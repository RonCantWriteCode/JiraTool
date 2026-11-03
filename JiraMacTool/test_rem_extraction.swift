import Foundation

class TestREMExtractor {
    static func test() {
        let html = "<label class=\"auditNote\" style=\"white-space:pre-wrap\"> 已登记REM-1861，涉及到理赔接口，烦请转办理赔开发科室登记REQ。</label>"
        
        // 兰凌 EKP 审批意见在 <label class="auditNote">...</label> 或 <label class="xxx auditNote xxx">...</label>
        // 使用最宽松的正则，匹配任意属性顺序和引号类型
        let auditPattern = #"(?is)<label[^>]*class=["'].*?auditNote.*?['"][^>]*>([\s\S]*?)</label>"#
        guard let regex = try? NSRegularExpression(pattern: auditPattern) else {
            print("auditPattern 编译失败")
            return
        }
        
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: html, options: [], range: range)
        
        print("auditPattern 匹配结果数量: \(matches.count)")
        for (i, match) in matches.enumerated() {
            let auditContent = ns.substring(with: match.range(at: 1))
            print("匹配 \(i+1): \(auditContent)")
        }
        
        if matches.isEmpty {
            print("auditPattern 没有匹配到任何内容")
            return
        }
        
        // REM 提取逻辑
        let remPattern = "REM-?\\d{3,}"
        guard let remRegex = try? NSRegularExpression(pattern: remPattern, options: .caseInsensitive) else {
            print("remPattern 编译失败")
            return
        }
        
        var result: [String] = []
        var seen = Set<String>()
        
        for match in matches {
            let auditContent = ns.substring(with: match.range(at: 1))
            let remMatches = remRegex.matches(in: auditContent, options: [], range: NSRange(location: 0, length: (auditContent as NSString).length))
            
            print("auditContent 中 REM 匹配数量: \(remMatches.count)")
            for m in remMatches {
                var key = (auditContent as NSString).substring(with: m.range).uppercased()
                print("  REM 原始: \(key)")
                
                if !key.contains("-") {
                    if let digits = key.range(of: "\\d+", options: .regularExpression) {
                        key = "REM-" + String(key[digits])
                        print("  REM 标准化: \(key)")
                    }
                }
                
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(key)
                }
            }
        }
        
        print("最终结果: \(result)")
    }
}

TestREMExtractor.test()