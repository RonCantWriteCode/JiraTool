using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace JiraWinTool.Views.Controls;

/// <summary>页面标题栏（移植自 Swift PageHeader：渐变方块图标 + 标题 + 副标题）</summary>
public partial class PageHeader : UserControl
{
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(PageHeader),
            new PropertyMetadata("", OnChanged));

    public static readonly DependencyProperty SubtitleProperty =
        DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(PageHeader),
            new PropertyMetadata("", OnChanged));

    public static readonly DependencyProperty IconProperty =
        DependencyProperty.Register(nameof(Icon), typeof(string), typeof(PageHeader),
            new PropertyMetadata("📄", OnChanged));

    public static readonly DependencyProperty HeaderColorProperty =
        DependencyProperty.Register(nameof(HeaderColor), typeof(Color), typeof(PageHeader),
            new PropertyMetadata(Color.FromRgb(0x00, 0x7A, 0xFF), OnChanged));

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string Subtitle
    {
        get => (string)GetValue(SubtitleProperty);
        set => SetValue(SubtitleProperty, value);
    }

    public string Icon
    {
        get => (string)GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    public Color HeaderColor
    {
        get => (Color)GetValue(HeaderColorProperty);
        set => SetValue(HeaderColorProperty, value);
    }

    public PageHeader()
    {
        InitializeComponent();
        Update();
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((PageHeader)d).Update();

    private void Update()
    {
        TitleText.Text = Title;
        SubtitleText.Text = Subtitle;
        IconText.Text = Icon;
        var c = HeaderColor;
        // 对应 Swift LinearGradient: color.opacity(0.8) → color.opacity(0.4)
        IconBox.Background = new LinearGradientBrush(
            Color.FromArgb(204, c.R, c.G, c.B),
            Color.FromArgb(102, c.R, c.G, c.B),
            new Point(0, 0), new Point(1, 1));
        IconShadow.Color = c;
    }
}
