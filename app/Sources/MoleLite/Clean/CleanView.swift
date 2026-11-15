import SwiftUI

// MARK: - 清理页

/// 两段式：先是“星球 + 可清理总量”的首屏，点“查看清单”进入分类清单再勾选、确认。
struct CleanView: View {
    @StateObject private var model: CleanViewModel
    @State private var showConfirm = false
    @State private var didAutoScan = false
    @State private var reviewing = false
    @State private var expanded: Set<String> = []

    private let palette = PagePalette.clean

    init(catalog: RulesCatalog) {
        _model = StateObject(wrappedValue: CleanViewModel(catalog: catalog))
    }

    var body: some View {
        ZStack {
            if let summary = model.resultSummary {
                CleanResultView(summary: summary,
                                note: model.errorMessage,
                                logLines: model.logLines) {
                    model.finishResult()
                    reviewing = false
                }
                .scrollContentBackground(.hidden)
                .transition(.opacity)
            } else if reviewing && model.hasPreview {
                review
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                hero
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: reviewing)
        .animation(.easeInOut(duration: 0.28), value: model.resultSummary == nil)
        .onAppear {
            // 截图/调试用：-MoleLiteAutoScan 1 且起始页是清理时，自动做一次预览扫描（只读 dry-run）。
            guard !didAutoScan,
                  UserDefaults.standard.bool(forKey: "MoleLiteAutoScan"),
                  (UserDefaults.standard.string(forKey: "MoleLiteStartSection") ?? "clean") == "clean"
            else { return }
            didAutoScan = true
            Task {
                await model.scan()
                if UserDefaults.standard.bool(forKey: "MoleLiteAutoReview") {
                    reviewing = true
                    expanded = Set(model.groupedItems.prefix(2).map(\.id))
                }
            }
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

    // MARK: 首屏

    private var hero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            OrbView(palette: palette, size: 250, busy: model.isScanning)
            Spacer().frame(height: 44)

            Text(heroTitle)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 6) {
                Text(heroSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.55))
                if model.hasPreview && !model.isScanning {
                    Text("·").foregroundStyle(Color.white.opacity(0.4))
                    Button("重新扫描") { Task { await model.scan() } }
                        .buttonStyle(LinkButtonStyle(color: palette.accent))
                }
            }
            .padding(.top, 8)

            if let message = model.errorMessage, !model.isScanning {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 10)
                    .frame(maxWidth: 520)
            }

            Group {
                if model.isScanning {
                    Button("取消扫描") { model.cancel() }
                } else if model.hasPreview {
                    Button("查看清单") {
                        expanded = Set(model.groupedItems.prefix(2).map(\.id))
                        reviewing = true
                    }
                } else {
                    Button("开始扫描") { Task { await model.scan() } }
                }
            }
            .buttonStyle(CapsuleButtonStyle())
            .padding(.top, 22)

            Spacer(minLength: 20)
            Text("只列出引擎认定可安全重建的缓存、日志与废纸篓内容；删除前一定会再确认。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroTitle: String {
        if model.isScanning { return "正在扫描…" }
        if model.hasPreview { return "发现 \(ByteFormat.string(model.totalBytes))" }
        return "准备好了"
    }

    private var heroSubtitle: String {
        if model.isScanning { return "正在统计缓存、日志、开发工具产物" }
        if model.hasPreview {
            return "\(model.items.count) 项，分布在 \(model.groupedItems.count) 个类别"
        }
        return "扫描只读取文件信息，不会删除任何东西"
    }

    // MARK: 清单

