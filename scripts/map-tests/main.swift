import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
var checks=0
func check(_ ok: @autoclosure () -> Bool, _ name: String) {
    checks+=1
    if !ok() { print("FAIL: \(name)"); exit(1) }
    print("PASS: \(name)")
}
func component(_ name:String="BlockMap", region:String="us", codes:[String]=["CA","NY"], values:[Double]=[1,2], extra:[String:MUValue]=[:]) -> MUComp {
    var p:[String:MUValue]=["region":.str(region),"codes":.arr(codes.map(MUValue.str)),"values":.arr(values.map(MUValue.num))]
    p.merge(extra) { _,new in new }; return MUComp(name:name,props:p,line:1)
}
let states=Set("AK AL AR AZ CA CO CT DC DE FL GA HI IA ID IL IN KS KY LA MA MD ME MI MN MO MS MT NC ND NE NH NJ NM NV NY OH OK OR PA RI SC SD TN TX UT VA VT WA WI WV WY".split(separator:" ").map(String.init))
check(Set(MUMapRegion.us.map(\.code)) == states,"50 states plus DC exactly")
check(MUMapRegion.us.count==51,"US count")
check(MUMapRegion.cn.count==34,"China count")
for (region,expectedColumns) in [("us",11),("cn",8)] {
    let tiles=MUMapRegion.tiles(region)
    check(Set(tiles.map { "\($0.row),\($0.column)" }).count==tiles.count,"\(region) no overlap")
    check(Set(tiles.map(\.code)).count==tiles.count,"\(region) unique codes")
    check(tiles.map(\.row).max()==7,"\(region) eight rows")
    check(tiles.map(\.column).max()==expectedColumns-1,"\(region) columns")
    for tile in tiles {
        check(MUMapRegion.canonical(tile.code.lowercased(),region:region)==tile.code,"canonical \(region) \(tile.code)")
    }
}
let anchors:[String:(Int,Int)] = ["AK":(0,0),"ME":(0,10),"WI":(1,5),"VT":(1,9),"NH":(1,10),"NY":(2,8),"MA":(2,9),"DC":(5,8),"HI":(7,0),"FL":(7,8)]
for (code,rc) in anchors { check(MUMapRegion.us.contains { $0.code==code && $0.row==rc.0 && $0.column==rc.1 },"official p9 \(code)") }
check(MUMapRegion.canonical("CN-11",region:"cn")=="BJ","GB numeric alias")
check(MUMapRegion.canonical("440000",region:"cn")=="GD","six digit GB alias")
check(MUMapRegion.canonical("台湾省",region:"cn")=="TW","Taiwan included")
check(MUMapRegion.canonical("港",region:"cn")=="HK","HK abbreviation")
check(MUMapRegion.canonical("澳门",region:"cn")=="MO","Macao included")
check(MUMapRegion.canonical("US-CA",region:"us")=="CA","ISO US alias")
let bins=MUMapBins(values:[0,100],boundaries:[10,20])
check(bins.index(-1)==0,"underflow bin")
check(bins.index(10)==1,"boundary goes right")
check(bins.index(20)==2,"last boundary goes right")
check(bins.index(1000)==2,"overflow bin")
check(bins.label(1)=="10–<20","half-open legend")
check(MUMapBins(values:[],boundaries:[-30.125,-30.124]).label(1)=="-30.125–<-30.124","explicit close decimal boundaries remain distinct and complete")
check(MUMapBins(values:[],boundaries:[-1e100,1e100]).label(1).contains("e+100"),"extreme explicit interval preserves exponent")
for input in [[-3.0,9.0],[0.0],[0.0,0.0],[-100.0,-20.0],[]] {
    let b=MUMapBins(values:input,diverging:true)
    check(b.count==6,"six automatic bins")
    check(b.edges[2]==0,"diverging zero boundary")
    check(zip(b.edges,b.edges.reversed()).allSatisfy { abs($0+$1)<1e-10 },"diverging symmetric")
    check(b.edges.allSatisfy(\.isFinite),"finite edges")
}
check(MUMapBins(values:[2,2]).edges.count==5,"constant values supported")
check(MUMapBins(values:[]).count==6,"no data safe")
for style in ["","economist","economist2017"] {
    let theme=MUMapTheme.resolve(style)
    check(theme.background.hex == (style=="economist" ? "#F1EFEA" : "#FFFFFF"),"theme surface \(style)")
    for name in MUMapScale.names {
        let ramp=MUMapScale.colors(name,style:style,count:6)
        check(ramp.count==6,"\(style) \(name) six colors")
        check(ramp.first != ramp.last,"\(style) \(name) ramp")
        check(ramp.allSatisfy { let l=$0.luminance; return max((l+0.05)/0.05,1.05/(l+0.05))>=4.5 },"\(style) \(name) legible ink")
    }
}
check(MUMapScale.colors(nil,style:"economist",count:6) != MUMapScale.colors(nil,style:"economist2017",count:6),"recent and 2017 distinct defaults")
check(MUMapScale.colors(nil,style:"",count:6) != MUMapScale.colors(nil,style:"economist2017",count:6),"system distinct default")
let bad=component(codes:["ZZ","?"],values:[1,2])
check(MUMapCore.checks(bad).contains { $0.code=="map-code" && $0.msg.contains("ZZ, ?") },"unknown codes listed")
check(!MUMapCore.checks(component(region:"cn",codes:["京","北京"],values:[1,2])).isEmpty,"aliases cannot duplicate")
check(!MUMapCore.checks(component(codes:["CA"],values:[])).isEmpty,"parallel arrays length")
check(!MUMapCore.checks(component(extra:["bins":.arr([.num(2),.num(1)])])).isEmpty,"unsorted boundaries rejected")
check(!MUMapCore.checks(component(extra:["bins":.arr([.num(1),.num(1)])])).isEmpty,"duplicate boundaries rejected")
check(!MUMapCore.checks(component(extra:["scale":.str("diverging"),"bins":.arr([.num(-2),.num(0),.num(1)])])).isEmpty,"asymmetric diverging rejected")
check(MUMapCore.checks(component(extra:["scale":.str("diverging"),"bins":.arr([.num(-2),.num(0),.num(2)])])).isEmpty,"symmetric diverging accepted")
for region in ["us","cn"] {
    for width in [120.0,240,320,390,768] {
        let c=component(region:region,codes:[],values:[])
        let m=MUMapMetrics(c,width:width)
        check(abs(m.plotHeight-(Double(m.rows)*m.cell+Double(m.rows-1)*m.gap))<1e-9,"\(region) row-exact plot at \(width)")
        check(MinisUIEngine.estimatedHeight(c,width:width)==m.height,"\(region) estimate exact at \(width)")
        check(m.rect(MUMapRegion.tiles(region).last!).maxY<=m.plotY+m.plotHeight+1e-9,"last row contained")
    }
}
for name in ["BlockMap","GeoMap"] {
    let program="root = Card([\(name)(\"us\", [\"CA\", \"NY\"], [1, 2], \"blue\", \"示意数据\", null, \"示意，非官方\")])"
    let result=MinisUIEngine.validate(program)
    check(result.ok,"\(name) Lang parses and validates")
    check(result.root.map { MUCardPlane.retainsOuterSurface($0) } ?? false,"\(name) retains outer Card")
    check(MinisUIEngine.fallbackText(result.root).contains("来源：示意，非官方"),"\(name) source export")
}
check(!MinisUIEngine.validate("root = BlockMap(\"us\", [\"ZZ\"], [1])").ok,"Lang rejects unknown code")
check(MinisUIEngine.validate("root = GeoMap(\"cn\", [], [])").ok,"shipped Geo China accepted")
check(Set(MUMapGeometry.us.map(\.code))==states,"offline geometry 51 regions")
check(MUMapGeometry.us.allSatisfy { !$0.rings.isEmpty && $0.rings.allSatisfy { $0.count>=4 } },"geometry rings complete")
check(MUMapGeometry.us.flatMap(\.rings).flatMap { $0 }.allSatisfy { CGRect(x:0,y:0,width:1001,height:641).contains($0) },"all geometry inside canvas")
for (lon,lat) in [(-77.0365,38.8977),(-149.9,61.2),(-157.8,21.3),(-122.4,37.8)] {
    check(MUMapProjection.usPoint(lon:lon,lat:lat) != nil,"project city \(lon)")
}
check(MUMapProjection.usPoint(lon:116.4,lat:39.9)==nil,"reject overseas point")
let rect=CGRect(x:10,y:20,width:200,height:128)
check(MUMapProjection.view(CGPoint(x:500,y:320),in:rect)==CGPoint(x:110,y:84),"aspect fit center")
let bounds=CGRect(x:0,y:0,width:100,height:100)
let box=MUMapLabels.place(anchor:CGPoint(x:40,y:40),size:CGSize(width:30,height:12),bounds:bounds,occupied:[])!
let next=MUMapLabels.place(anchor:CGPoint(x:40,y:40),size:CGSize(width:30,height:12),bounds:bounds,occupied:[box])!
check(!box.intersects(next),"labels avoid overlap")
let leader=MUMapLabels.leader(anchor:CGPoint(x:40,y:40),label:box)
check(zip(leader,leader.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y },"orthogonal leaders only")
for width in [120.0,240,320,390] {
    for edges in [[-30.0,-20,-10,0,10,20,30],[-30.125,-20.125,-10.125,-0.125,0,0.125,10.125,20.125,30.125]] {
        let raw="root = BlockMap(\"us\", [\"TX\"], [-12.1], \"diverging\", \"参议院：34州定盘，民主党赢下21席\", \"蓝＝民主党胜，红＝共和党胜，色深＝领先幅度；2026年完整说明文字按宽度自动换行而不截断\", \"Wikipedia / AP，截至2026-11-13，长来源说明\", \"百分点\", [\"TX\"], ["+edges.map(String.init(describing:)).joined(separator:",")+"])"
        let v=MinisUIEngine.validate(raw)
        check(v.ok,"8/10 interval long-text fixture valid")
        guard let c=v.root else { fatalError("fixture missing") }
        let m=MUMapMetrics(c,width:width), bins=MUMapBins(values:c.numbers("values"),boundaries:edges,diverging:true)
        check(m.legendFrames.count==bins.count,"every bin has a compact swatch")
        for r in m.legendFrames {
            check(abs(r.height-6.0)<1e-6,"swatch height is 6pt")
            check(abs(r.minY-m.legendY)<1e-6,"single-row color strip")
            check(r.maxX<=width-10+0.1 && r.minX>=10,"swatch within horizontal bounds")
            check(r.maxY<m.missingY,"swatch above missing row")
        }
        check(!m.legendTicks.isEmpty,"at least one boundary tick placed")
        if width >= 240 && edges.count == 7 {
            check(m.legendTicks.count == 7,"all seven integer boundary ticks fit at \(width)pt")
            check(m.unitY - m.legendY <= 52,"compact legend stays concise at \(width)pt")
        }
        var prevTickMaxX = -Double.infinity
        for t in m.legendTicks {
            check(t.frame.minX >= 10 - 0.1 && t.frame.maxX <= width - 10 + 0.1,"tick within horizontal bounds")
            check(t.frame.maxY < m.missingY && t.frame.minY >= m.legendY,"tick above missing row")
            check(t.frame.minX >= prevTickMaxX + 3.9,"boundary ticks never overlap")
            prevTickMaxX = Double(t.frame.maxX)
        }
        if m.endsRect != .zero {
            check(m.endsRect.minX >= 10 - 0.1 && m.endsRect.maxX <= width - 10 + 0.1,"endpoint summary within bounds")
            check(m.endsRect.maxY <= m.unitY,"endpoint summary above unit/plot")
        }
        check(m.subtitleHeight>20 && m.sourceHeight>10,"long explanation wraps without ellipsis")
        check(m.plotY>=m.unitY+m.unitHeight,"unit does not cover map")
        check(MinisUIEngine.estimatedHeight(c,width:width)==m.height,"long-text estimated height equals native layout contract")
    }
}
for darkBg in ["#000000","#1C1C1E","#2A2A2A","#30302E","#28292D"] {
    let s = MUMapRGB(hex: darkBg)
    for style in ["","economist","economist2017"] {
        let adapted = MUMapTheme.resolve(style).adapted(to: s)
        check(adapted.text.contrast(on: s) >= 10.0,"dark primary text high contrast on \(darkBg)")
        check(adapted.muted.contrast(on: s) >= 6.0,"dark muted text readable on \(darkBg)")
        check(adapted.text != adapted.muted,"dark primary and muted maintain visual hierarchy on \(darkBg)")
    }
}

