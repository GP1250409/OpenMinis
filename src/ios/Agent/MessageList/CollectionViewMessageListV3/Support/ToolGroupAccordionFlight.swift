//
//  ToolGroupAccordionFlight.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-toolgroup-accordion] The frame driver of the chat tool-call accordion.
//
//  One flight animates one folded tool run from closed to open (or back). It
//  owns: the frozen natural heights of the member rows, the reveal clock
//  (CADisplayLink on the main run loop, `.common` mode — same as the sidebar
//  accordion), the per-frame relayout, the clipped rows, and the offset that
//  keeps the tapped title where the user tapped it.
//
//  Why a flight and not a UIView animation: the list rows are self-sizing and
//  the layout caches their heights (MessageListLayout). Animating a constraint
//  or a snapshot would either scale the text or fade a screenshot. Here every
//  frame writes ONE number (the reveal) into the layout, the layout hands each
//  member row `min(natural, frontier - Σ before)`, and UIKit re-positions the
//  rows below it. Text keeps its size; only the clipping window grows.
//
//  Scope discipline: this type never touches folding policy, the two switches,
//  the question card or the status-bar scroll flight. The coordinator passes a
//  plan and gets one `onFinish` call back.
//

import QuartzCore
import UIKit

final class ToolGroupAccordionFlight {

    enum Direction {
        case expand
        case collapse

        var targetReveal: CGFloat { self == .expand ? 1 : 0 }
    }

    /// How the flight ended. `.instant` = reduce motion / zero duration: the
    /// caller still gets the terminal state, but no intermediate frame existed.
    enum Outcome: String {
        case completed
        case interrupted      // user drag / scroll-to-top flight took the viewport
        case cancelled        // view went away (window nil, session swap, background)
        case instant          // reduce motion: applied without animating
    }

    struct Plan {
        /// Row range of the run's member rows in the CURRENT data source.
        var memberRange: ClosedRange<Int>
        /// Natural (unclipped) height of each member row, in range order.
        var naturalHeights: [CGFloat]
        /// Row of the tapped group header (the row whose screen Y is pinned).
        var headerIndex: Int
        /// The header's screen Y at the moment of the tap.
        ///
        /// Declared BEFORE `headerItem` on purpose: the memberwise initializer
        /// takes its arguments in declaration order, and every call site (the
        /// coordinator's transaction and the UIKit fixture) passes the anchor
        /// right after the header index.
        var anchorY: CGFloat
        /// What that row and the member rows REALLY are. Row counts cannot tell
        /// an inserted-above row, a same-count session swap or a replaced span
        /// row from the original layout.
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
    private var duration: CFTimeInterval = ToolGroupAccordion.duration
    private var didFinish = false
    private var onFinish: ((Outcome) -> Void)?

    /// Injected so the harness can force reduce motion; production reads the
    /// system switch.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    /// [T-toolgroup-accordion] Live rows, for the per-frame identity check.
    /// Supplied by the coordinator; never a count.
    var liveItems: (() -> [MessageListItem]?)?

    /// True when `items` still holds exactly this plan's rows at its indices.
    func planStillMatches(_ items: [MessageListItem]) -> Bool {
        guard let plan else { return false }
        guard items.count > plan.memberRange.upperBound, items.count > plan.headerIndex else { return false }
        guard items[plan.headerIndex] == plan.headerItem else { return false }
        for (k, want) in plan.memberItems.enumerated()
        where items[plan.memberRange.lowerBound + k] != want { return false }
        return true
    }

    /// Diagnostics counter (frames actually laid out) — the harness asserts it
    /// is > 1 so "instant" can never pass as "animated".
    private(set) var framesApplied = 0
    private(set) var lastOutcome: Outcome?

    init(collectionView: UICollectionView, layout: MessageListLayout) {
        self.collectionView = collectionView
        self.layout = layout
    }

    var isRunning: Bool { link != nil }
    var currentPlan: Plan? { plan }
    /// The direction the flight will END in (a retarget changes it). The
    /// transaction decides what to converge with THIS, never with the direction
    /// of the tap that started it.
    var finalDirection: Direction { direction }

    // MARK: - Takeover channel ownership

    /// True while THIS flight is the one that armed
    /// `layout.toolGroupAccordionAbort`.
    ///
    /// [T-toolgroup-accordion] The closure is installed by the transaction that
    /// starts the flight, and it must be disarmed on EVERY terminal path:
    /// takeover, drag interrupt, cancel, normal end (and the reduce-motion
    /// shortcut). Deciding that from `currentFlight() === flight` alone cannot
    /// work for the takeover path: the abort closure clears the stored flight
    /// BEFORE it finishes this one, so by the time the completion runs the
    /// identity check is false and the closure stayed armed with a dead flight
    /// captured (run 44506193558: `takeover: the abort channel is disarmed after
    /// the takeover`). Ownership therefore travels with the flight object:
    /// only the flight that armed the channel may clear it, so a newer
    /// transaction's channel is never stolen.
    private(set) var ownsAbortChannel = false

