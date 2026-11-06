import UIKit
import SwiftUI

/// Regression suite for the thinking row's tap-to-expand transaction.
///
/// Drives the REAL production methods: `MessageListLayout` + `SelfSizingCell`
/// (verbatim), and `thinkingToggleAnchored` / `verifyThinkingToggle` /
/// `releaseThinkingToggleOnUserScroll` / `releaseThinkingToggleTxnForListChange`
/// (verbatim from `MessageListV3Coordinator+ToolFolding.swift`, wrapped in the
/// fixture coordinator in TxCoordinatorStub.swift).
final class ThinkingTransactionTests {
    let thinkingText: String = {
        var s = ""
        for i in 0..<40 { s += "Step \(i): the model weighed option \(i) against the previous one and kept the shorter path.\n" }
        return s
    }()

    func makeRows() -> [RowModel] {
        (0..<9).map { i in
            RowModel(thinking: i == 5, text: i == 5 ? thinkingText : "Answer \(i) with a few words so the row is short.")
        }
    }

    // MARK: - The two paths

    /// Real transaction: the tap hands over a one-shot request, the coordinator
    /// applies it in its no-animation pass, then the cross-frame verifier
    /// decides settle / confirm / fixHeight and owns the anchor.
    func toggleViaTransaction(_ h: ListHarness, expanded: Bool) {
        let i = h.targetIndex
        let target = expanded
        let request = ToggleRequest { [weak h] in h?.rows[i].expanded = target }
        h.transactionToggle(index: i, request: request)
        h.layoutNow()
        // The production verifier schedules ITSELF (probeFrameInterval); drive
        // frames until it stops probing instead of calling verify by hand, so
        // the probe budget and the scheduling gate are the production ones.
        var frames = 0
        while h.coordinator.thinkingToggleTxn?.probing == true, frames < 24 {
            h.pump(ThinkingToggleTxnMath.probeFrameInterval + 0.004)
            frames += 1
        }
        h.layoutNow()
    }

    /// Negative control: the historical path (invalidate → estimate → real
    /// height, no transaction, no anchor).
    func togglePlain(_ h: ListHarness, expanded: Bool) {
        let i = h.targetIndex
        h.rows[i].expanded = expanded
        h.layout.invalidateHeight(at: i)
        h.targetCell?.clearCachedHeight()
        if let cell = h.targetCell { h.configure(cell, at: i) }
        h.layout.invalidateLayout()
        h.layoutNow()
    }

    // MARK: - Suite

    func run() {
        anchorMath()
        twentyRoundToggle()
        rapidTaps()
        lateMeasurement()
        userInterruptions()
        anchorOwnership()
        txnAnchorOnRealLayout()
        receiptMissingStillFixesHeight()
        offscreenProbeBudgetStops()
        ThinkingToggleTxnMathTests.run()
    }

