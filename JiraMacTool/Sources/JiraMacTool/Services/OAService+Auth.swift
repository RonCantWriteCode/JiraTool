import Foundation

// MARK: - OAService 登录 / 会话 / 表单解析

extension OAService {

    func logout() {
        clearSession()
    }

    // MARK: - Login attempts

    func doLogin(baseURL: String, verifyURL: String? = nil) async throws {
        let cfg = AppConfig.shared
        let user = cfg.jiraUser
        let password = cfg.jiraPassword
        guard !user.isEmpty, !password.isEmpty else {
            throw OAError.loginFailed("未配置 Jira 账号/密码（OA 共用域账号）")
        }
        // 打印实际使用的账号密码（密码脱敏）供排查
        let maskedPassword = password.prefix(1) + String(repeating: "*", count: max(0, password.count - 1))
        debugLog("[OAService] 登录凭据: user=\(user) password=\(maskedPassword) (len=\(password.count))")
        // 先清理旧 cookie
        clearSession()

        var diagnostics: [String] = []
        // 先 GET 登录页，获取初始 JSESSIONID 并尝试解析出真实的 form action / 字段名
        let discovered = try? await discoverLoginForm(baseURL: baseURL)
        if let d = discovered {
            diagnostics.append("  [解析到登录表单] action=\(d.action) userField=\(d.userField) passField=\(d.passField) hidden=\(d.hiddenFields.map{$0.0}.joined(separator: ","))")
        } else {
            diagnostics.append("  [解析登录表单失败] 回退枚举探测")
        }

        // 尝试列表：优先用解析出的真实 form，再回退到枚举组合
        var attempts: [LoginAttempt] = []
        if let d = discovered {
            attempts.append(LoginAttempt(path: d.action, userField: d.userField, passField: d.passField, extraFields: d.hiddenFields))
        }
        attempts.append(contentsOf: enumeratedAttempts())

        for attempt in attempts {
            let savedCookies = cookies
            do {
                let result = try await postLogin(baseURL: baseURL, attempt: attempt, user: user, password: password)
                diagnostics.append("  [\(attempt.path) | \(attempt.userField)] status=\(result.statusCode) loc=\(result.location) cookies=\(cookies.keys.sorted().joined(separator: ",")) bodyHead=\(result.bodySnippet)")

                // 快速跳过已知失败模式：302 到 anonym.jsp / login.jsp = 未认证
                if (300..<400).contains(result.statusCode) && looksLikeLoginRedirect(location: result.location) {
                    cookies = savedCookies
                    continue
                }

                // 明确成功信号：POST 后 302 跳到非登录页（如 "/" / 桌面页 / 业务页），Acegi 成功标志
                if (300..<400).contains(result.statusCode) && !result.location.isEmpty {
                    // 关键：跟进 302 的 GET 请求，确保 session 完全建立（Acegi session fixation protection）
                    await followRedirect(baseURL: baseURL, location: result.location)
                    self.loggedInBaseURL = baseURL
                    self.loggedInUser = user
                    debugLog("[OAService] 登录成功 via \(attempt.path)（302跳非登录页），loc=\(result.location) cookies=\(cookies.keys.sorted().joined(separator: ","))")
                    diagnostics.append("  → 认定登录成功（302 跳非登录页）")
                    return
                }

                // 没有明确 302 信号，用目标页或 / 兼底校验
                if try await verifyLogin(baseURL: baseURL, verifyURL: verifyURL) {
                    self.loggedInBaseURL = baseURL
                    self.loggedInUser = user
                    debugLog("[OAService] 登录成功 via \(attempt.path)，cookie 数量=\(cookies.count)")
                    return
                }
                cookies = savedCookies
            } catch {
                diagnostics.append("  [\(attempt.path) | \(attempt.userField)] 异常: \(error.localizedDescription)")
                cookies = savedCookies
            }
        }

        let tail = diagnostics.joined(separator: "\n")
        throw OAError.loginFailed("全部登录入口尝试失败。诊断明细：\n\(tail)")
    }

