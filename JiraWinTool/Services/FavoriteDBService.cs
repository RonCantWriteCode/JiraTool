using JiraWinTool.Models;
using JiraWinTool.Utils;
using Microsoft.Data.Sqlite;

namespace JiraWinTool.Services;

/// <summary>
/// SQLite 数据库服务（移植自 Swift FavoriteDBService.swift，改用 Microsoft.Data.Sqlite）。
/// 默认路径：%AppData%/JiraWinTool/jira_favorites.sqlite
/// </summary>
public class FavoriteDBService
{
    public static FavoriteDBService Shared { get; } = new FavoriteDBService();

    private const string DbFileName = "jira_favorites.sqlite";
    private string? _customDBPath;
    private SqliteConnection? _db;
    private readonly object _lock = new();

    private static readonly DateTime UnixEpoch = new(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    private FavoriteDBService()
    {
        var dbPath = AppConfig.Shared.DbPath;
        if (!string.IsNullOrEmpty(dbPath))
            _customDBPath = dbPath;

        OpenDatabase();
        CreateTable();
    }

    // MARK: - 数据库初始化

    private void OpenDatabase()
    {
        var path = GetDBPath();
        try
        {
            _db = new SqliteConnection($"Data Source={path}");
            _db.Open();
        }
        catch (Exception ex)
        {
            Log.Debug($"❌ 无法打开 SQLite 数据库: {ex.Message}");
        }
    }

    private string GetDBPath()
    {
        if (_customDBPath != null)
        {
            var dir = Path.GetDirectoryName(_customDBPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            return _customDBPath;
        }
        var appDir = AppConfig.AppDataDir;
        Directory.CreateDirectory(appDir);
        return Path.Combine(appDir, DbFileName);
    }

    /// <summary>获取当前数据库路径字符串</summary>
    public string GetCurrentPath() => GetDBPath();

    /// <summary>
    /// 设置自定义数据库路径并重新打开
    /// </summary>
    /// <param name="path">新的数据库文件路径，null 表示恢复默认</param>
    /// <param name="migrateData">是否将旧数据复制到新位置</param>
    /// <returns>操作结果消息</returns>
    public string SetCustomPath(string? path, bool migrateData = false)
    {
        lock (_lock)
        {
            var oldPath = GetDBPath();

            // 关闭旧连接
            try { _db?.Close(); _db?.Dispose(); } catch { }
            _db = null;

            _customDBPath = path;

            if (migrateData)
            {
                var newPath = GetDBPath();
                var dir = Path.GetDirectoryName(newPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                if (File.Exists(oldPath) && !string.Equals(oldPath, newPath, StringComparison.OrdinalIgnoreCase))
                {
                    try { File.Copy(oldPath, newPath, overwrite: true); } catch { }
                }
            }

            OpenDatabase();
            CreateTable();
        }

        return $"✅ 数据库路径已更新: {GetDBPath()}";
    }

    private void CreateTable()
    {
        const string sql = """
        CREATE TABLE IF NOT EXISTS favorites (
            id TEXT PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            issueType TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            reporter TEXT NOT NULL DEFAULT '',
            assignee TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL DEFAULT '',
            updated TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            addedAt REAL NOT NULL,
            isPinned INTEGER NOT NULL DEFAULT 0,
            pinnedAt REAL,
            isArchived INTEGER NOT NULL DEFAULT 0,
            qianbaoNo TEXT NOT NULL DEFAULT '',
            qianbaoLink TEXT NOT NULL DEFAULT '',
            modifiedAt REAL NOT NULL DEFAULT 0
        );
        """;
        ExecuteSQL(sql);

        // 数据库迁移：为旧表添加 pinnedAt 列
        MigrateAddColumnIfNeeded("pinnedAt", "REAL");
        // 数据库迁移：为旧表添加 modifiedAt 列，并用 addedAt 回填历史数据
        if (MigrateAddColumnIfNeeded("modifiedAt", "REAL NOT NULL DEFAULT 0"))
        {
            ExecuteSQL("UPDATE favorites SET modifiedAt = addedAt WHERE modifiedAt = 0;");
        }

        // 创建索引
        ExecuteSQL("CREATE INDEX IF NOT EXISTS idx_favorites_key ON favorites(key);");
        ExecuteSQL("CREATE INDEX IF NOT EXISTS idx_favorites_isPinned ON favorites(isPinned);");
        ExecuteSQL("CREATE INDEX IF NOT EXISTS idx_favorites_pinnedAt ON favorites(pinnedAt);");
        ExecuteSQL("CREATE INDEX IF NOT EXISTS idx_favorites_isArchived ON favorites(isArchived);");
    }

    /// <summary>通用迁移：若指定列不存在则添加。返回 true 表示本次确实新增了该列。</summary>
    private bool MigrateAddColumnIfNeeded(string column, string definition)
    {
        lock (_lock)
        {
            if (_db == null) return false;

            var hasColumn = false;
            using (var cmd = _db.CreateCommand())
            {
                cmd.CommandText = "PRAGMA table_info(favorites);";
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    if (reader.GetString(1) == column)
                    {
                        hasColumn = true;
                        break;
                    }
                }
            }

            if (hasColumn) return false;
            Log.Debug($"📦 数据库迁移：添加 {column} 列...");
            ExecuteSQL($"ALTER TABLE favorites ADD COLUMN {column} {definition};");
            Log.Debug($"✅ 数据库迁移完成：{column}");
            return true;
        }
    }

    private void ExecuteSQL(string sql)
    {
        lock (_lock)
        {
            if (_db == null) return;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = sql;
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                Log.Debug($"❌ SQL 执行失败: {ex.Message}");
            }
        }
    }

    // MARK: - CRUD 操作

    /// <summary>插入一条收藏（INSERT OR REPLACE）</summary>
    public void Insert(FavoriteJira item)
    {
        lock (_lock)
        {
            if (_db == null) return;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = """
                INSERT OR REPLACE INTO favorites
                (id, key, issueType, summary, reporter, assignee, status, created, updated, url, addedAt, isPinned, pinnedAt, isArchived, qianbaoNo, qianbaoLink, modifiedAt)
                VALUES ($id, $key, $issueType, $summary, $reporter, $assignee, $status, $created, $updated, $url, $addedAt, $isPinned, $pinnedAt, $isArchived, $qianbaoNo, $qianbaoLink, $modifiedAt);
                """;
                cmd.Parameters.AddWithValue("$id", item.Id);
                cmd.Parameters.AddWithValue("$key", item.Key);
                cmd.Parameters.AddWithValue("$issueType", item.IssueType);
                cmd.Parameters.AddWithValue("$summary", item.Summary);
                cmd.Parameters.AddWithValue("$reporter", item.Reporter);
                cmd.Parameters.AddWithValue("$assignee", item.Assignee);
                cmd.Parameters.AddWithValue("$status", item.Status);
                cmd.Parameters.AddWithValue("$created", item.Created);
                cmd.Parameters.AddWithValue("$updated", item.Updated);
                cmd.Parameters.AddWithValue("$url", item.Url);
                cmd.Parameters.AddWithValue("$addedAt", ToUnixSeconds(item.AddedAt));
                cmd.Parameters.AddWithValue("$isPinned", item.IsPinned ? 1 : 0);
                if (item.PinnedAt is DateTime pinnedAt)
                    cmd.Parameters.AddWithValue("$pinnedAt", ToUnixSeconds(pinnedAt));
                else
                    cmd.Parameters.AddWithValue("$pinnedAt", DBNull.Value);
                cmd.Parameters.AddWithValue("$isArchived", item.IsArchived ? 1 : 0);
                cmd.Parameters.AddWithValue("$qianbaoNo", item.QianbaoNo);
                cmd.Parameters.AddWithValue("$qianbaoLink", item.QianbaoLink);
                cmd.Parameters.AddWithValue("$modifiedAt", ToUnixSeconds(item.ModifiedAt));
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                Log.Debug($"❌ 插入失败: {ex.Message}");
            }
        }
    }

