import Foundation
import AppKit
import Combine

// MARK: - 数据模型

/// DC 目录中的一个文本/附件文件（引用类型，页面勾选状态直接写回）
final class DcFileEntry: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let fullPath: String
    let size: Int
    var text: String = ""
    var isText: Bool = false
    /// 从文件名解析出的系统名称（最后一个紧跟中文的下划线之后的中文串）
    var systemName: String = ""
    /// 是否作为附件上传到 DC（页面勾选）
    @Published var selectedAsAttachment: Bool = true

    init(name: String, fullPath: String, size: Int) {
        self.name = name
        self.fullPath = fullPath
        self.size = size
    }

    var sizeDisplay: String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024.0) }
        return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
    }

    var mimeType: String { DcService.mimeTypeFor(name) }
}

/// 『系统』级联下拉字段的一个可选项（父类 + 子系统，含各自 id）
struct DcSystemOption {
    let parentValue: String
    let parentId: String
    let childValue: String
    let childId: String
    var display: String { "\(parentValue) / \(childValue)" }
}

/// 本地目录扫描出的一个待创建 DC 条目（= 一个 REQ 目录内的某个系统分组）
final class DcItem: Identifiable, ObservableObject {
    let id = UUID()
    let directoryName: String
    let directoryPath: String
    var reqKey: String
    /// 本条目对应的系统名称（从文件名解析）
    let systemName: String
    /// 系统名称映射到的『系统』级联选项；无映射时为 nil（不写系统字段）
    let systemOption: DcSystemOption?
    /// 是否勾选参与批量创建（页面状态，不传给服务层）
    @Published var isSelected: Bool = true
    /// 是否关联对应 REQ（页面上的勾选开关）
    @Published var linkReq: Bool = true
    @Published var summary: String
    @Published var descriptionText: String
    /// 目录对应的 SVN 完整地址（SVN 前置地址 + 目录名；未配置前置地址时为空）
    var svnUrl: String = ""
    /// 页面状态列：待创建 / 创建中... / 失败 / DC Key
    @Published var status: String = "待创建"
    var files: [DcFileEntry] = []
    /// 本次批量创建成功后回写的 DC Key（未创建时为空）
    var lastCreatedKey: String = ""

    /// 系统列显示：映射到的级联选项，或标注无映射/未识别
    var systemDisplay: String {
        if let opt = systemOption { return opt.display }
        return systemName.isEmpty ? "未识别" : "\(systemName)（无映射）"
    }

    init(directoryName: String, directoryPath: String, reqKey: String,
         systemName: String, systemOption: DcSystemOption?) {
        self.directoryName = directoryName
        self.directoryPath = directoryPath
        self.reqKey = reqKey
        self.systemName = systemName
        self.systemOption = systemOption
        self.summary = systemName.isEmpty ? directoryName : "\(directoryName) \(systemName)"
        self.descriptionText = ""
    }
}

enum DcError: Error, LocalizedError {
    case noTemplate
    case invalidTemplate(String)
    case directoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noTemplate: return "未指定模板 DC Key"
        case .invalidTemplate(let msg): return "模板 DC 校验失败: \(msg)"
        case .directoryNotFound(let path): return "目录不存在: \(path)"
        }
    }
}

