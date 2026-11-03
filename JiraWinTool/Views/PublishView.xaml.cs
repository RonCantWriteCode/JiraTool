using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

public partial class PublishView : UserControl
{
    public PublishView()
    {
        try
        {
            InitializeComponent();
            DateField.Text = DateTime.Now.ToString("yyyy-MM-dd");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[PublishView] 初始化失败: {ex}");
        }
    }

    private void ModeChanged(object sender, RoutedEventArgs e)
    {
        // InitializeComponent 期间 RadioButton.Checked 先于后续元素触发，
        // 此时 DatePanel / ReqPanel 可能尚未初始化，需做空保护
        if (DatePanel == null || ReqPanel == null) return;

        var isDate = DateModeRadio.IsChecked == true;
        DatePanel.Visibility = isDate ? Visibility.Visible : Visibility.Collapsed;
        ReqPanel.Visibility = isDate ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void ExecuteButton_Click(object sender, RoutedEventArgs e)
    {
        var isDate = DateModeRadio.IsChecked == true;

        ExecuteButton.IsEnabled = false;
        ExecuteButton.Content = "执行中...";
        try
        {
            string logs;
            if (isDate)
            {
                var date = DateField.Text?.Trim() ?? "";
                if (string.IsNullOrEmpty(date)) return;
                var noPublishId = NoPublishIdField.Text?.Trim();
                if (string.IsNullOrEmpty(noPublishId)) noPublishId = null;
                logs = await PublishService.Shared.CreatePublishByDateAsync(date, noPublishId);
            }
            else
            {
                var reqId = ReqIdField.Text?.Trim() ?? "";
                if (string.IsNullOrEmpty(reqId)) return;
                var banbenhao = BanBenHaoField.Text?.Trim();
                if (string.IsNullOrEmpty(banbenhao)) banbenhao = null;
                logs = await PublishService.Shared.CreatePublishByReqAsync(reqId, banbenhao);
            }
            LogViewControl.Logs = logs;
        }
        catch (Exception ex)
        {
            LogViewControl.Logs = $"执行失败: {ex.Message}";
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
}
