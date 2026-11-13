import SwiftUI
import UIKit
import Charts

final class ChartProbe { var geometry: MUChartRenderGeometry? }

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
            for palette in ["", "economist", "economist2017"] {
                for width: CGFloat in [280, 330, 400] {
                    let scenarios: [(kind: String, count: Int, framed: Bool)] = (1...6).map { ("line", $0, true) }
                        + [("bar", 1, false), ("line", 1, false), ("bar", 3, true), ("stacked", 6, true)]
                    for scenario in scenarios {
                        let count = scenario.count, kind = scenario.kind
                        let names = (0..<count).map { $0 == 0 ? "中国" : "很长的中文系列名称第\($0)组" }
                        let matrix = (0..<count).map { i in [Double(i) - 4, 5, -2, 5] }
                        let theme = MUChartTheme.current(for: palette)
                        let probe = ChartProbe()
                        let title = "中国保持增长"
                        let subtitle = "实际GDP同比增速，%，2019–24"
                        let source = "来源：渲染回归示意数据"
                        let view = MUMultiChartBody(look: theme.look, kind: kind,
                            labels: ["19", "20", "22", "24"], series: names, matrix: matrix,
                            title: title, subtitle: subtitle, source: source, unit: "%", highlight: ["中国"], framed: scenario.framed)
                            .onPreferenceChange(MUChartRenderGeometryKey.self) { probe.geometry = $0 }
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let id = "\(palette.isEmpty ? "system" : palette)-\(Int(width))-\(kind)-\(count)-\(scenario.framed)-\(dark ? "dark" : "light")"
                        let host = UIHostingController(rootView: view)
                        host.overrideUserInterfaceStyle = dark ? .dark : .light
                        host.view.backgroundColor = dark ? .black : .white
                        let parent = window!.rootViewController!
                        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
                        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                        host.view.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
                        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
                        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
                            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                        }
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
        let report = measurements.joined(separator: "\n") + "\nCHART_RENDER_METRICS maxPaddingDifference=\(maxPaddingDifference) minLabelAxisGap=\(minGap) maxHeightDifference=\(maxHeightDifference)\n"
        try! report.write(to: output.appendingPathComponent("pixel-measurements.log"), atomically: true, encoding: .utf8)
        print(report)
        print("CHART_RENDER_\(failed == 0 ? "PASS" : "FAIL") checks=\(passed) failures=\(failed) png=\(measurements.count)")
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
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
        func ink(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return (0..<3).map { abs(Int(bytes[i + $0]) - Int(bytes[bg + $0])) }.max()! > 24
        }
        func extent(_ rect: CGRect) -> (Int?, Int?) {
            let x0 = max(0, Int(ceil(rect.minX * scale))), x1 = min(w, Int(ceil(rect.maxX * scale)))
            let y0 = max(0, Int(ceil(rect.minY * scale))), y1 = min(h, Int(ceil(rect.maxY * scale)))
            guard x1 > x0, y1 > y0 else { return (nil, nil) }
            var lo: Int?, hi: Int?
            for x in x0..<x1 {
                for y in y0..<y1 where ink(x, y) {
                    lo = min(lo ?? x, x); hi = max(hi ?? x, x); break
                }
            }
            return (lo, hi)
        }
        let plot = extent(g.plot.insetBy(dx: -1, dy: 1))
        let axisRect = CGRect(x: g.axisColumn.minX - 0.5, y: g.plot.minY - 16,
                              width: g.axisColumn.width + 1, height: g.plot.height + 15)
        let axis = extent(axisRect)
        let label = extent(g.labelColumn)
        let left = plot.0.map { CGFloat($0) / scale }
        let right = axis.1.map { g.panelWidth - CGFloat($0 + 1) / scale }
        let gap: CGFloat?
        if let a = axis.0, let l = label.1 { gap = CGFloat(a - l - 1) / scale } else { gap = nil }
        return (left, right, gap)
    }
}