// MARK: - Generic MapPack v1 & Multi-Pack Engine Tests

let store = MUMapPackStore.shared
let packIds = store.availablePackIds()
let expectedPacks = ["us-admin1","world-admin0","europe-admin0","de-admin1","jp-admin1","ca-admin1","au-admin1","br-admin1","kr-admin1","gb-admin1","fr-admin1","it-admin1","es-admin1","us-county","cn-admin1"]
check(Set(packIds) == Set(expectedPacks), "all 15 packs loaded from catalog")

// 1. Pack protocol safety & binary decoder rejection tests
check(!MUMapPackDecoder.isSafePackId("../etc"), "reject path traversal packId")
check(!MUMapPackDecoder.isSafePackId("UPPER"), "reject uppercase packId")
check(!MUMapPackDecoder.isSafePackId(""), "reject empty packId")
check(MUMapPackDecoder.isSafePackId("us-county"), "accept safe packId")

func makeValidMump(scale: Float = 10.0) -> Data {
    var d = Data([0x4D, 0x55, 0x4D, 0x50, 1, 0, 0, 0]) // MUMP v1 flags=0
    func app<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    app(scale.bitPattern.littleEndian)
    app(UInt32(1).littleEndian) // features
    app(UInt32(1).littleEndian) // rings
    app(UInt32(3).littleEndian) // vertices
    app(UInt32(0).littleEndian) // overlays
    app(UInt32(0).littleEndian) // overlayVerts
    // 1 feature: rStart=0, rCount=1, flags=0
    app(UInt32(0).littleEndian); app(UInt16(1).littleEndian); app(UInt16(0).littleEndian)
    // 1 ring: vStart=0, vCount=3
    app(UInt32(0).littleEndian); app(UInt32(3).littleEndian)
    // 3 vertices: (10,10), (20,10), (15,20)
    app(Int16(100).littleEndian); app(Int16(100).littleEndian)
    app(Int16(200).littleEndian); app(Int16(100).littleEndian)
    app(Int16(150).littleEndian); app(Int16(200).littleEndian)
    return d
}
let validMump = makeValidMump()
let validSha = MUMapSHA256.hex(validMump)
check((try? MUMapPackDecoder.decode(validMump, expectedFeatures: 1, expectedSha256: validSha)) != nil, "valid mump decodes with matching sha256")
do {
    _ = try MUMapPackDecoder.decode(validMump, expectedFeatures: 1, expectedSha256: String(repeating: "0", count: 64))
    check(false, "checksum mismatch must throw")
} catch let err as MUMapPackError { check(err == .checksumMismatch, "checksum mismatch rejected") }
var badMagic = validMump; badMagic[0] = 0x58
do { _ = try MUMapPackDecoder.decode(badMagic); check(false, "bad magic must throw") }
catch let err as MUMapPackError { check(err == .corruptHeader, "bad magic rejected") }
var badVer = validMump; badVer[4] = 9
do { _ = try MUMapPackDecoder.decode(badVer); check(false, "bad version must throw") }
catch let err as MUMapPackError { check(err == .corruptHeader, "unsupported version rejected") }
let truncated = validMump.prefix(validMump.count - 4)
do { _ = try MUMapPackDecoder.decode(Data(truncated)); check(false, "truncated mump must throw") }
catch let err as MUMapPackError { check(err == .corruptBounds, "truncated payload rejected") }
var hugeCount = validMump
withUnsafeBytes(of: UInt32(99999).littleEndian) { hugeCount.replaceSubrange(12..<16, with: $0) }
do { _ = try MUMapPackDecoder.decode(hugeCount); check(false, "oversized header count must throw") }
catch let err as MUMapPackError { check(err == .oversized, "oversized feature count rejected") }

