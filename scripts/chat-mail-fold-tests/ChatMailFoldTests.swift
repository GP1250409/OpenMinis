// [T-chat-mail-fold] Geometry of the mail-style chat fold, run against the
// SHIPPING block (`ChatMailFold.swift`, between its BEGIN/END markers).
//
// Standalone on Linux: `swift scripts/chat-mail-fold-tests/ChatMailFoldTests.swift`
// (also driven by scripts/chat_mail_fold_regression.py, which compiles the same
// block with swiftc and checks every printed value).
import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let src = try String(contentsOf: root.appendingPathComponent(
    "src/ios/Agent/MessageList/CollectionViewMessageListV3/Support/ChatMailFold.swift"), encoding: .utf8)
guard let b = src.range(of: "// === BEGIN ChatMailFold ==="),
      let e = src.range(of: "// === END ChatMailFold ===") else { fatalError("markers missing") }
let block = String(src[b.upperBound..<e.lowerBound])

let harness = #"""
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "ok" : "FAIL") name=\(name) \(detail)")
    if !ok { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }
func fmt(_ v: [CGFloat]) -> String { v.map { String(format: "%.3f", Double($0)) }.joined(separator: ",") }

// 1. Total block height: children + INTERNAL gaps only.
check("total-3x100-gap8", near(ChatMailFold.totalHeight(natural: [100, 100, 100], rowSpacing: 8), 316))
check("total-1x100", near(ChatMailFold.totalHeight(natural: [100], rowSpacing: 8), 100))
check("total-empty", near(ChatMailFold.totalHeight(natural: [], rowSpacing: 8), 0))

// 2. Collapsed: nothing visible, everything hidden, no top clip.
let c0 = ChatMailFold.rows(natural: [100, 100, 100], rowSpacing: 8, reveal: 0)
check("collapse-heights", fmt(c0.map { $0.visible }) == "0.000,0.000,0.000", fmt(c0.map { $0.visible }))
check("collapse-hidden", c0.allSatisfy { $0.isHidden })
// Fully hidden rows are not drawn and report no clip.
check("collapse-topclip", c0.allSatisfy { near($0.topClip, 0) })

// 3. Expanded: the whole block, no clip.
let c1 = ChatMailFold.rows(natural: [100, 100, 100], rowSpacing: 8, reveal: 1)
check("expand-heights", fmt(c1.map { $0.visible }) == "108.000,108.000,100.000", fmt(c1.map { $0.visible }))
check("expand-topclip", c1.allSatisfy { near($0.topClip, 0) })
check("expand-sum", near(c1.map { $0.visible }.reduce(0, +), 316))

// 4. MAIL ORDER: at a small reveal the LAST child is the one that shows.
let q = ChatMailFold.rows(natural: [100, 100, 100], rowSpacing: 8, reveal: 0.25)
// 0.25 * 316 = 79 → only the LAST child shows, its bottom 79 of 100.
check("quarter-heights", fmt(q.map { $0.visible }) == "0.000,0.000,79.000", fmt(q.map { $0.visible }))
check("quarter-last-visible", q[2].visible > 0 && q[0].isHidden && q[1].isHidden)
check("quarter-straddle-is-last", ChatMailFold.clippedRow(natural: [100, 100, 100], rowSpacing: 8, reveal: 0.25) == 2)
// The straddling child shows its BOTTOM 79 of 100: 21 hidden above the window.
check("quarter-topclip", fmt(q.map { $0.topClip }) == "0.000,0.000,21.000", fmt(q.map { $0.topClip }))
check("quarter-content-visible", fmt(q.map { $0.contentVisible }) == "0.000,0.000,79.000", fmt(q.map { $0.contentVisible }))
// FIRST child appears LAST / disappears FIRST (the opposite of a curtain).
check("quarter-first-hidden", q[0].isHidden)
check("three-quarter-first-partial", ChatMailFold.rows(natural: [100, 100, 100], rowSpacing: 8, reveal: 0.8)[0].visible > 0)

