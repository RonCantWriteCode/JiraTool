import Foundation

struct FavoriteJira: Codable, Identifiable, Sendable {
    let id: String          // UUID
    let key: String         // REQ-22411
    let issueType: String   // 类型（需求、缺陷等）
    let summary: String     // 标题
    let reporter: String    // 报告人
    let assignee: String    // 经办人
    let status: String      // 状态
    let created: String     // 创建时间
    let updated: String     // 更新时间
    let url: String         // 原始链接
    let addedAt: Date       // 收藏时间
    var isPinned: Bool      // 是否置顶
    var pinnedAt: Date?     // 置顶时间（用于排序）
    var isArchived: Bool    // 是否已归档
    let qianbaoNo: String   // 签报号
    let qianbaoLink: String // 签报链接
    /// 最近一次本地修改时间。用于 WebDAV 同步时的 Last-Write-Wins 冲突解决。
    /// 任何会改变本条记录的操作（添加、置顶、归档、刷新）都应刷新该值。
    var modifiedAt: Date

    /// 兼容旧数据：isPinned/isArchived 默认 false, qianbaoNo/qianbaoLink 默认空字符串,
    /// pinnedAt 默认 nil, modifiedAt 默认取 addedAt。
    init(id: String, key: String, issueType: String, summary: String, reporter: String, assignee: String, status: String, created: String, updated: String, url: String, addedAt: Date, isPinned: Bool = false, pinnedAt: Date? = nil, isArchived: Bool = false, qianbaoNo: String = "", qianbaoLink: String = "", modifiedAt: Date? = nil) {
        self.id = id; self.key = key; self.issueType = issueType; self.summary = summary
        self.reporter = reporter; self.assignee = assignee; self.status = status
        self.created = created; self.updated = updated; self.url = url
        self.addedAt = addedAt; self.isPinned = isPinned; self.pinnedAt = pinnedAt; self.isArchived = isArchived
        self.qianbaoNo = qianbaoNo; self.qianbaoLink = qianbaoLink
        self.modifiedAt = modifiedAt ?? addedAt
    }

    // MARK: - Codable（手动实现以保证向后兼容旧的远程/本地数据）

    private enum CodingKeys: String, CodingKey {
        case id, key, issueType, summary, reporter, assignee, status
        case created, updated, url, addedAt, isPinned, pinnedAt, isArchived
        case qianbaoNo, qianbaoLink, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        issueType = try c.decodeIfPresent(String.self, forKey: .issueType) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        reporter = try c.decodeIfPresent(String.self, forKey: .reporter) ?? ""
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        created = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        let added = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        addedAt = added
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        qianbaoNo = try c.decodeIfPresent(String.self, forKey: .qianbaoNo) ?? ""
        qianbaoLink = try c.decodeIfPresent(String.self, forKey: .qianbaoLink) ?? ""
        // 旧数据没有 modifiedAt，回退到收藏时间，保证排序与合并仍可工作
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? added
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(issueType, forKey: .issueType)
        try c.encode(summary, forKey: .summary)
        try c.encode(reporter, forKey: .reporter)
        try c.encode(assignee, forKey: .assignee)
        try c.encode(status, forKey: .status)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(url, forKey: .url)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(qianbaoNo, forKey: .qianbaoNo)
        try c.encode(qianbaoLink, forKey: .qianbaoLink)
        try c.encode(modifiedAt, forKey: .modifiedAt)
    }

    /// 从 JiraIssue 构建收藏项
    static func from(issue: JiraIssue, url: String) -> FavoriteJira {
        let reporterName: String
        if let reporterDict = issue.fields["reporter"] as? [String: Any] {
            reporterName = reporterDict["displayName"] as? String ?? reporterDict["name"] as? String ?? "未知"
        } else {
            reporterName = "未知"
        }

        let assigneeName: String
        if let assigneeDict = issue.fields["assignee"] as? [String: Any] {
            assigneeName = assigneeDict["displayName"] as? String ?? assigneeDict["name"] as? String ?? "未分配"
        } else {
            assigneeName = "未分配"
        }

        let created = issue.fields["created"] as? String ?? ""
        let updated = issue.fields["updated"] as? String ?? ""

        let qianbaoNo = issue.fields["customfield_10115"] as? String ?? ""
        let qianbaoLink = issue.fields["customfield_13252"] as? String ?? ""

        let now = Date()
        return FavoriteJira(
            id: UUID().uuidString,
            key: issue.key,
            issueType: issue.issueType,
            summary: issue.summary,
            reporter: reporterName,
            assignee: assigneeName,
            status: issue.status,
            created: formatJiraDate(created),
            updated: formatJiraDate(updated),
            url: url,
            addedAt: now,
            isPinned: false,
            isArchived: false,
            qianbaoNo: qianbaoNo,
            qianbaoLink: qianbaoLink,
            modifiedAt: now
        )
    }

    /// 返回一个 modifiedAt 刷新为当前时间的副本（用于本地修改后标记需要同步）
    func touched(at date: Date = Date()) -> FavoriteJira {
        var copy = self
        copy.modifiedAt = date
        return copy
    }

    /// 格式化 Jira 日期（内部用）
    private static func formatJiraDate(_ dateStr: String) -> String {
        return formatJiraDatePublic(dateStr)
    }

    /// 格式化 Jira 日期（外部可调用）
    static func formatJiraDatePublic(_ dateStr: String) -> String {
        guard !dateStr.isEmpty else { return "" }
        // 尝试解析 ISO 格式
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
        if let date = formatter.date(from: dateStr) {
            let display = DateFormatter()
            display.dateFormat = "yyyy-MM-dd HH:mm"
            return display.string(from: date)
        }
        // 尝试 Jira 常见格式
        let jiraFormatter = DateFormatter()
        jiraFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = jiraFormatter.date(from: dateStr) {
            let display = DateFormatter()
            display.dateFormat = "yyyy-MM-dd HH:mm"
            return display.string(from: date)
        }
        // 回退：截取前16位
        if dateStr.count >= 16 {
            return String(dateStr.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        return dateStr
    }
}
