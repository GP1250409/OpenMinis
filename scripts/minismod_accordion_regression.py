#!/usr/bin/env python3
"""Compile the actual accordion UIKit code and run a real simulator app."""
import json,plistlib,subprocess,pathlib,sys
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'build/accordion-regression';out.mkdir(parents=True,exist_ok=True)
app=out/'AccordionRegression.app';app.mkdir(exist_ok=True)
ios=root/'src/ios/Views/ContentView/Sidebar'

def sh(*a,**k):
    print('+',' '.join(map(str,a)),flush=True); return subprocess.run(list(map(str,a)),**k)

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
paint+=surfaces[surfaces.index('struct FolderSurface:'):surfaces.index('/// Rename + dissolve alerts')]
paint_source=out/'ProductionFolderSurfaces.swift';paint_source.write_text(paint)
# Compile the complete production SessionRow, not a replacement Text fixture.
# Only application services/models are doubled in RowClippingTests.swift.
row_source=out/'InstrumentedSessionRow.swift'
row_text=(ios/'SessionRow.swift').read_text()
# Diagnostic-only GeometryReader backgrounds do not propose layout sizes.
row_text=row_text.replace('.frame(width: 44, height: 44)', '.frame(width: 44, height: 44).background(RowDiagnosticProbe(name: "icon-\\(session.id)"))', 1)
row_text=row_text.replace('.lineLimit(1)', '.lineLimit(1).background(RowDiagnosticProbe(name: "title-\\(session.id)"))', 1)
row_text=row_text.replace('.contentShape(Rectangle())', '.contentShape(Rectangle()).background(RowDiagnosticProbe(name: "body-\\(session.id)"))', 1)
row_source.write_text(row_text)
wrappers=(ios/'SessionListRows.swift').read_text()
wrapped_source=out/'ProductionStackRow.swift'
wrapped_source.write_text('import SwiftUI\n'+wrappers[wrappers.index('struct SessionStackRow:'):wrappers.index('/// iPad / Mac')]+wrappers[wrappers.index('struct SessionRowPressStyle:'):])
# Regression: the lifted card may NOT follow the Button's press state. On iOS 16
# that state outlives a cancelled menu, which is exactly the residue the user
# still saw (a lone rounded card with its shadow gone). The welded segment is
# the resting paint; the lone card exists only inside the platter-snapshot
# window (FolderMemberLiftBackground → FolderPreviewLift.swift).
press=wrappers[wrappers.index('struct SessionRowPressStyle:'):]
branch=press[press.index('if inFolder {'):press.index('} else {')]
assert 'FolderMemberLiftBackground(isLast: isLast, pressed: configuration.isPressed)' in branch,\
 'member row must paint through the lift background (press state only ARMS it)'
assert 'FolderLiftedCard' not in branch and 'ZStack' not in branch,\
 'the folder row paint must not follow the press state directly: it outlives a cancelled menu'
assert 'lifted: configuration.isPressed' not in branch and 'lifted: !configuration.isPressed' not in branch,\
 'the pressed flag may only arm the lift; the platter probe decides when it ends'
assert 'FolderLiftedCard' not in wrappers and 'FolderLiftPreviewShape' not in wrappers,\
 'the always-painted lifted card / card-only mask must be gone'
assert 'FolderPlatterShape()' in wrappers[wrappers.index('struct SessionRowContextMenu:'):],\
 'member preview must be masked by the shared platter shape'
header=(ios.parent/'ContentView+SectionHeaders.swift').read_text()
# The platter must be the CARD plus its 4pt band on all four sides. The mask is
# applied to the padded row (the production carrier), so the band exists on
# every side of the card; the expanded header's bottom band comes from the CARD
# being painted 4pt short while held, never from cropping the snapshot (the
# flat, cut-off bottom edge the user rejected).
_hf=header[header.index('func folderSectionHeader('):header.index('func handleSessionCreatedForPendingFolder(')]
assert _hf.count('.contextMenu {')==1,'header must carry exactly one context menu'
assert '.contentShape(.contextMenuPreview, FolderPlatterShape())' in _hf,\
 'header preview must be masked by the shared platter shape'
assert _hf.index('.contentShape(.contextMenuPreview') > _hf.index('.padding(.horizontal, 6)'),\
 'header preview must be attached to the padded row so the mask rect is the row'
assert _hf.index('.contextMenu {') > _hf.index('.contentShape(.contextMenuPreview'),\
 'contextMenu must stay attached to the masked view'
assert 'FolderCardPreviewShape' not in header,'the expanded/collapsed mask variant must be gone'
assert 'FolderCardPreviewShape' not in surfaces and 'FolderCardPreviewShape' not in wrappers
lift=(ios/'FolderPreviewLift.swift').read_text()
assert 'row.insetBy(dx: sideInset - gap, dy: verticalInset - gap)' in lift,\
 'platter mask = card expanded by the 4pt band on every side'
