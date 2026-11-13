// Native offline maps. Independent of MUChartStyle members except its storage key.
import SwiftUI
import UIKit

extension MUMapRGB {
    var color: Color { let (r,g,b)=rgb; return Color(red:r,green:g,blue:b) }
}

// This environment contains an OPAQUE composited surface, not a trait guess.
// The root supplies ChatColors.background; each Card composites its real fill.
private struct MUSurfaceKey: EnvironmentKey { static let defaultValue: MUMapRGB? = nil }
extension EnvironmentValues {
    var muSurface: MUMapRGB? {
        get { self[MUSurfaceKey.self] }
        set { self[MUSurfaceKey.self] = newValue }
    }
}
enum MUSurface {
    static func base(_ inherited: MUMapRGB?, scheme: ColorScheme) -> MUMapRGB {
        inherited ?? rgb(Color(uiColor: .systemBackground), over: MUMapRGB(hex: "#FFFFFF"), scheme: scheme)
    }
    static func rgb(_ color: Color, over background: MUMapRGB, scheme: ColorScheme) -> MUMapRGB {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return background }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let foreground = MUMapRGB(hex: String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b)))
        return foreground.composited(over: background, alpha: Double(a))
    }
    static func foreground(_ color: Color, on surface: MUMapRGB, scheme: ColorScheme, minimum: Double = 4.5) -> Color {
        rgb(color, over: surface, scheme: scheme).readable(on: surface, minimum: minimum).color
    }
}
// Shared by MUCard and the bitmap fixtures: no extra geometry or layout pass.
struct MUCardSurface: ViewModifier {
    let fill: Color
    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let parent = MUSurface.base(inherited, scheme: scheme)
        let surface = MUSurface.rgb(fill, over: parent, scheme: scheme)
        content
            .foregroundStyle(surface.ink.color)
            .environment(\.muSurface, surface)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
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
        let measured=resolved.measure(in:constraint)
        context.draw(resolved,at:CGPoint(x:centered ? rect.midX : rect.minX,y:rect.midY-min(rect.height,measured.height)/2),anchor:centered ? .top : .topLeading)
    }

    private func draw(_ context: GraphicsContext, _ m: MUMapMetrics) {
        let theme=MUMapTheme.resolve(style).adapted(to: surface), values=MUMapCore.values(comp)
        let highlight=MUMapCore.highlights(comp)
        let bins=MUMapBins(values:comp.numbers("values"),boundaries:comp.numbers("bins"),diverging:(comp.str("scale") ?? "").hasPrefix("diverging"))
        let colors=MUMapScale.colors(comp.str("scale"),style:style,count:bins.count)
        // No peripheral panel: the actual Card/chat surface remains visible.
        // p9 cutout convention; recent/system keep the same structural rule.
        context.fill(Path(CGRect(x:10,y:8,width:max(0,m.width-20),height:0.75)),with:.color(theme.accent.color))
        context.fill(Path(CGRect(x:10,y:8,width:18,height:4)),with:.color(theme.accent.color))
        var y=16.0
        if let title=comp.str("title") {
            text(title,CGRect(x:10,y:y,width:m.width-20,height:22),context:context,color:theme.text,size:16,bold:true); y+=26
        }
        if let subtitle=comp.str("subtitle") {
            text(subtitle,CGRect(x:10,y:y,width:m.width-20,height:20),context:context,color:theme.muted,size:12); y+=24
        }
        if !values.isEmpty {
            let w=max(0,(m.width-20)/Double(bins.count))
            for i in 0..<bins.count {
                let x=10+Double(i)*w
                let swatch=Path(CGRect(x:x,y:y,width:max(0,w-1),height:9))
                context.fill(swatch,with:.color(colors[i].color))
                context.stroke(swatch,with:.color(theme.text.color),lineWidth:0.5)
                text(bins.label(i),CGRect(x:x,y:y+10,width:max(0,w-1),height:14),context:context,color:theme.text,size:8,centered:true)
            }
            let missing=Path(CGRect(x:10,y:y+29,width:9,height:9))
            context.fill(missing,with:.color(theme.missing.color))
            context.stroke(missing,with:.color(theme.text.color),lineWidth:0.5)
            text("无数据",CGRect(x:23,y:y+26,width:80,height:15),context:context,color:theme.muted,size:9)
            y+=44
        }
        if let unit=comp.str("unit") { text(unit,CGRect(x:10,y:y,width:m.width-20,height:16),context:context,color:theme.muted,size:10) }
        if comp.name == "BlockMap" { drawBlocks(context,m,theme,values,highlight,bins,colors) }
        else { drawGeo(context,m,theme,values,highlight,bins,colors) }
        var footer=m.footerY
        for code in highlight.prefix(3) {
            let label=MUMapRegion.tiles(comp.str("region") ?? "us").first { $0.code == code }?.label ?? code
            let value=values[code].map { String(format:"%.4g",$0)+(comp.str("unit") ?? "") } ?? "无数据"
            // A dedicated one-line box (<=3 lines total), never over the plot.
            context.fill(Path(CGRect(x:10,y:footer,width:max(0,m.width-20),height:12)),with:.color(theme.accent.color))
            text(label+"  "+value,CGRect(x:17,y:footer,width:m.width-34,height:12),context:context,color:theme.accent.ink,size:9,bold:true)
            footer+=14
        }
        if let source=comp.str("source") {
            text("来源："+source,CGRect(x:10,y:footer,width:m.width-20,height:20),context:context,color:theme.muted,size:10); footer+=20
        }
        if comp.name == "GeoMap" {
            text("Natural Earth · Albers · AK/HI 插图 · 非导航地图",CGRect(x:10,y:footer,width:m.width-20,height:18),context:context,color:theme.muted,size:8)
        } else if comp.str("region") == "cn" {
            text("中国34省级行政区（含台港澳）· 方块拓扑示意",CGRect(x:10,y:footer,width:m.width-20,height:18),context:context,color:theme.muted,size:9)
        }
    }

    private func drawBlocks(_ context: GraphicsContext, _ m: MUMapMetrics, _ theme: MUMapTheme, _ values: [String:Double], _ highlight: [String], _ bins: MUMapBins, _ colors: [MUMapRGB]) {
        for tile in MUMapRegion.tiles(comp.str("region") ?? "us") {
            let rect=m.rect(tile), fill=values[tile.code].map { colors[bins.index($0)] } ?? theme.missing
            context.fill(Path(rect),with:.color(fill.color))
            context.stroke(Path(rect.insetBy(dx:0.25,dy:0.25)),with:.color(theme.text.color),lineWidth:0.5)
            if highlight.contains(tile.code) {
                context.stroke(Path(rect.insetBy(dx:1,dy:1)),with:.color(theme.accent.color),lineWidth:2)
            }
            text(tile.label,rect.insetBy(dx:1,dy:1),context:context,color:fill.ink,size:min(12,max(5,m.cell*0.36)),bold:true,centered:true)
        }
    }

    private func drawGeo(_ context: GraphicsContext, _ m: MUMapMetrics, _ theme: MUMapTheme, _ values: [String:Double], _ highlight: [String], _ bins: MUMapBins, _ colors: [MUMapRGB]) {
        let rect=CGRect(x:10,y:m.plotY,width:max(1,m.width-20),height:m.plotHeight)
        let location=(comp.str("mode") ?? "location") == "location"
        if location { context.fill(Path(rect),with:.color(theme.sea.color)) }
        for region in MUMapGeometry.us {
            var path=Path()
            for ring in region.rings {
                guard let first=ring.first else { continue }
                path.move(to:MUMapProjection.view(first,in:rect))
                for p in ring.dropFirst() { path.addLine(to:MUMapProjection.view(p,in:rect)) }
                path.closeSubpath()
            }
            let fill=values[region.code].map { colors[bins.index($0)] }
                ?? (highlight.contains(region.code) ? theme.focus : (values.isEmpty ? theme.land : theme.missing))
            context.fill(path,with:.color(fill.color),style:FillStyle(eoFill:true))
            context.stroke(path,with:.color(theme.text.color),lineWidth:1)
            context.stroke(path,with:.color(theme.border.readable(on:fill,minimum:3).color),style:StrokeStyle(lineWidth:0.5,dash:[3,1]))
            if highlight.contains(region.code) { context.stroke(path,with:.color(theme.accent.color),lineWidth:1.25) }
        }
        // Separate inset labels make their shifted/scaled placement explicit.
        for (label,p) in [("AK",CGPoint(x:35,y:620)),("HI",CGPoint(x:300,y:620))] {
            let a=MUMapProjection.view(p,in:rect)
            text(label,CGRect(x:a.x,y:a.y-10,width:25,height:12),context:context,color:theme.landText.readable(on:location ? theme.sea : surface),size:8)
        }
        var occupied: [CGRect]=[]
        let labels=comp.strings("pointLabels")
        for (i,p) in comp.matrix("points").enumerated() where p.count == 3 {
            guard let raw=MUMapProjection.usPoint(lon:p[0],lat:p[1]) else { continue }
            let a=MUMapProjection.view(raw,in:rect), capital=p[2] == 1
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
