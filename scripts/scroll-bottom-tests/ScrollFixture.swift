import Foundation
import UIKit

// Fixture for the scroll-to-bottom animation regression.
//
// The production scroll code is NOT re-written here: the driver slices
// `bottomRestingOffset`, `applySubViewportCompensation`,
// `absorbPendingComposerShrink`, `animatesJumpToBottom`, `scrollToBottomNow`,
// `syncScrollFlags`, `isNearBottom` / `isAtContentTop` / `isWithinBottom`,
// `nbDump` (MessageListV3Coordinator+Scroll.swift), `scheduleCoalescedScroll`
// (+Streaming.swift) and `scrollViewWillBeginDragging` /
// `scrollViewDidEndScrollingAnimation` (+ScrollViewDelegate.swift) verbatim
// into a generated file and wraps them in
// `extension CollectionViewMessageListV3.Coordinator`.
//
// This file only supplies what those methods read from the app: a view
// controller holding a REAL UICollectionView in a REAL window, the scroll mode,
// the insets, the composer-shrink bookkeeping and a stand-in view model.

// Logging is not under test (same pattern as the other standalone fixtures).
struct AppLogger {
    let category: String
    init(category: String) { self.category = category }
    func info(_ message: String) {}
    func debug(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}

/// The two `MessageListLayout` members the scroll code touches. The layout's
/// measurement behaviour is not what this fixture tests (the thinking-transaction
/// regression owns that), so it is a two-property stand-in.
protocol LayoutPinning: AnyObject {
    var isAutoScrollPinning: Bool { get set }
    var deferSelfSizing: Bool { get set }
}

final class FixtureLayout: LayoutPinning {
    var isAutoScrollPinning = true
    var deferSelfSizing = false
}

enum CollectionViewMessageListV3 {
    enum ScrollMode {
        case autoScrolling, userBrowsing
    }

    final class ScrollListViewController: UIViewController {
        /// Implicitly unwrapped, exactly like the production view controller:
        /// the scroll code reads `viewController?.collectionView?....`.
        var collectionView: UICollectionView!
        var messageListLayout: LayoutPinning?
        init(collectionView: UICollectionView, layout: LayoutPinning) {
            self.collectionView = collectionView
            self.messageListLayout = layout
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("unused in tests") }
        override func loadView() { view = UIView(frame: collectionView.frame) }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.addSubview(collectionView)
        }
    }

    final class ScrollViewModel {
        var isNearBottom = true
        var isAtFirstTurn = true
        var streamingUIUpdatesSuspended = false
        func setStreamingUIUpdatesSuspended(_ suspended: Bool) {
            streamingUIUpdatesSuspended = suspended
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var viewController: ScrollListViewController?
        var vm: ScrollViewModel?
        var scrollMode: ScrollMode = .autoScrolling

        // Stored state the extracted production methods read. Production keeps
        // these in MessageListV3Coordinator.swift (split seam); the values and
        // names are identical.
        let nearBottomThreshold: CGFloat = 20
        let reacquireAutoScrollThreshold: CGFloat = 4
        var lastDidScrollOffsetY: CGFloat = 0
        var lastJumpedUserId: UUID?
        var extraTopInset: CGFloat = 0
        var baseBottomInset: CGFloat = 0
        var composerShrink = ComposerShrinkAbsorption()
        var composerLiveHeight: ComposerLiveHeight?
        var composerShrinkAbsorbDeadline: CFAbsoluteTime = 0
        var searchHidesComposer = false
        static let searchBottomInset: CGFloat = 8
        var isAnimatingScrollToBottom = false
        var scrollBottomJumpToken = 0
        var scrollBottomRealigns = 0
        var pendingScrollWork: DispatchWorkItem?
        var clampAfterSessionLoad = false

        /// Production releases the parked thinking-toggle anchor here; no
        /// transaction is running in this fixture.
        func releaseThinkingToggleOnUserScroll() {}
    }
}

// MARK: - A real list

/// A `UICollectionView` with enough rows to scroll, in a real window, with the
/// same bottom-inset shape the chat list uses (base inset for the composer).
final class ListFixture: NSObject {
    let window: UIWindow
    let viewController: CollectionViewMessageListV3.ScrollListViewController
    let collectionView: UICollectionView
    let layout = FixtureLayout()
    let coordinator = CollectionViewMessageListV3.Coordinator()
    let viewModel = CollectionViewMessageListV3.ScrollViewModel()

    static let rowHeight: CGFloat = 140
    let bottomInset: CGFloat = 120

    private(set) var rowCount: Int = 0

    init(rows: Int, viewport: CGSize = CGSize(width: 390, height: 800)) {
        rowCount = rows
        let flow = UICollectionViewFlowLayout()
        flow.itemSize = CGSize(width: 390, height: ListFixture.rowHeight)
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        flow.sectionInset = .zero
        collectionView = UICollectionView(frame: CGRect(origin: .zero, size: viewport), collectionViewLayout: flow)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        collectionView.backgroundColor = .white

        viewController = CollectionViewMessageListV3.ScrollListViewController(collectionView: collectionView, layout: layout)
        window = UIWindow(frame: CGRect(origin: .zero, size: viewport))
        super.init()

        coordinator.viewController = viewController
        coordinator.vm = viewModel
        coordinator.baseBottomInset = bottomInset

        window.rootViewController = viewController
        window.makeKeyAndVisible()

        collectionView.dataSource = self
        collectionView.delegate = self
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(origin: .zero, size: viewport)
        collectionView.frame = CGRect(origin: .zero, size: viewport)
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
    }

    /// Grow the content the way self-sizing does after rows below the old
    /// viewport get laid out: real heights replace the estimates.
    func appendRows(_ extra: Int) {
        rowCount += extra
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
    }

    var contentBottomTarget: CGFloat {
        collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
    }

    func setOffset(_ y: CGFloat) {
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}

extension ListFixture: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rowCount }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }
}

extension ListFixture: UICollectionViewDelegate {}

// MARK: - Frame sampling

/// One sample per run-loop turn (~1/60 s). UIKit drives the scroll animation
/// from the display link, so pumping the main run loop is what advances it.
struct FrameSample {
    let t: TimeInterval
    let y: CGFloat
}

final class FrameRecorder {
    private(set) var samples: [FrameSample] = []
    private let start = CACurrentMediaTime()

    func record(_ y: CGFloat) {
        samples.append(FrameSample(t: CACurrentMediaTime() - start, y: y))
    }

    /// Pump the main run loop for `duration` seconds, sampling every turn.
    @discardableResult
    func pump(_ duration: TimeInterval, _ y: () -> CGFloat) -> [FrameSample] {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            record(y())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 60.0))
        }
        record(y())
        return samples
    }
}

func distinctIntermediate(_ samples: [FrameSample], from: CGFloat, to: CGFloat) -> [CGFloat] {
    var seen: [CGFloat] = []
    for sample in samples {
        let y = sample.y
        guard y > from + 1.5, y < to - 1.5 else { continue }
        if let last = seen.last, abs(last - y) < 0.5 { continue }
        seen.append(y)
    }
    return seen
}

func firstReachTime(_ samples: [FrameSample], target: CGFloat, tolerance: CGFloat = 1.0) -> TimeInterval? {
    samples.first(where: { abs($0.y - target) <= tolerance })?.t
}

func maxStep(_ samples: [FrameSample]) -> CGFloat {
    var worst: CGFloat = 0
    for (a, b) in zip(samples, samples.dropFirst()) {
        worst = max(worst, abs(b.y - a.y))
    }
    return worst
}
