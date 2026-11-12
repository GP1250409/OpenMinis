//
//  MinisUIView.swift
//  Minis
//
//  [MOD genui] The `show_ui` card: draws a Minis UI Lang program with native
//  SwiftUI components. State lives on the block (`genuiStateJSON`, saved per
//  session by GenUIStatePersistence), never in view @State, so a recycled
//  cell or a reopened chat shows what the user set.
//
//  Layout rule: values and actual height commit together without animation.
//  Only a real size change updates list geometry; no automatic bottom reveal,
//  no coarse-height reset, and no borrowed thinking/user-ask toggle callbacks.
//

import Charts
import Combine
import SwiftUI
import UIKit

// MARK: - Model shared by the card, the agent and the list

/// One synchronous state commit. A detached/preview card runs the same request
/// itself; a mounted list consumes it while content and real height are atomic.
final class MinisUIStateUpdate {
    let blockId: UUID
    let sessionId: String?
    let request: ToggleRequest
    /// The origin's final state, read AFTER the one-shot request. Other mounted
    /// lists of this session may hold a different AssistantBlock instance.
    let state: (() -> String?)?

    init(blockId: UUID, sessionId: String?, state: (() -> String?)? = nil, apply: @escaping () -> Void) {
        self.blockId = blockId
        self.sessionId = sessionId
        self.state = state
        self.request = ToggleRequest(apply)
    }
}

enum MinisUIStore {
    static let stateChanged = Notification.Name("MinisUIStateChanged")

    /// Leave the originating Button/Slider callback BEFORE replacing its hosting
    /// configuration. The whole mutation is queued, NOT just the size update:
    /// no frame can draw new content at the old height. Mutations read current
    /// state when executed, so several queued controls cannot overwrite each other.
    static func enqueue(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    /// Do NOT publish state first and then hop to the main queue to resize:
    /// that drew new content in the old cell, followed by an animated rebuild.
    /// NotificationCenter delivery is synchronous on the UI thread on purpose.
    static func update(blockId: UUID, sessionId: String?, state: (() -> String?)? = nil, _ apply: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let change = MinisUIStateUpdate(blockId: blockId, sessionId: sessionId, state: state, apply: apply)
        NotificationCenter.default.post(name: stateChanged, object: change)
        if !change.request.hasRun {
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            withTransaction(noAnim) { _ = change.request.run() }
        }
    }
}

enum MinisUITool {
    static let name = "show_ui"

    /// Parsed programs by source text. `renders` / `estimatedHeight` run from
    /// the list's layout and the block view's body; parsing once per program
    /// keeps those paths cheap. Main-thread only (both callers are).
    private static var parsed: [String: (MUProgram, [String: MUValue])] = [:]

    static func compiled(_ src: String) -> (MUProgram, [String: MUValue]) {
        if let hit = parsed[src] { return hit }
        let p = MUProgram.parse(src)
        let entry = (p, p.defaultState().0)
        if parsed.count > 64 { parsed.removeAll() }
        parsed[src] = entry
        return entry
    }

    /// Defaults with the block's saved values on top.
    static func state(_ block: AssistantBlock, defaults: [String: MUValue]) -> [String: MUValue] {
        var st = defaults
        if let saved = loadState(block) { for (k, v) in saved where st[k] != nil { st[k] = v } }
        return st
    }

    /// The program from the tool input JSON.
    static func program(_ block: AssistantBlock) -> String? {
        guard let json = block.toolInputArgs, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["program"] as? String
    }

    static func loadState(_ block: AssistantBlock) -> [String: MUValue]? {
        guard let json = block.genuiStateJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj.mapValues(MUValue.fromJSON)
    }

