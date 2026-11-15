import SwiftUI

// MARK: - 应用列表单行

struct InstalledAppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 预览单行

/// 不能声明为 private——UninstallView.swift 也会引用。
struct UninstallItemRow: View {
    let item: UninstallPreviewItem
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.needsAdmin ? Color.secondary : Color.primary)
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
                }
            }

            Spacer(minLength: 8)

            Text(ByteFormat.string(item.sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .opacity(item.needsAdmin ? 0.65 : 1)
    }
}
