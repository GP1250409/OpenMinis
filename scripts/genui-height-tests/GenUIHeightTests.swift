import UIKit
import SwiftUI

/// Regression suite for a show_ui card's state commit.
///
/// Drives the REAL production code: `MessageListLayout` + `SelfSizingCell`
/// (verbatim), `MinisUIStore` / `MinisUIStateUpdate` (verbatim slice) and
/// `commitGenUIStateChange` (+ its async verify) from
/// `MessageListV3Coordinator+GenUI.swift`, wrapped in the fixture coordinator.
final class GenUIHeightTests {
    func makeHarness(long: Bool = false, sessionId: String? = "session-A",
                     cardBlockId: UUID? = nil) -> GenUIListHarness {
        var card = GenUICardState()
        card.long = long
        let rows = [
            GenUIRowModel(kind: .header, text: "Assistant header row"),
            GenUIRowModel(kind: .text, text: "第一段回答，用来在卡片上方制造真实内容，让卡片下方仍然可以滚动。"),
            GenUIRowModel(kind: .card, card: card, blockId: cardBlockId),
            GenUIRowModel(kind: .text, text: "卡片之后的解释文字，保证下方有内容、offset 有上下限。"),
            GenUIRowModel(kind: .footer, text: "footer"),
        ]
        return GenUIListHarness(rows: rows, targetIndex: 2, sessionId: sessionId)
    }

    // MARK: - 1. Choice + verdict grows

    func choiceFeedbackGrows() {
        let h = makeHarness()
        let before = h.rowHeight(h.targetIndex)
        let topHeader = h.topOf(0)
        let topUser = h.topOf(1)
        let offset = h.offset
        CheckLog.check("choiceFeedbackGrows/baseline-real", before > 40 && abs(before - GenUIListHarness.coarseEstimate) > 1,
                       "h=\(before)")
        CheckLog.check("choiceFeedbackGrows/baseline-offset-legal", h.isLegalOffset(offset),
                       "offset=\(offset) min=\(-h.collection.contentInset.top) max=\(h.maxOffset)")
        let consumedBefore = h.productionConfigureCount
        h.cardUpdate { s in
            var s = s
            s.choice = "绿色"
            s.feedback = "答对了：绿色可见光的波长最短，红色最长。"
            return s
        }
        CheckLog.check("choiceFeedbackGrows/consumed-by-list", h.productionConfigureCount > consumedBefore,
                       "production configureCell runs=\(h.productionConfigureCount - consumedBefore) (0 = store fallback, no re-measure)")
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        let after = h.rowHeight(h.targetIndex)
        let drift = h.topOf(1) - topUser
        print("GENUI_CHOICE_DRIFT \(h.topOf(1) - topUser)")
        CheckLog.check("choiceFeedbackGrows/taller", after > before + 10, "\(before) -> \(after)")
        CheckLog.check("choiceFeedbackGrows/header-fixed", abs(h.topOf(0) - topHeader) <= 0.5,
                       "drift=\(h.topOf(0) - topHeader)")
        CheckLog.check("choiceFeedbackGrows/row-above-fixed", abs(drift) <= 0.5, "drift=\(drift)")
        CheckLog.check("choiceFeedbackGrows/offset-legal",
                       h.isLegalOffset(h.offset) && (abs(h.offset - offset) <= 0.5 || h.offset == -h.collection.contentInset.top || h.offset == h.maxOffset),
                       "offset \(offset) -> \(h.offset) max=\(h.maxOffset)")
        CheckLog.check("choiceFeedbackGrows/state-written", h.rows[h.targetIndex].card.choice == "绿色")
    }

    // MARK: - 2. Long card, top already off screen

