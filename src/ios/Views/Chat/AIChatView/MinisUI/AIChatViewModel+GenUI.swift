//
//  AIChatViewModel+GenUI.swift
//  Minis
//
//  [MOD genui] The `show_ui` tool in the agent loop: definition, the system
//  prompt section that teaches Minis UI Lang, and execution (validate → the
//  card shows, or the errors go back to the model to fix).
//

import Foundation

enum MinisUISettings {
    /// Settings key; default ON in this MOD build.
    static let key = "agent.tools.genui.enabled"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

extension AIChatViewModel {

    /// Exposed only in the main conversation: a sub agent's cards would be
    /// in a hidden session nobody looks at.
    var genuiExposed: Bool { MinisUISettings.enabled && !isHelper }

    static var genuiToolDefinition: AgentToolDefinition {
        AgentToolDefinition(
            name: MinisUITool.name,
            description: "Render an interactive native card in the chat (calculators with adjustable inputs, quizzes, comparisons, checklists, charts). Write the card as a Minis UI Lang program; the language is described in the system prompt's show_ui section. The card is validated before it is shown: if the result says it was not rendered, fix the listed errors and call show_ui again with the full program.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of the card, shown to the user. Use the same language as the user."),
                "program": AgentToolParam(type: .string, description: "The Minis UI Lang program: one `name = Expression` statement per line, entry statement `root`."),
            ],
            required: ["program"],
            propertyOrdering: ["tool_title", "program"]
        )
    }

    /// The system-prompt section (empty when the tool is not in this run).
    var genuiSystemPromptText: String {
        genuiExposed ? MinisUIPrompt.section : ""
    }

    /// Validate the program; on success the block draws the card.
    func executeShowUI(args: [String: Any], msgIdx: Int, blockIdx: Int) -> (output: String, success: Bool) {
        let program = (args["program"] as? String) ?? ""
        guard !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Error: `program` is required: call show_ui again with a Minis UI Lang program.", false)
        }
        let v = MinisUIEngine.validate(program)
        let out = MinisUIEngine.feedback(v)
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            let block = messages[msgIdx].blocks[blockIdx]
            block.kind = .genuiTool
            block.content = out
        }
        AppLogger(category: "GenUI").info("[GenUI] show_ui ok=\(v.ok) components=\(v.components) inputs=\(v.inputs) buttons=\(v.buttons) errors=\(v.errors.count) warnings=\(v.warnings.count)")
        CrashBreadcrumbs.record("genui.show", detail: "ok=\(v.ok ? 1 : 0) c=\(v.components) e=\(v.errors.count)")
        return (out, v.ok)
    }
}

