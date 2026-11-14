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

@main
enum SettingsMenuRunner {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ ok: Bool, _ msg: String) {
        checks += 1
        if !ok { failures.append(msg); print("SETTINGS_MENU_FAIL", msg) }
    }

    static func snapshot(_ view: UIView, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    static func renderCollapsedAndExpanded(style: UIUserInterfaceStyle, width: CGFloat = 390) -> (UIImage, UIImage, Bool) {
        var togglePreview: (() -> Void)?
        let root = List {
            AppearanceMenuSettingsSections { togglePreview = $0 }
        }
        .listStyle(.insetGrouped)

        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let target = CGSize(width: width, height: 760)
        let collapsedImg = snapshot(host.view, size: target)

        let hasToggle = togglePreview != nil
        togglePreview?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let expandedImg = snapshot(host.view, size: target)

        window.isHidden = true
        return (collapsedImg, expandedImg, hasToggle)
    }

    static func measureSize<V: View>(_ view: V, style: UIUserInterfaceStyle = .light) -> CGSize {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 358, height: 600))
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fitted = host.sizeThatFits(in: CGSize(width: 358, height: UIView.layoutFittingExpandedSize.height))
        window.isHidden = true
        return fitted
    }

    static func nonFlat(_ img: UIImage) -> Bool {
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

    static func main() {
        Bundle.enableTestLanguageOverride()
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("settings-menu", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Settings isolation + .chatThemeChanged notification verification
        var themeNotifCount = 0
        let obs = NotificationCenter.default.addObserver(forName: .chatThemeChanged, object: nil, queue: nil) { _ in
            themeNotifCount += 1
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        ChatThemeStore.select("")
        themeNotifCount = 0
        UserDefaults.standard.set(MUChartStyle.economist2017, forKey: MUChartStyle.key)
        UserDefaults.standard.set("bold", forKey: MUChartDrawing.weightKey)
        UserDefaults.standard.set("context", forKey: MUChartDrawing.dashKey)
        ChatThemeStore.select("claude")
        check(ChatThemeStore.current?.id == "claude", "ChatThemeStore.select updates current theme")
        check(themeNotifCount >= 1, "ChatThemeStore.select posts .chatThemeChanged")
        check(UserDefaults.standard.string(forKey: MUChartStyle.key) == MUChartStyle.economist2017, "palette preserved")
        check(UserDefaults.standard.string(forKey: MUChartDrawing.weightKey) == "bold", "weight preserved")
        check(UserDefaults.standard.string(forKey: MUChartDrawing.dashKey) == "context", "pattern preserved")
        ChatThemeStore.select("deepseek")
        check(themeNotifCount >= 2 && ChatThemeStore.current?.id == "deepseek", "second theme switch posts .chatThemeChanged")
        ChatThemeStore.select("")

        // 2. Exact plot height geometry: default 180pt vs preview 104pt (delta 76pt) + invalid value fallback
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
        let defaultChartH = measureSize(MUNodeView(comp: chart, ctx: ctx)).height
        let previewPlotChartH = measureSize(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, 104)).height
        check(abs(defaultChartH - 222) <= 1.0, "default formal chat chart height 180+42: \(defaultChartH)")
        check(abs(previewPlotChartH - 146) <= 1.0, "preview plot chart height 104+42: \(previewPlotChartH)")
        check(abs((defaultChartH - previewPlotChartH) - 76.0) <= 0.5, "exact 76pt delta between 180 and 104")
        check(abs(measureSize(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, 0)).height - defaultChartH) <= 0.5, "zero height falls back to 180")
        check(abs(measureSize(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, -10)).height - defaultChartH) <= 0.5, "negative height falls back to 180")
        check(abs(measureSize(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, .nan)).height - defaultChartH) <= 0.5, "nan height falls back to 180")
        check(abs(measureSize(MUNodeView(comp: chart, ctx: ctx).environment(\.muChartPlotHeight, .infinity)).height - defaultChartH) <= 0.5, "infinity height falls back to 180")

        // 3. Localization + production AppearanceMenuSettingsSections collapsed -> expanded x 3 langs x 2 styles
        let expectedMapAll: [String: String] = ["en": "All", "zh-Hans": "全部", "zh-Hant": "全部"]
        let expectedMapNoData: [String: String] = ["en": "No data", "zh-Hans": "无数据", "zh-Hant": "無資料"]
        let expectedMapSource: [String: String] = ["en": "Source: ", "zh-Hans": "来源：", "zh-Hant": "來源："]

        var pngCount = 0
        for lang in ["en", "zh-Hans", "zh-Hant"] {
            Bundle.setTestLanguage(lang)
            check(MUMapL10n.all == expectedMapAll[lang], "map all localized \(lang)")
            check(MUMapL10n.noData == expectedMapNoData[lang], "map noData localized \(lang)")
            check(MUMapL10n.sourcePrefix == expectedMapSource[lang], "map source localized \(lang)")

            for (sname, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
                let previewSize = measureSize(MUChartSettingsPreview(), style: style)
                check(previewSize.width <= 358 && previewSize.height < defaultChartH && previewSize.height >= 165 && previewSize.height <= 220,
                      "compact preview card size \(lang)-\(sname): \(previewSize)")

                let (collapsedImg, expandedImg, hasToggle) = renderCollapsedAndExpanded(style: style)
                check(hasToggle, "production AppearanceMenuSettingsSections toggle ready \(lang)-\(sname)")
                check(nonFlat(collapsedImg) && nonFlat(expandedImg), "non-flat render \(lang)-\(sname)")
                check(collapsedImg.pngData() != expandedImg.pngData(), "collapsed differs from expanded \(lang)-\(sname)")

                if let data = expandedImg.pngData() {
                    let url = outDir.appendingPathComponent("settings-\(lang)-\(sname).png")
                    try? data.write(to: url)
                    pngCount += 1
                }
            }
        }

        let summary = failures.isEmpty
            ? "SETTINGS_MENU_PASS checks=\(checks) png=\(pngCount)"
            : "SETTINGS_MENU_FAIL failures=\(failures.count) checks=\(checks)"
        try? summary.write(to: outDir.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(summary)
        if !failures.isEmpty { exit(1) }
    }
}