    func longCardOffscreenKeepsOffset() {
        let h = makeHarness(long: true)
        h.scrollPastCardTop(by: 260)
        let offset = h.offset
        let cardTop = h.topOf(h.targetIndex)
        guard cardTop < -40 else {
            CheckLog.fail("longCardOffscreenKeepsOffset/setup (cardTop=\(cardTop))")
            return
        }
        guard h.targetCell != nil else {
            CheckLog.fail("longCardOffscreenKeepsOffset/cell-visible")
            return
        }
        h.cardUpdate { s in
            var s = s
            s.choice = "蓝色"
            s.feedback = "答案已记录。"
            return s
        }
        h.layoutNow(); h.pump(0.3); h.layoutNow()
        let delta = h.offset - offset
        print("GENUI_OFFSCREEN_DRIFT \(h.topOf(h.targetIndex) - cardTop)")
        print("GENUI_OFFSCREEN_OFFSET_DELTA \(delta)")
        CheckLog.check("longCardOffscreenKeepsOffset/offset-kept", abs(delta) <= 0.5,
                       "\(offset) -> \(h.offset) (max=\(h.maxOffset))")
        CheckLog.check("longCardOffscreenKeepsOffset/state", h.rows[h.targetIndex].card.choice == "蓝色")
        CheckLog.check("longCardOffscreenKeepsOffset/no-reveal", h.topOf(h.targetIndex) < -20,
                       "cardTop=\(h.topOf(h.targetIndex)) (a reveal-to-bottom would put it on screen)")
        // The bounded async verify must not drag the viewport back to a stale
        // offset captured at commit time: scrolling after the commit wins.
        h.collection.setContentOffset(CGPoint(x: 0, y: min(h.maxOffset, h.offset + 60)), animated: false)
        h.layoutNow(); h.pump(0.35); h.layoutNow()
        CheckLog.check("longCardOffscreenKeepsOffset/stale-verify-no-replay",
                       abs(h.offset - (offset + 60)) <= 1 || abs(h.offset - h.maxOffset) <= 1,
                       "offset=\(h.offset) expected≈\(offset + 60) max=\(h.maxOffset)")
    }

    // MARK: - 3. Reset shrinks back

    func resetShrinksBack() {
        let h = makeHarness()
        let before = h.rowHeight(h.targetIndex)
        let offset = h.offset
        h.cardUpdate { s in var s = s; s.choice = "红色"; s.feedback = "先答一次，让卡片长高。"; return s }
        h.layoutNow(); h.pump(0.2); h.layoutNow()
        let grown = h.rowHeight(h.targetIndex)
        h.cardUpdate { s in var s = s; s.choice = ""; s.feedback = ""; return s }
        h.layoutNow(); h.pump(0.3); h.layoutNow()
        let shrunk = h.rowHeight(h.targetIndex)
        let drift = h.offset - offset
        print("GENUI_RESET_DRIFT \(drift)")
        CheckLog.check("resetShrinksBack/grew-first", grown > before + 10, "\(before) -> \(grown)")
        CheckLog.check("resetShrinksBack/shrunk", abs(shrunk - before) <= 2, "\(grown) -> \(shrunk), baseline \(before)")
        CheckLog.check("resetShrinksBack/offset-legal", h.isLegalOffset(h.offset) && abs(drift) <= 0.5,
                       "offset \(offset) -> \(h.offset)")
    }

    // MARK: - 4. Segmented: pure value, same height, no geometry change

    func segmentedPureValueNoGeometry() {
        let h = makeHarness()
        h.cardUpdate { s in var s = s; s.choice = "绿色"; s.feedback = "基线"; return s }
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        let height = h.rowHeight(h.targetIndex)
        let offset = h.offset
        let content = h.contentHeight
        let invalidations = h.layout.invalidateCount
        h.cardUpdate { s in var s = s; s.segmented = "年"; return s }
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        print("GENUI_SEGMENTED_GEOMETRY \(height == h.rowHeight(h.targetIndex) ? "same" : "changed")")
        CheckLog.check("segmented/same-height", abs(h.rowHeight(h.targetIndex) - height) <= 0.5,
                       "\(height) -> \(h.rowHeight(h.targetIndex))")
        CheckLog.check("segmented/offset", abs(h.offset - offset) <= 0.5, "\(offset) -> \(h.offset)")
        CheckLog.check("segmented/content-size", abs(h.contentHeight - content) <= 0.5,
                       "\(content) -> \(h.contentHeight)")
        CheckLog.check("segmented/no-extra-invalidate", h.layout.invalidateCount == invalidations,
                       "invalidations \(invalidations) -> \(h.layout.invalidateCount)")
        CheckLog.check("segmented/state", h.rows[h.targetIndex].card.segmented == "年")
    }

    // MARK: - 5. Rapid repeated taps

