// [T-user-ask-anchor-clamp] Assertions for the SHIPPING ToggleAnchorMath block.
//
// This file is compiled TOGETHER with `build/ask-card-anchor/ProductionToggleAnchorMath.swift`,
// which the driver extracts verbatim from `MessageListLayout.swift` between the
// `// BEGIN ToggleAnchorMath` / `// END ToggleAnchorMath` markers. No copy of the
// algorithm lives here: every value below comes from the production code the app
// ships, so a wrong implementation cannot "pass itself".
//
// Prints `ASK_CARD_ANCHOR_MATH_PASS checks=<n>` when every assertion holds.
import Foundation

var checks = 0
var failures = 0

func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label) \(detail)")
    }
}
func f(_ x: CGFloat) -> String { String(format: "%.3f", Double(x)) }

print("\n1. an in-range toggle still holds the tapped row's top")
let holdPlan = ToggleAnchorMath.cardAnchorPlan(newMinY: 1200, anchorY: 200, minOffset: -100, maxOffset: 1600)
check("plan is holdTop", holdPlan == .holdTop(offset: 1000), "\(holdPlan)")
check("offset = newMinY - anchorY = 1000", f(holdPlan.offset) == "1000.000", f(holdPlan.offset))
check("not reported as clamped", !holdPlan.isClamped)

print("\n2. a collapse past the scroll range clamps to the LEGAL bottom (the recorded jump)")
// 200pt card above a COLLAPSED tool group, list at the bottom: after the
// collapse the scroll range ends 120pt earlier than the offset.
let clampPlan = ToggleAnchorMath.cardAnchorPlan(newMinY: 1200, anchorY: -400, minOffset: -100, maxOffset: 1480)
check("plan is clampedToBottom", clampPlan == .clampedToBottom(offset: 1480), "\(clampPlan)")
check("offset = maxOffset (inside the range, no padding invented)", f(clampPlan.offset) == "1480.000", f(clampPlan.offset))
check("reported as clamped (the caller must not claim the top was held)", clampPlan.isClamped)

print("\n3a. P0: content shorter than the viewport (maxOff < minOff) - only minOff is legal")
// newMinY=0, anchorY=200 -> ideal -200; minOff -100, maxOff -300 (content short).
// The old lo=min(minOff,maxOff)=-300 accepted -200, which is BELOW the legal floor.
let shortPlan = ToggleAnchorMath.cardAnchorPlan(newMinY: 0, anchorY: 200, minOffset: -100, maxOffset: -300)
check("plan is clampedToTop at the legal floor", shortPlan == .clampedToTop(offset: -100), "\(shortPlan)")
let shortPre = ToggleAnchorMath.preResizeOffset(idealOffset: -200, predictedMaxOffset: -300, minOffset: -100)
check("pre-write is the legal floor, not the negative max", f(shortPre) == "-100.000", f(shortPre))

print("\n3. short content clamps to the top limit, never negative")
let topPlan = ToggleAnchorMath.cardAnchorPlan(newMinY: 40, anchorY: 200, minOffset: 0, maxOffset: 0)
check("offset = 0", f(topPlan.offset) == "0.000", f(topPlan.offset))
check("reported as clamped", topPlan.isClamped)

print("\n4. the clamp is predicted BEFORE the resize, so it can animate")
check("collapse: pre-write lands on the predicted max",
      f(ToggleAnchorMath.preResizeOffset(idealOffset: 1600, predictedMaxOffset: 1480, minOffset: -100)) == "1480.000",
      f(ToggleAnchorMath.preResizeOffset(idealOffset: 1600, predictedMaxOffset: 1480, minOffset: -100)))
check("growth: pre-write leaves the offset alone",
      f(ToggleAnchorMath.preResizeOffset(idealOffset: 1600, predictedMaxOffset: 1720, minOffset: -100)) == "1600.000")
check("degenerate max<min resolves to the min limit",
      f(ToggleAnchorMath.preResizeOffset(idealOffset: 0, predictedMaxOffset: -50, minOffset: 0)) == "0.000")
check("predicted max = current max + height delta",
      f(ToggleAnchorMath.predictedMaxOffset(currentMaxOffset: 1600, heightDelta: -120)) == "1480.000")

print("\n5. the expansion reveal is untouched by the clamp work")
check("overflow 408, room 2 -> 2 (never above the visible top)",
      f(ToggleAnchorMath.revealShift(cellMinY: 1610, cellMaxY: 2660, visibleTop: 1600, visibleBottom: 2260)) == "2.000")
check("already visible -> 0",
      f(ToggleAnchorMath.revealShift(cellMinY: 1200, cellMaxY: 1500, visibleTop: 1000, visibleBottom: 1800)) == "0.000")

print("\n6. sweep: 4000 geometries, always legal, never moves more than required")
var bad = 0
var clamped = 0
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd(_ lo: Double, _ hi: Double) -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let u = Double(seed >> 11) / Double(1 << 53)
    return CGFloat(lo + (hi - lo) * u)
}
for _ in 0..<4000 {
    let content = rnd(0, 6000), viewport = rnd(200, 900)
    let minOff = -rnd(0, 120), maxOff = content - viewport + rnd(0, 160)
    let rowY = rnd(0, max(0, content - 1)), anchorY = rnd(-50, viewport + 50)
    let plan = ToggleAnchorMath.cardAnchorPlan(newMinY: rowY, anchorY: anchorY, minOffset: minOff, maxOffset: maxOff)
    // legal range: floor is ALWAYS minOff (independent audit P0)
    let lo = minOff, hi = max(minOff, maxOff)
    if plan.offset < lo - 0.001 || plan.offset > hi + 0.001 { bad += 1 }
    // A plan that is NOT clamped must actually equal the ideal top, otherwise
    // the "top held" claim in the log is a lie.
    if !plan.isClamped && abs(plan.offset - (rowY - anchorY)) > 0.001 { bad += 1 }
    if plan.isClamped { clamped += 1 }
    let current = rnd(Double(minOff), Double(max(minOff, maxOff)))
    let delta = rnd(-400, 400)
    let predicted = ToggleAnchorMath.predictedMaxOffset(currentMaxOffset: maxOff, heightDelta: delta)
    let pre = ToggleAnchorMath.preResizeOffset(idealOffset: current, predictedMaxOffset: predicted, minOffset: minOff)
    if pre > max(minOff, maxOff) + 0.001 || pre < minOff - 0.001 { bad += 1 }      // legal BEFORE the resize
    if pre > max(minOff, predicted) + 0.001 || pre < minOff - 0.001 { bad += 1 }  // and AFTER it
    if pre > current + 0.001 { bad += 1 }                                          // never moves further than needed
}
check("no out-of-range plan or pre-write", bad == 0, "bad=\(bad)")
check("the sweep exercised the clamped branch (>200)", clamped > 200, "clamped=\(clamped)")

print("\nRESULT checks=\(checks) failures=\(failures)")
if failures > 0 { exit(1) }
print("ASK_CARD_ANCHOR_MATH_PASS checks=\(checks)")
