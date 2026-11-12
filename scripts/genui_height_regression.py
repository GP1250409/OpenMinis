#!/usr/bin/env python3
"""GenUI card state commits: real UIKit regression (macOS + Xcode).

Contract under test (branch mod-genui-height-transaction):

  * `MinisUIStore.update(blockId:sessionId:_:)` posts `MinisUIStateChanged`
    SYNCHRONOUSLY (no `receive(on:)`) carrying a `MinisUIStateUpdate`
    (blockId / sessionId / ToggleRequest); if nobody consumed it, the store
    runs the request itself inside a no-animation transaction, once.
  * `MinisUICardView.persist` no longer writes the block and then asks for a
    re-measure: the write happens inside the list's own real-height pass.
    Slider live drags still write directly (no save, no re-measure); the
    release force-commits through `MinisUIStore.update`.
  * `CollectionViewMessageListV3.Coordinator.commitGenUIStateChange(_:)`
    (new file `MessageListV3Coordinator+GenUI.swift`) consumes exactly the
    update belonging to the current session and to a `.genuiTool` /
    `.success` block that is STILL in the snapshot. One no-animation
    transaction: capture the old offset, suppression on, `request.run()`,
    fresh `configureCell` config, clear the cell's cached height, measure the
    real fitted height, keep the OLD real height until the new one exists
    (never `invalidateHeight` down to the coarse estimate). Only when the
    height really changed (> 0.5pt) invalidate + `layoutIfNeeded` + clamp the
    offset. A pure value change (Segmented at constant height) must not move
    the list geometry at all.
  * `MessageListLayout.setInteractiveMeasuredHeight(_:at:)` commits the real
    height and discards stale deferred / precalc entries for that index.

Compiles, verbatim:
  * `MessageListLayout.swift` (the layout, incl. `setInteractiveMeasuredHeight`),
  * `SelfSizingCell` + `MessageListItem` sliced out of `MessageListInfrastructure.swift`,
  * `MinisUIStateUpdate` + `MinisUIStore` and `MinisUICardView.persist`'s body
    region sliced out of `MinisUIView.swift`,
  * every `extension CollectionViewMessageListV3.Coordinator { … }` block of
    `MessageListV3Coordinator+GenUI.swift` (the commit method itself),
  wrapped in the fixture coordinator of
  `scripts/genui-height-tests/GenUICoordinatorStub.swift` and driven in a real
  `UICollectionView` (`UIHostingConfiguration` card fixture) on an iOS
  simulator.

`--source-only` runs every static contract check and the fixture-coverage
audit without Xcode (Linux preflight); it never claims the runtime suite ran.

Prints `GENUI_HEIGHT_UIKIT_PASS checks=<n>` on success.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/genui-height'
tests = root / 'scripts/genui-height-tests'
app = out / 'GenUIHeight.app'

layout_path = root / 'src/ios/Agent/MessageList/MessageListLayout.swift'
infra_path = root / 'src/ios/Agent/MessageList/MessageListInfrastructure.swift'
card_path = root / 'src/ios/Views/Chat/AIChatView/MinisUI/MinisUIView.swift'
coord = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator'
genui_coord_path = coord / 'MessageListV3Coordinator+GenUI.swift'
snapshot_path = coord / 'MessageListV3Coordinator+Snapshot.swift'
core_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator.swift'

source_only = '--source-only' in sys.argv[1:]
verbose = '--verbose' in sys.argv[1:]

failures = []
contract_pending = []


def note(msg):
    print(msg, flush=True)


def need(cond, msg):
    if cond:
        note('SOURCE_CHECK_OK: ' + msg)
    else:
        failures.append(msg)
        note('SOURCE_CHECK_FAIL: ' + msg)


def pending(cond, msg):
    """A rule the production edit must satisfy. Missing = FAIL in a full run
    (never skipped): a stale fixture must not let the old model pass silently.
    `--source-only` reports it as PENDING because production may not have
    landed yet."""
    if cond:
        note('CONTRACT_OK: ' + msg)
    else:
        contract_pending.append(msg)
        note('CONTRACT_PENDING: ' + msg)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f'extraction failed: end marker not found ({label})')
    return text[i:j]


def brace_block(text, marker, label):
    """Return `marker … }` by matching braces, so a nested-closure body is not
    truncated by the next `// MARK:` (a stale end-marker is exactly what
    produced a historic false extraction)."""
    i = text.find(marker)
    if i < 0:
        raise SystemExit(f'extraction failed: {label} not found')
    depth = 0
    for k in range(i, len(text)):
        c = text[k]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return text[i:k + 1]
    raise SystemExit(f'extraction failed: unbalanced braces for {label}')


# --------------------------------------------------------------------------
# slices
# --------------------------------------------------------------------------

def extract_slices(source_only_mode=False):
    out.mkdir(parents=True, exist_ok=True)
    infra = infra_path.read_text()
    item = slice_between(infra, 'enum MessageListItem: Hashable {', '// MARK: - Self-Sizing Cell',
                         'MessageListItem')
    cell = slice_between(infra, 'class SelfSizingCell: UICollectionViewCell {',
                         '// MARK: - NoAnimationCollectionView', 'SelfSizingCell')
    (out / 'ProductionMessageListItem.swift').write_text('import Foundation\n\n' + item + '\n')
    (out / 'ProductionSelfSizingCell.swift').write_text(
        'import Foundation\nimport UIKit\nimport SwiftUI\n\n' + cell + '\n')
    note(f'CELL_SLICE_LINES {cell.count(chr(10)) + 1}')

    card = card_path.read_text()
    try:
        store = slice_between(card, 'final class MinisUIStateUpdate {', 'enum MinisUITool {',
                              'MinisUIStateUpdate + MinisUIStore')
    except SystemExit:
        store = ''
    if store:
        (out / 'ProductionMinisUIStore.swift').write_text('import SwiftUI\nimport UIKit\n\n' + store + '\n')
    return store


def instrumented_layout():
    """The production layout with ONE token removed so the fixture can observe
    `invalidateLayout()` / `prepare()`: `final class MessageListLayout:` ->
    `class MessageListLayout:`. Every other byte (all method bodies) is
    identical — asserted below, not promised."""
    src = layout_path.read_text()
    marker = 'final class MessageListLayout:'
    if src.count(marker) != 1:
        raise SystemExit(f'expected exactly one `{marker}` in MessageListLayout.swift, '
                         f'found {src.count(marker)}')
    body = src.replace(marker, 'class MessageListLayout:')
    header = (
        '// GENERATED by scripts/genui_height_regression.py — DO NOT EDIT.\n'
        '//\n'
        '// This is src/ios/Agent/MessageList/MessageListLayout.swift verbatim with\n'
        '// exactly ONE change, so the fixture subclass `GenUITrackedLayout` can\n'
        '// observe invalidation / prepare passes:\n'
        '//\n'
        '//     final class MessageListLayout:  ->  class MessageListLayout:\n'
        '//\n'
        '// The single word `final` is removed; no method body, property, marker or\n'
        '// comment is touched (the runner asserts byte equality modulo that token).\n'
        '// The production file itself is never modified.\n'
        '\n')
    path = out / 'InstrumentedProductionLayout.swift'
    path.write_text(header + body)
    if path.read_text().replace(header, '').replace('class MessageListLayout:',
                                                    'final class MessageListLayout:') != src:
        raise SystemExit('instrumented layout is not byte-identical to production apart from `final`')
    note('INSTRUMENTED_LAYOUT_ONLY_CHANGE final-removed (bytes identical otherwise, '
         f'{body.count(chr(10)) + 1} lines)')
    return path


def production_genui_block():
    """The commit method + helpers from the new coordinator file, verbatim."""
    if not genui_coord_path.exists():
        return None, ''
    text = genui_coord_path.read_text()
    if 'func commitGenUIStateChange(' not in text:
        return None, ''
    blocks = []
    idx = 0
    while True:
        i = text.find('extension CollectionViewMessageListV3.Coordinator {', idx)
        if i < 0:
            break
        block = brace_block(text[i:], 'extension CollectionViewMessageListV3.Coordinator {',
                            'genui coordinator extension')
        blocks.append(block)
        idx = i + len(block)
    if not blocks:
        # A `// MARK:`-style file: lift the method with brace matching.
        blocks.append(brace_block(text, 'func commitGenUIStateChange(', 'commitGenUIStateChange'))
    wrapped = 'import UIKit\nimport SwiftUI\n\n' + '\n\n'.join(blocks) + '\n'
    path = out / 'GenUICoordinatorBlock.swift'
    path.write_text(wrapped)
    funcs = re.findall(r'\n\s{0,12}func ([A-Za-z0-9_]+)\(', '\n\n'.join(blocks))
    note('GENUI_BLOCK_FUNCS ' + ','.join(funcs))
    note('GENUI_BLOCK_LINES ' + str(wrapped.count('\n')))
    return path, wrapped


# --------------------------------------------------------------------------
# static contract checks (no Xcode needed)
# --------------------------------------------------------------------------

def source_checks(store_slice='', genui_block=''):
    layout = layout_path.read_text()
    card = card_path.read_text()
    snap = snapshot_path.read_text()

    # ---- store: synchronous post, one-shot fallback ----
    need('final class MinisUIStateUpdate {' in card
         and 'let blockId: UUID' in store_slice
         and 'let sessionId: String?' in store_slice
         and 'let request: ToggleRequest' in store_slice,
         'MinisUIStateUpdate carries blockId / sessionId / ToggleRequest')
    need(re.search(r'static func update\(blockId: UUID, sessionId: String\?,'
                   r'( state: \(\(\) -> String\?\)\? = nil,)? _ apply: @escaping \(\) -> Void\)', store_slice) is not None,
         'MinisUIStore.update(blockId:sessionId:[state:]_:_) signature')
    need('static func enqueue(_ work: @escaping () -> Void)' in store_slice
         and 'DispatchQueue.main.async(execute: work)' in store_slice,
         'MinisUIStore.enqueue puts the whole mutation on the next main-queue turn')
    need('precondition(Thread.isMainThread)' in card
         and 'assert(Thread.isMainThread)' not in card,
         'the main-thread contract is a precondition (not a debug-only assert)')
    need('NotificationCenter.default.post(name: stateChanged, object: change)' in store_slice,
         'the update is posted synchronously (plain post, no scheduler hop)')
    update_fn = brace_block(store_slice, 'static func update(blockId: UUID', 'MinisUIStore.update')
    need('receive(on:' not in update_fn and 'DispatchQueue.main.async' not in update_fn,
         'no receive(on:)/async hop inside MinisUIStore.update (the post stays synchronous)')
    need('if !change.request.hasRun {' in store_slice and 'withTransaction' in store_slice
         and 'disablesAnimations = true' in store_slice,
         'no-handler fallback runs the request once inside a no-animation transaction')

    # ---- card: persist through the list, slider live stays direct ----
    need('let state: (() -> String?)?' in store_slice
         and 'state: (() -> String?)? = nil' in store_slice,
         'MinisUIStateUpdate carries the origin final state reader (optional, nil default)')
    persist = brace_block(card, 'private func persist(_ st: [String: MUValue], force: Bool = false) {',
                          'persist')
    need('MinisUIStore.update(blockId: block.id, sessionId: vm.sessionId, state:' in persist,
         'persist delegates the state write to MinisUIStore.update')
    need('block.genuiStateJSON = after' in persist,
         'the write itself is still performed (inside the list transaction)')
    need('MinisUIStore.didResize' not in card,
         'the old post-then-resize path (didResize) is gone')
    need('GenUIStatePersistence.save(' in persist,
         'persistence still happens after the commit')
    need('state: { block.genuiStateJSON }' in persist,
         'persist hands the origin final state to the list (separate block instances)')
    # Three queue call sites: slider release / segmented-choice / button action.
    enq = brace_block(card, 'private func enqueueStateChange(_ work: @escaping () -> Void) {',
                      'enqueueStateChange')
    need('MinisUIStore.enqueue' in enq, 'enqueueStateChange routes through MinisUIStore.enqueue')
    need('guard vm.sessionId == sessionId else { return }' in enq,
         'a queued change re-checks the session (no leak after navigation)')
    need('commit: { enqueueStateChange {' in card,
         'slider release commits through the queue')
    set_state = brace_block(card, 'private func setState(_ name: String, _ value: MUValue, live: Bool,',
                            'setState')
    need('} else {\n            enqueueStateChange {' in set_state
         and 'var latest = currentState(defaults)' in set_state,
         'non-live input changes queue, then re-read state and touch only their own key')
    run_action = brace_block(card, 'private func runAction(_ act: MUAction', 'runAction')
    need('enqueueStateChange { applyAction(' in run_action,
         'a button action (and its @ToAssistant turn) runs after the queue, not inside the touch callback')
    need('didResize' not in snap, 'the notification sink no longer handles didResize')
    set_state = brace_block(card, 'private func setState(_ name: String, _ value: MUValue, live: Bool,',
                            'setState')
    live_region = set_state.split('} else {')[0]
    need('MinisUIStore.update' not in live_region and 'block.genuiStateJSON = MinisUITool.encodeState(st)' in live_region,
         'slider live drag writes directly (no save, no re-measure)')
    need('persist(latest)' in set_state, 'a slider release force-commits the re-read state through persist')

    # ---- coordinator wiring ----
    need('var genuiStateSub: AnyCancellable?' in core_path.read_text(),
         'coordinator owns a genui state subscription token')
    sink = ''
    if 'if genuiStateSub == nil {' in snap:
        sink = brace_block(snap, 'if genuiStateSub == nil {', 'genui subscription')
    elif 'MinisUIStore.stateChanged' in snap:
        i = snap.find('MinisUIStore.stateChanged')
        sink = snap[max(0, i - 400): i + 500]
    need('MinisUIStore.stateChanged' in snap, 'coordinator subscribes to MinisUIStore.stateChanged')
    need('commitGenUIStateChange(change)' in sink, 'the subscription forwards to commitGenUIStateChange')
    need(sink != '' and 'receive(on:' not in sink,
         'the genui subscription is NOT moved to another queue (atomic content+height)')

    # ---- layout API ----
    need('func setInteractiveMeasuredHeight(_ height: CGFloat, at index: Int)' in layout,
         'layout exposes setInteractiveMeasuredHeight(_:at:)')
    sim = brace_block(layout, 'func setInteractiveMeasuredHeight(_ height: CGFloat, at index: Int) {',
                      'setInteractiveMeasuredHeight')
    need('heightCache[index] = height' in sim, 'the measured real height is committed')
    need('deferredHeights.removeValue(forKey: index)' in sim
         and 'precalcHeights.removeValue(forKey: index)' in sim,
         'stale deferred / precalc entries for that index are discarded')
    need('thinkingToggleTxn' not in sim and 'topAnchoredIndex' not in sim,
         'the interactive commit does not touch the thinking transaction / top anchor')

    # ---- the commit method ----
    if not genui_coord_path.exists():
        pending(False, 'MessageListV3Coordinator+GenUI.swift exists (production not landed yet)')
        pending(False, 'commitGenUIStateChange consumes only the current session + live snapshot block')
        pending(False, 'commit applies the request in one no-animation transaction with a fresh configureCell')
        pending(False, 'commit keeps the old real height until the new one is measured (no invalidateHeight first)')
        pending(False, 'only a > 0.5pt height diff invalidates and clamps the offset')
        pending(False, 'no thinkingBlockToggled / no 0.6s lock / no reveal animation in the genui commit')
        pending(False, 'the genui commit matches .genuiTool + .success only')
        return True
    pending(len(genui_block) > 400, 'commitGenUIStateChange body was extracted')
    pending('func commitGenUIStateChange(_ change: MinisUIStateUpdate)' in genui_block,
            'commitGenUIStateChange(_ change: MinisUIStateUpdate) signature')
    body = brace_block(genui_block, 'func commitGenUIStateChange(',
                       'commitGenUIStateChange') if 'func commitGenUIStateChange(' in genui_block else ''
    pending('change.sessionId' in body and ('vm?.sessionId' in body or 'sessionId ==' in body),
            'session mismatch is not consumed (current session compared to change.sessionId)')
    pending('dataSource.snapshot()' in body or 'snapshot()' in body,
            'the target row is resolved against the current snapshot, not a cached index')
    pending('.genuiTool' in body, 'only a genui card block is committed')
    card_src = card_path.read_text()
    renders_ok = ('.success' in body
                  or ('MinisUITool.renders(block)' in body
                      and 'case .success = block.toolStatus' in card_src))
    pending(renders_ok, 'only a successfully rendered card is committed (.success / MinisUITool.renders)')
    pending('_ = change.request.run()' in body, 'the one-shot request is applied inside the commit')
    pending('!change.request.hasRun' not in body,
            'EVERY mounted list measures (the !hasRun guard is gone)')
    pending('if let readState = change.state' in body and 'block.genuiStateJSON != after' in body,
            'the origin final state is written to this list\'s own block when it differs')
    pending('withTransaction' in body and 'disablesAnimations = true' in body,
            'the commit runs inside one no-animation transaction')
    pending('configureCell(' in body, 'the cell is reconfigured (fresh content, not a bare height write)')
    pending(body.find('configureCell(') >= 0 and body.find('configureCell(') < body.find('preferredLayoutAttributesFitting('),
            'the fresh configure runs BEFORE the real height is fitted (same height still re-measures)')
    pending('clearInteractiveHeightCache()' in body or 'clearCachedHeight()' in body,
            'the cell height cache (fitted + seeded) is cleared before measuring')
    pending('suppressContentOffsetAdjustment' in body and 'isFlushing' in body,
            'UIKit offset compensation and the flush path are suppressed during the commit')
    pending('setInteractiveMeasuredHeight(' in body, 'the measured real height is committed to the layout')
    # The old model: invalidate first (drops to estimate), or a timer, or a reveal.
    pending('asyncAfter(deadline: .now() + 0.6)' not in genui_block,
            'no 0.6s transaction lock in the genui path')
    pending('scrollToItem(' not in genui_block and 'revealItem(' not in genui_block
            and 'scrollToBottom(' not in genui_block,
            'no reveal-scroll (scrollToItem/revealItem) in the genui path')
    pending('UIView.animate' not in genui_block and 'withAnimation' not in genui_block,
            'no animation in the genui commit')
    pending('.thinkingBlockToggled' not in genui_block and 'toggleAnchor' not in genui_block,
            'the genui commit emits no thinkingBlockToggled / anchor post')
    pending('func verifyGenUIStateHeight(' in genui_block,
            'one bounded async verify exists (state + session + snapshot generation guarded)')
    verify_body = ''
    if 'func verifyGenUIStateHeight(' in genui_block:
        verify_body = brace_block(genui_block, 'func verifyGenUIStateHeight(', 'verifyGenUIStateHeight')
    pending('block.genuiStateJSON == expectedState' in body
            and 'snapshotApplyGeneration == generation' in body
            and 'self.vm?.sessionId == change.sessionId' in body,
            'async verify returns early on state / snapshot-generation / session mismatch (no stale offset replay)')
    pending('!cv.isDragging' in verify_body and '!cv.isDecelerating' in verify_body,
            'async verify does not run while the user drags/decelerates')
    pending('self.verifyGenUIStateHeight(' in body and 'self.verifyGenUIStateHeight(' not in verify_body,
            'the verify step cannot recurse into itself')
    # The VISIBLE branch must never invalidate: the old real height stays until
    # the replacement is measured. The off-screen branch may invalidate (there
    # is no cell to fit), so the check is structural, not a text window.
    vi = body.find('if let cell = cv.cellForItem')
    vj = body.find('} else {', vi) if vi >= 0 else -1
    visible_branch = body[vi:vj] if 0 <= vi < vj else ''
    offscreen_branch = body[vj:] if vj >= 0 else ''
    pending(visible_branch != '', 'the visible branch of the commit was located for inspection')
    pending('invalidateHeight(' not in visible_branch,
            'the VISIBLE branch never calls invalidateHeight (old real height kept until the new one is measured)')
    pending('setInteractiveMeasuredHeight(' in visible_branch
            and 'preferredLayoutAttributesFitting(' in visible_branch,
            'the visible branch fits the real height and commits it via setInteractiveMeasuredHeight')
    pending(abs(visible_branch.find('setInteractiveMeasuredHeight(') - visible_branch.find('preferredLayoutAttributesFitting(')) < 400
            if 'setInteractiveMeasuredHeight(' in visible_branch else False,
            'the commit uses the measured height (fit and commit stay in one pass)')
    if offscreen_branch:
        pending('invalidateLayout()' in offscreen_branch,
                'the off-screen branch asks for a fresh sizing pass (no cell to fit)')

    need('thinkingBlockToggled' not in card.split('MinisUICardView')[1] if 'MinisUICardView' in card else True,
         'the card no longer posts thinkingBlockToggled')
    return True


# --------------------------------------------------------------------------
# fixture coverage audit (works on Linux)
# --------------------------------------------------------------------------

REQUIRED_CASES = [
    ('choiceFeedbackGrows', 'Choice 选中 + 反馈出现：卡片真实长高，上方行不漂移'),
    ('longCardOffscreenKeepsOffset', '长卡片顶部已离屏：点第二题保持 offset'),
    ('resetShrinksBack', '重置后真实收缩，offset 只做合法夹紧'),
    ('segmentedPureValueNoGeometry', 'Segmented 纯值变化同高：不触发额外布局几何'),
    ('rapidRepeatedState', '连点重复 state：幂等，无二次位移'),
    ('sliderLiveThenCommit', 'slider live 期间不测高，松手 commit 测一次'),
    ('noListFallbackKeepsState', '无列表/离屏 fallback：状态写入一次'),
    ('sessionMismatchNotConsumed', 'session 不匹配不被消费，fallback 生效'),
    ('noLayerAnimations', '状态写 + 拟合前后无 layer 动画'),
    ('oldRealHeightNeverEstimate', '旧 real 高度不掉回粗估'),
    ('noThinkingToggleEmitted', '不发出 thinkingBlockToggled'),
    ('widthChangeRemeasure', '变宽/变窄后重新测高的基础 case'),
    ('enqueueDefersStateAndHeight', 'enqueue 前 state/height 都不变，下一 turn 同时正确，两个排队变更不丢 key'),
    ('twoListsSharedBlockChange', '同 session 两列表同 block UUID 不同实例：一次 apply，两边都测高'),
]


def fixture_coverage():
    suite_path = tests / 'GenUIHeightTests.swift'
    if not suite_path.exists():
        failures.append('GenUIHeightTests.swift missing')
        note('SOURCE_CHECK_FAIL: fixture suite missing')
        return 0
    suite = suite_path.read_text()
    hit = 0
    for name, desc in REQUIRED_CASES:
        if f'func {name}(' in suite:
            hit += 1
            note(f'FIXTURE_CASE_OK {name} — {desc}')
        else:
            note(f'FIXTURE_CASE_MISSING {name} — {desc}')
    for helper, why in [
        ('GenUICardFixture', 'SwiftUI 卡片 fixture'),
        ('SelfSizingCell', '真实 SelfSizingCell'),
        ('MessageListLayout', '真实 MessageListLayout'),
        ('MinisUIStore', '真实 MinisUIStore 切片'),
        ('commitGenUIStateChange', '真实 coordinator 方法'),
    ]:
        present = helper in suite or any(helper in p.read_text() for p in tests.glob('*.swift'))
        note(('FIXTURE_LINK_OK ' if present else 'FIXTURE_LINK_MISSING ') + f'{helper} — {why}')
        if not present:
            failures.append(f'fixture does not use {helper}')
    return hit


# --------------------------------------------------------------------------
# build + run (macOS only)
# --------------------------------------------------------------------------

def swift_env():
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()
    return sdk, arch


def syntax_gate(extra):
    files = list(extra)
    sdk, arch = swift_env()
    bad = 0
    for f in files:
        r = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', '-sdk', sdk,
                            '-target', f'{arch}-apple-ios16.0-simulator', str(f)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.returncode != 0:
            bad += 1
            note(f'SYNTAX_FAIL {f.name}')
            note(r.stdout[-4000:])
        else:
            note(f'SYNTAX_OK {f.name}')
    return bad


def build_and_run(genui_src, cell_src, item_src, store_src, instrumented):
    app.mkdir(parents=True, exist_ok=True)
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
    if not choices:
        raise SystemExit('No iPhone simulator available')
    d = next((d for d in choices if d['state'] == 'Booted'), choices[0])
    uid = d['udid']
    if d['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', uid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', uid, '-b'], check=True)
    sdk, arch = swift_env()

    # The real ObjC exception guard SelfSizingCell calls into (not replaced by
    # a Swift closure that cannot catch an NSException).
    native = root / 'src/ios/NativeOffloads'
    native_text = (native / 'NativeOffloadUtils.m').read_text()
    guard_fn = native_text[native_text.index('BOOL noff_try_objc('):native_text.index('// ── Calling session')]
    guard_decl = next(line for line in (native / 'NativeOffloadUtils.h').read_text().splitlines()
                      if line.startswith('BOOL noff_try_objc('))
    bridge_header = out / 'ExceptionBridge.h'
    bridge_header.write_text('#import <Foundation/Foundation.h>\n' + guard_decl + '\n')
    bridge_source = out / 'ExceptionBridge.m'
    bridge_source.write_text('#import "ExceptionBridge.h"\n' + guard_fn)
    bridge_obj = out / 'ExceptionBridge.o'
    br = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-fobjc-arc', '-fblocks',
                         '-isysroot', sdk, '-target', f'{arch}-apple-ios16.0-simulator',
                         '-c', str(bridge_source), '-o', str(bridge_obj)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'objc-bridge.log').write_text(br.stdout)
    if br.returncode:
        note(br.stdout)
        raise SystemExit('production Objective-C exception guard failed to compile')
    note('PRODUCTION_EXCEPTION_BRIDGE_OK')

    # MessageListLayout.prepare() uses the production MessageRowGap rule.
    # Compile its real pure-support file too; a synthetic stub would hide drift.
    spacing = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift'
    sources = [instrumented, spacing, item_src, cell_src, store_src, genui_src,
               tests / 'ProductionStubs.swift', tests / 'GenUICoordinatorStub.swift',
               tests / 'GenUICardFixture.swift', tests / 'GenUIListHarness.swift',
               tests / 'GenUIHeightTests.swift']
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-import-objc-header', str(bridge_header),
           '-o', str(app / 'GenUIHeight')]
    cmd += [str(s) for s in sources] + [str(bridge_obj)]
    (out / 'compile-command.txt').write_text(' '.join(cmd))
    note('COMPILE_START')
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'compile.log').write_text(r.stdout)
    note(r.stdout[-20000:])
    if r.returncode != 0:
        raise SystemExit('swiftc failed — see build/genui-height/compile.log')

    info = {'CFBundleIdentifier': 'com.gonepaul.genui.height',
            'CFBundleExecutable': 'GenUIHeight', 'CFBundleName': 'GenUIHeight',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
            'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
            'UILaunchScreen': {}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', uid, str(app)], check=True)
    try:
        run = subprocess.run(['xcrun', 'simctl', 'launch', '--console', uid, info['CFBundleIdentifier']],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    except subprocess.TimeoutExpired as e:
        partial = e.stdout or ''
        if isinstance(partial, bytes):
            partial = partial.decode(errors='replace')
        (out / 'results-timeout.log').write_text(partial)
        note(partial[-20000:])
        note('GENUI_HEIGHT_LAUNCH_TIMEOUT 180s; partial console saved')
        subprocess.run(['xcrun', 'simctl', 'terminate', uid, info['CFBundleIdentifier']],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        raise SystemExit('GenUI fixture did not finish; partial console retained')
    print(run.stdout, flush=True)
    (out / 'results.log').write_text(run.stdout)
    note('LAUNCH_RETURN_CODE ' + str(run.returncode))
    container = subprocess.run(['xcrun', 'simctl', 'get_app_container', uid, info['CFBundleIdentifier'], 'data'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
    if container.returncode == 0:
        phase = pathlib.Path(container.stdout.strip()) / 'Documents/genui-phase.log'
        if phase.exists():
            journal = phase.read_text()
            (out / 'phase-journal.log').write_text(journal)
            note('GENUI_PHASE_JOURNAL_TAIL\n' + '\n'.join(journal.splitlines()[-16:]))
    # A complete phase journal alone NEVER substitutes for the stdout PASS.

    for key, pattern in (('CHECK_COUNT', r'GENUI_HEIGHT_UIKIT_CHECKS (\d+)'),
                         ('CHOICE_DRIFT', r'GENUI_CHOICE_DRIFT (-?[\d.]+)'),
                         ('OFFSCREEN_DRIFT', r'GENUI_OFFSCREEN_DRIFT (-?[\d.]+)'),
                         ('OFFSCREEN_OFFSET_DELTA', r'GENUI_OFFSCREEN_OFFSET_DELTA (-?[\d.]+)'),
                         ('RESET_DRIFT', r'GENUI_RESET_DRIFT (-?[\d.]+)'),
                         ('SEGMENTED_GEOMETRY', r'GENUI_SEGMENTED_GEOMETRY (\w+)'),
                         ('SLIDER_LIVE_MEASURES', r'GENUI_SLIDER_LIVE_MEASURES (\d+)'),
                         ('FALLBACK_RUNS', r'GENUI_FALLBACK_RUNS (\d+)'),
                         ('LAYER_ANIMATIONS', r'GENUI_LAYER_ANIMATIONS (\d+)'),
                         ('ESTIMATE_FALLBACK', r'GENUI_ESTIMATE_FALLBACK (\d+)'),
                         ('THINKING_POSTS', r'GENUI_THINKING_POSTS (\d+)'),
                         ('WIDTH_HEIGHT', r'GENUI_WIDTH_HEIGHT (-?[\d.]+) -> (-?[\d.]+)')):
        m = re.search(pattern, run.stdout)
        if m:
            note(f'REPORT_{key} ' + ' '.join(m.groups()))

    if 'GENUI_HEIGHT_UIKIT_PASS' not in run.stdout:
        # simctl's exit code is NOT the app exit status. Preserve crash evidence
        # whenever the suite marker is absent, including sudden signals/abort.
        import shutil
        crash_dir = out / 'crash-reports'
        crash_dir.mkdir(exist_ok=True)
        scanner = shutil.which('rg')
        if scanner is None and shutil.which('brew'):
            install = subprocess.run(['brew', 'install', 'ripgrep'], stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, timeout=180)
            (out / 'diagnostic-tools.log').write_text(install.stdout)
            scanner = shutil.which('rg')
        copied = 0
        for directory in [pathlib.Path.home() / 'Library/Logs/DiagnosticReports',
                          pathlib.Path.home() / ('Library/Developer/CoreSimulator/Devices/' + uid + '/data/Library/Logs/CrashReporter')]:
            if not scanner or not directory.exists():
                continue
            scan = subprocess.run([scanner, '--files', '-uuu', '-g', '*GenUIHeight*', str(directory)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
            paths = [pathlib.Path(s) for s in scan.stdout.splitlines() if pathlib.Path(s).suffix in ('.ips', '.crash')]
            for p in sorted(paths, key=lambda p: p.stat().st_mtime, reverse=True)[:5]:
                shutil.copyfile(p, crash_dir / p.name)
                copied += 1
        note('GENUI_CRASH_REPORTS_COPIED ' + str(copied) + ' scanner=' + str(scanner is not None))
        try:
            log = subprocess.run(['xcrun', 'simctl', 'spawn', uid, 'log', 'show', '--style', 'compact',
                                  '--last', '3m', '--predicate', 'process == "GenUIHeight" OR process == "ReportCrash" OR eventMessage CONTAINS "GenUIHeight"'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            (out / 'diagnostic.log').write_text(log.stdout)
        except subprocess.TimeoutExpired:
            (out / 'diagnostic.log').write_text('log show timed out')
        raise SystemExit('genui height UI regression failed (see build/genui-height/)')


def main():
    store_src_text = extract_slices()
    instrumented_layout()  # validates the byte-identical instrumented copy
    item_src = out / 'ProductionMessageListItem.swift'
    cell_src = out / 'ProductionSelfSizingCell.swift'
    store_src = out / 'ProductionMinisUIStore.swift'

    genui_src, genui_block = production_genui_block()
    source_checks(store_src_text, genui_block)
    covered = fixture_coverage()
    note(f'FIXTURE_CASES {covered}/{len(REQUIRED_CASES)}')

    if source_only:
        if failures:
            raise SystemExit('source-only checks failed: ' + '; '.join(failures))
        if contract_pending:
            note('CONTRACT_PENDING_COUNT ' + str(len(contract_pending)))
            for m in contract_pending:
                note('  - ' + m)
            note(f'GENUI_HEIGHT_REGRESSION_SOURCE_ONLY_PENDING pending={len(contract_pending)}')
            raise SystemExit(0)
        note('GENUI_HEIGHT_REGRESSION_SOURCE_ONLY_OK')
        raise SystemExit(0)

    if not store_src_text or genui_src is None:
        raise SystemExit('the GenUI commit production slice is missing — implement '
                         'MinisUIStateUpdate/update + MessageListV3Coordinator+GenUI.swift first')
    instrumented = out / 'InstrumentedProductionLayout.swift'
    gate = [instrumented, root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/QueuedCandidateSpacing.swift',
            tests / 'ProductionStubs.swift', tests / 'GenUICoordinatorStub.swift',
            tests / 'GenUICardFixture.swift', tests / 'GenUIListHarness.swift',
            tests / 'GenUIHeightTests.swift', genui_src, store_src]
    if syntax_gate(gate):
        raise SystemExit('swiftc -frontend -parse failed')
    build_and_run(genui_src, cell_src, item_src, store_src, instrumented)

    if contract_pending:
        raise SystemExit('UIKit suite passed, but the genui commit contract is not met yet: '
                         + '; '.join(contract_pending))
    if failures:
        raise SystemExit('source checks failed: ' + '; '.join(failures))
    note('GENUI_HEIGHT_REGRESSION_OK')


if __name__ == '__main__':
    main()
