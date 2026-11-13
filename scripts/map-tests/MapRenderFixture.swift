// Standalone simulator fixture: renders the actual production MUMapView.
import SwiftUI
import UIKit

// Sole app-wide dependency of the map view. Must match production storage key;
// Python verifies the value against MinisUIView.swift before building.
enum MUChartStyle { static let key = "genuiChartPalette" }

@main final class MapRenderFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        let window=UIWindow(frame:UIScreen.main.bounds)
        window.rootViewController=UIViewController()
        window.makeKeyAndVisible()
        self.window=window
        DispatchQueue.main.async { self.renderMaps() }
        return true
    }
    @MainActor private func renderMaps() {
        let programs:[(String,String)] = [
            ("us", "root = BlockMap(\"us\", [\"CA\",\"NY\",\"TX\",\"WA\",\"FL\",\"DC\",\"AK\",\"HI\"], [2,4,6,3,5,1,2,3], null, \"美国方块地图\", \"示意数据 · 非官方统计\", \"内置测试示例\", \"单位\", [\"CA\"])"),
            ("cn", "root = BlockMap(\"cn\", [\"京\",\"沪\",\"粤\",\"川\",\"台\",\"港\",\"澳\",\"新\"], [1,2,3,4,5,6,2,1], \"green\", \"中国方块地图\", \"34省级行政区 · 示意数据\", \"内置测试示例\", null, [\"台\",\"港\",\"澳\"])"),
            ("geo", "root = GeoMap(\"us\", [\"CA\",\"NY\",\"TX\",\"FL\",\"AK\",\"HI\"], [1,2,3,4,5,6], \"blue\", \"美国轮廓地图\", \"示意数据 · 非官方统计\", \"内置测试示例\", null, [\"CA\"], null, \"location\", [[-77.0365,38.8977,1],[-122.4,37.8,0],[-149.9,61.2,0],[-157.8,21.3,0]], [\"Washington\",\"San Francisco\",\"Anchorage\",\"Honolulu\"])"),
            ("cutout", "root = GeoMap(\"us\", [], [], null, \"位置高亮\", \"无数值 · 聚焦示例\", null, null, [\"NY\"], null, \"cutout\")")
        ]
        let out=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("map-render")
        try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks=0
        for style in ["","economist","economist2017"] {
            let defaults=UserDefaults(suiteName:"map-fixture-"+style)!
            defaults.set(style,forKey:MUChartStyle.key)
            for (name,program) in programs {
                let validation=MinisUIEngine.validate(program)
                guard validation.ok,let comp=validation.root else { fatalError(MinisUIEngine.feedback(validation)) }
                let width=390.0,height=MUMapMetrics(comp,width:width).height
                let content=MUMapView(comp:comp).defaultAppStorage(defaults)
                let host=UIHostingController(rootView:content)
                let measured=host.sizeThatFits(in:CGSize(width:width,height:10000))
                guard abs(measured.height-height)<0.6 else { fatalError("height mismatch \(name): \(measured.height) != \(height)") }
                checks+=1
                let renderer=ImageRenderer(content:content.frame(width:width,height:height))
                renderer.scale=2
                guard let image=renderer.uiImage,let png=image.pngData() else { fatalError("render failed") }
                try! png.write(to:out.appendingPathComponent("\(style.isEmpty ? "system" : style)-\(name).png"))
                checks+=1
            }
        }
        let marker="MAP_RENDER_PASS checks=\(checks) png=12\n"
        try! marker.write(to:out.appendingPathComponent("result.log"),atomically:true,encoding:.utf8)
        print(marker); fflush(stdout); exit(0)
    }
}
