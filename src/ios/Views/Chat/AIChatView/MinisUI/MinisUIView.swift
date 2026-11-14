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
    @Environment(\.colorScheme) private var surfaceScheme


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
                    .modifier(MUReadableText(color: ChatColors.secondaryText))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .modifier(MURootSurface())
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
    /// [T-chart-label-physical] Real advance width of `text` in the system font
    /// a label is drawn in. SwiftUI's `.system(size:weight:)` is UIKit's
    /// system font of the same size/weight, so this is the width the glyphs
    /// will occupy — no per-class estimate involved.
    static func textWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w * 100) / 100
    }

    static func tone(_ t: String?) -> Color {
        switch t {
        case "accent", "info": return ChatColors.tint
        case "success": return ChatColors.success
        case "warning": return ChatColors.warning
        case "danger": return ChatColors.danger
        case "secondary": return ChatColors.secondaryText
        default: return ChatColors.primaryText
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
                .modifier(MUReadableText(color: ChatColors.primaryText))
                .fixedSize(horizontal: false, vertical: true)
        case "Text":
            Text(MUStyle.inline(comp.str("text") ?? ""))
                .font(.system(size: 14))
                .modifier(MUReadableText(color: MUStyle.tone(comp.str("tone"))))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case "Metric": MUMetric(comp: comp)
        case "Badge":
            let tone = comp.str("tone") ?? "neutral"
            let c = tone == "neutral" ? ChatColors.secondaryText : MUStyle.tone(tone)
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
        case "BlockMap", "GeoMap": MUMapView(comp: comp)
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

    // All Cards retain the same outer plane, including chart-only output.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = comp.str("title") {
                MUCardTitle(title: t)
            }
            ForEach(Array(comp.children.enumerated()), id: \.offset) { _, c in MUNodeView(comp: c, ctx: ctx) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(MUCardSurface(fill: topLevel ? ChatColors.secondaryBg : Color.primary.opacity(0.04),
                                nativeFill: topLevel ? ChatColors.secondaryBgUIColor : UIColor.label.withAlphaComponent(0.04)))
    }
}

private struct MUMetric: View {
    let comp: MUComp
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(comp.str("label") ?? "").font(.system(size: 12)).modifier(MUReadableText(color: ChatColors.secondaryText))
            Text(comp.str("value") ?? "")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if let n = comp.str("note") {
                Text(n).font(.system(size: 12)).modifier(MUReadableText(color: ChatColors.secondaryText))
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
                    Text(ordered ? "\(i + 1)." : "•").font(.system(size: 14)).modifier(MUReadableText(color: ChatColors.secondaryText))
                    Text(MUStyle.inline(item)).font(.system(size: 14)).modifier(MUReadableText(color: ChatColors.primaryText)).fixedSize(horizontal: false, vertical: true)
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
                .modifier(MUReadableText(color: ChatColors.primaryText))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MUCardSurface(fill: c.opacity(0.10), cornerRadius: 10, bordered: false))
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
                Text(comp.str("label") ?? "").font(.system(size: 13)).modifier(MUReadableText(color: ChatColors.secondaryText))
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
                        .modifier(MUReadableText(color: ChatColors.primaryText))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? ChatColors.inputBg : .clear)
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
                            .foregroundStyle(on ? ChatColors.tint : ChatColors.secondaryText)
                        Text(MUStyle.inline(opt)).font(.system(size: 14)).modifier(MUReadableText(color: ChatColors.primaryText))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? ChatColors.tint.opacity(0.12) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? ChatColors.tint.opacity(0.6) : .clear, lineWidth: 1))
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
struct MUChartDrawing {
    static let weightKey = "genuiChartStrokeWeight"
    static let dashKey = "genuiChartLinePattern"
    let weight: String
    let pattern: String
    var multiplier: CGFloat { weight == "fine" ? 0.8 : (weight == "bold" ? 1.4 : 1) }
    func width(_ base: CGFloat) -> CGFloat { base * multiplier }
    func dash(context: Bool = false) -> [CGFloat] {
        pattern == "dashed" || (pattern == "context" && context) ? [5, 3] : []
    }
}

