//
//  ChatMailFoldFlight.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-chat-mail-fold] The frame driver of the chat's mail-style fold.
//
//  One flight slides ONE block of child rows out from behind a fixed header
//  (expand) or back behind it (collapse). It owns: the frozen natural heights,
//  the block's internal gap, a CADisplayLink clock (`.common` mode, so the
//  film keeps running while a finger is still down), the clipped cell windows,
//  and the anchored content offset.
//
//  Why a flight and not `UIView.animate`: the rows are self-sizing and the
//  layout caches their heights. Animating a constraint or a snapshot would
//  either scale the text or fade a screenshot. Here every frame writes ONE
//  number (the reveal) into the layout; the layout hands each child
//  `ChatMailFold.rows(...).visible` and the cell clips its TOP. Text keeps its
//  size; only the window behind the header moves.
//
//  END-STATE DISCIPLINE (the bug this file exists to not repeat): `finish`
//  NEVER lays the list out after clearing the span. The cancelled 2026-11-19
//  accordion restored the members' full natural heights and laid out BEFORE
//  the transaction deleted the rows, which showed as a hitch at the end of
//  every close (run d48 / user recording 11-20). Here the span is cleared by
//  the caller inside ONE `UIView.performWithoutAnimation` block, together with
//  the structural apply, so no frame can ever see the natural heights of a
//  block that is about to disappear.
//

import QuartzCore
import UIKit

final class ChatMailFoldFlight {

    enum Direction {
        case expand
        case collapse

        var targetReveal: CGFloat { self == .expand ? 1 : 0 }
        var isExpanding: Bool { self == .expand }
    }

    /// How the flight ended. `.instant` = reduce motion / zero duration: the
    /// caller still gets the terminal state, but no intermediate frame existed.
    enum Outcome: String {
        case completed
        /// A finger (drag / deceleration) or the status-bar flight took the
        /// viewport. The caller must land the business end state at once.
        case interrupted
        /// The list went away (window nil, session swap, teardown).
        case cancelled
        /// Reduce motion / zero duration.
        case instant
    }

    struct Plan {
        /// Child rows in the CURRENT data source, contiguous, below the header.
        var memberRange: ClosedRange<Int>
        /// Natural (unclipped) height of each child, in range order.
        var naturalHeights: [CGFloat]
        /// Gap between two children (folded into each child's slot).
        var rowSpacing: CGFloat
        /// The fixed header row (its screen Y is pinned).
        var headerIndex: Int
        /// The header's screen Y when the tap landed.
        var anchorY: CGFloat
        var headerItem: MessageListItem
        var memberItems: [MessageListItem]
    }

    private weak var collectionView: UICollectionView?
    private let layout: MessageListLayout

    private var link: CADisplayLink?
    private var plan: Plan?
    private var direction: Direction = .expand
    private(set) var reveal: CGFloat = 0
    private var fromReveal: CGFloat = 0
    private var startedAt: CFTimeInterval = 0
    private var duration: CFTimeInterval = ChatMailFold.duration
    private var didFinish = false
    private var onFinish: ((Outcome) -> Void)?

    /// Injected so a harness can force reduce motion; production reads the
    /// system switch.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    /// Live rows, for the per-frame identity check (never a row count).
    var liveItems: (() -> [MessageListItem]?)?

    private(set) var framesApplied = 0
    private(set) var lastOutcome: Outcome?
    /// Set when the flight stopped because the list no longer holds the plan.
    private(set) var retiredReason: String?

    init(collectionView: UICollectionView, layout: MessageListLayout) {
        self.collectionView = collectionView
        self.layout = layout
    }

    var isRunning: Bool { link != nil }
    var currentPlan: Plan? { plan }
    /// The direction the flight will END in (a retarget flips it).
    var finalDirection: Direction { direction }

    /// True when `items` still holds exactly this plan's rows at its indices.
    func planStillMatches(_ items: [MessageListItem]) -> Bool {
        guard let plan else { return false }
        guard items.count > plan.memberRange.upperBound, items.count > plan.headerIndex else { return false }
        guard items[plan.headerIndex] == plan.headerItem else { return false }
        for (k, want) in plan.memberItems.enumerated()
        where items[plan.memberRange.lowerBound + k] != want { return false }
        return true
    }

    // MARK: - Start / retarget / finish

