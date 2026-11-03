using System.Globalization;

namespace JiraWinTool.Utils;

/// <summary>
/// 日期工具（移植自 Swift DateUtils.swift）
/// </summary>
public static class DateUtils
{
    public static string FormatDate(DateTime date, string format = "yyyy-MM-dd")
        => date.ToString(format);

    public static DateTime? ParseDate(string s, string format = "yyyy-MM-dd")
    {
        if (DateTime.TryParseExact(s, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
            return dt;
        return null;
    }

    public static DateTime? FormateStringToDate(string s)
    {
        if (DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
            return dt;
        if (DateTime.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
            return dt;
        return null;
    }

    public static string FormatDateToString(DateTime date)
        => date.ToString("yyyy-MM-dd HH:mm:ss");

    /// <summary>周一=1 … 周日=7</summary>
    public static int GetWeek(DateTime date)
    {
        int weekday = ((int)date.DayOfWeek + 6) % 7 + 1;
        return weekday;
    }

    public static int DaysBetween(DateTime from, DateTime to)
        => (to.Date - from.Date).Days;

    public static DateTime AddDate(DateTime date, int day)
        => date.AddDays(day);

    public static string GetYesterday()
        => FormatDate(DateTime.Now.AddDays(-1));

    public static string GetCurrentDateTime()
        => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

    public static List<string> GetMonthBetween(string minDate, string maxDate)
    {
        var min = ParseDate(minDate, "yyyy-MM");
        var max = ParseDate(maxDate, "yyyy-MM");
        if (min == null || max == null) return new List<string>();

        var result = new List<string>();
        var current = min.Value;
        while (current < max.Value)
        {
            result.Add(FormatDate(current, "yyyy-MM"));
            current = current.AddMonths(1);
        }
        return result;
    }
}
