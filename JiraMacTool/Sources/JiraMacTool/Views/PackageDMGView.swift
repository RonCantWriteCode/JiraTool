import SwiftUI
import AppKit

struct PackageDMGView: View {
    @State private var projectPath: String = ""
    @State private var isBuilding = false
    @State private var logs = ""
    @State private var dmgOutputPath: String? = nil
    @State private var buildSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 项目路径
            HStack {
                Text("项目路径:")
                    .frame(width: 70, alignment: .trailing)
                TextField("项目根目录", text: $projectPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("浏览...") {
                    selectProjectPath()
                }
                .disabled(isBuilding)
            }

            // 操作按钮
            HStack(spacing: 10) {
                Button(action: startBuild) {
                    HStack {
                        if isBuilding {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "shippingbox.fill")
                        }
                        Text(isBuilding ? "打包中..." : "开始打包 DMG")
                    }
                }
                .disabled(isBuilding || projectPath.isEmpty)
                .buttonStyle(.borderedProminent)

                Button("清空日志") {
                    logs = ""
                    dmgOutputPath = nil
                    buildSucceeded = false
                }
                .disabled(isBuilding)

                if let dmgPath = dmgOutputPath {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(dmgPath, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // 结果状态
            if buildSucceeded, let dmgPath = dmgOutputPath {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("DMG 已生成: \(dmgPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(dmgPath, forType: .string)
                    }) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("复制路径")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            }

            // 日志输出
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logs.isEmpty ? "日志将在此处显示..." : logs)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logBottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(Color.gray.opacity(0.3), width: 1)
                .onChange(of: logs) { _ in
                    withAnimation {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 550, minHeight: 500)
        .navigationTitle("打包 DMG")
        }

    // MARK: - 检测项目路径

    private func detectProjectPath() -> String {
        // 先尝试从 app bundle 同级目录找 build_dmg.sh
        let appDir = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: appDir.appendingPathComponent("build_dmg.sh").path
        ) {
            return appDir.path
        }
        // 再尝试从可执行文件路径推断（swift run 开发模式）
        if let execPath = Bundle.main.executablePath {
            var url = URL(fileURLWithPath: execPath)
            for _ in 0..<6 {
                url = url.deletingLastPathComponent()
                let candidate = url.appendingPathComponent("build_dmg.sh")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return url.path
                }
            }
        }
        return ""
    }

    // MARK: - 选择项目路径

    private func selectProjectPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 build_dmg.sh 的项目根目录"
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }

    // MARK: - 执行打包

    private func startBuild() {
        let scriptPath = (projectPath as NSString).appendingPathComponent("build_dmg.sh")
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logs = "❌ 找不到 build_dmg.sh，请确认项目路径正确:\n\(scriptPath)"
            return
        }

        isBuilding = true
        buildSucceeded = false
        dmgOutputPath = nil
        logs = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptPath]
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            process.standardOutput = pipe
            process.standardError = pipe

            var collectedOutput = ""

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                collectedOutput += str
                DispatchQueue.main.async {
                    logs += str
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    logs += "\n❌ 启动进程失败: \(error.localizedDescription)"
                    isBuilding = false
                }
                return
            }

            pipe.fileHandleForReading.readabilityHandler = nil

            let exitCode = process.terminationStatus
            DispatchQueue.main.async {
                isBuilding = false
                if exitCode == 0 {
                    // 解析 DMG 路径
                    let lines = collectedOutput.components(separatedBy: "\n")
                    for line in lines {
                        if line.hasPrefix("DMG_OUTPUT_PATH=") {
                            let path = String(line.dropFirst("DMG_OUTPUT_PATH=".count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            dmgOutputPath = path
                            buildSucceeded = true
                            break
                        }
                    }
                    if dmgOutputPath == nil {
                        buildSucceeded = true
                        logs += "\n⚠️ 未能解析 DMG 路径，请手动查看项目目录"
                    }
                } else {
                    logs += "\n\n❌ 打包失败（退出码: \(exitCode)）"
                }
            }
        }
    }
}
