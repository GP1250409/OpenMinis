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

## 9. Phase 1 排版规范化（mod-chart-phase1-20261113）

本节是 §8 之后的当前增量，**不代表完整实现官方全部规范**。

- `MUChartTheme.current(for: String) -> MUChartTheme`：设置空字符串/`economist`/
  `economist2017` 返回系统/近年/2017。面板、网格、零线、红标、红顶线、主副标题、
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
