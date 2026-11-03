import Foundation
import Security

// 从 Keychain 读取密码
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
        return nil
    }
    return password
}

let jiraURL = UserDefaults.standard.string(forKey: "jira_url") ?? "http://jira.sinosafe.com.cn"
let jiraUser = UserDefaults.standard.string(forKey: "jira_user") ?? "wuhaopeng"

guard let jiraPassword = loadPasswordFromKeychain() else {
    print("❌ 未找到 Keychain 中的密码，请先在应用中保存密码")
    exit(1)
}

let config = URLSessionConfiguration.default
config.httpCookieAcceptPolicy = .never
config.httpShouldSetCookies = false
let session = URLSession(configuration: config)

// 测试 Basic Auth
print("=== 测试 Basic Auth (与应用相同 URLSession 配置) ===")
let url = URL(string: "\(jiraURL)/rest/api/2/myself")!
var request = URLRequest(url: url)
request.setValue("application/json", forHTTPHeaderField: "Accept")
request.setValue("JiraMacTool/1.0", forHTTPHeaderField: "User-Agent")
let authString = "\(jiraUser):\(jiraPassword)"
let base64Auth = Data(authString.utf8).base64EncodedString()
request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")

print("URL: \(url)")

let sem = DispatchSemaphore(value: 0)
session.dataTask(with: request) { data, response, error in
    if let error = error {
        print("❌ 错误: \(error)")
        sem.signal(); return
    }
    guard let http = response as? HTTPURLResponse else {
        print("❌ 无效响应"); sem.signal(); return
    }
    print("Status: \(http.statusCode)")
    print("Headers:")
    for (k, v) in http.allHeaderFields { print("  \(k): \(v)") }
    if let data = data, let body = String(data: data, encoding: .utf8) {
        print("Body: \(body.prefix(400))")
    }
    if http.statusCode == 200 {
        print("\n✅ Basic Auth 工作正常！")
    } else {
        print("\n❌ Basic Auth 也失败了")
    }
    sem.signal()
}.resume()
sem.wait()
