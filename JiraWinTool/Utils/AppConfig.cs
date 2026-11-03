using CommunityToolkit.Mvvm.ComponentModel;
using Newtonsoft.Json;

namespace JiraWinTool.Utils;

/// <summary>
/// 应用配置（移植自 Swift AppConfig.swift）。
/// 存储位置：exe 同目录/data/config.json；密码用 DPAPI 加密后存储（替代 Keychain）。
/// 任意键值（原 UserDefaults / @AppStorage）通过 GetCustom/SetCustom 访问。
/// </summary>
public partial class AppConfig : ObservableObject
{
    public static AppConfig Shared { get; } = new AppConfig();

    /// <summary>数据目录：exe 同目录下的 data 文件夹，方便分发和查找</summary>
    public static string AppDataDir
    {
        get
        {
            var exeDir = Path.GetDirectoryName(Environment.ProcessPath ?? AppContext.BaseDirectory) ?? ".";
            return Path.Combine(exeDir, "data");
        }
    }

    private static string ConfigPath => Path.Combine(AppDataDir, "config.json");

    // MARK: - 序列化模型

    private class ConfigData
    {
        public string JiraUrl { get; set; } = "http://jira.sinosafe.com.cn";
        public string JiraUser { get; set; } = "wurunlong";
        public string JiraPasswordProtected { get; set; } = "";
        public string WebdavUrl { get; set; } = "";
        public string WebdavUser { get; set; } = "";
        public string WebdavRemotePath { get; set; } = "/jira-favorites.json";
        public string WebdavPasswordProtected { get; set; } = "";
        public bool AutoSyncEnabled { get; set; }
        public int AutoSyncInterval { get; set; } = 30;
        public DateTime? LastSyncTime { get; set; }
        public string DbPath { get; set; } = "";
        public Dictionary<string, string> Custom { get; set; } = new();
    }

    private ConfigData _data = new();
    private string? _jiraPassword;
    private string? _webdavPassword;

    // MARK: - 可绑定属性

    public string JiraURL
    {
        get => _data.JiraUrl;
        set { if (_data.JiraUrl != value) { _data.JiraUrl = value; OnPropertyChanged(); Save(); } }
    }

    public string JiraUser
    {
        get => _data.JiraUser;
        set { if (_data.JiraUser != value) { _data.JiraUser = value; OnPropertyChanged(); Save(); } }
    }

    /// <summary>密码延迟加载：只在首次访问时才解密读取</summary>
    public string JiraPassword
    {
        get
        {
            _jiraPassword ??= SecureStorage.Unprotect(_data.JiraPasswordProtected);
            return _jiraPassword;
        }
    }

    public string WebdavURL
    {
        get => _data.WebdavUrl;
        set { if (_data.WebdavUrl != value) { _data.WebdavUrl = value; OnPropertyChanged(); Save(); } }
    }

    public string WebdavUser
    {
        get => _data.WebdavUser;
        set { if (_data.WebdavUser != value) { _data.WebdavUser = value; OnPropertyChanged(); Save(); } }
    }

    public string WebdavRemotePath
    {
        get => _data.WebdavRemotePath;
        set { if (_data.WebdavRemotePath != value) { _data.WebdavRemotePath = value; OnPropertyChanged(); Save(); } }
    }

    public string WebdavPassword
    {
        get
        {
            _webdavPassword ??= SecureStorage.Unprotect(_data.WebdavPasswordProtected);
            return _webdavPassword;
        }
    }

    public bool AutoSyncEnabled
    {
        get => _data.AutoSyncEnabled;
        set { if (_data.AutoSyncEnabled != value) { _data.AutoSyncEnabled = value; OnPropertyChanged(); Save(); } }
    }

    /// <summary>自动同步间隔（分钟），默认 30</summary>
    public int AutoSyncInterval
    {
        get => _data.AutoSyncInterval;
        set { if (_data.AutoSyncInterval != value) { _data.AutoSyncInterval = value; OnPropertyChanged(); Save(); } }
    }

    /// <summary>数据库文件自定义路径（空字符串表示使用默认路径）</summary>
    public string DbPath
    {
        get => _data.DbPath;
        set { if (_data.DbPath != value) { _data.DbPath = value; OnPropertyChanged(); Save(); } }
    }

    public DateTime? LastSyncTime
    {
        get => _data.LastSyncTime;
        set { if (_data.LastSyncTime != value) { _data.LastSyncTime = value; OnPropertyChanged(); Save(); } }
    }

    /// <summary>可选的同步频率（分钟）</summary>
    public static readonly (string Label, int Minutes)[] SyncIntervalOptions =
    {
        ("5 分钟", 5),
        ("10 分钟", 10),
        ("15 分钟", 15),
        ("30 分钟", 30),
        ("1 小时", 60),
        ("2 小时", 120),
        ("6 小时", 360),
        ("12 小时", 720),
    };

    public bool IsWebdavConfigured =>
        !string.IsNullOrEmpty(WebdavURL) && !string.IsNullOrEmpty(WebdavUser) && !string.IsNullOrEmpty(WebdavPassword);

    // MARK: - 密码保存

    public void SavePassword(string password)
    {
        _jiraPassword = password;
        _data.JiraPasswordProtected = SecureStorage.Protect(password);
        Save();
    }

    public void SaveWebdavPassword(string password)
    {
        _webdavPassword = password;
        _data.WebdavPasswordProtected = SecureStorage.Protect(password);
        Save();
    }

    // MARK: - 任意键值存储（替代 UserDefaults / @AppStorage）

    public string GetCustom(string key, string defaultValue = "")
    {
        return _data.Custom.TryGetValue(key, out var v) ? v : defaultValue;
    }

    public void SetCustom(string key, string value)
    {
        _data.Custom[key] = value;
        Save();
    }

    public bool GetCustomBool(string key, bool defaultValue = false)
    {
        if (_data.Custom.TryGetValue(key, out var v) && bool.TryParse(v, out var b)) return b;
        return defaultValue;
    }

    public void SetCustomBool(string key, bool value)
    {
        _data.Custom[key] = value ? "true" : "false";
        Save();
    }

    // MARK: - 持久化

    private AppConfig()
    {
        Load();
    }

    private void Load()
    {
        try
        {
            Directory.CreateDirectory(AppDataDir);
            if (File.Exists(ConfigPath))
            {
                var json = File.ReadAllText(ConfigPath);
                _data = JsonConvert.DeserializeObject<ConfigData>(json) ?? new ConfigData();
            }
        }
        catch
        {
            _data = new ConfigData();
        }
    }

    private readonly object _saveLock = new();

    public void Save()
    {
        lock (_saveLock)
        {
            try
            {
                Directory.CreateDirectory(AppDataDir);
                var json = JsonConvert.SerializeObject(_data, Formatting.Indented);
                File.WriteAllText(ConfigPath, json);
            }
            catch { }
        }
    }
}