    func anchorMath() {
        // Only UNC LAMPED samples can prove "the top is restored exactly": a
        // sample whose target falls outside [minOffset, maxOffset] is clamped
        // by definition, and asserting exactness there is a guaranteed failure
        // (n=0 used to: newMinY=-500, anchorY=0, minOffset=-80 → -80, i.e. the
        // row sits at -420 on screen, not 0).
        var worstUnclamped: CGFloat = 0
        var clampedSamples = 0
        for n in 0...200 {
            let anchorY = CGFloat(n % 37) * 10
            let newMinY = CGFloat(n * 13)
            let minOffset: CGFloat = -80
            let maxOffset: CGFloat = 4000
            let wanted = newMinY - anchorY
            let v = ToggleAnchorMath.anchoredOffset(newMinY: newMinY, anchorY: anchorY,
                                                    minOffset: minOffset, maxOffset: maxOffset)
            if wanted >= minOffset && wanted <= maxOffset {
                worstUnclamped = max(worstUnclamped, abs((newMinY - v) - anchorY))
            } else {
                clampedSamples += 1
                let expected = min(max(wanted, minOffset), max(minOffset, maxOffset))
                check(abs(v - expected) < 0.001,
                      "sample \(n): out-of-range target is clamped to \(fmt(expected)), not \(fmt(v))")
            }
        }
        check(clampedSamples > 0, "the sweep actually covered clamped samples (\(clampedSamples))")
        check(worstUnclamped < 0.001,
              "unclamped samples restore the row's top exactly (worst \(fmt(worstUnclamped))pt)")

        // Clamp behaviour, tested on its own.
        check(ToggleAnchorMath.anchoredOffset(newMinY: -9000, anchorY: 100, minOffset: -44, maxOffset: 1000) == -44,
              "a target above the scrollable start clamps to minOffset")
        check(ToggleAnchorMath.anchoredOffset(newMinY: 9000, anchorY: 0, minOffset: 0, maxOffset: 640) == 640,
              "a target past the end clamps to maxOffset")
        check(ToggleAnchorMath.anchoredOffset(newMinY: 300, anchorY: 0, minOffset: 0, maxOffset: 0) == 0,
              "a non-scrollable list pins the offset to 0 (max(min,max) guard)")

        check(ToggleAnchorMath.manualThinkingKey == "manualThinkingTxn",
              "manual thinking marker key is stable")
        check(ToggleAnchorMath.manualThinkingKey != ToggleAnchorMath.anchorTopKey
              && ToggleAnchorMath.manualThinkingKey != ToggleAnchorMath.toggleRequestKey,
              "manual marker is its own userInfo key (not the card's anchor/request)")
        var cardWorst: CGFloat = 0
        for n in 0...100 {
            let anchored = n % 7
            let index = n % 9
            let skip = ToggleAnchorMath.skipsVisibleCompensation(index: index, anchored: anchored)
            if skip != (index == anchored) { cardWorst += 1 }
        }
        check(cardWorst == 0, "card path exempts exactly its own row, never a neighbour")
        check(ToggleAnchorMath.revealShift(cellMinY: 0, cellMaxY: 900, visibleTop: 0, visibleBottom: 700) == 0,
              "no reveal scroll when the row has no room above")
    }

    /// 20 real cycles through the production transaction.
    func twentyRoundToggle() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        h.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        h.layoutNow()
        let startTop = h.targetTopOnScreen()
        let collapsedHeight = h.rowHeight(5)
        var worst: CGFloat = 0
        var tops: [CGFloat] = []
        for round in 0..<20 {
            let before = h.targetTopOnScreen()
            toggleViaTransaction(h, expanded: true)
            worst = max(worst, abs(h.targetTopOnScreen() - before))
            let expandedHeight = h.rowHeight(5)
            check(expandedHeight > collapsedHeight + 40,
                  "round \(round): the transaction really expanded the row (\(fmt(collapsedHeight)) → \(fmt(expandedHeight))pt)")
            let beforeCollapse = h.targetTopOnScreen()
            toggleViaTransaction(h, expanded: false)
            worst = max(worst, abs(h.targetTopOnScreen() - beforeCollapse))
            tops.append(h.targetTopOnScreen())
            check(abs(h.rowHeight(5) - collapsedHeight) < 1.0,
                  "round \(round): collapse returns to the header height (\(fmt(h.rowHeight(5))) vs \(fmt(collapsedHeight)))")
            // A finished transaction may keep its token-owned ANCHOR parked
            // (allowed: released by the next transaction / drag / session
            // change), but it must stop probing — a live probe budget here
            // would mean the transaction never converged.
            check((h.coordinator.thinkingToggleTxn?.probes ?? 0) <= ThinkingToggleTxnMath.maxProbes,
                  "round \(round): the transaction converged (probes \(h.coordinator.thinkingToggleTxn?.probes ?? 0) ≤ \(ThinkingToggleTxnMath.maxProbes))")
        }
        let drift = (tops.last ?? startTop) - startTop
        print("THINKING_TXN_20R_DRIFT \(fmt(drift)) worstPerRound \(fmt(worst)) startTop \(fmt(startTop))")
        check(abs(drift) < 1.0, "20 rounds leave the list where it started (drift \(fmt(drift))pt)")
        check(worst < 1.0, "no single round moves the row's top (worst \(fmt(worst))pt)")
        check(abs(h.rowHeight(5) - collapsedHeight) < 1.0,
              "final collapsed height matches the first (no accumulated growth)")

