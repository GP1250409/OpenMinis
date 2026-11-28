//
//  ChatMailFoldUIKitTests.swift
//  MinisTests
//
//  [T-chat-mail-fold] REAL UIKit coverage for the chat's mail-style fold:
//  the shipping `MessageListLayout` (mail span), `SelfSizingCell` (top clip
//  window), `ChatMailFoldFlight` (frame driver) and `ChatMailFoldToggle`
//  (transaction) on a real windowed `UICollectionView`.
//
//  Rows are plain cells with PRE-SEEDED measured heights, so the geometry the
//  assertions read is the layout's, not a self-sizing guess: the question here
//  is the fold's geometry / end state / interruption, not text measurement.
//
//  Cases:
//   1. expand      — intermediate frames exist, the LAST child's top edge is
//                    the one clipped (mail order), the header does not move.
//   2. terminal    — span gone, natural heights restored, follower exactly at
//                    the expanded position, no hitch height.
//   3. close       — children at 0pt, then removed: the follower's Y is
//                    identical before and after the removal (the d48 hitch).
//   4. interrupt   — a drag (abort channel) lands the END state at once; the
//                    offset is not stolen from the finger.
//   5. reversal    — a second tap mid-flight retargets the SAME flight (one
//                    span, no restart) and ends closed.
//   6. reduce      — reduce motion: terminal state, zero frames.
//
import XCTest
import UIKit
@testable import Minis

@MainActor
final class ChatMailFoldUIKitTests: XCTestCase {

    // MARK: - Harness

    private final class Harness: NSObject, UICollectionViewDataSource {
        let window: UIWindow
        let cv: UICollectionView
        let layout = MessageListLayout()
        var items: [MessageListItem] = []
        var heights: [CGFloat] = []
        let messageId = UUID()
        let headerId = UUID()
        let memberIds = [UUID(), UUID(), UUID()]
        let followerId = UUID()
        /// Heights the rows would have at their natural size.
        let headerHeight: CGFloat = 44
        let memberHeights: [CGFloat] = [120, 80, 60]
        let followerHeight: CGFloat = 100
        var spacing: CGFloat { layout.itemSpacing }
        var reduceMotion = false
        var streaming = false
        var structureApplies = 0
        var logs: [String] = []

        override init() {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let vc = UIViewController()
            window.rootViewController = vc
            window.makeKeyAndVisible()
            layout.itemSpacing = 8
            cv = UICollectionView(frame: vc.view.bounds, collectionViewLayout: layout)
            cv.register(SelfSizingCell.self, forCellWithReuseIdentifier: "cell")
            super.init()
            cv.dataSource = self
            vc.view.addSubview(cv)
            cv.frame = vc.view.bounds
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! SelfSizingCell
            cell.backgroundColor = .clear
            return cell
        }

        /// Seeded heights: exactly what the coordinator's height memo hands the
        /// layout for content that was measured before.
        func seed(_ heights: [CGFloat]) {
            self.heights = heights
            for (i, h) in heights.enumerated() { layout.setMeasuredHeight(h, at: i) }
        }

        func expandedItems() -> [MessageListItem] {
            [.toolGroup(messageId, headerId)]
                + memberIds.map { MessageListItem.assistantBlock(messageId, $0) }
                + [.assistantBlock(messageId, followerId)]
        }

        func collapsedItems() -> [MessageListItem] {
            [.toolGroup(messageId, headerId), .assistantBlock(messageId, followerId)]
        }

        func expandedHeights() -> [CGFloat] { [headerHeight] + memberHeights + [followerHeight] }
        func collapsedHeights() -> [CGFloat] { [headerHeight, followerHeight] }

        /// The real structural apply the coordinator does (a rebuild from the
        /// business state), without touching any user data.
        func applyStructure(expanded: Bool, caller: String) {
            structureApplies += 1
            UIView.performWithoutAnimation {
                items = expanded ? expandedItems() : collapsedItems()
                cv.reloadData()
                seed(expanded ? expandedHeights() : collapsedHeights())
                layout.invalidateLayout()
                cv.layoutIfNeeded()
            }
        }

        func install(expanded: Bool) {
            items = expanded ? expandedItems() : collapsedItems()
            seed(expanded ? expandedHeights() : collapsedHeights())
            layout.invalidateLayout()
            cv.layoutIfNeeded()
        }

