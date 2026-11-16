import AppKit
import CoreText
import SwiftUI

// MARK: - 五线谱音符装饰
//
// 平时（空闲）：整句音符保持暗色半透明，按节拍从左到右一个接一个轻轻跳起，循环不停，像音乐在放。
// 状态到了：音符从左到右逐个点亮并轻微上浮。卸载执行时反过来，从右往左淡出并下坠，落完再回到暗色律动。
// 字形用 Bravura（SMuFL 标准音乐字体，SIL OFL 1.1），符干、符杠、加线用 Path 画。
// 坐标系：参考画布 560 x 200，五线谱底线 y = 150，pitch 0 = 底线，每 +1 升半个间距（线/间交替）。

enum StaffGlyph {
    case treble, bass, flat, sharp, natural

    var codepoint: String {
        switch self {
        case .treble: return "\u{E050}"
        case .bass: return "\u{E062}"
        case .flat: return "\u{E260}"
        case .sharp: return "\u{E262}"
        case .natural: return "\u{E261}"
        }
    }
}

struct StaffElement {
    enum Kind {
        case glyph(StaffGlyph, pitch: Double)
        /// 一个或多个符头（和弦），stemUp=nil 表示无符干
        case note(pitches: [Int], stemUp: Bool?, open: Bool, stemLength: Double)
    }

    var x: Double
    var kind: Kind

    static func glyph(_ g: StaffGlyph, x: Double, pitch: Double) -> StaffElement {
        StaffElement(x: x, kind: .glyph(g, pitch: pitch))
    }

    static func note(_ x: Double, _ pitches: [Int], up: Bool? = true, open: Bool = false, stem: Double = 48) -> StaffElement {
        StaffElement(x: x, kind: .note(pitches: pitches, stemUp: up, open: open, stemLength: stem))
    }
}

struct StaffBeam {
    var from: Int
    var to: Int
    var count: Int = 1
}

struct StaffPhrase {
    var elements: [StaffElement]
    var beams: [StaffBeam] = []

    // 清理：高音谱号，三组上行连杠，夹一个降号和一个升号
    static let clean: StaffPhrase = {
        var e: [StaffElement] = [.glyph(.treble, x: 30, pitch: 2)]
        let xs: [Double] = [120, 155, 190, 225, 280, 315, 350, 385, 445, 485, 525]
        let ps = [1, 3, 5, 4, 5, 7, 9, 8, 10, 9, 11]
        for (i, (x, p)) in zip(xs, ps).enumerated() {
            if i == 4 { e.append(.glyph(.flat, x: 252, pitch: 7)) }
            if i == 8 { e.append(.glyph(.sharp, x: 421, pitch: 10)) }
            e.append(.note(x, [p]))
        }
        // 下标：0 谱号，1-4 第一组，5 降号，6-9 第二组，10 升号，11-13 第三组
        return StaffPhrase(elements: e, beams: [
            StaffBeam(from: 1, to: 4), StaffBeam(from: 6, to: 9, count: 2), StaffBeam(from: 11, to: 13)
        ])
    }()

    // 卸载：一步一步往下走的四分音符（不连杠），最后落在一个二分长音上
    static let uninstall: StaffPhrase = {
        var e: [StaffElement] = [.glyph(.treble, x: 30, pitch: 2), .glyph(.flat, x: 95, pitch: 7)]
        let xs: [Double] = [150, 195, 240, 285, 330, 375, 420, 465]
        let ps = [10, 9, 8, 7, 8, 6, 5, 4]
        for (x, p) in zip(xs, ps) { e.append(.note(x, [p], up: p < 6)) }
        e.append(.note(530, [2], up: true, open: true))
        return StaffPhrase(elements: e)
    }()

    /// 关于：一句短短的起伏乐句
    static let about: StaffPhrase = {
        var e: [StaffElement] = [.glyph(.treble, x: 30, pitch: 2)]
        let xs: [Double] = [140, 190, 240, 290, 360, 410, 460, 520]
        let ps = [4, 6, 8, 7, 5, 6, 4, 2]
        for (x, p) in zip(xs, ps) { e.append(.note(x, [p])) }
        return StaffPhrase(elements: e, beams: [StaffBeam(from: 1, to: 4), StaffBeam(from: 5, to: 7)])
    }()

