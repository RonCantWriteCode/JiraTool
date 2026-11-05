import SwiftUI
import UniformTypeIdentifiers

struct EmailCreateReqView: View {
    // 输入
    @State private var emlFilePath: String = ""
    @AppStorage("email_template_req_key") private var templateReqKey: String = "REQ-23963"
    @AppStorage("email_fixed_system_parent") private var fixedSystemParent: String = "核心条线"
    @AppStorage("email_fixed_system_child") private var fixedSystemChild: String = "产品工厂"
    @State private var systemChildOption: String = "产品工厂"
    private let systemChildOptions = ["新一代非车险承保核心系统", "产品工厂", "自定义"]
    @AppStorage("email_fixed_dev_version") private var fixedDevVersion: String = "即时版本（脚本）"
    @AppStorage("email_fixed_duty_dept") private var fixedDutyDept: String = "承保开发室"
    @AppStorage("email_fixed_group_name") private var fixedGroupName: String = ""
    @AppStorage("email_fixed_is_copy_req") private var fixedIsCopyReq: String = "否"
    @AppStorage("email_fixed_is_complex_req") private var fixedIsComplexReq: String = "否"
    @AppStorage("email_fixed_req_category") private var fixedReqCategory: String = "产品"
    @AppStorage("email_fixed_is_pricing") private var fixedIsPricing: String = "是"
    @AppStorage("email_fixed_labels") private var fixedLabels: String = "计价"
    @AppStorage("email_fixed_assignee") private var fixedAssignee: String = ""

    // 解析结果（可编辑）
    @State private var title: String = ""
    @State private var sender: String = ""
    @State private var senderEmail: String = ""
    @State private var draftDept: String = ""
    @State private var branchCompany: String = ""
    @State private var content: String = ""
    @State private var attachments: [EmailAttachmentInfo] = []
    @State private var attachmentSelection: [UUID: Bool] = [:]

