import Foundation

/// 邮件解析结果
struct EmailParseResult {
    var subject: String = ""
    var from: String = ""
    var fromName: String = ""
    var body: String = ""
    var attachments: [EmailAttachmentInfo] = []
}

/// 邮件附件信息
struct EmailAttachmentInfo: Identifiable {
    var name: String = ""
    var data: Data = Data()
    var mimeType: String = "application/octet-stream"
    var id: UUID = UUID()
}

/// 邮件解析服务：解析 .eml 文件，提取标题、发件人、正文、附件
struct EmailParser {

    /// 从文件路径解析邮件
    static func parse(fromFile filePath: String) throws -> EmailParseResult {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            throw NSError(domain: "EmailParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取文件: \(filePath)"])
        }
        // 尝试多种编码
        let content: String
        if let str = String(data: data, encoding: .utf8) {
            content = str
        } else if let str = String(data: data, encoding: .ascii) {
            content = str
        } else if let str = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
            content = str
        } else {
            content = String(data: data, encoding: .isoLatin1) ?? ""
        }
        return parse(content)
    }

    /// 从字符串内容解析邮件
    static func parse(_ eml: String) -> EmailParseResult {
        return parseMIMEManual(eml)
    }

    // MARK: - MIME 手动解析

    private static func parseMIMEManual(_ eml: String) -> EmailParseResult {
        var result = EmailParseResult()

        // 分离 header 和 body
        let (headerSection, bodySection) = splitHeaderBody(eml)

        // 解析 headers
        let headers = parseHeaders(unfoldHeaders(headerSection))

        // Subject
        if let subject = headers["subject"] {
            result.subject = decodeMIMEWord(subject)
        }

        // From
        if let from = headers["from"] {
            result.from = from
            result.fromName = extractDisplayName(from)
        }

        // Content-Type
        let contentType = headers["content-type"] ?? "text/plain"
        let boundary = extractBoundary(contentType)

        if let boundary = boundary {
            // multipart 邮件
            parseMultipart(bodySection, boundary: boundary, result: &result)
        } else {
            // 单部分邮件
            let charset = extractCharset(contentType)
            let transferEncoding = headers["content-transfer-encoding"] ?? "7bit"
            result.body = decodeBody(bodySection, transferEncoding: transferEncoding, charset: charset)
        }

        return result
    }

    /// 分离 header 和 body（以空行分隔）
    private static func splitHeaderBody(_ eml: String) -> (String, String) {
        if let range = eml.range(of: "\r\n\r\n") {
            return (String(eml[eml.startIndex..<range.lowerBound]),
                    String(eml[range.upperBound...]))
        }
        if let range = eml.range(of: "\n\n") {
            return (String(eml[eml.startIndex..<range.lowerBound]),
                    String(eml[range.upperBound...]))
        }
        return (eml, "")
    }

    /// 展开 RFC 2822 折叠行
    private static func unfoldHeaders(_ headerSection: String) -> String {
        // 以空格或 Tab 开头的续行合并到上一行
        let pattern = #"\r?\n[ \t]+"#
        return headerSection.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }

    /// 解析 headers 为字典
    private static func parseHeaders(_ unfoldedHeaders: String) -> [String: String] {
        var dict = [String: String]()
        let lines = unfoldedHeaders.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            guard let colonIdx = line.firstIndex(of: ":"), colonIdx > line.startIndex else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            dict[key.lowercased()] = value
        }
        return dict
    }

    /// 解析 multipart body
    private static func parseMultipart(_ bodySection: String, boundary: String, result: inout EmailParseResult) {
        let parts = splitMIMEParts(bodySection, boundary: boundary)

        var htmlBody: String?
        var plainBody: String?

        for part in parts {
            let (partHeaderStr, partBody) = splitHeaderBody(part)
            let partHeaders = parseHeaders(unfoldHeaders(partHeaderStr))

            let partContentType = partHeaders["content-type"] ?? "text/plain"
            let charset = extractCharset(partContentType)
            let transferEncoding = partHeaders["content-transfer-encoding"] ?? "7bit"
            let disposition = partHeaders["content-disposition"] ?? ""

            let isAttachment = disposition.lowercased().contains("attachment")
            let fileName = extractFilename(disposition)

            if isAttachment || fileName != nil {
                // 附件
                let data = decodeBodyBytes(partBody, transferEncoding: transferEncoding)
                let attachment = EmailAttachmentInfo(
                    name: fileName ?? "attachment",
                    data: data,
                    mimeType: partContentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"
                )
                result.attachments.append(attachment)
            } else if partContentType.lowercased().contains("text/html") {
                htmlBody = decodeBody(partBody, transferEncoding: transferEncoding, charset: charset)
            } else if partContentType.lowercased().contains("text/plain") {
                plainBody = decodeBody(partBody, transferEncoding: transferEncoding, charset: charset)
            } else if partContentType.lowercased().hasPrefix("multipart/") {
                // 嵌套 multipart
                if let innerBoundary = extractBoundary(partContentType) {
                    parseMultipart(partBody, boundary: innerBoundary, result: &result)
                }
            }
        }

        // 优先使用 HTML 正文
        if let html = htmlBody, !html.isEmpty {
            result.body = htmlToPlainText(html)
        } else if let plain = plainBody, !plain.isEmpty {
            result.body = plain
        }
    }

    /// 按 boundary 拆分 MIME 部分
    private static func splitMIMEParts(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        let endDelimiter = "--" + boundary + "--"

        var parts = [String]()
        let sections = body.components(separatedBy: delimiter)

        for section in sections {
            let trimmed = section.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if trimmed.hasPrefix("--") || trimmed.isEmpty { continue }
            var content = trimmed
            if let endRange = content.range(of: endDelimiter) {
                content = String(content[content.startIndex..<endRange.lowerBound])
            }
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(content)
            }
        }
        return parts
    }

    /// 解码邮件正文为字符串
    private static func decodeBody(_ body: String, transferEncoding: String, charset: String) -> String {
        let bytes = decodeBodyBytes(body, transferEncoding: transferEncoding)
        let encoding = charsetToEncoding(charset)
        return String(data: bytes, encoding: encoding) ?? String(data: bytes, encoding: .utf8) ?? body
    }

    /// 按 transfer-encoding 解码为字节数组
    private static func decodeBodyBytes(_ body: String, transferEncoding: String) -> Data {
        let te = transferEncoding.lowercased().trimmingCharacters(in: .whitespaces)
        let trimmedBody = body.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))

        if te == "base64" {
            let cleaned = trimmedBody.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            return Data(base64Encoded: cleaned) ?? Data()
        } else if te == "quoted-printable" {
            return decodeQuotedPrintable(trimmedBody)
        } else {
            return trimmedBody.data(using: .utf8) ?? Data()
        }
    }

    /// 解码 Quoted-Printable
    private static func decodeQuotedPrintable(_ input: String) -> Data {
        // 处理软换行
        let unfolded = input.replacingOccurrences(of: "=\r?\n", with: "", options: .regularExpression)
        var bytes = Data()
        var i = unfolded.startIndex

        while i < unfolded.endIndex {
            if unfolded[i] == "=" && unfolded.index(i, offsetBy: 2, limitedBy: unfolded.endIndex) != unfolded.endIndex {
                let next1 = unfolded.index(after: i)
                let next2 = unfolded.index(after: next1)
                let hex = String(unfolded[next1...next2])
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    i = unfolded.index(after: next2)
                    continue
                }
            }
            if let asciiBytes = String(unfolded[i]).data(using: .utf8) {
                bytes.append(asciiBytes)
            }
            i = unfolded.index(after: i)
        }
        return bytes
    }

    /// 解码 MIME encoded-word
    private static func decodeMIMEWord(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        var result = input

        // 使用正则匹配并替换
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsStr = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsStr.length))

        // 从后往前替换以保持索引正确
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let charset = nsStr.substring(with: match.range(at: 1))
            let encoding = nsStr.substring(with: match.range(at: 2)).uppercased()
            let encodedText = nsStr.substring(with: match.range(at: 3))

            var decoded: String?
            if encoding == "B" {
                if let data = Data(base64Encoded: encodedText) {
                    decoded = String(data: data, encoding: charsetToEncoding(charset))
                }
            } else { // Q
                let qpText = encodedText.replacingOccurrences(of: "_", with: " ")
                let data = decodeQuotedPrintable(qpText)
                decoded = String(data: data, encoding: charsetToEncoding(charset))
            }

            if let decoded = decoded {
                let range = match.range
                result = (result as NSString).replacingCharacters(in: range, with: decoded)
            }
        }

        return result
    }

    /// 从 From 头提取显示名称
    private static func extractDisplayName(_ from: String) -> String {
        guard !from.isEmpty else { return "" }

        // 格式1: "Display Name" <email>
        let pattern1 = #"^"?([^"<]+)"?\s*<"#
        if let regex = try? NSRegularExpression(pattern: pattern1),
           let match = regex.firstMatch(in: from, range: NSRange(from.startIndex..., in: from)),
           match.numberOfRanges >= 2 {
            let name = (from as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.contains("@") {
                return decodeMIMEWord(name)
            }
        }

        // 格式2: <email>
        if let emailRange = from.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            let email = String(from[emailRange]).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            return email
        }

        return decodeMIMEWord(from.trimmingCharacters(in: .whitespaces))
    }

    /// 从 Content-Type 提取 boundary
    private static func extractBoundary(_ contentType: String) -> String? {
        let pattern = #"boundary\s*=\s*"?([^";\s]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)) else {
            return nil
        }
        return (contentType as NSString).substring(with: match.range(at: 1))
    }

    /// 从 Content-Type 提取 charset
    private static func extractCharset(_ contentType: String) -> String {
        let pattern = #"charset\s*=\s*"?([^";\s]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)) else {
            return "utf-8"
        }
        return (contentType as NSString).substring(with: match.range(at: 1))
    }

    /// 从 Content-Disposition 提取文件名
    private static func extractFilename(_ disposition: String) -> String? {
        guard !disposition.isEmpty else { return nil }

        // filename*=charset'language'encoded_name
        let patternStar = #"filename\*\s*=\s*([^']*)'[^']*'(.+)"#
        if let regex = try? NSRegularExpression(pattern: patternStar, options: .caseInsensitive),
           let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
           match.numberOfRanges >= 3 {
            let charset = (disposition as NSString).substring(with: match.range(at: 1))
            let encodedName = (disposition as NSString).substring(with: match.range(at: 2))
            if let decoded = encodedName.removingPercentEncoding {
                let data = decoded.data(using: .utf8) ?? Data()
                return String(data: data, encoding: charsetToEncoding(charset))
            }
        }

        // filename="xxx"
        let pattern = #"filename\s*=\s*"?([^";\r\n]+)"?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)) {
            let name = (disposition as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return decodeMIMEWord(name)
        }

        return nil
    }

    /// charset 转 String.Encoding
    private static func charsetToEncoding(_ charset: String) -> String.Encoding {
        let lower = charset.lowercased()
        switch lower {
        case "utf-8", "utf8": return .utf8
        case "gb2312", "gbk", "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "ascii": return .ascii
        default: return .utf8
        }
    }

    /// 简易 HTML 转纯文本
    private static func htmlToPlainText(_ html: String) -> String {
        var text = html

        // 移除 style 和 script
        text = text.replacingOccurrences(of: #"<style[^>]*>[\s\S]*?</style>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<script[^>]*>[\s\S]*?</script>"#, with: "", options: .regularExpression)

        // 换行标签
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</(p|div|tr|li|h[1-6])>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<(p|div|tr|li|h[1-6])[^>]*>"#, with: "\n", options: .regularExpression)

        // td 转空格
        text = text.replacingOccurrences(of: #"</?td[^>]*>"#, with: " ", options: .regularExpression)

        // 移除所有 HTML 标签
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // 解码 HTML 实体
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        // 清理多余空行
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
