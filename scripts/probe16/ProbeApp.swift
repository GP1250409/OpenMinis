import SwiftUI
import UIKit

// Standalone probe app (iOS 16 runtime): how the long-press platter looks for
// several preview strategies, whether the preview is live or a static
// snapshot, and what the dismissal frames contain.

final class ProbeState: ObservableObject { @Published var red = false }

struct ProbeShape: Shape {
    let inset: CGFloat; let top: CGFloat; let bottom: CGFloat; let radius: CGFloat
    func path(in r: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: r.minX + inset, y: r.minY + top, width: r.width - 2 * inset, height: r.height - top - bottom))
    }
}

struct ClearHost: UIViewRepresentable {
    func makeUIView(context: Context) -> ClearHostView { ClearHostView() }
    func updateUIView(_ v: ClearHostView, context: Context) {}
}
final class ClearHostView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var v = superview; var d = 0
        while let c = v, d < 3 {
            if String(describing: type(of: c)).contains("HostingView") { c.backgroundColor = .clear }
            v = c.superview; d += 1
        }
    }
}

struct RowContent: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.blue.opacity(0.35)).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ivan 电源适配器询价邮件").font(.system(size: 16, weight: .semibold))
                Text("记住了。以后英文邮件").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 68)
    }
}

struct ProbeRow: View {
    let mode: Int
    @ObservedObject var state: ProbeState
    var fill: Color { state.red ? .red : Color(UIColor.secondarySystemBackground) }
    var segment: some View { Rectangle().fill(fill).padding(.horizontal, 6) }
    var lone: some View { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill).padding(.horizontal, 6).padding(.vertical, 4) }
    var body: some View {
        switch mode {
        case 0: // square segment, path outside bounds (-4 / +4)
            RowContent().background(segment)
                .contentShape(.contextMenuPreview, ProbeShape(inset: 2, top: -4, bottom: -4, radius: 20))
                .contextMenu { Button("取消固定") {}; Button("导出") {} }
        case 1: // lone card inside bounds, concentric path inside bounds
            RowContent().background(lone)
                .contentShape(.contextMenuPreview, ProbeShape(inset: 2, top: 0, bottom: 0, radius: 20))
                .contextMenu { Button("取消固定") {}; Button("导出") {} }
        case 2: // custom preview, default host background
            RowContent().background(segment)
                .contentShape(.contextMenuPreview, ProbeShape(inset: 6, top: 0, bottom: 0, radius: 16))
                .contextMenu { Button("取消固定") {}; Button("导出") {} } preview: {
                    RowContent().frame(width: UIScreen.main.bounds.width - 12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)).padding(4)
                }
        default: // custom preview, host background cleared
            RowContent().background(segment)
                .contentShape(.contextMenuPreview, ProbeShape(inset: 6, top: 0, bottom: 0, radius: 16))
                .contextMenu { Button("取消固定") {}; Button("导出") {} } preview: {
                    RowContent().frame(width: UIScreen.main.bounds.width - 12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)).padding(4)
                        .background(ClearHost())
                }
        }
    }
}

@main
final class ProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds); window = w
        w.rootViewController = UIViewController(); w.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.run() }
        return true
    }
    func pump(_ s: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }
    func interactions(_ v: UIView) -> [UIContextMenuInteraction] {
        v.interactions.compactMap { $0 as? UIContextMenuInteraction } + v.subviews.flatMap { interactions($0) }
    }
    func shot(_ name: String) {
        let ws = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
        let img = UIGraphicsImageRenderer(bounds: UIScreen.main.bounds).image { _ in
            for w in ws { w.drawHierarchy(in: w.frame, afterScreenUpdates: true) }
        }
        try? img.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p16-\(name).png"))
    }
    func run() {
        print("P16 os=\(UIDevice.current.systemVersion) scale=\(UIScreen.main.scale) w=\(UIScreen.main.bounds.width)")
        for mode in 0...3 {
            let state = ProbeState()
            let root = UIViewController(); root.view.backgroundColor = .systemBackground
            window!.rootViewController = root
            let host = UIHostingController(rootView: VStack(spacing: 0) {
                RowContent().background(Rectangle().fill(Color(UIColor.secondarySystemBackground)).padding(.horizontal, 6))
                ProbeRow(mode: mode, state: state)
                RowContent().background(Rectangle().fill(Color(UIColor.secondarySystemBackground)).padding(.horizontal, 6))
            })
            host.view.backgroundColor = .clear
            root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
            host.view.frame = CGRect(x: 0, y: 300, width: UIScreen.main.bounds.width, height: 204)
            pump(0.4)
            let all = interactions(host.view)
            guard let ia = all.first, let iv = ia.view else { print("P16 mode=\(mode) no interaction"); continue }
            let sel = NSSelectorFromString("_presentMenuAtLocation:")
            guard ia.responds(to: sel) else { print("P16 mode=\(mode) no private present"); continue }
            typealias Fn = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            unsafeBitCast(ia.method(for: sel), to: Fn.self)(ia, sel, iv.convert(CGPoint(x: 150, y: 402), from: root.view))
            pump(1.2); shot("m\(mode)-open")
            state.red = true
            pump(0.5); shot("m\(mode)-open-red")
            state.red = false
            pump(0.3)
            ia.dismissMenu()
            var t = 0.0
            for (i, s) in [0.02, 0.06, 0.12, 0.2, 0.35, 0.6, 1.0].enumerated() {
                pump(s - t); t = s; shot("m\(mode)-d\(i)")
            }
            print("P16 mode=\(mode) done")
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        print("P16_DONE"); fflush(stdout); exit(0)
    }
}
