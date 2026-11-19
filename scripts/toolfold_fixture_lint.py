#!/usr/bin/env python3
"""[T-toolgroup-accordion] A Swift-source analyser for the two fixture files.

WHY THIS EXISTS
The Tool fold UIKit fixture (`scripts/toolfold-uikit-tests/*.swift`) is only ever
compiled by the Darwin CI job, because it needs UIKit. Run 44485598270 was the
first run that actually reached that compile and it failed with 24 type errors in
`ToolFoldUIKitFixture.swift` — code that had been *parsed* (`swiftc -frontend
-parse`) many times and always looked green:

  * `msg.id` / `run` used in functions that never declared them (the plan was
    built with a scalar stand-in instead of the fixture's own list items),
  * `flight.spanIsValid` (a member that no longer exists: the flight retired on
    `liveItems` / `planStillMatches`),
  * `(1...3).map { ToolGroupRowView.rowHeight }` (a closure that ignores its
    argument; Swift requires `_ in`),
  * `guard let self` inside a closure that captured `self` STRONGLY.

`-parse` cannot see any of those: they are scope, member, arity and capture
errors, i.e. the type checker's job. This analyser re-checks exactly those
classes on plain Linux Python, so a re-introduction is caught in the same run
that would otherwise stay green until Darwin.

It is NOT a type checker and it does not claim to be one: it checks the specific,
enumerable traps below, and `scripts/toolfold-uikit-typecheck/` (when present)
does the stub-level typecheck. `TOOLFOLD_UIKIT_TYPECHECK` on Darwin remains the
only real typecheck.

RULES
  unscoped-identifier   a `<lowerIdent>.<member>` base that is declared nowhere
                        in the enclosing function / type / file
  plan-labels           `ToolGroupAccordionFlight.Plan(...)` labels must equal the
                        declared member order (Swift's memberwise init is
                        positional; `anchorY` before `headerItem`)
  plan-identity         a Plan's `headerItem` / `memberItems` must come from the
                        file's own `[MessageListItem]`, never be re-derived from
                        scalar ids at the call site
  stale-member          a `ToolGroupAccordionFlight` member that the production
                        class does not declare (e.g. the removed `spanIsValid`)
  live-items            every flight the fixture builds must be wired to the real
                        snapshot (`liveItems = { ... listItems }`), else the
                        retirement cases cannot fire
  closure-arity         `.map { <expr> }` without `_ in` / `$0`, or `$1` in a
                        one-parameter API (tuple destructuring)
  self-capture          `guard let self` / `if let self` in a closure that did not
                        capture `self` weakly

usage:
  python3 scripts/toolfold_fixture_lint.py [--json]
  (import) lint_file(text, ...) -> [Finding]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts/toolfold-uikit-tests/ToolFoldUIKitFixture.swift"
ENTRY = ROOT / "scripts/toolfold-uikit-tests/ToolGroupToggleEntryStage.swift"
FLIGHT = ROOT / "src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionFlight.swift"
TXN = ROOT / "src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionToggle.swift"
MEASURE = ROOT / "src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionMeasurement.swift"
LAYOUT = ROOT / "src/ios/Agent/MessageList/MessageListLayout.swift"
# Everything the Tool fold UIKit job links. The production files belong here:
# run 44490117255 proved `ToolGroupAccordionFlight.swift` had never been compiled
# either (the app job is skipped in incremental scope), so it carries the same
# Darwin-only traps as the fixture and must be linted with it.
TARGETS = (FIXTURE, ENTRY, FLIGHT, TXN, MEASURE)

SWIFT_KEYWORDS = {
    "self", "Self", "super", "true", "false", "nil", "return", "if", "else", "guard",
    "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue",
    "let", "var", "func", "init", "deinit", "struct", "class", "enum", "protocol",
    "extension", "import", "typealias", "where", "as", "is", "try", "catch", "throw",
    "throws", "do", "defer", "inout", "operator", "static", "final", "override",
    "public", "private", "fileprivate", "internal", "open", "mutating", "lazy",
    "weak", "unowned", "some", "any", "await", "async", "get", "set", "willSet",
    "didSet", "required", "convenience", "indirect", "subscript", "associatedtype",
}
# Lower-case names that are legitimately unbound at a use site.
KNOWN_SYMBOLS = {
    "abs", "min", "max", "zip", "print", "stride", "pow", "sqrt", "floor", "ceil",
    "round", "exit", "fatalError", "precondition", "assert", "swap", "type", "debugPrint",
    "withUnsafePointer", "numericCast", "unsafeBitCast", "MemoryLayout", "withoutActuallyEscaping",
}

CALL_LIKE = ("map", "flatMap", "compactMap", "filter", "allSatisfy", "forEach", "sorted")
ONE_ARG_CALLS = ("map", "flatMap", "compactMap", "filter", "allSatisfy", "forEach", "sorted")


class Finding:
    __slots__ = ("rule", "line", "col", "detail")

    def __init__(self, rule, line, col, detail):
        self.rule, self.line, self.col, self.detail = rule, line, col, detail

    def __str__(self):
        return "%s:%d:%d: %s: %s" % (self.rule, self.line, self.col, self.rule, self.detail)

    def as_dict(self):
        return {"rule": self.rule, "line": self.line, "col": self.col, "detail": self.detail}


# --------------------------------------------------------------------------- #
# Lexical helpers
# --------------------------------------------------------------------------- #
def strip_comments_and_strings(text: str) -> str:
    """Blank out comments and string literals while keeping every offset/line."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and depth:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                else:
                    if text[i] != "\n":
                        out[i] = " "
                    i += 1
        elif ch in "\"'":
            # multi-line strings and ordinary literals; keep newlines
            if text.startswith('"""', i):
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
                while i < n and not text.startswith('"""', i):
                    if text[i] != "\n":
                        out[i] = " "
                    i += 1
                if i < n:
                    out[i] = out[i + 1] = out[i + 2] = " "
                    i += 3
                continue
            quote, i = ch, i + 1
            if quote in out:
                out[0] = out[0]  # no-op, keep linters quiet
            while i < n:
                if text[i] == "\\":
                    out[i] = " "
                    if i + 1 < n and text[i + 1] != "\n":
                        out[i + 1] = " "
                    i += 2
                    continue
                if text[i] == quote:
                    out[i] = " "
                    i += 1
                    break
                if text[i] == "\n":
                    i += 1
                    break
                out[i] = " "
                i += 1
        else:
            i += 1
    return "".join(out)