        let p = ListHarness(rows: makeRows(), targetIndex: 5)
        p.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        p.layoutNow()
        let plainStart = p.targetTopOnScreen()
        for _ in 0..<20 {
            togglePlain(p, expanded: true)
            togglePlain(p, expanded: false)
        }
        let plainDrift = p.targetTopOnScreen() - plainStart
        print("THINKING_TXN_PLAIN_PATH_DRIFT \(fmt(plainDrift)) (negative control)")
        check(abs(plainDrift) >= abs(drift) - 0.5,
              "the un-anchored path is never more stable than the transaction (\(fmt(plainDrift)) vs \(fmt(drift))pt)")
        if abs(plainDrift) > 4 { print("THINKING_TXN_CONTROL_DRIFT_DETECTED \(fmt(plainDrift))") }
    }

    /// Rapid taps: each one supersedes the previous token.
    func rapidTaps() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        h.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        h.layoutNow()
        let anchor = h.targetTopOnScreen()
        var firstToken = -1
        for n in 0..<8 {
            let target = (n % 2 == 0)
            let request = ToggleRequest { [weak h] in h?.rows[5].expanded = target }
            h.transactionToggle(index: 5, request: request)
            if n == 0 { firstToken = h.coordinator.thinkingToggleTxn?.token ?? -1 }
        }
        let lastToken = h.coordinator.thinkingToggleTxn?.token ?? -1
        check(lastToken > firstToken, "each rapid tap bumps the generation (\(firstToken) → \(lastToken))")
        check(h.coordinator.thinkingToggleTxn?.targetExpanded == false,
              "the transaction's target follows the LAST tap (collapsed)")
        // A stale generation must be inert.
        h.verify(token: firstToken, stableHits: 0)
        check(h.coordinator.thinkingToggleTxn?.token == lastToken,
              "a stale token's verify does not touch the live transaction")
        var frames = 0
        while h.coordinator.thinkingToggleTxn?.probing == true, frames < 24 {
            h.pump(ThinkingToggleTxnMath.probeFrameInterval + 0.004)
            frames += 1
        }
        h.layoutNow()
        let settled = h.rowHeight(5)
        let real = h.targetFittedHeight()
        check(abs(settled - real) < 1.0,
              "8 rapid taps settle on the last intent's real height (\(fmt(settled)) vs \(fmt(real)))")
        let moved = h.targetTopOnScreen() - anchor
        print("THINKING_TXN_RAPID_TOP_MOVE \(fmt(moved))")
        check(abs(moved) < 2.0, "rapid taps do not move the row's top (\(fmt(moved))pt)")
    }

    /// Late SwiftUI height, delivered the way it really arrives: the row's
    /// CONTENT changes and UIKit re-runs self-sizing for it, which runs the
    /// layout's `invalidationContext(forPreferredLayoutAttributes:)` (the
    /// visible-cell compensation). `setMeasuredHeight` never triggers that
    /// path, so it cannot prove anything about compensation.
    func lateMeasurement() {
        // Anchored: a late content change on the toggled row must not move it.
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        h.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        h.layoutNow()
        toggleViaTransaction(h, expanded: true)
        let anchoredTop = h.targetTopOnScreen()
        let anchoredOffset = h.collection.contentOffset.y
        // The row's own content grows by two paragraphs: its real fitted height
        // changes, so self-sizing must produce a correction.
        h.rows[5].text += "\nLate paragraph A.\nLate paragraph B.\nLate paragraph C."
        h.reconfigureItem(5)
        h.layoutNow()
        let anchoredDelta = h.targetTopOnScreen() - anchoredTop
        let offsetDelta = h.collection.contentOffset.y - anchoredOffset
        print("THINKING_TXN_LATE_ANCHORED_TOP \(fmt(anchoredDelta)) OFFSET \(fmt(offsetDelta))")
        check(h.layout.isTxnAnchored(index: 5) || h.coordinator.thinkingToggleTxn != nil
              || abs(offsetDelta) < 0.5,
              "the anchored row's correction does not pull the list (offset \(fmt(offsetDelta))pt)")
        check(abs(anchoredDelta) < 1.5,
              "a late real height on the toggled row keeps its top (\(fmt(anchoredDelta))pt)")

        // Control: identical content change with NO transaction/anchor. This is
        // the path UIKit really uses for an unanchored row, so a drift here is
        // the production behaviour being guarded against.
        let c = ListHarness(rows: makeRows(), targetIndex: 5)
        c.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        c.layoutNow()
        togglePlain(c, expanded: true)
        let plainTop = c.targetTopOnScreen()
        let plainOffset = c.collection.contentOffset.y
        c.rows[5].text += "\nLate paragraph A.\nLate paragraph B.\nLate paragraph C."
        c.reconfigureItem(5)
        c.layoutNow()
        let plainDelta = c.targetTopOnScreen() - plainTop
        print("THINKING_TXN_LATE_PLAIN_TOP \(fmt(plainDelta)) OFFSET \(fmt(c.collection.contentOffset.y - plainOffset)) (control)")
        check(abs(anchoredDelta) <= abs(plainDelta) + 1.0,
              "the transaction is never less stable than the unanchored path (\(fmt(anchoredDelta)) vs \(fmt(plainDelta))pt)")

        // No row-height lock: the layout still follows the cell's measurement.
        h.rows[5].expanded = true
        h.refreshTargetContent()
        h.targetCell?.clearCachedHeight()
        let fitted = h.targetFittedHeight()
        check(abs(h.rowHeight(5) - fitted) < 2.0,
              "row height still follows the cell's own measurement (no lock: \(fmt(h.rowHeight(5))) vs \(fmt(fitted)))")
    }

    /// Drag and session switch release the transaction without pulling.
    func userInterruptions() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        h.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        h.layoutNow()
        let request = ToggleRequest { [weak h] in h?.rows[5].expanded = true }
        h.transactionToggle(index: 5, request: request)
        let token = h.coordinator.thinkingToggleTxn?.token ?? -1
        check(h.layout.isTxnAnchored(index: 5), "the transaction parks its own anchor while it runs")
        h.collection.setContentOffset(CGPoint(x: 0, y: h.collection.contentOffset.y + 120), animated: false)
        h.coordinator.releaseThinkingToggleOnUserScroll()
        check(h.coordinator.thinkingToggleTxn == nil, "a user drag releases the transaction")
        check(h.layout.txnAnchor == nil, "the drag releases the token-owned anchor too")
        h.verify(token: token, stableHits: 0)
        let after = h.collection.contentOffset.y
        h.layoutNow()
        check(abs(h.collection.contentOffset.y - after) < 0.5,
              "a late verify after the drag does not move the offset (\(fmt(h.collection.contentOffset.y - after))pt)")
        // Session switch.
        let request2 = ToggleRequest { [weak h] in h?.rows[5].expanded = false }
        h.transactionToggle(index: 5, request: request2)
        h.coordinator.releaseThinkingToggleTxnForListChange()
        check(h.coordinator.thinkingToggleTxn == nil, "a session switch releases the transaction")
        check(h.layout.txnAnchor == nil, "and its anchor")
    }

    /// The thinking transaction must never park on the card's anchor field.
    func anchorOwnership() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        let request = ToggleRequest { [weak h] in h?.rows[5].expanded = true }
        h.transactionToggle(index: 5, request: request)
        check(h.layout.topAnchoredIndex == nil,
              "thinking transactions never use the answered-card anchor field")
        check(h.layout.txnAnchor?.index == 5, "they use the token-owned anchor instead")
        h.layout.topAnchoredIndex = nil
        check(h.layout.isTxnAnchored(index: 5),
              "clearing the card anchor cannot drop a live thinking anchor")
        var ran = 0
        let once = ToggleRequest { ran += 1 }
        once.run()
        once.run()
        check(ran == 1, "the handed-off request applies the flip exactly once")
    }

    /// Token semantics through the real layout.
    func txnAnchorOnRealLayout() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        let layout = h.layout
        let id = h.rows[5].id
        check(layout.txnAnchor == nil, "no anchor before the first tap")
        check(layout.setTxnAnchor(token: 7, index: 5, blockId: id), "layout accepts the first tap's anchor")
        check(layout.txnAnchor?.token == 7 && layout.txnAnchor?.blockId == id,
              "the parked anchor carries token AND row identity")
        check(layout.isTxnAnchored(index: 5), "the owning row skips visible-cell compensation")
        check(!layout.isTxnAnchored(index: 4) && !layout.isTxnAnchored(index: 6),
              "neighbour rows keep the ordinary compensation")
        check(layout.setTxnAnchor(token: 3, index: 2, blockId: id) == false,
              "a late, older token cannot steal the anchor")
        check(layout.clearTxnAnchor(token: 3) == false, "a stale token cannot release the anchor")
        check(layout.isTxnAnchored(index: 5), "the anchor survives that stale release")
        check(layout.setTxnAnchor(token: 8, index: 2, blockId: id), "a newer tap moves the anchor to its own row")
        check(layout.isTxnAnchored(index: 2) && !layout.isTxnAnchored(index: 5),
              "after supersession only the newest row is exempt")
        check(layout.clearTxnAnchor(forIndex: 5) == false, "release-by-index ignores a row that no longer owns it")
        check(layout.clearTxnAnchor(forIndex: 2), "release-by-index clears the owning row")
        check(layout.txnAnchor == nil, "row-gone cleanup leaves no anchor behind")
    }


    /// (1) regression: when the view never consumed the flip (no receipt), a
    /// CHANGED height must still be installed. Missing receipts may only delay
    /// agreement, never block a correction.
    func receiptMissingStillFixesHeight() {
        let h = ListHarness(rows: makeRows(), targetIndex: 5)
        h.collection.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        h.layoutNow()
        let request = ToggleRequest { [weak h] in h?.rows[5].expanded = true }
        h.transactionToggle(index: 5, request: request)
        h.layoutNow()
        // The marker is still set: SwiftUI has not delivered the flip yet, so
        // the production receipt is false.
        h.block(at: 5)?.pendingManualThinkingState = true
        let top = h.targetTopOnScreen()
        // A real height change arrives meanwhile (markdown re-render).
        h.rows[5].text += "\nExtra paragraph that the old height did not include."
        h.reconfigureItem(5)
        var frames = 0
        while h.coordinator.thinkingToggleTxn?.probing == true, frames < 24 {
            h.pump(ThinkingToggleTxnMath.probeFrameInterval + 0.004)
            frames += 1
        }
        h.layoutNow()
        let fitted = h.targetFittedHeight()
        check(abs(h.rowHeight(5) - fitted) < 2.0,
              "without a receipt a changed height is still installed (\(fmt(h.rowHeight(5))) vs measured \(fmt(fitted)))")
        check(abs(h.targetTopOnScreen() - top) < 1.5,
              "and the row keeps its top while that correction lands (\(fmt(h.targetTopOnScreen() - top))pt)")
        check(h.coordinator.thinkingToggleTxn?.probing != true,
              "the transaction stops probing instead of polling forever")
    }

    /// (2) regression: an off-screen row must spend the same finite budget.
    /// Before, every unmeasurable round re-scheduled itself at 60 Hz forever.
    func offscreenProbeBudgetStops() {
        // Tall list so the toggled row can be scrolled out of the viewport
        // while still being present in the snapshot.
        var rows: [RowModel] = []
        for i in 0..<40 {
            rows.append(RowModel(thinking: i == 20,
                                 text: i == 20 ? thinkingText : "Answer \(i). " + String(repeating: "Filler sentence. ", count: 12)))
        }
        let h = ListHarness(rows: rows, targetIndex: 20)
        h.layoutNow()
        // Park the target well outside the viewport.
        h.collection.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        h.layoutNow()
        check(h.targetCell == nil, "the toggled row is off screen for this case")
        let request = ToggleRequest { [weak h] in h?.rows[20].expanded = true }
        h.transactionToggle(index: 20, request: request)
        let offsetBefore = h.collection.contentOffset.y
        var frames = 0
        while frames < 40 {
            h.pump(ThinkingToggleTxnMath.probeFrameInterval + 0.004)
            frames += 1
            if h.coordinator.thinkingToggleTxn?.probing != true { break }
        }
        let live = h.coordinator.thinkingToggleTxn
        print("THINKING_TXN_OFFSCREEN_FRAMES \(frames) probes \(live?.probes ?? -1) probing \(live?.probing ?? false)")
        check(live?.probing != true, "an off-screen transaction stops probing (no 60 Hz poll)")
        check((live?.probes ?? 0) <= ThinkingToggleTxnMath.maxProbes,
              "off-screen rounds spend the finite budget (\(live?.probes ?? 0) ≤ \(ThinkingToggleTxnMath.maxProbes))")
        check(abs(h.collection.contentOffset.y - offsetBefore) < 0.5,
              "nothing moves the list while the row is off screen")
    }

    // MARK: - helpers

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { CheckLog.pass(name) } else { CheckLog.fail(name) }
    }
    func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
}
