# PocketWorld UI 与 Cauchy 最终重建完整交接提示词

生成时间：2026-07-10，北京时间。

这份文件本身就是给接力 agent 的提示词。请完整阅读后再改代码，不要只读结论。

- 产品仓正文：`/Users/kaidongwang/Developer/pocketworld/HANDOFF_UI与Cauchy最终重建_2026-07-10.md`
- 工作区备份：`/Users/kaidongwang/Documents/progecttwo/HANDOFF_UI与Cauchy最终重建_2026-07-10.md`

## 0. 接力任务与不可变产品决定

你正在接手 PocketWorld iOS AR 采集 App 的拍摄后最终稀疏点云、等待页、草稿重入、灵动岛后台任务和完整 Cauchy 全局 BA 集成。

用户已经明确做出以下决定，不得自行改回：

1. 中文回复。
2. 真机包必须使用 `flutter build ios --profile`。debug 包脱离调试器会崩。
3. 真机测试采用可拔线流程。日志写入 App 容器，用户完成操作后再拉取，不要求用户连线等 agent 实时盯日志。
4. 点云全量交付，不做为了展示而降采样。
5. 拍摄期间 SfM worker 与 Flutter UI 必须异步。SfM 反馈可以晚，但不能让拍照按钮等待 SfM。
6. 用户点击拍摄完成后进入最终成果等待状态。必须处理所有已拍且已进入队列的帧，不能丢弃剩余帧。
7. 最终成果出现前不向用户先展示 local 点云，不做后台静默替换。用户愿意等待权威最终稀疏点云。
8. 等待页左上角必须有返回草稿按钮。点击只显示草稿，不销毁 capture route，不销毁 SfM worker。
9. 用户在草稿页点击当前正在重建的同一任务卡时，必须回到原等待页看进度，不得启动第二个重建任务。
10. 等待过程中最终点云必须先完成取色并持久化到磁盘，之后才能出现“完成”按钮。
11. 打开 App、退出 App、前后台切换都不得凭空创建灵动岛任务。只有用户主动点击拍摄完成后才允许提交后台继续处理任务。
12. temporal 匹配保持 K12、8192 features、mutual GPU matcher。GPU matcher 失败时跳过该 pair，不允许进入分钟级 CPU brute-force fallback。
13. K20 已经真机否决。它明显增加每帧成本，不得恢复。
14. spatial guided matching 已经真机证明不能解决这次双墙，不能继续把它包装成双墙方案。
15. 用户现在要求接力 agent 落实完整 Cauchy 配方。当前手机包的 async `RefineGlobalBA()` 实际使用默认 global TRIVIAL，不是此前声称的完整 Cauchy。
16. 另一个 agent 负责全局 BA。做 UI 时必须保留本文件所述已验证交互，不得因为重构 finalize 再次删掉等待页、草稿返回或任务卡重入。

## 1. 仓库、远端、分支、HEAD 与工作树

### 1.1 产品 App 仓库

- 本地 git 根：`/Users/kaidongwang/Developer/pocketworld`
- GitHub 远端：`https://github.com/Kyle-Wang0211/pocketworld.git`
- origin fetch：`https://github.com/Kyle-Wang0211/pocketworld.git`
- origin push：`https://github.com/Kyle-Wang0211/pocketworld.git`
- 当前分支：`ar-capture-rs`
- 当前 HEAD：`981d157af588b083c865c82dfb1c6b33b67a5724`
- HEAD 标题：`feat(sfm): streaming COLMAP local-BA preview — color fix, floater filters, deferred global BA`
- 远端分支：`origin/ar-capture-rs`
- 重要事实：本轮所有 UI、灵动岛、spatial、temporal-detail 和 ABI 改动都没有 commit。远端分支不包含这些未提交内容。

产品仓当前所有 tracked 修改文件：

- `/Users/kaidongwang/Developer/pocketworld/ios/Podfile.lock`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AetherARKitPlugin.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift`
- `/Users/kaidongwang/Developer/pocketworld/lib/aether_sfm_ffi.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_live_recon.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_resume.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/main.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/sfm_preview_overlay.dart`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/aether3d_ffi.podspec`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/include/aether_sfm_c.h`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/src/pwsfm_export_shim.c`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/src/pwsfm_gpu_match.mm`

产品仓当前所有 untracked 文件：

- `/Users/kaidongwang/Developer/pocketworld/HANDOFF_双墙与热管理_2026-07-09.md`
- `/Users/kaidongwang/Developer/pocketworld/HANDOFF_UI与Cauchy最终重建_2026-07-10.md`
- `/Users/kaidongwang/Developer/pocketworld/test/sfm_final_quality_filter_test.dart`
- `/Users/kaidongwang/Developer/pocketworld/test/sfm_preview_overlay_test.dart`
- `/Users/kaidongwang/Developer/pocketworld/tool/sfm_spatial_pairs.dart`

远端 commit 基线文件 URL：

- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/lib/ui/capture/ar_capture_page.dart`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/lib/ui/capture/sfm_preview_overlay.dart`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/lib/ui/me_page.dart`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/lib/capture/sfm_live_recon.dart`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/lib/capture/sfm_resume.dart`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/ios/Runner/ReconUmbrella.swift`
- `https://github.com/Kyle-Wang0211/pocketworld/blob/981d157af588b083c865c82dfb1c6b33b67a5724/ios/Runner/AetherARKitPlugin.swift`

