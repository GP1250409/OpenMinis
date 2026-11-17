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
            check(!plan.contains { $0.memberIds.contains(sample[0].id) || $0.memberIds.contains(sample[2].id) }, "unfinished show_ui blocks prior run as barrier")
        }
    }
    var live = ChatMessage(blocks: [think(907), tool(.shellTool, .running)])
    let hLive = ToolFoldPlanner.foldHorizon(for: live, runningMessageId: live.id, separators: [:])
    check(hLive == live.blocks.count, "live running folds immediately from first block")
    let liveThinkRun = ToolFoldPlanner.foldedRuns(in: [live.blocks[0]], ended: false)
    let liveWithTool = ToolFoldPlanner.foldedRuns(in: Array(live.blocks.prefix(hLive)), ended: false)
    check(liveThinkRun.count == 1 && liveThinkRun[0].group.isLive, "thinking-only live run folds")
    check(liveWithTool.count == 1 && liveWithTool[0].group.runningCount == 1 && liveWithTool[0].group.completedCount == 0 && liveWithTool[0].group.isLive, "live running tool counted")
    check(liveWithTool[0].matchKeys.contains(liveThinkRun[0].key), "live group preserves fallback key for manual expansion")
    live.blocks.append(tool(.genuiTool, .success))
    let liveAfterCard = ToolFoldPlanner.foldedRuns(in: live.blocks, ended: false)
    check(liveAfterCard.count == 1 && !liveAfterCard[0].memberIds.contains(live.blocks[2].id), "successful show_ui card stays outside live group")
    // [T-fold-two-switches] The two independent switches, through the shipped
    // adapters. `closed` is a run a reply closed; `grow` is the run still
    // growing at the tail; `note` a remark that soft-ends the run.
    let closed = [think(120), tool(.shellTool, .success), tool(.shellTool, .success),
                  AssistantBlock(kind: .text, content: "结论第一行\n结论第二行")]
    let grow = [think(120), tool(.shellTool, .success), tool(.shellTool, .running)]
    let stop = [think(120), tool(.shellTool, .success), tool(.shellTool, .success)]
    let offOff = ToolFoldPlanner.foldedRuns(in: closed, ended: true, liveFolding: false, endFolding: false)
    check(offOff.isEmpty, "both switches off: nothing folds, ever")
    let closedOffOn = ToolFoldPlanner.foldedRuns(in: closed, ended: true, liveFolding: false, endFolding: true)
    check(closedOffOn.count == 1 && closedOffOn[0].group.range == 0...2 && !closedOffOn[0].group.isLive,
          "only after-the-reply: the reply-closed run folds")
    let growOffOn = ToolFoldPlanner.foldedRuns(in: grow, ended: false, liveFolding: false, endFolding: true)
    check(growOffOn.isEmpty, "only after-the-reply: the growing run stays open while the tool runs")
    let growOnOn = ToolFoldPlanner.foldedRuns(in: grow, ended: false, liveFolding: true, endFolding: true)
    check(growOnOn.count == 1 && growOnOn[0].group.runningCount == 1 && growOnOn[0].group.isLive,
          "both switches: the growing run folds live with its running count")
    let growOnOff = ToolFoldPlanner.foldedRuns(in: grow, ended: false, liveFolding: true, endFolding: false)
    check(growOnOff.count == 1 && growOnOff[0].group.isLive,
          "only while-replying: the growing run folds")
    let closedOnOff = ToolFoldPlanner.foldedRuns(in: closed, ended: true, liveFolding: true, endFolding: false)
    check(closedOnOff.isEmpty, "only while-replying: a run its reply closed opens again — the requested end state")
    let stopOnOff = ToolFoldPlanner.foldedRuns(in: stop, ended: true, liveFolding: true, endFolding: false)
    check(stopOnOff.isEmpty, "only while-replying: a finished message without a reply has no fold row either")
    let stopOffOn = ToolFoldPlanner.foldedRuns(in: stop, ended: true, liveFolding: false, endFolding: true)
    check(stopOffOn.count == 1 && !stopOffOn[0].group.isLive, "only after-the-reply: a stopped turn folds its calls")
    // The manual close: the coordinator re-plans with `endFolding: true` to find
    // the runs it must keep for the user, so that plan has to contain exactly
    // this run.
    let manual = ToolFoldPlanner.foldedRuns(in: closed, ended: true, liveFolding: true, endFolding: true)
    check(manual.count == 1 && manual[0].matchKeys == closedOffOn[0].matchKeys,
          "the settled plan a manual close re-uses is keyed like the folded one")
    // Horizon: with live folding off a running message is planned exactly as
    // before live folding existed — only through its latest reply separator.
    var horizonMsg = ChatMessage(blocks: closed + [think(80)])
    let separatorId = closed[3].id
    let hAll = ToolFoldPlanner.foldHorizon(for: horizonMsg, runningMessageId: horizonMsg.id,
                                           separators: [horizonMsg.id: [separatorId]])
    let hSettled = ToolFoldPlanner.foldHorizon(for: horizonMsg, runningMessageId: horizonMsg.id,
                                               separators: [horizonMsg.id: [separatorId]],
                                               liveFolding: false)
    check(hAll == horizonMsg.blocks.count && hSettled == 4,
          "live folding plans every block, after-the-reply only through the last separator")
    // Browse hold: the running message is held back again without live folding.
    check(ToolFoldPlanner.holdsBack(browsing: true, alreadyFolded: false, inRunningMessage: true,
                                    liveFolding: false, shownAsRows: { false }),
          "without live folding a browsing reader holds the running message back")
    check(!ToolFoldPlanner.holdsBack(browsing: true, alreadyFolded: false, inRunningMessage: true,
                                     liveFolding: true, shownAsRows: { true }),
          "live folding never holds the running message back")
    print("TOOLFOLD_ADAPTER_PASS checks=\(checks)")
}
MainActor.assumeIsolated { runAdapters() }
