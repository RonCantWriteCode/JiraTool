import SwiftUI

struct PublishView: View {
    @State private var date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var noPublishId = ""
    @State private var reqId = ""
    @State private var banbenhao = ""
    @State private var selectedTab = 0
    @State private var logs = ""
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "创建发布申请",
                    subtitle: "按日期批量创建或按 REQ 单独创建 PUBLISH 工单",
                    icon: "arrow.up.circle.fill",
                    color: .blue
                )

                Picker("", selection: $selectedTab) {
                    Label("按日期创建", systemImage: "calendar").tag(0)
                    Label("按REQ创建", systemImage: "doc.text.magnifyingglass").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())

                if selectedTab == 0 {
                    CardSection(title: "发布参数", icon: "calendar", iconColor: .blue) {
                        LabeledField(label: "发布日期", placeholder: "yyyy-MM-dd", text: $date)
                        LabeledField(label: "排除版本号", placeholder: "可选，指定不创建的版本号", text: $noPublishId)
                    }
                } else {
                    CardSection(title: "REQ 参数", icon: "doc.text.magnifyingglass", iconColor: .purple) {
                        LabeledField(label: "REQ ID", placeholder: "REQ-XXXXX", text: $reqId)
                        LabeledField(label: "指定版本号", placeholder: "可选，空则创建全部", text: $banbenhao)
                    }
                }

                CardSection(title: "执行", icon: "terminal", iconColor: .green) {
                    ActionBar(
                        executeTitle: "执行",
                        isLoading: isLoading,
                        canExecute: canExecute,
                        logs: logs,
                        onExecute: {
                            Task {
                                isLoading = true
                                defer { isLoading = false }
                                if selectedTab == 0 {
                                    logs = await PublishService.shared.createPublishByDate(date: date, noPublishId: noPublishId.isEmpty ? nil : noPublishId)
                                } else {
                                    logs = await PublishService.shared.createPublishByReq(reqId: reqId, banbenhao: banbenhao.isEmpty ? nil : banbenhao)
                                }
                            }
                        },
                        onClear: { logs = "" }
                    )
                    LogView(logs: logs)
                        .frame(minHeight: 200)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 450)
    }

    private var canExecute: Bool {
        selectedTab == 0 ? !date.isEmpty : !reqId.isEmpty
    }
}
