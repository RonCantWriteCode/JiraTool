import SwiftUI
import AppKit

/// 创建 DC 页面（对应 C# DcCreateView.xaml）：
/// 扫描本地目录中 REQ- 开头的子目录，参考模板 DC 批量创建『生产数据配置变更申请』
struct DcCreateView: View {
    // 输入
    @AppStorage("dc_root_dir") private var rootDir: String = ""
    @AppStorage("dc_svn_base") private var svnBase: String = ""
    @AppStorage("dc_template_key") private var templateDcKey: String = "DC-6273"
    @AppStorage("dc_fixed_labels") private var fixedLabels: String = ""
    @AppStorage("dc_fixed_change_reason") private var fixedChangeReason: String = ""
    @AppStorage("dc_fixed_assignee") private var fixedAssignee: String = ""
    @AppStorage("dc_test_attach") private var testAttachPaths: String = ""

    // 扫描结果
    @State private var items: [DcItem] = []
    @State private var isScanning: Bool = false
    @State private var isCreating: Bool = false
    @State private var logs: String = ""
    @State private var lastCreatedKey: String = ""

    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "创建 DC",
                    subtitle: "扫描本地目录中 REQ- 开头的子目录，参考模板 DC 批量创建『生产数据配置变更申请』",
                    icon: "folder.badge.plus",
                    color: Color(red: 0x0E / 255.0, green: 0xA5 / 255.0, blue: 0xE9 / 255.0)
                )

                // 本地目录与模板
                CardSection(title: "本地目录与模板", icon: "folder", iconColor: .blue) {
                    HStack(spacing: 8) {
                        LabeledField(label: "本地目录", placeholder: "选择包含 REQ-xxxxx 子目录的根目录", text: $rootDir, labelWidth: 80)
                        Button(action: browseDir) {
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 11))
                                Text("选择目录...")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    LabeledField(label: "模板 DC", placeholder: "如 DC-123（用作字段参考；首次填入后自动保存）", text: $templateDcKey, labelWidth: 80)
                    LabeledField(label: "SVN前置地址", placeholder: "如 http://svn.sinosafe.com.cn:1580/svn/NEWPCIS/DC/2026（拼接目录名作为 SVN 地址；留空则用本地目录）", text: $svnBase, labelWidth: 80)
                    LabeledField(label: "变更原因", placeholder: "留空则复制模板 DC 的变更原因；填写后覆盖写入新建 DC", text: $fixedChangeReason, labelWidth: 80)
                    LabeledField(label: "标签", placeholder: "如『数据变更』，多个用英文逗号分隔", text: $fixedLabels, labelWidth: 80)
                    LabeledField(label: "经办人", placeholder: "登录账号", text: $fixedAssignee, labelWidth: 80)

                    HStack(spacing: 8) {
                        Text("测试附件").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).frame(width: 80, alignment: .leading)
                        Text(testAttachDisplay).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                        Button(action: browseTestFile) {
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.system(size: 11))
                                Text("选择文件...")
                            }
                        }.buttonStyle(.bordered)
                        Button(action: { testAttachPaths = "" }) {
                            Text("清除")
                        }.buttonStyle(.bordered)
                        .disabled(testAttachPaths.isEmpty)
                    }

                    HStack(spacing: 8) {
                        Button(action: scanAction) {
                            HStack(spacing: 5) {
                                if isScanning {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                                }
                                Text(isScanning ? "扫描中..." : "扫描目录")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isScanning || rootDir.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                }

                // 扫描结果
                CardSection(title: "扫描结果（摘要与变更内容可修改）", icon: "list.bullet.rectangle", iconColor: .orange) {
                    if items.isEmpty {
                        Text("尚未扫描。选择本地目录后点击『扫描目录』，将列出 REQ- 开头的子目录，并按文件名末尾的系统名拆分（每个系统一个 DC，摘要=目录名+系统名，变更内容汇总该系统文件）。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                DcItemRowView(item: item)
                                if item.id != items.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                // 执行
                CardSection(title: "执行", icon: "terminal", iconColor: .green) {
                    HStack(spacing: 8) {
                        Button(action: createAllAction) {
                            HStack(spacing: 5) {
                                if isCreating {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 11))
                                }
                                Text(isCreating ? "创建中..." : "批量创建 DC")
                            }
                            .frame(minWidth: 110)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)

                        Button(action: { logs = ""; lastCreatedKey = "" }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("清空")
                            }
                        }.disabled(logs.isEmpty)

                        if !lastCreatedKey.isEmpty {
                            Button(action: openCreatedIssue) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                                    Text("打开 \(lastCreatedKey)")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    LogView(logs: logs).frame(minHeight: 200)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            if templateDcKey.isEmpty {
                templateDcKey = "DC-6273"
            }
            if fixedAssignee.isEmpty {
                fixedAssignee = appConfig.jiraUser
            }
        }
    }

    // MARK: - Actions

    private func browseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择包含 REQ-xxxxx 子目录的本地根目录"
        if !rootDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: rootDir)
        }
        if panel.runModal() == .OK, let url = panel.url {
            rootDir = url.path
        }
    }

    private var testAttachDisplay: String {
        guard !testAttachPaths.isEmpty else { return "未选择" }
        let names = testAttachPaths
            .split(whereSeparator: { "\n\r;".contains($0) })
            .map { ($0.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent }
            .filter { !$0.isEmpty }
        return names.isEmpty ? "未选择" : names.joined(separator: "、")
    }

    private func browseTestFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "选择测试通过附件"
        if panel.runModal() == .OK {
            testAttachPaths = panel.urls.map { $0.path }.joined(separator: "\n")
        }
    }

    private func scanAction() {
        let dir = rootDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        isScanning = true
        let base = svnBase
        appendLog("开始扫描：\(dir)")

        Task {
            defer { Task { @MainActor in isScanning = false } }
            do {
                let scanned = try await Task.detached {
                    try DcService.shared.scanDirectory(dir, svnBase: base)
                }.value
                items = scanned
                appendLog("扫描完成：共 \(scanned.count) 个待创建 DC（已按文件名系统名拆分）")
            } catch {
                appendLog("[失败] 扫描目录失败：\(error.localizedDescription)")
            }
        }
    }

    private func createAllAction() {
        let tpl = templateDcKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tpl.isEmpty else {
            appendLog("[错误] 请先填写模板 DC Key")
            return
        }
        let selected = items.filter(\.isSelected)
        guard !selected.isEmpty else {
            appendLog("[错误] 请至少勾选一个要创建的目录")
            return
        }

        isCreating = true
        lastCreatedKey = ""
        for item in selected { item.status = "创建中..." }
        items = items
        appendLog("开始批量创建 DC（共 \(selected.count) 个）...")

        Task {
            defer { Task { @MainActor in isCreating = false } }
            do {
                let keys = try await DcService.shared.createFromItems(
                    templateDcKey: tpl,
                    items: selected,
                    fixedLabels: fixedLabels,
                    fixedAssignee: fixedAssignee,
                    extraAttachmentPaths: testAttachPaths,
                    fixedChangeReason: fixedChangeReason,
                    logger: { line in
                        Task { @MainActor in self.appendLog(line) }
                    }
                )
                await MainActor.run {
                    for item in selected {
                        item.status = item.lastCreatedKey.isEmpty ? "失败" : item.lastCreatedKey
                    }
                    items = items
                    if let last = keys.last {
                        lastCreatedKey = last
                        if keys.count == 1 { openCreatedIssue() }
                    }
                }
            } catch {
                appendLog("[失败] \(error.localizedDescription)")
                await MainActor.run {
                    for item in selected where item.status == "创建中..." { item.status = "失败" }
                    items = items
                }
            }
        }
    }

    private func openCreatedIssue() {
        guard !lastCreatedKey.isEmpty else { return }
        let base = appConfig.jiraURL.hasSuffix("/") ? String(appConfig.jiraURL.dropLast()) : appConfig.jiraURL
        if let url = URL(string: "\(base)/browse/\(lastCreatedKey)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private var canCreate: Bool {
        !isCreating
        && !templateDcKey.trimmingCharacters(in: .whitespaces).isEmpty
        && items.contains(where: \.isSelected)
    }

    private func appendLog(_ line: String) {
        let ts = DcDateFormatter.hhmmss.string(from: Date())
        logs += "[\(ts)] \(line)\n"
    }
}

