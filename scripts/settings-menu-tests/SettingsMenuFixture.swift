import Foundation
import ObjectiveC.runtime
import SwiftUI
import UIKit

private var settingsMenuLanguageBundleKey: UInt8 = 0

extension Bundle {
    fileprivate static func enableTestLanguageOverride() {
        let original = class_getInstanceMethod(Bundle.self, #selector(localizedString(forKey:value:table:)))!
        let swizzled = class_getInstanceMethod(Bundle.self, #selector(testOverrideLocalizedString(forKey:value:table:)))!
        method_exchangeImplementations(original, swizzled)
    }

    @objc private func testOverrideLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if self == Bundle.main, let b = objc_getAssociatedObject(Bundle.main, &settingsMenuLanguageBundleKey) as? Bundle {
            return b.testOverrideLocalizedString(forKey: key, value: value, table: tableName)
        }
        return testOverrideLocalizedString(forKey: key, value: value, table: tableName)
    }

    fileprivate static func setTestLanguage(_ code: String) {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            objc_setAssociatedObject(Bundle.main, &settingsMenuLanguageBundleKey, b, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else {
            objc_setAssociatedObject(Bundle.main, &settingsMenuLanguageBundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private final class ChartGeometryProbe {
    var geometry: MUChartRenderGeometry?
}

@main
final class SettingsMenuFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var outDir: URL!
    var checks = 0
    var failures: [String] = []
    var themeNotifCount = 0
    var themeObserver: NSObjectProtocol?
    var defaultChartH: CGFloat = 0

    let expectedMapAll: [String: String] = ["en": "All", "zh-Hans": "全部", "zh-Hant": "全部"]
    let expectedMapNoData: [String: String] = ["en": "No data", "zh-Hans": "无数据", "zh-Hant": "無資料"]
    let expectedMapSource: [String: String] = ["en": "Source: ", "zh-Hans": "来源：", "zh-Hant": "來源："]

    func check(_ ok: Bool, _ msg: String) {
        checks += 1
        if !ok { failures.append(msg); print("SETTINGS_MENU_FAIL", msg) }
    }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Bundle.enableTestLanguageOverride()
        outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("settings-menu", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        window = w

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runThemeChecks()
        }
        return true
    }

    func snapshot(_ view: UIView, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    func measureChart<V: View>(_ view: V, style: UIUserInterfaceStyle = .light) -> (CGSize, MUChartRenderGeometry?) {
        let probe = ChartGeometryProbe()
        let probed = view.onPreferenceChange(MUChartRenderGeometryKey.self) { probe.geometry = $0 }
        let host = UIHostingController(rootView: probed)
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.overrideUserInterfaceStyle = style
        let container = window!.rootViewController!
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        let fitted = host.sizeThatFits(in: CGSize(width: 358, height: UIView.layoutFittingExpandedSize.height))
        host.view.frame = CGRect(x: 0, y: 0, width: 358, height: fitted.height)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        return (fitted, probe.geometry)
    }

    func measureSize<V: View>(_ view: V, style: UIUserInterfaceStyle = .light) -> CGSize {
        let host = UIHostingController(rootView: view)
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.overrideUserInterfaceStyle = style
        let container = window!.rootViewController!
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        let fitted = host.sizeThatFits(in: CGSize(width: 358, height: UIView.layoutFittingExpandedSize.height))
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        return fitted
    }

    func nonFlat(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return false }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r0 = buf[0], g0 = buf[1], b0 = buf[2]
        var diff = 0
        for i in stride(from: 0, to: buf.count, by: 16) {
            if abs(Int(buf[i]) - Int(r0)) > 8 || abs(Int(buf[i + 1]) - Int(g0)) > 8 || abs(Int(buf[i + 2]) - Int(b0)) > 8 {
                diff += 1
            }
        }
        return diff > 150
    }

    func runThemeChecks() {
        themeObserver = NotificationCenter.default.addObserver(forName: .chatThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.themeNotifCount += 1
        }
        ChatThemeStore.select("")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.themeNotifCount = 0
            UserDefaults.standard.set(MUChartStyle.economist2017, forKey: MUChartStyle.key)
            UserDefaults.standard.set("bold", forKey: MUChartDrawing.weightKey)
            UserDefaults.standard.set("context", forKey: MUChartDrawing.dashKey)
            ChatThemeStore.select("claude")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.check(ChatThemeStore.current?.id == "claude", "ChatThemeStore.select updates current theme")
                self.check(self.themeNotifCount >= 1, "ChatThemeStore.select posts .chatThemeChanged")
                self.check(UserDefaults.standard.string(forKey: MUChartStyle.key) == MUChartStyle.economist2017, "palette preserved")
                self.check(UserDefaults.standard.string(forKey: MUChartDrawing.weightKey) == "bold", "weight preserved")
                self.check(UserDefaults.standard.string(forKey: MUChartDrawing.dashKey) == "context", "pattern preserved")
                ChatThemeStore.select("deepseek")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.check(self.themeNotifCount >= 2 && ChatThemeStore.current?.id == "deepseek", "second theme switch posts .chatThemeChanged")
                    ChatThemeStore.select("")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.runChartGeometryChecks()
                    }
                }
            }
        }
    }

