using System.Diagnostics;

namespace JiraWinTool.Utils;

/// <summary>
/// 调试日志。仅在 DEBUG 构建中输出（Conditional 特性保证 Release 下调用被整体移除，
/// 字符串拼接不会求值，无性能开销，也不会把调试信息带进正式包）。
/// 用法：Log.Debug("[OAService] 登录成功");
/// </summary>
public static class Log
{
    [Conditional("DEBUG")]
    public static void Debug(string message)
    {
        System.Diagnostics.Debug.WriteLine(message);
        Console.WriteLine(message);
    }
}
