import Foundation
import Security

// 1. 先从 Keychain 读取密码
func loadPasswordFromKeychain() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "JiraMacTool",
        kSecAttrAccount as String: "jira_password",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let password = String(data: data, encoding: .utf8) else {
        print("❌ Keychain 读取失败, status: \(status)")
        return nil
    }
    return password
}

let jiraURL = UserDefaults.standard.string(forKey: "jira_url") ?? "http://jira.sinosafe.com.cn"
let jiraUser = UserDefaults.standard.string(forKey: "jira_user") ?? "wuhaopeng"
let keychainPassword = loadPasswordFromKeychain()

print("=== 诊断信息 ===")
print("Jira URL: \(jiraURL)")
print("Jira User: \(jiraUser)")
print("Keychain 密码: \(keychainPassword == nil ? "❌ 未找到" : "✅ 长度=\(keychainPassword!.count), 内容=\(keychainPassword!)")")

guard let password = keychainPassword, !password.isEmpty else {
    print("\n❌ 密码为空，请先在应用中保存密码")
    exit(1)
}

// 2. 配置 URLSession（与应用完全一致）
class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let originalRequest = task.originalRequest else {
            completionHandler(request)
            return
        }
        var newRequest = request
        newRequest.httpMethod = originalRequest.httpMethod
        newRequest.httpBody = originalRequest.httpBody
        if let cookie = originalRequest.value(forHTTPHeaderField: "Cookie") {
            newRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let auth = originalRequest.value(forHTTPHeaderField: "Authorization") {
            newRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let ct = originalRequest.value(forHTTPHeaderField: "Content-Type") {
            newRequest.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        print("  [Redirect] \(response.statusCode) -> \(newRequest.url?.absoluteString ?? "?")")
        print("  [Redirect] Method: \(newRequest.httpMethod ?? "?"), Body: \(newRequest.httpBody?.count ?? 0) bytes")
        completionHandler(newRequest)
    }
}

let config = URLSessionConfiguration.default
config.httpCookieAcceptPolicy = .never
config.httpShouldSetCookies = false
let session = URLSession(configuration: config, delegate: RedirectDelegate(), delegateQueue: nil)

// 3. 测试 Session API 登录
print("\n=== 测试 Session API 登录 ===")
let loginURL = URL(string: jiraURL + "/rest/auth/1/session")!
var loginRequest = URLRequest(url: loginURL)
loginRequest.httpMethod = "POST"
loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
loginRequest.setValue("application/json", forHTTPHeaderField: "Accept")
loginRequest.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")
let loginBody = try! JSONSerialization.data(withJSONObject: ["username": jiraUser, "password": password])
loginRequest.httpBody = loginBody

print("Request URL: \(loginURL)")
print("Body: \(String(data: loginBody, encoding: .utf8) ?? "")")

let semaphore = DispatchSemaphore(value: 0)

let task = session.dataTask(with: loginRequest) { data, response, error in
    if let error = error {
        print("❌ 网络错误: \(error.localizedDescription)")
        semaphore.signal()
        return
    }
    guard let httpResponse = response as? HTTPURLResponse else {
        print("❌ 无效响应")
        semaphore.signal()
        return
    }
    
    print("Response status: \(httpResponse.statusCode)")
    print("Response URL: \(httpResponse.url?.absoluteString ?? "?")")
    print("Response headers:")
    for (key, value) in httpResponse.allHeaderFields {
        print("  \(key): \(value)")
    }
    
    if let data = data {
        let bodyStr = String(data: data, encoding: .utf8) ?? "(binary)"
        print("Response body: \(bodyStr)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sessionDict = json["session"] as? [String: Any],
               let sessionValue = sessionDict["value"] as? String {
                print("\n✅ Session 登录成功！JSESSIONID = \(sessionValue)")
                
                // 4. 测试用 session cookie 访问 /myself
                print("\n=== 测试 Cookie 认证 ===")
                let myselfURL = URL(string: "\(jiraURL)/rest/api/2/myself")!
                var myselfReq = URLRequest(url: myselfURL)
                myselfReq.setValue("JSESSIONID=\(sessionValue)", forHTTPHeaderField: "Cookie")
                myselfReq.setValue("application/json", forHTTPHeaderField: "Accept")
                
                let task2 = session.dataTask(with: myselfReq) { data2, resp2, err2 in
                    if let httpResp2 = resp2 as? HTTPURLResponse {
                        print("myself status: \(httpResp2.statusCode)")
                        if let d = data2, let s = String(data: d, encoding: .utf8) {
                            print("myself body: \(s.prefix(300))")
                        }
                    }
                    if let err2 = err2 {
                        print("myself error: \(err2)")
                    }
                    semaphore.signal()
                }
                task2.resume()
                return
            } else {
                print("❌ 200 但解析 session 失败")
            }
        } else {
            print("❌ 非 200 响应")
        }
    }
    semaphore.signal()
}
task.resume()
semaphore.wait()
// 给第二个请求一点时间
Thread.sleep(forTimeInterval: 3)
