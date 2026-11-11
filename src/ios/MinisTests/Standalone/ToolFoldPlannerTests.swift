// Tests for [T-fold-consecutive-tools] — which runs of tool calls the message
// list folds into one "Ran N tools" row — and for [T-fold-all-process], which
// makes that row the whole process of a request: a single call, and a run of
// thinking on its own ("Thinking process"). Compiles the REAL ToolFoldPlanner
// out of Agent/MessageList/ToolFoldPlanner.swift and runs it, then checks the
// list, settings and localization wiring in source.
//
// Standalone: `swift ToolFoldPlannerTests.swift` from this directory.
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ l: String, _ ok: Bool) {
    if ok { print("  ✅ \(l)") } else { print("  ❌ \(l)"); failures += 1 }
}
let root = FileManager.default.currentDirectoryPath + "/../../"
func read(_ p: String) -> String { (try? String(contentsOfFile: root + p, encoding: .utf8)) ?? "" }
let plannerSrc = read("Agent/MessageList/ToolFoldPlanner.swift")
check("ToolFoldPlanner.swift readable", !plannerSrc.isEmpty)
guard let s = plannerSrc.range(of: "enum ToolFoldPlanner {"),
      let e = plannerSrc.range(of: "// END ToolFoldPlanner", range: s.upperBound..<plannerSrc.endIndex) else {
    print("❌ ToolFoldPlanner not found"); exit(1)
}
let planner = String(plannerSrc[s.lowerBound..<e.lowerBound])

