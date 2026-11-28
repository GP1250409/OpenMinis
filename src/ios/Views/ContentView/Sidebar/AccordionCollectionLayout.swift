import UIKit

/// [T-sidebar-mail-fold] iOS 16 Mail's fold, as pure geometry (no UIKit types
/// beyond CGFloat / CGRect, so `scripts/accordion-tests/mail_fold_linux_check.py`
/// can compile THIS block verbatim on Linux).
///
/// The member block keeps its FULL height and is laid out BOTTOM-ALIGNED
/// inside the section's member window: the last member's bottom edge is welded
/// to the window's bottom edge (the edge the footer and every lower sibling
/// follow), while the window's TOP edge stays at the header. Only the bottom
/// edge moves, so a row is clipped at its TOP — by the header — and every
/// visible row keeps its exact row height and pitch:
///
///   expand   → the LAST member appears first directly under the header, then
///              all visible rows translate DOWN together; earlier members
///              emerge at the header line, one at a time
///   collapse → the FIRST member disappears first behind the header, the rest
///              translate UP together under unchanged pitch
///
/// This replaces the old top-aligned window (first member grows out of the
/// header, tail clipped at the moving bottom edge, i.e. top-first reveal).
/// No scaling, no fading, no row re-measure: only a translating clipped block.
enum AccordionMemberFold {
    /// One member row's on-screen slice.
    struct Slice: Equatable {
        /// Visible top, in the layout's coordinate space.
        var y: CGFloat
        /// Visible height. The row still PITCHES at `rowHeight`; this is the
        /// part the header does not cover.
        var height: CGFloat
        /// How much of the row's top is covered. Its content keeps the FULL
        /// row frame and is drawn at `-clipTop`, so text/icon stay aligned to
        /// their own row instead of to the clip.
        var clipTop: CGFloat
        var isVisible: Bool { height > 0.0001 }
    }
    /// Clamped reveal progress for one section.
    static func progress(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// Visible height of the member window: the moving quantity.
    static func windowHeight(count: Int, rowHeight: CGFloat, progress value: CGFloat) -> CGFloat {
        guard count > 0, rowHeight > 0 else { return 0 }
        return CGFloat(count) * rowHeight * progress(value)
    }

    static func slice(row: Int, count: Int, rowHeight: CGFloat, blockTop: CGFloat,
                      progress value: CGFloat) -> Slice {
        guard count > 0, rowHeight > 0, row >= 0, row < count else {
            return Slice(y: blockTop, height: 0, clipTop: rowHeight)
        }
        let bottom = blockTop + windowHeight(count: count, rowHeight: rowHeight, progress: value)
        // Bottom-aligned: the last member's bottom IS the window bottom at
        // every progress value, so the lower sibling never detaches from it.
        let fullTop = bottom - CGFloat(count - row) * rowHeight
        let clipTop = min(rowHeight, max(0, blockTop - fullTop))
        let visibleTop = max(fullTop, blockTop)
        return Slice(y: visibleTop, height: rowHeight - clipTop, clipTop: clipTop)
    }

    /// Members that touch the window at this progress — the topmost one may be
    /// partially clipped, the rest are full rows. Last member first.
    static func visibleRows(count: Int, rowHeight: CGFloat, progress value: CGFloat) -> Range<Int> {
        guard count > 0, rowHeight > 0 else { return 0..<0 }
        let h = windowHeight(count: count, rowHeight: rowHeight, progress: value)
        guard h > 0 else { return 0..<0 }
        let touching = min(count, max(1, Int(ceil(h / rowHeight - 1e-6))))
        return (count - touching)..<count
    }

    /// Row indices worth enumerating for a viewport rect. The lower bound is
    /// EXACT — the first row the header does not fully cover — so a row that
    /// has scrolled behind the header is never enumerated; the upper bound is
    /// the rect edge widened by one row (callers still test each frame).
    static func rowBounds(in rect: CGRect, count: Int, rowHeight: CGFloat,
                          blockTop: CGFloat, blockBottom: CGFloat) -> ClosedRange<Int>? {
        guard count > 0, rowHeight > 0, blockBottom > blockTop else { return nil }
        let lo = max(blockTop, rect.minY)
        let hi = min(blockBottom, rect.maxY)
        guard hi > lo else { return nil }
        // First row whose bottom clears the header: r > count - 1 - h/rowHeight.
        let h = blockBottom - blockTop
        let firstVisible = Int(floor(CGFloat(count) - 1 - h / rowHeight)) + 1
        // Full (unclipped) top of row 0; rows pitch upward from the bottom.
        let base = blockBottom - CGFloat(count) * rowHeight
        let first = max(0, max(firstVisible, Int(floor((lo - base) / rowHeight)) - 1))
        let last = min(count - 1, Int(floor((hi - base) / rowHeight)) + 1)
        guard first <= last else { return nil }
        return first...last
    }
}
// END AccordionMemberFold

/// Layout attributes that carry the Mail fold's top clip to the cell, so the
/// cell can keep the row's content frame and only translate it.
final class AccordionRowAttributes: UICollectionViewLayoutAttributes {
    var clipTop: CGFloat = 0
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! AccordionRowAttributes
        copy.clipTop = clipTop
        return copy
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AccordionRowAttributes else { return false }
        return super.isEqual(object) && other.clipTop == clipTop
    }
}

