import SwiftUI
import AppKit

struct FavoriteView: View {
    @StateObject private var service = FavoriteService.shared
    @State private var inputText = ""
    @State private var searchText = ""
    @State private var isAdding = false
    @State private var statusMessage = ""
    @State private var isError = false
    @State private var refreshingIds: Set<String> = []
    @State private var detailItem: DetailSheetItem?
    @State private var showArchived = false
    @State private var isExporting = false
    @State private var isBatchMode = false
    private var filteredFavorites: [FavoriteJira] {
        // 先按归档状态过滤
        let byArchive = service.favorites.filter { $0.isArchived == showArchived }
        let base: [FavoriteJira]
        if searchText.isEmpty {
            base = byArchive
        } else {
            let query = searchText.lowercased()
            base = byArchive.filter {
                $0.key.lowercased().contains(query) ||
                $0.summary.lowercased().contains(query) ||
                $0.reporter.lowercased().contains(query) ||
                $0.assignee.lowercased().contains(query) ||
                $0.status.lowercased().contains(query) ||
                $0.issueType.lowercased().contains(query) ||
                $0.qianbaoNo.lowercased().contains(query)
            }
        }
        // 置顶的排在前面，多个置顶项按置顶时间倒序（最新置顶的在最上面）
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            // 如果都是置顶，按 pinnedAt 倒序排列（最新置顶的优先）
            if a.isPinned && b.isPinned {
                let dateA = a.pinnedAt ?? a.addedAt
                let dateB = b.pinnedAt ?? b.addedAt
                return dateA > dateB
            }
            return false
        }
    }

    private var archivedCount: Int {
        service.favorites.filter { $0.isArchived }.count
    }

    private var unarchivedCount: Int {
        service.favorites.filter { !$0.isArchived }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶部:添加收藏
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("收藏 Jira")
                        .font(.headline)
                                
                    Spacer()
                                
                    // 切换单行/批量模式
                    Button(action: { 
                        isBatchMode.toggle()
                        inputText = ""
                        statusMessage = ""
                    }) {
                        Label(
                            isBatchMode ? "单行添加" : "批量导入",
                            systemImage: isBatchMode ? "text.line.first" : "text.justify"
                        )
                    }
                    .buttonStyle(.borderless)
                }
                            
                if isBatchMode {
                    // 批量导入模式：多行文本框
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $inputText)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                                    
                        HStack {
                            Text("每行一个 Jira 编号或链接")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                                
                            Spacer()
                                                
                            Button(action: addFavorite) {
                                Text(isAdding ? "添加中..." : "批量添加")
                            }
                            .disabled(isAdding || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                    }
                } else {
                    // 单行添加模式：单行输入框 + 按钮
                    HStack(spacing: 8) {
                        TextField("输入 Jira 链接或编号，如 REQ-22411", text: $inputText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onSubmit { addFavorite() }
                                        
                        Button(action: addFavorite) {
                            Text(isAdding ? "添加中..." : "添加")
                        }
                        .disabled(isAdding || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .foregroundColor(isError ? .red : .green)
                        .font(.caption)
                }
            }
            .padding()

            Divider()

            // MARK: - 搜索栏 + 归档切换
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索收藏...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()

                // 归档切换
                Picker("", selection: $showArchived) {
                    Text("未归档 (\(unarchivedCount))").tag(false)
                    Text("已归档 (\(archivedCount))").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)

                Text("\(filteredFavorites.count) 条")
                    .foregroundColor(.secondary)
                    .font(.caption)

                // 导出按钮
                Button(action: exportToExcel) {
                    if isExporting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .help("导出当前列表为 Excel")
                .disabled(isExporting || filteredFavorites.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // MARK: - 收藏列表
            if service.favorites.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "star")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无收藏")
                        .foregroundColor(.secondary)
                    Text("输入 Jira 链接或编号来添加收藏")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Spacer()
            } else if filteredFavorites.isEmpty {
                Spacer()
                Text("没有匹配「\(searchText)」的收藏")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(filteredFavorites) { item in
                        FavoriteRow(
                            item: item,
                            isRefreshing: refreshingIds.contains(item.id),
                            onOpen: { openInBrowser(item) },
                            onCopyKey: { copyToClipboard(item.key) },
                            onRefresh: { refreshItem(item) },
                            onDelete: { service.removeFavorite(id: item.id) },
                            onTogglePin: { service.togglePin(id: item.id) },
                            onToggleArchive: { service.toggleArchive(id: item.id) },
                            onOpenQianbao: { openQianbaoLink(item) },
                            onShowDetail: {
                                detailItem = DetailSheetItem(issueKey: item.key)
                            }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("收藏 Jira")
        .overlay {
            if let item = detailItem {
                // 半透明遵罩，点击关闭弹窗
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        detailItem = nil
                    }
                
                // 详情弹窗内容
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

    private func addFavorite() {
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // 解析多行输入
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        isAdding = true
        statusMessage = ""
        
        Task {
            let result = await service.addFavoritesBatch(inputs: lines)
            
            await MainActor.run {
                var messages: [String] = []
                
                if !result.success.isEmpty {
                    messages.append("✅ 成功添加 \(result.success.count) 个收藏")
                }
                
                if !result.failed.isEmpty {
                    let failedDetails = result.failed.map { "\($0.input): \($0.error)" }.joined(separator: "\n")
                    messages.append("❌ 失败 \(result.failed.count) 个:\n\(failedDetails)")
                }
                
                statusMessage = messages.joined(separator: "\n")
                isError = result.failed.isEmpty ? false : (result.success.isEmpty ? true : false)
                inputText = ""
                isAdding = false
            }
        }
    }

    private func refreshItem(_ item: FavoriteJira) {
        refreshingIds.insert(item.id)
        Task {
            do {
                try await service.refreshFavorite(id: item.id)
                await MainActor.run {
                    refreshingIds.remove(item.id)
                    statusMessage = "✅ 已刷新 \(item.key)"
                    isError = false
                }
            } catch {
                await MainActor.run {
                    refreshingIds.remove(item.id)
                    statusMessage = "❌ 刷新失败: \(error.localizedDescription)"
                    isError = true
                }
            }
        }
    }

    private func openInBrowser(_ item: FavoriteJira) {
        if let url = URL(string: item.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openQianbaoLink(_ item: FavoriteJira) {
        if let url = URL(string: item.qianbaoLink) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "✅ 已复制: \(text)"
        isError = false
    }

    private func exportToExcel() {
        let panel = NSSavePanel()
        panel.title = "导出收藏 Jira 列表"
        panel.nameFieldStringValue = "收藏Jira_\(formattedNow()).xlsx"
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        statusMessage = ""
        let items = filteredFavorites
        Task {
            do {
                try await service.exportToExcel(items: items, outputPath: url.path)
                await MainActor.run {
                    statusMessage = "✅ 已导出 \(items.count) 条收藏到: \(url.lastPathComponent)"
                    isError = false
                    isExporting = false
                    // 导出后在 Finder 中显示
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    statusMessage = "❌ 导出失败: \(error.localizedDescription)"
                    isError = true
                    isExporting = false
                }
            }
        }
    }

    private func formattedNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

}

// MARK: - 收藏行视图

struct FavoriteRow: View {
    let item: FavoriteJira
    let isRefreshing: Bool
    let onOpen: () -> Void
    let onCopyKey: () -> Void
    let onRefresh: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onToggleArchive: () -> Void
    let onOpenQianbao: () -> Void
    let onShowDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 第一行：Key + 类型 + 状态
            HStack {
                Text(item.key)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                    .onTapGesture { onOpen() }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                StatusBadge(text: item.issueType, color: issueTypeColor)
                StatusBadge(text: item.status, color: statusColor)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                // 操作按钮
                HStack(spacing: 4) {
                    Button(action: onOpen) {
                        Image(systemName: "safari")
                            .help("在浏览器中打开")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onCopyKey) {
                        Image(systemName: "doc.on.doc")
                            .help("复制编号")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onRefresh) {
                        if isRefreshing {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .help("刷新信息")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRefreshing)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                            .help("删除收藏")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onTogglePin) {
                        Image(systemName: item.isPinned ? "pin.slash" : "pin")
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                            .help(item.isPinned ? "取消置顶" : "置顶")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onToggleArchive) {
                        Image(systemName: item.isArchived ? "tray.and.arrow.up" : "archivebox")
                            .foregroundColor(item.isArchived ? .green : .secondary)
                            .help(item.isArchived ? "取消归档" : "归档")
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            // 第二行：标题（点击弹出详情）
            Text(item.summary)
                .lineLimit(2)
                .onTapGesture { onShowDetail() }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

            // 第三行：详情信息 + 签报号（如果有）
            HStack(spacing: 12) {
                Label(item.reporter, systemImage: "person")
                Label(item.assignee, systemImage: "person.fill")
                if !item.updated.isEmpty {
                    Label(relativeUpdatedTime, systemImage: "clock")
                }
                if !item.qianbaoNo.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.badge.plus")
                            .font(.caption)
                        Text(item.qianbaoNo)
                            .lineLimit(1)
                    }
                    .onTapGesture { onOpenQianbao() }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .background(item.isPinned ? Color.orange.opacity(0.09) : Color.clear)
        .contextMenu {
            Button("在浏览器中打开") { onOpen() }
            Button("复制编号") { onCopyKey() }
            Button("刷新信息") { onRefresh() }
            Divider()
            Button(item.isPinned ? "取消置顶" : "置顶") { onTogglePin() }
            Button(item.isArchived ? "取消归档" : "归档") { onToggleArchive() }
            if !item.qianbaoLink.isEmpty {
                Button("打开签报") { onOpenQianbao() }
            }
            Button("删除", role: .destructive) { onDelete() }
        }
    }

    private var issueTypeColor: Color {
        // switch item.issueType {
        // case "需求", "求受理", "完善性需求", "需求受理": return .blue
        // case "内部测试": return .orange
        // case "缺陷", "Bug": return .red
        // case "任务": return .green
        // case "子任务": return .blue
        // default: return .gray
        // }

        let type = item.issueType
    
        if type.contains("需求") {
            return .blue
        } else if type.contains("测试") {
            return .orange
        } else if type.contains("缺陷") || type.contains("Bug") {
            return .red
        } else if type.contains("任务") {
            return .green
        } else if type.contains("子任务") {
            return .blue
        } else if type.contains("代理") {
            return .green
        }else {
            return .gray
        }
    }

    private var statusColor: Color {
        let s = item.status.lowercased()
        if s.contains("完成") || s.contains("关闭") || s.contains("done") || s.contains("closed") {
            return .green
        } else if s.contains("进行") || s.contains("处理") || s.contains("progress") {
            return .orange
        } else if s.contains("测试") || s.contains("testing") {
            return .yellow
        } else if s.contains("开发") || s.contains("development") {
            return .white
        } else if s.contains("待") || s.contains("open") || s.contains("todo") {
            return .blue
        }
        return .gray
    }

    /// 相对时间显示：超过2天按天/周/月/年前显示
    private var relativeUpdatedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = formatter.date(from: item.updated) else {
            return item.updated
        }

        let now = Date()
        let calendar = Calendar.current
        let diffSeconds = now.timeIntervalSince(date)
        let twoDays: TimeInterval = 2 * 24 * 60 * 60

        // 2天内显示原始时间
        if diffSeconds <= twoDays {
            return item.updated
        }

        let components = calendar.dateComponents([.year, .month, .day], from: date, to: now)

        if let years = components.year, years > 0 {
            return "\(years) 年前"
        } else if let months = components.month, months > 0 {
            return "\(months) 月前"
        } else if let days = components.day, days >= 7 {
            let weeks = days / 7
            return "\(weeks) 周前"
        } else if let days = components.day, days > 2 {
            return "\(days) 天前"
        } else {
            return item.updated
        }
    }
}

// MARK: - 状态标签组件

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.28))
            .foregroundColor(color.opacity(0.92))
            .cornerRadius(6)
    }
}
