#!/usr/bin/env python3
"""Real Settings menu, collapsed/expanded compact preview, and multilingual regression."""
import json
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI = ROOT / 'src/ios/Views/Chat/AIChatView/MinisUI'
OUT = ROOT / 'build/settings-menu'
APP = OUT / 'SettingsMenu.app'

REQUIRED_18_LANGS = {
    'de', 'en', 'es', 'fil', 'fr', 'hr', 'id', 'ja', 'ko',
    'ms', 'pl', 'pt-BR', 'ro', 'ru', 'th', 'tr', 'zh-Hans', 'zh-Hant',
}
REQUIRED_KEYS = [
    'Interactive Cards · Charts & Maps', 'Chart stroke weight', 'Fine', 'Bold',
    'Chart line pattern', 'Solid', 'Dashed context series', 'All lines dashed',
    'Cards follow Chat Theme; charts and maps keep independent colours. Line weight adjusts chart lines, axes and grid; dashed styles apply only to line charts, not maps. Chart settings are saved separately.',
    'Sample trend', 'Text follows Chat Theme', 'Sample', 'Main', 'Comparison',
    'Jan', 'Feb', 'Mar', 'Apr', 'All', 'No data', 'Source: ',
    'First %@ · Last %@', '%d other regions have no data',
    'Chat Theme', 'Default Theme',
    'Colours for chat background, bubbles, text and the send button. Light / Dark above still applies.',
    'Chart Colours', 'The Economist', 'The Economist (2017 guide)',
]


def run(cmd, **kw):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, **kw)


def write_lproj_strings(app_dir: pathlib.Path):
    catalog = json.loads((ROOT / 'src/ios/Localizable.xcstrings').read_text())['strings']
    for lang in ['en', 'zh-Hans', 'zh-Hant']:
        lproj = app_dir / f'{lang}.lproj'
        lproj.mkdir(parents=True, exist_ok=True)
        lines = []
        for k, v in catalog.items():
            locs = v.get('localizations', {})
            if lang in locs and 'stringUnit' in locs[lang]:
                val = locs[lang]['stringUnit']['value']
                ek = json.dumps(k, ensure_ascii=False)
                ev = json.dumps(val, ensure_ascii=False)
                lines.append(f'{ek} = {ev};')
        (lproj / 'Localizable.strings').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    appearance = (ROOT / 'src/ios/Views/Settings/AppearanceSettingsView.swift').read_text()
    minis_ui = (UI / 'MinisUIView.swift').read_text()
    catalog = json.loads((ROOT / 'src/ios/Localizable.xcstrings').read_text())['strings']

    assert appearance.count('.pickerStyle(.menu)') >= 5, 'Expected unified .menu pickers in AppearanceSettingsView'
    assert 'Picker("Theme", selection: $appearanceMode)' in appearance
    assert '.pickerStyle(.segmented)' not in appearance[:appearance.index('Picker("Chat Theme"')]
    assert 'func chatThemeRow(' not in appearance and 'func chatThemePreview(' not in appearance
    assert 'ChatThemeStore.select(newId)' in appearance
    assert '@State private var isPreviewExpanded = false' in appearance
    assert r'.environment(\.muChartPlotHeight, 104)' in minis_ui
    assert 'private var chartHeight: CGFloat { 180 }' in minis_ui
    assert 'enum MUMapL10n {' in (UI / 'MinisUIMapCore.swift').read_text()
    assert 'private struct MUChartPlotHeightKey: EnvironmentKey' in (UI / 'MinisUIMapView.swift').read_text()
    for k in REQUIRED_KEYS:
        assert k in catalog, f'Missing key in Localizable.xcstrings: {k}'
        assert REQUIRED_18_LANGS.issubset(set(catalog[k].get('localizations', {}).keys())), f'Incomplete 18-lang coverage: {k}'
    print('SETTINGS_MENU_SOURCE_PASS checks=9 keys=29 langs=18', flush=True)

    if '--source-only' in sys.argv:
        print('SETTINGS_MENU_SOURCE_ONLY UIKit runtime NOT run')
        return
    if sys.platform != 'darwin':
        raise SystemExit('SETTINGS_MENU_REQUIRES_MACOS')

    renderer = minis_ui[minis_ui.index('struct MUContext {'):]
    fixture = (ROOT / 'scripts/settings-menu-tests/SettingsMenuFixture.swift').read_text()
    (OUT / 'ProductionRenderer.swift').write_text(
        'import SwiftUI\nimport UIKit\nimport Charts\n' + renderer + '\n' + fixture
    )

    APP.mkdir(exist_ok=True)
    write_lproj_strings(APP)
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
    sources = [
        UI / n for n in [
            'MinisUICore.swift', 'MinisUIMapCore.swift', 'MinisUIMapData.swift',
            'MinisUIMapPack.swift', 'MinisUIMapView.swift',
        ]
    ] + [UI.parent / 'Support/ChatColors.swift', OUT / 'ProductionRenderer.swift']
    r = subprocess.run(
        ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
         '-target', f'{platform.machine()}-apple-ios16.0-simulator', '-parse-as-library',
         *map(str, sources), '-o', str(APP / 'SettingsMenu')],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    (OUT / 'compile.log').write_text(r.stdout)
    print(r.stdout, flush=True)
    if r.returncode:
        raise SystemExit('SETTINGS_MENU_COMPILE_FAILED')

    info = {
        'CFBundleIdentifier': 'com.minismod.settings.menu',
        'CFBundleExecutable': 'SettingsMenu',
        'CFBundleName': 'SettingsMenu',
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
    if (container / 'tmp/settings-menu').exists():
        shutil.rmtree(container / 'tmp/settings-menu')
    for stale in [*OUT.glob('*.png'), OUT / 'result.log']:
        if stale.exists():
            stale.unlink()
    try:
        output = run(['xcrun', 'simctl', 'launch', '--console-pty', uid, info['CFBundleIdentifier']], timeout=300)
    except subprocess.CalledProcessError as e:
        output = e.output
    (OUT / 'launch.log').write_text(output)
    print(output, flush=True)
    for p in (container / 'tmp/settings-menu').iterdir():
        shutil.copy2(p, OUT / p.name)
    marker = (OUT / 'result.log').read_text()
    print(marker, flush=True)
    assert 'SETTINGS_MENU_PASS checks=31 png=6' in marker, marker
    assert len(list(OUT.glob('*.png'))) == 6
    print('SETTINGS_MENU_ARTIFACT_OK png=6', flush=True)


if __name__ == '__main__':
    main()