def line_col(text: str, offset: int):
    line = text.count("\n", 0, offset) + 1
    col = offset - (text.rfind("\n", 0, offset) + 1) + 1
    return line, col


def match_brace(text: str, open_at: int) -> int:
    """Offset just past the `}` matching the `{` at open_at (text is already stripped)."""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


MODS = r"(?:@\w+\s+|private(?:\(set\))?\s+|fileprivate\s+|internal\s+|public\s+|open\s+|static\s+|final\s+|override\s+|class\s+|mutating\s+|lazy\s+)*"


def enclosing_type_members(clean: str) -> dict:
    """Declaration names at the top level of the file and of each `final class` body."""
    decl = r"(?:let|var|func|case|struct|class|enum|protocol|typealias)\s+`?([A-Za-z_]\w*)"
    file_level = set(re.findall(r"^%s%s" % (MODS, decl), clean, re.M))
    # every type body's members, by type name
    by_type: dict[str, set] = {}
    for m in re.finditer(r"\b(?:final\s+)?(?:class|struct|enum|extension)\s+(\w+)", clean):
        brace = clean.find("{", m.end())
        if brace < 0:
            continue
        end = match_brace(clean, brace)
        body = clean[brace:end]
        by_type.setdefault(m.group(1), set()).update(
            re.findall(r"^ {4}%s%s" % (MODS, decl), body, re.M))
    return {"file": file_level, "types": by_type}


