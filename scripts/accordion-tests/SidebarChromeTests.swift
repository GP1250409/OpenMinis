import SwiftUI
import UIKit

final class SidebarChromeState: ObservableObject {
    @Published var mode = 0
    @Published var path: [String] = []
    @Published var sheet = false
    let viewport = AccordionViewportState()
    let sections: [AccordionRenderSection]
    init(sections: [AccordionRenderSection]) { self.sections = sections }
}

struct SidebarChromeFixture: View {
    @ObservedObject var state: SidebarChromeState
    var body: some View {
        NavigationStack(path: $state.path) {
            Group {
                if state.mode == 0 {
                    FloatingSidebarSurface {
                        NativeAccordionList(sections: state.sections, viewport: state.viewport,
                            bottomInset: 76, toggle: { _ in }, render: { group, _, _ in
                                AnyView(Text(group.label).frame(maxWidth: .infinity, maxHeight: .infinity))
                            })
                    } controls: { Text("Floating controls").frame(height: 76) }
                } else {
                    List { Text(state.mode == 1 ? "Search" : "Selection") }
                }
            }
            .modifier(SidebarNavigationChrome {
                ToolbarItem(placement: .navigationBarLeading) { Button("Settings") {} }
                ToolbarItem(placement: .principal) { Text("minis") }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Terminal") {} }
            })
            .navigationDestination(for: String.self) { _ in
                Text("Chat destination").navigationTitle("Chat")
                    .toolbar(.hidden, for: .navigationBar)
            }
            .sheet(isPresented: $state.sheet) {
                NavigationStack { Text("Tool sheet").navigationTitle("Tool") }
            }
        }
    }
}

extension AccordionTestApp {
    func findNavigation(_ vc: UIViewController) -> UINavigationController? {
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children { if let nav = findNavigation(child) { return nav } }
        return nil
    }
    func sidebarChromeTest() {
        let state = SidebarChromeState(sections: sections(nil, count: 100))
        let host = UIHostingController(rootView: SidebarChromeFixture(state: state))
        window!.rootViewController = host
        host.view.layoutIfNeeded(); pump(0.6)
        guard let nav = findNavigation(host) else {
            check(false, "sidebar has a real UIKit navigation controller"); return
        }
        func verify(_ reason: String) {
            host.view.layoutIfNeeded(); pump(0.12)
            let item = nav.navigationBar.topItem ?? nav.topViewController?.navigationItem
            // iOS 26 may expose toolbar controls as item GROUPS rather than
            // left/rightBarButtonItems. Inspect both public representations.
            let leading = (item?.leftBarButtonItems?.count ?? 0) + (item?.leadingItemGroups.reduce(0) { $0 + $1.barButtonItems.count } ?? 0)
            let trailing = (item?.rightBarButtonItems?.count ?? 0) + (item?.trailingItemGroups.reduce(0) { $0 + $1.barButtonItems.count } ?? 0)
            print("NAV_CHROME \(reason) hidden=\(nav.isNavigationBarHidden) left=\(leading) right=\(trailing) center=\(item?.centerItemGroups.count ?? 0)")
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nav-current.png"))
            check(!nav.isNavigationBarHidden && !nav.navigationBar.isHidden, "root navigation bar visible: \(reason)")
            check(leading > 0, "settings menu retained: \(reason)")
            check(trailing > 0, "terminal menu retained: \(reason)")
            check(item?.titleView != nil || !(item?.title?.isEmpty ?? true) || !(item?.centerItemGroups.isEmpty ?? true), "principal title retained: \(reason)")
        }
        verify("initial native")
        for n in 0..<4 {
            state.mode = 1; pump(0.2); verify("search \(n)")
            state.mode = 2; pump(0.2); verify("selection \(n)")
            state.mode = 0; pump(0.2); verify("native \(n)")
            state.path = ["chat"]; pump(0.45)
            check(nav.isNavigationBarHidden, "destination can independently hide its bar")
            state.path = []; pump(0.45); verify("chat pop \(n)")
            state.sheet = true; pump(0.45)
            check(host.presentedViewController != nil, "tool sheet really presented")
            state.sheet = false; pump(0.55); verify("sheet dismissed \(n)")
        }
        if let native = findNative(host) { native.stop() }
    }
}
