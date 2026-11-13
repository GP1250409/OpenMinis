//
//  MinisUICore.swift
//  Minis
//
//  [MOD genui] Minis UI Lang — the language behind the `show_ui` tool: the
//  model writes a small program, the app draws it with native components.
//
//  A strict subset of OpenUI Lang 1.0 (thesysdev/openui, MIT): one
//  `name = Expression` per line, entry `root`, `$state` two-way bound to
//  inputs, `@Functions` and `@Actions`. No loops, no JavaScript, no network.
//
//  Pure Foundation on purpose: this file is compiled on Linux and checked
//  against the Python reference implementation (shared/minismod/
//  genui-20261109/minisui.py) on the same programs. Keep the two in step:
//  same component library, same error codes, same evaluation rules.
//

import Foundation

// MARK: - Values

final class MUComp {
    let name: String
    var props: [String: MUValue]
    let line: Int
    init(name: String, props: [String: MUValue], line: Int) {
        self.name = name; self.props = props; self.line = line
    }
    var children: [MUComp] {
        if case .arr(let xs)? = props["children"] { return xs.compactMap { if case .comp(let c) = $0 { return c }; return nil } }
        return []
    }
    func str(_ k: String) -> String? { if case .str(let s)? = props[k] { return s }; return nil }
    func num(_ k: String) -> Double? { if case .num(let d)? = props[k] { return d }; return nil }
    func bool(_ k: String) -> Bool? { if case .bool(let b)? = props[k] { return b }; return nil }
    func strings(_ k: String) -> [String] {
        if case .arr(let xs)? = props[k] { return xs.compactMap { if case .str(let s) = $0 { return s }; return nil } }
        return []
    }
    func numbers(_ k: String) -> [Double] {
        if case .arr(let xs)? = props[k] { return xs.compactMap { if case .num(let d) = $0 { return d }; return nil } }
        return []
    }
    func matrix(_ k: String) -> [[Double]] {
        if case .arr(let xs)? = props[k] {
            return xs.map { r in if case .arr(let ys) = r { return ys.compactMap { if case .num(let d) = $0 { return d }; return nil } }; return [] }
        }
        return []
    }
    func rows(_ k: String) -> [[String]] {
        if case .arr(let xs)? = props[k] {
            return xs.map { r in if case .arr(let cs) = r { return cs.compactMap { if case .str(let s) = $0 { return s }; return nil } }; return [] }
        }
        return []
    }
    var action: MUAction? { if case .action(let a)? = props["action"] { return a }; return nil }
}

struct MUStep {
    let name: String
    let args: [MUNode]
    let line: Int
}

final class MUAction {
    let steps: [MUStep]
    init(_ steps: [MUStep]) { self.steps = steps }
}

indirect enum MUValue {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([MUValue])
    case obj([String: MUValue])
    case comp(MUComp)
    case action(MUAction)

    var isNull: Bool { if case .null = self { return true }; return false }

    static func eq(_ a: MUValue, _ b: MUValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.num(let x), .num(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.arr(let x), .arr(let y)): return x.count == y.count && zip(x, y).allSatisfy { eq($0, $1) }
        case (.obj(let x), .obj(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { eq(v, $0) } ?? false }
        case (.comp(let x), .comp(let y)): return x === y
        case (.action(let x), .action(let y)): return x === y
        default: return false
        }
    }

    /// Plain JSON for state persistence and for messages back to the model.
    var json: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .num(let d): return (d == d.rounded() && abs(d) < 1e15) ? Int64(d) as Any : d as Any
        case .str(let s): return s
        case .arr(let xs): return xs.map(\.json)
        case .obj(let o): return o.mapValues(\.json)
        case .comp, .action: return NSNull()
        }
    }

    static func fromJSON(_ any: Any) -> MUValue {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too; their
            // objCType is "c" (char) on both Darwin and Linux Foundation.
            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
            return .num(n.doubleValue)
        case let b as Bool: return .bool(b)
        case let d as Double: return .num(d)
        case let i as Int: return .num(Double(i))
        case let s as String: return .str(s)
        case let a as [Any]: return .arr(a.map(fromJSON))
        case let o as [String: Any]: return .obj(o.mapValues(fromJSON))
        default: return .null
        }
    }
}

enum MUMember {
    case name(String)
    case index(Int)
}

indirect enum MUNode {
    case lit(MUValue)
    case arr([MUNode])
    case obj([(String, MUNode)])
    case ref(String, Int)
    case state(String)
    case comp(String, [MUNode], Int)
    case call(String, [MUNode], Int)
    case action([MUNode], Int)
    case named(String, MUNode)
    case bin(String, MUNode, MUNode)
    case un(String, MUNode)
    case tern(MUNode, MUNode, MUNode)
    case mem(MUNode, MUMember)
    case idx(MUNode, MUNode)

    var isConst: Bool {
        switch self {
        case .lit: return true
        case .un(let op, let a): return op == "-" && a.isConst
        case .arr(let xs): return xs.allSatisfy(\.isConst)
        case .obj(let kv): return kv.allSatisfy { $0.1.isConst }
        default: return false
        }
    }
}

struct MUError: Hashable {
    let code: String
    let line: Int
    let msg: String
}

struct MURuntimeError: Error {
    let msg: String
    init(_ m: String) { msg = m }
}

// MARK: - Component library

enum MUType {
    case string, number, bool, text, strings, numbers, matrix, rows, component, components, binding, action
    case oneOf([String])

    var label: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .text: return "text"
        case .strings: return "string[]"
        case .numbers: return "number[]"
        case .matrix: return "number[][]"
        case .rows: return "rows"
        case .component: return "component"
        case .components: return "component[]"
        case .binding: return "binding"
        case .action: return "action"
        case .oneOf(let xs): return "enum:" + xs.joined(separator: "|")
        }
    }
}

struct MUArg {
    let name: String
    let type: MUType
    let required: Bool
    init(_ name: String, _ type: MUType, _ required: Bool) {
        self.name = name; self.type = type; self.required = required
    }
}

enum MinisUILibrary {
    static let components: [String: [MUArg]] = [
        "Card": [MUArg("children", .components, true), MUArg("title", .string, false)],
        "Stack": [MUArg("children", .components, true), MUArg("gap", .oneOf(["s", "m", "l"]), false)],
        "Row": [MUArg("children", .components, true)],
        "Divider": [],
        "Title": [MUArg("text", .text, true), MUArg("size", .oneOf(["s", "m", "l"]), false)],
        "Text": [MUArg("text", .text, true),
                 MUArg("tone", .oneOf(["primary", "secondary", "accent", "success", "warning", "danger"]), false)],
        "Metric": [MUArg("label", .string, true), MUArg("value", .text, true), MUArg("note", .text, false)],
        "Badge": [MUArg("text", .text, true), MUArg("tone", .oneOf(["neutral", "info", "success", "warning", "danger"]), false)],
        "List": [MUArg("items", .strings, true), MUArg("ordered", .bool, false)],
        "Callout": [MUArg("text", .text, true), MUArg("tone", .oneOf(["info", "success", "warning", "danger"]), false)],
        "Slider": [MUArg("label", .string, true), MUArg("value", .binding, true), MUArg("min", .number, true),
                   MUArg("max", .number, true), MUArg("step", .number, false), MUArg("unit", .string, false)],
        "Stepper": [MUArg("label", .string, true), MUArg("value", .binding, true), MUArg("min", .number, true),
                    MUArg("max", .number, true), MUArg("step", .number, false)],
        "Segmented": [MUArg("value", .binding, true), MUArg("options", .strings, true)],
        "Toggle": [MUArg("label", .string, true), MUArg("value", .binding, true)],
        "Choice": [MUArg("value", .binding, true), MUArg("options", .strings, true)],
        "Table": [MUArg("headers", .strings, true), MUArg("rows", .rows, true)],
        "BarChart": [MUArg("labels", .strings, true), MUArg("values", .numbers, true), MUArg("unit", .string, false),
                      MUArg("highlight", .strings, false)],
        "LineChart": [MUArg("labels", .strings, true), MUArg("values", .numbers, true), MUArg("unit", .string, false),
                      MUArg("highlight", .strings, false)],
        // 2017 Economist-style multi-series chart (new; BarChart/LineChart unchanged).
        // kind: line | bar | stacked. series[i] names the row values[i].
        "MultiChart": [MUArg("kind", .oneOf(["line", "bar", "stacked"]), true),
                       MUArg("labels", .strings, true), MUArg("series", .strings, true),
                       MUArg("values", .matrix, true), MUArg("title", .string, false),
                       MUArg("subtitle", .string, false), MUArg("source", .string, false),
                       MUArg("unit", .string, false), MUArg("highlight", .strings, false)],
        "Button": [MUArg("label", .string, true), MUArg("action", .action, true),
                   MUArg("style", .oneOf(["primary", "secondary"]), false)],
    ]
    static let functions: Set<String> = ["Round", "Format", "Pow", "Sum", "Avg", "Min", "Max", "Count",
                                         "Abs", "Floor", "Ceil", "At", "Join"]
    static let actions: Set<String> = ["ToAssistant", "Set", "Reset", "Copy", "OpenUrl"]
    static let inputs: Set<String> = ["Slider", "Stepper", "Segmented", "Toggle", "Choice"]

    static let maxStatements = 120
    static let maxDepth = 8
    static let maxNodes = 150
    static let maxTableRows = 60
    static let maxRowChildren = 3
    static let maxChartPoints = 60
}

