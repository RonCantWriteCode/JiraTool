import Foundation

enum OACreateReqError: Error, LocalizedError {
    case templateNotFound
    case invalidTemplate(String)

    var errorDescription: String? {
        switch self {
        case .templateNotFound: return "未指定模板 REQ Key"
        case .invalidTemplate(let msg): return "模板 REQ 校验失败: \(msg)"
        }
    }
}

/// 使用参考 REQ 做模板，把 OA 页面解析结果转换为新 REQ
actor OACreateReqService {
    static let shared = OACreateReqService()
    private init() {}

    private let jira = JiraService.shared

    /// 创建 REQ 主流程
    /// - Parameters:
    ///   - oaLink: 原始 OA 链接（用作签报链接）
    ///   - templateReqKey: 参考模板 REQ Key
    ///   - parsed: OA 解析结果（可能被用户手工修正过）
    ///   - pickedAttachments: 勾选要上传的附件
    ///   - draftDeptKeyword: 拟稿部门关键字（用户手工修正后）
    ///   - fixedSystemParent: 固定字段：系统名称（父级）
    ///   - fixedSystemChild: 固定字段：系统名称（子级）
    ///   - fixedDevVersion: 固定字段：开发版本号
    ///   - fixedDutyDept: 固定字段：责任科室
    ///   - fixedGroupName: 固定字段：科室小组（空时复制模板值）
    ///   - fixedIsCopyReq: 固定字段：是否复制需求
    ///   - fixedIsComplexReq: 固定字段：是否复杂需求
    ///   - fixedReqCategory: 固定字段：需求分类
    ///   - fixedIsPricing: 固定字段：是否计价
    ///   - fixedLabels: 固定字段：标签（多个用英文逗号分隔）
    ///   - fixedAssignee: 固定字段：经办人
    ///   - logger: 日志回调（线程不安全的 String 拼接，这里只做进度提示）
    /// - Returns: 新建 REQ Key
    func createFromOA(
        oaLink: String,
        templateReqKey: String,
        parsed: OAParseResult,
        pickedAttachments: [OAAttachment],
        draftDeptKeyword: String,
        fixedSystemParent: String,
        fixedSystemChild: String,
        fixedDevVersion: String,
        fixedDutyDept: String,
        fixedGroupName: String,
        fixedIsCopyReq: String,
        fixedIsComplexReq: String,
        fixedReqCategory: String,
        fixedIsPricing: String,
        fixedLabels: String,
        fixedAssignee: String,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {

        let templateKey = templateReqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templateKey.isEmpty else { throw OACreateReqError.templateNotFound }

        logger("读取模板 REQ \(templateKey) ...")
        let raw = try await jira.getIssueRaw(templateKey, expand: "names")
        guard let fields = raw["fields"] as? [String: Any] else {
            throw OACreateReqError.invalidTemplate("模板返回无 fields")
        }
        let names = raw["names"] as? [String: String] ?? [:]

        // 反向索引：中文字段名 → customfield_id
        var nameToId: [String: String] = [:]
        for (id, name) in names {
            nameToId[name] = id
        }

        // 1) 系统名称（开发）级联字段：获取模板结构作为基础
        let sysField = fields["customfield_10125"]
        if sysField == nil {
            logger("[警告] 模板中没有级联字段 customfield_10125（系统名称（开发）），将尝试按元数据构建")
        }

        // 2) issuetype
        let issueTypeDict = fields["issuetype"] as? [String: Any]
        let issueTypeName = issueTypeDict?["name"] as? String ?? ""
        let issueTypeId = issueTypeDict?["id"] as? String
        if !issueTypeName.contains("系统需求") && !issueTypeName.contains("需求") {
            logger("[警告] 模板 issuetype=\(issueTypeName)，并非『系统需求』；将继续使用模板 id=\(issueTypeId ?? "")")
        }

        // 查询 createmeta 获取字段选项元数据（用于解析选项字段的正确 id）
        var fieldOptions: [String: [[String: Any]]] = [:]
        var fieldSchemaTypes: [String: String] = [:]
        do {
            let metaName = issueTypeName.isEmpty ? "系统需求" : issueTypeName
            if let metaFields = try await jira.getCreateMetaFields(projectKey: "REQ", issueTypeName: metaName) {
                for (fieldId, fieldMeta) in metaFields {
                    if let meta = fieldMeta as? [String: Any] {
                        if let allowedValues = meta["allowedValues"] as? [[String: Any]],
                           !allowedValues.isEmpty {
                            fieldOptions[fieldId] = allowedValues
                        }
                        // 记录字段 schema 类型（用于区分选项/级联/字符串字段）
                        if let schema = meta["schema"] as? [String: Any],
                           let schemaType = schema["type"] as? String, !schemaType.isEmpty {
                            fieldSchemaTypes[fieldId] = schemaType
                        }
                    }
                }
                logger("[元数据] 已加载 \(fieldOptions.count) 个字段的选项数据，\(fieldSchemaTypes.count) 个字段的类型信息")
            } else {
                logger("[元数据] createmeta 返回空，将仅按 value 文本匹配")
            }
        } catch {
            logger("[元数据] 查询 createmeta 失败: \(error.localizedDescription)，将仅按 value 文本匹配")
        }

        // 3) 构造创建字段
        var newFields: [String: Any] = [:]
        newFields["project"] = ["key": "REQ"]
        if let issueTypeId = issueTypeId {
            newFields["issuetype"] = ["id": issueTypeId]
        } else {
            newFields["issuetype"] = ["name": "系统需求"]
        }
        newFields["summary"] = parsed.title.isEmpty ? "(来自 OA，无标题)" : parsed.title

        // 系统名称（开发）: 用用户指定的父/子级值覆盖
        var sysResult: [String: Any] = [:]
        let sysMetaOptions = fieldOptions["customfield_10125"]
        if let metaOptions = sysMetaOptions, !fixedSystemParent.isEmpty {
            // 通过元数据匹配父级 id
            if let parentMatched = findOptionByValue(allowedValues: metaOptions, targetValue: fixedSystemParent) {
                if let id = parentMatched["id"] as? String { sysResult["id"] = id }
                sysResult["value"] = fixedSystemParent
                // 匹配子级 id
                if let children = parentMatched["children"] as? [[String: Any]], !fixedSystemChild.isEmpty {
                    if let childMatched = findOptionByValue(allowedValues: children, targetValue: fixedSystemChild) {
                        var c: [String: Any] = [:]
                        if let id = childMatched["id"] as? String { c["id"] = id }
                        c["value"] = fixedSystemChild
                        sysResult["child"] = c
                    } else {
                        sysResult["child"] = ["value": fixedSystemChild]
                    }
                }
                logger("[设置] customfield_10125 = \(fixedSystemParent) > \(fixedSystemChild) (id 匹配)")
            } else {
                // 父级未匹配到元数据，仅设置文本值
                sysResult["value"] = fixedSystemParent
                if !fixedSystemChild.isEmpty { sysResult["child"] = ["value": fixedSystemChild] }
                logger("[设置] customfield_10125 = \(fixedSystemParent) > \(fixedSystemChild) (仅文本值)")
            }
        } else {
            // 无元数据，回退到克隆模板 + 覆盖文本值
            if let sysDict = sysField as? [String: Any] {
                sysResult = (cloneCascading(sysDict) as? [String: Any]) ?? [:]
            }
            sysResult["value"] = fixedSystemParent
            if !fixedSystemChild.isEmpty {
                var c = (sysResult["child"] as? [String: Any]) ?? [:]
                c["value"] = fixedSystemChild
                sysResult["child"] = c
            }
            logger("[设置] customfield_10125 = \(fixedSystemParent) > \(fixedSystemChild) (回退模板结构)")
        }
        newFields["customfield_10125"] = sysResult

        // 价值描述 (customfield_12105) = 申请内容
        if !parsed.content.isEmpty {
            newFields["customfield_12105"] = parsed.content
        }

        // 签报号 / 签报链接
        newFields["customfield_10115"] = parsed.applyNo
        newFields["customfield_13252"] = oaLink

        // 经办人 = 用户指定的值（优先使用可编辑字段，默认当前登录账号）
        let assignee = !fixedAssignee.isEmpty ? fixedAssignee : AppConfig.shared.jiraUser
        if !assignee.isEmpty {
            newFields["assignee"] = ["name": assignee]
        }

        // —— 下列字段按"中文字段名"在模板 names 中反查 customfield_id，再按模板结构克隆 ——

        // a) 需求提交部门：拟稿部门关键字
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["需求提交部门", "提交部门", "需求部门", "申请部门"],
            stringValue: draftDeptKeyword,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // a-2) 开发版本号
        if !fixedDevVersion.isEmpty {
            applyFieldByName(
                newFields: &newFields,
                templateFields: fields,
                nameToId: nameToId,
                candidateNames: ["开发版本号", "版本号", "开发版本"],
                stringValue: fixedDevVersion,
                fieldOptions: fieldOptions,
                fieldSchemaTypes: fieldSchemaTypes,
                logger: logger
            )
        }

        // b) 责任科室
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["责任科室", "开发科室", "主责科室"],
            stringValue: fixedDutyDept,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // b-2) 分公司：使用解析结果中的值
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["分公司", "分支机构", "所属分公司"],
            stringValue: parsed.branchCompany,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // c) 科室小组: 用户录入为空时直接复制模板 REQ 的值，否则使用用户输入
        if let groupNameFieldId = resolveCustomFieldId(nameToId: nameToId, candidates: ["科室小组", "开发小组", "责任小组"], logger: logger) {
            if fixedGroupName.isEmpty {
                // 用户未录入，复制模板值
                if let templateVal = fields[groupNameFieldId] {
                    newFields[groupNameFieldId] = cloneCascading(templateVal)
                    logger("[设置] 科室小组(\(groupNameFieldId)) = 复制模板值")
                }
            } else {
                // 用户已录入，替换 value
                applyFieldByName(
                    newFields: &newFields,
                    templateFields: fields,
                    nameToId: nameToId,
                    candidateNames: ["科室小组", "开发小组", "责任小组"],
                    stringValue: fixedGroupName,
                    fieldOptions: fieldOptions,
                    fieldSchemaTypes: fieldSchemaTypes,
                    logger: logger
                )
            }
        } else {
            logger("[跳过] 未在模板中找到字段：科室小组/开发小组/责任小组")
        }

        // d) 是否复制需求
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["是否复制需求", "是否复制"],
            stringValue: fixedIsCopyReq,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // e) 需求提出人 = 拟稿人（customfield_10123 已知）
        let drafter = parsed.drafter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !drafter.isEmpty {
            // 直接使用拟稿人原始中文姓名，不做任何转换
            newFields["customfield_10123"] = drafter
            logger("[设置] 需求提出人(customfield_10123) = \(drafter)")

            // 同时走动态匹配以兼容其它字段名（若模板里字段名不叫"需求提出人"）
            applyUserFieldByName(
                newFields: &newFields,
                templateFields: fields,
                nameToId: nameToId,
                candidateNames: ["需求提出人", "提出人", "需求提交人"],
                userName: drafter,
                logger: logger
            )

            // f) 用户测试人员 = 拟稿人
            applyUserFieldByName(
                newFields: &newFields,
                templateFields: fields,
                nameToId: nameToId,
                candidateNames: ["用户测试人员", "用户测试", "测试用户"],
                userName: drafter,
                logger: logger
            )
        } else {
            logger("[警告] OA 拟稿人为空，跳过『需求提出人』与『用户测试人员』设置")
        }

        // g) 是否复杂需求
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["是否复杂需求", "复杂需求"],
            stringValue: fixedIsComplexReq,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // h) 需求接收日期: 当前日期（格式 yyyy-MM-dd）
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["需求接收日期", "接收日期", "需求提交日期"],
            stringValue: Self.formatTodayDate(),
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // i) 需求分类
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["需求分类", "需求类型"],
            stringValue: fixedReqCategory,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // i-2) 是否计价
        applyFieldByName(
            newFields: &newFields,
            templateFields: fields,
            nameToId: nameToId,
            candidateNames: ["是否计价", "计价"],
            stringValue: fixedIsPricing,
            fieldOptions: fieldOptions,
            fieldSchemaTypes: fieldSchemaTypes,
            logger: logger
        )

        // j) 标签
        let labels = fixedLabels
            .split(whereSeparator: { ",，; ；\n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !labels.isEmpty {
            newFields["labels"] = labels
            logger("[设置] 标签 = \(labels)")
        }

        // 创建（带字段过滤重试机制）
        logger("创建 REQ ...")
        let newKey: String
        var removedFields: [String]?
        do {
            newKey = try await jira.createIssue(project: "REQ", issueType: issueTypeId ?? "", fields: newFields)
        } catch {
            let errorMsg = error.localizedDescription
            logger("[提示] 首次创建失败，尝试过滤不在创建屏幕上的字段...")
            if let badFields = parseBadFieldsFromError(errorMsg) {
                removedFields = badFields
                logger("[过滤] 移除不在创建屏幕上的字段: \(badFields.joined(separator: ", "))")
                for field in badFields {
                    newFields.removeValue(forKey: field)
                }
                do {
                    newKey = try await jira.createIssue(project: "REQ", issueType: issueTypeId ?? "", fields: newFields)
                } catch {
                    // 第二轮容错：处理选项字段值无效的情况
                    newKey = try await retryWithFieldRemoval(newFields: &newFields, issueTypeId: issueTypeId, error: error, fieldOptions: fieldOptions, logger: logger)
                }
            } else {
                // 首轮错误不是 "cannot be set" 格式，尝试选项字段容错
                newKey = try await retryWithFieldRemoval(newFields: &newFields, issueTypeId: issueTypeId, error: error, fieldOptions: fieldOptions, logger: logger)
            }
        }
        logger("[成功] 创建 REQ: \(newKey)")

        // 创建成功后，尝试通过 update API 补回被过滤的字段（如 labels）
        if let removed = removedFields, !removed.isEmpty {
            // labels 需要用 update 操作格式，不能用 fields 直接设置
            if removed.contains("labels") && !labels.isEmpty {
                do {
                    let updateBlock: [String: Any] = [
                        "labels": [["set": labels]]
                    ]
                    try await jira.updateIssueOperations(newKey, update: updateBlock)
                    logger("[补设] 已通过 update 操作设置 labels: \(labels.joined(separator: ", "))")
                } catch {
                    logger("[补设失败] labels: \(error.localizedDescription)")
                }
            }
        }

        // 4) 上传附件
        // 从 OA 链接提取 baseURL（用于诊断）
        let oaBaseURL = extractBaseURL(from: oaLink)
        if !pickedAttachments.isEmpty {
            logger("下载并上传附件 \(pickedAttachments.count) 个 ...")
            for att in pickedAttachments {
                do {
                    let downloaded = try await OAService.shared.downloadAttachment(urlString: att.url)
                    try await jira.uploadAttachment(
                        issueKey: newKey,
                        fileName: downloaded.name.isEmpty ? att.name : downloaded.name,
                        fileData: downloaded.data,
                        mimeType: downloaded.mimeType
                    )
                    logger("  ✓ 已上传: \(downloaded.name)")
                } catch {
                    logger("  ✗ 附件失败 [\(att.name)]: \(error.localizedDescription)")
                    // 自动诊断：尝试所有可能的 URL 组合并保存报告
                    logger("  🔍 正在生成下载诊断报告 ...")
                    await OAService.shared.diagnoseDownload(attachment: att, baseURL: oaBaseURL, referer: oaLink)
                }
            }
        }

        // 5) 关联 REM
        if !parsed.remKeys.isEmpty {
            logger("关联 REM \(parsed.remKeys.joined(separator: ",")) ...")
            for rem in parsed.remKeys {
                do {
                    try await jira.linkIssues(from: newKey, to: rem, linkType: "关联")
                    logger("  ✓ 已关联 \(rem)")
                } catch {
                    logger("  ✗ 关联失败 \(rem): \(error.localizedDescription)")
                }
            }
        }

        return newKey
    }

    // MARK: - Helpers

    /// 格式化今天日期为 Jira 接受的 datetime 格式（如 2026-04-30T15:20:26.620+0800）
    /// Jira 要求时区用 ±HHMM 格式，不接受 "Z"
    private static func formatTodayDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// 从 400 错误信息中提取不能设置的字段列表（支持 customfield_XXXX 和 labels 等内置字段名）
    /// 错误格式：{"errors":{"customfield_13256":"Field 'customfield_13256' cannot be set..."}}
    private func parseBadFieldsFromError(_ errorMsg: String) -> [String]? {
        let pattern = #"Field\s+'([a-zA-Z_][a-zA-Z_0-9]*)'\s+cannot\s+be\s+set"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = errorMsg as NSString
        let matches = regex.matches(in: errorMsg, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [String] = []
        for match in matches {
            if match.numberOfRanges >= 2 {
                let field = ns.substring(with: match.range(at: 1))
                result.append(field)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// 从错误信息中提取有无效选项值的字段（如 "Could not find valid 'id' or 'value'"）
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

    /// 第二轮容错：识别无效选项字段，打印可用选项，移除后重试
    private func retryWithFieldRemoval(
        newFields: inout [String: Any],
        issueTypeId: String?,
        error: Error,
        fieldOptions: [String: [[String: Any]]],
        logger: (String) -> Void
    ) async throws -> String {
        let errorMsg = error.localizedDescription
        if let invalidFields = parseInvalidOptionFieldsFromError(errorMsg) {
            for field in invalidFields {
                if let opts = fieldOptions[field] {
                    let available = opts.compactMap { $0["value"] as? String }.joined(separator: ", ")
                    logger("[跳过] \(field) 选项值无效，可用选项: [\(available)]")
                } else {
                    logger("[跳过] \(field) 选项值无效，无元数据可用")
                }
                newFields.removeValue(forKey: field)
            }
            return try await jira.createIssue(project: "REQ", issueType: issueTypeId ?? "", fields: newFields)
        }
        throw error
    }

    private func cloneCascading(_ value: Any?) -> Any {
        // 级联字段结构：{value, id, child: {value, id}}；只保留 value/id/child
        guard let dict = value as? [String: Any] else { return [String: Any]() }
        var out: [String: Any] = [:]
        if let v = dict["value"] as? String { out["value"] = v }
        if let i = dict["id"] as? String { out["id"] = i }
        if let child = dict["child"] as? [String: Any] {
            var c: [String: Any] = [:]
            if let v = child["value"] as? String { c["value"] = v }
            if let i = child["id"] as? String { c["id"] = i }
            out["child"] = c
        }
        return out
    }

    /// 对“选项类”字段（单选/多选/级联）：按名字反查 id，使用 createmeta 元数据解析正确的 option id
    private func applyFieldByName(
        newFields: inout [String: Any],
        templateFields: [String: Any],
        nameToId: [String: String],
        candidateNames: [String],
        stringValue: String,
        fieldOptions: [String: [[String: Any]]],
        fieldSchemaTypes: [String: String],
        logger: @escaping (String) -> Void
    ) {
        guard !stringValue.isEmpty else { return }
        guard let cfId = resolveCustomFieldId(nameToId: nameToId, candidates: candidateNames, logger: logger) else {
            logger("[跳过] 未在模板中找到字段：\(candidateNames.joined(separator: "/"))")
            return
        }
        let templateVal = templateFields[cfId]
        let metaOptions = fieldOptions[cfId]

        // 模板字段为单选/级联 dict
        if let dict = templateVal as? [String: Any] {
            if let metaOptions = metaOptions {
                // 有元数据：解析正确的 option id
                if let matched = findOptionByValue(allowedValues: metaOptions, targetValue: stringValue) {
                    var result: [String: Any] = [:]
                    if let id = matched["id"] as? String { result["id"] = id }
                    if let v = matched["value"] as? String { result["value"] = v }
                    // 级联字段：处理 child
                    if let templateChild = dict["child"] as? [String: Any],
                       let childVal = templateChild["value"] as? String, !childVal.isEmpty {
                        if let children = matched["children"] as? [[String: Any]] {
                            if let childMatched = findOptionByValue(allowedValues: children, targetValue: childVal) {
                                var c: [String: Any] = [:]
                                if let id = childMatched["id"] as? String { c["id"] = id }
                                if let v = childMatched["value"] as? String { c["value"] = v }
                                result["child"] = c
                                logger("[设置] \(cfId) = \(stringValue) > \(childVal) (id 匹配成功)")
                            } else {
                                result["child"] = ["value": childVal]
                                logger("[设置] \(cfId) = \(stringValue) (父级 id 匹配，子选项 '\(childVal)' 未匹配到 id)")
                            }
                        }
                    } else {
                        logger("[设置] \(cfId) = \(stringValue) (id=\(matched["id"] as? String ?? ""))")
                    }
                    newFields[cfId] = result
                } else {
                    let available = metaOptions.compactMap { $0["value"] as? String }.joined(separator: ", ")
                    logger("[跳过] \(cfId) 元数据中未找到匹配 '\(stringValue)' 的选项，可用选项: [\(available)]")
                }
            } else {
                // 无元数据：仅发送 value
                var out: [String: Any] = [:]
                out["value"] = stringValue
                if let child = dict["child"] as? [String: Any] {
                    var c: [String: Any] = [:]
                    if let v = child["value"] as? String { c["value"] = v }
                    out["child"] = c
                }
                newFields[cfId] = out
                logger("[设置] \(cfId) = \(stringValue) (无元数据，按 value)")
            }
            return
        }
        // 模板字段为多选 [dict]
        if templateVal is [[String: Any]] {
            if let metaOptions = metaOptions {
                if let matched = findOptionByValue(allowedValues: metaOptions, targetValue: stringValue) {
                    var item: [String: Any] = [:]
                    if let id = matched["id"] as? String { item["id"] = id }
                    if let v = matched["value"] as? String { item["value"] = v }
                    newFields[cfId] = [item]
                    logger("[设置] \(cfId) = [\(stringValue)] (id 匹配成功)")
                    return
                }
                let available = metaOptions.compactMap { $0["value"] as? String }.joined(separator: ", ")
                logger("[跳过] \(cfId) 元数据中未找到匹配 '\(stringValue)' 的选项，可用选项: [\(available)]")
                return
            }
            let first: [String: Any] = ["value": stringValue]
            newFields[cfId] = [first]
            logger("[设置] \(cfId) = [\(stringValue)] (无元数据，按 value)")
            return
        }
        // 字符串字段
        if templateVal is String || templateVal is NSNull || templateVal == nil {
            // 检查 createmeta schema 判断是否为选项/级联字段（模板值为 null 但字段实际是选项类型）
            if templateVal == nil, let schemaType = fieldSchemaTypes[cfId],
               schemaType == "option" || schemaType == "cascadingSelect" {
                // 选项/级联字段但模板无值，无法确定正确的 option id，跳过
                if let opts = fieldOptions[cfId] {
                    let available = opts.compactMap { $0["value"] as? String }.joined(separator: ", ")
                    logger("[跳过] \(cfId) 是\(schemaType)类型字段但模板无值，无法设置 '\(stringValue)'，可用选项: [\(available)]")
                } else {
                    logger("[跳过] \(cfId) 是\(schemaType)类型字段但模板无值，无法设置 '\(stringValue)'")
                }
                return
            }
            newFields[cfId] = stringValue
            return
        }
        logger("[跳过] 字段 \(cfId) 模板结构未知，忽略: \(candidateNames.joined(separator: "/"))")
    }

    /// 在 allowedValues 中按 value 文本查找匹配的选项
    /// 匹配优先级：精确匹配 > 忽略大小写/空格 > 包含匹配
    private func findOptionByValue(allowedValues: [[String: Any]], targetValue: String) -> [String: Any]? {
        // 1. 精确匹配
        if let exact = allowedValues.first(where: { ($0["value"] as? String) == targetValue }) {
            return exact
        }
        // 2. 忽略大小写和首尾空格
        let trimmed = targetValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fuzzy = allowedValues.first(where: {
            ($0["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return fuzzy
        }
        // 3. 包含匹配（选项值包含用户输入，或用户输入包含选项值）
        if let contains = allowedValues.first(where: {
            guard let optVal = ($0["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return optVal.caseInsensitiveCompare(trimmed) == .orderedSame
                || optVal.contains(trimmed)
                || trimmed.contains(optVal)
        }) {
            return contains
        }
        return nil
    }

    /// 用户字段：按名字反查 id，写入 {name: userName}
    private func applyUserFieldByName(
        newFields: inout [String: Any],
        templateFields: [String: Any],
        nameToId: [String: String],
        candidateNames: [String],
        userName: String,
        logger: @escaping (String) -> Void
    ) {
        guard !userName.isEmpty else { return }
        guard let cfId = resolveCustomFieldId(nameToId: nameToId, candidates: candidateNames, logger: logger) else {
            logger("[跳过] 未在模板中找到用户字段：\(candidateNames.joined(separator: "/"))")
            return
        }
        let templateVal = templateFields[cfId]
        // 模板字段是字符串（"登录名"）
        if templateVal is String {
            newFields[cfId] = userName
            return
        }
        // 模板字段是数组（多用户）
        if templateVal is [[String: Any]] {
            newFields[cfId] = [["name": userName]]
            return
        }
        // 默认当作单用户 {name: ...}
        newFields[cfId] = ["name": userName]
    }

    private func resolveCustomFieldId(nameToId: [String: String], candidates: [String], logger: ((String) -> Void)? = nil) -> String? {
        for c in candidates {
            if let id = nameToId[c] {
                logger?("[字段匹配] '\(c)' → \(id) (精确匹配)")
                return id
            }
        }
        // 模糊匹配：包含候选名的 key
        for (name, id) in nameToId {
            for c in candidates where name.contains(c) {
                logger?("[字段匹配] '\(c)' → \(id) (模糊匹配, 字段名='\(name)')")
                return id
            }
        }
        return nil
    }

    /// 若 drafter 是中文姓名，尝试通过 /user/search 反查登录名；失败则按原值返回
    private func resolveUserLogin(_ drafter: String, logger: (String) -> Void) async -> String {
        // 简单判断：全英文/数字 → 直接当登录名
        if drafter.range(of: "[A-Za-z0-9_.\\-]+", options: .regularExpression)?.upperBound == drafter.endIndex,
           !drafter.contains(where: { $0.unicodeScalars.contains(where: { $0.value > 127 }) }) {
            return drafter
        }
        do {
            let arr = try await jira.searchUsers(query: drafter)
            // 先找 displayName 完全等于的
            if let hit = arr.first(where: { ($0["displayName"] as? String) == drafter }),
               let name = hit["name"] as? String {
                return name
            }
            if let name = arr.first?["name"] as? String {
                return name
            }
        } catch {
            logger("[提示] 反查 Jira 用户失败 (\(drafter)): \(error.localizedDescription)")
        }
        return drafter
    }

    /// 从 OA 链接提取 baseURL（强制 https）
    private func extractBaseURL(from link: String) -> String {
        guard let u = URL(string: link), let host = u.host else { return link }
        let scheme = "https"
        if let port = u.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}
