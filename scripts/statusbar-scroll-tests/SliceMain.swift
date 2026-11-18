// [T-statusbar-native-scroll] Behaviour checks against the GENERATED production
// slice: the generator extracts beginStatusBarScrollToTop /
// finishStatusBarScrollToTop / resumeAfterStatusBarScrollToTop /
// scheduleStatusBarScrollToTopWatchdog from the real Coordinator file and
// compiles them here with stubs. This file only drives them.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

var checks = 0
func check(_ c: Bool, _ name: String) {
    if !c {
        print("FAIL: " + name)
        fflush(stdout)
        fatalError("FAIL: " + name)
    }
    checks += 1
    print("PASS: " + name)
    fflush(stdout)
}

let coord = SliceCoordinator()
let cv = coord.viewController!.collectionView!
let layout = coord.viewController!.messageListLayout!
let vm = coord.vm!

// begin: synchronous takeover, production code.
cv.contentOffset.y = 900
coord.beginStatusBarScrollToTop()
check(coord.scrollMode == .userBrowsing, "production begin exits autoScrolling")
check(coord.clampAfterSessionLoad == false, "production begin cancels the clamp")
check(coord.pendingScrollWork == nil, "production begin cancels the queued pin")
check(coord.isAnimatingScrollToBottom == false, "production begin retires the bottom animation")
check(coord.scrollBottomJumpToken == 8, "production begin invalidates the bottom-jump token")
check(coord.scrollBottomRealigns == 0, "production begin clears the re-align budget")
check(coord.lastJumpedUserId == nil, "production begin clears the jump cursor")
check(coord.thinkingReleased == 1, "production begin releases the thinking anchor once")
check(layout.abandonCount == 1, "production begin abandons the answered-question card anchor")
check(coord.statusBarScrollToTop.isActive, "production begin opens the flight")
check(layout.isSystemScrollToTopActive, "production begin marks the layout")
check(layout.deferSelfSizing, "production begin defers self-sizing")
check(vm.suspended, "production begin suspends streaming")

// complete: consume deferred work once, restore the numeric viewport, no auto.
cv.contentOffset.y = 0
check(coord.finishStatusBarScrollToTop(reason: .completed, offset: 0), "production finish completes")
check(!coord.statusBarScrollToTop.isActive, "production finish closes the flight")
check(layout.applyCount == 1, "production finish applies the deferred heights")
check(cv.visibleCells.reduce(0) { $0 + $1.text.consumed } == 2, "production finish consumes visible text corrections")
check(layout.invalidateCount == 1, "production finish re-lays out after the flush")
check(layout.deferSelfSizing == false, "production finish resumes self-sizing")
check(!vm.suspended, "production finish resumes streaming")
check(coord.scrollMode == .userBrowsing, "production finish does not re-acquire auto")
check(abs(cv.contentOffset.y) < 0.001, "production finish keeps the top offset")
check(coord.hasPendingSnapshot, "production finish leaves the pending snapshot to its deferred flush")

// drag transfer: production end with restoring:false leaves the borrowed flags
// to the drag path / settle and consumes nothing here.
coord.beginStatusBarScrollToTop()
let beforeApply = layout.applyCount
let beforeConsume = coord.consumedCorrections
check(coord.finishStatusBarScrollToTop(reason: .drag, restoring: false), "production drag transfer ends")
check(layout.deferSelfSizing && vm.suspended, "drag transfer leaves suspend/defer to the drag path")
check(layout.applyCount == beforeApply && coord.consumedCorrections == beforeConsume,
      "drag transfer does not flush (settle owns it)")
check(!coord.finishStatusBarScrollToTop(reason: .completed), "late Did after drag is stale")
// settleAfterInteraction owns the drag's restore; reproduce its effect.
vm.suspended = false; layout.deferSelfSizing = false

// Session change / leave / search / screenshot / superseded all resume.
for reason in [StatusBarScrollToTopLifecycle.EndReason.sessionChange, .viewDisappear,
               .search, .screenshot, .superseded] {
    coord.beginStatusBarScrollToTop()
    check(coord.finishStatusBarScrollToTop(reason: reason), "production \(reason.rawValue) ends")
    check(!layout.deferSelfSizing && !vm.suspended && !layout.isSystemScrollToTopActive,
          "production \(reason.rawValue) restores ownership")
}

// A repeat tap keeps the flight and starts a fresh progress window: a stale
// still sample from the previous phase cannot end it immediately.
coord.beginStatusBarScrollToTop()
let oldToken = coord.statusBarScrollToTop.token
coord.beginStatusBarScrollToTop()
check(coord.statusBarScrollToTop.token > oldToken, "repeat tap mints a newer token")
check(!coord.finishStatusBarScrollToTop(reason: .completed, expectedToken: oldToken),
      "older token cannot end the newer flight")
check(coord.statusBarScrollToTop.isActive, "newer flight survives")
check(coord.finishStatusBarScrollToTop(reason: .completed), "current flight completes")

// R2: a suspend/defer that already existed must NOT be resumed by our end.
let busy = SliceCoordinator()
busy.vm!.suspended = true
busy.viewController!.messageListLayout!.deferSelfSizing = true
busy.beginStatusBarScrollToTop()
check(!busy.statusBarScrollToTop.streamingSuspendedByFlight, "begin does not claim an existing streaming suspend")
check(!busy.statusBarScrollToTop.selfSizingDeferredByFlight, "begin does not claim an existing self-sizing defer")
busy.finishStatusBarScrollToTop(reason: .completed)
check(busy.vm!.suspended, "end leaves the pre-existing streaming suspend alone")
check(busy.viewController!.messageListLayout!.deferSelfSizing, "end leaves the pre-existing self-sizing defer alone")

// An old end-of-flight callback must not flush a snapshot into a newer flight.
let queued = SliceCoordinator()
queued.beginStatusBarScrollToTop()
queued.finishStatusBarScrollToTop(reason: .completed)
queued.beginStatusBarScrollToTop()
SliceMainQueue.drain()
check(queued.pendingFlushCaller == nil, "old deferred flush cannot run during a new flight")
queued.finishStatusBarScrollToTop(reason: .completed)
SliceMainQueue.drain()
check(queued.pendingFlushCaller == "statusbar-end", "current completed flight consumes its pending snapshot")
check(!queued.isFlushing && !queued.viewController!.messageListLayout!.suppressContentOffsetAdjustment,
      "restoration returns the layout/KVO suppression flags to their prior values")

// Exercise the actual production UIScrollViewDelegate completion entry point.
let late = SliceCoordinator()
let lateCV = late.viewController!.collectionView!
late.scrollViewDidScrollToTop(lateCV)
check(late.scrollMode == .autoScrolling, "late Did cannot overwrite a superseding bottom mode")
lateCV.contentOffset.y = 800
check(late.scrollViewShouldScrollToTop(lateCV), "production Should preserves UIKit's native animation")
late.scrollViewDidScrollToTop(lateCV)
check(late.statusBarScrollToTop.isActive, "old Did cannot end a newer flight before it reaches the top")
lateCV.contentOffset.y = -lateCV.adjustedContentInset.top
late.scrollViewDidScrollToTop(lateCV)
check(!late.statusBarScrollToTop.isActive, "production Did completes the live flight at the top")

print("STATUSBAR_SCROLL_SLICE_PASS checks=\(checks)")
