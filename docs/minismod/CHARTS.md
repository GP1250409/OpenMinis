# show_ui 图表：实现说明与风格来源（维护用）

适用代码：`src/ios/Views/Chat/AIChatView/MinisUI/` 下的
`MinisUICore.swift`（纯逻辑）、`MinisUIView.swift`（渲染）、
`AIChatViewModel+GenUI.swift`（模型提示词）。
测试：`scripts/chart_layout_regression.py` + `scripts/chart-layout-tests/main.swift`。

本文区分三种来源，代码注释与提交信息也沿用这三个词：

| 标记 | 含义 |
| --- | --- |
| **官方** | 出自《The Economist: visual styleguide》v1.2（2017-05-04）原件，页码可查 |
| **取样** | 从 economist.com 2024–2026 成品图上取色/取布局，**不是官方规范** |
| **自行适配** | 规范和成品图都没有规定，为 iOS 屏幕、深色模式、可测性做出的决定 |

> 官方 PDF 已从官方站点下架，本仓库不含 PDF；取色与页码依据见
> `shared/minismod` 之外的资料目录 `ECONOMIST-CHART-STYLE/`（个人留存，勿再分发）。

## 1. 三种配色档（设置 → 外观 → 交互卡片 → 图表配色）

| 档位 | 面板 | 系列色 | 来源 |
| --- | --- | --- | --- |
| 系统 | 淡灰圆角面板 `primary.opacity(0.04)` | SwiftUI 语义色 蓝/橙/绿/红/紫/teal | 自行适配（沿用 Swift Charts 默认观感） |
| 经济学人（近年） | 米色 `#F1EFEA` / 深色 `#262624` | 主红 `#E62923`、暖灰 `#B6B6A9`、浅红 `#F8A290`、深灰、深红 `#BE191F`、蓝 `#3651A3` | **取样**（不是官方色板） |
| 经济学人（2017 规范） | 蓝灰 `#E9EDF0` / 深色 `#1F262B` | 蓝 `#006BA2`、青 `#3EBCD2`、金 `#EBB434`、暗红 `#A81829`(替身)、绿 `#379A8B`、紫 `#9A607F` | 前五色**官方**（网页色板 p.12 + 折线色序 p.15），`#A81829` 为**替身** |

`#A81829` 是规范里“暗红/勃艮第”在网页色板中无对应值时的替身；印刷值为
CMYK(0,75,35,45)，屏幕近似约 `#942A44`。**该色值仍待用户决定，本次不动**，
也不要对外宣称它是官方十六进制。

## 2. 高亮（highlight）语义

- 解析在 `MUChartEmphasis.roles(series:highlight:)`，**按数据顺序**排名，与
  `highlight` 数组顺序无关；`series` 里第几个不影响是否被强调。
- 强调色阶（每档 3 个，见 `MUChartStyle.accent*`）：
  - 2017：蓝 `#006BA2` → 深青 `#005F73` → 金 `#EBB434`（都是官方色序里的色）
  - 近年：主红 → 深红 `#BE191F` → 蓝 `#3651A3`（取样）
  - 系统：`.blue` → `.teal` → `.indigo`（自行适配，跟随深浅色）
- 其余系列转灰（2017 用 `#758D99`，近年/系统用暖灰/语义灰）。
- 超过 3 个高亮时，第 4 个起**保留自身色板色**，不会变灰——强调不能反过来把数据藏起来。
- 单系列 `BarChart`（2017 档）沿用官方“1 trace with highlight”：底色蓝、被强调项青
  （p.13）。近年档为红 + 灰，系统档为蓝 + 橙。
- 图例、线、柱、线末标签全部取自同一个 `color(_:)`，不会各说各话。
- 已知取舍：3 个以上同时高亮时，第 4 个回到色板色，读者可能误以为它没被强调；
  官方规范本来也只建议高亮 1–2 项。

## 3. 线末标签与右侧纵轴

- 图区固定 180pt 高（高度事务不变），宽度由 `GeometryReader` 读取真实卡片宽度。
- `MUChartLabelMetrics.gutter(...)` 取**最宽标签**：调用方给了实测宽度就用实测
  （否则回落到 CJK 1em / 数字 0.55em 的估算），gutter = 标签盒 + 3pt 间隔 + 10pt 间距；
  上限为卡片宽度的 42%（至少 56pt）。
- gutter 作为 `chartPlotStyle` 的**绘图区内**右侧留白，纵轴数字在绘图区之外，
  两者物理隔离，不再依赖“22pt 够不够”的猜测。
