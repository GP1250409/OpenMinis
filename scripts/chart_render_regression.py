#!/usr/bin/env python3
"""Real iOS Charts/SwiftUI bitmap regression; requires macOS + Xcode.
Extracts the entire production chart section byte-for-byte into a simulator app.
PNG + pixel measurements are copied to build/chart-render for the log artifact.
"""
import json
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/chart-render'
app = out / 'ChartRender.app'
view = root / 'src/ios/Views/Chat/AIChatView/MinisUI/MinisUIView.swift'
core = root / 'src/ios/Views/Chat/AIChatView/MinisUI/MinisUICore.swift'
fixture = root / 'scripts/chart-render-tests/ChartRenderTests.swift'

def block(text, marker):
    start = text.index(marker)
    depth = 0
    for i in range(text.index('{', start), len(text)):
        if text[i] == '{': depth += 1
        if text[i] == '}':
            depth -= 1
            if depth == 0: return text[start:i + 1]
    raise ValueError('unbalanced production block')

def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)

def main():
    out.mkdir(parents=True, exist_ok=True)
    text = view.read_text()
    chart = text[text.index('enum MUChartStyle {'):text.index('private struct MUButton: View')]
    assert 'MUChartColumns.layout' in chart and 'MUChartRenderGeometryKey' in chart
    # Drawing tokens precede MUChartStyle (the old slice start). Include the
    # exact production value type, NOT the settings preview between the two:
    # that preview depends on the ordinary MUNodeView/MUContext renderer.
    drawing = block(text, 'struct MUChartDrawing {')
    assert 'static let weightKey' in drawing and 'static let dashKey' in drawing
    assert 'func width(' in drawing and 'func dash(' in drawing
    style = block(text, 'enum MUStyle {')
    generated = out / 'ChartFixture.swift'
    # A single file preserves production private visibility; no function body
    # is replaced and all MUChart/MUMultiChart/Theme code is actually compiled.
    generated.write_text('import SwiftUI\nimport UIKit\nimport Charts\n' + style + '\n' + drawing + '\n' + chart + '\n' + fixture.read_text())
    generated_text = generated.read_text()
    assert generated_text.count('struct MUChartDrawing {') == 1
    assert drawing in generated_text, 'drawing tokens must be byte-for-byte production code'
    assert 'struct MUChartSettingsPreview:' not in generated_text, 'ordinary preview is outside chart-only dependency closure'
    print('CHART_RENDER_DEPENDENCY_PASS tokens=MUChartDrawing exact=1', flush=True)
    print('CHART_RENDER_PRODUCTION_SLICE_OK', len(chart), flush=True)
    if '--source-only' in sys.argv:
        print('CHART_RENDER_SOURCE_OK (no UIKit compilation or pixel validation)')
        return
    app.mkdir(parents=True, exist_ok=True)
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
    choices = [d for group in devices.values() for d in group if 'iPhone' in d['name'] and d.get('isAvailable')]
    device = next((d for d in choices if d['state'] == 'Booted'), choices[0])
    uid = device['udid']
    if device['state'] != 'Booted': run(['xcrun','simctl','boot',uid])
    run(['xcrun','simctl','bootstatus',uid,'-b'])
    sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'], text=True).strip()
    arch = platform.machine()
    cmd = ['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-parse-as-library','-sdk',sdk,
           '-target',arch+'-apple-ios16.0-simulator',str(core),
           str(core.with_name('MinisUIMapCore.swift')),str(core.with_name('MinisUIMapData.swift')),str(core.with_name('MinisUIMapPack.swift')),str(core.with_name('MinisUIMapView.swift')),str(core.parent.parent/'Support/ChatColors.swift'),str(generated),'-o',str(app/'ChartRender')]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out/'compile.log').write_text(result.stdout)
    print(result.stdout, flush=True)
    if result.returncode: raise SystemExit('chart render swiftc failed')
    info = {'CFBundleIdentifier':'com.gonepaul.chart.render','CFBundleExecutable':'ChartRender',
            'CFBundleName':'ChartRender','CFBundlePackageType':'APPL','CFBundleVersion':'1',
            'CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0',
            'UIDeviceFamily':[1],'UILaunchScreen':{}}
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    run(['codesign','--force','--sign','-',str(app)])
    run(['xcrun','simctl','install',uid,str(app)])
    try:
        result = subprocess.run(['xcrun','simctl','launch','--console-pty',uid,info['CFBundleIdentifier']],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
        console = result.stdout
    except subprocess.TimeoutExpired as error:
        console = error.stdout or b''
        if isinstance(console, bytes): console = console.decode(errors='replace')
    (out/'results.log').write_text(console)
    print(console, flush=True)
    container = subprocess.check_output(['xcrun','simctl','get_app_container',uid,info['CFBundleIdentifier'],'data'], text=True).strip()
    documents = pathlib.Path(container)/'Documents'
    if documents.exists(): shutil.copytree(documents, out/'png', dirs_exist_ok=True)
    if 'CHART_RENDER_PASS checks=' not in console: raise SystemExit('real chart bitmap regression did not pass')
    assert len(list((out/'png').glob('*.png'))) >= 720, 'missing chart render PNGs'
    print('CHART_RENDER_ARTIFACT_OK png=720', flush=True)

if __name__ == '__main__': main()
