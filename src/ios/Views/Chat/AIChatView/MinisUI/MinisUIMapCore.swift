// Offline maps for Minis UI Lang. Pure Foundation; shared by iOS and Linux tests.
import Foundation
#if canImport(UIKit)
import UIKit // Native glyph metrics; Linux uses a conservative source-test fallback.
#endif
#if canImport(CoreGraphics)
import CoreGraphics // Apple geometry conveniences; no UI/rendering dependency.
#endif

struct MUMapTile {
    let code: String
    let label: String
    let row: Int
    let column: Int
    var aliases: [String] = []
}

enum MUMapRegion {
    // Economist maps styleguide (2017), p9, visually transcribed; zero-based.
    static let us: [MUMapTile] = {
        let rows = [
            "AK . . . . . . . . . ME",
            ". . . . . WI . . . VT NH",
            "WA ID MT ND MN IL MI . NY MA .",
            "OR NV WY SD IA IN OH PA NJ CT RI",
            "CA UT CO NE MO KY WV VA MD DE .",
            ". AZ NM KS AR TN NC SC DC . .",
            ". . . OK LA MS AL GA . . .",
            "HI . . TX . . . . FL . ."
        ]
        return rows.enumerated().flatMap { row, line in
            line.split(separator: " ").enumerated().compactMap { column, code in
                code == "." ? nil : MUMapTile(code: String(code), label: String(code), row: row, column: column)
            }
        }
    }()
    // Author-designed equal-area topology, NOT a geographic/standard boundary map.
    // Taiwan, Hong Kong and Macao are included as Chinese province-level divisions.
    static let cn: [MUMapTile] = {
        let rows = [
            ". . . . . . . HL", "XJ . . . . NM . JL",
            "XZ QH GS NX SX HE BJ LN", ". SC CQ SN HA SD TJ .",
            ". YN GZ HB AH JS SH .", ". . GX HN JX ZJ . .",
            ". . HI GD FJ TW . .", ". . . MO HK . . ."
        ]
        let names = ["BJ":"京|北京|北京市|11", "TJ":"津|天津|天津市|12", "HE":"冀|河北|河北省|13",
            "SX":"晋|山西|山西省|14", "NM":"蒙|内蒙古|内蒙古自治区|15", "LN":"辽|辽宁|辽宁省|21",
            "JL":"吉|吉林|吉林省|22", "HL":"黑|黑龙江|黑龙江省|23", "SH":"沪|上海|上海市|31",
            "JS":"苏|江苏|江苏省|32", "ZJ":"浙|浙江|浙江省|33", "AH":"皖|安徽|安徽省|34",
            "FJ":"闽|福建|福建省|35", "JX":"赣|江西|江西省|36", "SD":"鲁|山东|山东省|37",
            "HA":"豫|河南|河南省|41", "HB":"鄂|湖北|湖北省|42", "HN":"湘|湖南|湖南省|43",
            "GD":"粤|广东|广东省|44", "GX":"桂|广西|广西壮族自治区|45", "HI":"琼|海南|海南省|46",
            "CQ":"渝|重庆|重庆市|50", "SC":"川|四川|四川省|51", "GZ":"贵|贵州|贵州省|52",
            "YN":"云|云南|云南省|53", "XZ":"藏|西藏|西藏自治区|54", "SN":"陕|陕西|陕西省|61",
            "GS":"甘|甘肃|甘肃省|62", "QH":"青|青海|青海省|63", "NX":"宁|宁夏|宁夏回族自治区|64",
            "XJ":"新|新疆|新疆维吾尔自治区|65", "TW":"台|台湾|台湾省|71", "HK":"港|香港|香港特别行政区|81",
            "MO":"澳|澳门|澳门特别行政区|82"]
        return rows.enumerated().flatMap { row, line in
            line.split(separator: " ").enumerated().compactMap { column, raw in
                let code = String(raw)
                guard let names = names[code] else { return nil }
                let aliases = names.components(separatedBy: "|")
                return MUMapTile(code: code, label: aliases[0], row: row, column: column, aliases: aliases)
            }
        }
    }()
    static func tiles(_ region: String) -> [MUMapTile] { region == "cn" ? cn : us }
    static func canonical(_ raw: String, region: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix(region.uppercased() + "-") { s = String(s.dropFirst(3)) }
        if region == "cn", s.count == 6, s.hasSuffix("0000") { s = String(s.prefix(2)) }
        return tiles(region).first { $0.code == s || $0.aliases.contains(s) }?.code
    }
}