    /// <summary>加载全部收藏（按收藏时间倒序）</summary>
    public List<FavoriteJira> LoadAll()
    {
        lock (_lock)
        {
            var items = new List<FavoriteJira>();
            if (_db == null) return items;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "SELECT id, key, issueType, summary, reporter, assignee, status, created, updated, url, addedAt, isPinned, pinnedAt, isArchived, qianbaoNo, qianbaoLink, modifiedAt FROM favorites ORDER BY addedAt DESC;";
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    items.Add(ReadRow(reader));
                }
            }
            catch (Exception ex)
            {
                Log.Debug($"❌ 查询失败: {ex.Message}");
            }
            return items;
        }
    }

    /// <summary>更新置顶状态</summary>
    public void UpdatePinned(string id, bool isPinned, DateTime? pinnedAt = null)
    {
        lock (_lock)
        {
            if (_db == null) return;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "UPDATE favorites SET isPinned = $isPinned, pinnedAt = $pinnedAt WHERE id = $id;";
                cmd.Parameters.AddWithValue("$isPinned", isPinned ? 1 : 0);
                if (pinnedAt is DateTime pa)
                    cmd.Parameters.AddWithValue("$pinnedAt", ToUnixSeconds(pa));
                else
                    cmd.Parameters.AddWithValue("$pinnedAt", DBNull.Value);
                cmd.Parameters.AddWithValue("$id", id);
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                Log.Debug($"❌ 更新置顶失败: {ex.Message}");
            }
        }
    }

    /// <summary>更新归档状态</summary>
    public void UpdateArchived(string id, bool isArchived)
    {
        lock (_lock)
        {
            if (_db == null) return;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "UPDATE favorites SET isArchived = $isArchived WHERE id = $id;";
                cmd.Parameters.AddWithValue("$isArchived", isArchived ? 1 : 0);
                cmd.Parameters.AddWithValue("$id", id);
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                Log.Debug($"❌ 更新归档失败: {ex.Message}");
            }
        }
    }

    /// <summary>更新整条记录（刷新时使用）</summary>
    public void Update(FavoriteJira item) => Insert(item); // INSERT OR REPLACE

    /// <summary>删除一条记录</summary>
    public void Delete(string id)
    {
        lock (_lock)
        {
            if (_db == null) return;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "DELETE FROM favorites WHERE id = $id;";
                cmd.Parameters.AddWithValue("$id", id);
                cmd.ExecuteNonQuery();
            }
            catch { }
        }
    }

    public void Delete(HashSet<string> ids)
    {
        lock (_lock)
        {
            ExecuteSQL("BEGIN TRANSACTION;");
            foreach (var id in ids) Delete(id);
            ExecuteSQL("COMMIT;");
        }
    }

    /// <summary>检查 key 是否已存在</summary>
    public bool Exists(string key)
    {
        lock (_lock)
        {
            if (_db == null) return false;
            try
            {
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "SELECT COUNT(*) FROM favorites WHERE key = $key;";
                cmd.Parameters.AddWithValue("$key", key);
                var count = Convert.ToInt32(cmd.ExecuteScalar());
                return count > 0;
            }
            catch { return false; }
        }
    }

    public void ReplaceAll(List<FavoriteJira> items)
    {
        lock (_lock)
        {
            ExecuteSQL("BEGIN TRANSACTION;");
            ExecuteSQL("DELETE FROM favorites;");
            foreach (var item in items) Insert(item);
            ExecuteSQL("COMMIT;");
        }
    }

    // MARK: - 辅助

    private static double ToUnixSeconds(DateTime dt) =>
        (dt.ToUniversalTime() - UnixEpoch).TotalSeconds;

    private static DateTime FromUnixSeconds(double seconds) =>
        UnixEpoch.AddSeconds(seconds).ToLocalTime();

    private static FavoriteJira ReadRow(SqliteDataReader reader)
    {
        string Col(int idx) => reader.IsDBNull(idx) ? "" : reader.GetString(idx);

        var addedAtSeconds = reader.IsDBNull(10) ? 0 : reader.GetDouble(10);
        var modifiedAtSeconds = reader.IsDBNull(16) ? 0 : reader.GetDouble(16);

        return new FavoriteJira
        {
            Id = Col(0),
            Key = Col(1),
            IssueType = Col(2),
            Summary = Col(3),
            Reporter = Col(4),
            Assignee = Col(5),
            Status = Col(6),
            Created = Col(7),
            Updated = Col(8),
            Url = Col(9),
            AddedAt = FromUnixSeconds(addedAtSeconds),
            IsPinned = !reader.IsDBNull(11) && reader.GetInt32(11) != 0,
            PinnedAt = reader.IsDBNull(12) ? null : FromUnixSeconds(reader.GetDouble(12)),
            IsArchived = !reader.IsDBNull(13) && reader.GetInt32(13) != 0,
            QianbaoNo = Col(14),
            QianbaoLink = Col(15),
            // 兼容旧库：modifiedAt 为 0 或缺失时回退到 addedAt
            ModifiedAt = modifiedAtSeconds > 0 ? FromUnixSeconds(modifiedAtSeconds) : FromUnixSeconds(addedAtSeconds)
        };
    }
}
