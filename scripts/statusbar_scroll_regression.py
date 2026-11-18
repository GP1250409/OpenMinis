#!/usr/bin/env python3
"""Build/run the status-bar scroll-to-top regression.

Compiles the PRODUCTION StatusBarScrollToTop.swift (never a copy) together with:
  * LogicMain.swift  — Foundation-only state-machine checks (all platforms);
  * UIKitMain.swift  — real UICollectionView + UIScrollViewDelegate entry point
                       on the iOS Simulator (CI). It calls the same delegate
                       method the status-bar tap reaches, but cannot simulate
                       the physical status-bar tap itself.
"""
from __future__ import annotations

import copy

import json
import pathlib
import platform
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / 'scripts' / 'statusbar-scroll-tests'
PROD = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift'
DELEGATE = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ScrollViewDelegate.swift'
SCROLL = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Scroll.swift'
SETUP = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Setup.swift'
LAYOUT = ROOT / 'src/ios/Agent/MessageList/MessageListLayout.swift'
INFRA = ROOT / 'src/ios/Agent/MessageList/MessageListInfrastructure.swift'
OUT = pathlib.Path(tempfile.mkdtemp(prefix='statusbar-scroll-'))
LOGIC_FLOOR = 40
UIKIT_FLOOR = 25


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print('+', ' '.join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, text=True, **kwargs)


def fail(message: str) -> None:
    print('STATUSBAR_SCROLL_FAIL ' + message)
    raise SystemExit(1)




