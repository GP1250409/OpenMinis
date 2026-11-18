//
//  StatusBarScrollToTop.swift
//  Minis - V3 chat message list
//
//  [T-statusbar-native-scroll] Lifecycle + offset-writer policy for the
//  system status-bar "scroll to top" gesture.
//
//  A status-bar tap is NOT a drag: UIKit never sends
//  `scrollViewWillBeginDragging`, it asks the delegate once
//  (`scrollViewShouldScrollToTop`) and then runs its own scroll animation.
//  Before this file the list only learned about the gesture when it had
//  already finished (`scrollViewDidScrollToTop`), so for the whole flight the
//  coordinator stayed in `.autoScrolling` and every list-owned offset writer
//  (contentSize pin, coalesced 80ms pin, sub-viewport compensation, layout
//  contentOffsetAdjustment, streaming grow animation) could fight the system
//  animation.
//
//  This type owns ONLY the bookkeeping and the decisions:
//    - one start, token-guarded so a stale completion/deadline can never end a
//      newer flight (repeat status-bar tap during a flight included);
//    - exactly-once restore of the two ownership flags the start borrowed
//      (streaming-body suspend + deferred self-sizing) on every terminal path,
//      not only `DidScrollToTop`;
//    - a progress/still watchdog signal whose caller supplies the real offset
//      (this type never touches a view, never performs a jump/animation, and
//      never calls a private API);
//    - the single policy used by every list-owned offset writer.
//
//  File map and split rules: CollectionViewMessageListV3.swift.
//

import Foundation

/// [T-statusbar-native-scroll] Bookkeeping for one system scroll-to-top flight.
final class StatusBarScrollToTopLifecycle {

    /// Why a flight stopped. `.completed` is the only non-interruption.
    enum EndReason: String {
        case completed
        case drag
        case sessionChange
        case viewDisappear
        case search
        case screenshot
        case superseded
        /// [T-user-ask-anchor-flight] An answered-question card toggle took the
        /// viewport: it ends the flight first, then re-measures the card.
        case askToggle
        case watchdog
    }

    struct Begin: Equatable {
        let token: Int
        /// The caller must suspend streaming body updates (borrowed once).
        let needsStreamingSuspend: Bool
        /// The caller must set `deferSelfSizing` (borrowed once).
        let needsSelfSizingDeferral: Bool
        /// Another tap arrived while a flight was already active.
        let isRepeat: Bool
    }

    struct End: Equatable {
        let token: Int
        let wasActive: Bool
        /// The flight had already ended (or was replaced) — drop the callback.
        let stale: Bool
        let restoreStreaming: Bool
        let restoreSelfSizing: Bool
        let reason: EndReason
        let activeMs: Double
    }

    private(set) var isActive = false
    /// Monotonic. Bumped by begin AND end, so every deferred task can capture
    /// it and drop itself when a newer flight (or an interruption) intervened.
    private(set) var token = 0
    private(set) var beginCount = 0
    private(set) var completedCount = 0
    private(set) var interruptionCount = 0
    private(set) var lastEndReason: EndReason?
    private(set) var lastActiveMs: Double = 0
    /// Ownership flags: set by `begin`, cleared exactly once by `end`.
    private(set) var streamingSuspendedByFlight = false
    private(set) var selfSizingDeferredByFlight = false

    private var beganAt: TimeInterval = 0
    private var lastWatchdogOffset: CGFloat = .nan
    private var stalledWatchdogSamples = 0
    private var watchdogSamples = 0

    /// Watchdog cadence (seconds). Purely a backstop; `DidScrollToTop` remains
    /// the normal completion signal.
    static let watchdogInterval: TimeInterval = 0.45
    /// Consecutive still samples (≈1.35s of no offset movement) before the
    /// flight is treated as dead (the system animation was cancelled without a
    /// callback). Progress keeps the flight alive; this is NOT a fixed 2s
    /// clear.
    static let watchdogStillSamples = 3
    /// Repeat taps restart the still-sample window: the old samples describe
    /// the previous animation phase and must not declare the new one dead.

