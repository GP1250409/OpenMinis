// Mounted UIKit test: production MUContext/MUNodeView and all renderer bodies.
// Does not compile AssistantBlock/Coordinator: context actions are inert stubs.
import SwiftUI
import UIKit

private func nativeRGB(_ color: UIColor, over parent: MUMapRGB, scheme: ColorScheme) -> MUMapRGB {
    let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    precondition(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
    let p = parent.rgb
    let channels = [Double(r)*Double(a)+p.0*(1-Double(a)), Double(g)*Double(a)+p.1*(1-Double(a)), Double(b)*Double(a)+p.2*(1-Double(a))]
    return MUMapRGB(hex: String(format: "#%02X%02X%02X", Int((channels[0]*255).rounded()),Int((channels[1]*255).rounded()),Int((channels[2]*255).rounded())))
}
private struct SurfaceProbe: View {
    @Environment(\.muSurface) var surface
    let report: (MUMapRGB?) -> Void
    var body: some View { Color.clear.overlay(alignment: .topLeading) { MUCardTitle(title: "Readable surface text").padding(.top, 14).padding(.leading, 14) }.onAppear { report(surface) }.onChange(of: surface?.hex) { _ in report(surface) } }
}
@main final class CardDarkFixture: UIResponder, UIApplicationDelegate, UICollectionViewDataSource {
    var window: UIWindow?
    var list: UICollectionView!
    var roots: [MUComp] = []
    var ctx: MUContext!
    var checks = 0
    var failures: [String] = []
    var output: URL!
    var observed: MUMapRGB?
    func check(_ ok: Bool, _ message: String) { checks += 1; if !ok { failures.append(message) } }
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("card-dark")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController(); w.rootViewController = vc; w.makeKeyAndVisible(); window = w
        let layout = UICollectionViewFlowLayout(); layout.itemSize = CGSize(width: 360, height: 100); layout.minimumLineSpacing = 0
        list = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 740), collectionViewLayout: layout)
        list.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "card"); list.dataSource = self; vc.view.addSubview(list)
        let program = MUProgram.parse("root = Card([Text(\"Readable body text\")], \"Readable card title\")")
        ctx = MUContext(state: [:], program: program, defaults: [:], set: { _,_,_ in }, commit: {}, run: { _ in })
        let programs = [
            "root = Card([], \"Readable card title\")",
            "root = Card([Title(\"Readable node title\")])",
            "root = Card([Text(\"Readable body text\")])",
            "root = Card([List([\"Readable list item text\"])])",
            "root = Card([Callout(\"Readable callout text\")])",
            "root = Stack([Card([Text(\"First readable card\")]), Card([Text(\"Second readable card\")])])"
        ]
        roots = programs.map { source in
            let v = MinisUIEngine.validate(source)
            guard v.ok, let root = v.root else { fatalError(MinisUIEngine.feedback(v)) }; return root
        }
        DispatchQueue.main.async { self.runCase(0) }; return true
    }
    func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { roots.count }
    func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = view.dequeueReusableCell(withReuseIdentifier: "card", for: path)
        cell.contentConfiguration = UIHostingConfiguration {
            MUNodeView(comp: self.roots[path.item], ctx: self.ctx, topLevel: path.item != 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(MURootSurface())
        }.margins(.all, 0)
        cell.backgroundColor = ChatColors.backgroundUIColor
        return cell
    }
    // Quantify actual text body pixels, excluding borders, bullets and callout icon.
    // Require many painted pixels AND several occupied scanlines; not max-pixel contrast.
    func audit(_ image: UIImage, _ bg: MUMapRGB, _ label: String, _ row: Int) {
        let cg = image.cgImage!; let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0; var lines = Set<Int>()
        let scale = image.scale
        for y in Int(16*scale)..<min(h, Int((row == 5 ? 90 : 48)*scale)) {
            for x in Int(55*scale)..<min(w, Int(290*scale)) {
                let i = 4*(y*w+x)
                let rgb = MUMapRGB(hex: String(format: "#%02X%02X%02X", bytes[i], bytes[i+1], bytes[i+2]))
                if rgb.contrast(on: bg) >= 4.5 { count += 1; lines.insert(y) }
            }
        }
        check(count >= 100 && lines.count >= 6, "\(label) row=\(row) bodyPixels=\(count) scanlines=\(lines.count)")
        print("CARD_BODY \(label) row=\(row) pixels=\(count) lines=\(lines.count)")
    }
    func runCase(_ index: Int) {
        // First cold dark, then live light/dark switching, then theme + reused cells.
        let cases: [(String, UIUserInterfaceStyle)] = [("", .dark),("", .light),("", .dark),("chatgpt", .dark),("claude", .light),("claude", .dark),("deepseek", .dark)]
        if index == cases.count { testSurfaces(); return }
        let (theme, style) = cases[index]; ChatThemeStore.select(theme)
        window!.overrideUserInterfaceStyle = style
        list.backgroundColor = ChatColors.backgroundUIColor
        list.reloadData(); list.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) {
            let scheme: ColorScheme = style == .dark ? .dark : .light
            let base = nativeRGB(ChatColors.backgroundUIColor, over: MUMapRGB(hex: "#FFFFFF"), scheme: scheme)
            for row in 0..<self.roots.count {
                let cell = self.list.cellForItem(at: IndexPath(item: row, section: 0))!
                cell.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true) }
                let surface = row == 5 ? nativeRGB(UIColor.label.withAlphaComponent(0.04), over: base, scheme: scheme) : nativeRGB(ChatColors.secondaryBgUIColor, over: base, scheme: scheme)
                let label = "case-\(index)-\(theme)-\(style.rawValue)"
                self.audit(image, surface, label, row)
                try! image.pngData()!.write(to: self.output.appendingPathComponent("\(label)-row-\(row).png"))
            }
            self.runCase(index+1)
        }
    }
    func testSurfaces() {
        // Includes a bright Card inside dark hosting traits, alpha nesting, and
        // a deliberate UIKit-current/SwiftUI-scheme disagreement.
        surfaceCase(0)
    }
    func surfaceCase(_ index: Int) {
        if index == 4 { finish(); return }
        let scheme: ColorScheme = index == 3 ? .light : .dark
        let parent = MUMapRGB(hex: index == 3 ? "#EEEEEE" : "#121212")
        let fill = [UIColor.white, UIColor.black.withAlphaComponent(0.2), UIColor.white.withAlphaComponent(0.04), UIColor.label.withAlphaComponent(0.04)][index]
        let expected = nativeRGB(fill, over: parent, scheme: scheme)
        observed = nil
        let host = UIHostingController(rootView:
            SurfaceProbe { self.observed = $0 }.frame(width: 200, height: 70)
                .modifier(MUCardSurface(fill: .clear, nativeFill: fill))
                .environment(\.muSurface, parent).environment(\.colorScheme, scheme))
        host.view.frame = CGRect(x: 0, y: 630, width: 200, height: 70)
        window!.rootViewController!.addChild(host); window!.rootViewController!.view.addSubview(host.view); host.didMove(toParent: window!.rootViewController)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.15) {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let cg = image.cgImage!; var rgba = [UInt8](repeating: 0, count: 4)
            let sample = cg.cropping(to: CGRect(x: cg.width/2, y: Int(Double(cg.height)*0.86), width: 1, height: 1))!
            let c = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let actual = MUMapRGB(hex: String(format: "#%02X%02X%02X", rgba[0],rgba[1],rgba[2]))
            self.check(self.observed == expected, "surface environment \(index)")
            let a = actual.rgb, e = expected.rgb
            self.check(abs(a.0-e.0)<0.012 && abs(a.1-e.1)<0.012 && abs(a.2-e.2)<0.012, "painted surface \(index) actual=\(actual.hex) expected=\(expected.hex)")
            self.check(expected.ink.contrast(on: expected) >= 4.5, "surface ink \(index)")
            self.audit(image, expected, "surface-\(index)", 0)
            try! image.pngData()!.write(to: self.output.appendingPathComponent("surface-\(index).png"))
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            self.surfaceCase(index+1)
        }
    }
    func finish() {
        let marker = failures.isEmpty ? "CARD_DARK_HOST_PASS checks=\(checks) png=46" : "CARD_DARK_HOST_FAIL checks=\(checks) failures=\(failures.joined(separator: "; "))"
        try! marker.write(to: output.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        print(marker); fflush(stdout); exit(failures.isEmpty ? 0 : 1)
    }
}
