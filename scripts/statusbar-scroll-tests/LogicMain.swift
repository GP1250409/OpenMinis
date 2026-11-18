// [T-statusbar-native-scroll] Linux-runnable logic checks for the production
// lifecycle/policy. UIKit behaviour lives in UIKitFixture.swift (CI only).
import Foundation

var checks = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: " + name) }
    checks += 1
    print("PASS: " + name)
}

let lifecycle = StatusBarScrollToTopLifecycle()
var mode = "auto"
var clamp = true
var bottomAnimating = true
var pendingWorkAlive = true
var streamingSuspended = false
var selfSizingDeferred = false

func onShould() {
    let begin = lifecycle.begin()
    mode = "browse"
    clamp = false
    bottomAnimating = false
    pendingWorkAlive = false
    if begin.needsStreamingSuspend { streamingSuspended = true }
    if begin.needsSelfSizingDeferral { selfSizingDeferred = true }
}

func onEnd(_ reason: StatusBarScrollToTopLifecycle.EndReason, restoring: Bool = true, expectedToken: Int? = nil) -> StatusBarScrollToTopLifecycle.End {
    let end = lifecycle.end(reason, restoring: restoring, expectedToken: expectedToken)
    if end.restoreStreaming { streamingSuspended = false }
    if end.restoreSelfSizing { selfSizingDeferred = false }
    return end
}

// 1. Should exits auto synchronously and borrows the drag ownership flags.
check(!lifecycle.isActive, "no flight before Should")
onShould()
check(lifecycle.isActive && lifecycle.beginCount == 1, "Should opens exactly one flight")
check(mode == "browse", "Should leaves autoScrolling for userBrowsing")
check(clamp == false, "Should cancels the session-load clamp")
check(bottomAnimating == false, "Should retires the old bottom animation")
check(pendingWorkAlive == false, "Should cancels the queued coalesced pin")
check(streamingSuspended && selfSizingDeferred, "Should borrows streaming + self-sizing ownership")
let firstToken = lifecycle.token
check(firstToken > 0, "Should mints a token")
check(!StatusBarScrollToTopPolicy.allowsBottomPin(isActive: true, isAutoScrolling: true, isAnimatingScrollToBottom: false),
      "active flight blocks the bottom pin even in auto mode")
check(!StatusBarScrollToTopPolicy.allowsCoalescedBottomPin(isActive: true, isAutoScrolling: true, isTracking: false, isAnimatingScrollToBottom: false),
      "active flight blocks the coalesced 80ms pin")
check(!StatusBarScrollToTopPolicy.allowsContentOffsetAdjustment(isActive: true, isTracking: false, isDecelerating: false),
      "active flight blocks layout contentOffsetAdjustment")
check(!StatusBarScrollToTopPolicy.allowsStreamingGrowAnimation(isActive: true, isStreaming: true, contentOverflows: true, isApplyingSnapshot: false, inGrowLayout: false),
      "active flight blocks the 0.2s streaming grow animation")

// 2. Repeat tap: new token; the previous token cannot end the new flight.
onShould()
check(lifecycle.token > firstToken, "repeat tap mints a newer token")
let oldFlightToken = firstToken
let stale = onEnd(.completed, expectedToken: firstToken)
check(stale.stale, "old completion cannot end the newer flight")
check(lifecycle.isActive, "flight still active after the stale completion")
check(lifecycle.token > oldFlightToken, "token advanced past the stale one")
check(streamingSuspended, "stale completion does not resume streaming")

// 3. Completion restores exactly once.
let done = onEnd(.completed)
check(!done.stale && done.restoreStreaming && done.restoreSelfSizing, "completion restores both ownership flags")
check(!streamingSuspended && !selfSizingDeferred, "completion actually resumes streaming and self-sizing")
check(lifecycle.completedCount == 1, "completion counted")
let afterDone = onEnd(.completed)
check(afterDone.stale, "double Did is stale")

