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

/// [T-toolgroup-accordion] The one property the real row bakes into its cell at
/// configure time: `isExpanded` (`BridgedToolGroupV3.isExpanded` is a `let`, and
/// `ToolGroupRowView` rotates its chevron and picks its accessibility label from
/// it). A placeholder text view would look the same in both states, so the stage
/// reads this value back off the LIVE cell — that is what makes "the tapped row
/// was reconfigured" a real assertion.
final class EntryRowConfiguration: NSObject, UIContentConfiguration {
    let height: CGFloat
    let isExpanded: Bool?

    init(height: CGFloat, isExpanded: Bool? = nil) {
        self.height = height
        self.isExpanded = isExpanded
    }

    func makeContentView() -> UIView & UIContentView { EntryRowContentView(self) }
    func updated(for state: UIConfigurationState) -> EntryRowConfiguration { self }
}

final class EntryRowContentView: UIView, UIContentView {
    private let label = UILabel()
    private var heightConstraint: NSLayoutConstraint?

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(_ configuration: EntryRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let c = heightAnchor.constraint(equalToConstant: configuration.height)
        c.isActive = true
        heightConstraint = c
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func apply() {
        guard let config = configuration as? EntryRowConfiguration else { return }
        label.text = config.isExpanded.map { $0 ? "Hide tool calls" : "Show tool calls" } ?? ""
        heightConstraint?.constant = config.height
    }
}

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
    private var headerRefreshes = 0
    private var headerRefreshExpanded: Bool?
    private var headerRefreshedWhileFlying = true
    private var deferredConverges: [String] = []

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

    /// The layout's ESTIMATE for a row. Member rows are deliberately estimated
    /// at 80 against real contents of 320 / 300 / 280: if the estimate equalled
    /// the content, "measured 320" would also pass for a receipt that merely
    /// echoed the proposal back (the NB4 regression), so the value assertion
    /// would prove nothing about measurement.
    private func estimateHeight(_ item: MessageListItem) -> CGFloat {
        memberItems.contains(item) ? 80 : cellHeight(item)
    }

    private func configureRow(_ cell: SelfSizingCell, item: MessageListItem) {
        let height = cellHeight(item)
        cell.backgroundColor = .clear
        cell.applyContentConfiguration(
            UIHostingConfiguration { Color.clear.frame(height: height) }
                .minSize(width: 0, height: 0)
                .margins(.all, 0))
    }

    /// What the coordinator's `refreshToolGroupToggleRow` does to the tapped
    /// row: re-render the LIVE cell with the state the business just flipped to.
    /// The row content is a real `UIContentConfiguration` carrying `isExpanded`
    /// (the one value `BridgedToolGroupV3` bakes into its cell), so the stage can
    /// read the property back off the cell instead of trusting a bookkeeping
    /// flag.
    private func refreshHeader(_ item: MessageListItem) {
        guard let idx = items.firstIndex(of: item),
              let cell = list.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell else {
            check(false, "header: the tapped row is on screen when the transaction refreshes it")
            return
        }
        headerRefreshes += 1
        headerRefreshExpanded = pendingExpanded
        headerRefreshedWhileFlying = flight?.isRunning ?? false
        cell.applyContentConfiguration(EntryRowConfiguration(height: cellHeight(item),
                                                             isExpanded: pendingExpanded))
        list.layoutIfNeeded()
    }

    private func rebuildFolded(scrollHeaderVisible: Bool = true) {
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
        if scrollHeaderVisible {
            scrollHeaderIntoView()
        } else {
            list.contentOffset = CGPoint(x: 0, y: -list.adjustedContentInset.top)
            list.setNeedsLayout()
            list.layoutIfNeeded()
        }
    }

