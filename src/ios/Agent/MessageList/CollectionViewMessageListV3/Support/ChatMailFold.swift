//
//  ChatMailFold.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-chat-mail-fold] The pure numbers behind the MAIL-STYLE expand / collapse
//  of a chat row block.
//
//  Geometry (verified against the Mail clip, 2026-11-28):
//
//    header  ──────────────────────────────── fixed, never moves
//            │  block of children, natural   │  ← the whole block TRANSLATES
//            │  row heights and spacing      │     DOWN from behind the header
//            ▼                               ▼
//    sibling  ──────────────────────────────── moves with the block's BOTTOM edge
//
//  At reveal 0 the block's bottom edge is exactly at the header's bottom edge,
//  so nothing is visible and the following sibling sits directly below the
//  header. At reveal 1 the block sits fully under the header. In between, the
//  VISIBLE part is the block's BOTTOM `total * reveal` points: the LAST child
//  appears first (its bottom strip is what emerges), the FIRST child rises out
//  from behind the header last; collapsing runs the same film backwards, so the
//  top child disappears first.
//
//  This is the opposite of the sidebar curtain (`AccordionLayout`: the frontier
//  grows from the TOP, the first row appears first) and it is why the chat
//  needs its own helper instead of reusing `ToolGroupAccordion.visibleHeights`.
//
//  Text is never scaled or faded: a straddling child keeps its natural height
//  inside the cell and the CELL clips its TOP (`topClip` points are hidden
//  above the window). The following rows move by exactly the block's bottom
//  edge because Σ visible == total * reveal.
//
//  No UIKit import: `scripts/chat_mail_fold_linux_check.py` compiles this exact
//  block with swiftc on Linux, so the shipping formulas are the ones that are
//  checked (never a copy).
//

import Foundation

// === BEGIN ChatMailFold ===
enum ChatMailFold {

    /// Same wall-clock length as the sidebar accordion / the chat curtain
    /// (ToolGroupAccordion.duration = 0.32): one motion language in the app.
    static let duration: Double = 0.32

