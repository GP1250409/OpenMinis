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

    # 1. the shared numbers are the sidebar's (one animation, two places)
    c.present(math, 'static let duration: Double = 0.32', 'accordion duration constant')
    c.present(sidebar_list, 'private let duration: CFTimeInterval = 0.32', 'sidebar duration unchanged')
    c.present(sidebar, 'return x * x * (3 - 2 * x)', 'sidebar smoothstep body')
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
    toggle = fold[fold.index('func toggleToolGroup(firstBlockId: UUID)'):fold.index('private func legacyInstantToolGroupToggle')]
    c.present(toggle, 'toolGroupAccordionFlight = flight', 'toggle starts a flight')
    c.present(toggle, 'flight.retarget(expanding ? .expand : .collapse)', 'second tap retargets')
    c.present(toggle, 'UIAccessibility.isReduceMotionEnabled', 'reduce motion is read from the system switch')
    c.present(toggle, 'legacyInstantToolGroupToggle(', 'reduce-motion / non-contiguous fallback kept')
    c.present(toggle, 'applySnapshot(messages: vm.messages, caller: "toolGroupAccordionEnd")', 'structural settle at the end of the flight')
    c.absent(toggle, 'caller: "toolGroupToggle")\n\n            guard let idx = ds.snapshot().indexOfItem(item) else { return }',
             'frozen negative: the old instant cut in the animated path')
    c.absent(toggle, 'var snap = ds.snapshot()\n            snap.reconfigureItems([item])',
             'frozen negative: reconfigure-instead-of-reveal in the animated path')
    c.absent(fold, 'ToolGroupAccordion.duration) ?? 0.32', 'no second hard-coded duration')
    c.present(snap, 'if let flight = toolGroupAccordionFlight {\n                toolGroupAccordionFlight = nil\n                flight.cancel()',
              'a snapshot swap cancels the flight (no stale span)')
    c.present(delegate, 'flight.finish(.interrupted)', 'drag owns the viewport')

    # 5. the UIKit fixture drives THIS class, on a window, with intermediate frames
    c.present(fixture, 'ToolGroupAccordionFlight(collectionView: list, layout: listLayout)', 'fixture uses the shipping driver')
    c.ok(fixture.count('ToolGroupAccordionFlight(collectionView: list, layout: listLayout)') >= 3,
         'fixture covers expand, collapse and reduce motion with the shipping driver')
    c.present(fixture, 'self.checkAccordionMidFlight()', 'fixture samples an intermediate frame')
    c.present(fixture, 'accordion-mid', 'intermediate-frame PNG')
    c.present(fixture, 'accordion-end', 'end-frame PNG')
    c.present(fixture, 'accordion-reduce-motion', 'reduce-motion PNG')
    c.present(fixture, 'drift=', 'fixture measures header drift (anchor)')
    c.present(fixture, 'framesApplied >= 3', 'fixture refuses an instant cut')
    c.present(driver, "Support/ToolGroupAccordion.swift'", 'CI compiles the shipping math')
    c.present(driver, "Support/ToolGroupAccordionFlight.swift'", 'CI compiles the shipping driver')
    c.present(driver, "_png == 15", 'CI still pins the PNG count exactly (12 render + 3 accordion)')
    c.present(driver, "_checks >= 55", 'CI floor raised above the pre-accordion 33 checks')

    # 6. parent review (blockers 1-4): frozen negatives + the ownership rules
    legacy = fold[fold.index('private func legacyInstantToolGroupToggle'):fold.index('private func restoreToolGroupToggleAnchor')]
    c.present(legacy, 'applySnapshot(messages: vm.messages, caller: "toolGroupToggle")',
              'legacy fallback applies the snapshot unconditionally again (a close must drop its rows)')
    c.absent(legacy, 'if expanding { applySnapshot', 'frozen negative: gating the legacy apply on expanding desyncs a reduce-motion close')
    c.present(toggle, 'finishStatusBarScrollToTop(reason: .toolGroupToggle, offset: cv.contentOffset.y)',
              'a tap takes the viewport from an active status-bar flight')
    c.present(delegate, 'func beginStatusBarScrollToTop() {\n            // [T-toolgroup-accordion]',
              'the status-bar flight cancels the accordion on its own start')
    c.present(toggle, 'case .interrupted, .cancelled:\n                    break',
              'an interrupted/superseded flight never restores the old anchor')
    c.absent(toggle, 'flight.start(plan, direction: expanding ? .expand : .collapse) { [weak self] outcome in\n                guard let self, let vm = self.vm else { return }\n                if self.toolGroupAccordionFlight === flight { self.toolGroupAccordionFlight = nil }\n                self.applySnapshot(messages: vm.messages, caller: "toolGroupAccordionEnd")\n                self.restoreToolGroupToggleAnchor',
             'frozen negative: anchor restore on every outcome (would fight a drag)')
    c.present(toggle, 'let fitted = cell.preferredLayoutAttributesFitting(attrs).size.height',
              'natural heights come from the production measurement channel')
    c.present(toggle, 'layout.setMeasuredHeight(fitted, at: idx)',
              'measured member heights are written through the production channel')
    c.present(FLIGHT_SRC.read_text(), 'cell.accordionContentHeight = plan.naturalHeights[k]',
              'the member cell keeps its content at the natural height (clip, not squeeze)')
    c.present(flight, 'cell.accordionContentHeight = nil', 'the cell window is cleared after the flight')
    infra = (IOS / 'Agent/MessageList/MessageListInfrastructure.swift').read_text()
    c.present(infra, 'var accordionContentHeight: CGFloat?', 'SelfSizingCell owns the clip window')
    c.present(infra, 'let target = max(bounds.height, natural)', 'the hosted content is never laid out shorter than natural')
    # dependency-free layout keeps the five other harness manifests valid
    c.absent(layout, 'ToolGroupAccordion.', 'frozen negative: MessageListLayout must not depend on ToolGroupAccordion.swift (5 other harnesses compile it verbatim)')
    c.present(''.join(layout.split()), 'letreveal=min(1,max(0,span.reveal))', 'layout inlines the same frontier formula')
    c.present(driver, "_png == 15", 'driver pins 15 PNGs')
    # 7. every gate script must know the new markers, not just build.py
    verify = (NEWROOT / 'verify_candidate.py')
    collect = (NEWROOT / 'collect_sign.py')
    vt = (NEWROOT / 'verify_candidate.py').read_text()
    c.present(vt, 'TOOLGROUP_ACCORDION_PASS', 'verify_candidate.py requires the accordion markers (current run only)')
    c.present(vt, 'png=15', 'verify_candidate.py pins the new PNG count')
    c.present(vt, "_tfq and max(_tfq) >= 55", 'verify_candidate.py keeps the 55-check floor')
    c.absent(vt, 'png=12', 'verify_candidate.py has no stale png=12 gate')
    ct = (NEWROOT / 'collect_sign.py').read_text()
    # collect_sign.py never carried a toolfold gate (grep: 0 hits) - it signs what
    # build.py verify approved, so the correct contract is "no stale numbers here".
    c.absent(ct, 'png=12', 'collect_sign.py has no stale png=12 gate')
    c.absent(ct, 'TOOLFOLD_UIKIT_PASS checks=33', 'collect_sign.py has no stale 33-check gate')
    c.present((NEWROOT / 'build.py').read_text(), "'TOOLGROUP_ACCORDION_PASS' in validation", 'build.py gates the new markers')

    return c


if __name__ == '__main__':
    m = math_checks()
    contract = static_checks()
    if contract.failures:
        for f in contract.failures:
            print('FAIL', f)
        print(f'TOOLGROUP_ACCORDION_FAIL math={m} static={contract.cases} failures={len(contract.failures)}')
        raise SystemExit(1)
    print(f'TOOLGROUP_ACCORDION_PASS math={m} static={contract.cases}')
