import Combine
import Foundation

// MARK: - 清理页状态

/// 清理页的唯一状态源。
///
/// 安全约束：
/// - `scan()` 成功后保存一份“本次预览”快照，`execute()` 只在这份快照里取路径；
/// - 勾选集合只在快照内生效，换一次扫描就整体重置；
/// - `needs_admin` 的条目既不能勾选，也不会被交给引擎；
/// - 执行期间 `isExecuting` 为真，界面禁用入口，`execute()` 自身也会拒绝重入。
@MainActor
public final class CleanViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case executing
        case finished
    }

    // MARK: 输出

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var items: [CleanPreviewItem] = []
    @Published public private(set) var selectedIDs: Set<String> = []
    @Published public private(set) var result: CleanExecutionReport?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var lastScannedAt: Date?

    /// 最近一次成功扫描的快照；执行只认它。
    private var previewSnapshot: CleanPreview?
    private let catalog: RulesCatalog
    /// 最小协议：生产用 EngineRunner.shared，测试注入假 runner。
    private let runner: any CleanEngineRunning

    /// nonisolated 让 SwiftUI 在构造 StateObject 时不必先跳回主线程；
    /// 这里只做属性初始化，不触碰任何 UI 状态。
    public nonisolated init(catalog: RulesCatalog, runner: any CleanEngineRunning = EngineRunner.shared) {
        self.catalog = catalog
        self.runner = runner
    }

    // MARK: 派生状态

    public var isScanning: Bool { phase == .scanning }
    public var isExecuting: Bool { phase == .executing }
    public var hasPreview: Bool { previewSnapshot != nil && !items.isEmpty }

    /// 可勾选（未被管理员权限拦住）的条目。
    public var selectableItems: [CleanPreviewItem] {
        items.filter { !$0.needsAdmin }
    }

    public var selectedItems: [CleanPreviewItem] {
        items.filter { selectedIDs.contains($0.id) && !$0.needsAdmin }
    }

    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    public var canExecute: Bool {
        hasPreview && !isExecuting && !isScanning && !selectedItems.isEmpty
    }

    public var selectionSummary: String {
        "已选 \(selectedItems.count) 项，共 \(ByteFormat.string(selectedBytes))"
    }

    /// 按 section 分组，保持引擎输出里的首次出现顺序。
    public var groupedItems: [CleanSectionGroup] {
        var order: [String] = []
        var groups: [String: [CleanPreviewItem]] = [:]
        for item in items {
            let key = item.section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let section = key.isEmpty ? "其他" : key
            if groups[section] == nil {
                order.append(section)
                groups[section] = []
            }
            groups[section]?.append(item)
        }
        return order.map { CleanSectionGroup(section: $0, items: groups[$0] ?? []) }
    }

    public var resultSummary: ResultSummary? {
        guard let result else { return nil }
        return ResultSummary(records: result.records)
    }

    // MARK: 勾选

    public func isSelected(_ item: CleanPreviewItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    public func setSelected(_ item: CleanPreviewItem, _ selected: Bool) {
        guard !item.needsAdmin else { return }
        guard hasPreview else { return }
        if selected {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs.remove(item.id)
        }
    }

    public func selectAll(_ selected: Bool) {
        guard hasPreview, !isExecuting else { return }
        selectedIDs = selected ? Set(selectableItems.map(\.id)) : []
    }

    // MARK: 扫描

    /// `clean --dry-run --json` → rules.json 覆盖 → 初始化勾选。
    public func scan() async {
        guard !isScanning, !isExecuting else { return }
        phase = .scanning
        errorMessage = nil
        result = nil

        do {
            let outcome = try await runner.cleanPreview(timeout: EngineRunner.Defaults.previewTimeout)
            let overridden = catalog.apply(to: outcome.value)
            let sorted = overridden.items.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.path < rhs.path
            }
            items = sorted
            previewSnapshot = CleanPreview(items: sorted)
            // 默认勾选按 rules.json 覆盖后的 default_selected；需管理员的永不预选。
            selectedIDs = Set(sorted.filter { $0.defaultSelected && !$0.needsAdmin }.map(\.id))
            logLines = outcome.logLines
            lastScannedAt = Date()
            phase = .ready
        } catch is CancellationError {
            phase = .idle
            errorMessage = "扫描已取消。"
        } catch {
            items = []
            previewSnapshot = nil
            selectedIDs = []
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 执行

    /// 只把“本次预览里出现且已勾选”的绝对路径交给引擎。
    public func execute() async {
        guard !isExecuting, !isScanning else { return }
        guard let preview = previewSnapshot, !preview.items.isEmpty else {
            errorMessage = "还没有本次扫描的预览，无法执行。请先重新扫描。"
            return
        }

        let allowed = Set(preview.items.map(\.id))
        let paths = preview.items
            .filter { allowed.contains($0.id) && selectedIDs.contains($0.id) && !$0.needsAdmin }
            .map(\.path)
        // 快照之外不可能有路径进来；EngineRunner 还会再校验绝对路径并去重。
        guard !paths.isEmpty else {
            errorMessage = "没有勾选任何可清理的项目。"
            return
        }

        phase = .executing
        errorMessage = nil
        // 只要尝试过执行，本次预览就作废：磁盘内容已变，必须重新扫描再决定。
        defer {
            previewSnapshot = nil
            items = []
            selectedIDs = []
            phase = .finished
        }

        do {
            let outcome = try await runner.cleanExecute(paths: paths,
                                                        timeout: EngineRunner.Defaults.executeTimeout)
            result = outcome.value
            logLines = outcome.logLines
            if outcome.invocation.exitCode != 0 {
                errorMessage = "引擎以退出码 \(outcome.invocation.exitCode) 结束，请查看结果明细。"
            }
        } catch is CancellationError {
            errorMessage = "清理已取消，结果可能不完整。请重新扫描确认。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancel() {
        guard isScanning || isExecuting else { return }
        runner.cancel()
    }

    /// 清掉结果页回到空状态（列表已被执行作废，这里同步回到 idle）。
    public func finishResult() {
        result = nil
        errorMessage = nil
        logLines = []
        phase = .idle
    }
}

// MARK: - 分组

public struct CleanSectionGroup: Identifiable {
    public let section: String
    public let items: [CleanPreviewItem]

    public var id: String { section }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - 结果汇总

/// 按 removed / skipped / failed 归类，空组不显示。
public struct ResultSummary {
    public var removed: [CleanExecutionRecord]
    public var skipped: [CleanExecutionRecord]
    public var failed: [CleanExecutionRecord]

    public init(records: [CleanExecutionRecord]) {
        removed = records.filter { $0.actionKind == .removed }
        skipped = records.filter { $0.actionKind == .skipped }
        failed = records.filter { $0.actionKind == .failed }
    }

    public var removedBytes: Int64 {
        removed.reduce(0) { $0 + $1.sizeBytes }
    }

    public var isEmpty: Bool {
        removed.isEmpty && skipped.isEmpty && failed.isEmpty
    }

    public var headline: String {
        "已删除 \(removed.count) 项（\(ByteFormat.string(removedBytes))），跳过 \(skipped.count) 项，失败 \(failed.count) 项。"
    }
}
