using System.Windows;
using System.Windows.Controls;

namespace JiraWinTool.Views.Controls;

/// <summary>标签输入行（移植自 Swift LabeledField）</summary>
public partial class LabeledField : UserControl
{
    public static readonly DependencyProperty LabelProperty =
        DependencyProperty.Register(nameof(Label), typeof(string), typeof(LabeledField),
            new PropertyMetadata(""));

    public static readonly DependencyProperty PlaceholderProperty =
        DependencyProperty.Register(nameof(Placeholder), typeof(string), typeof(LabeledField),
            new PropertyMetadata(""));

    public static readonly DependencyProperty TextProperty =
        DependencyProperty.Register(nameof(Text), typeof(string), typeof(LabeledField),
            new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnTextChanged));

    public static readonly DependencyProperty LabelWidthProperty =
        DependencyProperty.Register(nameof(LabelWidth), typeof(double), typeof(LabeledField),
            new PropertyMetadata(90.0));

    public static readonly DependencyProperty IsPlaceholderVisibleProperty =
        DependencyProperty.Register(nameof(IsPlaceholderVisible), typeof(Visibility), typeof(LabeledField),
            new PropertyMetadata(Visibility.Visible));

    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public string Placeholder
    {
        get => (string)GetValue(PlaceholderProperty);
        set => SetValue(PlaceholderProperty, value);
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double LabelWidth
    {
        get => (double)GetValue(LabelWidthProperty);
        set => SetValue(LabelWidthProperty, value);
    }

    public Visibility IsPlaceholderVisible
    {
        get => (Visibility)GetValue(IsPlaceholderVisibleProperty);
        private set => SetValue(IsPlaceholderVisibleProperty, value);
    }

    public LabeledField()
    {
        InitializeComponent();
        IsPlaceholderVisible = string.IsNullOrEmpty(Text) ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var self = (LabeledField)d;
        self.IsPlaceholderVisible = string.IsNullOrEmpty(self.Text) ? Visibility.Visible : Visibility.Collapsed;
    }
}
