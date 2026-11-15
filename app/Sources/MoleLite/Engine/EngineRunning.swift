import Foundation

// MARK: - 可替换的引擎接口
//
// ViewModel 只需要“调引擎 / 取消”这两件事，因此这里只抽最小协议，
// 生产环境仍是 EngineRunner，测试里可以注入只返回固定预览的假实现。
// 协议不暴露 Process、文件系统或临时选择文件，避免测试绕过安全路径。

/// 清理页需要的引擎能力。
public protocol CleanEngineRunning: Sendable {
    func cleanPreview(timeout: TimeInterval) async throws -> EngineOutcome<CleanPreview>
    func cleanExecute(paths: [String], timeout: TimeInterval) async throws -> EngineOutcome<CleanExecutionReport>
    func cancel()
}

/// 卸载页需要的引擎能力。
public protocol UninstallEngineRunning: Sendable {
    func uninstallPreview(appName: String, timeout: TimeInterval) async throws -> EngineOutcome<UninstallPreview>
    func uninstallExecute(appName: String, paths: [String], timeout: TimeInterval) async throws -> EngineOutcome<UninstallExecutionReport>
    func cancel()
}

// EngineRunner 的现有签名与协议一致，这里只声明遵循关系，不改实现。
extension EngineRunner: CleanEngineRunning {}
extension EngineRunner: UninstallEngineRunning {}
