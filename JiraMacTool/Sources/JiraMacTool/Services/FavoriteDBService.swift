import Foundation
import SQLite3

/// SQLite 数据库服务：管理收藏 Jira 的本地持久化
class FavoriteDBService {
    static let shared = FavoriteDBService()

    private var db: OpaquePointer?
    private let dbFileName = "jira_favorites.sqlite"
    private var customDBPath: URL?

    private init() {
        let dbPath = AppConfig.shared.dbPath
        if !dbPath.isEmpty {
            customDBPath = URL(fileURLWithPath: dbPath)
        }
        openDatabase()
        createTable()
        migrateFromUserDefaults()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - 数据库初始化

    private func openDatabase() {
        let fileURL = getDBPath()
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            debugLog("❌ 无法打开 SQLite 数据库: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func getDBPath() -> URL {
        if let custom = customDBPath {
            let dir = custom.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return custom
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("JiraMacTool")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(dbFileName)
    }

    /// 获取当前数据库路径字符串
    func getCurrentPath() -> String {
        getDBPath().path
    }

    /// 设置自定义数据库路径并重新打开
    /// - Parameters:
    ///   - path: 新的数据库文件路径，nil 表示恢复默认
    ///   - migrateData: 是否将旧数据复制到新位置
    /// - Returns: 操作结果消息
    @discardableResult
    func setCustomPath(_ path: URL?, migrateData: Bool = false) -> String {
        // 关闭旧连接
        if db != nil {
            sqlite3_close(db)
            db = nil
        }

        let oldPath = getDBPath()
        customDBPath = path

        if migrateData {
            let newPath = getDBPath()
            let dir = newPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: oldPath.path) {
                try? FileManager.default.copyItem(at: oldPath, to: newPath)
            }
        }

        openDatabase()
        createTable()

        return "✅ 数据库路径已更新: \(getDBPath().path)"
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS favorites (
            id TEXT PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            issueType TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            reporter TEXT NOT NULL DEFAULT '',
            assignee TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL DEFAULT '',
            updated TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            addedAt REAL NOT NULL,
            isPinned INTEGER NOT NULL DEFAULT 0,
            pinnedAt REAL,
            isArchived INTEGER NOT NULL DEFAULT 0,
            qianbaoNo TEXT NOT NULL DEFAULT '',
            qianbaoLink TEXT NOT NULL DEFAULT '',
            modifiedAt REAL NOT NULL DEFAULT 0
        );
        """
        executeSQL(sql)

        // 数据库迁移：为旧表添加 pinnedAt 列
        migrateAddColumnIfNeeded(column: "pinnedAt", definition: "REAL")
        // 数据库迁移：为旧表添加 modifiedAt 列，并用 addedAt 回填历史数据
        if migrateAddColumnIfNeeded(column: "modifiedAt", definition: "REAL NOT NULL DEFAULT 0") {
            executeSQL("UPDATE favorites SET modifiedAt = addedAt WHERE modifiedAt = 0;")
        }

        // 创建索引
        executeSQL("CREATE INDEX IF NOT EXISTS idx_favorites_key ON favorites(key);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_favorites_isPinned ON favorites(isPinned);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_favorites_pinnedAt ON favorites(pinnedAt);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_favorites_isArchived ON favorites(isArchived);")
    }

    /// 通用迁移：若指定列不存在则添加。返回 true 表示本次确实新增了该列。
    @discardableResult
    private func migrateAddColumnIfNeeded(column: String, definition: String) -> Bool {
        let checkSql = "PRAGMA table_info(favorites);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ 检查表结构失败")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        var hasColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let colName = sqlite3_column_text(stmt, 1) {
                if String(cString: colName) == column {
                    hasColumn = true
                    break
                }
            }
        }

        guard !hasColumn else { return false }
        debugLog("📦 数据库迁移：添加 \(column) 列...")
        executeSQL("ALTER TABLE favorites ADD COLUMN \(column) \(definition);")
        debugLog("✅ 数据库迁移完成：\(column)")
        return true
    }

    private func executeSQL(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "未知错误"
            debugLog("❌ SQL 执行失败: \(msg)")
            sqlite3_free(errMsg)
        }
    }

    // MARK: - 从 UserDefaults 迁移

    private func migrateFromUserDefaults() {
        let storageKey = "jira_favorites"
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([FavoriteJira].self, from: data) else {
            return
        }

        // 检查数据库是否已有数据，避免重复迁移
        if loadAll().isEmpty && !items.isEmpty {
            debugLog("📦 从 UserDefaults 迁移 \(items.count) 条收藏到 SQLite...")
            for item in items {
                insert(item)
            }
            // 迁移完成后删除 UserDefaults 数据
            UserDefaults.standard.removeObject(forKey: storageKey)
            debugLog("✅ 迁移完成，已清除 UserDefaults 数据")
        }
    }

    // MARK: - CRUD 操作

    /// 插入一条收藏
    func insert(_ item: FavoriteJira) {
        let sql = """
        INSERT OR REPLACE INTO favorites
        (id, key, issueType, summary, reporter, assignee, status, created, updated, url, addedAt, isPinned, pinnedAt, isArchived, qianbaoNo, qianbaoLink, modifiedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ 准备插入语句失败: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: item.id)
        bindText(stmt, index: 2, value: item.key)
        bindText(stmt, index: 3, value: item.issueType)
        bindText(stmt, index: 4, value: item.summary)
        bindText(stmt, index: 5, value: item.reporter)
        bindText(stmt, index: 6, value: item.assignee)
        bindText(stmt, index: 7, value: item.status)
        bindText(stmt, index: 8, value: item.created)
        bindText(stmt, index: 9, value: item.updated)
        bindText(stmt, index: 10, value: item.url)
        sqlite3_bind_double(stmt, 11, item.addedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 12, item.isPinned ? 1 : 0)
        if let pinnedAt = item.pinnedAt {
            sqlite3_bind_double(stmt, 13, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_bind_int(stmt, 14, item.isArchived ? 1 : 0)
        bindText(stmt, index: 15, value: item.qianbaoNo)
        bindText(stmt, index: 16, value: item.qianbaoLink)
        sqlite3_bind_double(stmt, 17, item.modifiedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            debugLog("❌ 插入失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// 加载全部收藏（按收藏时间倒序）
    func loadAll() -> [FavoriteJira] {
        let sql = "SELECT id, key, issueType, summary, reporter, assignee, status, created, updated, url, addedAt, isPinned, pinnedAt, isArchived, qianbaoNo, qianbaoLink, modifiedAt FROM favorites ORDER BY addedAt DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ 准备查询语句失败: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var items: [FavoriteJira] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = readRow(stmt)
            items.append(item)
        }
        return items
    }

    /// 更新置顶状态
    func updatePinned(id: String, isPinned: Bool, pinnedAt: Date? = nil) {
        let sql = "UPDATE favorites SET isPinned = ?, pinnedAt = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ 准备更新置顶语句失败: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, isPinned ? 1 : 0)
        if let pinnedAt = pinnedAt {
            sqlite3_bind_double(stmt, 2, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        bindText(stmt, index: 3, value: id)
        if sqlite3_step(stmt) != SQLITE_DONE {
            debugLog("❌ 更新置顶失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// 更新归档状态
    func updateArchived(id: String, isArchived: Bool) {
        let sql = "UPDATE favorites SET isArchived = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ 准备更新归档语句失败: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, isArchived ? 1 : 0)
        bindText(stmt, index: 2, value: id)
        if sqlite3_step(stmt) != SQLITE_DONE {
            debugLog("❌ 更新归档失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// 更新整条记录（刷新时使用）
    func update(_ item: FavoriteJira) {
        insert(item) // INSERT OR REPLACE
    }

    /// 删除一条记录
    func delete(id: String) {
        let sql = "DELETE FROM favorites WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: id)
        sqlite3_step(stmt)
    }

    func delete(ids: Set<String>) {
        executeSQL("BEGIN TRANSACTION;")
        for id in ids {
            delete(id: id)
        }
        executeSQL("COMMIT;")
    }

    /// 检查 key 是否已存在
    func exists(key: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM favorites WHERE key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: key)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    func replaceAll(_ items: [FavoriteJira]) {
        executeSQL("BEGIN TRANSACTION;")
        executeSQL("DELETE FROM favorites;")
        for item in items {
            insert(item)
        }
        executeSQL("COMMIT;")
    }

    // MARK: - 辅助

    /// 安全绑定文本参数（使用 SQLITE_TRANSIENT 确保字符串生命周期安全）
    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, strdup(value), -1, { ptr in free(UnsafeMutableRawPointer(mutating: ptr)) })
    }

    private func readRow(_ stmt: OpaquePointer?) -> FavoriteJira {
        func col(_ idx: Int32) -> String {
            if let cStr = sqlite3_column_text(stmt, idx) {
                return String(cString: cStr)
            }
            return ""
        }

        return FavoriteJira(
            id: col(0),
            key: col(1),
            issueType: col(2),
            summary: col(3),
            reporter: col(4),
            assignee: col(5),
            status: col(6),
            created: col(7),
            updated: col(8),
            url: col(9),
            addedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
            isPinned: sqlite3_column_int(stmt, 11) != 0,
            pinnedAt: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)) : nil,
            isArchived: sqlite3_column_int(stmt, 13) != 0,
            qianbaoNo: col(14),
            qianbaoLink: col(15),
            modifiedAt: {
                // 兼容旧库：modifiedAt 为 0 或缺失时回退到 addedAt
                let m = sqlite3_column_double(stmt, 16)
                return m > 0 ? Date(timeIntervalSince1970: m) : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            }()
        )
    }
}
