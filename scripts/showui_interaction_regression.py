#!/usr/bin/env python3
"""ShowUI interaction theme regression (typography + palette + action contrast).

Three layers, each one honest about what it actually ran:

  --source-only            static contract only (runs anywhere, claims nothing else)
  (default, Linux)         static + the pure Foundation role/token suite compiled
                           with the local swiftc (real production slice)
  (default, macOS)         static + pure suite + the real UIKit 24-case renderer
                           (production MUNodeView / MUCallout / MUTable / MUButton)

The UIKit layer renders the confirmed matrix 3 chart palettes x 4 chat themes x
day/night = 24 cases into build/showui-interaction/png/ (24 PNGs) and prints
`SHOWUI_INTERACTION_PASS checks=<real> cases=24 png=24`; the driver then prints
`SHOWUI_INTERACTION_ARTIFACT_OK png=24` after it has copied exactly those files.
"""
import pathlib
import json
import platform
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI = ROOT / 'src/ios/Views/Chat/AIChatView/MinisUI'
TESTS = ROOT / 'scripts/showui-interaction-tests'
OUT = ROOT / 'build/showui-interaction'
PNG = OUT / 'png'
OUT.mkdir(parents=True, exist_ok=True)

source_only = '--source-only' in sys.argv[1:]
swiftc = shutil.which('swiftc')
if '--swiftc' in sys.argv[1:]:
    swiftc = sys.argv[sys.argv.index('--swiftc') + 1]

failures = []
def need(cond, msg):
    if cond:
        print('SOURCE_CHECK_OK: ' + msg, flush=True)
    else:
        failures.append(msg)
        print('SOURCE_CHECK_FAILED: ' + msg, flush=True)

core = (UI / 'MinisUICore.swift').read_text()
view = (UI / 'MinisUIView.swift').read_text()
prompt = (UI / 'AIChatViewModel+GenUI.swift').read_text()
colors = (UI.parent / 'Support/ChatColors.swift').read_text()

# --- 1. typography: one role function owns the size for view + estimate ------
need('enum MUTextRole: String, CaseIterable' in core, 'one text-role enum in pure Foundation core')
need('case .body: return 14' in core and 'case .note: return 12' in core
     and 'case .source: return MUChartTypography.source' in core,
     'roles are 14 / 12 / the shared 10.5 source size')
need('static func style(role: String?, size: Double?, tone: String?, text: String)' in core,
     'role/size/tone/legacy resolution is one pure function')
need('MUArg("role", .oneOf(MUTextRole.names), false)' in core
     and 'MUArg("size", .number, false)' in core,
     'Text accepts optional role/size, so old programs keep compiling')
need('.font(.system(size: MUTextStyle.style(comp).size))' in view,
     'the view draws the size the same function resolves')
need('let style = MUTextStyle.style(c)\n                return style.lineHeight * textLines' in core,
     'the estimate uses the same resolved size and line box')
callout = view[view.index('private struct MUCallout: View'):]
callout = callout[:callout.index('\n}\n')]
need('frame(width: 3)' not in callout, 'the callout has no 3pt leading bar')
need('MUTextRole.note.size' in callout, 'the callout body is the 12pt note role')
need('ChatColors.' not in callout, 'the callout takes no colour from the chat theme')
need('MUChartInteractionTheme.resolved(tone: tone, dark: scheme == .dark, palette: paletteKey)' in callout,
     'the callout resolves from the palette + colour scheme')
need('@AppStorage(MUChartStyle.key) private var paletteKey' in callout,
     'the callout reads the real genuiChartPalette AppStorage value')
need('RoundedRectangle(cornerRadius: 1.5' not in callout and 'Rectangle()' not in callout,
     'no full-height accent rule is left inside the box')

# --- 2. palette: table + callout interior, day/night, chat independent ------
for name in ['static let system = MUChartInteriorPalette', 'static let economist = MUChartInteriorPalette',
             'static let economist2017 = MUChartInteriorPalette']:
    need(name in core, name.split(' = ')[0] + ' preset exists')
need('static func preset(_ key: String) -> MUChartInteriorPalette' in core
     and 'case "economist2017": return .economist2017' in core,
     'preset keys match genuiChartPalette ("" / economist / economist2017)')
table = view[view.index('private struct MUTable: View'):]
table = table[:table.index('\n}\n')]
need('MUChartInteractionTheme.interior(paletteKey, dark: scheme == .dark)' in table,
     'the table panel reads the same palette tokens')
need('tokens.panel.color' in table and 'tokens.ink.color' in table and 'tokens.rule.color' in table,
     'table ground, hairline and ink are palette tokens')
need('foregroundStyle(header ? .secondary : .primary)' not in table,
     'table text no longer falls back to system primary/secondary')
need('ChatColors.' not in table, 'the table interior never reads the chat theme')
need('struct MUChartInteriorTokens' in core and 'static func interior(_ palette: String, dark: Bool)' in core,
     'one interior resolver for both components')
