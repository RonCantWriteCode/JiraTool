using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>收藏页（移植自 Swift FavoriteView.swift）</summary>
public partial class FavoriteView : UserControl
{
    private readonly FavoriteService _service = FavoriteService.Shared;
    private bool _isBatchMode;
    private bool _isAdding;
    private bool _isExporting;
    private bool _showArchived;

    private bool _isInitialized;

    public FavoriteView()
    {
        InitializeComponent();
        _isInitialized = true;

        _service.PropertyChanged += Service_PropertyChanged;
        Loaded += (_, _) => RefreshList();
        Unloaded += (_, _) => _service.PropertyChanged -= Service_PropertyChanged;
    }

    // MARK: - 列表数据

    private List<FavoriteJira> FilteredFavorites
    {
        get
        {
            // 先按归档状态过滤
            var byArchive = _service.Favorites.Where(f => f.IsArchived == _showArchived);
            IEnumerable<FavoriteJira> baseList;
            var searchText = SearchBox?.Text?.Trim() ?? "";
            if (string.IsNullOrEmpty(searchText))
            {
                baseList = byArchive;
            }
            else
            {
                var query = searchText.ToLowerInvariant();
                baseList = byArchive.Where(f =>
                    f.Key.ToLowerInvariant().Contains(query) ||
                    f.Summary.ToLowerInvariant().Contains(query) ||
                    f.Reporter.ToLowerInvariant().Contains(query) ||
                    f.Assignee.ToLowerInvariant().Contains(query) ||
                    f.Status.ToLowerInvariant().Contains(query) ||
                    f.IssueType.ToLowerInvariant().Contains(query) ||
                    f.QianbaoNo.ToLowerInvariant().Contains(query));
            }
            // 置顶的排在前面，多个置顶项按置顶时间倒序（最新置顶的在最上面）
            return baseList.OrderByDescending(f => f.IsPinned)
                .ThenByDescending(f => f.IsPinned ? (f.PinnedAt ?? f.AddedAt) : DateTime.MinValue)
                .ToList();
        }
    }