    /// 枚举常见的 EKP / 泛微 / Tomcat 登录入口组合
    func enumeratedAttempts() -> [LoginAttempt] {
        return [
            // 兰凌 EKP 新版（userName/password）
            LoginAttempt(path: "/sys/login/login.do?method=login", userField: "userName", passField: "password"),
            LoginAttempt(path: "/sys/login/login.do", userField: "userName", passField: "password"),
            LoginAttempt(path: "/sys/login/login.do?flag=login", userField: "userName", passField: "password"),
            // 兰凌 EKP 旧版（loginName/password）
            LoginAttempt(path: "/sys/login/login.do?method=login", userField: "loginName", passField: "password"),
            LoginAttempt(path: "/sys/login/login.do", userField: "loginName", passField: "password"),
            LoginAttempt(path: "/sys/login/checkLogin.do", userField: "loginName", passField: "password"),
            LoginAttempt(path: "/sys/login/doLogin.do", userField: "loginName", passField: "password"),
            // 通用 username/password
            LoginAttempt(path: "/sys/login/login.do", userField: "username", passField: "password"),
            LoginAttempt(path: "/login", userField: "username", passField: "password"),
            // j_security_check
            LoginAttempt(path: "/j_security_check", userField: "j_username", passField: "j_password"),
            LoginAttempt(path: "/login.do?method=check", userField: "j_username", passField: "j_password"),
            LoginAttempt(path: "/sys/login/login.do", userField: "j_username", passField: "j_password"),
            LoginAttempt(path: "/sys/login/doLogin.do", userField: "j_username", passField: "j_password"),
            LoginAttempt(path: "/login.jsp", userField: "j_username", passField: "j_password"),
        ]
    }

    struct LoginAttempt {
        let path: String
        let userField: String
        let passField: String
        var extraFields: [(String, String)] = []
    }

    struct DiscoveredLoginForm {
        let action: String // 相对路径或绝对 URL
        let userField: String
        let passField: String
        let hiddenFields: [(String, String)]
    }

    struct LoginPostResult {
        let statusCode: Int
        let location: String
        let bodySnippet: String
    }

    /// GET 登录页并解析 form（action / 字段名 / hidden）；同时获取初始 JSESSIONID
    func discoverLoginForm(baseURL: String) async throws -> DiscoveredLoginForm? {
        let candidates = ["/login.jsp", "/sys/login/login.jsp", "/sys/login/login.do", "/"]
        for path in candidates {
            guard let url = URL(string: baseURL + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            attachCookie(to: &request)
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            absorbSetCookies(from: http, responseURL: url)

            // 若 3xx，跟随一次
            if (300..<400).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let nextURL = URL(string: loc, relativeTo: url) {
                var req2 = URLRequest(url: nextURL)
                req2.httpMethod = "GET"
                req2.setValue(browserUA, forHTTPHeaderField: "User-Agent")
                attachCookie(to: &req2)
                guard let (data2, resp2) = try? await session.data(for: req2),
                      let http2 = resp2 as? HTTPURLResponse,
                      http2.statusCode == 200 else { continue }
                absorbSetCookies(from: http2, responseURL: nextURL)
                let html2 = decodeHTML(data: data2, response: http2)
                if let form = parseLoginForm(html: html2) { return form }
                continue
            }

            if http.statusCode == 200 {
                let html = decodeHTML(data: data, response: http)
                if let form = parseLoginForm(html: html) { return form }
            }
        }
        return nil
    }

    /// 从 HTML 中解析登录 form：找到含 password 输入的 form 块，提取 action / 字段名 / hidden
    func parseLoginForm(html: String) -> DiscoveredLoginForm? {
        guard let formBlock = extractFormContainingPassword(html: html) else { return nil }
        let action = extractAttr(name: "action", from: formBlock) ?? ""
        guard let passField = extractInputName(ofType: "password", in: formBlock) else { return nil }
        let userField = extractUsernameFieldName(in: formBlock, excluding: passField) ?? "username"
        let hidden = extractHiddenInputs(in: formBlock)
        return DiscoveredLoginForm(action: action, userField: userField, passField: passField, hiddenFields: hidden)
    }

    func extractFormContainingPassword(html: String) -> String? {
        // 非贪婪匹配 <form ...>...</form>
        let pattern = #"(?is)<form[^>]*>.*?</form>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        for m in matches {
            if let r = Range(m.range, in: html) {
                let block = String(html[r])
                if block.range(of: #"type\s*=\s*["']?password"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return block
                }
            }
        }
        return nil
    }

    func extractAttr(name: String, from tag: String) -> String? {
        let pattern = "(?i)\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let m = regex.firstMatch(in: tag, range: range) else { return nil }
        for i in 1...3 {
            if m.range(at: i).location != NSNotFound, let r = Range(m.range(at: i), in: tag) {
                return String(tag[r])
            }
        }
        return nil
    }

    func extractInputName(ofType type: String, in formBlock: String) -> String? {
        let pattern = #"(?is)<input[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(formBlock.startIndex..., in: formBlock)
        let matches = regex.matches(in: formBlock, range: range)
        for m in matches {
            if let r = Range(m.range, in: formBlock) {
                let tag = String(formBlock[r])
                if let t = extractAttr(name: "type", from: tag)?.lowercased(), t == type.lowercased() {
                    if let n = extractAttr(name: "name", from: tag), !n.isEmpty { return n }
                }
            }
        }
        return nil
    }

