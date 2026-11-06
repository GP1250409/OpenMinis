import UIKit
import SwiftUI

// MARK: - Fixture: the thinking row's real SwiftUI structure

/// A thinking row with the production geometry (36pt header + 10pt vertical
/// padding, body capped at ThinkingBlockView.bodyMaxHeight = 300, same fonts
/// and paddings as `ThinkingBlockView`). Only the AssistantBlock model and the
/// streaming follow logic are omitted — see build/thinking-transaction-test-needs.md
/// for the declared gap. The measured heights therefore come from real SwiftUI
/// layout, not from a constant.
struct ThinkingRowFixture: View {
    static let bodyMaxHeight: CGFloat = 300
    static let headerHeight: CGFloat = 36
    let text: String
    let isExpanded: Bool
    let streaming: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain").font(.system(size: 14))
                Text("Deep Thinking").font(.system(size: 13, weight: .semibold))
                if streaming { ProgressView().controlSize(.mini) }
                Spacer()
                Text("\(text.count)").font(.system(size: 11, weight: .medium, design: .monospaced))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: ThinkingRowFixture.headerHeight)
            .contentShape(Rectangle())
            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .frame(maxHeight: ThinkingRowFixture.bodyMaxHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Match the production thinking root's top-aligned hosting hand-off.
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A filler row (an ordinary answer) so the thinking row sits in a list with
/// content above AND below it — the situation where an un-anchored re-measure
/// moves the whole list.
struct FillerRowFixture: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keep a real scroll range in collapsed AND expanded states; the
            // tests deliberately interrupt by 120pt and must not hit a clamp.
            .frame(minHeight: 100, alignment: .topLeading)
    }
}

// MARK: - List harness: real MessageListLayout + real SelfSizingCell

/// Model of one row. `thinking` marks the row under test.
final class RowModel {
    let id = UUID()
    var thinking: Bool
    var text: String
    var expanded: Bool
    // An asynchronous view constraint, deliberately outside the 300pt body
    // cap, lets the late-sizing test force a REAL additional fitted height.
    var delayedMinimumHeight: CGFloat = 0
    init(thinking: Bool, text: String, expanded: Bool = false) {
        self.thinking = thinking
        self.text = text
        self.expanded = expanded
    }
    var item: MessageListItem { thinking ? .assistantBlock(id, id) : .wholeMessage(id) }
}

final class ListHarness {
    let rows: [RowModel]
    let targetIndex: Int
    let layout = MessageListLayout()
    // SelfSizingCell intentionally refuses to re-enter a detached hosting
    // graph. A real retained window is therefore part of every UI fixture.
    private let testWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    private(set) var collection: UICollectionView!
    private(set) var controller: CollectionViewMessageListV3.TxListViewController!
    let coordinator = CollectionViewMessageListV3.Coordinator()
    private var tokenSeq = 0