need('static let key = "genuiChartPalette"' in view, 'the palette key is genuiChartPalette')

# --- 3. action button: chat tint fill, measured label ----------------------
button = view[view.index('private struct MUButton: View'):]
button = button[:button.index('\n}\n')]
need('ChatColors.tint' in button and 'MUActionText.on(base)' in button,
     'the primary fill follows ChatColors.tint and the label is measured on it')
need('foregroundStyle(primary ? ChatColors.onTint' not in button,
     'the button no longer assumes a pure-white onTint')
need('MUActionText.secondaryInk' in button, 'the secondary style has its own contrast floor')
need('enum MUActionText' in core and 'static let soft = MUMapRGB(hex: "#E4E6EB")' in core
     and 'static let deep = MUMapRGB(hex: "#080808")' in core,
     'the action text is the demo v2 soft/near-black pair, not a global token edit')
need('static var onTint' in colors and 'ChatThemePair' in colors,
     'ChatColors is untouched by the per-call-site adaptation')

# --- 4. prompt teaches the new contract -----------------------------------
need('role' in prompt and 'source' in prompt, 'the show_ui prompt documents the text roles')
need('数据：' in prompt or '来源：' in prompt or 'Source:' in prompt,
     'the prompt tells the model how to write a source line')

# --- 5. other real fixtures keep the components they slice -----------------
for script, syms in [('scripts/card_dark_regression.py', ['private struct MUCallout:']),
                     ('scripts/theme_matrix_regression.py', ['MinisUIView.swift'])]:
    text = (ROOT / script).read_text()
    for sym in syms:
        need(sym in text, f'{script} still slices {sym}')

if failures:
    print('SHOWUI_INTERACTION_STATIC_FAILED failures=%d' % len(failures), flush=True)
    raise SystemExit(1)
print('SHOWUI_INTERACTION_SOURCE_PASS checks=ok', flush=True)
if source_only:
    print('SHOWUI_INTERACTION_SOURCE_ONLY pure suite and UIKit runtime NOT run', flush=True)
    raise SystemExit(0)

# --- 6. pure Foundation suite (real swiftc, production slice) -------------
pure_ok = False
if not swiftc:
    print('SHOWUI_INTERACTION_PURE_NOT_RUN swiftc missing', flush=True)
else:
    binary = OUT / 'pure-checks'
    cmd = [swiftc, '-swift-version', '5', str(UI / 'MinisUICore.swift'), str(UI / 'MinisUIMapCore.swift'),
           str(UI / 'MinisUIMapData.swift'), str(UI / 'MinisUIMapPack.swift'),
           str(TESTS / 'main.swift'), '-o', str(binary)]
    print('COMPILE: swiftc MinisUICore.swift main.swift', flush=True)
    r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / 'pure-compile.log').write_text(r.stdout)
    if r.returncode:
        print(r.stdout, flush=True)
        print('SHOWUI_INTERACTION_PURE_COMPILE_FAILED', flush=True)
        raise SystemExit(1)
    r = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / 'pure.log').write_text(r.stdout)
    print(r.stdout, flush=True)
    if r.returncode or 'SHOWUI_ROLE_TOKEN_PASS checks=' not in r.stdout:
        print('SHOWUI_INTERACTION_PURE_FAILED', flush=True)
        raise SystemExit(1)
    pure_ok = True

# --- 7. real UIKit renderer: 3 palettes x 4 chats x day/night = 24 --------
if sys.platform != 'darwin':
    print('SHOWUI_INTERACTION_UIKIT_NOT_RUN requires macOS simulator; pure checks only', flush=True)
    raise SystemExit(0 if pure_ok else 1)

APP = OUT / 'ShowUIInteraction.app'
renderer = view[view.index('struct MUContext {'):]
fixture = (TESTS / 'ShowUIInteractionFixture.swift').read_text()
(OUT / 'ProductionRenderer.swift').write_text(
    'import SwiftUI\nimport UIKit\nimport Charts\n' + renderer + '\n' + fixture)
APP.mkdir(exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
sources = [UI / n for n in ['MinisUICore.swift', 'MinisUIMapCore.swift', 'MinisUIMapData.swift',
                            'MinisUIMapPack.swift', 'MinisUIMapView.swift']]
sources += [UI.parent / 'Support/ChatColors.swift', OUT / 'ProductionRenderer.swift']
r = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
                    '-target', f'{platform.machine()}-apple-ios16.0-simulator', '-parse-as-library',
                    *map(str, sources), '-o', str(APP / 'ShowUIInteraction')],
                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(OUT / 'compile.log').write_text(r.stdout)
print(r.stdout, flush=True)
if r.returncode:
    print('SHOWUI_INTERACTION_UIKIT_COMPILE_FAILED', flush=True)
    raise SystemExit(1)