// 2. Decode all 14 real packs & test LRU eviction limit (<=4 packs, <=4MB)
store.clearCache()
for pid in expectedPacks {
    let meta = store.metadata(for: pid)
    check(meta != nil, "metadata exists for \(pid)")
    let geom = store.geometry(for: pid)
    check(geom != nil, "geometry decodes for \(pid)")
    if let meta, let geom {
        check(geom.features.count == meta.features.count, "\(pid) decoded feature count matches manifest")
        check(geom.features.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.count >= 3 } }, "\(pid) every polygon ring valid")
        let stats = store.cacheStats()
        check(stats.packCount <= MUMapPackStore.maxCachedPacks, "LRU pack cap respected after \(pid)")
        check(stats.byteCount <= MUMapPackStore.maxCachedBytes, "LRU byte cap respected after \(pid)")
    }
}
// Reload evicted cold pack ("world") cleanly
check(store.geometry(for: "world") != nil, "evicted pack reloads on demand")
check(store.cacheStats().order.last == "world-admin0", "LRU touches world-admin0 most recently")

// 3. Builtin US fallback works with empty search paths
store.configureSearchPaths([])
check(store.metadata(for: "us") != nil && store.geometry(for: "us")?.features.count == 51, "builtin US fallback works without disk packs")
check(store.metadata(for: "world") == nil, "disk-only packs absent when search paths empty")
store.resetToDefaultSearchPaths()

