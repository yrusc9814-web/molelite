import AppKit
import Combine
import Foundation

// MARK: - 磁盘分析状态

/// 磁盘分析页的唯一状态源。
///
/// 这一页只读：这里只会调用 `EngineRunner.analyze`，不会向引擎传任何删除/清理参数。
/// 下钻与返回上级都靠 `pathStack`：
/// - 进入一个目录前，把当前路径压栈；
/// - “返回上级”弹栈并重新分析上一路径；
/// - 手动选择目录同样压栈，所以从任意位置都能沿原路返回。
@MainActor
public final class AnalyzeViewModel: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case analyzing
        case ready
    }

    // MARK: 输出

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var currentPath: String = NSHomeDirectory()
    @Published public private(set) var pathStack: [String] = []
    @Published public private(set) var entries: [AnalyzeEntry] = []
    @Published public private(set) var largeFiles: [AnalyzeFileEntry] = []
    @Published public private(set) var totalSize: Int64 = 0
    @Published public private(set) var totalFiles: Int64?
    /// 占比条分母，分析完成时算一次，避免每行重排。
    @Published public private(set) var maxEntrySize: Int64 = 1
    @Published public private(set) var maxLargeFileSize: Int64 = 1
    @Published public private(set) var scanStatus: String?
    @Published public private(set) var overview = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var lastScannedAt: Date?

    private let runner: EngineRunner
    /// 只用于丢弃过期回调；当前实现同一时间只允许一个分析，留着更稳。
    private var generation = 0

    /// nonisolated 让 SwiftUI 构造 StateObject 时不必先跳回主线程；
    /// 这里只保存 runner，主目录用属性默认值，避免在 init 里碰 @Published。
    public nonisolated init(runner: EngineRunner = .shared) {
        self.runner = runner
    }

    // MARK: 派生状态

    public var isAnalyzing: Bool { phase == .analyzing }
    public var canGoUp: Bool { !pathStack.isEmpty && !isAnalyzing }
    public var hasResult: Bool { phase == .ready || !entries.isEmpty || !largeFiles.isEmpty }

    /// 引擎已按大小排过一次；这里再排一次，保证界面顺序稳定。
    public var sortedEntries: [AnalyzeEntry] {
        entries.sorted { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public var sortedLargeFiles: [AnalyzeFileEntry] {
        largeFiles.sorted { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 展示用路径：主目录缩写成 ~，太长的路径在界面上截断。
    public var displayPath: String {
        (currentPath as NSString).abbreviatingWithTildeInPath
    }

    public var scanStatusText: String? {
        guard let raw = scanStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "complete", "ok", "done": return "扫描完成"
        case "partial": return "部分完成"
        case "unavailable": return "部分目录不可读"
        default: return raw
        }
    }

    // MARK: 分析

    /// 重新分析当前目录。
    public func analyzeCurrent() async {
        await analyze(path: currentPath)
    }

    /// 分析指定目录；不改变路径栈，供 `analyzeCurrent` 与内部导航复用。
    public func analyze(path: String) async {
        guard !isAnalyzing else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            errorMessage = "分析目录不能为空。"
            return
        }

        generation += 1
        let token = generation
        currentPath = target
        phase = .analyzing
        errorMessage = nil
        // 旧结果先清掉，避免分析新目录时仍显示上一个目录的列表。
        entries = []
        largeFiles = []
        maxEntrySize = 1
        maxLargeFileSize = 1
        totalSize = 0
        totalFiles = nil
        scanStatus = nil
        overview = false

        do {
            let outcome = try await runner.analyze(path: target)
            guard token == generation else { return }

            let output = outcome.value
            if let reported = output.path?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reported.isEmpty {
                currentPath = reported
            }
            entries = output.sortedEntries
            largeFiles = output.largeFiles.sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            maxEntrySize = max(1, entries.first?.size ?? 0)
            maxLargeFileSize = max(1, largeFiles.first?.size ?? 0)
            totalSize = output.totalSize
            totalFiles = output.totalFiles
            scanStatus = output.scanStatus?.value
            overview = output.overview
            logLines = outcome.logLines
            lastScannedAt = Date()
            phase = .ready
        } catch is CancellationError {
            guard token == generation else { return }
            phase = .idle
            errorMessage = "分析已取消。"
        } catch {
            guard token == generation else { return }
            entries = []
            largeFiles = []
            maxEntrySize = 1
            maxLargeFileSize = 1
            totalSize = 0
            totalFiles = nil
            scanStatus = nil
            overview = false
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 导航

    /// 点目录：压栈后分析该路径。
    public func drillDown(into entry: AnalyzeEntry) async {
        guard entry.isDir, !isAnalyzing else { return }
        let target = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != currentPath else { return }
        pathStack.append(currentPath)
        await analyze(path: target)
    }

    /// 返回上级：只用路径栈，不猜测文件系统父目录。
    public func goUp() async {
        guard !isAnalyzing, let previous = pathStack.popLast() else { return }
        await analyze(path: previous)
    }

    /// 手动选目录；同样压栈，便于返回。
    /// NSOpenPanel 在面板关闭后才返回，这里用 runModal 同步拿结果。
    public func chooseDirectory() {
        guard !isAnalyzing else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        panel.prompt = "分析"
        panel.message = "选择一个目录，只读分析它的空间占用。"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let target = url.path
        if target != currentPath {
            pathStack.append(currentPath)
        }
        Task { await analyze(path: target) }
    }

    // MARK: 其他

    public func cancel() {
        guard isAnalyzing else { return }
        runner.cancel()
    }

    /// 在 Finder 中定位当前目录或指定条目；只定位，不打开、不修改。
    public func revealInFinder(_ path: String? = nil) {
        let target = (path ?? currentPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    /// 清掉错误回到可重试状态。
    public func clearError() {
        errorMessage = nil
    }
}