    /// Call from `scrollViewShouldScrollToTop`, synchronously, before returning
    /// true. Repeat calls keep the flight alive and mint a new token so the
    /// previous flight's deferred work is stale.
    func begin(previouslyStreamingSuspended: Bool = false,
               previouslySelfSizingDeferred: Bool = false,
               now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Begin {
        let isRepeat = isActive
        token &+= 1
        if !isRepeat {
            isActive = true
            beginCount += 1
        }
        // A repeat tap starts a NEW animation phase: reset the progress window
        // and its age even though the flight stays active.
        beganAt = now
        lastWatchdogOffset = .nan
        stalledWatchdogSamples = 0
        watchdogSamples = 0
        // Borrow ONLY what the flight actually changes: a suspend/defer that
        // already belonged to a sheet, background transition or drag must not
        // be resumed by our end path.
        let suspend = !previouslyStreamingSuspended && !streamingSuspendedByFlight
        if suspend { streamingSuspendedByFlight = true }
        let deferSize = !previouslySelfSizingDeferred && !selfSizingDeferredByFlight
        if deferSize { selfSizingDeferredByFlight = true }
        return Begin(token: token,
                     needsStreamingSuspend: suspend,
                     needsSelfSizingDeferral: deferSize,
                     isRepeat: isRepeat)
    }

    /// Terminal path. `restoring: false` is ONLY for a real drag, which
    /// suspends streaming and defers self-sizing itself one line later and
    /// restores them in `settleAfterInteraction`; the flight drops ownership so
    /// that path restores exactly once.
    /// `expectedToken` is for DEFERRED callers (watchdog / queued work): a
    /// flight that was replaced by a newer tap reports `stale` instead of
    /// ending the newer one. The synchronous `DidScrollToTop` passes nil —
    /// it always describes the system's current (only) animation.
    @discardableResult
    func end(_ reason: EndReason,
             restoring: Bool = true,
             expectedToken: Int? = nil,
             now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> End {
        if let expectedToken, expectedToken != token {
            return End(token: token, wasActive: isActive, stale: true,
                       restoreStreaming: false, restoreSelfSizing: false,
                       reason: reason, activeMs: 0)
        }
        guard isActive else {
            return End(token: token, wasActive: false, stale: true,
                       restoreStreaming: false, restoreSelfSizing: false,
                       reason: reason, activeMs: 0)
        }
        isActive = false
        token &+= 1
        let activeMs = max(0, (now - beganAt) * 1000)
        lastActiveMs = activeMs
        lastEndReason = reason
        if reason == .completed { completedCount += 1 } else { interruptionCount += 1 }
        let restoreStreaming = restoring && streamingSuspendedByFlight
        let restoreSelfSizing = restoring && selfSizingDeferredByFlight
        streamingSuspendedByFlight = false
        selfSizingDeferredByFlight = false
        return End(token: token, wasActive: true, stale: false,
                   restoreStreaming: restoreStreaming,
                   restoreSelfSizing: restoreSelfSizing,
                   reason: reason, activeMs: activeMs)
    }

    /// Feed one watchdog sample. Returns true when the caller should end the
    /// flight (`DidScrollToTop` never arrived and the system animation is no
    /// longer moving the viewport).
    func noteWatchdogSample(offset: CGFloat,
                            atTop: Bool,
                            now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        guard isActive else { return false }
        watchdogSamples += 1
        if !lastWatchdogOffset.isNaN, abs(offset - lastWatchdogOffset) <= 0.5 {
            stalledWatchdogSamples += 1
        } else {
            stalledWatchdogSamples = 0
        }
        lastWatchdogOffset = offset
        if atTop, watchdogSamples >= 2, stalledWatchdogSamples >= 1 { return true }
        // Only genuine stillness ends a flight: a moving viewport is never
        // force-cleared, no matter how long the animation takes.
        return stalledWatchdogSamples >= Self.watchdogStillSamples
    }
}

/// [T-statusbar-native-scroll] The single decision seam shared by every
/// list-owned offset writer and by the UIKit regression fixture. Kept pure so
/// the production decision (not a copy of it) is what CI exercises.
enum StatusBarScrollToTopPolicy {

    /// ContentSize pin / coalesced pin / sub-viewport offset pin.
    static func allowsBottomPin(isActive: Bool,
                                isAutoScrolling: Bool,
                                isAnimatingScrollToBottom: Bool) -> Bool {
        !isActive && isAutoScrolling && !isAnimatingScrollToBottom
    }

    /// Layout `contentOffsetAdjustment` (self-sizing / streaming glue).
    static func allowsContentOffsetAdjustment(isActive: Bool,
                                              isTracking: Bool,
                                              isDecelerating: Bool) -> Bool {
        !isActive && !isTracking && !isDecelerating
    }

    /// NoAnimationCollectionView's 0.2s streaming grow animation.
    static func allowsStreamingGrowAnimation(isActive: Bool,
                                            isStreaming: Bool,
                                            contentOverflows: Bool,
                                            isApplyingSnapshot: Bool,
                                            inGrowLayout: Bool) -> Bool {
        !isActive && isStreaming && contentOverflows && !isApplyingSnapshot && !inGrowLayout
    }

    /// The 80ms coalesced bottom pin.
    static func allowsCoalescedBottomPin(isActive: Bool,
                                         isAutoScrolling: Bool,
                                         isTracking: Bool,
                                         isAnimatingScrollToBottom: Bool) -> Bool {
        !isActive && isAutoScrolling && !isTracking && !isAnimatingScrollToBottom
    }
}
