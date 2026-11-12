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

    /// <summary>评估人：审批日志中该操作人的处理意见携带内/外部人力</summary>
    public static readonly DependencyProperty EvaluatorProperty =
        DependencyProperty.Register(nameof(Evaluator), typeof(string), typeof(OACreateReqView),
            new PropertyMetadata("吴润龙", (d, _) => ((OACreateReqView)d).SaveFixedField("oa_evaluator", ((OACreateReqView)d).Evaluator)));

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

    public static readonly DependencyProperty ParseReqEvalLinkProperty =
        DependencyProperty.Register(nameof(ParseReqEvalLink), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseInnerManpowerProperty =
        DependencyProperty.Register(nameof(ParseInnerManpower), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseExternalManpowerProperty =
        DependencyProperty.Register(nameof(ParseExternalManpower), typeof(string), typeof(OACreateReqView), new PropertyMetadata(""));

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
    public string Evaluator { get => (string)GetValue(EvaluatorProperty); set => SetValue(EvaluatorProperty, value); }
    public string ParseTitle { get => (string)GetValue(ParseTitleProperty); set => SetValue(ParseTitleProperty, value); }
    public string ParseDrafter { get => (string)GetValue(ParseDrafterProperty); set => SetValue(ParseDrafterProperty, value); }
    public string ParseDraftDeptOriginal { get => (string)GetValue(ParseDraftDeptOriginalProperty); set => SetValue(ParseDraftDeptOriginalProperty, value); }
    public string ParseDraftDeptKeyword { get => (string)GetValue(ParseDraftDeptKeywordProperty); set => SetValue(ParseDraftDeptKeywordProperty, value); }
    public string ParseBranchCompany { get => (string)GetValue(ParseBranchCompanyProperty); set => SetValue(ParseBranchCompanyProperty, value); }
    public string ParseApplyNo { get => (string)GetValue(ParseApplyNoProperty); set => SetValue(ParseApplyNoProperty, value); }
    public string ParseRemText { get => (string)GetValue(ParseRemTextProperty); set => SetValue(ParseRemTextProperty, value); }
    public string ParseReqEvalLink { get => (string)GetValue(ParseReqEvalLinkProperty); set => SetValue(ParseReqEvalLinkProperty, value); }
    public string ParseInnerManpower { get => (string)GetValue(ParseInnerManpowerProperty); set => SetValue(ParseInnerManpowerProperty, value); }
    public string ParseExternalManpower { get => (string)GetValue(ParseExternalManpowerProperty); set => SetValue(ParseExternalManpowerProperty, value); }
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
    private int _snapshotCount;

    public OACreateReqView()
    {
        InitializeComponent();

        // 恢复已保存的模板 REQ Key
        var savedTemplate = AppConfig.Shared.GetCustom("oa_template_req_key");
        if (!string.IsNullOrEmpty(savedTemplate))
            TemplateReqKey = savedTemplate;

        // 恢复已保存的评估人
        LoadFixedField("oa_evaluator", v => Evaluator = v);

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
        AppendLog($"开始解析：fdId={ShortDocId(link)}");
        _snapshotCount = 0;

        try
        {
            var html = await OAService.Shared.FetchHTMLAsync(link);
            // 保存调试快照（只计数，不逐份打日志）
            if (DumpDebugHTML(html, link) != null) _snapshotCount++;

            var baseURL = ExtractBaseURL(link);
            var parsed = OAParser.Parse(html, baseURL);

            // 额外抓取审批日志 AJAX 以提取 REM 号
            string? mainAuditHTML = null;
            if (parsed.RemKeys.Count == 0)
            {
                var auditURL = BuildAuditNoteURL(html, baseURL);
                if (auditURL != null)
                {
                    try
                    {
                        var auditHTML = await OAService.Shared.FetchHTMLAsync(auditURL);
                        mainAuditHTML = auditHTML;
                        if (DumpDebugHTML(auditHTML, auditURL) != null) _snapshotCount++;

                        var extraREM = OAParser.ExtractREMFromAuditNotes(auditHTML);
                        if (extraREM.Count > 0)
                        {
                            // REM 号由下方的『解析完成』行统一展示，不单独占一行
                            parsed.RemKeys = extraREM;
                        }

                        // 解析审批日志中的附件并合并
                        var auditAttachments = OAParser.ParseAttachments(auditHTML, baseURL);
                        if (auditAttachments.Count > 0)
                        {
                            // 同一份文件在表单页和审批日志页的 FdId 不同（挂载关系各自一条），
                            // 必须按文件实体 DedupKey 去重，否则 Jira 会挂两份重复附件
                            var existingKeys = new HashSet<string>(parsed.Attachments.Select(a => a.DedupKey));
                            var extra = auditAttachments.Where(a => !existingKeys.Contains(a.DedupKey)).ToList();
                            if (extra.Count > 0)
                            {
                                parsed.Attachments.AddRange(extra);
                                AppendLog($"[调试] 审批日志补充附件 {extra.Count} 个");
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
            // 提交部门：优先使用总公司牵头部门，如果没有则从拟稿部门派生
            if (!string.IsNullOrEmpty(parsed.LeadDept))
            {
                ParseDraftDeptKeyword = DeriveDeptKeyword(parsed.LeadDept);
            }
            else
            {
                ParseDraftDeptKeyword = DeriveDeptKeyword(parsed.DraftDept);
            }
            ParseBranchCompany = DeriveBranchCompany(parsed.DraftDept);
            ParseApplyNo = parsed.ApplyNo;
            // 需求评估 OA 页面：『预估产能/产出』拼到申请内容最前面，评估人处理意见中解析内/外部人力
            var evalInfo = await FetchReqEvalInfoAsync(parsed, html, baseURL, mainAuditHTML);
            var content = parsed.Content;
            if (!string.IsNullOrEmpty(evalInfo.Capacity) && !content.Contains(evalInfo.Capacity))
                content = $"预估产能/产出：{evalInfo.Capacity}\n{content}";
            ParseContent = content;
            ParseRemText = string.Join(",", parsed.RemKeys);
            ParseReqEvalLink = parsed.ReqEvalOALink;
            ParseInnerManpower = evalInfo.Inner;
            ParseExternalManpower = evalInfo.Outer;
            _parsedAttachments = parsed.Attachments;

            // 更新附件列表
            _attachmentDisplays.Clear();
            foreach (var att in parsed.Attachments)
            {
                _attachmentDisplays.Add(new AttachmentDisplay(att, !att.IsTemplateAttachment));
            }
            RefreshAttachmentList();

            AppendLog($"解析完成：提交部门={ParseDraftDeptKeyword}；分公司={ParseBranchCompany}；REM={string.Join(",", parsed.RemKeys)}；附件 {parsed.Attachments.Count} 个");
            AppendLog(DescribeReqEval(evalInfo));
            if (_snapshotCount > 0)
                AppendLog($"[调试] 已保存 HTML 快照 {_snapshotCount} 份");
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

    /// <summary>抓取『需求评估OA链接』对应的 OA 页面：解析『预估产能/产出』，并从审批日志中
    /// 评估人所在行的处理意见里解析内部/外部人力；
    /// 若未关联需求评估签报（录入的就是需求评估页面本身），则回退到当前页面。
    /// 过程不逐行记日志，Note 为空表示一切正常，由 DescribeReqEval 统一输出一行</summary>
    private async Task<(string Capacity, string Inner, string Outer, string Note)> FetchReqEvalInfoAsync(
        OAParseResult parsed, string html, string baseURL, string? mainAuditHTML)
    {
        var evalLink = parsed.ReqEvalOALink.Trim();
        var formHTML = html;
        var pageBaseURL = baseURL;
        var auditHTML = mainAuditHTML ?? "";
        var note = "";

        if (string.IsNullOrEmpty(evalLink))
        {
            note = "未关联评估签报，按当前页解析";
        }
        else
        {
            try
            {
                formHTML = await OAService.Shared.FetchHTMLAsync(evalLink);
                if (DumpDebugHTML(formHTML, evalLink, "eval") != null) _snapshotCount++;
                pageBaseURL = ExtractBaseURL(evalLink);
                auditHTML = "";
            }
            catch (Exception ex)
            {
                return ("", "", "", $"抓取需求评估页面失败：{ex.Message}");
            }
        }

        var capacity = OAParser.ExtractEstimatedCapacity(formHTML);

        var evaluatorName = Evaluator.Trim();
        if (string.IsNullOrEmpty(evaluatorName))
            return (capacity, "", "", "评估人为空");

        // 评估人的内/外部人力位于审批日志（流程轨迹）的处理意见列
        if (string.IsNullOrEmpty(auditHTML))
        {
            var auditURL = BuildAuditNoteURL(formHTML, pageBaseURL);
            if (auditURL != null)
            {
                try
                {
                    auditHTML = await OAService.Shared.FetchHTMLAsync(auditURL);
                    if (DumpDebugHTML(auditHTML, auditURL, string.IsNullOrEmpty(evalLink) ? "audit" : "evalaudit") != null)
                        _snapshotCount++;
                }
                catch (Exception ex)
                {
                    note = $"抓取审批日志失败：{ex.Message}";
                }
            }
        }
        if (string.IsNullOrEmpty(auditHTML))
            return (capacity, "", "", string.IsNullOrEmpty(note) ? "未取得审批日志" : note);

        var (inner, outer) = OAParser.ExtractManpowerByOperator(auditHTML, evaluatorName);
        if (string.IsNullOrEmpty(inner) && string.IsNullOrEmpty(outer))
            note = "评估人处理意见无人力数字";
        return (capacity, inner, outer, note);
    }

    /// <summary>把需求评估抓取结果（预估产能/产出 + 评估人处理意见中的内/外部人力）汇成一行日志</summary>
    private string DescribeReqEval((string Capacity, string Inner, string Outer, string Note) info)
    {
        var ev = Evaluator.Trim();
        var line = $"需求评估：产能={(string.IsNullOrEmpty(info.Capacity) ? "未解析" : info.Capacity)}"
            + $"；人力 内={(string.IsNullOrEmpty(info.Inner) ? "-" : info.Inner)}"
            + $" 外={(string.IsNullOrEmpty(info.Outer) ? "-" : info.Outer)} 人/天"
            + $"（评估人：{(string.IsNullOrEmpty(ev) ? "未填" : ev)}";
        if (!string.IsNullOrEmpty(ParseReqEvalLink)) line += $"，fdId={ShortDocId(ParseReqEvalLink)}";
        line += "）";
        if (!string.IsNullOrEmpty(info.Note)) line += $" [提示] {info.Note}";
        return line;
    }

    /// <summary>取 OA 链接里的 fdId 前 12 位作为日志短标识（完整链接见页面上的对应字段）</summary>
    private static string ShortDocId(string url)
    {
        var m = System.Text.RegularExpressions.Regex.Match(url, @"fdId=([a-f0-9]{1,12})", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value : "?";
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
            Attachments = _parsedAttachments,
            ReqEvalOALink = ParseReqEvalLink.Trim(),
            InnerManpower = ParseInnerManpower.Trim(),
            ExternalManpower = ParseExternalManpower.Trim()
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
    private static string? DumpDebugHTML(string html, string link, string kind = "")
    {
        try
        {
            var dir = Path.Combine(AppConfig.AppDataDir, "oa_debug");
            Directory.CreateDirectory(dir);
            var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var fileName = string.IsNullOrEmpty(kind) ? $"oa_debug_{stamp}.html" : $"oa_debug_{kind}_{stamp}.html";
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