// Block notation: T = succeeded tool, F = failed, C = cancelled, R = unfinished
// (running/streaming), K = thinking, t = non-empty multi-line text, o = non-empty
// ONE-line text, e = empty text, B = barrier (info / delegate). Output: one
// "lo-hi:tools/failed/cancelled" per group, or "none". Like the list, `show`
// runs `markingNotes` first ([T-fold-tool-notes]).
let harness = "import Foundation\n" + planner + #"""
func parse(_ s: String) -> [ToolFoldPlanner.Input] {
    s.map { c -> ToolFoldPlanner.Input in
        switch c {
        case "T": return .tool(.succeeded)
        case "F": return .tool(.failed)
        case "C": return .tool(.cancelled)
        case "R": return .tool(.unfinished)
        case "K": return .thinking
        case "t", "o": return .text(isEmpty: false)
        case "e": return .text(isEmpty: true)
        default: return .barrier
        }
    }
}
func show(_ s: String, enabled: Bool = true) -> String {
    let chars = Array(s)
    let inputs = ToolFoldPlanner.markingNotes(parse(s)) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: enabled, ended: true)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.toolCount)/\($0.failedCount)/\($0.cancelledCount)" }
        .joined(separator: ",")
}
// [T-fold-stopped-tools] The same message while its task still runs: the run
// that ends it is the pause before the next calls, so it stays open.
func live(_ s: String) -> String {
    let chars = Array(s)
    let inputs = ToolFoldPlanner.markingNotes(parse(s)) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: true, ended: false)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.toolCount)/\($0.failedCount)/\($0.cancelledCount)" }
        .joined(separator: ",")
}
let cases: [(String, String)] = [
    ("three", "TTTt"),
    ("two", "TTt"),
    ("one", "Tt"),
    ("oneThink", "TKKt"),
    ("leadText", "tTTTTt"),
    ("interleaved", "KTKTTt"),
    ("thinkOnly", "TKKTt"),
    ("thinkMid", "TKTKTt"),
    ("emptyMid", "TTeTt"),
    ("infoMid", "TTBTTt"),
    ("delegateSplit", "TTTBTTTt"),
    ("noReply", "tTTTT"),
    ("noReplyEmpty", "TTTe"),
    ("running", "TTTRt"),
    ("runningFirst", "RTTTt"),
    ("failCancel", "TFCTt"),
    ("twoRuns", "TTTtTTTTt"),
    ("trailingThink", "TTTKt"),
    ("trailingThinks", "TTKeKt"),
    ("trailingAll", "KTKTKt"),
    ("trailingNoReply", "TTK"),
    ("trailingOneTool", "TKt"),
    ("trailingThenCall", "TTKTt"),
    ("trailingThinkingRun2", "TTtTTKt"),
    ("allThinking", "KKKt"),
    // [T-fold-tool-notes]
    ("noteExample", "ToTo"),
    ("noteThenReply", "ToTt"),
    ("notesLong", "ToToTTt"),
    ("multiLineMid", "TTtTTt"),
    ("noteLive", "TToR"),
    ("noteNoReply", "TToTT"),
    ("noteOneTool", "ToR"),
    ("noteLead", "oTTt"),
    ("noteBeforeBarrier", "TToBt"),
    ("noteThink", "TKoTt"),
    ("noteAfterSoftEnd", "TToTTR"),
    // [T-fold-lead-thinking]
    ("leadThink", "KTTt"),
    ("leadThinks", "KKeTTt"),
    ("leadThinkAfterText", "tKTTt"),
    ("leadThinkSecondRun", "TTtKTTt"),
    ("leadThinkOneTool", "KTt"),
    ("leadThinkNote", "KoTTt"),
    ("leadThinkBarrier", "KBTTt"),
    ("leadThinkRunning", "KRTTt"),
    // [T-fold-all-process] One row per process, whatever it is made of.
    ("singleToolReply", "Tt"),
    ("singleToolLong", "Ttt"),
    ("singleToolStop", "T"),
    ("oneToolBothEndsThink", "KTKt"),
    ("thinkReply", "Kt"),
    ("thinkTwoReplies", "Ktt"),
    ("thinkOnlyEmptyText", "KeKt"),
    ("thinkBetweenReplies", "tKt"),
    ("thinkAfterReply", "tK"),
    ("twoThinkRuns", "KtKt"),
    ("leadEmptyThenThink", "eKt"),
    ("emptyThinkEmpty", "eKe"),
    ("pureText", "tt"),
    ("oneLineText", "o"),
    ("emptyOnly", "e"),
    // [T-fold-stopped-tools] The task is over and no reply follows the last
    // call: a Stop, a failed turn or a reply-less end. `stoppedFiveThink` is
    // the message the user's screenshot shows (5 calls, thinking before,
    // between and after them).
    ("stoppedTwo", "TT"),
    ("stoppedFiveThink", "KTKTKTKTKTK"),
    ("stoppedCancel", "KTKTC"),
    ("stoppedFail", "TTF"),
    ("stoppedFailCancel", "TTCTF"),
    ("stoppedOne", "C"),
    ("stoppedNoTools", "KK"),
    ("stoppedRunning", "TTTR"),
    ("stoppedBarrier", "TTB"),
    ("stoppedTrailThink", "TKTK"),
    ("stoppedAfterNote", "TToT"),
    ("stoppedTwoRuns", "TTtKTTC"),
]
print("single1=\(ToolFoldPlanner.isSingleLine("  Now checking the logs.  \n"))")
print("single2=\(ToolFoldPlanner.isSingleLine("line one\nline two"))")
print("single3=\(ToolFoldPlanner.isSingleLine("\n\nOne line after blank lines\n\n"))")
print("single4=\(ToolFoldPlanner.isSingleLine(""))")
// [T-fold-all-process] What the row is: a run with no call at all is the
// thinking, and must never be drawn as "Ran 0 tools".
func kinds(_ s: String) -> String {
    let chars = Array(s)
    let inputs = ToolFoldPlanner.markingNotes(parse(s)) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: true, ended: true)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.kind == .thinking ? "thinking" : "tools"):\($0.toolCount)/\($0.thinkingCount)" }
        .joined(separator: ",")
}
for (name, input) in cases { print("\(name)=\(show(input))") }
print("kindTool=\(kinds("Tt"))")
print("kindThink=\(kinds("KKKt"))")
print("kindMixed=\(kinds("KTKt"))")
print("kindTwoRuns=\(kinds("KtKt"))")
print("kindNone=\(kinds("tt"))")
print("minThink=\(ToolFoldPlanner.minimumThinkingCount)")
// [T-fold-stopped-tools] The same blocks, task still running vs ended.
print("stStoppedLive=\(live("KTKTC"))|\(show("KTKTC"))")
print("stStoppedPair=\(live("TT"))|\(show("TT"))")
print("stStoppedTrail=\(live("TKTK"))|\(show("TKTK"))")
print("stStoppedThink=\(live("KK"))|\(show("KK"))")
print("stStoppedThinkOne=\(live("K"))|\(show("K"))")
print("stStreamThink=\(running("K", 0))|\(running("Kt", 1))|\(running("Kt", 2))")
print("stLiveThinkNoReply=\(live("Kt"))")
// [T-fold-at-request-end] Timing. `running(s, h)` is what the list folds in a
// message whose task is still running: only its first `h` blocks are planned
// (notes marked within them), h = foldHorizon, `ended: false`. `show(s)` is the
// task-end view (`ended: true`), `live(s)` the same blocks with the task still
// running.
func running(_ s: String, _ horizon: Int) -> String {
    let chars = Array(s.prefix(horizon))
    let inputs = ToolFoldPlanner.markingNotes(parse(String(chars))) { chars[$0] == "o" }
    let g = ToolFoldPlanner.plan(inputs, enabled: true, ended: false)
    if g.isEmpty { return "none" }
    return g.map { "\($0.range.lowerBound)-\($0.range.upperBound):\($0.toolCount)/\($0.failedCount)/\($0.cancelledCount)" }
        .joined(separator: ",")
}
print("lines0=\(ToolFoldPlanner.nonEmptyLineCount(""))")
print("lines1=\(ToolFoldPlanner.nonEmptyLineCount("Checking the logs now."))")
print("lines1b=\(ToolFoldPlanner.nonEmptyLineCount("\n  \nOnly one line\n\n   \n"))")
print("lines2=\(ToolFoldPlanner.nonEmptyLineCount("First line\nSecond line"))")
print("lines2b=\(ToolFoldPlanner.nonEmptyLineCount("First\n\n\n   \nSecond\n"))")
print("lines2crlf=\(ToolFoldPlanner.nonEmptyLineCount("First\r\nSecond"))")
print("lines3=\(ToolFoldPlanner.nonEmptyLineCount("- a\n- b\n- c"))")
print("sep0=\(ToolFoldPlanner.isFoldSeparator(requestText: ""))")
print("sep1=\(ToolFoldPlanner.isFoldSeparator(requestText: "Now let me check the logs."))")
print("sep1blank=\(ToolFoldPlanner.isFoldSeparator(requestText: "One line\n\n   \n"))")
print("sep2=\(ToolFoldPlanner.isFoldSeparator(requestText: "Found it.\nThe config is wrong."))")
print("sep2blocks=\(ToolFoldPlanner.isFoldSeparator(requestText: ["First block", "Second block"].joined(separator: "\n")))")
print("minLines=\(ToolFoldPlanner.separatorMinimumLines)")
let ids = ["a", "b", "c", "d", "e"]
print("hNone=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: []))")
print("hOne=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["c"]))")
print("hLatest=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["b", "d"]))")
print("hGone=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["x"]))")
print("hGoneOne=\(ToolFoldPlanner.foldHorizon(blockIds: ids, separators: ["b", "x"]))")
// One task, step by step: T T, then a request whose reply streams ("t"), then
// a call (R) that runs and finishes (T), then the final reply.
print("stStreaming=\(running("TTt", 0))")        // reply streaming, no request end yet
print("stShortEnd=\(running("TToR", 0))")        // that request ended on a 1-line remark: no separator
print("stLongEnd=\(running("TTtR", 4))")         // ended on >=2 lines: separator = its last block (R)
print("stToolRuns=\(running("TTtTT", 4))")       // the next calls finish: nothing new folds mid-task
print("stNextStream=\(running("TTtTTt", 4))")    // next reply streams: still only the first run
// [T-fold-trailing-thinking] The thinking that trails the last call folds with
// the run only once the reply closing it is there; while it streams, nothing.
print("stTrailThink=\(running("KTKTK", 5))")     // thinking streams after the last call: no fold
print("stTrailThinkEnd=\(running("KTKTKt", 6))") // request ended on >=2 lines: one row for all of it
print("stTrailThinkHistory=\(show("KTKTKt"))")   // history / task end: the same group
print("stTaskEnd=\(show("TTtTTt"))")             // task ends: whole message, no line limit
// Retry / resume: the message's existing 6 blocks are a separator (floor), the
// new request's call (R) is past it — the folds from the ended task stay as-is.
print("stResume=\(running("TTtTToR", 6))|\(show("TTtTTo"))")
// [T-fold-browse-hold] holdsBack(browsing, alreadyFolded, running, shownAsRows)
var probed = 0
func hb(_ b: Bool, _ f: Bool, _ r: Bool, _ shown: Bool) -> Bool {
    ToolFoldPlanner.holdsBack(browsing: b, alreadyFolded: f, inRunningMessage: r, shownAsRows: { probed += 1; return shown })
}
print("hbAtBottom=\(hb(false, false, true, true))")
print("hbFolded=\(hb(true, true, true, true))")
print("hbRunning=\(hb(true, false, true, false))")
print("hbShownRows=\(hb(true, false, false, true))")
print("hbFreshSession=\(hb(true, false, false, false))")
probed = 0; _ = hb(false, false, false, true); _ = hb(true, true, false, true); _ = hb(true, false, true, true)
print("hbLazy=\(probed)")
print("stShortOnly=\(running("TToTTo", 0)),\(show("TToTTo"))") // only short replies: open until the end
print("off=\(show("TTTTt", enabled: false))")
print("min=\(ToolFoldPlanner.minimumToolCount)")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tfp-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let main = tmp.appendingPathComponent("main.swift"); try! harness.write(to: main, atomically: true, encoding: .utf8)
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}
let bin = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-o", bin, main.path])
check("ToolFoldPlanner compiles standalone", cs == 0)
if cs != 0 { print(cout); exit(1) }
let (_, o) = run(bin, [])
let lines = Set(o.split(separator: "\n").map(String.init))
func has(_ l: String) -> Bool { lines.contains(l) }

