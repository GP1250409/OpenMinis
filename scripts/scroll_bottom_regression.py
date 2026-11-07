#!/usr/bin/env python3
"""Manual down-arrow jump-to-bottom: real UIKit animation regression (macOS + Xcode).

Compiles, verbatim, out of the production coordinator:

  * `MessageListV3Coordinator+Scroll.swift`: `isNearBottom` / `isAtContentTop` /
    `isWithinBottom`, `nbDump`, `bottomRestingOffset`,
    `applySubViewportCompensation` (with its pin), `absorbPendingComposerShrink`,
    `animatesJumpToBottom`, `scrollToBottomNow`, `syncScrollFlags`;
  * `MessageListV3Coordinator+Streaming.swift`: `scheduleCoalescedScroll`;
  * `MessageListV3Coordinator+ScrollViewDelegate.swift`:
    `scrollViewWillBeginDragging`, `scrollViewDidEndScrollingAnimation`;
  * `Support/ComposerShrinkAbsorption.swift` whole.

…into `extension CollectionViewMessageListV3.Coordinator` (see
`scripts/scroll-bottom-tests/ScrollFixture.swift` for the stand-ins) and runs it
against a REAL `UICollectionView` in a REAL window on an iOS simulator, launched
as a UIApplication so UIKit's display link drives the scroll animation:

  1. the manual jump glides (frame-by-frame travel, native duration, lands on
     the resting bottom, flag cleared),
  2. negative control: pin-first (the old order) produces no travel at all,
  3. rapid repeated taps restart from the current offset without a jump,
  4. a user drag clears the in-flight flag and the streaming pin recovers,
  5. the coalesced pin no longer lands mid-flight,
  6. the streaming pin (animated: false) is still a single instant write,
  7. a list shorter than the viewport cannot leave a stuck flag,
  8. Reduce Motion policy (instant jump),
  9. content that grew during the flight re-aligns to the true bottom,
 10. the in-flight flag cannot outlive the animation without a terminal callback.

Prints `SCROLL_BOTTOM_UIKIT_PASS checks=<n>` on success.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/scroll-bottom'
out.mkdir(parents=True, exist_ok=True)
app = out / 'ScrollBottom.app'
app.mkdir(exist_ok=True)
tests = root / 'scripts/scroll-bottom-tests'
coord = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator'
scroll_path = coord / 'MessageListV3Coordinator+Scroll.swift'
delegate_path = coord / 'MessageListV3Coordinator+ScrollViewDelegate.swift'
streaming_path = coord / 'MessageListV3Coordinator+Streaming.swift'
setup_path = coord / 'MessageListV3Coordinator+Setup.swift'
snapshot_path = coord / 'MessageListV3Coordinator+Snapshot.swift'
bindings_path = coord / 'MessageListV3Coordinator+Bindings.swift'
storage_path = coord / 'MessageListV3Coordinator.swift'
support_path = root / 'src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/ComposerShrinkAbsorption.swift'

failures = []


def note(msg):
    print(msg, flush=True)


def need(cond, msg):
    if cond:
        note('SOURCE_CHECK_OK: ' + msg)
    else:
        failures.append(msg)
        note('SOURCE_CHECK_FAIL: ' + msg)


def slice_between(text, start, end, label):
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'extraction failed: start marker not found ({label})')
    if end is None:
        j = text.rindex('\n}')
    else:
        j = text.find(end, i + len(start))
        if j < 0:
            raise SystemExit(f'extraction failed: end marker not found ({label})')
    block = text[i:j]
    if len(block.splitlines()) < 3:
        raise SystemExit(f'extraction failed: slice too short ({label})')
    return block


def production_block():
    """Production scroll methods, verbatim, wrapped in the fixture coordinator."""
    scroll = scroll_path.read_text()
    parts = [
        slice_between(scroll, '        func isNearBottom() -> Bool {',
                      '        func scrollToLastItem(', 'isNearBottom group'),
        slice_between(scroll, '        static func nbDump(_ cv: UICollectionView?) -> String {',
                      '        /// Base contentInset.top', 'nbDump'),
        slice_between(scroll, '        func bottomRestingOffset(_ cv: UIScrollView, bottomInsetBase: CGFloat) -> CGFloat? {',
                      '        /// When content overflows the visible area but is still smaller', 'bottomRestingOffset'),
        slice_between(scroll, '        @discardableResult\n        func applySubViewportCompensation(',
                      '        // MARK: - Composer shrink absorption', 'applySubViewportCompensation'),
        slice_between(scroll, '        func absorbPendingComposerShrink(caller: String) {',
                      '        /// The composer reported a new height.', 'absorbPendingComposerShrink'),
        slice_between(scroll, '        static func animatesJumpToBottom(',
                      '        /// Push the current near-bottom', 'animatesJumpToBottom + scrollToBottomNow'),
        slice_between(scroll, '        func syncScrollFlags() {', None, 'syncScrollFlags'),
        slice_between(streaming_path.read_text(), '        func scheduleCoalescedScroll() {', None,
                      'scheduleCoalescedScroll'),
        slice_between(delegate_path.read_text(), '        func scrollViewWillBeginDragging(',
                      '        func scrollViewWillEndDragging(', 'scrollViewWillBeginDragging'),
        slice_between(delegate_path.read_text(), '        func scrollViewDidEndScrollingAnimation(',
                      '        func scrollViewDidScrollToTop(', 'scrollViewDidEndScrollingAnimation'),
    ]
    for required in ('func scrollToBottomNow(animated: Bool = false)',
                     'if animate && abs(cv.contentOffset.y - target) > 0.5',
                     '!isAnimatingScrollToBottom'):
        if required not in ''.join(parts):
            raise SystemExit('production block lost a required line: ' + required)
    wrapped = ('import Foundation\nimport UIKit\n\n'
               'extension CollectionViewMessageListV3.Coordinator {\n'
               + '\n'.join(parts) + '\n}\n')
    path = out / 'ScrollCoordinatorProduction.swift'
    path.write_text(wrapped)
    note('PRODUCTION_BLOCK_LINES ' + str(wrapped.count('\n') + 1))
    return path


def source_checks():
    scroll = scroll_path.read_text()
    delegate = delegate_path.read_text()
    streaming = streaming_path.read_text()
    setup = setup_path.read_text()
    snapshot = snapshot_path.read_text()
    bindings = bindings_path.read_text()
    storage = storage_path.read_text()

    # The pin that used to pre-empt the animation, and the dead `if` around the
    # compensation pass, are gone.
    need('if applySubViewportCompensation(caller: "scrollToBottom") {' not in scroll,
         'scrollToBottomNow no longer early-returns on the compensation pass')
    need('if scrollMode == .autoScrolling, !isAnimatingScrollToBottom,\n               let target = bottomRestingOffset(' in scroll,
         'the compensation pin is skipped while a jump animation owns the offset')
    need('isAnimatingScrollToBottom = true\n                // Safety net' in scroll,
         'the jump claims the flag BEFORE the compensation pass')
    need('Self.animatesJumpToBottom(animated: animated,' in scroll,
         'Reduce Motion is routed through the pure policy function')
    need('UIAccessibility.isReduceMotionEnabled' in scroll, 'the policy reads the real Reduce Motion flag')
    need('if self.isAnimatingScrollToBottom { self.scheduleCoalescedScroll(); return }' in streaming,
         'the coalesced pin re-arms instead of landing mid-flight')
    need('!cv.isDecelerating && !self.isAnimatingScrollToBottom' in setup,
         'the KVO shrink clamp is skipped while the jump animation is in flight')
    need('if isAnimatingScrollToBottom {\n                        scheduleCoalescedScroll()' in snapshot,
         'the snapshot pin defers to the coalesced scroll while the jump is in flight')
    need('isAnimatingScrollToBottom = false\n            scrollBottomRealigns = 0' in delegate,
         'a user drag clears the in-flight flag and the re-align budget')
    need('[bottomJumpRealign]' in delegate and 'scrollBottomRealigns < 2' in delegate,
         'the terminal delegate re-aligns to the true bottom, bounded')
    need('self.scrollBottomRealigns = 0' in bindings,
         'a fresh manual jump resets the re-align budget')
    need('var scrollBottomJumpToken = 0' in storage and 'var scrollBottomRealigns = 0' in storage,
         'the token + re-align budget live in the coordinator stored-state seam')
    need('scrollToBottomSignal' in bindings and 'self.scrollToBottomNow()' in bindings,
         'streaming follow still uses the instant path (unchanged)')

    # The button itself must keep posting the force signal — no SwiftUI animation
    # was ever involved in the scroll, so none may be added around it.
    area = (root / 'src/ios/Views/Chat/AIChatView/AIChatView+MessagesArea.swift').read_text()
    need('vm.forceScrollToBottom.send()' in area, 'the down-arrow button still posts forceScrollToBottom')
    need('withAnimation' not in area.split('scrollFloatingButtonLabel("chevron.down")')[0].split('// Scroll to bottom')[-1],
         'the down-arrow action is not wrapped in withAnimation (it never was; the scroll is UIKit)')

    # The existing standalone source contract must still hold.
    composer = (root / 'src/ios/MinisTests/Standalone/ComposerShrinkAbsorptionTests.swift').read_text()
    need('applySubViewportCompensation(caller: \\"scrollToBottom\\")"' in composer,
         'the composer-shrink contract tracks the unwrapped compensation call')

    if failures:
        raise SystemExit('source checks failed: ' + '; '.join(failures))


def syntax_gate(files):
    bad = 0
    for f in files:
        r = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', str(f)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.returncode != 0:
            bad += 1
            note(f'SYNTAX_FAIL {f.name}')
            note(r.stdout[-4000:])
        else:
            note(f'SYNTAX_OK {f.name}')
    return bad


def main():
    prod = production_block()
    source_checks()

    gate = [prod, tests / 'ScrollFixture.swift', tests / 'ScrollBottomTests.swift', tests / 'main.swift',
            scroll_path, delegate_path, streaming_path, setup_path, snapshot_path, bindings_path, storage_path]
    if syntax_gate(gate):
        raise SystemExit('swiftc -frontend -parse failed')

    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    choices = [d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
    if not choices:
        raise SystemExit('No iPhone simulator available')
    d = next((d for d in choices if d['state'] == 'Booted'), choices[0])
    uid = d['udid']
    if d['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', uid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', uid, '-b'], check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()

    sources = [prod, support_path, tests / 'ScrollFixture.swift', tests / 'ScrollBottomTests.swift',
               tests / 'main.swift']
    cmd = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-target', f'{arch}-apple-ios16.0-simulator', '-o', str(app / 'ScrollBottom')]
    cmd += [str(s) for s in sources]
    note('COMPILE ' + ' '.join(cmd))
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / 'compile.log').write_text(r.stdout)
    note(r.stdout[-20000:])
    if r.returncode != 0:
        raise SystemExit('swiftc failed — see build/scroll-bottom/compile.log')

    info = {'CFBundleIdentifier': 'com.gonepaul.scroll.bottom',
            'CFBundleExecutable': 'ScrollBottom', 'CFBundleName': 'ScrollBottom',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
            'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
            'UILaunchScreen': {}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', uid, str(app)], check=True)
    run = subprocess.run(['xcrun', 'simctl', 'launch', '--console', uid, info['CFBundleIdentifier']],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=420)
    print(run.stdout, flush=True)
    (out / 'results.log').write_text(run.stdout)
    note('LAUNCH_RETURN_CODE ' + str(run.returncode))

    if 'SCROLL_BOTTOM_UIKIT_PASS' not in run.stdout:
        try:
            log = subprocess.run(['xcrun', 'simctl', 'spawn', uid, 'log', 'show', '--style', 'compact',
                                  '--last', '2m', '--predicate', 'process == "ScrollBottom"'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            (out / 'diagnostic.log').write_text(log.stdout)
        except subprocess.TimeoutExpired:
            (out / 'diagnostic.log').write_text('log show timed out')
        raise SystemExit('scroll-to-bottom UI regression failed (see build/scroll-bottom/)')

    note('SCROLL_BOTTOM_REGRESSION_OK')


if __name__ == '__main__':
    main()
