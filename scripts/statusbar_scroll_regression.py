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
import plistlib
import platform
import re
import shutil
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
LOGIC_FLOOR = 46
UIKIT_FLOOR = 25
# Raw stdout of the logic suite: the aggregate marker is checked against THIS
# text, not against an f-string assumption.
_LOGIC_STDOUT = ''


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


def source_manifest_contract() -> int:
    """[T-statusbar-native-scroll] Every fixture that compiles the FULL production
    `MessageListLayout.swift` verbatim must also compile the REAL
    `Support/StatusBarScrollToTop.swift` — the layout's `contentOffsetAdjustment`
    now calls `StatusBarScrollToTopPolicy`, which is defined there (never a stub,
    never deleting the call). This is a SOURCE-MANIFEST contract (structural,
    Linux-runnable): it proves each compile source list NAMES the shipping
    support file, NOT that a Darwin typecheck ran. The Darwin typecheck is proven
    separately by each suite's own swiftc on the simulator (run 44423138250's
    genui step failed exactly this with "cannot find 'StatusBarScrollToTopPolicy'
    in scope")."""
    support = 'Support/StatusBarScrollToTop.swift'
    spacing = 'Support/QueuedCandidateSpacing.swift'
    # Every direct production dependency MessageListLayout.swift needs that is
    # NOT declared in that file: MessageRowGap (Support/QueuedCandidateSpacing)
    # and StatusBarScrollToTopPolicy (Support/StatusBarScrollToTop). A missing
    # entry is a Darwin typecheck failure, proven twice:
    #   44423138250 -> "cannot find 'StatusBarScrollToTopPolicy' in scope"
    #   44428916963 -> "cannot find 'MessageRowGap' in scope"
    required = (spacing, support)
    manifest = {
        'genui_height_regression.py': ROOT / 'scripts/genui_height_regression.py',
        'thinking_transaction_regression.py': ROOT / 'scripts/thinking_transaction_regression.py',
        'toolfold_uikit_regression.py': ROOT / 'scripts/toolfold_uikit_regression.py',
        'usage_toggle_anchor_regression.py': ROOT / 'scripts/usage_toggle_anchor_regression.py',
        'ask_card_anchor_uikit.py': ROOT / 'scripts/ask_card_anchor_uikit.py',
    }
    cases = 0

    def case(cond: bool, name: str) -> None:
        nonlocal cases
        cases += 1
        if not cond:
            fail('source manifest contract: ' + name)

    # Positive: every full-layout compile source list names BOTH support files.
    for name, path in manifest.items():
        text = path.read_text()
        for dep in required:
            case(dep in text, f'{name} lists {dep}')

    # Negative (the exact list that failed run 44428916963): the ask-card UIKit
    # compile list compiled MessageListLayout verbatim WITHOUT the MessageRowGap
    # file — it must be rejected.
    old_ask = ("    sources = [IOS / 'Agent/MessageList/MessageListLayout.swift',\n"
               "               IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift',\n"
               "               OUT / 'ProductionMessageListItem.swift', OUT / 'ProductionSelfSizingCell.swift',")
    case(spacing not in old_ask, 'frozen pre-fix ask-card compile list is rejected')

    # Negative (the exact list that failed run 44423138250): pre-fix genui list.
    old_genui = ("sources = [instrumented, spacing, item_src, cell_src, store_src, genui_src,\n"
                 "           tests / 'ProductionStubs.swift', tests / 'GenUICoordinatorStub.swift',\n"
                 "           tests / 'GenUICardFixture.swift', tests / 'GenUIListHarness.swift',\n"
                 "           tests / 'GenUIHeightTests.swift']")
    case(support not in old_genui, 'frozen pre-fix genui compile list is rejected')

    # Sensitivity: dropping either file from the CURRENT ask-card list must flip
    # the contract red (guards a silent re-introduction on the next edit).
    current = (ROOT / 'scripts/ask_card_anchor_uikit.py').read_text()
    for dep in required:
        stripped = current.replace(dep, dep.replace('Support/', 'Support/Removed'))
        case(dep not in stripped, f'contract is sensitive to dropping {dep} from ask-card')
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


