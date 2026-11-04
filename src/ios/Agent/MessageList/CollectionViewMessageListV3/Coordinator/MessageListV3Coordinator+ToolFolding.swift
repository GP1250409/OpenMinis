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
                let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)))
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
            // [MOD think-collapse-hold] Which way this tap goes. A COLLAPSE
            // must keep the opened body on screen while the cell's height
            // animates down: switching it off first leaves a cell that is
            // still 340pt tall holding only a 40pt header, and the rest shows
            // the black list background for the length of the animation
            // (device video 20:55:45: one all-black frame, then ghosts of the
            // rows below fading in). So a collapse measures the target height
            // WITHOUT flipping the state, animates the height, and flips the
            // state once the cell has reached it. An expand keeps the old
            // order (content first, then the height animation): the body
            // being revealed must already exist when the cell opens up.
            let isCollapse: Bool = {
                if case .assistantBlock(let mid, let bid) = item,
                   let mIdx = messageIndex[mid], mIdx < (vm?.messages.count ?? 0),
                   let b = vm?.messages[mIdx].blocks.first(where: { $0.id == bid }) {
                    return b.isThinkingExpanded
                }
                return false
            }()

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
                        if isCollapse {
                            // [MOD think-collapse-hold] The body stays up; only the
                            // height goes down, to the header's own height. The
                            // state flips in `finish`, once the cell has got there.
                            // The target is a constant (the collapsed block is its
                            // header, 39pt on device in every collapse of the
                            // 20:53-20:55 session), so no measure is needed - and
                            // none is wanted: a measure taken before the hosting
                            // view re-renders returns the OLD height.
                            // [MOD think-collapse-lock] The cell is self-sizing and
                            // still holds the tall body: without the lock it
                            // measures that and writes the tall height back (device
                            // crumbs 05:19: `think.toggle h=158->158` on every
                            // collapse, then a header over a black gap).
                            layout.heightLockedIndex = i
                            layout.invalidateHeight(at: i)
                            layout.setMeasuredHeight(Self.collapsedThinkingHeight, at: i)
                            cell.clearCachedHeight()
                        } else {
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
                            var fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                            // [MOD think-measure-lag] Some rows still answer with the
                            // height of the state they just left (device crumbs, idx=7:
                            // `think.toggle h=39->39`, then `verify 39->232`, every
                            // tap): the verify pass then ran a SECOND animation, which
                            // is the flash on those rows. An expand can only get
                            // taller, so an answer that is not taller than before is
                            // that lag: give the hosting view one more layout turn and
                            // measure again before the height is committed.
                            var retries = 0
                            while fitted <= oldHeight + 0.5 && retries < 3 {
                                retries += 1
                                self.configureCell(cell, item: item, indexPath: ip)
                                cell.contentView.setNeedsLayout()
                                cell.contentView.layoutIfNeeded()
                                cell.clearCachedHeight()
                                fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                            }
                            if retries > 0 {
                                CrashBreadcrumbs.record("think.remeasure",
                                                        detail: "idx=\(i) retries=\(retries) h=\(Int(fitted))")
                            }
                            layout.setMeasuredHeight(fitted, at: i)
                        }
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
                // [MOD think-collapse-hold] The cell is down to header height;
                // now drop the body. The visible part of the cell is the header
                // either way, so this lands without anything on screen moving.
                // The request runs through the same single-shot gate, so the
                // 0.15s fallback in the tap handler cannot flip it twice.
                if isCollapse {
                    var noAnim = Transaction(animation: nil)
                    noAnim.disablesAnimations = true
                    withTransaction(noAnim) {
                        UIView.performWithoutAnimation {
                            _ = request?.run()
                            self.reconfigureThinkingCell(item: item, index: i)
                        }
                    }
                    // [MOD think-collapse-lock2] The lock stays on. Device crumbs
                    // (7d75788, 09:27): `think.toggle h=340->39` then, 9ms later,
                    // `think.verify h=340->39` - the animation was cut short, and
                    // the moment the lock came off the hosting view (not yet
                    // re-rendered) measured the OLD 340pt body and wrote it back:
                    // the empty row sprang open, then verify animated it shut
                    // again over 0.2s. That is the flash. The collapsed height is
                    // known (set above), so there is nothing to verify. The
                    // lock is not held to a timer either: it is released once
                    // the cell's measured height converges on the collapsed
                    // one (releaseCollapseLockWhenSettled, below).
                } else {
                    // [T-user-ask-expand-verify] Settled: check the height once more.
                    self.verifyToggledHeight(blockId: blockId, attempt: 0)
                }
                if self.isNearBottom() { self.scrollMode = .autoScrolling }
                // Keep the anchor through the next runloop turns: a late
                // SwiftUI re-measure of the same cell must not take the
                // visible-cell compensation either.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if layout?.topAnchoredIndex == i { layout?.topAnchoredIndex = nil }
                }
                // [MOD think-collapse-lock3] Deterministic release, not a
                // timer: poll the cell's real fitted height and hand the row
                // back to self-sizing only once it has CONVERGED on the
                // collapsed height - i.e. the hosting view has really dropped
                // the body. 57cf040's flat 0.6s failsafe worked on device but
                // was a guess: unlock too early (host not re-rendered yet)
                // and the stale tall measure bounces the row open; too late
                // and the row stays frozen. Convergence makes it exact.
                if isCollapse {
                    self.releaseCollapseLockWhenSettled(blockId: blockId, originalIndex: i, attempt: 0)
                }
            }
            // [T-user-ask-expand-verify] And on the next runloop turn, when the
            // hosting view has certainly applied the new state.
            // [MOD think-collapse-hold] Not for a collapse: the body is still up
            // until the animation ends, so a measure now would read the OLD tall
            // height and "correct" the cell back up. `finish` verifies it.
            if !isCollapse {
                DispatchQueue.main.async { [weak self] in
                    self?.verifyToggledHeight(blockId: blockId, attempt: 0)
                }
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

        /// [MOD think-collapse-hold] Height of a collapsed thinking row: the
        /// header block (36pt capsule + 2x2pt wrapper padding). Device crumbs
        /// show the measured collapsed height as 39 on every collapse; the
        /// estimator uses 40. A wrong value here is corrected by the verify
        /// pass, so this only has to be close.
        static let collapsedThinkingHeight: CGFloat = 39

        /// Re-render one visible thinking cell with its current state, without
        /// touching its height (the caller has just set it).
        func reconfigureThinkingCell(item: MessageListItem, index i: Int) {
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let cell = cv.cellForItem(at: IndexPath(item: i, section: 0)) as? SelfSizingCell,
                  dataSource?.snapshot().indexOfItem(item) == i else { return }
            self.configureCell(cell, item: item, indexPath: IndexPath(item: i, section: 0))
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            layout.setMeasuredHeight(Self.collapsedThinkingHeight, at: i)
        }

        /// [MOD think-collapse-lock3] Release the collapse height lock only
        /// once the row's measured height has converged on the collapsed
        /// height - proof that the hosting view has really removed the body
        /// and a self-sizing pass would measure the header, not the stale
        /// 340pt body. Replaces 57cf040's flat 0.6s failsafe, which unlocked
        /// on a timer and hoped the host had re-rendered by then.
        /// - The block may have moved in the snapshot (insertions/deletions
        ///   above), so the index is re-resolved from the blockId each pass;
        ///   the lock travels with the index it was taken on, so a move also
        ///   means this toggle is over - unlock and bail.
        /// - If the user expands the block again before convergence, the
        ///   expand pass needs self-sizing back: unlock at once and let the
        ///   expand's own remeasure own the row.
        /// - Bounded: ~0.6s (10 x 60ms) then an unconditional unlock; a row
        ///   is never left locked.
        func releaseCollapseLockWhenSettled(blockId: UUID, originalIndex: Int, attempt: Int) {
            guard attempt < 10,
                  let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let snapshot = dataSource?.snapshot(),
                  let i = snapshot.itemIdentifiers.firstIndex(where: {
                      if case .assistantBlock(_, let bid) = $0 { return bid == blockId }
                      return false
                  }) else {
                // Gone from the list (compact/share/etc.) - nothing to guard.
                if let layout = viewController?.collectionView?.collectionViewLayout
                    as? MessageListLayout, layout.heightLockedIndex == originalIndex {
                    layout.heightLockedIndex = nil
                }
                return
            }
            // The toggle is over if the row moved, or the lock is already
            // gone (a later expand pass may have taken the row over).
            guard i == originalIndex, layout.heightLockedIndex == i else {
                if layout.heightLockedIndex == originalIndex { layout.heightLockedIndex = nil }
                return
            }
            // Has the user expanded it again? The expand path's remeasure must
            // be allowed through - hand the row back at once.
            if case .assistantBlock(let mid, let bid) = snapshot.itemIdentifiers[i],
               let mIdx = messageIndex[mid], mIdx < (vm?.messages.count ?? 0),
               let b = vm?.messages[mIdx].blocks.first(where: { $0.id == bid }),
               !b.isThinkingExpanded {
                layout.heightLockedIndex = nil
                CrashBreadcrumbs.record("think.unlock", detail: "idx=\(i) reason=reexpand n=\(attempt)")
                return
            }
            let ip = IndexPath(item: i, section: 0)
            guard let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                  let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes
            else {
                // Off-screen already: nothing visible to flash, safe to release.
                layout.heightLockedIndex = nil
                CrashBreadcrumbs.record("think.unlock", detail: "idx=\(i) reason=offscreen n=\(attempt)")
                return
            }
            // Measure WITHOUT the lock: this is the same self-sizing measure
            // `shouldInvalidateLayout` would take a moment later, but here it
            // is only a PROBE - the lock stays on until the answer is safe.
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            cell.clearCachedHeight()
            let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
            let target = Self.collapsedThinkingHeight
            if fitted.isFinite, fitted > 1, abs(fitted - target) <= 1 {
                // Converged: the cell now measures as its collapsed self.
                // Write the real measured height (not the constant) and hand
                // the row back to self-sizing.
                layout.setMeasuredHeight(fitted, at: i)
                layout.heightLockedIndex = nil
                CrashBreadcrumbs.record("think.unlock", detail: "idx=\(i) reason=converged h=\(Int(fitted)) n=\(attempt)")
                return
            }
            if attempt == 9 {
                // Last try: never leave a row locked. Keep the collapsed
                // constant rather than a stale tall measure.
                layout.setMeasuredHeight(target, at: i)
                layout.heightLockedIndex = nil
                CrashBreadcrumbs.record("think.unlock", detail: "idx=\(i) reason=timeout h=\(Int(fitted)) n=\(attempt)")
                return
            }
            CrashBreadcrumbs.record("think.probe", detail: "idx=\(i) h=\(Int(fitted)) n=\(attempt)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.releaseCollapseLockWhenSettled(blockId: blockId, originalIndex: i, attempt: attempt + 1)
            }
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
