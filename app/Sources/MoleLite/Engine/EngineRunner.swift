import Foundation

// MARK: - 引擎错误

/// 引擎调用过程中的可展示错误。所有文案都在这里集中，界面直接显示 errorDescription。
public enum EngineError: LocalizedError, Sendable {
    case engineNotFound(searched: [String])
    case scriptMissing(path: String)
    case busy
    case invalidArgument(String)
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    case cancelled
    case emptyOutput(script: String)
    case invalidJSON(script: String, detail: String, raw: String)
    case nonZeroExit(script: String, code: Int32, log: [String])

    public var errorDescription: String? {
        switch self {
        case .engineNotFound(let searched):
            return "找不到引擎目录，已查找：\(searched.joined(separator: "、"))"
        case .scriptMissing(let path):
            return "引擎脚本不存在：\(path)"
        case .busy:
            return "已有一个引擎任务在运行，请等它结束。"
        case .invalidArgument(let reason):
            return "调用参数不合法：\(reason)"
        case .launchFailed(let reason):
            return "无法启动引擎：\(reason)"
        case .timedOut(let seconds):
            return "引擎执行超时（\(Int(seconds.rounded())) 秒），已终止。"
        case .cancelled:
            return "操作已取消。"
        case .emptyOutput(let script):
            return "\(script) 没有在 stdout 输出 JSON。"
        case .invalidJSON(let script, let detail, _):
            return "\(script) 输出的 JSON 无法解析：\(detail)"
        case .nonZeroExit(let script, let code, let log):
            let tail = log.suffix(3).joined(separator: " / ")
            return "\(script) 退出码 \(code)" + (tail.isEmpty ? "。" : "：\(tail)")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .engineNotFound:
            return "开发时设置环境变量 MOLE_ENGINE_DIR 指向 engine/，打包后确认 Resources/engine/bin 存在。"
        case .scriptMissing:
            return "检查引擎副本是否完整（bin/clean.sh、bin/uninstall.sh、bin/analyze.sh）。"
        case .busy:
            return "等当前任务结束，或在界面上取消它。"
        case .timedOut:
            return "可以取消后重试；磁盘分析在文件很多的目录上会更慢。"
        case .nonZeroExit(_, _, let log):
            return log.isEmpty ? "查看引擎日志了解原因。" : "引擎日志最后几行：\(log.suffix(5).joined(separator: " / "))"
        default:
            return nil
        }
    }
}

// MARK: - 调用结果

/// 一次引擎调用的原始结果，供界面展示日志与退出码。
public struct EngineInvocation: Sendable {
    public var script: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var logLines: [String]
    public var duration: TimeInterval
    public var timedOut: Bool
    public var cancelled: Bool

    public init(
        script: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        logLines: [String],
        duration: TimeInterval,
        timedOut: Bool,
        cancelled: Bool
    ) {
        self.script = script
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.logLines = logLines
        self.duration = duration
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

/// 解析成功后的结果，附带本次调用信息。
public struct EngineOutcome<Value: Sendable>: Sendable {
    public var value: Value
    public var invocation: EngineInvocation

    public init(value: Value, invocation: EngineInvocation) {
        self.value = value
        self.invocation = invocation
    }

    public var logLines: [String] { invocation.logLines }
    public var exitCode: Int32 { invocation.exitCode }
    public var duration: TimeInterval { invocation.duration }
}

// MARK: - EngineRunner

/// 通过 `/bin/bash` 调用 Mole 引擎脚本。
///
/// - 引擎目录：环境变量 `MOLE_ENGINE_DIR`，否则 `Bundle.main.resourceURL/engine`。
/// - stdout 只当 JSON 解析；stderr 逐行收成日志。
/// - 支持取消（Task 取消或 `cancel()`）、超时（SIGTERM 后补 SIGKILL）、非 0 退出报错。
/// - clean / uninstall 执行时把勾选路径逐行写入临时文件并设置 `MOLE_SELECTION_FILE`，
///   调用结束（成功、失败、取消、超时）都会删除该临时文件。
public final class EngineRunner: @unchecked Sendable {

    public static let shared = EngineRunner()

    /// 引擎脚本名。
    public enum Script: String, Sendable {
        case clean = "clean.sh"
        case uninstall = "uninstall.sh"
        case analyze = "analyze.sh"
    }

    /// 各类调用的默认超时（秒）。
    public enum Defaults {
        public static let previewTimeout: TimeInterval = 600
        public static let executeTimeout: TimeInterval = 1800
        public static let analyzeTimeout: TimeInterval = 900
    }

    private static let selectionEnvironmentKey = "MOLE_SELECTION_FILE"

    private let stateLock = NSLock()
    private var activeProcess: Process?
    private var activeCancelRequested = false
    private var activeTimedOut = false

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: 运行状态

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeProcess != nil
    }

    /// 取消当前调用；没有调用时是空操作。
    public func cancel() {
        stateLock.lock()
        let process = activeProcess
        if process != nil {
            activeCancelRequested = true
        }
        stateLock.unlock()

        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: 引擎定位

    /// 返回引擎目录（含 bin/clean.sh 的那个 engine/ 目录）。
    public func resolveEngineDirectory() throws -> URL {
        var searched: [String] = []

        if let override = ProcessInfo.processInfo.environment["MOLE_ENGINE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            searched.append(url.path)
            if isEngineDirectory(url) {
                return url
            }
        }

        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("engine", isDirectory: true)
            searched.append(bundled.path)
            if isEngineDirectory(bundled) {
                return bundled
            }
        }

        // swift run 时 Bundle.main 是 .build 下的可执行文件，resourceURL 不等于包根，
        // 这里补一个可执行文件同级的 engine/，方便开发期直接跑。
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        let sibling = executableDirectory.appendingPathComponent("engine", isDirectory: true)
        if !searched.contains(sibling.path) {
            searched.append(sibling.path)
            if isEngineDirectory(sibling) {
                return sibling
            }
        }

        throw EngineError.engineNotFound(searched: searched)
    }

    private func isEngineDirectory(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("bin/clean.sh").path)
    }

