// Stubs for the application services the verbatim production files call into.
// Every behaviour the suite asserts on comes from the real MessageListLayout /
// SelfSizingCell / MinisUIStore / commitGenUIStateChange.
import Foundation
import UIKit

/// Diagnostics-only timestamp read by the verbatim SelfSizingCell logger.
enum AIChatViewModel {
    static let onAppearTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
}

/// Fixed default message scale (only used to qualify memo keys).
final class FontSettings {
    static let shared = FontSettings()
    func scaledMessage(_ reference: CGFloat) -> CGFloat { reference }
}

/// Test double for the app's logger; keeps the production trace inspectable.
final class AppLogger {
    static var lines: [String] = []
    static let lock = NSLock()
    let category: String
    init(category: String) { self.category = category }
    func debug(_ m: String) { record("DEBUG", m) }
    func info(_ m: String) { record("INFO", m) }
    func warning(_ m: String) { record("WARN", m) }
    func error(_ m: String) { record("ERROR", m) }
    private func record(_ level: String, _ m: String) {
        AppLogger.lock.lock()
        AppLogger.lines.append("[\(category)][\(level)] \(m)")
        if AppLogger.lines.count > 4000 { AppLogger.lines.removeFirst(1000) }
        AppLogger.lock.unlock()
    }
}

/// Test double for the markdown table column planner used by
/// `MarkdownHeightEstimate` (compiled verbatim inside MessageListLayout.swift).
enum TableColumnPlanner {
    struct Column {
        var natural: CGFloat
        var minUnbreakable: CGFloat
        init(natural: CGFloat, minUnbreakable: CGFloat) {
            self.natural = natural
            self.minUnbreakable = minUnbreakable
        }
    }
    struct Plan { var widths: [CGFloat]; var isWide: [Bool] }
    static func plan(columns: [Column], availableWidth: CGFloat) -> Plan {
        let total = max(columns.reduce(0) { $0 + $1.natural }, 1)
        let scale = min(1, max(0, availableWidth) / total)
        return Plan(widths: columns.map { max($0.minUnbreakable, $0.natural * scale) },
                    isWide: columns.map { _ in false })
    }
}

enum CrashBreadcrumbs {
    static var recorded: [String] = []
    static func record(_ kind: String, detail: String) { recorded.append("\(kind) \(detail)") }
}

/// Bounds the printed PASS lines so a long run stays readable.
final class CheckLog {
    static var passed = 0
    static var failed = 0
    static func pass(_ name: String) {
        passed += 1
        print("PASS: \(name)")
        fflush(stdout)
    }
    static func fail(_ name: String) {
        failed += 1
        print("FAIL: \(name)")
        fflush(stdout)
    }
    /// One assertion; `detail` is always printed so a failure carries numbers.
    @discardableResult
    static func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        let d = detail()
        if cond { pass(name + (d.isEmpty ? "" : " (\(d)")) }
        else { fail(name + (d.isEmpty ? "" : " (\(d)")) }
        return cond
    }
}

/// Stub for the app's markdown text view: `SelfSizingCell.renderQualifiedKey`
/// walks the subtree asking for a render signal; the fixtures host none.
final class SelectableMarkdownTextView: UIView {
    private var signal = 0
    func asyncAttachmentRenderSignal() -> Int { signal }
}

/// The list strips UIKit implicit animations. The real class lives in
/// MessageListInfrastructure.swift (not compiled here), so the fixture defines
/// the members the production code under test touches.
final class NoAnimationCollectionView: UICollectionView {
    var animatesNextLayoutPass = false
    var isApplyingSnapshot = false
    var streamingGrowAnimationEnabled = false
}
