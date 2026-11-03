import Foundation
import Combine

class FavoriteService: ObservableObject {
    static let shared = FavoriteService()

    @Published var favorites: [FavoriteJira] = []
    @Published var autoSyncMessage: String = ""

    private let db = FavoriteDBService.shared
    private var autoSyncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 删除墓硕（Tombstones）
    // 用于记录已删除的 key，避免 WebDAV 合并时被“复活”
    private static let deletedKeysStorageKey = "favorite_deleted_keys"
    private var deletedKeys: Set<String> = []

    private init() {
        loadDeletedKeys()
        loadFavorites()
        setupAutoSyncObserver()
        startAutoSyncIfNeeded()
    }

    // MARK: - Tombstones 持久化

    private func loadDeletedKeys() {
        if let arr = UserDefaults.standard.array(forKey: Self.deletedKeysStorageKey) as? [String] {
            deletedKeys = Set(arr)
        }
    }

    private func saveDeletedKeys() {
        UserDefaults.standard.set(Array(deletedKeys), forKey: Self.deletedKeysStorageKey)
    }

    private func addTombstone(key: String) {
        deletedKeys.insert(key)
        saveDeletedKeys()
    }

    private func removeTombstone(key: String) {
        deletedKeys.remove(key)
        saveDeletedKeys()
    }

    // MARK: - 从链接解析 Issue Key

