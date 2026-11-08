#!/usr/bin/env python3
"""Usage-toggle footer insert/delete: real UIKit regression (macOS + Xcode).

The 2026-11-08 recording (video_3BDC8F60.mp4) shows that double-tapping a
message block to show/hide the usage footer ratchets the transcript UPWARD: the
insert side pays only the footer's 4pt seed estimate while the delete side pays
its whole ~21pt row, so every show/hide cycle loses ≈17pt and four cycles in
9.5s netted −70pt on a `userBrowsing` (not auto-scrolling) list.

Source of the code under test, all compiled verbatim:

  * `MessageListLayout.swift` whole — the real custom layout, including
    `invalidationContext(forPreferredLayoutAttributes:)`'s compensation rules;
  * `MessageListItem` + `SelfSizingCell` sliced out of
    `MessageListInfrastructure.swift` (real UIHostingConfiguration self-sizing);
  * the `// MARK: - [T-usage-toggle-anchor]` block out of
    `Coordinator/MessageListV3Coordinator+Snapshot.swift` (`captureVisibleAnchor`
    / `restoreVisibleAnchor` / `VisibleAnchor`) verbatim.

The fixture (scripts/usage-toggle-anchor-tests/) supplies a real
`UICollectionView` in a real window, a real diffable data source of
`MessageListItem`, and a mirror of `applySnapshot`'s structural sequence. That
mirror is the only re-implemented part, so `source_checks` pins it against the
production file statement by statement (capture → suppress → apply →
layoutIfNeeded → un-suppress → restore → deferred restore → post-apply pin), and
the existing standalone contract (MinisTests/Standalone/UsageToggleAnchorTests)
is run as well.

Prints `USAGE_TOGGLE_ANCHOR_UIKIT_PASS checks=<n>` on success.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/usage-toggle-anchor'
out.mkdir(parents=True, exist_ok=True)
app = out / 'UsageToggleAnchor.app'
app.mkdir(exist_ok=True)
tests = root / 'scripts/usage-toggle-anchor-tests'
coord = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator'
layout_path = root / 'src/ios/Agent/MessageList/MessageListLayout.swift'
infra_path = root / 'src/ios/Agent/MessageList/MessageListInfrastructure.swift'
snapshot_path = coord / 'MessageListV3Coordinator+Snapshot.swift'
bindings_path = coord / 'MessageListV3Coordinator+Bindings.swift'
storage_path = coord / 'MessageListV3Coordinator.swift'
block_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedAssistantBlockV3.swift'
standalone_path = root / 'src/ios/MinisTests/Standalone/UsageToggleAnchorTests.swift'
spacing_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift'

failures = []


def note(msg):
    print(msg, flush=True)


def need(cond, msg):
    if cond:
        note('SOURCE_CHECK_OK: ' + msg)
    else:
        failures.append(msg)
        note('SOURCE_CHECK_FAIL: ' + msg)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    if end is None:
        j = len(text)
    else:
        j = text.find(end, i + len(start))
        if j < 0:
            raise SystemExit(f'extraction failed: end marker not found ({label})')
    block = text[i:j]
    if len(block.splitlines()) < 5:
        raise SystemExit(f'extraction failed: slice too short ({label})')
    return block


def extract_slices():
    infra = infra_path.read_text()
    item = slice_between(infra, 'enum MessageListItem: Hashable {', '// MARK: - Self-Sizing Cell',
                         'MessageListItem')
    cell = slice_between(infra, 'class SelfSizingCell: UICollectionViewCell {',
                         '// MARK: - NoAnimationCollectionView', 'SelfSizingCell')
    (out / 'ProductionMessageListItem.swift').write_text('import Foundation\nimport UIKit\n\n' + item + '\n')
    (out / 'ProductionSelfSizingCell.swift').write_text(
        'import Foundation\nimport UIKit\nimport SwiftUI\n\n' + cell + '\n')
    note(f'CELL_SLICE_LINES {cell.count(chr(10)) + 1}')
    return out / 'ProductionSelfSizingCell.swift', out / 'ProductionMessageListItem.swift'


def production_anchor_block():
    """The production anchor helpers, verbatim, wrapped in the fixture coordinator."""
    text = snapshot_path.read_text()
    start = text.find('// MARK: - [T-usage-toggle-anchor]')
    if start < 0:
        raise SystemExit('the usage-toggle anchor block is missing from +Snapshot.swift')
    end = text.rindex('\n}')
    block = text[start:end]
    for required in ('struct VisibleAnchor', 'func captureVisibleAnchor()', 'func restoreVisibleAnchor(',
                     'if case .assistantFooter = item { continue }',
                     'anchor.generation != snapshotApplyGeneration',
                     'cv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)'):
        if required not in block:
            raise SystemExit('production anchor block lost a required line: ' + required)
    note(f'ANCHOR_BLOCK_LINES {block.count(chr(10)) + 1}')
    wrapped = ('import Foundation\nimport UIKit\n\n'
               'extension CollectionViewMessageListV3.Coordinator {\n' + block + '\n}\n')
    path = out / 'ProductionAnchorBlock.swift'
    path.write_text(wrapped)
    return path, block


def source_checks(anchor_block):
    snap = snapshot_path.read_text()
    bind = bindings_path.read_text()
    block = block_path.read_text()
    infra = infra_path.read_text()
    storage = storage_path.read_text()

    # ── the opt-in parameter and the generation seam ──
    need('preserveVisibleAnchor: Bool = false) {' in snap,
         'applySnapshot takes a defaulted opt-in preserveVisibleAnchor')
    need('var snapshotApplyGeneration = 0' in storage,
         'the apply generation lives in the coordinator stored-state seam')
    need('snapshotApplyGeneration &+= 1' in snap, 'every apply bumps the generation')
    need('(preserveVisibleAnchor && !clampAfterSessionLoad) ? captureVisibleAnchor() : nil' in snap,
         'the capture is skipped while the session-load clamp owns the offset')

    # ── the order inside applySnapshot ──
    order = [
        ('generation bump', 'snapshotApplyGeneration &+= 1'),
        ('capture', 'let anchorBefore = (preserveVisibleAnchor'),
        ('suppress on', 'snapshotLayout?.suppressContentOffsetAdjustment = true'),
        ('first layout', 'cv.layoutIfNeeded()\n                snapshotLayout?.suppressContentOffsetAdjustment = false'),
        ('sync restore', 'restoreVisibleAnchor(anchorBefore)'),
        ('deferred restore', 'DispatchQueue.main.async { [weak self] in'),
        ('post-apply sub-viewport', 'applySubViewportCompensation(caller: "snapshot-subVP")'),
    ]
    positions = {}
    for label, needle in order:
        i = snap.find(needle)
        positions[label] = i
        need(i >= 0, f'the {label} statement is present')
    seq = [label for label, _ in order]
    need(all(positions[a] < positions[b] for a, b in zip(seq, seq[1:])),
         'apply order is capture → suppress → layout → un-suppress → restore → deferred restore → post-apply')

    # ── the deferred restore cannot yank a dragging reader ──
    defer_at = snap.find('DispatchQueue.main.async { [weak self] in')
    defer_block = snap[defer_at:defer_at + 900] if defer_at >= 0 else ''
    need('self.scrollMode != .autoScrolling' in defer_block
         and '!cv.isTracking, !cv.isDecelerating' in defer_block,
         'the deferred restore is gated on browsing + not tracking/decelerating')

    # ── exactly one caller, and it names its path ──
    need(bind.count('preserveVisibleAnchor: true') == 1,
         'exactly one call site opts into the anchor')
    need(snap.count('preserveVisibleAnchor: true') == 0,
         'no call site inside +Snapshot.swift opts in')
    need('fromUsageToggle' in bind
         and '(note.object as? String) == MessageListItem.usageToggleSender' in bind
         and 'preserveVisibleAnchor: fromUsageToggle' in bind,
         'only the MARKED usage-toggle notification opts in (font/appearance applies do not)')
    need('static let usageToggleSender = "usageToggle"' in infra,
         'the sender marker exists on MessageListItem')
    need(block.count('object: MessageListItem.usageToggleSender)') == 2,
         'both footer toggle posts carry the marker (BridgedAssistantBlockV3)')

    # ── the anchor's own safety properties ──
    need('if case .assistantFooter = item { continue }' in anchor_block,
         'the row this apply deletes can never be the anchor')
    need('anchor.generation != snapshotApplyGeneration' in anchor_block,
         'a stale anchor is dropped instead of pulling the reader back')
    need('if attrs.frame.minY - cv.contentOffset.y >= -0.5 { return anchor(item, attrs) }' in anchor_block,
         'a row whose top edge is on screen wins (the fallback covers clipped tops)')
    need('let clamped = min(max(target, minOff), maxOff)' in anchor_block,
         'the restored offset is clamped into the legal range')
    need('guard abs(clamped - cv.contentOffset.y) > 0.5 else { return }' in anchor_block,
         'a sub-pixel restore stays a no-op')
    need('withAnimation' not in anchor_block,
         'the anchor never animates a SwiftUI property (that cannot move a UIScrollView)')

    # ── the asymmetry this fix compensates is still where it was ──
    need('layout.setEstimatedHeight(footerProminent ? 48 : 4, at: i)' in snap,
         'the quiet footer is still seeded at 4pt')
    need('|| (cellBridges[message.id]?.showUsage == true)' in snap,
         'the footer is still omitted from the item list when showUsage is off')

    # ── what must NOT have changed: bottom follow, arrow, thinking txn ──
    need('if scrollMode == .autoScrolling && maxOff > 0' in snap,
         'the autoScrolling pin still runs after the restore')
    need('applySubViewportCompensation(caller: "snapshot-shrink", forceRelax: true)' in snap,
         'the shrink clamp is untouched')
    scroll = (coord / 'MessageListV3Coordinator+Scroll.swift').read_text()
    need('func scrollToBottomNow(animated: Bool = false)' in scroll and 'isAnimatingScrollToBottom' in scroll,
         'the down-arrow jump-to-bottom path is untouched')
    fold = (coord / 'MessageListV3Coordinator+ToolFolding.swift').read_text()
    need('func thinkingToggleAnchored(' in fold and 'setTxnAnchor' in fold,
         'the thinking-row transaction is untouched')

    if failures:
        raise SystemExit('source checks failed: ' + '; '.join(failures))


def syntax_gate(files):
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


def standalone_contract():
    """The pre-existing source contract still has to pass unchanged."""
    r = subprocess.run(['swift', str(standalone_path)], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, cwd=str(root))
    note(r.stdout[-4000:])
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith('  ✓') or ln.startswith('  ✗')]
    note(f'STANDALONE_CONTRACT_CHECKS {len(lines)}')
    if r.returncode != 0 or 'ALL PASSED' not in r.stdout:
        raise SystemExit('the standalone UsageToggleAnchorTests source contract failed')


def main():
    cell_src, item_src = extract_slices()
    anchor_src, anchor_block = production_anchor_block()
    source_checks(anchor_block)
    standalone_contract()

    gate = [anchor_src, cell_src, item_src, tests / 'UsageToggleStubs.swift',
            tests / 'UsageToggleHarness.swift', tests / 'UsageToggleAnchorUITests.swift',
            tests / 'main.swift', snapshot_path, bindings_path, storage_path, infra_path,
            layout_path, block_path]
    if syntax_gate(gate):
        raise SystemExit('swiftc -frontend -parse failed')

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

    # SelfSizingCell's measure path is wrapped in the production ObjC exception
    # guard; compile the real function instead of stubbing it out.
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

    sources = [layout_path, item_src, cell_src, anchor_src, spacing_path,
               tests / 'UsageToggleStubs.swift', tests / 'UsageToggleHarness.swift',
               tests / 'UsageToggleAnchorUITests.swift', tests / 'main.swift']
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-import-objc-header', str(bridge_header),
           '-o', str(app / 'UsageToggleAnchor')]
    cmd += [str(s) for s in sources] + [str(bridge_obj)]
    note('COMPILE ' + ' '.join(cmd))
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'compile.log').write_text(r.stdout)
    note(r.stdout[-20000:])
    if r.returncode != 0:
        raise SystemExit('swiftc failed — see build/usage-toggle-anchor/compile.log')

    info = {'CFBundleIdentifier': 'com.gonepaul.usage.toggle.anchor',
            'CFBundleExecutable': 'UsageToggleAnchor', 'CFBundleName': 'UsageToggleAnchor',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
            'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
            'UILaunchScreen': {}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', uid, str(app)], check=True)
    run = subprocess.run(['xcrun', 'simctl', 'launch', '--console', uid, info['CFBundleIdentifier']],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=420)
    print(run.stdout, flush=True)
    (out / 'results.log').write_text(run.stdout)
    note('LAUNCH_RETURN_CODE ' + str(run.returncode))

    for key, pattern in (('FOOTER_FIRST_PASS', r'REPORT_FOOTER_FIRST_PASS (-?[\d.]+)'),
                         ('FOOTER_REAL', r'REPORT_FOOTER_REAL (-?[\d.]+)'),
                         ('NOANCHOR_PER_CYCLE', r'REPORT_NOANCHOR_PER_CYCLE ([\-0-9.,]+)'),
                         ('NOANCHOR_TOTAL', r'REPORT_NOANCHOR_TOTAL (-?[\d.]+)'),
                         ('ANCHORED_PER_CYCLE', r'REPORT_ANCHORED_PER_CYCLE ([\-0-9.,]+)'),
                         ('ANCHORED_TOTAL', r'REPORT_ANCHORED_TOTAL (-?[\d.]+)'),
                         ('ANCHOR_RESTORES', r'REPORT_ANCHOR_RESTORES (\d+)'),
                         ('RAPID_TOTAL', r'REPORT_RAPID_TOTAL (-?[\d.]+)'),
                         ('DRAG_CYCLE_AFTER', r'REPORT_DRAG_CYCLE_AFTER (-?[\d.]+)'),
                         ('STALE_OFFSETS', r'REPORT_STALE_OFFSETS ([\-0-9.,]+)'),
                         ('BOTTOM_OFFSETS', r'REPORT_BOTTOM_OFFSETS ([\-0-9.,]+)'),
                         ('BELOW_PER_CYCLE', r'REPORT_BELOW_PER_CYCLE ([\-0-9.,]+)'),
                         ('TOPCLIP_TOTAL', r'REPORT_TOPCLIP_TOTAL (-?[\d.]+)'),
                         ('FOOTERTOP_CYCLE', r'REPORT_FOOTERTOP_CYCLE (-?[\d.]+)'),
                         ('CHECK_COUNT', r'USAGE_TOGGLE_ANCHOR_UIKIT_CHECKS (\d+)')):
        m = re.search(pattern, run.stdout)
        if m:
            note(f'REPORT_{key} {m.group(1)}')

    if 'USAGE_TOGGLE_ANCHOR_UIKIT_PASS' not in run.stdout:
        try:
            log = subprocess.run(['xcrun', 'simctl', 'spawn', uid, 'log', 'show', '--style', 'compact',
                                  '--last', '2m', '--predicate', 'process == "UsageToggleAnchor"'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            (out / 'diagnostic.log').write_text(log.stdout)
        except subprocess.TimeoutExpired:
            (out / 'diagnostic.log').write_text('log show timed out')
        raise SystemExit('usage-toggle anchor UI regression failed (see build/usage-toggle-anchor/)')

    note('USAGE_TOGGLE_ANCHOR_REGRESSION_OK')


if __name__ == '__main__':
    main()
