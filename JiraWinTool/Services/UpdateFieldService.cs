using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>字段更新服务（移植自 Swift UpdateFieldService.swift）</summary>
public class UpdateFieldService
{
    public static UpdateFieldService Shared { get; } = new();

    private readonly JiraService _jira = JiraService.Shared;

    public async Task<string> UpdateSomeFieldAsync(string date, bool isRegular)
    {
        var logs = "";
        try
        {
            var jql = $"预计修复时间 = \"{date}\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC";
            var issues = await _jira.SearchJQLAsync(jql);

            foreach (var issue in issues)
            {
                var fieldsToUpdate = new JObject();

                if (isRegular)
                {
                    fieldsToUpdate["customfield_13221"] = new JObject { ["value"] = "是" };
                }

                // First fix date
                var firstFixDate = issue.Fields["customfield_13217"];
                if (firstFixDate == null || firstFixDate.Type == JTokenType.Null)
                {
                    fieldsToUpdate["customfield_13217"] = date;
                }
                else if (firstFixDate.Value<string>() != date)
                {
                    fieldsToUpdate["customfield_13219"] = new JObject { ["value"] = "是" };
                }

                if (fieldsToUpdate.Count > 0)
                {
                    await _jira.UpdateIssueAsync(issue.Key, fieldsToUpdate);
                }

                logs += $"已更新: {issue.Key} {issue.Summary}\n";
            }

            return logs.Length > 0 ? logs : "没有需要更新的 issue";
        }
        catch (Exception ex)
        {
            return $"更新失败: {ex.Message}";
        }
    }
}
