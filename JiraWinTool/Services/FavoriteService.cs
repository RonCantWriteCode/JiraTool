using System.ComponentModel;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json;

namespace JiraWinTool.Services;

public class FavoriteException : Exception
{
    private FavoriteException(string message) : base(message) { }

    public static FavoriteException InvalidInput(string msg) => new(msg);
    public static FavoriteException AlreadyExists(string key) => new($"{key} 已在收藏列表中");
    public static FavoriteException FetchFailed(string msg) => new($"获取 Jira 信息失败: {msg}");
}

/// <summary>
/// 收藏服务（移植自 Swift FavoriteService.swift）。
/// 收藏库：SQLite（FavoriteDBService）；同步：WebDAV（WebDavService）；
/// 自动同步：PeriodicTimer 后台任务（对应 Swift Timer）。
/// </summary>
public partial class FavoriteService : ObservableObject
{
    public static FavoriteService Shared { get; } = new FavoriteService();

    [ObservableProperty]
    private List<FavoriteJira> _favorites = new();

    [ObservableProperty]
    private string _autoSyncMessage = "";

    private readonly FavoriteDBService _db = FavoriteDBService.Shared;
    private CancellationTokenSource? _autoSyncCts;
    private CancellationTokenSource? _restartDebounceCts;

    // MARK: - 删除墓碑（Tombstones）
    // 用于记录已删除的 key，避免 WebDAV 合并时被"复活"
    private const string DeletedKeysStorageKey = "favorite_deleted_keys";
    private HashSet<string> _deletedKeys = new();

    private FavoriteService()
    {
        LoadDeletedKeys();
        LoadFavorites();
        SetupAutoSyncObserver();
        StartAutoSyncIfNeeded();
    }

    // MARK: - Tombstones 持久化

    private void LoadDeletedKeys()
    {
        var json = AppConfig.Shared.GetCustom(DeletedKeysStorageKey);
        if (string.IsNullOrEmpty(json)) return;
        try
        {
            _deletedKeys = JsonConvert.DeserializeObject<HashSet<string>>(json) ?? new HashSet<string>();
        }
        catch { _deletedKeys = new HashSet<string>(); }
    }

    private void SaveDeletedKeys()
        => AppConfig.Shared.SetCustom(DeletedKeysStorageKey, JsonConvert.SerializeObject(_deletedKeys));

    private void AddTombstone(string key)
    {
        _deletedKeys.Add(key);
        SaveDeletedKeys();
    }

    private void RemoveTombstone(string key)
    {
        _deletedKeys.Remove(key);
        SaveDeletedKeys();
    }

    // MARK: - 从链接解析 Issue Key

    /// <summary>从 Jira 链接中提取 issue key，如 REQ-22411</summary>
    public static string? ParseIssueKey(string input)
    {
        var trimmed = input.Trim();

        // 匹配 /browse/XXX-123 格式的链接
        var m = Regex.Match(trimmed, @"/browse/([A-Z]+-\d+)");
        if (m.Success) return m.Groups[1].Value;

        // 直接输入 issue key（如 REQ-22411）
        if (Regex.IsMatch(trimmed, @"^[A-Z]+-\d+$")) return trimmed;

        return null;
    }

    // MARK: - CRUD

    /// <summary>添加收藏:从 Jira 获取信息并保存</summary>
    public async Task<FavoriteJira> AddFavoriteAsync(string input)
    {
        var issueKey = ParseIssueKey(input)
            ?? throw FavoriteException.InvalidInput("无法解析 Jira 链接或编号,请输入类似 REQ-22411 或 http://jira.sinosafe.com.cn/browse/REQ-22411");

        // 检查是否已收藏（使用数据库查询）
        if (_db.Exists(issueKey))
            throw FavoriteException.AlreadyExists(issueKey);

        // 从 Jira 获取详情
        var issue = await JiraService.Shared.GetIssueAsync(issueKey);

        var baseURL = AppConfig.Shared.JiraURL.TrimEnd('/');
        var url = $"{baseURL}/browse/{issueKey}";

        var favorite = FavoriteJira.FromIssue(issue, url);

        _db.Insert(favorite);
        // 重新添加时清除对应的墓碑
        RemoveTombstone(issueKey);
        var list = new List<FavoriteJira>(Favorites);
        list.Insert(0, favorite);
        Favorites = list;
        SyncAfterChange();

        return favorite;
    }

    /// <summary>批量添加结果</summary>
    public record BatchAddResult(List<FavoriteJira> Success, List<(string Input, string Error)> Failed);

