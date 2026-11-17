#!/usr/bin/env python3
"""show_ui (genui) streaming fold-barrier regression — real planner, Swift/Linux.

The bug this pins: a message that already shows a FOLDED row
(`thinking + two finished calls`, folded live) appends a `show_ui` block. While
the program streams/runs, `input(for:)` classified it `.barrier`; `plan` closed
the open run at that barrier with only `closeAtSoftEnd()`, which does nothing
when the run has no note. The row therefore vanished (the calls came back as
separate capsules) and re-appeared as soon as the card settled — a fold →
expand → fold flap for as long as the UI program streams.

What is asserted here (only what the planner itself decides):
  * live folding ON: the run on screen stays ONE folded row across
    streaming/running/none of the show_ui block, whatever the terminal status,
    and the show_ui block is never a member of it (the card stays independent);
  * live folding OFF: nothing folds before the reply/end — the pre-live
    behavior, no early fold at the open card;
  * the four switch combinations keep their documented end state;
  * a note still soft-ends the run (a partial fold is not a disappearance);
  * the row KEY is stable across every step, so the user's manual expand/close
    (`expandedToolGroups` / `toolGroupManuallyFolded`, keyed by that key) keeps
    applying.

usage: python3 scripts/genui_fold_barrier_regression.py [--swiftc swiftc] [--dump]
       --dump prints the per-step plan table (the evidence table in the report)
"""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
planner_path = root / 'src/ios/Agent/MessageList/ToolFoldPlanner.swift'
out = root / 'build' / os.environ.get('GENUI_FOLD_OUT', 'genui-fold-barrier')
out.mkdir(parents=True, exist_ok=True)

planner_src = planner_path.read_text()
start = planner_src.index('enum ToolFoldPlanner {')
end = planner_src.index('// END ToolFoldPlanner', start)
planner = planner_src[start:end]

