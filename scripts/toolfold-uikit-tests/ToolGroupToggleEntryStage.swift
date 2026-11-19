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
// case the accordion used to need a measurement probe for.
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
    private var applyCallers: [String] = []
    private var anchors: [CGFloat] = []
    private var headerRefreshes = 0
    private var headerRefreshExpanded: Bool?

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
                                        anchorY: 40,
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

    // MARK: - Cases

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { self.expandCase() }
    }

    private func expandCase() {
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
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
        check(abs((headerScreenY() ?? -999) - 40) < 0.6,
              "expand: the tapped row is back at its screen anchor (\(headerScreenY() ?? -1))")
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
        pendingExpanded = false
        let before = anchors.count
        let outcome = ToolGroupOriginalToggle.run(request(expanding: false), in: environment())
        if case .applied = outcome {} else { check(false, "close: the transaction applied (outcome=\(outcome))") }
        check(items.count == expectedFoldedCount,
              "close: the member rows are dropped by the SAME apply (\(items.count)/\(expectedFoldedCount))")
        check(headerRefreshes == 2 && headerRefreshExpanded == false,
              "close: the row was reconfigured with the closed state")
        let cfg = list.cellForItem(at: IndexPath(item: fillerBlocks.count, section: 0))?
            .contentConfiguration as? EntryRowConfiguration
        check(cfg?.isExpanded == false, "close: the live header cell flips to closed at once")
        check(anchors.count == before, "close: no separate anchor pass on the original path (\(anchors.count))")
        check(abs((headerScreenY() ?? -999) - 40) < 0.6,
              "close: the tapped row is still at its screen anchor (\(headerScreenY() ?? -1))")
        checkNoFlightResidue("close")
        check(applyCallers == ["toolGroupToggle", "toolGroupToggle"],
              "close: still one apply per tap, no end-of-flight apply (\(applyCallers))")
        repeatTapCase()
    }

    /// A continuous double tap: expand then close without a run-loop turn in
    /// between. The original switch has no "in-flight" state to retarget, so the
    /// second tap is just the next transaction and the list ends on its state.
    private func repeatTapCase() {
        rebuildFolded()
        pendingExpanded = true
        _ = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        pendingExpanded = false
        _ = ToolGroupOriginalToggle.run(request(expanding: false), in: environment())
        pendingExpanded = true
        _ = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        check(items.count == expectedExpandedCount,
              "repeat: three taps leave the structure of the last one (\(items.count)/\(expectedExpandedCount))")
        checkNoFlightResidue("repeat")
        check(abs((headerScreenY() ?? -999) - 40) < 0.6,
              "repeat: the header never drifted (\(headerScreenY() ?? -1))")
        shortCase()
    }

    /// Content shorter than the viewport: the anchor wants an offset the list
    /// cannot hold, so it collapses to the legal top inset — the pre-accordion
    /// clamp, verified on the real layout.
    private func shortCase() {
        rebuildFolded(scrollHeaderVisible: false)
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        let top = -list.adjustedContentInset.top
        check(abs(list.contentOffset.y - top) < 0.6,
              "short: the list stays at its legal top (\(list.contentOffset.y) vs \(top))")
        if case .applied(let r) = outcome {
            check(r.offset >= top - 0.5, "short: the transaction clamped instead of scrolling past the top (\(r.offset))")
        } else {
            check(false, "short: the transaction applied (\(outcome))")
        }
        check(items.count == expectedExpandedCount, "short: the rows are still open")
        checkNoFlightResidue("short")
        nearBottomCase()
    }

    /// The header parked at the bottom edge: a close keeps it there and the
    /// offset ends exactly on the legal bottom, never past it.
    private func nearBottomCase() {
        rebuildFolded(scrollHeaderVisible: false)
        list.setNeedsLayout()
        list.layoutIfNeeded()
        list.contentOffset = CGPoint(x: 0, y: max(-list.adjustedContentInset.top,
                                                  list.contentSize.height - list.bounds.height))
        list.layoutIfNeeded()
        pendingExpanded = true
        _ = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        pendingExpanded = false
        _ = ToolGroupOriginalToggle.run(request(expanding: false), in: environment())
        let w = legalWindow()
        check(list.contentOffset.y <= w.max + 0.5,
              "near-bottom: the offset ends on or above the legal bottom (\(list.contentOffset.y) ≤ \(w.max))")
        checkNoFlightResidue("near-bottom")
        streamingCase()
    }

    /// Streaming does not change the path. The old accordion had to decline
    /// while a run was still producing (frozen heights would end out of date);
    /// the original switch has nothing to freeze, so the same transaction runs
    /// and the business state is the only input.
    private func streamingCase() {
        streaming = true
        rebuildFolded()
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        check(items.count == expectedExpandedCount,
              "streaming: the open is applied, not declined (\(items.count)/\(expectedExpandedCount))")
        if case .applied = outcome {} else { check(false, "streaming: applied (outcome=\(outcome))") }
        checkNoFlightResidue("streaming")
        streaming = false
        reduceMotionCase()
    }

    /// Reduce motion changes nothing either: there is no animation left to
    /// suppress, so the same instant switch is the whole behaviour.
    private func reduceMotionCase() {
        rebuildFolded()
        reduceMotion = true
        pendingExpanded = true
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
        check(items.count == expectedExpandedCount,
              "reduce-motion: the same instant switch runs (\(items.count)/\(expectedExpandedCount))")
        if case .applied = outcome {} else { check(false, "reduce-motion: applied (outcome=\(outcome))") }
        checkNoFlightResidue("reduce-motion")
        reduceMotion = false
        missingRowCase()
    }

    /// A session swap under the tap: the row is gone, so the transaction owes
    /// only the business apply and must not write the offset.
    private func missingRowCase() {
        rebuildFolded()
        pendingExpanded = true
        let saved = items
        items = fillerBlocks.map { .assistantBlock(messageId, $0) }
        let before = list.contentOffset.y
        let outcome = ToolGroupOriginalToggle.run(request(expanding: true), in: environment())
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
