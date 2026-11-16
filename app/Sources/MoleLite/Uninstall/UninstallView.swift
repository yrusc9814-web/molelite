import SwiftUI

// MARK: - 卸载页

/// 一张应用清单：点开某个应用就地展开它的本体与残留，勾选后在底栏确认移到废纸篓。
struct UninstallView: View {
    @StateObject private var model: UninstallViewModel
    @State private var query = ""
    @State private var showConfirm = false
    @State private var staffCount = 0

    private let palette = PagePalette.uninstall

    init(catalog: RulesCatalog) {
        _model = StateObject(wrappedValue: UninstallViewModel(catalog: catalog))
    }

    var body: some View {
        ZStack {
            if let summary = model.resultSummary {
                UninstallResultView(
                    appName: model.executedAppName,
                    summary: summary,
                    note: model.errorMessage,
                    logLines: model.logLines
                ) {
                    model.finishResult()
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    staffHeader
                    appList
                    if model.selectedApp != nil {
                        bottomBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.selectedApp?.id)
        .onAppear {
            model.reloadApps()
            // 截图/调试用：-MoleLiteAutoScan 1 且起始页是卸载时，自动选中一个应用并预览（只读 dry-run）。
            // -MoleLiteAutoApp <名字> 指定应用，默认取列表第一个。
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "MoleLiteAutoScan"),
               defaults.string(forKey: "MoleLiteStartSection") == "uninstall",
               model.selectedApp == nil {
                let wanted = defaults.string(forKey: "MoleLiteAutoApp")
                let pick = model.apps.first { app in
                    guard let wanted else { return false }
                    return app.name.localizedCaseInsensitiveContains(wanted)
                } ?? model.apps.first
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

    // MARK: 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField("搜索应用或 Bundle ID", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 320)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))

            Spacer()

            HStack(spacing: 4) {
                Text("已安装应用")
                    .font(.system(size: 12, weight: .semibold))
                MetaText("\(visibleApps.count) 个")
            }

            Button {
                model.reloadApps()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GhostButtonStyle())
            .help("重新扫描 /Applications 与 ~/Applications")
            .disabled(model.isExecuting || model.isPreviewing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    // MARK: 乐句页头

    /// 选中应用后一句下行乐句淡入；确认卸载时从右往左淡出下坠。
    private var staffHeader: some View {
        HStack(spacing: 28) {
            NoteStaffView(phrase: .uninstall, visibleCount: staffCount, dropOnHide: true)
                .frame(width: 360, height: 112)
                .modifier(StaffProgress(busy: model.isPreviewing,
                                        done: model.hasPreview && !model.isExecuting,
                                        total: StaffPhrase.uninstall.elements.count,
                                        count: $staffCount, interval: 0.12))
            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedApp?.name ?? "选择要卸载的应用")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(staffSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 6)
    }

    private var staffSubtitle: String {
        if model.isExecuting { return "正在移到废纸篓…可以从废纸篓恢复" }
        if model.isPreviewing { return "正在查找残留…" }
        if model.hasPreview {
            return "本体 + \(max(0, model.items.count - 1)) 项残留 · 已选 \(ByteFormat.string(model.selectedBytes))"
        }
        return "会连同偏好设置、缓存等残留一起找出来"
    }

    // MARK: 应用清单

    private var visibleApps: [InstalledApp] {
        model.filteredApps(query: query)
    }

    @ViewBuilder
    private var appList: some View {
        if visibleApps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white.opacity(0.3))
                Text(query.isEmpty ? "没有找到应用" : "没有匹配的应用")
                    .font(.system(size: 14, weight: .semibold))
                MetaText(query.isEmpty ? "只列出 /Applications 与 ~/Applications 下的 .app" : "换个关键词，或清空搜索")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleApps) { app in
                        appRow(app)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isOpen = model.selectedApp?.id == app.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: AppIconCache.icon(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    MetaText(app.bundleID ?? (app.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isOpen {
                    if model.isPreviewing {
                        ProgressView().controlSize(.small)
                        MetaText("正在查找残留…", opacity: 0.6)
                    } else if model.hasPreview {
                        MetaText("共 \(model.items.count) 项 · 已选 \(ByteFormat.string(model.selectedBytes))", opacity: 0.7)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !model.isExecuting, !model.isPreviewing else { return }
                model.select(isOpen ? nil : app)
            }

            if isOpen {
                detail
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isOpen ? 0.07 : 0.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(isOpen ? 0.10 : 0.0))
        )
    }

    // MARK: 展开后的明细

    @ViewBuilder
    private var detail: some View {
        if model.isPreviewing && model.items.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                MetaText("正在读取应用本体与残留文件，只读不改动…", opacity: 0.6)
            }
            .padding(.vertical, 12)
        } else if model.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                }
                Button("重新预览") { Task { await model.loadPreview() } }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                }
                if !model.appBundleItems.isEmpty {
                    groupBlock(title: "应用本体", items: model.appBundleItems)
                }
                if model.leftoverGroups.isEmpty {
                    MetaText("没有发现残留文件。")
                } else {
                    ForEach(model.leftoverGroups) { group in
                        groupBlock(title: group.title, items: group.items)
                    }
                }
            }
        }
    }

    private func groupBlock(title: String, items: [UninstallPreviewItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                MetaText("\(items.count) 项 · \(ByteFormat.string(items.reduce(Int64(0)) { $0 + $1.sizeBytes }))")
            }
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(items) { item in
                UninstallItemRow(
                    item: item,
                    isSelected: model.isSelected(item),
                    disabled: model.isExecuting || model.isPreviewing,
                    tint: palette.accent,
                    onToggle: { model.setSelected(item, $0) }
                )
            }
        }
    }

    // MARK: 底栏

    private var bottomBar: some View {
        BottomBar {
            if let app = model.selectedApp {
                Image(nsImage: AppIconCache.icon(for: app.path))
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasPreview ? "已选 \(model.selectedItems.count) 项 · \(ByteFormat.string(model.selectedBytes))" : "等待预览")
                    .font(.system(size: 13, weight: .semibold))
                MetaText("移到废纸篓，可以从废纸篓恢复", opacity: 0.55)
            }
            if model.hasPreview {
                Button(allSelected ? "全部取消" : "全选") {
                    model.selectAll(!allSelected)
                }
                .buttonStyle(LinkButtonStyle(color: palette.accent))
                .disabled(model.isExecuting || model.isPreviewing)
            }
            Spacer()
            if model.isExecuting || model.isPreviewing {
                ProgressView().controlSize(.small)
                Button("取消") { model.cancel() }
                    .buttonStyle(GhostButtonStyle())
            }
            Button("卸载 \(model.selectedItems.count) 项") {
                showConfirm = true
            }
            .buttonStyle(CapsuleButtonStyle(minWidth: 180))
            .disabled(!model.canExecute)
        }
    }

    private var allSelected: Bool {
        !model.selectableItems.isEmpty && model.selectedItems.count == model.selectableItems.count
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
