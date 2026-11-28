import SwiftUI
import UIKit

// [T-sidebar-mail-fold] iOS 16 Mail's fold, on the SHIPPING layout and the
// shipping cell. Geometry is asserted between the real endpoints of the real
// sections; motion is sampled from a real CADisplayLink in a real window.
extension AccordionTestApp {
    static let mailRowHeight: CGFloat = 68

    /// Sections: one labelled date bucket (Pinned / Recent path, no header),
    /// one folder card (header + footer), one following folder card.
    func mailFoldFixture(progress p: CGFloat) -> AccordionCollectionLayout {
        let layout = AccordionCollectionLayout()
        layout.sections = [
            AccordionSectionGeometry(id: "recent", folderID: nil, count: 3, rowHeight: Self.mailRowHeight,
                                     labelHeight: 32, headerHeight: 0, footerHeight: 0),
            spec("A", count: 5),
            spec("B", count: 2),
        ]
        layout.reveal = [1, p, 0]
        layout.prepare()
        return layout
    }

    func mailMember(_ layout: AccordionCollectionLayout, _ section: Int, _ row: Int) -> AccordionRowAttributes? {
        layout.layoutAttributesForItem(at: IndexPath(item: layout.sections[section].prefixCount + row,
                                                     section: section)) as? AccordionRowAttributes
    }

    func mailBlockTop(_ layout: AccordionCollectionLayout, _ section: Int) -> CGFloat {
        let s = layout.sections[section]
        return layout.starts[section] + s.labelHeight + s.headerHeight
    }

    /// Every invariant of the bottom-aligned, header-clipped member block, at
    /// one arbitrary intermediate progress value.
    func mailFoldAssertShape(_ layout: AccordionCollectionLayout, _ section: Int, _ p: CGFloat, _ tag: String) {
        let s = layout.sections[section]
        let rowH = s.rowHeight
        let blockTop = mailBlockTop(layout, section)
        let blockBottom = blockTop + s.fullHeight * p
        // Header (or, for a date bucket, the 32pt label) never moves with p.
        // The label (when present) owns the top slot; a folder card's header
        // sits right under it. Either way it must not move with p.
        let headerItem = s.prefixCount - 1
        let header = layout.layoutAttributesForItem(at: IndexPath(item: headerItem, section: section))!
        let expectedHeaderY = s.headerHeight > 0 ? layout.starts[section] + s.labelHeight : layout.starts[section]
        check(abs(header.frame.minY - expectedHeaderY) < 0.001,
              "\(tag) p=\(p) section header stays fixed at its endpoint origin")
        // The LAST member is welded to the moving bottom edge, so the lower
        // sibling (footer slot + next section) follows it at a stable gap.
        let last = mailMember(layout, section, s.count - 1)!
        check(abs(last.frame.maxY - blockBottom) < 0.001,
              "\(tag) p=\(p) last member bottom == moving block bottom")
        check(abs(layout.starts[section + 1] - last.frame.maxY - s.footerHeight) < 0.001,
              "\(tag) p=\(p) gap to the lower sibling stays at the footer pitch")
        var clipped = 0
        var visible: [Int] = []
        for row in 0..<s.count {
            let a = mailMember(layout, section, row)!
            guard !a.isHidden else { continue }
            visible.append(row)
            check(a.frame.height <= rowH + 0.001, "\(tag) p=\(p) row \(row) never grows past its row height")
            check(a.frame.height > 0, "\(tag) p=\(p) row \(row) has real height, not alpha/scale")
            check(a.frame.minY >= blockTop - 0.001, "\(tag) p=\(p) row \(row) never draws above the header")
            check(a.frame.maxY <= blockBottom + 0.001, "\(tag) p=\(p) row \(row) never draws below the block")
            check(abs(a.frame.height - (rowH - a.clipTop)) < 0.001,
                  "\(tag) p=\(p) row \(row) keeps full frame: clipTop is the only hidden part")
            if a.clipTop > 0.001 {
                clipped += 1
                check(abs(a.frame.minY - blockTop) < 0.001,
                      "\(tag) p=\(p) row \(row) is clipped AT the header, not at its own bottom")
                check(row == (visible.first ?? -1), "\(tag) p=\(p) only the first visible row is clipped")
            }
        }
        check(clipped <= 1, "\(tag) p=\(p) at most one partially clipped member row")
        // Last member first: the visible set is always a suffix of the members.
        check(visible == Array((s.count - visible.count)..<s.count),
              "\(tag) p=\(p) visible members are the trailing rows (last child appears first)")
    }

