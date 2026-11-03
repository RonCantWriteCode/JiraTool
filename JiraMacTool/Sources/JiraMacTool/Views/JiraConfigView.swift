import SwiftUI

struct JiraConfigView: View {
    @StateObject private var config = AppConfig.shared
    @State private var testResult = ""
    @State private var isTesting = false
    @State private var isLoggingIn = false
    @State private var isLoggingOut = false
    @State private var saveResult = ""
    @State private var passwordInput = ""
    @State private var showPassword = false
    @State private var sessionValid = false
    @State private var sessionUser: String?
    @State private var sessionLoginTime: Date?

    private var effectivePassword: String {
        passwordInput.isEmpty ? config.jiraPassword : passwordInput
    }

    var body: some View {
        Form {
            Section(header: Text("Jira 服务器配置")) {
                TextField("Jira URL", text: $config.jiraURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                TextField("用户名", text: $config.jiraUser)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                HStack {
                    if showPassword {
                        TextField("密码", text: $passwordInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        SecureField("密码", text: $passwordInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .onSubmit {
                    config.savePassword(passwordInput)
                    saveResult = "✅ 密码已保存"
                }
            }

            // MARK: - 会话状态
            Section(header: Text("会话状态")) {
                HStack {
                    Circle()
                        .fill(sessionValid ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(sessionValid ? "已登录" : "未登录")
                        .fontWeight(.medium)
                    Spacer()
                    if sessionValid, let user = sessionUser {
                        Text(user)
                            .foregroundColor(.secondary)
                    }
                }

                if sessionValid, let loginTime = sessionLoginTime {
                    HStack {
                        Text("登录时间:")
                        Spacer()
                        Text(formatDate(loginTime))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("过期时间:")
                        Spacer()
                        Text(formatDate(loginTime.addingTimeInterval(7 * 24 * 60 * 60)))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(action: {
                        Task {
                            isLoggingIn = true
                            defer { isLoggingIn = false }
                            print("[JiraConfig] 登录按钮被点击")
                            if !passwordInput.isEmpty {
                                config.savePassword(passwordInput)
                                print("[JiraConfig] 密码已保存")
                            }
                            guard !config.jiraPassword.isEmpty else {
                                print("[JiraConfig] 密码为空，中止登录")
                                testResult = "❌ 密码不能为空，请先输入密码"
                                return
                            }
                            print("[JiraConfig] 开始调用 JiraService.login(), user=\(config.jiraUser)")
                            testResult = "⏳ 正在连接服务器..."
                            do {
                                let displayName = try await JiraService.shared.login()
                                print("[JiraConfig] 登录成功: \(displayName)")
                                testResult = "✅ 登录成功！用户: \(displayName)"
                                await refreshSessionStatus()
                            } catch {
                                print("[JiraConfig] 登录失败: \(error.localizedDescription)")
                                testResult = "❌ 登录失败: \(error.localizedDescription)"
                                await refreshSessionStatus()
                            }
                        }
                    }) {
                        Text(isLoggingIn ? "登录中..." : "登录")
                    }
                    .disabled(isLoggingIn || isLoggingOut)

                    if sessionValid {
                        Button(action: {
                            Task {
                                isLoggingOut = true
                                defer { isLoggingOut = false }
                                await JiraService.shared.logout()
                                testResult = "✅ 已登出"
                                await refreshSessionStatus()
                            }
                        }) {
                            Text(isLoggingOut ? "登出中..." : "登出")
                        }
                        .disabled(isLoggingIn || isLoggingOut)
                    }
                }

                if !testResult.isEmpty {
                    Text(testResult)
                        .foregroundColor(testResult.hasPrefix("✅") ? .green : .red)
                }
            }

            Section(header: Text("快捷操作")) {
                HStack(spacing: 12) {
                    Button(action: {
                        config.savePassword(passwordInput)
                        saveResult = "✅ 密码已保存"
                    }) {
                        Text("保存密码")
                    }

                    Button(action: {
                        Task {
                            isTesting = true
                            defer { isTesting = false }
                            if !passwordInput.isEmpty {
                                config.savePassword(passwordInput)
                            }
                            guard !config.jiraPassword.isEmpty else {
                                testResult = "❌ 密码不能为空，请先输入密码并点击保存"
                                return
                            }
                            do {
                                let displayName = try await JiraService.shared.testConnection()
                                testResult = "✅ 连接成功！用户: \(displayName)"
                                await refreshSessionStatus()
                            } catch let error as JiraError {
                                testResult = "❌ \(error.localizedDescription)"
                            } catch {
                                testResult = "❌ 连接失败: \(error.localizedDescription)"
                            }
                        }
                    }) {
                        Text(isTesting ? "测试中..." : "测试连接")
                    }
                    .disabled(isTesting)
                }

                if !saveResult.isEmpty {
                    Text(saveResult)
                        .foregroundColor(.green)
                }
            }

            Section(header: Text("当前配置")) {
                HStack {
                    Text("URL:")
                    Spacer()
                    Text(config.jiraURL)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("用户:")
                    Spacer()
                    Text(config.jiraUser)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("密码:")
                    Spacer()
                    if effectivePassword.isEmpty {
                        Text("未设置")
                            .foregroundColor(.red)
                    } else {
                        Text(effectivePassword)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 450)
        .navigationTitle("Jira 配置")
        .task {
            await refreshSessionStatus()
        }
    }

    private func refreshSessionStatus() async {
        let info = await JiraService.shared.sessionInfo
        sessionValid = info.isValid
        sessionUser = info.user
        sessionLoginTime = info.loginTime
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
