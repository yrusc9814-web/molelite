import XCTest
@testable import MoleLite

// MARK: - 安全约束测试

/// 每个用例都只验证一件事：执行入口是否把“未预览 / 空勾选 / 需管理员 / 非本次预览”
/// 的路径挡在引擎之外。假 runner 代替真引擎，测试不产出任何文件。
final class SafetyTests: XCTestCase {

    // MARK: 夹具

    private static let cleanItems: [CleanPreviewItem] = [
        CleanPreviewItem(ruleID: "r-cache", section: "user_cache",
                         path: "/Users/tester/Library/Caches/A",
                         sizeBytes: 3_000, defaultSelected: true, needsAdmin: false,
                         risk: "low", itemCount: 1, sizeKnown: true, coveredBy: nil),
        CleanPreviewItem(ruleID: "r-logs", section: "logs",
                         path: "/Users/tester/Library/Logs/B",
                         sizeBytes: 2_000, defaultSelected: true, needsAdmin: false,
                         risk: "low", itemCount: 1, sizeKnown: true, coveredBy: nil),
        CleanPreviewItem(ruleID: "r-downloads", section: "downloads",
                         path: "/Users/tester/Downloads/C.dmg",
                         sizeBytes: 1_000, defaultSelected: false, needsAdmin: false,
                         risk: "medium", itemCount: 1, sizeKnown: true, coveredBy: nil),
        CleanPreviewItem(ruleID: "r-system", section: "system_cache",
                         path: "/Library/Caches/D",
                         sizeBytes: 500, defaultSelected: false, needsAdmin: true,
                         risk: "high", itemCount: 1, sizeKnown: true, coveredBy: nil),
    ]

    private static let uninstallItems: [UninstallPreviewItem] = [
        UninstallPreviewItem(app: "Demo", bundleID: "local.demo", path: "/Applications/Demo.app",
                             kind: "app", sizeBytes: 3_000, defaultSelected: true,
                             needsAdmin: false, risk: "low", action: "trash", mode: "trash"),
        UninstallPreviewItem(app: "Demo", bundleID: "local.demo",
                             path: "/Users/tester/Library/Application Support/Demo",
                             kind: "app_support", sizeBytes: 2_000, defaultSelected: true,
                             needsAdmin: false, risk: "medium", action: "trash", mode: "trash"),
        UninstallPreviewItem(app: "Demo", bundleID: "local.demo",
                             path: "/Users/tester/Library/Preferences/local.demo.plist",
                             kind: "preferences", sizeBytes: 1_000, defaultSelected: false,
                             needsAdmin: false, risk: "low", action: "trash", mode: "trash"),
        UninstallPreviewItem(app: "Demo", bundleID: "local.demo",
                             path: "/Users/tester/Library/LaunchAgents/local.demo.plist",
                             kind: "launch_agent", sizeBytes: 500, defaultSelected: false,
                             needsAdmin: true, risk: "high", action: "trash", mode: "trash"),
    ]

    private static let demoApp = InstalledApp(name: "Demo", path: "/Applications/Demo.app",
                                              bundleID: "local.demo")

