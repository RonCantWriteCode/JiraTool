using System.Text;
using System.Text.RegularExpressions;
using JiraWinTool.Models;

namespace JiraWinTool.Services;

/// <summary>
/// 邮件解析服务：解析 .eml 文件，提取标题、发件人、正文、附件。
/// </summary>
public static class EmailParser
{
    /// <summary>从 .eml 文件路径解析邮件</summary>
    public static EmailParseResult ParseFromFile(string filePath)
    {
        var content = File.ReadAllText(filePath, Encoding.UTF8);
        return Parse(content);
    }

    /// <summary>从 .eml 文件内容字符串解析邮件</summary>
    public static EmailParseResult Parse(string emlContent)
    {
        return ParseMIMEManual(emlContent);
    }

    /// <summary>手动解析 MIME 邮件内容</summary>
    private static EmailParseResult ParseMIMEManual(string eml)
    {
        var result = new EmailParseResult();

        // 分离 header 和 body
        var headerEndIdx = FindHeaderEnd(eml);
        var headerSection = eml.Substring(0, headerEndIdx);
        var bodySection = eml.Substring(headerEndIdx).TrimStart('\r', '\n');

        // 解析 headers（处理折叠行）
        var unfoldedHeaders = UnfoldHeaders(headerSection);
        var headers = ParseHeaders(unfoldedHeaders);

        // Subject
        if (headers.TryGetValue("subject", out var subject))
            result.Subject = DecodeMIMEWord(subject);

        // From
        if (headers.TryGetValue("from", out var from))
        {
            result.From = from;
            result.FromName = ExtractDisplayName(from);
        }

        // Content-Type
        var contentType = headers.GetValueOrDefault("content-type", "text/plain");
        var boundary = ExtractBoundary(contentType);

        if (!string.IsNullOrEmpty(boundary))
        {
            // multipart 邮件：解析各部分
            ParseMultipart(bodySection, boundary, result);
        }
        else
        {
            // 单部分邮件
            var encoding = ExtractCharset(contentType);
            var transferEncoding = headers.GetValueOrDefault("content-transfer-encoding", "7bit");
            result.Body = DecodeBody(bodySection, transferEncoding, encoding);
        }

        return result;
    }

    /// <summary>查找 header 和 body 的分界（空行 \r\n\r\n 或 \n\n）</summary>
    private static int FindHeaderEnd(string eml)
    {
        var idx = eml.IndexOf("\r\n\r\n");
        if (idx >= 0) return idx;
        idx = eml.IndexOf("\n\n");
        if (idx >= 0) return idx;
        return eml.Length;
    }

    /// <summary>展开 RFC 2822 折叠行（以空白字符开头的续行）</summary>
    private static string UnfoldHeaders(string headerSection)
    {
        // RFC 2822: 折叠行以空格或 Tab 开头
        return Regex.Replace(headerSection, @"\r?\n[ \t]+", " ");
    }

