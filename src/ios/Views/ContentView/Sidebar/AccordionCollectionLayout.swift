import UIKit

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
        return starts[section] + sections[section].labelHeight
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard sections.indices.contains(indexPath.section), starts.indices.contains(indexPath.section) else { return nil }
        let s = sections[indexPath.section]
        guard (0..<s.itemCount).contains(indexPath.item) else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
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
        let p = indexPath.section < reveal.count ? min(1, max(0, reveal[indexPath.section])) : 1
        let height = min(s.rowHeight, max(0, s.fullHeight * p - CGFloat(row) * s.rowHeight))
        a.frame = CGRect(x: 0, y: y + s.headerHeight + CGFloat(row) * s.rowHeight,
                         width: width, height: height)
        a.isHidden = height <= 0
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
            let y = starts[i] + translation + s.labelHeight + s.headerHeight
            let first = max(0, min(s.count - 1, Int(floor((rect.minY - y) / s.rowHeight))))
            let last = max(0, min(s.count - 1, Int(floor((rect.maxY - y) / s.rowHeight))))
            if first <= last {
                for row in first...last {
                    if let a = layoutAttributesForItem(at: IndexPath(item: s.prefixCount + row, section: i)),
                       !a.isHidden, a.frame.intersects(rect) { result.append(a) }
                }
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
