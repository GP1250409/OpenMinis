// Native offline maps. Independent of MUChartStyle members except its storage key.
import SwiftUI
import UIKit

extension MUMapRGB {
    var color: Color { let (r,g,b)=rgb; return Color(red:r,green:g,blue:b) }
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
        if #available(iOS 17.0, *) {
            var environment = environment ?? EnvironmentValues()
            environment.colorScheme = scheme
            let c = color.resolve(in: environment)
            return rgb(UIColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.opacity)), over: background, scheme: scheme)
        }
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        var native = UIColor.clear
        traits.performAsCurrent { native = UIColor(color) }
        return rgb(native, over: background, scheme: scheme)
    }
    static func rgb(_ color: UIColor, over background: MUMapRGB, scheme: ColorScheme) -> MUMapRGB {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return background }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let foreground = MUMapRGB(hex: String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b)))
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

struct MUMapView: View {
    let comp: MUComp
    @AppStorage(MUChartStyle.key) private var style = ""
    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    private var surface: MUMapRGB { MUSurface.base(inherited, scheme: scheme) }
    var body: some View {
        MUMapExactLayout(comp:comp) {
            Canvas { context,size in
                let metrics=MUMapMetrics(comp,width:size.width)
                draw(context,metrics)
            }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(MUMapCore.fallback(comp))
    }

    private func text(_ string: String, _ rect: CGRect, context: GraphicsContext, color: MUMapRGB, size: Double = 11, bold: Bool = false, centered: Bool = false) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = Font.system(size:size,weight:bold ? .semibold : .regular)
        var s=String(string.prefix(512))
        var resolved=context.resolve(Text(s).font(font).foregroundColor(color.color))
        let constraint=CGSize(width:100000,height:100)
        while s.count > 1 && resolved.measure(in:constraint).width > rect.width {
            s=String(s.dropLast(s.hasSuffix("…") ? 2 : 1))+"…"
            resolved=context.resolve(Text(s).font(font).foregroundColor(color.color))
        }
        resolved.shading = .color(color.color) // Do not inherit Card foregroundStyle.
        let measured=resolved.measure(in:constraint)
        context.draw(resolved,at:CGPoint(x:centered ? rect.midX : rect.minX,y:rect.midY-min(rect.height,measured.height)/2),anchor:centered ? .top : .topLeading)
    }

    // Explanatory text and interval labels are NEVER truncated. Unlike tile
    // codes, their measured multiline boxes participate in MUMapMetrics.
    private func paragraph(_ string: String, _ rect: CGRect, context: GraphicsContext, color: MUMapRGB, size: Double, bold: Bool = false) {
        var resolved=context.resolve(Text(string).font(.system(size:size,weight:bold ? .semibold : .regular)).foregroundColor(color.color))
        resolved.shading = .color(color.color)
        context.draw(resolved,in:rect)
    }

    private func lineText(_ string: String, at point: CGPoint, anchor: UnitPoint = .topLeading, context: GraphicsContext, color: MUMapRGB, size: Double, bold: Bool = false) {
        var resolved=context.resolve(Text(string).font(.system(size:size,weight:bold ? .semibold : .regular)).foregroundColor(color.color))
        resolved.shading = .color(color.color)
        context.draw(resolved,at:point,anchor:anchor)
    }

