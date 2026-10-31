import SwiftUI
import UIKit

// PROBE: how does SwiftUI build the long-press preview for a nested
// `.contentShape(.contextMenuPreview, …)`? Drives the real
// UIContextMenuInteraction delegate SwiftUI installs and inspects the
// UITargetedPreview it returns. Diagnostics only; never fails the run.

struct ProbeForcedPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay(Color.red.opacity(0.5).allowsHitTesting(false))
    }
}

struct ProbeGapShape: Shape {
    let inset: CGFloat
    let gap: CGFloat
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 16 + gap, style: .continuous)
            .path(in: rect.insetBy(dx: inset - gap, dy: -gap))
    }
}

struct ProbeRow: View {
    let nested: Bool
    var body: some View {
        Button {} label: {
            Group {
                if nested {
                    Text("Probe row content").frame(maxWidth: .infinity).frame(height: 68)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.green).padding(.horizontal, 6.75))
                        .contentShape(.contextMenuPreview, ProbeGapShape(inset: 6.75, gap: 4))
                } else {
                    Text("Probe row content").frame(maxWidth: .infinity).frame(height: 68)
                }
            }
        }
        .buttonStyle(ProbeForcedPress())
        .background(Color.blue)
        .modifier(ProbeOuterShape(apply: !nested))
        .contextMenu { Button("A") {} }
    }
}
struct ProbeOuterShape: ViewModifier {
    let apply: Bool
    func body(content: Content) -> some View {
        if apply { content.contentShape(.contextMenuPreview, ProbeGapShape(inset: 6, gap: 4)) } else { content }
    }
}

extension AccordionTestApp {
    func probeInteractions(_ v: UIView) -> [UIContextMenuInteraction] {
        v.interactions.compactMap { $0 as? UIContextMenuInteraction } + v.subviews.flatMap { probeInteractions($0) }
    }
    func probePixel(_ image: UIImage, _ p: CGPoint) -> [Int] {
        guard let cg = image.cgImage,
              let crop = cg.cropping(to: CGRect(x: Int(p.x * image.scale), y: Int(p.y * image.scale), width: 1, height: 1)) else { return [-1] }
        var b: [UInt8] = [0,0,0,0]
        b.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return b.map(Int.init)
    }
    func contextMenuProbe() {
        print("PROBE os=\(UIDevice.current.systemVersion)")
        for nested in [false, true] {
            let host = UIHostingController(rootView: ProbeRow(nested: nested).frame(width: 390, height: 68))
            let root = UIViewController(); root.view.backgroundColor = .white
            window!.rootViewController = root
            root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
            host.view.frame = CGRect(x: 0, y: 200, width: 390, height: 68)
            host.view.backgroundColor = .clear
            host.view.layoutIfNeeded(); pump(0.3)
            let all = probeInteractions(host.view)
            print("PROBE nested=\(nested) interactions=\(all.count) views=\(all.map { String(describing: type(of: $0.view!)) })")
            guard let ia = all.first, let d = ia.delegate, let iv = ia.view else { continue }
            let pt = iv.convert(CGPoint(x: 195, y: 234), from: root.view)
            guard let cfg = d.contextMenuInteraction(ia, configurationForMenuAtLocation: pt) else {
                print("PROBE nested=\(nested) no configuration"); continue
            }
            var preview: UITargetedPreview?
            if #available(iOS 16.0, *) {
                preview = d.contextMenuInteraction?(ia, configuration: cfg, highlightPreviewForItemWithIdentifier: cfg.identifier)
            }
            if preview == nil { preview = d.contextMenuInteraction?(ia, previewForHighlightingMenuWithConfiguration: cfg) }
            guard let p = preview else { print("PROBE nested=\(nested) no preview"); continue }
            let pv = p.view
            let path = p.parameters.visiblePath?.bounds ?? .null
            var bg: CGFloat = -1
            p.parameters.backgroundColor?.getWhite(nil, alpha: &bg)
            print("PROBE nested=\(nested) view=\(type(of: pv)) frame=\(pv.frame) inWindow=\(pv.window != nil) sameAsIV=\(pv === iv) path=\(path) bgAlpha=\(bg) target=\(type(of: p.target.container)) center=\(p.target.center)")
            let fmt = UIGraphicsImageRendererFormat(); fmt.opaque = false
            let img = UIGraphicsImageRenderer(bounds: pv.bounds, format: fmt).image { c in
                if pv.window != nil { pv.drawHierarchy(in: pv.bounds, afterScreenUpdates: true) }
                else { pv.layer.render(in: c.cgContext) }
            }
            let mid = CGPoint(x: pv.bounds.midX, y: pv.bounds.midY)
            let samples = [("center", mid), ("x10", CGPoint(x: 10, y: pv.bounds.midY)),
                           ("x3", CGPoint(x: 3, y: pv.bounds.midY)), ("y2", CGPoint(x: pv.bounds.midX, y: 2)),
                           ("y-bottom2", CGPoint(x: pv.bounds.midX, y: pv.bounds.maxY - 2))]
            for (n, s) in samples where pv.bounds.contains(s) { print("PROBE nested=\(nested) px \(n)=\(probePixel(img, s))") }
            try? img.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-probe-\(nested ? "nested" : "outer").png"))
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }
}
