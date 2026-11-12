import Combine
import UIKit
import SwiftUI

// MARK: - List harness: real MessageListLayout + real SelfSizingCell + real MinisUIStore

/// One row of the mounted list. `card` rows are show_ui cards under test.
final class GenUIRowModel {
    enum Kind { case header, text, card, footer }
    let id = UUID()
    let kind: Kind
    var text: String
    var card: GenUICardState
    var options: [String] = ["红色", "绿色", "蓝色"]
    /// Production block kind / tool status (a `.genuiTool` `.success` block is
    /// the only one the commit method may consume).
    /// Two lists of one session may hold DIFFERENT AssistantBlock instances
    /// for the SAME block UUID.
    var blockId: UUID?
    var blockKind: CollectionViewMessageListV3.BlockKind = .genuiTool
    var toolStatus: CollectionViewMessageListV3.ToolStatus = .success
    init(kind: Kind, text: String = "", card: GenUICardState = GenUICardState(), blockId: UUID? = nil) {
        self.kind = kind
        self.text = text
        self.card = card
        self.blockId = blockId
    }
    var item: MessageListItem {
        switch kind {
        case .header: return .assistantHeader(id)
        case .card: return .assistantBlock(blockId ?? id, blockId ?? id)
        case .text, .footer: return .wholeMessage(id)
        }
    }
}

/// MessageListLayout with two observation hooks: how many times the commit
/// asked UIKit to invalidate, and every height the layout ever published per
/// row (proves the old real height never drops to the coarse estimate).
final class GenUITrackedLayout: MessageListLayout {
    var invalidateCount = 0
    var heightSamples: [Int: [CGFloat]] = [:]
    var trackCount = 0
    private var recording = false

    override func invalidateLayout() {
        invalidateCount += 1
        super.invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard !recording, trackCount > 0 else { return }
        recording = true
        defer { recording = false }
        for index in 0..<trackCount {
            if let a = layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
                heightSamples[index, default: []].append(a.frame.height)
            }
        }
    }

    var observedCount: Int { heightSamples.values.reduce(0) { $0 + $1.count } }
}

final class GenUIListHarness {
    /// A deliberately wrong coarse estimate, far from every real height: if a
    /// commit ever drops the row to it, the assertions see the number.
    static let coarseEstimate: CGFloat = 777
    static let precalcEstimate: CGFloat = 555

    let rows: [GenUIRowModel]
    let targetIndex: Int
    let sessionId: String?
    let layout = GenUITrackedLayout()
    private let testWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    private(set) var collection: NoAnimationCollectionView!
    private(set) var controller: CollectionViewMessageListV3.GenUIListViewController!
    let coordinator = CollectionViewMessageListV3.Coordinator()
    /// The model blocks behind `coordinator.snapshotMessages` — the same
    /// objects production's `assistantBlock(id:)` returns (the card writes
    /// `genuiStateJSON` on this block, not on a copy).
    private(set) var cardBlocks: [UUID: CollectionViewMessageListV3.AssistantBlock] = [:]
    /// Incremented ONLY through `applyConfiguration`, i.e. only when the
    /// production `configureCell` runs inside `commitGenUIStateChange`. The
    /// data source dequeues directly, so this counts real transaction
    /// consumptions — a store fallback leaves it untouched.
    private(set) var productionConfigureCount = 0
    /// Production installs this subscription inside its snapshot-apply path
    /// (MessageListV3Coordinator+Snapshot.swift, `if genuiStateSub == nil {…}`),
    /// which drags in the whole chat screen and is not compiled here. The
    /// fixture wires the SAME one-line sink (same publisher, same cast, same
    /// call, synchronous, no scheduler hop) so `MinisUIStore.update` reaches
    /// `commitGenUIStateChange`. Nothing else of the commit is re-implemented.
    private var genuiStateSub: AnyCancellable?
    private var preparingWidthBaseline = false
    private var previousWidthHeights: [Int: CGFloat] = [:]
    private(set) var widthReseedCount = 0

