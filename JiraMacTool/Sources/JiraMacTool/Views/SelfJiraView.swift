import SwiftUI
import AppKit

// MARK: - 表格行数据模型

struct JiraTableRow: Identifiable {
    let id: String          // issue.key
    let key: String
    let summary: String
    let issueType: String
    let status: String
    let assignee: String
    let reporter: String
    let fixDate: String     // regularVersionField 对应的字段值（如「预计修复时间」）
    let testDate: String    // 预计提测时间 (customfield_13212)
    let testDateObj: Date?  // 预计提测时间的 Date 对象，用于倒计时
    let versions: String    // 版本号 (customfield_10126，多个以逗号拼接)
    let developer: String   // 系统开发人员 (customfield_11923)
    let labels: String      // 标签 (issue.labels 逗号拼接)
    let requester: String   // 需求提出人员 (customfield_10123)
    let created: String
    let updated: String
    let issue: JiraIssue    // 原始对象，供操作使用
}

struct SelfJiraView: View {
    let title: String
    // 顶部「常规版本」chip 要替换的 JQL 字段名；nil 表示不显示 chip 栏
    // 例：「版本需求」传入 "预计修复时间"，「publish」传入 "申请发布时间"
    let regularVersionField: String?
    /// 是否用表格模式展示（有标头+数据行）
    let useTableLayout: Bool
    // 保存 JQL 的默认值，修改后自动持久化
    @AppStorage private var jql: String

    init(title: String = "Self-Jira",
         storageKey: String = "self_jira_jql",
         defaultJQL: String = "assignee in (currentUser()) AND status != Closed AND status != Done AND project = REQ ORDER BY createdDate DESC",
         regularVersionField: String? = nil,
         useTableLayout: Bool = false) {
        self.title = title
        self.regularVersionField = regularVersionField
        self.useTableLayout = useTableLayout
        self._jql = AppStorage(wrappedValue: defaultJQL, storageKey)
    }

    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var regularVersionStore = RegularVersionDateStore.shared
    @State private var issues: [JiraIssue] = []
    @State private var isLoading = false
    @State private var errorMsg = ""
    @State private var detailItem: DetailSheetItem?
    @State private var favoritingKeys: Set<String> = []
    @State private var statusMessage = ""
    @State private var isStatusError = false
    @State private var tableSelection: Set<String> = []
    @State private var tableSortOrder = [KeyPathComparator<JiraTableRow>(\JiraTableRow.key)]

    /// 将原始 issues 转换为表格行（含字段提取）
    private func makeTableRows() -> [JiraTableRow] {
        issues.map { issue in
            let assignee: String = {
                if let a = issue.fields["assignee"] as? [String: Any] {
                    return a["displayName"] as? String ?? a["name"] as? String ?? "未分配"
                }
                return "未分配"
            }()
            let reporter: String = {
                if let r = issue.fields["reporter"] as? [String: Any] {
                    return r["displayName"] as? String ?? r["name"] as? String ?? "未知"
                }
                return "未知"
            }()
            // 预计修复时间 (customfield_10919) -> 格式化为 yy-MM-dd
            let fixDateRaw: String = {
                if let v = issue.fields["customfield_10919"] as? String { return v }
                if let v = issue.fields["customfield_10919"] as? [String: Any],
                   let d = v["value"] as? String ?? v["name"] as? String { return d }
                return ""
            }()
            let fixDate = formatDate(fixDateRaw, format: "yy-MM-dd")

            // 预计提测时间 (customfield_13212) -> 格式化为 MM-dd HH:mm:ss
            let testDateRaw: String = {
                if let v = issue.fields["customfield_13212"] as? String { return v }
                if let v = issue.fields["customfield_13212"] as? [String: Any],
                   let d = v["value"] as? String ?? v["name"] as? String { return d }
                return ""
            }()
            let testDate = formatDate(testDateRaw, format: "MM-dd HH:mm:ss")
            let testDateObj = parseDate(testDateRaw)

            // 版本号 (customfield_10126，数组，取所有 name 拼接)
            let versions: String = {
                guard let arr = issue.fields["customfield_10126"] as? [[String: Any]] else { return "" }
                return arr.compactMap { $0["name"] as? String }.joined(separator: ", ")
            }()
            // 系统开发人员 (customfield_11923，user 对象，取 displayName)
            let developer: String = {
                if let obj = issue.fields["customfield_11923"] as? [String: Any] {
                    return obj["displayName"] as? String ?? obj["name"] as? String ?? ""
                }
                // 兼容字符串格式
                if let s = issue.fields["customfield_11923"] as? String { return s }
                return ""
            }()
            // 标签
            let labels = issue.labels.joined(separator: ", ")
            // 需求提出人员 (customfield_10123，字符串)
            let requester = issue.fields["customfield_10123"] as? String ?? ""
            let created = FavoriteJira.formatJiraDatePublic(issue.fields["created"] as? String ?? "")
            let updated = FavoriteJira.formatJiraDatePublic(issue.fields["updated"] as? String ?? "")
            return JiraTableRow(
                id: issue.key,
                key: issue.key,
                summary: issue.summary,
                issueType: issue.issueType,
                status: issue.status,
                assignee: assignee,
                reporter: reporter,
                fixDate: fixDate,
                testDate: testDate,
                testDateObj: testDateObj,
                versions: versions,
                developer: developer,
                labels: labels,
                requester: requester,
                created: created,
                updated: updated,
                issue: issue
            )
        }
    }

