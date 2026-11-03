using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>
/// OA 流程完成视图 — 解析 OA 审批流程中的 REQ 需求号
/// </summary>
public partial class OAProcessCompleteView : UserControl, INotifyPropertyChanged
{
    // MARK: - Dependency properties

    public static readonly DependencyProperty OALinkProperty =
        DependencyProperty.Register(nameof(OALink), typeof(string), typeof(OAProcessCompleteView),
            new PropertyMetadata("", (d, _) =>
            {
                var view = (OAProcessCompleteView)d;
                view.OnPropertyChanged(nameof(OALink));
                view.UpdateDownloadButtonState();
            }));

    public static readonly DependencyProperty OperatorNameProperty =
        DependencyProperty.Register(nameof(OperatorName), typeof(string), typeof(OAProcessCompleteView),
            new PropertyMetadata("吴润龙", (d, e) =>
            {
                var view = (OAProcessCompleteView)d;
                view.OnPropertyChanged(nameof(OperatorName));
                AppConfig.Shared.SetCustom("oa_process_complete_operator", e.NewValue as string ?? "");
            }));

    public static readonly DependencyProperty REQNumberProperty =
        DependencyProperty.Register(nameof(REQNumber), typeof(string), typeof(OAProcessCompleteView),
            new PropertyMetadata("", (d, _) =>
            {
                ((OAProcessCompleteView)d).UpdateDownloadButtonState();
            }));

