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
    names = [s[0] for s in current]
    case('layout' in names and 'cellSlice' in names and 'toggleBlock' in names,
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