// 4. Drag interrupt transfers ownership: no restore here, exactly one later.
onShould()
check(streamingSuspended && selfSizingDeferred, "second flight borrows again")
let drag = onEnd(.drag, restoring: false)
check(!drag.stale && !drag.restoreStreaming && !drag.restoreSelfSizing, "drag transfer does not restore")
check(streamingSuspended && selfSizingDeferred, "drag path still owns suspend/defer")
check(!lifecycle.isActive && !lifecycle.streamingSuspendedByFlight && !lifecycle.selfSizingDeferredByFlight,
      "flight ownership bookkeeping cleared on drag transfer")
streamingSuspended = false; selfSizingDeferred = false  // settleAfterInteraction
let afterDragCompletion = onEnd(.completed)
check(afterDragCompletion.stale && !streamingSuspended, "late Did after drag cannot resume twice")

// 5. Session change / leave / search / screenshot / supersede all restore.
for reason in [StatusBarScrollToTopLifecycle.EndReason.sessionChange, .viewDisappear, .search, .screenshot, .superseded] {
    onShould()
    let end = onEnd(reason)
    check(!end.stale && end.restoreStreaming && end.restoreSelfSizing && !streamingSuspended && !selfSizingDeferred,
          "end reason \(reason.rawValue) restores everything")
}

// 6. Watchdog: progress keeps the flight, stillness ends it; not a fixed 2s.
onShould()
let t0 = Date().timeIntervalSinceReferenceDate
check(!lifecycle.noteWatchdogSample(offset: 3000, atTop: false, now: t0 + 0.45), "first still sample is not enough")
check(!lifecycle.noteWatchdogSample(offset: 2000, atTop: false, now: t0 + 0.90), "progress resets the still counter")
check(!lifecycle.noteWatchdogSample(offset: 1500, atTop: false, now: t0 + 1.35), "continued progress never force-clears")
check(!lifecycle.noteWatchdogSample(offset: 900, atTop: false, now: t0 + 1.80), "flight survives past 1.8s while moving")
check(!lifecycle.noteWatchdogSample(offset: 900, atTop: false, now: t0 + 2.25), "still #1")
check(!lifecycle.noteWatchdogSample(offset: 900, atTop: false, now: t0 + 2.70), "still #2")
check(lifecycle.noteWatchdogSample(offset: 900, atTop: false, now: t0 + 3.15), "still #3 ends a dead animation")
onEnd(.watchdog)
check(!lifecycle.isActive, "watchdog end clears the flight")

// 7. Watchdog at top after Did was lost.
onShould()
_ = lifecycle.noteWatchdogSample(offset: 0, atTop: false, now: t0 + 4.0)
check(lifecycle.noteWatchdogSample(offset: 0, atTop: true, now: t0 + 4.45), "at-top and still ends after Did was lost")
_ = onEnd(.watchdog)

// 8. Bottom path (old native behavior) is untouched when no flight is active.
onShould(); onEnd(.completed)
check(StatusBarScrollToTopPolicy.allowsBottomPin(isActive: false, isAutoScrolling: true, isAnimatingScrollToBottom: false),
      "bottom pin allowed after the flight")
check(StatusBarScrollToTopPolicy.allowsCoalescedBottomPin(isActive: false, isAutoScrolling: true, isTracking: false, isAnimatingScrollToBottom: false),
      "coalesced bottom pin allowed after the flight")
check(StatusBarScrollToTopPolicy.allowsContentOffsetAdjustment(isActive: false, isTracking: false, isDecelerating: false),
      "layout adjustment allowed after the flight")
check(StatusBarScrollToTopPolicy.allowsStreamingGrowAnimation(isActive: false, isStreaming: true, contentOverflows: true, isApplyingSnapshot: false, inGrowLayout: false),
      "streaming grow animation allowed after the flight")
check(!StatusBarScrollToTopPolicy.allowsBottomPin(isActive: false, isAutoScrolling: true, isAnimatingScrollToBottom: true),
      "bottom animation still owns the offset during a bottom jump")
check(StatusBarScrollToTopPolicy.allowsContentOffsetAdjustment(isActive: false, isTracking: true, isDecelerating: false) == false,
      "drag still suppresses layout adjustment")

print("STATUSBAR_SCROLL_LOGIC_PASS checks=\(checks)")
