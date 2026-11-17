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
        let long = String(repeating: "这是一段很长的中文说明文字，用来检查换行、估高与裁切。", count: 5)
        let source = """
        root = Card([
          Title("事件前后的股价走势", "m"),
          Text("公告日前后六个交易日的收盘表现，用于检查 14pt 正文的换行与行高。"),
          Table(["日期", "收盘"], [["11/09 一", "288.15"], ["11/10 二", "287.38"]]),
          Callout("11/17 开盘前暂无当日收盘价，图上最后一点为 11/16 收盘。"),
          Callout("数据为估算，仅供参考。", "warning"),
          Text("来源：用户截图，仅用于配色预览", "secondary", "source"),
          Text("\(long)")
        ], "GOOGL · 视觉示例")
        """
        let v = MinisUIEngine.validate(source)
        guard v.ok, let root = v.root else { fatalError(MinisUIEngine.feedback(v)) }
        card = root
        ctx = MUContext(state: [:], program: MUProgram.parse(source), defaults: [:],
                        set: { _, _, _ in }, commit: {}, run: { _ in })
        runCase(0)
        return true
    }

    func hostFor(_ comp: MUComp, scheme: ColorScheme) {
        host.rootView = AnyView(MUNodeView(comp: comp, ctx: ctx, topLevel: true)
            .modifier(MURootSurface()).environment(\.colorScheme, scheme))
    }

    func render(_ scheme: ColorScheme, width: CGFloat = 360) -> (UIImage, CGFloat) {
        window!.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        host.view.backgroundColor = ChatColors.backgroundUIColor
        let size = host.sizeThatFits(in: CGSize(width: width, height: 2400))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            self.host.view.drawHierarchy(in: self.host.view.bounds, afterScreenUpdates: true)
        }
        return (image, host.sizeThatFits(in: CGSize(width: width, height: 2400)).height)
    }

    /// How many pixels of each candidate colour the image actually contains.
    func matches(_ image: UIImage, _ candidates: [(String, MUMapRGB)]) -> [String: Int] {
        var out = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0, 0) })
        let cg = image.cgImage!, width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
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
        let tokens = MUChartInteractionTheme.interior(style, dark: dark)

        // 1. the whole confirmed card, one PNG per case
        hostFor(card, scheme: scheme)
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

        // 3. interior is chat independent: the same palette/mode gives one panel
        let key = "\(style)|\(dark)"
        panels[key, default: []].insert(tokens.panel.hex)
        check(panels[key]!.count == 1, "\(label): the interior does not depend on the chat theme")

        // 4. callout: no 3pt bar, info neutral, status semantic
        let infoCard = MUProgram.parse("root = Card([Callout(\"信息说明文字\")])").render([:]).0!
        hostFor(infoCard, scheme: scheme)
        let (infoImage, _) = render(scheme)
        let info = MUChartInteractionTheme.resolved(tone: "info", dark: dark, palette: style)
        let infoSeen = matches(infoImage, [("note", info.fill), ("bar", MUChartInteractionTheme.info.rgb(forDarkSurface: dark)),
                                          ("text", info.text)])
        check((infoSeen["note"] ?? 0) > 60, "\(label): the info box uses the neutral note ground")
        check((infoSeen["bar"] ?? 0) < 120, "\(label): no 3pt info-blue leading bar is painted")
        check((infoSeen["text"] ?? 0) > 4, "\(label): the info text is painted in the palette ink")
        let warnCard = MUProgram.parse("root = Card([Callout(\"警告文字\", \"warning\")])").render([:]).0!
        hostFor(warnCard, scheme: scheme)
        let (warnImage, _) = render(scheme)
        let warn = MUChartInteractionTheme.resolved(tone: "warning", dark: dark, palette: style)
        let warnSeen = matches(warnImage, [("fill", warn.fill), ("accent", warn.accent)])
        check((warnSeen["fill"] ?? 0) > 60, "\(label): warning keeps its semantic wash")
        check((warnSeen["accent"] ?? 0) > 2, "\(label): warning keeps its semantic icon")

        // 5. table: chat theme cannot repaint it
        let tableCard = MUProgram.parse("root = Card([Table([\"日期\", \"收盘\"], [[\"11/09\", \"288.15\"]])])").render([:]).0!
        hostFor(tableCard, scheme: scheme)
        let (tableImage, _) = render(scheme)
        let tableSeen = matches(tableImage, [("panel", tokens.panel), ("card", cardFill)])
        check((tableSeen["panel"] ?? 0) > 60, "\(label): the table ground is the palette panel")
        check((tableSeen["card"] ?? 0) > 20, "\(label): the outer Card stays on the chat theme")

        // 6. buttons: fill follows the chat tint, label clears 4.5:1
        let buttonCard = MUProgram.parse("""
        root = Card([Button("对比英伟达同期走势", @Copy("x")), Button("复制数据", @Copy("y"), style: "secondary")])
        """).render([:]).0!
        hostFor(buttonCard, scheme: scheme)
        let (buttonImage, _) = render(scheme)
        let surface = MUSurface.base(nil, scheme: scheme)
        let tint = MUSurface.rgb(ChatColors.tint, over: surface, scheme: scheme)
        let labelInk = MUActionText.on(tint)
        let wash = tint.composited(over: surface, alpha: 0.12)
        let secondaryInk = MUActionText.secondaryInk(tint: tint, wash: wash)
        let buttonSeen = matches(buttonImage, [("fill", tint), ("wash", wash), ("primaryText", labelInk), ("secondaryText", secondaryInk)])
        check((buttonSeen["fill"] ?? 0) > 60, "\(label): the primary button is filled with the chat tint")
        check((buttonSeen["wash"] ?? 0) > 20, "\(label): the secondary button uses the 12% tint wash")
        check((buttonSeen["primaryText"] ?? 0) > 3, "\(label): the primary label uses the resolved colour")
        check((buttonSeen["secondaryText"] ?? 0) > 3, "\(label): the secondary label uses the resolved colour")
        check(labelInk.contrast(on: tint) >= 4.5, "\(label): primary label >= 4.5:1")
        check(secondaryInk.contrast(on: wash) >= 4.5, "\(label): secondary label >= 4.5:1")
        check(labelInk != rgb("#FFFFFF"), "\(label): the primary label is never pure white")
        // the action survived both styles
        let buttons = buttonCard.children
        check(buttons.count == 2 && buttons.allSatisfy { $0.action != nil }, "\(label): both buttons keep their action")

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
        try! log.write(to: output.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(log)
        exit(failures.isEmpty ? 0 : 1)
    }
}
