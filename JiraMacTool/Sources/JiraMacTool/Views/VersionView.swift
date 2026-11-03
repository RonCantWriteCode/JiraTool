import SwiftUI

struct VersionView: View {
    @State private var date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var isUrgent = false
    @State private var selectedSystems: Set<SystemEnum> = []
    @State private var deleteVersionName = ""
    @State private var logs = ""
    @State private var isLoading = false
    @State private var selectedTab = 0
    @State private var showDateManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("模式", selection: $selectedTab) {
                Text("创建版本号").tag(0)
                Text("删除版本号").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())

            if selectedTab == 0 {
                HStack {
                    Text("日期:")
                    TextField("yyyy-MM-dd", text: $date)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                Toggle("紧急版本", isOn: $isUrgent)

                Text("选择系统:")
                    .font(.headline)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                        ForEach(SystemEnum.allCases) { system in
                            Toggle(system.systemName, isOn: Binding(
                                get: { selectedSystems.contains(system) },
                                set: { isOn in
                                    if isOn {
                                        selectedSystems.insert(system)
                                    } else {
                                        selectedSystems.remove(system)
                                    }
                                }
                            ))
                        }
                    }
                }
                .frame(height: 200)

                HStack {
                    Button("全选") {
                        selectedSystems = Set(SystemEnum.allCases)
                    }
                    Button("清空") {
                        selectedSystems.removeAll()
                    }
                }
                
                Divider()
                
                HStack {
                    Text("批量创建常规版本:")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button("常规版本日期管理") {
                        showDateManager = true
                    }
                }
                
                Button("批量创建") {
                    Task {
                        isLoading = true
                        defer { isLoading = false }
                        let dates = RegularVersionDateStore.shared.dates
                        if dates.isEmpty {
                            logs = "⚠️ 常规版本日期列表为空，请先在「常规版本日期管理」中添加日期"
                            return
                        }
                        var allLogs = ""
                        for date in dates {
                            allLogs += await VersionService.shared.createVersion(date: date, systems: Array(selectedSystems), isUrgent: false)
                            allLogs += "\n"
                        }
                        logs = allLogs
                    }
                }
                .disabled(selectedSystems.isEmpty)
            } else {
                HStack {
                    Text("版本号名称:")
                    TextField("如: CLM_V10_26.4.21", text: $deleteVersionName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }

            HStack {
                Button(action: {
                    Task {
                        isLoading = true
                        defer { isLoading = false }
                        if selectedTab == 0 {
                            logs = await VersionService.shared.createVersion(date: date, systems: Array(selectedSystems), isUrgent: isUrgent)
                        } else {
                            logs = await VersionService.shared.deleteVersion(versionName: deleteVersionName)
                        }
                    }
                }) {
                    Text(isLoading ? "执行中..." : "执行")
                }
                .disabled(isLoading || !canExecute)

                Button("清空日志") {
                    logs = ""
                }

                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs, forType: .string)
                }
            }

            ScrollView {
                Text(logs)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .border(Color.gray.opacity(0.3), width: 1)

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 550)
        .navigationTitle("版本管理")
        .sheet(isPresented: $showDateManager) {
            RegularVersionDateManagerSheet()
        }
    }

    private var canExecute: Bool {
        if selectedTab == 0 {
            return !date.isEmpty && !selectedSystems.isEmpty
        } else {
            return !deleteVersionName.isEmpty
        }
    }
}

// MARK: - 常规版本日期持久化存储

class RegularVersionDateStore: ObservableObject {
    static let shared = RegularVersionDateStore()
    
    private static let storageKey = "regularVersionDates"
    