    public static readonly DependencyProperty RelatedREQProperty =
        DependencyProperty.Register(nameof(RelatedREQ), typeof(string), typeof(OAProcessCompleteView),
            new PropertyMetadata(""));

    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(OAProcessCompleteView),
            new PropertyMetadata(""));

    public string OALink { get => (string)GetValue(OALinkProperty); set => SetValue(OALinkProperty, value); }
    public string OperatorName { get => (string)GetValue(OperatorNameProperty); set => SetValue(OperatorNameProperty, value); }
    public string REQNumber { get => (string)GetValue(REQNumberProperty); set => SetValue(REQNumberProperty, value); }
    public string RelatedREQ { get => (string)GetValue(RelatedREQProperty); set => SetValue(RelatedREQProperty, value); }
    public string Logs { get => (string)GetValue(LogsProperty); set => SetValue(LogsProperty, value); }

    // MARK: - State

    private bool _isParsing;
    private bool _isDownloadingPDF;

    public OAProcessCompleteView()
    {
        InitializeComponent();

        // 加载已保存的操作人
        var saved = AppConfig.Shared.GetCustom("oa_process_complete_operator");
        if (!string.IsNullOrEmpty(saved))
            OperatorName = saved;
    }

    // MARK: - INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: - Button State

    /// <summary>更新"下载PDF上传REQ"按钮的可用状态（与 Mac 端 disabled 条件对齐：OA 链接 + REQ 均非空）</summary>
    private void UpdateDownloadButtonState()
    {
        if (DownloadPDFBtn == null) return;
        if (_isParsing || _isDownloadingPDF)
        {
            DownloadPDFBtn.IsEnabled = false;
            return;
        }
        var hasLink = !string.IsNullOrEmpty(OALink?.Trim());
        var hasReq = !string.IsNullOrEmpty(REQNumber?.Trim());
        DownloadPDFBtn.IsEnabled = hasLink && hasReq;
    }

    // MARK: - Parse Action

    private async void ParseBtn_Click(object sender, RoutedEventArgs e)
    {
        var link = OALink.Trim();
        if (string.IsNullOrEmpty(link)) return;
        if (_isParsing) return;

        var opName = OperatorName.Trim();
        if (string.IsNullOrEmpty(opName))
        {
            AppendLog("[警告] 操作人姓名为空，请输入");
            return;
        }

        _isParsing = true;
        ParseBtn.IsEnabled = false;
        DownloadPDFBtn.IsEnabled = false;
        ParseProgress.Text = "解析中...";
        AppendLog($"开始解析：{link}，操作人：{opName}");

        try
        {
            // 1. 抓取主页面
            var html = await OAService.Shared.FetchHTMLAsync(link);
            var dumpPath = DumpDebugHTML(html, link);
            if (dumpPath != null)
                AppendLog($"[调试] 已保存 HTML 快照：{dumpPath}");

            var baseURL = ExtractBaseURL(link);

            // 2. 构造审批日志 URL 并抓取
            var auditURL = BuildAuditNoteURL(html, baseURL);
            string? combinedHTML = html;
            if (auditURL != null)
            {
                AppendLog($"[调试] 抓取审批日志：{auditURL}");
                try
                {
                    var auditHTML = await OAService.Shared.FetchHTMLAsync(auditURL);
                    var dumpPath2 = DumpDebugHTML(auditHTML, auditURL);
                    if (dumpPath2 != null)
                        AppendLog($"[调试] 已保存审批日志快照：{dumpPath2}");
                    combinedHTML = html + "\n" + auditHTML;
                }
                catch (Exception ex)
                {
                    AppendLog($"[调试] 审批日志抓取失败: {ex.Message}");
                }
            }
            else
            {
                AppendLog("[调试] 未找到审批日志 URL，仅使用主页面");
            }

            // 3. 调用 ExtractREQByOperator
            var reqs = OAParser.ExtractREQByOperator(combinedHTML, opName);
            // 4. 提取全部 REQ（不限操作人）用于关联REQ
            var allReqs = OAParser.ExtractAllREQ(combinedHTML);

            // 5. 填入结果
            if (reqs.Count > 0)
            {
                REQNumber = reqs[0];
                AppendLog($"解析完成：找到 {reqs.Count} 个 REQ（按操作人）：{string.Join(",", reqs)}");
            }
            else
            {
                REQNumber = "";
                RelatedREQ = "";
                AppendLog("[警告] 未找到操作人相关的 REQ 号，请检查 OA 链接和操作人姓名");
            }
            // 关联REQ：全部 REQ 排除主 REQ
            var mainReq = REQNumber.ToUpper();
            var related = allReqs.Where(r => r != mainReq).ToList();
            if (related.Count > 0)
            {
                RelatedREQ = string.Join(",", related);
                AppendLog($"关联 REQ（全部 {allReqs.Count} 个，排除主 REQ）：{RelatedREQ}");
            }
            else
            {
                RelatedREQ = "";
            }
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] {ex.Message}");
        }
        finally
        {
            _isParsing = false;
            ParseBtn.IsEnabled = true;
            UpdateDownloadButtonState();
            ParseProgress.Text = "";
        }
    }

    // MARK: - Download PDF & Upload

    private async void DownloadPDFBtn_Click(object sender, RoutedEventArgs e)
    {
        var link = OALink.Trim();
        var req = REQNumber.Trim();
        if (string.IsNullOrEmpty(link) || string.IsNullOrEmpty(req))
        {
            AppendLog("[警告] OA 链接或 REQ 为空");
            return;
        }
        if (_isDownloadingPDF) return;

        _isDownloadingPDF = true;
        DownloadPDFBtn.IsEnabled = false;
        AppendLog($"开始下载 PDF 并上传到 REQ: {req}");

        try
        {
            // 1. 构造 printURL（同现有逻辑）
            string printURL = OALink.Replace("method=view", "method=print");
            string baseURL = ExtractBaseURL(OALink);

            // 2. 调用 OAPDFExportService（返回的 fileName 为 OA 页面标题，如 “关于xxx的请示需求.pdf”）
            var (pdfData, pdfFileName) = await OAPDFExportService.Shared.ExportPDFAsync(printURL, baseURL);
            if (string.IsNullOrEmpty(pdfFileName))
                pdfFileName = $"{REQNumber}.pdf";
            else if (!pdfFileName.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
                pdfFileName += ".pdf";
            AppendLog($"[成功] PDF 下载完成 ({pdfData.Length} bytes)，文件名: {pdfFileName}");

            // 3. 上传到 Jira（使用 OA 页面标题作为文件名）
            await JiraService.Shared.UploadAttachmentAsync(REQNumber, pdfFileName, pdfData, "application/pdf");
            AppendLog($"[成功] PDF 已上传到 Jira: {REQNumber}/{pdfFileName}");

            // 4. 如果关联REQ不为空，将关联REQ链接到主REQ（已关联则跳过）
            var related = RelatedREQ?.Trim() ?? "";
            if (!string.IsNullOrEmpty(related))
            {
                // 获取主REQ已有的issuelinks
                var existingLinkedKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    var raw = await JiraService.Shared.GetIssueRawAsync(REQNumber);
                    if (raw["fields"] is JObject fields && fields["issuelinks"] is JArray links)
                    {
                        foreach (var issueLink in links)
                        {
                            var outwardKey = issueLink["outwardIssue"]?["key"]?.ToString();
                            if (!string.IsNullOrEmpty(outwardKey)) existingLinkedKeys.Add(outwardKey);
                            var inwardKey = issueLink["inwardIssue"]?["key"]?.ToString();
                            if (!string.IsNullOrEmpty(inwardKey)) existingLinkedKeys.Add(inwardKey);
                        }
                    }
                }
                catch (Exception ex)
                {
                    AppendLog($"[调试] 获取主REQ关联信息失败: {ex.Message}，将尝试全部关联");
                }
                var relatedReqs = related.Split(',', StringSplitOptions.RemoveEmptyEntries)
                    .Select(s => s.Trim())
                    .Where(s => !string.IsNullOrEmpty(s));
                foreach (var relatedReq in relatedReqs)
                {
                    if (existingLinkedKeys.Contains(relatedReq))
                    {
                        AppendLog($"[跳过] {relatedReq} 已与 {REQNumber} 关联");
                        continue;
                    }
                    try
                    {
                        await JiraService.Shared.LinkIssuesAsync(REQNumber, relatedReq, "关联");
                        AppendLog($"[成功] 已关联 REQ: {relatedReq} → {REQNumber}");
                    }
                    catch (Exception linkEx)
                    {
                        AppendLog($"[警告] 关联 {relatedReq} 失败: {linkEx.Message}");
                    }
                }
            }
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] {ex.Message}");
        }
        finally
        {
            _isDownloadingPDF = false;
            UpdateDownloadButtonState();
        }
    }

    // MARK: - Helpers

    private void ClearLogBtn_Click(object sender, RoutedEventArgs e)
    {
        Logs = "";
    }

    private void AppendLog(string line)
    {
        var ts = DateTime.Now.ToString("HH:mm:ss");
        Logs += $"[{ts}] {line}\n";
    }

    private static string ExtractBaseURL(string link)
    {
        try
        {
            var uri = new Uri(link);
            return $"https://{uri.Host}" + (uri.IsDefaultPort ? "" : $":{uri.Port}");
        }
        catch
        {
            return link;
        }
    }

    /// <summary>构造审批日志 AJAX URL</summary>
    private static string? BuildAuditNoteURL(string html, string baseURL)
    {
        // 预处理：折叠 JS 多行字符串拼接 'xxx' + 'yyy' → 'xxxyyy'，以支持跨行 URL
        var collapsed = Regex.Replace(html, @"'\s*\+\s*'", "");

        var match = Regex.Match(collapsed,
            @"lbpmAuditNote\.do\?method=listNote[^""']*[&?]fdModelId=([a-f0-9]+)[^""'\s]*[&?]fdModelName=([^&""'\s]+)[^""'\s]*[&?]formBeanName=([^&""'\s]+)",
            RegexOptions.IgnoreCase);
        if (!match.Success) return null;

        var fdModelId = match.Groups[1].Value;
        var fdModelName = match.Groups[2].Value;
        var formBeanName = match.Groups[3].Value;
        var baseClean = baseURL.TrimEnd('/');
        return $"{baseClean}/sys/lbpmservice/support/lbpm_audit_note/lbpmAuditNote.do?method=listNote&fdModelId={fdModelId}&fdModelName={fdModelName}&formBeanName={formBeanName}&showPersonal=true&approveType=";
    }

    /// <summary>保存 HTML 调试快照</summary>
    private static string? DumpDebugHTML(string html, string link)
    {
        try
        {
            var dir = Path.Combine(AppConfig.AppDataDir, "oa_debug");
            Directory.CreateDirectory(dir);
            var fileName = $"oa_debug_complete_{DateTime.Now:yyyyMMdd_HHmmss}.html";
            var filePath = Path.Combine(dir, fileName);
            var withHeader = $"<!-- source: {link} -->\n" + html;
            File.WriteAllText(filePath, withHeader, System.Text.Encoding.UTF8);
            return filePath;
        }
        catch
        {
            return null;
        }
    }
}