struct MUMapRGB: Equatable {
    let hex: String
    var rgb: (Double, Double, Double) {
        let n = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }
    var luminance: Double {
        func f(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r,g,b) = rgb; return 0.2126*f(r) + 0.7152*f(g) + 0.0722*f(b)
    }
    var ink: MUMapRGB { MUMapRGB(hex: luminance > 0.179 ? "#000000" : "#FFFFFF") }
    static func mix(_ a: MUMapRGB, _ b: MUMapRGB, _ t: Double) -> MUMapRGB {
        let (r,g,bl) = a.rgb, (x,y,z) = b.rgb, p = min(1, max(0, t))
        return MUMapRGB(hex: String(format: "#%02X%02X%02X", Int(((r+(x-r)*p)*255).rounded()), Int(((g+(y-g)*p)*255).rounded()), Int(((bl+(z-bl)*p)*255).rounded())))
    }
}

// Shared, UI-independent sRGB policy. Preserve valid theme colours verbatim.
// Mixing towards the better neutral retains hue, unlike replacing every series
// with black/white. Quantized output is rechecked before it is accepted.
extension MUMapRGB {
    func contrast(on background: MUMapRGB) -> Double {
        (max(luminance, background.luminance) + 0.05) / (min(luminance, background.luminance) + 0.05)
    }
    func composited(over background: MUMapRGB, alpha: Double) -> MUMapRGB {
        Self.mix(background, self, alpha)
    }
    func readable(on background: MUMapRGB, minimum: Double = 4.5) -> MUMapRGB {
        guard contrast(on: background) < minimum else { return self }
        let black = Self(hex: "#000000"), white = Self(hex: "#FFFFFF")
        let target = black.contrast(on: background) >= white.contrast(on: background) ? black : white
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if Self.mix(self, target, mid).contrast(on: background) >= min(minimum + 0.15, target.contrast(on: background)) { hi = mid } else { lo = mid }
        }
        return Self.mix(self, target, hi)
    }
}

struct MUMapTheme {
    let background, sea, land, landText, waterText, river, border, coast, missing, text, muted, accent, focus: MUMapRGB
    let defaultScale: String
    static func resolve(_ style: String) -> MUMapTheme {
        let colors: [String]
        switch style {
        case "economist2017": colors = ["FFFFFF","EBF8FE","D6D9C9","7A7D69","54C6D2","54C6D2","FFFFFF","A5B29E","E4EAED","262624","66808E","E3120B","E2E4D8"]
        case "economist": colors = ["F1EFEA","E4EDF0","D5D8CB","6D705F","5A9AA6","5A9AA6","FFFFFF","9AA48E","B6B6A9","262624","6F7168","E62923","C8CBB8"]
        default: colors = ["FFFFFF","EAF3FC","DCE5D8","53654F","3989AB","3989AB","FFFFFF","9AAC9C","E5E7EB","1C1C1E","636366","007AFF","B9D3EB"]
        }
        let c = colors.map { MUMapRGB(hex: "#" + $0) }
        return MUMapTheme(background:c[0],sea:c[1],land:c[2],landText:c[3],waterText:c[4],river:c[5],border:c[6],coast:c[7],missing:c[8],text:c[9],muted:c[10],accent:c[11],focus:c[12],defaultScale:style == "economist" ? "red" : "blue")
    }
}

extension MUMapTheme {
    func adapted(to surface: MUMapRGB) -> MUMapTheme {
        // Leave data ramps, land, sea and missing fills unchanged and ordered.
        // Low-contrast regions/swatches receive a thin contrasting outline.
        // On dark surfaces, jump directly to high-contrast light ink tones
        // instead of stopping right at the 4.5:1 gray floor.
        let isDarkSurface = surface.luminance < 0.179
        let resolvedText = isDarkSurface
            ? MUMapRGB(hex: "#F3F4F6").readable(on: surface, minimum: 7.0)
            : text.readable(on: surface)
        let resolvedMuted = isDarkSurface
            ? MUMapRGB(hex: "#B8C0CC").readable(on: surface, minimum: 6.0)
            : muted.readable(on: surface)
        let resolvedLandText = isDarkSurface
            ? MUMapRGB(hex: "#CBD5E1").readable(on: surface, minimum: 6.0)
            : landText.readable(on: surface)
        let resolvedCoast = isDarkSurface
            ? MUMapRGB(hex: "#94A3B8").readable(on: surface, minimum: 3.0)
            : coast.readable(on: surface, minimum: 3.0)
        return MUMapTheme(background: surface, sea: sea, land: land,
            landText: resolvedLandText, waterText: waterText.readable(on: sea),
            river: river.readable(on: sea, minimum: 3), border: border,
            coast: resolvedCoast, missing: missing,
            text: resolvedText, muted: resolvedMuted,
            accent: accent.readable(on: surface, minimum: isDarkSurface ? 3.6 : 3.0),
            focus: focus, defaultScale: defaultScale)
    }
}

