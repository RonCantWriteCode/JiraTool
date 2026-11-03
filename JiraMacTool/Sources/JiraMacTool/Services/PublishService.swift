import Foundation

actor PublishService {
    static let shared = PublishService()
    private init() {}

    private let jira = JiraService.shared
    private let CREAT_PUBLISH_FLAG = true
    private let MULTI_BANBEN_FLAG = true

    // MARK: - Create Publish by Date

    func createPublishByDate(date: String, noPublishId: String?) async -> String {
        var logBuilder = ""
        logBuilder += "\(date) 版本publish：\n"

        do {
            let jql = "预计修复时间 = \"\(date)\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC"
            logBuilder += "执行 JQL: \(jql)\n"
            let issues = try await jira.searchJQL(jql)
            logBuilder += "✅ JQL 查到 \(issues.count) 个 REQ\n"
            var allVersion = Set<String>()

            for issue in issues {
                guard let versions = issue.customField("customfield_10126") as? [[String: Any]] else {
                    logBuilder += "⚠️ \(issue.key) customfield_10126 为空或类型不匹配，实际类型: \(type(of: issue.customField("customfield_10126")))\n"
                    continue
                }
                for (index, versionDict) in versions.enumerated() {
                    if index > 0 && !MULTI_BANBEN_FLAG { continue }
                    if let versionId = versionDict["name"] as? String {
                        if let noPublishId = noPublishId, versionId == noPublishId { continue }
                        allVersion.insert(versionId)
                    } else {
                        logBuilder += "⚠️ \(issue.key) 版本号name为空，原始值: \(versionDict)\n"
                    }
                }
            }

            logBuilder += "提取到 \(allVersion.count) 个版本号: \(allVersion.sorted().joined(separator: ", "))\n"

            for versionId in allVersion {
                let parts = versionId.split(separator: "_")
                guard parts.count > 1 else {
                    logBuilder += "⚠️ 版本号[\(versionId)]没有下划线分隔，无法拆分系统前缀\n"
                    continue
                }
                let banben = String(parts[0])

                guard let systemEnum = SystemEnum.getBySystemPublishName(banben) else {
                    logBuilder += "⚠️ 获取不到系统对应的publish类: \(banben)\n"
                    continue
                }

                let (result, detailLog) = await createPublish(issue: nil, versionId: versionId, systemEnum: systemEnum)
                logBuilder += detailLog
                if let result = result {
                    logBuilder += "✅ \(result.issueKey) \(systemEnum.systemName)上线发布申请【\(result.relateIssueName.joined(separator: "、"))】\n"
                }
            }

            logBuilder += "\nps：根据目前 REQ 现状（版本号+上线日期）建的 PUBLISH，如后续对应 REQ 有调整，REQ相关人记得同步修改 publish"
            return logBuilder
        } catch {
            return logBuilder + "❌ 查询失败: \(error.localizedDescription)\n"
        }
    }

    // MARK: - Create Publish by REQ

    func createPublishByReq(reqId: String, banbenhao: String?) async -> String {
        do {
            let issue = try await jira.getIssue(reqId)
            var logs = "✅ 获取到 REQ: \(issue.key)\n"

            guard let versions = issue.customField("customfield_10126") as? [[String: Any]] else {
                let actualType = type(of: issue.customField("customfield_10126"))
                return "❌ 该 REQ 没有开发版本号 (customfield_10126 类型: \(actualType))\n"
            }

            logs += "开发版本号原始值: \(versions.map { $0["name"] ?? "(无name)" })\n"

            for (index, versionDict) in versions.enumerated() {
                if index > 0 && !MULTI_BANBEN_FLAG { continue }
                guard let versionId = versionDict["name"] as? String else {
                    logs += "⚠️ 版本号[\(index)]无法读取name，原始值: \(versionDict)\n"
                    continue
                }

                if versionId.contains("ZZUSER") {
                    logs += "⏭️ 跳过 ZZUSER 版本号: \(versionId)\n"
                    continue
                }

                if let banbenhao = banbenhao, !banbenhao.isEmpty, versionId != banbenhao {
                    logs += "⏭️ 跳过不匹配版本号: \(versionId) (指定: \(banbenhao))\n"
                    continue
                }

                let parts = versionId.split(separator: "_")
                guard parts.count > 1 else {
                    logs += "⚠️ 版本号[\(versionId)]没有下划线分隔，无法拆分系统前缀\n"
                    continue
                }
                let banben = String(parts[0])
                logs += "版本号拆分: 前缀=\(banben), 版本=\(versionId)\n"

                guard let systemEnum = SystemEnum.getBySystemPublishName(banben) else {
                    logs += "⚠️ 获取不到系统对应的publish类: \(banben)，可用的前缀: \(SystemEnum.allCases.map(\.rawValue))\n"
                    continue
                }

                let (result, detailLog) = await createPublish(issue: issue, versionId: versionId, systemEnum: systemEnum)
                logs += detailLog
                if let result = result {
                    logs += "✅ 成功创建: \(result.issueKey)\n"
                }
            }
            return logs.isEmpty ? "没有需要创建的 publish" : logs
        } catch {
            return "❌ 查询 REQ 失败: \(error.localizedDescription)\n"
        }
    }

    // MARK: - Core Create Publish

    func createPublish(issue: JiraIssue?, versionId: String, systemEnum: SystemEnum) async -> (MyResultIssue?, String) {
        var log = ""

        guard CREAT_PUBLISH_FLAG else {
            return (nil, "⚠️ CREAT_PUBLISH_FLAG = false，跳过创建\n")
        }

        // Step 1: JQL 搜索关联 REQ
        let jql = "project = REQ AND 开发版本号 = \"\(versionId)\" ORDER BY priority ASC"
        log += "📋 执行 JQL: \(jql)\n"

        let issues: [JiraIssue]
        do {
            issues = try await jira.searchJQL(jql)
        } catch {
            return (nil, log + "❌ JQL 查询失败: \(error.localizedDescription)\n")
        }
        log += "✅ JQL 查到 \(issues.count) 个关联 REQ\n"

        if issues.isEmpty {
            return (nil, log + "❌ 未查到版本号 \(versionId) 对应的 REQ，无法创建 PUBLISH\n")
        }

        // Step 2: 汇总 REQ 数据
        var relateIssueName: [String] = []
        var reqDesc = ""
        var develop = Set<String>()
        var peizhishuoming = ""
        var fixtimeValue: String?

        var publishItemList: [PublishItemDto] = [
            PublishItemDto(itemName: "代码", exists: "无", remark: "-"),
            PublishItemDto(itemName: "数据库脚本", exists: "无", remark: "-"),
            PublishItemDto(itemName: "env与share文件", exists: "无", remark: "-"),
            PublishItemDto(itemName: "Groovy更新", exists: "无", remark: "-"),
            PublishItemDto(itemName: "MQ队列", exists: "无", remark: "-"),
            PublishItemDto(itemName: "Dubbo配置", exists: "无", remark: "-"),
            PublishItemDto(itemName: "nacos配置", exists: "无", remark: "-"),
            PublishItemDto(itemName: "DDL脚本", exists: "无", remark: "-")
        ]

        for reqIssue in issues {
            relateIssueName.append(reqIssue.key)
            let displayName = extractDisplayName(from: reqIssue, fieldId: "customfield_11923")
            develop.insert(displayName)
            reqDesc += "\(reqIssue.key) \(reqIssue.summary) 【\(displayName)】\n"

            if issue == nil {
                if let configRemark = reqIssue.fields["customfield_10724"] {
                    peizhishuoming = String(describing: configRemark)
                }
                if fixtimeValue == nil, let ft = reqIssue.fields["customfield_10919"] as? String {
                    fixtimeValue = ft
                }
            }

            dealPublishItem(issue: reqIssue, publishItemList: &publishItemList)
        }

        peizhishuoming = printPublishItem(publishItemList, versionId: versionId, systemEnum: systemEnum)

        let summary = "\(systemEnum.systemName)\(versionId)上线发布申请"

        // Step 3: 获取修复日期
        var fixtime: String
        if let issue = issue {
            if let ft = issue.fields["customfield_10919"] as? String {
                fixtime = ft
            } else {
                return (nil, log + "❌ 源 REQ 的 customfield_10919(预计修复时间) 为空，无法创建 PUBLISH\n")
            }
        } else if let ft = fixtimeValue {
            fixtime = ft
        } else {
            return (nil, log + "❌ 所有关联 REQ 均无 customfield_10919(预计修复时间)，无法创建 PUBLISH\n")
        }
        log += "📅 预计修复时间: \(fixtime)\n"

        // Step 4: 组装 fields
        let fixtimeDatetime = "\(fixtime)T21:00:00.000+0800"
        var fields: [String: Any] = [
            "project": ["key": "PUBLISH"],
            "issuetype": ["id": "10404"],
            "summary": summary,
            "customfield_10719": versionId,
            "customfield_10723": systemEnum.getSvnLocation(versionId: versionId),
            "customfield_10721": fixtimeDatetime,
            "customfield_10720": reqDesc
        ]

        // Schedule type
        let calendar = Calendar.current
        let fixDate = DateUtils.formateStringToDate(fixtime) ?? Date()
        let weekday = calendar.component(.weekday, from: fixDate)

        if versionId.hasSuffix(".0") {
            fields["customfield_10760"] = jira.getFieldString(name: "排期类型", value: "紧急", id: "11326")
            if let issue = issue, let reqTypeJson = issue.fields["customfield_13220"] as? [String: Any],
               let reqType = reqTypeJson["value"] as? String, reqType == "专题" {
                fields["customfield_10760"] = jira.getFieldString(name: "排期类型", value: "专题", id: "14612")
            }
        } else if weekday == 5 { // Thursday
            fields["customfield_10760"] = jira.getFieldString(name: "排期类型", value: "紧急", id: "11326")
        } else {
            fields["customfield_10760"] = jira.getFieldString(name: "排期类型", value: "常规", id: "11325")
        }

        fields["customfield_10727"] = jira.getFieldString(name: "自测结论", value: "自测通过", id: "11255")
        fields["customfield_12600"] = jira.getFieldString(name: "包含新产品", value: "不包含", id: "14205")
        fields["customfield_12300"] = jira.getFieldString(name: "风险等级", value: "低", id: "13902")
        fields["customfield_10724"] = peizhishuoming

        // System field
        let systemParent: [String: Any]
        if systemEnum.systemCode == "D05" {
            systemParent = [
                "self": "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/10886",
                "value": "Y辅助支持类（*新核心）",
                "id": "10886",
                "child": jira.getFieldString(name: systemEnum.systemName, value: "\(systemEnum.systemCode) \(systemEnum.systemName)", id: systemEnum.systemId)
            ]
        } else {
            systemParent = [
                "self": "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/10852",
                "value": "B理赔服务类",
                "id": "10852",
                "child": jira.getFieldString(name: systemEnum.systemName, value: "\(systemEnum.systemCode) \(systemEnum.systemName)", id: systemEnum.systemId)
            ]
        }
        fields["customfield_10501"] = systemParent

        // Publish choose items
        var publishChoose: [[String: Any]] = []
        for name in systemEnum.getPublishChooseNames() {
            if let fv = PublishChooseCodeEnum.makeFieldValue(name: name) {
                publishChoose.append(fv)
            }
        }

        if publishItemList[1].exists == "有" {
            // 2026-01-14 注释掉：不再添加"发布数据库脚本-DBA执行"
        }
        if publishItemList[7].exists == "有" {
            // 2026-01-14 注释掉：不再添加"有DDL脚本-需数据应用室审核"
        }
        fields["customfield_10722"] = publishChoose

        // Version type
        fields["customfield_10759"] = [jira.getFieldString(name: "版本类型", value: "需求", id: "11322")]

        // Test line
        fields["customfield_13101"] = [jira.getFieldString(name: "测试条线归属", value: "服务条线", id: "14809")]

        // Step 5: 打印完整 fields 用于诊断
        log += "📦 创建 PUBLISH 字段:\n"
        log += "  summary: \(summary)\n"
        log += "  customfield_10719(版本号): \(versionId)\n"
        log += "  customfield_10721(发布时间): \(fixtimeDatetime)\n"
        log += "  customfield_10501(系统分类): id=\(systemEnum.systemCode), systemId=\(systemEnum.systemId)\n"
        log += "  customfield_10722(发布选择项): \(publishChoose.map { $0["value"] ?? "?" })\n"
        log += "  customfield_10760(排期类型): \(String(describing: fields["customfield_10760"]))\n"

        // Step 6: 创建 Issue
        let publishKey: String
        do {
            publishKey = try await jira.createIssue(project: "PUBLISH", issueType: "10404", fields: fields)
            log += "✅ 创建 PUBLISH 成功: \(publishKey)\n"
        } catch {
            return (nil, log + "❌ 创建 PUBLISH 失败: \(error.localizedDescription)\n")
        }

        // Step 7: 后续操作（评论、标签、链接、转交）
        var specialLabels = Set<String>()
        for reqIssue in issues {
            do {
                try await jira.addComment(issueKey: reqIssue.key, body: "\(systemEnum.systemName) : \(publishKey)")

                var labels = Set(reqIssue.labels)
                labels.insert("[\(systemEnum.rawValue)]\(publishKey)")

                let devName = extractDisplayName(from: reqIssue, fieldId: "customfield_11923")
                if !devName.isEmpty {
                    labels.insert(devName)
                }

                try await jira.updateIssue(reqIssue.key, fields: ["labels": Array(labels)])

                for label in reqIssue.labels {
                    if label.contains("同步上线") {
                        specialLabels.insert(label)
                    }
                }

                try await jira.linkIssues(from: publishKey, to: reqIssue.key)
            } catch {
                log += "⚠️ REQ \(reqIssue.key) 后续操作失败: \(error.localizedDescription)\n"
            }
        }

        // Update publish labels
        do {
            let publishIssue = try await jira.getIssue(publishKey)
            var publishLabels = Set(publishIssue.labels)
            publishLabels.insert("[\(systemEnum.rawValue)]\(publishKey)")
            publishLabels.formUnion(specialLabels)
            try await jira.updateIssue(publishKey, fields: ["labels": Array(publishLabels)])
        } catch {
            log += "⚠️ PUBLISH 标签更新失败: \(error.localizedDescription)\n"
        }

        // Transition to submit test (451)
        do {
            try await jira.transitionIssue(issueKey: publishKey, transitionId: "451")
            log += "✅ 已提交测试\n"
        } catch {
            log += "⚠️ 提交测试失败: \(error.localizedDescription)\n"
        }

        // Update assignee
        do {
            try await jira.updateIssue(publishKey, fields: ["assignee": ["name": "lisonglin"]])
            log += "✅ 已设置经办人\n"
        } catch {
            log += "⚠️ 设置经办人失败: \(error.localizedDescription)\n"
        }

        return (MyResultIssue(issueKey: publishKey, relateIssueName: relateIssueName), log)
    }

    // MARK: - Helpers

    private func dealPublishItem(issue: JiraIssue, publishItemList: inout [PublishItemDto]) {
        for itemEnum in PublishItemEnum.allCases {
            guard itemEnum.rawValue < publishItemList.count else { continue }
            if publishItemList[itemEnum.rawValue].exists == "有" { continue }

            if let fieldValue = issue.fields[itemEnum.systemName] as? [String: Any],
               let value = fieldValue["value"] as? String,
               value == "有变更" {
                publishItemList[itemEnum.rawValue].exists = "有"
            }
        }
    }

    private func printPublishItem(_ list: [PublishItemDto], versionId: String, systemEnum: SystemEnum) -> String {
        var result = "||条目||有/无||备注||\n"
        for i in 0..<min(7, list.count) {
            let dto = list[i]
            result += "|\(dto.itemName)|\(dto.exists)|"

            var third = "-"
            if dto.itemName == "数据库脚本" && dto.exists == "有" && versionId.hasPrefix("CLM_V") {
                third = systemEnum.getSvnLocation(versionId: versionId)
            }
            result += "\(third)|\n"
        }
        return result
    }

    private func extractDisplayName(from issue: JiraIssue, fieldId: String) -> String {
        guard let fieldValue = issue.fields[fieldId] as? [String: Any] else { return "" }
        return fieldValue["displayName"] as? String ?? ""
    }
}