    init(rows: [GenUIRowModel], targetIndex: Int, sessionId: String? = "session-A") {
        self.rows = rows
        self.targetIndex = targetIndex
        self.sessionId = sessionId
        collection = NoAnimationCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 700),
                                               collectionViewLayout: layout)
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset = UIEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
        collection.register(SelfSizingCell.self, forCellWithReuseIdentifier: "cell")
        controller = CollectionViewMessageListV3.GenUIListViewController(collectionView: collection,
                                                                        messageListLayout: layout)
        coordinator.viewController = controller
        layout.onWidthCachesPurged = { [weak self] in self?.reseedAfterWidthPurge() }
        coordinator.nearBottom = true
        coordinator.applyConfiguration = { [weak self] cell, item, ip in
            guard let self else { return }
            self.productionConfigureCount += 1
            self.configure(cell, at: ip.item)
        }
        let ds = UICollectionViewDiffableDataSource<CollectionViewMessageListV3.Section, MessageListItem>(
            collectionView: collection) { [weak self] cv, ip, item in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "cell", for: ip) as! SelfSizingCell
                self?.configure(cell, at: ip.item)
                return cell
            }
        coordinator.dataSource = ds
        coordinator.vm = CollectionViewMessageListV3.GenUIViewModel(sessionId: sessionId)
        var blocks: [UUID: CollectionViewMessageListV3.AssistantBlock] = [:]
        var messages: [CollectionViewMessageListV3.GenUIMessage] = []
        for (index, row) in rows.enumerated() {
            let b = block(at: index)
            blocks[row.id] = b
            messages.append(CollectionViewMessageListV3.GenUIMessage(id: row.id, blocks: [b]))
        }
        cardBlocks = blocks
        coordinator.snapshotMessages = messages
        coordinator.vm?.messages = coordinator.snapshotMessages
        // The production snapshot path suppresses offset compensation while
        // constructing the initial list, then restores its captured viewport.
        // Our fixture must establish the same LEGAL resting baseline before
        // asserting that a later card interaction never moves that viewport.
        coordinator.isFlushing = true
        layout.suppressContentOffsetAdjustment = true
        layout.trackCount = rows.count
        var snap = NSDiffableDataSourceSnapshot<CollectionViewMessageListV3.Section, MessageListItem>()
        snap.appendSections([0])
        snap.appendItems(rows.map { $0.item }, toSection: 0)
        ds.apply(snap, animatingDifferences: false)
        genuiStateSub = NotificationCenter.default.publisher(for: MinisUIStore.stateChanged)
            .sink { [weak self] notification in
                guard let change = notification.object as? MinisUIStateUpdate else { return }
                self?.coordinator.commitGenUIStateChange(change)
            }
        controller.view.frame = collection.frame
        testWindow.rootViewController = controller
        testWindow.makeKeyAndVisible()
        testWindow.layoutIfNeeded()
        collection.layoutIfNeeded()
        warmUp()
        scrollToTop()
        layout.suppressContentOffsetAdjustment = false
        coordinator.isFlushing = false
    }

    deinit { testWindow.isHidden = true }

    // MARK: model

    func block(at index: Int) -> CollectionViewMessageListV3.AssistantBlock {
        let row = rows[index]
        let block = CollectionViewMessageListV3.AssistantBlock(id: row.blockId ?? row.id, kind: row.blockKind,
                                                              toolStatus: row.toolStatus)
        block.genuiStateJSON = row.card.json
        return block
    }

    // MARK: cells

    func contentKey(for index: Int) -> String {
        let row = rows[index]
        switch row.kind {
        case .card: return "genui:\(row.id.uuidString):\(row.card.contentHash)"
        default: return "row:\(row.id.uuidString)"
        }
    }

    func configureContent(_ cell: SelfSizingCell, at index: Int) {
        let row = rows[index]
        cell.rendersNonEmptyText = row.kind != .card
        cell.contentKey = contentKey(for: index)
        layout.setContentKey(cell.contentKey!, at: index)
        if !preparingWidthBaseline {
            layout.setEstimatedHeight(GenUIListHarness.coarseEstimate, at: index)
            layout.setPrecalcHeight(GenUIListHarness.precalcEstimate, at: index)
        }
        switch row.kind {
        case .card:
            // The card renders the BLOCK's state, exactly like SwiftUI observing
            // the model block (two lists = two block instances, one UUID).
            var state = (cardBlocks[row.id]?.genuiStateJSON).flatMap(GenUICardState.init(json:)) ?? row.card
            // `long` is fixture-only (never part of the card's JSON state).
            state.long = row.card.long
            let options = row.options
            cell.applyContentConfiguration(UIHostingConfiguration {
                GenUICardFixture(state: state, options: options)
            })
        default:
            let text = row.text
            cell.applyContentConfiguration(UIHostingConfiguration {
                GenUIFillerRow(text: text)
            })
        }
    }

    func configure(_ cell: SelfSizingCell, at index: Int) {
        guard index < rows.count else { return }
        configureContent(cell, at: index)
    }

    // MARK: geometry

    var targetItem: MessageListItem { rows[targetIndex].item }
    var targetIndexPath: IndexPath { IndexPath(item: targetIndex, section: 0) }
    var targetCell: SelfSizingCell? { collection.cellForItem(at: targetIndexPath) as? SelfSizingCell }
    var offset: CGFloat { collection.contentOffset.y }
    var maxOffset: CGFloat {
        max(-collection.contentInset.top,
            layout.collectionViewContentSize.height - collection.bounds.height + collection.contentInset.bottom)
    }
    var contentHeight: CGFloat { layout.collectionViewContentSize.height }

    func rowHeight(_ index: Int) -> CGFloat {
        layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height ?? -1
    }
    func topOf(_ index: Int) -> CGFloat {
        guard let a = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return .nan }
        return a.frame.minY - collection.contentOffset.y
    }
    /// The real fitted height of the visible card, measured from the cell the
    /// same way the production commit does.
    func measuredCardHeight() -> CGFloat {
        guard let cell = targetCell,
              let attrs = layout.layoutAttributesForItem(at: targetIndexPath) else { return -1 }
        cell.clearCachedHeight()
        return cell.preferredLayoutAttributesFitting(attrs.copy() as! UICollectionViewLayoutAttributes).size.height
    }
    func estimatedHeightsPublished() -> [CGFloat] {
        layout.heightSamples[targetIndex] ?? []
    }

    // MARK: driving the real production path

    /// A card value change: exactly what `MinisUICardView.persist` does.
    func cardUpdate(session: String? = nil, blockId: UUID? = nil,
                    _ mutate: @escaping (GenUICardState) -> GenUICardState) {
        let row = rows[targetIndex]
        let after = mutate(row.card)
        let blocks = cardBlocks
        MinisUIStore.update(blockId: blockId ?? row.blockId ?? row.id, sessionId: session ?? sessionId,
                            state: { blocks[row.id]?.genuiStateJSON }) {
            row.card = after
            blocks[row.id]?.genuiStateJSON = after.json
        }
    }

    /// The state this list would render right now (from its own block).
    func cardStateFromBlock() -> GenUICardState? {
        cardBlocks[rows[targetIndex].id]?.genuiStateJSON.flatMap(GenUICardState.init(json:))
    }

    /// Production's queued control path: `MinisUIStore.enqueue` → re-read the
    /// LATEST state → touch only this control's key → `MinisUIStore.update`.
    func queuedCardChange(session: String? = nil,
                          _ mutate: @escaping (GenUICardState) -> GenUICardState) {
        let row = rows[targetIndex]
        let expected = session ?? sessionId
        MinisUIStore.enqueue { [weak self] in
            guard let self, self.coordinator.vm?.sessionId == expected else { return }
            let latest = self.cardStateFromBlock() ?? row.card
            let after = mutate(latest)
            MinisUIStore.update(blockId: row.blockId ?? row.id, sessionId: self.sessionId,
                                state: { self.cardBlocks[row.id]?.genuiStateJSON }) {
                self.rows[self.targetIndex].card = after
                self.cardBlocks[row.id]?.genuiStateJSON = after.json
            }
        }
    }

    /// Slider mid-drag: production writes the block's JSON directly inside a
    /// no-animation transaction, with NO list update and NO re-measure.
    func sliderLive(_ value: Double) {
        let row = rows[targetIndex]
        var after = row.card
        after.slider = value
        var noAnim = Transaction(animation: nil)
        noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            row.card = after
            cardBlocks[row.id]?.genuiStateJSON = after.json
        }
        // SwiftUI re-renders the card in place (new hosting content, same cell).
        if let cell = targetCell { configureContent(cell, at: targetIndex) }
    }

    /// Slider release: production force-commits the final live state.
    func sliderCommit() {
        let row = rows[targetIndex]
        let state = row.card
        let blocks = cardBlocks
        MinisUIStore.update(blockId: row.blockId ?? row.id, sessionId: sessionId,
                            state: { blocks[row.id]?.genuiStateJSON }) {
            row.card = state
            blocks[row.id]?.genuiStateJSON = state.json
        }
    }

    // MARK: pumping / scrolling

    func pump(_ seconds: Double) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            let slice = min(0.004, end.timeIntervalSinceNow)
            if slice <= 0 { break }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: slice))
            RunLoop.main.run(mode: .common, before: Date(timeIntervalSinceNow: 0.0005))
        }
    }

    func layoutNow() {
        collection.layoutIfNeeded()
        pump(0.02)
        collection.layoutIfNeeded()
    }

    /// Let SwiftUI deliver late filler heights before a baseline is taken.
    func warmUp(_ seconds: Double = 0.4) {
        collection.layoutIfNeeded()
        pump(seconds)
        collection.layoutIfNeeded()
        pump(0.05)
        collection.layoutIfNeeded()
    }

    /// Move the viewport so the card's top is above the visible area.
    func scrollPastCardTop(by delta: CGFloat = 140) {
        let cardMinY = layout.layoutAttributesForItem(at: targetIndexPath)?.frame.minY ?? offset
        let target = min(max(-collection.contentInset.top, cardMinY + delta), maxOffset)
        collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        collection.layoutIfNeeded()
        pump(0.05)
        collection.layoutIfNeeded()
    }

    func scrollToTop() {
        collection.setContentOffset(CGPoint(x: 0, y: -collection.contentInset.top), animated: false)
        collection.layoutIfNeeded()
        pump(0.05)
        collection.layoutIfNeeded()
    }

    /// Minimum equivalent of production's widthPurge-reseed snapshot pass:
    /// re-register keys and CHEAP ESTIMATES, never pretend an estimate is a real
    /// measurement or seed SelfSizingCell. The small filler rows use prior real
    /// heights as estimates; the card uses its normal program-style estimator.
    private func reseedAfterWidthPurge() {
        widthReseedCount += 1
        for i in rows.indices {
            layout.setContentKey(contentKey(for: i), at: i)
            let estimate: CGFloat
            if rows[i].kind == .card, let block = cardBlocks[rows[i].id] {
                estimate = MinisUITool.estimatedHeight(block, width: collection.bounds.width)
            } else {
                estimate = previousWidthHeights[i] ?? layout.estimatedItemHeight
            }
            layout.setEstimatedHeight(estimate, at: i)
        }
    }

    /// Establish a settled NEW-width baseline, then test an interaction at that
    /// width. Production also reseeds after its debounced width purge. Without
    /// that callback the old fixture fell to 200pt for every row and was still
    /// correcting those unrelated rows during the later card assertion.
    func resizeWidth(_ width: CGFloat) {
        previousWidthHeights = Dictionary(uniqueKeysWithValues: rows.indices.map { ($0, rowHeight($0)) })
        let oldSuppress = layout.suppressContentOffsetAdjustment
        let oldFlushing = coordinator.isFlushing
        layout.suppressContentOffsetAdjustment = true
        coordinator.isFlushing = true
        preparingWidthBaseline = true
        defer {
            preparingWidthBaseline = false
            layout.suppressContentOffsetAdjustment = oldSuppress
            coordinator.isFlushing = oldFlushing
        }
        collection.frame = CGRect(x: 0, y: 0, width: width, height: collection.bounds.height)
        controller.view.frame = collection.frame
        collection.layoutIfNeeded()
        pump(0.12) // Includes the real 33ms width purge + reseed callback.
        warmUp()
        scrollToTop()
        print("GENUI_WIDTH_RESEED count=\(widthReseedCount) offset=\(offset) heights=\(rows.indices.map { rowHeight($0) })")
    }

    /// Clamp legality: an offset may only move INTO the scrollable range.
    func isLegalOffset(_ y: CGFloat) -> Bool {
        y >= -collection.contentInset.top - 0.5 && y <= maxOffset + 0.5
    }
}