enum MUMapScale {
    static let names = ["blue", "red", "green", "yellow", "purple", "stone", "yellowBlue", "greenPurple", "diverging", "divergingStoneGreen"]
    // p5 verified screen colours. p6 diverging: adapted ten-stop combinations,
    // NOT a claim that the PDF specified these ten exact screen hex values.
    static let official: [String: [String]] = [
        "red": ["F2BFBC","EB9D9C","E47C80","DE5D68","D84055","9D1A29"],
        "blue": ["B8C5DE","91A9CD","6D90BE","4B7CB1","2C6BA6","023759"],
        "purple": ["DBBFCF","C79FB7","B681A2","A5678F","964F7F","722157"],
        "yellow": ["F8DDAA","F4CA7E","F1B956","EEA932","EA9A12","E87318"],
        "green": ["B4DDDA","8BCAC8","65B8B7","41A6A9","20969C","235F68"],
        "stone": ["D2D0C7","B9B7AA","A2A291","8D8E7C","7A7D69","4A4B43"],
        "yellowBlue": ["F1DBAF","C7DABA","9FD6C4","6199B6","2C6BA6","02486F"],
        "greenPurple": ["A0DFD1","9ABFC0","93A2AF","957895","964F7F","722157"],
        "diverging": ["023759","2C6BA6","4B7CB1","91A9CD","B8C5DE","F2BFBC","EB9D9C","DE5D68","D84055","9D1A29"],
        "divergingStoneGreen": ["4A4B43","7A7D69","A2A291","B9B7AA","D2D0C7","B4DDDA","8BCAC8","41A6A9","20969C","235F68"]
    ]
    static func colors(_ name: String?, style: String, count: Int) -> [MUMapRGB] {
        let key = name ?? MUMapTheme.resolve(style).defaultScale
        var stops = (official[key] ?? official["blue"]!).map { MUMapRGB(hex: "#" + $0) }
        // Recent is a sampled adaptation, system a native-like adaptation.
        // Retain the official named multihue/diverging ramps in all three modes.
        if style != "economist2017", !["yellowBlue","greenPurple","diverging","divergingStoneGreen"].contains(key) {
            let system = ["blue":"007AFF","red":"FF3B30","green":"248A3D","yellow":"AD7800","purple":"8944AB","stone":"535B63"]
            let recent = ["blue":"22699B","red":"E62923","green":"347565","yellow":"C98B16","purple":"8B5275","stone":"5C6050"]
            let end = MUMapRGB(hex: "#" + ((style == "economist" ? recent : system)[key] ?? "007AFF"))
            stops = [MUMapRGB.mix(MUMapTheme.resolve(style).background, end, 0.22), end,
                     MUMapRGB.mix(end, MUMapRGB(hex: "#152D38"), 0.48)]
        }
        let n = max(1, count)
        return (0..<n).map { i in
            let t = n == 1 ? 0.5 : Double(i) / Double(n-1)
            let x = t * Double(stops.count-1), lo = Int(floor(x)), hi = min(stops.count-1, lo+1)
            return MUMapRGB.mix(stops[lo], stops[hi], x-Double(lo))
        }
    }
}

