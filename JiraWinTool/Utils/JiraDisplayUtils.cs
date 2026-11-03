using System.Windows.Media;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Utils;

/// <summary>附件预览类型（对应 Swift AttachmentPreview.Kind）</summary>
public enum AttachmentPreviewKind { Image, Text, Pdf, RichText }

/// <summary>
/// Jira 字段显示辅助（移植自 Swift FavoriteView / JiraDetailSheet 的颜色与字段解析函数）
/// </summary>
public static class JiraDisplayUtils
{
    // macOS 系统色等价
    public static readonly Color MacBlue = Color.FromRgb(0x00, 0x7A, 0xFF);
    public static readonly Color MacOrange = Color.FromRgb(0xFF, 0x95, 0x00);
    public static readonly Color MacRed = Color.FromRgb(0xFF, 0x3B, 0x30);
    public static readonly Color MacGreen = Color.FromRgb(0x34, 0xC7, 0x59);
    public static readonly Color MacGray = Color.FromRgb(0x8E, 0x8E, 0x93);
    public static readonly Color MacYellow = Color.FromRgb(0xFF, 0xCC, 0x00);
    public static readonly Color MacPurple = Color.FromRgb(0xAF, 0x52, 0xDE);

    /// <summary>问题类型颜色（移植自 FavoriteRow.issueTypeColor，按包含匹配）</summary>
    public static Color IssueTypeColor(string type)
    {
        if (type.Contains("需求")) return MacBlue;
        if (type.Contains("测试")) return MacOrange;
        if (type.Contains("缺陷") || type.Contains("Bug")) return MacRed;
        if (type.Contains("子任务")) return MacBlue;
        if (type.Contains("任务")) return MacGreen;
        if (type.Contains("代理")) return MacGreen;
        return MacGray;
    }

    /// <summary>状态徽章颜色（移植自 FavoriteRow.statusColor）</summary>
    public static Color StatusBadgeColor(string status)
    {
        var s = status.ToLowerInvariant();
        if (s.Contains("完成") || s.Contains("关闭") || s.Contains("done") || s.Contains("closed")) return MacGreen;
        if (s.Contains("进行") || s.Contains("处理") || s.Contains("progress")) return MacOrange;
        if (s.Contains("测试") || s.Contains("testing")) return MacYellow;
        if (s.Contains("开发") || s.Contains("development")) return Colors.White;
        if (s.Contains("待") || s.Contains("open") || s.Contains("todo")) return MacBlue;
        return MacGray;
    }

    /// <summary>详情页状态行前景色（移植自 JiraDetailSheet.statusTextColor）</summary>
    public static Color StatusTextColor(string status)
    {
        var s = status.ToLowerInvariant();
        if (s.Contains("完成") || s.Contains("关闭") || s.Contains("done") || s.Contains("closed")) return MacGreen;
        if (s.Contains("进行") || s.Contains("处理") || s.Contains("progress")) return MacOrange;
        if (s.Contains("待") || s.Contains("open") || s.Contains("todo")) return MacBlue;
        return MacBlue;
    }

    // MARK: - Jira 字段解析（JToken 版本，对应 Swift 的 [String: Any] 解析）

    /// <summary>提取用户显示名（displayName → name）</summary>
    public static string ExtractUser(JToken? field)
    {
        if (field is JObject dict)
            return dict["displayName"]?.Value<string>() ?? dict["name"]?.Value<string>() ?? "";
        return "";
    }

    /// <summary>提取 name/value 字段</summary>
    public static string ExtractName(JToken? field)
    {
        if (field is JObject dict)
            return dict["name"]?.Value<string>() ?? dict["value"]?.Value<string>() ?? "";
        if (field is JValue v) return v.Value<string>() ?? "";
        return "";
    }

    /// <summary>提取级联系统名称（child.value → value）</summary>
    public static string ExtractSystemName(JToken? field)
    {
        if (field is JObject dict)
        {
            var childValue = (dict["child"] as JObject)?["value"]?.Value<string>();
            if (!string.IsNullOrEmpty(childValue)) return childValue;
            return dict["value"]?.Value<string>() ?? "";
        }
        if (field is JValue v) return v.Value<string>() ?? "";
        return "";
    }

