#!/usr/bin/env python3
"""Actual ToolGroupRowView + BridgedToolGroupV3 + ToolGroupCellV3/SelfSizingCell + MessageListLayout + ToolFoldPlanner in UIHostingConfiguration."""
import json, pathlib, platform, plistlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS = ROOT / 'src' / 'ios'
OUT = ROOT / 'build' / 'toolfold-uikit'
OUT.mkdir(parents=True, exist_ok=True)
APP = OUT / 'ToolFoldUIKit.app'


def run(cmd, **kw):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, **kw)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f'extraction failed: end marker not found ({label})')
    block = text[i:j]
    if len(block.splitlines()) < 5:
        raise SystemExit(f'extraction failed: slice too short ({label})')
    return block


def prepare():
    abv = (IOS / 'Views/Chat/AssistantBlockView.swift').read_text()
    row_start = abv.index('struct ToolGroupRowView: View {')
    row_end = abv.index('\nextension Notification.Name {', row_start)
    row_slice = abv[row_start:row_end]
    for token in [
        'struct ToolGroupRowView: View {',
        'static let rowHeight: CGFloat = 28',
        'Running \\(runningCount) tools',
        '\\(completedCount) done',
        'Thinking…',
        'Thinking process',
        'Ran \\(toolCount) tools',
        '.toolGroupToggled',
    ]:
        assert token in row_slice, f'missing token in ToolGroupRowView: {token}'

    bridged = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedToolGroupV3.swift').read_text()
    assert '.transaction { $0.disablesAnimations = true }' in bridged
    assert 'runningCount: group.runningCount' in bridged

    cells = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Cells/MessageListV3Cells.swift').read_text()
    assert 'final class ToolGroupCellV3: SelfSizingCell {}' in cells

    setup = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Setup.swift').read_text()
    assert 'CellRegistration<ToolGroupCellV3, MessageListItem>' in setup

    est = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+HeightEstimation.swift').read_text()
    assert 'ToolGroupRowView.rowHeight' in est

    infra = (IOS / 'Agent/MessageList/MessageListInfrastructure.swift').read_text()
    item_slice = slice_between(infra, 'enum MessageListItem: Hashable {', '// MARK: - Self-Sizing Cell', 'MessageListItem')
    cell_slice = slice_between(infra, 'class SelfSizingCell: UICollectionViewCell {', '// MARK: - NoAnimationCollectionView', 'SelfSizingCell')
    assert 'contentView.systemLayoutSizeFitting(' in cell_slice
    assert 'UIView.layoutFittingCompressedSize.height' in cell_slice

    (OUT / 'ProductionMessageListItem.swift').write_text('import Foundation\n\n' + item_slice + '\n')
    (OUT / 'ProductionSelfSizingCell.swift').write_text(
        'import Combine\nimport Foundation\nimport SwiftUI\nimport UIKit\n\n' + cell_slice + '\n')

    fixture = (ROOT / 'scripts/toolfold-uikit-tests/ToolFoldUIKitFixture.swift').read_text()
    assert 'MessageListLayout()' in fixture
    assert 'ToolGroupCellV3.self' in fixture
    assert 'TOOLFOLD_UIKIT_DIAG' in fixture
    assert 'clearCachedHeight()' in fixture
    (OUT / 'ProductionToolGroupRow.swift').write_text(fixture + '\n' + row_slice + '\n')
    print(f'TOOLFOLD_UIKIT_SLICE_OK bytes={len(row_slice)} cell_bytes={len(cell_slice)}', flush=True)


prepare()
if '--source-only' in sys.argv:
    print('TOOLFOLD_UIKIT_SOURCE_ONLY (UIKit runtime NOT run)')
    sys.exit(0)
if sys.platform != 'darwin':
    raise SystemExit('TOOLFOLD_UIKIT_REQUIRES_MACOS')

APP.mkdir(exist_ok=True)
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
arch = platform.machine()

native = ROOT / 'src/ios/NativeOffloads'
native_text = (native / 'NativeOffloadUtils.m').read_text()
guard_fn = native_text[native_text.index('BOOL noff_try_objc('):native_text.index('// ── Calling session')]
guard_decl = next(line for line in (native / 'NativeOffloadUtils.h').read_text().splitlines()
                  if line.startswith('BOOL noff_try_objc('))
