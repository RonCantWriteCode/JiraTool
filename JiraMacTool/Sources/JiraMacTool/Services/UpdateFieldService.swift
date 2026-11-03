import Foundation

actor UpdateFieldService {
    static let shared = UpdateFieldService()
    private init() {}

    private let jira = JiraService.shared

    func updateSomeField(date: String, isRegular: Bool) async -> String {
        var logs = ""
        do {
            let jql = "预计修复时间 = \"\(date)\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC"
            let issues = try await jira.searchJQL(jql)

            for issue in issues {
                var fieldsToUpdate: [String: Any] = [:]

                if isRegular {
                    fieldsToUpdate["customfield_13221"] = ["value": "是"]
                }

                // First fix date
                if let firstFixDate = issue.fields["customfield_13217"] {
                    if firstFixDate is NSNull {
                        fieldsToUpdate["customfield_13217"] = date
                    } else if let existingDate = firstFixDate as? String, existingDate != date {
                        fieldsToUpdate["customfield_13219"] = ["value": "是"]
                    }
                } else {
                    fieldsToUpdate["customfield_13217"] = date
                }

                if !fieldsToUpdate.isEmpty {
                    try await jira.updateIssue(issue.key, fields: fieldsToUpdate)
                }

                logs += "已更新: \(issue.key) \(issue.summary)\n"
            }

            return logs.isEmpty ? "没有需要更新的 issue" : logs
        } catch {
            return "更新失败: \(error.localizedDescription)"
        }
    }
}