    /// <summary>解析 headers 为字典</summary>
    private static Dictionary<string, string> ParseHeaders(string unfoldedHeaders)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var lines = unfoldedHeaders.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var line in lines)
        {
            var colonIdx = line.IndexOf(':');
            if (colonIdx <= 0) continue;
            var key = line.Substring(0, colonIdx).Trim();
            var value = line.Substring(colonIdx + 1).Trim();
            dict[key] = value;
        }
        return dict;
    }

    /// <summary>解析 multipart body，提取正文和附件</summary>
    private static void ParseMultipart(string bodySection, string boundary, EmailParseResult result)
    {
        var parts = SplitMIMEParts(bodySection, boundary);

        string? htmlBody = null;
        string? plainBody = null;

        foreach (var part in parts)
        {
            var partHeaderEnd = FindHeaderEnd(part);
            var partHeaders = ParseHeaders(UnfoldHeaders(part.Substring(0, partHeaderEnd)));
            var partBody = part.Substring(partHeaderEnd).TrimStart('\r', '\n');

            var partContentType = partHeaders.GetValueOrDefault("content-type", "text/plain");
            var partEncoding = ExtractCharset(partContentType);
            var transferEncoding = partHeaders.GetValueOrDefault("content-transfer-encoding", "7bit");
            var disposition = partHeaders.GetValueOrDefault("content-disposition", "");

            // 判断是否为附件
            var isAttachment = disposition.Contains("attachment", StringComparison.OrdinalIgnoreCase);
            var fileName = ExtractFilename(disposition);

            if (isAttachment || !string.IsNullOrEmpty(fileName))
            {
                // 附件部分
                var data = DecodeBodyBytes(partBody, transferEncoding);
                var attachment = new EmailAttachment
                {
                    Name = !string.IsNullOrEmpty(fileName) ? fileName : "attachment",
                    Data = data,
                    MimeType = partContentType.Split(';')[0].Trim()
                };
                result.Attachments.Add(attachment);
            }
            else if (partContentType.Contains("text/html", StringComparison.OrdinalIgnoreCase))
            {
                htmlBody = DecodeBody(partBody, transferEncoding, partEncoding);
            }
            else if (partContentType.Contains("text/plain", StringComparison.OrdinalIgnoreCase))
            {
                plainBody = DecodeBody(partBody, transferEncoding, partEncoding);
            }
            else if (partContentType.StartsWith("multipart/", StringComparison.OrdinalIgnoreCase))
            {
                // 嵌套 multipart（如 multipart/related）
                var innerBoundary = ExtractBoundary(partContentType);
                if (!string.IsNullOrEmpty(innerBoundary))
                {
                    ParseMultipart(partBody, innerBoundary, result);
                }
            }
        }

        // 优先使用 HTML 正文，其次纯文本
        if (!string.IsNullOrEmpty(htmlBody))
            result.Body = HtmlToPlainText(htmlBody);
        else if (!string.IsNullOrEmpty(plainBody))
            result.Body = plainBody;
    }

    /// <summary>按 boundary 拆分 MIME 部分</summary>
    private static List<string> SplitMIMEParts(string body, string boundary)
    {
        var parts = new List<string>();
        var delimiter = "--" + boundary;
        var endDelimiter = "--" + boundary + "--";

        var sections = body.Split(new[] { delimiter }, StringSplitOptions.None);
        foreach (var section in sections)
        {
            var trimmed = section.TrimStart('\r', '\n');
            if (trimmed.StartsWith("--") || string.IsNullOrWhiteSpace(trimmed))
                continue;
            // 去掉末尾的结束标记
            if (trimmed.Contains(endDelimiter))
                trimmed = trimmed.Substring(0, trimmed.IndexOf(endDelimiter));
            if (!string.IsNullOrWhiteSpace(trimmed))
                parts.Add(trimmed);
        }
        return parts;
    }

    /// <summary>解码邮件正文为字符串</summary>
    private static string DecodeBody(string body, string transferEncoding, string charset)
    {
        var bytes = DecodeBodyBytes(body, transferEncoding);
        try
        {
            var encoding = !string.IsNullOrEmpty(charset)
                ? Encoding.GetEncoding(charset)
                : Encoding.UTF8;
            return encoding.GetString(bytes);
        }
        catch
        {
            return Encoding.UTF8.GetString(bytes);
        }
    }

    /// <summary>按 transfer-encoding 解码邮件正文为字节数组</summary>
    private static byte[] DecodeBodyBytes(string body, string transferEncoding)
    {
        var te = transferEncoding.ToLower().Trim();
        var trimmedBody = body.TrimEnd('\r', '\n');

        if (te == "base64")
        {
            try
            {
                var cleaned = Regex.Replace(trimmedBody, @"\s+", "");
                return Convert.FromBase64String(cleaned);
            }
            catch
            {
                return Encoding.UTF8.GetBytes(trimmedBody);
            }
        }
        else if (te == "quoted-printable")
        {
            return DecodeQuotedPrintableBytes(trimmedBody);
        }
        else
        {
            // 7bit, 8bit, binary 等
            return Encoding.UTF8.GetBytes(trimmedBody);
        }
    }

    /// <summary>解码 Quoted-Printable 编码为字节数组</summary>
    private static byte[] DecodeQuotedPrintableBytes(string input)
    {
        // 先处理软换行（= 后跟 \r\n）
        var unfolded = Regex.Replace(input, @"=\r?\n", "");
        var bytes = new List<byte>();
        var i = 0;
        while (i < unfolded.Length)
        {
            if (unfolded[i] == '=' && i + 2 < unfolded.Length)
            {
                var hex = unfolded.Substring(i + 1, 2);
                if (byte.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var b))
                {
                    bytes.Add(b);
                    i += 3;
                    continue;
                }
            }
            var charBytes = Encoding.UTF8.GetBytes(unfolded[i].ToString());
            bytes.AddRange(charBytes);
            i++;
        }
        return bytes.ToArray();
    }

    /// <summary>解码 MIME encoded-word（=?charset?B?...?= 或 =?charset?Q?...?=）</summary>
    private static string DecodeMIMEWord(string input)
    {
        if (string.IsNullOrEmpty(input)) return input;

        // 匹配 =?charset?encoding?encoded_text?=
        var pattern = @"=\?([^?]+)\?([BbQq])\?([^?]*)\?=";
        var result = Regex.Replace(input, pattern, match =>
        {
            var charset = match.Groups[1].Value;
            var encoding = match.Groups[2].Value.ToUpper();
            var encodedText = match.Groups[3].Value;

            try
            {
                byte[] bytes;
                if (encoding == "B")
                {
                    bytes = Convert.FromBase64String(encodedText);
                }
                else // Q
                {
                    bytes = DecodeQuotedPrintableBytes(encodedText.Replace("_", " "));
                }

                var enc = !string.IsNullOrEmpty(charset)
                    ? Encoding.GetEncoding(charset)
                    : Encoding.UTF8;
                return enc.GetString(bytes);
            }
            catch
            {
                return match.Value;
            }
        });

        // 移除 encoded-word 之间的空白（RFC 2047）
        result = Regex.Replace(result, @"\?=\s+=\?", "?= =?");
        return result;
    }

    /// <summary>从 From 头中提取显示名称</summary>
    private static string ExtractDisplayName(string from)
    {
        if (string.IsNullOrEmpty(from)) return "";

        // 格式1: "Display Name" <email@example.com>
        var match = Regex.Match(from, @"^""?([^""<]+)""?\s*<");
        if (match.Success)
        {
            var name = match.Groups[1].Value.Trim();
            if (!string.IsNullOrEmpty(name) && !name.Contains("@"))
                return DecodeMIMEWord(name);
        }

        // 格式2: 纯 email 地址
        var emailMatch = Regex.Match(from, @"<([^>]+)>");
        if (emailMatch.Success)
            return emailMatch.Groups[1].Value;

        return DecodeMIMEWord(from.Trim());
    }

    /// <summary>从 Content-Type 提取 boundary</summary>
    private static string? ExtractBoundary(string contentType)
    {
        var match = Regex.Match(contentType, @"boundary\s*=\s*""?([^"";\s]+)""?", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : null;
    }

    /// <summary>从 Content-Type 提取 charset</summary>
    private static string ExtractCharset(string contentType)
    {
        var match = Regex.Match(contentType, @"charset\s*=\s*""?([^"";\s]+)""?", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : "utf-8";
    }

    /// <summary>从 Content-Disposition 提取文件名</summary>
    private static string? ExtractFilename(string disposition)
    {
        if (string.IsNullOrEmpty(disposition)) return null;

        // filename="xxx" 或 filename*=charset'language'encoded_name
        var match = Regex.Match(disposition, @"filename\*\s*=\s*([^']*)'[^']*'(.+)", RegexOptions.IgnoreCase);
        if (match.Success)
        {
            var charset = match.Groups[1].Value;
            var encodedName = match.Groups[2].Value;
            try
            {
                var bytes = DecodeQuotedPrintableBytes(Uri.UnescapeDataString(encodedName));
                var enc = !string.IsNullOrEmpty(charset) ? Encoding.GetEncoding(charset) : Encoding.UTF8;
                return enc.GetString(bytes);
            }
            catch { }
        }

        match = Regex.Match(disposition, @"filename\s*=\s*""?([^"";\r\n]+)""?", RegexOptions.IgnoreCase);
        if (match.Success)
        {
            return DecodeMIMEWord(match.Groups[1].Value.Trim());
        }

        return null;
    }

    /// <summary>简易 HTML 转纯文本</summary>
    private static string HtmlToPlainText(string html)
    {
        if (string.IsNullOrEmpty(html)) return "";

        // 移除 <style> 和 <script> 标签及内容
        var text = Regex.Replace(html, @"<style[^>]*>[\s\S]*?</style>", "", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<script[^>]*>[\s\S]*?</script>", "", RegexOptions.IgnoreCase);

        // <br>, <p>, <div> 等替换为换行
        text = Regex.Replace(text, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"</(p|div|tr|li|h[1-6])>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<(p|div|tr|li|h[1-6])[^>]*>", "\n", RegexOptions.IgnoreCase);

        // <td> 替换为空格
        text = Regex.Replace(text, @"</?td[^>]*>", " ", RegexOptions.IgnoreCase);

        // 移除所有剩余 HTML 标签
        text = Regex.Replace(text, @"<[^>]+>", "");

        // 解码 HTML 实体
        text = text.Replace("&nbsp;", " ")
                   .Replace("&amp;", "&")
                   .Replace("&lt;", "<")
                   .Replace("&gt;", ">")
                   .Replace("&quot;", "\"")
                   .Replace("&#39;", "'");

        // 清理多余空行
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        return text.Trim();
    }
}