    /// Take ownership of the layout's takeover channel (the transaction arms it
    /// right before installing its closure).
    func armAbortChannel() { ownsAbortChannel = true }

    /// Disarm the takeover channel this flight armed, and only that one.
    func disarmAbortChannel() {
        guard ownsAbortChannel else { return }
        ownsAbortChannel = false
        layout.toolGroupAccordionAbort = nil
    }

    // MARK: - Start / retarget / finish

    /// Begin a flight. Applies the start state (all rows closed for `.expand`,
    /// fully open for `.collapse`) before the first frame so the caller can
    /// return to the run loop with the list already in the right geometry.
    func start(_ plan: Plan, direction: Direction,
               duration: CFTimeInterval = ToolGroupAccordion.duration,
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
        self.fromReveal = direction == .expand ? 0 : 1
        self.reveal = fromReveal
        self.startedAt = CACurrentMediaTime()
        layout.setToolGroupAccordion(MessageListLayout.ToolGroupAccordionSpan(lowerBound: plan.memberRange.lowerBound,
                                                                             naturalHeights: plan.naturalHeights,
                                                                             reveal: fromReveal))
        applyFrame(cv: cv, logFrame: false)

        if reduceMotion() || duration <= 0 {
            // Reduce motion: no intermediate frame at all. Terminal geometry,
            // then hand control back synchronously.
            setReveal(direction.targetReveal, cv: cv)
            finish(.instant)
            return
        }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Same run-loop mode as the sidebar accordion: keep animating while the
        // finger is still down on the list (tracking mode) instead of freezing
        // the first frame.
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// A second tap on the same run while a flight is in the air. The frozen
    /// heights stay valid (the rows never left), so this is a direction flip
    /// from the CURRENT reveal — no restart from 0, no structural churn.
    func retarget(_ direction: Direction) {
        guard isRunning else { return }
        self.direction = direction
        self.fromReveal = reveal
        self.startedAt = CACurrentMediaTime()
    }

    /// Stop at once and hand ownership back (drag, scroll-to-top flight,
    /// snapshot swap, view teardown). The caller decides what the final
    /// structure is; the layout override is already cleared here.
    func finish(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        lastOutcome = outcome
        // [T-toolgroup-accordion] Disarm BEFORE the completion runs and before
        // anything else can look at the owner: a takeover has already cleared
        // the stored flight, so nobody downstream can recognise this flight as
        // the owner anymore.
        disarmAbortChannel()
        link?.invalidate()
        link = nil
        restoreClip()
        layout.clearToolGroupAccordion()
        if let cv = collectionView, cv.window != nil, outcome != .cancelled {
            // The span is gone: the rows jump back to their real heights in one
            // layout pass. Suppress the layout's own contentOffsetAdjustment so
            // that pass cannot move the viewport - an interrupted flight must
            // leave the offset exactly where the finger left it.
            let wasSuppressed = layout.suppressContentOffsetAdjustment
            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            layout.suppressContentOffsetAdjustment = wasSuppressed
        }
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
        layout.clearToolGroupAccordion()
        // [T-toolgroup-accordion] The takeover closure captures this flight (and
        // through it the collection view and the layout), so leaving it armed on
        // a cancel is a retain cycle the list never gets back: the owner drops
        // its reference and then, if the toggle falls back to the instant
        // switch, nothing else ever clears it. A cancel means the list itself is
        // going away, so the channel is cleared outright, not only while this
        // flight still owns it.
        layout.toolGroupAccordionAbort = nil
        ownsAbortChannel = false
        plan = nil
        onFinish = nil
    }

    // MARK: - Frames

    @objc private func tick(_ link: CADisplayLink) {
        // [T-toolgroup-accordion] Bind the plan HERE: `plan` is `Plan?` and every
        // use below (identity log, structural bounds, the frame itself) reads its
        // members. `plan != nil` alone left them all looking at an Optional, which
        // is a compile error (`value of optional type 'Plan?' must be unwrapped`)
        // and a crash waiting behind a force unwrap. The flight still OWNS the
        // plan (`self.plan`), so the local binding changes no lifetime: `finish`
        // nils the property and every path here returns right after it.
        guard let cv = collectionView, let plan = self.plan else { finish(.cancelled); return }
        // The list must be on a window to be laid out at all (production
        // self-sizing refuses off-window cells) — a flight cannot continue
        // without it.
        guard cv.window != nil else { finish(.cancelled); return }
        // Drag takeover: the user's finger owns the viewport from the first
        // touch. Never fight a pan/deceleration.
        if cv.isTracking || cv.isDecelerating {
            finish(.interrupted)
            return
        }
        // [T-toolgroup-accordion] Structural conflict only. Ordinary content
        // updates re-apply the same rows, so the frozen span is still valid and
        // the animation must keep playing; rows appearing/disappearing under it
        // (a plan change, a new message, a session swap) retire it at once.
        // Identity check first (rows inserted above, a session swap with the
        // same count, a replaced span row), then the cheap bounds check.
        if let items = liveItems?(), !planStillMatches(items) {
            AppLogger(category: "ToolFold").info("[ToolFold][Accordion] retire=identity header=\(plan.headerIndex) span=\(plan.memberRange.lowerBound)...\(plan.memberRange.upperBound)")
            finish(.interrupted)
            return
        }
        let rowCount = cv.numberOfItems(inSection: 0)
        if plan.headerIndex >= rowCount || plan.memberRange.upperBound >= rowCount {
            AppLogger(category: "ToolFold").info("[ToolFold][Accordion] retire=structure rows=\(rowCount) header=\(plan.headerIndex) span=\(plan.memberRange.lowerBound)...\(plan.memberRange.upperBound)")
            finish(.interrupted)
            return
        }
        let elapsed = CACurrentMediaTime() - startedAt
        let p = ToolGroupAccordion.progress(elapsed: elapsed, duration: duration)
        let r = fromReveal + (direction.targetReveal - fromReveal) * p
        setReveal(r, cv: cv)
        if p >= 1 { finish(.completed); return }
    }

    private func setReveal(_ r: CGFloat, cv: UICollectionView) {
        reveal = min(1, max(0, r))
        layout.updateToolGroupAccordionReveal(reveal)
        applyFrame(cv: cv, logFrame: true)
    }

    /// One geometry step: relayout, clip the straddling row, put the header
    /// back where the user tapped it (clamped to the legal offset window).
    private func applyFrame(cv: UICollectionView, logFrame: Bool) {
        guard let plan = plan else { return }
        layout.invalidateLayout()
        cv.layoutIfNeeded()
        framesApplied += 1

        // Only the row that straddles the frontier can overflow its frame; the
        // rows below the frontier are hidden by the layout (height 0). Clip the
        // straddling cell so the text is revealed, never scaled or faded.
        let clipped = ToolGroupAccordion.clippedRow(natural: plan.naturalHeights, reveal: reveal)
        var clipIndex: Int?
        if let k = clipped { clipIndex = plan.memberRange.lowerBound + k }
        // Every member row keeps its TEXT at the natural height and is clipped
        // by the cell (see SelfSizingCell.accordionContentHeight): a cell that
        // simply shrank would re-lay the hosted SwiftUI content into the shorter
        // container, which squashes the transcript instead of revealing it.
        for (k, idx) in plan.memberRange.enumerated() {
            guard let cell = cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell else { continue }
            cell.clipsToBounds = true
            cell.accordionContentHeight = plan.naturalHeights[k]
        }

        // Anchor: rows below the header grow DOWNWARD, so the header's content
        // Y does not move; only the legal clamp (bottom pin / short content)
        // can move it. Re-derive the offset every frame from the header's real
        // frame instead of trusting the pre-flight number.
        guard let attrs = layout.layoutAttributesForItem(at: IndexPath(item: plan.headerIndex, section: 0)) else { return }
        let topInset = cv.adjustedContentInset.top
        let bottomInset = cv.adjustedContentInset.bottom
        let target = ToolGroupAccordion.anchoredOffset(headerY: attrs.frame.minY, anchorY: plan.anchorY,
                                                      contentHeight: cv.contentSize.height,
                                                      viewportHeight: cv.bounds.height,
                                                      topInset: topInset, bottomInset: bottomInset)
        if abs(target - cv.contentOffset.y) > 0.5 {
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
        }
        if logFrame {
            let drift = ToolGroupAccordion.anchorDrift(headerY: attrs.frame.minY, contentOffset: cv.contentOffset.y,
                                                       anchorY: plan.anchorY)
            AppLogger(category: "ToolFold").debug(String(
                format: "[ToolFold][Accordion] frame=%d reveal=%.3f header=%.1f offset=%.1f drift=%.2f clip=%@",
                framesApplied, reveal, attrs.frame.minY, cv.contentOffset.y, drift,
                clipIndex.map { String($0) } ?? "-"))
        }
    }

    private func restoreClip() {
        guard let cv = collectionView, let plan = plan else { return }
        for idx in plan.memberRange {
            if let cell = cv.cellForItem(at: IndexPath(item: idx, section: 0)) as? SelfSizingCell {
                cell.accordionContentHeight = nil
                cell.clipsToBounds = false
            }
        }
    }
}
