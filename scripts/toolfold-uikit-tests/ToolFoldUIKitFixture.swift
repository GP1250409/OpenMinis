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
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w

        let layout = MessageListLayout()
        layout.estimatedItemHeight = Self.initialEstimateHeight
        layout.itemSpacing = 4
        listLayout = layout
        list = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 760), collectionViewLayout: layout)
        list.contentInsetAdjustmentBehavior = .never
        list.register(ToolGroupCellV3.self, forCellWithReuseIdentifier: "group")
        list.dataSource = self
        vc.view.addSubview(list)
        vc.view.layoutIfNeeded()

        DispatchQueue.main.async { self.renderStyle(0) }
        return true
    }

    func runLifecycleChecks() {
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

    func renderStyle(_ step: Int) {
        let styles: [(String, UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]
        if step == styles.count {
            testToggleNotification()
            return
        }
        let (name, style) = styles[step]
        window!.overrideUserInterfaceStyle = style
        list.backgroundColor = ChatColors.backgroundUIColor
        listLayout.clearHeightCache()
        for i in 0..<rows.count {
            listLayout.setEstimatedHeight(Self.initialEstimateHeight, at: i)
        }
        list.reloadData()
        list.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.list.setNeedsLayout()
            self.list.layoutIfNeeded()
            let expectedContentH = CGFloat(self.rows.count) * ToolGroupRowView.rowHeight
                + CGFloat(max(0, self.rows.count - 1)) * self.listLayout.itemSpacing
            let contentSize = self.listLayout.collectionViewContentSize
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
                    format: "TOOLFOLD_UIKIT_DIAG style=%@ row=%@ est=%.1f frame=%.1fx%.1f attrs=%.1fx%.1f layoutCache=%.1f fit=%.1fx%.1f contentFit=%.1fx%.1f intrinsic=%.1fx%.1f hostIntrinsic=%.1fx%.1f contentSize=%.1fx%.1f",
                    name, self.rows[i].label, Self.initialEstimateHeight,
                    frameSize.width, frameSize.height,
                    attrs.size.width, attrs.size.height,
                    layoutCacheH,
                    fit.width, fit.height,
                    contentFit.width, contentFit.height,
                    intrinsic.width, intrinsic.height,
                    hostIntrinsic.width, hostIntrinsic.height,
                    contentSize.width, contentSize.height
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
