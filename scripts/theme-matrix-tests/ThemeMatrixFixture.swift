import SwiftUI
import UIKit

@main final class ThemeMatrixFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var host: UIHostingController<AnyView>!
    var output: URL!
    var checks = 0
    var failures: [String] = []
    var heights: [Int: CGFloat] = [:]
    var roots: [MUComp] = []
    var ctx: MUContext!
    let apps = ["", "chatgpt", "claude"]
    let styles = ["", "economist", "economist2017"]
    func check(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures.append(label) } }
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("theme-matrix")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host = UIHostingController(rootView: AnyView(EmptyView()))
        // Card coordinates, not a full-screen page: use the same safe-area
        // contract as the existing 720-PNG production chart regression.
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        w.rootViewController = host; w.makeKeyAndVisible(); window = w
        let sources = [
            "root = Card([Title(\"Readable node title\"), Text(\"Readable body text\"), Badge(\"Accent\", \"info\"), Button(\"App theme button\", @Copy(\"preview\"))], \"Readable card title\")",
            "root = Card([MultiChart(\"line\", [\"Jan\", \"Feb\", \"Mar\"], [\"First\", \"Context\"], [[2, 5, 3], [1, 2, 4]], \"Professional chart\", null, \"Test data\", null, [\"First\"])])",
            "root = Card([BlockMap(\"us\", [\"CA\", \"NY\", \"TX\"], [1, 2, 3], null, \"Professional map\", null, \"Test data\")])"
        ]
        roots = sources.map { source in
            let v = MinisUIEngine.validate(source)
            guard v.ok, let root = v.root else { fatalError(MinisUIEngine.feedback(v)) }; return root
        }
        let p = MUProgram.parse(sources[0])
        ctx = MUContext(state: [:], program: p, defaults: [:], set: { _,_,_ in }, commit: {}, run: { _ in })
        // Deliberately non-default settings: switching App theme must preserve them.
        UserDefaults.standard.set("bold", forKey: MUChartDrawing.weightKey)
        UserDefaults.standard.set("context", forKey: MUChartDrawing.dashKey)
        runCase(0, row: 0); return true
    }
    func rgb(_ image: UIImage, x: CGFloat, y: CGFloat) -> MUMapRGB {
        let cg = image.cgImage!.cropping(to: CGRect(x: x*image.scale, y: y*image.scale, width: 1, height: 1))!
        var b = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &b, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return MUMapRGB(hex: String(format: "#%02X%02X%02X", b[0],b[1],b[2]))
    }
    func runCase(_ index: Int, row: Int) {
        if index == 18 { finish(); return }
        let app = apps[index/6], style = styles[index%3]
        let dark = (index%6)/3 == 1
        let scheme: ColorScheme = dark ? .dark : .light
        ChatThemeStore.select(app)
        UserDefaults.standard.set(style, forKey: MUChartStyle.key)
        window!.overrideUserInterfaceStyle = dark ? .dark : .light
        host.rootView = AnyView(MUNodeView(comp: roots[row], ctx: ctx, topLevel: true).modifier(MURootSurface()).environment(\.colorScheme, scheme))
        host.view.backgroundColor = ChatColors.backgroundUIColor
        let size = host.sizeThatFits(in: CGSize(width: 360, height: 1600))
        host.view.frame = CGRect(x: 0, y: 0, width: 360, height: size.height)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.25) {
            self.host.view.setNeedsLayout(); self.host.view.layoutIfNeeded()
            let measured = self.host.sizeThatFits(in: CGSize(width:360,height:1600))
            self.check(abs(measured.height-size.height)<0.5, "no late height jump \(index)-\(row)")
            if let previous = self.heights[row] { self.check(abs(previous-measured.height)<0.5, "stable theme height \(index)-\(row)") }
            else { self.heights[row] = measured.height }
            let image = UIGraphicsImageRenderer(bounds:self.host.view.bounds).image { _ in self.host.view.drawHierarchy(in:self.host.view.bounds,afterScreenUpdates:true) }
            let base = MUSurface.rgb(ChatColors.backgroundUIColor,over:MUMapRGB(hex:"#FFFFFF"),scheme:scheme)
            let surface = MUSurface.rgb(ChatColors.secondaryBgUIColor,over:base,scheme:scheme)
            let actual = self.rgb(image,x:180,y:measured.height-7)
            let a=actual.rgb,e=surface.rgb
            self.check(abs(a.0-e.0)<0.012 && abs(a.1-e.1)<0.012 && abs(a.2-e.2)<0.012,"real card fill \(index)-\(row): \(actual.hex) vs \(surface.hex)")
            // Painted foreground must exist across many actual bitmap samples.
            var painted=0
            for y in stride(from: CGFloat(16),to:measured.height-16,by:4) {
                for x in stride(from:CGFloat(16),to:CGFloat(344),by:4) {
                    if self.rgb(image,x:x,y:y).contrast(on:surface)>2 { painted += 1 }
                }
            }
            self.check(painted>20,"real foreground pixels \(index)-\(row) count=\(painted)")
            let theme = MUChartTheme.resolved(for:style,on:surface,scheme:scheme)
            let warmed = MUChartTheme.resolved(for:style,on:surface,scheme:scheme)
            self.check(MUSurface.rgb(theme.series[0],over:surface,scheme:scheme)==MUSurface.rgb(warmed.series[0],over:surface,scheme:scheme),"warm surface cache")
            self.check(UserDefaults.standard.string(forKey:MUChartDrawing.weightKey)=="bold" && UserDefaults.standard.string(forKey:MUChartDrawing.dashKey)=="context","App theme preserves professional settings")
            try! image.pngData()!.write(to:self.output.appendingPathComponent("app-\(app)-\(dark ? "dark" : "light")-\(style)-row-\(row).png"))
            if row == 2 { self.runCase(index+1,row:0) } else { self.runCase(index,row:row+1) }
        }
    }
    func finish() {
        let drawing=MUChartDrawing(weight:"fine",pattern:"dashed")
        check(abs(drawing.width(2.5)-2)<0.001 && drawing.dash()==[5,3],"fine/dashed tokens")
        check(MUChartDrawing(weight:"unknown",pattern:"unknown").width(2.5)==2.5,"unknown preference defaults")
        check(MUChartDrawing(weight:"bold",pattern:"context").dash(context:true)==[5,3] && MUChartDrawing(weight:"bold",pattern:"context").dash().isEmpty,"context dash isolation")
        let png = try! FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil).filter { $0.pathExtension=="png" }.count
        check(png==54,"18 combinations x 3 production cards")
        let marker=failures.isEmpty ? "THEME_MATRIX_PASS checks=\(checks) png=\(png)" : "THEME_MATRIX_FAIL checks=\(checks) \(failures.joined(separator:"; "))"
        try! marker.write(to:output.appendingPathComponent("result.log"),atomically:true,encoding:.utf8)
        print(marker); fflush(stdout); exit(failures.isEmpty ? 0 : 1)
    }
}
