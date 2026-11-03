using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>数据库配置页（移植自 Swift DBConfigView.swift）</summary>
public partial class DBConfigView : UserControl
{
    private readonly AppConfig _config = AppConfig.Shared;

    public DBConfigView()
    {
        InitializeComponent();

        Loaded += (_, _) =>
        {
            CurrentPathText.Text = FavoriteDBService.Shared.GetCurrentPath();
            if (!string.IsNullOrEmpty(_config.DbPath))
                CustomPathBox.Text = _config.DbPath;
            UpdateButtonStates();
        };
    }

    private void CustomPathBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateButtonStates();

    private void UpdateButtonStates()
    {
        var enabled = !string.IsNullOrEmpty(CustomPathBox.Text) && CustomPathBox.Text != CurrentPathText.Text;
        ApplyOnlyButton.IsEnabled = enabled;
        MigrateButton.IsEnabled = enabled;
    }

    private void SelectFolder_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择数据库文件所在目录",
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            CustomPathBox.Text = System.IO.Path.Combine(dialog.SelectedPath, "jira_favorites.sqlite");
        }
    }

    private void ApplyOnly_Click(object sender, RoutedEventArgs e) => ApplyPath(migrate: false);

    private void Migrate_Click(object sender, RoutedEventArgs e) => ApplyPath(migrate: true);

    private void ApplyPath(bool migrate)
    {
        _config.DbPath = CustomPathBox.Text;
        var message = FavoriteDBService.Shared.SetCustomPath(CustomPathBox.Text, migrate);
        SetMessage(message, message.Contains("✅"));
        CurrentPathText.Text = FavoriteDBService.Shared.GetCurrentPath();
        UpdateButtonStates();
    }

    private void RestoreDefault_Click(object sender, RoutedEventArgs e)
    {
        CustomPathBox.Text = "";
        _config.DbPath = "";
        var message = FavoriteDBService.Shared.SetCustomPath(null, false);
        SetMessage(message, message.Contains("✅"));
        CurrentPathText.Text = FavoriteDBService.Shared.GetCurrentPath();
        UpdateButtonStates();
    }

    private void SetMessage(string text, bool success)
    {
        MessageText.Text = text;
        MessageText.Foreground = success ? Brushes.Green : Brushes.Red;
        MessageText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }
}
