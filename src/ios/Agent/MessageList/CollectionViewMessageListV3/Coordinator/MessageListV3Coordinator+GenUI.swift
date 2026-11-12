//
//  MessageListV3Coordinator+GenUI.swift
//  Minis — Open UI value changes are NOT expand/collapse gestures.
//
import SwiftUI
import UIKit

extension CollectionViewMessageListV3.Coordinator {
    /// [MOD genui-height-txn] Content and size commit in the SAME no-animation
    /// pass. Keep real geometry until its replacement is measured; never run
    /// the answered-question animation/reveal or its delayed anchor callbacks.
    func commitGenUIStateChange(_ change: MinisUIStateUpdate) {
        guard Thread.isMainThread,
              let vm, vm.sessionId == change.sessionId,
              let cv = viewController?.collectionView, cv.window != nil,
              let layout = cv.collectionViewLayout as? MessageListLayout,
              let snapshot = dataSource?.snapshot(),
              let i = snapshot.itemIdentifiers.firstIndex(where: {
                  if case .assistantBlock(_, let bid) = $0 { return bid == change.blockId }
                  return false
              }),
              let block = assistantBlock(id: change.blockId), block.kind == .genuiTool,
              MinisUITool.renders(block) else { return }
        let item = snapshot.itemIdentifiers[i]
        // An interactive choice is reading, not following a streaming tail.
        // Also cancels pending coalesced bottom pins after this atomic pass.
        scrollMode = .userBrowsing
        let ip = IndexPath(item: i, section: 0)
        let oldOffset = cv.contentOffset
        let oldHeight = cv.layoutAttributesForItem(at: ip)?.size.height ?? layout.cachedHeight(at: i) ?? 0
        let wasFlushing = isFlushing
        let wasSuppressing = layout.suppressContentOffsetAdjustment
        isFlushing = true
        layout.suppressContentOffsetAdjustment = true
        defer {
            layout.suppressContentOffsetAdjustment = wasSuppressing
            isFlushing = wasFlushing
        }
        var noAnim = Transaction(animation: nil)
        noAnim.disablesAnimations = true
        var measured: CGFloat?
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            withTransaction(noAnim) {
                _ = change.request.run()
                // The write is one-shot, but EVERY mounted list must size the
                // final state, including lists with a separately loaded block.
                if let readState = change.state {
                    let after = readState()
                    if block.genuiStateJSON != after { block.genuiStateJSON = after }
                }
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                   let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes {
                    // A fresh root observes the just-committed values immediately.
                    // Unlike the old route, the layout's real height is NOT cleared
                    // before configuration (no estimate-sized intermediate frame).
                    self.configureCell(cell, item: item, indexPath: ip)
                    cell.contentView.setNeedsLayout()
                    cell.contentView.layoutIfNeeded()
                    // configureCell may seed a previously measured state; discard
                    // that seed too, so force-commit really checks the current view.
                    cell.clearInteractiveHeightCache()
                    let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                    guard fitted.isFinite, fitted > 1 else { return }
                    measured = fitted
                    layout.setInteractiveMeasuredHeight(fitted, at: i)
                    if abs(fitted - oldHeight) > 0.5 {
                        layout.invalidateLayout()
                        cv.layoutIfNeeded()
                        self.restoreGenUIOffset(oldOffset, in: cv)
                    }
                } else {
                    // A second view of the same session may be off screen. It
                    // must not keep the previous state's index cache on re-entry.
                    layout.invalidateHeight(at: i)
                    layout.clearPrecalcHeight(at: i)
                    layout.setEstimatedHeight(MinisUITool.estimatedHeight(block, width: cv.bounds.width), at: i)
                    layout.invalidateLayout()
                    cv.layoutIfNeeded()
                    self.restoreGenUIOffset(oldOffset, in: cv)
                }
            }
        }
        CrashBreadcrumbs.record("genui.commit", detail: String(format: "idx=%d h=%.0f->%.0f animated=0", i, oldHeight, measured ?? oldHeight))
        // One bounded validation after the hosting graph has consumed @Published.
        // No captured offset/anchor is replayed: rapid taps, scrolling, navigation
        // or a new snapshot make this check stale and it must do nothing.
        let expectedState = block.genuiStateJSON
        let generation = snapshotApplyGeneration
        DispatchQueue.main.async { [weak self, weak block] in
            guard let self, let block, block.genuiStateJSON == expectedState,
                  self.snapshotApplyGeneration == generation,
                  self.vm?.sessionId == change.sessionId else { return }
            self.verifyGenUIStateHeight(item: item, blockId: change.blockId)
        }
    }

    /// Preserve the CURRENT viewport, not the card's top and not the bottom.
    /// A card longer than the screen may have its top far above the viewport;
    /// revealing its bottom on every choice was the first-click upward jump.
    private func restoreGenUIOffset(_ offset: CGPoint, in cv: UICollectionView) {
        let minY = -cv.adjustedContentInset.top
        let maxY = max(minY, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
        let target = CGPoint(x: offset.x, y: min(maxY, max(minY, offset.y)))
        if abs(cv.contentOffset.y - target.y) > 0.5 { cv.contentOffset = target }
    }

    private func verifyGenUIStateHeight(item: MessageListItem, blockId: UUID) {
        guard let cv = viewController?.collectionView, cv.window != nil,
              !cv.isDragging, !cv.isDecelerating, !cv.isTracking,
              let layout = cv.collectionViewLayout as? MessageListLayout,
              let i = dataSource?.snapshot().itemIdentifiers.firstIndex(of: item),
              let cell = cv.cellForItem(at: IndexPath(item: i, section: 0)) as? SelfSizingCell,
              let attrs = layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.copy() as? UICollectionViewLayoutAttributes
        else { return }
        let offset = cv.contentOffset
        let wasFlushing = isFlushing
        let wasSuppressing = layout.suppressContentOffsetAdjustment
        isFlushing = true
        layout.suppressContentOffsetAdjustment = true
        defer {
            isFlushing = wasFlushing
            layout.suppressContentOffsetAdjustment = wasSuppressing
        }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            cell.clearInteractiveHeightCache()
            let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
            guard fitted.isFinite, fitted > 1 else { return }
            layout.setInteractiveMeasuredHeight(fitted, at: i)
            guard abs(fitted - attrs.size.height) > 0.5 else { return }
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            restoreGenUIOffset(offset, in: cv)
            CrashBreadcrumbs.record("genui.verify", detail: String(format: "idx=%d h=%.0f->%.0f animated=0", i, attrs.size.height, fitted))
        }
    }
}
