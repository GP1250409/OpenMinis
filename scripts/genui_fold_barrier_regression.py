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
# [fix 2026-11-17] `inputs(for:)`, `FoldedRun` and `foldedRuns` live in the
# `extension ToolFoldPlanner` that FOLLOWS `// END ToolFoldPlanner`, so a slice
# that stops at that marker does not compile against the production API at all
# (the first version of this script did exactly that and had never been run).
# The whole tail of the file is the planner's own extension — nothing else — so
# the production source is taken verbatim to EOF.
planner = planner_src[start:]
assert '// END ToolFoldPlanner' in planner and 'struct FoldedRun' in planner
assert 'static func inputs(for blocks: [AssistantBlock]) -> [Input]' in planner

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
// The tail of the production file also carries
// `foldHorizon(for message: ChatMessage, …)`. The planner proper never looks
// inside it, so the fixture only needs the two members that call touches —
// the planner text itself stays verbatim.
struct ChatMessage {
    var id = UUID()
    var blocks: [AssistantBlock] = []
}

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
        // One simple interpolation per append: a chained `+` here made the
        // Swift type checker give up ("unable to type-check in reasonable time")
        // on the device-class toolchain, and cost ~12 minutes per attempt.
        let lo = run.group.range.lowerBound
        let hi = run.group.range.upperBound
        let t = run.group.toolCount
        let f = run.group.failedCount
        let c = run.group.cancelledCount
        let th = run.group.thinkingCount
        let lv = run.group.isLive
        shape.append("G[\(lo)...\(hi) t=\(t) f=\(f) c=\(c) th=\(th) live=\(lv)]")
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
        // Explicit element type + qualified cases: `AssistantBlock?` made the
        // optional-member lookup fail to infer (it cost a full compile to learn).
        let steps: [(String, AssistantBlock.Status?)] =
            [("ui.streaming", AssistantBlock.Status.streaming),
             ("ui.running", AssistantBlock.Status.running),
             ("ui.none", AssistantBlock.Status?.none)]
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


# [truth table, 2026-11-17] The four switch combinations are a documented
# product contract, and this table states it cell by cell. It was rewritten
# after the first real execution of this script (it had never been run): three
# expectations contradicted the contract they were supposed to pin —
#   * "end-only + ended=true folds nothing" is wrong: the END switch owns a
#     finished message, so the run folds there (`live` is the switch that is
#     off, not folding altogether);
#   * "live-only + success keeps the row" is wrong: the settled `.card` branch
#     reads `endFolding` only, so that combination expands once the card lands
#     — the documented "folds while replying, expands after the reply";
#   * "a failed show_ui is always a member" is wrong when nothing folds at all
#     (no run exists to be a member of).
# No threshold is weakened: every cell is asserted EXACTLY (run count, tool
# count, membership), and the A/B below additionally requires the pre-patch
# mapping to lose the row this patch keeps.
RUNS_OPEN = {  # show_ui streaming / running / none — the pre-landing frames
    ('live+end', 'false'): 1, ('live+end', 'true'): 1,
    ('live-only', 'false'): 1, ('live-only', 'true'): 0,
    ('end-only', 'false'): 0, ('end-only', 'true'): 1,
    ('off-off', 'false'): 0, ('off-off', 'true'): 0,
}
RUNS_CARD = {  # show_ui settled as .card — reads endFolding only
    ('live+end', 'false'): 1, ('live+end', 'true'): 1,
    ('live-only', 'false'): 0, ('live-only', 'true'): 0,
    ('end-only', 'false'): 1, ('end-only', 'true'): 1,
    ('off-off', 'false'): 0, ('off-off', 'true'): 0,
}
RUNS_PROCESS = {  # show_ui failed / cancelled — settled process, joins the run
    ('live+end', 'false'): 1, ('live+end', 'true'): 1,
    ('live-only', 'false'): 1, ('live-only', 'true'): 0,
    ('end-only', 'false'): 0, ('end-only', 'true'): 1,
    ('off-off', 'false'): 0, ('off-off', 'true'): 0,
}

# 1. unrendered show_ui: the run on screen stays ONE folded row, the card is
#    never a member, and the row is the same row (range + counts).
for status in ('ui.streaming', 'ui.running', 'ui.none'):
    for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
        for ended in ('true', 'false'):
            kv = steps[(f'plain/{combo}/ended={ended}', status)]
            want = RUNS_OPEN[(combo, ended)]
            label = f'{combo} ended={ended} {status}'
            expect(int(kv['runs']) == want, f'{label}: exactly {want} fold row(s)')
            expect(kv['uiMember'] == '0', f'{label}: show_ui is never a member')
            if want == 1:
                expect(ints(kv, 't') == [2] and 'G[0...2 t=2' in kv['shape'],
                       f'{label}: the leading run keeps range 0...2 and toolCount 2 ({kv["shape"]})')
                expect(int(kv['rows']) == 2, f'{label}: 1 fold row + the show_ui capsule')
            else:
                expect(int(kv['rows']) == 4, f'{label}: nothing folds, every block keeps its row')

