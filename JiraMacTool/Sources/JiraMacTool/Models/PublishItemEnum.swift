import Foundation

enum PublishItemEnum: Int, CaseIterable {
    case code = 0
    case dbScript = 1
    case envShare = 2
    case groovy = 3
    case mq = 4
    case dubbo = 5
    case nacos = 6
    case ddl = 7

    var systemName: String {
        switch self {
        case .code: return "【代码】"
        case .dbScript: return "【数据库脚本】"
        case .envShare: return "【env与share文件】"
        case .groovy: return "【Groovy更新】"
        case .mq: return "【MQ队列】"
        case .dubbo: return "【Dubbo配置】"
        case .nacos: return "【nacos配置】"
        case .ddl: return "DDL脚本"
        }
    }

    var itemName: String {
        switch self {
        case .code: return "代码"
        case .dbScript: return "数据库脚本"
        case .envShare: return "env与share文件"
        case .groovy: return "Groovy更新"
        case .mq: return "MQ队列"
        case .dubbo: return "Dubbo配置"
        case .nacos: return "nacos配置"
        case .ddl: return "DDL脚本"
        }
    }
}
