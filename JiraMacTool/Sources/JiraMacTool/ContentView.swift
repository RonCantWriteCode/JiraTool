import SwiftUI

// MARK: - 通知名称扩展
extension Notification.Name {
    static let openSyncConfig = Notification.Name("openSyncConfig")
}

// MARK: - 配置子项枚举
enum ConfigSubItem: String, CaseIterable, Identifiable {
    case jiraConfig = "Jira配置"
    case syncConfig = "同步配置"
    case dbConfig = "数据库配置"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .jiraConfig: return "server.rack"
        case .syncConfig: return "arrow.triangle.2.circlepath"
        case .dbConfig: return "externaldrive"
        }
    }
}

// MARK: - 收藏Jira 子项枚举
enum FavoriteSubItem: String, CaseIterable, Identifiable {
    case selfJira = "Self-Jira"
    case versionReq = "版本需求"
    case publish = "publish"
    case dc = "DC"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .selfJira: return "person.crop.circle"
        case .versionReq: return "flag"
        case .publish: return "paperplane"
        case .dc: return "externaldrive.connected.to.line.below"
        }
    }

    var storageKey: String {
        switch self {
        case .selfJira: return "self_jira_jql"
        case .versionReq: return "version_req_jql"
        case .publish: return "publish_req_jql"
        case .dc: return "dc_req_jql"
        }
    }

    var defaultJQL: String {
        switch self {
        case .selfJira:
            return "assignee in (currentUser()) AND status != Closed AND status != Done AND project = REQ ORDER BY createdDate DESC"
        case .versionReq:
            return "预计修复时间 = 2026-05-19 AND 系统名称（开发） in (理赔条线, 电销条线) AND status != Closed ORDER BY cf[11923] ASC, cf[10126] ASC, cf[10106] DESC"
        case .publish:
            return "申请发布时间 = 2026-04-23 AND 系统 in (B理赔服务类, \"D05 新核心诉讼系统\") AND status != Closed AND project = 生产环境系统发布 ORDER BY createdDate DESC"
        case .dc:
            return "createdDate >= 2026-01-01 AND status changed by currentUser() AND project = 生产数据配置变更申请 ORDER BY createdDate DESC"
        }
    }
}

// MARK: - 侧边栏选中项（统一管理普通菜单、配置子项、收藏子项、不常用子项的选中状态）
enum SidebarSelection: Hashable {
    case menu(SidebarItem)
    case configSub(ConfigSubItem)
    case favoriteSub(FavoriteSubItem)
    case infrequentSub(InfrequentSubItem)
}

// MARK: - 不常用功能子项枚举
enum InfrequentSubItem: String, CaseIterable, Identifiable {
    case excel = "Excel导出"
    case notice = "通知生成"
    case updateField = "字段更新"
    case docGen = "文档生成"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .excel: return "tablecells"
        case .notice: return "bell"
        case .updateField: return "pencil"
        case .docGen: return "doc.text"
        }
    }
}

// MARK: - 侧边栏主菜单项枚举（不含配置和不常用，它们单独用 DisclosureGroup 处理）
enum SidebarItem: String, CaseIterable, Identifiable {
    case oaCreateReq = "OA创建REQ"
    case emailCreateReq = "邮件创建REQ"
    case oaProcessComplete = "OA流程完成"
    case publish = "创建发布"
    case version = "版本管理"
    case favorite = "收藏Jira"
    case packageDMG = "打包DMG"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .publish: return "arrow.up.circle"
        case .version: return "tag"
        case .favorite: return "star"
        case .oaCreateReq: return "link.badge.plus"
        case .emailCreateReq: return "envelope.badge"
        case .oaProcessComplete: return "checkmark.circle"
        case .packageDMG: return "shippingbox"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarSelection? = .menu(.oaCreateReq)
    @State private var configExpanded: Bool = false
    @State private var infrequentExpanded: Bool = false
    @State private var favoriteExpanded: Bool = true
    @State private var appVersion: String = ""
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // 普通菜单项（收藏Jira 展开为 DisclosureGroup，包含子菜单）
                ForEach(SidebarItem.allCases) { item in
                    if item == .favorite {
                        DisclosureGroup(isExpanded: $favoriteExpanded) {
                            ForEach(FavoriteSubItem.allCases) { subItem in
                                Label(subItem.rawValue, systemImage: subItem.icon)
                                    .tag(SidebarSelection.favoriteSub(subItem))
                            }
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .tag(SidebarSelection.menu(item))
                        }
                    } else {
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(SidebarSelection.menu(item))
                    }
                }
                
