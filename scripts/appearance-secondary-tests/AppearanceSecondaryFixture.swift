import Combine
import Foundation
import ObjectiveC.runtime
import SwiftUI
import UIKit

@MainActor
final class NavProbe: ObservableObject {
    enum Command {
        case reset
        case push(SettingsDestination)
        case pop
    }

    let commandSubject = PassthroughSubject<Command, Never>()
    var autoOpenSettingsOnMount = true
    var simulatedSystemLocaleId: String = "en"
    var contentMountCount = 0
    var sheetMountCount = 0
    var navCount = 0
    var lastConsumedReopen: String?

    func syncPathCount(_ count: Int) {
        navCount = count
    }
}

struct RootReproView: View {
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @ObservedObject var probe: NavProbe

    var body: some View {
        ContentReproView(probe: probe)
            .id(appLanguage)
            .environment(\.locale, Locale(identifier: appLanguage.isEmpty ? probe.simulatedSystemLocaleId : appLanguage))
    }
}

struct ContentReproView: View {
    @ObservedObject var probe: NavProbe
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsSheetHarness(probe: probe)
            } else {
                Color(.systemBackground)
            }
        }
        .onAppear {
            probe.contentMountCount += 1
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil {
                DispatchQueue.main.async {
                    showSettings = true
                }
            } else if probe.autoOpenSettingsOnMount {
                showSettings = true
            }
        }
    }
}

struct SettingsSheetHarness: View {
    @ObservedObject var probe: NavProbe
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                Section("Appearance") {
                    NavigationLink(value: SettingsDestination.appearance) {
                        Label {
                            Text("Appearance")
                        } icon: {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { dest in
                switch dest {
                case .appearance:
                    AppearanceSettingsView()
                case .appearanceAppIcon:
                    AppIconSettingsView()
                case .appearanceLanguage:
                    LanguageSettingsView()
                default:
                    EmptyView()
                }
            }
            .onAppear {
                probe.sheetMountCount += 1
                if let dest = UserDefaults.standard.string(forKey: "pendingSettingsReopen") {
                    UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
                    probe.lastConsumedReopen = dest
                    switch dest {
                    case "appearance":
                        navPath.append(SettingsDestination.appearance)
                    case "appearance-language":
                        navPath.append(SettingsDestination.appearance)
                        navPath.append(SettingsDestination.appearanceLanguage)
                    default:
                        break
                    }
                }
                probe.syncPathCount(navPath.count)
            }
            .onChange(of: navPath.count) { newCount in
                probe.syncPathCount(newCount)
            }
            .onReceive(probe.commandSubject) { cmd in
                switch cmd {
                case .reset:
                    navPath = NavigationPath()
                case .push(let dest):
                    navPath.append(dest)
                case .pop:
                    if !navPath.isEmpty { navPath.removeLast() }
                }
                probe.syncPathCount(navPath.count)
            }
        }
        .preferredColorScheme(appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : nil)
        .appFontScale()
    }
}

@main
final class AppearanceSecondaryFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var outDir: URL!
    var checks = 0
    var failures: [String] = []
    var pngCount = 0
    let probe = NavProbe()
    var host: UIHostingController<RootReproView>!

    var topZhLight: UIImage!
    var midZhLight: UIImage!
    var bottomZhLight: UIImage!
    var topEnDark: UIImage!

    var prevSuspend = 0
    var prevContentMounts = 0
    var prevSheetMounts = 0

    func check(_ ok: Bool, _ msg: String) {
        checks += 1
        if !ok {
            failures.append(msg)
            print("APPEARANCE_SECONDARY_FAIL", msg)
        }
    }

    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Bundle.enableLanguageOverride()
        UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
        UserDefaults.standard.set("", forKey: "appLanguage")
        UserDefaults.standard.set(0, forKey: "appearanceMode")
        UserDefaults.standard.set(0, forKey: "appIconMode")
        UserDefaults.standard.set(0, forKey: "returnKeyBehavior")
        probe.simulatedSystemLocaleId = "zh-Hans"
        Bundle.setLanguage("zh-Hans")

        outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appearance-secondary", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let h = UIHostingController(rootView: RootReproView(probe: probe))
        w.rootViewController = h
        w.makeKeyAndVisible()
        window = w
        host = h

