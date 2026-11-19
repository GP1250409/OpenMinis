// [T-ios-streaming-resume-reentry] Behaviour checks against the GENERATED
// production slice. scripts/streaming_resume_regression.py extracts
//   scheduleStreamingResumeNotification, clearStreamingUIUpdatesSuspended,
//   setStreamingUIUpdatesSuspended, setSuspendedForTransition,
//   setStreamingTextBlockContent, applyStreamingTextBlockContent and
//   flushDeferredStreamingTextUpdateIfNeeded
// verbatim from the shipping Agent/Chat/AIChatViewModel+StreamingUI.swift and
// compiles them against the stubs below. This file only drives them — every
// assertion below executes the production body, never a re-implementation.
//
// Crash being frozen (Minis-2026-11-19 20:28:54 / 20:41:11, same frames):
//   dismantleUIViewController → finishStatusBarScrollToTop →
//   resumeAfterStatusBarScrollToTop → setStreamingUIUpdatesSuspended(false) →
//   objectWillChange.send → CachedViewModel forwarder → SwiftUI body re-entry →
//   swift_beginAccess exclusivity trap.
// The suite's job: the resume NOTIFICATION must leave the caller's stack, stay
// coalesced, and never be dropped, while the resume STATE stays synchronous and
// the deferred text / final tool status survive.
//
// `pump()` is the platform's "let queued main-thread work run":
//   Linux  — the generator rewrote DispatchQueue.main.async → SliceMainQueue.async
//            and pump() drains it deterministically;
//   Darwin — the generator leaves the real DispatchQueue.main.async in place and
//            pump() spins the main runloop, so this same driver proves the real
//            Combine + GCD path and prints STREAMING_RESUME_COMBINE_PASS.
import Foundation
#if canImport(Combine)
import Combine
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
func checkEq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    if a != b { print("  expected \(b), got \(a)") }
    check(a == b, name)
}

func makeVM(_ session: String = "0243521B-1111-2222-3333-444455556666") -> StubVM {
    let vm = StubVM()
    vm.sessionId = session
    vm.messages = [ChatMessage(blocks: [AssistantBlock(kind: "text")])]
    vm.isNearBottom = false
    return vm
}

// Frame depth of the caller: the harness bumps it to simulate SwiftUI's
// update/teardown pass (the stack `dismantleUIViewController` provides).
var frameDepth = 0

// MARK: - [1] The resume notification leaves the caller's stack

print("\n[1] Resume from inside the update/teardown frame publishes nothing inline")
do {
    let vm = makeVM()
    var publishes = 0
    var insideFrame = 0
    var hooks = 0
    var hookInsideFrame = 0
    vm.startObservingPublishes { publishes += 1; if frameDepth > 0 { insideFrame += 1 } }
    vm.onStreamingUIUpdatesResumed = { hooks += 1; if frameDepth > 0 { hookInsideFrame += 1 } }

    vm.setStreamingUIUpdatesSuspended(true)          // beginStatusBarScrollToTop
    frameDepth += 1                                   // dismantleUIViewController
    vm.setStreamingUIUpdatesSuspended(false)          // → finish → resume → clear
    frameDepth -= 1

    checkEq(publishes, 0, "no objectWillChange delivery inside the teardown frame")
    checkEq(hooks, 0, "no coordinator resume hook inside the teardown frame")
    checkEq(insideFrame, 0, "the publisher never re-entered the teardown frame")
    checkEq(hookInsideFrame, 0, "the resume hook never re-entered the teardown frame")
    checkEq(vm.streamingUIUpdatesSuspended, false,
            "the suspend flag is still cleared SYNCHRONOUSLY (state before notification)")
    checkEq(vm.streamingResumeNotificationScheduled, true, "exactly one notification is queued")
    pump()
    checkEq(publishes, 1, "one publish after the hop")
    checkEq(hooks, 1, "one resume hook after the hop")
    checkEq(vm.streamingResumeNotificationScheduled, false, "the queue slot is released")
    checkEq(vm.streamingResumeNotificationPending, false, "nothing is left owed")
    pump()
    checkEq(publishes, 1, "a second pump replays nothing (no self-feeding hop)")
}

// MARK: - [2] Coalescing

