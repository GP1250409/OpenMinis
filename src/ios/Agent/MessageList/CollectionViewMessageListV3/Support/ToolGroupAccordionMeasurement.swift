//
//  ToolGroupAccordionMeasurement.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-toolgroup-accordion] Legitimate off-screen measurement for the folded tool
//  run's member rows.
//
//  Why this type exists (and why it is NOT part of the coordinator): the
//  accordion freezes every member row's natural height before it animates, and
//  a wrong height makes the frontier land in the wrong place. The rows that are
//  off screen have no cell, so they have to be measured in a throwaway
//  container. Three rules, each of which the previous version broke:
//
//  1. The container must never touch the LIST. It takes no `MessageListLayout`
//     of the main list at all — it can only return heights, which the caller
//     writes — and the cell configuration it is handed is invoked in
//     measurement mode, so the production `configureCell` does not write
//     `contentKeyByIndex` / `metricsTagByIndex` / estimates / memo seeds with the
//     container's 0…n-1 index paths (that used to overwrite the first rows' real
//     keys and mis-attribute memo heights).
//
//  2. Every row must be really measured — not just the rows that happened to
//     fall inside a container sized from the ESTIMATES. A shell output row is
//     often 10× its 36 pt estimate, so one pass over `estimatedHeight + 40`
//     covered the first few rows and the whole run fell back to the instant
//     switch. Rows are measured ONE AT A TIME here: the container holds a single
//     item, so the row is always inside its bounds whatever its height, and the
//     container only has to be tall enough for the layout to place that one row
//     (it starts at y = 0, so this is a formality, kept as a conditional growth
//     loop rather than a magic constant).
//
//  3. A measurement must be distinguishable from a proposal. A merely
//     positive `fitted` is true for the caller's own estimate too, because
//     `preferredLayoutAttributesFitting` returns its input unchanged from its
//     off-collection guard, its hosting-exception fallback and its
//     `configGeneration` race. The cell reports a `heightReceipt` only when a
//     real height exists; a row without one is returned as UNMEASURED so the
//     caller can switch instantly instead of animating to a guess.
//
//  4. The container must measure in the SAME coordinate / safe-area context the
//     row has inside the list. Rule 4 was missing and run 44506193558 caught
//     it: the container used to be parked at the window origin, i.e. inside the
//     62pt status-bar safe area, while the list's rows live below its
//     `adjustedContentInset.top`. A `UIHostingConfiguration` cell laid out
//     inside that safe area reports its content height PLUS the inset
//     (320 → 382 on a notch device), so the same row measured 62pt taller off
//     screen than on screen and every frozen height — the reveal frontier, the
//     anchor, the final row height — was wrong. The container is therefore
//     placed where the list's FIRST row lives (the list's origin inside the
//     window, pushed down by its own top inset) and never inside the window's
//     top safe area. The number comes from the live window/list geometry, never
//     from a constant: rotation, split screen and the keyboard move these
//     insets and the probe follows them.
//

import UIKit

/// [T-toolgroup-accordion] One-shot, row-at-a-time measurement of the member
/// rows that have no cell on screen.
enum ToolGroupAccordionMeasurement {

    /// What the probe actually achieved. `heights` only ever contains REAL
    /// heights (cell receipts); every other requested row is listed in
    /// `unmeasured` so the caller cannot mistake a partial run for a full one.
    struct Result {
        var heights: [Int: CGFloat] = [:]
        var unmeasured: [Int] = []
        /// How the heights were obtained, for the caller's log:
        /// `measured` (systemLayoutSizeFitting on this probe), `cached`
        /// (this cell had already measured this width) or `seeded` (a real
        /// height measured earlier for the same content key).
        var sources: [String: Int] = [:]
        /// Rows whose cell UIKit refused to create (no window / zero width /
        /// layout kept them outside the container). Diagnostics only.
        var unhosted: [Int] = []
        /// The coordinate / safe-area context the probe measured in
        /// (`rowY` in window coordinates, the container's top inset, the list's
        /// origin and the window's top safe-area inset). Diagnostics only: a
        /// context mismatch is exactly the defect run 44506193558 exposed, so
        /// the caller's log line carries the numbers.
        var context: String = "-"
        var complete: Bool { unmeasured.isEmpty }
        var summary: String {
            let src = ["measured", "cached", "seeded"]
                .map { "\($0)=\(sources[$0] ?? 0)" }
                .joined(separator: " ")
            return "measured=\(heights.count)/\(heights.count + unmeasured.count) \(src) ctx=\(context)"
        }
    }