    static func encodeState(_ st: [String: MUValue]) -> String? {
        let obj = st.mapValues(\.json)
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Plain text for copy / search / share.
    static func fallbackText(_ block: AssistantBlock) -> String {
        guard let src = program(block) else { return "" }
        let (prog, defaults) = compiled(src)
        return MinisUIEngine.fallbackText(prog.render(state(block, defaults: defaults)).0)
    }

    static func estimatedHeight(_ block: AssistantBlock, width: CGFloat) -> CGFloat {
        guard let src = program(block) else { return 36 }
        let (prog, defaults) = compiled(src)
        guard let root = prog.render(state(block, defaults: defaults)).0 else { return 64 }
        // 16pt list margins each side; 2pt card padding top and bottom.
        return MinisUIEngine.estimatedHeight(root, width: width - 32) + 4
    }

    /// Whether the card is drawn (the call succeeded = the program validated);
    /// otherwise the block shows as an ordinary tool capsule with the errors.
    static func renders(_ block: AssistantBlock) -> Bool {
        guard case .success = block.toolStatus, let src = program(block) else { return false }
        let (prog, defaults) = compiled(src)
        return prog.render(defaults).0 != nil
    }

    /// The message a button sends as the user's next turn: the visible text
    /// plus a machine-readable line the model can rely on.
    static func turnText(message: String, context: MUValue, state: [String: MUValue], order: [String]) -> String {
        var payload: [String: Any] = [:]
        var st: [String: Any] = [:]
        for k in order { if let v = state[k] { st[k] = v.json } }
        if !st.isEmpty { payload["state"] = st }
        if !context.isNull { payload["context"] = context.json }
        guard !payload.isEmpty, JSONSerialization.isValidJSONObject(payload),
              let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return message }
        // A reminder: the bubble, previews and search hide it (one shared
        // stripper); the model still reads it.
        return message + "\n<system-reminder>show_ui card values when tapped: \(s)</system-reminder>"
    }
}

// MARK: - Card

struct MinisUICardView: View {
    @ObservedObject var block: AssistantBlock
    @EnvironmentObject private var vm: AIChatViewModel