/// Geometry-only, virtualized accordion. Membership never changes on a toggle.
/// A member's text keeps its full height; only its cell's clipping window grows.
/// No self-sizing, SwiftUI animation transaction, or per-frame parent state writes.
struct AccordionSectionGeometry: Equatable {
    var id: String
    var folderID: String?
    var count: Int
    var rowHeight: CGFloat
    var labelHeight: CGFloat
    var headerHeight: CGFloat
    var footerHeight: CGFloat
    var prefixCount: Int { (labelHeight > 0 ? 1 : 0) + (headerHeight > 0 ? 1 : 0) }
    var itemCount: Int { prefixCount + count }
    var fullHeight: CGFloat { CGFloat(count) * rowHeight }
}

final class AccordionCollectionLayout: UICollectionViewLayout {
    var sections: [AccordionSectionGeometry] = []
    var reveal: [CGFloat] = []
    // During a transition translate the CONTENT coordinate system, not the
    // UIScrollView. Remove this translation with ONE atomic offset adjustment
    // at completion. This avoids fighting UIKit's pan/deceleration each frame.
    var translation: CGFloat = 0
    var minimumContentHeight: CGFloat = 0
    private(set) var starts: [CGFloat] = []
    private(set) var ends: [CGFloat] = []
    private(set) var naturalHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        starts.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for (i, s) in sections.enumerated() {
            starts.append(y)
            let p = i < reveal.count ? min(1, max(0, reveal[i])) : 1
            y += s.labelHeight + s.headerHeight + s.fullHeight * p + s.footerHeight
            ends.append(y)
        }
        naturalHeight = y
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0,
               height: max(0, minimumContentHeight, naturalHeight + translation))
    }

    func headerY(section: Int) -> CGFloat {
        guard sections.indices.contains(section), starts.indices.contains(section) else { return 0 }
        let s = sections[section]
        return s.headerHeight > 0 ? starts[section] + s.labelHeight : starts[section]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard sections.indices.contains(indexPath.section), starts.indices.contains(indexPath.section) else { return nil }
        let s = sections[indexPath.section]
        guard (0..<s.itemCount).contains(indexPath.item) else { return nil }
        let a = AccordionRowAttributes(forCellWith: indexPath)
        let width = collectionView?.bounds.width ?? 0
        var y = starts[indexPath.section] + translation
        if s.labelHeight > 0 && indexPath.item == 0 {
            // The label is the SAME cell throughout toggles. Pinning is pure
            // layout math, no asynchronously observed title probes / overlay.
            let top = (collectionView?.contentOffset.y ?? 0) + (collectionView?.adjustedContentInset.top ?? 0)
            y = min(max(y, top), ends[indexPath.section] + translation - s.labelHeight)
            a.frame = CGRect(x: 0, y: y, width: width, height: s.labelHeight)
            a.zIndex = 1000
            return a
        }
        y += s.labelHeight
        if s.headerHeight > 0 && indexPath.item == s.prefixCount - 1 {
            a.frame = CGRect(x: 0, y: y, width: width, height: s.headerHeight)
            a.zIndex = 1
            return a
        }
        let row = indexPath.item - s.prefixCount
        // [T-sidebar-mail-fold] Member rows are a BOTTOM-aligned block clipped
        // at the header, so the cell carries the part of its top the header
        // covers. Endpoints are the shipped layout exactly (p == 1 → no clip,
        // full pitch from the header; p == 0 → invisible).
        let p = indexPath.section < reveal.count ? reveal[indexPath.section] : 1
        let slice = AccordionMemberFold.slice(row: row, count: s.count, rowHeight: s.rowHeight,
                                              blockTop: y + s.headerHeight, progress: p)
        a.frame = CGRect(x: 0, y: slice.y, width: width, height: slice.height)
        a.clipTop = slice.clipTop
        a.isHidden = !slice.isVisible
        return a
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        guard starts.count == sections.count else { return result }
        // O(number of groups + visible rows), NOT O(all sessions).
        for (i, s) in sections.enumerated() {
            guard ends[i] + translation >= rect.minY, starts[i] + translation <= rect.maxY else { continue }
            for item in 0..<s.prefixCount {
                if let a = layoutAttributesForItem(at: IndexPath(item: item, section: i)), a.frame.intersects(rect) {
                    result.append(a)
                }
            }
            guard s.count > 0, s.rowHeight > 0 else { continue }
            // [T-sidebar-mail-fold] Enumerate the members that actually touch
            // the bottom-aligned window inside `rect` — including the one row
            // the header partially clips — never a row already scrolled behind
            // the header, and never O(count) for an expanded 4700-row folder.
            let p = i < reveal.count ? reveal[i] : 1
            let blockTop = starts[i] + translation + s.labelHeight + s.headerHeight
            let blockBottom = blockTop + AccordionMemberFold.windowHeight(
                count: s.count, rowHeight: s.rowHeight, progress: p)
            guard let bounds = AccordionMemberFold.rowBounds(in: rect, count: s.count,
                                                             rowHeight: s.rowHeight,
                                                             blockTop: blockTop,
                                                             blockBottom: blockBottom) else { continue }
            for row in bounds {
                if let a = layoutAttributesForItem(at: IndexPath(item: s.prefixCount + row, section: i)),
                   !a.isHidden, a.frame.intersects(rect) { result.append(a) }
            }
        }
        return result
    }
}

/// Shared by production and simulator regression tests.
enum AccordionMotion {
    static func ease(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t)); return x * x * (3 - 2 * x)
    }
    static func clampedOffset(_ desired: CGFloat, contentHeight: CGFloat,
                              viewportHeight: CGFloat, inset: UIEdgeInsets) -> CGFloat {
        min(max(-inset.top, desired), max(-inset.top, contentHeight - viewportHeight + inset.bottom))
    }
    static func translation(startHeader: CGFloat, currentHeader: CGFloat, endHeader: CGFloat,
                            startOffset: CGFloat, endOffset: CGFloat, progress: CGFloat) -> CGFloat {
        // Interpolate only the UNAVOIDABLE boundary-clamp displacement.
        // Otherwise the tapped header is perfectly stationary on screen.
        let endPresentation = endHeader + startOffset - endOffset
        return startHeader + (endPresentation - startHeader) * progress - currentHeader
    }
}
