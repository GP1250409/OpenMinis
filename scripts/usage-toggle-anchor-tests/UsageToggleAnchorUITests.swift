import Foundation
import UIKit

// Real-UIKit regression for [T-usage-toggle-anchor].
//
// The two facts the 2026-11-08 recording established:
//   1. the quiet usage footer measures ~21pt but is SEEDED at 4pt, so the
//      insert side pays only the seed and the delete side pays the whole row;
//   2. nothing compensates a row that is inserted or deleted ABOVE the
//      viewport, so a show/hide cycle ratchets the transcript upward.
// Check 1 proves (1) in this fixture. Check 2 reproduces (2) with the anchor
// OFF (the negative control: the shipped bug). Every later check exercises the
// production `captureVisibleAnchor` / `restoreVisibleAnchor` (sliced verbatim
// from MessageListV3Coordinator+Snapshot.swift).

enum CheckLog {
    static var passed = 0
    static var failed = 0
}

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        CheckLog.passed += 1
        print("  ok   \(label)\(detail.isEmpty ? "" : " — " + detail)")
    } else {
        CheckLog.failed += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — " + detail)")
    }
}

func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }

final class UsageToggleAnchorTests {
    func run() {
        print("USAGE_TOGGLE_ANCHOR_SUITE start")
        caseSeedAsymmetry()
        caseNegativeControlUnaanchored()
        caseAnchoredHoldsPosition()
        caseRapidToggles()
        caseDragGuard()
        caseStaleGeneration()
        caseBottomAutoFollow()
        caseFooterBelowViewport()
        caseTopClippedOversizedRow()
        caseFooterIsNeverTheAnchor()
    }

    // MARK: 1. the asymmetry the fix exists for

    func caseSeedAsymmetry() {
        print("[1] the footer is seeded at 4pt and really measures ~21pt")
        AnchorTrace.reset()
        let h = UsageHarness(rowCount: 12, footerIndex: 5, textHeight: 120)
        // Hide, then show and read the height the FIRST layout pass gave the
        // new row (inside the apply, before the hosting graph re-measures).
        h.apply(showFooter: false, anchored: false)
        h.settle()
        var firstPassHeight: CGFloat = .nan
        h.apply(showFooter: true, anchored: false) {
            firstPassHeight = h.rowHeight(h.footerIndex)
        }
        h.settle()
        let real = h.rowHeight(h.footerIndex)
        print("REPORT_FOOTER_FIRST_PASS \(f(firstPassHeight))")
        print("REPORT_FOOTER_REAL \(f(real))")
        check("the first pass lays the inserted footer out at its 4pt seed",
              abs(firstPassHeight - UsageHarness.quietFooterSeed) < 1.5, "first=\(f(firstPassHeight))")
        check("the settled footer is much taller than its seed (the asymmetry)",
              real >= UsageHarness.quietFooterSeed + 8, "real=\(f(real)) seed=4")
    }

    // MARK: 2. negative control: the shipped bug

    func caseNegativeControlUnaanchored() {
        print("[2] negative control — four show/hide cycles with NO anchor")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        h.scrollFooterAboveViewport()
        h.settle()
        h.trace("case2.start")
        let start = h.screenTop(of: h.referenceItem)
        var perCycle: [CGFloat] = []
        for i in 0..<4 {
            h.traceCycles = (i == 0)
            perCycle.append(h.cycle(anchored: false))
            if i == 0 { h.trace("case2.after-cycle-1") }
        }
        h.traceCycles = false
        let total = h.screenTop(of: h.referenceItem) - start
        print("REPORT_NOANCHOR_PER_CYCLE " + perCycle.map(f).joined(separator: ","))
        print("REPORT_NOANCHOR_TOTAL \(f(total))")
        let footerHeight = h.footerRealHeight
        check("hiding the footer alone moves the reader's row up by the whole row height",
              perCycle.allSatisfy { $0 < -1 },
              "per-cycle=" + perCycle.map(f).joined(separator: ","))
        check("four cycles ratchet the transcript upward (the shipped bug)",
              total <= -8, "total=\(f(total)) footerHeight=\(f(footerHeight))")
        check("the ratchet is smaller than one row height per cycle (the insert side pays the 4pt seed)",
              abs(total) < 4 * footerHeight, "|total|=\(f(abs(total))) < 4*\(f(footerHeight))")
    }

    // MARK: 3. the fix