// MARK: - Lexer

private struct MUTok {
    enum Kind { case num, str, id, state, at, op, nl, eof }
    let kind: Kind
    var s: String = ""
    var d: Double = 0
    let line: Int

    var repr: String {
        switch kind {
        case .num: return MUFormat.pyFloat(d)
        case .str, .id, .state, .at, .op: return "'\(s)'"
        case .nl, .eof: return "None"
        }
    }
}

private struct MULexError: Error {
    let msg: String
    let line: Int
}

private enum MULexer {
    static let ops = ["==", "!=", ">=", "<=", "&&", "||", "+", "-", "*", "/", "%", ">", "<", "!", "?", ":",
                      "(", ")", "[", "]", "{", "}", ",", ".", "="].map { Array($0.unicodeScalars) }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
    static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) || c == "_"
    }
    static func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }

    static func lex(_ src: String) throws -> [MUTok] {
        let s = Array(src.unicodeScalars)
        let n = s.count
        var toks: [MUTok] = []
        var i = 0, line = 1, depth = 0
        func starts(_ p: [Unicode.Scalar], _ at: Int) -> Bool {
            guard at + p.count <= n else { return false }
            for k in 0..<p.count where s[at + k] != p[k] { return false }
            return true
        }
        while i < n {
            let c = s[i]
            if c == "\n" {
                if depth == 0 { toks.append(MUTok(kind: .nl, line: line)) }
                line += 1; i += 1; continue
            }
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            if c == "/" && i + 1 < n && s[i + 1] == "/" {
                while i < n && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" || c == "\u{201C}" {
                // An ASCII quote closes only on the same quote, so Chinese
                // “引号” inside text stay literal; a curly open closes on ”.
                let close: Unicode.Scalar = c == "\u{201C}" ? "\u{201D}" : c
                var j = i + 1
                var buf = String.UnicodeScalarView()
                while j < n && s[j] != close {
                    if s[j] == "\\" && j + 1 < n {
                        let nx = s[j + 1]
                        if nx == "n" { buf.append("\n") } else if nx == "t" { buf.append("\t") } else { buf.append(nx) }
                        j += 2; continue
                    }
                    if s[j] == "\n" { throw MULexError(msg: "unterminated string", line: line) }
                    buf.append(s[j]); j += 1
                }
                if j >= n { throw MULexError(msg: "unterminated string", line: line) }
                toks.append(MUTok(kind: .str, s: String(buf), line: line))
                i = j + 1
                continue
            }
            if isDigit(c) {
                var j = i
                while j < n && isDigit(s[j]) { j += 1 }
                if j + 1 < n && s[j] == "." && isDigit(s[j + 1]) {
                    j += 1
                    while j < n && isDigit(s[j]) { j += 1 }
                }
                if j < n && (s[j] == "e" || s[j] == "E") {
                    var k = j + 1
                    if k < n && (s[k] == "+" || s[k] == "-") { k += 1 }
                    if k < n && isDigit(s[k]) {
                        while k < n && isDigit(s[k]) { k += 1 }
                        j = k
                    }
                }
                var txt = String.UnicodeScalarView(); txt.append(contentsOf: s[i..<j])
                toks.append(MUTok(kind: .num, d: Double(String(txt)) ?? 0, line: line))
                i = j
                continue
            }
            var kind: MUTok.Kind? = nil
            var start = i
            if (c == "$" || c == "@") && i + 1 < n && isIdentStart(s[i + 1]) {
                kind = c == "$" ? .state : .at; start = i + 1
            } else if isIdentStart(c) {
                kind = .id
            }
            if let kind {
                var j = start
                while j < n && isIdent(s[j]) { j += 1 }
                var txt = String.UnicodeScalarView(); txt.append(contentsOf: s[start..<j])
                toks.append(MUTok(kind: kind, s: String(txt), line: line))
                i = j
                continue
            }
            var matched = false
            for op in ops where starts(op, i) {
                let o = String(String.UnicodeScalarView(op))
                if o == "(" || o == "[" || o == "{" { depth += 1 }
                if o == ")" || o == "]" || o == "}" { depth = max(0, depth - 1) }
                toks.append(MUTok(kind: .op, s: o, line: line))
                i += op.count
                matched = true
                break
            }
            if !matched { throw MULexError(msg: "unexpected character '\(String(Character(c)))'", line: line) }
        }
        toks.append(MUTok(kind: .eof, line: line))
        return toks
    }
}

// MARK: - Parser

private struct MUParseError: Error {
    let msg: String
    let line: Int
}

private struct MUParser {
    let t: [MUTok]
    var p = 0
    static let prec: [String: Int] = ["||": 1, "&&": 2, "==": 3, "!=": 3, ">": 4, "<": 4, ">=": 4, "<=": 4,
                                      "+": 5, "-": 5, "*": 6, "/": 6, "%": 6]

    init(_ t: [MUTok]) { self.t = t }

    func peek(_ k: Int = 0) -> MUTok { t[min(p + k, t.count - 1)] }
    mutating func next() -> MUTok { let x = t[p]; p += 1; return x }
    func isOp(_ op: String, _ k: Int = 0) -> Bool { let x = peek(k); return x.kind == .op && x.s == op }
    mutating func expect(_ op: String) throws {
        let x = next()
        if x.kind != .op || x.s != op { throw MUParseError(msg: "expected '\(op)' but got \(x.repr)", line: x.line) }
    }

    mutating func expr(_ minp: Int = 0) throws -> MUNode {
        if minp == 0 {
            let cond = try expr(1)
            if isOp("?") {
                _ = next()
                let a = try expr(0)
                try expect(":")
                let b = try expr(0)
                return .tern(cond, a, b)
            }
            return cond
        }
        var left = try unary()
        while true {
            let x = peek()
            if x.kind == .op, let pr = Self.prec[x.s], pr >= minp {
                let op = next().s
                let right = try expr(pr + 1)
                left = .bin(op, left, right)
            } else {
                return left
            }
        }
    }

    mutating func unary() throws -> MUNode {
        if isOp("!") || isOp("-") {
            let op = next().s
            return .un(op, try unary())
        }
        return try postfix(try primary())
    }

    mutating func postfix(_ e0: MUNode) throws -> MUNode {
        var e = e0
        while true {
            if isOp(".") {
                _ = next()
                let x = next()
                if x.kind == .id { e = .mem(e, .name(x.s)) }
                else if x.kind == .num { e = .mem(e, .index(Int(x.d))) }
                else { throw MUParseError(msg: "bad member access", line: x.line) }
            } else if isOp("[") {
                _ = next()
                let i = try expr()
                try expect("]")
                e = .idx(e, i)
            } else {
                return e
            }
        }
    }

    mutating func args(_ close: String, namedOK: Bool = false) throws -> [MUNode] {
        var out: [MUNode] = []
        while !isOp(close) {
            if namedOK, peek().kind == .id, peek(1).kind == .op, peek(1).s == ":" || peek(1).s == "=" {
                let key = next().s
                _ = next()
                out.append(.named(key, try expr()))
            } else {
                out.append(try expr())
            }
            if isOp(",") {
                _ = next()
            } else if !isOp(close) {
                let x = peek()
                throw MUParseError(msg: "expected ',' or '\(close)' but got \(x.repr)", line: x.line)
            }
        }
        _ = next()
        return out
    }

    mutating func primary() throws -> MUNode {
        let x = next()
        switch x.kind {
        case .num: return .lit(.num(x.d))
        case .str: return .lit(.str(x.s))
        case .state: return .state(x.s)
        case .at:
            try expect("(")
            return .call(x.s, try args(")"), x.line)
        case .id:
            if x.s == "true" || x.s == "false" { return .lit(.bool(x.s == "true")) }
            if x.s == "null" { return .lit(.null) }
            if isOp("(") {
                _ = next()
                let a = try args(")", namedOK: x.s != "Action")
                return x.s == "Action" ? .action(a, x.line) : .comp(x.s, a, x.line)
            }
            return .ref(x.s, x.line)
        case .op:
            if x.s == "(" {
                let e = try expr()
                try expect(")")
                return e
            }
            if x.s == "[" { return .arr(try args("]")) }
            if x.s == "{" {
                var items: [(String, MUNode)] = []
                while !isOp("}") {
                    let k = next()
                    let key: String
                    switch k.kind {
                    case .id, .str: key = k.s
                    case .num: key = MUFormat.pyFloat(k.d)
                    default: throw MUParseError(msg: "bad object key", line: k.line)
                    }
                    try expect(":")
                    items.append((key, try expr()))
                    if isOp(",") { _ = next() }
                }
                _ = next()
                return .obj(items)
            }
        default: break
        }
        throw MUParseError(msg: "unexpected \(x.repr)", line: x.line)
    }
}

// MARK: - Program

final class MUProgram {
    var stmts: [String: (MUNode, Int)] = [:]
    var state: [String: (MUNode, Int)] = [:]
    /// Declaration order of `$state`, for stable messages back to the model.
    var stateOrder: [String] = []
    var errors: [MUError] = []

