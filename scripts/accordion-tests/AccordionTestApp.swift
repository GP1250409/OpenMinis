import UIKit
import SwiftUI

// Minimal model stub: the actual UIKit layout/controller are compiled verbatim.
struct SidebarGroup {
    var id: String
    var folderId: String?
    var ids: [String]
    var label: String
    var isCollapsed: Bool
}
func AppLocalized(_ s: String) -> String { s }

@main
final class AccordionTestApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var passed = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { print("FAIL: \(name)"); fflush(stdout); exit(2) }
        passed += 1; print("PASS: \(name)"); fflush(stdout)
    }
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.runTests() }
        return true
    }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
    func spec(_ id: String, count: Int, folder: Bool = true) -> AccordionSectionGeometry {
        AccordionSectionGeometry(id: id, folderID: folder ? id : nil, count: count,
            rowHeight: 68, labelHeight: 32, headerHeight: folder ? 68 : 0, footerHeight: folder ? 4 : 0)
    }
    func sections(_ expanded: Int?, count: Int = 4700) -> [AccordionRenderSection] {
        [2, count, 12, 80].enumerated().map { i, n in
            let id = "g\(i)"; let ids = (0..<n).map { "\(id)-\($0)" }
            return AccordionRenderSection(group: SidebarGroup(id: id, folderId: i == 0 ? nil : id,
                ids: ids, label: i == 0 ? "Pinned" : id, isCollapsed: i != 0 && i != expanded),
                members: ids, geometry: spec(id, count: n, folder: i != 0))
        }
    }
    func runTests() {
        let layout = AccordionCollectionLayout()
        let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        layout.sections = [spec("p", count: 2, folder: false), spec("a", count: 4700), spec("b", count: 10)]
        layout.reveal = [1, 0, 0]; layout.prepare()
        let closedHeight = layout.naturalHeight
        check((layout.layoutAttributesForElements(in: cv.bounds) ?? []).count < 20, "4700 collapsed members produce no eager cells")
        layout.reveal = [1, 0.0001, 0]; layout.prepare()
        let partial = layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 1))!
        check(partial.frame.height > 0 && partial.frame.height < 68, "real partial-height member, not alpha or scale")
        check(layout.naturalHeight > closedHeight, "following groups move with growing member region")
        let hidden = layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 1))!
        check(hidden.isHidden, "unrevealed rows stay hidden")
        layout.reveal = [1, 1, 0]; layout.prepare()
        let attributes = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 100000, width: 390, height: 844)) ?? []
        check(attributes.count < 25, "deep scroll visits only viewport rows in huge group")
        let t0 = CACurrentMediaTime()
        for n in 0..<10000 {
            _ = layout.layoutAttributesForElements(in: CGRect(x: 0, y: CGFloat(n % 2000) * 68, width: 390, height: 844))
        }
        print("GEOMETRY_10000_QUERY_SECONDS \(CACurrentMediaTime() - t0)")
        for n in 0...1000 {
            let p = CGFloat(n) / 1000
            let current = 20000 - 19000 * p
            let shift = AccordionMotion.translation(startHeader: 20000, currentHeader: current,
                endHeader: 1000, startOffset: 19500, endOffset: 500, progress: p)
            checkSilent(abs(current + shift - 19500 - 500) < 0.001)
        }
        check(true, "1001 anchor samples remain stationary without changing contentOffset")
        check(AccordionMotion.ease(0) == 0 && AccordionMotion.ease(1) == 1, "motion endpoints exact")
        check(AccordionMotion.clampedOffset(-100, contentHeight: 20, viewportHeight: 800, inset: .zero) == 0,
              "short-content boundary clamp")

        let controller = NativeAccordionController(viewport: AccordionViewportState(), bottomInset: 0)
        window!.rootViewController = controller
        let render: NativeAccordionController.Renderer = { group, _, role in
            AnyView(Text(group.label).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray.opacity(0.1)))
        }
        controller.receive(sections(nil), render: render)
        controller.view.layoutIfNeeded(); pump(0.2)
        check(controller.collection.numberOfItems(inSection: 1) == 4702, "native data source retains stable membership")
        check(controller.collection.visibleCells.count < 35, "UIKit creates only visible cells")
        controller.receive(sections(2), render: render)
        pump(0.12)
        let progress = controller.accordionLayout.reveal[2]
        check(progress > 0 && progress < 1, "real CADisplayLink drives intermediate reveal")
        controller.receive(sections(1), render: render)
        controller.receive(sections(nil), render: render)
        pump(0.85)
        check(controller.accordionLayout.reveal == [1, 0, 0, 0], "rapid taps converge to latest intent")
        check(controller.accordionLayout.translation == 0, "transition translation removed after commit")
        check(controller.accordionLayout.minimumContentHeight == 0, "no residual artificial scroll range")
        controller.receive(sections(1), render: render)
        pump(0.5)
        let sc = controller.collection
        let bY = controller.accordionLayout.headerY(section: 2)
        sc.setContentOffset(CGPoint(x: 0, y: bY - 250), animated: false)
        sc.layoutIfNeeded(); pump(0.08)
        let initialY = controller.accordionLayout.headerY(section: 2) - sc.contentOffset.y
        controller.receive(sections(2), render: render)
        var maxError: CGFloat = 0
        var offsets: [CGFloat] = []
        for _ in 0..<5 {
            pump(0.04)
            let y = controller.accordionLayout.headerY(section: 2) + controller.accordionLayout.translation - sc.contentOffset.y
            maxError = max(maxError, abs(y - initialY))
            offsets.append(sc.contentOffset.y)
        }
        check(maxError < 1, "long A to B preserves tapped title within one point")
        check((offsets.max()! - offsets.min()!) < 0.1, "no per-frame contentOffset correction loop")
        pump(0.5)
        let finalY = controller.accordionLayout.headerY(section: 2) - sc.contentOffset.y
        check(abs(finalY - initialY) < 1, "atomic final offset commit has no anchor jump")
        check(controller.collection.visibleCells.count < 35, "long switch retains bounded cell count")
        let baseline = controller.configuredCellCount
        pump(0.1)
        check(controller.configuredCellCount == baseline, "idle does not rebuild cells")
        print("STAGE: request C"); fflush(stdout)
        controller.receive(sections(3), render: render)
        print("STAGE: pump C"); fflush(stdout)
        pump(0.08)
        print("STAGE: interrupt by drag"); fflush(stdout)
        controller.scrollViewWillBeginDragging(sc)
        print("STAGE: after interruption"); fflush(stdout)
        pump(0.5)
        check(controller.accordionLayout.translation == 0, "user drag stops the transition cleanly")
        controller.stop()
        check(controller.accordionLayout.minimumContentHeight == 0, "teardown leaves no animation state")
        print("ACCORDION_UIKIT_PASS \(passed)"); fflush(stdout); exit(0)
    }
    func checkSilent(_ condition: Bool) { if !condition { check(false, "anchor geometry"); } }
}