assert 'cornerRadius + gap' in lift,'platter radius must be concentric with the card radius'
assert 'private var bottomInset: CGFloat { (lifted && isExpanded) ? FolderCardLift.verticalInset : 0 }' in lift,\
 'the expanded header card must be painted 4pt short while held'
assert 'onChange(of: pressed)' in lift,'a stuck press state must not be able to re-arm the lift'
assert 'class PassiveTouchRecognizer' in lift and 'static func platterVisible' in lift,\
 'the lift must be driven by an observable touch/menu lifecycle'
member_bg=surfaces[surfaces.index('struct FolderMemberRowBackground: View'):]
member_bg=member_bg[:member_bg.index('\n}\n')]
assert 'lifted ? .lone' in member_bg and '.padding(.top, lifted ? 4 : 0)' in member_bg,\
 'held member row must inset the card 4pt from the top and bottom'
header=header[header.index('        HStack(spacing: 8) {', header.index('    func folderSectionHeader(')):]
header=header[:header.index('            // Mini-bar trigger:')]
header=header.replace('.textCase(nil)', '.textCase(nil).background(RowDiagnosticProbe(name: "folder-body"))', 1)
# The preview carrier and paint are production types; only the menu ITEMS are
# stubbed here (they are irrelevant to the platter's geometry), so the fixture
# can present a REAL context menu without the app's folder services.
header_source=out/'ProductionFolderHeaderFixture.swift'
header_source.write_text('import SwiftUI\nimport UIKit\n'+
    'struct ProductionFolderHeaderFixture: View {\n'
    ' let group: SidebarGroup\n let searchResultsActive = false\n let searchQuery = ""\n'
    ' var body: some View {\n'+header+
    ' .modifier(FolderCardBackground(isDropTarget: false, isExpanded: !group.isCollapsed && !group.ids.isEmpty))\n'
    ' .padding(.horizontal, 6).padding(.top, 4)\n'
    ' .padding(.bottom, (group.isCollapsed || group.ids.isEmpty) ? 4 : 0)\n'
    ' .contentShape(.contextMenuPreview, FolderPlatterShape())\n'
    ' .contextMenu { Button("Pin") {}; Button("Rename Group") {}; Button("Dissolve Group") {} }\n'
    ' }\n}\n')
# The toolbar must have ONE stable owner, outside all three renderer branches.
session_source=(ios.parent/'ContentView+SessionList.swift').read_text()
assert session_source.count('SidebarNavigationChrome { sidebarToolbarContent }') == 1
assert '.toolbar { sidebarToolbarContent }' not in session_source
assert '.toolbar { sidebarToolbarContent }' not in (ios.parent/'ContentView+NativeAccordion.swift').read_text()
sh('xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-O','-parse-as-library','-sdk',sdk,
 '-target',arch+'-apple-ios16.0-simulator',str(ios/'AccordionCollectionLayout.swift'),str(ios/'NativeAccordionList.swift'),
 str(ios/'FloatingSidebarSurface.swift'), str(ios/'SidebarNavigationChrome.swift'),
 str(ios/'FolderPreviewLift.swift'),
 str(paint_source), str(row_source), str(header_source), str(wrapped_source),
 str(root/'scripts/accordion-tests/WrappedRowGeometryTests.swift'),
 str(root/'scripts/accordion-tests/RowClippingTests.swift'), str(root/'scripts/accordion-tests/SidebarChromeTests.swift'),
 str(root/'scripts/accordion-tests/FolderAppearanceTests.swift'), str(root/'scripts/accordion-tests/FloatingBarTests.swift'),
 str(root/'scripts/accordion-tests/AccordionTestApp.swift'),'-o',str(app/'AccordionRegression'),check=True)
info={'CFBundleIdentifier':'com.gonepaul.accordion.regression','CFBundleExecutable':'AccordionRegression',
 'CFBundleName':'AccordionRegression','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1',
 'LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
sh('codesign','--force','--sign','-',str(app),check=True)
sh('xcrun','simctl','install',uid,str(app),check=True)
try:
 r=subprocess.run(['xcrun','simctl','launch','--console',uid,info['CFBundleIdentifier']],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=240)
 stdout=r.stdout or ''
 print(stdout)
 print('LAUNCH_RETURN_CODE',r.returncode,flush=True)
except subprocess.TimeoutExpired as te:
 stdout=(te.stdout.decode('utf-8','replace') if isinstance(te.stdout,bytes) else (te.stdout or ''))
 print('LAUNCH_TIMED_OUT_PARTIAL_STDOUT:')
 print(stdout)
(out/'results.log').write_text(stdout)
import shutil
try:
 container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data'],text=True).strip())
 for pattern in ('fab-*.png','folder-*.png','nav-*.png','row-*.png','platter-*.png'):
  for p in (container/'tmp').glob(pattern): shutil.copy2(p,out/p.name)
except Exception as e: print('Screenshot collection unavailable:',type(e).__name__)
if 'ACCORDION_UIKIT_PASS ' not in stdout:
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
assert 'ACCORDION_UIKIT_PASS ' in stdout,'Native accordion regression failed'
