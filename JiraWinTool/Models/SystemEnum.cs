using Newtonsoft.Json.Linq;

namespace JiraWinTool.Models;

/// <summary>系统枚举（移植自 Swift SystemEnum.swift）</summary>
public enum SystemEnum
{
    Regist, Clm, Cilog, Tps, Antifraud, Cps, Rclm, Ams, Law,
    Zz, Zzuser, Pvs, ClmCommonService, Tpms, Css, Dayu,
    Sclm, Mclm, Workbench, Share
}

public static class SystemEnumExtensions
{
    public static string RawValue(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => "REGIST",
        SystemEnum.Clm => "CLM",
        SystemEnum.Cilog => "CILOG",
        SystemEnum.Tps => "TPS",
        SystemEnum.Antifraud => "ANTIFRAUD",
        SystemEnum.Cps => "CPS",
        SystemEnum.Rclm => "RCLM",
        SystemEnum.Ams => "AMS",
        SystemEnum.Law => "LAW",
        SystemEnum.Zz => "ZZ",
        SystemEnum.Zzuser => "ZZUSER",
        SystemEnum.Pvs => "PVS",
        SystemEnum.ClmCommonService => "CLM-COMMON-SERVICE",
        SystemEnum.Tpms => "TPMS",
        SystemEnum.Css => "CSS",
        SystemEnum.Dayu => "DAYU",
        SystemEnum.Sclm => "SCLM",
        SystemEnum.Mclm => "MCLM",
        SystemEnum.Workbench => "WORKBENCH",
        SystemEnum.Share => "SHARE",
        _ => ""
    };

    public static string SystemCode(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => "B19", SystemEnum.Clm => "B01", SystemEnum.Cilog => "B07",
        SystemEnum.Tps => "B12", SystemEnum.Antifraud => "B15", SystemEnum.Cps => "B22",
        SystemEnum.Rclm => "B23", SystemEnum.Ams => "B24", SystemEnum.Law => "D05",
        SystemEnum.Zz => "207", SystemEnum.Zzuser => "208", SystemEnum.Pvs => "25",
        SystemEnum.ClmCommonService => "B30", SystemEnum.Tpms => "B29", SystemEnum.Css => "26",
        SystemEnum.Dayu => "B18", SystemEnum.Sclm => "B02", SystemEnum.Mclm => "B13",
        SystemEnum.Workbench => "B09", SystemEnum.Share => "SHARE",
        _ => ""
    };

    public static string SystemName(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => "报案微服务", SystemEnum.Clm => "新核心理赔系统",
        SystemEnum.Cilog => "理赔iLog", SystemEnum.Tps => "第三方供应商管理平台",
        SystemEnum.Antifraud => "无间盾（反欺诈）中台", SystemEnum.Cps => "消保投诉防控系统",
        SystemEnum.Rclm => "意健险理赔系统", SystemEnum.Ams => "配件管理系统",
        SystemEnum.Law => "诉讼系统", SystemEnum.Zz => "增值服务",
        SystemEnum.Zzuser => "增值服务-会员系统", SystemEnum.Pvs => "精友视频系统",
        SystemEnum.ClmCommonService => "理赔公共服务", SystemEnum.Tpms => "第三方管理服务",
        SystemEnum.Css => "调度微服务", SystemEnum.Dayu => "自动核价核损（大禹）",
        SystemEnum.Sclm => "自助理赔中台管理系统", SystemEnum.Mclm => "理赔案件中台(短信)",
        SystemEnum.Workbench => "工作台", SystemEnum.Share => "理赔核心SHARE",
        _ => ""
    };

    public static string SystemId(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => "15700", SystemEnum.Clm => "12405", SystemEnum.Cilog => "14119",
        SystemEnum.Tps => "14373", SystemEnum.Antifraud => "14588", SystemEnum.Cps => "14708",
        SystemEnum.Rclm => "14728", SystemEnum.Ams => "14738", SystemEnum.Law => "13431",
        SystemEnum.Zz => "14820", SystemEnum.Zzuser => "15453", SystemEnum.Pvs => "14741",
        SystemEnum.ClmCommonService => "15701", SystemEnum.Tpms => "15701", SystemEnum.Css => "15701",
        SystemEnum.Dayu => "15701", SystemEnum.Sclm => "15701", SystemEnum.Mclm => "15701",
        SystemEnum.Workbench => "14621", SystemEnum.Share => "15701",
        _ => ""
    };

