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
            else if mode == 4 { content.modifier(MUCardSurface(fill: Color(red:48.0/255.0,green:48.0/255.0,blue:46.0/255.0))) }
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
                        for c in [theme.title,theme.subtitle,theme.source,theme.axis,theme.contextLabel] + theme.seriesLabels + theme.accentLabels {
                            check(MUSurface.rgb(c,over:surface,scheme:scheme).contrast(on:surface) >= 4.5, "resolved chart text contrast")
                        }
                        for c in theme.series + theme.accents + [theme.context,theme.grid,theme.zero] {
                            check(MUSurface.rgb(c,over:surface,scheme:scheme).contrast(on:surface) >= 3, "resolved chart graphic contrast")
                        }
                        check(Set(theme.series.map { MUSurface.rgb($0,over:surface,scheme:scheme).hex }).count == theme.series.count, "series remain distinct")
                        let id = "surface\(surfaceCase)-\(palette.isEmpty ? "system" : palette)-\(Int(width))-\(kind)-\(count)-\(scenario.framed)-\(dark ? "dark" : "light")"
                        check(Set(theme.seriesLabels.map { MUSurface.rgb($0,over:surface,scheme:scheme).hex }).count == theme.seriesLabels.count, "series labels remain distinct")
                        if count > 1 {
                            let occupied = theme.look == .recent ? MUChartPaletteTokens.recentAccentOccupiedSeries
                                : (theme.look == .guide2017 ? MUChartPaletteTokens.guide2017AccentOccupiedSeries : MUChartPaletteTokens.systemAccentOccupiedSeries)
                            let st = MUChartEmphasis.styles(series: names, highlight: ["中国"], paletteCount: theme.series.count, accentOccupiedSeries: occupied)
                            let resolvedLineHexes = st.map { s -> String in
                                let col: Color
                                switch s.color {
                                case .accent(let slot): col = theme.accents[min(slot, theme.accents.count - 1)]
                                case .series(let idx): col = theme.series[idx % theme.series.count]
                                case .context: col = theme.context
                                }
                                return MUSurface.rgb(col, over: surface, scheme: scheme).hex
                            }
                            check(Set(resolvedLineHexes).count == names.count, id + " non-highlighted named series remain distinct")
                        }
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
        let fourSeries = ["美国", "日本", "中国", "德国"]
        let fourMatrix: [[Double]] = [
            [2.5, -2.2, 2.5, 2.8],
            [-0.4, -4.2, 1.0, 0.3],
            [6.0, 2.2, 3.0, 4.9],
            [1.1, -3.8, 1.4, -0.4],
        ]
        let sixSeries = ["美国", "日本", "中国", "德国", "印度", "英国"]
        let sixMatrix: [[Double]] = [
            [2.5, -2.2, 2.5, 2.8],
            [-0.4, -4.2, 1.0, 0.3],
            [6.0, 2.2, 3.0, 4.9],
            [1.1, -3.8, 1.4, -0.4],
            [3.9, -5.8, 7.0, 6.5],
            [1.6, -9.3, 4.8, 1.3],
        ]
        let sixOtherSeries = ["美国", "日本", "中国", "德国", "印度", "其他"]
        struct GDPShowcaseSpec {
            let tag: String
            let dark: Bool
            let surfaceCase: Int
            let palette: String
            let names: [String]
            let matrix: [[Double]]
            let hasOtherBucket: Bool
        }
        var gdpSpecs: [GDPShowcaseSpec] = []
        for palette in ["", "economist", "economist2017"] {
            gdpSpecs.append(GDPShowcaseSpec(tag: "4s", dark: false, surfaceCase: 1, palette: palette, names: fourSeries, matrix: fourMatrix, hasOtherBucket: false))
            gdpSpecs.append(GDPShowcaseSpec(tag: "6s", dark: false, surfaceCase: 1, palette: palette, names: sixSeries, matrix: sixMatrix, hasOtherBucket: false))
            gdpSpecs.append(GDPShowcaseSpec(tag: "4s", dark: true, surfaceCase: 4, palette: palette, names: fourSeries, matrix: fourMatrix, hasOtherBucket: false))
            gdpSpecs.append(GDPShowcaseSpec(tag: "6s", dark: true, surfaceCase: 4, palette: palette, names: sixSeries, matrix: sixMatrix, hasOtherBucket: false))
        }
        gdpSpecs.append(GDPShowcaseSpec(tag: "4s", dark: true, surfaceCase: 0, palette: "economist", names: fourSeries, matrix: fourMatrix, hasOtherBucket: false))
        gdpSpecs.append(GDPShowcaseSpec(tag: "6s", dark: true, surfaceCase: 0, palette: "economist", names: sixSeries, matrix: sixMatrix, hasOtherBucket: false))
        gdpSpecs.append(GDPShowcaseSpec(tag: "6s-other", dark: false, surfaceCase: 1, palette: "economist", names: sixOtherSeries, matrix: sixMatrix, hasOtherBucket: true))
        gdpSpecs.append(GDPShowcaseSpec(tag: "6s-other", dark: true, surfaceCase: 4, palette: "economist", names: sixOtherSeries, matrix: sixMatrix, hasOtherBucket: true))

        let gdpFailBefore = failed
        var gdpPngCount = 0
        for spec in gdpSpecs {
          autoreleasepool {
            let width: CGFloat = 330
            let palette = spec.palette
            let dark = spec.dark
            let scheme: ColorScheme = dark ? .dark : .light
            let parent = MUMapRGB(hex: dark ? "#000000" : "#FFFFFF")
            var surface = parent
            if spec.surfaceCase == 1 { surface = MUSurface.rgb(Color(red:0.94,green:0.93,blue:0.90), over:parent, scheme:scheme) }
            if spec.surfaceCase == 4 { surface = MUSurface.rgb(Color(red:48.0/255.0,green:48.0/255.0,blue:46.0/255.0), over:parent, scheme:scheme) }
            let id = "gdp-hl2-\(palette.isEmpty ? "system" : palette)-\(dark ? "dark" : "light")-s\(spec.surfaceCase)-\(spec.tag)"
            let theme = MUChartTheme.current(for: palette).adapted(to: surface, scheme: scheme)
            let occupied = theme.look == .recent ? MUChartPaletteTokens.recentAccentOccupiedSeries
                : (theme.look == .guide2017 ? MUChartPaletteTokens.guide2017AccentOccupiedSeries : MUChartPaletteTokens.systemAccentOccupiedSeries)
            let highlight = ["中国", "美国"]
            let st = MUChartEmphasis.styles(series: spec.names, highlight: highlight, paletteCount: theme.series.count, accentOccupiedSeries: occupied)
            let stRev = MUChartEmphasis.styles(series: spec.names, highlight: ["美国", "中国"], paletteCount: theme.series.count, accentOccupiedSeries: occupied)
            check(st == stRev, id + " two-highlight order invariant")
            check(st[0].color == .accent(0) && st[0].isEmphasized && !st[0].isContextWeight && st[0].boldLabel && !st[0].usesDashByDefault,
                  id + " first data-order highlight gets accent 0")
            check(st[2].color == .accent(1) && st[2].isEmphasized && !st[2].isContextWeight && st[2].boldLabel && !st[2].usesDashByDefault,
                  id + " second data-order highlight gets accent 1")
            for idx in spec.names.indices where idx != 0 && idx != 2 {
                if spec.hasOtherBucket && idx == 5 {
                    check(st[idx].color == .context && st[idx].isContextWeight && !st[idx].boldLabel && !st[idx].usesDashByDefault,
                          id + " explicit other bucket uses context grey")
                } else {
                    check(st[idx].color != .context && !st[idx].isEmphasized && st[idx].isContextWeight && !st[idx].boldLabel && !st[idx].usesDashByDefault,
                          id + " non-highlighted named series \(spec.names[idx]) keeps independent palette colour")
                }
            }
            func resolveRGB(_ source: MUChartColorSource, forLabel: Bool) -> MUMapRGB {
                let pal = forLabel ? theme.seriesLabels : theme.series
                let acc = forLabel ? theme.accentLabels : theme.accents
                let ctx = forLabel ? theme.contextLabel : theme.context
                let col: Color
                switch source {
                case .accent(let slot): col = acc[min(slot, acc.count - 1)]
                case .series(let idx): col = pal[idx % pal.count]
                case .context: col = ctx
                }
                return MUSurface.rgb(col, over: surface, scheme: scheme)
            }
            let expectedLineRGBs = st.map { resolveRGB($0.color, forLabel: false) }
            let expectedLabelRGBs = st.map { resolveRGB($0.color, forLabel: true) }
            check(Set(expectedLineRGBs.map(\.hex)).count == spec.names.count, id + " resolved line colours distinct")
            check(Set(expectedLabelRGBs.map(\.hex)).count == spec.names.count, id + " resolved label colours distinct")
            check(expectedLineRGBs.allSatisfy { $0.contrast(on: surface) >= 3.0 }, id + " line contrast >= 3.0")
            check(expectedLabelRGBs.allSatisfy { $0.contrast(on: surface) >= 4.5 }, id + " label contrast >= 4.5")

            let probe = ChartProbe()
            let title = "主要经济体实际 GDP 增速"
            let subtitle = "实际GDP同比增速，%，2019–24（中美高亮）"
            let source = "来源：渲染回归示意数据"
            let view = MUMultiChartBody(look: theme.look, kind: "line",
                labels: ["19", "20", "22", "24"], series: spec.names, matrix: spec.matrix,
                title: title, subtitle: subtitle, source: source, unit: "%", highlight: highlight, framed: true)
                .onPreferenceChange(MUChartRenderGeometryKey.self) { probe.geometry = $0 }
                .modifier(ChartFixtureSurface(mode: spec.surfaceCase, parent: parent))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = UIHostingController(rootView: view)
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
            let sampled = sample(image, at: CGPoint(x: width/2, y: 1))
            check(rgbDistance(sampled, surface) <= 2, id + " transparent chart exposes actual surface")
            try! image.pngData()!.write(to: output.appendingPathComponent(id + ".png"))
            gdpPngCount += 1

            if let g = probe.geometry {
                check(abs(g.plot.minX - 10) <= 1, id + " actual plot left inset")
                check(abs(g.plot.height - 180) <= 0.5, id + " actual plot height")
                check(abs(g.plot.minX - (width - g.axisColumn.maxX)) <= 1, id + " actual equal insets")
                check(g.labelColumn.minX - g.plot.maxX >= 3.99, id + " actual curve-label gap")
                check(g.axisColumn.minX - g.labelColumn.maxX >= 5.99, id + " actual label-axis gap")
                check(g.labelBoxes.count == spec.names.count, id + " all series have rendered end-label boxes")
                check(g.labelBoxes.allSatisfy { $0.maxX <= g.axisColumn.minX - 6 }, id + " label boxes excluded from axis")
                let ctxLabelRGB = MUSurface.rgb(theme.contextLabel, over: surface, scheme: scheme)
                for (idx, box) in g.labelBoxes.enumerated() {
                    check(maxPixelContrast(image, box: box, surface: surface) >= 4.5, id + " end-label \(spec.names[idx]) bitmap contrast >= 4.5")
                    let obs = coreInkColor(image, box: box, surface: surface)
                    check(obs != nil, id + " end-label \(spec.names[idx]) ink visible")
                    if let obs {
                        check(obs.contrast(on: surface) >= 4.5, id + " end-label \(spec.names[idx]) core pixel contrast >= 4.5")
                        check(euclidDistance(obs, expectedLabelRGBs[idx]) <= 30, id + " end-label \(spec.names[idx]) bitmap colour \(obs.hex) near \(expectedLabelRGBs[idx].hex)")
                        if !spec.hasOtherBucket && (palette != "economist2017" || idx == 0 || idx == 2) {
                            let nearest = expectedLabelRGBs.enumerated().min(by: { euclidDistance(obs, $0.element) < euclidDistance(obs, $1.element) })?.offset
                            check(nearest == idx, id + " end-label \(spec.names[idx]) nearest expected series \(idx) not \(nearest ?? -1)")
                        }
                        if !(spec.hasOtherBucket && idx == 5) && euclidDistance(expectedLabelRGBs[idx], ctxLabelRGB) >= 20 {
                            check(euclidDistance(obs, expectedLabelRGBs[idx]) < euclidDistance(obs, ctxLabelRGB),
                                  id + " end-label \(spec.names[idx]) distinct from context grey")
                        }
                    }
                }
                if palette == "economist" {
                    let gridRGB = MUSurface.rgb(theme.grid, over: surface, scheme: scheme)
                    let zeroRGB = MUSurface.rgb(theme.zero, over: surface, scheme: scheme)
                    for idx in spec.names.indices {
                        if euclidDistance(expectedLineRGBs[idx], gridRGB) >= 35 && euclidDistance(expectedLineRGBs[idx], zeroRGB) >= 35 {
                            let pxCount = countMatchingPixels(image, in: g.plot, matching: expectedLineRGBs[idx], tolerance: 14)
                            check(pxCount >= 25, id + " plot line \(spec.names[idx]) renders colour \(expectedLineRGBs[idx].hex) pixels=\(pxCount)")
                        }
                    }
                }
                let pixels = measure(image, geometry: g)
                check(pixels.left != nil && pixels.right != nil, id + " real bitmap ink detected")
                if let left = pixels.left, let right = pixels.right {
                    let delta = abs(left - right)
                    maxPaddingDifference = max(maxPaddingDifference, delta)
                    check(delta <= 1, id + " pixel inset difference \(delta)")
                }
                check(pixels.gap != nil, id + " pixel text columns both visible")
                if let gap = pixels.gap {
                    minGap = min(minGap, gap)
                    check(gap >= 6, id + " pixel label-axis gap \(gap)")
                }
                let estimate = MUChartTypography.estimatedHeight(title: title, subtitle: subtitle, source: source,
                    seriesCount: spec.names.count, kind: "line", width: width, framed: true)
                let drift = abs(size.height - estimate)
                maxHeightDifference = max(maxHeightDifference, drift)
                check(drift <= 5, id + " rendered height estimate drift \(drift)")
                measurements.append("\(id) left=\(pixels.left ?? -1) right=\(pixels.right ?? -1) gap=\(pixels.gap ?? -1) height=\(size.height) estimate=\(estimate) plot=\(g.plot)")
            } else { check(false, id + " missing production ChartProxy geometry") }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
          }
        }
        if failed == gdpFailBefore && gdpPngCount == 16 {
            print("CHART_RENDER_TWO_HL_PASS cases=\(gdpSpecs.count) png=\(gdpPngCount)")
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
    func euclidDistance(_ a: MUMapRGB, _ b: MUMapRGB) -> Double {
        let (r, g, bl) = a.rgb, (x, y, z) = b.rgb
        let dr = (r - x) * 255, dg = (g - y) * 255, db = (bl - z) * 255
        return sqrt(dr * dr + dg * dg + db * db)
    }
    func coreInkColor(_ image: UIImage, box: CGRect, surface: MUMapRGB) -> MUMapRGB? {
        let inset = box.insetBy(dx: 0, dy: 1.5)
        let rect = CGRect(x: floor(inset.minX * image.scale), y: floor(inset.minY * image.scale),
                          width: ceil(inset.width * image.scale), height: ceil(inset.height * image.scale))
        guard rect.width > 0, rect.height > 0, let cg = image.cgImage?.cropping(to: rect) else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let srgb = surface.rgb
        let sr = srgb.0 * 255, sg = srgb.1 * 255, sb = srgb.2 * 255
        var bestDist = 0.0
        var best = (0, 0, 0)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let dr = Double(bytes[i]) - sr, dg = Double(bytes[i + 1]) - sg, db = Double(bytes[i + 2]) - sb
            let d = dr * dr + dg * dg + db * db
            if d > bestDist {
                bestDist = d
                best = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
            }
        }
        guard bestDist > 100 else { return nil }
        return MUMapRGB(hex: String(format: "#%02X%02X%02X", best.0, best.1, best.2))
    }
    func countMatchingPixels(_ image: UIImage, in box: CGRect, matching target: MUMapRGB, tolerance: Double = 14) -> Int {
        let rect = CGRect(x: floor(box.minX * image.scale), y: floor(box.minY * image.scale),
                          width: ceil(box.width * image.scale), height: ceil(box.height * image.scale))
        guard rect.width > 0, rect.height > 0, let cg = image.cgImage?.cropping(to: rect) else { return 0 }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let (tr, tg, tb) = target.rgb
        let rr = tr * 255, gg = tg * 255, bb = tb * 255
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let d = max(abs(Double(bytes[i]) - rr), max(abs(Double(bytes[i + 1]) - gg), abs(Double(bytes[i + 2]) - bb)))
            if d <= tolerance { count += 1 }
        }
        return count
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
