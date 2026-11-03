using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Interop;
using JiraWinTool.Utils;
using Microsoft.Web.WebView2.Core;

namespace JiraWinTool.Services;

/// <summary>
/// PDF 导出异常
/// </summary>
public class OAPDFExportException : Exception
{
    public OAPDFExportException(string message) : base(message) { }
    public OAPDFExportException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>
/// 通过隐藏 WebView2 加载 OA 打印页，注入 JS 触发 PDF 导出，
/// 利用 WebView2 原生 DownloadStarting 事件捕获下载文件，返回 PDF 原始数据。
/// 对应 Swift 端 OAPDFExportService。
/// </summary>
public class OAPDFExportService
{
    public static OAPDFExportService Shared { get; } = new();

    private const int TimeoutSeconds = 90;

    private OAPDFExportService() { }

    /// <summary>
    /// 通过 offscreen WebView2 加载 OA 打印页，注入 JS 触发 PDF 导出，
    /// 利用原生 DownloadStarting 事件捕获下载文件，返回 PDF 字节数组和文件名
    /// </summary>
    public async Task<(byte[] Data, string FileName)> ExportPDFAsync(string printURL, string baseURL)
    {
        if (string.IsNullOrEmpty(baseURL))
            throw new OAPDFExportException("PDF 导出：无效的 baseURL");

        // 用于桥接事件到 async/await；结果为 (base64, fileName)
        var tcs = new TaskCompletionSource<(string Base64, string FileName)>(TaskCreationOptions.RunContinuationsAsynchronously);

        // 超时保护
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSeconds));
        using var registration = cts.Token.Register(() =>
        {
            tcs.TrySetException(new OAPDFExportException($"PDF 导出：超时（{TimeoutSeconds} 秒）"));
        });

        // 从 printURL 解析默认文件名（去掉 query 参数）
        var defaultFileName = "oa_print.pdf";
        try
        {
            var uri = new Uri(printURL);
            var segs = uri.Segments.Where(s => s != "/").Select(s => Uri.UnescapeDataString(s.TrimEnd('/'))).Where(s => !string.IsNullOrEmpty(s)).ToList();
            if (segs.Count > 0)
                defaultFileName = $"{string.Join("_", segs)}.pdf";
        }
        catch { /* 使用默认文件名 */ }

        CoreWebView2Environment? env = null;
        CoreWebView2Controller? controller = null;
        HwndSource? hwndSource = null;
        string? userDataFolder = null;

