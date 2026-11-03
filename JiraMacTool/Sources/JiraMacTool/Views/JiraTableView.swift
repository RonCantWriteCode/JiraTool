import SwiftUI
import AppKit

// MARK: - Jira 表格视图（原生 SwiftUI Table，要求 macOS 14+）

struct JiraTableView: View {
    let rows: [JiraTableRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<JiraTableRow>]
    let fixDateTitle: String
    let onOpen: (String) -> Void
    let onCopyKey: (String) -> Void
    let onShowDetail: (String) -> Void
    let onFavorite: (String) -> Void
    let isFavoriting: (String) -> Bool

    @ObservedObject private var favoriteService = FavoriteService.shared

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            Group {
                TableColumn("编号", value: \JiraTableRow.key) { row in
                    Button {
                        onOpen(row.key)
                    } label: {
                        Text(row.key)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in h ? NSCursor.pointingHand.push() : NSCursor.pop() }
                }
                .width(min: 80, ideal: 100)

                TableColumn("标题", value: \JiraTableRow.summary) { row in
                    Button {
                        onShowDetail(row.key)
                    } label: {
                        Text(row.summary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in h ? NSCursor.pointingHand.push() : NSCursor.pop() }
                }
                .width(min: 200, ideal: 300)

                TableColumn("类型", value: \JiraTableRow.issueType) { row in
                    StatusBadge(text: row.issueType, color: issueTypeColor(row.issueType))
                }
                .width(60)

                TableColumn("状态", value: \JiraTableRow.status) { row in
                    StatusBadge(text: row.status, color: statusBadgeColor(row.status))
                }
                .width(70)

                TableColumn("经办人", value: \JiraTableRow.assignee) { row in
                    Text(row.assignee)
                }
                .width(50)

                TableColumn(fixDateTitle, value: \JiraTableRow.fixDate) { row in
                    Text(row.fixDate)
                }
                .width(70)

                TableColumn("预计提测时间", value: \JiraTableRow.testDate) { row in
                    Text(row.testDate)
                }
                .width(100)

                TableColumn("剩余提测时间") { row in
                    let status = row.status
                    if status == "内部测试" || status == "用户测试" {
                        Text("已提测")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                    } else if ["需求受理", "系统设计", "DBA审核", "需求待排期", "开发"].contains(status) {
                        if let targetDate = row.testDateObj {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let diff = Int(targetDate.timeIntervalSince(context.date))
                                if diff > 0 {
                                    let days = diff / 86400
                                    let hours = (diff % 86400) / 3600
                                    let minutes = (diff % 3600) / 60
                                    let seconds = diff % 60
                                    Text("\(days)天\(hours)时\(minutes)分\(seconds)秒")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.orange)
                                } else {
                                    Text("已逾期")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.red)
                                }
                            }
                        } else {
                            Text("-")
                        }
                    } else {
                        Text("-")
                    }
                }
                .width(100)

                TableColumn("版本号", value: \JiraTableRow.versions) { row in
                    Text(row.versions)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                }
                .width(min: 100, ideal: 150)

                TableColumn("系统开发人员", value: \JiraTableRow.developer) { row in
                    Text(row.developer)
                }
                .width(80)
            }

            Group {
                TableColumn("需求提出人员", value: \JiraTableRow.requester) { row in
                    Text(row.requester)
                }
                .width(80)

                TableColumn("标签", value: \JiraTableRow.labels) { row in
                    Text(row.labels)
                        .lineLimit(nil)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .width(min: 80, ideal: 120)

                TableColumn("更新时间", value: \JiraTableRow.updated) { row in
                    Text(row.updated)
                }
                .width(90)

                TableColumn("操作") { row in
                    HStack(spacing: 6) {
                        Button { onOpen(row.key) } label: {
                            Image(systemName: "safari").help("在浏览器中打开")
                        }.buttonStyle(PlainButtonStyle())

                        Button { onCopyKey(row.key) } label: {
                            Image(systemName: "doc.on.doc").help("复制编号")
                        }.buttonStyle(PlainButtonStyle())

                        Button { onFavorite(row.key) } label: {
                            if isFavoriting(row.key) {
                                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                            } else {
                                let fav = favoriteService.favorites.contains(where: { $0.key == row.key })
                                Image(systemName: fav ? "star.fill" : "star")
                                    .foregroundColor(fav ? .orange : .secondary)
                                    .help(fav ? "取消收藏" : "加入收藏")
                            }
                        }.buttonStyle(PlainButtonStyle())
                    }
                }
                .width(75)
            }
        }
        .onTapGesture(count: 2) {
            if let key = selection.first {
                onOpen(key)
            }
        }
    }
}

// MARK: - 表格徽章配色（仅表格视图使用）

fileprivate func issueTypeColor(_ type: String) -> Color {
    if type.contains("需求") { return .blue }
    else if type.contains("测试") { return .orange }
    else if type.contains("缺陷") || type.contains("Bug") { return .red }
    else if type.contains("子任务") { return .blue }
    else if type.contains("任务") { return .green }
    else if type.contains("代理") { return .green }
    return .gray
}

fileprivate func statusBadgeColor(_ s: String) -> Color {
    let ls = s.lowercased()
    if ls.contains("完成") || ls.contains("关闭") || ls.contains("done") || ls.contains("closed") { return .green }
    else if ls.contains("进行") || ls.contains("处理") || ls.contains("progress") { return .orange }
    else if ls.contains("测试") || ls.contains("testing") { return .yellow }
    else if ls.contains("开发") || ls.contains("development") { return .white }
    else if ls.contains("待") || ls.contains("open") || ls.contains("todo") { return .blue }
    return .gray
}
