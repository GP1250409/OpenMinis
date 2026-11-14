#!/usr/bin/env python3
"""Real production MUNodeView in a UIKit window; not a substitute for device QA."""
import json, pathlib, platform, plistlib, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
UI=ROOT/'src/ios/Views/Chat/AIChatView/MinisUI'
OUT=ROOT/'build/theme-matrix'; OUT.mkdir(parents=True,exist_ok=True)
APP=OUT/'ThemeMatrix.app'
def run(cmd,**kw): return subprocess.check_output(cmd,text=True,stderr=subprocess.STDOUT,**kw)
text=(UI/'MinisUIView.swift').read_text()
renderer=text[text.index('struct MUContext {'):]
fixture=(ROOT/'scripts/theme-matrix-tests/ThemeMatrixFixture.swift').read_text()
(OUT/'ProductionRenderer.swift').write_text('import SwiftUI\nimport UIKit\nimport Charts\n'+renderer+'\n'+fixture)
assert '@AppStorage(ChatThemeStore.key)' in (UI/'MinisUIMapView.swift').read_text()
assert 'drawing.width(isGreyed(s)' in renderer and 'drawing.dash(context: isGreyed(s))' in renderer
assert 'genuiChartStrokeWeight' in renderer and 'genuiChartLinePattern' in renderer
assert 'MUChartSettingsPreview()' in (ROOT/'src/ios/Views/Settings/AppearanceSettingsView.swift').read_text()
print('THEME_MATRIX_SOURCE_PASS wiring=5',flush=True)
if '--source-only' in sys.argv:
    print('THEME_MATRIX_SOURCE_ONLY UIKit runtime NOT run'); sys.exit(0)
if sys.platform!='darwin': raise SystemExit('THEME_MATRIX_REQUIRES_MACOS')
APP.mkdir(exist_ok=True)
sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']).strip()
sources=[UI/n for n in ['MinisUICore.swift','MinisUIMapCore.swift','MinisUIMapData.swift','MinisUIMapPack.swift','MinisUIMapView.swift']]+[UI.parent/'Support/ChatColors.swift',OUT/'ProductionRenderer.swift']
r=subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target',f'{platform.machine()}-apple-ios16.0-simulator','-parse-as-library',*map(str,sources),'-o',str(APP/'ThemeMatrix')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(OUT/'compile.log').write_text(r.stdout); print(r.stdout,flush=True)
if r.returncode: raise SystemExit('THEME_MATRIX_COMPILE_FAILED')
info={'CFBundleIdentifier':'com.minismod.theme.matrix','CFBundleExecutable':'ThemeMatrix','CFBundleName':'ThemeMatrix','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(APP/'Info.plist').write_bytes(plistlib.dumps(info)); run(['codesign','--force','--sign','-',str(APP)])
devices=json.loads(run(['xcrun','simctl','list','devices','available','-j']))['devices']
choices=[d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
d=next((d for d in choices if d['state']=='Booted'),choices[0]); uid=d['udid']
if d['state']!='Booted': run(['xcrun','simctl','boot',uid])
run(['xcrun','simctl','bootstatus',uid,'-b']); run(['xcrun','simctl','install',uid,str(APP)])
container=pathlib.Path(run(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data']).strip())
if (container/'tmp/theme-matrix').exists(): shutil.rmtree(container/'tmp/theme-matrix')
for stale in [*OUT.glob('*.png'),OUT/'result.log']:
    if stale.exists(): stale.unlink()
try: output=run(['xcrun','simctl','launch','--console-pty',uid,info['CFBundleIdentifier']],timeout=180)
except subprocess.CalledProcessError as e: output=e.output
(OUT/'launch.log').write_text(output); print(output,flush=True)
for p in (container/'tmp/theme-matrix').iterdir(): shutil.copy2(p,OUT/p.name)
marker=(OUT/'result.log').read_text(); print(marker,flush=True)
assert 'THEME_MATRIX_PASS checks=325 png=54' in marker,marker
assert len(list(OUT.glob('*.png')))==54
print('THEME_MATRIX_ARTIFACT_OK png=54',flush=True)
