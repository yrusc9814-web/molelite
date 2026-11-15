import SwiftUI

// MARK: - 风险徽标

struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.displayName)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - 结果页

struct CleanResultView: View {
    let summary: ResultSummary
    let note: String?
    let logLines: [String]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: summary.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(summary.failed.isEmpty ? Color.green : Color.orange)
                        Text(summary.headline)
                            .font(.headline)
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

                    resultGroup("已删除", records: summary.removed, color: .green)
                    resultGroup("已跳过", records: summary.skipped, color: .secondary)
                    resultGroup("失败", records: summary.failed, color: .red)

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

    @ViewBuilder
    private func resultGroup(_ title: String, records: [CleanExecutionRecord], color: Color) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) · \(records.count) 项 · \(ByteFormat.string(records.reduce(0) { $0 + $1.sizeBytes }))")
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