def function_spans(clean: str):
    """(name, body_start, body_end, params_text) for every `func` (incl. nested)."""
    out = []
    for m in re.finditer(r"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\(", clean):
        close = _match_paren(clean, m.end() - 1)
        brace = clean.find("{", close)
        if brace < 0:
            continue
        end = match_brace(clean, brace)
        out.append((m.group(1), brace, end, clean[m.end():close]))
    return out


def _match_paren(text: str, open_at: int) -> int:
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return open_at


def declared_names(clean: str, lo: int, hi: int, params_text: str = "") -> set:
    """Every name bound inside the body span: params, lets, fors, closure params."""
    body = clean[lo:hi]
    names = set()
    names.update(re.findall(r"\b(?:let|var)\s+`?([a-z_]\w*)", body))
    names.update(re.findall(r"\bfor\s+`?([a-z_]\w*)\s+in\b", body))
    names.update(re.findall(r"\bcase\s+(?:let\s+)?`?([a-z_]\w*)\b", body))
    names.update(re.findall(r"\{[^{}\n]{0,60}?\b([a-z_]\w*)\s*(?:,\s*[a-z_]\w*\s*)*\bin\b", body))
    names.update(re.findall(r"\{\s*([a-z_]\w*)\s+in\b", body))
    # tuple patterns: `for (k, a) in ...`, `case let (a, b)`
    for grp in re.findall(r"\bfor\s*\(([^)]*)\)\s*in\b", body):
        names.update(re.findall(r"[a-z_]\w*", grp))
    for grp in re.findall(r"\b(?:var|let)\s*\(([^)]*)\)", body):
        names.update(re.findall(r"[a-z_]\w*", grp))
    # function parameters of the enclosing func
    for p in params_text.split(","):
        p = p.strip()
        if not p:
            continue
        head = p.split(":")[0].strip().split()
        if head:
            names.add(head[-1].strip("`"))
    # closure capture lists: [weak self] / [unowned self, x = y]
    for m in re.finditer(r"\[\s*(?:weak\s+|unowned\s+)?([a-z_]\w*)\s*(?:=[^\]]*)?\]", body):
        pass
    return {n for n in names if n and n not in SWIFT_KEYWORDS}


def _closure_capture_lists(clean: str, lo: int, hi: int):
    """(offset, capture names) for every closure header inside the span."""
    out = []
    for m in re.finditer(r"\{", clean[lo:hi]):
        at = lo + m.start()
        tail = clean[at:at + 120]
        cap = re.match(r"\{\s*\[([^\]]*)\]", tail)
        if cap:
            names = set(re.findall(r"(?:weak\s+|unowned(?:\(safe\)\s+)?)(\w+)", cap.group(1)))
            out.append((at, names))
    return out


# --------------------------------------------------------------------------- #
# Structural helpers
# --------------------------------------------------------------------------- #
def struct_members(text: str, name: str):
    """Member names of `struct <name>` (or `class`/`enum`) in declaration order."""
    head = re.search(r"\b(?:struct|final class|class|enum)\s+%s\b[^{]*\{" % re.escape(name), text)
    if not head:
        return []
    body = text[head.end():match_brace(text, head.end() - 1)]
    return re.findall(r"^\s{4,}%s(?:let|var|func)\s+`?(\w*)" % MODS, body, re.M)


def call_labels(text: str, callee: str):
    """(offset, labels) for every `<callee>(...)` call (top-level labels only)."""
    out = []
    for m in re.finditer(re.escape(callee) + r"\(", text):
        open_at = m.end() - 1
        close = _match_paren(text, open_at)
        args, depth, chunk = [], 0, ""
        for ch in text[open_at + 1:close]:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                args.append(chunk)
                chunk = ""
            else:
                chunk += ch
        args.append(chunk)
        labels = []
        for a in args:
            lab = re.match(r"\s*(\w+)\s*:", a)
            labels.append(lab.group(1) if lab else "")
        out.append((m.start(), labels, args))
    return out


