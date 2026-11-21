#!/usr/bin/env swift
// [T-user-ask-toggle-drift] Tapping an answered user_ask card open / shut must
// keep the card's top where it is and only move its bottom.
//
// Field report (screen recording, 60 fps): every expand grew the card UPWARD
// (content below stayed, measured -6pt) and every collapse kept its top fixed
// (content below jumped up, measured -142pt), so each expand/collapse pair
// moved the whole list up by the card's height change. Root cause: after the
// toggle cleared the height caches, the shrink to the estimate landed in
// prepare() with no offset change, while the growth back to the real height
// took MessageListLayout's visible-cell contentOffsetAdjustment (+delta).
//
//   [1] anchoredOffset / revealShift / skipsVisibleCompensation (shipping code,
//       compiled standalone from MessageListLayout.swift)
//   [2] a simulated list: N expand/collapse cycles, old rules vs new rules
//   [3] source guards: layout skip, Coordinator anchored path, card opt-in
//
// Run: swift ToggleAnchorMathTests.swift   (needs swiftc)
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let layoutSrc = source("Agent/MessageList/MessageListLayout.swift")
guard let b = layoutSrc.range(of: "// BEGIN ToggleAnchorMath"),
      let e = layoutSrc.range(of: "// END ToggleAnchorMath") else {
    print("❌ ToggleAnchorMath block not found"); exit(1)
}
let block = "import Foundation\nimport CoreGraphics\n" + layoutSrc[b.upperBound..<e.lowerBound]

let harness = #"""
import Foundation
import CoreGraphics
var out: [String] = []
func R(_ k: String, _ v: Any) { out.append("R \(k)=\(v)") }
func f(_ x: CGFloat) -> String { String(format: "%.1f", Double(x)) }

// --- [1] pure functions
// The cell's top was 120pt below the viewport top; after re-measure it sits
// at content y 900 → offset 780 puts it back at 120.
R("anchorBasic", f(ToggleAnchorMath.anchoredOffset(newMinY: 900, anchorY: 120, minOffset: -100, maxOffset: 5000)))
R("anchorClampMax", f(ToggleAnchorMath.anchoredOffset(newMinY: 900, anchorY: 120, minOffset: -100, maxOffset: 600)))
R("anchorClampMin", f(ToggleAnchorMath.anchoredOffset(newMinY: 50, anchorY: 400, minOffset: -100, maxOffset: 5000)))
// Content shorter than the viewport: maxOffset < minOffset must not invert the clamp.
R("anchorShortContent", f(ToggleAnchorMath.anchoredOffset(newMinY: 300, anchorY: 120, minOffset: -100, maxOffset: -300)))

// Visible band 100...700 (content coordinates).
R("revealFits", f(ToggleAnchorMath.revealShift(cellMinY: 400, cellMaxY: 650, visibleTop: 100, visibleBottom: 700)))
R("revealOverflow", f(ToggleAnchorMath.revealShift(cellMinY: 500, cellMaxY: 760, visibleTop: 100, visibleBottom: 700)))
// Taller than the viewport: stop when the top reaches the visible top + margin.
R("revealCappedByTop", f(ToggleAnchorMath.revealShift(cellMinY: 300, cellMaxY: 1400, visibleTop: 100, visibleBottom: 700)))
// Top already at the edge: no room, no scroll.
R("revealNoRoom", f(ToggleAnchorMath.revealShift(cellMinY: 105, cellMaxY: 900, visibleTop: 100, visibleBottom: 700)))

R("skipSame", ToggleAnchorMath.skipsVisibleCompensation(index: 7, anchored: 7))
R("skipOther", ToggleAnchorMath.skipsVisibleCompensation(index: 8, anchored: 7))
R("skipNone", ToggleAnchorMath.skipsVisibleCompensation(index: 7, anchored: nil))
R("key", ToggleAnchorMath.anchorTopKey)
// [T-user-ask-pixel-align] measured heights snap to the device pixel grid
R("pxWhole", f(ToggleAnchorMath.pixelAligned(58, scale: 3)))
R("pxLow", f(ToggleAnchorMath.pixelAligned(58.1, scale: 3)))
R("pxHigh", f(ToggleAnchorMath.pixelAligned(58.4, scale: 3)))
R("pxHalf", f(ToggleAnchorMath.pixelAligned(58.5, scale: 3)))
R("pxZero", f(ToggleAnchorMath.pixelAligned(0, scale: 3)))
R("pxNoScale", f(ToggleAnchorMath.pixelAligned(58.4, scale: 0)))
// [T-user-ask-expand-anim] duration, Reduce Motion, one-shot request
R("dur", ToggleAnchorMath.animationDuration)
R("durRM", ToggleAnchorMath.animationDuration(reduceMotion: true).map { "\($0)" } ?? "nil")
R("durNormal", ToggleAnchorMath.animationDuration(reduceMotion: false).map { "\($0)" } ?? "nil")
var flips = 0
let req = ToggleRequest { flips += 1 }
let first = req.run(), second = req.run()
R("requestOnce", "\(first)|\(second)|\(flips)|\(req.hasRun)")

