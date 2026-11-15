import XCTest
@testable import MoleLite

// MARK: - 假引擎

/// 只记录“执行时收到了哪些路径”，不碰文件系统、不启动进程。
final class FakeCleanRunner: CleanEngineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _previewCalls = 0
    private var _executeCalls: [[String]] = []
    private let previewItems: [CleanPreviewItem]

    init(previewItems: [CleanPreviewItem]) {
        self.previewItems = previewItems
    }

    var previewCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _previewCalls
    }

    /// 每次 cleanExecute 收到的路径列表，按调用顺序保留。
    var executeCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _executeCalls
    }

    var flattenedExecutedPaths: [String] { executeCalls.flatMap { $0 } }

    func cleanPreview(timeout: TimeInterval) async throws -> EngineOutcome<CleanPreview> {
        lock.lock()
        _previewCalls += 1
        lock.unlock()
        return EngineOutcome(value: CleanPreview(items: previewItems),
                             invocation: Self.invocation(arguments: ["--dry-run", "--json"]))
    }

    func cleanExecute(paths: [String], timeout: TimeInterval) async throws -> EngineOutcome<CleanExecutionReport> {
        lock.lock()
        _executeCalls.append(paths)
        lock.unlock()
        let records = paths.map {
            CleanExecutionRecord(path: $0, section: nil, action: "removed", reason: nil, sizeBytes: 1)
        }
        return EngineOutcome(value: CleanExecutionReport(records: records),
                             invocation: Self.invocation(arguments: ["--json"]))
    }

    func cancel() {}

    private static func invocation(arguments: [String]) -> EngineInvocation {
        EngineInvocation(script: "clean.sh",
                         arguments: arguments,
                         exitCode: 0,
                         stdout: "[]",
                         stderr: "",
                         logLines: [],
                         duration: 0,
                         timedOut: false,
                         cancelled: false)
    }
}

final class FakeUninstallRunner: UninstallEngineRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _previewCalls = 0
    private var _previewAppNames: [String] = []
    private var _executeCalls: [(app: String, paths: [String])] = []
    private let previewItems: [UninstallPreviewItem]

    init(previewItems: [UninstallPreviewItem]) {
        self.previewItems = previewItems
    }

    var previewAppNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _previewAppNames
    }

    var executeCalls: [(app: String, paths: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _executeCalls
    }

    var flattenedExecutedPaths: [String] { executeCalls.flatMap { $0.paths } }

    func uninstallPreview(appName: String, timeout: TimeInterval) async throws -> EngineOutcome<UninstallPreview> {
        lock.lock()
        _previewCalls += 1
        _previewAppNames.append(appName)
        lock.unlock()
        return EngineOutcome(value: UninstallPreview(items: previewItems),
                             invocation: Self.invocation(arguments: ["--dry-run", "--json", appName]))
    }

    func uninstallExecute(appName: String, paths: [String], timeout: TimeInterval) async throws -> EngineOutcome<UninstallExecutionReport> {
        lock.lock()
        _executeCalls.append((app: appName, paths: paths))
        lock.unlock()
        let records = paths.map {
            UninstallExecutionRecord(app: appName, path: $0, kind: nil, action: "trashed", reason: nil, sizeBytes: 1)
        }
        return EngineOutcome(value: UninstallExecutionReport(records: records),
                             invocation: Self.invocation(arguments: ["--json", appName]))
    }

    func cancel() {}

    private static func invocation(arguments: [String]) -> EngineInvocation {
        EngineInvocation(script: "uninstall.sh",
                         arguments: arguments,
                         exitCode: 0,
                         stdout: "[]",
                         stderr: "",
                         logLines: [],
                         duration: 0,
                         timedOut: false,
                         cancelled: false)
    }
}
