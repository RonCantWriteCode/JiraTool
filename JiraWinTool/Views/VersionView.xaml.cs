using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;
using TextBox = System.Windows.Controls.TextBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace JiraWinTool.Views;

public partial class VersionView : UserControl
{
    private readonly Dictionary<SystemEnum, System.Windows.Controls.CheckBox> _systemCheckboxes = new();
    private List<string> _regularDates = new();

    public VersionView()
    {
        try
        {
            InitializeComponent();
            DateField.Text = DateTime.Now.ToString("yyyy-MM-dd");
            CreateSystemCheckboxes();
            LoadRegularDates();
        }
        catch (Exception ex)
        {
            // 防止初始化异常被 WPF 吞掉导致页面无响应
            System.Diagnostics.Debug.WriteLine($"[VersionView] 初始化失败: {ex}");
        }
    }

    private void CreateSystemCheckboxes()
    {
        foreach (var system in SystemEnumExtensions.AllCases)
        {
            var cb = new System.Windows.Controls.CheckBox
            {
                Content = $"{system.SystemName()} ({system.RawValue()})",
                Margin = new Thickness(4),
                Tag = system
            };
            SystemsPanel.Children.Add(cb);
            _systemCheckboxes[system] = cb;
        }
    }

    private void ModeChanged(object sender, RoutedEventArgs e)
    {
        // InitializeComponent 期间 RadioButton.Checked 先于后续元素触发，
        // 此时 CreatePanel / DeletePanel 可能尚未初始化，需做空保护
        if (CreatePanel == null || DeletePanel == null) return;

        var isCreate = CreateModeRadio.IsChecked == true;
        CreatePanel.Visibility = isCreate ? Visibility.Visible : Visibility.Collapsed;
        DeletePanel.Visibility = isCreate ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SelectAllButton_Click(object sender, RoutedEventArgs e)
    {
        foreach (var cb in _systemCheckboxes.Values)
            cb.IsChecked = true;
    }

    private void ClearSelectionButton_Click(object sender, RoutedEventArgs e)
    {
        foreach (var cb in _systemCheckboxes.Values)
            cb.IsChecked = false;
    }

    private async void ExecuteButton_Click(object sender, RoutedEventArgs e)
    {
        var isCreate = CreateModeRadio.IsChecked == true;

        if (isCreate)
        {
            var date = DateField.Text?.Trim() ?? "";
            var isUrgent = IsUrgentCheck.IsChecked == true;
            var systems = _systemCheckboxes.Where(kv => kv.Value.IsChecked == true).Select(kv => kv.Key).ToArray();

            if (string.IsNullOrEmpty(date) || systems.Length == 0) return;

            ExecuteButton.IsEnabled = false;
            ExecuteButton.Content = "执行中...";
            try
            {
                var logs = await VersionService.Shared.CreateVersionAsync(date, systems, isUrgent);
                LogViewControl.Logs = logs;
            }
            catch (Exception ex)
            {
                LogViewControl.Logs = $"创建失败: {ex.Message}";
            }
            finally
            {
                ExecuteButton.IsEnabled = true;
                ExecuteButton.Content = "执行";
            }
        }
        else
        {
            var versionName = DeleteVersionField.Text?.Trim() ?? "";
            if (string.IsNullOrEmpty(versionName)) return;

            ExecuteButton.IsEnabled = false;
            ExecuteButton.Content = "执行中...";
            try
            {
                var logs = await VersionService.Shared.DeleteVersionAsync(versionName);
                LogViewControl.Logs = logs;
            }
            catch (Exception ex)
            {
                LogViewControl.Logs = $"删除失败: {ex.Message}";
            }
            finally
            {
                ExecuteButton.IsEnabled = true;
                ExecuteButton.Content = "执行";
            }
        }
    }

    private async void BatchCreateButton_Click(object sender, RoutedEventArgs e)
    {
        var systems = _systemCheckboxes.Where(kv => kv.Value.IsChecked == true).Select(kv => kv.Key).ToArray();
        if (systems.Length == 0 || _regularDates.Count == 0)
        {
            LogViewControl.Logs = "⚠️ 常规版本日期列表为空或未选择系统，请先在「常规版本日期管理」中添加日期";
            return;
        }

        ExecuteButton.IsEnabled = false;
        ExecuteButton.Content = "执行中...";
        try
        {
            var allLogs = "";
            foreach (var date in _regularDates)
            {
                allLogs += await VersionService.Shared.CreateVersionAsync(date, systems, false);
                allLogs += "\n";
            }
            LogViewControl.Logs = allLogs;
        }
        catch (Exception ex)
        {
            LogViewControl.Logs = $"批量创建失败: {ex.Message}";
        }
        finally
        {
            ExecuteButton.IsEnabled = true;
            ExecuteButton.Content = "执行";
        }
    }

    private void ClearButton_Click(object sender, RoutedEventArgs e)
    {
        LogViewControl.Logs = "";
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(LogViewControl.Logs))
            PlatformUtils.SetClipboardText(LogViewControl.Logs);
    }