// 4. Region aliases, ISO quirks, holes, overlays, and projections across all packs
check(store.resolvePackId("world") == "world-admin0", "world alias")
check(store.resolvePackId("eu") == "europe-admin0", "eu alias")
check(store.resolvePackId("uk") == "gb-admin1", "uk alias")
check(store.resolvePackId("us-counties") == "us-county", "us-counties alias")

check(store.canonical("FRA", region: "world") == "FR", "world France ISO3 -> FR (not -99)")
check(store.canonical("Norway", region: "world") == "NO", "world Norway -> NO (not -99)")
check(store.canonical("UK", region: "world") == "GB", "world UK -> GB")
check(store.canonical("XK", region: "world") == "XK", "world Kosovo -> XK")
check(store.canonical("IOA", region: "world") == "IOA", "world Indian Ocean Ter. distinct from AU")
check(store.canonical("ATC", region: "world") == "ATC", "world Ashmore distinct from AU")
check(store.canonical("Somaliland", region: "world") == "SOL", "world Somaliland -> SOL")
let worldGeom = store.geometry(for: "world")!
let worldMeta = store.metadata(for: "world")!
if let zaIdx = worldMeta.byCode["ZA"]?.index {
    check(worldGeom.features[zaIdx].count >= 2, "world South Africa preserves Lesotho interior hole (1:10m also carries Prince Edward Is.)")
}

