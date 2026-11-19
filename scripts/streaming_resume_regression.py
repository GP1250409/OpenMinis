#!/usr/bin/env python3
"""Build/run the streaming resume-notification regression.

[T-ios-streaming-resume-reentry] Freezes the 2026-11-19 status-bar teardown
crash (`dismantleUIViewController → finishStatusBarScrollToTop →
resumeAfterStatusBarScrollToTop → setStreamingUIUpdatesSuspended(false) →
objectWillChange.send → CachedViewModel forwarder → SwiftUI body re-entry →
swift_beginAccess exclusivity trap`).

This is NOT a static string search: the generator extracts the SHIPPING method
bodies from src/ios/Agent/Chat/AIChatViewModel+StreamingUI.swift

    scheduleStreamingResumeNotification
    clearStreamingUIUpdatesSuspended
    setStreamingUIUpdatesSuspended
    setSuspendedForTransition
    setStreamingTextBlockContent
    applyStreamingTextBlockContent
    flushDeferredStreamingTextUpdateIfNeeded

verbatim, drops only the `@MainActor` attribute (the harness class is not an
actor), and compiles them against the stubs in PRELUDE. The driver
(scripts/streaming-resume-tests/ResumeMain.swift) then drives the real bodies:
state synchrony, notification deferral out of the caller's stack, coalescing,
fire-time re-verification (re-suspend / session transition / deallocated vm),
deferred-text fidelity and the in-place tool-status republish.

Two queue flavours of the SAME assertions:
  * Linux  — `DispatchQueue.main.async` is rewritten to the drained
             `SliceMainQueue.async` (Linux Foundation's main queue is not
             drained by a script), so the suite runs on every platform and is
             the local gate;
  * Darwin — the real `DispatchQueue.main.async` + real Combine
             `ObservableObjectPublisher` are compiled and the main runloop is
             spun, which is what prints STREAMING_RESUME_COMBINE_PASS.

Markers (root delivery gate):
    STREAMING_RESUME_PASS checks=<n>            compiled production slice
    STREAMING_RESUME_COMBINE_PASS checks=<n>    Darwin: real Combine + GCD
    STREAMING_RESUME_WIRING_PASS checks=<n>     structural contract, frozen
                                                pre-fix negatives included
    STREAMING_RESUME_FAIL <reason>              any failure

usage: python3 scripts/streaming_resume_regression.py [--swiftc swiftc]
"""
from __future__ import annotations

import pathlib
import platform
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / 'scripts' / 'streaming-resume-tests'
PROD = ROOT / 'src/ios/Agent/Chat/AIChatViewModel+StreamingUI.swift'
VM = ROOT / 'src/ios/Agent/Chat/AIChatViewModel.swift'
# The crash stack's other three frames: they stay as they are — this regression
# pins that the fix is the VM's publish deferral, NOT deleting the teardown call,
# the resume edge or SwiftUI's own objectWillChange forwarder.
LIST = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/CollectionViewMessageListV3.swift'
DELEGATE = (ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator'
            / 'MessageListV3Coordinator+ScrollViewDelegate.swift')
CHAT_VIEW = ROOT / 'src/ios/Views/Chat/AIChatView/AIChatView.swift'
OUT = pathlib.Path(tempfile.mkdtemp(prefix='streaming-resume-'))

# Floors are the REVIEWED lower bound, never the observed value: the root gate
# re-parses the printed marker and holds it against these constants.
LOGIC_FLOOR = 46
WIRING_FLOOR = 20

EXTRACT = (
    'scheduleStreamingResumeNotification',
    'clearStreamingUIUpdatesSuspended',
    'setStreamingUIUpdatesSuspended',
    'setSuspendedForTransition',
    'setStreamingTextBlockContent',
    'applyStreamingTextBlockContent',
    'flushDeferredStreamingTextUpdateIfNeeded',
)


def fail(message: str) -> None:
    print('STREAMING_RESUME_FAIL ' + message)
    raise SystemExit(1)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print('+', ' '.join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, text=True, **kwargs)


