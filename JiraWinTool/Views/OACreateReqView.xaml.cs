using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>
/// OA 创建 REQ 视图（移植自 Swift OACreateReqView.swift）
/// </summary>
public partial class OACreateReqView : UserControl, INotifyPropertyChanged
{
    // MARK: - Attachments display model

    public class AttachmentDisplay : INotifyPropertyChanged
    {
        public OAAttachment Attachment { get; }
        public string Name => Attachment.Name;
        public string Url => Attachment.Url;

        private bool _isSelected = true;
        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; OnPropertyChanged(); }
        }

        public AttachmentDisplay(OAAttachment attachment, bool isSelected)
        {
            Attachment = attachment;
            _isSelected = isSelected;
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // MARK: - Dependency properties

    public static readonly DependencyProperty OALinkProperty =
        DependencyProperty.Register(nameof(OALink), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("", (d, _) => ((OACreateReqView)d).OnPropertyChanged(nameof(OALink))));

    public static readonly DependencyProperty TemplateReqKeyProperty =
        DependencyProperty.Register(nameof(TemplateReqKey), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("REQ-23963"));

    public static readonly DependencyProperty ParseTitleProperty =
        DependencyProperty.Register(nameof(ParseTitle), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseDrafterProperty =
        DependencyProperty.Register(nameof(ParseDrafter), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseDraftDeptOriginalProperty =
        DependencyProperty.Register(nameof(ParseDraftDeptOriginal), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseDraftDeptKeywordProperty =
        DependencyProperty.Register(nameof(ParseDraftDeptKeyword), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseBranchCompanyProperty =
        DependencyProperty.Register(nameof(ParseBranchCompany), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseApplyNoProperty =
        DependencyProperty.Register(nameof(ParseApplyNo), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseRemTextProperty =
        DependencyProperty.Register(nameof(ParseRemText), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseContentProperty =
        DependencyProperty.Register(nameof(ParseContent), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    // MARK: - 固定字段（可修改保存）

    public static readonly DependencyProperty FixedSystemParentProperty =
        DependencyProperty.Register(nameof(FixedSystemParent), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("核心条线", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_system_parent", ((OACreateReqView)d).FixedSystemParent)));

    public static readonly DependencyProperty FixedSystemChildProperty =
        DependencyProperty.Register(nameof(FixedSystemChild), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("新一代非车险承保核心系统", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_system_child", ((OACreateReqView)d).FixedSystemChild)));

    // 单选项状态
    public static readonly DependencyProperty IsSystemChild1CheckedProperty =
        DependencyProperty.Register(nameof(IsSystemChild1Checked), typeof(bool), typeof(OACreateReqView), new PropertyMetadata(true));
    public static readonly DependencyProperty IsSystemChild2CheckedProperty =
        DependencyProperty.Register(nameof(IsSystemChild2Checked), typeof(bool), typeof(OACreateReqView), new PropertyMetadata(false));
    public static readonly DependencyProperty IsSystemChildCustomCheckedProperty =
        DependencyProperty.Register(nameof(IsSystemChildCustomChecked), typeof(bool), typeof(OACreateReqView), new PropertyMetadata(false));

    public static readonly DependencyProperty FixedDevVersionProperty =
        DependencyProperty.Register(nameof(FixedDevVersion), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_dev_version", ((OACreateReqView)d).FixedDevVersion)));

    public static readonly DependencyProperty FixedDutyDeptProperty =
        DependencyProperty.Register(nameof(FixedDutyDept), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("承保开发室", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_duty_dept", ((OACreateReqView)d).FixedDutyDept)));

    public static readonly DependencyProperty FixedGroupNameProperty =
        DependencyProperty.Register(nameof(FixedGroupName), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_group_name", ((OACreateReqView)d).FixedGroupName)));

    public static readonly DependencyProperty FixedIsCopyReqProperty =
        DependencyProperty.Register(nameof(FixedIsCopyReq), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("否", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_is_copy_req", ((OACreateReqView)d).FixedIsCopyReq)));

    public static readonly DependencyProperty FixedIsComplexReqProperty =
        DependencyProperty.Register(nameof(FixedIsComplexReq), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("否", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_is_complex_req", ((OACreateReqView)d).FixedIsComplexReq)));

    public static readonly DependencyProperty FixedReqCategoryProperty =
        DependencyProperty.Register(nameof(FixedReqCategory), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("产品", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_req_category", ((OACreateReqView)d).FixedReqCategory)));

    public static readonly DependencyProperty FixedIsPricingProperty =
        DependencyProperty.Register(nameof(FixedIsPricing), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("是", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_is_pricing", ((OACreateReqView)d).FixedIsPricing)));

    public static readonly DependencyProperty FixedLabelsProperty =
        DependencyProperty.Register(nameof(FixedLabels), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("计价", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_labels", ((OACreateReqView)d).FixedLabels)));

    public static readonly DependencyProperty FixedAssigneeProperty =
        DependencyProperty.Register(nameof(FixedAssignee), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_fixed_assignee", ((OACreateReqView)d).FixedAssignee)));

    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public string OALink { get => (string)GetValue(OALinkProperty); set => SetValue(OALinkProperty, value); }
    public string TemplateReqKey { get => (string)GetValue(TemplateReqKeyProperty); set => SetValue(TemplateReqKeyProperty, value); }
    public string ParseTitle { get => (string)GetValue(ParseTitleProperty); set => SetValue(ParseTitleProperty, value); }
    public string ParseDrafter { get => (string)GetValue(ParseDrafterProperty); set => SetValue(ParseDrafterProperty, value); }
    public string ParseDraftDeptOriginal { get => (string)GetValue(ParseDraftDeptOriginalProperty); set => SetValue(ParseDraftDeptOriginalProperty, value); }
    public string ParseDraftDeptKeyword { get => (string)GetValue(ParseDraftDeptKeywordProperty); set => SetValue(ParseDraftDeptKeywordProperty, value); }
    public string ParseBranchCompany { get => (string)GetValue(ParseBranchCompanyProperty); set => SetValue(ParseBranchCompanyProperty, value); }
    public string ParseApplyNo { get => (string)GetValue(ParseApplyNoProperty); set => SetValue(ParseApplyNoProperty, value); }
    public string ParseRemText { get => (string)GetValue(ParseRemTextProperty); set => SetValue(ParseRemTextProperty, value); }
    public string ParseContent { get => (string)GetValue(ParseContentProperty); set => SetValue(ParseContentProperty, value); }
    public string FixedSystemParent { get => (string)GetValue(FixedSystemParentProperty); set => SetValue(FixedSystemParentProperty, value); }
    public string FixedSystemChild { get => (string)GetValue(FixedSystemChildProperty); set => SetValue(FixedSystemChildProperty, value); }
    public bool IsSystemChild1Checked { get => (bool)GetValue(IsSystemChild1CheckedProperty); set => SetValue(IsSystemChild1CheckedProperty, value); }
    public bool IsSystemChild2Checked { get => (bool)GetValue(IsSystemChild2CheckedProperty); set => SetValue(IsSystemChild2CheckedProperty, value); }
    public bool IsSystemChildCustomChecked { get => (bool)GetValue(IsSystemChildCustomCheckedProperty); set => SetValue(IsSystemChildCustomCheckedProperty, value); }
    public string FixedDevVersion { get => (string)GetValue(FixedDevVersionProperty); set => SetValue(FixedDevVersionProperty, value); }
    public string FixedDutyDept { get => (string)GetValue(FixedDutyDeptProperty); set => SetValue(FixedDutyDeptProperty, value); }
    public string FixedGroupName { get => (string)GetValue(FixedGroupNameProperty); set => SetValue(FixedGroupNameProperty, value); }
    public string FixedIsCopyReq { get => (string)GetValue(FixedIsCopyReqProperty); set => SetValue(FixedIsCopyReqProperty, value); }
    public string FixedIsComplexReq { get => (string)GetValue(FixedIsComplexReqProperty); set => SetValue(FixedIsComplexReqProperty, value); }
    public string FixedReqCategory { get => (string)GetValue(FixedReqCategoryProperty); set => SetValue(FixedReqCategoryProperty, value); }
    public string FixedIsPricing { get => (string)GetValue(FixedIsPricingProperty); set => SetValue(FixedIsPricingProperty, value); }
    public string FixedLabels { get => (string)GetValue(FixedLabelsProperty); set => SetValue(FixedLabelsProperty, value); }
    public string FixedAssignee { get => (string)GetValue(FixedAssigneeProperty); set => SetValue(FixedAssigneeProperty, value); }
    public string Logs { get => (string)GetValue(LogsProperty); set => SetValue(LogsProperty, value); }

    // MARK: - State

    private readonly List<AttachmentDisplay> _attachmentDisplays = new();
    private bool _isParsing;
    private bool _isCreating;
    private string? _createdKey;
    private List<OAAttachment> _parsedAttachments = new();

    public OACreateReqView()
    {
        InitializeComponent();

        // 恢复已保存的模板 REQ Key
        var savedTemplate = AppConfig.Shared.GetCustom("oa_template_req_key");
        if (!string.IsNullOrEmpty(savedTemplate))
            TemplateReqKey = savedTemplate;

        // 恢复已保存的固定字段
        LoadFixedField("oa_fixed_system_parent", v => FixedSystemParent = v);
        LoadFixedField("oa_fixed_system_child", v => FixedSystemChild = v);
        LoadFixedField("oa_fixed_dev_version", v => FixedDevVersion = v);
        LoadFixedField("oa_fixed_duty_dept", v => FixedDutyDept = v);
        LoadFixedField("oa_fixed_is_copy_req", v => FixedIsCopyReq = v);
        LoadFixedField("oa_fixed_is_complex_req", v => FixedIsComplexReq = v);
        LoadFixedField("oa_fixed_req_category", v => FixedReqCategory = v);
        LoadFixedField("oa_fixed_is_pricing", v => FixedIsPricing = v);
        LoadFixedField("oa_fixed_labels", v => FixedLabels = v);

        // 同步单选按钮状态与保存的系统名称子级值
        if (FixedSystemChild == "新一代非车险承保核心系统")
        {
            IsSystemChild1Checked = true;
            IsSystemChild2Checked = false;
            IsSystemChildCustomChecked = false;
        }
        else if (FixedSystemChild == "产品工厂")
        {
            IsSystemChild1Checked = false;
            IsSystemChild2Checked = true;
            IsSystemChildCustomChecked = false;
        }
        else if (!string.IsNullOrEmpty(FixedSystemChild))
        {
            IsSystemChild1Checked = false;
            IsSystemChild2Checked = false;
            IsSystemChildCustomChecked = true;
        }

        // 经办人：优先读取已保存值，否则使用当前登录账号
        var savedAssignee = AppConfig.Shared.GetCustom("oa_fixed_assignee");
        FixedAssignee = !string.IsNullOrEmpty(savedAssignee) ? savedAssignee : AppConfig.Shared.JiraUser;
    }

    // MARK: - 系统名称子级单选项变更

    private void SystemChildRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;  // 初始化时不处理
        
        if (IsSystemChild1Checked)
        {
            FixedSystemChild = "新一代非车险承保核心系统";
            FixedDevVersion = "";  // 新一代非车险承保核心系统默认为空
            // 取消其他选项
            if (IsSystemChild2Checked) IsSystemChild2Checked = false;
            if (IsSystemChildCustomChecked) IsSystemChildCustomChecked = false;
        }
        else if (IsSystemChild2Checked)
        {
            FixedSystemChild = "产品工厂";
            FixedDevVersion = "即时版本（脚本）";  // 产品工厂默认为即时版本（脚本）
            // 取消其他选项
            if (IsSystemChild1Checked) IsSystemChild1Checked = false;
            if (IsSystemChildCustomChecked) IsSystemChildCustomChecked = false;
        }
        else if (IsSystemChildCustomChecked)
        {
            // 自定义模式，不自动填充，让用户手工输入
            if (IsSystemChild1Checked) IsSystemChild1Checked = false;
            if (IsSystemChild2Checked) IsSystemChild2Checked = false;
        }
    }

    // MARK: - INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: - Parse Action

    private async void ParseBtn_Click(object sender, RoutedEventArgs e)
    {
        var link = OALink.Trim();
        if (string.IsNullOrEmpty(link)) return;
        if (_isParsing) return;

        _isParsing = true;
        ParseBtn.IsEnabled = false;
        ParseProgress.Text = "解析中...";
        AppendLog($"开始解析：{link}");

        try
        {
            var html = await OAService.Shared.FetchHTMLAsync(link);
            // 保存调试快照
            var dumpPath = DumpDebugHTML(html, link);
            if (dumpPath != null)
                AppendLog($"[调试] 已保存 HTML 快照：{dumpPath}");

            var baseURL = ExtractBaseURL(link);
            var parsed = OAParser.Parse(html, baseURL);

            // 额外抓取审批日志 AJAX 以提取 REM 号
            if (parsed.RemKeys.Count == 0)
            {
                var auditURL = BuildAuditNoteURL(html, baseURL);
                if (auditURL != null)
                {
                    AppendLog($"[调试] 抓取审批日志：{auditURL}");
                    try
                    {
                        var auditHTML = await OAService.Shared.FetchHTMLAsync(auditURL);
                        var dumpPath2 = DumpDebugHTML(auditHTML, auditURL);
                        if (dumpPath2 != null)
                            AppendLog($"[调试] 已保存审批日志快照：{dumpPath2}");

                        var extraREM = OAParser.ExtractREMFromAuditNotes(auditHTML);
                        if (extraREM.Count > 0)
                        {
                            parsed.RemKeys = extraREM;
                            AppendLog($"[调试] 从审批日志提取到 REM: {string.Join(",", extraREM)}");
                        }

                        // 解析审批日志中的附件并合并
                        var auditAttachments = OAParser.ParseAttachments(auditHTML, baseURL);
                        if (auditAttachments.Count > 0)
                        {
                            var existingFdIds = new HashSet<string>(parsed.Attachments.Select(a => a.FdId));
                            foreach (var att in auditAttachments)
                            {
                                if (!existingFdIds.Contains(att.FdId))
                                {
                                    parsed.Attachments.Add(att);
                                    AppendLog($"[调试] 从审批日志补充附件: {att.Name}");
                                }
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        AppendLog($"[调试] 审批日志抓取失败: {ex.Message}");
                    }
                }
            }

            // 更新 UI
            ParseTitle = parsed.Title;
            ParseDrafter = parsed.Drafter;
            ParseDraftDeptOriginal = parsed.DraftDept;
            ParseDraftDeptKeyword = DeriveDeptKeyword(parsed.DraftDept);
            ParseBranchCompany = DeriveBranchCompany(parsed.DraftDept);
            ParseApplyNo = parsed.ApplyNo;
            ParseContent = parsed.Content;
            ParseRemText = string.Join(",", parsed.RemKeys);
            _parsedAttachments = parsed.Attachments;

            // 更新附件列表
            _attachmentDisplays.Clear();
            foreach (var att in parsed.Attachments)
            {
                _attachmentDisplays.Add(new AttachmentDisplay(att, !att.IsTemplateAttachment));
            }
            RefreshAttachmentList();

            AppendLog($"解析完成：标题={parsed.Title}；拟稿人={parsed.Drafter}；拟稿部门={parsed.DraftDept}；分公司={ParseBranchCompany}；申请单编号={parsed.ApplyNo}；REM={string.Join(",", parsed.RemKeys)}；附件 {parsed.Attachments.Count} 个");
            if (string.IsNullOrEmpty(parsed.Title) && string.IsNullOrEmpty(parsed.Drafter) && string.IsNullOrEmpty(parsed.ApplyNo))
                AppendLog("[警告] 主要字段均为空，可能页面结构不匹配，请手工填写或联系开发优化解析规则。");
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] {ex.Message}");
        }
        finally
        {
            _isParsing = false;
            ParseBtn.IsEnabled = true;
            ParseProgress.Text = "";
        }
    }

    // MARK: - Create Action

    private async void CreateBtn_Click(object sender, RoutedEventArgs e)
    {
        var link = OALink.Trim();
        var tpl = TemplateReqKey.Trim();
        if (string.IsNullOrEmpty(link) || string.IsNullOrEmpty(tpl)) return;
        if (_isCreating) return;

        // 保存模板 REQ Key
        AppConfig.Shared.SetCustom("oa_template_req_key", tpl);

        _isCreating = true;
        CreateBtn.IsEnabled = false;
        CreateProgress.Text = "创建中...";
        AppendLog("开始创建 REQ ...");

        var remKeys = ParseRemText
            .Split(new[] { ',', '，', ';', '；', '\n', '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim().ToUpper())
            .Where(s => !string.IsNullOrEmpty(s))
            .ToList();

        var parsed = new OAParseResult
        {
            Title = ParseTitle,
            Drafter = ParseDrafter,
            DraftDept = ParseDraftDeptOriginal,
            BranchCompany = ParseBranchCompany,
            Content = ParseContent,
            ApplyNo = ParseApplyNo,
            RemKeys = remKeys,
            Attachments = _parsedAttachments
        };

        var picked = _attachmentDisplays
            .Where(a => a.IsSelected)
            .Select(a => a.Attachment)
            .ToList();

        var dept = ParseDraftDeptKeyword.Trim();

        try
        {
            var key = await OACreateReqService.Shared.CreateFromOAAsync(
                link, tpl, parsed, picked, dept,
                FixedSystemParent, FixedSystemChild, FixedDevVersion,
                FixedDutyDept,
                FixedGroupName,
                FixedIsCopyReq, FixedIsComplexReq, FixedReqCategory,
                FixedIsPricing,
                FixedLabels,
                FixedAssignee,
                line => Dispatcher.Invoke(() => AppendLog(line)));

            _createdKey = key;
            AppendLog($"[完成] 新 REQ：{key}");
            OpenBtn.Visibility = Visibility.Visible;
            OpenBtn.Content = $"打开 {key}";

            // 自动打开浏览器
            OpenCreatedIssue();
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] 创建 REQ 失败：{ex.Message}");
        }
        finally
        {
            _isCreating = false;
            CreateBtn.IsEnabled = true;
            CreateProgress.Text = "";
        }
    }

    private void ClearBtn_Click(object sender, RoutedEventArgs e)
    {
        Logs = "";
        _createdKey = null;
        OpenBtn.Visibility = Visibility.Collapsed;
    }

    private void OpenBtn_Click(object sender, RoutedEventArgs e)
    {
        OpenCreatedIssue();
    }

    private void OpenCreatedIssue()
    {
        if (string.IsNullOrEmpty(_createdKey)) return;
        var baseUrl = AppConfig.Shared.JiraURL.TrimEnd('/');
        var url = $"{baseUrl}/browse/{_createdKey}";
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            AppendLog($"[错误] 无法打开浏览器: {ex.Message}");
        }
    }

    // MARK: - Helpers

    private void AppendLog(string line)
    {
        var ts = DateTime.Now.ToString("HH:mm:ss");
        Logs += $"[{ts}] {line}\n";
    }

    private void RefreshAttachmentList()
    {
        // 每次创建新的 List 实例赋给 ItemsSource，确保 WPF ItemsControl 识别到引用变化并重新渲染
        var newList = new List<AttachmentDisplay>(_attachmentDisplays);
        if (newList.Count == 0)
        {
            NoAttachmentHint.Visibility = Visibility.Visible;
            AttachmentList.ItemsSource = null;
            AttachmentList.Visibility = Visibility.Collapsed;
        }
        else
        {
            NoAttachmentHint.Visibility = Visibility.Collapsed;
            AttachmentList.Visibility = Visibility.Visible;
            AttachmentList.ItemsSource = newList;
        }
    }

    /// <summary>从原始拟稿部门抽取关键字（倒数第二段）</summary>
    private static string DeriveDeptKeyword(string raw)
    {
        var trimmed = raw.Trim();
        if (string.IsNullOrEmpty(trimmed)) return "";
    
        var parts = trimmed.Split(new[] { '-', '/', '|', '>', '》', ' ', '\t', ' ', '\\' },
                StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim())
            .Where(p => !string.IsNullOrEmpty(p))
            .ToList();
    
        if (parts.Count >= 2) return parts[parts.Count - 2];
        return parts.LastOrDefault() ?? trimmed;
    }
    
    /// <summary>从原始拟稿部门提取分公司（倒数第三段）</summary>
    /// <example>华安财产保险股份有限公司/总公司/重客渠道部/车商业务室 → 总公司</example>
    private static string DeriveBranchCompany(string raw)
    {
        var trimmed = raw.Trim();
        if (string.IsNullOrEmpty(trimmed)) return "";
    
        var parts = trimmed.Split(new[] { '-', '/', '|', '>', '》', ' ', '\t', ' ', '\\' },
                StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim())
            .Where(p => !string.IsNullOrEmpty(p))
            .ToList();
    
        if (parts.Count >= 3) return parts[parts.Count - 3];
        return "";  // 不足三段时返回空，让用户手工填写
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
            var fileName = $"oa_debug_{DateTime.Now:yyyyMMdd_HHmmss}.html";
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

    /// <summary>持久化固定字段值到 AppConfig</summary>
    private void SaveFixedField(string key, string value)
    {
        AppConfig.Shared.SetCustom(key, value);
    }

    /// <summary>从 AppConfig 加载已保存的固定字段值</summary>
    private void LoadFixedField(string key, Action<string> setter)
    {
        var saved = AppConfig.Shared.GetCustom(key);
        if (!string.IsNullOrEmpty(saved))
            setter(saved);
    }
}
