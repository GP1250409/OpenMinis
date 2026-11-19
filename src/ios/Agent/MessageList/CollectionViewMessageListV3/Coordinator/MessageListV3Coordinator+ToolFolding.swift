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
            /// [T-fold-live-process] All keys by which this run may have been
            /// tracked earlier in its live lifecycle.
            let matchKeys: [String]
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
            // [T-fold-two-switches] The two independent switches, read once per
            // plan: `live` folds the run still growing, `end` folds a run a
            // reply or card closed. Downstream passes them on unchanged, so the
            // chat list, the share export and the planner can never disagree.
            let settings = ToolFoldPlanner.FoldSettings.current
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
                                                          separators: vm.toolFoldSeparators,
                                                          liveFolding: settings.live)
                guard horizon > 0 else { continue }
                // [T-share-fold-tools] The same runs the share export folds.
                // [T-fold-stopped-tools] `ended` is the TASK's end, not the
                // plan's: only a message the loop is not writing into may fold a
                // run that has no reply after it. A running message whose
                // horizon stops on a tool must leave it open — those calls are
                // about to run.
                var folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)),
                                                        ended: !isRunning,
                                                        liveFolding: settings.live,
                                                        endFolding: settings.end)
                // [T-fold-two-switches] With "fold after the reply" off, a run a
                // reply closed is dropped from the plan — that IS the expansion
                // the user asked for once the reply lands. The one exception is
                // a run the user closed BY HAND: the manual close is theirs, so
                // the row stays (and stays closed) until they open it again or
                // the session changes. Planning it with `endFolding: true` finds
                // exactly the runs the automatic rule would have folded.
                if !settings.end {
                    let settled = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)),
                                                             ended: !isRunning,
                                                             liveFolding: settings.live,
                                                             endFolding: true)
                    let planned = Set(folded.map(\.firstBlockId))
                    folded += settled.filter { run in
                        !planned.contains(run.firstBlockId)
                            && run.matchKeys.contains(where: { toolGroupManuallyFolded.contains($0) })
                    }
                    folded.sort { $0.group.range.lowerBound < $1.group.range.lowerBound }
                }
                guard !folded.isEmpty else { continue }
                var runs: [ToolFoldRun] = []
                for run in folded {
                    let prevKey = toolFoldRunByFirstBlock[run.firstBlockId]?.key
                    let alreadyFolded = run.matchKeys.contains(where: { presentedToolGroupKeys.contains($0) })
                        || prevKey.map { presentedToolGroupKeys.contains($0) } == true
                    if ToolFoldPlanner.holdsBack(browsing: browsing,
                                                 alreadyFolded: alreadyFolded,
                                                 inRunningMessage: isRunning,
                                                 liveFolding: settings.live,
                                                 shownAsRows: { isShownUnfolded(message.id, run.firstBlockId) }) {
                        deferred = true
                        continue
                    }
                    runs.append(ToolFoldRun(messageId: message.id, key: run.key, matchKeys: run.matchKeys,
                                            firstBlockId: run.firstBlockId,
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

            let expanding = !(expandedToolGroups.contains(run.key)
                              || run.matchKeys.contains(where: { expandedToolGroups.contains($0) }))
            if expanding {
                expandedToolGroups.insert(run.key)
                // [T-fold-two-switches] Opening the row is a manual decision too:
                // it must not be closed again by the next automatic plan.
                for k in run.matchKeys { toolGroupManuallyFolded.remove(k) }
                toolGroupManuallyFolded.remove(run.key)
            } else {
                for k in run.matchKeys { expandedToolGroups.remove(k) }
                // [T-fold-two-switches] Remember the close across the turn end:
                // with "fold after the reply" off the plan drops this run once
                // its reply lands, and only this key brings the row back.
                toolGroupManuallyFolded.insert(run.key)
                for k in run.matchKeys { toolGroupManuallyFolded.insert(k) }
            }
            // Without this, a list pinned to the bottom keeps the bottom in
            // place and the newly opened calls push the row up and out of
            // sight — the tap would look like it did nothing.
            scrollMode = .userBrowsing

            // [T-toolgroup-accordion] Two writers may not own the viewport at
            // once. A system scroll-to-top flight started before this tap is
            // finished here (reason: this toggle, restoring=false) so its
            // per-frame offset writer cannot fight the reveal; the reverse
            // direction is in `beginStatusBarScrollToTop`, which cancels this
            // flight. Neither path changes the status-bar feature itself.
            if statusBarScrollToTop.isActive {
                // Same call shape as `.askToggle`: end the flight at the offset
                // the system animation had reached, let its resume pass thaw
                // self-sizing/streaming, and only then let the reveal write.
                _ = // `.superseded` is the existing reason for "another list writer owns
                // the viewport now"; the enum is deliberately NOT extended (the
                // status-bar gate enumerates its reasons).
                finishStatusBarScrollToTop(reason: .superseded, offset: cv.contentOffset.y)
                log.info("[ToolFold][Accordion] took the viewport from a status-bar flight")
            }

            // [T-toolgroup-accordion] A second tap while the run is still
            // moving flips it in place: the frozen heights are still valid
            // because the rows never left the snapshot, so this is a direction
            // change from the CURRENT reveal, not a restart (no flash, no
            // re-measure, no structural churn).
            if let flight = toolGroupAccordionFlight, flight.isRunning,
               let live = flight.currentPlan, live.headerIndex == oldIdx,
               ds.snapshot().itemIdentifiers.firstIndex(of: item) == oldIdx {
                flight.retarget(expanding ? .expand : .collapse)
                log.info("[ToolFold][Accordion] retarget group=\(firstBlockId.uuidString.prefix(8)) direction=\(expanding ? "expand" : "collapse") reveal=\(String(format: "%.3f", flight.reveal))")
                return
            }
            // One flight at a time: another run's flight is dropped (geometry
            // settles exactly, no callback — this tap owns the list now).
            if let other = toolGroupAccordionFlight {
                toolGroupAccordionFlight = nil
                other.cancel()
            }

            let memberIndices: ([MessageListItem]) -> [Int] = { items in
                var out: [Int] = []
                for id in run.memberIds {
                    guard let k = items.firstIndex(of: .assistantBlock(run.messageId, id)) else { return [] }
                    out.append(k)
                }
                return out
            }
            // Reduce motion: the terminal geometry, one frame, no intermediate
            // state at all (the legacy instant switch below, unchanged).
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            // [T-toolgroup-accordion] While a turn streams, the list is re-applied
            // continuously; an animation started here would be cut short by the
            // next update, so the run switches instantly instead of "animating"
            // for one frame. Semantic: unchanged, only the presentation.
            if vm.streamingUIUpdatesSuspended {
                log.info("[ToolFold][Accordion] fallback=streaming group=\(firstBlockId.uuidString.prefix(8))")
                legacyInstantToolGroupToggle(item: item, run: run, firstBlockId: firstBlockId,
                                             expanding: expanding, oldIdx: oldIdx, anchorY: anchorY,
                                             cv: cv, layout: layout, ds: ds, log: log)
                return
            }
            if reduceMotion {
                legacyInstantToolGroupToggle(item: item, run: run, firstBlockId: firstBlockId,
                                             expanding: expanding, oldIdx: oldIdx, anchorY: anchorY,
                                             cv: cv, layout: layout, ds: ds, log: log)
                return
            }

            if expanding {
                // The member rows have to exist before they can be revealed.
                // This is the same structural apply the list always did; the
                // rows are then frozen and pulled back to reveal 0 inside this
                // same turn, before anything is drawn.
                applySnapshot(messages: vm.messages, caller: "toolGroupToggle")
                UIView.performWithoutAnimation { cv.layoutIfNeeded() }
            }
            let items = ds.snapshot().itemIdentifiers
            guard let headerIdx = items.firstIndex(of: item) else {
                log.warning("[ToolFold][Accordion] header MISS group=\(firstBlockId.uuidString.prefix(8))")
                return
            }
            let idxs = memberIndices(items)
            let contiguous = !idxs.isEmpty
                && idxs.count == run.memberIds.count
                && idxs == Array(idxs[0]...(idxs[0] + idxs.count - 1))
                && idxs[0] > headerIdx
            guard contiguous else {
                // A run whose member rows are not one contiguous span right
                // below its header (an interleaved row the plan drew between
                // them) cannot be revealed as a window: keep the old instant
                // switch rather than animate the wrong rows.
                log.info("[ToolFold][Accordion] fallback=non-contiguous group=\(firstBlockId.uuidString.prefix(8)) members=\(idxs.count)/\(run.memberIds.count)")
                legacyInstantToolGroupToggle(item: item, run: run, firstBlockId: firstBlockId,
                                             expanding: expanding, oldIdx: oldIdx, anchorY: anchorY,
                                             cv: cv, layout: layout, ds: ds, log: log)
                return
            }
            // [T-toolgroup-accordion] Freeze MEASURED natural heights. A cached
            // height is not necessarily what the row really needs (a freshly
            // inserted block only has an estimate), and revealing a row to a
            // guessed height makes the frontier land in the wrong place. Rows
            // that are on screen are measured through the production
            // self-sizing channel; off-screen rows keep the layout's current
            // height (they cannot be seen during this flight) and are corrected
            // by the ordinary self-sizing pass afterwards.
            let spanItems = ds.snapshot().itemIdentifiers
            let offScreen = idxs.filter { cv.cellForItem(at: IndexPath(item: $0, section: 0)) == nil }
            let hosted = measureMemberRowsOffScreen(offScreen, items: spanItems, cv: cv, layout: layout)
            var heights: [CGFloat] = []
            heights.reserveCapacity(idxs.count)
            var measuredCount = 0
            var estimatedCount = 0
            for idx in idxs {
                let ip = IndexPath(item: idx, section: 0)
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                    let attrs = layout.layoutAttributesForItem(at: ip)
                        ?? UICollectionViewLayoutAttributes(forCellWith: ip)
                    let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                    if fitted > 0.5 {
                        layout.setMeasuredHeight(fitted, at: idx)
                        heights.append(fitted)
                        measuredCount += 1
                        continue
                    }
                }
                if let cached = layout.cachedHeight(at: idx) {
                    // A cached height is only trusted when a cell really reported
                    // it; precalc/estimated entries never land in heightCache.
                    heights.append(cached)
                    measuredCount += 1
                    continue
                }
                if let value = hosted[idx] {
                    heights.append(value)
                    measuredCount += 1
                    continue
                }
                heights.append(layout.naturalHeightForAccordion(at: idx))
                estimatedCount += 1
            }
            log.info("[ToolFold][Accordion] natural measured=\(measuredCount) estimated=\(estimatedCount) of \(idxs.count)")
            // [T-toolgroup-accordion] A member row WITHOUT a real measurement
            // cannot be revealed to the right height: its estimate would be
            // replaced by the true value when the span clears, which moves
            // every row below it at the very end of the flight ("pops"). Only
            // a fully measured run may animate; otherwise the run switches
            // instantly (the pre-accordion behaviour) - correct, just not
            // animated, and never wrong geometry.
            guard estimatedCount == 0 else {
                log.info("[ToolFold][Accordion] fallback=unmeasured group=\(firstBlockId.uuidString.prefix(8)) estimated=\(estimatedCount)")
                legacyInstantToolGroupToggle(item: item, run: run, firstBlockId: firstBlockId,
                                             expanding: expanding, oldIdx: oldIdx, anchorY: anchorY,
                                             cv: cv, layout: layout, ds: ds, log: log)
                return
            }
            let span = idxs[0]...(idxs[0] + idxs.count - 1)
            let plan = ToolGroupAccordionFlight.Plan(memberRange: span, naturalHeights: heights,
                                                     headerIndex: headerIdx, anchorY: anchorY,
                                                     headerItem: item,
                                                     memberItems: run.memberIds.map { .assistantBlock(run.messageId, $0) })
            let flight = ToolGroupAccordionFlight(collectionView: cv, layout: layout)
            toolGroupAccordionFlight = flight
            // Published for the other viewport owner (status-bar flight); see
            // MessageListLayout.toolGroupAccordionAbort.
            // [T-toolgroup-accordion] Identity, not row counts: a row inserted
            // ABOVE the run, a swap to another session with the same row count,
            // or a replaced span row all keep the numbers valid while the
            // indices now point at the wrong rows. Every frame asks this before
            // it writes a reveal, and the driver retires itself when it fails.
            flight.liveItems = { [weak self] in self?.dataSource?.snapshot().itemIdentifiers }
            layout.toolGroupAccordionAbort = { [weak self] in
                guard let self, let running = self.toolGroupAccordionFlight else { return }
                self.toolGroupAccordionFlight = nil
                running.finish(.interrupted)
            }
            flight.start(plan, direction: expanding ? .expand : .collapse) { [weak self] outcome in
                guard let self, let vm = self.vm else { return }
                if self.toolGroupAccordionFlight === flight {
                    self.toolGroupAccordionFlight = nil
                    self.viewController?.messageListLayout?.toolGroupAccordionAbort = nil
                }
                // Exact restore: the structure now matches the business state
                // (a close drops its rows only here, with every member row
                // already at 0 height, so nothing moves on screen).
                self.applySnapshot(messages: vm.messages, caller: "toolGroupAccordionEnd")
                // [T-toolgroup-accordion][takeover] Only a flight that RAN TO
                // ITS END may put the tapped title back and re-arm the bottom
                // pin. `.interrupted` means a finger (or the status-bar flight)
                // owns the viewport: writing the old anchor here would yank the
                // list back under the drag, and `autoScrolling` would re-pin the
                // bottom the user just grabbed.
                switch outcome {
                case .completed, .instant:
                    self.restoreToolGroupToggleAnchor(item: item, anchorY: anchorY)
                case .interrupted, .cancelled:
                    break
                }
                log.info("[ToolFold][Accordion] end group=\(firstBlockId.uuidString.prefix(8)) outcome=\(outcome.rawValue) frames=\(flight.framesApplied) reveal=\(String(format: "%.3f", flight.reveal))")
            }
            log.info("[ToolFold] toggle group=\(firstBlockId.uuidString.prefix(8)) expanded=\(expanding) members=\(run.memberIds.count) idx=\(oldIdx)→\(headerIdx) span=\(span.lowerBound)...\(span.upperBound) anchorY=\(String(format: "%.1f", anchorY)) mode=accordion")
        }

        /// [T-toolgroup-accordion] Called immediately BEFORE a diffable apply is
        /// committed. The per-frame check alone is too late: UIKit can lay the
        /// old span out against the new items inside the apply itself. If the
        /// upcoming items no longer hold this flight's rows at its indices (a
        /// row inserted above, a session swap with the same count, a replaced
        /// span row), the span is cleared here — the animation stops, the rows
        /// are laid out normally, and nothing is clipped against the wrong row.
        /// Ordinary content updates keep the very same items, so they keep the
        /// animation.
        func cancelAccordionIfSpanBroken(beforeApplying items: [MessageListItem]) {
            guard let flight = toolGroupAccordionFlight, flight.isRunning else { return }
            guard !flight.planStillMatches(items) else { return }
            toolGroupAccordionFlight = nil
            viewController?.messageListLayout?.toolGroupAccordionAbort = nil
            flight.cancel()
            AppLogger(category: "ToolFold").info("[ToolFold][Accordion] cancel=preapply-broken-span rows=\(items.count)")
        }

        /// [T-toolgroup-accordion] Measure the member rows that are NOT on screen.
        ///
        /// NOT through `ds.collectionView(_:cellForItemAt:)`: that calls
        /// `dequeueConfiguredReusableCell` outside a UIKit request cycle, which
        /// iOS 18+ can trap ("Expected dequeued view to be returned to
        /// collection view"). Instead a private measuring collection view (alpha
        /// 0, user interaction off, its own MessageListLayout, added to the same
        /// window) is driven by UIKit normally; each row is configured with the
        /// SAME production `configureCell(_:item:indexPath:)`, never a copy of
        /// it. The user's viewport is not touched.
        private final class AccordionMeasureHost: NSObject, UICollectionViewDataSource {
            var items: [MessageListItem] = []
            var make: ((UICollectionView, IndexPath, MessageListItem) -> UICollectionViewCell)?
            func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
            func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                make?(view, indexPath, items[indexPath.item]) ?? UICollectionViewCell()
            }
        }

        private func measureMemberRowsOffScreen(_ idxs: [Int], items: [MessageListItem],
                                                cv: UICollectionView,
                                                layout: MessageListLayout) -> [Int: CGFloat] {
            guard let window = cv.window, cv.bounds.width > 0, !idxs.isEmpty else { return [:] }
            let mcv = UICollectionView(frame: .zero, collectionViewLayout: MessageListLayout())
            mcv.isUserInteractionEnabled = false
            mcv.isScrollEnabled = false
            mcv.alpha = 0
            let host = AccordionMeasureHost()
            host.items = idxs.map { items[$0] }
            host.make = { [weak self] v, ip, item in
                let cell = SelfSizingCell()
                self?.configureCell(cell, item: item, indexPath: ip)
                return cell
            }
            mcv.dataSource = host
            let estimated = idxs.reduce(CGFloat(0)) { $0 + layout.naturalHeightForAccordion(at: $1) }
            mcv.frame = CGRect(x: 0, y: 0, width: cv.bounds.width, height: max(400, estimated + 40))
            window.addSubview(mcv)
            mcv.layoutIfNeeded()
            var out: [Int: CGFloat] = [:]
            for (k, idx) in idxs.enumerated() {
                let ip = IndexPath(item: k, section: 0)
                guard let cell = mcv.cellForItem(at: ip) as? SelfSizingCell else { continue }
                let attrs = UICollectionViewLayoutAttributes(forCellWith: ip)
                attrs.size = CGSize(width: mcv.bounds.width, height: cell.bounds.height)
                let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
                if fitted > 0.5 {
                    layout.setMeasuredHeight(fitted, at: idx)
                    out[idx] = fitted
                }
            }
            mcv.removeFromSuperview()
            mcv.dataSource = nil
            return out
        }

        /// [T-toolgroup-accordion] The pre-accordion switch, kept verbatim for
        /// the two cases that must not animate: reduce motion, and a run whose
        /// member rows are not a contiguous span. Same calls in the same order
        /// as before, so its behaviour (and its regression evidence) is
        /// unchanged.
        private func legacyInstantToolGroupToggle(item: MessageListItem, run: ToolFoldRun, firstBlockId: UUID,
                                                  expanding: Bool, oldIdx: Int, anchorY: CGFloat,
                                                  cv: UICollectionView,
                                                  layout: MessageListLayout,
                                                  ds: UICollectionViewDiffableDataSource<Section, MessageListItem>,
                                                  log: AppLogger) {
            guard let vm else { return }
            // [T-toolgroup-accordion] Unconditional, exactly like the original
            // implementation: on a CLOSE this apply is what drops the member
            // rows, so gating it on `expanding` left the business state
            // (expandedToolGroups says closed) out of sync with the snapshot.
            applySnapshot(messages: vm.messages, caller: "toolGroupToggle")
            guard let idx = ds.snapshot().indexOfItem(item) else { return }
            let ip = IndexPath(item: idx, section: 0)
            (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
            layout.invalidateHeight(at: idx)
            var snap = ds.snapshot()
            snap.reconfigureItems([item])
            UIView.performWithoutAnimation {
                (cv as? NoAnimationCollectionView)?.isApplyingSnapshot = true
                ds.apply(snap, animatingDifferences: false)
                (cv as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            }
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            restoreToolGroupToggleAnchor(item: item, anchorY: anchorY)
            log.info("[ToolFold] toggle group=\(firstBlockId.uuidString.prefix(8)) expanded=\(expanding) members=\(run.memberIds.count) idx=\(oldIdx)→\(idx) anchorY=\(String(format: "%.1f", anchorY)) mode=instant")
        }

        /// Put the tapped row back at `anchorY` on screen, inside the legal
        /// offset window. Shared by the instant path and the accordion's end.
        private func restoreToolGroupToggleAnchor(item: MessageListItem, anchorY: CGFloat) {
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource,
                  let idx = ds.snapshot().indexOfItem(item) else { return }
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            if let newMinY = cv.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))?.frame.minY {
                let minOff = -cv.adjustedContentInset.top
                let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                let target = min(max(newMinY - anchorY, minOff), maxOff)
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
                }
            }
            if isNearBottom() { scrollMode = .autoScrolling }
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
        func remeasureKeepingTop(item: MessageListItem, index indexIn: Int, blockId: UUID,
                                         request: ToggleRequest? = nil) {
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let ds = dataSource else {
                request?.run()
                return
            }
            let log = AppLogger(category: "ThinkingCollapse")
            // [T-user-ask-anchor-flight] A system status-bar flight owns the
            // viewport until it ends. This toggle is fresh user intent and MUST
            // move the card, so it takes ownership instead of writing offsets
            // underneath a running system animation: end the flight first (its
            // resume pass thaws self-sizing, pays the deferred correction debt
            // and only then puts the offset back where the animation left it),
            // and read the row's frame AFTER that settles.
            if statusBarScrollToTop.isActive {
                finishStatusBarScrollToTop(reason: .askToggle, offset: cv.contentOffset.y)
                _ = layout.abandonTopAnchor()
            }
            // [T-user-ask-anchor-pending] `finish` does NOT finish the resume:
            // `resumeAfterStatusBarScrollToTop` only QUEUES a deferred streaming
            // snapshot (`DispatchQueue.main.async` -> `flushPendingSnapshotIfNeeded`)
            // when the flight suspended streaming UI updates. Landing it one
            // turn later is exactly the wrong moment: a `flushPending` apply
            // with unchanged items goes through `remeasureVisibleCells`, which
            // calls `layout.invalidateHeight(at:)` for EVERY visible row - i.e.
            // it drops the height this toggle just installed for THIS row and
            // reconfigures its cell while the 0.2s height animation is running.
            // `verifyToggledHeight` would then probe a height the flush itself
            // manufactured, and write the offset with the screen anchor read
            // against the pre-flush list.
            //
            // So consume what the flight deferred HERE, before this row is read,
            // measured and anchored: the same snapshot work, one turn earlier,
            // against a world this toggle then owns. It is skipped while a
            // snapshot apply is already running (re-entrancy) and while a
            // session is loading (`applySnapshot` returns early there, and
            // `flushPendingSnapshotIfNeeded` has already cleared the flag -
            // that would silently drop the deferred update).
            if hasPendingSnapshot, !isFlushing, vm?.isLoadingSession != true {
                log.info("[ThinkingCollapse] ASK-PENDING consume deferred snapshot before measuring block=\(blockId.uuidString.prefix(8)) flight=\(statusBarScrollToTop.isActive ? 1 : 0)")
                flushPendingSnapshotIfNeeded(caller: "askToggle-beforeMeasure")
            }
            // [T-user-ask-anchor-pending] The flush may have inserted/removed
            // rows above this one, so the row's index is read from the data
            // source, never taken from the caller's snapshot of it. A row that
            // is gone cannot be measured - run the one-shot request anyway so
            // the state the user tapped for is not lost.
            guard let row = ds.snapshot().itemIdentifiers.firstIndex(of: item) else {
                _ = request?.run()
                return
            }
            let i = row
            let ip = IndexPath(item: i, section: 0)
            let oldFrame = cv.layoutAttributesForItem(at: ip)?.frame
            let anchorY = (oldFrame?.minY ?? cv.contentOffset.y) - cv.contentOffset.y
            let oldHeight = oldFrame?.height ?? 0
            // [T-user-ask-expand-anim] Reduce Motion: the same single pass,
            // just without animation.
            let duration = ToggleAnchorMath.animationDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)

            scrollMode = .userBrowsing
            // [T-user-ask-anchor-token] The anchor is token-owned: a late
            // callback from an earlier tap (the 0.6s release, a stale verify
            // chain) must not release the anchor a NEWER tap is holding.
            let anchorToken = layout.beginTopAnchor(index: i)
            var newFrame: CGRect?
            var reveal: CGFloat = 0
            /// Where the row's top ended up on screen after this pass; the
            /// verify chain restores THIS, never a mid-animation re-read.
            var settledAnchorY = anchorY
            /// Whether the pass had to move the page (legal clamp) - logged and
            /// handed to the verify chain so a later correction does not try to
            /// re-hold a top that the content size cannot support.
            var anchorClamped = false
            // The finger owns the position: a toggle that lands during a drag
            // or a glide resizes the row and leaves the offset alone (UIKit
            // keeps a decelerating list in range by itself).
            let userHoldsOffset = cv.isTracking || cv.isDecelerating
            let minOff = -cv.adjustedContentInset.top
            let oldMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom

            // Everything that changes what is on screen happens in this one
            // pass, in one runloop turn: the content switches state AND the
            // cell gets its new height before the next frame is drawn. The
            // flicker came from the two landing a frame apart (content first,
            // size a runloop later through the async notification hop), with
            // the content centred in the stale cell for that frame.
            let changes = {
                guard let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                      let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes
                else {
                    _ = request?.run()
                    // Cell not on screen: the old re-measure path.
                    (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateHeight(at: i)
                    var snap = ds.snapshot()
                    snap.reconfigureItems([item])
                    ds.apply(snap, animatingDifferences: false)
                    layout.invalidateLayout()
                    cv.layoutIfNeeded()
                    return
                }

                // ---- 1. measure with the NEW state, without touching layout ----
                // [T-user-ask-expand-clip] The card's content switches and is
                // measured with NO animation (UIKit or Core Animation): it lands
                // in its final layout at once, pinned to the top of the cell, and
                // the cell's clipping bounds are what animates.
                // [T-user-ask-expand-overlap] Flip the state AND hand the cell a
                // fresh hosting configuration in the same step, then measure:
                // measuring right after the flip alone returned the OLD height
                // (the hosting view only picks the new state up on its next
                // update), and that stale height became the cell's cache - the
                // opened card then overlapped the text above it.
                // [T-user-ask-expand-ghost] No SwiftUI animation here either: the
                // height animation is the UIKit pass around this block.
                // [T-user-ask-history-seed] Drop this row's cached and memoized
                // height BEFORE configureCell (the memo is keyed by content, not
                // by expanded state, so configureCell would seed the height
                // measured for the OLD state).
                var fittedHeight: CGFloat = 0
                UIView.performWithoutAnimation {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    var noAnim = Transaction(animation: nil)
                    noAnim.disablesAnimations = true
                    withTransaction(noAnim) {
                        _ = request?.run()
                        layout.invalidateHeight(at: i)
                        self.configureCell(cell, item: item, indexPath: ip)
                    }
                    // The hosting view applies a new root view on its next update;
                    // run that update now so the measure sees the new state rather
                    // than the previous render (device log: measured heights lagged
                    // one tap behind without this).
                    cell.contentView.setNeedsLayout()
                    cell.contentView.layoutIfNeeded()
                    cell.clearCachedHeight()
                    fittedHeight = cell.preferredLayoutAttributesFitting(attrs).size.height
                    CATransaction.commit()
                }

                // ---- 2. put the offset where it must be BEFORE the height ----
                // [T-user-ask-anchor-preclamp] The row still has its OLD height,
                // so the scroll range is still the old one and the offset we
                // need after the resize is legal right now. Writing it here is
                // what keeps UIScrollView from discovering the clamp inside its
                // own layout pass - that clamp is applied with animations
                // disabled and is the ONE-FRAME page shift in the user
                // recording (a single frame moved 103px; the two animated moves
                // beside it were smooth).
                //
                // The movement itself is unavoidable when the content becomes
                // shorter than the range allows (a card above a collapsed tool
                // group, list at the bottom): the plan below says so out loud
                // (`clampedToBottom`) instead of pretending the top can be
                // held. What must not happen is a snap.
                if !userHoldsOffset, fittedHeight.isFinite, fittedHeight > 1 {
                    let predictedMax = ToggleAnchorMath.predictedMaxOffset(
                        currentMaxOffset: oldMaxOff, heightDelta: fittedHeight - oldHeight)
                    let pre = ToggleAnchorMath.preResizeOffset(
                        idealOffset: cv.contentOffset.y, predictedMaxOffset: predictedMax, minOffset: minOff)
                    if abs(pre - cv.contentOffset.y) > 0.5 {
                        cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: pre)
                    }
                }

                // ---- 3. install the height and lay out ----
                UIView.performWithoutAnimation {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if fittedHeight.isFinite, fittedHeight > 1 {
                        layout.setMeasuredHeight(fittedHeight, at: i)
                    }
                    CATransaction.commit()
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

                // ---- 4. settle the offset inside the NEW legal range ----
                let newMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                var plan = ToggleAnchorMath.cardAnchorPlan(newMinY: frame.minY, anchorY: anchorY,
                                                           minOffset: minOff, maxOffset: newMaxOff)
                var target = plan.offset
                if frame.height > oldHeight + 0.5, !userHoldsOffset {
                    let visibleTop = target + cv.adjustedContentInset.top
                    let visibleBottom = target + cv.bounds.height - cv.adjustedContentInset.bottom
                    reveal = ToggleAnchorMath.revealShift(cellMinY: frame.minY, cellMaxY: frame.maxY,
                                                          visibleTop: visibleTop, visibleBottom: visibleBottom)
                    reveal = min(reveal, max(0, max(minOff, newMaxOff) - target))
                    target += reveal
                }
                if !userHoldsOffset, abs(target - cv.contentOffset.y) > 0.5 {
                    cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: target)
                }
                anchorClamped = plan.isClamped
                settledAnchorY = frame.minY - cv.contentOffset.y
            }
            let finish = { [weak self, weak layout] in
                guard let self else { return }
                // [T-user-ask-expand-verify] Settled: check the height once more.
                // [T-user-ask-anchor-token] The chain carries THIS toggle's token
                // and the screen position the row's top actually ended at: a
                // correction must never re-anchor to a fresh `frame.minY -
                // contentOffset` read, because inside the 0.2s animation the
                // model offset already holds the final value while the rows are
                // still moving - that read produced the "one nudge too far"
                // corrections. A newer tap invalidates this chain by token.
                self.verifyToggledHeight(blockId: blockId, attempt: 0,
                                         anchorY: settledAnchorY, token: anchorToken)
                // [T-user-ask-anchor-clamp] Follow again only when the user is
                // not holding the list. A clamped collapse already sits exactly
                // on the legal bottom, so this pin is an idempotent write, not a
                // second scroll.
                if !cv.isTracking, !cv.isDecelerating, self.isNearBottom() {
                    self.scrollMode = .autoScrolling
                }
                // Keep the anchor through the next runloop turns: a late
                // SwiftUI re-measure of the same cell must not take the
                // visible-cell compensation either. Token-guarded, so this can
                // no longer clear a newer tap's anchor.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    layout?.endTopAnchor(token: anchorToken)
                }
            }
            // [T-user-ask-anchor-token] A toggle that lands while the finger is
            // down owns no anchor: the next turn must not probe (and cannot
            // move a held offset), so the token is released here instead of
            // being carried into the verify chain.
            if userHoldsOffset {
                layout.endTopAnchor(token: anchorToken)
            } else {
                // [T-user-ask-expand-verify] And on the next runloop turn, when
                // the hosting view has certainly applied the new state. The
                // completion and this hop are two entries for ONE token; the
                // layout hands the chain to the first of them only.
                DispatchQueue.main.async { [weak self] in
                    self?.verifyToggledHeight(blockId: blockId, attempt: 0,
                                              anchorY: settledAnchorY, token: anchorToken)
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
            log.info("[ThinkingCollapse] ANCHORED block=\(blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", oldHeight, newFrame?.height ?? -1)) anchorY=\(String(format: "%.1f", anchorY)) offset→\(String(format: "%.1f", cv.contentOffset.y)) reveal=\(String(format: "%.1f", reveal)) clamped=\(anchorClamped ? 1 : 0) token=\(anchorToken) animated=\(duration != nil) request=\(request != nil) drag=\(userHoldsOffset ? 1 : 0)")
            // [T-crash-breadcrumbs] Numbers only. A user toggle / end-of-stream
            // collapse, not a per-frame path.
            CrashBreadcrumbs.record("think.toggle",
                                    detail: "idx=\(i) h=\(Int(oldHeight))->\(Int(newFrame?.height ?? -1)) offset=\(Int(cv.contentOffset.y)) clamped=\(anchorClamped ? 1 : 0) animated=\(duration != nil ? 1 : 0)")
        }

        /// [T-user-ask-expand-verify] The in-pass measure of a toggled card can
        /// return the height of the state it just left (device crumbs: the
        /// first tap after a page show / return to foreground logged
        /// `think.toggle h=59->59` on an expand, the opened card drawn over the
        /// row below). Measure the visible cell again once things have settled
        /// and, if the list holds a different height, move to the real one with
        /// the card's top kept in place. Bounded retries; logs every fix.
        ///
        /// [T-user-ask-anchor-token] `anchorY` and `token` are captured by the
        /// toggle that started the chain. The chain stops as soon as a newer
        /// toggle owns the anchor, and a height that is still wrong is STILL
        /// corrected (a real content change must stay fixable) - it is only the
        /// authority to move the list that is token-scoped.
        func verifyToggledHeight(blockId: UUID, attempt: Int, anchorY: CGFloat, token: Int,
                                 continuation: Bool = false) {
            guard attempt < 3,
                  let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  layout.topAnchorOwned(by: token) else { return }
            // [T-user-ask-anchor-flight] Never probe - and never write the
            // offset - while the system status-bar animation owns the viewport:
            // the correction would land underneath a running animation and
            // re-anchor against a moving viewport. The chain is dropped; the
            // flight ends on its own and the next tap starts a fresh one.
            guard !statusBarScrollToTop.isActive, !layout.isSystemScrollToTopActive else {
                layout.endTopAnchor(token: token)
                layout.endVerifyChain(token: token)
                return
            }
            // [T-user-ask-anchor-token] One chain per token: the completion and
            // the next-runloop hop both arrive with attempt 0, only the first
            // gets the chain, so `attempt < 3` is a per-toggle budget.
            guard continuation || layout.beginVerifyChain(token: token) else { return }
            guard let snapshot = dataSource?.snapshot() else {
                layout.endVerifyChain(token: token); return
            }
            guard let i = snapshot.itemIdentifiers.firstIndex(where: {
                if case .assistantBlock(_, let bid) = $0 { return bid == blockId }
                return false
            }) else {
                // [T-user-ask-anchor-token] The row is GONE (session switch, tool
                // group fold, snapshot replace): the anchor must not stay parked
                // on a stale index. Release the token - a newer toggle owns its
                // own token, so this cannot clear one that is still live.
                layout.endTopAnchor(token: token)
                layout.endVerifyChain(token: token)
                return
            }
            let ip = IndexPath(item: i, section: 0)
            guard let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                  let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes
            else {
                // Not on screen: keep the chain open for the next attempt but do
                // not spend a height probe.
                DispatchQueue.main.async { [weak self] in
                    self?.verifyToggledHeight(blockId: blockId, attempt: attempt + 1,
                                              anchorY: anchorY, token: token, continuation: true)
                }
                return
            }
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            cell.clearCachedHeight()
            let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height
            let current = attrs.frame.height
            guard fitted.isFinite, fitted > 1, abs(fitted - current) > 0.5 else {
                layout.endVerifyChain(token: token); return
            }
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] VERIFY block=\(blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", current, fitted)) attempt=\(attempt) token=\(token)")
            CrashBreadcrumbs.record("think.verify", detail: "idx=\(i) h=\(Int(current))->\(Int(fitted)) n=\(attempt)")
            // The row may have been renumbered by a streaming flush above it.
            layout.retargetTopAnchor(token: token, index: i)
            let userHoldsOffset = cv.isTracking || cv.isDecelerating
            let duration = ToggleAnchorMath.animationDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            let apply = {
                layout.setMeasuredHeight(fitted, at: i)
                layout.invalidateLayout()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = duration != nil
                cv.layoutIfNeeded()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false
                guard let frame = cv.layoutAttributesForItem(at: ip)?.frame, !userHoldsOffset else { return }
                let minOff = -cv.adjustedContentInset.top
                let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                let target = ToggleAnchorMath.cardAnchorPlan(newMinY: frame.minY, anchorY: anchorY,
                                                             minOffset: minOff, maxOffset: maxOff).offset
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: target)
                }
            }
            let done = { [weak self] in
                if attempt + 1 >= 3 {
                    layout.endVerifyChain(token: token)
                    return
                }
                DispatchQueue.main.async {
                    self?.verifyToggledHeight(blockId: blockId, attempt: attempt + 1,
                                              anchorY: anchorY, token: token, continuation: true)
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
