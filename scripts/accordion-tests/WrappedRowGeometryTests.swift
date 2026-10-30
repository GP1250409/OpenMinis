import SwiftUI
import UIKit

// Only action dispatch and menu business logic are doubles. The actual
// SessionStackRow and ButtonStyle expressions are extracted verbatim.
enum HomeListPerf { static func rowBuilt() {} }
struct MenuKey: Equatable {
    let sid: String
    let pinned: Bool
    let title: String?
    let filed: Bool
}
final class SessionMenuActionChannel {
    enum Action { case open(String) }
    func send(_ action: Action) {}
}
struct SessionContextMenu: View, Equatable {
    let key: MenuKey
    let actions: SessionMenuActionChannel
    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    var body: some View { Button("Open") { actions.send(.open(key.sid)) } }
}
struct DiagnosticPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, rhs in rhs })
    }
}
enum DiagnosticFrames { static var current: [String: CGRect] = [:] }
struct RowDiagnosticProbe: View {
    let name: String
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: DiagnosticPreference.self,
                value: [name: geo.frame(in: .global)])
        }
        .onPreferenceChange(DiagnosticPreference.self) { value in
            DiagnosticFrames.current.merge(value, uniquingKeysWith: { _, rhs in rhs })
        }
    }
}
func wrappedDiagnosticRow(_ index: Int, folder: Bool = true) -> AnyView {
    var session = ChatSession()
    session.id = "wrapped-\(index)"
    session.title = index % 2 == 0 ? "欧路词典 LM5 释义显示问题" : "停用 frida-server 服务"
    return AnyView(SessionStackRow(session: session, isActive: false, isSuspended: false,
        highlightQuery: nil, matchSnippet: nil, isRegeneratingTitle: false,
        inFolder: folder, isLastInFolder: false, menuActions: SessionMenuActionChannel())
        .background {
            if folder { FolderMemberRowBackground(isLast: false) }
            else { Color(UIColor.systemBackground) }
        })
}

