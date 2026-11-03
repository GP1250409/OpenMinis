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
# Regression: tapping a deep-thinking row opens it DOWNWARD. The tap must hand
# a ToggleRequest to the list's top-anchored path (like the user_ask card);
# flipping isThinkingExpanded in the view re-measured through the plain path,
# whose visible-cell compensation grew the block upward.
blk=(root/'src/ios/Views/Chat/AssistantBlockView.swift').read_text()
tap=blk[blk.index('struct ThinkingBlockView:'):]
tap=tap[tap.index('.onTapGesture {'):tap.index('// Content')]
assert 'ToggleAnchorMath.anchorTopKey: true' in tap and 'ToggleAnchorMath.toggleRequestKey: request' in tap,'thinking tap must take the anchored path'
assert 'isExpanded.wrappedValue.toggle()' not in tap,'thinking tap must not flip the state itself'
chg=blk[blk.index('.onChange(of: block.isThinkingExpanded)'):]
chg=chg[:chg.index('NotificationCenter.default.post')]
assert 'if block.thinkingToggleAnchored {' in chg,'anchored tap must skip the second, unanchored re-measure'
v3=(root/'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift').read_text()
assert 'self.remeasureKeepingTop(item: item, index: i, blockId: blockId, request: request)' in v3
pin=blk[blk.index('struct ThinkingBlockView:'):]
pin=pin[pin.index('.stroke(ChatColors.thinkingBorder, lineWidth: 0.5)'):pin.index('.task(id: block.id)')]
assert '.frame(maxHeight: .infinity, alignment: .top)' in pin,'thinking block must be pinned to the top of its cell during the height animation'
# Regression: a COLLAPSE keeps the opened body on screen until the cell's
# height animation ends (flipping it first left a 340pt cell holding a 40pt
# header: one all-black frame plus ghosts of the rows below, video 20:55:45),
# and an EXPAND re-measures when the hosting view answers with the old height
# (device crumbs idx=7: toggle h=39->39, verify 39->232 on every tap).
tf=(root/'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift').read_text()
rk=tf[tf.index('func remeasureKeepingTop('):tf.index('func verifyToggledHeight(')]
assert 'let isCollapse: Bool' in rk and 'return b.isThinkingExpanded' in rk,'collapse must be decided before the state flips'
col=rk[rk.index('if isCollapse {'):rk.index('} else {', rk.index('if isCollapse {'))]
assert 'request?.run()' not in col,'a collapse must not flip the state before the height animation'
assert 'setMeasuredHeight(Self.collapsedThinkingHeight' in col,'a collapse animates to the header height'
fin=rk[rk.index('let finish = {'):rk.index('// [T-user-ask-expand-verify] And on the next runloop turn')]
assert fin.index('if isCollapse {') < fin.index('request?.run()') < fin.index('verifyToggledHeight'),'state flips in finish, before the verify'
assert 'while fitted <= oldHeight + 0.5 && retries < 3' in rk,'expand must re-measure a lagging answer'
assert 'if !isCollapse {' in rk[rk.index('// [MOD think-collapse-hold] Not for a collapse'):],'no early verify during a collapse'
assert 'deadline: .now() + 0.5' in tap,'fallback toggle must wait for the collapse animation'
print('THINKING_ANCHOR_SOURCE_OK')
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
