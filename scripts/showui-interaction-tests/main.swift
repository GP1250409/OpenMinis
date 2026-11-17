// [T-showui-interaction-theme] Pure Foundation checks: no SwiftUI, no UIKit.
// Compiled by scripts/showui_interaction_regression.py against the production
// MinisUICore.swift / MinisUIMapCore.swift slice, so the numbers below are the
// numbers the app draws with — not a re-implementation.
import Foundation

var passed = 0
var failed: [String] = []
func check(_ ok: Bool, _ label: String) { if ok { passed += 1 } else { failed.append(label) } }
func contrast(_ a: MUMapRGB, _ b: MUMapRGB) -> Double { a.contrast(on: b) }

// MARK: - 1. Text roles: 14 / 12 / 10.5, backward compatible
check(MUTextRole.body.size == 14, "body = 14pt")
check(MUTextRole.note.size == 12, "note = 12pt")
check(MUTextRole.source.size == 10.5, "source = 10.5pt")
check(MUTextRole.source.size == MUChartTypography.source, "source shares the MultiChart source size")
check(MUTextRole.names == ["body", "note", "source"], "three role names for the schema")
check(MUTextStyle.style(role: nil, size: nil, tone: nil, text: "普通正文").size == 14,
      "no role -> 14pt")
check(MUTextStyle.style(role: "body", size: nil, tone: nil, text: "x").size == 14, "role body -> 14")
check(MUTextStyle.style(role: "NOTE", size: nil, tone: nil, text: "x").size == 12, "role lookup is case-insensitive")
check(MUTextStyle.style(role: "source", size: nil, tone: nil, text: "x").size == 10.5, "role source -> 10.5")
check(MUTextStyle.style(role: nil, size: 17, tone: nil, text: "x").size == 17, "explicit size honoured")
check(MUTextStyle.style(role: nil, size: 99, tone: nil, text: "x").size == 20, "explicit size clamped high")
check(MUTextStyle.style(role: nil, size: 1, tone: nil, text: "x").size == 10.5, "explicit size clamped low")
check(MUTextStyle.style(role: "nonsense", size: nil, tone: nil, text: "x").size == 14,
      "an unknown role falls back to body, never to a tiny size")
for prefix in ["数据：", "数据:", "来源：", "来源:", "source:", "sources:"] {
    check(MUTextStyle.style(role: nil, size: nil, tone: "secondary", text: prefix + "统计局").size == 10.5,
          "legacy prefix \(prefix) -> 10.5")
}
check(MUTextStyle.style(role: nil, size: nil, tone: "secondary", text: "  来源：统计局").size == 10.5,
      "legacy prefix after whitespace -> 10.5")
check(MUTextStyle.style(role: nil, size: nil, tone: "secondary", text: "以上数据来自统计局").size == 14,
      "a mention inside a sentence is not a source")
check(MUTextStyle.style(role: nil, size: nil, tone: "secondary", text: "来源数据说明").size == 14,
      "a prefix without the colon is not a source")
check(MUTextStyle.style(role: nil, size: nil, tone: "primary", text: "来源：统计局").size == 14,
      "the legacy rule needs tone=secondary")
check(MUTextStyle.style(role: "body", size: nil, tone: "secondary", text: "来源：统计局").size == 14,
      "an explicit role wins over the legacy rule")
check(MUTextStyle(role: .body, size: 14).lineHeight == 20, "14pt line box = 20")
check(MUTextStyle(role: .note, size: 12).lineHeight == 17, "12pt line box = 17")
check(MUTextStyle(role: .source, size: 10.5).lineHeight == 15, "10.5pt line box = 15")

// MARK: - 2. Palette presets: exact v2 values, day and night separate
let presets: [(String, MUChartInteriorPalette)] = [("", .system), ("economist", .economist),
                                                   ("economist2017", .economist2017)]