    func rapidRepeatedState() {
        let h = makeHarness()
        let before = h.rowHeight(h.targetIndex)
        let offset = h.offset
        for _ in 0..<3 {
            h.cardUpdate { s in var s = s; s.choice = "绿色"; s.feedback = "重复点同一项。"; return s }
        }
        let peak = h.rowHeight(h.targetIndex)
        h.layoutNow(); h.pump(0.3); h.layoutNow()
        let after = h.rowHeight(h.targetIndex)
        CheckLog.check("rapidRepeatedState/grew-once", after > before + 10, "\(before) -> \(after)")
        CheckLog.check("rapidRepeatedState/no-double-growth", abs(after - peak) <= 0.5 || peak <= before,
                       "peak=\(peak) after=\(after)")
        CheckLog.check("rapidRepeatedState/offset", abs(h.offset - offset) <= 0.5, "\(offset) -> \(h.offset)")
        CheckLog.check("rapidRepeatedState/state", h.rows[h.targetIndex].card.feedback == "重复点同一项。")
        // The async verify must not replay a stale offset.
        h.pump(0.4); h.layoutNow()
        CheckLog.check("rapidRepeatedState/verify-no-replay", abs(h.offset - offset) <= 0.5,
                       "\(offset) -> \(h.offset)")
    }

    // MARK: - 6. Slider live then commit

    func sliderLiveThenCommit() {
        let h = makeHarness()
        let height = h.rowHeight(h.targetIndex)
        let offset = h.offset
        let invalidations = h.layout.invalidateCount
        h.sliderLive(80)
        h.layoutNow(); h.pump(0.1); h.layoutNow()
        print("GENUI_SLIDER_LIVE_MEASURES \(h.layout.invalidateCount - invalidations)")
        CheckLog.check("sliderLive/no-layout", h.layout.invalidateCount == invalidations,
                       "invalidations \(invalidations) -> \(h.layout.invalidateCount)")
        CheckLog.check("sliderLive/height", abs(h.rowHeight(h.targetIndex) - height) <= 0.5,
                       "\(height) -> \(h.rowHeight(h.targetIndex))")
        CheckLog.check("sliderLive/state", h.rows[h.targetIndex].card.slider == 80)
        h.sliderCommit()
        h.layoutNow(); h.pump(0.3); h.layoutNow()
        CheckLog.check("sliderCommit/real-height", abs(h.rowHeight(h.targetIndex) - h.measuredCardHeight()) <= 0.5,
                       "row=\(h.rowHeight(h.targetIndex)) fitted=\(h.measuredCardHeight())")
        CheckLog.check("sliderCommit/offset", abs(h.offset - offset) <= 0.5, "\(offset) -> \(h.offset)")
        CheckLog.check("sliderCommit/state", h.rows[h.targetIndex].card.slider == 80)
    }

    // MARK: - 7. No list mounted: fallback keeps the state

    func noListFallbackKeepsState() {
        let h = makeHarness()
        // Detach the list: the update must be applied exactly once by the
        // store's own no-animation fallback (production: no mounted list).
        h.coordinator.viewController = nil
        var runs = 0
        let row = h.rows[h.targetIndex]
        let after = { () -> GenUICardState in var s = row.card; s.choice = "红色"; return s }()
        MinisUIStore.update(blockId: row.id, sessionId: h.sessionId) {
            runs += 1
            row.card = after
        }
        print("GENUI_FALLBACK_RUNS \(runs)")
        CheckLog.check("noListFallback/runs-once", runs == 1, "runs=\(runs)")
        CheckLog.check("noListFallback/state", row.card.choice == "红色")
    }

    // MARK: - 8. Session mismatch is not consumed

    func sessionMismatchNotConsumed() {
        let h = makeHarness()
        let before = h.rowHeight(h.targetIndex)
        let offset = h.offset
        let invalidations = h.layout.invalidateCount
        var runs = 0
        let row = h.rows[h.targetIndex]
        let after = { () -> GenUICardState in var s = row.card; s.choice = "蓝色"; s.feedback = "别的会话"; return s }()
        MinisUIStore.update(blockId: row.id, sessionId: "session-B") {
            runs += 1
            row.card = after
        }
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        CheckLog.check("sessionMismatch/not-consumed", runs == 1, "the store fallback, not the list, must apply it (runs=\(runs))")
        CheckLog.check("sessionMismatch/no-layout", h.layout.invalidateCount == invalidations,
                       "invalidations \(invalidations) -> \(h.layout.invalidateCount)")
        CheckLog.check("sessionMismatch/height", abs(h.rowHeight(h.targetIndex) - before) <= 0.5,
                       "\(before) -> \(h.rowHeight(h.targetIndex))")
        CheckLog.check("sessionMismatch/offset", abs(h.offset - offset) <= 0.5)
        CheckLog.check("sessionMismatch/state", row.card.feedback == "别的会话")
    }