check(store.canonical("MT", region: "eu") == "MT", "eu includes Malta")
check(store.canonical("UK", region: "eu") == "GB", "eu UK -> GB")
check(store.canonical("RU", region: "eu") == "RU", "eu includes clipped Russia")
check(store.canonical("TR", region: "eu") == "TR", "eu includes Turkey")

let expectedAdmin1Counts: [(String, Int, String, String)] = [
    ("de", 16, "BW", "DE-BW"),
    ("gb", 4, "ENG", "GB-ENG"),
    ("fr", 13, "FR-COR", "FR-20R"),
    ("it", 20, "Lombardia", "IT-25"),
    ("es", 19, "Canarias", "ES-CN"),
    ("jp", 47, "13", "JP-13"),
    ("ca", 13, "ON", "CA-ON"),
    ("au", 8, "NSW", "AU-NSW"),
    ("br", 27, "SP", "BR-SP"),
    ("kr", 17, "Seoul", "KR-11"),
]
for (reg, cnt, alias, canon) in expectedAdmin1Counts {
    let m = store.metadata(for: reg)
    check(m?.features.count == cnt, "\(reg) feature count == \(cnt)")
    check(store.canonical(alias, region: reg) == canon, "\(reg) alias \(alias) -> \(canon)")
}
check((store.geometry(for: "es")?.overlays.count ?? 0) >= 1, "Spain has Canarias inset box overlay")
check((store.geometry(for: "jp")?.overlays.count ?? 0) >= 1, "Japan has Okinawa inset box overlay")

