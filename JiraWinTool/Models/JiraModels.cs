using Newtonsoft.Json.Linq;

namespace JiraWinTool.Models;

/// <summary>Jira 工单（移植自 Swift PublishModels.swift 的 JiraIssue）</summary>
public class JiraIssue
{
    public string Key { get; set; } = "";
    public string Summary { get; set; } = "";
    public JObject Fields { get; set; } = new();
    public List<string> Labels { get; set; } = new();
    public string Status { get; set; } = "";
    public string IssueType { get; set; } = "";

    public JToken? FieldValue(string name) => Fields[name];
    public JToken? CustomField(string id) => Fields[id];
}

/// <summary>Jira 版本</summary>
public class JiraVersion
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Description { get; set; }
    public string? ReleaseDate { get; set; }
    public bool Archived { get; set; }
    public bool Released { get; set; }
    public string SelfUrl { get; set; } = "";
}

/// <summary>发布条目</summary>
public class PublishItemDto
{
    public string ItemName { get; set; } = "";
    public string Exists { get; set; } = "";
    public string Remark { get; set; } = "";
}

/// <summary>发布描述</summary>
public class PublishDescDto
{
    public string PublishKey { get; set; } = "";
    public string Summary { get; set; } = "";
    public string BanBenKey { get; set; } = "";
    public List<ReqDescDto> ReqDescDto { get; set; } = new();
}

public class ReqDescDto
{
    public string ReqKey { get; set; } = "";
    public string ReqDesc { get; set; } = "";
    public string DevelopName { get; set; } = "";
}

public class MyResultIssue
{
    public string IssueKey { get; set; } = "";
    public List<string> RelateIssueName { get; set; } = new();
}

/// <summary>版本清单 Excel 行数据</summary>
public class BanBenJiraDto
{
    public string ReqType { get; set; } = "";
    public string ReqId { get; set; } = "";
    public string ReqName { get; set; } = "";
    public string UserDevelop { get; set; } = "";
    public string UserTest { get; set; } = "";
    public string ModifySystem { get; set; } = "";
    public string Progress { get; set; } = "";
    public string ScheduleLaunchDate { get; set; } = "";
    public string Remark { get; set; } = "";
}

/// <summary>通知数据</summary>
public class JiraTongZhiDto
{
    public string ReqId { get; set; } = "";
    public HashSet<string> UserNotice { get; set; } = new();
    public string NoticeRemark { get; set; } = "";
}
