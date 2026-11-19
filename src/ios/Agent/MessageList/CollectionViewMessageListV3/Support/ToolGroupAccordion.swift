//
//  ToolGroupAccordion.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-toolgroup-accordion] The pure numbers behind the chat tool-call accordion.
//
//  The home sidebar already opens a folder with a real accordion
//  (Views/ContentView/Sidebar/NativeAccordionList.swift): 0.32s, a smoothstep
//  ease, and a *clipping window* that grows row by row while the text inside
//  keeps its full height (AccordionLayout: `height = min(rowHeight, full*p -
//  row*rowHeight)`). This file is the same math without the sidebar's virtual
//  layout: the chat list keeps its normal self-sizing rows and only asks for
//  "how much of each of these N rows may be shown right now".
//
//  No UIKit import on purpose. `scripts/toolgroup-accordion-tests` compiles
//  this exact block with swiftc on Linux and checks the numbers, so the
//  shipping formulas are the ones the tests run (not a copy).
//

import Foundation

// === BEGIN ToolGroupAccordion ===
enum ToolGroupAccordion {
    /// [T-toolgroup-accordion] Same wall-clock length as the sidebar accordion
    /// (NativeAccordionList.duration = 0.32). One constant, one source.
    static let duration: Double = 0.32

    /// Smoothstep, byte-identical to `AccordionMotion.ease` in
    /// Views/ContentView/Sidebar/AccordionCollectionLayout.swift. Kept as a
    /// separate pure function because the sidebar block lives next to a
    /// UICollectionViewLayout and cannot be linked into the harnesses.
    static func ease(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Clamped linear progress → eased progress. `duration <= 0` means "no
    /// animation": the caller gets 1 at once (reduce motion, tests).
    static func progress(elapsed: Double, duration: Double = duration) -> CGFloat {
        guard duration > 0 else { return 1 }
        if elapsed >= duration { return 1 }
        if elapsed <= 0 { return 0 }
        return ease(CGFloat(elapsed / duration))
    }

    /// Visible height of each member row at `reveal` (0…1).
    ///
    /// The reveal frontier is `total * reveal`; row i may show
    /// `min(natural[i], frontier - Σ natural[0..<i])`. Text inside a row is
    /// never scaled — the row is laid out at its natural height and its cell
    /// clips, exactly like the sidebar's `min(rowHeight, full*p - row*rowHeight)`.
    /// `Σ result == total * reveal` for reveal in 0…1, so the following rows
    /// move by exactly the revealed amount every frame.
    static func visibleHeights(natural: [CGFloat], reveal: CGFloat) -> [CGFloat] {
        let p = min(1, max(0, reveal))
        let total = natural.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return natural.map { _ in 0 } }
        var frontier = total * p
        var out: [CGFloat] = []
        out.reserveCapacity(natural.count)
        for h in natural {
            let full = max(0, h)
            let shown = min(full, max(0, frontier))
            out.append(shown)
            frontier -= full
            if frontier <= 0 { frontier = 0 }
        }
        return out
    }

    /// Legal content-offset window for a scroll view, given plain numbers so
    /// this stays UIKit-free. Mirrors `AccordionMotion.clampedOffset` (the
    /// `max(-inset.top, …)` guard is what makes short content legal: when the
    /// content is shorter than the viewport, min and max collapse to the top).
    static func clampedOffset(_ desired: CGFloat, contentHeight: CGFloat,
                              viewportHeight: CGFloat,
                              topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let minOff = -topInset
        let maxOff = max(minOff, contentHeight - viewportHeight + bottomInset)
        return min(max(minOff, desired), maxOff)
    }

    /// The offset that puts `headerY` back at `anchorY` on screen, clamped to
    /// the legal window. This is the whole "the tapped title must not move"
    /// rule: rows below the header grow downward, so the anchor offset is
    /// normally the offset we already had; it only changes when the content
    /// edge forces a clamp (bottom pin, short content).
    static func anchoredOffset(headerY: CGFloat, anchorY: CGFloat,
                               contentHeight: CGFloat, viewportHeight: CGFloat,
                               topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        clampedOffset(headerY - anchorY,
                      contentHeight: contentHeight, viewportHeight: viewportHeight,
                      topInset: topInset, bottomInset: bottomInset)
    }

    /// How far a header at `headerY` sits from where the user tapped it.
    /// Used by the driver each frame and asserted by the harnesses.
    static func anchorDrift(headerY: CGFloat, contentOffset: CGFloat, anchorY: CGFloat) -> CGFloat {
        headerY - contentOffset - anchorY
    }

    /// The row that straddles the reveal frontier (the only row that needs
    /// clipping), or nil when the frontier lands exactly on a row boundary.
    static func clippedRow(natural: [CGFloat], reveal: CGFloat) -> Int? {
        let visible = visibleHeights(natural: natural, reveal: reveal)
        for (i, h) in visible.enumerated() {
            let full = max(0, natural[i])
            if h > 0.001 && h < full - 0.001 { return i }
        }
        return nil
    }
}
// === END ToolGroupAccordion ===
