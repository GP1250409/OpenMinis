// Standalone simulator fixture: renders the actual production MUMapView.
import SwiftUI
import UIKit

// Sole app-wide dependency of the map view. Must match production storage key;
// Python verifies the value against MinisUIView.swift before building.
enum MUChartStyle { static let key = "genuiChartPalette" }

@main final class MapRenderFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        let window=UIWindow(frame:UIScreen.main.bounds)
        window.rootViewController=UIViewController()
        window.makeKeyAndVisible()
        self.window=window
        DispatchQueue.main.async { self.renderMaps() }
        return true
    }
    func maxPixelContrast(_ image: UIImage, box: CGRect, surface: MUMapRGB) -> Double {
        let rect=CGRect(x:floor(box.minX*image.scale),y:floor(box.minY*image.scale),width:ceil(box.width*image.scale),height:ceil(box.height*image.scale))
        guard let cg=image.cgImage?.cropping(to:rect) else { return 0 }
        let w=cg.width, h=cg.height
        var bytes=[UInt8](repeating:0,count:w*h*4)
        let c=CGContext(data:&bytes,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
        // Native text/marks include antialiased edges. Require a genuinely
        // painted core pixel (not an expected colour swatch) at the threshold.
        let linear=(0..<256).map { i -> Double in
            let c=Double(i)/255
            return c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4)
        }
        let background=surface.luminance
        var result=1.0
        for i in stride(from:0,to:bytes.count,by:4) {
            let l=0.2126*linear[Int(bytes[i])]+0.7152*linear[Int(bytes[i+1])]+0.0722*linear[Int(bytes[i+2])]
            result=max(result,(max(l,background)+0.05)/(min(l,background)+0.05))
            if result >= 4.5 { return result }
        }
        return result
    }
    @MainActor private func renderMaps() {
        let programs:[(String,String)] = [
            ("us", "root = BlockMap(\"us\", [\"CA\",\"NY\",\"TX\",\"WA\",\"FL\",\"DC\",\"AK\",\"HI\"], [2,4,6,3,5,1,2,3], null, \"美国方块地图\", \"示意数据 · 非官方统计\", \"内置测试示例\", \"单位\", [\"CA\"])"),
            ("cn", "root = BlockMap(\"cn\", [\"京\",\"沪\",\"粤\",\"川\",\"台\",\"港\",\"澳\",\"新\"], [1,2,3,4,5,6,2,1], \"green\", \"中国方块地图\", \"34省级行政区 · 示意数据\", \"内置测试示例\", null, [\"台\",\"港\",\"澳\"])"),
            ("geo", "root = GeoMap(\"us\", [\"CA\",\"NY\",\"TX\",\"FL\",\"AK\",\"HI\"], [1,2,3,4,5,6], \"blue\", \"美国轮廓地图\", \"示意数据 · 非官方统计\", \"内置测试示例\", null, [\"CA\"], null, \"location\", [[-77.0365,38.8977,1],[-122.4,37.8,0],[-149.9,61.2,0],[-157.8,21.3,0]], [\"Washington\",\"San Francisco\",\"Anchorage\",\"Honolulu\"])"),
            ("cutout", "root = GeoMap(\"us\", [], [], null, \"位置高亮\", \"无数值 · 聚焦示例\", null, null, [\"NY\"], null, \"cutout\")")
        ]
        let out=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("map-render")
        try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        func journal(_ phase: String) {
            try! phase.write(to:out.appendingPathComponent("progress.log"),atomically:true,encoding:.utf8)
        }
        journal("started")
        var checks=0
        for style in ["","economist","economist2017"] {
            let defaults=UserDefaults(suiteName:"map-fixture-"+style)!
            defaults.set(style,forKey:MUChartStyle.key)
            for dark in [false,true] {
              for surfaceCase in 0..<4 {
               for (name,program) in programs {
                journal("case \(style) \(name) dark=\(dark) surface=\(surfaceCase) before validate")
                let validation=MinisUIEngine.validate(program)
                guard validation.ok,let comp=validation.root else { fatalError(MinisUIEngine.feedback(validation)) }
                let width=390.0,height=MUMapMetrics(comp,width:width).height
                let scheme: ColorScheme = dark ? .dark : .light
                let parent=MUMapRGB(hex:dark ? "#000000" : "#FFFFFF")
                let light=Color(red:0.94,green:0.93,blue:0.90), deep=Color(red:0.07,green:0.09,blue:0.12)
                let outer=Color(red:0.35,green:0.52,blue:0.44).opacity(0.4)
                var surface=parent
                if surfaceCase == 1 { surface=MUSurface.rgb(light,over:parent,scheme:scheme) }
                if surfaceCase == 2 { surface=MUSurface.rgb(deep,over:parent,scheme:scheme) }
                if surfaceCase == 3 {
                    surface=MUSurface.rgb(outer,over:parent,scheme:scheme)
                    surface=MUSurface.rgb(Color.primary.opacity(0.04),over:surface,scheme:scheme)
                }
                let chart=MUMapView(comp:comp).defaultAppStorage(defaults)
                let content=Group {
                    if surfaceCase == 0 { chart }
                    else if surfaceCase == 1 { chart.modifier(MUCardSurface(fill:light)) }
                    else if surfaceCase == 2 { chart.modifier(MUCardSurface(fill:deep)) }
                    else { chart.modifier(MUCardSurface(fill:Color.primary.opacity(0.04))).modifier(MUCardSurface(fill:outer)) }
                }.environment(\.muSurface,parent).environment(\.colorScheme,scheme).background(parent.color)
                let theme=MUMapTheme.resolve(style).adapted(to:surface)
                guard theme.text.contrast(on:surface) >= 4.5, theme.muted.contrast(on:surface) >= 4.5,
                    theme.accent.contrast(on:surface) >= 3 else { fatalError("map contrast") }
                checks+=3
                // The ramps are not contrast-clamped to a single colour.
                for scale in MUMapScale.names {
                    let ramp=MUMapScale.colors(scale,style:style,count:6)
                    guard Set(ramp.map(\.hex)).count == 6,
                          ramp.allSatisfy({ $0.ink.contrast(on:$0) >= 4.5 }) else { fatalError("ramp collapsed or label contrast") }
                    checks+=1
                }
                journal("case \(style) \(name) dark=\(dark) surface=\(surfaceCase) before host")
                let host=UIHostingController(rootView:content)
                let measured=host.sizeThatFits(in:CGSize(width:width,height:10000))
                guard abs(measured.height-height)<0.6 else { fatalError("height mismatch \(name): \(measured.height) != \(height)") }
                checks+=1
                if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                host.overrideUserInterfaceStyle=dark ? .dark : .light
                journal("case \(style) \(name) dark=\(dark) surface=\(surfaceCase) before image")
                let renderer=ImageRenderer(content:content.frame(width:width,height:height))
                renderer.scale=2
                guard let image=renderer.uiImage,let png=image.pngData() else { fatalError("render failed") }
                let cg=image.cgImage!.cropping(to:CGRect(x:width,y:2,width:1,height:1))!
                var bytes=[UInt8](repeating:0,count:4)
                let ctx=CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                ctx.draw(cg,in:CGRect(x:0,y:0,width:1,height:1))
                let (r,g,b)=surface.rgb
                guard zip(bytes.prefix(3),[r,g,b]).allSatisfy({ abs(Double($0.0)-$0.1*255) <= 2 }) else { fatalError("opaque map panel or wrong nested background: \(bytes)") }
                checks+=1
                guard maxPixelContrast(image,box:CGRect(x:10,y:16,width:width-20,height:22),surface:surface) >= 4.5 else { fatalError("map title bitmap contrast") }
                guard maxPixelContrast(image,box:CGRect(x:10,y:8,width:width-20,height:4),surface:surface) >= 3 else { fatalError("map top rule bitmap contrast") }
                checks+=2
                journal("case \(style) \(name) dark=\(dark) surface=\(surfaceCase) completed")
                try! png.write(to:out.appendingPathComponent("surface\(surfaceCase)-\(dark ? "dark" : "light")-\(style.isEmpty ? "system" : style)-\(name).png"))
                checks+=1
            }
        }
              }
            }
        // Faithful minimal REAL root/Card path: production ChatColors (no
        // palette stub), MURootSurface, MUCardSurface, Canvas, UIKit traits.
        // Contrast cases intentionally disagree with the device appearance.
        let longSubtitle="蓝＝民主党胜，红＝共和党胜，色深＝领先幅度；2026年美国参议院选举，各州按两党得票领先百分点着色，未投票州保留无数据轮廓。"
        var dynamicChecks=0, dynamicPNGs=0
        for themeID in ["", "chatgpt", "claude", "deepseek"] {
          ChatThemeStore.select(themeID)
          for dark in [true,false,true] { // switch appearance and reload
            let scheme:ColorScheme=dark ? .dark : .light
            let traits=UITraitCollection(userInterfaceStyle:dark ? .dark : .light)
            let parent=MUSurface.rgb(ChatColors.background,over:MUMapRGB(hex:"#FFFFFF"),scheme:scheme)
            let expected=ChatThemeStore.current?.background.uiColor ?? UIColor.systemBackground
            var rr:CGFloat=0,gg:CGFloat=0,bb:CGFloat=0,aa:CGFloat=0
            expected.resolvedColor(with:traits).getRed(&rr,green:&gg,blue:&bb,alpha:&aa)
            let actual=parent.rgb
            guard abs(actual.0-Double(rr))<0.01, abs(actual.1-Double(gg))<0.01, abs(actual.2-Double(bb))<0.01 else { fatalError("dynamic root resolves wrong traits") }
            dynamicChecks+=3
            for width in [240.0,320.0] {
              for cardCase in 0..<4 {
                let program="root = BlockMap(\"us\", [\"TX\",\"NC\",\"OH\"], [-12.1,-19.6,-4.8], \"diverging\", \"参议院：34州定盘，民主党赢下21席\", \""+longSubtitle+"\", \"Wikipedia / AP，截至2026-11-13，完整长来源说明不会被裁切\", \"百分点\", [\"TX\",\"NC\",\"OH\"], [-30,-20,-10,0,10,20,30])"
                let testedProgram=width == 240 ? program.replacingOccurrences(of:"[-30,-20,-10,0,10,20,30]",with:"[-30.125,-20.125,-10.125,-0.125,0,0.125,10.125,20.125,30.125]") : program
                let v=MinisUIEngine.validate(testedProgram)
                guard v.ok,let comp=v.root else { fatalError(MinisUIEngine.feedback(v)) }
                let m=MUMapMetrics(comp,width:width)
                let fill:Color=cardCase == 1 ? ChatColors.secondaryBg : (cardCase == 2 ? Color.white : Color.black.opacity(0.4))
                var surface=cardCase == 0 ? parent : MUSurface.rgb(fill,over:parent,scheme:scheme)
                if cardCase == 3 { surface=MUSurface.rgb(Color.primary.opacity(0.04),over:surface,scheme:scheme) }
                let content=Group {
                  if cardCase == 0 { MUMapView(comp:comp) }
                  else if cardCase == 3 { MUMapView(comp:comp).modifier(MUCardSurface(fill:Color.primary.opacity(0.04))).modifier(MUCardSurface(fill:fill)) }
                  else { MUMapView(comp:comp).modifier(MUCardSurface(fill:fill)) }
                }.modifier(MURootSurface()).environment(\.colorScheme,scheme).background(ChatColors.background)
                // Each label's complete native glyph measurement must fit;
                // no ellipsis, font shrinking or silent range simplification.
                let bins=MUMapBins(values:comp.numbers("values"),boundaries:comp.numbers("bins"),diverging:true)
                for (i,box) in m.legendFrames.enumerated() {
                    let measured=MUMapTypography.measure(bins.label(i),width:box.width-8,size:11)
                    guard measured.height<=box.height-12, box.maxX<=width-10+0.1, box.maxY<m.missingY else { fatalError("legend clipped") }
                    dynamicChecks+=3
                }
                guard m.subtitleHeight > 30, m.sourceHeight > 20, m.plotY >= m.unitY+m.unitHeight else { fatalError("long explanation not fully allocated") }
                dynamicChecks+=3
                let headings=VStack(alignment:.leading,spacing:4) {
                    MUCardTitle(title:"参议院：34州定盘")
                    Text("根节点文本").modifier(MUReadableText(color:.primary))
                }
                let headingContent=Group {
                    if cardCase == 0 { headings }
                    else if cardCase == 3 { headings.modifier(MUCardSurface(fill:Color.primary.opacity(0.04))).modifier(MUCardSurface(fill:fill)) }
                    else { headings.modifier(MUCardSurface(fill:fill)) }
                }.modifier(MURootSurface()).environment(\.colorScheme,scheme).background(ChatColors.background)
                let headingRenderer=ImageRenderer(content:headingContent.frame(width:width,height:60)); headingRenderer.scale=2
                guard let headingImage=headingRenderer.uiImage,
                    maxPixelContrast(headingImage,box:CGRect(x:0,y:0,width:width,height:30),surface:surface)>=4.5,
                    maxPixelContrast(headingImage,box:CGRect(x:0,y:30,width:width,height:30),surface:surface)>=4.5 else { fatalError("actual Card title/root Text contrast") }
                dynamicChecks+=2
                let host=UIHostingController(rootView:content)
                host.overrideUserInterfaceStyle=dark ? .dark : .light
                if #available(iOS 16.4,*) { host.safeAreaRegions=[] }
                let measured=host.sizeThatFits(in:CGSize(width:width,height:10000))
                guard abs(measured.height-m.height)<0.6 else { fatalError("dynamic height mismatch") }
                let renderer=ImageRenderer(content:content.frame(width:width,height:m.height)); renderer.scale=2
                guard let image=renderer.uiImage else { fatalError("dynamic image missing") }
                let subtitleY=16+m.titleHeight+4
                for box in [CGRect(x:10,y:16,width:width-20,height:m.titleHeight),CGRect(x:10,y:subtitleY,width:width-20,height:m.subtitleHeight),CGRect(x:10,y:m.footerY+42,width:width-20,height:m.sourceHeight)] {
                    guard maxPixelContrast(image,box:box,surface:surface)>=4.5 else { fatalError("dynamic explanation contrast") }
                    dynamicChecks+=1
                }
                for box in m.legendFrames {
                    guard maxPixelContrast(image,box:CGRect(x:box.minX+4,y:box.minY+12,width:box.width-8,height:box.height-12),surface:surface)>=4.5 else { fatalError("dynamic interval contrast") }
                    dynamicChecks+=1
                }
                try! image.pngData()!.write(to:out.appendingPathComponent("dynamic-\(dynamicPNGs)-\(themeID)-\(dark)-\(cardCase)-\(Int(width)).png"))
                dynamicPNGs+=1; dynamicChecks+=1
              }
            }
          }
        }
        let marker="MAP_RENDER_PASS checks=\(checks+dynamicChecks) png=\(96+dynamicPNGs)\nMAP_DYNAMIC_PASS checks=\(dynamicChecks) png=\(dynamicPNGs)\n"
        try! marker.write(to:out.appendingPathComponent("result.log"),atomically:true,encoding:.utf8)
        print(marker); fflush(stdout); exit(0)
    }
}
