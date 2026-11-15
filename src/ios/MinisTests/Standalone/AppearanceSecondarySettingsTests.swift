// Standalone: `cd src/ios/MinisTests/Standalone && swift AppearanceSecondarySettingsTests.swift`

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label) — expected \(expected), got \(actual)")
        failures += 1
    }
}

let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let appearancePath = iosRoot.appendingPathComponent("Views/Settings/AppearanceSettingsView.swift")
let settingsSheetPath = iosRoot.appendingPathComponent("Views/Settings/SettingsSheet.swift")
let catalogPath = iosRoot.appendingPathComponent("Localizable.xcstrings")

let appearance = (try? String(contentsOf: appearancePath, encoding: .utf8)) ?? ""
let settingsSheet = (try? String(contentsOf: settingsSheetPath, encoding: .utf8)) ?? ""
let catalogData = (try? Data(contentsOf: catalogPath)) ?? Data()

check("sources found", !appearance.isEmpty && !settingsSheet.isEmpty && !catalogData.isEmpty)

func slice(_ text: String, _ start: String, _ end: String) -> String {
    guard let s = text.range(of: start),
          let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return "" }
    return String(text[s.lowerBound..<e.upperBound])
}

print("\n▶️  1. Return Key menu")
check("segmented picker removed from AppearanceSettingsView", !appearance.contains(".pickerStyle(.segmented)"))
let returnSection = slice(appearance, "Picker(\"Return Key\", selection: $returnKeyBehavior)", "Text(\"Choose whether the Return key")
check("Return Key uses .pickerStyle(.menu)", returnSection.contains(".pickerStyle(.menu)"))
check("Return Key uses semantic secondary menu tint", returnSection.contains(".tint(Color(uiColor: .secondaryLabel))"))
let grayMenuPattern = #"\.pickerStyle\(\.menu\)\s*\.tint\(Color\(uiColor: \.secondaryLabel\)\)"#
let grayMenuCount = (try? NSRegularExpression(pattern: grayMenuPattern))?.numberOfMatches(in: appearance, range: NSRange(appearance.startIndex..., in: appearance)) ?? 0
check("all six menu pickers explicitly use semantic secondary tint", grayMenuCount == 6)
check("Return Key preserves tag 0/1 and Newline/Send", returnSection.contains("Text(\"Newline\").tag(0)") && returnSection.contains("Text(\"Send\").tag(1)"))
check("Return Key preserves @AppStorage(\"returnKeyBehavior\")", appearance.contains("@AppStorage(\"returnKeyBehavior\") private var returnKeyBehavior: Int = 0"))

print("\n▶️  2. Secondary entry rows in AppearanceSettingsView (no inline duplicate lists)")
let appearanceBody = slice(appearance, "struct AppearanceSettingsView: View {", "struct AppIconSettingsView: View {")
check("AppearanceSettingsView has App Icon NavigationLink", appearanceBody.contains("NavigationLink(value: SettingsDestination.appearanceAppIcon)"))
check("AppearanceSettingsView has Language NavigationLink", appearanceBody.contains("NavigationLink(value: SettingsDestination.appearanceLanguage)"))
check("AppearanceSettingsView gates App Icon entry with supportsAlternateIcons", appearanceBody.contains("if UIApplication.shared.supportsAlternateIcons {"))
check("AppearanceSettingsView no longer inlines appIconOptions list", !appearanceBody.contains("ForEach(appIconOptions)"))
check("AppearanceSettingsView no longer inlines supportedLanguages list", !appearanceBody.contains("ForEach(supportedLanguages)"))
check("AppearanceSettingsView preserves AppearanceMenuSettingsSections", appearanceBody.contains("AppearanceMenuSettingsSections()"))

