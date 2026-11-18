#!/usr/bin/env python3
"""Ask-card anchor regression: the SHIPPING ToggleAnchorMath block + wiring guards.

The answered-question card's collapse moved the whole page when the tool group
below it was collapsed (user recording, 8.8s 888x1920: one frame moved ~103px
with animations off, next to two smooth ~102px moves). The clamp that UIKit
applies inside its own layout pass cannot be animated; the fix predicts it
before the resize, keeps it legal, and makes the anchor token-owned.

This gate:
  * extracts `// BEGIN ToggleAnchorMath` ... `// END ToggleAnchorMath` from
    `MessageListLayout.swift` verbatim and compiles it with
    `scripts/ask-card-anchor-tests/AskCardAnchorChecks.swift` (real production
    code, never a copy),
  * asserts the coordinator wiring: measure -> pre-clamp -> install -> layout ->
    plan, token-owned release, no offset write while the user drags, no
    unbounded padding,
  * prints `ASK_CARD_ANCHOR_PASS checks=<n>` only when all of it ran.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS = ROOT / 'src' / 'ios'
LAYOUT = IOS / 'Agent/MessageList/MessageListLayout.swift'
FOLD = IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+ToolFolding.swift'
TESTS = ROOT / 'scripts/ask-card-anchor-tests'
OUT = ROOT / 'build/ask-card-anchor'
OUT.mkdir(parents=True, exist_ok=True)

checks = 0
failures = []


def check(label, cond, detail=''):
    global checks
    checks += 1
    if cond:
        print('  ok   ' + label)
    else:
        failures.append(label)
        print('  FAIL ' + label + (' ' + detail if detail else ''))


def extract_block():
    text = LAYOUT.read_text()
    a = text.find('// BEGIN ToggleAnchorMath')
    b = text.find('// END ToggleAnchorMath')
    if a < 0 or b < 0 or b < a:
        raise SystemExit('ToggleAnchorMath markers missing from MessageListLayout.swift')
    block = text[a:b + len('// END ToggleAnchorMath')]
    if 'enum ToggleAnchorMath {' not in block or 'static func cardAnchorPlan' not in block:
        raise SystemExit('extracted block is not the shipping ToggleAnchorMath')
    path = OUT / 'ProductionToggleAnchorMath.swift'
    path.write_text('import Foundation\n\n' + block + '\n')
    print('BLOCK_LINES ' + str(block.count(chr(10)) + 1))
    return block, path


def compiler():
    for c in ('/usr/bin/swiftc', '/usr/local/bin/swiftc'):
        if pathlib.Path(c).is_file():
            return c
    out = subprocess.run(['/usr/bin/env', 'which', 'swiftc'], capture_output=True, text=True)
    return out.stdout.strip() or 'swiftc'


def run_math(block_path):
    bin_path = OUT / 'AskCardAnchorMath'
    # Top-level code is only allowed in `main.swift` when several files are
    # compiled together, so the assertion file is copied under that name.
    main_copy = OUT / 'main.swift'
    main_copy.write_text((TESTS / 'AskCardAnchorChecks.swift').read_text())
    cmd = [compiler(), '-swift-version', '5', str(block_path), str(main_copy), '-o', str(bin_path)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (OUT / 'compile.log').write_text(r.stdout)
    if r.returncode != 0:
        print(r.stdout[-6000:])
        raise SystemExit('swiftc failed on the shipping ToggleAnchorMath block')
    check('the shipping ToggleAnchorMath block compiles with its assertions', True)
    run = subprocess.run([str(bin_path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (OUT / 'math.log').write_text(run.stdout)
    print(run.stdout)
    m = re.search(r'ASK_CARD_ANCHOR_MATH_PASS checks=(\d+)', run.stdout)
    check('the compiled math assertions pass', run.returncode == 0 and m is not None,
          'rc=' + str(run.returncode))
    return int(m.group(1)) if m else 0


def wiring_guards():
    fold = FOLD.read_text()
    layout = LAYOUT.read_text()
    a = fold.find('func remeasureKeepingTop(')
    b = fold.find('func verifyToggledHeight(')
    body = fold[a:b] if a >= 0 and b > a else ''
    check('remeasureKeepingTop found', bool(body))
    if not body:
        return
    order = ['cell.preferredLayoutAttributesFitting(attrs)',
             'ToggleAnchorMath.preResizeOffset(',
             'layout.setMeasuredHeight(fittedHeight, at: i)',
             'cv.layoutIfNeeded()',
             'ToggleAnchorMath.cardAnchorPlan(']
    # `cv.layoutIfNeeded()` also runs in the off-screen branch; measure the
    # one that belongs to this pass (the first after the install).
    pos = [body.find(t) for t in order]
    inst = pos[2]
    lay = body.find('cv.layoutIfNeeded()', inst)
    pos[3] = lay
    check('ordering: measure -> pre-clamp -> install -> layout -> plan',
          all(p >= 0 for p in pos) and pos == sorted(pos), str(pos))
    pre = body.find('ToggleAnchorMath.preResizeOffset(')
    nxt = body.find('UIView.performWithoutAnimation', pre)
    check('the pre-clamp write is outside UIView.performWithoutAnimation (it has to animate)',
          pre >= 0 and (nxt < 0 or nxt > pre))
    check('the offset is never written while the user drags or glides',
          'let userHoldsOffset = cv.isTracking || cv.isDecelerating' in body
          and 'if !userHoldsOffset, abs(target - cv.contentOffset.y) > 0.5' in body)
    check('no unbounded padding / inset invention',
          'contentInset =' not in body and 'contentInsetAdjustmentBehavior' not in body)
    check('the anchor is token-owned and released by token',
          'layout.beginTopAnchor(index: i)' in body
          and 'layout?.endTopAnchor(token: anchorToken)' in body
          and 'layout?.topAnchoredIndex = nil' not in fold)
    check('both verifier entry points carry the settled anchor + token',
          fold.count('anchorY: settledAnchorY, token: anchorToken') >= 2)
    va = fold.find('func verifyToggledHeight(')
    vb = fold.find('// MARK: - [T-thinking-toggle-txn]', va)
    verify = fold[va:vb] if va >= 0 and vb > va else ''
    check('the verifier stops when a newer toggle owns the anchor',
          'layout.topAnchorOwned(by: token)' in verify)
    check('the verifier never re-reads a mid-animation anchor',
          'frame.minY - cv.contentOffset.y' not in verify)
    check('the verifier still corrects a real height change',
          'layout.setMeasuredHeight(fitted, at: i)' in verify)
    for api in ['func beginTopAnchor(index: Int) -> Int',
                'func topAnchorOwned(by token: Int) -> Bool',
                'func retargetTopAnchor(token: Int, index: Int) -> Bool',
                'func endTopAnchor(token: Int) -> Bool']:
        check('layout: ' + api, api in layout)
    check('layout: the newest token wins', 'Self.topAnchorTokenSeq += 1' in layout)
    check('layout: the visible-cell compensation still skips the anchored row',
          '!ToggleAnchorMath.skipsVisibleCompensation(index: index, anchored: topAnchoredIndex)' in layout)

    # ---- CROSS: the answered-question card vs the system status-bar flight ----
    # Combined candidate (mod-ask-card-statusbar-combined-20261119). Both
    # features write `contentOffset`; these guards pin WHO owns it when they
    # meet, so a later edit cannot re-introduce two writers.
    delegate = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/'
                'MessageListV3Coordinator+ScrollViewDelegate.swift').read_text()
    bindings = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Coordinator/'
                'MessageListV3Coordinator+Bindings.swift').read_text()
    lifecycle = (IOS / 'Agent/MessageList/CollectionViewMessageListV3/Support/'
                 'StatusBarScrollToTop.swift').read_text()
    b0 = delegate.find('func beginStatusBarScrollToTop(')
    b1 = delegate.find('private func resumeAfterStatusBarScrollToTop')
    flight_begin = delegate[b0:b1] if 0 <= b0 < b1 else ''
    d0 = delegate.find('func scrollViewWillBeginDragging(')
    d1 = delegate.find('func scrollViewWillEndDragging(')
    drag = delegate[d0:d1] if 0 <= d0 < d1 else ''
    check('cross: the flight start abandons the card anchor + probe chain',
          'abandonTopAnchor()' in flight_begin)
    check('cross: a real drag abandons the card anchor too', 'abandonTopAnchor()' in drag)
    check('cross: both session-change paths drop the card anchor',
          bindings.count('abandonTopAnchor()') >= 2)
    check('cross: a card toggle ends the flight BEFORE it touches the offset',
          'finishStatusBarScrollToTop(reason: .askToggle' in body
          and 0 <= body.find('finishStatusBarScrollToTop(reason: .askToggle')
                   < body.find('layout.beginTopAnchor(index: i)'))
    check('cross: the verifier refuses to probe while the flight owns the viewport',
          'guard !statusBarScrollToTop.isActive, !layout.isSystemScrollToTopActive else' in verify)
    check('cross: the token-less takeover clears the anchor AND the chain',
          'func abandonTopAnchor() -> Bool' in layout
          and '_topAnchorToken = 0' in layout and '_verifyChainToken = 0' in layout)
    check('cross: the flight lifecycle names the ask-toggle reason',
          'case askToggle' in lifecycle)
    # [T-user-ask-anchor-pending] `finish` only QUEUES the flight's deferred
    # streaming snapshot (`DispatchQueue.main.async` ->
    # `flushPendingSnapshotIfNeeded`). A `flushPending` apply with unchanged
    # items runs `remeasureVisibleCells`, which invalidates every visible row's
    # cached height - including the one this toggle just installed - and
    # reconfigures the cell while its 0.2s height animation is running. So the
    # toggle consumes it BEFORE it reads/measures/anchors its row.
    consume = body.find('flushPendingSnapshotIfNeeded(caller: "askToggle-beforeMeasure")')
    check('cross: the toggle consumes the flight\'s deferred snapshot itself',
          consume >= 0 and 'if hasPendingSnapshot, !isFlushing, vm?.isLoadingSession != true' in body)
    check('cross: …before the row is read, measured and anchored',
          consume >= 0
          and consume < body.find('let ip = IndexPath(item: i, section: 0)')
          and consume < body.find('layout.beginTopAnchor(index: i)')
          and consume < body.find('cell.preferredLayoutAttributesFitting(attrs)'),
          str((consume, body.find('let ip = IndexPath(item: i, section: 0)'),
               body.find('layout.beginTopAnchor(index: i)'))))
    # The flush can insert/remove rows ABOVE this one, so the index the toggle
    # measures must come from the data source, not from the caller's snapshot.
    remap = body.find('guard let row = ds.snapshot().itemIdentifiers.firstIndex(of: item)')
    check('cross: the row index is re-read from the data source after the flush',
          remap >= 0 and consume >= 0 and consume < remap
          and 'let i = row' in body
          and remap < body.find('layout.beginTopAnchor(index: i)')
          and remap < body.find('layout.setMeasuredHeight(fittedHeight, at: i)'))
    check('cross: a row that is gone still runs the one-shot request',
          'else {\n                _ = request?.run()\n                return\n            }\n            let i = row' in body)
    check('cross: the verifier still does not re-anchor to a live read',
          'frame.minY - cv.contentOffset.y' not in verify
          and 'anchorY: settledAnchorY' in fold)


def main():
    block, block_path = extract_block()
    math_checks = run_math(block_path)
    wiring_guards()
    print('\nASK_CARD_ANCHOR_CHECKS total=' + str(checks) + ' failures=' + str(len(failures))
          + ' math=' + str(math_checks))
    if failures:
        print('ASK_CARD_ANCHOR_FAIL ' + '; '.join(failures[:8]))
        raise SystemExit(1)
    print('ASK_CARD_ANCHOR_PASS checks=' + str(checks))


if __name__ == '__main__':
    main()
    sys.exit(0)
