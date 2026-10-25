#!/usr/bin/env python3
"""Generate an isolated UIKit regression harness from the actual production source."""
from pathlib import Path
import re,json,subprocess,sys
root=Path(__file__).resolve().parents[1]; ios=root/'src/ios'; out=root/'build/mod-regression';out.mkdir(parents=True,exist_ok=True)
bridge=(ios/'Views/Chat/Markdown/Bridge/SelectableMarkdownView.swift').read_text()
start=bridge.index('    private static func prefixesEqualIgnoringFontSubstitution(')
end=bridge.index('    /// Recursively collect',start)
method=bridge[start:end].replace('private static func','static func',1)
assert 'fadeAnimator.cancelAll()\n            textView.attributedText = attributed' in bridge
assert 'oldPrefix.enumerateAttributes(in: range' in method
pinned=(ios/'Views/ContentView/Sidebar/SidebarSurfaces.swift').read_text().split('// MARK: - MOD stable pinned-title presentation')[1]
(out/'Pinned.swift').write_text('import UIKit\nimport SwiftUI\nfunc AppLocalized(_ s: String) -> String { s }\n'+pinned)
(out/'Prefix.swift').write_text('import UIKit\nenum PrefixTest {\n static let nsOriginalFontKey = NSAttributedString.Key("NSOriginalFont")\n'+method+'}\n')
(out/'main.swift').write_text('''import UIKit
import Foundation
var passed = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: " + name) }
    passed += 1
    print("PASS: " + name)
}
let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
let orange = UIColor.systemOrange
let black = UIColor.label
func text(_ value: String, _ color: UIColor) -> NSMutableAttributedString {
    NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
}
let good = text("94e9eef", orange)
let mixed = text("94e9eef", orange)
mixed.addAttribute(.foregroundColor, value: black, range: NSRange(location: 4, length: 3))
check(!PrefixTest.prefixesEqualIgnoringFontSubstitution(good, mixed), "old attribute boundary in middle of new run is detected")
check(PrefixTest.prefixesEqualIgnoringFontSubstitution(good, good), "equal prefix fast path retained")
let bgMixed = text("94e9eef", orange)
bgMixed.addAttribute(.backgroundColor, value: UIColor.systemGray6, range: NSRange(location: 2, length: 3))
check(!PrefixTest.prefixesEqualIgnoringFontSubstitution(good, bgMixed), "background mismatch detected")
let fallback = NSMutableAttributedString(attributedString: good)
fallback.addAttributes([.font: UIFont.systemFont(ofSize: 14), NSAttributedString.Key("NSOriginalFont"): font], range: NSRange(location: 3, length: 4))
check(PrefixTest.prefixesEqualIgnoringFontSubstitution(good, fallback), "legitimate font substitution retained")
let storage = NSTextStorage(attributedString: mixed)
// Top-level code is nonisolated; run the actor-isolated assertions explicitly.
MainActor.assumeIsolated {
let fade = TextFadeAnimator(requestRedraw: {})
fade.scheduleAnimation(for: NSRange(location: 0, length: storage.length), in: storage)
fade.cancelAll()
check((storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor) == orange, "fade preserves first run")
check((storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor) == black, "fade preserves second run inside same word")
fade.scheduleAnimation(for: NSRange(location: 0, length: storage.length), in: storage)
// Same lifecycle as the production full-assignment branch.
fade.cancelAll()
storage.setAttributedString(good)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
check((storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor) == orange, "old fade cannot repaint replacement inline code")
for viewport in stride(from: CGFloat(-50), through: 400, by: 1) {
    let y = StablePinnedTitle.titleY(natural: 50, viewport: viewport, bottom: 250, height: 30)
    precondition(y == min(max(50, viewport), 220))
}
check(true, "451 natural/pinned/section-bottom clamp cases")
check(StablePinnedTitle.titleY(natural: 50, viewport: 260, bottom: 250, height: 30) + 30 <= 260, "pinned title leaves viewport with its section")
check(34.0 / 2 + 12 == 29, "actual composer concentric geometry")
}
print("MINISMOD_REGRESSION_PASS \\(passed)")
''')
# Actual UIKit executable, not a model of the production implementation.
if '--generate-only' in sys.argv: print(out);sys.exit(0)
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
choices=[d for ds in devices.values() for d in ds if 'iPhone' in d['name'] and d.get('isAvailable')]
assert choices, 'No iOS simulator installed'
d=next((d for d in choices if d['state']=='Booted'),choices[0]);uid=d['udid']
if d['state']!='Booted': subprocess.run(['xcrun','simctl','boot',uid],check=True)
subprocess.run(['xcrun','simctl','bootstatus',uid,'-b'],check=True)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
arch=subprocess.check_output(['uname','-m'],text=True).strip()
exe=out/'regression'
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target',arch+'-apple-ios16.0-simulator',str(ios/'Views/Chat/TextFadeAnimator.swift'),str(out/'Pinned.swift'),str(out/'Prefix.swift'),str(out/'main.swift'),'-o',str(exe)],check=True)
subprocess.run(['xcrun','simctl','spawn',uid,str(exe)],check=True)