    // MARK: - 9. No layer animation around the commit

    func noLayerAnimations() {
        let h = makeHarness()
        let offset = h.offset
        CATransaction.setDisableActions(false)
        h.cardUpdate { s in var s = s; s.choice = "绿色"; s.feedback = "检查帧动画。"; return s }
        let cellAnimations = h.targetCell?.contentView.layer.animationKeys() ?? []
        let listAnimations = h.collection.layer.animationKeys() ?? []
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        let animated = cellAnimations.count + listAnimations.count
        print("GENUI_LAYER_ANIMATIONS \(animated)")
        CheckLog.check("noLayerAnimations/none", animated == 0, "cell=\(cellAnimations) list=\(listAnimations)")
        CheckLog.check("noLayerAnimations/offset", abs(h.offset - offset) <= 0.5, "\(offset) -> \(h.offset)")
        CheckLog.check("noLayerAnimations/settled", h.targetCell?.contentView.layer.animationKeys() == nil)
    }

    // MARK: - 10. An old real height never falls back to the coarse estimate

    func oldRealHeightNeverEstimate() {
        let h = makeHarness()
        let baseline = h.rowHeight(h.targetIndex)
        let samplesBefore = h.estimatedHeightsPublished().count
        h.cardUpdate { s in var s = s; s.choice = "绿色"; s.feedback = "真实高度必须保持到新的真实高度出现。"; return s }
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        let samples = Array(h.estimatedHeightsPublished().dropFirst(samplesBefore))
        let sawEstimate = samples.contains { abs($0 - GenUIListHarness.coarseEstimate) <= 0.5
            || abs($0 - GenUIListHarness.precalcEstimate) <= 0.5 }
        print("GENUI_ESTIMATE_FALLBACK \(sawEstimate ? 1 : 0)")
        CheckLog.check("oldRealHeight/samples-nonempty", !samples.isEmpty,
                       "published heights after baseline=\(samples.count) (empty = the layout never re-published, assertion would be vacuous)")
        CheckLog.check("oldRealHeight/not-estimate", !sawEstimate,
                       "samples=\(Set(samples.map { Int($0.rounded()) }).sorted())")
        CheckLog.check("oldRealHeight/cache-real",
                       abs((h.layout.cachedHeight(at: h.targetIndex) ?? -1) - h.rowHeight(h.targetIndex)) <= 0.5,
                       "cache=\(h.layout.cachedHeight(at: h.targetIndex) ?? -1) row=\(h.rowHeight(h.targetIndex))")
        CheckLog.check("oldRealHeight/baseline-was-real", abs(baseline - GenUIListHarness.coarseEstimate) > 1,
                       "baseline=\(baseline)")
    }

    // MARK: - 11. No thinking toggle notification

    func noThinkingToggleEmitted() {
        let h = makeHarness()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .thinkingBlockToggled, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        h.cardUpdate { s in var s = s; s.choice = "红色"; s.feedback = "不应发出 thinking 通知。"; return s }
        h.layoutNow(); h.pump(0.3); h.sliderLive(20); h.sliderCommit(); h.layoutNow(); h.pump(0.2)
        print("GENUI_THINKING_POSTS \(posts)")
        CheckLog.check("noThinkingToggleEmitted", posts == 0, "posts=\(posts)")
    }

    // MARK: - 12. Width change re-measure (basic case)