FIXTURE = r'''
import Foundation

// Only model storage is stubbed (same shape as scripts/toolfold-adapter-tests.swift);
// the planner below is the production file, verbatim.
struct AssistantBlock {
    enum Kind { case text, thinking, info, delegateTool, userAskTool, genuiTool, shellTool,
                fileReadTool, fileWriteTool, fileEditTool, browserTool, readImageTool, memoryTool }
    enum Status { case success, failed, cancelled, streaming, running }
    var id = UUID()
    var kind: Kind
    var toolStatus: Status? = nil
    var content = ""
    var thinkingContentBuffer = ""
    var toolUseId: String? = nil
    var toolDuration: TimeInterval? = nil
}

var counter = 0
func think(_ n: Int) -> AssistantBlock { AssistantBlock(kind: .thinking, content: String(repeating: "思", count: n)) }
func ok() -> AssistantBlock {
    counter += 1
    return AssistantBlock(kind: .shellTool, toolStatus: .success, toolUseId: "tool-\(counter)", toolDuration: 2)
}
func genui(_ status: AssistantBlock.Status?) -> AssistantBlock {
    counter += 1
    return AssistantBlock(kind: .genuiTool, toolStatus: status, toolUseId: "ui-\(counter)", toolDuration: 3)
}
func note(_ s: String) -> AssistantBlock { AssistantBlock(kind: .text, content: s) }

/// What the list would draw: one row per group, one row per block outside it.
func rows(_ blocks: [AssistantBlock], _ runs: [ToolFoldPlanner.FoldedRun]) -> (Int, [String]) {
    var covered = Set<Int>()
    var shape: [String] = []
    for run in runs {
        for i in run.group.range { covered.insert(i) }
        shape.append("G[\(run.group.range.lowerBound)...\(run.group.range.upperBound)"
                     + " t=\(run.group.toolCount) f=\(run.group.failedCount)"
                     + " c=\(run.group.cancelledCount) th=\(run.group.thinkingCount)"
                     + " live=\(run.group.isLive)]")
    }
    var visible = 0
    for i in blocks.indices where !covered.contains(i) {
        visible += 1
        shape.append("b\(i)")
    }
    return (runs.count + visible, shape)
}

func statusName(_ s: AssistantBlock.Status?) -> String {
    guard let s = s else { return "none" }
    switch s {
    case .success: return "success"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    case .streaming: return "streaming"
    case .running: return "running"
    }
}

/// The baseline mapping: before [T-fold-open-card], `input(for:)` returned
/// `.barrier` for a show_ui that had not rendered. That single mapping is the
/// whole bug, so the OLD plan can be produced from the same binary with the
/// same `plan` implementation — an honest A/B, not a re-implementation.
func legacyInputs(_ blocks: [AssistantBlock]) -> [ToolFoldPlanner.Input] {
    ToolFoldPlanner.inputs(for: blocks).map { $0 == .openCard ? .barrier : $0 }
}

func line(_ tag: String, _ combo: String, _ step: String, _ blocks: [AssistantBlock],
          _ runs: [ToolFoldPlanner.FoldedRun]) {
    let (count, shape) = rows(blocks, runs)
    let keys: String = runs.map { $0.key }.joined(separator: ",")
    let members: String = runs.map { String($0.memberIds.count) }.joined(separator: ",")
    let tools: String = runs.map { String($0.group.toolCount) }.joined(separator: ",")
    let liveFlags: String = runs.map { $0.group.isLive ? "1" : "0" }.joined(separator: ",")
    let last = blocks[blocks.count - 1].id
    let uiIsMember = runs.contains { $0.memberIds.contains(last) }
    var parts: [String] = []
    parts.append(tag)
    parts.append(combo)
    parts.append(step)
    parts.append("rows=" + String(count))
    parts.append("runs=" + String(runs.count))
    parts.append("t=" + tools)
    parts.append("members=" + members)
    parts.append("live=" + liveFlags)
    parts.append("uiMember=" + (uiIsMember ? "1" : "0"))
    parts.append("key=" + keys)
    parts.append("shape=" + shape.joined(separator: " "))
    print(parts.joined(separator: "|"))
}

// Built piece by piece: one big interpolated chain makes the Swift type checker
// crawl on a device-class toolchain.
func emit(_ combo: String, _ step: String, _ blocks: [AssistantBlock],
          ended: Bool, live: Bool, end: Bool) {
    let new = ToolFoldPlanner.plan(ToolFoldPlanner.inputs(for: blocks), enabled: true, ended: ended,
                                   liveFolding: live, endFolding: end)
    let old = ToolFoldPlanner.plan(legacyInputs(blocks), enabled: true, ended: ended,
                                   liveFolding: live, endFolding: end)
    line("NEW", combo, step, blocks, ToolFoldPlanner.foldedRuns(in: blocks, ended: ended,
                                                                 liveFolding: live, endFolding: end))
    // The runs the old plan would have drawn, with the same helpers.
    var oldRuns: [ToolFoldPlanner.FoldedRun] = []
    for g in old {
        let members = blocks[g.range]
        let firstTool = members.first { $0.toolUseId != nil } ?? members[members.startIndex]
        let anchor = g.visibleGaps.last.map { min($0 + 1, g.range.upperBound) } ?? g.range.lowerBound
        oldRuns.append(.init(key: firstTool.toolUseId ?? firstTool.id.uuidString,
                             firstBlockId: members[members.startIndex].id,
                             anchorBlockId: blocks[anchor].id,
                             visibleIds: g.visibleGaps.map { blocks[$0].id },
                             memberIds: members.map(\.id), group: g,
                             duration: members.compactMap(\.toolDuration).isEmpty ? nil
                                                                                  : members.compactMap(\.toolDuration).reduce(0, +)))
    }
    line("OLD", combo, step, blocks, oldRuns)
}

let combos: [(String, Bool, Bool)] = [
    ("live+end", true, true), ("live-only", true, false),
    ("end-only", false, true), ("off-off", false, false),
]

/// The message: thinking, two finished calls, then the show_ui block whose
/// status walks streaming → running → none → terminal.
func walk(_ name: String, prefix: [AssistantBlock], terminal: [AssistantBlock.Status?]) {
    for (combo, live, end) in combos {
        let steps: [(String, AssistantBlock?)] =
            [("ui.streaming", .streaming), ("ui.running", .running), ("ui.none", nil)]
        for (label, status) in steps {
            for ended in [false, true] {
                var blocks = prefix
                blocks.append(genui(status))
                emit("\(name)/\(combo)/ended=\(ended)", label, blocks, ended: ended, live: live, end: end)
            }
        }
        for status in terminal {
            for ended in [false, true] {
                var blocks = prefix
                blocks.append(genui(status))
                emit("\(name)/\(combo)/ended=\(ended)", "ui." + statusName(status),
                     blocks, ended: ended, live: live, end: end)
            }
        }
        // And the state right before the show_ui block exists (the row the user
        // is looking at when it is appended).
        for ended in [false, true] {
            emit("\(name)/\(combo)/ended=\(ended)", "before", prefix, ended: ended, live: live, end: end)
        }
    }
}

// A. the reported shape: lead thinking + two finished calls, no note.
walk("plain", prefix: [think(907), ok(), ok()], terminal: [.success, .failed, .cancelled])
// B. the same with a one-line remark between the thinking and the calls: the
//    run has a soft end, so the barrier may keep a PARTIAL row (never nothing).
walk("note", prefix: [think(907), note("Now let me check the logs."), ok(), ok()],
     terminal: [.success, .failed, .cancelled])
// C. a trailing thinking between the calls and the show_ui: it folds with the
//    run at the boundary, exactly like it does at a settled card, so the row
//    does not change shape when the card lands.
walk("trailing-think", prefix: [think(907), ok(), ok(), think(120)],
     terminal: [.success, .failed, .cancelled])
// D. info / delegate barriers must keep the historical contract: never folded,
//    never closing a run into a row.
for (combo, live, end) in combos {
    for ended in [false, true] {
        emit("barrier/\(combo)/ended=\(ended)", "info",
             [think(907), ok(), ok(), AssistantBlock(kind: .info, content: "info")],
             ended: ended, live: live, end: end)
        emit("barrier/\(combo)/ended=\(ended)", "delegate",
             [think(907), ok(), ok(), AssistantBlock(kind: .delegateTool, toolStatus: .running)],
             ended: ended, live: live, end: end)
    }
}
// E. user_ask keeps being a card in every state (unchanged).
for (combo, live, end) in combos {
    emit("userAsk/\(combo)/ended=false", "streaming",
         [think(907), ok(), ok(), AssistantBlock(kind: .userAskTool, toolStatus: .streaming)],
         ended: false, live: live, end: end)
}
print("RAN")
'''

