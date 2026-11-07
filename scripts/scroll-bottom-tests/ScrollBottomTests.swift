import Foundation
import UIKit

/// UIKit regression for the manual down-arrow jump (production
/// `scrollToBottomNow(animated: true)` path).
///
/// Everything asserted here runs on a real `UICollectionView` inside a real
/// window in the simulator: the animation is measured frame by frame from
/// `contentOffset`, not modelled. See ScrollFixture.swift for what is stubbed.
final class ScrollBottomRunner {
    private var checks = 0
    private var failures: [String] = []
    private var fixtures: [ListFixture] = []

    private func check(_ condition: Bool, _ name: String) {
        checks += 1
        if condition {
            print("PASS: \(name)")
        } else {
            failures.append(name)
            print("FAIL: \(name)")
        }
    }

    private func makeFixture(rows: Int) -> ListFixture {
        let fixture = ListFixture(rows: rows)
        fixtures.append(fixture)
        return fixture
    }

    private func restingTarget(_ fixture: ListFixture) -> CGFloat {
        fixture.coordinator.bottomRestingOffset(fixture.collectionView,
                                                bottomInsetBase: fixture.bottomInset) ?? 0
    }

    func run() {
        print("SCROLL_BOTTOM_UIKIT_START")
        animatedJumpGlides()
        pinFirstControlDoesNotGlide()
        rapidRepeatedTap()
        dragInterruptsAndStreamingPinRecovers()
        coalescedScrollDoesNotCutTheFlight()
        streamingPinIsStillInstant()
        shortListDoesNotStick()
        reduceMotionPolicy()
        growthDuringFlightReAligns()
        jumpFlagCannotOutliveTheFlight()
        finish()
    }

    // MARK: - 1. The manual down-arrow: a real native glide