        func frame(of item: MessageListItem) -> CGRect? {
            guard let i = items.firstIndex(of: item) else { return nil }
            return layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame
        }

        func memberRange() -> ClosedRange<Int> {
            let first = 1
            return first...(first + memberIds.count - 1)
        }

        func toggleEnv() -> ChatMailFoldToggle.Environment {
            ChatMailFoldToggle.Environment(
                collectionView: cv,
                layout: layout,
                items: { [weak self] in self?.items ?? [] },
                applyStructure: { [weak self] caller in
                    guard let self else { return }
                    self.applyStructure(expanded: caller == "toolGroupToggle", caller: caller)
                },
                indexOf: { [weak self] item in self?.items.firstIndex(of: item) },
                configureForMeasurement: { _, _, _ in },
                refreshHeader: { _ in },
                storeFlight: { [weak self] flight in
                    guard let self else { return }
                    self.flight = flight
                },
                currentFlight: { [weak self] in self?.flight },
                isReduceMotion: { [weak self] in self?.reduceMotion ?? false },
                isStreaming: { [weak self] in self?.streaming ?? false },
                trailingSpacing: { [weak self] _ in self?.layout.itemSpacing ?? 8 },
                log: { [weak self] message in self?.logs.append(message) })
        }

        var flight: ChatMailFoldFlight?

        func request(expanding: Bool, anchorY: CGFloat) -> ChatMailFoldToggle.Request {
            ChatMailFoldToggle.Request(
                item: .toolGroup(messageId, headerId),
                memberItems: memberIds.map { MessageListItem.assistantBlock(messageId, $0) },
                expanding: expanding,
                oldIndex: 0,
                anchorY: anchorY,
                rowSpacing: layout.itemSpacing,
                groupTag: "fixture")
        }

        /// Let the display link run for `seconds` while the run loop turns.
        func spin(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
    }

    private var harness: Harness!

    override func setUp() async throws {
        harness = Harness()
    }

    override func tearDown() async throws {
        harness?.flight?.cancel()
        harness = nil
    }

    // MARK: - 1 + 2. Expand: intermediate frames, mail order, terminal state

