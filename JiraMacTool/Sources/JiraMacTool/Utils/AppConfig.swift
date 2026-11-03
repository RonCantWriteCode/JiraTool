import Foundation
import Security

class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published var jiraURL: String {
        didSet { UserDefaults.standard.set(jiraURL, forKey: "jira_url") }
    }

    @Published var jiraUser: String {
        didSet { UserDefaults.standard.set(jiraUser, forKey: "jira_user") }
    }

    /// 密码延迟加载：只在首次访问或需要登录时才从 Keychain 读取
    private var _jiraPassword: String? = nil

    var jiraPassword: String {
        if let pw = _jiraPassword { return pw }
        let loaded = AppConfig.loadPasswordFromKeychain() ?? ""
        _jiraPassword = loaded
        return loaded
    }

    // MARK: - WebDAV 配置

    @Published var webdavURL: String {
        didSet { UserDefaults.standard.set(webdavURL, forKey: "webdav_url") }
    }

    @Published var webdavUser: String {
        didSet { UserDefaults.standard.set(webdavUser, forKey: "webdav_user") }
    }

    @Published var webdavRemotePath: String {
        didSet { UserDefaults.standard.set(webdavRemotePath, forKey: "webdav_remote_path") }
    }

    private var _webdavPassword: String? = nil

    var webdavPassword: String {
        if let pw = _webdavPassword { return pw }
        let loaded = AppConfig.loadKeychainPassword(service: "JiraMacTool", account: "webdav_password") ?? ""
        _webdavPassword = loaded
        return loaded
    }

    // MARK: - 自动同步配置

    @Published var autoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "webdav_auto_sync_enabled") }
    }

    /// 自动同步间隔（分钟）
    @Published var autoSyncInterval: Int {
        didSet { UserDefaults.standard.set(autoSyncInterval, forKey: "webdav_auto_sync_interval") }
    }

    /// 数据库文件自定义路径（空字符串表示使用默认路径）
    @Published var dbPath: String {
        didSet { UserDefaults.standard.set(dbPath, forKey: "db_path") }
    }

    /// 上次同步时间
    @Published var lastSyncTime: Date? {
        didSet {
            if let date = lastSyncTime {
                UserDefaults.standard.set(date, forKey: "webdav_last_sync_time")
            }
        }
    }

    /// 可选的同步频率（分钟）
    static let syncIntervalOptions: [(label: String, minutes: Int)] = [
        ("5 分钟", 5),
        ("10 分钟", 10),
        ("15 分钟", 15),
        ("30 分钟", 30),
        ("1 小时", 60),
        ("2 小时", 120),
        ("6 小时", 360),
        ("12 小时", 720),
    ]

    var isWebdavConfigured: Bool {
        !webdavURL.isEmpty && !webdavUser.isEmpty && !webdavPassword.isEmpty
    }

    func saveWebdavPassword(_ password: String) {
        _webdavPassword = password
        saveKeychainPassword(password, service: "JiraMacTool", account: "webdav_password")
    }

    private init() {
        self.jiraURL = UserDefaults.standard.string(forKey: "jira_url") ?? "http://jira.sinosafe.com.cn"
        self.jiraUser = UserDefaults.standard.string(forKey: "jira_user") ?? "wurunlong"
        self.webdavURL = UserDefaults.standard.string(forKey: "webdav_url") ?? ""
        self.webdavUser = UserDefaults.standard.string(forKey: "webdav_user") ?? ""
        self.webdavRemotePath = UserDefaults.standard.string(forKey: "webdav_remote_path") ?? "/jira-favorites.json"
        self.autoSyncEnabled = UserDefaults.standard.bool(forKey: "webdav_auto_sync_enabled")
        self.autoSyncInterval = {
            let val = UserDefaults.standard.integer(forKey: "webdav_auto_sync_interval")
            return val > 0 ? val : 30  // 默认 30 分钟
        }()
        self.lastSyncTime = UserDefaults.standard.object(forKey: "webdav_last_sync_time") as? Date
        self.dbPath = UserDefaults.standard.string(forKey: "db_path") ?? ""
        // 不再从 Keychain 加载密码，延迟到首次需要时再加载
    }

    func savePassword(_ password: String) {
        _jiraPassword = password
        savePasswordToKeychain(password)
    }

    // MARK: - Keychain 通用方法

    private func savePasswordToKeychain(_ password: String) {
        saveKeychainPassword(password, service: "JiraMacTool", account: "jira_password")
    }

    private func saveKeychainPassword(_ password: String, service: String, account: String) {
        let data = password.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func loadPasswordFromKeychain() -> String? {
        return loadKeychainPassword(service: "JiraMacTool", account: "jira_password")
    }

    static func loadKeychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
}
