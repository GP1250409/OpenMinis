//
//  ToolGroupOriginalToggle.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-toolgroup-original-toggle] The tool-group switch the chat list shipped
//  before the accordion (b54da95), kept as PRODUCTION code in one place:
//
//      structure apply -> instant reconfigure -> layoutIfNeeded ->
//      put the tapped row back at its screen anchor inside the legal window
//
//  There is deliberately no frame driver here. The accordion (0.32s frame-driven height
//  reveal, frozen member heights, span, direction flip, measurement probe,
//  deferred converge) was cancelled by user decision on 2026-11-20; this file is
//  the entry's whole toggle again, and `Support/ToolGroupAccordion*.swift` is no
//  longer reached from production.
//
//  Shared on purpose: the coordinator's `toggleToolGroup` and the UIKit harness
//  (`scripts/toolfold-uikit-tests/ToolGroupToggleEntryStage.swift`) run the SAME
//  `run(_:in:)`, so the regression evidence is about this code, not a look-alike.
//

import SwiftUI
import UIKit

enum ToolGroupOriginalToggle {

    /// What the list must do for the transaction. Each closure is one line in
    /// the coordinator (diffable data source) and one line in the harness.
    struct Environment {
        let collectionView: UICollectionView
        let layout: MessageListLayout
        /// The rows the list holds right now.
        var items: () -> [MessageListItem]
        /// The business apply: the folded run's member rows enter/leave.
        var applyStructure: (String) -> Void
        /// Index of the tapped row in the list's current items.
        var indexOf: (MessageListItem) -> Int?
        /// Re-render the tapped row with the state the business just flipped to.
        var reconfigure: (MessageListItem) -> Void
        var log: (String) -> Void = { _ in }
    }

    struct Request {
        let item: MessageListItem
        let memberItems: [MessageListItem]
        let expanding: Bool
        let oldIndex: Int
        /// The row's screen Y when the tap landed (frame.minY - contentOffset.y).
        let anchorY: CGFloat
        let groupTag: String
    }

    struct Result: Equatable {
        let fromIndex: Int
        let toIndex: Int
        let offset: CGFloat
        let moved: Bool
    }

    enum Outcome: Equatable {
        case applied(Result)
        /// The tapped row is not in the list (session swapped under the tap).
        case missing(String)
    }

    static func run(_ request: Request, in env: Environment) -> Outcome {
        let cv = env.collectionView
        let layout = env.layout

        // 1. The structure: exactly the caller's own apply, as before.
        env.applyStructure("toolGroupToggle")

        // 2. The row that carries the run. A missing row means the list was
        //    rebuilt under the tap; the business state is already correct, so
        //    nothing else is owed.
        guard let idx = env.indexOf(request.item) else {
            env.log("[ToolFold] toggle MISS group=\(request.groupTag) not in snapshot")
            return .missing("not-in-snapshot")
        }
        let ip = IndexPath(item: idx, section: 0)

        // 3. Full invalidation of the tapped row: the chevron and the content
        //    key changed, its height may have changed with them.
        (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
        layout.invalidateHeight(at: idx)
        env.reconfigure(request.item)
        layout.invalidateLayout()
        cv.layoutIfNeeded()

        // 4. Put the row back where it was on screen, inside the legal window
        //    (short content collapses to the top inset instead of scrolling).
        guard let newMinY = cv.layoutAttributesForItem(at: ip)?.frame.minY else {
            env.log("[ToolFold] toggle group=\(request.groupTag) expanded=\(request.expanding) members=\(request.memberItems.count) idx=\(request.oldIndex)→\(idx) geometry-missing")
            return .applied(Result(fromIndex: request.oldIndex, toIndex: idx,
                                   offset: cv.contentOffset.y, moved: false))
        }
        let minOff = -cv.adjustedContentInset.top
        let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
        let target = min(max(newMinY - request.anchorY, minOff), maxOff)
        var moved = false
        if abs(target - cv.contentOffset.y) > 0.5 {
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
            moved = true
        }
        env.log("[ToolFold] toggle group=\(request.groupTag) expanded=\(request.expanding) members=\(request.memberItems.count) idx=\(request.oldIndex)→\(idx) anchorY=\(String(format: "%.1f", request.anchorY)) target=\(String(format: "%.1f", target)) moved=\(moved)")
        return .applied(Result(fromIndex: request.oldIndex, toIndex: idx, offset: cv.contentOffset.y, moved: moved))
    }
}