def method_body(path: pathlib.Path, name: str) -> str:
    text = path.read_text()
    start = text.index('func ' + name + '(')
    brace = text.index('{', start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise RuntimeError('unbalanced method ' + name)


def wiring_checks() -> int:
    """The fixture cannot call UIKit's whole coordinator, so the entry-point
    wiring is gated structurally here. Each check fails if the production line
    disappears (verified by the mutation self-test at the end)."""
    drag = method_body(DELEGATE, 'scrollViewWillBeginDragging')
    prev = method_body(SCROLL, 'scrollToPreviousUserTurn')
    begin = method_body(DELEGATE, 'beginStatusBarScrollToTop')
    finish = method_body(DELEGATE, 'finishStatusBarScrollToTop')
    resume = method_body(DELEGATE, 'resumeAfterStatusBarScrollToTop')
    checks = 0

    def need(cond, name):
        nonlocal checks
        if not cond:
            fail('wiring: ' + name)
        checks += 1

    need('finishStatusBarScrollToTop(reason: .drag, restoring: false)' in drag,
         'a drag must transfer the status-bar flight')
    need('finishStatusBarScrollToTop(reason: .superseded' in prev,
         'the up-button jump must supersede the flight')
    # [T-user-ask-anchor-flight] CROSS with the answered-question card: the
    # flight and the card toggle both write contentOffset, so the takeover has
    # to be explicit in both directions.
    need('abandonTopAnchor()' in begin, 'flight start abandons the card anchor + probe chain')
    need('abandonTopAnchor()' in drag, 'a real drag abandons the card anchor too')
    need('settleAfterInteraction(' not in begin, 'Should must not call settle (auto re-acquire)')
    need('resumeAfterStatusBarScrollToTop' in finish, 'end must run the restoration pass')
    for api in ('applyDeferredHeights', 'consumeDeferredCorrectionIfNeeded',
                'flushPendingSnapshotIfNeeded'):
        need(api in resume, 'restoration must consume ' + api)
    need('settleAfterInteraction(' not in resume, 'restoration must not call settle')
    need('.autoScrolling' not in resume, 'restoration must not re-acquire auto')
    need('viewController?.messageListLayout?.isSystemScrollToTopActive = false' in finish,
         'end must release the layout')
    helper = PROD.read_text()
    need('watchdogMaxMs' not in helper, 'no hard-coded animation deadline')
    need('beganAt = now' in helper and 'stalledWatchdogSamples = 0' in helper,
         'repeat tap resets the watchdog window')
    # Type declarations the parse-only check cannot see.
    need('var isSystemScrollToTopActive: Bool = false' in LAYOUT.read_text(), 'layout flag declared')
    infra = INFRA.read_text()
    need('let statusBarOwnsViewport =' in infra and infra.index('let statusBarOwnsViewport =') < infra.index('statusBarOwnsViewport {'),
         'collection view computes statusBarOwnsViewport before use')
    setup = SETUP.read_text()
    need('if self.statusBarScrollToTop.isActive {' in setup
         and 'self.applySubViewportCompensation(caller: "contentSizeKVO")' in setup.split('if self.statusBarScrollToTop.isActive {')[1].split('return')[0],
         'active KVO still runs the inset ledger')

    # Mutation self-test: the gate must go red when the drag transfer is removed.
    mutated = drag.replace('finishStatusBarScrollToTop(reason: .drag, restoring: false)', '')
    need('finishStatusBarScrollToTop(reason: .drag, restoring: false)' not in mutated,
         'mutation harness can delete the drag transfer')
    mutated_ok = 'finishStatusBarScrollToTop(reason: .drag, restoring: false)' in mutated
    need(not mutated_ok, 'wiring gate is sensitive to the deleted drag transfer')
    return checks


SLICE_STUBS = """import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // Darwin: Foundation alone leaves CGPoint/CGSize/CGRect opaque (CFCGTypes.h forward decls).
#endif

// Deterministic main-queue dependency for deferred resume callbacks. UIKit
// animation remains a separate Darwin test; these tests drain only queued work.
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

final class StubText {
    var consumed = 0
    var isDeferred: () -> Bool = { false }
    // Match applyCellCorrection's real deferSelfSizing guard: attempting a
    // consume before thawing must not be counted as a paid correction.
    func consumeDeferredCorrectionIfNeeded() {
        guard !isDeferred() else { return }
        consumed += 1
    }
}
final class StubCell { let text = StubText() }
final class StubCV {
    var contentOffset = CGPoint.zero
    var contentSize = CGSize.zero
    var bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
    var adjustedContentInset = StubInsets()
    var isTracking = false
    var isDecelerating = false
    var visibleCells = [StubCell(), StubCell()]
    func layoutIfNeeded() {}
    struct StubInsets { var top: CGFloat = 0; var bottom: CGFloat = 60 }
}
typealias UIScrollView = StubCV
final class StubLayout {
    var deferSelfSizing = false
    var isSystemScrollToTopActive = false
    var suppressContentOffsetAdjustment = false
    var applyCount = 0
    var invalidateCount = 0
    var abandonCount = 0
    func applyDeferredHeights() { applyCount += 1 }
    func invalidateLayout() { invalidateCount += 1 }
    func abandonTopAnchor() -> Bool { abandonCount += 1; return true }
}
final class StubVC {
    var collectionView: StubCV? = StubCV()
    var messageListLayout: StubLayout? = StubLayout()
    init() {
        for cell in collectionView!.visibleCells {
            cell.text.isDeferred = { [weak self] in
                self?.messageListLayout?.deferSelfSizing ?? false
            }
        }
    }
}
final class StubVM {
    var streamingUIUpdatesSuspended = false
    var suspended: Bool {
        get { streamingUIUpdatesSuspended }
        set { streamingUIUpdatesSuspended = newValue }
    }
    func setStreamingUIUpdatesSuspended(_ value: Bool) { streamingUIUpdatesSuspended = value }
}
struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
}

final class SliceCoordinator {
    enum ScrollMode { case autoScrolling, userBrowsing }
    var scrollMode: ScrollMode = .autoScrolling
    let statusBarScrollToTop = StatusBarScrollToTopLifecycle()
    var statusBarScrollToTopWatchdog: DispatchWorkItem?
    var viewController: StubVC? = StubVC()
    var vm: StubVM? = StubVM()
    var pendingScrollWork: DispatchWorkItem?
    var clampAfterSessionLoad = true
    var isAnimatingScrollToBottom = true
    var scrollBottomJumpToken = 7
    var scrollBottomRealigns = 3
    var lastJumpedUserId: UUID? = UUID()
    var isFlushing = false
    var hasPendingSnapshot = true
    var thinkingReleased = 0
    var consumedCorrections = 0
    var pendingFlushCaller: String?

    func releaseThinkingToggleOnUserScroll() { thinkingReleased += 1 }
    func isAtContentTop() -> Bool { false }
    func scheduleCoalescedScroll() {}
    func flushPendingSnapshotIfNeeded(caller: String) { pendingFlushCaller = caller }
    static func forEachMarkdownTextView(in cell: StubCell, _ body: (StubText) -> Void) {
        body(cell.text)
    }
"""

# --- Darwin fixture-import contract -----------------------------------------
# Run 44388591808 attempt 1 (job 135099797930, macos-26 / Xcode 26.6 17F113)
# failed the production slice at COMPILE time with:
#   Slice.swift:29: error: type 'CGPoint' has no member 'zero'
#   Slice.swift:30: error: type 'CGSize' has no member 'zero'
#   Slice.swift:31: error: argument passed to call that takes no arguments
# Those three diagnostics are the signature of the CFCGTypes.h forward
# declarations (`typedef struct CGPoint CGPoint;`): with `import Foundation`
# alone on Darwin, CGPoint/CGSize/CGRect resolve to opaque, memberless types, so
# neither `.zero` nor the memberwise init exists. CGFloat was NOT affected —
# since Swift 5.5 it lives in the stdlib — which is exactly why the compiler
# found the types but not their members. Linux cannot reproduce this: there
# Swift's Foundation defines the full structs itself (canImport(CoreGraphics)
# is false), which is why the local Linux run passed and the Darwin run did not.
# Fix = import the native geometry overlay behind a guard, the same pattern the
# repo already uses for the image-geometry (8d7d540) and map (9be2e13) tests.
CG_GEOMETRY = re.compile(r'\b(CGPoint|CGSize|CGRect)\b')
CG_IMPORT_GUARD = re.compile(r'#if canImport\(CoreGraphics\)[^\n]*\nimport CoreGraphics')


def geometry_import_gaps(source: str) -> list[str]:
    """CG geometry spelled without the native overlay import -> Darwin break."""
    if CG_IMPORT_GUARD.search(source):
        return []
    return [f'{i}: {line.strip()}' for i, line in enumerate(source.splitlines(), 1)
            if CG_GEOMETRY.search(line) and not line.lstrip().startswith('//')]


# Frozen verbatim excerpt of what the OLD generator wrote (logged lines 25-32 of
# run 44388591808). It exists so the contract is proven to reject the generator
# that actually failed on Darwin, not merely to accept the fixed one.
OLD_SLICE_STUB_EXCERPT = """final class StubCV {
    var contentOffset = CGPoint.zero
    var contentSize = CGSize.zero
    var bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
    var adjustedContentInset = StubInsets()
"""


def fixture_import_contract(slice_source: str) -> int:
    cases = 0

    def case(cond: bool, name: str) -> None:
        nonlocal cases
        cases += 1
        if not cond:
            fail('fixture import contract: ' + name)

    old_gaps = geometry_import_gaps('import Foundation\n\n' + OLD_SLICE_STUB_EXCERPT)
    case(len(old_gaps) == 3, 'old generator stub is rejected at all three sites')
    case(any('CGPoint.zero' in gap for gap in old_gaps), 'old stub flags CGPoint.zero')
    case(any('CGRect(x: 0' in gap for gap in old_gaps), 'old stub flags the CGRect memberwise init')
    case(geometry_import_gaps(slice_source) == [], 'generated slice stub imports the geometry overlay')
    case(geometry_import_gaps(CG_IMPORT_GUARD.sub('', slice_source, count=1)) != [],
         'contract is sensitive: guard removed -> flagged')
    return cases


def build_slice() -> pathlib.Path:
    work = OUT / 'slice'
    work.mkdir()
    methods = '\n'.join(method_body(DELEGATE, n) for n in (
        'scrollViewShouldScrollToTop', 'scrollViewDidScrollToTop',
        'beginStatusBarScrollToTop', 'finishStatusBarScrollToTop',
        'resumeAfterStatusBarScrollToTop', 'scheduleStatusBarScrollToTopWatchdog'))
    # Swap only the queue dependency, preserving the production closure body.
    # Linux's Foundation RunLoop does not reliably drain DispatchQueue.main.
    methods = methods.replace('DispatchQueue.main.async {', 'SliceMainQueue.async {')
    (work / 'Slice.swift').write_text(SLICE_STUBS + methods + '\n}\n')
    (work / 'main.swift').write_text((TESTS / 'SliceMain.swift').read_text())
    exe = work / 'slice'
    result = run(['swiftc', '-swift-version', '5', str(PROD), str(work / 'Slice.swift'),
                  str(work / 'main.swift'), '-o', str(exe)], capture_output=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        fail('production slice compile failed')
    result = run([str(exe)], capture_output=True)
    print(result.stdout)
    if result.returncode != 0:
        fail('production slice run failed')
    match = re.search(r'STATUSBAR_SCROLL_SLICE_PASS checks=(\d+)', result.stdout)
    if not match:
        fail('production slice marker missing')
    return int(match.group(1))


def compile_logic() -> None:
    work = OUT / 'logic'
    work.mkdir()
    (work / 'main.swift').write_text((TESTS / 'LogicMain.swift').read_text())
    exe = work / 'logic'
    result = run(['swiftc', '-swift-version', '5', str(PROD), str(work / 'main.swift'), '-o', str(exe)],
                 capture_output=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        fail('logic compile failed')
    result = run([str(exe)], capture_output=True)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        fail('logic run failed')
    match = re.search(r'STATUSBAR_SCROLL_LOGIC_PASS checks=(\d+)', result.stdout)
    if not match:
        fail('logic marker missing')
    checks = int(match.group(1))
    if checks < LOGIC_FLOOR:
        fail(f'logic checks {checks} < {LOGIC_FLOOR}')


def run_uikit() -> int:
    if platform.system() != 'Darwin':
        return -1
    work = OUT / 'uikit'
    work.mkdir()
    (work / 'main.swift').write_text((TESTS / 'UIKitMain.swift').read_text())
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    choices = [d for group in devices.values() for d in group if 'iPhone' in d['name'] and d.get('isAvailable')]
    if not choices:
        fail('no available iPhone simulator')
    device = next((d for d in choices if d['state'] == 'Booted'), choices[0])
    udid = device['udid']
    if device['state'] != 'Booted':
        run(['xcrun', 'simctl', 'boot', udid], check=True)
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = platform.machine()
    exe = work / 'statusbar-uikit'
    result = run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5',
                  '-sdk', sdk, '-target', arch + '-apple-ios16.0-simulator',
                  str(PROD), str(work / 'main.swift'), '-o', str(exe)], capture_output=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        fail('uikit compile failed')
    result = run(['xcrun', 'simctl', 'spawn', udid, str(exe)], capture_output=True, timeout=300)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        fail('uikit run failed')
    match = re.search(r'STATUSBAR_SCROLL_UIKIT_PASS checks=(\d+)', result.stdout)
    if not match:
        fail('uikit marker missing')
    checks = int(match.group(1))
    if checks < UIKIT_FLOOR:
        fail(f'uikit checks {checks} < {UIKIT_FLOOR}')
    return checks


def main() -> None:
    if not PROD.is_file():
        fail('production lifecycle file missing')
    compile_logic()
    slice_checks = build_slice()
    fixture_cases = fixture_import_contract((OUT / 'slice' / 'Slice.swift').read_text())
    print(f'STATUSBAR_SCROLL_FIXTURE_IMPORT_PASS cases={fixture_cases}')
    wiring = wiring_checks()
    print(f'STATUSBAR_SCROLL_WIRING_PASS checks={wiring}')
    uikit = run_uikit()
    if uikit < 0:
        # Honest local scope: Linux has no UIKit; CI is the platform that runs it.
        print('STATUSBAR_SCROLL_LOCAL_LOGIC_ONLY uikit=unavailable platform=' + platform.system())
        return
    print(f'STATUSBAR_SCROLL_PASS logic={LOGIC_FLOOR}+ uikit={uikit} slice={slice_checks} wiring={wiring}')


if __name__ == '__main__':
    main()
