import SwiftUI
import UIKit

// Service/model doubles only. SessionRow, its fonts/padding, and the folder
// header's actual rendering expression are compiled from production sources.
struct ChatSession {
    var id = "fixture"
    var title: String? = "朗文专题数据统计讨论"
    var lastMessage: String? = "明白，那这里是正常行为：abbreviate"
    var updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var pinnedAt: Date? = nil
    var category: String? = "support"
    var source: String? = nil
    var remoteDeviceId: String? = nil
    var isPinned: Bool { pinnedAt != nil }
    var isRemote: Bool { remoteDeviceId != nil }
}
struct FolderGlyph: Equatable { var color: Color = .orange }
final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    func isActive(_ id: String) -> Bool { false }
}
final class SessionConcurrencyManager: ObservableObject {
    static let shared = SessionConcurrencyManager()
    func isSuspended(_ id: String) -> Bool { false }
}
final class SessionLockStore: ObservableObject {
    static let shared = SessionLockStore()
    func isVisuallyLocked(_ id: String) -> Bool { false }
}
enum SessionBadgeState { case paused, iCloudSyncing, unread }
final class SessionBadgeStore: ObservableObject {
    static let shared = SessionBadgeStore()
    func topCornerBadge(for id: String) -> SessionBadgeState? { nil }
    func hasUnread(for id: String) -> Bool { false }
}
final class FontSettings: ObservableObject {
    static let shared = FontSettings()
    @Published var scale: CGFloat = 1
    func scaledApp(_ value: CGFloat) -> CGFloat { value * scale }
}
enum PerfTrace {
    static func measure<T>(_ name: String, _ body: () -> T) -> T { body() }
}
enum SearchKeywords {
    static func terms(_ query: String) -> [String] { [query] }
    static func firstHit(in text: String, terms: [String]) -> Range<String.Index>? { nil }
    static func hitRanges(in text: String, terms: [String]) -> [Range<String.Index>] { [] }
}
struct SpinningRing: View { let color: Color; var body: some View { Circle().stroke(color) } }

extension AccordionTestApp {
    func rowRaster(_ view: UIView) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cg = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }
    func rowClippingTest() {
        let owner = UIViewController()
        window!.rootViewController = owner
        owner.view.backgroundColor = .systemBackground
        owner.view.layoutIfNeeded(); pump(0.15)
        for style in [UIUserInterfaceStyle.light, .dark] {
            owner.overrideUserInterfaceStyle = style
            for scale: CGFloat in [0.85, 1, 1.4] {
                FontSettings.shared.scale = scale
                let title = UIFont.systemFont(ofSize: scale * 16, weight: .semibold).lineHeight
                let subtitle = UIFont.systemFont(ofSize: scale * 14).lineHeight
                let rowHeight = ceil(max(44, title + 4 + subtitle) + 24)
                for (index, name) in ["网站开发", "朗文专题数据统计讨论", "停用 frida-server 服务", "English gypq clipping"].enumerated() {
                    var group = SidebarGroup(id: "web", folderId: "web", ids: ["one"], label: name, isCollapsed: true)
                    group.summaryTitle = "5 个会话 · 查看完整的中文与 English 摘要"
                    var session = ChatSession(); session.title = name
                    let content: AnyView = index < 2
                        ? AnyView(ProductionFolderHeaderFixture(group: group))
                        : AnyView(SessionRow(session: session))
                    let height: CGFloat = index < 2 ? 68 : rowHeight
                    let cell = AccordionHostingCell(frame: CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: height))
                    owner.view.addSubview(cell)
                    cell.set(content, height: height, owner: owner)
                    cell.layoutIfNeeded(); pump(0.08)
                    let host = owner.children.compactMap { $0 as? AccordionRowHostingController }.last!
                    let reference = rowRaster(cell)
                    host.additionalSafeAreaInsets = UIEdgeInsets(top: 24, left: 0, bottom: 12, right: 0)
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.08)
                    let insetRaster = rowRaster(cell)
                    let changed = zip(reference, insetRaster).filter { abs(Int($0.0) - Int($0.1)) > 8 }.count
                    print("ROW_SAFEAREA style=\(style.rawValue) scale=\(scale) title=\(name) changed=\(changed)")
                    check(changed < 16, "row pixels invariant under inherited safe area: \(name) \(style.rawValue)/\(scale)")
                    check(host.navigationController == nil, "safe-area fix retains navigation isolation")
                    check(abs(host.view.bounds.height - height) < 0.1, "row keeps full layout height")
                    // A/B control: the old root must visibly respond to the
                    // same inset, otherwise this fixture has not exercised it.
                    host.rootView = AnyView(content.frame(maxWidth: .infinity).frame(height: height, alignment: .top))
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.08)
                    let legacy = rowRaster(cell)
                    let oldChanged = zip(reference, legacy).filter { abs(Int($0.0) - Int($0.1)) > 8 }.count
                    check(oldChanged > 40, "legacy unisolated root reproduces inset-induced clipping")
                    // Restore production root, then emulate partial accordion reveal.
                    cell.set(content, height: height, owner: owner)
                    cell.frame.size.height = height / 2
                    cell.layoutIfNeeded(); pump(0.04)
                    check(abs(host.view.bounds.height - height) < 0.1, "partial reveal clips outside without squeezing text")
                    if scale == 1 && style == .light {
                        cell.frame.size.height = height; cell.layoutIfNeeded(); pump(0.04)
                        let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
                            cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
                        }
                        try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("row-\(index).png"))
                    }
                    host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                    cell.removeFromSuperview()
                }
            }
        }
        FontSettings.shared.scale = 1
    }
}