// --- [2] simulated list
// Items above the card are fixed; the card starts at content y `cardY`.
// Collapsed 58.5pt, expanded 182pt (the device measurement), estimate 52pt.
struct Sim {
    var offset: CGFloat = 1000
    let cardY: CGFloat = 1200          // card top in content coordinates
    let viewport: CGFloat = 896, insetTop: CGFloat = 100, insetBottom: CGFloat = 180
    var below: CGFloat = 900            // content under the card
    var h: CGFloat = 58.5
    var contentHeight: CGFloat { cardY + h + below }
    var maxOffset: CGFloat { contentHeight - viewport + insetBottom }
    var cardOnScreen: CGFloat { cardY - offset }
}
// Old rules: shrink to the estimate uncompensated, then the growth from the
// estimate compensated as a visible-cell resize (offset += delta).
func oldToggle(_ s: inout Sim, to newH: CGFloat) {
    let est: CGFloat = 52
    s.h = est                              // prepare(): no offset change
    let delta = newH - est
    s.h = newH
    s.offset += delta                      // visible-cell contentOffsetAdjustment
}
// New rules: whatever the layout did, put the top back where it was.
func newToggle(_ s: inout Sim, to newH: CGFloat) {
    let anchorY = s.cardY - s.offset
    oldToggle(&s, to: newH)                // same layout passes
    s.offset = ToggleAnchorMath.anchoredOffset(newMinY: s.cardY, anchorY: anchorY,
                                               minOffset: -s.insetTop, maxOffset: s.maxOffset)
}
var old = Sim(), new = Sim()
var oldTops: [String] = [], newTops: [String] = []
for i in 0..<6 {
    let target: CGFloat = i % 2 == 0 ? 182 : 58.5
    oldToggle(&old, to: target); oldTops.append(f(old.cardOnScreen))
    newToggle(&new, to: target); newTops.append(f(new.cardOnScreen))
}
R("oldTops", oldTops.joined(separator: ","))
R("newTops", newTops.joined(separator: ","))
R("newStart", f(Sim().cardOnScreen))