    /// Begin a flight. The caller has already installed the span at the START
    /// reveal and laid the list out once, so the first presented frame is the
    /// collapsed (or fully open) geometry.
    func start(_ plan: Plan, direction: Direction,
               duration: CFTimeInterval = ChatMailFold.duration,
               onFinish: @escaping (Outcome) -> Void) {
        guard let cv = collectionView, !plan.naturalHeights.isEmpty,
              plan.naturalHeights.count == plan.memberRange.count else {
            onFinish(.cancelled)
            return
        }
        self.plan = plan
        self.direction = direction
        self.duration = duration
        self.onFinish = onFinish
        self.didFinish = false
        self.framesApplied = 0
        self.retiredReason = nil
        self.fromReveal = direction == .expand ? 0 : 1
        self.reveal = fromReveal
        self.startedAt = CACurrentMediaTime()
        applyFrame(cv: cv)

        if reduceMotion() || duration <= 0 {
            setReveal(direction.targetReveal, cv: cv)
            finish(.instant)
            return
        }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// A second tap on the same block while a flight is in the air. The frozen
    /// heights stay valid (the rows never left the data source mid-flight), so
    /// this is a direction flip from the CURRENT reveal — no restart from 0, no
    /// structural churn.
    func retarget(_ direction: Direction) {
        guard isRunning else { return }
        self.direction = direction
        self.fromReveal = reveal
        self.startedAt = CACurrentMediaTime()
    }

    /// Stop at once and hand ownership back. The span is deliberately NOT
    /// cleared here (see the file header): the caller clears it together with
    /// the structural apply in one non-animated block.
    func finish(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        lastOutcome = outcome
        link?.invalidate()
        link = nil
        restoreClip()
        plan = nil
        let cb = onFinish
        onFinish = nil
        cb?(outcome)
    }

    /// The window went away / the session changed: drop everything silently.
    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        lastOutcome = .cancelled
        link?.invalidate()
        link = nil
        restoreClip()
        layout.clearMailFold()
        layout.toolGroupAccordionAbort = nil
        plan = nil
        onFinish = nil
    }

    // MARK: - Frames

    @objc private func tick(_ link: CADisplayLink) {
        guard let cv = collectionView, let plan = self.plan else { finish(.cancelled); return }
        guard cv.window != nil else { retiredReason = "off-window"; finish(.cancelled); return }
        // Drag takeover: the finger owns the viewport from the first touch.
        if cv.isTracking || cv.isDecelerating {
            retiredReason = "user-scroll"
            finish(.interrupted)
            return
        }
        // Structural conflict only (identity first, then cheap bounds): the
        // block moved, the session swapped, or the rows were replaced.
        if let items = liveItems?(), !planStillMatches(items) {
            AppLogger(category: "MailFold").info("[MailFold] retire=identity header=\(plan.headerIndex) span=\(plan.memberRange.lowerBound)...\(plan.memberRange.upperBound)")
            retiredReason = "identity"
            finish(.interrupted)
            return
        }
        let rowCount = cv.numberOfItems(inSection: 0)
        if plan.headerIndex >= rowCount || plan.memberRange.upperBound >= rowCount {
            AppLogger(category: "MailFold").info("[MailFold] retire=structure rows=\(rowCount) header=\(plan.headerIndex) span=\(plan.memberRange.lowerBound)...\(plan.memberRange.upperBound)")
            retiredReason = "structure"
            finish(.interrupted)
            return
        }
        let elapsed = CACurrentMediaTime() - startedAt
        let p = ChatMailFold.progress(elapsed: elapsed, duration: duration)
        let r = fromReveal + (direction.targetReveal - fromReveal) * p
        setReveal(r, cv: cv)
        if p >= 1 { finish(.completed) }
    }

    private func setReveal(_ r: CGFloat, cv: UICollectionView) {
        reveal = min(1, max(0, r))
        layout.updateMailFoldReveal(reveal)
        applyFrame(cv: cv)
    }

    /// One geometry step: relayout, write each child's top clip into its cell,
    /// put the fixed header back where the user tapped it (clamped).
    private func applyFrame(cv: UICollectionView) {
        guard let plan = plan else { return }
        // UIKit's own contentOffsetAdjustment must never fight the anchor.
        let wasSuppressed = layout.suppressContentOffsetAdjustment
        layout.suppressContentOffsetAdjustment = true
        layout.invalidateLayout()
        cv.layoutIfNeeded()
        layout.suppressContentOffsetAdjustment = wasSuppressed
        framesApplied += 1

        for (k, idx) in plan.memberRange.enumerated() {
            guard let cell = cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell else { continue }
            cell.clipsToBounds = true
            cell.accordionContentHeight = max(0, plan.naturalHeights[k])
            cell.mailFoldContentTopClip = layout.mailFoldTopClip(at: idx)
        }

        guard let attrs = layout.layoutAttributesForItem(at: IndexPath(item: plan.headerIndex, section: 0)) else { return }
        let target = ChatMailFold.anchoredOffset(headerY: attrs.frame.minY, anchorY: plan.anchorY,
                                                contentHeight: cv.contentSize.height,
                                                viewportHeight: cv.bounds.height,
                                                topInset: cv.adjustedContentInset.top,
                                                bottomInset: cv.adjustedContentInset.bottom)
        if abs(target - cv.contentOffset.y) > 0.5 {
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
        }
        AppLogger(category: "MailFold").debug(String(
            format: "[MailFold] frame=%d reveal=%.3f header=%.1f offset=%.1f drift=%.2f",
            framesApplied, reveal, attrs.frame.minY, cv.contentOffset.y,
            ChatMailFold.anchorDrift(headerY: attrs.frame.minY, contentOffset: cv.contentOffset.y, anchorY: plan.anchorY)))
    }

    private func restoreClip() {
        guard let cv = collectionView, let plan = plan else { return }
        for idx in plan.memberRange {
            if let cell = cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell {
                cell.mailFoldContentTopClip = 0
                cell.accordionContentHeight = nil
                cell.clipsToBounds = false
            }
        }
    }
}
