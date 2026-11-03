using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Utils;

namespace JiraWinTool.Views.Controls;

/// <summary>操作按钮组（移植自 Swift ActionBar：执行/清空/复制）</summary>
public partial class ActionBar : UserControl
{
    public static readonly DependencyProperty ExecuteTitleProperty =
        DependencyProperty.Register(nameof(ExecuteTitle), typeof(string), typeof(ActionBar),
            new PropertyMetadata("执行", OnChanged));

    public static readonly DependencyProperty IsLoadingProperty =
        DependencyProperty.Register(nameof(IsLoading), typeof(bool), typeof(ActionBar),
            new PropertyMetadata(false, OnChanged));

    public static readonly DependencyProperty CanExecuteProperty =
        DependencyProperty.Register(nameof(CanExecute), typeof(bool), typeof(ActionBar),
            new PropertyMetadata(true, OnChanged));

    public static readonly DependencyProperty LogsProperty =
        DependencyProperty.Register(nameof(Logs), typeof(string), typeof(ActionBar),
            new PropertyMetadata("", OnChanged));

    /// <summary>点击「执行」时触发</summary>
    public event EventHandler? ExecuteClick;

    /// <summary>点击「清空」时触发</summary>
    public event EventHandler? ClearClick;

    public string ExecuteTitle
    {
        get => (string)GetValue(ExecuteTitleProperty);
        set => SetValue(ExecuteTitleProperty, value);
    }

    public bool IsLoading
    {
        get => (bool)GetValue(IsLoadingProperty);
        set => SetValue(IsLoadingProperty, value);
    }

    public bool CanExecute
    {
        get => (bool)GetValue(CanExecuteProperty);
        set => SetValue(CanExecuteProperty, value);
    }

    public string Logs
    {
        get => (string)GetValue(LogsProperty);
        set => SetValue(LogsProperty, value);
    }

    public ActionBar()
    {
        InitializeComponent();
        Update();
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((ActionBar)d).Update();

    private void Update()
    {
        ExecuteText.Text = IsLoading ? "执行中..." : ExecuteTitle;
        LoadingBar.Visibility = IsLoading ? Visibility.Visible : Visibility.Collapsed;
        ExecuteButton.IsEnabled = !IsLoading && CanExecute;
        ClearButton.IsEnabled = !string.IsNullOrEmpty(Logs);
        CopyButton.IsEnabled = !string.IsNullOrEmpty(Logs);
    }

    private void ExecuteButton_Click(object sender, RoutedEventArgs e) => ExecuteClick?.Invoke(this, EventArgs.Empty);

    private void ClearButton_Click(object sender, RoutedEventArgs e) => ClearClick?.Invoke(this, EventArgs.Empty);

    private void CopyButton_Click(object sender, RoutedEventArgs e) => PlatformUtils.SetClipboardText(Logs);
}
