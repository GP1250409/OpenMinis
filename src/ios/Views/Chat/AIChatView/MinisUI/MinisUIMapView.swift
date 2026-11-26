// Native offline maps. Independent of MUChartStyle members except its storage key.
import SwiftUI
import UIKit

extension MUMapRGB {
    var color: Color { let (r,g,b)=rgb; return Color(red:r,green:g,blue:b) }
    var uiColor: UIColor { UIColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0) }
}

// This environment contains an OPAQUE composited surface, not a trait guess.
// The root supplies ChatColors.background; each Card composites its real fill.
private struct MUSurfaceKey: EnvironmentKey { static let defaultValue: MUMapRGB? = nil }
private struct MUChartPlotHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var muSurface: MUMapRGB? {
        get { self[MUSurfaceKey.self] }
        set { self[MUSurfaceKey.self] = newValue }
    }
    var muChartPlotHeight: CGFloat? {
        get { self[MUChartPlotHeightKey.self] }
        set { self[MUChartPlotHeightKey.self] = newValue }
    }
}
enum MUSurface {
    static func base(_ inherited: MUMapRGB?, scheme: ColorScheme) -> MUMapRGB {
        inherited ?? rgb(UIColor.systemBackground, over: MUMapRGB(hex: "#FFFFFF"), scheme: scheme)
    }
    static func rgb(_ color: Color, over background: MUMapRGB, scheme: ColorScheme, environment: EnvironmentValues? = nil) -> MUMapRGB {
        // Resolve through UIKit under an explicit trait collection. Asking a
        // *fresh* `EnvironmentValues` instead answered for a context with no
        // tint: `Color.accentColor` (the Default chat theme) then came back as
        // the system default blue, so the ink was measured against a fill the
        // view never paints. UIKit resolves the same colour against the app's
        // real tint and the requested light/dark appearance.
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        var native = UIColor.clear
        traits.performAsCurrent { native = UIColor(color) }
        return rgb(native, over: background, scheme: scheme)
    }
    static func rgb(_ color: UIColor, over background: MUMapRGB, scheme: ColorScheme) -> MUMapRGB {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = color.resolvedColor(with: traits)
        // Components are only comparable in one space. A Display P3 triple read
        // as sRGB moves a saturated accent by tens of units (#4C84E7 for
        // #3686EE), so convert the CGColor into sRGB before the byte maths.
        // Neutral surfaces are unchanged by the conversion.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = resolved.cgColor.converted(to: space, intent: .defaultIntent, options: nil) ?? resolved.cgColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: converted).getRed(&r, green: &g, blue: &b, alpha: &a) else { return background }
        func byte(_ x: CGFloat) -> UInt8 { UInt8(min(255, max(0, Int((min(1, max(0, x)) * 255).rounded())))) }
        let foreground = MUMapRGB(r: byte(r), g: byte(g), b: byte(b))
        return foreground.composited(over: background, alpha: Double(a))
    }
    static func foreground(_ color: Color, on surface: MUMapRGB, scheme: ColorScheme, minimum: Double = 4.5, environment: EnvironmentValues? = nil) -> Color {
        rgb(color, over: surface, scheme: scheme, environment: environment).readable(on: surface, minimum: minimum).color
    }
}
// The same root path is used by chat cards and the native regression fixture.
struct MURootSurface: ViewModifier {
    @AppStorage(ChatThemeStore.key) private var appThemeId = ""
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let surface = MUSurface.rgb(ChatColors.backgroundUIColor, over: MUSurface.base(nil, scheme: scheme), scheme: scheme)
        // AppStorage invalidates this root even outside the chat coordinator.
        // Surface keys already segregate the chart contrast cache by true RGB.
        let _ = appThemeId
        content.environment(\.muSurface, surface)
            .foregroundStyle(MUSurface.foreground(ChatColors.primaryText, on: surface, scheme: scheme))
            .tint(ChatColors.tint)
    }
}
struct MUCardTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size:16,weight:.semibold))
            .modifier(MUReadableText(color: ChatColors.primaryText))
            .fixedSize(horizontal:false,vertical:true)
    }
}
struct MUReadableText: ViewModifier {
    let color: Color
    @Environment(\.self) private var appearance
    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.foregroundStyle(MUSurface.foreground(color,on:MUSurface.base(inherited,scheme:scheme),scheme:scheme,environment:appearance))
    }
}
// Shared by MUCard and the bitmap fixtures: no extra geometry or layout pass.
struct MUCardSurface: ViewModifier {
    let fill: Color
    var nativeFill: UIColor? = nil
    var cornerRadius: CGFloat = 14
    var bordered = true
    @Environment(\.self) private var appearance
    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let parent = MUSurface.base(inherited, scheme: scheme)
        let surface = nativeFill.map { MUSurface.rgb($0, over: parent, scheme: scheme) }
            ?? MUSurface.rgb(fill, over: parent, scheme: scheme, environment: appearance)
        // Draw exactly the same opaque composite that descendants use. Resolving
        // fill a second time in SwiftUI can disagree with the hosting cell traits.
        content
            .foregroundStyle(MUSurface.foreground(ChatColors.primaryText, on: surface, scheme: scheme, environment: appearance))
            .environment(\.muSurface, surface)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(surface.color))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(bordered ? 0.08 : 0), lineWidth: 0.6))
    }
}

