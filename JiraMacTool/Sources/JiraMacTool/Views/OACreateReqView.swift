import SwiftUI

struct OACreateReqView: View {
    // 输入
    @State private var oaLink: String = ""
    @AppStorage("oa_template_req_key") private var templateReqKey: String = "REQ-23963"
    @AppStorage("oa_fixed_system_parent") private var fixedSystemParent: String = "核心条线"
    @AppStorage("oa_fixed_system_child") private var fixedSystemChild: String = "新一代非车险承保核心系统"
    @State private var systemChildOption: String = "新一代非车险承保核心系统"
    private let systemChildOptions = ["新一代非车险承保核心系统", "产品工厂", "自定义"]
    @AppStorage("oa_fixed_dev_version") private var fixedDevVersion: String = ""
    @AppStorage("oa_fixed_duty_dept") private var fixedDutyDept: String = "承保开发室"
    @AppStorage("oa_fixed_group_name") private var fixedGroupName: String = ""
    @AppStorage("oa_fixed_is_copy_req") private var fixedIsCopyReq: String = "否"
    @AppStorage("oa_fixed_is_complex_req") private var fixedIsComplexReq: String = "否"
    @AppStorage("oa_fixed_req_category") private var fixedReqCategory: String = "产品"
    @AppStorage("oa_fixed_is_pricing") private var fixedIsPricing: String = "是"
    @AppStorage("oa_fixed_labels") private var fixedLabels: String = "计价"
    @AppStorage("oa_fixed_assignee") private var fixedAssignee: String = ""

    // 解析结果（可编辑）
    @State private var title: String = ""
    @State private var drafter: String = ""
    @State private var draftDeptOriginal: String = ""
    @State private var draftDeptKeyword: String = ""
    @State private var branchCompany: String = ""
    @State private var applyNo: String = ""
    @State private var content: String = ""
    @State private var remText: String = ""
    @State private var attachments: [OAAttachment] = []
    @State private var attachmentSelection: [UUID: Bool] = [:]

