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
        let settledCard = rgb(settled, CGPoint(x: w - 30, y: h - 8))
        print("MEMBER_PREVIEW_SETTLED style=\(style.rawValue) card=\(settledCard)")
        check(zip(settledCard, card).allSatisfy { abs($0 - $1) <= 3 },
              "dismissal lands on the same card colour the platter showed")
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

    /// Expanded folder header: its card welds onto the first member row, so the
    /// preview mask used to end flush with the row and the held header was cut
    /// flat at the bottom (photo_968D96E1 / photo_447E005A). The mask now stops
    /// 4pt short and rounds there; the collapsed mask is unchanged.
    func headerPreviewMaskTest() {
        let rect = CGRect(x: 0, y: 0, width: 390, height: 68)
        let expanded = FolderCardPreviewShape(expanded: true).path(in: rect)
        let e = expanded.boundingRect
        print("HEADER_PREVIEW_MASK expanded=\(e.minX),\(e.minY),\(e.width),\(e.height)")
        check(abs(e.minX - 2) < 0.5 && abs(e.maxX - 388) < 0.5 && abs(e.minY) < 0.5 && abs(e.maxY - 64) < 0.5,
              "expanded header preview keeps a 4pt gap under the welded card")
        check(!expanded.contains(CGPoint(x: 2.6, y: 63.4)) && !expanded.contains(CGPoint(x: 387.4, y: 63.4)),
              "expanded header preview rounds both bottom corners")
        check(expanded.contains(CGPoint(x: 195, y: 63.4)),
              "expanded header preview keeps a continuous bottom edge")
        let collapsed = FolderCardPreviewShape(expanded: false).path(in: rect).boundingRect
        check(abs(collapsed.minY) < 0.5 && abs(collapsed.maxY - 68) < 0.5,
              "collapsed header preview keeps its 4pt gap inside the row")
    }
}
