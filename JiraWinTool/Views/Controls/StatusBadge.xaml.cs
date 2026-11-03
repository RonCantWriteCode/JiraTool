using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace JiraWinTool.Views.Controls;

/// <summary>状态标签组件（移植自 Swift StatusBadge：背景色 0.28 透明度 + 前景色 0.92 透明度）</summary>
public partial class StatusBadge : UserControl
{
    public static readonly DependencyProperty TextProperty =
        DependencyProperty.Register(nameof(Text), typeof(string), typeof(StatusBadge),
            new PropertyMetadata("", OnChanged));

    public static readonly DependencyProperty BadgeColorProperty =
        DependencyProperty.Register(nameof(BadgeColor), typeof(Color), typeof(StatusBadge),
            new PropertyMetadata(Color.FromRgb(0x8E, 0x8E, 0x93), OnChanged));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public Color BadgeColor
    {
        get => (Color)GetValue(BadgeColorProperty);
        set => SetValue(BadgeColorProperty, value);
    }

    public StatusBadge()
    {
        InitializeComponent();
        Update();
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((StatusBadge)d).Update();

    private void Update()
    {
        var c = BadgeColor;
        // 对应 Swift: background color.opacity(0.28), foreground color.opacity(0.92)
        BadgeBorder.Background = new SolidColorBrush(Color.FromArgb(71, c.R, c.G, c.B));
        BadgeText.Foreground = new SolidColorBrush(Color.FromArgb(235, c.R, c.G, c.B));
        BadgeText.Text = Text;
    }
}
