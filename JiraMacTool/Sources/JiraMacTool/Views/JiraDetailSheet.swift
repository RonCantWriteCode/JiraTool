import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

/// sheet(item:) 所需的 Identifiable 包装
struct DetailSheetItem: Identifiable {
    let id = UUID()
    let issueKey: String
}

/// 附件在线预览数据
struct AttachmentPreview: Identifiable {
    let id = UUID()
    let filename: String
    let mime: String
    let data: Data
    enum Kind { case image, text, pdf, richText }
    let kind: Kind
}

/// 待删除附件的目标（用于确认弹框）
struct AttachmentDeleteTarget: Identifiable {
    let id: String
    let filename: String
}

struct JiraDetailSheet: View {
    let issueKey: String
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var envDismiss
    @State private var isLoading = true
    @State private var errorMessage = ""
    @State private var issue: JiraIssue?
    @State private var comments: [[String: Any]] = []

    // 附件相关状态
    @State private var attachments: [[String: Any]] = []
    @State private var isDragTargeted = false
    @State private var isUploading = false
    @State private var uploadMessage = ""
    @State private var isUploadError = false
    @State private var downloadingIds: Set<String> = []

    // 在线预览状态
    @State private var previewItem: AttachmentPreview?
    @State private var previewingIds: Set<String> = []

    // 删除状态
    @State private var deletingIds: Set<String> = []
    @State private var pendingDelete: AttachmentDeleteTarget?

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                if let issue = issue {
                    Text(issue.key)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                        .onTapGesture { openInBrowser() }
                        .onHover { h in h ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    StatusBadge(text: issue.issueType, color: issueTypeColor(issue.issueType))
                    StatusBadge(text: issue.status, color: statusColor(issue.status))
                } else {
                    Text(issueKey)
                        .font(.title2)
                        .fontWeight(.bold)
                }
                Spacer()
                Button(action: { openInBrowser() }) {
                    Label("浏览器打开", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                Button("关闭") { dismissSheet() }
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView("正在获取 \(issueKey) 的详情...")
                Spacer()
            } else if !errorMessage.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Button("重试") { loadDetail() }
                }
                Spacer()
            } else if let issue = issue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 标题
                        Text(issue.summary)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                            .padding(.horizontal)

                        // 基本信息
                        detailSection("基本信息", icon: "info.circle") {
                            detailGrid(issue)
                        }

