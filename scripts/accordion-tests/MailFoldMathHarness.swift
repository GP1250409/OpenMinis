import Foundation

// [T-sidebar-mail-fold] Linux-runnable harness for the SHIPPING Mail-fold
// geometry. `scripts/accordion-tests/mail_fold_linux_check.py` compiles the
// real `enum AccordionMemberFold` block out of AccordionCollectionLayout.swift
// (not a copy) with this file, so the fold's math can be checked without a
// macOS simulator. The UIKit end of the same contract (cells, real 60 Hz
// frames, clipping) lives in MailFoldTests.swift.
var passed = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { print("FAIL: \(name)"); exit(2) }
    passed += 1
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.0001) -> Bool { abs(a - b) <= tol }

let rowH: CGFloat = 68

/// A section's member window endpoints, as the layout computes them.
func window(count: Int, blockTop: CGFloat, p: CGFloat) -> (top: CGFloat, bottom: CGFloat, h: CGFloat) {
    let h = AccordionMemberFold.windowHeight(count: count, rowHeight: rowH, progress: p)
    return (blockTop, blockTop + h, h)
}

// --- 1. endpoints ----------------------------------------------------------
let blockTop: CGFloat = 336          // label 32 + header 68 above a 236pt start
let count = 5
for row in 0..<count {
    let slice = AccordionMemberFold.slice(row: row, count: count, rowHeight: rowH, blockTop: blockTop, progress: 1)
    check(near(slice.y, blockTop + CGFloat(row) * rowH) && near(slice.height, rowH) && slice.clipTop == 0 && slice.isVisible,
          "expanded endpoint row \(row) keeps the shipped full-pitch layout")
    let folded = AccordionMemberFold.slice(row: row, count: count, rowHeight: rowH, blockTop: blockTop, progress: 0)
    check(!folded.isVisible && folded.height == 0, "folded endpoint row \(row) draws nothing")
}
// Clamped progress: out-of-range values cannot stretch a row.
check(AccordionMemberFold.slice(row: 0, count: count, rowHeight: rowH, blockTop: blockTop, progress: 3).clipTop == 0,
      "progress > 1 clamps to the expanded endpoint")
check(!AccordionMemberFold.slice(row: 0, count: count, rowHeight: rowH, blockTop: blockTop, progress: -2).isVisible,
      "progress < 0 clamps to the folded endpoint")

// --- 2. the moving block: bottom edge, stable gap, both directions ----------
let footer: CGFloat = 4
for p: CGFloat in [0.02, 0.1, 0.26, 0.5, 0.73, 0.85, 0.99, 0.5, 0.26, 0.02] {
    let w = window(count: count, blockTop: blockTop, p: p)
    let slices = (0..<count).map { AccordionMemberFold.slice(row: $0, count: count, rowHeight: rowH, blockTop: blockTop, progress: p) }
    let last = slices[count - 1]
    check(near(last.y + last.height, w.bottom), "p=\(p) last member bottom is welded to the moving bottom edge")
    check(near(last.y + last.height + footer, w.bottom + footer), "p=\(p) lower sibling keeps the footer gap")
    var visible: [Int] = []
    for (row, slice) in slices.enumerated() where slice.isVisible {
        visible.append(row)
        check(slice.height <= rowH + 0.0001, "p=\(p) row \(row) never grows past its row height")
        check(near(slice.height, rowH - slice.clipTop), "p=\(p) row \(row) keeps its full frame, clip is the only loss")
        check(slice.y >= blockTop - 0.0001, "p=\(p) row \(row) never draws above the header")
        check(slice.y + slice.height <= w.bottom + 0.0001, "p=\(p) row \(row) never draws below the block")
        if slice.clipTop > 0.0001 {
            check(near(slice.y, blockTop), "p=\(p) row \(row) clips AT the header")
            check(row == visible.first!, "p=\(p) only the first visible row is clipped")
        }
    }
    check(visible == Array((count - visible.count)..<count),
          "p=\(p) visible members are the trailing rows (last child appears first)")
    check(visible.count == AccordionMemberFold.visibleRows(count: count, rowHeight: rowH, progress: p).count
          || p > 0.999, "p=\(p) visibleRows agrees with the slices")
}
// Last member first on open, first member last.
check(!AccordionMemberFold.slice(row: 0, count: count, rowHeight: rowH, blockTop: blockTop, progress: 0.05).isVisible,
      "opening at p=0.05 has not reached the first member yet")
