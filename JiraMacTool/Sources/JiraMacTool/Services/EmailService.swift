import Foundation

struct EmailService {

    /// Generate EML file from export data
    static func generateEML(
        toEmails: [String],
        dataList: [BanBenJiraDto],
        noticeContent: String,
        outputPath: String
    ) throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let todayStr = dateFormatter.string(from: Date())

        let rfcDateFormatter = DateFormatter()
        rfcDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        rfcDateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let rfcDate = rfcDateFormatter.string(from: Date())

        // Build To header
        let toHeader = toEmails.map { email in
            "=?utf-8?Q?\(email.replacingOccurrences(of: "@", with: "=40"))?= <\(email)>"
        }.joined(separator: ",\n ")

        // Cc list (unchanged from template)
        let ccList: [(name: String, email: String)] = [
            ("王在平总", "wangzaiping@sinosafe.com.cn"),
            ("谭杰方总", "tanjiefang@sinosafe.com.cn"),
            ("陈瑄波", "chenxuanbo@sinosafe.com.cn"),
            ("欧阳子栋", "ouyangzidong@sinosafe.com.cn"),
            ("杨凡", "yangfan@sinosafe.com.cn"),
            ("刘青新", "liuqingxin@sinosafe.com.cn"),
            ("王淑艳", "wangshuyan@sinosafe.com.cn"),
            ("许湉", "xutian@sinosafe.com.cn"),
        ]
        let ccHeader = ccList.map { item in
            let nameB64 = Data(item.name.utf8).base64EncodedString()
            return "=?utf-8?B?\(nameB64)?= <\(item.email)>"
        }.joined(separator: ",\r\n ")

        // Subject with current date
        let subjectText = "关于理赔开发室理赔相关需求（非项目）-排期计划通知(最新变更时间\(todayStr))"
        let subjectEncoded = encodeBase64Subject(subjectText)

        // Message-ID
        let messageId = "<\(UUID().uuidString)@sinosafe.com.cn>"

        // Build boundary
        let boundary = "=_jira_mac_tool_\(UUID().uuidString.prefix(16))"

        // Build HTML body
        let htmlBody = buildHTMLBody(dataList: dataList, noticeContent: noticeContent, todayStr: todayStr)

        // Build plain text body
        let plainBody = buildPlainTextBody(dataList: dataList, noticeContent: noticeContent, todayStr: todayStr)

        // Build EML content
        var eml = ""
        eml += "Date: \(rfcDate)\r\n"
        eml += "From: wuhaopeng <wuhaopeng@sinosafe.com.cn>\r\n"
        eml += "To: \(toHeader)\r\n"
        eml += "Cc: \(ccHeader)\r\n"
        eml += "Message-ID: \(messageId)\r\n"
        eml += "Subject: \(subjectEncoded)\r\n"
        eml += "MIME-Version: 1.0\r\n"
        eml += "Content-Type: multipart/alternative;\r\n"
        eml += " boundary=\"\(boundary)\"\r\n"
        eml += "\r\n"

        // Plain text part
        eml += "--\(boundary)\r\n"
        eml += "Content-Type: text/plain; charset=\"utf-8\"\r\n"
        eml += "Content-Transfer-Encoding: base64\r\n"
        eml += "\r\n"
        eml += base64Encode(plainBody)
        eml += "\r\n"

        // HTML part
        eml += "--\(boundary)\r\n"
        eml += "Content-Type: text/html; charset=\"utf-8\"\r\n"
        eml += "Content-Transfer-Encoding: base64\r\n"
        eml += "\r\n"
        eml += base64Encode(htmlBody)
        eml += "\r\n"

        // End
        eml += "--\(boundary)--\r\n"

        try eml.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    // MARK: - HTML Body