    func testExpandUsesMailGeometryAndLandsExactly() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: false)
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let follower = MessageListItem.assistantBlock(h.messageId, h.followerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        let collapsedFollowerY = try XCTUnwrap(h.frame(of: follower)).minY

        let outcome = ChatMailFoldToggle.run(h.request(expanding: true, anchorY: headerY), in: h.toggleEnv())
        guard case .started(let flight) = outcome else {
            return XCTFail("mail transaction declined: \(outcome)")
        }
        XCTAssertEqual(flight.framesApplied, 1, "the start frame is applied before returning")
        XCTAssertTrue(flight.isRunning, "a real display link drives the fold")

        h.spin(0.12)
        XCTAssertGreaterThan(flight.framesApplied, 3, "intermediate frames exist (not an instant cut)")
        let midReveal = flight.reveal
        XCTAssertGreaterThan(midReveal, 0.01)
        XCTAssertLessThan(midReveal, 0.99)

        // MAIL ORDER: at a small reveal only the LAST child has content on
        // screen, and the clipped one is that child (top clipped), not the first.
        let range = h.memberRange()
        let lastIndex = range.upperBound
        let firstIndex = range.lowerBound
        let lastCell = h.cv.cellForItem(at: IndexPath(item: lastIndex, section: 0)) as? SelfSizingCell
        let firstCell = h.cv.cellForItem(at: IndexPath(item: firstIndex, section: 0)) as? SelfSizingCell
        XCTAssertNotNil(lastCell)
        XCTAssertEqual(lastCell?.accordionContentHeight, CGFloat(h.memberHeights[2]), accuracy: 0.5,
                       "the straddling child is laid out at its NATURAL height (no squash)")
        XCTAssertGreaterThan(lastCell?.mailFoldContentTopClip ?? 0, 1,
                             "the last child's TOP is hidden behind the header (mail order)")
        if midReveal < 0.35 {
            XCTAssertEqual(firstCell?.mailFoldContentTopClip ?? 0, 0)
            let firstFrame = try XCTUnwrap(h.frame(of: MessageListItem.assistantBlock(h.messageId, h.memberIds[0])))
            XCTAssertLessThanOrEqual(firstFrame.height, 0.5, "the first child has not appeared yet")
        }

        // The fixed header does not move while the block slides.
        let headerNow = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        XCTAssertEqual(headerNow, headerY, accuracy: 1.0, "header anchor drift")

        // Bottom edge / follower at reveal r: blockTop + total * r.
        // Every gap of the block — internal AND the one after the last child —
        // is inside the span, so the follower sits at blockTop + total * reveal.
        let total = h.memberHeights.reduce(0, +) + CGFloat(h.memberHeights.count) * h.layout.itemSpacing
        let blockTop = h.layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))!.frame.minY
        let followerMid = try XCTUnwrap(h.frame(of: follower)).minY
        XCTAssertEqual(followerMid, blockTop + total * flight.reveal, accuracy: 1.0,
                       "the following sibling moves with the block's bottom edge")

        // Terminal.
        h.spin(0.5)
        XCTAssertFalse(flight.isRunning)
        XCTAssertEqual(flight.lastOutcome, .completed)
        XCTAssertNil(h.layout.mailFoldSpan, "the span never survives a completed fold")
        XCTAssertNil(h.flight, "the transaction released the flight")
        let expandedFollowerY = try XCTUnwrap(h.frame(of: follower)).minY
        XCTAssertEqual(expandedFollowerY, blockTop + total, accuracy: 0.6,
                       "expanded: the follower sits exactly under the natural block")
        XCTAssertGreaterThan(expandedFollowerY, collapsedFollowerY)
        let headerEnd = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        XCTAssertEqual(headerEnd, headerY, accuracy: 1.0, "header anchor restored at the end")
        // No cell keeps a clip window.
        for i in h.memberRange() {
            let cell = h.cv.cellForItem(at: IndexPath(item: i, section: 0)) as? SelfSizingCell
            XCTAssertEqual(cell?.mailFoldContentTopClip ?? 0, 0)
            XCTAssertNil(cell?.accordionContentHeight)
        }
    }

    // MARK: - 3. Close: rows leave while they occupy no space

    func testCloseRemovesRowsWithoutMovingTheFollower() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: true)
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let follower = MessageListItem.assistantBlock(h.messageId, h.followerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        let expandedFollowerY = try XCTUnwrap(h.frame(of: follower)).minY

        let outcome = ChatMailFoldToggle.run(h.request(expanding: false, anchorY: headerY), in: h.toggleEnv())
        guard case .started(let flight) = outcome else {
            return XCTFail("close declined: \(outcome)")
        }
        XCTAssertEqual(flight.reveal, 1, accuracy: 0.001, "a close starts at the resting geometry")

        h.spin(0.14)
        XCTAssertGreaterThan(flight.framesApplied, 3)
        XCTAssertLessThan(flight.reveal, 0.99)
        // While closing, the top child has already gone behind the header.
        let firstIndex = h.memberRange().lowerBound
        let firstFrame = try XCTUnwrap(h.layout.layoutAttributesForItem(at: IndexPath(item: firstIndex, section: 0))?.frame)
        XCTAssertLessThan(firstFrame.height, CGFloat(h.memberHeights[0]) - 1,
                          "the first child disappears first (mail order)")

        h.spin(0.5)
        XCTAssertEqual(flight.lastOutcome, .completed)
        XCTAssertEqual(flight.reveal, 0, accuracy: 0.001)
        // The structural apply ran exactly once and removed the children.
        XCTAssertEqual(h.structureApplies, 1)
        XCTAssertEqual(h.items, h.collapsedItems())
        XCTAssertNil(h.layout.mailFoldSpan)
        // d48: the follower did NOT move when the (invisible) rows went away.
        let collapsedFollowerY = try XCTUnwrap(h.frame(of: follower)).minY
        XCTAssertEqual(collapsedFollowerY, expandedFollowerY - totalBlock(h),
                       accuracy: 0.6, "the follower follows the block's bottom edge, once")
        let headerEnd = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        XCTAssertEqual(headerEnd, headerY, accuracy: 1.0)
    }

    private func totalBlock(_ h: Harness) -> CGFloat {
        h.memberHeights.reduce(0, +) + CGFloat(h.memberHeights.count) * h.layout.itemSpacing
    }

    // MARK: - 4. Interruption (drag / status-bar takeover)

    func testInterruptionLandsTheEndStateAtOnceAndKeepsTheOffset() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: false)
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        let outcome = ChatMailFoldToggle.run(h.request(expanding: true, anchorY: headerY), in: h.toggleEnv())
        guard case .started(let flight) = outcome else {
            return XCTFail("expand declined: \(outcome)")
        }
        h.spin(0.10)
        let framesBefore = flight.framesApplied
        let offsetBefore = h.cv.contentOffset.y
        // The finger / status-bar flight takes the viewport through the channel
        // the delegate calls.
        XCTAssertNotNil(h.layout.toolGroupAccordionAbort)
        h.layout.abortToolGroupAccordion()

        XCTAssertFalse(flight.isRunning)
        XCTAssertEqual(flight.lastOutcome, .interrupted)
        XCTAssertEqual(flight.framesApplied, framesBefore, "no frame ran after the takeover")
        XCTAssertNil(h.layout.mailFoldSpan, "the interrupted fold still lands a terminal span")
        XCTAssertEqual(h.cv.contentOffset.y, offsetBefore, accuracy: 0.5,
                       "an interrupted fold never steals the finger's offset")
        // The business end state is expanded and every child is at its natural height.
        for (k, i) in h.memberRange().enumerated() {
            let frame = try XCTUnwrap(h.layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame)
            XCTAssertEqual(frame.height, CGFloat(h.memberHeights[k]), accuracy: 0.6)
        }
    }

    // MARK: - 5. Rapid reversal retargets the same flight

    func testRapidReversalRetargetsInsteadOfRestarting() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: false)
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        guard case .started(let flight) = ChatMailFoldToggle.run(h.request(expanding: true, anchorY: headerY), in: h.toggleEnv()) else {
            return XCTFail("expand declined")
        }
        h.spin(0.10)
        let revealBefore = flight.reveal
        let framesBefore = flight.framesApplied
        XCTAssertGreaterThan(revealBefore, 0.01)

        // Second tap: close while the open film is still running.
        let second = ChatMailFoldToggle.run(h.request(expanding: false, anchorY: headerY), in: h.toggleEnv())
        guard case .started(let sameFlight) = second else {
            return XCTFail("reversal declined: \(second)")
        }
        XCTAssertTrue(sameFlight === flight, "the reversal reuses the live flight")
        XCTAssertEqual(sameFlight.finalDirection.isExpanding, false)
        XCTAssertGreaterThanOrEqual(sameFlight.reveal, revealBefore - 0.05,
                                    "no restart from 0: the film continues from where it was")
        XCTAssertGreaterThanOrEqual(sameFlight.framesApplied, framesBefore)
        XCTAssertEqual(h.structureApplies, 1, "only the opening tap applied the structure")

        h.spin(0.5)
        XCTAssertEqual(sameFlight.lastOutcome, .completed)
        XCTAssertEqual(sameFlight.reveal, 0, accuracy: 0.001)
        XCTAssertEqual(h.items, h.collapsedItems(), "the reversed fold landed closed")
        XCTAssertNil(h.layout.mailFoldSpan)
    }

    // MARK: - 6. Reduce motion: terminal state, no frames

    func testReduceMotionIsInstant() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: false)
        h.reduceMotion = true
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        // Reduce motion declines the mail flight: the caller's instant switch runs.
        let outcome = ChatMailFoldToggle.run(h.request(expanding: true, anchorY: headerY), in: h.toggleEnv())
        guard case .fallback(let reason) = outcome else {
            return XCTFail("reduce motion must decline the flight, got \(outcome)")
        }
        XCTAssertEqual(reason, "reduce-motion")
        XCTAssertNil(h.layout.mailFoldSpan)
        XCTAssertTrue(h.logs.contains { $0.contains("fallback=reduce-motion") })
    }

    // MARK: - 7. Streaming declines the flight

    func testStreamingFallsBack() throws {
        let h = try XCTUnwrap(harness)
        h.install(expanded: false)
        h.streaming = true
        let header = MessageListItem.toolGroup(h.messageId, h.headerId)
        let headerY = try XCTUnwrap(h.frame(of: header)).minY - h.cv.contentOffset.y
        let outcome = ChatMailFoldToggle.run(h.request(expanding: false, anchorY: headerY), in: h.toggleEnv())
        guard case .fallback(let reason) = outcome else {
            return XCTFail("streaming must decline the flight, got \(outcome)")
        }
        XCTAssertEqual(reason, "streaming")
        XCTAssertNil(h.layout.mailFoldSpan)
    }
}