print("▶️  threshold")
check("3 tools + reply fold", has("three=0-2:3/0/0"))
check("2 tools + reply fold ([T-fold-tools-min2])", has("two=0-1:2/0/0"))
check("a single call before a reply folds too [T-fold-all-process]", has("one=0-0:1/0/0"))
check("one call is the threshold now (was 2)", has("min=1") && has("minThink=1"))
check("text before the run is not part of it", has("leadText=1-4:4/0/0"))

print("▶️  thinking and empty text")
check("interleaved thinking folds along, counts only tools (K T K T T t -> 3 tools, leading K too)", has("interleaved=0-4:3/0/0"))
check("thinking between tools does not break the run", has("thinkMid=0-4:3/0/0"))
check("thinking between 2 tools folds along (T K K T t -> 2 tools)", has("thinkOnly=0-3:2/0/0"))
check("thinking does not count toward the tool threshold (1 tool + thinking is one call)",
      has("oneThink=0-2:1/0/0"))
check("thinking alone IS a run: three thoughts and a reply fold into one row (K K K t)",
      has("allThinking=0-2:0/0/0"))
check("an empty text block does not break the run", has("emptyMid=0-3:3/0/0"))
print("▶️  thinking that trails the run [T-fold-trailing-thinking]")
check("thinking between the last tool and the reply folds with the run (T T T K t)",
      has("trailingThink=0-3:3/0/0"))
