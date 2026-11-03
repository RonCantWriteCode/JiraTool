import Foundation

actor NoticeService {
    static let shared = NoticeService()
    private init() {}

    private let jira = JiraService.shared

    func generalPublishDes(date: String) async -> String {
        do {
            let jql = "申请发布时间 = \(date) AND 系统 in (\"B理赔服务类\",\"D05 新核心诉讼系统\") AND status != Closed AND project = 生产环境系统发布 ORDER BY createdDate DESC"
            let issues = try await jira.searchJQL(jql)

            var developMap: [String: [String: PublishDescDto]] = [:]
            var result = ""
            result += "\(date) 上线版本：\n"

            for publish in issues {
                guard let banben = publish.fields["customfield_10719"] as? String else { continue }

                let reqJql = "project = REQ and 预计修复时间 = \"\(date)\" AND 开发版本号 = \"\(banben)\" ORDER BY priority ASC"
                let reqIssues = try await jira.searchJQL(reqJql)

                for req in reqIssues {
                    var displayName = ""
                    // 系统开发人员 customfield_11923
                    if let devObj = req.fields["customfield_11923"] as? [String: Any] {
                        displayName = devObj["displayName"] as? String ?? ""
                    }
                    // 如果为空，取系统设计人员 customfield_11916
                    if displayName.isEmpty, let designObj = req.fields["customfield_11916"] as? [String: Any] {
                        displayName = designObj["displayName"] as? String ?? ""
                    }
                    // 不再 fallback 到 reporter/创建人，确保只@开发人员
                    if displayName.isEmpty {
                        displayName = "未知开发人员"
                    }

                    let reqDto = ReqDescDto(reqKey: req.key, reqDesc: req.summary, developName: displayName)

                    if developMap[displayName] == nil {
                        developMap[displayName] = [:]
                    }

                    let publishDto = PublishDescDto(
                        publishKey: publish.key,
                        summary: publish.summary,
                        banBenKey: banben,
                        reqDescDto: [reqDto]
                    )

                    if var publishMap = developMap[displayName] {
                        if var existing = publishMap[publish.key] {
                            existing.reqDescDto.append(reqDto)
                            publishMap[publish.key] = existing
                        } else {
                            publishMap[publish.key] = publishDto
                        }
                        developMap[displayName] = publishMap
                    }
                }
            }

            for (devName, publishMap) in developMap {
                result += "@\(devName)\n"
                for (pubKey, pubDto) in publishMap {
                    let reqKeys = pubDto.reqDescDto.map { $0.reqKey }.joined(separator: "、")
                    result += "核实下【\(pubKey)】(对应 【\(reqKeys)】)\n"
                }
                result += "\n"
            }

            result += "1. \"发布内容\"是否包含对应 REQ？\n"
            result += "2. \"发布操作说明\"是否说明正确（是否有代码、是否有脚本、是否有配置调整）？\n"
            result += "3. \"发布选择项\"：有脚本需额外勾选\"发布数据库脚本-DBA 执行\"，有 DDL 脚本需额外勾选\"有DDL脚本\"\n"
            result += "4. 生产分支是否已拉？（理赔核心可忽略）\n"
            result += "5. 对应上线微服务名是否明确标识？（理赔核心可忽略）\n"
            result += "\n全部确认后回复下（核实自己相关的内容即可），最迟周一上午 10点前确认回复。"

            return result
        } catch {
            return "查询失败: \(error.localizedDescription)"
        }
    }

    func generalVersionMeetingDesc(date: String) async -> String {
        guard let dateObj = DateUtils.parseDate(date) else { return "日期格式错误" }
        let meetingDate = DateUtils.addDate(dateObj, day: -21)
        let meetingDateStr = DateUtils.formatDate(meetingDate)

        var result = ""
        result += "会议：理赔版本会议【\(date)版本】\n"
        result += "时间：\(meetingDateStr) 14:00 ~ \(meetingDateStr) 15:00\n"
        result += "会议地点： 金丰城23楼1号会议室\n"
        result += "@李松林 @天晖 @罗家声\n\n"
        result += "2 点 1 号会议室\n"

        do {
            let jql = "预计修复时间 = \"\(date)\" AND 系统名称（开发） in (理赔条线, 电销条线) AND status != Closed ORDER BY cf[11923] ASC, cf[10126] ASC, cf[10106] DESC"
            let issues = try await jira.searchJQL(jql)
            var developList = Set<String>()

            for issue in issues {
                if let devObj = issue.fields["customfield_11923"] as? [String: Any] {
                    if let name = devObj["displayName"] as? String {
                        developList.insert(name)
                    }
                }
            }

            for name in developList {
                result += "@\(name) "
            }
            result += "\n"
            return result
        } catch {
            return result + "\n查询开发人员失败: \(error.localizedDescription)"
        }
    }
}
