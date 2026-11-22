# show_ui 通用地图引擎与数据包（MapPack v1）

本文档说明 `MinisUIMapPack.swift`、`MinisUIMapCore.swift`、`MinisUIMapView.swift`
以及 `src/ios/Resources/MapPacks/` 的协议、构建方式与测试验证边界。

## 1. 组件语法与兼容

```text
BlockMap(region, codes, values, scale?, title?, subtitle?, source?, unit?, highlight?, bins?)
GeoMap(region, codes, values, scale?, title?, subtitle?, source?, unit?, highlight?, bins?, mode?, points?, pointLabels?)
```

- `BlockMap` 保持 `"us"`（51 区）与 `"cn"`（34 省级方块拓扑）不变。
- `GeoMap` 仍保持原有 13 个位置参数签名，`region` 由硬编码 `"us"` 扩充为通过 `MUMapPackStore` 查询已加载数据包。
- 仅在 `MinisUI` 自定义组件体系内扩展，不声称属于 OpenUI 官方地图标准。

## 2. 首期内置数据包（共 14 个，约 817 KB）

| Pack ID | 别名 | 区域数 | 编码体系 | 来源与许可 | 投影/插图 |
|---|---|---:|---|---|---|
| `us-admin1` | `us`, `usa`, `us-states` | 51 | USPS / `US-XX` | Natural Earth 50m (PD) | Albers + AK/HI |
| `world-admin0` | `world`, `global` | 241 | ISO α-2 / NE 特例码 | Natural Earth 50m (PD) | Equal Earth |
| `europe-admin0` | `eu`, `europe` | 47 | ISO α-2 | Natural Earth 50m (PD) | LAEA (10°E, 52°N) |
| `de-admin1` | `de`, `germany` | 16 | `DE-XX` / 短码 | Natural Earth 10m (PD) | Albers |
| `gb-admin1` | `gb`, `uk` | 4 | `GB-ENG/SCT/WLS/NIR` | geoBoundaries (CC BY 4.0) | Albers |
| `fr-admin1` | `fr`, `france` | 13 | `FR-XX` (含 `FR-20R`) | geoBoundaries / IGN-F (Etalab 2.0) | Albers |
| `it-admin1` | `it`, `italy` | 20 | `IT-21`..`IT-88` | geoBoundaries / ISTAT (CC BY 3.0) | Albers |
| `es-admin1` | `es`, `spain` | 19 | `ES-XX` | geoBoundaries / IGN-ES (CC BY 4.0) | Albers + Canarias |
| `jp-admin1` | `jp`, `japan` | 47 | `JP-01`..`JP-47` | Natural Earth 10m (PD) | Albers + Okinawa |
| `ca-admin1` | `ca`, `canada` | 13 | `CA-XX` / 短码 | Natural Earth 10m (PD) | Albers |
| `au-admin1` | `au`, `australia` | 8 | `AU-XX` / 短码 | Natural Earth 10m (PD) | Albers |
| `br-admin1` | `br`, `brazil` | 27 | `BR-XX` / 短码 | Natural Earth 10m (PD) | Albers |
| `kr-admin1` | `kr`, `korea` | 17 | `KR-11`..`KR-49` | Natural Earth 10m (PD) | Albers |
| `us-county` | `us-counties`, `us-admin2` | 3,143 | 5 位 Census 2020 FIPS | US Census 2020 (PD) | Albers + AK/HI + 州界叠加 |

### 未默认内置项
- `GeoMap("cn")`：公开仓库与默认 App 包不捆绑未经审图或无再分发授权的中国地理边界；未安装合规包时明确拒绝并引导使用 `BlockMap("cn", ...)`。引擎层已支持中国 Albers、南海诸岛插图、`overlays` 线层及 34 省 GB 编码协议。
- 原生交互（点选高亮、双指缩放、指标切换）未在首期加入，保留与 `CollectionViewMessageListV3` 固定测高模型的兼容性。

## 3. 协议与性能安全护栏

