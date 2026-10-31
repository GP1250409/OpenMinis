import SwiftUI
import UIKit

struct FolderAppearanceFixture: View {
    let box: FloatingBarGeometryBox
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 68)
                .modifier(FolderCardBackground(isDropTarget: false, isExpanded: false))
                .padding(.horizontal, 6)
            Color.clear.frame(height: 24)
            Color.clear.frame(height: 68)
                .modifier(FolderCardBackground(isDropTarget: false, isExpanded: true))
                .padding(.horizontal, 6)
            Color.clear.frame(height: 68)
                .background(FolderMemberRowBackground(isLast: false))
            Color.clear.frame(height: 68)
                .background(FolderMemberRowBackground(isLast: true))
        }
        .frame(width: 320)
        .background(FloatingBarGeometryMarker(box: box))
    }
}

extension AccordionTestApp {
    func rgb(_ image: UIImage, _ point: CGPoint) -> [Int] {
        guard let cg = image.cgImage,
              let crop = cg.cropping(to: CGRect(x: Int(point.x * image.scale), y: Int(point.y * image.scale), width: 1, height: 1)) else { return [0,0,0] }
        var bytes: [UInt8] = [0,0,0,0]
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
    func folderAppearanceTest() {
        let box = FloatingBarGeometryBox()
        let host = UIHostingController(rootView: FolderAppearanceFixture(box: box))
        window!.rootViewController = host
        var lones: [(UIUserInterfaceStyle, [Int])] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            host.overrideUserInterfaceStyle = style
            host.view.backgroundColor = .systemBackground
            host.view.layoutIfNeeded(); pump(0.3)
            guard let marker = box.marker else { check(false, "folder fixture mounted"); return }
            let rect = marker.convert(marker.bounds, to: host.view)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let title = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 126))
            let member = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 194))
            print("FOLDER_COLORS style=\(style.rawValue) title=\(title) member=\(member)")
            check(zip(title, member).allSatisfy { abs($0 - $1) <= 2 }, "expanded menu shares member background without extra tint")
            let divider = rgb(image, CGPoint(x: rect.midX, y: rect.minY + 160 - 0.25))
            check(zip(divider, title).contains { abs($0 - $1) >= 3 }, "only header-to-member boundary has a visible fine rule")
            let scale = image.scale
            func edgeStrength(_ y: CGFloat) -> Int {
                let base = rgb(image, CGPoint(x: rect.midX, y: rect.minY + y))
                return (-2...8).reduce(0) { sum, step in
                    let color = rgb(image, CGPoint(x: rect.minX + 6 + CGFloat(step)/scale, y: rect.minY + y))
                    return sum + zip(color, base).reduce(0) { $0 + abs($1.0 - $1.1) }
                }
            }
            let collapsed = edgeStrength(34), expanded = edgeStrength(194)
            print("FOLDER_EDGE style=\(style.rawValue) collapsed=\(collapsed) expanded=\(expanded)")
            // Upstream uses the same 0.75pt highlight on expanded segments;
            // a stronger-than-collapsed edge is no longer the requested style.
            check(expanded > 0, "upstream-style expanded outer edge remains visible")
            let filename = style == .light ? "folder-light.png" : "folder-dark.png"
            try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
            lones.append((style, rgb(image, CGPoint(x: rect.midX, y: rect.minY + 34))))
        }
        // After the loop: the preview tests replace the window's root.
        for (style, lone) in lones { memberPreviewTest(style: style, loneCard: lone) }
        headerPreviewMaskTest()
        menuPlatterTest()
    }

    // MARK: - Rendered geometry

    /// The platter mask is the RESTING card plus its 4pt band on all four sides:
    /// row inset by (6-4)=2 horizontally and (4-4)=0 vertically, radius 20,
    /// concentric with the card's own 16pt corners. No expanded/collapsed
    /// variant — the bottom band comes from the card being painted 4pt short
    /// while held, never from cropping the snapshot (the old flat, cut-off
    /// bottom edge on an expanded group header).
    func platterMaskTest() {
        let row = CGRect(x: 0, y: 0, width: 390, height: 68)
        let path = FolderPlatterShape().path(in: row)
        let bounds = path.boundingRect
        print("PLATTER_MASK \(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height)")
        check(abs(bounds.minX - 2) < 0.5 && abs(bounds.maxX - 388) < 0.5
              && abs(bounds.minY) < 0.5 && abs(bounds.maxY - 68) < 0.5,
              "platter mask is the card plus a 4pt band on every side")
        check(!path.contains(CGPoint(x: 3, y: 1)) && !path.contains(CGPoint(x: 387, y: 67)),
              "platter mask corners are rounded at 20, concentric with the card")
        check(FolderCardLift.platterRadius == FolderCardLift.cornerRadius + FolderCardLift.gap,
              "platter radius stays concentric with the card radius")
        check(path.contains(CGPoint(x: 195, y: 1)) && path.contains(CGPoint(x: 195, y: 67)),
              "platter mask keeps a continuous band edge at mid-width")
    }

    /// Member row: the platter's snapshot is the lone card inset 6pt from the
    /// sides and 4pt from the top and bottom, on the card's own colour, and the
    /// row is a welded segment again the moment the lift ends.
    func memberPreviewTest(style: UIUserInterfaceStyle, loneCard: [Int]) {
        platterMaskTest()
        let w: CGFloat = 390, h: CGFloat = 68
        let lifted = render(Color.clear.frame(width: w, height: h)
            .background(FolderMemberRowBackground(isLast: false, lifted: true))
            .clipShape(FolderPlatterShape()), w: w, h: h, style: style)
        let settled = render(Color.clear.frame(width: w, height: h)
            .background(FolderMemberRowBackground(isLast: false)), w: w, h: h, style: style)

        check([CGPoint(x: w/2, y: 2), CGPoint(x: w/2, y: h - 2),
               CGPoint(x: 4, y: h/2), CGPoint(x: w - 4, y: h/2)].allSatisfy { alpha(lifted, $0) == 0 },
              "held member card keeps a clear 4pt band on all four sides")
        check([CGPoint(x: w/2, y: 6), CGPoint(x: w/2, y: h - 6),
               CGPoint(x: 8, y: h/2), CGPoint(x: w - 8, y: h/2)].allSatisfy { alpha(lifted, $0) == 255 },
              "held member card starts exactly at the 6pt/4pt insets")
        let card = rgb(lifted, CGPoint(x: w - 30, y: h - 8))
        print("MEMBER_PREVIEW_COLOR style=\(style.rawValue) card=\(card) lone=\(loneCard)")
        check(zip(card, loneCard).allSatisfy { abs($0 - $1) <= 2 }, "held member card uses the folder card colour, no pressed tint")

        // The residue guard: once the lift ends the row is the welded segment
        // again — painted through the 4pt bands, with no lone-card edge left.
        check([CGPoint(x: w/2, y: 2), CGPoint(x: w/2, y: h - 2)].allSatisfy { alpha(settled, $0) == 255 },
              "settled member row paints the welded segment through the 4pt bands")
        check(zip(rgb(settled, CGPoint(x: w/2, y: 2)), rgb(settled, CGPoint(x: w/2, y: h/2)))
                .allSatisfy { abs($0 - $1) <= 2 },
              "settled member row has no card edge at its top")
        let filename = style == .light ? "folder-preview-light.png" : "folder-preview-dark.png"
        try? lifted.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
    }

    /// Expanded group header: its card is welded to the first member row at
    /// rest, so the held card has to be painted 4pt short at the bottom with
    /// all four corners at 16 — otherwise the platter has no bottom band (or a
    /// flat, cut-off edge, which is what the user rejected).
    func headerPreviewMaskTest() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let row = render(FolderCardPaint(isDropTarget: false, isExpanded: true, lifted: true) {
                Color.clear.frame(height: 64)
            }
                .padding(.horizontal, 6)
                .padding(.top, 4), w: 390, h: 68, style: style)
            check(alpha(row, CGPoint(x: 195, y: 66)) == 0,
                  "expanded header card leaves its 4pt bottom gap while held")
            check(alpha(row, CGPoint(x: 195, y: 60)) == 255,
                  "expanded header card still reaches the bottom band's top edge")
            check(alpha(row, CGPoint(x: 195, y: 2)) == 0,
                  "expanded header card keeps its 4pt top band empty")
            check(alpha(row, CGPoint(x: 6, y: 66)) == 0 && alpha(row, CGPoint(x: 383, y: 66)) == 0,
                  "expanded header card's own bottom corners are rounded, not cut")
            check(rgb(row, CGPoint(x: 195, y: 6)) == rgb(row, CGPoint(x: 195, y: 60)),
                  "expanded header card is one flat surface end to end")
        }
    }

    // MARK: - Real context menu: present → open → dismiss frames → after

    /// What the user actually sees, on the real production views, with a REAL
    /// `UIContextMenuInteraction` presented and dismissed. Three things are
    /// checked per target:
    ///
    /// 1. OPEN: the platter has the same 4pt band on all four sides — including
    ///    the BOTTOM, which the expanded group header used to lose — and the
    ///    card keeps the folder surface colour (no pressed dimming).
    /// 2. HELD: the row behind the platter is already the welded segment again
    ///    (that is what makes the dismissal land on a continuous group).
    /// 3. AFTER + the late dismissal frames: no lone-card edge is left in the
    ///    row (the residue the user still saw with 8c34dec).
    enum MenuTarget: String { case header, member }

    func menuPlatterTest() {
        for target in [MenuTarget.header, .member] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                menuPlatterCase(target, style: style)
            }
        }
    }

    func menuPlatterCase(_ target: MenuTarget, style: UIUserInterfaceStyle) {
        var group = SidebarGroup(id: "g", folderId: "g", ids: ["a", "b"], label: "商务邮件", isCollapsed: false)
        group.totalCount = 5
        var first = ChatSession()
        first.id = "a"
        first.title = "24V 电源适配器报价邮件"
        first.lastMessage = "5 个会话 · 24V 电源适配器报价邮件"
        var second = first
        second.id = "b"
        second.title = "Ivan 电源适配器询价邮件"

        let root = UIViewController()
        window!.rootViewController = root
        root.overrideUserInterfaceStyle = style
        root.view.backgroundColor = .systemBackground
        root.view.layoutIfNeeded(); pump(0.2)

        // The three rows of one expanded group, welded in a real column: card
        // paint, masks and menus are the production views.
        let hosts: [(AnyView, CGRect)] = [
            (AnyView(ProductionFolderHeaderFixture(group: group)),
             CGRect(x: 0, y: 200, width: 390, height: 68)),
            (AnyView(SessionStackRow(session: first, isActive: false, isSuspended: false,
                highlightQuery: nil, matchSnippet: nil, isRegeneratingTitle: false,
                inFolder: true, isLastInFolder: false, menuActions: SessionMenuActionChannel())),
             CGRect(x: 0, y: 268, width: 390, height: 68)),
            (AnyView(SessionStackRow(session: second, isActive: false, isSuspended: false,
                highlightQuery: nil, matchSnippet: nil, isRegeneratingTitle: false,
                inFolder: true, isLastInFolder: true, menuActions: SessionMenuActionChannel())),
             CGRect(x: 0, y: 372, width: 390, height: 68))
        ]
        var rowHosts: [UIView] = []
        for (view, frame) in hosts {
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = style
            host.view.backgroundColor = .clear
            root.addChild(host)
            host.view.frame = frame
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            host.view.layoutIfNeeded()
            rowHosts.append(host.view)
        }
        pump(0.5)

        let index = target == .header ? 0 : 1
        let row = rowHosts[index]
        let rowRect = row.frame
        guard let interaction = contextMenuInteraction(in: row),
              let state = liftState(in: row) else {
            check(false, "\(target.rawValue): row exposes its menu and lift state"); return
        }
        let tag = "\(target.rawValue)-\(style == .light ? "light" : "dark")"
        print("PLATTER_CASE \(tag) row=\(rowRect)")

        // Tap safety: a quick touch must not lift the row.
        state.touchDown(); pump(0.08); check(!state.lifted, "\(tag): a tap does not lift the row")
        state.touchEnded(); pump(0.15)

        // Baseline: the settled list, before any menu exists.
        let baseline = screenshot(root.view)
        try? baseline.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("platter-\(tag)-baseline.png"))

        // Hold: the row arms its lifted paint exactly as a finger would.
        state.touchDown(); pump(0.35)
        check(state.lifted, "\(tag): a hold arms the lifted card")

        present(interaction, at: CGPoint(x: rowRect.midX, y: rowRect.midY), in: root.view)
        pump(1.2)
        let open = screenshot(root.view)
        try? open.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("platter-\(tag)-open.png"))
        check(!state.lifted, "\(tag): the row drops the lifted paint once the platter exists")

        // 1. 4pt band on all four sides, card colour untouched.
        let top = rgb(open, CGPoint(x: rowRect.midX, y: rowRect.minY + 1.5))
        let bottom = rgb(open, CGPoint(x: rowRect.midX, y: rowRect.maxY - 1.5))
        let left = rgb(open, CGPoint(x: rowRect.minX + 3.5, y: rowRect.midY))
        let right = rgb(open, CGPoint(x: rowRect.maxX - 3.5, y: rowRect.midY))
        let cardTop = rgb(open, CGPoint(x: rowRect.midX, y: rowRect.minY + 6))
        let cardBottom = rgb(open, CGPoint(x: rowRect.midX, y: rowRect.maxY - 6))
        let cardMiddle = rgb(open, CGPoint(x: rowRect.midX, y: rowRect.midY))
        print("PLATTER_BANDS \(tag) top=\(top) bottom=\(bottom) left=\(left) right=\(right) card=\(cardTop)/\(cardMiddle)/\(cardBottom)")
        check(!sameColor(top, cardTop), "\(tag): the platter keeps a 4pt band above the card")
        check(!sameColor(bottom, cardBottom), "\(tag): the platter keeps a 4pt band BELOW the card")
        check(!sameColor(left, cardMiddle) && !sameColor(right, cardMiddle),
              "\(tag): the platter keeps a 4pt band left and right of the card")
        check(sameColor(cardTop, cardMiddle) && sameColor(cardBottom, cardMiddle),
              "\(tag): the held card is one surface, not dimmed")

        // 2/3. Dismiss: frame by frame, then the settled list again.
        interaction.dismissMenu()
        var elapsed = 0.0
        for (i, step) in [0.03, 0.06, 0.12, 0.2, 0.35, 0.6, 1.0].enumerated() {
            pump(step - elapsed); elapsed = step
            let frame = screenshot(root.view)
            try? frame.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("platter-\(tag)-d\(i).png"))
            if step >= 0.35 {
                let topBand = rgb(frame, CGPoint(x: rowRect.midX, y: rowRect.minY + 2))
                let bottomBand = rgb(frame, CGPoint(x: rowRect.midX, y: rowRect.maxY - 2))
                let middle = rgb(frame, CGPoint(x: rowRect.midX, y: rowRect.midY))
                check(sameColor(topBand, middle) && sameColor(bottomBand, middle),
                      "\(tag): dismissal frame \(i) has no lone-card edge left in the row")
            }
        }
        state.touchEnded()
        pump(0.5)
        let after = screenshot(root.view)
        try? after.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("platter-\(tag)-after.png"))
        let delta = diff(after, baseline, in: rowRect)
        print("PLATTER_AFTER \(tag) changedPixels=\(delta.0) maxChannelDelta=\(delta.1)")
        check(delta.0 == 0, "\(tag): the settled row is pixel-identical to before the menu (no residue)")
    }

    func contextMenuInteraction(in view: UIView) -> UIContextMenuInteraction? {
        if let own = view.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first { return own }
        for sub in view.subviews {
            if let found = contextMenuInteraction(in: sub) { return found }
        }
        return nil
    }

    func liftState(in view: UIView) -> FolderLiftState? {
        if let touch = view as? FolderLiftTouchObserver.TouchView, let state = touch.state { return state }
        for sub in view.subviews {
            if let found = liftState(in: sub) { return found }
        }
        return nil
    }

    func present(_ interaction: UIContextMenuInteraction, at point: CGPoint, in root: UIView) {
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let target = interaction.view, interaction.responds(to: selector) else {
            check(false, "context menu can be presented programmatically"); return
        }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(interaction.method(for: selector), to: Present.self)(
            interaction, selector, target.convert(point, from: root))
    }

    /// Every visible window of the scene, lowest level first — the context
    /// menu's platter lives above the app window, so a single-view snapshot
    /// would miss the very thing this test is about.
    func screenshot(_ view: UIView) -> UIImage {
        let windows = (view.window?.windowScene?.windows ?? [view.window].compactMap { $0 })
            .filter { !$0.isHidden }
            .sorted { $0.windowLevel < $1.windowLevel }
        return UIGraphicsImageRenderer(bounds: UIScreen.main.bounds).image { _ in
            for window in windows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
            }
        }
    }

    func sameColor(_ a: [Int], _ b: [Int]) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= 2 }
    }

    func diff(_ a: UIImage, _ b: UIImage, in rect: CGRect) -> (Int, Int) {
        let scale = a.scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale)
        guard let ca = a.cgImage, let cb = b.cgImage,
              let cropA = ca.cropping(to: pixels), let cropB = cb.cropping(to: pixels) else { return (-1, -1) }
        var changed = 0, maxDelta = 0
        let w = Int(pixels.width), h = Int(pixels.height)
        var pa = [UInt8](repeating: 0, count: w * h * 4), pb = pa
        func draw(_ cg: CGImage, _ p: inout [UInt8]) {
            p.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        draw(cropA, &pa); draw(cropB, &pb)
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = max(abs(Int(pa[i]) - Int(pb[i])), max(abs(Int(pa[i+1]) - Int(pb[i+1])),
                                                           abs(Int(pa[i+2]) - Int(pb[i+2]))))
            if d > 2 { changed += 1; maxDelta = max(maxDelta, d) }
        }
        return (changed, maxDelta)
    }

    func render<V: View>(_ view: V, w: CGFloat, h: CGFloat, style: UIUserInterfaceStyle) -> UIImage {
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        host.view.backgroundColor = .clear
        let root = UIViewController(); root.view.backgroundColor = .clear
        window!.rootViewController = root
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(origin: CGPoint(x: 0, y: 100), size: CGSize(width: w, height: h))
        host.view.layoutIfNeeded(); pump(0.3)
        return snapshot(host.view)
    }

    func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    func alpha(_ image: UIImage, _ point: CGPoint) -> Int {
        guard let cg = image.cgImage,
              let crop = cg.cropping(to: CGRect(x: Int(point.x * image.scale), y: Int(point.y * image.scale), width: 1, height: 1)) else { return -1 }
        var bytes: [UInt8] = [0,0,0,0]
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(bytes[3])
    }
}
