#!/usr/bin/env python3
"""Live-fold "one-frame thinking card" regression — source audit + real-code logic run.

Covers the 17.0s frame of setting-flicker-review-20261117 §5.1: a folded
"Ran 2 tools · 9s" row on screen, a new assistant round starts, and a blank
`.thinking` block is appended BEFORE its first text lands — for one snapshot the
planner reads it as empty text (never a fold member) and the live-tail exemption
draws it as a standalone blue "Deep Thinking" card, which the next flush folds
into the run above and deletes. The footer's typing indicator was not cleared by
a thinking delta either, so the placeholder appeared twice.

[1] SOURCE AUDIT (runs anywhere, incl. iSH)
    * the SSE stream creates the thinking block WITH its first text, flushes it,
      and clears `isAwaitingModelResponse` in the SAME `MainActor.run`
      transaction — and never appends a blank thinking block;
    * a whitespace-only opener creates no block at all;
    * the list asks `LivePlaceholderPolicy.blankThinkingKeepsRow(...)` for the
      blank tail, with the fold row it already emitted above it;
    * no delay / hidden-animation cover-up was added.

[2] LOGIC RUN (swiftc on Linux, same style as scripts/toolfold_linux_check.py)
    Compiles, verbatim:
      * `enum ToolFoldPlanner { ... }` out of src/ios/Agent/MessageList/,
      * `enum LivePlaceholderPolicy { ... }` out of the snapshot coordinator,
      * the production `.thinkingDelta` case body out of
        AIChatViewModel+SSEStream.swift,
    and drives them through the real delta timeline: whitespace opener →
    first visible delta → more deltas. At EVERY middle snapshot it asserts the
    row plan the list would build, with the real planner and the real policy:

      - no independent blank-thinking row, at any step, ever;
      - the fold row above neither disappears nor re-folds (no "unfold→refold");
      - first delta is one transaction: the block is born with its text,
        flushed, and `isAwaitingModelResponse` already false;
      - placeholder ownership: at most one "working" placeholder per frame;
      - manual expansion survives the tail joining the run;
      - an interactive card keeps its own row;
      - the no-tool opening placeholder is still drawn (semantics preserved).

usage: python3 scripts/toolfold_live_thinking_flash_regression.py [--source-only]
       [--swiftc swiftc]
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sse_path = root / 'src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift'
planner_path = root / 'src/ios/Agent/MessageList/ToolFoldPlanner.swift'
snap_path = root / ('src/ios/Agent/MessageList/CollectionViewMessageListV3/'
                    'Coordinator/MessageListV3Coordinator+Snapshot.swift')
models_path = root / 'src/ios/Agent/Chat/ChatModels.swift'
out = root / 'build/toolfold-live-thinking-flash'
out.mkdir(parents=True, exist_ok=True)

failures = []


def note(msg):
    print(msg, flush=True)


def need(cond, msg):
    if cond:
        note('SOURCE_CHECK_OK: ' + msg)
    else:
        failures.append(msg)
        note('SOURCE_CHECK_FAIL: ' + msg)


# --------------------------------------------------------------------- audit ---
def source_audit():
    sse = sse_path.read_text()
    snap = snap_path.read_text()
    models = models_path.read_text()
    planner = planner_path.read_text()

    # 1. No blank thinking block is ever appended.
    need('AssistantBlock(kind: .thinking, content: "")\n                        )' not in sse,
         'SSE stream no longer appends a blank thinking block on its own')
    need(re.search(r'let block = AssistantBlock\(kind: \.thinking, content: ""\)\n'
                   r'\s*block\.appendThinkingDelta\(lead\)', sse) is not None,
         'the thinking block is created WITH its first text in the transaction')
    need(re.search(r'block\.appendThinkingDelta\(lead\)\n(?:\s*//[^\n]*\n)*\s*block\.flushThinkingBuffer\(\)\n'
                   r'(?:\s*//[^\n]*\n)*\s*messages\[msgIdx\]\.blocks\.append\(block\)', sse) is not None,
         'first text is flushed BEFORE the block joins the array (same transaction)')
    need(re.search(r'messages\[msgIdx\]\.blocks\.append\(block\)\n(?:\s*//[^\n]*\n)*\s*'
                   r'if messages\[msgIdx\]\.isAwaitingModelResponse \{\n\s*'
                   r'messages\[msgIdx\]\.isAwaitingModelResponse = false', sse) is not None,
         'the same transaction clears isAwaitingModelResponse (footer placeholder hand-off)')
    need('guard !ToolFoldPlanner.isBlank(lead) else {' in sse and 'pendingThinkingLead = lead' in sse,
         'a whitespace-only opener creates no block at all')
    need('result.thinkingText = lead' in sse and 'lastThinkingDeltaFlush = Date()' in sse,
         'the per-block accumulator starts with the lead and the throttle clock resets')
    # [deterministic clock, 2026-11-17] The intermediate flush is decided by a
    # wall-clock timer in the body this fixture compiles verbatim; the logic run
    # therefore asserts the CLOCK-FREE facts (birth transaction, prefix) and this
    # audit pins the production predicate, so deleting the throttle fails here.
    need('thinkNow.timeIntervalSince(lastThinkingDeltaFlush) >= flushInterval' in sse
         and 'AssistantBlock.thinkingFlushInterval(forLength: result.thinkingText.count)' in sse,
         'the intermediate flush is still the adaptive production timer (not re-implemented)')
    delta_body = slice_between(sse, 'case .thinkingDelta(let text):', 'case .reasoningContent(let rc):',
                              'thinkingDelta')
    need('asyncAfter' not in delta_body and 'Task.sleep' not in delta_body,
         'no delay introduced in the thinking delta path')

    # 2. The list's blank-thinking row decision is the shared policy.
    need('enum LivePlaceholderPolicy {' in snap, 'LivePlaceholderPolicy exists in the snapshot builder')
    need(re.search(r'!LivePlaceholderPolicy\.blankThinkingKeepsRow\(\s*\n?\s*'
                   r'hasFoldRowAbove: foldRowEmitted,\s*\n?\s*'
                   r'footerOwnsPlaceholder: message\.shouldShowTypingIndicator,\s*\n?\s*'
                   r'isLiveTail: blocks\[bi\]\.id == liveTailBlockId\)', snap) is not None,
         'blank-thinking suppression asks the policy with the fold row + footer owner')
    need(re.search(r'newItems\.append\(\.toolGroup\(message\.id, run\.firstBlockId\)\)\n'
                   r'\s*foldRowEmitted = true', snap) is not None,
         'the fold row marks itself as emitted above the walk position')
    need(re.search(r'var foldRowEmitted = false', snap) is not None,
         'the fold-row flag is per message (declared inside the message walk)')
    need(re.search(r'if blocks\[bi\]\.kind == \.thinking,\s*\n\s*blocks\[bi\]\.id != liveTailBlockId,', snap)
         is None,
         'the live tail is no longer exempted from the blank-thinking rule by itself')
    # Old semantics kept: a blank block that is NOT the live tail still gets no row.
    need('guard isLiveTail else { return false }' in snap,
         'settled blank thinking still draws no row')
    need('if footerOwnsPlaceholder { return false }' in snap,
         'the footer typing indicator owns the placeholder when it is drawn')

    # 3. The shared blank test still consults both content and buffer.
    need('isBlank(block.content) && isBlank(block.thinkingContentBuffer)' in planner,
         'planner isBlankThinking unchanged (content + buffer)')
    # 4. The typing indicator is still gated on the waiting flag only.
    need('guard isAwaitingModelResponse else { return false }' in models,
         'typing indicator unchanged: still owned by isAwaitingModelResponse')
    # 5. No hidden-animation cover-up in the touched code.
    for tag in ['T-fold-first-thinking-atomic', 'T-fold-blank-thinking-atomic']:
        need(tag in sse or tag in snap, f'marker {tag} present for traceability')


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        sys.exit(f'extraction failed: start marker not found ({label})')
    j = text.find(end, i + len(start))
    if j < 0:
        sys.exit(f'extraction failed: end marker not found ({label})')
    return text[i:j]


# ------------------------------------------------------------------ harness ---
FIXTURE = r'''
// ---- production model surface the sliced streaming body talks to ----------
final class AssistantBlock {
    enum Kind { case text, thinking, info, delegateTool, userAskTool, genuiTool, shellTool,
                fileReadTool, fileWriteTool, fileEditTool, browserTool, readImageTool, memoryTool }
    enum Status: CaseIterable { case success, failed, cancelled, streaming, running }
    let id = UUID()
    var kind: Kind
    var content: String
    var thinkingContentBuffer = ""
    var toolStatus: Status?
    var toolUseId: String?
    var toolDuration: TimeInterval?
    var contentUpdateSeq = 0
    var flushCount = 0

    init(kind: Kind, content: String = "") { self.kind = kind; self.content = content }

    // Verbatim tier table + selector semantics from ChatModels.swift.
    static let thinkingFlushTiers: [(maxLength: Int, interval: TimeInterval)] = [
        (1_000, 0.3), (3_000, 0.6), (Int.max, 1.0),
    ]
    static func thinkingFlushInterval(forLength length: Int) -> TimeInterval {
        for tier in thinkingFlushTiers where length < tier.maxLength { return tier.interval }
        return thinkingFlushTiers[thinkingFlushTiers.count - 1].interval
    }
    func appendThinkingDelta(_ delta: String) { thinkingContentBuffer += delta; contentUpdateSeq += 1 }
    func flushThinkingBuffer() {
        guard kind == .thinking, thinkingContentBuffer.count > content.count else { return }
        content = thinkingContentBuffer
        flushCount += 1
    }
}

struct StreamResult { var thinkingText: String = "" }

final class ChatMessage {
    let id = UUID()
    var blocks: [AssistantBlock] = []
    var isAwaitingModelResponse = false
    init(_ blocks: [AssistantBlock] = []) { self.blocks = blocks }
    /// Mirrors ChatModels.swift `shouldShowTypingIndicator` (the real one is
    /// pinned by the python audit: `blocks.isEmpty` / `guard isAwaitingModelResponse`).
    var shouldShowTypingIndicator: Bool {
        if blocks.isEmpty { return true }
        guard isAwaitingModelResponse else { return false }
        return !blocks.contains { $0.toolStatus == .streaming || $0.toolStatus == .running }
    }
}

final class Signal { var sends = 0; func send() { sends += 1 } }
final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var updates = 0
    func updateToolInfo(sessionId: String, toolName: String, toolStatus: String) { updates += 1 }
}

var checks = 0
var problems: [String] = []
func check(_ ok: Bool, _ label: String) {
    checks += 1
    if !ok { problems.append(label); print("FAIL: \(label)") }
}

// ---- the rows the list would build (mirror of the snapshot walk) ----------
enum Row: Equatable, CustomStringConvertible {
    case group(String)
    case block(UUID)
    case footer
    var description: String {
        switch self {
        case .group(let k): return "group(\(k.prefix(4)))"
        case .block(let id): return "block(\(id.uuidString.prefix(4)))"
        case .footer: return "footer"
        }
    }
}

struct Frame {
    let rows: [Row]
    let blankRows: Int
    let groupCount: Int
    let typing: Bool
    var signature: [String] { rows.map { r -> String in
        if case .group = r { return "group" }
        if case .footer = r { return "footer" }
        return "block" } }
}

@MainActor
final class List {
    var expanded: Set<String> = []
    var runningMessageId: UUID?

    /// Mirrors MessageListV3Coordinator+Snapshot's assistant walk: a run draws
    /// one `.toolGroup`, its members draw only while expanded, hidden members
    /// draw nothing, and a blank thinking block follows `LivePlaceholderPolicy`.
    /// The fixtures below have no lead gaps, which is asserted separately.
    func frame(_ message: ChatMessage, ended: Bool) -> Frame {
        let horizon = ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningMessageId,
                                                  separators: [:])
        let blocks = Array(message.blocks.prefix(horizon))
        let runs = ToolFoldPlanner.foldedRuns(in: blocks, ended: ended)
        check(runs.allSatisfy { $0.visibleIds.isEmpty }, "fixture has no lead gaps")
        var runByAnchor: [UUID: ToolFoldPlanner.FoldedRun] = [:]
        var hidden: Set<UUID> = []
        for run in runs {
            runByAnchor[run.anchorBlockId] = run
            hidden.formUnion(run.memberIds)
        }
        let liveTailBlockId: UUID? = runningMessageId == message.id ? message.blocks.last?.id : nil
        var rows: [Row] = []
        var blankRows = 0
        var groupCount = 0
        var foldRowEmitted = false
        var bi = 0
        while bi < blocks.count {
            if let run = runByAnchor[blocks[bi].id] {
                rows.append(.group(run.key))
                groupCount += 1
                foldRowEmitted = true
                if expanded.contains(run.key) {
                    rows.append(contentsOf: blocks[run.group.range]
                        .filter { !($0.kind == .thinking && ToolFoldPlanner.isBlankThinking($0)) }
                        .map { .block($0.id) })
                }
                bi += 1
                continue
            }
            if hidden.contains(blocks[bi].id) { bi += 1; continue }
            if blocks[bi].kind == .thinking,
               ToolFoldPlanner.isBlankThinking(blocks[bi]),
               !LivePlaceholderPolicy.blankThinkingKeepsRow(
                    hasFoldRowAbove: foldRowEmitted,
                    footerOwnsPlaceholder: message.shouldShowTypingIndicator,
                    isLiveTail: blocks[bi].id == liveTailBlockId) {
                bi += 1
                continue
            }
            if blocks[bi].kind == .thinking, ToolFoldPlanner.isBlankThinking(blocks[bi]) { blankRows += 1 }
            rows.append(.block(blocks[bi].id))
            bi += 1
        }
        let typing = message.shouldShowTypingIndicator
        if typing { rows.append(.footer) }
        return Frame(rows: rows, blankRows: blankRows, groupCount: groupCount, typing: typing)
    }
}

func think(_ text: String) -> AssistantBlock { AssistantBlock(kind: .thinking, content: text) }
func tool(_ kind: AssistantBlock.Kind, _ status: AssistantBlock.Status?) -> AssistantBlock {
    let b = AssistantBlock(kind: kind)
    b.toolStatus = status
    b.toolUseId = UUID().uuidString
    b.toolDuration = 4
    return b
}

/// Drives the PRODUCTION `.thinkingDelta` body — sliced out of
/// AIChatViewModel+SSEStream.swift and pasted here — with the fixture's own
/// members, then delivers exactly one snapshot per stream event (what
/// `receive(on: DispatchQueue.main)` does: never mid-transaction).
@MainActor
final class Stream {
    var messages: [ChatMessage]
    let msgIdx = 0
    var currentThinkingBlockIdx: Int? = nil
    var pendingThinkingLead: String = ""
    var result = StreamResult()
    var lastThinkingDeltaFlush: Date = .distantPast
    let sessionId: String? = nil
    var isNearBottom = false
    let scrollToBottomSignal = Signal()
    let list = List()
    var frames: [Frame] = []
    var publishes = 0

    init(_ blocks: [AssistantBlock], processing: Bool = true, waiting: Bool = true) {
        let m = ChatMessage(blocks)
        m.isAwaitingModelResponse = waiting
        messages = [m]
        list.runningMessageId = processing ? m.id : nil
    }

    var message: ChatMessage { messages[0] }
    func publishUnlessTransitioning() { publishes += 1 }

    func step(_ text: String) async {
        for _ in 0..<1 {
%%BODY%%
        }
        frames.append(list.frame(message, ended: false))
    }

    func stepText(_ text: String) async -> Frame {
        await step(text)
        return frames.last!
    }
}
'''

CHECKS = r'''
@MainActor
func run() async {
    // ---------------------------------------------------------------- S1 ---
    // The recorded timeline: "Ran 2 tools · 9s" folded, a new round opens with
    // whitespace, then visible thinking arrives in several deltas.
    do {
        let s = Stream([think(String(repeating: "思", count: 907)), tool(.shellTool, .success),
                        tool(.shellTool, .success)])
        let before = s.list.frame(s.message, ended: false)
        check(before.groupCount == 1 && before.rows.count == 2, "fold row + footer before the new round")
        let blockCountBefore = s.message.blocks.count

        var frameIndex = 0
        // The frame in which the block is born: the one place the throttle cannot
        // reach, so it is where "born with its text, flushed once" is asserted.
        var birthState: (content: String, buffer: String, flushes: Int)? = nil
        for delta in ["\n", "", "  \t\n", "思", "考", "\n思考更深"] {
            let f = await s.stepText(delta)
            frameIndex += 1
            if s.message.blocks.count == blockCountBefore + 1, birthState == nil {
                let born = s.message.blocks.last!
                birthState = (born.content, born.thinkingContentBuffer, born.flushCount)
            }
            check(f.blankRows == 0, "S1 step \(frameIndex) (\(delta.debugDescription)): no standalone blank thinking row")
            check(f.groupCount == 1, "S1 step \(frameIndex): the fold row above survives (no unfold/refold)")
            check(f.rows.filter { if case .block = $0 { return true }; return false }.count == 0,
                  "S1 step \(frameIndex): no block row appears under the fold row")
            check(!LivePlaceholderPolicy.isDoublePlaceholder(
                    hasFoldRow: f.groupCount > 0,
                    blankThinkingKeepsRow: f.blankRows > 0),
                  "S1 step \(frameIndex): one placeholder owner at most")
            check(!(f.typing && f.blankRows > 0),
                  "S1 step \(frameIndex): never a blank thinking row AND the footer indicator")
        }
        check(s.message.blocks.count == blockCountBefore + 1, "S1: exactly one thinking block for the new round")
        let tail = s.message.blocks.last!
        check(tail.kind == .thinking, "S1: the new block is thinking")
        check(tail.thinkingContentBuffer == "\n  \t\n思考\n思考更深",
              "S1: the buffer carries every delta in order, whitespace opener included (\(tail.thinkingContentBuffer.debugDescription))")
        // [deterministic clock, 2026-11-17] Production flushes `content` on a
        // Date()-based adaptive timer (0.3s while the thinking is under 1K
        // chars). One step of this timeline can take longer than that on an
        // emulated runner, so a second/third flush DURING the timeline is the
        // production throttle working, not a regression — the same tree failed
        // these two assertions on one run and passed them on the next. They are
        // now split into the facts that hold on every clock, with no behaviour
        // threshold relaxed: the birth transaction still flushes exactly once
        // WITH the first visible text, and `content` is only ever a flush of the
        // buffer (a prefix), so it can never be invented, reordered or blank.
        if let born = birthState {
            check(born.content == "\n  \t\n思",
                  "S1: the block is BORN flushed — non-blank from the first visible delta (\(born.content.debugDescription))")
            check(born.flushes == 1, "S1: exactly one flush in the birth transaction (\(born.flushes))")
        } else {
            check(false, "S1: the thinking block is born inside the delta timeline")
        }
        check(tail.content == "\n  \t\n思" || tail.thinkingContentBuffer.hasPrefix(tail.content),
              "S1: content is always a flush of the buffer, never invented text (\(tail.content.debugDescription))")
        check(!ToolFoldPlanner.isBlankThinking(tail), "S1: the planner never sees it empty")
        check(tail.flushCount >= 1, "S1: the birth flush landed, then the throttle owns later flushes (\(tail.flushCount))")
        check(!s.message.isAwaitingModelResponse, "S1: the waiting flag was cleared by the first delta")
        check(!s.message.shouldShowTypingIndicator, "S1: the footer typing indicator is no longer drawn")
        check(s.result.thinkingText == tail.thinkingContentBuffer, "S1: accumulator matches the block text")
    }

    // ---------------------------------------------------------------- S2 ---
    // First delta is ONE transaction: born with text, flushed, waiting cleared.
    do {
        let s = Stream([think("已完成"), tool(.shellTool, .success), tool(.shellTool, .success)])
        let f = await s.stepText("先看日志")
        let born = s.message.blocks.last!
        check(s.message.blocks.count == 4, "S2: block appended on the FIRST visible delta")
        check(born.content == "先看日志", "S2: content is non-blank the instant the block exists")
        check(born.thinkingContentBuffer == born.content, "S2: buffer == content, no unflushed window")
        check(f.blankRows == 0 && f.groupCount == 1, "S2: no blank row, fold row intact")
        check(!s.message.isAwaitingModelResponse, "S2: waiting flag cleared in the same transaction")
        // The old shape (blank append, text later) is what the policy now rejects.
        check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: true,
                                                         footerOwnsPlaceholder: false,
                                                         isLiveTail: true) == false,
              "S2: counterfactual — a blank tail under a fold row WOULD be a row under the old rule")
    }

    // ---------------------------------------------------------------- S3 ---
    // Whitespace opener: no block, no snapshot at all.
    do {
        let s = Stream([think("已完成"), tool(.shellTool, .success), tool(.shellTool, .success)])
        let n = s.message.blocks.count
        for delta in ["\n", "   ", "\u{200B}"] {
            let f = await s.stepText(delta)
            check(s.message.blocks.count == n, "S3: whitespace-only delta \(delta.debugDescription) creates no block")
            check(f.blankRows == 0 && f.groupCount == 1, "S3: rows unchanged while the opener is invisible")
        }
        let f = await s.stepText("ABC")
        check(s.message.blocks.count == n + 1, "S3: one block once text is visible")
        check(s.message.blocks.last!.content == "\n   \u{200B}ABC",
              "S3: the held-back whitespace is prepended in order, nothing dropped (\(s.message.blocks.last!.content.debugDescription))")
        check(f.blankRows == 0, "S3: still no standalone blank row")
    }

    // ---------------------------------------------------------------- S4 ---
    // Manual expansion survives the tail joining the run.
    do {
        let lead = think("已完成")
        let t1 = tool(.shellTool, .success), t2 = tool(.shellTool, .success)
        let s = Stream([lead, t1, t2])
        let runsBefore = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(runsBefore.count == 1, "S4: one folded run before the new round")
        s.list.expanded.insert(runsBefore[0].key)
        let expandedFrame = s.list.frame(s.message, ended: false)
        check(expandedFrame.rows.contains(.block(t1.id)) && expandedFrame.rows.contains(.block(t2.id)),
              "S4: expanded run shows its members")
        let keyBefore = runsBefore[0].key
        let f = await s.stepText("继续思考")
        let runsAfter = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(runsAfter.count == 1 && runsAfter[0].key == keyBefore, "S4: run key stable when the tail joins")
        check(s.list.expanded.contains(runsAfter[0].key), "S4: manual expansion still matches the run")
        check(f.rows.contains(.block(s.message.blocks.last!.id)),
              "S4: the joined thinking shows inside the expanded run, not as a stray row")
        check(f.groupCount == 1, "S4: still exactly one fold row")
    }

    // ---------------------------------------------------------------- S5 ---
    // An interactive card keeps its own row, with a blank tail below it.
    do {
        let card = tool(.genuiTool, .success)
        let s = Stream([think("已完成"), tool(.shellTool, .success), tool(.shellTool, .success), card],
                       waiting: true)
        let f = s.list.frame(s.message, ended: false)
        check(f.rows.contains(.block(card.id)), "S5: interactive card keeps its own row")
        check(f.groupCount == 1, "S5: the card does not restart the fold row")
        let f2 = await s.stepText("卡片看过了")
        check(f2.rows.contains(.block(card.id)), "S5: card row survives the new thinking delta")
        check(f2.blankRows == 0, "S5: no blank thinking row next to the card")
        let runs = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(!runs.contains { $0.memberIds.contains(card.id) }, "S5: card is never a fold member")
    }

    // --------------------------------------------------------------- S5b ---
    // [T-fold-open-card] A show_ui that starts streaming right below a row that
    // is already folded. It used to be a `.barrier`: the row came apart for as
    // long as the program streamed and folded again when the card validated.
    // Now the open card closes the run like the card does, keeps its own row,
    // and the key never changes — so a manual expansion keeps matching.
    do {
        let s = Stream([think("已完成"), tool(.shellTool, .success), tool(.shellTool, .success)])
        let before = s.list.frame(s.message, ended: false)
        let runBefore = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(before.groupCount == 1 && runBefore.count == 1, "S5b: one folded row before the show_ui")
        let keyBefore = runBefore[0].key
        let ui = tool(.genuiTool, .streaming)
        s.message.blocks.append(ui)
        let streaming = s.list.frame(s.message, ended: false)
        check(streaming.groupCount == 1, "S5b: the fold row above survives the show_ui streaming")
        check(streaming.rows.contains(.block(ui.id)), "S5b: the streaming show_ui keeps its own capsule row")
        let runStreaming = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(runStreaming.count == 1 && runStreaming[0].key == keyBefore,
              "S5b: same run, same key, no re-fold with a new identity")
        check(!runStreaming[0].memberIds.contains(ui.id), "S5b: the open card is never a member")
        s.list.expanded.insert(keyBefore)
        let expandedFrame = s.list.frame(s.message, ended: false)
        check(expandedFrame.rows.contains(.block(s.message.blocks[1].id)),
              "S5b: a manual expansion still shows the members under the surviving row")
        s.list.expanded.remove(keyBefore)
        ui.toolStatus = .running
        let running = s.list.frame(s.message, ended: false)
        check(running.groupCount == 1 && running.rows.contains(.block(ui.id)),
              "S5b: running keeps the row and the capsule")
        ui.toolStatus = .success
        let landed = s.list.frame(s.message, ended: false)
        check(landed.groupCount == 1 && landed.rows.contains(.block(ui.id)),
              "S5b: the card landing keeps one folded row and its own row")
        let runLanded = ToolFoldPlanner.foldedRuns(in: s.message.blocks, ended: false)
        check(runLanded.count == 1 && runLanded[0].key == keyBefore && runLanded[0].memberIds == runBefore[0].memberIds,
              "S5b: the row is identical before and after the card lands (no range or count jump)")
        // The plain barrier keeps its contract: an info row still discards.
        let info = AssistantBlock(kind: .info, content: "info")
        let withInfo = Stream([think("已完成"), tool(.shellTool, .success), tool(.shellTool, .success), info])
        let infoFrame = withInfo.list.frame(withInfo.message, ended: false)
        check(infoFrame.groupCount == 0, "S5b: an info row still discards the open run (barrier contract)")
    }

    // ---------------------------------------------------------------- S6 ---
    // Semantics kept: the opening placeholder of a turn with no calls.
    do {
        let blank = AssistantBlock(kind: .thinking, content: "")
        let s = Stream([blank], waiting: true)
        let f = s.list.frame(s.message, ended: false)
        check(f.groupCount == 0, "S6: a blank thinking-only turn has no fold row (empty text never folds)")
        check(f.blankRows == 0, "S6: the footer indicator owns the wait, not a second blank row")
        check(f.typing, "S6: the footer draws the wait")
        check(!LivePlaceholderPolicy.isDoublePlaceholder(hasFoldRow: f.groupCount > 0,
                                                        blankThinkingKeepsRow: f.blankRows > 0),
              "S6: single owner for the opening wait")
        // With nothing else on screen (no fold row, no footer) the blank tail
        // is still the placeholder — the semantics folding must not break.
        check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: false,
                                                         footerOwnsPlaceholder: false,
                                                         isLiveTail: true),
              "S6: no fold row and no footer -> the blank tail owns its row")
    }

    // ---------------------------------------------------------------- S7 ---
    // A settled blank block still draws nothing.
    do {
        let s = Stream([think("已完成"), tool(.shellTool, .success), AssistantBlock(kind: .thinking, content: "")],
                       processing: false, waiting: false)
        let f = s.list.frame(s.message, ended: true)
        check(f.blankRows == 0, "S7: settled blank thinking keeps no row")
        check(f.groupCount == 1, "S7: the run is still folded once the turn ends")
    }

    // ---------------------------------------------------------------- S8 ---
    // The policy is the only thing standing between the two shapes.
    check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: true, footerOwnsPlaceholder: false,
                                                     isLiveTail: true) == false,
          "S8: blank tail under a fold row -> no row")
    check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: false, footerOwnsPlaceholder: true,
                                                     isLiveTail: true) == false,
          "S8: blank tail under the footer indicator -> no row")
    check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: false, footerOwnsPlaceholder: false,
                                                     isLiveTail: true) == true,
          "S8: blank tail with nothing above -> keeps the placeholder row")
    check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: false, footerOwnsPlaceholder: false,
                                                     isLiveTail: false) == false,
          "S8: settled blank -> no row")
    check(LivePlaceholderPolicy.isDoublePlaceholder(hasFoldRow: true, blankThinkingKeepsRow: true) == true,
          "S8: the double-placeholder predicate is sensitive")

    if problems.isEmpty {
        print("FOLD_FLASH_PASS checks=\(checks)")
    } else {
        print("FOLD_FLASH_FAIL checks=\(checks) problems=\(problems.count)")
        for p in problems { print("  - \(p)") }
        exit(1)
    }
    exit(0)
}
// MainActor's executor on Linux is the main dispatch queue: drain it so the
// `await MainActor.run` hops inside the sliced production body can complete.
Task { @MainActor in await run() }
dispatchMain()
'''


def build_harness():
    """The production planner file is compiled whole (like
    scripts/toolfold-adapter-tests.swift): it holds the enum in more than one
    block, and slicing it would cut `foldedRuns` / `isBlankThinking` off."""
    snap_src = snap_path.read_text()
    policy = slice_between(snap_src, 'enum LivePlaceholderPolicy {',
                           '\nextension CollectionViewMessageListV3.Coordinator {', 'policy') + '\n'

    sse_src = sse_path.read_text()
    body = slice_between(sse_src, 'case .thinkingDelta(let text):', 'case .reasoningContent(let rc):',
                         'thinkingDelta')
    # Strip the case label: the fixture owns the loop entry point.
    body = body.split('\n', 1)[1]
    body = '\n'.join(('        ' + line) if line.strip() else line for line in body.splitlines())

    fixture = FIXTURE.replace('%%BODY%%', body)
    main = 'import Foundation\n\n' + policy + '\n' + fixture + '\n' + CHECKS
    path = out / 'main.swift'
    path.write_text(main)
    note(f'HARNESS_LINES {main.count(chr(10)) + 1} (production slices: policy '
         f'{policy.count(chr(10)) + 1}, delta body {body.count(chr(10)) + 1}; planner compiled whole)')
    return path


def run_harness():
    path = build_harness()
    swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
    exe = out / 'flash'
    build = subprocess.run([swiftc, '-swift-version', '5', str(planner_path), str(path),
                            '-o', str(exe)], capture_output=True, text=True)
    if build.returncode != 0:
        note('HARNESS_COMPILE_FAILED')
        note(build.stderr[-6000:])
        return False
    note('HARNESS_COMPILE_OK')
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    note(run.stdout.strip()[-8000:])
    if run.returncode != 0 or 'FOLD_FLASH_PASS' not in run.stdout:
        note(run.stderr[-4000:])
        note('HARNESS_RUN_FAILED')
        return False
    return True


def main():
    source_audit()
    if failures:
        note('SOURCE_AUDIT_FAILED')
        for f in failures:
            note('  - ' + f)
        sys.exit(1)
    note('SOURCE_AUDIT_OK')
    if '--source-only' in sys.argv[1:]:
        note('FOLD_FLASH_SOURCE_ONLY_OK')
        return
    if not run_harness():
        sys.exit(1)
    note('TOOLFOLD_LIVE_THINKING_FLASH_OK')


main()