bridge_header = OUT / 'ExceptionBridge.h'
bridge_header.write_text('#import <Foundation/Foundation.h>\n' + guard_decl + '\n')
bridge_source = OUT / 'ExceptionBridge.m'
bridge_source.write_text('#import "ExceptionBridge.h"\n' + guard_fn)
bridge_obj = OUT / 'ExceptionBridge.o'
br = subprocess.run(
    ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-fobjc-arc', '-fblocks',
     '-isysroot', sdk, '-target', f'{arch}-apple-ios16.0-simulator',
     '-c', str(bridge_source), '-o', str(bridge_obj)],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)
(OUT / 'objc-bridge.log').write_text(br.stdout)
if br.returncode:
    print(br.stdout, flush=True)
    raise SystemExit('TOOLFOLD_UIKIT_OBJC_BRIDGE_FAILED')

sources = [
    IOS / 'Agent/MessageList/ToolFoldPlanner.swift',
    IOS / 'Agent/MessageList/MessageListLayout.swift',
    IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift',
    OUT / 'ProductionMessageListItem.swift',
    OUT / 'ProductionSelfSizingCell.swift',
    IOS / 'Agent/MessageList/CollectionViewMessageListV3/Cells/MessageListV3Cells.swift',
    IOS / 'Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedToolGroupV3.swift',
    IOS / 'Views/Chat/AIChatView/Support/ChatColors.swift',
    OUT / 'ProductionToolGroupRow.swift',
]
cmd = [
    'xcrun', '--sdk', 'iphonesimulator', 'swiftc',
    '-swift-version', '5', '-sdk', sdk,
    '-target', f'{arch}-apple-ios16.0-simulator',
    '-import-objc-header', str(bridge_header),
    '-parse-as-library', *map(str, sources), str(bridge_obj),
    '-o', str(APP / 'ToolFoldUIKit'),
]
r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(OUT / 'compile.log').write_text(r.stdout)
print(r.stdout, flush=True)
if r.returncode:
    raise SystemExit('TOOLFOLD_UIKIT_COMPILE_FAILED')

info = {
    'CFBundleIdentifier': 'com.gonepaul.toolfold.uikit',
    'CFBundleExecutable': 'ToolFoldUIKit',
    'CFBundleName': 'ToolFoldUIKit',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1',
    'LSRequiresIPhoneOS': True,
    'MinimumOSVersion': '16.0',
    'UIDeviceFamily': [1],
    'UILaunchScreen': {},
}
(APP / 'Info.plist').write_bytes(plistlib.dumps(info))
run(['codesign', '--force', '--sign', '-', str(APP)])
devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
d = next((d for d in choices if d['state'] == 'Booted'), choices[0])
uid = d['udid']
if d['state'] != 'Booted':
    run(['xcrun', 'simctl', 'boot', uid])
run(['xcrun', 'simctl', 'bootstatus', uid, '-b'])
run(['xcrun', 'simctl', 'install', uid, str(APP)])
container = pathlib.Path(run(['xcrun', 'simctl', 'get_app_container', uid, info['CFBundleIdentifier'], 'data']).strip())
if (container / 'tmp/toolfold-uikit').exists():
    shutil.rmtree(container / 'tmp/toolfold-uikit')
for stale in [*OUT.glob('*.png'), OUT / 'result.log', OUT / 'diag.log']:
    if stale.exists():
        stale.unlink()
try:
    output = run(['xcrun', 'simctl', 'launch', '--console-pty', uid, info['CFBundleIdentifier']], timeout=180)
except subprocess.CalledProcessError as e:
    output = e.output
(OUT / 'launch.log').write_text(output)
print(output, flush=True)
container = pathlib.Path(run(['xcrun', 'simctl', 'get_app_container', uid, info['CFBundleIdentifier'], 'data']).strip())
for p in (container / 'tmp/toolfold-uikit').iterdir():
    shutil.copy2(p, OUT / p.name)
diag_file = OUT / 'diag.log'
if diag_file.exists():
    diag_text = diag_file.read_text()
    print(diag_text, flush=True)
    diag_lines = [l for l in diag_text.splitlines() if l.startswith('TOOLFOLD_UIKIT_DIAG ')]
    assert len(diag_lines) == 12, f'expected 12 TOOLFOLD_UIKIT_DIAG lines, got {len(diag_lines)}'
marker = (OUT / 'result.log').read_text()
print(marker, flush=True)
assert 'TOOLFOLD_UIKIT_PASS checks=21 png=12' in marker, marker
assert len(list(OUT.glob('*.png'))) == 12
print('TOOLFOLD_UIKIT_ARTIFACT_OK png=12', flush=True)