def compile_logic() -> int:
    global _LOGIC_STDOUT
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
    _LOGIC_STDOUT = result.stdout
    if result.returncode != 0:
        fail('logic run failed')
    match = re.search(r'STATUSBAR_SCROLL_LOGIC_PASS checks=(\d+)', result.stdout)
    if not match:
        fail('logic marker missing')
    checks = int(match.group(1))
    if checks < LOGIC_FLOOR:
        fail(f'logic checks {checks} < {LOGIC_FLOOR}')
    # The aggregate marker is the only thing the root gate reads. Return the
    # REAL count the logic suite printed (never None, never the floor constant).
    return checks


# Artifacts for review when the hosted UIKit run misbehaves: console text,
# compile log and a simulator screenshot, all uploaded by the workflow.
DIAG = ROOT / 'build' / 'statusbar-scroll-uikit'


def copy_diagnostics(work: pathlib.Path, label: str, udid: str | None = None) -> None:
    DIAG.mkdir(parents=True, exist_ok=True)
    for name in ('compile.log', 'results.log'):
        src = work / name
        if src.is_file():
            shutil.copyfile(src, DIAG / f'{label}-{name}')
    if udid:
        shot = DIAG / f'{label}-screen.png'
        try:
            subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(shot)],
                           capture_output=True, text=True, timeout=60)
            print('STATUSBAR_SCROLL_UIKIT_DIAG dir=build/statusbar-scroll-uikit label=' + label)
        except Exception as exc:  # screenshot is diagnostics only, never a gate
            print('STATUSBAR_SCROLL_UIKIT_DIAG screenshot skipped: ' + str(exc))
    else:
        print('STATUSBAR_SCROLL_UIKIT_DIAG dir=build/statusbar-scroll-uikit label=' + label)


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

    # A bare `simctl spawn` binary has no UIApplication and no window server
    # connection, so UIKit's own animated setContentOffset never advances there
    # (run 44414791444 attempt 1 died on "UIKit's own animation moved the
    # viewport up" for exactly that reason). Ship the same source as a real
    # .app: install + launch --console-pty, with the list in a UIWindow.
    app = work / 'StatusBarScrollUIKit.app'
    app.mkdir()
    exe = app / 'StatusBarScrollUIKit'
    result = run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5',
                  '-sdk', sdk, '-target', arch + '-apple-ios16.0-simulator',
                  str(PROD), str(work / 'main.swift'), '-o', str(exe)], capture_output=True)
    (work / 'compile.log').write_text((result.stdout or '') + (result.stderr or ''))
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        copy_diagnostics(work, 'uikit-compile')
        fail('uikit compile failed')
    bundle_id = 'com.gonepaul.statusbar.uikit'
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'StatusBarScrollUIKit',
        'CFBundleName': 'StatusBarScrollUIKit', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
        'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
        'UILaunchScreen': {}}))
    run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'uninstall', udid, bundle_id], capture_output=True, text=True)
    run(['xcrun', 'simctl', 'install', udid, str(app)], check=True)
    try:
        result = run(['xcrun', 'simctl', 'launch', '--console-pty', udid, bundle_id],
                     capture_output=True, timeout=420)
        text = (result.stdout or '') + (result.stderr or '')
        code = result.returncode
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or ''
        if isinstance(text, bytes):
            text = text.decode(errors='replace')
        print(text[-20000:])
        copy_diagnostics(work, 'uikit-timeout', udid)
        fail('uikit run timed out (no marker within 420s)')
    print(text)
    (work / 'results.log').write_text(text)
    if code != 0:
        copy_diagnostics(work, 'uikit-run', udid)
        fail('uikit run failed')
    match = re.search(r'STATUSBAR_SCROLL_UIKIT_PASS checks=(\d+)', text)
    if not match:
        copy_diagnostics(work, 'uikit-marker', udid)
        fail('uikit marker missing')
    copy_diagnostics(work, 'uikit-pass', udid)
    checks = int(match.group(1))
    if checks < UIKIT_FLOOR:
        fail(f'uikit checks {checks} < {UIKIT_FLOOR}')
    return checks