def method_body(path: pathlib.Path, name: str) -> str:
    """Verbatim production body, from `func <name>(` to its matching brace."""
    text = path.read_text()
    needle = 'func ' + name + '('
    if needle not in text:
        fail(f'production method {name} not found in {path.name}')
    start = text.index(needle)
    brace = text.index('{', start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    fail(f'unbalanced method {name}')


PRELUDE = '''import Foundation
import Dispatch
#if canImport(Combine)
import Combine
#endif
#if canImport(Darwin)
import Darwin
#endif

// Deterministic main-queue dependency for the resume notification. On Linux the
// generator rewrites `DispatchQueue.main.async {` -> `SliceMainQueue.async {`
// (a script's main queue is not drained there); on Darwin the real GCD hop is
// kept, so the identical assertions below run through real Combine + GCD.
enum SliceMainQueue {
    static var pending: [() -> Void] = []
    static func async(execute work: @escaping () -> Void) { pending.append(work) }
    static func drain() {
        while !pending.isEmpty {
            let batch = pending
            pending.removeAll()
            for work in batch { work() }
        }
    }
}

#if os(Linux)
func pump() { SliceMainQueue.drain() }
#else
// Real GCD flavour (the macOS runner, where the same assertions must hold
// through real Combine): the production body queues on DispatchQueue.main, so
// enqueue a marker BEHIND it (FIFO) and let the main queue drain. The semaphore
// proves the notification has already run when the marker signals; the deadline
// only stops a broken queue plumbing from hanging the suite (the assertion that
// follows then fails honestly instead of blocking).
func pump() {
    // Watchdog: if the host's runloop ever stopped draining the main queue, the
    // deadline below could not be reached (RunLoop.run can block). SIGALRM ends
    // the process in 20 s instead of a hung CI job; the last PASS line still
    // names the assertion that was in flight.
    alarm(20)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { done.signal() }
    let deadline = Date(timeIntervalSinceNow: 5)
    while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    alarm(0)
}
#endif

#if !canImport(Combine)
/// Stand-in with the ONLY surface the production bodies use: `send()`.
final class StubWillChange {
    private(set) var sendCount = 0
    var onSend: (() -> Void)?
    func send() { sendCount += 1; onSend?() }
}
#endif

/// PassthroughSubject stand-in: `send()` / `send(value)`, counted.
final class StubSignal<Value> {
    private(set) var sendCount = 0
    private(set) var values: [Value] = []
    var onSend: ((Value) -> Void)?
    func send(_ value: Value) { sendCount += 1; values.append(value); onSend?(value) }
}
extension StubSignal where Value == Void {
    func send() { send(Void()) }
}

// --- production dependencies that are NOT part of the extracted bodies --------
struct MarkdownContent: Equatable {
    let text: String
    init(_ text: String) { self.text = text }
}
func prepareMarkdownForRender(_ text: String) -> String { text }

final class AssistantBlock {
    let id = UUID()
    var kind: String
    var content: String = ""
    var cachedMarkdown: MarkdownContent?
    var toolStatus: String = "pending"
    init(kind: String = "text") { self.kind = kind }
}
struct ChatMessage {
    let id = UUID()
    var blocks: [AssistantBlock] = []
}
struct DeferredStreamingTextUpdate {
    let messageId: UUID
    let blockId: UUID
    let text: String
    let parsedMarkdown: MarkdownContent?
    let cacheAttributedString: Bool
}
final class StreamingHangLogger {
    static let shared = StreamingHangLogger()
    private(set) var flushes = 0
    func recordStreamingFlush(messageId: UUID, blockId: UUID, text: String, finalFlush: Bool) {
        flushes += 1
    }
}
struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
    func debug(_ message: String) {}
}
private let logger = AppLogger(category: "AIChatVM")

final class StubVM {
#if canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    private var publishSink: AnyCancellable?
#else
    let objectWillChange = StubWillChange()
#endif
    static var liveInstances = 0

    var sessionId: String?
    var messages: [ChatMessage] = []
    var isNearBottom = false

    // The shipped suspend / resume state machine.
    var streamingUIUpdatesSuspended = false
    var transitionSuspended = false
    var streamingResumeNotificationScheduled = false
    var streamingResumeNotificationPending = false
    var needsSnapshotReloadOnResume = false
    var deferredStreamingTextUpdates: [DeferredStreamingTextUpdate] = []
    var onStreamingUIUpdatesResumed: (() -> Void)?
    let retrySnapshotReloadSignal = StubSignal<Void>()
    let scrollToBottomSignal = StubSignal<Void>()
    let blockContentFilledSignal = StubSignal<(messageId: UUID, blockId: UUID)>()

    private(set) var cacheCalls = 0

    init() { StubVM.liveInstances += 1 }
    deinit { StubVM.liveInstances -= 1 }

    func cacheAttributedString(for block: AssistantBlock) { cacheCalls += 1 }

    func startObservingPublishes(_ body: @escaping () -> Void) {
#if canImport(Combine)
        publishSink = objectWillChange.sink(receiveValue: { _ in body() })
#else
        objectWillChange.onSend = body
#endif
    }
    func startObservingReplay(_ body: @escaping () -> Void) {
        retrySnapshotReloadSignal.onSend = { _ in body() }
    }
}

extension StubVM {
'''


INLINE_QUEUE = '''enum SliceMainQueue {
    // SELF-TEST MUTATION: the "hop" runs synchronously on the caller's stack,
    // which is exactly what the pre-fix code did (hook + objectWillChange.send()
    // inline in setStreamingUIUpdatesSuspended). The driver MUST go red.
    static var pending: [() -> Void] = []
    static func async(execute work: @escaping () -> Void) { work() }
    static func drain() {}
}
'''

# The three assertions that exist because of the crash; a mutation that puts the
# notification back on the caller's stack must trip the first one.
SELFTEST_EXPECT = 'FAIL: no objectWillChange delivery inside the teardown frame'


def build_slice(inline_queue: bool = False) -> tuple[pathlib.Path, str]:
    work = OUT / ('slice-inline' if inline_queue else 'slice')
    work.mkdir(parents=True, exist_ok=True)
    bodies = []
    for name in EXTRACT:
        body = method_body(PROD, name)
        if 'func ' + name + '(' not in body:
            fail(f'extraction of {name} produced no function')
        bodies.append(body)
    methods = '\n\n'.join(bodies)
    # Only the actor attribute is dropped: the harness class is not actor
    # isolated, and `@MainActor` on the funcs would make the synchronous driver
    # calls nonisolated-context errors. Everything else is byte-identical.
    methods = re.sub(r'(?m)^\s*@MainActor\s*\n', '', methods)
    if '@MainActor' in methods:
        fail('an @MainActor survived extraction (inline form?)')
    if platform.system() != 'Darwin':
        # Linux: the main queue of a script process is not drained, so the ONE
        # queue dependency is swapped for the drained harness queue. The closure
        # body (the production notification) is untouched.
        if 'DispatchQueue.main.async {' not in methods:
            fail('the notification no longer hops on DispatchQueue.main.async — '
                 're-audit the deferral before changing this harness')
        methods = methods.replace('DispatchQueue.main.async {', 'SliceMainQueue.async {')
    prelude = PRELUDE
    if inline_queue:
        start = prelude.index('enum SliceMainQueue {')
        end = prelude.index('\n}\n', start) + 3
        prelude = prelude[:start] + INLINE_QUEUE + prelude[end:]
    slice_path = work / 'Slice.swift'
    slice_path.write_text(prelude + methods + '\n}\n')
    return slice_path, methods


def compile_and_run(swiftc: str, slice_path: pathlib.Path) -> int:
    driver = TESTS / 'ResumeMain.swift'
    if not driver.is_file():
        fail('driver scripts/streaming-resume-tests/ResumeMain.swift missing')
    main_path = OUT / 'main.swift'
    main_path.write_text(driver.read_text())
    exe = OUT / 'streaming-resume'
    result = run([swiftc, '-swift-version', '5', str(slice_path), str(main_path), '-o', str(exe)],
                 capture_output=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        fail('production slice compile failed')
    result = run([str(exe)], capture_output=True)
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        fail('production slice run failed')
    stdout = result.stdout
    match = re.search(r'STREAMING_RESUME_PASS checks=(\d+)', stdout)
    if not match:
        fail('production slice marker missing')
    checks = int(match.group(1))
    if checks < LOGIC_FLOOR:
        fail(f'checks {checks} < floor {LOGIC_FLOOR}')
    expected = re.findall(r'^PASS: ', stdout, re.M)
    if len(expected) != checks:
        fail(f'marker says {checks} but {len(expected)} PASS lines were printed')
    if 'STREAMING_RESUME_COMBINE_PASS checks=%d' % checks in stdout:
        print('STREAMING_RESUME_COMBINE just-ran platform=' + platform.system())
    else:
        print('STREAMING_RESUME_COMBINE_SKIP marker=Darwin-only platform=' + platform.system())
    return checks


# --- structural contract -----------------------------------------------------
# The compiled slice proves behaviour; this proves the RESUME SITES still route
# through the single deferred notification (a future edit could re-add an inline
# publish in one of the three callers and the driver would not see it, because
# it drives whatever the extracted bodies do).
FROZEN_CLEAR = '''
    private func clearStreamingUIUpdatesSuspended() {
        guard streamingUIUpdatesSuspended else { return }
        streamingUIUpdatesSuspended = false
        onStreamingUIUpdatesResumed?()
        if needsSnapshotReloadOnResume {
            needsSnapshotReloadOnResume = false
'''


def inline_hook_sites(body: str) -> int:
    return len(re.findall(r'(?<!self\.)onStreamingUIUpdatesResumed\?\(\)', body))


def inline_publish_sites(body: str) -> int:
    return len(re.findall(r'objectWillChange\.send\(\)', body))


def wiring_checks() -> int:
    checks = 0

    def case(cond: bool, name: str) -> None:
        nonlocal checks
        checks += 1
        if not cond:
            fail('wiring: ' + name)

    clear = method_body(PROD, 'clearStreamingUIUpdatesSuspended')
    suspend = method_body(PROD, 'setStreamingUIUpdatesSuspended')
    transition = method_body(PROD, 'setSuspendedForTransition')
    helper = method_body(PROD, 'scheduleStreamingResumeNotification')

    # 1-3. The chokepoint delegates, and the frozen pre-fix body is rejected.
    case('scheduleStreamingResumeNotification(caller: "clear")' in clear,
         'clearStreamingUIUpdatesSuspended queues the notification')
    case(inline_hook_sites(clear) == 0,
         'the chokepoint no longer calls the resume hook inline')
    case(inline_hook_sites(FROZEN_CLEAR) == 1,
         'frozen pre-fix chokepoint is rejected by the same detector')

    # 4-7. Both resume entry points route through it and publish nothing inline.
    case('scheduleStreamingResumeNotification(caller: "setStreamingUIUpdatesSuspended")' in suspend,
         'setStreamingUIUpdatesSuspended queues the republish')
    case(inline_publish_sites(suspend) == 0,
         'setStreamingUIUpdatesSuspended has no inline objectWillChange.send')
    case('scheduleStreamingResumeNotification(caller: "setSuspendedForTransition")' in transition,
         'setSuspendedForTransition queues the republish')
    case(inline_publish_sites(transition) == 0,
         'setSuspendedForTransition has no inline objectWillChange.send')

    # 8. The pre-fix cut (publish re-inserted at the exact anchor) IS flagged.
    prefix_suspend = suspend.replace(
        'scheduleStreamingResumeNotification(caller: "setStreamingUIUpdatesSuspended")',
        'objectWillChange.send()')
    case(inline_publish_sites(prefix_suspend) == 1,
         'the pre-fix inline publish is rejected by the same detector')

    # 9-10. The notification itself: weak self, and the gate re-checked twice
    # (at schedule time and again at fire time — the whole point of the hop).
    case('DispatchQueue.main.async { [weak self] in' in helper,
         'the notification holds self weakly')
    case(helper.count('guard !self.streamingUIUpdatesSuspended, !self.transitionSuspended else') == 1
         and 'guard !streamingUIUpdatesSuspended, !transitionSuspended else { return }' in helper,
         'the gate is verified at schedule time AND re-verified at fire time')

    # 11. The deferred loop-end replay is consumed after the fire-time gate, so a
    # superseded resume cannot eat it (the pre-fix code consumed it inline).
    gate = helper.index('guard !self.streamingUIUpdatesSuspended, !self.transitionSuspended else')
    replay = helper.index('self.needsSnapshotReloadOnResume = false')
    case(gate < replay, 'the replay flag is consumed only after the fire-time gate')

    # 12. Delivery order inside the notification: hook, replay, republish.
    hook_at = helper.index('self.onStreamingUIUpdatesResumed?()')
    retry_at = helper.index('self.retrySnapshotReloadSignal.send()')
    publish_at = helper.rindex('self.objectWillChange.send()')
    case(hook_at < retry_at < publish_at, 'delivery order is hook → replay → republish')

    # 13. The republish is unconditional: no guard may sit in front of it
    # (in-place tool-status mutations produce no @Published assignment, so a
    # dirty-bit / value comparison would silently drop the notification).
    case(not re.search(r'guard[^\n]*\n(?:[^\n]*\n){0,2}\s*self\.objectWillChange\.send\(\)', helper),
         'the republish is not gated behind a guard (no dirty-bit drop)')

    # 14. New state lives on the class, never in the extension (Swift rule).
    case('var streamingResumeNotificationScheduled = false' in VM.read_text()
         and 'var streamingResumeNotificationPending = false' in VM.read_text(),
         'the notification state is declared on AIChatViewModel')
    case(len(re.findall(r'(?m)^\s*var streamingResumeNotification', PROD.read_text())) == 0,
         'no stored property is declared in the extension file')

    # 15-16. Text state still lands BEFORE the notification in both resume paths.
    for name, body in (('setStreamingUIUpdatesSuspended', suspend),
                       ('setSuspendedForTransition', transition)):
        case(body.index('flushDeferredStreamingTextUpdateIfNeeded()')
             < body.index('clearStreamingUIUpdatesSuspended()')
             < body.index('scheduleStreamingResumeNotification('),
             f'{name} flushes the deferred text before clearing and notifying')

    # 17. The slice really carries production text (not a hand-written copy).
    text = PROD.read_text()
    case(text.count('scheduleStreamingResumeNotification(caller: "') == 3,
         'exactly three resume sites call the chokepoint')
    case(len(re.findall(r'private func scheduleStreamingResumeNotification\(caller: String\)',
                        text)) == 1,
         'the chokepoint is defined exactly once')
    # 18-20. The rest of the crash stack is UNTOUCHED by this fix.
    dismantle = method_body(LIST, 'dismantleUIViewController')
    case('coordinator.finishStatusBarScrollToTop(' in dismantle
         and 'reason: .viewDisappear' in dismantle,
         'dismantleUIViewController still ends the status-bar flight (crash frame kept)')
    resume = method_body(DELEGATE, 'resumeAfterStatusBarScrollToTop')
    case(resume.count('setStreamingUIUpdatesSuspended(false)') >= 1,
         'the resume still restores streaming (the crashed edge is preserved)')
    case('vm.objectWillChange' in CHAT_VIEW.read_text()
         and 'self?.objectWillChange.send()' in CHAT_VIEW.read_text(),
         'CachedViewModel still forwards objectWillChange (the fix is the deferral, '
         'not silencing the wrapper)')

    slice_text = (OUT / 'slice' / 'Slice.swift').read_text()
    case('[SuspendResume] notify caller=' in slice_text
         and 'self.onStreamingUIUpdatesResumed?()' in slice_text,
         'the compiled slice carries the production notification body verbatim')
    return checks


def self_test(swiftc: str) -> None:
    """Mutation self-test: with the hop made synchronous (the pre-fix shape) the
    suite must fail on the crash assertion itself, not merely 'somewhere'."""
    if platform.system() == 'Darwin':
        # The Darwin flavour uses the real DispatchQueue.main.async, which this
        # mutation does not touch; the Linux leg carries the sensitivity proof.
        print('STREAMING_RESUME_SELFTEST skip=Darwin-leg-uses-real-GCD platform=Darwin')
        return
    slice_path, _ = build_slice(inline_queue=True)
    driver = TESTS / 'ResumeMain.swift'
    self_test_dir = OUT / 'selftest'
    self_test_dir.mkdir(parents=True, exist_ok=True)
    main_path = self_test_dir / 'main.swift'   # top-level code needs the name
    main_path.write_text(driver.read_text())
    exe = OUT / 'streaming-resume-inline'
    result = run([swiftc, '-swift-version', '5', str(slice_path), str(main_path), '-o', str(exe)],
                 capture_output=True)
    if result.returncode != 0:
        print(result.stderr)
        fail('self-test slice compile failed')
    result = run([str(exe)], capture_output=True)
    output = (result.stdout or '') + (result.stderr or '')
    if result.returncode == 0:
        fail('self-test did not fail: a synchronous resume notification passed the suite')
    if SELFTEST_EXPECT not in output:
        print(output[-3000:])
        fail(f'self-test failed for the wrong reason (expected {SELFTEST_EXPECT!r})')
    print('STREAMING_RESUME_SELFTEST_PASS mutation=inline-notification assertion=teardown-frame')


def main() -> None:
    if not PROD.is_file():
        fail('production streaming-UI file missing')
    swiftc = 'swiftc'
    if '--swiftc' in sys.argv:
        swiftc = sys.argv[sys.argv.index('--swiftc') + 1]
    slice_path, _ = build_slice()
    wiring = wiring_checks()
    print(f'STREAMING_RESUME_WIRING_PASS checks={wiring}')
    checks = compile_and_run(swiftc, slice_path)
    self_test(swiftc)
    print(f'STREAMING_RESUME_REPORT logic={checks} wiring={wiring} platform={platform.system()}')
    print(f'STREAMING_RESUME_PASS checks={checks}')


if __name__ == '__main__':
    main()