check("a stretch of thinking (and empty text) after the last tool folds whole (T T K e K t)",
      has("trailingThinks=0-4:2/0/0"))
check("lead AND trailing thinking fold: the whole execution is one row (K T K T K t)",
      has("trailingAll=0-4:2/0/0"))
check("one call with trailing thinking folds (T K t)", has("trailingOneTool=0-1:1/0/0"))
check("trailing thinking with no reply after it folds once the task has ended (T T K)", has("trailingNoReply=0-2:2/0/0"))
check("thinking followed by another call was already inside the run (T T K T t)",
      has("trailingThenCall=0-3:3/0/0"))
check("each run takes its own trailing thinking", has("trailingThinkingRun2=0-1:2/0/0,3-5:2/0/0"))
check("the planner declares the rule", planner.contains("[T-fold-trailing-thinking]"))

print("▶️  barriers")
check("an info block breaks the run: the 2 before it have no reply, the 2 after it fold", has("infoMid=3-4:2/0/0"))
check("a delegate block breaks the run; the run after it folds alone", has("delegateSplit=4-6:3/0/0"))

print("▶️  what closes a run: the reply, or the end of the task [T-fold-stopped-tools]")
check("a run the task ended on folds with no reply after it (t T T T T)", has("noReply=1-4:4/0/0"))
check("an empty text is never a reply, but the task end still folds the run (T T T e)", has("noReplyEmpty=0-2:3/0/0"))
check("while the task runs, a message that ends on its calls folds nothing — the next calls come (T T)",
      has("stStoppedPair=none|0-1:2/0/0"))
check("the user's screenshot shape: 5 calls, thinking before/between/after them, nothing after",
      has("stoppedFiveThink=0-10:5/0/0"))
check("a stopped run folds with its cancelled call counted (K T K T C)", has("stoppedCancel=0-4:3/0/1"))
check("thinking left trailing the last call folds into the row too (T K T K)", has("stoppedTrailThink=0-3:2/0/0"))
check("still one row, thinking at both ends (live: nothing, ended: one row)",
      has("stStoppedTrail=none|0-3:2/0/0"))
check("a failed call ends a stopped run the same way (T T F)", has("stoppedFail=0-2:3/1/0"))
check("cancelled and failed calls are both counted, not split (T T C T F)", has("stoppedFailCancel=0-4:5/1/1"))
check("after a remark, a stopped run folds whole (T T o T)", has("stoppedAfterNote=0-3:3/0/0"))
check("two runs in a stopped message: both fold, the second one on the end of the task",
      has("stoppedTwoRuns=0-1:2/0/0,3-6:3/0/1"))
check("at task end a single cancelled call folds, and so do two thoughts with no call at all",
      has("stoppedOne=0-0:1/0/1") && has("stoppedNoTools=0-1:0/0/0"))
check("a call that never finished keeps its capsules visible even at task end (T T T R)",
      has("stoppedRunning=none"))
check("an info/delegate row or an unanswered card still breaks the run at task end (T T B)",
      has("stoppedBarrier=none"))

print("▶️  status")
check("an unfinished tool before the reply keeps the run open (no fold)", has("running=none"))
check("an unfinished tool ends the run; the finished ones after it fold", has("runningFirst=1-3:3/0/0"))
check("failed and cancelled tools fold, and are counted", has("failCancel=0-3:4/1/1"))

print("▶️  one-line remarks between tool calls [T-fold-tool-notes]")
check("the user's example: T, 1-line, T, 1-line reply -> T..T fold, the final line stays as the reply", has("noteExample=0-2:2/0/0"))
check("a remark between calls folds with them; a multi-line reply closes the run", has("noteThenReply=0-2:2/0/0"))
check("several remarks keep one run going (4 tools)", has("notesLong=0-5:4/0/0"))
check("a MULTI-line text between calls still ends the run (two runs)", has("multiLineMid=0-1:2/0/0,3-4:2/0/0"))
check("live: a remark then a running call -> the part up to the remark stays folded", has("noteLive=0-2:2/0/0"))
check("message ends on tools after a remark: the task end folds the whole run (T T o T T)",
      has("noteNoReply=0-4:4/0/0"))
check("soft end: one call and a remark already qualify (T o R)", has("noteOneTool=0-1:1/0/0"))
check("a remark before the first call is not part of the run", has("noteLead=1-2:2/0/0"))
check("a one-line text with no call after it is the reply, not a remark", has("noteBeforeBarrier=0-1:2/0/0"))
check("thinking and a remark between calls both fold along", has("noteThink=0-3:2/0/0"))
check("tools after the soft end, then a running call -> only up to the remark folds", has("noteAfterSoftEnd=0-2:2/0/0"))
check("one line = no newline between first and last visible character",
      has("single1=true") && has("single2=false") && has("single3=true") && has("single4=true"))

