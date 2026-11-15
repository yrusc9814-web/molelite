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
    var tint: Color = .accentColor
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(isOn: isSelected, tint: tint, disabled: disabled || item.needsAdmin) {
                onToggle(!isSelected)
            }
            .help(item.needsAdmin ? "需要管理员权限，本版本不执行" : "")

            Text(item.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text((item.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if item.needsAdmin {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.orange)
            }
            RiskBadge(level: item.riskLevel)
            Text(ByteFormat.string(item.sizeBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .opacity(item.needsAdmin ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if !(disabled || item.needsAdmin) { onToggle(!isSelected) }
        }
    }
}