    /// Put the tapped group header at the bottom edge of the 500pt viewport so
    /// (1) the header is live on screen (`cellForItem` is non-nil, just like a
    /// real user tap) and (2) the member rows inserted below it start off screen
    /// and still exercise `ToolGroupAccordionMeasurement`.
    private func scrollHeaderIntoView() {
        let headerIP = IndexPath(item: fillerBlocks.count, section: 0)
        guard let headerFrame = layout.layoutAttributesForItem(at: headerIP)?.frame else { return }
        let minOff = -list.adjustedContentInset.top
        let maxOff = max(minOff, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        let target = min(maxOff, max(minOff, headerFrame.maxY - list.bounds.height))
        list.contentOffset = CGPoint(x: 0, y: target)
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    private func reload() {
        layout.clearToolGroupAccordion()
        layout.clearHeightCache()
        for (index, item) in items.enumerated() {
            layout.setEstimatedHeight(estimateHeight(item), at: index)
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
            layout.setEstimatedHeight(estimateHeight(item), at: index)
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
            refreshHeader: { [unowned self] item in self.refreshHeader(item) },
            deferConverge: { [unowned self] caller in self.deferredConverges.append(caller) },
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
        check(headerRefreshes == 1, "expand: the tapped row was refreshed once by the transaction (\(headerRefreshes))")
        check(headerRefreshExpanded == true, "expand: the refresh carried the NEW expanded state")
        check(headerRefreshedWhileFlying, "expand: the refresh happened with the reveal window already installed")
        let headerCfg = list.cellForItem(at: IndexPath(item: fillerBlocks.count, section: 0))?
            .contentConfiguration as? EntryRowConfiguration
        check(headerCfg?.isExpanded == true,
              "expand: the live header cell reports isExpanded == true (chevron / a11y source)")
        check(abs((headerCfg?.height ?? 0) - 28) < 0.5,
              "expand: the refresh keeps the fixed row height, so no geometry moves under the flight")
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
        check(headerRefreshExpanded == false, "close: the refresh carried the closed state")
        let closedCfg = list.cellForItem(at: IndexPath(item: fillerBlocks.count, section: 0))?
            .contentConfiguration as? EntryRowConfiguration
        check(closedCfg?.isExpanded == false,
              "close: the live header cell flips to closed as the run collapses")
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
        rebuildFolded(scrollHeaderVisible: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            let top = -self.list.adjustedContentInset.top
            self.check(abs(self.list.contentOffset.y - top) < 0.5,
                       "short content: the list stays at its legal top (\(self.list.contentOffset.y) vs \(top))")
            self.closeInterruptedCase()
        }
    }

    // MARK: - Interrupted flights (B2)

    /// The coordinator's `flushToolGroupAccordionConverge` at the moment the
    /// finger is off the screen: run the recorded converge once.
    private func settleDeferredConverge() {
        guard !deferredConverges.isEmpty else { return }
        let caller = deferredConverges.removeFirst()
        applyCallers.append(caller)
        syncStructure()
    }

    /// A close taken over by a drag must NOT delete its rows under the finger
    /// (that is the "content jumps mid-gesture" trap), and it must NOT be left
    /// open behind a closed business state either. The transaction hands the
    /// converge to the caller, and the rows go at the settle.
    private func closeInterruptedCase() {
        rebuildFolded()
        pendingExpanded = true
        syncStructure()
        pendingExpanded = false
        let before = anchors.count
        _ = ToolGroupAccordionToggle.run(request(expanding: false), in: environment())
        guard let flight else { check(false, "close-interrupt: a flight is live"); return }
        flight.finish(.interrupted)
        check(items.count == expectedExpandedCount,
              "close-interrupt: the rows are not deleted under the finger (\(items.count)/\(expectedExpandedCount))")
        check(layout.toolGroupAccordionSpan == nil, "close-interrupt: the reveal window is gone")
        check(deferredConverges == ["toolGroupAccordionEnd-deferred"],
              "close-interrupt: the close asked for a deferred converge (\(deferredConverges))")
        check(anchors.count == before, "close-interrupt: no anchor write while the finger owns the list")
        settleDeferredConverge()
        check(items.count == expectedFoldedCount,
              "close-interrupt: after the settle the rows are gone (\(items.count)/\(expectedFoldedCount))")
        check(applyCallers.last == "toolGroupAccordionEnd-deferred",
              "close-interrupt: the converge ran through applySnapshot")
        expandInterruptCase()
    }

    /// The other side: an interrupted EXPAND already matches the business state,
    /// so it must NOT schedule a converge (that would delete rows that are
    /// supposed to be there).
    private func expandInterruptCase() {
        rebuildFolded()
        deferredConverges.removeAll()
        pendingExpanded = true
        _ = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        guard let flight else { check(false, "expand-interrupt: a flight is live"); return }
        flight.finish(.interrupted)
        check(items.count == expectedExpandedCount, "expand-interrupt: the opened rows stay")
        check(deferredConverges.isEmpty,
              "expand-interrupt: nothing to converge (the open state IS the business state)")
        retargetInterruptCase()
    }

    /// A retarget flips the FINAL direction: the close must be deferred even
    /// though the request that started the flight said `expanding: true`, so
    /// `request.expanding` can never decide this.
    private func retargetInterruptCase() {
        rebuildFolded()
        deferredConverges.removeAll()
        pendingExpanded = true
        _ = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        guard let flight else { check(false, "retarget-interrupt: a flight is live"); return }
        pendingExpanded = false
        flight.retarget(.collapse)
        check(flight.finalDirection == .collapse, "retarget-interrupt: the flight's final direction is the close")
        flight.finish(.interrupted)
        check(deferredConverges == ["toolGroupAccordionEnd-deferred"],
              "retarget-interrupt: the close is deferred from the FINAL direction, not the request (\(deferredConverges))")
        settleDeferredConverge()
        check(items.count == expectedFoldedCount, "retarget-interrupt: the rows are gone after the settle")
        takeoverCase()
    }

    /// Status-bar takeover goes through the layout's abort channel; a cancelled
    /// list drop must clear it (no layout → flight → layout retain cycle).
    private func takeoverCase() {
        rebuildFolded()
        deferredConverges.removeAll()
        pendingExpanded = true
        _ = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        check(flight != nil, "takeover: a flight is live")
        check(layout.toolGroupAccordionAbort != nil, "takeover: the abort channel is armed")
        layout.toolGroupAccordionAbort?()
        check(flight == nil, "takeover: the status-bar channel finished the reveal")
        check(layout.toolGroupAccordionAbort == nil, "takeover: the abort channel is disarmed after the takeover")
        // A cancelled list (window gone / session swap) must not leave the
        // closure armed on the layout either.
        rebuildFolded()
        pendingExpanded = true
        _ = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        flight?.cancel()
        check(layout.toolGroupAccordionAbort == nil, "cancel: the abort channel is cleared")
        done()
    }

    private func done() {
        list.removeFromSuperview()
        let verdict = failures.isEmpty ? "PASS" : "FAIL"
        print("TOOLGROUP_ENTRY_\(verdict) checks=\(checks) failures=\(failures.joined(separator: "; "))")
        report(failures.isEmpty, "entry stage: \(checks) checks")
    }
}