# 2. the card lands: independent, never swallowed, and the end switch decides.
for terminal in ('ui.success',):
    for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
        for ended in ('true', 'false'):
            kv = steps[(f'plain/{combo}/ended={ended}', terminal)]
            want = RUNS_CARD[(combo, ended)]
            label = f'{combo} ended={ended} success'
            expect(int(kv['runs']) == want, f'{label}: exactly {want} fold row(s) after the card lands')
            expect(kv['uiMember'] == '0', f'{label}: the card is never a member')
            if want == 1:
                expect(ints(kv, 't') == [2], f'{label}: run before the card folds')

# 3. failed / cancelled show_ui is settled process: it joins the run whenever a
#    run exists at all.
for terminal in ('ui.failed', 'ui.cancelled'):
    for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
        for ended in ('true', 'false'):
            kv = steps[(f'plain/{combo}/ended={ended}', terminal)]
            want = RUNS_PROCESS[(combo, ended)]
            label = f'{combo} ended={ended} {terminal}'
            expect(int(kv['runs']) == want, f'{label}: exactly {want} fold row(s)')
            if want == 1:
                expect(kv['uiMember'] == '1' and ints(kv, 't') == [3],
                       f'{label}: the settled call joins the run (3 tools, member)')
            else:
                expect(kv['uiMember'] == '0', f'{label}: no run, so no membership')

# 4. the row the user is looking at before the block appears: same KEY (manual
#    expand/close is keyed by it), same range, and the run closes as a settled
#    row (isLive false) exactly the way the settled card does — that is what
#    keeps the row from re-rendering as a different kind of row.
for combo in ('live+end', 'live-only'):
    before = steps[(f'plain/{combo}/ended=false', 'before')]
    expect(before['live'] == '1', f'{combo} before: the tail run is the live row ({before["live"]})')
    for status in ('ui.streaming', 'ui.running', 'ui.none'):
        kv = steps[(f'plain/{combo}/ended=false', status)]
        expect(kv['key'] == before['key'] and kv['key'] == 'tool-1',
               f'{combo} {status}: row key unchanged ({kv["key"]}) so manual expand/close still applies')
        expect(kv['live'] == '0',
               f'{combo} {status}: the closed run is a settled row (isLive false) like the card')
        expect('G[0...2 t=2' in kv['shape'] and 'G[0...2 t=2' in before['shape'],
               f'{combo} {status}: same range/counts as the row that was on screen ({kv["shape"]})')

# 5. THE A/B: the same binary, the pre-patch mapping only (`.openCard` read as
#    `.barrier`), must lose exactly that row. Without this the suite would pass
#    even if `input(for:)` had never changed.
for combo in ('live+end', 'live-only'):
    for status in ('ui.streaming', 'ui.running', 'ui.none'):
        key = (f'plain/{combo}/ended=false', status)
        n, o = steps[key], old[key]
        expect(int(o['rows']) > int(n['rows']) and 'G[0...2' not in o['shape'] and n['shape'].count('G[0...2') == 1,
               f'AB {combo} {status}: baseline mapping loses the folded row '
               f'(old rows={o["rows"]} runs={o["runs"]} -> new rows={n["rows"]} runs={n["runs"]})')
for combo in ('live+end', 'live-only'):
    key = (f'plain/{combo}/ended=false', 'ui.success')
    n, o = steps[key], old[key]
    expect(int(n['rows']) <= int(o['rows']),
           f'AB {combo} ui.success: the card landing never adds a row (new {n["rows"]} vs old {o["rows"]})')

# 6. Note: a soft end still keeps a row (never a disappearance), and the card
#    stays outside it.
kv = steps[('note/live+end/ended=false', 'ui.streaming')]
expect(int(kv['runs']) == 1 and ' t=2 ' in kv['shape'] and kv['uiMember'] == '0',
       f'note: the run before the open card keeps a row ({kv["shape"]})')

# 7. Trailing thinking folds at the open card, exactly as at a settled card.
tt_open = steps[('trailing-think/live+end/ended=false', 'ui.streaming')]
tt_card = steps[('trailing-think/live+end/ended=false', 'ui.success')]
expect(tt_open['shape'] == tt_card['shape'] and 'G[0...3 t=2' in tt_open['shape'],
       f'trailing thinking: same shape before and after the card lands ({tt_open["shape"]})')

# 8. Ordinary barriers keep the historical contract (discard, never fold).
for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
    for kind in ('info', 'delegate'):
        for ended in ('true', 'false'):
            kv = steps[(f'barrier/{combo}/ended={ended}', kind)]
            expect(kv['uiMember'] == '0' and kv['runs'] == '0',
                   f'{combo} ended={ended} {kind}: plain barrier still discards the run, never folds it')

# 9. user_ask: still a card in every state.
for combo in ('live+end', 'live-only', 'end-only', 'off-off'):
    kv = steps[(f'userAsk/{combo}/ended=false', 'streaming')]
    expect(kv['uiMember'] == '0', f'{combo} user_ask streaming: still a card, never a member')

print(f'\nSTEPS {len(steps)}  FAILURES {len(failures)}')
if failures:
    for f in failures:
        print('  - ' + f)
    sys.exit(1)
print('GENUI_FOLD_BARRIER_PASS')
