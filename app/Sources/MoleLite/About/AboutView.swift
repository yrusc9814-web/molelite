import SwiftUI

// MARK: - 关于页

/// 自用说明页。文案全部为本应用自写，不引用原版 Mole 的界面文字或图标。
struct AboutView: View {
    let catalog: RulesCatalog

    @State private var engineDirectory: String? = nil
    @State private var engineProblem: String? = nil

    init(catalog: RulesCatalog) {
        self.catalog = catalog
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                purposeBlock
                engineBlock
                rulesBlock
                licenseBlock
                safetyBlock
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("关于")
        .task { loadEngineDirectory() }
    }

    // MARK: 各段

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MoleLite")
                .font(.largeTitle.weight(.semibold))
            Text("个人自用的 macOS 清理与磁盘查看工具")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("版本 \(Self.version) · \(Bundle.main.bundleIdentifier ?? "未打包运行")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var purposeBlock: some View {
        section("用途") {
            Text("本应用为个人自用，不对外分发，也不提供任何账号、订阅或激活机制。界面只做三件事：查看可清理项、只读分析磁盘占用、预览并卸载应用。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineBlock: some View {
        section("清理与卸载引擎") {
            Text("清理和卸载的实际动作由 tw93/Mole 开源命令行工具完成。本应用只负责调用它、展示预览结果，并在执行前要求确认。")
                .fixedSize(horizontal: false, vertical: true)

            infoRow("上游项目", "tw93/Mole（开源 CLI）")
            infoRow("对应提交", "dc6605c")
            infoRow("许可证", "GPL-3.0")
            infoRow("引擎目录", engineDirectory ?? "未检测到",
                    selectable: engineDirectory != nil,
                    tint: engineDirectory == nil ? .orange : .secondary)

            if engineDirectory == nil, let problem = engineProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var rulesBlock: some View {
        section("规则") {
            infoRow("规则条数", "\(catalog.count) 条")
            infoRow("加载来源", Self.sourceName(catalog.source))
            if let error = catalog.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Text("规则文件用于修正引擎默认的勾选状态、管理员权限与风险等级；界面上的勾选初始值以它为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var licenseBlock: some View {
        section("许可与来源说明") {
            Text("本应用自身代码为本机自用而写。内置或随附的 Mole 引擎来自上述开源项目，按 GPL-3.0 许可使用；其版权归原作者及贡献者所有。")
                .fixedSize(horizontal: false, vertical: true)
            Text("本页与应用图标均为自写，不包含原版 Mole 的文案、图标或其他美术素材。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyBlock: some View {
        section("安全提醒") {
            Label("清理是永久删除，不进废纸篓；卸载默认移到废纸篓。两者都必须先预览、再确认。", systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("应用不会以 root 运行，也不会在未预览的情况下执行删除。首次使用若提示无权读取某些目录，请在“系统设置 → 隐私与安全性 → 完全磁盘访问”中手动授权。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 组件

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func infoRow(
        _ title: String,
        _ value: String,
        selectable: Bool = false,
        tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.callout)
            .foregroundStyle(tint)
            .lineLimit(2)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据

    private func loadEngineDirectory() {
        do {
            engineDirectory = try EngineRunner.shared.resolveEngineDirectory().path
            engineProblem = nil
        } catch {
            engineDirectory = nil
            engineProblem = error.localizedDescription
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static func sourceName(_ source: RulesCatalog.Source) -> String {
        switch source {
        case .environment(let path):
            return path == "MOLE_RULES_JSON" ? "环境变量（JSON 文本）" : "环境变量：\(path)"
        case .bundle:
            return "App Bundle 内置 rules.json"
        case .executableDirectory:
            return "可执行文件目录 rules.json"
        case .none:
            return "未加载"
        }
    }
}