print("▶️  thinking right before the run [T-fold-lead-thinking]")
check("thinking just before the first tool folds with the run", has("leadThink=0-2:2/0/0"))
check("a stretch of thinking (and empty text) before it folds whole", has("leadThinks=0-4:2/0/0"))
check("text before that thinking stays out", has("leadThinkAfterText=1-3:2/0/0"))
check("the second run takes its own leading thinking", has("leadThinkSecondRun=0-1:2/0/0,3-5:2/0/0"))
check("one call still takes its lead thinking along (K T t)", has("leadThinkOneTool=0-1:1/0/0"))
check("a remark between the thinking and the first tool keeps the thinking out", has("leadThinkNote=2-3:2/0/0"))
check("a barrier between them keeps the thinking out", has("leadThinkBarrier=2-3:2/0/0"))
check("an unfinished tool between them keeps the thinking out", has("leadThinkRunning=2-3:2/0/0"))

print("▶️  timing: fold at request end, not while streaming [T-fold-at-request-end]")
check("line count = lines with a visible character (0 / 1 / blank lines ignored / 2 / CRLF / 3)",
      has("lines0=0") && has("lines1=1") && has("lines1b=1") && has("lines2=2")
      && has("lines2b=2") && has("lines2crlf=2") && has("lines3=3"))
check("the threshold is a named constant, 2", has("minLines=2"))
check("separator: empty and 1-line replies are not; 1 line plus blank lines is not; 2 lines are",
      has("sep0=false") && has("sep1=false") && has("sep1blank=false") && has("sep2=true"))
check("separator: the whole request's text counts (two one-line blocks = 2 lines)", has("sep2blocks=true"))
check("horizon: none before the first separator; through its block; the latest wins; rolled-back ids ignored",
      has("hNone=0") && has("hOne=3") && has("hLatest=4") && has("hGone=0") && has("hGoneOne=2"))
check("streaming: a reply that is still streaming folds nothing (the task-end rule alone would)",
      has("stStreaming=none") && has("three=0-2:3/0/0"))
check("a request ending on a 1-line remark folds nothing mid-task", has("stShortEnd=none"))
check("a request ending on >=2 lines folds the run before it", has("stLongEnd=0-1:2/0/0"))
check("tools finishing after the separator do not fold mid-task", has("stToolRuns=0-1:2/0/0"))
check("the next reply streaming does not fold the next run yet", has("stNextStream=0-1:2/0/0"))
check("thinking streaming after the last call does not fold yet (the pill never vanishes mid-stream)",
      has("stTrailThink=none"))
check("the request end that carries the reply folds lead thinking, calls and trailing thinking into one row",
      has("stTrailThinkEnd=0-4:2/0/0"))
check("a reloaded/history message plans the same group", has("stTrailThinkHistory=0-4:2/0/0"))
check("task end folds the whole message, the run before a short reply included", has("stTaskEnd=0-1:2/0/0,3-4:2/0/0"))
check("only short replies: nothing mid-task, all folded at task end",
      has("stShortOnly=none,0-4:4/0/0"))
check("retry/resume on an ended message keeps its folds (floor separator = its last block)",
      has("stResume=0-1:2/0/0,3-4:2/0/0|0-1:2/0/0,3-4:2/0/0"))
check("browse hold: never at the bottom, never for an already-folded run",
      has("hbAtBottom=false") && has("hbFolded=false"))
check("browse hold: the running message, or a run whose blocks are on the list as rows [T-fold-browse-hold]",
      has("hbRunning=true") && has("hbShownRows=true"))
check("browse hold: a session just opened (rows never shown) folds at once", has("hbFreshSession=false"))
check("browse hold: the row lookup runs only when the cheap conditions leave it open", has("hbLazy=0"))
check("a folded run stays the same group as the task goes on (no flip-flop)",
      has("stLongEnd=0-1:2/0/0") && has("stToolRuns=0-1:2/0/0") && has("stNextStream=0-1:2/0/0"))

print("▶️  one row per process, whatever it is made of [T-fold-all-process]")
check("a single call and its reply (the memory_write screenshot: no thinking, one call)",
      has("singleToolReply=0-0:1/0/0") && has("singleToolLong=0-0:1/0/0"))
check("a stopped message that is nothing but one finished call still folds", has("singleToolStop=0-0:1/0/0"))
check("one call with thinking on BOTH sides is one row, not a pill + a capsule + a pill",
      has("oneToolBothEndsThink=0-2:1/0/0"))
check("thinking and a reply, no call at all: one 'Thinking process' row (K t)", has("thinkReply=0-0:0/0/0"))
check("the reply stays outside however many blocks it was loaded as (K t t)", has("thinkTwoReplies=0-0:0/0/0"))
check("empty text between thoughts does not split the run (K e K t)", has("thinkOnlyEmptyText=0-2:0/0/0"))
check("thinking between two segments of the body: the body stays out on both sides (t K t)",
      has("thinkBetweenReplies=1-1:0/0/0"))
check("thinking after the body is still a run of its own (t K)", has("thinkAfterReply=1-1:0/0/0"))
check("two processes in one message stay two rows (K t K t)", has("twoThinkRuns=0-0:0/0/0,2-2:0/0/0"))
check("an empty text before the thinking is not part of it (e K t)", has("leadEmptyThenThink=1-1:0/0/0"))
check("empty text is never a member: the run is the thought alone (e K e), and (e) is no run",
      has("emptyThinkEmpty=1-1:0/0/0") && has("emptyOnly=none"))