    static func parse(_ source: String) -> MUProgram {
        let prog = MUProgram()
        var src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a fenced block (the Python reference strips the same).
        if src.hasPrefix("```"), let nl = src.firstIndex(of: "\n") {
            let tag = src[src.index(src.startIndex, offsetBy: 3)..<nl]
            if tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) { src = String(src[src.index(after: nl)...]) }
        }
        if src.hasSuffix("\n```") { src = String(src.dropLast(4)) }
        let toks: [MUTok]
        do {
            toks = try MULexer.lex(src)
        } catch let e as MULexError {
            prog.errors.append(MUError(code: "parse-failed", line: e.line, msg: e.msg))
            return prog
        } catch {
            prog.errors.append(MUError(code: "parse-failed", line: 0, msg: "\(error)"))
            return prog
        }
        var statements: [[MUTok]] = []
        var cur: [MUTok] = []
        for tk in toks {
            if tk.kind == .nl || tk.kind == .eof {
                if !cur.isEmpty { statements.append(cur) }
                cur = []
            } else {
                cur.append(tk)
            }
        }
        for st in statements {
            let line = st[0].line
            guard st.count >= 3, st[1].kind == .op, st[1].s == "=", st[0].kind == .id || st[0].kind == .state else {
                prog.errors.append(MUError(code: "parse-failed", line: line, msg: "statement must be `name = Expression`"))
                continue
            }
            var p = MUParser(Array(st[2...]) + [MUTok(kind: .eof, line: line)])
            let ast: MUNode
            do {
                ast = try p.expr()
                if p.peek().kind != .eof {
                    throw MUParseError(msg: "unexpected \(p.peek().repr) after expression", line: line)
                }
            } catch let e as MUParseError {
                prog.errors.append(MUError(code: "parse-failed", line: e.line == 0 ? line : e.line, msg: e.msg))
                continue
            } catch {
                continue
            }
            if st[0].kind == .state {
                if ast.isConst {
                    if prog.state[st[0].s] == nil { prog.stateOrder.append(st[0].s) }
                    prog.state[st[0].s] = (ast, line)
                } else {
                    // `$x = <expression>` is a computed value, not editable state.
                    prog.stmts["$" + st[0].s] = (ast, line)
                }
            } else {
                prog.stmts[st[0].s] = (ast, line)
            }
        }
        if prog.stmts.isEmpty && prog.errors.isEmpty {
            prog.errors.append(MUError(code: "parse-failed", line: 0, msg: "no statements"))
        }
        return prog
    }

    /// Declared defaults (constants only, so evaluation cannot fail in practice).
    func defaultState() -> ([String: MUValue], [MUError]) {
        var st: [String: MUValue] = [:]
        var errs: [MUError] = []
        for (name, (ast, line)) in state {
            do {
                st[name] = try MUEnv(self, [:]).ev(ast, line)
            } catch let e as MURuntimeError {
                errs.append(MUError(code: "runtime-error", line: line, msg: "$\(name): \(e.msg)"))
                st[name] = .null
            } catch {
                st[name] = .null
            }
        }
        return (st, errs)
    }

    func render(_ state: [String: MUValue]) -> (MUComp?, MUEnv) {
        let env = MUEnv(self, state)
        guard let (_, rline) = stmts["root"] else {
            env.err("no-root", 0, "no `root` statement")
            return (nil, env)
        }
        if case .comp(let c) = env.ref("root", 0) { return (c, env) }
        env.err("no-root", rline, "`root` is not a component")
        return (nil, env)
    }
}

// MARK: - Evaluation

final class MUEnv {
    let prog: MUProgram
    let state: [String: MUValue]
    private var memo: [String: MUValue] = [:]
    private var active: Set<String> = []
    private(set) var errors: [MUError] = []

    init(_ prog: MUProgram, _ state: [String: MUValue]) {
        self.prog = prog
        self.state = state
    }

    func err(_ code: String, _ line: Int, _ msg: String) {
        let e = MUError(code: code, line: line, msg: msg)
        if !errors.contains(e) { errors.append(e) }
    }

    func ref(_ name: String, _ line: Int) -> MUValue {
        if let v = memo[name] { return v }
        guard let (ast, sline) = prog.stmts[name] else {
            err("unknown-reference", line, "`\(name)` is not defined")
            return .null
        }
        if active.contains(name) {
            err("cycle", line, "`\(name)` refers to itself")
            return .null
        }
        active.insert(name)
        var v: MUValue
        do {
            v = try ev(ast, sline)
        } catch let e as MURuntimeError {
            err("runtime-error", sline, "\(name): \(e.msg)")
            v = .null
        } catch {
            v = .null
        }
        active.remove(name)
        memo[name] = v
        return v
    }

    func ev(_ a: MUNode, _ line: Int) throws -> MUValue {
        switch a {
        case .lit(let v): return v
        case .arr(let xs): return .arr(try xs.map { try ev($0, line) })
        case .obj(let kv):
            var o: [String: MUValue] = [:]
            for (k, v) in kv { o[k] = try ev(v, line) }
            return .obj(o)
        case .ref(let name, let l): return ref(name, l)
        case .state(let name):
            if let v = state[name] { return v }
            if prog.stmts["$" + name] != nil { return ref("$" + name, line) }
            err("unknown-state", line, "$\(name) is not declared")
            return .null
        case .comp(let name, let args, let l): return try comp(name, args, l)
        case .action(let xs, _):
            var steps: [MUStep] = []
            for s in xs {
                if case .call(let n, let args, let l) = s, MinisUILibrary.actions.contains(n) {
                    steps.append(MUStep(name: n, args: args, line: l))
                } else if case .action(let inner, _) = s {
                    for x in inner { if case .call(let n, let args, let l) = x { steps.append(MUStep(name: n, args: args, line: l)) } }
                } else {
                    err("type-mismatch", line, "Action([...]) may only contain @actions")
                }
            }
            return .action(MUAction(steps))
        case .call(let name, let args, let l):
            if MinisUILibrary.actions.contains(name) { return .action(MUAction([MUStep(name: name, args: args, line: l)])) }
            return function(name, args, l)
        case .named(_, let e): return try ev(e, line)
        case .tern(let c, let x, let y):
            return MUOps.truthy(try ev(c, line)) ? try ev(x, line) : try ev(y, line)
        case .un(let op, let x):
            let v = try ev(x, line)
            return op == "!" ? .bool(!MUOps.truthy(v)) : .num(-(try MUOps.num(v)))
        case .mem(let base0, let key):
            let base = try ev(base0, line)
            switch base {
            case .null: return .null
            case .obj(let o):
                if case .name(let k) = key { return o[k] ?? .null }
                return .null
            case .arr(let xs):
                if case .name(let k) = key, k == "length" { return .num(Double(xs.count)) }
                let allObj = xs.allSatisfy { if case .obj = $0 { return true }; return false }
                if allObj {
                    return .arr(xs.map { x in
                        if case .obj(let o) = x, case .name(let k) = key { return o[k] ?? .null }
                        return .null
                    })
                }
                throw MURuntimeError("cannot read .\(key.label)")
            default:
                throw MURuntimeError("cannot read .\(key.label)")
            }
        case .idx(let b, let i):
            return try MUOps.index(try ev(b, line), try ev(i, line))
        case .bin(let op, let x, let y):
            return try MUOps.binop(op, try ev(x, line), try ev(y, line))
        }
    }

    private func function(_ name: String, _ args: [MUNode], _ line: Int) -> MUValue {
        guard MinisUILibrary.functions.contains(name) else {
            err("unknown-function", line, "@\(name) does not exist")
            return .null
        }
        do {
            let vals = try args.map { try ev($0, line) }
            return try MUOps.call(name, vals)
        } catch let e as MURuntimeError {
            err("runtime-error", line, "@\(name): \(e.msg)")
            return .null
        } catch {
            return .null
        }
    }

    private func comp(_ name: String, _ args0: [MUNode], _ line: Int) throws -> MUValue {
        guard let spec = MinisUILibrary.components[name] else {
            err("unknown-component", line, "\(name) is not a component")
            return .null
        }
        var args = args0
        let names = spec.map(\.name)
        if args.contains(where: { if case .named = $0 { return true }; return false }) {
            let pos = args.filter { if case .named = $0 { return false }; return true }
            var slots: [MUNode?] = pos.count <= spec.count ? pos + Array(repeating: nil, count: spec.count - pos.count) : pos
            for a in args {
                guard case .named(let k, let e) = a else { continue }
                if let i = names.firstIndex(of: k) { slots[i] = e } else { err("excess-args", line, "\(name) has no argument `\(k)`") }
            }
            while let last = slots.last, last == nil { slots.removeLast() }
            args = slots.map { $0 ?? .lit(.null) }
        }
        if args.count > spec.count {
            err("excess-args", line, "\(name) takes \(spec.count) arguments, got \(args.count)")
            args = Array(args.prefix(spec.count))
        }
        var props: [String: MUValue] = [:]
        for (i, arg) in spec.enumerated() {
            let a: MUNode? = i < args.count ? args[i] : nil
            if case .binding = arg.type {
                guard let a, case .state(let v) = a else {
                    err("type-mismatch", line, "\(name).\(arg.name) must be a $variable")
                    return .null
                }
                guard state[v] != nil else {
                    err("unknown-state", line, "$\(v) is not declared")
                    return .null
                }
                props[arg.name] = .str(v)
                continue
            }
            var v: MUValue = .null
            if let a {
                do { v = try ev(a, line) } catch let e as MURuntimeError {
                    err("runtime-error", line, "\(name).\(arg.name): \(e.msg)")
                    v = .null
                }
            }
            let checked = try MUTypes.check(v, arg.type)
            if v.isNull || checked == nil {
                if arg.required {
                    err(v.isNull ? "missing-required" : "type-mismatch", line,
                        "\(name).\(arg.name) (\(arg.type.label)) " + (v.isNull ? "is missing/null" : "got \(MUFormat.short(v))"))
                    return .null
                }
                if !v.isNull { err("type-mismatch", line, "\(name).\(arg.name) (\(arg.type.label)) got \(MUFormat.short(v)); ignored") }
                props[arg.name] = .null
            } else {
                props[arg.name] = checked!
            }
        }
        return .comp(MUComp(name: name, props: props, line: line))
    }
}

