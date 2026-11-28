#!/usr/bin/env python3
"""[T-chat-mail-fold] Mail-style chat fold: geometry COMPILED+RUN on Linux
plus the static contracts of the transaction / flight / layout / coordinator.

The geometry half compiles the SHIPPING `ChatMailFold` block (between its
BEGIN/END markers) and the shipping assertion harness from
`scripts/chat-mail-fold-tests/ChatMailFoldTests.swift`, so the numbers verified
here are the ones the app runs. The static half pins the wiring that makes the
animation safe: end-state settle order, takeover, identity retire, reduce
motion, streaming fallback, top-clip cell window, and the absence of the
patterns that made the cancelled accordion unsafe (scale / fade / snapshot).

usage: python3 scripts/chat_mail_fold_regression.py [--swiftc swiftc]
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'src' / 'ios'
SUPPORT = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support'
OUT = ROOT / 'build' / 'chat-mail-fold'
OUT.mkdir(parents=True, exist_ok=True)

failures = []


def ok(cond, label):
    if not cond:
        failures.append(label)
        print('FAIL', label)


def read(p):
    return p.read_text()


# ---------------------------------------------------------------- geometry
core = read(SUPPORT / 'ChatMailFold.swift')
b = core.index('// === BEGIN ChatMailFold ===')
e = core.index('// === END ChatMailFold ===')
block = core[b + len('// === BEGIN ChatMailFold ==='):e]

test_src = read(ROOT / 'scripts/chat-mail-fold-tests/ChatMailFoldTests.swift')
h0 = test_src.index('#"""')
h1 = test_src.index('"""#', h0)
harness = test_src[h0 + 4:h1]

(OUT / 'main.swift').write_text('import Foundation\n' + block + '\n' + harness)
swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(OUT / 't'), str(OUT / 'main.swift')],
                       capture_output=True, text=True)
if build.returncode != 0:
    print('COMPILE FAILED')
    print(build.stderr[:4000])
    sys.exit(1)
print('COMPILE OK')
run = subprocess.run([str(OUT / 't')], capture_output=True, text=True)
print(run.stdout.strip())
ok(run.returncode == 0, 'geometry harness exited 0')
lines = [l for l in run.stdout.splitlines() if l.strip()]
asserts = [l for l in lines if l.startswith('ok ') or l.startswith('FAIL ')]
ok(len(asserts) >= 26, 'geometry assertions >= 26 (got %d)' % len(asserts))
ok(all(l.startswith('ok ') for l in asserts), 'no geometry assertion failed')
names = {re.match(r'(?:ok|FAIL) name=([^\s]+)', l).group(1) for l in asserts if re.match(r'(?:ok|FAIL) name=([^\s]+)', l)}
for required in ['total-3x100-gap8', 'collapse-heights', 'expand-heights', 'quarter-last-visible',
                 'quarter-straddle-is-last', 'quarter-topclip', 'sum-linear', 'single-topclip',
                 'progress-zero-duration', 'anchor-clamp-bottom', 'terminal-expand']:
    ok(required in names, 'geometry case present: ' + required)

