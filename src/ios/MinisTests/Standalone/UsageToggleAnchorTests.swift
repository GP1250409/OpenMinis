// Contract tests for [T-usage-toggle-anchor] — the assistant footer's usage
// toggle is the one user gesture that INSERTS or DELETES a row above the
// viewport. Measured on the 2026-11-08 recording: showing the footer paid only
// its 4pt seed estimate (+2..+7pt of content), hiding it dropped the row's real
// ~21pt with no compensation at all, so every show/hide cycle ratcheted the
// transcript upward by 14-21pt (70pt over four cycles in 9.5s).
//
// These checks pin the WIRING (who asks for the anchor, in what order, with what
// clamps). The pixels are the UIKit fixture's job — see
// shared/minismod/usage-toggle-drift-20261108/REPORT.md §"测试".
//
// Standalone: `swift UsageToggleAnchorTests.swift` from this directory.
import Foundation

let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Standalone
    .deletingLastPathComponent()      // MinisTests
    .deletingLastPathComponent()      // ios

func source(_ relative: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

let coordinatorDir = "Agent/MessageList/CollectionViewMessageListV3/Coordinator/"
let snapshot = source(coordinatorDir + "MessageListV3Coordinator+Snapshot.swift")
let bindings = source(coordinatorDir + "MessageListV3Coordinator+Bindings.swift")
let blockCell = source("Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedAssistantBlockV3.swift")

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)")
        failures += 1
    }
}
func index(of needle: String, in haystack: String) -> String.Index? {
    haystack.range(of: needle)?.lowerBound
}

print("▶️  the sources were found")
check("Snapshot coordinator", !snapshot.isEmpty)
check("Bindings coordinator", !bindings.isEmpty)
check("block cell", !blockCell.isEmpty)

print("▶️  the apply takes an anchor request")
check("applySnapshot has a defaulted preserveVisibleAnchor",
      snapshot.contains("preserveVisibleAnchor: Bool = false)"))
check("the capture is skipped while the session-load clamp owns the offset",
      snapshot.contains("(preserveVisibleAnchor && !clampAfterSessionLoad) ? captureVisibleAnchor() : nil"))

if let capture = index(of: "let anchorBefore = (preserveVisibleAnchor", in: snapshot),
   let suppressOn = index(of: "suppressContentOffsetAdjustment = true", in: snapshot),
   let layoutIfNeeded = index(of: "cv.layoutIfNeeded()", in: snapshot),
   let suppressOff = index(of: "suppressContentOffsetAdjustment = false", in: snapshot),
   let restore = index(of: "restoreVisibleAnchor(anchorBefore)", in: snapshot),
   let subViewport = index(of: "applySubViewportCompensation(caller: \"snapshot-subVP\")", in: snapshot) {
    check("capture happens BEFORE the apply suppresses compensation", capture < suppressOn)
    check("capture happens BEFORE the layout pass", capture < layoutIfNeeded)
    check("restore happens AFTER the layout pass and its suppression is lifted",
          suppressOff < restore && layoutIfNeeded < restore)
    check("restore happens BEFORE the sub-viewport inset pass", restore < subViewport)
} else {
    check("capture → suppress → layout → restore → sub-viewport are all present", false)
}

print("▶️  the toggle is the only caller and it names its path")
// [T-usage-toggle-anchor] The sink does NOT hard-code the opt-in: it passes a
// flag derived from the notification's sender marker, because
// `.messageListNeedsResnapshot` has three senders and only the toggle is a pure
// row insert/delete. A literal `true` at the call site would anchor font /
// appearance applies too.
let callers = snapshot.components(separatedBy: "preserveVisibleAnchor: true").count - 1
let inBindings = bindings.components(separatedBy: "preserveVisibleAnchor:").count - 1
check("no call site hard-codes preserveVisibleAnchor: true", callers == 0)
check("exactly one call site passes preserveVisibleAnchor", inBindings == 1)
check("only the marked usage-toggle sender opts in",
      bindings.contains("preserveVisibleAnchor: fromUsageToggle)"))
check("the sink labels the apply caller=usageToggle",
      bindings.contains("caller: fromUsageToggle ? \"usageToggle\" : \"resnapshot\","))

print("▶️  the restore is a plain UIKit offset write, clamped")
check("no SwiftUI withAnimation in the anchor code",
      !snapshot.contains("withAnimation { expanded") && !snapshot.contains("withAnimation(.easeInOut(duration: 0.2)) { expanded"))
check("the restore writes contentOffset through setContentOffset",
      snapshot.contains("cv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)"))
check("the target is clamped into the legal range",
      snapshot.contains("let clamped = min(max(target, minOff), maxOff)"))
check("a sub-pixel no-op stays a no-op",
      snapshot.contains("guard abs(clamped - cv.contentOffset.y) > 0.5 else { return }"))
check("the anchor is the FIRST visible row that still has its top on screen",
      snapshot.contains("if attrs.frame.minY - cv.contentOffset.y >= -0.5 { return anchor(item, attrs) }"))
check("a row clipped by the viewport top is still a fallback anchor",
      snapshot.contains("if fallback == nil { fallback = anchor(item, attrs) }"))

print("▶️  the asymmetry the fix has to survive is still where it was")
check("a quiet footer is seeded with its learned height, else the layout formula, on the usage toggle",
      snapshot.contains("let quietLearned = (preserveVisibleAnchor && !footerProminent)")
      && snapshot.contains("let quietSeed: CGFloat? = (preserveVisibleAnchor && !footerProminent)")
      && snapshot.contains("layout.quietFooterEstimate(width: cvWidth) : nil")
      && snapshot.contains("layout.setEstimatedHeight(footerProminent ? 48 : (quietSeed ?? 4), at: i)"))
check("the footer is still omitted from the snapshot when showUsage is off (the structural trigger survives)",
      snapshot.contains("|| (cellBridges[message.id]?.showUsage == true)") && snapshot.contains("if needsFooter {"))

print("▶️  gesture separation (double-tap block vs single-tap capsule) is untouched")
check("the double tap flips bridge.showUsage and posts the MARKED re-snapshot",
      blockCell.contains("bridge.showUsage = true")
      && blockCell.contains("object: MessageListItem.usageToggleSender)"))
check("the marker exists and the sink gates on it (AppearanceSettingsView posts the same notification)",
      source("Agent/MessageList/MessageListInfrastructure.swift").contains("static let usageToggleSender = \"usageToggle\"")
      && bindings.contains("(note.object as? String) == MessageListItem.usageToggleSender")
      && bindings.contains("preserveVisibleAnchor: fromUsageToggle"))
check("the anchor can never be the footer row this apply may delete",
      snapshot.contains("if case .assistantFooter = item { continue }"))
check("a stale anchor from an older apply is dropped",
      snapshot.contains("if requireCurrentApply, anchor.generation != snapshotApplyGeneration { return }")
      && snapshot.contains("snapshotApplyGeneration &+= 1"))
check("the single tap only swaps the row's contents (expanded / collapsed), same height",
      source("Agent/MessageList/CollectionViewMessageListV3/Cells/UsageStampRow.swift")
        .contains("stampCapsule(stamp).hidden().frame(width: 0)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
