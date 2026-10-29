#!/usr/bin/env python3
"""Compile the actual accordion UIKit code and run a real simulator app."""
import json,plistlib,subprocess,pathlib,sys
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'build/accordion-regression';out.mkdir(parents=True,exist_ok=True)
app=out/'AccordionRegression.app';app.mkdir(exist_ok=True)
ios=root/'src/ios/Views/ContentView/Sidebar'
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
choices=[d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
assert choices,'No iPhone simulator'
d=next((d for d in choices if d['state']=='Booted'),choices[0]);uid=d['udid']
if d['state']!='Booted':subprocess.run(['xcrun','simctl','boot',uid],check=True)
subprocess.run(['xcrun','simctl','bootstatus',uid,'-b'],check=True)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
arch=subprocess.check_output(['uname','-m'],text=True).strip()
# Compile the production paint declarations verbatim, excluding unrelated
# legacy scroll probes, search glass and their application-only dependencies.
surfaces=(ios/'SidebarSurfaces.swift').read_text()
paint='import SwiftUI\nimport UIKit\n'+surfaces[surfaces.index('private struct FolderSegmentBorder:'):surfaces.index('/// Background for the expanded FAB search bar.')]
paint+=surfaces[surfaces.index('private struct FolderSurface:'):surfaces.index('/// Rename + dissolve alerts')]
paint_source=out/'ProductionFolderSurfaces.swift';paint_source.write_text(paint)
# The toolbar must have ONE stable owner, outside all three renderer branches.
session_source=(ios.parent/'ContentView+SessionList.swift').read_text()
assert session_source.count('SidebarNavigationChrome { sidebarToolbarContent }') == 1
assert '.toolbar { sidebarToolbarContent }' not in session_source
assert '.toolbar { sidebarToolbarContent }' not in (ios.parent/'ContentView+NativeAccordion.swift').read_text()
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-O','-sdk',sdk,
 '-target',arch+'-apple-ios16.0-simulator',str(ios/'AccordionCollectionLayout.swift'),str(ios/'NativeAccordionList.swift'),
 str(ios/'FloatingSidebarSurface.swift'), str(ios/'SidebarNavigationChrome.swift'),
 str(paint_source), str(root/'scripts/accordion-tests/SidebarChromeTests.swift'),
 str(root/'scripts/accordion-tests/FolderAppearanceTests.swift'), str(root/'scripts/accordion-tests/FloatingBarTests.swift'),
 str(root/'scripts/accordion-tests/AccordionTestApp.swift'),'-o',str(app/'AccordionRegression')],check=True)
info={'CFBundleIdentifier':'com.gonepaul.accordion.regression','CFBundleExecutable':'AccordionRegression',
 'CFBundleName':'AccordionRegression','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1',
 'LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['xcrun','simctl','install',uid,str(app)],check=True)
r=subprocess.run(['xcrun','simctl','launch','--console',uid,info['CFBundleIdentifier']],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=100)
print(r.stdout)
print('LAUNCH_RETURN_CODE',r.returncode,flush=True)
(out/'results.log').write_text(r.stdout)
import shutil
try:
 container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data'],text=True).strip())
 for pattern in ('fab-*.png','folder-*.png'):
  for p in (container/'tmp').glob(pattern): shutil.copy2(p,out/p.name)
except Exception as e: print('Screenshot collection unavailable:',type(e).__name__)
if 'ACCORDION_UIKIT_PASS ' not in r.stdout:
 import shutil
 diagnostic=pathlib.Path.home()/'Library/Logs/DiagnosticReports'
 for p in diagnostic.glob('AccordionRegression*'):
  if p.is_file():
   try: shutil.copy2(p,out/p.name)
   except Exception: pass
 try:
  diagnostic_run=subprocess.run(['xcrun','simctl','spawn',uid,'log','show','--style','compact','--last','1m','--predicate','process == "AccordionRegression"'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
  (out/'diagnostic.log').write_text(diagnostic_run.stdout)
 except subprocess.TimeoutExpired:
  (out/'diagnostic.log').write_text('log show timed out')
assert 'ACCORDION_UIKIT_PASS ' in r.stdout,'Native accordion regression failed'
