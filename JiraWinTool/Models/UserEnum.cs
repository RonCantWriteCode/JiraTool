using JiraWinTool.Utils;
using Newtonsoft.Json;

namespace JiraWinTool.Models;

/// <summary>用户邮箱映射（移植自 Swift UserEnum.swift）</summary>
public static class UserEmailMapping
{
    private static readonly Dictionary<string, string> BuiltInEmails = new()
    {
        ["王勇"] = "wangyong10@sinosafe.com.cn",
        ["韩蓉蓉"] = "hanrongrong@sinosafe.com.cn",
        ["何贵辉"] = "heguihui@sinosafe.com.cn",
        ["邢君"] = "xingjun@sinosafe.com.cn",
        ["李晓龙"] = "lixiaolong1@sinosafe.com.cn",
        ["韦五一"] = "weiwuyi@sinosafe.com.cn",
        ["黄天泽"] = "huangtianze@sinosafe.com.cn",
        ["周健强"] = "zhoujianqiang@sinosafe.com.cn",
        ["蓝建伟"] = "lanjianwei@sinosafe.com.cn",
        ["孙园园"] = "sunyuanyuan2@sinosafe.com.cn",
        ["唐阳"] = "tangyang1@sinosafe.com.cn",
        ["高泰康"] = "gaotaikang@sinosafe.com.cn",
        ["饶娉珍"] = "raopingzhen@sinosafe.com.cn",
        ["刘芳"] = "liufang9@sinosafe.com.cn",
        ["宇星"] = "yuxing@sinosafe.com.cn",
        ["谢邦"] = "xiebang@sinosafe.com.cn",
        ["李松林"] = "lisonglin@sinosafe.com.cn",
        ["罗家声"] = "luojiasheng@sinosafe.com.cn",
        ["袁辉"] = "yuanhui2@sinosafe.com.cn",
        ["李欣"] = "lixin20@sinosafe.com.cn",
        ["黄廷玺"] = "huangtingxi@sinosafe.com.cn",
        ["吕航"] = "lvhang@sinosafe.com.cn",
        ["刘东山"] = "ex_liudongshan@sinosafe.com.cn",
        ["王涵"] = "wanghan4@sinosafe.com.cn",
        ["石云清"] = "shiyunqing@sinosafe.com.cn",
        ["张敏"] = "zhangmin17@sinosafe.com.cn",
        ["周凯"] = "zhoukai2@sinosafe.com.cn",
        ["高金鹏"] = "gaojinpeng@sinosafe.com.cn",
        ["江斌"] = "jiangbin2@sinosafe.com.cn",
        ["吴润龙"] = "wurunlong@sinosafe.com.cn",
        ["彭霞"] = "pengxia@sinosafe.com.cn",
        ["肖华"] = "xiaohua@sinosafe.com.cn",
        ["毛乾"] = "maoqian@sinosafe.com.cn",
        ["王燕"] = "wangyan31@sinosafe.com.cn",
        ["芦思豫"] = "lusiyu1@sinosafe.com.cn",
        ["高凯"] = "gaokai@sinosafe.com.cn",
        ["莫秀杰"] = "moxiujie@sinosafe.com.cn",
        ["黄河生"] = "huanghesheng@sinosafe.com.cn",
        ["谷玉颖"] = "guyuying@sinosafe.com.cn",
        ["熊勉"] = "xiongmian@sinosafe.com.cn",
        ["马福创"] = "mafuchuang@sinosafe.com.cn",
        ["莫鑫群"] = "moxinqun@sinosafe.com.cn",
        ["谢智鹏"] = "xiezhipeng@sinosafe.com.cn",
        ["夏霆"] = "xiating@sinosafe.com.cn",
        ["彭昌伟"] = "pengchangwei@sinosafe.com.cn",
        ["周琴"] = "zhouqin5@sinosafe.com.cn",
        ["梁红艳"] = "lianghongyan@sinosafe.com.cn",
        ["林海"] = "linhai3@sinosafe.com.cn",
        ["高鑫海"] = "gaoxinhai@sinosafe.com.cn",
        ["巫绍虎"] = "wushaohu@sinosafe.com.cn",
        ["徐丹"] = "xudan4@sinosafe.com.cn",
        ["李保友"] = "libaoyou85@sinosafe.com.cn",
        ["曾志华"] = "zengzhihua@sinosafe.com.cn",
        ["段乃鹏"] = "p_duannaipeng@sinosafe.com.cn",
        ["周稳"] = "zhouwen3@sinosafe.com.cn",
        ["徐晟昱"] = "xushengyu@sinosafe.com.cn",
        ["杨雨欣"] = "yangyuxin2@sinosafe.com.cn",
        ["谢莉"] = "xieli2@sinosafe.com.cn",
        ["曹新良"] = "caoxinliang@sinosafe.com.cn",
        ["吴仪"] = "wuyi5@sinosafe.com.cn",
        ["胡建雄"] = "hujianxiong@sinosafe.com.cn",
        ["苏鑫"] = "suxin@sinosafe.com.cn",
        ["胡宇琴"] = "huyuqin@sinosafe.com.cn",
        ["王一帆"] = "wangyifan1@sinosafe.com.cn",
        ["余乐锦"] = "p_yulejin@sinosafe.com.cn",
        ["慕海梅"] = "muhaimei@sinosafe.com.cn",
        ["房林彦"] = "fanglinyan@sinosafe.com.cn",
        ["杨铭"] = "yangming7@sinosafe.com.cn",
        ["徐特立"] = "xuteli@sinosafe.com.cn",
        ["李小宏"] = "lixiaohong2@sinosafe.com.cn",
        ["栾志海"] = "luanzhihai@sinosafe.com.cn",
        ["顾东炜"] = "gudongwei@sinosafe.com.cn",
        ["王怀志"] = "wanghuaizhi@sinosafe.com.cn",
        ["李然"] = "liran1@sinosafe.com.cn",
        ["唐立宇"] = "tangliyu@sinosafe.com.cn",
        ["何沂芳"] = "heyifang@sinosafe.com.cn",
        ["卢泓"] = "luhong2@sinosafe.com.cn",
        ["吴恩"] = "wuen1@sinosafe.com.cn",
        ["雷萌"] = "leimeng@sinosafe.com.cn",
    };

