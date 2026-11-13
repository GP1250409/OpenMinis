#!/usr/bin/env python3
"""macOS-only: compile/run the native map fixture, copy PNGs into CI artifacts."""
import json, os, pathlib, plistlib, re, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
UI=ROOT/'src/ios/Views/Chat/AIChatView/MinisUI'
OUT=ROOT/'build/map-render'; OUT.mkdir(parents=True,exist_ok=True)
APP=OUT/'MapRender.app'; APP.mkdir(exist_ok=True)
def run(cmd,**kwargs):
    return subprocess.run(cmd,check=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kwargs).stdout
if sys.platform!='darwin': raise SystemExit('MAP_RENDER_REQUIRES_MACOS (not run)')
fixture=ROOT/'scripts/map-tests/MapRenderFixture.swift'
production_key=re.search(r'enum MUChartStyle\s*\{\s*static let key = "([^"]+)"',(UI/'MinisUIView.swift').read_text()).group(1)
assert 'static let key = "'+production_key+'"' in fixture.read_text(), 'fixture theme key drift'
sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']).strip()
arch=run(['uname','-m']).strip()
sources=[UI/n for n in ['MinisUICore.swift','MinisUIMapCore.swift','MinisUIMapData.swift','MinisUIMapView.swift']]+[UI.parent/'Support/ChatColors.swift',fixture]
cmd=['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target',f'{arch}-apple-ios16.0-simulator','-parse-as-library',*map(str,sources),'-o',str(APP/'MapRender')]
(OUT/'compile-command.txt').write_text(' '.join(cmd))
r=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(OUT/'compile.log').write_text(r.stdout)
if r.returncode: print(r.stdout); raise SystemExit('MAP_RENDER_COMPILE_FAILED')
info={'CFBundleIdentifier':'com.gonepaul.map.render','CFBundleExecutable':'MapRender','CFBundleName':'MapRender','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(APP/'Info.plist').write_bytes(plistlib.dumps(info))
run(['codesign','--force','--sign','-',str(APP)])
devices=json.loads(run(['xcrun','simctl','list','devices','available','-j']))['devices']
choices=[d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
assert choices,'No available iPhone simulator'
d=next((d for d in choices if d['state']=='Booted'),choices[0]); uid=d['udid']
if d['state']!='Booted': run(['xcrun','simctl','boot',uid])
run(['xcrun','simctl','bootstatus',uid,'-b'])
run(['xcrun','simctl','install',uid,str(APP)])
try:
    output=run(['xcrun','simctl','launch','--console-pty',uid,info['CFBundleIdentifier']],timeout=900)
    (OUT/'launch.log').write_text(output); print(output)
except subprocess.TimeoutExpired as exc:
    (OUT/'launch.log').write_text(str(exc.stdout)); print('MAP_RENDER_LAUNCH_TIMEOUT; collecting journal and partial PNGs')
container=pathlib.Path(run(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data']).strip())
rendered=container/'tmp/map-render'
assert rendered.is_dir(),'Fixture did not produce native renders'
for p in rendered.iterdir(): shutil.copy2(p,OUT/p.name)
print('MAP_RENDER_JOURNAL', (OUT/'progress.log').read_text() if (OUT/'progress.log').exists() else 'APP_NOT_STARTED')
marker=(OUT/'result.log').read_text(); assert re.search(r'MAP_RENDER_PASS checks=(\d+) png=(\d+)',marker)
assert int(re.search(r'checks=(\d+)',marker)[1]) >= 1728
assert 'MAP_DYNAMIC_PASS' in marker
assert len(list(OUT.glob('*.png'))) >= 192
print(marker)
