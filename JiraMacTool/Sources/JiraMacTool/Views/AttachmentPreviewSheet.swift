import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - 附件在线预览 Sheet

struct AttachmentPreviewSheet: View {
    let preview: AttachmentPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ideal = idealSize()
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: titleIcon)
                    .foregroundColor(.accentColor)
                Text(preview.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            Divider()

            // 内容区
            Group {
                switch preview.kind {
                case .image:
                    imagePreview
                case .text:
                    textPreview
                case .pdf:
                    pdfPreview
                case .richText:
                    richTextPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 精确尺寸：图片刚好装下屏幕时按原图尺寸显示；超出则收敛到屏幕 98%，由内部 ScrollView 滚动
        .frame(width: ideal.width, height: ideal.height)
    }

    private var titleIcon: String {
        switch preview.kind {
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .pdf: return "doc.richtext"
        case .richText: return "doc.text"
        }
    }

    /// 当前屏幕可视区域（已排除菜单栏与 Dock）
    private func screenSize() -> CGSize {
        NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }

    /// 图片在屏幕上的实际显示尺寸（points）。优先用 NSImage.size；为 0 时回退到像素尺寸
    private func imagePointSize(_ img: NSImage) -> CGSize {
        let s = img.size
        if s.width > 0 && s.height > 0 { return s }
        if let rep = img.representations.first {
            return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        return CGSize(width: 800, height: 600)
    }

    /// 标题栏 + 分割线 + ScrollView padding 的非内容区域尺寸预留
    private var chromeSize: CGSize { CGSize(width: 32, height: 95) }

    /// 根据内容类型 / 图片尺寸 返回自适应初始尺寸（精确尺寸，sheet 直接采用）
    private func idealSize() -> CGSize {
        let screen = screenSize()
        let maxW = screen.width * 0.98
        let maxH = screen.height * 0.98
        switch preview.kind {
        case .image:
            guard let img = NSImage(data: preview.data) else {
                return CGSize(width: 900, height: 700)
            }
            let pt = imagePointSize(img)
            // 图片 + chrome 能装进屏幕可视区则按原图尺寸；超出则按屏幕 98% 由内部滚动
            let needW = pt.width + chromeSize.width
            let needH = pt.height + chromeSize.height
            let w = min(max(needW, 400), maxW)
            let h = min(max(needH, 300), maxH)
            return CGSize(width: w, height: h)
        case .text:
            return CGSize(width: min(900, maxW), height: min(650, maxH))
        case .pdf:
            return CGSize(width: min(1000, maxW), height: min(800, maxH))
        case .richText:
            return CGSize(width: min(950, maxW), height: min(750, maxH))
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let img = NSImage(data: preview.data) {
            let pt = imagePointSize(img)
            ScrollView([.horizontal, .vertical]) {
                // 按原始 points 尺寸显示，不缩放失真；
                // 装得下时 sheet 恰好等于图片 + chrome，无滚动条；装不下时由 ScrollView 滚动
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: pt.width, height: pt.height)
                    .padding()
            }
        } else {
            errorPlaceholder("无法解析图片数据")
        }
    }

    @ViewBuilder
    private var textPreview: some View {
        let text = decodeText(preview.data)
        ScrollView {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private var pdfPreview: some View {
        if let doc = PDFDocument(data: preview.data) {
            PDFKitView(document: doc)
        } else {
            errorPlaceholder("无法解析 PDF 文件")
        }
    }

    @ViewBuilder
    private var richTextPreview: some View {
        RichTextView(data: preview.data, filename: preview.filename)
            .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func errorPlaceholder(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(msg)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 尝试多种编码解码文本
    private func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        // GB18030 / GBK
        let gb18030 = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(gb18030)
        if let s = String(data: data, encoding: String.Encoding(rawValue: nsEnc)) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return "⚠️ 无法解码文件内容"
    }
}

// MARK: - PDFKit 包装

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}

// MARK: - Word / RTF 富文本包装

struct RichTextView: NSViewRepresentable {
    let data: Data
    let filename: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            loadDocument(into: textView)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            loadDocument(into: textView)
        }
    }

    private func loadDocument(into textView: NSTextView) {
        let name = filename.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if name.hasSuffix(".docx") {
            options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        } else if name.hasSuffix(".doc") {
            options[.documentType] = NSAttributedString.DocumentType.docFormat
        } else if name.hasSuffix(".rtf") {
            options[.documentType] = NSAttributedString.DocumentType.rtf
        }

        // 尝试带 documentType 解析，失败后尝试自动识别
        if let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
            return
        }
        if let attr = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
            return
        }
        textView.string = "⚠️ 无法解析文档内容"
    }
}
