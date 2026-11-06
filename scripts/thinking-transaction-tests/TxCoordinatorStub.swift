import UIKit
import SwiftUI

// These application declarations live outside the production coordinator.
// Preserve that lookup and notification name when compiling its extension.
typealias AssistantBlock = CollectionViewMessageListV3.AssistantBlock
extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
}

// Fixture-side services for the production coordinator transaction. The
// transaction methods themselves are NOT re-written here: the driver extracts
// `// MARK: - [T-thinking-toggle-txn]` … `func reconfigureAllCells()` from
// MessageListV3Coordinator+ToolFolding.swift verbatim into
// TxCoordinatorTxnBlock.swift, wrapped in `extension CollectionViewMessageListV3.Coordinator`.
// This file only supplies what those methods read from the app: a view
// controller holding a collection view + layout, a diffable data source, the
// scroll mode, `isNearBottom`, cell configuration and the transaction state.

enum CollectionViewMessageListV3 {
    typealias Section = Int

    /// Stand-in for `MessageListViewController` (which drags in the whole chat
    /// screen). Only the two members the transaction touches.
    final class TxListViewController: UIViewController {
        let collectionView: UICollectionView
        var messageListLayout: MessageListLayout!
        init(collectionView: UICollectionView, messageListLayout: MessageListLayout) {
            self.collectionView = collectionView
            self.messageListLayout = messageListLayout
            super.init(nibName: nil, bundle: nil)
            view.addSubview(collectionView)
        }
        required init?(coder: NSCoder) { fatalError("unused in tests") }
    }

    /// One thinking block as the transaction sees it: identity + the explicit
    /// manual target marker + the state the view renders.
    final class AssistantBlock {
        let id: UUID
        let thinking: Bool
        var pendingManualThinkingState: Bool?
        var pendingManualThinkingToken: UUID?
        /// Backed by the fixture row so the flip applied by `ToggleRequest` is
        /// visible to the transaction (production reads the model block).
        var readExpanded: () -> Bool = { false }
        var isThinkingExpanded: Bool {
            get { readExpanded() }
            set { _ = newValue }
        }
        init(id: UUID, thinking: Bool) { self.id = id; self.thinking = thinking }
    }

    final class TxMessage {
        let id: UUID
        var blocks: [AssistantBlock]
        init(id: UUID, blocks: [AssistantBlock]) { self.id = id; self.blocks = blocks }
    }

    final class TxViewModel {
        var messages: [TxMessage] = []
    }

    final class Coordinator {
        enum ScrollMode { case autoScrolling, userBrowsing }

        weak var viewController: TxListViewController?
        var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!
        var scrollMode: ScrollMode = .autoScrolling
        var thinkingToggleTxn: ThinkingToggleTxn?
        var thinkingToggleTokenSeq: Int = 0
        /// Snapshot messages the verifier walks when matching a row back to its
        /// model block (production: the same snapshot it re-renders from).
        var snapshotMessages: [TxMessage] = []
        var vm: TxViewModel?

        /// Fixture hook: how the real `configureCell` builds a cell's hosting
        /// configuration. Set by the harness.
        var applyConfiguration: ((SelfSizingCell, MessageListItem, IndexPath) -> Void)?
        /// Fixture: scroll position near the bottom (the production method
        /// reads scroll geometry).
        var nearBottom = true

        func isNearBottom() -> Bool { nearBottom }

        func configureCell(_ cell: SelfSizingCell, item: MessageListItem, indexPath: IndexPath) {
            applyConfiguration?(cell, item, indexPath)
        }
    }
}
