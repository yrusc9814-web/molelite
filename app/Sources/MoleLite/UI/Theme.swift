import AppKit
import SwiftUI

// MARK: - 页面配色

/// 每个页面一套深色底：上浅下深的渐变 + 一颗同色系的“星球”。
struct PagePalette {
    let top: Color
    let bottom: Color
    /// 星球三段色：亮面、主色、暗面
    let orb: [Color]
    /// 星球表面的条纹色（可为空）
    let bands: [Color]
    let accent: Color
    /// 星球照片文件名（Assets/planets/<name>.png），找不到时退回代码绘制
    var planet: String = ""

    static let clean = PagePalette(
        top: Color(red: 0.16, green: 0.20, blue: 0.33),
        bottom: Color(red: 0.11, green: 0.13, blue: 0.21),
        orb: [Color(red: 0.62, green: 0.86, blue: 0.98),
              Color(red: 0.20, green: 0.46, blue: 0.86),
              Color(red: 0.06, green: 0.14, blue: 0.36)],
        bands: [Color(red: 0.35, green: 0.70, blue: 0.55).opacity(0.55),
                Color.white.opacity(0.35)],
        accent: Color(red: 0.48, green: 0.72, blue: 1.0),
        planet: "earth")

    static let uninstall = PagePalette(
        top: Color(red: 0.24, green: 0.13, blue: 0.14),
        bottom: Color(red: 0.15, green: 0.08, blue: 0.09),
        orb: [Color(red: 1.0, green: 0.74, blue: 0.58),
              Color(red: 0.80, green: 0.33, blue: 0.22),
              Color(red: 0.30, green: 0.08, blue: 0.06)],
        bands: [Color(red: 0.55, green: 0.18, blue: 0.10).opacity(0.5)],
        accent: Color(red: 0.96, green: 0.56, blue: 0.48),
        planet: "mars")

    static let analyze = PagePalette(
        top: Color(red: 0.27, green: 0.18, blue: 0.11),
        bottom: Color(red: 0.17, green: 0.11, blue: 0.07),
        orb: [Color(red: 1.0, green: 0.90, blue: 0.76),
              Color(red: 0.82, green: 0.62, blue: 0.42),
              Color(red: 0.36, green: 0.22, blue: 0.12)],
        bands: [Color(red: 0.62, green: 0.38, blue: 0.22).opacity(0.65),
                Color(red: 0.95, green: 0.86, blue: 0.72).opacity(0.55)],
        accent: Color(red: 0.96, green: 0.76, blue: 0.50),
        planet: "jupiter")

    static let about = PagePalette(
        top: Color(red: 0.19, green: 0.17, blue: 0.29),
        bottom: Color(red: 0.11, green: 0.10, blue: 0.18),
        orb: [Color(red: 0.86, green: 0.80, blue: 1.0),
              Color(red: 0.52, green: 0.42, blue: 0.86),
              Color(red: 0.16, green: 0.10, blue: 0.36)],
        bands: [Color.white.opacity(0.25)],
        accent: Color(red: 0.74, green: 0.66, blue: 1.0),
        planet: "moon")
}

struct PageBackground: View {
    let palette: PagePalette

    var body: some View {
        LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

// MARK: - 按钮

/// 白色胶囊主按钮。
struct CapsuleButtonStyle: ButtonStyle {
    var minWidth: CGFloat = 220
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.88 : 0.35))
            .padding(.horizontal, 28)
            .frame(minWidth: minWidth, minHeight: 44)
            .background(
                Capsule().fill(Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.80 : 0.97) : 0.35))
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 半透明小按钮（工具栏用）。
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.85 : 0.35))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

/// 文字链接样式（“重新扫描”之类）。
struct LinkButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
    }
}

// MARK: - 勾选框

struct CheckBox: View {
    let isOn: Bool
    var mixed: Bool = false
    var tint: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn || mixed ? tint : Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn || mixed ? Color.clear : Color.white.opacity(0.35), lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                } else if mixed {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

// MARK: - 顶部导航

struct TopNavBar: View {
    @Binding var selection: SidebarSection
    let accent: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .padding(.horizontal, 6)
            ForEach(SidebarSection.allCases) { section in
                let active = section == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selection = section
                    }
                } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: active ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(active ? Color.black.opacity(0.85) : Color.white.opacity(0.62))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background {
                            if active {
                                Capsule().fill(Color.white)
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

// MARK: - 小部件

/// 等宽的元信息文字（大小、路径、数量）。
struct MetaText: View {
    let text: String
    var opacity: Double = 0.5

    init(_ text: String, opacity: Double = 0.5) {
        self.text = text
        self.opacity = opacity
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.white.opacity(opacity))
    }
}

/// 卡片底：极淡的白色叠层 + 细描边。
struct CardBackground: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? 0.09 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(highlighted ? 0.12 : 0.06))
            )
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View {
        modifier(CardBackground(highlighted: highlighted))
    }
}

/// 应用图标缓存（NSWorkspace 取真实图标）。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        cache[path] = image
        return image
    }
}

/// 底部操作栏的毛玻璃底。
struct BottomBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) { content }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.22))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }
    }
}
