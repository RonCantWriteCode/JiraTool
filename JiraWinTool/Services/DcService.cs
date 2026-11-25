using System.Text;
using System.Text.RegularExpressions;
using JiraWinTool.Utils;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>DC 目录中的一个文本/附件文件</summary>
public class DcFileEntry
{
    public string Name { get; set; } = "";
    public string FullPath { get; set; } = "";
    public long Size { get; set; }
    /// <summary>文本文件解析出的正文（二进制文件为空）</summary>
    public string Text { get; set; } = "";
    public bool IsText { get; set; }
    /// <summary>是否作为附件上传到 DC</summary>
    public bool SelectedAsAttachment { get; set; }
    /// <summary>从文件名解析出的系统名称（最后一个紧跟中文的下划线之后的中文串）</summary>
    public string SystemName { get; set; } = "";

    public string SizeDisplay =>
        Size < 1024 ? $"{Size} B"
        : Size < 1024 * 1024 ? $"{Size / 1024.0:F1} KB"
        : $"{Size / (1024.0 * 1024.0):F1} MB";

    public string MimeType => DcService.MimeTypeFor(Name);
}

/// <summary>『系统』级联下拉字段的一个可选项（父类 + 子系统，含各自 id）</summary>
public class DcSystemOption
{
    public string ParentValue { get; set; } = "";
    public string ParentId { get; set; } = "";
    public string ChildValue { get; set; } = "";
    public string ChildId { get; set; } = "";
    public string Display => $"{ParentValue} / {ChildValue}";
}

/// <summary>本地目录扫描出的一个待创建 DC 条目（= 一个 REQ 目录内的某个系统分组）</summary>
public class DcItem
{
    public string DirectoryName { get; set; } = "";
    public string DirectoryPath { get; set; } = "";
    /// <summary>目录名对应的 REQ Key（如 REQ-12345）</summary>
    public string ReqKey { get; set; } = "";
    /// <summary>本条目对应的系统名称（从文件名解析）</summary>
    public string SystemName { get; set; } = "";
    /// <summary>系统名称映射到的『系统』级联选项；无映射时为 null（不写系统字段）</summary>
    public DcSystemOption? SystemOption { get; set; }
    /// <summary>是否关联对应 REQ（页面上的勾选开关）</summary>
    public bool LinkReq { get; set; } = true;
    /// <summary>DC 摘要（默认取对应 REQ 的标题）</summary>
    public string Summary { get; set; } = "";
    /// <summary>DC 描述/变更内容（默认取目录内文本文件内容汇总）</summary>
    public string Description { get; set; } = "";
    public List<DcFileEntry> Files { get; set; } = new();
    /// <summary>本次批量创建成功后回写的 DC Key（未创建时为空）</summary>
    public string LastCreatedKey { get; set; } = "";
}

/// <summary>
/// 创建 DC（生产数据配置变更申请）服务：
/// 扫描本地目录中 REQ- 开头的子目录，参考模板 DC 工单的字段结构批量创建 DC，
/// 并把目录内文本文件内容汇总为变更描述、按勾选上传附件、关联对应 REQ。
/// 字段容错重试机制与 OACreateReqService 保持一致。
/// </summary>
public class DcService
{
    public static DcService Shared { get; } = new();
    private DcService() { }

    private readonly JiraService _jira = JiraService.Shared;

