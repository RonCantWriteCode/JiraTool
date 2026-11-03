using System.Windows.Controls;

namespace JiraWinTool.Views;

public partial class JiraQueryView : UserControl
{
    private readonly FavoriteSubItemInfo _info;

    public JiraQueryView(FavoriteSubItemInfo info)
    {
        _info = info;
        InitializeComponent();
        TitleText.Text = $"{info.Title}（实现中）";
    }
}
