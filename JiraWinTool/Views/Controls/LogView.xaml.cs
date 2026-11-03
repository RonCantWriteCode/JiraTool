using System.Windows;
using System.Windows.Controls;

namespace JiraWinTool.Views.Controls;

/// <summary>日志输出区（移植自 Swift LogView：空态占位 + 只读等宽文本）</summary>
public partial class LogView : UserControl
{
    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(LogView),
            new PropertyMetadata("", OnChanged));

    public string Logs
    {
        get => (string)GetValue(LogsProperty);
        set => SetValue(LogsProperty, value);
    }

    public LogView()
    {
        InitializeComponent();
        Update();
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((LogView)d).Update();

    private void Update()
    {
        var empty = string.IsNullOrEmpty(Logs);
        Placeholder.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        LogBox.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        LogBox.Text = Logs;
        if (!empty) LogBox.ScrollToEnd();
    }
}
