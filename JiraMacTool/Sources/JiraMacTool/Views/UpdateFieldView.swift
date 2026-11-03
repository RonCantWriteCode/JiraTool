import SwiftUI

struct UpdateFieldView: View {
    @State private var date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var isRegular = true
    @State private var logs = ""
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("日期:")
                TextField("yyyy-MM-dd", text: $date)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            Toggle("设置常规版本排期需求为\"是\"", isOn: $isRegular)

            HStack {
                Button(action: {
                    Task {
                        isLoading = true
                        defer { isLoading = false }
                        logs = await UpdateFieldService.shared.updateSomeField(date: date, isRegular: isRegular)
                    }
                }) {
                    Text(isLoading ? "执行中..." : "执行更新")
                }
                .disabled(isLoading || date.isEmpty)

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
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("字段更新")
    }
}