    func extractUsernameFieldName(in formBlock: String, excluding passName: String) -> String? {
        let pattern = #"(?is)<input[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(formBlock.startIndex..., in: formBlock)
        let matches = regex.matches(in: formBlock, range: range)
        // 优先选 type=text 且名字像用户名
        let preferNames = ["username", "userName", "loginName", "loginname", "j_username", "user", "account", "loginId"]
        var first: String? = nil
        for m in matches {
            guard let r = Range(m.range, in: formBlock) else { continue }
            let tag = String(formBlock[r])
            let t = extractAttr(name: "type", from: tag)?.lowercased() ?? "text"
            if t == "hidden" || t == "password" || t == "submit" || t == "button" || t == "checkbox" || t == "radio" { continue }
            guard let n = extractAttr(name: "name", from: tag), !n.isEmpty, n != passName else { continue }
            if preferNames.contains(n) { return n }
            if first == nil { first = n }
        }
        return first
    }

    func extractHiddenInputs(in formBlock: String) -> [(String, String)] {
        let pattern = #"(?is)<input[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(formBlock.startIndex..., in: formBlock)
        let matches = regex.matches(in: formBlock, range: range)
        var list: [(String, String)] = []
        for m in matches {
            guard let r = Range(m.range, in: formBlock) else { continue }
            let tag = String(formBlock[r])
            let t = extractAttr(name: "type", from: tag)?.lowercased()
            if t != "hidden" { continue }
            guard let n = extractAttr(name: "name", from: tag), !n.isEmpty else { continue }
            let v = extractAttr(name: "value", from: tag) ?? ""
            list.append((n, v))
        }
        return list
    }