    private void RefreshList()
    {
        var filtered = FilteredFavorites;
        FavList.ItemsSource = filtered;

        var archivedCount = _service.Favorites.Count(f => f.IsArchived);
        var unarchivedCount = _service.Favorites.Count - archivedCount;
        UnarchivedItem.Content = $"未归档 ({unarchivedCount})";
        ArchivedItem.Content = $"已归档 ({archivedCount})";
        CountText.Text = $"{filtered.Count} 条";

        // 空态
        EmptyPanel.Visibility = _service.Favorites.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_service.Favorites.Count > 0 && filtered.Count == 0)
        {
            NoMatchText.Text = $"没有匹配「{SearchBox.Text}」的收藏";
            NoMatchText.Visibility = Visibility.Visible;
        }
        else
        {
            NoMatchText.Visibility = Visibility.Collapsed;
        }
        FavList.Visibility = filtered.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        ExportButton.IsEnabled = !_isExporting && filtered.Count > 0;
    }

    private void Service_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(FavoriteService.Favorites))
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.Invoke(RefreshList);
                return;
            }
            RefreshList();
        }
    }

    // MARK: - 添加收藏

    private void BatchToggle_Click(object sender, RoutedEventArgs e)
    {
        _isBatchMode = !_isBatchMode;
        BatchToggleButton.Content = _isBatchMode ? "☰ 单行添加" : "☰ 批量导入";
        SinglePanel.Visibility = _isBatchMode ? Visibility.Collapsed : Visibility.Visible;
        BatchPanel.Visibility = _isBatchMode ? Visibility.Visible : Visibility.Collapsed;
        InputBox.Text = "";
        BatchInputBox.Text = "";
        SetStatus("", false);
    }

    private void InputBox_TextChanged(object sender, TextChangedEventArgs e)
        => InputPlaceholder.Visibility = string.IsNullOrEmpty(InputBox.Text) ? Visibility.Visible : Visibility.Collapsed;

    private void InputBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && AddButton.IsEnabled)
            Add_Click(sender, e);
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        var input = _isBatchMode ? BatchInputBox.Text : InputBox.Text;
        var lines = input.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        if (lines.Count == 0) return;

        SetAdding(true);
        SetStatus("", false);
        try
        {
            var result = await _service.AddFavoritesBatchAsync(lines);

            var messages = new List<string>();
            if (result.Success.Count > 0)
                messages.Add($"✅ 成功添加 {result.Success.Count} 个收藏");
            if (result.Failed.Count > 0)
            {
                var failedDetails = string.Join("\n", result.Failed.Select(f => $"{f.Input}: {f.Error}"));
                messages.Add($"❌ 失败 {result.Failed.Count} 个:\n{failedDetails}");
            }

            SetStatus(string.Join("\n", messages), result.Failed.Count > 0 && result.Success.Count == 0);
            InputBox.Text = "";
            BatchInputBox.Text = "";
        }
        finally
        {
            SetAdding(false);
        }
    }

    private void SetAdding(bool adding)
    {
        _isAdding = adding;
        AddButton.IsEnabled = !adding;
        AddButton.Content = adding ? "添加中..." : "添加";
        BatchAddButton.IsEnabled = !adding;
        BatchAddButton.Content = adding ? "添加中..." : "批量添加";
    }

    private void SetStatus(string message, bool isError)
    {
        StatusText.Text = message;
        StatusText.Foreground = isError ? Brushes.Red : Brushes.Green;
        StatusText.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: - 搜索 / 归档切换

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) { if (_isInitialized) RefreshList(); }

    private void ArchiveFilter_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitialized && ArchiveFilter.SelectedItem is ComboBoxItem item)
        {
            _showArchived = item.Tag as string == "true";
            RefreshList();
        }
    }

    // MARK: - 行操作

    private static FavoriteJira? ItemOf(object sender) => (sender as FrameworkElement)?.Tag as FavoriteJira;

    private void RowOpen_Click(object sender, RoutedEventArgs e) => OpenInBrowser(ItemOf(sender));

    private void RowKey_Click(object sender, MouseButtonEventArgs e)
        => OpenInBrowser((sender as FrameworkElement)?.DataContext as FavoriteJira);

    private void OpenInBrowser(FavoriteJira? item)
    {
        if (item != null) PlatformUtils.OpenUrl(item.Url);
    }

    private void RowCopyKey_Click(object sender, RoutedEventArgs e) => CopyKey(ItemOf(sender));

    private void CopyKey(FavoriteJira? item)
    {
        if (item == null) return;
        PlatformUtils.SetClipboardText(item.Key);
        SetStatus($"✅ 已复制: {item.Key}", false);
    }

    private async void RowRefresh_Click(object sender, RoutedEventArgs e)
    {
        var item = ItemOf(sender);
        if (item == null || item.IsRefreshing) return;

        item.IsRefreshing = true;
        try
        {
            await _service.RefreshFavoriteAsync(item.Id);
            SetStatus($"✅ 已刷新 {item.Key}", false);
        }
        catch (Exception ex)
        {
            SetStatus($"❌ 刷新失败: {ex.Message}", true);
        }
        finally
        {
            item.IsRefreshing = false;
            // 刷新完成后列表中的对象已被替换，按 Id 找到新对象一并复位
            var current = _service.Favorites.FirstOrDefault(f => f.Id == item.Id);
            if (current != null && !ReferenceEquals(current, item)) current.IsRefreshing = false;
        }
    }

    private void RowDelete_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) _service.RemoveFavorite(item.Id);
    }

    private void RowTogglePin_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) _service.TogglePin(item.Id);
    }

    private void RowToggleArchive_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) _service.ToggleArchive(item.Id);
    }

    private void RowSummary_Click(object sender, MouseButtonEventArgs e)
        => ShowDetail((sender as FrameworkElement)?.DataContext as FavoriteJira);

    private void RowQianbao_Click(object sender, MouseButtonEventArgs e)
        => OpenQianbao((sender as FrameworkElement)?.DataContext as FavoriteJira);

    private void OpenQianbao(FavoriteJira? item)
    {
        if (item != null && !string.IsNullOrEmpty(item.QianbaoLink))
            PlatformUtils.OpenUrl(item.QianbaoLink);
    }

    private void ShowDetail(FavoriteJira? item)
    {
        if (item == null) return;
        var window = new JiraDetailWindow(item.Key)
        {
            Owner = Window.GetWindow(this)
        };
        window.ShowDialog();
    }

    // MARK: - 右键菜单

    private void RowContextMenu_Opened(object sender, RoutedEventArgs e)
    {
        if (sender is not ContextMenu menu) return;
        var item = menu.PlacementTarget is FrameworkElement fe ? fe.DataContext as FavoriteJira : null;
        if (item == null) return;

        // 菜单 Tag 记录当前项
        menu.Tag = item;
        foreach (var obj in menu.Items)
        {
            if (obj is not MenuItem mi) continue;
            switch (mi.Name)
            {
                case "CtxPin":
                    mi.Header = item.IsPinned ? "取消置顶" : "置顶";
                    break;
                case "CtxArchive":
                    mi.Header = item.IsArchived ? "取消归档" : "归档";
                    break;
                case "CtxQianbao":
                    mi.Visibility = string.IsNullOrEmpty(item.QianbaoLink) ? Visibility.Collapsed : Visibility.Visible;
                    break;
            }
        }
    }

    private static FavoriteJira? CtxItem(object sender) =>
        (sender as MenuItem)?.Parent is ContextMenu menu ? menu.Tag as FavoriteJira : null;

    private void CtxOpen_Click(object sender, RoutedEventArgs e) => OpenInBrowser(CtxItem(sender));
    private void CtxCopyKey_Click(object sender, RoutedEventArgs e) => CopyKey(CtxItem(sender));

    private void CtxRefresh_Click(object sender, RoutedEventArgs e)
    {
        if (CtxItem(sender) is { } item)
            RowRefresh_Click(new Button { Tag = item }, e);
    }

    private void CtxTogglePin_Click(object sender, RoutedEventArgs e)
    {
        if (CtxItem(sender) is { } item) _service.TogglePin(item.Id);
    }

    private void CtxToggleArchive_Click(object sender, RoutedEventArgs e)
    {
        if (CtxItem(sender) is { } item) _service.ToggleArchive(item.Id);
    }

    private void CtxOpenQianbao_Click(object sender, RoutedEventArgs e) => OpenQianbao(CtxItem(sender));

    private void CtxDelete_Click(object sender, RoutedEventArgs e)
    {
        if (CtxItem(sender) is { } item) _service.RemoveFavorite(item.Id);
    }

    // MARK: - 导出 Excel

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        var items = FilteredFavorites;
        if (items.Count == 0) return;

        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "导出收藏 Jira 列表",
            FileName = $"收藏Jira_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx",
            Filter = "Excel 文件 (*.xlsx)|*.xlsx",
            DefaultExt = ".xlsx"
        };
        if (dialog.ShowDialog() != true) return;

        _isExporting = true;
        ExportButton.IsEnabled = false;
        ExportButton.Content = "⏳ 导出中";
        SetStatus("", false);
        try
        {
            var path = dialog.FileName;
            await _service.ExportToExcelAsync(items, path);
            SetStatus($"✅ 已导出 {items.Count} 条收藏到: {System.IO.Path.GetFileName(path)}", false);
            // 导出后在资源管理器中显示
            PlatformUtils.RevealInExplorer(path);
        }
        catch (Exception ex)
        {
            SetStatus($"❌ 导出失败: {ex.Message}", true);
        }
        finally
        {
            _isExporting = false;
            ExportButton.IsEnabled = true;
            ExportButton.Content = "📤 导出";
        }
    }
}