for (key, preset) in presets {
    for dark in [false, true] {
        let t = MUChartInteractionTheme.interior(key, dark: dark)
        let slot = dark ? "night" : "day"
        check(t.panel == preset.panel.rgb(forDarkSurface: dark), "\(key) \(slot): panel token")
        check(t.note == preset.note.rgb(forDarkSurface: dark), "\(key) \(slot): note token")
        check(t.ink == preset.ink.rgb(forDarkSurface: dark), "\(key) \(slot): ink token")
        check(t.muted == preset.muted.rgb(forDarkSurface: dark), "\(key) \(slot): muted token")
        check(t.rule == preset.rule.rgb(forDarkSurface: dark), "\(key) \(slot): rule token")
        check(t.series == preset.series.rgb(forDarkSurface: dark), "\(key) \(slot): series token")
        check(t.isDark == dark, "\(key) \(slot): scheme flag")
        check(contrast(t.ink, t.panel) >= 4.5, "\(key) \(slot): ink >= 4.5 on panel")
        check(contrast(t.muted, t.panel) >= 4.5, "\(key) \(slot): muted >= 4.5 on panel")
        check(contrast(t.ink, t.note) >= 4.5, "\(key) \(slot): ink >= 4.5 on note")
        check(contrast(t.series, t.panel) >= 3.0, "\(key) \(slot): series >= 3 on panel")
        check(contrast(t.rule, t.panel) > 1.05, "\(key) \(slot): hairline visible")
    }
}
check(MUChartInteriorPalette.preset("nonsense") == .system, "unknown preset -> system, like the chart")
check(MUChartInteriorPalette.preset("") == .system, "empty preset -> system")
check(MUChartInteriorPalette.preset("economist") != .system, "economist is its own preset")
check(MUChartInteriorPalette.preset("economist2017") != .economist, "2017 is its own preset")

// MARK: - 3. Callout: info neutral and barless, status semantic
let tones = ["info", "warning", "danger", "success"]
check(MUChartInteractionTheme.isStatus("warning"), "warning is a status tone")
check(MUChartInteractionTheme.isStatus("danger") && MUChartInteractionTheme.isStatus("error"), "danger/error")
check(MUChartInteractionTheme.isStatus("success") && MUChartInteractionTheme.isStatus("ok"), "success/ok")
check(!MUChartInteractionTheme.isStatus("info") && !MUChartInteractionTheme.isStatus("whatever"),
      "info/unknown are not status tones")
for (key, _) in presets {
    for dark in [false, true] {
        let t = MUChartInteractionTheme.interior(key, dark: dark)
        let info = MUChartInteractionTheme.resolved(tone: "info", dark: dark, palette: key)
        check(info.isNeutral, "\(key): info is neutral")
        check(info.fill == t.note, "\(key): info ground = palette note")
        check(info.border == t.rule, "\(key): info hairline = palette rule")
        check(info.text == t.ink, "\(key): info text = palette ink")
        check(info.accent == t.muted.readable(on: t.note, minimum: 3.0), "\(key): info icon = palette muted")
        var fills: [String] = []
        for tone in tones {
            let box = MUChartInteractionTheme.resolved(tone: tone, dark: dark, palette: key)
            fills.append(box.fill.hex)
            check(box.text == t.ink, "\(key)/\(tone): body text is the palette ink (not forced white/black)")
            check(contrast(box.text, box.fill) >= 4.5, "\(key)/\(tone): text >= 4.5")
            check(contrast(box.accent, box.fill) >= 3.0, "\(key)/\(tone): icon >= 3")
            check(contrast(box.muted, box.fill) >= 4.5, "\(key)/\(tone): muted >= 4.5")
            check(box.text != MUMapRGB(hex: "#FFFFFF") && box.text != MUMapRGB(hex: "#000000"),
                  "\(key)/\(tone): text is not pure white/black")
            if tone != "info" {
                check(!box.isNeutral, "\(key)/\(tone): keeps semantics")
                check(contrast(box.fill, t.note) < contrast(box.fill, MUChartInteractionTheme.accent(tone).rgb(forDarkSurface: dark)),
                      "\(key)/\(tone): wash stays bounded")
            }
        }
        check(Set(fills).count == tones.count, "\(key) \(dark ? "night" : "day"): four distinct grounds")
    }
}
check(MUChartInteractionTheme.resolved(tone: "info", dark: false, palette: "") !=
      MUChartInteractionTheme.resolved(tone: "info", dark: true, palette: ""), "day/night differ")