// Pinned at the very bottom: collapsing near the end may have to clamp, but
// expanding again must not drift past the starting top either.
var pinned = Sim(); pinned.below = 40; pinned.offset = pinned.maxOffset
let pinnedStart = pinned.cardOnScreen
var pinnedTops: [CGFloat] = []
for i in 0..<6 { newToggle(&pinned, to: i % 2 == 0 ? 182 : 58.5); pinnedTops.append(pinned.cardOnScreen) }
R("pinnedNeverAboveStart", pinnedTops.allSatisfy { $0 >= pinnedStart - 0.5 })
R("pinnedStable", Set(pinnedTops.map(f)).count <= 2)
print(out.joined(separator: "\n"))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-anchor-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
#if os(Linux)
// No CoreGraphics module on Linux; CGFloat comes from Foundation.
let blockForPlatform = block.replacingOccurrences(of: "import CoreGraphics\n", with: "")
#else
let blockForPlatform = block
#endif
let files = [("ToggleAnchorMath.swift", blockForPlatform), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
/// [T-standalone-no-macos] `xcrun` only exists on macOS. The block under test is
/// pure Swift + CGFloat (no UIKit), so a plain `swiftc` runs it on Linux too -
/// which is where this repo is edited, and why the file had been dead weight.
func swiftcCommand() -> [String] {
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") { return ["/usr/bin/xcrun", "swiftc"] }
    for candidate in ["/usr/local/bin/swiftc", "/usr/bin/swiftc"]
    where FileManager.default.isExecutableFile(atPath: candidate) { return [candidate] }
    return ["/usr/bin/env", "swiftc"]
}
let compiler = swiftcCommand()
let (cc, ccOut) = run(compiler[0], Array(compiler.dropFirst()) + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping ToggleAnchorMath compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
if rc != 0 { print(out) }
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. Pure geometry")
check("anchoredOffset puts the top back (900 - 120 = 780)", r["anchorBasic"] == "780.0")
check("anchoredOffset clamps to the max offset", r["anchorClampMax"] == "600.0")
check("anchoredOffset clamps to the min offset", r["anchorClampMin"] == "-100.0")
check("short content: max below min does not invert the clamp", r["anchorShortContent"] == "-100.0")
check("reveal: bottom already visible → no scroll", r["revealFits"] == "0.0")
check("reveal: scrolls exactly the overflow + margin (760+8-700 = 68)", r["revealOverflow"] == "68.0")
check("reveal: a cell taller than the viewport stops at its top (300-108 = 192)", r["revealCappedByTop"] == "192.0")
check("reveal: top at the edge → no room → no scroll", r["revealNoRoom"] == "0.0")
check("layout skips compensation only for the anchored index",
      r["skipSame"] == "true" && r["skipOther"] == "false" && r["skipNone"] == "false")
check("notification key is stable", r["key"] == "anchorTop")
// [T-user-ask-pixel-align] 58.1 → 174.3 → 174 → 58.0; 58.4 → 175.2 → 175 →
// 58.333; 58.5 → 175.5 → 176 → 58.667; degenerate inputs pass through.
check("pixel align: whole height unchanged", r["pxWhole"] == "58.0")
check("pixel align: 58.1 snaps down to the 1/3 pt grid", r["pxLow"] == "58.0")
check("pixel align: 58.4 snaps to 58.333", r["pxHigh"] == "58.3")
check("pixel align: 58.5 snaps up to 58.667", r["pxHalf"] == "58.7")
check("pixel align: zero height passes through", r["pxZero"] == "0.0")
check("pixel align: a non-positive scale is ignored", r["pxNoScale"] == "58.4")

print("\n2. Simulated expand/collapse cycles")
let start = r["newStart"] ?? "?"
let newTops = (r["newTops"] ?? "").split(separator: ",").map(String.init)
let oldTops = (r["oldTops"] ?? "").split(separator: ",").map(String.init)
check("new rules: card top never moves over 6 toggles (\(start))", newTops.count == 6 && newTops.allSatisfy { $0 == start })
check("old rules reproduce the field drift (top keeps moving up)",
      oldTops.count == 6 && Double(oldTops.last!)! < Double(start)! - 300)
check("pinned at the bottom: the top never rises above where it started", r["pinnedNeverAboveStart"] == "true")
check("pinned at the bottom: no accumulating drift (≤2 distinct positions)", r["pinnedStable"] == "true")

print("\n2b. Animation constants")
check("0.2 s", r["dur"] == "0.2" && r["durNormal"] == "0.2")
check("Reduce Motion → no animation", r["durRM"] == "nil")
check("a toggle request runs exactly once (list and fallback cannot double-toggle)", r["requestOnce"] == "true|false|1|true")

print("\n3. Source guards")
check("layout: visible-cell compensation is skipped for the anchored index",
      layoutSrc.contains("!ToggleAnchorMath.skipsVisibleCompensation(index: index, anchored: topAnchoredIndex)"))
check("layout: topAnchoredIndex is lock-protected (read off-main)",
      layoutSrc.contains("private var _topAnchoredIndex: Int?") && layoutSrc.contains("return _topAnchoredIndex"))
let v3 = messageListV3Source()
check("list: a flagged toggle takes the anchored path, carrying the card's toggle request",
      v3.contains("notification.userInfo?[ToggleAnchorMath.anchorTopKey] as? Bool == true")
      && v3.contains("let request = notification.userInfo?[ToggleAnchorMath.toggleRequestKey] as? ToggleRequest")
      && v3.contains("self.remeasureKeepingTop(item: item, index: i, blockId: blockId, request: request)"))
if let r0 = v3.range(of: "func remeasureKeepingTop("),
   let r1 = v3.range(of: "\n        }\n", range: r0.upperBound..<v3.endIndex) {
    let body = String(v3[r0.upperBound..<r1.lowerBound])
    let browse = body.range(of: "scrollMode = .userBrowsing")
    let measure = body.range(of: "cv.layoutIfNeeded()")
    check("list: browse mode is set BEFORE the re-measure (no bottom re-pin)",
          browse != nil && measure != nil && browse!.lowerBound < measure!.lowerBound)
    // [T-user-ask-anchor-clamp] The top is restored through the pre-clamp plan
    // (cardAnchorPlan), not the legacy bare anchoredOffset call: the clamp has
    // to be predicted BEFORE the destructive layout pass.
    check("list: the top is restored through the pre-clamp card plan",
          body.contains("ToggleAnchorMath.preResizeOffset(") && body.contains("ToggleAnchorMath.cardAnchorPlan("))
    check("list: the reveal only runs when the cell grew", body.contains("if frame.height > oldHeight + 0.5 {"))
    // [T-user-ask-single-pass] One pass, no animation: the height and the
    // offset must never be at different points of their travel (that is the
    // two-stage move the device recording shows).
    check("single-pass: no UIView.animate around the toggle",
          !body.contains("UIView.animate("))
    check("single-pass: the pass is applied exactly once, then finish",
          body.contains("\n            changes()\n            finish()\n"))
    check("single-pass: no reveal scroll after the resize",
          !body.contains("revealShift(") && body.contains("// [T-user-ask-single-pass] No reveal scroll"))
    check("single-pass: the layout pass is not animated",
          body.contains("(cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false\n                cv.layoutIfNeeded()"))
    check("single-pass: the cell's height goes straight to the new measure (no drop to the estimate)",
          body.contains("layout.setMeasuredHeight(fittedHeight, at: i)"))
    check("single-pass: the measured height is snapped to the pixel grid",
          body.contains("fittedHeight = ToggleAnchorMath.pixelAligned(cell.preferredLayoutAttributesFitting(attrs).size.height"))
    // [T-user-ask-expand-overlap] streaming: the measure must see the NEW state
    if let flip = body.range(of: "_ = request?.run()"),
       let conf = body.range(of: "self.configureCell(cell, item: item, indexPath: ip)"),
       let lay = body.range(of: "cell.contentView.layoutIfNeeded()"),
       let meas = body.range(of: "ToggleAnchorMath.pixelAligned(cell.preferredLayoutAttributesFitting(attrs)") {
        check("overlap: flip → fresh hosting config → content layout → measure, in that order",
              flip.lowerBound < conf.lowerBound && conf.lowerBound < lay.lowerBound && lay.lowerBound < meas.lowerBound)
    } else {
        check("overlap: flip / reconfigure / layout / measure sequence present", false)
    }
    // [T-user-ask-anchor-clamp] ...and only when the user is not holding the
    // list: a clamped collapse already sits on the legal bottom.
    check("list: following resumes only when the list ends at the bottom and the user is not holding it",
          body.contains("if !cv.isTracking, !cv.isDecelerating, self.isNearBottom() {\n                    self.scrollMode = .autoScrolling"))
    // [T-user-ask-anchor-token] Released by TOKEN (a bare-index clear could drop
    // a newer tap's anchor), and the token API exists on the layout.
    check("list: the anchor is released by token afterwards",
          body.contains("layout?.endTopAnchor(token: anchorToken)")
          && layoutSrc.contains("func endTopAnchor(token: Int) -> Bool")
          && layoutSrc.contains("func beginTopAnchor(index: Int) -> Int"))
} else {
    check("remeasureKeepingTop found", false)
}
check("thinking: the manual toggle snaps its measured height to the pixel grid too",
      v3.contains("let fitted = ToggleAnchorMath.pixelAligned(cell.preferredLayoutAttributesFitting(attrs).size.height,"))
let card = source("Views/Chat/UserAskCardView.swift")
check("card: the resolved card's tap hands a one-shot request to the list (no direct toggle)",
      card.contains("let request = ToggleRequest { [block] in block.isThinkingExpanded.toggle() }")
      && card.contains("userInfo: [ToggleAnchorMath.anchorTopKey: true,")
      && card.contains("ToggleAnchorMath.toggleRequestKey: request])")
      && card.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { request.run() }"))
check("card: details fade, card pinned to the top of its cell",
      card.contains(".transition(.opacity)") && card.contains(".frame(maxHeight: .infinity, alignment: .top)"))
let infra = source("Agent/MessageList/MessageListInfrastructure.swift")
check("collection view: the one-pass flag bypasses performWithoutAnimation, default off",
      infra.contains("var animatesNextLayoutPass = false")
      && infra.contains("if animatesNextLayoutPass {\n            // [T-user-ask-expand-anim]"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
