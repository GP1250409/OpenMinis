# CI-FIX-2 — entry stage 的 6 条真实 UIKit 失败

范围：仅改 `scripts/toolfold-uikit-tests/ToolGroupToggleEntryStage.swift`（夹具）。
生产事务 `Support/ToolGroupOriginalToggle.swift`、`Coordinator+ToolFolding.swift`、
`MessageListLayout.swift` **未改**。结论：6 条失败全部是夹具自造几何/自测量问题，
不是生产事务缺陷（生产 `run(_:in:)` 与 b54 `legacyInstantToolGroupToggle` +
`restoreToolGroupToggleAnchor` 逐行为等价，已用 `git show f827eaa^:…` 比对）。

## 根因 → 证据 → 改法（每条对应一条或多条失败）

1. **anchorY 被写死为 40，而不是行的真实屏幕 Y** → 失败 1（112.0）、失败 3（352.0）。
   生产 `toggleToolGroup` 用 `(attrs.frame.minY - contentOffset.y)` 取真实锚；夹具
   `request()` 硬编码 `anchorY: 40`，而 header 实际停在 472（底部边缘），target
   =1100−40=1060 被 clamp 到 maxOff=988，header 落 112；close 同理落 352。
   改法：`request()` 改用 `headerScreenY()` 的真实锚，断言也对照真实锚 ±0.75pt。

2. **成员行从未被测量** → 失败 2（[80,80,80]），并放大了 1/3/5。
   header 在底部边缘时，插入的成员行在视口外，`reloadData` 只测量可见 cell，
   布局保留 80 估计 → contentSize 用估计值 → clamp 在 988 卡死。
   改法：展开用例把 header 停在视口上部（60pt）+ run 下方加 3 条 220pt 尾行，
   让三个成员行都在视口内被真实 self-size 到 320/300/280。

3. **`EntryRowContentView` 自测量返回非法尺寸** → 加重 2，日志 8 条
   `NSInternalInconsistencyException — {1.7976931348623157e+308, 28}`，
   被 shipping `SelfSizingCell.noff_try_objc` 吞掉，被点行从不真正测量。
   label 宽度自由（trailing 用 ≤）。改法：固定行高行覆写 `systemLayoutSizeFitting`
   返回 (目标宽, 配置高)；label 约束改为 leading/trailing 等值。

4. **"short" 用例根本不短且点击了屏外行** → 失败 4（被点行不在屏）、失败 5（988 vs −62）。
   旧 `rebuildFolded(scrollHeaderVisible:false)` 仍造 1248pt 内容（5×220 填充行），
   视口 500 下 maxOff=748；expand 后 target 被 clamp 到 988；且 offset=−62 时
   header(minY 1100) 在屏外，reconfigure 读不到 cell。
   改法：新增 `rebuildShort()`（group+follow=148pt，展开后也 < 视口−顶部 inset），
   header 在 index 0 屏内；加前置断言 `contentSize <= bounds − adjustedTop` 与
   `max==min`，并断言 `!moved`（clamp 被遵守）。

5. **"missing" 用例只改 items 不同步 dataSource/offset 快照** → 失败 6（600 vs 628）。
   旧代码 `items = fillers` 后直接取 `before=contentOffset`（628），但事务的 apply
   本身会 reload（内容 1100 → maxOff 600）→ 合法 clamp 628→600 被误判为"事务写 offset"。
   改法：先做真实 data-source 替换 + settle（会话切换），再取 `before`，事务跑完
   断言 offset 不变。

6. **夹具结构 apply 未镜像生产 applySnapshot**（历史同类坑）。
   `syncStructure()` 现镜像 `updateCacheForSnapshot(oldIds:newIds:)`（按身份重映射
   高度缓存，防止成员行高度按旧索引残留）+ `suppressContentOffsetAdjustment`（提交期
   offset 补偿抑制，apply 后恢复）+ `UIView.performWithoutAnimation`。

## 本地验证结果（Linux，无 UIKit）

- `swiftc -frontend -parse scripts/toolfold-uikit-tests/ToolGroupToggleEntryStage.swift` → PARSE_OK
- `python3 scripts/toolgroup_accordion_regression.py` → `TOOLGROUP_ACCORDION_PASS math=27 static=284`、`TOOLGROUP_ORIGINAL_TOGGLE_PASS static=48`
- `python3 scripts/toolgroup_accordion_regression.py --layout-self-test` → `LAYOUT_SELF_TEST_PASS`
- `python3 scripts/toolfold_fixture_lint.py --selftest` → `TOOLFOLD_FIXTURE_LINT_SELFTEST_PASS cases=21 failed=0`
- `python3 scripts/statusbar_scroll_regression.py` → PASS（`uikit=unavailable platform=Linux`）
- `python3 scripts/streaming_resume_regression.py` → `STREAMING_RESUME_PASS checks=70`
- `python3 scripts/ci_validation_scope.py` → full mode，`toolfold: run:true`

## 未验证（Darwin-only，需父接 CI）

- `python3 scripts/toolfold_uikit_regression.py`：需要 `xcrun --sdk iphonesimulator`
  真实编译+运行；Linux 无 UIKit，`-frontend -parse` 只证明语法，不证明类型/Darwin 语义。
- 真正的 8 用例运行时断言（checks>=40、entry>=18、PNG=15、failures=0）留待 CI。
