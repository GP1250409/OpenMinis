import Foundation
import UIKit

/// Pure decisions of the thinking-row transaction (`ThinkingToggleTxn` /
/// `ThinkingToggleTxnMath`, extracted verbatim from `MessageListLayout.swift`
/// between its BEGIN/END markers by scripts/thinking_transaction_regression.py).
///
/// These are the parts the user's bug report hinges on: a late measure must not
/// re-use an anchor the height change invalidated, a stale generation must not
/// touch the offset, and the probe loop must converge instead of re-measuring
/// forever. There is deliberately NO counted-echo test: that design is blocked
/// (SwiftUI may coalesce `onChange`), so the dedupe is a model-level explicit
/// manual target and is asserted in the source contract instead.
enum ThinkingToggleTxnMathTests {
    static func run() {
        tokenGeneration()
        manualMarker()
        anchorProbes()
        ownership()
    }

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { CheckLog.pass(name) } else { CheckLog.fail(name) }
    }

    static func tokenGeneration() {
        var token = 0
        for _ in 0..<20 { token = ThinkingToggleTxnMath.nextToken(after: token) }
        check(token == 20, "20 taps produce 20 distinct generations (monotonic, no wrap at this scale)")
        check(ThinkingToggleTxnMath.isCurrent(token: 20, currentToken: 20), "the newest generation is current")
        check(!ThinkingToggleTxnMath.isCurrent(token: 19, currentToken: 20),
              "a late closure from tap #19 is rejected after tap #20")
        check(!ThinkingToggleTxnMath.isCurrent(token: 20, currentToken: nil),
              "a closure whose transaction was released cannot act")
        check(ThinkingToggleTxnMath.supersedes(existingToken: 19, newToken: 20), "a new tap supersedes the old token")
        check(!ThinkingToggleTxnMath.supersedes(existingToken: 20, newToken: 20), "same token does not supersede itself")
        check(!ThinkingToggleTxnMath.supersedes(existingToken: nil, newToken: 1), "first transaction supersedes nothing")

        let id = UUID()
        let item = MessageListItem.assistantBlock(id, id)
        let a = ToggleTxnAnchor(token: 1, index: 5, blockId: id)
        let b = ToggleTxnAnchor(token: 2, index: 5, blockId: id)
        let moved = ToggleTxnAnchor(token: 1, index: 6, blockId: id)
        check(a != b, "a new generation is a different anchor even at the same index")
        check(a != moved, "a renumbered index (streaming flush above) is a different anchor")
    }

    static func manualMarker() {
        // The marker rides on the notification, so a receiver that is not the
        // toggling view can tell a manual flip from a streaming/auto post.
        check(ToggleAnchorMath.manualThinkingKey == "manualThinkingTxn",
              "manual thinking marker key is stable (\\(ToggleAnchorMath.manualThinkingKey))")
        check(ToggleAnchorMath.manualThinkingKey != ToggleAnchorMath.anchorTopKey
              && ToggleAnchorMath.manualThinkingKey != ToggleAnchorMath.toggleRequestKey,
              "manual marker is its own userInfo key (cannot be confused with the card's anchor/request)")
        // A reusable target marker must be able to express "collapsed" and
        // "expanded" distinctly — a Bool toggle cannot be replayed by a late
        // closure that only knows it ran twice.
        var ran = 0
        let request = ToggleRequest { ran += 1 }
        check(request.run() == true && ran == 1, "the handed-off request applies the flip once")
        check(request.run() == false && ran == 1, "a second release of the same request is a no-op (no double flip)")
        check(request.hasRun, "the transaction can tell the request already ran (fallback must not flip again)")
    }

    static func anchorProbes() {
        // Late measure: the row's top stays where it is NOW, not where it was
        // before the height change (that stale anchor was the reported bug).
        let late = ThinkingToggleTxnMath.lateAnchorY(currentMinY: 640, currentOffset: 200)
        check(abs(late - 440) < 0.001, "late anchor uses the CURRENT on-screen top (440pt)")
        let afterGrowth = ThinkingToggleTxnMath.lateAnchorY(currentMinY: 940, currentOffset: 500)
        check(abs(afterGrowth - 440) < 0.001, "a taller row at a scrolled offset keeps the same on-screen top")

        let tol = ThinkingToggleTxnMath.heightTolerance

        // (1) A REAL height difference is always installed, receipt or not.
        // Replacing the hosting root can drop the old view's onChange, so a
        // missing receipt must never block a correction (that left a gap on
        // collapse).
        check(ThinkingToggleTxnMath.probe(measured: 420, current: 300, stableHits: 0, probes: 0,
                                          receipt: false) == .fixHeight,
              "receipt=false + taller measurement still fixes the height")
        check(ThinkingToggleTxnMath.probe(measured: 120, current: 300, stableHits: 3, probes: 4,
                                          receipt: false) == .fixHeight,
              "receipt=false + shorter measurement still fixes the height (no collapse gap)")
        check(ThinkingToggleTxnMath.probe(measured: 300 + tol * 3, current: 300, stableHits: 0, probes: 0,
                                          receipt: false) == .fixHeight,
              "a difference beyond tolerance fixes even without a receipt")

        // (2) A missing receipt only prevents AGREEMENT from settling.
        check(ThinkingToggleTxnMath.probe(measured: 300, current: 300, stableHits: 5, probes: 2,
                                          receipt: false) == .waitReceipt,
              "receipt=false + identical height waits for a frame instead of settling")
        check(ThinkingToggleTxnMath.probe(measured: 300 + tol * 0.5, current: 300, stableHits: 5, probes: 2,
                                          receipt: false) == .waitReceipt,
              "receipt=false + within-tolerance height also waits (no false settle)")
        check(ThinkingToggleTxnMath.probe(measured: 300, current: 300, stableHits: 0, probes: 0,
                                          receipt: true) == .confirm,
              "receipt=true + first agreement confirms once")
        check(ThinkingToggleTxnMath.probe(measured: 300, current: 300, stableHits: 1, probes: 1,
                                          receipt: true) == .settle,
              "receipt=true + second agreement settles")

        // (3) Budget is spent BEFORE correctness, so no poll can outlive it.
        check(ThinkingToggleTxnMath.probe(measured: 420, current: 300, stableHits: 0,
                                          probes: ThinkingToggleTxnMath.maxProbes, receipt: false) == .abandon,
              "the probe budget abandons even when a fix is pending")
        check(ThinkingToggleTxnMath.probe(measured: .nan, current: 300, stableHits: 0, probes: 0,
                                          receipt: true) == .abandon,
              "a NaN measurement (hosting view before first layout) never anchors")
        check(ThinkingToggleTxnMath.probe(measured: 0, current: 300, stableHits: 0, probes: 0,
                                          receipt: true) == .abandon,
              "a zero measurement is rejected, not applied as a collapse")

        // (4) No receipt ever arrives: the loop must still terminate at the cap
        // (this is the 60 Hz-forever case when a row sits off screen).
        var probes = 0
        var rounds = 0
        var last: ThinkingToggleTxnMath.Probe = .confirm
        while rounds < 100 {
            rounds += 1
            last = ThinkingToggleTxnMath.probe(measured: 300, current: 300, stableHits: 0, probes: probes,
                                               receipt: false)
            probes += 1
            if last == .abandon || last == .settle { break }
        }
        // probes is incremented after each decision, so the abandoning round is
        // the one that sees probes == maxProbes: maxProbes + 1 decisions total.
        check(last == .abandon && rounds == ThinkingToggleTxnMath.maxProbes + 1 && probes == ThinkingToggleTxnMath.maxProbes + 1,
              "a receipt that never arrives ends in .abandon after \(ThinkingToggleTxnMath.maxProbes) spent probes (got \(rounds) rounds)")
        check(ThinkingToggleTxnMath.maxProbes >= 2 && ThinkingToggleTxnMath.maxProbes <= 10,
              "probe budget stays small (no endless re-measure loop)")
        check(ThinkingToggleTxnMath.probeFrameInterval > 0 && ThinkingToggleTxnMath.probeFrameInterval <= 0.1,
              "probe interval is frame-paced (\(ThinkingToggleTxnMath.probeFrameInterval)s), not a timer wake")

        let reasons: [ThinkingToggleTxnMath.ReleaseReason] = [.settled, .rowGone, .sessionChanged,
                                                              .userScroll, .superseded, .listTornDown,
                                                              .probesExhausted]
        check(reasons.count == 7, "every release path is named (drag, session change, reuse, teardown)")
        check(ThinkingToggleTxnMath.ReleaseReason.userScroll.rawValue == "userScroll",
              "a user drag is its own release reason (explicit takeover)")
    }

    static func ownership() {
        check(ThinkingToggleTxnMath.skipsVisibleCompensation(anchorIndex: 5, index: 5)
              && !ThinkingToggleTxnMath.skipsVisibleCompensation(anchorIndex: 5, index: 6),
              "only the thinking row skips visible-cell compensation")
        check(ThinkingToggleTxnMath.skipsVisibleCompensation(anchorIndex: nil, index: 5) == false,
              "no thinking anchor means no row is exempt")
        // Separate decision functions, same rule: neither is expressed in terms
        // of the other's state.
        check(ToggleAnchorMath.skipsVisibleCompensation(index: 5, anchored: 5)
              == ThinkingToggleTxnMath.skipsVisibleCompensation(anchorIndex: 5, index: 5),
              "card and thinking paths agree on the compensation rule")
        // Unclamped on purpose: 700-100=600 lies inside [0, 4000], so the card
        // helper returns 600 and the thinking helper must derive the on-screen
        // top from the CURRENT offset (700-500=200), never from the card's 100.
        let cardAnchor = ToggleAnchorMath.anchoredOffset(newMinY: 700, anchorY: 100, minOffset: 0, maxOffset: 4000)
        check(abs(cardAnchor - 600) < 0.001, "card helper restores the top at an unclamped offset")
        let thinkingAnchor = ThinkingToggleTxnMath.lateAnchorY(currentMinY: 700, currentOffset: cardAnchor - 100)
        check(abs(thinkingAnchor - 200) < 0.001,
              "thinking anchor is computed from the current offset (200), not from the card's anchor")
        // Clamped card sample: the thinking anchor still uses the real offset,
        // so no clamping assumption leaks into this path.
        let clamped = ToggleAnchorMath.anchoredOffset(newMinY: -500, anchorY: 0, minOffset: -80, maxOffset: 4000)
        check(abs(clamped - (-80)) < 0.001, "out-of-range card target clamps to minOffset (-80)")
        check(abs(ThinkingToggleTxnMath.lateAnchorY(currentMinY: -420, currentOffset: clamped) - (-340)) < 0.001,
              "thinking anchor stays consistent with a clamped card offset (-340)")
    }
}
