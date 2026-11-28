//
//  ChatMailFoldToggle.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-chat-mail-fold] The TRANSACTION of one mail-style fold of a chat block.
//
//  The coordinator owns the business half of a tap (the expanded / manually
//  folded sets, `scrollMode`, the status-bar handoff) and then hands the list
//  to this type, which does the rest with production code only:
//
//    prove the children are ONE contiguous window under the fixed header →
//    freeze their real natural heights →
//    install the span at the START reveal (0 for open, 1 for close) →
//    run the ChatMailFoldFlight →
//    SETTLE: terminal reveal + structural apply + span clear in ONE
//    non-animated block, then put the tapped header back.
//
//  Why the settle is one block: the cancelled 2026-11-19 accordion restored
//  the children's full natural heights, laid out, and only THEN deleted the
//  rows on a close. That intermediate layout is the end-of-close hitch the user
//  reported (run d48). Here a close settles with the rows still at height 0, so
//  removing them moves nothing; an open settles with the rows already at their
//  natural heights, so clearing the span moves nothing either.
//
//  Shared on purpose: the coordinator's `toggleToolGroup` and the UIKit
//  harness (`scripts/chat-mail-fold-uikit-tests/`) call the SAME `run(_:in:)`.
//

import SwiftUI
import UIKit

enum ChatMailFoldToggle {

    /// What the transaction needs from the list it runs in.
    struct Environment {
        let collectionView: UICollectionView
        let layout: MessageListLayout
        /// Rows as they are right now (the diffable snapshot's items).
        var items: () -> [MessageListItem]
        /// Commit the business structure (the coordinator's `applySnapshot`).
        var applyStructure: (String) -> Void
        /// Index of a row in the CURRENT items.
        var indexOf: (MessageListItem) -> Int?
        /// The PRODUCTION cell configuration in measurement mode
        /// (`writesListState: false`); see `ToolGroupAccordionMeasurement`.
        var configureForMeasurement: (SelfSizingCell, MessageListItem, IndexPath) -> Void
        /// Re-render the tapped header row with its NEW expanded state (a
        /// diffable apply never reconfigures an item whose identity did not
        /// change).
        var refreshHeader: (MessageListItem) -> Void
        /// Store / clear the live flight on the owner.
        var storeFlight: (ChatMailFoldFlight?) -> Void
        /// The flight the owner currently holds (identity check).
        var currentFlight: () -> ChatMailFoldFlight?
        var isReduceMotion: () -> Bool
        /// Streaming: the list is re-applied continuously, so an animation here
        /// would be cut short by the next update — the caller uses its instant
        /// switch.
        var isStreaming: () -> Bool
        var log: (String) -> Void
    }

    struct Request {
        /// The `.toolGroup` header row the user tapped.
        let item: MessageListItem
        /// The child rows, in order.
        let memberItems: [MessageListItem]
        let expanding: Bool
        /// Where the header was when the tap arrived (diagnostics only).
        let oldIndex: Int
        /// The header's top in the viewport, to be put back.
        let anchorY: CGFloat
        /// Gap between two children (the layout's item spacing at this width).
        let rowSpacing: CGFloat
        let groupTag: String
    }

    enum Outcome {
        /// The flight is running; its end handler settles the structure.
        case started(ChatMailFoldFlight)
        /// The transaction declined; the caller must use its instant switch.
        case fallback(String)
        /// The list does not hold what the tap was about.
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
        guard let first = idxs.first, !idxs.isEmpty, first > headerIndex else { return false }
        return idxs == Array(first...(first + idxs.count - 1))
    }