- 名字太长时按 10 → 9 → 8pt 缩字号，仍放不下才截断加 `…`（每档都保留至少 1 个字符）。
- ~~文字宽度是估算（系统字体真实 advance 拿不到），6pt 安全间距就是留给估算误差的。~~
  **20261113 起改为实测 + 物理摆放**：`widths:`/`measure:` 传入 UIView 实测字宽
  （`MUStyle.textWidth`），标签不再用 mark annotation，而是按
  `ChartProxy.plotAreaFrame` 与 `proxy.position(forY:)` 画在绘图区之内、
  右缘钉在 `maxX - 8`，间距 10pt。详见 §8.2。估算表只作为无 UIKit 环境的后备。

## 4. 末值相近时的防碰撞

- `MUChartEndLabels.layout(values:domain:plotHeight:minGap:edgeInset:)`：
  1. 按末值降序（同值按数据顺序）得到自然位置；
  2. 自上而下保证 ≥ `fontSize + 3`pt 的间距；
  3. 越过底边就整体上推并重新保证间距；
  4. 夹在 `[edgeInset, height - edgeInset]` 内；
  5. 输出每个系列相对自然位置的 `dy`，视图只用 `.offset(y:)`。
- 顺序永不颠倒：标签的上下次序始终与数值次序一致，不会出现“线交叉”。
- 1–6 个系列、相同末值、负值、90 种稠密组合都在测试里覆盖（`CHART_LAYOUT_PASS`）。
- 明确不做：连接线/引导线（避免再引入一套几何），也不靠删灰标签“看起来不挤”。

## 5. y 轴

- 显式 domain（`MUChartAxis.domain` / `stackedDomain`）：含零、6% 余量、向外取整到
  1/2/2.5/5/10×10ⁿ 的步长。显式 domain 是像素定位和换档不跳动的前提。
- 堆叠柱按**每列合计**定 domain；负值按正负分堆合计。
- 官方规范要求“柱状图不要截断刻度”，这里柱图强制含零，符合。

## 6. 模型提示词（`MinisUI Prompt`）

新增的“Charts”段要求：

- 普通数据图表在组件能力覆盖时**优先 show_ui**（包括先查资料再画），
  只有用户明确要导出图片/海报/信息图，或能力不覆盖时才另走一路，并说明
  静态图不跟随 App 设置；
- 不编造数据或来源；估计值必须在 `subtitle`/`source` 标注“估算/示意数据”；
- 时间升序、写清单位与口径、一图一信息、尽量 ≤4 系列、其余用 `highlight` 压灰；
- 预测点只能用系列名或 `subtitle` 说明（图表没有虚线/阴影能力）。

同时修正了两处与实现不符的说明：`BarChart` 的“其他变灰”改为按档位描述真实颜色；
`MultiChart` 明确 1–6 系列、强调色阶、线末自动标名，以及**没有**的能力。

## 7. 仍未实现的官方能力（不要对外承诺）

- 双坐标轴（官方 p.21 有规则：左轴青/深青绿、右轴暗红/灰紫）
- 散点图、气泡图（含 0.3pt 描边、50% 不透明规则）
- 饼图/环形图、温度计图、断轴符号
- 高亮标签引线（0.5pt 线 + 箭头 21）、灰色/淡红高亮面板
- 预测区间、虚线趋势线、指数基准红线
- Econ Sans 字体、官方印刷尺寸（160/332/504pt）与 0.5pt 刻度精度
- 地图配色已在 Phase 2 单独实现（见 §9）；世界/中国轮廓、河流与争议边界尚未实现
## 8. 变更说明（mod-chart-fold-polish-20261113，基于 8ec8992）

### 8.1 [T-chart-card-flat] 图表卡不再套第二层底

真机截图（build 8ec8992）里，图表外面是 `MUCard` 的浅灰底 + 0.6pt 描边，
里面又是 `MUMultiChartBody` 自己的蓝灰/米底，看起来像"盒子里再套一个盒子"。

- 判定是一个**纯函数分类**（`MUCardPlane.isChartOnly`，在 `MinisUICore.swift`，
  Linux 可编译、有测试）：只有顶层 `Card` 的**整棵子树**都是图表输出时才平面化。
  允许的叶子：`Title` / `Text` / `Badge` / `Divider`；容器：`Card` / `Stack` / `Row`；
  必须至少有一个 `BarChart` / `LineChart` / `MultiChart`。
