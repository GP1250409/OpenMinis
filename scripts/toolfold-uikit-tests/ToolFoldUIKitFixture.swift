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
        /// [T-toolgroup-accordion] The REAL list item this row stands for. The
        /// flight's identity check compares `MessageListItem`s, so the fixture
        /// must own the same identities the production data source would hold —
        /// a scalar stand-in (`msg.id`/`run` re-derived at the call site, or a
        /// local `Bool`) could never be replaced or shifted by a real update.
        let item: MessageListItem

        init(label: String, message: ChatMessage, run: ToolFoldPlanner.FoldedRun,
             expanded: Bool, item: MessageListItem? = nil) {
            self.label = label
            self.message = message
            self.run = run
            self.expanded = expanded
            self.item = item ?? .toolGroup(message.id, run.firstBlockId)
        }
    }

    // Deliberately non-28 initial layout estimate to prove real self-sizing
    // shrinks every cell to ToolGroupRowView.rowHeight (28pt) instead of
    // echoing a fixed cell size.
    static let initialEstimateHeight: CGFloat = 40

    var window: UIWindow?
    var listLayout: MessageListLayout!
    var list: UICollectionView!
    /// The rows the list draws. `listItems` mirrors their REAL identities in the
    /// same order — that array is what `ToolGroupAccordionFlight.liveItems`
    /// reads, exactly like the coordinator hands the flight its snapshot.
    var rows: [RowCase] = [] {
        didSet { listItems = rows.map(\.item) }
    }
    private(set) var listItems: [MessageListItem] = []
    /// The scene the current accordion case was built from (its message, its run
    /// and the real items). Every plan of that case addresses these items.
    var currentScene: AccordionScene?
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
            && zip(previousHeights, currentHeights).allSatisfy { pair in abs(pair.0 - pair.1) <= 0.1 }

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
        startAccordionStage()
    }

    // MARK: - [T-toolgroup-accordion] Real accordion flight

    /// [T-toolgroup-accordion] One accordion case's REAL data: a message whose
    /// consecutive tool calls fold into a single run, the list items the
    /// production list holds for it (the group row, every member row, then the
    /// reply block and the message footer), and nothing invented.
    ///
    /// The plan the flight receives is addressed with THESE items
    /// (`items[headerIndex]`, `items[memberRange]`), which are the same values
    /// the layout's data source is built from. `MessageListItem` carries real
    /// `UUID`s, so a same-count replacement or an insert above genuinely changes
    /// them — that is what the identity check must react to.
    struct AccordionScene {
        let message: ChatMessage
        let run: ToolFoldPlanner.FoldedRun
        let items: [MessageListItem]
    }

    func makeScene(tag: String, tools: Int) -> AccordionScene {
        let blocks = (0..<tools).map { index in
            AssistantBlock(kind: .shellTool, toolStatus: .success, toolUseId: "\(tag)-tool-\(index)")
        }
        let reply = AssistantBlock(kind: .text, content: "\(tag) reply")
        let message = ChatMessage(blocks: blocks + [reply])
        let run = ToolFoldPlanner.foldedRuns(in: message.blocks, ended: true).first!
        var items: [MessageListItem] = [.toolGroup(message.id, run.firstBlockId)]
        items += run.memberIds.map { MessageListItem.assistantBlock(message.id, $0) }
        items.append(.assistantBlock(message.id, reply.id))
        items.append(.assistantFooter(message.id))
        return AccordionScene(message: message, run: run, items: items)
    }

    /// The rows the list draws for a scene. Every slot hosts the group row's
    /// content on purpose (this stage is about GEOMETRY, and the accordion is
    /// row-type agnostic), but each row CARRIES the item it really stands for.
    func makeRows(for scene: AccordionScene, prefix: String) -> [RowCase] {
        scene.items.enumerated().map { index, item in
            RowCase(label: "\(prefix)-\(index)", message: scene.message, run: scene.run,
                    expanded: index == 0, item: item)
        }
    }

    /// Load a scene into the list: real rows, real identities, estimates, layout.
    func applyScene(_ scene: AccordionScene, prefix: String, limit: Int? = nil) {
        currentScene = scene
        let all = makeRows(for: scene, prefix: prefix)
        rows = limit.map { Array(all.prefix($0)) } ?? all
        listLayout.clearToolGroupAccordion()
        listLayout.clearHeightCache()
        for i in 0..<rows.count { listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: i) }
        // [T-toolgroup-accordion] Same shape as production's snapshot apply (see
        // `renderStyle`): the reload's self-sizing corrections (40 → 28) must not
        // write a `contentOffsetAdjustment`. Un-suppressed, they left the list a
        // few points outside the legal window of a short list, and the flight's
        // own clamp — not the tap — then moved the header (run 44506193558:
        // `drift=-4.33`).
        listLayout.suppressContentOffsetAdjustment = true
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
        listLayout.suppressContentOffsetAdjustment = false
        normalizeViewportToLegalTop()
    }

    /// [T-toolgroup-accordion] A tap always arrives on a LEGAL viewport: a
    /// UIScrollView clamps its own offset, so production never hands the flight
    /// an anchor measured at -4.33pt above the top. This stage reloads its list
    /// between cases, so it puts the viewport back on the legal top explicitly
    /// instead of inheriting a leftover from the previous case. Returns how far
    /// the offset had to move (diagnostics / assertion).
    @discardableResult
    func normalizeViewportToLegalTop() -> CGFloat {
        let top = -list.adjustedContentInset.top
        let delta = list.contentOffset.y - top
        if abs(delta) > 0.01 {
            list.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            list.setNeedsLayout()
            list.layoutIfNeeded()
        }
        return list.contentOffset.y - top
    }

    /// Replace the data source WITHOUT touching the reveal window: the flying
    /// driver has to notice by itself (that is the identity-retirement case).
    func replaceRows(_ newRows: [RowCase]) {
        rows = newRows
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    /// The plan for a scene, addressed with the scene's REAL items.
    func makePlan(for scene: AccordionScene, memberRange: ClosedRange<Int>,
                  heights: [CGFloat], anchorY: CGFloat) -> ToolGroupAccordionFlight.Plan {
        ToolGroupAccordionFlight.Plan(memberRange: memberRange,
                                      naturalHeights: heights,
                                      headerIndex: 0,
                                      anchorY: anchorY,
                                      headerItem: scene.items[0],
                                      memberItems: Array(scene.items[memberRange]))
    }

    /// A flight wired the way the coordinator wires it: `liveItems` is the
    /// list's current snapshot, so retirement is decided by real identities and
    /// never by a local flag of this fixture.
    func makeFlight() -> ToolGroupAccordionFlight {
        let flight = ToolGroupAccordionFlight(collectionView: list, layout: listLayout)
        flight.liveItems = { [weak self] in self?.listItems }
        accordionFlight = flight
        return flight
    }

    /// One folded run (header row + 3 member rows) followed by two rows that
    /// must move smoothly while the run opens. The rows are ToolGroupCellV3 for
    /// every slot on purpose: this stage is about GEOMETRY (the accordion is
    /// row-type agnostic), and the production `ToolGroupAccordionFlight` +
    /// `MessageListLayout` are the real ones the chat list uses.
    func startAccordionStage() {
        let scene = makeScene(tag: "acc", tools: 3)
        check(scene.run.memberIds.count == 3 && scene.items.count == 6,
              "accordion scene: one run of 3 calls, 6 real rows (\(scene.run.memberIds.count)/\(scene.items.count))")
        applyScene(scene, prefix: "acc")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.beginAccordionFlight() }
    }

    func beginAccordionFlight() {
        guard let scene = currentScene else { check(false, "the accordion stage keeps its scene"); return }
        list.setNeedsLayout()
        list.layoutIfNeeded()
        // [T-toolgroup-accordion] The anchor is only meaningful on a legal
        // viewport (production always is). Normalise first, then assert it, so
        // the mid-flight drift measures the flight and not a stale offset the
        // previous case left behind.
        let strayOffset = normalizeViewportToLegalTop()
        check(abs(strayOffset) <= 0.5,
              "the tap is taken on a legal viewport, never on a stale offset (Δ=\(String(format: "%.2f", strayOffset)))")
        let heights = (1...3).map { listLayout.naturalHeightForAccordion(at: $0) }
        check(heights.allSatisfy { $0 > 1 }, "accordion member rows have a measured natural height \(heights)")
        let headerY = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.minY - list.contentOffset.y
        accordionHeaderY = headerY
        let plan = makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: headerY)
        check(plan.headerItem == listItems[0] && plan.memberItems == Array(listItems[1...3]),
              "accordion plan addresses exactly the rows the list holds")
        let flight = makeFlight()
        flight.reduceMotion = { false }
        flight.start(plan, direction: .expand) { outcome in
            self.check(outcome == .completed, "accordion expand completed (outcome=\(outcome.rawValue))")
            self.captureAccordionFrame("accordion-end")
            self.checkAccordionSettled()
            self.startAccordionCollapse()
        }
        // [T-toolgroup-accordion] The baseline of "rows below the run move DOWN"
        // is the CLOSED state, which `start` applies synchronously (reveal 0,
        // member rows 0 high). Reading it before the span existed compared
        // against the fully open rest geometry that the animation never shows —
        // production inserts the rows and installs the span in the same turn
        // (run 44506193558: 128.0 → 53.3, i.e. the rows had to shrink first).
        list.layoutIfNeeded()
        accordionFollowYBefore = list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))!.frame.minY
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { self.checkAccordionMidFlight() }
    }

    func checkAccordionMidFlight() {
        guard let flight = accordionFlight, let heights = listLayout.toolGroupAccordionVisibleHeights else {
            check(false, "accordion mid-flight: flight and span still live")
            return
        }
        let reveal = flight.reveal
        check(flight.framesApplied >= 3 && reveal > 0.02 && reveal < 0.98,
              "accordion mid-flight is NOT an instant cut: frames=\(flight.framesApplied) reveal=\(String(format: "%.3f", reveal))")
        let summary = heights.reduce(0, +)
        check(abs(summary - flight.currentPlan!.naturalHeights.reduce(0, +) * reveal) <= 1.0,
              "mid-flight revealed height follows the eased reveal (\(String(format: "%.1f", summary)) vs reveal)")
        check(heights.contains { $0 > 0.5 && $0 < flight.currentPlan!.naturalHeights[0] - 0.5 },
              "a member row is partially revealed (clipped, not scaled): \(heights.map { String(format: "%.1f", $0) })")
        let attrs0 = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!
        let drift = attrs0.frame.minY - list.contentOffset.y - accordionHeaderY
        check(abs(drift) <= 0.75,
              "tapped header stays at its screen Y mid-flight (drift=\(String(format: "%.2f", drift)) "
                + "header=\(String(format: "%.2f", attrs0.frame.minY)) offset=\(String(format: "%.2f", list.contentOffset.y)) "
                + "anchor=\(String(format: "%.2f", accordionHeaderY)))")
        let follow = list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))!.frame.minY
        check(follow > accordionFollowYBefore + 1,
              "rows below the run move down while it opens (\(String(format: "%.1f", accordionFollowYBefore))→\(String(format: "%.1f", follow)))")
        // [T-toolgroup-accordion] The revealed span ends at the FRONTIER
        // (`Σ shown == total × reveal`, measured from the run's own top), not at
        // the last member row's frame: below the frontier the member rows are
        // hidden and 0 high, and the layout gives a zero-height row no trailing
        // gap, so the last span row's `maxY` sits one gap above the frontier.
        // Comparing against it (run 44506193558) measured the layout's gap policy
        // instead of the reveal.
        let runTop = attrs0.frame.maxY + listLayout.itemSpacing
        let frontier = runTop + summary
        check(abs(follow - (frontier + listLayout.itemSpacing)) <= 0.75,
              "following row sits exactly after the revealed span (follow=\(String(format: "%.1f", follow)) "
                + "frontier=\(String(format: "%.1f", frontier)))")
        if let cell = list.cellForItem(at: IndexPath(item: 1, section: 0)) as? SelfSizingCell {
            let natural = flight.currentPlan!.naturalHeights[0]
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            check(cell.clipsToBounds, "straddling cell clips")
            check(cell.bounds.height < natural - 0.5,
                  "the cell is SHORTER than its content (a clip window, not a re-layout): cell=\(cell.bounds.height) natural=\(natural)")
            check(cell.contentView.frame.height >= natural - 0.5,
                  "hosted content is still laid out at its natural height: content=\(cell.contentView.frame.height) natural=\(natural)")
            check(cell.contentView.frame.minY == 0, "hosted content stays top-aligned inside the window")
        } else {
            check(false, "straddling member cell exists mid-flight")
        }
        captureAccordionFrame("accordion-mid")
    }

    func checkAccordionSettled() {
        check(listLayout.toolGroupAccordionSpan == nil, "accordion span cleared after the flight")
        check(accordionFlight?.reveal == 1, "accordion ended fully revealed")
        let attrs = (1...3).map { list.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))! }
        for (k, a) in attrs.enumerated() {
            let natural = listLayout.cachedHeight(at: k + 1) ?? -1
            check(abs(a.frame.height - natural) <= 0.75,
                  "member row \(k + 1) restored to its measured height (\(a.frame.height) vs \(natural))")
        }
        let follow = list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))!.frame.minY
        check(abs(follow - (attrs[2].frame.maxY + listLayout.itemSpacing)) <= 0.75,
              "following row restored exactly under the open run")
        if let cell = list.cellForItem(at: IndexPath(item: 1, section: 0)) as? SelfSizingCell {
            check(!cell.clipsToBounds, "clipping flag restored on the cell")
            check(cell.accordionContentHeight == nil, "the clip window is cleared after the flight")
            check(abs(cell.contentView.frame.height - cell.bounds.height) <= 0.5,
                  "contentView is back to the cell bounds (\(cell.contentView.frame.height) vs \(cell.bounds.height))")
            cell.prepareForReuse()
            check(abs(cell.contentView.frame.height - cell.bounds.height) <= 0.5,
                  "a reused cell does not keep the taller content window")
        }
        check(abs(list.contentSize.height - listLayout.collectionViewContentSize.height) <= 1.0,
              "contentSize agrees with the layout after the flight")
    }

    func startAccordionCollapse() {
        guard let scene = currentScene else { check(false, "the collapse stage keeps its scene"); return }
        let heights = (1...3).map { listLayout.cachedHeight(at: $0) ?? ToolGroupRowView.rowHeight }
        let headerY = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.minY - list.contentOffset.y
        accordionHeaderY = headerY
        let followBefore = list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))!.frame.minY
        let plan = makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: headerY)
        let flight = makeFlight()
        flight.reduceMotion = { false }
        flight.start(plan, direction: .collapse) { outcome in
            // This flight runs to its own END: the reversal/drag case below owns
            // a SEPARATE flight and scene. Sharing one flight made that case's
            // forced `.interrupted` run these end-of-close assertions, and both
            // cases then advanced the stage — which duplicated every later case
            // (run 44506193558: "collapse completed (outcome=interrupted)", and
            // the entry stage ran twice).
            self.check(outcome == .completed, "accordion collapse completed (outcome=\(outcome.rawValue))")
            guard outcome == .completed else { return }
            self.check(self.listLayout.toolGroupAccordionSpan == nil, "collapse cleared its span")
            // `finish` clears the span BEFORE this callback, so the member rows
            // are back at the heights they were frozen at: the close's own
            // geometry is "0 revealed, rows at their natural height", and
            // dropping the rows is the structural step (the entry stage asserts
            // that one). The old "every member row is 0 high" expected the span
            // to survive the callback, which `finish` never does.
            let closed = (1...3).map { self.listLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))!.frame.height }
            self.check(zip(closed, heights).allSatisfy { pair in abs(pair.0 - pair.1) <= 0.75 },
                       "every member row is back at its frozen height after the close, nothing left clipped (\(closed))")
            self.check(self.accordionFlight?.reveal == 0, "collapse ended fully hidden")
            let followAfter = self.list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0))!.frame.minY
            self.check(abs(followAfter - followBefore) <= 0.75,
                       "the row after the closed run is back where it started (\(followBefore)→\(followAfter))")
            self.startRetargetCase()
        }
    }

    /// [T-toolgroup-accordion] A second tap on the same run mid-close: the flight
    /// reverses in place instead of restarting, and a drag that takes the
    /// viewport afterwards leaves the offset exactly where the finger left it.
    /// Own scene + own flight, so the forced `.interrupted` here can never run
    /// another case's end-of-flight assertions.
    func startRetargetCase() {
        let scene = makeScene(tag: "retarget", tools: 3)
        applyScene(scene, prefix: "retarget")
        let heights = (1...3).map { listLayout.naturalHeightForAccordion(at: $0) }
        let headerY = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.minY - list.contentOffset.y
        accordionHeaderY = headerY
        let plan = makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: headerY)
        let flight = makeFlight()
        flight.reduceMotion = { false }
        flight.start(plan, direction: .collapse) { outcome in
            self.check(outcome == .interrupted, "retarget: the reversal ends interrupted (outcome=\(outcome.rawValue))")
            self.startReduceMotionCase()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.retargetAccordionMidFlight() }
    }

    func retargetAccordionMidFlight() {
        guard let flight = accordionFlight else { check(false, "retarget: flight live"); return }
        let before = flight.reveal
        check(before > 0.02 && before < 0.98, "collapse was mid-flight before the second tap (\(String(format: "%.3f", before)))")
        flight.retarget(.expand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard let f = self.accordionFlight else { return }
            self.check(f.reveal > before, "second tap reverses in place, does not restart (\(String(format: "%.3f", before))→\(String(format: "%.3f", f.reveal)))")
            self.check(f.framesApplied >= 2, "reversal kept the same flight (frames=\(f.framesApplied))")
            let offsetBefore = self.list.contentOffset.y
            f.finish(.interrupted)
            self.check(abs(self.list.contentOffset.y - offsetBefore) < 0.5,
                       "interrupt leaves the viewport where the finger left it (\(offsetBefore)→\(self.list.contentOffset.y))")
            self.check(self.listLayout.toolGroupAccordionSpan == nil, "interrupt path clears the span at once")
        }
    }

    func startReduceMotionCase() {
        let scene = makeScene(tag: "reduce", tools: 3)
        applyScene(scene, prefix: "reduce")
        let heights = (1...3).map { _ in ToolGroupRowView.rowHeight }
        let plan = makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: 0)
        let flight = makeFlight()
        flight.reduceMotion = { true }
        flight.start(plan, direction: .expand) { outcome in
            self.check(outcome == .instant, "reduce motion applies the terminal state without animating")
            self.check(flight.reveal == 1 && self.listLayout.toolGroupAccordionSpan == nil,
                       "reduce motion leaves no span behind")
            self.captureAccordionFrame("accordion-reduce-motion")
            self.startShortContentCase()
        }
    }

    var accordionFlight: ToolGroupAccordionFlight?
    var entryStage: ToolGroupToggleEntryStage?
    var accordionHeaderY: CGFloat = 0
    var accordionFollowYBefore: CGFloat = 0

    // MARK: - [T-toolgroup-accordion] edge cases (dynamic, real layout + driver)

    /// Two rows in a tall list: the content is SHORTER than the viewport, so the
    /// only legal offset is the top inset. The reveal must still run and the
    /// offset must never leave the legal window (no bounce, no crash).
    func startShortContentCase() {
        let scene = makeScene(tag: "short", tools: 1)
        applyScene(scene, prefix: "short", limit: 2)   // header + its one member row
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            let heights = [self.listLayout.naturalHeightForAccordion(at: 1)]
            let plan = self.makePlan(for: scene, memberRange: 1...1, heights: heights, anchorY: 0)
            let flight = self.makeFlight()
            flight.reduceMotion = { false }
            flight.start(plan, direction: .expand) { outcome in
                self.check(outcome == .completed, "short content: the reveal still runs (outcome=\(outcome.rawValue))")
                self.check(self.list.contentSize.height <= self.list.bounds.height + 1,
                           "short content: the list is really shorter than its viewport")
                self.check(abs(self.list.contentOffset.y + self.list.adjustedContentInset.top) <= 1,
                           "short content: offset stays at the legal top inset (\(self.list.contentOffset.y))")
                self.check((self.listLayout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.height ?? 0) > 0.5,
                           "short content: the member row is revealed")
                self.startLongGroupCase()
            }
        }
    }

    /// A run taller than the viewport: rows below the fold must move by exactly
    /// the revealed amount, and nothing may be left clipped after the flight.
    func startLongGroupCase() {
        let scene = makeScene(tag: "long", tools: 32)
        check(scene.run.memberIds.count == 32, "long group: the planner folds its 32 calls into one run (\(scene.run.memberIds.count))")
        applyScene(scene, prefix: "long")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let heights = (1...32).map { self.listLayout.naturalHeightForAccordion(at: $0) }
            self.check(heights.reduce(0, +) > self.list.bounds.height,
                       "long group: the members really are taller than the viewport (\(heights.reduce(0, +)) vs \(self.list.bounds.height))")
            let headerY = (self.list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY ?? 0) - self.list.contentOffset.y
            let plan = self.makePlan(for: scene, memberRange: 1...32, heights: heights, anchorY: headerY)
            let flight = self.makeFlight()
            flight.reduceMotion = { false }
            flight.start(plan, direction: .expand) { outcome in
                self.check(outcome == .completed, "long group: the flight completes (outcome=\(outcome.rawValue))")
                self.check(flight.framesApplied >= 5, "long group: many frames, not an instant cut (frames=\(flight.framesApplied))")
                let open = (1...32).map { self.listLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.height ?? 0 }
                self.check(open.allSatisfy { $0 > 0.5 }, "long group: every member row ends open")
                let follow = self.list.layoutAttributesForItem(at: IndexPath(item: 33, section: 0))?.frame.minY ?? 0
                let lastMember = self.list.layoutAttributesForItem(at: IndexPath(item: 32, section: 0))?.frame.maxY ?? 0
                self.check(abs(follow - lastMember - self.listLayout.itemSpacing) <= 0.75,
                           "long group: the row after the run sits exactly under it")
                self.startIdentityInvalidationCase()
            }
        }
    }

    /// The plan's rows are replaced by others (same count): the driver must
    /// retire on identity, not keep clipping whatever now lives at those rows.
    /// The replacement is a REAL data source swap — another message's run, so
    /// every index holds a different `MessageListItem` while the row count and
    /// the reveal window stay exactly as they were.
    func startIdentityInvalidationCase() {
        let scene = makeScene(tag: "ident", tools: 3)
        applyScene(scene, prefix: "ident")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            let heights = (1...3).map { self.listLayout.naturalHeightForAccordion(at: $0) }
            let plan = self.makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: 0)
            let flight = self.makeFlight()
            flight.reduceMotion = { false }
            flight.start(plan, direction: .expand) { outcome in
                self.check(outcome == .interrupted, "identity: the flight retires instead of clipping the wrong rows")
                self.check(self.listLayout.toolGroupAccordionSpan == nil, "identity: the span is cleared at once")
                self.startInsertAboveCase()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let other = self.makeScene(tag: "ident-other", tools: 3)
                let replacement = self.makeRows(for: other, prefix: "ident-other")
                self.check(replacement.count == self.rows.count,
                           "identity: the replacement really has the same row count (\(replacement.count)/\(self.rows.count))")
                self.check(replacement.map(\.item) != self.listItems,
                           "identity: the replacement really changes every list identity")
                self.replaceRows(replacement)   // same count, different rows
            }
        }
    }

    /// A row inserted ABOVE the run: the count grows by one and every stored
    /// identity moves one row down. The count alone cannot see this; the items
    /// can, so the driver must retire.
    func startInsertAboveCase() {
        let scene = makeScene(tag: "insert", tools: 3)
        applyScene(scene, prefix: "insert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            let heights = (1...3).map { self.listLayout.naturalHeightForAccordion(at: $0) }
            let plan = self.makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: 0)
            let flight = self.makeFlight()
            flight.reduceMotion = { false }
            flight.start(plan, direction: .expand) { outcome in
                self.check(outcome == .interrupted, "insert above: the flight retires instead of clipping shifted rows")
                self.check(self.listLayout.toolGroupAccordionSpan == nil, "insert above: the span is cleared at once")
                self.startReduceMotionCollapseCase()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let earlier = ChatMessage(blocks: [AssistantBlock(kind: .text, content: "earlier")])
                var grown = self.rows
                grown.insert(RowCase(label: "insert-above-prior", message: earlier, run: scene.run,
                                     expanded: false, item: .wholeMessage(earlier.id)), at: 0)
                self.check(grown.count == self.rows.count + 1,
                           "insert above: the list really grew by one row (\(grown.count)/\(self.rows.count))")
                self.check(grown[1].item == plan.headerItem,
                           "insert above: the run's header now lives one row below the plan's index")
                self.replaceRows(grown)
            }
        }
    }

    /// Reduce motion in the CLOSING direction must reach reveal 0 and drop the
    /// span without a single intermediate frame.
    func startReduceMotionCollapseCase() {
        let scene = makeScene(tag: "reduce-close", tools: 3)
        applyScene(scene, prefix: "reduce-close")
        let heights = (1...3).map { _ in ToolGroupRowView.rowHeight }
        let plan = makePlan(for: scene, memberRange: 1...3, heights: heights, anchorY: 0)
        let flight = makeFlight()
        flight.reduceMotion = { true }
        flight.start(plan, direction: .collapse) { outcome in
            self.check(outcome == .instant, "reduce motion close: instant outcome")
            self.check(flight.reveal == 0 && self.listLayout.toolGroupAccordionSpan == nil,
                       "reduce motion close: closed and no span left")
            self.startToggleEntryStage()
        }
    }

    // MARK: - [T-toolgroup-accordion] Entry level: the production toggle transaction

    /// Drives `ToolGroupAccordionToggle.run(_:in:)` — the call the coordinator's
    /// `toggleToolGroup` makes — against its own real list, so the business
    /// entry (expand/close structure, measurement, span, flight, end anchor) is
    /// covered by the shipping code rather than by this fixture.
    func startToggleEntryStage() {
        let stage = ToolGroupToggleEntryStage(window: window!, report: { [weak self] ok, label in
            self?.check(ok, label)
        })
        entryStage = stage
        stage.start()
        // [T-toolgroup-accordion] `self` is the app delegate (it outlives the
        // run) and `entryStage` retains the stage, so a weak capture cannot cut
        // the stage short — it only keeps `guard let self` legal, which a strong
        // capture does not (a non-optional self can never be bound again).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, let stage = self.entryStage else { return }
            self.check(stage.failures.isEmpty, "entry stage finished without failures (\(stage.failures))")
            self.check(stage.checks >= 18, "entry stage ran its cases (checks=\(stage.checks))")
            self.finish()
        }
    }

    /// The rows of a scene, loaded with the estimates the style stage uses.
    func reloadForAccordionStage() {
        listLayout.clearToolGroupAccordion()
        listLayout.clearHeightCache()
        for i in 0..<rows.count { listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: i) }
        list.reloadData()
        list.setNeedsLayout()
        list.layoutIfNeeded()
    }

    func captureAccordionFrame(_ name: String) {
        list.setNeedsLayout()
        list.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: list.bounds)
        let img = renderer.image { ctx in list.drawHierarchy(in: list.bounds, afterScreenUpdates: true) }
        if let data = img.pngData() {
            try? data.write(to: output.appendingPathComponent("\(name).png"))
            pngCount += 1
        }
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
