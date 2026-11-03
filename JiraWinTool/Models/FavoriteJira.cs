using System.Runtime.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;
using JiraWinTool.Utils;
using Newtonsoft.Json;

namespace JiraWinTool.Models;

/// <summary>
/// Apple 参考日期 JSON 转换器：Swift JSONEncoder 默认把 Date 编码为
/// 2001-01-01T00:00:00Z 起的秒数（Double）。为与 macOS 版 WebDAV 同步文件互通，
/// 本转换器使用完全相同的编码格式。
/// </summary>
public class AppleDateConverter : JsonConverter
{
    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override bool CanConvert(Type objectType) =>
        objectType == typeof(DateTime) || objectType == typeof(DateTime?);

    public override void WriteJson(JsonWriter writer, object? value, JsonSerializer serializer)
    {
        if (value is DateTime dt)
        {
            writer.WriteValue((dt.ToUniversalTime() - AppleEpoch).TotalSeconds);
        }
        else
        {
            writer.WriteNull();
        }
    }

    public override object? ReadJson(JsonReader reader, Type objectType, object? existingValue, JsonSerializer serializer)
    {
        if (reader.TokenType == JsonToken.Null) return null;
        if (reader.TokenType == JsonToken.Date && reader.Value is DateTime dt) return dt;
        if (reader.TokenType is JsonToken.Integer or JsonToken.Float)
        {
            var seconds = Convert.ToDouble(reader.Value);
            return AppleEpoch.AddSeconds(seconds).ToLocalTime();
        }
        // 容错：ISO 字符串
        if (reader.TokenType == JsonToken.String &&
            DateTime.TryParse(reader.Value as string, out var parsed))
        {
            return parsed;
        }
        return null;
    }
}

/// <summary>收藏 Jira 项（移植自 Swift FavoriteModels.swift，JSON 键名与 Swift Codable 一致）</summary>
public partial class FavoriteJira : ObservableObject
{
    [JsonProperty("id")] public string Id { get; set; } = "";
    [JsonProperty("key")] public string Key { get; set; } = "";
    [JsonProperty("issueType")] public string IssueType { get; set; } = "";
    [JsonProperty("summary")] public string Summary { get; set; } = "";
    [JsonProperty("reporter")] public string Reporter { get; set; } = "";
    [JsonProperty("assignee")] public string Assignee { get; set; } = "";
    [JsonProperty("status")] public string Status { get; set; } = "";
    [JsonProperty("created")] public string Created { get; set; } = "";
    [JsonProperty("updated")] public string Updated { get; set; } = "";
    [JsonProperty("url")] public string Url { get; set; } = "";

    [JsonProperty("addedAt")]
    [JsonConverter(typeof(AppleDateConverter))]
    public DateTime AddedAt { get; set; } = DateTime.Now;

    [ObservableProperty]
    [property: JsonProperty("isPinned")]
    private bool _isPinned;

    [ObservableProperty]
    [property: JsonProperty("pinnedAt", NullValueHandling = NullValueHandling.Ignore)]
    [property: JsonConverter(typeof(AppleDateConverter))]
    private DateTime? _pinnedAt;

    [ObservableProperty]
    [property: JsonProperty("isArchived")]
    private bool _isArchived;

    [JsonProperty("qianbaoNo")] public string QianbaoNo { get; set; } = "";
    [JsonProperty("qianbaoLink")] public string QianbaoLink { get; set; } = "";

    /// <summary>仅 UI 使用：当前是否正在刷新（不序列化、不入库）</summary>
    [ObservableProperty]
    [property: JsonIgnore]
    private bool _isRefreshing;

    // MARK: - UI 显示辅助（不序列化）

    [JsonIgnore] public System.Windows.Media.Color IssueTypeColorValue => JiraDisplayUtils.IssueTypeColor(IssueType);
    [JsonIgnore] public System.Windows.Media.Color StatusColorValue => JiraDisplayUtils.StatusBadgeColor(Status);
    [JsonIgnore] public string RelativeUpdated => JiraDisplayUtils.RelativeUpdatedTime(Updated);

    /// <summary>最近一次本地修改时间，用于 WebDAV 同步 Last-Write-Wins</summary>
    [JsonProperty("modifiedAt")]
    [JsonConverter(typeof(AppleDateConverter))]
    public DateTime ModifiedAt { get; set; } = DateTime.Now;

    /// <summary>反序列化兼容（对应 Swift decodeIfPresent 默认值与 modifiedAt 回退 addedAt）</summary>
    [OnDeserialized]
    internal void OnDeserialized(StreamingContext context)
    {
        Id ??= ""; Key ??= ""; IssueType ??= ""; Summary ??= "";
        Reporter ??= ""; Assignee ??= ""; Status ??= "";
        Created ??= ""; Updated ??= ""; Url ??= "";
        QianbaoNo ??= ""; QianbaoLink ??= "";
        if (AddedAt == default) AddedAt = DateTime.Now;
        if (ModifiedAt == default) ModifiedAt = AddedAt;
    }

    /// <summary>从 JiraIssue 构建收藏项</summary>
    public static FavoriteJira FromIssue(JiraIssue issue, string url)
    {
        var reporterName = "未知";
        if (issue.Fields["reporter"] is Newtonsoft.Json.Linq.JObject reporterDict)
            reporterName = reporterDict["displayName"]?.ToString()
                           ?? reporterDict["name"]?.ToString() ?? "未知";

        var assigneeName = "未分配";
        if (issue.Fields["assignee"] is Newtonsoft.Json.Linq.JObject assigneeDict)
            assigneeName = assigneeDict["displayName"]?.ToString()
                           ?? assigneeDict["name"]?.ToString() ?? "未分配";

        var created = issue.Fields["created"]?.ToString() ?? "";
        var updated = issue.Fields["updated"]?.ToString() ?? "";
        var qianbaoNo = issue.Fields["customfield_10115"]?.ToString() ?? "";
        var qianbaoLink = issue.Fields["customfield_13252"]?.ToString() ?? "";

        var now = DateTime.Now;
        return new FavoriteJira
        {
            Id = Guid.NewGuid().ToString(),
            Key = issue.Key,
            IssueType = issue.IssueType,
            Summary = issue.Summary,
            Reporter = reporterName,
            Assignee = assigneeName,
            Status = issue.Status,
            Created = FormatJiraDate(created),
            Updated = FormatJiraDate(updated),
            Url = url,
            AddedAt = now,
            IsPinned = false,
            IsArchived = false,
            QianbaoNo = qianbaoNo,
            QianbaoLink = qianbaoLink,
            ModifiedAt = now
        };
    }

    /// <summary>将 modifiedAt 刷新为当前时间（用于本地修改后标记需要同步）</summary>
    public void Touch(DateTime? date = null)
    {
        ModifiedAt = date ?? DateTime.Now;
    }

    /// <summary>格式化 Jira 日期为 "yyyy-MM-dd HH:mm"</summary>
    public static string FormatJiraDate(string dateStr)
    {
        if (string.IsNullOrEmpty(dateStr)) return "";

        // ISO 8601 / Jira 常见格式
        if (DateTime.TryParse(dateStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var date))
            return date.ToLocalTime().ToString("yyyy-MM-dd HH:mm");

        // 回退：截取前16位
        if (dateStr.Length >= 16)
            return dateStr[..16].Replace("T", " ");

        return dateStr;
    }
}
