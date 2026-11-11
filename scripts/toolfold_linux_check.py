#!/usr/bin/env python3
"""Run the ToolFoldPlanner regression cases on Linux.

The standalone test (src/ios/MinisTests/Standalone/ToolFoldPlannerTests.swift)
compiles the planner through /usr/bin/xcrun, so it only runs on macOS. This
script does the same on Swift/Linux: it builds a harness out of the real
`enum ToolFoldPlanner { ... }` and the test's own raw-string harness (the block
notation vectors), runs it with swiftc, then compares every printed value with
the expectations the Swift test asserts via has("name=value").

usage: python3 scripts/toolfold_linux_check.py [--swiftc swiftc]
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
ios = root / 'src' / 'ios'
test_path = ios / 'MinisTests' / 'Standalone' / 'ToolFoldPlannerTests.swift'
planner_path = ios / 'Agent' / 'MessageList' / 'ToolFoldPlanner.swift'
out = root / 'build' / 'toolfold-linux'
out.mkdir(parents=True, exist_ok=True)

planner_src = planner_path.read_text()
start = planner_src.index('enum ToolFoldPlanner {')
end = planner_src.index('// END ToolFoldPlanner', start)
planner = planner_src[start:end]

test = test_path.read_text()
h_start = test.index('#"""')
h_end = test.index('"""#', h_start)
harness = test[h_start + 4:h_end]

(out / 'main.swift').write_text('import Foundation\n' + planner + harness)
swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(out / 't'), str(out / 'main.swift')],
                       capture_output=True, text=True)
if build.returncode != 0:
    print('COMPILE FAILED')
    print(build.stderr[:4000])
    sys.exit(1)
print('COMPILE OK')

run = subprocess.run([str(out / 't')], capture_output=True, text=True)
if run.returncode != 0:
    print('RUN FAILED')
    print(run.stdout[-2000:], run.stderr[-2000:])
    sys.exit(1)
lines = set(run.stdout.splitlines())

checks = re.findall(r'check\(\s*"((?:[^"\\]|\\.)*)"', test)
# Every value the test asserts through has("..."): both the pairs inside a
# check's description argument and the has(...) literals beside it.
asserted = []
for c in checks:
    asserted += re.findall(r'([A-Za-z][A-Za-z0-9]*)=([^"\s]+)', c)
for lit in re.findall(r'has\("([^"]*)"\)', test):
    asserted += re.findall(r'([A-Za-z][A-Za-z0-9]*)=([^"\s]+)', lit)
missing = []
for name, value in asserted:
    if not any(l == f'{name}={value}' for l in lines):
        missing.append(f'{name}={value}')

for v in missing:
    print(f'MISSING: {v}')
print(f'CHECKED {len(checks)} check() descriptions, {len(asserted)} asserted values, {len(missing)} missing')
print('TOOLFOLD_LINUX_OK' if not missing else 'TOOLFOLD_LINUX_FAIL')
sys.exit(0 if not missing else 1)