    #region Regular Version Date Store

    private const string RegularDatesKey = "regularVersionDates";

    private void LoadRegularDates()
    {
        try
        {
            var saved = AppConfig.Shared.GetCustom(RegularDatesKey);
            if (!string.IsNullOrEmpty(saved))
            {
                _regularDates = saved.Split('\n', StringSplitOptions.RemoveEmptyEntries)
                    .Select(s => s.Trim())
                    .Where(s => !string.IsNullOrEmpty(s))
                    .OrderBy(s => s)
                    .ToList();
            }

            if (_regularDates.Count == 0)
            {
                _regularDates = PublishConstants.DefaultDates.ToList();
            }
        }
        catch
        {
            _regularDates = PublishConstants.DefaultDates.ToList();
        }
    }

    private void SaveRegularDates()
    {
        AppConfig.Shared.SetCustom(RegularDatesKey, string.Join("\n", _regularDates));
    }

    private void DateManagerButton_Click(object sender, RoutedEventArgs e)
    {
        var window = new Window
        {
            Title = "常规版本日期管理",
            Width = 500,
            Height = 550,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Window.GetWindow(this),
            ResizeMode = ResizeMode.CanResize
        };

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Margin = new Thickness(16);

        // Title
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        var titleText = new TextBlock
        {
            Text = "常规版本日期管理",
            FontSize = 18,
            FontWeight = FontWeights.Bold,
            VerticalAlignment = VerticalAlignment.Center
        };
        var countText = new TextBlock
        {
            Text = $"共 {_regularDates.Count} 个日期",
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x88, 0x88, 0x88)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(16, 0, 0, 0)
        };
        titleRow.Children.Add(titleText);
        titleRow.Children.Add(countText);
        Grid.SetRow(titleRow, 0);
        grid.Children.Add(titleRow);

        // ListBox
        var listBox = new System.Windows.Controls.ListBox { Margin = new Thickness(0, 12, 0, 12) };
        RefreshDateList(listBox);
        Grid.SetRow(listBox, 1);
        grid.Children.Add(listBox);

        // Delete button
        var deleteBtn = new Button
        {
            Content = "删除选中",
            Height = 28,
            Padding = new Thickness(10, 0, 10, 0),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        deleteBtn.Click += (_, _) =>
        {
            var selected = listBox.SelectedItems.OfType<string>().ToList();
            foreach (var s in selected)
                _regularDates.Remove(s);
            SaveRegularDates();
            RefreshDateList(listBox);
        };
        Grid.SetRow(deleteBtn, 2);
        grid.Children.Add(deleteBtn);

        // New date input
        var newRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        var newDateTextBox = new TextBox { Width = 200, Height = 28, VerticalContentAlignment = VerticalAlignment.Center };
        var addBtn = new Button { Content = "添加", Height = 28, Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 0, 10, 0) };
        var statusText = new TextBlock
        {
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x00, 0x7A, 0xFF)),
            Margin = new Thickness(0, 8, 0, 0)
        };

        addBtn.Click += (_, _) =>
        {
            var date = newDateTextBox.Text.Trim();
            if (!DateUtils.ParseDate(date).HasValue)
            {
                statusText.Text = $"⚠️ 日期格式不正确: {date}，请使用 yyyy-MM-dd";
                return;
            }
            if (_regularDates.Contains(date))
            {
                statusText.Text = $"⚠️ 日期已存在: {date}";
                return;
            }
            _regularDates.Add(date);
            _regularDates = _regularDates.OrderBy(d => d).ToList();
            SaveRegularDates();
            RefreshDateList(listBox);
            newDateTextBox.Text = "";
            statusText.Text = $"已添加: {date}";
        };

        newRow.Children.Add(new DatePicker
        {
            Width = 200,
            Height = 28,
            SelectedDateFormat = DatePickerFormat.Short
        });
        newRow.Children.Add(addBtn);

        // Wire DatePicker to update text
        if (newRow.Children[0] is DatePicker dp)
        {
            dp.SelectedDateChanged += (_, _) =>
            {
                if (dp.SelectedDate.HasValue)
                    newDateTextBox.Text = dp.SelectedDate.Value.ToString("yyyy-MM-dd");
            };
        }

        Grid.SetRow(newRow, 3);
        grid.Children.Add(newRow);

        // Status + Close
        var bottomRow = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        bottomRow.Children.Add(statusText);
        var closeBtn = new Button
        {
            Content = "关闭",
            Height = 28,
            Width = 80,
            Padding = new Thickness(10, 0, 10, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0)
        };
        closeBtn.Click += (_, _) => window.Close();
        bottomRow.Children.Add(closeBtn);
        Grid.SetRow(bottomRow, 4);
        grid.Children.Add(bottomRow);

        window.Content = grid;
        window.ShowDialog();

        LoadRegularDates();
    }

    private void RefreshDateList(System.Windows.Controls.ListBox listBox)
    {
        listBox.ItemsSource = null;
        listBox.ItemsSource = _regularDates;
    }

    #endregion
}
