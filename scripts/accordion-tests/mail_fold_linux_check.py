#!/usr/bin/env python3
"""Run the iOS 16 Mail fold geometry on Swift/Linux.

`scripts/accordion-tests/MailFoldTests.swift` needs a simulator. This script
compiles the SHIPPING `enum AccordionMemberFold` block straight out of
`src/ios/Views/ContentView/Sidebar/AccordionCollectionLayout.swift` (not a
copy) together with the harness in this directory, then checks the source
contracts the geometry depends on (header-clipped cell, reduce motion, the
0.25 s / 60 Hz display link, date-bucket path).

usage: python3 scripts/accordion-tests/mail_fold_linux_check.py [--swiftc swiftc]
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sidebar = root / 'src' / 'ios' / 'Views' / 'ContentView' / 'Sidebar'
layout_path = sidebar / 'AccordionCollectionLayout.swift'
list_path = sidebar / 'NativeAccordionList.swift'
harness_path = Path(__file__).resolve().parent / 'MailFoldMathHarness.swift'
out = root / 'build' / 'mail-fold-linux'
out.mkdir(parents=True, exist_ok=True)

layout = layout_path.read_text()
start = layout.index('enum AccordionMemberFold {')
end = layout.index('// END AccordionMemberFold', start)
block = layout[start:end]
checklist = layout[layout.index('final class AccordionRowAttributes: UICollectionViewLayoutAttributes {'):]
checklist = checklist[:checklist.index('\n}\n') + 3]
list_source = list_path.read_text()

assert 'UIKit' in layout, 'layout still imports UIKit (this block must not)'
for forbidden in ('import UIKit', 'UIView', 'UIBezierPath'):
    assert forbidden not in block, f'pure geometry block must not mention {forbidden!r}'

# --- source contracts the runtime geometry depends on ----------------------
assert 'AccordionRowAttributes(forCellWith: indexPath)' in layout, 'member attributes must carry the fold clip'
assert 'a.clipTop = slice.clipTop' in layout, 'member cell must receive the covered top'
assert 'a.frame = CGRect(x: 0, y: slice.y, width: width, height: slice.height)' in layout, \
    'member frame must be the visible slice'
assert 'AccordionMemberFold.rowBounds(in: rect' in layout, 'enumeration must be bounded by the window'
assert 'y += s.labelHeight + s.headerHeight + s.fullHeight * p + s.footerHeight' in layout, \
    'section height contribution must stay label + header + rows*p + footer'
assert 'clipTop' in checklist and 'AccordionRowAttributes' in checklist, 'attributes subclass must copy its clip'
# The cell keeps the row's FULL frame and only translates it.
assert 'host?.view.frame = CGRect(x: 0, y: -clipTop, width: bounds.width, height: fullHeight)' in list_source, \
    'clipped row must translate its full-height content, never squeeze it'
assert 'let next = (layoutAttributes as? AccordionRowAttributes)?.clipTop ?? 0' in list_source, \
    'cell must read the clip from the layout attributes'
# Motion, anchoring and reduce motion are untouched by this change.
assert 'let duration: CFTimeInterval = 0.25' in list_source, '0.25 s fold duration unchanged'
assert 'CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)' in list_source, '60 Hz display link unchanged'
assert '!UIAccessibility.isReduceMotionEnabled' in list_source, 'reduce motion still bypasses the animation'
assert 'AccordionMotion.translation(startHeader: anchorStartY' in list_source, 'anchor translation unchanged'
assert 'dateBucketFoldChanged("Pinned"' in list_source and 'dateBucketFoldChanged("Recent"' in list_source, \
    'pinned / recent still fold through beginMotion'
assert 'case .member' in list_source and 'cell.accessibilityElementsHidden = link != nil' in list_source, \
    'hit handling / accessibility during motion unchanged'

# --- compile the shipping geometry on Linux --------------------------------
harness = harness_path.read_text()
(out / 'main.swift').write_text('import Foundation\n' + block + '\n' + harness)
swiftc = sys.argv[sys.argv.index('--swiftc') + 1] if '--swiftc' in sys.argv else 'swiftc'
build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(out / 't'), str(out / 'main.swift')],
                       capture_output=True, text=True)
if build.returncode != 0:
    print('COMPILE FAILED')
    print(build.stderr[:4000])
    sys.exit(1)
print('COMPILE OK')
run = subprocess.run([str(out / 't')], capture_output=True, text=True)
print(run.stdout[-2000:])
if run.returncode != 0:
    print('RUN FAILED')
    print(run.stderr[-2000:])
    sys.exit(1)
m = re.search(r'MAILFOLD_MATH_PASS (\d+)', run.stdout)
assert m, 'harness did not report a pass count'
print(f'MAIL_FOLD_LINUX_PASS checks={m.group(1)}')
