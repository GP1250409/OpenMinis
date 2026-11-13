import SwiftUI
import UIKit
import Charts

final class ChartProbe { var geometry: MUChartRenderGeometry? }

// Exercise the production Card surface modifier, including nested alpha.
struct ChartFixtureSurface: ViewModifier {
    let mode: Int
    let parent: MUMapRGB
    func body(content: Content) -> some View {
        Group {
            if mode == 0 { content }
            else if mode == 1 { content.modifier(MUCardSurface(fill: Color(red:0.94,green:0.93,blue:0.90))) }
            else if mode == 2 { content.modifier(MUCardSurface(fill: Color(red:0.07,green:0.09,blue:0.12))) }
            else { content.modifier(MUCardSurface(fill: Color.primary.opacity(0.04)))
                .modifier(MUCardSurface(fill: Color(red:0.35,green:0.52,blue:0.44).opacity(0.4))) }
        }.environment(\.muSurface, parent)
    }
}

@main
final class ChartRenderApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var passed = 0
    var failed = 0
    var measurements: [String] = []
    func check(_ ok: Bool, _ message: String) {
        if ok { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
    }
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.run() }
        return true
    }
    func run() {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var minGap = CGFloat.greatestFiniteMagnitude
        var maxPaddingDifference: CGFloat = 0
        var maxHeightDifference: CGFloat = 0
        for dark in [false, true] {
          for surfaceCase in 0..<4 {
            for palette in ["", "economist", "economist2017"] {
                for width: CGFloat in [280, 330, 400] {
                    let scenarios: [(kind: String, count: Int, framed: Bool)] = (1...6).map { ("line", $0, true) }
                        + [("bar", 1, false), ("line", 1, false), ("bar", 3, true), ("stacked", 6, true)]
                    for scenario in scenarios {
                      autoreleasepool {
                        let count = scenario.count, kind = scenario.kind
                        let names = (0..<count).map { $0 == 0 ? "中国" : "很长的中文系列名称第\($0)组" }
                        let matrix = (0..<count).map { i -> [Double] in
                            let values = [Double(i) - 4, 5, -2, 5]
                            // All chart kinds, themes and appearances cover
                            // positive-only, negative-only and crossing zero.
                            if width == 280 { return values.map { abs($0) + 1 } }
                            if width == 330 { return values.map { -abs($0) - 1 } }
                            return values
                        }
                        let scheme: ColorScheme = dark ? .dark : .light
                        let parent = MUMapRGB(hex: dark ? "#000000" : "#FFFFFF")
                        var surface = parent
                        if surfaceCase == 1 { surface = MUSurface.rgb(Color(red:0.94,green:0.93,blue:0.90), over:parent,scheme:scheme) }
                        if surfaceCase == 2 { surface = MUSurface.rgb(Color(red:0.07,green:0.09,blue:0.12), over:parent,scheme:scheme) }
                        if surfaceCase == 3 {
                            surface = MUSurface.rgb(Color(red:0.35,green:0.52,blue:0.44).opacity(0.4),over:parent,scheme:scheme)
                            surface = MUSurface.rgb(Color.primary.opacity(0.04),over:surface,scheme:scheme)
                        }
                        let theme = MUChartTheme.current(for: palette).adapted(to:surface,scheme:scheme)
                        for c in [theme.title,theme.subtitle,theme.source,theme.axis] {
                            check(MUSurface.rgb(c,over:surface,scheme:scheme).contrast(on:surface) >= 4.5, "resolved chart text contrast")
                        }
                        for c in theme.series + theme.accents + [theme.context,theme.grid,theme.zero] {
                            check(MUSurface.rgb(c,over:surface,scheme:scheme).contrast(on:surface) >= 3, "resolved chart graphic contrast")
                        }
                        check(Set(theme.series.map { MUSurface.rgb($0,over:surface,scheme:scheme).hex }).count == theme.series.count, "series remain distinct")
                        let probe = ChartProbe()
                        let title = "中国保持增长"
                        let subtitle = "实际GDP同比增速，%，2019–24"
                        let source = "来源：渲染回归示意数据"
                        let view = MUMultiChartBody(look: theme.look, kind: kind,
                            labels: ["19", "20", "22", "24"], series: names, matrix: matrix,
                            title: title, subtitle: subtitle, source: source, unit: "%", highlight: ["中国"], framed: scenario.framed)
                            .onPreferenceChange(MUChartRenderGeometryKey.self) { probe.geometry = $0 }
                            .modifier(ChartFixtureSurface(mode:surfaceCase,parent:parent))
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let id = "surface\(surfaceCase)-\(palette.isEmpty ? "system" : palette)-\(Int(width))-\(kind)-\(count)-\(scenario.framed)-\(dark ? "dark" : "light")"
                        let host = UIHostingController(rootView: view)
                        // This is a card snapshot, not a screen snapshot. Without
                        // this UIKit injects the phone's 62pt status safe area into
                        // sizeThatFits and shifts pixels outside the named space.
                        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                        host.overrideUserInterfaceStyle = dark ? .dark : .light
                        host.view.backgroundColor = dark ? .black : .white
                        let container = window!.rootViewController!
                        container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
                        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                        host.view.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
                        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
                        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
                            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                        }
                        let sampled=sample(image, at:CGPoint(x:width/2,y:1))
                        check(rgbDistance(sampled,surface) <= 2, id + " transparent chart exposes actual Card/chat/nested surface")
                        try! image.pngData()!.write(to: output.appendingPathComponent(id + ".png"))
                        if let g = probe.geometry {
                            check(abs(g.plot.minX - 10) <= 1, id + " actual plot left inset")
                            check(abs(g.plot.height - 180) <= 0.5, id + " actual plot height")
                            check(abs(g.plot.minX - (width - g.axisColumn.maxX)) <= 1, id + " actual equal insets")
                            if count > 1 && kind == "line" {
                                check(g.labelColumn.minX - g.plot.maxX >= 3.99, id + " actual curve-label gap")
                                check(g.axisColumn.minX - g.labelColumn.maxX >= 5.99, id + " actual label-axis gap")
                                check(g.labelBoxes.allSatisfy { $0.maxX <= g.axisColumn.minX - 6 }, id + " actual label boxes excluded from axis")
                            }
                            check(g.axisBoxes.count == g.gridYs.count && !g.axisBoxes.isEmpty, id + " observed axis boxes")
                            for (box, gridY) in zip(g.axisBoxes, g.gridYs) {
                                check(abs(box.midY - gridY) <= 0.01, id + " axis box center on horizontal grid")
                                check(box.minY >= 0 && box.maxY <= size.height, id + " extreme tick not clipped by card")
                                check(maxPixelContrast(image, box:box, surface:surface) >= 4.5, id + " actual digit bitmap contrast >= 4.5")
                                let ink = axisInkBounds(image, box: box)
                                check(ink != nil, id + " actual digit ink visible including extreme ticks")
                                if let ink {
                                    // Glyph optical bounds may differ slightly from the
                                    // font line box, but never by the old 8.5pt shift.
                                    check(abs(ink.midY - gridY) <= 2, id + " bitmap digit centered on grid \(ink.midY - gridY)")
                                    check(ink.minY > box.minY && ink.maxY < box.maxY, id + " bitmap digit not vertically clipped")
                                }
                            }
                            check(maxPixelContrast(image,box:g.plot,surface:surface,minimum:3) >= 3, id + " actual plot bitmap contrast >= 3")
                            let pixels = measure(image, geometry: g)
                            check(pixels.left != nil && pixels.right != nil, id + " real bitmap ink detected")
                            if let left = pixels.left, let right = pixels.right {
                                let delta = abs(left - right)
                                maxPaddingDifference = max(maxPaddingDifference, delta)
                                check(delta <= 1, id + " pixel inset difference \(delta)")
                            }
                            if count > 1 && kind == "line" {
                                check(pixels.gap != nil, id + " pixel text columns both visible")
                                if let gap = pixels.gap {
                                    minGap = min(minGap, gap)
                                    check(gap >= 6, id + " pixel label-axis gap \(gap)")
                                }
                            }
                            let estimate = MUChartTypography.estimatedHeight(title: title, subtitle: subtitle, source: source,
                                seriesCount: names.count, kind: kind, width: width, framed: scenario.framed)
                            let drift = abs(size.height - estimate)
                            maxHeightDifference = max(maxHeightDifference, drift)
                            check(drift <= 5, id + " rendered height estimate drift \(drift)")
                            measurements.append("\(id) left=\(pixels.left ?? -1) right=\(pixels.right ?? -1) gap=\(pixels.gap ?? -1) height=\(size.height) estimate=\(estimate) plot=\(g.plot)")
                        } else { check(false, id + " missing production ChartProxy geometry") }
                        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                      }
                    }
                }
            }
        }
          }
        let report = measurements.joined(separator: "\n") + "\nCHART_RENDER_METRICS maxPaddingDifference=\(maxPaddingDifference) minLabelAxisGap=\(minGap) maxHeightDifference=\(maxHeightDifference)\n"
        try! report.write(to: output.appendingPathComponent("pixel-measurements.log"), atomically: true, encoding: .utf8)
        print(report)
        print("CHART_RENDER_\(failed == 0 ? "PASS" : "FAIL") checks=\(passed) failures=\(failed) png=\(measurements.count)")
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
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
    func rgbDistance(_ a: MUMapRGB, _ b: MUMapRGB) -> Double {
        let (r,g,bl)=a.rgb, (x,y,z)=b.rgb
        return max(abs(r-x),max(abs(g-y),abs(bl-z)))*255
    }
    func sample(_ image: UIImage, at p: CGPoint) -> MUMapRGB {
        let cg=image.cgImage!.cropping(to:CGRect(x:p.x*image.scale,y:p.y*image.scale,width:1,height:1))!
        var bytes=[UInt8](repeating:0,count:4)
        let c=CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg,in:CGRect(x:0,y:0,width:1,height:1))
        return MUMapRGB(hex:String(format:"#%02X%02X%02X",Int(bytes[0]),Int(bytes[1]),Int(bytes[2])))
    }
    /// Detect the actual glyph bounds within its production 14pt number box.
    func axisInkBounds(_ image: UIImage, box: CGRect) -> CGRect? {
        let scale = image.scale
        let rect = CGRect(x: floor(box.minX * scale), y: floor(box.minY * scale),
                          width: ceil(box.width * scale), height: ceil(box.height * scale))
        guard let cg = image.cgImage?.cropping(to: rect) else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var low = h, high = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if (0..<3).map({ abs(Int(bytes[i + $0]) - Int(bytes[$0])) }).max()! > 24 {
                    low = min(low, y); high = max(high, y)
                }
            }
        }
        guard high >= low else { return nil }
        return CGRect(x: box.minX, y: (rect.minY + CGFloat(low)) / scale,
                      width: box.width, height: CGFloat(high - low + 1) / scale)
    }
    /// Inspect the actual rendered bitmap, not expected frames. Find painted
    /// glyphs in each column against the panel sample. Units returned in pt.
    func measure(_ image: UIImage, geometry g: MUChartRenderGeometry) -> (left: CGFloat?, right: CGFloat?, gap: CGFloat?) {
        let cg = image.cgImage!, w = cg.width, h = cg.height
        let scale = image.scale
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let by = min(h - 1, max(0, Int((g.plot.midY) * scale)))
        let bg = (by * w + w - 2) * 4
        func ink(_ x: Int, _ y: Int, threshold: Int) -> Bool {
            let i = (y * w + x) * 4
            return (0..<3).map { abs(Int(bytes[i + $0]) - Int(bytes[bg + $0])) }.max()! > threshold
        }
        func extent(_ rect: CGRect, threshold: Int = 24) -> (Int?, Int?) {
            let x0 = max(0, Int(ceil(rect.minX * scale))), x1 = min(w, Int(ceil(rect.maxX * scale)))
            let y0 = max(0, Int(ceil(rect.minY * scale))), y1 = min(h, Int(ceil(rect.maxY * scale)))
            guard x1 > x0, y1 > y0 else { return (nil, nil) }
            var lo: Int?, hi: Int?
            for x in x0..<x1 {
                for y in y0..<y1 where ink(x, y, threshold: threshold) {
                    lo = min(lo ?? x, x); hi = max(hi ?? x, x); break
                }
            }
            return (lo, hi)
        }
        // 0.5pt grid strokes are antialiased over 1–2 pixels; their visible
        // contrast can be <24 even though dark text easily exceeds that.
        let plot = extent(g.plot.insetBy(dx: -1, dy: 1), threshold: 8)
        let axisRect = CGRect(x: g.axisColumn.minX - 0.5, y: g.plot.minY - 7,
                              width: g.axisColumn.width + 1, height: g.plot.height + 14)
        let axis = extent(axisRect)
        let label = extent(g.labelColumn)
        let left = plot.0.map { CGFloat($0) / scale }
        let right = axis.1.map { g.panelWidth - CGFloat($0 + 1) / scale }
        let gap: CGFloat?
        if let a = axis.0, let l = label.1 { gap = CGFloat(a - l - 1) / scale } else { gap = nil }
        return (left, right, gap)
    }
}
