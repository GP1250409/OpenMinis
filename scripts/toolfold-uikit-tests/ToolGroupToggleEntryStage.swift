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

    /// [T-toolgroup-collapse-finish] A row's WIDTH is the list's and its HEIGHT
    /// is the configuration's, so the size is known without solving the layout.
    ///
    /// The label only has a `<=` trailing relation (it must be free to be
    /// narrower than the row), which leaves the content view's width ambiguous:
    /// UIKit asked for a fitting size on every frame and got
    /// `{1.7976931348623157e+308, 28}` — an `NSInternalInconsistencyException`
    /// per measure of the tapped row (236 of them in run 44632268214, all
    /// swallowed by `noff_try_objc`, each one falling back to the layout's
    /// estimate for the row the close is anchored on). Echoing the target width
    /// and the configured height is what a fixed-height full-width row really
    /// is, and it keeps the `isExpanded` value the stage reads off the live
    /// cell (`BridgedToolGroupV3.isExpanded` is baked in at configure time).
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        let configured = (configuration as? EntryRowConfiguration)?.height ?? targetSize.height
        let width = targetSize.width.isFinite && targetSize.width > 0 ? targetSize.width : 390
        return CGSize(width: width, height: configured)
    }

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

    // [T-toolgroup-collapse-finish] The close's terminal window, recorded.
    private var lastMemberHeights: [CGFloat] = [320, 300, 280]
    private var prepareEvents: [PrepareEvent] = []
    private var terminalTrace: [TerminalSample] = []
    private var terminalCaseTag = ""
    private var terminalNext: (() -> Void)?
    /// [B1] The members of the case THAT IS RUNNING, never a global three: the
    /// short case closes a one-member run, and a sample that keeps asking for the
    /// module's three members would report two phantom `-1`s (and make the row
    /// arithmetic subtract rows that were never in the list).
    private var terminalMembers: [MessageListItem] = []

    /// One geometry sample of the terminal window, taken at a named point of the
    /// close (armed / apply-pre / apply-post / settled).
    struct TerminalSample {
        let tag: String
        let rows: Int
        let offset: CGFloat
        let contentHeight: CGFloat
        let headerScreenY: CGFloat
        let followMinY: CGFloat
        let memberHeights: [CGFloat]
        let window: String
    }

    /// What one `prepare()` pass of the production layout saw.
    struct PrepareEvent {
        let generation: Int
        let rows: Int
        let contentHeight: CGFloat
        let window: String
    }

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
        // [T-toolgroup-collapse-finish] See every layout pass this list runs: the
        // close's terminal handoff is a claim about PASSES (no pass may restore
        // the member rows' natural height before they are deleted), and the
        // production layout reports each one through this hook.
        layout.prepareObserver = { [weak self] generation, rows, contentHeight, window in
            // [R1] This harness lays out on main only. A pass from another thread
            // could not be appended without a data race, and reporting it would
            // just move the race into the failure counter — so it fails loudly
            // here instead: the trace is meaningless off main.
            guard Thread.isMainThread else {
                fatalError("terminal trace: prepare() arrived off the main thread")
            }
            self?.prepareEvents.append(PrepareEvent(generation: generation, rows: rows,
                                                    contentHeight: contentHeight, window: window))
        }
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

    /// [T-toolgroup-collapse-finish] The folded scene, with the member rows'
    /// REAL content height as a parameter: the terminal cases need a run taller
    /// than the viewport (long), one that barely fits (near bottom) and one whose
    /// whole content is shorter than the viewport (short), and each of those is a
    /// different measurement, not a different assertion.
    private func rebuildFolded(scrollHeaderVisible: Bool = true,
                               memberHeights: [CGFloat] = [320, 300, 280]) {
        items = fillerBlocks.map { .assistantBlock(messageId, $0) }
            + [groupItem, .assistantBlock(messageId, followBlock)]
        for block in fillerBlocks { contentHeights[.assistantBlock(messageId, block)] = 220 }
        contentHeights[groupItem] = 28
        contentHeights[.assistantBlock(messageId, followBlock)] = 120
        let heights = memberHeights.isEmpty ? [CGFloat(0)] : memberHeights
        for (index, block) in memberBlocks.enumerated() {
            contentHeights[.assistantBlock(messageId, block)] = heights[min(index, heights.count - 1)]
        }
        lastMemberHeights = heights
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
        // [T-toolgroup-collapse-finish] Mirror `applySnapshot`'s commit point: a
        // closing run parks its zero-reveal window on the layout and the commit
        // consumes it IMMEDIATELY before the new rows are applied, so the OLD
        // member indices can never clip the rows that move up into them. Sampling
        // right after the consume is the "commit" geometry the regression asserts.
        layout.consumeToolGroupAccordionTerminalHandoff()
        if !terminalCaseTag.isEmpty { terminalSample("commit") }
        // [T-toolgroup-collapse-finish] Mirror the production commit's HEIGHT
        // BOOKKEEPING, not only its handoff. `applySnapshot` remaps the
        // index-keyed height cache by row IDENTITY before it applies
        // (`MessageListV3Coordinator+Snapshot.swift`: `layout.updateCacheForSnapshot`)
        // and keeps `suppressContentOffsetAdjustment` on for the whole commit.
        // Without the remap this harness kept OLD indices: the row that moves
        // up into a deleted member's slot inherited that member's cached height,
        // its first self-size correction then carried a `contentOffsetAdjustment`
        // of (real - stale) — the viewport "compensated" by exactly that much
        // (748 → 548 for a 320pt member, 748 → −32 for a 900pt one in run
        // 44632268214) and a re-inserted member kept the follower's 120pt.
        // Production cannot see either number; the harness must not invent them.
        let oldItems = items
        let members = memberItems
        items.removeAll { members.contains($0) }
        if pendingExpanded, let at = items.firstIndex(of: groupItem).map({ $0 + 1 }) {
            items.insert(contentsOf: members, at: at)
        }
        let wasSuppressing = layout.suppressContentOffsetAdjustment
        layout.suppressContentOffsetAdjustment = true
        layout.updateCacheForSnapshot(oldIds: oldItems, newIds: items)
        for (index, item) in items.enumerated() {
            layout.setEstimatedHeight(estimateHeight(item), at: index)
        }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
        layout.suppressContentOffsetAdjustment = wasSuppressing
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
                // [T-toolgroup-collapse-finish] Sample the geometry on both sides
                // of the structural commit while a terminal case is armed: that
                // pair is what proves the delete lands on the last frame's
                // geometry instead of after a natural-height pass.
                let tracing = !self.terminalCaseTag.isEmpty
                if tracing { self.terminalSample("apply-entry") }
                self.syncStructure()
                if tracing { self.terminalSample("apply-post") }
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

    private func request(expanding: Bool, members: [MessageListItem]? = nil,
                         anchorY: CGFloat = 40) -> ToolGroupAccordionToggle.Request {
        ToolGroupAccordionToggle.Request(item: groupItem,
                                         memberItems: members ?? memberItems,
                                         expanding: expanding,
                                         oldIndex: items.firstIndex(of: groupItem) ?? fillerBlocks.count,
                                         anchorY: anchorY,
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
        // [T-toolgroup-accordion] A channel that outlives its flight keeps the
        // flight (and through it the list) alive, and can finish a LATER reveal
        // by mistake. `takeoverCase` covers the takeover path; this covers the
        // path that ends on its own (run 44506193558 only asserted the takeover
        // and cancel paths, which is how the leak stayed invisible).
        check(layout.toolGroupAccordionAbort == nil,
              "expand: the abort channel is disarmed when the flight ends normally")
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
        // [T-toolgroup-collapse-finish] The terminal window of a NORMAL close, on
        // this same production transaction: normal / near-bottom / short / long,
        // the next expand's natural heights, a retargeted reversal, an interrupt
        // and a cancel, each with its own trace.
        terminalCloseCase()
    }

    // MARK: - [T-toolgroup-collapse-finish] The close's terminal window

    /// Two decimals for the trace (the numbers are points on a 390×500 viewport).
    private func f2(_ value: CGFloat) -> String { String(format: "%.2f", value) }

    private func recordedSample(_ tag: String) -> TerminalSample? {
        for sample in terminalTrace where sample.tag == tag { return sample }
        return nil
    }

    /// Record one geometry sample: what the list holds, where the viewport is,
    /// where the tapped row sits on screen, where the row after the run sits, how
    /// tall the member rows are and whether a reveal window is installed.
    @discardableResult
    private func terminalSample(_ tag: String) -> TerminalSample {
        let headerIndex = items.firstIndex(of: groupItem) ?? 0
        let headerY = (list.layoutAttributesForItem(at: IndexPath(item: headerIndex, section: 0))?.frame.minY ?? 0)
            - list.contentOffset.y
        var heights: [CGFloat] = []
        for item in terminalMembers {
            if let index = items.firstIndex(of: item) {
                heights.append(list.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height ?? -1)
            } else {
                heights.append(-1)
            }
        }
        var followY: CGFloat = -1
        if let followIndex = items.firstIndex(of: .assistantBlock(messageId, followBlock)),
           let attrs = list.layoutAttributesForItem(at: IndexPath(item: followIndex, section: 0)) {
            followY = attrs.frame.minY
        }
        var window = "-"
        if let span = layout.toolGroupAccordionSpan {
            window = "\(span.lowerBound)...\(span.upperBound)@\(String(format: "%.3f", span.reveal))"
        }
        let sample = TerminalSample(tag: tag, rows: items.count, offset: list.contentOffset.y,
                                    contentHeight: list.contentSize.height, headerScreenY: headerY,
                                    followMinY: followY, memberHeights: heights, window: window)
        terminalTrace.append(sample)
        return sample
    }

    private func printTerminalTrace(_ label: String) {
        for sample in terminalTrace {
            let members = sample.memberHeights.map { f2($0) }.joined(separator: ",")
            print("TOOLGROUP_TERMINAL case=\(label) at=\(sample.tag) rows=\(sample.rows) "
                + "off=\(f2(sample.offset)) ch=\(f2(sample.contentHeight)) headerY=\(f2(sample.headerScreenY)) "
                + "followY=\(f2(sample.followMinY)) members=[\(members)] window=\(sample.window)")
        }
        var summary = "-"
        if let last = prepareEvents.last {
            summary = "rows=\(last.rows) window=\(last.window) ch=\(f2(last.contentHeight))"
        }
        print("TOOLGROUP_TERMINAL case=\(label) passes=\(prepareEvents.count) last=\(summary)")
    }

    /// The evidence of a NORMAL close, from its own trace:
    ///
    ///   * no layout pass between the last animated frame and the structural apply
    ///     laid the member rows out at their natural height (the rebound);
    ///   * the commit starts on the geometry the last frame ended on (same
    ///     content height, same viewport, members still 0 high);
    ///   * the commit removes the rows without changing the content height and
    ///     without a second anchor correction;
    ///   * the tapped row never leaves the screen position the last frame gave it.
    private func checkTerminalWindow(_ label: String) {
        guard let arm = recordedSample("arm"), let entry = recordedSample("apply-entry"),
              let commit = recordedSample("commit"), let post = recordedSample("apply-post"),
              let settled = recordedSample("settled") else {
            check(false, "\(label): the terminal window recorded arm / apply-entry / commit / apply-post / settled")
            return
        }
        var lastFrame: PrepareEvent?
        var rebound = 0
        var animated = 0
        var commits = 0
        for event in prepareEvents {
            if event.window != "-" && event.rows == arm.rows { lastFrame = event }
            if event.window == "-" && event.rows == arm.rows { rebound += 1 }
            if event.window != "-" { animated += 1 }
            if event.window == "-" && event.rows != arm.rows { commits += 1 }
        }
        check(rebound == 0,
              "\(label): NO layout pass restored the member rows before the delete (rebound passes=\(rebound), total=\(prepareEvents.count))")
        check(animated >= 3, "\(label): the reveal window was installed across the animation (\(animated) passes)")
        check(commits >= 1, "\(label): the commit itself laid the new structure out (\(commits) passes)")

        check(entry.rows == arm.rows,
              "\(label): the rows are all still in the list when the apply starts (\(entry.rows)/\(arm.rows))")
        check(entry.window != "-",
              "\(label): the window survives into the apply — the preparation did not tear it down early (\(entry.window))")
        check(entry.memberHeights.allSatisfy { $0 >= -0.5 && $0 <= 0.5 },
              "\(label): the member rows are still 0 high on entry to the apply — nothing restored them (\(entry.memberHeights))")
        check(commit.window == "-",
              "\(label): the window dies exactly at the commit (\(commit.window))")
        check(commit.rows == entry.rows,
              "\(label): the commit still sees the old rows (it has not applied them yet) (\(commit.rows))")
        check(commit.memberHeights.allSatisfy { $0 >= -0.5 && $0 <= 0.5 },
              "\(label): the members are 0 high when the commit starts (\(commit.memberHeights))")
        check(abs(commit.contentHeight - entry.contentHeight) <= 1 && abs(commit.offset - entry.offset) <= 1,
              "\(label): nothing moved between the apply and its commit (\(f2(entry.contentHeight))/\(f2(entry.offset)) → "
                + "\(f2(commit.contentHeight))/\(f2(commit.offset)))")
        if let frame = lastFrame {
            check(abs(commit.contentHeight - frame.contentHeight) <= 1,
                  "\(label): the commit starts from the LAST ANIMATED frame's content height "
                    + "(\(f2(frame.contentHeight)) at pass #\(frame.generation) → \(f2(commit.contentHeight)))")
        } else {
            check(false, "\(label): the trace contains the animation's passes")
        }
        check(ToolGroupTerminalMemberContract.isComplete(entry.memberHeights, caseMembers: terminalMembers.count),
              "\(label): the entry sample describes exactly this case's \(terminalMembers.count) member rows — "
                + "a row that is not in the list fails instead of becoming a phantom -1 (\(entry.memberHeights))")
        check(ToolGroupTerminalMemberContract.isComplete(commit.memberHeights, caseMembers: terminalMembers.count),
              "\(label): the commit sample describes the same \(terminalMembers.count) rows (\(commit.memberHeights))")
        check(post.rows == arm.rows - terminalMembers.count,
              "\(label): the members are really removed by the commit (\(entry.rows) → \(post.rows), "
                + "\(terminalMembers.count) members)")
        check(abs(post.contentHeight - commit.contentHeight) <= 1,
              "\(label): deleting them does not change the content height — they were 0 high (\(f2(commit.contentHeight)) → \(f2(post.contentHeight)))")
        check(abs(post.offset - commit.offset) <= 0.5,
              "\(label): no anchor compensation on top of the commit (\(f2(commit.offset)) → \(f2(post.offset)))")
        check(abs(post.headerScreenY - commit.headerScreenY) <= 0.75,
              "\(label): the tapped row stays exactly where the last frame put it (\(f2(commit.headerScreenY)) → \(f2(post.headerScreenY)))")
        check(abs(settled.offset - commit.offset) <= 0.5,
              "\(label): the settled viewport is the last frame's (\(f2(commit.offset)) → \(f2(settled.offset)))")
        check(settled.window == "-" && layout.toolGroupAccordionSpan == nil,
              "\(label): no reveal window survives the close")
        check(applyCallers.last == "toolGroupAccordionEnd",
              "\(label): the structure converged through the production apply (\(applyCallers.last ?? "-"))")
        check(abs((anchors.last ?? -1) - arm.headerScreenY) <= 0.75,
              "\(label): the anchor restore ran with the tap's own anchor (\(f2(anchors.last ?? -1)) vs \(f2(arm.headerScreenY)))")
    }

    /// [B1] Positive AND negative control for the sample rule, executed here on
    /// every run: the old fixed-three sample (three entries against a one-member
    /// case) must be rejected, the one-member and three-member samples must pass,
    /// and a single missing row must never be masked. The same predicate is also
    /// compiled and run on Linux by `toolgroup_accordion_regression.py`.
    private func terminalMemberContractSelfTest() {
        check(!ToolGroupTerminalMemberContract.isComplete([-1, -1, -1], caseMembers: 1),
              "contract[B1]: the fixed-three sample is rejected for a one-member case")
        check(!ToolGroupTerminalMemberContract.isComplete([0, 0, -1], caseMembers: 3),
              "contract[B1]: one missing member is never masked by the other two")
        check(!ToolGroupTerminalMemberContract.isComplete([0, 0], caseMembers: 3),
              "contract[B1]: a short sample is rejected for a three-member case")
        check(ToolGroupTerminalMemberContract.isComplete([40], caseMembers: 1),
              "contract[B1]: the one-member short case samples exactly one row")
        check(ToolGroupTerminalMemberContract.isComplete([0, 0, 0], caseMembers: 3),
              "contract[B1]: the three-member close samples three rows at reveal 0")
        check(ToolGroupTerminalMemberContract.isComplete([], caseMembers: 0),
              "contract[B1]: an empty run is trivially complete")
    }

    /// Open the run through the production transaction and wait for its OWN end.
    private func openThroughTransaction(_ label: String, next: @escaping () -> Void) {
        pendingExpanded = true
        let outcome = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        if case .started = outcome {
            check(flight != nil, "\(label): the expand started through the production transaction")
        } else {
            check(false, "\(label): the expand started (outcome=\(outcome))")
        }
        waitForFlightToEnd(label) { next() }
    }

    /// [T-toolgroup-collapse-finish] Wait for the LIST's flight to end, then
    /// continue (bounded). A fixed delay is not a schedule: a flight needs its
    /// 0.32s of display-link ticks *plus* whatever else the main run loop had
    /// to do, and one that is still in the air leaks its structural apply into
    /// the NEXT case's trace. Run 44632268214 showed exactly that in
    /// `close-retarget`: its trace opened with the previous expand's apply
    /// (`apply-entry rows=10 ch=2148 members=[320,300,280] window=-`), so the
    /// arm/entry/commit/post pairs no longer described one close.
    ///
    /// This adds no tolerance to any assertion — it only lets the transaction a
    /// case started reach its own end before that case starts measuring. A
    /// flight that never ends is still a failure, with its state in the label.
    private func waitForFlightToEnd(_ label: String, timeout: TimeInterval = 2.0,
                                    then next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard let live = flight else { next(); return }
            if Date() >= deadline {
                check(false, "\(label): the flight ended before the next case starts "
                        + "(frames=\(live.framesApplied) reveal=\(f2(live.reveal)) "
                        + "running=\(live.isRunning) direction=\(live.finalDirection))")
                next()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { poll() }
        }
        poll()
    }

    /// Close the open run through the production transaction, with the trace armed.
    private func runTerminalClose(_ label: String, members: [MessageListItem]? = nil,
                                  scrollTo: CGFloat? = nil, next: @escaping () -> Void) {
        if let target = scrollTo {
            list.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            list.setNeedsLayout()
            list.layoutIfNeeded()
        }
        let headerIndex = items.firstIndex(of: groupItem) ?? 0
        let anchor = (list.layoutAttributesForItem(at: IndexPath(item: headerIndex, section: 0))?.frame.minY ?? 0)
            - list.contentOffset.y
        prepareEvents.removeAll()
        terminalTrace.removeAll()
        terminalMembers = members ?? memberItems
        terminalCaseTag = label
        terminalNext = next
        terminalSample("arm")
        pendingExpanded = false
        let outcome = ToolGroupAccordionToggle.run(request(expanding: false, members: members, anchorY: anchor),
                                                   in: environment())
        if case .started = outcome {
            check(items.count > 1, "\(label): the run is open while it collapses (\(items.count) rows)")
        } else {
            check(false, "\(label): the close started (outcome=\(outcome))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.terminalCloseSettled(label) }
    }

    private func terminalCloseSettled(_ label: String) {
        list.layoutIfNeeded()
        terminalSample("settled")
        printTerminalTrace(label)
        checkTerminalWindow(label)
        terminalCaseTag = ""
        let next = terminalNext
        terminalNext = nil
        next?()
    }

    /// The normal close: a run taller than the viewport, the tapped row parked at
    /// the top. This is the case the user reported ("the last bit of the collapse
    /// judders").
    private func terminalCloseCase() {
        terminalMemberContractSelfTest()
        rebuildFolded()
        openThroughTransaction("close-normal") {
            self.runTerminalClose("close-normal") { self.terminalNearBottomCase() }
        }
    }

    /// Near the bottom: the close starts BELOW the legal maximum of the closed
    /// content, so its last frames clamp the viewport to the bottom edge. The
    /// delete must then leave it there — no second correction, and the content
    /// height must not change.
    private func terminalNearBottomCase() {
        let label = "close-near-bottom"
        rebuildFolded()
        openThroughTransaction("close-near-bottom") {
            let headerIndex = self.items.firstIndex(of: self.groupItem) ?? 0
            let headerMinY = self.list.layoutAttributesForItem(at: IndexPath(item: headerIndex, section: 0))?.frame.minY ?? 0
            // Park the tapped row 60pt below the top of the viewport. That offset
            // is still legal for the OPEN run and already beyond the legal bottom
            // of the CLOSED one (the run is 900pt tall), so the last frames of the
            // close really clamp.
            let target = max(0, headerMinY - 60)
            self.runTerminalClose(label, scrollTo: target) {
                self.check(abs(self.list.contentOffset.y - self.legalMaxOffset()) <= 0.5,
                           "\(label): the close ends exactly at the legal bottom")
                self.check(self.list.contentOffset.y < target,
                           "\(label): the close really clamped (the viewport had to give ground)")
                self.terminalShortCase()
            }
        }
    }

    /// Short: the whole content is shorter than the viewport, so the only legal
    /// offset is the top inset. The close must not invent motion there.
    private func terminalShortCase() {
        let label = "close-short"
        installShortScene(memberHeight: 60)
        check(list.contentSize.height <= list.bounds.height + 1,
              "\(label): the list really is shorter than its viewport (\(f2(list.contentSize.height)) vs \(f2(list.bounds.height)))")
        runTerminalClose(label, members: [shortMember]) {
            self.check(abs(self.list.contentOffset.y + self.list.adjustedContentInset.top) <= 1,
                       "\(label): the offset stays at the legal top (\(self.f2(self.list.contentOffset.y)))")
            self.terminalLongCase()
        }
    }

    /// Long: a run several times the viewport height, opened and closed through
    /// the production transaction.
    private func terminalLongCase() {
        let label = "close-long"
        rebuildFolded(memberHeights: [900, 800, 700])
        openThroughTransaction("close-long") {
            self.check(self.lastMemberHeights.reduce(0, +) > self.list.bounds.height * 3,
                       "\(label): the run really is several viewports tall")
            self.runTerminalClose(label) { self.terminalNextExpandCase() }
        }
    }

    /// After all those closes the run must open again with its REAL natural
    /// heights: no close may leave a 0 in the frozen/height cache.
    private func terminalNextExpandCase() {
        let label = "next-expand"
        prepareEvents.removeAll()
        terminalTrace.removeAll()
        terminalMembers = memberItems
        terminalCaseTag = label
        terminalSample("arm")
        pendingExpanded = true
        let expected = lastMemberHeights
        let outcome = ToolGroupAccordionToggle.run(request(expanding: true), in: environment())
        if case .started(let flight) = outcome {
            if let plan = flight.currentPlan {
                check(plan.naturalHeights.allSatisfy { $0 > 100 },
                      "\(label): the close did not poison the natural heights (\(plan.naturalHeights))")
                check(zip(plan.naturalHeights, expected).allSatisfy { pair in abs(pair.0 - pair.1) <= 2 },
                      "\(label): every member row is measured to its real height again (\(plan.naturalHeights))")
            } else {
                check(false, "\(label): the flight published its plan")
            }
        } else {
            check(false, "\(label): the expand started (outcome=\(outcome))")
        }
        waitForFlightToEnd(label) {
            var heights: [CGFloat] = []
            var cached: [CGFloat] = []
            for item in self.memberItems {
                if let row = self.items.firstIndex(of: item) {
                    heights.append(self.list.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame.height ?? 0)
                    cached.append(self.layout.cachedHeight(at: row) ?? -1)
                } else {
                    heights.append(0)
                    cached.append(-1)
                }
            }
            self.check(zip(heights, self.lastMemberHeights).allSatisfy { pair in abs(pair.0 - pair.1) <= 2 },
                       "\(label): every member row ends open at its real height (\(heights))")
            self.check(cached.allSatisfy { $0 > 100 },
                       "\(label): the height cache holds the real heights, never a 0 from the close (\(cached))")
            self.check(self.items.count == self.memberItems.count + self.fillerBlocks.count + 2,
                       "\(label): the open structure is complete again (\(self.items.count) rows)")
            self.terminalCaseTag = ""
            self.terminalRetargetCase()
        }
    }

    /// A retargeted flight: the second tap turns an EXPAND into a CLOSE, so the
    /// terminal side is decided by the flight's final direction. The completed
    /// reversal must converge the structure itself (no deferred converge) and go
    /// through the same atomic handoff.
    private func terminalRetargetCase() {
        let label = "close-retarget"
        rebuildFolded()
        openThroughTransaction("retarget-open") {
            self.prepareEvents.removeAll()
            self.terminalTrace.removeAll()
            self.terminalCaseTag = label
            self.check(self.flight == nil, "\(label): the first expand already finished")
            let headerIndex = self.items.firstIndex(of: self.groupItem) ?? 0
            let anchor = (self.list.layoutAttributesForItem(at: IndexPath(item: headerIndex, section: 0))?.frame.minY ?? 0)
                - self.list.contentOffset.y
            self.pendingExpanded = true
            let outcome = ToolGroupAccordionToggle.run(self.request(expanding: true, anchorY: anchor), in: self.environment())
            guard case .started(let flight) = outcome else {
                self.check(false, "\(label): the expand started (outcome=\(outcome))")
                self.terminalCaseTag = ""
                self.terminalInterruptCase()
                return
            }
            // The expand's own structural insert is NOT part of the close's window:
            // from here on the trace describes the reversal, whose terminal state
            // is the one under test.
            self.prepareEvents.removeAll()
            self.terminalTrace.removeAll()
            self.terminalMembers = self.memberItems
            self.terminalSample("arm")
            self.deferredConverges.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                // The user tapped again: business state closed, flight reversed.
                self.pendingExpanded = false
                flight.retarget(.collapse)
                self.check(flight.finalDirection == .collapse,
                           "\(label): the flight ends on the collapse side (\(flight.finalDirection))")
                self.waitForFlightToEnd(label) {
                    self.list.layoutIfNeeded()
                    self.terminalSample("settled")
                    self.printTerminalTrace(label)
                    self.checkTerminalWindow(label)
                    self.check(self.deferredConverges.isEmpty,
                               "\(label): a completed reversal settles itself, never through the deferred converge (\(self.deferredConverges))")
                    self.check(self.items.count == self.expectedFoldedCount,
                               "\(label): the reversed run is folded at the end (\(self.items.count))")
                    self.terminalCaseTag = ""
                    self.terminalInterruptCase()
                }
            }
        }
    }

    /// The interrupt terminal: a drag takes the viewport mid-close. The rows stay,
    /// the viewport stays where the finger left it, and the delete is handed to
    /// the settle. The window is gone immediately (that is the documented
    /// contract for a takeover, not the atomic close).
    private func terminalInterruptCase() {
        let label = "close-interrupt"
        rebuildFolded()
        openThroughTransaction("interrupt-open") {
            self.pendingExpanded = false
            self.deferredConverges.removeAll()
            let outcome = ToolGroupAccordionToggle.run(self.request(expanding: false), in: self.environment())
            guard case .started(let flight) = outcome else {
                self.check(false, "\(label): the close started (outcome=\(outcome))")
                self.terminalCancelCase()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                let before = self.list.contentOffset.y
                let rowsBefore = self.items.count
                flight.finish(.interrupted)
                self.check(abs(self.list.contentOffset.y - before) <= 0.5,
                           "\(label): the interrupt leaves the viewport where the finger left it (\(self.f2(before)) → \(self.f2(self.list.contentOffset.y)))")
                self.check(self.items.count == rowsBefore,
                           "\(label): nothing is deleted under the finger (\(self.items.count)/\(rowsBefore))")
                self.check(self.layout.toolGroupAccordionSpan == nil,
                           "\(label): the interrupt drops the window at once (the old shape)")
                self.check(self.deferredConverges == ["toolGroupAccordionEnd-deferred"],
                           "\(label): the delete is handed to the settle (\(self.deferredConverges))")
                let anchorsBefore = self.anchors.count
                self.settleDeferredConverge()
                self.check(self.items.count == self.expectedFoldedCount,
                           "\(label): after the settle the rows are gone (\(self.items.count)/\(self.expectedFoldedCount))")
                self.check(self.anchors.count == anchorsBefore,
                           "\(label): the settle does not re-anchor the tap (\(self.anchors.count))")
                self.terminalCancelCase()
            }
        }
    }

    /// The cancel terminal: the list goes away (session swap / window gone)
    /// mid-close. Nothing is deleted, nothing is deferred, no clip window and no
    /// takeover closure may be left behind.
    private func terminalCancelCase() {
        let label = "close-cancel"
        rebuildFolded()
        openThroughTransaction("cancel-open") {
            self.pendingExpanded = false
            self.deferredConverges.removeAll()
            let outcome = ToolGroupAccordionToggle.run(self.request(expanding: false), in: self.environment())
            guard case .started(let flight) = outcome else {
                self.check(false, "\(label): the close started (outcome=\(outcome))")
                self.done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                let before = self.list.contentOffset.y
                let rowsBefore = self.items.count
                flight.cancel()
                self.check(abs(self.list.contentOffset.y - before) <= 0.5,
                           "\(label): a cancelled close does not move the viewport (\(self.f2(before)) → \(self.f2(self.list.contentOffset.y)))")
                self.check(self.items.count == rowsBefore && rowsBefore > 1,
                           "\(label): a cancelled close deletes nothing (\(self.items.count))")
                self.check(self.deferredConverges.isEmpty,
                           "\(label): a cancelled close schedules no converge (\(self.deferredConverges))")
                self.check(self.layout.toolGroupAccordionSpan == nil, "\(label): the window is gone")
                self.check(self.layout.toolGroupAccordionAbort == nil, "\(label): the takeover channel is disarmed")
                self.check(self.layout.toolGroupAccordionTerminalHandoff == nil,
                           "\(label): no terminal handoff is left parked for a later commit")
                var cleared = false
                if let row = self.items.firstIndex(of: self.memberItems[0]),
                   let cell = self.list.cellForItem(at: IndexPath(item: row, section: 0)) as? SelfSizingCell {
                    cleared = cell.accordionContentHeight == nil && !cell.clipsToBounds
                }
                self.check(cleared, "\(label): the member cell keeps no clip window after the cancel")
                self.done()
            }
        }
    }

    /// `Short` scene: the group row plus ONE member row, with the whole content
    /// shorter than the viewport. Its member is `memberBlocks[0]` with a real
    /// content height of `memberHeight`, so the transaction measures it from the
    /// live cell instead of the estimate.
    private var shortMember: MessageListItem { .assistantBlock(messageId, memberBlocks[0]) }

    private func installShortScene(memberHeight: CGFloat) {
        items = [groupItem, shortMember]
        contentHeights[groupItem] = 28
        contentHeights[shortMember] = memberHeight
        pendingExpanded = true
        layout.clearToolGroupAccordion()
        layout.clearHeightCache()
        for index in items.indices {
            layout.setEstimatedHeight(estimateHeight(items[index]), at: index)
        }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
        list.contentOffset = CGPoint(x: 0, y: -list.adjustedContentInset.top)
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    private func legalMaxOffset() -> CGFloat {
        let minOff = -list.adjustedContentInset.top
        return max(minOff, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
    }

    private func done() {
        list.removeFromSuperview()
        let verdict = failures.isEmpty ? "PASS" : "FAIL"
        print("TOOLGROUP_ENTRY_\(verdict) checks=\(checks) failures=\(failures.joined(separator: "; "))")
        report(failures.isEmpty, "entry stage: \(checks) checks")
    }
}

// === BEGIN TerminalMemberContract ===
/// [B1] A terminal sample describes exactly the case's OWN member rows: one
/// height per member, and every one of them really found in the list while the
/// run is open. `0` is a legal height at reveal 0; `missing` (-1) means "not in
/// the list" and must never be hidden by an intersection or by counting the
/// module's three members instead of the case's.
enum ToolGroupTerminalMemberContract {
    static let missing: CGFloat = -1

    static func isComplete(_ heights: [CGFloat], caseMembers: Int) -> Bool {
        guard caseMembers >= 0, heights.count == caseMembers else { return false }
        for value in heights where value < 0 { return false }
        return true
    }
}
// === END TerminalMemberContract ===
