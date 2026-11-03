using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>版本管理服务（移植自 Swift VersionService.swift）</summary>
public class VersionService
{
    public static VersionService Shared { get; } = new();

    private readonly JiraService _jira = JiraService.Shared;

    public async Task<string> CreateVersionAsync(string date, SystemEnum[] systems, bool isUrgent)
    {
        var logs = "\n\n已成功创建版本号：\n";

        foreach (var system in systems)
        {
            try
            {
                var versionName = GetVersionName(date, system, isUrgent);
                var description = $"【理赔】- {system.SystemName()} - {date} - {(isUrgent ? "紧急版本" : "常规版本")}";

                var version = await _jira.CreateVersionAsync(project: "REQ", name: versionName, description: description, releaseDate: date);
                logs += $"{version.Name}\n";
            }
            catch (Exception ex)
            {
                logs += $"创建 {system.SystemName()} 版本号失败: {ex.Message}\n";
            }
        }
        return logs;
    }

    public async Task<string> CreateVersionByReqDateAsync(string date, bool isUrgent)
    {
        try
        {
            var jql = $"预计修复时间 = \"{date}\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC";
            var issues = await _jira.SearchJQLAsync(jql);
            var createdSystems = new HashSet<SystemEnum>();
            var logs = "";

            foreach (var issue in issues)
            {
                var fieldValue = issue.Fields["customfield_10501"] as JObject;
                var child = fieldValue?["child"] as JObject;
                var id = child?["id"]?.Value<string>();
                if (id == null) continue;
                var system = SystemEnumExtensions.GetBySystemIdReq(id);
                if (system == null || createdSystems.Contains(system.Value)) continue;

                createdSystems.Add(system.Value);

                try
                {
                    _ = await CreateVersionAsync(date, new[] { system.Value }, isUrgent);
                    var versionName = GetVersionName(date, system.Value, isUrgent);

                    // Find version and update REQ
                    var versions = await _jira.GetProjectVersionsAsync("REQ");
                    var foundVersion = versions.FirstOrDefault(v => v.Name == versionName);
                    if (foundVersion != null)
                    {
                        var versionField = new JArray
                        {
                            new JObject
                            {
                                ["self"] = foundVersion.SelfUrl,
                                ["id"] = foundVersion.Id,
                                ["name"] = foundVersion.Name,
                                ["releaseDate"] = date,
                                ["archived"] = false,
                                ["released"] = false
                            }
                        };
                        await _jira.UpdateIssueAsync(issue.Key, new JObject { ["customfield_10126"] = versionField });
                    }
                }
                catch (Exception ex)
                {
                    logs += $"{system.Value.SystemName()} 处理失败: {ex.Message}\n";
                }
            }
            return logs;
        }
        catch (Exception ex)
        {
            return $"查询失败: {ex.Message}";
        }
    }

    public async Task<string> DeleteVersionAsync(string versionName)
    {
        try
        {
            var versions = await _jira.GetProjectVersionsAsync("REQ");
            var version = versions.FirstOrDefault(v => v.Name == versionName);
            if (version != null)
            {
                await _jira.DeleteVersionAsync(version.Id);
                return $"已删除版本号: {versionName}";
            }
            else
            {
                return $"找不到版本号: {versionName}";
            }
        }
        catch (Exception ex)
        {
            return $"删除失败: {ex.Message}";
        }
    }

    public static string GetVersionName(string date, SystemEnum system, bool isUrgent)
    {
        var dateObj = DateUtils.ParseDate(date);
        if (dateObj == null) return "";

        var year = dateObj.Value.Year;
        var month = dateObj.Value.Month;
        var day = dateObj.Value.Day;

        var versionYearId = year - system.InitYear() + 1;
        var lastTwoDigits = year.ToString().Substring(2, 2);
        var dayStr = isUrgent ? $"{day}.0" : day.ToString();

        return $"{system.RawValue()}_V{versionYearId}_{lastTwoDigits}.{month}.{dayStr}";
    }
}