    func postLogin(baseURL: String, attempt: LoginAttempt, user: String, password: String) async throws -> LoginPostResult {
        // action 可能是绝对 URL / 相对路径 / # / javascript:...
        let actionURL: URL
        if attempt.path.hasPrefix("http://") || attempt.path.hasPrefix("https://") {
            guard let u = URL(string: attempt.path) else { throw OAError.invalidURL }
            actionURL = u
        } else if attempt.path.hasPrefix("#") || attempt.path.lowercased().hasPrefix("javascript") || attempt.path.isEmpty {
            // 无效 action，回退到兰凌 EKP 默认入口
            guard let u = URL(string: baseURL + "/sys/login/login.do?method=login") else { throw OAError.invalidURL }
            actionURL = u
        } else {
            let fullPath = attempt.path.hasPrefix("/") ? attempt.path : "/" + attempt.path
            guard let u = URL(string: baseURL + fullPath) else { throw OAError.invalidURL }
            actionURL = u
        }
        var request = URLRequest(url: actionURL)
        request.httpMethod = "POST"
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue(baseURL + "/login.jsp", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        attachCookie(to: &request)

        var pairs: [String] = []
        pairs.append("\(attempt.userField)=\(urlEncode(user))")
        pairs.append("\(attempt.passField)=\(urlEncode(password))")
        // 带上 hidden 字段（CSRF token 等）
        for (k, v) in attempt.extraFields {
            if k == attempt.userField || k == attempt.passField { continue }
            pairs.append("\(urlEncode(k))=\(urlEncode(v))")
        }
        // 兰凌 EKP 常见兼容字段
        pairs.append("_validateFlag=1")
        pairs.append("rememberMe=true")
        let body = pairs.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        debugLog("[OAService] 尝试登录: \(actionURL.absoluteString) 字段=\(attempt.userField)/\(attempt.passField)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return LoginPostResult(statusCode: -1, location: "", bodySnippet: "non-http response")
        }
        absorbSetCookies(from: http, responseURL: actionURL)
        let location = http.value(forHTTPHeaderField: "Location") ?? ""
        var bodyText = String(data: data, encoding: .utf8) ?? ""
        if bodyText.isEmpty { bodyText = String(data: data, encoding: gbkEncoding) ?? "" }
        let snippet = String(bodyText.replacingOccurrences(of: "\n", with: " ").prefix(140))
        debugLog("[OAService] 响应: \(http.statusCode) loc=\(location) cookie=\(cookies.keys.joined(separator: ","))")
        return LoginPostResult(statusCode: http.statusCode, location: location, bodySnippet: snippet)
    }

    /// 登录 POST 后跟随一次 302 跳转，让 Acegi / EKP 完成 session 固化
    /// 失败不 throw（登录已判定成功，只是最佳努力）
    func followRedirect(baseURL: String, location: String) async {
        let target: String
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            target = location
        } else if location.hasPrefix("/") {
            target = baseURL + location
        } else {
            target = baseURL + "/" + location
        }
        guard let url = URL(string: target) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        attachCookie(to: &request)
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                absorbSetCookies(from: http, responseURL: url)
                debugLog("[OAService] followRedirect status=\(http.statusCode) url=\(target.prefix(120)) cookies=\(cookies.keys.sorted().joined(separator: ","))")
            }
        } catch {
            debugLog("[OAService] followRedirect 失败: \(error.localizedDescription)")
        }
    }

    func verifyLogin(baseURL: String, verifyURL: String? = nil) async throws -> Bool {
        // 优先用用户实际要抽取的业务页做校验，避免 / 被误判为登录成功
        let target = verifyURL ?? (baseURL + "/")
        guard let url = URL(string: target) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        attachCookie(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        absorbSetCookies(from: http)

        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            // 跳登录页 = 未登录
            return !looksLikeLoginRedirect(location: location)
        }
        if http.statusCode == 200 {
            let html = decodeHTML(data: data, response: http)
            return !looksLikeLoginPage(html: html)
        }
        return false
    }

    // MARK: - Cookie / URL helpers

    func attachCookie(to request: inout URLRequest) {
        guard !cookies.isEmpty else { return }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        request.setValue(header, forHTTPHeaderField: "Cookie")
    }

    /// 从 Set-Cookie 抽取 name=value，存入 cookies；优先用 HTTPCookie 解析多 Cookie
    func absorbSetCookies(from http: HTTPURLResponse, responseURL: URL? = nil) {
        if let url = responseURL {
            let fields = http.allHeaderFields as? [String: String] ?? [:]
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !parsed.isEmpty {
                for c in parsed { cookies[c.name] = c.value }
                return
            }
        }
        // HTTPURLResponse 只提供合并后的 "Set-Cookie" 单一 header，不可靠
        // 改用 allHeaderFields 的变体
        let headers = http.allHeaderFields
        for (k, v) in headers {
            guard let keyStr = k as? String, keyStr.lowercased() == "set-cookie",
                  let valStr = v as? String else { continue }
            // 多个 cookie 被合并为 "a=1; Path=/, b=2; Path=/" 的串，先按 ", " 粗拆（EKP 通常单个）
            // 精确起见：按每个 cookie 的第一个 "=" 前名字拆
            for piece in splitSetCookie(valStr) {
                guard let eqIdx = piece.firstIndex(of: "=") else { continue }
                let name = piece[..<eqIdx].trimmingCharacters(in: .whitespaces)
                var rest = String(piece[piece.index(after: eqIdx)...])
                if let semi = rest.firstIndex(of: ";") {
                    rest = String(rest[..<semi])
                }
                let value = rest.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { cookies[name] = value }
            }
        }
    }

    func splitSetCookie(_ header: String) -> [String] {
        // Set-Cookie 中 Expires 可能带 ", " （RFC1123），简单策略：按 "name=..." 边界拆分
        // 这里兜底：直接整段当作一个；多数 EKP 设的是 JSESSIONID=... 单一
        return [header]
    }

    func extractBaseURL(from url: URL) -> String {
        // 强制使用 https（OA 服务器通常要求 HTTPS）
        let scheme = "https"
        let host = url.host ?? ""
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    func absoluteURL(location: String, base: URL) -> String {
        if location.hasPrefix("http://") || location.hasPrefix("https://") { return location }
        if let u = URL(string: location, relativeTo: base) { return u.absoluteString }
        return location
    }

    func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func clearSession() {
        cookies.removeAll()
        loggedInBaseURL = nil
        loggedInUser = nil
    }

    // MARK: - Heuristics

    func looksLikeLoginRedirect(location: String) -> Bool {
        let lower = location.lowercased()
        // 兰凌 EKP 未认证时的重定向目标是 anonym.jsp，这里明确判为未登录
        return lower.contains("login") || lower.contains("signin") || lower.contains("sso") || lower.contains("anonym")
    }

    func looksLikeLoginPage(html: String) -> Bool {
        return loginPageDetectReason(html: html) != nil
    }

    func decodeHTML(data: Data, response: HTTPURLResponse) -> String {
        // 优先 Content-Type 里的 charset
        let ct = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ct.contains("charset=") {
            if ct.contains("gb") {
                if let s = String(data: data, encoding: gbkEncoding) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: gbkEncoding) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    func extractFileName(from http: HTTPURLResponse, fallbackURL: URL) -> String {
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
            debugLog("[OAService] Content-Disposition: \(cd)")
            
            // 1) RFC5987: filename*=UTF-8''xxx
            if let range = cd.range(of: "filename\\*=[^']*''([^;]+)", options: .regularExpression) {
                let raw = String(cd[range]).components(separatedBy: "''").last ?? ""
                if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                    debugLog("[OAService] 文件名 (RFC5987): \(decoded)")
                    return decoded.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            // 2) filename="xxx"（兰凌 EKP 返回两种格式：纯 UTF-8 字节流 或 UTF-8 字节流被错误解析为 Latin-1 后再 URL 编码）
            if let range = cd.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
                let raw = String(cd[range])
                if let startQ = raw.firstIndex(of: "\""), let endQ = raw.lastIndex(of: "\""), startQ < endQ {
                    let name = String(raw[raw.index(after: startQ)..<endQ])
                    debugLog("[OAService] 原始文件名 (quoted): \(name)")
                    
                    // 尝试 URL 解码（处理 %E4%B8%AD%E6%96%87 格式）
                    if let decoded = name.removingPercentEncoding, !decoded.isEmpty {
                        debugLog("[OAService] URL 解码后: \(decoded)")
                        
                        // 对 URL 解码后的结果，再尝试 UTF-8 重新解码（处理双重编码）
                        if let utf8Data = decoded.data(using: .isoLatin1),
                           let finalDecoded = String(data: utf8Data, encoding: .utf8),
                           !finalDecoded.isEmpty {
                            debugLog("[OAService] URL 解码 + UTF-8 重新解码后: \(finalDecoded)")
                            return finalDecoded
                        }
                        
                        // 直接返回 URL 解码结果
                        return decoded
                    }
                    
                    // 关键修复：兰凌 EKP 返回的是 UTF-8 字节流，但被 HTTP 响应头当作 Latin-1 解析
                    // 需要先将 String 转回原始字节，再用 UTF-8 重新解码
                    if let utf8Data = name.data(using: .isoLatin1),
                       let decodedUTF8 = String(data: utf8Data, encoding: .utf8),
                       !decodedUTF8.isEmpty {
                        debugLog("[OAService] UTF-8 重新解码后: \(decodedUTF8)")
                        return decodedUTF8
                    }
                    
                    // 尝试 GBK 解码（某些旧版本 EKP）
                    if let gbkData = name.data(using: .isoLatin1),
                       let decodedGBK = String(data: gbkData, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                        debugLog("[OAService] GBK 解码后: \(decodedGBK)")
                        return decodedGBK
                    }
                    
                    // 直接使用原始字符串
                    if !name.isEmpty { return name }
                }
            }
            // 3) filename=xxx（无引号）
            if let range = cd.range(of: "filename=([^;]+)", options: .regularExpression) {
                let raw = String(cd[range])
                let name = raw.replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: .whitespaces)
                debugLog("[OAService] 原始文件名 (unquoted): \(name)")
                // 尝试 URL 解码
                if let decoded = name.removingPercentEncoding, !decoded.isEmpty {
                    debugLog("[OAService] URL 解码后: \(decoded)")
                    
                    // 对 URL 解码后的结果，再尝试 UTF-8 重新解码（处理双重编码）
                    if let utf8Data = decoded.data(using: .isoLatin1),
                       let finalDecoded = String(data: utf8Data, encoding: .utf8),
                       !finalDecoded.isEmpty {
                        debugLog("[OAService] URL 解码 + UTF-8 重新解码后: \(finalDecoded)")
                        return finalDecoded
                    }
                    
                    // 直接返回 URL 解码结果
                    return decoded
                }
                // UTF-8 重新解码
                if let utf8Data = name.data(using: .isoLatin1),
                   let decodedUTF8 = String(data: utf8Data, encoding: .utf8),
                   !decodedUTF8.isEmpty {
                    debugLog("[OAService] UTF-8 重新解码后: \(decodedUTF8)")
                    return decodedUTF8
                }
                // 尝试 GBK 解码
                if let gbkData = name.data(using: .isoLatin1),
                   let decodedGBK = String(data: gbkData, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                    debugLog("[OAService] GBK 解码后: \(decodedGBK)")
                    return decodedGBK
                }
                if !name.isEmpty { return name }
            }
        }
        // fallback: URL 最后一段
        let fallbackName = fallbackURL.lastPathComponent.isEmpty ? "attachment.bin" : fallbackURL.lastPathComponent
        debugLog("[OAService] 使用 fallback 文件名: \(fallbackName)")
        return fallbackName
    }
}