1. 元数据（`catalog.json` + `manifest.json` + `codes.tsv`）与几何二进制（`geometry.mump`）分离；校验与 `MUMapMetrics` 测高零几何读取。
2. `.mump` 使用小端定点数 `Int16`（`coordScale` 10/20）、强制文件头校验、SHA-256 校验、路径字符白名单及上限（单包 ≤ 4 MB、要素 ≤ 10,000、顶点 ≤ 200,000）。
3. `MUMapPackStore` 几何缓存为严格有界 LRU（最多 4 个包 且 累计 ≤ 4 MB）。
4. 复现全部数据包：`python3 scripts/generate_map_packs.py`。
5. 回归入口：`python3 scripts/map_regression.py`（Linux 纯 Foundation/Swift 6.2）与 `python3 scripts/map_render_regression.py`（macOS 模拟器真实位图与性能预算）。

## 4. 图例与暗色模式可读性（mod-map-legend-compact-20261114）

- 连续/离散分箱图例采用单行 `6pt` 色带与不重叠共享边界刻度（`9.5pt`），并在「无数据」行右侧给出首末档范围摘要；副标题采用 `11pt` 自动换行。
- 暗色承载表面（`luminance < 0.179`）下，画布主文字与刻度采用高对比近白 `#F3F4F6`、说明与次要文字采用 `#B8C0CC`，保留原有分箱填充色与色阶顺序不变。

## 5. highlight 图例：单行优先、统一强调色（mod-showui-map-chips-20261121）

`highlight` 的每个 region code 渲染为一个 **由内容决定宽度** 的 chip，不再是横贯卡片的色条。几何常量集中在 `MUMapChipStyle`（`MinisUIMapCore.swift`），测高公式与 `Canvas` 绘制读取同一份 `m.highlightChips`，因此占位与绘制不会脱节。

| 项目 | 值 |
|---|---|
| 字号 | `10pt`（semibold，与 canvas 绘制字体同源测量） |
| 水平 / 垂直内边距 | `5pt` / `3pt`（chip 高度 = 行高 + 6 ≈ 18pt） |
| 圆角 | `4pt` |
| chip 间距 | 同一行 `6pt`，换行 `4pt` |
| 距地图底边 | `8pt`（`footerY = plotY + plotHeight + 8`） |
| chip 块到来源/说明 | `6pt`（`contentY`） |
| 最大宽度 | 卡片可用宽度（`width − 20`），超长尾部省略号截断，不换行、不缩字 |
| 上限 | 5 个 code；多余的按顺序丢弃，不报错 |

- 布局是**单行优先**的流式排布：放得下就只占一行，放不下才按 4pt 行距换行。整行左对齐在 `x = 10`。
- **地图取景**：GeoMap 的绘图矩形按 pack 的 *内容边界*（所有 feature 的 boundingBox 并集）而不是清单里的画布尺寸来计算和缩放，playground 画布四周的空白海域不会再被算进去——世界地图因此放大约 1.2–1.3 倍并铺满卡片宽度；点/标签走同一个仿射变换，不会漂移。纯 canvas 尺寸仅在 pack 尚未解码时兜底。
- 宽度公式：`chipWidth = ceil(textWidth) + 2 × 5pt`（多留 1pt 抵消 NSString/`Text` 两套测量取整差）；卡片 320 → 430pt 时 chip 宽度不变（除非触到上限）。
- 颜色沿用回调前的规则：所有标注与地图轮廓统一使用主题强调色 `theme.accent`（按承载表面 `readable` 适配），chip 文字用 `theme.accent.ink`，对比度恒定 ≥ 4.5:1。不逐项分色。
- 文字由 `label + "  " + 数值 + 单位` 组成；数值沿用 `%.4g`，无数据时显示「无数据」，单位为空时不追加空格。
- `bins` / `cutout` / `mode` / `points` 行为不变。
- 回归：`scripts/map-tests/main.swift` 覆盖宽度随文本、320→430 不变、单行优先、6pt/4pt 间距、5 个合法且两行、第 6 个静默丢弃、超宽截断、无 highlight 不留空、`estimatedHeight` 精确一致，以及强调色可见性与文字 ≥4.5:1。
