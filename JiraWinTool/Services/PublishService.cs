using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>发布创建服务（移植自 Swift PublishService.swift）</summary>
public class PublishService
{
    public static PublishService Shared { get; } = new();

    private readonly JiraService _jira = JiraService.Shared;
    private static readonly bool CREAT_PUBLISH_FLAG = true;
    private const bool MULTI_BANBEN_FLAG = true;

    // MARK: - Create Publish by Date

    public async Task<string> CreatePublishByDateAsync(string date, string? noPublishId)
    {
        var logBuilder = $"{date} 版本publish：\n";

        try
        {
            var jql = $"预计修复时间 = \"{date}\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC";
            logBuilder += $"执行 JQL: {jql}\n";
            var issues = await _jira.SearchJQLAsync(jql);
            logBuilder += $"✅ JQL 查到 {issues.Count} 个 REQ\n";
            var allVersion = new HashSet<string>();

            foreach (var issue in issues)
            {
                if (issue.Fields["customfield_10126"] is not JArray versions)
                {
                    logBuilder += $"⚠️ {issue.Key} customfield_10126 为空或类型不匹配\n";
                    continue;
                }
                for (int i = 0; i < versions.Count; i++)
                {
                    if (i > 0 && !MULTI_BANBEN_FLAG) continue;
                    var versionName = versions[i]?["name"]?.Value<string>();
                    if (versionName == null) continue;
                    if (noPublishId != null && versionName == noPublishId) continue;
                    allVersion.Add(versionName);
                }
            }

            logBuilder += $"提取到 {allVersion.Count} 个版本号: {string.Join(", ", allVersion.OrderBy(v => v))}\n";

            foreach (var versionId in allVersion.OrderBy(v => v))
            {
                var parts = versionId.Split('_');
                if (parts.Length <= 1)
                {
                    logBuilder += $"⚠️ 版本号[{versionId}]没有下划线分隔，无法拆分系统前缀\n";
                    continue;
                }
                var banben = parts[0];

                var systemEnum = SystemEnumExtensions.GetBySystemPublishName(banben);
                if (systemEnum == null)
                {
                    logBuilder += $"⚠️ 获取不到系统对应的publish类: {banben}\n";
                    continue;
                }

                var (result, detailLog) = await CreatePublishAsync(null, versionId, systemEnum.Value);
                logBuilder += detailLog;
                if (result != null)
                {
                    logBuilder += $"✅ {result.IssueKey} {systemEnum.Value.SystemName()}上线发布申请【{string.Join("、", result.RelateIssueName)}】\n";
                }
            }

            logBuilder += "\nps：根据目前 REQ 现状（版本号+上线日期）建的 PUBLISH，如后续对应 REQ 有调整，REQ相关人记得同步修改 publish";
            return logBuilder;
        }
        catch (Exception ex)
        {
            return logBuilder + $"❌ 查询失败: {ex.Message}\n";
        }
    }

    // MARK: - Create Publish by REQ

    public async Task<string> CreatePublishByReqAsync(string reqId, string? banbenhao)
    {
        try
        {
            var issue = await _jira.GetIssueAsync(reqId);
            var logs = $"✅ 获取到 REQ: {issue.Key}\n";

            if (issue.Fields["customfield_10126"] is not JArray versions)
            {
                return $"❌ 该 REQ 没有开发版本号\n";
            }

            for (int i = 0; i < versions.Count; i++)
            {
                if (i > 0 && !MULTI_BANBEN_FLAG) continue;
                var versionId = versions[i]?["name"]?.Value<string>();
                if (versionId == null) continue;

                if (versionId.Contains("ZZUSER"))
                {
                    logs += $"⏭️ 跳过 ZZUSER 版本号: {versionId}\n";
                    continue;
                }

                if (!string.IsNullOrEmpty(banbenhao) && versionId != banbenhao)
                {
                    logs += $"⏭️ 跳过不匹配版本号: {versionId} (指定: {banbenhao})\n";
                    continue;
                }

                var parts = versionId.Split('_');
                if (parts.Length <= 1)
                {
                    logs += $"⚠️ 版本号[{versionId}]没有下划线分隔\n";
                    continue;
                }
                var banben = parts[0];

                var systemEnum = SystemEnumExtensions.GetBySystemPublishName(banben);
                if (systemEnum == null)
                {
                    logs += $"⚠️ 获取不到系统对应的publish类: {banben}\n";
                    continue;
                }

                var (result, detailLog) = await CreatePublishAsync(issue, versionId, systemEnum.Value);
                logs += detailLog;
                if (result != null)
                {
                    logs += $"✅ 成功创建: {result.IssueKey}\n";
                }
            }
            return string.IsNullOrEmpty(logs) ? "没有需要创建的 publish" : logs;
        }
        catch (Exception ex)
        {
            return $"❌ 查询 REQ 失败: {ex.Message}\n";
        }
    }

