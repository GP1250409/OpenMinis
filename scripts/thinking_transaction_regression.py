#!/usr/bin/env python3
"""Thinking-row manual open/close transaction: real UIKit regression (macOS + Xcode).

Compiles, verbatim:
  * `MessageListLayout.swift` (anchor API, compensation, ThinkingToggleTxn math),
  * `SelfSizingCell` + `MessageListItem` sliced out of `MessageListInfrastructure.swift`,
  * the coordinator's `// MARK: - [T-thinking-toggle-txn]` … `func reconfigureAllCells()`
    block out of `MessageListV3Coordinator+ToolFolding.swift`, wrapped in the
    fixture coordinator from `scripts/thinking-transaction-tests/TxCoordinatorStub.swift`,
and runs it in a real `UICollectionView` (UIHostingConfiguration content) on an
iOS simulator: 20 expand/collapse rounds, rapid taps, late measure, drag /
session release, token-owned anchor semantics.

Prints `THINKING_TRANSACTION_UIKIT_PASS checks=<n>` on success.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/thinking-transaction'
out.mkdir(parents=True, exist_ok=True)
app = out / 'ThinkingTransaction.app'
app.mkdir(exist_ok=True)
tests = root / 'scripts/thinking-transaction-tests'
layout_path = root / 'src/ios/Agent/MessageList/MessageListLayout.swift'
infra_path = root / 'src/ios/Agent/MessageList/MessageListInfrastructure.swift'
fold_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift'
snap_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift'
block_view_path = root / 'src/ios/Views/Chat/AssistantBlockView.swift'

failures = []
contract_pending = []


def note(msg):
    print(msg, flush=True)


def need(cond, msg):
    if cond:
        note('SOURCE_CHECK_OK: ' + msg)
    else:
        failures.append(msg)
        note('SOURCE_CHECK_FAIL: ' + msg)


def pending(cond, msg):
    """A rule the implementation agent is still changing. Missing = FAIL (never
    skipped): a stale fixture must not let the old model pass silently."""
    if cond:
        note('CONTRACT_OK: ' + msg)
    else:
        contract_pending.append(msg)
        note('CONTRACT_PENDING: ' + msg)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f'extraction failed: end marker not found ({label})')
    return text[i:j]


def production_transaction_block():
    fold = fold_path.read_text()
    block = slice_between(fold, '// MARK: - [T-thinking-toggle-txn]', 'func reconfigureAllCells()',
                          'thinking transaction block')
    # Core methods that must exist in the block, plus (below) the methods the
    # fixture coordinator feeds it. A missing one = the block cannot be run, so
    # the run FAILS loudly instead of skipping.
    required = ['func thinkingToggleAnchored(', 'func verifyThinkingToggle(',
                'func releaseThinkingToggleTxn(', 'ThinkingToggleTxnMath.probe(',
                'ThinkingToggleTxnMath.lateAnchorY(', 'setTxnAnchor(']
    forbidden = ['consumeThinkingToggleEcho', 'thinkingEchoPendingByBlock', 'consumesEcho']
    present = [f for f in forbidden if f in block]
    if present:
        raise SystemExit('blocked counted-echo design still in the transaction block: ' + ', '.join(present))
    missing = [r for r in required if r not in block]
    if missing:
        raise SystemExit('transaction block is missing production methods: ' + ', '.join(missing))
    # Every function in the range must reach the fixture — a range that stops at
    # a stale name is exactly what produced a historic false failure.
    funcs = re.findall(r'\n        func ([A-Za-z0-9_]+)\(', block)
    note('TXN_BLOCK_FUNCS ' + ','.join(funcs))
    note('TXN_BLOCK_LINES ' + str(block.count('\n') + 1))
    wrapped = ('import UIKit\nimport SwiftUI\n\n'
               'extension CollectionViewMessageListV3.Coordinator {\n' + block + '\n}\n')
    path = out / 'TxCoordinatorTxnBlock.swift'
    path.write_text(wrapped)
    return path, block


def source_checks(txn_block=''):
    layout = layout_path.read_text()
    block = block_view_path.read_text()
    fold = fold_path.read_text()
    snap = snap_path.read_text()

    need('enum ToggleAnchorMath {' in layout, 'ToggleAnchorMath present')
    need('static let manualThinkingKey = "manualThinkingTxn"' in layout,
         'manual thinking userInfo key exists and is separate from anchorTop/toggleRequest')
    need('func setTxnAnchor(token: Int, index: Int, blockId: UUID) -> Bool' in layout
         and 'func clearTxnAnchor(token: Int) -> Bool' in layout
         and 'func clearTxnAnchor(forIndex index: Int) -> Bool' in layout
         and 'func isTxnAnchored(index: Int) -> Bool' in layout,
         'token-owned anchor API present (set/clear by token + index, isTxnAnchored)')
    need(('isTxnAnchored(index: index)' in layout) or ('txnAnchor' in layout and 'contentOffsetAdjustment' in layout),
         'visible-cell compensation skips the transaction-owned row')
    need('isThinkingExpanded == true) ? ":x"' in
         (root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+HeightEstimation.swift').read_text(),
         'content key still carries the thinking expanded state (8817c8e fix intact)')

    # ---- tap path: model-level manual marker, no counted echo ----
    pending(re.search(r'let request = ToggleRequest \{', block) is not None
            and 'ToggleAnchorMath.toggleRequestKey: request' in block,
            'tap hands the flip to the list through ToggleRequest (no direct state flip)')
    pending('ToggleAnchorMath.manualThinkingKey: true' in block,
            'tap post carries the manual marker in userInfo')
    pending('request.hasRun' in block,
            'no-list fallback checks hasRun and posts an explicit re-measure')
    pending('consumesEcho' not in fold and 'thinkingEchoPendingByBlock' not in fold,
            'counted echo dedupe REMOVED from the coordinator (blocked: onChange may coalesce/drop)')
    pending('thinkingEchoPendingByBlock' not in snap, 'counted echo map not read by the notification sink')
    # onChange must itself skip the manual post (model marker), and a manual
    # target must be an explicit value, not a counter.
    pending(re.search(r'onChange\(of: .{0,120}isThinkingExpanded', block) is not None,
            'ThinkingBlockView still observes isThinkingExpanded (auto-collapse path kept)')
    models = (root / 'src/ios/Agent/Chat/ChatModels.swift').read_text()
    pending('var pendingManualThinkingState: Bool?' in models
            and 'var pendingManualThinkingToken: UUID?' in models,
            'model carries an EXPLICIT manual target state + its token (replaces the counted echo)')
    pending('pendingManualThinkingState' in block and 'pendingManualThinkingState = nil' in block,
            'onChange consumes the manual target and skips the plain post for exactly that flip')
    # verify must span render frames and judge against the current expanded target.
    pending('txn.targetExpanded' in fold, 'verifier judges by the transaction target state, not only height')
    # (1) receipt=false must not block a real correction.
    pending('if abs(measured - current) > tolerance { return .fixHeight }' in layout,
            'probe installs a changed height BEFORE looking at the receipt')
    pending('guard receipt else { return .waitReceipt }' in layout,
            'a missing receipt only downgrades agreement to .waitReceipt')
    pending('case waitReceipt' in layout, 'probe exposes the waitReceipt verdict')
    pending('receipt: receipt && t2.didApply' in fold, 'verifier passes the real receipt into probe()')
    # (2) budget is spent by EVERY scheduled round, including unmeasurable ones.
    pending('t.probes += 1' in fold and 'func scheduleThinkingToggleProbe(' in fold,
            'verifier counts every scheduled probe (self-scheduling entry point present)')
    pending('if txn.probes >= ThinkingToggleTxnMath.maxProbes {' in fold and 'txn.probing = false' in fold,
            'off-screen / unmeasurable rounds stop at the probe cap (no 60 Hz poll)')
    pending('guard txn.probing else { return }' in fold, 'a stopped transaction cannot re-enter verify()')
    pending('probing: true, receiptSeen: false' in fold, 'transaction starts with probing on and no receipt')
    # (3) counted echo must stay gone.
    pending('consumesEcho' not in layout and 'consumesEcho' not in fold,
            'the blocked counted-echo helper is removed from layout + coordinator')
    # (4) release keeps the model marker; onChange always consumes it.
    rx_release = re.search(r'func releaseThinkingToggleTxn\b.*?\n        \}', fold, re.S)
    pending(rx_release is not None and 'pendingManualThinking' not in rx_release.group(0),
            'release does NOT clear the model marker (a late onChange must still see it)')
    pending('block.pendingManualThinkingState = nil' in block,
            'onChange consumes the marker unconditionally')
    pending(re.search(r'pending == \w+|pending == newValue|== block\.isThinkingExpanded', block) is not None,
            'onChange skips the plain post ONLY when the marker matches this transition')
    # (5) the row must not stretch vertically.
    pending('.frame(maxHeight: .infinity, alignment: .top)' in block,
            'thinking row is top-aligned with an unbounded max height')
    pending(fold.count('DispatchQueue.main.async') >= 2,
            'verifier re-probes across render frames (async hops) instead of one synchronous pass')
    pending('asyncAfter(deadline: .now() + 0.6)' not in txn_block,
            'no 0.6s timer inside the thinking transaction (frame-paced probe instead)')
    pending('guard let txn = thinkingToggleTxn, txn.token == token else { return }' in fold,
            'generation guard protects every late closure')
    # Settle may keep the anchor; release must be token-guarded either way.
    pending('clearTxnAnchor(token:' in fold, 'anchor release goes through the token-guarded clear')
    pending('snapshot.itemIdentifiers.firstIndex(of: txn.item)' in fold,
            'row relocated by identity (item + blockId), never by a cached index')
    return True


def extract_slices():
    infra = infra_path.read_text()
    item = slice_between(infra, 'enum MessageListItem: Hashable {', '// MARK: - Self-Sizing Cell', 'MessageListItem')
    cell = slice_between(infra, 'class SelfSizingCell: UICollectionViewCell {',
                         '// MARK: - NoAnimationCollectionView', 'SelfSizingCell')
    (out / 'ProductionMessageListItem.swift').write_text('import Foundation\nimport UIKit\n\n' + item + '\n')
    (out / 'ProductionSelfSizingCell.swift').write_text(
        'import Foundation\nimport UIKit\nimport SwiftUI\n\n' + cell + '\n')
    note(f'CELL_SLICE_LINES {cell.count(chr(10)) + 1}')
    return out / 'ProductionSelfSizingCell.swift', out / 'ProductionMessageListItem.swift'


def syntax_gate(extra):
    """Fast `swiftc -frontend -parse` over every changed Swift file: catches a
    broken production edit before the simulator build (seconds, not minutes)."""
    # CI checks out a clean tree, so `git diff` is empty there. Parse the
    # explicit production edit set, not only unstaged files on a developer box.
    rels = [
        'src/ios/Agent/Chat/ChatModels.swift',
        'src/ios/Views/Chat/AssistantBlockView.swift',
        'src/ios/Agent/MessageList/MessageListLayout.swift',
    ]
    coord = 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/'
    rels += [coord + name for name in [
        'MessageListV3Coordinator.swift', 'MessageListV3Coordinator+ToolFolding.swift',
        'MessageListV3Coordinator+Snapshot.swift', 'MessageListV3Coordinator+Bindings.swift',
        'MessageListV3Coordinator+ScrollViewDelegate.swift',
    ]]
    files = [root / rel for rel in rels] + extra
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()
    bad = 0
    for f in files:
        r = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', '-sdk', sdk,
                            '-target', f'{arch}-apple-ios16.0-simulator', str(f)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.returncode != 0:
            bad += 1
            note(f'SYNTAX_FAIL {f.name}')
            note(r.stdout[-4000:])
        else:
            note(f'SYNTAX_OK {f.name}')
    return bad


def main():
    cell_src, item_src = extract_slices()
    txn_src, txn_block = production_transaction_block()
    source_checks(txn_block)

    gate_files = [tests / 'ProductionStubs.swift', tests / 'ThinkingHarness.swift',
                  tests / 'TxCoordinatorStub.swift', tests / 'ThinkingTransactionTests.swift',
                  tests / 'ThinkingToggleTxnMathTests.swift', txn_src]
    bad = syntax_gate(gate_files)
    if bad:
        raise SystemExit(f'swiftc -frontend -parse failed for {bad} file(s)')

    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
    if not choices:
        raise SystemExit('No iPhone simulator available')
    d = next((d for d in choices if d['state'] == 'Booted'), choices[0])
    uid = d['udid']
    if d['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', uid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', uid, '-b'], check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()

    # Compile the actual ObjC exception guard used by SelfSizingCell, rather
    # than silently replacing it with a Swift closure that cannot catch an
    # NSException. Only the independent function is lifted; the rest of the
    # native offload implementation depends on the full app/iSH runtime.
    native = root / 'src/ios/NativeOffloads'
    native_text = (native / 'NativeOffloadUtils.m').read_text()
    guard_fn = native_text[native_text.index('BOOL noff_try_objc('):native_text.index('// ── Calling session')]
    guard_decl = next(line for line in (native / 'NativeOffloadUtils.h').read_text().splitlines()
                      if line.startswith('BOOL noff_try_objc('))
    bridge_header = out / 'ExceptionBridge.h'
    bridge_header.write_text('#import <Foundation/Foundation.h>\n' + guard_decl + '\n')
    bridge_source = out / 'ExceptionBridge.m'
    bridge_source.write_text('#import "ExceptionBridge.h"\n' + guard_fn)
    bridge_obj = out / 'ExceptionBridge.o'
    br = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-fobjc-arc', '-fblocks',
                         '-isysroot', sdk, '-target', f'{arch}-apple-ios16.0-simulator',
                         '-c', str(bridge_source), '-o', str(bridge_obj)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'objc-bridge.log').write_text(br.stdout)
    if br.returncode:
        note(br.stdout)
        raise SystemExit('production Objective-C exception guard failed to compile')
    note('PRODUCTION_EXCEPTION_BRIDGE_OK')

    sources = [layout_path, item_src, cell_src, txn_src,
               root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift',
               tests / 'ProductionStubs.swift', tests / 'TxCoordinatorStub.swift',
               tests / 'ThinkingHarness.swift', tests / 'ThinkingTransactionTests.swift',
               tests / 'ThinkingToggleTxnMathTests.swift']
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-import-objc-header', str(bridge_header),
           '-o', str(app / 'ThinkingTransaction')]
    cmd += [str(s) for s in sources] + [str(bridge_obj)]
    note('COMPILE ' + ' '.join(cmd))
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'compile.log').write_text(r.stdout)
    note(r.stdout[-20000:])
    if r.returncode != 0:
        raise SystemExit('swiftc failed — see build/thinking-transaction/compile.log')

    info = {'CFBundleIdentifier': 'com.gonepaul.thinking.transaction',
            'CFBundleExecutable': 'ThinkingTransaction', 'CFBundleName': 'ThinkingTransaction',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
            'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
            'UILaunchScreen': {}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', uid, str(app)], check=True)
    run = subprocess.run(['xcrun', 'simctl', 'launch', '--console', uid, info['CFBundleIdentifier']],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=360)
    print(run.stdout, flush=True)
    (out / 'results.log').write_text(run.stdout)
    note('LAUNCH_RETURN_CODE ' + str(run.returncode))

    for key, pattern in (('ANCHORED_20R_DRIFT', r'THINKING_TXN_20R_DRIFT (-?[\d.]+)'),
                         ('PLAIN_PATH_DRIFT', r'THINKING_TXN_PLAIN_PATH_DRIFT (-?[\d.]+)'),
                         ('RAPID_TOP_MOVE', r'THINKING_TXN_RAPID_TOP_MOVE (-?[\d.]+)'),
                         ('LATE_MOVE', r'THINKING_TXN_LATE_MOVE (-?[\d.]+)'),
                         ('CHECK_COUNT', r'THINKING_TRANSACTION_UIKIT_CHECKS (\d+)'),
                         ('ASYNC_PUMP', r'THINKING_TXN_ASYNC_PUMP asyncBlock=(\w+) timer=(\w+)'),
                         ('OFFSCREEN_FRAMES', r'THINKING_TXN_OFFSCREEN_FRAMES (\d+) probes (-?\d+)'),
                         ('LATE_ANCHORED_TOP', r'THINKING_TXN_LATE_ANCHORED_TOP (-?[\d.]+)'),
                         ('LATE_PLAIN_TOP', r'THINKING_TXN_LATE_PLAIN_TOP (-?[\d.]+)')):
        m = re.search(pattern, run.stdout)
        if m:
            note(f'REPORT_{key} {m.group(1)}')

    if 'THINKING_TRANSACTION_UIKIT_PASS' not in run.stdout:
        try:
            log = subprocess.run(['xcrun', 'simctl', 'spawn', uid, 'log', 'show', '--style', 'compact',
                                  '--last', '2m', '--predicate', 'process == "ThinkingTransaction"'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            (out / 'diagnostic.log').write_text(log.stdout)
        except subprocess.TimeoutExpired:
            (out / 'diagnostic.log').write_text('log show timed out')
        raise SystemExit('thinking transaction UI regression failed (see build/thinking-transaction/)')

    pending_msgs = []
    if contract_pending:
        note('CONTRACT_PENDING_COUNT ' + str(len(contract_pending)))
        for m in contract_pending:
            note('  - ' + m)
        pending_msgs = contract_pending
    if failures:
        raise SystemExit('source checks failed: ' + '; '.join(failures))
    if pending_msgs:
        raise SystemExit(
            'UIKit regression passed, but the transaction contract is not met yet '
            f'({len(pending_msgs)} rule(s) pending — the counted-echo model is blocked; '
            'implement the model-level manual target marker and re-run): ' + '; '.join(pending_msgs))
    note('THINKING_TRANSACTION_REGRESSION_OK')


if __name__ == '__main__':
    main()
