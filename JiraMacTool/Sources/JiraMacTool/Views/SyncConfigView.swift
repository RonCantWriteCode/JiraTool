import SwiftUI

struct SyncConfigView: View {
    @ObservedObject private var config = AppConfig.shared

    @State private var webdavURL: String = ""
    @State private var webdavUser: String = ""
    @State private var webdavPassword: String = ""
    @State private var webdavRemotePath: String = ""
    @State private var autoSyncEnabled: Bool = false
    @State private var autoSyncInterval: Int = 30
    @State private var testMessage: String = ""
    @State private var isTesting = false
    @State private var saveMessage: String = ""

    var body: some View {
        Form {
            Section(header: Text("WebDAV 连接")) {
                TextField("WebDAV 地址", text: $webdavURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                TextField("用户名", text: $webdavUser)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                SecureField("密码", text: $webdavPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                TextField("远程路径", text: $webdavRemotePath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            Section(header: Text("自动同步")) {
                Toggle("启用自动同步", isOn: $autoSyncEnabled)

                if autoSyncEnabled {
                    Picker("同步频率", selection: $autoSyncInterval) {
                        ForEach(AppConfig.syncIntervalOptions, id: \.minutes) { option in
                            Text(option.label).tag(option.minutes)
                        }
                    }
                    .pickerStyle(.menu)

                    if let lastSync = config.lastSyncTime {
                        HStack {
                            Text("上次同步:")
                                .foregroundColor(.secondary)
                            Text(formatDate(lastSync))
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            Section(header: Text("操作")) {
                HStack(spacing: 12) {
                    Button(isTesting ? "测试中..." : "测试连接") {
                        testConnection()
                    }
                    .disabled(isTesting || webdavURL.isEmpty || webdavUser.isEmpty || webdavPassword.isEmpty)

                    Spacer()

                    Button("保存") {
                        saveConfig()
                    }
                    .disabled(webdavURL.isEmpty)
                }
            }

            if !testMessage.isEmpty {
                Text(testMessage)
                    .foregroundColor(testMessage.contains("✅") ? .green : .red)
                    .font(.caption)
            }

            if !saveMessage.isEmpty {
                Text(saveMessage)
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 350)
        .navigationTitle("同步配置")
        .onAppear {
            webdavURL = config.webdavURL
            webdavUser = config.webdavUser
            webdavPassword = config.webdavPassword
            webdavRemotePath = config.webdavRemotePath
            autoSyncEnabled = config.autoSyncEnabled
            autoSyncInterval = config.autoSyncInterval
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private func saveConfig() {
        config.webdavURL = webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.webdavUser = webdavUser.trimmingCharacters(in: .whitespacesAndNewlines)
        config.webdavRemotePath = webdavRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        config.saveWebdavPassword(webdavPassword)
        config.autoSyncEnabled = autoSyncEnabled
        config.autoSyncInterval = autoSyncInterval
        saveMessage = "✅ 配置已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveMessage = ""
        }
    }

    private func testConnection() {
        config.webdavURL = webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.webdavUser = webdavUser.trimmingCharacters(in: .whitespacesAndNewlines)
        config.webdavRemotePath = webdavRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        config.saveWebdavPassword(webdavPassword)

        isTesting = true
        testMessage = ""
        Task {
            do {
                let msg = try await WebDavService.shared.testConnection()
                await MainActor.run {
                    testMessage = msg
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testMessage = "❌ \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