        try
        {
            // 1. 创建 offscreen WebView2 环境
            // 创建专用临时 UserData 目录，避免连续快速导出时的目录锁冲突
            userDataFolder = Path.Combine(Path.GetTempPath(), "JiraMacTool_WebView2_" + Guid.NewGuid().ToString("N")[..8]);
            env = await CoreWebView2Environment.CreateAsync(null, userDataFolder);

            // 创建隐藏的 HwndSource 作为 controller 的父窗口
            var hwndParams = new HwndSourceParameters("OAPDFExportHost")
            {
                Width = 1024,
                Height = 768,
                PositionX = -10000,
                PositionY = -10000,
                WindowStyle = 0x800000, // WS_POPUP — 不可见
                ExtendedWindowStyle = 0x08000080, // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW — 不可见且不在任务栏闪现
                ParentWindow = IntPtr.Zero,
            };
            hwndSource = new HwndSource(hwndParams);
            var hwnd = hwndSource.Handle;

            // 2. 创建 controller（offscreen）
            controller = await env.CreateCoreWebView2ControllerAsync(hwnd);
            controller.Bounds = new System.Drawing.Rectangle(0, 0, 1024, 768);
            controller.IsVisible = false;

            var webView = controller.CoreWebView2;

            // 3. Cookie 桥接：将 OAService 的 cookies 注入到 WebView2
            await InjectCookiesAsync(webView, baseURL);

            // 4. 设置 WebMessageReceived 监听 JS 回传的消息（仅用于错误报告和 console 转发）
            webView.WebMessageReceived += (_, args) =>
            {
                try
                {
                    var json = args.WebMessageAsJson;
                    Log.Debug($"[OAPDFExport][DIAG] WebMessageReceived, length={json.Length}");

                    // 检查是否是 console.log 转发（以 "__console:" 前缀标识）
                    if (json.Contains("\"__console:\""))
                    {
                        var logMsg = ExtractJSONValue(json, "__console:");
                        if (!string.IsNullOrEmpty(logMsg))
                            Log.Debug($"[WebView Console] {logMsg}");
                        return;
                    }

                    // JS 回传的错误消息
                    if (json.StartsWith("\"ERROR:") || (json.Contains("ERROR:") && !json.Contains("\"base64\"")))
                    {
                        var errMsg = json.Trim('"');
                        Log.Debug($"[OAPDFExport][DIAG] Received ERROR from JS: {errMsg}");
                        tcs.TrySetException(new OAPDFExportException("PDF 导出：" + errMsg));
                        return;
                    }

                    // 兼容：如果 JS 仍然回传 base64（不应发生，但保留容错）
                    if (json.Contains("\"base64\""))
                    {
                        Log.Debug($"[OAPDFExport][DIAG] Unexpected base64 from JS (native download should handle this), length={json.Length}");
                    }
                }
                catch (Exception ex)
                {
                    Log.Debug($"[OAPDFExport][DIAG] WebMessageReceived handler EXCEPTION: {ex}");
                    tcs.TrySetException(new OAPDFExportException("PDF 导出：消息处理异常", ex));
                }
            };

            // 4b. DownloadStarting — 原生下载拦截（主要 PDF 捕获机制）
            // jsPDF 的 save() 触发 <a download> 点击，WebView2 会触发此事件
            // 线程模型：DownloadStarting / StateChanged 事件均在 UI 线程触发，
            // 所有 CoreWebView2 成员（State/ResultFilePath/InterruptReason 等）只允许在这些
            // 事件处理器内访问；严禁在轮询循环或 Task.Run 中访问（会抛出
            // "CoreWebView2 members can only be accessed from the UI thread"）。
            // 下载等待采用事件驱动 + TaskCompletionSource，不做任何轮询。
            var downloadHandled = false;
            webView.DownloadStarting += (_, args) =>
            {
                try
                {
                    var downloadOp = args.DownloadOperation;
                    var dlUri = downloadOp.Uri;
                    var mimeType = downloadOp.MimeType;
                    var totalBytes = downloadOp.TotalBytesToReceive;
                    Log.Debug($"[OAPDFExport] DownloadStarting fired: URI={dlUri}, MimeType={mimeType}, TotalBytesExpected={totalBytes}");
            
                    // OA 导出只产生一个 PDF：仅处理第一个下载，取消后续下载避免干扰
                    if (downloadHandled)
                    {
                        Log.Debug("[OAPDFExport] Additional download ignored and cancelled");
                        args.Cancel = true;
                        return;
                    }
                    downloadHandled = true;

                    // 在覆盖 ResultFilePath 前捕获 WebView2 建议的原始文件名：
                    // OA 的 export.js 用 jsPDF.save(标题 + '.pdf') 触发 <a download="标题.pdf">，
                    // WebView2 会把 download 属性作为建议文件名写入 ResultFilePath 初始值
                    var originalFileName = Path.GetFileName(args.ResultFilePath);
                    Log.Debug($"[OAPDFExport] Download suggested fileName: {originalFileName}");

                    // 设置下载路径到临时文件
                    var filePath = Path.Combine(Path.GetTempPath(), "oa_pdf_dl_" + Guid.NewGuid().ToString("N")[..8] + ".pdf");
                    args.ResultFilePath = filePath;
            
                    // 不取消下载，让 WebView2 完成它；标记为已处理以抑制默认下载 UI
                    args.Handled = true;
                    args.Cancel = false;
                    Log.Debug($"[OAPDFExport] Download allowed, saving to: {filePath}");
            
                    // 事件驱动等待下载完成：StateChanged 在 UI 线程触发，
                    // 在此读取 downloadOp.State / ResultFilePath / InterruptReason 是安全的
                    var terminal = false;
                    downloadOp.StateChanged += async (_, _) =>
                    {
                        try
                        {
                            var state = downloadOp.State; // UI 线程访问，安全
                            Log.Debug($"[OAPDFExport] Download state changed: {state}, bytes: {downloadOp.BytesReceived}/{downloadOp.TotalBytesToReceive}");
            
                            if (terminal || state == CoreWebView2DownloadState.InProgress)
                                return;
            
                            terminal = true;
                            if (state == CoreWebView2DownloadState.Completed)
                            {
                                // 在 UI 线程读取最终路径，再把纯文件 I/O 转到线程池执行
                                var finalPath = downloadOp.ResultFilePath;
                                Log.Debug($"[OAPDFExport] Download completed, file: {finalPath}");

                                // 在 UI 线程（StateChanged 回调内）解析最终文件名：
                                // 原始建议名（= OA 标题.pdf）→ document.title → 下载 URI → 默认名。
                                // ExecuteScriptAsync 只允许在 UI 线程调用，不能放进下面的 Task.Run
                                var fn = await ResolveDownloadFileNameAsync(webView, originalFileName, dlUri, defaultFileName);

                                _ = Task.Run(async () =>
                                {
                                    try
                                    {
                                        // 下载刚完成时文件可能尚未完全落盘，最多重试 5 秒（纯文件 I/O）
                                        byte[]? bytes = null;
                                        for (int i = 0; i < 10 && (bytes == null || bytes.Length == 0); i++)
                                        {
                                            if (File.Exists(finalPath))
                                                bytes = await File.ReadAllBytesAsync(finalPath);
                                            if (bytes == null || bytes.Length == 0)
                                                await Task.Delay(500);
                                        }
            
                                        if (bytes == null || bytes.Length == 0)
                                        {
                                            Log.Debug($"[OAPDFExport] Download completed but file missing or empty: {finalPath}");
                                            tcs.TrySetException(new OAPDFExportException("PDF 导出：下载完成但文件不存在或为空"));
                                            return;
                                        }
            
                                        var base64 = Convert.ToBase64String(bytes);
                                        Log.Debug($"[OAPDFExport] Download completed, file size: {bytes.Length} bytes, fileName: {fn}");
                                        tcs.TrySetResult((base64, fn));
            
                                        // 清理临时文件
                                        try { File.Delete(finalPath); } catch { }
                                    }
                                    catch (Exception ex)
                                    {
                                        Log.Debug($"[OAPDFExport] Download file read error: {ex.Message}");
                                        tcs.TrySetException(new OAPDFExportException($"PDF 导出：读取下载文件失败 - {ex.Message}", ex));
                                    }
                                });
                            }
                            else if (state == CoreWebView2DownloadState.Interrupted)
                            {
                                Log.Debug($"[OAPDFExport] Download interrupted: {downloadOp.InterruptReason}");
                                tcs.TrySetException(new OAPDFExportException($"PDF 导出：下载中断 ({downloadOp.InterruptReason})"));
                            }
                        }
                        catch (Exception ex)
                        {
                            Log.Debug($"[OAPDFExport] StateChanged handler error: {ex.Message}");
                            tcs.TrySetException(new OAPDFExportException($"PDF 导出：下载状态处理失败 - {ex.Message}", ex));
                        }
                    };
                }
                catch (Exception ex)
                {
                    Log.Debug($"[OAPDFExport] DownloadStarting handler error: {ex.Message}");
                }
            };

            // 4c. 导航拦截 — 如果页面直接导航到 PDF，捕获该导航
            webView.NavigationStarting += (_, args) =>
            {
                try
                {
                    var uri = args.Uri;
                    Log.Debug($"[OAPDFExport] NavigationStarting: {uri}");
                    // 如果导航目标是 PDF 文件（非 HTML 页面），取消导航并尝试下载
                    if (uri.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ||
                        uri.Contains("exportPdf", StringComparison.OrdinalIgnoreCase) ||
                        uri.Contains("downloadPdf", StringComparison.OrdinalIgnoreCase))
                    {
                        Log.Debug($"[OAPDFExport] PDF navigation detected: {uri}");
                    }
                }
                catch (Exception ex)
                {
                    Log.Debug($"[OAPDFExport] NavigationStarting handler error: {ex.Message}");
                }
            };

            // 5. 导航完成事件 → 注入 JS
            EventHandler<CoreWebView2NavigationCompletedEventArgs>? navHandler = null;
            navHandler = async (_, args) =>
            {
                // 取消订阅，只处理一次
                webView.NavigationCompleted -= navHandler;

                if (!args.IsSuccess)
                {
                    Log.Debug($"[OAPDFExport][DIAG] Navigation FAILED, HTTP error={(int)args.WebErrorStatus}");
                    tcs.TrySetException(new OAPDFExportException(
                        $"PDF 导出：页面加载失败 (HTTP {(int)args.WebErrorStatus})"));
                    return;
                }

                try
                {
                    Log.Debug($"[OAPDFExport][DIAG] Navigation completed successfully, URL={webView.Source}");
                    // 注入 JS 拦截 PDF Blob
                    var js = PdfInterceptJS();
                    Log.Debug($"[OAPDFExport][DIAG] JS script length={js.Length} chars, injecting...");
                    var result = await webView.ExecuteScriptAsync(js);
                    Log.Debug($"[OAPDFExport][DIAG] JS execution completed, result preview={(result?.Length > 200 ? result[..200] : result ?? "null")}");
                }
                catch (Exception ex)
                {
                    Log.Debug($"[OAPDFExport][DIAG] JS execution FAILED: {ex.Message}");
                    tcs.TrySetException(new OAPDFExportException("PDF 导出：JS 注入失败", ex));
                }
            };
            webView.NavigationCompleted += navHandler;

            // 6. 导航到打印页
            webView.Navigate(printURL);

            // 7. 等待结果（带超时）
            var (base64Data, capturedFileName) = await tcs.Task;
            var resolvedFileName = !string.IsNullOrEmpty(capturedFileName) ? capturedFileName : defaultFileName;

            // 清理 base64 字符串：去除空白、换行、可能的 data: 前缀
            base64Data = base64Data.Replace(" ", "").Replace("\n", "").Replace("\r", "").Replace("\t", "");
            if (base64Data.StartsWith("data:"))
            {
                var commaIdx = base64Data.IndexOf(',');
                if (commaIdx >= 0)
                    base64Data = base64Data[(commaIdx + 1)..];
            }

            // 补齐 padding（base64 长度必须是 4 的倍数）
            var padding = (4 - base64Data.Length % 4) % 4;
            if (padding > 0)
                base64Data += new string('=', padding);

            byte[] pdfBytes;
            try
            {
                pdfBytes = Convert.FromBase64String(base64Data);
            }
            catch (FormatException ex)
            {
                var preview = base64Data.Length > 200 ? base64Data[..200] + "..." : base64Data;
                throw new OAPDFExportException(
                    $"PDF 导出：Base64 解码失败（长度={base64Data.Length}，前200字符=[{preview}]）", ex);
            }

            return (pdfBytes, resolvedFileName);
        }
        catch (OAPDFExportException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw new OAPDFExportException($"PDF 导出：超时（{TimeoutSeconds} 秒）");
        }
        catch (Exception ex)
        {
            throw new OAPDFExportException("PDF 导出失败：" + ex.Message, ex);
        }
        finally
        {
            // 8. 清理 COM 资源 — controller/HwndSource 必须在创建它们的 UI 线程上释放。
            // 由于 tcs 使用了 RunContinuationsAsynchronously，此 finally 可能运行在线程池线程，
            // 因此通过 HwndSource 的 Dispatcher 将清理调度回 UI 线程执行
            try
            {
                if (hwndSource != null)
                {
                    var dispatcher = hwndSource.Dispatcher;
                    await dispatcher.InvokeAsync(() =>
                    {
                        try { controller?.Close(); } catch { /* 清理阶段忽略异常 */ }
                        try { hwndSource.Dispose(); } catch { /* 清理阶段忽略异常 */ }
                    });
                }
                else
                {
                    controller?.Close();
                }
            }
            catch { /* 清理阶段忽略异常 */ }

            // 尝试清理专用 UserData 目录（纯文件 I/O，任意线程均可）
            try
            {
                if (userDataFolder != null && Directory.Exists(userDataFolder))
                    Directory.Delete(userDataFolder, recursive: true);
            }
            catch { /* 清理失败不影响主流程 */ }
        }
    }

    /// <summary>
    /// 将 OAService 中的 cookies 注入到 WebView2
    /// </summary>
    private static Task InjectCookiesAsync(CoreWebView2 webView, string baseURL)
    {
        if (!Uri.TryCreate(baseURL, UriKind.Absolute, out var uri))
            throw new OAPDFExportException("PDF 导出：无效的 baseURL");

        var domain = uri.Host;
        var oaCookies = OAService.Shared.Cookies;

        foreach (var (name, value) in oaCookies)
        {
            try
            {
                // 使用 System.Net.Cookie 创建再通过 WebView2 CookieManager 注入
                var netCookie = new System.Net.Cookie(name, value, "/", domain);
                var wvCookie = webView.CookieManager.CreateCookieWithSystemNetCookie(netCookie);
                webView.CookieManager.AddOrUpdateCookie(wvCookie);
            }
            catch (Exception ex)
            {
                Log.Debug($"[OAPDFExport] Cookie 注入失败 name={name}: {ex.Message}");
            }
        }
        return Task.CompletedTask;
    }

    /// <summary>从简单 JSON 中提取指定 key 的 string value</summary>
    private static string ExtractJSONValue(string json, string key)
    {
        var pattern = $"\"{key}\"\\s*:\\s*\"([^\"]*)\"";
        var match = Regex.Match(json, pattern);
        return match.Success ? match.Groups[1].Value : "";
    }

    /// <summary>WebView2 建议文件名中的“通用”名称（未携带 OA 标题时出现），命中则继续 fallback</summary>
    private static readonly HashSet<string> GenericPdfNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "download.pdf", "document.pdf", "export.pdf", "content.pdf",
        "print.pdf", "untitled.pdf", "blob.pdf", "file.pdf", "unknown.pdf", "oa_print.pdf"
    };

    /// <summary>
    /// 解析下载 PDF 的最终文件名。优先级：
    /// 1. WebView2 建议的原始文件名（OA export.js 用 jsPDF.save(标题+'.pdf') 设置的 download 属性）
    /// 2. document.title（如 “关于xxx需求的请示”）
    /// 3. 下载 URI 最后一段（blob: URL 时通常拿不到有效名字）
    /// 4. 从 printURL 解析的默认文件名
    /// 注意：必须在 UI 线程调用（内部调用 ExecuteScriptAsync）
    /// </summary>
    private static async Task<string> ResolveDownloadFileNameAsync(CoreWebView2 webView, string? originalFileName, string dlUri, string fallbackName)
    {
        // 1. 原始建议文件名（即 OA 页面标题.pdf）
        var name = SanitizeFileName(originalFileName ?? "");
        if (!IsGenericPdfName(name))
            return EnsurePdfExtension(name);

        // 2. document.title
        try
        {
            var titleJson = await webView.ExecuteScriptAsync("document.title");
            var title = SanitizeFileName(ParseJsonStringValue(titleJson) ?? "");
            if (!string.IsNullOrWhiteSpace(title) && title != "content")
                return EnsurePdfExtension(title);
        }
        catch (Exception ex)
        {
            Log.Debug($"[OAPDFExport] document.title read failed: {ex.Message}");
        }

        // 3. 下载 URI 最后一段
        try
        {
            var seg = new Uri(dlUri).Segments.LastOrDefault();
            if (!string.IsNullOrEmpty(seg))
            {
                var dlName = SanitizeFileName(Uri.UnescapeDataString(seg));
                if (!IsGenericPdfName(dlName))
                    return EnsurePdfExtension(dlName);
            }
        }
        catch { /* 使用默认名 */ }

        // 4. 默认名（从 printURL 解析）
        return fallbackName;
    }

    /// <summary>清理文件名中的非法字符（Windows 保留字符与控制字符）</summary>
    private static string SanitizeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Where(c => !invalid.Contains(c) && !char.IsControl(c)).ToArray());
        return cleaned.Trim();
    }

    private static bool IsGenericPdfName(string? name)
    {
        return string.IsNullOrWhiteSpace(name) || GenericPdfNames.Contains(name.Trim());
    }

    private static string EnsurePdfExtension(string name)
    {
        return name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? name : name + ".pdf";
    }

    /// <summary>解析 ExecuteScriptAsync 返回的 JSON 字符串（如 "\"标题\"" → 标题）</summary>
    private static string? ParseJsonStringValue(string? json)
    {
        if (string.IsNullOrWhiteSpace(json) || json == "null") return null;
        try
        {
            return JsonSerializer.Deserialize<string>(json);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 触发 PDF 导出的 JS 脚本（简化版）。
    /// 不再尝试通过 JS hook 拦截 Blob；而是触发出后，由原生 DownloadStarting 事件捕获下载文件。
    /// 仅保留：console.log 转发 + seajs/outputPDF 触发 + 错误回报。
    /// </summary>
    private static string PdfInterceptJS()
    {
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
                    chrome.webview.postMessage(JSON.stringify({"__console:": '[' + level + '] ' + msg}));
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
    
        // 触发 PDF 导出 — 由原生 DownloadStarting 捕获下载文件
        (function() {
            function reportError(msg) {
                console.log('[PDF Export] ERROR:', msg);
                try { chrome.webview.postMessage('ERROR:' + msg); } catch(e) {}
            }
    
            if (typeof seajs !== 'undefined') {
                console.log('[PDF Export] Using seajs to trigger export...');
                // seajs 加载超时保护：15s
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
        """;
    }
}
