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
    func maxPixelContrast(_ image: UIImage, box: CGRect, surface: MUMapRGB, minimum: Double = 4.5) -> Double {
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
            if result >= minimum { return result }
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
                }.modifier(MURootSurface()).background(ChatColors.background).environment(\.colorScheme,scheme)
                // Compact 6pt single-row color strip + non-overlapping boundary ticks.
                let bins=MUMapBins(values:comp.numbers("values"),boundaries:comp.numbers("bins"),diverging:true)
                guard m.legendFrames.count == bins.count else { fatalError("swatch count mismatch") }
                for box in m.legendFrames {
                    guard abs(box.height - 6.0) < 0.01, abs(box.minY - m.legendY) < 0.01, box.maxX <= width - 10 + 0.1, box.maxY < m.missingY else { fatalError("legend swatch layout error") }
                    dynamicChecks += 3
                }
                guard !m.legendTicks.isEmpty else { fatalError("missing legend ticks") }
                if width == 320 {
                    guard m.legendTicks.count == 7, m.unitY - m.legendY <= 52 else { fatalError("standard legend not compact or incomplete ticks") }
                }
                var prevTickMax = -Double.infinity
                for tick in m.legendTicks {
                    guard tick.frame.minX >= 10 - 0.1, tick.frame.maxX <= width - 10 + 0.1, tick.frame.minX >= prevTickMax + 3.9, tick.frame.maxY < m.missingY else { fatalError("tick clipped or overlapped") }
                    prevTickMax = Double(tick.frame.maxX)
                    dynamicChecks += 3
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
                }.modifier(MURootSurface()).background(ChatColors.background).environment(\.colorScheme,scheme)
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
                let sample=image.cgImage!.cropping(to:CGRect(x:width,y:2,width:1,height:1))!
                var sampled=[UInt8](repeating:0,count:4)
                let sampleContext=CGContext(data:&sampled,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                sampleContext.draw(sample,in:CGRect(x:0,y:0,width:1,height:1))
                let (sr,sg,sb)=surface.rgb
                guard zip(sampled.prefix(3),[sr,sg,sb]).allSatisfy({ abs(Double($0.0)-$0.1*255)<=3 }) else { fatalError("dynamic rendered surface differs from resolved production surface: \(sampled) \(surface.hex)") }
                dynamicChecks+=3
                let isDark = surface.luminance < 0.179
                let primaryMin = isDark ? 10.0 : 4.5
                let mutedMin = isDark ? 6.0 : 4.5
                let subtitleY=16+m.titleHeight+4
                guard maxPixelContrast(image,box:CGRect(x:10,y:16,width:width-20,height:m.titleHeight),surface:surface,minimum:primaryMin)>=primaryMin else { fatalError("dynamic title contrast") }
                guard maxPixelContrast(image,box:CGRect(x:10,y:subtitleY,width:width-20,height:m.subtitleHeight),surface:surface,minimum:mutedMin)>=mutedMin else { fatalError("dynamic subtitle contrast") }
                guard maxPixelContrast(image,box:CGRect(x:10,y:m.footerY+42,width:width-20,height:m.sourceHeight),surface:surface,minimum:mutedMin)>=mutedMin else { fatalError("dynamic source contrast") }
                dynamicChecks+=3
                for tick in m.legendTicks {
                    guard maxPixelContrast(image,box:tick.frame,surface:surface,minimum:primaryMin)>=primaryMin else { fatalError("dynamic tick contrast") }
                    dynamicChecks+=1
                }
                if m.endsRect != .zero {
                    guard maxPixelContrast(image,box:m.endsRect,surface:surface,minimum:mutedMin)>=mutedMin else { fatalError("dynamic endpoint summary contrast") }
                    dynamicChecks+=1
                }
                try! image.pngData()!.write(to:out.appendingPathComponent("dynamic-\(dynamicPNGs)-\(themeID)-\(dark)-\(cardCase)-\(Int(width)).png"))
                dynamicPNGs+=1; dynamicChecks+=1
              }
            }
          }
        }

        // Generic MapPack native simulator rendering & performance budget tests.
        let packCases: [(String, String)] = [
            ("world", "root = GeoMap(\"world\", [\"US\",\"CN\",\"DE\",\"GB\",\"JP\",\"FR\",\"BR\",\"AU\",\"ZA\",\"MT\"], [25,18,4.5,3.3,4.2,3.0,2.1,1.7,0.4,0.02], \"blue\", \"全球主要经济体示例\", \"Natural Earth 1:50m Equal Earth 多边形与孔洞测试\", \"内置测试\", \"万亿\", [\"CN\",\"US\"], null, \"location\", [[116.4,39.9,1],[-0.12,51.5,1],[151.2,-33.86,0]], [\"北京\",\"伦敦\",\"悉尼\"])"),
            ("eu", "root = GeoMap(\"eu\", [\"DE\",\"FR\",\"GB\",\"IT\",\"ES\",\"PL\",\"UA\",\"NO\",\"SE\",\"MT\"], [4.5,3.0,3.3,2.2,1.6,0.8,0.2,0.5,0.6,0.02], \"green\", \"欧洲示例\", \"LAEA 等积投影与马耳他/冰岛边界测试\", \"内置测试\", null, [\"DE\",\"MT\"], null, \"location\", [[13.4,52.5,1],[-21.9,64.1,1]], [\"Berlin\",\"Reykjavik\"])"),
            ("de", "root = GeoMap(\"de\", [\"DE-BY\",\"DE-NW\",\"DE-BW\",\"DE-BE\"], [10,20,30,40], \"purple\", \"德国各州\", \"16 州一级行政区\", \"内置测试\", null, [\"DE-BE\"])"),
            ("es", "root = GeoMap(\"es\", [\"ES-MD\",\"ES-CT\",\"ES-AN\",\"ES-CN\"], [40,35,28,15], \"yellowBlue\", \"西班牙大区\", \"含加那利群岛插图测试\", \"内置测试\", null, [\"ES-CN\"], null, \"location\", [[-3.7,40.4,1],[-16.25,28.46,0]], [\"Madrid\",\"Tenerife\"])"),
            ("jp", "root = GeoMap(\"jp\", [\"JP-13\",\"JP-27\",\"JP-01\",\"JP-47\"], [95,60,40,20], \"red\", \"日本都道府县\", \"含冲绳插图测试\", \"内置测试\", null, [\"JP-47\"], null, \"location\", [[139.69,35.69,1],[127.68,26.21,0]], [\"东京\",\"那霸\"])"),
            ("au", "root = GeoMap(\"au\", [\"AU-NSW\",\"AU-VIC\",\"AU-QLD\",\"AU-WA\"], [80,65,50,35], \"greenPurple\", \"澳大利亚州与领地\", \"南半球 Albers 投影验证\", \"内置测试\", null, [\"AU-NSW\"])"),
            ("us-county", "root = GeoMap(\"us-county\", [\"06037\",\"36061\",\"17031\",\"48201\",\"02016\",\"15003\"], [-25,-32,12,8,-5,28], \"diverging\", \"美国县级测试（3,143 县）\", \"含 50 州界叠加层与阿拉斯加/夏威夷插图\", \"US Census 2020 示意\", \"百分点\", [\"06037\",\"48201\"], [-30,-15,0,15,30])"),
        ]
        var packChecks = 0, packPNGs = 0
        ChatThemeStore.select("")
        for (tag, prog) in packCases {
            for dark in [false, true] {
                autoreleasepool {
                    let v = MinisUIEngine.validate(prog)
                    guard v.ok, let comp = v.root else { fatalError("pack fixture invalid: \(tag) \(MinisUIEngine.feedback(v))") }
                    let width = 390.0
                    let m = MUMapMetrics(comp, width: width)
                    let scheme: ColorScheme = dark ? .dark : .light
                    let parent = MUSurface.rgb(ChatColors.background, over: MUMapRGB(hex: "#FFFFFF"), scheme: scheme)
                    let surface = MUSurface.rgb(ChatColors.secondaryBg, over: parent, scheme: scheme)
                    let content = MUMapView(comp: comp)
                        .modifier(MUCardSurface(fill: ChatColors.secondaryBg))
                        .modifier(MURootSurface())
                        .background(ChatColors.background)
                        .environment(\.colorScheme, scheme)
                    let host = UIHostingController(rootView: content)
                    host.overrideUserInterfaceStyle = dark ? .dark : .light
                    if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                    let measured = host.sizeThatFits(in: CGSize(width: width, height: 10000))
                    guard abs(measured.height - m.height) < 0.6 else { fatalError("pack height mismatch \(tag): \(measured.height) != \(m.height)") }
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let renderer = ImageRenderer(content: content.frame(width: width, height: m.height))
                    renderer.scale = 2
                    guard let image = renderer.uiImage, let png = image.pngData() else { fatalError("pack render failed: \(tag)") }
                    let elapsed = CFAbsoluteTimeGetCurrent() - t0
                    print(String(format: "PACK_RENDER_TIMING %@ dark=%@ elapsed_ms=%.1f", tag, dark ? "true" : "false", elapsed * 1000))
                    guard elapsed < 5.0 else { fatalError("pack render budget exceeded for \(tag): \(elapsed)s") }
                    guard maxPixelContrast(image, box: CGRect(x: 10, y: 16, width: width - 20, height: m.titleHeight), surface: surface) >= 4.5 else { fatalError("pack title contrast \(tag)") }
                    guard maxPixelContrast(image, box: CGRect(x: 10, y: 8, width: width - 20, height: 4), surface: surface) >= 3.0 else { fatalError("pack top rule contrast \(tag)") }
                    let stats = MUMapPackStore.shared.cacheStats()
                    guard stats.packCount <= MUMapPackStore.maxCachedPacks, stats.byteCount <= MUMapPackStore.maxCachedBytes else {
                        fatalError("pack cache budget exceeded: \(stats)")
                    }
                    try! png.write(to: out.appendingPathComponent("pack-\(tag)-\(dark ? "dark" : "light").png"))
                    packPNGs += 1
                    packChecks += 5
                }
            }
        }

        let totalChecks = checks + dynamicChecks + packChecks
        let totalPNGs = 96 + dynamicPNGs + packPNGs
        let marker="MAP_RENDER_PASS checks=\(totalChecks) png=\(totalPNGs)\nMAP_DYNAMIC_PASS checks=\(dynamicChecks) png=\(dynamicPNGs)\nMAP_PACK_RENDER_PASS checks=\(packChecks) png=\(packPNGs)\n"
        try! marker.write(to:out.appendingPathComponent("result.log"),atomically:true,encoding:.utf8)
        print(marker); fflush(stdout); exit(0)
    }
}
