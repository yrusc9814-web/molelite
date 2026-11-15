import Foundation

// MARK: - 已安装应用

/// `/Applications` 与 `~/Applications` 里的一个 `.app`。
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let bundleID: String?

    public var id: String { path }

    public init(name: String, path: String, bundleID: String?) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }
}

// MARK: - 残留分组

public struct UninstallLeftoverGroup: Identifiable {
    public let kind: String
    public let title: String
    public let items: [UninstallPreviewItem]

    public var id: String { kind }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

public enum UninstallKind {
    public static func title(_ raw: String) -> String {
        let known: [String: String] = [
            "app_support": "应用支持",
            "caches": "缓存",
            "preferences": "偏好设置",
            "launch_agent": "启动项",
            "launch_daemon": "系统启动项",
            "logs": "日志",
            "containers": "容器",
            "saved_state": "窗口状态",
            "app": "应用本体",
            "other": "其他残留"
        ]
        return known[raw.lowercased()] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - 结果汇总

/// 按 trashed / removed / skipped / failed 归类，空组不显示。
public struct UninstallResultSummary {
    public let trashed: [UninstallExecutionRecord]
    public let removed: [UninstallExecutionRecord]
    public let skipped: [UninstallExecutionRecord]
    public let failed: [UninstallExecutionRecord]

    public init(records: [UninstallExecutionRecord]) {
        trashed = records.filter { $0.actionKind == .trashed }
        removed = records.filter { $0.actionKind == .removed }
        skipped = records.filter { $0.actionKind == .skipped }
        failed = records.filter { $0.actionKind == .failed }
    }

    public var hasPermanentRemoval: Bool { !removed.isEmpty }
    public var isEmpty: Bool { trashed.isEmpty && removed.isEmpty && skipped.isEmpty && failed.isEmpty }

    public var headline: String {
        let trashedSize = ByteFormat.string(bytes(of: trashed))
        return "移到废纸篓 \(trashed.count) 项（\(trashedSize)），"
            + "永久删除 \(removed.count) 项，跳过 \(skipped.count) 项，失败 \(failed.count) 项。"
    }

    public func bytes(of records: [UninstallExecutionRecord]) -> Int64 {
        records.reduce(0) { $0 + $1.sizeBytes }
    }
}
