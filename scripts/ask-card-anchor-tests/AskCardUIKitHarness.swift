// [T-user-ask-anchor-clamp] Real UICollectionView fixture for the answered-question
// card toggle. Compiled by scripts/ask_card_anchor_uikit.py together with:
//   * the SHIPPING MessageListLayout.swift (layout + ToggleAnchorMath + token API),
//   * the SHIPPING SelfSizingCell / MessageListItem slices,
//   * the SHIPPING `remeasureKeepingTop` … `verifyToggledHeight` block, extracted
//     verbatim from MessageListV3Coordinator+ToolFolding.swift into an extension of
//     the fixture Coordinator (scripts/thinking-transaction-tests/TxCoordinatorStub.swift),
//   * ProductionStubs.swift (AppLogger / CrashBreadcrumbs / NoAnimationCollectionView).
// Nothing here re-implements the anchor algorithm: the scenarios drive the production
// methods and only observe geometry.
import Foundation
import SwiftUI
import UIKit

var checks = 0
var failures = 0

func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label) \(detail)") }
}
func f(_ x: CGFloat) -> String { String(format: "%.1f", Double(x)) }

/// The card as the list sees it: a hosting row whose height changes with the
/// toggle. Same shape as UserAskResolvedCard (34pt header, questions below).
struct FixtureAskCard: View {
    let expanded: Bool
    let questions: Int
    var body: some View {
        // [T-ask-fixture-settle-after-attach] The expanded questions are part of
        // the CARD'S OWN LAYOUT FLOW (VStack), not an `.overlay`, and the card
        // no longer fills `maxHeight: .infinity`. With an overlay the expanded
        // content contributes nothing to the ideal height, so whether the row
        // measured 61.3 or 133.0 depended on HOW MUCH HEIGHT the measure
        // proposed (compressed proposal → header only; unspecified proposal →
        // overlay counted) - a fixture artefact, not the production card. The
        // real card is header + questions below it (see the comment above), so
        // its height must be a function of `expanded` alone.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(Color.blue.opacity(0.15)).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text("我想把 com.openminis.app 切到前台").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text("已回答 0/2").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<questions, id: \.self) { i in
                        Text("问题 \(i)：可以把当前这个聊天切到后台吗").font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("已超时 · No answer within 5 min").font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 46)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
    }
}

/// Tool-group row stand-in: real height difference between collapsed/expanded,
/// which is exactly what changes the scroll range under the card.
struct FixtureToolGroup: View {
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("已执行 24 个工具 · 54s").font(.system(size: 13)); Spacer() }
                .frame(height: 28)
            if expanded {
                ForEach(0..<8, id: \.self) { i in
                    Text("tool \(i) output line").font(.system(size: 12)).frame(height: 40, alignment: .leading)
                }
            }
        }
    }
}

/// Records every contentSize change together with the offset that was in effect
/// at that moment. If the offset is already outside the NEW range, UIScrollView
/// is about to correct it inside its own layout pass - animations off, i.e. the
/// single-frame page shift from the recording. This is the assertion that the
/// pre-clamp actually happens before the resize.
final class ClampSpy {
    var observations = 0
    var outOfRange = 0
    var worst: CGFloat = 0
    private var obs: NSKeyValueObservation?
    func attach(_ cv: UICollectionView) {
        obs = cv.observe(\.contentSize, options: [.old, .new]) { [weak cv] _, _ in
            guard let cv else { return }
            self.observations += 1
            let minOff = -cv.adjustedContentInset.top
            let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            let over = cv.contentOffset.y - max(minOff, maxOff)
            if over > 1.0 { self.outOfRange += 1; self.worst = max(self.worst, over) }
        }
    }
    func reset() { observations = 0; outOfRange = 0; worst = 0 }
}

/// The production list's collection view, with the drag state forceable: the
/// delegate reads `isTracking` to keep its hands off a finger-held offset, and a
/// simulator cannot start a real touch from inside a fixture.
final class FixtureCollectionView: NoAnimationCollectionView {
    private var forcedTracking = false
    override var isTracking: Bool { forcedTracking }
    override var isDragging: Bool { forcedTracking }
    func beginDragForFixture() { forcedTracking = true }
    func endDragForFixture() { forcedTracking = false }
}

