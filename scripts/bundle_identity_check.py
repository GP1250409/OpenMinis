#!/usr/bin/env python3
"""Fail-closed identity gate. No device/container/keychain operations."""
from pathlib import Path
import argparse,collections,json,plistlib,re,struct,zipfile
R=Path(__file__).resolve().parents[1]; I=R/'src/ios'; OLD='com.gonepaul.minismod'; NEW='com.minismod'; GROUP='group.'+NEW
TARGETS={'main':('Minis','', 'Minis.entitlements'),'widget':('AgentWidgetExtension','PlugIns/AgentWidgetExtension.appex/','AgentWidget/AgentWidget.entitlements'),'fp':('MinisFileProvider','PlugIns/MinisFileProvider.appex/','FileProvider/FileProvider.entitlements'),'share':('MinisShare','PlugIns/MinisShare.appex/','ShareExtension/ShareExtension.entitlements')}
IDS={'main':NEW,'widget':NEW+'.AgentWidget','fp':NEW+'.FileProvider','share':NEW+'.ShareExtension'}
def pl(p):return plistlib.loads(p.read_bytes())
def check_info(main,fp):
 assert main['BGTaskSchedulerPermittedIdentifiers']==[NEW+'.liveactivity-refresh',NEW+'.continued.*']
 assert fp['NSExtension']['NSExtensionFileProviderDocumentGroup']==GROUP
 assert [x['UTTypeIdentifier'] for x in main['UTExportedTypeDeclarations']]==[NEW+'.minisbak']
 assert OLD+'.minisbak' in [x['UTTypeIdentifier'] for x in main['UTImportedTypeDeclarations']]
 assert main['CFBundleURLTypes'][0]['CFBundleURLSchemes']==[NEW]
def source():
 allowed=json.loads((R/'docs/bundleid-legacy-allowlist.json').read_text()); expected=collections.Counter((x['path'],x['line']) for x in allowed); actual=collections.Counter()
 for p in I.rglob('*'):
  if p.is_file() and p.suffix in {'.swift','.m','.plist','.entitlements','.pbxproj'}:
   for line in p.read_text().splitlines():
    if OLD in line:actual[(str(p.relative_to(R)),line.strip())]+=1
 assert actual==expected, 'unreviewed legacy source reference'
 bundle_ids=re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);',(I/'Minis.xcodeproj/project.pbxproj').read_text())
 assert collections.Counter(x for x in bundle_ids if x.startswith(NEW))==collections.Counter({v:2 for v in IDS.values()})
 for _,_,ent in TARGETS.values():
  e=pl(I/ent); assert e['com.apple.security.application-groups']==[GROUP]
  assert OLD not in str(e)
 check_info(pl(I/'Info.plist'),pl(I/'FileProvider/Info.plist'))
 for p in ['MinisApp.swift','FileProvider/AppGroupChangeWatcher.swift','Views/Rootfs/FileBrowserView.swift','Views/Settings/MountDetailView.swift','Views/Settings/SharedFoldersSettingsView.swift']:
  assert NEW+'.files' in (I/p).read_text(),p
 for key in ['com.apple.developer.icloud-container-identifiers','com.apple.developer.ubiquity-container-identifiers']:assert pl(I/'Minis.entitlements')[key]==['iCloud.'+NEW]
 print('BUNDLE_ID_SOURCE_PASS targets=4 legacy_entries='+str(sum(actual.values())))
 return allowed
def embedded(b):
 assert struct.unpack_from('<I',b)[0]==0xfeedfacf; n=struct.unpack_from('<I',b,16)[0]; cur=32;sig=None
 for _ in range(n):
  cmd,size=struct.unpack_from('<II',b,cur);assert size>=8
  if cmd==0x1d:
   off,length=struct.unpack_from('<II',b,cur+8);sig=b[off:off+length]
  cur+=size
 assert sig is not None
 magic,length,count=struct.unpack_from('>III',sig);assert magic==0xfade0cc0 and length<=len(sig)
 for i in range(count):
  slot,off=struct.unpack_from('>II',sig,12+i*8)
  if slot==5:
   magic,size=struct.unpack_from('>II',sig,off);assert magic==0xfade7171
   return plistlib.loads(sig[off+8:off+size])
 raise AssertionError('missing embedded entitlements')
def ipa(path,signed,allowed):
 pattern=rb'com\.gonepaul\.minismod[A-Za-z0-9_.-]*'
 allow={m.decode() for x in allowed for m in re.findall(pattern,x['line'].encode())}
 with zipfile.ZipFile(path) as z:
  assert z.testzip() is None
  base='Payload/Minis.app/'
  assert len([n for n in z.namelist() if n.endswith('.appex/Info.plist')])==3
  for key,(exe,tail,ent) in TARGETS.items():
   info=plistlib.loads(z.read(base+tail+'Info.plist')); assert info['CFBundleIdentifier']==IDS[key],key
   assert info['CFBundleExecutable']==exe
   b=z.read(base+tail+exe); hits={m.decode() for m in re.findall(pattern,b)};assert hits<=allow,(key,sorted(hits-allow))
   if signed:
    actual=embedded(b);assert actual==pl(I/ent),key+' entitlements'
   print('BUNDLE_ID_IPA_TARGET_PASS',key,IDS[key],'embedded_checked='+str(signed),'legacy_tokens='+str(len(hits)))
  check_info(plistlib.loads(z.read(base+'Info.plist')),plistlib.loads(z.read(base+'PlugIns/MinisFileProvider.appex/Info.plist')))
 print('BUNDLE_ID_IPA_PASS signed='+str(signed))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--ipa');p.add_argument('--signed',action='store_true');a=p.parse_args();allowed=source()
 if a.ipa:ipa(a.ipa,a.signed,allowed)