    @discardableResult
    static func run(_ request: Request, in env: Environment) -> Outcome {
        let cv = env.collectionView
        let tag = request.groupTag
        let log = { (message: String) in env.log("[MailFold] \(message) group=\(tag)") }

        if env.isReduceMotion() { log("fallback=reduce-motion"); return .fallback("reduce-motion") }
        if env.isStreaming() { log("fallback=streaming"); return .fallback("streaming") }

        var items = env.items()
        guard var headerIndex = items.firstIndex(of: request.item) else { return .invalid("header-miss") }
        var idxs = memberIndices(of: request.memberItems, in: items) ?? []

        if request.expanding {
            // The children have to exist before they can slide out. This is the
            // same structural apply the list always did; the rows are pulled to
            // reveal 0 inside this same turn, before anything is drawn.
            if idxs.isEmpty {
                env.applyStructure("toolGroupToggle")
                UIView.performWithoutAnimation { cv.layoutIfNeeded() }
                items = env.items()
            }
            guard let h = items.firstIndex(of: request.item) else { return .invalid("header-miss-after-apply") }
            headerIndex = h
            guard let found = memberIndices(of: request.memberItems, in: items), !found.isEmpty else {
                log("fallback=member-miss members=0/\(request.memberItems.count)")
                return .fallback("member-miss")
            }
            idxs = found
        } else if idxs.isEmpty {
            // A close keeps the rows it is collapsing; gone means something
            // else already dropped them — the business state is already right.
            return .invalid("member-miss")
        }

        guard isContiguousSpan(idxs, headerIndex: headerIndex) else {
            log("fallback=non-contiguous members=\(idxs.count)/\(request.memberItems.count)")
            return .fallback("non-contiguous")
        }
        return start(request, headerIndex: headerIndex, idxs: idxs, in: env)
    }

