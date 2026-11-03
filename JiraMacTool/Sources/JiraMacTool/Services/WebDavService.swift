import Foundation

/// WebDAV 同步服务：通过 WebDAV 协议上传/下载收藏列表 JSON
class WebDavService {
    static let shared = WebDavService()
    private init() {}

    enum WebDavError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case uploadFailed(String)
        case downloadFailed(String)
        case mergeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "WebDAV 未配置，请先设置 WebDAV 连接信息"
            case .invalidURL: return "WebDAV URL 无效"
            case .uploadFailed(let msg): return "上传失败: \(msg)"
            case .downloadFailed(let msg): return "下载失败: \(msg)"
            case .mergeFailed(let msg): return "合并失败: \(msg)"
            }
        }
    }

    // MARK: - 构建请求

    private func buildURL() throws -> URL {
        let config = AppConfig.shared
        guard config.isWebdavConfigured else { throw WebDavError.notConfigured }

        var base = config.webdavURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }

        var path = config.webdavRemotePath
        if !path.hasPrefix("/") { path = "/" + path }

        guard let url = URL(string: base + path) else { throw WebDavError.invalidURL }
        return url
    }

    private func authHeader() -> String {
        let config = AppConfig.shared
        let credentials = "\(config.webdavUser):\(config.webdavPassword)"
        let data = credentials.data(using: .utf8)!
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - 上传（PUT）

    /// 将本地收藏列表上传到 WebDAV
    func upload(favorites: [FavoriteJira]) async throws {
        let url = try buildURL()
        let data = try JSONEncoder().encode(favorites)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDavError.uploadFailed("无法获取响应")
        }

        // 2xx 表示成功（201 Created 或 204 No Content）
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDavError.uploadFailed("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - 下载（GET）

    /// 从 WebDAV 下载收藏列表
    func download() async throws -> [FavoriteJira] {
        let url = try buildURL()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDavError.downloadFailed("无法获取响应")
        }

        if httpResponse.statusCode == 404 {
            // 远程文件不存在，返回空列表
            return []
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDavError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        guard !data.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([FavoriteJira].self, from: data)
        } catch {
            throw WebDavError.downloadFailed("JSON 解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 合并

    /// 合并本地和远程收藏列表（以 key 为唯一标识，取 addedAt 较新的）
    func merge(local: [FavoriteJira], remote: [FavoriteJira]) -> [FavoriteJira] {
        var merged: [String: FavoriteJira] = [:]

        // 先放入远程数据
        for item in remote {
            merged[item.key] = item
        }

        // 本地数据覆盖或补充（本地优先，因为本地每次变更都会自动同步）
        for item in local {
            if let existing = merged[item.key] {
                // addedAt 相同时本地优先（>= 而非 >）
                if item.addedAt >= existing.addedAt {
                    merged[item.key] = item
                }
            } else {
                merged[item.key] = item
            }
        }

        // 按收藏时间倒序排列
        return merged.values.sorted { $0.addedAt > $1.addedAt }
    }

    // MARK: - 测试连接

    /// 测试 WebDAV 连接是否正常
    func testConnection() async throws -> String {
        let config = AppConfig.shared
        guard config.isWebdavConfigured else { throw WebDavError.notConfigured }

        var base = config.webdavURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }

        // 使用 PROPFIND 测试根目录
        guard let url = URL(string: base + "/") else { throw WebDavError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDavError.downloadFailed("无法获取响应")
        }

        // 207 Multi-Status 是 PROPFIND 的正常响应
        if httpResponse.statusCode == 207 || (200...299).contains(httpResponse.statusCode) {
            return "连接成功 ✅"
        } else if httpResponse.statusCode == 401 {
            throw WebDavError.downloadFailed("认证失败，请检查用户名和密码")
        } else {
            throw WebDavError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }
    }
}
