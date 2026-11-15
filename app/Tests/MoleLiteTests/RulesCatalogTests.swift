import XCTest
@testable import MoleLite

// MARK: - RulesCatalog 覆盖逻辑

/// rules-sample.json 的 3 条规则覆盖三种情况：
/// - installer-dmg：default_selected=true / needs_admin=false / risk=medium
/// - system-cache：default_selected=false / needs_admin=true / risk=high
/// - xcode-derived-data：default_selected=true / needs_admin=false / risk=low
final class RulesCatalogTests: XCTestCase {

    private func sampleCatalog(file: StaticString = #filePath, line: UInt = #line) throws -> RulesCatalog {
        let rules = try XCTUnwrap(Fixture.decode([RuleOverride].self, "rules-sample", file: file, line: line))
        let catalog = RulesCatalog(overrides: Dictionary(uniqueKeysWithValues: rules.map { ($0.ruleID, $0) }))
        XCTAssertEqual(catalog.count, 3, file: file, line: line)
        XCTAssertNil(catalog.loadError, file: file, line: line)
        return catalog
    }

    // MARK: 解析

    func testSampleDecodesAllThreeFields() throws {
        let catalog = try sampleCatalog()

        let installer = try XCTUnwrap(catalog["installer-dmg"])
        XCTAssertEqual(installer.defaultSelected, true)
        XCTAssertEqual(installer.needsAdmin, false)
        XCTAssertEqual(installer.riskLevel, .medium)

        let system = try XCTUnwrap(catalog["system-cache"])
        XCTAssertEqual(system.defaultSelected, false)
        XCTAssertEqual(system.needsAdmin, true)
        XCTAssertEqual(system.riskLevel, .high)

        let xcode = try XCTUnwrap(catalog["xcode-derived-data"])
        XCTAssertEqual(xcode.defaultSelected, true)
        XCTAssertEqual(xcode.needsAdmin, false)
        XCTAssertEqual(xcode.riskLevel, .low)

        // 不存在的 id 与空 id 都返回 nil，不崩。
        XCTAssertNil(catalog["nope"])
        XCTAssertNil(catalog[nil])
        XCTAssertNil(catalog[""])
    }

    func testDecodeIgnoresExtraKeysAndDropsBlankIDs() {
        let json = Data("""
        [
          {"id": "a", "default_selected": true, "risk": "low", "category": "x", "paths": ["/tmp/*"]},
          {"id": "", "default_selected": true},
          {"risk": "high"}
        ]
        """.utf8)
        let catalog = RulesCatalog.decode(json, source: .bundle)
        // 空 id 与缺 id 的条目被丢掉，只保留 "a"。
        XCTAssertEqual(catalog.count, 1)
        XCTAssertNotNil(catalog["a"])
        XCTAssertNil(catalog.loadError)
        XCTAssertEqual(catalog.source, .bundle)
    }

