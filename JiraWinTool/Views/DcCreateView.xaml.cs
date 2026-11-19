using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>
/// 创建 DC 视图：扫描本地目录中 REQ- 开头的子目录，参考模板 DC 批量创建『生产数据配置变更申请』。
/// </summary>
public partial class DcCreateView : UserControl, INotifyPropertyChanged
{
    // MARK: - 行显示模型

    /// <summary>扫描到的每个 REQ- 目录对应的可编辑行</summary>
    public class ItemRow : INotifyPropertyChanged
    {
        public DcItem Model { get; }
        public ItemRow(DcItem model) { Model = model; }

        public string DirectoryName => Model.DirectoryName;
        public string DirectoryDisplay => $"{Model.DirectoryName}\n{Model.ReqKey}";
        public string SystemName => Model.SystemName;
        /// <summary>系统列显示：映射到的级联选项，或标注无映射/未识别</summary>
        public string SystemDisplay => Model.SystemOption != null
            ? Model.SystemOption.Display
            : (string.IsNullOrEmpty(Model.SystemName) ? "未识别" : $"{Model.SystemName}（无映射）");
        public ObservableCollection<FileRow> Files { get; } = new();

        private bool _isSelected = true;
        public bool IsSelected { get => _isSelected; set { _isSelected = value; OnPropertyChanged(); } }

        private bool _linkReq = true;
        public bool LinkReq
        {
            get => _linkReq;
            set { _linkReq = value; Model.LinkReq = value; OnPropertyChanged(); }
        }

        public string Summary
        {
            get => Model.Summary;
            set { Model.Summary = value; OnPropertyChanged(); }
        }

        public string Description
        {
            get => Model.Description;
            set { Model.Description = value; OnPropertyChanged(); }
        }

        private string _status = "待创建";
        public string Status { get => _status; set { _status = value; OnPropertyChanged(); } }

        /// <summary>异步填充 REQ 标题后通知摘要列刷新</summary>
        public void OnSummaryUpdated() => OnPropertyChanged(nameof(Summary));

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public class FileRow : INotifyPropertyChanged
    {
        public DcFileEntry Entry { get; }
        public FileRow(DcFileEntry entry) { Entry = entry; }

        public string Name => Entry.Name;
        public string SizeDisplay => Entry.SizeDisplay;

        public bool IsAttachment
        {
            get => Entry.SelectedAsAttachment;
            set { Entry.SelectedAsAttachment = value; OnPropertyChanged(); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // MARK: - Dependency properties

    public static readonly DependencyProperty RootDirProperty =
        DependencyProperty.Register(nameof(RootDir), typeof(string), typeof(DcCreateView),
            new PropertyMetadata("", (d, _) => ((DcCreateView)d).SaveCustom("dc_root_dir", ((DcCreateView)d).RootDir)));

    public static readonly DependencyProperty TemplateDcKeyProperty =
        DependencyProperty.Register(nameof(TemplateDcKey), typeof(string), typeof(DcCreateView),
            new PropertyMetadata("", (d, _) => ((DcCreateView)d).SaveCustom("dc_template_key", ((DcCreateView)d).TemplateDcKey)));

    public static readonly DependencyProperty FixedLabelsProperty =
        DependencyProperty.Register(nameof(FixedLabels), typeof(string), typeof(DcCreateView),
            new PropertyMetadata("", (d, _) => ((DcCreateView)d).SaveCustom("dc_fixed_labels", ((DcCreateView)d).FixedLabels)));

    public static readonly DependencyProperty FixedAssigneeProperty =
        DependencyProperty.Register(nameof(FixedAssignee), typeof(string), typeof(DcCreateView),
            new PropertyMetadata("", (d, _) => ((DcCreateView)d).SaveCustom("dc_fixed_assignee", ((DcCreateView)d).FixedAssignee)));

    public static readonly DependencyProperty TestAttachPathsProperty =
        DependencyProperty.Register(nameof(TestAttachPaths), typeof(string), typeof(DcCreateView),
            new PropertyMetadata("", (d, _) =>
            {
                var v = (DcCreateView)d;
                v.SaveCustom("dc_test_attach", v.TestAttachPaths);
                v.OnPropertyChanged(nameof(TestAttachDisplay));
            }));

    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(DcCreateView), new PropertyMetadata(""));

    public string RootDir { get => (string)GetValue(RootDirProperty); set => SetValue(RootDirProperty, value); }
    public string TemplateDcKey { get => (string)GetValue(TemplateDcKeyProperty); set => SetValue(TemplateDcKeyProperty, value); }
    public string FixedLabels { get => (string)GetValue(FixedLabelsProperty); set => SetValue(FixedLabelsProperty, value); }
    public string FixedAssignee { get => (string)GetValue(FixedAssigneeProperty); set => SetValue(FixedAssigneeProperty, value); }
    public string TestAttachPaths { get => (string)GetValue(TestAttachPathsProperty); set => SetValue(TestAttachPathsProperty, value); }
    /// <summary>测试附件友好展示（仅文件名）</summary>
    public string TestAttachDisplay => string.IsNullOrEmpty(TestAttachPaths)
        ? "未选择"
        : string.Join("、", TestAttachPaths.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(System.IO.Path.GetFileName));
    public string Logs { get => (string)GetValue(LogsProperty); set => SetValue(LogsProperty, value); }

    // MARK: - State

    private readonly ObservableCollection<ItemRow> _rows = new();
    private bool _isCreating;
    private string? _lastCreatedKey;

    public DcCreateView()
    {
        InitializeComponent();
        ItemList.ItemsSource = _rows;

        // 恢复已保存配置
        RootDir = AppConfig.Shared.GetCustom("dc_root_dir");
        var savedTpl = AppConfig.Shared.GetCustom("dc_template_key");
        TemplateDcKey = !string.IsNullOrEmpty(savedTpl) ? savedTpl : "DC-6296";
        FixedLabels = AppConfig.Shared.GetCustom("dc_fixed_labels");
        var savedAssignee = AppConfig.Shared.GetCustom("dc_fixed_assignee");
        FixedAssignee = !string.IsNullOrEmpty(savedAssignee) ? savedAssignee : AppConfig.Shared.JiraUser;
        TestAttachPaths = AppConfig.Shared.GetCustom("dc_test_attach");
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void SaveCustom(string key, string value) => AppConfig.Shared.SetCustom(key, value);

    // MARK: - 选择目录

    private void BrowseDir_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择包含 REQ-xxxxx 子目录的本地根目录",
            UseDescriptionForTitle = true
        };
        if (!string.IsNullOrEmpty(RootDir) && System.IO.Directory.Exists(RootDir))
            dialog.SelectedPath = RootDir;

        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            RootDir = dialog.SelectedPath;
    }

    // MARK: - 测试通过附件

    private void BrowseTestFile_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择测试通过附件（可多选）",
            Multiselect = true
        };
        if (dlg.ShowDialog() == true)
            TestAttachPaths = string.Join("\n", dlg.FileNames);
    }

