using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using JiraWinTool.Models;
using JiraWinTool.Utils;

namespace JiraWinTool.Services;

/// <summary>OA 登录认证（移植自 Swift OAService+Auth.swift）</summary>
public partial class OAService
{
    // MARK: - Login flow

    private async Task DoLoginAsync(string baseURL, string? verifyURL = null)
    {
        var cfg = AppConfig.Shared;
        var user = cfg.JiraUser;
        var password = cfg.JiraPassword;
        if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(password))
            throw OAException.LoginFailed("未配置 Jira 账号/密码（OA 共用域账号）");

        Log.Debug($"[OAService] 登录凭据: user={user}, password={password}");
        ClearSession();

        var diagnostics = new List<string>();

        // 先尝试解析真实登录表单
        DiscoveredLoginForm? discovered = null;
        try { discovered = await DiscoverLoginFormAsync(baseURL); } catch { }

        if (discovered != null)
        {
            var hf = discovered.HiddenFields.Count > 0
                ? " hidden=[" + string.Join(",", discovered.HiddenFields.Select(x => x.Item1 + "=" + (x.Item2.Length > 30 ? x.Item2[..30] + "..." : x.Item2))) + "]"
                : "";
            diagnostics.Add($"  [解析到登录表单] action={discovered.Action} userField={discovered.UserField} passField={discovered.PassField}{hf}");
        }
        else
            diagnostics.Add("  [解析登录表单失败] 回退枚举探测");

        // 尝试列表：优先用解析出的表单，再回退枚举
        var attempts = new List<LoginAttempt>();
        if (discovered != null)
            attempts.Add(new LoginAttempt
            {
                Path = discovered.Action,
                UserField = discovered.UserField,
                PassField = discovered.PassField,
                ExtraFields = discovered.HiddenFields
            });
        attempts.AddRange(EnumeratedAttempts());

        foreach (var attempt in attempts)
        {
            var savedCookies = new Dictionary<string, string>(_cookies);
            try
            {
                var result = await PostLoginAsync(baseURL, attempt, user, password);
                diagnostics.Add($"  [{attempt.Path} | {attempt.UserField}] status={result.StatusCode} loc={result.Location} body={result.BodySnippet}");

                // 快速跳过已知失败模式
                if (result.StatusCode is >= 300 and < 400 && LooksLikeLoginRedirect(result.Location))
                {
                    _cookies.Clear();
                    foreach (var kv in savedCookies) _cookies[kv.Key] = kv.Value;
                    continue;
                }

                // 明确成功：302 跳到非登录页
                if (result.StatusCode is >= 300 and < 400 && !string.IsNullOrEmpty(result.Location))
                {
                    await FollowRedirectAsync(baseURL, result.Location);
                    _loggedInBaseURL = baseURL;
                    _loggedInUser = user;
                    Log.Debug($"[OAService] 登录成功 via {attempt.Path}（302跳非登录页），loc={result.Location}");
                    diagnostics.Add("  → 认定登录成功（302 跳非登录页）");
                    return;
                }

                // 没有明确 302 信号，用 verifyURL 校验
                if (await VerifyLoginAsync(baseURL, verifyURL))
                {
                    _loggedInBaseURL = baseURL;
                    _loggedInUser = user;
                    Log.Debug($"[OAService] 登录成功 via {attempt.Path}");
                    return;
                }
                _cookies.Clear();
                foreach (var kv in savedCookies) _cookies[kv.Key] = kv.Value;
            }
            catch (Exception ex)
            {
                diagnostics.Add($"  [{attempt.Path}] 异常: {ex.Message}");
                _cookies.Clear();
                foreach (var kv in savedCookies) _cookies[kv.Key] = kv.Value;
            }
        }

