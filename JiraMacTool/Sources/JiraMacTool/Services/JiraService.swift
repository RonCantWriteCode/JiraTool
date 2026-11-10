import Foundation

enum JiraError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case decodingError
    case noData
    case sessionExpired
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .invalidResponse: return "无效的服务器响应"
        case .httpError(let code, let msg): return "HTTP 错误 \(code): \(msg)"
        case .decodingError: return "数据解析错误"
        case .noData: return "没有返回数据"
        case .sessionExpired: return "会话已过期，请重新登录"
        case .loginFailed(let msg): return "登录失败: \(msg)"
        }
    }
}

private class SessionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let originalRequest = task.originalRequest else {
            completionHandler(request)
            return
        }
        var newRequest = request
        // 重定向时保留原始 HTTP 方法和请求体（防止 POST 变 GET）
        newRequest.httpMethod = originalRequest.httpMethod
        newRequest.httpBody = originalRequest.httpBody
        // 保留 Cookie 头
        if let cookie = originalRequest.value(forHTTPHeaderField: "Cookie") {
            newRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        // 保留 Authorization 头
        if let auth = originalRequest.value(forHTTPHeaderField: "Authorization") {
            newRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        // 保留 Content-Type
        if let contentType = originalRequest.value(forHTTPHeaderField: "Content-Type") {
            newRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        completionHandler(newRequest)
    }
}

/// Session 有效期：7 天
private let sessionMaxAge: TimeInterval = 7 * 24 * 60 * 60

actor JiraService {
    static let shared = JiraService()
    private init() {
        let config = URLSessionConfiguration.default
        // 禁用自动 cookie 管理，由我们手动控制
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config, delegate: SessionRedirectDelegate(), delegateQueue: nil)
        // 从 UserDefaults 恢复 session
        self.sessionId = UserDefaults.standard.string(forKey: "jira_session_id")
        if let ts = UserDefaults.standard.object(forKey: "jira_session_login_time") as? Date {
            self.sessionLoginTime = ts
        }
        self.sessionUser = UserDefaults.standard.string(forKey: "jira_session_user")
    }

    private let session: URLSession

    // MARK: - Session 状态
    private var sessionId: String?
    private var sessionLoginTime: Date?
    private var sessionUser: String?
    /// 是否正在登录中（防止并发重复登录）
    private var isLoggingIn = false

    /// 当前 session 是否有效
    var isSessionValid: Bool {
        guard let sessionId = sessionId, !sessionId.isEmpty,
              let loginTime = sessionLoginTime else {
            return false
        }
        let config = AppConfig.shared
        // 用户名变了也视为无效
        if sessionUser != config.jiraUser {
            return false
        }
        return Date().timeIntervalSince(loginTime) < sessionMaxAge
    }

    /// 获取 session 信息（供 UI 显示）
    var sessionInfo: (isValid: Bool, user: String?, loginTime: Date?) {
        return (isSessionValid, sessionUser, sessionLoginTime)
    }

    // MARK: - 登录 / 登出

    /// 是否正在使用 Basic Auth 降级模式
    private var usingBasicAuthFallback = false

    /// 通过 Jira REST Session API 登录，获取 JSESSIONID
    /// 如果 Session API 不可用，自动降级为 Basic Auth 模式
    func login() async throws -> String {
        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        guard let url = URL(string: baseURL + "/rest/auth/1/session") else {
            throw JiraError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")

        let loginBody: [String: String] = [
            "username": config.jiraUser,
            "password": config.jiraPassword
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: loginBody)

        debugLog("[JiraService] 正在通过 Session API 登录... 用户: \(config.jiraUser), URL: \(url.absoluteString)")
        print("[JiraService] 正在通过 Session API 登录... 用户: \(config.jiraUser), URL: \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JiraError.invalidResponse
            }

            print("[JiraService] Session API 响应: \(httpResponse.statusCode)")
            debugLog("[JiraService] Session API 响应: \(httpResponse.statusCode)")
            if let responseURL = httpResponse.url {
                debugLog("[JiraService] 最终 URL: \(responseURL.absoluteString)")
            }

            if httpResponse.statusCode == 200 {
                // 尝试解析 session 响应
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sessionDict = json["session"] as? [String: Any],
                   let sessionValue = sessionDict["value"] as? String {
                    // Session 登录成功
                    self.sessionId = sessionValue
                    self.sessionLoginTime = Date()
                    self.sessionUser = config.jiraUser
                    self.usingBasicAuthFallback = false
                    self.persistSession()

                    debugLog("[JiraService] ✅ Session 登录成功！JSESSIONID=\(sessionValue.prefix(8))...")

                    // 调用 /myself 获取 displayName
                    let displayName = await fetchDisplayName()
                    return displayName ?? config.jiraUser
                } else {
                    let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
                    debugLog("[JiraService] Session API 返回 200 但解析失败: \(bodyStr.prefix(500))")
                    debugLog("[JiraService] 降级为 Basic Auth 模式")
                    return try await loginWithBasicAuth()
                }
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                let msg = String(data: data, encoding: .utf8) ?? "认证失败"
                debugLog("[JiraService] Session API 认证失败: \(msg.prefix(200))")
                throw JiraError.loginFailed("用户名或密码错误")
            } else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
                debugLog("[JiraService] Session API 返回 \(httpResponse.statusCode): \(bodyStr.prefix(200))")
                debugLog("[JiraService] 降级为 Basic Auth 模式")
                return try await loginWithBasicAuth()
            }
        } catch let error as JiraError {
            throw error
        } catch {
            print("[JiraService] Session API 请求异常: \(error.localizedDescription)")
            debugLog("[JiraService] Session API 请求异常: \(error.localizedDescription)")
            debugLog("[JiraService] 降级为 Basic Auth 模式")
            return try await loginWithBasicAuth()
        }
    }

    /// Basic Auth 降级登录：通过 /rest/api/2/myself 验证凭证
    private func loginWithBasicAuth() async throws -> String {
        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        guard let url = URL(string: baseURL + "/rest/api/2/myself") else {
            throw JiraError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")

        let authString = "\(config.jiraUser):\(config.jiraPassword)"
        guard let authData = authString.data(using: .utf8) else {
            throw JiraError.invalidURL
        }
        request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        debugLog("[JiraService] 尝试 Basic Auth 验证...")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            self.usingBasicAuthFallback = true
            self.sessionId = "BASIC_AUTH_FALLBACK"
            self.sessionLoginTime = Date()
            self.sessionUser = config.jiraUser
            self.persistSession()

            let displayName: String
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["displayName"] as? String {
                displayName = name
            } else {
                displayName = config.jiraUser
            }

            debugLog("[JiraService] ✅ Basic Auth 登录成功！用户: \(displayName)")
            return displayName
        } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw JiraError.loginFailed("用户名或密码错误")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw JiraError.loginFailed(msg)
        }
    }

    /// 获取当前用户 displayName
    private func fetchDisplayName() async -> String? {
        do {
            let data = try await doRequest(path: "/rest/api/2/myself")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["displayName"] as? String {
                return name
            }
        } catch {
            debugLog("[JiraService] 获取 displayName 失败: \(error)")
        }
        return nil
    }

    /// 登出，清除 session
    func logout() async {
        if let sid = sessionId {
            // 尝试调用 Jira 登出 API
            do {
                let config = AppConfig.shared
                let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
                if let url = URL(string: baseURL + "/rest/auth/1/session") {
                    var request = URLRequest(url: url)
                    request.httpMethod = "DELETE"
                    request.setValue("JSESSIONID=\(sid)", forHTTPHeaderField: "Cookie")
                    _ = try await session.data(for: request)
                    debugLog("[JiraService] 已通知服务器登出")
                }
            } catch {
                debugLog("[JiraService] 登出请求失败（不影响本地清除）: \(error)")
            }
        }
        clearSession()
        debugLog("[JiraService] 已清除本地 session")
    }

    /// 确保 session 有效，无效则自动登录
    private func ensureSession() async throws {
        if isSessionValid { return }
        // 防止并发重复登录
        guard !isLoggingIn else { return }
        isLoggingIn = true
        defer { isLoggingIn = false }
        debugLog("[JiraService] Session 无效或已过期，自动重新登录...")
        _ = try await login()
    }

    private func clearSession() {
        sessionId = nil
        sessionLoginTime = nil
        sessionUser = nil
        UserDefaults.standard.removeObject(forKey: "jira_session_id")
        UserDefaults.standard.removeObject(forKey: "jira_session_login_time")
        UserDefaults.standard.removeObject(forKey: "jira_session_user")
    }

    private func persistSession() {
        UserDefaults.standard.set(sessionId, forKey: "jira_session_id")
        UserDefaults.standard.set(sessionLoginTime, forKey: "jira_session_login_time")
        UserDefaults.standard.set(sessionUser, forKey: "jira_session_user")
    }

    // MARK: - 请求

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        // 确保有有效 session
        try await ensureSession()

        let data = try await doRequest(path: path, method: method, body: body)
        return data
    }

    /// 执行实际的 HTTP 请求，使用 Cookie Session 认证
    private func doRequest(path: String, method: String = "GET", body: Data? = nil, retried: Bool = false) async throws -> Data {
        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        guard let url = URL(string: baseURL + path) else {
            throw JiraError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")

        // 使用 Cookie 认证或 Basic Auth 降级
        if usingBasicAuthFallback {
            let appConfig = AppConfig.shared
            let authString = "\(appConfig.jiraUser):\(appConfig.jiraPassword)"
            if let authData = authString.data(using: .utf8) {
                request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        } else if let sid = sessionId {
            request.setValue("JSESSIONID=\(sid)", forHTTPHeaderField: "Cookie")
        }

        if let body = body {
            request.httpBody = body
        }

        debugLog("[JiraService] Request URL: \(url.absoluteString) [\(method)]")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraError.invalidResponse
        }

        debugLog("[JiraService] Response status: \(httpResponse.statusCode)")

        // 401 表示 session 可能已过期，尝试重新登录后重试一次
        if httpResponse.statusCode == 401 && !retried {
            debugLog("[JiraService] 收到 401，session 可能已过期，尝试重新登录...")
            clearSession()
            _ = try await login()
            return try await doRequest(path: path, method: method, body: body, retried: true)
        }

        if httpResponse.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            debugLog("[JiraService] Error body: \(msg)")
            throw JiraError.httpError(httpResponse.statusCode, msg)
        }

        return data
    }

    // MARK: - Connection Test

    func testConnection() async throws -> String {
        let data = try await makeRequest(path: "/rest/api/2/myself")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["displayName"] as? String else {
            throw JiraError.decodingError
        }
        return name
    }

    // MARK: - Search

    func searchJQL(_ jql: String, fields: String = "*all", maxResults: Int = 1000) async throws -> [JiraIssue] {
        let encodedJQL = jql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? jql
        let path = "/rest/api/2/search?jql=\(encodedJQL)&fields=\(fields)&maxResults=\(maxResults)"

        let data = try await makeRequest(path: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = json["issues"] as? [[String: Any]] else {
            throw JiraError.decodingError
        }

        return issues.compactMap { parseIssue($0) }
    }

    // MARK: - Issue CRUD

    func getIssue(_ key: String) async throws -> JiraIssue {
        let path = "/rest/api/2/issue/\(key)"
        let data = try await makeRequest(path: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.decodingError
        }
        guard let issue = parseIssue(json) else {
            throw JiraError.decodingError
        }
        return issue
    }

    /// 获取 issue 的原始 JSON 字典（可选 expand），便于读取 names / schema 等附加信息
    func getIssueRaw(_ key: String, expand: String? = nil) async throws -> [String: Any] {
        var path = "/rest/api/2/issue/\(key)"
        if let expand = expand, !expand.isEmpty {
            path += "?expand=\(expand)"
        }
        let data = try await makeRequest(path: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.decodingError
        }
        return json
    }

    /// 获取指定项目和IssueType的创建字段元数据（含 allowedValues）
    func getCreateMetaFields(projectKey: String, issueTypeName: String) async throws -> [String: Any]? {
        let encoded = issueTypeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issueTypeName
        let path = "/rest/api/2/issue/createmeta?projectKeys=\(projectKey)&issuetypeNames=\(encoded)&expand=projects.issuetypes.fields"
        let data = try await makeRequest(path: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]], !projects.isEmpty,
              let issueTypes = projects[0]["issuetypes"] as? [[String: Any]], !issueTypes.isEmpty,
              let fields = issueTypes[0]["fields"] as? [String: Any] else {
            return nil
        }
        return fields
    }

    /// 按名字搜索用户（Jira 用户名/显示名），返回 name 列表
    func searchUsers(query: String) async throws -> [[String: Any]] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = "/rest/api/2/user/search?username=\(encoded)&maxResults=5"
        let data = try await makeRequest(path: path)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    func createIssue(project: String, issueType: String, fields: [String: Any]) async throws -> String {
        let path = "/rest/api/2/issue"
        let body: [String: Any] = [
            "fields": fields
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await makeRequest(path: path, method: "POST", body: data)

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let key = json["key"] as? String else {
            throw JiraError.decodingError
        }
        return key
    }

    func updateIssue(_ key: String, fields: [String: Any]) async throws {
        let path = "/rest/api/2/issue/\(key)"
        let body: [String: Any] = ["fields": fields]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await makeRequest(path: path, method: "PUT", body: data)
    }

    /// 通过 update 操作更新问题字段（适用于 labels 等不支持 fields 直接设置的字段）
    func updateIssueOperations(_ key: String, update: [String: Any]) async throws {
        let path = "/rest/api/2/issue/\(key)"
        let body: [String: Any] = ["update": update]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await makeRequest(path: path, method: "PUT", body: data)
    }

    func addComment(issueKey: String, body: String) async throws {
        let path = "/rest/api/2/issue/\(issueKey)/comment"
        let bodyJson: [String: Any] = ["body": body]
        let data = try JSONSerialization.data(withJSONObject: bodyJson)
        _ = try await makeRequest(path: path, method: "POST", body: data)
    }

    func transitionIssue(issueKey: String, transitionId: String) async throws {
        let path = "/rest/api/2/issue/\(issueKey)/transitions"
        let body: [String: Any] = [
            "transition": ["id": transitionId]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await makeRequest(path: path, method: "POST", body: data)
    }

    func linkIssues(from: String, to: String, linkType: String = "关联") async throws {
        let path = "/rest/api/2/issueLink"
        let body: [String: Any] = [
            "type": ["name": linkType],
            "inwardIssue": ["key": from],
            "outwardIssue": ["key": to]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await makeRequest(path: path, method: "POST", body: data)
    }

    /// 关联操作结果
    enum LinkOutcome {
        /// 新建了关联
        case created
        /// 已经存在关联，未重复创建
        case alreadyLinked
        /// 两侧都读不到已有关联，为安全起见未创建
        case unverified
    }

    /// 读取 issue 已关联的其他 issue key（统一大写）；读取失败返回 nil
    func getLinkedIssueKeys(_ key: String) async -> Set<String>? {
        do {
            let raw = try await getIssueRaw(key)
            guard let fields = raw["fields"] as? [String: Any] else { return nil }
            // issuelinks 字段缺失时无法确认已有关联，按读取失败处理（避免重复关联）
            guard let links = fields["issuelinks"] as? [[String: Any]] else { return nil }
            var keys = Set<String>()
            for link in links {
                if let outward = link["outwardIssue"] as? [String: Any], let k = outward["key"] as? String {
                    keys.insert(k.uppercased())
                }
                if let inward = link["inwardIssue"] as? [String: Any], let k = inward["key"] as? String {
                    keys.insert(k.uppercased())
                }
            }
            return keys
        } catch {
            debugLog("[JiraService] getLinkedIssueKeys(\(key)) 失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 关联两个 issue，已关联则跳过：先查 from 侧，查不到再查 to 侧；
    /// 两侧都读不到时返回 .unverified 且不创建，避免重复关联。
    /// 创建关联本身失败时抛出异常。
    func linkIssuesIfAbsent(from: String, to: String, linkType: String = "关联") async throws -> LinkOutcome {
        if let fromKeys = await getLinkedIssueKeys(from) {
            if fromKeys.contains(to.uppercased()) { return .alreadyLinked }
        } else {
            guard let toKeys = await getLinkedIssueKeys(to) else { return .unverified }
            if toKeys.contains(from.uppercased()) { return .alreadyLinked }
        }

        do {
            try await linkIssues(from: from, to: to, linkType: linkType)
            return .created
        } catch let error as JiraError {
            // 部分实例在关联已存在时返回错误，按已关联处理
            if case .httpError(_, let msg) = error, Self.isAlreadyExistsError(msg) {
                debugLog("[JiraService] linkIssues 报关联已存在: \(msg.prefix(200))")
                return .alreadyLinked
            }
            throw error
        }
    }

    /// 判断报错文本是否为「关联已存在」
    private static func isAlreadyExistsError(_ msg: String) -> Bool {
        let lower = msg.lowercased()
        return lower.contains("already exist") || lower.contains("duplicate") || msg.contains("已存在")
    }

    // MARK: - Versions

    func getProjectVersions(project: String = "REQ") async throws -> [JiraVersion] {
        let path = "/rest/api/2/project/\(project)/versions"
        let data = try await makeRequest(path: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JiraError.decodingError
        }

        return json.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return JiraVersion(
                id: id,
                name: name,
                description: dict["description"] as? String,
                releaseDate: dict["releaseDate"] as? String,
                archived: dict["archived"] as? Bool ?? false,
                released: dict["released"] as? Bool ?? false,
                selfUrl: (dict["self"] as? String) ?? ""
            )
        }
    }

    func createVersion(project: String = "REQ", name: String, description: String, releaseDate: String) async throws -> JiraVersion {
        let path = "/rest/api/2/version"
        let body: [String: Any] = [
            "project": project,
            "name": name,
            "description": description,
            "releaseDate": releaseDate,
            "archived": false,
            "released": false
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await makeRequest(path: path, method: "POST", body: data)

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let id = json["id"] as? String,
              let retName = json["name"] as? String else {
            throw JiraError.decodingError
        }

        return JiraVersion(
            id: id,
            name: retName,
            description: json["description"] as? String,
            releaseDate: json["releaseDate"] as? String,
            archived: json["archived"] as? Bool ?? false,
            released: json["released"] as? Bool ?? false,
            selfUrl: (json["self"] as? String) ?? ""
        )
    }

    func deleteVersion(versionId: String) async throws {
        let path = "/rest/api/2/version/\(versionId)"
        _ = try await makeRequest(path: path, method: "DELETE")
    }

    // MARK: - Attachments

    /// 获取 issue 的附件列表（原始字典数组，由调用方解析字段）
    func getAttachments(issueKey: String) async throws -> [[String: Any]] {
        let issue = try await getIssue(issueKey)
        return issue.fields["attachment"] as? [[String: Any]] ?? []
    }

    /// issue 上是否已有同名（忽略大小写）且同大小的附件。
    /// 读取失败或字段缺失时返回 false（照常上传，不拦住正常流程）。
    func hasSameAttachment(issueKey: String, fileName: String, size: Int) async -> Bool {
        do {
            let list = try await getAttachments(issueKey: issueKey)
            let target = fileName.lowercased()
            return list.contains { att in
                let name = (att["filename"] as? String ?? "").lowercased()
                let attSize = att["size"] as? Int ?? -1
                return name == target && attSize == size
            }
        } catch {
            debugLog("[JiraService] hasSameAttachment(\(issueKey)) 失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 上传附件；同名同大小的附件已存在则跳过。返回 true=已上传，false=已存在跳过
    @discardableResult
    func uploadAttachmentIfAbsent(issueKey: String, fileName: String, fileData: Data,
                                  mimeType: String = "application/octet-stream") async throws -> Bool {
        if await hasSameAttachment(issueKey: issueKey, fileName: fileName, size: fileData.count) {
            return false
        }
        try await uploadAttachment(issueKey: issueKey, fileName: fileName, fileData: fileData, mimeType: mimeType)
        return true
    }

    /// 下载附件内容（传入 attachment.content 绝对 URL）
    func downloadAttachmentData(urlString: String) async throws -> Data {
        try await ensureSession()
        guard let url = URL(string: urlString) else { throw JiraError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")
        attachAuthHeaders(to: &request)

        debugLog("[JiraService] Download attachment: \(url.absoluteString)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        if http.statusCode == 401 {
            clearSession()
            _ = try await login()
            return try await downloadAttachmentData(urlString: urlString)
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.httpError(http.statusCode, msg)
        }
        return data
    }

    /// 上传附件（multipart/form-data）
    func uploadAttachment(issueKey: String, fileName: String, fileData: Data, mimeType: String = "application/octet-stream") async throws {
        try await ensureSession()

        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        guard let url = URL(string: baseURL + "/rest/api/2/issue/\(issueKey)/attachments") else {
            throw JiraError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")
        attachAuthHeaders(to: &request)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        // 文件名对双引号进行转义
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        debugLog("[JiraService] Upload attachment: \(safeName) (\(fileData.count) bytes) -> \(issueKey)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        if http.statusCode == 401 {
            clearSession()
            _ = try await login()
            return try await uploadAttachment(issueKey: issueKey, fileName: fileName, fileData: fileData, mimeType: mimeType)
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.httpError(http.statusCode, msg)
        }
    }

    /// 删除指定附件（DELETE /rest/api/2/attachment/{id}）。401 自动重登重试
    func deleteAttachment(id: String) async throws {
        try await ensureSession()

        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        guard let url = URL(string: baseURL + "/rest/api/2/attachment/\(id)") else {
            throw JiraError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")
        attachAuthHeaders(to: &request)

        debugLog("[JiraService] Delete attachment: id=\(id)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        if http.statusCode == 401 {
            clearSession()
            _ = try await login()
            return try await deleteAttachment(id: id)
        }
        // 成功：204 No Content；部分实例可能 200
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.httpError(http.statusCode, msg)
        }
    }

    /// 给请求添加认证 header（Cookie 或 Basic Auth）
    private func attachAuthHeaders(to request: inout URLRequest) {
        if usingBasicAuthFallback {
            let config = AppConfig.shared
            let authString = "\(config.jiraUser):\(config.jiraPassword)"
            if let authData = authString.data(using: .utf8) {
                request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        } else if let sid = sessionId {
            request.setValue("JSESSIONID=\(sid)", forHTTPHeaderField: "Cookie")
        }
    }

    // MARK: - Helpers

    private func parseIssue(_ dict: [String: Any]) -> JiraIssue? {
        guard let key = dict["key"] as? String,
              let fields = dict["fields"] as? [String: Any] else { return nil }

        let summary = fields["summary"] as? String ?? ""
        let labels = fields["labels"] as? [String] ?? []
        let statusDict = fields["status"] as? [String: Any]
        let status = statusDict?["name"] as? String ?? ""
        let issueTypeDict = fields["issuetype"] as? [String: Any]
        let issueType = issueTypeDict?["name"] as? String ?? ""

        return JiraIssue(
            key: key,
            summary: summary,
            fields: fields,
            labels: labels,
            status: status,
            issueType: issueType
        )
    }

    nonisolated func getFieldString(name: String, value: String, id: String) -> [String: Any] {
        return [
            "self": "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/\(id)",
            "value": value,
            "id": id
        ]
    }
}
