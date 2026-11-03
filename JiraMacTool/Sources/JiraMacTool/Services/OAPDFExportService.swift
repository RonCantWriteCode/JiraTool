import Foundation
@preconcurrency import WebKit

// MARK: - Error

enum OAPDFExportError: Error, LocalizedError {
    case invalidBaseURL
    case cookieInjectionFailed(String)
    case pageLoadFailed(String)
    case jsInjectionFailed(String)
    case pdfCaptureFailed(String)
    case timeout
    case base64DecodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "PDF 导出：无效的 baseURL"
        case .cookieInjectionFailed(let m): return "PDF 导出：Cookie 注入失败 - \(m)"
        case .pageLoadFailed(let m): return "PDF 导出：页面加载失败 - \(m)"
        case .jsInjectionFailed(let m): return "PDF 导出：JS 注入失败 - \(m)"
        case .pdfCaptureFailed(let m): return "PDF 导出：PDF 捕获失败 - \(m)"
        case .timeout: return "PDF 导出：超时（90 秒）"
        case .base64DecodeFailed: return "PDF 导出：Base64 解码失败"
        }
    }
}

// MARK: - PDF Response Model

/// JS 回传的 PDF 响应 JSON 结构
private struct OAPDFResponseJSON: Decodable {
    let base64: String
    let fileName: String?
}

// MARK: - Delegate Coordinator

/// 在主线程上运行，负责 WKNavigationDelegate + WKScriptMessageHandler + WKDownloadDelegate 回调
@MainActor
private final class PDFDelegateCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {

