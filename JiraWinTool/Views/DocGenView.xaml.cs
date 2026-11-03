using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Services;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

public partial class DocGenView : UserControl
{
    private string _titleResult = "";
    private string _contentResult = "";

    public DocGenView()
    {
        InitializeComponent();
    }

    private void GenerateButton_Click(object sender, RoutedEventArgs e)
    {
        var reqId = ReqIdField.Text?.Trim() ?? "";
        var reqName = ReqNameField.Text?.Trim() ?? "";

        if (string.IsNullOrEmpty(reqId) || string.IsNullOrEmpty(reqName))
            return;

        var categories = CategoriesField.Text?.Trim() ?? "设计文档";
        var tagsText = TagsField.Text?.Trim() ?? "";
        var tags = tagsText.Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(t => t.Trim()).ToArray();
        if (tags.Length == 0) tags = new[] { "设计文档" };
        var description = DescriptionField.Text?.Trim() ?? "";

        var (title, content) = DocService.GenerateDoc(reqId, reqName, categories, tags, description);
        _titleResult = title;
        _contentResult = content;

        TitleResult.Text = title;
        TitleLabel.Visibility = Visibility.Visible;
        TitleResultBox.Visibility = Visibility.Visible;
        ContentLabel.Visibility = Visibility.Visible;
        ContentLogView.Logs = content;
    }

    private void CopyTitleButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_titleResult))
            PlatformUtils.SetClipboardText(_titleResult);
    }

    private void CopyContentButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_contentResult))
            PlatformUtils.SetClipboardText(_contentResult);
    }
}