    func mailFoldGeometryTest() {
        let layout = mailFoldFixture(progress: 0)
        // --- endpoints: p == 1 is the SHIPPED layout, bit for bit -----------
        layout.reveal = [1, 1, 0]; layout.prepare()
        let blockTop = mailBlockTop(layout, 1)
        for row in 0..<layout.sections[1].count {
            let a = mailMember(layout, 1, row)!
            check(abs(a.frame.minY - (blockTop + CGFloat(row) * Self.mailRowHeight)) < 0.001
                  && abs(a.frame.height - Self.mailRowHeight) < 0.001 && a.clipTop == 0 && !a.isHidden,
                  "expanded endpoint row \(row) is the untouched full-pitch layout")
        }
        // --- endpoints: p == 0 contributes nothing --------------------------
        layout.reveal = [1, 0, 0]; layout.prepare()
        let collapsed = (0..<layout.sections[1].count).map { mailMember(layout, 1, $0)! }
        check(collapsed.allSatisfy { $0.isHidden && $0.frame.height == 0 },
              "folded endpoint renders no member pixel")
        // --- both directions, non-first members, intermediate p ------------
        // Expansion (0 -> 1) and collapse (1 -> 0) are the same geometry read
        // backwards, so the shape contract is asserted on both traversals.
        let ascending: [CGFloat] = [0.02, 0.1, 0.26, 0.5, 0.73, 0.85, 0.99]
        for p in ascending { layout.reveal = [1, p, 0]; layout.prepare(); mailFoldAssertShape(layout, 1, p, "expand") }
        for p in ascending.reversed() { layout.reveal = [1, p, 0]; layout.prepare(); mailFoldAssertShape(layout, 1, p, "collapse") }
        // Expansion reveals the LAST child first, collapse loses the FIRST.
        layout.reveal = [1, 0.05, 0]; layout.prepare()
        check(!mailMember(layout, 1, 4)!.isHidden, "small p shows the last member first")
        check(mailMember(layout, 1, 0)!.isHidden, "first member is still hidden while folding open")
        layout.reveal = [1, 0.85, 0]; layout.prepare()
        let firstChild = mailMember(layout, 1, 0)!
        check(!firstChild.isHidden && firstChild.clipTop > 1 && firstChild.clipTop < Self.mailRowHeight,
              "first member is the LAST thing to appear, as a clipped slice under the header")
        check(mailMember(layout, 1, 4)!.clipTop == 0 && !mailMember(layout, 1, 4)!.isHidden,
              "last member is already full height by then")
        // Non-first member translation: row 2 only moves DOWN while opening.
        var lastY = -CGFloat.greatestFiniteMagnitude
        for p in ascending {
            layout.reveal = [1, p, 0]; layout.prepare()
            let y = mailMember(layout, 1, 2)!.frame.minY
            check(y >= lastY - 0.001, "expand translates row 2 down, never up (p=\(p))")
            lastY = y
        }
        lastY = .greatestFiniteMagnitude
        for p in ascending.reversed() {
            layout.reveal = [1, p, 0]; layout.prepare()
            let y = mailMember(layout, 1, 2)!.frame.minY
            check(y <= lastY + 0.001, "collapse translates row 2 up, never down (p=\(p))")
            lastY = y
        }
        // --- enumeration includes the partially clipped row -----------------
        layout.reveal = [1, 0.5, 0]; layout.prepare()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 4000)
        let attrs = layout.layoutAttributesForElements(in: viewport)!
        let middle = attrs.filter { $0.indexPath.section == 1 && $0.indexPath.item >= 2 }
        check(middle.count == 3, "p=0.5 enumerates exactly the three touching members, got \(middle.count)")
        check(middle.contains { $0.indexPath.item == 4 && ($0 as! AccordionRowAttributes).clipTop > 0 },
              "the partially clipped first-visible member is enumerated")
        check(!attrs.contains { $0.indexPath.section == 1 && $0.indexPath.item == 3 },
              "members scrolled behind the header are not enumerated")
        check(middle.allSatisfy { $0.frame.intersects(viewport) }, "enumerated frames intersect the viewport")
        // --- the date buckets (Pinned / Recent) fold through the same block --
        for p: CGFloat in [0.15, 0.5, 0.8] {
            layout.reveal = [p, 1, 0]; layout.prepare()
            mailFoldAssertShape(layout, 0, p, "date-bucket")
        }
        layout.reveal = [0.5, 1, 0]; layout.prepare()
        let bucketTop = mailBlockTop(layout, 0)
        let bucketLast = mailMember(layout, 0, 2)!
        check(abs(bucketLast.frame.maxY - (bucketTop + 3 * Self.mailRowHeight * 0.5)) < 0.001,
              "date bucket's last member follows its label bottom, not a card header")
        check(mailMember(layout, 0, 0)!.isHidden, "date bucket reveals its last member first")
        // --- an expanded huge folder stays O(viewport) ----------------------
        let huge = AccordionCollectionLayout()
        huge.sections = [spec("A", count: 4700)]
        huge.reveal = [1]; huge.prepare()
        let deep = huge.layoutAttributesForElements(in: CGRect(x: 0, y: 120000, width: 390, height: 844))!
        check(deep.count < 25, "changing the alignment did not make deep scroll enumerate every member")
        let folded = AccordionCollectionLayout()
        folded.sections = [spec("A", count: 4700)]
        folded.reveal = [0.5]; folded.prepare()
        let half = folded.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 390, height: 844))!
        check(half.count <= 15, "a half-open 4700-row folder enumerates only the rows that touch the window")
    }

    /// Real CADisplayLink frames on the shipping controller: the child block
    /// moves, is clipped at the header, and the tapped header stays put.
    func mailFoldMotionTest() {
        let controller = NativeAccordionController(viewport: AccordionViewportState(), bottomInset: 0)
        window!.rootViewController = controller
        let render: NativeAccordionController.Renderer = { group, _, role in
            AnyView(Text("\(group.label)").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.08)))
        }
        func fixture(expandedA: Bool) -> [AccordionRenderSection] {
            let recentIDs = ["r0", "r1", "r2"]
            let aIDs = (0..<5).map { "a\($0)" }
            let bIDs = ["b0", "b1"]
            return [
                AccordionRenderSection(group: SidebarGroup(id: "recent", folderId: nil, ids: recentIDs,
                                                           label: "Recent", isCollapsed: false),
                                       members: recentIDs,
                                       geometry: AccordionSectionGeometry(id: "recent", folderID: nil, count: 3,
                                                                          rowHeight: Self.mailRowHeight,
                                                                          labelHeight: 32, headerHeight: 0, footerHeight: 0)),
                AccordionRenderSection(group: SidebarGroup(id: "A", folderId: "A", ids: aIDs, label: "A",
                                                           isCollapsed: !expandedA),
                                       members: aIDs, geometry: spec("A", count: 5)),
                AccordionRenderSection(group: SidebarGroup(id: "B", folderId: "B", ids: bIDs, label: "B",
                                                           isCollapsed: true),
                                       members: bIDs, geometry: spec("B", count: 2)),
            ]
        }
        controller.receive(fixture(expandedA: false), render: render, allowAnimation: false)
        controller.view.layoutIfNeeded(); pump(0.25)
        // Park the folder header near the top edge but fully visible.
        let headerY = controller.accordionLayout.headerY(section: 1)
        controller.collection.setContentOffset(CGPoint(x: 0, y: headerY - 120), animated: false)
        controller.collection.layoutIfNeeded(); pump(0.08)
        let headerScreenBefore = headerY - controller.collection.contentOffset.y
        print("STAGE: mail fold expand"); fflush(stdout)
        controller.receive(fixture(expandedA: true), render: render)
        var lastBottom: [CGFloat] = []
        var clippedSamples = 0
        for _ in 0..<8 {
            pump(0.03)
            let p = controller.accordionLayout.reveal[1]
            guard p > 0.001, p < 0.999 else { continue }
            let layout = controller.accordionLayout
            let blockTop = layout.starts[1] + layout.translation + layout.sections[1].labelHeight
                + layout.sections[1].headerHeight
            let blockBottom = blockTop + layout.sections[1].fullHeight * p
            if let cell = controller.collection.cellForItem(at: IndexPath(item: 6, section: 1)) {
                check(abs(cell.frame.maxY - blockBottom) < 1,
                      "live frame: last member cell rides the moving bottom edge (p=\(p))")
                lastBottom.append(cell.frame.maxY)
            }
            for cell in controller.collection.visibleCells {
                guard let path = controller.collection.indexPath(for: cell), path.section == 1,
                      path.item >= 2, let hosting = cell as? AccordionHostingCell,
                      hosting.clipTop > 0.5 else { continue }
                clippedSamples += 1
                let host = hosting.contentView.subviews.first
                check(abs((host?.frame.origin.y ?? 0) + hosting.clipTop) < 0.5,
                      "live frame: the clipped row's content keeps its full frame, translated by -clipTop")
                check(abs(cell.frame.height - (Self.mailRowHeight - hosting.clipTop)) < 1,
                      "live frame: clipped row shows exactly the uncovered slice")
                check(abs(cell.frame.minY - blockTop) < 1, "live frame: clipping happens at the header line")
            }
        }
        check(clippedSamples >= 2, "real 60 Hz frames produced header-clipped member rows, got \(clippedSamples)")
        check(lastBottom.count >= 2, "real frames sampled the moving bottom edge")
        check(zip(lastBottom, lastBottom.dropFirst()).allSatisfy { pair in pair.1 >= pair.0 - 1 },
              "expanding translates the child block DOWN, never up")
        controller.receive(fixture(expandedA: true), render: render)
        pump(0.6)
        check(controller.accordionLayout.reveal == [1, 1, 0], "expand lands on the full endpoint layout")
        for row in 0..<5 {
            let a = mailMember(controller.accordionLayout, 1, row)!
            check(a.clipTop == 0 && abs(a.frame.height - Self.mailRowHeight) < 0.001,
                  "committed row \(row) is unclipped at the endpoint")
        }
        check(abs(headerY - controller.collection.contentOffset.y - headerScreenBefore) < 1,
              "the tapped folder header did not move on screen across the fold")
        // --- pinned bucket: same motion, driven by its own store ------------
        UserDefaults.standard.set(false, forKey: PinnedSectionState.defaultsKey)
        let pinnedIDs = ["p0", "p1", "p2"]
        var pinnedFixture = fixture(expandedA: true)
        pinnedFixture[0] = AccordionRenderSection(
            group: SidebarGroup(id: "pinned", folderId: nil, ids: pinnedIDs, label: "Pinned", isCollapsed: false),
            members: pinnedIDs,
            geometry: AccordionSectionGeometry(id: "pinned", folderID: nil, count: 3,
                                               rowHeight: Self.mailRowHeight, labelHeight: 32,
                                               headerHeight: 0, footerHeight: 0))
        controller.receive(pinnedFixture, render: render, allowAnimation: false)
        controller.view.layoutIfNeeded(); pump(0.25)
        print("STAGE: mail fold pinned"); fflush(stdout)
        PinnedSectionState.shared.toggle()
        var pinnedClip = 0
        for _ in 0..<8 {
            pump(0.03)
            let p = controller.accordionLayout.reveal[0]
            guard p > 0.001, p < 0.999 else { continue }
            let blockTop = controller.accordionLayout.starts[0] + controller.accordionLayout.translation
                + controller.accordionLayout.sections[0].labelHeight
            for cell in controller.collection.visibleCells {
                guard let path = controller.collection.indexPath(for: cell), path.section == 0,
                      path.item >= 1, let hosting = cell as? AccordionHostingCell,
                      hosting.clipTop > 0.5 else { continue }
                pinnedClip += 1
                check(abs(cell.frame.minY - blockTop) < 1,
                      "pinned bucket clips its rows at its own label bottom")
            }
        }
        check(pinnedClip >= 1, "the date-bucket fold path animates the same clipped block")
        pump(0.5)
        check(controller.accordionLayout.reveal[0] == 0, "pinned bucket fold commits its endpoint")
        UserDefaults.standard.set(false, forKey: PinnedSectionState.defaultsKey)
        controller.stop()
    }
}
