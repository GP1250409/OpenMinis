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
# Regression: a held folder member row's welded segment lives OUTSIDE the
# context-menu source (SessionStackRow background after SessionRowContextMenu);
# inside the source (the ButtonStyle) only the lifted card is drawn. The menu
# hides its source during dismissal, so a segment inside it left a white hole
# around the returning card (photo_43A30060).
stack=wrappers[wrappers.index('struct SessionStackRow:'):wrappers.index('/// MOD: long-press menu of a stack row.')]
assert stack.index('.modifier(SessionRowContextMenu(') < stack.index('FolderMemberRowBackground(isLast: isLastInFolder)'),'member segment must sit outside the menu source'
press=wrappers[wrappers.index('struct SessionRowPressStyle:'):]
branch=press[press.index('if inFolder {'):press.index('} else {')]
assert 'FolderMemberRowBackground' not in branch,'member segment must not be inside the menu source'
assert 'FolderLiftedCard' in branch[branch.index('if configuration.isPressed'):],'lifted card drawn while pressed'
hdr=(ios.parent/'ContentView+SectionHeaders.swift').read_text()
hdr=hdr[hdr.index('    func folderSectionHeader('):hdr.index('    func handleSessionCreatedForPendingFolder(')]
assert 'paintsSurface: group.isCollapsed || group.ids.isEmpty' in hdr,'expanded header must not paint its segment inside the source'
assert hdr.index('.contextMenu {') < hdr.index('FolderWeldStrip('),'expanded header segment must sit outside the menu source'
header=(ios.parent/'ContentView+SectionHeaders.swift').read_text()
header=header[header.index('        HStack(spacing: 8) {', header.index('    func folderSectionHeader(')):]
header=header[:header.index('            // Mini-bar trigger:')]
header=header.replace('.textCase(nil)', '.textCase(nil).background(RowDiagnosticProbe(name: "folder-body"))', 1)
header_all=(ios.parent/'ContentView+SectionHeaders.swift').read_text()
# The preview mask is production code too: compile it verbatim so the header
# preview regression asserts the real path, not a copy.
preview_shape=header_all[header_all.index('struct FolderCardPreviewShape:'):]
header_source=out/'ProductionFolderHeaderFixture.swift'
header_source.write_text('import SwiftUI\nimport UIKit\n'+preview_shape+'\n'+
    'struct ProductionFolderHeaderFixture: View {\n'
    ' let group: SidebarGroup\n let searchResultsActive = false\n let searchQuery = ""\n'
    ' var body: some View {\n'+header+
    ' .modifier(FolderCardBackground(isDropTarget: false, isExpanded: !group.isCollapsed && !group.ids.isEmpty))\n'
    ' .padding(.horizontal, 6).padding(.top, 4)\n }\n}\n')
# The toolbar must have ONE stable owner, outside all three renderer branches.
session_source=(ios.parent/'ContentView+SessionList.swift').read_text()
assert session_source.count('SidebarNavigationChrome { sidebarToolbarContent }') == 1
assert '.toolbar { sidebarToolbarContent }' not in session_source
assert '.toolbar { sidebarToolbarContent }' not in (ios.parent/'ContentView+NativeAccordion.swift').read_text()
# Usage footer row: UsageStampRow compiled verbatim; the usage capsule body and
# its summary formatter are lifted verbatim out of BridgedAssistantFooterV3.
v3=root/'src/ios/Agent/MessageList/CollectionViewMessageListV3/Cells'
footer=(v3/'BridgedAssistantFooterV3.swift').read_text()
assert 'UsageStampRow(' in footer and 'CompletionStampParts(' in footer,'footer must use UsageStampRow'
assert 'completedAtText' not in footer,'old single-line stamp formatter must be gone'
cap=footer[footer.index('    @ViewBuilder\n    private func usageCapsule('):footer.rindex('}')]
usage_source=out/'ProductionUsageCapsule.swift'
usage_source.write_text('import SwiftUI\nstruct ProductionUsageCapsule: View {\n let usage: TokenUsage\n var body: some View { usageCapsule(usage) }\n'+cap+'}\n')
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-O','-sdk',sdk,
 '-target',arch+'-apple-ios16.0-simulator',str(ios/'AccordionCollectionLayout.swift'),str(ios/'NativeAccordionList.swift'),
 str(ios/'FloatingSidebarSurface.swift'), str(ios/'SidebarNavigationChrome.swift'),
 str(paint_source), str(row_source), str(header_source), str(wrapped_source),
 str(root/'scripts/accordion-tests/WrappedRowGeometryTests.swift'),
 str(root/'scripts/accordion-tests/RowClippingTests.swift'), str(root/'scripts/accordion-tests/SidebarChromeTests.swift'),
 str(root/'scripts/accordion-tests/FolderAppearanceTests.swift'), str(root/'scripts/accordion-tests/FloatingBarTests.swift'),
 str(v3/'UsageStampRow.swift'), str(usage_source), str(root/'scripts/accordion-tests/UsageStampTests.swift'),
 str(root/'scripts/accordion-tests/AccordionTestApp.swift'),'-o',str(app/'AccordionRegression')],check=True)
info={'CFBundleIdentifier':'com.gonepaul.accordion.regression','CFBundleExecutable':'AccordionRegression',
 'CFBundleName':'AccordionRegression','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1',
 'LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['xcrun','simctl','install',uid,str(app)],check=True)
r=subprocess.run(['xcrun','simctl','launch','--console',uid,info['CFBundleIdentifier']],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=240)
print(r.stdout)
print('LAUNCH_RETURN_CODE',r.returncode,flush=True)
(out/'results.log').write_text(r.stdout)
# Regression: a thinking block's memoized height must not cross between its
# collapsed and expanded state. The content key carries the expanded state for
# thinking blocks too (user_ask cards already had it), otherwise the height
# measured for one state is seeded back onto the other: a tap that does not open
# and an empty gap under a collapsed header.
hk=(root/'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+HeightEstimation.swift').read_text()
ck=hk[hk.index('static func contentKey('):hk.index('func stableHeightKey(')]
ab=ck[ck.index('case .assistantBlock(let mid, let bid):'):ck.index('case .toolGroup')]
assert 'block?.kind == .thinking' in ab and 'block?.kind == .userAskTool' in ab,'content key must cover thinking and user_ask blocks'
assert 'isThinkingExpanded == true) ? ":x"' in ab,'content key must carry the expanded state'
assert 'return "b:\\(mid.uuidString):\\(bid.uuidString):\\(n)\\(x)"' in ab,'key shape unchanged apart from the state suffix'
print('THINKING_KEY_SOURCE_OK')
import shutil
try:
 container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data'],text=True).strip())
 for pattern in ('stamp-*.png','fab-*.png','folder-*.png','nav-*.png','row-*.png'):
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
