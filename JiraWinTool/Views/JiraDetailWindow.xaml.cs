using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Views;

/// <summary>Jira 详情对话框（移植自 Swift JiraDetailSheet.swift）</summary>
public partial class JiraDetailWindow : Window
{
    /// <summary>评论行模型</summary>
    private class CommentItem
    {
        public string Author { get; set; } = "";
        public string Created { get; set; } = "";
        public string Body { get; set; } = "";
    }

    /// <summary>附件行模型</summary>
    private partial class AttachmentItem : ObservableObject
    {
        public string Id { get; set; } = "";
        public string Filename { get; set; } = "";
        public string Mime { get; set; } = "";
        public string Author { get; set; } = "";
        public string Created { get; set; } = "";
        public string Content { get; set; } = "";
        public long Size { get; set; }

        [ObservableProperty] private bool _isBusy;      // 下载/删除中
        [ObservableProperty] private bool _isPreviewing; // 预览加载中

        public AttachmentPreviewKind? PreviewKind =>
            JiraDisplayUtils.PreviewKindFor(Mime, Filename) is { } k && !string.IsNullOrEmpty(Content) ? k : null;

        public string SizeText => PlatformUtils.FormatBytes(Size);

        public string MetaText
        {
            get
            {
                var parts = new List<string> { SizeText };
                if (!string.IsNullOrEmpty(Author)) parts.Add($"· {Author}");
                if (!string.IsNullOrEmpty(Created)) parts.Add($"· {Created}");
                return string.Join(" ", parts);
            }
        }

        public string Icon
        {
            get
            {
                var m = Mime.ToLowerInvariant();
                var name = Filename.ToLowerInvariant();
                if (m.StartsWith("image/")) return "🖼";
                if (m.StartsWith("video/")) return "🎬";
                if (m.StartsWith("audio/")) return "🎵";
                if (m.Contains("pdf")) return "📕";
                if (m.Contains("zip") || m.Contains("compressed") || m.Contains("tar")) return "🗜";
                if (m.Contains("sheet") || m.Contains("excel") || name.EndsWith(".xlsx") || name.EndsWith(".xls")) return "📊";
                if (m.Contains("word") || name.EndsWith(".docx") || name.EndsWith(".doc")) return "📝";
                if (m.Contains("presentation") || name.EndsWith(".pptx") || name.EndsWith(".ppt")) return "📽";
                if (m.Contains("text")) return "📃";
                return "📄";
            }
        }

        // 可预览的附件：文件名显示为链接样式
        public Brush FilenameColor => PreviewKind != null ? Brushes.DodgerBlue : Brushes.Black;
        public Cursor FilenameCursor => PreviewKind != null ? Cursors.Hand : Cursors.Arrow;
        public TextDecorationCollection? FilenameDecoration =>
            PreviewKind != null ? TextDecorations.Underline : null;
    }

    private readonly string _issueKey;
    private JiraIssue? _issue;
    private string _qianbaoLink = "";
    private bool _isUploading;

    private readonly ObservableCollection<AttachmentItem> _attachments = new();

    public JiraDetailWindow(string issueKey)
    {
        _issueKey = issueKey;
        InitializeComponent();

        Title = issueKey;
        KeyText.Text = issueKey;
        LoadingText.Text = $"正在获取 {issueKey} 的详情...";
        AttachmentsList.ItemsSource = _attachments;

        Loaded += (_, _) => LoadDetail();
    }

    // MARK: - 数据加载