    var onPageLoaded: ((WKWebView) -> Void)?
    var onPageFailed: ((Error) -> Void)?
    var onPDFReady: ((String) -> Void)?
    var downloadDestinationURL: URL?
    var suggestedFileName: String?
    /// decidePolicyFor navigationResponse 中记录的响应建议文件名（备用来源）
    var responseSuggestedFileName: String?
    /// OA 导出只产生一个 PDF：仅处理第一个下载，取消后续下载避免干扰（与 C# 端 downloadHandled 对齐）
    var hasHandledDownload = false
    /// downloadDidFinish 回调不带 webView 参数，读取 document.title 时需要它
    weak var webView: WKWebView?

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageLoaded?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onPageFailed?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onPageFailed?(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mimeType = navigationResponse.response.mimeType ?? ""
        debugLog("[OAPDFExport] decidePolicyFor navigationResponse: MIME=\(mimeType), canShow=\(navigationResponse.canShowMIMEType), URL=\(navigationResponse.response.url?.absoluteString ?? "unknown")")
        // 记录响应建议文件名（下载文件名的备选来源）
        if let suggested = navigationResponse.response.suggestedFilename {
            responseSuggestedFileName = suggested
        }
        // PDF 或无法在 WebView 中直接显示的内容 → 作为下载处理
        if mimeType == "application/pdf" || mimeType == "application/octet-stream" || !navigationResponse.canShowMIMEType {
            debugLog("[OAPDFExport] Treating response as download (MIME: \(mimeType))")
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    // WKWebView 下载拦截（iOS 13+ / macOS 10.15+）
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        debugLog("[OAPDFExport] Navigation became download: \(navigationAction.request.url?.absoluteString ?? "unknown")")
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        debugLog("[OAPDFExport] Navigation response became download: \(navigationResponse.response.url?.absoluteString ?? "unknown")")
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        debugLog("[OAPDFExport] Download destination requested, suggested: \(suggestedFilename), MIME: \(response.mimeType ?? "unknown"), expectedContentLength: \(response.expectedContentLength)")
        // OA 导出只产生一个 PDF：仅处理第一个下载，取消后续下载避免干扰（与 C# 端对齐）
        if hasHandledDownload {
            debugLog("[OAPDFExport] Additional download ignored and cancelled")
            completionHandler(nil)
            return
        }
        hasHandledDownload = true
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("oa_pdf_\(UUID().uuidString.prefix(8)).pdf")
        downloadDestinationURL = tmpURL
        suggestedFileName = suggestedFilename
        completionHandler(tmpURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        debugLog("[OAPDFExport] Download finished")
        guard let destURL = downloadDestinationURL, FileManager.default.fileExists(atPath: destURL.path) else {
            debugLog("[OAPDFExport] Download finished but destination file not found")
            onPDFReady?("ERROR:下载完成但文件不存在")
            return
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path))?[.size] as? Int ?? 0
        debugLog("[OAPDFExport] Downloaded file size: \(fileSize) bytes")
        guard fileSize > 0 else {
            debugLog("[OAPDFExport] Downloaded file is empty")
            onPDFReady?("ERROR:下载完成但文件为空")
            try? FileManager.default.removeItem(at: destURL)
            downloadDestinationURL = nil
            return
        }
        guard let data = try? Data(contentsOf: destURL) else {
            debugLog("[OAPDFExport] Failed to read downloaded file")
            onPDFReady?("ERROR:无法读取下载的文件")
            try? FileManager.default.removeItem(at: destURL)
            downloadDestinationURL = nil
            return
        }
        try? FileManager.default.removeItem(at: destURL)
        downloadDestinationURL = nil

        let base64 = data.base64EncodedString()

        // 文件名解析链（与 C# 端 ResolveDownloadFileNameAsync 对齐）：
        // ① 下载建议名（= OA export.js 的 jsPDF.save(标题+'.pdf') 设置的 download 属性；
        //    responseSuggestedFileName 为响应层备用建议名）
        // → ② document.title（OA 页面标题，过滤 "content"）
        // → ③ 下载原始请求 URL 最后一段（blob: URL 时通常拿不到有效名字）
        // → ④ 回传空名，由上层使用 printURL 默认名
        let suggestedCandidates = [suggestedFileName, responseSuggestedFileName]
            .compactMap { $0 }
            .map { Self.sanitizeFileName($0) }
        if let valid = suggestedCandidates.first(where: { !Self.isGenericPdfName($0) }) {
            let fileName = Self.ensurePdfExtension(valid)
            debugLog("[OAPDFExport] PDF ready, base64 length: \(base64.count), fileName: \(fileName)")
            onPDFReady?(JSON.stringify(["base64": base64, "fileName": fileName]))
            return
        }

        // ② document.title → ③ URI 最后一段 → ④ 空名（由上层默认名兜底）
        guard let wv = webView else {
            if let uriName = Self.fileNameFromOriginalRequest(download) {
                debugLog("[OAPDFExport] PDF ready (URI fallback), base64 length: \(base64.count), fileName: \(uriName)")
                onPDFReady?(JSON.stringify(["base64": base64, "fileName": uriName]))
            } else {
                debugLog("[OAPDFExport] PDF ready (no webView for title fallback), base64 length: \(base64.count)")
                onPDFReady?(JSON.stringify(["base64": base64, "fileName": ""]))
            }
            return
        }
        wv.evaluateJavaScript("document.title") { [weak self] result, _ in
            Task { @MainActor in
                var fileName = ""
                if let title = result as? String {
                    let cleaned = Self.sanitizeFileName(title)
                    if !cleaned.isEmpty && cleaned != "content" {
                        fileName = Self.ensurePdfExtension(cleaned)
                    }
                }
                if fileName.isEmpty, let uriName = Self.fileNameFromOriginalRequest(download) {
                    fileName = uriName
                }
                debugLog("[OAPDFExport] PDF ready (document.title fallback), base64 length: \(base64.count), fileName: \(fileName)")
                self?.onPDFReady?(JSON.stringify(["base64": base64, "fileName": fileName]))
            }
        }
    }

    /// 从下载的原始请求 URL 提取最后一段作为文件名候选（与 C# 端 URI last segment 对齐；blob: URL 时通常无效）
    nonisolated static func fileNameFromOriginalRequest(_ download: WKDownload) -> String? {
        guard let url = download.originalRequest?.url else { return nil }
        let rawSeg = url.lastPathComponent
        guard !rawSeg.isEmpty, rawSeg != "/" else { return nil }
        let seg = rawSeg.removingPercentEncoding ?? rawSeg
        let dlName = sanitizeFileName(seg)
        guard !isGenericPdfName(dlName) else { return nil }
        return ensurePdfExtension(dlName)
    }

    // MARK: - File name helpers

    /// 清理文件名中的非法字符（Windows 保留字符与控制字符，与 C# 端 SanitizeFileName 保持一致）
    nonisolated static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// 未携带 OA 标题的“通用”下载文件名，命中则继续 fallback（与 C# 端 GenericPdfNames 保持一致）
    nonisolated static func isGenericPdfName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || [
            "download.pdf", "document.pdf", "export.pdf", "content.pdf",
            "print.pdf", "untitled.pdf", "blob.pdf", "file.pdf", "unknown.pdf", "oa_print.pdf"
        ].contains(trimmed.lowercased())
    }