    // MARK: - Core Create Publish

    private async Task<(MyResultIssue? Result, string Log)> CreatePublishAsync(Models.JiraIssue? issue, string versionId, SystemEnum systemEnum)
    {
        var log = "";

        if (!CREAT_PUBLISH_FLAG)
        {
            return (null, "⚠️ CREAT_PUBLISH_FLAG = false，跳过创建\n");
        }

        // Step 1: JQL 搜索关联 REQ
        var jql = $"project = REQ AND 开发版本号 = \"{versionId}\" ORDER BY priority ASC";
        log += $"📋 执行 JQL: {jql}\n";

        List<Models.JiraIssue> issues;
        try
        {
            issues = await _jira.SearchJQLAsync(jql);
        }
        catch (Exception ex)
        {
            return (null, log + $"❌ JQL 查询失败: {ex.Message}\n");
        }
        log += $"✅ JQL 查到 {issues.Count} 个关联 REQ\n";

        if (issues.Count == 0)
        {
            return (null, log + $"❌ 未查到版本号 {versionId} 对应的 REQ，无法创建 PUBLISH\n");
        }

        // Step 2: 汇总 REQ 数据
        var relateIssueName = new List<string>();
        var reqDesc = "";
        var develop = new HashSet<string>();
        var peizhishuoming = "";
        string? fixtimeValue = null;

        var publishItemList = new List<PublishItemDto>
        {
            new() { ItemName = "代码", Exists = "无", Remark = "-" },
            new() { ItemName = "数据库脚本", Exists = "无", Remark = "-" },
            new() { ItemName = "env与share文件", Exists = "无", Remark = "-" },
            new() { ItemName = "Groovy更新", Exists = "无", Remark = "-" },
            new() { ItemName = "MQ队列", Exists = "无", Remark = "-" },
            new() { ItemName = "Dubbo配置", Exists = "无", Remark = "-" },
            new() { ItemName = "nacos配置", Exists = "无", Remark = "-" },
            new() { ItemName = "DDL脚本", Exists = "无", Remark = "-" }
        };

        foreach (var reqIssue in issues)
        {
            relateIssueName.Add(reqIssue.Key);
            var displayName = ExtractDisplayName(reqIssue, "customfield_11923");
            develop.Add(displayName);
            reqDesc += $"{reqIssue.Key} {reqIssue.Summary} 【{displayName}】\n";

            if (issue == null)
            {
                if (reqIssue.Fields["customfield_10724"] != null)
                {
                    peizhishuoming = reqIssue.Fields["customfield_10724"]?.Value<string>() ?? "";
                }
                if (fixtimeValue == null)
                {
                    fixtimeValue = reqIssue.Fields["customfield_10919"]?.Value<string>();
                }
            }

            DealPublishItem(reqIssue, publishItemList);
        }

        peizhishuoming = PrintPublishItem(publishItemList, versionId, systemEnum);

        var summary = $"{systemEnum.SystemName()}{versionId}上线发布申请";

        // Step 3: 获取修复日期
        string fixtime;
        if (issue != null)
        {
            fixtime = issue.Fields["customfield_10919"]?.Value<string>() ?? "";
            if (string.IsNullOrEmpty(fixtime))
                return (null, log + "❌ 源 REQ 的 customfield_10919(预计修复时间) 为空，无法创建 PUBLISH\n");
        }
        else if (!string.IsNullOrEmpty(fixtimeValue))
        {
            fixtime = fixtimeValue;
        }
        else
        {
            return (null, log + "❌ 所有关联 REQ 均无 customfield_10919(预计修复时间)，无法创建 PUBLISH\n");
        }
        log += $"📅 预计修复时间: {fixtime}\n";

        // Step 4: 组装 fields
        var fixtimeDatetime = $"{fixtime}T21:00:00.000+0800";
        var fields = new JObject
        {
            ["project"] = new JObject { ["key"] = "PUBLISH" },
            ["issuetype"] = new JObject { ["id"] = "10404" },
            ["summary"] = summary,
            ["customfield_10719"] = versionId,
            ["customfield_10723"] = systemEnum.GetSvnLocation(versionId),
            ["customfield_10721"] = fixtimeDatetime,
            ["customfield_10720"] = reqDesc
        };

        // Schedule type
        var fixDate = DateUtils.FormateStringToDate(fixtime) ?? DateTime.Now;
        var weekday = ((int)fixDate.DayOfWeek + 6) % 7 + 1; // Monday=1

        if (versionId.EndsWith(".0"))
        {
            fields["customfield_10760"] = _jira.GetFieldString("排期类型", "紧急", "11326");
            if (issue != null && issue.Fields["customfield_13220"] is JObject reqTypeObj &&
                reqTypeObj["value"]?.Value<string>() == "专题")
            {
                fields["customfield_10760"] = _jira.GetFieldString("排期类型", "专题", "14612");
            }
        }
        else if (weekday == 5) // Thursday
        {
            fields["customfield_10760"] = _jira.GetFieldString("排期类型", "紧急", "11326");
        }
        else
        {
            fields["customfield_10760"] = _jira.GetFieldString("排期类型", "常规", "11325");
        }

        fields["customfield_10727"] = _jira.GetFieldString("自测结论", "自测通过", "11255");
        fields["customfield_12600"] = _jira.GetFieldString("包含新产品", "不包含", "14205");
        fields["customfield_12300"] = _jira.GetFieldString("风险等级", "低", "13902");
        fields["customfield_10724"] = peizhishuoming;

        // System field
        JObject systemParent;
        if (systemEnum.SystemCode() == "D05")
        {
            systemParent = new JObject
            {
                ["self"] = "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/10886",
                ["value"] = "Y辅助支持类（*新核心）",
                ["id"] = "10886",
                ["child"] = _jira.GetFieldString(systemEnum.SystemName(), $"{systemEnum.SystemCode()} {systemEnum.SystemName()}", systemEnum.SystemId())
            };
        }
        else
        {
            systemParent = new JObject
            {
                ["self"] = "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/10852",
                ["value"] = "B理赔服务类",
                ["id"] = "10852",
                ["child"] = _jira.GetFieldString(systemEnum.SystemName(), $"{systemEnum.SystemCode()} {systemEnum.SystemName()}", systemEnum.SystemId())
            };
        }
        fields["customfield_10501"] = systemParent;

        // Publish choose items
        var publishChoose = new JArray();
        foreach (var name in systemEnum.GetPublishChooseNames())
        {
            var fv = PublishChooseCode.MakeFieldValue(name);
            if (fv != null)
                publishChoose.Add(fv);
        }
        fields["customfield_10722"] = publishChoose;

        // Version type
        fields["customfield_10759"] = new JArray { _jira.GetFieldString("版本类型", "需求", "11322") };

        // Test line
        fields["customfield_13101"] = new JArray { _jira.GetFieldString("测试条线归属", "服务条线", "14809") };

        // Step 5: 打印完整 fields 用于诊断
        log += $"📦 创建 PUBLISH 字段:\n";
        log += $"  summary: {summary}\n";
        log += $"  customfield_10719(版本号): {versionId}\n";
        log += $"  customfield_10721(发布时间): {fixtimeDatetime}\n";
        log += $"  customfield_10501(系统分类): id={systemEnum.SystemCode()}, systemId={systemEnum.SystemId()}\n";
        log += $"  customfield_10722(发布选择项): {string.Join(", ", publishChoose.Select(c => c["value"]?.Value<string>() ?? "?"))}\n";

        // Step 6: 创建 Issue
        string publishKey;
        try
        {
            publishKey = await _jira.CreateIssueAsync("PUBLISH", "10404", fields);
            log += $"✅ 创建 PUBLISH 成功: {publishKey}\n";
        }
        catch (Exception ex)
        {
            return (null, log + $"❌ 创建 PUBLISH 失败: {ex.Message}\n");
        }

        // Step 7: 后续操作（评论、标签、链接、转交）
        var specialLabels = new HashSet<string>();
        foreach (var reqIssue in issues)
        {
            try
            {
                await _jira.AddCommentAsync(reqIssue.Key, $"{systemEnum.SystemName()} : {publishKey}");

                var labels = new HashSet<string>(reqIssue.Labels);
                labels.Add($"[{systemEnum.RawValue()}]{publishKey}");

                var devName = ExtractDisplayName(reqIssue, "customfield_11923");
                if (!string.IsNullOrEmpty(devName))
                    labels.Add(devName);

                await _jira.UpdateIssueAsync(reqIssue.Key, new JObject { ["labels"] = new JArray(labels.ToArray()) });

                foreach (var label in reqIssue.Labels)
                {
                    if (label.Contains("同步上线"))
                        specialLabels.Add(label);
                }

                await _jira.LinkIssuesAsync(publishKey, reqIssue.Key);
            }
            catch (Exception ex)
            {
                log += $"⚠️ REQ {reqIssue.Key} 后续操作失败: {ex.Message}\n";
            }
        }

        // Update publish labels
        try
        {
            var publishIssue = await _jira.GetIssueAsync(publishKey);
            var publishLabels = new HashSet<string>(publishIssue.Labels);
            publishLabels.Add($"[{systemEnum.RawValue()}]{publishKey}");
            foreach (var label in specialLabels)
                publishLabels.Add(label);
            await _jira.UpdateIssueAsync(publishKey, new JObject { ["labels"] = new JArray(publishLabels.ToArray()) });
        }
        catch (Exception ex)
        {
            log += $"⚠️ PUBLISH 标签更新失败: {ex.Message}\n";
        }

        // Transition to submit test (451)
        try
        {
            await _jira.TransitionIssueAsync(publishKey, "451");
            log += "✅ 已提交测试\n";
        }
        catch (Exception ex)
        {
            log += $"⚠️ 提交测试失败: {ex.Message}\n";
        }

        // Update assignee
        try
        {
            await _jira.UpdateIssueAsync(publishKey, new JObject { ["assignee"] = new JObject { ["name"] = "lisonglin" } });
            log += "✅ 已设置经办人\n";
        }
        catch (Exception ex)
        {
            log += $"⚠️ 设置经办人失败: {ex.Message}\n";
        }

        return (new MyResultIssue { IssueKey = publishKey, RelateIssueName = relateIssueName }, log);
    }

