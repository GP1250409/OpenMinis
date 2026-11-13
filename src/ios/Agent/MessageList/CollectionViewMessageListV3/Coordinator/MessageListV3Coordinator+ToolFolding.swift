//
//  MessageListV3Coordinator+ToolFolding.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Tool-call folding [T-fold-consecutive-tools]: ToolFoldRun, the fold plan,
//  group toggle with anchored re-measure, and the reconfigure-all/visible
//  helpers that sat in this section.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ToolFolding" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // === Tool call folding [T-fold-consecutive-tools] ===
        /// One folded run of tool calls in the current snapshot.
        struct ToolFoldRun: Equatable {
            let messageId: UUID
            /// Expanded-state key: the first member's provider `toolUseId`,
            /// which survives a session reload (block ids are regenerated on
            /// every load); the block id when there is none.
            let key: String
            let firstBlockId: UUID
            /// [T-fold-lead-gap] The block this row is DRAWN at: the first
            /// member after the run's visible gaps.
            let anchorBlockId: UUID
            /// [T-fold-lead-gap] Members that keep their own row.
            let visibleIds: [UUID]
            let memberIds: [UUID]
            let group: ToolFoldPlanner.Group
            /// [T-fold-tool-duration] Summed execution time of the folded
            /// tool calls; nil when none of them recorded one.
            let duration: TimeInterval?
        }
        // MARK: - Tool call folding [T-fold-consecutive-tools]

        /// The runs of tool calls to fold in `messages` right now (see
        /// `ToolFoldPlanner` for the rule). Empty while the setting is off.
        ///
        /// [T-fold-at-request-end] WHEN: the message the agent loop is writing
        /// into (`vm.toolFoldRunningMessageId`) is planned only up to its fold
        /// horizon — the last block of the latest request that ended with a
        /// reply of at least 2 lines (`vm.toolFoldSeparators`). So nothing
        /// folds while a reply streams or a tool runs, and a run already folded
        /// cannot grow mid-task (blocks past the horizon are not planned). Every
        /// other message — a finished task, history — is planned whole, without
        /// the line rule.
        ///
        /// Folding swaps several rows for one. At the bottom that reads as the
        /// capsules above the reply closing up. While the user is scrolled up
        /// reading, though, removing rows would shift what they are looking
        /// at, so a run that has never been folded is held back (`deferred`)
        /// when it belongs to the running message OR its blocks are on the
        /// list right now as separate rows; it folds on the next plan after
        /// they return to the bottom. [T-fold-browse-hold] The second half
        /// covers the end of a task: every run of the finished message folds
        /// then, and one above the viewport used to pull the reply the user
        /// was reading up by its height (the list does not compensate rows
        /// removed above the viewport). A session just opened has never shown
        /// those rows (fresh block ids), so it still folds at once.
        func planToolFolds(messages: [ChatMessage])
            -> (runs: [UUID: [ToolFoldRun]], deferred: Bool) {
            guard ToolFoldPlanner.isEnabled, let vm else { return ([:], false) }
            let browsing = scrollMode == .userBrowsing
            let runningId = vm.toolFoldRunningMessageId
            var runsByMessage: [UUID: [ToolFoldRun]] = [:]
            var deferred = false
            // [T-fold-browse-hold] The rows on the list before this plan, built
            // only when a not-yet-folded run is met while browsing (never on
            // the common paths: not browsing, or every run already folded).
            var shownRows: Set<MessageListItem>?
            func isShownUnfolded(_ messageId: UUID, _ blockId: UUID) -> Bool {
                if shownRows == nil { shownRows = Set(previousSnapshotIds) }
                return shownRows?.contains(.assistantBlock(messageId, blockId)) ?? false
            }
            for message in messages where message.role == .assistant {
                let isRunning = message.id == runningId
                let horizon = ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningId,
                                                          separators: vm.toolFoldSeparators)
                guard horizon > 0 else { continue }
                // [T-share-fold-tools] The same runs the share export folds.
                // [T-fold-stopped-tools] `ended` is the TASK's end, not the
                // plan's: only a message the loop is not writing into may fold a
                // run that has no reply after it. A running message whose
                // horizon stops on a tool must leave it open — those calls are
                // about to run.
                let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)),
                                                        ended: !isRunning)
                guard !folded.isEmpty else { continue }
                var runs: [ToolFoldRun] = []
                for run in folded {
                    if ToolFoldPlanner.holdsBack(browsing: browsing,
                                                 alreadyFolded: presentedToolGroupKeys.contains(run.key),
                                                 inRunningMessage: isRunning,
                                                 shownAsRows: { isShownUnfolded(message.id, run.firstBlockId) }) {
                        deferred = true
                        continue
                    }
                    runs.append(ToolFoldRun(messageId: message.id, key: run.key, firstBlockId: run.firstBlockId,
                                            anchorBlockId: run.anchorBlockId, visibleIds: run.visibleIds,
                                            memberIds: run.memberIds, group: run.group,
                                            duration: run.duration))
                }
                if !runs.isEmpty { runsByMessage[message.id] = runs }
            }
            return (runsByMessage, deferred)
        }

        #if DEBUG
        /// [T-scroll-jitter-fold-diag] Scroll state for diagnostics events:
        /// mode, finger down (trk), decelerating (dec).
        func scrollStateTag(_ cv: UICollectionView) -> String {
            (scrollMode == .autoScrolling ? "auto" : "browse")
                + (cv.isTracking ? "+trk" : "") + (cv.isDecelerating ? "+dec" : "")
        }
        #endif

        /// Re-apply the snapshot if the fold plan no longer matches the list.
        ///
        /// Folding depends on things that do not otherwise re-snapshot: a
        /// request ending with a long-enough reply, the turn ending, the user
        /// returning to the bottom ([T-fold-at-request-end]). Comparing plans
        /// first keeps these triggers free when nothing would change.
        func resnapshotIfToolFoldsChanged(caller: String) {
            guard let vm, !vm.isLoadingSession else { return }
            let messages = vm.messages.filter { !$0.isInternalBridge }
            let planned = planToolFolds(messages: messages)
            #if DEBUG
            // [T-scroll-jitter-fold-diag] Every re-plan, including the ones that
            // change nothing or are held back while the user browses.
            if ScrollMetricsRecorder.shared.isEnabled, let cv = viewController?.collectionView {
                let outcome = planned.runs == toolFoldRunsByMessage ? "unchanged"
                    : (vm.streamingUIUpdatesSuspended ? "pending" : "apply")
                ScrollMetricsRecorder.shared.record(kind: "fold",
                    a: Double(toolFoldRunsByMessage.values.reduce(0) { $0 + $1.count }),
                    b: Double(planned.runs.values.reduce(0) { $0 + $1.count }),
                    pos: scrollStateTag(cv), offset: Double(cv.contentOffset.y),
                    note: "caller=\(caller) outcome=\(outcome) deferred=\(planned.deferred)")
            }
            #endif
            guard planned.runs != toolFoldRunsByMessage else {
                toolFoldDeferred = planned.deferred
                return
            }
            if vm.streamingUIUpdatesSuspended {
                hasPendingSnapshot = true
                return
            }
            AppLogger(category: "ToolFold").info("[ToolFold] re-plan caller=\(caller) runs=\(toolFoldRunByFirstBlock.count)→\(planned.runs.values.reduce(0) { $0 + $1.count })")
            applySnapshot(messages: vm.messages, caller: caller)
        }

        /// Open or close one folded run, keeping its row where it is on screen.
        ///
        /// Two changes happen at once. The run's blocks enter or leave the list
        /// (a structural apply), and the row itself re-renders — chevron, and a
        /// different content key — so it goes through the same full
        /// invalidation as a thinking block toggle ([T-thinking-collapse-blank]):
        /// clear the cell's own height cache, invalidate the layout's, then
        /// reconfigure, apply, and invalidate the layout.
        func toggleToolGroup(firstBlockId: UUID) {
            let log = AppLogger(category: "ToolFold")
            guard let vm, let run = toolFoldRunByFirstBlock[firstBlockId],
                  let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else {
                log.warning("[ToolFold] toggle MISS group=\(firstBlockId.uuidString.prefix(8))")
                return
            }
            let item = MessageListItem.toolGroup(run.messageId, firstBlockId)
            guard let oldIdx = ds.snapshot().indexOfItem(item) else {
                log.warning("[ToolFold] toggle MISS group=\(firstBlockId.uuidString.prefix(8)) not in snapshot")
                return
            }
            // Where the row sits in the viewport now, to put it back there.
            let oldIp = IndexPath(item: oldIdx, section: 0)
            let anchorY = (cv.layoutAttributesForItem(at: oldIp)?.frame.minY ?? cv.contentOffset.y) - cv.contentOffset.y

            let expanding = !expandedToolGroups.contains(run.key)
            if expanding {
                expandedToolGroups.insert(run.key)
            } else {
                expandedToolGroups.remove(run.key)
            }
            // Without this, a list pinned to the bottom keeps the bottom in
            // place and the newly opened calls push the row up and out of
            // sight — the tap would look like it did nothing.
            scrollMode = .userBrowsing

            applySnapshot(messages: vm.messages, caller: "toolGroupToggle")

            guard let idx = ds.snapshot().indexOfItem(item) else { return }
            let ip = IndexPath(item: idx, section: 0)
            (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
            layout.invalidateHeight(at: idx)
            var snap = ds.snapshot()
            snap.reconfigureItems([item])
            ds.apply(snap, animatingDifferences: false)
            layout.invalidateLayout()
            cv.layoutIfNeeded()

            if let newMinY = cv.layoutAttributesForItem(at: ip)?.frame.minY {
                let minOff = -cv.adjustedContentInset.top
                let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                let target = min(max(newMinY - anchorY, minOff), maxOff)
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
                }
            }
            if isNearBottom() { scrollMode = .autoScrolling }
            log.info("[ToolFold] toggle group=\(firstBlockId.uuidString.prefix(8)) expanded=\(expanding) members=\(run.memberIds.count) idx=\(oldIdx)→\(idx) anchorY=\(String(format: "%.1f", anchorY))")
        }

        /// [T-user-ask-toggle-drift] A cell the user tapped open or shut
        /// (an answered user_ask card) changes height in place: its top stays
        /// where it was on screen and only its bottom moves.
        ///
        /// The plain `.thinkingBlockToggled` path re-measures through the
        /// estimate - the collapse to it lands in prepare() with no offset
        /// change (top fixed), the growth back to the real height goes through
        /// the layout's visible-cell compensation (bottom fixed). An expand
        /// therefore grew upward and a collapse shrank downward, and each pair
        /// moved the list up by the cell's height change (user recording:
        /// -6pt on expand, -142pt on collapse, every cycle).
        ///
        /// Same shape as `toggleToolGroup`: a tap is reading, not following,
        /// so the bottom pin must not move the list; re-measure now, put the
        /// top back, then - after an expansion only - one short scroll so the
        /// opened content is visible without losing the top.
        func remeasureKeepingTop(item: MessageListItem, index i: Int, blockId: UUID,
                                         request: ToggleRequest? = nil) {
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let ds = dataSource else {
                request?.run()
                return
            }
            let log = AppLogger(category: "ThinkingCollapse")
            let ip = IndexPath(item: i, section: 0)
            let oldFrame = cv.layoutAttributesForItem(at: ip)?.frame
            let anchorY = (oldFrame?.minY ?? cv.contentOffset.y) - cv.contentOffset.y
            let oldHeight = oldFrame?.height ?? 0
            // [T-user-ask-expand-anim] Reduce Motion: the same single pass,
            // just without animation.
            let duration = ToggleAnchorMath.animationDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)

            scrollMode = .userBrowsing
            layout.topAnchoredIndex = i
            var newFrame: CGRect?
            var reveal: CGFloat = 0

            // Everything that changes what is on screen happens in this one
            // pass, in one runloop turn: the content switches state AND the
            // cell gets its new height before the next frame is drawn. The
            // flicker came from the two landing a frame apart (content first,
            // size a runloop later through the async notification hop), with
            // the content centred in the stale cell for that frame.
            let changes = {
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                   let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes {
                    // [T-user-ask-expand-clip] The card's content switches and is
                    // measured with NO animation (UIKit or Core Animation): it
                    // lands in its final layout at once, pinned to the top of the
                    // cell, and the cell's clipping bounds are what animates -
                    // the same reveal as the sidebar groups. Re-rendering the
                    // card inside the UIView.animate block cross-faded the old
                    // and new renders (recording: the header drawn twice ~10pt
                    // apart while the card faded).
                    UIView.performWithoutAnimation {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        // [T-user-ask-expand-overlap] Flip the state AND hand the
                        // cell a fresh hosting configuration in the same step, then
                        // measure. Measuring right after the flip alone returned the
                        // OLD height (the hosting view only picks the new state up
                        // on its next update): that stale height became the cell's
                        // cache, and while a message streams the cell serves its
                        // cache to every later pass - so a card opened under a
                        // streaming/thinking reply kept its collapsed height and
                        // overlapped the text above and the thinking row below.
                        // configureCell clears the cell's height cache; the fresh
                        // root view reads the new state, so the measure is real -
                        // and that correct height is what streaming passes reuse.
                        // [T-user-ask-expand-ghost] No SwiftUI animation here: the
                        // height animation is the UIKit pass around this block. A
                        // second, SwiftUI-driven animation on the same card moved
                        // and faded its header on its own clock (recording: the
                        // header drawn twice ~9pt apart, card half transparent).
                        var noAnim = Transaction(animation: nil)
                        noAnim.disablesAnimations = true
                        withTransaction(noAnim) {
                            _ = request?.run()
                            // [T-user-ask-history-seed] Drop this row's cached and
                            // memoized height BEFORE configureCell. The memo is keyed
                            // by content, not by expanded state, so configureCell
                            // would otherwise seed the height measured for the OLD
                            // state, and the seed makes the measure below return it
                            // without measuring (device log on a finished message:
                            // `[MemoSeed] … h=64.0` then `ANCHORED h=64.0→64.0`, the
                            // opened card overlapping its neighbours). Streaming
                            // messages are never seeded, which is why this only
                            // showed up in history. The new height is memoized by
                            // that measure, so scrolling back still skips it.
                            layout.invalidateHeight(at: i)
                            self.configureCell(cell, item: item, indexPath: ip)
                        }
                        // The hosting view applies a new root view on its next
                        // update; run that update now (a layout pass of the cell's
                        // content) so the measure below sees the new state rather
                        // than the previous render (device log: measured heights
                        // lagged one tap behind without this).
                        cell.contentView.setNeedsLayout()
                        cell.contentView.layoutIfNeeded()
                        cell.clearCachedHeight()
                        let fitted = cell.preferredLayoutAttributesFitting(attrs)
                        layout.setMeasuredHeight(fitted.size.height, at: i)
                        CATransaction.commit()
                    }
                } else {
                    _ = request?.run()
                    // Cell not on screen: the old re-measure path.
                    (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateHeight(at: i)
                    var snap = ds.snapshot()
                    snap.reconfigureItems([item])
                    ds.apply(snap, animatingDifferences: false)
                }
                layout.invalidateLayout()
                // The list strips UIKit animations from its layout passes
                // (NoAnimationCollectionView); let this one pass animate so the
                // rows around the card move with it instead of jumping.
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = duration != nil
                cv.layoutIfNeeded()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false

                guard let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return }
                newFrame = frame
                let minOff = -cv.adjustedContentInset.top
                let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                var target = ToggleAnchorMath.anchoredOffset(newMinY: frame.minY, anchorY: anchorY,
                                                             minOffset: minOff, maxOffset: maxOff)
                if frame.height > oldHeight + 0.5 {
                    let visibleTop = target + cv.adjustedContentInset.top
                    let visibleBottom = target + cv.bounds.height - cv.adjustedContentInset.bottom
                    reveal = ToggleAnchorMath.revealShift(cellMinY: frame.minY, cellMaxY: frame.maxY,
                                                          visibleTop: visibleTop, visibleBottom: visibleBottom)
                    reveal = min(reveal, max(0, max(minOff, maxOff) - target))
                    target += reveal
                }
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: target)
                }
            }
            let finish = { [weak self, weak layout] in
                guard let self else { return }
                // [T-user-ask-expand-verify] Settled: check the height once more.
                self.verifyToggledHeight(blockId: blockId, attempt: 0)
                if self.isNearBottom() { self.scrollMode = .autoScrolling }
                // Keep the anchor through the next runloop turns: a late
                // SwiftUI re-measure of the same cell must not take the
                // visible-cell compensation either.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if layout?.topAnchoredIndex == i { layout?.topAnchoredIndex = nil }
                }
            }
            // [T-user-ask-expand-verify] And on the next runloop turn, when the
            // hosting view has certainly applied the new state.
            DispatchQueue.main.async { [weak self] in
                self?.verifyToggledHeight(blockId: blockId, attempt: 0)
            }
            if let duration {
                // Short ease-out, no spring overshoot; a tap during the
                // animation starts from where things are on screen.
                UIView.animate(withDuration: duration, delay: 0,
                               options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                               animations: changes, completion: { _ in finish() })
            } else {
                changes()
                finish()
            }
            log.info("[ThinkingCollapse] ANCHORED block=\(blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", oldHeight, newFrame?.height ?? -1)) anchorY=\(String(format: "%.1f", anchorY)) offset→\(String(format: "%.1f", cv.contentOffset.y)) reveal=\(String(format: "%.1f", reveal)) animated=\(duration != nil) request=\(request != nil)")
            // [T-crash-breadcrumbs] Numbers only. A user toggle / end-of-stream
            // collapse, not a per-frame path.
            CrashBreadcrumbs.record("think.toggle",
                                    detail: "idx=\(i) h=\(Int(oldHeight))->\(Int(newFrame?.height ?? -1)) offset=\(Int(cv.contentOffset.y)) animated=\(duration != nil ? 1 : 0)")
        }

        /// [T-user-ask-expand-verify] The in-pass measure of a toggled card can
        /// return the height of the state it just left (device crumbs: the
        /// first tap after a page show / return to foreground logged
        /// `think.toggle h=59->59` on an expand, the opened card drawn over the
        /// row below). Measure the visible cell again once things have settled
        /// and, if the list holds a different height, move to the real one with
        /// the card's top kept in place. Bounded retries; logs every fix.
        func verifyToggledHeight(blockId: UUID, attempt: Int) {
            guard attempt < 3,
                  let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let snapshot = dataSource?.snapshot(),
                  let i = snapshot.itemIdentifiers.firstIndex(where: {
                      if case .assistantBlock(_, let bid) = $0 { return bid == blockId }
                      return false
                  }) else { return }
            let ip = IndexPath(item: i, section: 0)
            guard let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                  let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes
            else { return }
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            cell.clearCachedHeight()
            let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
            let current = attrs.frame.height
            guard fitted.isFinite, fitted > 1, abs(fitted - current) > 0.5 else { return }
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] VERIFY block=\(blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", current, fitted)) attempt=\(attempt)")
            CrashBreadcrumbs.record("think.verify", detail: "idx=\(i) h=\(Int(current))->\(Int(fitted)) n=\(attempt)")
            let anchorY = attrs.frame.minY - cv.contentOffset.y
            layout.topAnchoredIndex = i
            let duration = ToggleAnchorMath.animationDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            let apply = {
                layout.setMeasuredHeight(fitted, at: i)
                layout.invalidateLayout()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = duration != nil
                cv.layoutIfNeeded()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false
                guard let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return }
                let minOff = -cv.adjustedContentInset.top
                let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                let target = ToggleAnchorMath.anchoredOffset(newMinY: frame.minY, anchorY: anchorY,
                                                             minOffset: minOff, maxOffset: maxOff)
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: target)
                }
            }
            let done = { [weak self, weak layout] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if layout?.topAnchoredIndex == i { layout?.topAnchoredIndex = nil }
                }
                DispatchQueue.main.async {
                    self?.verifyToggledHeight(blockId: blockId, attempt: attempt + 1)
                }
            }
            if duration != nil {
                UIView.animate(withDuration: 0.2, delay: 0,
                               options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                               animations: apply, completion: { _ in done() })
            } else {
                apply()
                done()
            }
        }

        // MARK: - [T-thinking-toggle-txn] Manual thinking-row open / close

        /// [T-thinking-toggle-txn] The live block behind an `.assistantBlock`
        /// item. The transaction reads the model for two things the collection
        /// view cannot answer: the state it must end in, and whether SwiftUI has
        /// consumed the flip yet (the receipt that the new state has been
        /// rendered at all).
        func assistantBlock(id: UUID) -> AssistantBlock? {
            let messages = snapshotMessages.isEmpty ? (vm?.messages ?? []) : snapshotMessages
            for m in messages {
                if let b = m.blocks.first(where: { $0.id == id }) { return b }
            }
            return nil
        }

        /// One MANUAL open / close of a thinking row: the state change and the
        /// new cell height land in a single NO-ANIMATION pass, and the row's top
        /// stays where the user tapped it.
        ///
        /// What this replaces, and why it drifted: the tap used to flip
        /// `isThinkingExpanded` inside SwiftUI, whose `onChange` posted a plain
        /// `.thinkingBlockToggled`. That path drops the row to its ESTIMATE
        /// (`invalidateHeight` + `clearCachedHeight` + reconfigure) and only
        /// later self-sizes to the real height. Estimate and real height are not
        /// symmetric between states, so the drop and the recovery compensated
        /// differently — expand grew the row upward, collapse shrank it
        /// downward, and every pair moved the list by the height change. The
        /// late SwiftUI measure then re-anchored a target offset computed for
        /// the *pre-change* height, which a second re-measure could never undo.
        ///
        /// No animation on purpose: the historical flicker came from content and
        /// cell size landing a frame apart, and from animated passes measuring
        /// the state they were leaving.
        func thinkingToggleAnchored(blockId: UUID, item: MessageListItem, index i: Int,
                                    request: ToggleRequest?) {
            let log = AppLogger(category: "ThinkingCollapse")
            let block = assistantBlock(id: blockId)
            // The state this transaction must end in is read AFTER the request
            // ran (below): the request flips whatever is current at that moment
            // and records it as the marker. Nothing is frozen at tap time.
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let ds = dataSource else {
                // No list mounted (debug preview, sheet, torn-down list): the row
                // must still open/close — run the handed-off flip and ask for the
                // plain re-measure. Same shape as the card path.
                let ran = request?.run() ?? false
                if ran {
                    NotificationCenter.default.post(name: .thinkingBlockToggled, object: blockId)
                }
                log.info("[ThinkingCollapse] TXN-NOLIST block=\(blockId.uuidString.prefix(8)) ran=\(ran)")
                return
            }
            // Supersede the previous transaction (rapid taps): its token stops
            // being current, so no late closure of it can re-anchor the list or
            // replay the state it was started for.
            if let old = thinkingToggleTxn {
                layout.clearTxnAnchor(token: old.token)
            }
            let token = ThinkingToggleTxnMath.nextToken(after: thinkingToggleTokenSeq)
            thinkingToggleTokenSeq = token
            let ip = IndexPath(item: i, section: 0)
            let oldFrame = cv.layoutAttributesForItem(at: ip)?.frame
            let oldHeight = oldFrame?.height ?? 0
            let anchorY = (oldFrame?.minY ?? cv.contentOffset.y) - cv.contentOffset.y
            var txn = ThinkingToggleTxn(token: token, blockId: blockId, item: item,
                                        anchorY: anchorY, targetExpanded: false,
                                        didApply: false, appliedHeight: oldHeight,
                                        stableHits: 0, probes: 0, anchorIndex: i,
                                        probing: true, receiptSeen: false)
            thinkingToggleTxn = txn
            // A tap is reading, not following: the bottom pin must not move the
            // list (restored when the user is still at the bottom, on release).
            scrollMode = .userBrowsing
            layout.setTxnAnchor(token: token, index: i, blockId: blockId)

            // No SwiftUI animation either: a second animation clock on the same
            // card moved the header on its own (see the card path above).
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            var applied = false
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                   let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes {
                    withTransaction(noAnim) {
                        // The list owns the flip (one-shot request). configureCell
                        // then hands the cell a root view built from the NEW
                        // state; the measure below reads that, not the state it
                        // just left, and the fresh view also makes the plain
                        // re-measure path unnecessary.
                        applied = request?.run() ?? false
                        // Drop this row's cached AND memoized height BEFORE
                        // measuring: the memo is keyed by content, and a height
                        // measured for the other state must never be seeded back
                        // onto this one ([T-thinking-memo-key] keeps the expanded
                        // flag in the key; this drops the entry the re-measure
                        // would otherwise hit).
                        layout.invalidateHeight(at: i)
                        configureCell(cell, item: item, indexPath: ip)
                    }
                    // UIHostingConfiguration applies a new root view on its next
                    // update; run that update now, then measure.
                    cell.contentView.setNeedsLayout()
                    cell.contentView.layoutIfNeeded()
                    cell.clearCachedHeight()
                    let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                    if fitted.isFinite, fitted > 1 {
                        layout.setMeasuredHeight(fitted, at: i)
                        txn.appliedHeight = fitted
                    }
                } else {
                    applied = request?.run() ?? false
                    // Cell off screen: re-measure through the ordinary path, but
                    // keep the anchor parked so the row does not drift when it
                    // scrolls back in.
                    (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateHeight(at: i)
                    var snap = ds.snapshot()
                    snap.reconfigureItems([item])
                    ds.apply(snap, animatingDifferences: false)
                }
                txn.didApply = applied
                // Target from the model, now that the flip has happened.
                txn.targetExpanded = block?.pendingManualThinkingState
                    ?? block?.isThinkingExpanded ?? txn.targetExpanded
                thinkingToggleTxn = txn
                layout.invalidateLayout()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false
                cv.layoutIfNeeded()
                applyTxnAnchorOffset(cv: cv, layout: layout, ip: ip, anchorY: anchorY, token: token)
                CATransaction.commit()
            }

            log.info("[ThinkingCollapse] TXN block=\(blockId.uuidString.prefix(8)) idx=\(i) token=\(token) target=\(txn.targetExpanded) h=\(String(format: "%.1f→%.1f", oldHeight, txn.appliedHeight)) anchorY=\(String(format: "%.1f", anchorY)) offset=\(String(format: "%.1f", cv.contentOffset.y)) applied=\(applied) request=\(request != nil)")
            CrashBreadcrumbs.record("think.txn",
                                    detail: "idx=\(i) h=\(Int(oldHeight))->\(Int(txn.appliedHeight)) token=\(token) applied=\(applied ? 1 : 0)")

            // Verify AFTER a real frame: a burst of main-queue hops can all run
            // before SwiftUI draws, and would then measure the previous state
            // twice and call it settled. `probeFrameInterval` is one display
            // frame; the loop also refuses to settle until the model shows the
            // flip consumed (`pendingManualThinkingState` cleared by the view).
            scheduleThinkingToggleProbe(token: token, stableHits: 0)
        }

        /// Run the next probe one display frame later (never a tight async hop).
        private func scheduleThinkingToggleProbe(token: Int, stableHits: Int) {
            guard var txn = thinkingToggleTxn, txn.token == token, txn.probing else { return }
            if txn.probes >= ThinkingToggleTxnMath.maxProbes {
                txn.probing = false
                thinkingToggleTxn = txn
                CrashBreadcrumbs.record("think.txnstop", detail: "token=\(token) probes=\(txn.probes)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ThinkingToggleTxnMath.probeFrameInterval) { [weak self] in
                self?.verifyThinkingToggle(token: token, stableHits: stableHits)
            }
        }

        /// Put the row's top back at `anchorY`, clamped to the scrollable range.
        /// Never while the user is dragging or decelerating: their finger owns the
        /// offset, and a transaction must not pull it.
        private func applyTxnAnchorOffset(cv: UICollectionView, layout: MessageListLayout,
                                          ip: IndexPath, anchorY: CGFloat, token: Int) {
            guard ThinkingToggleTxnMath.isCurrent(token: token, currentToken: thinkingToggleTxn?.token),
                  let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return }
            guard !cv.isTracking, !cv.isDecelerating else { return }
            let minOff = -cv.adjustedContentInset.top
            let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let target = ToggleAnchorMath.anchoredOffset(newMinY: frame.minY, anchorY: anchorY,
                                                         minOffset: minOff, maxOffset: maxOff)
            if abs(target - cv.contentOffset.y) > 0.5 {
                cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
            }
        }

        /// [T-thinking-toggle-txn] Re-measure the toggled row until its height is
        /// the CURRENT state's, the model agrees, and two frame-spaced probes
        /// (with a render receipt in between) confirm it. The anchor is NOT
        /// released here: it stays parked until the user scrolls, the session
        /// changes, the row disappears, or a newer transaction takes over, so a
        /// late self-size correction can never start compensating again.
        ///
        /// Looked up by the transaction's stable identity (`.assistantBlock` item
        /// + block id) every round, never by the index captured at tap time:
        /// streaming growth above the row renumbers indices, cells are reused,
        /// and a session switch replaces the whole snapshot.
        func verifyThinkingToggle(token: Int, stableHits: Int) {
            guard let txn = thinkingToggleTxn, txn.token == token else { return }
            guard txn.probing else { return }
            guard ThinkingToggleTxnMath.isCurrent(token: token, currentToken: thinkingToggleTxn?.token) else { return }
            let log = AppLogger(category: "ThinkingCollapse")
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let snapshot = dataSource?.snapshot() else {
                releaseThinkingToggleTxn(token: token, reason: .listTornDown)
                return
            }
            guard case .assistantBlock(_, let bid) = txn.item, bid == txn.blockId,
                  let i = snapshot.itemIdentifiers.firstIndex(of: txn.item) else {
                // Row gone (session switch, message deleted, run folded away).
                releaseThinkingToggleTxn(token: token, reason: .rowGone)
                return
            }
            guard !cv.isTracking, !cv.isDecelerating else {
                releaseThinkingToggleTxn(token: token, reason: .userScroll)
                return
            }
            var t = txn
            t.anchorIndex = i
            // Count EVERY scheduled round, including off-screen/unmeasurable
            // rounds. Otherwise a row pushed off-screen polls at 60 Hz forever.
            t.probes += 1
            // The model is the only trustworthy witness that the state this
            // transaction installed is the one on screen. A different value means
            // a newer flip owns the row: stop, keep the anchor, do not fight it.
            let block = assistantBlock(id: txn.blockId)
            if txn.didApply, let block, block.isThinkingExpanded != txn.targetExpanded {
                thinkingToggleTxn = t
                log.info("[ThinkingCollapse] TXN-STALE block=\(txn.blockId.uuidString.prefix(8)) want=\(txn.targetExpanded) now=\(block.isThinkingExpanded)")
                releaseThinkingToggleTxn(token: token, reason: .superseded)
                return
            }
            // Render receipt: the view clears the marker when SwiftUI delivers
            // the flip. Until then the cell may still be drawing the old state,
            // and an identical measure proves nothing.
            let receipt = txn.receiptSeen || (block?.pendingManualThinkingState == nil)
            t.receiptSeen = receipt
            thinkingToggleTxn = t
            layout.setTxnAnchor(token: token, index: i, blockId: txn.blockId)
            guard let cell = cv.cellForItem(at: IndexPath(item: i, section: 0)) as? SelfSizingCell,
                  let attrs = layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.copy() as? UICollectionViewLayoutAttributes else {
                // Missing cells/attributes spend the same finite budget as a
                // measured round. Stop probing at the cap; keep only the anchor.
                if t.probes >= ThinkingToggleTxnMath.maxProbes {
                    t.probing = false
                    thinkingToggleTxn = t
                } else {
                    scheduleThinkingToggleProbe(token: token, stableHits: stableHits)
                }
                return
            }
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            cell.clearCachedHeight()
            let measured = cell.preferredLayoutAttributesFitting(attrs).size.height
            let current = attrs.frame.height
            let t2 = t
            thinkingToggleTxn = t2
            let verdict = ThinkingToggleTxnMath.probe(measured: measured, current: current,
                                                      stableHits: stableHits, probes: t2.probes - 1,
                                                      receipt: receipt && t2.didApply)

            switch verdict {
            case .settle:
                var done = t2
                done.probing = false
                thinkingToggleTxn = done
                // Anchor STAYS parked: a late correction must not compensate.
                layout.setTxnAnchor(token: token, index: i, blockId: txn.blockId)
                if isNearBottom() { scrollMode = .autoScrolling }
                log.info("[ThinkingCollapse] TXN-SETTLED block=\(txn.blockId.uuidString.prefix(8)) idx=\(i) token=\(token) h=\(String(format: "%.1f", current)) probes=\(t2.probes) (anchor kept)")

            case .waitReceipt, .confirm:
                scheduleThinkingToggleProbe(token: token, stableHits: verdict == .confirm ? stableHits + 1 : stableHits)

            case .fixHeight:
                // A late SwiftUI measure landed on a different height than the
                // one the transaction installed. Install the real one and keep
                // the row's CURRENT on-screen top — not the target offset the old
                // code compensated with.
                let topOnScreen = ThinkingToggleTxnMath.lateAnchorY(currentMinY: attrs.frame.minY,
                                                                   currentOffset: cv.contentOffset.y)
                layout.setTxnAnchor(token: token, index: i, blockId: txn.blockId)
                layout.setMeasuredHeight(measured, at: i)
                layout.invalidateLayout()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false
                cv.layoutIfNeeded()
                applyTxnAnchorOffset(cv: cv, layout: layout, ip: IndexPath(item: i, section: 0),
                                     anchorY: topOnScreen, token: token)
                log.info("[ThinkingCollapse] TXN-FIX block=\(txn.blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", current, measured)) probe=\(t2.probes) receipt=\(receipt)")
                CrashBreadcrumbs.record("think.txnfix",
                                        detail: "idx=\(i) h=\(Int(current))->\(Int(measured)) n=\(t2.probes)")
                scheduleThinkingToggleProbe(token: token, stableHits: 0)

            case .abandon:
                // Out of probes: stop measuring, but KEEP the anchor parked so a
                // late correction cannot drag the row. It is released by the user
                // scrolling, a session change, the row disappearing, or a newer
                // transaction.
                var done = t2
                done.probing = false
                thinkingToggleTxn = done
                layout.setTxnAnchor(token: token, index: i, blockId: txn.blockId)
                log.info("[ThinkingCollapse] TXN-ABANDON block=\(txn.blockId.uuidString.prefix(8)) idx=\(i) probe=\(t2.probes) receipt=\(receipt) (anchor kept)")
            }
        }

        /// Give the row back to the list: drop the token-owned anchor (only if
        /// this token still owns it) and restore the bottom pin if the user is
        /// still there. Never moves the offset.
        func releaseThinkingToggleTxn(token: Int, reason: ThinkingToggleTxnMath.ReleaseReason) {
            guard let txn = thinkingToggleTxn, txn.token == token else { return }
            thinkingToggleTxn = nil
            // Do not clear the model's manual marker here. SwiftUI may deliver
            // its onChange after this transaction ends; that callback must
            // still recognize the manual flip instead of posting the old path.
            // The next observed transition consumes it, or a new tap replaces it.
            viewController?.messageListLayout?.clearTxnAnchor(token: token)
            // Restore the bottom pin only when the user did NOT take over: a
            // drag leaves the list in `.userBrowsing` on purpose, and flipping
            // it back here would re-pin (and scroll) under the user's finger.
            if reason != .userScroll, isNearBottom() { scrollMode = .autoScrolling }
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] TXN-END block=\(txn.blockId.uuidString.prefix(8)) token=\(token) reason=\(reason.rawValue) probes=\(txn.probes)")
        }

        /// [T-thinking-toggle-txn] A structural apply renumbers rows. The anchor
        /// is moved in the SAME pass — waiting for the next probe would leave the
        /// token parked on an index that now belongs to another row, which is
        /// exactly the compensation skip this transaction must never apply to a
        /// bystander. Row gone -> release.
        func reconcileThinkingToggleTxn(items: [MessageListItem]) {
            guard let txn = thinkingToggleTxn, let layout = viewController?.messageListLayout else { return }
            guard items.indices.contains(txn.anchorIndex), items[txn.anchorIndex] != txn.item else {
                // Same slot: nothing moved (or the list rebuilt identically).
                if let i = items.firstIndex(of: txn.item) {
                    if i != txn.anchorIndex {
                        layout.clearTxnAnchor(token: txn.token)
                        layout.setTxnAnchor(token: txn.token, index: i, blockId: txn.blockId)
                        var t = txn
                        t.anchorIndex = i
                        thinkingToggleTxn = t
                    }
                } else {
                    releaseThinkingToggleTxn(token: txn.token, reason: .rowGone)
                }
                return
            }
            if let i = items.firstIndex(of: txn.item) {
                layout.clearTxnAnchor(token: txn.token)
                layout.setTxnAnchor(token: txn.token, index: i, blockId: txn.blockId)
                var t = txn
                t.anchorIndex = i
                thinkingToggleTxn = t
            } else {
                releaseThinkingToggleTxn(token: txn.token, reason: .rowGone)
            }
        }

        /// The user grabbed the list: an explicit takeover wins over keeping the
        /// row anchored. No offset change — the drag is never pulled.
        func releaseThinkingToggleOnUserScroll() {
            guard let txn = thinkingToggleTxn else { return }
            releaseThinkingToggleTxn(token: txn.token, reason: .userScroll)
        }

        /// Session change / list rebuild: the transaction's row cannot survive.
        func releaseThinkingToggleTxnForListChange() {
            guard let txn = thinkingToggleTxn else { return }
            releaseThinkingToggleTxn(token: txn.token, reason: .sessionChanged)
        }

        func reconfigureAllCells() {
            viewController?.messageListLayout?.clearHeightCache()
            // [T-ios-listsessions-perf] Not cleared: the font size is IN the
            // key, so the post-change measurements miss and re-measure while
            // the pre-change entries simply age out of the LRU. Clearing would
            // throw away every other session's still-valid heights to solve a
            // problem the key already solves.
            userBubbleHeightCache.removeAll()
            reconfigureVisibleCells()
        }

        /// Reconfigure all cells without clearing the height cache.
        /// Used after compact to update opacity without losing measured heights.
        func reconfigureVisibleCells() {
            var snapshot = dataSource.snapshot()
            let items = snapshot.itemIdentifiers
            guard !items.isEmpty else { return }
            snapshot.reconfigureItems(items)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
        }
}
