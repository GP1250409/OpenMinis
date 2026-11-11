//
//  ToolFoldPlanner.swift
//  MinisApp
//
//  [T-fold-consecutive-tools] Decides which runs of consecutive tool calls in
//  one assistant message the message list folds into a single "Ran N tools"
//  row. Pure: it sees only a compact description of each block, so the rule
//  is unit-tested without the list (MinisTests/Standalone/ToolFoldPlannerTests).
//

import Foundation

/// Folding rule for consecutive tool calls (Settings → Appearance → Tool Calls).
///
/// A run starts at the first tool block and continues through
/// - more finished tool blocks (counted),
/// - thinking blocks (folded along, not counted — interleaved-thinking models
///   alternate thinking/tool and would otherwise never reach the threshold),
/// - empty text blocks (a text block that has not received content yet).
///
/// - one-line remarks between tool calls (`note`, see `markingNotes`): folded
///   along, not counted. [T-fold-tool-notes]
///
/// It ends at a non-empty text block, an info block, a delegate block, or a
/// tool that has not finished (streaming / running / awaiting confirmation).
///
/// A run of at least `minimumToolCount` tools folds in two cases:
/// - a NON-EMPTY text block closes it — the reply it produced;
/// - [T-fold-stopped-tools] the task that wrote the blocks is over (`ended`)
///   and every tool of the run finished: a user stop, a failed turn or an
///   end with no reply at all would otherwise leave the capsules expanded for
///   good. Mid-task that shape is exactly the pause before the next calls
///   run, so `ended == false` folds nothing there.
///
/// A fold covers the run from its first block — the lead thinking, when there
/// is one — through its last block: the last tool or note, or the thinking
/// that trails it into the reply (or into the end of a stopped turn).
///
/// [T-fold-lead-thinking] Thinking right before the run's first tool (only
/// empty text may sit between them) folds with the run too — it is the
/// reasoning that led to those calls, and left outside it hung alone above
/// the folded row. [T-fold-trailing-thinking] Thinking after the last member
/// folds as well, once a reply closes the run or the task ends; while that
/// thinking is still being written it stays outside, so the pill never
/// vanishes before the reply it leads into.
///
/// WHEN a message is planned (during its task: at qualifying request ends,
/// over the part before them; after it: all of it) is a separate rule, see
/// `foldHorizon`. [T-fold-at-request-end] Note that the end of the planned
/// PREFIX is not the end of the task: `ended` is, and only `ended` lets a
/// run fold without a reply.
///
/// A note is also a soft end: when the run is then cut by an unfinished tool,
/// a barrier or the end of the message, the part up to its latest note still
/// folds. Without it a live run would open again the moment the model
/// followed a remark with another call (the remark turns into a note right
/// then), and close again once that call finished.
enum ToolFoldPlanner {
    /// The minimum number of tool blocks in a run before it folds.
    /// [T-fold-tools-min2] 2, lowered from 3 at the user's request: a pair
    /// of calls before a reply is already enough to crowd the conversation.
    static let minimumToolCount = 2

    enum ToolOutcome: Equatable {
        case unfinished
        case succeeded
        case failed
        case cancelled
    }

    /// What the planner needs to know about one block.
    enum Input: Equatable {
        /// A foldable tool call (shell, file, browser, image, memory).
        case tool(ToolOutcome)
        case thinking
        /// A text block; `isEmpty` is true while it has no visible content.
        case text(isEmpty: Bool)
        /// [T-fold-tool-notes] A one-line text with a tool call after it — a
        /// remark between calls, not the reply. See `markingNotes`.
        case note
        /// Always visible and ends a run: info rows and sub agent delegations.
        case barrier
    }

    struct Group: Equatable {
        /// Indices of the folded blocks, first tool through last tool.
        let range: ClosedRange<Int>
        let toolCount: Int
        let failedCount: Int
        let cancelledCount: Int
    }