    // MARK: 高层调用

    /// `clean --dry-run --json`
    public func cleanPreview(timeout: TimeInterval = Defaults.previewTimeout) async throws -> EngineOutcome<CleanPreview> {
        let invocation = try await execute(
            script: .clean,
            arguments: ["--dry-run", "--json"],
            selectionPaths: nil,
            timeout: timeout
        )
        try ensureSucceeded(invocation)
        let preview = try decodeJSON(CleanPreview.self, from: invocation, script: Script.clean.rawValue)
        return EngineOutcome(value: preview, invocation: invocation)
    }

    /// `clean --json`，只处理 `paths` 里列出的路径。
    /// 部分条目失败时引擎仍会输出完整 JSON 并以非 0 退出，这里优先保留 JSON，
    /// 把退出码交给界面提示；解析失败才当作错误。
    public func cleanExecute(
        paths: [String],
        timeout: TimeInterval = Defaults.executeTimeout
    ) async throws -> EngineOutcome<CleanExecutionReport> {
        let cleaned = try normalizedSelection(paths)
        let invocation = try await execute(
            script: .clean,
            arguments: ["--json"],
            selectionPaths: cleaned,
            timeout: timeout
        )
        let report: CleanExecutionReport
        do {
            report = try decodeJSON(CleanExecutionReport.self, from: invocation, script: Script.clean.rawValue)
        } catch {
            try ensureSucceeded(invocation)
            throw error
        }
        return EngineOutcome(value: report, invocation: invocation)
    }

    /// `uninstall --dry-run --json <app>`；app 是应用名（不含 .app 也可以）。
    public func uninstallPreview(
        appName: String,
        timeout: TimeInterval = Defaults.previewTimeout
    ) async throws -> EngineOutcome<UninstallPreview> {
        let name = try normalizedAppName(appName)
        let invocation = try await execute(
            script: .uninstall,
            arguments: ["--dry-run", "--json", name],
            selectionPaths: nil,
            timeout: timeout
        )
        try ensureSucceeded(invocation)
        let preview = try decodeJSON(UninstallPreview.self, from: invocation, script: Script.uninstall.rawValue)
        return EngineOutcome(value: preview, invocation: invocation)
    }

    /// `uninstall --json <app>`，只处理 `paths` 里列出的路径。默认走废纸篓（不使用 --permanent）。
    public func uninstallExecute(
        appName: String,
        paths: [String],
        timeout: TimeInterval = Defaults.executeTimeout
    ) async throws -> EngineOutcome<UninstallExecutionReport> {
        let name = try normalizedAppName(appName)
        let cleaned = try normalizedSelection(paths)
        let invocation = try await execute(
            script: .uninstall,
            arguments: ["--json", name],
            selectionPaths: cleaned,
            timeout: timeout
        )
        let report: UninstallExecutionReport
        do {
            report = try decodeJSON(UninstallExecutionReport.self, from: invocation, script: Script.uninstall.rawValue)
        } catch {
            try ensureSucceeded(invocation)
            throw error
        }
        return EngineOutcome(value: report, invocation: invocation)
    }