    func caseAnchoredHoldsPosition() {
        print("[3] four show/hide cycles WITH the production anchor")
        AnchorTrace.reset()
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        h.scrollFooterAboveViewport()
        h.settle()
        let start = h.screenTop(of: h.referenceItem)
        var perCycle: [CGFloat] = []
        for _ in 0..<4 { perCycle.append(h.cycle(anchored: true)) }
        let total = h.screenTop(of: h.referenceItem) - start
        print("REPORT_ANCHORED_PER_CYCLE " + perCycle.map(f).joined(separator: ","))
        print("REPORT_ANCHORED_TOTAL \(f(total))")
        print("REPORT_ANCHOR_RESTORES \(AnchorTrace.count)")
        check("every cycle is a no-op for the reader (|Δ| ≤ 1pt)",
              perCycle.allSatisfy { abs($0) <= 1.0 },
              "per-cycle=" + perCycle.map(f).joined(separator: ","))
        check("the four cycles together do not drift", abs(total) <= 1.5, "total=\(f(total))")
        check("the production restore actually ran", AnchorTrace.count >= 4,
              "restores=\(AnchorTrace.count)")
        check("the footer is present again after the last show", h.footerPresent)
    }

    // MARK: 4. fast user (no settle between taps)

    func caseRapidToggles() {
        print("[4] six toggles back to back, no settle in between")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        h.scrollFooterAboveViewport()
        h.settle()
        let start = h.screenTop(of: h.referenceItem)
        var show = false
        for _ in 0..<6 {
            h.apply(showFooter: show, anchored: true)
            show.toggle()
        }
        h.settle(0.20)
        let total = h.screenTop(of: h.referenceItem) - start
        print("REPORT_RAPID_TOTAL \(f(total))")
        check("rapid toggles leave the reader within 2pt of where he was",
              abs(total) <= 2.0, "total=\(f(total))")
    }

    // MARK: 5. a drag in the same tick wins

    func caseDragGuard() {
        print("[5] a drag started in the same tick is not yanked back")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        h.scrollFooterAboveViewport()
        h.settle()
        h.collection.forcedTracking = true
        h.apply(showFooter: false, anchored: true)
        h.settle()
        // The user keeps dragging: the reader is 60pt further down.
        let dragged = h.collection.contentOffset.y + 60
        h.collection.setContentOffset(CGPoint(x: 0, y: dragged), animated: false)
        h.settle(0.20)
        let afterAsync = h.collection.contentOffset.y
        print("REPORT_DRAG_OFFSET_AFTER_ASYNC \(f(afterAsync))")
        check("the deferred restore does not pull the list back while isTracking",
              abs(afterAsync - dragged) <= 0.5, "dragged=\(f(dragged)) after=\(f(afterAsync))")
        h.collection.forcedTracking = false
        // Tracking ended: the next toggle anchors again.
        h.settle()
        h.apply(showFooter: true, anchored: true)
        h.settle()
        let cycleAfterDrag = h.cycle(anchored: true)
        print("REPORT_DRAG_CYCLE_AFTER \(f(cycleAfterDrag))")
        check("after the drag ends a toggle anchors again (|Δ| ≤ 1.5pt)",
              abs(cycleAfterDrag) <= 1.5, "cycle=\(f(cycleAfterDrag))")
    }

    // MARK: 6. a stale anchor is dropped

    func caseStaleGeneration() {
        print("[6] an anchor from an older apply is dropped")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        h.scrollFooterAboveViewport()
        h.settle()
        let coordinator = h.coordinator
        let capture = coordinator.captureVisibleAnchor()
        check("a visible anchor is captured", capture != nil)
        guard let capture else { return }
        let before = h.collection.contentOffset.y
        // Another apply (or a session switch) lands in between.
        coordinator.snapshotApplyGeneration += 1
        h.collection.setContentOffset(CGPoint(x: 0, y: before - 40), animated: false)
        coordinator.restoreVisibleAnchor(capture)
        let afterStale = h.collection.contentOffset.y
        check("a stale generation is dropped (no pull back)",
              abs(afterStale - (before - 40)) <= 0.5, "after=\(f(afterStale))")
        coordinator.restoreVisibleAnchor(capture, requireCurrentApply: false)
        let afterForced = h.collection.contentOffset.y
        print("REPORT_STALE_OFFSETS \(f(before)),\(f(afterStale)),\(f(afterForced))")
        check("with the generation check waived the same anchor restores",
              abs(afterForced - before) <= 1.0, "after=\(f(afterForced)) want≈\(f(before))")
    }

    // MARK: 7. bottom auto-follow still wins