    @Published var dates: [String]
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey), !saved.isEmpty {
            dates = saved.split(separator: "\n").map(String.init).sorted()
        } else {
            // 默认使用 PublishConstants 中的数据初始化
            dates = (PublishConstants.changguiVersion2025_34 + PublishConstants.changguiVersion2026_12).sorted()
        }
    }
    
    func addDate(_ date: String) {
        guard !dates.contains(date) else { return }
        dates.append(date)
        persistSorted()
    }
    
    func removeDate(_ date: String) {
        dates.removeAll { $0 == date }
        persistSorted()
    }
    
    func removeExpiredDates() {
        dates.removeAll { Self.isDatePast($0) }
        persistSorted()
    }
    
    func replaceAll(with newDates: [String]) {
        dates = newDates.sorted()
        persist()
    }
    
    func appendAll(_ newDates: [String]) {
        let existing = Set(dates)
        let toAdd = newDates.filter { !existing.contains($0) }
        dates.append(contentsOf: toAdd)
        persistSorted()
    }
    
    private func persistSorted() {
        dates.sort()
        persist()
    }
    
    private func persist() {
        let joined = dates.joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: Self.storageKey)
    }
    
    fileprivate static func isDatePast(_ str: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: str) else { return false }
        return date < Calendar.current.startOfDay(for: Date())
    }
}

// MARK: - 常规版本日期管理弹窗

struct RegularVersionDateManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RegularVersionDateStore.shared
    @State private var importText = ""
    @State private var newDate = ""
    @State private var showImport = false
    @State private var statusMessage = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题栏
            HStack {
                Text("常规版本日期管理")
                    .font(.title2).bold()
                Spacer()
                Text("共 \(store.dates.count) 个日期")
                    .foregroundColor(.secondary)
            }
            
            // 日期列表
            List {
                ForEach(store.dates, id: \.self) { date in
                    HStack {
                        Text(date)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        // 判断是否已过期
                        if isDatePast(date) {
                            Text("已过期")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button(action: {
                            store.removeDate(date)
                            statusMessage = "已删除: \(date)"
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            }
            .frame(minHeight: 250)
            
            Divider()
            
            // 新增单个日期
            HStack {
                TextField("新增日期 yyyy-MM-dd", text: $newDate)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
                Button("添加") {
                    addSingleDate()
                }
                .disabled(newDate.isEmpty)
            }
            
            // 导入区域（可折叠）
            DisclosureGroup("批量导入", isExpanded: $showImport) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每行一个日期，格式 yyyy-MM-dd")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $importText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                        .border(Color.gray.opacity(0.3))
                    HStack {
                        Button("追加导入") {
                            importDates(replace: false)
                        }
                        Button("替换导入") {
                            importDates(replace: true)
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            
            // 状态消息
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            Divider()
            
            // 底部操作
            HStack {
                Button("导出到剪贴板") {
                    let text = store.dates.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    statusMessage = "已复制 \(store.dates.count) 个日期到剪贴板"
                }
                
                Button("清除已过期") {
                    let before = store.dates.count
                    store.removeExpiredDates()
                    let removed = before - store.dates.count
                    statusMessage = "已清除 \(removed) 个过期日期"
                }
                
                Spacer()
                
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 500)
    }
    
    private func addSingleDate() {
        let trimmed = newDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDate(trimmed) else {
            statusMessage = "⚠️ 日期格式不正确: \(trimmed)，请使用 yyyy-MM-dd"
            return
        }
        if store.dates.contains(trimmed) {
            statusMessage = "⚠️ 日期已存在: \(trimmed)"
            return
        }
        store.addDate(trimmed)
        newDate = ""
        statusMessage = "已添加: \(trimmed)"
    }
    
    private func importDates(replace: Bool) {
        let lines = importText.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var valid: [String] = []
        var invalid: [String] = []
        for line in lines {
            if isValidDate(line) {
                valid.append(line)
            } else {
                invalid.append(line)
            }
        }
        
        if replace {
            store.replaceAll(with: valid)
        } else {
            store.appendAll(valid)
        }
        
        if invalid.isEmpty {
            statusMessage = "已\(replace ? "替换" : "追加")导入 \(valid.count) 个日期"
        } else {
            statusMessage = "已导入 \(valid.count) 个，\(invalid.count) 个格式无效: \(invalid.joined(separator: ", "))"
        }
        importText = ""
    }
    
    private func isValidDate(_ str: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: str) != nil
    }
    
    private func isDatePast(_ str: String) -> Bool {
        RegularVersionDateStore.isDatePast(str)
    }
}