def closure_bodies(text: str, call_end_paren: int, body_text: str):
    """Split a call's argument text into (is_closure, closure_text)."""
    return body_text


def map_closures(text: str):
    """Yield (offset, api, body_start, body_end) for `.api { ... }`.

    Offsets are used so the caller can read the RAW slice: string interpolation
    (`{ "\\($0)" }`) is invisible in the comment/string-stripped text, and a
    closure that only mentions `$0` inside interpolation is NOT ignoring it.
    """
    out = []
    for api in CALL_LIKE:
        for m in re.finditer(r"\.%s\s*(?:\([^(){}]*\)\s*)?\{" % api, text):
            brace = text.index("{", m.end() - 1)
            end = match_brace(text, brace)
            out.append((m.start(), api, brace + 1, end - 1))
    return out


def second_offset(text: str, needle: str, after: int) -> int:
    i = text.find(needle, after)
    return i


def _closes_with(clean: str, brace: int) -> int:
    return match_brace(clean, brace)


# --------------------------------------------------------------------------- #
# The rules
# --------------------------------------------------------------------------- #
def rule_unscoped(raw: str, clean: str, members, findings):
    spans = function_spans(clean)
    for name, lo, hi, params in spans:
        local = declared_names(clean, lo, hi, params)
        # a nested func sees its enclosing func's locals (captures)
        for _n, olo, ohi, oparams in spans:
            if (olo, ohi) != (lo, hi) and olo <= lo and hi <= ohi:
                local |= declared_names(clean, olo, ohi, oparams)
        for m in re.finditer(r"(?<![\w.`$])([a-z_][A-Za-z0-9_]*)\.", clean[lo:hi]):
            base = m.group(1)
            if base in SWIFT_KEYWORDS or base in local or base in KNOWN_SYMBOLS:
                continue
            if base in members["file"]:
                continue
            if any(base in s for s in members["types"].values()):
                continue
            at = lo + m.start(1)
            line, col = line_col(raw, at)
            findings.append(Finding("unscoped-identifier", line, col,
                                    "`%s` is not declared in `%s` (scope/typo: Swift says \"cannot find "
                                    "'%s' in scope\")" % (base, name, base)))


def rule_plan(raw: str, clean: str, flight_src: str, findings):
    want = struct_members(flight_src, "Plan")
    for at, labels, args in call_labels(clean, "ToolGroupAccordionFlight.Plan"):
        line, col = line_col(raw, at)
        if labels != want:
            findings.append(Finding("plan-labels", line, col,
                                    "Plan labels %s != declared order %s" % (labels, want)))
        for lab, value in zip(labels, args):
            v = value.split(":", 1)[1] if ":" in value else value
            if lab in ("headerItem", "memberItems") and re.search(r"\.(toolGroup|assistantBlock|assistantFooter|wholeMessage)\s*\(", v):
                findings.append(Finding("plan-identity", line, col,
                                        "`%s` is re-derived from scalar ids instead of the file's own "
                                        "[MessageListItem] snapshot" % lab))


def rule_stale_member(raw: str, clean: str, flight_src: str, findings):
    declared = set(struct_members(flight_src, "ToolGroupAccordionFlight"))
    declared |= set(re.findall(r"^\s{4}%s(?:let|var|func)\s+`?(\w*)" % MODS, flight_src, re.M))
    for body in ("flight", "accordionFlight"):
        for m in re.finditer(r"\b%s\??\.([A-Za-z_]\w*)" % body, clean):
            member = m.group(1)
            if member in declared or member in SWIFT_KEYWORDS:
                continue
            line, col = line_col(raw, m.start(1))
            findings.append(Finding("stale-member", line, col,
                                    "ToolGroupAccordionFlight has no member `%s` (declared: %s)" %
                                    (member, ", ".join(sorted(declared)[:8]) + " ...")))