    var body: some View {
        let compiled = compiledProgram()
        let state = currentState(compiled.1)
        let (root, _) = compiled.0.render(state)
        Group {
            if let root {
                MUNodeView(comp: root, ctx: MUContext(state: state, program: compiled.0, defaults: compiled.1,
                                                     set: { name, value, live in setState(name, value, live: live, defaults: compiled.1) },
                                                     commit: { enqueueStateChange { persist(currentState(compiled.1), force: true) } },
                                                     run: { act in runAction(act, program: compiled.0, defaults: compiled.1) }),
                           topLevel: true)
            } else {
                Text(AppLocalized("This card could not be displayed."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// Parsed once per program text (shared cache).
    private func compiledProgram() -> (MUProgram, [String: MUValue]) {
        MinisUITool.compiled(MinisUITool.program(block) ?? "")
    }

    private func currentState(_ defaults: [String: MUValue]) -> [String: MUValue] {
        MinisUITool.state(block, defaults: defaults)
    }

    /// `live`: a slider mid-drag. The value shows at once, but saving and the
    /// list's re-measure wait for the drag to end (`commit`), so dragging
    /// never runs a layout pass per frame.
    private func setState(_ name: String, _ value: MUValue, live: Bool, defaults: [String: MUValue]) {
        var st = currentState(defaults)
        guard st[name] != nil else { return }
        st[name] = value
        if live {
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            withTransaction(noAnim) {
                block.genuiStateJSON = MinisUITool.encodeState(st)
            }
        } else {
            enqueueStateChange {
                // Resolve after earlier queued controls, not from the snapshot
                // the Button action read before those controls were committed.
                var latest = currentState(defaults)
                guard latest[name] != nil else { return }
                latest[name] = value
                persist(latest)
            }
        }
    }

    private func enqueueStateChange(_ work: @escaping () -> Void) {
        let sessionId = vm.sessionId
        MinisUIStore.enqueue {
            guard vm.sessionId == sessionId else { return }
            work()
        }
    }

    private func persist(_ st: [String: MUValue], force: Bool = false) {
        let after = MinisUITool.encodeState(st)
        guard force || block.genuiStateJSON != after else { return }
        // The list owns the state write AND any size change in one no-animation
        // pass. Even a slider's force-commit must measure its final live state.
        MinisUIStore.update(blockId: block.id, sessionId: vm.sessionId, state: { block.genuiStateJSON }) {
            block.genuiStateJSON = after
        }
        GenUIStatePersistence.save(blockToolUseId: block.toolUseId, sessionId: vm.sessionId, json: after)
    }

    private func runAction(_ act: MUAction, program: MUProgram, defaults: [String: MUValue]) {
        enqueueStateChange { applyAction(act, program: program, defaults: defaults) }
    }

    private func applyAction(_ act: MUAction, program: MUProgram, defaults: [String: MUValue]) {
        let st = currentState(defaults)
        let (newState, events, _) = MinisUIEngine.run(act, state: st, prog: program, defaults: defaults)
        persist(newState)
        for e in events {
            switch e {
            case .copy(let s):
                UIPasteboard.general.string = s
                MinisToast.show(AppLocalized("Copied"))
            case .openURL(let u):
                if let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
            case .toAssistant(let message, let context):
                let text = MinisUITool.turnText(message: message, context: context, state: newState, order: program.stateOrder)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // The user's own tap, like the composer's send: a busy run
                // queues it as the next turn, an idle chat starts one now.
                if vm.isProcessing {
                    vm.enqueuePrompt(silent: true, overrideText: text)
                } else {
                    vm.send(overrideText: text)
                }
            }
        }
    }
}

/// Saving the card's state outside the message store, keyed by session and
/// tool call id: a small JSON file per session in Application Support. The
/// transcript (and what the model sees) is never rewritten for a slider move.
enum GenUIStatePersistence {
    private static let queue = DispatchQueue(label: "minis.genui.state")

    private static func fileURL(_ sessionId: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MinisUIState", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return dir.appendingPathComponent("\(safe).json")
    }

    static func save(blockToolUseId: String?, sessionId: String?, json: String?) {
        guard let toolUseId = blockToolUseId, let sessionId, let url = fileURL(sessionId) else { return }
        queue.async {
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
            all[toolUseId] = json
            if let d = try? JSONSerialization.data(withJSONObject: all) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// Put each card's saved values back on its block (session load).
    static func restore(into messages: [ChatMessage], sessionId: String?) {
        let cards = messages.flatMap { $0.blocks }.filter { $0.kind == .genuiTool && $0.toolUseId != nil }
        guard !cards.isEmpty, let sessionId, let url = fileURL(sessionId) else { return }
        let all: [String: String] = queue.sync {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
        }
        for b in cards {
            if let id = b.toolUseId, let saved = all[id] { b.genuiStateJSON = saved }
        }
    }
}

// MARK: - Rendering context

struct MUContext {
    let state: [String: MUValue]
    let program: MUProgram
    let defaults: [String: MUValue]
    /// (name, value, live): live = a slider mid-drag (no save, no re-measure).
    let set: (String, MUValue, Bool) -> Void
    /// The drag ended: save and re-measure once.
    let commit: () -> Void
    let run: (MUAction) -> Void

    func set(_ name: String, _ value: MUValue) { set(name, value, false) }

    func num(_ name: String) -> Double { if case .num(let d)? = state[name] { return d }; return 0 }
    func str(_ name: String) -> String { if case .str(let s)? = state[name] { return s }; return "" }
    func bool(_ name: String) -> Bool { if case .bool(let b)? = state[name] { return b }; return false }
}

enum MUStyle {
    static func tone(_ t: String?) -> Color {
        switch t {
        case "accent", "info": return .accentColor
        case "success": return .green
        case "warning": return .orange
        case "danger": return .red
        case "secondary": return .secondary
        default: return .primary
        }
    }

    static func numText(_ d: Double) -> String { (try? MUFormat.num(d)) ?? "" }

    /// `**bold**` only, as the spec promises.
    static func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        for (i, part) in s.components(separatedBy: "**").enumerated() {
            if i > 0 { bold.toggle() }
            var a = AttributedString(part)
            if bold { a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
        }
        return out
    }
}

// MARK: - Node renderer

struct MUNodeView: View {
    let comp: MUComp
    let ctx: MUContext
    var topLevel = false

    var body: some View {
        switch comp.name {
        case "Card": MUCard(comp: comp, ctx: ctx, topLevel: topLevel)
        case "Stack":
            let gap: CGFloat = comp.str("gap") == "s" ? 6 : (comp.str("gap") == "l" ? 16 : 10)
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(comp.children.enumerated()), id: \.offset) { _, c in MUNodeView(comp: c, ctx: ctx) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "Row":
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(comp.children.enumerated()), id: \.offset) { _, c in
                    MUNodeView(comp: c, ctx: ctx).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case "Divider":
            Divider()
        case "Title":
            let size: CGFloat = comp.str("size") == "l" ? 20 : (comp.str("size") == "s" ? 15 : 17)
            Text(MUStyle.inline(comp.str("text") ?? ""))
                .font(.system(size: size, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        case "Text":
            Text(MUStyle.inline(comp.str("text") ?? ""))
                .font(.system(size: 14))
                .foregroundStyle(MUStyle.tone(comp.str("tone")))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case "Metric": MUMetric(comp: comp)
        case "Badge":
            let tone = comp.str("tone") ?? "neutral"
            let c = tone == "neutral" ? Color.secondary : MUStyle.tone(tone)
            Text(comp.str("text") ?? "")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(c)
                .background(Capsule().fill(c.opacity(0.14)))
        case "List": MUList(comp: comp)
        case "Callout": MUCallout(comp: comp)
        case "Slider": MUSlider(comp: comp, ctx: ctx)
        case "Stepper": MUStepper(comp: comp, ctx: ctx)
        case "Segmented": MUSegmented(comp: comp, ctx: ctx)
        case "Toggle":
            let name = comp.str("value") ?? ""
            Toggle(isOn: Binding(get: { ctx.bool(name) }, set: { ctx.set(name, .bool($0)) })) {
                Text(comp.str("label") ?? "").font(.system(size: 14))
            }
            .toggleStyle(MUCheckToggleStyle())
        case "Choice": MUChoice(comp: comp, ctx: ctx)
        case "Table": MUTable(comp: comp)
        case "BarChart", "LineChart": MUChart(comp: comp)
        case "MultiChart": MUMultiChart(comp: comp)
        case "Button": MUButton(comp: comp, ctx: ctx)
        default: EmptyView()
        }
    }
}

private struct MUCard: View {
    let comp: MUComp
    let ctx: MUContext
    let topLevel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = comp.str("title") {
                Text(t).font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(comp.children.enumerated()), id: \.offset) { _, c in MUNodeView(comp: c, ctx: ctx) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(topLevel ? ChatColors.secondaryBg : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }
}

private struct MUMetric: View {
    let comp: MUComp
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(comp.str("label") ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(comp.str("value") ?? "")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if let n = comp.str("note") {
                Text(n).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MUList: View {
    let comp: MUComp
    var body: some View {
        let ordered = comp.bool("ordered") == true
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(comp.strings("items").enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(i + 1)." : "•").font(.system(size: 14)).foregroundStyle(.secondary)
                    Text(MUStyle.inline(item)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct MUCallout: View {
    let comp: MUComp
    var body: some View {
        let tone = comp.str("tone") ?? "info"
        let c = MUStyle.tone(tone)
        let icon = ["success": "checkmark.circle.fill", "warning": "exclamationmark.triangle.fill",
                    "danger": "xmark.circle.fill"][tone] ?? "info.circle.fill"
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(c).padding(.top, 1)
            Text(MUStyle.inline(comp.str("text") ?? "")).font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.opacity(0.10)))
    }
}

private struct MUSlider: View {
    let comp: MUComp
    let ctx: MUContext

    var body: some View {
        let name = comp.str("value") ?? ""
        let lo = comp.num("min") ?? 0, hi = max(comp.num("max") ?? 1, (comp.num("min") ?? 0) + 0.0001)
        let step = comp.num("step").flatMap { $0 > 0 ? $0 : nil }
        let value = min(max(ctx.num(name), lo), hi)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comp.str("label") ?? "").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(MUStyle.numText(value) + (comp.str("unit") ?? ""))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            // The program recomputes on every change; it is a few dozen
            // arithmetic nodes, so live updates while dragging are cheap.
            let binding = Binding<Double>(get: { value }, set: { v in
                let snapped = step.map { lo + ((v - lo) / $0).rounded() * $0 } ?? v
                ctx.set(name, .num(min(max(snapped, lo), hi)), true)
            })
            let editing: (Bool) -> Void = { active in if !active { ctx.commit() } }
            if let step {
                Slider(value: binding, in: lo...hi, step: step, onEditingChanged: editing)
            } else {
                Slider(value: binding, in: lo...hi, onEditingChanged: editing)
            }
        }
    }
}

private struct MUStepper: View {
    let comp: MUComp
    let ctx: MUContext
    var body: some View {
        let name = comp.str("value") ?? ""
        let lo = comp.num("min") ?? 0, hi = comp.num("max") ?? 0
        let step = max(comp.num("step") ?? 1, 0.0001)
        let v = ctx.num(name)
        HStack {
            Text(comp.str("label") ?? "").font(.system(size: 14))
            Spacer()
            Button { ctx.set(name, .num(max(lo, v - step))) } label: { Image(systemName: "minus") }
                .buttonStyle(MUSquareButtonStyle()).disabled(v <= lo)
            Text(MUStyle.numText(v)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 36)
            Button { ctx.set(name, .num(min(hi, v + step))) } label: { Image(systemName: "plus") }
                .buttonStyle(MUSquareButtonStyle()).disabled(v >= hi)
        }
    }
}

private struct MUSegmented: View {
    let comp: MUComp
    let ctx: MUContext
    var body: some View {
        // [MOD genui] Drawn from plain SwiftUI buttons, not
        // `Picker(.segmented)`: on 13P the UIKit segmented control inside the
        // list's hosting cell never reported a new selection (saved value
        // stayed at the default across three cards), while the card's
        // Button-based inputs (Choice, Stepper, @Set buttons) all worked.
        let name = comp.str("value") ?? ""
        let selected = ctx.str(name)
        HStack(spacing: 2) {
            ForEach(Array(comp.strings("options").enumerated()), id: \.offset) { _, opt in
                let on = opt == selected
                Button {
                    guard !on else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    ctx.set(name, .str(opt))
                } label: {
                    Text(opt)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Color(uiColor: .systemBackground) : .clear)
                                .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 2, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.07)))
    }
}

private struct MUChoice: View {
    let comp: MUComp
    let ctx: MUContext
    var body: some View {
        let name = comp.str("value") ?? ""
        let selected = ctx.str(name)
        VStack(spacing: 8) {
            ForEach(Array(comp.strings("options").enumerated()), id: \.offset) { _, opt in
                let on = opt == selected
                Button { ctx.set(name, .str(opt)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(MUStyle.inline(opt)).font(.system(size: 14)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MUTable: View {
    let comp: MUComp
    var body: some View {
        let headers = comp.strings("headers")
        let rows = comp.rows("rows")
        VStack(spacing: 0) {
            row(headers, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Divider()
                row(r, header: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(c)
                    .font(.system(size: 13, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? .secondary : .primary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// Chart colour style for `show_ui` charts. Stored in UserDefaults (settings
/// page: Appearance > Chart Colours). "" = system look (Swift Charts default),
/// "economist" = The Economist house style: one red series on a quiet grid.
enum MUChartStyle {
    static let key = "genuiChartPalette"
    static let economist = "economist"
    /// The Economist visual styleguide v1.2 (4 May 2017): blue/cyan/gold series
    /// on a light blue-grey panel, red tag in the top-left corner.
    static let economist2017 = "economist2017"

    private static func hex(_ rgb: UInt32, dark: UInt32? = nil) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { t in t.userInterfaceStyle == .dark ? ui(dark ?? rgb) : ui(rgb) })
    }

    /// Series order for lines, taken from the guide's web palette (p.12) and the
    /// "Lines" colour order (p.15): blue, cyan, gold, dark red, green, purple.
    /// Dark red is not in the web palette; #A81829 (red scale, darkest) stands in.
    static let series2017: [Color] = [
        hex(0x006BA2, dark: 0x4D9FD1),  // blue
        hex(0x3EBCD2, dark: 0x6FD3E4),  // cyan
        hex(0xEBB434, dark: 0xF2C85E),  // gold / yellow
        hex(0xA81829, dark: 0xE0525E),  // dark red (stand-in, see above)
        hex(0x379A8B, dark: 0x5CBBAD),  // green
        hex(0x9A607F, dark: 0xBE86A2),  // purple
    ]
    /// Stacked bars use blue, cyan, gold, green, light green, dark blue (p.14).
    static let stacked2017: [Color] = [
        hex(0x006BA2, dark: 0x4D9FD1), hex(0x3EBCD2, dark: 0x6FD3E4), hex(0xEBB434, dark: 0xF2C85E),
        hex(0x379A8B, dark: 0x5CBBAD), hex(0x69C9B9, dark: 0x86E5D4), hex(0x00588D, dark: 0x3D89C3),
    ]
    /// Chart panel (web "boxes": #E9EDF0), grid, text, red tag.
    static let panel2017 = hex(0xE9EDF0, dark: 0x1F262B)
    static let grid2017 = hex(0xB7C6CF, dark: 0x3A474F)
    static let text2017 = hex(0x3F5661, dark: 0xB7C6CF)
    static let tag2017 = hex(0xE3120B, dark: 0xE3120B)
    /// Grey for "other" / context (web palette grey).
    static let other2017 = hex(0x758D99, dark: 0x8FA3AD)

    /// Main series red (light / dark).
    static let red = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.27, blue: 0.25, alpha: 1)
            : UIColor(red: 0.902, green: 0.161, blue: 0.137, alpha: 1)
    })

    /// Context grey (warm, like the printed charts): #b6b6a9 light, #8c8c83 dark.
    static let grey = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.549, green: 0.549, blue: 0.514, alpha: 1)
            : UIColor(red: 0.714, green: 0.714, blue: 0.663, alpha: 1)
    })
}

private struct MUChart: View {
    let comp: MUComp
    @AppStorage(MUChartStyle.key) private var palette: String = ""

    var body: some View {
        let labels = comp.strings("labels")
        let values = comp.numbers("values")
        let unit = comp.str("unit") ?? ""
        let points = Array(zip(labels, values).enumerated())
        if palette == MUChartStyle.economist2017 {
            // One-series charts become a one-row MultiChart in the 2017 style.
            MUMultiChartBody(kind: comp.name == "LineChart" ? "line" : "bar",
                             labels: labels, series: [], matrix: [values],
                             title: nil, subtitle: nil, source: nil, unit: unit,
                             highlight: comp.strings("highlight"), framed: false)
        } else if palette == MUChartStyle.economist {
            economistChart(labels: labels, values: values, unit: unit)
        } else {
            Chart(points, id: \.offset) { _, p in
                if comp.name == "LineChart" {
                    LineMark(x: .value("x", p.0), y: .value("y", p.1))
                    PointMark(x: .value("x", p.0), y: .value("y", p.1))
                } else {
                    BarMark(x: .value("x", p.0), y: .value("y", p.1))
                        .cornerRadius(4)
                        .annotation(position: .top) {
                            Text(MUStyle.numText(p.1) + unit).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: labels)
            .frame(height: 180)
            .padding(.top, 4)
        }
    }

    /// Same data and the same fixed 180pt height as the system chart, so
    /// switching style never changes the card's measured height.
    ///
    /// Economist rule: grey for context, red for the point. With `highlight`
    /// labels, bars outside the list turn grey; a line stays grey with red
    /// dots on the highlighted points (and the red line when none is given).
    @ViewBuilder
    private func economistChart(labels: [String], values: [Double], unit: String) -> some View {
        let isLine = comp.name == "LineChart"
        let n = min(labels.count, values.count)
        let hl = Set(comp.strings("highlight"))
        let hasHL = !hl.isEmpty
        Chart {
            ForEach(0..<n, id: \.self) { i in
                if isLine {
                    LineMark(x: .value("x", labels[i]), y: .value("y", values[i]))
                        .foregroundStyle(hasHL ? MUChartStyle.grey : MUChartStyle.red)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    if hl.contains(labels[i]) {
                        PointMark(x: .value("x", labels[i]), y: .value("y", values[i]))
                            .foregroundStyle(MUChartStyle.red)
                            .symbolSize(70)
                            .annotation(position: .top) {
                                Text(MUStyle.numText(values[i]) + unit)
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(MUChartStyle.red)
                            }
                    }
                } else {
                    let on = !hasHL || hl.contains(labels[i])
                    BarMark(x: .value("x", labels[i]), y: .value("y", values[i]))
                        .foregroundStyle(on ? MUChartStyle.red : MUChartStyle.grey)
                        .annotation(position: .top) {
                            Text(MUStyle.numText(values[i]) + unit)
                                .font(.system(size: 9, weight: on && hasHL ? .semibold : .regular))
                                .foregroundStyle(on && hasHL ? MUChartStyle.red : Color.secondary)
                        }
                }
            }
            if !isLine {
                // Black baseline, as in the print charts.
                RuleMark(y: .value("zero", 0.0))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: labels)
        .chartYAxis {
            // Light horizontal grid only, value labels on the right.
            AxisMarks(position: .trailing) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8)).foregroundStyle(Color.primary.opacity(0.14))
                AxisValueLabel().foregroundStyle(Color.primary)
            }
        }
        .frame(height: 180)
        .padding(.top, 4)
    }
}

/// `MultiChart`: several series, a legend, subtitle and source note. Always
/// drawn in the 2017 Economist look (it has no "system" look); the settings
/// switch only decides how the single-series BarChart/LineChart draw.
private struct MUMultiChart: View {
    let comp: MUComp
    var body: some View {
        MUMultiChartBody(kind: comp.str("kind") ?? "line",
                         labels: comp.strings("labels"), series: comp.strings("series"),
                         matrix: comp.matrix("values"), title: comp.str("title"),
                         subtitle: comp.str("subtitle"), source: comp.str("source"),
                         unit: comp.str("unit") ?? "", highlight: comp.strings("highlight"),
                         framed: true)
    }
}

/// Economist 2017 chart body. `framed` = light panel + red tag + title block
/// (used by MultiChart); BarChart/LineChart in this style draw unframed so they
/// sit inside the card like before.
///
/// Height contract: the chart area is a fixed 180pt like the other charts; the
/// title/subtitle/legend/source rows are text and wrap, so the sizing estimate
/// in MinisUIEngine.estimate() mirrors them.
private struct MUMultiChartBody: View {
    let kind: String
    let labels: [String]
    let series: [String]
    let matrix: [[Double]]
    let title: String?
    let subtitle: String?
    let source: String?
    let unit: String
    let highlight: [String]
    let framed: Bool

    private var palette: [Color] { kind == "stacked" ? MUChartStyle.stacked2017 : MUChartStyle.series2017 }

    private var rows: Int { matrix.count }
    private var cols: Int { min(labels.count, matrix.map(\.count).min() ?? 0) }
    private var hl: Set<String> { Set(highlight) }

    /// Colour of series `s`. A highlight naming series turns the others grey.
    private func color(_ s: Int) -> Color {
        let names = hl.intersection(Set(series))
        if !names.isEmpty, s < series.count, !names.contains(series[s]) { return MUChartStyle.other2017 }
        return palette[s % palette.count]
    }

    /// Colour of one bar. A highlight naming labels keeps those at the series
    /// colour (cyan for the emphasised bar in the guide's "1 trace with highlight").
    private func barColor(series s: Int, index i: Int) -> Color {
        let marked = hl.intersection(Set(labels))
        if rows == 1, !marked.isEmpty {
            return marked.contains(labels[i]) ? MUChartStyle.series2017[1] : MUChartStyle.series2017[0]
        }
        return color(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if framed {
                Rectangle().fill(MUChartStyle.tag2017).frame(width: 28, height: 4)
                    .padding(.bottom, 2)
                if let t = title {
                    Text(t).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let st = subtitle {
                    Text(st).font(.system(size: 12)).foregroundStyle(MUChartStyle.text2017)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if series.count > 1 { legend }
            chart.frame(height: 180).padding(.top, 4)
            if framed, let src = source {
                Text(src).font(.system(size: 10)).foregroundStyle(MUChartStyle.text2017.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(framed ? 10 : 0)
        .background(framed ? AnyView(RoundedRectangle(cornerRadius: 2).fill(MUChartStyle.panel2017)) : AnyView(Color.clear))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(0..<series.count, id: \.self) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(color(s)).frame(width: 10, height: 3)
                    Text(series[s]).font(.system(size: 11)).foregroundStyle(MUChartStyle.text2017)
                }
            }
        }
    }

    /// Per-mark colours are set explicitly (no foregroundStyle(by:) scale), so a
    /// highlight can recolour single bars and the legend uses the same function.
    private var chart: some View {
        Chart {
            ForEach(0..<rows, id: \.self) { s in
                ForEach(0..<cols, id: \.self) { i in
                    let name = s < series.count ? series[s] : "v"
                    switch kind {
                    case "line":
                        LineMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]), series: .value("s", name))
                            .foregroundStyle(color(s))
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    case "stacked":
                        BarMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]))
                            .foregroundStyle(color(s))
                    default:
                        BarMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]))
                            .foregroundStyle(barColor(series: s, index: i))
                            .position(by: .value("s", name))
                    }
                }
            }
            if kind != "line" {
                RuleMark(y: .value("zero", 0.0)).foregroundStyle(Color.primary).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartXScale(domain: labels)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6)).foregroundStyle(MUChartStyle.grid2017)
                AxisValueLabel().foregroundStyle(MUChartStyle.text2017)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(MUChartStyle.text2017)
                AxisValueLabel().foregroundStyle(MUChartStyle.text2017)
            }
        }
    }
}

private struct MUButton: View {
    let comp: MUComp
    let ctx: MUContext
    var body: some View {
        let primary = comp.str("style") != "secondary"
        Button {
            if let a = comp.action { ctx.run(a) }
        } label: {
            Text(comp.str("label") ?? "")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(primary ? Color.white : Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary ? Color.accentColor : Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct MUSquareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .frame(width: 30, height: 30)
            .foregroundStyle(enabled ? Color.accentColor : .secondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
    }
}

private struct MUCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label
                    .strikethrough(false)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