    /// 磁盘分析：低音谱号 + 一串和弦，和弦越厚目录越大。
    /// weights：各目录大小占最大者的比例（0...1），按从大到小排好，最多取 10 个。
    static func analyze(weights: [Double]) -> StaffPhrase {
        var e: [StaffElement] = [.glyph(.bass, x: 25, pitch: 6)]
        let list = weights.isEmpty ? [1, 0.8, 0.6, 0.5, 0.4, 0.3, 0.2, 0.15, 0.1, 0.05] : Array(weights.prefix(10))
        let step = list.count > 1 ? min(50, 440 / Double(list.count - 1)) : 0
        for (i, w) in list.enumerated() {
            let n = max(1, min(5, Int((w * 5).rounded(.up))))
            let base = [0, 1, 2, 3, 4, 5, 6][min(6, i)]
            let pitches = (0..<n).map { base + $0 * 2 }
            e.append(.note(100 + Double(i) * step, pitches, up: true, stem: 40))
        }
        return StaffPhrase(elements: e)
    }
}

/// 画一段五线谱；visibleCount 决定显示到第几个元素，变化时逐个淡入/淡出。
struct NoteStaffView: View {
    let phrase: StaffPhrase
    /// 0...elements.count：前 visibleCount 个可见
    var visibleCount: Int
    var ink: Color = .white
    var lineOpacity: Double = 0.18
    /// 隐藏时下坠（卸载用），否则原地淡出
    var dropOnHide: Bool = false
    var stagger: Double = 0.12
    var duration: Double = 0.35
    /// 空闲律动：未点亮的音符以暗色显示并按节拍跳动
    var idleRhythm: Bool = true
    /// 暗色音符的基础不透明度
    var ghost: Double = 0.26
    /// 每秒跳几个音符
    var beat: Double = 2.6

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let clock = Date()

    @State private var shown: [Bool] = []
    @State private var changedAt: [Date] = []
    @State private var animatingUntil = Date.distantPast
    @State private var tick = 0

