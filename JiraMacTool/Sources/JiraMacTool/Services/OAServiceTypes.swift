import Foundation

enum OAError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case loginFailed(String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 OA URL"
        case .invalidResponse: return "无效的 OA 服务器响应"
        case .httpError(let code, let msg): return "OA HTTP 错误 \(code): \(msg)"
        case .loginFailed(let msg): return "OA 登录失败: \(msg)"
        case .notLoggedIn: return "OA 尚未登录"
        }
    }
}

/// OA 附件信息（下载后）
struct OADownloadedAttachment {
    let name: String
    let data: Data
    let mimeType: String
}

final class OARedirectBlocker: NSObject, URLSessionTaskDelegate {
    /// 禁止自动重定向，由调用方手动处理，方便保留 Cookie 并检测登录页跳转
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
