using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

public partial class NoticeView : UserControl
{
    public NoticeView()
    {
        InitializeComponent();
        DateField.Text = DateTime.Now.ToString("yyyy-MM-dd");
    }

    private async void ExecuteButton_Click(object sender, RoutedEventArgs e)
    {
        var date = DateField.Text?.Trim() ?? "";
        if (string.IsNullOrEmpty(date)) return;

        ExecuteButton.IsEnabled = false;
        ExecuteButton.Content = "生成中...";
        try
        {
            string logs;
            if (PublishModeRadio.IsChecked == true)
                logs = await NoticeService.Shared.GeneralPublishDesAsync(date);
            else
                logs = await NoticeService.Shared.GeneralVersionMeetingDescAsync(date);
            ResultLogView.Logs = logs;
        }
        catch (Exception ex)
        {
            ResultLogView.Logs = $"生成失败: {ex.Message}";
        }
        finally
        {
            ExecuteButton.IsEnabled = true;
            ExecuteButton.Content = "生成";
        }
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(ResultLogView.Logs))
            PlatformUtils.SetClipboardText(ResultLogView.Logs);
    }
}
