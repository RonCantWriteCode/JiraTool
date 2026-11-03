using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using JiraWinTool.Models;
using JiraWinTool.Utils;

namespace JiraWinTool.Services;

/// <summary>
/// OA HTTP 服务（移植自 Swift OAService.swift）。
/// 管理 Cookie 会话、登录态维持、HTML 抓取、附件下载。
/// </summary>
public partial class OAService
{
    public static OAService Shared { get; } = new();

    private readonly HttpClient _http;
    private readonly Dictionary<string, string> _cookies = new();
    private string? _loggedInBaseURL;
    private string? _loggedInUser;

    private const string BrowserUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 JiraWinTool/1.0";

    private OAService()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All
        };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
    }

    // MARK: - Public

    /// <summary>登出</summary>
    public void Logout() => ClearSession();

    /// <summary>确保指定 baseURL 已登录</summary>
    public async Task EnsureLoginAsync(string baseURL, string? verifyURL = null)
    {
        var user = AppConfig.Shared.JiraUser;
        if (_loggedInBaseURL == baseURL && _loggedInUser == user && _cookies.Count > 0)
            return;
        await DoLoginAsync(baseURL, verifyURL);
    }

    /// <summary>抓取指定链接的 HTML；如未登录则自动登录；401/会话失效自动重登一次</summary>
    public async Task<string> FetchHTMLAsync(string urlString, bool retried = false)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url))
            throw OAException.InvalidURL;
        var baseURL = ExtractBaseURL(url);
        await EnsureLoginAsync(baseURL, urlString);

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        request.Headers.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        AttachCookie(request);

        var (data, http) = await SendAsync(request);
        AbsorbSetCookies(http, url);

        Log.Debug($"[OAService] fetchHTML status={(int)http.StatusCode} url={urlString[..Math.Min(120, urlString.Length)]}");

        // 3xx 且 Location 指向登录页
        if (http.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest)
        {
            var location = http.Headers.Location?.ToString() ?? "";
            if (LooksLikeLoginRedirect(location))
            {
                if (retried) throw OAException.LoginFailed("会话失效，再次登录仍被重定向到 " + location);
                ClearSession();
                return await FetchHTMLAsync(urlString, retried: true);
            }
            var next = AbsoluteURL(location, url);
            return await FetchHTMLAsync(next, retried);
        }

        if ((int)http.StatusCode >= 400)
        {
            var msg = DecodeBody(data, http);
            throw OAException.HttpError((int)http.StatusCode, msg[..Math.Min(200, msg.Length)]);
        }

        var html = DecodeBody(data, http);
        var trimmed = html.Trim();
        if (trimmed.Length < 32)
        {
            Log.Debug($"[OAService] fetchHTML 短响应 bodySize={data.Length}；不按登录页处理，原样返回");
            return html;
        }

        var loginReason = LoginPageDetectReason(html);
        if (loginReason != null)
        {
            Log.Debug($"[OAService] fetchHTML 被判为登录页 reason={loginReason}");
            if (retried)
                throw OAException.LoginFailed($"会话失效，再次登录仍落到登录页({loginReason})");
            ClearSession();
            return await FetchHTMLAsync(urlString, retried: true);
        }
        return html;
    }

    /// <summary>下载附件</summary>
    public async Task<OADownloadedAttachment> DownloadAttachmentAsync(string urlString, bool retried = false)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url))
            throw OAException.InvalidURL;
        var baseURL = ExtractBaseURL(url);
        await EnsureLoginAsync(baseURL);

        Log.Debug($"[OAService] 下载附件，主 URL: {urlString}");
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        request.Headers.TryAddWithoutValidation("Referer", baseURL + "/");
        AttachCookie(request);

        var (data, http) = await SendAsync(request);
        AbsorbSetCookies(http, url);

        if (http.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest)
        {
            var location = http.Headers.Location?.ToString() ?? "";
            if (LooksLikeLoginRedirect(location))
            {
                if (retried) throw OAException.LoginFailed("附件下载时会话失效");
                ClearSession();
                return await DownloadAttachmentAsync(urlString, retried: true);
            }
            var next = AbsoluteURL(location, url);
            return await DownloadAttachmentAsync(next, retried);
        }

        // 404/400 自动尝试备用下载路径
        if (http.StatusCode == HttpStatusCode.NotFound || http.StatusCode == HttpStatusCode.BadRequest)
        {
            var ids = ExtractAllHexIdsFromURL(urlString);
            var shortKey = ids.FirstOrDefault(x => x.Length >= 8 && x.Length < 20) ?? "";
            var longIds = ids.Where(x => x.Length >= 20).ToList();
            var fdId = longIds.FirstOrDefault() ?? "";
            var fdFileId = longIds.Count > 1 ? longIds[1] : fdId;

            var candidates = new List<string>();
            if (!string.IsNullOrEmpty(shortKey))
            {
                candidates.Add($"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={shortKey}");
                candidates.Add($"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={shortKey}&fdAttId={fdId}");
            }
            if (!string.IsNullOrEmpty(fdId))
            {
                candidates.Add($"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={fdId}");
                candidates.Add($"{baseURL}/sys/attachment/sys_att_main/{fdId}.do?method=download");
                candidates.Add($"{baseURL}/sys/attachment/download.do?fdId={fdId}");
                candidates.Add($"{baseURL}/sys/common/downloadFile.do?fdId={fdId}");
            }
            foreach (var candidate in candidates.Where(c => c != urlString))
            {
                Log.Debug($"[OAService] 尝试备用路径: {candidate}");
                try
                {
                    var result = await DownloadAttachmentRawAsync(candidate, baseURL + "/");
                    Log.Debug($"[OAService] ✅ 备用路径成功: {candidate}");
                    return result;
                }
                catch { }
            }
            var msg = DecodeBody(data, http);
            throw OAException.HttpError((int)http.StatusCode, msg[..Math.Min(200, msg.Length)]);
        }

        if ((int)http.StatusCode >= 400)
        {
            var msg = DecodeBody(data, http);
            throw OAException.HttpError((int)http.StatusCode, msg[..Math.Min(200, msg.Length)]);
        }

        var fileName = ExtractFileName(http, url);
        var mime = http.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
        return new OADownloadedAttachment { Name = fileName, Data = data, MimeType = mime };
    }

    /// <summary>底层下载（不带 fallback）</summary>
    public async Task<OADownloadedAttachment> DownloadAttachmentRawAsync(string urlString, string? referer = null)
    {
        var (data, http, fileName) = await ProbeURLAsync(urlString, referer);
        if ((int)http.StatusCode >= 400)
        {
            var msg = DecodeBody(data, http);
            throw OAException.HttpError((int)http.StatusCode, msg[..Math.Min(200, msg.Length)]);
        }
        var mime = http.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
        if (mime.Contains("text/html", StringComparison.OrdinalIgnoreCase))
            throw OAException.HttpError(400, "返回 HTML 而非文件");
        return new OADownloadedAttachment { Name = fileName, Data = data, MimeType = mime };
    }

    /// <summary>探测 URL，返回原始数据、HTTP 响应、文件名</summary>
    public async Task<(byte[] Data, HttpResponseMessage Response, string FileName)> ProbeURLAsync(
        string urlString, string? referer = null, HttpMethod? method = null)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url))
            throw OAException.InvalidURL;

        using var request = new HttpRequestMessage(method ?? HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        if (!string.IsNullOrEmpty(referer))
            request.Headers.TryAddWithoutValidation("Referer", referer);
        AttachCookie(request);

        var (data, http) = await SendAsync(request);
        AbsorbSetCookies(http, url);

        if (http.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest)
        {
            var location = http.Headers.Location?.ToString() ?? "";
            if (LooksLikeLoginRedirect(location))
                throw OAException.LoginFailed("会话失效");
            var next = AbsoluteURL(location, url);
            return await ProbeURLAsync(next, referer, method);
        }

        var fileName = ExtractFileName(http, url);
        return (data, http, fileName);
    }

    // MARK: - Diagnostic

    /// <summary>诊断下载：暴力尝试所有可能的 URL 组合并保存报告</summary>
    public async Task DiagnoseDownloadAsync(OAAttachment attachment, string baseURL, string? referer = null)
    {
        var ts = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var dir = Path.Combine(AppConfig.AppDataDir, "oa_diagnosis");
        Directory.CreateDirectory(dir);
        var reportPath = Path.Combine(dir, $"oa_download_diagnosis_{ts}.txt");

        var lines = new List<string>
        {
            "=== OA 附件下载诊断报告 ===",
            $"时间: {ts}",
            $"附件名: {attachment.Name}",
            $"prefix: {attachment.Prefix}",
            $"fdId: {attachment.FdId}",
            $"fdFileId: {attachment.FdFileId}",
            $"modelName: {attachment.ModelName}",
            $"modelId: {attachment.ModelId}",
            ""
        };

        var prefix = attachment.Prefix;
        var fdId = attachment.FdId;
        var fdFileId = attachment.FdFileId;
        var modelName = attachment.ModelName;
        var modelId = attachment.ModelId;

        var candidates = new List<(string Label, string Url, bool IsPost)>();

        if (!string.IsNullOrEmpty(fdId))
        {
            var ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            candidates.Add(("sysAttMain.do fdId", $"{baseURL}/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId={fdId}&isSupportDirect=null&downloadType=manual&downloadFlag={ms}", false));
            candidates.Add(("sysAttMain.do fdFileId", $"{baseURL}/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId={fdFileId}&isSupportDirect=null&downloadType=manual&downloadFlag={ms}", false));
            candidates.Add(("sys_att_main download", $"{baseURL}/sys/attachment/sys_att_main/{fdId}.do?method=download", false));
            candidates.Add(("download.do", $"{baseURL}/sys/attachment/download.do?fdId={fdId}", false));
            candidates.Add(("common downloadFile", $"{baseURL}/sys/common/downloadFile.do?fdId={fdId}", false));
        }

        if (!string.IsNullOrEmpty(prefix))
        {
            candidates.Add(("swf prefix", $"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={prefix}", false));
            candidates.Add(("swf prefix+model", $"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={prefix}&fdModelName={Uri.EscapeDataString(modelName)}&fdModelId={modelId}", false));
            candidates.Add(("swf prefix+fdAttId", $"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={prefix}&fdAttId={fdId}", false));
            candidates.Add(("swf prefix+fdFileId", $"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={prefix}&fdFileId={fdFileId}", false));
            candidates.Add(("swf prefix+all", $"{baseURL}/sys/attachment/swf_attachment.do?method=download&fdId={prefix}&fdAttId={fdId}&fdFileId={fdFileId}", false));
        }

        lines.Add($"共尝试 {candidates.Count} 个 URL:");
        lines.Add("");

        foreach (var (label, urlStr, isPost) in candidates)
        {
            lines.Add($"--- {label} ---");
            lines.Add($"URL: {urlStr}");
            lines.Add($"method: {(isPost ? "POST" : "GET")}");
            try
            {
                var method = isPost ? HttpMethod.Post : HttpMethod.Get;
                var diagReferer = referer ?? (baseURL + "/");
                var (data, http, fileName) = await ProbeURLAsync(urlStr, diagReferer, method);
                var ct = http.Content.Headers.ContentType?.ToString() ?? "?";
                lines.Add($"status: {(int)http.StatusCode}");
                lines.Add($"content-type: {ct}");
                lines.Add($"size: {data.Length}B");
                lines.Add($"fileName: {fileName}");
                if (ct.Contains("text/html", StringComparison.OrdinalIgnoreCase))
                {
                    var body = Encoding.UTF8.GetString(data.Take(800).ToArray());
                    lines.Add($"body(前800): {body}");
                }
                if ((int)http.StatusCode == 200 && !ct.Contains("text/html", StringComparison.OrdinalIgnoreCase) && data.Length > 100)
                    lines.Add("⚠️ 可能成功！");
            }
            catch (Exception ex) { lines.Add($"error: {ex.Message}"); }
            lines.Add("");
        }

        await File.WriteAllTextAsync(reportPath, string.Join("\n", lines));
        Log.Debug($"[OAService] 诊断报告已保存: {reportPath}");
    }

    // MARK: - Login detection

    /// <summary>判断 HTML 是否为登录页</summary>
    public string? LoginPageDetectReason(string html)
    {
        var trimmed = html.Trim();
        if (trimmed.Length < 32) return null;
        var lower = html.ToLowerInvariant();

        var strongTokens = new[] { "j_username", "j_password", "name=\"loginname\"", "id=\"loginname\"",
            "name=\"password\"", "id=\"password\"", "loginform", "login-form", "login_form" };
        var hits = strongTokens.Where(t => lower.Contains(t.ToLowerInvariant())).ToList();
        if (hits.Count >= 2) return "strongTokens=[" + string.Join(",", hits) + "]";

        var softZh = new[] { "用户登录", "请登录", "登录系统", "账号登录", "用户名或密码", "账号或密码" };
        if (softZh.Any(html.Contains) && lower.Contains("type=\"password\""))
            return "zhLoginHint+passwordInput";

        if (lower.Contains("location.href") && (lower.Contains("login.jsp") || lower.Contains("anonym.jsp") || lower.Contains("/sys/login/")))
            return "jsRedirectLoginJsp";

        return null;
    }

    public bool LooksLikeLoginPage(string html) => LoginPageDetectReason(html) != null;

    // MARK: - Cookie / URL helpers

    public void AttachCookie(HttpRequestMessage request)
    {
        if (_cookies.Count == 0) return;
        var header = string.Join("; ", _cookies.Select(kv => $"{kv.Key}={kv.Value}"));
        request.Headers.TryAddWithoutValidation("Cookie", header);
    }

    public void AbsorbSetCookies(HttpResponseMessage http, Uri? responseURL = null)
    {
        // 优先用 Set-Cookie header 直接解析
        if (http.Headers.TryGetValues("Set-Cookie", out var values))
        {
            foreach (var val in values)
            {
                var semi = val.IndexOf(';');
                var cookiePart = semi >= 0 ? val[..semi] : val;
                var eq = cookiePart.IndexOf('=');
                if (eq > 0)
                {
                    var name = cookiePart[..eq].Trim();
                    var value = cookiePart[(eq + 1)..].Trim();
                    if (!string.IsNullOrEmpty(name))
                        _cookies[name] = value;
                }
            }
        }
    }

    public static string ExtractBaseURL(Uri url)
    {
        var scheme = "https";
        var host = url.Host;
        if (url.Port != 80 && url.Port != 443)
            return $"{scheme}://{host}:{url.Port}";
        return $"{scheme}://{host}";
    }

    public static string AbsoluteURL(string location, Uri baseUri)
    {
        if (location.StartsWith("http://") || location.StartsWith("https://"))
            return location;
        if (Uri.TryCreate(baseUri, location, out var result))
            return result.ToString();
        return location;
    }

    /// <summary>LooksLikeLoginRedirect：location 含 login/signin/sso/anonym</summary>
    public static bool LooksLikeLoginRedirect(string location)
    {
        var lower = location.ToLowerInvariant();
        return lower.Contains("login") || lower.Contains("signin") || lower.Contains("sso") || lower.Contains("anonym");
    }

    public static string DecodeBody(byte[] data, HttpResponseMessage response)
    {
        var ct = response.Content.Headers.ContentType?.ToString()?.ToLowerInvariant() ?? "";
        if (ct.Contains("charset=gb") || ct.Contains("charset=gbk"))
        {
            try { return Encoding.GetEncoding("GB18030").GetString(data); } catch { }
        }
        try { return Encoding.UTF8.GetString(data); } catch { }
        try { return Encoding.GetEncoding("GB18030").GetString(data); } catch { }
        return Encoding.Latin1.GetString(data);
    }

    /// <summary>从 URL 中提取所有 16+ 位十六进制 ID</summary>
    public static List<string> ExtractAllHexIdsFromURL(string urlString)
    {
        var matches = Regex.Matches(urlString, @"[a-f0-9]{16,}", RegexOptions.IgnoreCase);
        return matches.Select(m => m.Value).ToList();
    }

    /// <summary>当前会话 cookies（只读副本），供 WebView2 PDF 导出等场景使用</summary>
    public IReadOnlyDictionary<string, string> Cookies => new Dictionary<string, string>(_cookies);

    /// <summary>当前已登录的 baseURL</summary>
    public string? LoggedInBaseURL => _loggedInBaseURL;

    public void ClearSession()
    {
        _cookies.Clear();
        _loggedInBaseURL = null;
        _loggedInUser = null;
    }

    // MARK: - Private send

    private async Task<(byte[] Data, HttpResponseMessage Response)> SendAsync(HttpRequestMessage request, int maxRedirects = 5)
    {
        for (int redirect = 0; redirect <= maxRedirects; redirect++)
        {
            var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);

            if (response.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest
                && redirect < maxRedirects && response.Headers.Location != null)
            {
                var newUrl = response.Headers.Location.IsAbsoluteUri
                    ? response.Headers.Location.ToString()
                    : new Uri(request.RequestUri!, response.Headers.Location).ToString();
                response.Dispose();
                // 非 GET/HEAD 的重定向必须切换为 GET（POST→302→GET 是标准 HTTP 行为）
                var redirectMethod = request.Method == HttpMethod.Get || request.Method == HttpMethod.Head
                    ? request.Method : HttpMethod.Get;
                var newReq = new HttpRequestMessage(redirectMethod, newUrl);
                foreach (var h in request.Headers)
                {
                    // 不复制 content 相关头，GET 请求无 body
                    if (h.Key.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)
                        || h.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                        continue;
                    newReq.Headers.TryAddWithoutValidation(h.Key, h.Value);
                }
                request.Dispose();
                request = newReq;
                continue;
            }

            var bytes = await response.Content.ReadAsByteArrayAsync();
            return (bytes, response);
        }
        throw OAException.InvalidResponse;
    }

    // MARK: - FileName extraction

    /// <summary>从 Content-Disposition 或 URL 提取文件名，处理兰凌 EKP 的各种编码坑</summary>
    public static string ExtractFileName(HttpResponseMessage http, Uri fallbackURL)
    {
        var cd = http.Content.Headers.ContentDisposition?.ToString() ?? "";
        if (string.IsNullOrEmpty(cd))
            cd = http.Headers.TryGetValues("Content-Disposition", out var vals) ? string.Join("", vals) : "";

        if (!string.IsNullOrEmpty(cd))
        {
            // RFC5987: filename*=UTF-8''xxx
            var m = Regex.Match(cd, @"filename\*=[^']*''([^;]+)");
            if (m.Success)
            {
                var decoded = Uri.UnescapeDataString(m.Groups[1].Value.Trim('"', ' '));
                if (!string.IsNullOrEmpty(decoded)) return decoded;
            }
            // filename="xxx"
            m = Regex.Match(cd, "filename=\"([^\"]+)\"");
            if (m.Success)
            {
                var name = m.Groups[1].Value;
                var decoded = Uri.UnescapeDataString(name);
                if (!string.IsNullOrEmpty(decoded) && decoded != name) return decoded;
                // UTF-8 字节被当作 Latin-1 解析
                try
                {
                    var latin1Bytes = Encoding.Latin1.GetBytes(name);
                    var utf8 = Encoding.UTF8.GetString(latin1Bytes);
                    if (!string.IsNullOrEmpty(utf8) && utf8 != name) return utf8;
                }
                catch { }
                if (!string.IsNullOrEmpty(name)) return name;
            }
            // filename=xxx
            m = Regex.Match(cd, "filename=([^;]+)");
            if (m.Success)
            {
                var name = m.Groups[1].Value.Trim(' ', '"');
                var decoded = Uri.UnescapeDataString(name);
                if (!string.IsNullOrEmpty(decoded) && decoded != name) return decoded;
                return name;
            }
        }
        return string.IsNullOrEmpty(fallbackURL.AbsolutePath.Split('/').Last()) ? "attachment.bin" : fallbackURL.AbsolutePath.Split('/').Last();
    }
}