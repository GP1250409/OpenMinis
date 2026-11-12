import UIKit
import SwiftUI

// These application declarations live outside the production coordinator.
// Preserve that lookup and notification name when compiling its extension.
typealias AssistantBlock = CollectionViewMessageListV3.AssistantBlock
extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
}

// Fixture-side services for the production genui commit. The commit method is
// NOT re-written here: `scripts/genui_height_regression.py` extracts every
// `extension CollectionViewMessageListV3.Coordinator { … }` block out of
// `MessageListV3Coordinator+GenUI.swift` verbatim into
// build/genui-height/GenUICoordinatorBlock.swift. This file only supplies the
// app members those methods read: a view controller owning a collection view
// and layout, the diffable data source, the view model / snapshot, cell
// configuration, the offset-suppression flags and the cell cache.
//
// If the production method reaches for a member that is not declared here,
// add it below — never re-implement the method.

enum CollectionViewMessageListV3 {
    typealias Section = Int

    /// Stand-in for `MessageListViewController` (drags in the whole chat
    /// screen). Only the two members the commit touches.
    final class GenUIListViewController: UIViewController {
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

    enum BlockKind { case genuiTool, tool, text }
    enum ToolStatus { case success, failure, running }

    /// One show_ui card as the commit sees it: identity, kind, tool status and
    /// the state JSON the card writes.
    final class AssistantBlock {
        let id: UUID
        var kind: BlockKind
        var toolStatus: ToolStatus
        var toolUseId: String?
        var genuiStateJSON: String?
        init(id: UUID, kind: BlockKind = .genuiTool, toolStatus: ToolStatus = .success,
             toolUseId: String? = nil) {
            self.id = id
            self.kind = kind
            self.toolStatus = toolStatus
            self.toolUseId = toolUseId
        }
    }

    final class GenUIMessage {
        let id: UUID
        var blocks: [AssistantBlock]
        init(id: UUID, blocks: [AssistantBlock]) { self.id = id; self.blocks = blocks }
    }

    final class GenUIViewModel {
        var sessionId: String?
        var messages: [GenUIMessage] = []
        var isProcessing = false
        func send(overrideText: String) {}
        func enqueuePrompt(silent: Bool, overrideText: String) {}
        init(sessionId: String? = nil) { self.sessionId = sessionId }
    }

    /// Small typed cache with the shapes a cell cache usually exposes, so a
    /// production `removeValue(forKey:)` / `removeAll()` compiles unchanged.
    final class GenUICellCache {
        private var map: [MessageListItem: SelfSizingCell] = [:]
        subscript(_ item: MessageListItem) -> SelfSizingCell? {
            get { map[item] }
            set { map[item] = newValue }
        }
        var count: Int { map.count }
        var isEmpty: Bool { map.isEmpty }
        func removeValue(forKey key: MessageListItem) { map.removeValue(forKey: key) }
        func removeAll() { map.removeAll() }
        func removeAllObjects() { map.removeAll() }
    }

    final class Coordinator {
        enum ScrollMode { case autoScrolling, userBrowsing }

        weak var viewController: GenUIListViewController?
        var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!
        var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // Same layout flag mirror as the real Coordinator.scrollMode.
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        var vm: GenUIViewModel?
        /// Snapshot messages the commit walks to match the row back to its
        /// model block (production: the same snapshot it renders from).
        var snapshotMessages: [GenUIMessage] = []
        /// Bumped by every snapshot apply (production owns it in
        /// MessageListV3Coordinator.swift); the async verify compares it so a
        /// stale validation cannot replay an old offset.
        var snapshotApplyGeneration = 0
        var suppressContentOffsetAdjustment = false
        var isFlushing = false
        var cellCache = GenUICellCache()
        var nearBottom = true

        /// Fixture hook: how the real `configureCell` builds a cell's hosting
        /// configuration. Set by the harness.
        var applyConfiguration: ((SelfSizingCell, MessageListItem, IndexPath) -> Void)?

        func isNearBottom() -> Bool { nearBottom }

        func configureCell(_ cell: SelfSizingCell, item: MessageListItem, indexPath: IndexPath) {
            applyConfiguration?(cell, item, indexPath)
        }

        func clearCellCache() { cellCache.removeAll() }

        /// Byte-identical with the production helper in
        /// MessageListV3Coordinator+ToolFolding.swift (not extracted here).
        func assistantBlock(id: UUID) -> AssistantBlock? {
            let messages = snapshotMessages.isEmpty ? (vm?.messages ?? []) : snapshotMessages
            for m in messages {
                if let b = m.blocks.first(where: { $0.id == id }) { return b }
            }
            return nil
        }
    }
}

/// Stub for `MinisUITool` (production: MinisUIView.swift, which drags in the
/// whole Minis UI Lang engine + Charts). Only the two queries the commit
/// method asks are reproduced — the same conditions production uses:
/// a rendered card is a `.genuiTool` block with a successful tool status and
/// a parsable program.
enum MinisUITool {
    static func renders(_ block: CollectionViewMessageListV3.AssistantBlock) -> Bool {
        guard block.kind == .genuiTool, block.genuiStateJSON != nil else { return false }
        if case .success = block.toolStatus { return true }
        return false
    }

    static func estimatedHeight(_ block: CollectionViewMessageListV3.AssistantBlock,
                                width: CGFloat) -> CGFloat {
        // Coarse production-style estimate: enough lines for the current state.
        let hasFeedback = (block.genuiStateJSON ?? "").contains("\"feedback\":\"\\\"") == false
        return hasFeedback ? 260 : 210
    }
}
