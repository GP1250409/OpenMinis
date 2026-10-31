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
        // After the loop: the preview test replaces the window's root.
        for (style, lone) in lones { memberPreviewTest(style: style, loneCard: lone) }
        headerPreviewMaskTest()
    }

    /// Folder member long-press preview. Two things are asserted:
    ///
    /// 1. The platter's mask (FolderLiftPreviewShape) is exactly the lone card
    ///    FolderLiftedCard draws — 6pt sides, 4pt top/bottom, radius 16 — so
    ///    the lift keeps the accepted uniform 4pt gap and card colour.
    /// 2. The row keeps its welded segment UNDER that card while it is held
    ///    (production: ZStack of FolderMemberRowBackground + FolderLiftedCard).
    ///    The old pressed branch replaced the segment, leaving a hole in the
    ///    group around the platter; on cancel the returning platter crossed it
    ///    and read as a stray rounded card (video_B6D9D356.mp4, 3.4-4.0 s).
    func memberPreviewTest(style: UIUserInterfaceStyle, loneCard: [Int]) {
        let w: CGFloat = 398, h: CGFloat = 76
        let mask = FolderLiftPreviewShape()
        let path = mask.path(in: CGRect(x: 0, y: 0, width: w, height: h))
        let bounds = path.boundingRect
        print("MEMBER_PREVIEW_MASK \(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height)")
        check(abs(bounds.minX - 6) < 0.5 && abs(bounds.maxX - (w - 6)) < 0.5
              && abs(bounds.minY - 4) < 0.5 && abs(bounds.maxY - (h - 4)) < 0.5,
              "member preview mask is the lone card: 6pt sides, 4pt top/bottom")
        check(!path.contains(CGPoint(x: 6.5, y: 4.5)), "member preview mask rounds its corners")

        // What UIKit snapshots as the platter while the menu holds the row.
        let platter = render(Color.clear.frame(width: w, height: h).background {
            ZStack {
                FolderMemberRowBackground(isLast: false)
                FolderLiftedCard(bottomInset: 4)
            }
        }.clipShape(FolderLiftPreviewShape()), w: w, h: h, style: style)
        // The same row once the menu is gone.
        let settled = render(Color.clear.frame(width: w, height: h)
            .background(FolderMemberRowBackground(isLast: false)), w: w, h: h, style: style)

        // 1. Platter keeps the equal-gap card look.
        check([CGPoint(x: w/2, y: 2), CGPoint(x: w/2, y: h - 2)].allSatisfy { alpha(platter, $0) == 0 },
              "lifted member leaves a clear 4pt top and bottom gap")
        check([CGPoint(x: 2, y: h/2), CGPoint(x: w - 2, y: h/2)].allSatisfy { alpha(platter, $0) == 0 },
              "lifted member is inset 6pt from the row sides")
        check([CGPoint(x: w/2, y: 6), CGPoint(x: w/2, y: h - 6), CGPoint(x: 8, y: h/2), CGPoint(x: w - 8, y: h/2)]
              .allSatisfy { alpha(platter, $0) == 255 }, "lifted card surface starts at the inset")
        let card = rgb(platter, CGPoint(x: w - 30, y: h - 8))
        print("MEMBER_PREVIEW_COLOR style=\(style.rawValue) card=\(card) lone=\(loneCard)")
        check(zip(card, loneCard).allSatisfy { abs($0 - $1) <= 2 }, "lifted card uses the folder card colour, no pressed tint")

        // 2. The group is NOT carved: behind the card's 4pt bands the welded
        //    segment is still painted, so a cancelled menu lands on a
        //    continuous group instead of a hole with a card over it.
        let held = render(Color.clear.frame(width: w, height: h).background {
            ZStack {
                FolderMemberRowBackground(isLast: false)
                FolderLiftedCard(bottomInset: 4)
            }
        }, w: w, h: h, style: style)
        // Compared against the settled row rather than a fixed alpha: the
        // welded segment is a material on iOS 26, so its own alpha is not 255
        // over a clear backdrop — what matters is that the surface the platter
        // hides (its 4pt bands) is the SAME one the dismissal lands on.
        let gapPoints = [CGPoint(x: w/2, y: 2), CGPoint(x: w/2, y: h - 2), CGPoint(x: 8, y: 2)]
        check(gapPoints.allSatisfy { p in
                zip(rgb(held, p), rgb(settled, p)).allSatisfy { abs($0 - $1) <= 2 }
              },
              "held row keeps the group surface in the card's gaps")
        // (Colour parity with the SETTLED row is deliberately not sampled
        // here: on iOS 26 a member segment is a material, which renders empty
        // when drawn over a clear backdrop. The platter's solid card is the
        // documented parity constant — FolderSurface.sampledGlassColor — and
        // the appearance parity is covered by FOLDER_COLORS above.)
        let filename = style == .light ? "folder-preview-light.png" : "folder-preview-dark.png"
        try? platter.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
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

    /// Folder header: the platter must be the card on every side. The shape is
    /// now drawn in the CARD's coordinates (the 6pt/4pt outer padding sits
    /// outside the view that carries the menu), so the regression is a
    /// zero-margin assertion on all four sides plus the card's real corner
    /// treatment — rounded all round when collapsed/lone, square at the bottom
    /// for an expanded header whose card welds onto its first member row.
    ///
    /// Device photo photo_EEB36A68 (8c34dec) is the failure this replaces: the
    /// mask included the row's 6pt/4pt paddings, so the platter sampled them as
    /// a ~4pt light gutter along both sides and both top corners while the
    /// welded bottom stayed flush — three margins of 4pt against a fourth of 0.
    func headerPreviewMaskTest() {
        let expandedCard = CGRect(x: 0, y: 0, width: 378, height: 64) // 390-2*6, 68-4
        let expanded = FolderCardPreviewShape(expanded: true).path(in: expandedCard)
        let e = expanded.boundingRect
        print("HEADER_PREVIEW_SHAPE expanded=\(e.minX),\(e.minY),\(e.width),\(e.height)")
        let insets = [e.minX, e.minY, expandedCard.width - e.maxX, expandedCard.height - e.maxY]
        check(insets.allSatisfy { abs($0) < 0.5 },
              "expanded header preview has one equal margin (0pt) on all four sides")
        check(!expanded.contains(CGPoint(x: 0.5, y: 0.5)) && !expanded.contains(CGPoint(x: 377.5, y: 0.5)),
              "expanded header preview keeps the card's rounded top corners")
        check(expanded.contains(CGPoint(x: 0.5, y: 63.5)) && expanded.contains(CGPoint(x: 377.5, y: 63.5)),
              "expanded header preview keeps the welded square bottom corners")

        let collapsedCard = CGRect(x: 0, y: 0, width: 378, height: 60) // 68-2*4
        let collapsed = FolderCardPreviewShape(expanded: false).path(in: collapsedCard)
        let c = collapsed.boundingRect
        let cInsets = [c.minX, c.minY, collapsedCard.width - c.maxX, collapsedCard.height - c.maxY]
        check(cInsets.allSatisfy { abs($0) < 0.5 },
              "collapsed header preview is the lone card, equal margin on all four sides")
        check(!collapsed.contains(CGPoint(x: 0.5, y: 0.5)) && !collapsed.contains(CGPoint(x: 0.5, y: 59.5)),
              "collapsed header preview rounds all four corners")
    }
}
