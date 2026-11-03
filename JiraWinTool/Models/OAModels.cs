namespace JiraWinTool.Models;

/// <summary>OA 错误类型（移植自 Swift OAError）</summary>
public class OAException : Exception
{
    public OAException(string message) : base(message) { }
    public static OAException InvalidURL => new("无效的 OA URL");
    public static OAException InvalidResponse => new("无效的 OA 服务器响应");
    public static OAException HttpError(int code, string msg) => new($"OA HTTP 错误 {code}: {msg}");
    public static OAException LoginFailed(string msg) => new($"OA 登录失败: {msg}");
    public static OAException NotLoggedIn => new("OA 尚未登录");
}

/// <summary>OA 附件信息（移植自 Swift OAAttachment）</summary>
public class OAAttachment
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    /// <summary>SWF 组件 14 位前缀</summary>
    public string Prefix { get; set; } = "";
    /// <summary>addDoc 中的 fdId（32 位）</summary>
    public string FdId { get; set; } = "";
    /// <summary>addDoc 中的 fdFileId（32 位）</summary>
    public string FdFileId { get; set; } = "";
    /// <summary>Swf_AttachmentObject 的 modelName</summary>
    public string ModelName { get; set; } = "";
    /// <summary>Swf_AttachmentObject 的 modelId</summary>
    public string ModelId { get; set; } = "";
    /// <summary>是否为需求模板附件（默认不勾选）</summary>
    public bool IsTemplateAttachment { get; set; }
}

/// <summary>OA 解析结果（移植自 Swift OAParseResult）</summary>
public class OAParseResult
{
    public string Title { get; set; } = "";
    public string Drafter { get; set; } = "";
    public string DraftDept { get; set; } = "";
    public string Content { get; set; } = "";
    public string ApplyNo { get; set; } = "";
    public List<string> RemKeys { get; set; } = new();
    public List<OAAttachment> Attachments { get; set; } = new();
}

/// <summary>OA 附件下载结果（移植自 Swift OADownloadedAttachment）</summary>
public class OADownloadedAttachment
{
    public string Name { get; set; } = "";
    public byte[] Data { get; set; } = Array.Empty<byte>();
    public string MimeType { get; set; } = "application/octet-stream";
}

/// <summary>邮件解析结果</summary>
public class EmailParseResult
{
    public string Subject { get; set; } = "";
    public string From { get; set; } = "";
    public string FromName { get; set; } = "";
    public string Body { get; set; } = "";
    public List<EmailAttachment> Attachments { get; set; } = new();
}

/// <summary>邮件附件信息</summary>
public class EmailAttachment
{
    public string Name { get; set; } = "";
    public byte[] Data { get; set; } = Array.Empty<byte>();
    public string MimeType { get; set; } = "application/octet-stream";
    private bool _isSelected = true;
    public bool IsSelected
    {
        get => _isSelected;
        set => _isSelected = value;
    }
}

/// <summary>登录尝试参数</summary>
public class LoginAttempt
{
    public string Path { get; set; } = "";
    public string UserField { get; set; } = "";
    public string PassField { get; set; } = "";
    public List<(string Key, string Value)> ExtraFields { get; set; } = new();
}

/// <summary>发现的登录表单</summary>
public class DiscoveredLoginForm
{
    public string Action { get; set; } = "";
    public string UserField { get; set; } = "";
    public string PassField { get; set; } = "";
    public List<(string Key, string Value)> HiddenFields { get; set; } = new();
}

/// <summary>登录 POST 结果</summary>
public class LoginPostResult
{
    public int StatusCode { get; set; }
    public string Location { get; set; } = "";
    public string BodySnippet { get; set; } = "";
}
