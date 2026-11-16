import AppKit
import CoreText
import SwiftUI

// MARK: - 页面背景

/// 每页一种“天色”：清理=极光丝带，卸载=暮色晚霞，磁盘分析=紫色星空+幻彩涟漪，关于=金色月晕薄雾。
enum PageScene: Equatable { case aurora, dusk, ripple, moon }

struct PagePalette: Equatable {
    let scene: PageScene
    let accent: Color

    static func == (l: PagePalette, r: PagePalette) -> Bool { l.scene == r.scene }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static let clean = PagePalette(scene: .aurora, accent: rgb(150, 170, 255))
    static let uninstall = PagePalette(scene: .dusk, accent: rgb(250, 180, 150))
    static let analyze = PagePalette(scene: .ripple, accent: rgb(205, 175, 250))
    static let about = PagePalette(scene: .moon, accent: rgb(240, 210, 150))
}

/// 动态背景。约 20 帧/秒；窗口不在前台或系统开启“减弱动态效果”时停住，省电。
struct PageBackground: View {
    let palette: PagePalette
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let start = Date()
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { PagePalette.rgb(r, g, b) }

    /// 固定种子的微尘：x, y(0...1), 半径, 相位
    private static let dust: [(Double, Double, Double, Double)] = {
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<150).map { _ in (rnd(), rnd(), [0.8, 1.0, 1.0, 1.3][Int(rnd() * 4) % 4], rnd() * 6.28) }
    }()

    var body: some View {
        let paused = reduceMotion || activeState == .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSince(Self.start)
            Canvas { gc, size in
                switch palette.scene {
                case .aurora: drawAurora(gc, size, t)
                case .dusk: drawDusk(gc, size, t)
                case .ripple: drawRipple(gc, size, t)
                case .moon: drawMoon(gc, size, t)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: 公共

    private func vertical(_ gc: GraphicsContext, _ size: CGSize, _ stops: [Gradient.Stop]) {
        gc.fill(Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(Gradient(stops: stops), startPoint: .zero,
                                      endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// 椭圆柔光：中心 c，半径 rx/ry，颜色 col，强度 a
    private func glow(_ gc: GraphicsContext, center c: CGPoint, rx: Double, ry: Double, color col: Color, _ a: Double) {
        var g = gc
        g.translateBy(x: c.x, y: c.y)
        g.scaleBy(x: 1, y: ry / rx)
        let r = rx * 2.2
        g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
               with: .radialGradient(Gradient(stops: [
                   .init(color: col.opacity(a), location: 0),
                   .init(color: col.opacity(a * 0.55), location: 0.25),
                   .init(color: col.opacity(a * 0.15), location: 0.55),
                   .init(color: col.opacity(0), location: 1)
               ]), center: .zero, startRadius: 0, endRadius: r))
    }

    /// 微尘：在 [0, ymax*h] 内慢慢上飘、闪烁；sparkles 个十字亮星
    private func drawDust(_ gc: GraphicsContext, _ size: CGSize, _ t: Double, count: Int, ymax: Double,
                          color: Color = .white, strength: Double = 1, sparkles: Int = 0) {
        let w = size.width, h = size.height, band = h * ymax
        for (i, d) in Self.dust.prefix(count).enumerated() {
            var y = (d.1 * band - t * 3 * (0.3 + 0.7 * d.0)).truncatingRemainder(dividingBy: band)
            if y < 0 { y += band }
            let x = d.0 * w
            let a = (0.16 + 0.34 * Double((i * 37) % 10) / 10) * (0.6 + 0.4 * sin(t * 1.5 + d.3)) * strength
            gc.fill(Path(ellipseIn: CGRect(x: x - d.2, y: y - d.2, width: d.2 * 2, height: d.2 * 2)),
                    with: .color(color.opacity(a)))
        }
        for i in 0..<sparkles {
            let d = Self.dust[Self.dust.count - 1 - i]
            let x = d.0 * w, y = 20 + d.1 * h * 0.42
            let tw = 0.55 + 0.45 * sin(t * 1.1 + d.3 * 3)
            let len = (4 + 3 * d.2) * (0.8 + 0.4 * tw)
            var p = Path()
            p.move(to: CGPoint(x: x - len, y: y)); p.addLine(to: CGPoint(x: x + len, y: y))
            p.move(to: CGPoint(x: x, y: y - len)); p.addLine(to: CGPoint(x: x, y: y + len))
            gc.stroke(p, with: .color(.white.opacity(0.6 * tw)), lineWidth: 1)
            gc.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
                    with: .color(.white.opacity(0.85 * tw)))
        }
    }

    /// 横向波浪带：中心线 cy 起伏，厚度 th，向上拉丝 up 倍
    private func band(cy: Double, amp: Double, th: Double, up: Double, w: Double, h: Double, ph: Double, t: Double, speed: Double) -> Path {
        let step = max(8.0, w / 90)
        var top: [CGPoint] = [], bot: [CGPoint] = []
        var x = -40.0
        while x <= w + 40 {
            let c = cy + amp * sin(x / 260 + ph + t * speed) + h * 0.014 * sin(x / 97 + ph * 2 + t * speed * 1.6)
            let breathe = 0.75 + 0.25 * sin(x / 180 + ph + t * speed * 1.2)
            top.append(CGPoint(x: x, y: c - th * up * breathe))
            bot.append(CGPoint(x: x, y: c + th * 0.7))
            x += step
        }
        var path = Path()
        path.addLines(top)
        path.addLines(bot.reversed())
        path.closeSubpath()
        return path
    }

    private func hFade(_ c0: Color, _ c1: Color, _ a0: Double, _ a1: Double, w: Double) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [
            .init(color: c0.opacity(0), location: 0),
            .init(color: c0.opacity(a0), location: 0.22),
            .init(color: c1.opacity(a1), location: 0.72),
            .init(color: c1.opacity(0), location: 1)
        ]), startPoint: .zero, endPoint: CGPoint(x: w, y: 0))
    }

    // MARK: 清理 · 极光丝带

    private func drawAurora(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        vertical(gc, size, [.init(color: Self.rgb(26, 30, 60), location: 0), .init(color: Self.rgb(12, 13, 28), location: 1)])
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: max(18, h * 0.045)))
            layer.fill(band(cy: h * 0.27, amp: h * 0.05, th: h * 0.085, up: 1.6, w: w, h: h, ph: 0, t: t, speed: 0.25),
                       with: hFade(Self.rgb(110, 140, 240), Self.rgb(200, 150, 220), 0.85, 0.7, w: w))
            layer.fill(band(cy: h * 0.41, amp: h * 0.04, th: h * 0.065, up: 1.6, w: w, h: h, ph: 1.7, t: t, speed: 0.25),
                       with: hFade(Self.rgb(140, 120, 230), Self.rgb(230, 170, 200), 0.77, 0.63, w: w))
        }
        drawDust(gc, size, t, count: 55, ymax: 0.7)
    }

    // MARK: 卸载 · 暮色晚霞

    private func drawDusk(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        vertical(gc, size, [.init(color: Self.rgb(30, 20, 52), location: 0), .init(color: Self.rgb(70, 34, 62), location: 1)])
        // 地平线下的蜜桃色余晖，轻轻呼吸
        let br = 0.8 + 0.06 * sin(t * 0.35)
        glow(gc, center: CGPoint(x: w * 0.58, y: h * 1.02), rx: w * 0.42, ry: h * 0.30, color: Self.rgb(250, 170, 140), br)
        // 横云带：上缘被余晖染亮，缓慢平移
        let clouds: [(Double, Double, Double, Color, Double, Double)] = [
            (0.47, 14, 16, Self.rgb(190, 150, 220), 0.30, 3.1),
            (0.58, 20, 22, Self.rgb(230, 160, 190), 0.42, 1.9),
            (0.70, 26, 18, Self.rgb(255, 190, 160), 0.55, 0.3),
            (0.80, 34, 14, Self.rgb(255, 200, 170), 0.50, 4.4)
        ]
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: max(10, h * 0.02)))
            for (cy, th, amp, col, s, k) in clouds {
                layer.fill(band(cy: h * cy, amp: amp, th: th, up: 1.0, w: w, h: h, ph: k, t: t, speed: 0.12),
                           with: hFade(col, col, s, s * 0.8, w: w))
            }
        }
        drawDust(gc, size, t, count: 40, ymax: 0.45)
    }

    // MARK: 磁盘分析 · 紫色星空 + 幻彩涟漪

    private func drawRipple(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        // 上深下浅：深靛夜空 → 浅紫
        vertical(gc, size, [
            .init(color: Self.rgb(20, 16, 44), location: 0),
            .init(color: Self.rgb(32, 23, 62), location: 0.35),
            .init(color: Self.rgb(80, 58, 128), location: 0.65),
            .init(color: Self.rgb(168, 130, 212), location: 1)
        ])
        // 左下发出的同心声波，颜色在粉 / 紫 / 冰蓝之间流转，慢慢向外扩
        let center = CGPoint(x: w * 0.12, y: h * 1.05)
        let spacing = max(150, w * 0.23)
        let drift = (t * 9).truncatingRemainder(dividingBy: spacing)
        let hues = [Self.rgb(255, 190, 235), Self.rgb(200, 170, 255), Self.rgb(170, 215, 255)]
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            var r = drift + 60
            var i = 0
            while r < w * 1.6 {
                let fade = exp(-r / (w * 0.5)) * 0.55
                let col = hues[(i + Int(t / 6)) % hues.count]
                let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                layer.stroke(ring, with: .color(col.opacity(fade)), lineWidth: 10)
                r += spacing; i += 1
            }
        }
        // 底部粉紫余光
        glow(gc, center: CGPoint(x: w * 0.4, y: h * 1.05), rx: w * 0.6, ry: h * 0.2, color: Self.rgb(235, 200, 245), 0.35)
        drawDust(gc, size, t, count: 150, ymax: 0.62, strength: 1.3, sparkles: 7)
    }

    // MARK: 关于 · 金色月晕薄雾

    private func drawMoon(_ gc: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        vertical(gc, size, [.init(color: Self.rgb(34, 30, 64), location: 0), .init(color: Self.rgb(16, 14, 34), location: 1)])
        let moon = CGPoint(x: w * 0.80, y: h * 0.16)
        let br = 0.92 + 0.08 * sin(t * 0.5)
        glow(gc, center: moon, rx: 120, ry: 120, color: Self.rgb(250, 225, 180), 0.55 * br)
        glow(gc, center: moon, rx: 34, ry: 34, color: Self.rgb(255, 245, 220), 0.75 * br)
        // 底部两层流雾，往左慢慢流
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: max(14, h * 0.03)))
            for (base, amp, s, col, k) in [(0.78, 24.0, 0.32, Self.rgb(200, 180, 235), 0.0),
                                           (0.86, 18.0, 0.42, Self.rgb(235, 210, 200), 2.3)] {
                var p = Path()
                p.move(to: CGPoint(x: -40, y: h + 40))
                var x = -40.0
                while x <= w + 40 {
                    let y = h * base + amp * sin(x / 150 + k + t * 0.15) + 10 * sin(x / 57 + t * 0.25)
                    p.addLine(to: CGPoint(x: x, y: y))
                    x += max(8, w / 90)
                }
                p.addLine(to: CGPoint(x: w + 40, y: h + 40))
                p.closeSubpath()
                layer.fill(p, with: .linearGradient(Gradient(colors: [col.opacity(s * 0.5), col.opacity(s)]),
                                                    startPoint: CGPoint(x: 0, y: h * base), endPoint: CGPoint(x: 0, y: h)))
            }
        }
        drawDust(gc, size, t, count: 45, ymax: 0.6, color: Self.rgb(255, 240, 210))
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
