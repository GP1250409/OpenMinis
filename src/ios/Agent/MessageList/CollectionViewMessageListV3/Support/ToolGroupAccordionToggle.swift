//
//  ToolGroupAccordionToggle.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-toolgroup-accordion] The REVEAL TRANSACTION of one tool-group toggle.
//
//  The coordinator owns the business half of a tap — the expanded / manually
//  folded sets, `scrollMode`, and taking the viewport from a status-bar flight —
//  and then hands the list to this type, which does the rest with production
//  code only:
//
//    freeze real natural heights (on-screen cells through their receipts,
//    off-screen rows through ToolGroupAccordionMeasurement)  →
//    prove the members are ONE contiguous window below the header  →
//    freeze them at reveal 0 / keep them while closing  →
//    run the ToolGroupAccordionFlight  →
//    converge the structure, then put the tapped title back.
//
//  It lives here rather than inside the coordinator for one reason: the UIKit
//  regression harness cannot link the coordinator (it pulls the whole app), but
//  it CAN link this file, so the harness calls the same `run(_:in:)` the app
//  calls instead of re-implementing the transaction next to it. Everything the
//  transaction needs from its list comes in through `Environment`.
//

import UIKit

struct ToolGroupAccordionToggle {

    /// What the transaction needs from the list it runs in.
    struct Environment {
        let collectionView: UICollectionView
        let layout: MessageListLayout
        /// The rows as they are right now (the diffable snapshot's items).
        var items: () -> [MessageListItem]
        /// Commit the business structure (the coordinator's `applySnapshot`).
        /// `items()` is the source of truth again once this returns.
        var applyStructure: (String) -> Void
        /// The PRODUCTION cell configuration in its measurement mode
        /// (`writesListState: false`); see `ToolGroupAccordionMeasurement`.
        var configureForMeasurement: (SelfSizingCell, MessageListItem, IndexPath) -> Void
        /// Re-render the tapped row with its NEW expanded state.
        ///
        /// `isExpanded` is baked into the cell's content when it is configured
        /// (`BridgedToolGroupV3` takes it as a `let`), and a diffable apply
        /// never reconfigures an item whose identity did not change — the
        /// identity of a group row is `.toolGroup(messageId, firstBlockId)`,
        /// which the flip does not touch. Without this call the chevron and the
        /// "Shows / Hides each tool call" accessibility label keep the OLD
        /// state for the whole flight (and until some unrelated reconfigure).
        var refreshHeader: (MessageListItem) -> Void
        /// Record that a CLOSE was interrupted before it converged, so the list
        /// can delete the rows at the first moment nobody owns the viewport
        /// (drag settle / status-bar flight end / the next tap). Deleting them
        /// inside `finish` would move everything below them while the finger is
        /// still down.
        var deferConverge: (String) -> Void
        /// Put the tapped row back at its screen Y (the coordinator clamps it
        /// into the list's legal offset window).
        var restoreAnchor: (MessageListItem, CGFloat) -> Void
        /// Store / clear the live flight on the owner (the coordinator keeps the
        /// same property its retarget and pre-apply checks read).
        var storeFlight: (ToolGroupAccordionFlight?) -> Void
        /// The flight the owner currently holds (identity check: a newer tap or
        /// an abort may have replaced / cleared it).
        var currentFlight: () -> ToolGroupAccordionFlight?
        var isReduceMotion: () -> Bool
        /// Streaming: the list is re-applied continuously, so an animation here
        /// would be cut short by the next update — the caller switches instantly.
        var isStreaming: () -> Bool
        var log: (String) -> Void
    }

    struct Request {
        /// The `.toolGroup` row the user tapped.
        let item: MessageListItem
        /// The member rows, in order.
        let memberItems: [MessageListItem]
        let expanding: Bool
        /// Where the tapped row was when the tap arrived (diagnostics only).
        let oldIndex: Int
        /// The tapped row's top in the viewport, to be put back.
        let anchorY: CGFloat
        /// `firstBlockId` prefix, for the log.
        let groupTag: String
    }

    enum Outcome {
        /// The accordion is running; its end handler converges the structure.
        case started(ToolGroupAccordionFlight)
        /// The transaction declined and the caller must use its instant switch.
        case fallback(String)
        /// The list does not hold what the tap was about (row gone, members
        /// not where the plan says). Also the caller's instant switch.
        case invalid(String)
    }

