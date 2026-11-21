# Antigravity iOS Native v6.0.0 (Build 100) 重构说明

基于 `Pinevu/agy-ios-native` v5.7.1 (94) 进行全面架构重构，并结合 **OpenMinis** 核心特性与 `agy-web` 新版接口落地 1～4 号增强模块。

## 一、核心问题修复与架构重构
1. **消除 God Object**：将原 1,294 行 `AppState.swift` 拆分为 `AppState.swift`、`AppState+Sessions.swift`、`AppState+Streaming.swift`、`AppState+JobsAndSkills.swift` 四个高内聚模块；新增 `Agy/Core/` 与 `Agy/Intents/` 目录；清理死代码（`RichParaView.swift`、`EditMessageSheet.swift`、`RowHeightStore`）。
2. **修复 P0 数学渲染与内存问题 (`Agy/Views/MathView.swift`)**：
   - 修正 `SwiftMath` 字体名错配（统一加载 `latinmodern-math` 并复用单例 `MTFontManager`）。
   - 用**全局单实例离屏 `KaTeXSnapshotEngine`**（1 个复用 `WKWebView` + 弱代理消息转发 + 32MB `NSCache` + 每批最多 4 并发 `MathRenderScheduler`）替代逐公式创建 `WKWebView`，彻底消除循环引用、大幅降低内存占用并支持深浅色自动重绘。
3. **凭证安全与有界缓存 (`KeychainStore.swift`, `ImageCache.swift`)**：
   - 鉴权令牌从明文 `UserDefaults` 自动静默迁移至 iOS Keychain（`AfterFirstUnlockThisDeviceOnly`）。
   - 统一图片缓存为有界结构（80MB 内存 + 40MB 附件解码 + 60MB LRU 磁盘自动淘汰 + 内存告警自动清理）。
4. **隐私清单与自动瘦身构建**：
   - 新增 `Agy/PrivacyInfo.xcprivacy`；对齐 `AgyWidget` 版本号与设备族；修复 `build-native.yml` 漏监听 `AgyWidget/**` 与 `Shared/**` 的问题。
   - 新增 `scripts/slim-ipa.sh` 并集成进 GitHub Actions 与 Codemagic：自动裁剪 10 套未用数学字体并执行 `strip -x`，将 IPA 体积由 ~5.8 MB 压缩至 ~1.8 MB 级别。
5. **修复模型展示名 Bug**：`AppState.currentModelName` 改为优先读取服务端动态 `modelOptions`。

## 二、参考 OpenMinis 落地的 1～4 号功能增强
- **模块 1 · 会话管理与效率**：服务端双向同步置顶/分组/重命名/未读（`/api/sessions/meta`）、`⚡ 最近活跃` 专区、可折叠置顶区、自定义分组筛选栏、标题/全文双模式检索（`/api/search`）、多选批量移动分组与批量删除（`/api/tasks/batch-delete`）、Markdown/JSON 系统分享导出（`/api/export/<id>`）、跨会话草稿持久化与转移（含 5 秒撤回）。
- **模块 2 · 运行态与阅读体验**：顶栏下方实时悬浮运行条（原生 `Text(startedAt, style: .timer)` 计时 + 最新工具胶囊 + 子代理/并发计数 + 一键停止）、连续工具调用智能折叠（`ToolGroupView`：运行中保留最近 3 步、结束后折叠为汇总胶囊）、原生 GFM 表格渲染、消息栏一键朗读/复制/导出。
- **模块 3 · 语音交互、系统集成与灵动岛/小组件**：
  - 零轮询灵动岛与锁屏实时活动（`Text(startedAt, style: .timer)` + 锁屏隐私模式 + DeepLink 回跳）。
  - 桌面与锁屏小组件套件：`AgyRecentSessionsWidget`、`AgyQuickActionsWidget`、`AgyQuotaWidget`。
  - 原生语音输入（`AVAudioEngine` + `SFSpeechRecognizer` + 32 段实时波形 + 中英文切换）与 TTS 朗读（自动剥离 Markdown）。
  - Siri 快捷指令（`AgyAppIntents.swift`，兼容 iOS 16.2+）、URL Scheme（`antigravity://` / `agy://`）与可选 Face ID / Touch ID 应用锁。
- **模块 4 · 定时任务中心与社区技能商店**：
  - `JobsSheet.swift`：完整 5 段式 Cron 定时任务增删改查、一键预设、手动触发、启停切换与执行回放直达。
  - `SkillsSheet.swift`：已安装技能详情（完整 `SKILL.md` 与文件清单）、GitHub 目录/Raw 链接/粘贴安装、在线浏览并一键安装 `OpenMinis/MinisSkills` 社区技能。

## 三、如何产出可安装的 `.ipa`
本仓库已配置好完整的免签自动化构建流水线：
1. 将本重构工程推送至你的 GitHub 仓库 `Pinevu/agy-ios-native` 的 `main` 分支（或直接解包覆盖后提交）。
2. GitHub Actions（`.github/workflows/build-native.yml`，`macos-15`）会自动执行 `xcodegen generate` → `xcodebuild Release` → `scripts/slim-ipa.sh` 瘦身，并上传产出的 **`Antigravity-6.0.0-100.ipa`**。
3. 也可在装有 Xcode 16+ 的 macOS 上运行 `xcodegen generate && open Agy.xcodeproj` 直接编译真机安装。
