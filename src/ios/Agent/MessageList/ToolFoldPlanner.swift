//
//  ToolFoldPlanner.swift
//  MinisApp
//
//  [T-fold-consecutive-tools] Decides which runs of consecutive tool calls in
//  one assistant message the message list folds into a single "Ran N tools"
//  row. Pure: it sees only a compact description of each block, so the rule
//  is unit-tested without the list (MinisTests/Standalone/ToolFoldPlannerTests).
//
//  [T-fold-all-process] A run is the PROCESS of a request, not just its calls:
//  thinking on its own folds the same way, as one "Thinking process" row.
//

import Foundation

/// Folding rule for one request's process (Settings → Appearance → Tool Calls).
///
/// [T-fold-all-process] A run is one continuous stretch of PROCESS: tool calls
/// and the thinking around them. It starts at
/// - the first finished tool block, or
/// - [T-fold-all-process] the first thinking block when no call has come yet —
///   thinking alone is process too, and a reply that follows it folds it into
///   one "Thinking process" row instead of leaving every pill expanded.
///
/// and continues through
/// - more finished tool blocks (counted),
/// - thinking blocks (members; a run of thinking only has `toolCount == 0`),
/// - empty text blocks (a text block that has not received content yet),
/// - one-line remarks between tool calls (`note`, see `markingNotes`): folded
///   along, not counted. [T-fold-tool-notes] [T-fold-lead-gap] A remark before
///   the FIRST call always keeps its own row, but it is not a barrier: when the
///   run opened on thinking, that thinking still folds with the calls below the
///   remark, and the remark becomes a GAP inside the group — visible, still in
///   order, its neighbours folded around it. This is the boundary the device
///   screenshot showed: "Deep Thinking 3K" on its own above "Ran 14 tools".
///   A remark with nothing folded before it (`o TTt`) behaves exactly as before.
///   A MULTI-line text is never a note, so a real paragraph between the
///   thinking and the calls still cuts the run in two.
///
/// It ends at a non-empty text block, [T-fold-card-boundary] an interactive
/// card for the user (a question, a generated UI), an info block, a delegate
/// block, or a tool that has not finished (streaming / running / awaiting
/// confirmation).
///
/// [T-fold-card-boundary] A CARD closes the run before it instead of dropping
/// it: the card is a boundary the model drew on purpose — it asked, or handed
/// over a form, and the request is over — while the calls and thinking before
/// it are a finished process that has to read as one row. The card itself is
/// never a member and is never hidden (it may still be waiting for an answer),
/// and the thinking between two cards is a run of its own, so the shape is
/// "process · card · thinking · card · thinking · reply". Info rows and
/// sub-agent delegations stay plain barriers: they are process, not a handover,
/// and keep cutting a run without folding it.
///
/// [T-fold-blank-thinking] A thinking block with nothing visible in it is
/// transparent, exactly like an empty text block: it never opens, joins or
/// closes a run, and the list gives it no row of its own once it cannot grow
/// any more (`isBlankThinking` is the one test every surface uses).
///
/// A run folds when it has at least `minimumToolCount` tools — or, with no tool
/// at all, at least `minimumThinkingCount` thinking blocks — and one of:
/// - a NON-EMPTY text block closes it — the reply it produced;
/// - [T-fold-stopped-tools] the task that wrote the blocks is over (`ended`)
///   and every tool of the run finished: a user stop, a failed turn or an
///   end with no reply at all would otherwise leave the capsules expanded for
///   good. Mid-task that shape is exactly the pause before the next calls
///   run, so `ended == false` folds nothing there.
///
/// A fold covers the run from its first block — the lead thinking, when there
/// is one — through its last block: the last tool or note, or the thinking
/// that trails it into the reply (or into the end of a stopped turn). Text is
/// NEVER a member: the reply (and every further segment of it) stays outside,
/// however many blocks it was loaded as.
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
    /// [T-fold-all-process] 1: a single call between two replies is process
    /// too, and the user asked for one row per process whatever its size.
    /// (Was 2 with [T-fold-tools-min2].)
    static let minimumToolCount = 1

    /// [T-fold-all-process] The minimum number of thinking blocks in a run
    /// with NO tool call at all. 1 — one thought is a process. A run that
    /// reaches neither minimum (only empty text) is not a run and never folds.
    static let minimumThinkingCount = 1

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
        /// [T-fold-lead-gap] Before the first call it stays visible and becomes
        /// a gap in the group it sits in, never a member.
        case note
        /// [T-fold-card-boundary] A card for the user (a question, a generated
        /// UI). Always visible, never a member, and it CLOSES the run before
        /// it like a reply does — the process up to the card is over.
        case card
        /// Always visible and ends a run WITHOUT folding it: info rows and sub
        /// agent delegations.
        case barrier
    }

    /// What a folded run is made of. Derived from `toolCount` so the two can
    /// never disagree: a run without a single call IS the thinking.
    enum Kind: Equatable {
        case tools
        /// [T-fold-all-process] A run of thinking only: drawn as one
        /// "Thinking process" row, never as "Ran 0 tools".
        case thinking
    }

    struct Group: Equatable {
        /// Indices of the folded blocks, first block of the run through its
        /// last member. Never empty — a run always opens on a real block.
        let range: ClosedRange<Int>
        let toolCount: Int
        let failedCount: Int
        let cancelledCount: Int
        /// [T-fold-all-process] How many thinking blocks the run covers.
        let thinkingCount: Int
        /// [T-fold-lead-gap] Blocks inside `range` that KEEP their own row: the
        /// one-line remarks written between the opening thinking and the first
        /// call. They are not members (nothing is hidden there) but they sit
        /// inside the range, so every surface that draws a range has to skip
        /// them instead of treating the range as one solid block of members.
        let visibleGaps: [Int]

        /// A run with no tool call is a thinking run ([T-fold-all-process]).
        var kind: Kind { toolCount > 0 ? .tools : .thinking }

        init(range: ClosedRange<Int>, toolCount: Int, failedCount: Int, cancelledCount: Int,
             thinkingCount: Int = 0, visibleGaps: [Int] = []) {
            self.range = range
            self.toolCount = toolCount
            self.failedCount = failedCount
            self.cancelledCount = cancelledCount
            self.thinkingCount = thinkingCount
            self.visibleGaps = visibleGaps
        }
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
        /// First block of the open run, while one is open.
        var start: Int?
        var lastMember = 0
        var tools = 0, thinks = 0, failed = 0, cancelled = 0
        /// The run as it stood at its latest note (the soft end).
        var softEnd: Group?
        /// [T-fold-lead-gap] One-line remarks between the run's opening
        /// thinking and its first call: they stay visible (range gaps).
        var leadGaps: [Int] = []
        /// [T-fold-trailing-thinking] Last thinking block of the stretch that
        /// follows the run's latest member, while no tool, note or barrier has
        /// come after it: it folds when the reply closes the run.
        var trailingThinking: Int?

        func reset() {
            start = nil
            tools = 0; thinks = 0; failed = 0; cancelled = 0
            softEnd = nil
            leadGaps = []
            trailingThinking = nil
        }
        /// Whether a run with `t` calls and `k` thinking blocks is worth a row:
        /// one call, or — with no call at all — one thought. Anything less is
        /// only empty text, which is never a run.
        func qualifies(_ t: Int, _ k: Int) -> Bool {
            t >= minimumToolCount || k >= minimumThinkingCount
        }
        /// The run's last folded block: its last member, or the thinking that
        /// trails it when that thinking leads into the reply.
        func lastBlock() -> Int { max(lastMember, trailingThinking ?? lastMember) }
        /// Whether the run is worth folding when it closes here. [T-fold-lead-gap]
        /// A run that opened on thinking and only ever met remarks before a
        /// barrier or the end never got its calls: the remark cuts it exactly
        /// as it always did, and the thinking keeps the row it always had.
        func foldsAtClose() -> Bool {
            qualifies(tools, thinks) && !(tools == 0 && !leadGaps.isEmpty)
        }
        /// [T-fold-lead-gap] The gaps that fall inside `lo...hi` — and only for
        /// a run that really has a call: a remark whose calls never arrived
        /// leaves the thinking on its own, and a run of thinking only has no
        /// gap to draw.
        func gaps(_ lo: Int, _ hi: Int) -> [Int] {
            guard tools > 0 else { return [] }
            return leadGaps.filter { $0 >= lo && $0 <= hi }
        }
        /// The run was cut without a reply: fold what came before its latest
        /// note, if that much qualifies on its own.
        func closeAtSoftEnd() {
            if let g = softEnd, qualifies(g.toolCount, g.thinkingCount) { groups.append(g) }
        }

        for (i, block) in blocks.enumerated() {
            switch block {
            case .tool(.unfinished), .barrier:
                // A call that can still make progress — or a row that is
                // always visible — cuts the run. What was already closed by a
                // note still folds; a run of thinking only is dropped with the
                // rest (the pills stay where they were, as before).
                // [T-fold-card-boundary] A CARD is not in this group: it closes
                // the run before it instead of dropping it.
                closeAtSoftEnd()
                reset()
            case .tool(let outcome):
                // [T-fold-all-process] A call joins the run its lead thinking
                // opened, or opens one.
                if start == nil { start = i }
                lastMember = i
                trailingThinking = nil
                tools += 1
                if outcome == .failed { failed += 1 }
                if outcome == .cancelled { cancelled += 1 }
            case .note:
                // [T-fold-lead-gap] A remark between the run's thinking and its
                // first call is the model introducing the work it is about to
                // do. It keeps its own row (it is text, never a member), but it
                // no longer cuts the thinking above it out of the process: with
                // the old `reset()` the device showed a "Deep Thinking" pill of
                // its own above the folded "Ran 14 tools" row. The remark is
                // recorded as a GAP inside the run instead.
                if let s = start, tools == 0, thinks > 0, s <= i {
                    leadGaps.append(i)
                    continue
                }
                // Only after a call: a remark with no run open (or none yet)
                // is not part of the process and stays visible.
                guard let s = start, tools > 0 else { reset(); continue }
                lastMember = i
                trailingThinking = nil
                softEnd = Group(range: s...i, toolCount: tools,
                                failedCount: failed, cancelledCount: cancelled,
                                thinkingCount: thinks,
                                visibleGaps: gaps(s, i))
            case .thinking:
                // [T-fold-all-process] Thinking IS the process: it opens the
                // run when no call has come yet (the old `leadThinking` case)
                // and joins it afterwards — including as the trailing member
                // that folds once the reply arrives.
                if start == nil { start = i }
                thinks += 1
                trailingThinking = i
            case .text(isEmpty: true):
                continue
            case .card, .text(isEmpty: false):
                // The reply — never a member, however many segments it has.
                // [T-fold-card-boundary] A card closes the run the same way:
                // what came before it is a finished process (its trailing
                // thinking included), and the card stays outside it, on show.
                if let s = start, foldsAtClose() {
                    groups.append(Group(range: s...lastBlock(), toolCount: tools,
                                        failedCount: failed, cancelledCount: cancelled,
                                        thinkingCount: thinks,
                                        visibleGaps: gaps(s, lastBlock())))
                }
                reset()
            }
        }
        // [T-fold-stopped-tools] The task is over and the message ends on a
        // run with no reply after it (a user stop, a failed turn, a reply-less
        // end): fold the whole run — cancelled and failed calls included, plus
        // the thinking before, between and after them. [T-fold-all-process]
        // The same holds for a run of thinking only: a stopped turn whose
        // whole content was one thought becomes one "Thinking process" row
        // instead of a stray pill (or nothing at all). A tool that never
        // finished closed the run above, so a call that is still running (or
        // still waiting for its confirmation) keeps its capsules visible even
        // here. While the task runs, this shape is the pause before the next
        // calls: only the part up to the latest note folds then.
        if ended, let s = start, foldsAtClose() {
            groups.append(Group(range: s...lastBlock(), toolCount: tools,
                                failedCount: failed, cancelledCount: cancelled,
                                thinkingCount: thinks,
                                visibleGaps: gaps(s, lastBlock())))
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

    // MARK: Nothing to show [T-fold-blank-thinking]
    //
    // A thinking block whose text is a lone space, a newline or a zero-width
    // marker holds nothing a reader can see, yet it is a block with its own
    // row: measured, drawn as the "Deep Thinking" header with a count of 1 and
    // an empty body when opened. The planner already treats it as empty text,
    // so it never folds and can never be hidden with a run — it stayed on
    // screen as a residual pill next to the fold row it was left out of.
    // ONE test decides "nothing to show", shared by the planner, the list's
    // rows and the share export.

    /// Characters that occupy no space of their own: the zero-width markers a
    /// model sometimes emits instead of nothing at all. Deliberately NARROW —
    /// whitespace is covered by `isWhitespace`, and marks that change how their
    /// NEIGHBOURS render (U+200E LRM, U+200F RLM, U+00AD soft hyphen, the
    /// variation selectors) are NOT here: a block holding only one of those
    /// must keep its row rather than have text hidden on a guess.
    static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{200B}",  // zero width space
        "\u{200C}",  // zero width non-joiner
        "\u{200D}",  // zero width joiner
        "\u{2060}",  // word joiner
        "\u{FEFF}",  // zero width no-break space (BOM)
    ]

    /// Whether `text` has no visible character at all. Stops at the first
    /// visible one, so a long thought costs one comparison.
    static func isBlank(_ text: String) -> Bool {
        for ch in text {
            if ch.isWhitespace { continue }
            if ch.unicodeScalars.allSatisfy(invisibleScalars.contains) { continue }
            return false
        }
        return true
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
    ///
    /// [T-fold-card-boundary] `isCard` extends that prefix over the cards that
    /// follow it. A card is final the moment it is on screen — the model asked
    /// the user something (or handed over a generated UI) and that request is
    /// over, so nothing more can arrive in it — and planning THROUGH it is what
    /// lets the run before the card fold while the answer is still pending.
    /// This is not a blanket "plan to the end": the scan stops at the first
    /// block that is not a settled card, so a request still streaming behind
    /// the card keeps everything after it out of the plan, and a message
    /// ending on a running tool still folds nothing.
    static func foldHorizon<ID: Hashable>(blockIds: [ID], separators: Set<ID>,
                                          isCard: (ID) -> Bool = { _ in false }) -> Int {
        var horizon: Int
        if let last = blockIds.lastIndex(where: { separators.contains($0) }) {
            horizon = last + 1
        } else {
            horizon = 0
        }
        while horizon < blockIds.count, isCard(blockIds[horizon]) { horizon += 1 }
        return horizon
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
            // [T-fold-all-process] Thinking with no text yet (a fresh stream,
            // or a block that never got one) is transparent, exactly like an
            // empty text block: there is nothing to fold and nothing to hide,
            // and a run must not open on a pill that is still empty. The
            // buffer counts as content: it is text that is about to show.
            // [T-fold-blank-thinking] "Empty" is the shared `isBlankThinking`
            // rule (whitespace AND lone zero-width markers) — the same one the
            // list uses to give such a block no row of its own.
            return isBlankThinking(block) ? .text(isEmpty: true) : .thinking
        case .info, .delegateTool:  // [T-user-ask] never folded
            return .barrier
        case .userAskTool:
            return isCard(block) ? .card : .barrier
        case .genuiTool:
            // A rendered UI is a handover. Failed/cancelled calls are settled
            // process, not unfinished barriers that discard the preceding run.
            switch block.toolStatus {
            case .success: return .card
            case .failed: return .tool(.failed)
            case .cancelled: return .tool(.cancelled)
            case .streaming, .running, .none: return .barrier
            }
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

    /// [T-fold-blank-thinking] A thinking block with nothing to show: neither
    /// its text nor the buffer that is about to become text holds a visible
    /// character (see `isBlank`). ONE test for every surface — the planner's
    /// input, the list's rows and the share export — so a block can never be a
    /// leftover pill in the chat while the exported image drops it.
    static func isBlankThinking(_ block: AssistantBlock) -> Bool {
        isBlank(block.content) && isBlank(block.thinkingContentBuffer)
    }

    /// [T-fold-card-boundary] A block drawn as a card the user acts on: a
    /// `user_ask` question (waiting, answered, failed or never sent — the card
    /// is on screen in every one of those states) or a `show_ui` that rendered.
    /// Info rows and sub-agent delegations are NOT cards: they are process.
    static func isCard(_ block: AssistantBlock) -> Bool {
        switch block.kind {
        case .userAskTool:
            return true
        case .genuiTool:
            // While the program streams, or when it failed to validate, the
            // block draws as an ordinary capsule: a call, not a handover.
            if case .success = block.toolStatus { return true }
            return false
        default:
            return false
        }
    }

    /// [T-share-fold-tools] One folded run as every surface draws it: the
    /// message list's "Ran N tools · 9s" row and the share picker / export,
    /// or — [T-fold-all-process] for a run with no call at all — one
    /// "Thinking process" row.
    struct FoldedRun: Equatable {
        /// Expanded-state key: the first TOOL's provider `toolUseId`, which
        /// survives a session reload (block ids are regenerated on every
        /// load); its block id when there is none. [T-fold-lead-thinking]
        /// The first TOOL, not the first block: the run may open on a
        /// thinking block, which has neither. [T-fold-all-process] A run of
        /// thinking only has no provider id anywhere, so it keys on its first
        /// block and comes back CLOSED after a reload — the same direction the
        /// row starts in, never a fold that reopens on its own.
        let key: String
        /// The first folded block (a thinking block when lead thinking folds).
        let firstBlockId: UUID
        /// [T-fold-lead-gap] The block the fold row is DRAWN at: the first
        /// member that is actually hidden. With a visible gap in front of it
        /// (thinking · remark · calls) the row belongs where the calls are,
        /// below the remark, not above it.
        let anchorBlockId: UUID
        /// [T-fold-lead-gap] Blocks inside `group.range` that keep their own
        /// row (see `Group.visibleGaps`), in order.
        let visibleIds: [UUID]
        /// Every folded block, in order (gaps included).
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
            // [T-fold-lead-gap] The gaps keep their rows; the fold row anchors
            // on the first block that is really hidden behind it.
            // The row goes where the CALLS are: below the remark, so the
            // remark keeps its place in the reading order (thinking above it
            // is what moves into the row).
            let anchor = group.visibleGaps.last.map { min($0 + 1, group.range.upperBound) }
                ?? group.range.lowerBound
            return FoldedRun(key: firstTool.toolUseId ?? firstTool.id.uuidString,
                             firstBlockId: members[members.startIndex].id,
                             anchorBlockId: blocks[anchor].id,
                             visibleIds: group.visibleGaps.filter { group.range.contains($0) }.map { blocks[$0].id },
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
        // [T-fold-card-boundary] The cards already on screen may be planned
        // through (see the generic rule above).
        let cards = Set(message.blocks.filter(isCard).map(\.id))
        return foldHorizon(blockIds: message.blocks.map(\.id),
                           separators: separators[message.id] ?? [],
                           isCard: { cards.contains($0) })
    }

    /// Settings key for the feature. Off unless the user turns it on.
    static let settingsKey = "chat.foldConsecutiveTools"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: settingsKey) as? Bool) ?? false
    }
}
