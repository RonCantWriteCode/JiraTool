using Newtonsoft.Json.Linq;

namespace JiraWinTool.Models;

/// <summary>Excel 导出结果</summary>
public class ExcelExportResult
{
    public string Log { get; set; } = "";
    public string[] UnknownUsers { get; set; } = Array.Empty<string>();
    public string[] EmailList { get; set; } = Array.Empty<string>();
    public List<BanBenJiraDto> DataList { get; set; } = new();
    public string NoticeContent { get; set; } = "";
}

/// <summary>发布项枚举（移植自 Swift PublishItemEnum）</summary>
public enum PublishItemEnum
{
    Code = 0,
    DbScript = 1,
    EnvShare = 2,
    Groovy = 3,
    Mq = 4,
    Dubbo = 5,
    Nacos = 6,
    Ddl = 7
}

public static class PublishItemEnumExtensions
{
    public static string SystemName(this PublishItemEnum e) => e switch
    {
        PublishItemEnum.Code => "【代码】",
        PublishItemEnum.DbScript => "【数据库脚本】",
        PublishItemEnum.EnvShare => "【env与share文件】",
        PublishItemEnum.Groovy => "【Groovy更新】",
        PublishItemEnum.Mq => "【MQ队列】",
        PublishItemEnum.Dubbo => "【Dubbo配置】",
        PublishItemEnum.Nacos => "【nacos配置】",
        PublishItemEnum.Ddl => "DDL脚本",
        _ => ""
    };

    public static string ItemName(this PublishItemEnum e) => e switch
    {
        PublishItemEnum.Code => "代码",
        PublishItemEnum.DbScript => "数据库脚本",
        PublishItemEnum.EnvShare => "env与share文件",
        PublishItemEnum.Groovy => "Groovy更新",
        PublishItemEnum.Mq => "MQ队列",
        PublishItemEnum.Dubbo => "Dubbo配置",
        PublishItemEnum.Nacos => "nacos配置",
        PublishItemEnum.Ddl => "DDL脚本",
        _ => ""
    };
}

/// <summary>发布选择项编码（移植自 Swift PublishChooseCodeEnum）</summary>
public static class PublishChooseCode
{
    private static readonly Dictionary<string, string> Codes = new()
    {
        ["紧急版本(需领导审批)"] = "13600",
        ["发布数据库脚本-DBA执行"] = "11248",
        ["发布数据库脚本-自动发布"] = "13670",
        ["有DDL脚本-需数据应用室审核"] = "12801",
        ["发布升级包文件"] = "11400",
        ["发布ilog规则"] = "14404",
        ["容器发布"] = "14370",
        ["涉及在途数据清理"] = "14880",
        ["涉及网络变更(含CDN、平台地址等)"] = "13446",
        ["涉及基础环境变更"] = "11249",
        ["涉及应用配置变更"] = "14214",
        ["涉及到MQ的配置"] = "11413",
        ["涉及电子商务部系统"] = "13306",
        ["涉及信保事业部系统"] = "13671",
    };

    public static string? GetChooseCode(string name) => Codes.GetValueOrDefault(name);

    public static JObject? MakeFieldValue(string name)
    {
        var code = GetChooseCode(name);
        if (code == null) return null;
        return new JObject
        {
            ["self"] = $"http://jira.sinosafe.com.cn/rest/api/2/customFieldOption/{code}",
            ["id"] = code,
            ["value"] = name
        };
    }
}

/// <summary>常规版本常量（移植自 Swift PublishConstants）</summary>
public static class PublishConstants
{
    public static readonly string[] ChangguiVersion2025_34 =
    {
        "2025-07-08", "2025-07-22", "2025-08-12", "2025-08-26",
        "2025-09-09", "2025-09-23", "2025-10-21", "2025-11-11",
        "2025-11-25", "2025-12-09", "2025-12-23"
    };

    public static readonly string[] ChangguiVersion2026_12 =
    {
        "2026-01-06", "2026-01-20", "2026-02-03", "2026-03-10",
        "2026-03-24", "2026-04-09", "2026-04-23", "2026-05-19",
        "2026-06-09", "2026-06-23"
    };

    public static string[] DefaultDates =>
        ChangguiVersion2025_34.Concat(ChangguiVersion2026_12).OrderBy(d => d).ToArray();
}