(out / 'main.swift').write_text(FIXTURE.replace('func emit(', planner + '\nfunc emit(', 1))
swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(out / 't'), str(out / 'main.swift')],
                       capture_output=True, text=True)
if build.returncode != 0:
    print('COMPILE FAILED')
    print(build.stderr[:4000])
    sys.exit(1)
run = subprocess.run([str(out / 't')], capture_output=True, text=True)
if run.returncode != 0 or 'RAN' not in run.stdout:
    print('RUN FAILED')
    print(run.stdout[-3000:], run.stderr[-3000:])
    sys.exit(1)

steps, old = {}, {}
for line in run.stdout.splitlines():
    parts = line.split('|')
    if len(parts) < 4 or parts[0] not in ('NEW', 'OLD'):
        continue
    tag, combo, step, *rest = parts
    kv = dict(p.split('=', 1) for p in rest)
    (steps if tag == 'NEW' else old)[(combo, step)] = kv

if '--dump' in sys.argv:
    for key in steps:
        combo, step = key
        n, o = steps[key], old[key]
        mark = '  <-- row lost then regained' if int(o['rows']) > int(n['rows']) else ''
        print(f'{combo:46s} {step:13s} old rows={o["rows"]:>2s} runs={o["runs"]} | new rows={n["rows"]:>2s} runs={n["runs"]}{mark}')
        print(f'    old: {o["shape"]}')
        print(f'    new: {n["shape"]}')
    # The flap summary: rows on screen along the live timeline, no note.
    print()
    for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
        seq = [('before', 'before'), ('ui.streaming', 'ui.streaming'), ('ui.running', 'ui.running'),
               ('ui.none', 'ui.none'), ('ui.success', 'ui.success')]
        for tag, table in (('old', old), ('new', steps)):
            rows_seq = [table[(f'plain/{combo}/ended=false', s)]['rows'] for _, s in seq]
            print(f'{combo:10s} ended=false {tag}: rows along before->streaming->running->none->success = '
                  + ' -> '.join(rows_seq))
    sys.exit(0)

failures = []


def expect(cond, msg):
    print(('OK:   ' if cond else 'FAIL: ') + msg)
    if not cond:
        failures.append(msg)


def ints(kv, field):
    return [int(x) for x in kv[field].split(',') if x]