def rule_live_items(raw: str, clean: str, findings):
    sites = list(re.finditer(r"ToolGroupAccordionFlight\s*\(\s*collectionView\s*:", clean))
    for m in sites:
        enclosing = [f for f in function_spans(clean) if f[1] < m.start() < f[2]]
        line, col = line_col(raw, m.start())
        if not enclosing:
            findings.append(Finding("live-items", line, col, "flight built outside any function"))
            continue
        name, lo, hi, _params = enclosing[-1]
        body = clean[lo:hi]
        if not re.search(r"\.liveItems\s*=", body):
            findings.append(Finding("live-items", line, col,
                                    "the flight built in `%s` is not wired to the list's real items "
                                    "(`liveItems`), so identity retirement can never fire" % name))


def rule_closure_arity(raw: str, clean: str, findings):
    for at, api, body_lo, body_hi in map_closures(clean):
        body = raw[body_lo:body_hi]
        head = body.split("\n")[0]
        has_in = re.search(r"\bin\b", head) or re.match(r"\s*[\w,\s]*\bin\b", body)
        uses_arg = "$0" in clean[body_lo:body_hi] or "$0" in body
        if not has_in and not uses_arg and body.strip():
            line, col = line_col(raw, at)
            findings.append(Finding("closure-arity", line, col,
                                    "`%s` closure ignores its argument (%r): Swift expects 1 argument, "
                                    "which cannot be implicitly ignored; write `{ _ in ... }`" %
                                    (api, body.strip()[:40])))


def rule_self_capture(raw: str, clean: str, findings):
    for m in re.finditer(r"\b(?:guard|if)\s+let\s+self\b", clean):
        open_at = clean.rfind("{", 0, m.start())
        if open_at < 0:
            continue
        caps = [c for c in _closure_capture_lists(clean, open_at, m.start() + 1) if c[0] == open_at]
        weak = bool(caps and "self" in caps[0][1])
        if not weak:
            line, col = line_col(raw, m.start())
            findings.append(Finding("self-capture", line, col,
                                    "`guard let self` needs a `[weak self]` closure: with a strong "
                                    "capture `self` is not Optional and the binding cannot compile"))


RULES = ("unscoped-identifier", "plan-labels", "plan-identity", "stale-member",
         "live-items", "closure-arity", "self-capture",
         "nested-type-scope", "optional-unwrapped")


def nested_types(text: str) -> dict:
    """{nested type name: owner} for types declared at indent 4 in a top-level type."""
    out = {}
    for m in re.finditer(r"^(?:final\s+)?(?:class|struct|enum|actor)\s+(\w+)", text, re.M):
        owner = m.group(1)
        brace = text.find("{", m.end())
        if brace < 0:
            continue
        body = text[brace:match_brace(text, brace)]
        for n in re.finditer(r"^ {4}(?:final\s+)?(?:class|struct|enum)\s+(\w+)", body, re.M):
            out[n.group(1)] = owner
    return out


def rule_nested_type_scope(raw: str, clean: str, owners: dict, filename: str, findings):
    """A type nested in another type must be qualified outside its own file.

    `MessageListLayout.ToolGroupAccordionSpan` is declared INSIDE
    `MessageListLayout` (indent 4). `ToolGroupAccordionSpan(...)` in
    ToolGroupAccordionFlight.swift was therefore "cannot find
    'ToolGroupAccordionSpan' in scope" — run 44490117255:137.
    """
    for name, owner in owners.items():
        if filename == LAYOUT.name:
            continue          # its own file: unqualified is legal inside the owner
        for m in re.finditer(r"(?<![\w.])%s\b" % re.escape(name), clean):
            before = clean[max(0, m.start() - 40):m.start()]
            if re.search(r"(?:class|struct|enum|actor|typealias)\s+$", before):
                continue      # its own declaration
            if re.search(r"%s\.\s*$" % re.escape(owner), before):
                continue      # already qualified
            line, col = line_col(raw, m.start())
            findings.append(Finding("nested-type-scope", line, col,
                                    "`%s` is nested in `%s`; outside %s it must be written "
                                    "`%s.%s` (cannot find it in scope)" %
                                    (name, owner, LAYOUT.name, owner, name)))


