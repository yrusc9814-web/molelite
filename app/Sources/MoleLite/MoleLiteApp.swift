import SwiftUI

// MARK: - 侧边栏

enum SidebarSection: String, CaseIterable, Identifiable {
    case clean
    case analyze
    case uninstall
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "清理"
        case .analyze: return "磁盘分析"
        case .uninstall: return "卸载"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .clean: return "sparkles"
        case .analyze: return "chart.pie"
        case .uninstall: return "trash"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 入口

@main
struct MoleLiteApp: App {
    /// rules.json 是只读的，启动时加载一次；失败也不阻断界面。
    @State private var catalog = RulesCatalog.load()

    var body: some Scene {
        WindowGroup {
            RootView(catalog: catalog)
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - 主窗口

struct RootView: View {
    let catalog: RulesCatalog
    /// 截图/调试用：启动参数 -MoleLiteStartSection <clean|analyze|uninstall|about> 选初始页。
    @State private var selection: SidebarSection? =
        SidebarSection(rawValue: UserDefaults.standard.string(forKey: "MoleLiteStartSection") ?? "") ?? .clean
    /// 分析页状态放在主窗口层，切换侧边栏再回来不会重新扫描整个主目录。
    @StateObject private var analyzeModel = AnalyzeViewModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            .safeAreaInset(edge: .bottom) {
                EngineStatusFooter()
            }
        } detail: {
            switch selection ?? .clean {
            case .clean:
                CleanView(catalog: catalog)
            case .analyze:
                AnalyzeView(model: analyzeModel)
            case .uninstall:
                UninstallView(catalog: catalog)
            case .about:
                AboutView(catalog: catalog)
            }
        }
    }
}

// MARK: - 引擎状态

struct EngineStatusFooter: View {
    @State private var directory: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(directory.map { "引擎：\($0)" } ?? (problem ?? "引擎：检测中…"))
                .font(.caption)
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task {
            do {
                let url = try EngineRunner.shared.resolveEngineDirectory()
                directory = url.path
            } catch {
                problem = "未找到引擎目录"
            }
        }
    }
}
