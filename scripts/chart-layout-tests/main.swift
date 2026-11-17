// Chart layout / emphasis regression tests.
//
// Compiles the PRODUCTION file `src/ios/Views/Chat/AIChatView/MinisUI/MinisUICore.swift`
// (pure Foundation) together with this harness, so the rules below are exercised
// as shipped code, not as a model of it. Run by scripts/chart_layout_regression.py.
//
// Covers the three defects reported on device with a 三国 GDP 折线图:
//   1. the highlighted series took its colour from its row index (China, third
//      row, became salmon/gold instead of the accent),
//   2. end-of-line labels ran into the right-hand axis numbers,
//   3. labels of lines with close end values overlapped each other.

import Foundation

var passed = 0
var failed = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("PASS: \(name)")
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-9) -> Bool { abs(a - b) <= tol }

// MARK: - 1. Emphasis roles

let three = ["美国", "日本", "中国"]

let r0 = MUChartEmphasis.roles(series: three, highlight: [])
check(r0 == [.normal, .normal, .normal], "no highlight: every series keeps its palette colour")

let r1 = MUChartEmphasis.roles(series: three, highlight: ["中国"])
check(r1 == [.context, .context, .emphasis(0)], "highlight 中国 (row 3/3) gets accent slot 0, others grey")

let r2 = MUChartEmphasis.roles(series: three, highlight: ["中国", "美国"])
check(r2 == [.emphasis(0), .context, .emphasis(1)], "two highlights are ranked by DATA order, not by the highlight array order")
let r2b = MUChartEmphasis.roles(series: three, highlight: ["美国", "中国"])
check(r2 == r2b, "reordering the highlight array draws the same chart")

let five = ["A", "B", "C", "D", "E"]
let r3 = MUChartEmphasis.roles(series: five, highlight: ["A", "B", "C", "D"])
check(r3 == [.emphasis(0), .emphasis(1), .emphasis(2), .normal, .context],
      "fourth highlight keeps its palette colour instead of turning grey")
check(MUChartEmphasis.usedSlots(r3) == 3, "three distinct accent slots in use")

let r4 = MUChartEmphasis.roles(series: three, highlight: ["2020", "2021"])
check(r4 == [.normal, .normal, .normal], "label-only highlight does not grey any series")
check(!MUChartEmphasis.hasEmphasis(r4), "label-only highlight reports no series emphasis")

let r5 = MUChartEmphasis.roles(series: ["中美", "中美"], highlight: ["中美"])
check(r5 == [.emphasis(0), .emphasis(1)], "duplicate series names both resolve deterministically")

let r6 = MUChartEmphasis.roles(series: three, highlight: ["中国 GDP"])
check(r6 == [.normal, .normal, .normal], "unknown highlight text cannot grey anything")

check(MUChartEmphasis.roles(series: [], highlight: ["中国"]).isEmpty,
      "single-series charts (no series list) have no series roles")

let marks = MUChartBarMarks.marked(labels: ["2019", "2020", "2021"], highlight: ["2020"])
check(marks == [false, true, false], "one-series bar highlight marks exactly the named labels")

// MARK: - 2. Y domain

let gdp: [[Double]] = [[2.3, 2.0, 1.9, 1.6, 1.4], [0.3, -0.1, 0.1, -0.2, 0.2], [6.1, 5.9, 3.1, 5.2, 4.9]]
let d1 = MUChartAxis.domain(values: gdp, includeZero: false)
check(gdp.flatMap { $0 }.allSatisfy { $0 >= d1.lower && $0 <= d1.upper }, "line domain brackets every value")
check(d1.span > 0, "line domain has a positive span")
check(d1.lower < -0.2 && d1.upper > 6.1, "line domain keeps headroom on both ends")

let d2 = MUChartAxis.domain(values: gdp, includeZero: true)
check(d2.lower <= 0 && d2.upper >= 6.1, "bar domain includes zero and the maximum")

let d3 = MUChartAxis.domain(values: [[4.0, 4.0, 4.0]], includeZero: false)
check(d3.span > 0.5 && 4.0 > d3.lower && 4.0 < d3.upper, "constant series gets a non-degenerate domain")

let stacked: [[Double]] = [[1, 2, 3], [2, 2, 2]]
let ds = MUChartAxis.stackedDomain(matrix: stacked)
check(ds.upper >= 5.0 && ds.lower <= 0, "stacked domain covers per-column totals (3+2), not a single segment")

let dn = MUChartAxis.stackedDomain(matrix: [[1, -4], [-2, 2]])
check(dn.lower <= -6 && dn.upper >= 3, "stacked domain covers negative totals too")

check(near(MUChartAxis.niceStep(0.9), 1) && near(MUChartAxis.niceStep(1.7), 2)
      && near(MUChartAxis.niceStep(2.4), 2.5) && near(MUChartAxis.niceStep(4.1), 5)
      && near(MUChartAxis.niceStep(7.0), 10) && near(MUChartAxis.niceStep(0.031), 0.05),
      "nice axis steps are 1/2/2.5/5/10 × 10^n")

let yTop = MUChartAxis.pixelY(d1.upper, domain: d1, height: 180)
let yBottom = MUChartAxis.pixelY(d1.lower, domain: d1, height: 180)
check(near(yTop, 0, 1e-6) && near(yBottom, 180, 1e-6), "pixel mapping: domain max is the top edge, min the bottom")
check(MUChartAxis.pixelY(6.1, domain: d1, height: 180) < MUChartAxis.pixelY(2.0, domain: d1, height: 180),
      "pixel mapping is monotone: a larger value sits higher")

// MARK: - 3. End-of-line label placement

let closeValues = [2.0, 1.1, 4.9]
let layout = MUChartEndLabels.layout(values: closeValues, domain: d1, plotHeight: 180)
check(layout.count == 3, "one placement per series")
func gaps(_ p: [MUChartEndLabels.Placement]) -> [CGFloat] {
    let ys = p.sorted { $0.centerY < $1.centerY }.map { $0.centerY }
    return zip(ys.dropFirst(), ys).map { $0 - $1 }
}
check(gaps(layout).allSatisfy { $0 >= 12 - 1e-6 }, "labels of close end values are at least 12pt apart")
check(layout.allSatisfy { $0.centerY >= 7 - 1e-6 && $0.centerY <= 173 + 1e-6 }, "labels stay inside the plot")

