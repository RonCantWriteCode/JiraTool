using System.Text;
using JiraWinTool.Models;
using JiraWinTool.Utils;

namespace JiraWinTool.Services;

/// <summary>邮件生成服务（移植自 Swift EmailService.swift）</summary>
public static class EmailService
{
    private const string RegularDatesKey = "regularVersionDates";

    /// <summary>从 EML 文件生成</summary>
    public static void GenerateEML(string[] toEmails, List<BanBenJiraDto> dataList, string noticeContent, string outputPath)
    {
        var todayStr = DateTime.Now.ToString("yyyyMMdd");
        var rfcDate = DateTime.Now.ToString("ddd, dd MMM yyyy HH:mm:ss +0800",
            new System.Globalization.CultureInfo("en-US"));

        // Build To header
        var toHeader = string.Join(",\n ", toEmails.Select(email =>
        {
            var encodedEmail = email.Replace("@", "=40");
            return $"=?utf-8?Q?{encodedEmail}?= <{email}>";
        }));

        // Cc list
        var ccList = new (string Name, string Email)[]
        {
            ("王在平总", "wangzaiping@sinosafe.com.cn"),
            ("谭杰方总", "tanjiefang@sinosafe.com.cn"),
            ("陈瑄波", "chenxuanbo@sinosafe.com.cn"),
            ("欧阳子栋", "ouyangzidong@sinosafe.com.cn"),
            ("杨凡", "yangfan@sinosafe.com.cn"),
            ("刘青新", "liuqingxin@sinosafe.com.cn"),
            ("王淑艳", "wangshuyan@sinosafe.com.cn"),
            ("许湉", "xutian@sinosafe.com.cn"),
        };
        var ccHeader = string.Join(",\r\n ", ccList.Select(item =>
        {
            var nameB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(item.Name));
            return $"=?utf-8?B?{nameB64}?= <{item.Email}>";
        }));

        // Subject
        var subjectText = $"关于理赔开发室理赔相关需求（非项目）-排期计划通知(最新变更时间{todayStr})";
        var subjectEncoded = EncodeBase64Subject(subjectText);

        // Message-ID
        var messageId = $"<{Guid.NewGuid()}@sinosafe.com.cn>";

        // Build boundary
        var boundary = $"=_jira_mac_tool_{Guid.NewGuid().ToString("N")[..16]}";

        // Load regular dates
        var changguiDates = LoadRegularDates();

        // Build bodies
        var htmlBody = BuildHTMLBody(dataList, noticeContent, todayStr, changguiDates);
        var plainBody = BuildPlainTextBody(dataList, noticeContent, todayStr, changguiDates);

        // Build EML
        var eml = new StringBuilder();
        eml.AppendLine($"Date: {rfcDate}");
        eml.AppendLine("From: wuhaopeng <wuhaopeng@sinosafe.com.cn>");
        eml.AppendLine($"To: {toHeader}");
        eml.AppendLine($"Cc: {ccHeader}");
        eml.AppendLine($"Message-ID: {messageId}");
        eml.AppendLine($"Subject: {subjectEncoded}");
        eml.AppendLine("MIME-Version: 1.0");
        eml.AppendLine($"Content-Type: multipart/alternative;");
        eml.AppendLine($" boundary=\"{boundary}\"");
        eml.AppendLine();

        // Plain text part
        eml.AppendLine($"--{boundary}");
        eml.AppendLine("Content-Type: text/plain; charset=\"utf-8\"");
        eml.AppendLine("Content-Transfer-Encoding: base64");
        eml.AppendLine();
        eml.Append(Base64Encode(plainBody));
        eml.AppendLine();

        // HTML part
        eml.AppendLine($"--{boundary}");
        eml.AppendLine("Content-Type: text/html; charset=\"utf-8\"");
        eml.AppendLine("Content-Transfer-Encoding: base64");
        eml.AppendLine();
        eml.Append(Base64Encode(htmlBody));
        eml.AppendLine();

        // End
        eml.AppendLine($"--{boundary}--");