def rule_optional_unwrapped(raw: str, clean: str, findings):
    """A member of an OPTIONAL property needs a binding, not a `!= nil` guard.

    `guard let cv = collectionView, plan != nil` then `plan.headerIndex` is
    "value of optional type 'Plan?' must be unwrapped" (run 44490117255:235/240).
    """
    optional = set()
    for m in re.finditer(r"^ {4}(?:@\w+\s+)?(?:private\(set\)\s+|private\s+|weak\s+|lazy\s+)*"
                         r"var\s+`?(\w+)`?\s*:\s*[^=\n{]*\?\s*(?:=|$)", clean, re.M):
        optional.add(m.group(1))
    if not optional:
        return
    for name, lo, hi, params in function_spans(clean):
        body = clean[lo:hi]
        # `guard let plan`, `if let plan`, `let plan = self.plan` or a parameter
        bound = declared_names(clean, lo, hi, params)
        for m in re.finditer(r"(?<![\w.?])(\w+)\.(?=[a-z_])", body):
            prop = m.group(1)
            if prop not in optional or prop in bound:
                continue
            if clean[lo + m.start() - 2:lo + m.start()] .strip().endswith("."):
                continue
            line, col = line_col(raw, lo + m.start(1))
            findings.append(Finding("optional-unwrapped", line, col,
                                    "`%s` is an Optional property of this type: bind it "
                                    "(`guard let %s = %s`), do not read `%s.%s` directly" %
                                    (prop, prop, prop, prop, m.group(0)[len(prop) + 1:])))


def lint_text(raw: str, flight_src: str, owners: dict = None, filename: str = "") -> list:
    clean = strip_comments_and_strings(raw)
    members = enclosing_type_members(clean)
    findings: list = []
    rule_unscoped(raw, clean, members, findings)
    rule_plan(raw, clean, flight_src, findings)
    rule_stale_member(raw, clean, flight_src, findings)
    rule_live_items(raw, clean, findings)
    rule_closure_arity(raw, clean, findings)
    rule_self_capture(raw, clean, findings)
    if owners:
        rule_nested_type_scope(raw, clean, owners, filename, findings)
    rule_optional_unwrapped(raw, clean, findings)
    findings.sort(key=lambda f: (f.line, f.col, f.rule))
    return findings


