import Foundation
import UIKit
import SwiftUI

// Stubs for the usage-toggle anchor regression.
//
// The production anchor code is NOT re-written here: the driver slices
// `// MARK: - [T-usage-toggle-anchor] …` out of
// `Coordinator/MessageListV3Coordinator+Snapshot.swift` verbatim and wraps it in
// `extension CollectionViewMessageListV3.Coordinator`. This file only supplies
// the app-side members those two functions read, plus the fixture's mirror of
// `applySnapshot`'s *structural* sequence (which the driver pins against the
// production file, statement by statement, in `source_checks`).
//
// The row content is a real SwiftUI view in a real `SelfSizingCell`
// (UIHostingConfiguration), and the layout is the production
// `MessageListLayout`, so the 4pt-estimate vs real-height asymmetry that the
// recording shows is produced by UIKit itself — not by a constant in the test.

/// Fixed default message scale, used only to qualify the layout's cross-session
/// height-memo key (`MessageListLayout.key(_:width:)`). The row and text
/// measurement still use SwiftUI's real font metrics. Same stub as
/// `scripts/thinking-transaction-tests/ProductionStubs.swift`.
final class FontSettings {
    static let shared = FontSettings()
    func scaledMessage(_ reference: CGFloat) -> CGFloat { reference }
}

/// App-side markdown table column planner called by `MessageListLayout`'s height
/// estimate. No table is rendered in this fixture; only the `Plan.widths` shape
/// has to exist to compile.
enum TableColumnPlanner {
    struct Column {
        var natural: CGFloat
        var minUnbreakable: CGFloat
    }
    struct Plan { var widths: [CGFloat]; var isWide: [Bool] }
    static func plan(columns: [Column], availableWidth: CGFloat) -> Plan {
        let total = max(columns.reduce(0) { $0 + $1.natural }, 1)
        let scale = min(1, max(0, availableWidth) / total)
        return Plan(widths: columns.map { max($0.minUnbreakable, $0.natural * scale) },
                    isWide: columns.map { _ in false })
    }
}

/// Diagnostics-only timestamp read by the verbatim `SelfSizingCell` logger
/// (`sinceAppear` in the `[ScrollStall]` line). Nothing under test reads it, so
/// the value only has to exist; same stub shape as
/// `scripts/thinking-transaction-tests/ProductionStubs.swift`.
enum AIChatViewModel {
    static let onAppearTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
}

/// Test double for the app's markdown text view. The verbatim `SelfSizingCell`
/// walks the subtree for `asyncAttachmentRenderSignal()` to qualify its height
/// memo key; this fixture's rows are plain SwiftUI text, so no such view is ever
/// hosted and the signal is only here to type-check.
final class SelectableMarkdownTextView: UIView {
    private var signal = 0
    func asyncAttachmentRenderSignal() -> Int { signal }
}

/// Logging is not under test (same pattern as the other standalone fixtures).
struct AppLogger {
    let category: String
    init(category: String) { self.category = category }
    func info(_ message: String) { AnchorTrace.record(message) }
    func debug(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}

/// Collects the `[anchor-restore]` lines the production restore writes, so the
/// suite can prove a restore actually happened (or deliberately did not).
enum AnchorTrace {
    private(set) static var lines: [String] = []
    static func record(_ line: String) {
        if line.contains("[anchor-restore]") { lines.append(line) }
    }
    static func reset() { lines.removeAll() }
    static var count: Int { lines.count }
    static var last: String? { lines.last }
}

/// A `UICollectionView` whose tracking / decelerating state can be forced.
///
/// `UIScrollView.isTracking` is read-only and only becomes true under a real
/// finger, so the production guard `!cv.isTracking, !cv.isDecelerating` cannot
/// be exercised otherwise. Nothing else about UIKit's behaviour changes.
final class TrackingCollectionView: UICollectionView {
    var forcedTracking: Bool?
    var forcedDecelerating: Bool?
    override var isTracking: Bool { forcedTracking ?? super.isTracking }
    override var isDecelerating: Bool { forcedDecelerating ?? super.isDecelerating }
}

enum CollectionViewMessageListV3 {
    enum ScrollMode {
        case autoScrolling, userBrowsing
    }

