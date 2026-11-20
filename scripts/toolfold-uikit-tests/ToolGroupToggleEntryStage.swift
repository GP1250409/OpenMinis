// [T-toolgroup-original-toggle] Entry-level coverage of the tool-group switch.
//
// This stage drives the SAME production entry the chat list's tap drives:
// `ToolGroupOriginalToggle.run(_:in:)` (Support/ToolGroupOriginalToggle.swift;
// the coordinator's `toggleToolGroup` calls it). It is not a look-alike next to
// the business code — the structure apply, the row reconfigure, the layout
// settle and the anchored offset are the shipping implementation.
//
// The list here is a real UIWindow-hosted UICollectionView with the real
// MessageListLayout, real SelfSizingCell and real UIHostingConfiguration rows,
// and the rows are deliberately TALL (320 / 300 / 280pt against an 80pt
// estimate) with the run parked below five 220pt rows — the "long tool output"
// case the accordion used to need a measurement probe for. Three 220pt tail
// rows below the run give the list room to scroll, so the tapped header can be
// placed high in the viewport AND the inserted member rows still land inside it
// (real UIKit self-sizing, measured for real instead of read back as estimates).
//
// The 0.32s accordion (flight, frozen member heights, span, retarget, probe,
// deferred converge) was cancelled by user decision on 2026-11-20. Every case
// here therefore also asserts the NEGATIVE side: after every run there is no
// reveal window, no abort channel and no illegal offset — and this file does
// not even link the accordion driver any more, which the driver checks.

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
    private var heightConstraint: NSLayoutConstraint!

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
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        heightConstraint.constant = config.height
    }

    /// The row's height is FIXED (production's `ToolGroupRowView.rowHeight`),
    /// so the fitting answer is that height at the proposed width, not a size
    /// Auto Layout has to discover. Without this the free label width made
    /// `systemLayoutSizeFitting` answer `{1.7976931348623157e+308, 28}` and
    /// UIKit raised NSInternalInconsistencyException inside the cell's self-size
    /// pass (8 times in CI run 44650457236); the shipping SelfSizingCell's
    /// `noff_try_objc` guard swallowed the exception, so the tapped row never
    /// really measured. The override keeps the measurement deterministic.
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let height = (configuration as? EntryRowConfiguration)?.height ?? 28
        let width = targetSize.width.isFinite && targetSize.width > 1 ? targetSize.width : 390
        return CGSize(width: width, height: height)
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
    /// Rows below the run: give the list room to scroll so the header can be
    /// parked high in the viewport (real user tap) and the member rows still
    /// land inside it (real measurement). The near-bottom case rebuilds
    /// WITHOUT these to reproduce the "offset ends exactly on the legal
    /// bottom" clamp the original fixture asserted.
    private let tailBlocks = (0..<3).map { _ in UUID() }
    private let memberHeights: [CGFloat] = [320, 300, 280]

    private var items: [MessageListItem] = []
    private var contentHeights: [MessageListItem: CGFloat] = [:]
    private var pendingExpanded = true
    private var applyCallers: [String] = []
    private var headerRefreshes = 0
    private var headerRefreshExpanded: Bool?
    private var expectedExpandedCount = 0
    private var expectedFoldedCount = 0

    private var reduceMotion = false
    private var streaming = false
    private(set) var checks = 0
    private(set) var failures: [String] = []

    private var memberItems: [MessageListItem] {
        memberBlocks.map { .assistantBlock(messageId, $0) }
    }
    private var groupItem: MessageListItem { .toolGroup(messageId, groupBlock) }

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

    /// The long-tool-output list: five 220pt rows, the 28pt group header, the
    /// (folded-out) member rows, a 120pt follow row, and — when `tails` — three
    /// 220pt rows below so the header can be parked high while the members stay
    /// inside the 500pt viewport.
    private func rebuildFolded(tails: Bool = true) {
        var rows = fillerBlocks.map { .assistantBlock(messageId, $0) }
            + [groupItem, .assistantBlock(messageId, followBlock)]
        if tails { rows += tailBlocks.map { .assistantBlock(messageId, $0) } }
        items = rows
        contentHeights = [:]
        for block in fillerBlocks { contentHeights[.assistantBlock(messageId, block)] = 220 }
        contentHeights[groupItem] = 28
        contentHeights[.assistantBlock(messageId, followBlock)] = 120
        for block in tailBlocks { contentHeights[.assistantBlock(messageId, block)] = 220 }
        for (block, height) in zip(memberBlocks, memberHeights) {
            contentHeights[.assistantBlock(messageId, block)] = height
        }
        pendingExpanded = false
        expectedFoldedCount = items.count
        expectedExpandedCount = expectedFoldedCount + memberBlocks.count
        reload()
        list.contentOffset = CGPoint(x: 0, y: -list.adjustedContentInset.top)
        settle()
    }

    /// Content genuinely shorter than the viewport (the group header + follow
    /// row only; the member rows are inserted by the tap): the only legal
    /// offset is the top inset, so any anchor write the transaction might
    /// attempt must collapse to it.
    private func rebuildShort() {
        items = [groupItem, .assistantBlock(messageId, followBlock)]
        contentHeights = [:]
        contentHeights[groupItem] = 28
        contentHeights[.assistantBlock(messageId, followBlock)] = 120
        for block in memberBlocks { contentHeights[.assistantBlock(messageId, block)] = 20 }
        pendingExpanded = false
        expectedFoldedCount = items.count
        expectedExpandedCount = expectedFoldedCount + memberBlocks.count
        reload()
        list.contentOffset = CGPoint(x: 0, y: -list.adjustedContentInset.top)
        settle()
    }

    /// A real user scroll: park the tapped header's top edge at `screenY`
    /// inside the legal offset window, then settle. Never writes an offset
    /// outside [minOff, maxOff].
    private func positionHeader(at screenY: CGFloat) {
        settle()
        guard let idx = items.firstIndex(of: groupItem),
              let frame = layout.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))?.frame else { return }
        let w = legalWindow()
        let target = min(max(frame.minY - screenY, w.min), w.max)
        list.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        settle()
    }

    private func settle() {
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
        settle()
    }

    /// The BUSINESS structure apply: insert / remove the member rows, exactly
    /// what the coordinator's `applySnapshot` does to the list — identity remap
    /// of the index-keyed height caches, suppression of the commit-time offset
    /// compensation, the apply, then a settle.
    private func syncStructure() {
        let old = items
        let members = memberItems
        items.removeAll { members.contains($0) }
        if pendingExpanded, let at = items.firstIndex(of: groupItem).map({ $0 + 1 }) {
            items.insert(contentsOf: members, at: at)
        }
        // [T-toolgroup-original-toggle] Mirror `applySnapshot`: remap measured /
        // estimate / precalc heights by IDENTITY before the apply, so a member
        // height measured at one index never survives the fold at a different
        // index (the historical stale-index-height trap).
        layout.updateCacheForSnapshot(oldIds: old, newIds: items)
        for (index, item) in items.enumerated() {
            layout.setEstimatedHeight(estimateHeight(item), at: index)
        }
        // Same as `applySnapshot`: suppress `contentOffsetAdjustment` for the
        // commit's own layout pass, then let the transaction's settle run with
        // compensation restored.
        layout.suppressContentOffsetAdjustment = true
        defer { layout.suppressContentOffsetAdjustment = false }
        UIView.performWithoutAnimation { list.reloadData() }
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
    //
    // [T-toolgroup-original-toggle] Every case below drives
    // `ToolGroupOriginalToggle.run(_:in:)` — the SAME transaction the chat
    // list's `toggleToolGroup` runs — through this environment. There is no
    // flight, span, retarget, measurement probe or deferred converge on this
    // path any more (the 0.32s accordion was cancelled by user decision on
    // 2026-11-20); the checks prove that, and prove the original geometry.

    private func environment() -> ToolGroupOriginalToggle.Environment {
        ToolGroupOriginalToggle.Environment(
            collectionView: list,
            layout: layout,
            items: { [unowned self] in self.items },
            applyStructure: { [unowned self] caller in
                self.applyCallers.append(caller)
                self.syncStructure()
            },
            indexOf: { [unowned self] item in self.items.firstIndex(of: item) },
            reconfigure: { [unowned self] item in self.reconfigureTappedRow(item) },
            log: { _ in })
    }

    private func request(expanding: Bool) -> ToolGroupOriginalToggle.Request {
        ToolGroupOriginalToggle.Request(item: groupItem,
                                        memberItems: memberItems,
                                        expanding: expanding,
                                        oldIndex: items.firstIndex(of: groupItem) ?? fillerBlocks.count,
                                        anchorY: headerScreenY() ?? 0,
                                        groupTag: "entry")
    }

    /// What the coordinator's `refreshToolGroupToggleRow` does: re-render the
    /// LIVE cell with the state the business just flipped to. The row content
    /// carries `isExpanded` (the one value `BridgedToolGroupV3` bakes into its
    /// cell), so the stage reads it back off the cell.
    private func reconfigureTappedRow(_ item: MessageListItem) {
        guard let idx = items.firstIndex(of: item),
              let cell = list.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell else {
            check(false, "the tapped row is live when the transaction reconfigures it")
            return
        }
        headerRefreshes += 1
        headerRefreshExpanded = pendingExpanded
        cell.applyContentConfiguration(EntryRowConfiguration(height: cellHeight(item),
                                                             isExpanded: pendingExpanded))
        list.layoutIfNeeded()
    }

    // MARK: - Geometry helpers

    private func headerScreenY() -> CGFloat? {
        guard let idx = items.firstIndex(of: groupItem),
              let frame = layout.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))?.frame else { return nil }
        return frame.minY - list.contentOffset.y
    }

    private func legalWindow() -> (min: CGFloat, max: CGFloat) {
        let minOff = -list.adjustedContentInset.top
        let maxOff = max(minOff, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        return (minOff, maxOff)
    }

    /// The three facts that must hold after EVERY run of the original toggle:
    /// no reveal window, no abort channel, an offset inside the legal window.
    private func checkNoFlightResidue(_ label: String) {
        check(layout.toolGroupAccordionSpan == nil, "\(label): no reveal window is installed")
        check(layout.toolGroupAccordionAbort == nil, "\(label): no takeover/abort channel is armed")
        let w = legalWindow()
        let off = list.contentOffset.y
        check(off >= w.min - 0.5 && off <= w.max + 0.5,
              "\(label): offset stays legal (\(off) in \(w.min)…\(w.max))")
    }

    /// The tapped row must come back to where the tap landed, ±0.75pt.
    private func checkAnchor(_ label: String, anchor: CGFloat?) {
        // A missing anchor would make this check compare the row against ITSELF
        // and pass while the tap landed on a row that was not on screen. The
        // anchor is a fact the case must establish, so an absent one fails.
        guard let anchor else {
            check(false, "\(label): the tapped row was on screen when the tap landed (no frame)")
            return
        }
        let after = headerScreenY() ?? -999
        check(abs(after - anchor) <= 0.75,
              "\(label): the tapped row is back at its screen anchor (\(after) vs \(anchor))")
    }

    // MARK: - Cases

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { self.expandCase() }
    }

    private func expandCase() {
        rebuildFolded(tails: true)
        // The header parked 60pt below the top of the viewport, like a real tap
        // on a visible row; the three member rows land inside the viewport and
        // must self-size for real (their estimate is 80, their content 320/300/280).
        positionHeader(at: 60)
        let anchor = headerScreenY()
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        check(outcome != .missing("not-in-snapshot"), "expand: the transaction found the row (\(outcome))")
        check(items.count == expectedExpandedCount,
              "expand: the business apply put the member rows in the list (\(items.count)/\(expectedExpandedCount))")
        check(applyCallers == ["toolGroupToggle"],
              "expand: exactly one structure apply, through the caller's own applySnapshot (\(applyCallers))")
        check(headerRefreshes == 1, "expand: the tapped row was reconfigured once (\(headerRefreshes))")
        check(headerRefreshExpanded == true, "expand: the reconfigure carried the NEW expanded state")
        let cfg = list.cellForItem(at: IndexPath(item: fillerBlocks.count, section: 0))?
            .contentConfiguration as? EntryRowConfiguration
        check(cfg?.isExpanded == true,
              "expand: the live header cell reports isExpanded == true (chevron / a11y source)")
        check(abs((cfg?.height ?? 0) - 28) < 0.5, "expand: the row keeps its fixed height")
        if case .applied(let r) = outcome {
            check(r.fromIndex == r.toIndex, "expand: the group row keeps its index (no row above moved)")
            check(r.offset >= legalWindow().min - 0.5 && r.offset <= legalWindow().max + 0.5,
                  "expand: the transaction's offset is inside the legal window (\(r.offset))")
        } else {
            check(false, "expand: the transaction applied (\(outcome))")
        }
        checkAnchor("expand", anchor: anchor)
        checkNoFlightResidue("expand")
        // Member rows are really in the list, at their real heights, below the header.
        let measured: [CGFloat] = memberItems.indices.map { offset in
            layout.layoutAttributesForItem(at: IndexPath(item: fillerBlocks.count + 1 + offset, section: 0))?.frame.height ?? 0
        }
        let expected: [CGFloat] = [320, 300, 280]
        check(zip(measured, expected).allSatisfy { pair in abs(pair.0 - pair.1) < 2 },
              "expand: every member row is laid out at its content height (\(measured))")
        collapseCase()
    }

    private func collapseCase() {
        rebuildFolded(tails: true)
        // Tap the header at the bottom edge of the viewport: after the member
        // rows drop, the content is still tall enough that the same offset stays
        // legal, so the row keeps its screen anchor exactly.
        positionHeader(at: 472)
        let anchor = headerScreenY()
        pendingExpanded = false
        let outcome = ToolGroupOriginalToggle.run(request(expanding: false), in: environment())
        settle()
        if case .applied(let r) = outcome {
            check(!r.moved, "close: no separate anchor write — the offset was not rewritten (\(r.moved))")
        } else { check(false, "close: the transaction applied (outcome=\(outcome))") }
        check(items.count == expectedFoldedCount,
              "close: the member rows are dropped by the SAME apply (\(items.count)/\(expectedFoldedCount))")
        check(headerRefreshes == 2 && headerRefreshExpanded == false,
              "close: the row was reconfigured with the closed state")
        let cfg = list.cellForItem(at: IndexPath(item: fillerBlocks.count, section: 0))?
            .contentConfiguration as? EntryRowConfiguration
        check(cfg?.isExpanded == false, "close: the live header cell flips to closed at once")
        checkAnchor("close", anchor: anchor)
        checkNoFlightResidue("close")
        check(applyCallers == ["toolGroupToggle", "toolGroupToggle"],
              "close: still one apply per tap, no end-of-flight apply (\(applyCallers))")
        repeatTapCase()
    }

    /// A continuous double tap: expand then close without a run-loop turn in
    /// between. The original switch has no "in-flight" state to retarget, so the
    /// second tap is just the next transaction and the list ends on its state.
    /// The header is parked at the bottom edge where every one of the three
    /// steps keeps its offset legal, so the row never drifts.
    private func repeatTapCase() {
        rebuildFolded(tails: true)
        positionHeader(at: 472)
        for expanding in [true, false, true] {
            pendingExpanded = expanding
            let anchor = headerScreenY()
            _ = ToolGroupOriginalToggle.run(request(expanding: expanding), in: environment())
            settle()
            checkAnchor("repeat", anchor: anchor)
        }
        check(items.count == expectedExpandedCount,
              "repeat: three taps leave the structure of the last one (\(items.count)/\(expectedExpandedCount))")
        checkNoFlightResidue("repeat")
        shortCase()
    }

    /// Content shorter than the viewport: the anchor wants an offset the list
    /// cannot hold, so it collapses to the legal top inset — the pre-accordion
    /// clamp, verified on the real layout.
    private func shortCase() {
        rebuildShort()
        settle()
        let w = legalWindow()
        check(list.contentSize.height <= list.bounds.height - list.adjustedContentInset.top + 0.5,
              "short: the content is really shorter than the viewport (precondition)")
        check(abs(w.max - w.min) < 0.5,
              "short: the only legal offset is the top inset (max \(w.max) == min \(w.min))")
        let anchor = headerScreenY()
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        let top = -list.adjustedContentInset.top
        check(abs(list.contentOffset.y - top) < 0.6,
              "short: the list stays at its legal top (\(list.contentOffset.y) vs \(top))")
        if case .applied(let r) = outcome {
            check(r.offset >= top - 0.5, "short: the transaction clamped instead of scrolling past the top (\(r.offset))")
            check(!r.moved, "short: no offset write was attempted (the clamp was honoured)")
        } else {
            check(false, "short: the transaction applied (\(outcome))")
        }
        check(items.count == expectedExpandedCount, "short: the rows are still open")
        checkAnchor("short", anchor: anchor)
        checkNoFlightResidue("short")
        nearBottomCase()
    }

    /// The header parked at the bottom edge: a close keeps it there and the
    /// offset ends exactly on the legal bottom, never past it. Rebuilt WITHOUT
    /// the tail rows so the bottom of the content is the run's own follow row
    /// (the geometry the original clamp assertion was written for).
    private func nearBottomCase() {
        rebuildFolded(tails: false)
        list.contentOffset = CGPoint(x: 0, y: legalWindow().max)
        settle()
        pendingExpanded = true
        _ = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        pendingExpanded = false
        _ = ToolGroupOriginalToggle.run(request(expanding: false), in: environment())
        settle()
        let w = legalWindow()
        check(list.contentOffset.y <= w.max + 0.5,
              "near-bottom: the offset ends on or above the legal bottom (\(list.contentOffset.y) ≤ \(w.max))")
        check(abs(list.contentOffset.y - w.max) < 0.6,
              "near-bottom: the close lands exactly on the legal bottom (\(list.contentOffset.y) vs \(w.max))")
        checkNoFlightResidue("near-bottom")
        streamingCase()
    }

    /// Streaming does not change the path. The old accordion had to decline
    /// while a run was still producing (frozen heights would end out of date);
    /// the original switch has nothing to freeze, so the same transaction runs
    /// and the business state is the only input.
    private func streamingCase() {
        streaming = true
        rebuildFolded(tails: true)
        positionHeader(at: 472)
        let anchor = headerScreenY()
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        check(items.count == expectedExpandedCount,
              "streaming: the open is applied, not declined (\(items.count)/\(expectedExpandedCount))")
        if case .applied = outcome {} else { check(false, "streaming: applied (outcome=\(outcome))") }
        checkAnchor("streaming", anchor: anchor)
        checkNoFlightResidue("streaming")
        streaming = false
        reduceMotionCase()
    }

    /// Reduce motion changes nothing either: there is no animation left to
    /// suppress, so the same instant switch is the whole behaviour.
    private func reduceMotionCase() {
        rebuildFolded(tails: true)
        positionHeader(at: 472)
        reduceMotion = true
        let anchor = headerScreenY()
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        check(items.count == expectedExpandedCount,
              "reduce-motion: the same instant switch runs (\(items.count)/\(expectedExpandedCount))")
        if case .applied = outcome {} else { check(false, "reduce-motion: applied (outcome=\(outcome))") }
        checkAnchor("reduce-motion", anchor: anchor)
        checkNoFlightResidue("reduce-motion")
        reduceMotion = false
        missingRowCase()
    }

    /// A session swap under the tap: the row is gone, so the transaction owes
    /// only the business apply and must not write the offset. The swap is a
    /// REAL data-source replace + settle (the list is rebuilt before the tap),
    /// so the baseline the offset is compared against is the post-swap offset,
    /// not the pre-swap one the transaction's own apply legitimately clamps.
    private func missingRowCase() {
        rebuildFolded(tails: true)
        positionHeader(at: 472)
        pendingExpanded = true
        let saved = items
        items = fillerBlocks.map { .assistantBlock(messageId, $0) }
        reload()
        let before = list.contentOffset.y
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        settle()
        if case .missing = outcome {
            check(true, "missing: the transaction reports the missing row")
        } else {
            check(false, "missing: the transaction reports the missing row (outcome=\(outcome))")
        }
        check(abs(list.contentOffset.y - before) < 0.5,
              "missing: no offset write without a row (\(list.contentOffset.y) vs \(before))")
        items = saved
        checkNoFlightResidue("missing")
        done()
    }

    private func done() {
        list.removeFromSuperview()
        // [T-toolgroup-original-toggle] The marker carries the VERDICT: a run
        // with failures must never print _PASS (it would let a red entry stage
        // satisfy the CI grep). The driver requires _PASS with failures=0.
        let verdict = failures.isEmpty ? "PASS" : "FAIL"
        let marker = "TOOLGROUP_ORIGINAL_TOGGLE_\(verdict)"
        print("\(marker) checks=\(checks) failures=\(failures.count) detail=\(failures.joined(separator: "; "))")
        print("TOOLGROUP_ENTRY_\(verdict) checks=\(checks) failures=\(failures.joined(separator: "; "))")
        report(failures.isEmpty, "entry stage: \(checks) checks")
    }
}
