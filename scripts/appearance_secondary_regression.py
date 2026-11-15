#!/usr/bin/env python3
"""Real AppearanceSettingsView, Return Key menu, six gray menu pickers, secondary App Icon/Language navigation, and remount recovery regression."""
import json
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS = ROOT / 'src/ios'
UI = IOS / 'Views/Chat/AIChatView/MinisUI'
OUT = ROOT / 'build/appearance-secondary'
APP = OUT / 'AppearanceSecondary.app'

REQUIRED_18_LANGS = [
    'de', 'en', 'es', 'fil', 'fr', 'hr', 'id', 'ja', 'ko',
    'ms', 'pl', 'pt-BR', 'ro', 'ru', 'th', 'tr', 'zh-Hans', 'zh-Hant',
]

REQUIRED_KEYS = [
    'Appearance', 'Return Key', 'Newline', 'Send',
    'Choose whether the Return key in the chat input inserts a newline or sends the message. Hardware Shift+Return always inserts a newline.',
    'App Icon', 'Automatic', 'Follows system', 'Light', 'Always light',
    'Dark', 'Always dark', 'Light (Legacy)', 'Classic light icon',
    'Dark (Legacy)', 'Classic dark icon',
    '"Automatic" uses the system icon which adapts to Dark Mode on iOS 18+.',
    'Language', 'System',
    'Override the display language for this app. "System" follows your device language.',
]


def run(cmd, **kw):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT, **kw)


def slice_block(text: str, start_marker: str, end_marker: str) -> str:
    s = text.index(start_marker)
    e = text.index(end_marker, s) + len(end_marker)
    return text[s:e]


def write_lproj_strings(app_dir: pathlib.Path):
    catalog = json.loads((IOS / 'Localizable.xcstrings').read_text())['strings']
    for lang in REQUIRED_18_LANGS:
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