    /// - Parameters:
    ///   - blocks: the message's blocks, in order (see `Input`).
    ///   - enabled: the user setting.
    ///   - ended: [T-fold-stopped-tools] whether the task that wrote these
    ///     blocks is OVER — a finished turn, a stopped/cancelled or failed
    ///     one, or history read back from disk. Only then may a run with no
    ///     reply after it fold. A message the agent loop is still writing
    ///     into is planned with `ended: false` even when the planned prefix
    ///     happens to end on a tool: the prefix ends at the latest finished
    ///     request, the task does not, and those calls are about to run.
    ///     Defaults to false — the safe direction: a forgotten argument
    ///     leaves a run open, it never folds one early.
    static func plan(_ blocks: [Input], enabled: Bool, ended: Bool = false) -> [Group] {
        guard enabled else { return [] }
        var groups: [Group] = []
        var start: Int?
        /// First thinking block of the unbroken thinking / empty-text stretch
        /// just before the current position, while no run is open.
        var leadThinking: Int?
        var lastMember = 0
        var tools = 0, failed = 0, cancelled = 0
        /// The run as it stood at its latest note (the soft end).
        var softEnd: Group?
        /// [T-fold-trailing-thinking] Last thinking block of the stretch that
        /// follows the run's latest member, while no tool, note or barrier has
        /// come after it: it folds when the reply closes the run.
        var trailingThinking: Int?

        func reset() {
            start = nil
            tools = 0; failed = 0; cancelled = 0
            softEnd = nil
            trailingThinking = nil
        }
        /// The run's last folded block: its last member, or the thinking that
        /// trails it when that thinking leads into the reply.
        func lastBlock() -> Int { max(lastMember, trailingThinking ?? lastMember) }
        /// The run was cut without a reply: fold what came before its latest
        /// note, if that much qualifies on its own.
        func closeAtSoftEnd() {
            if let g = softEnd, g.toolCount >= minimumToolCount { groups.append(g) }
        }

        for (i, block) in blocks.enumerated() {
            switch block {
            case .tool(.unfinished), .barrier:
                closeAtSoftEnd()
                reset()
                leadThinking = nil
            case .tool(let outcome):
                if start == nil { start = leadThinking ?? i }
                leadThinking = nil
                lastMember = i
                tools += 1
                if outcome == .failed { failed += 1 }
                if outcome == .cancelled { cancelled += 1 }
            case .note:
                // Only after a tool: a remark before the first call is not
                // part of any run and stays visible — and it separates any
                // thinking before it from the call after it.
                guard let s = start else { leadThinking = nil; continue }
                lastMember = i
                trailingThinking = nil
                softEnd = Group(range: s...i, toolCount: tools,
                                failedCount: failed, cancelledCount: cancelled)
            case .thinking:
                if start == nil {
                    if leadThinking == nil { leadThinking = i }
                } else {
                    // [T-fold-trailing-thinking] Only the latest counts: the
                    // stretch has no tool, note or barrier in it by now.
                    trailingThinking = i
                }
            case .text(isEmpty: true):
                continue
            case .text(isEmpty: false):
                if let s = start, tools >= minimumToolCount {
                    groups.append(Group(range: s...lastBlock(), toolCount: tools,
                                        failedCount: failed, cancelledCount: cancelled))
                }
                reset()
                leadThinking = nil
            }
        }
        // [T-fold-stopped-tools] The task is over and the message ends on a
        // run with no reply after it (a user stop, a failed turn, a reply-less
        // end): fold the whole run — cancelled and failed calls included, plus
        // the thinking before, between and after them. A tool that never
        // finished closed the run above, so a call that is still running (or
        // still waiting for its confirmation) keeps its capsules visible even
        // here. While the task runs, this shape is the pause before the next
        // calls: only the part up to the latest note folds then.
        if ended, let s = start, tools >= minimumToolCount {
            groups.append(Group(range: s...lastBlock(), toolCount: tools,
                                failedCount: failed, cancelledCount: cancelled))
        } else {
            // A run still open here has no reply after it: only its part up to
            // the latest note folds; the rest stays unfolded.
            closeAtSoftEnd()
        }
        return groups
    }

