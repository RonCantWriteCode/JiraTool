import Foundation

enum PublishChooseCodeEnum: String, CaseIterable {
    case emergency = "紧急版本(需领导审批)"
    case dbScriptDBA = "发布数据库脚本-DBA执行"
    case dbScriptAuto = "发布数据库脚本-自动发布"
    case ddl = "有DDL脚本-需数据应用室审核"
    case upgradePackage = "发布升级包文件"
    case ilogRule = "发布ilog规则"
    case container = "容器发布"
    case dataCleanup = "涉及在途数据清理"
    case networkChange = "涉及网络变更(含CDN、平台地址等)"
    case envChange = "涉及基础环境变更"
    case appConfig = "涉及应用配置变更"
    case mqConfig = "涉及到MQ的配置"
    case ecommerce = "涉及电子商务部系统"
    case creditInsurance = "涉及信保事业部系统"

    var chooseCode: String {
        switch self {
        case .emergency: return "13600"
        case .dbScriptDBA: return "11248"
        case .dbScriptAuto: return "13670"
        case .ddl: return "12801"
        case .upgradePackage: return "11400"
        case .ilogRule: return "14404"
        case .container: return "14370"
        case .dataCleanup: return "14880"
        case .networkChange: return "13446"
        case .envChange: return "11249"
        case .appConfig: return "14214"
        case .mqConfig: return "11413"
        case .ecommerce: return "13306"
        case .creditInsurance: return "13671"
        }
    }

    static func getChooseCode(for name: String) -> String? {
        return PublishChooseCodeEnum.allCases.first { $0.rawValue == name }?.chooseCode
    }

    static func makeFieldValue(name: String) -> [String: Any]? {
        guard let code = getChooseCode(for: name) else { return nil }
        return [
            "self": "http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/\(code)",
            "id": code,
            "value": name
        ]
    }
}
