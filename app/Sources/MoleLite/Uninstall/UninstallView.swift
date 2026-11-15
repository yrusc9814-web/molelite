import SwiftUI

// MARK: - 卸载页

struct UninstallView: View {
    @StateObject private var model: UninstallViewModel
    @State private var query = ""
    @State private var showConfirm = false

    init(catalog: RulesCatalog) {
        _model = StateObject(wrappedValue: UninstallViewModel(catalog: catalog))
    }

    var body: some View {
        HStack(spacing: 0) {
            appColumn
            Divider()
            detailColumn
        }
        .navigationTitle("卸载")
        .onAppear {
            model.reloadApps()
            // 截图/调试用：-MoleLiteAutoScan 1 时自动选中一个应用并预览（只读 dry-run，不卸载）。
            // -MoleLiteAutoApp <名字> 指定应用，默认取列表第一个。
            if UserDefaults.standard.bool(forKey: "MoleLiteAutoScan"), model.selectedApp == nil {
                let wanted = UserDefaults.standard.string(forKey: "MoleLiteAutoApp")
                let pick = model.apps.first { wanted != nil && $0.name.localizedCaseInsensitiveContains(wanted!) } ?? model.apps.first
                if let pick { model.select(pick) }
            }
        }
        .alert("确认移到废纸篓？", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                Task { await model.execute() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: 左栏：应用列表

    private var appColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索应用或 Bundle ID", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Text("\(visibleApps.count) 个应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.reloadApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新扫描 /Applications 与 ~/Applications")
                    .disabled(model.isExecuting || model.isPreviewing)
                }
            }
            .padding(12)

            Divider()

            if visibleApps.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "没有找到应用" : "没有匹配的应用",
                          systemImage: "square.grid.2x2")
                } description: {
                    Text(query.isEmpty
                         ? "只列出 /Applications 与 ~/Applications 下的 .app。"
                         : "换个关键词，或清空搜索。")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedApp?.id },
                    set: { id in
                        model.select(visibleApps.first { $0.id == id })
                    }
                )) {
                    ForEach(visibleApps) { app in
                        InstalledAppRow(app: app)
                            .tag(app.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 240, idealWidth: 268, maxWidth: 340)
        .disabled(model.isExecuting)
    }

    private var visibleApps: [InstalledApp] {
        model.filteredApps(query: query)
    }

    // MARK: 右栏

    @ViewBuilder
    private var detailColumn: some View {
        if let summary = model.resultSummary {
            UninstallResultView(
                appName: model.executedAppName,
                summary: summary,
                note: model.errorMessage,
                logLines: model.logLines
            ) {
                model.finishResult()
            }
        } else if let app = model.selectedApp {
            VStack(spacing: 0) {
                previewHeader(app)
                Divider()
                previewBody
                if model.hasPreview {
                    Divider()
                    footer
                }
            }
        } else {
            ContentUnavailableView {
                Label("选择一个应用", systemImage: "trash")
            } description: {
                Text("从左侧选一个应用，先预览应用本体与残留文件，确认后再移到废纸篓。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeader(_ app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(app.bundleID ?? app.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.isPreviewing {
                ProgressView().controlSize(.small)
                Button("取消") { model.cancel() }
            } else {
                Button(model.hasPreview ? "重新预览" : "预览") {
                    Task { await model.loadPreview() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecuting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var previewBody: some View {
        if model.isPreviewing && model.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在查找应用与残留文件…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            ContentUnavailableView {
                Label("还没有预览", systemImage: "doc.text.magnifyingglass")
            } description: {
                if let message = model.errorMessage {
                    Text(message)
                } else {
                    Text("预览只会读取文件列表，不会改动任何东西。")
                }
            } actions: {
                Button("开始预览") {
                    Task { await model.loadPreview() }
                }
                .disabled(model.isPreviewing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let message = model.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if !model.appBundleItems.isEmpty {
                    Section("应用本体") {
                        ForEach(model.appBundleItems) { item in
                            UninstallItemRow(
                                item: item,
                                isSelected: model.isSelected(item),
                                disabled: model.isExecuting || model.isPreviewing,
                                onToggle: { model.setSelected(item, $0) }
                            )
                        }
                    }
                }
                Section("残留文件") {
                    if model.leftoverGroups.isEmpty {
                        Text("没有发现残留文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.leftoverGroups) { group in
                        DisclosureGroup {
                            ForEach(group.items) { item in
                                UninstallItemRow(
                                    item: item,
                                    isSelected: model.isSelected(item),
                                    disabled: model.isExecuting || model.isPreviewing,
                                    onToggle: { model.setSelected(item, $0) }
                                )
                            }
                        } label: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.items.count) 项 · \(ByteFormat.string(group.totalBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("全选", isOn: Binding(
                get: {
                    !model.selectableItems.isEmpty
                        && model.selectedItems.count == model.selectableItems.count
                },
                set: { model.selectAll($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(model.isExecuting || model.isPreviewing)

            Text(model.selectionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if model.isExecuting {
                ProgressView().controlSize(.small)
                Button("取消") { model.cancel() }
            }

            Button("卸载所选") {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExecute)
            .help(model.canExecute ? "确认后把勾选的项目移到废纸篓" : "先预览并勾选至少一项")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var confirmationMessage: String {
        let app = model.selectedApp?.name ?? "该应用"
        let count = model.selectedItems.count
        let size = ByteFormat.string(model.selectedBytes)
        return """
        将 \(app) 的 \(count) 个项目移到废纸篓，合计 \(size)。

        移到废纸篓后还能恢复；个别项目若无法放入废纸篓，会在结果页单列并醒目标出。
        """
    }
}