let firstSlice = AccordionMemberFold.slice(row: 0, count: count, rowHeight: rowH, blockTop: blockTop, progress: 0.85)
check(firstSlice.isVisible && firstSlice.clipTop > 1 && firstSlice.clipTop < rowH,
      "at p=0.85 the first member is a clipped slice under the header")
check(AccordionMemberFold.slice(row: 4, count: count, rowHeight: rowH, blockTop: blockTop, progress: 0.85).clipTop == 0,
      "the last member is already full height by then")

// --- 3. non-first member translates monotonically --------------------------
for row in [1, 2, 3] {
    var previous: CGFloat = -1e9
    for step in 0...100 {
        let p = CGFloat(step) / 100
        let y = AccordionMemberFold.slice(row: row, count: count, rowHeight: rowH, blockTop: blockTop, progress: p).y
        check(y >= previous - 0.0001, "row \(row) translates down while opening (p=\(p))")
        previous = y
    }
    previous = 1e9
    for step in stride(from: 100, through: 0, by: -1) {
        let p = CGFloat(step) / 100
        let y = AccordionMemberFold.slice(row: row, count: count, rowHeight: rowH, blockTop: blockTop, progress: p).y
        check(y <= previous + 0.0001, "row \(row) translates up while closing (p=\(p))")
        previous = y
    }
}

// --- 4. date buckets (Pinned / Recent): label bottom is the header line -----
let bucketTop: CGFloat = 32
for p: CGFloat in [0.15, 0.5, 0.8] {
    let slices = (0..<3).map { AccordionMemberFold.slice(row: $0, count: 3, rowHeight: rowH, blockTop: bucketTop, progress: p) }
    check(near(slices[2].y + slices[2].height, bucketTop + 3 * rowH * p),
          "date bucket p=\(p) last member follows the label bottom")
    if p < 0.999 {
        check(!slices[0].isVisible || near(slices[0].y, bucketTop), "date bucket p=\(p) clips at its own label")
    }
}

// --- 5. enumeration bounds --------------------------------------------------
let mid = AccordionMemberFold.rowBounds(in: CGRect(x: 0, y: 0, width: 390, height: 4000), count: count,
                                       rowHeight: rowH, blockTop: blockTop,
                                       blockBottom: blockTop + CGFloat(count) * rowH * 0.5)!
check(mid.lowerBound <= 2 && mid.upperBound >= 4, "p=0.5 bounds cover the three touching members")
for row in mid {
    let slice = AccordionMemberFold.slice(row: row, count: count, rowHeight: rowH, blockTop: blockTop, progress: 0.5)
    check(slice.isVisible, "enumerated row \(row) is visible at p=0.5")
}
check(mid.lowerBound > 0, "rows scrolled behind the header are not enumerated")
check(AccordionMemberFold.rowBounds(in: CGRect(x: 0, y: 5000, width: 390, height: 844), count: count,
                                    rowHeight: rowH, blockTop: blockTop,
                                    blockBottom: blockTop + CGFloat(count) * rowH * 0.5) == nil,
      "a viewport below the block enumerates no member")
let huge = AccordionMemberFold.rowBounds(in: CGRect(x: 0, y: 120000, width: 390, height: 844), count: 4700,
                                         rowHeight: rowH, blockTop: 100,
                                         blockBottom: 100 + 4700 * rowH)!
check(huge.count < 25, "deep scroll in a 4700-row folder bounds to the viewport, got \(huge.count)")
check(AccordionMemberFold.visibleRows(count: 4700, rowHeight: rowH, progress: 0).isEmpty,
      "a folded 4700-row folder has no visible member")
check(AccordionMemberFold.visibleRows(count: 4700, rowHeight: rowH, progress: 1).count == 4700,
      "an expanded folder still enumerates every member on request")

print("MAILFOLD_MATH_PASS \(passed)")
