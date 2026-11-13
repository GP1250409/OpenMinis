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
