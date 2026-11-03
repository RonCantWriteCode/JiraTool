import Foundation

struct OAAttachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let url: String
    // 诊断字段（用于构造下载 URL）
    var prefix: String = ""        // SWF 组件 14 位前缀
    var fdId: String = ""          // addDoc 中的 fdId（32 位）
    var fdFileId: String = ""      // addDoc 中的 fdFileId（32 位）
    var modelName: String = ""     // Swf_AttachmentObject 的 modelName
    var modelId: String = ""       // Swf_AttachmentObject 的 modelId
    var isTemplateAttachment: Bool = false // 是否为需求模板附件（默认不勾选）
}

struct OAParseResult {
    var title: String
    var drafter: String          // 拟稿人
    var draftDept: String        // 原始拟稿部门全名
    var content: String          // 申请内容（纯文本）
    var applyNo: String          // 申请单编号
    var remKeys: [String]        // 自动检测到的 REM
    var attachments: [OAAttachment]
}

/// OA 页面启发式解析器
/// 当前已针对兰凌 EKP (Landray KM) 的 DOM 结构做精确抽取：
///   - 标题：<title>xxx -流程管理</title>
///   - 字段：<td class="td_normal_title"> 标签名 </td><td> 值 </td>
///   - 部门：<span class="addressName">xxx</span>
///   - 内容：<div class="xform_textArea"><xformflag>内容</xformflag></div>
///   - 附件：<div class="upload_list_tr_view" id="fdId">...<span class="upload_list_filename_title">名称</span>
enum OAParser {

    /// 入口：解析 OA 详情页 HTML
    static func parse(html: String, baseURL: String) -> OAParseResult {
        // 预计算小写 HTML
        let lowerHTML = (html.lowercased() as NSString)
        let title = extractTitle(html: html)
        let drafter = extractDrafter(html: html)
        let draftDept = extractDraftDept(html: html, lowerHTML: lowerHTML)
        let applyNo = extractApplyNo(html: html)
        let content = extractContent(html: html, lowerHTML: lowerHTML)
        var remKeys = extractREMFromAuditNotes(html: html, lowerHTML: lowerHTML)
        if remKeys.isEmpty {
            remKeys = extractREMKeys(from: html + " " + content + " " + title)
        }
        let attachments = extractAttachments(html: html, baseURL: baseURL)

        return OAParseResult(
            title: title,
            drafter: drafter,
            draftDept: draftDept,
            content: content,
            applyNo: applyNo,
            remKeys: remKeys,
            attachments: attachments
        )
    }

    // MARK: - Title