let equalValues = [3.0, 3.0, 3.0]
let equalLayout = MUChartEndLabels.layout(values: equalValues, domain: MUChartAxis.domain(values: [[3.0]], includeZero: false), plotHeight: 180)
check(gaps(equalLayout).allSatisfy { $0 >= 12 - 1e-6 }, "identical end values are stacked, not overlapped")

let six = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
let sixLayout = MUChartEndLabels.layout(values: six, domain: MUChartAxis.domain(values: [six], includeZero: false), plotHeight: 180)
check(gaps(sixLayout).allSatisfy { $0 >= 12 - 1e-6 }, "six labels in 180pt keep their gaps")
check(sixLayout.allSatisfy { $0.centerY >= 7 && $0.centerY <= 173 }, "six labels stay inside 180pt")

let dense = [10.0, 10.05, 10.1, 10.15, 10.2, 10.25]
let denseLayout = MUChartEndLabels.layout(values: dense, domain: MUChartAxis.domain(values: [dense], includeZero: false), plotHeight: 180)
check(gaps(denseLayout).allSatisfy { $0 >= 12 - 1e-6 }, "a 0.25-unit cluster of six labels is pushed apart")
check(denseLayout.allSatisfy { $0.centerY >= 7 && $0.centerY <= 173 }, "the pushed cluster stays inside the plot")

// Order must follow the values: a label never crosses a neighbour.
func orderOfValues(_ values: [Double], _ p: [MUChartEndLabels.Placement]) -> [Int] {
    let byValue = values.enumerated().sorted { $0.element > $1.element }.map { $0.offset }
    let byPixel = p.sorted { $0.centerY < $1.centerY }.map { $0.index }
    return byValue == byPixel ? [] : byValue
}
check(orderOfValues(closeValues, layout).isEmpty, "vertical order matches value order (no crossed labels)")
check(orderOfValues(dense, denseLayout).isEmpty, "dense cluster keeps value order")

let negative = [-8.0, -3.0, 2.0]
let negDomain = MUChartAxis.domain(values: [negative], includeZero: true)
let negLayout = MUChartEndLabels.layout(values: negative, domain: negDomain, plotHeight: 180)
check(negLayout.count == 3 && negLayout.allSatisfy { $0.centerY >= 7 && $0.centerY <= 173 },
      "negative end values get labels inside the plot")
check(orderOfValues(negative, negLayout).isEmpty, "negative values keep their vertical order")

let single = MUChartEndLabels.layout(values: [4.9], domain: d1, plotHeight: 180)
check(single.count == 1 && near(single[0].dy, 0, 1e-6), "a single label sits exactly on its point")

let again = MUChartEndLabels.layout(values: closeValues, domain: d1, plotHeight: 180)
check(again == layout, "placement is deterministic across calls")

check(layout.allSatisfy { abs($0.dy) <= 180 }, "displacements stay within the plot height")

// MARK: - 4. Trailing gutter for the labels

let cjk = MUChartLabelMetrics.width("中国", fontSize: 10)
let ascii = MUChartLabelMetrics.width("US", fontSize: 10)
check(cjk > ascii + 4, "CJK names are wider than ASCII names of the same length")
check(MUChartLabelMetrics.width("中国", fontSize: 11) > cjk, "width grows with the font size")
check(MUChartLabelMetrics.width("", fontSize: 10) > 0, "an empty label still reports a positive width")

let g1 = MUChartLabelMetrics.gutter(labels: three, fontSize: 10, available: 310)
let widest = three.map { MUChartLabelMetrics.width($0, fontSize: g1.fontSize) }.max() ?? 0
check(!g1.truncated && g1.fontSize == 10, "three short Chinese names fit at 10pt on a phone card")
check(g1.width >= widest + 3 + 6 - 1e-6, "gutter covers the widest label + spacing + safety gap")
check(g1.width <= max(56, 310 * 0.42) + 1e-6, "gutter never eats more than 42% of the card")

let longNames = ["中国（大陆）", "美国", "欧元区十九国"]
let g2 = MUChartLabelMetrics.gutter(labels: longNames, fontSize: 10, available: 200)
check(g2.width <= max(56, 200 * 0.42) + 1e-6, "narrow card caps the gutter")
check(g2.labels.count == longNames.count, "every series keeps a label when the gutter is capped")
check(g2.labels.allSatisfy { MUChartLabelMetrics.width($0, fontSize: g2.fontSize) <= g2.width - 3 - 6 + 1 },
      "after shrinking/truncating every label fits inside the gutter")
check(g2.labels != longNames ? g2.truncated : true, "truncation flag reflects the fitted labels")
check(g2.labels.allSatisfy { !$0.isEmpty }, "truncation never produces an empty label")

let g3 = MUChartLabelMetrics.gutter(labels: ["美", "日", "中"], fontSize: 10, available: 320)
check(g3.fontSize == 10 && !g3.truncated, "short one-character names stay at the base size")

let g4 = MUChartLabelMetrics.gutter(labels: [], fontSize: 10, available: 320)
check(g4.width == 0 && !g4.truncated, "no labels means no reserved gutter")


// MARK: - 5. [T-chart-label-physical] The gutter is MEASURED, not estimated
//
// The device screenshot of build 8ec8992 showed "中国" (bold, 10pt) ending on
// the axis "5": the per-Unicode-class estimate was narrower than the rendered
// glyphs, so the nominal 6pt gap was gone. The view now passes real widths in;
// what is asserted here is the invariant the drawing relies on:
//   gutter.width == labelWidth + spacing + gap, and the label BOX (not the
//   glyphs) is what the layout places, so the strip between the box and the
//   axis is at least `gap`.
let realCJK: [CGFloat] = [26.4, 24.0, 25.7]      // 美国 / 日本 / 中国 at 10pt bold-ish
let gm = MUChartLabelMetrics.gutter(labels: three, fontSize: 10, available: 310, widths: realCJK)
check(near(gm.labelWidth, 26.4), "the reserved label box is the MEASURED widest label")
check(near(gm.width, 26.4 + 3 + 10), "gutter = label box + annotation spacing + 10pt gap")
check(gm.width - gm.labelWidth - 3 >= 10 - 1e-6, "at least 10pt of blank strip before the axis")
check(gm.truncated == false && gm.labels == three, "measured widths never truncate a name that fits")