                        // 标签
                        if !issue.labels.isEmpty {
                            detailSection("标签", icon: "tag") {
                                FlowLayout(spacing: 6) {
                                    ForEach(issue.labels, id: \.self) { label in
                                        Text(label)
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.1))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }

                        // 自定义字段
                        detailSection("业务字段", icon: "list.bullet.rectangle") {
                            customFieldsView(issue)
                        }

                        // 签报信息（如果有）
                        let qianbaoNo = issue.fields["customfield_10115"] as? String ?? ""
                        let qianbaoLink = issue.fields["customfield_13252"] as? String ?? ""
                        if !qianbaoNo.isEmpty || !qianbaoLink.isEmpty {
                            detailSection("签报信息", icon: "doc.badge.plus") {
                                HStack(spacing: 4) {
                                    Text("签报号:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                    if !qianbaoNo.isEmpty {
                                        Text(qianbaoNo)
                                            .font(.callout)
                                            .fontWeight(.semibold)
                                            .textSelection(.enabled)
                                    }
                                }
                                if !qianbaoLink.isEmpty {
                                    HStack(spacing: 4) {
                                        Text("签报链接:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .frame(width: 60, alignment: .trailing)
                                        Link(qianbaoLink, destination: URL(string: qianbaoLink) ?? URL(string: "https://")!)
                                            .font(.callout)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        // 价值描述（如果有）
                        let valueDesc = issue.fields["customfield_12105"] as? String ?? ""
                        if !valueDesc.isEmpty {
                            detailSection("价值描述", icon: "sparkles") {
                                Text(valueDesc)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        // 描述 / 申请原因及需求内容描述
                        let desc = issue.fields["description"] as? String ?? ""
                        if !desc.isEmpty {
                            detailSection("申请原因及需求内容描述", icon: "doc.text") {
                                Text(desc)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        // 最近评论
                        if !comments.isEmpty {
                            detailSection("最近评论", icon: "bubble.left.and.bubble.right") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(comments.prefix(5).enumerated()), id: \.offset) { _, comment in
                                        commentView(comment)
                                    }
                                }
                            }
                        }

                        // 附件（始终显示，支持上传）
                        detailSection("附件", icon: "paperclip") {
                            attachmentsView()
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 650, minHeight: 500)
        .frame(maxWidth: 800, maxHeight: 700)
        .onAppear { loadDetail() }
        .sheet(item: $previewItem) { preview in
            AttachmentPreviewSheet(preview: preview)
        }
    }

    // MARK: - 关闭弹窗

    private func dismissSheet() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            envDismiss()
        }
    }

    // MARK: - 数据加载

    private func loadDetail() {
        isLoading = true
        errorMessage = ""
        Task {
            for attempt in 0...1 {
                do {
                    let fetched = try await JiraService.shared.getIssue(issueKey)
                    // 获取评论
                    let fetchedComments: [[String: Any]] = {
                        if let commentObj = fetched.fields["comment"] as? [String: Any],
                           let commentList = commentObj["comments"] as? [[String: Any]] {
                            return commentList
                        }
                        return []
                    }()
                    await MainActor.run {
                        self.issue = fetched
                        self.comments = fetchedComments
                        self.attachments = fetched.fields["attachment"] as? [[String: Any]] ?? []
                        self.isLoading = false
                    }
                    return // 成功则退出
                } catch {
                    if attempt == 0 {
                        // 首次失败等待后重试（可能是 session 初始化导致）
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    } else {
                        await MainActor.run {
                            self.errorMessage = error.localizedDescription
                            self.isLoading = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - 基本信息网格

    @ViewBuilder
    private func detailGrid(_ issue: JiraIssue) -> some View {
        let reporter = extractUser(issue.fields["reporter"])
        let assignee = extractUser(issue.fields["assignee"])
        let priority = extractName(issue.fields["priority"])
        let created = FavoriteJira.formatJiraDatePublic(issue.fields["created"] as? String ?? "")
        let updated = FavoriteJira.formatJiraDatePublic(issue.fields["updated"] as? String ?? "")
        let resolution = extractName(issue.fields["resolution"])

        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading)
        ], spacing: 10) {
            fieldRow("类型", issue.issueType)
            statusRow(issue.status)
            fieldRow("优先级", priority)
            fieldRow("解决结果", resolution.isEmpty ? "未解决" : resolution)
            fieldRow("报告人", reporter)
            fieldRow("经办人", assignee.isEmpty ? "未分配" : assignee)
            fieldRow("创建时间", created)
            fieldRow("更新时间", updated)
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    /// 状态行：带颜色标签，更醒目
    @ViewBuilder
    private func statusRow(_ status: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("状态:")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(status)
                .font(.callout)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor(status))
                .foregroundColor(statusTextColor(status))
                .cornerRadius(6)
        }
    }

    private func statusColor(_ status: String) -> Color {
        let s = status.lowercased()
        if s.contains("完成") || s.contains("关闭") || s.contains("done") || s.contains("closed") {
            return Color.green.opacity(0.2)
        } else if s.contains("进行") || s.contains("处理") || s.contains("progress") {
            return Color.orange.opacity(0.2)
        } else if s.contains("待") || s.contains("open") || s.contains("todo") {
            return Color.blue.opacity(0.2)
        }
        return Color.blue.opacity(0.2)
    }

    private func statusTextColor(_ status: String) -> Color {
        let s = status.lowercased()
        if s.contains("完成") || s.contains("关闭") || s.contains("done") || s.contains("closed") {
            return Color.green
        } else if s.contains("进行") || s.contains("处理") || s.contains("progress") {
            return Color.orange
        } else if s.contains("待") || s.contains("open") || s.contains("todo") {
            return Color.blue
        }
        return Color.blue
    }

    // MARK: - 自定义业务字段

    @ViewBuilder
    private func customFieldsView(_ issue: JiraIssue) -> some View {
        let developer = issue.fields["customfield_10123"] as? String ?? ""
        let systemName = extractSystemName(issue.fields["customfield_10125"])
        let versions = extractVersions(issue.fields["customfield_10126"])
        let testUser = extractTestUser(issue.fields["customfield_11915"] ?? issue.fields["customfield_10107"])
        let scheduleDateStr = extractScheduleDate(issue.fields["customfield_10919"])

        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading)
        ], spacing: 10) {
            if !systemName.isEmpty { fieldRow("系统名称", systemName) }
            if !developer.isEmpty { fieldRow("开发人员", developer) }
            if !testUser.isEmpty { fieldRow("测试人员", testUser) }
            if !versions.isEmpty { fieldRow("开发版本", versions) }
            if !scheduleDateStr.isEmpty { fieldRow("排期日期", scheduleDateStr) }
        }
    }

    // MARK: - 评论视图

    @ViewBuilder
    private func commentView(_ comment: [String: Any]) -> some View {
        let author = extractUser(comment["author"])
        let body = comment["body"] as? String ?? ""
        let created = FavoriteJira.formatJiraDatePublic(comment["created"] as? String ?? "")

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(author)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(created)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(body)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    // MARK: - Section 容器

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    // MARK: - 字段解析工具

    private func extractUser(_ field: Any?) -> String {
        if let dict = field as? [String: Any] {
            return dict["displayName"] as? String ?? dict["name"] as? String ?? ""
        }
        return ""
    }

    private func extractName(_ field: Any?) -> String {
        if let dict = field as? [String: Any] {
            return dict["name"] as? String ?? dict["value"] as? String ?? ""
        }
        if let str = field as? String { return str }
        return ""
    }

    private func extractSystemName(_ field: Any?) -> String {
        if let dict = field as? [String: Any] {
            if let child = dict["child"] as? [String: Any],
               let childValue = child["value"] as? String {
                return childValue
            }
            return dict["value"] as? String ?? ""
        }
        if let str = field as? String { return str }
        return ""
    }

    private func extractVersions(_ field: Any?) -> String {
        if let arr = field as? [[String: Any]] {
            return arr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        return ""
    }

    private func extractTestUser(_ field: Any?) -> String {
        if let str = field as? String { return str }
        if let dict = field as? [String: Any] {
            return dict["displayName"] as? String ?? dict["name"] as? String ?? ""
        }
        if let arr = field as? [[String: Any]] {
            return arr.compactMap { $0["displayName"] as? String ?? $0["name"] as? String }.joined(separator: ", ")
        }
        return ""
    }

    private func extractScheduleDate(_ field: Any?) -> String {
        if let str = field as? String {
            return FavoriteJira.formatJiraDatePublic(str)
        }
        if let dict = field as? [String: Any], let val = dict["value"] as? String {
            return val
        }
        return ""
    }

    private func openInBrowser() {
        let config = AppConfig.shared
        let baseURL = config.jiraURL.hasSuffix("/") ? String(config.jiraURL.dropLast()) : config.jiraURL
        if let url = URL(string: "\(baseURL)/browse/\(issueKey)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func issueTypeColor(_ type: String) -> Color {
        switch type {
        case "需求": return .blue
        case "缺陷", "Bug": return .red
        case "任务": return .orange
        case "子任务": return .purple
        default: return .gray
        }
    }

    // MARK: - 附件视图

    @ViewBuilder
    private func attachmentsView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 附件列表
            if attachments.isEmpty {
                Text("暂无附件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { _, att in
                        attachmentRow(att)
                    }
                }
            }

            // 上传区：拖拽 / 选择 / 粘贴
            uploadDropZone()

            // 状态提示
            if !uploadMessage.isEmpty {
                Text(uploadMessage)
                    .font(.caption)
                    .foregroundColor(isUploadError ? .red : .green)
            }
        }
        .confirmationDialog(
            "删除附件",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("删除", role: .destructive) {
                performDeleteAttachment(id: target.id, filename: target.filename)
            }
            Button("取消", role: .cancel) { }
        } message: { target in
            Text("确定要删除附件「\(target.filename)」吗？此操作不可撤销。")
        }
    }

    @ViewBuilder
    private func attachmentRow(_ att: [String: Any]) -> some View {
        let id = att["id"] as? String ?? ""
        let filename = att["filename"] as? String ?? "(unnamed)"
        let size = att["size"] as? Int ?? 0
        let mime = att["mimeType"] as? String ?? ""
        let author = extractUser(att["author"])
        let created = FavoriteJira.formatJiraDatePublic(att["created"] as? String ?? "")
        let content = att["content"] as? String ?? ""
        let isDownloading = downloadingIds.contains(id)

        HStack(spacing: 8) {
            Image(systemName: iconForMime(mime, filename: filename))
                .foregroundColor(.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                // 文件名：可预览的类型可点击查看
                let kind = previewKind(mime: mime, filename: filename)
                if let kind = kind, !content.isEmpty {
                    HStack(spacing: 6) {
                        Text(filename)
                            .font(.callout)
                            .foregroundColor(.accentColor)
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                openPreview(id: id, url: content, filename: filename, mime: mime, kind: kind)
                            }
                            .onHover { h in h ? NSCursor.pointingHand.push() : NSCursor.pop() }
                        if previewingIds.contains(id) {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        }
                    }
                } else {
                    Text(filename)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Text(formatBytes(size))
                    if !author.isEmpty { Text("· \(author)") }
                    if !created.isEmpty { Text("· \(created)") }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer()
            if isDownloading {
                ProgressView().scaleEffect(0.55).frame(width: 20, height: 20)
            } else {
                Button {
                    downloadAttachment(id: id, url: content, filename: filename)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("下载到本地")
                .disabled(content.isEmpty)

                Button {
                    if let url = URL(string: content) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("在浏览器打开")
                .disabled(content.isEmpty)

                if deletingIds.contains(id) {
                    ProgressView().scaleEffect(0.55).frame(width: 20, height: 20)
                } else {
                    Button {
                        pendingDelete = AttachmentDeleteTarget(id: id, filename: filename)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除附件")
                    .foregroundColor(.red)
                    .disabled(id.isEmpty)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func uploadDropZone() -> some View {
        VStack(spacing: 6) {
            if isUploading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("正在上传...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: isDragTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.title3)
                    .foregroundColor(isDragTargeted ? .accentColor : .secondary)
                Text("拖拽文件到此处上传，或点击下方按钮")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button {
                        chooseFile()
                    } label: {
                        Label("选择文件", systemImage: "folder")
                    }
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("粘贴 ⌘V", systemImage: "doc.on.clipboard")
                    }
                    .keyboardShortcut("v", modifiers: .command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDragTargeted ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - 附件上传 / 下载逻辑

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                uploadFileURL(url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        // file URL 通常以 UTF-8 字符串形式编码
                        if let str = String(data: data, encoding: .utf8),
                           let u = URL(string: str) {
                            url = u
                        } else {
                            url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                        }
                    } else if let u = item as? URL {
                        url = u
                    }
                    if let url = url {
                        DispatchQueue.main.async {
                            uploadFileURL(url)
                        }
                    }
                }
            }
        }
        return handled
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general

        // 1) 文件 URL
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls { uploadFileURL(url) }
            return
        }
        // 2) PNG 原始数据
        if let png = pb.data(forType: NSPasteboard.PasteboardType("public.png")) {
            let name = "clipboard_\(timestampName()).png"
            uploadBytes(data: png, filename: name, mime: "image/png")
            return
        }
        // 3) TIFF 转 PNG
        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff),
           let png = pngData(from: img) {
            let name = "clipboard_\(timestampName()).png"
            uploadBytes(data: png, filename: name, mime: "image/png")
            return
        }
        // 4) 纯文本
        if let text = pb.string(forType: .string), !text.isEmpty,
           let data = text.data(using: .utf8) {
            let name = "clipboard_\(timestampName()).txt"
            uploadBytes(data: data, filename: name, mime: "text/plain")
            return
        }
        uploadMessage = "⚠️ 剪贴板没有可上传的文件、图片或文本"
        isUploadError = true
    }

    private func uploadFileURL(_ url: URL) {
        do {
            // 处理安全作用域（用户选择的文件）
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let mime = mimeType(forExtension: url.pathExtension)
            uploadBytes(data: data, filename: url.lastPathComponent, mime: mime)
        } catch {
            uploadMessage = "❌ 读取文件失败：\(error.localizedDescription)"
            isUploadError = true
        }
    }

    private func uploadBytes(data: Data, filename: String, mime: String) {
        guard !isUploading else { return }
        isUploading = true
        uploadMessage = ""
        isUploadError = false
        Task {
            do {
                try await JiraService.shared.uploadAttachment(
                    issueKey: issueKey, fileName: filename, fileData: data, mimeType: mime
                )
                // 重新拉取附件列表
                let fresh = try await JiraService.shared.getAttachments(issueKey: issueKey)
                await MainActor.run {
                    self.attachments = fresh
                    self.isUploading = false
                    self.uploadMessage = "✅ 已上传 \(filename)"
                    self.isUploadError = false
                }
            } catch {
                await MainActor.run {
                    self.isUploading = false
                    self.uploadMessage = "❌ 上传失败：\(error.localizedDescription)"
                    self.isUploadError = true
                }
            }
        }
    }

    private func downloadAttachment(id: String, url: String, filename: String) {
        guard !url.isEmpty else { return }
        downloadingIds.insert(id)
        Task {
            do {
                let data = try await JiraService.shared.downloadAttachmentData(urlString: url)
                await MainActor.run {
                    saveDownloadedFile(data: data, suggestedName: filename)
                    downloadingIds.remove(id)
                }
            } catch {
                await MainActor.run {
                    downloadingIds.remove(id)
                    uploadMessage = "❌ 下载失败：\(error.localizedDescription)"
                    isUploadError = true
                }
            }
        }
    }

    private func saveDownloadedFile(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                try data.write(to: targetURL)
                uploadMessage = "✅ 已保存到 \(targetURL.path)"
                isUploadError = false
            } catch {
                uploadMessage = "❌ 保存失败：\(error.localizedDescription)"
                isUploadError = true
            }
        }
    }

    /// 实际执行附件删除（确认弹框点击「删除」后调用）
    private func performDeleteAttachment(id: String, filename: String) {
        guard !id.isEmpty else { return }
        deletingIds.insert(id)
        uploadMessage = ""
        Task {
            do {
                try await JiraService.shared.deleteAttachment(id: id)
                await MainActor.run {
                    // 从本地列表即时移除，提升响应感
                    attachments.removeAll { ($0["id"] as? String) == id }
                    deletingIds.remove(id)
                    uploadMessage = "✅ 已删除附件：\(filename)"
                    isUploadError = false
                }
            } catch {
                await MainActor.run {
                    deletingIds.remove(id)
                    uploadMessage = "❌ 删除失败：\(error.localizedDescription)"
                    isUploadError = true
                }
            }
        }
    }

    // MARK: - 辅助函数

    private func iconForMime(_ mime: String, filename: String) -> String {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "video" }
        if m.hasPrefix("audio/") { return "music.note" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.contains("zip") || m.contains("compressed") || m.contains("tar") { return "doc.zipper" }
        if m.contains("sheet") || m.contains("excel") || filename.hasSuffix(".xlsx") || filename.hasSuffix(".xls") { return "tablecells" }
        if m.contains("word") || filename.hasSuffix(".docx") || filename.hasSuffix(".doc") { return "doc.text" }
        if m.contains("presentation") || filename.hasSuffix(".pptx") || filename.hasSuffix(".ppt") { return "rectangle.stack" }
        if m.contains("text") { return "doc.plaintext" }
        return "doc"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    private func mimeType(forExtension ext: String) -> String {
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func timestampName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
    }

    // MARK: - 在线预览

    /// 判断附件是否可在线预览，返回预览类型
    private func previewKind(mime: String, filename: String) -> AttachmentPreview.Kind? {
        let m = mime.lowercased()
        let name = filename.lowercased()
        // 图片
        if m.hasPrefix("image/") { return .image }
        let imgExts = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".webp", ".heic"]
        if imgExts.contains(where: { name.hasSuffix($0) }) { return .image }

        // PDF
        if m.contains("pdf") || name.hasSuffix(".pdf") { return .pdf }

        // Word / RTF
        if m.contains("msword") || m.contains("officedocument.wordprocessing") ||
           m.contains("rtf") ||
           name.hasSuffix(".doc") || name.hasSuffix(".docx") || name.hasSuffix(".rtf") {
            return .richText
        }

        // 纯文本
        if m.hasPrefix("text/") || m.contains("json") || m.contains("xml") || m.contains("javascript") {
            return .text
        }
        let textExts = [
            ".txt", ".sql", ".log", ".md", ".markdown", ".json", ".xml", ".yml", ".yaml",
            ".csv", ".tsv", ".ini", ".conf", ".properties",
            ".java", ".kt", ".swift", ".py", ".js", ".ts", ".tsx", ".jsx",
            ".go", ".rs", ".c", ".h", ".cpp", ".hpp", ".cs", ".rb", ".php",
            ".sh", ".bash", ".zsh", ".bat", ".ps1",
            ".html", ".htm", ".css", ".scss", ".less"
        ]
        if textExts.contains(where: { name.hasSuffix($0) }) { return .text }
        return nil
    }

    private func openPreview(id: String, url: String, filename: String, mime: String, kind: AttachmentPreview.Kind) {
        guard !url.isEmpty else { return }
        previewingIds.insert(id)
        Task {
            do {
                let data = try await JiraService.shared.downloadAttachmentData(urlString: url)
                await MainActor.run {
                    previewingIds.remove(id)
                    previewItem = AttachmentPreview(filename: filename, mime: mime, data: data, kind: kind)
                }
            } catch {
                await MainActor.run {
                    previewingIds.remove(id)
                    uploadMessage = "❌ 预览失败：\(error.localizedDescription)"
                    isUploadError = true
                }
            }
        }
    }
}