    /// Smoothstep, identical to `AccordionMotion.ease` (sidebar) and
    /// `ToolGroupAccordion.ease`.
    static func ease(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Clamped linear progress → eased progress. `duration <= 0` means "no
    /// animation": the caller gets 1 at once (reduce motion).
    static func progress(elapsed: Double, duration: Double = duration) -> CGFloat {
        guard duration > 0 else { return 1 }
        if elapsed >= duration { return 1 }
        if elapsed <= 0 { return 0 }
        return ease(CGFloat(elapsed / duration))
    }

    /// One child row's slice of the block, in block coordinates.
    ///
    ///  * `visible`      – what the row occupies in the list right now: its
    ///                     visible content PLUS the visible part of its
    ///                     trailing gap. This is the height the layout hands
    ///                     the cell (spacing is suppressed for the block and
    ///                     folded into this number, so the bottom edge is
    ///                     exact to the point).
    ///  * `contentVisible` – how much of the row's own content shows (never
    ///                     more than its natural height).
    ///  * `topClip`      – how many points of the row's content are hidden
    ///                     ABOVE the window; the cell lays its content out at
    ///                     the natural height and shifts it up by this much.
    struct Row: Equatable {
        var visible: CGFloat
        var contentVisible: CGFloat
        var topClip: CGFloat
        var isHidden: Bool { visible <= 0.5 }
    }

    /// Total block height: every natural height plus the INTERNAL gaps only.
    /// The trailing gap after the last child belongs to the layout (it follows
    /// the same footer-hug rules as the expanded state), so it is not part of
    /// the block and does not translate.
    static func totalHeight(natural: [CGFloat], rowSpacing: CGFloat) -> CGFloat {
        let n = natural.count
        guard n > 0 else { return 0 }
        let sum = natural.reduce(0) { $0 + max(0, $1) }
        return sum + CGFloat(max(0, n - 1)) * max(0, rowSpacing)
    }

    /// The block's rows at `reveal` (0 = collapsed, 1 = expanded), in order.
    ///
    /// Window in block coordinates: `[total * (1 - reveal), total]` — the
    /// BOTTOM part of the block. Row k occupies `[start, start + h + gap]`
    /// (`[start, start + h]` for the last row).
    static func rows(natural: [CGFloat], rowSpacing: CGFloat, reveal: CGFloat) -> [Row] {
        let n = natural.count
        guard n > 0 else { return [] }
        let p = min(1, max(0, reveal))
        let total = totalHeight(natural: natural, rowSpacing: rowSpacing)
        guard total > 0 else { return natural.map { _ in Row(visible: 0, contentVisible: 0, topClip: 0) } }
        let gap = max(0, rowSpacing)
        let windowStart = total * (1 - p)
        var out: [Row] = []
        out.reserveCapacity(n)
        var start: CGFloat = 0
        for (k, raw) in natural.enumerated() {
            let h = max(0, raw)
            let slotEnd = start + h + (k == n - 1 ? 0 : gap)
            let contentEnd = start + h
            let visible = max(0, min(slotEnd, total) - max(start, windowStart))
            let contentVisible = max(0, min(contentEnd, total) - max(max(start, windowStart), 0))
            // A row outside the window is not drawn at all: report no clip so
            // diagnostics and `clippedRow` only ever see the one straddling row.
            let topClip = visible <= 0.5 ? 0 : max(0, min(windowStart - start, h))
            out.append(Row(visible: visible, contentVisible: contentVisible, topClip: topClip))
            start = slotEnd
        }
        return out
    }

    /// Heights the layout gives the block's rows at `reveal` (spacing folded in).
    /// `Σ result == total * reveal` for reveal in 0…1, which is what makes the
    /// following sibling move with the block's bottom edge instead of popping.
    static func visibleHeights(natural: [CGFloat], rowSpacing: CGFloat, reveal: CGFloat) -> [CGFloat] {
        rows(natural: natural, rowSpacing: rowSpacing, reveal: reveal).map { $0.visible }
    }

    /// Points of each row's content hidden above the window, in order.
    static func topClips(natural: [CGFloat], rowSpacing: CGFloat, reveal: CGFloat) -> [CGFloat] {
        rows(natural: natural, rowSpacing: rowSpacing, reveal: reveal).map { $0.topClip }
    }

    /// The row that straddles the window's TOP edge (the only one that needs a
    /// cell clip), or nil when the edge lands on a row boundary.
    static func clippedRow(natural: [CGFloat], rowSpacing: CGFloat, reveal: CGFloat) -> Int? {
        let r = rows(natural: natural, rowSpacing: rowSpacing, reveal: reveal)
        for (i, row) in r.enumerated() {
            let full = max(0, natural[i])
            if !row.isHidden && row.topClip > 0.001 && row.contentVisible < full - 0.5 { return i }
        }
        return nil
    }

    /// Legal content-offset window for a scroll view (same rule as the sidebar /
    /// the chat curtain: when the content is shorter than the viewport, min and
    /// max collapse to the top inset instead of inverting).
    static func clampedOffset(_ desired: CGFloat, contentHeight: CGFloat,
                              viewportHeight: CGFloat,
                              topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let minOff = -topInset
        let maxOff = max(minOff, contentHeight - viewportHeight + bottomInset)
        return min(max(minOff, desired), maxOff)
    }

    /// The offset that puts the fixed header back at the screen Y the user
    /// tapped. The block grows downward, so this only changes when the content
    /// edge forces a clamp (bottom pin / short content) — never because of the
    /// animation itself.
    static func anchoredOffset(headerY: CGFloat, anchorY: CGFloat,
                               contentHeight: CGFloat, viewportHeight: CGFloat,
                               topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        clampedOffset(headerY - anchorY,
                      contentHeight: contentHeight, viewportHeight: viewportHeight,
                      topInset: topInset, bottomInset: bottomInset)
    }

    /// How far the fixed header sits from where the user tapped it (0 at rest).
    static func anchorDrift(headerY: CGFloat, contentOffset: CGFloat, anchorY: CGFloat) -> CGFloat {
        headerY - contentOffset - anchorY
    }

    /// The reveal a terminated flight must land on: the END of the direction it
    /// was flying (a retarget changes the direction, never the requirement that
    /// the list ends exactly on the business state).
    static func terminalReveal(expanding: Bool) -> CGFloat { expanding ? 1 : 0 }
}
// === END ChatMailFold ===
