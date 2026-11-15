import Combine
import Foundation

// MARK: - 卸载页状态

/// 卸载页的唯一状态源。
///
/// 安全约束：
/// - 预览成功才保存快照，执行只从快照里取路径；
/// - 勾选按 `default_selected` 初始化，`needs_admin` 永不可勾；
/// - 执行期间拒绝重入，执行后快照作废；
/// - 结果按 trashed / removed / skipped / failed 汇总。
@MainActor
public final class UninstallViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case previewing
        case ready
        case executing
        case finished
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var apps: [InstalledApp] = []
    @Published public private(set) var selectedApp: InstalledApp?
    @Published public private(set) var items: [UninstallPreviewItem] = []
    @Published public private(set) var selectedIDs: Set<String> = []
    @Published public private(set) var result: UninstallExecutionReport?
    @Published public private(set) var executedAppName: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var logLines: [String] = []

    private struct Snapshot {
        let app: InstalledApp
        let preview: UninstallPreview
    }

    private var snapshot: Snapshot?
    /// 防止快速切换应用时旧预览覆盖新选择。
    private var previewGeneration = 0

    /// 最小协议：生产用 EngineRunner.shared，测试注入假 runner。
    private let runner: any UninstallEngineRunning
    private let fileManager: FileManager

    /// `catalog` 只为与清理页保持同样的构造方式：uninstall 预览项没有 `rule_id`，
    /// rules.json 的按条覆盖不适用，`default_selected` / `needs_admin` 直接取引擎值。
    public nonisolated init(
        catalog: RulesCatalog,
        runner: any UninstallEngineRunning = EngineRunner.shared,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    // MARK: 派生状态

    public var isPreviewing: Bool { phase == .previewing }
    public var isExecuting: Bool { phase == .executing }
    public var hasPreview: Bool { snapshot != nil && !items.isEmpty }

    public var selectableItems: [UninstallPreviewItem] {
        items.filter { !$0.needsAdmin }
    }

    public var selectedItems: [UninstallPreviewItem] {
        items.filter { selectedIDs.contains($0.id) && !$0.needsAdmin }
    }

    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var canExecute: Bool {
        hasPreview && !isExecuting && !isPreviewing && !selectedItems.isEmpty
    }

    public var selectionSummary: String {
        "已选 \(selectedItems.count) 项，共 \(ByteFormat.string(selectedBytes))"
    }

    public var appBundleItems: [UninstallPreviewItem] {
        items.filter { $0.isAppBundle }
    }

    public var leftoverGroups: [UninstallLeftoverGroup] {
        var order: [String] = []
        var buckets: [String: [UninstallPreviewItem]] = [:]
        for item in items where !item.isAppBundle {
            let raw = item.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = raw.isEmpty ? "other" : raw.lowercased()
            if buckets[kind] == nil {
                order.append(kind)
                buckets[kind] = []
            }
            buckets[kind]?.append(item)
        }
        return order.map { kind in
            UninstallLeftoverGroup(kind: kind,
                                   title: UninstallKind.title(kind),
                                   items: buckets[kind] ?? [])
        }
    }

    public var resultSummary: UninstallResultSummary? {
        result.map { UninstallResultSummary(records: $0.records) }
    }

    // MARK: 应用列表

    /// 只读枚举两个标准目录，不递归、不跟随符号链接。
    public func reloadApps() {
        var found: [InstalledApp] = []
        var seen = Set<String>()
        for directory in Self.applicationDirectories(fileManager: fileManager) {
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension.lowercased() == "app" {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let bundleID = Bundle(url: url)?.bundleIdentifier
                found.append(InstalledApp(name: name, path: path, bundleID: bundleID))
            }
        }
        apps = found.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    public func filteredApps(query: String) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(trimmed)
                || ($0.bundleID?.lowercased().contains(trimmed) ?? false)
                || $0.path.lowercased().contains(trimmed)
        }
    }

    public static func applicationDirectories(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: 选择与预览

    /// 切换应用会清空旧预览，并立刻为新应用拉一次预览；忙碌时忽略，避免执行中换目标。
    public func select(_ app: InstalledApp?) {
        guard !isExecuting, !isPreviewing else { return }
        previewGeneration += 1
        selectedApp = app
        items = []
        selectedIDs = []
        snapshot = nil
        result = nil
        executedAppName = nil
        errorMessage = nil
        logLines = []
        phase = .idle

        guard app != nil else { return }
        Task { await loadPreview() }
    }

    /// `uninstall --dry-run --json <app>` → 初始化勾选。
    public func loadPreview() async {
        guard let app = selectedApp, !isPreviewing, !isExecuting else { return }
        previewGeneration += 1
        let generation = previewGeneration

        phase = .previewing
        errorMessage = nil
        result = nil
        items = []

        do {
            let outcome = try await runner.uninstallPreview(appName: app.name,
                                                           timeout: EngineRunner.Defaults.previewTimeout)
            guard generation == previewGeneration, selectedApp?.id == app.id else { return }
            let sorted = outcome.value.items.sorted { lhs, rhs in
                if lhs.isAppBundle != rhs.isAppBundle { return lhs.isAppBundle }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.path < rhs.path
            }
            items = sorted
            snapshot = Snapshot(app: app, preview: UninstallPreview(items: sorted))
            selectedIDs = Set(sorted.filter { $0.defaultSelected && !$0.needsAdmin }.map(\.id))
            logLines = outcome.logLines
            phase = .ready
        } catch is CancellationError {
            guard generation == previewGeneration else { return }
            items = []
            snapshot = nil
            selectedIDs = []
            phase = .idle
            errorMessage = "预览已取消。"
        } catch {
            guard generation == previewGeneration else { return }
            items = []
            snapshot = nil
            selectedIDs = []
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 勾选

    public func isSelected(_ item: UninstallPreviewItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    public func setSelected(_ item: UninstallPreviewItem, _ selected: Bool) {
        guard !item.needsAdmin, hasPreview, !isExecuting, !isPreviewing else { return }
        if selected {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs.remove(item.id)
        }
    }

    public func selectAll(_ selected: Bool) {
        guard hasPreview, !isExecuting, !isPreviewing else { return }
        selectedIDs = selected ? Set(selectableItems.map(\.id)) : []
    }

    // MARK: 执行

    /// 只把“本次预览里出现且已勾选”的绝对路径交给引擎。
    public func execute() async {
        guard !isExecuting, !isPreviewing else { return }
        guard let current = snapshot, !current.preview.items.isEmpty else {
            errorMessage = "还没有本次预览，无法执行。请先重新预览。"
            return
        }

        let allowed = Set(current.preview.items.map(\.id))
        let paths = current.preview.items
            .filter { allowed.contains($0.id) && selectedIDs.contains($0.id) && !$0.needsAdmin }
            .map(\.path)
        guard !paths.isEmpty else {
            errorMessage = "没有勾选任何可移除的项目。"
            return
        }

        phase = .executing
        errorMessage = nil
        executedAppName = current.app.name
        // 尝试执行后预览即作废：磁盘内容已变，下次必须重新预览。
        defer {
            snapshot = nil
            items = []
            selectedIDs = []
            phase = .finished
        }

        do {
            let outcome = try await runner.uninstallExecute(appName: current.app.name, paths: paths,
                                                            timeout: EngineRunner.Defaults.executeTimeout)
            result = outcome.value
            logLines = outcome.logLines
            if outcome.invocation.exitCode != 0 {
                errorMessage = "引擎以退出码 \(outcome.invocation.exitCode) 结束，请查看结果明细。"
            }
        } catch is CancellationError {
            errorMessage = "卸载已取消，结果可能不完整。请重新预览确认。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancel() {
        guard isPreviewing || isExecuting else { return }
        runner.cancel()
    }

    /// 关闭结果页，重新枚举应用列表。
    public func finishResult() {
        result = nil
        errorMessage = nil
        logLines = []
        executedAppName = nil
        selectedApp = nil
        phase = .idle
        reloadApps()
    }
}
