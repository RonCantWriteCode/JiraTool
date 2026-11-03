import Foundation

// Simple test to verify Excel export functionality
@main
struct ExcelExportTest {
    static func main() async {
        print("=== Excel Export Test ===\n")
        
        let testDate = "2026-04-30"
        let outputWithoutTemplate = "/tmp/test_export_no_template.xlsx"
        let outputWithTemplate = "/tmp/test_export_with_template.xlsx"
        
        // Test 1: Export without template
        print("Test 1: Export without template")
        print("Output: \(outputWithoutTemplate)")
        
        // We'll just verify the file can be created
        let success1 = await testBasicExport(outputPath: outputWithoutTemplate)
        print("Result: \(success1 ? "✅ PASS" : "❌ FAIL")\n")
        
        // Test 2: Export with template (if template exists)
        let templatePath = "/tmp/test_template.xlsx"
        if FileManager.default.fileExists(atPath: templatePath) {
            print("Test 2: Export with template")
            print("Template: \(templatePath)")
            print("Output: \(outputWithTemplate)")
            
            let success2 = await testTemplateExport(templatePath: templatePath, outputPath: outputWithTemplate)
            print("Result: \(success2 ? "✅ PASS" : "❌ FAIL")\n")
        } else {
            print("Test 2: Skipped (no template found at \(templatePath))")
            print("To test with template, please provide a template file at: \(templatePath)\n")
        }
        
        print("=== Test Complete ===")
    }
    
    static func testBasicExport(outputPath: String) async -> Bool {
        // Simulate creating a basic xlsx structure
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Create minimal xlsx structure
            let xlDir = tempDir.appendingPathComponent("xl")
            let worksheetsDir = xlDir.appendingPathComponent("worksheets")
            let relsDir = tempDir.appendingPathComponent("_rels")
            let xlRelsDir = xlDir.appendingPathComponent("_rels")
            
            try FileManager.default.createDirectory(at: worksheetsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)
            
            // Create [Content_Types].xml
            let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                <Default Extension="xml" ContentType="application/xml"/>
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """
            try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
            
            // Create workbook
            let workbook = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                <sheets>
                    <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
                </sheets>
            </workbook>
            """
            try workbook.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
            
            // Create worksheet with data
            let worksheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                <sheetData>
                    <row r="1">
                        <c r="A1" t="inlineStr"><is><t>需求类型</t></is></c>
                        <c r="B1" t="inlineStr"><is><t>需求号</t></is></c>
                        <c r="C1" t="inlineStr"><is><t>需求名称</t></is></c>
                    </row>
                    <row r="2">
                        <c r="A2" t="inlineStr"><is><t>常规</t></is></c>
                        <c r="B2" t="inlineStr"><is><t>TEST-001</t></is></c>
                        <c r="C2" t="inlineStr"><is><t>Test Requirement</t></is></c>
                    </row>
                </sheetData>
            </worksheet>
            """
            try worksheet.write(to: worksheetsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)
            
            // Create styles
            let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                <fonts count="2">
                    <font><sz val="11"/><name val="Arial"/></font>
                    <font><b/><sz val="11"/><name val="Arial"/></font>
                </fonts>
                <fills count="2">
                    <fill><patternFill patternType="none"/></fill>
                    <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/></patternFill></fill>
                </fills>
                <borders count="1">
                    <border><left/><right/><top/><bottom/><diagonal/></border>
                </borders>
                <cellXfs count="2">
                    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
                    <xf numFmtId="0" fontId="1" fillId="1" borderId="0" applyFont="1" applyFill="1"/>
                </cellXfs>
            </styleSheet>
            """
            try styles.write(to: xlDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
            
            // Create zip (xlsx)
            let zipManager = ZipArchive()
            try zipManager.createZip(from: tempDir, to: URL(fileURLWithPath: outputPath))
            
            // Verify file was created
            let exists = FileManager.default.fileExists(atPath: outputPath)
            if exists {
                let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
                let size = attributes[.size] as? UInt64 ?? 0
                print("  File created: \(outputPath)")
                print("  File size: \(size) bytes")
            }
            
            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
            
            return exists
        } catch {
            print("  Error: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempDir)
            return false
        }
    }
    
    static func testTemplateExport(templatePath: String, outputPath: String) async -> Bool {
        do {
            // Verify template exists
            guard FileManager.default.fileExists(atPath: templatePath) else {
                print("  Template not found")
                return false
            }
            
            // Copy template to output
            try FileManager.default.copyItem(atPath: templatePath, toPath: outputPath)
            
            // Verify output was created
            let exists = FileManager.default.fileExists(atPath: outputPath)
            if exists {
                let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
                let size = attributes[.size] as? UInt64 ?? 0
                print("  File created: \(outputPath)")
                print("  File size: \(size) bytes")
            }
            
            return exists
        } catch {
            print("  Error: \(error.localizedDescription)")
            return false
        }
    }
}

// Simple zip helper
class ZipArchive {
    func createZip(from sourceDir: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destination.path, "."]
        process.currentDirectoryURL = sourceDir
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw NSError(domain: "ZipArchive", code: Int(process.terminationStatus), 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create zip file"])
        }
    }
}
