import SwiftUI
import UIKit

/// [T-showui-interaction-theme] 3 palettes x 4 chat themes x day/night = 24
/// cases, rendered with the PRODUCTION components (MUNodeView -> MUCallout /
/// MUTable / MUButton), not a redrawn illustration. One PNG per case goes to
/// tmp/showui-interaction/; the marker names the real check count.
@main final class ShowUIInteractionFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var host: UIHostingController<AnyView>!
    var output: URL!
    var checks = 0
    var failures: [String] = []
    var ctx: MUContext!
    var card: MUComp!
    let apps = ["", "chatgpt", "claude", "deepseek"]
    let styles = ["", "economist", "economist2017"]
    let names = ["system", "economist", "economist2017"]
    var panels: [String: Set<String>] = [:]
    var pngs = 0
    var runs = 0
    var diag: [String] = []
    var accentColor: UIColor!

    func check(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures.append(label) } }
    func rgb(_ hex: String) -> MUMapRGB { MUMapRGB(hex: hex) }

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("showui-interaction")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host = UIHostingController(rootView: AnyView(EmptyView()))
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        w.rootViewController = host; w.makeKeyAndVisible(); window = w
        // Use the production AccentColor asset compiled into this fixture app.
        // A window tint alone does not prove Color.accentColor's environment.
        guard let accent = UIColor(named: "AccentColor", in: .main, compatibleWith: nil) else {
            fatalError("SHOWUI_INTERACTION_ASSET_MISSING AccentColor")
        }
        accentColor = accent
        w.tintColor = accent
        let long = String(repeating: "这是一段很长的中文说明文字，用来检查换行、估高与裁切。", count: 5)
        let source = """
        root = Card([
          Title("事件前后的股价走势", "m"),
          Text("公告日前后六个交易日的收盘表现，用于检查 14pt 正文的换行与行高。"),
          Table(["日期", "收盘"], [["11/09 一", "288.15"], ["11/10 二", "287.38"]]),
          Callout("11/17 开盘前暂无当日收盘价，图上最后一点为 11/16 收盘。"),
          Callout("数据为估算，仅供参考。", "warning"),
          Text("来源：用户截图，仅用于配色预览", "secondary", "source"),
          Text("\(long)"),
          Button("对比英伟达同期走势", @Copy("compare")),
          Button("复制数据", @Copy("copy"), style: "secondary")
        ], "GOOGL · 视觉示例")
        """
        let v = MinisUIEngine.validate(source)
        guard v.ok, let root = v.root else { fatalError(MinisUIEngine.feedback(v)) }
        card = root
        ctx = MUContext(state: [:], program: MUProgram.parse(source), defaults: [:],
                        set: { _, _, _ in }, commit: {}, run: { _ in self.runs += 1 })
        runCase(0)
        return true
    }

    func hostFor(_ comp: MUComp, scheme: ColorScheme, surface: MUMapRGB? = nil) {
        let node = MUNodeView(comp: comp, ctx: ctx, topLevel: true)
        if let surface {
            // A raw production Button needs exactly its enclosing Card surface.
            host.rootView = AnyView(node.environment(\.muSurface, surface)
                .modifier(MURootSurface()).environment(\.colorScheme, scheme))
        } else {
            host.rootView = AnyView(node.modifier(MURootSurface()).environment(\.colorScheme, scheme))
        }
    }

    func render(_ scheme: ColorScheme, width: CGFloat = 360, canvas: UIColor? = nil) -> (UIImage, CGFloat) {
        window!.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        // mount -> settle -> measure, never measure in the same turn as mount
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        host.view.backgroundColor = canvas ?? ChatColors.backgroundUIColor
        let size = host.sizeThatFits(in: CGSize(width: width, height: 2400))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            self.host.view.drawHierarchy(in: self.host.view.bounds, afterScreenUpdates: true)
        }
        return (image, host.sizeThatFits(in: CGSize(width: width, height: 2400)).height)
    }

    func pixelBytes(_ image: UIImage) -> (Int, Int, [UInt8]) {
        let cg = image.cgImage!, width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, bytes)
    }

    /// Actual dominant raster colour, not a token inserted into its own set.
    func dominant(_ image: UIImage) -> MUMapRGB {
        let (width, height, bytes) = pixelBytes(image)
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                let v = UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2])
                counts[v, default: 0] += 1
            }
        }
        return rgb(String(format: "#%06X", counts.max(by: { $0.value < $1.value })!.key))
    }

    /// Only use a component-local image for proof; a whole Card can have the
    /// same colour as a panel and would falsely satisfy a global pixel count.
    func matches(_ image: UIImage, _ candidates: [(String, MUMapRGB)]) -> [String: Int] {
        var out = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0, 0) })
        let (width, height, bytes) = pixelBytes(image)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                let p = MUMapRGB(hex: String(format: "#%02X%02X%02X", bytes[o], bytes[o + 1], bytes[o + 2]))
                for (name, candidate) in candidates {
                    let (r, g, b) = p.rgb, (cr, cg, cb) = candidate.rgb
                    if abs(r - cr) < 0.015 && abs(g - cg) < 0.015 && abs(b - cb) < 0.015 { out[name, default: 0] += 1 }
                }
            }
        }
        return out
    }

    func native(_ color: MUMapRGB) -> UIColor {
        let (r, g, b) = color.rgb
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    /// Contrast from the ACTUAL flat glyph core against the actual dominant
    /// fill. Sampling the darkest near-ink pixel measured antialiasing instead
    /// of legibility: at 14pt every stroke carries a lighter edge pixel inside
    /// the 4/255 match tolerance, so a label that legitimately sits just above
    /// the 4.5:1 floor always read about 4.4 and failed. The modal matched pixel
    /// is the solid stroke colour. A missing core returns zero, never a pass.
    func rasterContrast(_ image: UIImage, ink: MUMapRGB, fill: MUMapRGB) -> Double {
        let (width, height, bytes) = pixelBytes(image)
        let (r, g, b) = ink.rgb
        var counts: [String: Int] = [:]
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                let hex = String(format: "#%02X%02X%02X", bytes[o], bytes[o + 1], bytes[o + 2])
                let (pr, pg, pb) = rgb(hex).rgb
                if abs(r - pr) < 0.015 && abs(g - pg) < 0.015 && abs(b - pb) < 0.015 {
                    counts[hex, default: 0] += 1
                }
            }
        }
        guard let core = counts.max(by: { $0.value < $1.value }), core.value >= 40 else { return 0 }
        return rgb(core.key).contrast(on: fill)
    }

    /// Worst antialiased pixel near the ink. Diagnostic only: it measures glyph
    /// blending, not legibility, so it never decides pass or fail.
    func rasterEdgeMinimum(_ image: UIImage, ink: MUMapRGB, fill: MUMapRGB) -> Double {
        let (width, height, bytes) = pixelBytes(image)
        let (r, g, b) = ink.rgb
        var lowest = Double.infinity
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                let p = rgb(String(format: "#%02X%02X%02X", bytes[o], bytes[o + 1], bytes[o + 2]))
                let (pr, pg, pb) = p.rgb
                if abs(r - pr) < 0.015 && abs(g - pg) < 0.015 && abs(b - pb) < 0.015 {
                    lowest = min(lowest, p.contrast(on: fill))
                }
            }
        }
        return lowest.isFinite ? lowest : 0
    }

    func runCase(_ index: Int) {
        if index == 24 {
            finish(); return
        }
        let style = styles[index / 8], app = apps[(index % 8) / 2]
        let dark = index % 2 == 1
        let scheme: ColorScheme = dark ? .dark : .light
        let label = "\(names[index / 8])-\(app.isEmpty ? "default" : app)-\(dark ? "night" : "day")"
        ChatThemeStore.select(app)
        UserDefaults.standard.set(style, forKey: MUChartStyle.key)
        window!.overrideUserInterfaceStyle = dark ? .dark : .light
        hostFor(card, scheme: scheme)
        host.view.backgroundColor = ChatColors.backgroundUIColor
        // Same contract as theme-matrix: the theme, the trait and the mounted
        // root view need real run-loop turns before the first screenshot,
        // otherwise the pixels can still belong to the previous case.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            self.measureCase(index, style: style, app: app, dark: dark, label: label)
        }
    }

    func measureCase(_ index: Int, style: String, app: String, dark: Bool, label: String) {
        let scheme: ColorScheme = dark ? .dark : .light
        let tokens = MUChartInteractionTheme.interior(style, dark: dark)

        // 1. the whole confirmed card (with both real buttons), one PNG per case
        let (image, measured) = render(scheme)
        let file = "case-" + String(format: "%02d", index) + "-" + label + ".png"
        try! image.pngData()!.write(to: output.appendingPathComponent(file))
        pngs += 1
        check(image.size.height > 200, "\(label): the card really rendered")
        let cardFill = MUSurface.rgb(ChatColors.secondaryBgUIColor, over: MUSurface.rgb(ChatColors.backgroundUIColor, over: rgb("#FFFFFF"), scheme: scheme), scheme: scheme)
        let seen = matches(image, [("card", cardFill), ("panel", tokens.panel), ("note", tokens.note)])
        check((seen["panel"] ?? 0) > 40, "\(label): the table panel is painted in the palette token")
        check((seen["note"] ?? 0) > 40, "\(label): the callout ground is painted in the palette note token")

        // 2. estimate <-> measured convergence for a long Chinese card
        let estimate = MinisUIEngine.estimatedHeight(card, width: 324)
        check(measured > estimate * 0.7 && measured < estimate + 220,
              "\(label): estimated \(Int(estimate)) vs measured \(Int(measured)) stays in one band")
        let again = host.sizeThatFits(in: CGSize(width: 360, height: 2400)).height
        check(abs(again - measured) < 0.5, "\(label): no late height jump")

        // 3. The independence set is filled below from actual table pixels.
        let key = "\(style)|\(dark)"

        // 4. callout: no 3pt bar, info neutral, status semantic
        let infoCard = MUProgram.parse("root = Card([Callout(\"信息说明文字\")])").render([:]).0!
        hostFor(infoCard.children[0], scheme: scheme)
        let (infoImage, _) = render(scheme, canvas: .magenta)
        let info = MUChartInteractionTheme.resolved(tone: "info", dark: dark, palette: style)
        let infoSeen = matches(infoImage, [("note", info.fill), ("bar", MUChartInteractionTheme.info.rgb(forDarkSurface: dark)),
                                          ("text", info.text)])
        check((infoSeen["note"] ?? 0) > 60, "\(label): the info box uses the neutral note ground")
        check((infoSeen["bar"] ?? 0) < 120, "\(label): no 3pt info-blue leading bar is painted")
        check((infoSeen["text"] ?? 0) > 40, "\(label): the info text is painted in the palette ink")
        let warnCard = MUProgram.parse("root = Card([Callout(\"警告文字\", \"warning\")])").render([:]).0!
        hostFor(warnCard.children[0], scheme: scheme)
        let (warnImage, _) = render(scheme, canvas: .magenta)
        let warn = MUChartInteractionTheme.resolved(tone: "warning", dark: dark, palette: style)
        let warnSeen = matches(warnImage, [("fill", warn.fill), ("accent", warn.accent)])
        check((warnSeen["fill"] ?? 0) > 60, "\(label): warning keeps its semantic wash")
        check((warnSeen["accent"] ?? 0) > 20, "\(label): warning keeps its semantic icon")

        // 5. table: chat theme cannot repaint it
        let tableCard = MUProgram.parse("root = Card([Table([\"日期\", \"收盘\"], [[\"11/09\", \"288.15\"]])])").render([:]).0!
        hostFor(tableCard.children[0], scheme: scheme)
        let (tableImage, _) = render(scheme, canvas: .magenta)
        let tableSeen = matches(tableImage, [("panel", tokens.panel)])
        check((tableSeen["panel"] ?? 0) > 600, "\(label): the isolated table paints a substantial palette panel")
        check((seen["card"] ?? 0) > 20, "\(label): the outer Card stays on the chat theme")
        panels[key, default: []].insert(dominant(tableImage).hex)
        check(panels[key]!.count == 1, "\(label): actual table raster colour is chat independent")

        // 6. buttons: fill follows the chat tint, label clears 4.5:1
        let buttonCard = MUProgram.parse("""
        root = Card([Button("对比英伟达同期走势", @Copy("x")), Button("复制数据", @Copy("y"), style: "secondary")])
        """).render([:]).0!
        // Each button is also rendered alone below, so no other text can
        // satisfy a label-colour count for this button.
        // MUButton inherits the real Card surface (MUSurface.base of the mounted
        // tree), not systemBackground: reuse the cardFill sampled for THIS case.
        let surface = cardFill
        let tint = MUSurface.rgb(ChatColors.tintUIColor, over: surface, scheme: scheme)
        if app.isEmpty {
            // Two separate facts, so a failure says WHICH one moved: the bundled
            // asset is still the documented blue, and the Default chat theme's
            // tint really resolves through that asset rather than the system
            // default. A bare `EnvironmentValues` used to answer #007AFF here.
            let assetNow = MUSurface.rgb(accentColor, over: surface, scheme: scheme)
            check(assetNow == (dark ? rgb("#5490E4") : rgb("#3686EE")),
                  "\(label): the bundled AccentColor asset is still the documented blue (got \(assetNow.hex))")
            check(tint == assetNow,
                  "\(label): the Default chat tint resolves to the app AccentColor (tint \(tint.hex) vs asset \(assetNow.hex))")
        }
        let labelInk = MUActionText.on(tint)
        let wash = tint.composited(over: surface, alpha: 0.12)
        let secondaryInk = MUActionText.secondaryInk(tint: tint, wash: wash)
        hostFor(buttonCard.children[0], scheme: scheme, surface: surface)
        let (primaryImage, _) = render(scheme, canvas: native(surface))
        hostFor(buttonCard.children[1], scheme: scheme, surface: surface)
        let (secondaryImage, _) = render(scheme, canvas: native(surface))
        let primarySeen = matches(primaryImage, [("fill", tint), ("text", labelInk)])
        let secondarySeen = matches(secondaryImage, [("wash", wash), ("text", secondaryInk)])
        check((primarySeen["fill"] ?? 0) > 600, "\(label): the primary button paints the chat tint")
        check((secondarySeen["wash"] ?? 0) > 600, "\(label): the secondary button paints the 12% tint wash")
        check((primarySeen["text"] ?? 0) > 80, "\(label): substantial primary glyph pixels use the resolved ink")
        check((secondarySeen["text"] ?? 0) > 80, "\(label): substantial secondary glyph pixels use the resolved ink")
        check(labelInk.contrast(on: tint) >= 4.5, "\(label): primary label >= 4.5:1")
        check(secondaryInk.contrast(on: wash) >= 4.5, "\(label): secondary label >= 4.5:1")
        let primaryFill = dominant(primaryImage)
        let secondaryFill = dominant(secondaryImage)
        let primaryCore = rasterContrast(primaryImage, ink: labelInk, fill: primaryFill)
        let secondaryCore = rasterContrast(secondaryImage, ink: secondaryInk, fill: secondaryFill)
        check(primaryCore >= 4.5,
              "\(label): actual primary raster foreground/background >= 4.5:1")
        check(secondaryCore >= 4.5,
              "\(label): actual secondary raster foreground/background >= 4.5:1")
        let primaryEdge = rasterEdgeMinimum(primaryImage, ink: labelInk, fill: primaryFill)
        let secondaryEdge = rasterEdgeMinimum(secondaryImage, ink: secondaryInk, fill: secondaryFill)
        diag.append("\(label) surface=\(surface.hex) tint=\(tint.hex) wash=\(wash.hex)"
            + " labelInk=\(labelInk.hex) secondaryInk=\(secondaryInk.hex)"
            + " primaryFill=\(primaryFill.hex) secondaryFill=\(secondaryFill.hex)"
            + " primaryCore=\(String(format: "%.2f", primaryCore))"
            + " secondaryCore=\(String(format: "%.2f", secondaryCore))"
            + " primaryEdgeMin=\(String(format: "%.2f", primaryEdge))"
            + " secondaryEdgeMin=\(String(format: "%.2f", secondaryEdge))")
        check(labelInk != rgb("#FFFFFF"), "\(label): the primary label is never pure white")
        // the action survived both styles
        let buttons = buttonCard.children
        check(buttons.count == 2 && buttons.allSatisfy { $0.action != nil }, "\(label): both buttons keep their action")
        // The MUButton body calls ctx.run(action); the closure is the same one,
        // so firing it proves the wiring, NOT a user tap on the glass.
        runs = 0
        for b in buttons { if let a = b.action { ctx.run(a) } }
        check(runs == 2, "\(label): both actions reach ctx.run (closure invoked directly, not a UI tap)")

        // 7. typography heights: 14 > 12 > 10.5, measured, not asserted from source
        func textHeight(_ extra: String) -> CGFloat {
            let c = MUProgram.parse("root = Card([Text(\"一段中文说明文字示例\"\(extra))])").render([:]).0!
            hostFor(c, scheme: scheme)
            return render(scheme).1
        }
        let body = textHeight("")
        let note = textHeight(", null, \"note\"")
        let src = textHeight(", null, \"source\"")
        check(body > note && note > src, "\(label): measured heights order body > note > source")
        check(body - note >= 1 && body - note <= 5, "\(label): 14pt vs 12pt differ by a line box, not a jump")
        check(note - src >= 1 && note - src <= 5, "\(label): 12pt vs 10.5pt differ by a line box")
        check(src > 12, "\(label): the 10.5pt source still renders a text line")

        if index == 23 {
            check(panels.count == 6 && panels.values.allSatisfy { $0.count == 1 },
                  "all six palette/mode interiors are one colour across four chat themes")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.runCase(index + 1) }
    }

    func finish() {
        var log = "SHOWUI_INTERACTION_" + (failures.isEmpty ? "PASS" : "FAILED")
        log += " checks=\(checks) cases=24 png=\(pngs)\n"
        for f in failures { log += "FAILED: \(f)\n" }
        // Measured values for the button block, so a future verdict can be read
        // without guessing which of tint / wash / ink actually moved.
        for d in diag { log += "DIAG " + d + "\n" }
        try! log.write(to: output.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(log)
        exit(failures.isEmpty ? 0 : 1)
    }
}