    public static string SystemIdReq(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => "14629", SystemEnum.Clm => "12420", SystemEnum.Cilog => "",
        SystemEnum.Tps => "14604", SystemEnum.Antifraud => "14590", SystemEnum.Cps => "14710",
        SystemEnum.Rclm => "14730", SystemEnum.Ams => "14740", SystemEnum.Law => "13459",
        SystemEnum.Zz => "15364", SystemEnum.Zzuser => "15364", SystemEnum.Pvs => "14741",
        SystemEnum.ClmCommonService => "", SystemEnum.Tpms => "14976", SystemEnum.Css => "14741",
        SystemEnum.Dayu => "14628", SystemEnum.Sclm => "13457", SystemEnum.Mclm => "14591",
        SystemEnum.Workbench => "14622", SystemEnum.Share => "",
        _ => ""
    };

    public static int InitYear(this SystemEnum e) => e switch
    {
        SystemEnum.Regist => 2021, SystemEnum.Clm => 2017, SystemEnum.Cilog => 2018,
        SystemEnum.Tps => 2020, SystemEnum.Antifraud => 2021, SystemEnum.Cps => 2022,
        SystemEnum.Rclm => 2022, SystemEnum.Ams => 2023, SystemEnum.Law => 2018,
        SystemEnum.Zz => 2025, SystemEnum.Zzuser => 2025, SystemEnum.Pvs => 2021,
        SystemEnum.ClmCommonService => 2024, SystemEnum.Tpms => 2023, SystemEnum.Css => 2025,
        SystemEnum.Dayu => 2021, SystemEnum.Sclm => 2017, SystemEnum.Mclm => 2020,
        SystemEnum.Workbench => 2019, SystemEnum.Share => 2024,
        _ => 2020
    };

    public static SystemEnum? GetBySystemPublishName(string name)
        => Enum.GetValues<SystemEnum>().FirstOrDefault(e => e.RawValue() == name);

    public static SystemEnum? GetBySystemIdReq(string id)
        => Enum.GetValues<SystemEnum>().FirstOrDefault(e => e.SystemIdReq() == id && !string.IsNullOrEmpty(e.SystemIdReq()));

    public static string GetSvnLocation(this SystemEnum e, string versionId) => e switch
    {
        SystemEnum.Clm => $"http://svn.sinosafe.com.cn:1580/svn/NEWPCIS/06.上线发布/理赔/{versionId}",
        SystemEnum.Ams or SystemEnum.Cilog => "http://git.sinosafe.com.cn/serve_develop_group/ams_plat/ams_parent_domain",
        SystemEnum.Cps => "http://git.sinosafe.com.cn/serve_develop_group/cps-plat/cps-parent-domain.git",
        SystemEnum.Dayu => "http://git.sinosafe.com.cn/serve_develop_group/clm_auto_approve_evaluate/clm_auto_approve_evaluate.git",
        SystemEnum.Mclm => "http://git.sinosafe.com.cn/serve_develop_group/claim_mid_plat.git",
        SystemEnum.Sclm => "http://git.sinosafe.com.cn/serve_develop_group/claim_mid_plat_self.git",
        SystemEnum.Tps => "http://git.sinosafe.com.cn/serve_develop_group/third_party_supplier_administrator/third_party_supplier.git",
        SystemEnum.Tpms => "http://git.sinosafe.com.cn/serve_develop_group/tpms-plat/tpms-parent-domain",
        SystemEnum.Rclm => "http://git.sinosafe.com.cn/serve_develop_group/core_claim/core_claim_domain.git",
        SystemEnum.Regist => "http://git.sinosafe.com.cn/serve_develop_group/clm_regist_server/clm_report_server.git",
        SystemEnum.Antifraud => "http://git.sinosafe.com.cn/serve_develop_group/clm_anti_fraud_plat/clm_anti_fraud_plat.git",
        SystemEnum.Workbench => "http://git.sinosafe.com.cn/serve_develop_group/clm_work_bench/clm_work_bench_group/workbench.git",
        SystemEnum.Css or SystemEnum.Share => "http://git.sinosafe.com.cn/serve_develop_group/claim-share-domain",
        SystemEnum.ClmCommonService => "http://git.sinosafe.com.cn/serve_develop_group/claim-share-domain;http://git.sinosafe.com.cn/serve_develop_group/claim-search-domain;",
        SystemEnum.Law => $"http://svn.sinosafe.com.cn:1580/svn/NEWPCIS/06.上线发布/诉讼/{versionId}",
        SystemEnum.Zz => "http://git.sinosafe.com.cn/ha-ds-pup/offer-plat",
        SystemEnum.Zzuser => "http://git.sinosafe.com.cn/ha-ds-pup/vip",
        SystemEnum.Pvs => "无",
        _ => ""
    };

    public static string[] GetPublishChooseNames(this SystemEnum e) => e switch
    {
        SystemEnum.Clm => new[] { "发布升级包文件" },
        SystemEnum.Cilog => new[] { "发布升级包文件", "发布ilog规则" },
        _ => new[] { "容器发布" }
    };

    /// <summary>所有可用的系统枚举值</summary>
    public static SystemEnum[] AllCases => Enum.GetValues<SystemEnum>();
}
