using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Text;
using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>Jira 错误（移植自 Swift JiraError）</summary>
public class JiraException : Exception
{
    public enum ErrorKind { InvalidURL, InvalidResponse, HttpError, DecodingError, NoData, SessionExpired, LoginFailed }

    public ErrorKind Kind { get; }
    public int? StatusCode { get; }

    public JiraException(ErrorKind kind, string message, int? statusCode = null) : base(message)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public static JiraException InvalidURL => new(ErrorKind.InvalidURL, "无效的 URL");
    public static JiraException InvalidResponse => new(ErrorKind.InvalidResponse, "无效的服务器响应");
    public static JiraException DecodingError => new(ErrorKind.DecodingError, "数据解析错误");
    public static JiraException NoData => new(ErrorKind.NoData, "没有返回数据");
    public static JiraException SessionExpired => new(ErrorKind.SessionExpired, "会话已过期，请重新登录");
    public static JiraException HttpError(int code, string msg) => new(ErrorKind.HttpError, $"HTTP 错误 {code}: {msg}", code);
    public static JiraException LoginFailed(string msg) => new(ErrorKind.LoginFailed, $"登录失败: {msg}");
}

/// <summary>
/// Jira REST API 服务（移植自 Swift JiraService.swift）。
/// Session API 登录（JSESSIONID Cookie），失败自动降级 Basic Auth；401 自动重登重试一次；
/// 手动管理 Cookie 与重定向（保留原始 method/body/Header）。
/// </summary>
public class JiraService
{
    public static JiraService Shared { get; } = new JiraService();

    private static readonly TimeSpan SessionMaxAge = TimeSpan.FromDays(7);
    private const string UserAgent = "JiraMacTool/1.0";

    private readonly HttpClient _http;
    private readonly SemaphoreSlim _gate = new(1, 1);

    // MARK: - Session 状态
    private string? _sessionId;
    private DateTime? _sessionLoginTime;
    private string? _sessionUser;
    private bool _isLoggingIn;
    private bool _usingBasicAuthFallback;

    private JiraService()
    {
        var handler = new HttpClientHandler
        {
            // 禁用自动 cookie 管理与自动重定向，由我们手动控制
            UseCookies = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All
        };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(60) };

