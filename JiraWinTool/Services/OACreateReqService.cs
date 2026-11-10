using System.Text.RegularExpressions;
using JiraWinTool.Models;
using JiraWinTool.Utils;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>
/// OA 创建 REQ 服务（移植自 Swift OACreateReqService.swift）。
/// 使用模板 REQ 的字段结构，结合 OA 解析结果，在 Jira 中创建新的系统需求 REQ。
/// </summary>
public class OACreateReqService
{
    public static OACreateReqService Shared { get; } = new();
    private OACreateReqService() { }

    private readonly JiraService _jira = JiraService.Shared;

    /// <summary>
    /// 创建 REQ 主流程
    /// </summary>
    /// <param name="oaLink">原始 OA 链接（用作签报链接）</param>
    /// <param name="templateReqKey">参考模板 REQ Key</param>
    /// <param name="parsed">OA 解析结果（可能被用户手工修正过）</param>
    /// <param name="pickedAttachments">勾选要上传的附件</param>
    /// <param name="draftDeptKeyword">拟稿部门关键字（用户手工修正后）</param>
    /// <param name="fixedSystemParent">固定字段：系统名称（父级）</param>
    /// <param name="fixedSystemChild">固定字段：系统名称（子级）</param>
    /// <param name="fixedDevVersion">固定字段：开发版本号</param>
    /// <param name="fixedDutyDept">固定字段：责任科室</param>
    /// <param name="fixedGroupName">固定字段：科室小组（空时复制模板值）</param>
    /// <param name="fixedIsCopyReq">固定字段：是否复制需求</param>
    /// <param name="fixedIsComplexReq">固定字段：是否复杂需求</param>
    /// <param name="fixedReqCategory">固定字段：需求分类</param>
    /// <param name="fixedIsPricing">固定字段：是否计价</param>
    /// <param name="fixedLabels">固定字段：标签（多个用英文逗号分隔）</param>
    /// <param name="logger">日志回调</param>
    /// <returns>新建 REQ Key</returns>
    public async Task<string> CreateFromOAAsync(
        string oaLink,
        string templateReqKey,
        OAParseResult parsed,
        List<OAAttachment> pickedAttachments,
        string draftDeptKeyword,
        string fixedSystemParent,
        string fixedSystemChild,
        string fixedDevVersion,
        string fixedDutyDept,
        string fixedGroupName,
        string fixedIsCopyReq,
        string fixedIsComplexReq,
        string fixedReqCategory,
        string fixedIsPricing,
        string fixedLabels,
        string fixedAssignee,
        Action<string> logger)
    {
        var templateKey = templateReqKey.Trim();
        if (string.IsNullOrEmpty(templateKey))
            throw new InvalidOperationException("未指定模板 REQ Key");

        logger($"读取模板 REQ {templateKey} ...");
        var raw = await _jira.GetIssueRawAsync(templateKey, expand: "names");
        var fields = raw["fields"] as JObject
            ?? throw new InvalidOperationException("模板返回无 fields");
        var names = raw["names"] as JObject ?? new JObject();

        // 反向索引：中文字段名 → customfield_id
        var nameToId = new Dictionary<string, string>();
        foreach (var prop in names.Properties())
            nameToId[prop.Value.Value<string>() ?? ""] = prop.Name;

        // 1) 系统名称（开发）级联字段：获取模板结构作为基础
        var sysField = fields["customfield_10125"] as JObject;
        if (sysField == null)
        {
            logger("[警告] 模板中没有级联字段 customfield_10125（系统名称（开发）），将尝试按元数据构建");
        }

        // 2) issuetype
        var issueTypeDict = fields["issuetype"] as JObject;
        var issueTypeName = issueTypeDict?["name"]?.Value<string>() ?? "";
        var issueTypeId = issueTypeDict?["id"]?.Value<string>();
        if (!issueTypeName.Contains("系统需求") && !issueTypeName.Contains("需求"))
            logger($"[警告] 模板 issuetype={issueTypeName}，并非『系统需求』；将继续使用模板 id={issueTypeId ?? ""}");

        // 查询 createmeta 获取字段选项元数据（用于解析选项字段的正确 id）
        var fieldOptions = new Dictionary<string, JArray>();
        var fieldSchemaTypes = new Dictionary<string, string>();
        try
        {
            var metaFields = await _jira.GetCreateMetaFieldsAsync("REQ", string.IsNullOrEmpty(issueTypeName) ? "系统需求" : issueTypeName);
            if (metaFields != null)
            {
                foreach (var prop in metaFields.Properties())
                {
                    var allowedValues = prop.Value["allowedValues"] as JArray;
                    if (allowedValues != null && allowedValues.Count > 0)
                        fieldOptions[prop.Name] = allowedValues;
                    // 记录字段 schema 类型（用于区分选项/级联/字符串字段）
                    var schemaType = prop.Value["schema"]?["type"]?.Value<string>();
                    if (!string.IsNullOrEmpty(schemaType))
                        fieldSchemaTypes[prop.Name] = schemaType;
                }
                logger($"[元数据] 已加载 {fieldOptions.Count} 个字段的选项数据，{fieldSchemaTypes.Count} 个字段的类型信息");
            }
            else
            {
                logger("[元数据] createmeta 返回空，将仅按 value 文本匹配");
            }
        }
        catch (Exception ex)
        {
            logger($"[元数据] 查询 createmeta 失败: {ex.Message}，将仅按 value 文本匹配");
        }

        // 3) 构造创建字段
        var newFields = new JObject
        {
            ["project"] = new JObject { ["key"] = "REQ" },
            ["issuetype"] = issueTypeId != null
                ? new JObject { ["id"] = issueTypeId }
                : new JObject { ["name"] = "系统需求" },
            ["summary"] = string.IsNullOrEmpty(parsed.Title) ? "(来自 OA，无标题)" : parsed.Title
        };

        // 系统名称（开发）: 用用户指定的父/子级值覆盖
        var sysResult = new JObject();
        if (fieldOptions.TryGetValue("customfield_10125", out var sysMetaOptions) && !string.IsNullOrEmpty(fixedSystemParent))
        {
            // 通过元数据匹配父级 id
            var parentMatched = FindOptionByValue(sysMetaOptions, fixedSystemParent);
            if (parentMatched != null)
            {
                if (parentMatched["id"] != null) sysResult["id"] = parentMatched["id"];
                sysResult["value"] = fixedSystemParent;
                // 匹配子级 id
                if (!string.IsNullOrEmpty(fixedSystemChild) && parentMatched["children"] is JArray children)
                {
                    var childMatched = FindOptionByValue(children, fixedSystemChild);
                    if (childMatched != null)
                    {
                        var c = new JObject();
                        if (childMatched["id"] != null) c["id"] = childMatched["id"];
                        c["value"] = fixedSystemChild;
                        sysResult["child"] = c;
                    }
                    else
                    {
                        sysResult["child"] = new JObject { ["value"] = fixedSystemChild };
                    }
                }
                logger($"[设置] customfield_10125 = {fixedSystemParent} > {fixedSystemChild} (id 匹配)");
            }
            else
            {
                // 父级未匹配到元数据，仅设置文本值
                sysResult["value"] = fixedSystemParent;
                if (!string.IsNullOrEmpty(fixedSystemChild))
                    sysResult["child"] = new JObject { ["value"] = fixedSystemChild };
                logger($"[设置] customfield_10125 = {fixedSystemParent} > {fixedSystemChild} (仅文本值)");
            }
        }
        else
        {
            // 无元数据，回退到克隆模板 + 覆盖文本值
            if (sysField != null)
                sysResult = (JObject)CloneCascading(sysField);
            sysResult["value"] = fixedSystemParent;
            if (!string.IsNullOrEmpty(fixedSystemChild))
            {
                var c = sysResult["child"] as JObject ?? new JObject();
                c["value"] = fixedSystemChild;
                sysResult["child"] = c;
            }
            logger($"[设置] customfield_10125 = {fixedSystemParent} > {fixedSystemChild} (回退模板结构)");
        }
        newFields["customfield_10125"] = sysResult;

        // 价值描述 (customfield_12105) = 申请内容
        if (!string.IsNullOrEmpty(parsed.Content))
            newFields["customfield_12105"] = parsed.Content;

        // 签报号 / 签报链接
        newFields["customfield_10115"] = parsed.ApplyNo;
        newFields["customfield_13252"] = oaLink;

        // 经办人 = 用户指定的值（优先使用可编辑字段，默认登录账号）
        var assignee = !string.IsNullOrEmpty(fixedAssignee) ? fixedAssignee : AppConfig.Shared.JiraUser;
        if (!string.IsNullOrEmpty(assignee))
            newFields["assignee"] = new JObject { ["name"] = assignee };

        // —— 下列字段按"中文字段名"在模板 names 中反查 customfield_id，再按模板结构克隆 ——

        // a) 需求提交部门：拟稿部门关键字
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "需求提交部门", "提交部门", "需求部门", "申请部门" },
            draftDeptKeyword, fieldOptions, fieldSchemaTypes, logger);

        // a-2) 开发版本号
        if (!string.IsNullOrEmpty(fixedDevVersion))
        {
            ApplyFieldByName(newFields, fields, nameToId,
                new[] { "开发版本号", "版本号", "开发版本" },
                fixedDevVersion, fieldOptions, fieldSchemaTypes, logger);
        }

        // b) 责任科室
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "责任科室", "开发科室", "主责科室" },
            fixedDutyDept, fieldOptions, fieldSchemaTypes, logger);

        // b-2) 分公司：使用解析结果中的值
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "分公司", "分支机构", "所属分公司" },
            parsed.BranchCompany, fieldOptions, fieldSchemaTypes, logger);

        // c) 科室小组: 用户录入为空时直接复制模板 REQ 的值，否则使用用户输入
        var groupNameFieldId = ResolveCustomFieldId(nameToId, new[] { "科室小组", "开发小组", "责任小组" }, logger);
        if (groupNameFieldId != null)
        {
            if (string.IsNullOrEmpty(fixedGroupName))
            {
                // 用户未录入，复制模板值
                if (fields[groupNameFieldId] != null)
                {
                    newFields[groupNameFieldId] = CloneCascading(fields[groupNameFieldId]);
                    logger($"[设置] 科室小组({groupNameFieldId}) = 复制模板值");
                }
            }
            else
            {
                // 用户已录入，替换 value
                ApplyFieldByName(newFields, fields, nameToId,
                    new[] { "科室小组", "开发小组", "责任小组" },
                    fixedGroupName, fieldOptions, fieldSchemaTypes, logger);
            }
        }
        else
        {
            logger("[跳过] 未在模板中找到字段：科室小组/开发小组/责任小组");
        }

        // d) 是否复制需求
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "是否复制需求", "是否复制" },
            fixedIsCopyReq, fieldOptions, fieldSchemaTypes, logger);

        // e) 需求提出人 = 拟稿人
        var drafter = parsed.Drafter.Trim();
        if (!string.IsNullOrEmpty(drafter))
        {
            newFields["customfield_10123"] = drafter;
            logger($"[设置] 需求提出人(customfield_10123) = {drafter}");

            ApplyUserFieldByName(newFields, fields, nameToId,
                new[] { "需求提出人", "提出人", "需求提交人" },
                drafter, logger);

            // f) 用户测试人员 = 拟稿人
            ApplyUserFieldByName(newFields, fields, nameToId,
                new[] { "用户测试人员", "用户测试", "测试用户" },
                drafter, logger);
        }
        else
        {
            logger("[警告] OA 拟稿人为空，跳过『需求提出人』与『用户测试人员』设置");
        }

        // g) 是否复杂需求
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "是否复杂需求", "复杂需求" },
            fixedIsComplexReq, fieldOptions, fieldSchemaTypes, logger);

        // h) 需求接收日期: 当前日期
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "需求接收日期", "接收日期", "需求提交日期" },
            FormatTodayDate(), fieldOptions, fieldSchemaTypes, logger);

        // i) 需求分类
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "需求分类", "需求类型" },
            fixedReqCategory, fieldOptions, fieldSchemaTypes, logger);

        // i-2) 是否计价
        ApplyFieldByName(newFields, fields, nameToId,
            new[] { "是否计价", "计价" },
            fixedIsPricing, fieldOptions, fieldSchemaTypes, logger);

        // j) 标签
        var labels = fixedLabels
            .Split(new[] { ',', '，', ';', '；', '\n', '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => s.Trim())
            .Where(s => !string.IsNullOrEmpty(s))
            .ToList();
        if (labels.Count > 0)
        {
            newFields["labels"] = new JArray(labels);
            logger($"[设置] 标签 = {string.Join(", ", labels)}");
        }

        // 创建（带字段过滤重试机制）
        logger("创建 REQ ...");
        string newKey;
        List<string>? removedFields = null;
        try
        {
            newKey = await _jira.CreateIssueAsync("REQ", issueTypeId ?? "", newFields);
        }
        catch (Exception ex)
        {
            var errorMsg = ex.Message;
            logger("[提示] 首次创建失败，尝试过滤不在创建屏幕上的字段...");
            var badFields = ParseBadFieldsFromError(errorMsg);
            if (badFields != null && badFields.Count > 0)
            {
                removedFields = badFields;
                logger($"[过滤] 移除不在创建屏幕上的字段: {string.Join(", ", badFields)}");
                foreach (var field in badFields)
                    newFields.Remove(field);
                try
                {
                    newKey = await _jira.CreateIssueAsync("REQ", issueTypeId ?? "", newFields);
                }
                catch (Exception ex2)
                {
                    // 第二轮容错：处理选项字段值无效的情况
                    newKey = await RetryWithFieldRemoval(newFields, issueTypeId, ex2, fieldOptions, logger);
                }
            }
            else
            {
                // 首轮错误不是 "cannot be set" 格式，尝试选项字段容错
                newKey = await RetryWithFieldRemoval(newFields, issueTypeId, ex, fieldOptions, logger);
            }
        }
        logger($"[成功] 创建 REQ: {newKey}");

        // 创建成功后，尝试通过 update API 补回被过滤的字段（如 labels）
        if (removedFields != null && removedFields.Count > 0)
        {
            // labels 需要用 update 操作格式，不能用 fields 直接设置
            if (removedFields.Contains("labels") && labels.Count > 0)
            {
                try
                {
                    var updateBlock = new JObject
                    {
                        ["labels"] = new JArray(new JObject { ["set"] = new JArray(labels) })
                    };
                    await _jira.UpdateIssueOperationsAsync(newKey, updateBlock);
                    logger($"[补设] 已通过 update 操作设置 labels: {string.Join(", ", labels)}");
                }
                catch (Exception ex)
                {
                    logger($"[补设失败] labels: {ex.Message}");
                }
            }
        }

        // 4) 上传附件
        var oaBaseURL = ExtractBaseURL(oaLink);
        if (pickedAttachments.Count > 0)
        {
            logger($"下载并上传附件 {pickedAttachments.Count} 个 ...");
            foreach (var att in pickedAttachments)
            {
                try
                {
                    var downloaded = await OAService.Shared.DownloadAttachmentAsync(att.Url);
                    await _jira.UploadAttachmentAsync(
                        newKey,
                        string.IsNullOrEmpty(downloaded.Name) ? att.Name : downloaded.Name,
                        downloaded.Data,
                        downloaded.MimeType);
                    logger($"  ✓ 已上传: {downloaded.Name}");
                }
                catch (Exception ex)
                {
                    logger($"  ✗ 附件失败 [{att.Name}]: {ex.Message}");
                    logger("  🔍 正在生成下载诊断报告 ...");
                    await OAService.Shared.DiagnoseDownloadAsync(att, oaBaseURL, oaLink);
                }
            }
        }

        // 5) 关联 REM（已关联则跳过，关联关系读不到时不创建）
        if (parsed.RemKeys.Count > 0)
        {
            logger($"关联 REM {string.Join(",", parsed.RemKeys)} ...");
            foreach (var rem in parsed.RemKeys)
            {
                try
                {
                    var outcome = await _jira.LinkIssuesIfAbsentAsync(newKey, rem, "关联");
                    logger(outcome switch
                    {
                        JiraService.LinkOutcome.Created => $"  ✓ 已关联 {rem}",
                        JiraService.LinkOutcome.AlreadyLinked => $"  ⏭ {rem} 已关联，跳过",
                        _ => $"  ⚠️ 无法确认 {rem} 的已有关联，本次未关联，请手动检查"
                    });
                }
                catch (Exception ex)
                {
                    logger($"  ✗ 关联失败 {rem}: {ex.Message}");
                }
            }
        }

        return newKey;
    }

    // MARK: - Helpers

    /// <summary>格式化今天日期为 Jira 接受的格式（如 2026-04-30T15:20:26.620+0800）</summary>
    private static string FormatTodayDate()
    {
        var now = DateTime.Now;
        var offset = TimeZoneInfo.Local.GetUtcOffset(now);
        var sign = offset >= TimeSpan.Zero ? "+" : "-";
        var offsetStr = $"{sign}{offset.Hours:D2}{offset.Minutes:D2}";
        return now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff") + offsetStr;
    }

    /// <summary>从 400 错误信息中提取不能设置的字段列表（支持 customfield_XXXX 和 labels 等内置字段名）</summary>
    private static List<string>? ParseBadFieldsFromError(string errorMsg)
    {
        var matches = Regex.Matches(errorMsg, @"Field\s+'([a-zA-Z_][a-zA-Z_0-9]*)'\s+cannot\s+be\s+set", RegexOptions.IgnoreCase);
        if (matches.Count == 0) return null;
        var result = new List<string>();
        foreach (Match m in matches)
        {
            if (m.Groups.Count >= 2)
                result.Add(m.Groups[1].Value);
        }
        return result;
    }

    /// <summary>克隆级联字段结构</summary>
    private static JToken CloneCascading(JToken? value)
    {
        if (value is not JObject dict) return new JObject();
        var result = new JObject();
        if (dict["value"] != null) result["value"] = dict["value"];
        if (dict["id"] != null) result["id"] = dict["id"];
        if (dict["child"] is JObject child)
        {
            var c = new JObject();
            if (child["value"] != null) c["value"] = child["value"];
            if (child["id"] != null) c["id"] = child["id"];
            result["child"] = c;
        }
        return result;
    }

    /// <summary>对“选项类”字段（单选/多选/级联）：按名字反查 id，使用 createmeta 元数据解析正确的 option id</summary>
    private static void ApplyFieldByName(
        JObject newFields,
        JObject templateFields,
        Dictionary<string, string> nameToId,
        string[] candidateNames,
        string stringValue,
        Dictionary<string, JArray> fieldOptions,
        Dictionary<string, string> fieldSchemaTypes,
        Action<string> logger)
    {
        if (string.IsNullOrEmpty(stringValue)) return;
        var cfId = ResolveCustomFieldId(nameToId, candidateNames, logger);
        if (cfId == null)
        {
            logger($"[跳过] 未在模板中找到字段：{string.Join("/", candidateNames)}");
            return;
        }
        
        var templateVal = templateFields[cfId];
        if (templateVal is JObject dict)
        {
            // 单选 / 级联字段
            fieldOptions.TryGetValue(cfId, out var metaOptions);
            if (metaOptions != null)
            {
                // 有元数据：解析正确的 option id
                var matched = FindOptionByValue(metaOptions, stringValue);
                if (matched != null)
                {
                    var result = new JObject { ["id"] = matched["id"] };
                    if (matched["value"] != null) result["value"] = matched["value"];
                    // 级联字段：处理 child
                    if (dict["child"] is JObject templateChild)
                    {
                        var childVal = templateChild["value"]?.Value<string>();
                        if (!string.IsNullOrEmpty(childVal))
                        {
                            var children = matched["children"] as JArray;
                            if (children != null)
                            {
                                var childMatched = FindOptionByValue(children, childVal);
                                if (childMatched != null)
                                {
                                    var c = new JObject { ["id"] = childMatched["id"] };
                                    if (childMatched["value"] != null) c["value"] = childMatched["value"];
                                    result["child"] = c;
                                    logger($"[设置] {cfId} = {stringValue} > {childVal} (id 匹配成功)");
                                }
                                else
                                {
                                    var c = new JObject { ["value"] = childVal };
                                    result["child"] = c;
                                    logger($"[设置] {cfId} = {stringValue} (父级 id 匹配，子选项 '{childVal}' 未匹配到 id)");
                                }
                            }
                        }
                    }
                    else
                    {
                        logger($"[设置] {cfId} = {stringValue} (id={matched["id"]?.Value<string>()})");
                    }
                    newFields[cfId] = result;
                }
                else
                {
                    // 元数据有但找不到匹配选项：打印可用选项并跳过
                    var available = string.Join(", ", metaOptions
                        .Select(o => o["value"]?.Value<string>() ?? "?")
                        .Where(v => v != "?"));
                    logger($"[跳过] {cfId} 元数据中未找到匹配 '{stringValue}' 的选项，可用选项: [{available}]");
                }
            }
            else
            {
                // 无元数据：仅发送 value
                var result = new JObject { ["value"] = stringValue };
                if (dict["child"] is JObject child)
                {
                    var c = new JObject();
                    if (child["value"] != null) c["value"] = child["value"];
                    result["child"] = c;
                }
                newFields[cfId] = result;
                logger($"[设置] {cfId} = {stringValue} (无元数据，按 value)");
            }
            return;
        }
        if (templateVal is JArray arr && arr.Count > 0 && arr[0] is JObject)
        {
            // 多选字段
            fieldOptions.TryGetValue(cfId, out var metaOptions);
            if (metaOptions != null)
            {
                var matched = FindOptionByValue(metaOptions, stringValue);
                if (matched != null)
                {
                    var item = new JObject { ["id"] = matched["id"] };
                    if (matched["value"] != null) item["value"] = matched["value"];
                    newFields[cfId] = new JArray(item);
                    logger($"[设置] {cfId} = [{stringValue}] (id 匹配成功)");
                    return;
                }
                var available = string.Join(", ", metaOptions
                    .Select(o => o["value"]?.Value<string>() ?? "?")
                    .Where(v => v != "?"));
                logger($"[跳过] {cfId} 元数据中未找到匹配 '{stringValue}' 的选项，可用选项: [{available}]");
                return;
            }
            var first = new JObject { ["value"] = stringValue };
            newFields[cfId] = new JArray(first);
            logger($"[设置] {cfId} = [{stringValue}] (无元数据，按 value)");
            return;
        }
        // 字符串字段或 null
        if (templateVal is JValue || templateVal == null)
        {
            // 检查 createmeta schema 判断是否为选项/级联字段（模板值为 null 但字段实际是选项类型）
            if (templateVal == null && fieldSchemaTypes.TryGetValue(cfId, out var schemaType)
                && (schemaType == "option" || schemaType == "cascadingSelect"))
            {
                // 选项/级联字段但模板无值，无法确定正确的 option id，跳过
                if (fieldOptions.TryGetValue(cfId, out var opts))
                {
                    var available = string.Join(", ", opts
                        .Select(o => o["value"]?.Value<string>() ?? "?")
                        .Where(v => v != "?"));
                    logger($"[跳过] {cfId} 是{schemaType}类型字段但模板无值，无法设置 '{stringValue}'，可用选项: [{available}]");
                }
                else
                {
                    logger($"[跳过] {cfId} 是{schemaType}类型字段但模板无值，无法设置 '{stringValue}'");
                }
                return;
            }
            newFields[cfId] = stringValue;
            return;
        }
        logger($"[跳过] 字段 {cfId} 模板结构未知，忽略: {string.Join("/", candidateNames)}");
    }

    /// <summary>在 allowedValues 中按 value 文本查找匹配的选项</summary>
    /// <remarks>匹配优先级：精确匹配 > 忽略大小写/空格 > 包含匹配</remarks>
    private static JObject? FindOptionByValue(JArray allowedValues, string targetValue)
    {
        // 1. 精确匹配
        foreach (var opt in allowedValues)
        {
            if (opt is JObject o && o["value"]?.Value<string>() == targetValue)
                return o;
        }
        // 2. 尝试忽略大小写和首尾空格
        var trimmed = targetValue.Trim();
        foreach (var opt in allowedValues)
        {
            if (opt is JObject o && o["value"]?.Value<string>()?.Trim().Equals(trimmed, StringComparison.OrdinalIgnoreCase) == true)
                return o;
        }
        // 3. 包含匹配（选项值包含用户输入，或用户输入包含选项值）
        foreach (var opt in allowedValues)
        {
            if (opt is JObject o)
            {
                var optVal = o["value"]?.Value<string>()?.Trim();
                if (!string.IsNullOrEmpty(optVal) && !string.IsNullOrEmpty(trimmed))
                {
                    if (optVal.Contains(trimmed, StringComparison.OrdinalIgnoreCase) ||
                        trimmed.Contains(optVal, StringComparison.OrdinalIgnoreCase))
                        return o;
                }
            }
        }
        return null;
    }

    /// <summary>用户字段：按名字反查 id，写入 {name: userName}</summary>
    private static void ApplyUserFieldByName(
        JObject newFields,
        JObject templateFields,
        Dictionary<string, string> nameToId,
        string[] candidateNames,
        string userName,
        Action<string> logger)
    {
        if (string.IsNullOrEmpty(userName)) return;
        var cfId = ResolveCustomFieldId(nameToId, candidateNames, logger);
        if (cfId == null)
        {
            logger($"[跳过] 未在模板中找到用户字段：{string.Join("/", candidateNames)}");
            return;
        }

        var templateVal = templateFields[cfId];
        if (templateVal?.Type == JTokenType.String)
        {
            newFields[cfId] = userName;
            return;
        }
        if (templateVal is JArray)
        {
            newFields[cfId] = new JArray(new JObject { ["name"] = userName });
            return;
        }
        // 默认当作单用户 {name: ...}
        newFields[cfId] = new JObject { ["name"] = userName };
    }

    private static string? ResolveCustomFieldId(Dictionary<string, string> nameToId, string[] candidates, Action<string>? logger = null)
    {
        foreach (var c in candidates)
        {
            if (nameToId.TryGetValue(c, out var id))
            {
                logger?.Invoke($"[字段匹配] '{c}' → {id} (精确匹配)");
                return id;
            }
        }
        // 模糊匹配：包含候选名的 key
        foreach (var (name, id) in nameToId)
        {
            foreach (var c in candidates)
            {
                if (name.Contains(c))
                {
                    logger?.Invoke($"[字段匹配] '{c}' → {id} (模糊匹配, 字段名='{name}')");
                    return id;
                }
            }
        }
        return null;
    }

    /// <summary>从错误信息中提取有无效选项值的字段（如 "Could not find valid 'id' or 'value'"）</summary>
    private static List<string>? ParseInvalidOptionFieldsFromError(string errorMsg)
    {
        // 匹配格式："errors":{"customfield_10118":"Could not find valid..."}
        var pattern = "\"(customfield_\\d+)\"\\s*:\\s*\"[^\"]*(?:Could not find valid|not a valid)\"";
        var matches = Regex.Matches(errorMsg, pattern, RegexOptions.IgnoreCase);
        if (matches.Count == 0) return null;
        var result = new List<string>();
        foreach (Match m in matches)
        {
            if (m.Groups.Count >= 2)
                result.Add(m.Groups[1].Value);
        }
        return result;
    }

    /// <summary>第二轮容错：识别无效选项字段，打印可用选项，移除后重试</summary>
    private async Task<string> RetryWithFieldRemoval(
        JObject newFields, string? issueTypeId, Exception ex,
        Dictionary<string, JArray> fieldOptions, Action<string> logger)
    {
        var errorMsg = ex.Message;
        var invalidFields = ParseInvalidOptionFieldsFromError(errorMsg);
        if (invalidFields != null && invalidFields.Count > 0)
        {
            foreach (var field in invalidFields)
            {
                // 打印该字段的可用选项
                if (fieldOptions.TryGetValue(field, out var opts))
                {
                    var values = new List<string>();
                    foreach (var o in opts)
                    {
                        var v = o["value"]?.Value<string>();
                        if (!string.IsNullOrEmpty(v))
                            values.Add(v);
                    }
                    var available = string.Join(", ", values);
                    logger($"[跳过] {field} 选项值无效，可用选项: [{available}]");
                }
                else
                {
                    logger($"[跳过] {field} 选项值无效，无元数据可用");
                }
                newFields.Remove(field);
            }
            return await _jira.CreateIssueAsync("REQ", issueTypeId ?? "", newFields);
        }
        throw ex;
    }

    /// <summary>从 OA 链接提取 baseURL（强制 https）</summary>
    private static string ExtractBaseURL(string link)
    {
        try
        {
            var uri = new Uri(link);
            return $"https://{uri.Host}" + (uri.IsDefaultPort ? "" : $":{uri.Port}");
        }
        catch
        {
            return link;
        }
    }
}