// One shared size formula drives both SwiftUI's first proposal and the list's
// estimatedHeight. No onAppear/PreferenceKey width feedback or second-pass jump.
private struct MUMapExactLayout: Layout {
    let comp: MUComp
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1,proposal.width ?? 300)
        return CGSize(width:width,height:MUMapMetrics(comp,width:width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at:bounds.origin,anchor:.topLeading,proposal:ProposedViewSize(bounds.size)) }
    }
}

/// Offscreen bitmap cache for BlockMap / GeoMap cards.
/// Scrolling back and forth over complex maps (e.g. world-admin0 with 70k+
/// vertices) hits this NSCache and blits a single texture instead of
/// re-rasterising thousands of polygons on the main thread.
private final class MUMapBitmapCache {
    static let shared = MUMapBitmapCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 48
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    func image(comp: MUComp, width: CGFloat, height: CGFloat, displayScale: CGFloat, style: String, surface: MUMapRGB) -> UIImage? {
        guard width > 1, height > 1 else { return nil }
        let scale = max(1.0, displayScale)
        let key = cacheKey(comp: comp, width: width, height: height, scale: scale, style: style, surface: surface) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let rendered = render(comp: comp, width: width, height: height, scale: scale, style: style, surface: surface)
        let cost = Int(ceil(width * scale)) * Int(ceil(height * scale)) * 4
        cache.setObject(rendered, forKey: key, cost: cost)
        return rendered
    }

    private func cacheKey(comp: MUComp, width: CGFloat, height: CGFloat, scale: CGFloat, style: String, surface: MUMapRGB) -> String {
        var h: UInt64 = 14695981039346656037
        @inline(__always) func mix(_ byte: UInt8) { h ^= UInt64(byte); h &*= 1099511628211 }
        @inline(__always) func mixStr(_ s: String?) {
            if let s { for b in s.utf8 { mix(b) } }
            mix(0x1F)
        }
        @inline(__always) func mixInt(_ v: Int) {
            var x = UInt64(bitPattern: Int64(v))
            for _ in 0..<8 { mix(UInt8(truncatingIfNeeded: x)); x >>= 8 }
        }
        @inline(__always) func mixDouble(_ d: Double) {
            var x = d.bitPattern
            for _ in 0..<8 { mix(UInt8(truncatingIfNeeded: x)); x >>= 8 }
        }
        mixStr(comp.name)
        let region = comp.str("region") ?? "us"
        mixStr(region)
        mixStr(comp.str("mode"))
        mixStr(comp.str("scale"))
        mixStr(comp.str("title"))
        mixStr(comp.str("subtitle"))
        mixStr(comp.str("unit"))
        mixStr(comp.str("source"))
        let codes = comp.strings("codes")
        mixInt(codes.count); for s in codes { mixStr(s) }
        let values = comp.numbers("values")
        mixInt(values.count); for v in values { mixDouble(v) }
        let bins = comp.numbers("bins")
        mixInt(bins.count); for v in bins { mixDouble(v) }
        let hl = comp.strings("highlight")
        mixInt(hl.count); for s in hl { mixStr(s) }
        let pts = comp.matrix("points")
        mixInt(pts.count); for row in pts { mixInt(row.count); for v in row { mixDouble(v) } }
        let pl = comp.strings("pointLabels")
        mixInt(pl.count); for s in pl { mixStr(s) }
        if comp.name == "GeoMap" {
            mixStr(MUMapPackStore.shared.resolvePackId(region))
        }
        let wBucket = Int((width * 2).rounded())
        let hBucket = Int((height * 2).rounded())
        let sBucket = Int((scale * 10).rounded())
        return "\(wBucket)x\(hBucket)@\(sBucket)|\(style)|\(surface.r),\(surface.g),\(surface.b)|\(String(h, radix: 16))"
    }