    /// Member indices in order, or nil when any member row is missing.
    static func memberIndices(of memberItems: [MessageListItem], in items: [MessageListItem]) -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(memberItems.count)
        for item in memberItems {
            guard let index = items.firstIndex(of: item) else { return nil }
            out.append(index)
        }
        return out
    }

    /// One contiguous span strictly below `headerIndex`.
    static func isContiguousSpan(_ idxs: [Int], headerIndex: Int) -> Bool {
        guard let first = idxs.first, idxs.count > 0, first > headerIndex else { return false }
        return idxs == Array(first...(first + idxs.count - 1))
    }

    /// [T-toolgroup-collapse-finish] Did any of the run's member rows survive the
    /// structural apply of a completed close?
    ///
    /// `applyStructure` is the coordinator's `applySnapshot`, and that call can
    /// legitimately do nothing: it returns at once while a session loads, and the
    /// tool-fold re-plan only defers when streaming UI updates are suspended. A
    /// close that assumed "the rows are gone now" would leave the run drawn at
    /// zero height forever in those cases, with no span and no owner.
    static func membersSurvivedStructure(_ memberItems: [MessageListItem],
                                         in env: Environment) -> Bool {
        let live = env.items()
        for item in memberItems where live.contains(item) { return true }
        return false
    }

    @discardableResult
    static func run(_ request: Request, in env: Environment) -> Outcome {
        let cv = env.collectionView
        let tag = request.groupTag
        let log = { (message: String) in env.log("[ToolFold][Accordion] \(message) group=\(tag)") }

        if env.isReduceMotion() {
            log("fallback=reduce-motion")
            return .fallback("reduce-motion")
        }
        if env.isStreaming() {
            log("fallback=streaming")
            return .fallback("streaming")
        }

        var items = env.items()
        guard let headerIndex = items.firstIndex(of: request.item) else {
            return .invalid("header-miss")
        }
        var idxs = memberIndices(of: request.memberItems, in: items) ?? []
        if !request.expanding {
            // A close keeps the rows it is collapsing; they can only be gone
            // when something else already dropped them.
            if idxs.isEmpty { return .invalid("member-miss") }
        } else {
            // The member rows have to exist before they can be revealed. This
            // is the same structural apply the list always did; the rows are
            // then frozen and pulled back to reveal 0 inside this same turn,
            // before anything is drawn.
            if idxs.isEmpty {
                env.applyStructure("toolGroupToggle")
                UIView.performWithoutAnimation { cv.layoutIfNeeded() }
                items = env.items()
            }
            guard let h = items.firstIndex(of: request.item) else { return .invalid("header-miss-after-apply") }
            guard let found = memberIndices(of: request.memberItems, in: items), !found.isEmpty else {
                log("fallback=member-miss members=0/\(request.memberItems.count)")
                return .fallback("member-miss")
            }
            idxs = found
            return start(request, headerIndex: h, idxs: idxs, in: env)
        }
        return start(request, headerIndex: headerIndex, idxs: idxs, in: env)
    }

    private static func start(_ request: Request, headerIndex: Int, idxs: [Int],
                              in env: Environment) -> Outcome {
        let cv = env.collectionView
        let layout = env.layout
        let tag = request.groupTag
        let log = { (message: String) in env.log("[ToolFold][Accordion] \(message) group=\(tag)") }

        guard isContiguousSpan(idxs, headerIndex: headerIndex) else {
            // A run whose member rows are not one contiguous span right below
            // its header (an interleaved row the plan drew between them) cannot
            // be revealed as a window: keep the old instant switch rather than
            // animate the wrong rows.
            log("fallback=non-contiguous members=\(idxs.count)/\(request.memberItems.count)")
            return .fallback("non-contiguous")
        }

        // [T-toolgroup-accordion] Freeze MEASURED natural heights. A cached
        // height is not necessarily what the row really needs (a freshly
        // inserted block only has an estimate), and revealing a row to a guess
        // makes the frontier land in the wrong place and pop at the end.
        let items = env.items()
        let offScreen = idxs.filter { cv.cellForItem(at: IndexPath(item: $0, section: 0)) == nil }
        let probe = ToolGroupAccordionMeasurement.naturalHeights(
            rows: offScreen.map { (index: $0, item: items[$0]) },
            in: cv,
            configure: env.configureForMeasurement)
        var heights: [CGFloat] = []
        heights.reserveCapacity(idxs.count)
        var sources: [String: Int] = [:]
        var unmeasured = 0
        for idx in idxs {
            let ip = IndexPath(item: idx, section: 0)
            if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                let attrs = layout.layoutAttributesForItem(at: ip)
                    ?? UICollectionViewLayoutAttributes(forCellWith: ip)
                _ = cell.preferredLayoutAttributesFitting(attrs)
                // The cell's RECEIPT decides, never `height > 0.5`: the fitting
                // pass hands its input back unchanged from its off-collection
                // guard, its hosting-exception fallback and its generation race,
                // and that input is the layout's estimate.
                if let receipt = cell.heightReceipt {
                    layout.setMeasuredHeight(receipt.height, at: idx)
                    heights.append(receipt.height)
                    sources["visible-\(receipt.source.rawValue)", default: 0] += 1
                    continue
                }
            }
            if let cached = layout.cachedHeight(at: idx) {
                heights.append(cached)
                sources["list-cache", default: 0] += 1
                continue
            }
            if let value = probe.heights[idx] {
                layout.setMeasuredHeight(value, at: idx)
                heights.append(value)
                sources["probe", default: 0] += 1
                continue
            }
            heights.append(layout.naturalHeightForAccordion(at: idx))
            unmeasured += 1
        }
        log("natural measured=\(idxs.count - unmeasured) unmeasured=\(unmeasured) of \(idxs.count) probe=[\(probe.summary)] unhosted=\(probe.unhosted.count) src=\(sources)")
        // Only a fully measured run may animate: an estimate would be replaced
        // by the true height when the span clears, moving every row below it at
        // the very end of the flight ("pops"). Correct beats animated.
        guard unmeasured == 0 else {
            log("fallback=unmeasured unmeasured=\(unmeasured)")
            return .fallback("unmeasured")
        }
        let span = idxs[0]...(idxs[0] + idxs.count - 1)
        let plan = ToolGroupAccordionFlight.Plan(memberRange: span, naturalHeights: heights,
                                                 headerIndex: headerIndex,
                                                 anchorY: request.anchorY,
                                                 headerItem: request.item,
                                                 memberItems: request.memberItems)
        let flight = ToolGroupAccordionFlight(collectionView: cv, layout: layout)
        // [T-toolgroup-accordion] One transaction owns the takeover channel at a
        // time: the closure captures the flight (and through it the list), so
        // whatever a previous transaction left armed is dropped before this one
        // installs its own. `disarmAbortChannel` refuses a flight that never
        // armed the channel, so this can never clear an unrelated owner.
        env.currentFlight()?.disarmAbortChannel()
        env.storeFlight(flight)
        // Published for the other viewport owner (status-bar flight); see
        // MessageListLayout.toolGroupAccordionAbort.
        // Identity, not row counts: a row inserted ABOVE the run, a swap to
        // another session with the same row count, or a replaced span row all
        // keep the numbers valid while the indices now point at the wrong rows.
        flight.liveItems = { env.items() }
        // [T-toolgroup-collapse-finish] This transaction is the one that deletes
        // the member rows when the run closes, so it claims the close's terminal
        // geometry BEFORE the flight starts: `finish` then keeps the zero-reveal
        // window (and the clip) installed and hands the delete to us instead of
        // laying the natural heights out first. A flight that ends EXPANDED (or
        // is retargeted to expand) ignores the claim and keeps the old teardown.
        flight.ownsTerminalCollapseHandoff = true
        flight.armAbortChannel()
        layout.toolGroupAccordionAbort = {
            // The abort channel is reached from the layout's own takeover paths
            // (a status-bar flight starting, a structural conflict). Only the
            // flight this transaction started may be finished through it.
            guard env.currentFlight() === flight else { return }
            env.storeFlight(nil)
            // `finish` disarms this very closure through the flight's channel
            // ownership; doing it from inside the closure is safe because the
            // call itself retains it.
            flight.finish(.interrupted)
        }
        flight.start(plan, direction: request.expanding ? .expand : .collapse) { outcome in
            if env.currentFlight() === flight {
                env.storeFlight(nil)
                // Belt and suspenders: `finish` already disarmed the channel
                // this flight armed, and this line can only run while no newer
                // flight owns the store.
                env.layout.toolGroupAccordionAbort = nil
            }
            // [T-toolgroup-collapse-finish] Atomic terminal handoff of a close.
            //
            // The reveal window must die in the SAME synchronous step as the
            // structural commit, not one statement earlier and not one pass
            // later. `applySnapshot` does real preparation between its entry and
            // `dataSource.apply` (it re-plans the runs, remaps the height cache,
            // may end editing, and any of that may lay out) — with the window
            // cleared at the START of that work, the old member rows would be
            // laid out at their natural heights for the whole preparation, which
            // IS the rebound this task removes. So the transaction does not clear
            // anything itself: it publishes a ONE-SHOT handoff on the layout, and
            // `applySnapshot` consumes it immediately before the commit (see
            // `consumeToolGroupAccordionTerminalHandoff`). Then:
            //
            //   ... frames at reveal 0 → [preparation: window still installed,
            //   members still 0 high] → clear window → commit (one pass, new
            //   rows) → verify
            //
            // The claim is the flight's, and the side is the flight's FINAL
            // direction: a second tap that turned the flight around ends on the
            // side it really converged to.
            let closingTerminal = (outcome == .completed || outcome == .instant)
                && flight.finalDirection == .collapse
            var handoffCommitted = false
            if closingTerminal {
                env.layout.toolGroupAccordionTerminalHandoff = {
                    handoffCommitted = flight.commitTerminalHandoff()
                }
            }
            // The structure may only converge when the flight really reached
            // its end. `.interrupted` means a finger (or the status-bar flight)
            // owns the viewport, and `finish` has just cleared the span — the
            // member rows are back at their natural heights, so deleting them
            // right here would move everything below them under the drag.
            //
            // Which side of the run to settle is decided by the flight's FINAL
            // direction, never by `request.expanding`: a retarget flips the
            // direction mid-air, so the request's value is stale by definition.
            //  * an interrupted EXPAND already matches the business state (the
            //    member rows are in the list) — nothing to converge;
            //  * an interrupted CLOSE leaves an open run behind a closed
            //    business state, so it is handed to `deferConverge` and settled
            //    once nobody owns the viewport;
            //  * `.cancelled` means the list is going away / being rebuilt, and
            //    that rebuild derives the structure from the business state.
            switch outcome {
            case .completed, .instant:
                env.applyStructure("toolGroupAccordionEnd")
                if closingTerminal {
                    // The channel belongs to this transaction alone: whatever the
                    // apply did, it must not stay armed for some later commit.
                    env.layout.toolGroupAccordionTerminalHandoff = nil
                    if membersSurvivedStructure(request.memberItems, in: env) {
                        // The apply declined to run (a session load in flight) or
                        // re-planned the run back in: the rows are still there. A
                        // dead zero-height window must not stay on screen, so land
                        // the real geometry and let the deferred converge delete
                        // the rows at the first free viewport — the same path an
                        // interrupted close takes.
                        flight.commitTerminalHandoff()
                        flight.landNaturalGeometry()
                        env.deferConverge("toolGroupAccordionEnd-deferred")
                        log("end handoff=declined members-still-present settle=deferred committed=\(handoffCommitted)")
                    } else {
                        // The rows are gone. If the apply never reached its commit
                        // (no `applySnapshot`, e.g. a caller that rebuilt the
                        // snapshot itself) the window is still installed: drop it
                        // now, with no layout of its own and without touching a
                        // cell that no longer belongs to this plan.
                        flight.commitTerminalHandoff()
                        // Nothing moved: the members were already 0 high when the
                        // apply deleted them, so the header is exactly where the
                        // last frame left it and `restoreAnchor` writes no offset
                        // unless a legal clamp really requires it.
                        env.restoreAnchor(request.item, request.anchorY)
                    }
                } else {
                    env.restoreAnchor(request.item, request.anchorY)
                }
            case .interrupted:
                if flight.finalDirection == .collapse {
                    env.deferConverge("toolGroupAccordionEnd-deferred")
                }
            case .cancelled:
                break
            }
            log("end outcome=\(outcome.rawValue) structure=\(outcome == .completed || outcome == .instant ? "settled" : "deferred") handoff=\(closingTerminal ? (handoffCommitted ? "atomic" : "atomic-uncommitted") : "legacy") frames=\(flight.framesApplied) reveal=\(String(format: "%.3f", flight.reveal))")
        }
        // [T-toolgroup-accordion] The tapped row must show its NEW expanded
        // state from the first frame: the diffable apply above never
        // reconfigures an item whose identity did not change, and the row's
        // identity is the same in both states (see `Environment.refreshHeader`).
        // Called AFTER the flight installed its span, so the reconfigure's
        // layout cannot draw the member rows before the reveal window exists.
        env.refreshHeader(request.item)
        log("toggle expanded=\(request.expanding) members=\(request.memberItems.count) idx=\(request.oldIndex)→\(headerIndex) span=\(span.lowerBound)...\(span.upperBound) anchorY=\(String(format: "%.1f", request.anchorY)) mode=accordion")
        return .started(flight)
    }
}