final class AskCardFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 760))
    let layout = MessageListLayout()
    let cv = FixtureCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 700),
                                       collectionViewLayout: UICollectionViewLayout())
    let vc: CollectionViewMessageListV3.TxListViewController
    let coordinator: CollectionViewMessageListV3.Coordinator
    var ds: UICollectionViewDiffableDataSource<Int, MessageListItem>!
    let spy = ClampSpy()
    var expanded: [UUID: Bool] = [:]
    var toolExpanded = false
    var cardIds: [UUID] = []
    var msgId = UUID()
    /// Set by `attach(to:)`: the list only measures inside a real window.
    private(set) var attached = false
    /// How many settle rounds ran after the attach; 0 means "not settled".
    private(set) var settleRounds = 0
    /// Human-readable measurement sequence, used in failure messages only.
    private(set) var settleTrace = "not-run"

    init(items: Int = 8, tail: Bool = false) {
        // `UICollectionViewLayout.collectionView` is get-only: the binding is
        // made by assigning the layout to the collection view (ThinkingHarness /
        // GenUIListHarness create the cv WITH the layout). MessageListLayout is
        // a plain UICollectionViewLayout, not a flow layout, so its estimate is
        // `estimatedItemHeight` (MessageListLayout.swift:17) - there is no
        // `estimatedItemSize`.
        cv.collectionViewLayout = layout
        layout.estimatedItemHeight = 80
        vc = CollectionViewMessageListV3.TxListViewController(collectionView: cv, messageListLayout: layout)
        coordinator = CollectionViewMessageListV3.Coordinator()
        coordinator.viewController = vc
        coordinator.scrollMode = .autoScrolling
        // [T-ask-fixture-settle-after-attach] NO window attach and NO settle
        // here: this fixture is built, and only then put on screen by the host
        // (`attach(to:)`); the settle runs after that, when the collection view
        // really is in a window. Settling a hosting row that has never been on
        // screen measured its collapsed height (run 44449400147: 61.3).
        cv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)

        let reg = UICollectionView.CellRegistration<SelfSizingCell, MessageListItem> { [unowned self] cell, _, item in
            self.coordinator.applyConfiguration?(cell, item, IndexPath(item: 0, section: 0))
        }
        ds = UICollectionViewDiffableDataSource<Int, MessageListItem>(collectionView: cv) { cv, ip, item in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: item)
        }
        coordinator.dataSource = ds
        coordinator.applyConfiguration = { [unowned self] cell, item, _ in
            switch item {
            case .assistantBlock(_, let bid) where self.cardIds.contains(bid):
                cell.contentConfiguration = UIHostingConfiguration {
                    FixtureAskCard(expanded: self.expanded[bid] ?? false, questions: 2)
                }.margins(.all, 0)
            case .toolGroup:
                cell.contentConfiguration = UIHostingConfiguration {
                    FixtureToolGroup(expanded: self.toolExpanded)
                }.margins(.all, 0)
            default:
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(String(repeating: "历史消息 ", count: 3)).font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.margins(.all, 0)
            }
        }
        var items_: [MessageListItem] = []
        for _ in 0..<items { items_.append(.assistantBlock(msgId, UUID())) }
        let card = UUID()
        cardIds = [card]
        expanded[card] = true
        items_.append(.assistantBlock(msgId, card))
        items_.append(.toolGroup(msgId, UUID()))
        var snap = NSDiffableDataSourceSnapshot<Int, MessageListItem>()
        snap.appendSections([0]); snap.appendItems(items_)
        ds.apply(snap, animatingDifferences: false)
        cv.layoutIfNeeded()
        spy.attach(cv)
        scrollToBottom()
    }

    /// Put the list on screen. The collection view becomes the window's root
    /// view and the window is made key and visible - nothing is measured here,
    /// so the ordering "attach first, settle after" is visible in the code.
    @discardableResult
    func attach(to hostView: UIWindow? = nil) -> Bool {
        let host = hostView ?? window
        if host.rootViewController !== vc { host.rootViewController = vc }
        host.makeKeyAndVisible()
        host.layoutIfNeeded()
        cv.layoutIfNeeded()
        attached = cv.window != nil
        return attached
    }

    /// Host entry point: attach, then settle. This is the only ordering the
    /// fixture allows - `settleAfterAttach` refuses to run off-window.
    @discardableResult
    func attachAndSettle() -> Bool {
        guard attach() else { return false }
        return settleAfterAttach()
    }

    var contentSizeHeight: CGFloat { cv.contentSize.height }

    var maxOffset: CGFloat { cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom }

    /// The legal upper bound of `contentOffset.y`. A list whose content is
    /// SHORTER than the viewport has `maxOffset < minOffset`, and the only legal
    /// offset there is `minOffset` - UIScrollView clamps to it, so asserting
    /// `offset <= maxOffset` is simply wrong (run 44439673271: off=0.0,
    /// max=-392.7). Same clamp the ClampSpy uses.
    var minOffset: CGFloat { -cv.adjustedContentInset.top }

    var legalUpperOffset: CGFloat { max(minOffset, maxOffset) }

    /// [T-ask-fixture-settle-after-attach] Settle the INITIAL geometry - but only
    /// after the list is really on screen, and only with a number the SHIPPING
    /// measure channel produced for a RENDERED card.
    ///
    /// History: run 44449400147 settled from `init`, before the collection view
    /// had ever been in a window. `preferredLayoutAttributesFitting` then
    /// answered with the collapsed 61.3 for the EXPANDED card, and `settle`
    /// installed that number through `layout.setMeasuredHeight` - so S1 started
    /// collapsed and S4's row never agreed with its own 133.0 measurement.
    ///
    /// Each round re-applies every configuration (a FRESH hosting
    /// configuration, exactly what the production toggle does, inside the same
    /// no-animation transaction), lets UIKit lay out and the run loop turn,
    /// then measures the real cell through
    /// `SelfSizingCell.preferredLayoutAttributesFitting` at the collection
    /// view's own width. Rounds stop when two consecutive measurements agree;
    /// only that stable number is installed with `layout.setMeasuredHeight`.
    /// No height literal exists anywhere in here.
    @discardableResult
    func settleAfterAttach(maxRounds: Int = 8) -> Bool {
        // The precondition the whole fix rests on: nothing can be measured for
        // a row that is not in a window. Refuse loudly instead of settling a
        // number no render ever produced.
        guard cv.window != nil else {
            settleTrace = "window=nil"
            print("[settle] refused window=nil attached=\(attached) cv=\(fmt(cv.frame)) content=\(fmt(cv.contentSize))")
            return false
        }
        guard let cardIndex = ds.snapshot().itemIdentifiers.firstIndex(where: {
            if case .assistantBlock(_, let b) = $0 { return cardIds.contains(b) }
            return false
        }) else {
            settleTrace = "no-card"
            print("[settle] refused no answered-question card in the snapshot")
            return false
        }
        let card = cardIds[0]
        let cardIsExpanded = expanded[card] ?? false

        var rounds = 0
        var previous: [Int: CGFloat] = [:]
        var latest: [Int: CGFloat] = [:]
        var cardTrace: [CGFloat] = []
        while rounds < maxRounds {
            rounds += 1
            reconfigureAllRows()
            let measured = measureAllRows()
            guard !measured.isEmpty else { break }
            latest = measured
            if let h = measured[cardIndex] { cardTrace.append(h) }
            if previous.count == measured.count,
               previous.allSatisfy({ (i, h) in abs((measured[i] ?? h) - h) <= 0.5 }) {
                break
            }
            previous = measured
        }
        settleRounds = rounds

        // Can this fixture express the expanded card at all? Ask the SAME cell
        // through the SAME channel for its collapsed height and compare. If the
        // expanded state does not measure taller, the fixture - not the card -
        // is the problem, and the cases must fail saying so (the three
        // assertions are never weakened).
        var collapsedProbe: CGFloat?
        if cardIsExpanded, let live = latest[cardIndex] {
            collapsedProbe = collapsedHeightProbe(cardIndex)
            if let c = collapsedProbe, live <= c + 1.0 {
                settleTrace = cardTrace.map { f($0) }.joined(separator: ",")
                print("[settle] UNREPRESENTABLE expanded=\(f(live)) collapsed=\(f(c)) trace=\(settleTrace) "
                      + "window=1 cv=\(fmt(cv.bounds)) content=\(fmt(cv.contentSize)) rounds=\(rounds)")
                return false
            }
            // The probe reconfigured the row; measure the real state again.
            reconfigureAllRows()
            if let h = measureRow(cardIndex) { latest[cardIndex] = h; cardTrace.append(h) }
        }

        var installed = 0
        for (i, fitted) in latest.sorted(by: { $0.key < $1.key }) where fitted > 1 {
            // `fitted` is the stable number `measureRow` got from the SHIPPING
            // cell - never a literal, never an estimate.
            layout.setMeasuredHeight(fitted, at: i)
            installed += 1
        }
        layout.invalidateLayout()
        cv.layoutIfNeeded()
        window.layoutIfNeeded()
        pump(0.1)
        scrollToBottom()
        settleTrace = cardTrace.map { f($0) }.joined(separator: ",")
        print("[settle] window=1 rounds=\(rounds) installed=\(installed) card=\(settleTrace) "
              + "collapsed=\(collapsedProbe.map { f($0) } ?? "-") cv=\(fmt(cv.bounds)) content=\(fmt(cv.contentSize))")
        return installed > 0
    }

    /// Re-apply every row's configuration inside the same "no animation"
    /// transaction the production toggle uses, so the hosting view applies the
    /// new state before the measure runs instead of on its next update.
    private func reconfigureAllRows() {
        let items = ds.snapshot().itemIdentifiers
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            withTransaction(noAnim) {
                var snap = ds.snapshot()
                snap.reconfigureItems(items)
                ds.apply(snap, animatingDifferences: false)
                for (i, _) in items.enumerated() { layout.invalidateHeight(at: i) }
                layout.invalidateLayout()
                cv.layoutIfNeeded()
                window.layoutIfNeeded()
            }
            CATransaction.commit()
        }
        pump(0.05)
    }

    private func measureAllRows() -> [Int: CGFloat] {
        var measured: [Int: CGFloat] = [:]
        for (i, _) in ds.snapshot().itemIdentifiers.enumerated() {
            if let h = measureRow(i) { measured[i] = h }
        }
        return measured
    }

    /// One REAL measurement of the live cell for `index` through the shipping
    /// self-sizing channel. `nil` when the row has no cell on screen - nothing
    /// can honestly be measured then.
    private func measureRow(_ index: Int) -> CGFloat? {
        let ip = IndexPath(item: index, section: 0)
        guard let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
              cell.window != nil, cell.contentConfiguration != nil else { return nil }
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        cell.clearCachedHeight()
        let attrs = UICollectionViewLayoutAttributes(forCellWith: ip)
        // The width UIKit hands a cell in a real self-sizing pass. A zero-width
        // attributes object is not what the shipping path sees.
        attrs.size = CGSize(width: cv.bounds.width, height: cell.bounds.height)
        let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
        return fitted.isFinite ? fitted : nil
    }

    /// Height the SAME cell reports for its COLLAPSED card, through the same
    /// production channel. Diagnostics only - this number is never installed.
    private func collapsedHeightProbe(_ index: Int) -> CGFloat? {
        guard let card = cardIds.first else { return nil }
        expanded[card] = false
        reconfigureAllRows()
        let h = measureRow(index)
        expanded[card] = true
        return h
    }

    private func fmt(_ r: CGRect) -> String { "\(f(r.width))x\(f(r.height))" }
    private func fmt(_ s: CGSize) -> String { "\(f(s.width))x\(f(s.height))" }

    func scrollToBottom() {
        cv.setContentOffset(CGPoint(x: 0, y: max(0, maxOffset)), animated: false)
        cv.layoutIfNeeded()
    }

    func frame(of blockId: UUID) -> CGRect? {
        guard let item = ds.snapshot().itemIdentifiers.first(where: {
            if case .assistantBlock(_, let b) = $0 { return b == blockId }
            return false
        }), let i = ds.snapshot().itemIdentifiers.firstIndex(of: item) else { return nil }
        return cv.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
    }

    /// Drive the SHIPPING remeasureKeepingTop with the same one-shot request the
    /// card's tap posts.
    func toggleCard(_ id: UUID) {
        guard let item = ds.snapshot().itemIdentifiers.first(where: {
            if case .assistantBlock(_, let b) = $0 { return b == id }
            return false
        }), let i = ds.snapshot().itemIdentifiers.firstIndex(of: item) else { return }
        coordinator.nearBottom = cv.contentOffset.y >= maxOffset - 40
        let request = ToggleRequest { [weak self] in
            self?.expanded[id] = !(self?.expanded[id] ?? false)
        }
        coordinator.remeasureKeepingTop(item: item, index: i, blockId: id, request: request)
        request.run()
    }

    func toggleTool() {
        toolExpanded.toggle()
        var snap = ds.snapshot()
        let groups = snap.itemIdentifiers.filter { if case .toolGroup = $0 { return true }; return false }
        snap.reconfigureItems(groups)
        ds.apply(snap, animatingDifferences: false)
        layout.invalidateLayout()
        cv.layoutIfNeeded()
        scrollToBottom()
    }

    func pump(_ seconds: TimeInterval = 1.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Snapshot swap: a new session / a tool-group fold replaces the items.
    func replaceSnapshot(count: Int = 3) {
        var snap = NSDiffableDataSourceSnapshot<Int, MessageListItem>()
        snap.appendSections([0]); snap.appendItems((0..<count).map { _ in .assistantBlock(msgId, UUID()) })
        ds.apply(snap, animatingDifferences: false)
        layout.invalidateLayout()
        cv.layoutIfNeeded()
    }
}
