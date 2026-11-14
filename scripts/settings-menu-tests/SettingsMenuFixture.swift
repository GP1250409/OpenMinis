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

private struct SettingsMenuHarnessView: View {
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("chatThemeId") private var chatThemeId: String = ""
    @AppStorage(MUChartStyle.key) private var genuiChartPalette: String = MUChartStyle.economist
    @AppStorage(MUChartDrawing.weightKey) private var genuiChartWeight = "standard"
    @AppStorage(MUChartDrawing.dashKey) private var genuiChartPattern = "context"
    let expanded: Bool

    private func l(_ key: String) -> String {
        NSLocalizedString(key, value: key, comment: "")
    }

    var body: some View {
        List {
            Section {
                Picker(l("Theme"), selection: $appearanceMode) {
                    Text(l("System")).tag(0)
                    Text(l("Light")).tag(1)
                    Text(l("Dark")).tag(2)
                }
                .pickerStyle(.menu)
            } header: {
                Text(l("Theme"))
            }
            Section {
                Picker(l("Chat Theme"), selection: $chatThemeId) {
                    Text(l("Default Theme")).tag("")
                    ForEach(ChatTheme.custom) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(l("Chat Theme"))
            }
            Section {
                Picker(l("Chart Colours"), selection: $genuiChartPalette) {
                    Text(l("System")).tag("")
                    Text(l("The Economist")).tag(MUChartStyle.economist)
                    Text(l("The Economist (2017 guide)")).tag(MUChartStyle.economist2017)
                }
                .pickerStyle(.menu)
                Picker(l("Chart stroke weight"), selection: $genuiChartWeight) {
                    Text(l("Fine")).tag("fine")
                    Text(l("Standard")).tag("standard")
                    Text(l("Bold")).tag("bold")
                }
                .pickerStyle(.menu)
                Picker(l("Chart line pattern"), selection: $genuiChartPattern) {
                    Text(l("Solid")).tag("solid")
                    Text(l("Dashed context series")).tag("context")
                    Text(l("All lines dashed")).tag("dashed")
                }
                .pickerStyle(.menu)
                HStack {
                    Text(l("Preview"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                if expanded {
                    MUChartSettingsPreview()
                }
            } header: {
                Text(l("Interactive Cards · Charts & Maps"))
            } footer: {
                Text(l("Cards follow Chat Theme; charts and maps keep independent colours. Line weight adjusts chart lines, axes and grid; dashed styles apply only to line charts, not maps. Chart settings are saved separately."))
            }
        }
        .listStyle(.insetGrouped)
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

    static func render(_ view: AnyView, style: UIUserInterfaceStyle, width: CGFloat = 390) -> (UIImage, CGSize) {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        let target = CGSize(width: width, height: 760)
        let img = UIGraphicsImageRenderer(size: target).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: target), afterScreenUpdates: true)
        }
        window.isHidden = true
        return (img, target)
    }

    static func measurePreview(_ style: UIUserInterfaceStyle) -> CGSize {
        let host = UIHostingController(rootView: MUChartSettingsPreview())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 358, height: 600))
        window.overrideUserInterfaceStyle = style
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
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

        // Preserve & verify settings isolation: ChatThemeStore.select must not reset chart keys
        UserDefaults.standard.set(MUChartStyle.economist2017, forKey: MUChartStyle.key)
        UserDefaults.standard.set("bold", forKey: MUChartDrawing.weightKey)
        UserDefaults.standard.set("context", forKey: MUChartDrawing.dashKey)
        ChatThemeStore.select("claude")
        check(ChatThemeStore.current?.id == "claude", "ChatThemeStore.select updates current theme")
        check(UserDefaults.standard.string(forKey: MUChartStyle.key) == MUChartStyle.economist2017, "palette preserved")
        check(UserDefaults.standard.string(forKey: MUChartDrawing.weightKey) == "bold", "weight preserved")
        check(UserDefaults.standard.string(forKey: MUChartDrawing.dashKey) == "context", "pattern preserved")

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
                let previewSize = measurePreview(style)
                check(previewSize.width <= 358 && previewSize.height >= 165 && previewSize.height <= 265,
                      "compact preview size \(lang)-\(sname): \(previewSize)")

                let (collapsedImg, _) = render(AnyView(SettingsMenuHarnessView(expanded: false)), style: style)
                let (expandedImg, _) = render(AnyView(SettingsMenuHarnessView(expanded: true)), style: style)
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