info = {'CFBundleIdentifier': 'com.minismod.showui.interaction', 'CFBundleExecutable': 'ShowUIInteraction',
        'CFBundleName': 'ShowUIInteraction', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1', 'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [1], 'UILaunchScreen': {}}
# Compile only the exact production AccentColor catalog, not a hand-drawn
# replacement. Match Xcode's GLOBAL_ACCENT_COLOR_NAME via actool metadata.
assets = OUT / 'FixtureAssets.xcassets'
if assets.exists():
    shutil.rmtree(assets)
assets.mkdir()
(assets / 'Contents.json').write_text(json.dumps({'info': {'version': 1, 'author': 'xcode'}}))
accent_source = ROOT / 'src/ios/Assets.xcassets/AccentColor.colorset'
shutil.copytree(accent_source, assets / 'AccentColor.colorset')
asset_info = OUT / 'asset-info.plist'
r = subprocess.run(['xcrun', 'actool', '--compile', str(APP), '--platform', 'iphonesimulator',
                    '--minimum-deployment-target', '16.0', '--target-device', 'iphone',
                    '--accent-color', 'AccentColor', '--output-partial-info-plist', str(asset_info),
                    str(assets)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(OUT / 'asset-compile.log').write_text(r.stdout)
if r.returncode or not asset_info.exists() or not (APP / 'Assets.car').exists():
    print(r.stdout, flush=True)
    print('SHOWUI_INTERACTION_ASSET_FAILED', flush=True)
    raise SystemExit(1)
info.update(plistlib.loads(asset_info.read_bytes()))
info['UIAccentColorName'] = 'AccentColor'
print('SHOWUI_INTERACTION_ASSET_OK exact=AccentColor.colorset', flush=True)
(APP / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.check_call(['codesign', '--force', '--sign', '-', str(APP)])
devices = json_load = None
import json
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True))['devices']
choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
device = next((d for d in choices if d['state'] == 'Booted'), choices[0])
uid = device['udid']
if device['state'] != 'Booted':
    subprocess.check_call(['xcrun', 'simctl', 'boot', uid])
subprocess.check_call(['xcrun', 'simctl', 'bootstatus', uid, '-b'])
subprocess.check_call(['xcrun', 'simctl', 'install', uid, str(APP)])
container = pathlib.Path(subprocess.check_output(
    ['xcrun', 'simctl', 'get_app_container', uid, info['CFBundleIdentifier'], 'data'], text=True).strip())
if (container / 'tmp/showui-interaction').exists():
    shutil.rmtree(container / 'tmp/showui-interaction')
if PNG.exists():
    shutil.rmtree(PNG)
launch_failed = False
try:
    output = subprocess.check_output(['xcrun', 'simctl', 'launch', '--console-pty', uid,
                                      info['CFBundleIdentifier']], text=True, timeout=600)
except subprocess.CalledProcessError as e:
    launch_failed = True
    output = e.output or ''
except subprocess.TimeoutExpired as e:
    launch_failed = True
    output = (e.output or b'').decode('utf-8', 'replace') if isinstance(e.output, bytes) else (e.output or '')
    print('SHOWUI_INTERACTION_TIMEOUT simulator launch exceeded 600s', flush=True)
(OUT / 'launch.log').write_text(output)
print(output, flush=True)
produced = container / 'tmp/showui-interaction'
if not produced.exists() or not any(produced.iterdir()):
    print('SHOWUI_INTERACTION_NO_FIXTURE_OUTPUT container=%s' % produced, flush=True)
    raise SystemExit(1)
PNG.mkdir(parents=True, exist_ok=True)
for p in produced.iterdir():
    shutil.copy2(p, PNG / p.name)
if launch_failed:
    print('SHOWUI_INTERACTION_LAUNCH_FAILED diagnostics copied; signing blocked', flush=True)
    raise SystemExit(1)
if not (PNG / 'result.log').exists():
    print('SHOWUI_INTERACTION_RESULT_LOG_MISSING launch produced no result.log', flush=True)
    raise SystemExit(1)
marker = (PNG / 'result.log').read_text()
print(marker, flush=True)
if 'FAILED' in marker or 'SHOWUI_INTERACTION_FAILED' in marker:
    print('SHOWUI_INTERACTION_FAILED', flush=True)
    raise SystemExit(1)
if 'SHOWUI_INTERACTION_PASS' not in marker or 'cases=24 png=24' not in marker:
    print('SHOWUI_INTERACTION_MARKER_MISSING', flush=True)
    raise SystemExit(1)
pngs = sorted(PNG.glob('*.png'))
if len(pngs) != 24:
    print(f'SHOWUI_INTERACTION_PNG_COUNT_FAILED png={len(pngs)}', flush=True)
    raise SystemExit(1)
print('SHOWUI_INTERACTION_ARTIFACT_OK png=24', flush=True)