    // 状态
    @State private var isCreating: Bool = false
    @State private var logs: String = ""
    @State private var createdKey: String = ""
    @State private var parsedEmail: EmailParseResult?

    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "邮件创建 REQ",
                    subtitle: "根据邮件内容（.eml 文件）解析并创建『系统需求』REQ",
                    icon: "envelope.badge",
                    color: .blue
                )

                // 邮件文件选择
                CardSection(title: "邮件文件", icon: "envelope", iconColor: .blue) {
                    LabeledField(
                        label: "EML 文件",
                        placeholder: "点击右侧按钮选择 .eml 邮件文件",
                        text: $emlFilePath,
                        labelWidth: 80
                    )
                    HStack {
                        Button(action: browseFile) {
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 11))
                                Text("选择文件...")
                            }
                        }
                        .buttonStyle(.bordered)

                        Button(action: parseAction) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11))
                                Text("解析邮件")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(emlFilePath.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                }

                // 模板 REQ
                CardSection(title: "模板配置", icon: "doc.template", iconColor: .orange) {
                    LabeledField(
                        label: "模板 REQ",
                        placeholder: "如 REQ-12345（用作字段参考；首次填入后自动保存）",
                        text: $templateReqKey,
                        labelWidth: 80
                    )
                }

                // 解析后内容
                CardSection(title: "解析结果（可手工修正）", icon: "pencil.and.list.clipboard", iconColor: .blue) {
                    LabeledField(label: "标题", placeholder: "邮件标题（Subject）", text: $title)
                    LabeledField(label: "发件人", placeholder: "邮件发件人（From）", text: $sender)
                    LabeledField(label: "发件人邮箱", placeholder: "发件人邮箱地址", text: $senderEmail)
                    LabeledField(label: "提交部门", placeholder: "如『重客渠道部』，需与 Jira 选项完全一致", text: $draftDept)
                    LabeledField(label: "分公司", placeholder: "如『总公司』，邮件中无法自动解析", text: $branchCompany)

                    HStack(alignment: .top, spacing: 8) {
                        Text("邮件正文")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        TextEditor(text: $content)
                            .font(.system(size: 12))
                            .frame(minHeight: 140, maxHeight: 280)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 0.5)
                            )
                    }
                }

                // 附件选择
                CardSection(title: "邮件附件（勾选要上传的文件）", icon: "paperclip", iconColor: .purple) {
                    if attachments.isEmpty {
                        Text("暂无解析到的附件。点击解析后此处将展示邮件中的附件。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(attachments) { att in
                                HStack {
                                    Toggle(isOn: Binding<Bool>(
                                        get: { attachmentSelection[att.id] ?? true },
                                        set: { attachmentSelection[att.id] = $0 }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(att.name).font(.system(size: 12))
                                            Text(formatSize(att.data.count))
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                // 固定字段（可修改，自动保存）
                CardSection(title: "将写入的固定字段（可修改，自动保存）", icon: "pencil", iconColor: .gray) {
                    Group {
                        LabeledField(label: "系统名称（父级）", placeholder: "如『核心条线』", text: $fixedSystemParent, labelWidth: 120)
                        HStack(spacing: 8) {
                            Text("系统名称（子级）")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 120, alignment: .trailing)
                            HStack(spacing: 12) {
                                ForEach(systemChildOptions, id: \.self) { option in
                                    Button(action: {
                                        systemChildOption = option
                                        if option != "自定义" {
                                            fixedSystemChild = option
                                        }
                                        // 根据选项设置开发版本号默认值
                                        if option == "产品工厂" {
                                            fixedDevVersion = "即时版本（脚本）"
                                        } else if option == "新一代非车险承保核心系统" {
                                            fixedDevVersion = ""
                                        }
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: systemChildOption == option ? "largecircle.fill.circle" : "circle")
                                                .foregroundColor(systemChildOption == option ? .accentColor : .secondary)
                                            Text(option)
                                                .font(.system(size: 12))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            TextField("或手工输入", text: $fixedSystemChild)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                        LabeledField(label: "开发版本号", placeholder: "如『即时版本（脚本）』，允许修改", text: $fixedDevVersion, labelWidth: 120)
                        LabeledField(label: "责任科室", placeholder: "如『承保开发室』", text: $fixedDutyDept, labelWidth: 120)
                        LabeledField(label: "科室小组", placeholder: "留空则复制模板值", text: $fixedGroupName, labelWidth: 120)
                        LabeledField(label: "是否复制需求", placeholder: "如『否』", text: $fixedIsCopyReq, labelWidth: 120)
                        LabeledField(label: "是否复杂需求", placeholder: "如『否』", text: $fixedIsComplexReq, labelWidth: 120)
                        LabeledField(label: "需求分类", placeholder: "如『产品』", text: $fixedReqCategory, labelWidth: 120)
                        LabeledField(label: "是否计价", placeholder: "如『是』", text: $fixedIsPricing, labelWidth: 120)
                        LabeledField(label: "标签", placeholder: "如『计价』，多个用英文逗号分隔", text: $fixedLabels, labelWidth: 120)
                    }
                    LabeledField(label: "经办人", placeholder: "登录账号", text: $fixedAssignee, labelWidth: 120)
                }

                // 执行
                CardSection(title: "执行", icon: "terminal", iconColor: .green) {
                    HStack(spacing: 8) {
                        Button(action: createAction) {
                            HStack(spacing: 5) {
                                if isCreating {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 11))
                                }
                                Text(isCreating ? "创建中..." : "创建 REQ")
                            }
                            .frame(minWidth: 100)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)

                        Button(action: { logs = ""; createdKey = "" }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("清空")
                            }
                        }.disabled(logs.isEmpty)

                        if !createdKey.isEmpty {
                            Button(action: { openCreatedIssue() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                                    Text("打开 \(createdKey)")
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
        .frame(minWidth: 620, minHeight: 500)
        .onAppear {
            // 同步单选按钮状态与保存的系统名称子级值
            if systemChildOptions.contains(fixedSystemChild) {
                systemChildOption = fixedSystemChild
            } else if !fixedSystemChild.isEmpty {
                systemChildOption = "自定义"
            }
            // 根据单选按钮同步开发版本号
            if systemChildOption == "产品工厂" && fixedDevVersion.isEmpty {
                fixedDevVersion = "即时版本（脚本）"
            }
            // 初始化经办人默认值
            if fixedAssignee.isEmpty {
                let oaAssignee = UserDefaults.standard.string(forKey: "oa_fixed_assignee") ?? ""
                if !oaAssignee.isEmpty {
                    fixedAssignee = oaAssignee
                } else {
                    fixedAssignee = appConfig.jiraUser
                }
            }
            // 初始化模板 REQ
            if templateReqKey == "REQ-23963" {
                let oaTemplate = UserDefaults.standard.string(forKey: "oa_template_req_key") ?? ""
                if !oaTemplate.isEmpty {
                    templateReqKey = oaTemplate
                }
            }
        }
    }

    // MARK: - Actions

    private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择邮件文件"

        if panel.runModal() == .OK, let url = panel.url {
            emlFilePath = url.path
        }
    }

    private func parseAction() {
        let filePath = emlFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filePath.isEmpty else { return }

        appendLog("开始解析邮件：\(filePath)")

        do {
            let parsed = try EmailParser.parse(fromFile: filePath)
            parsedEmail = parsed

            title = parsed.subject
            sender = parsed.fromName
            senderEmail = parsed.from
            content = parsed.body
            attachments = parsed.attachments
            attachmentSelection = Dictionary(uniqueKeysWithValues: parsed.attachments.map { att in
                (att.id, true)
            })

            appendLog("解析完成：标题=\(parsed.subject)；发件人=\(parsed.fromName)；邮箱=\(parsed.from)；附件 \(parsed.attachments.count) 个")
            if parsed.subject.isEmpty && parsed.fromName.isEmpty {
                appendLog("[警告] 主要字段为空，请手工填写或检查邮件文件格式。")
            }
        } catch {
            appendLog("[失败] 解析邮件失败：\(error.localizedDescription)")
        }
    }

    private func createAction() {
        let tpl = templateReqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tpl.isEmpty else {
            appendLog("[错误] 请先填写模板 REQ")
            return
        }
        guard parsedEmail != nil else {
            appendLog("[错误] 请先解析邮件")
            return
        }
        isCreating = true
        createdKey = ""
        appendLog("开始创建 REQ ...")

        // 构造 OAParseResult 以复用 OACreateReqService
        let parsed = OAParseResult(
            title: title,
            drafter: sender,
            draftDept: "",
            leadDept: "",
            branchCompany: branchCompany,
            content: content,
            applyNo: "",
            remKeys: [],
            attachments: []
        )

        // 获取勾选的附件
        let pickedAttachments = attachments.filter { attachmentSelection[$0.id] ?? true }

        // 签报链接使用发件人邮箱作为标识
        let oaLink = "mailto:\(senderEmail)"

        Task {
            defer { Task { @MainActor in isCreating = false } }
            do {
                let key = try await OACreateReqService.shared.createFromOA(
                    oaLink: oaLink,
                    templateReqKey: tpl,
                    parsed: parsed,
                    pickedAttachments: [], // 邮件附件不走 OA 下载流程
                    draftDeptKeyword: draftDept,
                    fixedSystemParent: fixedSystemParent,
                    fixedSystemChild: fixedSystemChild,
                    fixedDevVersion: fixedDevVersion,
                    fixedDutyDept: fixedDutyDept,
                    fixedGroupName: fixedGroupName,
                    fixedIsCopyReq: fixedIsCopyReq,
                    fixedIsComplexReq: fixedIsComplexReq,
                    fixedReqCategory: fixedReqCategory,
                    fixedIsPricing: fixedIsPricing,
                    fixedLabels: fixedLabels,
                    fixedAssignee: fixedAssignee,
                    logger: { line in
                        Task { @MainActor in self.appendLog(line) }
                    }
                )

                await MainActor.run {
                    self.createdKey = key
                    self.appendLog("[完成] 新 REQ：\(key)")
                }

                // 上传邮件附件（直接上传本地数据，不走 OA 下载）
                if !pickedAttachments.isEmpty {
                    appendLog("上传邮件附件 \(pickedAttachments.count) 个 ...")
                    for att in pickedAttachments {
                        do {
                            try await JiraService.shared.uploadAttachment(
                                issueKey: key,
                                fileName: att.name,
                                fileData: att.data,
                                mimeType: att.mimeType
                            )
                            appendLog("  ✓ 已上传: \(att.name)")
                        } catch {
                            appendLog("  ✗ 附件失败 [\(att.name)]: \(error.localizedDescription)")
                        }
                    }
                }

                await MainActor.run {
                    self.openCreatedIssue()
                }
            } catch {
                appendLog("[失败] 创建 REQ 失败：\(error.localizedDescription)")
            }
        }
    }

    private func openCreatedIssue() {
        let base = appConfig.jiraURL.hasSuffix("/") ? String(appConfig.jiraURL.dropLast()) : appConfig.jiraURL
        if let url = URL(string: "\(base)/browse/\(createdKey)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Logic helpers

    private var canCreate: Bool {
        !isCreating
        && !templateReqKey.trimmingCharacters(in: .whitespaces).isEmpty
        && parsedEmail != nil
        && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.hhmmss.string(from: Date())
        logs += "[\(ts)] \(line)\n"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}

private extension DateFormatter {
    static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
