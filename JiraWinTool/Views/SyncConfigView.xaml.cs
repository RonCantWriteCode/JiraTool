using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>同步配置页（移植自 Swift SyncConfigView.swift）</summary>
public partial class SyncConfigView : UserControl
{
    private readonly AppConfig _config = AppConfig.Shared;
    private bool _showPassword;
    private bool _isTesting;

    /// <summary>同步频率选项视图模型</summary>
    private record IntervalOption(string Label, int Minutes)
    {
        public override string ToString() => Label;
    }

    public SyncConfigView()
    {
        InitializeComponent();

        // 同步频率选项
        foreach (var (label, minutes) in AppConfig.SyncIntervalOptions)
            IntervalComboBox.Items.Add(new IntervalOption(label, minutes));

        Loaded += (_, _) => LoadFromConfig();
    }

    private void LoadFromConfig()
    {
        UrlBox.Text = _config.WebdavURL;
        UserBox.Text = _config.WebdavUser;
        PasswordBox.Password = _config.WebdavPassword;
        RemotePathBox.Text = _config.WebdavRemotePath;
        AutoSyncCheckBox.IsChecked = _config.AutoSyncEnabled;

        foreach (var obj in IntervalComboBox.Items)
        {
            if (obj is IntervalOption opt && opt.Minutes == _config.AutoSyncInterval)
            {
                IntervalComboBox.SelectedItem = opt;
                break;
            }
        }
        if (IntervalComboBox.SelectedItem == null && IntervalComboBox.Items.Count > 0)
            IntervalComboBox.SelectedIndex = 3; // 默认 30 分钟

        RefreshLastSyncText();
    }

    private void RefreshLastSyncText()
    {
        if (_config.LastSyncTime is DateTime lastSync)
        {
            LastSyncText.Text = lastSync.ToString("yyyy-MM-dd HH:mm:ss");
            LastSyncPanel.Visibility = Visibility.Visible;
        }
        else
        {
            LastSyncPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void AutoSync_CheckedChanged(object sender, RoutedEventArgs e)
        => AutoSyncDetailPanel.Visibility = AutoSyncCheckBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

    private void TogglePasswordVisibility_Click(object sender, RoutedEventArgs e)
    {
        _showPassword = !_showPassword;
        if (_showPassword)
        {
            PasswordTextBox.Text = PasswordBox.Password;
            PasswordBox.Visibility = Visibility.Collapsed;
            PasswordTextBox.Visibility = Visibility.Visible;
        }
        else
        {
            PasswordBox.Password = PasswordTextBox.Text;
            PasswordTextBox.Visibility = Visibility.Collapsed;
            PasswordBox.Visibility = Visibility.Visible;
        }
    }

    private string CurrentPassword => _showPassword ? PasswordTextBox.Text : PasswordBox.Password;

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        SaveToConfig();
        SaveResultText.Text = "✅ 配置已保存";
        SaveResultText.Visibility = Visibility.Visible;
        // 3 秒后自动清除
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        timer.Tick += (_, _) =>
        {
            SaveResultText.Visibility = Visibility.Collapsed;
            timer.Stop();
        };
        timer.Start();
    }

    private void SaveToConfig()
    {
        _config.WebdavURL = UrlBox.Text.Trim();
        _config.WebdavUser = UserBox.Text.Trim();
        _config.WebdavRemotePath = RemotePathBox.Text.Trim();
        _config.SaveWebdavPassword(CurrentPassword);
        _config.AutoSyncEnabled = AutoSyncCheckBox.IsChecked == true;
        if (IntervalComboBox.SelectedItem is IntervalOption opt)
            _config.AutoSyncInterval = opt.Minutes;
    }

    private async void TestConnection_Click(object sender, RoutedEventArgs e)
    {
        if (_isTesting) return;
        // 先把界面上的值写入配置再测试（与 Swift 行为一致）
        SaveToConfig();

        _isTesting = true;
        TestButton.IsEnabled = false;
        TestButton.Content = "测试中...";
        SetTestResult("", true);
        try
        {
            var msg = await WebDavService.Shared.TestConnectionAsync();
            SetTestResult(msg, true);
        }
        catch (Exception ex)
        {
            SetTestResult($"❌ {ex.Message}", false);
        }
        finally
        {
            _isTesting = false;
            TestButton.IsEnabled = true;
            TestButton.Content = "测试连接";
            RefreshLastSyncText();
        }
    }

    private void SetTestResult(string text, bool success)
    {
        TestResultText.Text = text;
        TestResultText.Foreground = success ? Brushes.Green : Brushes.Red;
        TestResultText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }
}