    /// 从 Jira 链接中提取 issue key，如 REQ-22411
    static func parseIssueKey(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 匹配 /browse/XXX-123 格式的链接
        if let range = trimmed.range(of: #"/browse/([A-Z]+-\d+)"#, options: .regularExpression) {
            let matched = trimmed[range]
            if let keyRange = matched.range(of: #"[A-Z]+-\d+"#, options: .regularExpression) {
                return String(matched[keyRange])
            }
        }

        // 直接输入 issue key（如 REQ-22411）
        if trimmed.range(of: #"^[A-Z]+-\d+$"#, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }

    // MARK: - CRUD

    /// 添加收藏:从 Jira 获取信息并保存
    func addFavorite(input: String) async throws -> FavoriteJira {
        guard let issueKey = FavoriteService.parseIssueKey(from: input) else {
            throw FavoriteError.invalidInput("无法解析 Jira 链接或编号,请输入类似 REQ-22411 或 http://jira.sinosafe.com.cn/browse/REQ-22411")
        }
    
        // 检查是否已收藏（使用数据库查询）
        if db.exists(key: issueKey) {
            throw FavoriteError.alreadyExists(issueKey)
        }
    
        // 从 Jira 获取详情
        let issue = try await JiraService.shared.getIssue(issueKey)
    
        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        let url = "\(baseURL)/browse/\(issueKey)"
    
        let favorite = FavoriteJira.from(issue: issue, url: url)
    
        db.insert(favorite)
        await MainActor.run {
            // 重新添加时清除对应的墓硕
            self.removeTombstone(key: issueKey)
            self.favorites.insert(favorite, at: 0)
        }
        syncAfterChange()
    
        return favorite
    }
    
    /// 批量添加收藏:支持多行输入,返回成功和失败的结果
    struct BatchAddResult {
        let success: [FavoriteJira]
        let failed: [(input: String, error: String)]
    }
    
    func addFavoritesBatch(inputs: [String]) async -> BatchAddResult {
        var success: [FavoriteJira] = []
        var failed: [(input: String, error: String)] = []
    
        for input in inputs {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
    
            do {
                let fav = try await addFavorite(input: trimmed)
                success.append(fav)
            } catch {
                failed.append((input: trimmed, error: error.localizedDescription))
            }
        }
    
        return BatchAddResult(success: success, failed: failed)
    }

    /// 切换置顶状态
    func togglePin(id: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[index].isPinned.toggle()
        let newVal = favorites[index].isPinned
        debugLog("📌 togglePin: \(favorites[index].key) -> isPinned=\(newVal), id=\(id)")
        
        // 置顶时记录时间，取消置顶时清空时间
        if newVal {
            favorites[index].pinnedAt = Date()
        } else {
            favorites[index].pinnedAt = nil
        }
        
        db.updatePinned(id: id, isPinned: newVal, pinnedAt: favorites[index].pinnedAt)
        syncAfterChange()
    }

    /// 切换归档状态
    func toggleArchive(id: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[index].isArchived.toggle()
        let newVal = favorites[index].isArchived
        debugLog("📦 toggleArchive: \(favorites[index].key) -> isArchived=\(newVal), id=\(id)")
        db.updateArchived(id: id, isArchived: newVal)
        syncAfterChange()
    }

    /// 删除收藏
    func removeFavorite(id: String) {
        // 记录墓硕，防止 WebDAV 合并时复活
        if let item = favorites.first(where: { $0.id == id }) {
            addTombstone(key: item.key)
        }
        favorites.removeAll { $0.id == id }
        db.delete(id: id)
        syncAfterChange()
    }

    /// 批量删除
    func removeFavorites(ids: Set<String>) {
        // 记录墓硕
        for id in ids {
            if let item = favorites.first(where: { $0.id == id }) {
                addTombstone(key: item.key)
            }
        }
        favorites.removeAll { ids.contains($0.id) }
        db.delete(ids: ids)
        syncAfterChange()
    }

    /// 刷新单个收藏（重新从 Jira 获取最新信息）
    func refreshFavorite(id: String) async throws {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let old = favorites[index]

        let issue = try await JiraService.shared.getIssue(old.key)
        let updated = FavoriteJira.from(issue: issue, url: old.url)

        // 保留原始 id 和收藏时间
        let refreshed = FavoriteJira(
            id: old.id,
            key: updated.key,
            issueType: updated.issueType,
            summary: updated.summary,
            reporter: updated.reporter,
            assignee: updated.assignee,
            status: updated.status,
            created: updated.created,
            updated: updated.updated,
            url: old.url,
            addedAt: old.addedAt,
            isPinned: old.isPinned,
            isArchived: old.isArchived,
            qianbaoNo: updated.qianbaoNo,
            qianbaoLink: updated.qianbaoLink
        )

        db.update(refreshed)
        await MainActor.run {
            self.favorites[index] = refreshed
        }
        syncAfterChange()
    }

    // MARK: - 导出 Excel

    /// 将收藏列表导出为 xlsx 文件
    func exportToExcel(items: [FavoriteJira], outputPath: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let xlDir = tempDir.appendingPathComponent("xl")
        let worksheetsDir = xlDir.appendingPathComponent("worksheets")
        let relsDir = tempDir.appendingPathComponent("_rels")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")

        try FileManager.default.createDirectory(at: worksheetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)

        // [Content_Types].xml
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """
        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        // _rels/.rels
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        try rootRels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        // xl/workbook.xml
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets>
                <sheet name="收藏Jira" sheetId="1" r:id="rId1"/>
            </sheets>
        </workbook>
        """
        try workbook.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)

        // xl/_rels/workbook.xml.rels
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        try workbookRels.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)

        // xl/styles.xml
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2">
                <font><sz val="11"/><name val="Arial"/></font>
                <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Arial"/></font>
            </fonts>
            <fills count="3">
                <fill><patternFill patternType="none"/></fill>
                <fill><patternFill patternType="gray125"/></fill>
                <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/></patternFill></fill>
            </fills>
            <borders count="2">
                <border><left/><right/><top/><bottom/><diagonal/></border>
                <border>
                    <left style="thin"><color auto="1"/></left>
                    <right style="thin"><color auto="1"/></right>
                    <top style="thin"><color auto="1"/></top>
                    <bottom style="thin"><color auto="1"/></bottom>
                    <diagonal/>
                </border>
            </borders>
            <cellStyleXfs count="1">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
            </cellStyleXfs>
            <cellXfs count="3">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
                <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
                <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
            </cellXfs>
        </styleSheet>
        """
        try styles.write(to: xlDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)

        // xl/worksheets/sheet1.xml
        let headers = ["Jira编号", "问题类型", "标题", "报告人", "经办人", "状态", "签报号", "创建时间", "更新时间", "收藏时间", "是否置顶", "是否归档"]
        let colCount = headers.count

        func letterForCol(_ col: Int) -> String {
            var c = col; var s = ""
            while c > 0 { let r = (c - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; c = (c - 1) / 26 }
            return s
        }
        func esc(_ str: String) -> String {
            str.replacingOccurrences(of: "&", with: "&amp;")
               .replacingOccurrences(of: "<", with: "&lt;")
               .replacingOccurrences(of: ">", with: "&gt;")
               .replacingOccurrences(of: "\"", with: "&quot;")
               .replacingOccurrences(of: "'", with: "&apos;")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <cols>
                <col min="1" max="1" width="16" customWidth="1"/>
                <col min="2" max="2" width="10" customWidth="1"/>
                <col min="3" max="3" width="50" customWidth="1"/>
                <col min="4" max="5" width="12" customWidth="1"/>
                <col min="6" max="6" width="14" customWidth="1"/>
                <col min="7" max="7" width="20" customWidth="1"/>
                <col min="8" max="10" width="18" customWidth="1"/>
                <col min="11" max="12" width="10" customWidth="1"/>
            </cols>
            <sheetData>
        """

        // Header row
        xml += "<row r=\"1\" spans=\"1:\(colCount)\">"
        for (idx, h) in headers.enumerated() {
            xml += "<c r=\"\(letterForCol(idx + 1))1\" s=\"1\" t=\"inlineStr\"><is><t>\(esc(h))</t></is></c>"
        }
        xml += "</row>"

        // Data rows
        for (rowIdx, item) in items.enumerated() {
            let row = rowIdx + 2
            let vals = [
                item.key,
                item.issueType,
                item.summary,
                item.reporter,
                item.assignee,
                item.status,
                item.qianbaoNo,
                item.created,
                item.updated,
                dateFormatter.string(from: item.addedAt),
                item.isPinned ? "是" : "否",
                item.isArchived ? "是" : "否"
            ]
            xml += "<row r=\"\(row)\" spans=\"1:\(colCount)\">"
            for (idx, v) in vals.enumerated() {
                xml += "<c r=\"\(letterForCol(idx + 1))\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(esc(v))</t></is></c>"
            }
            xml += "</row>"
        }

        xml += """
            </sheetData>
        </worksheet>
        """
        try xml.write(to: worksheetsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        // Zip to xlsx
        let finalPath = outputPath.hasSuffix(".xlsx") ? outputPath : outputPath + ".xlsx"
        // Remove existing file if any
        if FileManager.default.fileExists(atPath: finalPath) {
            try FileManager.default.removeItem(atPath: finalPath)
        }

        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", "-q", finalPath, "."]
        zipProcess.currentDirectoryURL = tempDir
        try zipProcess.run()
        zipProcess.waitUntilExit()

        if zipProcess.terminationStatus != 0 {
            throw FavoriteError.fetchFailed("创建 xlsx 文件失败")
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)

        if !FileManager.default.fileExists(atPath: finalPath) {
            throw FavoriteError.fetchFailed("导出文件未生成")
        }
    }

    // MARK: - WebDAV 同步

    /// 上传本地收藏到 WebDAV
    func syncUpload() async throws -> String {
        try await WebDavService.shared.upload(favorites: favorites)
        await MainActor.run { AppConfig.shared.lastSyncTime = Date() }
        return "✅ 已上传 \(favorites.count) 条收藏到 WebDAV"
    }

    /// 从 WebDAV 下载覆盖本地收藏
    func syncDownload() async throws -> String {
        let remote = try await WebDavService.shared.download()
        db.replaceAll(remote)
        await MainActor.run {
            self.favorites = remote
            AppConfig.shared.lastSyncTime = Date()
        }
        return "✅ 已从 WebDAV 下载 \(remote.count) 条收藏"
    }

    /// 双向合并同步（本地 + 远程 合并后回写双方）
    func syncMerge() async throws -> String {
        let remote = try await WebDavService.shared.download()
        let merged = WebDavService.shared.merge(local: favorites, remote: remote)

        // 过滤已删除的 key，防止“复活”
        let filtered = merged.filter { !deletedKeys.contains($0.key) }

        // 更新本地
        db.replaceAll(filtered)
        await MainActor.run {
            self.favorites = filtered
            AppConfig.shared.lastSyncTime = Date()
        }

        // 回写远程
        try await WebDavService.shared.upload(favorites: filtered)

        return "✅ 合并同步完成，共 \(filtered.count) 条收藏"
    }

    // MARK: - 自动同步

    /// 监听配置变化，动态重启定时器
    private func setupAutoSyncObserver() {
        let config = AppConfig.shared
        // 监听 autoSyncEnabled 和 autoSyncInterval 变化
        config.$autoSyncEnabled
            .combineLatest(config.$autoSyncInterval)
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.startAutoSyncIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// 启动或停止自动同步定时器
    func startAutoSyncIfNeeded() {
        // 先停止旧的定时器
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil

        let config = AppConfig.shared
        guard config.autoSyncEnabled && config.isWebdavConfigured else { return }

        let interval = TimeInterval(config.autoSyncInterval * 60)
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performAutoSync()
        }
        // 首次启动时也执行一次
        performAutoSync()
    }

    /// 执行自动同步（合并模式）
    private func performAutoSync() {
        guard AppConfig.shared.isWebdavConfigured else { return }

        Task {
            do {
                let msg = try await syncMerge()
                await MainActor.run {
                    self.autoSyncMessage = msg
                }
            } catch {
                await MainActor.run {
                    self.autoSyncMessage = "❌ 自动同步失败: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 停止自动同步
    func stopAutoSync() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }

    // MARK: - 数据变更后自动同步

    /// 本地数据变更后，自动上传到 WebDAV（非阻塞，后台静默执行）
    private func syncAfterChange() {
        guard AppConfig.shared.isWebdavConfigured else { return }
        Task {
            do {
                try await WebDavService.shared.upload(favorites: favorites)
                await MainActor.run {
                    AppConfig.shared.lastSyncTime = Date()
                }
                debugLog("☁️ 数据变更后自动同步完成")
            } catch {
                debugLog("⚠️ 数据变更后自动同步失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 持久化

    private func loadFavorites() {
        let loaded = db.loadAll()
        debugLog("📚 从 SQLite 加载 \(loaded.count) 条收藏")
        for item in loaded where item.isPinned || item.isArchived {
            debugLog("  └ \(item.key) isPinned=\(item.isPinned) isArchived=\(item.isArchived)")
        }
        favorites = loaded
    }
}

enum FavoriteError: Error, LocalizedError {
    case invalidInput(String)
    case alreadyExists(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return msg
        case .alreadyExists(let key): return "\(key) 已在收藏列表中"
        case .fetchFailed(let msg): return "获取 Jira 信息失败: \(msg)"
        }
    }
}
