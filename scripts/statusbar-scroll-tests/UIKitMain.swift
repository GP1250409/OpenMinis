// [T-statusbar-native-scroll] Real-UIKit fixture. Compiled by CI against the
// Simulator SDK with the PRODUCTION StatusBarScrollToTop.swift; the harness
// reproduces the coordinator's delegate call order at Should/Did/interrupt and
// asks the production policy for every offset-writer decision.
//
// It does NOT simulate the physical status-bar tap (not scriptable): it calls
// the same UIScrollViewDelegate entry point with a real UICollectionView and
// lets UIKit run its own animated scroll. Not a substitute for on-device
// timing, under Reduce Motion / long-session conditions.
import UIKit

var checks = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: " + name) }
    checks += 1
    print("PASS: " + name)
}

/// Requests a real `contentOffsetAdjustment` from UIKit, gated by the
/// production policy — proves UIKit's layout pass leaves the viewport alone
/// while the system flight is active.
final class AdjustingLayout: UICollectionViewFlowLayout {
    var active = false
    var requested: CGFloat = 0
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let ctx = super.invalidationContext(forBoundsChange: newBounds)
        let tracking = collectionView?.isTracking ?? false
        let decel = collectionView?.isDecelerating ?? false
        if requested != 0,
           StatusBarScrollToTopPolicy.allowsContentOffsetAdjustment(
               isActive: active, isTracking: tracking, isDecelerating: decel) {
            ctx.contentOffsetAdjustment = CGPoint(x: 0, y: requested)
        }
        return ctx
    }
}

/// Mirrors the coordinator's wiring, not its geometry code. Every decision is
/// delegated to the production lifecycle/policy.
final class Harness: NSObject, UICollectionViewDataSource {
    let lifecycle = StatusBarScrollToTopLifecycle()
    var mode = "auto"
    var clamp = true
    var bottomAnimating = true
    var pendingPinAlive = false
    var streamingSuspended = false
    var selfSizingDeferred = false
    var layoutFlag = false
    var pinRuns = 0
    var pinWrites = 0
    weak var cv: UICollectionView?

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 40 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        cell.backgroundColor = .systemBlue
        return cell
    }

    func bottomOffset() -> CGFloat {
        guard let cv else { return 0 }
        return max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
    }

    func allowsBottomPin() -> Bool {
        StatusBarScrollToTopPolicy.allowsBottomPin(
            isActive: lifecycle.isActive,
            isAutoScrolling: mode == "auto",
            isAnimatingScrollToBottom: bottomAnimating)
    }

    func attemptBottomPin() {
        pinRuns += 1
        guard allowsBottomPin(), let cv else { return }
        pinWrites += 1
        cv.contentOffset.y = bottomOffset()
    }

    func shouldScrollToTopStart() -> Bool {
        let begin = lifecycle.begin()
        mode = "browse"
        clamp = false
        bottomAnimating = false
        pendingPinAlive = false
        if begin.needsStreamingSuspend { streamingSuspended = true }
        if begin.needsSelfSizingDeferral { selfSizingDeferred = true }
        layoutFlag = true
        return true
    }

    @discardableResult
    func finish(_ reason: StatusBarScrollToTopLifecycle.EndReason,
                restoring: Bool = true,
                expectedToken: Int? = nil) -> Bool {
        guard lifecycle.isActive else { return false }
        let end = lifecycle.end(reason, restoring: restoring, expectedToken: expectedToken)
        guard !end.stale else { return false }
        layoutFlag = false
        if end.restoreSelfSizing { selfSizingDeferred = false }
        if end.restoreStreaming { streamingSuspended = false }
        return true
    }
}

func makeCollectionView(harness: Harness, layout: AdjustingLayout) -> UICollectionView {
    let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), collectionViewLayout: layout)
    cv.dataSource = harness
    cv.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
    cv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
    // No UIWindow: a spawned test binary must not depend on UIApplicationMain.
    // UIScrollView's animated setContentOffset and UICollectionView layout both
    // run from the main run loop, which is all this fixture needs.
    cv.layoutIfNeeded()
    harness.cv = cv
    return cv
}

let harness = Harness()
let layout = AdjustingLayout()
let cv = makeCollectionView(harness: harness, layout: layout)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

let bottom = harness.bottomOffset()
cv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
check(abs(cv.contentOffset.y - bottom) <= 1, "fixture starts at the real bottom")
let startOffset = cv.contentOffset.y

// A stale coalesced pin scheduled BEFORE Should must not resurrect the bottom.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { harness.attemptBottomPin() }
harness.pendingPinAlive = true

// 1. Should: synchronous takeover, system animation untouched.
check(harness.shouldScrollToTopStart(), "Should returns true (system keeps the animation)")
check(harness.mode == "browse", "Should exits autoScrolling immediately")
check(harness.clamp == false, "Should cancels the session-load clamp")
check(harness.bottomAnimating == false, "Should retires the old bottom animation state")
check(harness.pendingPinAlive == false, "Should cancels the queued bottom pin")
check(harness.streamingSuspended && harness.selfSizingDeferred, "Should borrows streaming + self-sizing ownership")
check(harness.layoutFlag, "Should marks the layout as system-owned")
check(harness.lifecycle.isActive, "flight active")

