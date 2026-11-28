import UIKit
import SwiftUI

// Minimal model stub: the actual UIKit layout/controller are compiled verbatim.
struct SidebarGroup {
    var id: String
    var folderId: String?
    var ids: [String]
    var label: String
    var isCollapsed: Bool
    var glyphs: [FolderGlyph] = [FolderGlyph()]
    var anyActive = false
    var anyPaused = false
    var anyUnread = false
    var totalCount = 5
    var summaryTitle: String? = nil
    var summarySessionId: String? = nil
    var latestDate: Date? = nil
    var isFolderPinned = false
}
func AppLocalized(_ s: String) -> String { s }
/// Test double for the app's ObjC breadcrumb recorder.
enum CrashBreadcrumbs {
    static var recorded: [String] = []
    static func record(_ kind: String, detail: String) { recorded.append("\(kind) \(detail)") }
}

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
        // [T-sidebar-mail-fold] The reveal is now a BOTTOM-aligned block clipped
        // at the header, so at a sliver of progress the row that is partially
        // visible is the LAST member (clipped at its top), not the first. The
        // intent of this check is unchanged: real geometry, never alpha/scale.
        let s1 = layout.sections[1]
        let partial = layout.layoutAttributesForItem(at: IndexPath(item: 2 + s1.count - 1, section: 1))!
        check(partial.frame.height > 0 && partial.frame.height < 68, "real partial-height member, not alpha or scale")
        check((partial as? AccordionRowAttributes)?.clipTop ?? 0 > 0, "partial member is clipped at the header, not its bottom")
        check(layout.naturalHeight > closedHeight, "following groups move with growing member region")
        let hidden = layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 1))!
        check(hidden.isHidden, "rows still behind the header stay hidden")
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
        mailFoldGeometryTest()
        mailFoldMotionTest()
        rowClippingTest()
        wrappedRowGeometryTest()
        floatingBarTest()
        sidebarChromeTest()
        folderAppearanceTest()
        recentBucketSpacingTest()
        usageStampTest()
        print("ACCORDION_UIKIT_PASS \(passed)"); fflush(stdout); exit(0)
    }
    func checkSilent(_ condition: Bool) { if !condition { check(false, "anchor geometry"); } }

    /// [T-sidebar-recent-section] "最近" and "置顶" are the SAME kind of section:
    /// one 32pt label slot, then real rows only. Folded, a bucket contributes
    /// nothing but its label; expanded, it adds exactly its rows — no minimum
    /// height, no inter-section spacing. That is the spacing contract the
    /// official sidebar breaks (its folded Recent leaves a row-sized hole) and
    /// this one must not: 最近→置顶 == 置顶→分组 == one label slot when folded,
    /// and every expanded boundary is flush.
    func recentBucketSpacingTest() {
        let layout = AccordionCollectionLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                          collectionViewLayout: layout)
        collection.contentInset = .zero
        layout.sections = [
            AccordionSectionGeometry(id: "b:Recent", folderID: nil, count: 5, rowHeight: 68,
                                     labelHeight: 32, headerHeight: 0, footerHeight: 0),
            AccordionSectionGeometry(id: "b:Pinned", folderID: nil, count: 3, rowHeight: 68,
                                     labelHeight: 32, headerHeight: 0, footerHeight: 0),
            AccordionSectionGeometry(id: "f:g", folderID: "g", count: 2, rowHeight: 68,
                                     labelHeight: 32, headerHeight: 68, footerHeight: 4),
        ]

        // The group card behind them stays EXPANDED, exactly as a folder card
        // ships (only the two date buckets toggle), so its own rows are part of
        // every expectation below.
        // NOTE: the slots are named CGFloat constants on purpose. Written as one
        // literal chain inside `check`'s @autoclosure every literal becomes
        // overloadable against CGFloat and the compiler gives up ("unable to
        // type-check this expression in reasonable time"), which is what killed
        // the first CI run of this fixture.
        let labelSlot: CGFloat = 32
        let rowSlot: CGFloat = 68
        // A group card's WHOLE contribution to naturalHeight: its own 32pt
        // "Groups" label, the 68pt header, one 68pt row per member and the 4pt
        // footer. The previous version defined `groupChrome` as header+footer
        // only, so `groupExpanded` was 32pt short of what prepare() actually
        // adds for this section (production builds folder sections with
        // labelHeight 32 / headerHeight 68 / footerHeight 4 — see
        // ContentView+NativeAccordion.swift). That fixture arithmetic, not the
        // shipping layout, is what failed on the simulator.
        let groupChrome: CGFloat = labelSlot + 68 + 4   // own label + header + footer
        let groupExpanded: CGFloat = groupChrome + 2 * rowSlot

        // Reports the two real numbers before an exact-equality assertion, so a
        // future mismatch shows the actual/expected geometry instead of only a
        // test name. The assertion itself stays exact.
        func checkHeight(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
            print("HEIGHT \(name) actual=\(actual) expected=\(expected) delta=\(actual - expected)")
            fflush(stdout)
            check(actual == expected, name)
        }

        // Both date buckets folded: equal 32pt pitches, no reserved member rows.
        layout.reveal = [0, 0, 1]
        layout.prepare()
        check(layout.starts[1] - layout.starts[0] == labelSlot, "folded 最近→置顶 pitch is one 32pt label slot")
        check(layout.starts[2] - layout.starts[1] == labelSlot, "folded 置顶→分组 pitch is one 32pt label slot")
        // Only the two folded date buckets still add a label; the group's own
        // label is already inside groupExpanded.
        let foldedHeight: CGFloat = 2 * labelSlot + groupExpanded
        checkHeight(layout.naturalHeight, foldedHeight, "a folded bucket reserves no member height")
        print("RECENT_BUCKET_SPACING_PASS folded_pitch=32 reserved_rows=0"); fflush(stdout)

        // 最近 expanded: label→row pitch is the label's own height, and the last
        // row sits flush on the 置顶 title.
        layout.reveal = [1, 0, 1]
        layout.prepare()
        let recentLabel = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!
        let recentFirst = layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))!
        let recentLast = layout.layoutAttributesForItem(at: IndexPath(item: 5, section: 0))!
        check(recentLabel.frame.height == 32, "最近 keeps the shared 32pt label slot")
        check(recentFirst.frame.minY == recentLabel.frame.maxY, "最近 title→first row has no extra gap")
        check(recentLast.frame.maxY == layout.starts[1], "last 最近 row meets 置顶 title with no gap")
        let recentExpandedHeight: CGFloat = labelSlot + 5 * rowSlot + labelSlot + groupExpanded
        checkHeight(layout.naturalHeight, recentExpandedHeight,
                    "expanded 最近 adds exactly its five real rows and nothing else")

        // 置顶 expanded between a folded Recent and the Groups divider.
        layout.reveal = [0, 1, 1]
        layout.prepare()
        let pinnedLabel = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))!
        let pinnedFirst = layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 1))!
        let pinnedLast = layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 1))!
        check(pinnedFirst.frame.minY == pinnedLabel.frame.maxY, "置顶 title→first row has no extra gap")
        check(pinnedLast.frame.maxY == layout.starts[2], "last pinned row meets 分组 with no gap")
        let pinnedExpandedHeight: CGFloat = labelSlot + labelSlot + 3 * rowSlot + groupExpanded
        checkHeight(layout.naturalHeight, pinnedExpandedHeight,
                    "expanded 置顶 adds exactly its three real rows and nothing else")

        // Both expanded: the two buckets stack on the same rhythm.
        layout.reveal = [1, 1, 1]
        layout.prepare()
        let recentOpenPitch: CGFloat = labelSlot + 5 * rowSlot
        check(layout.starts[1] - layout.starts[0] == recentOpenPitch,
              "expanded 最近→置顶 pitch is its label plus its rows")
        print("RECENT_BUCKET_SPACING_PASS expanded_pitch=32 row=68 footer=0"); fflush(stdout)
    }
}