// One to six series, all long Chinese names: every one gets a box of the same
// width, and the strip to the axis is never smaller than the gap.
for n in 1...6 {
    let names = (0..<n).map { "系列名称\($0)很长" }
    let widths = names.map { CGFloat($0.count) * 10.6 }
    let g = MUChartLabelMetrics.gutter(labels: names, fontSize: 10, available: 320, widths: widths)
    check(g.labels.count == n && g.labelWidth > 0, "\(n) long CJK series: every series keeps a label box")
    check(g.width >= g.labelWidth + 3 + 10 - 1e-6 || g.truncated,
          "\(n) long CJK series: the gutter still holds the box plus the gap (or truncates)")
    check(g.labelWidth <= g.width - 3 + 1e-6, "\(n) long CJK series: the box never exceeds the gutter")
}
// A narrow card: the box shrinks with the font, and the gap survives.
let narrow = MUChartLabelMetrics.gutter(labels: three, fontSize: 10, available: 150, widths: realCJK)
check(narrow.width <= max(56, 150 * 0.42) + 1e-6, "narrow card: the gutter stays within its cap")
check(narrow.labelWidth <= narrow.width - 3 - 10 + 1e-6 || narrow.truncated,
      "narrow card: the label box still leaves the gap (shrunk or truncated otherwise)")

// The vertical layout now takes the REAL mark positions; equal and negative end
// values must still be separated, in the order of the values.
let negValues: [Double] = [-2.5, -2.5, 4.0]
let nd = MUChartAxis.domain(values: [negValues], includeZero: true)
let baseY: [CGFloat] = negValues.map { MUChartAxis.pixelY($0, domain: nd, height: 180) }
let negPlaced = MUChartEndLabels.layout(values: negValues, domain: nd, plotHeight: 180,
                                        minGap: 13, edgeInset: 7.5, baseY: baseY)
check(negPlaced.count == 3, "negative and equal end values all get a placement")
let byValue = negPlaced.sorted { $0.centerY < $1.centerY }        // top first
check(byValue.map(\.index) == [2, 0, 1],
      "placements keep the order of the values (top = larger value, ties by series)")
check(zip(byValue, byValue.dropFirst()).allSatisfy { $1.centerY - $0.centerY >= 13 - 1e-6 },
      "equal end values are pushed apart by the minimum gap")
check(negPlaced.allSatisfy { $0.centerY >= 7.5 - 1e-6 && $0.centerY <= 180 - 7.5 + 1e-6 },
      "no label leaves the plot's vertical inset")

// MARK: - 6. [T-card-surface] Every Card keeps its own panel
//
// Charts, maps, text and interactive output all share the original Card
// plane. Only internal chart/map panels are transparent.
func node(_ name: String, _ children: [MUComp] = [], _ extra: [String: MUValue] = [:]) -> MUComp {
    var props: [String: MUValue] = extra
    if !children.isEmpty { props["children"] = .arr(children.map { .comp($0) }) }
    return MUComp(name: name, props: props, line: 1)
}
func text(_ s: String) -> MUComp { node("Text", [], ["text": .str(s)]) }
func series(_ names: [String]) -> [MUValue] { names.map { .str($0) } }

let chart = node("MultiChart", [], ["kind": .str("line"), "labels": .arr(series(["2019", "2020"])),
                                    "series": .arr(series(["中国", "美国"])),
                                    "values": .arr([.arr([.num(1), .num(2)]), .arr([.num(2), .num(3)])])])
let chartOnly = node("Card", [node("Title", [], ["text": .str("三国实际 GDP 增速")]), chart,
                              text("2020 年疫情冲击下三国同步失速。")],
                     ["title": .str("三国实际 GDP 增速")])
check(MUCardPlane.retainsOuterSurface(chartOnly), "a card of title + chart + explanation is chart-only content, not a transparent outer Card")

let nested = node("Card", [node("Stack", [chart])])
check(MUCardPlane.retainsOuterSurface(nested), "a chart inside Stack/Row wrappers is still chart output")

let withChoice = node("Card", [chart, node("Choice", [], ["value": .str("$a"),
                                                           "options": .arr(series(["是", "否"]))])])
check(MUCardPlane.retainsOuterSurface(withChoice), "a chart card with a Choice keeps its panel (it is interactive)")

let calculator = node("Card", [node("Segmented", [], ["value": .str("$op"), "options": .arr(series(["+", "-"]))]),
                               node("Slider", [], ["label": .str("a"), "value": .str("$a"), "min": .num(0), "max": .num(10)]),
                               text("结果：0")])
check(MUCardPlane.retainsOuterSurface(calculator), "the calculator / question card keeps its panel")

let withMetric = node("Card", [chart, node("Metric", [], ["label": .str("增速"), "value": .str("4.8%")])])
check(MUCardPlane.retainsOuterSurface(withMetric), "a KPI next to a chart keeps the universal Card surface")

let withTable = node("Card", [chart, node("Table", [], ["headers": .arr(series(["a"])), "rows": .arr([])])])
check(MUCardPlane.retainsOuterSurface(withTable), "a table next to a chart keeps the card surface")

let chartsOnly = node("Card", [chart, node("MultiChart")])
check(MUCardPlane.retainsOuterSurface(chartsOnly), "two charts and nothing else retain the shared outer Card plane")

check(MUCardPlane.retainsOuterSurface(node("Card", [text("只有文字")], ["title": .str("标题")])),
      "a text-only card keeps its panel like every other Card")

check(!MUCardPlane.retainsOuterSurface(chart), "a bare chart never manufactures a Card panel")

check(MUCardPlane.retainsOuterSurface(node("Card", [chart, node("Button", [], ["label": .str("好"), "action": .str("@x")])])),
      "a chart card with a button keeps its panel")

// MARK: - Phase 1 owned columns: widths, series counts, signs and collisions
for width: CGFloat in [280, 330, 400] {
    for count in 1...6 {
        for negative in [false, true] {
            let names = (0..<count).map { "非常长的中文系列名称第\($0)组" }
            let gutter = MUChartLabelMetrics.gutter(labels: names, fontSize: 12, available: width,
                spacing: 4, gap: 6, maxFraction: 0.36)
            let axis: CGFloat = negative ? 35 : 24
            let c = MUChartColumns.layout(width: width, labelWidth: gutter.labelWidth, axisWidth: axis)
            check(abs(c.plotMinX - c.rightInset) < 0.001, "owned equal insets w=\(width) n=\(count) neg=\(negative)")
            check(c.labelMinX - c.plotMaxX >= 4, "curve-label gap at least 4pt w=\(width) n=\(count) neg=\(negative)")
            check(c.axisMinX - c.labelMaxX >= 6, "label-axis gap at least 6pt w=\(width) n=\(count) neg=\(negative)")
            check(c.plotWidth >= 100 && c.axisMaxX <= width - 10, "long names leave usable plot w=\(width) n=\(count) neg=\(negative)")
            let values = [Double](repeating: negative ? -5 : 5, count: count)
            let d = MUChartAxis.domain(values: [values], includeZero: true)
            let p = MUChartEndLabels.layout(values: values, domain: d, plotHeight: 180, minGap: 15, edgeInset: 9)
            let sorted = p.map(\.centerY).sorted()
            check(zip(sorted, sorted.dropFirst()).allSatisfy { $1 - $0 >= 15 - 0.001 },
                "equal end values remain disjoint w=\(width) n=\(count) neg=\(negative)")
        }
    }
    let bar = MUChartColumns.layout(width: width, labelWidth: 0, axisWidth: 35)
    check(abs(bar.plotMinX - bar.rightInset) < 0.001 && bar.axisMinX - bar.plotMaxX >= 6,
          "bar and single series keep symmetric insets w=\(width)")
}
let phaseTitle = "中国保持增长"
let lineHeight = MUChartTypography.estimatedHeight(title: phaseTitle, subtitle: "同比增速，%", source: "来源：官方统计",
    seriesCount: 3, kind: "line", width: 330, framed: true)