for status in ('ui.streaming', 'ui.running', 'ui.none'):
    for combo, live in (('live+end', True), ('live-only', True), ('end-only', False), ('off-off', False)):
        for ended in ('true', 'false'):
            kv = steps[(f'plain/{combo}/ended={ended}', status)]
            shape = kv['shape']
            if live and ended == 'false':
                # THE regression: the folded row on screen may not come apart
                # while the UI program streams.
                expect(ints(kv, 't') == [2] and 'G[0...2 t=2' in shape,
                       f'{combo} ended=false {status}: leading run stays one folded row')
                expect(kv['uiMember'] == '0', f'{combo} ended=false {status}: show_ui is never a member')
                expect(kv['rows'] == '2', f'{combo} ended=false {status}: 1 fold row + the show_ui capsule')
            elif live and ended == 'true':
                # Same rule for a finished message (end switch owns it).
                if combo == 'live+end':
                    expect(ints(kv, 't') == [2], f'{combo} ended=true {status}: run before the open card folds')
                else:
                    expect(kv['runs'] == '0', f'{combo} ended=true {status}: end switch off -> no row')
            else:
                expect(kv['runs'] == '0',
                       f'{combo} ended={ended} {status}: nothing folds before a reply (pre-live behavior)')

# Terminal statuses: the card is independent, never swallowed.
for terminal, expected_members in (('ui.success', 0), ('ui.failed', 1), ('ui.cancelled', 1)):
    for combo, live, end in (('live+end', True, True), ('live-only', True, False),
                             ('end-only', False, True), ('off-off', False, False)):
        for ended in ('true', 'false'):
            kv = steps[(f'plain/{combo}/ended={ended}', terminal)]
            if terminal == 'ui.success':
                expect(kv['uiMember'] == '0',
                       f'{combo} ended={ended} success: the card is never a member')
                # end on -> the process before the card is one row, live or not.
                if end:
                    expect(ints(kv, 't') == [2], f'{combo} ended={ended} success: run before the card folds (end switch)')
                elif ended == 'false' and live:
                    expect(ints(kv, 't') == [2],
                           f'{combo} ended=false success: the live row survives the card landing')
                else:
                    expect(kv['runs'] == '0', f'{combo} ended={ended} success: no row with the end switch off')
            else:
                # Failed/cancelled show_ui is settled process: it JOINS the run.
                expect(kv['uiMember'] == '1', f'{combo} ended={ended} {terminal}: failed call is process')
                if ended == 'true' and not end:
                    expect(kv['runs'] == '0', f'{combo} ended=true {terminal}: end switch off -> no row')

# The row the user is looking at before the block appears, and the KEY: stable.
for combo in ('live+end', 'live-only'):
    before = steps[(f'plain/{combo}/ended=false', 'before')]
    for status in ('ui.streaming', 'ui.running', 'ui.none', 'ui.success'):
        kv = steps[(f'plain/{combo}/ended=false', status)]
        if status == 'ui.success' and combo == 'live-only':
            continue  # documented end state of that combination: the reply/card expands it
        expect(kv['key'] == before['key'] and kv['key'] != '',
               f'{combo} {status}: row key unchanged ({kv["key"]}) so manual expand/close still applies')
        expect(kv['live'] == before['live'],
               f'{combo} {status}: isLive flag unchanged ({kv["live"]}) - no re-render of the row kind')

# Note: a soft end keeps a partial row (does not disappear), and it never grows
# to cover the remark's own row.
kv = steps[('note/live+end/ended=false', 'ui.streaming')]
expect('G[0...1 t=1' in kv['shape'] or 'G[0...2 t=2' in kv['shape'],
       f'note: the run before the open card keeps a row ({kv["shape"]})')
expect('uiMember=0' in f'uiMember={kv["uiMember"]}', 'note: show_ui stays outside')

# Trailing thinking folds at the open card, exactly as at a settled card.
tt_open = steps[('trailing-think/live+end/ended=false', 'ui.streaming')]
tt_card = steps[('trailing-think/live+end/ended=false', 'ui.success')]
expect(tt_open['shape'] == tt_card['shape'] and 'G[0...3 t=2' in tt_open['shape'],
       f'trailing thinking: same shape before and after the card lands ({tt_open["shape"]})')

# Ordinary barriers keep the historical contract.
for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
    for kind in ('info', 'delegate'):
        for ended in ('true', 'false'):
            kv = steps[(f'barrier/{combo}/ended={ended}', kind)]
            expect(kv['uiMember'] == '0' and kv['runs'] == '0',
                   f'{combo} ended={ended} {kind}: plain barrier still discards the run, never folds it')

# user_ask: still a card in every state.
for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
    kv = steps[(f'userAsk/{combo}/ended=false', 'streaming')]
    expect(kv['uiMember'] == '0', f'{combo} user_ask streaming: still a card, never a member')

print(f'\nSTEPS {len(steps)}  FAILURES {len(failures)}')
if failures:
    for f in failures:
        print('  - ' + f)
    sys.exit(1)
print('GENUI_FOLD_BARRIER_PASS')
