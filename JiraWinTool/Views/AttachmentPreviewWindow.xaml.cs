using System.IO;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media.Imaging;
using JiraWinTool.Utils;

namespace JiraWinTool.Views;

/// <summary>
/// 附件在线预览窗口（移植自 Swift AttachmentPreviewSheet.swift）。
/// 平台差异：Windows 无内置 PDF/Word 渲染组件（macOS 用 PDFKit/NSAttributedString），
/// PDF 与 doc/docx 改为「保存到临时文件 + 系统默认程序打开」；RTF 用 RichTextBox 内嵌预览。
/// </summary>
public partial class AttachmentPreviewWindow : Window
{
    private readonly string _filename;
    private readonly byte[] _data;
    private readonly AttachmentPreviewKind _kind;
    private string? _tempFilePath;

    public AttachmentPreviewWindow(string filename, string mime, byte[] data, AttachmentPreviewKind kind)
    {
        _filename = filename;
        _data = data;
        _kind = kind;

        InitializeComponent();

        Title = filename;
        FilenameText.Text = filename;
        IconText.Text = kind switch
        {
            AttachmentPreviewKind.Image => "🖼",
            AttachmentPreviewKind.Text => "📃",
            AttachmentPreviewKind.Pdf => "📕",
            AttachmentPreviewKind.RichText => "📝",
            _ => "📄"
        };

        Loaded += (_, _) => Render();
    }

    private void Render()
    {
        switch (_kind)
        {
            case AttachmentPreviewKind.Image:
                RenderImage();
                break;
            case AttachmentPreviewKind.Text:
                Width = Math.Min(900, SystemParameters.WorkArea.Width * 0.98);
                Height = Math.Min(650, SystemParameters.WorkArea.Height * 0.98);
                TextPanel.Text = PlatformUtils.DecodeText(_data);
                TextPanel.Visibility = Visibility.Visible;
                break;
            case AttachmentPreviewKind.RichText:
                RenderRichText();
                break;
            case AttachmentPreviewKind.Pdf:
                Width = Math.Min(1000, SystemParameters.WorkArea.Width * 0.98);
                Height = Math.Min(800, SystemParameters.WorkArea.Height * 0.98);
                ShowExternal("PDF 暂不支持内嵌预览，请使用系统默认程序打开");
                break;
        }
    }

    private void RenderImage()
    {
        try
        {
            using var ms = new MemoryStream(_data);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = ms;
            bitmap.EndInit();
            bitmap.Freeze();

            PreviewImage.Source = bitmap;
            PreviewImage.Width = bitmap.PixelWidth;
            PreviewImage.Height = bitmap.PixelHeight;

            // 图片 + 边框能装进屏幕可视区则按原图尺寸；超出则由内部滚动
            var needW = bitmap.PixelWidth + 60;
            var needH = bitmap.PixelHeight + 110;
            Width = Math.Clamp(needW, 400, SystemParameters.WorkArea.Width * 0.98);
            Height = Math.Clamp(needH, 300, SystemParameters.WorkArea.Height * 0.98);

            ImagePanel.Visibility = Visibility.Visible;
        }
        catch
        {
            ShowExternal("无法解析图片数据");
        }
    }

    private void RenderRichText()
    {
        var name = _filename.ToLowerInvariant();
        if (name.EndsWith(".rtf"))
        {
            Width = Math.Min(950, SystemParameters.WorkArea.Width * 0.98);
            Height = Math.Min(750, SystemParameters.WorkArea.Height * 0.98);
            try
            {
                using var ms = new MemoryStream(_data);
                var range = new TextRange(RtfPanel.Document.ContentStart, RtfPanel.Document.ContentEnd);
                range.Load(ms, DataFormats.Rtf);
                RtfPanel.Visibility = Visibility.Visible;
                return;
            }
            catch
            {
                // RTF 解析失败则回退到外部打开
            }
        }
        // doc / docx 无内嵌解析能力（macOS 用 NSAttributedString officeOpenXML）
        Width = Math.Min(950, SystemParameters.WorkArea.Width * 0.98);
        Height = Math.Min(750, SystemParameters.WorkArea.Height * 0.98);
        ShowExternal("Word 文档暂不支持内嵌预览，请使用系统默认程序打开");
    }

    private void ShowExternal(string hint)
    {
        ExternalHintText.Text = hint;
        ExternalPanel.Visibility = Visibility.Visible;
    }

    /// <summary>保存到临时文件并用系统默认程序打开</summary>
    private void OpenExternal_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_tempFilePath == null)
            {
                var tempDir = Path.Combine(Path.GetTempPath(), "JiraWinTool", "preview");
                Directory.CreateDirectory(tempDir);
                _tempFilePath = Path.Combine(tempDir,
                    $"{DateTime.Now:yyyyMMdd_HHmmss}_{Path.GetFileName(_filename)}");
                File.WriteAllBytes(_tempFilePath, _data);
            }
            PlatformUtils.OpenUrl(_tempFilePath);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"打开失败: {ex.Message}", "错误",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