    nonisolated static func ensurePdfExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        debugLog("[OAPDFExport] Download failed: \(error.localizedDescription)")
        onPDFReady?("ERROR:下载失败 - \(error.localizedDescription)")
        downloadDestinationURL = nil
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        debugLog("[OAPDFExport][DIAG] ScriptMessage received, name=\(message.name), bodyType=\(type(of: message.body))")
        if message.name == "pdfReady", let body = message.body as? String {
            let preview = body.count > 300 ? String(body.prefix(300)) + "..." : body
            debugLog("[OAPDFExport][DIAG] pdfReady body preview: \(preview)")
            onPDFReady?(body)
        } else if message.name == "consoleLog", let body = message.body as? String {
            // 转发 WebView 内的 console.log 到原生日志
            debugLog("[WebView Console] \(body)")
        }
    }
}

// MARK: - JSON helper

private enum JSON {
    static func stringify(_ dict: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - WebView Holder (lives on MainActor)

/// 持有 WKWebView 及其 coordinator，确保所有 UI 操作在主线程
@MainActor
private final class PDFWebViewHolder {
    let webView: WKWebView
    let coordinator: PDFDelegateCoordinator
    let config: WKWebViewConfiguration

    init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()

        let coord = PDFDelegateCoordinator()
        cfg.userContentController.add(coord, name: "pdfReady")
        cfg.userContentController.add(coord, name: "consoleLog")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
        wv.navigationDelegate = coord
        wv.isHidden = true
        coord.webView = wv

        self.config = cfg
        self.coordinator = coord
        self.webView = wv
    }

    func cleanup() {
        // 先移除 message handler，防止清理过程中再收到消息
        config.userContentController.removeScriptMessageHandler(forName: "pdfReady")
        config.userContentController.removeScriptMessageHandler(forName: "consoleLog")
        coordinator.onPageLoaded = nil
        coordinator.onPageFailed = nil
        coordinator.onPDFReady = nil
        coordinator.hasHandledDownload = false
        webView.loadHTMLString("about:blank", baseURL: nil)
    }

    deinit {
        // 安全网：即使忘记手动调用 cleanup，deinit 也能释放资源。
        // deinit 是 nonisolated，不能同步调用 @MainActor 方法，调度回主线程执行
        Task { @MainActor in
            self.cleanup()
        }
    }
}

// MARK: - Service

actor OAPDFExportService {
    static let shared = OAPDFExportService()

    /// 主线程持有的 WebView 容器
    @MainActor
    private lazy var holder: PDFWebViewHolder = PDFWebViewHolder()

    private init() {}

    /// 通过隐藏 WKWebView 加载 OA 打印页，注入 JS 触发 PDF 导出，
    /// 利用 WKDownloadDelegate 原生下载拦截捕获下载文件，返回 PDF 原始数据和文件名
    ///
    /// - Parameters:
    ///   - printURL: OA 打印页的完整 URL
    ///   - baseURL: OA 站点 base URL（用于 Cookie 注入）
    /// - Returns: 元组 `(data: Data, fileName: String)`，data 为 PDF 原始字节，fileName 为从页面或 URL 解析的文件名
    /// - Throws: `OAPDFExportError` 类型的错误（超时、页面加载失败、JS 注入失败等）
    @discardableResult
    func exportPDF(printURL: String, baseURL: String) async throws -> (data: Data, fileName: String) {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, fileName: String), Error>) in
            Task { @MainActor in
                do {
                    try await self.runExport(printURL: printURL, baseURL: baseURL, continuation: continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Internal

    @MainActor
    private func runExport(
        printURL: String,
        baseURL: String,
        continuation: CheckedContinuation<(data: Data, fileName: String), Error>
    ) async throws {
        guard !baseURL.isEmpty else {
            throw OAPDFExportError.invalidBaseURL
        }

        let h = self.holder
        let webView = h.webView
        let coordinator = h.coordinator
        let defaultFileName = Self.defaultFileName(from: printURL)

        // 用 actor-isolated 标记保证 resolved 仅在 MainActor 上访问
        var resolved = false

        func resume(_ result: Result<(data: Data, fileName: String), Error>) {
            guard !resolved else { return }
            resolved = true
            h.cleanup()
            switch result {
            case .success(let (data, fileName)):
                debugLog("[OAPDFExport] 导出成功，\(data.count.formatted(.byteCount(style: .file)))，文件名: \(fileName)")
                continuation.resume(returning: (data, fileName))
            case .failure(let error):
                debugLog("[OAPDFExport] 导出失败: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        }

        // 超时保护：90 秒（html2canvas + jsPDF 客户端渲染需要更多时间）
        let startTime = Date()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            let elapsed = Date().timeIntervalSince(startTime)
            debugLog("[OAPDFExport][DIAG] TIMEOUT fired after \(String(format: "%.1f", elapsed))s")
            // 超时后触发 resume
            resume(.failure(OAPDFExportError.timeout))
        }

        // 设置回调 — 这些闭包在 PDFDelegateCoordinator（@MainActor）的 delegate 方法中被调用
        coordinator.onPageFailed = { error in
            timeoutTask.cancel()
            resume(.failure(OAPDFExportError.pageLoadFailed(error.localizedDescription)))
        }

        coordinator.onPDFReady = { response in
            timeoutTask.cancel()
            if response.hasPrefix("ERROR:") {
                let msg = String(response.dropFirst(6))
                resume(.failure(OAPDFExportError.pdfCaptureFailed(msg)))
                return
            }
            // 尝试解析 JSON 格式 {"base64":"...","fileName":"..."}
            let (base64String, capturedFileName) = Self.parsePDFResponse(response)
            guard let data = Data(base64Encoded: base64String) else {
                resume(.failure(OAPDFExportError.base64DecodeFailed))
                return
            }
            let fileName = capturedFileName.isEmpty ? defaultFileName : capturedFileName
            resume(.success((data, fileName)))
        }

        coordinator.onPageLoaded = { wv in
            // 页面加载完成后注入 JS；Promise 拒绝会通过 JS .catch → pdfReady 回传
            debugLog("[OAPDFExport][DIAG] Page loaded, URL=\(wv.url?.absoluteString ?? "unknown"), injecting JS...")
            let js = OAPDFExportService.pdfInterceptJS()
            debugLog("[OAPDFExport][DIAG] JS script length=\(js.count) chars")
            wv.evaluateJavaScript(js) { result, error in
                if let error = error {
                    debugLog("[OAPDFExport][DIAG] JS execution FAILED: \(error.localizedDescription)")
                } else {
                    let resultStr = result.map { String(describing: $0).prefix(200) } ?? "nil"
                    debugLog("[OAPDFExport][DIAG] JS execution completed, result=\(resultStr)")
                }
            }
        }

        // 注入 Cookie 并加载页面
        try await injectCookies(into: webView, baseURL: baseURL)

        guard let url = URL(string: printURL) else {
            timeoutTask.cancel()
            resume(.failure(OAPDFExportError.invalidBaseURL))
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// 将 OAService 中的 cookies 注入到 WKWebView
    @MainActor
    private func injectCookies(into webView: WKWebView, baseURL: String) async throws {
        guard let host = URL(string: baseURL)?.host else {
            throw OAPDFExportError.invalidBaseURL
        }

        let oaCookies = await OAService.shared.cookies
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

        // 先同步构造所有 HTTPCookie，再逐个注入（cookieStore 是 MainActor API，无需并发）
        let httpCookies = oaCookies.compactMap { name, value in
            HTTPCookie(properties: [.name: name, .value: value, .domain: host, .path: "/"])
        }
        for cookie in httpCookies {
            await cookieStore.setCookie(cookie)
        }
    }

    /// 从 URL 解析默认文件名：全部路径段用 "_" 连接 + ".pdf"（与 C# 端 string.Join("_", segments) 对齐）
    nonisolated private static func defaultFileName(from url: String) -> String {
        guard let url = URL(string: url) else { return "oa_print.pdf" }
        let segs = url.pathComponents
            .filter { !$0.isEmpty && $0 != "/" }
            .map { ($0.removingPercentEncoding ?? $0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        if !segs.isEmpty {
            return segs.joined(separator: "_") + ".pdf"
        }
        return "oa_print.pdf"
    }

    /// 解析 JS 回传的 PDF 响应：支持 JSON 格式 {"base64":"...","fileName":"..."} 或纯 base64 字符串
    nonisolated private static func parsePDFResponse(_ response: String) -> (base64: String, fileName: String) {
        if let data = response.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(OAPDFResponseJSON.self, from: data) {
            return (decoded.base64, decoded.fileName ?? "")
        }
        return (response, "")
    }

    // MARK: - JS

    nonisolated private static func pdfInterceptJS() -> String {
        return """
        // 注入 console.log 捕获，转发到原生代码（用于诊断）
        (function() {
            var origLog = console.log;
            var origWarn = console.warn;
            var origError = console.error;
            function forward(level, args) {
                var msg = Array.prototype.slice.call(args).map(function(a) {
                    try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                    catch(e) { return String(a); }
                }).join(' ');
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[' + level + '] ' + msg);
                } catch(e) {}
            }
            console.log = function() { forward('LOG', arguments); origLog.apply(console, arguments); };
            console.warn = function() { forward('WARN', arguments); origWarn.apply(console, arguments); };
            console.error = function() { forward('ERROR', arguments); origError.apply(console, arguments); };
        })();

        console.log('[PDF Export] === Native download mode ===');
        console.log('[PDF Export] URL:', location.href);
        console.log('[PDF Export] Title:', document.title);
        console.log('[PDF Export] typeof seajs:', typeof seajs);
        console.log('[PDF Export] typeof outputPDF:', typeof outputPDF);
        console.log('[PDF Export] typeof html2canvas:', typeof html2canvas);
        console.log('[PDF Export] typeof jsPDF:', typeof jsPDF);

        // 触发 PDF 导出 — 由原生 WKDownloadDelegate 捕获下载文件
        (function() {
            function reportError(msg) {
                console.log('[PDF Export] ERROR:', msg);
                try { window.webkit.messageHandlers.pdfReady.postMessage('ERROR:' + msg); } catch(e) {}
            }

            if (typeof seajs !== 'undefined') {
                console.log('[PDF Export] Using seajs to trigger export...');
                var seajsTimeout = setTimeout(function() {
                    reportError('seajs.use callback never fired after 15s - module load failure');
                }, 15000);

                seajs.use(['lui/jquery','lui/export/export'], function($, exp) {
                    clearTimeout(seajsTimeout);
                    console.log('[PDF Export] seajs.use callback executed');
                    if (!exp) {
                        reportError('seajs loaded but exp module is null/undefined');
                        return;
                    }
                    if (typeof exp.exportPdf !== 'function') {
                        reportError('exp.exportPdf is not a function. Available: ' + Object.keys(exp).join(', '));
                        return;
                    }
                    try {
                        console.log('[PDF Export] Calling exp.exportPdf()...');
                        exp.exportPdf();
                        console.log('[PDF Export] exp.exportPdf() returned successfully — waiting for native download...');
                    } catch(e) {
                        reportError('exp.exportPdf() threw: ' + (e.message || e));
                    }
                });
            } else if (typeof outputPDF === 'function') {
                console.log('[PDF Export] Calling outputPDF()...');
                try {
                    outputPDF();
                    console.log('[PDF Export] outputPDF() called — waiting for native download...');
                } catch(e) {
                    reportError('outputPDF() threw: ' + (e.message || e));
                }
            } else {
                var globalFuncs = [];
                for (var k in window) {
                    if (typeof window[k] === 'function' && (k.toLowerCase().indexOf('pdf') >= 0 || k.toLowerCase().indexOf('export') >= 0 || k.toLowerCase().indexOf('print') >= 0)) {
                        globalFuncs.push(k);
                    }
                }
                reportError('Neither seajs nor outputPDF found. PDF-related globals: ' + (globalFuncs.join(', ') || 'none'));
            }
        })();
        """
    }
}