这些 URL 只代表 commit `981d157af588b083c865c82dfb1c6b33b67a5724` 的旧基线。当前等待页、草稿重入、灵动岛去重和最新算法接线只存在于本机未提交工作树，不能从远端 URL 恢复。

`/Users/kaidongwang/Developer/pocketworld/lib/main.dart` 当前 diff 主要是 `dart format` 排版变化，不要把它误报成一项新的 UI 功能。曾经触发 App 启动自动恢复的调用属于中间工作树版本，当前 `lib/main.dart` 中已经没有 `resumeIncompleteCaptures()` 调用。

### 1.2 原生 Aether3D 仓库

- 本地 git 根：`/Users/kaidongwang/Developer/Aether3D-cross`
- 原生代码根：`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp`
- GitHub 远端：`https://github.com/Kyle-Wang0211/Aether3D.git`
- origin fetch：`https://github.com/Kyle-Wang0211/Aether3D.git`
- origin push：`https://github.com/Kyle-Wang0211/Aether3D.git`
- 当前分支：`claude/publish-to-community`
- 当前 HEAD：`74d5f47716af5dda6516c58acd34d45331782d56`
- HEAD 标题：`feat(sfm): streaming local-BA preview — grow-gate, TVG inliers, floater filters, telemetry`
- 远端分支：`origin/claude/publish-to-community`
- 这是巨型、长期脏工作树。不得 reset、clean、checkout 或删除不属于本任务的文件。

当前 tracked 修改文件：

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/include/aether/shaders/wgsl_sources.h`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/include/aether_sfm_c.h`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/CMakeLists.txt`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/aether_sfm_stub.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/colmap_bench.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/dsp_sift_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/estimators/bundle_adjustment_ceres.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/iosapp/Sources/AppDelegate.m`

远端 commit 基线文件 URL：

- `https://github.com/Kyle-Wang0211/Aether3D/blob/74d5f47716af5dda6516c58acd34d45331782d56/aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc`
- `https://github.com/Kyle-Wang0211/Aether3D/blob/74d5f47716af5dda6516c58acd34d45331782d56/aether_cpp/third_party/glomap_vendor/bench/colmap_bench.cc`
- `https://github.com/Kyle-Wang0211/Aether3D/blob/74d5f47716af5dda6516c58acd34d45331782d56/aether_cpp/include/aether_sfm_c.h`

这些 URL 同样只代表 commit `74d5f47716af5dda6516c58acd34d45331782d56`。当前 `RefineGlobalBA()`、spatial、temporal-detail 和 telemetry 改动只存在本机。

原生仓还有大量预先存在的 untracked 构建目录、依赖、benchmark、shader 和其他项目文件。不要全量整理。需要查看时只运行：

```bash
cd /Users/kaidongwang/Developer/Aether3D-cross
git status --short --untracked-files=no
git diff -- aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc
```

### 1.3 不要混淆的旧 Flutter 工程

- `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_flutter`

它不是本次装到手机上的产品工程。本次产品工程只有 `/Users/kaidongwang/Developer/pocketworld`。

## 2. 当前手机包与可复现指纹

- Bundle ID：`com.kyle.PocketWorld`
- Team ID：`26AH7V448L`
- 设备：Kyle’s iPhone，iPhone 14 Pro，iOS 26.5
- coredevice UDID：`1B290474-D354-5B4C-AAB0-0805AC5DC832`
- 当前 profile App 本地路径：`/Users/kaidongwang/Developer/pocketworld/build/ios/iphoneos/Runner.app`
- 当前 Runner executable 构建时间：`2026-07-10 11:15:07`
- 当前 Runner executable SHA-256：`b319f1e49483614bbcc1290737b92847f80857649e57e527d5fa3a3f26d339e2`
- 当前产品仓 native archive SHA-256：`989c36450285024963410e0e95eb8ec544cdeaeefec17e83df74fc349f06a92d`
- 当前产品仓 native archive 路径：`/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a`
- 当前产品仓 native archive 写入时间：`2026-07-10 11:14:12`
- 当前原生 build-ios archive 路径：`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-ios/libglomap_core.a`
- 当前原生 build-ios archive 写入时间：`2026-07-10 10:51:56`
- 当前原生 build-ios archive SHA-256：`e76b2f42336e0b96b9710764ce2904cfe907eccb5272d8d33c27e93e87a726f4`

两个 archive 哈希不同。产品仓 archive 更新更晚，当前手机包链接的是产品仓那份。接力 agent 修改 native 后必须重新运行 iOS native build，并明确复制新的 archive 到产品仓，不能假定 `build-ios/libglomap_core.a` 就是手机当前那份。

当前 UI 文件 SHA-256：

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift`：`1bbd912564778a73baad01fe5c06492ebe3cacc11310d653202ba2e53ac46e54`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart`：`aa4c1dee6b1fde62fb60137a6382389df5aaafc08593954e77ce31d16989aef6`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/sfm_preview_overlay.dart`：`60405237c210b93e25b51720ab45fef78bfa7210e88d436c6267d6f471432f99`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart`：`63b76948dcc38496b156b825df625366b02a7bb8fcb9f40ea24099e4496a6f2d`