        var tail = string.Join("\n", diagnostics);
        throw OAException.LoginFailed("全部登录入口尝试失败。诊断明细：\n" + tail);
    }

    /// <summary>枚举常见的 EKP 登录入口组合</summary>
    private static List<LoginAttempt> EnumeratedAttempts()
    {
        return new List<LoginAttempt>
        {
            new() { Path = "/sys/login/login.do?method=login", UserField = "userName", PassField = "password" },
            new() { Path = "/sys/login/login.do", UserField = "userName", PassField = "password" },
            new() { Path = "/sys/login/login.do?flag=login", UserField = "userName", PassField = "password" },
            new() { Path = "/sys/login/login.do?method=login", UserField = "loginName", PassField = "password" },
            new() { Path = "/sys/login/login.do", UserField = "loginName", PassField = "password" },
            new() { Path = "/sys/login/checkLogin.do", UserField = "loginName", PassField = "password" },
            new() { Path = "/sys/login/doLogin.do", UserField = "loginName", PassField = "password" },
            new() { Path = "/sys/login/login.do", UserField = "username", PassField = "password" },
            new() { Path = "/login", UserField = "username", PassField = "password" },
            new() { Path = "/j_security_check", UserField = "j_username", PassField = "j_password" },
            new() { Path = "/login.do?method=check", UserField = "j_username", PassField = "j_password" },
            new() { Path = "/sys/login/login.do", UserField = "j_username", PassField = "j_password" },
            new() { Path = "/sys/login/doLogin.do", UserField = "j_username", PassField = "j_password" },
            new() { Path = "/login.jsp", UserField = "j_username", PassField = "j_password" },
        };
    }

    /// <summary>GET 登录页并解析 form</summary>
    private async Task<DiscoveredLoginForm?> DiscoverLoginFormAsync(string baseURL)
    {
        var candidates = new[] { "/login.jsp", "/sys/login/login.jsp", "/sys/login/login.do", "/" };
        foreach (var path in candidates)
        {
            if (!Uri.TryCreate(baseURL + path, UriKind.Absolute, out var url)) continue;

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
            AttachCookie(request);

            try
            {
                var (data, http) = await SendAsync(request);
                AbsorbSetCookies(http, url);

                // 3xx 跟随一次
                if (http.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest
                    && http.Headers.Location != null)
                {
                    var nextUrl = new Uri(url, http.Headers.Location);
                    using var r2 = new HttpRequestMessage(HttpMethod.Get, nextUrl);
                    r2.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
                    AttachCookie(r2);
                    var (d2, h2) = await SendAsync(r2);
                    AbsorbSetCookies(h2, nextUrl);
                    if ((int)h2.StatusCode == 200)
                    {
                        var html = DecodeBody(d2, h2);
                        var form = ParseLoginForm(html);
                        if (form != null) return form;
                    }
                    continue;
                }

                if ((int)http.StatusCode == 200)
                {
                    var html = DecodeBody(data, http);
                    var form = ParseLoginForm(html);
                    if (form != null) return form;
                }
            }
            catch { }
        }
        return null;
    }

    /// <summary>POST 登录请求</summary>
    private async Task<LoginPostResult> PostLoginAsync(string baseURL, LoginAttempt attempt, string user, string password)
    {
        var actionUrl = BuildActionURL(baseURL, attempt.Path);

        using var request = new HttpRequestMessage(HttpMethod.Post, actionUrl);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        request.Headers.TryAddWithoutValidation("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
        request.Headers.TryAddWithoutValidation("Origin", baseURL);
        request.Headers.TryAddWithoutValidation("Referer", baseURL + "/login.jsp");
        request.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        AttachCookie(request);

        var pairs = new List<string>
        {
            $"{Uri.EscapeDataString(attempt.UserField)}={Uri.EscapeDataString(user)}",
            $"{Uri.EscapeDataString(attempt.PassField)}={Uri.EscapeDataString(password)}",
            "_validateFlag=1",
            "rememberMe=true"
        };
        foreach (var (k, v) in attempt.ExtraFields)
        {
            if (k == attempt.UserField || k == attempt.PassField) continue;
            pairs.Add($"{Uri.EscapeDataString(k)}={Uri.EscapeDataString(v)}");
        }
        request.Content = new StringContent(string.Join("&", pairs), Encoding.UTF8, "application/x-www-form-urlencoded");

        var bodyLog = string.Join("&", pairs.Select(p => p.StartsWith(attempt.PassField + "=", StringComparison.OrdinalIgnoreCase) ? attempt.PassField + "=***" : p));
        Log.Debug($"[OAService] 尝试登录: {actionUrl} 字段={attempt.UserField}/{attempt.PassField} body={bodyLog}");
        HttpResponseMessage http;
        byte[] data;
        try
        {
            (data, http) = await SendAsync(request, maxRedirects: 0); // 登录 POST 不跟随重定向，直接看 302 判定成功
        }
        catch (Exception ex)
        {
            return new LoginPostResult { StatusCode = -1, Location = "", BodySnippet = ex.Message };
        }

        AbsorbSetCookies(http, new Uri(actionUrl));
        var location = http.Headers.Location?.ToString() ?? "";
        var bodyText = DecodeBody(data, http);
        var snippet = Regex.Replace(bodyText, @"\n", " ")[..Math.Min(140, bodyText.Length)];

        Log.Debug($"[OAService] 响应: {(int)http.StatusCode} loc={location}");
        return new LoginPostResult { StatusCode = (int)http.StatusCode, Location = location, BodySnippet = snippet };
    }

    private static string BuildActionURL(string baseURL, string actionPath)
    {
        if (actionPath.StartsWith("http://") || actionPath.StartsWith("https://"))
            return actionPath;
        if (actionPath.StartsWith("#") || actionPath.StartsWith("javascript:", StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(actionPath))
            return baseURL + "/sys/login/login.do?method=login";
        var fullPath = actionPath.StartsWith('/') ? actionPath : "/" + actionPath;
        return baseURL + fullPath;
    }

    /// <summary>登录 POST 后跟随一次 302 跳转</summary>
    private async Task FollowRedirectAsync(string baseURL, string location)
    {
        var target = location.StartsWith("http") ? location
            : location.StartsWith("/") ? baseURL + location
            : baseURL + "/" + location;
        if (!Uri.TryCreate(target, UriKind.Absolute, out var url)) return;

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        request.Headers.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        AttachCookie(request);
        try
        {
            var (_, http) = await SendAsync(request);
            AbsorbSetCookies(http, url);
        }
        catch (Exception ex) { Log.Debug($"[OAService] followRedirect 失败: {ex.Message}"); }
    }

    /// <summary>验证登录是否成功</summary>
    private async Task<bool> VerifyLoginAsync(string baseURL, string? verifyURL = null)
    {
        var target = verifyURL ?? (baseURL + "/");
        if (!Uri.TryCreate(target, UriKind.Absolute, out var url)) return false;

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", BrowserUA);
        AttachCookie(request);

        try
        {
            var (data, http) = await SendAsync(request);
            AbsorbSetCookies(http, url);

            if (http.StatusCode is >= HttpStatusCode.MovedPermanently and < HttpStatusCode.BadRequest)
            {
                var location = http.Headers.Location?.ToString() ?? "";
                return !LooksLikeLoginRedirect(location);
            }
            if ((int)http.StatusCode == 200)
            {
                var html = DecodeBody(data, http);
                return !LooksLikeLoginPage(html);
            }
        }
        catch { }
        return false;
    }

    // MARK: - Form parsing

    /// <summary>从 HTML 中解析登录 form</summary>
    public static DiscoveredLoginForm? ParseLoginForm(string html)
    {
        var formBlock = ExtractFormContainingPassword(html);
        if (formBlock == null) return null;

        var action = ExtractAttr("action", formBlock) ?? "";
        var passField = ExtractInputNameOfType("password", formBlock);
        if (passField == null) return null;

        var userField = ExtractUsernameFieldName(formBlock, passField) ?? "username";
        var hidden = ExtractHiddenInputs(formBlock);
        return new DiscoveredLoginForm { Action = action, UserField = userField, PassField = passField, HiddenFields = hidden };
    }

    private static string? ExtractFormContainingPassword(string html)
    {
        var matches = Regex.Matches(html, @"<form[^>]*>.*?</form>", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        return matches.Select(m => m.Value)
            .FirstOrDefault(block => Regex.IsMatch(block, @"type\s*=\s*[""']?password", RegexOptions.IgnoreCase));
    }

    private static string? ExtractAttr(string name, string tag)
    {
        var m = Regex.Match(tag, $@"{name}\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))", RegexOptions.IgnoreCase);
        if (!m.Success) return null;
        for (int i = 1; i <= 3; i++)
            if (m.Groups[i].Success) return m.Groups[i].Value;
        return null;
    }

    private static string? ExtractInputNameOfType(string type, string formBlock)
    {
        var matches = Regex.Matches(formBlock, @"<input[^>]*>", RegexOptions.IgnoreCase);
        foreach (Match m in matches)
        {
            var tag = m.Value;
            var t = ExtractAttr("type", tag)?.ToLowerInvariant();
            if (t == type.ToLowerInvariant())
            {
                var n = ExtractAttr("name", tag);
                if (!string.IsNullOrEmpty(n)) return n;
            }
        }
        return null;
    }

    private static string? ExtractUsernameFieldName(string formBlock, string passName)
    {
        var preferNames = new[] { "username", "userName", "loginName", "loginname", "j_username", "user", "account", "loginId" };
        string? first = null;
        var matches = Regex.Matches(formBlock, @"<input[^>]*>", RegexOptions.IgnoreCase);
        foreach (Match m in matches)
        {
            var tag = m.Value;
            var t = ExtractAttr("type", tag)?.ToLowerInvariant() ?? "text";
            if (t is "hidden" or "password" or "submit" or "button" or "checkbox" or "radio") continue;
            var n = ExtractAttr("name", tag);
            if (string.IsNullOrEmpty(n) || n == passName) continue;
            if (preferNames.Contains(n)) return n;
            first ??= n;
        }
        return first;
    }

    private static List<(string, string)> ExtractHiddenInputs(string formBlock)
    {
        var list = new List<(string, string)>();
        var matches = Regex.Matches(formBlock, @"<input[^>]*>", RegexOptions.IgnoreCase);
        foreach (Match m in matches)
        {
            var tag = m.Value;
            if (ExtractAttr("type", tag)?.ToLowerInvariant() != "hidden") continue;
            var n = ExtractAttr("name", tag);
            if (string.IsNullOrEmpty(n)) continue;
            var v = ExtractAttr("value", tag) ?? "";
            list.Add((n, v));
        }
        return list;
    }
}