let barHeight = MUChartTypography.estimatedHeight(title: phaseTitle, subtitle: "同比增速，%", source: "来源：官方统计",
    seriesCount: 3, kind: "bar", width: 330, framed: true)
check(barHeight - lineHeight == 40, "hidden line legend is removed from first-frame estimate")
check(MUChartTypography.plotHeight == 180, "plot height stays 180pt across all themes")
check(MUChartTypography.estimatedHeight(title: nil, subtitle: nil, source: nil, seriesCount: 0, kind: "line", width: 330, framed: false) == 222,
      "single-series estimate includes owned x axis and tick headroom")
check(MUChartAxis.ticks(domain: MUChartDomain(lower: -10, upper: 10)).contains(0), "cross-zero explicit ticks contain a zero baseline")

// Axis number boxes extend 7pt above/below the extreme grid lines. Keep
// existing plotTop/xAxisHeight reservations (no clamping or domain changes).
for domain in [MUChartDomain(lower: 0, upper: 10), MUChartDomain(lower: -10, upper: 0), MUChartDomain(lower: -10, upper: 10)] {
    for value in [domain.lower, domain.upper] {
        let gridY = MUChartAxis.pixelY(value, domain: domain, height: 180)
        let box = CGRect(x: 0, y: MUChartTypography.plotTop + gridY - 7, width: 35, height: 14)
        check(box.minY >= 0, "top tick box fits existing headroom \(domain) \(value)")
        check(box.maxY <= MUChartTypography.plotTop + 180 + MUChartTypography.xAxisHeight,
              "bottom tick box fits existing footroom \(domain) \(value)")
    }
}

// All previous chart-only cases now explicitly retain the universal Card plane.


for name in ["BarChart", "LineChart", "MultiChart", "BlockMap", "GeoMap", "Text", "Slider", "Button"] {
    check(MUCardPlane.retainsOuterSurface(node("Card", [node(name)])), "outer Card retained for \(name)")
    check(!MUCardPlane.retainsOuterSurface(node(name)), "bare \(name) adds no Card surface")
}
// Contrast is evaluated against actual sRGB, independently of appearance.
for bg in ["#FFFFFF", "#000000", "#F1EFEA", "#161B1F", "#7B83A0", "#B8D8C8"] {
    let surface=MUMapRGB(hex:bg)
    for raw in ["#E3120B", "#E62923", "#B6B6A9", "#007AFF", "#54C6D2", "#FFFFFF", "#000000", "#888888"] {
        let color=MUMapRGB(hex:raw)
        for minimum in [3.0, 4.5] {
            let result=color.readable(on:surface,minimum:minimum)
            check(result.contrast(on:surface) >= minimum, "sRGB contrast \(raw) on \(bg) >= \(minimum)")
            check(color.contrast(on:surface) < minimum || result == color, "valid brand/theme colour unchanged \(raw) on \(bg)")
            check(result.readable(on:surface,minimum:minimum) == result, "contrast adjustment idempotent")
        }
    }
    for style in ["", "economist", "economist2017"] {
        let original=MUMapTheme.resolve(style), adapted=original.adapted(to:surface)
        check(adapted.text.contrast(on:surface) >= 4.5 && adapted.muted.contrast(on:surface) >= 4.5, "map text actual surface contrast")
        check(adapted.accent.contrast(on:surface) >= 3, "map emphasis contrast")
        check(adapted.missing == original.missing && adapted.land == original.land && adapted.sea == original.sea, "map data/sea/missing remain distinct; outlines provide contrast")
    }
}
check(MUMapRGB(hex:"#FFFFFF").composited(over:MUMapRGB(hex:"#000000"),alpha:0.5) == MUMapRGB(hex:"#808080"), "alpha is composited rather than treated as opaque")
check(MUMapRGB(hex:"#000000").composited(over:MUMapRGB(hex:"#808080"),alpha:0.5) == MUMapRGB(hex:"#404040"), "nested surfaces compose recursively")

// MARK: - 4. Series identity palette, non-colliding style assignment & dark/surface adaptation

func resolvedColorHex(source: MUChartColorSource,
                      series: [MUChartColorPair],
                      accents: [MUChartColorPair],
                      context: MUChartColorPair,
                      on surface: MUMapRGB,
                      minimum: Double) -> String {
    let pair: MUChartColorPair
    switch source {
    case .accent(let slot): pair = accents[min(slot, accents.count - 1)]
    case .series(let idx): pair = series[idx % series.count]
    case .context: pair = context
    }
    return MUChartPaletteTokens.adapt(pair, on: surface, minimum: minimum).hex
}

func rgbDistance(_ a: MUMapRGB, _ b: MUMapRGB) -> Double {
    let (ar, ag, ab) = a.rgb, (br, bg, bb) = b.rgb
    let dr = (ar - br) * 255, dg = (ag - bg) * 255, db = (ab - bb) * 255
    return sqrt(dr * dr + dg * dg + db * db)
}

// 4.1 2017 dark red stand-in #A81829 intentionally preserved
check(MUChartPaletteTokens.guide2017Series[3].light == 0xA81829,
      "2017 dark red stand-in #A81829 remains unchanged")
check(MUChartPaletteTokens.recentSeries.count == 6,
      "recent Economist palette exposes 6 finite identity colours")

