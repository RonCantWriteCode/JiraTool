import Foundation

actor VersionService {
    static let shared = VersionService()
    private init() {}

    private let jira = JiraService.shared

    func createVersion(date: String, systems: [SystemEnum], isUrgent: Bool) async -> String {
        var logs = ""
        logs += "\n\n已成功创建版本号：\n"

        for system in systems {
            do {
                let versionName = getVersionName(date: date, system: system, isUrgent: isUrgent)
                let description = "【理赔】- \(system.systemName) - \(date) - \(isUrgent ? "紧急版本" : "常规版本")"

                let version = try await jira.createVersion(
                    project: "REQ",
                    name: versionName,
                    description: description,
                    releaseDate: date
                )
                logs += "\(version.name)\n"
            } catch {
                logs += "创建 \(system.systemName) 版本号失败: \(error.localizedDescription)\n"
            }
        }
        return logs
    }

    func createVersionByReqDate(date: String, isUrgent: Bool) async -> String {
        do {
            let jql = "预计修复时间 = \"\(date)\" AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10126] ASC, cf[10106] DESC"
            let issues = try await jira.searchJQL(jql)
            var createdSystems = Set<SystemEnum>()
            var logs = ""

            for issue in issues {
                guard let fieldValue = issue.fields["customfield_10501"] as? [String: Any],
                      let child = fieldValue["child"] as? [String: Any],
                      let id = child["id"] as? String,
                      let system = SystemEnum.getBySystemIdReq(id) else { continue }

                if createdSystems.contains(system) { continue }
                createdSystems.insert(system)

                do {
                    _ = await createVersion(date: date, systems: [system], isUrgent: isUrgent)
                    let versionName = getVersionName(date: date, system: system, isUrgent: isUrgent)

                    // Find version and update REQ
                    let versions = try await jira.getProjectVersions(project: "REQ")
                    if let version = versions.first(where: { $0.name == versionName }) {
                        let versionField: [[String: Any]] = [[
                            "self": version.selfUrl,
                            "id": version.id,
                            "name": version.name,
                            "releaseDate": date,
                            "archived": false,
                            "released": false
                        ]]
                        try await jira.updateIssue(issue.key, fields: ["customfield_10126": versionField])
                    }
                } catch {
                    logs += "\(system.systemName) 处理失败: \(error.localizedDescription)\n"
                }
            }
            return logs
        } catch {
            return "查询失败: \(error.localizedDescription)"
        }
    }

    func deleteVersion(versionName: String) async -> String {
        do {
            let versions = try await jira.getProjectVersions(project: "REQ")
            if let version = versions.first(where: { $0.name == versionName }) {
                try await jira.deleteVersion(versionId: version.id)
                return "已删除版本号: \(versionName)"
            } else {
                return "找不到版本号: \(versionName)"
            }
        } catch {
            return "删除失败: \(error.localizedDescription)"
        }
    }

    func getVersionName(date: String, system: SystemEnum, isUrgent: Bool) -> String {
        guard let dateObj = DateUtils.parseDate(date) else { return "" }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: dateObj)
        let month = calendar.component(.month, from: dateObj)
        let day = calendar.component(.day, from: dateObj)

        let versionYearId = year - system.initYear + 1
        let lastTwoDigits = String(year).suffix(2)
        var dayStr = String(day)
        if isUrgent {
            dayStr += ".0"
        }

        return "\(system.rawValue)_V\(versionYearId)_\(lastTwoDigits).\(month).\(dayStr)"
    }
}