struct MUMapBins {
    let edges: [Double] // Interior cut points. [a,b) except final [a,+infinity).
    private let exactLabels: Bool
    var count: Int { edges.count + 1 }
    init(values: [Double], boundaries: [Double] = [], diverging: Bool = false) {
        exactLabels = !boundaries.isEmpty
        if !boundaries.isEmpty { edges = boundaries; return }
        let finite = values.filter(\.isFinite)
        var lo = finite.min() ?? 0, hi = finite.max() ?? 1
        if diverging { let m = max(abs(lo), abs(hi), 1e-12); lo = -m; hi = m }
        if hi == lo { let d = max(abs(lo)*0.1, 1); lo -= d; hi += d }
        // Weighted sum avoids overflow of hi-lo for large finite inputs.
        edges = (1...5).map { let t = Double($0)/6; return lo*(1-t) + hi*t }
    }
    func index(_ value: Double) -> Int { edges.firstIndex(where: { value < $0 }) ?? edges.count }
    func edgeText(_ index: Int) -> String {
        let x = edges[index]
        // Explicit user thresholds must not collapse under %.3g rounding.
        // Automatic equal-width bins retain their concise approximate ticks.
        guard exactLabels else { return String(format: "%.3g", x) }
        if x == 0 { return "0" }
        let s = String(x)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
    func label(_ index: Int) -> String {
        if edges.isEmpty { return MUMapL10n.all }
        if index == 0 { return "<" + edgeText(0) }
        if index == edges.count { return "≥" + edgeText(index - 1) }
        return edgeText(index - 1) + "–<" + edgeText(index)
    }
}

enum MUMapL10n {
    static var all: String { NSLocalizedString("All", value: "全部", comment: "Map legend label for all regions") }
    static var noData: String { NSLocalizedString("No data", value: "无数据", comment: "Map legend label for missing data") }
    static var sourcePrefix: String { NSLocalizedString("Source: ", value: "来源：", comment: "Map source prefix") }
    static func endsSummary(_ first: String, _ last: String) -> String {
        String(format: NSLocalizedString("First %@ · Last %@", value: "首档 %@ · 末档 %@", comment: "Map legend endpoints summary"), first, last)
    }
    static func omittedCount(_ count: Int) -> String {
        String(format: NSLocalizedString("%d other regions have no data", value: "其余 %d 个区域无数据", comment: "Map fallback omitted regions count"), count)
    }
}

// The native estimator and Canvas share EXACT font metrics and geometry.
// Foundation fallback is only for non-rendering Linux contract tests.
enum MUMapTypography {
    static func measure(_ text: String, width: Double, size: Double, bold: Bool = false) -> CGSize {
        let w = max(1, width)
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let box = (text as NSString).boundingRect(with: CGSize(width:w,height:1000000),
            options:[.usesLineFragmentOrigin,.usesFontLeading], attributes:[.font:font], context:nil)
        return CGSize(width:ceil(min(w,box.width)),height:ceil(max(font.lineHeight,box.height))+2)
        #else
        let glyphs = text.reduce(0.0) { $0 + ($1.isASCII ? size*0.65 : size) }
        return CGSize(width:min(w,glyphs),height:ceil(max(1,ceil(glyphs/w))*size*1.3)+2)
        #endif
    }
    static func naturalWidth(_ text: String, size: Double) -> Double {
        Double(measure(text,width:1000000,size:size).width)
    }
}
struct MUMapLegendTick: Equatable {
    let index: Int
    let anchorX: Double
    let text: String
    let frame: CGRect
}
struct MUMapMetrics {
    let width: Double
    let columns: Int
    let rows: Int
    let cell: Double
    let gap = 2.0
    let inset = 10.0
    let swatchHeight = 6.0
    let titleHeight, subtitleHeight, unitHeight, sourceHeight, noteHeight: Double
    let legendY: Double
    let legendFrames: [CGRect]
    let legendTickAnchors: [Double]
    let legendTicks: [MUMapLegendTick]
    let legendSingleLabelRect: CGRect
    let missingY: Double
    let missingHeight: Double
    let endsText: String
    let endsRect: CGRect
    let unitY: Double
    let plotY: Double
    let plotHeight: Double
    let footerY: Double
    let height: Double
    init(_ c: MUComp, width: Double) {
        self.width = max(1,width)
        let usable = max(1,width-20)
        func h(_ text: String?, _ size: Double, _ bold: Bool = false) -> Double {
            text.map { Double(MUMapTypography.measure($0,width:usable,size:size,bold:bold).height) } ?? 0
        }
        titleHeight=h(c.str("title"),16,true)
        subtitleHeight=h(c.str("subtitle"),11)
        unitHeight=h(c.str("unit"),10)
        sourceHeight=h(c.str("source").map { MUMapL10n.sourcePrefix+$0 },10)
        let regionArg = c.str("region") ?? "us"
        let packMeta = c.name == "GeoMap" ? MUMapPackStore.shared.metadata(for: regionArg) : nil
        let noteText: String? = c.name == "GeoMap"
            ? (packMeta?.manifest.complianceNote ?? "Natural Earth · Albers · AK/HI 插图 · 非导航地图")
            : (regionArg == "cn" ? "中国34省级行政区（含台港澳）· 方块拓扑示意" : nil)
        noteHeight=h(noteText,9)
        let tiles=MUMapRegion.tiles(regionArg)
        columns=(tiles.map(\.column).max() ?? 0)+1
        rows=(tiles.map(\.row).max() ?? 0)+1
        cell=max(0,(max(1,width)-20-Double(columns-1)*2)/Double(columns))
        var top=16.0
        if titleHeight > 0 { top += titleHeight+4 }
        if subtitleHeight > 0 { top += subtitleHeight+4 }
        legendY=top
        var frames:[CGRect]=[]
        var anchors:[Double]=[]
        var ticks:[MUMapLegendTick]=[]
        var singleRect:CGRect = .zero
        var resolvedMissingHeight = 0.0
        var resolvedEndsText = ""
        var resolvedEndsRect:CGRect = .zero
        if !c.numbers("values").isEmpty {
            let bins=MUMapBins(values:c.numbers("values"),boundaries:c.numbers("bins"),diverging:(c.str("scale") ?? "").hasPrefix("diverging"))
            let n = max(1, bins.count)
            let tickBottom: Double
            if bins.edges.isEmpty {
                let sw = min(44.0, usable)
                frames.append(CGRect(x:10.0,y:top,width:sw,height:swatchHeight))
                let lblSize = MUMapTypography.measure(MUMapL10n.all,width:usable,size:9.5)
                singleRect = CGRect(x:10.0,y:top+swatchHeight+3.0,width:Double(lblSize.width),height:Double(lblSize.height))
                tickBottom = Double(singleRect.maxY)
            } else {
                let swatchGap = usable / Double(n) > 6.0 ? 1.0 : 0.0
                let swatchW = max(1.0, (usable - swatchGap * Double(n - 1)) / Double(n))
                for i in 0..<n {
                    frames.append(CGRect(x:10.0+Double(i)*(swatchW+swatchGap),y:top,width:swatchW,height:swatchHeight))
                }
                let tickY = top + swatchHeight + 3.0
                var candidates:[MUMapLegendTick] = []
                for j in 0..<bins.edges.count {
                    let ax = Double(frames[j].maxX) + swatchGap / 2.0
                    anchors.append(ax)
                    let t = bins.edgeText(j)
                    let sz = MUMapTypography.measure(t, width: usable, size: 9.5)
                    let tw = Double(sz.width)
                    let rawX = min(max(10.0, ax - tw / 2.0), max(10.0, self.width - 10.0 - tw))
                    candidates.append(MUMapLegendTick(index: j, anchorX: ax, text: t, frame: CGRect(x: rawX, y: tickY, width: tw, height: Double(sz.height))))
                }
                func fits(_ indices: [Int]) -> Bool {
                    var prevMaxX = -Double.infinity
                    for idx in indices.sorted() {
                        let r = candidates[idx].frame
                        if r.minX < prevMaxX + 4.0 { return false }
                        prevMaxX = Double(r.maxX)
                    }
                    return true
                }
                var chosen: [Int] = []
                let allIndices = Array(0..<candidates.count)
                if fits(allIndices) {
                    chosen = allIndices
                } else {
                    if candidates.count >= 3 {
                        for step in 2...max(2, candidates.count - 1) {
                            var idxs = Array(stride(from: 0, to: candidates.count, by: step))
                            if idxs.last != candidates.count - 1 {
                                if fits(idxs + [candidates.count - 1]) {
                                    idxs.append(candidates.count - 1)
                                } else if idxs.count >= 2 && (candidates.count - 1 - idxs.last!) <= step / 2 {
                                    idxs[idxs.count - 1] = candidates.count - 1
                                }
                            }
                            if idxs.count >= 2, fits(idxs) { chosen = idxs; break }
                        }
                    }
                    if chosen.isEmpty {
                        var priority: [Int] = [0]
                        if candidates.count > 1 { priority.append(candidates.count - 1) }
                        if let zeroIdx = bins.edges.firstIndex(of: 0), !priority.contains(zeroIdx) { priority.append(zeroIdx) }
                        // Add evenly spread interior indices via binary bisection order.
                        var queue: [(Int, Int)] = candidates.count > 2 ? [(0, candidates.count - 1)] : []
                        while !queue.isEmpty {
                            let (lo, hi) = queue.removeFirst()
                            let mid = (lo + hi) / 2
                            if mid > lo && mid < hi {
                                if !priority.contains(mid) { priority.append(mid) }
                                queue.append((lo, mid)); queue.append((mid, hi))
                            }
                        }
                        for idx in priority {
                            if fits(chosen + [idx]) { chosen.append(idx) }
                        }
                        chosen.sort()
                    }
                }
                ticks = chosen.map { candidates[$0] }
                tickBottom = ticks.map { Double($0.frame.maxY) }.max() ?? (top + swatchHeight)
            }
            missingY = tickBottom + 3.0
            let missingTextSize = MUMapTypography.measure(MUMapL10n.noData, width: usable, size: 9.5)
            let missingRowH = max(9.0, Double(missingTextSize.height))
            resolvedMissingHeight = missingRowH
            let missingRight = 10.0 + 7.0 + 4.0 + Double(missingTextSize.width)
            if !bins.edges.isEmpty {
                let summary = MUMapL10n.endsSummary(bins.label(0), bins.label(bins.count - 1))
                resolvedEndsText = summary
                let naturalEnds = MUMapTypography.measure(summary, width: 100000, size: 9.5)
                if missingRight + 8.0 + Double(naturalEnds.width) <= self.width - 10.0 {
                    let ex = max(missingRight + 8.0, self.width - 10.0 - Double(naturalEnds.width))
                    resolvedEndsRect = CGRect(x: ex, y: missingY, width: Double(naturalEnds.width), height: Double(naturalEnds.height))
                    top = missingY + max(missingRowH, Double(naturalEnds.height)) + 4.0
                } else {
                    let wrappedEnds = MUMapTypography.measure(summary, width: usable, size: 9.5)
                    resolvedEndsRect = CGRect(x: 10.0, y: missingY + missingRowH + 2.0, width: usable, height: Double(wrappedEnds.height))
                    top = Double(resolvedEndsRect.maxY) + 4.0
                }
            } else {
                top = missingY + missingRowH + 4.0
            }
        } else {
            missingY = top
        }
        legendFrames=frames
        legendTickAnchors=anchors
        legendTicks=ticks
        legendSingleLabelRect=singleRect
        missingHeight=resolvedMissingHeight
        endsText=resolvedEndsText
        endsRect=resolvedEndsRect
        unitY=top
        if unitHeight > 0 { top += unitHeight+4 }
        plotY=top
        if c.name == "GeoMap" {
            let cw = max(1.0, packMeta?.manifest.canvas.width ?? 1000.0)
            let ch = max(1.0, packMeta?.manifest.canvas.height ?? 640.0)
            plotHeight = max(1, usable * (ch / cw))
        } else {
            plotHeight = Double(rows)*cell+Double(rows-1)*2
        }
        footerY=top+plotHeight+8
        height=ceil(footerY+Double(min(3,c.strings("highlight").count))*14+sourceHeight+noteHeight+10)
    }
    func rect(_ tile: MUMapTile) -> CGRect {
        CGRect(x:inset+Double(tile.column)*(cell+gap),y:plotY+Double(tile.row)*(cell+gap),width:cell,height:cell)
    }
}

// Label collision resolution is deterministic and platform-independent. City
// leaders use only horizontal/vertical segments (a single orthogonal elbow).
enum MUMapLabels {
    static func place(anchor: CGPoint, size: CGSize, bounds: CGRect, occupied: [CGRect]) -> CGRect? {
        for (dx,dy) in [(5.0,-15.0),(5.0,5.0),(-size.width-5,-15.0),(-size.width-5,5.0)] {
            let r = CGRect(x: min(max(bounds.minX,anchor.x+dx),max(bounds.minX,bounds.maxX-size.width)), y:min(max(bounds.minY,anchor.y+dy),max(bounds.minY,bounds.maxY-size.height)), width:size.width,height:size.height)
            if bounds.contains(r), !occupied.contains(where: { $0.insetBy(dx:-2,dy:-2).intersects(r) }) { return r }
        }
        return nil // Never force overlapping labels; full text remains in fallback.
    }
    static func leader(anchor: CGPoint, label: CGRect) -> [CGPoint] {
        let end = CGPoint(x: label.midX, y:label.midY)
        return [anchor,CGPoint(x:end.x,y:anchor.y),end]
    }
}

enum MUMapCore {
    static let commonArgs: [MUArg] = [MUArg("codes",.strings,true), MUArg("values",.numbers,true),
        MUArg("scale",.oneOf(MUMapScale.names),false), MUArg("title",.string,false), MUArg("subtitle",.string,false),
        MUArg("source",.string,false), MUArg("unit",.string,false), MUArg("highlight",.strings,false), MUArg("bins",.numbers,false)]
    static let blockArgs = [MUArg("region",.oneOf(["us","cn"]),true)] + commonArgs
    static let geoArgs = [MUArg("region",.string,true)] + commonArgs + [MUArg("mode",.oneOf(["location","cutout"]),false), MUArg("points",.matrix,false), MUArg("pointLabels",.strings,false)]