    /// 建立“已扫描、有本次预览”的清理页模型。
    @MainActor
    private func scannedCleanModel() async -> (CleanViewModel, FakeCleanRunner) {
        let runner = FakeCleanRunner(previewItems: Self.cleanItems)
        let model = CleanViewModel(catalog: RulesCatalog(), runner: runner)
        await model.scan()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.hasPreview)
        return (model, runner)
    }

    /// select() 会自己起一个 Task 去拉预览，这里等它落定。
    @MainActor
    private func previewedUninstallModel() async throws -> (UninstallViewModel, FakeUninstallRunner) {
        let runner = FakeUninstallRunner(previewItems: Self.uninstallItems)
        let model = UninstallViewModel(catalog: RulesCatalog(), runner: runner)
        model.select(Self.demoApp)
        for _ in 0..<200 {
            if model.phase == .ready { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.phase, .ready, "假 runner 应立即返回预览")
        XCTAssertTrue(model.hasPreview)
        XCTAssertTrue(runner.previewAppNames.contains("Demo"))
        return (model, runner)
    }

    // MARK: 清理：未预览不得执行

    @MainActor
    func testCleanExecuteWithoutPreviewIsBlocked() async {
        let runner = FakeCleanRunner(previewItems: Self.cleanItems)
        let model = CleanViewModel(catalog: RulesCatalog(), runner: runner)

        XCTAssertFalse(model.hasPreview)
        XCTAssertFalse(model.canExecute)

        await model.execute()

        XCTAssertTrue(runner.executeCalls.isEmpty, "没有预览时不得调用执行")
        XCTAssertEqual(runner.previewCallCount, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: 清理：勾选为空不得执行

    @MainActor
    func testCleanExecuteWithEmptySelectionIsBlocked() async {
        let (model, runner) = await scannedCleanModel()

        model.selectAll(false)
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertFalse(model.canExecute)

        await model.execute()

        XCTAssertTrue(runner.executeCalls.isEmpty, "空勾选时不得调用执行")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.hasPreview, "被拦下的执行不应作废预览")
    }

    // MARK: 清理：needs_admin 不可勾 / 不可执行

    @MainActor
    func testCleanNeedsAdminItemCannotBeSelectedOrExecuted() async throws {
        let (model, runner) = await scannedCleanModel()
        let adminItem = try XCTUnwrap(model.items.first { $0.needsAdmin })

        // 直接勾选被拒绝。
        model.setSelected(adminItem, true)
        XCTAssertFalse(model.isSelected(adminItem))
        XCTAssertFalse(model.selectedItems.contains { $0.id == adminItem.id })

        // 全选也跳过它。
        model.selectAll(true)
        XCTAssertFalse(model.isSelected(adminItem))
        XCTAssertEqual(model.selectedItems.count, model.items.filter { !$0.needsAdmin }.count)

        let expected = model.selectedItems.map(\.path)
        await model.execute()

        XCTAssertEqual(runner.executeCalls.count, 1)
        XCTAssertFalse(runner.flattenedExecutedPaths.contains(adminItem.path),
                       "needs_admin 路径绝不能交给引擎")
        XCTAssertEqual(runner.flattenedExecutedPaths, expected)
    }

    // MARK: 清理：执行路径 ⊆ 预览 ∩ 勾选

    @MainActor
    func testCleanExecuteReceivesOnlySelectedSubsetOfPreview() async throws {
        let (model, runner) = await scannedCleanModel()
        let previewPaths = Set(Self.cleanItems.map(\.path))

        // 只勾两个里较大的那个（A），取消另一个默认勾选（B）。
        let first = try XCTUnwrap(model.items.first { $0.path.hasSuffix("/Caches/A") })
        let second = try XCTUnwrap(model.items.first { $0.path.hasSuffix("/Logs/B") })
        model.setSelected(second, false)
        model.setSelected(first, true)

        let expected = model.selectedItems.map(\.path)
        XCTAssertEqual(expected, ["/Users/tester/Library/Caches/A"])
        XCTAssertTrue(model.canExecute)

        await model.execute()

        XCTAssertEqual(runner.executeCalls.count, 1)
        let executed = try XCTUnwrap(runner.executeCalls.first)
        XCTAssertEqual(executed, expected)
        XCTAssertTrue(Set(executed).isSubset(of: previewPaths), "只能执行预览里出现过的路径")
        XCTAssertFalse(executed.contains(second.path), "未勾选的路径不得执行")

        // 执行后预览作废，必须重新扫描；再次 execute 不会再调引擎。
        XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.phase, .finished)
        await model.execute()
        XCTAssertEqual(runner.executeCalls.count, 1, "作废的预览不得复用")
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: 卸载：未预览不得执行

    @MainActor
    func testUninstallExecuteWithoutPreviewIsBlocked() async {
        let runner = FakeUninstallRunner(previewItems: Self.uninstallItems)
        let model = UninstallViewModel(catalog: RulesCatalog(), runner: runner)

        XCTAssertNil(model.selectedApp)
        XCTAssertFalse(model.hasPreview)
        XCTAssertFalse(model.canExecute)

        await model.execute()

        XCTAssertTrue(runner.executeCalls.isEmpty, "没有预览时不得调用执行")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: 卸载：勾选为空不得执行

    @MainActor
    func testUninstallExecuteWithEmptySelectionIsBlocked() async throws {
        let (model, runner) = try await previewedUninstallModel()

        model.selectAll(false)
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertFalse(model.canExecute)

        await model.execute()

        XCTAssertTrue(runner.executeCalls.isEmpty, "空勾选时不得调用执行")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.hasPreview, "被拦下的执行不应作废预览")
    }

    // MARK: 卸载：needs_admin 不可勾 / 不可执行

    @MainActor
    func testUninstallNeedsAdminItemCannotBeSelectedOrExecuted() async throws {
        let (model, runner) = try await previewedUninstallModel()
        let adminItem = try XCTUnwrap(model.items.first { $0.needsAdmin })
        XCTAssertEqual(adminItem.kind, "launch_agent")

        model.setSelected(adminItem, true)
        XCTAssertFalse(model.isSelected(adminItem))
        XCTAssertFalse(model.selectedItems.contains { $0.id == adminItem.id })

        model.selectAll(true)
        XCTAssertFalse(model.isSelected(adminItem))

        let expected = model.selectedItems.map(\.path)
        await model.execute()

        XCTAssertEqual(runner.executeCalls.count, 1)
        let call = try XCTUnwrap(runner.executeCalls.first)
        XCTAssertEqual(call.app, "Demo")
        XCTAssertEqual(call.paths, expected)
        XCTAssertFalse(call.paths.contains(adminItem.path), "needs_admin 路径绝不能交给引擎")
    }

    // MARK: 卸载：执行路径 ⊆ 预览 ∩ 勾选

    @MainActor
    func testUninstallExecuteReceivesOnlySelectedSubsetOfPreview() async throws {
        let (model, runner) = try await previewedUninstallModel()
        let previewPaths = Set(Self.uninstallItems.map(\.path))

        let appBundle = try XCTUnwrap(model.items.first { $0.isAppBundle })
        let support = try XCTUnwrap(model.items.first { $0.kind == "app_support" })
        let prefs = try XCTUnwrap(model.items.first { $0.kind == "preferences" })

        model.selectAll(false)
        model.setSelected(appBundle, true)
        model.setSelected(support, true)
        // prefs 未勾选；launch_agent 需要管理员，勾也勾不上。

        let expected = model.selectedItems.map(\.path)
        XCTAssertEqual(Set(expected), [appBundle.path, support.path])
        XCTAssertTrue(model.canExecute)

        await model.execute()

        XCTAssertEqual(runner.executeCalls.count, 1)
        let call = try XCTUnwrap(runner.executeCalls.first)
        XCTAssertEqual(call.app, "Demo")
        XCTAssertEqual(call.paths, expected)
        XCTAssertTrue(Set(call.paths).isSubset(of: previewPaths), "只能执行预览里出现过的路径")
        XCTAssertFalse(call.paths.contains(prefs.path), "未勾选的路径不得执行")

        // 执行后预览作废，必须重新预览。
        XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.phase, .finished)
        await model.execute()
        XCTAssertEqual(runner.executeCalls.count, 1, "作废的预览不得复用")
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: 卸载：换应用会清空旧预览

    @MainActor
    func testUninstallSelectingOtherAppInvalidatesPreview() async throws {
        let (model, runner) = try await previewedUninstallModel()
        model.selectAll(true)

        model.select(nil)

        XCTAssertFalse(model.hasPreview)
        XCTAssertTrue(model.selectedItems.isEmpty)
        await model.execute()
        XCTAssertTrue(runner.executeCalls.isEmpty, "换应用后旧勾选不得被执行")
        XCTAssertNotNil(model.errorMessage)
    }
}
