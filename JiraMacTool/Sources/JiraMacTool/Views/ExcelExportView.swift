import SwiftUI

struct EmailMappingSheet: View {
    let unknownUsers: [String]
    @Binding var isPresented: Bool
    @State private var emailInputs: [String: String] = [:]
    @State private var showSavedAlert = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text("补充用户邮箱映射")
                .font(.headline)
            
            Text("以下 \(unknownUsers.count) 个用户未找到邮箱映射，请补充：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(unknownUsers, id: \.self) { user in
                        HStack {
                            Button(action: {
                                // Copy user name to clipboard
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(user, forType: .string)
                            }) {
                                Text(user)
                                    .frame(width: 100, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("点击复制: \(user)")
                            
                            TextField("邮箱地址", text: Binding(
                                get: { emailInputs[user] ?? "" },
                                set: { emailInputs[user] = $0 }
                            ))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            HStack(spacing: 16) {
                Button("跳过") {
                    isPresented = false
                }
                
                Button("保存并关闭") {
                    let validMappings = emailInputs.filter { !$0.value.isEmpty }
                    if !validMappings.isEmpty {
                        UserEnum.addDynamicMappings(validMappings)
                        showSavedAlert = true
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct UserMappingManagerSheet: View {
    @Binding var isPresented: Bool
    @State private var allMappings: [(name: String, email: String, isBuiltIn: Bool)] = []
    @State private var emailEdits: [String: String] = [:]
    @State private var searchText = ""
    
    var filteredMappings: [(name: String, email: String, isBuiltIn: Bool)] {
        if searchText.isEmpty {
            return allMappings
        }
        return allMappings.filter {
            $0.name.contains(searchText) || $0.email.contains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("用户邮箱映射管理")
                .font(.headline)
            
            Text("共 \(allMappings.count) 个用户映射（内置 \(allMappings.filter { $0.isBuiltIn }.count) 个，动态 \(allMappings.filter { !$0.isBuiltIn }.count) 个）")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索用户或邮箱...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredMappings, id: \.name) { mapping in
                        HStack(spacing: 12) {
                            Text(mapping.name)
                                .frame(width: 100, alignment: .leading)
                                .lineLimit(1)
                            
                            if mapping.isBuiltIn {
                                Text(mapping.email)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                Text("内置")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(4)
                            } else {
                                TextField("邮箱地址", text: Binding(
                                    get: { emailEdits[mapping.name] ?? mapping.email },
                                    set: { emailEdits[mapping.name] = $0 }
                                ))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(maxWidth: .infinity)
                                
                                Text("动态")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal)
            }
            
            HStack(spacing: 16) {
                Button("关闭") {
                    isPresented = false
                }
                
                Button("保存修改") {
                    // Save all modified dynamic mappings
                    for (name, email) in emailEdits {
                        if let original = allMappings.first(where: { $0.name == name }), !original.isBuiltIn {
                            UserEnum.updateEmail(for: name, email: email)
                        }
                    }
                    // Reload mappings
                    allMappings = UserEnum.getAllMappings()
                    emailEdits = [:]
                }
                .buttonStyle(.borderedProminent)
                .disabled(emailEdits.isEmpty)
            }
            .padding(.bottom)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            allMappings = UserEnum.getAllMappings()
        }
    }
}

struct ExcelExportView: View {
    @State private var beforeDate = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Default to current date + 29 days
        let futureDate = Calendar.current.date(byAdding: .day, value: 29, to: Date()) ?? Date()
        return formatter.string(from: futureDate)
    }()
    @State private var outFilePath = ""
    @AppStorage("excel_template_path") private var templateFilePath = ""
    @State private var logs = ""
    @State private var isLoading = false
    @State private var showEmailMappingSheet = false
    @State private var showUserMappingSheet = false
    @State private var pendingUnknownUsers: [String] = []
    @State private var pendingEmailList: [String] = []
    @State private var lastExportResult: ExcelExportResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("截止日期:")
                TextField("yyyy-MM-dd", text: $beforeDate)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("输出路径:")
                TextField("/Users/xxx/Downloads/版本清单.xlsx", text: $outFilePath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("选择...") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.spreadsheet]
                    panel.nameFieldStringValue = "版本清单\(beforeDate).xlsx"
                    if panel.runModal() == .OK, let url = panel.url {
                        outFilePath = url.path
                    }
                }
            }

            HStack {
                Text("模板路径:")
                TextField("可选（xlsx 模板文件）", text: $templateFilePath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("选择...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.spreadsheet]
                    if panel.runModal() == .OK, let url = panel.url {
                        templateFilePath = url.path
                    }
                }
            }

            HStack {
                Button(action: {
                    Task {
                        isLoading = true
                        defer { isLoading = false }
                        let path = outFilePath.isEmpty ? "/Users/\(NSUserName())/Downloads/版本清单\(beforeDate).xlsx" : outFilePath
                        let result = await ExcelService.shared.exportExcel(beforeDate: beforeDate, outFilePath: path, templateFilePath: templateFilePath, sheetName: "1")
                        logs = result.log
                        pendingUnknownUsers = result.unknownUsers
                        pendingEmailList = result.emailList
                        lastExportResult = result
                        
                        // Show email mapping sheet if there are unknown users
                        if !result.unknownUsers.isEmpty {
                            showEmailMappingSheet = true
                        }
                    }
                }) {
                    Text(isLoading ? "导出中..." : "导出")
                }
                .disabled(isLoading || beforeDate.isEmpty)

                Button(action: {
                    Task {
                        isLoading = true
                        defer { isLoading = false }
                        let path = outFilePath.isEmpty ? "/Users/\(NSUserName())/Downloads/版本清单\(beforeDate).xlsx" : outFilePath
                        let result = await ExcelService.shared.exportExcel(beforeDate: beforeDate, outFilePath: path, templateFilePath: templateFilePath, sheetName: "1")
                        logs = result.log
                        pendingUnknownUsers = result.unknownUsers
                        pendingEmailList = result.emailList
                        lastExportResult = result
                        
                        // Show email mapping sheet if there are unknown users
                        if !result.unknownUsers.isEmpty {
                            showEmailMappingSheet = true
                        }
                        
                        // Generate EML file
                        if !result.dataList.isEmpty {
                            let emlPath = path.replacingOccurrences(of: ".xlsx", with: ".eml")
                            do {
                                try EmailService.generateEML(
                                    toEmails: result.emailList,
                                    dataList: result.dataList,
                                    noticeContent: result.noticeContent,
                                    outputPath: emlPath
                                )
                                logs += "\n\n已生成邮件文件: \(emlPath)"
                                
                                // Open the EML file with default mail client
                                let workspace = NSWorkspace.shared
                                let fileURL = URL(fileURLWithPath: emlPath)
                                if workspace.open(fileURL) {
                                    logs += "\n已自动打开邮件文件"
                                } else {
                                    logs += "\n⚠️ 无法自动打开邮件文件，请手动双击打开"
                                }
                            } catch {
                                logs += "\n\n生成邮件失败: \(error.localizedDescription)"
                            }
                        }
                    }
                }) {
                    Text(isLoading ? "生成中..." : "导出并生成邮件")
                }
                .disabled(isLoading || beforeDate.isEmpty)

                Button("清空日志") {
                    logs = ""
                }

                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs, forType: .string)
                }

                Button("修改用户映射") {
                    showUserMappingSheet = true
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
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Excel 导出")
        .sheet(isPresented: $showEmailMappingSheet) {
            EmailMappingSheet(unknownUsers: pendingUnknownUsers, isPresented: $showEmailMappingSheet)
        }
        .sheet(isPresented: $showUserMappingSheet) {
            UserMappingManagerSheet(isPresented: $showUserMappingSheet)
        }
    }
}