    // MARK: - Helpers

    private static void DealPublishItem(Models.JiraIssue issue, List<PublishItemDto> publishItemList)
    {
        foreach (var itemEnum in Enum.GetValues<PublishItemEnum>())
        {
            var idx = (int)itemEnum;
            if (idx >= publishItemList.Count) continue;
            if (publishItemList[idx].Exists == "有") continue;

            if (issue.Fields[itemEnum.SystemName()] is JObject fieldObj &&
                fieldObj["value"]?.Value<string>() == "有变更")
            {
                publishItemList[idx].Exists = "有";
            }
        }
    }

    private static string PrintPublishItem(List<PublishItemDto> list, string versionId, SystemEnum systemEnum)
    {
        var result = "||条目||有/无||备注||\n";
        for (int i = 0; i < Math.Min(7, list.Count); i++)
        {
            var dto = list[i];
            result += $"|{dto.ItemName}|{dto.Exists}|";

            var third = "-";
            if (dto.ItemName == "数据库脚本" && dto.Exists == "有" && versionId.StartsWith("CLM_V"))
            {
                third = systemEnum.GetSvnLocation(versionId);
            }
            result += $"{third}|\n";
        }
        return result;
    }

    private static string ExtractDisplayName(Models.JiraIssue issue, string fieldId)
    {
        if (issue.Fields[fieldId] is JObject fieldObj)
            return fieldObj["displayName"]?.Value<string>() ?? "";
        return "";
    }
}
