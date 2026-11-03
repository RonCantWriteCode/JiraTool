using System.Security.Cryptography;
using System.Text;

namespace JiraWinTool.Utils;

/// <summary>
/// 密码安全存储（替代 macOS Keychain）。
/// 使用 DPAPI（Data Protection API）按当前用户加密，密文 base64 存于 config.json。
/// </summary>
public static class SecureStorage
{
    public static string Protect(string plainText)
    {
        if (string.IsNullOrEmpty(plainText)) return "";
        var data = Encoding.UTF8.GetBytes(plainText);
        var protectedData = ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(protectedData);
    }

    public static string Unprotect(string protectedBase64)
    {
        if (string.IsNullOrEmpty(protectedBase64)) return "";
        try
        {
            var data = Convert.FromBase64String(protectedBase64);
            var plain = ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return "";
        }
    }
}
