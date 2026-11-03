using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

public partial class UpdateFieldView : UserControl
{
    public UpdateFieldView()
    {
        InitializeComponent();
        DateField.Text = DateTime.Now.ToString("yyyy-MM-dd");
    }

    private async void ExecuteButton_Click(object sender, RoutedEventArgs e)
    {
        var date = DateField.Text?.Trim() ?? "";
        var isRegular = IsRegularCheck.IsChecked == true;

        if (string.IsNullOrEmpty(date)) return;

        ExecuteButton.IsEnabled = false;
        ExecuteButton.Content = "执行中...";
        try
        {
            var logs = await UpdateFieldService.Shared.UpdateSomeFieldAsync(date, isRegular);
            LogViewControl.Logs = logs;
        }
        catch (Exception ex)
        {
            LogViewControl.Logs = $"更新失败: {ex.Message}";
        }
        finally
        {
            ExecuteButton.IsEnabled = true;
            ExecuteButton.Content = "执行更新";
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
}