// 4.2 3-4 series get blue naturally (no >6 series rule) and default solid
let fourNames = ["Alpha", "Beta", "Gamma", "Delta"]
let fourPlain = MUChartEmphasis.styles(series: fourNames, highlight: [])
check(fourPlain.map(\.color) == [.series(0), .series(1), .series(2), .series(3)],
      "4-series plain chart uses red, salmon, dark blue, light blue (blue used without >6 gate)")
check(fourPlain.allSatisfy { !$0.isContextWeight && $0.boldLabel && !$0.usesDashByDefault },
      "4-series plain chart uses default solid lines without context weight")

// 4.3 Highlight counts 0/1/2/3/4 across 4-series and 6-series charts, plus order stability
let sixNames = ["S0", "S1", "S2", "S3", "S4", "S5"]
let highlightCases: [(String, [String], [String])] = [
    ("4s-hl0", fourNames, []),
    ("4s-hl1-head", fourNames, ["Alpha"]),
    ("4s-hl1-tail", fourNames, ["Delta"]),
    ("4s-hl2", fourNames, ["Beta", "Delta"]),
    ("4s-hl3", fourNames, ["Alpha", "Gamma", "Delta"]),
    ("4s-hl4", fourNames, fourNames),
    ("6s-hl0", sixNames, []),
    ("6s-hl1", sixNames, ["S4"]),
    ("6s-hl2", sixNames, ["S1", "S5"]),
    ("6s-hl3", sixNames, ["S0", "S2", "S5"]),
    ("6s-hl4", sixNames, ["S1", "S2", "S4", "S5"]),
]

let themeConfigs: [(String, [MUChartColorPair], [MUChartColorPair], MUChartColorPair, [Int?])] = [
    ("recent", MUChartPaletteTokens.recentSeries, MUChartPaletteTokens.recentAccents, MUChartPaletteTokens.recentContext, MUChartPaletteTokens.recentAccentOccupiedSeries),
    ("guide2017", MUChartPaletteTokens.guide2017Series, MUChartPaletteTokens.guide2017Accents, MUChartPaletteTokens.guide2017Context, MUChartPaletteTokens.guide2017AccentOccupiedSeries),
]

for (label, sNames, hl) in highlightCases {
    let reversedHl = Array(hl.reversed())
    for (tName, tSeries, tAccents, tContext, tOcc) in themeConfigs {
        let st = MUChartEmphasis.styles(series: sNames, highlight: hl, paletteCount: tSeries.count, accentOccupiedSeries: tOcc)
        let stRev = MUChartEmphasis.styles(series: sNames, highlight: reversedHl, paletteCount: tSeries.count, accentOccupiedSeries: tOcc)
        check(st == stRev, "\(tName) \(label): style assignment independent of highlight array order")
        check(st.allSatisfy { !$0.usesDashByDefault }, "\(tName) \(label): default solid lines never auto-dashed")
        let nonHl = st.enumerated().filter { !hl.contains(sNames[$0.offset]) }.map(\.element)
        check(nonHl.allSatisfy { $0.color != .context },
              "\(tName) \(label): non-highlighted named series keep independent identity colours instead of collapsing to context grey")
        if !hl.isEmpty {
            let hlIdx = st.indices.filter { hl.contains(sNames[$0]) }
            check(hlIdx.allSatisfy { st[$0].isEmphasized && !st[$0].isContextWeight && st[$0].boldLabel },
                  "\(tName) \(label): all highlighted series including >3 stay emphasised")
        }
        // Check actual resolved colours never collide in light or dark mode
        for bg in ["#FFFFFF", "#F0EEE6", "#000000", "#262624", "#30302E", "#383836"] {
            let surf = MUMapRGB(hex: bg)
            let lineHexes = st.map { resolvedColorHex(source: $0.color, series: tSeries, accents: tAccents, context: tContext, on: surf, minimum: 3.0) }
            let textHexes = st.map { resolvedColorHex(source: $0.color, series: tSeries, accents: tAccents, context: tContext, on: surf, minimum: 4.5) }
            check(Set(lineHexes).count == sNames.count, "\(tName) \(label) on \(bg): all line colours distinct")
            check(Set(textHexes).count == sNames.count, "\(tName) \(label) on \(bg): all label text colours distinct")
        }
    }
    // System theme non-collision & non-context-grey retention (index-level check)
    let sysSt = MUChartEmphasis.styles(series: sNames, highlight: hl, paletteCount: 6, accentOccupiedSeries: MUChartPaletteTokens.systemAccentOccupiedSeries)
    let sysNonHl = sysSt.enumerated().filter { !hl.contains(sNames[$0.offset]) }.map(\.element)
    check(sysNonHl.allSatisfy { $0.color != .context }, "system \(label): non-highlighted named series keep independent colours")
    let sysResolvedIndices = sysSt.map { style -> String in
        switch style.color {
        case .accent(0): return "idx0"
        case .accent(1): return "idx5"
        case .accent(let k): return "acc\(k)"
        case .series(let i): return "idx\(i)"
        case .context: return "ctx"
        }
    }
    check(Set(sysResolvedIndices).count == sNames.count, "system \(label): no slot collision between accents and regular series")
}

// 4.4 Explicit "other"/"其他" bucket uses context only when NOT highlighted
let withOther = ["中国", "美国", "日本", "其他"]
let otherPlain = MUChartEmphasis.styles(series: withOther, highlight: ["中国"])
check(otherPlain[0].color == .accent(0) && otherPlain[1].color == .series(1)
      && otherPlain[2].color == .series(2) && otherPlain[3].color == .context,
      "explicit other bucket receives context colour while named non-highlighted series stay independent")
let otherEmphasized = MUChartEmphasis.styles(series: withOther, highlight: ["其他"])
check(otherEmphasized[3].color == .accent(0) && otherEmphasized[3].isEmphasized,
      "explicit other bucket receives emphasis accent when highlighted")

// 4.5 Finite capacity overflow (>6 hypothetical caller) still avoids active accent slot
let sevenSeries = ["S0", "S1", "S2", "S3", "S4", "S5", "S6"]
let sevenStyles = MUChartEmphasis.styles(series: sevenSeries, highlight: ["S3"])
check(sevenStyles[3].color == .accent(0), "7-series overflow still honours highlight accent slot")
check(sevenStyles.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element.color != .series(0) },
      "7-series overflow skips occupied accent slot 0")

// 4.6 Dark mode & real surface contrast: lines >= 3.0 without collapsing pairs; labels >= 4.5 without collapsing pairs
let realSurfaces = ["#FFFFFF", "#F7F7F8", "#FAF9F5", "#F0EEE6", "#E6E4DD",
                    "#000000", "#161B1F", "#1C1C1E", "#262624", "#30302E", "#383836", "#2D3D35"]
