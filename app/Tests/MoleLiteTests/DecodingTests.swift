import XCTest
@testable import MoleLite

// MARK: - 解码测试

final class DecodingTests: XCTestCase {

    /// 6 个 fixture 必须全部能被对应模型解码；任何一个抛错都会让本用例失败。
    func testAllFixturesDecode() throws {
        XCTAssertEqual(Fixture.names.count, 6)

        let cleanPreview = try XCTUnwrap(Fixture.decode(CleanPreview.self, "clean-preview"))
        XCTAssertEqual(cleanPreview.items.count, 9)

        let cleanExecution = try XCTUnwrap(Fixture.decode(CleanExecutionReport.self, "clean-execute"))
        XCTAssertEqual(cleanExecution.records.count, 6)

        let uninstallPreview = try XCTUnwrap(Fixture.decode(UninstallPreview.self, "uninstall-preview"))
        XCTAssertEqual(uninstallPreview.items.count, 5)

        let uninstallExecution = try XCTUnwrap(Fixture.decode(UninstallExecutionReport.self, "uninstall-execute"))
        XCTAssertEqual(uninstallExecution.records.count, 5)

        let rules = try XCTUnwrap(Fixture.decode([RuleOverride].self, "rules-sample"))
        XCTAssertEqual(rules.count, 3)

        let analyze = try XCTUnwrap(Fixture.decode(AnalyzeOutput.self, "analyze"))
        XCTAssertEqual(analyze.entries.count, 4)
        XCTAssertEqual(analyze.largeFiles.count, 2)
    }

    // MARK: clean 预览

    func testCleanPreviewFields() throws {
        let preview = try XCTUnwrap(Fixture.decode(CleanPreview.self, "clean-preview"))
        let items = preview.items

        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(preview.totalBytes, 3_879_731_200)
        XCTAssertEqual(Set(items.map(\.id)).count, 9, "rule_id + path 的 id 应唯一")

        // section 覆盖 6 组。
        XCTAssertEqual(Set(items.compactMap(\.section)).count, 6)
        XCTAssertEqual(Set(items.compactMap(\.section)),
                       ["user_cache", "logs", "trash", "system_cache", "dev_cache", "downloads"])

        let safari = try XCTUnwrap(items.first { $0.path.hasSuffix("/Caches/com.apple.Safari") })
        XCTAssertEqual(safari.ruleID, "user_cache-01")
        XCTAssertEqual(safari.section, "user_cache")
        XCTAssertEqual(safari.sizeBytes, 52_428_800)
        XCTAssertEqual(safari.itemCount, 12)
        XCTAssertTrue(safari.defaultSelected)
        XCTAssertFalse(safari.needsAdmin)
        XCTAssertEqual(safari.riskLevel, .low)
        XCTAssertTrue(safari.sizeKnown)
        XCTAssertNil(safari.coveredBy)
        XCTAssertEqual(safari.displayName, "com.apple.Safari")

        let chrome = try XCTUnwrap(items.first { $0.path.contains("/Google/Chrome/") })
        XCTAssertFalse(chrome.defaultSelected)
        XCTAssertEqual(chrome.riskLevel, .medium)
        XCTAssertEqual(chrome.itemCount, 214)

        // 被父项覆盖的子项：大小为 0、size_known=false、covered_by 指向父项。
        let webkit = try XCTUnwrap(items.first { $0.path.hasSuffix("/com.apple.Safari/WebKit") })
        XCTAssertEqual(webkit.sizeBytes, 0)
        XCTAssertFalse(webkit.sizeKnown)
        XCTAssertEqual(webkit.coveredBy, "user_cache-01:/Users/demo/Library/Caches/com.apple.Safari")

        // 需要管理员权限的条目：默认不勾选，风险高。
        let adminItem = try XCTUnwrap(items.first { $0.needsAdmin })
        XCTAssertTrue(adminItem.path.hasSuffix("/com.apple.dyld"))
        XCTAssertFalse(adminItem.defaultSelected)
        XCTAssertEqual(adminItem.riskLevel, .high)

        // 风险三档都出现，且未知值不会被误判。
        let risks = Set(items.map(\.riskLevel))
        XCTAssertTrue(risks.isSuperset(of: [.low, .medium, .high]))
        XCTAssertFalse(risks.contains(.unknown))

        XCTAssertEqual(items.filter(\.defaultSelected).count, 5)
        XCTAssertEqual(items.filter(\.needsAdmin).count, 1)
        XCTAssertEqual(items.filter { !$0.sizeKnown }.count, 2)
        XCTAssertEqual(items.filter { $0.coveredBy != nil }.count, 1)

        XCTAssertEqual(RiskLevel(raw: "HIGH"), .high)
        XCTAssertEqual(RiskLevel(raw: "wat"), .unknown)
        XCTAssertEqual(RiskLevel(raw: nil), .unknown)
    }