    /// [T-fold-tool-notes] Marks the one-line remarks a model writes between
    /// tool calls ("Now let me check the logs.") as `.note`, so a run of calls
    /// folds with them instead of being cut into single-call pieces.
    ///
    /// A non-empty text is a note when `isSingleLine(index)` holds AND a tool
    /// call comes after it in the message. Everything after the message's
    /// last tool call is the reply — including every segment of a long reply,
    /// which a reload splits into several text blocks — and is never a note.
    /// Mid-turn, a remark is the reply until the model follows it with another
    /// call.
    static func markingNotes(_ inputs: [Input], isSingleLine: (Int) -> Bool) -> [Input] {
        guard let lastTool = inputs.lastIndex(where: { if case .tool = $0 { return true }; return false })
        else { return inputs }
        var out = inputs
        for i in 0..<lastTool where out[i] == .text(isEmpty: false) && isSingleLine(i) {
            out[i] = .note
        }
        return out
    }

    /// One line by line BREAKS, not by how it wraps on screen: no newline
    /// between its first and last visible character. Scans in place (no
    /// trimmed copy) and stops at the first inner newline.
    static func isSingleLine(_ text: String) -> Bool {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { return true }
        return !text[first...last].contains(where: \.isNewline)
    }

    // MARK: When a run folds [T-fold-at-request-end]
    //
    // Folding never happens while a reply streams or a tool runs. A message
    // whose task is still running folds only at the end of a request (one LLM
    // call) whose reply was long enough, and then only the part of the message
    // up to that request's last block — see `foldHorizon`. Once the task ends,
    // the whole message is planned with `plan(..., ended: true)`, whatever the
    // reply lengths and even with no reply at all ([T-fold-stopped-tools]).
    // History is always "ended". The horizon is where planning STOPS, not
    // where the task does.

    /// The fewest lines a request's reply needs for the end of that request to
    /// fold the tool runs before it. A shorter reply (a one-line remark between
    /// calls) leaves them open until the task ends.
    static let separatorMinimumLines = 2

    /// Lines by line BREAKS, not by on-screen wrapping, so the answer never
    /// depends on the width: lines with at least one visible character.
    static func nonEmptyLineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .filter { $0.contains(where: { !$0.isWhitespace }) }
            .count
    }

    /// Whether a request whose reply text (all its text blocks, joined) is
    /// `requestText` folds the runs before it when it ends. The whole
    /// request's text counts, not just its last text block: one rule for every
    /// shape a request can take (text only, text then calls, text between
    /// parallel calls). Stops scanning at the threshold.
    static func isFoldSeparator(requestText: String) -> Bool {
        var lines = 0
        for line in requestText.split(whereSeparator: \.isNewline)
        where line.contains(where: { !$0.isWhitespace }) {
            lines += 1
            if lines >= separatorMinimumLines { return true }
        }
        return false
    }

    /// For a message whose task is still running: how many of its leading
    /// blocks may be planned. That is through the last block of the latest
    /// request that ended with a long-enough reply (`separators` holds those
    /// requests' last block ids); 0 before the first one. Ids no longer in the
    /// message (a retried round rolled back) are ignored.
    static func foldHorizon<ID: Hashable>(blockIds: [ID], separators: Set<ID>) -> Int {
        guard !separators.isEmpty,
              let last = blockIds.lastIndex(where: { separators.contains($0) }) else { return 0 }
        return last + 1
    }

    /// [T-fold-browse-hold] Whether a run that is due to fold is held back
    /// for now because folding it would move what the user is reading: only
    /// while they are scrolled up (`browsing`), never for a run already folded
    /// once (it stays folded), and only when it belongs to the running message
    /// or its blocks are on the list as separate rows right now. A session
    /// just opened has never shown them, so it folds at once. `shownAsRows` is
    /// only called when the cheaper conditions leave the answer open.
    static func holdsBack(browsing: Bool, alreadyFolded: Bool, inRunningMessage: Bool,
                          shownAsRows: () -> Bool) -> Bool {
        guard browsing, !alreadyFolded else { return false }
        return inRunningMessage || shownAsRows()
    }
}
// END ToolFoldPlanner

