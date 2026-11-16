#!/usr/bin/env python3
"""Actual ToolGroupRowView + BridgedToolGroupV3 + ToolFoldPlanner in UIHostingConfiguration."""
import json, pathlib, platform, plistlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS = ROOT / 'src' / 'ios'
OUT = ROOT / 'build' / 'toolfold-uikit'
OUT.mkdir(parents=True, exist_ok=True)
APP = OUT / 'ToolFoldUIKit.app'


def run(cmd, **kw):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, **kw)


def prepare():
    abv = (IOS / 'Views/Chat/AssistantBlockView.swift').read_text()
    row_start = abv.index('struct ToolGroupRowView: View {')
    row_end = abv.index('\nextension Notification.Name {', row_start)
    row_slice = abv[row_start:row_end]
    for token in [
        'struct ToolGroupRowView: View {',
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

    fixture = (ROOT / 'scripts/toolfold-uikit-tests/ToolFoldUIKitFixture.swift').read_text()
    (OUT / 'ProductionToolGroupRow.swift').write_text(fixture + '\n' + row_slice + '\n')
    print(f'TOOLFOLD_UIKIT_SLICE_OK bytes={len(row_slice)}', flush=True)


prepare()
if '--source-only' in sys.argv:
    print('TOOLFOLD_UIKIT_SOURCE_ONLY (UIKit runtime NOT run)')
    sys.exit(0)
if sys.platform != 'darwin':
    raise SystemExit('TOOLFOLD_UIKIT_REQUIRES_MACOS')

APP.mkdir(exist_ok=True)
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
sources = [
    IOS / 'Agent/MessageList/ToolFoldPlanner.swift',
    IOS / 'Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedToolGroupV3.swift',
    IOS / 'Views/Chat/AIChatView/Support/ChatColors.swift',
    OUT / 'ProductionToolGroupRow.swift',
]
cmd = [
    'xcrun', '--sdk', 'iphonesimulator', 'swiftc',
    '-swift-version', '5', '-sdk', sdk,
    '-target', f'{platform.machine()}-apple-ios16.0-simulator',
    '-parse-as-library', *map(str, sources), '-o', str(APP / 'ToolFoldUIKit'),
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
for stale in [*OUT.glob('*.png'), OUT / 'result.log']:
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
marker = (OUT / 'result.log').read_text()
print(marker, flush=True)
assert 'TOOLFOLD_UIKIT_PASS checks=21 png=12' in marker, marker
assert len(list(OUT.glob('*.png'))) == 12
print('TOOLFOLD_UIKIT_ARTIFACT_OK png=12', flush=True)