    private static func extractTitle(html: String) -> String {
        // 优先从页面正文 DOM 找类似 "标题" 字段的值
        if let v = extractFieldByTd(html: html, keys: ["标题", "主题", "事项名称", "名称"]), !v.isEmpty {
            return v
        }
        // <title>xxx -流程管理</title> → 取前半部分
        if let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: .regularExpression) {
            let raw = String(html[range])
            let inner = raw.replacingOccurrences(of: "<title[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "</title>", with: "")
            var title = stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            // 去掉常见后缀：-流程管理 / -流程审批 / -OA
            title = title.replacingOccurrences(of: "\\s*-流程.*$", with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: "\\s*-OA$", with: "", options: .regularExpression)
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - 拟稿人/申请人

    /// 兰凌 EKP：<td class="td_normal_title">申请人/拟稿人/起草人</td><td>...姓名</td>
    private static func extractDrafter(html: String) -> String {
        if let v = extractFieldByTd(html: html, keys: ["申请人", "拟稿人", "起草人", "提交人"]), !v.isEmpty {
            return v
        }
        return ""
    }

    // MARK: - 拟稿部门

    /// 兰凌 EKP 部门字段结构（不是 td_normal_title 形式）：
    /// <td ...><label class="xform_address"><xformflag><span class="addressName">xxx</span></xformflag></label></td>
    /// 或 hidden input 里存了 name
    private static func extractDraftDept(html: String, lowerHTML: NSString) -> String {
        // 策略 1：直接从 addressName span 提取（用深度计数器避免 [\s\S]*?</span> 回溯）
        let addrTagPattern = #"(?i)<span[^>]*class="[^"]*addressName[^"]*"[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: addrTagPattern),
           let m = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)) {
            let contentStart = m.range.location + m.range.length
            let ns = html as NSString
            if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "span", lowerHTML: lowerHTML) {
                let raw = stripTags(ns.substring(with: contentRange)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty && raw.count > 3 && !raw.hasPrefix("1") { return raw }
            }
        }
        // 策略 2：从 xform_address 的 hidden input 提取（不依赖属性顺序）
        // <input name="extendDataFormInfo.value(xxx.name)" value="部门全称" ...>
        // 先找所有含 extendDataFormInfo.value 的 input，再筛选 .name 结尾的
        let inputPattern = #"(?is)<input[^>]*name="extendDataFormInfo\.value\([^)]*\.name\)"[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: inputPattern) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: html, options: [], range: range)
            for match in matches {
                let inputTag = ns.substring(with: match.range)
                // 从这个 input tag 里提取 value="xxx"
                let valPattern = #"value="([^"]*)""#
                if let m2 = firstMatch(in: inputTag, pattern: valPattern), !m2.isEmpty {
                    let raw = decodeHTMLEntities(m2).trimmingCharacters(in: .whitespacesAndNewlines)
                    // 部门名通常包含中文或/分隔符，不会是纯 ID
                    if raw.contains("/") || raw.contains("公司") || raw.contains("部门") {
                        return raw
                    }
                }
            }
        }
        return ""
    }

    // MARK: - 申请单编号

    private static func extractApplyNo(html: String) -> String {
        // 诊断：检查 HTML 中是否包含关键字
        for key in ["申请单编号", "单据编号", "文档编号", "流水号", "编号"] {
            let count = html.components(separatedBy: key).count - 1
            if count > 0 {
                debugLog("[OAParser.extractApplyNo] HTML 中包含 '\(key)' \(count) 次")
            }
        }
        // 诊断：检查 td_normal_title 数量
        if let tdRegex = try? NSRegularExpression(pattern: #"(?is)td_normal_title"#) {
            let ns = html as NSString
            let tdCount = tdRegex.numberOfMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            debugLog("[OAParser.extractApplyNo] HTML 中 td_normal_title 出现 \(tdCount) 次")
        }
        if let v = extractFieldByTd(html: html, keys: ["申请单编号", "单据编号", "文档编号", "流水号", "编号"]), !v.isEmpty {
            debugLog("[OAParser.extractApplyNo] ✅ 提取成功: \(v)")
            return v
        }
        debugLog("[OAParser.extractApplyNo] ❌ 提取失败，返回空")
        return ""
    }

    // MARK: - 核心字段抽取：<td class="td_normal_title">KEY</td><td>VALUE</td>

    /// 在 HTML 中查找 `<td class="td_normal_title">...KEY...</td>`，然后取紧邻的下一个 `<td>...</td>` 内容
    /// 注意：字段名可能在 <label> 等嵌套标签内，所以用字符串搜索代替正则
    private static func extractFieldByTd(html: String, keys: [String]) -> String? {
        let ns = html as NSString
        let lh = ns.lowercased as NSString
        let len = ns.length

        for key in keys {
            let keyLower = key.lowercased()
            // Step 1: 找到所有 td_normal_title 的位置，检查文本内容是否包含 key
            var searchPos = 0
            var foundEnd = -1
            while searchPos < len {
                // 在 lowerHTML 中找下一个 td_normal_title
                let markerRange = lh.range(of: "td_normal_title", options: [], range: NSRange(location: searchPos, length: len - searchPos))
                guard markerRange.location != NSNotFound else { break }
                // 往前找 <td 开标签
                let tdStart = lh.range(of: "<td", options: [.backwards], range: NSRange(location: 0, length: markerRange.location))
                guard tdStart.location != NSNotFound else { searchPos = markerRange.location + markerRange.length; continue }
                // 找 > 结束开标签
                let gtAfterTd = lh.range(of: ">", options: [], range: NSRange(location: tdStart.location + 3, length: len - tdStart.location - 3))
                guard gtAfterTd.location != NSNotFound else { searchPos = markerRange.location + markerRange.length; continue }
                let contentBegin = gtAfterTd.location + 1
                // 找 </td> 闭合
                let closeTd = lh.range(of: "</td>", options: [], range: NSRange(location: contentBegin, length: len - contentBegin))
                guard closeTd.location != NSNotFound else { searchPos = markerRange.location + markerRange.length; continue }
                // 检查 td 内容是否包含 key（直接用 lowercased 内容检查，避免 stripTags 开销）
                let tdInnerLower = lh.substring(with: NSRange(location: contentBegin, length: closeTd.location - contentBegin))
                if tdInnerLower.contains(keyLower) {
                    foundEnd = closeTd.location + 5  // skip past </td>
                    break
                }
                searchPos = closeTd.location + 5
            }

            guard foundEnd > 0 else { continue }
            debugLog("[OAParser.extractFieldByTd] '\(key)' 找到标题 td")

            // Step 2: 从 foundEnd 起找下一个 <td>...</td>
            guard let valRange = findNextTdValue(html: ns, lowerHTML: lh, from: foundEnd) else {
                debugLog("[OAParser.extractFieldByTd] '\(key)' 后续未找到值 <td>")
                continue
            }
            let raw = ns.substring(with: valRange)
            debugLog("[OAParser.extractFieldByTd] '\(key)' 原始值(前200字): \(raw.prefix(200))")
            let cleaned = cleanupFieldTdValue(raw)
            debugLog("[OAParser.extractFieldByTd] '\(key)' 清理后: '\(cleaned)'")
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// 从指定位置开始，用字符串搜索找到下一个 <td>...</td> 的值区域（避免正则回溯）
    private static func findNextTdValue(html: NSString, lowerHTML: NSString, from startPos: Int) -> NSRange? {
        let len = html.length
        let pos = startPos
        // 找下一个 <td （不区分大小写，用预计算的 lowerHTML）
        let tdOpenRange = lowerHTML.range(of: "<td", options: [], range: NSRange(location: pos, length: len - pos))
        guard tdOpenRange.location != NSNotFound else { return nil }
        // 找 > 结束开标签
        let afterTd = tdOpenRange.location + tdOpenRange.length
        let gtRange = html.range(of: ">", options: [], range: NSRange(location: afterTd, length: len - afterTd))
        guard gtRange.location != NSNotFound else { return nil }
        let contentStart = gtRange.location + 1
        // 找 </td> 闭合（简单搜索，不处理嵌套 td——OA 表单值 td 不会嵌套 td）
        let closeRange = lowerHTML.range(of: "</td>", options: [], range: NSRange(location: contentStart, length: len - contentStart))
        guard closeRange.location != NSNotFound else { return nil }
        return NSRange(location: contentStart, length: closeRange.location - contentStart)
    }

    /// 清理 <td> 内的值：去掉 hidden input、保留纯文本
    private static func cleanupFieldTdValue(_ s: String) -> String {
        var v = s
        // 去掉 hidden input 标签（支持 type=hidden / type="hidden" / type='hidden'）
        v = v.replacingOccurrences(of: #"<input[^>]*type=["']?hidden["']?[^>]*>"#, with: " ", options: .regularExpression)
        v = stripTags(v)
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 申请内容

    private static func extractContent(html: String, lowerHTML: NSString) -> String {
        // 兰凌 EKP 内容在 <div class="xform_textArea">...<xformflag>内容</xformflag></div>
        // 用深度计数器替代 [\s\S]*?</div>，避免嵌套 div 导致灾难性回溯
        let tagPattern = #"(?i)<div[^>]*class="[^"]*xform_textArea[^"]*"[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern),
           let m = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)) {
            let contentStart = m.range.location + m.range.length
            let ns = html as NSString
            if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "div", lowerHTML: lowerHTML) {
                let raw = ns.substring(with: contentRange)
                // 剥掉 xformflag 等标签，保留 <br> 换行
                let cleaned = stripXformContent(raw)
                if cleaned.count >= 10 { return cleaned }
            }
        }
        // 回退：旧启发式
        return extractContentFallback(html: html, lowerHTML: lowerHTML)
    }

    /// 清理 xform_textArea 内的内容：去掉 xformflag 等标签，但保留 <br> 为换行
    private static func stripXformContent(_ s: String) -> String {
        var v = s
        v = v.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        v = v.replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
        v = v.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
        v = v.replacingOccurrences(of: "<xformflag[^>]*>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "</xformflag>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "&nbsp;", with: " ")
        v = v.replacingOccurrences(of: "&amp;", with: "&")
        v = v.replacingOccurrences(of: "&lt;", with: "<")
        v = v.replacingOccurrences(of: "&gt;", with: ">")
        v = v.replacingOccurrences(of: "[\\t\\r\\f\\v]+", with: " ", options: .regularExpression)
        v = v.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractContentFallback(html: String, lowerHTML: NSString) -> String {
        let keys = ["申请内容", "主要内容", "需求内容", "详细说明", "申请事由", "内容描述", "正文内容"]
        for key in keys {
            guard let keyRange = html.range(of: key) else { continue }
            let end = html.index(keyRange.upperBound, offsetBy: 20000, limitedBy: html.endIndex) ?? html.endIndex
            let window = String(html[keyRange.upperBound..<end])
            // 用深度计数器替代 [\s\S]*?</textarea>，避免灾难性回溯
            let textareaTagPattern = #"(?i)<textarea[^>]*>"#
            if let regex = try? NSRegularExpression(pattern: textareaTagPattern),
               let m = regex.firstMatch(in: window, options: [], range: NSRange(location: 0, length: (window as NSString).length)) {
                let cs = m.range.location + m.range.length
                let ns = window as NSString
                if let cr = findMatchingCloseTag(html: ns, contentStart: cs, tagName: "textarea", lowerHTML: lowerHTML) {
                    let t = stripTags(ns.substring(with: cr))
                    if t.count >= 4 { return t }
                }
            }
            // 用深度计数器替代 [\s\S]*?</t[dh]>，避免灾难性回溯
            let tdTagPattern = #"(?i)<t[dh][^>]*>"#
            if let regex = try? NSRegularExpression(pattern: tdTagPattern) {
                let ns = window as NSString
                let matches = regex.matches(in: window, options: [], range: NSRange(location: 0, length: ns.length))
                for tm in matches.prefix(20) { // 限制检查前20个标签
                    let cs = tm.range.location + tm.range.length
                    // 判断是 td 还是 th
                    let tag = ns.substring(with: tm.range).lowercased()
                    let tagName = tag.hasPrefix("<th") ? "th" : "td"
                    if let cr = findMatchingCloseTag(html: ns, contentStart: cs, tagName: tagName, lowerHTML: lowerHTML) {
                        let t = stripTags(ns.substring(with: cr))
                        if t.count >= 10 && !t.contains("\t") { return t }
                    }
                }
            }
            let fallback = stripTags(window)
            return String(fallback.prefix(4000))
        }
        return String(stripTags(html).prefix(4000))
    }

    /// 取整段匹配（不是 group1，因为 NSRegularExpression 的 group 处理较啰嗦，这里取 group1）
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard let m = match, m.numberOfRanges >= 2 else { return nil }
        let g1 = m.range(at: 1)
        guard g1.location != NSNotFound else { return nil }
        return ns.substring(with: g1)
    }

    private static func allMatches(in text: String, pattern: String, groups: Int = 1) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            var arr: [String] = []
            for i in 1...groups {
                if i < m.numberOfRanges {
                    let r = m.range(at: i)
                    if r.location != NSNotFound {
                        arr.append(ns.substring(with: r))
                        continue
                    }
                }
                arr.append("")
            }
            return arr
        }
    }

    private static func cleanupValue(_ s: String) -> String {
        var v = s
        v = v.replacingOccurrences(of: "&nbsp;", with: " ")
        v = v.replacingOccurrences(of: "&amp;", with: "&")
        v = v.replacingOccurrences(of: "&lt;", with: "<")
        v = v.replacingOccurrences(of: "&gt;", with: ">")
        v = v.replacingOccurrences(of: "&quot;", with: "\"")
        v = v.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ s: String) -> String {
        // 脚本/样式剔除
        var v = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        // 替换 <br>/<p> 为换行
        v = v.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        v = v.replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
        v = v.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
        // 去除所有标签
        v = v.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // 常见实体
        v = v.replacingOccurrences(of: "&nbsp;", with: " ")
        v = v.replacingOccurrences(of: "&amp;", with: "&")
        v = v.replacingOccurrences(of: "&lt;", with: "<")
        v = v.replacingOccurrences(of: "&gt;", with: ">")
        v = v.replacingOccurrences(of: "&quot;", with: "\"")
        // 清掉连续空白
        v = v.replacingOccurrences(of: "[\\t\\r\\f\\v]+", with: " ", options: .regularExpression)
        v = v.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - REM

    private static func extractREMKeys(from text: String) -> [String] {
        let pattern = "REM-?\\d{3,}"
        var result: [String] = []
        var seen = Set<String>()
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            var key = ns.substring(with: m.range).uppercased()
            if !key.contains("-") {
                // REM1234 → REM-1234
                if let digits = key.range(of: "\\d+", options: .regularExpression) {
                    key = "REM-" + String(key[digits])
                }
            }
            if !seen.contains(key) {
                seen.insert(key)
                result.append(key)
            }
        }
        return result
    }

    /// 从流程审批意见区域（auditNote）提取 REM 号
    /// - Parameter lowerHTML: 预计算的小写 HTML（可选，为 nil 时自动计算）
    static func extractREMFromAuditNotes(html: String, lowerHTML: NSString? = nil) -> [String] {
        let lh = lowerHTML ?? (html.lowercased() as NSString)
        // 兰凌 EKP 审批意见可能在：<label class="auditNote">...</label> 或 <div id="auditHistory">...</div>
        var combinedHTML = html

        // 尝试提取轨迹记录区域（auditHistory）—— 用深度计数器避免灾难性回溯
        // 注意：属性内用 [^"']* 代替 .*? 避免回溯
        let historyTagPattern = #"(?i)<div[^>]*id=["'][^"']*auditHistory[^"']*['"][^>]*>"#
        if let historyRegex = try? NSRegularExpression(pattern: historyTagPattern) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = historyRegex.matches(in: html, options: [], range: range)
            for match in matches {
                let contentStart = match.range.location + match.range.length
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "div", lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        // 尝试提取其他常见轨迹容器（如 class="process-history"）
        print("[OAParser.extractREQ] historyPattern 完成, combinedHTML长度=\(combinedHTML.count)")
        let processTagPattern = #"(?i)<div[^>]*class=["'][^"']*process[-\s]?history[^"']*['"][^>]*>"#
        if let processRegex = try? NSRegularExpression(pattern: processTagPattern) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = processRegex.matches(in: html, options: [], range: range)
            for match in matches {
                let contentStart = match.range.location + match.range.length
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "div", lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        // 尝试提取更多轨迹容器
        print("[OAParser.extractREQ] processPattern 完成, combinedHTML长度=\(combinedHTML.count)")
        let containerTagPatterns = [
            (#"(?i)<div[^>]*class=["'][^"']*audit[-\s]?log[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*workflow[-\s]?history[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*approval[-\s]?list[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*trace[-\s]?record[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*process[-\s]?log[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*history[-\s]?list[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<section[^>]*id=["'][^"']*workflow[-\s]?history[^"']*["'][^>]*>"#, "section"),
            (#"(?i)<ul[^>]*class=["'][^"']*approval[-\s]?list[^"']*["'][^>]*>"#, "ul"),
        ]

        for (_, (tagPattern, tagName)) in containerTagPatterns.enumerated() {
            guard let tagRegex = try? NSRegularExpression(pattern: tagPattern) else { continue }
            let ns = html as NSString
            let tagRange = NSRange(location: 0, length: ns.length)
            let tagMatches = tagRegex.matches(in: html, options: [], range: tagRange)
            for tagMatch in tagMatches {
                let contentStart = tagMatch.range.location + tagMatch.range.length
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: tagName, lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        // 主正则：搜索所有 auditNote 标签
        // 注意：属性内用 [^"']* 代替 .*? 避免回溯；内容用 [\s\S]*? 匹配到 </label>
        let auditPattern = #"(?is)<label[^>]*class=["'][^"']*auditNote[^"']*['"][^>]*>([\s\S]*?)</label>"#
        guard let regex = try? NSRegularExpression(pattern: auditPattern) else { return [] }
        let ns = combinedHTML as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: combinedHTML, options: [], range: range)
    
        var result: [String] = []
        var seen = Set<String>()
        let remPattern = "REM-?\\d{3,}"
        guard let remRegex = try? NSRegularExpression(pattern: remPattern, options: .caseInsensitive) else { return [] }
    
        for match in matches {
            let auditContent = ns.substring(with: match.range(at: 1))
            let remMatches = remRegex.matches(in: auditContent, options: [], range: NSRange(location: 0, length: (auditContent as NSString).length))
            for m in remMatches {
                var key = (auditContent as NSString).substring(with: m.range).uppercased()
                if !key.contains("-") {
                    if let digits = key.range(of: "\\d+", options: .regularExpression) {
                        key = "REM-" + String(key[digits])
                    }
                }
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(key)
                }
            }
        }
            
        // 【兜底策略】如果 auditNote 提取失败，直接全文搜索 REM-XXXX
        if result.isEmpty {
            let fullTextRemPattern = "REM-?\\d{3,}"
            if let fullTextRemRegex = try? NSRegularExpression(pattern: fullTextRemPattern, options: .caseInsensitive) {
                let fullTextMatches = fullTextRemRegex.matches(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length))
                for m in fullTextMatches {
                    var key = (html as NSString).substring(with: m.range).uppercased()
                    if !key.contains("-") {
                        if let digits = key.range(of: "\\d+", options: .regularExpression) {
                            key = "REM-" + String(key[digits])
                        }
                    }
                    if !seen.contains(key) {
                        seen.insert(key)
                        result.append(key)
                    }
                }
            }
        }
            
        return result
    }

    // MARK: - 按操作人提取 REQ

    /// 从审批意见中提取指定操作人的 REQ 号
    /// - Parameters:
    ///   - html: 审批日志 HTML（来自 lbpmAuditNote.do 或主页面）
    ///   - operatorName: 操作人姓名（如"吴润龙"）
    /// - Returns: 去重后的 REQ 号列表（如 ["REQ-12345", "REQ-67890"]）

    /// 从 contentStart 开始，用标签深度计数器找到配对的闭合标签，返回内容区域的 NSRange
    /// - Parameter lowerHTML: 预计算的小写 HTML（避免每次调用都重新 lowercased 221K 字符串）
    private static func findMatchingCloseTag(html: NSString, contentStart: Int, tagName: String, lowerHTML: NSString) -> NSRange? {
        let openTag = "<\(tagName)"
        let closeTag = "</\(tagName)>"
        var depth = 1
        var pos = contentStart
        let len = html.length

        while pos < len && depth > 0 {
            let nextOpen = lowerHTML.range(of: openTag, options: [], range: NSRange(location: pos, length: len - pos)).location
            let nextClose = lowerHTML.range(of: closeTag, options: [], range: NSRange(location: pos, length: len - pos)).location

            if nextClose == NSNotFound { return nil }

            if nextOpen != NSNotFound && nextOpen < nextClose {
                // 确认是真正的开标签（后面跟空格或 > 而不是其他字母）
                let afterTag = nextOpen + openTag.count
                if afterTag < len {
                    let ch = lowerHTML.character(at: afterTag)
                    if ch == 32 || ch == 62 || ch == 9 || ch == 47 { // space, >, tab, /
                        depth += 1
                    }
                }
                pos = nextOpen + openTag.count
            } else {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: contentStart, length: nextClose - contentStart)
                }
                pos = nextClose + closeTag.count
            }
        }
        return nil
    }

    static func extractREQByOperator(html: String, operatorName: String) -> [String] {
        print("[OAParser.extractREQ] 开始, html长度=\(html.count), operatorName=\(operatorName)")
        let lh = html.lowercased() as NSString
        // 复用 extractREMFromAuditNotes 的容器收集策略
        var combinedHTML = html

        let historyTagPattern = #"(?i)<div[^>]*id=["'][^"']*auditHistory[^"']*['"][^>]*>"#
        if let historyRegex = try? NSRegularExpression(pattern: historyTagPattern) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = historyRegex.matches(in: html, options: [], range: range)
            for match in matches {
                let contentStart = match.range.location + match.range.length
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "div", lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        print("[OAParser.extractREQ] historyPattern 完成, combinedHTML长度=\(combinedHTML.count)")
        let processTagPattern = #"(?i)<div[^>]*class=["'][^"']*process[-\s]?history[^"']*['"][^>]*>"#
        if let processRegex = try? NSRegularExpression(pattern: processTagPattern) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = processRegex.matches(in: html, options: [], range: range)
            for match in matches {
                let contentStart = match.range.location + match.range.length
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: "div", lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        print("[OAParser.extractREQ] processPattern 完成, combinedHTML长度=\(combinedHTML.count)")

        // 使用标签名+属性正则只匹配开标签，然后用 div 深度计数器找闭合标签，避免 [\s\S]*?</div> 的灾难性回溯
        let containerTagPatterns = [
            (#"(?i)<div[^>]*class=["'][^"']*audit[-\s]?log[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*workflow[-\s]?history[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*approval[-\s]?list[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*trace[-\s]?record[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*process[-\s]?log[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<div[^>]*class=["'][^"']*history[-\s]?list[^"']*["'][^>]*>"#, "div"),
            (#"(?i)<section[^>]*id=["'][^"']*workflow[-\s]?history[^"']*["'][^>]*>"#, "section"),
            (#"(?i)<ul[^>]*class=["'][^"']*approval[-\s]?list[^"']*["'][^>]*>"#, "ul"),
        ]

        for (idx, (tagPattern, tagName)) in containerTagPatterns.enumerated() {
            guard let tagRegex = try? NSRegularExpression(pattern: tagPattern) else { continue }
            let ns = html as NSString
            let tagRange = NSRange(location: 0, length: ns.length)
            let tagMatches = tagRegex.matches(in: html, options: [], range: tagRange)
            print("[OAParser.extractREQ] container[\(idx)] <\(tagName)> 开标签匹配数=\(tagMatches.count)")
            for tagMatch in tagMatches {
                let contentStart = tagMatch.range.location + tagMatch.range.length
                // 用深度计数器找配对的闭合标签
                if let contentRange = findMatchingCloseTag(html: ns, contentStart: contentStart, tagName: tagName, lowerHTML: lh) {
                    combinedHTML += "\n" + ns.substring(with: contentRange)
                }
            }
        }

        print("[OAParser.extractREQ] containerPatterns 完成, combinedHTML总长度=\(combinedHTML.count)")
        debugLog("[OAParser.extractREQByOperator] combinedHTML length=\(combinedHTML.count), operatorName=\(operatorName)")

        let reqPattern = "REQ-\\d+"
        var result: [String] = []
        var seen = Set<String>()

        // ========== 策略 A（主）：表格行解析 ==========
        // 审批记录为 <table> 结构，每行 <tr> 包含 5 个 <td>：
        //   时间 | 节点名称 | 操作者 | 操作 | 处理意见
        // 操作者在第 3 列，处理意见在第 5 列
        let trPattern = #"(?is)<tr[^>]*>([\s\S]*?)</tr>"#
        let tdPattern = #"(?is)<td[^>]*>([\s\S]*?)</td>"#

        print("[OAParser.extractREQ] 策略A: 开始<tr>匹配, combinedHTML长度=\(combinedHTML.count)")
        if let trRegex = try? NSRegularExpression(pattern: trPattern) {
            let ns = combinedHTML as NSString
            let trMatches = trRegex.matches(in: combinedHTML, options: [], range: NSRange(location: 0, length: ns.length))
            print("[OAParser.extractREQ] 策略A: <tr>匹配完成, 行数=\(trMatches.count)")
            print("[OAParser.extractREQ] 策略A: <tr>行数=\(trMatches.count)")
            debugLog("[OAParser.extractREQByOperator] 策略A: 找到 <tr> 行数=\(trMatches.count)")

            if let tdRegex = try? NSRegularExpression(pattern: tdPattern),
               let reqRegex = try? NSRegularExpression(pattern: reqPattern, options: .caseInsensitive) {
                for trMatch in trMatches {
                    let rowHTML = ns.substring(with: trMatch.range(at: 1))
                    let tdMatches = tdRegex.matches(in: rowHTML, options: [], range: NSRange(location: 0, length: (rowHTML as NSString).length))
                    // 至少需要 5 列（时间、节点、操作者、操作、处理意见）
                    guard tdMatches.count >= 5 else { continue }

                    // 第 3 列 = 操作者（index=2）
                    let operatorText = stripTags(ns.substring(with: tdMatches[2].range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
                    // 第 5 列 = 处理意见（index=4）
                    let commentText = ns.substring(with: tdMatches[4].range(at: 1))

                    debugLog("[OAParser.extractREQByOperator] 策略A: 操作者列='\(operatorText)', 处理意见(前80字)='\(stripTags(commentText).prefix(80))'")

                    if operatorText.hasPrefix(operatorName) {
                        debugLog("[OAParser.extractREQByOperator] 策略A ✅ 操作人匹配: '\(operatorText)' startsWith '\(operatorName)'")
                        let reqMatches = reqRegex.matches(in: commentText, options: [], range: NSRange(location: 0, length: (commentText as NSString).length))
                        for m in reqMatches {
                            let req = (commentText as NSString).substring(with: m.range).uppercased()
                            if !seen.contains(req) {
                                seen.insert(req)
                                result.append(req)
                            }
                        }
                    }
                }
            }
        }

        if !result.isEmpty {
            debugLog("[OAParser.extractREQByOperator] 策略A 表格行提取完成，共 \(result.count) 个 REQ")
            return result
        }

        // ========== 策略 B（兜底）：auditNote 标签 + startsWith ==========
        print("[OAParser.extractREQ] 策略A 未匹配，启用策略B")
        debugLog("[OAParser.extractREQByOperator] 策略A 表格行未匹配到结果，启用策略B auditNote + startsWith")
        let auditPattern = #"(?is)<label[^>]*class=["'][^"']*auditNote[^"']*['"][^>]*>([\s\S]*?)</label>"#

        if let regex = try? NSRegularExpression(pattern: auditPattern) {
            let ns = combinedHTML as NSString
            let matches = regex.matches(in: combinedHTML, options: [], range: NSRange(location: 0, length: ns.length))
            print("[OAParser.extractREQ] 策略B: auditNote matches=\(matches.count)")
            debugLog("[OAParser.extractREQByOperator] 策略B: auditNote matches=\(matches.count)")

            for match in matches {
                let auditContent = ns.substring(with: match.range(at: 1))
                let windowStart = max(0, match.range.location - 2000)
                let windowLen = min(2000, match.range.location - windowStart)
                let window = ns.substring(with: NSRange(location: windowStart, length: windowLen))

                // 按行分割窗口，stripTags 后检查是否有行以 operatorName 开头
                var matched = false
                let lines = window.components(separatedBy: "\n")
                for line in lines {
                    let stripped = stripTags(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if stripped.hasPrefix(operatorName) {
                        matched = true
                        debugLog("[OAParser.extractREQByOperator] 策略B: 行 '\(stripped.prefix(50))' startsWith '\(operatorName)'")
                        break
                    }
                }

                if matched, let reqRegex = try? NSRegularExpression(pattern: reqPattern, options: .caseInsensitive) {
                    let reqMatches = reqRegex.matches(in: auditContent, options: [], range: NSRange(location: 0, length: (auditContent as NSString).length))
                    for m in reqMatches {
                        let req = (auditContent as NSString).substring(with: m.range).uppercased()
                        if !seen.contains(req) {
                            seen.insert(req)
                            result.append(req)
                        }
                    }
                }
            }
        }

        // ========== 策略 C（兜底）：全文纯文本 startsWith ==========
        if result.isEmpty {
            print("[OAParser.extractREQ] 策略B 未匹配，启用策略C")
            print("[OAParser.extractREQ] 策略B 未匹配，启用策略C")
            debugLog("[OAParser.extractREQByOperator] 策略B 未匹配，启用策略C 全文纯文本 startsWith")
            let plainText = stripTags(combinedHTML)
            let segments = plainText.components(separatedBy: "\n")
            for (i, segment) in segments.enumerated() {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix(operatorName) {
                    debugLog("[OAParser.extractREQByOperator] 策略C: 第\(i)行 startsWith '\(operatorName)': '\(trimmed.prefix(50))'")
                    let windowStart = max(0, i - 2)
                    let windowEnd = min(segments.count - 1, i + 2)
                    let window = segments[windowStart...windowEnd].joined(separator: "\n")
                    if let reqRegex = try? NSRegularExpression(pattern: reqPattern, options: .caseInsensitive) {
                        let reqMatches = reqRegex.matches(in: window, options: [], range: NSRange(location: 0, length: (window as NSString).length))
                        for m in reqMatches {
                            let req = (window as NSString).substring(with: m.range).uppercased()
                            if !seen.contains(req) {
                                seen.insert(req)
                                result.append(req)
                            }
                        }
                    }
                }
            }
        }

        debugLog("[OAParser.extractREQByOperator] 最终提取到 \(result.count) 个 REQ: \(result.joined(separator: ","))")
        return result
    }

    /// 从 HTML 中提取所有 REQ 编号（不限操作人），去重后返回
    static func extractAllREQ(html: String) -> [String] {
        let reqPattern = "REQ-\\d+"
        var result: [String] = []
        var seen = Set<String>()
        guard let reqRegex = try? NSRegularExpression(pattern: reqPattern, options: .caseInsensitive) else { return result }
        let ns = html as NSString
        let matches = reqRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let req = (ns.substring(with: m.range)).uppercased()
            if !seen.contains(req) {
                seen.insert(req)
                result.append(req)
            }
        }
        return result
    }

    // MARK: - 附件

    /// 兰凌 EKP 附件提取策略：
    /// 1. 解析 JS `addDoc("unicode文件名", "fdId", ...)` 调用（最可靠）
    /// 2. 从 DOM `<div id="fdId" class="upload_list_tr_view">...<span class="upload_list_filename_title">` 提取
    /// 3. 回退到 `<a href="...attachment...">` 链接匹配
    /// 公开入口：仅解析附件（用于审批日志等二次解析场景）
    static func parseAttachments(html: String, baseURL: String) -> [OAAttachment] {
        return extractAttachments(html: html, baseURL: baseURL)
    }

    /// 下载 URL：{baseURL}/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId={fdId}&isSupportDirect=null&downloadType=manual&downloadFlag={timestamp}
    /// prefix 从 `Swf_AttachmentObject("fd_PREFIX_fdModelId", ...)` 提取（14 位 hex）
    private static func extractAttachments(html: String, baseURL: String) -> [OAAttachment] {
        var result: [OAAttachment] = []
        var seen = Set<String>()
        let ns = html as NSString
    
        // 前置：提取所有 Swf_AttachmentObject 的 modelName，建立 modelId -> modelName 映射
        var modelMap: [String: String] = [:]
        let modelPattern = #"Swf_AttachmentObject\("(?:fd_[a-f0-9]{14}|[a-f0-9]{32})_([a-f0-9]{32})","([^"]+)","([a-f0-9]{32})"#;
        if let mr = try? NSRegularExpression(pattern: modelPattern, options: [.caseInsensitive]) {
            let mm = mr.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            for m in mm {
                if m.numberOfRanges >= 4 {
                    let mId = ns.substring(with: m.range(at: 1))
                    let mName = ns.substring(with: m.range(at: 2))
                    modelMap[mId] = mName
                }
            }
        }
        debugLog("[OAParser] modelMap=\(modelMap)")
            
        // 方式 A（主）：直接从 `attachmentObject_...addDoc(...)` 提取
        // 支持两种格式：
        //   主页面：attachmentObject_fd_<14hex>_<32hex>.addDoc(...)
        //   审批意见：attachmentObject_<32hex>_<32hex>.addDoc(...)
        // addDoc(fileName, fdId, true, mime, size, fdFileId, downloadCount)
        let boundPattern = #"attachmentObject_(?:fd_([a-f0-9]{14})|([a-f0-9]{32}))_([a-f0-9]{32})\.addDoc\(\s*"([^"]+)"\s*,\s*"([a-f0-9]{32})"\s*,\s*(?:true|false)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([a-f0-9]{32})"#;
        if html.contains("addDoc") {
        if let regex = try? NSRegularExpression(pattern: boundPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            debugLog("[OAParser] attachments: bound addDoc matches=\(matches.count)")
            for (idx, match) in matches.enumerated() {
                if match.numberOfRanges >= 9 {
                    let r1 = match.range(at: 1)
                    let r2 = match.range(at: 2)
                    let prefix14 = r1.location != NSNotFound ? ns.substring(with: r1) : ""
                    let prefix32 = r2.location != NSNotFound ? ns.substring(with: r2) : ""
                    let prefix = prefix14.isEmpty ? prefix32 : "fd_" + prefix14
                    let modelId = ns.substring(with: match.range(at: 3))
                    let rawName = ns.substring(with: match.range(at: 4))
                    let fdId = ns.substring(with: match.range(at: 5))
                    let fdFileId = ns.substring(with: match.range(at: 8))
                    let name = decodeUnicodeEscapes(rawName)
                    let key = prefix + "_" + fdId
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    let modelName = modelMap[modelId] ?? ""
                    let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                    let url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(timestamp)"
                    debugLog("[OAParser] 附件: \(name) prefix=\(prefix) modelId=\(modelId) fdId=\(fdId) fdFileId=\(fdFileId) url=\(url)")
                    var att = OAAttachment(name: name.isEmpty ? fdId : name, url: url)
                    att.prefix = prefix
                    att.fdId = fdId
                    att.fdFileId = fdFileId
                    att.modelName = modelName
                    att.modelId = modelId
                    if prefix == "fd_36d9d9ef7503d8" {
                        att.isTemplateAttachment = true
                    }
                    result.append(att)
                }
            }
        }
    
        } // end if html.contains("addDoc")
        // 方式 B：如果方式 A 没匹配到，尝试宽松 addDoc 提取 + 全局 prefix
        if result.isEmpty {
            // 先提取第一个 Swf_AttachmentObject 的 14 位 prefix
            var globalPrefix = ""
            let prefixPattern = #"Swf_AttachmentObject\(\s*"fd_([a-f0-9]{14})_"#
            if let pr = try? NSRegularExpression(pattern: prefixPattern, options: [.caseInsensitive]),
               let pm = pr.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
               pm.numberOfRanges >= 2 {
                globalPrefix = ns.substring(with: pm.range(at: 1))
                debugLog("[OAParser] globalPrefix = '\(globalPrefix)'")
            }
            // 宽松 addDoc 提取
            let loosePattern = #"addDoc\(\s*"([^"]+)"\s*,\s*"([a-f0-9]{32})"\s*,\s*(?:true|false)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([a-f0-9]{32})""#
            if html.contains("addDoc"), let regex = try? NSRegularExpression(pattern: loosePattern, options: [.caseInsensitive]) {
                let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
                debugLog("[OAParser] attachments: loose addDoc matches=\(matches.count)")
                for match in matches {
                    if match.numberOfRanges >= 6 {
                        let rawName = ns.substring(with: match.range(at: 1))
                        let fdId = ns.substring(with: match.range(at: 2))
                        let fdFileId = ns.substring(with: match.range(at: 5))
                        let name = decodeUnicodeEscapes(rawName)
                        if seen.contains(fdId) { continue }
                        seen.insert(fdId)
                        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                        let url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(timestamp)"
                        debugLog("[OAParser] 附件: \(name) fdId=\(fdId) fdFileId=\(fdFileId) url=\(url)")
                        result.append(OAAttachment(name: name.isEmpty ? fdId : name, url: url))
                    }
                }
            }
            // 再退化：只取 fileName + fdId
            if result.isEmpty {
                let fallbackPattern = #"addDoc\(\s*"([^"]+)"\s*,\s*"([a-f0-9]{32})""#
                if html.contains("addDoc"), let regex2 = try? NSRegularExpression(pattern: fallbackPattern, options: [.caseInsensitive]) {
                    let matches2 = regex2.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
                    debugLog("[OAParser] attachments: fallback addDoc matches=\(matches2.count)")
                    for match in matches2 {
                        if match.numberOfRanges >= 3 {
                            let rawName = ns.substring(with: match.range(at: 1))
                            let fdId = ns.substring(with: match.range(at: 2))
                            let name = decodeUnicodeEscapes(rawName)
                            if seen.contains(fdId) { continue }
                            seen.insert(fdId)
                            let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                            let url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(timestamp)"
                            result.append(OAAttachment(name: name.isEmpty ? fdId : name, url: url))
                        }
                    }
                }
            }
        }
        // 方式 C：从 DOM 补充提取（如果 JS addDoc 完全没匹配到）
        if result.isEmpty {
            let blockPattern = #"(?i)<div\s+id="([a-f0-9]{32})"[^>]*upload_list_tr_view[^>]*>"#
            let domMatches = allMatches(in: html, pattern: blockPattern, groups: 3)
            debugLog("[OAParser] attachments: DOM matches=\(domMatches.count)")
            for m in domMatches {
                let fdId = m[0]
                let nameTitle = stripTags(m[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let nameExt = m.count > 2 ? stripTags(m[2]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if fdId.isEmpty || seen.contains(fdId) { continue }
                seen.insert(fdId)
                let fullName = nameTitle + nameExt
                let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                let url = baseURL + "/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(timestamp)"
                result.append(OAAttachment(name: fullName.isEmpty ? fdId : fullName, url: url))
            }
        }
        // 方式 D：回退到 <a href=...> 链接
        if result.isEmpty {
            result = extractAttachmentsLegacy(html: html, baseURL: baseURL)
            debugLog("[OAParser] attachments: legacy fallback count=\(result.count)")
        }

        return result
    }

    /// 将 \uXXXX 转义序列解码为实际字符（兰凌 EKP 的 JS addDoc 参数全是 Unicode 转义）
    private static func decodeUnicodeEscapes(_ s: String) -> String {
        let pattern = #"\\u([0-9a-fA-F]{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let result = NSMutableString(string: s)
        // 从后往前替换，避免位置偏移
        let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
        for match in matches.reversed() {
            let hexRange = match.range(at: 1)
            let hex = (s as NSString).substring(with: hexRange)
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                let replacement = String(Character(scalar))
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return result as String
    }

    private static func extractAttachmentsLegacy(html: String, baseURL: String) -> [OAAttachment] {
        let pattern = "<a[^>]*href=\"([^\"]*(?:attachment|fileDownload|file_download|sysFileService|Lui/sys_attachment|/sys/attachment|downLoad|download)[^\"]*)\"[^>]*>([\\s\\S]*?)</a>"
        var result: [OAAttachment] = []
        var seen = Set<String>()
        for m in allMatches(in: html, pattern: pattern, groups: 2) {
            let rawHref = m[0]
            let rawName = stripTags(m[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawHref.isEmpty { continue }
            let href = decodeHTMLEntities(rawHref)
            if href.lowercased().hasPrefix("javascript:") { continue }
            let absURL = resolveURL(href: href, base: baseURL)
            if seen.contains(absURL) { continue }
            seen.insert(absURL)
            let name = rawName.isEmpty ? (URL(string: absURL)?.lastPathComponent ?? "attachment") : rawName
            result.append(OAAttachment(name: name, url: absURL))
        }
        return result
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func resolveURL(href: String, base: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        guard let baseURL = URL(string: base) else { return href }
        if let u = URL(string: href, relativeTo: baseURL) { return u.absoluteString }
        return href
    }
}