extension ToolFoldPlanner {
    /// [T-fold-tool-notes] The planner's view of one message's blocks, with
    /// the one-line remarks between tool calls marked as notes.
    static func inputs(for blocks: [AssistantBlock]) -> [Input] {
        markingNotes(blocks.map(input(for:))) { isSingleLine(blocks[$0].content) }
    }

    /// The planner's view of a live block.
    static func input(for block: AssistantBlock) -> Input {
        switch block.kind {
        case .text:
            // Stops at the first visible character: this runs for every text
            // block on every snapshot, so it must not copy or scan the reply.
            return .text(isEmpty: !block.content.contains(where: { !$0.isWhitespace }))
        case .thinking:
            return .thinking
        case .info, .delegateTool, .userAskTool, .genuiTool:  // [T-user-ask] never folded
            return .barrier
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool:
            switch block.toolStatus {
            case .success: return .tool(.succeeded)
            case .failed: return .tool(.failed)
            case .cancelled: return .tool(.cancelled)
            case .streaming, .running, .none: return .tool(.unfinished)
            }
        }
    }

    /// [T-share-fold-tools] One folded run as every surface draws it: the
    /// message list's "Ran N tools · 9s" row and the share picker / export.
    struct FoldedRun: Equatable {
        /// Expanded-state key: the first TOOL's provider `toolUseId`, which
        /// survives a session reload (block ids are regenerated on every
        /// load); its block id when there is none. [T-fold-lead-thinking]
        /// The first TOOL, not the first block: the run may open on a
        /// thinking block, which has neither.
        let key: String
        /// The first folded block (a thinking block when lead thinking folds).
        let firstBlockId: UUID
        /// Every folded block, in order.
        let memberIds: [UUID]
        let group: Group
        /// [T-fold-tool-duration] Summed execution time of the folded tool
        /// calls; nil when none of them recorded one.
        let duration: TimeInterval?
    }

    /// [T-share-fold-tools] The runs `blocks` fold into (`plan` over
    /// `inputs(for:)`), with what drawing them needs. Shared by the message
    /// list and the share export so a shared image folds exactly like the chat.
    /// - Parameter ended: [T-fold-stopped-tools] whether the task that wrote
    ///   these blocks is over — the same value `plan` takes: true for a
    ///   finished or stopped turn and for history, false for the message the
    ///   agent loop is still writing into. Explicit on purpose: a prefix cut
    ///   at the fold horizon is not the end of the task.
    static func foldedRuns(in blocks: [AssistantBlock], ended: Bool) -> [FoldedRun] {
        plan(inputs(for: blocks), enabled: true, ended: ended).map { group in
            let members = blocks[group.range]
            let firstTool = members.first { $0.toolUseId != nil } ?? members[members.startIndex]
            let durations = members.compactMap(\.toolDuration)
            return FoldedRun(key: firstTool.toolUseId ?? firstTool.id.uuidString,
                             firstBlockId: members[members.startIndex].id,
                             memberIds: members.map(\.id),
                             group: group,
                             duration: durations.isEmpty ? nil : durations.reduce(0, +))
        }
    }

    /// [T-fold-at-request-end] How many of `message`'s leading blocks may be
    /// planned now: all of them, unless it is the message the running loop is
    /// writing into — then only through its latest fold separator.
    @MainActor
    static func foldHorizon(for message: ChatMessage, runningMessageId: UUID?,
                            separators: [UUID: Set<UUID>]) -> Int {
        guard message.id == runningMessageId else { return message.blocks.count }
        return foldHorizon(blockIds: message.blocks.map(\.id), separators: separators[message.id] ?? [])
    }

    /// Settings key for the feature. Off unless the user turns it on.
    static let settingsKey = "chat.foldConsecutiveTools"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: settingsKey) as? Bool) ?? false
    }
}