    private func render(comp: MUComp, width: CGFloat, height: CGFloat, scale: CGFloat, style: String, surface: MUMapRGB) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let m = MUMapMetrics(comp, width: Double(width))
        return renderer.image { uiCtx in
            draw(uiCtx.cgContext, m, comp: comp, style: style, surface: surface)
        }
    }

    private func drawSingleLineText(_ string: String, in rect: CGRect, color: MUMapRGB, size: Double = 11, bold: Bool = false, centered: Bool = false) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = centered ? .center : .left
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.uiColor,
            .paragraphStyle: para
        ]
        let s = String(string.prefix(512)) as NSString
        let lineH = min(rect.height, ceil(font.lineHeight))
        let drawRect = CGRect(x: rect.minX, y: rect.midY - lineH / 2.0, width: rect.width, height: lineH)
        s.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: attrs, context: nil)
    }

    private func drawParagraph(_ string: String, in rect: CGRect, color: MUMapRGB, size: Double, bold: Bool = false) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.uiColor
        ]
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
    }

    private func drawLineText(_ string: String, at point: CGPoint, trailing: Bool = false, color: MUMapRGB, size: Double, bold: Bool = false) {
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.uiColor
        ]
        let ns = string as NSString
        let x = trailing ? point.x - ns.size(withAttributes: attrs).width : point.x
        ns.draw(at: CGPoint(x: x, y: point.y), withAttributes: attrs)
    }

    private func draw(_ cg: CGContext, _ m: MUMapMetrics, comp: MUComp, style: String, surface: MUMapRGB) {
        let theme = MUMapTheme.resolve(style).adapted(to: surface)
        let values = MUMapCore.values(comp)
        let highlight = Array(MUMapCore.highlights(comp).prefix(MUMapChipStyle.highlightLimit))
        let bins = MUMapBins(values: comp.numbers("values"), boundaries: comp.numbers("bins"), diverging: (comp.str("scale") ?? "").hasPrefix("diverging"))
        let colors = MUMapScale.colors(comp.str("scale"), style: style, count: bins.count)
        let hairline = (surface.luminance < 0.179 ? theme.muted.uiColor.withAlphaComponent(0.65) : theme.text.uiColor).cgColor

        cg.setFillColor(theme.accent.uiColor.cgColor)
        cg.fill(CGRect(x: 10, y: 8, width: max(0, m.width - 20), height: 0.75))
        cg.fill(CGRect(x: 10, y: 8, width: 18, height: 4))

        var y = 16.0
        if let title = comp.str("title") {
            drawParagraph(title, in: CGRect(x: 10, y: y, width: m.width - 20, height: m.titleHeight), color: theme.text, size: 16, bold: true)
            y += m.titleHeight + 4
        }
        if let subtitle = comp.str("subtitle") {
            drawParagraph(subtitle, in: CGRect(x: 10, y: y, width: m.width - 20, height: m.subtitleHeight), color: theme.muted, size: 11)
        }
        cg.setStrokeColor(hairline)
        cg.setLineWidth(0.5)
        for (i, frame) in m.legendFrames.enumerated() {
            cg.setFillColor(colors[i].uiColor.cgColor)
            cg.fill(frame)
            cg.stroke(frame)
        }
        if !m.legendTickAnchors.isEmpty {
            cg.setStrokeColor(theme.muted.uiColor.withAlphaComponent(0.85).cgColor)
            cg.setLineWidth(0.75)
            for ax in m.legendTickAnchors {
                cg.move(to: CGPoint(x: ax, y: m.legendY + m.swatchHeight))
                cg.addLine(to: CGPoint(x: ax, y: m.legendY + m.swatchHeight + 2.5))
            }
            cg.strokePath()
        }
        for tick in m.legendTicks {
            drawLineText(tick.text, at: CGPoint(x: tick.frame.minX, y: tick.frame.minY), color: theme.text, size: 9.5)
        }
        if m.legendSingleLabelRect != .zero {
            drawLineText(MUMapL10n.all, at: CGPoint(x: m.legendSingleLabelRect.minX, y: m.legendSingleLabelRect.minY), color: theme.text, size: 9.5)
        }
        if !m.legendFrames.isEmpty {
            let missingRect = CGRect(x: 10, y: m.missingY + max(0, (m.missingHeight - 7.0) / 2.0), width: 7, height: 7)
            cg.setFillColor(theme.missing.uiColor.cgColor)
            cg.fill(missingRect)
            cg.setStrokeColor(hairline)
            cg.setLineWidth(0.5)
            cg.stroke(missingRect)
            drawLineText(MUMapL10n.noData, at: CGPoint(x: 21, y: m.missingY), color: theme.muted, size: 9.5)
            if m.endsRect != .zero {
                if abs(m.endsRect.minY - m.missingY) < 0.5 {
                    drawLineText(m.endsText, at: CGPoint(x: m.endsRect.maxX, y: m.endsRect.minY), trailing: true, color: theme.muted, size: 9.5)
                } else {
                    drawParagraph(m.endsText, in: m.endsRect, color: theme.muted, size: 9.5)
                }
            }
        }
        if let unit = comp.str("unit") {
            drawParagraph(unit, in: CGRect(x: 10, y: m.unitY, width: m.width - 20, height: m.unitHeight), color: theme.muted, size: 10)
        }
        if comp.name == "BlockMap" {
            drawBlocks(cg, m, comp: comp, theme: theme, surface: surface, values: values, highlight: highlight, bins: bins, colors: colors)
        } else {
            drawGeo(cg, m, comp: comp, style: style, theme: theme, surface: surface, values: values, highlight: highlight, bins: bins, colors: colors)
        }
        let region = comp.str("region") ?? "us"
        let packMeta = comp.name == "GeoMap" ? MUMapPackStore.shared.metadata(for: region) : nil
        for chip in m.highlightChips {
            let chipPath = UIBezierPath(roundedRect: chip.frame, cornerRadius: MUMapChipStyle.cornerRadius).cgPath
            cg.addPath(chipPath)
            cg.setFillColor(theme.accent.uiColor.cgColor)
            cg.fillPath()
            let inner = CGRect(x: chip.frame.minX + MUMapChipStyle.horizontalPadding, y: chip.frame.minY,
                               width: max(1, chip.frame.width - MUMapChipStyle.horizontalPadding * 2 + 1.5), height: chip.frame.height)
            drawSingleLineText(chip.text, in: inner, color: theme.accent.ink, size: MUMapChipStyle.fontSize, bold: true)
        }
        var footer = m.contentY
        if let source = comp.str("source") {
            drawParagraph(MUMapL10n.sourcePrefix + source, in: CGRect(x: 10, y: footer, width: m.width - 20, height: m.sourceHeight), color: theme.muted, size: 10)
            footer += m.sourceHeight
        }
        if comp.name == "GeoMap" {
            let note = packMeta?.manifest.complianceNote ?? "Natural Earth · Albers · AK/HI 插图 · 非导航地图"
            drawParagraph(note, in: CGRect(x: 10, y: footer, width: m.width - 20, height: m.noteHeight), color: theme.muted, size: 9)
        } else if region == "cn" {
            drawParagraph("中国34省级行政区（含台港澳）· 方块拓扑示意", in: CGRect(x: 10, y: footer, width: m.width - 20, height: m.noteHeight), color: theme.muted, size: 9)
        }
    }

    private func drawBlocks(_ cg: CGContext, _ m: MUMapMetrics, comp: MUComp, theme: MUMapTheme, surface: MUMapRGB,
                            values: [String: Double], highlight: [String], bins: MUMapBins, colors: [MUMapRGB]) {
        let tileBorder = (surface.luminance < 0.179 ? theme.muted.uiColor.withAlphaComponent(0.55) : theme.text.uiColor).cgColor
        let accentCG = theme.accent.uiColor.cgColor
        let highlightSet = Set(highlight)
        let fontSize = min(12, max(5, m.cell * 0.36))
        for tile in MUMapRegion.tiles(comp.str("region") ?? "us") {
            let rect = m.rect(tile)
            let fill = values[tile.code].map { colors[bins.index($0)] } ?? theme.missing
            cg.setFillColor(fill.uiColor.cgColor)
            cg.fill(rect)
            cg.setStrokeColor(tileBorder)
            cg.setLineWidth(0.5)
            cg.stroke(rect.insetBy(dx: 0.25, dy: 0.25))
            if highlightSet.contains(tile.code) {
                cg.setStrokeColor(accentCG)
                cg.setLineWidth(2.0)
                cg.stroke(rect.insetBy(dx: 1, dy: 1))
            }
            drawSingleLineText(tile.label, in: rect.insetBy(dx: 1, dy: 1), color: fill.ink, size: fontSize, bold: true, centered: true)
        }
    }

    private func drawGeo(_ cg: CGContext, _ m: MUMapMetrics, comp: MUComp, style: String, theme: MUMapTheme, surface: MUMapRGB,
                         values: [String: Double], highlight: [String], bins: MUMapBins, colors: [MUMapRGB]) {
        let rect = CGRect(x: 10, y: m.plotY, width: max(1, m.width - 20), height: m.plotHeight)
        let region = comp.str("region") ?? "us"
        guard let packMeta = MUMapPackStore.shared.metadata(for: region),
              let packGeom = MUMapPackStore.shared.geometry(for: region) else { return }
        let location = (comp.str("mode") ?? "location") == "location"
        if location {
            cg.setFillColor(theme.sea.uiColor.cgColor)
            cg.fill(rect)
        }

        let frame = MUMapFraming.frame(geometry: packGeom, manifest: packMeta.manifest)
        let viewScale = min(rect.width / frame.width, rect.height / frame.height)
        let tx = rect.midX - frame.midX * viewScale
        let ty = rect.midY - frame.midY * viewScale
        let xform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: viewScale, y: viewScale)
        let invScale = 1.0 / max(1e-6, viewScale)

        cg.saveGState()
        if packMeta.manifest.styleHints.clipToCanvas {
            cg.clip(to: rect)
        }
        cg.concatenate(xform)

        let strokeW = packMeta.manifest.styleHints.featureStrokeWidth
        let highlightSet = Set(highlight)
        var highlightedIndices: [Int] = []
        let darkStrokeCG = MUMapRGB(r: 0x26, g: 0x26, b: 0x24).uiColor.cgColor
        let minBorderContrast = strokeW >= 0.5 ? 3.0 : 2.2
        var borderColorCache: [MUMapRGB: CGColor] = [:]
        @inline(__always) func borderCG(for fill: MUMapRGB) -> CGColor {
            if let hit = borderColorCache[fill] { return hit }
            let c = theme.border.readable(on: fill, minimum: minBorderContrast).uiColor.cgColor
            borderColorCache[fill] = c
            return c
        }
        let dashLengths: [CGFloat] = [3.0 * invScale, 1.0 * invScale]
        let scaledStrokeW = strokeW * invScale
        let scaledDashW = 0.5 * invScale

        for (idx, feat) in packMeta.features.enumerated() where idx < packGeom.featurePaths.count {
            let path = packGeom.featurePaths[idx]
            let fill = values[feat.code].map { colors[bins.index($0)] }
                ?? (highlightSet.contains(feat.code) ? theme.focus : (values.isEmpty ? theme.land : theme.missing))
            cg.addPath(path)
            cg.setFillColor(fill.uiColor.cgColor)
            cg.fillPath(using: .evenOdd)

            if strokeW >= 0.5 {
                cg.setLineDash(phase: 0, lengths: [])
                cg.addPath(path)
                cg.setStrokeColor(darkStrokeCG)
                cg.setLineWidth(scaledStrokeW)
                cg.strokePath()

                cg.setLineDash(phase: 0, lengths: dashLengths)
                cg.addPath(path)
                cg.setStrokeColor(borderCG(for: fill))
                cg.setLineWidth(scaledDashW)
                cg.strokePath()
            } else {
                cg.setLineDash(phase: 0, lengths: [])
                cg.addPath(path)
                cg.setStrokeColor(borderCG(for: fill))
                cg.setLineWidth(scaledStrokeW)
                cg.strokePath()
            }
            if highlightSet.contains(feat.code) { highlightedIndices.append(idx) }
        }

        cg.setLineDash(phase: 0, lengths: [])
        let ovWidth = packMeta.manifest.styleHints.overlayStrokeWidth
        let ovInk = location ? MUMapRGB(r: 0x26, g: 0x26, b: 0x24) : theme.text
        let ovMuted = location ? MUMapRGB(r: 0x66, g: 0x80, b: 0x8E) : theme.muted
        let ovMutedCG = ovMuted.uiColor.withAlphaComponent(0.65).cgColor
        let ovInkCG = ovInk.uiColor.cgColor
        let ovInkSoftCG = ovInk.uiColor.withAlphaComponent(0.72).cgColor
        for (kind, cgPath) in packGeom.overlayPaths {
            cg.addPath(cgPath)
            if kind == 1 {
                cg.setStrokeColor(ovMutedCG)
                cg.setLineWidth(0.75 * invScale)
            } else if kind == 2 {
                cg.setStrokeColor(ovInkCG)
                cg.setLineWidth(max(0.9, ovWidth) * invScale)
            } else {
                cg.setStrokeColor(ovInkSoftCG)
                cg.setLineWidth(ovWidth * invScale)
            }
            cg.strokePath()
        }
        if !highlightedIndices.isEmpty {
            cg.setStrokeColor(theme.accent.uiColor.cgColor)
            cg.setLineWidth(1.25 * invScale)
            for idx in highlightedIndices {
                cg.addPath(packGeom.featurePaths[idx])
                cg.strokePath()
            }
        }
        cg.restoreGState()

        for zone in packMeta.manifest.zones {
            if let lbl = zone.insetLabel {
                let a = CGPoint(x: lbl.x, y: lbl.y).applying(xform)
                let lblColor = location ? MUMapTheme.resolve(style).landText.readable(on: theme.sea) : theme.landText.readable(on: surface)
                drawSingleLineText(lbl.text, in: CGRect(x: a.x, y: a.y - 10, width: 72, height: 12), color: lblColor, size: 8)
            }
        }
        var occupied: [CGRect] = []
        let labels = comp.strings("pointLabels")
        let pointLabelFont = UIFont.systemFont(ofSize: 9)
        for (i, p) in comp.matrix("points").enumerated() where p.count == 3 {
            guard let raw = MUMapProjection.projectPoint(lon: p[0], lat: p[1], manifest: packMeta.manifest) else { continue }
            let a = raw.applying(xform), capital = p[2] == 1
            let diameter = capital ? 3.5 : 3.0
            let marker = CGRect(x: a.x - diameter / 2, y: a.y - diameter / 2, width: diameter, height: diameter)
            cg.setFillColor(UIColor.black.cgColor)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(0.5)
            if capital {
                cg.fill(marker)
                cg.stroke(marker)
            } else {
                cg.fillEllipse(in: marker)
                cg.strokeEllipse(in: marker)
            }
            if i < labels.count {
                let prefixText = String(labels[i].prefix(28)) as NSString
                let measured = prefixText.size(withAttributes: [.font: pointLabelFont])
                let labelSize = CGSize(width: min(110, ceil(measured.width) + 4), height: 13)
                if let box = MUMapLabels.place(anchor: a, size: labelSize, bounds: rect, occupied: occupied) {
                    occupied.append(box)
                    let leader = MUMapLabels.leader(anchor: a, label: box)
                    if leader.count >= 2 {
                        cg.beginPath()
                        cg.move(to: leader[0])
                        for pt in leader.dropFirst() { cg.addLine(to: pt) }
                        cg.setStrokeColor(theme.background.uiColor.cgColor)
                        cg.setLineWidth(1.5)
                        cg.strokePath()

                        cg.beginPath()
                        cg.move(to: leader[0])
                        for pt in leader.dropFirst() { cg.addLine(to: pt) }
                        cg.setStrokeColor(theme.background.ink.uiColor.cgColor)
                        cg.setLineWidth(0.5)
                        cg.strokePath()
                    }
                    cg.setFillColor(theme.background.uiColor.cgColor)
                    cg.fill(box)
                    drawSingleLineText(labels[i], in: box.insetBy(dx: 2, dy: 0), color: theme.landText.readable(on: theme.background), size: 9)
                }
            }
        }
    }
}

struct MUMapView: View {
    let comp: MUComp
    @AppStorage(MUChartStyle.key) private var style = ""
    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    private var surface: MUMapRGB { MUSurface.base(inherited, scheme: scheme) }
    var body: some View {
        let resolvedSurface = surface
        let resolvedStyle = style
        let resolvedScale = displayScale
        MUMapExactLayout(comp:comp) {
            Canvas { context, size in
                if let uiImage = MUMapBitmapCache.shared.image(
                    comp: comp,
                    width: size.width,
                    height: size.height,
                    displayScale: resolvedScale,
                    style: resolvedStyle,
                    surface: resolvedSurface
                ) {
                    context.draw(Image(uiImage: uiImage), in: CGRect(origin: .zero, size: size))
                }
            }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(MUMapCore.fallback(comp))
    }
}
