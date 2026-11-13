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
| 经济学人（2017 规范） | **白色 `#FFFFFF`** / 深色 `#161B1F` | 蓝 `#006BA2`、青 `#3EBCD2`、金 `#EBB434`、暗红 `#A81829`(适配)、绿 `#379A8B`、紫 `#9A607F` | 白底/横红条/红顶线据官方 p.3 网页新版；主色据 p.12；暗红选用官方红色阶最深级但其系列位置属于自行适配 |

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

## 3. 线末标签与右侧纵轴（Phase 1 当前实现）

- 图区固定 180pt；横轴独占 22pt，顶部轴数字留 16pt；字号和隐藏图例同步估高。
- 隐藏 Swift Charts 的原生 x/y 轴，自绘横向网格、下刻度、右轴；Chart 仅负责 marks。
- `MUChartColumns.layout(width:labelWidth:axisWidth:)` 是唯一横向几何：
  `plotWidth = width − 2×10 − labelWidth − axisWidth − (labelWidth>0 ? 4 : 0) − 6`。
  曲线 → ≥4pt → 实测最宽线末标签 → ≥6pt → 实测最宽轴数字 → 10pt。
  左侧同一个 `innerInset=10`，柱图和单系列无标签时仍留 6pt 的轴前空隙。
- 不再使用 `chartPlotStyle` 的 trailing padding，也没有 `max(lastX+3,...)`。
  实际 plot 高度/minY 来自 `proxy.plotAreaFrame`，y 使用同一显式 domain 与真实 mark 坐标。
- 字宽使用 UIKit 实测；长名称在窄屏按 12→11→10pt 缩小，必要时截断，标签盒裁剪。
  截断上限为面板宽度 36%（至少56pt），是手机适配，不是官方字体规则。
- §8.2 是旧版本的历史修复记录，其“绘图区内预留必定有效”的假设已被真机推翻；
  本次把两列真正移出 Chart，避免再把纵轴外侧空白误当线末空间。

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
- 地图配色已在 Phase 2 单独实现（见 §10）；世界/中国轮廓、河流与争议边界尚未实现
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

## 9. Phase 1 排版规范化（mod-chart-phase1-20261113）

本节是 §8 之后的当前增量，**不代表完整实现官方全部规范**。

- `MUChartTheme.current(for: String) -> MUChartTheme`：设置空字符串/`economist`/
  `economist2017` 返回系统/近年/2017。`theme.fonts` 显式提供五级字号值；面板、网格、零线、红标、红顶线、主副标题、
  来源、轴、系列色、强调色、灰化色、九组完整六级色阶、图例标记都由主题提供；
  地图可复用该接口，但本分支不新增地图组件。
- **官方**：2017 网页新版白底、左上横红条 `#E3120B` 和贯穿内容宽度的0.5pt红顶线；
  网格 `#B7C6CF`、副标题 `#3F5661`、灰化 `#758D99` 与 p.12 九组六级色阶。
  系列顺序蓝→青→黄→暗红 `#A81829`→绿→紫维持用户授权值。
- **取样**：近年米底 `#F1EFEA`、红 `#E62923`、暖灰；其辅助色和布局来自近年样图，
  不称为官方新规范；近年的插值红色阶是自行适配，而非官方色阶。
- **自行适配**：SF 字体代替 Econ Sans；16pt bold主标题、13pt副标题、12pt图例、
  11pt等宽数字刻度、10.5pt来源（75%黑/深色反转）；2017深底 `#161B1F`，近年 `#262624`。
  单系列、系统档同走一套渲染骨架，系统档不画红标。
- 纵轴数字右对齐，文字框下缘在网格上方1.5pt；跨零时0刻度粗体，折线也画零线：
  2017红1pt、近年黑1.5pt、系统细灰0.5pt。横轴底线/下短刻度0.5pt、刻度长5pt，无竖网格。
- 线末标签显示时自动隐藏重复图例；柱图图例为方块，折线图例接口为短横线。
  柱图图例每行两项，长名称截断；绘图区180pt不变；外置轴的高度已同步到估高函数。
  单系列的`unit`显示在既有16pt顶部预留区，不额外增高；系统档保留柱形圆角与单线数据点。
- 提示词：单位/统计口径写进subtitle；title写结论而非单位；可消歧时年份缩为两位。

### 验证边界

- `chart_layout_regression.py` 编译生产纯Foundation核心与测试；新增280/330/400pt、
  1–6系列、长中文、负值、相同末值与单系列断言，检查数下限不降低。
- `chart_render_regression.py` 在CI模拟器中编译**同一份生产图表代码**（包括单系列），
  UIHostingController + drawHierarchy 以3x生成180个PNG；覆盖三主题、深浅色、三宽度、
  折线1–6系列/单系列柱线/分组柱/堆叠柱。扫描实际位图，要求左右内边距差≤1pt、
  标签与右轴实际着色像素间隔≥6pt，并验证180pt真实plot及估高误差≤5pt。
  输出 `CHART_RENDER_PASS` 才算真实渲染通过；`--source-only`或Linux parse不算。
- PNG、逐样本像素测量和编译日志归档到 `mod-validation-logs` 的 `build/chart-render/`。
  只有跑完的CI结果才能作为像素证据；真机截图仍建议交付后人工验收。
- 保持高度事务和思考折叠代码不变；原63项UIKit高度回归及≥170项折叠检查仍是门槛。

资料依据：个人留存《The Economist: visual styleguide》v1.2，p.3/p.12，
官方原发布入口 https://www.economist.com/brand-and-marketing （旧PDF已下架）；
近年取样入口 https://www.economist.com/graphic-detail 。网页界面设计系统不是图表规范。
## 10. 地图（Phase 2，mod-chart-map-20261113）

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