    /// The measuring collection view's data source: one row, configured through
    /// the caller's (production) configuration closure.
    private final class Host: NSObject, UICollectionViewDataSource {
        static let reuseIdentifier = "ToolGroupAccordionMeasurementCell"
        var item: MessageListItem?
        var lastConfigured: MessageListItem?
        var configure: ((SelfSizingCell, MessageListItem, IndexPath) -> Void)?
        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            item == nil ? 0 : 1
        }
        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            // UIKit requires every cell returned from a data source to come
            // from register + dequeueReusableCell on THIS throwaway container
            // (a bare cell throws NSInternalInconsistencyException at runtime).
            // This runs inside the private container's own layout pass, never
            // touching the main list's diffable data source.
            let cell = view.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)
            guard let sizingCell = cell as? SelfSizingCell, let item else { return cell }
            // A recycled cell has already been cleaned by the cell's own
            // `prepareForReuse` (it clears the clip window and the receipt), and
            // a brand-new one starts clean — the probe must not reach for the
            // cell's file-private hooks from here. Only the shared, internal
            // cache reset is called.
            sizingCell.clearCachedHeight()
            configure?(sizingCell, item, indexPath)
            lastConfigured = item
            return sizingCell
        }
    }

    /// Measure `rows` (list index + the item drawn at it) inside a private
    /// container added to the same window, at the list's width AND in the same
    /// coordinate / safe-area context its rows have (rule 4 above).
    ///
    /// - Parameters:
    ///   - configure: the PRODUCTION cell configuration. It must run in
    ///     measurement mode (`writesListState: false`) — see rule 1 above.
    ///   - collectionView: the user's list; only its window, width, origin and
    ///     top inset are read. Its content offset, its layout and its cells are
    ///     never touched.
    static func naturalHeights(rows: [(index: Int, item: MessageListItem)],
                               in collectionView: UICollectionView,
                               configure: @escaping (SelfSizingCell, MessageListItem, IndexPath) -> Void) -> Result {
        var result = Result()
        guard !rows.isEmpty else { return result }
        let width = collectionView.bounds.width
        guard let window = collectionView.window, width > 1 else {
            result.unmeasured = rows.map(\.index)
            return result
        }
        // [T-toolgroup-accordion] Rule 4: the probe row has to sit where a list
        // row sits. `listTopInset` is the list's own top inset (its first row
        // lives below it) and `windowTopInset - listOrigin.y` lifts a list that
        // starts at the window origin out of the window's top safe area. Taking
        // the larger of the two means the row is never drawn inside the safe
        // area, which is what made a 320pt row measure 382pt (run 44506193558).
        // Both numbers are read live, so rotation / split screen / keyboard
        // changes are followed instead of compensated with a constant.
        let listOrigin = collectionView.convert(CGPoint.zero, to: window)
        let listTopInset = collectionView.adjustedContentInset.top
        let windowTopInset = window.safeAreaInsets.top
        let topInset = max(listTopInset, max(0, windowTopInset - listOrigin.y))
        result.context = String(format: "rowY=%.1f inset=%.1f listY=%.1f listInset=%.1f safeTop=%.1f",
                                listOrigin.y + topInset, topInset, listOrigin.y, listTopInset, windowTopInset)
        let host = Host()
        host.configure = configure
        let containerLayout = MessageListLayout()
        let container = UICollectionView(frame: CGRect(x: listOrigin.x, y: listOrigin.y, width: width, height: 64),
                                         collectionViewLayout: containerLayout)
        container.register(SelfSizingCell.self, forCellWithReuseIdentifier: Host.reuseIdentifier)
        container.isUserInteractionEnabled = false
        container.isScrollEnabled = false
        container.alpha = 0
        container.dataSource = host
        // `.never` + an explicit inset: the container no longer depends on what
        // UIKit infers for an inset-adjusting scroll view it did not put in a
        // view controller, so the probe context is the LIST's context only.
        container.contentInsetAdjustmentBehavior = .never
        container.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        container.contentOffset = CGPoint(x: 0, y: -topInset)
        window.addSubview(container)
        defer {
            container.removeFromSuperview()
            container.dataSource = nil
        }

        for row in rows {
            host.item = row.item
            host.lastConfigured = nil
            containerLayout.clearHeightCache()
            container.reloadData()
            // ONE row is in the container, at y = 0, so any usable bounds holds
            // it. The growth loop only covers the degenerate case (a layout that
            // places the single row outside a 64pt container); it is a
            // CONDITION, not a content cap: it stops as soon as UIKit hands over
            // the cell, and reports the row unhosted after a few doublings
            // rather than pretending it was measured.
            // The starting height leaves the whole 64pt window BELOW the top
            // inset (the previous 64 included the inset, which left only a
            // sliver of the row inside the container on a notch device).
            var height: CGFloat = 64 + topInset
            var cell: SelfSizingCell?
            var attempts = 0
            repeat {
                // The ORIGIN and the inset stay fixed: they are the measurement
                // context. Only the height grows, and the offset is re-asserted
                // so the single row is always the row drawn just below the
                // safe-area edge.
                container.frame = CGRect(x: listOrigin.x, y: listOrigin.y, width: width, height: height)
                container.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
                container.contentOffset = CGPoint(x: 0, y: -topInset)
                container.layoutIfNeeded()
                cell = container.cellForItem(at: IndexPath(item: 0, section: 0)) as? SelfSizingCell
                if cell == nil {
                    height *= 2
                    attempts += 1
                }
            } while cell == nil && attempts < 4
            guard let cell, host.lastConfigured == row.item else {
                result.unhosted.append(row.index)
                result.unmeasured.append(row.index)
                continue
            }
            let ip = IndexPath(item: 0, section: 0)
            let attrs = UICollectionViewLayoutAttributes(forCellWith: ip)
            // Same width basis the list measures at: the collection's bounds.
            // The proposed height is the row's current estimate — it must NOT
            // end up as the answer, which is exactly what the receipt proves.
            attrs.size = CGSize(width: width, height: max(1, cell.bounds.height))
            _ = cell.preferredLayoutAttributesFitting(attrs)
            // [T-toolgroup-accordion] A receipt means a real height exists for
            // this width; nil means the fitting pass returned its input (guard,
            // exception or generation race) and the number it returned is the
            // estimate we proposed. No `height > 0.5` heuristic here.
            if let receipt = cell.measuredHeight(forWidth: width) {
                result.heights[row.index] = receipt.height
                result.sources[receipt.source.rawValue, default: 0] += 1
            } else {
                result.unmeasured.append(row.index)
            }
            cell.clearCachedHeight()
        }
        return result
    }
}