// US Counties 3,143 + state overlay + unambiguous alias checks
let countyMeta = store.metadata(for: "us-county")
let countyGeom = store.geometry(for: "us-county")
check(countyMeta?.features.count == 3143, "us-county has 3,143 counties (50 states + DC)")
check((countyGeom?.overlays.count ?? 0) > 50, "us-county carries state boundary overlays")
check(store.canonical("US-06037", region: "us-county") == "06037", "us-county US- prefix")
check(store.canonical("Los Angeles County, CA", region: "us-county") == "06037", "us-county full name+state")
check(store.canonical("CA:Los Angeles", region: "us-county") == "06037", "us-county ST:Name")
check(store.canonical("Orleans Parish, LA", region: "us-county") == "22071", "us-county Louisiana parish")
check(store.canonical("Baltimore County, MD", region: "us-county") == "24005", "us-county Baltimore County distinct")
check(store.canonical("Baltimore city, MD", region: "us-county") == "24510", "us-county Baltimore city distinct")
check(store.canonical("MD:Baltimore", region: "us-county") == nil, "us-county ambiguous MD:Baltimore rejected")

// Multi-pack projections & city points + Aleutian antimeridian wrap + Southern Hemisphere
let worldV = MinisUIEngine.validate("root = GeoMap(\"world\", [\"US\", \"CN\", \"AU\", \"BR\"], [10, 20, 30, 40], \"blue\", \"全球示例\", null, \"测试\", null, [\"CN\"], null, \"location\", [[116.4, 39.9, 1], [151.2, -33.86, 0]], [\"Beijing\", \"Sydney\"])")
check(worldV.ok, "GeoMap world with points validates")
let euV = MinisUIEngine.validate("root = GeoMap(\"eu\", [\"DE\", \"FR\", \"GB\", \"MT\"], [10, 20, 30, 40], null, \"欧洲示例\", null, null, null, [\"MT\"], null, \"location\", [[13.4, 52.5, 1], [-21.9, 64.1, 1]], [\"Berlin\", \"Reykjavik\"])")
check(euV.ok, "GeoMap eu with Reykjavik & Malta validates")
let esV = MinisUIEngine.validate("root = GeoMap(\"es\", [\"ES-MD\", \"ES-CN\"], [10, 20], null, \"西班牙\", null, null, null, [\"ES-CN\"], null, \"location\", [[-3.7, 40.4, 1], [-16.25, 28.46, 0]], [\"Madrid\", \"Tenerife\"])")
check(esV.ok, "GeoMap es projects Canarias inset point")
let jpV = MinisUIEngine.validate("root = GeoMap(\"jp\", [\"JP-13\", \"JP-47\"], [50, 20], null, \"日本\", null, null, null, [\"JP-47\"], null, \"location\", [[139.69, 35.69, 1], [127.68, 26.21, 0]], [\"Tokyo\", \"Naha\"])")
check(jpV.ok, "GeoMap jp projects Okinawa inset point")
let countyV = MinisUIEngine.validate("root = GeoMap(\"us-county\", [\"06037\", \"36061\", \"02016\"], [10, 20, 5], null, \"美国县级\", null, \"US Census\", null, [\"06037\"], null, \"location\", [[-118.24, 34.05, 0], [174.1, 52.7, 0]], [\"LA\", \"Attu\"])")
check(countyV.ok, "GeoMap us-county validates LA and +174E Aleutian point")
check(!MinisUIEngine.validate("root = GeoMap(\"de\", [\"DE-BE\"], [10], null, null, null, null, null, null, null, \"location\", [[-77.0, 38.9, 1]], [\"DC\"])").ok, "GeoMap de rejects outside US point")