    /// <summary>提取版本数组（name 逗号拼接）</summary>
    public static string ExtractVersions(JToken? field)
    {
        if (field is JArray arr)
            return string.Join(", ", arr.OfType<JObject>().Select(d => d["name"]?.Value<string>()).Where(n => !string.IsNullOrEmpty(n)));
        return "";
    }

    /// <summary>提取测试人员（兼容字符串/单用户字典/用户数组三种 JSON 形态）</summary>
    public static string ExtractTestUser(JToken? field)
    {
        if (field is JValue v) return v.Value<string>() ?? "";
        if (field is JObject dict)
            return dict["displayName"]?.Value<string>() ?? dict["name"]?.Value<string>() ?? "";
        if (field is JArray arr)
            return string.Join(", ", arr.OfType<JObject>()
                .Select(d => d["displayName"]?.Value<string>() ?? d["name"]?.Value<string>())
                .Where(n => !string.IsNullOrEmpty(n)));
        return "";
    }

    /// <summary>相对更新时间显示：超过2天按天/周/月/年前显示（移植自 FavoriteRow.relativeUpdatedTime）</summary>
    public static string RelativeUpdatedTime(string updated)
    {
        if (string.IsNullOrEmpty(updated)) return updated;
        if (!DateTime.TryParseExact(updated, "yyyy-MM-dd HH:mm",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var date))
        {
            return updated;
        }

        var now = DateTime.Now;
        var diff = now - date;
        if (diff.TotalSeconds <= 2 * 24 * 60 * 60) return updated;

        var years = now.Year - date.Year;
        var months = years * 12 + now.Month - date.Month;
        if (now.Day < date.Day) months--;
        if (months >= 12 && years > 0) return $"{(months / 12)} 年前";
        if (months > 0) return $"{months} 月前";

        var days = (int)Math.Floor((now.Date - date.Date).TotalDays);
        if (days >= 7) return $"{days / 7} 周前";
        if (days > 2) return $"{days} 天前";
        return updated;
    }

    /// <summary>判断附件是否可在线预览（移植自 JiraDetailSheet.previewKind）</summary>
    public static AttachmentPreviewKind? PreviewKindFor(string mime, string filename)
    {
        var m = mime.ToLowerInvariant();
        var name = filename.ToLowerInvariant();

        // 图片
        if (m.StartsWith("image/")) return AttachmentPreviewKind.Image;
        string[] imgExts = { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".webp", ".heic" };
        if (imgExts.Any(name.EndsWith)) return AttachmentPreviewKind.Image;

        // PDF
        if (m.Contains("pdf") || name.EndsWith(".pdf")) return AttachmentPreviewKind.Pdf;

        // Word / RTF
        if (m.Contains("msword") || m.Contains("officedocument.wordprocessing") || m.Contains("rtf") ||
            name.EndsWith(".doc") || name.EndsWith(".docx") || name.EndsWith(".rtf"))
            return AttachmentPreviewKind.RichText;

        // 纯文本
        if (m.StartsWith("text/") || m.Contains("json") || m.Contains("xml") || m.Contains("javascript"))
            return AttachmentPreviewKind.Text;
        string[] textExts =
        {
            ".txt", ".sql", ".log", ".md", ".markdown", ".json", ".xml", ".yml", ".yaml",
            ".csv", ".tsv", ".ini", ".conf", ".properties",
            ".java", ".kt", ".swift", ".py", ".js", ".ts", ".tsx", ".jsx",
            ".go", ".rs", ".c", ".h", ".cpp", ".hpp", ".cs", ".rb", ".php",
            ".sh", ".bash", ".zsh", ".bat", ".ps1",
            ".html", ".htm", ".css", ".scss", ".less"
        };
        if (textExts.Any(name.EndsWith)) return AttachmentPreviewKind.Text;
        return null;
    }
}
