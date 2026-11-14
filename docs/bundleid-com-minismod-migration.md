# com.minismod 独立候选与迁移边界

基线：01e36e011ceae3215912affc4b9da0af8a5bcc50。此分支仅改运行身份、备份类型兼容声明及身份验收；不改夜间文字、6pt 色带、图表、地图或布局算法。无 project.yml；实际工程为 src/ios/Minis.xcodeproj/project.pbxproj。

## 新运行身份
- 主应用 com.minismod；Widget com.minismod.AgentWidget；File Provider com.minismod.FileProvider；Share com.minismod.ShareExtension。
- 全四目标仅申请 group.com.minismod；File Provider Info.plist 同组；域 com.minismod.files。
- iCloud/ubiquity 容器 iCloud.com.minismod；后台 com.minismod.liveactivity-refresh 与 com.minismod.continued.*；活动通知、日志、缓存及默认调试目标同步改名。
- 备份新写入 UTI com.minismod.minisbak；旧 com.gonepaul.minismod.minisbak 仅作为 imported UTI 与可读文档类型。归档扩展名、格式、加密派生上下文保持不变。

## 有意保留的旧名称
精确逐行白名单：bundleid-legacy-allowlist.json；由 scripts/bundle_identity_check.py 强制检查，新增任何未经审阅的旧名称即失败。
- 活跃 Keychain 服务 provider.<instanceId>、envvar、device、rclone、mcp-oauth 的读写/删除统一改为 com.minismod 前缀；不增加旧服务 fallback，不添加旧 keychain access-group。
- ProviderMigration 中旧迁移完成标记、agent-model-settings、active-provider 与旧 API key 服务读取保留。三家 OAuth legacy 服务及 Gemini 旧邮箱/project ID 仅用于既有旧模式读取。绝不把旧迁移标记改成新名字后误重跑覆盖现有 provider。
- DeviceIdentity 使用 com.minismod.device。新身份不自动继承旧身份。

最新范围：用户自行处理迁移；以下原有计划仅保留为历史记录，不再开发或执行迁移功能，也不作为交付门槛。

## 本轮安全边界
仅源码、GitHub Actions 构建及隔离暂存目录 ad-hoc 签名；不安装、不卸载、不运行新应用、不访问或写入旧 App/Group 数据，不导出秘密、不合并、不删除旧包。签名通过不等于普通开发者签名/provisioning，也不等于 iCloud/APNs 可用。
普通 iOS 下新 Bundle ID 与 Group 不能自动访问旧容器或旧 Keychain；仅复制数据库不能保证 API Key、环境变量、OAuth Token、rclone/MCP 凭据可用。新 iCloud 容器与旧容器隔离，服务端注册/授权状态未验证，不会自动迁移云数据。

## 后续迁移方案（仅计划，必须另行明确授权）
1. 保留旧版及旧包；记录旧 App、旧 App Group、用户 rootfs/共享目录、数据库+WAL/SHM、UserDefaults、文件挂载/bookmark、Keychain 凭据类别的清单和版本，不在日志显示秘密值。
2. 首选通过旧版自身已实现的备份功能，人工确认导出范围、是否包含凭据与环境变量，选择加密并保管密码；备份落到用户指定安全位置并计算 hash。本轮不执行这一步，不导出 secrets.json。
3. 在旧应用停写的一致性窗口生成可恢复快照；完整数据库备份/加密归档可恢复验证完成后才考虑新容器导入。不得把单独 DB 文件当作完整备份。
4. 新版独立安装后先保持同步关闭，在新容器以显式导入恢复；核对会话/消息/附件、Provider 配置与秘密是否完整、环境变量、MCP/OAuth、rootfs、mount/bookmark、文件提供器、widget。普通权限无法读取旧 Keychain 时需旧版受支持导出并导入，或用户重新登录/录入，不能承诺跨组原样复制。
5. TrollStore/root 仅可作为后续单独批准的替代路径；必须审计脚本、停写、备份、dry-run 路径与权限，再做原子恢复。不能把本次 ad-hoc 签名当作已获迁移授权。
6. 新旧同机时 minismod:// 与 minis-mcp:// 等既有共享 URL scheme 仍可能路由冲突；本轮不更改其公开协议以免破坏既有链接与 OAuth 配置，验收须用显式 bundle 启动并确认回调目标。文件 .minisbak 也可能有多个打开处理器。
7. 新旧数据独立保留并比对；确认密钥/环境变量可读且业务端到端成功后，用户才可另行决定是否停用旧版。失败则继续使用未动过的旧版，不自动回滚覆盖数据。

## 验证标准
本地只跑源码门槛与适用静态检查，不在手机完整编译 Swift。CI 在同 SHA 运行既有全部 UI/地图/图表/折叠测试，新增四目标源码与未签 IPA 标识检查；收包后独立解析四个 Mach-O 的 XML entitlements，必须与此分支实际 entitlements 文件完全一致，并复验 ZIP CRC、SHA256、全部四 Bundle ID、File Provider Info 与新写入/旧读取 UTI。旧字符串扫描仅允许白名单持久模式/导入别名。
夜间旧基线模拟器 42 checks/42 PNG 通过、FAILURE_REPRODUCED=False，不是用户真机黑字故障的复现或修复确证；新候选也不得声称真机验收完成。
