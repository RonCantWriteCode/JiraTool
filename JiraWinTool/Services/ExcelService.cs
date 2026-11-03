using System.Globalization;
using System.IO.Compression;
using System.Text;
using JiraWinTool.Models;
using Newtonsoft.Json.Linq;

namespace JiraWinTool.Services;

/// <summary>Excel导出服务（移植自 Swift ExcelService.swift）</summary>
public class ExcelService
{
    public static ExcelService Shared { get; } = new();

    private readonly JiraService _jira = JiraService.Shared;

    public async Task<ExcelExportResult> ExportExcelAsync(string beforeDate, string outFilePath, string templateFilePath, string sheetName)
    {
        try
        {
            var jql = $"预计修复时间 > 2025-01-01 AND 预计修复时间 < {beforeDate} AND 系统名称（开发） in (理赔条线) AND status != Closed ORDER BY cf[10919] ASC, cf[11923] ASC, cf[10126] ASC, cf[10106] DESC";
            var issues = await _jira.SearchJQLAsync(jql);

            var dataList = new List<BanBenJiraDto>();
            var allSendName = new HashSet<string>();
            var jiraTongZhiDtoList = new List<JiraTongZhiDto>();
            var taskLog = "";

            foreach (var issue in issues)
            {
                var dto = new BanBenJiraDto();
                var key = issue.Key;
                var summer = issue.Summary;
                var singleStr = $"[{key} {summer}](http://jira.sinosafe.com.cn/browse/{key})";

                var displayName = "";
                if (issue.Fields["customfield_10125"] is JObject devObj)
                {
                    displayName = devObj["displayName"]?.Value<string>() ?? "";
                    if (!string.IsNullOrEmpty(displayName))
                        singleStr += $" #{displayName} ";
                }

                var reqType = "常规";
                var remark = "";
                var noticeRemark = "";

                foreach (var label in issue.Labels)
                {
                    if (label.Contains("同步上线") || label.Contains("专题") || label.Contains("项目") || label.Contains("监管"))
                        singleStr += $" #{label} ";
                    if (label.Contains("同步上线"))
                    {
                        remark += label;
                        noticeRemark += label;
                    }
                    if (label.Contains("专题")) reqType = "专题";
                    if (label.Contains("项目")) reqType = "项目";
                    if (label.Contains("监管")) reqType = "监管";
                }

                if (issue.IssueType == "缺陷")
                    reqType = "缺陷";

                // User relate
                var userRelate = issue.Fields["customfield_13269"]?.Value<string>();
                if (!string.IsNullOrEmpty(userRelate))
                {
                    var userNotice = new HashSet<string>();

                    var noticeRemark2 = issue.Fields["customfield_13270"]?.Value<string>() ?? "";

                    var finalNotice = noticeRemark;
                    if (!string.IsNullOrEmpty(noticeRemark2))
                        finalNotice = string.IsNullOrEmpty(finalNotice) ? noticeRemark2 : $"{noticeRemark},{noticeRemark2}";

                    var separators = new[] { '，', ',', '、', ';', '；' };
                    var splitUsers = userRelate.Split(separators, StringSplitOptions.RemoveEmptyEntries)
                        .Select(u => u.Trim()).Where(u => !string.IsNullOrEmpty(u));

                    foreach (var u in splitUsers)
                    {
                        allSendName.Add(u);
                        userNotice.Add(u);
                    }

                    jiraTongZhiDtoList.Add(new JiraTongZhiDto
                    {
                        ReqId = issue.Key,
                        UserNotice = userNotice,
                        NoticeRemark = finalNotice
                    });
                }

                // User develop
                var userDevelop = issue.Fields["customfield_10123"]?.Value<string>();
                if (!string.IsNullOrEmpty(userDevelop))
                {
                    var separators = new[] { '，', ',', '、', ';', '；' };
                    foreach (var u in userDevelop.Split(separators, StringSplitOptions.RemoveEmptyEntries)
                        .Select(u => u.Trim()).Where(u => !string.IsNullOrEmpty(u)))
                    {
                        allSendName.Add(u);
                    }
                }

                // User test
                var userTestStr2 = issue.Fields["customfield_10107"]?.Value<string>();
                if (!string.IsNullOrEmpty(userTestStr2))
                {
                    var separators = new[] { '，', ',', '、', ';', '；' };
                    foreach (var u in userTestStr2.Split(separators, StringSplitOptions.RemoveEmptyEntries)
                        .Select(u => u.Trim()).Where(u => !string.IsNullOrEmpty(u)))
                    {
                        allSendName.Add(u);
                    }
                }

                // Modify system - process ALL versions from customfield_10126
                var modifySystem = "";
                var allVersionName = new HashSet<string>();
                if (issue.Fields["customfield_10126"] is JArray versions)
                {
                    foreach (var versionDict in versions.OfType<JObject>())
                    {
                        var versionName = versionDict["name"]?.Value<string>();
                        if (string.IsNullOrEmpty(versionName)) continue;
                        var parts = versionName.Split('_');
                        if (parts.Length > 1)
                        {
                            var banben = parts[0];
                            var sys = SystemEnumExtensions.GetBySystemPublishName(banben);
                            if (sys != null)
                                allVersionName.Add(sys.Value.SystemName());
                        }
                        else
                        {
                            var sys = SystemEnumExtensions.GetBySystemPublishName(versionName);
                            if (sys != null)
                                allVersionName.Add(sys.Value.SystemName());
                        }
                    }
                }
                modifySystem = string.Join(",", allVersionName.OrderBy(n => n));

                // Fallback: customfield_10125 (系统名称（开发）)
                if (string.IsNullOrEmpty(modifySystem))
                {
                    if (issue.Fields["customfield_10125"] is JObject devSystemObj)
                    {
                        var childObj = devSystemObj["child"] as JObject;
                        var systemName = childObj?["value"]?.Value<string>() ?? childObj?["name"]?.Value<string>()
                                         ?? devSystemObj["value"]?.Value<string>() ?? devSystemObj["name"]?.Value<string>() ?? "";
                        var dashIndex = systemName.IndexOf('-');
                        if (dashIndex >= 0 && dashIndex < systemName.Length - 1)
                            systemName = systemName.Substring(dashIndex + 1);
                        modifySystem = systemName;
                    }
                    else if (issue.Fields["customfield_10125"]?.Value<string>() is string devSystemStr)
                    {
                        var dashIndex = devSystemStr.IndexOf('-');
                        if (dashIndex >= 0 && dashIndex < devSystemStr.Length - 1)
                            devSystemStr = devSystemStr.Substring(dashIndex + 1);
                        modifySystem = devSystemStr;
                    }
                }

                // Progress
                var progress = "开发";
                if (issue.Status is "内部测试" or "用户测试" or "版本上线")
                    progress = issue.Status;

                singleStr += $" *{beforeDate} ";
                taskLog += $"\n{singleStr}";

                dto.ReqId = key;
                dto.ReqName = summer;
                dto.ReqType = reqType;
                dto.UserDevelop = issue.Fields["customfield_10123"]?.Value<string>() ?? "";

                // User test - extract from customfield_11915
                var userTestField = issue.Fields["customfield_11915"];
                if (userTestField != null)
                {
                    dto.UserTest = userTestField switch
                    {
                        JValue jv => jv.Value<string>() ?? "",
                        JObject jo => jo["displayName"]?.Value<string>() ?? jo["name"]?.Value<string>() ?? jo["value"]?.Value<string>() ?? "",
                        JArray ja => string.Join(", ", ja.OfType<JObject>().Select(o => o["displayName"]?.Value<string>() ?? o["name"]?.Value<string>() ?? "").Where(s => !string.IsNullOrEmpty(s))),
                        _ => ""
                    };
                }

                // Schedule launch date
                var scheduleField = issue.Fields["customfield_10919"];
                dto.ScheduleLaunchDate = scheduleField switch
                {
                    JValue jv => jv.Value<string>() ?? "",
                    JObject jo => jo["value"]?.Value<string>() ?? jo["name"]?.Value<string>() ?? "",
                    _ => ""
                };

                dto.Remark = remark;
                dto.ModifySystem = modifySystem;
                dto.Progress = progress;

                dataList.Add(dto);
            }

            // Build email list and collect unknown users
            var emailSet = new HashSet<string>();
            var unknownUsersSet = new HashSet<string>();
            foreach (var user in allSendName)
            {
                var email = UserEmailMapping.GetEmail(user);
                if (email != null)
                    emailSet.Add(email);
                else
                    unknownUsersSet.Add(user);
            }

            var fixedEmails = new[]
            {
                "chenshuhao@sinosafe.com.cn", "chenxiefan@sinosafe.com.cn", "huangshishui@sinosafe.com.cn",
                "sunyuanyuan2@sinosafe.com.cn", "zhongjinquan@sinosafe.com.cn", "zouyang1@sinosafe.com.cn",
                "lixiaolong1@sinosafe.com.cn", "xingjun@sinosafe.com.cn", "lanjianwei@sinosafe.com.cn",
                "luojiasheng@sinosafe.com.cn", "heguihui@sinosafe.com.cn", "zhoukai2@sinosafe.com.cn",
                "lisonglin@sinosafe.com.cn", "ex_weichao@sinosafe.com.cn", "ex_liudongshan@sinosafe.com.cn"
            };
            foreach (var e in fixedEmails) emailSet.Add(e);

            var sb = "";
            for (int i = 0; i < jiraTongZhiDtoList.Count; i++)
            {
                var tz = jiraTongZhiDtoList[i];
                sb += $"{i + 1}、{tz.ReqId} {tz.NoticeRemark} ";
                foreach (var u in tz.UserNotice)
                    sb += $"@{u} ";
                sb += "\n";
            }

            // Export to Excel
            var finalPath = outFilePath.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)
                ? outFilePath : outFilePath.Replace(".csv", ".xlsx", StringComparison.OrdinalIgnoreCase);

            if (!string.IsNullOrEmpty(templateFilePath) && File.Exists(templateFilePath))
            {
                await CreateStyledExcelFromTemplateAsync(templateFilePath, finalPath, dataList);
            }
            else
            {
                await CreateBasicStyledExcelAsync(finalPath, dataList);
            }

            var result = $"已导出 Excel: {finalPath}\n\n";
            if (unknownUsersSet.Count > 0)
            {
                result += $"⚠️ 有 {unknownUsersSet.Count} 个用户未找到邮箱映射，请确认后补充\n\n";
            }
            result += "邮件列表:\n";
            result += string.Join(";", emailSet.OrderBy(e => e));
            result += "\n\n通知事项:\n";
            result += sb;

            return new ExcelExportResult
            {
                Log = result,
                UnknownUsers = unknownUsersSet.OrderBy(u => u).ToArray(),
                EmailList = emailSet.OrderBy(e => e).ToArray(),
                DataList = dataList,
                NoticeContent = sb
            };
        }
        catch (Exception ex)
        {
            return new ExcelExportResult
            {
                Log = $"导出失败: {ex.Message}",
                UnknownUsers = Array.Empty<string>(),
                EmailList = Array.Empty<string>(),
                DataList = new List<BanBenJiraDto>(),
                NoticeContent = ""
            };
        }
    }

    // MARK: - Excel Generation Methods

    private static async Task CreateStyledExcelFromTemplateAsync(string templatePath, string outputPath, List<BanBenJiraDto> dataList)
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            ZipFile.ExtractToDirectory(templatePath, tempDir);

            // Find the xl directory
            var xlDir = Path.Combine(tempDir, "xl");
            if (!Directory.Exists(xlDir))
            {
                // Search subdirectories
                xlDir = Directory.GetDirectories(tempDir, "xl", SearchOption.AllDirectories).FirstOrDefault() ?? "";
            }

            if (string.IsNullOrEmpty(xlDir) || !Directory.Exists(xlDir))
                throw new InvalidOperationException("Template structure invalid: xl directory not found");

            var worksheetsDir = Path.Combine(xlDir, "worksheets");
            var sheet1Path = Path.Combine(worksheetsDir, "sheet1.xml");
            if (!File.Exists(sheet1Path))
                throw new InvalidOperationException("Template structure invalid: sheet1.xml not found");

            var sheetContent = await File.ReadAllTextAsync(sheet1Path);

            // Replace sheetData
            var openTag = "<sheetData";
            var closeTag = "</sheetData>";
            var openIdx = sheetContent.IndexOf(openTag);
            var closeIdx = sheetContent.LastIndexOf(closeTag) + closeTag.Length;

            if (openIdx < 0 || closeIdx <= closeTag.Length)
                throw new InvalidOperationException("Invalid sheet structure: sheetData tags not found");

            // Find end of open tag
            var openEnd = sheetContent.IndexOf('>', openIdx) + 1;
            var newSheetData = sheetContent[openIdx..openEnd] + "\n";

            // Header row
            newSheetData += "    <row r=\"1\" spans=\"1:9\">\n";
            var headers = new[] { "需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注" };
            for (int i = 0; i < headers.Length; i++)
            {
                var colLetter = LetterForColumn(i + 1);
                var styleIndex = (i + 1 >= 7) ? 3 : 1;
                newSheetData += $"        <c r=\"{colLetter}1\" s=\"{styleIndex}\" t=\"inlineStr\"><is><t>{EscapeXml(headers[i])}</t></is></c>\n";
            }
            newSheetData += "    </row>\n";

            // Data rows
            for (int rowIdx = 0; rowIdx < dataList.Count; rowIdx++)
            {
                var row = rowIdx + 2;
                var item = dataList[rowIdx];
                newSheetData += $"    <row r=\"{row}\" spans=\"1:9\">\n";
                newSheetData += CreateInlineCell(1, row, item.ReqType, 2);
                newSheetData += CreateInlineCell(2, row, item.ReqId, 2);
                newSheetData += CreateInlineCell(3, row, item.ReqName, 2);
                newSheetData += CreateInlineCell(4, row, item.UserDevelop, 2);
                newSheetData += CreateInlineCell(5, row, item.UserTest, 2);
                newSheetData += CreateInlineCell(6, row, item.ModifySystem, 2);
                newSheetData += CreateInlineCell(7, row, item.Progress, 2);
                newSheetData += CreateInlineCell(8, row, item.ScheduleLaunchDate, 2);
                newSheetData += CreateInlineCell(9, row, item.Remark, 2);
                newSheetData += "    </row>\n";
            }

            newSheetData += closeTag;

            // Replace old sheetData content
            sheetContent = sheetContent[..openIdx] + newSheetData + sheetContent[closeIdx..];
            await File.WriteAllTextAsync(sheet1Path, sheetContent);

            // Find zip source dir (root of extracted xlsx)
            var contentTypesPath = Path.Combine(tempDir, "[Content_Types].xml");
            var zipSourceDir = tempDir;
            if (!File.Exists(contentTypesPath))
            {
                zipSourceDir = Directory.GetFiles(tempDir, "[Content_Types].xml", SearchOption.AllDirectories)
                    .Select(Path.GetDirectoryName)
                    .FirstOrDefault() ?? tempDir;
            }

            // Create zip
            if (File.Exists(outputPath))
                File.Delete(outputPath);
            ZipFile.CreateFromDirectory(zipSourceDir, outputPath);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, true); } catch { }
            }
        }
    }

    private static async Task CreateBasicStyledExcelAsync(string outputPath, List<BanBenJiraDto> dataList)
    {
        var tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            // Create directory structure
            var xlDir = Path.Combine(tempDir, "xl");
            var worksheetsDir = Path.Combine(xlDir, "worksheets");
            var relsDir = Path.Combine(tempDir, "_rels");
            var xlRelsDir = Path.Combine(xlDir, "_rels");

            Directory.CreateDirectory(worksheetsDir);
            Directory.CreateDirectory(relsDir);
            Directory.CreateDirectory(xlRelsDir);

            // [Content_Types].xml
            await File.WriteAllTextAsync(Path.Combine(tempDir, "[Content_Types].xml"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n" +
                "    <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n" +
                "    <Default Extension=\"xml\" ContentType=\"application/xml\"/>\n" +
                "    <Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\n" +
                "    <Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n" +
                "    <Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\n" +
                "    <Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>\n" +
                "</Types>");

            // _rels/.rels
            await File.WriteAllTextAsync(Path.Combine(relsDir, ".rels"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "    <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>\n" +
                "</Relationships>");

            // xl/workbook.xml
            await File.WriteAllTextAsync(Path.Combine(xlDir, "workbook.xml"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n" +
                "    <sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets>\n" +
                "</workbook>");

            // xl/_rels/workbook.xml.rels
            await File.WriteAllTextAsync(Path.Combine(xlRelsDir, "workbook.xml.rels"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "    <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>\n" +
                "    <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n" +
                "    <Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>\n" +
                "</Relationships>");

            // xl/styles.xml
            await File.WriteAllTextAsync(Path.Combine(xlDir, "styles.xml"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n" +
                "    <fonts count=\"2\">\n" +
                "        <font><sz val=\"11\"/><name val=\"Arial\"/></font>\n" +
                "        <font><b/><sz val=\"11\"/><name val=\"Arial\"/></font>\n" +
                "    </fonts>\n" +
                "    <fills count=\"2\">\n" +
                "        <fill><patternFill patternType=\"none\"/></fill>\n" +
                "        <fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF4472C4\"/></patternFill></fill>\n" +
                "    </fills>\n" +
                "    <borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\n" +
                "    <cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>\n" +
                "    <cellXfs count=\"3\">\n" +
                "        <xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>\n" +
                "        <xf numFmtId=\"0\" fontId=\"1\" fillId=\"1\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/>\n" +
                "        <xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>\n" +
                "    </cellXfs>\n" +
                "</styleSheet>");

            // Build shared strings
            var sharedStrings = new HashSet<string>();
            sharedStrings.UnionWith(headersList);
            foreach (var item in dataList)
            {
                sharedStrings.Add(item.ReqType);
                sharedStrings.Add(item.ReqId);
                sharedStrings.Add(item.ReqName);
                sharedStrings.Add(item.UserDevelop);
                sharedStrings.Add(item.UserTest);
                sharedStrings.Add(item.ModifySystem);
                sharedStrings.Add(item.Progress);
                sharedStrings.Add(item.ScheduleLaunchDate);
                sharedStrings.Add(item.Remark);
            }

            var sortedStrings = sharedStrings.OrderBy(s => s).ToList();
            var sharedStringsXml = new StringBuilder();
            sharedStringsXml.AppendLine("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
            sharedStringsXml.AppendLine($"<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"{sortedStrings.Count}\" uniqueCount=\"{sortedStrings.Count}\">");
            foreach (var str in sortedStrings)
            {
                sharedStringsXml.AppendLine($"<si><t>{EscapeXml(str)}</t></si>");
            }
            sharedStringsXml.AppendLine("</sst>");
            await File.WriteAllTextAsync(Path.Combine(xlDir, "sharedStrings.xml"), sharedStringsXml.ToString());

            // Build string index map
            var stringIndexMap = new Dictionary<string, int>();
            for (int i = 0; i < sortedStrings.Count; i++)
                stringIndexMap[sortedStrings[i]] = i;

            // xl/worksheets/sheet1.xml
            var sheetXml = new StringBuilder();
            sheetXml.AppendLine("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
            sheetXml.AppendLine("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">");
            sheetXml.AppendLine("    <sheetData>");

            // Header row
            sheetXml.AppendLine("    <row r=\"1\" spans=\"1:9\">");
            for (int i = 0; i < headers.Length; i++)
            {
                var colLetter = LetterForColumn(i + 1);
                var strIdx = stringIndexMap.GetValueOrDefault(headers[i], 0);
                sheetXml.AppendLine($"        <c r=\"{colLetter}1\" s=\"1\" t=\"s\"><v>{strIdx}</v></c>");
            }
            sheetXml.AppendLine("    </row>");

            // Data rows
            for (int rowIdx = 0; rowIdx < dataList.Count; rowIdx++)
            {
                var row = rowIdx + 2;
                var item = dataList[rowIdx];
                sheetXml.AppendLine($"    <row r=\"{row}\" spans=\"1:9\">");
                sheetXml.AppendLine(CreateSSCell(1, row, item.ReqType, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(2, row, item.ReqId, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(3, row, item.ReqName, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(4, row, item.UserDevelop, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(5, row, item.UserTest, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(6, row, item.ModifySystem, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(7, row, item.Progress, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(8, row, item.ScheduleLaunchDate, stringIndexMap));
                sheetXml.AppendLine(CreateSSCell(9, row, item.Remark, stringIndexMap));
                sheetXml.AppendLine("    </row>");
            }

            sheetXml.AppendLine("    </sheetData>");
            sheetXml.AppendLine("</worksheet>");
            await File.WriteAllTextAsync(Path.Combine(worksheetsDir, "sheet1.xml"), sheetXml.ToString());

            // Create zip
            if (File.Exists(outputPath))
                File.Delete(outputPath);
            ZipFile.CreateFromDirectory(tempDir, outputPath);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, true); } catch { }
            }
        }
    }

    private static readonly string[] headers = { "需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注" };
    private static readonly string[] headersList = { "需求类型", "需求号", "需求名称", "需求提出人", "用户测试", "涉及改造系统", "进度", "排期上线日期", "备注" };

    // MARK: - Helper Methods

    private static string LetterForColumn(int col)
    {
        var letter = "";
        while (col > 0)
        {
            var remainder = (col - 1) % 26;
            letter = (char)('A' + remainder) + letter;
            col = (col - 1) / 26;
        }
        return letter;
    }

    private static string EscapeXml(string s)
    {
        return s
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;")
            .Replace("'", "&apos;");
    }

    private static string CreateInlineCell(int col, int row, string value, int style)
    {
        var colLetter = LetterForColumn(col);
        return $"        <c r=\"{colLetter}{row}\" s=\"{style}\" t=\"inlineStr\"><is><t>{EscapeXml(value)}</t></is></c>\n";
    }

    private static string CreateSSCell(int col, int row, string value, Dictionary<string, int> stringIndexMap)
    {
        var colLetter = LetterForColumn(col);
        var strIdx = stringIndexMap.GetValueOrDefault(value, 0);
        return $"        <c r=\"{colLetter}{row}\" t=\"s\"><v>{strIdx}</v></c>";
    }
}