## 3. UI 版本时间线，包括成功版和失败版

### 3.1 基线：先显示 local，再后台替换 refined

基线 commit `981d157af588b083c865c82dfb1c6b33b67a5724` 的设计是：完成后较快显示 local 点云，后台 global refine 完成后替换。用户明确否决了这种产品行为，要求直接等待最终成果。不要恢复。

### 3.2 失败版本 A：App 启动自动扫旧任务，灵动岛越开越多

2026-07-10 09:55 左右的中间版本曾在 App 启动时自动调用 `resumeIncompleteCaptures()`。它扫描到 5 个有 `sfm_live.db` 但没有 `sfm_sparse.ply` 的旧 capture，并依次重跑 finalize。证据在：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/pw_device_log.txt`
- 关键行号：6400 至 6520
- 日志明确写出 `sweep: 5 capture(s) to recover`

这导致用户只是打开 App 再退出，灵动岛就出现“PocketWorld 重建”，而且每次进入可能增加任务卡。原图文件当时位于：

- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/ac4723a537dfcc3026c2af88c088f103.jpg`

该微信临时图片已被系统清理，当前磁盘上不存在，但用户截图内容是灵动岛同时出现两条 PocketWorld 重建任务。

当前修复：

1. 当前 `lib/main.dart` 没有任何 `resumeIncompleteCaptures()` 调用。
2. `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_resume.dart:56` 明确写成只能由显式用户恢复动作调用。
3. `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift:42` 在注册 handler 时取消上个进程残留的 pending request。
4. `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift:61` 使用 capture directory 作为 job ID，同一个 job 重复 begin 不会再 submit。
5. `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift:83` 只尝试 `.fail` 的 immediate submission，不再 fallback 到 `.queue`，避免排到以后无缘无故出现。
6. 删除旧版 `UIApplication.didBecomeActiveNotification` recycle 逻辑。前后台切换不再完成旧卡后重新提交一张新卡。
7. `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AetherARKitPlugin.swift:480` 和 `:491` 将 `jobId` 传给 native begin/end。
8. `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1119` 至 `:1148` 在 Dart 侧也做 job ID 幂等。

验证状态：修复代码已进入 2026-07-10 11:15 的 profile 包。最新 11:23 至 11:31 采集使用了该包，未再触发自动旧任务 sweep。尚未做一套专门的“连续前后台十次并观察灵动岛数量”真机压力验证，不能写成完全验证。

### 3.3 失败版本 B：detached finalize 导致点击完成直接回草稿

2026-07-10 10:03 的中间版本把 live recon ownership 交给 `startDetachedSfmFinalize()`，随后 capture route 直接退出。结果是用户点击拍摄完成后没有看到队列等待页，而是直接回到草稿页。用户明确指出这是 UI 回归。

证据：

- capture ID：`cap_1783648612967643`
- 本地日志：`/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/pw_device_log.txt`
- 关键行：6819 至 6839
- 行 6820：`finish: sfm fed=98 queued=0 detached=true`
- 行 6822：`detached finalize start`
- 最终结果：48,027 点

失败原因不是算法线程不异步，而是 UI route 和 event subscription 被过早释放。worker 虽然继续跑，但等待页不再存在。

当前状态：`/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_resume.dart:43` 的 `startDetachedSfmFinalize()` 和内部 `_runDetachedFinalize()` 仍保留在文件中，但整个产品仓没有调用者。它们是死代码。不要重新接回拍摄完成主流程，否则会复现直接退出草稿问题。以后可单独删除，但不要在全局 BA 交接中顺手做无关重构。

### 3.4 当前版本 C：等待页恢复，允许返回草稿和任务卡重入

当前实现写于 2026-07-10 10:20，已经进入 11:15 profile 包。

完整交互：

1. 用户点拍摄完成。
2. `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1243` 进入 `_finalizeRecording()`。
3. `:1254` 停止 CaptureSession 并等待照片保存完成。
4. `:1278` 主动停止 ARSession。此时相机、VIO 和 ARSCNView 不再占用资源。
5. `:1315` 判断当前 recon 是否有至少 2 帧。
6. `:1326` 至 `:1335` 将 UI 状态设置为 `SfmPreviewPhase.generating`，初始化剩余帧计数。
7. `:1338` 只在真实用户完成动作后 begin 灵动岛 umbrella。
8. `:1340` 调用异步 `recon.finalize()`。Flutter 不执行 native solve。
9. 草稿记录仍会持久化，但 `:1379` 的 `_exitToDrafts()` 检测到 `_sfmPhase` 非空，只记录 `_sfmPendingPop=true`，不会立即 pop route。
10. `:1692` 至 `:1702` 渲染全屏 `SfmPreviewOverlay`。
11. 队列未清时显示 `已处理 N 帧 · 剩余 M 帧`。
12. 队列清空后显示 `帧队列已清空 · 正在生成最终点云`。
13. LOCAL 事件不作为用户结果显示。worker 日志明确写 `local_ready withheld; waiting for refined final snapshot`。
14. refined snapshot 先在 `_colorizeSnapshot()` 取色，再做保守 orphan filter，再 `await persistSparseSnapshot()`。
15. PLY 持久化结束后才把 `_sfmPhase` 改成 refined，等待页显示最终点云和“完成”按钮。
16. 用户点“完成”，`_onSfmPreviewDone()` 释放 worker、结束 umbrella，并根据 `_sfmPendingPop` 返回草稿。

