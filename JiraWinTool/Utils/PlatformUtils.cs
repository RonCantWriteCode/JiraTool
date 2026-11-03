using System.Diagnostics;
using System.Text;
using System.Windows;

namespace JiraWinTool.Utils;

/// <summary>
/// Windows 平台能力封装（对应 macOS 的 NSWorkspace / NSPasteboard / UTType 等）
/// </summary>
public static class PlatformUtils
{
    /// <summary>用系统默认浏览器打开 URL（对应 NSWorkspace.open）</summary>
    public static void OpenUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Debug($"❌ 打开链接失败: {ex.Message}");
        }
    }

    /// <summary>在资源管理器中显示并选中文件（对应 Finder activateFileViewerSelecting）</summary>
    public static void RevealInExplorer(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            Process.Start("explorer.exe", $"/select,\"{path}\"");
        }
        catch (Exception ex)
        {
            Log.Debug($"❌ 打开资源管理器失败: {ex.Message}");
        }
    }

    /// <summary>复制文本到剪贴板（对应 NSPasteboard）</summary>
    public static void SetClipboardText(string text)
    {
        try { Clipboard.SetText(text); }
        catch (Exception ex) { Log.Debug($"❌ 复制失败: {ex.Message}"); }
    }

    /// <summary>格式化字节数（移植自 Swift JiraDetailSheet.formatBytes）</summary>
    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        var kb = bytes / 1024.0;
        if (kb < 1024) return $"{kb:F1} KB";
        var mb = kb / 1024;
        if (mb < 1024) return $"{mb:F1} MB";
        var gb = mb / 1024;
        return $"{gb:F2} GB";
    }

    /// <summary>按扩展名推断 MIME 类型（对应 UTType(filenameExtension:)）</summary>
    public static string MimeTypeForExtension(string ext)
    {
        return ext.TrimStart('.').ToLowerInvariant() switch
        {
            "png" => "image/png",
            "jpg" or "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            "webp" => "image/webp",
            "tif" or "tiff" => "image/tiff",
            "heic" => "image/heic",
            "pdf" => "application/pdf",
            "txt" or "log" => "text/plain",
            "md" or "markdown" => "text/markdown",
            "json" => "application/json",
            "xml" => "application/xml",
            "csv" => "text/csv",
            "sql" => "application/sql",
            "htm" or "html" => "text/html",
            "css" => "text/css",
            "js" => "text/javascript",
            "zip" => "application/zip",
            "rar" => "application/vnd.rar",
            "7z" => "application/x-7z-compressed",
            "doc" => "application/msword",
            "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls" => "application/vnd.ms-excel",
            "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt" => "application/vnd.ms-powerpoint",
            "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "rtf" => "application/rtf",
            "eml" => "message/rfc822",
            _ => "application/octet-stream"
        };
    }

    /// <summary>
    /// 尝试多种编码解码文本（移植自 Swift AttachmentPreviewSheet.decodeText）：
    /// UTF-8 → UTF-16 → GB18030 → Latin1
    /// </summary>
    public static string DecodeText(byte[] data)
    {
        try
        {
            // 严格 UTF-8（不允许替换字符回退）
            var strictUtf8 = new UTF8Encoding(false, true);
            return strictUtf8.GetString(data);
        }
        catch { }
        try { return Encoding.Unicode.GetString(data); } catch { }
        try { return Encoding.GetEncoding("GB18030").GetString(data); } catch { }
        try { return Encoding.Latin1.GetString(data); } catch { }
        return "⚠️ 无法解码文件内容";
    }
}
