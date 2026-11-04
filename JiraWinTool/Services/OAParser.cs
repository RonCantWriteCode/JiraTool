using System.Text.RegularExpressions;
using JiraWinTool.Models;
using JiraWinTool.Utils;

namespace JiraWinTool.Services;

/// <summary>OA 页面启发式解析器（移植自 Swift OAParser.swift）</summary>
public static class OAParser
{
    /// <summary>入口：解析 OA 详情页 HTML</summary>
    public static OAParseResult Parse(string html, string baseURL)
    {
        var title = ExtractTitle(html);
        var drafter = ExtractDrafter(html);
        var draftDept = ExtractDraftDept(html);
        var applyNo = ExtractApplyNo(html);
        var content = ExtractContent(html);
        var remKeys = ExtractREMFromAuditNotes(html);
        if (remKeys.Count == 0)
            remKeys = ExtractREMKeys(html + " " + content + " " + title);
        var attachments = ExtractAttachments(html, baseURL);

        return new OAParseResult
        {
            Title = title,
            Drafter = drafter,
            DraftDept = draftDept,
            BranchCompany = "",  // 由视图层从 DraftDept 派生
            Content = content,
            ApplyNo = applyNo,
            RemKeys = remKeys,
            Attachments = attachments
        };
    }

    // MARK: - Title

    private static string ExtractTitle(string html)
    {
        // 优先从页面正文 DOM 找 "标题" 字段
        var v = ExtractFieldByTd(html, new[] { "标题", "主题", "事项名称", "名称" });
        if (!string.IsNullOrEmpty(v)) return v;

        var m = Regex.Match(html, @"<title[^>]*>([\s\S]*?)</title>", RegexOptions.IgnoreCase);
        if (m.Success)
        {
            var title = StripTags(m.Groups[1].Value).Trim();
            title = Regex.Replace(title, @"\s*-流程.*$", "").Trim();
            title = Regex.Replace(title, @"\s*-OA$", "").Trim();
            return title;
        }
        return "";
    }

    // MARK: - Drafter

    private static string ExtractDrafter(string html)
    {
        return ExtractFieldByTd(html, new[] { "申请人", "拟稿人", "起草人", "提交人" });
    }

    // MARK: - DraftDept
    
    private static string ExtractDraftDept(string html)
    {
        // 策略 1：从 addressName span 提取
        var m = Regex.Match(html, @"<span[^>]*class=""[^""]*addressName[^""]*""[^>]*>([\s\S]*?)</span>", RegexOptions.IgnoreCase);
        if (m.Success)
        {
            var raw = StripTags(m.Groups[1].Value).Trim();
            if (!string.IsNullOrEmpty(raw) && raw.Length > 3 && !raw.StartsWith("1")) return raw;
        }
    
        // 策略 2：从 xform_address 的 hidden input 提取
        var inputMatches = Regex.Matches(html, @"<input[^>]*name=""extendDataFormInfo\.value\([^)]*\.name\)""[^>]*>", RegexOptions.IgnoreCase);
        foreach (Match im in inputMatches)
        {
            var tag = im.Value;
            var vm = Regex.Match(tag, @"value=""([^""]*)""");
            if (vm.Success)
            {
                var val = DecodeHtmlEntities(vm.Groups[1].Value).Trim();
                if (val.Contains('/') || val.Contains("公司") || val.Contains("部门"))
                    return val;
            }
        }
        return "";
    }

    // MARK: - ApplyNo

    private static string ExtractApplyNo(string html)
    {
        // 诊断：检查 HTML 中是否包含关键字
        foreach (var key in new[] { "申请单编号", "单据编号", "文档编号", "流水号", "编号" })
        {
            var count = 0;
            var idx = 0;
            while ((idx = html.IndexOf(key, idx, StringComparison.Ordinal)) >= 0) { count++; idx += key.Length; }
            if (count > 0) Log.Debug($"[OAParser.ExtractApplyNo] HTML 中包含 '{key}' {count} 次");
        }
        // 诊断：检查 td_normal_title 数量
        var tdCount = Regex.Matches(html, "td_normal_title", RegexOptions.IgnoreCase).Count;
        Log.Debug($"[OAParser.ExtractApplyNo] HTML 中 td_normal_title 出现 {tdCount} 次");

        var result = ExtractFieldByTd(html, new[] { "申请单编号", "单据编号", "文档编号", "流水号", "编号" });
        if (!string.IsNullOrEmpty(result))
        {
            Log.Debug($"[OAParser.ExtractApplyNo] ✅ 提取成功: {result}");
            return result;
        }
        Log.Debug("[OAParser.ExtractApplyNo] ❌ 提取失败，返回空");
        return "";
    }

