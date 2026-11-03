import Foundation

struct ExcelExportResult {
    let log: String
    let unknownUsers: [String]
    let emailList: [String]
    let dataList: [BanBenJiraDto]
    let noticeContent: String
}

actor ExcelService {
    static let shared = ExcelService()
    private init() {}

    private let jira = JiraService.shared

    func exportExcel(beforeDate: String, outFilePath: String, templateFilePath: String, sheetName: String) async -> ExcelExportResult {
        do {
            let jql = "预计修复时间 > 2025-01-01 AND 预计修复时间 < \(beforeDate) AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10919] ASC, cf[11923] ASC, cf[10126] ASC, cf[10106] DESC"
            let issues = try await jira.searchJQL(jql)

            var dataList: [BanBenJiraDto] = []
            var allSendName = Set<String>()
            var jiraTongZhiDtoList: [JiraTongZhiDto] = []
            var taskLog = ""
            
            // Debug: Print field structure for first issue
            if let firstIssue = issues.first {
                taskLog += "=== 字段调试信息 ===\n"
                taskLog += "问题: \(firstIssue.key)\n"
                taskLog += "所有字段ID:\n"
                for (key, value) in firstIssue.fields {
                    let valueType = type(of: value)
                    taskLog += "  - \(key): \(valueType)\n"
                }
                taskLog += "\n"
            }

            for issue in issues {
                var dto = BanBenJiraDto()
                let key = issue.key
                let summer = issue.summary
                var singleStr = "[\(key) \(summer)](http://jira.sinosafe.com.cn/browse/\(key))"

                var displayName = ""
                if let devObj = issue.fields["customfield_10125"] as? [String: Any] {
                    displayName = devObj["displayName"] as? String ?? ""
                    if !displayName.isEmpty {
                        singleStr += " #\(displayName) "
                    }
                }

                var reqType = "常规"
                var remark = ""
                var noticeRemark = ""

                for label in issue.labels {
                    if label.contains("同步上线") || label.contains("专题") || label.contains("项目") || label.contains("监管") {
                        singleStr += " #\(label) "
                    }
                    if label.contains("同步上线") {
                        remark += label
                        noticeRemark += label
                    }
                    if label.contains("专题") { reqType = "专题" }
                    if label.contains("项目") { reqType = "项目" }
                    if label.contains("监管") { reqType = "监管" }
                }

                if issue.issueType == "缺陷" {
                    reqType = "缺陷"
                }

                // User relate
                if let userRelate = issue.fields["customfield_13269"] as? String {
                    let tongZhiDto = JiraTongZhiDto(reqId: issue.key, userNotice: [], noticeRemark: "")
                    var userNotice = Set<String>()

                    var noticeRemark2 = ""
                    if let userRelateRemark = issue.fields["customfield_13270"] as? String {
                        noticeRemark2 = userRelateRemark
                    }

                    var finalNotice = noticeRemark
                    if !noticeRemark2.isEmpty {
                        finalNotice = finalNotice.isEmpty ? noticeRemark2 : "\(noticeRemark),\(noticeRemark2)"
                    }

                    let separators: [Character] = ["，", ",", "、", ";", "；"]
                    let splitUsers = userRelate.split { separators.contains($0) }.map { String($0).trimmingCharacters(in: .whitespaces) }
                    for u in splitUsers {
                        allSendName.insert(u)
                        userNotice.insert(u)
                    }

                    var tz = tongZhiDto
                    tz.userNotice = userNotice
                    tz.noticeRemark = finalNotice
                    jiraTongZhiDtoList.append(tz)
                }

                // User develop
                if let userDevelop = issue.fields["customfield_10123"] as? String {
                    let separators: [Character] = ["，", ",", "、", ";", "；"]
                    let splitUsers = userDevelop.split { separators.contains($0) }.map { String($0).trimmingCharacters(in: .whitespaces) }
                    for u in splitUsers {
                        allSendName.insert(u)
                    }
                }

                // User test
                if let userTest2 = issue.fields["customfield_10107"] as? String {
                    let separators: [Character] = ["，", ",", "、", ";", "；"]
                    let splitUsers = userTest2.split { separators.contains($0) }.map { String($0).trimmingCharacters(in: .whitespaces) }
                    for u in splitUsers {
                        allSendName.insert(u)
                    }
                }

                // Modify system - process ALL versions from customfield_10126
                var modifySystem = ""
                var allVersionName = Set<String>()
                if let versions = issue.fields["customfield_10126"] as? [[String: Any]] {
                    for versionDict in versions {
                        if let versionName = versionDict["name"] as? String {
                            // Parse version name to extract system code
                            // Format: "SYSTEMCODE_version" or similar
                            let parts = versionName.split(separator: "_")
                            if parts.count > 1 {
                                let banben = String(parts[0])
                                if let sys = SystemEnum.getBySystemPublishName(banben) {
                                    allVersionName.insert(sys.systemName)
                                }
                            } else {
                                // If no underscore, try the full name
                                if let sys = SystemEnum.getBySystemPublishName(versionName) {
                                    allVersionName.insert(sys.systemName)
                                }
                            }
                        }
                    }
                }
                modifySystem = allVersionName.sorted().joined(separator: ",")
                
                // Fallback: if modifySystem is empty, use customfield_10125 (系统名称（开发）)
                // This is a cascading select field, we need the child (secondary) value
                if modifySystem.isEmpty {
                    if let devSystemObj = issue.fields["customfield_10125"] as? [String: Any] {
                        // Try to get child (secondary level) first
                        if let childObj = devSystemObj["child"] as? [String: Any] {
                            var systemName = childObj["value"] as? String ?? childObj["name"] as? String ?? ""
                            // Remove version prefix if exists (e.g., "TPMS-第三方管理服务" -> "第三方管理服务")
                            if let dashIndex = systemName.firstIndex(of: "-") {
                                systemName = String(systemName[systemName.index(after: dashIndex)...])
                            }
                            modifySystem = systemName
                        } else {
                            // Fallback to parent (primary level) if child doesn't exist
                            var systemName = devSystemObj["value"] as? String ?? devSystemObj["name"] as? String ?? ""
                            // Remove version prefix if exists
                            if let dashIndex = systemName.firstIndex(of: "-") {
                                systemName = String(systemName[systemName.index(after: dashIndex)...])
                            }
                            modifySystem = systemName
                        }
                    } else if let devSystemStr = issue.fields["customfield_10125"] as? String {
                        var systemName = devSystemStr
                        // Remove version prefix if exists
                        if let dashIndex = systemName.firstIndex(of: "-") {
                            systemName = String(systemName[systemName.index(after: dashIndex)...])
                        }
                        modifySystem = systemName
                    }
                }

                // Progress
                var progress = "开发"
                if issue.status == "内部测试" || issue.status == "用户测试" || issue.status == "版本上线" {
                    progress = issue.status
                }

                singleStr += " *\(beforeDate) "
                taskLog += "\n\(singleStr)"

                dto.reqId = key
                dto.reqName = summer
                dto.reqType = reqType
                dto.userDevelop = issue.fields["customfield_10123"] as? String ?? ""
                
                // User test - debug and extract
                if let userTestField = issue.fields["customfield_11915"] {
                    if let userTestStr = userTestField as? String {
                        dto.userTest = userTestStr
                    } else if let userTestObj = userTestField as? [String: Any] {
                        dto.userTest = userTestObj["displayName"] as? String ?? userTestObj["name"] as? String ?? userTestObj["value"] as? String ?? ""
                    } else if let userTestArray = userTestField as? [[String: Any]] {
                        dto.userTest = userTestArray.map { $0["displayName"] as? String ?? $0["name"] as? String ?? "" }.filter { !$0.isEmpty }.joined(separator: ", ")
                    } else {
                        taskLog += "\n[\(key)] 用户测试字段类型未知: \(type(of: userTestField))"
                        dto.userTest = ""
                    }
                } else {
                    taskLog += "\n[\(key)] 用户测试字段(customfield_11915)不存在"
                    dto.userTest = ""
                }
                
                // Schedule launch date - debug and extract
                if let scheduleField = issue.fields["customfield_10919"] {
                    if let scheduleStr = scheduleField as? String {
                        dto.scheduleLaunchDate = scheduleStr
                    } else if let scheduleObj = scheduleField as? [String: Any] {
                        dto.scheduleLaunchDate = scheduleObj["value"] as? String ?? scheduleObj["name"] as? String ?? ""
                    } else {
                        taskLog += "\n[\(key)] 排期上线日期字段类型未知: \(type(of: scheduleField))"
                        dto.scheduleLaunchDate = ""
                    }
                } else {
                    taskLog += "\n[\(key)] 排期上线日期字段(customfield_10919)不存在"
                    dto.scheduleLaunchDate = ""
                }
                
                dto.remark = remark
                dto.modifySystem = modifySystem
                dto.progress = progress

                dataList.append(dto)
            }

            // Build email list and collect unknown users
            var emailSet = Set<String>()
            var unknownUsers = Set<String>()
            for user in allSendName {
                if let email = UserEnum.getEmail(for: user) {
                    emailSet.insert(email)
                } else {
                    unknownUsers.insert(user)
                }
            }

            let fixedEmails = [
                "chenshuhao@sinosafe.com.cn",
                "chenxiefan@sinosafe.com.cn",
                "huangshishui@sinosafe.com.cn",
                "sunyuanyuan2@sinosafe.com.cn",
                "zhongjinquan@sinosafe.com.cn",
                "zouyang1@sinosafe.com.cn",
                "lixiaolong1@sinosafe.com.cn",
                "xingjun@sinosafe.com.cn",
                "lanjianwei@sinosafe.com.cn",
                "luojiasheng@sinosafe.com.cn",
                "heguihui@sinosafe.com.cn",
                "zhoukai2@sinosafe.com.cn",
                "lisonglin@sinosafe.com.cn",
                "ex_weichao@sinosafe.com.cn",
                "ex_liudongshan@sinosafe.com.cn"
            ]
            for e in fixedEmails { emailSet.insert(e) }

            var sb = ""
            for (index, tz) in jiraTongZhiDtoList.enumerated() {
                sb += "\(index + 1)、\(tz.reqId) \(tz.noticeRemark) "
                for u in tz.userNotice {
                    sb += "@\(u) "
                }
                sb += "\n"
            }

            // Export to Excel with template style
            let finalPath = outFilePath.hasSuffix(".xlsx") ? outFilePath : outFilePath.replacingOccurrences(of: ".csv", with: ".xlsx")
            
            if !templateFilePath.isEmpty && FileManager.default.fileExists(atPath: templateFilePath) {
                // Use template to create styled Excel
                try await createStyledExcelFromTemplate(templatePath: templateFilePath, outputPath: finalPath, dataList: dataList)
            } else {
                // Create basic styled Excel without template
                try await createBasicStyledExcel(outputPath: finalPath, dataList: dataList)
            }

            var result = "已导出 Excel: \(finalPath)\n\n"
            if !unknownUsers.isEmpty {
                result += "⚠️ 有 \(unknownUsers.count) 个用户未找到邮箱映射，请确认后补充\n\n"
            }
            result += "邮件列表:\n"
            result += emailSet.sorted().joined(separator: ";")
            result += "\n\n通知事项:\n"
            result += sb
            return ExcelExportResult(
                log: result,
                unknownUsers: Array(unknownUsers).sorted(),
                emailList: Array(emailSet).sorted(),
                dataList: dataList,
                noticeContent: sb
            )
        } catch {
            return ExcelExportResult(
                log: "导出失败: \(error.localizedDescription)",
                unknownUsers: [],
                emailList: [],
                dataList: [],
                noticeContent: ""
            )
        }
    }
    
    // MARK: - Excel Generation Methods
    
    private func createStyledExcelFromTemplate(templatePath: String, outputPath: String, dataList: [BanBenJiraDto]) async throws {
        // Create a temporary directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let extractionDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        
        do {
            // Unzip template using unzip command (more reliable than ditto for xlsx)
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", templatePath, "-d", extractionDir.path]
            
            let pipe = Pipe()
            unzipProcess.standardError = pipe
            unzipProcess.standardOutput = Pipe()
            
            try unzipProcess.run()
            unzipProcess.waitUntilExit()
            
            if unzipProcess.terminationStatus != 0 {
                let errorData = try pipe.fileHandleForReading.readToEnd()
                let errorMsg = String(data: errorData ?? Data(), encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "ExcelService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to unzip template: \(errorMsg)"
                ])
            }
            
            // Find the xl directory (might be in a subdirectory)
            var xlDir: URL?
            let fileManager = FileManager.default
            
            // Try direct path first
            let directXlPath = extractionDir.appendingPathComponent("xl")
            if fileManager.fileExists(atPath: directXlPath.path) {
                xlDir = directXlPath
            } else {
                // Search for xl directory in subdirectories
                if let enumerator = fileManager.enumerator(at: extractionDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.lastPathComponent == "xl" {
                            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                            if isDir {
                                xlDir = fileURL
                                break
                            }
                        }
                    }
                }
            }
            
            guard let xlDir = xlDir else {
                throw NSError(domain: "ExcelService", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Template structure invalid: xl directory not found"
                ])
            }
            
            let worksheetsDir = xlDir.appendingPathComponent("worksheets")
            let sheet1Path = worksheetsDir.appendingPathComponent("sheet1.xml")
            
            if !fileManager.fileExists(atPath: sheet1Path.path) {
                throw NSError(domain: "ExcelService", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Template structure invalid: sheet1.xml not found"
                ])
            }
            
            var sheetContent = try String(contentsOf: sheet1Path, encoding: .utf8)
            
            // Replace the entire sheetData section with our data
            // Find the opening <sheetData...> tag
            guard let openRange = sheetContent.range(of: "<sheetData[^>]*>", options: .regularExpression),
                  let closeRange = sheetContent.range(of: "</sheetData>", options: .regularExpression) else {
                throw NSError(domain: "ExcelService", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid sheet structure: sheetData tags not found"
                ])
            }
            
            // Build new sheetData content
            var newSheetData = ""
            newSheetData += String(sheetContent[openRange])  // Keep the opening tag with all attributes
            newSheetData += "\n"
            
            // Add header row (row 1) - use style from template if available
            // From the template: 
            //   - Columns A-F: s="1" (header style)
            //   - Columns G-I: s="3" (header style - orange)
            newSheetData += "    <row r=\"1\" spans=\"1:9\">\n"
            let headers = ["需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注"]
            for (idx, header) in headers.enumerated() {
                let col = idx + 1
                let colLetter = letterForColumn(col)
                // Columns G-I (7-9) use style 3 (orange) for header
                let styleIndex = (col >= 7) ? 3 : 1
                newSheetData += "        <c r=\"\(colLetter)1\" s=\"\(styleIndex)\" t=\"inlineStr\"><is><t>\(escapeXML(header))</t></is></c>\n"
            }
            newSheetData += "    </row>\n"
            
            // Add data rows (starting from row 2)
            // All data columns use s="2" (normal data style)
            for (rowIdx, item) in dataList.enumerated() {
                let row = rowIdx + 2
                newSheetData += "    <row r=\"\(row)\" spans=\"1:9\">\n"
                newSheetData += "        <c r=\"A\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.reqType))</t></is></c>\n"
                newSheetData += "        <c r=\"B\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.reqId))</t></is></c>\n"
                newSheetData += "        <c r=\"C\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.reqName))</t></is></c>\n"
                newSheetData += "        <c r=\"D\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.userDevelop))</t></is></c>\n"
                newSheetData += "        <c r=\"E\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.userTest))</t></is></c>\n"
                newSheetData += "        <c r=\"F\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.modifySystem))</t></is></c>\n"
                newSheetData += "        <c r=\"G\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.progress))</t></is></c>\n"
                newSheetData += "        <c r=\"H\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.scheduleLaunchDate))</t></is></c>\n"
                newSheetData += "        <c r=\"I\(row)\" s=\"2\" t=\"inlineStr\"><is><t>\(escapeXML(item.remark))</t></is></c>\n"
                newSheetData += "    </row>\n"
            }
            
            newSheetData += "</sheetData>"
            
            // Replace the old sheetData section with new content
            let fullRange = openRange.lowerBound..<closeRange.upperBound
            sheetContent.replaceSubrange(fullRange, with: newSheetData)
            
            // Write back the modified content
            try sheetContent.write(to: sheet1Path, atomically: true, encoding: .utf8)
            
            // Zip back to xlsx using zip command
            // Need to find the root directory that contains the xlsx structure
            var zipSourceDir = extractionDir
            if let enumerator = fileManager.enumerator(at: extractionDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent != "extracted" && 
                       fileManager.fileExists(atPath: fileURL.appendingPathComponent("[Content_Types].xml").path) {
                        zipSourceDir = fileURL
                        break
                    }
                }
            }
            
            let zipProcess = Process()
            zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zipProcess.arguments = ["-r", "-q", outputPath, "."]
            zipProcess.currentDirectoryURL = zipSourceDir
            
            try zipProcess.run()
            zipProcess.waitUntilExit()
            
            if zipProcess.terminationStatus != 0 {
                throw NSError(domain: "ExcelService", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create xlsx file"
                ])
            }
            
            // Verify output
            if !fileManager.fileExists(atPath: outputPath) {
                throw NSError(domain: "ExcelService", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Output file was not created"
                ])
            }
        } catch {
            // Cleanup on error
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    private func createBasicStyledExcel(outputPath: String, dataList: [BanBenJiraDto]) async throws {
        // Create a basic xlsx file with styling
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Create directory structure
        let xlDir = tempDir.appendingPathComponent("xl")
        let worksheetsDir = xlDir.appendingPathComponent("worksheets")
        let relsDir = tempDir.appendingPathComponent("_rels")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        
        try FileManager.default.createDirectory(at: worksheetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)
        
        // [Content-Type].xml
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        
        // _rels/.rels
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        try rootRels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        
        // xl/workbook.xml
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets>
                <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
            </sheets>
        </workbook>
        """
        try workbook.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        
        // xl/_rels/workbook.xml.rels
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
        try workbookRels.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)
        
        // xl/styles.xml - Define styles
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2">
                <font>
                    <sz val="11"/>
                    <name val="Arial"/>
                </font>
                <font>
                    <b/>
                    <sz val="11"/>
                    <name val="Arial"/>
                </font>
            </fonts>
            <fills count="2">
                <fill>
                    <patternFill patternType="none"/>
                </fill>
                <fill>
                    <patternFill patternType="solid">
                        <fgColor rgb="FF4472C4"/>
                    </patternFill>
                </fill>
            </fills>
            <borders count="1">
                <border>
                    <left/>
                    <right/>
                    <top/>
                    <bottom/>
                    <diagonal/>
                </border>
            </borders>
            <cellStyleXfs count="1">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
            </cellStyleXfs>
            <cellXfs count="3">
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
                <xf numFmtId="0" fontId="1" fillId="1" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
                <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            </cellXfs>
        </styleSheet>
        """
        try styles.write(to: xlDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
        
        // Build shared strings
        var sharedStrings = Set<String>()
        sharedStrings.formUnion(["需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注"])
        for item in dataList {
            sharedStrings.insert(item.reqType)
            sharedStrings.insert(item.reqId)
            sharedStrings.insert(item.reqName)
            sharedStrings.insert(item.userDevelop)
            sharedStrings.insert(item.userTest)
            sharedStrings.insert(item.modifySystem)
            sharedStrings.insert(item.progress)
            sharedStrings.insert(item.scheduleLaunchDate)
            sharedStrings.insert(item.remark)
        }
        
        let sortedStrings = Array(sharedStrings).sorted()
        var sharedStringsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">
        """
        for str in sortedStrings {
            sharedStringsXML += "<si><t>\(escapeXML(str))</t></si>"
        }
        sharedStringsXML += "</sst>"
        try sharedStringsXML.write(to: xlDir.appendingPathComponent("sharedStrings.xml"), atomically: true, encoding: .utf8)
        
        // Create string index map
        let stringIndexMap = Dictionary(uniqueKeysWithValues: sortedStrings.enumerated().map { ($0.1, $0.0) })
        
        // xl/worksheets/sheet1.xml
        var sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheetData>
        """
        
        // Header row
        sheetXML += "<row r=\"1\" spans=\"1:9\">"
        let headers = ["需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注"]
        for (idx, header) in headers.enumerated() {
            let col = idx + 1
            let strIdx = stringIndexMap[header] ?? 0
            sheetXML += "<c r=\"\(letterForColumn(col))1\" s=\"1\" t=\"s\"><v>\(strIdx)</v></c>"
        }
        sheetXML += "</row>"
        
        // Data rows
        for (rowIdx, item) in dataList.enumerated() {
            let row = rowIdx + 2
            sheetXML += "<row r=\"\(row)\" spans=\"1:9\">"
            sheetXML += createCellWithSharedString(column: 1, row: row, value: item.reqType, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 2, row: row, value: item.reqId, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 3, row: row, value: item.reqName, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 4, row: row, value: item.userDevelop, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 5, row: row, value: item.userTest, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 6, row: row, value: item.modifySystem, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 7, row: row, value: item.progress, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 8, row: row, value: item.scheduleLaunchDate, stringIndexMap: stringIndexMap)
            sheetXML += createCellWithSharedString(column: 9, row: row, value: item.remark, stringIndexMap: stringIndexMap)
            sheetXML += "</row>"
        }
        
        sheetXML += """
            </sheetData>
        </worksheet>
        """
        
        try sheetXML.write(to: worksheetsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)
        
        // Zip to create xlsx using zip command
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", "-q", outputPath, "."]
        zipProcess.currentDirectoryURL = tempDir
        
        try zipProcess.run()
        zipProcess.waitUntilExit()
        
        if zipProcess.terminationStatus != 0 {
            throw NSError(domain: "ExcelService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create xlsx file"
            ])
        }
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Helper Methods
    
    private func letterForColumn(_ col: Int) -> String {
        var column = col
        var letter = ""
        while column > 0 {
            let remainder = (column - 1) % 26
            letter = String(UnicodeScalar(65 + remainder)!) + letter
            column = (column - 1) / 26
        }
        return letter
    }
    
    private func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    private func createCell(column: Int, row: Int, value: String, style: Int) -> String {
        let colLetter = letterForColumn(column)
        let escapedValue = escapeXML(value)
        return "<c r=\"\(colLetter)\(row)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(escapedValue)</t></is></c>"
    }
    
    private func createCellWithSharedString(column: Int, row: Int, value: String, stringIndexMap: [String: Int]) -> String {
        let colLetter = letterForColumn(column)
        let strIdx = stringIndexMap[value] ?? 0
        return "<c r=\"\(colLetter)\(row)\" t=\"s\"><v>\(strIdx)</v></c>"
    }
}

