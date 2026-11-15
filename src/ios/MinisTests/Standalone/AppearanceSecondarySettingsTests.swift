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
let contentViewPath = iosRoot.appendingPathComponent("Views/ContentView/ContentView.swift")
let minisAppPath = iosRoot.appendingPathComponent("MinisApp.swift")
let catalogPath = iosRoot.appendingPathComponent("Localizable.xcstrings")

let appearance = (try? String(contentsOf: appearancePath, encoding: .utf8)) ?? ""
let settingsSheet = (try? String(contentsOf: settingsSheetPath, encoding: .utf8)) ?? ""
let contentView = (try? String(contentsOf: contentViewPath, encoding: .utf8)) ?? ""
let minisApp = (try? String(contentsOf: minisAppPath, encoding: .utf8)) ?? ""
let catalogData = (try? Data(contentsOf: catalogPath)) ?? Data()

check("sources found", !appearance.isEmpty && !settingsSheet.isEmpty && !contentView.isEmpty && !minisApp.isEmpty && !catalogData.isEmpty)

func slice(_ text: String, _ start: String, _ end: String) -> String {
    guard let s = text.range(of: start),
          let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return "" }
    return String(text[s.lowerBound..<e.upperBound])
}

let secondaryTint = ".tint(Color(uiColor: .secondaryLabel))"
let userDefaultsToken = "UserDefaults" + ".standard"

print("\n▶️  1. Return Key menu & local semantic tint isolation")
check("segmented picker removed from AppearanceSettingsView", !appearance.contains(".pickerStyle(.segmented)"))
let returnSection = slice(appearance, "Picker(\"Return Key\", selection: $returnKeyBehavior)", "Text(\"Choose whether the Return key")
check("Return Key uses .pickerStyle(.menu)", returnSection.contains(".pickerStyle(.menu)"))
check("Return Key uses semantic secondary menu tint", returnSection.contains(secondaryTint))
check("Return Key keeps section header", slice(appearance, "Picker(\"Return Key\"", "footer: {").contains("header: {\n                Text(\"Return Key\")") || slice(appearance, "Picker(\"Return Key\"", "Text(\"Choose whether the Return key").contains("header: {\n                Text(\"Return Key\")"))
check("Return Key keeps footer", appearance.contains("Text(\"Choose whether the Return key in the chat input inserts a newline or sends the message. Hardware Shift+Return always inserts a newline.\")"))
check("Return Key preserves tag 0/1 and Newline/Send", returnSection.contains("Text(\"Newline\").tag(0)") && returnSection.contains("Text(\"Send\").tag(1)"))
check("Return Key preserves @AppStorage(\"returnKeyBehavior\")", appearance.contains("@AppStorage(\"returnKeyBehavior\") private var returnKeyBehavior: Int = 0"))

let grayMenuPattern = #"\.pickerStyle\(\.menu\)\s*\.tint\(Color\(uiColor: \.secondaryLabel\)\)"#
let grayMenuCount = (try? NSRegularExpression(pattern: grayMenuPattern))?.numberOfMatches(in: appearance, range: NSRange(appearance.startIndex..., in: appearance)) ?? 0
check("all six menu pickers explicitly use semantic secondary tint", grayMenuCount == 6)

let totalTintCount = appearance.components(separatedBy: secondaryTint).count - 1
check("no extra container/whole-page secondaryLabel tint beyond the 6 pickers", totalTintCount == 6)
let sectionsBlock = slice(appearance, "struct AppearanceMenuSettingsSections: View {", "// MARK: - End AppearanceMenuSettingsSections")
check("MUChartSettingsPreview has no secondaryLabel tint modifier", !sectionsBlock.contains("MUChartSettingsPreview()\n                .tint"))
check("SteppedSlider keeps Color.accentColor", appearance.contains(".fill(Color.accentColor)"))
let launchSection = slice(appearance, "Picker(\"Launch Session\", selection: $launchScreen)", "Text(\"Choose what to show when the app starts.")
check("Launch Session picker remains untouched by secondaryLabel tint", !launchSection.isEmpty && !launchSection.contains(secondaryTint))