for bg in realSurfaces {
    let surf = MUMapRGB(hex: bg)
    let isDark = surf.luminance < 0.179
    let recentLines = MUChartPaletteTokens.recentSeries.map { MUChartPaletteTokens.adapt($0, on: surf, minimum: 3.0) }
    let recentTexts = MUChartPaletteTokens.recentSeries.map { MUChartPaletteTokens.adapt($0, on: surf, minimum: 4.5) }
    check(recentLines.allSatisfy { $0.contrast(on: surf) >= 3.0 }, "recent line colours on \(bg) >= 3.0")
    check(recentTexts.allSatisfy { $0.contrast(on: surf) >= 4.5 }, "recent text colours on \(bg) >= 4.5")
    check(Set(recentLines.map(\.hex)).count == 6, "recent line colours stay 6/6 distinct on \(bg)")
    check(Set(recentTexts.map(\.hex)).count == 6, "recent text colours stay 6/6 distinct on \(bg)")
    // Hierarchical separation between pairs: red vs salmon, dark blue vs light blue, dark grey vs light grey
    check(rgbDistance(recentLines[0], recentLines[1]) >= 60, "recent line red vs salmon distance on \(bg)")
    check(rgbDistance(recentLines[2], recentLines[3]) >= 75, "recent line dark blue vs light blue distance on \(bg)")
    check(rgbDistance(recentLines[4], recentLines[5]) >= 75, "recent line dark grey vs light grey distance on \(bg)")
    check(rgbDistance(recentTexts[0], recentTexts[1]) >= 60, "recent text red vs salmon distance on \(bg)")
    check(rgbDistance(recentTexts[2], recentTexts[3]) >= 45, "recent text dark blue vs light blue distance on \(bg)")
    check(rgbDistance(recentTexts[4], recentTexts[5]) >= 60, "recent text dark grey vs light grey distance on \(bg)")
    if isDark {
        // Dark mode lines keep exact independent dark hexes without brightening collapse
        check(recentLines.map(\.hex) == ["#F04540", "#FFC0B0", "#5685EB", "#9AD0FF", "#8A8D8C", "#D6D8CF"],
              "dark mode recent line identity hexes preserved uncollapsed on \(bg)")
        check(recentLines[5].luminance - recentLines[4].luminance >= 0.35,
              "dark mode light grey stays substantially brighter than dark grey on \(bg)")
        check(recentTexts[5].luminance - recentTexts[4].luminance >= 0.25,
              "dark mode label light grey stays distinctly brighter than dark grey on \(bg)")
    }
    let guideLines = MUChartPaletteTokens.guide2017Series.map { MUChartPaletteTokens.adapt($0, on: surf, minimum: 3.0) }
    let guideTexts = MUChartPaletteTokens.guide2017Series.map { MUChartPaletteTokens.adapt($0, on: surf, minimum: 4.5) }
    check(guideLines.allSatisfy { $0.contrast(on: surf) >= 3.0 } && Set(guideLines.map(\.hex)).count == 6,
          "2017 line colours >= 3.0 and 6/6 distinct on \(bg)")
    check(guideTexts.allSatisfy { $0.contrast(on: surf) >= 4.5 } && Set(guideTexts.map(\.hex)).count == 6,
          "2017 text colours >= 4.5 and 6/6 distinct on \(bg)")
}

// MARK: - 7. [T-chart-x-axis] X-axis tick labels are placed, not stacked
//
// Device report (photo_B923E3B4): a 2026-09-02 … 09-16 date axis printed
// "9/15" and "9/16" on top of each other. The old rule kept every tick whose
// index was a multiple of ceil(n/5) PLUS the last tick, with a fixed
// min(44, width/3) box; nothing looked at the text width, so the forced last
// tick landed next to a stride tick and the two boxes overlapped.
func xNoOverlap(_ layout: MUChartXAxisLabels.Layout, gap: CGFloat, span: CGFloat) -> Bool {
    let placed = layout.placements
    let ordered = zip(placed, placed.dropFirst()).allSatisfy { $1.minX - $0.maxX >= gap - 1e-6 }
    let inside = placed.allSatisfy { $0.minX >= -1e-6 && $0.maxX <= span + 1e-6 && $0.width >= 0 }
    let ascending = placed.map(\.index) == placed.map(\.index).sorted()
    return ordered && inside && ascending
}
func xCenters(_ n: Int, _ span: CGFloat) -> [CGFloat] {
    n <= 1 ? [0] : (0..<n).map { CGFloat($0) * span / CGFloat(n - 1) }
}
func xWidths(_ texts: [String], _ size: CGFloat = 11) -> [CGFloat] {
    texts.map { MUChartLabelMetrics.width($0, fontSize: size) }
}

// The exact reported case: 15 daily dates on a phone-width plot.
let dateAxis = (2...16).map { "9/\($0)" }
let dateLayout = MUChartXAxisLabels.layout(centers: xCenters(dateAxis.count, 250),
                                           widths: xWidths(dateAxis), plotMinX: 0, plotMaxX: 250)
check(xNoOverlap(dateLayout, gap: 6, span: 250),
      "9/2…9/16 on a 250pt plot: no two date labels overlap")
check(dateLayout.placements.first?.index == 0 && dateLayout.placements.last?.index == dateAxis.count - 1,
      "the date axis keeps its first and last tick")
check(dateLayout.placements.count >= 3 && dateLayout.placements.count <= 6,
      "the date axis thins out instead of printing all 15 labels")
check(dateLayout.dropped.contains(12) && !dateLayout.dropped.contains(dateAxis.count - 1),
      "the tick next to the end (9/14) is the one that gets dropped, never the end (9/16)")
check(!dateLayout.placements.contains { a in dateLayout.placements.contains { b in
        a.index != b.index && abs(a.centerX - b.centerX) < max(a.width, b.width) } },
      "no two kept date labels share a centre band")

// Two ticks that used to collide on a narrow phone: 9/15 + 9/16.
for span: CGFloat in [60, 80, 120, 200] {
    let pair = ["9/15", "9/16"]
    let l = MUChartXAxisLabels.layout(centers: xCenters(2, span), widths: xWidths(pair),
                                      plotMinX: 0, plotMaxX: span)
    check(xNoOverlap(l, gap: 6, span: span), "9/15 + 9/16 never overlap at span \(span)")
    check(l.placements.map(\.index) == [0, 1], "9/15 + 9/16 both survive at span \(span)")
}

