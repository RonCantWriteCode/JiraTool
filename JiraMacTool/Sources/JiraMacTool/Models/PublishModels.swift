import Foundation

struct PublishItemDto {
    var itemName: String
    var exists: String
    var remark: String
}

struct PublishDescDto {
    var publishKey: String = ""
    var summary: String = ""
    var banBenKey: String = ""
    var reqDescDto: [ReqDescDto] = []
}

struct ReqDescDto {
    var reqKey: String = ""
    var reqDesc: String = ""
    var developName: String = ""
}

struct MyResultIssue {
    var issueKey: String = ""
    var relateIssueName: [String] = []
}

struct JiraIssue {
    let key: String
    let summary: String
    let fields: [String: Any]
    let labels: [String]
    let status: String
    let issueType: String

    func fieldValue(name: String) -> Any? {
        return fields[name]
    }

    func customField(_ id: String) -> Any? {
        return fields[id]
    }
}

struct JiraVersion {
    let id: String
    let name: String
    let description: String?
    let releaseDate: String?
    let archived: Bool
    let released: Bool
    let selfUrl: String
}

struct BanBenJiraDto {
    var reqType: String = ""
    var reqId: String = ""
    var reqName: String = ""
    var userDevelop: String = ""
    var userTest: String = ""
    var modifySystem: String = ""
    var progress: String = ""
    var scheduleLaunchDate: String = ""
    var remark: String = ""
}

struct JiraTongZhiDto {
    var reqId: String = ""
    var userNotice: Set<String> = []
    var noticeRemark: String = ""
}