    func caseBottomAutoFollow() {
        print("[7] at the bottom, the auto-scroll pin still owns the offset")
        let h = UsageHarness(rowCount: 40, footerIndex: 20, textHeight: 120)
        h.coordinator.scrollMode = .autoScrolling
        h.scrollToBottom()
        h.settle()
        let bottom = h.maxOffset
        h.apply(showFooter: false, anchored: true)
        h.settle()
        let afterHide = h.collection.contentOffset.y
        h.apply(showFooter: true, anchored: true)
        h.settle()
        let afterShow = h.collection.contentOffset.y
        let expected = h.maxOffset
        print("REPORT_BOTTOM_OFFSETS \(f(bottom)),\(f(afterHide)),\(f(afterShow)),\(f(expected))")
        check("hiding the footer still leaves the list pinned to the bottom",
              abs(afterHide - h.maxOffset) <= 1.0, "after=\(f(afterHide)) max=\(f(h.maxOffset))")
        check("showing it leaves the list pinned to the bottom",
              abs(afterShow - expected) <= 1.0, "after=\(f(afterShow)) max=\(f(expected))")
    }

    // MARK: 8. a row added/removed below the viewport must not move anything

    func caseFooterBelowViewport() {
        print("[8] the footer below the viewport: no anchor over-correction")
        let h = UsageHarness(rowCount: 30, footerIndex: 20, textHeight: 120)
        h.scrollFooterBelowViewport()
        h.settle()
        let start = h.screenTop(of: h.rows[h.footerIndex - 1].item)
        var perCycle: [CGFloat] = []
        for anchored in [false, true] {
            for _ in 0..<2 { perCycle.append(h.cycle(anchored: anchored)) }
        }
        let total = h.screenTop(of: h.rows[h.footerIndex - 1].item) - start
        print("REPORT_BELOW_PER_CYCLE " + perCycle.map(f).joined(separator: ","))
        check("a structural change below the viewport moves nothing (anchored or not)",
              perCycle.allSatisfy { abs($0) <= 1.0 }, "per-cycle=" + perCycle.map(f).joined(separator: ","))
        check("four cycles below the viewport leave no residue", abs(total) <= 1.0, "total=\(f(total))")
    }

    // MARK: 9. a row taller than the viewport / clipped at the top

    func caseTopClippedOversizedRow() {
        print("[9] the top visible row is clipped (oversized): the fallback anchor")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120, tallRowAt: 8)
        h.scrollFooterAboveViewport()
        h.settle()
        // Scroll INTO the oversized row so its top edge is off screen.
        if let a = h.attrs(8) {
            h.collection.setContentOffset(CGPoint(x: 0, y: a.frame.minY + 300), animated: false)
            h.collection.layoutIfNeeded()
        }
        h.settle()
        let anchor = h.coordinator.captureVisibleAnchor()
        if let anchor {
            print("REPORT_TOPCLIP_ANCHOR \(String(describing: anchor.item).prefix(24))")
        } else {
            print("REPORT_TOPCLIP_ANCHOR nil")
        }
        check("an anchor is captured even when every visible row starts above the viewport",
              anchor != nil)
        let start = h.screenTop(of: h.referenceItem)
        var perCycle: [CGFloat] = []
        for _ in 0..<3 { perCycle.append(h.cycle(anchored: true)) }
        let total = h.screenTop(of: h.referenceItem) - start
        print("REPORT_TOPCLIP_TOTAL \(f(total))")
        check("a clipped top row still anchors the position (|Δ| ≤ 1.5pt per cycle)",
              perCycle.allSatisfy { abs($0) <= 1.5 }, "per-cycle=" + perCycle.map(f).joined(separator: ","))
        check("three clipped-row cycles do not drift", abs(total) <= 2.0, "total=\(f(total))")
    }

    // MARK: 10. the anchor can never be the row this apply deletes

    func caseFooterIsNeverTheAnchor() {
        print("[10] the deleted footer is never chosen as the anchor")
        let h = UsageHarness(rowCount: 14, footerIndex: 5, textHeight: 120)
        // Put the footer AT the viewport top: the naive "first visible row"
        // would be the very row the hide is about to delete.
        if let a = h.attrs(h.footerIndex) {
            h.collection.setContentOffset(CGPoint(x: 0, y: a.frame.minY + 2), animated: false)
            h.collection.layoutIfNeeded()
        }
        h.settle()
        let anchor = h.coordinator.captureVisibleAnchor()
        let isFooter: Bool
        if case .assistantFooter = anchor?.item { isFooter = true } else { isFooter = false }
        print("REPORT_FOOTER_ANCHOR_CANDIDATE " + (isFooter ? "footer" : "other"))
        check("captureVisibleAnchor skips .assistantFooter", anchor != nil && !isFooter)
        let start = h.screenTop(of: h.referenceItem)
        let delta = h.cycle(anchored: true)
        let total = h.screenTop(of: h.referenceItem) - start
        print("REPORT_FOOTERTOP_CYCLE \(f(delta))")
        check("a cycle that starts on the footer row still holds position",
              abs(total) <= 1.5, "total=\(f(total))")
    }
}
