#!/usr/bin/env python3
"""Run the context-menu preview probe on an iOS 16 simulator (installs the runtime if needed)."""
import json, pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
out = root/'build/probe16'; out.mkdir(parents=True, exist_ok=True)
def sh(*a, **k):
    print('+', ' '.join(map(str, a)), flush=True); return subprocess.run(list(map(str, a)), **k)
rts = json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
print('RUNTIMES', [r['identifier'] for r in rts], flush=True)
rt = next((r for r in rts if r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-16')), None)
if rt is None:
    sh('xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '16.4', timeout=2400)
    rts = json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
    print('RUNTIMES', [r['identifier'] for r in rts], flush=True)
    rt = next((r for r in rts if r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-16')), None)
target_os = '16.0'
if rt is None:
    print('NO_IOS16_RUNTIME, falling back to newest', flush=True)
    rt = rts[-1]; target_os = '16.0'
types = json.loads(subprocess.check_output(['xcrun','simctl','list','devicetypes','-j']))['devicetypes']
dt = next((t['identifier'] for t in types if t['name'] == 'iPhone 13 Pro'), None) or next(t['identifier'] for t in types if 'iPhone' in t['name'])
uid = subprocess.check_output(['xcrun','simctl','create','probe16', dt, rt['identifier']], text=True).strip()
sh('xcrun','simctl','boot',uid); sh('xcrun','simctl','bootstatus',uid,'-b')
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'], text=True).strip()
arch = subprocess.check_output(['uname','-m'], text=True).strip()
app = out/'Probe16.app'; app.mkdir(exist_ok=True)
sh('xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-O','-parse-as-library','-sdk',sdk,'-target',f'{arch}-apple-ios{target_os}-simulator',
   root/'scripts/probe16/ProbeApp.swift','-o',app/'Probe16', check=True)
info = {'CFBundleIdentifier':'com.gonepaul.probe16','CFBundleExecutable':'Probe16','CFBundleName':'Probe16','CFBundlePackageType':'APPL',
        'CFBundleVersion':'1','CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'MinimumOSVersion':target_os,
        'UIDeviceFamily':[1],'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
sh('codesign','--force','--sign','-',app, check=True)
sh('xcrun','simctl','install',uid,app, check=True)
r = subprocess.run(['xcrun','simctl','launch','--console',uid,info['CFBundleIdentifier']], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
print(r.stdout)
c = pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data'], text=True).strip())
for p in (c/'tmp').glob('p16-*.png'): shutil.copy2(p, out/p.name)
print('COLLECTED', len(list(out.glob('p16-*.png'))))