print("\n[2] N resumes in one turn → exactly one notification")
do {
    let vm = makeVM()
    var publishes = 0
    var hooks = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.onStreamingUIUpdatesResumed = { hooks += 1 }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingUIUpdatesSuspended(false)         // queues #1
    vm.setSuspendedForTransition(true)               // re-gates (session switch starts)
    vm.setSuspendedForTransition(false)              // queues again → coalesced
    pump()
    checkEq(publishes, 1, "two resume paths → one publish")
    checkEq(hooks, 1, "two resume paths → one resume hook")

    // Five full cycles must deliver five, never zero and never ten.
    let cyclePublishes = publishes
    for _ in 0..<5 {
        vm.setStreamingUIUpdatesSuspended(true)
        vm.setStreamingUIUpdatesSuspended(false)
        pump()
    }
    checkEq(publishes - cyclePublishes, 5, "5 suspend/resume cycles → 5 publishes")
}

// MARK: - [3] Re-suspend before the hop: nothing delivered, nothing lost

print("\n[3] A suspend that lands before the hop keeps the notification owed")
do {
    let vm = makeVM()
    var publishes = 0
    var hooks = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.onStreamingUIUpdatesResumed = { hooks += 1 }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingUIUpdatesSuspended(false)         // queues
    vm.setStreamingUIUpdatesSuspended(true)          // re-suspended before it ran
    pump()
    checkEq(publishes, 0, "the superseded notification publishes nothing")
    checkEq(hooks, 0, "…and calls no resume hook on a re-suspended vm")
    checkEq(vm.streamingResumeNotificationPending, true, "…but the notification is still owed")
    vm.setStreamingUIUpdatesSuspended(false)
    pump()
    checkEq(publishes, 1, "the following resume delivers it (nothing was dropped)")
    checkEq(hooks, 1, "…including the resume hook")
}

// MARK: - [4] Re-verification against the transition gate at fire time

print("\n[4] A session switch that starts before the hop defers, and never drops")
do {
    let vm = makeVM()
    var publishes = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingUIUpdatesSuspended(false)         // queues
    vm.setSuspendedForTransition(true)               // outgoing side of the switch
    pump()
    checkEq(publishes, 0, "no publish while the vm is the outgoing side")
    checkEq(vm.streamingResumeNotificationPending, true, "the notification stays owed")
    vm.setSuspendedForTransition(false)
    pump()
    checkEq(publishes, 1, "leaving the transition delivers it once")
    checkEq(vm.transitionSuspended, false, "the transition flag is restored synchronously")
}

// MARK: - [5] Ordering inside the notification: hook → replay → publish

print("\n[5] The notification runs hook, deferred replay, then the republish")
do {
    let vm = makeVM()
    var order: [String] = []
    vm.startObservingPublishes { order.append("publish") }
    vm.onStreamingUIUpdatesResumed = { order.append("hook") }
    vm.startObservingReplay { order.append("replay") }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.needsSnapshotReloadOnResume = true            // loop ended while suspended
    vm.setStreamingUIUpdatesSuspended(false)
    pump()
    checkEq(order, ["hook", "replay", "publish"], "hook → replay → publish, once each")
    checkEq(vm.needsSnapshotReloadOnResume, false, "the loop-end replay flag is consumed")
}

print("\n[5b] A superseded resume must not eat the loop-end replay")
do {
    let vm = makeVM()
    var replays = 0
    vm.startObservingReplay { replays += 1 }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.needsSnapshotReloadOnResume = true
    vm.setStreamingUIUpdatesSuspended(false)         // queues
    vm.setSuspendedForTransition(true)               // supersedes before the hop
    pump()
    checkEq(replays, 0, "no replay while gated")
    checkEq(vm.needsSnapshotReloadOnResume, true,
            "the replay flag survives a resume that could not run (pre-fix ate it)")
    vm.setSuspendedForTransition(false)
    pump()
    checkEq(replays, 1, "…and replays exactly once when the gate lifts")
    checkEq(vm.needsSnapshotReloadOnResume, false, "flag consumed exactly once")
}

// MARK: - [6] Deferred streaming text: coalesced, newest wins, applied synchronously

