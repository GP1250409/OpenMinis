// Stubs for the application services the verbatim production files call into.
// Kept as thin as the compile needs them; every behaviour the tests assert on
// comes from the real MessageListLayout / SelfSizingCell.
import Foundation
import UIKit

/// Test double for the app's logger. Records lines so a failure can print the
/// production trace (e.g. the [CellSizing] INVALIDATE lines) instead of nothing.
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
/// The tests never exercise tables; only `plan(columns:availableWidth:)`'s
/// `widths` shape is required to compile.
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

/// `CrashBreadcrumbs` is an ObjC helper in the app; the verbatim code only
/// records strings.
enum CrashBreadcrumbs {
    static var recorded: [String] = []
    static func record(_ kind: String, detail: String) { recorded.append("\(kind) \(detail)") }
}

/// Bounds the number of printed PASS lines so a 200-check run stays readable.
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
}

/// Test double for the app's markdown text view. `SelfSizingCell`'s
/// `renderQualifiedKey` walks the subtree asking for a render signal; the
/// fixtures host no such view, so the signal is only here to type-check.
final class SelectableMarkdownTextView: UIView {
    private var signal = 0
    func asyncAttachmentRenderSignal() -> Int { signal }
}


/// The list strips UIKit implicit animations: the transaction sets
/// `animatesNextLayoutPass` on it. The class itself lives in
/// MessageListInfrastructure.swift (not compiled here), so the fixture defines
/// the one member the transaction touches.
final class NoAnimationCollectionView: UICollectionView {
    var animatesNextLayoutPass = false
}