    /// <summary>批量添加收藏:支持多行输入,返回成功和失败的结果</summary>
    public async Task<BatchAddResult> AddFavoritesBatchAsync(List<string> inputs)
    {
        var success = new List<FavoriteJira>();
        var failed = new List<(string Input, string Error)>();

        foreach (var raw in inputs)
        {
            var trimmed = raw.Trim();
            if (trimmed.Length == 0) continue;

            try
            {
                var fav = await AddFavoriteAsync(trimmed);
                success.Add(fav);
            }
            catch (Exception ex)
            {
                failed.Add((trimmed, ex.Message));
            }
        }

        return new BatchAddResult(success, failed);
    }

    /// <summary>切换置顶状态</summary>
    public void TogglePin(string id)
    {
        var item = Favorites.FirstOrDefault(f => f.Id == id);
        if (item == null) return;
        item.IsPinned = !item.IsPinned;
        Log.Debug($"📌 togglePin: {item.Key} -> isPinned={item.IsPinned}, id={id}");

        // 置顶时记录时间，取消置顶时清空时间
        item.PinnedAt = item.IsPinned ? DateTime.Now : null;

        _db.UpdatePinned(id, item.IsPinned, item.PinnedAt);
        NotifyFavoritesChanged();
        SyncAfterChange();
    }

    /// <summary>切换归档状态</summary>
    public void ToggleArchive(string id)
    {
        var item = Favorites.FirstOrDefault(f => f.Id == id);
        if (item == null) return;
        item.IsArchived = !item.IsArchived;
        Log.Debug($"📦 toggleArchive: {item.Key} -> isArchived={item.IsArchived}, id={id}");
        _db.UpdateArchived(id, item.IsArchived);
        NotifyFavoritesChanged();
        SyncAfterChange();
    }

    /// <summary>删除收藏</summary>
    public void RemoveFavorite(string id)
    {
        // 记录墓碑，防止 WebDAV 合并时复活
        var item = Favorites.FirstOrDefault(f => f.Id == id);
        if (item != null) AddTombstone(item.Key);
        Favorites = Favorites.Where(f => f.Id != id).ToList();
        _db.Delete(id);
        SyncAfterChange();
    }

    /// <summary>批量删除</summary>
    public void RemoveFavorites(HashSet<string> ids)
    {
        // 记录墓碑
        foreach (var id in ids)
        {
            var item = Favorites.FirstOrDefault(f => f.Id == id);
            if (item != null) AddTombstone(item.Key);
        }
        Favorites = Favorites.Where(f => !ids.Contains(f.Id)).ToList();
        _db.Delete(ids);
        SyncAfterChange();
    }

    /// <summary>刷新单个收藏（重新从 Jira 获取最新信息）</summary>
    public async Task RefreshFavoriteAsync(string id)
    {
        var index = Favorites.FindIndex(f => f.Id == id);
        if (index < 0) return;
        var old = Favorites[index];

        var issue = await JiraService.Shared.GetIssueAsync(old.Key);
        var updated = FavoriteJira.FromIssue(issue, old.Url);

        // 保留原始 id 和收藏时间
        var refreshed = new FavoriteJira
        {
            Id = old.Id,
            Key = updated.Key,
            IssueType = updated.IssueType,
            Summary = updated.Summary,
            Reporter = updated.Reporter,
            Assignee = updated.Assignee,
            Status = updated.Status,
            Created = updated.Created,
            Updated = updated.Updated,
            Url = old.Url,
            AddedAt = old.AddedAt,
            IsPinned = old.IsPinned,
            PinnedAt = old.PinnedAt,
            IsArchived = old.IsArchived,
            QianbaoNo = updated.QianbaoNo,
            QianbaoLink = updated.QianbaoLink
            // ModifiedAt 默认为当前时间（对应 Swift init 时 touched）
        };

        _db.Update(refreshed);
        var list = new List<FavoriteJira>(Favorites);
        list[index] = refreshed;
        Favorites = list;
        SyncAfterChange();
    }

    // MARK: - 导出 Excel

    /// <summary>将收藏列表导出为 xlsx 文件（手写 OOXML + ZipArchive，对应 Swift /usr/bin/zip 方案）</summary>
    public Task ExportToExcelAsync(List<FavoriteJira> items, string outputPath)
        => Task.Run(() => ExportToExcelCore(items, outputPath));

    private static void ExportToExcelCore(List<FavoriteJira> items, string outputPath)
    {
        var finalPath = outputPath.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)
            ? outputPath : outputPath + ".xlsx";
        if (File.Exists(finalPath)) File.Delete(finalPath);

        using (var fs = new FileStream(finalPath, FileMode.CreateNew, FileAccess.ReadWrite))
        using (var zip = new ZipArchive(fs, ZipArchiveMode.Create))
        {
            void AddEntry(string name, string content)
            {
                var entry = zip.CreateEntry(name);
                using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
                writer.Write(content);
            }

            AddEntry("[Content_Types].xml", XlsxContentTypes);
            AddEntry("_rels/.rels", XlsxRootRels);
            AddEntry("xl/workbook.xml", XlsxWorkbook);
            AddEntry("xl/_rels/workbook.xml.rels", XlsxWorkbookRels);
            AddEntry("xl/styles.xml", XlsxStyles);
            AddEntry("xl/worksheets/sheet1.xml", BuildSheetXml(items));
        }

