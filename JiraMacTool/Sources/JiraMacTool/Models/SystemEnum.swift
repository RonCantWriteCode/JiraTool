import Foundation

enum SystemEnum: String, CaseIterable, Identifiable {
    case regist = "REGIST"
    case clm = "CLM"
    case cilog = "CILOG"
    case tps = "TPS"
    case antifraud = "ANTIFRAUD"
    case cps = "CPS"
    case rclm = "RCLM"
    case ams = "AMS"
    case law = "LAW"
    case zz = "ZZ"
    case zzuser = "ZZUSER"
    case pvs = "PVS"
    case clmCommonService = "CLM-COMMON-SERVICE"
    case tpms = "TPMS"
    case css = "CSS"
    case dayu = "DAYU"
    case sclm = "SCLM"
    case mclm = "MCLM"
    case workbench = "WORKBENCH"
    case share = "SHARE"

    var id: String { rawValue }

    var systemCode: String {
        switch self {
        case .regist: return "B19"
        case .clm: return "B01"
        case .cilog: return "B07"
        case .tps: return "B12"
        case .antifraud: return "B15"
        case .cps: return "B22"
        case .rclm: return "B23"
        case .ams: return "B24"
        case .law: return "D05"
        case .zz: return "207"
        case .zzuser: return "208"
        case .pvs: return "25"
        case .clmCommonService: return "B30"
        case .tpms: return "B29"
        case .css: return "26"
        case .dayu: return "B18"
        case .sclm: return "B02"
        case .mclm: return "B13"
        case .workbench: return "B09"
        case .share: return "SHARE"
        }
    }

    var systemName: String {
        switch self {
        case .regist: return "报案微服务"
        case .clm: return "新核心理赔系统"
        case .cilog: return "理赔iLog"
        case .tps: return "第三方供应商管理平台"
        case .antifraud: return "无间盾（反欺诈）中台"
        case .cps: return "消保投诉防控系统"
        case .rclm: return "意健险理赔系统"
        case .ams: return "配件管理系统"
        case .law: return "诉讼系统"
        case .zz: return "增值服务"
        case .zzuser: return "增值服务-会员系统"
        case .pvs: return "精友视频系统"
        case .clmCommonService: return "理赔公共服务"
        case .tpms: return "第三方管理服务"
        case .css: return "调度微服务"
        case .dayu: return "自动核价核损（大禹）"
        case .sclm: return "自助理赔中台管理系统"
        case .mclm: return "理赔案件中台(短信)"
        case .workbench: return "工作台"
        case .share: return "理赔核心SHARE"
        }
    }

    var systemId: String {
        switch self {
        case .regist: return "15700"
        case .clm: return "12405"
        case .cilog: return "14119"
        case .tps: return "14373"
        case .antifraud: return "14588"
        case .cps: return "14708"
        case .rclm: return "14728"
        case .ams: return "14738"
        case .law: return "13431"
        case .zz: return "14820"
        case .zzuser: return "15453"
        case .pvs: return "14741"
        case .clmCommonService: return "15701"
        case .tpms: return "15701"
        case .css: return "15701"
        case .dayu: return "15701"
        case .sclm: return "15701"
        case .mclm: return "15701"
        case .workbench: return "14621"
        case .share: return "15701"
        }
    }

    var systemIdReq: String {
        switch self {
        case .regist: return "14629"
        case .clm: return "12420"
        case .cilog: return ""
        case .tps: return "14604"
        case .antifraud: return "14590"
        case .cps: return "14710"
        case .rclm: return "14730"
        case .ams: return "14740"
        case .law: return "13459"
        case .zz: return "15364"
        case .zzuser: return "15364"
        case .pvs: return "14741"
        case .clmCommonService: return ""
        case .tpms: return "14976"
        case .css: return "14741"
        case .dayu: return "14628"
        case .sclm: return "13457"
        case .mclm: return "14591"
        case .workbench: return "14622"
        case .share: return ""
        }
    }

    var initYear: Int {
        switch self {
        case .regist: return 2021
        case .clm: return 2017
        case .cilog: return 2018
        case .tps: return 2020
        case .antifraud: return 2021
        case .cps: return 2022
        case .rclm: return 2022
        case .ams: return 2023
        case .law: return 2018
        case .zz: return 2025
        case .zzuser: return 2025
        case .pvs: return 2021
        case .clmCommonService: return 2024
        case .tpms: return 2023
        case .css: return 2025
        case .dayu: return 2021
        case .sclm: return 2017
        case .mclm: return 2020
        case .workbench: return 2019
        case .share: return 2024
        }
    }

    static func getBySystemPublishName(_ name: String) -> SystemEnum? {
        return SystemEnum.allCases.first { $0.rawValue == name }
    }

    static func getBySystemIdReq(_ id: String) -> SystemEnum? {
        return SystemEnum.allCases.first { $0.systemIdReq == id && !$0.systemIdReq.isEmpty }
    }

    func getSvnLocation(versionId: String) -> String {
        switch self {
        case .clm:
            return "http://svn.sinosafe.com.cn:1580/svn/NEWPCIS/06.上线发布/理赔/\(versionId)"
        case .ams, .cilog:
            return "http://git.sinosafe.com.cn/serve_develop_group/ams_plat/ams_parent_domain"
        case .cps:
            return "http://git.sinosafe.com.cn/serve_develop_group/cps-plat/cps-parent-domain.git"
        case .dayu:
            return "http://git.sinosafe.com.cn/serve_develop_group/clm_auto_approve_evaluate/clm_auto_approve_evaluate.git"
        case .mclm:
            return "http://git.sinosafe.com.cn/serve_develop_group/claim_mid_plat.git"
        case .sclm:
            return "http://git.sinosafe.com.cn/serve_develop_group/claim_mid_plat_self.git"
        case .tps:
            return "http://git.sinosafe.com.cn/serve_develop_group/third_party_supplier_administrator/third_party_supplier.git"
        case .tpms:
            return "http://git.sinosafe.com.cn/serve_develop_group/tpms-plat/tpms-parent-domain"
        case .rclm:
            return "http://git.sinosafe.com.cn/serve_develop_group/core_claim/core_claim_domain.git"
        case .regist:
            return "http://git.sinosafe.com.cn/serve_develop_group/clm_regist_server/clm_report_server.git"
        case .antifraud:
            return "http://git.sinosafe.com.cn/serve_develop_group/clm_anti_fraud_plat/clm_anti_fraud_plat.git"
        case .workbench:
            return "http://git.sinosafe.com.cn/serve_develop_group/clm_work_bench/clm_work_bench_group/workbench.git"
        case .css, .share:
            return "http://git.sinosafe.com.cn/serve_develop_group/claim-share-domain"
        case .clmCommonService:
            return "http://git.sinosafe.com.cn/serve_develop_group/claim-share-domain;http://git.sinosafe.com.cn/serve_develop_group/claim-search-domain;"
        case .law:
            // LAW 系统 SVN 路径包含小写版本号处理
            return "http://svn.sinosafe.com.cn:1580/svn/NEWPCIS/06.上线发布/诉讼/\(versionId)"
        case .zz:
            return "http://git.sinosafe.com.cn/ha-ds-pup/offer-plat"
        case .zzuser:
            return "http://git.sinosafe.com.cn/ha-ds-pup/vip"
        case .pvs:
            return "无"
        }
    }

    func getPublishChooseNames() -> [String] {
        switch self {
        case .clm:
            return ["发布升级包文件"]
        case .cilog:
            return ["发布升级包文件", "发布ilog规则"]
        default:
            return ["容器发布"]
        }
    }
}
