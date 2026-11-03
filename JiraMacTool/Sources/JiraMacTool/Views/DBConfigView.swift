import SwiftUI
import AppKit

struct DBConfigView: View {
    @ObservedObject private var config = AppConfig.shared

    @State private var customPath: String = ""
    @State private var currentPath: String = ""
    @State private var message: String = ""

    var body: some View {
        Form {
            Section(header: Text("当前路径")) {
                Text(currentPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Section(header: Text("自定义路径")) {
                HStack {
                    TextField("数据库文件路径", text: $customPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Button("选择...") {
                        selectFolder()
                    }
                }

                HStack(spacing: 12) {
                    Button("应用（仅切换）") {
                        applyPath(migrate: false)
                    }
                    .disabled(customPath.isEmpty || customPath == currentPath)

                    Button("迁移并应用") {
                        applyPath(migrate: true)
                    }
                    .disabled(customPath.isEmpty || customPath == currentPath)

                    Button("恢复默认") {
                        restoreDefault()
                    }
                }
            }

            if !message.isEmpty {
                Text(message)
                    .foregroundColor(message.contains("✅") ? .green : .red)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 250)
        .navigationTitle("数据库配置")
        .onAppear {
            currentPath = FavoriteDBService.shared.getCurrentPath()
            if !config.dbPath.isEmpty {
                customPath = config.dbPath
            }
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.appendingPathComponent("jira_favorites.sqlite").path
        }
    }

    private func applyPath(migrate: Bool) {
        let url = URL(fileURLWithPath: customPath)
        config.dbPath = customPath
        message = FavoriteDBService.shared.setCustomPath(url, migrateData: migrate)
        currentPath = FavoriteDBService.shared.getCurrentPath()
    }

    private func restoreDefault() {
        customPath = ""
        config.dbPath = ""
        message = FavoriteDBService.shared.setCustomPath(nil, migrateData: false)
        currentPath = FavoriteDBService.shared.getCurrentPath()
    }
}