    private func animatedJumpGlides() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)
        check(target > 5000, "fixture: long list has a bottom far below the viewport (target=\(Int(target)))")
        check(target <= f.contentBottomTarget + 1, "fixture: resting target is inside UIKit's scrollable range")

        let recorder = FrameRecorder()
        f.coordinator.scrollToBottomNow(animated: true)
        recorder.pump(1.6) { f.collectionView.contentOffset.y }

        let mids = distinctIntermediate(recorder.samples, from: 0, to: target)
        check(mids.count >= 8, "down-arrow travels through >=8 distinct intermediate offsets (got \(mids.count))")
        let reach = firstReachTime(recorder.samples, target: target) ?? -1
        check(reach >= 0.10, "down-arrow takes native animation time to arrive (reached at \(String(format: "%.2f", reach))s)")
        check(abs(f.collectionView.contentOffset.y - target) <= 1.5,
              "down-arrow lands on the resting bottom (off=\(String(format: "%.1f", f.collectionView.contentOffset.y)) target=\(String(format: "%.1f", target)))")
        check(!f.coordinator.isAnimatingScrollToBottom,
              "the in-flight flag is cleared when the jump ends (UIKit called the terminal delegate)")
    }

    // MARK: - 2. Negative control: the pre-fix order really is a snap

    private func pinFirstControlDoesNotGlide() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)

        // Exactly what the button used to do: the compensation pass — whose pin
        // writes contentOffset — ran first, then the same animated set.
        f.coordinator.applySubViewportCompensation(caller: "control")
        let pinned = f.collectionView.contentOffset.y
        f.collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        let recorder = FrameRecorder()
        recorder.pump(0.9) { f.collectionView.contentOffset.y }

        check(abs(pinned - target) <= 1.5,
              "control: the compensation pin alone already sits at the bottom before the animated set (pinned=\(String(format: "%.1f", pinned)) target=\(String(format: "%.1f", target)))")
        let mids = distinctIntermediate(recorder.samples, from: 0, to: target)
        check(mids.count <= 1, "control: animating after that pin shows no travel — the reported no-animation (mids=\(mids.count))")
    }

    // MARK: - 3. Rapid repeated taps

    private func rapidRepeatedTap() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)
        let recorder = FrameRecorder()
        f.coordinator.scrollToBottomNow(animated: true)
        recorder.pump(0.10) { f.collectionView.contentOffset.y }
        let midOffset = f.collectionView.contentOffset.y
        check(midOffset > 1 && midOffset < target - 1, "fixture: the first tap is still travelling when the second lands")
        let secondTapAt = recorder.samples.last?.t ?? 0
        f.coordinator.scrollToBottomNow(animated: true)
        recorder.pump(1.8) { f.collectionView.contentOffset.y }

        let reachedAfterSecondTap = recorder.samples
            .filter { $0.t >= secondTapAt }
            .first(where: { abs($0.y - target) <= 1.0 })?.t
        let secondTapTravel = (reachedAfterSecondTap ?? -1) - secondTapAt
        check(secondTapTravel >= 0.08,
              "a second tap mid-flight keeps gliding instead of snapping (reached \(String(format: "%.2f", secondTapTravel))s after the tap)")
        var reversed = false
        for (a, b) in zip(recorder.samples, recorder.samples.dropFirst()) where b.y < a.y - 1.5 { reversed = true }
        check(!reversed, "the jump never travels back up while it runs")
        check(abs(f.collectionView.contentOffset.y - target) <= 1.5, "rapid taps still land on the bottom")
        check(!f.coordinator.isAnimatingScrollToBottom, "rapid taps leave no in-flight flag behind")
    }

    // MARK: - 4. User drag interruption, then the streaming pin must work again

    private func dragInterruptsAndStreamingPinRecovers() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)
        f.coordinator.scrollToBottomNow(animated: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
        let mid = f.collectionView.contentOffset.y
        check(f.coordinator.isAnimatingScrollToBottom, "fixture: jump is in flight before the drag")

        // A touch cancels the programmatic animation without the terminal
        // delegate; the production drag entry point must clear the flag.
        f.collectionView.setContentOffset(CGPoint(x: 0, y: mid), animated: false)
        f.coordinator.scrollViewWillBeginDragging(f.collectionView)
        check(!f.coordinator.isAnimatingScrollToBottom, "a user drag clears the in-flight flag")
        check(f.coordinator.scrollMode == .userBrowsing, "a user drag still switches to userBrowsing")

        // Streaming follow must not stay deferred by a stale flag.
        f.coordinator.scrollMode = .autoScrolling
        f.coordinator.scrollToBottomNow()
        check(abs(f.collectionView.contentOffset.y - target) <= 1.5,
              "the non-animated pin lands on the bottom right after the interruption")
    }

    // MARK: - 5. The coalesced pin must not cut the flight short

    private func coalescedScrollDoesNotCutTheFlight() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)
        let recorder = FrameRecorder()
        f.coordinator.scrollToBottomNow(animated: true)
        recorder.pump(0.05) { f.collectionView.contentOffset.y }
        // What the contentSize KVO arms while rows below the old viewport
        // measure: an 80 ms non-animated pin.
        f.coordinator.scheduleCoalescedScroll()
        recorder.pump(1.6) { f.collectionView.contentOffset.y }

        let reach = firstReachTime(recorder.samples, target: target) ?? -1
        check(reach >= 0.18,
              "the coalesced pin no longer lands mid-flight (reached at \(String(format: "%.2f", reach))s, the pin would have fired at ~0.13s)")
        check(abs(f.collectionView.contentOffset.y - target) <= 1.5, "the jump still ends on the bottom after the deferred pin")
    }

    // MARK: - 6. Streaming pin semantics unchanged

    private func streamingPinIsStillInstant() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        let target = restingTarget(f)
        let recorder = FrameRecorder()
        f.coordinator.scrollToBottomNow()
        recorder.pump(0.25) { f.collectionView.contentOffset.y }

        check(abs(f.collectionView.contentOffset.y - target) <= 1.5,
              "the streaming pin (animated: false) still lands in one write")
        check(distinctIntermediate(recorder.samples, from: 0, to: target).isEmpty,
              "the streaming pin still produces no travel frames (no accidental animation)")
        check(!f.coordinator.isAnimatingScrollToBottom, "the streaming pin never claims the in-flight flag")
    }

    // MARK: - 7. Short list (content fits): no stuck state

    private func shortListDoesNotStick() {
        let f = makeFixture(rows: 2)
        f.setOffset(0)
        let topLimit = -f.collectionView.adjustedContentInset.top
        let recorder = FrameRecorder()
        f.coordinator.scrollToBottomNow(animated: true)
        recorder.pump(0.4) { f.collectionView.contentOffset.y }
        check(!f.coordinator.isAnimatingScrollToBottom, "a list shorter than the viewport cannot leave the flag set")
        check(abs(f.collectionView.contentOffset.y - topLimit) <= 1.5,
              "a list shorter than the viewport stays at the top resting offset")
    }

    // MARK: - 8. Reduce Motion policy

    private func reduceMotionPolicy() {
        let coordinatorType = CollectionViewMessageListV3.Coordinator.self
        check(!coordinatorType.animatesJumpToBottom(animated: true, reduceMotion: true),
              "Reduce Motion turns the jump into an instant move")
        check(coordinatorType.animatesJumpToBottom(animated: true, reduceMotion: false),
              "normal motion keeps the native animated jump")
        check(!coordinatorType.animatesJumpToBottom(animated: false, reduceMotion: false),
              "an explicit instant request stays instant")
    }

    // MARK: - 9. Content grew while the flight was running: re-align

    private func growthDuringFlightReAligns() {
        let f = makeFixture(rows: 60)
        f.setOffset(0)
        let targetBefore = restingTarget(f)
        f.coordinator.scrollToBottomNow(animated: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))

        // Estimated row heights become real ones while the flight is running.
        f.appendRows(40)
        let targetAfter = restingTarget(f)
        check(targetAfter > targetBefore + 100,
              "fixture: content grew during the flight (+\(Int(targetAfter - targetBefore))pt)")

        // Drive the production terminal callback (UIKit's own wiring for it is
        // covered by test 1, where the flag clears without help).
        f.coordinator.scrollViewDidEndScrollingAnimation(f.collectionView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.6))

        check(abs(f.collectionView.contentOffset.y - targetAfter) <= 2,
              "the jump re-aligns to the true bottom after the estimates were measured (off=\(String(format: "%.1f", f.collectionView.contentOffset.y)) target=\(String(format: "%.1f", targetAfter)))")
        check(f.coordinator.scrollBottomRealigns <= 2, "the re-align is bounded")
        check(!f.coordinator.isAnimatingScrollToBottom, "the re-align finishes with no in-flight flag")
    }

    // MARK: - 10. Safety net: the flag cannot outlive the animation

    private func jumpFlagCannotOutliveTheFlight() {
        let f = makeFixture(rows: 120)
        f.setOffset(0)
        f.coordinator.scrollToBottomNow(animated: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        // A write we do not control cancels UIKit's animation without the
        // terminal delegate (this is the case that used to leave pins deferred).
        f.collectionView.contentOffset = CGPoint(x: 0, y: f.collectionView.contentOffset.y + 4)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        check(!f.coordinator.isAnimatingScrollToBottom,
              "the in-flight flag is cleared within 1.2 s even without a terminal callback")
    }

    // MARK: - Result

    private func finish() {
        if failures.isEmpty {
            print("SCROLL_BOTTOM_UIKIT_PASS checks=\(checks)")
            exit(0)
        }
        for failure in failures { print("SCROLL_BOTTOM_FAILED: \(failure)") }
        print("SCROLL_BOTTOM_UIKIT_FAILED checks=\(checks) failures=\(failures.count)")
        exit(1)
    }
}