    private const string DynamicMappingsKey = "user_email_dynamic_mappings";

    public static string? GetEmail(string name)
    {
        if (BuiltInEmails.TryGetValue(name, out var email))
            return email;
        var dynamicMap = LoadDynamicMappings();
        return dynamicMap.GetValueOrDefault(name);
    }

    public static string[] GetUnknownUsers(IEnumerable<string> names)
        => names.Where(n => GetEmail(n) == null).ToArray();

    public static void AddDynamicMappings(Dictionary<string, string> mappings)
    {
        var existing = LoadDynamicMappings();
        foreach (var (k, v) in mappings) existing[k] = v;
        SaveDynamicMappings(existing);
    }

    public static void UpdateEmail(string name, string email)
    {
        var dynamicMap = LoadDynamicMappings();
        dynamicMap[name] = email;
        SaveDynamicMappings(dynamicMap);
    }

    public static List<(string Name, string Email, bool IsBuiltIn)> GetAllMappings()
    {
        var result = BuiltInEmails.Select(kv => (kv.Key, kv.Value, true)).ToList();
        var dynamicMap = LoadDynamicMappings();
        foreach (var (name, email) in dynamicMap)
        {
            if (!result.Any(r => r.Item1 == name))
                result.Add((name, email, false));
        }
        result.Sort((a, b) => string.Compare(a.Item1, b.Item1, StringComparison.Ordinal));
        return result;
    }

    private static Dictionary<string, string> LoadDynamicMappings()
    {
        try
        {
            var json = AppConfig.Shared.GetCustom(DynamicMappingsKey);
            if (!string.IsNullOrEmpty(json))
                return JsonConvert.DeserializeObject<Dictionary<string, string>>(json) ?? new();
        }
        catch { }
        return new();
    }

    private static void SaveDynamicMappings(Dictionary<string, string> mappings)
    {
        var json = JsonConvert.SerializeObject(mappings);
        AppConfig.Shared.SetCustom(DynamicMappingsKey, json);
    }
}
