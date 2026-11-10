import SwiftUI

struct OAProcessCompleteView: View {
    // 输入
    @State private var oaLink: String = ""
    @AppStorage("oa_process_complete_operator") private var operatorName: String = "吴润龙"

    // 解析结果
    @State private var reqNumber: String = ""
    @State private var relatedREQ: String = ""

    // 状态
    @State private var isParsing: Bool = false
    @State private var isDownloadingPDF: Bool = false
    @State private var logs: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "OA 流程完成",
                    subtitle: "解析 OA 审批流程中的 REQ 需求号",
                    icon: "checkmark.circle",
                    color: .green
                )

                // 输入区
                CardSection(title: "输入", icon: "link", iconColor: .green) {
                    LabeledField(
                        label: "OA 链接",
                        placeholder: "https://oa.sinosafe.com.cn/km/review/...",
                        text: $oaLink,
                        labelWidth: 80
                    )
                    LabeledField(
                        label: "操作人",
                        placeholder: "审核意见中的操作人姓名",
                        text: $operatorName,
                        labelWidth: 80
                    )
                    LabeledField(
                        label: "REQ",
                        placeholder: "解析到的 REQ 需求号（可手动修改）",
                        text: $reqNumber,
                        labelWidth: 80
                    )
                    LabeledField(
                        label: "关联REQ",
                        placeholder: "其他关联的 REQ 编号，逗号分隔（可空）",
                        text: $relatedREQ,
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
                                Text(isParsing ? "解析中..." : "OA解析REQ")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isParsing || oaLink.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button(action: downloadPDFAndUploadAction) {
                            HStack(spacing: 5) {
                                if isDownloadingPDF {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.up.doc").font(.system(size: 11))
                                }
                                Text(isDownloadingPDF ? "上传中..." : "下载PDF上传REQ")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isDownloadingPDF || isParsing || reqNumber.trimmingCharacters(in: .whitespaces).isEmpty || oaLink.trimmingCharacters(in: .whitespaces).isEmpty)

                        Spacer()
                    }
                }

                // 日志区
                CardSection(title: "日志", icon: "terminal", iconColor: .gray) {
                    HStack {
                        Button(action: { logs = "" }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("清空")
                            }
                        }.disabled(logs.isEmpty)
                        Spacer()
                    }
                    LogView(logs: logs).frame(minHeight: 200)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 400)
    }

    // MARK: - Actions

    private func parseAction() {
        let link = oaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        let opName = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opName.isEmpty else {
            appendLog("[警告] 操作人姓名为空，请输入")
            return
        }
        isParsing = true
        appendLog("开始解析：\(link)，操作人：\(opName)")

        Task {
            defer { Task { @MainActor in isParsing = false } }
            do {
                // 1. 抓取主页面 HTML
                let html = try await OAService.shared.fetchHTML(urlString: link)
                if let dumpPath = dumpDebugHTML(html: html, link: link) {
                    await MainActor.run { self.appendLog("[调试] 已保存 HTML 快照：\(dumpPath)") }
                }
                let baseURL = extractBaseURL(link)

                // 2. 构造审批日志 URL 并抓取（抓取失败时仅用主页面，与 C# 端对齐）
                var combinedHTML = html
                if let auditURL = buildAuditNoteURL(html: html, baseURL: baseURL) {
                    appendLog("[调试] 抓取审批日志：\(auditURL)")
                    do {
                        let auditHTML = try await OAService.shared.fetchHTML(urlString: auditURL)
                        if let dumpPath = dumpDebugHTML(html: auditHTML, link: auditURL) {
                            await MainActor.run { self.appendLog("[调试] 已保存审批日志快照：\(dumpPath)") }
                        }
                        combinedHTML = html + "\n" + auditHTML
                    } catch {
                        appendLog("[调试] 审批日志抓取失败: \(error.localizedDescription)")
                    }
                } else {
                    appendLog("[调试] 未找到审批日志 URL，仅使用主页面")
                }

                // 3. 调用解析器提取 REQ（在主页面 + 审批日志合并 HTML 上解析）
                let reqs = OAParser.extractREQByOperator(html: combinedHTML, operatorName: opName)
                // 4. 提取全部 REQ（不限操作人）用于关联REQ
                let allReqs = OAParser.extractAllREQ(html: combinedHTML)

                // 5. 填入结果
                await MainActor.run {
                    if !reqs.isEmpty {
                        self.reqNumber = reqs.first ?? ""
                        self.appendLog("解析完成：找到 \(reqs.count) 个 REQ（按操作人）：\(reqs.joined(separator: ","))")
                    } else {
                        self.reqNumber = ""
                        self.relatedREQ = ""
                        self.appendLog("[警告] 未找到操作人相关的 REQ 号，请检查 OA 链接和操作人姓名")
                    }
                    // 关联REQ：全部 REQ 排除主 REQ
                    let mainReq = self.reqNumber.uppercased()
                    let related = allReqs.filter { $0 != mainReq }
                    if !related.isEmpty {
                        self.relatedREQ = related.joined(separator: ",")
                        self.appendLog("关联 REQ（全部 \(allReqs.count) 个，排除主 REQ）：\(self.relatedREQ)")
                    } else {
                        self.relatedREQ = ""
                    }
                }
            } catch {
                appendLog("[失败] \(error.localizedDescription)")
            }
        }
    }

    // MARK: - PDF Download & Upload

    private func downloadPDFAndUploadAction() {
        let link = oaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = reqNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !req.isEmpty else {
            appendLog("[警告] OA 链接或 REQ 为空")
            return
        }
        isDownloadingPDF = true
        appendLog("开始下载 PDF 并上传到 REQ: \(req)")

        Task {
            defer { Task { @MainActor in isDownloadingPDF = false } }
            do {
                // 1. 构造打印页 URL
                let printURL = link.replacingOccurrences(of: "method=view", with: "method=print")
                let baseURL = extractBaseURL(link)
                await MainActor.run { self.appendLog("[步骤1] 打印页 URL: \(printURL)") }

                // 2. 调用 OAPDFExportService 生成 PDF（返回的 fileName 为 OA 页面标题，如 “关于xxx的请示需求.pdf”）
                let (pdfData, pdfFileName) = try await OAPDFExportService.shared.exportPDF(printURL: printURL, baseURL: baseURL)
                var tmpName = pdfFileName.isEmpty ? "\(req).pdf" : pdfFileName
                if !tmpName.lowercased().hasSuffix(".pdf") { tmpName += ".pdf" }
                let fileName = tmpName
                await MainActor.run { self.appendLog("[成功] PDF 下载完成 (\(pdfData.count) bytes)，文件名: \(fileName)") }

                // 3. 上传到 Jira（使用 OA 页面标题作为文件名；同名同大小的附件已存在则跳过）
                let uploaded = try await JiraService.shared.uploadAttachmentIfAbsent(
                    issueKey: req,
                    fileName: fileName,
                    fileData: pdfData,
                    mimeType: "application/pdf"
                )
                await MainActor.run {
                    self.appendLog(uploaded
                        ? "[成功] PDF 已上传到 Jira: \(req)/\(fileName)"
                        : "[跳过] \(req) 上已有同名同大小的 PDF 附件: \(fileName)")
                }

                // 4. 如果关联REQ不为空，将关联REQ链接到主REQ（已关联则跳过）
                let relatedRaw = await MainActor.run { self.relatedREQ }
                await linkRelatedREQs(mainReq: req, relatedRaw: relatedRaw)
            } catch {
                await MainActor.run { self.appendLog("[失败] \(error.localizedDescription)") }
            }
        }
    }

    /// 把「关联REQ」逐个关联到主 REQ：
    /// 先去掉重复项与主 REQ 自身，再由 JiraService 双侧校验已有关联，
    /// 已关联的跳过；关联关系读不到时不创建，避免重复关联。
    @MainActor
    private func linkRelatedREQs(mainReq: String, relatedRaw: String) async {
        guard !relatedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var candidates: [String] = []
        var seen = Set<String>()
        for part in relatedRaw.split(separator: ",") {
            let key = part.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if key.isEmpty || key == mainReq.uppercased() { continue }
            if seen.insert(key).inserted { candidates.append(key) }
        }
        if candidates.isEmpty {
            appendLog("[跳过] 关联REQ 全部与主 REQ 相同，无需关联")
            return
        }
        for relatedReq in candidates {
            do {
                let outcome = try await JiraService.shared.linkIssuesIfAbsent(from: mainReq, to: relatedReq, linkType: "关联")
                switch outcome {
                case .created:
                    appendLog("[成功] 已关联 REQ: \(relatedReq) → \(mainReq)")
                case .alreadyLinked:
                    appendLog("[跳过] \(relatedReq) 已与 \(mainReq) 关联")
                case .unverified:
                    appendLog("[警告] 无法确认 \(relatedReq) 的已有关联，本次未关联，请在 Jira 手动检查")
                }
            } catch {
                appendLog("[警告] 关联 \(relatedReq) 失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helper methods

    /// 构造审批日志（流程轨迹）AJAX URL，用于提取 REM / REQ
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
        // 与 C# 端对齐：用 oa_debug_complete_ 前缀区分本页面的快照
        let fileName = "oa_debug_complete_\(fmt.string(from: Date())).html"
        let fileURL = dir.appendingPathComponent(fileName)
        let withHeader = "<!-- source: \(link) -->\n" + html
        do {
            try withHeader.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private func extractBaseURL(_ link: String) -> String {
        guard let u = URL(string: link), let host = u.host else { return link }
        let scheme = "https"
        if let port = u.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.hhmmss.string(from: Date())
        logs += "[\(ts)] \(line)\n"
    }
}

private extension DateFormatter {
    static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
