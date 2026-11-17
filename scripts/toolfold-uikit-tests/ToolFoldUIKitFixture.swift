// Mounted UIKit regression fixture: production ToolFoldPlanner + MessageListLayout + SelfSizingCell (ToolGroupCellV3) + BridgedToolGroupV3 + ToolGroupRowView.
import Combine
import Foundation
import SwiftUI
import UIKit

enum AssistantBlockKind: Equatable {
    case text, thinking, info, delegateTool, userAskTool, genuiTool
    case shellTool, fileReadTool, fileWriteTool, fileEditTool, browserTool, readImageTool, memoryTool
}

enum ToolBlockStatus: Equatable {
    case streaming(bytes: Int)
    case running
    case success
    case failed(message: String)
    case cancelled
}

struct AssistantBlock {
    var id = UUID()
    var kind: AssistantBlockKind
    var toolStatus: ToolBlockStatus? = nil
    var content = ""
    var thinkingContentBuffer = ""
    var toolUseId: String? = nil
    var toolDuration: TimeInterval? = nil
}

final class ChatMessage: ObservableObject {
    var id = UUID()
    @Published var blocks: [AssistantBlock] = []
    @Published var isCompactedHistory: Bool = false

    init(blocks: [AssistantBlock] = [], isCompactedHistory: Bool = false) {
        self.blocks = blocks
        self.isCompactedHistory = isCompactedHistory
    }
}

func AppLocalized(_ s: String) -> String { s }

extension Notification.Name {
    static let toolGroupToggled = Notification.Name("toolGroupToggled")
}

// MARK: - Minimal stubs required by verbatim MessageListLayout + SelfSizingCell slices

enum AIChatViewModel {
    static let onAppearTimestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
}

final class FontSettings {
    static let shared = FontSettings()
    func scaledMessage(_ reference: CGFloat) -> CGFloat { reference }
}

final class AppLogger {
    let category: String
    init(category: String) { self.category = category }
    func debug(_ m: String) {}
    func info(_ m: String) {}
    func warning(_ m: String) {}
    func error(_ m: String) {}
}

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

final class SelectableMarkdownTextView: UIView {
    private var signal = 0
    func asyncAttachmentRenderSignal() -> Int { signal }
}

@main final class ToolFoldUIKitFixture: UIResponder, UIApplicationDelegate, UICollectionViewDataSource {
    struct RowCase {
        let label: String
        let message: ChatMessage
        let run: ToolFoldPlanner.FoldedRun
        let expanded: Bool
    }

    // Deliberately non-28 initial layout estimate to prove real self-sizing
    // shrinks every cell to ToolGroupRowView.rowHeight (28pt) instead of
    // echoing a fixed cell size.
    static let initialEstimateHeight: CGFloat = 40

    var window: UIWindow?
    var listLayout: MessageListLayout!
    var list: UICollectionView!
    var rows: [RowCase] = []
    var checks = 0
    var failures: [String] = []
    var diagLines: [String] = []
    var output: URL!
    var pngCount = 0

