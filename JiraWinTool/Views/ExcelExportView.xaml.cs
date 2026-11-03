using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Models;
using JiraWinTool.Services;
using JiraWinTool.Utils;
using Microsoft.Win32;
using TextBox = System.Windows.Controls.TextBox;
using ListBox = System.Windows.Controls.ListBox;
using SaveFileDialog = Microsoft.Win32.SaveFileDialog;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace JiraWinTool.Views;

public partial class ExcelExportView : UserControl
{
    private ExcelExportResult? _lastResult;

    public ExcelExportView()
    {
        InitializeComponent();
        // Default to current date + 29 days
        BeforeDateField.Text = DateTime.Now.AddDays(29).ToString("yyyy-MM-dd");

        // Restore template path
        var savedTemplate = AppConfig.Shared.GetCustom("excel_template_path");
        if (!string.IsNullOrEmpty(savedTemplate))
            TemplatePathBox.Text = savedTemplate;
    }

    private void OutputPathButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog
        {
            Filter = "Excel 文件 (*.xlsx)|*.xlsx|所有文件 (*.*)|*.*",
            FileName = $"版本清单{BeforeDateField.Text}.xlsx",
            DefaultExt = ".xlsx"
        };
        if (dialog.ShowDialog() == true)
        {
            OutFilePathBox.Text = dialog.FileName;
        }
    }

    private void TemplatePathButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Filter = "Excel 文件 (*.xlsx)|*.xlsx|所有文件 (*.*)|*.*"
        };
        if (dialog.ShowDialog() == true)
        {
            TemplatePathBox.Text = dialog.FileName;
            AppConfig.Shared.SetCustom("excel_template_path", dialog.FileName);
        }
    }

    private async void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        await DoExportAsync(false);
    }

    private async void ExportEmailButton_Click(object sender, RoutedEventArgs e)
    {
        await DoExportAsync(true);
    }

    private async Task DoExportAsync(bool generateEmail)
    {
        var beforeDate = BeforeDateField.Text?.Trim() ?? "";
        if (string.IsNullOrEmpty(beforeDate)) return;

        var outPath = OutFilePathBox.Text?.Trim() ?? "";
        if (string.IsNullOrEmpty(outPath))
        {
            var downloadsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", $"版本清单{beforeDate}.xlsx");
            outPath = downloadsPath;
        }

        var templatePath = TemplatePathBox.Text?.Trim() ?? "";

        ExportButton.IsEnabled = false;
        ExportEmailButton.IsEnabled = false;
        ExportButton.Content = "导出中...";
        ExportEmailButton.Content = "生成中...";
        try
        {
            _lastResult = await ExcelService.Shared.ExportExcelAsync(beforeDate, outPath, templatePath, "1");
            LogViewControl.Logs = _lastResult.Log;

            // Show email mapping sheet if there are unknown users
            if (_lastResult.UnknownUsers.Length > 0)
            {
                ShowEmailMappingDialog(_lastResult.UnknownUsers);
            }

            // Generate EML if requested
            if (generateEmail && _lastResult.DataList.Count > 0)
            {
                var emlPath = outPath.Replace(".xlsx", ".eml", StringComparison.OrdinalIgnoreCase);
                try
                {
                    EmailService.GenerateEML(_lastResult.EmailList, _lastResult.DataList, _lastResult.NoticeContent, emlPath);
                    LogViewControl.Logs += $"\n\n已生成邮件文件: {emlPath}";
                }
                catch (Exception ex)
                {
                    LogViewControl.Logs += $"\n\n生成邮件失败: {ex.Message}";
                }
            }
        }
        catch (Exception ex)
        {
            LogViewControl.Logs = $"导出失败: {ex.Message}";
        }
        finally
        {
            ExportButton.IsEnabled = true;
            ExportEmailButton.IsEnabled = true;
            ExportButton.Content = "导出";
            ExportEmailButton.Content = "导出并生成邮件";
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

    #region Email Mapping Dialog

    private void ShowEmailMappingDialog(string[] unknownUsers)
    {
        var window = new Window
        {
            Title = "补充用户邮箱映射",
            Width = 450,
            Height = 400,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Window.GetWindow(this),
            ResizeMode = ResizeMode.CanResize
        };

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Margin = new Thickness(16);

        // Title
        var titleText = new TextBlock
        {
            Text = "补充用户邮箱映射",
            FontSize = 16,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(0, 0, 0, 4)
        };
        Grid.SetRow(titleText, 0);
        grid.Children.Add(titleText);

        var subtitleText = new TextBlock
        {
            Text = $"以下 {unknownUsers.Length} 个用户未找到邮箱映射，请补充：",
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x88, 0x88, 0x88)),
            Margin = new Thickness(0, 0, 0, 12)
        };
        Grid.SetRow(subtitleText, 1);
        grid.Children.Add(subtitleText);

        var scrollViewer = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stackPanel = new StackPanel();
        var emailInputs = new Dictionary<string, TextBox>();

        foreach (var user in unknownUsers)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };

            var copyBtn = new Button
            {
                Content = user,
                Width = 100,
                Height = 28,
                ToolTip = $"点击复制: {user}",
                Margin = new Thickness(0, 0, 8, 0)
            };
            copyBtn.Click += (_, _) => PlatformUtils.SetClipboardText(user);

            var emailBox = new TextBox { Width = 250, Height = 28, VerticalContentAlignment = VerticalAlignment.Center };
            emailInputs[user] = emailBox;

            row.Children.Add(copyBtn);
            row.Children.Add(emailBox);
            stackPanel.Children.Add(row);
        }

        scrollViewer.Content = stackPanel;
        Grid.SetRow(scrollViewer, 2);
        grid.Children.Add(scrollViewer);

        // Buttons
        var buttonRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var skipBtn = new Button { Content = "跳过", Width = 80, Height = 30, Margin = new Thickness(0, 0, 12, 0) };
        var saveBtn = new Button { Content = "保存并关闭", Width = 100, Height = 30 };

        skipBtn.Click += (_, _) => window.Close();
        saveBtn.Click += (_, _) =>
        {
            var mappings = new Dictionary<string, string>();
            foreach (var (user, box) in emailInputs)
            {
                var email = box.Text.Trim();
                if (!string.IsNullOrEmpty(email))
                    mappings[user] = email;
            }
            if (mappings.Count > 0)
            {
                UserEmailMapping.AddDynamicMappings(mappings);
            }
            window.Close();
        };

        buttonRow.Children.Add(skipBtn);
        buttonRow.Children.Add(saveBtn);
        Grid.SetRow(buttonRow, 3);
        grid.Children.Add(buttonRow);

        window.Content = grid;
        window.ShowDialog();
    }

    #endregion

    #region User Mapping Manager Dialog

    private void UserMappingButton_Click(object sender, RoutedEventArgs e)
    {
        var window = new Window
        {
            Title = "用户邮箱映射管理",
            Width = 650,
            Height = 550,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Window.GetWindow(this),
            ResizeMode = ResizeMode.CanResize
        };

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Margin = new Thickness(16);

        // Title
        var titleText = new TextBlock
        {
            Text = "用户邮箱映射管理",
            FontSize = 16,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(0, 0, 0, 4)
        };
        Grid.SetRow(titleText, 0);
        grid.Children.Add(titleText);

        var allMappings = UserEmailMapping.GetAllMappings();
        var countText = new TextBlock
        {
            Text = $"共 {allMappings.Count} 个用户映射（内置 {allMappings.Count(m => m.IsBuiltIn)} 个，动态 {allMappings.Count(m => !m.IsBuiltIn)} 个）",
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x88, 0x88, 0x88)),
            Margin = new Thickness(0, 0, 0, 8)
        };
        Grid.SetRow(countText, 1);
        grid.Children.Add(countText);

        var listBox = new ListBox();
        var emailEdits = new Dictionary<string, TextBox>();

        // Build list
        var itemsPanel = new StackPanel();
        foreach (var mapping in allMappings)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };

            var nameText = new TextBlock
            {
                Text = mapping.Name,
                Width = 100,
                VerticalAlignment = VerticalAlignment.Center
            };
            row.Children.Add(nameText);

            if (mapping.IsBuiltIn)
            {
                var emailText = new TextBlock
                {
                    Text = mapping.Email,
                    Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x88, 0x88, 0x88)),
                    VerticalAlignment = VerticalAlignment.Center,
                    Width = 300
                };
                var badge = new Border
                {
                    Background = new System.Windows.Media.SolidColorBrush(
                        System.Windows.Media.Color.FromArgb(25, 0x00, 0x7A, 0xFF)),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 2, 6, 2),
                    Child = new TextBlock
                    {
                        Text = "内置",
                        FontSize = 10,
                        Foreground = new System.Windows.Media.SolidColorBrush(
                            System.Windows.Media.Color.FromRgb(0x00, 0x7A, 0xFF))
                    }
                };
                row.Children.Add(emailText);
                row.Children.Add(badge);
            }
            else
            {
                var emailBox = new TextBox
                {
                    Text = mapping.Email,
                    Width = 300,
                    Height = 28,
                    VerticalContentAlignment = VerticalAlignment.Center
                };
                emailEdits[mapping.Name] = emailBox;

                var badge = new Border
                {
                    Background = new System.Windows.Media.SolidColorBrush(
                        System.Windows.Media.Color.FromArgb(25, 0x34, 0xC7, 0x59)),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 2, 6, 2),
                    Child = new TextBlock
                    {
                        Text = "动态",
                        FontSize = 10,
                        Foreground = new System.Windows.Media.SolidColorBrush(
                            System.Windows.Media.Color.FromRgb(0x34, 0xC7, 0x59))
                    }
                };
                row.Children.Add(emailBox);
                row.Children.Add(badge);
            }

            itemsPanel.Children.Add(row);
        }

        var scrollViewer = new ScrollViewer
        {
            Content = itemsPanel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        Grid.SetRow(scrollViewer, 2);
        grid.Children.Add(scrollViewer);

        // Buttons
        var buttonRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };

        var closeBtn = new Button { Content = "关闭", Width = 80, Height = 30, Margin = new Thickness(0, 0, 12, 0) };
        var saveBtn = new Button { Content = "保存修改", Width = 100, Height = 30 };

        closeBtn.Click += (_, _) => window.Close();
        saveBtn.Click += (_, _) =>
        {
            foreach (var (name, box) in emailEdits)
            {
                var newEmail = box.Text.Trim();
                if (!string.IsNullOrEmpty(newEmail))
                {
                    UserEmailMapping.UpdateEmail(name, newEmail);
                }
            }
            window.Close();
        };

        buttonRow.Children.Add(closeBtn);
        buttonRow.Children.Add(saveBtn);
        Grid.SetRow(buttonRow, 3);
        grid.Children.Add(buttonRow);

        window.Content = grid;
        window.ShowDialog();
    }

    #endregion
}