check(MUChartInteractionTheme.resolved(tone: "info", dark: false, palette: "economist") !=
      MUChartInteractionTheme.resolved(tone: "info", dark: false, palette: "economist2017"),
      "presets differ in the interior")

// MARK: - 4. Action text: measured on the real fill, never pure white
let chatTints = ["#3686EE", "#5490E4", "#0D0D0D", "#ECECEC", "#D97757", "#4D6BFE"].map { MUMapRGB(hex: $0) }
for fill in chatTints {
    let glyph = MUActionText.on(fill)
    check(contrast(glyph, fill) >= 4.5, "label >= 4.5 on \(fill.hex)")
    check(glyph != MUMapRGB(hex: "#FFFFFF"), "label is never pure white on \(fill.hex)")
}
check(MUActionText.on(MUMapRGB(hex: "#0D0D0D")) == MUActionText.soft, "dark fill -> soft light")
check(MUActionText.on(MUMapRGB(hex: "#ECECEC")) == MUActionText.deep, "light fill -> near black")
check(MUActionText.soft == MUMapRGB(hex: "#E4E6EB") && MUActionText.deep == MUMapRGB(hex: "#080808"),
      "the demo v2 action text values")
for fill in chatTints {
    for surface in ["#F7F7F8", "#1C1C1E", "#30302E", "#F0EEE6"].map({ MUMapRGB(hex: $0) }) {
        let wash = fill.composited(over: surface, alpha: 0.12)
        let ink = MUActionText.secondaryInk(tint: fill, wash: wash)
        check(contrast(ink, wash) >= 4.5, "secondary \(fill.hex) on \(surface.hex) >= 4.5")
        check(ink != MUMapRGB(hex: "#FFFFFF"), "secondary is never pure white")
    }
}

// MARK: - 5. Height estimate uses the same roles (no 3pt bar, no 13pt guess)
func estimate(_ src: String, width: CGFloat = 324) -> CGFloat {
    guard let root = MUProgram.parse(src).render([:]).0 else { return 0 }
    return MinisUIEngine.estimatedHeight(root, width: width)
}
let shortText = estimate("root = Card([Text(\"短短一行\")])")
let longText = estimate("root = Card([Text(\"\(String(repeating: "很长的中文正文段落，用来检查估高是否收敛。", count: 6))\")])")
check(longText > shortText, "a long Chinese paragraph estimates taller")
check(longText < 24 * 20 + 200, "the estimate stays bounded for long Chinese text")
let noteText = estimate("root = Card([Text(\"一段说明\", \"null\", \"note\")])")
let plainText = estimate("root = Card([Text(\"一段说明\")])")
check(noteText < plainText, "a 12pt note estimates shorter than the 14pt body")
check(plainText - noteText <= 5, "the note/body delta is one line box, not a font jump")
let calloutShort = estimate("root = Card([Callout(\"一段说明\")])")
let calloutLong = estimate("root = Card([Callout(\"\(String(repeating: "很长的中文说明文字，检查换行。", count: 8))\")])")
check(calloutLong > calloutShort, "a long callout estimates taller")
check(calloutLong - calloutShort < 400, "the callout estimate converges for long Chinese text")
// A 12pt callout line box must never be estimated with the 14pt box.
let oneLineCallout = calloutShort - shortText
check(oneLineCallout < 21, "the callout chrome is <= 21pt (10+10 padding + hairline), no bar column")
let oneLine = estimate("root = Card([Callout(\"\(String(repeating: "字", count: 20))\")])")
let twoLines = estimate("root = Card([Callout(\"\(String(repeating: "字", count: 24))\")])")
check(twoLines - oneLine == 17, "each extra callout line is exactly the 12pt line box (17pt)")

print("SHOWUI_ROLE_TOKEN_PASS checks=\(passed)")
if !failed.isEmpty {
    for f in failed { print("FAILED: \(f)") }
    exit(1)
}
