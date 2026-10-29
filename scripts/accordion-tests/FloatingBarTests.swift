import SwiftUI
import UIKit

final class FloatingBarGeometryBox {
    weak var marker: UIView?
}
struct FloatingBarGeometryMarker: UIViewRepresentable {
    let box: FloatingBarGeometryBox
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.isUserInteractionEnabled = false; box.marker = v; return v
    }
    func updateUIView(_ view: UIView, context: Context) { box.marker = view }
}

extension AccordionTestApp {
    func findNative(_ parent: UIViewController) -> NativeAccordionController? {
        if let native = parent as? NativeAccordionController { return native }
        for child in parent.children { if let found = findNative(child) { return found } }
        return nil
    }
    func floatingBarTest() {
        let box = FloatingBarGeometryBox()
        let items = sections(3, count: 100)
        let renderer: NativeAccordionController.Renderer = { group, _, role in
            AnyView(Text(group.label).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.green))
        }
        let surface = FloatingSidebarSurface {
            NativeAccordionList(sections: items, viewport: AccordionViewportState(), bottomInset: 76,
                toggle: { _ in }, render: renderer)
        } controls: {
            HStack {
                Circle().fill(Color.orange).frame(width: 56, height: 56)
                Spacer()
                Circle().fill(Color.gray).frame(width: 56, height: 56)
            }
            .padding(10)
            .background(FloatingBarGeometryMarker(box: box))
        }
        let host = UIHostingController(rootView: surface)
        window!.rootViewController = host
        host.view.layoutIfNeeded(); pump(0.4)
        guard let native = findNative(host), let marker = box.marker else {
            check(false, "full SwiftUI wrapper hosts real native controller and controls"); return
        }
        let cv = native.collection
        for style in [UIUserInterfaceStyle.light, .dark] {
            host.overrideUserInterfaceStyle = style
            cv.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            host.view.layoutIfNeeded(); cv.layoutIfNeeded(); pump(0.2)
            let bar = marker.convert(marker.bounds, to: host.view)
            let viewport = cv.convert(cv.bounds, to: host.view)
            print("FAB_GEOMETRY style=\(style.rawValue) bar=\(bar) viewport=\(viewport) inset=\(cv.contentInset)")
            check(bar.height > 70 && bar.height < 80, "floating controls retain their 76pt layout")
            check(viewport.maxY >= bar.maxY - 1, "native viewport extends behind full floating control area")
            let screenPoint = CGPoint(x: bar.midX, y: bar.midY)
            let contentPoint = host.view.convert(screenPoint, to: cv)
            guard let path = cv.indexPathForItem(at: contentPoint), let cell = cv.cellForItem(at: path) else {
                check(false, "real visible session cell exists behind transparent center of FAB row"); return
            }
            check(!cell.isHidden && cell.alpha > 0.99, "session cell behind controls is actually visible")
            // Capture actual composited output, not just layout attributes.
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let filename = style == .light ? "fab-light.png" : "fab-dark.png"
            try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename))
            if let cg = image.cgImage {
                let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
                pixel.initialize(repeating: 0, count: 4)
                let ctx = CGContext(data: pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let scale = image.scale
                let x = min(cg.width - 1, max(0, Int(screenPoint.x * scale)))
                let y = min(cg.height - 1, max(0, Int(screenPoint.y * scale)))
                if let cropped = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) {
                    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    print("FAB_PIXEL \(pixel[0]),\(pixel[1]),\(pixel[2]),\(pixel[3])")
                    check(Int(pixel[1]) > Int(pixel[0]) + 25 && Int(pixel[1]) > Int(pixel[2]) + 25,
                          "composited FAB center shows green session content, not opaque panel")
                }
                pixel.deinitialize(count: 4); pixel.deallocate()
            }
            let maxY = AccordionMotion.clampedOffset(.greatestFiniteMagnitude,
                contentHeight: native.accordionLayout.naturalHeight, viewportHeight: cv.bounds.height,
                inset: cv.adjustedContentInset)
            cv.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            cv.layoutIfNeeded(); pump(0.1)
            let last = IndexPath(item: items.last!.geometry.itemCount - 1, section: items.count - 1)
            let attr = native.accordionLayout.layoutAttributesForItem(at: last)!
            let lastRect = cv.convert(attr.frame, to: host.view)
            check(lastRect.maxY <= bar.minY + 1, "last row can scroll completely above floating controls")
        }
        native.stop()
    }
}