    /// <summary>按文本处理的最大文件大小（超过则仅作为附件上传）</summary>
    private const long MaxTextFileSize = 2 * 1024 * 1024;

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".sql", ".txt", ".md", ".csv", ".json", ".xml", ".html", ".htm", ".log", ".sh", ".yaml", ".yml", ".properties",
    };

    static DcService()
    {
        // GBK 等代码页解码需要注册 CodePages 提供程序
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    /// <summary>
    /// 文件名系统名 → 『系统』级联选项 的固定映射表（父/子 value 与 id 均取自 Jira createmeta）。
    /// 新增系统时在此补一行即可；匹配不到的系统名将留空由用户手工处理。
    /// </summary>
    public static readonly Dictionary<string, DcSystemOption> SystemMap = new()
    {
        ["新非车"] = Opt("A核心出单类", "10851", "A22 新一代非车险承保核心系统", "15002"),
        ["核保系统"] = Opt("A核心出单类", "10851", "A10 核保子系统", "14341"),
        ["数字化营销"] = Opt("E渠道支持类", "10884", "531 数字化营销管家", "14811"),
        ["平台系统"] = Opt("Y辅助支持类", "10886", "D01 新核心平台系统", "12900"),
        ["收付系统"] = Opt("C资金财务类", "10882", "C01 新核心收付系统", "12406"),
        ["配管系统"] = Opt("Y辅助支持类", "10886", "969 微-配置管理系统", "14633"),
        ["费管系统"] = Opt("A核心出单类", "10851", "119 销售费用管理系统（费管）", "10868"),
        ["产品工厂"] = Opt("Y辅助支持类", "10886", "D11 产品工厂", "14392"),
    };

    private static DcSystemOption Opt(string pv, string pid, string cv, string cid) => new()
    {
        ParentValue = pv, ParentId = pid, ChildValue = cv, ChildId = cid
    };

    /// <summary>从文件名提取系统名：最后一个紧跟中文的下划线之后，连续的中文串。取不到返回空。</summary>
    public static string ExtractSystemName(string fileName)
    {
        var name = System.IO.Path.GetFileNameWithoutExtension(fileName);
        var bestPos = -1;
        for (var i = 0; i < name.Length - 1; i++)
            if (name[i] == '_' && IsCjk(name[i + 1]))
                bestPos = i;
        if (bestPos < 0) return "";
        var end = bestPos + 1;
        while (end < name.Length && IsCjk(name[end])) end++;
        return name.Substring(bestPos + 1, end - bestPos - 1);
    }

    private static bool IsCjk(char c) => c >= 0x4E00 && c <= 0x9FFF;

    /// <summary>根据文件名扩展名推断 MIME 类型</summary>
    public static string MimeTypeFor(string fileName) =>
        System.IO.Path.GetExtension(fileName).ToLowerInvariant() switch
        {
            ".sql" => "application/sql",
            ".txt" or ".log" => "text/plain",
            ".md" => "text/markdown",
            ".csv" => "text/csv",
            ".json" => "application/json",
            ".xml" => "application/xml",
            ".html" or ".htm" => "text/html",
            ".zip" => "application/zip",
            ".pdf" => "application/pdf",
            ".doc" => "application/msword",
            ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".xls" => "application/vnd.ms-excel",
            ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            _ => "application/octet-stream",
        };

    // MARK: - 目录扫描

    /// <summary>扫描根目录下 REQ-开头的子目录，生成待创建 DC 条目（含文件清单与文本内容）</summary>
    public List<DcItem> ScanDirectory(string rootPath)
    {
        if (!Directory.Exists(rootPath))
            throw new DirectoryNotFoundException($"目录不存在: {rootPath}");

        var items = new List<DcItem>();
        // 若选中的目录本身就是 REQ- 开头，直接把它当作待处理目录；否则扫描其下 REQ-* 子目录
        var rootName = System.IO.Path.GetFileName(rootPath.TrimEnd('/', '\\'));
        var dirs = Regex.IsMatch(rootName, @"^REQ-\d+")
            ? new List<string> { rootPath }
            : Directory.GetDirectories(rootPath, "REQ-*")
                .Where(d => Regex.IsMatch(System.IO.Path.GetFileName(d), @"^REQ-\d+"))
                .OrderBy(d =>
                {
                    var m = Regex.Match(System.IO.Path.GetFileName(d), @"REQ-(\d+)");
                    return m.Success ? int.Parse(m.Groups[1].Value) : int.MaxValue;
                }).ToList();

        foreach (var dir in dirs)
        {
            var dirName = System.IO.Path.GetFileName(dir);
            var reqKey = Regex.Match(dirName, @"REQ-\d+").Value;

            // 先读取目录内所有文件，标注各自系统名
            var entries = new List<DcFileEntry>();
            foreach (var file in Directory.GetFiles(dir).OrderBy(f => f))
            {
                var name = System.IO.Path.GetFileName(file);
                if (name.StartsWith("._") || name.Equals(".DS_Store", StringComparison.Ordinal)) continue;

                var ext = System.IO.Path.GetExtension(name);
                var size = new FileInfo(file).Length;
                var isText = TextExtensions.Contains(ext) && size <= MaxTextFileSize;
                var entry = new DcFileEntry
                {
                    Name = name,
                    FullPath = file,
                    Size = size,
                    IsText = isText,
                    // 默认：文本文件上传附件 + 内容进描述；Office/PDF 等仅上传附件
                    SelectedAsAttachment = true,
                    SystemName = ExtractSystemName(name),
                };
                if (isText)
                {
                    try { entry.Text = ReadTextFile(file); }
                    catch (Exception ex)
                    {
                        Log.Debug($"[DcService] 读取文本失败 {file}: {ex.Message}");
                        entry.IsText = false;
                        entry.Text = "";
                    }
                }
                entries.Add(entry);
            }

            // 按系统名分组：每个系统名一个 DC，未识别（空）的排到最后
            var groups = entries
                .GroupBy(e => e.SystemName)
                .OrderBy(g => string.IsNullOrEmpty(g.Key) ? 1 : 0)
                .ThenBy(g => g.Key, StringComparer.Ordinal);

            foreach (var g in groups)
            {
                var sysName = g.Key;
                var item = new DcItem
                {
                    DirectoryName = dirName,
                    DirectoryPath = dir,
                    ReqKey = reqKey,
                    SystemName = sysName,
                    SystemOption = SystemMap.TryGetValue(sysName, out var opt) ? opt : null,
                    Summary = string.IsNullOrEmpty(sysName) ? dirName : $"{dirName} {sysName}",
                };
                item.Files.AddRange(g);
                item.Description = BuildDescriptionFromFiles(item);
                items.Add(item);
            }
        }
        return items;
    }

    /// <summary>把目录内文本文件内容汇总为 DC 变更描述</summary>
    private static string BuildDescriptionFromFiles(DcItem item)
    {
        var sb = new StringBuilder();
        var textFiles = item.Files.Where(f => f.IsText && !string.IsNullOrWhiteSpace(f.Text)).ToList();
        foreach (var f in textFiles)
        {
            if (sb.Length > 0) sb.AppendLine();
            sb.AppendLine($"【{f.Name}】");
            sb.AppendLine(f.Text.Trim());
        }
        var binaryNames = item.Files.Where(f => !f.IsText).Select(f => f.Name).ToList();
        if (binaryNames.Count > 0)
        {
            if (sb.Length > 0) sb.AppendLine();
            sb.AppendLine("【附件文件】");
            foreach (var n in binaryNames) sb.AppendLine(n);
        }
        if (sb.Length == 0)
            sb.AppendLine($"（{item.DirectoryName} 目录无内容，请手工填写变更内容）");
        sb.AppendLine();
        sb.Append($"本地目录：{item.DirectoryPath}");
        return sb.ToString();
    }

    /// <summary>读取文本文件：优先 UTF-8（含 BOM），失败回退 GBK，再回退 latin1 保字节</summary>
    private static string ReadTextFile(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // UTF-8 BOM
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        try
        {
            var utf8 = new UTF8Encoding(false, true);
            return utf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            try
            {
                var gbk = Encoding.GetEncoding("GBK");
                return gbk.GetString(bytes);
            }
            catch
            {
                return Encoding.Latin1.GetString(bytes);
            }
        }
    }

    // MARK: - 批量创建

    /// <summary>
    /// 按勾选条目批量创建 DC。
    /// </summary>
    /// <param name="templateDcKey">参考模板 DC 工单 Key（项目/类型/固定字段均取自它）</param>
    /// <param name="items">待创建条目（摘要/描述可被用户手工修正）</param>
    /// <param name="fixedLabels">固定字段：标签（多个用英文逗号分隔）</param>
    /// <param name="fixedAssignee">固定字段：经办人（空则用登录账号）</param>
    /// <param name="extraAttachmentPaths">固定附件：本地文件路径（多个用换行或分号分隔），上传到每个新建 DC</param>
    /// <param name="rawLogger">日志回调（[设置] 行按两端约定自动聚合）</param>
    /// <returns>成功创建的 DC Key 列表</returns>
    public async Task<List<string>> CreateFromItemsAsync(
        string templateDcKey,
        List<DcItem> items,
        string fixedLabels,
        string fixedAssignee,
        string extraAttachmentPaths,
        Action<string> rawLogger)
    {
        var templateKey = templateDcKey.Trim();
        if (string.IsNullOrEmpty(templateKey))
            throw new InvalidOperationException("未指定模板 DC Key");

        // 固定（测试通过）附件：解析为存在的文件路径列表
        var extraPaths = (extraAttachmentPaths ?? "")
            .Split(new[] { '\n', '\r', ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim())
            .Where(p => p.Length > 0 && File.Exists(p))
            .ToList();

        // 日志精简：连续的『[设置] xxx』行合并成一行输出（与 OACreateReqService 约定一致）
        const string SetPrefix = "[设置] ";
        var didSet = new List<string>();
        Action<string> logger = line =>
        {
            if (line.StartsWith(SetPrefix, StringComparison.Ordinal))
            {
                didSet.Add(line.Substring(SetPrefix.Length));
            }
            else
            {
                if (didSet.Count > 0)
                {
                    rawLogger(SetPrefix + string.Join("；", didSet));
                    didSet.Clear();
                }
                rawLogger(line);
            }
        };

        logger($"读取模板 DC {templateKey} ...");
        var raw = await _jira.GetIssueRawAsync(templateKey, expand: "names");
        var fields = raw["fields"] as JObject
            ?? throw new InvalidOperationException("模板返回无 fields");
        var names = raw["names"] as JObject ?? new JObject();

        // 反向索引：中文字段名 → customfield_id
        var nameToId = new Dictionary<string, string>();
        foreach (var prop in names.Properties())
            nameToId[prop.Value.Value<string>() ?? ""] = prop.Name;

        // 模板项目与类型
        var projectKey = fields["project"]?["key"]?.Value<string>()
            ?? throw new InvalidOperationException("模板无项目 key");
        var issueTypeDict = fields["issuetype"] as JObject;
        var issueTypeName = issueTypeDict?["name"]?.Value<string>() ?? "";
        var issueTypeId = issueTypeDict?["id"]?.Value<string>();

        // createmeta 字段元数据（用于选项字段解析与克隆白名单）
        var fieldOptions = new Dictionary<string, JArray>();
        var fieldSchemaTypes = new Dictionary<string, string>();
        var creatableFields = new HashSet<string>();
        try
        {
            var metaFields = await _jira.GetCreateMetaFieldsAsync(projectKey,
                string.IsNullOrEmpty(issueTypeName) ? "故障" : issueTypeName);
            if (metaFields != null)
            {
                foreach (var prop in metaFields.Properties())
                {
                    creatableFields.Add(prop.Name);
                    var allowedValues = prop.Value["allowedValues"] as JArray;
                    if (allowedValues != null && allowedValues.Count > 0)
                        fieldOptions[prop.Name] = allowedValues;
                    var schemaType = prop.Value["schema"]?["type"]?.Value<string>();
                    if (!string.IsNullOrEmpty(schemaType))
                        fieldSchemaTypes[prop.Name] = schemaType;
                }
            }
        }
        catch (Exception ex)
        {
            logger($"[元数据] 查询 createmeta 失败: {ex.Message}，将仅按模板结构克隆");
        }

        // 『系统』级联字段（按模板 names 精确匹配“系统”），单独按映射表写入，不参与克隆
        var systemFieldId = nameToId.TryGetValue("系统", out var sysId) ? sysId : null;

        // 模板中可克隆的普通字段（字符串/数字/选项/级联/多选/日期），排除系统字段与已知需覆盖的字段
        var cloneFieldIds = new List<string>();
        foreach (var prop in fields.Properties())
        {
            var id = prop.Name;
            if (systemFieldId != null && id == systemFieldId) continue;
            if (id is "summary" or "description" or "project" or "issuetype" or "creator" or "reporter"
                or "assignee" or "labels" or "issuelinks" or "attachment" or "comment" or "subtasks"
                or "issuechildren" or "parent" or "status" or "resolution" or "resolutiondate"
                or "created" or "updated" or "watchers" or "votes" or "worklog"
                or "timetracking" or "aggregateprogress" or "progress" or "environment"
                or "components" or "versions")
                continue;
            if (id.StartsWith("customfield_") && creatableFields.Count > 0 && !creatableFields.Contains(id))
                continue;
            var val = prop.Value;
            if (val == null || val.Type == JTokenType.Null) continue;
            var keep = val.Type switch
            {
                JTokenType.String or JTokenType.Integer or JTokenType.Float or JTokenType.Boolean => true,
                JTokenType.Object => IsCloneableObject(val as JObject),
                JTokenType.Array => val is JArray arr && arr.Count > 0 && arr.All(IsCloneableArrayItem),
                _ => false,
            };
            if (keep) cloneFieldIds.Add(id);
        }

        var assignee = !string.IsNullOrEmpty(fixedAssignee) ? fixedAssignee : AppConfig.Shared.JiraUser;
        var labels = fixedLabels
            .Split(new[] { ',', '，', ';', '；', '\n', '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => !string.IsNullOrEmpty(s))
            .ToList();

        var createdKeys = new List<string>();
        var total = items.Count;
        for (var i = 0; i < total; i++)
        {
            var item = items[i];
            var tag = $"[{i + 1}/{total}] {item.DirectoryName} {item.SystemName}".TrimEnd();
            try
            {
                var summaryFallback = string.IsNullOrEmpty(item.SystemName)
                    ? item.DirectoryName : $"{item.DirectoryName} {item.SystemName}";
                var newFields = new JObject
                {
                    ["project"] = new JObject { ["key"] = projectKey },
                    ["issuetype"] = issueTypeId != null
                        ? new JObject { ["id"] = issueTypeId }
                        : new JObject { ["name"] = issueTypeName },
                    ["summary"] = string.IsNullOrWhiteSpace(item.Summary) ? summaryFallback : item.Summary.Trim()
                };
                if (!string.IsNullOrWhiteSpace(item.Description))
                    newFields["description"] = item.Description;

                // 克隆模板普通字段
                foreach (var id in cloneFieldIds)
                {
                    if (fields[id] is not { } cloneValue) continue;
                    newFields[id] = cloneValue.DeepClone();
                }
                if (cloneFieldIds.Count > 0)
                    logger($"{tag} [设置] 克隆模板字段 {cloneFieldIds.Count} 个");

                // 『系统』级联字段：按固定映射表写入父/子选项（含 id）
                if (systemFieldId != null)
                {
                    if (item.SystemOption is { } opt)
                    {
                        newFields[systemFieldId] = new JObject
                        {
                            ["value"] = opt.ParentValue,
                            ["id"] = opt.ParentId,
                            ["child"] = new JObject { ["value"] = opt.ChildValue, ["id"] = opt.ChildId }
                        };
                        logger($"[设置] 系统 = {opt.ParentValue} > {opt.ChildValue}");
                    }
                    else
                    {
                        logger($"[警告] 系统名『{(string.IsNullOrEmpty(item.SystemName) ? "未识别" : item.SystemName)}』无映射，未设置系统字段");
                    }
                }

                // 变更内容类字段：若模板有「变更内容/数据变更内容」等多行文本字段，同步写入描述
                var changeFieldId = ResolveCustomFieldId(nameToId,
                    new[] { "变更内容", "数据变更内容", "变更脚本", "配置变更内容" });
                if (changeFieldId != null && !string.IsNullOrWhiteSpace(item.Description)
                    && IsPlainTextSchema(changeFieldId, fields))
                {
                    newFields[changeFieldId] = item.Description;
                    logger($"[设置] 变更内容 = {item.DirectoryName}");
                }

                if (!string.IsNullOrEmpty(assignee))
                    newFields["assignee"] = new JObject { ["name"] = assignee };
                if (labels.Count > 0)
                    newFields["labels"] = new JArray(labels);

                logger($"{tag} 创建 DC ...");
                var newKey = await CreateWithRetryAsync(newFields, issueTypeId, fieldOptions, logger);
                createdKeys.Add(newKey);
                item.LastCreatedKey = newKey;
                logger($"{tag} [成功] 创建 DC: {newKey}（{item.Summary}）");

                // 上传勾选的目录文件
                var picked = item.Files.Where(f => f.SelectedAsAttachment).ToList();
                if (picked.Count > 0)
                {
                    var uploaded = 0;
                    foreach (var f in picked)
                    {
                        try
                        {
                            var data = await File.ReadAllBytesAsync(f.FullPath);
                            if (await _jira.UploadAttachmentIfAbsentAsync(newKey, f.Name, data, f.MimeType))
                                uploaded++;
                        }
                        catch (Exception ex)
                        {
                            logger($"[附件失败] {f.Name}: {ex.Message}");
                        }
                    }
                    logger($"[附件] {newKey} 已上传 {uploaded}/{picked.Count}");
                }

                // 上传固定（测试通过）附件
                if (extraPaths.Count > 0)
                {
                    var up = 0;
                    foreach (var p in extraPaths)
                    {
                        var fname = System.IO.Path.GetFileName(p);
                        try
                        {
                            var data = await File.ReadAllBytesAsync(p);
                            if (await _jira.UploadAttachmentIfAbsentAsync(newKey, fname, data, MimeTypeFor(fname)))
                                up++;
                        }
                        catch (Exception ex)
                        {
                            logger($"[测试附件失败] {fname}: {ex.Message}");
                        }
                    }
                    logger($"[测试附件] {newKey} 已上传 {up}/{extraPaths.Count}");
                }

                // 关联对应 REQ
                if (item.LinkReq && !string.IsNullOrEmpty(item.ReqKey))
                {
                    try
                    {
                        var outcome = await _jira.LinkIssuesIfAbsentAsync(newKey, item.ReqKey, "关联");
                        switch (outcome)
                        {
                            case JiraService.LinkOutcome.Created:
                                logger($"[关联] {newKey} → {item.ReqKey}");
                                break;
                            case JiraService.LinkOutcome.AlreadyLinked:
                                logger($"[关联] {newKey} 与 {item.ReqKey} 已关联，未重复创建");
                                break;
                            default:
                                logger($"[关联] 无法确认 {item.ReqKey} 的已有关联，本次未关联，请手动检查");
                                break;
                        }
                    }
                    catch (Exception ex)
                    {
                        logger($"[关联失败] {newKey} → {item.ReqKey}: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                logger($"{tag} [失败] 创建 DC 失败：{ex.Message}");
            }
        }

        rawLogger($"[完成] 成功 {createdKeys.Count}/{total} 个 DC" +
                  (createdKeys.Count > 0 ? $"：{string.Join(", ", createdKeys)}" : ""));
        return createdKeys;
    }

    // MARK: - 创建容错（与 OACreateReqService 相同的两轮重试策略）

    private async Task<string> CreateWithRetryAsync(
        JObject newFields, string? issueTypeId,
        Dictionary<string, JArray> fieldOptions, Action<string> logger)
    {
        try
        {
            return await _jira.CreateIssueAsync("", issueTypeId ?? "", newFields);
        }
        catch (Exception ex)
        {
            var badFields = ParseBadFieldsFromError(ex.Message);
            if (badFields is { Count: > 0 })
            {
                logger($"[过滤] 首次创建失败，移除不在创建屏幕上的字段后重试: {string.Join(", ", badFields)}");
                foreach (var field in badFields)
                    newFields.Remove(field);
                try
                {
                    return await _jira.CreateIssueAsync("", issueTypeId ?? "", newFields);
                }
                catch (Exception ex2)
                {
                    return await RetryWithFieldRemoval(newFields, issueTypeId, ex2, fieldOptions, logger);
                }
            }
            return await RetryWithFieldRemoval(newFields, issueTypeId, ex, fieldOptions, logger);
        }
    }

    private async Task<string> RetryWithFieldRemoval(
        JObject newFields, string? issueTypeId, Exception ex,
        Dictionary<string, JArray> fieldOptions, Action<string> logger)
    {
        var invalidFields = ParseInvalidOptionFieldsFromError(ex.Message);
        if (invalidFields is { Count: > 0 })
        {
            foreach (var field in invalidFields)
            {
                if (fieldOptions.TryGetValue(field, out var opts))
                    logger($"[跳过] {field} 选项值无效，可用选项: {DescribeOptions(opts)}");
                else
                    logger($"[跳过] {field} 选项值无效，无元数据可用");
                newFields.Remove(field);
            }
            return await _jira.CreateIssueAsync("", issueTypeId ?? "", newFields);
        }
        throw ex;
    }

    private static bool IsCloneableObject(JObject? obj)
    {
        if (obj == null) return false;
        // 级联/选项结构：{id, value[, child]}
        if (obj["value"] != null) return true;
        // 用户结构：{name/key, displayName}
        if (obj["name"] != null || obj["key"] != null) return true;
        return false;
    }

    private static bool IsCloneableArrayItem(JToken token) =>
        token.Type == JTokenType.String
        || (token is JObject obj && obj["self"] == null
            && (obj["value"] != null || obj["id"] != null || obj["name"] != null));

    /// <summary>字段是否可安全写入纯文本（string/text schema，或模板值本身是字符串）</summary>
    private static bool IsPlainTextSchema(string cfId, JObject templateFields)
    {
        var templateVal = templateFields[cfId];
        if (templateVal != null && templateVal.Type == JTokenType.String) return true;
        return templateVal == null || templateVal.Type == JTokenType.Null;
    }

    private static string DescribeOptions(JArray allowedValues)
    {
        var values = allowedValues
            .Select(o => o["value"]?.Value<string>() ?? "?")
            .Where(v => v != "?")
            .ToList();
        var shown = string.Join(", ", values.Take(8));
        return values.Count > 8 ? $"[{shown}, …共 {values.Count} 项]" : $"[{shown}]";
    }

    private static string? ResolveCustomFieldId(Dictionary<string, string> nameToId, string[] candidates)
    {
        foreach (var c in candidates)
            if (nameToId.TryGetValue(c, out var id))
                return id;
        foreach (var (name, id) in nameToId)
            foreach (var c in candidates)
                if (name.Contains(c))
                    return id;
        return null;
    }

    private static List<string>? ParseBadFieldsFromError(string errorMsg)
    {
        var matches = Regex.Matches(errorMsg, @"Field\s+'([a-zA-Z_][a-zA-Z_0-9]*)'\s+cannot\s+be\s+set", RegexOptions.IgnoreCase);
        if (matches.Count == 0) return null;
        var result = new List<string>();
        foreach (Match m in matches)
            if (m.Groups.Count >= 2)
                result.Add(m.Groups[1].Value);
        return result;
    }

    private static List<string>? ParseInvalidOptionFieldsFromError(string errorMsg)
    {
        var pattern = "\"(customfield_\\d+)\"\\s*:\\s*\"[^\"]*(?:Could not find valid|not a valid)\"";
        var matches = Regex.Matches(errorMsg, pattern, RegexOptions.IgnoreCase);
        if (matches.Count == 0) return null;
        var result = new List<string>();
        foreach (Match m in matches)
            if (m.Groups.Count >= 2)
                result.Add(m.Groups[1].Value);
        return result;
    }
}