private extension MUMember {
    var label: String {
        switch self {
        case .name(let s): return s
        case .index(let i): return String(i)
        }
    }
}

enum MUOps {
    static func truthy(_ v: MUValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .num(let d): return d != 0
        case .str(let s): return !s.isEmpty
        case .arr(let xs): return !xs.isEmpty
        default: return true
        }
    }

    static func num(_ v: MUValue) throws -> Double {
        if case .num(let d) = v { return d }
        let t: String
        switch v {
        case .null: t = "null"
        case .bool: t = "bool"
        case .str: t = "str"
        case .arr: t = "list"
        case .obj: t = "dict"
        case .comp: t = "Comp"
        case .action: t = "Act"
        case .num: t = "float"
        }
        throw MURuntimeError("expected number, got \(t)")
    }

    static func toStr(_ v: MUValue) throws -> String {
        switch v {
        case .null: return ""
        case .str(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .num(let d): return try MUFormat.num(d)
        case .arr: throw MURuntimeError("cannot turn list into text")
        case .obj: throw MURuntimeError("cannot turn dict into text")
        case .comp: throw MURuntimeError("cannot turn Comp into text")
        case .action: throw MURuntimeError("cannot turn Act into text")
        }
    }

    static func index(_ base: MUValue, _ i: MUValue) throws -> MUValue {
        switch base {
        case .null: return .null
        case .arr(let xs):
            let k = Int(try num(i))
            return (k >= 0 && k < xs.count) ? xs[k] : .null
        case .obj(let o): return o[try toStr(i)] ?? .null
        default: throw MURuntimeError("cannot index this value")
        }
    }

    static func binop(_ op: String, _ x: MUValue, _ y: MUValue) throws -> MUValue {
        switch op {
        case "&&": return truthy(x) ? y : x
        case "||": return truthy(x) ? x : y
        case "==": return .bool(MUValue.eq(x, y))
        case "!=": return .bool(!MUValue.eq(x, y))
        default: break
        }
        if op == "+" {
            var stringy = false
            if case .str = x { stringy = true }
            if case .str = y { stringy = true }
            if stringy { return .str(try toStr(x) + toStr(y)) }
        }
        if ["<", ">", "<=", ">="].contains(op), case .str(let a) = x, case .str(let b) = y {
            switch op {
            case "<": return .bool(a < b)
            case ">": return .bool(a > b)
            case "<=": return .bool(a <= b)
            default: return .bool(a >= b)
            }
        }
        let a = try num(x), b = try num(y)
        switch op {
        case "+": return .num(a + b)
        case "-": return .num(a - b)
        case "*": return .num(a * b)
        case "/":
            if b == 0 { throw MURuntimeError("division by zero") }
            return .num(a / b)
        case "%":
            if b == 0 { throw MURuntimeError("modulo by zero") }
            return .num(fmod(a, b))
        case "<": return .bool(a < b)
        case ">": return .bool(a > b)
        case "<=": return .bool(a <= b)
        default: return .bool(a >= b)
        }
    }

    private static func nums(_ vals: [MUValue]) throws -> [Double] {
        if vals.count == 1, case .arr(let xs) = vals[0] { return try xs.map(num) }
        return try vals.map(num)
    }

    private static func arg(_ v: [MUValue], _ i: Int) throws -> MUValue {
        guard i < v.count else { throw MURuntimeError("missing argument") }
        return v[i]
    }

    private static func decimals(_ v: [MUValue]) throws -> Int {
        guard v.count > 1, !v[1].isNull else { return 0 }
        return Int(try num(v[1]))
    }

    static func call(_ name: String, _ v: [MUValue]) throws -> MUValue {
        switch name {
        case "Round":
            let q = pow(10.0, Double(try decimals(v)))
            return .num(floor(try num(arg(v, 0)) * q + 0.5) / q)
        case "Format":
            return .str(try MUFormat.grouped(try num(arg(v, 0)), decimals: max(0, min(10, try decimals(v)))))
        case "Pow":
            return .num(pow(try num(arg(v, 0)), try num(arg(v, 1))))
        case "Sum", "Avg", "Min", "Max":
            let xs = try nums(v)
            if xs.isEmpty { return name == "Sum" ? .num(0) : .null }
            switch name {
            case "Sum": return .num(xs.reduce(0, +))
            case "Avg": return .num(xs.reduce(0, +) / Double(xs.count))
            case "Min": return .num(xs.min()!)
            default: return .num(xs.max()!)
            }
        case "Count":
            guard case .arr(let xs) = try arg(v, 0) else { throw MURuntimeError("expected array") }
            return .num(Double(xs.count))
        case "Abs": return .num(abs(try num(arg(v, 0))))
        case "Floor": return .num(floor(try num(arg(v, 0))))
        case "Ceil": return .num(ceil(try num(arg(v, 0))))
        case "At": return try index(try arg(v, 0), try arg(v, 1))
        case "Join":
            guard case .arr(let xs) = try arg(v, 0) else { throw MURuntimeError("expected array") }
            let sep = v.count > 1 ? try toStr(v[1]) : ", "
            return .str(try xs.map(toStr).joined(separator: sep))
        default:
            throw MURuntimeError("unknown function")
        }
    }
}

enum MUTypes {
    /// The checked (normalised) value, or nil when it does not fit.
    static func check(_ v: MUValue, _ t: MUType) throws -> MUValue? {
        if v.isNull { return nil }
        switch t {
        case .string:
            if case .str = v { return v }
            if case .num(let d) = v { return .str(try MUFormat.num(d)) }
            return nil
        case .text:
            switch v {
            case .str: return v
            case .num(let d): return .str(try MUFormat.num(d))
            default: return nil
            }
        case .number:
            if case .num = v { return v }
            return nil
        case .bool:
            if case .bool = v { return v }
            return nil
        case .oneOf(let xs):
            if case .str(let s) = v, xs.contains(s) { return v }
            return nil
        case .strings:
            guard case .arr(let xs) = v else { return nil }
            var out: [MUValue] = []
            for x in xs {
                switch x {
                case .str: out.append(x)
                case .num(let d): out.append(.str(try MUFormat.num(d)))
                default: return nil
                }
            }
            return .arr(out)
        case .numbers:
            guard case .arr(let xs) = v else { return nil }
            for x in xs { if case .num = x { continue }; return nil }
            return v
        case .matrix:
            guard case .arr(let rs) = v else { return nil }
            for r in rs {
                guard case .arr(let xs) = r else { return nil }
                for x in xs { if case .num = x { continue }; return nil }
            }
            return v
        case .rows:
            guard case .arr(let rs) = v else { return nil }
            var out: [MUValue] = []
            for r in rs {
                guard case .arr(let cs) = r else { return nil }
                do { out.append(.arr(try cs.map { .str(try MUOps.toStr($0)) })) } catch { return nil }
            }
            return .arr(out)
        case .component:
            if case .comp = v { return v }
            return nil
        case .components:
            guard case .arr(let xs) = v else { return nil }
            var out: [MUValue] = []
            for x in xs {
                switch x {
                case .null: continue
                case .arr(let inner):
                    out.append(contentsOf: inner.filter { if case .comp = $0 { return true }; return false })
                case .comp: out.append(x)
                case .str, .num:
                    out.append(.comp(MUComp(name: "Text", props: ["text": .str(try MUOps.toStr(x)), "tone": .null], line: 0)))
                default: return nil
                }
            }
            return .arr(out)
        case .action:
            if case .action = v { return v }
            return nil
        case .binding:
            return nil
        }
    }
}