                // 配置菜单（可折叠，包含二级子项）
                DisclosureGroup(isExpanded: $configExpanded) {
                    ForEach(ConfigSubItem.allCases) { subItem in
                        Label(subItem.rawValue, systemImage: subItem.icon)
                            .tag(SidebarSelection.configSub(subItem))
                    }
                } label: {
                    Label("配置", systemImage: "gearshape")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            configExpanded.toggle()
                        }
                }

                // 不常用菜单（可折叠，包含二级子项）
                DisclosureGroup(isExpanded: $infrequentExpanded) {
                    ForEach(InfrequentSubItem.allCases) { subItem in
                        Label(subItem.rawValue, systemImage: subItem.icon)
                            .tag(SidebarSelection.infrequentSub(subItem))
                    }
                } label: {
                    Label("不常用", systemImage: "ellipsis.circle")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            infrequentExpanded.toggle()
                        }
                }
            }
            .navigationTitle("Jira工具")
            .frame(minWidth: 150)
            .onReceive(NotificationCenter.default.publisher(for: .openSyncConfig)) { _ in
                selection = .configSub(.syncConfig)
                configExpanded = true
            }
            .onAppear {
                selection = .menu(.oaCreateReq)
                if appVersion.isEmpty {
                    appVersion = VersionManager.shared.getCurrentVersion()
                }
            }
        } detail: {
            detailView
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay(
            ZStack {
                VStack {
                    Spacer()
                    HStack {
                        if !appVersion.isEmpty {
                            Text("v\(appVersion)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                        }
                        Spacer()
                    }
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                }
            }
        )
    }
    
    // MARK: - 详细视图
    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .menu(let item):
            switch item {
            case .publish:
                PublishView()
            case .version:
                VersionView()
            case .favorite:
                FavoriteView()
            case .oaCreateReq:
                OACreateReqView()
            case .emailCreateReq:
                EmailCreateReqView()
            case .oaProcessComplete:
                OAProcessCompleteView()
            case .packageDMG:
                PackageDMGView()
            }
        case .configSub(let subItem):
            switch subItem {
            case .jiraConfig:
                JiraConfigView()
            case .syncConfig:
                SyncConfigView()
            case .dbConfig:
                DBConfigView()
            }
        case .favoriteSub(let subItem):
            SelfJiraView(
                title: subItem.rawValue,
                storageKey: subItem.storageKey,
                defaultJQL: subItem.defaultJQL,
                regularVersionField: {
                    switch subItem {
                    case .versionReq: return "预计修复时间"
                    case .publish: return "申请发布时间"
                    default: return nil
                    }
                }(),
                useTableLayout: subItem == .versionReq
            )
            .id(subItem)
        case .infrequentSub(let subItem):
            switch subItem {
            case .excel:
                ExcelExportView()
            case .notice:
                NoticeView()
            case .updateField:
                UpdateFieldView()
            case .docGen:
                DocGenView()
            }
        case .none:
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.blue.opacity(0.2), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 120, height: 120)
                        .blur(radius: 10)
                    
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 50, weight: .light))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
                
                VStack(spacing: 8) {
                    Text("Jira 效率工具")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("请在左侧选择需要的功能以开始")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}