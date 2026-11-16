import AppKit
import CoreText
import SwiftUI

// MARK: - 页面配色

/// 每个页面一套深色底 + 两条极光丝带（同一种形式，配色各不相同，切页不视觉疲劳）。
struct PagePalette: Equatable {
    let top: Color
    let bottom: Color
    /// 第一条丝带：左端色 → 右端色
    let ribbonA: (Color, Color)
    /// 第二条丝带
    let ribbonB: (Color, Color)
    let accent: Color

    static func == (l: PagePalette, r: PagePalette) -> Bool { l.top == r.top && l.bottom == r.bottom }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// 清理：深海军蓝底，蓝紫 → 淡粉
    static let clean = PagePalette(
        top: rgb(26, 30, 60), bottom: rgb(12, 13, 28),
        ribbonA: (rgb(110, 140, 240), rgb(200, 150, 220)),
        ribbonB: (rgb(140, 120, 230), rgb(230, 170, 200)),
        accent: rgb(150, 170, 255))

    /// 卸载：深梅紫底，紫 → 蜜桃（不用红）
    static let uninstall = PagePalette(
        top: rgb(34, 24, 56), bottom: rgb(14, 10, 26),
        ribbonA: (rgb(170, 110, 220), rgb(250, 170, 140)),
        ribbonB: (rgb(200, 130, 210), rgb(255, 200, 160)),
        accent: rgb(250, 180, 150))

    /// 磁盘分析：深青底，青 → 翠绿
    static let analyze = PagePalette(
        top: rgb(12, 40, 48), bottom: rgb(6, 16, 22),
        ribbonA: (rgb(60, 190, 200), rgb(90, 220, 150)),
        ribbonB: (rgb(70, 160, 210), rgb(140, 230, 180)),
        accent: rgb(110, 225, 190))

    /// 关于：深靛底，淡金 → 淡紫
    static let about = PagePalette(
        top: rgb(22, 22, 52), bottom: rgb(10, 10, 26),
        ribbonA: (rgb(240, 210, 140), rgb(190, 160, 240)),
        ribbonB: (rgb(220, 190, 150), rgb(170, 150, 235)),
        accent: rgb(240, 210, 150))
}

/// 极光背景：渐变底 + 两条缓慢飘动的柔光丝带 + 少量闪烁微尘。
/// 约 20 帧/秒；窗口不在前台或系统开启“减弱动态效果”时停住，省电。
struct PageBackground: View {
    let palette: PagePalette
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let start = Date()
    private static let dust: [(Double, Double, Double, Double)] = {
        // 固定种子：x, y(0...1), 半径, 相位
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<55).map { _ in (rnd(), rnd() * 0.7, [0.8, 1.0, 1.0, 1.3][Int(rnd() * 4) % 4], rnd() * 6.28) }
    }()

    var body: some View {
        let paused = reduceMotion || activeState == .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSince(Self.start)
            Canvas { gc, size in
                draw(gc, size: size, t: t)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let full = Path(CGRect(origin: .zero, size: size))
        gc.fill(full, with: .linearGradient(Gradient(colors: [palette.top, palette.bottom]),
                                            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // 丝带：中心线随 x 起伏并随时间缓慢漂移；上沿拉高，像极光往上散开
        let ribbons: [(cy: Double, amp: Double, th: Double, cols: (Color, Color), ph: Double, k: Double)] = [
            (0.23, 0.05, 0.075, palette.ribbonA, 0.0, 0.85),
            (0.36, 0.04, 0.055, palette.ribbonB, 1.7, 0.75)
        ]
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: max(18, h * 0.045)))
            for r in ribbons {
                let step = max(8.0, w / 90)
                var top: [CGPoint] = [], bot: [CGPoint] = []
                var x = -40.0
                while x <= w + 40 {
                    let c = h * r.cy + h * r.amp * sin(x / 260 + r.ph + t * 0.25)
                        + h * 0.014 * sin(x / 97 + r.ph * 2 + t * 0.4)
                    let breathe = 0.75 + 0.25 * sin(x / 180 + r.ph + t * 0.3)
                    top.append(CGPoint(x: x, y: c - h * r.th * 1.6 * breathe))
                    bot.append(CGPoint(x: x, y: c + h * r.th * 0.7))
                    x += step
                }
                var path = Path()
                path.addLines(top)
                path.addLines(bot.reversed())
                path.closeSubpath()
                let (c0, c1) = r.cols
                layer.fill(path, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: c0.opacity(0), location: 0),
                        .init(color: c0.opacity(0.55 * r.k), location: 0.22),
                        .init(color: c1.opacity(0.45 * r.k), location: 0.7),
                        .init(color: c1.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0)))
            }
        }
        // 微尘：慢慢上飘、轻微闪烁
        for (i, d) in Self.dust.enumerated() {
            var y = (d.1 * h * 0.7 - t * 3 * (0.3 + 0.7 * d.0)).truncatingRemainder(dividingBy: h * 0.7)
            if y < 0 { y += h * 0.7 }
            let x = d.0 * w
            let a = (0.16 + 0.3 * Double((i * 37) % 10) / 10) * (0.6 + 0.4 * sin(t * 1.5 + d.3))
            gc.fill(Path(ellipseIn: CGRect(x: x - d.2, y: y - d.2, width: d.2 * 2, height: d.2 * 2)),
                    with: .color(.white.opacity(a)))
        }
    }
}