    private async void LoadDetail()
    {
        LoadingPanel.Visibility = Visibility.Visible;
        ErrorPanel.Visibility = Visibility.Collapsed;
        DetailPanel.Visibility = Visibility.Collapsed;

        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                var fetched = await JiraService.Shared.GetIssueAsync(_issueKey);
                _issue = fetched;
                RenderIssue(fetched);
                RenderComments(fetched);
                RenderAttachments(fetched.Fields["attachment"] as JArray);

                LoadingPanel.Visibility = Visibility.Collapsed;
                DetailPanel.Visibility = Visibility.Visible;
                return; // 成功则退出
            }
            catch (Exception ex)
            {
                if (attempt == 0)
                {
                    // 首次失败等待后重试（可能是 session 初始化导致）
                    await Task.Delay(500);
                    continue;
                }
                LoadingPanel.Visibility = Visibility.Collapsed;
                ErrorText.Text = ex.Message;
                ErrorPanel.Visibility = Visibility.Visible;
            }
        }
    }

    private void RenderIssue(JiraIssue issue)
    {
        Title = $"{issue.Key} - {issue.Summary}";
        KeyText.Text = issue.Key;
        TypeBadge.Text = issue.IssueType;
        TypeBadge.BadgeColor = JiraDisplayUtils.IssueTypeColor(issue.IssueType);
        TypeBadge.Visibility = Visibility.Visible;
        StatusBadge.Text = issue.Status;
        StatusBadge.BadgeColor = JiraDisplayUtils.StatusBadgeColor(issue.Status);
        StatusBadge.Visibility = Visibility.Visible;

        SummaryText.Text = issue.Summary;

        // 基本信息
        var reporter = JiraDisplayUtils.ExtractUser(issue.Fields["reporter"]);
        var assignee = JiraDisplayUtils.ExtractUser(issue.Fields["assignee"]);
        var priority = JiraDisplayUtils.ExtractName(issue.Fields["priority"]);
        var created = FavoriteJira.FormatJiraDate(issue.Fields["created"]?.Value<string>() ?? "");
        var updated = FavoriteJira.FormatJiraDate(issue.Fields["updated"]?.Value<string>() ?? "");
        var resolution = JiraDisplayUtils.ExtractName(issue.Fields["resolution"]);

        BasicInfoGrid.Children.Clear();
        var row = 0;
        AddFieldRow(BasicInfoGrid, row, 0, "类型", issue.IssueType);
        AddStatusRow(BasicInfoGrid, row++, 1, issue.Status);
        AddFieldRow(BasicInfoGrid, row, 0, "优先级", priority);
        AddFieldRow(BasicInfoGrid, row++, 1, "解决结果", string.IsNullOrEmpty(resolution) ? "未解决" : resolution);
        AddFieldRow(BasicInfoGrid, row, 0, "报告人", reporter);
        AddFieldRow(BasicInfoGrid, row++, 1, "经办人", string.IsNullOrEmpty(assignee) ? "未分配" : assignee);
        AddFieldRow(BasicInfoGrid, row, 0, "创建时间", created);
        AddFieldRow(BasicInfoGrid, row, 1, "更新时间", updated);

        // 标签
        if (issue.Labels.Count > 0)
        {
            LabelsList.ItemsSource = issue.Labels;
            LabelsSection.Visibility = Visibility.Visible;
        }

        // 业务字段
        var developer = issue.Fields["customfield_10123"]?.Value<string>() ?? "";
        var systemName = JiraDisplayUtils.ExtractSystemName(issue.Fields["customfield_10125"]);
        var versions = JiraDisplayUtils.ExtractVersions(issue.Fields["customfield_10126"]);
        var testUser = JiraDisplayUtils.ExtractTestUser(issue.Fields["customfield_11915"] ?? issue.Fields["customfield_10107"]);
        var scheduleDateStr = ExtractScheduleDate(issue.Fields["customfield_10919"]);

        var customRows = new List<(string Label, string Value)>();
        if (!string.IsNullOrEmpty(systemName)) customRows.Add(("系统名称", systemName));
        if (!string.IsNullOrEmpty(developer)) customRows.Add(("开发人员", developer));
        if (!string.IsNullOrEmpty(testUser)) customRows.Add(("测试人员", testUser));
        if (!string.IsNullOrEmpty(versions)) customRows.Add(("开发版本", versions));
        if (!string.IsNullOrEmpty(scheduleDateStr)) customRows.Add(("排期日期", scheduleDateStr));

        if (customRows.Count > 0)
        {
            CustomFieldsGrid.Children.Clear();
            for (var i = 0; i < customRows.Count; i++)
                AddFieldRow(CustomFieldsGrid, i / 2, i % 2, customRows[i].Label, customRows[i].Value);
            CustomFieldsSection.Visibility = Visibility.Visible;
        }

        // 签报信息
        var qianbaoNo = issue.Fields["customfield_10115"]?.Value<string>() ?? "";
        _qianbaoLink = issue.Fields["customfield_13252"]?.Value<string>() ?? "";
        if (!string.IsNullOrEmpty(qianbaoNo) || !string.IsNullOrEmpty(_qianbaoLink))
        {
            QianbaoNoText.Text = qianbaoNo;
            QianbaoNoRow.Visibility = string.IsNullOrEmpty(qianbaoNo) ? Visibility.Collapsed : Visibility.Visible;
            QianbaoLinkText.Text = _qianbaoLink;
            QianbaoLinkRow.Visibility = string.IsNullOrEmpty(_qianbaoLink) ? Visibility.Collapsed : Visibility.Visible;
            QianbaoSection.Visibility = Visibility.Visible;
        }

        // 价值描述
        var valueDesc = issue.Fields["customfield_12105"]?.Value<string>() ?? "";
        if (!string.IsNullOrEmpty(valueDesc))
        {
            ValueDescText.Text = valueDesc;
            ValueDescSection.Visibility = Visibility.Visible;
        }

        // 描述 / 申请原因及需求内容描述
        var desc = issue.Fields["description"]?.Value<string>() ?? "";
        if (!string.IsNullOrEmpty(desc))
        {
            DescText.Text = desc;
            DescSection.Visibility = Visibility.Visible;
        }
    }

    private void RenderComments(JiraIssue issue)
    {
        var commentList = (issue.Fields["comment"] as JObject)?["comments"] as JArray;
        if (commentList == null || commentList.Count == 0) return;

        var items = commentList.OfType<JObject>().Take(5).Select(c => new CommentItem
        {
            Author = JiraDisplayUtils.ExtractUser(c["author"]),
            Body = c["body"]?.Value<string>() ?? "",
            Created = FavoriteJira.FormatJiraDate(c["created"]?.Value<string>() ?? "")
        }).ToList();

        CommentsList.ItemsSource = items;
        CommentsSection.Visibility = Visibility.Visible;
    }

    private void RenderAttachments(JArray? attachmentArray)
    {
        _attachments.Clear();
        if (attachmentArray != null)
        {
            foreach (var att in attachmentArray.OfType<JObject>())
            {
                _attachments.Add(new AttachmentItem
                {
                    Id = att["id"]?.Value<string>() ?? "",
                    Filename = att["filename"]?.Value<string>() ?? "(unnamed)",
                    Size = att["size"]?.Value<long>() ?? 0,
                    Mime = att["mimeType"]?.Value<string>() ?? "",
                    Author = JiraDisplayUtils.ExtractUser(att["author"]),
                    Created = FavoriteJira.FormatJiraDate(att["created"]?.Value<string>() ?? ""),
                    Content = att["content"]?.Value<string>() ?? ""
                });
            }
        }
        NoAttachmentText.Visibility = _attachments.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string ExtractScheduleDate(JToken? field)
    {
        if (field is JValue v && v.Value<string>() is { } str)
            return FavoriteJira.FormatJiraDate(str);
        if (field is JObject dict && dict["value"]?.Value<string>() is { } val)
            return val;
        return "";
    }

    // MARK: - 字段行构建

    private static void AddFieldRow(Grid grid, int row, int col, string label, string value)
    {
        EnsureRow(grid, row);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        panel.Children.Add(new TextBlock
        {
            Text = label + ":",
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88)),
            Width = 60,
            TextAlignment = TextAlignment.Right
        });
        panel.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 13,
            Margin = new Thickness(6, 0, 8, 0),
            TextWrapping = TextWrapping.Wrap
        });
        Grid.SetRow(panel, row);
        Grid.SetColumn(panel, col);
        grid.Children.Add(panel);
    }

    /// <summary>状态行：带颜色标签，更醒目</summary>
    private static void AddStatusRow(Grid grid, int row, int col, string status)
    {
        EnsureRow(grid, row);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        panel.Children.Add(new TextBlock
        {
            Text = "状态:",
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88)),
            Width = 60,
            TextAlignment = TextAlignment.Right
        });
        var fg = JiraDisplayUtils.StatusTextColor(status);
        panel.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(51, fg.R, fg.G, fg.B)), // 0.2 透明度
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 3, 8, 3),
            Margin = new Thickness(6, 0, 8, 0),
            Child = new TextBlock
            {
                Text = status,
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(fg)
            }
        });
        Grid.SetRow(panel, row);
        Grid.SetColumn(panel, col);
        grid.Children.Add(panel);
    }

    private static void EnsureRow(Grid grid, int row)
    {
        while (grid.RowDefinitions.Count <= row)
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
    }

    // MARK: - 标题栏操作

    private void Key_Click(object sender, MouseButtonEventArgs e) => OpenInBrowser();

    private void OpenInBrowser_Click(object sender, RoutedEventArgs e) => OpenInBrowser();

    private void OpenInBrowser()
    {
        var baseURL = AppConfig.Shared.JiraURL.TrimEnd('/');
        PlatformUtils.OpenUrl($"{baseURL}/browse/{_issueKey}");
    }

    private void QianbaoLink_Click(object sender, MouseButtonEventArgs e)
    {
        if (!string.IsNullOrEmpty(_qianbaoLink)) PlatformUtils.OpenUrl(_qianbaoLink);
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void Retry_Click(object sender, RoutedEventArgs e) => LoadDetail();

    // MARK: - 附件操作

    private static AttachmentItem? AttachmentOf(object sender) => (sender as FrameworkElement)?.Tag as AttachmentItem;

    private async void AttachmentDownload_Click(object sender, RoutedEventArgs e)
    {
        var att = AttachmentOf(sender);
        if (att == null || string.IsNullOrEmpty(att.Content) || att.IsBusy) return;

        att.IsBusy = true;
        try
        {
            var data = await JiraService.Shared.DownloadAttachmentDataAsync(att.Content);
            SaveDownloadedFile(data, att.Filename);
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 下载失败：{ex.Message}", true);
        }
        finally
        {
            att.IsBusy = false;
        }
    }

    private void SaveDownloadedFile(byte[] data, string suggestedName)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            FileName = suggestedName,
            Filter = "所有文件 (*.*)|*.*"
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            File.WriteAllBytes(dialog.FileName, data);
            SetUploadMessage($"✅ 已保存到 {dialog.FileName}", false);
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 保存失败：{ex.Message}", true);
        }
    }

    private void AttachmentOpenUrl_Click(object sender, RoutedEventArgs e)
    {
        var att = AttachmentOf(sender);
        if (att != null && !string.IsNullOrEmpty(att.Content))
            PlatformUtils.OpenUrl(att.Content);
    }

    private async void AttachmentDelete_Click(object sender, RoutedEventArgs e)
    {
        var att = AttachmentOf(sender);
        if (att == null || string.IsNullOrEmpty(att.Id) || att.IsBusy) return;

        var result = MessageBox.Show(this,
            $"确定要删除附件「{att.Filename}」吗？此操作不可撤销。",
            "删除附件", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (result != MessageBoxResult.Yes) return;

        att.IsBusy = true;
        SetUploadMessage("", false);
        try
        {
            await JiraService.Shared.DeleteAttachmentAsync(att.Id);
            // 从本地列表即时移除，提升响应感
            _attachments.Remove(att);
            NoAttachmentText.Visibility = _attachments.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            SetUploadMessage($"✅ 已删除附件：{att.Filename}", false);
        }
        catch (Exception ex)
        {
            att.IsBusy = false;
            SetUploadMessage($"❌ 删除失败：{ex.Message}", true);
        }
    }

    private async void AttachmentFilename_Click(object sender, MouseButtonEventArgs e)
    {
        var att = (sender as FrameworkElement)?.DataContext as AttachmentItem;
        if (att?.PreviewKind is not { } kind || att.IsPreviewing) return;

        att.IsPreviewing = true;
        try
        {
            var data = await JiraService.Shared.DownloadAttachmentDataAsync(att.Content);
            var preview = new AttachmentPreviewWindow(att.Filename, att.Mime, data, kind)
            {
                Owner = this
            };
            preview.ShowDialog();
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 预览失败：{ex.Message}", true);
        }
        finally
        {
            att.IsPreviewing = false;
        }
    }

    // MARK: - 附件上传

    private void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Multiselect = true,
            Filter = "所有文件 (*.*)|*.*"
        };
        if (dialog.ShowDialog() != true) return;
        foreach (var file in dialog.FileNames)
            UploadFile(file);
    }

    private void UploadFile(string path)
    {
        try
        {
            var data = File.ReadAllBytes(path);
            var mime = PlatformUtils.MimeTypeForExtension(System.IO.Path.GetExtension(path));
            UploadBytes(data, System.IO.Path.GetFileName(path), mime);
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 读取文件失败：{ex.Message}", true);
        }
    }

    private async void UploadBytes(byte[] data, string filename, string mime)
    {
        if (_isUploading) return;
        _isUploading = true;
        DropHintPanel.Visibility = Visibility.Collapsed;
        UploadingPanel.Visibility = Visibility.Visible;
        SetUploadMessage("", false);
        try
        {
            await JiraService.Shared.UploadAttachmentAsync(_issueKey, filename, data, mime);
            // 重新拉取附件列表
            var fresh = await JiraService.Shared.GetAttachmentsAsync(_issueKey);
            RenderAttachments(fresh);
            SetUploadMessage($"✅ 已上传 {filename}", false);
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 上传失败：{ex.Message}", true);
        }
        finally
        {
            _isUploading = false;
            DropHintPanel.Visibility = Visibility.Visible;
            UploadingPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void Paste_Click(object sender, RoutedEventArgs e) => PasteFromClipboard();

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.V && Keyboard.Modifiers == ModifierKeys.Control)
            PasteFromClipboard();
    }

    /// <summary>从剪贴板粘贴上传：文件 → 图片(转 PNG) → 纯文本（对应 Swift pasteFromClipboard）</summary>
    private void PasteFromClipboard()
    {
        try
        {
            // 1) 文件
            var files = Clipboard.GetFileDropList();
            if (files.Count > 0)
            {
                foreach (var file in files)
                {
                    if (File.Exists(file)) UploadFile(file);
                }
                return;
            }

            // 2) 图片（转 PNG）
            if (Clipboard.ContainsImage())
            {
                var image = Clipboard.GetImage();
                if (image != null)
                {
                    using var ms = new MemoryStream();
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(image));
                    encoder.Save(ms);
                    var name = $"clipboard_{DateTime.Now:yyyyMMdd_HHmmss}.png";
                    UploadBytes(ms.ToArray(), name, "image/png");
                    return;
                }
            }

            // 3) 纯文本
            if (Clipboard.ContainsText())
            {
                var text = Clipboard.GetText();
                if (!string.IsNullOrEmpty(text))
                {
                    var name = $"clipboard_{DateTime.Now:yyyyMMdd_HHmmss}.txt";
                    UploadBytes(System.Text.Encoding.UTF8.GetBytes(text), name, "text/plain");
                    return;
                }
            }

            SetUploadMessage("⚠️ 剪贴板没有可上传的文件、图片或文本", true);
        }
        catch (Exception ex)
        {
            SetUploadMessage($"❌ 读取剪贴板失败：{ex.Message}", true);
        }
    }

    // MARK: - 拖拽上传

    private void DropZone_DragEnter(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            DropZone.BorderBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x7A, 0xFF));
            DropZone.Background = new SolidColorBrush(Color.FromArgb(20, 0x00, 0x7A, 0xFF));
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void DropZone_DragLeave(object sender, DragEventArgs e)
    {
        DropZone.BorderBrush = new SolidColorBrush(Color.FromArgb(0x4D, 0x88, 0x88, 0x88));
        DropZone.Background = new SolidColorBrush(Color.FromArgb(0x66, 0xF0, 0xF0, 0xF0));
    }

    private void DropZone_Drop(object sender, DragEventArgs e)
    {
        DropZone_DragLeave(sender, e);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            foreach (var file in files)
            {
                if (File.Exists(file)) UploadFile(file);
            }
        }
    }

    // MARK: - 辅助

    private void SetUploadMessage(string message, bool isError)
    {
        UploadMessageText.Text = message;
        UploadMessageText.Foreground = isError ? Brushes.Red : Brushes.Green;
        UploadMessageText.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
    }
}