    private func parseDate(_ dateStr: String) -> Date? {
        guard !dateStr.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: dateStr) { return d }
        }
        return nil
    }

    private func formatDate(_ dateStr: String, format: String) -> String {
        guard let d = parseDate(dateStr) else { return dateStr }
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = format
        return outputFormatter.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶部：JQL 输入
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    if !issues.isEmpty {
                        Text("共 \(issues.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 常规版本 chip（由 regularVersionField 控制是否显示及替换哪个字段）
                if let field = regularVersionField, !regularVersionStore.dates.isEmpty {
                    regularVersionBar(field: field)
                }

                HStack(spacing: 8) {
                    TextField("JQL 查询语句", text: $jql)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { runQuery() }

                    Button(action: runQuery) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("查询", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isLoading || jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }

                if !errorMsg.isEmpty {
                    Text(errorMsg)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .foregroundColor(isStatusError ? .red : .green)
                        .font(.caption)
                }
            }
            .padding()

            Divider()

            // MARK: - 结果列表
            if isLoading && issues.isEmpty {
                Spacer()
                ProgressView("查询中...")
                Spacer()
            } else if issues.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("无查询结果")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if useTableLayout {
                // MARK: 表格模式 —— 提取为独立 View 以规避编译器类型推断超时
                JiraTableView(
                    rows: makeTableRows().sorted(using: tableSortOrder),
                    selection: $tableSelection,
                    sortOrder: $tableSortOrder,
                    fixDateTitle: regularVersionField ?? "修复时间",
                    onOpen: { openInBrowser($0) },
                    onCopyKey: { copyToClipboard($0) },
                    onShowDetail: { detailItem = DetailSheetItem(issueKey: $0) },
                    onFavorite: { toggleFavorite($0) },
                    isFavoriting: { favoritingKeys.contains($0) }
                )
            } else {
                List {
                    ForEach(issues, id: \.key) { issue in
                        SelfJiraRow(
                            issue: issue,
                            isFavorited: favoriteService.favorites.contains(where: { $0.key == issue.key }),
                            isFavoriting: favoritingKeys.contains(issue.key),
                            onOpen: { openInBrowser(issue.key) },
                            onCopyKey: { copyToClipboard(issue.key) },
                            onShowDetail: { detailItem = DetailSheetItem(issueKey: issue.key) },
                            onFavorite: { toggleFavorite(issue.key) }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle(title)
        .onAppear {
            // 每次进入菜单都执行一次查询
            runQuery()
        }
        .overlay {
            if let item = detailItem {
                // 半透明遮罩
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { detailItem = nil }

                JiraDetailSheet(issueKey: item.issueKey, onDismiss: {
                    detailItem = nil
                })
                .frame(minWidth: 650, minHeight: 500)
                .frame(maxWidth: 800, maxHeight: 700)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: detailItem != nil)
    }

    // MARK: - Actions

    /// 常规版本 chip 栏：点击后将 JQL 中「<field> = 某日期」替换为对应日期
    @ViewBuilder
    private func regularVersionBar(field: String) -> some View {
        let current = currentDate(for: field)
        VStack(alignment: .leading, spacing: 4) {
            Text("常规版本（点击切换\(field)）")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(regularVersionStore.dates, id: \.self) { date in
                        let isSelected = (current == date)
                        let past = isDatePast(date)
                        Button {
                            applyRegularVersion(date, field: field)
                        } label: {
                            Text(date)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(
                                        isSelected
                                        ? Color.accentColor
                                        : Color.secondary.opacity(past ? 0.08 : 0.18)
                                    )
                                )
                                .foregroundColor(
                                    isSelected ? .white
                                    : (past ? .secondary : .primary)
                                )
                                .overlay(
                                    Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(past ? "\(date)（已过期）" : date)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 从当前 JQL 中提取「<field> = YYYY-MM-DD」中的日期
    private func currentDate(for field: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: field)
        let pattern = "\(escaped)\\s*=\\s*(\\d{4}-\\d{2}-\\d{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(jql.startIndex..., in: jql)
        guard let m = regex.firstMatch(in: jql, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: jql) else { return nil }
        return String(jql[r])
    }

    /// 将 JQL 中「<field> = 旧日期」替换为指定日期，未命中则前置插入，随后自动查询
    private func applyRegularVersion(_ date: String, field: String) {
        let escaped = NSRegularExpression.escapedPattern(for: field)
        let pattern = "\(escaped)\\s*=\\s*\\d{4}-\\d{2}-\\d{2}"
        let replacement = "\(field) = \(date)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(jql.startIndex..., in: jql)
            if regex.firstMatch(in: jql, range: range) != nil {
                jql = regex.stringByReplacingMatches(in: jql, range: range, withTemplate: replacement)
            } else {
                // 无匹配时前置插入，避免影响已有 ORDER BY 等子句
                jql = jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? replacement
                    : "\(replacement) AND \(jql)"
            }
        }
        runQuery()
    }

    /// 判断 yyyy-MM-dd 是否在今日之前
    private func isDatePast(_ date: String) -> Bool {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let d = fmt.date(from: date) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    private func runQuery() {
        let q = jql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isLoading = true
        errorMsg = ""
        Task {
            do {
                let result = try await JiraService.shared.searchJQL(q)
                await MainActor.run {
                    issues = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMsg = "❌ 查询失败: \(error.localizedDescription)"
                    issues = []
                    isLoading = false
                }
            }
        }
    }

    private func openInBrowser(_ key: String) {
        let base = AppConfig.shared.jiraURL
        let baseURL = base.hasSuffix("/") ? String(base.dropLast()) : base
        if let url = URL(string: "\(baseURL)/browse/\(key)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func toggleFavorite(_ key: String) {
        // 如果已收藏，则取消收藏；否则添加到收藏
        if let exist = favoriteService.favorites.first(where: { $0.key == key }) {
            favoriteService.removeFavorite(id: exist.id)
            statusMessage = "🗑️ 已取消收藏 \(key)"
            isStatusError = false
            return
        }
        favoritingKeys.insert(key)
        statusMessage = ""
        Task {
            do {
                _ = try await favoriteService.addFavorite(input: key)
                await MainActor.run {
                    favoritingKeys.remove(key)
                    statusMessage = "✅ 已添加 \(key) 到收藏"
                    isStatusError = false
                }
            } catch {
                await MainActor.run {
                    favoritingKeys.remove(key)
                    statusMessage = "❌ 收藏失败: \(error.localizedDescription)"
                    isStatusError = true
                }
            }
        }
    }
}