        File.WriteAllText(outputPath, eml.ToString(), Encoding.UTF8);
    }

    // MARK: - HTML Body

    private static string BuildHTMLBody(List<BanBenJiraDto> dataList, string noticeContent, string todayStr, List<string> changguiDates)
    {
        var matchedDates = ExtractChangguiDates(dataList, changguiDates);
        var versionText = BuildVersionText(matchedDates);

        var html = new StringBuilder();
        html.AppendLine("<html><head><meta http-equiv='Content-Type' content='text/html; charset=UTF-8'></head>");
        html.AppendLine("<body style=\"font-family: Helvetica, 微软雅黑, 宋体; line-height:1.6;\">");
        html.AppendLine("<style>font{line-height:1.6;}ul,ol{padding-left:20px;list-style-position:inside;}</style>");
        html.AppendLine("<div style=\"font-family:Helvetica,Helvetica,微软雅黑,宋体;line-height:1.6;\">");
        html.AppendLine("<div></div>");
        html.Append("<div>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;");
        html.Append("&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;");
        html.Append("&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;");
        html.Append("&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;");
        html.AppendLine($"<strong style=\"font-size:16px;font-weight:bold;\">【理赔开发室相关需求（非项目）-排期计划通知】 (最新变更时间{todayStr})</strong></div>");
        html.AppendLine("<div><strong style=\"font-weight:bold;\">各位领导，同事好：</strong></div>");
        html.AppendLine($"<div><strong style=\"font-weight:bold;\">&nbsp;&nbsp;根据公司科技服务工作安排，现将理赔条线中已受理并已纳入近期{versionText}以及部分专题的需求通报如下，请各位知悉：</strong></div>");
        html.AppendLine($"<div><strong style=\"font-weight:bold;\">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;如有需求未在下表中纳入且要在近期{versionText}上线的，请在本周内反馈给我（<span>wuhaopeng@sinosafe.com.cn</span>）。&nbsp;&nbsp;&nbsp;</strong></div>");
        html.AppendLine("<div><br></div>");
        html.AppendLine("<div>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<strong style=\"font-weight:bold;\">需求清单：</strong></div>");
        html.AppendLine("<div></div>");

        // Build table
        html.AppendLine("<div><table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"957\" style=\"border-collapse:collapse;width:957.02pt;\">");
        html.AppendLine("<colgroup>");
        html.AppendLine("<col width=\"66\" style=\"width:66.1pt;\"><col width=\"58\" style=\"width:58.2pt;\"><col width=\"376\" style=\"width:376.75pt;\">");
        html.AppendLine("<col width=\"92\" span=\"2\" style=\"width:92.1pt;\"><col width=\"126\" style=\"width:126.25pt;\">");
        html.AppendLine("<col width=\"63\" style=\"width:63.3pt;\"><col width=\"82\" style=\"width:82.5pt;\">");
        html.AppendLine("</colgroup><tbody>");

        // Header row
        var greenStyle = "padding-top:1px;padding-left:1px;padding-right:1px;font-size:10pt;font-weight:700;font-family:等线;border:0.5pt solid rgb(0,0,0);vertical-align:top;white-space:nowrap;background:rgb(0,176,80);text-align:center;";
        var orangeStyle = "padding-top:1px;padding-left:1px;padding-right:1px;font-size:10pt;font-weight:700;font-family:等线;border:0.5pt solid rgb(0,0,0);vertical-align:top;white-space:nowrap;background:rgb(255,192,0);text-align:center;";

        html.AppendLine("<tr height=\"15\" style=\"height:15.2pt;\">");
        html.AppendLine($"<td style=\"{greenStyle}height:15.2pt;width:66.1pt;\">需求类型</td>");
        html.AppendLine($"<td style=\"{greenStyle}width:58.2pt;\">需求号</td>");
        html.Append($"<td style=\"{greenStyle}width:376.75pt;\">需求名称</td>");
        html.Append($"<td style=\"{greenStyle}width:92.1pt;\">需求提出人</td>");
        html.Append($"<td style=\"{greenStyle}width:92.1pt;\">用户测试</td>");
        html.Append($"<td style=\"{greenStyle}width:126.25pt;\">涉及改造系统</td>");
        html.Append($"<td style=\"{orangeStyle}width:63.3pt;\">进度</td>");
        html.Append($"<td style=\"{orangeStyle}width:82.5pt;\">排期上线日期</td>");
        html.AppendLine("</tr>");

        // Data rows
        var dataStyle = "padding-top:1px;padding-left:1px;padding-right:1px;font-size:10pt;font-family:等线;border:0.5pt solid rgb(0,0,0);vertical-align:top;white-space:nowrap;text-align:center;";

        foreach (var item in dataList)
        {
            html.AppendLine("<tr height=\"15\" style=\"height:15.2pt;\">");
            html.AppendLine($"<td style=\"{dataStyle}height:15.2pt;\">{EscapeHtml(item.ReqType)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.ReqId)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.ReqName)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.UserDevelop)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.UserTest)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.ModifySystem)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.Progress)}</td>");
            html.AppendLine($"<td style=\"{dataStyle}\">{EscapeHtml(item.ScheduleLaunchDate)}</td>");
            html.AppendLine("</tr>");
        }

        html.AppendLine("</tbody></table></div>");

        // Notice content
        html.AppendLine("<div><br></div>");
        html.AppendLine("<div><div style=\"text-indent:2em;\"><strong style=\"font-weight:bold;\">关联系统&amp;&amp;特别注意事项：</strong><span><br></span></div></div>");

        if (!string.IsNullOrEmpty(noticeContent))
        {
            var lines = noticeContent.Split('\n');
            foreach (var line in lines)
            {
                if (string.IsNullOrEmpty(line)) continue;
                html.AppendLine($"<div><span style=\"color:rgb(234,51,36);\">{EscapeHtml(line)}</span></div>");
            }
        }

        // Signature
        html.AppendLine("<div><br></div><div><br></div>");
        html.AppendLine("<div style=\"font-family:'Helvetica','Microsoft Yahei','微软雅黑'\">");
        html.AppendLine("<div style=\"font-size:14px;padding:0;margin:0;\">");
        html.AppendLine("<div style=\"padding-bottom:10px;margin-bottom:10px;display:inline-block;\">");
        html.AppendLine("<div><br></div>");
        html.AppendLine("<div><hr color=\"#b5c4df\" size=\"1\" align=\"left\" style=\"width:210px;height:1px;\">");
        html.AppendLine("<div style=\"margin:10px;\">");
        html.AppendLine("<p style=\"margin:0;font-family:微软雅黑;font-size:10.5pt;text-align:justify;\"><span style=\"font-size:medium;\"><span style=\"font-family:楷体;font-size:18px;\"><b>华安财产保险股份有限公司</b></span></span></p>");
        html.AppendLine("<p style=\"margin:0;font-family:微软雅黑;font-size:10.5pt;text-align:justify;\"><span style=\"font-size:medium;\"><span style=\"font-family:楷体;font-size:18px;\"><b>总公司信息科技部理赔开发室&nbsp;吴浩鹏</b></span></span></p>");
        html.AppendLine("<p style=\"margin:0;font-family:微软雅黑;font-size:10.5pt;text-align:justify;\"><span style=\"font-size:medium;\"><span style=\"font-family:楷体;font-size:18px;\"><b>地址：深圳市福田区福华一路华安保险大厦8楼</b></span></span></p>");
        html.AppendLine("<p style=\"margin:0;text-align:justify;\"><span style=\"font-family:楷体;font-size:18px;\"><b>邮编：518001</b></span></p>");
        html.AppendLine("<p style=\"margin:0;text-align:justify;\"><span style=\"line-height:27px;\"><span style=\"font-family:楷体;font-size:18px;\"><b>座机：0755-84489334</b></span></span></p>");
        html.AppendLine("<p style=\"margin:0;text-align:justify;\"><span style=\"font-family:楷体;font-size:18px;\"><b>手机：17688894904</b></span></p>");
        html.AppendLine("<p style=\"margin:0;text-align:justify;\"><span style=\"font-family:楷体;font-size:18px;\"><b>邮箱：wuhaopeng@sinosafe.com.cn</b></span></p>");
        html.AppendLine("</div></div></div></div></div></div></div></body></html>");

        return html.ToString();
    }

    // MARK: - Plain Text Body

    private static string BuildPlainTextBody(List<BanBenJiraDto> dataList, string noticeContent, string todayStr, List<string> changguiDates)
    {
        var matchedDates = ExtractChangguiDates(dataList, changguiDates);
        var plainVersionText = BuildVersionText(matchedDates);

        var text = new StringBuilder();
        text.AppendLine($"【理赔开发室相关需求（非项目）-排期计划通知】 (最新变更时间{todayStr})");
        text.AppendLine("各位领导，同事好：");
        text.AppendLine($"根据公司科技服务工作安排，现将理赔条线中已受理并已纳入近期{plainVersionText}以及部分专题的需求通报如下，请各位知悉：");
        text.AppendLine($"如有需求未在下表中纳入且要在近期{plainVersionText}上线的，请在本周内反馈给我（wuhaopeng@sinosafe.com.cn）。");
        text.AppendLine("需求清单：");

        foreach (var item in dataList)
        {
            text.AppendLine($"{item.ReqType}\t{item.ReqId}\t{item.ReqName}\t{item.UserDevelop}\t{item.UserTest}\t{item.ModifySystem}\t{item.Progress}\t{item.ScheduleLaunchDate}\t{item.Remark}");
        }

        if (!string.IsNullOrEmpty(noticeContent))
        {
            text.AppendLine("\n关联系统&&特别注意事项：");
            text.Append(noticeContent);
        }

        text.AppendLine("\n总公司信息科技部理赔开发室 吴浩鹏");
        text.AppendLine("地址：深圳市福田区福华一路华安保险大厦8楼");
        text.AppendLine("邮编：518001");
        text.AppendLine("座机：0755-84489334");
        text.AppendLine("手机：17688894904");
        text.AppendLine("邮箱：wuhaopeng@sinosafe.com.cn");

        return text.ToString();
    }

    // MARK: - Helpers

    private static List<string> LoadRegularDates()
    {
        try
        {
            var saved = AppConfig.Shared.GetCustom(RegularDatesKey);
            if (!string.IsNullOrEmpty(saved))
            {
                return saved.Split('\n', StringSplitOptions.RemoveEmptyEntries)
                    .Select(s => s.Trim())
                    .Where(s => !string.IsNullOrEmpty(s))
                    .OrderBy(s => s)
                    .ToList();
            }
        }
        catch { }
        return PublishConstants.DefaultDates.ToList();
    }

    private static List<string> ExtractChangguiDates(List<BanBenJiraDto> dataList, List<string> changguiDates)
    {
        var changguiSet = new HashSet<string>(changguiDates);
        var matched = new HashSet<string>();
        foreach (var item in dataList)
        {
            var date = item.ScheduleLaunchDate?.Trim() ?? "";
            if (!string.IsNullOrEmpty(date) && changguiSet.Contains(date))
                matched.Add(date);
        }
        return matched.OrderBy(d => d).ToList();
    }

    private static string BuildVersionText(List<string> dates)
    {
        if (dates.Count == 0) return "常规版本";

        var formattedDates = dates.Select(FormatDateForDisplay).ToList();

        if (formattedDates.Count == 1)
            return $"1个常规版本（{formattedDates[0]}）";
        else
            return $"{formattedDates.Count}个常规版本（{string.Join("、", formattedDates)}）";
    }

    private static string FormatDateForDisplay(string dateStr)
    {
        var dateObj = DateUtils.ParseDate(dateStr);
        if (dateObj == null) return dateStr;
        return $"{dateObj.Value.Month}月{dateObj.Value.Day}日";
    }

    private static string EscapeHtml(string str)
    {
        return str
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;");
    }

    private static string Base64Encode(string str)
    {
        var bytes = Encoding.UTF8.GetBytes(str);
        var base64 = Convert.ToBase64String(bytes);
        // Split into lines for MIME
        var sb = new StringBuilder();
        for (int i = 0; i < base64.Length; i += 76)
        {
            var len = Math.Min(76, base64.Length - i);
            sb.AppendLine(base64.Substring(i, len));
        }
        return sb.ToString();
    }

    private static string EncodeBase64Subject(string text)
    {
        var base64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        // Split into 40-char chunks for line folding
        var chunks = new List<string>();
        for (int i = 0; i < base64.Length; i += 40)
        {
            var len = Math.Min(40, base64.Length - i);
            chunks.Add($"=?utf-8?B?{base64.Substring(i, len)}?=");
        }
        return string.Join("\r\n ", chunks);
    }
}
