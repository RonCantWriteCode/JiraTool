import SwiftUI

struct NoticeView: View {
    @State private var date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var selectedType = 0
    @State private var result = ""
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "通知生成",
                    subtitle: "生成发布确认提醒文案或版本会议邀请通知",
                    icon: "bell.fill",
                    color: .orange
                )

                Picker("", selection: $selectedType) {
                    Label("发布确认提醒", systemImage: "checkmark.circle").tag(0)
                    Label("版本会议通知", systemImage: "person.3").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())

                CardSection(title: "查询参数", icon: "calendar", iconColor: .orange) {
                    LabeledField(label: "日期", placeholder: "yyyy-MM-dd", text: $date)
                }

                CardSection(title: "生成结果", icon: "text.bubble", iconColor: .green) {
                    HStack(spacing: 8) {
                        Button(action: {
                            Task {
                                isLoading = true
                                defer { isLoading = false }
                                if selectedType == 0 {
                                    result = await NoticeService.shared.generalPublishDes(date: date)
                                } else {
                                    result = await NoticeService.shared.generalVersionMeetingDesc(date: date)
                                }
                            }
                        }) {
                            HStack(spacing: 5) {
                                if isLoading {
                                    ProgressView().controlSize(.small).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "play.fill").font(.system(size: 11))
                                }
                                Text(isLoading ? "生成中..." : "生成")
                            }
                            .frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || date.isEmpty)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc").font(.system(size: 11))
                                Text("复制")
                            }
                        }
                        .disabled(result.isEmpty)

                        Spacer()
                    }

                    LogView(logs: result)
                        .frame(minHeight: 220)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 450)
    }
}