    private func draw(_ context: GraphicsContext, _ m: MUMapMetrics) {
        let theme=MUMapTheme.resolve(style).adapted(to: surface), values=MUMapCore.values(comp)
        let highlight=MUMapCore.highlights(comp)
        let bins=MUMapBins(values:comp.numbers("values"),boundaries:comp.numbers("bins"),diverging:(comp.str("scale") ?? "").hasPrefix("diverging"))
        let colors=MUMapScale.colors(comp.str("scale"),style:style,count:bins.count)
        let hairline=surface.luminance < 0.179 ? theme.muted.color.opacity(0.65) : theme.text.color
        // No peripheral panel: the actual Card/chat surface remains visible.
        // p9 cutout convention; recent/system keep the same structural rule.
        context.fill(Path(CGRect(x:10,y:8,width:max(0,m.width-20),height:0.75)),with:.color(theme.accent.color))
        context.fill(Path(CGRect(x:10,y:8,width:18,height:4)),with:.color(theme.accent.color))
        var y=16.0
        if let title=comp.str("title") {
            paragraph(title,CGRect(x:10,y:y,width:m.width-20,height:m.titleHeight),context:context,color:theme.text,size:16,bold:true); y+=m.titleHeight+4
        }
        if let subtitle=comp.str("subtitle") {
            paragraph(subtitle,CGRect(x:10,y:y,width:m.width-20,height:m.subtitleHeight),context:context,color:theme.muted,size:11)
        }
        for (i,frame) in m.legendFrames.enumerated() {
            let swatch=Path(frame)
            context.fill(swatch,with:.color(colors[i].color))
            context.stroke(swatch,with:.color(hairline),lineWidth:0.5)
        }
        for ax in m.legendTickAnchors {
            var tick=Path()
            tick.move(to:CGPoint(x:ax,y:m.legendY+m.swatchHeight))
            tick.addLine(to:CGPoint(x:ax,y:m.legendY+m.swatchHeight+2.5))
            context.stroke(tick,with:.color(theme.muted.color.opacity(0.85)),lineWidth:0.75)
        }
        for tick in m.legendTicks {
            lineText(tick.text,at:CGPoint(x:tick.frame.minX,y:tick.frame.minY),anchor:.topLeading,context:context,color:theme.text,size:9.5)
        }
        if m.legendSingleLabelRect != .zero {
            lineText(MUMapL10n.all,at:CGPoint(x:m.legendSingleLabelRect.minX,y:m.legendSingleLabelRect.minY),anchor:.topLeading,context:context,color:theme.text,size:9.5)
        }
        if !m.legendFrames.isEmpty {
            let missing=Path(CGRect(x:10,y:m.missingY+max(0,(m.missingHeight-7.0)/2.0),width:7,height:7))
            context.fill(missing,with:.color(theme.missing.color))
            context.stroke(missing,with:.color(hairline),lineWidth:0.5)
            lineText(MUMapL10n.noData,at:CGPoint(x:21,y:m.missingY),anchor:.topLeading,context:context,color:theme.muted,size:9.5)
            if m.endsRect != .zero {
                if abs(m.endsRect.minY - m.missingY) < 0.5 {
                    lineText(m.endsText,at:CGPoint(x:m.endsRect.maxX,y:m.endsRect.minY),anchor:.topTrailing,context:context,color:theme.muted,size:9.5)
                } else {
                    paragraph(m.endsText,m.endsRect,context:context,color:theme.muted,size:9.5)
                }
            }
        }
        if let unit=comp.str("unit") {
            paragraph(unit,CGRect(x:10,y:m.unitY,width:m.width-20,height:m.unitHeight),context:context,color:theme.muted,size:10)
        }
        if comp.name == "BlockMap" { drawBlocks(context,m,theme,values,highlight,bins,colors) }
        else { drawGeo(context,m,theme,values,highlight,bins,colors) }
        let region=comp.str("region") ?? "us"
        let packMeta=comp.name == "GeoMap" ? MUMapPackStore.shared.metadata(for:region) : nil
        var footer=m.footerY
        for code in highlight.prefix(3) {
            let label=comp.name == "BlockMap"
                ? (MUMapRegion.tiles(region).first { $0.code == code }?.label ?? code)
                : MUMapPackStore.shared.displayName(for:code,region:region)
            let value=values[code].map { String(format:"%.4g",$0)+(comp.str("unit") ?? "") } ?? MUMapL10n.noData
            // A dedicated one-line box (<=3 lines total), never over the plot.
            context.fill(Path(CGRect(x:10,y:footer,width:max(0,m.width-20),height:12)),with:.color(theme.accent.color))
            text(label+"  "+value,CGRect(x:17,y:footer,width:m.width-34,height:12),context:context,color:theme.accent.ink,size:9,bold:true)
            footer+=14
        }
        if let source=comp.str("source") {
            paragraph(MUMapL10n.sourcePrefix+source,CGRect(x:10,y:footer,width:m.width-20,height:m.sourceHeight),context:context,color:theme.muted,size:10); footer+=m.sourceHeight
        }
        if comp.name == "GeoMap" {
            let note=packMeta?.manifest.complianceNote ?? "Natural Earth · Albers · AK/HI 插图 · 非导航地图"
            paragraph(note,CGRect(x:10,y:footer,width:m.width-20,height:m.noteHeight),context:context,color:theme.muted,size:9)
        } else if region == "cn" {
            paragraph("中国34省级行政区（含台港澳）· 方块拓扑示意",CGRect(x:10,y:footer,width:m.width-20,height:m.noteHeight),context:context,color:theme.muted,size:9)
        }
    }