    func testDecodeReportsDuplicatesAndKeepsLast() {
        let json = Data("""
        [
          {"id": "dup", "default_selected": true, "risk": "low"},
          {"id": "dup", "default_selected": false, "risk": "high"}
        ]
        """.utf8)
        let catalog = RulesCatalog.decode(json)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog["dup"]?.defaultSelected, false, "重复 id 后者生效")
        XCTAssertEqual(catalog["dup"]?.riskLevel, .high)
        XCTAssertNotNil(catalog.loadError)
    }

    func testDecodeInvalidJSONYieldsEmptyCatalogWithError() {
        let catalog = RulesCatalog.decode(Data("{ not json".utf8), source: .none)
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertNotNil(catalog.loadError)
    }

    func testLoadFromEnvironmentText() {
        let env = ["MOLE_RULES_JSON": #"[{"id":"env-rule","default_selected":true,"needs_admin":false,"risk":"high"}]"#]
        let catalog = RulesCatalog.load(environment: env)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.source, .environment("MOLE_RULES_JSON"))
        XCTAssertEqual(catalog["env-rule"]?.riskLevel, .high)
    }

    // MARK: 覆盖

    func testOverrideReplacesEngineValues() throws {
        let catalog = try sampleCatalog()

        // 引擎说 false，rules.json 说 true。
        let installer = CleanPreviewItem(ruleID: "installer-dmg",
                                         path: "/Users/demo/Downloads/a.dmg",
                                         defaultSelected: false,
                                         needsAdmin: true,
                                         risk: "low")
        let appliedInstaller = catalog.apply(to: installer)
        XCTAssertTrue(appliedInstaller.defaultSelected)
        XCTAssertFalse(appliedInstaller.needsAdmin)
        XCTAssertEqual(appliedInstaller.risk, "medium")
        XCTAssertEqual(appliedInstaller.riskLevel, .medium)
        XCTAssertEqual(appliedInstaller.path, installer.path)

        // 引擎说 true/false，rules.json 说 false/true。
        let system = CleanPreviewItem(ruleID: "system-cache",
                                      path: "/Library/Caches/x",
                                      defaultSelected: true,
                                      needsAdmin: false,
                                      risk: "low")
        let appliedSystem = catalog.apply(to: system)
        XCTAssertFalse(appliedSystem.defaultSelected)
        XCTAssertTrue(appliedSystem.needsAdmin)
        XCTAssertEqual(appliedSystem.riskLevel, .high)

        // 未知 rule_id：完全保留引擎值。
        let unknown = CleanPreviewItem(ruleID: "not-in-rules",
                                       path: "/tmp/x",
                                       defaultSelected: true,
                                       needsAdmin: false,
                                       risk: "low")
        let appliedUnknown = catalog.apply(to: unknown)
        XCTAssertEqual(appliedUnknown, unknown)

        // rule_id 缺失：同样保留引擎值。
        let noID = CleanPreviewItem(path: "/tmp/y", defaultSelected: false, needsAdmin: true, risk: "high")
        XCTAssertEqual(catalog.apply(to: noID), noID)
    }

    func testPartialOverrideOnlyTouchesPresentFields() {
        let catalog = RulesCatalog(overrides: [
            "only-risk": RuleOverride(ruleID: "only-risk", risk: "high"),
            "only-default": RuleOverride(ruleID: "only-default", defaultSelected: false),
            "only-admin": RuleOverride(ruleID: "only-admin", needsAdmin: true)
        ])

        let item = CleanPreviewItem(ruleID: "only-risk",
                                    path: "/tmp/a",
                                    defaultSelected: true,
                                    needsAdmin: false,
                                    risk: "low")
        let appliedRisk = catalog.apply(to: item)
        XCTAssertEqual(appliedRisk.risk, "high")
        XCTAssertTrue(appliedRisk.defaultSelected, "rules.json 没写 default_selected 时保留引擎值")
        XCTAssertFalse(appliedRisk.needsAdmin, "rules.json 没写 needs_admin 时保留引擎值")

        let defaultItem = CleanPreviewItem(ruleID: "only-default",
                                           path: "/tmp/b",
                                           defaultSelected: true,
                                           needsAdmin: true,
                                           risk: "medium")
        let appliedDefault = catalog.apply(to: defaultItem)
        XCTAssertFalse(appliedDefault.defaultSelected)
        XCTAssertTrue(appliedDefault.needsAdmin)
        XCTAssertEqual(appliedDefault.risk, "medium")

        let adminItem = CleanPreviewItem(ruleID: "only-admin",
                                         path: "/tmp/c",
                                         defaultSelected: true,
                                         needsAdmin: false,
                                         risk: nil)
        let appliedAdmin = catalog.apply(to: adminItem)
        XCTAssertTrue(appliedAdmin.needsAdmin)
        XCTAssertTrue(appliedAdmin.defaultSelected)
        XCTAssertNil(appliedAdmin.risk)
    }

    func testAccessorsFallBackToEngineValue() {
        let catalog = RulesCatalog()

        XCTAssertTrue(catalog.defaultSelected(for: "anything", fallback: true))
        XCTAssertFalse(catalog.defaultSelected(for: nil, fallback: false))
        XCTAssertTrue(catalog.needsAdmin(for: "anything", fallback: true))
        XCTAssertEqual(catalog.risk(for: "anything", fallback: "medium"), "medium")
        XCTAssertNil(catalog.risk(for: "anything", fallback: nil))
        XCTAssertEqual(catalog.riskLevel(for: "anything", fallback: .high), .high)
    }

    func testApplyToPreviewKeepsOrderAndCount() throws {
        let catalog = try sampleCatalog()
        var items = try XCTUnwrap(Fixture.decode(CleanPreview.self, "clean-preview")).items
        items.append(CleanPreviewItem(ruleID: "xcode-derived-data",
                                      path: "/Users/demo/Library/Developer/Xcode/DerivedData",
                                      defaultSelected: false,
                                      needsAdmin: true,
                                      risk: "high"))
        let applied = catalog.apply(to: CleanPreview(items: items))

        XCTAssertEqual(applied.items.count, items.count)
        XCTAssertEqual(applied.items.map(\.path), items.map(\.path))
        // 样本里的 rule_id 都不在 rules-sample 中，所以除最后追加的那条外全部保持原样。
        XCTAssertEqual(Array(applied.items.dropLast()), Array(items.dropLast()))

        // 追加的条目命中 xcode-derived-data：false→true、true→false、high→low。
        let derived = try XCTUnwrap(applied.items.last)
        XCTAssertTrue(derived.defaultSelected)
        XCTAssertFalse(derived.needsAdmin)
        XCTAssertEqual(derived.riskLevel, .low)
    }
}
