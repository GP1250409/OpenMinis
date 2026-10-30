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
        data["swiftUI"] = DiagnosticFrames.current.mapValues { rect($0) }
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) { print("ROW_CHAIN \(line)") }
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
            if step == 0 || step == 5 { diagnosticImage(native.view, name: "native-\(step)") }
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
    }
}
