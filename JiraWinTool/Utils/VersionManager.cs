namespace JiraWinTool.Utils;

/// <summary>
/// 应用版本号管理（移植自 Swift VersionManager.swift）。
/// 版本号格式 "{yyyy-MM-dd}-NN"，按日从 01 递增，记录存 version.txt（每行 "date,version"）。
/// </summary>
public class VersionManager
{
    public static VersionManager Shared { get; } = new VersionManager();

    private readonly string _versionFilePath;

    private VersionManager()
    {
        var appDir = AppConfig.AppDataDir;
        Directory.CreateDirectory(appDir);
        _versionFilePath = Path.Combine(appDir, "version.txt");
    }

    /// <summary>获取当前版本号</summary>
    public string GetCurrentVersion()
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd");

        if (File.Exists(_versionFilePath))
        {
            var lines = ReadLines();
            for (int i = lines.Count - 1; i >= 0; i--)
            {
                var parts = lines[i].Split(',');
                if (parts.Length == 2 && parts[0] == today)
                    return parts[1];
            }
        }

        return GenerateNewVersion(today);
    }

    private string GenerateNewVersion(string date)
    {
        var newVersion = $"{date}-01";
        SaveVersion(date, newVersion);
        return newVersion;
    }

    /// <summary>递增版本号</summary>
    public string IncrementVersion()
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd");

        if (File.Exists(_versionFilePath))
        {
            var lines = ReadLines();
            for (int i = lines.Count - 1; i >= 0; i--)
            {
                var parts = lines[i].Split(',');
                if (parts.Length == 2 && parts[0] == today)
                {
                    // 忠实移植 Swift 版逻辑：按 "-" 拆分判断段数==2（当前版本格式 "yyyy-MM-dd-NN"
                    // 拆分为 4 段，故此分支实际不会命中，总是走 generateNewVersion —— 与原版行为一致）
                    var versionParts = parts[1].Split('-');
                    if (versionParts.Length == 2 && int.TryParse(versionParts[1], out var currentSeq))
                    {
                        var newVersion = $"{today}-{currentSeq + 1:D2}";
                        SaveVersion(today, newVersion);
                        return newVersion;
                    }
                }
            }
        }

        return GenerateNewVersion(today);
    }

    private void SaveVersion(string date, string version)
    {
        var lines = ReadLines();
        var updated = new List<string>();
        var dateFound = false;

        foreach (var line in lines)
        {
            var parts = line.Split(',');
            if (parts.Length == 2 && parts[0] == date)
            {
                updated.Add($"{date},{version}");
                dateFound = true;
            }
            else
            {
                updated.Add(line);
            }
        }

        if (!dateFound)
            updated.Add($"{date},{version}");

        try { File.WriteAllLines(_versionFilePath, updated); } catch { }
    }

    private List<string> ReadLines()
    {
        try
        {
            if (!File.Exists(_versionFilePath)) return new List<string>();
            return File.ReadAllLines(_versionFilePath)
                       .Where(l => !string.IsNullOrWhiteSpace(l))
                       .ToList();
        }
        catch { return new List<string>(); }
    }
}
