import Foundation

class VersionManager {
    static let shared = VersionManager()
    
    private let versionFileURL: URL
    private let dateFormatter: DateFormatter
    
    private init() {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = documentsDirectory.appendingPathComponent("JiraMacTool", isDirectory: true)
        
        // 创建应用目录（如果不存在）
        if !fileManager.fileExists(atPath: appDirectory.path) {
            try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        
        versionFileURL = appDirectory.appendingPathComponent("version.txt")
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
    }
    
    /// 获取当前版本号
    func getCurrentVersion() -> String {
        let today = dateFormatter.string(from: Date())
        
        // 读取版本文件
        if let content = try? String(contentsOf: versionFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            // 检查今天的版本记录
            for line in lines.reversed() {
                let parts = line.components(separatedBy: ",")
                if parts.count == 2, parts[0] == today {
                    return parts[1]
                }
            }
        }
        
        // 如果没有今天的版本，生成新的版本号
        return generateNewVersion(for: today)
    }
    
    /// 生成新的版本号
    private func generateNewVersion(for date: String) -> String {
        let newVersion = "\(date)-01"
        saveVersion(date: date, version: newVersion)
        return newVersion
    }
    
    /// 递增版本号
    @discardableResult
    func incrementVersion() -> String {
        let today = dateFormatter.string(from: Date())
        
        if let content = try? String(contentsOf: versionFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            // 查找今天的最后一个版本
            for line in lines.reversed() {
                let parts = line.components(separatedBy: ",")
                if parts.count == 2, parts[0] == today {
                    let currentVersion = parts[1]
                    let versionParts = currentVersion.components(separatedBy: "-")
                    if versionParts.count == 2, let currentSeq = Int(versionParts[1]) {
                        let newSeq = currentSeq + 1
                        let newVersion = String(format: "%@-%02d", today, newSeq)
                        saveVersion(date: today, version: newVersion)
                        return newVersion
                    }
                }
            }
        }
        
        // 如果没有今天的版本，创建第一个版本
        return generateNewVersion(for: today)
    }
    
    /// 保存版本信息
    private func saveVersion(date: String, version: String) {
        var content = ""
        if let existingContent = try? String(contentsOf: versionFileURL, encoding: .utf8) {
            content = existingContent
        }
        
        // 检查是否已有今天的记录
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var updatedLines: [String] = []
        var dateFound = false
        
        for line in lines {
            let parts = line.components(separatedBy: ",")
            if parts.count == 2, parts[0] == date {
                updatedLines.append("\(date),\(version)")
                dateFound = true
            } else {
                updatedLines.append(line)
            }
        }
        
        if !dateFound {
            updatedLines.append("\(date),\(version)")
        }
        
        let newContent = updatedLines.joined(separator: "\n")
        try? newContent.write(to: versionFileURL, atomically: true, encoding: .utf8)
    }
}