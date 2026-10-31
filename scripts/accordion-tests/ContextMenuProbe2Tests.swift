import SwiftUI
import UIKit

// PROBE 2: present the REAL context menu (UIKit private test entry
// `_presentMenuAtLocation:`) for three preview strategies and capture the
// composited screen, the preview platter's view tree and the dismissal frames.
// Diagnostics only; never fails the run.

struct ProbeSegmentRow: View {
    let mode: Int   // 0 snapshot+expanded path, 1 custom preview, 2 custom preview + clear host
    var body: some View {
        let row = Button {} label: {
            HStack {
                Circle().fill(Color.blue.opacity(0.4)).frame(width: 44, height: 44)
                VStack(alignment: .leading) { Text("Ivan 电源适配器询价邮件").bold(); Text("记住了。以后英文邮件").foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 68)
            .background(Rectangle().fill(Color(UIColor.secondarySystemBackground)).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        return Group {
            switch mode {
            case 0:
                row.contentShape(.contextMenuPreview, ProbeGapShape(inset: 6, gap: 4))
                    .contextMenu { Button("取消固定") {}; Button("导出") {} }
            default:
                row.contentShape(.contextMenuPreview, Rectangle().inset(by: 0))
                    .contextMenu { Button("取消固定") {}; Button("导出") {} } preview: {
                        HStack {
                            Circle().fill(Color.blue.opacity(0.4)).frame(width: 44, height: 44)
                            VStack(alignment: .leading) { Text("Ivan 电源适配器询价邮件").bold(); Text("记住了。以后英文邮件").foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .padding(.horizontal, 16).frame(width: 378, height: 68)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(UIColor.secondarySystemBackground)))
                        .padding(4)
                        .background(ProbeClearHost(enabled: mode == 2))
                    }
            }
        }
    }
}

struct ProbeClearHost: UIViewRepresentable {
    let enabled: Bool
    func makeUIView(context: Context) -> ProbeClearHostView { let v = ProbeClearHostView(); v.enabled = enabled; return v }
    func updateUIView(_ v: ProbeClearHostView, context: Context) { v.enabled = enabled }
}
final class ProbeClearHostView: UIView {
    var enabled = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var v: UIView? = superview; var depth = 0
        while let cur = v, depth < 12 {
            var a: CGFloat = -1; cur.backgroundColor?.getWhite(nil, alpha: &a)
            print("PROBE2 ancestor[\(depth)] \(type(of: cur)) bgAlpha=\(a) frame=\(cur.frame) clips=\(cur.clipsToBounds) radius=\(cur.layer.cornerRadius)")
            if enabled, depth < 4 { cur.backgroundColor = .clear }
            v = cur.superview; depth += 1
        }
    }
}

extension AccordionTestApp {
    func screenImage() -> UIImage {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
        let b = UIScreen.main.bounds
        return UIGraphicsImageRenderer(bounds: b).image { _ in
            for w in windows { w.drawHierarchy(in: w.frame, afterScreenUpdates: true) }
        }
    }
    func dumpTree(_ v: UIView, _ d: Int = 0, _ out: inout [String]) {
        guard d < 14, out.count < 120 else { return }
        var a: CGFloat = -1; v.backgroundColor?.getWhite(nil, alpha: &a)
        let name = String(describing: type(of: v))
        if name.contains("ContextMenu") || name.contains("Platter") || name.contains("Preview") || name.contains("Hosting") || d < 3 {
            out.append(String(repeating: " ", count: d) + "\(name) f=\(v.frame.integral) bg=\(a) r=\(v.layer.cornerRadius) clip=\(v.clipsToBounds)")
        }
        for s in v.subviews { dumpTree(s, d + 1, &out) }
    }
    func contextMenuProbe2() {
        let runtimes = (try? String(contentsOfFile: "/dev/null")) ?? ""
        _ = runtimes
        for mode in 0...2 {
            let host = UIHostingController(rootView: ProbeSegmentRow(mode: mode).frame(width: UIScreen.main.bounds.width, height: 68))
            let root = UIViewController(); root.view.backgroundColor = .white
            window!.rootViewController = root
            root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
            host.view.frame = CGRect(x: 0, y: 300, width: UIScreen.main.bounds.width, height: 68)
            host.view.backgroundColor = .clear
            host.view.layoutIfNeeded(); pump(0.3)
            guard let ia = probeInteractions(host.view).first, let iv = ia.view else { print("PROBE2 mode=\(mode) no interaction"); continue }
            let sel = NSSelectorFromString("_presentMenuAtLocation:")
            guard ia.responds(to: sel) else { print("PROBE2 mode=\(mode) no _presentMenuAtLocation"); continue }
            let p = iv.convert(CGPoint(x: 150, y: 334), from: root.view)
            typealias Fn = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let fn = unsafeBitCast(ia.method(for: sel), to: Fn.self)
            fn(ia, sel, p)
            pump(1.2)
            var tree: [String] = []
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }) { dumpTree(w, 0, &tree) }
            tree.forEach { print("PROBE2 mode=\(mode) tree \($0)") }
            let shot = screenImage()
            try? shot.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-probe2-m\(mode)-open.png"))
            ia.dismissMenu()
            for (i, t) in [0.05, 0.1, 0.15, 0.25].enumerated() {
                pump(t - (i == 0 ? 0 : [0.05, 0.1, 0.15, 0.25][i - 1]))
                try? screenImage().pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-probe2-m\(mode)-dismiss\(i).png"))
            }
            pump(0.8)
            try? screenImage().pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-probe2-m\(mode)-after.png"))
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }
}
