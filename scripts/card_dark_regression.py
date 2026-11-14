#!/usr/bin/env python3
"""Actual MUNodeView renderer in UIHostingConfiguration + collection/window.
Only app state/action context is stubbed. No ImageRenderer or hand-built text.
"""
import json, os, pathlib, platform, plistlib, re, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
UI=ROOT/'src/ios/Views/Chat/AIChatView/MinisUI'
BASELINE = '--baseline' in sys.argv
OUT=ROOT/('build/card-dark-baseline' if BASELINE else 'build/card-dark'); OUT.mkdir(parents=True,exist_ok=True)
APP=OUT/'CardDark.app'
def run(cmd,**kw):
    return subprocess.check_output(cmd,text=True,stderr=subprocess.STDOUT,**kw)
def original(path):
    return run(['git','show','88103702b3718f95bc3ff7f4944c4bdd08b0322e:'+str(path.relative_to(ROOT))])
def prepare():
    text=original(UI/'MinisUIView.swift') if BASELINE else (UI/'MinisUIView.swift').read_text()
    renderer=text[text.index('struct MUContext {'):]
    for token in ['struct MUNodeView:', 'private struct MUCard:', 'private struct MUList:', 'private struct MUCallout:']:
        assert token in renderer
    fixture=(ROOT/'scripts/card-dark-tests/CardDarkFixture.swift').read_text()
    if BASELINE:
        # Identical 42 mounted body-pixel assertions, omit NEW nativeFill API tests.
        a=fixture.index('    func testSurfaces()')
        b=fixture.index('    func finish()',a)
        fixture=fixture[:a]+'    func testSurfaces() { finish() }\n'+fixture[b:]
        fixture=fixture.replace('ChatColors.backgroundUIColor','(ChatThemeStore.current?.background.uiColor ?? UIColor.systemBackground)').replace('ChatColors.secondaryBgUIColor','(ChatThemeStore.current?.secondaryBg.uiColor ?? UIColor.secondarySystemBackground)')
        # Expected backgrounds are independently resolved from native tokens;
        # baseline MUSurface only accepts Color, unlike the new overload.
        fixture=fixture.replace('MUSurface.rgb((ChatThemeStore.current?.background.uiColor ?? UIColor.systemBackground),', 'nativeRGB((ChatThemeStore.current?.background.uiColor ?? UIColor.systemBackground),').replace('MUSurface.rgb((ChatThemeStore.current?.secondaryBg.uiColor ?? UIColor.secondarySystemBackground),', 'nativeRGB((ChatThemeStore.current?.secondaryBg.uiColor ?? UIColor.secondarySystemBackground),').replace('MUSurface.rgb(UIColor.label.withAlphaComponent(0.04),','nativeRGB(UIColor.label.withAlphaComponent(0.04),')
        for path in [UI/'MinisUIMapView.swift', UI.parent/'Support/ChatColors.swift']:
            (OUT/path.name).write_text(original(path))
    (OUT/'ProductionRenderer.swift').write_text('import SwiftUI\nimport UIKit\nimport Charts\n'+renderer+'\n'+fixture)
    print('CARD_DARK_PRODUCTION_SLICE_OK bytes='+str(len(renderer)),flush=True)
prepare()
if '--source-only' in sys.argv:
    print('CARD_DARK_SOURCE_ONLY (UIKit runtime NOT run)'); sys.exit(0)
if sys.platform!='darwin': raise SystemExit('CARD_DARK_REQUIRES_MACOS')
APP.mkdir(exist_ok=True)
sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']).strip()
sources=[UI/n for n in ['MinisUICore.swift','MinisUIMapCore.swift','MinisUIMapData.swift','MinisUIMapPack.swift','MinisUIMapView.swift']]+[UI.parent/'Support/ChatColors.swift',OUT/'ProductionRenderer.swift']
if BASELINE:
    sources=[(OUT/p.name if p.name in ['MinisUIMapView.swift','ChatColors.swift'] else p) for p in sources]
cmd=['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target',f'{platform.machine()}-apple-ios16.0-simulator','-parse-as-library',*map(str,sources),'-o',str(APP/'CardDark')]
r=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(OUT/'compile.log').write_text(r.stdout); print(r.stdout,flush=True)
if r.returncode: raise SystemExit('CARD_DARK_COMPILE_FAILED')
info={'CFBundleIdentifier':'com.gonepaul.card.dark','CFBundleExecutable':'CardDark','CFBundleName':'CardDark','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
run(['codesign','--force','--sign','-',str(APP)])
devices=json.loads(run(['xcrun','simctl','list','devices','available','-j']))['devices']
choices=[d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
d=next((d for d in choices if d['state']=='Booted'),choices[0]); uid=d['udid']
if d['state']!='Booted': run(['xcrun','simctl','boot',uid])
run(['xcrun','simctl','bootstatus',uid,'-b']); run(['xcrun','simctl','install',uid,str(APP)])
container=pathlib.Path(run(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data']).strip())
# Only this fixture's temporary simulator output; never an installed user app/package.
if (container/'tmp/card-dark').exists(): shutil.rmtree(container/'tmp/card-dark')
for stale in [*OUT.glob('*.png'), OUT/'result.log']:
    if stale.exists(): stale.unlink()
try:
    output=run(['xcrun','simctl','launch','--console-pty',uid,info['CFBundleIdentifier']],timeout=180)
except subprocess.CalledProcessError as e:
    output=e.output
(OUT/'launch.log').write_text(output); print(output,flush=True)
container=pathlib.Path(run(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data']).strip())
for p in (container/'tmp/card-dark').iterdir(): shutil.copy2(p,OUT/p.name)
marker=(OUT/'result.log').read_text(); print(marker,flush=True)
if BASELINE:
    print('CARD_DARK_BASELINE_BODY_FAILURE_REPRODUCED='+str('HOST_FAIL' in marker),flush=True)
    # Observation, never substituted for the current-code hard gate.
    sys.exit(0)
assert 'CARD_DARK_HOST_PASS checks=58 png=46' in marker, marker
assert len(list(OUT.glob('*.png')))==46
print('CARD_DARK_ARTIFACT_OK png=46',flush=True)