等待页 UI 文件：

- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/sfm_preview_overlay.dart`
- `:53` 只有 refined 或 error 才允许完成。
- `:88` 至 `:107` 是左上角返回草稿按钮。
- `:108` 至 `:139` 是生成中 spinner 和队列文字。
- `:172` 至 `:208` 是只在 terminal 状态出现的完成按钮。
- `:215` 至 `:230` 是顶部状态 chip。

返回草稿和重入：

- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1178` 的 `_showDraftsDuringReconstruction()` 只切换 bool，不 dispose worker。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1184` 的 `_showReconstructionProgress()` 恢复等待页。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1556` 在该 bool 为 true 时渲染 `MePage`，同时把当前 captureDir 和重入 callback 传进去。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart:44` 至 `:60` 新增 `initialShowDrafts`、`activeReconstructionCaptureDir`、`onActiveReconstructionTap`。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart:84` 至 `:100` 保证临时 MePage 默认打开草稿 tab。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart:366` 至 `:377` 在点击同一 captureDir 的草稿卡时调用原 route callback，不打开半成品 PLY，不启动第二个 worker。

验证状态：

- Widget 测试文件：`/Users/kaidongwang/Developer/pocketworld/test/sfm_preview_overlay_test.dart`
- 2026-07-10 再跑结果：3 个 overlay 测试全部通过。
- 测试覆盖 generating 不出现完成、generating 有返回按钮、terminal 才出现完成。
- 最新真机采集 `cap_1783653792723217` 从完成动作进入当前等待主流程，并成功等到最终 62,691 点。
- 尚未单独录制真机手势来验证“等待中点返回草稿，再点同一任务卡，再回等待页”的完整交互。代码和 widget 测试支持该行为，但交接时必须标为待专测。
- 当前临时草稿页是 capture route 内直接渲染的 `MePage`，不是完整底部导航 AppShell。它能浏览草稿和点当前卡重入，但没有实现等待时启动第二次 AR 采集。
- 如果 App 被杀，capture route 不再存在。当前没有自动恢复，因为自动恢复会制造灵动岛任务。未来若要冷启动恢复，必须做显式“继续重建”按钮，不能在 App launch 自动调用 sweep。

## 4. 灵动岛后台任务当前实现

相关文件：

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AetherARKitPlugin.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AppDelegate.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/Info.plist`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner.xcodeproj/project.pbxproj`

关键点：

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AppDelegate.swift:33` 至 `:38` 只负责注册 handler，不 submit 任务。
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/Info.plist:109` 至 `:121` 声明 `fetch`、`processing` 和 `com.kyle.PocketWorld.recon`。
- identifier 大小写必须精确为 `com.kyle.PocketWorld.recon`。
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift:31` 使用 `Set<String>` 跟踪 active job ID。
- begin 同一 job 幂等。
- 多 job 共用一个 umbrella，不为每个 job 建一张系统卡。
- submit 只允许 foreground。
- handler 每 2 秒增加 progress，避免系统把任务判断成停滞。
- end 最后一个 job 时取消 pending request。
- task completion 永远传 success=true，避免系统残留失败 tombstone 卡。

需要接力 agent 补做的 UI 真机验证：

1. 冷启动 App，不拍摄，退出。灵动岛不得出现 PocketWorld 重建。
2. 连续进入退出 App 5 次。灵动岛仍不得出现任务。
3. 完成一次拍摄。灵动岛最多一条 PocketWorld 重建。
4. 重建中前台、后台往返 5 次。不得增加第二条任务。
5. 最终 PLY 持久化后，任务应完成并消失，不留失败卡。

## 5. 拍摄 UI 为什么不应被 SfM 阻塞

当前 SfM 重计算在 `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_live_recon.dart` 的 worker isolate 内运行。Flutter 页面只 offer frame、接收事件、刷新计数，不执行 C++ solve。

此前拍摄按钮偶尔在后台 colorize 时等待数秒，不是 BA 阻塞 Flutter，而是 native `decodeJpegForColor` 逐帧 ImageIO decode 曾占用 platform main thread，饿死 shutter method-channel reply。

修复位置：

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AetherARKitPlugin.swift:501` 附近
- `decodeJpegForColor` 现在派发到 `colorizeQueue`，只把 FlutterResult 回调切回 main thread。
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1190` 至 `:1205` 记录每次 shutter 等待时间和当前 sfmPhase。

最新 11:23 至 11:28 拍摄中绝大多数 shutter 等待约 100 至 180 ms，热起来后个别 300 至 921 ms。没有再出现旧版 GPU matcher 失败后 CPU fallback 导致的 90 秒至 235 秒单帧阻塞。

## 6. 当前完整 Cauchy 缺口，接力 agent 的第一优先级

### 6.1 当前代码实际做了什么

文件：`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc`

同步 `RunPipeline()` 的完整已验证配置在 `:1160` 至 `:1231`，其中：