enum MUFormat {
    /// Python's repr of a float ("1.0", "2.5").
    static func pyFloat(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    static func num(_ x: Double) throws -> String {
        if x.isNaN || x.isInfinite { throw MURuntimeError("non-finite number") }
        if abs(x - x.rounded()) < 1e-9 && abs(x) < 1e15 { return String(Int64(x.rounded())) }
        var s = String(format: "%.10f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// `12345.6` → "12,345.6" (comma thousands, fixed decimals).
    static func grouped(_ x: Double, decimals: Int) throws -> String {
        if x.isNaN || x.isInfinite { throw MURuntimeError("non-finite number") }
        let raw = String(format: "%.\(decimals)f", x)
        var intPart = raw
        var frac = ""
        if let dot = raw.firstIndex(of: ".") {
            intPart = String(raw[..<dot])
            frac = String(raw[dot...])
        }
        var sign = ""
        if intPart.hasPrefix("-") { sign = "-"; intPart.removeFirst() }
        var out: [Character] = []
        for (i, c) in intPart.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return sign + String(out.reversed()) + frac
    }

    static func short(_ v: MUValue) -> String {
        let s: String
        switch v {
        case .str(let x): s = "'\(x)'"
        case .num(let d): s = pyFloat(d)
        case .bool(let b): s = b ? "True" : "False"
        case .null: s = "None"
        case .arr(let xs): s = "[" + xs.map(short).joined(separator: ", ") + "]"
        case .obj: s = "{…}"
        case .comp(let c): s = "Comp(\(c.name))"
        case .action: s = "Act"
        }
        return s.count < 60 ? s : String(s.prefix(57)) + "..."
    }
}

// MARK: - Validation

struct MUValidation {
    var ok: Bool
    var errors: [MUError]
    var warnings: [MUError]
    var root: MUComp?
    var components = 0
    var inputs = 0
    var buttons = 0
    var interactions = 0
    var statements = 0
}

enum MUEvent {
    case toAssistant(message: String, context: MUValue)
    case copy(String)
    case openURL(String)
}

enum MinisUIEngine {
    static func walk(_ c: MUComp, _ depth: Int = 0, _ f: (MUComp, Int) -> Void) {
        f(c, depth)
        for ch in c.children { walk(ch, depth + 1, f) }
    }

    static func structuralChecks(_ root: MUComp, _ state: [String: MUValue]) -> ([MUError], [MUError]) {
        var errs: [MUError] = []
        var warns: [MUError] = []
        var nodes: [(MUComp, Int)] = []
        walk(root) { nodes.append(($0, $1)) }
        if nodes.count > MinisUILibrary.maxNodes {
            errs.append(MUError(code: "too-large", line: 0, msg: "\(nodes.count) components (max \(MinisUILibrary.maxNodes))"))
        }
        if (nodes.map(\.1).max() ?? 0) > MinisUILibrary.maxDepth {
            errs.append(MUError(code: "too-deep", line: 0, msg: "nesting too deep"))
        }
        for (c, _) in nodes {
            switch c.name {
            case "Row":
                if c.children.count > MinisUILibrary.maxRowChildren {
                    warns.append(MUError(code: "layout", line: c.line, msg: "Row has \(c.children.count) children; max 3 on a phone"))
                }
            case "BarChart", "LineChart":
                let l = c.strings("labels").count, v = c.numbers("values").count
                if l != v { errs.append(MUError(code: "chart-mismatch", line: c.line, msg: "\(c.name): \(l) labels vs \(v) values")) }
                let labelSet = Set(c.strings("labels"))
                let missing = c.strings("highlight").filter { !labelSet.contains($0) }
                if !missing.isEmpty {
                    errs.append(MUError(code: "chart-highlight", line: c.line,
                                        msg: "\(c.name): highlight must repeat label texts exactly; not in labels: \(missing.joined(separator: ", "))"))
                }
            case "MultiChart":
                let labels = c.strings("labels"), names = c.strings("series"), m = c.matrix("values")
                if names.isEmpty || names.count > 6 {
                    errs.append(MUError(code: "chart-series", line: c.line, msg: "MultiChart: use 1–6 series (got \(names.count)); split the data into two charts if you need more"))
                }
                if m.count != names.count {
                    errs.append(MUError(code: "chart-mismatch", line: c.line, msg: "MultiChart: \(names.count) series names vs \(m.count) value rows"))
                }
                if let bad = m.firstIndex(where: { $0.count != labels.count }) {
                    errs.append(MUError(code: "chart-mismatch", line: c.line, msg: "MultiChart: row \(bad) has \(m[bad].count) values but there are \(labels.count) labels"))
                }
                if labels.count > MinisUILibrary.maxChartPoints {
                    errs.append(MUError(code: "too-large", line: c.line, msg: "MultiChart: too many points (max \(MinisUILibrary.maxChartPoints))"))
                }
                let known = Set(labels).union(names)
                let missing = c.strings("highlight").filter { !known.contains($0) }
                if !missing.isEmpty {
                    errs.append(MUError(code: "chart-highlight", line: c.line,
                                        msg: "MultiChart: highlight must repeat label or series texts exactly; not found: \(missing.joined(separator: ", "))"))
                }
            case "Table":
                let w = c.strings("headers").count
                let rows = c.rows("rows")
                if rows.contains(where: { $0.count != w }) {
                    errs.append(MUError(code: "table-mismatch", line: c.line, msg: "every row must have as many cells as headers"))
                }
                if rows.count > MinisUILibrary.maxTableRows { errs.append(MUError(code: "too-large", line: c.line, msg: "table too long")) }
                if w > 4 { warns.append(MUError(code: "layout", line: c.line, msg: "Table has \(w) columns; max 4 on a phone")) }
            case "Slider", "Stepper":
                let name = c.str("value") ?? ""
                guard case .num(let v)? = state[name] else {
                    errs.append(MUError(code: "type-mismatch", line: c.line, msg: "$\(name) must hold a number"))
                    continue
                }
                let lo = c.num("min") ?? 0, hi = c.num("max") ?? 0
                if lo >= hi {
                    errs.append(MUError(code: "type-mismatch", line: c.line, msg: "\(c.name): min must be < max"))
                } else if !(lo <= v && v <= hi) {
                    let s = { (d: Double) in (try? MUFormat.num(d)) ?? "?" }
                    warns.append(MUError(code: "range", line: c.line, msg: "$\(name)=\(s(v)) is outside \(s(lo))…\(s(hi))"))
                }
            case "Toggle":
                let name = c.str("value") ?? ""
                if case .bool? = state[name] {} else {
                    errs.append(MUError(code: "type-mismatch", line: c.line, msg: "$\(name) must be true/false for Toggle"))
                }
            case "Segmented", "Choice":
                let name = c.str("value") ?? ""
                let options = c.strings("options")
                if case .str(let v)? = state[name] {
                    if c.name == "Segmented" && !options.contains(v) {
                        errs.append(MUError(code: "type-mismatch", line: c.line, msg: "default '\(v)' is not one of the options"))
                    } else if c.name == "Choice" && !v.isEmpty && !options.contains(v) {
                        errs.append(MUError(code: "type-mismatch", line: c.line, msg: "default '\(v)' is not one of the options"))
                    }
                } else {
                    errs.append(MUError(code: "type-mismatch", line: c.line, msg: "$\(name) must hold option text"))
                }
                if c.name == "Segmented" && options.count > 4 {
                    warns.append(MUError(code: "layout", line: c.line, msg: "Segmented: max 4 options; use Choice"))
                }
            default: break
            }
        }
        return (errs, warns)
    }

    static func inputsAndButtons(_ root: MUComp) -> ([MUComp], [MUComp]) {
        var ins: [MUComp] = []
        var btns: [MUComp] = []
        walk(root) { c, _ in
            if MinisUILibrary.inputs.contains(c.name) { ins.append(c) }
            if c.name == "Button" { btns.append(c) }
        }
        return (ins, btns)
    }

    /// Runs one action: the new state, the events for the host, any errors.
    static func run(_ act: MUAction, state: [String: MUValue], prog: MUProgram,
                    defaults: [String: MUValue]) -> ([String: MUValue], [MUEvent], [MUError]) {
        var st = state
        var events: [MUEvent] = []
        var errs: [MUError] = []
        for step in act.steps {
            let env = MUEnv(prog, st)
            do {
                switch step.name {
                case "Set":
                    guard let first = step.args.first, case .state(let v) = first, st[v] != nil else {
                        errs.append(MUError(code: "type-mismatch", line: step.line, msg: "@Set needs a declared $variable first"))
                        continue
                    }
                    st[v] = step.args.count > 1 ? try env.ev(step.args[1], step.line) : .null
                case "Reset":
                    for a in step.args {
                        if case .state(let v) = a, let d = defaults[v] { st[v] = d } else {
                            errs.append(MUError(code: "type-mismatch", line: step.line, msg: "@Reset takes declared $variables"))
                        }
                    }
                case "ToAssistant":
                    let msg = step.args.isEmpty ? "" : try MUOps.toStr(try env.ev(step.args[0], step.line))
                    if msg.isEmpty { errs.append(MUError(code: "missing-required", line: step.line, msg: "@ToAssistant needs a message")) }
                    let ctx = step.args.count > 1 ? try env.ev(step.args[1], step.line) : .null
                    events.append(.toAssistant(message: msg, context: ctx))
                case "Copy":
                    events.append(.copy(step.args.isEmpty ? "" : try MUOps.toStr(try env.ev(step.args[0], step.line))))
                case "OpenUrl":
                    let u = step.args.isEmpty ? "" : try MUOps.toStr(try env.ev(step.args[0], step.line))
                    if !(u.hasPrefix("http://") || u.hasPrefix("https://")) {
                        errs.append(MUError(code: "type-mismatch", line: step.line, msg: "@OpenUrl needs an http(s) URL"))
                    }
                    events.append(.openURL(u))
                default: break
                }
            } catch let e as MURuntimeError {
                errs.append(MUError(code: "runtime-error", line: step.line, msg: "@\(step.name): \(e.msg)"))
            } catch {}
            errs.append(contentsOf: env.errors)
        }
        return (st, events, errs)
    }

    static func testValues(_ c: MUComp, current: MUValue?) -> [MUValue] {
        switch c.name {
        case "Slider", "Stepper":
            let lo = c.num("min") ?? 0, hi = c.num("max") ?? 0
            var step = c.num("step") ?? 1
            if step == 0 { step = 1 }
            let mid = lo + ((hi - lo) / 2 / step).rounded(.toNearestOrEven) * step
            return [.num(lo), .num(mid), .num(hi)]
        case "Toggle":
            if case .bool(let b)? = current { return [.bool(!b)] }
            return [.bool(true)]
        case "Segmented", "Choice":
            return c.strings("options").map { .str($0) }
        default:
            return []
        }
    }

    static func valueLabel(_ v: MUValue) -> String {
        switch v {
        case .str(let s): return "'\(s)'"
        case .num(let d): return MUFormat.pyFloat(d)
        case .bool(let b): return b ? "True" : "False"
        default: return "None"
        }
    }

    /// Parse, render with defaults, then set every input to a few values and
    /// tap every button once, collecting every error along the way.
    static func validate(_ src: String) -> MUValidation {
        let prog = MUProgram.parse(src)
        var v = MUValidation(ok: false, errors: prog.errors, warnings: [], root: nil)
        v.statements = prog.stmts.count + prog.state.count
        if prog.errors.contains(where: { $0.code == "parse-failed" }) && prog.stmts.isEmpty { return v }
        if v.statements > MinisUILibrary.maxStatements { v.errors.append(MUError(code: "too-large", line: 0, msg: "too many statements")) }
        let (defaults, serr) = prog.defaultState()
        v.errors += serr
        let (root0, env) = prog.render(defaults)
        v.errors += env.errors
        guard let root = root0 else {
            v.errors = dedupe(v.errors)
            return v
        }
        v.root = root
        let (se, sw) = structuralChecks(root, defaults)
        v.errors += se
        v.warnings += sw
        let (ins, btns) = inputsAndButtons(root)
        v.inputs = ins.count
        v.buttons = btns.count
        walk(root) { _, _ in v.components += 1 }
        for c in ins {
            let name = c.str("value") ?? ""
            for val in testValues(c, current: defaults[name]) {
                var st = defaults
                st[name] = val
                let (r2, env2) = prog.render(st)
                v.interactions += 1
                for e in env2.errors {
                    v.errors.append(MUError(code: e.code, line: e.line, msg: "after setting $\(name)=\(valueLabel(val)): \(e.msg)"))
                }
                if r2 == nil {
                    v.errors.append(MUError(code: "runtime-error", line: c.line, msg: "card disappears after setting $\(name)=\(valueLabel(val))"))
                }
            }
        }
        for b in btns {
            guard let act = b.action else { continue }
            let (st, _, aerrs) = run(act, state: defaults, prog: prog, defaults: defaults)
            v.interactions += 1
            v.errors += aerrs
            let (_, env2) = prog.render(st)
            for e in env2.errors {
                v.errors.append(MUError(code: e.code, line: e.line, msg: "after tapping '\(b.str("label") ?? "")': \(e.msg)"))
            }
        }
        v.errors = dedupe(v.errors)
        v.warnings = dedupe(v.warnings)
        v.ok = v.errors.isEmpty
        return v
    }

    static func dedupe(_ xs: [MUError]) -> [MUError] {
        var seen = Set<MUError>()
        return xs.filter { seen.insert($0).inserted }
    }

    /// The tool result the model reads.
    static func feedback(_ v: MUValidation) -> String {
        if v.ok {
            var msg = "Rendered. The user can now interact with the card; button actions arrive as user messages."
            if !v.warnings.isEmpty {
                msg += "\nWarnings (optional to fix):\n" + v.warnings.map { "- line \($0.line): \($0.msg)" }.joined(separator: "\n")
            }
            return msg
        }
        let lines = v.errors.prefix(12).map { "- [\($0.code)] line \($0.line): \($0.msg)" }
        return "Not rendered — fix these and call show_ui again with the full corrected program:\n" + lines.joined(separator: "\n")
    }

    /// Plain-text version for copy, search and exports.
    static func fallbackText(_ root: MUComp?) -> String {
        guard let root else { return "" }
        var out: [String] = []
        walk(root) { c, _ in
            switch c.name {
            case "Card":
                if let t = c.str("title") { out.append("【\(t)】") }
            case "Title", "Text", "Callout", "Badge":
                out.append(c.str("text") ?? "")
            case "Metric":
                var s = "\(c.str("label") ?? "")：\(c.str("value") ?? "")"
                if let n = c.str("note") { s += "（\(n)）" }
                out.append(s)
            case "List":
                out += c.strings("items").map { "• \($0)" }
            case "Table":
                out.append(c.strings("headers").joined(separator: " | "))
                out += c.rows("rows").map { $0.joined(separator: " | ") }
            case "BarChart", "LineChart":
                let unit = c.str("unit") ?? ""
                for (a, b) in zip(c.strings("labels"), c.numbers("values")) {
                    out.append("\(a): \((try? MUFormat.num(b)) ?? "?")\(unit)")
                }
            case "MultiChart":
                if let t = c.str("title") { out.append(t) }
                let unit = c.str("unit") ?? ""
                let labels = c.strings("labels"), names = c.strings("series"), m = c.matrix("values")
                for (i, n) in names.enumerated() where i < m.count {
                    let cells = zip(labels, m[i]).map { "\($0): \((try? MUFormat.num($1)) ?? "?")\(unit)" }
                    out.append("\(n) — " + cells.joined(separator: "; "))
                }
            default: break
            }
        }
        return out.joined(separator: "\n")
    }

    /// Rough height for the list's first layout pass (the real one is measured).
    static func estimatedHeight(_ c: MUComp, width: CGFloat) -> CGFloat {
        func textLines(_ s: String, _ w: CGFloat, _ charWidth: CGFloat) -> CGFloat {
            let perLine = max(1, w / charWidth)
            var lines: CGFloat = 0
            for part in s.split(separator: "\n", omittingEmptySubsequences: false) {
                lines += max(1, ceil(CGFloat(part.count) / perLine))
            }
            return max(1, lines)
        }
        func h(_ c: MUComp, _ w: CGFloat, _ nested: Bool) -> CGFloat {
            let kids = c.children
            switch c.name {
            case "Card":
                let inner = w - 28
                var total: CGFloat = 28
                if c.str("title") != nil { total += 22 + 10 }
                total += kids.map { h($0, inner, true) }.reduce(0, +) + CGFloat(max(0, kids.count - 1)) * 10
                return total
            case "Stack":
                let gap: CGFloat = c.str("gap") == "s" ? 6 : (c.str("gap") == "l" ? 16 : 10)
                return kids.map { h($0, w, nested) }.reduce(0, +) + CGFloat(max(0, kids.count - 1)) * gap
            case "Row":
                let cw = (w - CGFloat(max(0, kids.count - 1)) * 10) / CGFloat(max(1, kids.count))
                return kids.map { h($0, cw, nested) }.max() ?? 0
            case "Divider": return 1
            case "Title":
                let lh: CGFloat = c.str("size") == "l" ? 26 : (c.str("size") == "s" ? 20 : 23)
                return lh * textLines(c.str("text") ?? "", w, lh * 0.8)
            case "Text": return 20 * textLines(c.str("text") ?? "", w, 13)
            case "Metric": return 16 + 4 + 32 + (c.str("note") != nil ? 18 : 0)
            case "Badge": return 22
            case "List": return c.strings("items").map { 20 * textLines($0, w - 18, 13) + 4 }.reduce(0, +)
            case "Callout": return 20 * textLines(c.str("text") ?? "", w - 46, 13) + 22
            case "Slider": return 22 + 34
            case "Stepper", "Toggle": return 34
            case "Segmented": return 32
            case "Choice":
                let opts = c.strings("options")
                return opts.map { 20 * textLines($0, w - 52, 13) + 22 }.reduce(0, +) + CGFloat(max(0, opts.count - 1)) * 8
            case "Table": return CGFloat(c.rows("rows").count + 1) * 30
            case "BarChart", "LineChart":
                return MUChartTypography.estimatedHeight(title: nil, subtitle: nil, source: nil,
                    seriesCount: 0, kind: c.name == "LineChart" ? "line" : "bar", width: w, framed: false)
            case "MultiChart":
                return MUChartTypography.estimatedHeight(title: c.str("title"), subtitle: c.str("subtitle"),
                    source: c.str("source"), seriesCount: c.strings("series").count,
                    kind: c.str("kind") ?? "line", width: w, framed: true)
            case "Button": return 40
            default: return 20
            }
        }
        return ceil(h(c, max(120, width), false))
    }
}
// MARK: - Card plane: chart-only cards draw flat [T-chart-card-flat]
//
// A top-level `Card` is drawn on the chat bubble as a filled, stroked panel
// (`ChatColors.secondaryBg` + a hairline border). That panel is right for a
// card the assistant hands over as an object — a calculator, a set of choices,
// a slider form — but a chart already brings its own surface (the blue-grey /
// beige Economist panel). Stacking the two made the device screenshot show a
// grey card around a grey panel, with the chart's own ground floating inside
// the card's ground.
//
// The decision is a pure classification of the component TREE, not of the
// `show_ui` call: the card is flat only when the whole subtree is chart output
// — a title, a chart, a legend/source line, dividers — and nothing else. A
// slider, a choice, a button, a table, a metric or ANY unknown component keeps
// the card exactly as it was: a card that does something must still read as a
// card the user can act on.
enum MUCardPlane {
    /// The chart leaves. One of them must be present, and nothing else that is
    /// not in `plainKinds` below may be.
    static let chartKinds: Set<String> = ["BarChart", "LineChart", "MultiChart"]
    /// Text and separators: a chart's title, subtitle, explanation, source note.
    static let plainKinds: Set<String> = ["Title", "Text", "Badge", "Divider"]
    /// Containers that only lay their children out. Traversed, never a verdict.
    static let wrapperKinds: Set<String> = ["Card", "Stack", "Row"]

    /// Whether `card` may be drawn without the outer panel: a Card whose whole
    /// subtree is chart output. Anything interactive, numeric or unknown — and
    /// a subtree with no chart at all — answers false, so the default card
    /// (choice lists, calculators, forms) is never touched.
    static func isChartOnly(_ card: MUComp) -> Bool {
        guard card.name == "Card" else { return false }
        var charts = 0
        func walk(_ c: MUComp) -> Bool {
            if chartKinds.contains(c.name) {
                charts += 1
                return c.children.isEmpty
            }
            if plainKinds.contains(c.name) { return c.children.isEmpty }
            if wrapperKinds.contains(c.name) { return c.children.allSatisfy(walk) }
            return false  // Slider/Choice/Button/Table/Metric/Callout/unknown
        }
        guard walk(card) else { return false }
        return charts > 0
    }
}

// MARK: - Chart layout & emphasis (pure Foundation; no SwiftUI)
//
// Everything in this section is deliberately free of SwiftUI/UIKit so the CI
// harness (`scripts/chart_layout_regression.py`) can compile it on a real
// toolchain and assert the behaviour that a screenshot can only hint at:
//
//  * which series is emphasised (data order, never the order of `highlight`),
//  * a stable y domain, so a label pixel position is a pure function of a value,
//  * end-of-line label placement that cannot overlap and never re-orders lines,
//  * the trailing gutter that keeps those labels away from the right axis.
//
// The view (`MinisUIView.MUMultiChartBody`) only maps these results to colours
// and `.offset`s; it must not re-implement any of the rules.

/// Colour role of one series in a multi-series chart.
///
/// `normal` — no emphasis in this chart: the series keeps its palette colour.
/// `emphasis(slot)` — highlighted; slot is 0-based, assigned in DATA order.
/// `context` — greyed out because other series are emphasised.
enum MUChartRole: Equatable {
    case normal
    case emphasis(Int)
    case context
}

enum MUChartEmphasis {
    /// Distinct accent colours available for simultaneous highlights. The guide
    /// only ever highlights one or two points; three is the point where another
    /// accent stops being clearly different from a normal series colour.
    static let slots = 3

    /// Highlight resolution. Deterministic and independent of the order of the
    /// `highlight` array: rank follows the order of `series`. A highlighted
    /// series past the last accent slot keeps its palette colour (`normal`)
    /// rather than turning grey — a highlight must never hide data.
    static func roles(series: [String], highlight: [String]) -> [MUChartRole] {
        guard !series.isEmpty else { return [] }
        let picked = Set(highlight)
        let hits = series.enumerated().filter { picked.contains($0.element) }.map { $0.offset }
        guard !hits.isEmpty else { return Array(repeating: MUChartRole.normal, count: series.count) }
        var out = Array(repeating: MUChartRole.context, count: series.count)
        for (rank, index) in hits.enumerated() {
            out[index] = rank < slots ? .emphasis(rank) : .normal
        }
        return out
    }

    static func hasEmphasis(_ roles: [MUChartRole]) -> Bool {
        roles.contains { role in
            if case .emphasis = role { return true }
            return false
        }
    }

    static func slot(_ roles: [MUChartRole], at index: Int) -> Int? {
        guard index >= 0, index < roles.count, case .emphasis(let s) = roles[index] else { return nil }
        return s
    }

    static func isContext(_ roles: [MUChartRole], at index: Int) -> Bool {
        guard index >= 0, index < roles.count else { return false }
        return roles[index] == .context
    }

    /// Number of accents in use, for warnings and tests.
    static func usedSlots(_ roles: [MUChartRole]) -> Int {
        roles.reduce(0) { acc, role in
            if case .emphasis(let s) = role { return max(acc, s + 1) }
            return acc
        }
    }
}

/// One-series charts (`BarChart`/`LineChart`): the guide's "1 trace with
/// highlight" rule — base colour with the emphasised items in the second colour.
enum MUChartBarMarks {
    static func marked(labels: [String], highlight: [String]) -> [Bool] {
        let hl = Set(highlight)
        return labels.map { hl.contains($0) }
    }
}

struct MUChartDomain: Equatable {
    var lower: Double
    var upper: Double
    var span: Double { upper - lower }
}

enum MUChartAxis {
    /// 1 / 2 / 2.5 / 5 / 10 × 10^n — the usual "nice" axis step.
    static func niceStep(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let norm = raw / magnitude
        let nice: Double
        if norm <= 1 { nice = 1 } else if norm <= 2 { nice = 2 }
        else if norm <= 2.5 { nice = 2.5 } else if norm <= 5 { nice = 5 } else { nice = 10 }
        return nice * magnitude
    }

    /// Explicit y domain: values, optional zero, ~6% headroom, rounded outward
    /// to a nice step. An explicit domain is what makes `pixelY` exact, and it
    /// keeps the frame identical when the colour style changes.
    static func domain(values: [[Double]], includeZero: Bool,
                       targetTicks: Int = 4, padding: Double = 0.06) -> MUChartDomain {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for row in values {
            for v in row where v.isFinite {
                lo = min(lo, v); hi = max(hi, v)
            }
        }
        if lo > hi { lo = 0; hi = 1 }
        if includeZero { lo = min(lo, 0); hi = max(hi, 0) }
        if hi - lo < 1e-9 {
            let pad = max(0.5, abs(hi) * 0.1)
            lo -= pad; hi += pad
        } else {
            let pad = (hi - lo) * padding
            lo -= pad; hi += pad
        }
        let step = niceStep((hi - lo) / Double(max(1, targetTicks)))
        lo = (lo / step).rounded(.down) * step
        hi = (hi / step).rounded(.up) * step
        if hi - lo < 1e-9 { hi = lo + step }
        return MUChartDomain(lower: lo, upper: hi)
    }

    /// Stacked bars scale to the per-column totals, not to a single segment.
    static func stackedDomain(matrix: [[Double]], targetTicks: Int = 4,
                              padding: Double = 0.06) -> MUChartDomain {
        guard let cols = matrix.map({ $0.count }).max(), cols > 0 else {
            return MUChartDomain(lower: 0, upper: 1)
        }
        var lo = 0.0, hi = 0.0
        for i in 0..<cols {
            var positive = 0.0, negative = 0.0
            for row in matrix where i < row.count {
                let v = row[i]
                if !v.isFinite { continue }
                if v >= 0 { positive += v } else { negative += v }
            }
            hi = max(hi, positive)
            lo = min(lo, negative)
        }
        return domain(values: [[lo, hi]], includeZero: true, targetTicks: targetTicks, padding: padding)
    }

    /// 0 at the top of the plot, `height` at the bottom.
    static func pixelY(_ value: Double, domain: MUChartDomain, height: CGFloat) -> CGFloat {
        guard domain.span > 0, height > 0 else { return height }
        let t = (value - domain.lower) / domain.span
        return height * CGFloat(1 - max(0, min(1, t)))
    }
}

/// End-of-line labels: one per series, placed in the plot's trailing gutter.
/// The placement is computed in points (not values) so a fixed minimum gap can
/// be guaranteed; series order is never inverted, so a pushed label still sits
/// on the same side of its neighbours as its value does.
enum MUChartEndLabels {
    struct Placement: Equatable {
        let index: Int
        let centerY: CGFloat
        /// `.offset(y:)` to add to the annotation (positive = down).
        let dy: CGFloat
    }

    static func layout(values: [Double], domain: MUChartDomain, plotHeight: CGFloat,
                       minGap: CGFloat = 12, edgeInset: CGFloat = 7,
                       baseY: [CGFloat]? = nil) -> [Placement] {
        guard !values.isEmpty, plotHeight > 0 else { return [] }
        let inset = min(max(0, edgeInset), plotHeight / 2)
        var gap = max(0, minGap)
        let room = plotHeight - 2 * inset
        if values.count > 1, room > 0 {
            let needed = gap * CGFloat(values.count - 1)
            if needed > room { gap = room / CGFloat(values.count - 1) }
        }
        let order = values.enumerated().sorted { a, b in
            if abs(a.element - b.element) > 1e-9 { return a.element > b.element }
            return a.offset < b.offset
        }.map { $0.offset }
        var natural = [CGFloat](repeating: 0, count: values.count)
        for i in values.indices {
            // [T-chart-label-physical] A caller that knows the REAL mark
            // position (`ChartProxy.position(forY:)`) hands it in; the pixel
            // mapping below is the fallback for the pure harness and stays the
            // contract `MUChartAxis.pixelY` is tested against.
            natural[i] = baseY.flatMap { $0.indices.contains(i) ? $0[i] : nil }
                ?? MUChartAxis.pixelY(values[i], domain: domain, height: plotHeight)
        }
        var y = order.map { natural[$0] }
        let bottom = plotHeight - inset
        if y.count > 1 {
            for i in 1..<y.count where y[i] < y[i - 1] + gap { y[i] = y[i - 1] + gap }
            if y[y.count - 1] > bottom {
                y[y.count - 1] = bottom
                for i in stride(from: y.count - 2, through: 0, by: -1) where y[i] > y[i + 1] - gap {
                    y[i] = y[i + 1] - gap
                }
            }
            if y[0] < inset {
                let shift = inset - y[0]
                for i in y.indices { y[i] = min(y[i] + shift, bottom) }
                for i in stride(from: y.count - 2, through: 0, by: -1) where y[i] > y[i + 1] - gap {
                    y[i] = y[i + 1] - gap
                }
            }
        } else {
            y[0] = max(inset, min(bottom, y[0]))
        }
        var out: [Placement] = []
        for (position, index) in order.enumerated() {
            out.append(Placement(index: index, centerY: y[position], dy: y[position] - natural[index]))
        }
        return out.sorted { $0.index < $1.index }
    }
}

/// Text metrics for the right-hand gutter.
///
/// [T-chart-label-physical] The estimate below is only the FALLBACK: a view
/// that can measure the rendered text (UIKit glyph advances, same size and
/// weight as the label) passes the real widths in, so the reserved gutter is
/// the space the glyphs actually need. That is the fix for the build-8ec8992
/// screenshot, where "中国" (bold, 10pt) reached the "5" axis label: the
/// per-Unicode-class estimate was narrower than the rendered glyphs and the
/// 6pt safety gap was eaten by the difference.
enum MUChartLabelMetrics {
    struct Gutter: Equatable {
        /// The whole reserved strip: label box + annotation spacing + gap.
        let width: CGFloat
        /// [T-chart-label-physical] The box the label is drawn in (widest
        /// label). The view sets it with `.frame(width:)` and leading
        /// alignment, so a label can never paint past `width` — the gap to the
        /// axis is a layout guarantee, not an estimate.
        let labelWidth: CGFloat
        let fontSize: CGFloat
        let labels: [String]
        let truncated: Bool
    }

    static func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        var units: CGFloat = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 32 { units += 0.28 }
            else if (48...57).contains(v) { units += 0.55 }
            else if (97...122).contains(v) { units += 0.56 }
            else if (65...90).contains(v) { units += 0.64 }
            else if v < 128 { units += 0.45 }
            else if (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v)
                        || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
                        || (0x3040...0x30FF).contains(v) { units += 1.0 }
            else { units += 0.62 }
        }
        return units * fontSize + 1
    }

    /// Gutter for the end labels: the widest label plus the annotation spacing
    /// and a safety gap, shrunk (font 10 → 9 → 8, then truncated) when the phone
    /// is narrow or the names are long. `width` never exceeds the cap, so the
    /// plot keeps most of the card.
    ///
    /// - Parameters:
    ///   - widths: [T-chart-label-physical] real widths of `labels`, measured
    ///     by the caller at `fontSize`. When present they replace the estimate
    ///     (scaled when the font has to shrink) — the gutter is then the space
    ///     the glyphs need, not a model of it.
    ///   - measure: measure used only for the truncation fallback.
    ///   - gap: [T-chart-label-physical] blank strip between the label box and
    ///     the axis. 10pt: the axis numbers are drawn outside the plot, and the
    ///     complaint was that 6pt of nominal gap still read as "touching".
    static func gutter(labels: [String], fontSize: CGFloat, available: CGFloat,
                       spacing: CGFloat = 3, gap: CGFloat = 10,
                       maxFraction: CGFloat = 0.42,
                       widths: [CGFloat]? = nil,
                       measure: ((String, CGFloat) -> CGFloat)? = nil) -> Gutter {
        guard !labels.isEmpty else {
            return Gutter(width: 0, labelWidth: 0, fontSize: fontSize, labels: labels, truncated: false)
        }
        /// Width of the widest label at `size`: measured (scaled from
        /// `fontSize`) when the caller supplied real widths.
        func widest(at size: CGFloat) -> CGFloat {
            if let widths, widths.count == labels.count {
                let scale = size / max(1, fontSize)
                return (widths.max() ?? 0) * scale
            }
            let f = measure ?? { width($0, fontSize: $1) }
            return labels.map { f($0, size) }.max() ?? 0
        }
        let cap = max(56, max(120, available) * maxFraction)
        var size = max(8, fontSize)
        for candidate in [max(8, fontSize), max(8, fontSize - 1), max(8, fontSize - 2)] {
            size = candidate
            let box = widest(at: candidate)
            if box + spacing + gap <= cap {
                return Gutter(width: box + spacing + gap, labelWidth: box, fontSize: candidate,
                              labels: labels, truncated: false)
            }
        }
        let room = max(8, cap - spacing - gap)
        let f = measure ?? { width($0, fontSize: $1) }
        let fitted = labels.map { text -> String in
            guard f(text, size) > room else { return text }
            var out = ""
            for character in text {
                let candidate = out + String(character)
                if f(candidate + "…", size) > room { break }
                out = candidate
            }
            if out.isEmpty { out = String(text.first ?? " ") }
            return out + "…"
        }
        let box = min(room, fitted.map { f($0, size) }.max() ?? room)
        return Gutter(width: min(cap, box + spacing + gap), labelWidth: box, fontSize: size,
                      labels: fitted, truncated: fitted != labels)
    }

    static func fit(_ text: String, room: CGFloat, fontSize: CGFloat) -> String {
        guard width(text, fontSize: fontSize) > room else { return text }
        var out = ""
        for character in text {
            let candidate = out + String(character)
            if width(candidate + "…", fontSize: fontSize) > room { break }
            out = candidate
        }
        if out.isEmpty { out = String(text.first ?? " ") }
        return out + "…"
    }
}

// MARK: - Phase 1 owned chart geometry (Foundation only)
/// Horizontal positions are panel-relative. Charts never owns either text column.
struct MUChartColumns: Equatable {
    static let innerInset: CGFloat = 10
    static let curveGap: CGFloat = 4
    static let axisGap: CGFloat = 6
    let width: CGFloat
    let inset: CGFloat
    let plotWidth: CGFloat
    let labelWidth: CGFloat
    let axisWidth: CGFloat
    var plotMinX: CGFloat { inset }
    var plotMaxX: CGFloat { inset + plotWidth }
    var labelMinX: CGFloat { plotMaxX + (labelWidth > 0 ? Self.curveGap : 0) }
    var labelMaxX: CGFloat { labelMinX + labelWidth }
    var axisMinX: CGFloat { labelMaxX + Self.axisGap }
    var axisMaxX: CGFloat { axisMinX + axisWidth }
    var rightInset: CGFloat { width - axisMaxX }