    /// `analyze --json <path>`
    public func analyze(
        path: String,
        timeout: TimeInterval = Defaults.analyzeTimeout
    ) async throws -> EngineOutcome<AnalyzeOutput> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError.invalidArgument("分析目录不能为空。")
        }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            throw EngineError.invalidArgument("分析目录必须是绝对路径：\(trimmed)")
        }
        let target = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.invalidArgument("目录不存在：\(target)")
        }

        let invocation = try await execute(
            script: .analyze,
            arguments: ["--json", target],
            selectionPaths: nil,
            timeout: timeout
        )
        try ensureSucceeded(invocation)
        let output = try decodeJSON(AnalyzeOutput.self, from: invocation, script: Script.analyze.rawValue)
        return EngineOutcome(value: output, invocation: invocation)
    }

    // MARK: 低层执行

    /// 执行脚本并把 stdout/stderr 分开收集。调用方负责退出码与 JSON 策略。
    private func execute(
        script: Script,
        arguments: [String],
        selectionPaths: [String]?,
        timeout: TimeInterval,
        extraEnvironment: [String: String] = [:],
        onLogLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> EngineInvocation {

        try Task.checkCancellation()

        stateLock.lock()
        let alreadyRunning = activeProcess != nil
        stateLock.unlock()
        if alreadyRunning {
            throw EngineError.busy
        }

        let engineDirectory = try resolveEngineDirectory()
        let scriptURL = engineDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(script.rawValue, isDirectory: false)
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw EngineError.scriptMissing(path: scriptURL.path)
        }

        // 勾选路径落到临时文件；执行结束无论如何都删掉。
        var selectionFileURL: URL?
        if let selectionPaths {
            let url = fileManager.temporaryDirectory
                .appendingPathComponent("molelite-selection-\(UUID().uuidString).txt", isDirectory: false)
            let body = selectionPaths
                .map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
                .joined()
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                throw EngineError.launchFailed("无法写入选择文件：\(error.localizedDescription)")
            }
            selectionFileURL = url
        }
        defer {
            if let selectionFileURL {
                try? fileManager.removeItem(at: selectionFileURL)
            }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments
        process.currentDirectoryURL = engineDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        // 不继承外部残留的选择文件，避免误把别人的勾选带进来。
        environment.removeValue(forKey: Self.selectionEnvironmentKey)
        environment["NO_COLOR"] = "1"
        environment["MOLE_ENGINE_DIR"] = engineDirectory.path
        if environment["TERM"] == nil {
            environment["TERM"] = "dumb"
        }
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        if let selectionFileURL {
            environment[Self.selectionEnvironmentKey] = selectionFileURL.path
        }
        process.environment = environment

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer(onLine: onLogLine)
        let resumeGate = ResumeGate()
        let timeoutBox = WorkItemBox()
        let startedAt = Date()

        let invocation: EngineInvocation = try await withTaskCancellationHandler(            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineInvocation, Error>) in

                    process.terminationHandler = { finished in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        timeoutBox.item?.cancel()

                        // 子进程结束后把管道里剩余内容取干净；有超时保护，不无限等。
                        self.drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer)
                        self.drain(stderrPipe.fileHandleForReading, into: stderrBuffer)
                        stderrBuffer.flushPendingLine()

                        self.stateLock.lock()
                        let wasCancelled = self.activeCancelRequested
                        let wasTimedOut = self.activeTimedOut
                        if self.activeProcess === finished {
                            self.activeProcess = nil
                        }
                        self.stateLock.unlock()

                        let stdout = stdoutBuffer.text
                        let stderr = stderrBuffer.text

                        let result = EngineInvocation(
                            script: script.rawValue,
                            arguments: arguments,
                            exitCode: finished.terminationStatus,
                            stdout: stdout,
                            stderr: stderr,
                            logLines: Self.logLines(from: stderr),
                            duration: Date().timeIntervalSince(startedAt),
                            timedOut: wasTimedOut,
                            cancelled: wasCancelled
                        )
                        resumeGate.resume {
                            continuation.resume(returning: result)
                        }
                    }

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { return }
                        stdoutBuffer.append(data)
                    }
                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { return }
                        stderrBuffer.append(data)
                    }

                    do {
                        try process.run()
                    } catch {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        resumeGate.resume {
                            continuation.resume(throwing: EngineError.launchFailed(error.localizedDescription))
                        }
                        return
                    }

                    self.stateLock.lock()
                    self.activeProcess = process
                    self.activeCancelRequested = false
                    self.activeTimedOut = false
                    self.stateLock.unlock()

                    // 超时：先 SIGTERM，5 秒后仍在跑就 SIGKILL。
                    let item = DispatchWorkItem { [weak self, weak process] in
                        guard let self, let process, process.isRunning else { return }
                        self.stateLock.lock()
                        if self.activeProcess === process {
                            self.activeTimedOut = true
                        }
                        self.stateLock.unlock()
                        process.terminate()
                        let pid = process.processIdentifier
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                            if process.isRunning {
                                kill(pid, SIGKILL)
                            }
                        }
                    }
                    timeoutBox.item = item
                    DispatchQueue.global(qos: .utility)
                        .asyncAfter(deadline: .now() + max(1, timeout), execute: item)

                    // 取消可能在 process.run() 之前就发生了（onCancel 已执行），
                    // 这里补一次，保证不会漏掉。
                    if Task.isCancelled {
                        self.cancel()
                    }
                }
            },
            onCancel: {
                self.cancel()
            }
        )

        if invocation.cancelled {
            throw CancellationError()
        }
        if invocation.timedOut {
            throw EngineError.timedOut(seconds: timeout)
        }
        return invocation
    }

    // MARK: 辅助

    private func ensureSucceeded(_ invocation: EngineInvocation) throws {
        guard invocation.exitCode == 0 else {
            throw EngineError.nonZeroExit(
                script: invocation.script,
                code: invocation.exitCode,
                log: invocation.logLines
            )
        }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from invocation: EngineInvocation, script: String) throws -> T {
        guard let payload = JSONPayload.extract(from: invocation.stdout) else {
            if invocation.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw EngineError.emptyOutput(script: script)
            }
            throw EngineError.invalidJSON(
                script: script,
                detail: "stdout 里找不到 JSON 起始括号",
                raw: String(invocation.stdout.prefix(2000))
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(payload.utf8))
        } catch {
            throw EngineError.invalidJSON(
                script: script,
                detail: error.localizedDescription,
                raw: String(payload.prefix(2000))
            )
        }
    }

    private func normalizedSelection(_ paths: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            guard path.hasPrefix("/") else {
                throw EngineError.invalidArgument("勾选路径必须是绝对路径：\(path)")
            }
            guard !path.contains("\n") else {
                throw EngineError.invalidArgument("勾选路径里不能有换行：\(path)")
            }
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        guard !result.isEmpty else {
            throw EngineError.invalidArgument("没有任何勾选路径，执行已阻止。")
        }
        return result
    }

    private func normalizedAppName(_ raw: String) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        guard !name.isEmpty else {
            throw EngineError.invalidArgument("应用名不能为空。")
        }
        guard !name.hasPrefix("-") else {
            throw EngineError.invalidArgument("应用名不能以 - 开头：\(name)")
        }
        guard !name.contains("\n") else {
            throw EngineError.invalidArgument("应用名里不能有换行。")
        }
        return name
    }

    private func drain(_ handle: FileHandle, into buffer: OutputBuffer, wait: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? handle.readToEnd(), !data.isEmpty {
                buffer.append(data)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + wait)
    }

    private static func logLines(from stderr: String) -> [String] {
        stderr
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 内部工具

/// stdout 里可能混入启动横幅，只截取最外层 JSON 片段再解析。
enum JSONPayload {
    static func extract(from raw: String) -> String? {
        guard let brace = raw.firstIndex(of: "{"),
              let bracket = raw.firstIndex(of: "[") else {
            return nil
        }
        let start = brace < bracket ? brace : bracket
        let closing: Character = raw[start] == "{" ? "}" : "]"
        guard let end = raw.lastIndex(of: closing), end > start else {
            return nil
        }
        return String(raw[start...end])
    }
}

/// 线程安全的字节缓冲；可选按行回调。
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        guard onLine != nil else {
            lock.unlock()
            return
        }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        lock.unlock()

        for line in lines {
            onLine?(line)
        }
    }

    func flushPendingLine() {
        guard let onLine else { return }
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        guard !rest.isEmpty else { return }
        onLine(String(decoding: rest, as: UTF8.self))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 保证 continuation 只被恢复一次。
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}

final class WorkItemBox: @unchecked Sendable {
    var item: DispatchWorkItem?
}