    static func canonical(_ raw: String, componentName: String, region: String) -> String? {
        if componentName == "BlockMap" { return MUMapRegion.canonical(raw, region: region) }
        return MUMapPackStore.shared.canonical(raw, region: region)
    }

    static func values(_ c: MUComp) -> [String:Double] {
        let region = c.str("region") ?? "us"
        var out: [String:Double] = [:]
        for (raw,value) in zip(c.strings("codes"),c.numbers("values")) {
            if let code = canonical(raw, componentName: c.name, region: region) { out[code] = value }
        }
        return out
    }
    static func highlights(_ c: MUComp) -> [String] {
        let region = c.str("region") ?? "us"
        return c.strings("highlight").compactMap { canonical($0, componentName: c.name, region: region) }
    }
    static func checks(_ c: MUComp) -> [MUError] {
        var errors: [MUError] = []
        func fail(_ code: String, _ msg: String) { errors.append(MUError(code:code,line:c.line,msg:"\(c.name): \(msg)")) }
        let region = c.str("region") ?? "us", codes = c.strings("codes"), nums = c.numbers("values")

        let packMeta: MUMapPackMetadata?
        if c.name == "GeoMap" {
            packMeta = MUMapPackStore.shared.metadata(for: region)
            if packMeta == nil {
                if MUMapPackStore.shared.isUnshippedChinaRegion(region) {
                    fail("map-region", "GeoMap(\"cn\") requires an authorized compliant China boundary pack (not bundled by default); use BlockMap(\"cn\", ...) for schematic 34-province topology")
                } else {
                    let avail = MUMapPackStore.shared.availablePackIds().joined(separator: ", ")
                    fail("map-region", "unknown GeoMap region '\(region)'; available packs: \(avail)")
                }
                return errors
            }
        } else {
            packMeta = nil
        }

        let all = codes + c.strings("highlight")
        let unknown = all.filter { canonical($0, componentName: c.name, region: region) == nil }
        if !unknown.isEmpty {
            if let packMeta {
                if packMeta.features.count <= 60 {
                    let validList = packMeta.features.map(\.code).joined(separator: ", ")
                    fail("map-code", "unknown region codes: " + unknown.joined(separator:", ") + "; valid: " + validList)
                } else {
                    let sample = packMeta.features.prefix(6).map(\.code).joined(separator: ", ")
                    fail("map-code", "unknown region codes: " + unknown.joined(separator:", ") + "; code system: \(packMeta.manifest.codeSystem) (e.g. \(sample))")
                }
            } else {
                fail("map-code", "unknown region codes: " + unknown.joined(separator:", ") + "; valid: " + MUMapRegion.tiles(region).map(\.code).joined(separator:", "))
            }
        }
        let known = codes.compactMap { canonical($0, componentName: c.name, region: region) }
        if Set(known).count != known.count { fail("map-duplicate", "duplicate region codes (including aliases)") }
        if codes.count != nums.count { fail("map-mismatch", "codes and values must have equal lengths") }
        if nums.contains(where: { !$0.isFinite }) { fail("map-number", "values must be finite") }
        let edges = c.numbers("bins")
        if edges.count > 9 || edges.contains(where: { !$0.isFinite }) || zip(edges,edges.dropFirst()).contains(where: { $0 >= $1 }) {
            fail("map-bins", "bins must be 1–9 strictly increasing finite interior cut points")
        }
        if (c.str("scale") ?? "").hasPrefix("diverging"), !edges.isEmpty {
            if edges.count % 2 != 1 || !zip(edges,edges.reversed()).allSatisfy({ abs($0+$1) <= max(1,abs($0),abs($1))*1e-10 }) {
                fail("map-bins", "diverging bins must be zero-symmetric and include zero")
            }
        }
        if c.strings("highlight").count > 3 { fail("map-highlight", "at most 3 highlights; use a separate legend/Text for more") }
        if c.name == "GeoMap", let packMeta {
            let points = c.matrix("points"), labels = c.strings("pointLabels")
            if points.count > 30 { fail("map-points", "at most 30 points") }
            if !labels.isEmpty && labels.count != points.count { fail("map-points", "pointLabels must match points") }
            if points.contains(where: { $0.count != 3 || !$0.allSatisfy(\.isFinite) || !(-180...180).contains($0[0]) || !(-90...90).contains($0[1]) || ![0.0,1.0].contains($0[2]) }) {
                fail("map-points", "points rows must be [longitude, latitude, capital:0|1]")
            } else if points.contains(where: { MUMapProjection.projectPoint(lon:$0[0],lat:$0[1],manifest:packMeta.manifest) == nil }) {
                fail("map-points", "point outside \(packMeta.manifest.id) projection/inset coverage")
            }
        }
        return errors
    }
    static func fallback(_ c: MUComp) -> String {
        var lines = [c.str("title"),c.str("subtitle")].compactMap { $0 }
        let values = values(c), region = c.str("region") ?? "us", unit = c.str("unit") ?? ""
        if c.name == "GeoMap", let packMeta = MUMapPackStore.shared.metadata(for: region) {
            if packMeta.features.count <= 80 {
                for f in packMeta.features {
                    let label = f.zh.isEmpty || f.zh == f.code ? f.code : "\(f.zh) (\(f.code))"
                    lines.append("\(label): " + (values[f.code].map { String(format:"%.6g",$0)+unit } ?? MUMapL10n.noData))
                }
            } else {
                let hi = Set(highlights(c))
                var shown = 0
                for f in packMeta.features where values[f.code] != nil || hi.contains(f.code) {
                    let label = f.zh.isEmpty || f.zh == f.code ? f.code : "\(f.zh) (\(f.code))"
                    lines.append("\(label): " + (values[f.code].map { String(format:"%.6g",$0)+unit } ?? MUMapL10n.noData))
                    shown += 1
                }
                let omitted = packMeta.features.count - shown
                if omitted > 0 { lines.append(MUMapL10n.omittedCount(omitted)) }
            }
        } else {
            for tile in MUMapRegion.tiles(region) {
                lines.append("\(tile.label) (\(tile.code)): " + (values[tile.code].map { String(format:"%.6g",$0)+unit } ?? MUMapL10n.noData))
            }
        }
        for (i,p) in c.matrix("points").enumerated() where p.count == 3 {
            let labels = c.strings("pointLabels")
            lines.append("\(i < labels.count ? labels[i] : "城市")：\(p[0]), \(p[1])\(p[2] == 1 ? " 首都" : "")")
        }
        if let s = c.str("source") { lines.append(MUMapL10n.sourcePrefix+s) }
        if c.name == "BlockMap" && region == "cn" { lines.append("中国34个省级行政区（含台湾、香港、澳门）；方块拓扑示意，非地理边界图") }
        if c.name == "GeoMap" {
            if let packMeta = MUMapPackStore.shared.metadata(for: region) {
                lines.append("\(packMeta.manifest.complianceNote) · \(packMeta.manifest.license.attribution)")
            } else {
                lines.append("Natural Earth 公有领域；Albers 本土投影，阿拉斯加/夏威夷独立插图；非导航地图")
            }
        }
        return lines.joined(separator:"\n")
    }
}

struct MUMapProjectionSpec {
    // standard parallels, central meridian, latitude of origin, all degrees.
    let parallels: [Double]
    let bounds: [Double]
    let frame: [Double]
    func project(lon: Double, lat: Double, alaska: Bool) -> CGPoint {
        let r = Double.pi/180, a=parallels[0]*r, b=parallels[1]*r
        let n=(sin(a)+sin(b))/2, c=pow(cos(a),2)+2*n*sin(a)
        let rho=sqrt(max(0,c-2*n*sin(lat*r)))/n
        let rho0=sqrt(max(0,c-2*n*sin(parallels[3]*r)))/n
        let longitude = alaska && lon > 0 ? lon-360 : lon
        let theta=n*(longitude-parallels[2])*r
        let x=rho*sin(theta), y=rho0-rho*cos(theta)
        let scale=min(frame[2]/(bounds[2]-bounds[0]),frame[3]/(bounds[3]-bounds[1]))
        return CGPoint(x:frame[0]+(frame[2]-(bounds[2]-bounds[0])*scale)/2+(x-bounds[0])*scale,
                       y:frame[1]+(frame[3]-(bounds[3]-bounds[1])*scale)/2+(bounds[3]-y)*scale)
    }
}

enum MUMapProjection {
    static func view(_ p: CGPoint, canvasSize: CGSize = CGSize(width: 1000, height: 640), in rect: CGRect) -> CGPoint {
        let cw = max(1.0, canvasSize.width), ch = max(1.0, canvasSize.height)
        let scale = min(rect.width / cw, rect.height / ch)
        return CGPoint(x: rect.midX - (cw / 2) * scale + p.x * scale, y: rect.midY - (ch / 2) * scale + p.y * scale)
    }
    static func projectPoint(lon: Double, lat: Double, manifest: MUMapPackManifest) -> CGPoint? {
        guard lon.isFinite, lat.isFinite else { return nil }
        let canvasRect = CGRect(x: 0, y: 0, width: manifest.canvas.width, height: manifest.canvas.height)
        for zone in manifest.zones where zone.contains(lon: lon, lat: lat) {
            if let p = zone.project(lon: lon, lat: lat), canvasRect.contains(p) {
                return p
            }
        }
        return nil
    }
    static func usPoint(lon: Double, lat: Double) -> CGPoint? {
        if let meta = MUMapPackStore.shared.metadata(for: "us-admin1") {
            return projectPoint(lon: lon, lat: lat, manifest: meta.manifest)
        }
        guard lon.isFinite,lat.isFinite else { return nil }
        let key: String
        if lat >= 50 && lat <= 72 && (lon <= -129 && lon >= -180 || lon >= 170 && lon <= 180) { key="AK" }
        else if lat >= 18 && lat <= 23 && lon >= -161 && lon <= -154 { key="HI" }
        else if lat >= 24 && lat <= 50 && lon >= -126 && lon <= -66 { key="main" }
        else { return nil }
        guard let spec=MUMapGeometry.specs[key] else { return nil }
        let p=spec.project(lon:lon,lat:lat,alaska:key == "AK")
        return CGRect(x:0,y:0,width:1000,height:640).contains(p) ? p : nil
    }
}