        after(0.6) {
            self.phase0_staticAndPushAppearance()
        }
        return true
    }

    func snapshotWindow() -> UIImage {
        let size = window!.bounds.size
        return UIGraphicsImageRenderer(size: size).image { _ in
            window!.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    func savePNG(_ image: UIImage, name: String) {
        if let data = image.pngData() {
            let url = outDir.appendingPathComponent(name)
            try? data.write(to: url)
            pngCount += 1
        }
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

    func hasSaturatedBluePixels(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return false }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Int(buf[i]), b = Int(buf[i + 2])
            if b - r > 50 && b > 120 {
                count += 1
            }
        }
        return count > 20
    }

    func findScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let sv = v as? UIScrollView, sv.contentSize.height > sv.bounds.height + 50 {
                if best == nil || sv.contentSize.height > best!.contentSize.height {
                    best = sv
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return best
    }

    func collectButtonsDiag(in view: UIView) -> [String] {
        var out: [String] = []
        func walk(_ v: UIView) {
            if let btn = v as? UIButton {
                let frame = btn.convert(btn.bounds, to: window)
                out.append("btn(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)),tint=\(btn.tintColor?.description ?? "nil"))")
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return out
    }

    func scrollToOffsetY(_ y: CGFloat, then block: @escaping () -> Void) {
        if let sv = findScrollView(in: window!) {
            let maxY = max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            let clamped = min(max(-sv.adjustedContentInset.top, y), maxY)
            sv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            sv.layoutIfNeeded()
        }
        after(0.35, block)
    }

    func scrollToTrueBottom(passesLeft: Int = 4, then block: @escaping () -> Void) {
        guard passesLeft > 0 else {
            after(0.25, block)
            return
        }
        if let sv = findScrollView(in: window!) {
            let maxY = max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            sv.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            sv.layoutIfNeeded()
        }
        after(0.22) {
            self.scrollToTrueBottom(passesLeft: passesLeft - 1, then: block)
        }
    }

    func phase0_staticAndPushAppearance() {
        check(UIApplication.shared.supportsAlternateIcons, "UIApplication.supportsAlternateIcons is true in bundle")
        for imgName in ["AlternateIcons/AppIcon-Light", "AlternateIcons/AppIcon-Dark", "AlternateIcons/AppIcon-LegacyLight", "AlternateIcons/AppIcon-LegacyDark"] {
            check(UIImage(named: imgName) != nil, "bundle loads \(imgName)")
        }

        check(AppearanceSettingsView.appIconSummaryKey(for: 0) == "Automatic", "appIconSummaryKey(0)")
        check(AppearanceSettingsView.appIconSummaryKey(for: 1) == "Light", "appIconSummaryKey(1)")
        check(AppearanceSettingsView.appIconSummaryKey(for: 2) == "Dark", "appIconSummaryKey(2)")
        check(AppearanceSettingsView.appIconSummaryKey(for: 3) == "Light (Legacy)", "appIconSummaryKey(3)")
        check(AppearanceSettingsView.appIconSummaryKey(for: 4) == "Dark (Legacy)", "appIconSummaryKey(4)")
        check(AppearanceSettingsView.appIconSummaryKey(for: 99) == "Automatic", "appIconSummaryKey(fallback)")
        check(AppearanceSettingsView.languageSummary(for: "") == .localizedKey("System"), "languageSummary empty")
        check(AppearanceSettingsView.languageSummary(for: "zh-Hans") == .verbatim("简体中文"), "languageSummary zh-Hans")
        check(AppearanceSettingsView.languageSummary(for: "zh-Hant") == .verbatim("繁體中文"), "languageSummary zh-Hant")
        check(AppearanceSettingsView.languageSummary(for: "pt-BR") == .verbatim("Português (Brasil)"), "languageSummary pt-BR")
        check(AppearanceSettingsView.languageSummary(for: "xx-Custom") == .verbatim("xx-Custom"), "languageSummary unknown fallback")

        UserDefaults.standard.set(1, forKey: "returnKeyBehavior")
        check(UserDefaults.standard.integer(forKey: "returnKeyBehavior") == 1, "returnKeyBehavior=1 persisted")
        UserDefaults.standard.set(0, forKey: "returnKeyBehavior")
        check(UserDefaults.standard.integer(forKey: "returnKeyBehavior") == 0, "returnKeyBehavior=0 persisted")

        probe.commandSubject.send(.push(.appearance))
        after(0.85) { self.phase1_topZhLight() }
    }

    func phase1_topZhLight() {
        check(probe.navCount == 1, "navigated to AppearanceSettingsView (navCount=1)")
        topZhLight = snapshotWindow()
        check(nonFlat(topZhLight), "appearance top zh-Hans light non-flat")
        savePNG(topZhLight, name: "appearance-top-zh-Hans-light.png")

        let diagTopBtns = collectButtonsDiag(in: window!)
        print("APPEARANCE_MENU_UIKIT_INSPECT top_btns=\(diagTopBtns.count) sample=\(diagTopBtns.prefix(6).joined(separator: ";"))")

        scrollToOffsetY(560) { self.phase2_midZhLight() }
    }

    func phase2_midZhLight() {
        midZhLight = snapshotWindow()
        check(nonFlat(midZhLight), "appearance mid zh-Hans light non-flat")
        check(topZhLight.pngData() != midZhLight.pngData(), "top and mid AppearanceSettingsView snapshots differ")
        savePNG(midZhLight, name: "appearance-mid-zh-Hans-light.png")

        let diagMidBtns = collectButtonsDiag(in: window!)
        print("APPEARANCE_MENU_UIKIT_INSPECT mid_btns=\(diagMidBtns.count) sample=\(diagMidBtns.prefix(4).joined(separator: ";"))")

        let hasScroll = findScrollView(in: window!) != nil
        check(hasScroll, "AppearanceSettingsView scrollable list found")
        scrollToTrueBottom { self.phase3_bottomZhLight() }
    }

    func phase3_bottomZhLight() {
        bottomZhLight = snapshotWindow()
        check(nonFlat(bottomZhLight), "appearance bottom zh-Hans light non-flat")
        check(midZhLight.pngData() != bottomZhLight.pngData(), "mid and bottom AppearanceSettingsView snapshots differ")
        savePNG(bottomZhLight, name: "appearance-bottom-zh-Hans-light.png")
        check(hasSaturatedBluePixels(bottomZhLight), "SteppedSlider retains blue accent in AppearanceSettingsView (local picker tint does not wash out slider)")

        probe.commandSubject.send(.push(.appearanceAppIcon))
        after(0.95) { self.phase4_appIcon() }
    }

    func phase4_appIcon() {
        check(probe.navCount == 2, "pushed to AppIconSettingsView (navCount=2)")
        let appIconImg = snapshotWindow()
        check(nonFlat(appIconImg), "AppIconSettingsView zh-Hans light non-flat")
        check(hasSaturatedBluePixels(appIconImg), "AppIconSettingsView retains blue checkmark")
        savePNG(appIconImg, name: "secondary-appicon-zh-Hans-light.png")

        UserDefaults.standard.set(4, forKey: "appIconMode")
        after(0.25) {
            self.probe.commandSubject.send(.pop)
            self.after(0.95) {
                self.scrollToTrueBottom { self.phase5_afterIconPop() }
            }
        }
    }

    func phase5_afterIconPop() {
        check(probe.navCount == 1, "popped back from AppIconSettingsView to AppearanceSettingsView")
        let afterIconPopImg = snapshotWindow()
        check(afterIconPopImg.pngData() != bottomZhLight.pngData(), "AppearanceSettingsView bottom reflects updated App Icon summary (Automatic -> Dark Legacy)")
        UserDefaults.standard.set(0, forKey: "appIconMode")

        after(0.2) {
            self.probe.commandSubject.send(.push(.appearanceLanguage))
            self.after(0.95) { self.phase6_languageView() }
        }
    }

    func phase6_languageView() {
        check(probe.navCount == 2, "pushed to LanguageSettingsView (navCount=2)")
        let langImg = snapshotWindow()
        check(nonFlat(langImg), "LanguageSettingsView zh-Hans light non-flat")
        check(hasSaturatedBluePixels(langImg), "LanguageSettingsView retains blue checkmark")
        savePNG(langImg, name: "secondary-language-zh-Hans-light.png")

        probe.simulatedSystemLocaleId = "en"
        UserDefaults.standard.set(2, forKey: "appearanceMode")
        window?.overrideUserInterfaceStyle = .dark
        Bundle.setLanguage("en")
        UserDefaults.standard.set("en", forKey: "appLanguage")
        after(0.85) {
            self.probe.commandSubject.send(.reset)
            self.after(0.25) {
                self.probe.commandSubject.send(.push(.appearance))
                self.after(0.95) { self.phase7_topEnDark() }
            }
        }
    }

    func phase7_topEnDark() {
        topEnDark = snapshotWindow()
        check(nonFlat(topEnDark), "appearance top en dark non-flat")
        savePNG(topEnDark, name: "appearance-top-en-dark.png")
        scrollToTrueBottom { self.phase8_bottomEnDark() }
    }

    func phase8_bottomEnDark() {
        let bottomEnDark = snapshotWindow()
        check(nonFlat(bottomEnDark), "appearance bottom en dark non-flat")
        check(topEnDark.pngData() != bottomEnDark.pngData(), "top and bottom en dark snapshots differ")
        savePNG(bottomEnDark, name: "appearance-bottom-en-dark.png")

        UserDefaults.standard.set(1, forKey: "appearanceMode")
        window?.overrideUserInterfaceStyle = .light
        probe.autoOpenSettingsOnMount = false
        prevSuspend = ViewModelCache.shared.suspendCount
        prevContentMounts = probe.contentMountCount
        prevSheetMounts = probe.sheetMountCount

        UserDefaults.standard.set("appearance-language", forKey: "pendingSettingsReopen")
        ViewModelCache.shared.suspendAllForTreeRemount()
        UserDefaults.standard.set("zh-Hans", forKey: "appLanguage")
        Bundle.setLanguage("zh-Hans")

        waitForRemount(attemptsLeft: 25) { self.phase9_afterRemount() }
    }

    func waitForRemount(attemptsLeft: Int, then block: @escaping () -> Void) {
        if (probe.contentMountCount > prevContentMounts &&
            probe.sheetMountCount > prevSheetMounts &&
            probe.navCount == 2 &&
            UserDefaults.standard.string(forKey: "pendingSettingsReopen") == nil) || attemptsLeft <= 0 {
            after(1.0, block)
            return
        }
        after(0.15) {
            self.waitForRemount(attemptsLeft: attemptsLeft - 1, then: block)
        }
    }

    func phase9_afterRemount() {
        check(ViewModelCache.shared.suspendCount == prevSuspend + 1, "ViewModelCache.suspendAllForTreeRemount called once on remount")
        check(ViewModelCache.shared.events.last == "suspend(pending=appearance-language,appLang=en)",
              "suspendAllForTreeRemount ran AFTER writing pendingSettingsReopen and BEFORE appLanguage changed: \(ViewModelCache.shared.events.last ?? "nil")")
        check(probe.contentMountCount > prevContentMounts, "Root .id(appLanguage) forced ContentReproView remount")
        check(probe.sheetMountCount > prevSheetMounts, "SettingsSheetHarness remounted after language change")
        check(probe.lastConsumedReopen == "appearance-language", "SettingsSheet consumed pendingSettingsReopen=appearance-language")
        check(UserDefaults.standard.string(forKey: "pendingSettingsReopen") == nil, "pendingSettingsReopen cleared after consumption")
        check(probe.navCount == 2, "SettingsSheet restored 2-level stack [.appearance, .appearanceLanguage]")
        check(AppLocalized("Language") == "语言", "AppLocalized reflects zh-Hans after remount")

        let restoredLangImg = snapshotWindow()
        check(nonFlat(restoredLangImg), "restored LanguageSettingsView zh-Hans non-flat")
        savePNG(restoredLangImg, name: "remount-restored-language-zh-Hans.png")

        probe.commandSubject.send(.pop)
        after(0.95) {
            self.scrollToTrueBottom { self.phase10_afterRemountPop() }
        }
    }

    func phase10_afterRemountPop() {
        check(probe.navCount == 1, "popping restored LanguageSettingsView lands on AppearanceSettingsView (navCount=1)")
        let backAppearanceImg = snapshotWindow()
        check(nonFlat(backAppearanceImg), "AppearanceSettingsView after pop non-flat")
        check(backAppearanceImg.pngData() != bottomZhLight.pngData(), "AppearanceSettingsView shows updated Language summary (简体中文 vs 跟随系统)")
        savePNG(backAppearanceImg, name: "remount-back-appearance-zh-Hans.png")

        let mountsBeforeLegacy = probe.sheetMountCount
        UserDefaults.standard.set("appearance", forKey: "pendingSettingsReopen")
        UserDefaults.standard.set("zh-Hant", forKey: "appLanguage")
        Bundle.setLanguage("zh-Hant")

        waitForLegacyRemount(mountsBefore: mountsBeforeLegacy, attemptsLeft: 25)
    }

    func waitForLegacyRemount(mountsBefore: Int, attemptsLeft: Int) {
        if (probe.sheetMountCount > mountsBefore &&
            probe.navCount == 1 &&
            UserDefaults.standard.string(forKey: "pendingSettingsReopen") == nil) || attemptsLeft <= 0 {
            after(0.45) { self.phase11_legacyAndFinish() }
            return
        }
        after(0.15) {
            self.waitForLegacyRemount(mountsBefore: mountsBefore, attemptsLeft: attemptsLeft - 1)
        }
    }

    func phase11_legacyAndFinish() {
        check(probe.lastConsumedReopen == "appearance", "legacy appearance reopen consumed")
        check(probe.navCount == 1, "legacy appearance reopen restores 1-level stack")
        check(AppLocalized("Return Key") == "回車鍵", "AppLocalized reflects zh-Hant")

        let summary = failures.isEmpty
            ? "APPEARANCE_SECONDARY_PASS checks=\(checks) png=\(pngCount)"
            : "APPEARANCE_SECONDARY_FAIL failures=\(failures.count) checks=\(checks)"
        try? summary.write(to: outDir.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(summary)
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