    private func drawBlocks(_ context: GraphicsContext, _ m: MUMapMetrics, _ theme: MUMapTheme, _ values: [String:Double], _ highlight: [String], _ bins: MUMapBins, _ colors: [MUMapRGB]) {
        let tileBorder = surface.luminance < 0.179 ? theme.muted.color.opacity(0.55) : theme.text.color
        for tile in MUMapRegion.tiles(comp.str("region") ?? "us") {
            let rect=m.rect(tile), fill=values[tile.code].map { colors[bins.index($0)] } ?? theme.missing
            context.fill(Path(rect),with:.color(fill.color))
            context.stroke(Path(rect.insetBy(dx:0.25,dy:0.25)),with:.color(tileBorder),lineWidth:0.5)
            if highlight.contains(tile.code) {
                context.stroke(Path(rect.insetBy(dx:1,dy:1)),with:.color(theme.accent.color),lineWidth:2)
            }
            text(tile.label,rect.insetBy(dx:1,dy:1),context:context,color:fill.ink,size:min(12,max(5,m.cell*0.36)),bold:true,centered:true)
        }
    }

    private func drawGeo(_ context: GraphicsContext, _ m: MUMapMetrics, _ theme: MUMapTheme, _ values: [String:Double], _ highlight: [String], _ bins: MUMapBins, _ colors: [MUMapRGB]) {
        let rect=CGRect(x:10,y:m.plotY,width:max(1,m.width-20),height:m.plotHeight)
        let region=comp.str("region") ?? "us"
        guard let packMeta=MUMapPackStore.shared.metadata(for:region),
              let packGeom=MUMapPackStore.shared.geometry(for:region) else { return }
        let location=(comp.str("mode") ?? "location") == "location"
        if location { context.fill(Path(rect),with:.color(theme.sea.color)) }

        let cw=max(1.0,packMeta.manifest.canvas.width), ch=max(1.0,packMeta.manifest.canvas.height)
        let canvasSize=CGSize(width:cw,height:ch)
        let viewScale=min(rect.width/cw,rect.height/ch)
        let tx=rect.midX-(cw/2)*viewScale, ty=rect.midY-(ch/2)*viewScale
        var xform=CGAffineTransform(translationX:tx,y:ty).scaledBy(x:viewScale,y:viewScale)

        var ctx=context
        if packMeta.manifest.styleHints.clipToCanvas { ctx.clip(to:Path(rect)) }

        let strokeW=packMeta.manifest.styleHints.featureStrokeWidth
        let highlightSet=Set(highlight)
        var highlightedIndices:[Int]=[]
        for (idx,feat) in packMeta.features.enumerated() where idx < packGeom.featurePaths.count {
            guard let transformed=packGeom.featurePaths[idx].copy(using:&xform) else { continue }
            let path=Path(transformed)
            let fill=values[feat.code].map { colors[bins.index($0)] }
                ?? (highlightSet.contains(feat.code) ? theme.focus : (values.isEmpty ? theme.land : theme.missing))
            ctx.fill(path,with:.color(fill.color),style:FillStyle(eoFill:true))
            if strokeW >= 0.5 {
                ctx.stroke(path,with:.color(MUMapRGB(hex:"#262624").color),lineWidth:strokeW)
                ctx.stroke(path,with:.color(theme.border.readable(on:fill,minimum:3).color),style:StrokeStyle(lineWidth:0.5,dash:[3,1]))
            } else {
                ctx.stroke(path,with:.color(theme.border.readable(on:fill,minimum:2.2).color),lineWidth:strokeW)
            }
            if highlightSet.contains(feat.code) { highlightedIndices.append(idx) }
        }
        let ovWidth=packMeta.manifest.styleHints.overlayStrokeWidth
        let ovInk=location ? MUMapRGB(hex:"#262624") : theme.text
        let ovMuted=location ? MUMapRGB(hex:"#66808E") : theme.muted
        for (kind,cgPath) in packGeom.overlayPaths {
            guard let transformed=cgPath.copy(using:&xform) else { continue }
            let path=Path(transformed)
            if kind == 1 {
                ctx.stroke(path,with:.color(ovMuted.color.opacity(0.65)),lineWidth:0.75)
            } else if kind == 2 {
                ctx.stroke(path,with:.color(ovInk.color),lineWidth:max(0.9,ovWidth))
            } else {
                ctx.stroke(path,with:.color(ovInk.color.opacity(0.72)),lineWidth:ovWidth)
            }
        }
        for idx in highlightedIndices {
            if let transformed=packGeom.featurePaths[idx].copy(using:&xform) {
                ctx.stroke(Path(transformed),with:.color(theme.accent.color),lineWidth:1.25)
            }
        }

        for zone in packMeta.manifest.zones {
            if let lbl=zone.insetLabel {
                let a=MUMapProjection.view(CGPoint(x:lbl.x,y:lbl.y),canvasSize:canvasSize,in:rect)
                let lblColor=location ? MUMapTheme.resolve(style).landText.readable(on:theme.sea) : theme.landText.readable(on:surface)
                text(lbl.text,CGRect(x:a.x,y:a.y-10,width:72,height:12),context:context,color:lblColor,size:8)
            }
        }
        var occupied: [CGRect]=[]
        let labels=comp.strings("pointLabels")
        for (i,p) in comp.matrix("points").enumerated() where p.count == 3 {
            guard let raw=MUMapProjection.projectPoint(lon:p[0],lat:p[1],manifest:packMeta.manifest) else { continue }
            let a=MUMapProjection.view(raw,canvasSize:canvasSize,in:rect), capital=p[2] == 1
            let diameter=capital ? 3.5 : 3.0
            let marker=CGRect(x:a.x-diameter/2,y:a.y-diameter/2,width:diameter,height:diameter)
            let shape=capital ? Path(marker) : Path(ellipseIn:marker)
            context.fill(shape,with:.color(.black)); context.stroke(shape,with:.color(.white),lineWidth:0.5)
            if i < labels.count {
                // Measure the native label before the pure collision resolver.
                let resolved=context.resolve(Text(String(labels[i].prefix(28))).font(.system(size:9)))
                let measured=resolved.measure(in:CGSize(width:100000,height:100))
                let labelSize=CGSize(width:min(110,measured.width+4),height:13)
                if let box=MUMapLabels.place(anchor:a,size:labelSize,bounds:rect,occupied:occupied) {
                    occupied.append(box)
                    let leader=MUMapLabels.leader(anchor:a,label:box)
                    var line=Path(); line.addLines(leader)
                    context.stroke(line,with:.color(theme.background.color),lineWidth:1.5)
                    context.stroke(line,with:.color(theme.background.ink.color),lineWidth:0.5)
                    context.fill(Path(box),with:.color(theme.background.color))
                    text(labels[i],box.insetBy(dx:2,dy:0),context:context,color:theme.landText.readable(on:theme.background),size:9)
                }
            }
        }
    }
}