print("\n[6] Deferred text is flushed by the resume itself, before any notification")
do {
    let vm = makeVM()
    let block = vm.messages[0].blocks[0]
    var publishes = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 0, text: "alpha",
                                    parsedMarkdown: nil, cacheAttributedString: false,
                                    requestScroll: true)
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 0, text: "alpha beta",
                                    parsedMarkdown: nil, cacheAttributedString: true,
                                    requestScroll: true)
    // …and a later interim snapshot must NOT clear that flag (OR-merge).
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 0, text: "alpha beta gamma",
                                    parsedMarkdown: nil, cacheAttributedString: false,
                                    requestScroll: true)
    checkEq(vm.deferredStreamingTextUpdates.count, 1, "one block → one deferred entry (coalesced)")
    checkEq(block.content, "", "nothing is written while suspended")
    checkEq(StreamingHangLogger.shared.flushes, 3, "every flush still reaches the hang logger")

    vm.setStreamingUIUpdatesSuspended(false)
    checkEq(block.content, "alpha beta gamma", "the newest text is applied by the resume, synchronously")
    checkEq(vm.deferredStreamingTextUpdates.count, 0, "the deferred queue is drained")
    checkEq(vm.cacheCalls, 1, "the final attributed string is cached once")
    checkEq(block.cachedMarkdown?.text, "alpha beta gamma",
            "…and the final markdown snapshot is the newest text")
    checkEq(vm.scrollToBottomSignal.sendCount, 0, "no scroll request while isNearBottom is false")
    checkEq(publishes, 0, "…and still no publish inside the resume call")
    pump()
    checkEq(publishes, 1, "the notification follows the flush")
}

print("\n[6b] Near the bottom the flushed text still asks for a scroll")
do {
    let vm = makeVM()
    vm.isNearBottom = true
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 0, text: "tail",
                                    parsedMarkdown: nil, cacheAttributedString: true,
                                    requestScroll: true)
    vm.setStreamingUIUpdatesSuspended(false)
    checkEq(vm.scrollToBottomSignal.sendCount, 1, "the resume keeps the scroll-to-bottom signal")
    checkEq(vm.messages[0].blocks[0].content, "tail", "and the text")
}

// MARK: - [7] In-place tool status is republished (no dirty-bit drop)

print("\n[7] A tool-status mutation that assigns nothing still republishes")
do {
    let vm = makeVM()
    vm.messages[0].blocks.append(AssistantBlock(kind: "tool_use"))
    vm.messages[0].blocks[1].toolStatus = "running"
    var publishes = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.setStreamingUIUpdatesSuspended(true)          // e.g. a tool detail sheet
    vm.messages[0].blocks[1].toolStatus = "done"     // in-place: no @Published assignment
    vm.setStreamingUIUpdatesSuspended(false)
    pump()
    checkEq(vm.messages[0].blocks[1].toolStatus, "done", "the final tool status survives")
    checkEq(publishes, 1, "the republish happens with no value-based gating")
}

// MARK: - [8] A vm that dies before the hop is a no-op

print("\n[8] Deallocating the vm before the hop drops the notification safely")
do {
    var vm: StubVM? = makeVM()
    vm!.setStreamingUIUpdatesSuspended(true)
    vm!.setStreamingUIUpdatesSuspended(false)        // queues
    vm = nil
    checkEq(StubVM.liveInstances, 0, "the vm is really gone")
    pump()                                           // must not crash
    check(true, "the queued notification is a harmless no-op on a deallocated vm")
}

// MARK: - [9] A deferred entry whose block vanished (session reload) is skipped

print("\n[9] A deferred entry for a vanished block is dropped without losing the rest")
do {
    let vm = makeVM()
    let survivor = AssistantBlock(kind: "text")
    vm.messages[0].blocks.append(survivor)
    vm.isNearBottom = true
    vm.setStreamingUIUpdatesSuspended(true)
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 0, text: "gone",
                                    parsedMarkdown: nil, cacheAttributedString: false,
                                    requestScroll: false)
    vm.setStreamingTextBlockContent(msgIdx: 0, blockIdx: 1, text: "kept",
                                    parsedMarkdown: nil, cacheAttributedString: true,
                                    requestScroll: false)
    vm.messages[0].blocks.remove(at: 0)              // the first block disappears
    vm.setStreamingUIUpdatesSuspended(false)
    checkEq(vm.deferredStreamingTextUpdates.count, 0, "the queue is drained even with a stale entry")
    check(vm.messages[0].blocks.contains { $0.content == "kept" }, "the surviving entry is applied")
    checkEq(vm.scrollToBottomSignal.sendCount, 1, "the near-bottom scroll request is still made")
}

// MARK: - [10] No resume, no notification

print("\n[10] Resume calls that change nothing notify nothing")
do {
    let vm = makeVM()
    var publishes = 0
    vm.startObservingPublishes { publishes += 1 }
    vm.setStreamingUIUpdatesSuspended(false)         // already false
    vm.setSuspendedForTransition(false)              // already false
    pump()
    checkEq(publishes, 0, "idempotent resumes stay silent")
}

print("STREAMING_RESUME_PASS checks=\(checks)")
#if canImport(Combine)
print("STREAMING_RESUME_COMBINE_PASS checks=\(checks)")
#endif
