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
# Also compile ALL production adapters, not just the abstract planner enum.
# The fixture supplies model storage only; classification/history/share logic
# remains verbatim shipped Swift. This stage is required before the OK marker.
adapter = root / 'scripts/toolfold-adapter-tests.swift'
(out / 'main.swift').write_text(adapter.read_text())
adapt_build = subprocess.run([swiftc, '-swift-version', '5', str(planner_path),
                              str(out / 'main.swift'), '-o', str(out / 'adapter')],
                             capture_output=True, text=True)
if adapt_build.returncode:
    print('ADAPTER_COMPILE_FAILED', adapt_build.stderr[-6000:])
    sys.exit(1)
adapt_run = subprocess.run([str(out / 'adapter')], capture_output=True, text=True)
print(adapt_run.stdout)
if adapt_run.returncode or 'TOOLFOLD_ADAPTER_PASS' not in adapt_run.stdout:
    print('ADAPTER_RUN_FAILED', adapt_run.stderr[-4000:])
    sys.exit(1)
# Run the standalone source/wiring audit too, with the same real compiler.
wiring_build = subprocess.run([swiftc, str(test_path), '-o', str(out / 'wiring')],
                              capture_output=True, text=True)
if wiring_build.returncode:
    print('WIRING_COMPILE_FAILED', wiring_build.stderr[-6000:]); sys.exit(1)
wiring_run = subprocess.run([str(out / 'wiring')], cwd=test_path.parent,
                            capture_output=True, text=True)
print(wiring_run.stdout)
if wiring_run.returncode:
    print('WIRING_RUN_FAILED', wiring_run.stderr[-4000:]); sys.exit(1)
print('TOOLFOLD_WIRING_OK')

# [T-fold-two-switches] Source gate for the two INDEPENDENT switches and for the
# manual-close state that survives the turn end. The Swift stages above prove
# the four combinations; this stage proves every surface is wired to them, so a
# later edit cannot silently reconnect only one of the two.
coord = (ios / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator')
coord_src = '\n'.join((coord / f).read_text() for f in sorted(__import__('os').listdir(coord)) if f.endswith('.swift'))
appearance = (ios / 'Views/Settings/AppearanceSettingsView.swift').read_text()
registry_src = (ios / 'Shared/Config/ConfigRegistry+Builtins.swift').read_text()
adapter_src = (root / 'scripts/toolfold-adapter-tests.swift').read_text()
import json as _json
catalog = _json.loads((ios / 'Localizable.xcstrings').read_text())['strings']
LIVE_TITLE = 'Fold Tools While Replying'
END_FOOTER = ('Fold Consecutive Tool Calls: once a reply has ended, the tool calls '
              'before it fold into one summary line. Tap the line to see each call.')
LIVE_FOOTER = ('Fold Tools While Replying: also fold the tool calls and thinking of a reply '
               'that is still being written. With this one on and the first one off, a run '
               'folds while the model works and opens again when its reply ends. A line you '
               'open or close by hand stays that way until the chat is reloaded.')
switch_checks = [
    ('planner gates on both switches', 'guard enabled, liveFolding || endFolding else { return [] }' in planner),
    ('planner takes both switches, defaulting to the live behavior',
     'liveFolding: Bool = true, endFolding: Bool = true) -> [Group]' in planner),
    ('planner restores the pre-live unfinished-tool branch',
     'case .tool(.unfinished) where !liveFolding:' in planner),
    ('planner restores the pre-live horizon',
     'guard !liveFolding else { return message.blocks.count }' in planner),
    ('planner restores the pre-live browse hold', 'guard liveFolding else { return inRunningMessage || shownAsRows() }' in planner),
    ('share/export pass both switches', 'endFolding: settings.end' in (ios / 'Views/Chat/ChatExportRenderer.swift').read_text()),
    ('list passes both switches', 'liveFolding: settings.live' in coord_src and 'endFolding: settings.end' in coord_src),
    ('manual close state exists and survives the session reset and key promotion',
     'var toolGroupManuallyFolded: Set<String> = []' in coord_src
     and 'toolGroupManuallyFolded.removeAll()' in coord_src
     and 'aliases.contains(where: { toolGroupManuallyFolded.contains($0) })' in coord_src),
    ('manual close and open are recorded by the tap',
     'toolGroupManuallyFolded.insert(run.key)' in coord_src
     and 'toolGroupManuallyFolded.remove(run.key)' in coord_src),
    ('settings shows two independent toggles with accurate copy',
     '@AppStorage("chat.foldConsecutiveTools") private var foldConsecutiveTools: Bool = false' in appearance
     and '@AppStorage("chat.foldToolsWhileReplying") private var foldToolsWhileReplying: Bool = false' in appearance
     and 'Toggle(AppLocalized("Fold Consecutive Tool Calls"), isOn: $foldConsecutiveTools)' in appearance
     and 'Toggle(AppLocalized("Fold Tools While Replying"), isOn: $foldToolsWhileReplying)' in appearance
     and END_FOOTER in appearance and LIVE_FOOTER in appearance),
    ('both toggles re-plan the open chat', appearance.count('.messageListNeedsResnapshot, object: nil') >= 2),
    ('config registry registers both, with a notification on write',
     'path: "chat.foldToolsWhileReplying"' in registry_src
     and 'userDefaultsKey: "chat.foldToolsWhileReplying"' in registry_src
     and registry_src.count('notification: .messageListNeedsResnapshot') >= 2),
    ('18-language copy for the three new strings',
     all(len(catalog[k].get('localizations', {})) == 18 for k in (LIVE_TITLE, END_FOOTER, LIVE_FOOTER))),
    ('the adapter suite covers all four combinations and the manual close',
     'liveFolding: true, endFolding: false' in adapter_src
     and 'liveFolding: false, endFolding: true' in adapter_src
     and 'liveFolding: false, endFolding: false' in adapter_src
     and 'liveFolding: true, endFolding: true' in adapter_src
     and 'the settled plan a manual close re-uses' in adapter_src),
]
bad = [label for label, ok in switch_checks if not ok]
for label in bad:
    print(f'SWITCH WIRING MISSING: {label}')
print(f'CHECKED {len(switch_checks)} two-switch wiring checks, {len(bad)} missing')
print('TOOLFOLD_SWITCHES_OK' if not bad else 'TOOLFOLD_SWITCHES_FAIL')
if bad:
    sys.exit(1)
print('TOOLFOLD_LINUX_OK' if not missing else 'TOOLFOLD_LINUX_FAIL')
sys.exit(0 if not missing else 1)
