using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json;

namespace JiraWinTool.Services;

public class WebDavException : Exception
{
    private WebDavException(string message) : base(message) { }

    public static WebDavException NotConfigured => new("WebDAV 未配置，请先设置 WebDAV 连接信息");
    public static WebDavException InvalidURL => new("WebDAV URL 无效");
    public static WebDavException UploadFailed(string msg) => new($"上传失败: {msg}");
    public static WebDavException DownloadFailed(string msg) => new($"下载失败: {msg}");
    public static WebDavException MergeFailed(string msg) => new($"合并失败: {msg}");
}

/// <summary>WebDAV 同步服务（移植自 Swift WebDavService.swift）：PUT/GET/PROPFIND</summary>
public class WebDavService
{
    public static WebDavService Shared { get; } = new();

    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        AllowAutoRedirect = true,
        AutomaticDecompression = DecompressionMethods.All
    });

    private WebDavService() { }

    // MARK: - 构建请求

    private static Uri BuildUri()
    {
        var config = AppConfig.Shared;
        if (!config.IsWebdavConfigured) throw WebDavException.NotConfigured;

        var baseUrl = config.WebdavURL.TrimEnd('/');
        var path = config.WebdavRemotePath;
        if (!path.StartsWith('/')) path = "/" + path;

        if (!Uri.TryCreate(baseUrl + path, UriKind.Absolute, out var uri))
            throw WebDavException.InvalidURL;
        return uri;
    }

    private static AuthenticationHeaderValue AuthHeader()
    {
        var config = AppConfig.Shared;
        var credentials = $"{config.WebdavUser}:{config.WebdavPassword}";
        return new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(credentials)));
    }

    // MARK: - 上传（PUT）

    /// <summary>将本地收藏列表上传到 WebDAV</summary>
    public async Task UploadAsync(List<FavoriteJira> favorites)
    {
        var uri = BuildUri();
        // FavoriteJira 的 JsonConverter 特性保证日期编码与 macOS 版一致（Apple 参考日期秒数）
        var json = JsonConvert.SerializeObject(favorites);

        using var req = new HttpRequestMessage(HttpMethod.Put, uri);
        req.Headers.Authorization = AuthHeader();
        req.Content = new StringContent(json, Encoding.UTF8, "application/json");

        using var resp = await Http.SendAsync(req);
        if ((int)resp.StatusCode < 200 || (int)resp.StatusCode > 299)
            throw WebDavException.UploadFailed($"HTTP {(int)resp.StatusCode}");
    }

    // MARK: - 下载（GET）

    /// <summary>从 WebDAV 下载收藏列表（远程文件不存在时返回空列表）</summary>
    public async Task<List<FavoriteJira>> DownloadAsync()
    {
        var uri = BuildUri();

        using var req = new HttpRequestMessage(HttpMethod.Get, uri);
        req.Headers.Authorization = AuthHeader();

        using var resp = await Http.SendAsync(req);

        if (resp.StatusCode == HttpStatusCode.NotFound)
            return new List<FavoriteJira>();

        if ((int)resp.StatusCode < 200 || (int)resp.StatusCode > 299)
            throw WebDavException.DownloadFailed($"HTTP {(int)resp.StatusCode}");

        var data = await resp.Content.ReadAsByteArrayAsync();
        if (data.Length == 0) return new List<FavoriteJira>();

        try
        {
            return JsonConvert.DeserializeObject<List<FavoriteJira>>(Encoding.UTF8.GetString(data))
                   ?? new List<FavoriteJira>();
        }
        catch (Exception ex)
        {
            throw WebDavException.DownloadFailed($"JSON 解析失败: {ex.Message}");
        }
    }

    // MARK: - 合并

    /// <summary>合并本地和远程收藏列表（以 key 为唯一标识，取 addedAt 较新的）</summary>
    public List<FavoriteJira> Merge(List<FavoriteJira> local, List<FavoriteJira> remote)
    {
        var merged = new Dictionary<string, FavoriteJira>();

        // 先放入远程数据
        foreach (var item in remote)
            merged[item.Key] = item;

        // 本地数据覆盖或补充（本地优先，因为本地每次变更都会自动同步）
        foreach (var item in local)
        {
            if (merged.TryGetValue(item.Key, out var existing))
            {
                // addedAt 相同时本地优先（>= 而非 >）
                if (item.AddedAt >= existing.AddedAt)
                    merged[item.Key] = item;
            }
            else
            {
                merged[item.Key] = item;
            }
        }

        // 按收藏时间倒序排列
        return merged.Values.OrderByDescending(i => i.AddedAt).ToList();
    }

    // MARK: - 测试连接

    /// <summary>测试 WebDAV 连接是否正常（PROPFIND Depth:0）</summary>
    public async Task<string> TestConnectionAsync()
    {
        var config = AppConfig.Shared;
        if (!config.IsWebdavConfigured) throw WebDavException.NotConfigured;

        var baseUrl = config.WebdavURL.TrimEnd('/') + "/";
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri))
            throw WebDavException.InvalidURL;

        using var req = new HttpRequestMessage(new HttpMethod("PROPFIND"), uri);
        req.Headers.Authorization = AuthHeader();
        req.Headers.TryAddWithoutValidation("Depth", "0");

        using var resp = await Http.SendAsync(req);

        // 207 Multi-Status 是 PROPFIND 的正常响应
        if ((int)resp.StatusCode == 207 || ((int)resp.StatusCode >= 200 && (int)resp.StatusCode <= 299))
            return "连接成功 ✅";
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw WebDavException.DownloadFailed("认证失败，请检查用户名和密码");
        throw WebDavException.DownloadFailed($"HTTP {(int)resp.StatusCode}");
    }
}
