# Chat Scroll & `show_ui` Render Performance Handoff (2026-11-26)

Merged from branch `mod-chat-scroll-perf-20261126` (`6a7635b`, verified on CI and real iOS 16 device).

## Upstream Sync Reminder (重要备注)

> **待 OpenMinis 上游源码更新后，请重点对照以下文件与上游实现的差异。**
> 上游开发者大概率也在同步优化聊天页非纯文本（Markdown 表格、图片、`show_ui` 卡片）的滑动性能；合入上游更新时请逐文件 `git diff` 对比双方策略，优先保留/融合更优方案，避免重复缓存或冲突。

### 本次改动涉及的文件清单

1. **地图与 `show_ui` 渲染性能**
   - `src/ios/Views/Chat/AIChatView/MinisUI/MinisUIMapCore.swift`
     - `MUMapRGB` 由十六进制字符串存储改为 `(r, g, b: UInt8)` + 256 项 sRGB 线性亮度查表 `linearLUT`，消除 `readable()` / `mix()` / `contrast()` 中的字符串格式化与 `pow` 运算。
   - `src/ios/Views/Chat/AIChatView/MinisUI/MinisUIMapPack.swift`
     - Darwin 平台通过 `#if canImport(CryptoKit)` 使用硬件 SHA-256（Linux 保留纯 Swift 回退）；
     - 几何 LRU 上限调整为 8 包 / 12MB；
     - `geometry(for:)` 的磁盘读取、SHA-256 校验与解码移出 `NSLock` 临界区，避免锁竞争阻塞主线程。
   - `src/ios/Views/Chat/AIChatView/MinisUI/MinisUIMapView.swift`
     - `drawGeo` 改用 GPU `Canvas` 的 `ctx.concatenate(xform)` 零拷贝变换（替代逐区域 `CGPath.copy(using:)` 拷贝 70k+ 顶点）；
     - 按分档填充色缓存 `borderColorCache`，避免每区域重复算 `readable()`；
     - `MUSurface.rgb` 改用 `MUMapRGB(r:g:b:)` 构造。
   - `src/ios/Views/Chat/AIChatView/MinisUI/MinisUIView.swift`
     - `MinisUITool` 增加 `programTextCache` 和 `renderedRootCache`，减少滚动/布局时的重复 `JSONSerialization` 与程序求值。
2. **Markdown 表格与图片滑动性能**
   - `src/ios/Views/Chat/Markdown/Attachments/Table/TableAttachment.swift`
     - 增加 `cachedPreparedCells` 缓存单元格 `NSAttributedString` 与 `NSDataDetector` 链接检测结果（仅在 `update(alignments:rows:)` 内容变更时失效），避免 Cell 复用重跑正则与富文本构建。
   - `src/ios/Views/Chat/Markdown/Bridge/SelectableMarkdownView+FirstSeed.swift`
   - `src/ios/MinisTests/Standalone/FirstDisplaySeedTests.swift`
     - 对已缓存像素尺寸的 `ImageAttachment` 放开 `firstDisplayHeight`，减少图片文本块的 SwiftUI 双重构建。
3. **CI 回归稳定性**
   - `scripts/card_dark_regression.py`
     - `simctl launch --console-pty` 超时由 `180s` 放宽至 `360s`，避免 `macos-26-arm64` 首次冷启动模拟器偶发超时。

## Real-Device Verification Notes

- **已验证避坑点**：不要在主线程用 `UIGraphicsImageRenderer`（CPU CoreGraphics 软光栅化）同步绘制 70,554 顶点且带虚线描边（`featureStrokeWidth >= 0.5`）的 `world-admin0` 地图，也不要在持有 `MUMapPackStore.lock` 期间做磁盘 I/O 或解码——两者在 iOS 16 真机上都会导致进会话卡顿数秒与回顶卡死。
- `6a7635b`（GPU `Canvas` + `ctx.concatenate(xform)` + 无锁解码 + 表格/图片缓存）已在 iOS 16 真机安装验证通过。
