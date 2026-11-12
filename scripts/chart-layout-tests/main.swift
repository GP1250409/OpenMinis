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

print("CHART_LAYOUT_PASS checks=\(passed)")
if failed > 0 {
    print("CHART_LAYOUT_FAILED \(failed)")
    exit(1)
}