    func runChartGeometryChecks() {
        let chart = MUComp(
            name: "MultiChart",
            props: [
                "kind": .str("line"),
                "labels": .arr([.str("Jan"), .str("Feb"), .str("Mar"), .str("Apr")]),
                "series": .arr([.str("Main"), .str("Comparison")]),
                "values": .arr([
                    .arr([.num(2.1), .num(4.8), .num(3.2), .num(5.4)]),
                    .arr([.num(1.4), .num(2.3), .num(4.1), .num(2.9)])
                ]),
                "highlight": .arr([.str("Main")]),
            ],
            line: 0
        )
        let ctx = MUContext(state: [:], program: MUProgram(), defaults: [:],
                            set: { _, _, _ in }, commit: {}, run: { _ in })

        let (defaultSize, defaultGeo) = measureChart(MUNodeView(comp: chart, ctx: ctx))
        let (previewSize, previewGeo) = measureChart(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, 104))
        defaultChartH = defaultSize.height
        let defaultPlotH = defaultGeo?.plot.height ?? -1
        let previewPlotH = previewGeo?.plot.height ?? -1

        check(abs(defaultPlotH - 180) <= 0.5, "default formal chat plot height 180: \(defaultPlotH)")
        check(abs(previewPlotH - 104) <= 0.5, "preview plot height 104: \(previewPlotH)")
        check(abs((defaultPlotH - previewPlotH) - 76.0) <= 0.5, "exact 76pt plot delta between 180 and 104: \(defaultPlotH - previewPlotH)")
        check(abs(defaultSize.height - 222) <= 1.0, "default formal chat chart height 180+42: \(defaultSize.height)")
        check(abs(previewSize.height - 146) <= 1.0, "preview plot chart height 104+42: \(previewSize.height)")
        check(abs((defaultSize.height - previewSize.height) - 76.0) <= 0.5, "exact 76pt card delta between 180 and 104")

        for (label, invalidH) in [("zero", CGFloat(0)), ("negative", CGFloat(-10)), ("nan", CGFloat.nan), ("infinity", CGFloat.infinity)] {
            let (sz, geo) = measureChart(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, invalidH))
            let plotH = geo?.plot.height ?? -1
            check(abs(plotH - 180) <= 0.5, "\(label) plot height falls back to 180: \(plotH)")
            check(abs(sz.height - defaultSize.height) <= 0.5, "\(label) card height falls back to 180: \(sz.height)")
        }

        runLayoutCase(index: 0, pngCount: 0)
    }

    func runLayoutCase(index: Int, pngCount: Int) {
        let cases: [(String, String, UIUserInterfaceStyle)] = [
            ("en", "light", .light), ("en", "dark", .dark),
            ("zh-Hans", "light", .light), ("zh-Hans", "dark", .dark),
            ("zh-Hant", "light", .light), ("zh-Hant", "dark", .dark),
        ]
        guard index < cases.count else {
            finish(pngCount: pngCount)
            return
        }
        let (lang, sname, style) = cases[index]
        Bundle.setTestLanguage(lang)
        check(MUMapL10n.all == expectedMapAll[lang], "map all localized \(lang)")
        check(MUMapL10n.noData == expectedMapNoData[lang], "map noData localized \(lang)")
        check(MUMapL10n.sourcePrefix == expectedMapSource[lang], "map source localized \(lang)")

        let previewSize = measureSize(MUChartSettingsPreview(), style: style)
        print(String(format: "SETTINGS_MENU_CASE %@-%@ previewCard=(%.2f, %.2f)", lang, sname, previewSize.width, previewSize.height))
        check(previewSize.width <= 358 && previewSize.height < defaultChartH && previewSize.height >= 165 && previewSize.height <= 220,
              "compact preview card size \(lang)-\(sname): \(previewSize)")

        var togglePreview: (() -> Void)?
        let root = List {
            AppearanceMenuSettingsSections { togglePreview = $0 }
        }
        .listStyle(.insetGrouped)

        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        window?.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        let container = window!.rootViewController!
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        let target = CGSize(width: 390, height: 760)
        host.view.frame = CGRect(origin: .zero, size: target)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let collapsedImg = self.snapshot(host.view, size: target)
            let hasToggle = togglePreview != nil
            self.check(hasToggle, "production AppearanceMenuSettingsSections toggle ready \(lang)-\(sname)")
            togglePreview?()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                let expandedImg = self.snapshot(host.view, size: target)
                self.check(self.nonFlat(collapsedImg) && self.nonFlat(expandedImg), "non-flat render \(lang)-\(sname)")
                self.check(collapsedImg.pngData() != expandedImg.pngData(), "collapsed differs from expanded \(lang)-\(sname)")

                var nextPngCount = pngCount
                if let data = expandedImg.pngData() {
                    let url = self.outDir.appendingPathComponent("settings-\(lang)-\(sname).png")
                    try? data.write(to: url)
                    nextPngCount += 1
                }
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                self.runLayoutCase(index: index + 1, pngCount: nextPngCount)
            }
        }
    }

    func finish(pngCount: Int) {
        if let obs = themeObserver { NotificationCenter.default.removeObserver(obs) }
        let summary = failures.isEmpty
            ? "SETTINGS_MENU_PASS checks=\(checks) png=\(pngCount)"
            : "SETTINGS_MENU_FAIL failures=\(failures.count) checks=\(checks)"
        try? summary.write(to: outDir.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(summary)
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
