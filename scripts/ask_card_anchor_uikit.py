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
    (the same stub the thinking/session harness uses).
Only the CARD and TOOL-GROUP content views are fixture SwiftUI (`AskCardUIKitHarness`);
the toggle path, the layout and the anchor math are the app's own code.

Cases (see AskCardAnchorUIKitTests.swift): collapse above a collapsed group,
collapse above an expanded group, 6-round trip mid-list, rapid double tap,
drag in flight, snapshot/session swap right after a toggle.
Prints `ASK_CARD_ANCHOR_UIKIT_PASS cases=7 checks=<n> png=<n>` and writes the
PNGs to `build/ask-card-uikit/`.
"""
import json
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/ask-card-uikit'
OUT.mkdir(parents=True, exist_ok=True)
APP = OUT / 'AskCardAnchorUIKit.app'
TESTS = ROOT / 'scripts/ask-card-anchor-tests'
THINK = ROOT / 'scripts/thinking-transaction-tests'
IOS = ROOT / 'src/ios'
FOLD = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift'


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
    return block_path


def main():
    block = prepare()
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

    main_file = OUT / 'main.swift'
    main_file.write_text('import UIKit\n\nrunAskCardUIKitCases()\n')
    sources = [IOS / 'Agent/MessageList/MessageListLayout.swift',
               # [T-user-ask-anchor-flight] The shipping flight state machine:
               # the toggle path ends a live flight, so the fixture must drive
               # the real lifecycle (Foundation-only, no UIKit).
               IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift',
               OUT / 'ProductionMessageListItem.swift', OUT / 'ProductionSelfSizingCell.swift',
               block, THINK / 'ProductionStubs.swift', THINK / 'TxCoordinatorStub.swift',
               TESTS / 'AskCardUIKitHarness.swift', TESTS / 'AskCardAnchorUIKitTests.swift',
               main_file]
    bin_path = APP / 'AskCardAnchorUIKit'
    APP.mkdir(exist_ok=True)
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-o', str(bin_path)]
    cmd += [str(s) for s in sources]
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
