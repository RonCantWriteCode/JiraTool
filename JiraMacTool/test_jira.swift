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

let authString = "\(jiraUser):\(jiraPassword)"
let base64Auth = Data(authString.utf8).base64EncodedString()

let url = URL(string: "\(jiraURL)/rest/api/2/myself")!
var request = URLRequest(url: url)
request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")

let task = URLSession.shared.dataTask(with: request) { data, response, error in
    if let error = error {
        print("❌ 连接失败: \(error.localizedDescription)")
        exit(1)
    }
    guard let httpResponse = response as? HTTPURLResponse else {
        print("❌ 无效响应")
        exit(1)
    }
    if httpResponse.statusCode == 200, let data = data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["displayName"] as? String {
            print("✅ 连接成功！用户: \(name)")
        } else {
            print("✅ 连接成功，但解析响应失败")
        }
    } else {
        print("❌ HTTP 错误: \(httpResponse.statusCode)")
        if let data = data, let msg = String(data: data, encoding: .utf8) {
            print(msg)
        }
    }
    exit(0)
}
task.resume()
RunLoop.main.run()