def run_source_checks() -> tuple[str, str, str, str]:
    appearance = (IOS / 'Views/Settings/AppearanceSettingsView.swift').read_text()
    settings_sheet = (IOS / 'Views/Settings/SettingsSheet.swift').read_text()
    content_view = (IOS / 'Views/ContentView/ContentView.swift').read_text()
    minis_app = (IOS / 'MinisApp.swift').read_text()
    catalog = json.loads((IOS / 'Localizable.xcstrings').read_text())['strings']

    checks = 0
    secondary_tint = '.tint(Color(uiColor: .secondaryLabel))'

    assert '.pickerStyle(.segmented)' not in appearance
    checks += 1

    ret_start = appearance.index('Picker("Return Key", selection: $returnKeyBehavior)')
    ret_end = appearance.index('Text("Choose whether the Return key', ret_start)
    ret_sec = appearance[ret_start:ret_end]
    assert '.pickerStyle(.menu)' in ret_sec and secondary_tint in ret_sec
    assert 'Text("Newline").tag(0)' in ret_sec and 'Text("Send").tag(1)' in ret_sec
    assert '@AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0' in appearance
    checks += 1

    gray_menus = re.findall(r'\.pickerStyle\(\.menu\)\s*\.tint\(Color\(uiColor: \.secondaryLabel\)\)', appearance)
    assert len(gray_menus) == 6, f'Expected 6 menu pickers with secondaryLabel tint, got {len(gray_menus)}'
    assert appearance.count(secondary_tint) == 6, 'secondaryLabel tint must stay local to the 6 pickers'
    assert '.fill(Color.accentColor)' in appearance
    checks += 1

    app_body_start = appearance.index('struct AppearanceSettingsView: View {')
    app_icon_start = appearance.index('struct AppIconSettingsView: View {')
    app_body = appearance[app_body_start:app_icon_start]
    assert 'NavigationLink(value: SettingsDestination.appearanceAppIcon)' in app_body
    assert 'NavigationLink(value: SettingsDestination.appearanceLanguage)' in app_body
    assert 'if UIApplication.shared.supportsAlternateIcons {' in app_body
    assert 'ForEach(appIconOptions)' not in app_body
    assert 'ForEach(supportedLanguages)' not in app_body
    checks += 1

    assert appearance.count('AppIconOption(id:') == 5
    assert appearance.count('LanguageOption(id:') == 19
    checks += 1

    lang_view = appearance[appearance.index('struct LanguageSettingsView: View {'):]
    reopen_s = lang_view.index('UserDefaults.standard.set("appearance-language", forKey: "pendingSettingsReopen")')
    suspend_s = lang_view.index('ViewModelCache.shared.suspendAllForTreeRemount()')
    write_s = lang_view.index('appLanguage = lang.id')
    bundle_s = lang_view.index('Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)')
    assert reopen_s < suspend_s < write_s < bundle_s
    checks += 1

    assert 'NavigationLink(value: SettingsDestination.appearance)' in settings_sheet
    assert 'case appearanceAppIcon' in settings_sheet and 'case appearanceLanguage' in settings_sheet
    assert 'case .appearanceAppIcon:\n                    AppIconSettingsView()' in settings_sheet
    assert 'case .appearanceLanguage:\n                    LanguageSettingsView()' in settings_sheet
    assert 'case "appearance-language":\n                        navPath.append(SettingsDestination.appearance)\n                        navPath.append(SettingsDestination.appearanceLanguage)' in settings_sheet
    assert 'case "appearance":\n                        navPath.append(SettingsDestination.appearance)' in settings_sheet
    checks += 1

    assert 'UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil' in content_view
    assert 'activeToolSheet = .settings' in content_view
    assert '.id(appLanguage)' in minis_app
    assert '.environment(\\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))' in minis_app
    checks += 1

    req_langs = set(REQUIRED_18_LANGS)
    for k in REQUIRED_KEYS:
        assert k in catalog, f'Missing key in Localizable.xcstrings: {k}'
        locs = catalog[k].get('localizations', {})
        assert req_langs.issubset(set(locs.keys())), f'Incomplete 18-lang coverage: {k}'
        for l in REQUIRED_18_LANGS:
            val = locs[l].get('stringUnit', {}).get('value', '')
            assert val, f'Empty value for key={k!r} lang={l}'
    checks += 1

    swift_bin = shutil.which('swift')
    if swift_bin:
        r = subprocess.run(
            [swift_bin, 'AppearanceSecondarySettingsTests.swift'],
            cwd=str(IOS / 'MinisTests/Standalone'),
            capture_output=True, text=True, check=False,
        )
        print(r.stdout, flush=True)
        assert r.returncode == 0 and 'ALL PASSED' in r.stdout, r.stdout + r.stderr
        checks += 1

    print(f'APPEARANCE_SECONDARY_SOURCE_PASS checks={checks} keys={len(REQUIRED_KEYS)} langs={len(REQUIRED_18_LANGS)}', flush=True)
    return appearance, settings_sheet, minis_app, (UI / 'MinisUIView.swift').read_text()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    _, settings_sheet, minis_app, minis_ui = run_source_checks()

    if '--source-only' in sys.argv:
        print('APPEARANCE_SECONDARY_SOURCE_ONLY UIKit runtime & pixel verification NOT run')
        return
    if sys.platform != 'darwin':
        raise SystemExit('APPEARANCE_SECONDARY_REQUIRES_MACOS')

    renderer = minis_ui[minis_ui.index('struct MUContext {'):]
    bundle_ext = slice_block(minis_app, 'extension Bundle {', '\n}\n')
    settings_dest = slice_block(settings_sheet, 'enum SettingsDestination: Hashable {', '\n}\n')
    fixture = (ROOT / 'scripts/appearance-secondary-tests/AppearanceSecondaryFixture.swift').read_text()
    fixture_lines = [l for l in fixture.splitlines() if not l.startswith('import ')]
    fixture_body = '\n'.join(fixture_lines)

    bridges = '''
enum AlwaysOnController {
    static let idleSecondsKey = "alwaysOnIdleSeconds"
    static let idleChoices = [0, 30, 60, 120, 300]
}

enum StopConfirmPolicy {
    static let settingsKey = "chat.confirmBeforeStopping"
    static let defaultValue = false
}

extension Notification.Name {
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")
}

@MainActor
final class ViewModelCache {
    static let shared = ViewModelCache()
    var suspendCount = 0
    var events: [String] = []
    func suspendAllForTreeRemount(resumeAfter seconds: TimeInterval = 0.4) {
        suspendCount += 1
        let pending = UserDefaults.standard.string(forKey: "pendingSettingsReopen") ?? "nil"
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        events.append("suspend(pending=\\(pending),appLang=\\(lang))")
    }
}
'''

    harness_path = OUT / 'ProductionHarness.swift'
    harness_path.write_text(
        'import Charts\nimport Combine\nimport Foundation\nimport ObjectiveC.runtime\nimport SwiftUI\nimport UIKit\n\n'
        + renderer + '\n'
        + bundle_ext + '\n'
        + settings_dest + '\n'
        + bridges + '\n'
        + fixture_body + '\n'
    )

    if APP.exists():
        shutil.rmtree(APP)
    APP.mkdir(parents=True, exist_ok=True)
    write_lproj_strings(APP)

    alt_src = IOS / 'Resources/AlternateIcons'
    if alt_src.is_dir():
        shutil.copytree(alt_src, APP / 'AlternateIcons')

    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
    sources = [
        UI / 'MinisUICore.swift',
        UI / 'MinisUIMapCore.swift',
        UI / 'MinisUIMapData.swift',
        UI / 'MinisUIMapPack.swift',
        UI / 'MinisUIMapView.swift',
        UI.parent / 'Support/ChatColors.swift',
        IOS / 'Shared/FontSettings.swift',
        IOS / 'Shared/AppLocalization.swift',
        IOS / 'Views/Settings/AppearanceSettingsView.swift',
        harness_path,
    ]
    r = subprocess.run(
        ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
         '-target', f'{platform.machine()}-apple-ios16.0-simulator', '-parse-as-library',
         *map(str, sources), '-o', str(APP / 'AppearanceSecondary')],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    (OUT / 'compile.log').write_text(r.stdout)
    print(r.stdout, flush=True)
    if r.returncode:
        raise SystemExit('APPEARANCE_SECONDARY_COMPILE_FAILED')

    prod_plist = plistlib.loads((IOS / 'Info.plist').read_bytes())
    info = {
        'CFBundleIdentifier': 'com.minismod.appearance.secondary',
        'CFBundleExecutable': 'AppearanceSecondary',
        'CFBundleName': 'AppearanceSecondary',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1',
        'LSRequiresIPhoneOS': True,
        'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [1],
        'UILaunchScreen': {},
    }
    for k in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        if k in prod_plist:
            info[k] = prod_plist[k]
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
    if (container / 'tmp/appearance-secondary').exists():
        shutil.rmtree(container / 'tmp/appearance-secondary')
    for stale in [*OUT.glob('*.png'), OUT / 'result.log']:
        if stale.exists():
            stale.unlink()
    try:
        output = run(['xcrun', 'simctl', 'launch', '--console-pty', uid, info['CFBundleIdentifier']], timeout=300)
    except subprocess.CalledProcessError as e:
        output = e.output
    (OUT / 'launch.log').write_text(output)
    print(output, flush=True)
    for p in (container / 'tmp/appearance-secondary').iterdir():
        shutil.copy2(p, OUT / p.name)
    marker = (OUT / 'result.log').read_text().strip()
    print(marker, flush=True)
    m = re.search(r'APPEARANCE_SECONDARY_PASS checks=(\d+) png=(\d+)', marker)
    assert m and int(m.group(1)) >= 50 and int(m.group(2)) == 8, marker
    assert len(list(OUT.glob('*.png'))) == 8
    print('APPEARANCE_SECONDARY_ARTIFACT_OK png=8', flush=True)


if __name__ == '__main__':
    main()