    // 状态
    @State private var isParsing: Bool = false
    @State private var isCreating: Bool = false
    @State private var logs: String = ""
    @State private var createdKey: String = ""

    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "OA 创建 REQ",
                    subtitle: "根据 OA 签报链接自动解析并创建『系统需求』REQ",
                    icon: "link.badge.plus",
                    color: .orange
                )

                // 输入
                CardSection(title: "OA 链接", icon: "link", iconColor: .orange) {
                    LabeledField(
                        label: "OA 链接",
                        placeholder: "https://oa.sinosafe.com.cn/km/review/km_review_main/kmReviewMain.do?method=view&fdId=...",
                        text: $oaLink,
                        labelWidth: 80
                    )
                    LabeledField(
                        label: "模板 REQ",
                        placeholder: "如 REQ-12345（用作字段参考；首次填入后自动保存）",
                        text: $templateReqKey,
                        labelWidth: 80
                    )
                    HStack {
                        Button(action: parseAction) {
                            HStack(spacing: 5) {
                                if isParsing {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11))
                                }
                                Text(isParsing ? "解析中..." : "解析 OA 页面")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isParsing || oaLink.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                }

                // 解析后内容
                CardSection(title: "解析结果（可手工修正）", icon: "pencil.and.list.clipboard", iconColor: .blue) {
                    LabeledField(label: "标题", placeholder: "OA 标题", text: $title)
                    LabeledField(label: "拟稿人", placeholder: "OA 拟稿人", text: $drafter)
                    LabeledField(label: "拟稿部门(原)", placeholder: "OA 拟稿部门原文", text: $draftDeptOriginal)
                    LabeledField(label: "提交部门", placeholder: "如『重客渠道部』，需与 Jira 选项完全一致", text: $draftDeptKeyword)
                    LabeledField(label: "分公司", placeholder: "如『总公司』，将从 OA 自动解析", text: $branchCompany)
                    LabeledField(label: "申请单编号", placeholder: "作为签报号", text: $applyNo)
                    LabeledField(label: "REM 号", placeholder: "多个用英文逗号分隔，如 REM-123,REM-456", text: $remText)

                    HStack(alignment: .top, spacing: 8) {
                        Text("申请内容")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        TextEditor(text: $content)
                            .font(.system(size: 12))
                            .frame(minHeight: 120, maxHeight: 260)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 0.5)
                            )
                    }
                }

                // 附件选择
                CardSection(title: "OA 附件（勾选要上传的文件）", icon: "paperclip", iconColor: .purple) {
                    if attachments.isEmpty {
                        Text("暂无解析到的附件。点击解析后此处将展示 OA 中可下载的附件。")
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
                                            Text(att.url)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("签报链接")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .trailing)
                        Text(oaLink.isEmpty ? "(尚未填写 OA 链接)" : oaLink)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
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
            } else if systemChildOption == "新一代非车险承保核心系统" {
                // 保持用户之前保存的值，不强制清空
            }
        }
    }

    // MARK: - Actions

    private func parseAction() {
        let link = oaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        isParsing = true
        appendLog("开始解析：\(link)")

        Task {
            defer { Task { @MainActor in self.isParsing = false } }
            do {
                // 1) 抓取 OA 页面 HTML
                let html = try await OAService.shared.fetchHTML(urlString: link)
                let baseURL = extractBaseURL(link)

                // 2) 正则解析
                let parsed = OAParser.parse(html: html, baseURL: baseURL)

                // 3) 额外抓取审批日志 AJAX 以提取 REM 号
                var finalParsed = parsed
                if finalParsed.remKeys.isEmpty {
                    if let auditURL = buildAuditNoteURL(html: html, baseURL: baseURL) {
                        appendLog("[进度] 正在抓取审批日志...")
                        do {
                            let auditHTML = try await OAService.shared.fetchHTML(urlString: auditURL)
                            let extraREM = OAParser.extractREMFromAuditNotes(html: auditHTML)
                            if !extraREM.isEmpty {
                                finalParsed = OAParseResult(
                                    title: finalParsed.title,
                                    drafter: finalParsed.drafter,
                                    draftDept: finalParsed.draftDept,
                                    leadDept: finalParsed.leadDept,
                                    branchCompany: finalParsed.branchCompany,
                                    content: finalParsed.content,
                                    applyNo: finalParsed.applyNo,
                                    remKeys: extraREM,
                                    attachments: finalParsed.attachments
                                )
                                appendLog("[调试] 从审批日志提取到 REM: \(extraREM.joined(separator: ","))")
                            }

                            let auditAttachments = OAParser.parseAttachments(html: auditHTML, baseURL: baseURL)
                            if !auditAttachments.isEmpty {
                                let existingFdIds = Set(finalParsed.attachments.map { $0.fdId })
                                for att in auditAttachments {
                                    if !existingFdIds.contains(att.fdId) {
                                        finalParsed.attachments.append(att)
                                        appendLog("[调试] 从审批日志补充附件: \(att.name)")
                                    }
                                }
                            }
                        } catch {
                            appendLog("[调试] 审批日志抓取失败: \(error.localizedDescription)")
                        }
                    }
                }

                // 4) 更新 UI
                title = finalParsed.title
                drafter = finalParsed.drafter
                draftDeptOriginal = finalParsed.draftDept
                // 提交部门：优先使用总公司牵头部门，如果没有则从拟稿部门派生
                if !finalParsed.leadDept.isEmpty {
                    draftDeptKeyword = deriveDeptKeyword(finalParsed.leadDept)
                } else {
                    draftDeptKeyword = deriveDeptKeyword(finalParsed.draftDept)
                }
                branchCompany = deriveBranchCompany(finalParsed.draftDept)
                applyNo = finalParsed.applyNo
                content = finalParsed.content
                remText = finalParsed.remKeys.joined(separator: ",")
                attachments = finalParsed.attachments
                attachmentSelection = Dictionary(uniqueKeysWithValues: finalParsed.attachments.map { att in
                    let isSelected = !att.isTemplateAttachment
                    return (att.id, isSelected)
                })
                appendLog("解析完成：提交部门=\(draftDeptKeyword)；分公司=\(branchCompany)；REM=\(finalParsed.remKeys.joined(separator: ","))；附件 \(finalParsed.attachments.count) 个")
                if finalParsed.title.isEmpty && finalParsed.drafter.isEmpty && finalParsed.applyNo.isEmpty {
                    appendLog("[警告] 主要字段均为空，可能页面结构不匹配，请手工填写或联系开发优化解析规则。")
                }
            } catch {
                appendLog("[失败] \(error.localizedDescription)")
            }
        }
    }
    
    /// 构造审批日志（流程轨迹）AJAX URL，用于提取 REM
    private func buildAuditNoteURL(html: String, baseURL: String) -> String? {
        // 预处理：折叠 JS 多行字符串拼接 'xxx' + 'yyy' → 'xxxyyy'，以支持跨行 URL（与 C# 端对齐）
        let collapsed = html.replacingOccurrences(of: #"'\s*\+\s*'"#, with: "", options: .regularExpression)
        // 宽松匹配：允许 fdModelId / fdModelName / formBeanName 之间存在其他参数（与 C# 端对齐）
        let pattern = #"(?i)lbpmAuditNote\.do\?method=listNote[^"']*[&?]fdModelId=([a-f0-9]+)[^"'\s]*[&?]fdModelName=([^&"'\s]+)[^"'\s]*[&?]formBeanName=([^&"'\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = collapsed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: collapsed, options: [], range: range),
              match.numberOfRanges >= 4 else { return nil }
        let fdModelId = ns.substring(with: match.range(at: 1))
        let fdModelName = ns.substring(with: match.range(at: 2))
        let formBeanName = ns.substring(with: match.range(at: 3))
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(base)/sys/lbpmservice/support/lbpm_audit_note/lbpmAuditNote.do?method=listNote&fdModelId=\(fdModelId)&fdModelName=\(fdModelName)&formBeanName=\(formBeanName)&showPersonal=true&approveType="
    }

    /// 把抓到的 HTML 保存一份到用户 Documents/JiraMacTool/ 目录，方便调试解析规则
    private func dumpDebugHTML(html: String, link: String) -> String? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("JiraMacTool", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "oa_debug_\(fmt.string(from: Date())).html"
        let fileURL = dir.appendingPathComponent(fileName)
        // 头部加一行注释记录原始 URL，便于对照
        let withHeader = "<!-- source: \(link) -->\n" + html
        do {
            try withHeader.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private func createAction() {
        let link = oaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let tpl = templateReqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !tpl.isEmpty else { return }
        isCreating = true
        createdKey = ""
        appendLog("开始创建 REQ ...")

        let parsed = OAParseResult(
            title: title,
            drafter: drafter,
            draftDept: draftDeptOriginal,
            leadDept: "",  // 创建时使用空值，实际提交部门在 dept 参数中传递
            branchCompany: branchCompany,
            content: content,
            applyNo: applyNo,
            remKeys: remText
                .split(whereSeparator: { ",，; ；\n\t".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty },
            attachments: attachments
        )
        let picked = attachments.filter { (attachmentSelection[$0.id] ?? true) }
        let dept = draftDeptKeyword.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { Task { @MainActor in isCreating = false } }
            do {
                let key = try await OACreateReqService.shared.createFromOA(
                    oaLink: link,
                    templateReqKey: tpl,
                    parsed: parsed,
                    pickedAttachments: picked,
                    draftDeptKeyword: dept,
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
                    // 自动打开浏览器查看生成的 REQ
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
        && !oaLink.trimmingCharacters(in: .whitespaces).isEmpty
        && !templateReqKey.trimmingCharacters(in: .whitespaces).isEmpty
        && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.hhmmss.string(from: Date())
        logs += "[\(ts)] \(line)\n"
    }

    /// 从原始拟稿部门尝试抽一个部门关键字（用户仍可手工修改）
    /// 例：华安财产保险股份有限公司/总公司/重客渠道部/车商业务室 → 重客渠道部（倒数第二段）
    private func deriveDeptKeyword(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // 拆分常见分隔符
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "-/|>》> 　\\"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 取倒数第二段（如 重客渠道部/车商业务室 → 重客渠道部）
        if parts.count >= 2 { return parts[parts.count - 2] }
        // 只有一段就返回那一段
        return parts.last ?? trimmed
    }

    /// 从原始拟稿部门提取分公司（倒数第三段）
    /// 例：华安财产保险股份有限公司/总公司/重客渠道部/车商业务室 → 总公司（倒数第三段）
    private func deriveBranchCompany(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // 拆分常见分隔符（与 deriveDeptKeyword 保持一致）
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "-/|>》> \t \u{3000}\\"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 取倒数第三段（如 华安财产保险/总公司/重客渠道部/车商业务室 → 总公司）
        if parts.count >= 3 { return parts[parts.count - 3] }
        // 不足三段时返回空，让用户手工填写
        return ""
    }

    private func extractBaseURL(_ link: String) -> String {
        guard let u = URL(string: link), let host = u.host else { return link }
        // 强制使用 https（OA 服务器通常要求 HTTPS，HTTP 会 404 或重定向失败）
        let scheme = "https"
        if let port = u.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}


private extension DateFormatter {
    static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
