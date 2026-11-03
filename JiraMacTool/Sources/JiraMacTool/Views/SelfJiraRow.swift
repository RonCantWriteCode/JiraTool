import SwiftUI
import AppKit

// MARK: - Self-Jira 行视图

struct SelfJiraRow: View {
    let issue: JiraIssue
    let isFavorited: Bool
    let isFavoriting: Bool
    let onOpen: () -> Void
    let onCopyKey: () -> Void
    let onShowDetail: () -> Void
    let onFavorite: () -> Void

    private var assignee: String {
        if let a = issue.fields["assignee"] as? [String: Any] {
            return a["displayName"] as? String ?? a["name"] as? String ?? "未分配"
        }
        return "未分配"
    }

    private var reporter: String {
        if let r = issue.fields["reporter"] as? [String: Any] {
            return r["displayName"] as? String ?? r["name"] as? String ?? "未知"
        }
        return "未知"
    }

    private var createdText: String {
        let s = issue.fields["created"] as? String ?? ""
        return FavoriteJira.formatJiraDatePublic(s)
    }

    private var updatedText: String {
        let s = issue.fields["updated"] as? String ?? ""
        return FavoriteJira.formatJiraDatePublic(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 第一行：Key + 类型 + 状态 + 操作
            HStack {
                Text(issue.key)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                    .onTapGesture { onOpen() }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                StatusBadge(text: issue.issueType, color: issueTypeColor)
                StatusBadge(text: issue.status, color: statusColor)

                Spacer()

                HStack(spacing: 4) {
                    Button(action: onOpen) {
                        Image(systemName: "safari")
                            .help("在浏览器中打开")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onCopyKey) {
                        Image(systemName: "doc.on.doc")
                            .help("复制编号")
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onFavorite) {
                        if isFavoriting {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: isFavorited ? "star.fill" : "star")
                                .foregroundColor(isFavorited ? .orange : .secondary)
                                .help(isFavorited ? "取消收藏" : "加入收藏Jira")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isFavoriting)
                }
            }

            // 第二行：标题（点击弹出详情）
            Text(issue.summary)
                .lineLimit(2)
                .onTapGesture { onShowDetail() }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

            // 第三行：信息
            HStack(spacing: 12) {
                Label(reporter, systemImage: "person")
                Label(assignee, systemImage: "person.fill")
                if !createdText.isEmpty {
                    Label(createdText, systemImage: "calendar")
                }
                if !updatedText.isEmpty {
                    Label(updatedText, systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("在浏览器中打开") { onOpen() }
            Button("复制编号") { onCopyKey() }
            Button("查看详情") { onShowDetail() }
            Button(isFavorited ? "取消收藏" : "加入收藏Jira") { onFavorite() }
        }
    }

    private var issueTypeColor: Color {
        let type = issue.issueType
        if type.contains("需求") { return .blue }
        else if type.contains("测试") { return .orange }
        else if type.contains("缺陷") || type.contains("Bug") { return .red }
        else if type.contains("子任务") { return .blue }
        else if type.contains("任务") { return .green }
        else if type.contains("代理") { return .green }
        return .gray
    }

    private var statusColor: Color {
        let s = issue.status.lowercased()
        if s.contains("完成") || s.contains("关闭") || s.contains("done") || s.contains("closed") { return .green }
        else if s.contains("进行") || s.contains("处理") || s.contains("progress") { return .orange }
        else if s.contains("测试") || s.contains("testing") { return .yellow }
        else if s.contains("开发") || s.contains("development") { return .white }
        else if s.contains("待") || s.contains("open") || s.contains("todo") { return .blue }
        return .gray
    }
}
