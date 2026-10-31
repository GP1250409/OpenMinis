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
    }

    /// Folder member long-press preview: the row is snapshotted as it is held,
    /// so its pressed appearance IS the preview. That pressed appearance is
    /// FolderLiftedCard — the lone folder card surface inset 6pt at the sides
    /// and 4pt top/bottom of the 68pt row (FolderLiftPreviewShape outlines it
    /// 2pt from each side, concentric corners 16+4). Assert the lifted card's
    /// surface and that the preview outline stays concentric with it.
    func memberPreviewTest(style: UIUserInterfaceStyle, loneCard: [Int]) {
        // The lifted card, at the fixed row size the native accordion gives it.
        let host = UIHostingController(rootView: FolderLiftedCard(bottomInset: 4).frame(width: 398, height: 76))
        host.overrideUserInterfaceStyle = style
        host.view.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window!.rootViewController = root
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.frame = CGRect(origin: CGPoint(x: 0, y: 100), size: CGSize(width: 398, height: 76))
        host.view.layoutIfNeeded(); pump(0.3)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        func alpha(_ p: CGPoint) -> Int {
            guard let cg = image.cgImage,
                  let crop = cg.cropping(to: CGRect(x: Int(p.x * image.scale), y: Int(p.y * image.scale), width: 1, height: 1)) else { return -1 }
            var bytes: [UInt8] = [0,0,0,0]
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Int(bytes[3])
        }
        let w: CGFloat = 398, h: CGFloat = 76
        print("MEMBER_PREVIEW style=\(style.rawValue) size=\(w)x\(h) screen=\(UIScreen.main.bounds.width)")
        // Clear 4pt top/bottom gap (inside the 68pt row) and clear 6pt side gap.
        check([CGPoint(x: w/2, y: 2), CGPoint(x: w/2, y: h - 2)].allSatisfy { alpha($0) == 0 },
              "lifted card leaves a clear 4pt top and bottom gap")
        check([CGPoint(x: 2, y: h/2), CGPoint(x: w - 2, y: h/2)].allSatisfy { alpha($0) == 0 },
              "lifted card is inset 6pt from the row sides")
        // Card body just inside the card edge (8pt from row sides, 6pt from
        // row top/bottom).
        check([CGPoint(x: w/2, y: 6), CGPoint(x: w/2, y: h - 6), CGPoint(x: 8, y: h/2), CGPoint(x: w - 8, y: h/2)]
              .allSatisfy { alpha($0) == 255 }, "lifted card surface starts at the inset")
        let card = rgb(image, CGPoint(x: w - 30, y: h - 8))
        print("MEMBER_PREVIEW_COLOR style=\(style.rawValue) card=\(card) lone=\(loneCard)")
        check(zip(card, loneCard).allSatisfy { abs($0 - $1) <= 2 }, "lifted card uses the folder card colour, no pressed tint")
        // Preview outline concentric: a rounded rect radius 20 inset 2pt.
        let outline = FolderLiftPreviewShape().path(in: CGRect(x: 0, y: 0, width: 398, height: 76)).boundingRect
        print("MEMBER_PREVIEW_OUTLINE \(outline.origin.x),\(outline.origin.y),\(outline.width),\(outline.height)")
        check(abs(outline.minX - 2) < 0.5 && abs(outline.maxX - 396) < 0.5
              && abs(outline.minY - 0) < 0.5 && abs(outline.maxY - 76) < 0.5,
              "preview outline is 2pt from each side, flush top/bottom, concentric with the card")
        let filename = style == .light ? "folder-preview-light.png" : "folder-preview-dark.png"
        try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
    }
}