- 任何交互或数值组件（`Slider` / `Stepper` / `Segmented` / `Toggle` / `Choice` /
  `Button`）、`Table`、`Metric`、`Callout`、以及**未知组件**都保持原样——
  计算器卡、选择题卡、表单卡仍有原来的底色与描边，不做全局去卡片。
- 平面化只去掉底色和描边：`padding(14)` 保留，`MinisUIEngine.estimatedHeight`
  的高度模型不变（高度事务、真实测高都不受影响）。
- 图表自己的 `panelFill`（system 4% / Economist 2017 米色 / recent 浅灰）**保留**。

### 8.2 [T-chart-label-physical] 线末标签与右轴数值的间距改成物理保证

8ec8992 的真机图里"中国"仍然贴着右轴刻度"5"。根因有两层，都不是"留白调小"：

1. gutter 宽度是**估算**（按 Unicode 类别 `units * fontSize + 1`），细体→粗体的
   实际字宽差异会把 6pt 的名义间距吃掉；
2. 标签画在 **mark annotation** 上——`annotation(position: .trailing)` 由 Swift
   Charts 摆放，允许**溢出绘图区**，于是它从"预留的 gutter"越到了轴线那一列。

修法：

- `MUChartLabelMetrics.gutter(..., widths:measure:)` 接受**实测字宽**：视图用
  `MUStyle.textWidth`（UIKit `NSString.size(withAttributes:)`，与
  `.system(size:weight:)` 同一字体）逐系列测量（强调系列粗体、压灰系列常规），
  再取最大值作为 **labelWidth**；`width = labelWidth + spacing + gap`，
  `gap` 默认 10pt。
- 标签不再用 annotation：`ChartProxy.plotAreaFrame` 给出**真实绘图区矩形**
  （轴数值在它外面），`proxy.position(forY:)` 给出**真实 mark 的 y**，
  `MUChartEndLabels.layout(..., baseY:)` 在真实 y 上做避让；
  每个标签的盒子固定为 `labelWidth`（`.frame(width:alignment: .leading)`）并
  右缘钉在 `plotAreaFrame.maxX - 8`，因此**版面保证**标签不会进入轴向列，
  与文字实际宽度的估算误差无关。`chartPlotStyle` 仍预留 gutter，线不会钻到标签下。
- 长中文、1–6 系列、负值与相同末值、浅/深色都在回归里；颜色映射
  （`MUChartEmphasis` 数据序强调色）与暗红 `#A81829` 的待定状态**未改**。

### 8.3 [T-fold-lead-gap] 思考与"已执行 N 个工具"之间的单行前言

真机折叠截图（同一包）顺序是：`深度思考 3K`（独立）→ 前言正文 →
`已执行 14 个工具 · 11m 2s · 3 个失败` → 最终正文。也就是说思考没有并进工具组。

原因是旧契约 `[T-fold-tool-notes]` 里"第一次调用前的单行备注会把上面的思考切出去"
（`reset()`）。新契约：

- 单行备注（`isSingleLine`，按**换行**而不是按屏幕折行判断）出现在
  "开场思考"和"第一次调用"之间时，**保留自己那一行**，但不再切掉思考：
  它记为组内的 **gap**（`Group.visibleGaps`），思考照旧并进这一组。
- 折叠行的位置在 gap **之后**（`FoldedRun.anchorBlockId`），所以阅读顺序是
  `前言 → 已执行 N 个工具 → 最终正文`，思考的内容仍在展开里，没有隐藏、没有换序。
- 仍然保持的边界：最终正文与 `user_ask` / 渲染成功的 `show_ui` 卡是 **barrier**
  （卡前的过程照样收成一行，卡本身永远可见）；**多行**正文不是备注，仍旧把过程切成两段；
  执行中的工具（streaming/running/等待确认）不提前折；"结束但没回复"仍按
  `[T-fold-stopped-tools]` 折；空白思考（`isBlankThinking`）仍旧不占行。
- 前言之后调用从未到来（被卡或 barrier 截断）时保持旧行为：不折。

文档里 §1–§7 是对 Economist 图表风格与实现边界的既有说明，本节只记录本次三项改动。

## 9. 地图（Phase 2，mod-chart-map-20261113）

### 9.1 语法与能力边界

参数均按顺序传入；可选参数用 `null` 跳过，不支持自定义颜色或客户端联网。

```text
BlockMap(region, codes, values, scale?, title?, subtitle?, source?, unit?, highlight?, bins?)
GeoMap(region, codes, values, scale?, title?, subtitle?, source?, unit?, highlight?, bins?, mode?, points?, pointLabels?)
```