check("no thinking and no call is never a run (t t / one-line o)", has("pureText=none") && has("oneLineText=none"))
check("the kind comes from the members: no call at all = thinking, never 'Ran 0 tools'",
      has("kindTool=0-0:tools:1/0") && has("kindThink=0-2:thinking:0/3")
      && has("kindMixed=0-2:tools:1/2") && has("kindTwoRuns=0-0:thinking:0/1,2-2:thinking:0/1")
      && has("kindNone=none"))
check("a stopped message that was only thinking folds once ended, and not while it streams",
      has("stStoppedThink=none|0-1:0/0/0") && has("stStoppedThinkOne=none|0-0:0/0/0"))
check("a thinking block still being written folds nothing: no reply yet, or past the horizon",
      has("stStreamThink=none|none|0-0:0/0/0"))
check("mid-task a thought followed by a reply closes at that request end, like a call run",
      has("stLiveThinkNoReply=0-0:0/0/0"))

print("▶️  several runs")
check("two runs in one message give two groups", has("twoRuns=0-2:3/0/0,4-7:4/0/0"))

print("▶️  setting off")
check("with the setting off nothing folds", has("off=none"))

// MARK: - Wiring

let v3 = messageListV3Source()
let infra = read("Agent/MessageList/MessageListInfrastructure.swift")
let content = contentViewSource()
let registry = read("Shared/Config/ConfigRegistry+Builtins.swift")
let catalog = read("Localizable.xcstrings")
let blockView = read("Views/Chat/AssistantBlockView.swift")
let shareView = read("Views/Chat/ChatShareSelectionView.swift")
let exportRenderer = read("Views/Chat/ChatExportRenderer.swift")

print("▶️  list wiring")
check("MessageListItem has a toolGroup case", infra.contains("case toolGroup(UUID, UUID)"))
let blockSwitches = v3.components(separatedBy: "case .assistantBlock").count - 1
let groupMentions = v3.components(separatedBy: ".toolGroup").count - 1
check("V3 handles .toolGroup wherever it switches over list items (\(groupMentions) mentions for \(blockSwitches) block cases)",
      groupMentions >= 10)
check("the group row's content key carries its expanded state",
      v3.contains("\"g:\\(mid.uuidString):\\(first.uuidString):")
      && v3.contains(":\\(expanded ? 1 : 0)\""))
check("both content-key sites (configureCell seed, snapshot seed loop) use itemContentKey",
      v3.components(separatedBy: "= itemContentKey(for: item, messages: messages)").count - 1 == 2)
