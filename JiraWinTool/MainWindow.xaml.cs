using System.Windows;
using System.Windows.Controls;
using JiraWinTool.Utils;

namespace JiraWinTool;

/// <summary>
/// 收藏 Jira 子项元数据（移植自 Swift ContentView.swift 的 FavoriteSubItem）
/// </summary>
public record FavoriteSubItemInfo(
    string Title,
    string StorageKey,
    string DefaultJql,
    string? RegularVersionField,
    bool UseTableLayout)
{
    public static readonly FavoriteSubItemInfo SelfJira = new(
        "Self-Jira",
        "self_jira_jql",
        "assignee in (currentUser()) AND status != Closed AND status != Done AND project = REQ ORDER BY createdDate DESC",
        null,
        false);

    public static readonly FavoriteSubItemInfo VersionReq = new(
        "版本需求",
        "version_req_jql",
        "预计修复时间 = 2026-05-19 AND 系统名称（开发） in (理赔条线, 电销条线) AND status != Closed ORDER BY cf[11923] ASC, cf[10126] ASC, cf[10106] DESC",
        "预计修复时间",
        true);

    public static readonly FavoriteSubItemInfo Publish = new(
        "publish",
        "publish_req_jql",
        "申请发布时间 = 2026-04-23 AND 系统 in (B理赔服务类, \"D05 新核心诉讼系统\") AND status != Closed AND project = 生产环境系统发布 ORDER BY createdDate DESC",
        "申请发布时间",
        false);

    public static readonly FavoriteSubItemInfo Dc = new(
        "DC",
        "dc_req_jql",
        "createdDate >= 2026-01-01 AND status changed by currentUser() AND project = 生产数据配置变更申请 ORDER BY createdDate DESC",
        null,
        false);
}

public partial class MainWindow : Window
{
    /// <summary>页面实例缓存（保持页面状态，切换不丢失）</summary>
    private readonly Dictionary<string, UserControl> _pageCache = new();

    public MainWindow()
    {
        InitializeComponent();
        VersionText.Text = "v" + VersionManager.Shared.GetCurrentVersion();

        Loaded += (_, _) =>
        {
            // 默认选中「收藏Jira」
            SelectTreeViewItem(NavTree, "favorite");
            Navigate("favorite");
        };
    }

    private void NavTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (e.NewValue is TreeViewItem item && item.Tag is string tag)
        {
            Navigate(tag);
        }
    }

    private void Navigate(string tag)
    {
        if (tag == "config" || tag == "infrequent") return; // 父节点无页面

        try
        {
            if (!_pageCache.TryGetValue(tag, out var page))
            {
                page = CreatePage(tag);
                if (page == null) return;
                _pageCache[tag] = page;
            }
            PageContent.Content = page;
        }
        catch (Exception ex)
        {
            // 页面初始化失败时清除缓存，防止脏状态阻断后续导航
            _pageCache.Remove(tag);
            System.Diagnostics.Debug.WriteLine($"[Navigate] 页面加载失败 (tag={tag}): {ex}");
        }
    }

    private static UserControl? CreatePage(string tag) => tag switch
    {
        "favorite" => new Views.FavoriteView(),
        "fav:selfJira" => new Views.JiraQueryView(FavoriteSubItemInfo.SelfJira),
        "fav:versionReq" => new Views.JiraQueryView(FavoriteSubItemInfo.VersionReq),
        "fav:publish" => new Views.JiraQueryView(FavoriteSubItemInfo.Publish),
        "fav:dc" => new Views.JiraQueryView(FavoriteSubItemInfo.Dc),
        "publish" => new Views.PublishView(),
        "version" => new Views.VersionView(),
        "excel" => new Views.ExcelExportView(),
        "notice" => new Views.NoticeView(),
        "updateField" => new Views.UpdateFieldView(),
        "docGen" => new Views.DocGenView(),
        "oaCreateReq" => new Views.OACreateReqView(),
        "emailCreateReq" => new Views.EmailCreateReqView(),
        "oaProcessComplete" => new Views.OAProcessCompleteView(),
        "cfg:jira" => new Views.JiraConfigView(),
        "cfg:sync" => new Views.SyncConfigView(),
        "cfg:db" => new Views.DBConfigView(),
        _ => null
    };

    /// <summary>供其他模块跳转「同步配置」页（对应 Swift 的 openSyncConfig 通知）</summary>
    public void OpenSyncConfig()
    {
        SelectTreeViewItem(NavTree, "cfg:sync");
        Navigate("cfg:sync");
    }

    private static void SelectTreeViewItem(ItemsControl parent, string tag)
    {
        foreach (var obj in parent.Items)
        {
            if (parent.ItemContainerGenerator.ContainerFromItem(obj) is TreeViewItem tvi)
            {
                if (tvi.Tag as string == tag)
                {
                    tvi.IsSelected = true;
                    tvi.BringIntoView();
                    return;
                }
                if (tvi.Items.Count > 0)
                {
                    // 强制生成子容器
                    tvi.ApplyTemplate();
                    SelectTreeViewItem(tvi, tag);
                }
            }
        }
    }
}
