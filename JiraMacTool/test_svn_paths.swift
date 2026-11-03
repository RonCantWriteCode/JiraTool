import Foundation

// 临时诊断脚本：查询多个 PUBLISH 工单的 SVN 路径
// 使用方法：在终端运行 swift test_svn_paths.swift

// 这里列出不同系统的 PUBLISH 工单号（你需要替换成实际的）
let publishKeys = [
    "PUBLISH-7248",  // SCLM 或其他系统
    // 添加更多不同系统的 PUBLISH 工单号
]

print("请提供以下系统的 PUBLISH 工单号：")
print("- SCLM（自助理赔中台）")
print("- RCLM（意健险理赔）")
print("- REGIST（报案微服务）")
print("- ANTIFRAUD（反欺诈）")
print("- WORKBENCH（工作台）")
print("- CLM-COMMON-SERVICE（理赔公共服务）")
print("- TPMS（第三方管理服务）")
print("- CSS（调度微服务）")
print("- SHARE（理赔核心SHARE）")
print("- LAW（诉讼系统）")
print("- ZZ（增值服务）")
print("- ZZUSER（增值服务-会员系统）")
print("- PVS（精友视频系统）")
print("")
print("提供后我可以直接查询并更新 getSvnLocation 配置。")
