using JiraWinTool.Models;
using JiraWinTool.Utils;

namespace JiraWinTool.Services;

/// <summary>通知生成服务（移植自 Swift NoticeService.swift）</summary>
public class NoticeService
{
    public static NoticeService Shared { get; } = new();

    private readonly JiraService _jira = JiraService.Shared;

    public async Task<string> GeneralPublishDesAsync(string date)
    {
        try
        {
            var jql = $"申请发布时间 = {date} AND 系统 in (\"B理赔服务类\",\"D05 新核心诉讼系统\") AND status != Closed AND project = 生产环境系统发布 ORDER BY createdDate DESC";
            var issues = await _jira.SearchJQLAsync(jql);

            var developMap = new Dictionary<string, Dictionary<string, PublishDescDto>>();
            var result = $"{date} 上线版本：\n";

            foreach (var publish in issues)
            {
                var banben = publish.Fields["customfield_10719"]?.Value<string>();
                if (string.IsNullOrEmpty(banben)) continue;

                var reqJql = $"project = REQ and 预计修复时间 = \"{date}\" AND 开发版本号 = \"{banben}\" ORDER BY priority ASC";
                var reqIssues = await _jira.SearchJQLAsync(reqJql);

                foreach (var req in reqIssues)
                {
                    var displayName = "";
                    // 系统开发人员 customfield_11923
                    if (req.Fields["customfield_11923"] is JObject devObj)
                        displayName = devObj["displayName"]?.Value<string>() ?? "";
                    // 如果为空，取系统设计人员 customfield_11916
                    if (string.IsNullOrEmpty(displayName) && req.Fields["customfield_11916"] is JObject designObj)
                        displayName = designObj["displayName"]?.Value<string>() ?? "";
                    if (string.IsNullOrEmpty(displayName))
                        displayName = "未知开发人员";

                    var reqDto = new ReqDescDto
                    {
                        ReqKey = req.Key,
                        ReqDesc = req.Summary,
                        DevelopName = displayName
                    };

                    if (!developMap.ContainsKey(displayName))
                        developMap[displayName] = new Dictionary<string, PublishDescDto>();

                    var publishMap = developMap[displayName];
                    if (publishMap.TryGetValue(publish.Key, out var existing))
                    {
                        existing.ReqDescDto.Add(reqDto);
                    }
                    else
                    {
                        publishMap[publish.Key] = new PublishDescDto
                        {
                            PublishKey = publish.Key,
                            Summary = publish.Summary,
                            BanBenKey = banben,
                            ReqDescDto = new List<ReqDescDto> { reqDto }
                        };
                    }
                }
            }

            foreach (var (devName, publishMap) in developMap)
            {
                result += $"@{devName}\n";
                foreach (var (pubKey, pubDto) in publishMap)
                {
                    var reqKeys = string.Join("、", pubDto.ReqDescDto.Select(r => r.ReqKey));
                    result += $"核实下【{pubKey}】(对应 【{reqKeys}】)\n";
                }
                result += "\n";
            }

            result += "1. \"发布内容\"是否包含对应 REQ？\n";
            result += "2. \"发布操作说明\"是否说明正确（是否有代码、是否有脚本、是否有配置调整）？\n";
            result += "3. \"发布选择项\"：有脚本需额外勾选\"发布数据库脚本-DBA 执行\"，有 DDL 脚本需额外勾选\"有DDL脚本\"\n";
            result += "4. 生产分支是否已拉？（理赔核心可忽略）\n";
            result += "5. 对应上线微服务名是否明确标识？（理赔核心可忽略）\n";
            result += "\n全部确认后回复下（核实自己相关的内容即可），最迟周一上午 10点前确认回复。";

            return result;
        }
        catch (Exception ex)
        {
            return $"查询失败: {ex.Message}";
        }
    }

    public async Task<string> GeneralVersionMeetingDescAsync(string date)
    {
        var dateObj = DateUtils.ParseDate(date);
        if (dateObj == null) return "日期格式错误";

        var meetingDate = dateObj.Value.AddDays(-21);
        var meetingDateStr = DateUtils.FormatDate(meetingDate);

        var result = "";
        result += $"会议：理赔版本会议【{date}版本】\n";
        result += $"时间：{meetingDateStr} 14:00 ~ {meetingDateStr} 15:00\n";
        result += "会议地点： 金丰城23楼1号会议室\n";
        result += "@李松林 @天晖 @罗家声\n\n";
        result += "2 点 1 号会议室\n";

        try
        {
            var jql = $"预计修复时间 = \"{date}\" AND 系统名称（开发） in (理赔条线, 电销条线) AND status != Closed ORDER BY cf[11923] ASC, cf[10126] ASC, cf[10106] DESC";
            var issues = await _jira.SearchJQLAsync(jql);
            var developList = new HashSet<string>();

            foreach (var issue in issues)
            {
                if (issue.Fields["customfield_11923"] is JObject devObj)
                {
                    var name = devObj["displayName"]?.Value<string>();
                    if (!string.IsNullOrEmpty(name))
                        developList.Add(name);
                }
            }

            foreach (var name in developList)
                result += $"@{name} ";
            result += "\n";
            return result;
        }
        catch (Exception ex)
        {
            return result + $"\n查询开发人员失败: {ex.Message}";
        }
    }
}
