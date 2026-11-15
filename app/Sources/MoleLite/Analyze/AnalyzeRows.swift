import Foundation
import SwiftUI

// MARK: - 条目行

struct AnalyzeEntryRow: View {
    let entry: AnalyzeEntry
    let maxSize: Int64
    let onReveal: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name.isEmpty ? (entry.path as NSString).lastPathComponent : entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.cleanable {
                        Text("可清理")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if !entry.isDir {
                        Text("文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                SizeRatioBar(fraction: fraction, tint: entry.isDir ? Color.accentColor : Color.secondary)

                Text(entry.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.string(entry.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if entry.isDir {
                    Button(action: onOpen) {
                        Label("打开", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("分析这个目录")
                }
            }

            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDir { onOpen() }
        }
        .contextMenu {
            Button("在 Finder 中显示", action: onReveal)
            if entry.isDir {
                Button("分析此目录", action: onOpen)
            }
        }
    }

    private var fraction: Double {
        guard entry.size > 0 else { return 0 }
        return min(1, Double(entry.size) / Double(maxSize))
    }
}

// MARK: - 大文件行

struct AnalyzeLargeFileRow: View {
    let file: AnalyzeFileEntry
    let maxSize: Int64
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name.isEmpty ? (file.path as NSString).lastPathComponent : file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SizeRatioBar(fraction: fraction, tint: .secondary)
                Text(file.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text(ByteFormat.string(file.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("在 Finder 中显示", action: onReveal)
        }
    }

    private var fraction: Double {
        guard file.size > 0 else { return 0 }
        return min(1, Double(file.size) / Double(maxSize))
    }
}

// MARK: - 占比条

/// 按当前列表最大条目归一化的横条；0 字节不画。
struct SizeRatioBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.65))
                    .frame(width: max(0, proxy.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