print("\n▶️  2. Secondary entry rows in AppearanceSettingsView (no inline duplicate lists)")
let appearanceBody = slice(appearance, "struct AppearanceSettingsView: View {", "struct AppIconSettingsView: View {")
let secondaryEntrySection = slice(appearanceBody, "Section {\n                if UIApplication.shared.supportsAlternateIcons {", "        }\n        .navigationTitle(\"Appearance\")")
check("App Icon and Language live in one headerless Section", !secondaryEntrySection.isEmpty && !secondaryEntrySection.contains("header:"))
check("AppearanceSettingsView has App Icon NavigationLink", secondaryEntrySection.contains("NavigationLink(value: SettingsDestination.appearanceAppIcon)"))
check("AppearanceSettingsView has Language NavigationLink", secondaryEntrySection.contains("NavigationLink(value: SettingsDestination.appearanceLanguage)"))
check("AppearanceSettingsView gates App Icon entry with supportsAlternateIcons", secondaryEntrySection.contains("if UIApplication.shared.supportsAlternateIcons {"))
check("App Icon summary uses LocalizedStringKey(Self.appIconSummaryKey(for: appIconMode))", secondaryEntrySection.contains("Text(LocalizedStringKey(Self.appIconSummaryKey(for: appIconMode)))"))
check("Language summary uses languageSummaryView with secondary foregroundStyle", secondaryEntrySection.contains("languageSummaryView\n                            .foregroundStyle(.secondary)"))
check("AppearanceSettingsView no longer inlines appIconOptions list", !appearanceBody.contains("ForEach(appIconOptions)"))
check("AppearanceSettingsView no longer inlines supportedLanguages list", !appearanceBody.contains("ForEach(supportedLanguages)"))
check("AppearanceSettingsView preserves AppearanceMenuSettingsSections", appearanceBody.contains("AppearanceMenuSettingsSections()"))

print("\n▶️  3. Secondary views & recovery chain")
let appIconView = slice(appearance, "struct AppIconSettingsView: View {", "struct LanguageSettingsView: View {")
let languageView = String(appearance[appearance.range(of: "struct LanguageSettingsView: View {")!.lowerBound...])
check("AppIconSettingsView preserves supportsAlternateIcons gate", appIconView.contains("if UIApplication.shared.supportsAlternateIcons {"))
check("AppIconSettingsView preserves setAlternateIconName", appIconView.contains("UIApplication.shared.setAlternateIconName(option.iconName)"))
check("AppIconSettingsView keeps blue checkmark", appIconView.contains(".foregroundStyle(.blue)"))
let iconCount = appearance.components(separatedBy: "AppIconOption(id:").count - 1
check("AppIconSettingsView preserves all 5 icon options", iconCount == 5 && appearance.contains("id: 0, title: \"Automatic\"") && appearance.contains("id: 4, title: \"Dark (Legacy)\""))
check("LanguageSettingsView preserves all 19 entries (System + 18 langs)", appearance.components(separatedBy: "LanguageOption(id:").count - 1 == 19)
check("LanguageSettingsView keeps blue checkmark", languageView.contains(".foregroundStyle(.blue)"))

let reopenCall = "\(userDefaultsToken).set(\"appearance-language\", forKey: \"pendingSettingsReopen\")"
let suspendCall = "ViewModelCache.shared.suspendAllForTreeRemount()"
let writeLangCall = "appLanguage = lang.id"
let bundleCall = "Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)"
check("LanguageSettingsView writes appearance-language reopen hint", languageView.contains(reopenCall))
check("LanguageSettingsView calls suspendAllForTreeRemount", languageView.contains(suspendCall))
check("LanguageSettingsView calls Bundle.setLanguage", languageView.contains(bundleCall))
if let rReopen = languageView.range(of: reopenCall),
   let rSuspend = languageView.range(of: suspendCall),
   let rWrite = languageView.range(of: writeLangCall),
   let rBundle = languageView.range(of: bundleCall) {
    check("LanguageSettingsView executes reopen -> suspend -> appLanguage write -> Bundle.setLanguage in exact order",
          rReopen.lowerBound < rSuspend.lowerBound && rSuspend.lowerBound < rWrite.lowerBound && rWrite.lowerBound < rBundle.lowerBound)
} else {
    check("LanguageSettingsView executes reopen -> suspend -> appLanguage write -> Bundle.setLanguage in exact order", false)
}

