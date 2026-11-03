using System.Text;
using System.Windows;
using JiraWinTool.Utils;

namespace JiraWinTool;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // 注册 GB18030 等代码页编码（OA 系统页面需要）
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

        // 触发配置目录创建与配置加载
        _ = AppConfig.Shared;

        // 启动即初始化收藏服务（含 WebDAV 自动同步定时器），而非等收藏页首次打开
        _ = Services.FavoriteService.Shared;

        base.OnStartup(e);
    }
}
