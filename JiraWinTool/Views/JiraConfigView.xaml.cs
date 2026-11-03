using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>Jira 配置页（移植自 Swift JiraConfigView.swift）</summary>
public partial class JiraConfigView : UserControl
{
    private readonly AppConfig _config = AppConfig.Shared;
    private string _passwordInput = "";
    private bool _showPassword;

    private string EffectivePassword =>
        string.IsNullOrEmpty(_passwordInput) ? _config.JiraPassword : _passwordInput;

    public JiraConfigView()
    {
        InitializeComponent();

        UrlBox.Text = _config.JiraURL;
        UserBox.Text = _config.JiraUser;

        UrlBox.LostFocus += (_, _) => { _config.JiraURL = UrlBox.Text.Trim(); RefreshCurrentConfig(); };
        UserBox.LostFocus += (_, _) => { _config.JiraUser = UserBox.Text.Trim(); RefreshCurrentConfig(); };

        Loaded += async (_, _) => { RefreshCurrentConfig(); await RefreshSessionStatusAsync(); };
    }

    // MARK: - 密码输入

    private void PasswordBox_PasswordChanged(object sender, RoutedEventArgs e)
        => _passwordInput = PasswordBox.Password;

    private void PasswordTextBox_TextChanged(object sender, TextChangedEventArgs e)
        => _passwordInput = PasswordTextBox.Text;

    private void Password_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            _config.SavePassword(_passwordInput);
            SaveResultText.Text = "✅ 密码已保存";
            RefreshCurrentConfig();
        }
    }

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

    // MARK: - 会话状态

    private async Task RefreshSessionStatusAsync()
    {
        var info = await Task.Run(() => JiraService.Shared.SessionInfo);
        SessionDot.Fill = info.IsValid ? Brushes.Green : Brushes.Red;
        SessionStatusText.Text = info.IsValid ? "已登录" : "未登录";
        SessionUserText.Text = info.IsValid ? info.User ?? "" : "";
        SessionTimePanel.Visibility = info.IsValid && info.LoginTime != null ? Visibility.Visible : Visibility.Collapsed;
        LogoutButton.Visibility = info.IsValid ? Visibility.Visible : Visibility.Collapsed;

        if (info.LoginTime is DateTime loginTime)
        {
            LoginTimeText.Text = loginTime.ToString("yyyy-MM-dd HH:mm:ss");
            ExpireTimeText.Text = loginTime.AddDays(7).ToString("yyyy-MM-dd HH:mm:ss");
        }
    }

    private void RefreshCurrentConfig()
    {
        CurrentUrlText.Text = _config.JiraURL;
        CurrentUserText.Text = _config.JiraUser;
        if (string.IsNullOrEmpty(EffectivePassword))
        {
            CurrentPasswordText.Text = "未设置";
            CurrentPasswordText.Foreground = Brushes.Red;
        }
        else
        {
            CurrentPasswordText.Text = EffectivePassword;
            CurrentPasswordText.Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88));
        }
    }

    // MARK: - 操作

    private async void Login_Click(object sender, RoutedEventArgs e)
    {
        LoginButton.IsEnabled = false;
        LoginButton.Content = "登录中...";
        try
        {
            _config.JiraURL = UrlBox.Text.Trim();
            _config.JiraUser = UserBox.Text.Trim();
            if (!string.IsNullOrEmpty(_passwordInput))
                _config.SavePassword(_passwordInput);

            if (string.IsNullOrEmpty(_config.JiraPassword))
            {
                SetResult("❌ 密码不能为空，请先输入密码", false);
                return;
            }

            var displayName = await JiraService.Shared.LoginAsync();
            SetResult($"✅ 登录成功！用户: {displayName}", true);
        }
        catch (Exception ex)
        {
            SetResult($"❌ 登录失败: {ex.Message}", false);
        }
        finally
        {
            LoginButton.IsEnabled = true;
            LoginButton.Content = "登录";
            RefreshCurrentConfig();
            await RefreshSessionStatusAsync();
        }
    }

    private async void Logout_Click(object sender, RoutedEventArgs e)
    {
        LogoutButton.IsEnabled = false;
        LogoutButton.Content = "登出中...";
        try
        {
            await JiraService.Shared.LogoutAsync();
            SetResult("✅ 已登出", true);
        }
        finally
        {
            LogoutButton.IsEnabled = true;
            LogoutButton.Content = "登出";
            await RefreshSessionStatusAsync();
        }
    }

    private void SavePassword_Click(object sender, RoutedEventArgs e)
    {
        _config.SavePassword(_passwordInput);
        SaveResultText.Text = "✅ 密码已保存";
        RefreshCurrentConfig();
    }

    private async void TestConnection_Click(object sender, RoutedEventArgs e)
    {
        TestButton.IsEnabled = false;
        TestButton.Content = "测试中...";
        try
        {
            _config.JiraURL = UrlBox.Text.Trim();
            _config.JiraUser = UserBox.Text.Trim();
            if (!string.IsNullOrEmpty(_passwordInput))
                _config.SavePassword(_passwordInput);

            if (string.IsNullOrEmpty(_config.JiraPassword))
            {
                SetResult("❌ 密码不能为空，请先输入密码并点击保存", false);
                return;
            }

            var displayName = await JiraService.Shared.TestConnectionAsync();
            SetResult($"✅ 连接成功！用户: {displayName}", true);
        }
        catch (JiraException ex)
        {
            SetResult($"❌ {ex.Message}", false);
        }
        catch (Exception ex)
        {
            SetResult($"❌ 连接失败: {ex.Message}", false);
        }
        finally
        {
            TestButton.IsEnabled = true;
            TestButton.Content = "测试连接";
            RefreshCurrentConfig();
            await RefreshSessionStatusAsync();
        }
    }

    private void SetResult(string text, bool success)
    {
        TestResultText.Text = text;
        TestResultText.Foreground = success ? Brushes.Green : Brushes.Red;
    }
}
