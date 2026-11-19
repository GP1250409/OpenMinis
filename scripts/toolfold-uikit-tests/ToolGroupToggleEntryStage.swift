// [T-toolgroup-accordion] Entry-level coverage of the tool-group toggle.
//
// This stage drives the SAME production entry the chat list's tap drives:
// `ToolGroupAccordionToggle.run(_:in:)` (the coordinator's `toggleToolGroup`
// calls it; see Support/ToolGroupAccordionToggle.swift). It is not a look-alike
// next to the business code — the flight, the measurement probe, the receipt
// checks, the contiguous-span rule and the end-of-flight anchor restore are all
// the shipping implementations.
//
// The list here is a real UIWindow-hosted UICollectionView with the real
// MessageListLayout, real SelfSizingCell and real UIHostingConfiguration rows.
// The rows are deliberately TALL (320 / 300 / 280pt against an 80pt estimate,
// with the run parked below five 220pt rows) so the member rows are off screen:
// that is the "long tool output" case whose estimate-based container used to
// leave the run unmeasured and fall back to an instant switch.

import Foundation
import SwiftUI
import UIKit

final class ToolGroupToggleEntryStage: NSObject, UICollectionViewDataSource {

    private let window: UIWindow
    private let report: (Bool, String) -> Void
    private let layout = MessageListLayout()
    private var list: UICollectionView!

    private let messageId = UUID()
    private let groupBlock = UUID()
    private let memberBlocks = [UUID(), UUID(), UUID()]
    private let followBlock = UUID()
    private let fillerBlocks = (0..<5).map { _ in UUID() }

    private var items: [MessageListItem] = []
    private var contentHeights: [MessageListItem: CGFloat] = [:]
    private var pendingExpanded = true
    private var flight: ToolGroupAccordionFlight?
    private var applyCallers: [String] = []
    private var anchors: [CGFloat] = []

    private var reduceMotion = false
    private var streaming = false
    private(set) var checks = 0
    private(set) var failures: [String] = []

    private var memberItems: [MessageListItem] {
        memberBlocks.map { .assistantBlock(messageId, $0) }
    }
    private var groupItem: MessageListItem { .toolGroup(messageId, groupBlock) }
    private var expectedExpandedCount: Int { fillerBlocks.count + 1 + memberBlocks.count + 1 }
    private var expectedFoldedCount: Int { fillerBlocks.count + 1 + 1 }

