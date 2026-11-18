//
//  MessageListV3Coordinator+ScrollViewDelegate.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  UICollectionViewDataSourcePrefetching and UIScrollViewDelegate callbacks,
//  scroll-decel instrumentation, and the post-interaction settle pass.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ScrollViewDelegate" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - UICollectionViewDataSourcePrefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let vm, let layout = viewController?.messageListLayout else { return }
            // Items below come from previousSnapshotIds (snapshot-locked) — the
            // messages they're resolved against must be the SAME locked array,
            // or a concurrent loadSession() swap makes every lookup miss and
            // estimates collapse to the 44pt fallback. [T-ios-blocks-lost-render]
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth
            for indexPath in indexPaths {
                let index = indexPath.item
                // Skip if we already have a measured or precalculated height.
                // estimateItemHeight calls NSAttributedString.boundingRect which invokes
                // CoreText font shaping (GSUB lookups) — for complex markdown blocks this
                // can take hundreds of ms per cell and accumulate into a watchdog crash
                // when the user scrolls back through long history. See 3a9fb98 for the
                // matching configureCell guard.
                guard layout.cachedHeight(at: index) == nil,
                      !layout.hasPrecalcHeight(at: index) else { continue }
                guard index < previousSnapshotIds.count else { continue }
                let item = previousSnapshotIds[index]
                let est = Self.estimateItemHeight(item, messages: messages, width: width)
                layout.setEstimatedHeight(est, at: index)
            }
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][willBeginDragging] offset=\(String(format: "%.0f", scrollView.contentOffset.y)) contentSize=\(String(format: "%.0f", scrollView.contentSize.height)) visibleCells=\(viewController?.collectionView?.visibleCells.count ?? -1)")
            // [T-statusbar-native-scroll] A real drag interrupts the system
            // flight. Ownership is transferred, not restored: this method
            // suspends streaming and defers self-sizing immediately below, and
            // `settleAfterInteraction` flushes/restores both exactly once.
            finishStatusBarScrollToTop(reason: .drag, restoring: false)
            // [T-user-ask-anchor-flight] The finger takes the viewport: the
            // answered-question card's parked anchor and its probe chain must
            // not keep suppressing compensation or write an offset under the
            // drag (its own toggle already released the token when it landed
            // mid-drag; this covers a drag that STARTS inside the 0.6s hold).
            _ = viewController?.messageListLayout?.abandonTopAnchor()
            #if DEBUG
            // [DecelDisplayLink] Safety: if the user grabs again mid-decel, stop
            // the previous link so it doesn't keep ticking under the new gesture.
            stopDecelDisplayLink()
            #endif
            scrollMode = .userBrowsing
            // [T-scroll-bottom-native-animation] The touch that starts this drag
            // already aborted any in-flight jump animation, and UIKit does NOT
            // call `scrollViewDidEndScrollingAnimation` for an interrupted
            // animation — clear the flag here or every later pin (streaming
            // follow, coalesced scroll) would stay deferred.
            isAnimatingScrollToBottom = false
            scrollBottomRealigns = 0
            // [T-thinking-toggle-txn] A drag is an explicit takeover: hand the
            // toggled row back to the list (no offset is pulled — the finger
            // owns it), so the parked anchor cannot outlive the user's intent.
            releaseThinkingToggleOnUserScroll()
            // Cancel session-load clamp immediately — user has started interacting.
            clampAfterSessionLoad = false
            // A manual drag breaks the up-button's turn-walk chain: the next tap
            // should re-anchor to wherever the user landed, not continue the old
            // sequence.
            lastJumpedUserId = nil
            viewController?.messageListLayout?.deferSelfSizing = true
            vm?.setStreamingUIUpdatesSuspended(true)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // [ScrollDecel] Fires the instant the finger lifts and UIKit has
            // projected where the deceleration will land. Logs the launch
            // velocity + projected target so the upcoming decel can be
            // correlated to the content region it's about to render.
            decelTargetOffset = targetContentOffset.pointee.y
            #if DEBUG
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][willEndDragging] vy=\(String(format: "%.0f", velocity.y))pt/s offset=\(String(format: "%.0f", scrollView.contentOffset.y)) → target=\(String(format: "%.0f", decelTargetOffset)) projDist=\(String(format: "%.0f", decelTargetOffset - scrollView.contentOffset.y)) cs=\(String(format: "%.0f", scrollView.contentSize.height))")
            #endif
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                settleAfterInteraction(scrollView)
            }
        }

        func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION START — the marker the analysis hangs
            // off. Every subsequent slow frame is logged as "+Xms into decel".
            let now = CACurrentMediaTime()
            decelStartTime = now
            decelLastFrameTime = now
            decelStartOffset = scrollView.contentOffset.y
            decelFrameCount = 0
            decelSlowFrameCount = 0
            #if DEBUG
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][BEGIN] offset=\(String(format: "%.0f", decelStartOffset)) target=\(String(format: "%.0f", decelTargetOffset)) decelDist=\(String(format: "%.0f", decelTargetOffset - decelStartOffset)) visibleCells=\(visibleN) deferSelfSizing=\((viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
            // [DecelDisplayLink] Start the real-frame-rate meter only for this
            // decel phase. Drops/summary go to the log; CADisplayLink is removed
            // in scrollViewDidEndDecelerating below.
            startDecelDisplayLink()
            #endif
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION END — summarize the phase: total
            // duration, frames, how many were slow (dropped), final offset.
            if decelStartTime > 0 {
                #if DEBUG
                let dur = (CACurrentMediaTime() - decelStartTime) * 1000
                AppLogger(category: "ScrollDecel").info("[ScrollDecel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))")
                // [DecelDisplayLink] Print the REAL frame-rate summary for this
                // decel and stop the link. If actualFps≈vsync and drops=0 the
                // visual "jitter" wasn't a dropped frame at all.
                logDecelDisplayLinkSummary()
                stopDecelDisplayLink()
                #endif
                decelStartTime = 0
            }
            DispatchQueue.main.async { [weak self] in
                self?.settleAfterInteraction(scrollView)
            }
        }

        /// [ScrollDecel] Called from scrollViewDidScroll. While decelerating,
        /// measures the gap since the previous frame; a gap above the threshold
        /// is a dropped/janky frame and gets logged with how far into the decel
        /// it happened, the current offset/scroll direction, and how many cells
        /// are on screen (heavy cells = expensive sizeThatFits). This is the
        /// "which stage of the decel started the costly render" signal.
        private func logDecelFrameIfSlow(_ scrollView: UIScrollView) {
            #if DEBUG
            guard decelStartTime > 0, scrollView.isDecelerating else { return }
            let now = CACurrentMediaTime()
            let gap = now - decelLastFrameTime
            decelLastFrameTime = now
            decelFrameCount += 1
            guard gap > decelSlowFrameThreshold else { return }
            decelSlowFrameCount += 1
            let sinceStart = (now - decelStartTime) * 1000
            let off = scrollView.contentOffset.y
            let dir = off >= decelStartOffset ? "↓" : "↑"
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").warning("[ScrollDecel][SLOW-FRAME] +\(String(format: "%.0f", sinceStart))ms into decel gap=\(String(format: "%.0f", gap * 1000))ms offset=\(String(format: "%.0f", off))\(dir) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - off)) visibleCells=\(visibleN) frame#\(self.decelFrameCount)")
            #endif
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [T-scroll-sync-defer] Hold back sync refreshes while the user flings.
            if scrollView.isTracking || scrollView.isDecelerating {
                ChatScrollActivity.noteMoving()
            }
            // [T-ios-wheel-scroll-pin-fight] Leave auto-follow when the user
            // scrolls up with an INDIRECT pointer (mouse wheel, trackpad,
            // iPhone Mirroring).
            //
            // `scrollViewWillBeginDragging` is the only ordinary way out of
            // `.autoScrolling` (the other two are scroll-to-top and the
            // screenshot pass), and indirect scrolling never fires it -- it is
            // not a touch drag. So the mode stayed `.autoScrolling` no matter
            // how far the user scrolled, and the contentSize KVO re-pinned the
            // viewport on every self-sizing tick: at the bottom, where cells
            // are still measuring, that reads as the view repeatedly yanking
            // itself back down. (The `[KVO] PIN-WHILE-SCROLLING ... MODE SHOULD
            // BE userBrowsing` line exists for exactly this case.)
            //
            // Scoped to INDIRECT scrolling only, so a touch-only device cannot
            // reach this at all and its behaviour is bit-for-bit unchanged --
            // see `isIndirectScroll`. Within that scope the trigger is the
            // offset moving up, and every other condition is a veto. Each guard
            // below protects one behaviour that must survive:
            //
            //   - moved up by more than noise -> streaming (offset grows) and
            //     cell self-sizing jitter (a few pt) can never trigger it;
            //   - not animating to bottom -> the scroll-to-bottom button's
            //     animation travels upward and must not cancel itself;
            //   - not in the session-load clamp -> the first-load settle window
            //     adjusts the offset on its own and is not user intent.
            //
            // The way back in is untouched: `settleAfterInteraction` re-acquires
            // auto-scroll only within `reacquireAutoScrollThreshold` (4pt) of the
            // bottom, the tight rule [T-ios-trackpad-scroll-jitter] already
            // settled on. Touch dragging is unaffected -- it still goes through
            // `scrollViewWillBeginDragging` and gets there first.
            let offsetY = scrollView.contentOffset.y
            if scrollMode == .autoScrolling,
               Self.isIndirectScroll(scrollView),
               !isAnimatingScrollToBottom,
               !clampAfterSessionLoad,
               offsetY < lastDidScrollOffsetY - indirectScrollExitThreshold {
                // [T-thinking-toggle-txn] Indirect (wheel / trackpad / keyboard)
                // scrolling is a user takeover too: release the parked anchor.
                releaseThinkingToggleOnUserScroll()
                AppLogger(category: "ScrollDiag").info("[ScrollDiag][indirectScrollExit] offset \(String(format: "%.0f", lastDidScrollOffsetY))→\(String(format: "%.0f", offsetY)) panState=\(scrollView.panGestureRecognizer.state.rawValue) touches=\(scrollView.panGestureRecognizer.numberOfTouches) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating) — auto→browse")
                scrollMode = .userBrowsing
                // Same follow-ups willBeginDragging performs for a touch drag.
                lastJumpedUserId = nil
                viewController?.messageListLayout?.deferSelfSizing = true
            }
            lastDidScrollOffsetY = offsetY

            // [ScrollDecel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gap exceeded).
            logDecelFrameIfSlow(scrollView)
            #if DEBUG
            // [T-ios-scroll-metrics-ring] Per-frame offset/contentSize sample —
            // lets the pulled trace reconstruct exactly when visible content
            // shifted vs when the offset moved (jitter = the two disagreeing).
            ScrollMetricsRecorder.shared.record(
                kind: "scroll", a: scrollView.contentOffset.y,
                b: scrollView.contentSize.height,
                pos: scrollView.isDecelerating ? "decel" : (scrollView.isTracking ? "drag" : "idle"),
                offset: scrollView.contentOffset.y)
            #endif
            if let vm {
                // IMPORTANT: only write when the value actually changes.
                // `isNearBottom` is `@Published`, and every write broadcasts
                // `objectWillChange` to every SwiftUI view observing the VM —
                // triggering a full AttributeGraph invalidation+re-evaluation
                // pass on the SwiftUI update thread. On iPhone 8 this was
                // burning 100% of one CPU core every scroll frame.
                let nb = isNearBottom()
                if vm.isNearBottom != nb {
                    #if DEBUG
                    // Diagnostics: record every isNearBottom TRANSITION with the
                    // scroll position and the user-turn the viewport is in, plus
                    // the resulting up/down-button visibility (!messages.empty &&
                    // !isNearBottom). Only fires on change, so it stays off the
                    // per-frame hot path. ScrollMetricsRecorder is DEBUG-only.
                    let turn = currentViewportUserTurn()
                    ScrollMetricsRecorder.shared.record(kind: "nbChange",
                        idx: turn.index, a: nb ? 1 : 0, b: Double(turn.total),
                        pos: "buttonsVisible=\(!vm.messages.isEmpty && !nb)",
                        offset: Double(scrollView.contentOffset.y),
                        note: Self.nbDump(viewController?.collectionView))
                    #endif
                    vm.isNearBottom = nb
                }
                let atTop = isAtContentTop()
                if vm.isAtFirstTurn != atTop { vm.isAtFirstTurn = atTop }
                vm.contentOffsetYSignal.send(scrollView.contentOffset.y)
            }
            // Detect offset jumps right after settle
            if settleJustFinished {
                let delta = scrollView.contentOffset.y - lastLoggedOffset
                if abs(delta) > 2 {
                    AppLogger(category: "Settle").debug("[Settle] POST-SETTLE JUMP offset \(String(format: "%.1f→%.1f", lastLoggedOffset, scrollView.contentOffset.y)) delta=\(String(format: "%.1f", delta)) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating) contentSize=\(String(format: "%.1f", scrollView.contentSize.height))")
                    settleJustFinished = false
                }
            }
            // [ScrollStall] Per-second scroll trajectory: offset, distance moved
            // since last flush, mode, tracking/decel state. Helps correlate
            // hitches with offset bursts.
            scrollSamples += 1
            let now = CACurrentMediaTime()
            if now - lastScrollFlush > 1.0 {
                let off = scrollView.contentOffset.y
                let dist = abs(off - lastScrollFlushOffset)
                AppLogger(category: "ScrollStall").debug("[SCR] last1s samples=\(scrollSamples) offset=\(String(format: "%.0f", off)) Δdist=\(String(format: "%.0f", dist)) cs=\(String(format: "%.0f", scrollView.contentSize.height)) mode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") tracking=\(scrollView.isTracking ? 1 : 0) decel=\(scrollView.isDecelerating ? 1 : 0) deferred=\((self.viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
                scrollSamples = 0
                lastScrollFlushOffset = off
                lastScrollFlush = now
            }
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            let wasBottomJump = isAnimatingScrollToBottom
            isAnimatingScrollToBottom = false
            // Final clamp: ensure offset doesn't exceed actual content bounds
            // after the animation completes (contentSize may have changed mid-flight).
            guard let cv = viewController?.collectionView else { return }
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            if cv.contentOffset.y > maxOff {
                cv.contentOffset.y = maxOff
            }
            // [T-scroll-bottom-native-animation] Rows below the old viewport
            // were ESTIMATED when the manual jump started; laying them out
            // measured their real heights, so the flight target is no longer
            // the bottom. Land on the true resting offset instead of stopping
            // short. Bounded (two attempts): a re-align can itself end short
            // while a stream keeps growing the content, and that case belongs
            // to the KVO / coalesced pin.
            guard wasBottomJump, scrollMode == .autoScrolling,
                  !cv.isTracking, !cv.isDecelerating, scrollBottomRealigns < 2 else { return }
            let bottomInsetBase = searchHidesComposer ? Self.searchBottomInset : baseBottomInset
            guard let target = bottomRestingOffset(cv, bottomInsetBase: bottomInsetBase),
                  abs(cv.contentOffset.y - target) > 1 else { return }
            scrollBottomRealigns += 1
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][bottomJumpRealign] #\(scrollBottomRealigns) off=\(String(format: "%.1f", cv.contentOffset.y)) target=\(String(format: "%.1f", target)) contentSize=\(String(format: "%.1f", cv.contentSize.height))")
            scrollToBottomNow(animated: true)
        }

        /// [T-statusbar-native-scroll] The ONLY synchronous "start" signal for
        /// a status-bar tap (UIKit does not send `willBeginDragging`). Take
        /// user ownership here and let UIKit run its own animation — no custom
        /// jump, no extra animation, no delay.
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            beginStatusBarScrollToTop()
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            // UIKit provides no flight token here. A completion delivered after
            // a drag/down-jump must not change the newer navigation's mode;
            // an earlier repeat-tap completion is useful only once at the top.
            guard statusBarScrollToTop.isActive,
                  scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1 else { return }
            scrollMode = .userBrowsing
            finishStatusBarScrollToTop(reason: .completed)
        }

        // MARK: - Status-bar scroll-to-top lifecycle [T-statusbar-native-scroll]

        /// Synchronous takeover at the start of the system gesture. The system
        /// animation itself is untouched; every list-owned writer that could
        /// move the viewport mid-flight is stopped or gated.
        func beginStatusBarScrollToTop() {
            // [T-statusbar-native-scroll] Already parked at the top: returning
            // true keeps UIKit's contract, but there is nothing to own — do not
            // suspend streaming / defer self-sizing for a no-op animation.
            if !statusBarScrollToTop.isActive, isAtContentTop() {
                scrollMode = .userBrowsing
                AppLogger(category: "StatusBarScroll").info("[StatusBarScroll][should] no-op at top offset=\(String(format: "%.1f", viewController?.collectionView?.contentOffset.y ?? 0))")
                return
            }
            let begin = statusBarScrollToTop.begin(
                previouslyStreamingSuspended: vm?.streamingUIUpdatesSuspended ?? false,
                previouslySelfSizingDeferred: viewController?.messageListLayout?.deferSelfSizing ?? false)
            let scrollView = viewController?.collectionView
            // 1. Leave auto-follow NOW. Deliberately not via
            //    `settleAfterInteraction`: that re-acquires `.autoScrolling`
            //    within 4pt of the bottom, which is exactly where a status-bar
            //    tap starts, so the pin would be back for the whole flight.
            scrollMode = .userBrowsing
            // 2. Retire the old bottom animation state + token: its completion
            //    or 1.2s safety net must not clear/re-align anything for this
            //    flight.
            isAnimatingScrollToBottom = false
            scrollBottomJumpToken &+= 1
            scrollBottomRealigns = 0
            // 3. A queued 80ms coalesced bottom pin would fire mid-flight.
            pendingScrollWork?.cancel()
            pendingScrollWork = nil
            // 4. The session-load clamp is a bottom pin too (8s window).
            clampAfterSessionLoad = false
            // 5. A parked thinking-toggle anchor is user-intent state from
            //    before the tap; release it without pulling the offset.
            releaseThinkingToggleOnUserScroll()
            // 5b. [T-user-ask-anchor-flight] Same for the answered-question
            //     card: its anchor suppresses the visible-cell compensation and
            //     its verify chain would probe/write the offset mid-flight, so
            //     the flight clears both (token-less takeover).
            let abandonedCardAnchor = viewController?.messageListLayout?.abandonTopAnchor() ?? false
            lastJumpedUserId = nil
            // 6. Borrow the drag's two ownership flags. Unlike the drag, no
            //    settle follows, so `finish...` below restores them on EVERY
            //    end path (completion, drag transfer, session change, leave,
            //    search, screenshot, supersede, watchdog).
            if begin.needsSelfSizingDeferral {
                viewController?.messageListLayout?.deferSelfSizing = true
            }
            if begin.needsStreamingSuspend {
                vm?.setStreamingUIUpdatesSuspended(true)
            }
            viewController?.messageListLayout?.isSystemScrollToTopActive = true
            AppLogger(category: "StatusBarScroll").info("[StatusBarScroll][should] token=\(begin.token) repeat=\(begin.isRepeat ? 1 : 0) offset=\(String(format: "%.1f", scrollView?.contentOffset.y ?? 0)) cs=\(String(format: "%.1f", scrollView?.contentSize.height ?? 0)) mode=browse clamp=0 animBottom=0 pendingWork=0")
            scheduleStatusBarScrollToTopWatchdog(token: begin.token)
        }

        /// [T-statusbar-native-scroll] Consume what the flight deferred, WITHOUT
        /// `settleAfterInteraction` (that re-acquires `.autoScrolling` within
        /// 4pt of the bottom — exactly where a status-bar tap starts). The
        /// viewport is restored numerically after the height flush, so the user
        /// stays at the top (or at the new intent that superseded the flight).
        private func resumeAfterStatusBarScrollToTop(
            reason: StatusBarScrollToTopLifecycle.EndReason,
            restoreSelfSizing: Bool,
            restoreStreaming: Bool
        ) {
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else {
                if restoreStreaming { vm?.setStreamingUIUpdatesSuspended(false) }
                return
            }
            let savedOffset = cv.contentOffset.y
            if restoreSelfSizing {
                // Thaw BEFORE paying text correction debt: applyCellCorrection
                // refuses while deferSelfSizing is true and otherwise merely
                // re-arms its retry timer. Keep all offset writers suppressed
                // through the real layout pass, not just invalidateLayout().
                let wasFlushing = isFlushing
                let wasSuppressing = layout.suppressContentOffsetAdjustment
                isFlushing = true
                layout.suppressContentOffsetAdjustment = true
                defer {
                    layout.suppressContentOffsetAdjustment = wasSuppressing
                    isFlushing = wasFlushing
                }
                layout.deferSelfSizing = false
                for cell in cv.visibleCells {
                    Self.forEachMarkdownTextView(in: cell) { $0.consumeDeferredCorrectionIfNeeded() }
                }
                layout.applyDeferredHeights()
                layout.invalidateLayout()
                cv.layoutIfNeeded()
                if scrollMode == .userBrowsing {
                    cv.contentOffset.y = savedOffset
                }
            }
            if restoreStreaming {
                vm?.setStreamingUIUpdatesSuspended(false)
            }
            if hasPendingSnapshot {
                let resumeToken = statusBarScrollToTop.token
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.statusBarScrollToTop.token == resumeToken,
                          !self.statusBarScrollToTop.isActive,
                          self.vm?.streamingUIUpdatesSuspended != true else { return }
                    self.flushPendingSnapshotIfNeeded(caller: "statusbar-end")
                }
            }
            AppLogger(category: "StatusBarScroll").info("[StatusBarScroll][resume] reason=\(reason.rawValue) offset=\(String(format: "%.1f", savedOffset)) selfSize=\(restoreSelfSizing ? 1 : 0) stream=\(restoreStreaming ? 1 : 0) pendingSnapshot=\(hasPendingSnapshot ? 1 : 0)")
        }

        /// Single terminal path. Returns true only when this call actually ended
        /// the live flight (stale callbacks return false and change nothing).
        @discardableResult
        func finishStatusBarScrollToTop(
            reason: StatusBarScrollToTopLifecycle.EndReason,
            restoring: Bool = true,
            offset: CGFloat? = nil,
            expectedToken: Int? = nil
        ) -> Bool {
            guard statusBarScrollToTop.isActive else { return false }
            let end = statusBarScrollToTop.end(reason, restoring: restoring,
                                               expectedToken: expectedToken)
            guard !end.stale else { return false }
            statusBarScrollToTopWatchdog?.cancel()
            statusBarScrollToTopWatchdog = nil
            // Order: stop suppressing layout adjustments BEFORE resuming
            // self-sizing, so the first self-size pass is not blocked.
            viewController?.messageListLayout?.isSystemScrollToTopActive = false
            if end.restoreSelfSizing || end.restoreStreaming {
                resumeAfterStatusBarScrollToTop(reason: reason,
                                                restoreSelfSizing: end.restoreSelfSizing,
                                                restoreStreaming: end.restoreStreaming)
            }
            AppLogger(category: "StatusBarScroll").info("[StatusBarScroll][end] token=\(end.token) reason=\(reason.rawValue) ms=\(String(format: "%.0f", end.activeMs)) offset=\(offset.map { String(format: "%.1f", $0) } ?? "-") restoreStream=\(end.restoreStreaming ? 1 : 0) restoreSelfSize=\(end.restoreSelfSizing ? 1 : 0) begins=\(statusBarScrollToTop.beginCount) completed=\(statusBarScrollToTop.completedCount) interrupted=\(statusBarScrollToTop.interruptionCount)")
            return true
        }

        /// Progress/still watchdog: `DidScrollToTop` is the normal completion,
        /// but a system animation cancelled without a callback must not leave
        /// the list gated forever. Token-checked, progress-aware — this never
        /// force-clears a flight that is still moving, and never uses a fixed
        /// 2s window.
        private func scheduleStatusBarScrollToTopWatchdog(token: Int) {
            statusBarScrollToTopWatchdog?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.statusBarScrollToTop.isActive,
                      self.statusBarScrollToTop.token == token,
                      let cv = self.viewController?.collectionView else { return }
                let atTop = cv.contentOffset.y <= -cv.adjustedContentInset.top + 0.5
                    && !cv.isTracking && !cv.isDecelerating
                if self.statusBarScrollToTop.noteWatchdogSample(offset: cv.contentOffset.y,
                                                                atTop: atTop) {
                    self.finishStatusBarScrollToTop(reason: .watchdog,
                                                    offset: cv.contentOffset.y,
                                                    expectedToken: token)
                } else {
                    self.scheduleStatusBarScrollToTopWatchdog(token: token)
                }
            }
            statusBarScrollToTopWatchdog = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + StatusBarScrollToTopLifecycle.watchdogInterval,
                execute: work)
        }

        /// [T-ios-defer-retry-never-consumed] Recursively walks a cell's subview
        /// tree and applies `body` to every hosted `SelectableMarkdownTextView`.
        /// Mirrors `invalidateTableAttachmentsInSubviews` in
        /// MessageListInfrastructure — the markdown view is nested several
        /// levels inside the UIHostingConfiguration's view tree, so there is no
        /// direct handle on it from the cell.
        private static func forEachMarkdownTextView(in view: UIView,
                                                    _ body: (SelectableMarkdownTextView) -> Void) {
            if let tv = view as? SelectableMarkdownTextView { body(tv) }
            for sub in view.subviews { forEachMarkdownTextView(in: sub, body) }
        }

        private func settleAfterInteraction(_ scrollView: UIScrollView) {
            // Re-acquire auto-scroll only when the user settled essentially at
            // the bottom (tight threshold), not merely "near" it. This stops
            // small trackpad scrolls on iPad from snapping back to the bottom
            // and jittering. [T-ios-trackpad-scroll-jitter]
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }

            let deferredCount = layout.deferredHeightCount
            AppLogger(category: "Settle").debug("[Settle] BEGIN mode=\(scrollMode == .autoScrolling ? "auto" : "browse") nearBottom=\(nearBottom) offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height)) deferredHeights=\(deferredCount) hasPendingSnapshot=\(hasPendingSnapshot)")

            // Re-enable self-sizing so future layout passes use real heights.
            layout.deferSelfSizing = false

            // [T-ios-defer-retry-never-consumed] Now that the defer window is
            // genuinely closed, let every visible markdown view apply a
            // correction it had to skip while the window was open.
            //
            // `SelectableMarkdownTextView.invalidateCellSizeIfNeeded` bails out
            // when `deferSelfSizing` is true, logging "will retry" and arming a
            // 0.6s timer. That timer is not a reliable consumer: it can fire
            // while the user is still dragging (landing back in the same bail),
            // and once the stream stops mutating the text storage the
            // fingerprint early-exit swallows the re-measure entirely — the
            // correction is then lost until the session is re-entered. Field
            // repro 2026-08-09: three skips in one session, none consumed; the
            // 11:01:27 one left a ~197pt error on screen for the remaining 38s
            // of the log, which is why the user could screenshot the overlap.
            //
            // Only views that actually owe a correction do any work — the call
            // is an early `guard` on a Bool for everyone else, so this adds no
            // measurement to the normal settle path.
            for cell in cv.visibleCells {
                Self.forEachMarkdownTextView(in: cell) { $0.consumeDeferredCorrectionIfNeeded() }
            }

            // [SettleJitter] Evidence capture (H1): the flush below re-flows
            // frames from corrected heights but restores only the numeric
            // offset — if cells ABOVE the viewport changed height, the same
            // offset now shows different content. Anchor on the top visible
            // cell's screen-relative y before/after to quantify the jump the
            // user actually sees at decel end.
            let anchorIP = cv.indexPathsForVisibleItems.min()
            let anchorPreY = anchorIP.flatMap { layout.layoutAttributesForItem(at: $0)?.frame.minY }

            let savedOffset = cv.contentOffset.y
            isFlushing = true
            layout.applyDeferredHeights()

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            isFlushing = false

            // Restore offset
            if scrollMode == .userBrowsing {
                cv.contentOffset.y = savedOffset
            }

            // [SettleJitter] Post-flush: same anchor item, new frame. screenΔ
            // is the on-screen displacement of the content the user is looking
            // at (0 = no visible jitter from the settle flush).
            if let ip = anchorIP, let preY = anchorPreY {
                cv.layoutIfNeeded()
                let postY = layout.layoutAttributesForItem(at: ip)?.frame.minY ?? preY
                let screenDelta = (postY - cv.contentOffset.y) - (preY - savedOffset)
                #if DEBUG
                // [T-ios-scroll-metrics-ring]
                ScrollMetricsRecorder.shared.record(
                    kind: "settle", idx: ip.item, a: screenDelta, b: postY - preY,
                    offset: Double(cv.contentOffset.y),
                    note: String(format: "savedOff=%.0f", savedOffset))
                #endif
                if abs(screenDelta) > 0.5 {
                    AppLogger(category: "SettleJitter").info("[SettleJitter][settle-shift] anchor=idx\(ip.item) screenΔ=\(String(format: "%+.1f", screenDelta)) frameY \(String(format: "%.0f", preY))→\(String(format: "%.0f", postY)) offset \(String(format: "%.0f", savedOffset))→\(String(format: "%.0f", cv.contentOffset.y))")
                }
            }

            vm?.setStreamingUIUpdatesSuspended(false)

            if hasPendingSnapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "settle")
                }
            }

            lastLoggedOffset = cv.contentOffset.y
            settleJustFinished = true
            // Auto-clear after 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.settleJustFinished = false
            }
            AppLogger(category: "Settle").debug("[Settle] END offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height))")
        }
}