    init(rows: [RowModel], targetIndex: Int) {
        self.rows = rows
        self.targetIndex = targetIndex
        // The production type: the transaction sets `animatesNextLayoutPass` on
        // it through a cast (the fixture defines only that member).
        collection = NoAnimationCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 700),
                                               collectionViewLayout: layout)
        collection.contentInsetAdjustmentBehavior = .never
        // -40 is the valid resting offset used throughout the suite.
        collection.contentInset = UIEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
        collection.register(SelfSizingCell.self, forCellWithReuseIdentifier: "cell")
        controller = CollectionViewMessageListV3.TxListViewController(collectionView: collection, messageListLayout: layout)
        coordinator.viewController = controller
        coordinator.nearBottom = true
        coordinator.applyConfiguration = { [weak self] cell, item, ip in
            self?.configure(cell, at: ip.item)
        }
        let ds = UICollectionViewDiffableDataSource<CollectionViewMessageListV3.Section, MessageListItem>(
            collectionView: collection) { [weak self] cv, ip, item in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "cell", for: ip) as! SelfSizingCell
                self?.configure(cell, at: ip.item)
                return cell
            }
        coordinator.dataSource = ds
        coordinator.vm = CollectionViewMessageListV3.TxViewModel()
        coordinator.snapshotMessages = rows.map { row in
            let block = CollectionViewMessageListV3.AssistantBlock(id: row.id, thinking: row.thinking)
            block.readExpanded = { [weak row] in row?.expanded ?? false }
            return CollectionViewMessageListV3.TxMessage(id: row.id, blocks: [block])
        }
        coordinator.vm?.messages = coordinator.snapshotMessages
        var snap = NSDiffableDataSourceSnapshot<CollectionViewMessageListV3.Section, MessageListItem>()
        snap.appendSections([0])
        snap.appendItems(rows.map { $0.item }, toSection: 0)
        ds.apply(snap, animatingDifferences: false)
        controller.view.frame = collection.frame
        testWindow.rootViewController = controller
        testWindow.makeKeyAndVisible()
        testWindow.layoutIfNeeded()
        collection.layoutIfNeeded()
        pump(0.08)
        collection.layoutIfNeeded()
    }

    deinit { testWindow.isHidden = true }

    var nextTokenValue: Int { tokenSeq }

    /// Mirrors the coordinator's monotonic token sequence for assertions.
    func nextToken() -> Int {
        tokenSeq = ThinkingToggleTxnMath.nextToken(after: tokenSeq)
        return tokenSeq
    }

    func configure(_ cell: SelfSizingCell, at index: Int) {
        guard index < rows.count else { return }
        let row = rows[index]
        cell.rendersNonEmptyText = true
        cell.contentKey = "t:\(row.id.uuidString):\(row.expanded ? "x" : "c")"
        layout.setContentKey(cell.contentKey!, at: index)
        layout.setEstimatedHeight(200, at: index)
        let key = cell.contentKey!
        if row.thinking {
            let text = row.text, expanded = row.expanded, delayedMinimum = row.delayedMinimumHeight
            cell.applyContentConfiguration(UIHostingConfiguration {
                ThinkingRowFixture(text: text, isExpanded: expanded, streaming: false)
                    .frame(minHeight: delayedMinimum > 0 ? delayedMinimum : nil, alignment: .top)
            })
        } else {
            let text = row.text
            cell.applyContentConfiguration(UIHostingConfiguration {
                FillerRowFixture(text: text)
            })
        }
        _ = key
    }

    var targetItem: MessageListItem { rows[targetIndex].item }
    var targetIndexPath: IndexPath { IndexPath(item: targetIndex, section: 0) }
    var targetCell: SelfSizingCell? { collection.cellForItem(at: targetIndexPath) as? SelfSizingCell }
    func rowHeight(_ index: Int) -> CGFloat {
        layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height ?? -1
    }
    func targetTopOnScreen() -> CGFloat {
        guard let attrs = layout.layoutAttributesForItem(at: targetIndexPath) else { return .nan }
        return attrs.frame.minY - collection.contentOffset.y
    }
    func layoutNow() {
        collection.layoutIfNeeded()
        pump(0.02)
        collection.layoutIfNeeded()
    }
    func refreshTargetContent() {
        if let cell = targetCell {
            configure(cell, at: targetIndex)
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
        }
    }
    func targetFittedHeight() -> CGFloat {
        guard let cell = targetCell, let attrs = layout.layoutAttributesForItem(at: targetIndexPath) else { return -1 }
        cell.clearCachedHeight()
        return cell.preferredLayoutAttributesFitting(attrs.copy() as! UICollectionViewLayoutAttributes).size.height
    }
    /// Startup is a run-loop Timer callback, NOT a main-dispatch block.
    /// Pump in short slices and prove actual dispatch/timer delivery via the
    /// gate below; slicing alone cannot make a main-queue block reentrant.
    func pump(_ seconds: Double) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            let slice = min(0.004, end.timeIntervalSinceNow)
            if slice <= 0 { break }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: slice))
            RunLoop.main.run(mode: .common, before: Date(timeIntervalSinceNow: 0.0005))
        }
    }

    /// Prove async deliverability before anything depends on it: a main-queue
    /// block AND a run-loop timer must both fire during one pump.
    func asyncPumpGate() -> (asyncBlock: Bool, timer: Bool) {
        var blockRan = false
        var timerRan = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { blockRan = true }
        let timer = Timer(timeInterval: 0.02, repeats: false) { _ in timerRan = true }
        RunLoop.main.add(timer, forMode: .common)
        pump(0.25)
        return (blockRan, timerRan)
    }

    /// Let the list reach a settled layout (SwiftUI delivers late filler
    /// heights a frame or two after the first layout) before any measurement
    /// that is supposed to be a *baseline*.
    func warmUp(_ seconds: Double = 0.45) {
        collection.layoutIfNeeded()
        pump(seconds)
        collection.layoutIfNeeded()
        pump(0.05)
        collection.layoutIfNeeded()
    }

    /// Reconfigure through the actual diffable data source. Do not bypass
    /// UIKit's sizing invalidation with a direct height-cache write.
    func reconfigureItem(_ index: Int) {
        guard let ds = coordinator.dataSource else { return }
        var snap = ds.snapshot()
        snap.reconfigureItems([rows[index].item])
        ds.apply(snap, animatingDifferences: false)
        layout.invalidateLayout()
        collection.layoutIfNeeded()
        pump(0.15)
        collection.layoutIfNeeded()
    }

    /// The fixture model block for a row (the transaction reads the model's
    /// manual marker + expanded state through `assistantBlock(id:)`).
    func block(at index: Int) -> CollectionViewMessageListV3.AssistantBlock? {
        coordinator.snapshotMessages.first { $0.id == rows[index].id }?.blocks.first
    }

    /// Drives the REAL production transaction for one row.
    func transactionToggle(index: Int, request: ToggleRequest?) {
        coordinator.thinkingToggleAnchored(blockId: rows[index].id, item: rows[index].item,
                                           index: index, request: request)
    }
    /// Drives the REAL cross-frame verifier.
    func verify(token: Int, stableHits: Int) {
        coordinator.verifyThinkingToggle(token: token, stableHits: stableHits)
    }
    /// Lets the transaction's own async hops (confirm/fix) run.
    func settleFrames(_ frames: Int = 6) { pump(0.05 * Double(frames)) }
}

// MARK: - App entry

@main
final class ThinkingTransactionApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        let start = Timer(timeInterval: 0.4, repeats: false) { _ in
            let suite = ThinkingTransactionTests()
            suite.run()
            print("THINKING_TRANSACTION_UIKIT_CHECKS \(CheckLog.passed)")
            if CheckLog.failed > 0 {
                print("THINKING_TRANSACTION_UIKIT_FAIL \(CheckLog.failed)")
                exit(2)
            }
            print("THINKING_TRANSACTION_UIKIT_PASS checks=\(CheckLog.passed)")
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.add(start, forMode: .common)
        return true
    }
}
