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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(Color.blue.opacity(0.15)).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text("我想把 com.openminis.app 切到前台").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text("已回答 0/2").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomLeading) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<questions, id: \.self) { i in
                        Text("问题 \(i)：可以把当前这个聊天切到后台吗").font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("已超时 · No answer within 5 min").font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 46).padding(.top, 54)
            }
        }
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

    init(items: Int = 8, tail: Bool = false) {
        layout.collectionView = cv
        cv.collectionViewLayout = layout
        layout.estimatedItemSize = CGSize(width: 390, height: 80)
        vc = CollectionViewMessageListV3.TxListViewController(collectionView: cv, messageListLayout: layout)
        coordinator = CollectionViewMessageListV3.Coordinator()
        coordinator.viewController = vc
        coordinator.scrollMode = .autoScrolling
        window.rootViewController = vc
        window.makeKeyAndVisible()
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

    var contentSizeHeight: CGFloat { cv.contentSize.height }

    var maxOffset: CGFloat { cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom }

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