    private void ClearTestFile_Click(object sender, RoutedEventArgs e) => TestAttachPaths = "";

    // MARK: - 扫描

    private async void ScanBtn_Click(object sender, RoutedEventArgs e)
    {
        var dir = RootDir.Trim();
        if (string.IsNullOrEmpty(dir))
        {
            AppendLog("[错误] 请先选择本地目录");
            return;
        }

        ScanBtn.IsEnabled = false;
        ScanProgress.Text = "扫描中...";
        try
        {
            var items = await Task.Run(() => DcService.Shared.ScanDirectory(dir));
            _rows.Clear();
            foreach (var item in items)
            {
                var row = new ItemRow(item);
                foreach (var f in item.Files)
                    row.Files.Add(new FileRow(f));
                // 摘要先用目录里的 REQ 号占位，稍后异步填充 REQ 标题
                row.Status = "待创建";
                _rows.Add(row);
            }

            NoItemHint.Visibility = _rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (_rows.Count == 0)
                NoItemHint.Text = $"目录 {dir} 下没有找到 REQ- 开头的子目录。";

            AppendLog($"扫描完成：共 {items.Count} 个待创建 DC（已按文件名系统名拆分）");
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] 扫描目录失败：{ex.Message}");
        }
        finally
        {
            ScanBtn.IsEnabled = true;
            ScanProgress.Text = "";
        }
    }

    // MARK: - 全选

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox cb && cb.IsChecked == true)
        {
            foreach (var row in _rows) row.IsSelected = true;
        }
    }

    // MARK: - 批量创建

    private async void CreateBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_isCreating) return;

        var tpl = TemplateDcKey.Trim();
        if (string.IsNullOrEmpty(tpl))
        {
            AppendLog("[错误] 请先填写模板 DC Key");
            return;
        }

        var selectedRows = _rows.Where(r => r.IsSelected).ToList();
        if (selectedRows.Count == 0)
        {
            AppendLog("[错误] 请至少勾选一个要创建的目录");
            return;
        }

        _isCreating = true;
        CreateBtn.IsEnabled = false;
        CreateProgress.Text = "创建中...";
        _lastCreatedKey = null;
        OpenBtn.Visibility = Visibility.Collapsed;

        var items = selectedRows.Select(r => r.Model).ToList();
        foreach (var row in selectedRows) row.Status = "创建中...";

        try
        {
            var keys = await DcService.Shared.CreateFromItemsAsync(
                tpl, items, FixedLabels, FixedAssignee, TestAttachPaths,
                line => Dispatcher.Invoke(() => AppendLog(line)));

            // 回填每行状态
            foreach (var row in selectedRows)
                row.Status = string.IsNullOrEmpty(row.Model.LastCreatedKey) ? "失败" : row.Model.LastCreatedKey;

            if (keys.Count > 0)
            {
                _lastCreatedKey = keys[^1];
                OpenBtn.Visibility = Visibility.Visible;
                OpenBtn.Content = $"打开 {_lastCreatedKey}";
                if (keys.Count == 1) OpenCreatedIssue();
            }
        }
        catch (Exception ex)
        {
            AppendLog($"[失败] {ex.Message}");
            foreach (var row in selectedRows)
                if (row.Status == "创建中...") row.Status = "失败";
        }
        finally
        {
            _isCreating = false;
            CreateBtn.IsEnabled = true;
            CreateProgress.Text = "";
        }
    }

    // MARK: - 清空 / 打开

    private void ClearBtn_Click(object sender, RoutedEventArgs e)
    {
        Logs = "";
        _lastCreatedKey = null;
        OpenBtn.Visibility = Visibility.Collapsed;
    }

    private void OpenBtn_Click(object sender, RoutedEventArgs e) => OpenCreatedIssue();

    private void OpenCreatedIssue()
    {
        if (string.IsNullOrEmpty(_lastCreatedKey)) return;
        var baseUrl = AppConfig.Shared.JiraURL.TrimEnd('/');
        var url = $"{baseUrl}/browse/{_lastCreatedKey}";
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

    private void AppendLog(string line)
    {
        var ts = DateTime.Now.ToString("HH:mm:ss");
        Logs += $"[{ts}] {line}\n";
    }
}
