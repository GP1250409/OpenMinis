import Foundation

// Only model storage is stubbed. Compile the entire production planner and
// adapters verbatim, including input(for:), foldedRuns and history horizons.
struct AssistantBlock {
    enum Kind { case text, thinking, info, delegateTool, userAskTool, genuiTool, shellTool, fileReadTool, fileWriteTool, fileEditTool, browserTool, readImageTool, memoryTool }
    enum Status: CaseIterable { case success, failed, cancelled, streaming, running }
    var id = UUID()
    var kind: Kind
    var toolStatus: Status? = nil
    var content = ""
    var thinkingContentBuffer = ""
    var toolUseId: String? = nil
    var toolDuration: TimeInterval? = nil
}
struct ChatMessage { var id = UUID(); var blocks: [AssistantBlock] }
var checks = 0
func check(_ ok: Bool, _ label: String) {
    checks += 1
    if !ok { print("FAIL: \(label)"); exit(1) }
}
func think(_ count: Int) -> AssistantBlock { AssistantBlock(kind: .thinking, content: String(repeating: "思", count: count)) }
func tool(_ kind: AssistantBlock.Kind, _ status: AssistantBlock.Status?) -> AssistantBlock {
    AssistantBlock(kind: kind, toolStatus: status, toolUseId: UUID().uuidString, toolDuration: 1)
}
@MainActor func runAdapters() {
    for status in AssistantBlock.Status.allCases.map(Optional.some) + [nil] {
        let ui = tool(.genuiTool, status)
        let actual = ToolFoldPlanner.input(for: ui)
        switch status {
        case .success: check(actual == .card, "success card")
        case .failed: check(actual == .tool(.failed), "failed settled tool")
        case .cancelled: check(actual == .tool(.cancelled), "cancelled settled tool")
        default: check(actual == .barrier, "unfinished barrier")
        }
        check(ToolFoldPlanner.input(for: tool(.userAskTool, status)) == .card, "user ask unchanged")
    }
    var blocks = [think(907)]
    for i in 0..<32 { blocks.append(tool(.shellTool, .success)); if i % 8 == 0 { blocks.append(think(351)) } }
    blocks += [tool(.genuiTool, .failed), think(260), tool(.genuiTool, .failed), think(64)]
    let cardIndex = blocks.count
    blocks += [tool(.genuiTool, .success), think(99), AssistantBlock(kind: .text, content: "最终正文\n保留可见")]
    let runs = ToolFoldPlanner.foldedRuns(in: blocks, ended: true)
    check(runs.count == 2, "full process plus final thinking")
    check(runs[0].group.toolCount == 34 && runs[0].group.failedCount == 2, "32 ordinary plus two failed UI")
    check(runs[0].group.range == 0...(cardIndex - 1), "entire leading process folded")
    let hidden = Set(runs.flatMap(\.memberIds))
    check(!hidden.contains(blocks[cardIndex].id) && !hidden.contains(blocks.last!.id), "success UI and reply visible")
    check(hidden.count == blocks.count - 2, "no leftover thinking or calls")
    check(runs[0].duration == 34, "failed calls retain durations")
    var history = ChatMessage(blocks: blocks)
    let horizon = ToolFoldPlanner.foldHorizon(for: history, runningMessageId: nil, separators: [:])
    check(horizon == blocks.count, "history horizon includes all")
    check(ToolFoldPlanner.foldedRuns(in: Array(history.blocks.prefix(horizon)), ended: true) == runs, "history and share use same runs")
    history.blocks = blocks.map { b in var copy = b; copy.id = UUID(); return copy }
    let reloaded = ToolFoldPlanner.foldedRuns(in: history.blocks, ended: true)
    check(reloaded[0].key == runs[0].key, "history stable tool key")
    check(reloaded[1].key == history.blocks[cardIndex + 1].id.uuidString, "thinking-only history key follows regenerated block")
    for status in [AssistantBlock.Status.cancelled, .running, .streaming] {
        let sample = [think(907), tool(.shellTool, .success), tool(.genuiTool, status), think(260), tool(.genuiTool, .success)]
        let plan = ToolFoldPlanner.foldedRuns(in: sample, ended: true)
        if status == .cancelled {
            check(plan.count == 1 && plan[0].group.cancelledCount == 1 && plan[0].group.toolCount == 2, "cancelled retained")
        } else {
            check(!plan.contains { $0.memberIds.contains(sample[0].id) || $0.memberIds.contains(sample[2].id) }, "unfinished blocks prior run")
        }
    }
    let live = ChatMessage(blocks: [think(907), tool(.shellTool, .success), tool(.genuiTool, .running)])
    check(ToolFoldPlanner.foldHorizon(for: live, runningMessageId: live.id, separators: [:]) == 0, "live running no early fold")
    print("TOOLFOLD_ADAPTER_PASS checks=\(checks)")
}
MainActor.assumeIsolated { runAdapters() }
