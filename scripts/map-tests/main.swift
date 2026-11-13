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
check(!MinisUIEngine.validate("root = GeoMap(\"cn\", [], [])").ok,"unshipped Geo China rejected")
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
        check(m.legendFrames.count==bins.count,"every interval has its own box")
        for (i,r) in m.legendFrames.enumerated() {
            check(r.maxX<=width-10+0.1 && r.minX>=10,"interval within horizontal bounds")
            check(r.maxY<m.missingY && r.minY>=m.legendY,"interval before missing row")
            check(Double(MUMapTypography.measure(bins.label(i),width:r.width-8,size:11).height)<=r.height-12,"full interval glyph height reserved")
        }
        check(m.subtitleHeight>20 && m.sourceHeight>10,"long explanation wraps without ellipsis")
        check(m.plotY>=m.unitY+m.unitHeight,"unit does not cover map")
        check(MinisUIEngine.estimatedHeight(c,width:width)==m.height,"long-text estimated height equals native layout contract")
    }
}
print("MAP_REGRESSION_PASS checks=\(checks)")