    private var review: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    reviewing = false
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("清理清单")
                        .font(.system(size: 15, weight: .semibold))
                    MetaText("\(model.items.count) 项 · \(ByteFormat.string(model.totalBytes))")
                }
                Spacer()
                Button(allSelected ? "全部取消" : "全选") {
                    model.selectAll(!allSelected)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isExecuting)
                Button {
                    Task { await model.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isExecuting || model.isScanning)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .card()
                    }
                    ForEach(model.groupedItems) { group in
                        categoryCard(group)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }

            BottomBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已选 \(model.selectedItems.count) 项")
                        .font(.system(size: 13, weight: .semibold))
                    MetaText("将释放 \(ByteFormat.string(model.selectedBytes)) · 永久删除，不进废纸篓", opacity: 0.55)
                }
                Spacer()
                if model.isExecuting {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }
                        .buttonStyle(GhostButtonStyle())
                }
                Button("清理 \(model.selectedItems.count) 项") {
                    showConfirm = true
                }
                .buttonStyle(CapsuleButtonStyle(minWidth: 180))
                .disabled(!model.canExecute)
            }
        }
    }

    private var allSelected: Bool {
        !model.selectableItems.isEmpty && model.selectedItems.count == model.selectableItems.count
    }

    private func categoryCard(_ group: CleanSectionGroup) -> some View {
        let isOpen = expanded.contains(group.id)
        let selectable = group.items.filter { !$0.needsAdmin }
        let picked = selectable.filter { model.isSelected($0) }
        let all = !selectable.isEmpty && picked.count == selectable.count
        let some = !picked.isEmpty && !all
        let pickedBytes = picked.reduce(Int64(0)) { $0 + $1.sizeBytes }

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(isOn: all, mixed: some, tint: palette.accent,
                         disabled: selectable.isEmpty || model.isExecuting) {
                    let target = !all
                    for item in selectable { model.setSelected(item, target) }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(CleanSection.tint(group.section).opacity(0.22))
                    Image(systemName: CleanSection.symbol(group.section))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CleanSection.tint(group.section))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(CleanSection.title(group.section))
                        .font(.system(size: 14, weight: .semibold))
                    MetaText("\(group.items.count) 项 · 已选 \(ByteFormat.string(pickedBytes))")
                }
                Spacer()
                Text(ByteFormat.string(group.totalBytes))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
            }

            if isOpen {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    .padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        CleanItemRow(
                            item: item,
                            isSelected: model.isSelected(item),
                            disabled: model.isExecuting || model.isScanning,
                            tint: palette.accent
                        ) {
                            model.setSelected(item, !model.isSelected(item))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .card(highlighted: isOpen)
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
    let tint: Color
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(isOn: isSelected, tint: tint, disabled: disabled || item.needsAdmin, action: onToggle)
                .help(item.needsAdmin ? "需要管理员权限，本版本不执行" : "")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    RiskBadge(level: item.riskLevel)
                    if item.needsAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }
                }
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text(item.sizeKnown ? ByteFormat.string(item.sizeBytes) : "大小未知")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .opacity(item.needsAdmin ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if !(disabled || item.needsAdmin) { onToggle() }
        }
    }
}

// MARK: - section 名称、图标、颜色

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

    /// 按关键词挑一个 SF Symbol；引擎的 section 名称不固定，所以用包含判断。
    static func symbol(_ raw: String) -> String {
        let key = raw.lowercased()
        let table: [(String, String)] = [
            ("trash", "trash.fill"),
            ("browser", "globe"),
            ("safari", "safari"),
            ("chrome", "globe"),
            ("log", "doc.text.fill"),
            ("dev", "hammer.fill"),
            ("xcode", "hammer.fill"),
            ("download", "arrow.down.circle.fill"),
            ("system", "gearshape.2.fill"),
            ("essential", "person.crop.circle.fill"),
            ("user", "person.crop.circle.fill"),
            ("app", "square.stack.3d.up.fill"),
            ("cache", "internaldrive.fill"),
            ("ai", "sparkles"),
            ("cloud", "icloud.fill"),
            ("mail", "envelope.fill"),
            ("media", "photo.fill")
        ]
        for (needle, symbol) in table where key.contains(needle) { return symbol }
        return "folder.fill"
    }

    /// 同一个 section 名称总是得到同一种颜色。
    static func tint(_ raw: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.48, green: 0.72, blue: 1.0),
            Color(red: 0.55, green: 0.86, blue: 0.70),
            Color(red: 1.0, green: 0.74, blue: 0.45),
            Color(red: 0.93, green: 0.55, blue: 0.70),
            Color(red: 0.72, green: 0.62, blue: 1.0),
            Color(red: 0.45, green: 0.86, blue: 0.90),
            Color(red: 0.96, green: 0.84, blue: 0.45)
        ]
        let hash = raw.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return colors[hash % colors.count]
    }
}