    func widthChangeRemeasure() {
        let h = makeHarness()
        h.cardUpdate { s in var s = s; s.choice = "绿色"; s.feedback = "换行宽度变化时应重新测量并保持视口。"; return s }
        h.layoutNow(); h.pump(0.25); h.layoutNow()
        let wide = h.rowHeight(h.targetIndex)
        h.resizeWidth(320)
        let offset = h.offset
        CheckLog.check("widthChange/purge-reseed-executed", h.widthReseedCount > 0,
                       "reseed count=\(h.widthReseedCount)")
        CheckLog.check("widthChange/baseline-legal", h.isLegalOffset(offset), "offset=\(offset)")
        let baselineRow = h.rowHeight(h.targetIndex)
        let baselineFit = h.measuredCardHeight()
        CheckLog.check("widthChange/baseline-real-at-new-width", abs(baselineRow - baselineFit) <= 1,
                       "row=\(baselineRow) fitted=\(baselineFit)")
        h.cardUpdate { s in var s = s; s.feedback = "换行宽度变化时应重新测量并保持视口。再看一次。"; return s }
        h.layoutNow(); h.pump(0.3); h.layoutNow()
        let narrow = h.rowHeight(h.targetIndex)
        let fitted = h.measuredCardHeight()
        print("GENUI_WIDTH_HEIGHT \(wide) -> \(narrow)")
        CheckLog.check("widthChange/real-measured", abs(narrow - fitted) <= 1, "row=\(narrow) fitted=\(fitted)")
        // Resize may itself leave the offset outside the (new) scrollable range;
        // the commit is then allowed to clamp INTO it, never to move content.
        CheckLog.check("widthChange/offset",
                       abs(h.offset - offset) <= 0.5 && h.isLegalOffset(h.offset),
                       "\(offset) -> \(h.offset) max=\(h.maxOffset)")
    }

    // MARK: - 13. enqueue defers BOTH state and height, queued keys survive

    func enqueueDefersStateAndHeight() {
        let h = makeHarness()
        let beforeState = h.rows[h.targetIndex].card
        let beforeHeight = h.rowHeight(h.targetIndex)
        h.queuedCardChange { s in var s = s; s.segmented = "年"; return s }
        h.queuedCardChange { s in var s = s; s.choice = "红色"; s.feedback = "两个排队变更都要保留。"; return s }
        // Before the main-queue turn runs: no state, no height.
        CheckLog.check("enqueue/deferred-state", h.rows[h.targetIndex].card == beforeState,
                       "segmented=\(h.rows[h.targetIndex].card.segmented) choice=\(h.rows[h.targetIndex].card.choice)")
        CheckLog.check("enqueue/deferred-height", abs(h.rowHeight(h.targetIndex) - beforeHeight) <= 0.5,
                       "\(beforeHeight) -> \(h.rowHeight(h.targetIndex))")
        h.pump(0.35); h.layoutNow(); h.pump(0.1); h.layoutNow()
        let after = h.rows[h.targetIndex].card
        CheckLog.check("enqueue/both-keys-kept",
                       after.segmented == "年" && after.choice == "红色" && after.feedback == "两个排队变更都要保留。",
                       "segmented=\(after.segmented) choice=\(after.choice) feedback=\(after.feedback)")
        CheckLog.check("enqueue/consumed-by-list", h.productionConfigureCount > 0,
                       "production configureCell runs=\(h.productionConfigureCount)")
        CheckLog.check("enqueue/height-grew", h.rowHeight(h.targetIndex) > beforeHeight + 10,
                       "\(beforeHeight) -> \(h.rowHeight(h.targetIndex))")
        CheckLog.check("enqueue/height-real",
                       abs(h.rowHeight(h.targetIndex) - h.measuredCardHeight()) <= 1,
                       "row=\(h.rowHeight(h.targetIndex)) fitted=\(h.measuredCardHeight())")
    }

    // MARK: - 14. Two lists, one block UUID, two block instances

