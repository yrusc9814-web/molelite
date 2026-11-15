import Foundation

// MARK: - 风险等级

/// 引擎与 rules.json 使用的风险字符串，未知值不报错，统一落到 unknown。
public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case unknown

    public init(raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        case .unknown: return "风险未知"
        }
    }
}

// MARK: - 执行动作

public enum ExecutionAction: String, Sendable {
    case removed
    case trashed
    case skipped
    case failed
    case unknown

    public init(raw: String?) {
        self = ExecutionAction(rawValue: raw?.lowercased() ?? "") ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .removed: return "已删除"
        case .trashed: return "已移到废纸篓"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .unknown: return "未知"
        }
    }
}

// MARK: - clean 预览

/// 对应 `clean --dry-run --json` 的每一条记录。
/// 字段来自 report/P3-summary.md：rule_id, section, path, size_bytes,
/// default_selected, needs_admin, risk, items, size_known, covered_by。
public struct CleanPreviewItem: Codable, Hashable, Identifiable, Sendable {
    public var ruleID: String?
    public var section: String?
    public var path: String
    public var sizeBytes: Int64
    public var defaultSelected: Bool
    public var needsAdmin: Bool
    public var risk: String?
    public var itemCount: Int?
    public var sizeKnown: Bool
    public var coveredBy: String?

    /// rule_id 会按路径重复，因此用 rule_id + path 作为稳定标识。
    public var id: String { "\(ruleID ?? "rule")|\(path)" }

    public var riskLevel: RiskLevel { RiskLevel(raw: risk) }

    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    public init(
        ruleID: String? = nil,
        section: String? = nil,
        path: String,
        sizeBytes: Int64 = 0,
        defaultSelected: Bool = false,
        needsAdmin: Bool = false,
        risk: String? = nil,
        itemCount: Int? = nil,
        sizeKnown: Bool = true,
        coveredBy: String? = nil
    ) {
        self.ruleID = ruleID
        self.section = section
        self.path = path
        self.sizeBytes = sizeBytes
        self.defaultSelected = defaultSelected
        self.needsAdmin = needsAdmin
        self.risk = risk
        self.itemCount = itemCount
        self.sizeKnown = sizeKnown
        self.coveredBy = coveredBy
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case section
        case path
        case sizeBytes = "size_bytes"
        case defaultSelected = "default_selected"
        case needsAdmin = "needs_admin"
        case risk
        case itemCount = "items"
        case sizeKnown = "size_known"
        case coveredBy = "covered_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = c.flexString(.ruleID)
        section = c.flexString(.section)
        path = c.flexString(.path) ?? ""
        let size = c.flexInt64(.sizeBytes)
        sizeBytes = size ?? 0
        defaultSelected = c.flexBool(.defaultSelected) ?? false
        needsAdmin = c.flexBool(.needsAdmin) ?? false
        risk = c.flexString(.risk)
        itemCount = c.flexInt(.itemCount)
        sizeKnown = c.flexBool(.sizeKnown) ?? (size != nil)
        coveredBy = c.flexString(.coveredBy)
    }
}

/// clean 预览可能是数组，也可能被包在 items/entries 里；两种都接受。
public struct CleanPreview: Codable, Sendable {
    public var items: [CleanPreviewItem]

