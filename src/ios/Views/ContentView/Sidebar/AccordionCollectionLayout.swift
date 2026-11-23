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
        if s.rowHeight > 0 && height < s.rowHeight {
            a.alpha = AccordionMotion.rowAlpha(fraction: height / s.rowHeight)
        } else {
            a.alpha = 1
        }
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
    /// Critically-damped spring curve (monotonic, zero overshoot) normalized to
    /// exact [0, 1] endpoints: responsive initial launch with a gentle iOS-like
    /// deceleration tail instead of symmetric smoothstep.
    static func ease(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let w = 6.2
        let xd = Double(x)
        let norm = 1.0 - (1.0 + w) * exp(-w)
        return CGFloat((1.0 - (1.0 + w * xd) * exp(-w * xd)) / norm)
    }
    /// Soft alpha ramp for a partially revealed member row so glyphs and edges
    /// feather in/out instead of popping across a hard clipping boundary.
    static func rowAlpha(fraction: CGFloat) -> CGFloat {
        let f = min(1, max(0, fraction))
        if f >= 0.65 { return 1 }
        let r = f / 0.65
        return r * r * (3 - 2 * r)
    }
    /// Adaptive flight duration: compact 1–2 row folders settle crisply (~0.26s),
    /// taller folders get up to ~0.36s for the gentle deceleration tail, and
    /// short mid-flight reversals stay snappy (~0.22s+).
    static func duration(from old: [CGFloat], to target: [CGFloat],
                         sections: [AccordionSectionGeometry], viewportHeight: CGFloat) -> CFTimeInterval {
        var maxVisualDelta: CGFloat = 0
        var maxRevealDelta: CGFloat = 0
        let cap = max(360, viewportHeight)
        for i in sections.indices where i < old.count && i < target.count {
            let dr = abs(target[i] - old[i])
            if dr > maxRevealDelta { maxRevealDelta = dr }
            let dh = min(sections[i].fullHeight, cap) * dr
            if dh > maxVisualDelta { maxVisualDelta = dh }
        }
        let heightFactor = min(1, max(0, (maxVisualDelta - 68) / 480))
        let base = 0.26 + 0.10 * Double(heightFactor)
        let travelScale = 0.65 + 0.35 * Double(min(1, max(0, maxRevealDelta)))
        return min(0.38, max(0.22, base * travelScale))
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