// 5. Σ visible == total * reveal at every step: the bottom edge (and every row
//    after it) moves by exactly the revealed amount — no end-of-flight pop.
var sumOK = true
for step in 0...100 {
    let r = CGFloat(step) / 100
    let sum = ChatMailFold.rows(natural: [120, 40, 210], rowSpacing: 8, reveal: r).map { $0.visible }.reduce(0, +)
    // 120 + 40 + 210 + 2 * 8 = 386
    if !near(sum, 386 * r, 0.01) { sumOK = false }
}
check("sum-linear", sumOK)
// No row is ever taller than its slot, and no content is shown twice.
var boundsOK = true
for step in 0...100 {
    let r = CGFloat(step) / 100
    let rows = ChatMailFold.rows(natural: [120, 40, 210], rowSpacing: 8, reveal: r)
    if rows[0].visible > 128.01 || rows[1].visible > 48.01 || rows[2].visible > 210.01 { boundsOK = false }
    if rows[0].topClip + rows[0].contentVisible > 120.01 { boundsOK = false }
}
check("row-bounds", boundsOK)

// 6. Single child (a one-row block): the same top-clipped sliding window,
//    content never scaled — half open shows the bottom half of the text.
let one = ChatMailFold.rows(natural: [200], rowSpacing: 8, reveal: 0.5)
check("single-visible", fmt(one.map { $0.visible }) == "100.000", fmt(one.map { $0.visible }))
check("single-topclip", fmt(one.map { $0.topClip }) == "100.000", fmt(one.map { $0.topClip }))
check("single-content-visible", fmt(one.map { $0.contentVisible }) == "100.000", fmt(one.map { $0.contentVisible }))
check("single-full", near(ChatMailFold.rows(natural: [200], rowSpacing: 8, reveal: 1)[0].visible, 200))

// 7. Reduce motion / zero duration: progress is 1 at once, no frames.
check("progress-zero-duration", near(ChatMailFold.progress(elapsed: 0, duration: 0), 1))
check("progress-clamped", near(ChatMailFold.progress(elapsed: 0, duration: 0.32), 0) &&
      near(ChatMailFold.progress(elapsed: 0.32, duration: 0.32), 1))
check("ease-endpoints", near(ChatMailFold.ease(0), 0) && near(ChatMailFold.ease(1), 1) && near(ChatMailFold.ease(0.5), 0.5))

// 8. Scroll clamp: the fixed header's anchor, and the legal window.
check("anchor-hold", near(ChatMailFold.anchoredOffset(headerY: 300, anchorY: 120, contentHeight: 2000,
                                                      viewportHeight: 800, topInset: 0, bottomInset: 0), 180))
check("anchor-clamp-bottom", near(ChatMailFold.anchoredOffset(headerY: 300, anchorY: 120, contentHeight: 850,
                                                              viewportHeight: 800, topInset: 0, bottomInset: 0), 50))
check("clamp-short-content", near(ChatMailFold.clampedOffset(900, contentHeight: 300, viewportHeight: 800,
                                                             topInset: 0, bottomInset: 0), 0))
check("terminal-expand", near(ChatMailFold.terminalReveal(expanding: true), 1) &&
      near(ChatMailFold.terminalReveal(expanding: false), 0))
if failures > 0 { print("FAILURES=\(failures)"); exit(1) }
"""#

let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chatmailfold-main.swift")
try ("import Foundation\n" + block + "\n" + harness).write(to: out, atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swiftc", "-swift-version", "5", "-o", NSTemporaryDirectory() + "chatmailfold", out.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("compile failed") }
let r = Process()
r.executableURL = URL(fileURLWithPath: NSTemporaryDirectory() + "chatmailfold")
try r.run(); r.waitUntilExit()
exit(r.terminationStatus)