        // 从配置恢复 session
        var cfg = AppConfig.Shared;
        _sessionId = EmptyToNull(cfg.GetCustom("jira_session_id"));
        var ts = cfg.GetCustom("jira_session_login_time");
        if (!string.IsNullOrEmpty(ts) &&
            DateTime.TryParse(ts, null, DateTimeStyles.RoundtripKind, out var dt))
        {
            _sessionLoginTime = dt;
        }
        _sessionUser = EmptyToNull(cfg.GetCustom("jira_session_user"));
    }

    private static string? EmptyToNull(string s) => string.IsNullOrEmpty(s) ? null : s;

    /// <summary>当前 session 是否有效</summary>
    public bool IsSessionValid
    {
        get
        {
            if (string.IsNullOrEmpty(_sessionId) || _sessionLoginTime == null) return false;
            // 用户名变了也视为无效
            if (_sessionUser != AppConfig.Shared.JiraUser) return false;
            return DateTime.Now - _sessionLoginTime.Value < SessionMaxAge;
        }
    }

    /// <summary>获取 session 信息（供 UI 显示）</summary>
    public (bool IsValid, string? User, DateTime? LoginTime) SessionInfo =>
        (IsSessionValid, _sessionUser, _sessionLoginTime);

    // MARK: - 登录 / 登出

    /// <summary>
    /// 通过 Jira REST Session API 登录，获取 JSESSIONID。
    /// 如果 Session API 不可用，自动降级为 Basic Auth 模式。返回 displayName。
    /// </summary>
    public async Task<string> LoginAsync()
    {
        await _gate.WaitAsync();
        try { return await LoginCoreAsync(); }
        finally { _gate.Release(); }
    }

    private async Task<string> LoginCoreAsync()
    {
        var config = AppConfig.Shared;
        var baseURL = config.JiraURL.TrimEnd('/');
        var url = baseURL + "/rest/auth/1/session";
        if (!Uri.IsWellFormedUriString(url, UriKind.Absolute)) throw JiraException.InvalidURL;

        var loginBody = new JObject
        {
            ["username"] = config.JiraUser,
            ["password"] = config.JiraPassword
        };
        var bodyBytes = Encoding.UTF8.GetBytes(loginBody.ToString(Formatting.None));

        Log.Debug($"[JiraService] 正在通过 Session API 登录... 用户: {config.JiraUser}, URL: {url}");

        ResponseData resp;
        try
        {
            resp = await SendCoreAsync(url, HttpMethod.Post, bodyBytes, "application/json");
        }
        catch (JiraException) { throw; }
        catch (Exception ex)
        {
            Log.Debug($"[JiraService] Session API 请求异常: {ex.Message}");
            Log.Debug("[JiraService] 降级为 Basic Auth 模式");
            return await LoginWithBasicAuthAsync();
        }

        Log.Debug($"[JiraService] Session API 响应: {(int)resp.Status}");

        if (resp.Status == HttpStatusCode.OK)
        {
            // 尝试解析 session 响应
            var json = TryParseJObject(resp.Body);
            var sessionValue = json?["session"]?["value"]?.Value<string>();
            if (sessionValue != null)
            {
                // Session 登录成功
                _sessionId = sessionValue;
                _sessionLoginTime = DateTime.Now;
                _sessionUser = config.JiraUser;
                _usingBasicAuthFallback = false;
                PersistSession();

                Log.Debug($"[JiraService] ✅ Session 登录成功！JSESSIONID={sessionValue[..Math.Min(8, sessionValue.Length)]}...");

                // 调用 /myself 获取 displayName
                var displayName = await FetchDisplayNameAsync();
                return displayName ?? config.JiraUser;
            }
            else
            {
                var bodyStr = Encoding.UTF8.GetString(resp.Body);
                Log.Debug($"[JiraService] Session API 返回 200 但解析失败: {bodyStr[..Math.Min(500, bodyStr.Length)]}");
                Log.Debug("[JiraService] 降级为 Basic Auth 模式");
                return await LoginWithBasicAuthAsync();
            }
        }
        else if (resp.Status == HttpStatusCode.Unauthorized || resp.Status == HttpStatusCode.Forbidden)
        {
            var msg = Encoding.UTF8.GetString(resp.Body);
            Log.Debug($"[JiraService] Session API 认证失败: {msg[..Math.Min(200, msg.Length)]}");
            throw JiraException.LoginFailed("用户名或密码错误");
        }
        else
        {
            var bodyStr = Encoding.UTF8.GetString(resp.Body);
            Log.Debug($"[JiraService] Session API 返回 {(int)resp.Status}: {bodyStr[..Math.Min(200, bodyStr.Length)]}");
            Log.Debug("[JiraService] 降级为 Basic Auth 模式");
            return await LoginWithBasicAuthAsync();
        }
    }

    /// <summary>Basic Auth 降级登录：通过 /rest/api/2/myself 验证凭证</summary>
    private async Task<string> LoginWithBasicAuthAsync()
    {
        var config = AppConfig.Shared;
        var baseURL = config.JiraURL.TrimEnd('/');
        var url = baseURL + "/rest/api/2/myself";
        if (!Uri.IsWellFormedUriString(url, UriKind.Absolute)) throw JiraException.InvalidURL;

        Log.Debug("[JiraService] 尝试 Basic Auth 验证...");

        var headers = new Dictionary<string, string> { ["Authorization"] = BasicAuthHeader() };
        var resp = await SendCoreAsync(url, HttpMethod.Get, null, "application/json", headers);

        if (resp.Status == HttpStatusCode.OK)
        {
            _usingBasicAuthFallback = true;
            _sessionId = "BASIC_AUTH_FALLBACK";
            _sessionLoginTime = DateTime.Now;
            _sessionUser = config.JiraUser;
            PersistSession();

            var json = TryParseJObject(resp.Body);
            var displayName = json?["displayName"]?.Value<string>() ?? config.JiraUser;

            Log.Debug($"[JiraService] ✅ Basic Auth 登录成功！用户: {displayName}");
            return displayName;
        }
        else if (resp.Status == HttpStatusCode.Unauthorized || resp.Status == HttpStatusCode.Forbidden)
        {
            throw JiraException.LoginFailed("用户名或密码错误");
        }
        else
        {
            var msg = Encoding.UTF8.GetString(resp.Body);
            throw JiraException.LoginFailed(string.IsNullOrEmpty(msg) ? "未知错误" : msg);
        }
    }

    /// <summary>获取当前用户 displayName</summary>
    private async Task<string?> FetchDisplayNameAsync()
    {
        try
        {
            var data = await DoRequestAsync("/rest/api/2/myself");
            var json = TryParseJObject(data);
            return json?["displayName"]?.Value<string>();
        }
        catch (Exception ex)
        {
            Log.Debug($"[JiraService] 获取 displayName 失败: {ex.Message}");
            return null;
        }
    }

    /// <summary>登出，清除 session</summary>
    public async Task LogoutAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (_sessionId != null)
            {
                // 尝试调用 Jira 登出 API
                try
                {
                    var config = AppConfig.Shared;
                    var baseURL = config.JiraURL.TrimEnd('/');
                    var headers = new Dictionary<string, string> { ["Cookie"] = $"JSESSIONID={_sessionId}" };
                    await SendCoreAsync(baseURL + "/rest/auth/1/session", HttpMethod.Delete, null, null, headers);
                    Log.Debug("[JiraService] 已通知服务器登出");
                }
                catch (Exception ex)
                {
                    Log.Debug($"[JiraService] 登出请求失败（不影响本地清除）: {ex.Message}");
                }
            }
            ClearSession();
            Log.Debug("[JiraService] 已清除本地 session");
        }
        finally { _gate.Release(); }
    }

    /// <summary>确保 session 有效，无效则自动登录（须在 gate 内调用）</summary>
    private async Task EnsureSessionCoreAsync()
    {
        if (IsSessionValid) return;
        // 防止并发重复登录
        if (_isLoggingIn) return;
        _isLoggingIn = true;
        try
        {
            Log.Debug("[JiraService] Session 无效或已过期，自动重新登录...");
            _ = await LoginCoreAsync();
        }
        finally { _isLoggingIn = false; }
    }

    private void ClearSession()
    {
        _sessionId = null;
        _sessionLoginTime = null;
        _sessionUser = null;
        var cfg = AppConfig.Shared;
        cfg.SetCustom("jira_session_id", "");
        cfg.SetCustom("jira_session_login_time", "");
        cfg.SetCustom("jira_session_user", "");
    }

    private void PersistSession()
    {
        var cfg = AppConfig.Shared;
        cfg.SetCustom("jira_session_id", _sessionId ?? "");
        cfg.SetCustom("jira_session_login_time", _sessionLoginTime?.ToString("o") ?? "");
        cfg.SetCustom("jira_session_user", _sessionUser ?? "");
    }

    // MARK: - 请求

    private async Task<byte[]> MakeRequestAsync(string path, string method = "GET", byte[]? body = null)
    {
        // 确保有有效 session
        await EnsureSessionCoreAsync();
        return await DoRequestAsync(path, method, body);
    }

    /// <summary>执行实际的 HTTP 请求，使用 Cookie Session 认证；401 自动重登重试一次</summary>
    private async Task<byte[]> DoRequestAsync(string path, string method = "GET", byte[]? body = null, bool retried = false)
    {
        var config = AppConfig.Shared;
        var baseURL = config.JiraURL.TrimEnd('/');
        var url = baseURL + path;
        if (!Uri.IsWellFormedUriString(url, UriKind.Absolute)) throw JiraException.InvalidURL;

        var headers = BuildAuthHeaders();

        Log.Debug($"[JiraService] Request URL: {url} [{method}]");
        var resp = await SendCoreAsync(url, new HttpMethod(method), body, "application/json", headers);
        Log.Debug($"[JiraService] Response status: {(int)resp.Status}");

        // 401 表示 session 可能已过期，尝试重新登录后重试一次
        if (resp.Status == HttpStatusCode.Unauthorized && !retried)
        {
            Log.Debug("[JiraService] 收到 401，session 可能已过期，尝试重新登录...");
            ClearSession();
            _ = await LoginCoreAsync();
            return await DoRequestAsync(path, method, body, true);
        }

        if ((int)resp.Status >= 400)
        {
            var msg = Encoding.UTF8.GetString(resp.Body);
            Log.Debug($"[JiraService] Error body: {msg}");
            throw JiraException.HttpError((int)resp.Status, msg);
        }

        return resp.Body;
    }

    private Dictionary<string, string> BuildAuthHeaders()
    {
        var headers = new Dictionary<string, string>();
        if (_usingBasicAuthFallback)
        {
            headers["Authorization"] = BasicAuthHeader();
        }
        else if (_sessionId != null)
        {
            headers["Cookie"] = $"JSESSIONID={_sessionId}";
        }
        return headers;
    }

    private static string BasicAuthHeader()
    {
        var config = AppConfig.Shared;
        var authString = $"{config.JiraUser}:{config.JiraPassword}";
        return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(authString));
    }

    // MARK: - HTTP 核心（手动 Cookie / 手动重定向）

    private readonly record struct ResponseData(byte[] Body, HttpStatusCode Status);

    /// <summary>
    /// 发送请求并手动跟随重定向（对应 Swift 的 SessionRedirectDelegate：
    /// 保留原始 HTTP 方法和请求体、Cookie、Authorization、Content-Type）。
    /// </summary>
    private async Task<ResponseData> SendCoreAsync(
        string url, HttpMethod method, byte[]? bodyBytes, string? contentType,
        Dictionary<string, string>? headers = null, int maxRedirects = 5)
    {
        var currentUrl = url;

        for (int redirect = 0; ; redirect++)
        {
            using var request = new HttpRequestMessage(method, currentUrl);
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            request.Headers.TryAddWithoutValidation("Accept", "application/json");
            if (headers != null)
            {
                foreach (var kv in headers)
                    request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
            }
            if (bodyBytes != null)
            {
                var content = new ByteArrayContent(bodyBytes);
                if (contentType != null)
                    content.Headers.TryAddWithoutValidation("Content-Type", contentType);
                request.Content = content;
            }

            HttpResponseMessage response;
            try
            {
                response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
            {
                throw new JiraException(JiraException.ErrorKind.InvalidResponse, $"网络请求失败: {ex.Message}");
            }

            var status = (int)response.StatusCode;
            if (status is 301 or 302 or 303 or 307 or 308 && redirect < maxRedirects &&
                response.Headers.Location != null)
            {
                currentUrl = new Uri(new Uri(currentUrl), response.Headers.Location).ToString();
                response.Dispose();
                continue; // 保留 method/body/headers，与 Swift 版一致
            }

            var bytes = await response.Content.ReadAsByteArrayAsync();
            var result = new ResponseData(bytes, response.StatusCode);
            response.Dispose();
            return result;
        }
    }

    /// <summary>模拟 Swift urlQueryAllowed 字符集的 URL 编码</summary>
    private static string UrlQueryEncode(string s)
    {
        const string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!'()*;:@&=+$,/?";
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (allowed.IndexOf(c) >= 0) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    private static JObject? TryParseJObject(byte[] data)
    {
        try { return JObject.Parse(Encoding.UTF8.GetString(data)); }
        catch { return null; }
    }

    private static JObject ParseJObjectOrThrow(byte[] data)
    {
        var json = TryParseJObject(data);
        return json ?? throw JiraException.DecodingError;
    }

    // MARK: - Connection Test

    public async Task<string> TestConnectionAsync()
    {
        await _gate.WaitAsync();
        try
        {
            var data = await MakeRequestAsync("/rest/api/2/myself");
            var json = ParseJObjectOrThrow(data);
            return json["displayName"]?.Value<string>() ?? throw JiraException.DecodingError;
        }
        finally { _gate.Release(); }
    }

    // MARK: - Search

    public async Task<List<JiraIssue>> SearchJQLAsync(string jql, string fields = "*all", int maxResults = 1000)
    {
        await _gate.WaitAsync();
        try
        {
            var encodedJQL = UrlQueryEncode(jql);
            var path = $"/rest/api/2/search?jql={encodedJQL}&fields={fields}&maxResults={maxResults}";
            var data = await MakeRequestAsync(path);
            var json = ParseJObjectOrThrow(data);
            var issues = json["issues"] as JArray ?? throw JiraException.DecodingError;
            return issues.OfType<JObject>().Select(ParseIssue).Where(i => i != null).Cast<JiraIssue>().ToList();
        }
        finally { _gate.Release(); }
    }

    // MARK: - Issue CRUD

    public async Task<JiraIssue> GetIssueAsync(string key)
    {
        await _gate.WaitAsync();
        try
        {
            var data = await MakeRequestAsync($"/rest/api/2/issue/{key}");
            var json = ParseJObjectOrThrow(data);
            return ParseIssue(json) ?? throw JiraException.DecodingError;
        }
        finally { _gate.Release(); }
    }

    /// <summary>获取 issue 的原始 JSON（可选 expand），便于读取 names / schema 等附加信息</summary>
    public async Task<JObject> GetIssueRawAsync(string key, string? expand = null)
    {
        await _gate.WaitAsync();
        try
        {
            var path = $"/rest/api/2/issue/{key}";
            if (!string.IsNullOrEmpty(expand)) path += $"?expand={expand}";
            var data = await MakeRequestAsync(path);
            return ParseJObjectOrThrow(data);
        }
        finally { _gate.Release(); }
    }

    /// <summary>获取指定项目和IssueType的创建字段元数据（含 allowedValues）</summary>
    public async Task<JObject?> GetCreateMetaFieldsAsync(string projectKey, string issueTypeName)
    {
        await _gate.WaitAsync();
        try
        {
            var path = $"/rest/api/2/issue/createmeta?projectKeys={projectKey}&issuetypeNames={UrlQueryEncode(issueTypeName)}&expand=projects.issuetypes.fields";
            var data = await MakeRequestAsync(path);
            var json = ParseJObjectOrThrow(data);
            var projects = json["projects"] as JArray;
            if (projects == null || projects.Count == 0) return null;
            var issueTypes = projects[0]?["issuetypes"] as JArray;
            if (issueTypes == null || issueTypes.Count == 0) return null;
            return issueTypes[0]?["fields"] as JObject;
        }
        catch (Exception ex)
        {
            Log.Debug($"[JiraService] GetCreateMetaFieldsAsync failed: {ex.Message}");
            return null;
        }
        finally { _gate.Release(); }
    }

    /// <summary>按名字搜索用户（Jira 用户名/显示名），返回用户字典数组</summary>
    public async Task<JArray> SearchUsersAsync(string query)
    {
        await _gate.WaitAsync();
        try
        {
            var encoded = UrlQueryEncode(query);
            var data = await MakeRequestAsync($"/rest/api/2/user/search?username={encoded}&maxResults=5");
            try
            {
                return JArray.Parse(Encoding.UTF8.GetString(data));
            }
            catch { return new JArray(); }
        }
        finally { _gate.Release(); }
    }

    public async Task<string> CreateIssueAsync(string project, string issueType, JObject fields)
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject { ["fields"] = fields };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            var responseData = await MakeRequestAsync("/rest/api/2/issue", "POST", bodyBytes);
            var json = ParseJObjectOrThrow(responseData);
            return json["key"]?.Value<string>() ?? throw JiraException.DecodingError;
        }
        finally { _gate.Release(); }
    }

    public async Task UpdateIssueAsync(string key, JObject fields)
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject { ["fields"] = fields };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            _ = await MakeRequestAsync($"/rest/api/2/issue/{key}", "PUT", bodyBytes);
        }
        finally { _gate.Release(); }
    }

    /// <summary>通过 update 操作更新问题字段（适用于 labels 等不支持 fields 直接设置的字段）</summary>
    public async Task UpdateIssueOperationsAsync(string key, JObject updateBlock)
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject { ["update"] = updateBlock };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            _ = await MakeRequestAsync($"/rest/api/2/issue/{key}", "PUT", bodyBytes);
        }
        finally { _gate.Release(); }
    }

    public async Task AddCommentAsync(string issueKey, string body)
    {
        await _gate.WaitAsync();
        try
        {
            var bodyJson = new JObject { ["body"] = body };
            var bodyBytes = Encoding.UTF8.GetBytes(bodyJson.ToString(Formatting.None));
            _ = await MakeRequestAsync($"/rest/api/2/issue/{issueKey}/comment", "POST", bodyBytes);
        }
        finally { _gate.Release(); }
    }

    public async Task TransitionIssueAsync(string issueKey, string transitionId)
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject { ["transition"] = new JObject { ["id"] = transitionId } };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            _ = await MakeRequestAsync($"/rest/api/2/issue/{issueKey}/transitions", "POST", bodyBytes);
        }
        finally { _gate.Release(); }
    }

    public async Task LinkIssuesAsync(string from, string to, string linkType = "关联")
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject
            {
                ["type"] = new JObject { ["name"] = linkType },
                ["inwardIssue"] = new JObject { ["key"] = from },
                ["outwardIssue"] = new JObject { ["key"] = to }
            };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            _ = await MakeRequestAsync("/rest/api/2/issueLink", "POST", bodyBytes);
        }
        finally { _gate.Release(); }
    }

    // MARK: - Versions

    public async Task<List<JiraVersion>> GetProjectVersionsAsync(string project = "REQ")
    {
        await _gate.WaitAsync();
        try
        {
            var data = await MakeRequestAsync($"/rest/api/2/project/{project}/versions");
            JArray arr;
            try { arr = JArray.Parse(Encoding.UTF8.GetString(data)); }
            catch { throw JiraException.DecodingError; }

            return arr.OfType<JObject>()
                .Select(d => new JiraVersion
                {
                    Id = d["id"]?.Value<string>() ?? "",
                    Name = d["name"]?.Value<string>() ?? "",
                    Description = d["description"]?.Value<string>(),
                    ReleaseDate = d["releaseDate"]?.Value<string>(),
                    Archived = d["archived"]?.Value<bool>() ?? false,
                    Released = d["released"]?.Value<bool>() ?? false,
                    SelfUrl = d["self"]?.Value<string>() ?? ""
                })
                .Where(v => !string.IsNullOrEmpty(v.Id) && !string.IsNullOrEmpty(v.Name))
                .ToList();
        }
        finally { _gate.Release(); }
    }

    public async Task<JiraVersion> CreateVersionAsync(string project = "REQ", string name = "", string description = "", string releaseDate = "")
    {
        await _gate.WaitAsync();
        try
        {
            var body = new JObject
            {
                ["project"] = project,
                ["name"] = name,
                ["description"] = description,
                ["releaseDate"] = releaseDate,
                ["archived"] = false,
                ["released"] = false
            };
            var bodyBytes = Encoding.UTF8.GetBytes(body.ToString(Formatting.None));
            var responseData = await MakeRequestAsync("/rest/api/2/version", "POST", bodyBytes);
            var json = ParseJObjectOrThrow(responseData);
            var id = json["id"]?.Value<string>();
            var retName = json["name"]?.Value<string>();
            if (id == null || retName == null) throw JiraException.DecodingError;

            return new JiraVersion
            {
                Id = id,
                Name = retName,
                Description = json["description"]?.Value<string>(),
                ReleaseDate = json["releaseDate"]?.Value<string>(),
                Archived = json["archived"]?.Value<bool>() ?? false,
                Released = json["released"]?.Value<bool>() ?? false,
                SelfUrl = json["self"]?.Value<string>() ?? ""
            };
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteVersionAsync(string versionId)
    {
        await _gate.WaitAsync();
        try { _ = await MakeRequestAsync($"/rest/api/2/version/{versionId}", "DELETE"); }
        finally { _gate.Release(); }
    }

    // MARK: - Attachments

    /// <summary>获取 issue 的附件列表（原始字典数组，由调用方解析字段）</summary>
    public async Task<JArray> GetAttachmentsAsync(string issueKey)
    {
        var issue = await GetIssueAsync(issueKey);
        return issue.Fields["attachment"] as JArray ?? new JArray();
    }

    /// <summary>下载附件内容（传入 attachment.content 绝对 URL）。401 自动重登重试</summary>
    public async Task<byte[]> DownloadAttachmentDataAsync(string urlString)
    {
        await _gate.WaitAsync();
        try { return await DownloadAttachmentDataCoreAsync(urlString); }
        finally { _gate.Release(); }
    }

    private async Task<byte[]> DownloadAttachmentDataCoreAsync(string urlString)
    {
        await EnsureSessionCoreAsync();
        if (!Uri.IsWellFormedUriString(urlString, UriKind.Absolute)) throw JiraException.InvalidURL;

        Log.Debug($"[JiraService] Download attachment: {urlString}");
        var resp = await SendCoreAsync(urlString, HttpMethod.Get, null, null, BuildAuthHeaders());

        if (resp.Status == HttpStatusCode.Unauthorized)
        {
            ClearSession();
            _ = await LoginCoreAsync();
            return await DownloadAttachmentDataCoreAsync(urlString);
        }
        if ((int)resp.Status >= 400)
        {
            throw JiraException.HttpError((int)resp.Status, Encoding.UTF8.GetString(resp.Body));
        }
        return resp.Body;
    }

    /// <summary>上传附件（multipart/form-data）。401 自动重登重试</summary>
    public async Task UploadAttachmentAsync(string issueKey, string fileName, byte[] fileData, string mimeType = "application/octet-stream")
    {
        await _gate.WaitAsync();
        try { await UploadAttachmentCoreAsync(issueKey, fileName, fileData, mimeType); }
        finally { _gate.Release(); }
    }

    private async Task UploadAttachmentCoreAsync(string issueKey, string fileName, byte[] fileData, string mimeType)
    {
        await EnsureSessionCoreAsync();

        var config = AppConfig.Shared;
        var baseURL = config.JiraURL.TrimEnd('/');
        var url = $"{baseURL}/rest/api/2/issue/{issueKey}/attachments";
        if (!Uri.IsWellFormedUriString(url, UriKind.Absolute)) throw JiraException.InvalidURL;

        var boundary = "Boundary-" + Guid.NewGuid().ToString("N");
        using var ms = new MemoryStream();
        void WriteStr(string s) { var b = Encoding.UTF8.GetBytes(s); ms.Write(b, 0, b.Length); }

        WriteStr($"--{boundary}\r\n");
        // 文件名对双引号进行转义
        var safeName = fileName.Replace("\"", "_");
        WriteStr($"Content-Disposition: form-data; name=\"file\"; filename=\"{safeName}\"\r\n");
        WriteStr($"Content-Type: {mimeType}\r\n\r\n");
        ms.Write(fileData, 0, fileData.Length);
        WriteStr($"\r\n--{boundary}--\r\n");
        var bodyBytes = ms.ToArray();

        var headers = BuildAuthHeaders();
        headers["X-Atlassian-Token"] = "no-check";

        Log.Debug($"[JiraService] Upload attachment: {safeName} ({fileData.Length} bytes) -> {issueKey}");
        var resp = await SendCoreAsync(url, HttpMethod.Post, bodyBytes, $"multipart/form-data; boundary={boundary}", headers);

        if (resp.Status == HttpStatusCode.Unauthorized)
        {
            ClearSession();
            _ = await LoginCoreAsync();
            await UploadAttachmentCoreAsync(issueKey, fileName, fileData, mimeType);
            return;
        }
        if ((int)resp.Status >= 400)
        {
            throw JiraException.HttpError((int)resp.Status, Encoding.UTF8.GetString(resp.Body));
        }
    }

    /// <summary>删除指定附件（DELETE /rest/api/2/attachment/{id}）。401 自动重登重试</summary>
    public async Task DeleteAttachmentAsync(string id)
    {
        await _gate.WaitAsync();
        try { await DeleteAttachmentCoreAsync(id); }
        finally { _gate.Release(); }
    }

    private async Task DeleteAttachmentCoreAsync(string id)
    {
        await EnsureSessionCoreAsync();

        var config = AppConfig.Shared;
        var baseURL = config.JiraURL.TrimEnd('/');
        var url = $"{baseURL}/rest/api/2/attachment/{id}";
        if (!Uri.IsWellFormedUriString(url, UriKind.Absolute)) throw JiraException.InvalidURL;

        var headers = BuildAuthHeaders();
        headers["X-Atlassian-Token"] = "no-check";

        Log.Debug($"[JiraService] Delete attachment: id={id}");
        var resp = await SendCoreAsync(url, HttpMethod.Delete, null, null, headers);

        if (resp.Status == HttpStatusCode.Unauthorized)
        {
            ClearSession();
            _ = await LoginCoreAsync();
            await DeleteAttachmentCoreAsync(id);
            return;
        }
        // 成功：204 No Content；部分实例可能 200
        if ((int)resp.Status >= 400)
        {
            throw JiraException.HttpError((int)resp.Status, Encoding.UTF8.GetString(resp.Body));
        }
    }

    // MARK: - Helpers

    private static JiraIssue? ParseIssue(JObject dict)
    {
        var key = dict["key"]?.Value<string>();
        var fields = dict["fields"] as JObject;
        if (key == null || fields == null) return null;

        return new JiraIssue
        {
            Key = key,
            Summary = fields["summary"]?.Value<string>() ?? "",
            Fields = fields,
            Labels = fields["labels"]?.ToObject<List<string>>() ?? new List<string>(),
            Status = fields["status"]?["name"]?.Value<string>() ?? "",
            IssueType = fields["issuetype"]?["name"]?.Value<string>() ?? ""
        };
    }

    /// <summary>生成自定义字段选项值（self/value/id 格式）</summary>
    public JObject GetFieldString(string name, string value, string id)
    {
        return new JObject
        {
            ["self"] = $"http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/{id}",
            ["value"] = value,
            ["id"] = id
        };
    }
}