- `BlockMap.region`: `"us"` / `"cn"`；`GeoMap.region` **目前仅 `"us"`**，其他值校验拒绝，不能伪装成世界或中国轮廓。
- `codes:string[]`、`values:number[]` 等长。缺失地区不填；未填是无数据灰块，**不是零**。重复代码（包括同一地区的不同别名）、未知代码均报错并列出未知值及合法代码表。
- 美国用 USPS 两字母，接受 `US-CA` 等别名，50州 + DC；中国含34省级行政区，台湾、香港、澳门按中国省级行政区处理。
- 中国接受京/津/冀等简称、中文全称、两字母拼写代码和 GB 省级数字码（`11`、`CN-11`、`110000`）。拼写代码：`BJ TJ HE SX NM LN JL HL SH JS ZJ AH FJ JX SD HA HB HN GD GX HI CQ SC GZ YN XZ SN GS QH NX XJ TW HK MO`。其中 `SX=山西`、`SN=陕西`、`HA=河南`、`HN=湖南`、`HI=海南`；以校验返回表为准。
- `scale`: `blue/red/green/yellow/purple/stone/yellowBlue/greenPurple/diverging/divergingStoneGreen`。默认系统/2017蓝阶、近年红阶。后两者为蓝→红、石灰→青绿的10档端点组合再插值，**自行适配**，不宣称十个 hex 均为 PDF 官方值。
- `bins:number[]` 是**内部切点**，最多9个，严格升序；区间 `[a,b)`，等于切点进入右箱；首尾箱开放。未指定默认6等宽箱；常数/空数据也生成有效分箱。发散默认域以0对称；显式发散切点必须奇数个、含0且零对称。
- `highlight:string[]` 最多3个区域，框内直接标注区域/数值，不另加类别图例。定量的分段色阶键仍保留，说明数值分箱（不是类别图例）。高亮框使用绘图区外的专用行，采用官方单行12pt框高、7pt水平内边距，步距14pt；至多3个单行框。多行12/23/34pt整框的排版暂不提供，长注释放外部Text。
- title/subtitle/source 固定单行，超长按原生实测截断，完整内容保留在复制、搜索、导出与无障碍文本。建议详细注释放外部 `Text`，不要依赖动态图内换行。
- `GeoMap.mode`: `location`（默认，海/陆/白州界）或 `cutout`（无海、白地、主题强调色顶线；2017为红）。有值即 choropleth；无值可传 `[], []`，用 highlight 做 focus。
- `points:number[][]`: `[经度,纬度,是否首都0或1]`，最多30点；`pointLabels:string[]` 可省略，否则长度一致。用相同 Albers 参数映射到本土或 AK/HI 插图。城市3pt圆/首都3.5pt方，0.5pt白描边；不含道路/河流/争议边界/导航。

可直接交给模型的程序（都是**示意数据**，不冒充官方统计）：

```text
root = Card([map])
map = BlockMap("cn", ["京", "沪", "粤", "川", "台", "港", "澳"], [12, 18, 24, 9, 15, 11, 6], "blue", "区域指标对比", "示意数据，非官方统计", "手工示例", "点", ["粤", "台"], [5, 10, 15, 20, 25])
```

```text
root = Card([map])
map = GeoMap("us", ["CA", "NY", "TX", "AK", "HI"], [10, 20, 30, 12, 18], "green", "美国区域指标", "示意数据，非官方统计", "手工示例", "点", ["CA"], null, "location", [[-77.0365, 38.8977, 1], [-122.4, 37.8, 0]], ["Washington", "San Francisco"])
```

### 9.2 风格来源与三档完整取色

**官方规则**来自《Economist maps styleguide》2017-05-05：p3线/符号、p4定位图、p5顺序色阶、p6发散示例、p8直接高亮、p9白底顶线/US BLOCK MAP、p12投影。**取样**指从保留 PDF 的屏幕渲染取 hex（并非 PDF 官方发布的 web hex）。**自行适配**包括手机字号、固定高度、CN网格、插值、近年/系统地图配色以及10档发散组合；不把图表官方蓝 `#006BA2` 冒充地图蓝 `#2C6BA6`。