// MARK: - 字体

/// 随包字体：思源宋体（标题）、EB Garamond（数字）、Bravura（音符）。均为 SIL OFL 1.1。
/// 按钮、正文小字仍用系统字体（Mac 苹方 / Windows 微软雅黑）。
enum AppFonts {
    private static var done = false
    static let displayName = "NotoSerifSC-SemiBold"
    static let serifName = "NotoSerifSC-Regular"
    static let numeralName = "EBGaramond-Medium"

    /// 注册 Contents/Resources/fonts 下所有字体（只做一次）。
    @discardableResult
    static func registerAll() -> Bool {
        if done { return true }
        done = true
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("fonts")) }
        if let dir = ProcessInfo.processInfo.environment["MOLELITE_ASSETS"] {
            dirs.append(URL(fileURLWithPath: dir).appendingPathComponent("fonts"))
        }
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(src.appendingPathComponent("Assets/fonts"))
        let fm = FileManager.default
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
            guard !fonts.isEmpty else { continue }
            for url in fonts {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
            return true
        }
        return false
    }
}

enum Typo {
    /// 标题：思源宋体 SemiBold
    static func display(_ size: CGFloat) -> Font {
        AppFonts.registerAll()
        return .custom(AppFonts.displayName, fixedSize: size)
    }

    /// 副标题：思源宋体 Regular
    static func serif(_ size: CGFloat) -> Font {
        AppFonts.registerAll()
        return .custom(AppFonts.serifName, fixedSize: size)
    }

    /// 数字：EB Garamond Medium
    static func numeral(_ size: CGFloat) -> Font {
        AppFonts.registerAll()
        return .custom(AppFonts.numeralName, fixedSize: size)
    }

    /// 标题里数字用 Garamond（放大一档），单位字母略小，中文用宋体。
    /// 例：“发现 649.1 MB” → 宋体“发现 ” + Garamond“649.1” + Garamond 小一号“ MB”
    static func headline(_ string: String, size: CGFloat) -> Text {
        enum Kind { case han, digit, latin }
        func kind(_ c: Character) -> Kind {
            if c.isNumber || c == "." || c == "," { return c.isASCII ? .digit : .han }
            if c.isASCII && (c.isLetter || c == "%") { return .latin }
            if c == " ", c.isASCII { return .latin }
            return .han
        }
        var result = Text("")
        var run = ""
        var current: Kind? = nil
        func flush() {
            guard let k = current, !run.isEmpty else { return }
            switch k {
            case .han: result = result + Text(run).font(display(size))
            case .digit: result = result + Text(run).font(numeral(size * 1.32))
            case .latin: result = result + Text(run).font(numeral(size * 0.9))
            }
            run = ""
        }
        for c in string {
            var k = kind(c)
            // 空格跟随前一段，避免宋体里出现宽空格
            if c == " ", let cur = current { k = cur }
            if k != current { flush(); current = k }
            run.append(c)
        }
        flush()
        return result
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