func body(of fn: String) -> String {
    guard let r = v3.range(of: fn),
          let end = v3.range(of: "\n        }\n", range: r.upperBound..<v3.endIndex) else { return "" }
    return String(v3[r.lowerBound..<end.lowerBound])
}
func ordered(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for p in parts {
        guard let r = text.range(of: p, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
let toggle = body(of: "func toggleToolGroup(firstBlockId: UUID) {")
check("toggle follows the full invalidation: clearCachedHeight -> invalidateHeight -> reconfigure -> apply -> invalidateLayout",
      ordered(toggle, ["applySnapshot(messages: vm.messages, caller: \"toolGroupToggle\")",
                       ".clearCachedHeight()", "layout.invalidateHeight(at: idx)",
                       "snap.reconfigureItems([item])", "ds.apply(snap, animatingDifferences: false)",
                       "layout.invalidateLayout()"]))
check("toggle keeps the row where it was on screen",
      ordered(toggle, ["let anchorY =", "scrollMode = .userBrowsing", "newMinY - anchorY"]))
let plan = body(of: "func planToolFolds(messages: [ChatMessage])")
check("a first fold is held back through ToolFoldPlanner.holdsBack, rows looked up lazily [T-fold-browse-hold]",
      plan.contains("if ToolFoldPlanner.holdsBack(browsing: browsing,")
      && plan.contains("shownAsRows: { isShownUnfolded(message.id, run.firstBlockId) }) {")
      && plan.contains("if shownRows == nil { shownRows = Set(previousSnapshotIds) }"))
check("the plan runs before the snapshot ids are replaced (it compares with the rows on screen)",
      ordered(v3, ["let toolFolds = planToolFolds(messages: messages)", "previousSnapshotIds = newItems"]))
check("re-plan triggers: request end, turn end, back to bottom — no longer a filled text block [T-fold-at-request-end]",
      v3.contains("caller: \"toolFold-requestEnd\"") && v3.contains("caller: \"toolFold-turnEnd\"")
      && v3.contains("caller: \"toolFold-backToBottom\"") && !v3.contains("toolFold-textFilled"))
check("the request-end trigger is the vm's separator signal",
      ordered(v3, ["vm.toolFoldSeparatorSignal", "resnapshotIfToolFoldsChanged(caller: \"toolFold-requestEnd\")"]))
check("only the loop's running message is planned up to its fold horizon; every other message whole",
      plan.contains("let isRunning = message.id == runningId")
      && plan.contains("let runningId = vm.toolFoldRunningMessageId")
      // [T-share-fold-tools] The horizon rule moved into ToolFoldPlanner,
      // shared with the share export.
      && plan.contains("let horizon = ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningId,")
      && plan.contains("separators: vm.toolFoldSeparators)")
      && plannerSrc.contains("guard message.id == runningMessageId else { return message.blocks.count }")
      && plannerSrc.contains("return foldHorizon(blockIds: message.blocks.map(\\.id), separators: separators[message.id] ?? [])")
      // [T-fold-stopped-tools] The horizon is where planning STOPS, not where
      // the task does: `ended` comes from the running message alone.
      && plan.contains("let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)),")
      && plan.contains("ended: !isRunning)"))
check("the planner takes the task's end as its own input, defaulting to \"not ended\" [T-fold-stopped-tools]",
      plannerSrc.contains("static func plan(_ blocks: [Input], enabled: Bool, ended: Bool = false) -> [Group] {")
      && plannerSrc.contains("static func foldedRuns(in blocks: [AssistantBlock], ended: Bool) -> [FoldedRun] {")
      && plannerSrc.contains("if ended, let s = start, tools >= minimumToolCount {")
      && plannerSrc.contains("[T-fold-stopped-tools]"))
check("the share export passes the same two inputs (horizon + task end)",
      read("Views/Chat/ChatExportRenderer.swift")
        .contains("ended: m.id != runningMessageId)"))
check("the list re-plans on the vm's turn-ended signal, not only on the isProcessing edge",
      v3.contains("caller: \"toolFold-turnEnded\"") && v3.contains("vm.toolFoldTurnEndedSignal"))
let vmSrc = chatViewModelSource()
check("the vm marks a request end once per request, after its stream result is final",
      ordered(vmSrc, ["let foldRequestStartBlockIds = Set(messages[msgIdx].blocks.map(\\.id))",
                      "let stopReason = streamResult.stopReason",
                      "noteToolFoldRequestEnded(messageId: runMsgId, startBlockIds: foldRequestStartBlockIds)"])
      && vmSrc.components(separatedBy: "noteToolFoldRequestEnded(messageId: runMsgId").count - 1 == 1)
check("the running message is set at a request start and cleared when the loop starts and ends",
      ordered(vmSrc, ["toolFoldRunningMessageId = nil\n        toolFoldSeparators.removeAll()\n        defer {\n            toolFoldRunningMessageId = nil"])
      && ordered(vmSrc, ["let foldRequestStartBlockIds", "noteToolFoldRequestStarting(messageId: runMsgId)"]))
check("a resumed/retried message's existing content counts as finished (its last block is a separator)",
      vmSrc.contains("if let last = messages.first(where: { $0.id == messageId })?.blocks.last {\n            toolFoldSeparators[messageId, default: []].insert(last.id)"))
check("the separator decision uses the request's whole text and the shared rule",
      vmSrc.contains(".filter { !startBlockIds.contains($0.id) && $0.kind == .text }")
      && vmSrc.contains("guard ToolFoldPlanner.isFoldSeparator(requestText: text) else { return }"))
check("re-plan only applies when the plan changed",
      body(of: "func resnapshotIfToolFoldsChanged(caller: String) {").contains("guard planned.runs != toolFoldRunsByMessage else {"))
check("the list plans from inputs(for:), so remarks become notes [T-fold-tool-notes]",
      plannerSrc.contains("plan(inputs(for: blocks), enabled: true, ended: ended).map { group in")
      && plannerSrc.contains("markingNotes(blocks.map(input(for:))) { isSingleLine(blocks[$0].content) }"))
check("the vm signals the turn's end twice where `isProcessing` cannot: loop unwound, stop cleaned up",
      vmSrc.contains("let toolFoldTurnEndedSignal = PassthroughSubject<Void, Never>()")
      && ordered(vmSrc, ["defer {\n            toolFoldRunningMessageId = nil\n            toolFoldSeparators.removeAll()",
                         "toolFoldTurnEndedSignal.send()"])
      && vmSrc.contains("let wasStopped = userDidCancel\n        defer { if wasStopped { toolFoldTurnEndedSignal.send() } }"))
check("a run that changed under the same row is reconfigured (skip path and full apply)",
      v3.contains("guard let old = previousFoldRuns[first], old != run else { return nil }")
      && v3.contains("snap.reconfigureItems(changedToolGroupItems.filter { snap.indexOfItem($0) != nil })")
      && v3.contains("if !regroupedRows.isEmpty { snapshot.reconfigureItems(regroupedRows) }"))
check("the fold key is the first TOOL's id, not a leading thinking block's [T-fold-lead-thinking]",
      plannerSrc.contains("let firstTool = members.first { $0.toolUseId != nil } ?? members[members.startIndex]")
      && plannerSrc.contains("return FoldedRun(key: firstTool.toolUseId ?? firstTool.id.uuidString,"))
check("the run sums its members' execution time [T-fold-tool-duration]",
      plannerSrc.contains("let durations = members.compactMap(\\.toolDuration)")
      && plannerSrc.contains("duration: durations.isEmpty ? nil : durations.reduce(0, +))")
      && plan.contains("duration: run.duration))"))
let row: String = {
    guard let r = blockView.range(of: "struct ToolGroupRowView: View {"),
          let end = blockView.range(of: "\n}\n", range: r.upperBound..<blockView.endIndex) else { return "" }
    return String(blockView[r.lowerBound..<end.lowerBound])
}()
check("the row shows the total time after the title, in the capsule's format",
      row.contains("Text(verbatim: durationText).monospacedDigit()")
      && row.contains("if dur < 1 { return String(format: \"%.1fs\", dur) }")
      && row.contains("if let durationText { parts.append(durationText) }"))
check("the setting is read with a default of OFF",
      plannerSrc.contains("(UserDefaults.standard.object(forKey: settingsKey) as? Bool) ?? false")
      && plannerSrc.contains("static let settingsKey = \"chat.foldConsecutiveTools\""))

print("▶️  settings")
check("Appearance has the toggle, default off",
      content.contains("@AppStorage(\"chat.foldConsecutiveTools\") private var foldConsecutiveTools: Bool = false"))
check("the toggle re-lays the open chat out",
      content.contains("NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)"))
check("ConfigRegistry registers it, default false",
      registry.contains("path: \"chat.foldTools\"") && registry.contains("userDefaultsKey: \"chat.foldConsecutiveTools\",\n            defaultValue: false"))

print("▶️  a thinking run is drawn as thinking [T-fold-all-process]")
check("the row title switches on the run's kind: 'Thinking process' when it has no call",
      row.contains("private var isThinkingOnly: Bool { toolCount == 0 }")
      && row.contains("isThinkingOnly ? AppLocalized(\"Thinking process\") : AppLocalized(\"Ran \\(toolCount) tools\")"))
check("it can never print a tool count of zero — there is no other title",
      row.components(separatedBy: "AppLocalized(\"Ran ").count - 1 == 1 && !row.contains("Ran 0"))
check("no invented time on a thinking run: a thinking block records none",
      row.contains("private var durationText: String? { isThinkingOnly ? nil : duration.map(Self.durationText) }"))
check("accessibility says what the row holds, and keeps working for thinking",
      row.contains("return isExpanded ? AppLocalized(\"Hide Thinking\") : AppLocalized(\"Show Thinking\")")
      && row.contains(".accessibilityLabel(accessibilityText)")
      && row.contains(".accessibilityAddTraits(.isButton)"))
check("expanding still inserts the ORIGINAL blocks, so each thinking block keeps its own chevron",
      v3.contains("newItems.append(contentsOf: run.memberIds.map { .assistantBlock(message.id, $0) })"))
check("the memory tool is a foldable call, not a barrier (the memory_write screenshot)",
      plannerSrc.contains(".browserTool, .readImageTool, .memoryTool:")
      && plannerSrc.contains("case .success: return .tool(.succeeded)"))
check("the share picker hides a thinking run under Hide Thinking, next to the thinking blocks",
      shareView.contains("return cell.kind == .toolGroup && (cell.fold?.toolCount ?? 0) == 0"))
check("the export follows the same split: tool runs with the tools, thinking runs with the thinking",
      exportRenderer.contains("return (cell.fold?.toolCount ?? 0) > 0 ? includeTools : includeThinking"))

print("▶️  localization")
let keys = ["Fold Consecutive Tool Calls", "Tool Calls",
            "Consecutive tool calls are shown as one line. Tap it to see each call.",
            "Ran %lld tools", "%lld failed", "%lld cancelled", "Shows each tool call", "Hides the tool calls"]
let locales = ["de", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
for k in keys {
    guard let r = catalog.range(of: "\n    \"\(k)\" : {") else { check("xcstrings has \"\(k)\"", false); continue }
    let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
    let entry = catalog[r.upperBound..<next]
    let missing = locales.filter { !entry.contains("\"\($0)\" : {") }
    check("xcstrings \"\(k)\" has all 18 locales\(missing.isEmpty ? "" : " — missing \(missing)")", missing.isEmpty)
}
for k in ["Thinking process", "Ran 1 tool"] {
    check("xcstrings has \"\(k)\"", catalog.contains("\n    \"\(k)\" : {") || catalog.contains("\"value\" : \"\(k)\""))
}
check("\"Thinking process\" is 思考过程 in both Chinese variants",
      catalog.range(of: "\n    \"Thinking process\" : {").map { r in
          let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
          let entry = catalog[r.upperBound..<next]
          return entry.contains("\"value\" : \"思考过程\"") && entry.contains("\"value\" : \"思考過程\"")
      } ?? false)
check("English counts one call in the singular (plural variation on the existing key)",
      catalog.contains("\"one\" : {") && catalog.contains("\"value\" : \"Ran 1 tool\"")
      && blockView.contains("AppLocalized(\"Ran \\(toolCount) tools\")"))
check("the switch description never says 'default'",
      !keys[2].lowercased().contains("default"))
check("the group row uses the localized strings",
      blockView.contains("AppLocalized(\"Ran \\(toolCount) tools\")")
      && blockView.contains("AppLocalized(\"\\(failedCount) failed\")")
      && blockView.contains("AppLocalized(\"\\(cancelledCount) cancelled\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