// Freeze the old algorithm against the new one on the reported axis: the
// stride tick 12 and the forced last tick 14 are 2 data steps apart, so the
// fixed 44pt boxes used to intersect.
let oldStep = max(1, Int(ceil(Double(dateAxis.count) / 5)))
let oldKept = (0..<dateAxis.count).filter { $0 % oldStep == 0 || $0 == dateAxis.count - 1 }
let oldBoxes = oldKept.map { i -> (CGFloat, CGFloat) in
    let x = xCenters(dateAxis.count, 250)[i]
    let clamped = min(max(x, 0 + 22), 250 - 22)
    return (clamped - 22, clamped + 22)
}
let oldCollides = zip(oldBoxes, oldBoxes.dropFirst()).contains { $1.0 - $0.1 < 0 }
check(oldCollides, "the previous fixed-44pt rule really did overlap on this axis (regression anchor)")
check(Set(dateLayout.placements.map(\.index)).isSubset(of: Set(0..<dateAxis.count)),
      "kept ticks are real data indices, in data order, with no invented label")

// Category axis with short labels keeps everything that fits.
let quarters = ["Q1", "Q2", "Q3", "Q4"]
let qLayout = MUChartXAxisLabels.layout(centers: xCenters(4, 300), widths: xWidths(quarters),
                                        plotMinX: 0, plotMaxX: 300)
check(qLayout.placements.map(\.index) == [0, 1, 2, 3] && !qLayout.truncated,
      "four short category labels all fit and are never truncated")
check(qLayout.dropped.isEmpty, "nothing is dropped when the labels fit")

// Long CJK dates on a narrow phone: keep both ends, truncate rather than overlap.
let cjkDates = ["2024年9月15日", "2024年10月15日"]
let cjkWidths = xWidths(cjkDates)
for span: CGFloat in [150, 180, 240] {
    let l = MUChartXAxisLabels.layout(centers: xCenters(2, span), widths: cjkWidths,
                                      plotMinX: 0, plotMaxX: span)
    check(xNoOverlap(l, gap: 6, span: span), "narrow CJK date ends never overlap at span \(span)")
    check(l.placements.count == 2, "narrow CJK date keeps BOTH ends at span \(span)")
    check(l.placements.allSatisfy { $0.width <= ceil(max(cjkWidths[0], cjkWidths[1])) + 1e-6 },
          "a shrink never widens a CJK box beyond its measured text at span \(span)")
    check(l.placements.allSatisfy { $0.width >= min(12, (span - 6) / 2) - 1e-6 },
          "a truncated CJK box keeps a readable minimum width at span \(span)")
}
let cjkNarrow = MUChartXAxisLabels.layout(centers: xCenters(2, 150), widths: cjkWidths,
                                          plotMinX: 0, plotMaxX: 150)
check(cjkNarrow.truncated, "a truncated CJK end is flagged as truncated")

// Degenerate strips: never blank, never inverted.
let tiny = MUChartXAxisLabels.layout(centers: [0], widths: [80], plotMinX: 0, plotMaxX: 20)
check(tiny.placements.count == 1 && tiny.placements[0].width <= 20 + 1e-6,
      "a single label wider than the plot is clamped to the plot, not dropped")
let none = MUChartXAxisLabels.layout(centers: [], widths: [], plotMinX: 0, plotMaxX: 200)
check(none.placements.isEmpty && none.dropped.isEmpty, "an empty axis produces no placements")
let one = MUChartXAxisLabels.layout(centers: [120], widths: [26], plotMinX: 0, plotMaxX: 240)
check(one.placements == [MUChartXAxisLabels.Placement(index: 0, minX: 107, width: 26)],
      "a single tick is centred on its mark")

// Matrix: every axis width, label width, count and density keeps the invariants.
for n in [1, 2, 3, 5, 8, 15, 23, 40] {
    for span: CGFloat in [60, 120, 200, 300, 500] {
        for textWidth: CGFloat in [8, 18, 26, 40, 64, 88] {
            let widths = [CGFloat](repeating: textWidth, count: n)
            let l = MUChartXAxisLabels.layout(centers: xCenters(n, span), widths: widths,
                                              plotMinX: 0, plotMaxX: span)
            check(!l.placements.isEmpty, "n=\(n) w=\(textWidth) span=\(span): the axis is never blank")
            check(xNoOverlap(l, gap: 6, span: span), "n=\(n) w=\(textWidth) span=\(span): no overlap")
            check(l.placements.first?.index == 0, "n=\(n) w=\(textWidth) span=\(span): first tick kept")
            if n > 1 && span >= 2 * textWidth + 6 {
                check(l.placements.last?.index == n - 1,
                      "n=\(n) w=\(textWidth) span=\(span): last tick kept when the ends fit")
            }
            check(l.placements.count <= 7,
                  "n=\(n) w=\(textWidth) span=\(span): density stays at the 6-tick cap plus the reserved end tick")
            check(Set(l.placements.map(\.index)).count == l.placements.count,
                  "n=\(n) w=\(textWidth) span=\(span): no duplicate tick")
            check(l.dropped.count + l.placements.count == n,
                  "n=\(n) w=\(textWidth) span=\(span): every tick is placed or reported as dropped")
        }
    }
}
let detA = MUChartXAxisLabels.layout(centers: xCenters(15, 250), widths: xWidths(dateAxis),
                                     plotMinX: 0, plotMaxX: 250)
let detB = MUChartXAxisLabels.layout(centers: xCenters(15, 250), widths: xWidths(dateAxis),
                                     plotMinX: 0, plotMaxX: 250)
check(detA == detB, "x-axis placement is deterministic across calls")
// A translated plot (Charts insets the strip) shifts every box by the same amount.
let shifted = MUChartXAxisLabels.layout(centers: xCenters(15, 250).map { $0 + 12 }, widths: xWidths(dateAxis),
                                        plotMinX: 12, plotMaxX: 262)
check(shifted.placements.map(\.index) == detA.placements.map(\.index)
      && zip(shifted.placements, detA.placements).allSatisfy { abs(($0.minX - 12) - $1.minX) < 1e-6 },
      "a plot inset shifts the tick boxes without changing which ticks are kept")