    var body: some View {
        let rhythmOn = idleRhythm && !reduceMotion && activeState != .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: tick >= 0 && !rhythmOn && Date() > animatingUntil)) { ctx in
            Canvas { gc, size in
                draw(gc, size: size, now: ctx.date, rhythm: rhythmOn)
            }
        }
        .onAppear { sync(animated: false) }
        .onChange(of: visibleCount) { _, _ in sync(animated: true) }
        .onChange(of: phrase.elements.count) { _, _ in sync(animated: false) }
        .accessibilityHidden(true)
    }

    private func sync(animated: Bool) {
        let n = phrase.elements.count
        let now = Date()
        if shown.count != n {
            shown = Array(repeating: false, count: n)
            changedAt = Array(repeating: .distantPast, count: n)
        }
        let target = max(0, min(n, visibleCount))
        var k = 0
        // 显示：从左到右；隐藏：从右到左
        for i in 0..<n where i < target && !shown[i] {
            shown[i] = true
            changedAt[i] = animated ? now.addingTimeInterval(Double(k) * stagger) : .distantPast
            k += 1
        }
        for i in stride(from: n - 1, through: 0, by: -1) where i >= target && shown[i] {
            shown[i] = false
            changedAt[i] = animated ? now.addingTimeInterval(Double(k) * stagger) : .distantPast
            k += 1
        }
        let total = Double(k) * stagger + duration + 0.1
        animatingUntil = animated ? now.addingTimeInterval(total) : now
        if animated {
            // 动画结束后再刷一次，让 TimelineView 停下来
            DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05) { tick += 1 }
        }
    }

    /// 返回 (点亮程度 0...1, 竖直位移, 暗色音符可见度 0...1)
    private func state(_ i: Int, now: Date) -> (Double, Double, Double) {
        guard i < shown.count else { return (0, 0, 1) }
        let elapsed = now.timeIntervalSince(changedAt[i])
        let t = max(0, min(1, elapsed / duration))
        let eased = 1 - pow(1 - t, 3)
        if shown[i] {
            return (eased, (1 - eased) * 10, 1)
        } else if dropOnHide {
            // 先点亮的音符下坠消失，落完再在原位淡回暗色
            let back = max(0, min(1, (elapsed - duration) / 0.6))
            return (1 - eased, t < 1 ? eased * 22 : 0, back)
        } else {
            return (1 - eased, 0, 1)
        }
    }

    /// 节拍脉冲：0...1，从左到右循环扫过
    private func pulse(_ i: Int, count: Int, now: Date) -> Double {
        let period = Double(count + 3)
        let ph = (now.timeIntervalSince(Self.clock) * beat - Double(i)).truncatingRemainder(dividingBy: period)
        let p = ph < 0 ? ph + period : ph
        return max(exp(-pow(p / 0.7, 2)), exp(-pow((p - period) / 0.7, 2)))
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, now: Date, rhythm: Bool) {
        let refW = 560.0, refH = 200.0, baseY = 150.0, sp = 15.0
        let scale = min(size.width / refW, size.height / refH)
        let ox = (size.width - refW * scale) / 2
        let oy = (size.height - refH * scale) / 2
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        func py(_ p: Double) -> Double { baseY - p * sp / 2 }
        let inkNS = NSColor(ink).usingColorSpace(.sRGB) ?? .white

        // 五线
        for i in 0..<5 {
            var line = Path()
            line.move(to: pt(0, baseY - Double(i) * sp))
            line.addLine(to: pt(refW, baseY - Double(i) * sp))
            gc.stroke(line, with: .color(ink.opacity(lineOpacity)), lineWidth: max(1, 1.4 * scale))
        }

        var stemTips: [Int: (CGPoint, Double, Bool)] = [:]
        let font = MusicFont.ctFont(size: 4 * sp * scale)

        let total = phrase.elements.count
        for (i, el) in phrase.elements.enumerated() {
            let (lit, litDy, ghostVis) = state(i, now: now)
            let pz = rhythm ? pulse(i, count: total, now: now) : 0
            let g = idleRhythm ? (ghost + 0.14 * pz) * ghostVis : 0
            let a = lit + (1 - lit) * g
            let dy = litDy - (1 - lit) * 9 * pz * ghostVis
            guard a > 0.01 else { continue }
            let color = ink.opacity(a)
            switch el.kind {
            case let .glyph(g, pitch):
                if let font {
                    MusicFont.draw(g.codepoint, font: font, color: inkNS.withAlphaComponent(a),
                                   at: pt(el.x, py(pitch) + dy), in: gc)
                }
            case let .note(pitches, stemUp, open, stemLen):
                let headW = 1.18 * sp
                for p in pitches {
                    let y = py(Double(p)) + dy
                    if let font {
                        MusicFont.draw(open ? "\u{E0A3}" : "\u{E0A4}", font: font,
                                       color: inkNS.withAlphaComponent(a), at: pt(el.x, y), in: gc)
                    } else {
                        let r = CGRect(x: ox + el.x * scale, y: oy + (y - 0.45 * sp) * scale,
                                       width: headW * scale, height: 0.9 * sp * scale)
                        gc.fill(Path(ellipseIn: r), with: .color(color))
                    }
                    // 加线
                    var ledgers: [Int] = []
                    if p <= -2 { ledgers = Array(stride(from: -2, through: p, by: -2)) }
                    if p >= 10 { ledgers = Array(stride(from: 10, through: p, by: 2)) }
                    for lp in ledgers {
                        var l = Path()
                        let ly = py(Double(lp)) + dy
                        l.move(to: pt(el.x - 5, ly)); l.addLine(to: pt(el.x + headW + 5, ly))
                        gc.stroke(l, with: .color(color), lineWidth: max(1, 1.4 * scale))
                    }
                }
                if let up = stemUp, let lo = pitches.min(), let hi = pitches.max() {
                    let sx = up ? el.x + headW - 1.1 : el.x + 0.9
                    let y1 = up ? py(Double(lo)) + dy - 2 : py(Double(hi)) + dy + 2
                    let y2 = up ? py(Double(hi)) + dy - stemLen : py(Double(lo)) + dy + stemLen
                    var s = Path()
                    s.move(to: pt(sx, y1)); s.addLine(to: pt(sx, y2))
                    gc.stroke(s, with: .color(color), lineWidth: max(1, 1.5 * scale))
                    stemTips[i] = (CGPoint(x: sx, y: y2), a, up)
                }
            }
        }

        for beam in phrase.beams {
            guard let ta = stemTips[beam.from], let tb = stemTips[beam.to] else { continue }
            let pa = ta.0, pb = tb.0, up = ta.2
            let alpha = (beam.from...beam.to).map { stemTips[$0]?.1 ?? 0 }.min() ?? 0
            guard alpha > 0.01 else { continue }
            let thick = 0.42 * sp
            for k in 0..<beam.count {
                let off = Double(k) * 0.62 * sp * (up ? 1 : -1)
                let h = up ? thick : -thick
                var b = Path()
                b.move(to: pt(pa.x, pa.y + off))
                b.addLine(to: pt(pb.x + 0.75, pb.y + off))
                b.addLine(to: pt(pb.x + 0.75, pb.y + off + h))
                b.addLine(to: pt(pa.x, pa.y + off + h))
                b.closeSubpath()
                gc.fill(b, with: .color(ink.opacity(alpha)))
            }
        }
    }
}

