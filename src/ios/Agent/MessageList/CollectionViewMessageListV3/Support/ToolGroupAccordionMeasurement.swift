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
        var complete: Bool { unmeasured.isEmpty }
        var summary: String {
            let src = ["measured", "cached", "seeded"]
                .map { "\($0)=\(sources[$0] ?? 0)" }
                .joined(separator: " ")
            return "measured=\(heights.count)/\(heights.count + unmeasured.count) \(src)"
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
            sizingCell.clearCachedHeight()
            sizingCell.resetAccordionWindowIfNeeded()
            configure?(sizingCell, item, indexPath)
            lastConfigured = item
            return sizingCell
        }
    }

    /// Measure `rows` (list index + the item drawn at it) inside a private
    /// container added to the same window, at the list's width.
    ///
    /// - Parameters:
    ///   - configure: the PRODUCTION cell configuration. It must run in
    ///     measurement mode (`writesListState: false`) — see rule 1 above.
    ///   - collectionView: the user's list; only its window and width are read.
    ///     Its content offset, its layout and its cells are never touched.
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
        let host = Host()
        host.configure = configure
        let containerLayout = MessageListLayout()
        let container = UICollectionView(frame: CGRect(x: 0, y: 0, width: width, height: 64),
                                         collectionViewLayout: containerLayout)
        container.register(SelfSizingCell.self, forCellWithReuseIdentifier: Host.reuseIdentifier)
        container.isUserInteractionEnabled = false
        container.isScrollEnabled = false
        container.alpha = 0
        container.dataSource = host
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
            var height: CGFloat = 64
            var cell: SelfSizingCell?
            var attempts = 0
            repeat {
                container.frame = CGRect(x: 0, y: 0, width: width, height: height)
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