/// 创建 DC（生产数据配置变更申请）服务（对应 C# DcService.cs）：
/// 扫描本地目录中 REQ- 开头的子目录，参考模板 DC 工单的字段结构批量创建 DC，
/// 并把目录内文本文件内容汇总为变更描述、按勾选上传附件、关联对应 REQ。
/// 字段容错重试机制与 OACreateReqService 保持一致。
actor DcService {
    static let shared = DcService()
    private init() {}

    private let jira = JiraService.shared

    /// 按文本处理的最大文件大小（超过则仅作为附件上传）
    private static let maxTextFileSize = 2 * 1024 * 1024

    private static let textExtensions: Set<String> = [
        "sql", "txt", "md", "csv", "json", "xml", "html", "htm", "log", "sh", "yaml", "yml", "properties",
    ]

    /// 文件名系统名 → 『系统』级联选项 的固定映射表（父/子 value 与 id 均取自 Jira createmeta）。
    /// 新增系统时在此补一行即可；匹配不到的系统名将留空由用户手工处理。
    static let systemMap: [String: DcSystemOption] = [
        "新非车": DcSystemOption(parentValue: "A核心出单类", parentId: "10851", childValue: "A22 新一代非车险承保核心系统", childId: "15002"),
        "核保系统": DcSystemOption(parentValue: "A核心出单类", parentId: "10851", childValue: "A10 核保子系统", childId: "14341"),
        "数字化营销": DcSystemOption(parentValue: "E渠道支持类", parentId: "10884", childValue: "531 数字化营销管家", childId: "14811"),
        "平台系统": DcSystemOption(parentValue: "Y辅助支持类", parentId: "10886", childValue: "D01 新核心平台系统", childId: "12900"),
        "收付系统": DcSystemOption(parentValue: "C资金财务类", parentId: "10882", childValue: "C01 新核心收付系统", childId: "12406"),
        "配管系统": DcSystemOption(parentValue: "Y辅助支持类", parentId: "10886", childValue: "969 微-配置管理系统", childId: "14633"),
        "费管系统": DcSystemOption(parentValue: "A核心出单类", parentId: "10851", childValue: "119 销售费用管理系统（费管）", childId: "10868"),
        "产品工厂": DcSystemOption(parentValue: "Y辅助支持类", parentId: "10886", childValue: "D11 产品工厂", childId: "14392"),
        "工作台": DcSystemOption(parentValue: "A核心出单类", parentId: "10851", childValue: "A09 核保工作台", childId: "14340"),
        "再保系统": DcSystemOption(parentValue: "A核心出单类", parentId: "10851", childValue: "A04 新核心再保系统", childId: "12403"),
    ]

    /// 从文件名提取系统名：最后一个紧跟中文的下划线之后，连续的中文串。取不到返回空。
    static func extractSystemName(_ fileName: String) -> String {
        let name = (fileName as NSString).deletingPathExtension
        let chars = Array(name)
        func isCjk(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first else { return false }
            return scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
        }
        var bestPos = -1
        for i in 0..<(chars.count - 1) where chars[i] == "_" && isCjk(chars[i + 1]) {
            bestPos = i
        }
        guard bestPos >= 0 else { return "" }
        var end = bestPos + 1
        while end < chars.count && isCjk(chars[end]) { end += 1 }
        return String(chars[(bestPos + 1)..<end])
    }

    // MARK: - 目录扫描

    /// 扫描根目录下 REQ-开头的子目录，生成待创建 DC 条目（含文件清单与文本内容）；svnBase 非空时拼接目录名生成 SVN 地址
    nonisolated func scanDirectory(_ rootPath: String, svnBase: String = "") throws -> [DcItem] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw DcError.directoryNotFound(rootPath)
        }

        let fm = FileManager.default
        // 若选中的目录本身就是 REQ- 开头，直接把它当作待处理目录；否则扫描其下 REQ-* 子目录
        let rootName = (rootPath as NSString).lastPathComponent
        var reqDirPaths: [String] = []
        if rootName.range(of: #"^REQ-\d+"#, options: .regularExpression) != nil {
            reqDirPaths = [rootPath]
        } else {
            let subDirs = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
            reqDirPaths = subDirs
                .filter { name in
                    guard !name.hasPrefix(".") else { return false }
                    var subIsDir: ObjCBool = false
                    fm.fileExists(atPath: (rootPath as NSString).appendingPathComponent(name), isDirectory: &subIsDir)
                    return subIsDir.boolValue && name.range(of: #"^REQ-\d+"#, options: .regularExpression) != nil
                }
                .sorted { Self.reqNumber($0) < Self.reqNumber($1) }
                .map { (rootPath as NSString).appendingPathComponent($0) }
        }

        var items: [DcItem] = []
        let svnBaseTrimmed = svnBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for dirPath in reqDirPaths {
            let dirName = (dirPath as NSString).lastPathComponent
            let reqKey = Self.extractReqKey(dirName)

            let fileNames = ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? [])
                .filter { !$0.hasPrefix("._") && $0 != ".DS_Store" }
                .sorted { ($0 as NSString).localizedStandardCompare($1) == .orderedAscending }

            // 先读取目录内所有文件，标注各自系统名
            var entries: [DcFileEntry] = []
            for fileName in fileNames {
                let filePath = (dirPath as NSString).appendingPathComponent(fileName)
                var isSubDir: ObjCBool = false
                guard fm.fileExists(atPath: filePath, isDirectory: &isSubDir), !isSubDir.boolValue else { continue }
                let attrs: [FileAttributeKey: Any] = (try? fm.attributesOfItem(atPath: filePath)) ?? [:]
                let size = attrs[.size] as? NSNumber
                let entry = DcFileEntry(name: fileName, fullPath: filePath, size: size?.intValue ?? 0)
                entry.systemName = Self.extractSystemName(fileName)
                let ext = (fileName as NSString).pathExtension.lowercased()
                if Self.textExtensions.contains(ext), entry.size <= Self.maxTextFileSize,
                   let text = Self.readTextFile(path: filePath) {
                    entry.isText = true
                    entry.text = text
                }
                entries.append(entry)
            }

            // 按系统名分组：每个系统名一个 DC，未识别（空）的排到最后
            let grouped = Dictionary(grouping: entries, by: { $0.systemName })
            let orderedKeys = grouped.keys.sorted { a, b in
                let ea = a.isEmpty ? 1 : 0, eb = b.isEmpty ? 1 : 0
                if ea != eb { return ea < eb }
                return a < b
            }
            for key in orderedKeys {
                let item = DcItem(directoryName: dirName, directoryPath: dirPath, reqKey: reqKey,
                                  systemName: key, systemOption: Self.systemMap[key])
                if !svnBaseTrimmed.isEmpty { item.svnUrl = "\(svnBaseTrimmed)/\(dirName)" }
                item.files = grouped[key] ?? []
                item.descriptionText = Self.buildDescription(from: item)
                items.append(item)
            }
        }
        return items
    }

    /// 文件的展示地址：SVN 前置地址配置时用 SVN 文件地址（目录SVN+文件名），否则仅文件名（不使用本地地址）
    private static func fileDisplayUrl(_ item: DcItem, _ f: DcFileEntry) -> String {
        item.svnUrl.isEmpty ? f.name : "\(item.svnUrl)/\(f.name)"
    }

    /// 把目录内扫描的文件清单（SVN 地址）与文本内容汇总为 DC 变更描述
    private static func buildDescription(from item: DcItem) -> String {
        var lines: [String] = []

        // 文件清单：使用 SVN 地址，不使用本地地址
        if !item.files.isEmpty {
            lines.append("【文件清单】")
            for f in item.files { lines.append(fileDisplayUrl(item, f)) }
            lines.append("")
        }

        for f in item.files where f.isText && !f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("【\(fileDisplayUrl(item, f))】")
            lines.append(f.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        if item.files.isEmpty {
            lines.append("（\(item.directoryName) 目录无内容，请手工填写变更内容）")
        }

        if !item.svnUrl.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("SVN地址：\(item.svnUrl)")
        }
        return lines.joined(separator: "\n")
    }

    /// 读取文本文件：优先 UTF-8，失败回退 GBK，再回退 latin1 保字节
    private static func readTextFile(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // UTF-8 BOM
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.subdata(in: 3..<data.count), encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func extractReqKey(_ dirName: String) -> String {
        let ns = dirName as NSString
        let range = ns.range(of: #"REQ-\d+"#, options: .regularExpression)
        return range.location == NSNotFound ? "" : ns.substring(with: range)
    }

    /// 根据文件名扩展名推断 MIME 类型
    static func mimeTypeFor(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "sql": return "application/sql"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    private static func reqNumber(_ name: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"REQ-(\d+)"#) else { return Int.max }
        let ns = name as NSString
        guard let m = regex.firstMatch(in: name, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return Int.max }
        return Int(ns.substring(with: m.range(at: 1))) ?? Int.max
    }

    // MARK: - 批量创建

    /// 按勾选条目批量创建 DC（对应 C# CreateFromItemsAsync）。
    /// - Returns: 成功创建的 DC Key 列表
    func createFromItems(
        templateDcKey: String,
        items: [DcItem],
        fixedLabels: String,
        fixedAssignee: String,
        extraAttachmentPaths: String,
        fixedChangeReason: String,
        logger rawLogger: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        // 日志精简：连续的『[设置] xxx』行合并成一行输出（与 OACreateReqService 约定一致）
        let setPrefix = "[设置] "
        let setBuffer = LogLineBuffer()
        let logger: @Sendable (String) -> Void = { line in
            if line.hasPrefix(setPrefix) {
                setBuffer.add(String(line.dropFirst(setPrefix.count)))
            } else {
                if !setBuffer.isEmpty {
                    rawLogger(setPrefix + setBuffer.joined())
                    setBuffer.clear()
                }
                rawLogger(line)
            }
        }

        let templateKey = templateDcKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templateKey.isEmpty else { throw DcError.noTemplate }

        // 固定（测试通过）附件：解析为存在的文件路径列表
        let extraPaths = extraAttachmentPaths
            .split(whereSeparator: { "\n\r;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }

        logger("读取模板 DC \(templateKey) ...")
        let raw = try await jira.getIssueRaw(templateKey, expand: "names")
        guard let fields = raw["fields"] as? [String: Any] else {
            throw DcError.invalidTemplate("模板返回无 fields")
        }
        let names = raw["names"] as? [String: String] ?? [:]

        // 反向索引：中文字段名 → customfield_id
        var nameToId: [String: String] = [:]
        for (id, name) in names { nameToId[name] = id }

        guard let projectKey = (fields["project"] as? [String: Any])?["key"] as? String else {
            throw DcError.invalidTemplate("模板无项目 key")
        }
        let issueTypeDict = fields["issuetype"] as? [String: Any]
        let issueTypeName = issueTypeDict?["name"] as? String ?? ""
        let issueTypeId = issueTypeDict?["id"] as? String

        // createmeta 字段元数据（用于选项字段解析与克隆白名单）
        var fieldOptions: [String: [[String: Any]]] = [:]
        var creatableFields = Set<String>()
        do {
            let metaName = issueTypeName.isEmpty ? "故障" : issueTypeName
            if let metaFields = try await jira.getCreateMetaFields(projectKey: projectKey, issueTypeName: metaName) {
                for (fieldId, fieldMeta) in metaFields {
                    creatableFields.insert(fieldId)
                    guard let meta = fieldMeta as? [String: Any] else { continue }
                    if let allowedValues = meta["allowedValues"] as? [[String: Any]], !allowedValues.isEmpty {
                        fieldOptions[fieldId] = allowedValues
                    }
                }
            }
        } catch {
            logger("[元数据] 查询 createmeta 失败: \(error.localizedDescription)，将仅按模板结构克隆")
        }

        // 模板中可克隆的普通字段（排除系统字段与已知需覆盖的字段）
        let excludedFields: Set<String> = [
            "summary", "description", "project", "issuetype", "creator", "reporter",
            "assignee", "labels", "issuelinks", "attachment", "comment", "subtasks",
            "issuechildren", "parent", "status", "resolution", "resolutiondate",
            "created", "updated", "watchers", "votes", "worklog",
            "timetracking", "aggregateprogress", "progress", "environment",
            "components", "versions",
        ]
        // 『系统』级联字段（按模板 names 精确匹配“系统”），单独按映射表写入，不参与克隆
        let systemFieldId = nameToId["系统"]

        var cloneFieldIds: [String] = []
        for (id, value) in fields {
            if excludedFields.contains(id) { continue }
            if let systemFieldId = systemFieldId, id == systemFieldId { continue }
            if id.hasPrefix("customfield_") && !creatableFields.isEmpty && !creatableFields.contains(id) { continue }
            if Self.isCloneableFieldValue(value) { cloneFieldIds.append(id) }
        }

        let assignee = !fixedAssignee.isEmpty ? fixedAssignee : AppConfig.shared.jiraUser
        let labels = fixedLabels
            .split(whereSeparator: { ",，; ；\n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 变更内容类字段（若模板存在同名纯文本字段则同步写入描述）
        let changeFieldId = resolveCustomFieldId(nameToId: nameToId, candidates: [
            "变更内容", "数据变更内容", "变更脚本", "配置变更内容",
        ])

        var createdKeys: [String] = []
        let total = items.count
        for (index, item) in items.enumerated() {
            let tag = "[\(index + 1)/\(total)] \(item.directoryName) \(item.systemName)".trimmingCharacters(in: .whitespaces)
            let summaryFallback = item.systemName.isEmpty ? item.directoryName : "\(item.directoryName) \(item.systemName)"
            do {
                var newFields: [String: Any] = [
                    "project": ["key": projectKey],
                    "summary": item.summary.trimmingCharacters(in: .whitespaces).isEmpty
                        ? summaryFallback : item.summary.trimmingCharacters(in: .whitespaces),
                ]
                if let issueTypeId = issueTypeId {
                    newFields["issuetype"] = ["id": issueTypeId]
                } else {
                    newFields["issuetype"] = ["name": issueTypeName]
                }
                if !item.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    newFields["description"] = item.descriptionText
                }

                // 克隆模板普通字段（JSON 深拷贝，剥离只读键）
                for id in cloneFieldIds {
                    if let value = fields[id], let cloned = Self.cloneJsonValue(value) {
                        newFields[id] = cloned
                    }
                }
                if !cloneFieldIds.isEmpty {
                    logger("\(tag) [设置] 克隆模板字段 \(cloneFieldIds.count) 个")
                }

                // 『系统』级联字段：按固定映射表写入父/子选项（含 id）
                if let systemFieldId = systemFieldId {
                    if let opt = item.systemOption {
                        var child: [String: Any] = ["value": opt.childValue]
                        if !opt.childId.isEmpty { child["id"] = opt.childId }
                        let cascading: [String: Any] = [
                            "value": opt.parentValue,
                            "id": opt.parentId,
                            "child": child,
                        ]
                        newFields[systemFieldId] = cascading
                        logger("[设置] 系统 = \(opt.parentValue) > \(opt.childValue)")
                    } else {
                        let shown = item.systemName.isEmpty ? "未识别" : item.systemName
                        logger("[警告] 系统名『\(shown)』无映射，未设置系统字段")
                    }
                }

                // 变更内容字段：模板值为空或是纯文本时才写入，避免破坏选项结构
                if let changeFieldId = changeFieldId,
                   !item.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   Self.isPlainTextTemplateValue(fields[changeFieldId]) {
                    newFields[changeFieldId] = item.descriptionText
                    logger("[设置] 变更内容 = \(item.directoryName)")
                }

                // 变更原因：非空时覆盖模板克隆值；留空则保持克隆（即复制模板内容）
                let reason = fixedChangeReason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty {
                    if let reasonFieldId = resolveCustomFieldId(nameToId: nameToId, candidates: ["变更原因"]) {
                        newFields[reasonFieldId] = reason
                        logger("[设置] 变更原因 = \(reason)")
                    } else {
                        logger("[警告] 模板无「变更原因」字段，录入的变更原因未写入")
                    }
                }

                if !assignee.isEmpty { newFields["assignee"] = ["name": assignee] }
                if !labels.isEmpty { newFields["labels"] = labels }

                logger("\(tag) 创建 DC ...")
                let newKey = try await createWithRetry(newFields: newFields, issueTypeId: issueTypeId,
                                                       fieldOptions: fieldOptions, logger: logger)
                createdKeys.append(newKey)
                item.lastCreatedKey = newKey
                logger("\(tag) [成功] 创建 DC: \(newKey)（\(item.summary)）")

                // 上传勾选的目录文件
                let picked = item.files.filter(\.selectedAsAttachment)
                if !picked.isEmpty {
                    var uploaded = 0
                    for f in picked {
                        do {
                            guard let data = FileManager.default.contents(atPath: f.fullPath) else {
                                logger("[附件失败] \(f.name): 无法读取文件")
                                continue
                            }
                            if try await jira.uploadAttachmentIfAbsent(
                                issueKey: newKey, fileName: f.name, fileData: data, mimeType: f.mimeType) {
                                uploaded += 1
                            }
                        } catch {
                            logger("[附件失败] \(f.name): \(error.localizedDescription)")
                        }
                    }
                    logger("[附件] \(newKey) 已上传 \(uploaded)/\(picked.count)")
                }

                // 上传固定（测试通过）附件
                if !extraPaths.isEmpty {
                    var up = 0
                    for p in extraPaths {
                        let fname = (p as NSString).lastPathComponent
                        do {
                            guard let data = FileManager.default.contents(atPath: p) else {
                                logger("[测试附件失败] \(fname): 无法读取文件")
                                continue
                            }
                            if try await jira.uploadAttachmentIfAbsent(
                                issueKey: newKey, fileName: fname, fileData: data, mimeType: Self.mimeTypeFor(fname)) {
                                up += 1
                            }
                        } catch {
                            logger("[测试附件失败] \(fname): \(error.localizedDescription)")
                        }
                    }
                    logger("[测试附件] \(newKey) 已上传 \(up)/\(extraPaths.count)")
                }

                // 关联对应 REQ
                if item.linkReq, !item.reqKey.isEmpty {
                    do {
                        let outcome = try await jira.linkIssuesIfAbsent(from: newKey, to: item.reqKey, linkType: "关联")
                        switch outcome {
                        case .created:
                            logger("[关联] \(newKey) → \(item.reqKey)")
                        case .alreadyLinked:
                            logger("[关联] \(newKey) 与 \(item.reqKey) 已关联，未重复创建")
                        case .unverified:
                            logger("[关联] 无法确认 \(item.reqKey) 的已有关联，本次未关联，请手动检查")
                        }
                    } catch {
                        logger("[关联失败] \(newKey) → \(item.reqKey): \(error.localizedDescription)")
                    }
                }
            } catch {
                logger("\(tag) [失败] 创建 DC 失败：\(error.localizedDescription)")
            }
        }

        var summaryLine = "[完成] 成功 \(createdKeys.count)/\(total) 个 DC"
        if !createdKeys.isEmpty { summaryLine += "：\(createdKeys.joined(separator: ", "))" }
        rawLogger(summaryLine)
        return createdKeys
    }

    // MARK: - 创建容错（与 OACreateReqService 相同的两轮重试策略）

    private func createWithRetry(
        newFields: [String: Any],
        issueTypeId: String?,
        fieldOptions: [String: [[String: Any]]],
        logger: @Sendable (String) -> Void
    ) async throws -> String {
        var fields = newFields
        let typeParam = issueTypeId ?? ""
        do {
            return try await jira.createIssue(project: "", issueType: typeParam, fields: fields)
        } catch {
            let errorMsg = error.localizedDescription
            if let badFields = parseBadFieldsFromError(errorMsg) {
                logger("[过滤] 首次创建失败，移除不在创建屏幕上的字段后重试: \(badFields.joined(separator: ", "))")
                for field in badFields { fields.removeValue(forKey: field) }
                do {
                    return try await jira.createIssue(project: "", issueType: typeParam, fields: fields)
                } catch {
                    return try await retryWithFieldRemoval(newFields: &fields, issueTypeId: issueTypeId,
                                                           error: error, fieldOptions: fieldOptions, logger: logger)
                }
            }
            return try await retryWithFieldRemoval(newFields: &fields, issueTypeId: issueTypeId,
                                                   error: error, fieldOptions: fieldOptions, logger: logger)
        }
    }

    private func retryWithFieldRemoval(
        newFields: inout [String: Any],
        issueTypeId: String?,
        error: Error,
        fieldOptions: [String: [[String: Any]]],
        logger: @Sendable (String) -> Void
    ) async throws -> String {
        let errorMsg = error.localizedDescription
        if let invalidFields = parseInvalidOptionFieldsFromError(errorMsg) {
            for field in invalidFields {
                if let opts = fieldOptions[field] {
                    let values = opts.compactMap { $0["value"] as? String }
                    logger("[跳过] \(field) 选项值无效，可用选项: \(describeOptions(values))")
                } else {
                    logger("[跳过] \(field) 选项值无效，无元数据可用")
                }
                newFields.removeValue(forKey: field)
            }
            return try await jira.createIssue(project: "", issueType: issueTypeId ?? "", fields: newFields)
        }
        throw error
    }

    // MARK: - Helpers

    /// 字段值是否可克隆：字符串/数字/布尔、{value|id|name} 结构、纯字符串或选项数组
    private static func isCloneableFieldValue(_ value: Any) -> Bool {
        if value is String || value is Int || value is Double || value is Bool { return true }
        if let dict = value as? [String: Any] {
            if dict["self"] != nil && dict["value"] == nil && dict["id"] == nil { return false }
            return dict["value"] != nil || dict["id"] != nil || dict["name"] != nil
        }
        if let arr = value as? [Any], !arr.isEmpty {
            return arr.allSatisfy { item in
                if item is String { return true }
                if let dict = item as? [String: Any] {
                    return dict["self"] == nil
                        && (dict["value"] != nil || dict["id"] != nil || dict["name"] != nil)
                }
                return false
            }
        }
        return false
    }

    /// JSON 深拷贝（经过序列化往返，天然剥离 NSNull 之外的异常类型）
    private static func cloneJsonValue(_ value: Any) -> Any? {
        guard JSONSerialization.isValidJSONObject([["v": value]]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value]),
              let back = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return back["v"]
    }

    /// 字段是否可安全写入纯文本（模板值为字符串或为空）
    private static func isPlainTextTemplateValue(_ value: Any?) -> Bool {
        if value == nil { return true }
        if value is String { return true }
        if value is NSNull { return true }
        return false
    }

    /// 选项列表的日志展示：最多 8 项，超出时只给总数
    private func describeOptions(_ values: [String]) -> String {
        let shown = values.prefix(8).joined(separator: ", ")
        return values.count > 8 ? "[\(shown), …共 \(values.count) 项]" : "[\(shown)]"
    }

    /// 按中文字段名反查 customfield_id
    private func resolveCustomFieldId(nameToId: [String: String], candidates: [String]) -> String? {
        for c in candidates {
            if let id = nameToId[c] { return id }
        }
        for (name, id) in nameToId {
            for c in candidates where name.contains(c) {
                return id
            }
        }
        return nil
    }

    /// 从 400 错误信息中提取不能设置的字段列表
    private func parseBadFieldsFromError(_ errorMsg: String) -> [String]? {
        let pattern = #"Field\s+'([a-zA-Z_][a-zA-Z_0-9]*)'\s+cannot\s+be\s+set"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = errorMsg as NSString
        let matches = regex.matches(in: errorMsg, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [String] = []
        for match in matches {
            if match.numberOfRanges >= 2 {
                result.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return result.isEmpty ? nil : result
    }

    /// 从错误信息中提取有无效选项值的字段
    private func parseInvalidOptionFieldsFromError(_ errorMsg: String) -> [String]? {
        let pattern = #""(customfield_\d+)"\s*:\s*"[^"]*(?:Could not find valid|not a valid)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = errorMsg as NSString
        let matches = regex.matches(in: errorMsg, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [String] = []
        for match in matches {
            if match.numberOfRanges >= 2 {
                result.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return result.isEmpty ? nil : result
    }
}