// MARK: - 8. [T-chart-interaction-theme] Callout colours come from the chart card
//
// Device report (photo_533C7419): the info box inside a card was filled with
// the CHAT accent, so it turned black/graphite under ChatGPT, clay under
// Claude and indigo under DeepSeek, while the data table right above it stayed
// neutral. The box now shares the table's ground token and takes only its
// semantic accent from the chart palette.
let calloutTones = ["info", "warning", "danger", "success"]
let lightCards = ["#FFFFFF", "#F7F7F8", "#FAF9F5", "#F0EEE6", "#EBF0FF"]
let darkCards = ["#1C1C1E", "#212121", "#262624", "#1E1F22", "#161B1F"]

check(MUChartInteractionTheme.accent("error") == MUChartInteractionTheme.danger
      && MUChartInteractionTheme.accent("caution") == MUChartInteractionTheme.warning
      && MUChartInteractionTheme.accent("ok") == MUChartInteractionTheme.success,
      "error/caution/ok aliases keep the info-warning-danger-success semantics")
check(MUChartInteractionTheme.accent("WARNING") == MUChartInteractionTheme.warning,
      "tone lookup is case-insensitive")
check(MUChartInteractionTheme.accent("whatever") == MUChartInteractionTheme.info,
      "an unknown tone falls back to the informational accent")

// Hue identity of the base tokens: blue info, amber warning, red danger, green success.
func channelOrder(_ c: MUMapRGB) -> (Double, Double, Double) { c.rgb }
for (name, pair) in [("info", MUChartInteractionTheme.info), ("warning", MUChartInteractionTheme.warning),
                     ("danger", MUChartInteractionTheme.danger), ("success", MUChartInteractionTheme.success)] {
    for dark in [false, true] {
        let (r, g, b) = channelOrder(pair.rgb(forDarkSurface: dark))
        switch name {
        case "info": check(b > r && b > g, "info stays blue in \(dark ? "dark" : "light")")
        case "warning": check(r > b && g > b, "warning stays amber in \(dark ? "dark" : "light")")
        case "danger": check(r > g && r > b, "danger stays red in \(dark ? "dark" : "light")")
        default: check(g > r && g > b, "success stays green in \(dark ? "dark" : "light")")
        }
    }
}
check(MUChartInteractionTheme.info.rgb(forDarkSurface: true) != MUChartInteractionTheme.info.rgb(forDarkSurface: false),
      "every tone carries an independent day/night pair")

for surfaceHex in lightCards + darkCards {
    let surface = MUMapRGB(hex: surfaceHex)
    let dark = surface.luminance < 0.179
    let panel = MUChartInteractionTheme.panel(on: surface)
    check(MUChartInteractionTheme.isDark(surface) == dark, "day/night is read from the real surface \(surfaceHex)")
    // The table ground adds no new hue: it is the card surface, deepened by a
    // neutral ink composite, so a warm (Claude), cool (DeepSeek) or dark card
    // keeps its own family instead of importing the chat accent.
    func hueSignature(_ c: MUMapRGB) -> [Double] {
        let (r, g, b) = c.rgb
        func sign(_ v: Double) -> Double { abs(v) < 0.004 ? 0 : (v > 0 ? 1 : -1) }
        return [sign(r - g), sign(g - b), sign(r - b)]
    }
    check(hueSignature(panel) == hueSignature(surface), "chart panel keeps the card's own hue on \(surfaceHex)")
    check(rgbDistance(panel, surface) <= 40, "chart panel is a neutral deepening of the card on \(surfaceHex)")
    if dark {
        check(panel.luminance > surface.luminance, "dark card: the panel lifts above the card \(surfaceHex)")
        check(panel.luminance < 0.30, "dark card: the panel stays dark \(surfaceHex)")
    } else {
        check(panel.luminance < surface.luminance, "light card: the panel sits below the card \(surfaceHex)")
        check(panel.luminance > 0.70, "light card: the panel stays light \(surfaceHex)")
    }
    var fills: [String] = []
    var accents: [String] = []
    for tone in calloutTones {
        let box = MUChartInteractionTheme.resolved(tone: tone, on: surface)
        fills.append(box.fill.hex); accents.append(box.accent.hex)
        check(box.isDark == dark, "\(tone) on \(surfaceHex): resolved scheme matches the surface")
        // Same family as the data table: the fill is the panel ground plus a
        // bounded accent wash, never a full-strength brand colour.
        check(rgbDistance(box.fill, panel) < rgbDistance(box.fill, MUChartInteractionTheme.accent(tone).rgb(forDarkSurface: dark)),
              "\(tone) on \(surfaceHex): the fill is closer to the table ground than to the raw accent")
        check(rgbDistance(box.fill, panel) <= 90, "\(tone) on \(surfaceHex): the accent wash stays bounded")
        // Contrast contract, measured on the real fill.
        check(box.accent.contrast(on: box.fill) >= 3.0 - 1e-9, "\(tone) on \(surfaceHex): icon/bar >= 3:1")
        check(box.text.contrast(on: box.fill) >= 7.0 - 1e-9, "\(tone) on \(surfaceHex): body text >= 7:1")
        check(box.muted.contrast(on: box.fill) >= 4.5 - 1e-9, "\(tone) on \(surfaceHex): secondary text >= 4.5:1")
        check(box.border.contrast(on: box.fill) > 1.0 && box.border.contrast(on: box.fill) < box.accent.contrast(on: box.fill),
              "\(tone) on \(surfaceHex): the border is a hairline, quieter than the icon")
        // Readability direction follows the scheme.
        if dark {
            check(box.text.luminance > 0.55, "\(tone) on \(surfaceHex): dark card uses light text")
        } else {
            check(box.text.luminance < 0.20, "\(tone) on \(surfaceHex): light card uses dark text")
        }
    }
    check(Set(fills).count == calloutTones.count, "the four tones are visually distinct on \(surfaceHex)")
    check(Set(accents).count == calloutTones.count, "the four accent colours stay distinct after adaptation on \(surfaceHex)")
}

// The same tone on a light and on a dark card of the SAME family must invert.
let lightBox = MUChartInteractionTheme.resolved(tone: "info", on: MUMapRGB(hex: "#FFFFFF"))
let darkBox = MUChartInteractionTheme.resolved(tone: "info", on: MUMapRGB(hex: "#1C1C1E"))
check(lightBox.fill != darkBox.fill && lightBox.accent != darkBox.accent && lightBox.text != darkBox.text,
      "info adapts independently for day and night cards")
check(lightBox.fill.luminance > 0.75 && darkBox.fill.luminance < 0.30,
      "info fill inverts between a white and a black card")

print("CHART_LAYOUT_PASS checks=\(passed)")
if failed > 0 {
    print("CHART_LAYOUT_FAILED \(failed)")
    exit(1)
}
