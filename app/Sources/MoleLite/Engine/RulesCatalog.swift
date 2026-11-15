import Foundation

// MARK: - 规则覆盖项

/// rules.json 中与界面直接相关的字段。
/// 只有显式出现的字段才覆盖引擎输出；缺失或 null 保持引擎值。
public struct RuleOverride: Codable, Hashable, Sendable {
    public var ruleID: String
    public var defaultSelected: Bool?
    public var needsAdmin: Bool?
    public var risk: String?

    public var riskLevel: RiskLevel? {
        risk.map { RiskLevel(raw: $0) }
    }

    public init(
        ruleID: String,
        defaultSelected: Bool? = nil,
        needsAdmin: Bool? = nil,
        risk: String? = nil
    ) {
        self.ruleID = ruleID
        self.defaultSelected = defaultSelected
        self.needsAdmin = needsAdmin
        self.risk = risk
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID = "id"
        case defaultSelected = "default_selected"
        case needsAdmin = "needs_admin"
        case risk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = c.flexString(.ruleID) ?? ""
        defaultSelected = c.flexBool(.defaultSelected)
        needsAdmin = c.flexBool(.needsAdmin)
        risk = c.flexString(.risk)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ruleID, forKey: .ruleID)
        try c.encodeIfPresent(defaultSelected, forKey: .defaultSelected)
        try c.encodeIfPresent(needsAdmin, forKey: .needsAdmin)
        try c.encodeIfPresent(risk, forKey: .risk)
    }
}

// MARK: - 目录

/// rules.json 的只读索引。加载失败不阻断启动：保留空目录并把原因暴露给"关于"页。
public struct RulesCatalog: Sendable {
    public enum Source: Sendable, Equatable {
        case environment(String)
        case bundle
        case executableDirectory
        case none
    }

    public private(set) var overrides: [String: RuleOverride]
    public private(set) var source: Source
    /// 为空表示加载成功或尚未尝试；非空是给诊断界面看的简短原因。
    public private(set) var loadError: String?

    public init(
        overrides: [String: RuleOverride] = [:],
        source: Source = .none,
        loadError: String? = nil
    ) {
        self.overrides = overrides
        self.source = source
        self.loadError = loadError
    }

    public var isEmpty: Bool { overrides.isEmpty }
    public var count: Int { overrides.count }

    public subscript(ruleID: String?) -> RuleOverride? {
        guard let ruleID, !ruleID.isEmpty else { return nil }
        return overrides[ruleID]
    }

    // MARK: 覆盖

    /// 引擎按 section 粗分，rules.json 是权威值；没有条目时保留 fallback。
    public func defaultSelected(for ruleID: String?, fallback: Bool) -> Bool {
        self[ruleID]?.defaultSelected ?? fallback
    }

    public func needsAdmin(for ruleID: String?, fallback: Bool) -> Bool {
        self[ruleID]?.needsAdmin ?? fallback
    }

    public func risk(for ruleID: String?, fallback: String?) -> String? {
        guard let value = self[ruleID]?.risk else { return fallback }
        return value
    }

    public func riskLevel(for ruleID: String?, fallback: RiskLevel) -> RiskLevel {
        self[ruleID]?.riskLevel ?? fallback
    }

    public func apply(to item: CleanPreviewItem) -> CleanPreviewItem {
        var copy = item
        copy.defaultSelected = defaultSelected(for: item.ruleID, fallback: item.defaultSelected)
        copy.needsAdmin = needsAdmin(for: item.ruleID, fallback: item.needsAdmin)
        copy.risk = risk(for: item.ruleID, fallback: item.risk)
        return copy
    }

    public func apply(to preview: CleanPreview) -> CleanPreview {
        CleanPreview(items: preview.items.map(apply(to:)))
    }

    // MARK: 加载

    public static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> RulesCatalog {
        if let raw = environment["MOLE_RULES_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            // 允许直接给 JSON 文本，方便测试；否则按路径读取。
            if raw.hasPrefix("[") || raw.hasPrefix("{") {
                return decode(Data(raw.utf8), source: .environment("MOLE_RULES_JSON"))
            }
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            guard fileManager.isReadableFile(atPath: url.path) else {
                return RulesCatalog(source: .environment(url.path),
                                    loadError: "MOLE_RULES_JSON 指向的文件不可读：\(url.path)")
            }
            return load(url: url, source: .environment(url.path))
        }

        if let url = bundle.url(forResource: "rules", withExtension: "json") {
            return load(url: url, source: .bundle)
        }

        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            let url = exe.appendingPathComponent("rules.json")
            if fileManager.isReadableFile(atPath: url.path) {
                return load(url: url, source: .executableDirectory)
            }
        }

        return RulesCatalog(source: .none, loadError: "未找到 rules.json（bundle / 可执行文件目录）")
    }

    public static func load(url: URL, source: Source) -> RulesCatalog {
        do {
            return decode(try Data(contentsOf: url), source: source)
        } catch {
            return RulesCatalog(source: source, loadError: "读取 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    public static func decode(_ data: Data, source: Source = .none) -> RulesCatalog {
        do {
            let entries = try JSONDecoder().decode([RuleOverride].self, from: data)
            var index: [String: RuleOverride] = [:]
            var duplicates = 0
            for entry in entries {
                let key = entry.ruleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                if index.updateValue(entry, forKey: key) != nil { duplicates += 1 }
            }
            return RulesCatalog(
                overrides: index,
                source: source,
                loadError: duplicates == 0 ? nil : "rules.json 有 \(duplicates) 个重复 id，后者生效"
            )
        } catch {
            return RulesCatalog(source: source, loadError: "解析 rules.json 失败：\(error.localizedDescription)")
        }
    }
}
