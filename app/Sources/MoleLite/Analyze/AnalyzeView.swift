import Foundation
import SwiftUI

// MARK: - 磁盘分析页

/// 只读页面：左侧星球与目录清单，右侧矩形树图；可以下钻、返回上级、在 Finder 中显示，没有删除入口。
struct AnalyzeView: View {
    @ObservedObject var model: AnalyzeViewModel
    private let palette = PagePalette.analyze
    @State private var staffCount = 0

    private var staffPhrase: StaffPhrase {
        let top = model.sortedEntries.prefix(10).map { Double($0.size) / Double(max(1, model.maxEntrySize)) }
        return .analyze(weights: model.hasResult ? top : [])
    }

    var body: some View {
        HStack(spacing: 0) {
            sidePanel
                .frame(width: 280)
            mainPanel
        }
        .onAppear {
            // 首次进入自动分析主目录；已有结果时不重复扫描。
            guard !model.hasResult, model.phase == .idle, model.errorMessage == nil else { return }
            Task { await model.analyzeCurrent() }
        }
    }

    // MARK: 左侧

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                NoteStaffView(phrase: staffPhrase, visibleCount: staffCount)
                    .frame(width: 250, height: 96)
                    .modifier(StaffProgress(busy: model.isAnalyzing, done: model.hasResult,
                                            total: staffPhrase.elements.count, count: $staffCount,
                                            interval: 0.3))
                    .padding(.top, 6)
                Typo.headline(model.hasResult
                     ? "\(model.entries.count) 项，\(ByteFormat.string(model.totalSize))"
                     : (model.isAnalyzing ? "正在统计…" : "尚未分析"), size: 15)
                    .foregroundStyle(Color.white.opacity(0.88))
                HStack(spacing: 6) {
                    Button {
                        model.chooseDirectory()
                    } label: {
                        Label("选择目录", systemImage: "folder")
                    }
                    Button {
                        Task { await model.analyzeCurrent() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isAnalyzing)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)

            Text("当前目录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 22)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.sortedEntries) { entry in
                        sideRow(entry)
                    }
                    if !model.sortedLargeFiles.isEmpty {
                        Text("大文件")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(model.sortedLargeFiles) { file in
                            largeFileRow(file)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            Text("只读 · 右键可在 Finder 中显示")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
    }

    private func sideRow(_ entry: AnalyzeEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder" : "doc")
                .font(.system(size: 13))
                .foregroundStyle(palette.accent.opacity(0.85))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entryName(entry))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                MetaText(ByteFormat.string(entry.size), opacity: 0.55)
            }
            Spacer()
            if entry.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDir { Task { await model.drillDown(into: entry) } }
        }
        .contextMenu {
            Button("在 Finder 中显示") { model.revealInFinder(entry.path) }
            if entry.isDir {
                Button("分析此目录") { Task { await model.drillDown(into: entry) } }
            }
        }
    }

    private func largeFileRow(_ file: AnalyzeFileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 18)
            Text(file.name.isEmpty ? (file.path as NSString).lastPathComponent : file.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            MetaText(ByteFormat.string(file.size), opacity: 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("在 Finder 中显示") { model.revealInFinder(file.path) }
        }
    }

    // MARK: 右侧

    private var mainPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if model.canGoUp {
                    Button {
                        Task { await model.goUp() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("回到上一个分析过的目录")
                }
                breadcrumb
                Spacer()
                if let status = model.scanStatusText {
                    MetaText(status, opacity: 0.55)
                }
                if let files = model.totalFiles {
                    MetaText("文件 \(files)", opacity: 0.55)
                }
                MetaText("合计 \(ByteFormat.string(model.totalSize))", opacity: 0.55)
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                if model.hasResult && !model.sortedEntries.isEmpty {
                    TreemapView(entries: model.sortedEntries,
                                total: max(model.totalSize, 1),
                                onOpen: { entry in Task { await model.drillDown(into: entry) } },
                                onReveal: { entry in model.revealInFinder(entry.path) })
                } else {
                    VStack(spacing: 10) {
                        if model.isAnalyzing {
                            ProgressView()
                            MetaText("正在统计目录大小，文件多时会慢一些…", opacity: 0.6)
                        } else {
                            Image(systemName: "square.grid.3x3.square")
                                .font(.system(size: 34))
                                .foregroundStyle(Color.white.opacity(0.3))
                            MetaText(model.hasResult ? "这个目录下没有可展示的条目" : "选择一个目录开始分析", opacity: 0.6)
                            Button("分析主目录") { Task { await model.analyzeCurrent() } }
                                .buttonStyle(CapsuleButtonStyle(minWidth: 160))
                                .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card()
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    private var breadcrumb: some View {
        let parts = model.displayPath.split(separator: "/").map(String.init)
        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                Text(part == "~" ? "主目录" : part)
                    .font(.system(size: 13, weight: index == parts.count - 1 ? .semibold : .regular))
                    .foregroundStyle(Color.white.opacity(index == parts.count - 1 ? 0.95 : 0.55))
                    .lineLimit(1)
            }
        }
        .help(model.currentPath)
    }

    private func entryName(_ entry: AnalyzeEntry) -> String {
        entry.name.isEmpty ? (entry.path as NSString).lastPathComponent : entry.name
    }
}

// MARK: - 矩形树图

struct TreemapView: View {
    let entries: [AnalyzeEntry]
    let total: Int64
    let onOpen: (AnalyzeEntry) -> Void
    let onReveal: (AnalyzeEntry) -> Void

    /// 最多画这么多块，剩下的合并成“其余 N 项”。
    private let maxTiles = 11

    /// 跟分析页极光一致的青绿色系，深浅错开，半透明叠在背景上。
    private static let tileColors: [Color] = [
        Color(red: 0.16, green: 0.46, blue: 0.50),
        Color(red: 0.20, green: 0.52, blue: 0.42),
        Color(red: 0.18, green: 0.38, blue: 0.52),
        Color(red: 0.26, green: 0.50, blue: 0.48),
        Color(red: 0.14, green: 0.40, blue: 0.40),
        Color(red: 0.24, green: 0.44, blue: 0.56),
        Color(red: 0.18, green: 0.46, blue: 0.36),
        Color(red: 0.22, green: 0.36, blue: 0.46),
        Color(red: 0.15, green: 0.34, blue: 0.38),
        Color(red: 0.26, green: 0.42, blue: 0.40),
        Color(red: 0.14, green: 0.30, blue: 0.36),
        Color(red: 0.12, green: 0.26, blue: 0.30)
    ]

    private struct Tile: Identifiable {
        let id: String
        let title: String
        let size: Int64
        let entry: AnalyzeEntry?
        let isRest: Bool
    }

    private var tiles: [Tile] {
        let positive = entries.filter { $0.size > 0 }
        var result = positive.prefix(maxTiles).map { entry in
            Tile(id: entry.path,
                 title: entry.name.isEmpty ? (entry.path as NSString).lastPathComponent : entry.name,
                 size: entry.size, entry: entry, isRest: false)
        }
        let rest = positive.dropFirst(maxTiles)
        if !rest.isEmpty {
            let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
            result.append(Tile(id: "__rest__", title: "其余 \(rest.count) 项",
                               size: restSize, entry: nil, isRest: true))
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let items = tiles
            let rects = Treemap.layout(values: items.map { Double($0.size) },
                                       in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, tile in
                    if index < rects.count {
                        let rect = rects[index].insetBy(dx: 3, dy: 3)
                        tileView(tile, color: Self.tileColors[index % Self.tileColors.count], rect: rect)
                            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
    }

    private func tileView(_ tile: Tile, color: Color, rect: CGRect) -> some View {
        let showText = rect.width > 70 && rect.height > 44
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear],
                                     startPoint: .top, endPoint: .bottom))
            if showText {
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: tile.isRest ? "square.grid.2x2" : ((tile.entry?.isDir ?? false) ? "folder" : "doc"))
                            .font(.system(size: 12))
                        Text(tile.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(ByteFormat.string(tile.size))
                        .font(.system(size: 11, design: .monospaced))
                        .opacity(0.8)
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("\(tile.title) · \(ByteFormat.string(tile.size))")
        .onTapGesture {
            if let entry = tile.entry, entry.isDir { onOpen(entry) }
        }
        .contextMenu {
            if let entry = tile.entry {
                Button("在 Finder 中显示") { onReveal(entry) }
                if entry.isDir {
                    Button("分析此目录") { onOpen(entry) }
                }
            }
        }
    }
}

// MARK: - squarified 布局

enum Treemap {
    /// 按 squarified 算法把 values（降序）铺进 rect，返回同顺序的矩形。
    static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return values.map { _ in .zero }
        }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row: [Int] = [index]
            var rowSum = areas[index]
            var best = worst(rowSum: rowSum, rowMin: areas[index], rowMax: areas[index], side: side)
            var next = index + 1
            while next < areas.count {
                let newSum = rowSum + areas[next]
                let newMin = min(areas[row.last!], areas[next])
                let newMax = areas[row.first!]
                let candidate = worst(rowSum: newSum, rowMin: newMin, rowMax: newMax, side: side)
                if candidate > best { break }
                row.append(next)
                rowSum = newSum
                best = candidate
                next += 1
            }

            let horizontal = remaining.width >= remaining.height
            let thickness = CGFloat(rowSum / side)
            var offset: CGFloat = 0
            for i in row {
                let length = CGFloat(areas[i] / Double(thickness))
                if horizontal {
                    result[i] = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                       width: thickness, height: length)
                } else {
                    result[i] = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                       width: length, height: thickness)
                }
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(remaining.width - thickness, 0), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(remaining.height - thickness, 0))
            }
            index = next
        }
        return result
    }

    private static func worst(rowSum: Double, rowMin: Double, rowMax: Double, side: Double) -> Double {
        guard rowSum > 0, rowMin > 0, side > 0 else { return .infinity }
        let s2 = side * side
        let r2 = rowSum * rowSum
        return max(s2 * rowMax / r2, r2 / (s2 * rowMin))
    }
}
