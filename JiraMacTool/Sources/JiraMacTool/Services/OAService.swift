import Foundation

actor OAService {
    static let shared = OAService()

    let session: URLSession
    /// 以 name=value 形式存的 cookie（简化处理，不区分 domain/path）
    var cookies: [String: String] = [:]
    /// 已登录成功的 baseURL（scheme://host）
    var loggedInBaseURL: String?
    /// 登录所用账号，用户名变更时需重新登录
    var loggedInUser: String?

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: OARedirectBlocker(), delegateQueue: nil)
    }

    // MARK: - Public

    /// 确保指定 baseURL 已登录；如果已登录过相同 baseURL 且账号未变则跳过
    /// - Parameters:
    ///   - baseURL: OA 站点 base URL
    ///   - verifyURL: 可选，用于验证登录是否成功的 URL（通常传入用户实际要访问的业务页，避免 "/" 被误判为登录成功）
    func ensureLogin(baseURL: String, verifyURL: String? = nil) async throws {
        let user = AppConfig.shared.jiraUser
        if loggedInBaseURL == baseURL, loggedInUser == user, !cookies.isEmpty {
            return
        }
        try await doLogin(baseURL: baseURL, verifyURL: verifyURL)
    }

    /// 抓取指定链接的 HTML；如未登录则自动登录；401/会话失效自动重登一次
    func fetchHTML(urlString: String, retried: Bool = false) async throws -> String {
        guard let url = URL(string: urlString) else { throw OAError.invalidURL }
        let base = extractBaseURL(from: url)
        try await ensureLogin(baseURL: base, verifyURL: urlString)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        attachCookie(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAError.invalidResponse }
        absorbSetCookies(from: http, responseURL: url)

        debugLog("[OAService] fetchHTML status=\(http.statusCode) url=\(urlString.prefix(120)) cookies=\(cookies.keys.sorted().joined(separator: ","))")

        // 3xx 且 Location 指向登录页，视为会话失效
        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            debugLog("[OAService] fetchHTML 302 loc=\(location)")
            if looksLikeLoginRedirect(location: location) {
                if retried { throw OAError.loginFailed("会话失效，再次登录仍被重定向到 \(location)") }
                clearSession()
                return try await fetchHTML(urlString: urlString, retried: true)
            }
            // 非登录跳转：跟随一次
            let next = absoluteURL(location: location, base: url)
            return try await fetchHTML(urlString: next, retried: retried)
        }

        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw OAError.httpError(http.statusCode, String(msg.prefix(200)))
        }

        let html = decodeHTML(data: data, response: http)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "-"
        // 空响应体/极短响应（<32 非空白字符）不做登录页误判，直接原样返回给上层
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHTML.count < 32 {
            debugLog("[OAService] fetchHTML 短响应 bodySize=\(data.count) trimmed=\(trimmedHTML.count) ct=\(contentType) cl=\(contentLength)；不按登录页处理，原样返回")
            return html
        }

        let loginPageReason = loginPageDetectReason(html: html)
        if let reason = loginPageReason {
            let snippet = compactSnippet(html, limit: 500)
            debugLog("[OAService] fetchHTML 被判为登录页 reason=\(reason) bodySize=\(data.count) ct=\(contentType) HTML前500字(压缩): \(snippet)")
            if retried {
                let tail = compactSnippet(html, limit: 300)
                throw OAError.loginFailed("会话失效，再次登录仍落到登录页(\(reason))。bodySize=\(data.count) ct=\(contentType) HTML(压缩)前300字: \(tail)")
            }
            clearSession()
            return try await fetchHTML(urlString: urlString, retried: true)
        }
        return html
    }

    /// 把 HTML 压缩成单行可读摘要：去掉脚本/样式 + 合并连续空白 + 截断
    func compactSnippet(_ html: String, limit: Int) -> String {
        var s = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)) + "..." }
        return s
    }

    /// 判断 HTML 是否为登录页；是则返回命中原因（便于排查），否则返回 nil。
    /// 对空或过短响应一律返回 nil（空页面不等于登录页）。
    func loginPageDetectReason(html: String) -> String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 32 { return nil }
        let lower = html.lowercased()

        // 强特征：登录表单常见字段/ID/类名，命中 2 个以上才算
        let strongTokens = ["j_username", "j_password", "name=\"loginname\"", "id=\"loginname\"",
                            "name=\"password\"", "id=\"password\"", "loginform", "login-form", "login_form"]
        var strongHits: [String] = []
        for t in strongTokens where lower.contains(t.lowercased()) { strongHits.append(t) }
        if strongHits.count >= 2 { return "strongTokens=[\(strongHits.joined(separator: ","))]" }

        // 中文登录提示 + password 输入框
        let softZh = ["用户登录", "请登录", "登录系统", "账号登录", "用户名或密码", "账号或密码"]
        if let z = softZh.first(where: { html.contains($0) }), lower.contains("type=\"password\"") {
            return "zhLoginHint=\(z)+passwordInput"
        }

        // JS 跳登录页：需要出现具体的登录路径（login.jsp / anonym.jsp / signin），
        // 避免 "window.location" + "login" 这种宽泛匹配把业务页面误判成登录页
        if lower.contains("location.href") && (lower.contains("login.jsp") || lower.contains("anonym.jsp") || lower.contains("/sys/login/")) {
            return "jsRedirectLoginJsp"
        }

        return nil
    }

    /// 下载附件；同样支持 401 自动重登
    func downloadAttachment(urlString: String, retried: Bool = false) async throws -> OADownloadedAttachment {
        guard let url = URL(string: urlString) else { throw OAError.invalidURL }
        let base = extractBaseURL(from: url)
        try await ensureLogin(baseURL: base)

        debugLog("[OAService] 下载附件，主 URL: \(urlString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        // 添加 Referer，很多 OA 系统要求来源页面
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        attachCookie(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAError.invalidResponse }
        absorbSetCookies(from: http)
        debugLog("[OAService] 主 URL 响应: status=\(http.statusCode), size=\(data.count)B, content-type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?")")

        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            debugLog("[OAService] 重定向到: \(location)")
            if looksLikeLoginRedirect(location: location) {
                if retried { throw OAError.loginFailed("附件下载时会话失效") }
                clearSession()
                return try await downloadAttachment(urlString: urlString, retried: true)
            }
            let next = absoluteURL(location: location, base: url)
            return try await downloadAttachment(urlString: next, retried: retried)
        }

        // 404/400 自动尝试兰凌 EKP 常见备用下载路径
        if http.statusCode == 404 || http.statusCode == 400 {
            // 打印 404 响应 body 前 500 字节，帮助定位
            let body404 = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            debugLog("[OAService] 主 URL 404/400 响应 body(前500字节):\n\(body404)")
            // 从原始 URL 中提取所有 hex ID（attachmentKey 14 位，fdId/fdFileId 32 位）
            let ids = extractAllHexIdsFromURL(urlString)
            // 14 位左右是 attachmentKey（SWF 动态 key），32 位是 fdId/fdFileId
            let shortKey = ids.first(where: { $0.count >= 8 && $0.count < 20 }) ?? ""
            let longIds = ids.filter { $0.count >= 20 }
            let fdId = longIds.first ?? ""
            let fdFileId = longIds.count > 1 ? longIds[1] : fdId
            var candidates: [String] = []
            // 优先尝试 swf_attachment.do 的各种变体（用户实测这是正确端点）
            if !shortKey.isEmpty {
                candidates.append(contentsOf: [
                    base + "/sys/attachment/swf_attachment.do?method=download&fdId=\(shortKey)",
                    base + "/sys/attachment/swf_attachment.do?method=download&fdId=\(shortKey)&fdAttId=\(fdId)",
                    base + "/sys/attachment/swf_attachment.do?method=view&fdId=\(shortKey)",
                    base + "/sys/attachment/swf_attachment.do?method=read&fdId=\(shortKey)"
                ])
            }
            if !fdId.isEmpty {
                candidates.append(contentsOf: [
                    base + "/sys/attachment/swf_attachment.do?method=download&fdId=\(fdId)",
                    base + "/sys/attachment/sys_att_main/\(fdId).do?method=download",
                    base + "/sys/attachment/sys_att_main/\(fdId).do?method=read",
                    base + "/sys/attachment/download.do?fdId=\(fdId)",
                    base + "/sys/common/downloadFile.do?fdId=\(fdId)",
                    base + "/sys/attachment/fileService.do?method=download&fdId=\(fdId)"
                ])
            }
            if !fdFileId.isEmpty && fdFileId != fdId {
                candidates.append(contentsOf: [
                    base + "/sys/attachment/swf_attachment.do?method=download&fdId=\(fdFileId)",
                    base + "/sys/attachment/sys_att_main/\(fdFileId).do?method=download"
                ])
            }
            for candidate in candidates where candidate != urlString {
                debugLog("[OAService] 尝试备用路径: \(candidate)")
                if let result = try? await downloadAttachmentRaw(urlString: candidate, referer: base + "/") {
                    debugLog("[OAService] ✅ 备用路径成功: \(candidate)")
                    return result
                }
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw OAError.httpError(http.statusCode, String(msg.prefix(200)))
        }

        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw OAError.httpError(http.statusCode, String(msg.prefix(200)))
        }

        let fileName = extractFileName(from: http, fallbackURL: url)
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return OADownloadedAttachment(name: fileName, data: data, mimeType: mime)
    }

    /// 从 URL 中提取所有 16+ 位十六进制 ID（通常第一个是 fdId，第二个是 fdFileId）
    func extractAllHexIdsFromURL(_ urlString: String) -> [String] {
        let pattern = #"([a-f0-9]{16,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = urlString as NSString
        let matches = regex.matches(in: urlString, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m -> String? in
            guard m.numberOfRanges >= 2 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    /// 从 URL 中提取 fdId（16+ 位十六进制）
    func extractFdIdFromURL(_ urlString: String) -> String? {
        let pattern = #"([a-f0-9]{16,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = urlString as NSString
        if let match = regex.firstMatch(in: urlString, options: [], range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges >= 2 {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    /// 底层下载（不带 fallback），用于备用路径尝试；返回原始结果供诊断使用
    func downloadAttachmentRaw(urlString: String, referer: String? = nil) async throws -> OADownloadedAttachment {
        let (data, http, fileName) = try await probeURL(urlString: urlString, referer: referer)
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw OAError.httpError(http.statusCode, String(msg.prefix(200)))
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        if mime.lowercased().contains("text/html") {
            throw OAError.httpError(400, "返回 HTML 而非文件")
        }
        return OADownloadedAttachment(name: fileName, data: data, mimeType: mime)
    }

    /// 探测 URL，返回原始数据、HTTP 响应、文件名（供诊断使用）
    func probeURL(urlString: String, referer: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse, String) {
        guard let url = URL(string: urlString) else { throw OAError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        if let referer = referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        attachCookie(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAError.invalidResponse }
        absorbSetCookies(from: http)
        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            if looksLikeLoginRedirect(location: location) { throw OAError.loginFailed("会话失效") }
            let next = absoluteURL(location: location, base: url)
            return try await probeURL(urlString: next, referer: referer, method: method)
        }
        let fileName = extractFileName(from: http, fallbackURL: url)
        return (data, http, fileName)
    }

    /// 诊断下载：当正常下载失败后，暴力尝试所有可能的 URL 组合并保存报告
    /// - Parameters:
    ///   - attachment: 附件信息
    ///   - baseURL: OA 站点 base URL
    ///   - referer: 完整的 OA 页面 URL（用作 Referer 头，模拟 Flash 组件行为）
    func diagnoseDownload(attachment: OAAttachment, baseURL: String, referer: String? = nil) async {
        let ts = ISO8601DateFormatter().string(from: Date())
        let reportName = "oa_download_diagnosis_\(ts).txt"
        let reportDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JiraMacTool")
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let reportPath = reportDir.appendingPathComponent(reportName)

        var lines: [String] = []
        lines.append("=== OA 附件下载诊断报告 ===")
        lines.append("时间: \(ts)")
        lines.append("附件名: \(attachment.name)")
        lines.append("prefix: \(attachment.prefix)")
        lines.append("fdId: \(attachment.fdId)")
        lines.append("fdFileId: \(attachment.fdFileId)")
        lines.append("modelName: \(attachment.modelName)")
        lines.append("modelId: \(attachment.modelId)")
        lines.append("")

        let prefix = attachment.prefix
        let fdId = attachment.fdId
        let fdFileId = attachment.fdFileId
        let modelName = attachment.modelName
        let modelId = attachment.modelId

        // 构造所有可能的 URL 组合
        var candidates: [(String, String)] = []  // (label, url)

        // 组 1：基于 fdAttId（32 位，addDoc 第二个参数）的真实下载端点（用户提供）
        // /sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId={fdId}&isSupportDirect=null&downloadType=manual&downloadFlag={timestamp}
        if !fdId.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            candidates.append(("sysAttMain.do fdId", "\(baseURL)/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(ts)"))
            candidates.append(("sysAttMain.do fdFileId", "\(baseURL)/sys/attachment/sys_att_main/sysAttMain.do?method=download&fdId=\(fdFileId)&isSupportDirect=null&downloadType=manual&downloadFlag=\(ts)"))
            candidates.append(("sys_att_main download", "\(baseURL)/sys/attachment/sys_att_main/\(fdId).do?method=download"))
            candidates.append(("sys_att_main read", "\(baseURL)/sys/attachment/sys_att_main/\(fdId).do?method=read"))
            candidates.append(("download.do fdAttId", "\(baseURL)/sys/attachment/download.do?fdId=\(fdId)"))
            candidates.append(("common downloadFile", "\(baseURL)/sys/common/downloadFile.do?fdId=\(fdId)"))
            candidates.append(("fileService", "\(baseURL)/sys/attachment/fileService.do?method=download&fdId=\(fdId)"))
        }

        // 组 2：swf_attachment.do 变体
        if !prefix.isEmpty {
            candidates.append(("swf prefix", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)"))
            candidates.append(("swf prefix+model", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdModelName=\(urlEncode(modelName))&fdModelId=\(modelId)"))
            candidates.append(("swf prefix+fdAttId", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdAttId=\(fdId)"))
            candidates.append(("swf prefix+fdFileId", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdFileId=\(fdFileId)"))
            candidates.append(("swf prefix+all", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdAttId=\(fdId)&fdFileId=\(fdFileId)"))
            candidates.append(("swf prefix read", "\(baseURL)/sys/attachment/swf_attachment.do?method=read&fdId=\(prefix)"))
            candidates.append(("swf prefix view", "\(baseURL)/sys/attachment/swf_attachment.do?method=view&fdId=\(prefix)"))
            candidates.append(("swf prefix+fdKey", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdKey=fd_\(prefix)_\(modelId)"))
        }

        // 组 3：基于完整 key（fd_prefix_modelId）的变体
        if !prefix.isEmpty && !modelId.isEmpty {
            let fullKey = "fd_\(prefix)_\(modelId)"
            let fullKeyNoFd = "\(prefix)_\(modelId)"
            candidates.append(("swf fullKey", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fullKey)"))
            candidates.append(("swf fullKeyNoFd", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fullKeyNoFd)"))
            candidates.append(("swf fullKey+fdKey", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix)&fdKey=\(fullKey)"))
        }

        // 组 4：基于 fdFileId 的 swf_attachment.do 变体
        if !fdFileId.isEmpty && fdFileId != fdId {
            candidates.append(("swf fdFileId", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fdFileId)"))
            candidates.append(("swf fdFileId+model", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fdFileId)&fdModelName=\(urlEncode(modelName))&fdModelId=\(modelId)"))
        }

        // 组 5：基于 fdId（32 位）的 swf_attachment.do 变体
        if !fdId.isEmpty {
            candidates.append(("swf fdId", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fdId)"))
            candidates.append(("swf fdId+model", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fdId)&fdModelName=\(urlEncode(modelName))&fdModelId=\(modelId)"))
            candidates.append(("swf fdId+fdFileId", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(fdId)&fdFileId=\(fdFileId)"))
        }

        // 组 6：其他可能的端点
        if !fdId.isEmpty {
            candidates.append(("sys/attach/read.jsp", "\(baseURL)/sys/attach/read.jsp?fdId=\(fdId)"))
            candidates.append(("sys/attach/download.jsp", "\(baseURL)/sys/attach/download.jsp?fdId=\(fdId)"))
            candidates.append(("sys/attachment/read.do", "\(baseURL)/sys/attachment/read.do?fdId=\(fdId)"))
            candidates.append(("sys/common/viewFile", "\(baseURL)/sys/common/viewFile.do?fdId=\(fdId)"))
            candidates.append(("km/review/attach", "\(baseURL)/km/review/km_review_attach.do?method=download&fdId=\(fdId)"))
        }

        // 组 7：POST 请求尝试
        if !fdId.isEmpty {
            candidates.append(("POST sys_att_main", "\(baseURL)/sys/attachment/sys_att_main/\(fdId).do?method=download [POST]"))
            candidates.append(("POST swf_attachment", "\(baseURL)/sys/attachment/swf_attachment.do?method=download&fdId=\(prefix) [POST]"))
        }

        lines.append("共尝试 \(candidates.count) 个 URL:")
        lines.append("")

        for (label, urlStr) in candidates {
            lines.append("--- \(label) ---")

            // 检查是否为 POST 请求标记
            let isPOST = urlStr.hasSuffix(" [POST]")
            let actualURL = isPOST ? String(urlStr.dropLast(7)) : urlStr
            lines.append("URL: \(actualURL)")
            lines.append("method: \(isPOST ? "POST" : "GET")")

            do {
                let method = isPOST ? "POST" : "GET"
                // 使用完整的 OA 页面 URL 作为 Referer（模拟 Flash 组件行为）
                let diagReferer = referer ?? (baseURL + "/")
                let (data, http, fileName) = try await probeURL(urlString: actualURL, referer: diagReferer, method: method)
                let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                lines.append("status: \(http.statusCode)")
                lines.append("content-type: \(ct)")
                lines.append("size: \(data.count)B")
                lines.append("fileName: \(fileName)")
                if ct.lowercased().contains("text/html") {
                    let body = String(data: data.prefix(800), encoding: .utf8) ?? "<binary>"
                    lines.append("body(前800): \(body)")
                } else if data.count > 0 && data.count < 10000 {
                    // 小文件可能是 JSON 错误信息
                    let body = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                    if !body.isEmpty && body.count < 500 {
                        lines.append("body: \(body)")
                    }
                }
                if http.statusCode == 200 && !ct.lowercased().contains("text/html") && data.count > 100 {
                    lines.append("⚠️ 可能成功！")
                }
            } catch {
                lines.append("error: \(error.localizedDescription)")
            }
            lines.append("")
        }

        // 额外诊断：尝试获取 swf_attachment.js 源码分析下载逻辑
        lines.append("=== swf_attachment.js 分析 ===")
        let jsURL = "\(baseURL)/sys/attachment/js/swf_attachment.js"
        lines.append("URL: \(jsURL)")
        do {
            let (data, http, _) = try await probeURL(urlString: jsURL, referer: baseURL + "/")
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
            lines.append("status: \(http.statusCode)")
            lines.append("content-type: \(ct)")
            if http.statusCode == 200 {
                let js = String(data: data, encoding: .utf8) ?? ""
                // 搜索 download 相关代码
                let downloadLines = js.split(separator: "\n").filter { line in
                    let lower = line.lowercased()
                    return lower.contains("download") || lower.contains("swf_attach") || lower.contains("fdid") || lower.contains("fdkey")
                }
                lines.append("JS 中含 download/fdId 的代码行（最多 30 行）:")
                for line in downloadLines.prefix(30) {
                    lines.append("  \(line)")
                }
            } else {
                lines.append("无法获取 JS 文件")
            }
        } catch {
            lines.append("error: \(error.localizedDescription)")
        }

        let report = lines.joined(separator: "\n")
        try? report.write(to: reportPath, atomically: true, encoding: .utf8)
        debugLog("[OAService] 诊断报告已保存: \(reportPath.path)")
    }


    /// 模拟浏览器 User-Agent
    let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15 JiraMacTool/1.0"

    /// GB18030 编码（用于解析部分 OA 页面）
    let gbkEncoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }()
}
