#!/usr/bin/env python3
"""Compile/run production Foundation maps & MapPack v1 loader, audit native integration.
--source-only never claims Swift tests passed. --render-simulator additionally
builds a standalone iOS fixture using the PRODUCTION MapView (macOS required).
"""
import argparse, json, os, pathlib, re, shutil, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
UI=ROOT/'src/ios/Views/Chat/AIChatView/MinisUI'
PACKS=ROOT/'src/ios/Resources/MapPacks'
p=argparse.ArgumentParser(); p.add_argument('--swiftc',default=shutil.which('swiftc')); p.add_argument('--source-only',action='store_true'); p.add_argument('--render-simulator',action='store_true'); args=p.parse_args()
core=(UI/'MinisUIMapCore.swift').read_text(); pack=(UI/'MinisUIMapPack.swift').read_text(); view=(UI/'MinisUIMapView.swift').read_text()
pack_bytes=sum(f.stat().st_size for f in PACKS.rglob('*') if f.is_file()) if PACKS.is_dir() else 0
checks=[('Foundation plus conditional native font metrics', 'import SwiftUI' not in core and 'import SwiftUI' not in pack and 'import UIKit' not in pack and '#if canImport(UIKit)' in core),
        ('one height formula','MUMapMetrics(comp,width:width).height' in view and 'MUMapMetrics(c, width: Double(w)).height' in (UI/'MinisUICore.swift').read_text()),
        ('native dispatch','case "BlockMap", "GeoMap": MUMapView(comp: comp)' in (UI/'MinisUIView.swift').read_text()),
        ('theme storage only', '@AppStorage(MUChartStyle.key)' in view and not re.search(r'MUChartStyle\.(?!key)',view)),
        ('no client network',not any(x in core+pack+view for x in ['URLSession','https://','MKMapView'])),
        ('bounded data',(UI/'MinisUIMapData.swift').stat().st_size<250000 and 0 < pack_bytes <= 2_097_152),
        ('prompt descriptions',all('("'+s+'",' in (UI/'AIChatViewModel+GenUI.swift').read_text() for s in ['BlockMap','GeoMap']))]
for name,ok in checks:
    print(('SOURCE_OK ' if ok else 'SOURCE_FAIL ')+name,flush=True)
if not all(ok for _,ok in checks): sys.exit(1)
subprocess.run([sys.executable,str(ROOT/'scripts/generate_map_packs.py'),'--verify-only','--out',str(PACKS)],check=True)
print('MAP_SOURCE_PASS checks='+str(len(checks)),flush=True)
if args.source_only:
    print('NOTE: Swift compile/run and simulator rendering NOT run.'); sys.exit(0)
if not args.swiftc: raise SystemExit('MAP_NO_SWIFTC')
out=ROOT/'build/map-regression'; out.mkdir(parents=True,exist_ok=True)
binary=out/'MapTests'
sources=[UI/n for n in ['MinisUICore.swift','MinisUIMapCore.swift','MinisUIMapData.swift','MinisUIMapPack.swift']]
r=subprocess.run([args.swiftc,'-swift-version','5',*map(str,sources),str(ROOT/'scripts/map-tests/main.swift'),'-o',str(binary)],capture_output=True,text=True)
(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode: print(r.stdout+r.stderr); raise SystemExit('MAP_COMPILE_FAILED')
env=dict(os.environ); env['MINIS_MAP_PACKS_DIR']=str(PACKS)
r=subprocess.run([str(binary)],capture_output=True,text=True,env=env)
print(r.stdout,flush=True)
(out/'run.log').write_text(r.stdout+r.stderr)
match=re.search(r'MAP_REGRESSION_PASS checks=(\d+)',r.stdout)
if r.returncode or not match or int(match[1])<650: raise SystemExit('MAP_RUN_FAILED')
if args.render_simulator:
    subprocess.run([sys.executable,str(ROOT/'scripts/map_render_regression.py')],check=True)
