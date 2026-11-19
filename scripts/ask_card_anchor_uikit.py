#!/usr/bin/env python3
"""Real UIKit fixture for the answered-question card toggle (iOS simulator).

Compiles, VERBATIM from the shipping sources:
  * `src/ios/Agent/MessageList/MessageListLayout.swift`
    (layout, `ToggleAnchorMath`, token-owned top anchor),
  * `SelfSizingCell` + `MessageListItem` slices out of `MessageListInfrastructure.swift`,
  * the `func remeasureKeepingTop(` … `func verifyToggledHeight(` … block out of
    `MessageListV3Coordinator+ToolFolding.swift`, wrapped in
    `extension CollectionViewMessageListV3.Coordinator` and driven through the
    fixture coordinator in `scripts/thinking-transaction-tests/TxCoordinatorStub.swift`
    (the same stub the thinking/session harness uses),
  * the SHIPPING Objective-C exception guard `noff_try_objc` out of
    `src/ios/NativeOffloads/NativeOffloadUtils.m` (declaration lifted from
    `NativeOffloadUtils.h`, exposed through `-import-objc-header` and linked as
    a compiled `.o`) — `SelfSizingCell.preferredLayoutAttributesFitting` and its
    explicit measure both run inside it; a Swift re-implementation is rejected
    by the closure audit below, because it would swallow the NSException.
Only the CARD and TOOL-GROUP content views are fixture SwiftUI (`AskCardUIKitHarness`);
the toggle path, the layout, the anchor math and the exception guard are the app's own code.

Host: `AskCardUIKitMain.swift` is a real `UIApplicationDelegate` app (the same shape
as the already-green Thinking/GenUI/toolfold UIKit drivers). The generated
`main.swift` that only did `import UIKit; runAskCardUIKitCases()` is GONE: an app
bundle that never calls `UIApplicationMain` never checks in with SpringBoard, and
the seven cases pump ~19s of wall clock — inside the 20s launch watchdog
(0x8badf00d), i.e. a mid-suite kill with no marker.

Cases (see AskCardAnchorUIKitTests.swift): collapse above a collapsed group,
collapse above an expanded group, 6-round trip mid-list, rapid double tap,
drag in flight, snapshot/session swap right after a toggle.
Prints `ASK_CARD_ANCHOR_UIKIT_PASS cases=7 checks=<n> png=<n>` and writes the
PNGs to `build/ask-card-uikit/`.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/ask-card-uikit'
OUT.mkdir(parents=True, exist_ok=True)
APP = OUT / 'AskCardAnchorUIKit.app'
TESTS = ROOT / 'scripts/ask-card-anchor-tests'
THINK = ROOT / 'scripts/thinking-transaction-tests'
IOS = ROOT / 'src/ios'
NATIVE = IOS / 'NativeOffloads'
FOLD = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift'
SUPPORT = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support'


def note(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, **kw)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f'extraction failed: end marker not found ({label})')
    return text[i:j]


# ---------------------------------------------------------------------------
# [T-ask-fixture-build] Complete compile closure
#
# run 44431220135 (SHA 84578ff) failed the ask-card UIKit list with
#   ProductionSelfSizingCell.swift:316/387: cannot find 'noff_try_objc' in scope
# because this driver alone compiled the real `SelfSizingCell` slice without the
# production Objective-C guard the other four fixtures already lift. The answer
# is not "add one more file": the closure is now DERIVED — every compiled source
# is scanned for the cross-file symbols it uses, and each of them must be
# satisfied by its one legal provider. The same function powers the frozen
# negative cases below, so a missing dependency cannot come back silently.
# ---------------------------------------------------------------------------
class Dependency:
    def __init__(self, symbol, kind, provider, declaration):
        self.symbol = symbol
        self.kind = kind              # 'swift' | 'objc'
        self.provider = provider      # path relative to src/ios
        self.declaration = declaration


DEPENDENCIES = (
    # MessageListLayout.swift's vertical rhythm (line ~433): declared in
    # Support/QueuedCandidateSpacing.swift. Proven by run 44428916963.
    Dependency('MessageRowGap', 'swift',
               'Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift',
               r'\benum MessageRowGap\b'),
    # MessageListLayout's contentOffsetAdjustment: Support/StatusBarScrollToTop.swift.
    # Proven by run 44423138250.
    Dependency('StatusBarScrollToTopPolicy', 'swift',
               'Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift',
               r'\benum StatusBarScrollToTopPolicy\b'),
    # The anchor math the fixture drives lives in MessageListLayout.swift itself.
    Dependency('ToggleAnchorMath', 'swift',
               'Agent/MessageList/MessageListLayout.swift',
               r'\benum ToggleAnchorMath\b'),
    # `noff_try_objc` is C/ObjC, not Swift: the ONLY legal provider is the
    # shipping function, exposed by the bridge header and linked as a .o.
    Dependency('noff_try_objc', 'objc',
               'NativeOffloads/NativeOffloadUtils.m',
               r'BOOL noff_try_objc\(void \(NS_NOESCAPE \^_Nonnull block\)\(void\)\);'),
)

FAKE_SWIFT_GUARD = re.compile(r'\bfunc\s+noff_try_objc\s*\(')


class Bridge:
    def __init__(self, header, source, obj, decl, fn):
        self.header = header
        self.source = source
        self.obj = obj
        self.decl = decl
        self.fn = fn


def production_bridge():
    """Lift the SHIPPING exception guard, byte for byte.

    Same construction as thinking_transaction_regression.py /
    genui_height_regression.py / toolfold_uikit_regression.py /
    usage_toggle_anchor_regression.py (all green on Darwin): only the
    independent C function is lifted; the rest of the native offload
    implementation depends on the full app/iSH runtime.
    """
    impl_text = (NATIVE / 'NativeOffloadUtils.m').read_text()
    start = impl_text.find('BOOL noff_try_objc(')
    end = impl_text.find('// ── Calling session', start) if start >= 0 else -1
    if start < 0 or end < 0:
        raise SystemExit('extraction failed: noff_try_objc not found in NativeOffloadUtils.m')
    fn = impl_text[start:end]
    # The lifted body must really catch: a no-op would silently swallow the
    # protection the shipping cell relies on.
    for token in ('@try {', '@catch (NSException', 'return NO;'):
        if token not in fn:
            raise SystemExit('production guard lost its protection: ' + token)
    decl = next((line for line in (NATIVE / 'NativeOffloadUtils.h').read_text().splitlines()
                 if line.startswith('BOOL noff_try_objc(')), None)
    if decl is None:
        raise SystemExit('extraction failed: noff_try_objc declaration not found in NativeOffloadUtils.h')
    header = OUT / 'ExceptionBridge.h'
    source = OUT / 'ExceptionBridge.m'
    obj = OUT / 'ExceptionBridge.o'
    header.write_text('#import <Foundation/Foundation.h>\n' + decl + '\n')
    source.write_text('#import "ExceptionBridge.h"\n' + fn)
    return Bridge(header=header, source=source, obj=obj, decl=decl, fn=fn)


def compile_bridge(bridge, sdk, arch):
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-fobjc-arc', '-fblocks',
           '-isysroot', sdk, '-target', f'{arch}-apple-ios16.0-simulator',
           '-c', str(bridge.source), '-o', str(bridge.obj)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (OUT / 'objc-bridge.log').write_text(r.stdout)
    if r.returncode:
        note(r.stdout)
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL production ObjC exception guard did not compile')
    note('PRODUCTION_EXCEPTION_BRIDGE_OK noff_try_objc')


def source_manifest(block):
    """The ONE list shared by the closure audit and the swiftc command."""
    return [
        ('layout', IOS / 'Agent/MessageList/MessageListLayout.swift'),
        # [T-user-ask-anchor-flight] The shipping flight state machine: the
        # toggle path ends a live flight, so the fixture must drive the real
        # lifecycle. The layout's contentOffsetAdjustment also calls its policy.
        ('statusBarSupport', SUPPORT / 'StatusBarScrollToTop.swift'),
        # MessageListLayout's vertical rhythm uses the production MessageRowGap
        # rule; the shipping file must be compiled, never a stub.
        ('rowGapSupport', SUPPORT / 'QueuedCandidateSpacing.swift'),
        ('itemSlice', OUT / 'ProductionMessageListItem.swift'),
        ('cellSlice', OUT / 'ProductionSelfSizingCell.swift'),
        ('toggleBlock', block),
        ('productionStubs', THINK / 'ProductionStubs.swift'),
        ('coordinatorStub', THINK / 'TxCoordinatorStub.swift'),
        ('harness', TESTS / 'AskCardUIKitHarness.swift'),
        ('tests', TESTS / 'AskCardAnchorUIKitTests.swift'),
        ('appHost', TESTS / 'AskCardUIKitMain.swift'),
    ]


def audit_closure(manifest, bridge):
    """Return the list of reasons this compile list cannot close.

    Linux-runnable and Darwin-independent: it reads the REAL files the compiler
    would read, derives every cross-file dependency from actual usage, and
    rejects a missing / stubbed provider. It is NOT a typecheck (parse only is
    not typecheck either); the Darwin typecheck is the swiftc run below.
    """
    problems = []
    texts = {}
    names = set()
    for label, path in manifest:
        path = pathlib.Path(path)
        names.add(path.name)
        if not path.is_file():
            problems.append(f'{label}: missing source {path}')
            continue
        text = path.read_text()
        if not text.strip():
            problems.append(f'{label}: empty source {path.name}')
            continue
        texts[path] = text

    # A compiled Swift source may never DEFINE the guard: `func noff_try_objc`
    # cannot catch an NSException, and defining it next to the real declaration
    # would silently replace the protection the shipping cell relies on.
    for path, text in texts.items():
        if FAKE_SWIFT_GUARD.search(text):
            problems.append(f'{path.name} defines a Swift noff_try_objc '
                            '(the guard must stay the shipping ObjC function)')

    for dep in DEPENDENCIES:
        users = sorted(p.name for p, t in texts.items()
                       if re.search(r'\b' + re.escape(dep.symbol) + r'\b', t))
        if not users:
            continue
        if dep.kind == 'swift':
            provider = IOS / dep.provider
            if provider.name not in names:
                problems.append(f'{dep.symbol} used by {users} but {dep.provider} is not compiled')
            elif not re.search(dep.declaration, provider.read_text()):
                problems.append(f'{dep.symbol} provider {dep.provider} no longer declares it')
        else:
            if bridge is None:
                problems.append(f'{dep.symbol} used by {users} but no ObjC bridge is linked')
                continue
            if not bridge.header.is_file() or not bridge.source.is_file():
                problems.append(f'{dep.symbol}: bridge header/implementation not written')
                continue
            if not re.search(dep.declaration, bridge.header.read_text()):
                problems.append(f'{dep.symbol}: bridge header does not declare the shipping signature')
            body = bridge.source.read_text()
            if not re.search(dep.declaration, body) and 'noff_try_objc(' not in body:
                problems.append(f'{dep.symbol}: bridge implementation is not the shipping function')
            elif '@catch (NSException' not in body or 'return NO;' not in body:
                problems.append(f'{dep.symbol}: bridge implementation does not catch (NOT a no-op)')
    return problems


def manifest_contract(block, bridge):
    """Frozen negatives + sensitivity for the closure audit above.

    Every case is executed: the negatives are the EXACT lists that failed on
    Darwin (run 44431220135 and run 44428916963), not descriptions of them.
    """
    cases = 0

    def case(cond, name):
        nonlocal cases
        cases += 1
        if cond:
            note('  ok   ' + name)
        else:
            note('  FAIL ' + name)
            raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL manifest contract: ' + name)

    current = source_manifest(block)
    case(audit_closure(current, bridge) == [], 'the current ask-card compile closure is complete')

    # run 44431220135 (SHA 84578ff): the exact list, without the ObjC bridge.
    no_bridge = audit_closure(current, None)
    case(no_bridge != [], 'the run 44431220135 closure (no ObjC bridge) is rejected')
    case(any('noff_try_objc' in p for p in no_bridge),
         'the rejection names noff_try_objc (the symbol that broke the build)')

    # run 44428916963 (SHA 6466033): the exact list, without the row-gap support.
    no_gap = [s for s in current if s[0] != 'rowGapSupport']
    case(audit_closure(no_gap, bridge) != [], 'the run 44428916963 closure (no MessageRowGap) is rejected')

    # Sensitivity: each provider is load-bearing for this exact list. (Dropping
    # a *user* is not a closure gap, so only providers can flip the audit red.)
    for label in ('rowGapSupport', 'statusBarSupport'):
        stripped = [s for s in current if s[0] != label]
        case(audit_closure(stripped, bridge) != [], f'contract is sensitive to dropping {label}')
    # The anchor math and the launch host are structural, not optional.
    labels = [s[0] for s in current]
    file_names = {pathlib.Path(path).name for _, path in current}
    case('layout' in labels and 'cellSlice' in labels and 'toggleBlock' in labels,
         'the manifest compiles the shipping layout, cell slice and toggle block')
    host = (TESTS / 'AskCardUIKitMain.swift').read_text()
    case('@main' in host and 'UIApplicationDelegate' in host and 'runAskCardUIKitCases()' in host,
         'the fixture is launched by a real UIApplicationDelegate host (never bare top-level)')

    # A Swift stand-in must never satisfy the ObjC guard: replacing it with a
    # closure that cannot catch an NSException is exactly what this fixture is
    # forbidden to do.
    fake = OUT / 'FakeNoff.swift'
    fake.write_text('import Foundation\n'
                    'func noff_try_objc(_ body: () -> Void) -> Bool { body(); return true }\n')
    case(FAKE_SWIFT_GUARD.search(fake.read_text()) is not None, 'the fake guard is what the scan looks for')
    case(audit_closure(current + [('fakeGuard', fake)], bridge) != [],
         'a Swift noff_try_objc stub is rejected')
    fake.unlink()
    case(not FAKE_SWIFT_GUARD.search((OUT / 'ProductionSelfSizingCell.swift').read_text()),
         'the generated cell slice never defines its own guard')

    # The bridge must carry the shipping body, not a hand-written one.
    case('@try {' in bridge.fn and '@catch (NSException' in bridge.fn and 'NSLog' in bridge.fn,
         'the bridge carries the shipping @try/@catch body')

    # Cross-check against the already-green drivers: every production support
    # file the thinking / genui fixtures compile must be in this list too. Those
    # two are the runs that proved the layout's dependency set on Darwin, so a
    # new fixture that omits one of them repeats run 44428916963.
    for driver in ('thinking_transaction_regression.py', 'genui_height_regression.py'):
        text = (ROOT / 'scripts' / driver).read_text()
        for dep in ('Support/QueuedCandidateSpacing.swift', 'Support/StatusBarScrollToTop.swift'):
            if dep in text:
                case(dep.rsplit('/', 1)[-1] in file_names,
                     f'{driver} compiles {dep.rsplit("/", 1)[-1]} and so does ask-card')
    return cases


def harness_api_contract():
    """Static API contract for the fixture's UIKit calls (NOT a typecheck).

    run 44436689380 (65ec6f6) got past the bridge and the source manifest, then
    the real Darwin typecheck rejected three calls in AskCardUIKitHarness.swift:
      102: inheritance from a final class 'NoAnimationCollectionView'
      125: cannot assign to property: 'collectionView' is a get-only property
      127: value of type 'MessageListLayout' has no member 'estimatedItemSize'
    All three are API-shape mistakes that a Linux run cannot see. This contract
    pins the exact three lines as frozen negatives and re-derives the rules from
    the SHIPPING declarations, so the next edit cannot reintroduce them.
    """
    cases = 0

    def case(cond, name):
        nonlocal cases
        cases += 1
        if cond:
            note('  ok   ' + name)
        else:
            note('  FAIL ' + name)
            raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL harness API contract: ' + name)

    swift = {p.name: p.read_text() for p in
             (TESTS / 'AskCardUIKitHarness.swift', TESTS / 'AskCardAnchorUIKitTests.swift',
              TESTS / 'AskCardUIKitMain.swift')}
    all_text = '\n'.join(swift.values())
    stub = (THINK / 'ProductionStubs.swift').read_text()
    production = (IOS / 'Agent/MessageList/MessageListInfrastructure.swift').read_text()
    layout_src = (IOS / 'Agent/MessageList/MessageListLayout.swift').read_text()

    # (1) The shipping class stays final; only the TEST DOUBLE may be subclassed.
    case('final class NoAnimationCollectionView' in production,
         'the shipping NoAnimationCollectionView is still final (never relaxed for a test)')
    stub_final = re.search(r'final class NoAnimationCollectionView', stub) is not None
    subclasses = re.search(r'class\s+\w+\s*:\s*NoAnimationCollectionView\b', all_text) is not None
    case(subclasses and not stub_final,
         'the fixture subclasses the non-final test double')
    frozen_final = 'final class NoAnimationCollectionView: UICollectionView {'
    case(subclasses and re.search(r'final class NoAnimationCollectionView', frozen_final) is not None,
         'frozen run-44436689380 inheritance of a final class is rejected')

    # (2) `MessageListLayout.collectionView` is inherited get-only: the binding
    #     must come from `cv.collectionViewLayout = layout` (what the green
    #     thinking/genui harnesses do by creating the cv with the layout).
    case('layout.collectionView =' not in all_text and 'layout.collectionView=' not in all_text,
         'no direct write to the get-only layout.collectionView')
    frozen_readonly = '        layout.collectionView = cv\n'
    case('layout.collectionView =' in frozen_readonly,
         'frozen run-44436689380 get-only assignment is rejected')
    case('cv.collectionViewLayout = layout' in all_text,
         'the layout is bound through the collection view')

    # (3) Every `layout.<member> =` must be a real stored property of the
    #     SHIPPING MessageListLayout (a UICollectionViewLayout has no
    #     estimatedItemSize; the layout's estimate is estimatedItemHeight).
    declared = set(re.findall(r'(?m)^\s*(?:private )?var\s+([A-Za-z_]\w*)', layout_src))
    assigned = sorted(set(re.findall(r'\blayout\.([A-Za-z_]\w*)\s*=(?!=)', all_text)))
    unknown = [n for n in assigned if n not in declared]
    case(unknown == [], f'every layout.<member> write exists in MessageListLayout (got {assigned})')
    case(re.search(r'\.estimatedItemSize\b', all_text) is None,
         'no flow-layout .estimatedItemSize call on MessageListLayout')
    frozen_size = '        layout.estimatedItemSize = CGSize(width: 390, height: 80)\n'
    case('estimatedItemSize' in frozen_size, 'frozen run-44436689380 estimatedItemSize is rejected')
    case('layout.estimatedItemHeight = 80' in all_text,
         'the layout estimate uses the shipping estimatedItemHeight')

    # Sensitivity: without the collection-view binding, `layout.collectionView`
    # stays nil, prepare() never runs and every geometry assertion is vacuous.
    stripped = all_text.replace('cv.collectionViewLayout = layout', '// removed')
    case('cv.collectionViewLayout = layout' not in stripped,
         'contract is sensitive to dropping the collection-view binding')
    return cases


def fixture_assertion_contract():
    """Static contract for the three assertion/precondition defects of run
    44439673271 (33 checks / 5 failures). NOT a typecheck, and NOT a substitute
    for the run: it freezes the exact broken lines so a future edit cannot put
    them back, and it re-derives the rules from what the fixture must do.
    """
    cases = 0

    def case(cond, name):
        nonlocal cases
        cases += 1
        if cond:
            note('  ok   ' + name)
        else:
            note('  FAIL ' + name)
            raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL fixture assertion contract: ' + name)

    harness = (TESTS / 'AskCardUIKitHarness.swift').read_text()
    tests = (TESTS / 'AskCardAnchorUIKitTests.swift').read_text()
    src = harness + '\n' + tests

    # (1) run 44439673271 S1/S5: "off=0.0 max=-392.7". When the content is
    #     SHORTER than the viewport maxOffset < minOffset and the only legal
    #     offset is minOffset, so the upper bound is max(minOffset, maxOffset).
    bad_bound = re.compile(r'contentOffset\.y\s*<=\s*[\w.]*maxOffset\s*\+')
    case(bad_bound.search(src) is None,
         'no "offset <= maxOffset" comparison (short content: maxOffset < minOffset)')
    case(re.search(r'var legalUpperOffset: CGFloat \{ max\(minOffset, maxOffset\) \}', harness)
         is not None, 'legalUpperOffset is max(minOffset, maxOffset) (same clamp as ClampSpy)')
    case(tests.count('legalUpperOffset') >= 3,
         'every legal-range assertion (S1/S5/S7) uses the clamped upper bound')
    frozen_bound = ('let legal = fx.cv.contentOffset.y <= fx.maxOffset + 1.0 '
                    '&& fx.cv.contentOffset.y >= -fx.cv.adjustedContentInset.top - 1.0')
    case(bad_bound.search(frozen_bound) is not None,
         'frozen run-44439673271 upper bound is rejected')

    # (2) run 44439673271 S3: the card boots EXPANDED, so six toggles return to
    #     `true`; the assertion hard-coded `false`.
    case(re.search(r'expanded\[card\]\s*==\s*false', tests) is None,
         'no hard-coded collapsed expectation in the round trip')
    case('let startExpanded = fx.expanded[card]' in tests
         and 'fx.expanded[card] == startExpanded' in tests,
         'the round trip compares against the recorded initial state')
    frozen_round = 'check("S3 back to the collapsed state it started from", fx.expanded[card] == false)'
    case(re.search(r'expanded\[card\]\s*==\s*false', frozen_round) is not None,
         'frozen run-44439673271 round-trip assertion is rejected')

    # (3) run 44439673271 / 44449400147 S1/S4: the expanded card measured 61.3
    #     (the collapsed height) because UIHostingConfiguration renders its first
    #     frame after the first layout pass - and, in 44449400147, because the
    #     settle ran from `init`, before the list had ever been in a window.
    #     Every case must start from a geometry measured AFTER attach.
    init_body = harness.split('init(items: Int = 8, tail: Bool = false) {')[1].split('\n    }\n')[0]
    case('settle()' not in init_body and 'settleAfterAttach()' not in init_body
         and 'makeKeyAndVisible' not in init_body,
         'init neither shows the window nor settles (attach comes first, settle after)')
    case('func attach(to hostView: UIWindow? = nil) -> Bool' in harness
         and 'host.makeKeyAndVisible()' in harness,
         'the host attaches the list to a real window (attach(to:))')
    case('func settleAfterAttach(maxRounds: Int = 8) -> Bool' in harness,
         'the settle is a post-attach, bounded (maxRounds) pass')
    settle_body = harness.split('func settleAfterAttach(')[1].split('\n    /// Re-apply every row')[0]
    case('guard cv.window != nil else' in settle_body,
         'settle refuses to run unless cv.window != nil')
    case('measureRow(' in settle_body and 'func measureRow' in harness
         and 'cell.preferredLayoutAttributesFitting(attrs)' in harness
         and 'abs((measured[i] ?? h) - h) <= 0.5' in settle_body
         and 'layout.setMeasuredHeight(fitted, at: i)' in settle_body,
         'settle stops only when two consecutive production measurements agree')
    case(tests.count('.attachAndSettle()') >= 8,
         'every case attaches and settles its fixture before measuring anything')
    # run 44452239211: the cases read `fx.attached` / `fx.settleRounds`, but the
    # fixture never declared them - the failure only showed up as a Darwin
    # compile error, after the harness parse had passed. Cross-check every
    # `fx.<member>` the cases touch against the fixture's declarations.
    declared = set(re.findall(r'(?:var|let|func)\s+([A-Za-z_][A-Za-z0-9_]*)', harness))
    touched = set(re.findall(r'fx\.([A-Za-z_][A-Za-z0-9_]*)', tests))
    missing = sorted(touched - declared)
    case(not missing,
         'every fx.<member> used by the cases is declared by the fixture '
         '(missing: %s)' % (', '.join(missing) or 'none'))
    case({'attached', 'settleRounds', 'settleTrace'} <= declared,
         'the fixture exposes the attach/settle diagnostics the cases assert on')
    case(all(tok in harness for tok in ('clearCachedHeight()', 'invalidateHeight(at: i)',
                                       'reconfigureItems(items)', 'layout.invalidateLayout()')),
         'settle re-asks the shipping layout (cache + measured heights), not a stub')
    measured = re.findall(r'setMeasuredHeight\(([^,]+),', src)
    case(bool(measured) and all('fitted' in a for a in measured),
         'every setMeasuredHeight argument is a real cell measurement (no literal)')
    case(re.search(r'setMeasuredHeight\(\s*[0-9]', src) is None,
         'no numeric literal is ever passed to setMeasuredHeight')
    frozen_const = 'layout.setMeasuredHeight(133, at: i)'
    case(re.search(r'setMeasuredHeight\(\s*[0-9]', frozen_const) is not None,
         'frozen hand-written height is rejected')
    case('> 100' in tests,
         'S1 asserts the card starts in its settled EXPANDED size')
    frozen_init = ('        ds.apply(snap, animatingDifferences: false)\n'
                   '        cv.layoutIfNeeded()\n'
                   '        spy.attach(cv)\n')
    case('settle()' not in frozen_init,
         'frozen run-44439673271 unsettled init is rejected')
    # run 44449400147: the init-time settle is what measured 61.3 off-window.
    frozen_offwindow = ('        window.rootViewController = vc\n'
                        '        window.makeKeyAndVisible()\n'
                        '        cv.contentInset = ')
    case('settleAfterAttach' not in frozen_offwindow
         and '        settle()\n' in ('        ds.apply(snap, animatingDifferences: false)\n'
                                       '        cv.layoutIfNeeded()\n'
                                       '        settle()\n'),
         'frozen run-44449400147 init-time settle is rejected')

    # Sensitivity: the attach gate and the settle are both load-bearing.
    case('guard cv.window != nil else' not in settle_body.replace('guard cv.window != nil else', '', 1),
         'contract is sensitive to dropping the cv.window != nil gate')
    case('max(minOffset, maxOffset)' not in harness.replace('max(minOffset, maxOffset)', 'maxOffset'),
         'contract is sensitive to dropping the legal-range clamp')
    return cases


def swiftc_command(sources, bridge, sdk, arch, out_bin):
    """The real command. Built from the audited manifest, so the list that was
    audited and the list that compiles cannot drift apart."""
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-import-objc-header', str(bridge.header),
           '-o', str(out_bin)]
    cmd += [str(pathlib.Path(p)) for _, p in sources]
    cmd.append(str(bridge.obj))
    return cmd


def prepare():
    infra = (IOS / 'Agent/MessageList/MessageListInfrastructure.swift').read_text()
    item = slice_between(infra, 'enum MessageListItem: Hashable {', '// MARK: - Self-Sizing Cell', 'MessageListItem')
    cell = slice_between(infra, 'class SelfSizingCell: UICollectionViewCell {',
                         '// MARK: - NoAnimationCollectionView', 'SelfSizingCell')
    (OUT / 'ProductionMessageListItem.swift').write_text('import Foundation\nimport UIKit\n\n' + item + '\n')
    (OUT / 'ProductionSelfSizingCell.swift').write_text(
        'import Foundation\nimport UIKit\nimport SwiftUI\n\n' + cell + '\n')

    fold = FOLD.read_text()
    block = slice_between(fold, '        func remeasureKeepingTop(', '        // MARK: - [T-thinking-toggle-txn]',
                          'ask-card toggle block')
    for token in ['func remeasureKeepingTop(', 'func verifyToggledHeight(',
                  'ToggleAnchorMath.preResizeOffset(', 'ToggleAnchorMath.cardAnchorPlan(',
                  'layout.beginTopAnchor(index: i)', 'layout.topAnchorOwned(by: token)',
                  'layout?.endTopAnchor(token: anchorToken)']:
        if token not in block:
            raise SystemExit('extracted block is missing production code: ' + token)
    if 'topAnchoredIndex = nil' in block:
        raise SystemExit('blocked bare-index anchor release still present')
    block_path = OUT / 'AskCardToggleBlock.swift'
    block_path.write_text('import UIKit\nimport SwiftUI\n\n'
                          'extension CollectionViewMessageListV3.Coordinator {\n' + block + '\n}\n')
    note('BLOCK_LINES ' + str(block.count('\n') + 1))
    return block_path, block


def main():
    block, block_text = prepare()
    bridge = production_bridge()
    manifest = source_manifest(block)
    problems = audit_closure(manifest, bridge)
    if problems:
        for p in problems:
            note('CLOSURE_GAP ' + p)
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL compile closure: ' + '; '.join(problems[:4]))
    note(f'ASK_CARD_UIKIT_CLOSURE_PASS sources={len(manifest)} deps=4 bridge=noff_try_objc')
    note(f'ASK_CARD_UIKIT_MANIFEST_CONTRACT_PASS cases={manifest_contract(block, bridge)}')
    note(f'ASK_CARD_UIKIT_HARNESS_API_CONTRACT_PASS cases={harness_api_contract()}')
    note(f'ASK_CARD_FIXTURE_ASSERTION_CONTRACT_PASS cases={fixture_assertion_contract()}')

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
    if not choices:
        raise SystemExit('no iPhone simulator available')
    d = next((x for x in choices if x['state'] == 'Booted'), choices[0])
    uid = d['udid']
    if d['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', uid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', uid, '-b'], check=True)
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
    arch = run(['uname', '-m']).strip()

    compile_bridge(bridge, sdk, arch)
    bin_path = APP / 'AskCardAnchorUIKit'
    APP.mkdir(exist_ok=True)
    cmd = swiftc_command(manifest, bridge, sdk, arch, bin_path)
    note('COMPILE ' + ' '.join(cmd))
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (OUT / 'compile.log').write_text(r.stdout)
    if r.returncode != 0:
        note(r.stdout[-20000:])
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL compile')

    info = {'CFBundleIdentifier': 'com.gonepaul.askcard.anchor',
            'CFBundleExecutable': 'AskCardAnchorUIKit', 'CFBundleName': 'AskCardAnchorUIKit',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
            'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
            'UILaunchScreen': {}}
    (APP / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', uid, str(APP)], check=True)
    env = {'SIMCTL_CHILD_ASK_PNG_DIR': str(OUT)}
    try:
        run_out = subprocess.run(['xcrun', 'simctl', 'launch', '--console-pty', uid, info['CFBundleIdentifier']],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 timeout=420, env={**__import__('os').environ, **env})
        text = run_out.stdout
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or '')
        if isinstance(text, bytes):
            text = text.decode(errors='replace')
        note(text[-20000:])
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL timeout')
    print(text, flush=True)
    (OUT / 'results.log').write_text(text)
    if 'ASK_CARD_ANCHOR_UIKIT_PASS' not in text:
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL marker missing')
    pngs = sorted(OUT.glob('*.png'))
    note('ASK_CARD_ANCHOR_UIKIT_PNG ' + str(len(pngs)))
    for p in pngs:
        note('  ' + p.name)
    # [T-ask-uikit-artifact] Exactly the seven case images: a missing PNG means
    # a case did not render, an extra one means the fixture grew a case without
    # the marker / root-gate contract being updated.
    if len(pngs) != 7:
        raise SystemExit('ASK_CARD_ANCHOR_UIKIT_FAIL png=' + str(len(pngs)))
    note('ASK_CARD_ANCHOR_UIKIT_ARTIFACT_OK dir=build/ask-card-uikit png=7')


if __name__ == '__main__':
    main()