    init(window: UIWindow, report: @escaping (Bool, String) -> Void) {
        self.window = window
        self.report = report
        super.init()
        list = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500),
                                collectionViewLayout: layout)
        list.dataSource = self
        list.register(SelfSizingCell.self, forCellWithReuseIdentifier: "entry-row")
        list.backgroundColor = .white
        window.addSubview(list)
        rebuildFolded()
    }

    private func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures.append(label) }
        report(ok, "entry: " + label)
    }

    // MARK: - Data

    private func cellHeight(_ item: MessageListItem) -> CGFloat {
        contentHeights[item] ?? 80
    }

    private func configureRow(_ cell: SelfSizingCell, item: MessageListItem) {
        let height = cellHeight(item)
        cell.backgroundColor = .clear
        cell.applyContentConfiguration(
            UIHostingConfiguration { Color.clear.frame(height: height) }
                .minSize(width: 0, height: 0)
                .margins(.all, 0))
    }

    private func rebuildFolded() {
        items = fillerBlocks.map { .assistantBlock(messageId, $0) }
            + [groupItem, .assistantBlock(messageId, followBlock)]
        for block in fillerBlocks { contentHeights[.assistantBlock(messageId, block)] = 220 }
        contentHeights[groupItem] = 28
        contentHeights[.assistantBlock(messageId, followBlock)] = 120
        for block in memberBlocks { contentHeights[.assistantBlock(messageId, block)] = 0 }
        contentHeights[.assistantBlock(messageId, memberBlocks[0])] = 320
        contentHeights[.assistantBlock(messageId, memberBlocks[1])] = 300
        contentHeights[.assistantBlock(messageId, memberBlocks[2])] = 280
        pendingExpanded = false
        reload()
    }

    private func reload() {
        layout.clearToolGroupAccordion()
        for (index, item) in items.enumerated() {
            layout.setEstimatedHeight(cellHeight(item), at: index)
        }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    /// The BUSINESS structure apply: insert / remove the member rows, exactly
    /// what the coordinator's `applySnapshot` does to the list.
    private func syncStructure() {
        let members = memberItems
        items.removeAll { members.contains($0) }
        if pendingExpanded, let at = items.firstIndex(of: groupItem).map({ $0 + 1 }) {
            items.insert(contentsOf: members, at: at)
        }
        for (index, item) in items.enumerated() {
            layout.setEstimatedHeight(cellHeight(item), at: index)
        }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "entry-row", for: indexPath) as! SelfSizingCell
        configureRow(cell, item: items[indexPath.item])
        return cell
    }

    // MARK: - The production environment the coordinator passes

    private func environment() -> ToolGroupAccordionToggle.Environment {
        ToolGroupAccordionToggle.Environment(
            collectionView: list,
            layout: layout,
            items: { [unowned self] in self.items },
            applyStructure: { [unowned self] caller in
                self.applyCallers.append(caller)
                self.syncStructure()
            },
            // Measurement mode: same content, nothing written into this list.
            configureForMeasurement: { [unowned self] cell, item, _ in
                self.configureRow(cell, item: item)
            },
            restoreAnchor: { [unowned self] _, anchorY in self.anchors.append(anchorY) },
            storeFlight: { [unowned self] flight in self.flight = flight },
            currentFlight: { [unowned self] in self.flight },
            isReduceMotion: { [unowned self] in self.reduceMotion },
            isStreaming: { [unowned self] in self.streaming },
            log: { _ in })
    }

    private func request(expanding: Bool) -> ToolGroupAccordionToggle.Request {
        ToolGroupAccordionToggle.Request(item: groupItem,
                                         memberItems: memberItems,
                                         expanding: expanding,
                                         oldIndex: fillerBlocks.count,
                                         anchorY: 40,
                                         groupTag: "entry")
    }

    // MARK: - Cases

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { self.expandCase() }
    }

    private func expandCase() {
        pendingExpanded = true
        let outcome = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        if case .started = outcome {} else { check(false, "expand: the transaction started (outcome=\(outcome))") }
        check(items.count == expectedExpandedCount,
              "expand: the business apply put the member rows in the list (\(items.count)/\(expectedExpandedCount))")
        check(applyCallers.first == "toolGroupToggle", "expand: structure applied through the caller's own apply")
        check(flight != nil, "expand: a production flight is live")
        let headerIndex = fillerBlocks.count
        if let plan = flight?.currentPlan {
            let heights = plan.naturalHeights
            let expected: [CGFloat] = [320, 300, 280]
            let allMeasured = heights.count == expected.count
                && zip(heights, expected).allSatisfy { pair in abs(pair.0 - pair.1) < 2 }
            check(allMeasured,
                  "expand: every off-screen member row is really measured, not estimated (\(heights))")
            check(plan.memberRange == headerIndex + 1...(headerIndex + memberBlocks.count),
                  "expand: the span is the contiguous window under the header (\(plan.memberRange))")
            check(plan.headerIndex == headerIndex, "expand: the plan points at the tapped row (\(plan.headerIndex))")
            check(plan.memberItems == memberItems, "expand: the plan carries the real member identities")
        } else {
            check(false, "expand: the flight published its plan")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { self.expandMidFlight() }
    }

    private func expandMidFlight() {
        guard let flight else { check(false, "mid: the flight is still live"); return }
        let reveal = flight.reveal
        check(reveal > 0.05 && reveal < 0.95,
              "mid: the run is partially revealed, not cut (\(String(format: "%.3f", reveal)))")
        check(flight.framesApplied >= 3, "mid: several frames ran (\(flight.framesApplied))")
        check(layout.toolGroupAccordionSpan != nil, "mid: the reveal window is installed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) { self.expandEnded() }
    }

    private func expandEnded() {
        check(flight == nil, "expand: the flight cleared itself at the end")
        check(layout.toolGroupAccordionSpan == nil, "expand: the reveal window is gone")
        check(anchors.last == 40, "expand: the tapped row was put back (\(anchors.last ?? -1))")
        check(items.count == expectedExpandedCount, "expand: the rows stay open")
        check(applyCallers.contains("toolGroupAccordionEnd"), "expand: the end converged through applySnapshot")
        let headerIndex = fillerBlocks.count
        let measured: [CGFloat] = memberItems.indices.map { offset in
            layout.layoutAttributesForItem(at: IndexPath(item: headerIndex + 1 + offset, section: 0))?.frame.height ?? 0
        }
        let expected: [CGFloat] = [320, 300, 280]
        check(zip(measured, expected).allSatisfy { pair in abs(pair.0 - pair.1) < 2 },
              "expand: every member row sits at its measured height (\(measured))")
        collapseCase()
    }

    private func collapseCase() {
        pendingExpanded = false
        let before = anchors.count
        let outcome = ToolGroupAccordionToggle.run(request(expanding: false), in: environment())
        if case .started = outcome {} else { check(false, "close: the transaction started (outcome=\(outcome))") }
        check(items.count == expectedExpandedCount,
              "close: the member rows stay in the list while they collapse (\(items.count))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            self.check(self.items.count == self.expectedFoldedCount,
                       "close: the rows are dropped once collapsed (\(self.items.count)/\(self.expectedFoldedCount))")
            self.check(self.layout.toolGroupAccordionSpan == nil, "close: the reveal window is gone")
            self.check(self.anchors.count > before, "close: the tapped row was put back again")
            self.check((self.flight?.reveal ?? 0) == 0, "close: the run ended closed")
            self.reduceMotionCase()
        }
    }

    private func reduceMotionCase() {
        reduceMotion = true
        let outcome = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        if case .fallback(let reason) = outcome {
            check(reason == "reduce-motion", "reduce motion: the transaction declines (\(reason))")
        } else {
            check(false, "reduce motion: the transaction declines (outcome=\(outcome))")
        }
        check(flight == nil, "reduce motion: no flight was started")
        check(items.count == expectedFoldedCount, "reduce motion: the structure was left to the caller's instant switch")
        reduceMotion = false
        streamingCase()
    }

    private func streamingCase() {
        streaming = true
        let outcome = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        if case .fallback(let reason) = outcome {
            check(reason == "streaming", "streaming: the transaction declines (\(reason))")
        } else {
            check(false, "streaming: the transaction declines (outcome=\(outcome))")
        }
        check(flight == nil, "streaming: no flight was started")
        streaming = false
        listWritesCase()
    }

    /// The measurement mode must not write the LIST's index-keyed state: the
    /// probe's index paths are its own 0…n-1, so a write here used to overwrite
    /// the first rows' content keys (and their memo attribution).
    private func listWritesCase() {
        layout.registerCellContentKey("list-key", index: 0, metricsTag: "list-tag", writesListState: true)
        check(layout.contentKey(at: 0) == "list-key", "list state: a real configuration registers its content key")
        layout.registerCellContentKey("probe-key", index: 0, metricsTag: "probe-tag", writesListState: false)
        check(layout.contentKey(at: 0) == "list-key",
              "list state: measurement mode does NOT overwrite the list's content key (\(layout.contentKey(at: 0) ?? "nil"))")
        // And the probe really measured through the same production configure:
        let rows = [(index: 5, item: memberItems[0])]
        let probe = ToolGroupAccordionMeasurement.naturalHeights(
            rows: rows, in: list,
            configure: { [unowned self] cell, item, _ in self.configureRow(cell, item: item) })
        check(abs((probe.heights[5] ?? 0) - 320) < 2,
              "probe: a tall row is measured to its real height (\(probe.heights[5] ?? -1))")
        check(probe.complete, "probe: the row is not reported unmeasured")
        // Short content: the reveal never scrolls past the legal top.
        rebuildFolded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            let top = -self.list.adjustedContentInset.top
            self.check(abs(self.list.contentOffset.y - top) < 0.5,
                       "short content: the list stays at its legal top (\(self.list.contentOffset.y) vs \(top))")
            self.done()
        }
    }

    private func done() {
        list.removeFromSuperview()
        let verdict = failures.isEmpty ? "PASS" : "FAIL"
        print("TOOLGROUP_ENTRY_\(verdict) checks=\(checks) failures=\(failures.joined(separator: "; "))")
        report(failures.isEmpty, "entry stage: \(checks) checks")
    }
}
