import SwiftUI

// MARK: - 清理页

struct CleanView: View {
    @StateObject private var model: CleanViewModel
    @State private var showConfirm = false
    @State private var didAutoScan = false

    init(catalog: RulesCatalog) {
        _model = StateObject(wrappedValue: CleanViewModel(catalog: catalog))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if model.result == nil {
                Divider()
                footer
            }
        }
        .navigationTitle("清理")
        .onAppear {
            // 截图/调试用：-MoleLiteAutoScan 1 时自动做一次预览扫描（只读 dry-run，不删除）。
            guard !didAutoScan, UserDefaults.standard.bool(forKey: "MoleLiteAutoScan") else { return }
            didAutoScan = true
            Task { await model.scan() }
        }
        .alert("确认永久删除？", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) {
                Task { await model.execute() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可清理项目")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                Button("取消扫描") { model.cancel() }
            } else if model.hasPreview {
                Button("重新扫描") {
                    Task { await model.scan() }
                }
                .disabled(model.isExecuting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if model.isScanning { return "正在让引擎统计可清理内容，请稍候。" }
        guard model.hasPreview else { return "先扫描一次，所有删除都只针对本次扫描结果。" }
        let base = "\(model.items.count) 项，共 \(ByteFormat.string(model.totalBytes))"
        guard let scannedAt = model.lastScannedAt else { return base }
        let time = scannedAt.formatted(date: .omitted, time: .shortened)
        return "\(base) · \(time) 扫描"
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if let summary = model.resultSummary {
            CleanResultView(summary: summary,
                            note: model.errorMessage,
                            logLines: model.logLines) {
                model.finishResult()
            }
        } else if model.isScanning && model.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在扫描…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else {
            itemList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有可清理的内容", systemImage: "sparkles")
        } description: {
            if let message = model.errorMessage {
                Text(message)
            } else {
                Text("点击“开始扫描”，查看引擎找到的缓存、日志与废纸篓项目。")
            }
        } actions: {
            Button("开始扫描") {
                Task { await model.scan() }
            }
            .disabled(model.isScanning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(model.groupedItems) { group in
                Section {
                    ForEach(group.items) { item in
                        CleanItemRow(
                            item: item,
                            isSelected: model.isSelected(item),
                            disabled: model.isExecuting || model.isScanning
                        ) { selected in
                            model.setSelected(item, selected)
                        }
                    }
                } header: {
                    HStack {
                        Text(CleanSection.title(group.section))
                        Spacer()
                        Text(ByteFormat.string(group.items.reduce(0) { $0 + $1.sizeBytes }))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if model.hasPreview && model.result == nil {
                Toggle("全选", isOn: Binding(
                    get: { !model.selectableItems.isEmpty && model.selectedItems.count == model.selectableItems.count },
                    set: { model.selectAll($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.isExecuting || model.isScanning)
            }

            Text(model.hasPreview ? model.selectionSummary : "尚未扫描")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if model.isExecuting {
                ProgressView()
                    .controlSize(.small)
                Button("取消") { model.cancel() }
            }

            Button("清理所选") {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExecute)
            .help(model.canExecute ? "确认后永久删除勾选的项目" : "先扫描并勾选至少一项")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var confirmationMessage: String {
        let count = model.selectedItems.count
        let size = ByteFormat.string(model.selectedBytes)
        return """
        永久删除，不进废纸篓。

        共 \(count) 项，合计 \(size)。删除后无法恢复；需要管理员权限的项目不在本次范围内。
        """
    }
}

// MARK: - 单行

private struct CleanItemRow: View {
    let item: CleanPreviewItem
    let isSelected: Bool
    let disabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(disabled || item.needsAdmin)
                .help(item.needsAdmin ? "需要管理员权限，本版本不执行" : "")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.body)
                    .foregroundStyle(item.needsAdmin ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    RiskBadge(level: item.riskLevel)
                    if item.needsAdmin {
                        Label("需管理员", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if !item.sizeKnown {
                        Text("大小未知")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let count = item.itemCount, count > 0 {
                        Text("\(count) 个文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(item.sizeKnown ? ByteFormat.string(item.sizeBytes) : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .opacity(item.needsAdmin ? 0.65 : 1)
    }
}

// MARK: - section 名称

enum CleanSection {
    static func title(_ raw: String) -> String {
        let known: [String: String] = [
            "trash": "废纸篓",
            "user_cache": "用户缓存",
            "system_cache": "系统缓存",
            "logs": "日志",
            "dev_cache": "开发缓存",
            "downloads": "下载",
            "browser": "浏览器",
            "app_cache": "应用缓存",
            "system_logs": "系统日志",
            "other": "其他"
        ]
        if let title = known[raw.lowercased()] { return title }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
