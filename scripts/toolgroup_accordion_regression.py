#!/usr/bin/env python3
"""[T-toolgroup-accordion] Local regression for the chat tool-group accordion.

Two halves, both real:

  A. MATH (compiled + RUN, not grepped): the shipping block between
     `// === BEGIN ToolGroupAccordion ===` and `// === END ToolGroupAccordion ===`
     is extracted from the production file and compiled with swiftc on Linux,
     with assertions written here. No UIKit is involved, so this is a genuine
     execution of the numbers the chat list uses at 60fps.
  B. STATIC CONTRACT: the production wiring (layout span, per-frame driver,
     coordinator hooks, reduce-motion path) plus FROZEN NEGATIVE examples of
     the pre-accordion implementation. A static contract is NOT a typecheck or
     a UIKit run — the real UIKit evidence is scripts/toolfold_uikit_regression.py.

usage: python3 scripts/toolgroup_accordion_regression.py [--swiftc swiftc]
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]   # worktree (repo)
NEWROOT = ROOT.parent                        # this round's root (scripts, docs, evidence)
IOS = ROOT / 'src' / 'ios'
MATH_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordion.swift'
FLIGHT_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionFlight.swift'
LAYOUT_SRC = IOS / 'Agent/MessageList/MessageListLayout.swift'
FOLD_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift'
SNAP_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift'
DELEGATE_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ScrollViewDelegate.swift'
SIDEBAR_SRC = IOS / 'Views/ContentView/Sidebar/AccordionCollectionLayout.swift'
SIDEBAR_LIST = IOS / 'Views/ContentView/Sidebar/NativeAccordionList.swift'
# [T-toolgroup-accordion] the shared production transaction + measurement probe
# (the code `toggleToolGroup` calls and the harness drives) and the cell config
# that owns the list-state gate.
TXN_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionToggle.swift'
MEASURE_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupAccordionMeasurement.swift'
CFG_SRC = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+CellConfiguration.swift'
ENTRY = ROOT / 'scripts/toolfold-uikit-tests/ToolGroupToggleEntryStage.swift'
FIXTURE = ROOT / 'scripts/toolfold-uikit-tests/ToolFoldUIKitFixture.swift'
DRIVER = ROOT / 'scripts/toolfold_uikit_regression.py'

BEGIN = '// === BEGIN ToolGroupAccordion ==='
END = '// === END ToolGroupAccordion ==='

SWIFT_MAIN = r'''
var failed = 0
var checks = 0
func ck(_ ok: Bool, _ label: String) {
    checks += 1
    if !ok { failed += 1; print("FAIL \(label)") }
}
func close(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-6) -> Bool { abs(a - b) <= tol }

// --- duration parity with the home sidebar accordion ---
ck(ToolGroupAccordion.duration == 0.32, "duration is the sidebar's 0.32s")

// --- smoothstep, byte-identical shape to AccordionMotion.ease ---
ck(close(ToolGroupAccordion.ease(0), 0), "ease(0)=0")
ck(close(ToolGroupAccordion.ease(1), 1), "ease(1)=1")
ck(close(ToolGroupAccordion.ease(0.5), 0.5), "ease(0.5)=0.5")
ck(close(ToolGroupAccordion.ease(-3), 0) && close(ToolGroupAccordion.ease(9), 1), "ease clamps")
var prev: CGFloat = -1
var monotonic = true
for i in 0...64 {
    let v = ToolGroupAccordion.ease(CGFloat(i) / 64)
    if v < prev - 1e-9 { monotonic = false }
    prev = v
}
ck(monotonic, "ease is monotonic")

// --- progress clock ---
ck(ToolGroupAccordion.progress(elapsed: 0) == 0, "progress(0)=0")
ck(ToolGroupAccordion.progress(elapsed: 0.32) == 1, "progress(duration)=1")
ck(ToolGroupAccordion.progress(elapsed: 5) == 1, "progress past the end stays 1")
ck(close(ToolGroupAccordion.progress(elapsed: 0.16), 0.5), "progress(half) is the eased half")
ck(ToolGroupAccordion.progress(elapsed: 0.1, duration: 0) == 1, "zero duration means instant")

// --- reveal heights: clip, never scale; sum == total*reveal ---
let natural: [CGFloat] = [10, 20, 30]
ck(ToolGroupAccordion.visibleHeights(natural: natural, reveal: 0) == [0, 0, 0], "reveal 0 shows nothing")
ck(ToolGroupAccordion.visibleHeights(natural: natural, reveal: 1) == natural, "reveal 1 shows everything")
let half = ToolGroupAccordion.visibleHeights(natural: natural, reveal: 0.5)
ck(close(half[0], 10) && close(half[1], 20) && close(half[2], 0),
   "50% reveal lands exactly on the row boundary: \(half)")
let clipped = ToolGroupAccordion.visibleHeights(natural: natural, reveal: 0.4)
ck(close(clipped[0], 10) && close(clipped[1], 14) && close(clipped[2], 0),
   "40% reveal clips the SECOND row instead of scaling it: \(clipped)")
var sumOk = true
for i in 0...100 {
    let p = CGFloat(i) / 100
    let shown = ToolGroupAccordion.visibleHeights(natural: natural, reveal: p)
    if !close(shown.reduce(0, +), 60 * p, 1e-4) { sumOk = false }
    if shown.contains(where: { $0 > 30.0001 }) { sumOk = false }
}
ck(sumOk, "revealed height never exceeds natural and sums to total*reveal")
ck(ToolGroupAccordion.visibleHeights(natural: [0, 0], reveal: 0.5) == [0, 0], "zero-height rows stay zero")
ck(ToolGroupAccordion.clippedRow(natural: natural, reveal: 0.5) == nil, "50% lands on a boundary: nothing straddles")
ck(ToolGroupAccordion.clippedRow(natural: natural, reveal: 0.4) == 1, "the straddling row is the clipped one")
ck(ToolGroupAccordion.clippedRow(natural: natural, reveal: 0) == nil, "nothing straddles at reveal 0")
ck(ToolGroupAccordion.clippedRow(natural: natural, reveal: 1) == nil, "nothing straddles at reveal 1")

// --- legal offsets, including content shorter than the viewport ---
ck(ToolGroupAccordion.clampedOffset(5000, contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0) == 1200,
   "offset clamps to the bottom edge")
ck(ToolGroupAccordion.clampedOffset(500, contentHeight: 100, viewportHeight: 800, topInset: 44, bottomInset: 34) == -44,
   "short content: every offset collapses to the top inset (legal)")
ck(ToolGroupAccordion.clampedOffset(-10, contentHeight: 100, viewportHeight: 800, topInset: 44, bottomInset: 34) == -44,
   "short content cannot scroll above the top inset")

// --- anchor: the tapped header keeps its screen Y ---
let a1 = ToolGroupAccordion.anchoredOffset(headerY: 1000, anchorY: 300, contentHeight: 4000,
                                           viewportHeight: 800, topInset: 0, bottomInset: 0)
ck(a1 == 700, "anchor offset puts headerY at anchorY (\(a1))")
ck(ToolGroupAccordion.anchorDrift(headerY: 1000, contentOffset: a1, anchorY: 300) == 0, "drift is zero at the anchor")
let a2 = ToolGroupAccordion.anchoredOffset(headerY: 2000, anchorY: 300, contentHeight: 2100,
                                           viewportHeight: 800, topInset: 0, bottomInset: 0)
ck(a2 == 1300, "anchor clamps at the bottom edge instead of scrolling past it (\(a2))")

print("MATH checks=\(checks) failed=\(failed)")
exit(failed == 0 ? 0 : 2)
'''


def math_checks():
    src = MATH_SRC.read_text()
    begin = src.index(BEGIN)
    end = src.index(END) + len(END)
    block = src[begin:end]
    assert 'enum ToolGroupAccordion' in block, 'the shipping block does not declare ToolGroupAccordion'
    out = ROOT / 'build' / 'toolgroup-accordion'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'main.swift').write_text('import Foundation\n\n' + block + '\n' + SWIFT_MAIN)
    swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
    build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(out / 'accordion'), str(out / 'main.swift')],
                           capture_output=True, text=True)
    (out / 'compile.log').write_text(build.stdout + build.stderr)
    if build.returncode:
        print(build.stdout + build.stderr)
        raise SystemExit('TOOLGROUP_ACCORDION_MATH_COMPILE_FAILED')
    run = subprocess.run([str(out / 'accordion')], capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode:
        print(run.stderr)
        raise SystemExit('TOOLGROUP_ACCORDION_MATH_FAILED')
    line = [l for l in run.stdout.splitlines() if l.startswith('MATH checks=')][0]
    checks = int(line.split('checks=')[1].split()[0])
    return checks


class Contract:
    def __init__(self):
        self.cases = 0
        self.failures = []

    def ok(self, cond, label):
        self.cases += 1
        if not cond:
            self.failures.append(label)

    def absent(self, text, needle, label):
        self.ok(needle not in text, label + ' :: frozen negative must stay absent')

    def present(self, text, needle, label):
        self.ok(needle in text, label + ' :: must be present')



def _strip_line_comments(text):
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def swift_struct_members(text, name):
    """Member names of `struct <name>` in declaration order (8-space indent)."""
    start = text.index("struct %s {" % name)
    end = text.index("\n    }", start)
    body = text[start:end]
    return re.findall(r"^        (?:let|var) (\w+):", body, re.M)


def swift_call_labels(text, callee):
    """Top-level argument labels of every `<callee>(...)` call, in order."""
    text = _strip_line_comments(text)
    out, at = [], 0
    while True:
        i = text.find(callee + "(", at)
        if i < 0:
            return out
        k = i + len(callee) + 1
        depth, chunk, chunks = 1, "", []
        while k < len(text) and depth > 0:
            ch = text[k]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    break
            if depth == 1 and ch == ",":
                chunks.append(chunk)
                chunk = ""
                k += 1
                continue
            if depth >= 1:
                chunk += ch
            k += 1
        chunks.append(chunk)
        labels = []
        for c in chunks:
            m = re.match(r"\s*(\w+)\s*:", c)
            labels.append(m.group(1) if m else "")
        out.append(labels)
        at = k + 1

def ordered_ok(text, parts):
    """True when every part appears, in this order."""
    at = 0
    for part in parts:
        found = text.find(part, at)
        if found < 0:
            return False
        at = found + len(part)
    return True


def _load_fixture_lint():
    """The Swift-source analyser of the fixture (scope/member/arity/capture)."""
    import importlib.util
    path = Path(__file__).resolve().parent / 'toolfold_fixture_lint.py'
    spec = importlib.util.spec_from_file_location('toolfold_fixture_lint', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def swift_declared_access(text, name):
    """How `name` is declared in `text`: 'open' when it is reachable from another
    file, 'private' when the declaration is restricted to its own file.

    Only the declaration that followed the member use matters here: a `func` /
    `var` / `let` line whose modifiers say `private` (or `fileprivate`) cannot be
    called from a different file of the same module — exactly the compile error
    an off-collection helper hits when it reuses a cell's own cleanup hook.
    """
    pattern = (r'^[ \t]*(?:@[A-Za-z_][\w.]*(?:\([^)]*\))?[ \t]+)*'
               r'((?:(?:private|fileprivate|internal|public|open|final|override|static|class|'
               r'mutating|nonisolated|lazy)[ \t]+)*)'
               r'(?:func|var|let)[ \t]+' + re.escape(name) + r'\b')
    m = re.search(pattern, text, re.M)
    if not m:
        return None
    modifiers = m.group(1) or ''
    # `private(set) var x` is still readable from anywhere.
    if 'private(set)' in modifiers.replace(' ', ''):
        return 'open'
    if re.search(r'\b(private|fileprivate)\b', modifiers):
        return 'private'
    return 'open'


def inaccessible_cell_members(source, infra):
    """Members of `SelfSizingCell` this source uses that it cannot actually reach.

    A helper that lives in another file may only touch the cell's internal API;
    reaching for a `private` hook compiles nowhere but the cell's own file, so
    the check is static and needs no Darwin toolchain.
    """
    bad = []
    for name in sorted(set(re.findall(r'\b(?:sizingCell|cell)\.([A-Za-z_][A-Za-z0-9_]*)', source))):
        access = swift_declared_access(infra, name)
        if access == 'private':
            bad.append(name)
    return bad


_sec14 = 0


def static_checks():
    c = Contract()
    math = MATH_SRC.read_text()
    flight = FLIGHT_SRC.read_text()
    layout = LAYOUT_SRC.read_text()
    fold = FOLD_SRC.read_text()
    snap = SNAP_SRC.read_text()
    delegate = DELEGATE_SRC.read_text()
    sidebar = SIDEBAR_SRC.read_text()
    sidebar_list = SIDEBAR_LIST.read_text()
    fixture = FIXTURE.read_text()
    driver = DRIVER.read_text()
    txn = TXN_SRC.read_text()
    measure = MEASURE_SRC.read_text()
    cfg = CFG_SRC.read_text()
    entry = ENTRY.read_text()

    # 1. chat tool-group math keeps its frozen 0.32s smoothstep; sidebar now
    #    uses its own adaptive critically-damped curve [T-home-accordion-motion].
    c.present(math, 'static let duration: Double = 0.32', 'accordion duration constant')
    c.present(sidebar_list, 'AccordionMotion.duration(from: old, to: target,', 'sidebar adaptive duration [T-home-accordion-motion]')
    c.present(sidebar, 'let norm = 1.0 - (1.0 + w) * exp(-w)', 'sidebar critically-damped curve [T-home-accordion-motion]')
    c.present(math, 'return x * x * (3 - 2 * x)', 'accordion smoothstep body (same curve)')
    c.absent(math, 'import UIKit', 'math file stays UIKit-free (Linux-compilable)')

    # 2. the layout owns the reveal, never the cache
    c.present(layout, 'struct ToolGroupAccordionSpan: Equatable', 'layout span type')
    c.present(layout, 'func naturalHeightForAccordion(at index: Int) -> CGFloat', 'layout natural height source')
    c.present(layout, 'if let shown = accordionShown[i] {\n                h = shown', 'prepare() uses the reveal heights')
    c.present(layout, 'attrs.isHidden = true', 'rows below the frontier do not draw')
    c.present(layout, 'if attrs.isHidden { continue }', 'hidden rows are never handed to UIKit')
    c.present(layout, 'if isToolGroupAccordionIndex(index) {\n            return false', 'self-sizing is suppressed during the flight')
    c.present(layout, 'private var _accordionLock = os_unfair_lock_s()', 'span has its own lock')
    span_setter = layout[layout.index('func setToolGroupAccordion('):layout.index('func updateToolGroupAccordionReveal(')]
    c.absent(span_setter, 'heightCache[', 'setting the span never writes the height cache')
    c.absent(layout[layout.index('struct ToolGroupAccordionSpan'):layout.index('func setToolGroupAccordion(')], 'heightCache[', 'the span type carries no cache writes')

    # 3. the driver is a real per-frame flight
    c.present(flight, 'CADisplayLink(target: self, selector: #selector(tick(_:)))', 'display link driver')
    c.present(flight, 'l.add(to: .main, forMode: .common)', 'common run-loop mode (keeps animating while tracking)')
    c.present(flight, 'if cv.isTracking || cv.isDecelerating {\n            finish(.interrupted)', 'drag takeover')
    c.present(flight, 'guard cv.window != nil else { finish(.cancelled); return }', 'off-window teardown')
    c.present(flight, 'reduceMotion() || duration <= 0', 'reduce motion path')
    c.present(flight, 'cell.clipsToBounds = true', 'straddling cell is clipped, not scaled')
    c.present(flight, 'cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)', 'per-frame anchor offset')
    c.present(flight, 'layout.clearToolGroupAccordion()', 'the span never survives a flight')
    c.absent(flight, 'UIView.animate(', 'no UIView animation (would scale/fade, not clip)')
    c.absent(flight, 'snapshotView(afterScreenUpdates', 'no screenshot fade')
    c.absent(flight, 'transform =', 'no scale transform on the text')
    c.absent(flight, 'alpha =', 'no cross-fade')
    c.present(flight, 'func retarget(_ direction: Direction)', 'continuous tap reverses in place')

    # 4. coordinator wiring
    # [T-toolgroup-original-toggle] The 0.32s accordion was cancelled by user
    # decision on 2026-11-20: the entry no longer starts a flight, retargets,
    # reads reduce-motion for a reveal, or falls back from one. The accordion
    # MODULE stays compiled (its math is still exercised above), but the tap
    # must not reach it. Old -> new mapping (this section only; nothing deleted,
    # every positive became the equivalent no-flight negative):
    #   toggle starts a flight            -> toggle creates NO flight
    #   second tap retargets              -> toggle has no retarget branch
    #   reduce motion read from system    -> no reveal to suppress
    #   legacy fallback kept              -> the original switch IS the path
    #   structural settle at flight end   -> one structure apply per tap
    ORIGINAL = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/ToolGroupOriginalToggle.swift'
    original = ORIGINAL.read_text()
    toggle = fold[fold.index('func toggleToolGroup(firstBlockId: UUID)'):fold.index('func refreshToolGroupToggleRow')]
    c.absent(toggle, 'ToolGroupAccordionFlight', 'frozen negative: the tap never creates a flight')
    c.absent(toggle, 'retarget', 'frozen negative: no retarget branch on the tap')
    c.absent(toggle, 'UIAccessibility.isReduceMotionEnabled', 'frozen negative: no reveal to gate on reduce motion')
    c.absent(toggle, 'legacyInstantToolGroupToggle', 'frozen negative: one path, not an animated one plus a fallback')
    c.present(toggle, 'ToolGroupOriginalToggle.run(request, in: env)',
              'the tap runs the shared original-toggle transaction')
    c.present(original, 'env.applyStructure("toolGroupToggle")',
              'the original transaction applies the structure through the caller')
    c.present(original, 'let target = min(max(newMinY - request.anchorY, minOff), maxOff)',
              'the original anchored offset with its legal clamp is the shared maths')
    c.absent(original, 'CADisplayLink', 'frozen negative: the shared transaction has no frame driver')
    c.absent(original, 'setToolGroupAccordion', 'frozen negative: the shared transaction installs no span')
    c.absent(original, 'isReduceMotion', 'frozen negative: no reduce-motion branch to take')
    c.absent(original, 'Converge', 'frozen negative: nothing is deferred, so nothing converges later')
    c.present(txn, 'env.applyStructure("toolGroupAccordionEnd")', 'structural settle at the end of the flight')
    c.present(toggle, 'self.applySnapshot(messages: vm.messages, caller: caller)',
              'the transaction applies through the production applySnapshot, never a copy')
    c.absent(toggle, 'caller: "toolGroupToggle")\n\n            guard let idx = ds.snapshot().indexOfItem(item) else { return }',
             'frozen negative: the old instant cut in the animated path')
    c.present(toggle, 'reconfigure: { [weak self] item in self?.refreshToolGroupToggleRow(item) }',
              'the row reconfigure is the list\'s own, wired into the transaction')
    c.absent(fold, 'ToolGroupAccordion.duration) ?? 0.32', 'no second hard-coded duration')
    c.absent(snap, 'flight.cancel()',
             'frozen negative: a snapshot must not kill the animation unconditionally')
    c.present(flight, 'retire=structure', 'the driver retires only on a real structural conflict')
    c.present(delegate, 'viewController?.messageListLayout?.abortToolGroupAccordion()',
              'drag owns the viewport through the slice-safe channel')
    c.present(layout, 'func abortToolGroupAccordion()', 'the takeover channel exists on the layout')
    c.absent(delegate, 'toolGroupAccordionFlight', 'frozen negative: no coordinator-only symbol in the status-bar slice')

    # 5. the UIKit fixture drives THIS class, on a window, with intermediate frames
    c.present(fixture, 'ToolGroupAccordionFlight(collectionView: list, layout: listLayout)',
              'fixture uses the shipping driver')
    # [T-toolgroup-accordion] Run 44485598270: the fixture used to build a flight
    # at every call site and addressed it with `headerItem: .toolGroup(msg.id,
    # run.firstBlockId)` — scalars that were not even in scope there. One factory
    # now builds every flight and wires it to the fixture's OWN list identities,
    # and every case starts it.
    c.ok(fixture.count('ToolGroupAccordionFlight(collectionView:') == 1,
         'every flight is built in ONE place, the factory that wires liveItems')
    c.present(fixture, 'flight.liveItems = { [weak self] in self?.listItems }',
              'the factory feeds the flight the fixture\'s real list identities')
    c.ok(fixture.count('.start(plan, direction: .') >= 6,
         'fixture covers expand, collapse, reduce motion, short, long and identity with the shipping driver')
    c.present(fixture, 'self.checkAccordionMidFlight()', 'fixture samples an intermediate frame')
    c.present(fixture, 'accordion-mid', 'intermediate-frame PNG')
    c.present(fixture, 'accordion-end', 'end-frame PNG')
    c.present(fixture, 'accordion-reduce-motion', 'reduce-motion PNG')
    c.present(fixture, 'drift=', 'fixture measures header drift (anchor)')
    c.present(fixture, 'framesApplied >= 3', 'fixture refuses an instant cut')
    c.present(driver, "Support/ToolGroupAccordion.swift'", 'CI still compiles the shipping math module')
    c.present(driver, "Support/ToolGroupOriginalToggle.swift'", 'CI compiles the shipping original-toggle transaction')
    c.absent(entry, 'ToolGroupAccordionFlight', 'frozen negative: the entry stage never names the cancelled driver')
    c.absent(entry, 'ToolGroupAccordionToggle', 'frozen negative: the entry stage never names the accordion transaction')
    # The old module stays linked for the accordion fixture cases' own geometry
    # PNGs (documented), but the stage that stands in for the TAP must not name
    # it — that negative is asserted on the stage itself above.
    c.present(driver, "ToolGroupOriginalToggle.swift'", 'the harness links the original switch')
    c.present(entry, 'ToolGroupOriginalToggle.run(', 'the entry stage calls the original switch directly')
    c.present(driver, "Support/ToolGroupAccordionFlight.swift'", 'CI compiles the shipping driver')
    c.present(driver, "_png == 15", 'CI still pins the PNG count exactly (12 render + 3 accordion)')
    c.present(driver, "_checks >= 55", 'CI floor raised above the pre-accordion 33 checks')

    # 6. parent review (blockers 1-4): frozen negatives + the ownership rules
    c.present(original, 'env.applyStructure("toolGroupToggle")\n',
              'the structure apply is unconditional: a close must drop its rows')
    c.absent(original, 'if expanding {', 'frozen negative: gating the apply on expanding would desync a close')
    c.absent(toggle, 'finishStatusBarScrollToTop',
             'frozen negative: no viewport handoff is needed without a reveal to fight')
    c.absent((IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/StatusBarScrollToTop.swift').read_text(),
             'case toolGroupToggle', 'frozen negative: the status-bar reason enum is not extended')
    c.present(delegate[delegate.index('func beginStatusBarScrollToTop()'):][:900],
              'abortToolGroupAccordion()',
              'the status-bar flight cancels the accordion on its own start')
    c.present(txn, 'case .cancelled:\n                break',
              'a cancelled flight never converges and never restores the old anchor')
    c.absent(txn, 'case .interrupted:\n                env.restoreAnchor',
             'frozen negative: an interrupted flight never restores the old anchor')
    c.absent(toggle, 'flight.start(plan, direction: expanding ? .expand : .collapse) { [weak self] outcome in\n                guard let self, let vm = self.vm else { return }\n                if self.toolGroupAccordionFlight === flight { self.toolGroupAccordionFlight = nil }\n                self.applySnapshot(messages: vm.messages, caller: "toolGroupAccordionEnd")\n                self.restoreToolGroupToggleAnchor',
             'frozen negative: anchor restore on every outcome (would fight a drag)')
    c.present(txn, 'if let receipt = cell.heightReceipt {',
              'natural heights come from the cell measurement receipt')
    c.absent(txn, 'fitted > 0.5', 'frozen negative: height > 0.5 is never a "measured" verdict')
    c.present(txn, 'layout.setMeasuredHeight(receipt.height, at: idx)',
              'measured member heights are written through the production channel')
    c.present(measure, 'if let receipt = cell.measuredHeight(forWidth: width) {',
              'the off-screen probe accepts only a width-matched receipt')
    c.absent(measure, 'fitted > 0.5', 'frozen negative: the probe never guesses from a height')
    c.present(FLIGHT_SRC.read_text(), 'cell.accordionContentHeight = plan.naturalHeights[k]',
              'the member cell keeps its content at the natural height (clip, not squeeze)')
    c.present(flight, 'cell.accordionContentHeight = nil', 'the cell window is cleared after the flight')
    infra = (IOS / 'Agent/MessageList/MessageListInfrastructure.swift').read_text()
    # parent review round 3: identity-validated span + no out-of-cycle dequeue
    c.present(flight, 'func planStillMatches(_ items: [MessageListItem]) -> Bool', 'the driver compares real item identity, not counts')
    c.present(flight, 'items[plan.headerIndex] == plan.headerItem', 'header identity')
    c.present(flight, 'where items[plan.memberRange.lowerBound + k] != want', 'member identity')
    c.present(flight, "retire=identity", 'a failed identity check retires the flight')
    c.present(toggle, 'memberItems: run.memberIds.map { .assistantBlock(run.messageId, $0) }',
              'the plan carries the real member identities')
    snap_src = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Snapshot.swift').read_text()
    c.ok(snap_src.count('cancelAccordionIfSpanBroken(beforeApplying:') == 0,
         'no snapshot apply validates a reveal span any more (the tap installs none)')
    # [T-toolgroup-accordion] The Coordinator is compiled ONLY by the full app
    # build (the UIKit harness links Support/*), so a type error here survives
    # every fast stage and only shows up ~40 min later. Run 44513828272 paid for
    # exactly that: `ds.snap` (no such member), `snapshot.itemIdentifiers`
    # (method used as a property) and an unqualified `Section` that resolved to
    # SwiftUI.Section. These four checks are the cheap guard.
    c.absent(snap_src, 'ds.snap.', 'frozen negative: the diffable data source exposes snapshot(), not .snap')
    c.absent(snap_src, '.snapshot.itemIdentifiers',
             'frozen negative: snapshot is a method — itemIdentifiers needs snapshot()')
    # [T-toolgroup-original-toggle] Old: four pre-apply span validations in the
    # snapshot path. The tap installs no span, so there is nothing to validate
    # before a commit — the type guard belongs to the diffable data source the
    # coordinator still uses.
    c.absent(snap_src, 'cancelAccordionIfSpanBroken',
             'frozen negative: a snapshot apply no longer validates a reveal span')
    c.present((IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator.swift').read_text(),
              'var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!',
              'the coordinator still drives the list through its own diffable data source')
    c.absent(fold, 'DiffableDataSource<Section,',
             'frozen negative: an unqualified Section resolves to SwiftUI.Section in a free function')
    c.absent(toggle, 'planStillMatches',
             'frozen negative: the tap validates no span identity (it installs none)')
    c.absent(toggle, 'flight.spanIsValid', 'frozen negative: no per-frame-only validation left')
    c.absent(toggle, 'ds.collectionView(cv, cellForItemAt: ip)',
             'frozen negative: never dequeue a cell outside a UIKit request cycle')
    c.absent(toggle, 'writesListState: false',
             'frozen negative: the tap never configures cells in measurement mode')
    c.present(txn, 'writesListState: false',
              'the measurement host keeps its write-free configure (module contract, not on the tap)')
    c.present(measure, 'window.addSubview(container)', 'measurement happens in a window-hosted collection view')
    c.present(measure, 'container.register(SelfSizingCell.self, forCellWithReuseIdentifier: Host.reuseIdentifier)',
              'the throwaway measurement container registers SelfSizingCell for UIKit dequeue')
    c.present(measure, 'view.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)',
              'the throwaway data source dequeues through UIKit instead of returning a bare cell')
    c.absent(measure, 'SelfSizingCell()',
             'frozen negative: never return a bare SelfSizingCell() from UICollectionViewDataSource (NSInternalInconsistencyException)')
    c.absent(measure, 'return UICollectionViewCell()',
             'frozen negative: never return a bare UICollectionViewCell() from UICollectionViewDataSource')
    # Cross-file access: the probe lives in its own file, so it may only use the
    # cell's internal API. `private` hooks compile only inside the cell's file —
    # the exact failure a dequeue-time cleanup call produced on Darwin.
    bad_members = inaccessible_cell_members(measure, infra) + inaccessible_cell_members(txn, infra)
    c.ok(not bad_members,
         'the measuring host and the toggle transaction only touch SelfSizingCell members reachable from another file '
         '(inaccessible=%s)' % ','.join(sorted(set(bad_members))))
    c.ok(swift_declared_access(infra, 'clearCachedHeight') == 'open',
         'the probe uses clearCachedHeight, which is declared without file restrictions')
    c.ok(inaccessible_cell_members('sizingCell.resetAccordionWindowIfNeeded()', infra)
         == ['resetAccordionWindowIfNeeded'],
         'frozen negative: a call to the cell\'s private reuse hook IS reported as unreachable')
    c.ok(inaccessible_cell_members('sizingCell.clearCachedHeight()', infra) == [],
         'the same rule accepts a call to an internal member')
    c.present(measure, 'container.reloadData()', 'each row is measured in its own UIKit request cycle')
    c.absent(measure, 'estimated + 40', 'frozen negative: no container sized from the estimates')
    c.absent(measure, '20_000', 'frozen negative: no magic height cap')
    c.absent(measure, '20000', 'frozen negative: no magic height cap')
    c.present(measure, 'result.unmeasured.append(row.index)',
              'a row without a receipt is reported unmeasured, never estimated')
    c.present(measure, 'guard !rows.isEmpty else { return result }', 'empty runs never touch a container')
    # the measurement must not write the LIST: the probe takes no main layout
    c.absent(measure[measure.index('static func naturalHeights'):], 'layout.setContentKey',
             'frozen negative: the probe never writes the list content keys')
    c.absent(measure[measure.index('static func naturalHeights'):], 'setEstimatedHeight',
             'frozen negative: the probe never writes list estimates')
    # item 1: the list-state gate
    c.present(cfg, 'writesListState: Bool = true', 'configureCell has one measurement-mode flag')
    c.present(cfg, 'layout.registerCellContentKey(key, index: indexPath.item,',
              'index-keyed writes go through the single gate')
    c.absent(cfg, 'layout.setContentKey(', 'frozen negative: no unguarded index-keyed write')
    c.present(layout, 'func registerCellContentKey(_ key: String, index: Int, metricsTag: String?, writesListState: Bool) {',
              'the layout owns the gate')
    c.present(layout, 'guard writesListState else { return }', 'the gate refuses writes in measurement mode')
    # item 2: no estimate can be frozen as a measurement
    c.present(infra, 'private(set) var heightReceipt: HeightReceipt?',
              'SelfSizingCell publishes a measurement receipt')
    c.present(infra, 'func measuredHeight(forWidth width: CGFloat) -> HeightReceipt?',
              'the receipt is width-matched')
    c.present(infra, 'heightReceipt = HeightReceipt(height: fittingSize.height,',
              'only a real systemLayoutSizeFitting writes a measured receipt')
    c.present(infra, 'guard superview is UICollectionView, window != nil, contentConfiguration != nil else {\n            return layoutAttributes\n        }',
              'the off-collection guard still returns the proposal (and writes no receipt)')
    # item 3: the shared production transaction the harness runs
    c.present(txn, 'static func run(_ request: Request, in env: Environment) -> Outcome',
              'the reveal transaction is production code the harness can link')
    c.present(toggle, 'ToolGroupOriginalToggle.run(request, in: env)',
              'the coordinator calls the SAME original-toggle transaction the harness drives')
    c.present(txn, 'static func isContiguousSpan(_ idxs: [Int], headerIndex: Int) -> Bool',
              'the contiguous window rule is shared')
    c.present(txn, 'if env.isReduceMotion() {', 'reduce motion is declined by the transaction')
    c.present(txn, 'if env.isStreaming() {', 'streaming is declined by the transaction')
    c.present(entry, 'ToolGroupOriginalToggle.run(request(expanding: true), in: environment())',
              'the entry stage drives the production original-toggle transaction')
    c.absent(entry, 'ToolGroupAccordionFlight(collectionView:', 'frozen negative: the entry stage never builds its own flight')
    c.present(driver, 'ToolGroupToggleEntryStage.swift', 'the harness compiles the entry stage')
    c.present(driver, 'ToolGroupOriginalToggle.swift', 'the harness compiles the production original-toggle transaction')
    c.present(driver, 'TOOLGROUP_ENTRY_PASS', 'a skipped entry stage cannot pass as covered')
    c.present(fixture, 'startToggleEntryStage()', 'the fixture runs the entry stage before finishing')
    c.present(infra, 'override func prepareForReuse()', 'a reused cell resets its clip window')
    # [T-toolgroup-accordion] Exactly ONE override of each reused hook: a second
    # `override func prepareForReuse()` in the class is a hard compile error
    # ("prepareForReuse() has already been overridden") and the five harnesses
    # that compile this class verbatim all fail on it. That is how the run
    # 44473421126 MOD step went red.
    cell_src = infra[infra.index('class SelfSizingCell: UICollectionViewCell {'):infra.index('// MARK: - NoAnimationCollectionView')]
    for hook in ('prepareForReuse', 'layoutSubviews', 'preferredLayoutAttributesFitting'):
        c.ok(cell_src.count('override func ' + hook + '(') == 1,
             hook + ' :: exactly one override in SelfSizingCell')
    c.present(cell_src, 'accordionContentHeight = nil\n        resetAccordionWindowIfNeeded()\n        rendersNonEmptyText = false',
              'the single reuse override does the clip-window reset AND the original reset')
    c.present(infra, 'accordionContentHeight = nil\n        resetAccordionWindowIfNeeded()\n        configGeneration',
              'a new configuration resets the clip window')
    c.present(infra, 'var accordionContentHeight: CGFloat?', 'SelfSizingCell owns the clip window')
    c.present(infra, 'let target = max(bounds.height, natural)', 'the hosted content is never laid out shorter than natural')
    # dependency-free layout keeps the five other harness manifests valid
    c.absent(layout, 'ToolGroupAccordion.', 'frozen negative: MessageListLayout must not depend on ToolGroupAccordion.swift (5 other harnesses compile it verbatim)')
    c.present(''.join(layout.split()), 'letreveal=min(1,max(0,span.reveal))', 'layout inlines the same frontier formula')
    c.present(driver, "_png == 15", 'driver pins 15 PNGs')
    # 7. [T-toolgroup-accordion] B1: the animated path must RE-RENDER the tapped
    #    row. `isExpanded` is baked into the cell at configure time and no
    #    diffable apply reconfigures an item whose identity did not change, so
    #    the old full-invalidation contract cannot be satisfied by the legacy
    #    path alone — the animated path has to do it through the transaction.
    c.present(toggle, 'refreshToolGroupToggleRow(item)', 'a retarget re-renders the tapped row too')
    refresh = fold[fold.index('func refreshToolGroupToggleRow'):fold.index('func deferToolGroupAccordionConverge')]
    c.present(refresh, 'snap.reconfigureItems([item])', 'the refresh really reconfigures the row (isExpanded is a configure-time value)')
    c.present(refresh, 'clearCachedHeight()', 'the refresh drops the cell height first')
    c.present(refresh, 'layout.invalidateHeight(at: idx)', 'the refresh invalidates the layout height')
    c.present(refresh, 'layout.invalidateLayout()', 'the refresh invalidates the layout')
    c.ok(ordered_ok(refresh, ['clearCachedHeight()', 'layout.invalidateHeight(at: idx)',
                              'snap.reconfigureItems([item])',
                              'ds.apply(snap, animatingDifferences: false)',
                              'layout.invalidateLayout()']),
         'the refresh is the old full invalidation, in the old order')
    c.present(toggle, 'reconfigure: { [weak self] item in', 'the coordinator wires the row reconfigure')
    c.present(txn, 'env.refreshHeader(request.item)', 'the transaction asks for the refresh')
    c.ok(txn.index('flight.start(plan') < txn.index('env.refreshHeader(request.item)'),
         'the refresh runs AFTER the span is installed (a reconfigure cannot draw the members first)')
    # 8. N1 (old accordion rule: "still producing" must gate the reveal). The
    #    original switch freezes no heights, so streaming is not an input at
    #    all: the tap must not read the production-live predicate or the
    #    suspended-updates flag. Old -> new: "falls back while streaming" ->
    #    "streams through the same instant switch".
    c.absent(toggle, 'isToolGroupAccordionProductionLive',
             'frozen negative: the tap no longer asks whether the run is still producing')
    c.absent(toggle, 'streamingUIUpdatesSuspended',
             'frozen negative: the tap does not read the suspended-updates flag either')
    c.absent(original, 'isStreaming', 'frozen negative: nothing in the transaction branches on streaming')
    # 9. N2: only a flight that reached its end may converge the structure
    c.present(txn, 'case .completed, .instant:\n                env.applyStructure("toolGroupAccordionEnd")',
              'the structure converges only for a completed / instant flight')
    c.absent(txn, 'env.applyStructure("toolGroupAccordionEnd")\n            // Only a flight',
             'frozen negative: the structure may not converge before the outcome is known')
    # 10. N4: a cancelled flight drops its takeover closure (layout → flight → layout)
    cancel_body = flight[flight.index('func cancel() {'):flight.index('private func restoreClip()')]
    c.present(cancel_body, 'layout.toolGroupAccordionAbort = nil',
              'cancel() clears the takeover closure it armed')

    # 11. B2: an interrupted CLOSE is settled at the first free viewport, never
    #     under the finger, and never from the stale `request.expanding`.
    c.present(flight, 'var finalDirection: Direction { direction }',
              'the flight exposes the direction it will END in (a retarget changes it)')
    c.present(txn, 'if flight.finalDirection == .collapse {',
              'the interrupted side is decided by the final direction, not by the request')
    c.present(txn, 'env.deferConverge("toolGroupAccordionEnd-deferred")',
              'an interrupted close hands its converge to the list')
    c.absent(txn, 'case .interrupted, .cancelled:\n                break',
             'frozen negative: an interrupted close is not simply dropped')
    # [T-toolgroup-original-toggle] The deferred converge existed only for an
    # interrupted close (the rows were held at natural height under the
    # finger). The original switch deletes the rows in the same apply, so a tap
    # has nothing to settle first and no reveal can own the viewport.
    # Old -> new: "settle the interrupted close first" -> "nothing is deferred".
    c.absent(toggle, 'flushToolGroupAccordionConverge',
             'frozen negative: the tap does not settle a deferred close (there is none)')
    c.present(delegate, 'flushToolGroupAccordionConverge()',
              'the drag / status-bar end still asks (the settle is a no-op without a deferred close)')
    c.present(fold, 'func flushToolGroupAccordionConverge(force: Bool = false)',
              'the converge helper still exists for the status-bar slice contract')
    c.absent(fold, 'toolGroupAccordionFlight?.isRunning != true,',
             'frozen negative: the flush no longer waits on a reveal')
    c.present(fold, '!statusBarScrollToTop.isActive,', 'no status-bar flight may own the viewport')
    c.present(fold, '!cv.isTracking, !cv.isDecelerating else { return }',
              'no drag / deceleration may own the viewport')
    c.present(fold, 'layout?.suppressContentOffsetAdjustment = true',
              'the deferred converge keeps the offset (rows are already at natural height)')
    # 12. N1 narrowed (old accordion rule). Old -> new: the per-message
    #     production-live predicate belonged to the reveal's fallback; the
    #     original switch has no fallback, so the predicate is gone from the
    #     coordinator instead of being kept as a dead hook.
    c.absent(fold, 'func isToolGroupAccordionProductionLive',
             'frozen negative: the per-message production-live hook is gone')
    c.absent(fold, 'toolGroupAccordionFlight',
             'frozen negative: no flight state survives in the coordinator')
    c.absent(fold, 'vm.isProcessing || vm.toolFoldRunningMessageId != nil',
             'frozen negative: a turn running elsewhere must not disable every historical group')

    # 13. K1: every `ToolGroupAccordionToggle.Environment(...)` call must pass its
    #     arguments in the DECLARATION order — Swift's memberwise init is
    #     positional, and a call that lists the same labels in another order is a
    #     hard compile error on Darwin (run 44482321219: refreshHeader …
    #     deferConverge … restoreAnchor vs refreshHeader … restoreAnchor …
    #     deferConverge). Parsed from the sources, not "text appears somewhere".
    # [T-toolgroup-original-toggle] Same K1 rule, applied to the transaction the
    # tap actually runs now.
    env_members = swift_struct_members(original, 'Environment')
    prod_calls = swift_call_labels(fold, 'ToolGroupOriginalToggle.Environment')
    entry_calls = swift_call_labels(entry, 'ToolGroupOriginalToggle.Environment')
    c.ok(len(env_members) >= 7, 'Environment has all its members (%d)' % len(env_members))
    c.ok(len(prod_calls) == 1, 'the coordinator builds exactly one Environment (%d)' % len(prod_calls))
    c.ok(len(entry_calls) == 1, 'the entry stage builds exactly one Environment (%d)' % len(entry_calls))
    c.ok(prod_calls and prod_calls[0] == env_members,
         'the coordinator passes every Environment argument in declaration order (call=%s decl=%s)' % (prod_calls, env_members))
    c.ok(entry_calls and entry_calls[0] == env_members,
         'the entry stage passes every Environment argument in declaration order (call=%s)' % (entry_calls,))
    # The parser itself must catch a swapped pair, or the two checks above would
    # pass on any text at all.
    swapped = list(env_members)
    swapped[5], swapped[6] = swapped[6], swapped[5]
    synthetic = 'ToolGroupOriginalToggle.Environment(' + ', '.join('%s: x' % m for m in swapped) + ')'
    c.ok(swift_call_labels(synthetic, 'ToolGroupOriginalToggle.Environment')[0] != env_members,
         'frozen negative: a swapped pair of labels is detected')
    c.ok(swift_call_labels('ToolGroupOriginalToggle.Environment(' + ', '.join('%s: x' % m for m in env_members) + ')',
                           'ToolGroupOriginalToggle.Environment')[0] == env_members,
         'the parser reads a well-ordered call back exactly')

    # 14. [T-toolgroup-accordion] The Darwin-only type errors of the fixture.
    #     Run 44485598270 was the FIRST run that actually compiled
    #     `scripts/toolfold-uikit-tests/ToolFoldUIKitFixture.swift` (UIKit), and it
    #     died with 24 type errors: `msg.id`/`run` used in functions that never
    #     declared them, the removed `flight.spanIsValid`, `(1...3).map { expr }`
    #     without `_ in`, and `guard let self` under a STRONG capture. `-parse`
    #     cannot see any of those. `toolfold_fixture_lint.py` re-checks exactly
    #     those classes here, on Linux, and is validated against the original
    #     errors (frozen) and against re-introductions in the REAL files.
    lint = _load_fixture_lint()
    flight_src = FLIGHT_SRC.read_text()
    owners = lint.nested_types(LAYOUT_SRC.read_text())
    linked = [(p.name, p.read_text()) for p in lint.TARGETS]
    for label, text in linked:
        findings = lint.lint_text(text, flight_src, owners, label)
        c.ok(not findings, 'fixture lint: %s has no Darwin-only type error (%d: %s)'
             % (label, len(findings), [str(f) for f in findings[:3]]))
    # run 44490117255: the PRODUCTION flight had never been compiled either
    # (the app job is skipped in incremental scope), so it is linted here too.
    c.ok(any(name == 'ToolGroupAccordionFlight.swift' for name, _ in linked),
         'the lint covers the production flight the UIKit job links')
    c.ok(len(lint.TARGETS) >= 5, 'the lint covers every linked file (%d)' % len(lint.TARGETS))
    for rule, where, src, what in lint.FROZEN:
        got = {f.rule for f in lint.lint_text(src, flight_src, owners, 'SomeOtherFile.swift')}
        c.ok(rule in got, 'fixture lint catches the frozen negative %s (%s)' % (where, what))
    for rule, mutate in lint.MUTATIONS:
        hits = [t for _, t in linked if mutate(t) != t]
        c.ok(bool(hits), 'fixture lint mutation %s still applies to a real file' % rule)
        c.ok(all(rule in {f.rule for f in lint.lint_text(mutate(t), flight_src, owners, 'mutated.swift')}
                 for t in hits),
             'fixture lint catches %s re-introduced into the real file' % rule)

    # 15. [T-toolgroup-accordion] P1 (run 44506193558): the off-screen probe has
    #     to measure in the SAME coordinate / safe-area context the list's rows
    #     have. The container used to be parked at the window origin — inside the
    #     status-bar safe area — while the list's rows live below its
    #     `adjustedContentInset.top`; a UIHostingConfiguration cell there adds the
    #     inset to its fitting height, so every member row came back 62pt taller
    #     than the same row on screen (382 vs 320) and the flight froze a wrong
    #     frontier and anchor. The cure is geometric (the list's own top inset and
    #     the window's safe-area edge), never a constant correction.
    probe = measure[measure.index('static func naturalHeights'):]
    c.present(probe, 'container.contentInsetAdjustmentBehavior = .never',
              'the probe container opts out of UIKit\'s inferred inset adjustment')
    c.present(probe, 'let listTopInset = collectionView.adjustedContentInset.top',
              'the probe reads the LIST\'s own top inset')
    c.present(probe, 'let windowTopInset = window.safeAreaInsets.top',
              'the probe reads the WINDOW\'s top safe-area inset')
    c.present(probe, 'let topInset = max(listTopInset, max(0, windowTopInset - listOrigin.y))',
              'the probe row sits below the list top inset AND below the safe-area edge')
    c.present(probe, 'let listOrigin = collectionView.convert(CGPoint.zero, to: window)',
              'the container sits at the list origin inside the SAME window')
    c.present(probe, 'container.contentOffset = CGPoint(x: 0, y: -topInset)',
              'the single probe row is pinned below the inset, not at y = 0')
    c.present(probe, 'container.frame = CGRect(x: listOrigin.x, y: listOrigin.y, width: width, height: height)',
              'the growth loop keeps the measurement origin (a resize must not move the row into the safe area)')
    c.absent(probe, 'CGRect(x: 0, y: 0, width: width, height: 64)',
             'frozen negative: a container at the window origin measures inside the status-bar safe area')
    # Executable rule, not a string grep: the shipped probe must contain no 62pt
    # constant anywhere in CODE (comments are stripped), because the inset has to
    # be measured — it changes with rotation, split screen and the keyboard.
    probe_code = '\n'.join(line.split('//')[0] for line in probe.splitlines())
    c.ok('62' not in probe_code,
         'frozen negative: the safe area is never compensated with a constant in the probe')

    # 16. [T-toolgroup-accordion] P2 (run 44506193558): the takeover channel must
    #     be disarmed on EVERY terminal path — takeover, drag interrupt, cancel,
    #     normal end — and only by the flight that armed it. The old code cleared
    #     it solely behind `currentFlight() === flight` in the completion, and the
    #     takeover path clears the stored flight BEFORE it finishes, so the
    #     closure stayed armed with a dead flight (and the whole list) captured.
    c.present(flight, 'private(set) var ownsAbortChannel = false',
              'the takeover channel ownership travels with the flight')
    c.present(flight, 'func armAbortChannel() { ownsAbortChannel = true }',
              'a transaction arms the channel on its own flight')
    c.present(flight, 'func disarmAbortChannel() {\n        guard ownsAbortChannel else { return }',
              'only the flight that armed the channel may clear it')

    def channel_disarmed_before_callback(src):
        i = src.find('func finish(_ outcome: Outcome) {')
        if i < 0:
            return False
        body = src[i:]
        j = body.find('func cancel() {')
        if j > 0:
            body = body[:j]
        if 'cb?(outcome)' not in body:
            return False
        return 'disarmAbortChannel()' in body and body.index('disarmAbortChannel()') < body.index('cb?(outcome)')

    c.ok(channel_disarmed_before_callback(flight),
         'finish() disarms the takeover channel BEFORE the completion runs')
    c.ok(not channel_disarmed_before_callback('''    func finish(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        lastOutcome = outcome
        link?.invalidate()
        link = nil
        restoreClip()
        layout.clearToolGroupAccordion()
        plan = nil
        let cb = onFinish
        onFinish = nil
        cb?(outcome)
    }

    func cancel() {
    }
'''), 'frozen negative: the old finish() never disarmed the channel (only the completion identity did)')
    c.present(txn, 'env.currentFlight()?.disarmAbortChannel()',
              'a new transaction drops the previous flight\'s channel before it installs its own')
    c.present(txn, 'flight.armAbortChannel()',
              'the transaction arms the channel on the flight it started')
    c.present(txn, 'guard env.currentFlight() === flight else { return }',
              'the takeover closure still finishes only the flight that armed it')

    # 14. [T-toolgroup-original-toggle] THE CANCELLED ACCORDION, PROVEN DEAD ON
    #     THE PRODUCTION PATH. The 0.32s reveal was removed by user decision
    #     (2026-11-20); the module above still exists and compiles, so this
    #     section is what keeps a future edit from silently re-entering it.
    #     Old -> new mapping (explicit, no assertion deleted):
    #       tap starts flight                  -> tap creates NO flight object
    #       retarget on second tap             -> no retarget, sequential taps
    #       span installed / clip window        -> no span install on the path
    #       per-row measurement probe           -> no probe on the path
    #       deferred converge after interruption -> one apply per tap
    #       must-animate (reveal > 0 mid-flight) -> must-NOT-animate (instant)
    tap_region = fold[fold.index('func toggleToolGroup(firstBlockId: UUID)'):fold.index('func refreshToolGroupToggleRow')]
    s14 = 0
    def c14(ok, label):
        global _sec14
        c.ok(ok, label)
        _sec14 += 1
    c14('ToolGroupOriginalToggle.run(request, in: env)' in tap_region, '14: the tap runs the shared original toggle')
    for token in ['ToolGroupAccordion', 'Flight', 'retarget', 'CADisplayLink', 'setToolGroupAccordion',
                  'naturalHeight', 'measurement', 'deferConverge', 'abort', 'span']:
        c14(token not in tap_region, '14: frozen negative — the tap names no %s' % token)
    for token in ['env.applyStructure("toolGroupToggle")', 'let idx = env.indexOf(request.item)',
                  'clearCachedHeight()', 'layout.invalidateHeight(at: idx)', 'env.reconfigure(request.item)',
                  'layout.invalidateLayout()', 'cv.layoutIfNeeded()',
                  'let target = min(max(newMinY - request.anchorY, minOff), maxOff)',
                  'cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)']:
        c14(token in original, '14: the transaction keeps the original step %r' % token[:48])
    for token in ['CADisplayLink', 'Timer', 'UIView.animate', 'setToolGroupAccordion', 'ToolGroupAccordionFlight',
                  'ToolGroupAccordionMeasurement', 'ToolGroupAccordionToggle', 'deferConverge', 'retarget']:
        c14(token not in original, '14: frozen negative — the transaction has no %s' % token)
    c14(original.count('func run(') == 1, '14: exactly one transaction entry point')
    c14(original.count('setContentOffset') == 1, '14: exactly one offset write, the anchored one')
    c14(original.count('applyStructure(') == 1, '14: exactly one structure apply')
    c14('animated: false' in original, '14: the offset write is not animated (instant, like b54da95)')
    # The harness runs THIS code and asserts the negative side after every case.
    for case in ['expandCase', 'collapseCase', 'repeatTapCase', 'shortCase', 'nearBottomCase',
                 'streamingCase', 'reduceMotionCase', 'missingRowCase']:
        c14(case in entry, '14: the entry stage covers %s' % case)
    c14(entry.count('checkNoFlightResidue(') >= 8, '14: every case asserts the no-residue invariants')
    c14("layout.toolGroupAccordionSpan == nil" in entry, '14: the stage asserts no reveal window')
    c14("layout.toolGroupAccordionAbort == nil" in entry, '14: the stage asserts no abort channel')
    c14('TOOLGROUP_ORIGINAL_TOGGLE_\\(verdict)' in entry,
        '14: the stage marker is built from the VERDICT (never a fixed _PASS)')
    c14('"TOOLGROUP_ORIGINAL_TOGGLE_PASS"' not in entry,
        '14: frozen negative — no unconditional _PASS literal in the stage')
    c14("'TOOLGROUP_ORIGINAL_TOGGLE_PASS checks=" in driver, '14: the driver requires the stage marker')
    c14("'TOOLGROUP_ORIGINAL_TOGGLE_STAGE_MISSING'" in driver, '14: a skipped stage is named, not passed')
    print('TOOLGROUP_ORIGINAL_TOGGLE_PASS static=%d' % _sec14)

    return c


def delivery_checks(delivery_root):
    """[T-toolgroup-accordion] The LOCAL DELIVERY ROOT contract.

    `verify_candidate.py`, `collect_sign.py` and `build.py` sign and gate the run
    from OUTSIDE the git repository (they are the delivery scaffolding, not
    product source), so a clean CI checkout cannot see them. Reading them here
    unconditionally is what killed run 44483236883 at this line: the script
    walked up to the parent of the checkout and crashed with FileNotFoundError.

    So this half is OPT-IN: `--delivery-root <dir>`. When it is requested the
    files MUST exist (a missing root is a hard failure, never a silent skip);
    when it is not requested the CI run stays repo-only and says so explicitly.
    """
    c = Contract()
    root = Path(delivery_root)
    required = ['verify_candidate.py', 'collect_sign.py', 'build.py']
    missing = [name for name in required if not (root / name).is_file()]
    c.ok(not missing, 'the delivery root holds every gate script (missing=%s root=%s)' % (missing, root))
    if missing:
        return c
    vt = (root / 'verify_candidate.py').read_text()
    c.present(vt, 'TOOLGROUP_ACCORDION_PASS', 'verify_candidate.py requires the accordion markers (current run only)')
    c.present(vt, 'png=15', 'verify_candidate.py pins the new PNG count')
    c.present(vt, "_tfq and max(_tfq) >= 55", 'verify_candidate.py keeps the 55-check floor')
    c.absent(vt, 'png=12', 'verify_candidate.py has no stale png=12 gate')
    ct = (root / 'collect_sign.py').read_text()
    # collect_sign.py never carried a toolfold gate (grep: 0 hits) - it signs what
    # build.py verify approved, so the correct contract is "no stale numbers here".
    c.absent(ct, 'png=12', 'collect_sign.py has no stale png=12 gate')
    c.absent(ct, 'TOOLFOLD_UIKIT_PASS checks=33', 'collect_sign.py has no stale 33-check gate')
    c.present((root / 'build.py').read_text(), "'TOOLGROUP_ACCORDION_PASS' in validation", 'build.py gates the new markers')

    return c


def layout_self_test():
    """A clean-checkout layout must pass with NO delivery root, and an explicitly
    requested but EMPTY root must fail. Uses `git archive` so the copy is exactly
    what CI checks out (no parent directory to walk into)."""
    import subprocess, tempfile, shutil
    tmp = Path(tempfile.mkdtemp(prefix='toolgroup-layout-'))
    try:
        # An ISOLATED copy of the tree as CI sees it: no .git, no parent
        # directory to walk into, no delivery scaffolding next to it.
        archive = tmp / 'checkout.tar'
        subprocess.run(['tar', '-cf', str(archive), '--exclude=.git', '--exclude=build', '-C', str(ROOT), '.'],
                       check=True)
        clean = tmp / 'checkout'
        clean.mkdir()
        subprocess.run(['tar', '-xf', str(archive), '-C', str(clean)], check=True)
        script = clean / 'scripts' / 'toolgroup_accordion_regression.py'
        ok = subprocess.run([sys.executable, str(script)], cwd=str(clean),
                            capture_output=True, text=True)
        ci_ok = (ok.returncode == 0 and 'TOOLGROUP_ACCORDION_PASS' in ok.stdout
                 and 'TOOLGROUP_DELIVERY_SKIPPED' in ok.stdout)
        empty = tmp / 'empty-root'
        empty.mkdir()
        bad = subprocess.run([sys.executable, str(script), '--delivery-root', str(empty)],
                             cwd=str(clean), capture_output=True, text=True)
        local_ok = bad.returncode != 0 and 'TOOLGROUP_DELIVERY_FAIL' in bad.stdout
        print('  %s clean checkout (no parent root) passes repo-only and says so' % ('OK ' if ci_ok else 'FAIL'))
        print('  %s an explicitly requested EMPTY delivery root fails' % ('OK ' if local_ok else 'FAIL'))
        print('LAYOUT_SELF_TEST_%s' % ('PASS' if (ci_ok and local_ok) else 'FAIL'))
        return 0 if (ci_ok and local_ok) else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    args = sys.argv[1:]
    if '--layout-self-test' in args:
        raise SystemExit(layout_self_test())
    delivery_root = None
    if '--delivery-root' in args:
        delivery_root = args[args.index('--delivery-root') + 1]
    elif any(a.startswith('--delivery-root=') for a in args):
        delivery_root = [a for a in args if a.startswith('--delivery-root=')][0].split('=', 1)[1]
    m = math_checks()
    contract = static_checks()
    if contract.failures:
        for f in contract.failures:
            print('FAIL', f)
        print('TOOLGROUP_ACCORDION_FAIL math=%s static=%s failures=%s' % (m, contract.cases, len(contract.failures)))
        raise SystemExit(1)
    print('TOOLGROUP_ACCORDION_PASS math=%s static=%s' % (m, contract.cases))
    if delivery_root is None:
        # Repo-only run (CI): the delivery scaffolding is not in the checkout.
        print('TOOLGROUP_DELIVERY_SKIPPED no --delivery-root (repo-only run)')
        raise SystemExit(0)
    dc = delivery_checks(delivery_root)
    if dc.failures:
        for f in dc.failures:
            print('FAIL', f)
        print('TOOLGROUP_DELIVERY_FAIL cases=%s failures=%s' % (dc.cases, len(dc.failures)))
        raise SystemExit(1)
    print('TOOLGROUP_DELIVERY_PASS cases=%s root=%s' % (dc.cases, delivery_root))
