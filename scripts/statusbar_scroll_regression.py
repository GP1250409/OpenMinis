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

import json
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / 'scripts' / 'statusbar-scroll-tests'
PROD = ROOT / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift'
OUT = pathlib.Path(tempfile.mkdtemp(prefix='statusbar-scroll-'))
LOGIC_FLOOR = 40
UIKIT_FLOOR = 25


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print('+', ' '.join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, text=True, **kwargs)


def fail(message: str) -> None:
    print('STATUSBAR_SCROLL_FAIL ' + message)
    raise SystemExit(1)


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
    uikit = run_uikit()
    if uikit < 0:
        # Honest local scope: Linux has no UIKit; CI is the platform that runs it.
        print('STATUSBAR_SCROLL_LOCAL_LOGIC_ONLY uikit=unavailable platform=' + platform.system())
        return
    print(f'STATUSBAR_SCROLL_PASS logic={LOGIC_FLOOR}+ uikit={uikit}')


if __name__ == '__main__':
    main()