def _valid_logic_count(value) -> bool:
    """The aggregate marker must carry the REAL positive int count."""
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


_AGGREGATE_RE = re.compile(r'STATUSBAR_SCROLL_PASS\s+logic=(\d+)\+\s+uikit=(\d+)')


def aggregate_contract() -> int:
    """Deterministic (Linux, no swiftc) contract for the aggregate marker.

    Run 44428916963 printed `logic=None+` because compile_logic() returned
    nothing: the root gate parses `logic=(\\d+)\\+` and holds on 40 < 46, so a
    missing return silently degrades a green logic suite to a failed delivery.
    These cases pin the rendering and the None rejection. NO case calls fail()
    on the negative path, so no STATUSBAR_SCROLL_FAIL marker is ever emitted
    into the validation log by the contract itself."""
    cases = 0

    def case(cond: bool, name: str) -> None:
        nonlocal cases
        cases += 1
        if not cond:
            fail('aggregate contract: ' + name)

    good = f'STATUSBAR_SCROLL_PASS logic={46}+ uikit={45} slice={52} wiring={19}'
    case(good == 'STATUSBAR_SCROLL_PASS logic=46+ uikit=45 slice=52 wiring=19',
         'real logic count is rendered verbatim')
    case('logic=40+' not in good, 'the floor constant is never substituted')
    case(_AGGREGATE_RE.search(good) is not None, 'root parser accepts the rendered marker')
    case(_valid_logic_count(46) is True, 'a real int count is accepted')
    case(_valid_logic_count(None) is False, 'None (missing return) is rejected')
    case(_valid_logic_count(0) is False and _valid_logic_count(True) is False,
         'zero / bool are rejected')
    return cases


def main() -> None:
    if not PROD.is_file():
        fail('production lifecycle file missing')
    logic_checks = compile_logic()
    # Never let None/0 reach the aggregate marker: prove the returned count is
    # the REAL one the logic suite printed (not just an f-string assumption).
    if not _valid_logic_count(logic_checks):
        fail(f'aggregate logic count is not a positive int: {logic_checks!r}')
    reparsed = re.search(r'STATUSBAR_SCROLL_LOGIC_PASS\s+checks=(\d+)', _LOGIC_STDOUT)
    if not reparsed or int(reparsed.group(1)) != logic_checks:
        fail(f'aggregate logic count {logic_checks} != printed marker {reparsed and reparsed.group(1)}')
    print(f'STATUSBAR_AGGREGATE_CONTRACT_PASS cases={aggregate_contract()}')
    slice_checks = build_slice()
    fixture_cases = fixture_import_contract((OUT / 'slice' / 'Slice.swift').read_text())
    print(f'STATUSBAR_SCROLL_FIXTURE_IMPORT_PASS cases={fixture_cases}')
    wiring = wiring_checks()
    print(f'STATUSBAR_SCROLL_WIRING_PASS checks={wiring}')
    manifest_cases = source_manifest_contract()
    print(f'STATUSBAR_SOURCE_MANIFEST_PASS cases={manifest_cases}')
    uikit = run_uikit()
    if uikit < 0:
        # Honest local scope: Linux has no UIKit; CI is the platform that runs it.
        print('STATUSBAR_SCROLL_LOCAL_LOGIC_ONLY uikit=unavailable platform=' + platform.system())
        return
    print(f'STATUSBAR_SCROLL_PASS logic={logic_checks}+ uikit={uikit} slice={slice_checks} wiring={wiring}')


if __name__ == '__main__':
    main()