// 2. Real UIKit animated scroll runs; the stale pin fires mid-flight but the
//    production policy blocks it, so the system animation is not cancelled.
cv.setContentOffset(CGPoint(x: 0, y: 0), animated: true)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
check(harness.pinRuns == 1, "stale scheduled pin actually ran")
check(harness.pinWrites == 0, "stale pin did not write the offset")
check(cv.contentOffset.y < startOffset - 100, "UIKit's own animation moved the viewport up")
let midOffset = cv.contentOffset.y

// 3. Layout offset protection + inset ledger.
layout.active = harness.layoutFlag
layout.requested = 40
let insetBefore = cv.contentInset.bottom
let adjustedBefore = cv.adjustedContentInset.bottom
let beforeAdjust = cv.contentOffset.y
let ctx = layout.invalidationContext(forBoundsChange: cv.bounds)
check(ctx.contentOffsetAdjustment == .zero, "layout requests no adjustment while the flight is active")
cv.collectionViewLayout.invalidateLayout(with: ctx)
cv.layoutIfNeeded()
check(abs(cv.contentOffset.y - beforeAdjust) <= 0.5, "layout pass did not move the system-owned viewport")
check(abs(cv.contentInset.bottom - insetBefore) <= 0.001, "bottom inset ledger preserved during the flight")
check(abs(cv.adjustedContentInset.bottom - adjustedBefore) <= 0.001, "adjusted inset preserved during the flight")

// 4. Completion restores exactly once and never snaps to the bottom.
check(harness.finish(.completed), "Did completes the flight")
check(!harness.streamingSuspended && !harness.selfSizingDeferred, "completion restores streaming + self-sizing")
check(!harness.layoutFlag, "completion releases the layout")
check(cv.contentOffset.y <= midOffset + 1, "completion does not jump back to the bottom")
check(!harness.finish(.completed), "a second Did is stale")

// 5. Bottom path still works after the flight: layout adjustment + native pin.
layout.active = harness.layoutFlag
layout.requested = 40
let beforeAllowed = cv.contentOffset.y
let ctx2 = layout.invalidationContext(forBoundsChange: cv.bounds)
check(ctx2.contentOffsetAdjustment != .zero, "layout may adjust the viewport again after the flight")
cv.collectionViewLayout.invalidateLayout(with: ctx2)
cv.layoutIfNeeded()
check(abs(cv.contentOffset.y - (beforeAllowed + 40)) <= 1, "UIKit applied the allowed contentOffsetAdjustment")
harness.mode = "auto"
harness.attemptBottomPin()
check(harness.pinWrites == 1, "bottom pin writes when no flight owns the viewport")
check(abs(cv.contentOffset.y - harness.bottomOffset()) <= 1, "old bottom path reaches the bottom")

// 6. Drag interrupt transfers ownership; settle restores once.
harness.shouldScrollToTopStart()
let flightToken = harness.lifecycle.token
check(harness.finish(.drag, restoring: false), "drag ends the flight")
check(harness.streamingSuspended && harness.selfSizingDeferred, "drag keeps the borrowed suspend/defer until settle")
check(!harness.lifecycle.streamingSuspendedByFlight && !harness.lifecycle.selfSizingDeferredByFlight,
      "flight ownership is cleared on the drag transfer")
check(!harness.finish(.completed, expectedToken: flightToken), "late Did after the drag is stale")
harness.streamingSuspended = false; harness.selfSizingDeferred = false; harness.layoutFlag = false  // settle

// 7. Repeat tap: the older deferred completion cannot end the newer flight.
harness.shouldScrollToTopStart()
let first = harness.lifecycle.token
harness.shouldScrollToTopStart()
let second = harness.lifecycle.token
check(second > first, "repeat tap mints a newer token")
check(!harness.finish(.completed, expectedToken: first), "older token is stale")
check(harness.lifecycle.isActive && harness.streamingSuspended, "newer flight survives the stale completion")
check(harness.finish(.completed, expectedToken: second), "current token completes the newer flight")
check(!harness.streamingSuspended && !harness.selfSizingDeferred, "repeat flight restores once")

// 8. Session change / leave / search / screenshot all restore.
for reason in [StatusBarScrollToTopLifecycle.EndReason.sessionChange, .viewDisappear, .search, .screenshot] {
    harness.shouldScrollToTopStart()
    check(harness.finish(reason), "end reason \(reason.rawValue) ends the flight")
    check(!harness.streamingSuspended && !harness.selfSizingDeferred && !harness.layoutFlag,
          "end reason \(reason.rawValue) restores all ownership")
}

// 9. The native scroll-to-top eligibility flag is untouched.
check(cv.scrollsToTop, "the list still opts into the system status-bar gesture")

print("STATUSBAR_SCROLL_UIKIT_PASS checks=\(checks)")