private enum DcDateFormatter {
    static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 单个 DC 目录行

/// 一行 = 一个 REQ- 目录：勾选 + 摘要 + 变更内容 + 附件勾选 + 关联REQ + 状态
struct DcItemRowView: View {
    @ObservedObject var item: DcItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: $item.isSelected)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.directoryName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(item.reqKey)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(item.systemDisplay)
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    if !item.svnUrl.isEmpty {
                        Text("SVN: \(item.svnUrl)")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 150, alignment: .leading)

                TextField("摘要", text: $item.summary)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Toggle("关联REQ", isOn: $item.linkReq)
                    .font(.system(size: 11))

                Text(item.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(statusColor)
                    .frame(width: 90, alignment: .trailing)
            }

            HStack(alignment: .top, spacing: 10) {
                TextEditor(text: $item.descriptionText)
                    .font(.system(size: 11))
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 0.5)
                )

                // 附件勾选
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传附件")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item.files) { file in
                                DcFileToggleView(file: file)
                            }
                        }
                    }
                    .frame(maxWidth: 220, maxHeight: 80)
                }
                .frame(width: 230, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch item.status {
        case "失败": return .red
        case "待创建", "创建中...": return .secondary
        default: return .green
        }
    }
}

/// 单个附件文件勾选行（file 为 ObservableObject，需要独立子视图才能生成 $ 绑定）
struct DcFileToggleView: View {
    @ObservedObject var file: DcFileEntry

    var body: some View {
        Toggle(isOn: $file.selectedAsAttachment) {
            Text("\(file.name) (\(file.sizeDisplay))")
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .toggleStyle(.checkbox)
    }
}