enum MinisUIPrompt {
    static let section: String = {
        func sig(_ name: String) -> String {
            let args = (MinisUILibrary.components[name] ?? []).map { a -> String in
                let t: String
                switch a.type {
                case .oneOf(let xs): t = xs.map { "\"\($0)\"" }.joined(separator: " | ")
                case .binding: t = "$var"
                default: t = a.type.label
                }
                return "\(a.name)\(a.required ? "" : "?"): \(t)"
            }
            return "\(name)(\(args.joined(separator: ", ")))"
        }
        let docs: [(String, String)] = [
            ("Card", "Rounded container. The usual top-level element."),
            ("Stack", "Vertical group."),
            ("Row", "Horizontal group, children share the width equally. Max 3 children; phone screens are narrow."),
            ("Divider", "Thin horizontal line."),
            ("Title", "Heading."),
            ("Text", "Paragraph. Supports **bold** only."),
            ("Metric", "Big number with a label, e.g. Metric(\"月供\", \"¥5,368\")."),
            ("Badge", "Small pill label."),
            ("List", "Bulleted (or numbered) list."),
            ("Callout", "Highlighted box, e.g. quiz feedback or a warning."),
            ("Slider", "Numeric slider bound to $var."),
            ("Stepper", "−/+ integer control bound to $var (counts such as people, servings)."),
            ("Segmented", "2–4 short options in one row; $var holds the selected option text."),
            ("Toggle", "On/off switch bound to a boolean $var. Also use for checklists."),
            ("Choice", "Vertical list of tappable options (quiz answers); $var holds the chosen option text, \"\" = none yet."),
            ("Table", "Table. rows = array of arrays of text. Keep to ≤4 columns."),
            ("BarChart", "Bar chart, one series. highlight = label texts of the bars to emphasise (the others turn grey in the Economist chart style); use it to point at the one thing the reader should notice, e.g. the latest or the largest."),
            ("LineChart", "Line chart, one series. highlight = label texts of the points to mark with a dot; leave out for a plain line."),
            ("MultiChart", "Chart with 2–6 series, a legend, subtitle and source line. kind \"line\" (trends over time), \"bar\" (side-by-side bars) or \"stacked\" (parts of a whole). series = one name per row of values; values = number[][] with one row per series, each row as long as labels. Use title for a short headline that states the point, subtitle for what is measured with units, source for the data source. highlight = label or series texts to emphasise (others turn grey). Prefer this over BarChart/LineChart when comparing several series. Do not use more than 4 series if you can avoid it."),
            ("Button", "Runs an action when tapped."),
        ]
        let comps = docs.map { "- \(sig($0.0)) — \($0.1)" }.joined(separator: "\n")
        return """

        ## show_ui — interactive answers

        Call the `show_ui` tool when an interactive or visual element genuinely helps:
        calculators with adjustable inputs, quizzes and practice questions (always use
        Choice so the user can answer by tapping), comparisons, plans with options,
        checklists, charts of given data. Do NOT use it for plain explanations, writing,
        translation, code, or casual chat — answer those in normal text.
        Write a short normal-text answer as well; the card complements it.
        A button's @ToAssistant message arrives as the user's next message, followed by
        a hidden note with the card's values.

        The `program` argument uses Minis UI Lang (a subset of OpenUI Lang):

        Rules
        1. One statement per line: `name = Expression`. The entry statement is `root`.
        2. Arguments are positional, in the order shown. Use `null` to skip an optional one.
        3. `$name = literal` declares state. Inputs bind to it; every expression that
           uses `$name` recomputes when it changes. No other code runs.
        4. Expressions: "strings", numbers, true/false, null, [arrays], {objects},
           references to other statements, a.b member access, + - * / %, == != > < >= <=,
           && || !, cond ? a : b. String + number concatenates.
        5. Functions and actions need the `@` prefix. Only those listed below exist.
        6. Forward references are fine. Write top-down: root first, then parts, then data.
        7. No loops: write repeated items out explicitly.
        8. Labels in the user's language. Phone screen: keep it compact.
        9. Segmented/Choice: the $var holds the option TEXT exactly as written in the
           options list (e.g. `$days = "3天"`, options ["3天", "5天"]), never an index.
        10. Put the program only in the tool argument, never in your text reply.

        Components
        \(comps)

        Functions
        - @Round(n, decimals?) → number
        - @Format(n, decimals?) → string with thousands separators, e.g. @Format(12345.6, 1) = "12,345.6"
        - @Pow(base, exp) → number
        - @Sum(numbers[]) → number
        - @Avg(numbers[]) → number
        - @Min(numbers[]) or @Min(a, b, …) → number
        - @Max(numbers[]) or @Max(a, b, …) → number
        - @Count(array) → number
        - @Abs(n)
        - @Floor(n)
        - @Ceil(n)
        - @At(array, index) → element (0-based)
        - @Join(array, separator) → string

        Actions (Button only)
        - @ToAssistant(message, context?) — send a message to you (the assistant) as the user's next turn; context = object with the relevant values
        - @Set($var, value) — set state
        - @Reset($a, $b, …) — restore declared defaults
        - @Copy(text) — copy to clipboard
        - @OpenUrl(url) — open a web page

        Example
        root = Card([title, seats, total, ask], "团队方案")
        title = Text("拖动滑块查看每月费用", "secondary")
        $seats = 8
        seats = Slider("人数", $seats, 1, 50, 1, "人")
        price = $seats * 29
        total = Metric("每月", "$" + @Format(price), $seats >= 20 ? "已含 10% 批量折扣" : null)
        ask = Button("按这个人数出方案", @ToAssistant("按 " + $seats + " 人出方案", {seats: $seats}))

        """
    }()
}