    private static func start(_ request: Request, headerIndex: Int, idxs: [Int],
                              in env: Environment) -> Outcome {
        let cv = env.collectionView
        let layout = env.layout
        let tag = request.groupTag
        let log = { (message: String) in env.log("[MailFold] \(message) group=\(tag)") }

        let items = env.items()
        guard idxs.allSatisfy({ $0 < items.count }) else { return .invalid("stale-span") }

        // [T-chat-mail-fold] Freeze MEASURED natural heights. A cached height
        // is not necessarily what the row really needs (a freshly inserted
        // block only has an estimate), and sliding a row to a guess makes the
        // block's bottom edge land in the wrong place and pop at the end.
        // On a close the drawn height is the ground truth, so the cache wins
        // there: the first frame must be pixel-identical to the resting list.
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
            if !request.expanding, let cached = layout.cachedHeight(at: idx), cached > 0.5 {
                heights.append(cached)
                sources["list-cache", default: 0] += 1
                continue
            }
            if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                let attrs = layout.layoutAttributesForItem(at: ip)
                    ?? UICollectionViewLayoutAttributes(forCellWith: ip)
                _ = cell.preferredLayoutAttributesFitting(attrs)
                // The cell's RECEIPT decides, never `height > 0.5`: the fitting
                // pass hands its input back unchanged from its off-collection
                // guard, its hosting-exception fallback and its generation
                // race, and that input is the layout's estimate.
                if let receipt = cell.heightReceipt {
                    heights.append(receipt.height)
                    sources["visible-\(receipt.source.rawValue)", default: 0] += 1
                    continue
                }
            }
            if let cached = layout.cachedHeight(at: idx), cached > 0.5 {
                heights.append(cached)
                sources["list-cache", default: 0] += 1
                continue
            }
            if let value = probe.heights[idx] {
                heights.append(value)
                sources["probe", default: 0] += 1
                continue
            }
            heights.append(layout.naturalHeightForAccordion(at: idx))
            unmeasured += 1
        }
        log("natural measured=\(idxs.count - unmeasured) unmeasured=\(unmeasured) probe=[\(probe.summary)] unhosted=\(probe.unhosted.count) src=\(sources)")
        // Only a fully measured run may animate: an estimate would be replaced
        // by the true height when the span clears, moving every row below it at
        // the very end ("pops"). Correct beats animated.
        guard unmeasured == 0 else {
            log("fallback=unmeasured unmeasured=\(unmeasured)")
            return .fallback("unmeasured")
        }

        let spanRange = idxs[0]...(idxs[0] + idxs.count - 1)
        let startReveal: CGFloat = request.expanding ? 0 : 1
        // Freeze the natural heights in the cache FIRST: clearing the span at
        // reveal 1 must be a no-op, and a structural apply during the flight
        // must not re-measure these rows into something else.
        for (k, idx) in idxs.enumerated() { layout.setMeasuredHeight(heights[k], at: idx) }

        let span = MessageListLayout.MailFoldSpan(lowerBound: spanRange.lowerBound,
                                                  naturalHeights: heights,
                                                  rowSpacing: max(0, request.rowSpacing),
                                                  reveal: startReveal)
        let wasSuppressed = layout.suppressContentOffsetAdjustment
        layout.suppressContentOffsetAdjustment = true
        UIView.performWithoutAnimation {
            layout.setMailFold(span)
            layout.invalidateLayout()
            cv.layoutIfNeeded()
        }
        layout.suppressContentOffsetAdjustment = wasSuppressed

        let plan = ChatMailFoldFlight.Plan(memberRange: spanRange,
                                           naturalHeights: heights,
                                           rowSpacing: max(0, request.rowSpacing),
                                           headerIndex: headerIndex,
                                           anchorY: request.anchorY,
                                           headerItem: request.item,
                                           memberItems: request.memberItems)
        let flight = ChatMailFoldFlight(collectionView: cv, layout: layout)
        // One transaction owns the takeover channel at a time.
        env.currentFlight()?.cancel()
        env.storeFlight(flight)
        flight.liveItems = { env.items() }
        // Published for the other viewport owner (status-bar flight, drag); see
        // MessageListLayout.toolGroupAccordionAbort (slice-safe channel).
        layout.toolGroupAccordionAbort = {
            guard env.currentFlight() === flight else { return }
            flight.finish(.interrupted)
        }
        flight.start(plan, direction: request.expanding ? .expand : .collapse) { outcome in
            settle(flight, outcome: outcome, request: request, in: env)
        }
        // The tapped header must show its NEW state from the first frame.
        env.refreshHeader(request.item)
        log("toggle expanded=\(request.expanding) members=\(request.memberItems.count) idx=\(request.oldIndex)→\(headerIndex) span=\(spanRange.lowerBound)...\(spanRange.upperBound) anchorY=\(String(format: "%.1f", request.anchorY)) mode=mail")
        return .started(flight)
    }

    /// Land the END STATE of a terminated flight in ONE non-animated block.
    ///
    /// `finalDirection` (never the tap's direction) decides which side the
    /// block settles on: a retarget flips it mid-air, so the request's value is
    /// stale by definition.
    static func settle(_ flight: ChatMailFoldFlight, outcome: ChatMailFoldFlight.Outcome,
                       request: Request, in env: Environment) {
        let cv = env.collectionView
        let layout = env.layout
        let expanding = flight.finalDirection.isExpanding
        let tag = request.groupTag
        let log = { (message: String) in env.log("[MailFold] \(message) group=\(tag)") }

        if env.currentFlight() === flight { env.storeFlight(nil) }
        if env.currentFlight() == nil { layout.toolGroupAccordionAbort = nil }

        let terminal: CGFloat = ChatMailFold.terminalReveal(expanding: expanding)
        let wasSuppressed = layout.suppressContentOffsetAdjustment
        layout.suppressContentOffsetAdjustment = true
        UIView.performWithoutAnimation {
            // 1. Terminal window while the rows are still owned by the span.
            //    Close: every child is at height 0 / hidden → nothing to see.
            //    Open: every child is already at its frozen natural height.
            layout.updateMailFoldReveal(terminal)
            layout.invalidateLayout()
            cv.layoutIfNeeded()
            // 2. Structure follows the business state. A close deletes the rows
            //    while they occupy no space, which is what makes the removal
            //    invisible (no d48 hitch).
            if !expanding { env.applyStructure("mailFoldEnd") }
            // 3. Nothing depends on the span any more.
            layout.clearMailFold()
            layout.invalidateLayout()
            cv.layoutIfNeeded()
        }
        layout.suppressContentOffsetAdjustment = wasSuppressed

        // 4. Viewport: a completed fold puts the fixed header back exactly
        //    where the user tapped it (clamped into the legal window); an
        //    interrupted one only clamps, because the finger owns the offset.
        if let idx = env.indexOf(request.item),
           let attrs = layout.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)) {
            let minOff = -cv.adjustedContentInset.top
            let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let desired = (outcome == .interrupted)
                ? cv.contentOffset.y
                : ChatMailFold.anchoredOffset(headerY: attrs.frame.minY, anchorY: request.anchorY,
                                              contentHeight: cv.contentSize.height,
                                              viewportHeight: cv.bounds.height,
                                              topInset: cv.adjustedContentInset.top,
                                              bottomInset: cv.adjustedContentInset.bottom)
            let target = min(max(desired, minOff), maxOff)
            if abs(target - cv.contentOffset.y) > 0.5 {
                cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
            }
        }
        log("end outcome=\(outcome.rawValue) final=\(expanding ? "open" : "closed") frames=\(flight.framesApplied) reveal=\(String(format: "%.3f", flight.reveal)) retired=\(flight.retiredReason ?? "-")")
    }
}