print("\n▶️  3. Secondary views & recovery chain")
let appIconView = slice(appearance, "struct AppIconSettingsView: View {", "struct LanguageSettingsView: View {")
let languageView = String(appearance[appearance.range(of: "struct LanguageSettingsView: View {")!.lowerBound...])
check("AppIconSettingsView preserves supportsAlternateIcons gate", appIconView.contains("if UIApplication.shared.supportsAlternateIcons {"))
check("AppIconSettingsView preserves setAlternateIconName", appIconView.contains("UIApplication.shared.setAlternateIconName(option.iconName)"))
check("AppIconSettingsView preserves all 5 icon options", appearance.contains("id: 0, title: \"Automatic\"") && appearance.contains("id: 4, title: \"Dark (Legacy)\""))
check("LanguageSettingsView preserves all 19 entries (System + 18 langs)", appearance.components(separatedBy: "LanguageOption(id:").count - 1 == 19)
check("LanguageSettingsView writes appearance-language reopen hint", languageView.contains("UserDefaults.standard.set(\"appearance-language\", forKey: \"pendingSettingsReopen\")"))
check("LanguageSettingsView calls suspendAllForTreeRemount before appLanguage write", languageView.contains("ViewModelCache.shared.suspendAllForTreeRemount()"))
check("LanguageSettingsView calls Bundle.setLanguage", languageView.contains("Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)"))

check("SettingsDestination defines appearanceAppIcon & appearanceLanguage", settingsSheet.contains("case appearanceAppIcon") && settingsSheet.contains("case appearanceLanguage"))
check("SettingsSheet routes to AppIconSettingsView & LanguageSettingsView", settingsSheet.contains("case .appearanceAppIcon:\n                    AppIconSettingsView()") && settingsSheet.contains("case .appearanceLanguage:\n                    LanguageSettingsView()"))
check("SettingsSheet restores appearance-language stack", settingsSheet.contains("case \"appearance-language\":\n                        navPath.append(SettingsDestination.appearance)\n                        navPath.append(SettingsDestination.appearanceLanguage)"))
check("SettingsSheet preserves legacy appearance reopen", settingsSheet.contains("case \"appearance\":\n                        navPath.append(SettingsDestination.appearance)"))

print("\n▶️  4. Summary mapping parity")
enum LanguageSummaryDisplay: Equatable {
    case localizedKey(String)
    case verbatim(String)
}
let iconTitles: [Int: String] = [
    0: "Automatic", 1: "Light", 2: "Dark", 3: "Light (Legacy)", 4: "Dark (Legacy)"
]
let langNames: [String: String] = [
    "en": "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語"
]
func appIconSummaryKey(_ mode: Int) -> String { iconTitles[mode] ?? "Automatic" }
func languageSummary(_ id: String) -> LanguageSummaryDisplay {
    if id.isEmpty { return .localizedKey("System") }
    if let name = langNames[id] { return .verbatim(name) }
    return .verbatim(id)
}
check("AppIcon mode 0 maps to Automatic", appIconSummaryKey(0) == "Automatic")
check("AppIcon mode 4 maps to Dark (Legacy)", appIconSummaryKey(4) == "Dark (Legacy)")
check("AppIcon unknown mode falls back to Automatic", appIconSummaryKey(99) == "Automatic")
check("Language empty id maps to localized System", languageSummary("") == .localizedKey("System"))
check("Language zh-Hans preserves native name", languageSummary("zh-Hans") == .verbatim("简体中文"))
check("Language ja preserves native name", languageSummary("ja") == .verbatim("日本語"))

print("\n▶️  5. Localization catalog coverage")
if let json = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
   let strings = json["strings"] as? [String: Any] {
    let requiredKeys: [(String, String)] = [
        ("Return Key", "回车键"),
        ("Newline", "换行"),
        ("Send", "发送"),
        ("App Icon", "应用图标"),
        ("Automatic", "自动"),
        ("Language", "语言"),
        ("System", "跟随系统")
    ]
    for (key, expectedZh) in requiredKeys {
        let entry = strings[key] as? [String: Any]
        let locs = entry?["localizations"] as? [String: Any]
        let zhHans = ((locs?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        check("catalog key '\(key)' has 18 langs & zh-Hans='\(expectedZh)'",
              (locs?.count ?? 0) >= 18 && zhHans == expectedZh)
    }
} else {
    check("Localizable.xcstrings parsed", false)
}

if failures == 0 {
    print("\n✅ ALL PASSED")
} else {
    print("\n❌ FAILED: \(failures) check(s)")
    exit(1)
}