// MARK: - Bravura 字体

enum MusicFont {
    private static var registered = false
    private static var available = false

    /// 按字号取 Bravura；字体文件找不到时返回 nil，调用方退回 Path 画符头、不画谱号。
    static func ctFont(size: Double) -> CTFont? {
        if !registered {
            registered = true
            available = register()
        }
        guard available else { return nil }
        return CTFontCreateWithName("Bravura" as CFString, size, nil)
    }

    private static func register() -> Bool {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("fonts/Bravura.otf"))
        }
        if let dir = ProcessInfo.processInfo.environment["MOLELITE_ASSETS"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("fonts/Bravura.otf"))
        }
        // swift run 时从源码目录取：Sources/MoleLite/UI/NoteStaff.swift -> app/Assets
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(src.appendingPathComponent("Assets/fonts/Bravura.otf"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            // 已注册过也算可用
            if let e = error?.takeRetainedValue(), CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue {
                return true
            }
        }
        return false
    }

    /// 把一个 SMuFL 字形画在 point（字形基线左端，与 SMuFL 约定一致：基线落在对应谱线上）。
    static func draw(_ glyph: String, font: CTFont, color: NSColor, at point: CGPoint, in gc: GraphicsContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attrs))
        gc.withCGContext { cg in
            cg.saveGState()
            cg.translateBy(x: point.x, y: point.y)
            cg.scaleBy(x: 1, y: -1)
            cg.textPosition = .zero
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
    }
}

// MARK: - 推进器：扫描进行中按节奏一个个亮起

/// 忙碌时每 interval 秒多亮一个（最多到 total-1，留最后一个等完成）；完成时全亮；空闲时 0。
struct StaffProgress: ViewModifier {
    let busy: Bool
    let done: Bool
    let total: Int
    @Binding var count: Int
    var interval: Double = 0.45

    func body(content: Content) -> some View {
        content
            .task(id: busy) {
                guard busy else { return }
                count = 1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    count = min(total - 1, count + 1)
                }
            }
            .onChange(of: busy) { _, nowBusy in
                if !nowBusy { count = done ? total : 0 }
            }
            .onChange(of: done) { _, isDone in
                if !busy { count = isDone ? total : 0 }
            }
            .onAppear {
                if !busy { count = done ? total : 0 }
            }
    }
}