    // MARK: - Content

    private static string ExtractContent(string html)
    {
        var m = Regex.Match(html, @"<div[^>]*class=""[^""]*xform_textArea[^""]*""[^>]*>([\s\S]*?)</div>", RegexOptions.IgnoreCase);
        if (m.Success)
        {
            var cleaned = StripXformContent(m.Groups[1].Value);
            if (cleaned.Length >= 10) return cleaned;
        }
        return ExtractContentFallback(html);
    }

    private static string StripXformContent(string s)
    {
        s = Regex.Replace(s, @"<script[\s\S]*?</script>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<style[\s\S]*?</style>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</p>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</div>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<xformflag[^>]*>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</xformflag>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<[^>]+>", "", RegexOptions.IgnoreCase);
        s = s.Replace("&nbsp;", " ").Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">");
        s = Regex.Replace(s, @"[\t\r\f\v]+", " ");
        s = Regex.Replace(s, @"\n{3,}", "\n\n");
        return s.Trim();
    }

    private static string ExtractContentFallback(string html)
    {
        var keys = new[] { "申请内容", "主要内容", "需求内容", "详细说明", "申请事由", "内容描述", "正文内容" };
        foreach (var key in keys)
        {
            var idx = html.IndexOf(key);
            if (idx < 0) continue;
            var window = html[idx..Math.Min(idx + 20000, html.Length)];
            var m = Regex.Match(window, @"<textarea[^>]*>([\s\S]*?)</textarea>", RegexOptions.IgnoreCase);
            if (m.Success && StripTags(m.Groups[1].Value).Length >= 4) return StripTags(m.Groups[1].Value);
            var tdMs = Regex.Matches(window, @"<t[dh][^>]*>([\s\S]*?)</t[dh]>", RegexOptions.IgnoreCase);
            foreach (Match tm in tdMs)
            {
                var t = StripTags(tm.Groups[1].Value);
                if (t.Length >= 10 && !t.Contains('\t')) return t;
            }
            return StripTags(window)[..Math.Min(4000, StripTags(window).Length)];
        }
        return StripTags(html)[..Math.Min(4000, StripTags(html).Length)];
    }

    // MARK: - Td field extraction

    private static string ExtractFieldByTd(string html, string[] keys)
    {
        foreach (var key in keys)
        {
            var m = Regex.Match(html, $@"<td[^>]*class=""[^""]*td_normal_title[^""]*""[^>]*>.*?{Regex.Escape(key)}.*?</td>", RegexOptions.IgnoreCase | RegexOptions.Singleline);
            if (!m.Success)
            {
                Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' 未匹配到 td_normal_title");
                continue;
            }
            Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' 匹配成功，match.Index={m.Index}, match.Length={m.Length}");

            var endPos = m.Index + m.Length;
            // 兰凌 EKP 的 td 标签属性较多，整个 <td>...</td> 可能超过 500 字符
            var remainLen = Math.Min(2000, html.Length - endPos);
            Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' endPos={endPos}, html.Length={html.Length}, remainLen={remainLen}");
            var remain = html[endPos..(endPos + remainLen)];
            var tm = Regex.Match(remain, @"<td[^>]*>([\s\S]*?)</td>", RegexOptions.IgnoreCase);
            if (!tm.Success)
            {
                Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' 后续 2000 字符内未找到 <td>");
                continue;
            }

            var raw = tm.Groups[1].Value;
            Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' 原始值(前200字): {raw[..Math.Min(200, raw.Length)]}");
            var val = CleanupFieldTdValue(raw);
            Log.Debug($"[OAParser.ExtractFieldByTd] '{key}' 清理后: '{val}'");
            if (!string.IsNullOrEmpty(val)) return val;
        }
        return "";
    }

    private static string CleanupFieldTdValue(string s)
    {
        s = Regex.Replace(s, @"<input[^>]*type=[""']?hidden[""']?[^>]*>", " ", RegexOptions.IgnoreCase);
        return StripTags(s).Trim();
    }

    // MARK: - REM extraction

    private static List<string> ExtractREMKeys(string text)
    {
        var result = new List<string>();
        var seen = new HashSet<string>();
        foreach (Match m in Regex.Matches(text, @"REM-?\d{3,}", RegexOptions.IgnoreCase))
        {
            var key = m.Value.ToUpper();
            if (!key.Contains('-'))
            {
                var digits = Regex.Match(key, @"\d+");
                if (digits.Success) key = "REM-" + digits.Value;
            }
            if (seen.Add(key)) result.Add(key);
        }
        return result;
    }

    /// <summary>从流程审批意见区域提取 REM 号</summary>
    public static List<string> ExtractREMFromAuditNotes(string html)
    {
        var combinedHTML = html;
        var seen = new HashSet<string>();
        var result = new List<string>();

        // 收集各种历史记录容器
        foreach (var pattern in new[]
        {
            @"<div[^>]*id=[""'].*?auditHistory.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?process[-\s]?history.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?audit[-\s]?log.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?workflow[-\s]?history.*?['""][^>]*>([\s\S]*?)</div>",
        })
        {
            foreach (Match m in Regex.Matches(html, pattern, RegexOptions.IgnoreCase))
            {
                if (m.Groups.Count >= 2) combinedHTML += "\n" + m.Groups[1].Value;
            }
        }

        // 主正则：搜索所有 auditNote 标签
        foreach (Match m in Regex.Matches(combinedHTML, @"<label[^>]*class=[""'].*?auditNote.*?['""][^>]*>([\s\S]*?)</label>", RegexOptions.IgnoreCase))
        {
            var auditContent = m.Groups[1].Value;
            foreach (Match rm in Regex.Matches(auditContent, @"REM-?\d{3,}", RegexOptions.IgnoreCase))
            {
                var key = rm.Value.ToUpper();
                if (!key.Contains('-'))
                {
                    var digits = Regex.Match(key, @"\d+");
                    if (digits.Success) key = "REM-" + digits.Value;
                }
                if (seen.Add(key)) result.Add(key);
            }
        }

        // 兜底：全文搜索
        if (result.Count == 0)
        {
            result.AddRange(ExtractREMKeys(html));
        }
        return result;
    }

    // MARK: - Attachments

    /// <summary>公开入口：仅解析附件（用于审批日志等二次解析场景）</summary>
    public static List<OAAttachment> ParseAttachments(string html, string baseURL)
    {
        return ExtractAttachments(html, baseURL);
    }

    private static List<OAAttachment> ExtractAttachments(string html, string baseURL)
    {
        var result = new List<OAAttachment>();
        var seen = new HashSet<string>();

        // 前置：提取 Swf_AttachmentObject 的 modelName 映射
        // 支持两种格式：fd_<14hex>_<32hex> 和 <32hex>_<32hex>
        var modelMap = new Dictionary<string, string>();
        foreach (Match m in Regex.Matches(html, @"Swf_AttachmentObject\(""(?:fd_[a-f0-9]{14}|[a-f0-9]{32})_([a-f0-9]{32})"",""([^""]+)"",""([a-f0-9]{32})""", RegexOptions.IgnoreCase))
        {
            if (m.Groups.Count >= 3) modelMap[m.Groups[1].Value] = m.Groups[2].Value;
        }

        // 方式 A：bound addDoc（每个附件绑定到自己的 SWF 组件 prefix）
        // 支持两种格式：
        //   主页面：attachmentObject_fd_<14hex>_<32hex>.addDoc(...)
        //   审批意见：attachmentObject_<32hex>_<32hex>.addDoc(...)
        foreach (Match m in Regex.Matches(html, @"attachmentObject_(?:fd_([a-f0-9]{14})|([a-f0-9]{32}))_([a-f0-9]{32})\.addDoc\(\s*""([^""]+)""\s*,\s*""([a-f0-9]{32})""\s*,\s*(?:true|false)\s*,\s*""([^""]*)""\s*,\s*""([^""]*)""\s*,\s*""([a-f0-9]{32})""", RegexOptions.IgnoreCase))
        {
            if (m.Groups.Count < 9) continue;
            // Group1 = fd_后的14位（主页面），Group2 = 32位prefix（审批意见），取非空者
            var prefix14 = m.Groups[1].Value;
            var prefix32 = m.Groups[2].Value;
            var prefix = !string.IsNullOrEmpty(prefix14) ? "fd_" + prefix14 : prefix32;
            var modelId = m.Groups[3].Value;
            var rawName = m.Groups[4].Value;
            var fdId = m.Groups[5].Value;
            var fdFileId = m.Groups[8].Value;
            var name = DecodeUnicodeEscapes(rawName);
            var key = prefix + "_" + fdId;
            if (!seen.Add(key)) continue;

            var modelName = modelMap.GetValueOrDefault(modelId, "");
            var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            var url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=" + fdId + "&isSupportDirect=null&downloadType=manual&downloadFlag=" + ts;

            result.Add(new OAAttachment
            {
                Name = string.IsNullOrEmpty(name) ? fdId : name,
                Url = url, Prefix = prefix, FdId = fdId, FdFileId = fdFileId,
                ModelName = modelName, ModelId = modelId,
                IsTemplateAttachment = prefix == "fd_36d9d9ef7503d8"
            });
        }

        // 方式 B：宽松 addDoc 提取
        if (result.Count == 0)
        {
            foreach (Match m in Regex.Matches(html, @"addDoc\(\s*""([^""]+)""\s*,\s*""([a-f0-9]{32})""\s*,\s*(?:true|false)\s*,\s*""([^""]*)""\s*,\s*""([^""]*)""\s*,\s*""([a-f0-9]{32})""", RegexOptions.IgnoreCase))
            {
                if (m.Groups.Count < 6) continue;
                var rawName = m.Groups[1].Value;
                var fdId = m.Groups[2].Value;
                var name = DecodeUnicodeEscapes(rawName);
                if (!seen.Add(fdId)) continue;
                var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
                var url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=" + fdId + "&isSupportDirect=null&downloadType=manual&downloadFlag=" + ts;
                result.Add(new OAAttachment { Name = string.IsNullOrEmpty(name) ? fdId : name, Url = url, FdId = fdId });
            }
        }

        // 方式 C：只取 fileName + fdId
        if (result.Count == 0)
        {
            foreach (Match m in Regex.Matches(html, @"addDoc\(\s*""([^""]+)""\s*,\s*""([a-f0-9]{32})""", RegexOptions.IgnoreCase))
            {
                if (m.Groups.Count < 3) continue;
                var rawName = m.Groups[1].Value;
                var fdId = m.Groups[2].Value;
                var name = DecodeUnicodeEscapes(rawName);
                if (!seen.Add(fdId)) continue;
                var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
                var url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=" + fdId + "&isSupportDirect=null&downloadType=manual&downloadFlag=" + ts;
                result.Add(new OAAttachment { Name = string.IsNullOrEmpty(name) ? fdId : name, Url = url, FdId = fdId });
            }
        }

        // 方式 D：从 DOM 补充
        if (result.Count == 0)
        {
            foreach (Match m in Regex.Matches(html, @"<div\s+id=""([a-f0-9]{32})""[^>]*upload_list_tr_view[^>]*>[\s\S]*?<span[^>]*upload_list_filename_title[^>]*>([\s\S]*?)</span>", RegexOptions.IgnoreCase))
            {
                var fdId = m.Groups[1].Value;
                var name = StripTags(m.Groups[2].Value).Trim();
                if (string.IsNullOrEmpty(fdId) || !seen.Add(fdId)) continue;
                var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
                var url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=" + fdId + "&isSupportDirect=null&downloadType=manual&downloadFlag=" + ts;
                result.Add(new OAAttachment { Name = string.IsNullOrEmpty(name) ? fdId : name, Url = url, FdId = fdId });
            }
        }

        return result;
    }

    // MARK: - REQ extraction by operator

    /// <summary>从审批意见中提取指定操作人的 REQ 号</summary>
    /// <param name="html">审批日志 HTML（来自 lbpmAuditNote.do 或主页面）</param>
    /// <param name="operatorName">操作人姓名（如"吴润龙"）</param>
    /// <returns>去重后的 REQ 号列表（如 ["REQ-12345", "REQ-67890"]）</returns>
    public static List<string> ExtractREQByOperator(string html, string operatorName)
    {
        // 复用 ExtractREMFromAuditNotes 的容器收集策略
        var combinedHTML = html;

        // 收集各种历史记录容器（与 Swift extractREQByOperator 完全对齐）
        foreach (var pattern in new[]
        {
            @"<div[^>]*id=[""'].*?auditHistory.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?process[-\s]?history.*?['""][^>]*>([\s\S]*?)</div>",
        })
        {
            foreach (Match m in Regex.Matches(html, pattern, RegexOptions.IgnoreCase))
            {
                if (m.Groups.Count >= 2) combinedHTML += "\n" + m.Groups[1].Value;
            }
        }

        // 额外容器（与 Swift containerPatterns 完全对齐）
        foreach (var pattern in new[]
        {
            @"<div[^>]*class=[""'].*?audit[-\s]?log.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?workflow[-\s]?history.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?approval[-\s]?list.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?trace[-\s]?record.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?process[-\s]?log.*?['""][^>]*>([\s\S]*?)</div>",
            @"<div[^>]*class=[""'].*?history[-\s]?list.*?['""][^>]*>([\s\S]*?)</div>",
            @"<section[^>]*id=[""'].*?workflow[-\s]?history.*?['""][^>]*>([\s\S]*?)</section>",
            @"<ul[^>]*class=[""'].*?approval[-\s]?list.*?['""][^>]*>([\s\S]*?)</ul>",
        })
        {
            foreach (Match m in Regex.Matches(html, pattern, RegexOptions.IgnoreCase))
            {
                if (m.Groups.Count >= 2) combinedHTML += "\n" + m.Groups[1].Value;
            }
        }

        Log.Debug($"[OAParser.ExtractREQByOperator] combinedHTML length={combinedHTML.Length}, operatorName={operatorName}");

        var reqPattern = @"REQ-\d+";
        var seen = new HashSet<string>();
        var result = new List<string>();

        // ========== 策略 A（主）：表格行解析 ==========
        // 审批记录为 <table> 结构，每行 <tr> 包含 5 个 <td>：
        //   时间 | 节点名称 | 操作者 | 操作 | 处理意见
        // 操作者在第 3 列，处理意见在第 5 列
        var trMatches = Regex.Matches(combinedHTML,
            @"<tr[^>]*>([\s\S]*?)</tr>", RegexOptions.IgnoreCase);
        Log.Debug($"[OAParser.ExtractREQByOperator] 策略A: 找到 <tr> 行数={trMatches.Count}");

        foreach (Match trMatch in trMatches)
        {
            var rowHTML = trMatch.Groups[1].Value;
            var tdMatches = Regex.Matches(rowHTML, @"<td[^>]*>([\s\S]*?)</td>", RegexOptions.IgnoreCase);
            // 至少需要 5 列（时间、节点、操作者、操作、处理意见）
            if (tdMatches.Count < 5) continue;

            // 第 3 列 = 操作者（index=2）
            var operatorText = StripTags(tdMatches[2].Groups[1].Value).Trim();
            // 第 5 列 = 处理意见（index=4）
            var commentText = tdMatches[4].Groups[1].Value;

            Log.Debug($"[OAParser.ExtractREQByOperator] 策略A: 操作者列='{operatorText}', 处理意见(前80字)='{StripTags(commentText)[..Math.Min(80, StripTags(commentText).Length)]}'");

            if (operatorText.StartsWith(operatorName))
            {
                Log.Debug($"[OAParser.ExtractREQByOperator] 策略A ✅ 操作人匹配: '{operatorText}' startsWith '{operatorName}'");
                foreach (Match reqMatch in Regex.Matches(commentText, reqPattern, RegexOptions.IgnoreCase))
                {
                    var reqKey = reqMatch.Value.ToUpper();
                    if (seen.Add(reqKey))
                    {
                        result.Add(reqKey);
                    }
                }
            }
        }

        if (result.Count > 0)
        {
            Log.Debug($"[OAParser.ExtractREQByOperator] 策略A 表格行提取完成，共 {result.Count} 个 REQ");
            return result;
        }

        // ========== 策略 B（兜底）：auditNote 标签 + startsWith ==========
        Log.Debug("[OAParser.ExtractREQByOperator] 策略A 表格行未匹配到结果，启用策略B auditNote + startsWith");

        var auditMatches = Regex.Matches(combinedHTML,
            @"<label[^>]*class=[""'].*?auditNote.*?['""][^>]*>([\s\S]*?)</label>",
            RegexOptions.IgnoreCase);
        Log.Debug($"[OAParser.ExtractREQByOperator] 策略B: auditNote matches={auditMatches.Count}");

        foreach (Match m in auditMatches)
        {
            var auditContent = m.Groups[1].Value;
            var windowStart = Math.Max(0, m.Index - 500);
            var windowLen = Math.Min(500, m.Index - windowStart);
            var window = combinedHTML.Substring(windowStart, windowLen);

            // 按行分割窗口，stripTags 后检查是否有行以 operatorName 开头
            var matched = false;
            foreach (var line in window.Split('\n'))
            {
                var stripped = StripTags(line).Trim();
                if (stripped.StartsWith(operatorName))
                {
                    matched = true;
                    Log.Debug($"[OAParser.ExtractREQByOperator] 策略B: 行 '{stripped[..Math.Min(50, stripped.Length)]}' startsWith '{operatorName}'");
                    break;
                }
            }

            if (matched)
            {
                foreach (Match reqMatch in Regex.Matches(auditContent, reqPattern, RegexOptions.IgnoreCase))
                {
                    var reqKey = reqMatch.Value.ToUpper();
                    if (seen.Add(reqKey))
                    {
                        result.Add(reqKey);
                    }
                }
            }
        }

        // ========== 策略 C（兜底）：全文纯文本 startsWith ==========
        if (result.Count == 0)
        {
            Log.Debug("[OAParser.ExtractREQByOperator] 策略B 未匹配，启用策略C 全文纯文本 startsWith");
            var plainText = StripTags(combinedHTML);
            var segments = plainText.Split('\n');
            for (var i = 0; i < segments.Length; i++)
            {
                var trimmed = segments[i].Trim();
                if (trimmed.StartsWith(operatorName))
                {
                    Log.Debug($"[OAParser.ExtractREQByOperator] 策略C: 第{i}行 startsWith '{operatorName}': '{trimmed[..Math.Min(50, trimmed.Length)]}'");
                    var winStart = Math.Max(0, i - 2);
                    var winEnd = Math.Min(segments.Length - 1, i + 2);
                    var winLines = new string[winEnd - winStart + 1];
                    Array.Copy(segments, winStart, winLines, 0, winEnd - winStart + 1);
                    var window = string.Join("\n", winLines);

                    foreach (Match reqMatch in Regex.Matches(window, reqPattern, RegexOptions.IgnoreCase))
                    {
                        var reqKey = reqMatch.Value.ToUpper();
                        if (seen.Add(reqKey))
                        {
                            result.Add(reqKey);
                        }
                    }
                }
            }
        }

        Log.Debug($"[OAParser.ExtractREQByOperator] 最终提取到 {result.Count} 个 REQ: {string.Join(",", result)}");
        return result;
    }

    /// <summary>从 HTML 中提取所有 REQ 编号（不限操作人），去重后返回</summary>
    public static List<string> ExtractAllREQ(string html)
    {
        var reqPattern = @"REQ-\d+";
        var seen = new HashSet<string>();
        var result = new List<string>();
        foreach (Match m in Regex.Matches(html, reqPattern, RegexOptions.IgnoreCase))
        {
            var req = m.Value.ToUpper();
            if (seen.Add(req))
            {
                result.Add(req);
            }
        }
        return result;
    }

    // MARK: - Helpers

    public static string StripTags(string s)
    {
        s = Regex.Replace(s, @"<script[\s\S]*?</script>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<style[\s\S]*?</style>", "", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</p>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"</div>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, @"<[^>]+>", "", RegexOptions.IgnoreCase);
        s = s.Replace("&nbsp;", " ").Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"");
        s = Regex.Replace(s, @"[\t\r\f\v]+", " ");
        s = Regex.Replace(s, @"\n{3,}", "\n\n");
        return s.Trim();
    }

    private static string DecodeUnicodeEscapes(string s)
    {
        return Regex.Replace(s, @"\\u([0-9a-fA-F]{4})", m =>
        {
            var code = Convert.ToInt32(m.Groups[1].Value, 16);
            return ((char)code).ToString();
        });
    }

    private static string DecodeHtmlEntities(string s)
    {
        return s.Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"");
    }
}