    public init(items: [CleanPreviewItem] = []) {
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        items = try EnvelopeCoding.decodeArray(CleanPreviewItem.self, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for item in items {
            try container.encode(item)
        }
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - clean 执行

/// 对应 `clean --json` 的每一条记录：path, section, action, reason, size_bytes。
public struct CleanExecutionRecord: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var section: String?
    public var action: String?
    public var reason: String?
    public var sizeBytes: Int64

    public var id: String { "\(action ?? "unknown")|\(path)" }
    public var actionKind: ExecutionAction { ExecutionAction(raw: action) }
    public var succeeded: Bool { actionKind == .removed }

    public init(
        path: String,
        section: String? = nil,
        action: String? = nil,
        reason: String? = nil,
        sizeBytes: Int64 = 0
    ) {
        self.path = path
        self.section = section
        self.action = action
        self.reason = reason
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case section
        case action
        case reason
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.flexString(.path) ?? ""
        section = c.flexString(.section)
        action = c.flexString(.action)
        reason = c.flexString(.reason)
        sizeBytes = c.flexInt64(.sizeBytes) ?? 0
    }
}

public struct CleanExecutionReport: Codable, Sendable {
    public var records: [CleanExecutionRecord]

    public init(records: [CleanExecutionRecord] = []) {
        self.records = records
    }

    public init(from decoder: Decoder) throws {
        records = try EnvelopeCoding.decodeArray(CleanExecutionRecord.self, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for record in records {
            try container.encode(record)
        }
    }

    public var removed: [CleanExecutionRecord] { records.filter { $0.actionKind == .removed } }
    public var skipped: [CleanExecutionRecord] { records.filter { $0.actionKind == .skipped } }
    public var failed: [CleanExecutionRecord] { records.filter { $0.actionKind == .failed } }
    public var removedBytes: Int64 { removed.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - uninstall 预览

/// 对应 `uninstall --dry-run --json` 的每一条记录：
/// app, bundle_id, path, kind, size_bytes, default_selected,
/// needs_admin, risk, action, mode。
public struct UninstallPreviewItem: Codable, Hashable, Identifiable, Sendable {
    public var app: String?
    public var bundleID: String?
    public var path: String
    public var kind: String?
    public var sizeBytes: Int64
    public var defaultSelected: Bool
    public var needsAdmin: Bool
    public var risk: String?
    public var action: String?
    public var mode: String?

    public var id: String { "\(kind ?? "item")|\(path)" }
    public var riskLevel: RiskLevel { RiskLevel(raw: risk) }

    /// 只有引擎标成 `kind=app` 的条目才是应用本体。
    ///
    /// 注意不能用 `kind.contains("app")`：`app_support` 也含 "app"，
    /// 会把「应用支持」残留误判成应用本体，导致 leftovers 少一组。
    /// kind 缺失时退回到 `.app` 后缀判断。
    public var isAppBundle: Bool {
        let normalized = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !normalized.isEmpty {
            return normalized == "app"
        }
        return path.lowercased().hasSuffix(".app")
    }

    public var displayName: String {
        if isAppBundle {
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? (app ?? path) : name
        }
        return (path as NSString).lastPathComponent
    }

    public init(
        app: String? = nil,
        bundleID: String? = nil,
        path: String,
        kind: String? = nil,
        sizeBytes: Int64 = 0,
        defaultSelected: Bool = false,
        needsAdmin: Bool = false,
        risk: String? = nil,
        action: String? = nil,
        mode: String? = nil
    ) {
        self.app = app
        self.bundleID = bundleID
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.defaultSelected = defaultSelected
        self.needsAdmin = needsAdmin
        self.risk = risk
        self.action = action
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case bundleID = "bundle_id"
        case path
        case kind
        case sizeBytes = "size_bytes"
        case defaultSelected = "default_selected"
        case needsAdmin = "needs_admin"
        case risk
        case action
        case mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = c.flexString(.app)
        bundleID = c.flexString(.bundleID)
        path = c.flexString(.path) ?? ""
        kind = c.flexString(.kind)
        sizeBytes = c.flexInt64(.sizeBytes) ?? 0
        defaultSelected = c.flexBool(.defaultSelected) ?? false
        needsAdmin = c.flexBool(.needsAdmin) ?? false
        risk = c.flexString(.risk)
        action = c.flexString(.action)
        mode = c.flexString(.mode)
    }
}

public struct UninstallPreview: Codable, Sendable {
    public var items: [UninstallPreviewItem]

    public init(items: [UninstallPreviewItem] = []) {
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        items = try EnvelopeCoding.decodeArray(UninstallPreviewItem.self, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for item in items {
            try container.encode(item)
        }
    }

    public var appBundle: UninstallPreviewItem? { items.first(where: { $0.isAppBundle }) }
    public var leftovers: [UninstallPreviewItem] { items.filter { !$0.isAppBundle } }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - uninstall 执行

/// 对应 `uninstall --json` 的每一条记录：app, path, kind, action, reason, size_bytes。
public struct UninstallExecutionRecord: Codable, Hashable, Identifiable, Sendable {
    public var app: String?
    public var path: String
    public var kind: String?
    public var action: String?
    public var reason: String?
    public var sizeBytes: Int64

    public var id: String { "\(action ?? "unknown")|\(path)" }
    public var actionKind: ExecutionAction { ExecutionAction(raw: action) }
    /// removed 表示永久删除，界面上需要醒目标出。
    public var isPermanentRemoval: Bool { actionKind == .removed }

    public init(
        app: String? = nil,
        path: String,
        kind: String? = nil,
        action: String? = nil,
        reason: String? = nil,
        sizeBytes: Int64 = 0
    ) {
        self.app = app
        self.path = path
        self.kind = kind
        self.action = action
        self.reason = reason
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case path
        case kind
        case action
        case reason
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = c.flexString(.app)
        path = c.flexString(.path) ?? ""
        kind = c.flexString(.kind)
        action = c.flexString(.action)
        reason = c.flexString(.reason)
        sizeBytes = c.flexInt64(.sizeBytes) ?? 0
    }
}

public struct UninstallExecutionReport: Codable, Sendable {
    public var records: [UninstallExecutionRecord]

    public init(records: [UninstallExecutionRecord] = []) {
        self.records = records
    }

    public init(from decoder: Decoder) throws {
        records = try EnvelopeCoding.decodeArray(UninstallExecutionRecord.self, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for record in records {
            try container.encode(record)
        }
    }

    public var trashed: [UninstallExecutionRecord] { records.filter { $0.actionKind == .trashed } }
    public var removed: [UninstallExecutionRecord] { records.filter { $0.actionKind == .removed } }
    public var skipped: [UninstallExecutionRecord] { records.filter { $0.actionKind == .skipped } }
    public var failed: [UninstallExecutionRecord] { records.filter { $0.actionKind == .failed } }
    public var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.sizeBytes } }
    public var hasPermanentRemoval: Bool { !removed.isEmpty }
}

// MARK: - analyze

/// 对应 cmd/analyze/json.go 的 jsonOutput。
public struct AnalyzeOutput: Codable, Sendable {
    public var scanStatus: FlexibleString?
    public var path: String?
    public var overview: Bool
    public var entries: [AnalyzeEntry]
    public var largeFiles: [AnalyzeFileEntry]
    public var totalSize: Int64
    public var totalFiles: Int64?

    public init(
        scanStatus: FlexibleString? = nil,
        path: String? = nil,
        overview: Bool = false,
        entries: [AnalyzeEntry] = [],
        largeFiles: [AnalyzeFileEntry] = [],
        totalSize: Int64 = 0,
        totalFiles: Int64? = nil
    ) {
        self.scanStatus = scanStatus
        self.path = path
        self.overview = overview
        self.entries = entries
        self.largeFiles = largeFiles
        self.totalSize = totalSize
        self.totalFiles = totalFiles
    }

    private enum CodingKeys: String, CodingKey {
        case scanStatus = "scan_status"
        case path
        case overview
        case entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanStatus = try? c.decodeIfPresent(FlexibleString.self, forKey: .scanStatus)
        path = c.flexString(.path)
        overview = c.flexBool(.overview) ?? false
        entries = (try? c.decodeIfPresent([AnalyzeEntry].self, forKey: .entries)) ?? []
        largeFiles = (try? c.decodeIfPresent([AnalyzeFileEntry].self, forKey: .largeFiles)) ?? []
        totalSize = c.flexInt64(.totalSize) ?? 0
        totalFiles = c.flexInt64(.totalFiles)
    }

    public var sortedEntries: [AnalyzeEntry] {
        entries.sorted { $0.size > $1.size }
    }
}

/// 对应 jsonEntry。
public struct AnalyzeEntry: Codable, Hashable, Identifiable, Sendable {
    public var scanStatus: FlexibleString?
    public var name: String
    public var path: String
    public var size: Int64
    public var isDir: Bool
    public var insight: Bool
    public var cleanable: Bool
    public var lastAccess: String?

    public var id: String { path }

    public init(
        scanStatus: FlexibleString? = nil,
        name: String,
        path: String,
        size: Int64 = 0,
        isDir: Bool = false,
        insight: Bool = false,
        cleanable: Bool = false,
        lastAccess: String? = nil
    ) {
        self.scanStatus = scanStatus
        self.name = name
        self.path = path
        self.size = size
        self.isDir = isDir
        self.insight = insight
        self.cleanable = cleanable
        self.lastAccess = lastAccess
    }

    private enum CodingKeys: String, CodingKey {
        case scanStatus = "scan_status"
        case name
        case path
        case size
        case isDir = "is_dir"
        case insight
        case cleanable
        case lastAccess = "last_access"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanStatus = try? c.decodeIfPresent(FlexibleString.self, forKey: .scanStatus)
        name = c.flexString(.name) ?? ""
        path = c.flexString(.path) ?? ""
        size = c.flexInt64(.size) ?? 0
        isDir = c.flexBool(.isDir) ?? false
        insight = c.flexBool(.insight) ?? false
        cleanable = c.flexBool(.cleanable) ?? false
        lastAccess = c.flexString(.lastAccess)
    }
}

/// 对应 jsonFileEntry。
public struct AnalyzeFileEntry: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var path: String
    public var size: Int64

    public var id: String { path }

    public init(name: String = "", path: String, size: Int64 = 0) {
        self.name = name
        self.path = path
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name) ?? ""
        path = c.flexString(.path) ?? ""
        size = c.flexInt64(.size) ?? 0
    }
}

// MARK: - 容错基础

/// scan_status 在不同引擎版本里可能是字符串或数字，保留原始文本即可。
public struct FlexibleString: Codable, Hashable, Sendable, CustomStringConvertible {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let s = try? single.decode(String.self) {
            value = s
        } else if let i = try? single.decode(Int64.self) {
            value = String(i)
        } else if let d = try? single.decode(Double.self) {
            value = String(d)
        } else if let b = try? single.decode(Bool.self) {
            value = String(b)
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(value)
    }

    public var description: String { value }
}

/// 顶层可能是数组，也可能是带 items/entries/... 的对象。
enum EnvelopeCoding {
    static let arrayKeys = ["items", "entries", "results", "records", "data", "paths"]
    /// 所有条目（clean/uninstall 预览与执行记录、analyze 条目）都必带 path。
    static let itemIdentityKey = "path"

    static func decodeArray<T: Decodable>(_ type: T.Type, from decoder: Decoder) throws -> [T] {
        let single = try decoder.singleValueContainer()
        if let array = try? single.decode([T].self) {
            return array
        }

        let keyed = try decoder.container(keyedBy: FlexibleKey.self)
        for name in arrayKeys {
            let key = FlexibleKey(name)
            guard keyed.contains(key) else { continue }
            if let array = try? keyed.decode([T].self, forKey: key) {
                return array
            }
            if let one = try? keyed.decode(T.self, forKey: key) {
                return [one]
            }
        }

        // 单条对象直接返回一条；完全陌生或空对象返回空数组而不是崩溃。
        //
        // 这里必须先确认对象里真的有条目字段：各条目的 init(from:) 对缺字段一律给默认值、
        // 不会抛错，所以单靠 `try? T(from:)` 会把 {"unexpected": true} 解成一条空条目。
        // 四种条目都必有 path，用它作为“这是条目本身”的最小判据。
        if keyed.contains(FlexibleKey(itemIdentityKey)),
           let one = try? T(from: decoder) {
            return [one]
        }
        return []
    }
}

struct FlexibleKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
}

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent([String].self, forKey: key) {
            return value.joined(separator: ", ")
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func flexBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y", "on": return true
            case "false", "0", "no", "n", "off": return false
            default: return nil
            }
        }
        return nil
    }

    func flexInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        guard let value = flexInt64(key) else { return nil }
        return Int(clamping: value)
    }
}

// MARK: - 展示辅助

public enum ByteFormat {
    /// 文件大小展示；负数按 0 处理，避免界面出现奇怪数值。
    public static func string(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }
}