check("SettingsSheet uses value-based Appearance NavigationLink", settingsSheet.contains("NavigationLink(value: SettingsDestination.appearance)"))
check("SettingsDestination defines appearanceAppIcon & appearanceLanguage", settingsSheet.contains("case appearanceAppIcon") && settingsSheet.contains("case appearanceLanguage"))
check("SettingsSheet routes to AppIconSettingsView & LanguageSettingsView", settingsSheet.contains("case .appearanceAppIcon:\n                    AppIconSettingsView()") && settingsSheet.contains("case .appearanceLanguage:\n                    LanguageSettingsView()"))
check("SettingsSheet restores appearance-language stack", settingsSheet.contains("case \"appearance-language\":\n                        navPath.append(SettingsDestination.appearance)\n                        navPath.append(SettingsDestination.appearanceLanguage)"))
check("SettingsSheet preserves legacy appearance reopen", settingsSheet.contains("case \"appearance\":\n                        navPath.append(SettingsDestination.appearance)"))
check("ContentView reopens settings sheet on non-nil pendingSettingsReopen", contentView.contains("\(userDefaultsToken).string(forKey: \"pendingSettingsReopen\") != nil") && contentView.contains("activeToolSheet = .settings"))
check("MinisApp re-keys root on appLanguage and binds locale", minisApp.contains(".id(appLanguage)") && minisApp.contains(".environment(\\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))"))

print("\n▶️  4. Production array parsing & summary mapping parity")
let iconRegex = try! NSRegularExpression(pattern: #"AppIconOption\(id:\s*(\d+),\s*title:\s*"([^"]+)""#)
var parsedIconTitles: [Int: String] = [:]
for m in iconRegex.matches(in: appearance, range: NSRange(appearance.startIndex..., in: appearance)) {
    if let r1 = Range(m.range(at: 1), in: appearance),
       let r2 = Range(m.range(at: 2), in: appearance),
       let id = Int(appearance[r1]) {
        parsedIconTitles[id] = String(appearance[r2])
    }
}
check("parsed all 5 icon titles from production source", parsedIconTitles.count == 5 && parsedIconTitles[0] == "Automatic" && parsedIconTitles[4] == "Dark (Legacy)")

let langRegex = try! NSRegularExpression(pattern: #"LanguageOption\(id:\s*"([^"]*)",\s*name:\s*"([^"]+)""#)
var parsedLangNames: [String: String] = [:]
for m in langRegex.matches(in: appearance, range: NSRange(appearance.startIndex..., in: appearance)) {
    if let r1 = Range(m.range(at: 1), in: appearance),
       let r2 = Range(m.range(at: 2), in: appearance) {
        parsedLangNames[String(appearance[r1])] = String(appearance[r2])
    }
}
check("parsed all 19 language entries from production source", parsedLangNames.count == 19 && parsedLangNames[""] == "System" && parsedLangNames["zh-Hans"] == "简体中文" && parsedLangNames["zh-Hant"] == "繁體中文" && parsedLangNames["ja"] == "日本語" && parsedLangNames["pt-BR"] == "Português (Brasil)")

print("\n▶️  5. Localization catalog coverage (20 keys x 18 languages)")
let required18Langs: Set<String> = [
    "de", "en", "es", "fil", "fr", "hr", "id", "ja", "ko",
    "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"
]
if let json = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
   let strings = json["strings"] as? [String: Any] {
    let requiredKeys: [(String, String?)] = [
        ("Appearance", "外观"),
        ("Return Key", "回车键"),
        ("Newline", "换行"),
        ("Send", "发送"),
        ("Choose whether the Return key in the chat input inserts a newline or sends the message. Hardware Shift+Return always inserts a newline.", nil),
        ("App Icon", "应用图标"),
        ("Automatic", "自动"),
        ("Follows system", "跟随系统"),
        ("Light", "浅色"),
        ("Always light", nil),
        ("Dark", "深色"),
        ("Always dark", nil),
        ("Light (Legacy)", nil),
        ("Classic light icon", nil),
        ("Dark (Legacy)", nil),
        ("Classic dark icon", nil),
        ("\"Automatic\" uses the system icon which adapts to Dark Mode on iOS 18+.", nil),
        ("Language", "语言"),
        ("System", "跟随系统"),
        ("Override the display language for this app. \"System\" follows your device language.", nil)
    ]
    for (key, expectedZh) in requiredKeys {
        let entry = strings[key] as? [String: Any]
        let locs = entry?["localizations"] as? [String: Any] ?? [:]
        let presentLangs = Set(locs.keys)
        let allNonEmpty = required18Langs.allSatisfy { lang in
            let val = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            return !val.isEmpty
        }
        let zhHans = ((locs["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        let zhOk = expectedZh == nil || zhHans == expectedZh
        check("catalog key '\(key.prefix(40))' covers 18 langs & non-empty", required18Langs.isSubset(of: presentLangs) && allNonEmpty && zhOk)
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