/// A real production card, not an illustration: appearance controls update the
/// same AppStorage readers used by existing conversations, without changing data.
struct MUChartSettingsPreview: View {
    var body: some View {
        let p = MUProgram.parse("root = Card([Text(\"App theme text\"), LineChart([\"Jan\", \"Feb\", \"Mar\"], [2, 5, 3])], \"Chart preview\")")
        let defaults = p.defaultState().0
        if let root = p.render(defaults).0 {
            MUNodeView(comp: root, ctx: MUContext(state: defaults, program: p, defaults: defaults,
                set: { _, _, _ in }, commit: {}, run: { _ in }), topLevel: true)
                .modifier(MURootSurface())
        }
    }
}

enum MUChartStyle {
    static let key = "genuiChartPalette"
    static let economist = "economist"
    /// The Economist visual styleguide v1.2 (4 May 2017): blue/cyan/gold series
    /// on a white web panel, red tag and a thin red top rule.
    static let economist2017 = "economist2017"

    static func hex(_ rgb: UInt32, dark: UInt32? = nil) -> Color {
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
    /// Recent-chart look (sampled from 2024-26 charts, not an official palette):
    /// red, salmon, dark red, warm greys, the one blue. Used for multi-series.
    static let seriesRecent: [Color] = [
        red, grey,
        hex(0xF8A290, dark: 0xF8A290),  // salmon
        hex(0x4A4C4E, dark: 0xC9C9BE),  // dark grey
        hex(0xBE191F, dark: 0xE0525E),  // dark red
        hex(0x3651A3, dark: 0x7C92D6),  // the one blue
    ]
    static let panelRecent = hex(0xF1EFEA, dark: 0x262624)
    static let gridRecent = hex(0xD1D0C6, dark: 0x45443F)
    static let textRecent = hex(0x4A4C4E, dark: 0xB6B6A9)

    /// White web panel (2017 p3), grid, text, red tag; dark mode adapted.
    static let panel2017 = hex(0xFFFFFF, dark: 0x161B1F)
    static let grid2017 = hex(0xB7C6CF, dark: 0x3A474F)
    static let text2017 = hex(0x3F5661, dark: 0xB7C6CF)
    static let tag2017 = hex(0xE3120B, dark: 0xE3120B)
    /// Grey for "other" / context (web palette grey).
    static let other2017 = hex(0x758D99, dark: 0x8FA3AD)

    /// Accent ramp for *highlighted* series, assigned in data order
    /// (`MUChartEmphasis`). 2017: blue → dark cyan → gold, i.e. the guide's own
    /// first/second/third colour, so an emphasised line can never be confused
    /// with the grey context lines. Deliberately not the dark-red stand-in
    /// #A81829, whose value is intentionally unchanged.
    static let accent2017: [Color] = [
        hex(0x006BA2, dark: 0x4D9FD1),
        hex(0x005F73, dark: 0x4EC8DE),
        hex(0xEBB434, dark: 0xF2C85E),
    ]

    /// Recent look: main red → dark red → the one blue sampled from 2024-26
    /// charts (a sample, not an official palette).
    static let accentRecent: [Color] = [
        red,
        hex(0xBE191F, dark: 0xE0525E),
        hex(0x3651A3, dark: 0x7C92D6),
    ]

    /// System look: semantic colours that adapt to light/dark on their own.
    static let accentSystem: [Color] = [.blue, .teal, .indigo]

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

/// Three complete theme presets share one geometry/rendering skeleton.
/// Official web colours: 2017 v1.2 p12; dark mode and SF fonts are adaptations.
enum MUChartLook { case system, recent, guide2017 }
struct MUChartTheme {
    let fonts: MUChartFontScale = .phone
    let look: MUChartLook
    let panel: Color
    let grid: Color
    let gridWidth: CGFloat
    let zero: Color
    let zeroWidth: CGFloat
    let tag: Color
    let topRule: Color
    let title: Color
    let subtitle: Color
    let source: Color
    let axis: Color
    let series: [Color]
    let accents: [Color]
    let context: Color
    let scales: [[Color]]
    enum LegendStyle { case shortLine, square }
    func legendStyle(for kind: String) -> LegendStyle { kind == "line" ? .shortLine : .square }

    static func current(for value: String) -> Self {
        let source = MUChartStyle.hex(0x404040, dark: 0xBFBFBF) // 75% black / inverted
        switch value {
        case MUChartStyle.economist2017:
            return Self(look: .guide2017, panel: MUChartStyle.panel2017,
                        grid: MUChartStyle.grid2017, gridWidth: 0.5,
                        zero: MUChartStyle.tag2017, zeroWidth: 1,
                        tag: MUChartStyle.tag2017, topRule: MUChartStyle.tag2017,
                        title: MUChartStyle.hex(0x0C0C0C, dark: 0xF3F3F3),
                        subtitle: MUChartStyle.text2017, source: source, axis: MUChartStyle.text2017,
                        series: MUChartStyle.series2017, accents: MUChartStyle.accent2017,
                        context: MUChartStyle.other2017, scales: guideScales)
        case MUChartStyle.economist:
            return Self(look: .recent, panel: MUChartStyle.panelRecent,
                        grid: MUChartStyle.gridRecent, gridWidth: 0.5,
                        zero: .primary, zeroWidth: 1.5, tag: MUChartStyle.red, topRule: .clear,
                        title: .primary, subtitle: MUChartStyle.textRecent, source: source,
                        axis: MUChartStyle.textRecent, series: MUChartStyle.seriesRecent,
                        accents: MUChartStyle.accentRecent, context: MUChartStyle.grey,
                        scales: [[0xBE191F, 0xD32924, 0xE62923, 0xEE6552, 0xF8A290, 0xFAD0C6].map { MUChartStyle.hex($0) }])
        default:
            return Self(look: .system, panel: Color.primary.opacity(0.04),
                        grid: Color.primary.opacity(0.12), gridWidth: 0.5,
                        zero: Color.secondary.opacity(0.6), zeroWidth: 0.5,
                        tag: .clear, topRule: .clear, title: .primary, subtitle: .secondary,
                        source: source, axis: .secondary,
                        series: [.blue, .orange, .green, .red, .purple, .teal],
                        accents: MUChartStyle.accentSystem, context: .gray,
                        scales: [[.blue.opacity(1), .blue.opacity(0.85), .blue.opacity(0.7),
                                  .blue.opacity(0.55), .blue.opacity(0.4), .blue.opacity(0.25)]])
        }
    }
    /// All nine official web equal-lightness ramps, six levels, deep → light.
    /// The selection of a ramp is not model-exposed in Phase 1.
    static let guideScales: [[Color]] = [
        [0xA81829,0xC7303C,0xE64E53,0xFF6B6C,0xFF8785,0xFFA39F],
        [0x00588D,0x1270A8,0x3D89C3,0x5DA4DF,0x7BBFFC,0x98DAFF],
        [0x005F73,0x00788D,0x0092A7,0x25ADC2,0x4EC8DE,0x6FE4FB],
        [0x005F52,0x00786B,0x2E9284,0x4DAD9E,0x69C9B9,0x86E5D4],
        [0x714C00,0x8D6300,0xAA7C00,0xC89608,0xE7B030,0xFFCB4D],
        [0x4C5900,0x667100,0x818A00,0x9DA521,0xBAC03F,0xD7DB5A],
        [0x78405F,0x925977,0xAD7291,0xC98CAC,0xE6A6C7,0xFFC2E3],
        [0x674E1F,0x826636,0x9D7F4E,0xB99966,0xD5B480,0xF2CF9A],
        [0x3F5661,0x576E79,0x6F8793,0x89A2AE,0xA4BDC9,0xBFD8E5],
    ].map { $0.map { MUChartStyle.hex(UInt32($0)) } }
}

extension MUChartTheme {
    private static let surfaceLock = NSLock()
    private static var surfaceThemes: [String: Self] = [:]
    static func resolved(for style: String, on surface: MUMapRGB, scheme: ColorScheme) -> Self {
        // Every mark requests its colour. Resolve a preset once per actual
        // surface/trait instead of repeating colour conversion for each mark.
        let key = style + ":" + surface.hex + (scheme == .dark ? ":dark" : ":light")
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        if let cached = surfaceThemes[key] { return cached }
        let theme = current(for: style).adapted(to: surface, scheme: scheme)
        if surfaceThemes.count >= 128 { surfaceThemes.removeAll(keepingCapacity: true) }
        surfaceThemes[key] = theme
        return theme
    }

    func adapted(to surface: MUMapRGB, scheme: ColorScheme) -> Self {
        func text(_ c: Color) -> Color { MUSurface.foreground(c, on: surface, scheme: scheme) }
        func graphic(_ c: Color) -> Color { MUSurface.foreground(c, on: surface, scheme: scheme, minimum: 3) }
        return Self(look: look, panel: .clear, grid: graphic(grid), gridWidth: gridWidth,
            zero: graphic(zero), zeroWidth: zeroWidth,
            tag: look == .system ? .clear : graphic(tag), topRule: look == .guide2017 ? graphic(topRule) : .clear,
            title: text(title), subtitle: text(subtitle), source: text(source), axis: text(axis),
            series: series.map(graphic), accents: accents.map(graphic), context: graphic(context),
            scales: scales.map { $0.map(graphic) })
    }
}

private struct MUChart: View {
    let comp: MUComp
    @AppStorage(MUChartStyle.key) private var palette: String = ""
    var body: some View {
        MUMultiChartBody(look: MUChartTheme.current(for: palette).look,
                         kind: comp.name == "LineChart" ? "line" : "bar",
                         labels: comp.strings("labels"), series: [], matrix: [comp.numbers("values")],
                         title: nil, subtitle: nil, source: nil, unit: comp.str("unit") ?? "",
                         highlight: comp.strings("highlight"), framed: false)
    }
}

private struct MUMultiChart: View {
    let comp: MUComp
    @AppStorage(MUChartStyle.key) private var palette: String = ""
    var body: some View {
        MUMultiChartBody(look: MUChartTheme.current(for: palette).look,
                         kind: comp.str("kind") ?? "line", labels: comp.strings("labels"),
                         series: comp.strings("series"), matrix: comp.matrix("values"),
                         title: comp.str("title"), subtitle: comp.str("subtitle"), source: comp.str("source"),
                         unit: comp.str("unit") ?? "", highlight: comp.strings("highlight"), framed: true)
    }
}

/// Rendered geometry is emitted from the actual ChartProxy plot anchor. The
/// simulator harness consumes this preference; no test-only chart is drawn.
struct MUChartRenderGeometry: Equatable {
    let panelWidth: CGFloat
    let plot: CGRect
    let labelColumn: CGRect
    let axisColumn: CGRect
    let labelBoxes: [CGRect]
    let axisBoxes: [CGRect]
    let gridYs: [CGFloat]
}
struct MUChartRenderGeometryKey: PreferenceKey {
    static var defaultValue: MUChartRenderGeometry? = nil
    static func reduce(value: inout MUChartRenderGeometry?, nextValue: () -> MUChartRenderGeometry?) {
        value = nextValue() ?? value
    }
}

private struct MUMultiChartBody: View {
    typealias Look = MUChartLook
    let look: Look
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

    @AppStorage(MUChartDrawing.weightKey) private var strokeWeight = "standard"
    @AppStorage(MUChartDrawing.dashKey) private var linePattern = "solid"
    private var drawing: MUChartDrawing { MUChartDrawing(weight: strokeWeight, pattern: linePattern) }

    @Environment(\.muSurface) private var inherited
    @Environment(\.colorScheme) private var scheme
    private var surface: MUMapRGB { MUSurface.base(inherited, scheme: scheme) }
    private var theme: MUChartTheme {
        MUChartTheme.resolved(for: look == .guide2017 ? MUChartStyle.economist2017
                                   : (look == .recent ? MUChartStyle.economist : ""), on: surface, scheme: scheme)
    }
    private var rows: Int { matrix.count }
    private var cols: Int { min(labels.count, matrix.map(\.count).min() ?? 0) }
    private var hl: Set<String> { Set(highlight) }
    private var roles: [MUChartRole] { MUChartEmphasis.roles(series: series, highlight: highlight) }
    private var showEndLabels: Bool { kind == "line" && series.count > 1 }
    private func isGreyed(_ s: Int) -> Bool { MUChartEmphasis.isContext(roles, at: s) }
    private func color(_ s: Int) -> Color {
        let palette = theme.series
        guard s >= 0, s < series.count else { return palette[0] }
        if let slot = MUChartEmphasis.slot(roles, at: s) {
            return theme.accents[min(slot, theme.accents.count - 1)]
        }
        if isGreyed(s) || ["其他", "其它", "other", "unknown"].contains(series[s].lowercased()) { return theme.context }
        return palette[s % palette.count]
    }
    private func barColor(series s: Int, index i: Int) -> Color {
        let marked = hl.intersection(Set(labels))
        if rows == 1, !marked.isEmpty {
            if look == .recent { return marked.contains(labels[i]) ? theme.accents[0] : theme.context }
            if look == .system { return marked.contains(labels[i]) ? theme.series[1] : theme.series[0] }
            return marked.contains(labels[i]) ? theme.series[1] : theme.series[0]
        }
        return color(s)
    }
    private var chartHeight: CGFloat { 180 }
    private var lastValues: [Double] { matrix.map { $0.last ?? 0 } }
    private var domain: MUChartDomain {
        kind == "stacked" ? MUChartAxis.stackedDomain(matrix: matrix)
                          : MUChartAxis.domain(values: matrix, includeZero: kind != "line")
    }
    private var ticks: [Double] { MUChartAxis.ticks(domain: domain) }
    private var crossesZero: Bool { domain.lower < 0 && domain.upper > 0 }
    private func axisText(_ value: Double) -> String { MUStyle.numText(value) }
    private func axisWidth(_ value: Double) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: theme.fonts.tick,
                     weight: value == 0 && crossesZero ? .bold : .regular)
        return ceil((axisText(value) as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if framed {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(theme.topRule).frame(height: 0.5)
                    Rectangle().fill(theme.tag).frame(width: 28, height: 4)
                }.frame(height: 6).padding(.horizontal, MUChartColumns.innerInset)
                if let title {
                    Text(title).font(.system(size: theme.fonts.title, weight: .bold))
                        .foregroundStyle(theme.title).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, MUChartColumns.innerInset)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: theme.fonts.subtitle))
                        .foregroundStyle(theme.subtitle).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, MUChartColumns.innerInset)
                }
            }
            if series.count > 1 && !showEndLabels { legend }
            GeometryReader { geo in
                chart(width: geo.size.width)
                if !framed, !unit.isEmpty {
                    Text(unit).font(.system(size: theme.fonts.subtitle)).foregroundStyle(theme.subtitle)
                        .lineLimit(1).frame(width: max(0, geo.size.width - 70), alignment: .leading)
                        .padding(.leading, MUChartColumns.innerInset)
                }
            }.frame(height: chartHeight + MUChartTypography.xAxisHeight + MUChartTypography.plotTop)
            if framed, let source {
                Text(source).font(.system(size: theme.fonts.source)).foregroundStyle(theme.source)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, MUChartColumns.innerInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, framed ? 10 : 2)
        // Transparent within either a Card or the chat; no theme panel fill.
        .coordinateSpace(name: "MUChartPanel")
    }
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(0..<series.count, id: \.self) { s in
                HStack(spacing: 4) {
                    Rectangle().fill(color(s))
                        .frame(width: theme.legendStyle(for: kind) == .shortLine ? 14 : 8,
                               height: theme.legendStyle(for: kind) == .shortLine ? 2 : 8)
                    Text(series[s]).font(.system(size: theme.fonts.legend)).foregroundStyle(theme.subtitle).lineLimit(1)
                }.frame(height: 16, alignment: .leading)
            }
        }.padding(.horizontal, MUChartColumns.innerInset)
    }

    private func chart(width: CGFloat) -> some View {
        let labelWidths = showEndLabels ? series.enumerated().map { s, text in
            MUStyle.textWidth(text, size: 12, bold: !isGreyed(s))
        } : []
        let gutter = MUChartLabelMetrics.gutter(labels: showEndLabels ? series : [], fontSize: 12,
                    available: width, spacing: MUChartColumns.curveGap, gap: MUChartColumns.axisGap,
                    maxFraction: 0.36, widths: labelWidths,
                    measure: { MUStyle.textWidth($0, size: $1, bold: true) })
        let columns = MUChartColumns.layout(width: width, labelWidth: gutter.labelWidth,
                                            axisWidth: ticks.map { axisWidth($0) }.max() ?? 0)
        return Chart {
            ForEach(0..<rows, id: \.self) { s in
                ForEach(0..<cols, id: \.self) { i in
                    let name = s < series.count ? series[s] : "v"
                    switch kind {
                    case "line":
                        LineMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]), series: .value("s", name))
                            .foregroundStyle(color(s))
                            .lineStyle(StrokeStyle(lineWidth: drawing.width(isGreyed(s) ? 2 : 2.5), lineCap: .round, lineJoin: .round, dash: drawing.dash(context: isGreyed(s))))
                    case "stacked":
                        BarMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i])).foregroundStyle(color(s))
                    default:
                        BarMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]))
                            .foregroundStyle(barColor(series: s, index: i))
                            .cornerRadius(look == .system ? 4 : 0).position(by: .value("s", name))
                    }
                    if kind == "line", rows == 1, look == .system, !hl.contains(labels[i]) {
                        PointMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]))
                            .foregroundStyle(color(s))
                    }
                    if kind == "line", rows == 1, hl.contains(labels[i]) {
                        PointMark(x: .value("x", labels[i]), y: .value("y", matrix[s][i]))
                            .foregroundStyle(look == .guide2017 ? theme.series[1] : theme.accents[0]).symbolSize(40)
                    }
                }
            }
        }
        .chartXScale(domain: labels)
        .chartYScale(domain: domain.lower...domain.upper, range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYAxis(.hidden).chartXAxis(.hidden).chartLegend(.hidden)
        .chartBackground { proxy in grid(in: proxy) }
        .chartOverlay { proxy in
            ownedAxes(in: proxy, columns: columns, gutter: gutter)
        }
        .frame(width: columns.plotWidth, height: chartHeight)
        .offset(x: columns.plotMinX, y: MUChartTypography.plotTop)
    }

    /// Both text columns are outside Chart. Their x positions depend ONLY on
    /// MUChartColumns, never on lastX, plot padding, or native axis placement.
    private func ownedAxes(in proxy: ChartProxy, columns: MUChartColumns,
                           gutter: MUChartLabelMetrics.Gutter) -> some View {
        GeometryReader { geo in
            let frame = geo[proxy.plotAreaFrame]
            let size = gutter.fontSize
            let baseY = lastValues.map { value in
                proxy.position(forY: value) ?? MUChartAxis.pixelY(value, domain: domain, height: frame.height)
            }
            let placements = showEndLabels ? MUChartEndLabels.layout(values: lastValues, domain: domain,
                plotHeight: frame.height, minGap: size + 3, edgeInset: size * 0.75, baseY: baseY) : []
            let labelX = columns.labelMinX - columns.plotMinX
            let axisX = columns.axisMinX - columns.plotMinX
            // The snapshot uses ACTUAL plot bounds and the exact boxes rendered
            // below. The host adds the Chart's explicit offset to panel space.
            let origin = geo.frame(in: .named("MUChartPanel")).origin
            let gridYs = ticks.map { value in
                frame.minY + (proxy.position(forY: value)
                    ?? MUChartAxis.pixelY(value, domain: domain, height: frame.height))
            }
            // SwiftUI position is the frame CENTER, not its top edge. No
            // optical offset: keep the 14pt digit box centered on its grid.
            let axisBoxes = gridYs.map { y in
                CGRect(x: axisX, y: y - 7, width: columns.axisWidth, height: 14)
            }
            let snapshot = MUChartRenderGeometry(panelWidth: columns.width,
                plot: frame.offsetBy(dx: origin.x, dy: origin.y),
                labelColumn: CGRect(x: columns.labelMinX, y: origin.y + frame.minY, width: columns.labelWidth, height: frame.height),
                axisColumn: CGRect(x: columns.axisMinX, y: origin.y + frame.minY, width: columns.axisWidth, height: frame.height),
                labelBoxes: placements.map { p in CGRect(x: columns.labelMinX,
                    y: origin.y + frame.minY + p.centerY - size * 0.65, width: columns.labelWidth, height: size * 1.3) },
                axisBoxes: axisBoxes.map { $0.offsetBy(dx: origin.x, dy: origin.y) },
                gridYs: gridYs.map { $0 + origin.y })
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, value in
                    let box = axisBoxes[index]
                    Text(axisText(value))
                        .font(.system(size: theme.fonts.tick, weight: value == 0 && crossesZero ? .bold : .regular))
                        .monospacedDigit().foregroundStyle(theme.axis)
                        .frame(width: box.width, height: box.height, alignment: .trailing)
                        .position(x: box.midX, y: box.midY)
                }
                ForEach(placements, id: \.index) { p in
                    if p.index < gutter.labels.count {
                        Text(gutter.labels[p.index])
                            .font(.system(size: size, weight: isGreyed(p.index) ? .regular : .bold))
                            .foregroundStyle(MUSurface.foreground(color(p.index), on: surface, scheme: scheme)).lineLimit(1)
                            .frame(width: columns.labelWidth, height: size * 1.3, alignment: .leading)
                            .clipped()
                            .position(x: labelX + columns.labelWidth / 2, y: frame.minY + p.centerY)
                    }
                }
                Path { path in
                    path.move(to: CGPoint(x: frame.minX, y: frame.maxY))
                    path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
                }.stroke(theme.axis, lineWidth: drawing.width(0.5))
                ForEach(Array(labels.prefix(cols).enumerated()), id: \.offset) { i, text in
                    if i % max(1, Int(ceil(Double(cols) / 5))) == 0 || i == cols - 1 {
                        let x = frame.minX + (proxy.position(forX: text) ?? 0)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: frame.maxY))
                            path.addLine(to: CGPoint(x: x, y: frame.maxY + 5))
                        }.stroke(theme.axis, lineWidth: drawing.width(0.5))
                        Text(text).font(.system(size: theme.fonts.tick)).monospacedDigit()
                            .foregroundStyle(theme.axis).lineLimit(1)
                            .frame(width: min(44, frame.width / 3), height: 14)
                            .position(x: min(max(x, frame.minX + 22), frame.maxX - 22), y: frame.maxY + 14)
                    }
                }
            }
            .preference(key: MUChartRenderGeometryKey.self, value: snapshot)
        }.allowsHitTesting(false)
    }

    private func grid(in proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let frame = geo[proxy.plotAreaFrame]
            ForEach(ticks, id: \.self) { value in
                let y = frame.minY + (proxy.position(forY: value)
                    ?? MUChartAxis.pixelY(value, domain: domain, height: frame.height))
                Path { path in
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }.stroke(value == 0 && crossesZero ? theme.zero : theme.grid,
                         lineWidth: drawing.width(value == 0 && crossesZero ? theme.zeroWidth : theme.gridWidth))
            }
        }.allowsHitTesting(false)
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
                .foregroundStyle(primary ? ChatColors.onTint : ChatColors.tint)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary ? ChatColors.tint : ChatColors.tint.opacity(0.12)))
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
            .foregroundStyle(enabled ? ChatColors.tint : ChatColors.secondaryText)
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
                    .foregroundStyle(configuration.isOn ? ChatColors.tint : ChatColors.secondaryText)
                configuration.label
                    .strikethrough(false)
                    .modifier(MUReadableText(color: ChatColors.primaryText))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