- `:1174` `defer_global_ba = true`
- local-only phase 设 `skip_finalize_global_ba = true`
- `:1182` `ba_local_max_num_iterations = 15`
- `:1183` `ba_min_num_residuals_for_cpu_multi_threading = 6000`
- `:1198` `ba_local_loss_type = 2`
- `:1199` `ba_local_loss_scale = 1.0`
- `:1200` `ba_global_loss_type = 2`
- `:1201` `ba_global_loss_scale = 1.0`
- `:1202` `ba_global_function_tolerance = 1e-6`
- `:1203` `mapper.ba_local_num_images = 10`
- global refinement 默认 `ba_global_max_refinements = 5`
- global 单次默认 `ba_global_max_num_iterations = 50`

但是 async worker `RefineGlobalBA()` 在 `:1246` 至 `:1271` 新建了一套默认 `IncrementalPipelineOptions`，只设置：

- `min_num_matches = 15`
- `ba_min_num_residuals_for_cpu_multi_threading = 6000`
- `image_path`

它没有设置 global Cauchy、loss scale 或 `function_tolerance`。默认值定义在：

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.h:127`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.h:143`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.h:144`

默认 global loss 是 `ba_global_loss_type = 0`，也就是 TRIVIAL。

因此当前 11:15 手机包的 phase 2 不是完整 Cauchy。此前把它描述为完整 Cauchy 是错误陈述。

### 6.2 注释与实际调用不一致

`aether_sfm_c.cc:1240` 的注释说 async worker 通过 `TriangulateReconstruction` 做 re-triangulation 和 global BA，但实际 `:1261` 调用的是：

```cpp
pipeline.RefineReconstruction(refined);
```

两者定义：

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.cc:782` 的 `TriangulateReconstruction()` 先逐 registered image 调 `TriangulateImage()`，再 `IterativeGlobalRefinement()`。
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.cc:821` 的 `RefineReconstruction()` 不执行逐 image triangulation，只运行 iterative global refinement、FilterFrames 和 UpdatePoint3DErrors。

接力 agent 必须先更正注释并明确选择，不允许继续把两个 API 当成同一件事。

### 6.3 用户现在要求的最小明确动作

用户已经要求完整 Cauchy。最小改动是在 `RefineGlobalBA()` 的 `popts` 上补齐 phase 2 所需配置：

```cpp
popts->ba_global_loss_type = 2;
popts->ba_global_loss_scale = 1.0;
popts->ba_global_function_tolerance = 1e-6;
popts->ba_global_max_refinements = 5;
popts->ba_global_max_num_iterations = 50;
popts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
```

phase 1 已经由 `RunPipeline(local_only=true)` 使用 local Cauchy。是否还要在 phase 2 `popts` 同步 local loss 和 `mapper.ba_local_num_images=10`，应以所调用 API 实际读取哪些 options 为准，不要为了表面一致盲加。

是否把 `RefineReconstruction()` 改成 `TriangulateReconstruction()` 是另一项算法决定。不要把“补完整 Cauchy”与“切完整 re-triangulation”混成一次不可解释改动。用户明确知道某次全局 BA 能消双墙，接力 agent 应定位那次 exact pipeline 后做受控 A/B。

### 6.4 已经跑过的最新 DB 离线 A/B

Host executable：

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-host/colmap_bench_exe`
- SHA-256：`207d22d279947a0ab84eb961cc875b775a2b53cd02fba951cee8ddb31ad32dde`

输入 DB：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/sfm_live.db`

当前 spatial DB 的 Cauchy 重建输出：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_spatial/cameras.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_spatial/frames.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_spatial/images.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_spatial/points3D.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_spatial/rigs.txt`
- 84 registered images
- 46,874 points
- 207,825 observations
- mean track length 4.434
- reprojection error 0.8472 px
- host wall time约 60.2 s

同一 DB 的 TRIVIAL 输出：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_spatial/cameras.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_spatial/frames.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_spatial/images.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_spatial/points3D.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_spatial/rigs.txt`
- 84 registered images
- 45,713 points
- 215,147 observations
- mean track length 4.706
- reprojection error 1.0543 px
- host wall time约 37.6 s

只保留时间近邻 pair 的 DB：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/temporal_only.db`
- 删除 frame gap 大于 12 的 311 个 long-gap pair
- Cauchy 只注册 51 张图
- 26,269 points
- 111,584 observations
- reprojection error 0.9231 px
- 输出目录：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/cauchy_temporal`

视觉对比：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/trivial_vs_cauchy_views.png`

结论必须准确表达：Cauchy 将 reprojection error 从 1.0543 明显降到 0.8472，但这份最新 DB 的 PCA 视图中双层结构仍可见。因此“把 TRIVIAL 换成 Cauchy”值得做且用户已经要求做，但不能在装机前承诺它单独必然消双墙。删掉所有 spatial pair 也不可行，因为 registered images 从 84 掉到 51。

## 7. 最新真机结果与当前问题

### 7.1 最新 capture