# --------------------------------------------------------------------------- #
# Frozen negatives: the 24 errors of run 44485598270, as executable cases
# --------------------------------------------------------------------------- #
FROZEN = [
    # (rule, original file:line:col, source that must be flagged, what it is)
    ("unscoped-identifier", "ToolFoldUIKitFixture.swift:519:80", "final class C {\n    func begin() {\n        let p = (msg.id, run.firstBlockId)\n    }\n}\n",
     "cannot find 'run' in scope (beginAccordionFlight never declared it)"),
    ("unscoped-identifier", "ToolFoldUIKitFixture.swift:519:76", "final class C {\n    func begin() {\n        let p = msg.id\n    }\n}\n",
     "type 'msg' has no member 'id'"),
    ("plan-labels", "ToolFoldUIKitFixture.swift:518:49",
     "final class C {\n    func f() {\n        _ = ToolGroupAccordionFlight.Plan(memberRange: 1...3, naturalHeights: [],\n            headerIndex: 0, headerItem: it, memberItems: [], anchorY: 0)\n    }\n}\n",
     "Plan labels out of declaration order (anchorY belongs before headerItem)"),
    ("plan-identity", "ToolFoldUIKitFixture.swift:519:76",
     "final class C {\n    func f() {\n        _ = ToolGroupAccordionFlight.Plan(memberRange: 1...3, naturalHeights: [], headerIndex: 0,\n            anchorY: 0, headerItem: .toolGroup(msg.id, run.firstBlockId), memberItems: [])\n    }\n}\n",
     "the plan identity was re-derived from scalar ids instead of the fixture's items"),
    ("stale-member", "ToolFoldUIKitFixture.swift:738:20",
     "final class C {\n    func f() {\n        let flight = makeFlight()\n        flight.spanIsValid = { _ in true }\n    }\n}\n",
     "value of type 'ToolGroupAccordionFlight' has no member 'spanIsValid'"),
    ("closure-arity", "ToolFoldUIKitFixture.swift:636:35",
     "final class C {\n    func f() {\n        let heights = (1...3).map { ToolGroupRowView.rowHeight }\n    }\n}\n",
     "contextual type for closure argument list expects 1 argument, which cannot be implicitly ignored"),
    ("closure-arity", "ToolFoldUIKitFixture.swift:754:35",
     "final class C {\n    func f() {\n        let heights = (1...3).map { 28 }\n    }\n}\n",
     "same defect on the reduce-motion close path"),
    ("self-capture", "ToolFoldUIKitFixture.swift:782:19",
     "final class C {\n    func f() {\n        g { \n            guard let self else { return }\n            self.h()\n        }\n    }\n}\n",
     "initializer for conditional binding must have Optional type, not 'C'"),
    ("nested-type-scope", "ToolGroupAccordionFlight.swift:137:38",
     "final class F {\n    func start(_ layout: L) {\n        layout.set(ToolGroupAccordionSpan(lowerBound: 0))\n    }\n}\n",
     "cannot find 'ToolGroupAccordionSpan' in scope (it is nested in MessageListLayout)"),
    ("optional-unwrapped", "ToolGroupAccordionFlight.swift:235:98",
     "struct Plan { var headerIndex: Int }\nfinal class F {\n    private var plan: Plan?\n    func tick() {\n        guard plan != nil else { return }\n        print(plan.headerIndex)\n    }\n}\n",
     "value of optional type 'Plan?' must be unwrapped to refer to member 'headerIndex'"),
    ("optional-unwrapped", "ToolGroupAccordionFlight.swift:240:44",
     "struct Plan { var memberRange: ClosedRange<Int> }\nfinal class F {\n    var plan: Plan?\n    func tick() {\n        guard plan != nil else { return }\n        print(plan.memberRange.upperBound)\n    }\n}\n",
     "same site: memberRange read through the Optional"),
    ("live-items", "ToolFoldUIKitFixture.swift:521:21",
     "final class C {\n    func f() {\n        let flight = ToolGroupAccordionFlight(collectionView: list, layout: l)\n        flight.start(p, direction: .expand) { _ in }\n    }\n}\n",
     "a flight with no liveItems can never retire on identity"),
]

