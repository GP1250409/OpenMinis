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
        let legal = fx.cv.contentOffset.y <= fx.maxOffset + 1.0 && fx.cv.contentOffset.y >= -fx.cv.adjustedContentInset.top - 1.0
        let shrunk = (after?.height ?? 0) < (before?.height ?? 0) - 20
        check("S1 collapse shrank the card", shrunk, "\(f(before?.height ?? -1))->\(f(after?.height ?? -1))")
        check("S1 no out-of-range offset at any contentSize change (no one-frame clamp)",
              fx.spy.outOfRange == 0, "violations=\(fx.spy.outOfRange) worst=\(f(fx.spy.worst)) events=\(fx.spy.observations)")
        check("S1 final offset is inside the legal range", legal, "off=\(f(fx.cv.contentOffset.y)) max=\(f(fx.maxOffset))")
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
        let anchorY = (before?.minY ?? 0) - fx.cv.contentOffset.y
        fx.spy.reset()
        fx.toggleCard(card)
        fx.pump(1.4)
        let after = fx.frame(of: card)
        let anchorAfter = (after?.minY ?? 0) - fx.cv.contentOffset.y
        check("S2 tool group expanded (range is larger)", fx.toolExpanded)
        check("S2 no out-of-range offset at any contentSize change",
              fx.spy.outOfRange == 0, "violations=\(fx.spy.outOfRange) worst=\(f(fx.spy.worst))")
        check("S2 the card's top is held (anchor reachable)",
              abs(anchorAfter - anchorY) <= 1.0, "anchor \(f(anchorY))->\(f(anchorAfter))")
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
        let start = fx.frame(of: card)!.minY - fx.cv.contentOffset.y
        fx.spy.reset()
        for _ in 0..<6 { fx.toggleCard(card); fx.pump(1.0) }
        let end = fx.frame(of: card)!.minY - fx.cv.contentOffset.y
        check("S3 card top did not drift over 6 toggles", abs(end - start) <= 1.0, "\(f(start))->\(f(end))")
        check("S3 no out-of-range offset during the round trips", fx.spy.outOfRange == 0, "\(fx.spy.outOfRange)")
        check("S3 back to the collapsed state it started from", fx.expanded[card] == false)
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
        fx.pump(1.6)
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
              fx.cv.contentOffset.y <= fx.maxOffset + 1.0)
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
        snapshot("s6-snapshot-swap", fx.vc)
    }

    print("ASK_CARD_ANCHOR_UIKIT_CHECKS checks=\(checks) failures=\(failures) png=\(png)")
    if failures > 0 {
        print("ASK_CARD_ANCHOR_UIKIT_FAIL failures=\(failures)")
        exit(1)
    }
    print("ASK_CARD_ANCHOR_UIKIT_PASS cases=6 checks=\(checks) png=\(png)")
    exit(0)
}