// Aspect ratio & estimatedHeight exactness across all 14 packs
for pid in expectedPacks {
    let prog = "root = Card([GeoMap(\"\(pid)\", [], [], null, \"标题 \(pid)\", \"多行说明文字测试自动换行完整性\", \"来源说明\", null, null, null, \"location\")])"
    let v = MinisUIEngine.validate(prog)
    check(v.ok, "Lang valid for pack \(pid)")
    if let root = v.root, let mapComp = root.children.first, let meta = store.metadata(for: pid) {
        let m = MUMapMetrics(mapComp, width: 320)
        let expectedRatio = meta.manifest.canvas.height / meta.manifest.canvas.width
        check(abs(m.plotHeight - 300.0 * expectedRatio) < 1e-6, "\(pid) plotHeight matches manifest canvas aspect ratio")
        check(MinisUIEngine.estimatedHeight(mapComp, width: 320) == m.height, "\(pid) estimatedHeight exact")
    }
}

// 5. Shipped China GeoMap + synthetic cn-admin1 protocol test
let cnOk = MinisUIEngine.validate("root = GeoMap(\"cn\", [\"BJ\"], [10])")
check(cnOk.ok, "GeoMap(\"cn\") validates against the shipped province pack with GB aliases")
let cnBadCode = MinisUIEngine.validate("root = GeoMap(\"cn\", [\"ZZ\"], [10])")
check(!cnBadCode.ok, "GeoMap(\"cn\") still rejects unknown GB codes")

let synthRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minis-synth-cn-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
let synthPack = synthRoot.appendingPathComponent("cn-admin1", isDirectory: true)
try! FileManager.default.createDirectory(at: synthPack, withIntermediateDirectories: true)
var synthMump = Data([0x4D, 0x55, 0x4D, 0x50, 1, 0, 0, 0])
func appendLE<T>(_ d: inout Data, _ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
appendLE(&synthMump, Float(10.0).bitPattern.littleEndian)
appendLE(&synthMump, UInt32(1).littleEndian); appendLE(&synthMump, UInt32(1).littleEndian); appendLE(&synthMump, UInt32(3).littleEndian)
appendLE(&synthMump, UInt32(1).littleEndian); appendLE(&synthMump, UInt32(2).littleEndian)
appendLE(&synthMump, UInt32(0).littleEndian); appendLE(&synthMump, UInt16(1).littleEndian); appendLE(&synthMump, UInt16(0).littleEndian)
appendLE(&synthMump, UInt32(0).littleEndian); appendLE(&synthMump, UInt32(3).littleEndian)
for (x,y) in [(Int16(5000),Int16(2000)),(Int16(5500),Int16(2000)),(Int16(5250),Int16(2500))] {
    appendLE(&synthMump, x.littleEndian); appendLE(&synthMump, y.littleEndian)
}
appendLE(&synthMump, UInt16(2).littleEndian); appendLE(&synthMump, UInt16(0).littleEndian)
appendLE(&synthMump, UInt32(0).littleEndian); appendLE(&synthMump, UInt32(2).littleEndian)
for (x,y) in [(Int16(8200),Int16(5000)),(Int16(8400),Int16(6200))] {
    appendLE(&synthMump, x.littleEndian); appendLE(&synthMump, y.littleEndian)
}
let synthTsv = "BJ\tBeijing\t北京\tCN-11|11|110000|北京市\n".data(using: .utf8)!
let synthManifest = """
{
  "schemaVersion": 1, "id": "cn-admin1", "aliases": ["cn"], "version": "test",
  "scope": "CN", "level": "admin1", "codeSystem": "GB",
  "source": {"name":"synthetic","url":"","version":"test","inputSha256":""},
  "license": {"spdx":"Test","attribution":"Test","commercialAllowed":false},
  "boundaryYear": 2024, "complianceNote": "Synthetic CN protocol fixture",
  "canvas": {"width": 1000, "height": 740, "coordScale": 10},
  "styleHints": {"featureStrokeWidth": 0.75, "overlayStrokeWidth": 0.9, "clipToCanvas": false, "drawSeaByDefault": true},
  "zones": [
    {"id":"main","projection":"albers","params":[25,47,105,0],"bounds":[-0.45,0.25,0.45,0.95],"frame":[20,15,960,710],"lonMin":73,"lonMax":136,"latMin":18,"latMax":54,"antimeridianWrap":false,"insetLabel":null,"insetBox":null},
    {"id":"SCS","projection":"albers","params":[25,47,105,0],"bounds":[-0.02,0.02,0.22,0.38],"frame":[800,480,160,220],"lonMin":105,"lonMax":122,"latMin":3,"latMax":24,"antimeridianWrap":false,"insetLabel":{"text":"南海诸岛","x":808,"y":705},"insetBox":[796,476,168,236]}
  ],
  "codesFile": "codes.tsv", "codesSha256": "\(MUMapSHA256.hex(synthTsv))",
  "geometry": {"file":"geometry.mump","sha256":"\(MUMapSHA256.hex(synthMump))","bytes":\(synthMump.count),"features":1,"rings":1,"vertices":3,"overlays":1}
}
""".data(using: .utf8)!
let synthCat = """
{
  "schemaVersion": 1,
  "packs": [{
    "id": "cn-admin1", "aliases": ["cn"], "level": "admin1",
    "manifestFile": "cn-admin1/manifest.json", "manifestSha256": "\(MUMapSHA256.hex(synthManifest))",
    "codesFile": "cn-admin1/codes.tsv", "codesSha256": "\(MUMapSHA256.hex(synthTsv))",
    "geometryFile": "cn-admin1/geometry.mump", "geometrySha256": "\(MUMapSHA256.hex(synthMump))",
    "featureCount": 1, "ringCount": 1, "vertexCount": 3, "geometryBytes": \(synthMump.count)
  }]
}
""".data(using: .utf8)!
try! synthMump.write(to: synthPack.appendingPathComponent("geometry.mump"))
try! synthTsv.write(to: synthPack.appendingPathComponent("codes.tsv"))
try! synthManifest.write(to: synthPack.appendingPathComponent("manifest.json"))
try! synthCat.write(to: synthRoot.appendingPathComponent("catalog.json"))
store.configureSearchPaths([synthRoot])
let cnSynthV = MinisUIEngine.validate("root = GeoMap(\"cn\", [\"110000\"], [42], null, \"合成协议验证\", null, null, null, [\"北京市\"], null, \"location\", [[116.4, 39.9, 1], [112.3, 16.8, 0]], [\"北京\", \"西沙\"])")
check(cnSynthV.ok, "synthetic cn-admin1 pack validates GB code, Albers, SCS inset & overlay")
check((store.geometry(for: "cn")?.overlays.count ?? 0) == 1, "synthetic cn-admin1 overlay loaded")
store.resetToDefaultSearchPaths()
try? FileManager.default.removeItem(at: synthRoot)

print("MAP_REGRESSION_PASS checks=\(checks)")
