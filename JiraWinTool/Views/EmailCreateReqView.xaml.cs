using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>
/// 邮件创建 REQ 视图：解析 .eml 邮件文件，映射到 OA REQ 字段并创建
/// </summary>
public partial class EmailCreateReqView : UserControl, INotifyPropertyChanged
{
    // MARK: - 附件展示模型

    public class EmailAttachmentDisplay : INotifyPropertyChanged
    {
        public EmailAttachment Attachment { get; }
        public string Name => Attachment.Name;
        public string SizeDisplay => FormatSize(Attachment.Data.Length);

        private bool _isSelected = true;
        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; OnPropertyChanged(); }
        }

        public EmailAttachmentDisplay(EmailAttachment attachment, bool isSelected = true)
        {
            Attachment = attachment;
            _isSelected = isSelected;
        }

        private static string FormatSize(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            return $"{bytes / (1024.0 * 1024.0):F1} MB";
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // MARK: - Dependency Properties

    public static readonly DependencyProperty EmlFilePathProperty =
        DependencyProperty.Register(nameof(EmlFilePath), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("", (d, _) => ((EmailCreateReqView)d).OnPropertyChanged(nameof(EmlFilePath))));

    public static readonly DependencyProperty TemplateReqKeyProperty =
        DependencyProperty.Register(nameof(TemplateReqKey), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("REQ-23963"));

    public static readonly DependencyProperty ParseTitleProperty =
        DependencyProperty.Register(nameof(ParseTitle), typeof(string), typeof(EmailCreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseSenderProperty =
        DependencyProperty.Register(nameof(ParseSender), typeof(string), typeof(EmailCreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseSenderEmailProperty =
        DependencyProperty.Register(nameof(ParseSenderEmail), typeof(string), typeof(EmailCreateReqView), new PropertyMetadata(""));

    public static readonly DependencyProperty ParseContentProperty =
        DependencyProperty.Register(nameof(ParseContent), typeof(string), typeof(EmailCreateReqView), new PropertyMetadata(""));

    // MARK: - 固定字段（可修改保存）

    public static readonly DependencyProperty FixedSystemParentProperty =
        DependencyProperty.Register(nameof(FixedSystemParent), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("核心条线", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_system_parent", ((EmailCreateReqView)d).FixedSystemParent)));

    public static readonly DependencyProperty FixedSystemChildProperty =
        DependencyProperty.Register(nameof(FixedSystemChild), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("产品工厂", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_system_child", ((EmailCreateReqView)d).FixedSystemChild)));

    public static readonly DependencyProperty FixedDutyDeptProperty =
        DependencyProperty.Register(nameof(FixedDutyDept), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("承保开发室", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_duty_dept", ((EmailCreateReqView)d).FixedDutyDept)));

    public static readonly DependencyProperty FixedBranchCompanyProperty =
        DependencyProperty.Register(nameof(FixedBranchCompany), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("总公司", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_branch_company", ((EmailCreateReqView)d).FixedBranchCompany)));

    public static readonly DependencyProperty FixedGroupNameProperty =
        DependencyProperty.Register(nameof(FixedGroupName), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_group_name", ((EmailCreateReqView)d).FixedGroupName)));

    public static readonly DependencyProperty FixedIsCopyReqProperty =
        DependencyProperty.Register(nameof(FixedIsCopyReq), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("否", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_is_copy_req", ((EmailCreateReqView)d).FixedIsCopyReq)));

    public static readonly DependencyProperty FixedIsComplexReqProperty =
        DependencyProperty.Register(nameof(FixedIsComplexReq), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("否", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_is_complex_req", ((EmailCreateReqView)d).FixedIsComplexReq)));

    public static readonly DependencyProperty FixedReqCategoryProperty =
        DependencyProperty.Register(nameof(FixedReqCategory), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("产品", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_req_category", ((EmailCreateReqView)d).FixedReqCategory)));

    public static readonly DependencyProperty FixedIsPricingProperty =
        DependencyProperty.Register(nameof(FixedIsPricing), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("是", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_is_pricing", ((EmailCreateReqView)d).FixedIsPricing)));

    public static readonly DependencyProperty FixedLabelsProperty =
        DependencyProperty.Register(nameof(FixedLabels), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("计价", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_labels", ((EmailCreateReqView)d).FixedLabels)));

    public static readonly DependencyProperty FixedAssigneeProperty =
        DependencyProperty.Register(nameof(FixedAssignee), typeof(string), typeof(EmailCreateReqView),
            new PropertyMetadata("", (d, _) => ((EmailCreateReqView)d).SaveFixedField("email_fixed_assignee", ((EmailCreateReqView)d).FixedAssignee)));

    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(EmailCreateReqView), new PropertyMetadata(""));

    public string EmlFilePath { get => (string)GetValue(EmlFilePathProperty); set => SetValue(EmlFilePathProperty, value); }
    public string TemplateReqKey { get => (string)GetValue(TemplateReqKeyProperty); set => SetValue(TemplateReqKeyProperty, value); }
    public string ParseTitle { get => (string)GetValue(ParseTitleProperty); set => SetValue(ParseTitleProperty, value); }
    public string ParseSender { get => (string)GetValue(ParseSenderProperty); set => SetValue(ParseSenderProperty, value); }
    public string ParseSenderEmail { get => (string)GetValue(ParseSenderEmailProperty); set => SetValue(ParseSenderEmailProperty, value); }
    public string ParseContent { get => (string)GetValue(ParseContentProperty); set => SetValue(ParseContentProperty, value); }
    public string FixedSystemParent { get => (string)GetValue(FixedSystemParentProperty); set => SetValue(FixedSystemParentProperty, value); }
    public string FixedSystemChild { get => (string)GetValue(FixedSystemChildProperty); set => SetValue(FixedSystemChildProperty, value); }
    public string FixedDutyDept { get => (string)GetValue(FixedDutyDeptProperty); set => SetValue(FixedDutyDeptProperty, value); }
    public string FixedBranchCompany { get => (string)GetValue(FixedBranchCompanyProperty); set => SetValue(FixedBranchCompanyProperty, value); }
    public string FixedGroupName { get => (string)GetValue(FixedGroupNameProperty); set => SetValue(FixedGroupNameProperty, value); }
    public string FixedIsCopyReq { get => (string)GetValue(FixedIsCopyReqProperty); set => SetValue(FixedIsCopyReqProperty, value); }
    public string FixedIsComplexReq { get => (string)GetValue(FixedIsComplexReqProperty); set => SetValue(FixedIsComplexReqProperty, value); }
    public string FixedReqCategory { get => (string)GetValue(FixedReqCategoryProperty); set => SetValue(FixedReqCategoryProperty, value); }
    public string FixedIsPricing { get => (string)GetValue(FixedIsPricingProperty); set => SetValue(FixedIsPricingProperty, value); }
    public string FixedLabels { get => (string)GetValue(FixedLabelsProperty); set => SetValue(FixedLabelsProperty, value); }
    public string FixedAssignee { get => (string)GetValue(FixedAssigneeProperty); set => SetValue(FixedAssigneeProperty, value); }
    public string Logs { get => (string)GetValue(LogsProperty); set => SetValue(LogsProperty, value); }

    // MARK: - State

    private readonly List<EmailAttachmentDisplay> _attachmentDisplays = new();
    private EmailParseResult? _parsedEmail;
    private bool _isCreating;
    private string? _createdKey;

    public EmailCreateReqView()
    {
        InitializeComponent();

        // 恢复已保存的模板 REQ Key
        var savedTemplate = AppConfig.Shared.GetCustom("email_template_req_key");
        if (!string.IsNullOrEmpty(savedTemplate))
            TemplateReqKey = savedTemplate;
        else
        {
            var oaTemplate = AppConfig.Shared.GetCustom("oa_template_req_key");
            if (!string.IsNullOrEmpty(oaTemplate))
                TemplateReqKey = oaTemplate;
        }

        // 恢复已保存的固定字段
        LoadFixedField("email_fixed_system_parent", v => FixedSystemParent = v);
        LoadFixedField("email_fixed_system_child", v => FixedSystemChild = v);
        LoadFixedField("email_fixed_duty_dept", v => FixedDutyDept = v);
        LoadFixedField("email_fixed_branch_company", v => FixedBranchCompany = v);
        LoadFixedField("email_fixed_is_copy_req", v => FixedIsCopyReq = v);
        LoadFixedField("email_fixed_is_complex_req", v => FixedIsComplexReq = v);
        LoadFixedField("email_fixed_req_category", v => FixedReqCategory = v);
        LoadFixedField("email_fixed_is_pricing", v => FixedIsPricing = v);
        LoadFixedField("email_fixed_labels", v => FixedLabels = v);

        // 经办人：优先读取已保存值，否则使用当前登录账号
        var savedAssignee = AppConfig.Shared.GetCustom("email_fixed_assignee");
        if (string.IsNullOrEmpty(savedAssignee))
            savedAssignee = AppConfig.Shared.GetCustom("oa_fixed_assignee");
        FixedAssignee = !string.IsNullOrEmpty(savedAssignee) ? savedAssignee : AppConfig.Shared.JiraUser;
    }

    // MARK: - INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: - Browse & Parse Actions

    private void BrowseBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "邮件文件 (*.eml)|*.eml|所有文件 (*.*)|*.*",
            Title = "选择邮件文件"
        };
        if (dlg.ShowDialog() == true)
        {
            EmlFilePath = dlg.FileName;
        }
    }

    private void ParseBtn_Click(object sender, RoutedEventArgs e)
    {
        var filePath = EmlFilePath.Trim();
        if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath))
        {
            AppendLog("[错误] 请先选择有效的 .eml 文件");
            return;
        }

        AppendLog($"开始解析邮件：{filePath}");

        try
        {
            var parsed = EmailParser.ParseFromFile(filePath);
            _parsedEmail = parsed;

            // 更新 UI
            ParseTitle = parsed.Subject;
            ParseSender = parsed.FromName;
            ParseSenderEmail = parsed.From;
            ParseContent = parsed.Body;

            // 更新附件列表
            _attachmentDisplays.Clear();
            foreach (var att in parsed.Attachments)
            {
                _attachmentDisplays.Add(new EmailAttachmentDisplay(att, true));
            }
            RefreshAttachmentList();

            AppendLog($"解析完成：标题={parsed.Subject}；发件人={parsed.FromName}；邮箱={parsed.From}；附件 {parsed.Attachments.Count} 个");
            if (string.IsNullOrEmpty(parsed.Subject) && string.IsNullOrEmpty(parsed.FromName))
                AppendLog("[警告] 主要字段为空，请手工填写或检查邮件文件格式。");
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] 解析邮件失败：{ex.Message}");
        }
    }

    // MARK: - Create Action

    private async void CreateBtn_Click(object sender, RoutedEventArgs e)
    {
        var tpl = TemplateReqKey.Trim();
        if (string.IsNullOrEmpty(tpl))
        {
            AppendLog("[错误] 请先填写模板 REQ");
            return;
        }
        if (_parsedEmail == null)
        {
            AppendLog("[错误] 请先解析邮件");
            return;
        }
        if (_isCreating) return;

        // 保存模板 REQ Key
        AppConfig.Shared.SetCustom("email_template_req_key", tpl);

        _isCreating = true;
        CreateBtn.IsEnabled = false;
        CreateProgress.Text = "创建中...";
        AppendLog("开始创建 REQ ...");

        // 构造 OAParseResult 以复用 OACreateReqService
        var parsed = new OAParseResult
        {
            Title = ParseTitle,
            Drafter = ParseSender,
            DraftDept = "",
            Content = ParseContent,
            ApplyNo = "",
            RemKeys = new List<string>(),
            Attachments = new List<OAAttachment>()
        };

        // 获取勾选的邮件附件
        var pickedAttachments = _attachmentDisplays
            .Where(a => a.IsSelected)
            .Select(a => a.Attachment)
            .ToList();

        // 签报链接使用发件人邮箱作为标识
        var oaLink = $"mailto:{ParseSenderEmail}";

        try
        {
            var key = await OACreateReqService.Shared.CreateFromOAAsync(
                oaLink, tpl, parsed, new List<OAAttachment>(), "",
                FixedSystemParent, FixedSystemChild,
                FixedDutyDept,
                FixedBranchCompany,
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

            // 上传邮件附件（不走 OA 下载流程，直接上传本地附件）
            if (pickedAttachments.Count > 0)
            {
                AppendLog($"上传邮件附件 {pickedAttachments.Count} 个 ...");
                foreach (var att in pickedAttachments)
                {
                    try
                    {
                        await JiraService.Shared.UploadAttachmentAsync(
                            key, att.Name, att.Data, att.MimeType);
                        AppendLog($"  ✓ 已上传: {att.Name}");
                    }
                    catch (Exception ex)
                    {
                        AppendLog($"  ✗ 附件失败 [{att.Name}]: {ex.Message}");
                    }
                }
            }

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
        var newList = new List<EmailAttachmentDisplay>(_attachmentDisplays);
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