    // MARK: clean 执行

    func testCleanExecutionFields() throws {
        let report = try XCTUnwrap(Fixture.decode(CleanExecutionReport.self, "clean-execute"))

        XCTAssertEqual(report.records.count, 6)
        XCTAssertEqual(report.removed.count, 2)
        XCTAssertEqual(report.skipped.count, 3)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.removedBytes, 1_089_470_464)

        let first = try XCTUnwrap(report.records.first)
        XCTAssertEqual(first.path, "/Users/demo/Library/Caches/pip")
        XCTAssertEqual(first.section, "dev_cache")
        XCTAssertEqual(first.actionKind, .removed)
        XCTAssertTrue(first.succeeded)
        XCTAssertNil(first.reason)

        XCTAssertEqual(report.skipped.map(\.reason), ["not_selected", "not_selected", "needs_admin"])
        XCTAssertEqual(report.failed.first?.reason, "permission denied")

        // 执行动作字符串大小写不敏感，陌生值落 unknown 而不是崩溃。
        XCTAssertEqual(ExecutionAction(raw: "Removed"), .removed)
        XCTAssertEqual(ExecutionAction(raw: "exploded"), .unknown)
    }

    // MARK: uninstall 预览

    func testUninstallPreviewFields() throws {
        let preview = try XCTUnwrap(Fixture.decode(UninstallPreview.self, "uninstall-preview"))

        XCTAssertEqual(preview.items.count, 5)
        XCTAssertEqual(preview.totalBytes, 1_609_363_660)

        let app = try XCTUnwrap(preview.appBundle)
        XCTAssertEqual(app.app, "Slack")
        XCTAssertEqual(app.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(app.path, "/Users/demo/Applications/Slack.app")
        XCTAssertEqual(app.kind, "app")
        XCTAssertEqual(app.sizeBytes, 268_435_456)
        XCTAssertTrue(app.defaultSelected)
        XCTAssertFalse(app.needsAdmin)
        XCTAssertEqual(app.riskLevel, .low)
        XCTAssertEqual(app.mode, "trash")
        XCTAssertEqual(app.displayName, "Slack.app")

        XCTAssertEqual(preview.leftovers.count, 4)
        XCTAssertEqual(Set(preview.leftovers.compactMap(\.kind)),
                       ["app_support", "caches", "preferences", "launch_agent"])

        // 启动项需要管理员权限：不预选，风险高。
        let launchAgent = try XCTUnwrap(preview.items.first { $0.kind == "launch_agent" })
        XCTAssertTrue(launchAgent.needsAdmin)
        XCTAssertFalse(launchAgent.defaultSelected)
        XCTAssertEqual(launchAgent.riskLevel, .high)
        XCTAssertFalse(launchAgent.isAppBundle)
    }

    // MARK: uninstall 执行

    func testUninstallExecutionFields() throws {
        let report = try XCTUnwrap(Fixture.decode(UninstallExecutionReport.self, "uninstall-execute"))

        XCTAssertEqual(report.records.count, 5)
        XCTAssertEqual(report.trashed.count, 2)
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(report.hasPermanentRemoval)
        XCTAssertEqual(report.trashedBytes, 1_556_925_644)

        let permanent = try XCTUnwrap(report.records.first { $0.actionKind == .removed })
        XCTAssertTrue(permanent.isPermanentRemoval)
        XCTAssertEqual(permanent.path, "/Users/demo/Library/Caches/com.tinyspeck.slackmacgap")
        XCTAssertEqual(permanent.reason, "trash unavailable, removed permanently")

        XCTAssertEqual(report.skipped.first?.reason, "not_selected")
        XCTAssertEqual(report.failed.first?.reason, "operation not permitted")
        XCTAssertFalse(report.records.first?.isPermanentRemoval ?? true, "trashed 不是永久删除")
    }

    // MARK: analyze

    func testAnalyzeFields() throws {
        let output = try XCTUnwrap(Fixture.decode(AnalyzeOutput.self, "analyze"))

        XCTAssertEqual(output.scanStatus?.value, "complete")
        XCTAssertEqual(output.path, "/Users/demo")
        XCTAssertTrue(output.overview)
        XCTAssertEqual(output.totalSize, 59_055_800_320)
        XCTAssertEqual(output.totalFiles, 184_320)

        XCTAssertEqual(output.entries.count, 4)
        let library = try XCTUnwrap(output.entries.first { $0.name == "Library" })
        XCTAssertEqual(library.path, "/Users/demo/Library")
        XCTAssertEqual(library.size, 42_949_672_960)
        XCTAssertTrue(library.isDir)
        XCTAssertTrue(library.insight)
        XCTAssertFalse(library.cleanable)
        XCTAssertEqual(library.lastAccess, "2026-11-13")

        let downloads = try XCTUnwrap(output.entries.first { $0.name == "Downloads" })
        XCTAssertTrue(downloads.cleanable)

        // 无访问权限的条目：scan_status 非 ok，last_access 缺失，不影响整体解码。
        let photos = try XCTUnwrap(output.entries.first { $0.name.hasSuffix(".photoslibrary") })
        XCTAssertEqual(photos.scanStatus?.value, "unavailable")
        XCTAssertEqual(photos.size, 0)
        XCTAssertNil(photos.lastAccess)

        // 按大小降序取用。
        XCTAssertEqual(output.sortedEntries.map(\.name).first, "Library")
        XCTAssertEqual(output.sortedEntries.last?.name, "Photos Library.photoslibrary")

        XCTAssertEqual(output.largeFiles.count, 2)
        let backup = try XCTUnwrap(output.largeFiles.first)
        XCTAssertEqual(backup.name, "backup-2026.tar.zst")
        XCTAssertEqual(backup.size, 8_589_934_592)
        XCTAssertEqual(output.largeFiles.last?.path, "/Users/demo/Downloads/Xcode_15.4.xip")
    }

    // MARK: 容错

    func testUnknownAndMissingFieldsAreTolerated() throws {
        // 带未来字段、数字/布尔用字符串表示：解析成功且值正确。
        let flexible = Data("""
        {
          "path": "/tmp/only",
          "size_bytes": "1024",
          "default_selected": "true",
          "items": "7",
          "future_field": {"nested": [1, 2, 3]}
        }
        """.utf8)
        let item = try JSONDecoder().decode(CleanPreviewItem.self, from: flexible)
        XCTAssertEqual(item.path, "/tmp/only")
        XCTAssertEqual(item.sizeBytes, 1024)
        XCTAssertTrue(item.defaultSelected)
        XCTAssertEqual(item.itemCount, 7)
        XCTAssertTrue(item.sizeKnown, "有大小但没有 size_known 时视为已知")
        XCTAssertNil(item.ruleID)

        // 只有 path：缺字段按默认值，不抛错。
        let minimal = try JSONDecoder().decode(CleanPreviewItem.self, from: Data(#"{"path":"/tmp/x"}"#.utf8))
        XCTAssertEqual(minimal.sizeBytes, 0)
        XCTAssertFalse(minimal.defaultSelected)
        XCTAssertFalse(minimal.needsAdmin)

        // 顶层被包成 {"items": [...]} 也能解出同样的条目。
        let envelope = try JSONDecoder().decode(CleanPreview.self, from: Data("""
        {"items": [{"path": "/tmp/a", "size_bytes": 1}, {"path": "/tmp/b", "size_bytes": 2}]}
        """.utf8))
        XCTAssertEqual(envelope.items.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(envelope.totalBytes, 3)

        // 完全陌生的对象 → 空数组而不是崩溃。
        let unknown = try JSONDecoder().decode(CleanPreview.self, from: Data(#"{"unexpected": true}"#.utf8))
        XCTAssertTrue(unknown.items.isEmpty)
    }
}
