import SwiftUI

// MARK: - 卸载结果页

struct UninstallResultView: View {
    let appName: String?
    let summary: UninstallResultSummary
    let note: String?
    let logLines: [String]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline

                    // removed 表示引擎绕过了废纸篓，必须显眼。
                    if summary.hasPermanentRemoval {
                        permanentRemovalBanner
                    }

                    if let note, !note.isEmpty {
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    if summary.isEmpty {
                        Text("引擎没有返回任何处理记录。")
                            .foregroundStyle(.secondary)
                    }

                    group("已移到废纸篓", records: summary.trashed, color: .teal)
                    group("已永久删除", records: summary.removed, color: .red)
                    group("已跳过", records: summary.skipped, color: .secondary)
                    group("失败", records: summary.failed, color: .red)

                    if !logLines.isEmpty {
                        DisclosureGroup("引擎日志（\(logLines.count) 行）") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(logLines.indices, id: \.self) { index in
                                    Text(logLines[index])
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.title)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                if let appName, !appName.isEmpty {
                    Text("卸载 \(appName)")
                        .font(.headline)
                }
                Text(summary.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        if !summary.failed.isEmpty { return "exclamationmark.triangle.fill" }
        if summary.hasPermanentRemoval { return "exclamationmark.octagon.fill" }
        return "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if !summary.failed.isEmpty { return .orange }
        if summary.hasPermanentRemoval { return .red }
        return .green
    }

    private var permanentRemovalBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("已永久删除 \(summary.removed.count) 项", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.white)
            Text("这些项目被永久删除，没有进废纸篓，无法恢复。共 \(ByteFormat.string(summary.bytes(of: summary.removed)))。")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("警告：已永久删除 \(summary.removed.count) 项，无法恢复。")
    }

    @ViewBuilder
    private func group(_ title: String, records: [UninstallExecutionRecord], color: Color) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) · \(records.count) 项 · \(ByteFormat.string(summary.bytes(of: records)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Text(record.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        if let reason = record.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(ByteFormat.string(record.sizeBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