- capture ID：`cap_1783653792723217`
- 用户截图最终点数：62,691
- 设备 capture 绝对路径：`/var/mobile/Containers/Data/Application/418B2088-CE28-413D-B330-7F1F949105BA/Documents/captures/cap_1783653792723217`
- 本地拉取目录：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132`
- 本地完整日志：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/pw_device_log.txt`
- 本地点云：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/sfm_sparse.ply`
- 本地 metadata：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/sfm_sparse_meta.json`
- 本地 fed frame sidecar：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/sfm_fed_frames.jsonl`
- 本地 DB：`/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/sfm_live.db`

关键真机数据：

- offered 89，fed 89，用户完成时 remaining 0
- finalize phase 1 wall time 169,594 ms
- phase 1 summary solve_ms 57,566.5 ms
- wall time 与 solve_ms 相差约 112 s，主要是 finish-time spatial matching 和相关准备，不是队列排空
- spatial considered 583
- spatial attempted 506
- spatial written 313
- spatial inliers 85,763
- anchors passed 113 of 179
- confirmed regions 19
- expanded attempts 298
- guided calls 349
- guided candidates 173,470
- phase 2 temporal detail wall time 19,602 ms
- temporal pairs 608
- temporal inliers 367,572
- temporal detail created 19,104
- temporal detail grown 341
- temporal reprojection rejects 33,437
- temporal triangulation-angle rejects 19,587
- temporal conflicts 15,264
- spatial-only two-view removed 1,789
- refined before Dart orphan filter 63,097
- colorized 62,849 of 63,097，日志按整数百分比显示 100%
- decoded frames 81，decode failures 3
- Dart orphan filter removed 406
- final persisted 62,691
- 双墙没有肉眼缓解
- 极端浮点消失
- 取色混色问题复现

### 7.2 双墙结论需要纠正

此前理论是“缺跨视 track，所以 BA 没有约束；补 spatial loop pair 后 full finalize 就能消双墙”。其中必要条件部分合理，但被错误地升级成了充分条件。

这次 313 个 spatial pair 和 85,763 个 spatial inlier 已经写入 DB，双墙仍没有肉眼改善。pair-level TVG inlier 数量不能证明重复墙两次访问已经形成正确、跨区、多视图、能拉动位姿的 track bridge。

因此：

- spatial guided 分支作为“双墙解法”已经失败。
- 它仍对图像连通和注册率有价值，不能直接全删。
- 下一步双墙主线应由接力 agent 复刻用户亲自验证过的 exact 全局 BA pipeline。
- 不得再声称“spatial pair 加 full finalize 已确定能解决双墙”。

### 7.3 取色问题根因

当前 live colorizer：

- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:699` 至 `:818`

当前 resume colorizer：

- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_resume.dart:215` 至 `:323`

两处都对一个 3D point 的所有 track observation 做 RGB 算术平均。最新 temporal-detail 恢复了 19,104 个细节点，其中大量是短 track。若两视图中有一个边界 keypoint 或错误 observation，算术平均会创造并不存在的混合色。旧作品未命名(33)和未命名(34)也有同类取色问题。

下一步建议是独立颜色修复，不改 geometry、不改点数：

1. 不再生成 RGB 算术平均色。
2. 三个及以上样本时，从真实 observation 色中选 robust representative medoid，或选最接近 robust 中心的真实样本。
3. 两个样本时不平均，优先选择 keypoint 更靠近图像中心的 observation。
4. live 和 resume 两份实现必须同步，避免冷恢复作品与现场作品颜色不一致。
5. 修改前保留原始样本计数和取色日志，以便 A/B。

最新 3 个 JPEG decode failure 不是主因，因为几何点 100% 都至少命中一个可用 observation。

## 8. 近期算法版本与真机结果索引

所有这些历史都能在下列完整日志中找到：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/pw_device_log.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132/pw_device_log.txt`

重要 capture：

1. 未命名(33)，60,628 点
   - capture ID：`cap_1783577563647102`
   - 完成时间：2026-07-09 14:16
   - fed 68，queue 2
   - streaming local 保存，`refined=false`
   - 低纹理床侧和地板分布较好

2. 未命名(34)，81,906 点
   - capture ID：`cap_1783581597353848`
   - 完成时间：2026-07-09 15:26
   - fed 81，queue 0
   - streaming local 保存，`refined=false`
   - 用户认为其点云分布优于后续版本

3. 89,332 点，两步 capped pure global refine
   - capture ID：`cap_1783609173673814`
   - global refine 8,392 ms
   - 双墙未解决

4. 98,185 点，K12，旧 CPU fallback 问题仍存在
   - capture ID：`cap_1783612108520868`
   - 完成时 fed 37，queue 85
   - frame 38 出现 GPU matcher 失败后 CPU fallback，单帧 235,369 ms，其中 match 233,335 ms
   - 该事件直接证明 CPU fallback 会把等待拖到不可接受

5. 56,949 点，K20 实验
   - capture ID：`cap_1783614507485074`
   - 完成时 fed 75，queue 28
   - 后段 `cand=20`
   - 多帧每帧约 5 至 18 s
   - K20 真机否决，已退回 K12

6. 48,027 点，spatial guided 严格版
   - capture ID：`cap_1783648612967643`
   - 本地产物目录：`/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023`
   - 极端浮点数量达到历史最差
   - 离线 ablation 证明主要风险来自 spatial-only guided 两视图点
   - 同一版本还有 detached finalize 直接退出草稿的 UI 回归

7. 62,691 点，temporal-detail 恢复加 spatial-only 两视图过滤
   - capture ID：`cap_1783653792723217`
   - 极端浮点消失
   - 密度恢复到 6 万以上
   - 双墙无改善
   - 取色混色复现
   - 当前手机包对应这一版

