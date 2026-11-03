import Foundation

/// 调试日志。
///
/// 仅在 DEBUG 构建中通过标准输出打印，Release 构建中为空实现，
/// 且由于参数是 `@autoclosure`，字符串拼接在 Release 下根本不会被求值，
/// 因此不会有任何性能开销，也不会把调试信息（含掩码后的凭据等）带进正式包。
///
/// 用法与 `print` 相同：`debugLog("[OAService] 登录成功")`。
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