extension AccordionTestApp {
    func diagnosticImage(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            context.cgContext.setFillColor(UIColor.systemBackground.resolvedColor(with: view.traitCollection).cgColor)
            context.cgContext.fill(view.bounds)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("row-chain-\(name).png"))
    }
    func printGeometry(_ name: String, _ cell: UICollectionViewCell, _ owner: UIViewController) {
        func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        let host = owner.children.compactMap { $0 as? AccordionRowHostingController }
            .first { $0.view.superview === cell.contentView }
        var data: [String: Any] = ["case": name, "cellFrame": rect(cell.frame),
            "cellBounds": rect(cell.bounds), "contentFrame": rect(cell.contentView.frame),
            "contentBounds": rect(cell.contentView.bounds)]
        if let host {
            data["hostFrame"] = rect(host.view.frame)
            data["hostBounds"] = rect(host.view.bounds)
            data["hostSafeArea"] = [host.view.safeAreaInsets.top, host.view.safeAreaInsets.bottom]
        }
        let path = (cell.superview as? UICollectionView)?.indexPath(for: cell)
        let memberKey = path.map { "wrapped-\($0.item - 2)" }
        data["swiftUI"] = DiagnosticFrames.current.filter { key, _ in
            key == "folder-body" || (memberKey.map { key.hasSuffix($0) } ?? false)
        }.mapValues { rect($0) }
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) { print("ROW_CHAIN \(line)") }
    }
    func hostRegionAB(_ native: NativeAccordionController) {
        guard #available(iOS 16.4, *) else {
            print("ROW_REGION_AB unavailable before iOS16.4"); return
        }
        let candidates = native.collection.visibleCells.sorted { $0.frame.minY > $1.frame.minY }
        for cell in candidates {
            guard let path = native.collection.indexPath(for: cell), path.section == 1, path.item >= 2,
                  let host = native.children.compactMap({ $0 as? AccordionRowHostingController })
                    .first(where: { $0.view.superview === cell.contentView }),
                  host.view.safeAreaInsets.bottom > 0,
                  cell.convert(cell.bounds, to: native.view).maxY <= native.view.bounds.maxY else { continue }
            let key = "body-wrapped-\(path.item - 2)"
            let cellY = cell.convert(cell.bounds, to: window).minY
            check(host.safeAreaRegions.isEmpty, "production row host disables forwarding by default")
            check(abs((DiagnosticFrames.current[key]?.minY ?? -999) - cellY) < 0.5,
                "production default aligns complete wrapped body before any test mutation")
            let productionRegions = host.safeAreaRegions
            host.safeAreaRegions = .all
            host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.2)
            let before = DiagnosticFrames.current[key]?.minY
            printGeometry("region-before", cell, native)
            diagnosticImage(cell, name: "region-before")
            let beforePixels = rowRaster(cell)
            let previous = host.safeAreaRegions
            host.safeAreaRegions = []
            host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.2)
            let after = DiagnosticFrames.current[key]?.minY
            let afterPixels = rowRaster(cell)
            let changed = zip(beforePixels, afterPixels).filter { abs(Int($0.0) - Int($0.1)) > 8 }.count
            printGeometry("region-after", cell, native)
            diagnosticImage(cell, name: "region-after")
            print("ROW_REGION_AB cellY=\(cellY) beforeBodyY=\(String(describing: before)) afterBodyY=\(String(describing: after)) changed=\(changed)")
            // safeAreaRegions controls what SwiftUI consumes; UIKit's view
            // safeAreaInsets may correctly stay 34pt. Assert rendered geometry,
            // not an unrelated assumption that the UIKit value becomes zero.
            check(host.safeAreaRegions.isEmpty, "host safe-area forwarding regions are disabled")
            check(changed > 40, "same fully wrapped row changes when host safeAreaRegions changes")
            if let before, let after {
                check(abs(after - cellY) < 0.5, "disabled host regions align wrapped body exactly with cell")
                check(abs((after - before) - 17) < 0.5, "same row A/B removes measured 17pt upward displacement")
            } else { check(false, "per-session body geometry captured for both A/B states") }
            host.safeAreaRegions = previous
            host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.1)
            let restored = DiagnosticFrames.current[key]?.minY
            check(restored == before, "restoring host regions reproduces the original displaced body")
            host.safeAreaRegions = productionRegions
            host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.1)
            return
        }
        check(false, "A/B selected a fully visible row with a real inherited bottom safe area")
    }
    func folderHostRegionAB() {
        guard #available(iOS 16.4, *) else { return }
        let owner = UIViewController()
        window!.rootViewController = owner
        owner.overrideUserInterfaceStyle = .light
        owner.view.backgroundColor = .systemBackground
        owner.view.layoutIfNeeded(); pump(0.2)
        let cell = AccordionHostingCell(frame: CGRect(x: 0, y: owner.view.bounds.height - 68,
            width: owner.view.bounds.width, height: 68))
        owner.view.addSubview(cell)
        let group = SidebarGroup(id: "web-test", folderId: "web-test", ids: ["one"],
            label: "网站开发", isCollapsed: true)
        cell.set(AnyView(ProductionFolderHeaderFixture(group: group)), height: 68, owner: owner)
        cell.layoutIfNeeded(); pump(0.2)
        let host = owner.children.compactMap { $0 as? AccordionRowHostingController }.last!
        check(host.safeAreaRegions.isEmpty, "production folder host disables forwarding by default")
        let defaultBody = DiagnosticFrames.current["folder-body"]?.minY
        host.safeAreaRegions = .all
        host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.2)
        printGeometry("folder-before", cell, owner)
        diagnosticImage(cell, name: "folder-before")
        let before = DiagnosticFrames.current["folder-body"]?.minY
        host.safeAreaRegions = []
        host.view.setNeedsLayout(); host.view.layoutIfNeeded(); pump(0.2)
        let after = DiagnosticFrames.current["folder-body"]?.minY
        printGeometry("folder-after", cell, owner)
        diagnosticImage(cell, name: "folder-after")
        print("FOLDER_REGION_AB before=\(String(describing: before)) after=\(String(describing: after))")
        if let before, let after {
            check(defaultBody == after, "production default folder matches corrected A/B position")
            check(abs(after - before - 17) < 0.5, "website group A/B removes same 17pt upward displacement")
        } else { check(false, "website group body geometry recorded") }
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        cell.removeFromSuperview()
    }
    func wrappedRowGeometryTest() {
        let baseline = UIHostingController(rootView:
            List { ForEach(0..<12, id: \.self) { index in
                SessionStackRow(session: ChatSession(), isActive: false, isSuspended: false,
                    highlightQuery: nil, matchSnippet: nil, isRegeneratingTitle: false,
                    inFolder: true, isLastInFolder: false, menuActions: SessionMenuActionChannel())
            } }.listStyle(.plain))
        window!.rootViewController = baseline
        baseline.overrideUserInterfaceStyle = .light
        baseline.view.layoutIfNeeded(); pump(0.4)
        diagnosticImage(baseline.view, name: "original-list")
        print("ROW_CHAIN_BASELINE \(DiagnosticFrames.current)")
        let native = NativeAccordionController(viewport: AccordionViewportState(), bottomInset: 0)
        window!.rootViewController = native
        native.overrideUserInterfaceStyle = .light
        native.view.layoutIfNeeded()
        let render: NativeAccordionController.Renderer = { group, _, role in
            switch role {
            case .folder: return AnyView(ProductionFolderHeaderFixture(group: group))
            case .member(let index): return wrappedDiagnosticRow(index)
            case .label: return AnyView(Text("Groups").frame(maxWidth: .infinity, maxHeight: .infinity))
            }
        }
        native.receive(sections(1, count: 100), render: render)
        native.view.layoutIfNeeded(); pump(0.4)
        for (step, offset) in [CGFloat(0), 204, 680, 1360, 2720, 680, 0].enumerated() {
            native.collection.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            native.collection.layoutIfNeeded(); pump(0.12)
            for cell in native.collection.visibleCells {
                guard let path = native.collection.indexPath(for: cell) else { continue }
                printGeometry("scroll-\(step)-\(path.section)-\(path.item)", cell, native)
                check(abs(cell.contentView.bounds.height - cell.bounds.height) < 0.5,
                    "full wrapper contentView height matches visible cell")
            }
            if step == 0 {
                diagnosticImage(native.view, name: "native-\(step)")
                hostRegionAB(native)
            } else if step == 5 { diagnosticImage(native.view, name: "native-\(step)") }
        }
        native.receive(sections(nil, count: 100), render: render)
        pump(0.12)
        diagnosticImage(native.view, name: "collapsing")
        for cell in native.collection.visibleCells { printGeometry("collapsing", cell, native) }
        pump(0.4)
        native.receive(sections(1, count: 100), render: render); pump(0.5)
        diagnosticImage(native.view, name: "expanded-again")
        for cell in native.collection.visibleCells { printGeometry("expanded-again", cell, native) }
        native.stop()
        folderHostRegionAB()
    }
}