    private static func buildHTMLBody(dataList: [BanBenJiraDto], noticeContent: String, todayStr: String) -> String {
        // 从需求清单中提取在常规版本日期列表中的日期
        let changguiDates = RegularVersionDateStore.shared.dates
        let matchedDates = extractChangguiDates(from: dataList, changguiDates: changguiDates)
        let versionText = buildVersionText(dates: matchedDates)
        let plainVersionText = buildPlainVersionText(dates: matchedDates)
        
        var html = """
<html><head><meta http-equiv='Content-Type' content='text/html; charset=UTF-8'></head>
<body style="font-family: Helvetica, 微软雅黑, 宋体; line-height:1.6;">
<style>
    font{
        line-height: 1.6;
    }
    ul,ol{
        padding-left: 20px;
        list-style-position: inside;
    }
</style>
<div style="font-family:Helvetica,Helvetica,微软雅黑, 宋体; line-height:1.6;">
    <div></div>
    <div>
        &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<strong style="font-size: 16px; font-weight: bold;">【理赔开发室相关需求（非项目）-排期计划通知】 (最新变更时间\(todayStr))</strong>
    </div>
    <div><strong style="font-weight: bold;">各位领导，同事好：</strong></div>
    <div><strong style="font-weight: bold;">&nbsp; &nbsp; 根据公司科技服务工作安排，现将理赔条线中已受理并已纳入近期\(versionText)以及部分专题的需求通报如下，请各位知悉：</strong></div>
    <div><strong style="font-weight: bold;">&nbsp; &nbsp;&nbsp;<span style="font-family: Helvetica, Helvetica, 微软雅黑, 宋体;">&nbsp; &nbsp; 如有需求未在下表中纳入且要在近期\(plainVersionText)上线的，请在本周内反馈给我（<span data-nds-detect-group="base" data-nds-detect-text="wuhaopeng@sinosafe.com.cn" data-nds-detect-index="349" data-nds-detect-item="email">wuhaopeng@sinosafe.com.cn</span>）。</span>&nbsp;&nbsp; &nbsp;</strong></div>
    <div><br></div>
    <div>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<strong style="font-weight: bold;">需求清单：</strong></div>
    <div></div>
    <div></div>
    <div></div>
    <div></div>
    <div></div>
    <div></div>
    <div></div>
"""

        // Build table
        html += "<div><table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"957\" style=\"border-collapse: collapse; width: 957.02pt;\">\n"
        html += "<colgroup>"
        html += "<col width=\"66\" style=\"width: 66.1pt;\">"
        html += "<col width=\"58\" style=\"width: 58.2pt;\">"
        html += "<col width=\"376\" style=\"width: 376.75pt;\">"
        html += "<col width=\"92\" span=\"2\" style=\"width: 92.1pt;\">"
        html += "<col width=\"126\" style=\"width: 126.25pt;\">"
        html += "<col width=\"63\" style=\"width: 63.3pt;\">"
        html += "<col width=\"82\" style=\"width: 82.5pt;\">"
        html += "</colgroup>\n"
        html += "<tbody>\n"

        // Header row - green background for first 6, orange for last 2
        let greenStyle = "padding-top: 1px; padding-left: 1px; padding-right: 1px; font-size: 10pt; font-weight: 700; font-family: 等线; border: 0.5pt solid rgb(0, 0, 0); vertical-align: top; white-space: nowrap; background: rgb(0, 176, 80); text-align: center;"
        let orangeStyle = "padding-top: 1px; padding-left: 1px; padding-right: 1px; font-size: 10pt; font-weight: 700; font-family: 等线; border: 0.5pt solid rgb(0, 0, 0); vertical-align: top; white-space: nowrap; background: rgb(255, 192, 0); text-align: center;"

        html += "<tr height=\"15\" style=\"height: 15.2pt;\">"
        html += "<td style=\"\(greenStyle) height: 15.2pt; width: 66.1pt;\">需求类型</td>"
        html += "<td style=\"\(greenStyle) width: 58.2pt;\">需求号</td>"
        html += "<td style=\"\(greenStyle) width: 376.75pt;\">需求名称</td>"
        html += "<td style=\"\(greenStyle) width: 92.1pt;\">需求提出人</td>"
        html += "<td style=\"\(greenStyle) width: 92.1pt;\">用户测试</td>"
        html += "<td style=\"\(greenStyle) width: 126.25pt;\">涉及改造系统</td>"
        html += "<td style=\"\(orangeStyle) width: 63.3pt;\">进度</td>"
        html += "<td style=\"\(orangeStyle) width: 82.5pt;\">排期上线日期</td>"
        html += "</tr>\n"

        // Data rows
        let dataStyle = "padding-top: 1px; padding-left: 1px; padding-right: 1px; font-size: 10pt; font-family: 等线; border: 0.5pt solid rgb(0, 0, 0); vertical-align: top; white-space: nowrap; text-align: center;"

        for item in dataList {
            html += "<tr height=\"15\" style=\"height: 15.2pt;\">"
            html += "<td style=\"\(dataStyle) height: 15.2pt;\">\(escapeHTML(item.reqType))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.reqId))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.reqName))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.userDevelop))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.userTest))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.modifySystem))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.progress))</td>"
            html += "<td style=\"\(dataStyle)\">\(escapeHTML(item.scheduleLaunchDate))</td>"
            html += "</tr>\n"
        }

        html += "</tbody></table></div>\n"

        // Notice content - 关联系统&&特别注意事项（始终显示标题）
        html += "<div><br></div>\n"
        html += "<div><div style=\"text-indent: 2em;\"><strong style=\"font-weight: bold;\">关联系统&amp;&amp;特别注意事项：</strong><span><br></span></div></div>\n"
        
        if !noticeContent.isEmpty {
            let lines = noticeContent.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                let lineStr = String(line)
                if lineStr.isEmpty { continue }
                html += "<div><span style=\"color: rgb(234, 51, 36);\">\(escapeHTML(lineStr))</span></div>\n"
            }
        }

