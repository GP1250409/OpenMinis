// [T-user-ask-anchor-clamp] Cases for the real UIKit fixture (AskCardUIKitHarness).
// Drives the SHIPPING remeasureKeepingTop / verifyToggledHeight and only observes
// geometry: scroll offset, content size, cell frames, and whether an offset was
// ever out of range at a contentSize change (what UIKit would clamp in one frame).
import Foundation
import SwiftUI
import UIKit

func runAskCardUIKitCases() {
    let pngDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASK_PNG_DIR"] ?? "./build/ask-card-uikit")
    try? FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
    var png = 0
    func snapshot(_ name: String, _ vc: UIViewController) {
        let renderer = UIGraphicsImageRenderer(bounds: vc.view.bounds)
        let img = renderer.image { _ in vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true) }
        if let data = img.pngData() {
            try? data.write(to: pngDir.appendingPathComponent(name + ".png"))
            png += 1
        }
    }

    // ---- S1: card collapses above a COLLAPSED tool group, list at the bottom ----
    do {
        let fx = AskCardFixture(items: 6, tail: false)
        fx.pump(0.4)
        let card = fx.cardIds[0]
        let before = fx.frame(of: card)
        let offsetBefore = fx.cv.contentOffset.y
        fx.spy.reset()
        fx.toggleCard(card)
        fx.pump(1.4)
        let after = fx.frame(of: card)
        // The card must START in its settled EXPANDED geometry (2 questions,
        // ~133pt); an unsettled hosting first frame is the collapsed ~61pt and
        // would make "did it shrink" vacuous (run 44439673271: 61.3->61.3).
        check("S1 the card starts expanded and settled (taller than the collapsed row)",
              (before?.height ?? 0) > 100, "before=\(f(before?.height ?? -1))")
        // A list shorter than the viewport has maxOffset < minOffset; the only
        // legal offset is then minOffset, so the upper bound is the clamped one.
        let legal = fx.cv.contentOffset.y <= fx.legalUpperOffset + 1.0
            && fx.cv.contentOffset.y >= fx.minOffset - 1.0
        let shrunk = (after?.height ?? 0) < (before?.height ?? 0) - 20
        check("S1 collapse shrank the card", shrunk, "\(f(before?.height ?? -1))->\(f(after?.height ?? -1))")
        check("S1 no out-of-range offset at any contentSize change (no one-frame clamp)",
              fx.spy.outOfRange == 0, "violations=\(fx.spy.outOfRange) worst=\(f(fx.spy.worst)) events=\(fx.spy.observations)")
        check("S1 final offset is inside the legal range", legal,
              "off=\(f(fx.cv.contentOffset.y)) max=\(f(fx.maxOffset)) upper=\(f(fx.legalUpperOffset)) min=\(f(fx.minOffset))")
        check("S1 contentSize observation actually fired", fx.spy.observations > 0, "\(fx.spy.observations)")
        check("S1 the page moved by no more than the card shrank",
              abs(fx.cv.contentOffset.y - offsetBefore) <= (before?.height ?? 0) - (after?.height ?? 0) + 2.0,
              "d=\(f(fx.cv.contentOffset.y - offsetBefore))")
        snapshot("s1-collapse-collapsed-group", fx.vc)
    }

    // ---- S2: same collapse with the tool group EXPANDED (the case that did not jump) ----
    do {
        let fx = AskCardFixture(items: 6, tail: false)
        fx.toggleTool()
        fx.pump(0.4)
        let card = fx.cardIds[0]
        let before = fx.frame(of: card)
        check("S2 the card row has layout attributes before the toggle", before != nil)
        let anchorY = (before?.minY ?? 0) - fx.cv.contentOffset.y
        fx.spy.reset()
        fx.toggleCard(card)
        fx.pump(1.4)
        let after = fx.frame(of: card)
        check("S2 the card row still has layout attributes after the toggle", after != nil)
        let anchorAfter = (after?.minY ?? 0) - fx.cv.contentOffset.y
        check("S2 tool group expanded (range is larger)", fx.toolExpanded)
        check("S2 no out-of-range offset at any contentSize change",
              fx.spy.outOfRange == 0, "violations=\(fx.spy.outOfRange) worst=\(f(fx.spy.worst))")
        check("S2 the card's top is held (anchor reachable)",
              before != nil && after != nil && abs(anchorAfter - anchorY) <= 1.0,
              "anchor \(f(anchorY))->\(f(anchorAfter))")
        snapshot("s2-collapse-expanded-group", fx.vc)
    }

    // ---- S3: 6 expand/collapse rounds mid-list: no cumulative drift ----
    do {
        let fx = AskCardFixture(items: 10, tail: false)
        fx.pump(0.4)
        // park mid-list so the anchor is always reachable
        fx.cv.setContentOffset(CGPoint(x: 0, y: max(0, fx.maxOffset - 260)), animated: false)
        fx.cv.layoutIfNeeded()
        let card = fx.cardIds[0]
        // Six toggles must land back on the state the fixture STARTED from
        // (the card boots expanded) - comparing to a hard-coded `false` was
        // wrong (run 44439673271).
        let startExpanded = fx.expanded[card]
        // A force-unwrapped `layoutAttributesForItem` would crash the whole app
        // (and take S4-S7 with it) if the parked offset ever pushed the row out
        // of the layout's attribute range; make that a real check instead.
        let startFrame = fx.frame(of: card)
        check("S3 the card row has layout attributes before the round trips", startFrame != nil)
        let start = (startFrame?.minY ?? 0) - fx.cv.contentOffset.y
        fx.spy.reset()
        for _ in 0..<6 { fx.toggleCard(card); fx.pump(1.0) }
        let endFrame = fx.frame(of: card)
        check("S3 the card row still has layout attributes after the round trips", endFrame != nil)
        let end = (endFrame?.minY ?? 0) - fx.cv.contentOffset.y
        check("S3 card top did not drift over 6 toggles",
              startFrame != nil && endFrame != nil && abs(end - start) <= 1.0, "\(f(start))->\(f(end))")
        check("S3 no out-of-range offset during the round trips", fx.spy.outOfRange == 0, "\(fx.spy.outOfRange)")
        check("S3 back to the state it started from",
              fx.expanded[card] == startExpanded,
              "start=\(String(describing: startExpanded)) end=\(String(describing: fx.expanded[card]))")
        snapshot("s3-roundtrip", fx.vc)
    }

    // ---- S4: rapid double tap: last intent wins, height agrees, nothing stale ----
    do {
        let fx = AskCardFixture(items: 8, tail: false)
        fx.pump(0.4)
        let card = fx.cardIds[0]   // starts expanded
        fx.spy.reset()
        fx.toggleCard(card)        // collapse
        fx.pump(0.05)
        fx.toggleCard(card)        // expand again, mid-animation
        // Cover the production release window (0.6s) and the cross-frame
        // verifier before comparing; the 1.5pt agreement threshold is unchanged.
        fx.pump(2.0)
        check("S4 last tap's intent is the final state", fx.expanded[card] == true)
        if let fr = fx.frame(of: card) {
            let cell = fx.cv.cellForItem(at: IndexPath(item: fx.ds.snapshot().itemIdentifiers.firstIndex(of: .assistantBlock(fx.msgId, card)) ?? 0, section: 0)) as? SelfSizingCell
            let fitted = cell.map { c -> CGFloat in
                c.contentView.setNeedsLayout(); c.contentView.layoutIfNeeded(); c.clearCachedHeight()
                return c.preferredLayoutAttributesFitting(UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))).size.height
            } ?? -1
            check("S4 cell height equals the measured height (no ghost / overlap)",
                  abs(fr.height - fitted) <= 1.5, "cell=\(f(fr.height)) fitted=\(f(fitted))")
        }
        check("S4 no out-of-range offset across the double tap", fx.spy.outOfRange == 0, "\(fx.spy.outOfRange)")
        snapshot("s4-double-tap", fx.vc)
    }

    // ---- S5: a drag in flight must not be moved by the toggle or its verify chain ----
    do {
        let fx = AskCardFixture(items: 8, tail: false)
        fx.pump(0.4)
        let card = fx.cardIds[0]
        fx.cv.setContentOffset(CGPoint(x: 0, y: max(0, fx.maxOffset - 300)), animated: false)
        fx.cv.layoutIfNeeded()
        let offsetBefore = fx.cv.contentOffset.y
        fx.cv.beginDragForFixture()
        fx.toggleCard(card)
        fx.pump(1.2)
        let moved = abs(fx.cv.contentOffset.y - offsetBefore)
        fx.cv.endDragForFixture()
        check("S5 no offset write while the finger is down", moved <= 1.0, "moved=\(f(moved))")
        check("S5 no crash and the offset stayed legal",
              fx.cv.contentOffset.y <= fx.legalUpperOffset + 1.0
              && fx.cv.contentOffset.y >= fx.minOffset - 1.0,
              "off=\(f(fx.cv.contentOffset.y)) upper=\(f(fx.legalUpperOffset)) min=\(f(fx.minOffset))")
        snapshot("s5-drag", fx.vc)
    }

    // ---- S6: snapshot / session swap right after a toggle: old chain must go quiet ----
    do {
        let fx = AskCardFixture(items: 8, tail: false)
        fx.pump(0.4)
        let card = fx.cardIds[0]
        fx.spy.reset()
        fx.toggleCard(card)
        fx.replaceSnapshot(count: 3)
        fx.pump(0.2)
        let offset = fx.cv.contentOffset.y
        fx.pump(1.2)
        check("S6 old verify chain did not move the list after the swap",
              abs(fx.cv.contentOffset.y - offset) <= 1.0,
              "\(f(offset))->\(f(fx.cv.contentOffset.y))")
        check("S6 no out-of-range offset after the swap", fx.spy.outOfRange == 0, "\(fx.spy.outOfRange)")

        // [T-user-ask-anchor-flight] CROSS with the status-bar scroll-to-top
        // flight: a card tap that lands mid-flight is fresh user intent, so it
        // ENDS the flight (reason .askToggle) instead of writing the offset
        // underneath the system animation, releases the layout's ownership and
        // the borrowed self-sizing, and leaves nothing behind that could move
        // the list later.
        //
        // FIXTURE BOUNDARY (do not read more into these checks): the flight's
        // real resume pass lives in Coordinator+ScrollViewDelegate.swift and is
        // NOT compiled into this fixture, so `statusBarRestoredOwnership` below
        // is TxCoordinatorStub's own counter and proves only that the toggle
        // ended the flight through the shipping call - not that the production
        // resume restored self-sizing/streaming. The real lifecycle's own
        // accounting (`selfSizingDeferredByFlight` / `streamingSuspendedByFlight`,
        // both SHIPPING code) covers that half; the physical restore is CI/app
        // territory and is reported as unverified.
        //
        // A dedicated fixture: the swap above removed this block's card, and the
        // tap path only runs for a row that is still in the data source.
        let cross = AskCardFixture(items: 6, tail: false)
        cross.pump(0.4)
        let crossCard = cross.cardIds[0]
        // What the flight's begin does in production: it suspends streaming UI
        // updates, so a block-count update during the flight is DEFERRED
        // (`hasPendingSnapshot = true`) and the resume only queues its flush.
        cross.coordinator.hasPendingSnapshot = true
        _ = cross.coordinator.statusBarScrollToTop.begin()
        cross.vc.messageListLayout?.isSystemScrollToTopActive = true
        cross.vc.messageListLayout?.deferSelfSizing = true
        check("S6 cross: fixture flight is running", cross.coordinator.statusBarScrollToTop.isActive)
        cross.toggleCard(crossCard)
        check("S6 cross: the card toggle ended the flight",
              !cross.coordinator.statusBarScrollToTop.isActive
              && cross.coordinator.statusBarEndReasons.contains(.askToggle),
              "\(cross.coordinator.statusBarEndReasons)")
        check("S6 cross: the layout is no longer system-owned",
              cross.vc.messageListLayout?.isSystemScrollToTopActive == false)
        // [T-user-ask-anchor-pending] A deferred streaming snapshot must be
        // consumed BEFORE this row is read/measured/anchored. A `flushPending`
        // apply with unchanged items goes through `remeasureVisibleCells`, which
        // drops every visible row's cached height - the height the toggle just
        // installed included - and reconfigures the cell mid-animation. The
        // record is taken from the SHIPPING layout (`topAnchoredIndex`), so an
        // ordering that flushes after the anchor cannot pass.
        let flush = cross.coordinator.pendingSnapshotFlushes
        check("S6 cross: the deferred snapshot is consumed exactly once by the toggle",
              flush.count == 1 && flush[0].caller == "askToggle-beforeMeasure",
              "\(flush.map { $0.caller })")
        check("S6 cross: …and it is consumed BEFORE the card's anchor is parked",
              flush.first?.anchoredIndex == nil,
              "\(flush.map { $0.anchoredIndex.map { String($0) } ?? "nil" })")
        check("S6 cross: nothing is left pending after the toggle",
              cross.coordinator.hasPendingSnapshot == false)
        // Production-observable half of "the borrowed ownership came back": the
        // SHIPPING lifecycle clears both flags in `end`, exactly once.
        check("S6 cross: the real lifecycle released both borrowed ownership flags",
              !cross.coordinator.statusBarScrollToTop.selfSizingDeferredByFlight
              && !cross.coordinator.statusBarScrollToTop.streamingSuspendedByFlight)
        check("S6 cross: the flight handed its borrowed self-sizing back (stub-boundary counter)",
              cross.coordinator.statusBarRestoredOwnership >= 1)
        check("S6 cross: the offset stayed legal", cross.spy.outOfRange == 0, "\(cross.spy.outOfRange)")
        let crossOffset = cross.cv.contentOffset.y
        cross.pump(0.8)
        check("S6 cross: no probe wrote the offset after the flight ended",
              abs(cross.cv.contentOffset.y - crossOffset) <= 1.0,
              "\(f(crossOffset))->\(f(cross.cv.contentOffset.y))")
        snapshot("s6-snapshot-swap", fx.vc)
    }

    // ---- S7 (P0): content SHORTER than the viewport (maxOff < minOff) ----
    do {
        let fx = AskCardFixture(items: 1, tail: false)
        fx.pump(0.4)
        let minOff = -fx.cv.adjustedContentInset.top
        let short = fx.contentSizeHeight - fx.cv.bounds.height + fx.cv.adjustedContentInset.bottom < minOff
        check("S7 fixture really is shorter than the viewport (maxOff < minOff)", short,
              "maxOff=\(f(fx.maxOffset)) minOff=\(f(minOff))")
        let card = fx.cardIds[0]
        fx.spy.reset()
        fx.toggleCard(card)
        fx.pump(1.2)
        check("S7 every offset stayed at/above the legal floor minOffset",
              fx.cv.contentOffset.y >= minOff - 1.0, "off=\(f(fx.cv.contentOffset.y)) min=\(f(minOff))")
        check("S7 the offset stayed inside the clamped legal range",
              fx.cv.contentOffset.y <= fx.legalUpperOffset + 1.0 && fx.cv.contentOffset.y >= fx.minOffset - 1.0,
              "off=\(f(fx.cv.contentOffset.y)) upper=\(f(fx.legalUpperOffset))")
        check("S7 no out-of-range offset at any contentSize change",
              fx.spy.outOfRange == 0, "violations=\(fx.spy.outOfRange) worst=\(f(fx.spy.worst))")
        snapshot("s7-short-content", fx.vc)
    }

    print("ASK_CARD_ANCHOR_UIKIT_CHECKS checks=\(checks) failures=\(failures) png=\(png)")
    if failures > 0 {
        print("ASK_CARD_ANCHOR_UIKIT_FAIL failures=\(failures)")
        exit(1)
    }
    print("ASK_CARD_ANCHOR_UIKIT_PASS cases=7 checks=\(checks) png=\(png)")
    exit(0)
}