    func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures.append(label) }
    }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("toolfold-uikit")
        try? FileManager.default.removeItem(at: output)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        runLifecycleChecks()

        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        let layout = MessageListLayout()
        layout.estimatedItemHeight = Self.initialEstimateHeight
        layout.itemSpacing = 4
        listLayout = layout
        let topSafe = max(vc.view.safeAreaInsets.top, vc.view.safeAreaLayoutGuide.layoutFrame.minY)
        let bottomSafe = vc.view.safeAreaInsets.bottom
        let listH = min(700, max(320, vc.view.bounds.height - topSafe - bottomSafe))
        list = UICollectionView(frame: CGRect(x: 0, y: topSafe, width: 390, height: listH), collectionViewLayout: layout)
        // Mirror production MessageListViewController while positioning collectionView
        // inside vc.view.safeAreaLayoutGuide so row 0 never inherits Dynamic Island safe area.
        list.contentInsetAdjustmentBehavior = .automatic
        list.register(ToolGroupCellV3.self, forCellWithReuseIdentifier: "group")
        list.dataSource = self
        vc.view.addSubview(list)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.renderStyle(0) }
        return true
    }

    /// [T-fold-first-thinking-atomic] Intermediate-frame design for the 17.0s
    /// one-frame "Deep Thinking" card (report §5.1). CI-PENDING: this fixture
    /// links the planner + the real `LivePlaceholderPolicy`, NOT the
    /// coordinator's snapshot walk, so it pins the invariants that walk
    /// depends on: at EVERY step of the delta timeline the rows below the fold
    /// row must stay zero — the blank tail never earns a row of its own, never
    /// becomes a second run, and never changes the fold row's identity (which
    /// is what a resnapshot diff would turn into an insert+delete pair).
    /// The row-level run (same timeline, full walk) is
    /// scripts/toolfold_live_thinking_flash_regression.py.
    func runLiveTailFrameChecks() {
        let prior = [AssistantBlock(kind: .thinking, content: "已完成"),
                     AssistantBlock(kind: .shellTool, toolStatus: .success, toolUseId: "f1"),
                     AssistantBlock(kind: .shellTool, toolStatus: .success, toolUseId: "f2")]
        var blocks = prior
        blocks.append(AssistantBlock(kind: .thinking, content: ""))   // the block the old stream appended first

        func extraRows() -> Int {
            let runs = ToolFoldPlanner.foldedRuns(in: blocks, ended: false)
            let hidden = Set(runs.flatMap(\.memberIds))
            var rows = 0
            for i in prior.count..<blocks.count {
                let b = blocks[i]
                if hidden.contains(b.id) { continue }
                if b.kind == .thinking,
                   !LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: true,
                                                               footerOwnsPlaceholder: false,
                                                               isLiveTail: i == blocks.count - 1) {
                    continue
                }
                rows += 1
            }
            return rows
        }
        func frame(_ step: String) -> (rows: Int, runs: Int, key: String?) {
            let runs = ToolFoldPlanner.foldedRuns(in: blocks, ended: false)
            check(extraRows() == 0, "live frame \(step): no row under the fold row")
            check(runs.count == 1, "live frame \(step): still exactly one fold row")
            return (extraRows(), runs.count, runs.first?.key)
        }

        let born = frame("blank-tail")
        let tail = blocks.count - 1
        blocks[tail].thinkingContentBuffer = "\n"
        _ = frame("whitespace-opener")
        blocks[tail].thinkingContentBuffer = "思考中"
        let preflush = frame("buffer-only")
        check(!ToolFoldPlanner.isBlankThinking(blocks[tail]), "buffered text is not blank to the planner")
        check(ToolFoldPlanner.foldedRuns(in: blocks, ended: false).first?.memberIds.contains(blocks[tail].id) == true,
              "the buffered tail already belongs to the run, so it cannot draw a row")
        blocks[tail].content = "思考中"
        let flushed = frame("first-flush")
        check(flushed.key == born.key && preflush.key == born.key, "fold row identity stable across the timeline")
        check(LivePlaceholderPolicy.blankThinkingKeepsRow(hasFoldRowAbove: true,
                                                          footerOwnsPlaceholder: false,
                                                          isLiveTail: true) == false,
              "blank tail under a fold row is never row-worthy")
    }

    func runLifecycleChecks() {
        runLiveTailFrameChecks()
        let msg = ChatMessage()
        let think1 = AssistantBlock(kind: .thinking, content: "")
        msg.blocks = [think1]
        check(ToolFoldPlanner.foldedRuns(in: msg.blocks, ended: false).isEmpty, "blank live thinking stays unfolded")

        msg.blocks[0].thinkingContentBuffer = "Inspecting files"
        let r1 = ToolFoldPlanner.foldedRuns(in: msg.blocks, ended: false)
        check(r1.count == 1 && r1[0].group.kind == .thinking && r1[0].group.isLive, "live thinking folds")

        // User manually expands while thinking-only.
        var expanded: Set<String> = [r1[0].key]
        let t1 = AssistantBlock(kind: .shellTool, toolStatus: .running, toolUseId: "toolu_1")
        msg.blocks.append(t1)
        let r2 = ToolFoldPlanner.foldedRuns(in: msg.blocks, ended: false)
        check(r2.count == 1 && r2[0].group.runningCount == 1 && r2[0].group.completedCount == 0 && r2[0].group.isLive, "running tool folds with thinking")
        // Migrate expanded key across live key promotion.
        if r2[0].matchKeys.contains(where: { expanded.contains($0) }) {
            for k in r2[0].matchKeys { expanded.remove(k) }
            expanded.insert(r2[0].key)
        }
        check(expanded.contains(r2[0].key), "manual expansion preserved on tool arrival")

        msg.blocks[1].toolStatus = .success
        msg.blocks[1].toolDuration = 1.4
        let t2 = AssistantBlock(kind: .fileReadTool, toolStatus: .running, toolUseId: "toolu_2")
        msg.blocks.append(t2)
        let r3 = ToolFoldPlanner.foldedRuns(in: msg.blocks, ended: false)
        check(r3.count == 1 && r3[0].group.toolCount == 2 && r3[0].group.runningCount == 1 && r3[0].group.completedCount == 1, "running and completed counts accurate")

        // Cards (userAsk + success show_ui), info barrier, and reply stay outside groups.
        msg.blocks[2].toolStatus = .success
        msg.blocks[2].toolDuration = 2.1
        let ask = AssistantBlock(kind: .userAskTool, toolStatus: .running, toolUseId: "ask_1")
        let uiFail = AssistantBlock(kind: .genuiTool, toolStatus: .failed(message: "err"), toolUseId: "ui_fail")
        let uiCancel = AssistantBlock(kind: .genuiTool, toolStatus: .cancelled, toolUseId: "ui_cancel")
        let t3 = AssistantBlock(kind: .shellTool, toolStatus: .running, toolUseId: "toolu_3")
        let uiOK = AssistantBlock(kind: .genuiTool, toolStatus: .success, toolUseId: "ui_ok")
        let info = AssistantBlock(kind: .info, content: "Switched provider")
        let reply = AssistantBlock(kind: .text, content: "Line 1\nLine 2")
        let liveWithAsk = [msg.blocks[0], msg.blocks[1], msg.blocks[2], ask, uiFail, uiCancel, t3]
        let rAsk = ToolFoldPlanner.foldedRuns(in: liveWithAsk, ended: false)
        check(rAsk.count == 2 && !rAsk.flatMap(\.memberIds).contains(ask.id), "user_ask outside groups")
        check(rAsk[0].group.isLive == false && rAsk[1].group.isLive == true && rAsk[1].group.runningCount == 1 && rAsk[1].group.failedCount == 1 && rAsk[1].group.cancelledCount == 1, "running mixed failed/cancelled")

        let endedBlocks = [msg.blocks[0], msg.blocks[1], msg.blocks[2], ask, uiOK, info, reply]
        let rEnd = ToolFoldPlanner.foldedRuns(in: endedBlocks, ended: true)
        check(rEnd.count == 1 && !rEnd[0].memberIds.contains(uiOK.id) && !rEnd[0].memberIds.contains(info.id) && !rEnd[0].memberIds.contains(reply.id), "show_ui, info, and reply stay outside")

        // Build UIKit render cases across live and ended states.
        let mLiveThink = ChatMessage(blocks: [AssistantBlock(kind: .thinking, content: "Reasoning")])
        let mLive1 = ChatMessage(blocks: [AssistantBlock(kind: .shellTool, toolStatus: .running, toolUseId: "r1")])
        let mLiveMix = ChatMessage(blocks: liveWithAsk)
        let mEnded = ChatMessage(blocks: endedBlocks)
        let mCompact = ChatMessage(blocks: endedBlocks, isCompactedHistory: true)
        rows = [
            RowCase(label: "live-thinking", message: mLiveThink, run: ToolFoldPlanner.foldedRuns(in: mLiveThink.blocks, ended: false)[0], expanded: false),
            RowCase(label: "live-running-1", message: mLive1, run: ToolFoldPlanner.foldedRuns(in: mLive1.blocks, ended: false)[0], expanded: false),
            RowCase(label: "live-mixed", message: mLiveMix, run: rAsk[1], expanded: false),
            RowCase(label: "ended-ran", message: mEnded, run: rEnd[0], expanded: false),
            RowCase(label: "expanded", message: mEnded, run: rEnd[0], expanded: true),
            RowCase(label: "compact", message: mCompact, run: rEnd[0], expanded: false),
        ]
    }

    func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = view.dequeueReusableCell(withReuseIdentifier: "group", for: path) as! ToolGroupCellV3
        let row = rows[path.item]
        let key = "g:\(row.message.id.uuidString):\(row.run.firstBlockId.uuidString):\(row.label)"
        cell.contentKey = key
        listLayout.setContentKey(key, at: path.item)
        listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: path.item)
        let config = UIHostingConfiguration {
            BridgedToolGroupV3(
                message: row.message,
                firstBlockId: row.run.firstBlockId,
                group: row.run.group,
                duration: row.run.duration,
                isExpanded: row.expanded,
                maxWidth: 358
            )
        }.minSize(width: 0, height: 0).margins(.all, 0)
        cell.applyContentConfiguration(config)
        cell.backgroundColor = ChatColors.backgroundUIColor
        return cell
    }

    private func syncCollectionFrameToSafeArea() -> Bool {
        guard let rootView = window?.rootViewController?.view else { return false }
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
        let safe = rootView.safeAreaLayoutGuide.layoutFrame
        let topSafe = max(rootView.safeAreaInsets.top, safe.minY)
        let bottomSafe = rootView.safeAreaInsets.bottom
        let availH = safe.height > 0 ? safe.height : max(320, rootView.bounds.height - topSafe - bottomSafe)
        let targetFrame = CGRect(x: 0, y: topSafe, width: 390, height: min(700, max(320, availH)))
        let frameChanged = list.frame != targetFrame
        if frameChanged {
            list.frame = targetFrame
            rootView.setNeedsLayout()
            rootView.layoutIfNeeded()
        }
        return frameChanged
    }

    func renderStyle(_ step: Int) {
        let styles: [(String, UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]
        if step == styles.count {
            testToggleNotification()
            return
        }
        let (name, style) = styles[step]
        _ = syncCollectionFrameToSafeArea()
        window!.overrideUserInterfaceStyle = style
        list.backgroundColor = ChatColors.backgroundUIColor
        list.contentOffset = .zero
        // Match production Snapshot.swift initial apply: suppress offset compensation
        // during initial reload/layout so height updates settle without shifting origin.
        listLayout.suppressContentOffsetAdjustment = true
        listLayout.clearHeightCache()
        for i in 0..<rows.count {
            listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: i)
        }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
        listLayout.suppressContentOffsetAdjustment = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.settleAndCaptureStyle(step: step, name: name, tick: 1, stableTicks: 0, previousHeights: [])
        }
    }

    func settleAndCaptureStyle(step: Int, name: String, tick: Int, stableTicks: Int, previousHeights: [CGFloat]) {
        if syncCollectionFrameToSafeArea() || list.safeAreaInsets.top > 0.5 {
            listLayout.suppressContentOffsetAdjustment = true
            listLayout.clearHeightCache()
            for i in 0..<rows.count {
                listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: i)
            }
            list.reloadData()
            list.setNeedsLayout()
            list.layoutIfNeeded()
            listLayout.suppressContentOffsetAdjustment = false
            if tick < 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self.settleAndCaptureStyle(step: step, name: name, tick: tick + 1, stableTicks: 0, previousHeights: [])
                }
                return
            }
        }

        list.setNeedsLayout()
        list.layoutIfNeeded()

        let expectedContentH = CGFloat(rows.count) * ToolGroupRowView.rowHeight
            + CGFloat(max(0, rows.count - 1)) * listLayout.itemSpacing

        var currentHeights: [CGFloat] = []
        var allCellsReady = true
        var allCachedReady = true
        var allLeftEstimate = true
        for i in 0..<rows.count {
            let ip = IndexPath(item: i, section: 0)
            guard let cell = list.cellForItem(at: ip) as? ToolGroupCellV3 else {
                allCellsReady = false
                break
            }
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            let h = cell.frame.size.height
            currentHeights.append(h)
            if abs(h - Self.initialEstimateHeight) <= 0.5 {
                allLeftEstimate = false
            }
            if listLayout.cachedHeight(at: i) == nil {
                allCachedReady = false
            }
        }

        let contentSize = listLayout.collectionViewContentSize
        let sumHeights = currentHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * listLayout.itemSpacing
        let layoutMatchesCells = allCellsReady && currentHeights.count == rows.count
            && abs(contentSize.height - sumHeights) <= 0.5
        let sameAsPrev = allCellsReady && previousHeights.count == currentHeights.count
            && zip(previousHeights, currentHeights).allSatisfy { abs($0 - $1) <= 0.1 }

        let nextStable = (allCellsReady && allCachedReady && allLeftEstimate && layoutMatchesCells && sameAsPrev && list.safeAreaInsets.top <= 0.5)
            ? (stableTicks + 1) : 0
        let maxTicks = 25
        if (tick >= 3 && nextStable >= 2) || tick >= maxTicks {
            captureStyleDiagnostics(step: step, name: name, settleTicks: tick, expectedContentH: expectedContentH)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.settleAndCaptureStyle(step: step, name: name, tick: tick + 1, stableTicks: nextStable, previousHeights: currentHeights)
        }
    }

    func captureStyleDiagnostics(step: Int, name: String, settleTicks: Int, expectedContentH: CGFloat) {
        let contentSize = self.listLayout.collectionViewContentSize
        let listSafeTop = self.list.safeAreaInsets.top
        for i in 0..<self.rows.count {
            let ip = IndexPath(item: i, section: 0)
            guard let cell = self.list.cellForItem(at: ip) as? ToolGroupCellV3 else {
                self.check(false, "missing cell \(name) \(i)")
                continue
            }
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()

            let frameSize = cell.frame.size
            let layoutCacheH = self.listLayout.cachedHeight(at: i) ?? -1
            let cellSafeTop = cell.safeAreaInsets.top
            let attrs = (self.list.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes)
                ?? UICollectionViewLayoutAttributes(forCellWith: ip)
            cell.clearCachedHeight()
            let fit = cell.preferredLayoutAttributesFitting(attrs).size
            let contentFit = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: attrs.size.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            let intrinsic = cell.contentView.intrinsicContentSize
            let hostIntrinsic = cell.contentView.subviews.first?.intrinsicContentSize ?? .zero
            let diag = String(
                format: "TOOLFOLD_UIKIT_DIAG style=%@ row=%@ est=%.1f frame=%.1fx%.1f attrs=%.1fx%.1f layoutCache=%.1f fit=%.1fx%.1f contentFit=%.1fx%.1f intrinsic=%.1fx%.1f hostIntrinsic=%.1fx%.1f contentSize=%.1fx%.1f safeTop=%.1f cellSafeTop=%.1f ticks=%d",
                name, self.rows[i].label, Self.initialEstimateHeight,
                frameSize.width, frameSize.height,
                attrs.size.width, attrs.size.height,
                layoutCacheH,
                fit.width, fit.height,
                contentFit.width, contentFit.height,
                intrinsic.width, intrinsic.height,
                hostIntrinsic.width, hostIntrinsic.height,
                contentSize.width, contentSize.height,
                listSafeTop, cellSafeTop, settleTicks
            )
            self.diagLines.append(diag)
            print(diag)

            let ok = abs(fit.height - ToolGroupRowView.rowHeight) <= 1.0
                && abs(frameSize.height - ToolGroupRowView.rowHeight) <= 1.0
                && abs(contentFit.height - ToolGroupRowView.rowHeight) <= 1.0
                && abs(layoutCacheH - ToolGroupRowView.rowHeight) <= 1.0
                && abs(contentSize.height - expectedContentH) <= 1.0
            self.check(ok,
                       "\(name) row \(self.rows[i].label) frame=\(frameSize.height) fit=\(fit.height) contentFit=\(contentFit.height) layoutCache=\(layoutCacheH) intrinsic=\(intrinsic.height) contentSize=\(contentSize.height) expected=\(ToolGroupRowView.rowHeight)")
            let renderer = UIGraphicsImageRenderer(bounds: cell.bounds)
            let img = renderer.image { ctx in cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true) }
            if let data = img.pngData() {
                try? data.write(to: self.output.appendingPathComponent("\(name)-\(self.rows[i].label).png"))
                self.pngCount += 1
            }
        }
        self.renderStyle(step + 1)
    }

    func testToggleNotification() {
        var received: UUID?
        let obs = NotificationCenter.default.addObserver(forName: .toolGroupToggled, object: nil, queue: nil) { n in
            received = n.object as? UUID
        }
        NotificationCenter.default.post(name: .toolGroupToggled, object: rows[0].run.firstBlockId)
        NotificationCenter.default.removeObserver(obs)
        check(received == rows[0].run.firstBlockId, "toolGroupToggled notification delivers firstBlockId")
        finish()
    }

    func finish() {
        let diagText = diagLines.joined(separator: "\n") + "\n"
        try? diagText.write(to: output.appendingPathComponent("diag.log"), atomically: true, encoding: .utf8)
        let msg: String
        if failures.isEmpty {
            msg = "TOOLFOLD_UIKIT_PASS checks=\(checks) png=\(pngCount)"
        } else {
            msg = "TOOLFOLD_UIKIT_FAIL checks=\(checks) failures=\(failures.joined(separator: "; "))"
        }
        try! (msg + "\n").write(to: output.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }
}
