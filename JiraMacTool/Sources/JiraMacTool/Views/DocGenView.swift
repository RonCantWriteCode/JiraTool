import SwiftUI

struct DocGenView: View {
    @State private var reqId = ""
    @State private var reqName = ""
    @State private var categories = "设计文档"
    @State private var tagsText = "推返修,设计文档"
    @State private var description = ""
    @State private var titleResult = ""
    @State private var contentResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("REQ ID:")
                TextField("REQ-XXXXX", text: $reqId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("需求名称:")
                TextField("输入需求名称", text: $reqName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("分类:")
                TextField("设计文档", text: $categories)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("标签:")
                TextField("用逗号分隔", text: $tagsText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("描述:")
                TextEditor(text: $description)
                    .frame(height: 60)
                    .border(Color.gray.opacity(0.3), width: 1)
            }

            HStack {
                Button("生成") {
                    let tags = tagsText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    let result = DocService.generateDoc(reqId: reqId, reqName: reqName, categories: categories, tags: tags, description: description)
                    titleResult = result.title
                    contentResult = result.content
                }
                .disabled(reqId.isEmpty || reqName.isEmpty)

                Button("复制标题") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(titleResult, forType: .string)
                }

                Button("复制内容") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(contentResult, forType: .string)
                }
            }

            if !titleResult.isEmpty {
                Text("标题:")
                    .font(.headline)
                Text(titleResult)
                    .textSelection(.enabled)
                    .padding(4)
                    .background(Color.yellow.opacity(0.2))
            }

            if !contentResult.isEmpty {
                Text("内容:")
                    .font(.headline)
                ScrollView {
                    Text(contentResult)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(Color.gray.opacity(0.3), width: 1)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, minHeight: 500)
        .navigationTitle("文档生成")
    }
}