    func twoListsSharedBlockChange() {
        let shared = UUID()
        let a = makeHarness(sessionId: "session-A", cardBlockId: shared)
        let b = makeHarness(sessionId: "session-A", cardBlockId: shared)
        guard let origin = a.cardBlocks[a.rows[a.targetIndex].id],
              let blockB = b.cardBlocks[b.rows[b.targetIndex].id] else {
            CheckLog.fail("twoLists/setup (blocks)")
            return
        }
        CheckLog.check("twoLists/distinct-instances", origin !== blockB)
        let beforeA = a.rowHeight(a.targetIndex)
        let beforeB = b.rowHeight(b.targetIndex)
        let offsetA = a.offset
        let offsetB = b.offset
        let target = GenUICardState(choice: "绿色", feedback: "同一个 block UUID，两个列表实例。",
                                    segmented: "月", slider: 30, long: false)
        var runs = 0
        // Built directly: the origin list's block, consumed by BOTH lists.
        let change = MinisUIStateUpdate(blockId: shared, sessionId: "session-A",
                                        state: { origin.genuiStateJSON }) {
            runs += 1
            origin.genuiStateJSON = target.json
        }
        print("GENUI_TWO_LIST_PHASE a-commit-begin main=\(Thread.isMainThread)"); fflush(stdout)
        a.coordinator.commitGenUIStateChange(change)
        print("GENUI_TWO_LIST_PHASE a-commit-end"); fflush(stdout)
        b.coordinator.commitGenUIStateChange(change)
        print("GENUI_TWO_LIST_PHASE b-commit-end"); fflush(stdout)
        a.layoutNow(); b.layoutNow()
        print("GENUI_TWO_LIST_PHASE first-layout-end"); fflush(stdout)
        a.pump(0.25); b.pump(0.25)
        print("GENUI_TWO_LIST_PHASE pump-end"); fflush(stdout)
        a.layoutNow(); b.layoutNow()
        CheckLog.check("twoLists/apply-once", runs == 1 && change.request.hasRun, "runs=\(runs)")
        CheckLog.check("twoLists/state-synced",
                       origin.genuiStateJSON == target.json && blockB.genuiStateJSON == target.json,
                       "b=\(blockB.genuiStateJSON ?? "nil")")
        CheckLog.check("twoLists/a-measured",
                       a.rowHeight(a.targetIndex) > beforeA + 10
                       && abs(a.rowHeight(a.targetIndex) - a.measuredCardHeight()) <= 1,
                       "\(beforeA) -> \(a.rowHeight(a.targetIndex)) fitted=\(a.measuredCardHeight())")
        CheckLog.check("twoLists/b-measured",
                       b.rowHeight(b.targetIndex) > beforeB + 10
                       && abs(b.rowHeight(b.targetIndex) - b.measuredCardHeight()) <= 1,
                       "\(beforeB) -> \(b.rowHeight(b.targetIndex)) fitted=\(b.measuredCardHeight())")
        CheckLog.check("twoLists/offsets", abs(a.offset - offsetA) <= 0.5 && abs(b.offset - offsetB) <= 0.5,
                       "a \(offsetA)->\(a.offset) b \(offsetB)->\(b.offset)")
    }

    // MARK: - suite

    private func runCase(_ name: String, _ body: () -> Void) {
        print("GENUI_CASE_BEGIN \(name)"); fflush(stdout)
        body()
        print("GENUI_CASE_END \(name)"); fflush(stdout)
    }

    func run() {
        runCase("choiceFeedbackGrows", choiceFeedbackGrows)
        runCase("longCardOffscreenKeepsOffset", longCardOffscreenKeepsOffset)
        runCase("resetShrinksBack", resetShrinksBack)
        runCase("segmentedPureValueNoGeometry", segmentedPureValueNoGeometry)
        runCase("rapidRepeatedState", rapidRepeatedState)
        runCase("sliderLiveThenCommit", sliderLiveThenCommit)
        runCase("noListFallbackKeepsState", noListFallbackKeepsState)
        runCase("sessionMismatchNotConsumed", sessionMismatchNotConsumed)
        runCase("noLayerAnimations", noLayerAnimations)
        runCase("oldRealHeightNeverEstimate", oldRealHeightNeverEstimate)
        runCase("noThinkingToggleEmitted", noThinkingToggleEmitted)
        runCase("widthChangeRemeasure", widthChangeRemeasure)
        runCase("enqueueDefersStateAndHeight", enqueueDefersStateAndHeight)
        runCase("twoListsSharedBlockChange", twoListsSharedBlockChange)
    }
}

// MARK: - App entry

@main
final class GenUIHeightApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        let start = Timer(timeInterval: 0.4, repeats: false) { _ in
            GenUIHeightTests().run()
            print("GENUI_HEIGHT_UIKIT_CHECKS \(CheckLog.passed)")
            if CheckLog.failed > 0 {
                print("GENUI_HEIGHT_UIKIT_FAIL \(CheckLog.failed)")
                fflush(stdout)
                exit(2)
            }
            print("GENUI_HEIGHT_UIKIT_PASS checks=\(CheckLog.passed)")
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.add(start, forMode: .common)
        return true
    }
}