        // Signature
        html += """

<div><br></div>
<div><br></div>
<div id="ntes-pcmac-signature" style="font-family:'Helvetica','Microsoft Yahei', '微软雅黑'" spellcheck="false">
    <div style="font-size:14px; padding: 0;  margin:0;">
        <div style="padding-bottom:10px;margin-bottom:10px;display:inline-block;">
            <div><br></div>
            <div><hr color="#b5c4df" size="1" align="left" style="width: 210px; height: 1px;">
            <div style="margin: 10px;">
                <p style="margin: 0px 0cm; font-family: 微软雅黑; font-size: 10.5pt; text-align: justify;"><span style="font-size: medium;"><span style="font-family: 楷体;font-size: 18px;"><b>华安财产保险股份有限公司</b></span></span></p>
                <p style="margin: 0px 0cm; font-family: 微软雅黑; font-size: 10.5pt; text-align: justify;"><span style="font-size: medium;"><span style="font-family: 楷体;font-size: 18px;"><b>总公司信息科技部理赔开发室&nbsp; 吴浩鹏</b></span></span></p>
                <p style="margin: 0px 0cm; font-family: 微软雅黑; font-size: 10.5pt; text-align: justify;"><span style="font-size: medium;"><span style="font-family: 楷体;font-size: 18px;"><b>地址：深圳市福田区福华一路华安保险大厦8楼</b></span></span></p>
                <p style="margin: 0px 0cm; text-align: justify;"><span style="font-family: 楷体;font-size: 18px;"><b>邮编：518001</b></span></p>
                <p style="margin: 0px 0cm; text-align: justify;"><span style="line-height: 27px;"><span style="font-family: 楷体;font-size: 18px;"><b>座机：0755-84489334</b></span></span></p>
                <p style="margin: 0px 0cm; text-align: justify;"><span style="font-family: 楷体;font-size: 18px;"><b>手机：17688894904</b></span></p>
                <p style="margin: 0px 0cm; text-align: justify;"><span style="font-family: 楷体;font-size: 18px;"><b>邮箱：wuhaopeng@sinosafe.com.cn</b></span></p>
            </div></div>
        </div>
    </div>
</div>
</div>
</div>
</body></html>
"""
        return html
    }

    // MARK: - Plain Text Body

    private static func buildPlainTextBody(dataList: [BanBenJiraDto], noticeContent: String, todayStr: String) -> String {
        // 从需求清单中提取在常规版本日期列表中的日期
        let changguiDates = RegularVersionDateStore.shared.dates
        let matchedDates = extractChangguiDates(from: dataList, changguiDates: changguiDates)
        let plainVersionText = buildPlainVersionText(dates: matchedDates)
        
        var text = ""
        text += "【理赔开发室相关需求（非项目）-排期计划通知】 (最新变更时间\(todayStr))\n"
        text += "各位领导，同事好：\n"
        text += "根据公司科技服务工作安排，现将理赔条线中已受理并已纳入近期\(plainVersionText)以及部分专题的需求通报如下，请各位知悉：\n"
        text += "如有需求未在下表中纳入且要在近期\(plainVersionText)上线的，请在本周内反馈给我（wuhaopeng@sinosafe.com.cn）。 \n"
        text += "需求清单：\n"

        for item in dataList {
            text += "\(item.reqType)\t\(item.reqId)\t\(item.reqName)\t\(item.userDevelop)\t\(item.userTest)\t\(item.modifySystem)\t\(item.progress)\t\(item.scheduleLaunchDate)\t\(item.remark)\n"
        }

        if !noticeContent.isEmpty {
            text += "\n关联系统&&特别注意事项：\n"
            text += noticeContent
        }

        text += "\n总公司信息科技部理赔开发室 吴浩鹏\n"
        text += "地址：深圳市福田区福华一路华安保险大厦8楼\n"
        text += "邮编：518001\n"
        text += "座机：0755-84489334\n"
        text += "手机：17688894904\n"
        text += "邮箱：wuhaopeng@sinosafe.com.cn"

        return text
    }

    // MARK: - Helpers

    /// 从需求清单中提取在常规版本日期列表中的日期（去重排序）
    private static func extractChangguiDates(from dataList: [BanBenJiraDto], changguiDates: [String]) -> [String] {
        let changguiSet = Set(changguiDates)
        var matched: Set<String> = []
        for item in dataList {
            let date = item.scheduleLaunchDate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !date.isEmpty && changguiSet.contains(date) {
                matched.insert(date)
            }
        }
        return matched.sorted()
    }
    
    /// 构建HTML邮件中的版本描述文本
    /// 例：2个常规版本（1月20日、2月3日）
    private static func buildVersionText(dates: [String]) -> String {
        guard !dates.isEmpty else { return "常规版本" }
        
        let count = dates.count
        let formattedDates = dates.map { formatDateForDisplay($0) }
        
        if count == 1 {
            return "1个常规版本（\(formattedDates[0])）"
        } else {
            let dateList = formattedDates.joined(separator: "、")
            return "\(count)个常规版本（\(dateList)）"
        }
    }
    
    /// 构建纯文本中的版本描述（与HTML版一致）
    private static func buildPlainVersionText(dates: [String]) -> String {
        return buildVersionText(dates: dates)
    }
    
    /// 格式化日期显示：yyyy-MM-dd -> M月d日
    private static func formatDateForDisplay(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)月\(day)日"
    }

    private static func escapeHTML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func base64Encode(_ str: String) -> String {
        guard let data = str.data(using: .utf8) else { return "" }
        let base64 = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return base64
    }

    private static func encodeBase64Subject(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return text }
        let base64 = data.base64EncodedString()
        // Split into 40-char chunks for line folding
        var result: [String] = []
        var index = base64.startIndex
        let chunkSize = 40
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[index..<end])
            result.append("=?utf-8?B?\(chunk)?=")
            index = end
        }
        return result.joined(separator: "\r\n ")
    }
}
