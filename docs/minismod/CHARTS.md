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
- 地图配色（另见 maps styleguide，未整理进代码）
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