# Mutations of the CURRENT fixture: the analyser must still see each one.
MUTATIONS = [
    ("closure-arity", lambda t: t.replace("(1...3).map { _ in ToolGroupRowView.rowHeight }",
                                         "(1...3).map { ToolGroupRowView.rowHeight }", 1)),
    ("stale-member", lambda t: t.replace("        let flight = makeFlight()\n        flight.reduceMotion = { true }",
                                         "        let flight = makeFlight()\n        flight.spanIsValid = { _ in true }\n        flight.reduceMotion = { true }", 1)),
    ("unscoped-identifier", lambda t: t.replace("        guard let scene = currentScene else { check(false, \"the accordion stage keeps its scene\"); return }",
                                                "        guard let scene = currentScene else { check(false, \"x\"); return }\n        _ = msg.id", 1)),
    ("self-capture", lambda t: t.replace("[weak self] in\n            guard let self, let stage = self.entryStage",
                                         "in\n            guard let self, let stage = self.entryStage", 1)),
    ("plan-labels", lambda t: t.replace("ToolGroupAccordionFlight.Plan(memberRange: memberRange,\n                                      naturalHeights: heights,\n                                      headerIndex: 0,\n                                      anchorY: anchorY,",
                                        "ToolGroupAccordionFlight.Plan(memberRange: memberRange,\n                                      naturalHeights: heights,\n                                      headerIndex: 0,\n                                      headerItem: scene.items[0],\n                                      anchorY: anchorY,", 1)),
    ("plan-identity", lambda t: t.replace("headerItem: scene.items[0],",
                                          "headerItem: .toolGroup(scene.message.id, scene.run.firstBlockId),", 1)),
    ("live-items", lambda t: t.replace("flight.liveItems = { [weak self] in self?.listItems }", "// removed", 1)),
    # run 44490117255: the two PRODUCTION errors, reverted in the real file
    ("optional-unwrapped", lambda t: t.replace(
        "guard let cv = collectionView, let plan = self.plan else",
        "guard let cv = collectionView, plan != nil else", 1)),
    ("nested-type-scope", lambda t: t.replace(
        "MessageListLayout.ToolGroupAccordionSpan(", "ToolGroupAccordionSpan(", 1)),
]


def self_test(verbose=False) -> int:
    """Every frozen negative and every mutation must be caught; the files must be clean."""
    flight_src = FLIGHT.read_text()
    owners = nested_types(LAYOUT.read_text())
    bad = 0
    for rule, where, src, what in FROZEN:
        got = {f.rule for f in lint_text(src, flight_src, owners, "SomeOtherFile.swift")}
        ok = rule in got
        bad += 0 if ok else 1
        if verbose or not ok:
            print("  %s frozen negative %-38s %-22s %s" % ("OK " if ok else "FAIL", rule, where, what))
    texts = [(p, p.read_text()) for p in TARGETS]
    applied = 0
    for mut_rule, mutate in MUTATIONS:
        # each mutation must apply to at least one of the two files, and be
        # caught in EVERY file it applied to
        hit_any = False
        for path, text in texts:
            mutated = mutate(text)
            if mutated == text:
                continue
            hit_any = True
            got = {f.rule for f in lint_text(mutated, flight_src, owners, path.name)}
            ok = mut_rule in got
            bad += 0 if ok else 1
            if verbose or not ok:
                print("  %s mutation %-22s on %s -> caught=%s" % ("OK " if ok else "FAIL", mut_rule, path.name, sorted(got)))
        if hit_any:
            applied += 1
        else:
            bad += 1
            print("  FAIL mutation %-22s did not apply to either file" % mut_rule)
    for path, text in texts:
        found = lint_text(text, flight_src, owners, path.name)
        if found:
            bad += 1
            print("  FAIL clean file %s has %d finding(s): %s" %
                  (path.name, len(found), [str(f) for f in found[:3]]))
        elif verbose:
            print("  OK  clean file %-38s 0 findings" % path.name)
    print("TOOLFOLD_FIXTURE_LINT_SELFTEST_%s cases=%d failed=%d" %
          ("PASS" if bad == 0 else "FAIL", len(FROZEN) + len(MUTATIONS), bad))
    return 0 if bad == 0 else 1


def main(argv) -> int:
    flight_src = FLIGHT.read_text()
    owners = nested_types(LAYOUT.read_text())
    failed = 0
    total = 0
    for path in TARGETS:
        findings = lint_text(path.read_text(), flight_src, owners, path.name)
        total += 1
        if findings:
            failed += 1
            for f in findings:
                print("%s:%d:%d: %s: %s" % (path.name, f.line, f.col, f.rule, f.detail))
    print("TOOLFOLD_FIXTURE_LINT_%s files=%d failed=%d" % ("PASS" if failed == 0 else "FAIL", total, failed))
    if "--selftest" in argv:
        return self_test(verbose="--json" not in argv) if not failed else 1
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