# ---------------------------------------------------------------- wiring
flight = read(SUPPORT / 'ChatMailFoldFlight.swift')
toggle = read(SUPPORT / 'ChatMailFoldToggle.swift')
layout = read(IOS / 'Agent/MessageList/MessageListLayout.swift')
cell = read(IOS / 'Agent/MessageList/MessageListInfrastructure.swift')
coord = read(IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift')
delegate = read(IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ScrollViewDelegate.swift')
stored = read(IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator.swift')

# Flight: a real clock, a real clip, an anchored offset, identity retire.
for needle in ['CADisplayLink(target: self', 'add(to: .main, forMode: .common)',
               'cell.mailFoldContentTopClip = layout.mailFoldTopClip(at: idx)',
               'cell.accordionContentHeight = max(0, plan.naturalHeights[k])',
               'cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)',
               'if cv.isTracking || cv.isDecelerating', 'func retarget(_ direction: Direction)',
               'guard cv.window != nil else', 'planStillMatches(items)', 'restoreClip()']:
    ok(needle in flight, 'flight: ' + needle)
# No scale / fade / screenshot: the block must stay at full size, only clipped.
for banned in ['UIView.animate(', 'snapshotView(afterScreenUpdates', 'transform =', 'alpha =', '.frame(height']:
    ok(banned not in flight, 'flight: no ' + banned)
# finish() must NOT clear the span or lay out: the settle owns both.
finish_body = flight[flight.index('func finish(_ outcome: Outcome)'):flight.index('func cancel()')]
ok('clearMailFold' not in finish_body, 'finish never clears the span itself')
ok('layoutIfNeeded' not in finish_body, 'finish never lays out (no restored-natural-height frame)')
ok('restoreClip()' in finish_body, 'finish restores the cell windows')

# Transaction: end-state settle is ONE block, structure before the span clear.
settle = toggle[toggle.index('static func settle('):]
ok(settle.index('updateMailFoldReveal(terminal)') < settle.index('env.applyStructure("mailFoldEnd")'),
   'settle: terminal window before the structural apply')
ok(settle.index('env.applyStructure("mailFoldEnd")') < settle.index('layout.clearMailFold()'),
   'settle: rows are deleted while they still occupy no space, then the span clears')
ok('UIView.performWithoutAnimation' in settle, 'settle is non-animated')
ok('suppressContentOffsetAdjustment = true' in settle, 'settle suppresses UIKit offset compensation')
ok('outcome == .interrupted' in settle, 'settle distinguishes an interrupted flight (finger owns the offset)')
ok('terminalReveal(expanding: expanding)' in settle and 'finalDirection.isExpanding' in settle,
   'settle uses the FINAL direction, not the tap request')
ok('outcome == .interrupted' in toggle and "case interrupted" in flight, 'interrupt outcome exists')
ok('fallback=reduce-motion' in toggle and 'fallback=streaming' in toggle, 'reduce-motion / streaming fallbacks')
ok('fallback=unmeasured' in toggle, 'unmeasured children never animate')
ok('fallback=non-contiguous' in toggle, 'non-contiguous run never animates')
ok('RAPID REVERSAL' in toggle and 'live.retarget(direction)' in toggle,
   'rapid reversal retargets the live flight instead of restarting it')
ok('env.items().contains(request.item)' in toggle, 'retarget requires the header to still be in the list')
ok('receipt.height > 0.5' in toggle, 'a zero-height receipt is not a measurement')
ok('ToolGroupAccordionMeasurement.naturalHeights' in toggle, 'off-screen children are really measured')
ok('layout.setMeasuredHeight(heights[k], at: idx)' in toggle, 'natural heights frozen in the cache first')
ok('env.currentFlight()?.cancel()' in toggle, 'one owner at a time')
ok('layout.toolGroupAccordionAbort = {' in toggle, 'takeover channel armed')
ok('flight.finish(.interrupted)' in toggle, 'takeover lands the end state')

# Layout: the same mail window for the rows, and no self-sizing fight.
ok('struct MailFoldSpan' in layout, 'layout: MailFoldSpan')
ok('mailShown[span.lowerBound + k] = visible' in layout, 'layout: per-row mail window')
ok('mailClips[span.lowerBound + k] = visible <= 0.5 ? 0 : max(0, min(windowStart - start, h))' in layout,
   'layout: top clip matches the helper')
ok('let windowStart = total * (1 - reveal)' in layout, 'layout: bottom-anchored window')
ok('isMailFoldIndex(index)' in layout, 'layout: self-sizing skipped for the block')
ok('if let shown = mailShown[i], shown <= 0.5 {' in layout, 'layout: empty rows hidden')
ok('let slotEnd = start + h + (k == n - 1 ? trailing : gap)' in layout,
   'layout: internal AND trailing gaps folded into their slots')
ok('let trailing = max(0, span.trailingSpacing)' in layout, 'layout: the span carries its trailing gap')
ok('func resolvedGapAfter(index: Int) -> CGFloat' in layout, 'layout: footer-hug aware trailing gap')
ok('gapWithheld = false' in layout, 'layout: no layout gap is added for a span row')
ok(layout.count('let windowStart = total * (1 - ') >= 2, 'layout: the span and the diagnostics use one formula')

# Cell: natural content height + top clip window.
ok('var mailFoldContentTopClip: CGFloat = 0' in cell, 'cell: top clip property')
ok('contentView.frame = CGRect(x: 0, y: -top, width: bounds.width, height: target)' in cell,
   'cell: content shifted up, never re-laid')
ok('let target = natural' in cell, 'cell: content view keeps the natural height')
ok('mailFoldContentTopClip = 0' in cell, 'cell: reuse resets the clip')

# Coordinator: production path tries mail first, falls back to the original.
toggle_fn = coord[coord.index('func toggleToolGroup(firstBlockId: UUID)'):coord.index('func refreshToolGroupToggleRow')]
ok('ChatMailFoldToggle.run(mailRequest, in: mailEnv)' in toggle_fn, 'coordinator runs the mail transaction')
ok('ToolGroupOriginalToggle.run(request, in: env)' in toggle_fn, 'coordinator keeps the instant switch as the fallback')
ok('rowSpacing: layout.itemSpacing' in toggle_fn, 'coordinator passes the layout spacing')
ok('case .started:' in toggle_fn, 'coordinator short-circuits when the flight started')
ok('mailFoldFlight' in stored, 'coordinator stores the live flight')
ok('abortToolGroupAccordion()' in delegate, 'drag takes the viewport from the fold')

# No production path may name the cancelled curtain driver for the tap.
ok('ToolGroupAccordionFlight' not in toggle_fn, 'no cancelled curtain driver on the tap')

print('CHATMAILFOLD_PASS geometry=%d static=%d failures=%d' % (len(asserts), 40, len(failures)))
if failures:
    print('FAILURES:', failures)
    sys.exit(1)
