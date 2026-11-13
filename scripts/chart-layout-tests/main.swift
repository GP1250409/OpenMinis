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

// MARK: - 6. [T-chart-card-flat] Which card drops its own panel
//
// Chart output only (title / chart / explanation / dividers) draws flat: the
// chart's own panel is the surface. Anything the user can touch — a choice, a
// slider, a button, a table, a metric — keeps the card exactly as before.
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
check(MUCardPlane.isChartOnly(chartOnly), "a card of title + chart + explanation draws flat")

let nested = node("Card", [node("Stack", [chart])])
check(MUCardPlane.isChartOnly(nested), "a chart inside Stack/Row wrappers is still chart output")

let withChoice = node("Card", [chart, node("Choice", [], ["value": .str("$a"),
                                                           "options": .arr(series(["是", "否"]))])])
check(!MUCardPlane.isChartOnly(withChoice), "a chart card with a Choice keeps its panel (it is interactive)")

let calculator = node("Card", [node("Segmented", [], ["value": .str("$op"), "options": .arr(series(["+", "-"]))]),
                               node("Slider", [], ["label": .str("a"), "value": .str("$a"), "min": .num(0), "max": .num(10)]),
                               text("结果：0")])
check(!MUCardPlane.isChartOnly(calculator), "the calculator / question card keeps its panel")

let withMetric = node("Card", [chart, node("Metric", [], ["label": .str("增速"), "value": .str("4.8%")])])
check(!MUCardPlane.isChartOnly(withMetric), "a KPI next to a chart is not chart-only output")

let withTable = node("Card", [chart, node("Table", [], ["headers": .arr(series(["a"])), "rows": .arr([])])])
check(!MUCardPlane.isChartOnly(withTable), "a table next to a chart keeps the card surface")

let chartsOnly = node("Card", [chart, node("MultiChart")])
check(MUCardPlane.isChartOnly(chartsOnly), "two charts and nothing else still draw flat")

check(!MUCardPlane.isChartOnly(node("Card", [text("只有文字")], ["title": .str("标题")])),
      "a text-only card is not chart output (it keeps its panel)")

check(!MUCardPlane.isChartOnly(chart), "only a Card subtree is classified, never a bare chart")

check(!MUCardPlane.isChartOnly(node("Card", [chart, node("Button", [], ["label": .str("好"), "action": .str("@x")])])),
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
print("CHART_LAYOUT_PASS checks=\(passed)")
if failed > 0 {
    print("CHART_LAYOUT_FAILED \(failed)")
    exit(1)
}