| 元素 | 系统（自行适配） | 近年（取样/适配） | 2017（地图PDF取样） |
|---|---|---|---|
| 面板 | `#FFFFFF` | `#F1EFEA` | `#FFFFFF` |
| 海 | `#EAF3FC` | `#E4EDF0` | `#EBF8FE` |
| 陆 | `#DCE5D8` | `#D5D8CB` | `#D6D9C9` |
| 陆地文字 | `#53654F` | `#6D705F` | `#7A7D69` |
| 海字/河流色（河流暂不绘制） | `#3989AB` | `#5A9AA6` | `#54C6D2` |
| 国/州界 | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` |
| 可选海岸（本期不单独绘制） | `#9AAC9C` | `#9AA48E` | `#A5B29E` |
| 无数据 | `#E5E7EB` | `#B6B6A9` | `#E4EAED` |
| 正文 | `#1C1C1E` | `#262624` | `#262624` |
| 次要文字 | `#636366` | `#6F7168` | `#66808E` |
| 顶线/高亮描边 | `#007AFF` | `#E62923` | `#E3120B` |
| focus | `#B9D3EB` | `#C8CBB8` | `#E2E4D8` |

2017档完整顺序色阶是 p5 的 RED/BLUE/PURPLE/YELLOW/GREEN/STONE/YELLOW-BLUE/GREEN-PURPLE 六级屏幕取色，见 `MUMapScale.official`。系统与近年单色阶由各自端点与面板插值，三档多色/发散阶保留这套可比的地图色序。文字按 WCAG 相对亮度选择黑/白，所有色阶检查至少4.5:1对比；地图固定浅色印刷底（近年米色），不另猜一套暗色地图。

### 9.3 布局、高度、离线数据与标签

- 美国布局：p9 **目视逐格抄录**的8行×11列，含 DC；AK在左上、HI左下。测试核对覆盖、无重叠、WI/VT/NH/NY/MA/DC等关键坐标。
- 中国布局：8行×8列、34区**自行设计**的方块拓扑。只表达近似相邻关系，不保证每一对邻接/距离/面积；**不是标准地图或领土边界图**，不能当作标准地图发布。图下注明含台港澳。未引入中国边界数据，不存在遗漏南海轮廓却假称完整中国 GeoMap 的情形。
- 网格高度：`cell=(width-20-(columns-1)*2)/columns`；`plotHeight=rows*cell+(rows-1)*2`。`MUMapMetrics` 同时被 `Layout.sizeThatFits` 和 `MinisUIEngine.estimatedHeight` 使用，避免靠 `onAppear`/宽度Preference再次测高。所有标题/图例/单位/来源/高亮行均固定可计算。Canvas不随动态字体改变尺寸，完整文本通过无障碍导出提供。
- GeoMap：Natural Earth 1:50m 美国51区；球面 USA Contiguous Albers（29.5°/45.5°，中经线−96°、原点23°）；AK/HI各自 Albers插图。离线RDP简化、0.1画布坐标量化、保留环/孔洞、亚像素离岸小点可省略；DC保留。`1000×640` 画布等比 aspect-fit 到视图。数据约45KB/3,707点，无网络下载。
- 点标签先原生测宽，纯Foundation避让器尝试右上/右下/左上/左下并夹到图内，避开已有标签；失败不强塞重叠文字。引线只用水平/垂直两段0.5pt。高亮信息在绘图区外，永不盖城市点或分箱图例。
- 复现：`python3 scripts/generate_map_data.py`；来源固定 commit 与 SHA256、许可详见仓库 `THIRD_PARTY_LICENSES.md`。未来世界/中国 GeoMap 要先审查许可、标准地图完整性/审图合规、台湾和南海诸岛处理，不能直接拼一张网络轮廓上线。

### 9.4 回归与 CI

```sh
python3 scripts/map_regression.py --swiftc /path/to/swiftc
python3 scripts/map_regression.py --render-simulator  # macOS，真实编译SwiftUI并输出PNG
```

Linux编译生产 `MinisUICore.swift + MinisUIMapCore.swift + MinisUIMapData.swift`，运行 `map-tests/main.swift`；不是仅字符串审计。`--source-only` 明确不会输出 `MAP_REGRESSION_PASS`。现有图表测试增加两个纯逻辑源文件依赖，不改图表断言。
CI的“Map regression tests”还编译生产 `MinisUIMapView.swift`，启动独立模拟器fixture，检查原生 `sizeThatFits` 等于共享估高，生成系统/近年/2017 × US/CN/Geo/location-cutout 共12张原生PNG；`map-regression.log`、编译/启动日志及PNG均归档到 `mod-validation-logs`。仅在真实运行后才报告 PASS；Linux `-frontend -parse` 不等于SwiftUI编译。