## 9. 浮点 ablation 产物

目录：`/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023`

文件：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/pw_device_log.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/sfm_live.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/sfm_sparse.ply`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/sfm_sparse_meta.json`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/sfm_fed_frames.jsonl`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/photo_bundle.json`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/spatial_written_pairs.txt`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_all.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_raw.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_reverify.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_strict.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_temporal.db`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023/ablation_compare.png`

验证出的方向：完全关闭 guided 会减少极端浮点，但损失回环连通；最终保留 spatial 用于位姿和注册，同时排除 spatial-only 两视图交付点，再用 temporal K12 mutual matches 在最终位姿后恢复细节点。最新真机证明该组合能消除极端浮点并恢复密度，但没有解决双墙。

## 10. 关键代码地图

### UI 与导航

- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart`
  - capture、finish、queue 状态、waiting overlay、返回草稿、任务重入 callback、取色、持久化、orphan filter
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/sfm_preview_overlay.dart`
  - 等待页、返回按钮、队列文字、terminal 完成按钮
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/me_page.dart`
  - 临时草稿页和 active task card 重入
- `/Users/kaidongwang/Developer/pocketworld/test/sfm_preview_overlay_test.dart`
  - 等待页 3 个 widget tests

### Worker、恢复和持久化

- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_live_recon.dart`
  - worker isolate、queue、K12、8192、finalize、事件、telemetry
- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sfm_resume.dart`
  - 显式冷恢复 helper、目前未调用的 detached helper、第二份 colorizer
- `/Users/kaidongwang/Developer/pocketworld/lib/capture/sparse_ply.dart`
  - `sfm_sparse.ply` 与 metadata 持久化
- `/Users/kaidongwang/Developer/pocketworld/test/sfm_final_quality_filter_test.dart`
  - spatial-only 两视图过滤测试

### iOS 后台与主线程隔离

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/ReconUmbrella.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AetherARKitPlugin.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/AppDelegate.swift`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/Info.plist`
- `/Users/kaidongwang/Developer/pocketworld/ios/Runner.xcodeproj/project.pbxproj`

### FFI 与 native 算法

- `/Users/kaidongwang/Developer/pocketworld/lib/aether_sfm_ffi.dart`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/include/aether_sfm_c.h`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/src/pwsfm_export_shim.c`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/src/pwsfm_gpu_match.mm`
- `/Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/aether3d_ffi.podspec`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/include/aether_sfm_c.h`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/bench/colmap_bench.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.h`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/incremental_pipeline.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/estimators/bundle_adjustment_ceres.cc`

## 11. 构建、安装与拉日志完整命令

### 11.1 修改 native 后重编 archive

```bash
cd /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor
LANG=en_US.UTF-8 bash build_ios.sh
nm -gU /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-ios/libglomap_core.a | rg 'aether_sfm_(finalize_async|stream_stats|global_refine|get_points_tracked)'
cp /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-ios/libglomap_core.a /Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a
```

注意：`cp` 后必须检查两个 archive 的 SHA-256 相同。

```bash
shasum -a 256 /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-ios/libglomap_core.a /Users/kaidongwang/Developer/pocketworld/vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a
```

### 11.2 构建 profile App

```bash
cd /Users/kaidongwang/Developer/pocketworld
flutter clean
cd /Users/kaidongwang/Developer/pocketworld/ios
LANG=en_US.UTF-8 pod install
cd /Users/kaidongwang/Developer/pocketworld
LANG=en_US.UTF-8 flutter build ios --profile
```

### 11.3 安装到真机

```bash
xcrun devicectl device install app --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 /Users/kaidongwang/Developer/pocketworld/build/ios/iphoneos/Runner.app
```

### 11.4 列设备容器文件

```bash
xcrun devicectl device info files --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld --username mobile --subdirectory Documents/captures
```

### 11.5 拉设备日志到一个明确目录

```bash
mkdir -p /Users/kaidongwang/Developer/pocketworld_artifacts/next_pull_2026-07-10
xcrun devicectl device copy from --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld --user mobile --source Documents/pw_device_log.txt --destination /Users/kaidongwang/Developer/pocketworld_artifacts/next_pull_2026-07-10/pw_device_log.txt
```

### 11.6 拉最新已知 capture

```bash
mkdir -p /Users/kaidongwang/Developer/pocketworld_artifacts/repull_cap_1783653792723217
xcrun devicectl device copy from --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld --user mobile --source Documents/captures/cap_1783653792723217 --destination /Users/kaidongwang/Developer/pocketworld_artifacts/repull_cap_1783653792723217
```

容器内固定日志：

- `Documents/pw_device_log.txt`
- `Documents/gpu_sift_feat.log`

每个 capture 的核心文件：

- `sfm_live.db`
- `sfm_live.db-shm`
- `sfm_live.db-wal`
- `sfm_sparse.ply`
- `sfm_sparse_meta.json`
- `sfm_fed_frames.jsonl`
- `photo_bundle.json`
- `photos_highres`
- `previews`

## 12. 当前测试结果与已知静态告警

运行命令：

```bash
cd /Users/kaidongwang/Developer/pocketworld
flutter test test/sfm_preview_overlay_test.dart test/sfm_final_quality_filter_test.dart
```

当前结果：4 tests passed。