    /// Input widths are actual glyph measurements, rounded UP to physical points.
    /// Long names are fitted before calling this function; no invisible padding
    /// is delegated to Chart. Even bars without end names keep the 6pt axis gap.
    static func layout(width: CGFloat, labelWidth: CGFloat, axisWidth: CGFloat) -> Self {
        let w = max(80, width)
        let l = max(0, ceil(labelWidth)), a = max(0, ceil(axisWidth))
        let gaps = axisGap + (l > 0 ? curveGap : 0)
        return Self(width: w, inset: innerInset,
                    plotWidth: max(0, w - 2 * innerInset - l - a - gaps),
                    labelWidth: l, axisWidth: a)
    }
}

enum MUChartTypography {
    static let title: CGFloat = 16
    static let subtitle: CGFloat = 13
    static let legend: CGFloat = 12
    static let tick: CGFloat = 11
    static let source: CGFloat = 10.5
    static let plotHeight: CGFloat = 180
    static let xAxisHeight: CGFloat = 22
    static let plotTop: CGFloat = 16

    /// Mirrors the explicit row heights and 4pt stack gaps in MUMultiChartBody.
    /// Theme choice changes no geometry. Text remains native SF, not Econ Sans.
    static func estimatedHeight(title: String?, subtitle: String?, source: String?,
                                seriesCount: Int, kind: String, width: CGFloat,
                                framed: Bool) -> CGFloat {
        func lines(_ text: String, size: CGFloat) -> CGFloat {
            let room = max(30, width - 2 * MUChartColumns.innerInset)
            return text.split(separator: "\n", omittingEmptySubsequences: false).map {
                max(1, ceil(MUChartLabelMetrics.width(String($0), fontSize: size) / room))
            }.reduce(0, +)
        }
        var heights: [CGFloat] = []
        if framed {
            heights.append(6) // red tag + top rule; clear in system mode
            if let title { heights.append(20 * lines(title, size: self.title)) }
            if let subtitle { heights.append(16 * lines(subtitle, size: self.subtitle)) }
        }
        if seriesCount > 1 && kind != "line" {
            let rows = ceil(CGFloat(seriesCount) / 2)
            heights.append(rows * 16 + max(0, rows - 1) * 4)
        }
        heights.append(plotHeight + xAxisHeight + plotTop)
        if framed, let source { heights.append(13 * lines(source, size: self.source)) }
        return ceil(heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 4 + (framed ? 20 : 4))
    }
}

extension MUChartAxis {
    static func ticks(domain: MUChartDomain) -> [Double] {
        let step = niceStep(domain.span / 4)
        guard step.isFinite, step > 0 else { return [0] }
        let start = ceil(domain.lower / step) * step
        var result: [Double] = []
        for index in 0...8 {
            let value = start + Double(index) * step
            if value <= domain.upper + step * 1e-6 {
                result.append(abs(value) < step * 1e-6 ? 0.0 : value)
            }
        }
        return result
    }
}

/// A value carried by each theme; all Phase 1 presets deliberately use the
/// same phone scale. Keeping the values in Foundation also ties them to sizing.
struct MUChartFontScale: Equatable {
    let title: CGFloat
    let subtitle: CGFloat
    let legend: CGFloat
    let tick: CGFloat
    let source: CGFloat
    static let phone = Self(title: MUChartTypography.title, subtitle: MUChartTypography.subtitle,
                            legend: MUChartTypography.legend, tick: MUChartTypography.tick,
                            source: MUChartTypography.source)
}