        if (!File.Exists(finalPath))
            throw FavoriteException.FetchFailed("导出文件未生成");
    }

    private const string XlsxContentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """;

    private const string XlsxRootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """;

    private const string XlsxWorkbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets>
                <sheet name="收藏Jira" sheetId="1" r:id="rId1"/>
            </sheets>
        </workbook>
        """;

    private const string XlsxWorkbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """;

    private const string XlsxStyles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2">
                <font><sz val="11"/><name val="Arial"/></font>
                <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Arial"/></font>
            </fonts>
            <fills count="3">
                <fill><patternFill patternType="none"/></fill>
                <fill><patternFill patternType="gray125"/></fill>
                <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/></patternFill></fill>
            </fills>
            <borders count="2">
                <border><left/><right/><top/><bottom/><diagonal/></border>
                <border>
                    <left style="thin"><color auto="1"/></left>
                    <right style="thin"><color auto="1"/></right>
                    <top style="thin"><color auto="1"/></top>
                    <bottom style="thin"><color auto="1"/></bottom>
                    <diagonal/>
                </border>
            </borders>
            <cellStyleXfs count="1">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
            </cellStyleXfs>
            <cellXfs count="3">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
                <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
                <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
            </cellXfs>
        </styleSheet>
        """;

    private static string BuildSheetXml(List<FavoriteJira> items)
    {
        string[] headers = { "Jira编号", "问题类型", "标题", "报告人", "经办人", "状态", "签报号", "创建时间", "更新时间", "收藏时间", "是否置顶", "是否归档" };
        var colCount = headers.Length;

        static string LetterForCol(int col)
        {
            var s = "";
            var c = col;
            while (c > 0)
            {
                var r = (c - 1) % 26;
                s = (char)('A' + r) + s;
                c = (c - 1) / 26;
            }
            return s;
        }

        static string Esc(string str) => str
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;")
            .Replace("'", "&apos;");

        var sb = new StringBuilder();
        sb.Append("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                <cols>
                    <col min="1" max="1" width="16" customWidth="1"/>
                    <col min="2" max="2" width="10" customWidth="1"/>
                    <col min="3" max="3" width="50" customWidth="1"/>
                    <col min="4" max="5" width="12" customWidth="1"/>
                    <col min="6" max="6" width="14" customWidth="1"/>
                    <col min="7" max="7" width="20" customWidth="1"/>
                    <col min="8" max="10" width="18" customWidth="1"/>
                    <col min="11" max="12" width="10" customWidth="1"/>
                </cols>
                <sheetData>
            """);

        // Header row
        sb.Append($"<row r=\"1\" spans=\"1:{colCount}\">");
        for (var idx = 0; idx < headers.Length; idx++)
        {
            sb.Append($"<c r=\"{LetterForCol(idx + 1)}1\" s=\"1\" t=\"inlineStr\"><is><t>{Esc(headers[idx])}</t></is></c>");
        }
        sb.Append("</row>");

        // Data rows
        for (var rowIdx = 0; rowIdx < items.Count; rowIdx++)
        {
            var item = items[rowIdx];
            var row = rowIdx + 2;
            string[] vals =
            {
                item.Key,
                item.IssueType,
                item.Summary,
                item.Reporter,
                item.Assignee,
                item.Status,
                item.QianbaoNo,
                item.Created,
                item.Updated,
                item.AddedAt.ToString("yyyy-MM-dd HH:mm"),
                item.IsPinned ? "是" : "否",
                item.IsArchived ? "是" : "否"
            };
            sb.Append($"<row r=\"{row}\" spans=\"1:{colCount}\">");
            for (var idx = 0; idx < vals.Length; idx++)
            {
                sb.Append($"<c r=\"{LetterForCol(idx + 1)}{row}\" s=\"2\" t=\"inlineStr\"><is><t>{Esc(vals[idx])}</t></is></c>");
            }
            sb.Append("</row>");
        }

        sb.Append("""
                </sheetData>
            </worksheet>
            """);
        return sb.ToString();
    }

    // MARK: - WebDAV 同步

    /// <summary>上传本地收藏到 WebDAV</summary>
    public async Task<string> SyncUploadAsync()
    {
        await WebDavService.Shared.UploadAsync(Favorites);
        AppConfig.Shared.LastSyncTime = DateTime.Now;
        return $"✅ 已上传 {Favorites.Count} 条收藏到 WebDAV";
    }

    /// <summary>从 WebDAV 下载覆盖本地收藏</summary>
    public async Task<string> SyncDownloadAsync()
    {
        var remote = await WebDavService.Shared.DownloadAsync();
        _db.ReplaceAll(remote);
        Favorites = remote;
        AppConfig.Shared.LastSyncTime = DateTime.Now;
        return $"✅ 已从 WebDAV 下载 {remote.Count} 条收藏";
    }

    /// <summary>双向合并同步（本地 + 远程 合并后回写双方）</summary>
    public async Task<string> SyncMergeAsync()
    {
        var remote = await WebDavService.Shared.DownloadAsync();
        var merged = WebDavService.Shared.Merge(Favorites, remote);

        // 过滤已删除的 key，防止"复活"
        var filtered = merged.Where(item => !_deletedKeys.Contains(item.Key)).ToList();

        // 更新本地
        _db.ReplaceAll(filtered);
        Favorites = filtered;
        AppConfig.Shared.LastSyncTime = DateTime.Now;

        // 回写远程
        await WebDavService.Shared.UploadAsync(filtered);

        return $"✅ 合并同步完成，共 {filtered.Count} 条收藏";
    }

    // MARK: - 自动同步

    /// <summary>监听配置变化，动态重启定时器（0.5s 防抖，对应 Swift combineLatest + debounce）</summary>
    private void SetupAutoSyncObserver()
    {
        AppConfig.Shared.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppConfig.AutoSyncEnabled) or nameof(AppConfig.AutoSyncInterval))
            {
                _restartDebounceCts?.Cancel();
                _restartDebounceCts = new CancellationTokenSource();
                var token = _restartDebounceCts.Token;
                _ = Task.Delay(500, token).ContinueWith(
                    t => { if (!t.IsCanceled) StartAutoSyncIfNeeded(); },
                    CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            }
        };
    }

    /// <summary>启动或停止自动同步定时器</summary>
    public void StartAutoSyncIfNeeded()
    {
        // 先停止旧的定时器
        _autoSyncCts?.Cancel();
        _autoSyncCts = null;

        var config = AppConfig.Shared;
        if (!config.AutoSyncEnabled || !config.IsWebdavConfigured) return;

        _autoSyncCts = new CancellationTokenSource();
        var token = _autoSyncCts.Token;
        var interval = TimeSpan.FromMinutes(config.AutoSyncInterval);

        _ = Task.Run(async () =>
        {
            // 首次启动时也执行一次
            await PerformAutoSyncAsync();
            using var timer = new PeriodicTimer(interval);
            try
            {
                while (await timer.WaitForNextTickAsync(token))
                    await PerformAutoSyncAsync();
            }
            catch (OperationCanceledException) { }
        });
    }

    /// <summary>执行自动同步（合并模式）</summary>
    private async Task PerformAutoSyncAsync()
    {
        if (!AppConfig.Shared.IsWebdavConfigured) return;

        try
        {
            var msg = await SyncMergeAsync();
            RunOnUi(() => AutoSyncMessage = msg);
        }
        catch (Exception ex)
        {
            RunOnUi(() => AutoSyncMessage = $"❌ 自动同步失败: {ex.Message}");
        }
    }

    /// <summary>停止自动同步</summary>
    public void StopAutoSync()
    {
        _autoSyncCts?.Cancel();
        _autoSyncCts = null;
    }

    // MARK: - 数据变更后自动同步

    /// <summary>本地数据变更后，自动上传到 WebDAV（非阻塞，后台静默执行）</summary>
    private void SyncAfterChange()
    {
        if (!AppConfig.Shared.IsWebdavConfigured) return;
        var snapshot = Favorites;
        _ = Task.Run(async () =>
        {
            try
            {
                await WebDavService.Shared.UploadAsync(snapshot);
                RunOnUi(() => AppConfig.Shared.LastSyncTime = DateTime.Now);
                Log.Debug("☁️ 数据变更后自动同步完成");
            }
            catch (Exception ex)
            {
                Log.Debug($"⚠️ 数据变更后自动同步失败: {ex.Message}");
            }
        });
    }

    // MARK: - 持久化

    private void LoadFavorites()
    {
        var loaded = _db.LoadAll();
        Log.Debug($"📚 从 SQLite 加载 {loaded.Count} 条收藏");
        foreach (var item in loaded.Where(i => i.IsPinned || i.IsArchived))
            Log.Debug($"  └ {item.Key} isPinned={item.IsPinned} isArchived={item.IsArchived}");
        Favorites = loaded;
    }

    // MARK: - 辅助

    /// <summary>触发 Favorites 变化通知（用于排序/过滤视图刷新）</summary>
    private void NotifyFavoritesChanged() => Favorites = new List<FavoriteJira>(Favorites);

    private static void RunOnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess()) action();
        else dispatcher.Invoke(action);
    }
}