目标文件 analyze：

```bash
cd /Users/kaidongwang/Developer/pocketworld
dart analyze lib/ui/capture/ar_capture_page.dart lib/ui/capture/sfm_preview_overlay.dart lib/ui/me_page.dart lib/capture/sfm_resume.dart test/sfm_preview_overlay_test.dart
```

当前只有 5 个既有 unused_element warning：

- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:420` `_stopRecordingIfRunning`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:466` `_onCenterTap`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:1919` `_PhotoPositionOverlay`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:2488` `_IdleHintPill`
- `/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/ar_capture_page.dart:2514` `_CaptureButtonOrDome`

不要为了清这 5 个 warning 在 Cauchy 接力中做大范围 UI 删除。

## 13. 过往交接与临时资料状态

旧交接正文：

- `/Users/kaidongwang/Developer/pocketworld/HANDOFF_双墙与热管理_2026-07-09.md`

旧交接曾声称有 scratchpad 备份：

- `/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/4a7bc53b-bdac-47b4-8715-2a1bf9249914/scratchpad/HANDOFF_双墙与热管理_2026-07-09.md`

2026-07-10 已实际搜索 `/private/tmp`，该备份当前不存在，推测被系统清理。不要把它当唯一资料源。

旧交接提到的 `dev_pull7` scratchpad 目录当前也未找到。可用的持久资料已经迁到：

- `/Users/kaidongwang/Developer/pocketworld_artifacts/floaters_2026-07-10_1023`
- `/Users/kaidongwang/Developer/pocketworld_artifacts/latest_2026-07-10_1132`

## 14. 用户提供图片索引

以下是会话中用户提供过的关键视觉证据。微信和系统截图临时目录会自动清理，只有最后一张当前仍存在。即使文件不在，也保留原路径和内容说明，避免丢记忆。

- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/eaa226f532051ecdf6a32f500ad05364.jpg`：89,332 点版本
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/8e4c87074a45ed8ebf45f2f77555f074.jpg`：未命名(34)，81,906 点
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/b78b526ef21c501b2c567c1ae3477e9c.jpg`：未命名(33)，60,628 点
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/bc28807b3b3955f4384b601b8fd92cd7.jpg`：98,185 点版本
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/614604cee3c0e5f03efd331cc408ea69.jpg`：56,949 点 K20 版本
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/ac4723a537dfcc3026c2af88c088f103.jpg`：打开 App 即出现两条灵动岛重建任务
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/5b5d2021b27c11cea8079ffd1ce60ff6.jpg`：48,027 点极端浮点版本近视图
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/6b71b1f80ab2f8f7eea905c32b122981.jpg`：48,027 点极端浮点版本远视图
- `/Users/kaidongwang/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_3ku80r1l155n12_f0d1/temp/RWTemp/2026-07/9e20f478899dc29eb19741386f9343c8/328a99d10eb320ba3d34ee462d57a3bd.jpg`：最新 62,691 点，极端浮点消失，双墙与混色仍在；当前文件仍存在

## 15. 接力执行顺序

1. 先保存两仓 `git status --short --untracked-files=no` 和相关文件 diff，不要覆盖用户或其他 agent 的改动。
2. 只改 `RefineGlobalBA()` 的完整 Cauchy配置，先保持 `RefineReconstruction()` 不变，做一次可解释 A/B。
3. host 编译并用最新 `sfm_live.db` 验证 metrics，确认实际 loss type、solver、gref、giter 和 gftol 都进入日志。
4. 重编 iOS archive，复制到产品仓，确认 SHA-256 相同。
5. profile build 并安装。
6. 保持当前等待页、返回草稿、任务卡重入、最终持久化后才完成的 UI contract。
7. 真机验证 Cauchy结果时同时记录总等待分解：queue drain、spatial matching、phase 1 solve、phase 2、colorize、persist。
8. 用固定几何门槛或同视角截图判断双墙，不要只看 reprojection error。
9. Cauchy仍不消双墙时，定位用户曾确认有效的 exact 全局 BA capture 和 exact pipeline，不要继续猜。
10. 颜色修复作为独立后续 patch，采用真实 observation representative color，不和 BA 一次改完。
11. 最后单独做等待页返回重入和灵动岛 5 次前后台压力测试。

## 16. 必须向用户诚实说明的结论

1. 当前手机包并不是此前声称的完整 Cauchy async refine，phase 2 实际是默认 global TRIVIAL。
2. 完整 Cauchy值得立刻补齐，而且用户已明确要求补齐。
3. 最新 host Cauchy A/B 显著改善 reprojection error，但最新 DB 的双层结构仍可见，不能提前承诺只改 loss 就必消双墙。
4. spatial guided 已经不应再作为双墙主方案，但保留它对注册连通有价值。
5. 最新 temporal-detail 方案成功恢复 6 万级密度并去掉极端浮点，这是已验证成果。
6. 最新取色问题来自 observation RGB 算术平均的设计缺陷，和双墙是两条独立问题。
7. 当前等待页主流程真机跑通过一次；草稿重入与灵动岛压力场景还缺专门真机复测。

完成交接后，不要先写长方案。先用一句话向用户复述你理解的优先级：完整 Cauchy、保留当前等待 UI、真机判断双墙、颜色独立修。然后直接检查代码和执行。