    enum Section: Hashable {
        case main
    }

    final class ListViewController: UIViewController {
        var collectionView: UICollectionView!
        var messageListLayout: MessageListLayout?
        init(collectionView: UICollectionView, messageListLayout: MessageListLayout) {
            self.collectionView = collectionView
            self.messageListLayout = messageListLayout
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("unused in tests") }
        override func loadView() { view = UIView(frame: collectionView.frame) }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.addSubview(collectionView)
        }
    }

    final class ViewModel {
        var isNearBottom = true
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        weak var viewController: ListViewController?
        var vm: ViewModel?
        var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>?
        var scrollMode: ScrollMode = .userBrowsing

        /// Production keeps these two in `MessageListV3Coordinator.swift`
        /// (split seam). Names and semantics are identical.
        var snapshotApplyGeneration = 0
        var clampAfterSessionLoad = false

        /// The fixture's mirror of `applySnapshot`'s structural sequence.
        /// `onFirstLayout` runs between `cv.layoutIfNeeded()` and
        /// `suppress = false`, i.e. exactly where UIKit has laid the new row
        /// out at its ESTIMATE and the real self-size has not landed yet.
        var onFirstLayout: (() -> Void)?
        /// Called after the post-apply block, so a test can read the final
        /// state of one apply without settling the run loop first.
        var onApplied: (() -> Void)?

        func applyStructural(items newItems: [MessageListItem],
                            estimates: [MessageListItem: CGFloat],
                            preserveVisibleAnchor: Bool) {
            guard let vm, let cv = viewController?.collectionView, let ds = dataSource else { return }
            _ = vm
            let snapshotLayout = viewController?.messageListLayout
            // Production shifts the per-index height cache by item identity
            // inside its item builder, i.e. BEFORE the anchor capture.
            snapshotLayout?.updateCacheForSnapshot(oldIds: ds.snapshot().itemIdentifiers, newIds: newItems)
            // ── production order starts here (see driver source_checks) ──
            snapshotApplyGeneration &+= 1
            let anchorBefore = (preserveVisibleAnchor && !clampAfterSessionLoad)
                ? captureVisibleAnchor() : nil
            snapshotLayout?.suppressContentOffsetAdjustment = true
            // Production builds `newItems` wholesale and applies it; the diff
            // then computes the insert/delete by identity. Doing the same here
            // keeps the footer at its real list position (right after its
            // message's last block) instead of parking it at the end.
            var snap = NSDiffableDataSourceSnapshot<Section, MessageListItem>()
            snap.appendSections([.main])
            snap.appendItems(newItems, toSection: .main)
            // Stands in for the production seeding loop (every item gets an
            // estimate; the quiet footer gets `footerProminent ? 48 : 4` = 4).
            for (i, item) in newItems.enumerated() {
                if let seed = estimates[item] { snapshotLayout?.setEstimatedHeight(seed, at: i) }
            }
            ds.apply(snap, animatingDifferences: false)
            cv.layoutIfNeeded()
            onFirstLayout?()
            snapshotLayout?.suppressContentOffsetAdjustment = false
            // ── [T-usage-toggle-anchor] restore ──
            if let anchorBefore {
                restoreVisibleAnchor(anchorBefore)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let cv = self.viewController?.collectionView,
                          self.scrollMode != .autoScrolling,
                          !cv.isTracking, !cv.isDecelerating else { return }
                    self.restoreVisibleAnchor(anchorBefore)
                }
            }
            // ── production's post-apply block ──
            let rawMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            let maxOff = max(0, rawMaxOff)
            if scrollMode == .autoScrolling && maxOff > 0 {
                cv.contentOffset.y = maxOff
            }
            onApplied?()
        }
    }
}
