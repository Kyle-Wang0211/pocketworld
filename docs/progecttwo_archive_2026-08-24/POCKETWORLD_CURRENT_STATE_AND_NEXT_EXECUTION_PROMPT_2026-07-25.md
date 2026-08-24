# PocketWorld 当前状态与下一阶段超级连续执行提示词

> 快照日期：2026-07-25（Asia/Shanghai）  
> 用途：把本文件完整交给下一次 Codex 任务，使其无需重新翻阅整段历史对话，也能准确接手 PocketWorld 产品、真机生产管线、官方 COLMAP 对齐、稀疏点云显示和本地研究资产。  
> 重要：本文件是“执行提示词 + 状态快照”，不是新的算法设计提案。开始任何修改前，仍要用 Git、文件哈希、当前手机状态和实验清单复核发生在本快照之后的变化。

---

## 0. 给下一位 Codex 的直接指令

你正在继续 PocketWorld 的长期产品与算法对齐工作。先完整阅读本文件，再开始任何命令、代码、实验、安装或删除操作。

你的总任务不是“再创造一个看起来更聪明的新算法”，而是：

1. 保住当前已经在用户 iPhone 上运行良好的生产版本和本地项目数据。
2. 继续逐项识别 PocketWorld 与官方 COLMAP 4.1.0、RealityScan 已知行为之间的差异。
3. 每次只改变一个可归因变量。
4. 能直接复用官方或经过商用许可审计的成熟实现时，不自创替代算法。
5. 任何生产质量、速度、参数接受结论必须来自用户物理 iPhone 的实际生产管线；Mac、桌面、模拟器和独立 COLMAP 重放只能用于诊断、搭建实验和提出假设。
6. 不得牺牲、覆盖或重新安装用户手机上的现有 App 与项目数据。

### 0.1 当前最高级别目标

当前唯一主命题仍然是：

> 让 PocketWorld 在拍摄期和最终输出的稀疏点云，尽可能接近 RealityScan 所呈现的高质量、稳定覆盖和真实空间对齐，同时把求解内层尽量保持为官方 COLMAP 语义；ARKit 提供高质量的图像、内参、位姿、重力、尺度和时间信息，但不要用自创后处理在官方 BA/过滤结束后裸补点。

### 0.2 当前已冻结的产品方向

- 产品只保留一条拍摄入口和一条“官方”生产路线。
- 用户点击拍摄后直接进入当前生产路线。
- 不再显示“自研 / 官方”选择器。
- 草稿卡片不再显示“官方”徽标。
- 生产 matcher 仍为 iPhone Metal matcher；桌面 CPU 精确 matcher 只是诊断参考。
- 生产最终点云停在：
  - 官方 COLMAP 最终全局 BA；
  - 官方轨迹完成、重三角化和过滤；
  - 然后取色、持久化与展示。
- 禁止在这个官方终点之后执行：
  - `RestoreTemporalDetail`；
  - `repair/enrichment`；
  - spatial revisit 裸补点；
  - low-parallax track upgrade；
  - fragment merge；
  - rematch-starved repair；
  - live repay；
  - Dart 浮点删除或自研几何过滤。
- 点云显示策略已经冻结为：
  - 完整保存；
  - Review 全显；
  - Capture 稳定动态 LOD。

---

## 1. 绝对不能违反的安全约束

### 1.1 用户 iPhone 与 App 数据

用户日常使用的 App：

- Bundle ID：`com.kyle.PocketWorld`
- Signing Team：`26AH7V448L`
- 当前产品仓库版本：`1.0.0+1`

手机上的 App Data Container 是不可替代的用户数据。必须遵守：

1. **永远不要卸载 App。**
2. **永远不要为了调试而重新安装或先删后装。**
3. **永远不要运行会在清理阶段卸载生产 Bundle 的 `flutter drive`。**
4. **不要换 Bundle ID 后假装更新了生产 App。**
5. **不要下载或临时切换另一套 Flutter、Xcode、CocoaPods 或原生依赖。**
6. 用户已经明确确认：当前手机已安装最新版本。没有新代码需要上手机时，不要再次安装。
7. 若以后用户明确要求真机更新：
   - 先分别备份 `Documents` 和 `Library`；
   - 对每个复制文件做 SHA-256；
   - 验证备份；
   - 使用既有、已验证的 Flutter SDK、package cache、签名团队和本地原生产物；
   - Flutter 构建必须使用 `--no-pub`；
   - 构建输出放在 `/private/tmp`，不要放在 Documents/File Provider；
   - 验证 Bundle ID、深层签名、ABI 符号和 `PWBuildMarker`；
   - 只用 `devicectl device install app` 做原地更新；
   - 命令中不得出现 uninstall；
   - 更新后再次拉回 `Documents` 和 `Library`，逐文件验证更新前已有内容字节不变；
   - 仅 `Library/SplashBoard/Snapshots/**` 可从身份比对中排除；
   - 只有看到显式 `UPDATE_COMPLETE` 后才能报告更新完成。

### 1.2 当前手机版本

用户在本会话中已经确认手机安装了最新版本，不需要再次更新。

产品仓库 `Info.plist` 当前期望标记：

```text
PWBuildMarker = permanent-project-delete-20260725
```

注意：

- 本快照没有再次从手机容器读取并独立证明该 marker。
- “手机已是最新版”是用户本轮明确确认的状态。
- 不要为了再次验证 marker 而重新安装。

### 1.3 文件与 Git 安全

- 不要运行 `git reset --hard`。
- 不要运行 `git checkout -- <path>` 去覆盖用户改动。
- 不要运行 `git clean`。
- 不要 `git add -A` 或 `git add .`。
- 不要删除任何未跟踪研究产物、备份、数据库、PLY 或 `.bak` 文件。
- 不要把研究仓库的文件推到产品仓库。
- 不要把产品代码推到研究仓库。
- 只有用户明确要求 commit/push 时才提交和推送。
- 提交前必须逐文件暂存，只暂存本任务文件。

---

## 2. 权威来源顺序

发生冲突时按以下顺序判断：

1. 当前 Git 提交、代码、测试、配置、二进制和文件哈希。
2. 不可变实验 contract、输入 manifest、数据库表哈希、PLY 哈希和结果 JSON。
3. 当前手机的真实生产行为和可验证容器数据。
4. 已接受的仓库文档与本文件。
5. 对话摘要和历史截图。
6. 推测、记忆和未经复现的口头结论。

特别注意：

- 不要把 RealityScan 的未公开内部实现写成已确认事实。
- 不要把桌面实验写成生产结论。
- 不要把“点更多”自动等同于“质量更高”。
- 不要把 COLMAP 无法注册一张照片等同于产品可以替用户删除照片。

---

## 3. 仓库、分支、远端和当前提交

## 3.1 PocketWorld 产品仓库

本地路径：

```text
/Users/kaidongwang/Developer/pocketworld
```

远端：

```text
https://github.com/Kyle-Wang0211/pocketworld.git
```

分支：

```text
main
```

本快照核验时：

```text
HEAD        = fd87494d0fcbecb36623b4568eade6d582774119
origin/main = fd87494d0fcbecb36623b4568eade6d582774119
```

因此产品仓库最新产品改动已经推送，`main` 与 `origin/main` 一致。

### 3.1.1 产品仓库当前未跟踪文件

产品仓库没有已跟踪文件改动，但存在以下未跟踪文件。它们不是本次提示词工作产生的，不得自动删除、覆盖、暂存或提交：

```text
ios/scripts/run_permanent_delete_backup.command
vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a.bak_1783822185
vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a.bak_1783833129
vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a.bak_1783867289
vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a.bak_1783868903
vendor/official_sfm/PARITY_REPORT.md
vendor/official_sfm/PROVENANCE.md
vendor/official_sfm/README.md
```

### 3.1.2 产品仓库远端最近提交

从新到旧：

```text
fd87494 fix(drafts): permanently delete complete projects
688c62e feat(display): preserve full clouds with stable capture LOD
20e4939 fix(official): stop production at the COLMAP endpoint
3f9b53c fix(drafts): remove obsolete pipeline badges
6d6a660 refactor(capture): make the official route the single path
eaf8706 feat(official): harden the production phone pipeline
7410bb9 feat(official): ship independent ARKit reconstruction route
```

这些提交共同构成当前生产基线。不要从更早的双路线提交重新拣代码。

## 3.2 原生 Aether3D / COLMAP 集成仓库

本地路径：

```text
/Users/kaidongwang/Developer/Aether3D-cross
```

远端：

```text
https://github.com/Kyle-Wang0211/Aether3D.git
```

本快照读到：

```text
branch = claude/publish-to-community
HEAD   = b930ab185135dfbd172aef7c2bbeed67ef315f75
```

当前生产官方管线关键原生源文件：

```text
/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc
```

本快照 SHA-256：

```text
bcf7fb527e986b4257ee971814892e0e49b2a9d6366cd3bdce9def88a7d48bb6
```

注意：

- 不要只凭 Aether3D-cross 仓库 HEAD 判断手机里链接的二进制内容。
- 产品仓库 vendored framework、静态库、ABI 校验和上面源文件哈希一起才构成证据。
- 任何原生修改后都必须重新验证 source parity、ABI 和产品仓库实际 vendored 二进制。

## 3.3 研究仓库

本地路径：

```text
/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks
```

远端：

```text
git@github.com:Kyle-Wang0211/pocketworld-research-benchmarks.git
```

本地分支与状态：

```text
branch = diffmvs-mvs-validation
HEAD   = 4ede962d70bc78b8bb99e57dec9a6e015d25571f
origin/diffmvs-mvs-validation = 8edbf1bb66e75b303d80fde6ac08210826935617
local behind remote by 4 commits
tracked changes = 0
untracked files/directories = 61
```

远端包含但本地当前分支尚未吸收的主要提交：

```text
8edbf1b Merge remote-tracking branch 'origin/diffmvs-mvs-validation' ...
cb009cc docs: close verified B0 review tasks
2bb10e6 research: run controlled cap50 FuseCut vs TSDF benchmark
02dee86 research: archive frozen Aether3D research sources
```

不要自动 pull、rebase、merge、clean 或删除。若用户要求整理研究仓库，先另开一个严格的“只迁移研究资产、保护 61 个未跟踪产物”的任务。

### 3.3.1 已退休方向

DA3 已经不是当前主方向。

不要自动加载或复用：

```text
docs/da3_image_only_long_term_memory_2026-06-06.md
```

除非用户明确要求复盘 DA3 历史证据，否则它只作为历史材料存在。

---

## 4. 本地提示词与研究报告工作区

本目录不是产品 Git 仓库，主要存放提示词、报告与交接材料：

```text
/Users/kaidongwang/Documents/progecttwo
```

重要文件：

```text
L1L2_PRECEDENT_SEARCH_PROMPT.md
L1L2_PRECEDENT_SEARCH_REPORT_2026-07-20.md

COLMAP_QUADRATIC_OVERLAP_RESEARCH_PROMPT.md
COLMAP_QUADRATIC_OVERLAP_RESEARCH_REPORT_2026-07-20.md

FULLRES_MVS_AND_FUSECUT_RESEARCH_PROMPT.md
FULLRES_MVS_AND_FUSECUT_RESEARCH_REPORT_2026-07-21.md

CLEANUP_SYNC_AND_ROADMAP_PROMPT.md
CLEANUP_SYNC_AND_ROADMAP_REPORT_2026-07-21.md

EXECUTE_SYNC_AND_AV_BUILD_PROMPT.md
EXECUTE_REPORT_2026-07-21.md
EXECUTE_REPORT_V2_2026-07-21.md

EXECUTE_THREE_DECOUPLED_TASKS_PROMPT.md
THREE_PROMPTS_EXECUTION_REPORT_2026-07-21.md

REPO_SEPARATION_AUDIT_AND_MIGRATION_PROMPT.md
REPO_SEPARATION_AUDIT_2026-07-21.md

B0_TO_B3_EXECUTE_PROMPT.md
B0_B3_EXECUTION_REPORT.md
B0_MESHING_AB_REPORT.md
B1_B3_MIGRATION_REPORT.md

PLY_CLEANUP_EXECUTE_PROMPT.md
PLY_CLEANUP_REPORT_2026-07-21.md
PLY_DELETION_COMMIT_REPORT.md

POCKETWORLD_ABCDE_MASTER_HANDOFF_PROMPT_2026-07-16.md
POCKETWORLD_HANDOFF_ADDENDUM_2026-07-17.md

HANDOFF_STAGE1_ALIAS_继承_2026-07-19.md
HANDOFF_UI与Cauchy最终重建_2026-07-10.md
STAGE1_TRACK_TOPOLOGY_RESEARCH_DOSSIER_2026-07-17.md

AV_BUILD_REPORT.md
AV_BUILD_REPORT_v2.md
PUSH_REPORT.md
ICLOUD_REPORT.md
icloud_materialize_report.md
```

当前这份超级提示词：

```text
/Users/kaidongwang/Documents/progecttwo/POCKETWORLD_CURRENT_STATE_AND_NEXT_EXECUTION_PROMPT_2026-07-25.md
```

---

## 5. 已完成的产品改动

## 5.1 双路线已合并为单一生产路线

提交：

```text
6d6a660 refactor(capture): make the official route the single path
```

已完成：

- 删除旧自研 Flutter 拍摄页面副本。
- 删除旧自研 Swift ARKit Plugin。
- 删除拍摄前“自研 / 官方”选择 UI。
- 用户点击拍摄后直接进入当前官方路线。
- 保留当前生产所需的官方 Swift Plugin、MethodChannel、Dart 拍摄和 SfM 实现。

关键事实：

- 这是单一路线，不是两个按钮调用同一个函数。
- 不要重新引入旧双栈。

草稿卡片上的“官方”徽标已由以下提交删除：

```text
3f9b53c fix(drafts): remove obsolete pipeline badges
```

## 5.2 12MP 高分辨率输入

当前冻结行为：

1. AR 预览继续使用 `1920×1440`，保障相机流畅和照片卡瞬时出现。
2. 每次用户快门额外获得 `4032×3024`、12MP、4:3 静照。
3. 该静照与同帧 ARKit：
   - `fx`
   - `fy`
   - `cx`
   - `cy`
   - 相机位姿
   - 时间戳
   一起成为重建证据。
4. 进入重建前：
   - 不裁剪；
   - 不缩放；
   - 不做直方图拉伸；
   - 不偷偷混入 `1920×1440` 预览图。
5. 高分辨率 capture transaction 若遇到瞬时相机资源问题，走重试；不能静默降级。
6. 一旦 JPEG 文件写入和同帧元数据配对完成：
   - 立即加入项目；
   - 立即进入相册；
   - 立即进入唯一照片计数；
   - 随后异步进入 SIFT、匹配、注册和 BA。
7. SfM 暂时无法注册一张照片：
   - 照片仍保留；
   - 相册里标为红色断联；
   - 用户可查看、删除或重拍；
   - 产品不得替用户删除。

关键文件：

```text
/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/capture_session.dart
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/official_highres_reconstruction_input.dart
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/project_photo_album.dart
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/sfm_live_recon.dart
/Users/kaidongwang/Developer/pocketworld/vendor/official_sfm/src/pwofficial_jpeg_decode.mm
```

相关测试：

```text
test/official_highres_reconstruction_contract_test.dart
integration_test/official_highres_reliability_test.dart
test/official_per_image_pinhole_contract_test.dart
test/official_photo_user_control_contract_test.dart
test/official_project_photo_album_test.dart
```

## 5.3 每图独立 PINHOLE 相机和 ARKit 已知内参

当前路线：

- 每张 `4032×3024` 照片拥有独立 COLMAP `PINHOLE` camera。
- 每张 image 绑定自己的 camera ID。
- 参数来自同一高分辨率 ARFrame 的：
  - `fx`
  - `fy`
  - `cx`
  - `cy`
- BA 固定这些 ARKit 内参，只优化位姿和三维点。
- 两视图几何、归一化射线、三角化、重投影使用 COLMAP 原生相机接口。
- 保留自动对焦。

这一步替换了早期所有图像共享 `SIMPLE_PINHOLE`、焦距取首帧 `fx/fy` 均值的错误近似。

用户真机观察：

- 旧版本“未命名（1）”杯子发生明显分裂，约 `7815` 点。
- 每图 PINHOLE 版本“未命名（2）”杯子结构更完整，约 `9754` 点。

这是用户的真机肉眼证据，不是严格同源 A/B；不要把它伪装成唯一变量实验，但它支持继续保留每图已知内参方案。

## 5.4 当前 SIFT 和 matcher 配置

当前生产运行时在：

```text
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/sfm_live_recon.dart
/Users/kaidongwang/Developer/pocketworld/lib/official_aether_sfm_ffi.dart
```

明确配置：

```text
maxFeatures = 8192
kNeighbors  = 12
match ratio = 0.8
useGpuMatch = true
useGpuExtract = true
```

当前特征栈：

```text
GPU DSP-SIFT + Affine + RootSIFT
```

当前 matcher：

```text
Metal FP16
mutual cross-check
ratio = 0.8
```

当前生产 stream 默认：

```text
AetherSfmStreamSession.researchMaxFeatures = 8192
AetherSfmStreamSession.researchKNeighbors = 12
AetherSfmStreamSession.defaultMatchMaxRatio = 0.8
```

注意：

- `AetherSfm.run(...)` 的非 streaming 包装器仍有 `2048/K6` 默认值。
- `vendor/official_sfm/include/official_sfm_c.h` 的注释也可能出现 `2048` validated config。
- 不能只读头文件默认值就宣称生产正在 K6。
- 当前拍摄 worker 明确用 `8192/K12` 创建 streaming session。
- resume 路径也显式用 `researchMaxFeatures/researchKNeighbors`。

## 5.5 拍摄期全局 BA 发布调度

关键文件：

```text
/Users/kaidongwang/Developer/pocketworld/lib/official_capture/live_sfm_publish_policy.dart
```

当前冻结值：

```text
kOfficialMinimumCaptureFrames = 20
kOfficialGlobalBaGrowthRatio = 1.40
```

规则：

1. 少于 20 个已接受帧：
   - 用户不能结束；
   - UI 提示至少拍满 20 张。
2. 第一次满足 20 个已注册相机且已有点：
   - 启动首次完整全局 BA；
   - 成功后发布第一个稳定点云版本。
3. 后续触发为一个统一 OR 条件：
   - 已注册相机数相对上次成功发布增长至少 40%；或
   - 重建点数相对上次成功发布增长至少 40%。
4. 成功发布会同时重置相机数与点数两个基线。
5. 没有“固定节点 + 点数阈值”两套独立时钟。
6. 如果没有提前被点数增长触发，纯相机数近似节点为：

```text
20 → 28 → 40 → 56 → 79 → ...
```

7. 上一次 BA 还没完成时，不并发启动下一次 BA。
8. 一轮完成后，如果队列已达到下一阈值，可继续启动下一轮。
9. BA 失败不提交发布基线，下一次更新必须重试。
10. 用户结束拍摄时：
    - 等待已经点击快门、仍在队列或处理中但尚未并入的合法照片；
    - 把全部已接受、可注册照片纳入；
    - 对全部已注册相机执行最终全局 BA；
    - 再输出最终 PLY。

相关测试：

```text
test/official_live_sfm_publish_policy_test.dart
test/official_capture_twenty_frame_ui_contract_test.dart
```

## 5.6 官方 COLMAP 终点

提交：

```text
20e4939 fix(official): stop production at the COLMAP endpoint
```

关键原生开关：

```cpp
constexpr bool kProductionOfficialEndpointOnly = true;
```

文件：

```text
/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc
```

当前生产允许的官方操作包括：

```text
CompleteAndMergeTracks
Retriangulate
AdjustGlobalBundle / final global BA
FilterPoints
必要的官方 frame filtering
```

当前生产禁用：

```text
RestoreTemporalDetail
AddSpatialRevisitMatches
自研 repair/enrichment
low-parallax track upgrade
fragment merging
finalize rematch-starved repair
live repay
BA/过滤后的裸补点
Dart floater filter
```

为什么：

- 之前生产 Metal 结果有大量远处漂浮点。
- 受控 A/B 证明，当两边都停在官方最终全局 BA 与官方过滤后，Metal 和 CPU 精确 matcher 几乎一致。
- 之前的大差距没有在官方终点复现。
- 因而主要问题来自官方 BA/过滤之后继续添加、修补或删除点的自研流程，而不是 Metal matcher 本身。

重要执行纪律：

- 如果以后有人提出恢复任何 detail/repair：
  - 必须先证明它是官方算法；
  - 必须放在最终一次官方全局 BA/过滤之前；
  - 不能在终点后直接追加未经最终求解的点。
- 用户已经明确决定：既然这些步骤不是官方，就保持禁用。

相关测试：

```text
test/official_stop_production_contract_test.dart
```

## 5.7 稀疏点云保存与显示

提交：

```text
688c62e feat(display): preserve full clouds with stable capture LOD
```

用户签定的产品原则：

```text
完整保存、Review 全显、Capture 稳定动态 LOD
```

### 5.7.1 完整保存

- 最终 PLY 保存全部官方终点点。
- LOD 不能改写 PLY。
- LOD 不能删除点。
- LOD 不能改变重建结果。
- 渐进顺序只是 display-only copy。

### 5.7.2 Review 全显

Review viewer：

- `drawStrideFor = 1`
- `drawCountFor = pointCount`
- 显示每一个持久化 PLY 点。
- 不再限制为约 22,000 或 27,000 个抽样点。

关键文件：

```text
/Users/kaidongwang/Developer/pocketworld/lib/ui/official_capture/sparse_cloud_view.dart
/Users/kaidongwang/Developer/pocketworld/lib/point_cloud_display/progressive_octree_order.dart
```

### 5.7.3 Capture 动态 LOD

Capture 中完整渐进点云驻留，按稳定前缀动态绘制。

当前层级：

```text
1.00
0.67
0.40
0.25
```

当前规则：

```text
点数 <= 24,000：全显
最低绘制数：12,000
决策窗口：2 秒
FPS < 24：快速降一级
FPS >= 28.5 且健康持续 8 秒：升一级
thermal serious：至少降到 40%
thermal critical：降到 25%
```

特性：

- 每一级都是同一渐进 octree 顺序的严格前缀。
- 降级或升级不会重新洗牌仍然显示的点。
- 保存与 Review 不走此预算控制。

借鉴来源：

```text
Potree revision:
5636cd471d9eb464969e758be45c44d7613d3859
```

许可：

```text
BSD-2-Clause
```

许可与 notice 已写入：

```text
/Users/kaidongwang/Developer/pocketworld/THIRD_PARTY_NOTICES
```

关键实现：

```text
lib/point_cloud_display/progressive_octree_order.dart
lib/ui/official_capture/ar_capture_page.dart
lib/ui/official_capture/sparse_cloud_view.dart
ios/Runner/OfficialAetherARKitPlugin.swift
```

测试：

```text
test/point_cloud_display_policy_test.dart
test/point_cloud_display_integration_contract_test.dart
```

## 5.8 AR 照片卡随距离缩放

用户最终签定：

> 拍摄位置保持原始尺寸；离开拍摄相机位置约 3 厘米时，视觉尺寸只剩约 20%，即缩小约 80%；后续很快进入平缓变化。

当前常量：

```text
photoCardMinVisualScale = 0.08
photoCardVisualTransitionM = 0.0045
photoCardMaxNodeScale = 2.0
```

当前曲线：

```text
visualScale =
  minScale +
  (1 - minScale) / (1 + travel / transition)
```

约束点：

```text
0 cm   ≈ 1.00
3 cm   ≈ 0.20
10 cm  ≈ 0.12
20 cm  ≈ 0.10
1 m    ≈ 0.084
```

同时补偿相机到固定照片卡 anchor 的透视变化，避免用户移动方向导致卡片忽大忽小。

文件：

```text
/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift
```

测试：

```text
test/photo_card_distance_scale_contract_test.dart
```

## 5.9 草稿项目永久删除

提交：

```text
fd87494 fix(drafts): permanently delete complete projects
```

用户定义的“删除”是：

> 删除该项目代表的全部本地数据，而不是只从草稿列表移除一张卡片。

当前实现：

1. 先写入不含明文项目 ID 的 SHA-256 tombstone。
2. 删除 canonical capture directory。
3. 若记录中的 stored capture directory 位于合法 route namespace，也递归删除。
4. 删除该项目在 `scans` namespace 下：
   - 精确等于项目 ID 的文件/目录；
   - 以 `<id>.` 开头的所有 artifact。
5. 删除的内容包括：
   - 12MP 原图；
   - preview；
   - AR metadata；
   - manifest；
   - SQLite/database；
   - SIFT/match/BA cache；
   - PLY；
   - GLB 等扫描 artifact；
   - 项目目录；
   - 草稿卡片和索引记录。
6. tombstone 阻止：
   - 中断删除后项目复活；
   - orphan recovery 把已删项目重新加回来；
   - 晚到的 finalize callback 重新写回记录。
7. 删除活跃重建项目时：
   - 先释放 Dart/native reconstruction resource；
   - 再删除完整 namespace。

关键文件：

```text
lib/me/scan_record_store.dart
lib/ui/me_page.dart
lib/ui/official_capture/ar_capture_page.dart
```

测试：

```text
test/project_delete_copy_test.dart
test/scan_record_artifact_namespace_test.dart
test/scan_record_pipeline_kind_test.dart
```

当前 build marker：

```text
permanent-project-delete-20260725
```

## 5.10 草稿页 `+` 按钮

冻结 UX：

- 任何看起来是草稿页的界面，右下角 `+` 永远显示。
- 重建进行中：
  - `+` 仍显示；
  - 点击后提示“当前任务正在重建”；
  - 不启动第二次拍摄；
  - 性能留给重建。
- 重建成功或失败进入终态后：
  - 立即释放拍摄路由；
  - 回到真正草稿页；
  - `+` 恢复正常拍摄。

不要再用“隐藏按钮”表达忙状态。

---

## 6. 用户已经完成的真机验证与观察

以下是用户完成的真机测试和肉眼结果。它们是重要产品证据，但除特别说明外，不是严格同源唯一变量 A/B。

## 6.1 12MP 采集

- 新版拍摄过程没有明显卡顿。
- 约二十多帧已经得到八千多点，比更早版本明显好。
- 12MP capture 失败提示曾出现过，后来通过 capture transaction 与重试路径修复。
- 不能恢复静默降级到 1920 预览图。

## 6.2 每图 PINHOLE

- “未命名（1）”：约 `7815` 点，杯子出现明显双层/分裂。
- “未命名（2）”：约 `9754` 点，结构与覆盖改善。

## 6.3 后续生产作品

- “未命名（3）”：用户观察点数约 `11438`，是早期调度/相机模型更新后的重要真机样本。
- “未命名（4）”：ratio 0.8 后，照片更少但点数更多，用户观察覆盖改善。
- “未命名（5）”：
  - capture ID：`cap_1784860918349292`
  - 85 张照片
  - 手机旧 Review 标题显示 `109287` 点
  - 是当前 matcher 诊断与官方终点 A/B 的冻结素材。

## 6.4 Metal 与 CPU matcher

用户肉眼确认：

- 旧生产 Metal 输出曾有明显更多远处漂浮点。
- 当两边都停在官方最终 BA/过滤终点，并做仅展示用 Sim(3) 对齐后，两组几乎没有可见差异。
- 用户接受把“官方终点”改动加入手机生产线。

---

## 7. 冻结的 matcher A/B 诊断

## 7.1 实验定位

根目录：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725
```

输入：

```text
作品：未命名（5）
capture ID：cap_1784860918349292
帧数：85
同一批 AR 数据
同一批 SIFT/keypoints/descriptors
同一 K12 配对计划
固定计划配对数：942
ratio：0.8
COLMAP：4.1.0
COLMAP commit：fa8e3b3
```

配对计划：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/pair_plan_942_temporal_k12.jsonl
```

SHA-256：

```text
8773710a88c84e8e43d569437f014a115b663d1daa9965121ce46d2da15e0667
```

实验 contract：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/experiment_contract.json
```

结果总表：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/result_summary.json
```

匹配数据库证据：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/evidence/match_database_summary.json
```

## 7.2 实验控制

两边相同：

- 85 张图；
- AR 数据；
- cameras；
- images；
- keypoints；
- descriptors；
- pose priors；
- K12 的 942 对计划；
- ratio 0.8；
- mapper；
- 最终全局 BA；
- 官方过滤；
- exporter；
- 取色逻辑；
- viewer。

唯一变量：

```text
A = 生产 Metal matcher 缓存
B = CPU exact matcher
```

两边都禁止：

```text
RestoreTemporalDetail
repair/enrichment
Dart floater filter
```

实验分类：

```text
host_diagnostic_only
```

它不能直接选生产 winner。

## 7.3 A：Metal 结果

```text
raw matches          = 903606
geometric inliers    = 824487
registered cameras   = 85
points               = 65990
observations         = 277143
mean track length    = 4.1997726928
reproj mean          = 1.0230197838 px
reproj p50           = 1.0368660591 px
reproj p90           = 1.6713062666 px
reproj p95           = 1.8312769044 px
solver               = 35488.579 ms
```

真彩 PLY：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/A_metal/official_stop_output/A_metal_official_stop_truecolor.ply
```

## 7.4 B：CPU 精确 matcher 结果

```text
raw matches          = 903606
geometric inliers    = 824345
registered cameras   = 85
points               = 65829
observations         = 276941
mean track length    = 4.2069756490
reproj mean          = 1.0223154681 px
reproj p50           = 1.0345429368 px
reproj p90           = 1.6731063092 px
reproj p95           = 1.8312900717 px
solver               = 35726.9575 ms
```

真彩 PLY：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/B_cpu_exact/official_stop_output/B_cpu_exact_official_stop_truecolor.ply
```

仅用于显示对齐到 A gauge 的 PLY：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/B_cpu_exact/official_stop_output/B_cpu_exact_official_stop_truecolor_display_aligned_to_A.ply
```

显示 Sim(3) 报告：

```text
/private/tmp/pw_matcher_official_stop_temporal942_20260725/B_cpu_exact/official_stop_output/display_sim3_B_to_A.json
```

显示对齐规则：

- 只用 85 个共有照片的相机中心求 Sim(3)。
- 不使用点云 ICP。
- 不删点。
- 不滤点。
- 不重着色。
- 不重排序。
- 原始 PLY 保持不变。

## 7.5 B-A 差值

```text
raw matches          = 0
geometric inliers    = -142
registered cameras   = 0
points               = -161
points percent       = -0.243976%
observations         = -202
mean track length    = +0.007203
reproj mean          = -0.000704 px
reproj p50           = -0.002323 px
reproj p90           = +0.001800 px
reproj p95           = +0.000013 px
solver               = +238.378 ms
```

## 7.6 当前结论

结论只限这个冻结 host diagnostic：

1. 官方终点上的 matcher 差异可忽略。
2. 之前 Metal 侧大量远处漂浮点没有复现。
3. 主要根因更可能是官方 BA/过滤结束后的自研加点、repair/enrichment 与处理顺序。
4. 生产保留 Metal matcher。
5. 不要因为 CPU 精确 matcher “跨端”就迁移生产：
   - CPU 版本在手机上过慢；
   - 后台容易暂停；
   - host 结果不代表 iPhone 的 Metal、热调度和生产总耗时；
   - 当前质量并没有出现足够差距。

## 7.7 历史 viewer 资产

旧 A/B viewer：

```text
/private/tmp/pw_matcher_ab_truecolor_viewer_20260724
```

主要文件：

```text
A_metal_truecolor_colored.ply
A_phone_unnamed5_truecolor.ply
B_cpu_exact_correct_942_truecolor.ply
B_cpu_exact_truecolor_colored.ply
index_phone_parity.html
```

这些文件对历史排错有用，但正式“官方终点”比较应以 2026-07-25 实验目录为准。

---

## 8. 当前手机数据安全备份

备份根目录：

```text
/private/tmp/pw_project_delete_update.Z3Av1y
```

备份内容：

```text
/private/tmp/pw_project_delete_update.Z3Av1y/before/Documents
/private/tmp/pw_project_delete_update.Z3Av1y/before/Library
```

大小：

```text
Documents ≈ 1.8 GB
Library   ≈ 24 MB
```

文件数：

```text
Documents = 1370
Library   = 22
```

身份 manifest：

```text
/private/tmp/pw_project_delete_update.Z3Av1y/Documents.before.sha256
/private/tmp/pw_project_delete_update.Z3Av1y/Library.before.sha256
```

说明：

- Documents manifest 含 1370 个文件。
- Library 一共复制 22 个文件。
- Library 身份 manifest 含 14 个文件。
- 另 8 个是 `Library/SplashBoard/Snapshots/**`，按原地更新 runbook 明确排除身份比对。

备份里的项目记录：

```text
/private/tmp/pw_project_delete_update.Z3Av1y/before/Documents/scan_records.json
```

该文件 SHA-256：

```text
674ba7e045765b361bb64c4c11e8ef839fa4affabbd84f4545bc373bae178002
```

## 8.1 备份时的四个有效草稿记录

```text
cap_1784860918349292
名称：未命名(5)
照片：85
目录大小：约 938 MB

cap_1784820270338819
名称：未命名(9)
照片：4
目录大小：约 16 MB

cap_1784830836808715
名称：未命名(10)
照片：50
目录大小：约 191 MB

cap_1784826668164867
名称：未命名(8)
照片：3
目录大小：约 13 MB
```

## 8.2 备份中发现的历史 orphan capture 目录

这些是旧版本留下、但不在当前 `scan_records.json` 四张草稿卡里的目录：

```text
cap_1784792081923324  ≈ 102 MB
cap_1784802118882656  ≈ 113 MB
cap_1784809021393372  ≈ 145 MB
cap_1784814888131788  ≈ 124 MB
cap_1784817643453993  = 0 B
cap_1784819644690781  ≈ 12 MB
cap_1784820775062947  ≈ 158 MB
cap_1784822525603889  ≈ 8.7 MB
```

总计约 664 MB。

重要：

- 这些旧 orphan 只在备份中被盘点。
- 没有自动从手机删除。
- 不要自行清理。
- 用户当前签定的是：新版本从现在起，用户在草稿页确认删除项目时删除完整项目 namespace。
- 如果以后用户明确要求清理历史 orphan，必须另做一次：
  - 记录关联审计；
  - 明确清单；
  - 用户确认；
  - 可恢复备份；
  - 再执行删除。

候选 tombstone 文件：

```text
/private/tmp/pw_project_delete_update.Z3Av1y/scan_record_deletion_tombstones.json
```

它没有复制到手机，不要擅自应用。

---

## 9. 最新一轮测试证据

永久删除提交 `fd87494` 前已完成：

```text
flutter test --no-pub --concurrency=1
结果：+150 All tests passed
```

删除相关 targeted tests：

```text
29 tests passed
```

其他：

```text
git diff --check = clean
```

已知情况：

- 并发测试时曾有一次旧 badge test 的并行抖动。
- 单独跑通过。
- `--concurrency=1` 完整 suite 通过。
- targeted analyze 有 5 个 `ar_capture_page.dart` 既有 unused-element warning，没有新 error。

注意：

- 这是提交 `fd87494` 时的证据。
- 如果当前 HEAD 在本文件之后发生改变，必须重新跑相应测试。

---

## 10. 当前仍然存在的官方对齐差异

不要把当前路线描述为“100% 官方 COLMAP 复刻”。现在是：

> 以官方 COLMAP 求解接口和官方终点为内核，使用 ARKit 高质量输入与移动端调度，同时仍保留若干非官方 feature、candidate pairing、AR prior 和 capture-time orchestration。

## 10.1 特征提取仍是核心差异

当前生产：

```text
GPU DSP-SIFT
Affine
RootSIFT
max 8192
```

官方 COLMAP 默认 SIFT：

- DSP 默认关闭；
- Affine 默认关闭；
- octave、peak threshold、edge threshold、normalization 与当前移动实现可能不同；
- 官方 CPU/CUDA extractor 与当前 Metal extractor 的数值和调度也不同。

这是下一阶段最值得做的受控差异之一。

但是不要立刻改：

1. 先完整列出当前 effective option。
2. 锁定官方 COLMAP 4.1.0 `fa8e3b3` 对应默认值与实现。
3. 冻结同一批手机原图、AR 内参/位姿和配对计划。
4. 只替换 feature extractor 配置或一个 feature 参数。
5. 生产接受必须在物理 iPhone 实际管线完成。

## 10.2 Candidate pairing 不是纯官方 sequential 默认

当前生产：

- K12；
- 存在 AR spatial-first、temporal fallback 和 capture-time 调度；
- 热状态曾允许 live window 降级，最终路径历史上有补偿逻辑；
- 当前官方终点模式禁用了若干自研 repair，但 candidate generation 本身仍需完整盘点。

官方 COLMAP sequential matcher 有自己的：

- overlap；
- loop detection；
- quadratic overlap；
- matching order；
- pairing semantics。

历史研究已经证明：

- 不要把旧 COLMAP quadratic 理解成“固定跳过 gap 3、5、6、7”。
- 旧实现长期是 additive 的 linear + power-of-two reach。
- 2024 代码又恢复为互斥语义。
- 当前 PocketWorld K12 不是对官方 sequential 的字面复制。

下一步必须先做 effective pair plan inventory，不要把 feature 和 pairing 同时改。

## 10.3 AR 输入与官方 mapper 的关系

当前每张照片带完整：

- ARKit rotation；
- translation；
- gravity/world alignment；
- metric scale；
- timestamp；
- per-image intrinsics。

这些是优质数据，应继续保留。

但是必须区分：

- “提供 AR prior”；
- “固定 AR pose”；
- “用 AR pose 直接注册”；
- “COLMAP 自己估计位姿后只用于 Sim(3)/gauge”。

当前代码说明：

- ARKit pose prior 用于 AR-world live preview/local BA path。
- authoritative finalize 仍从 image matches 估计 SfM camera poses。

下一次对齐任务必须先画清楚当前数据流，不能只说“使用 AR”。

## 10.4 轨迹创建与 capture-time BA 调度

早期代码包含自研：

```text
create / grow / merge
10 / 14 / 8 px 等门槛
raw fallback
W12 local BA
Cauchy
最多 5 轮
```

当前官方终点禁用了后置修补，但 live capture 阶段仍需审计：

- 哪些行为是官方 COLMAP correspondence graph / incremental triangulator 的直接调用；
- 哪些是自研 track create/grow/merge；
- 哪些只影响预览；
- 哪些会进入最终数据库与最终 BA；
- 哪些已被 `kProductionOfficialEndpointOnly` 实际短路。

不要靠注释猜，必须从调用图、runtime counter 和数据库表证明。

## 10.5 RealityScan 仍有未确认项

公开资料不足以 100% 证明：

- RS 在第 20 张何时进行局部或全局 BA；
- RS 是否显示全部稀疏点；
- RS 的 Capture 点云是否动态抽样；
- RS 的 matcher ratio 是否恰为 0.8；
- RS 的具体 SIFT variant、配对计划和云端调度；
- 红、黄、绿点的全部内部语义；
- 第 21、22 张后的确切全局 BA 触发策略。

当前产品对 RS 的复刻是基于：

- 可观察 UX；
- 官方 COLMAP video-oriented 1.40 增长规则；
- AR overlay 产品需求；
- 受控实验与真机表现。

不要把推断升级为“RS 官方确认”。

---

## 11. 下一阶段建议顺序

## P0：先保护当前生产基线

开始前：

```text
cd /Users/kaidongwang/Developer/pocketworld
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

预期：

```text
HEAD = origin/main = fd87494d0fcbecb36623b4568eade6d582774119
```

如果不一致：

- 不要 reset；
- 不要覆盖；
- 先报告发生在本快照后的提交和工作树状态。

手机已经是当前版本，不要安装。

## P1：真机验证“官方终点 + 全显/LOD + 永久删除”

只在用户同意使用可丢弃的新项目时做。

检查：

1. 12MP 拍摄：
   - 每次快门不卡 UI；
   - 照片卡瞬时出现；
   - JPEG/metadata 成功后立即计数；
   - 不出现静默 1920 fallback。
2. 前 20 张：
   - 不能结束；
   - 提示至少拍 20 张。
3. 第 20 张后：
   - 首次稳定全局 BA；
   - 点云出现。
4. 后续：
   - 1.40 增长触发；
   - BA 不并发；
   - 旧点云保持稳定，成功后原子替换。
5. 最终：
   - 等待全部已点击照片；
   - 全部已注册相机进入最终 BA；
   - 官方过滤结束后直接输出；
   - 不执行后置自研加点/删点。
6. Review：
   - 标题点数与实际 PLY vertex count 一致；
   - 全点绘制；
   - 不再只有约四分之一。
7. Capture LOD：
   - 小云全显；
   - 大云在热压/FPS 下稳定降级；
   - 不闪烁、不重新洗牌；
   - 退出 Capture 后最终文件不变。
8. 永久删除：
   - 只对新建的可丢弃测试项目；
   - 确认删除后卡片消失；
   - capture dir、photos、metadata、db、cache、PLY、scan artifact 全部消失；
   - 重启 App 后不复活。

## P2：特征提取受控对齐

先写 experiment contract，再改代码。

不可变输入：

- 同一物理 iPhone 捕获；
- 同一 12MP 原图；
- 同一 AR intrinsics/pose；
- 同一 candidate pair plan；
- 同一 matcher；
- 同一 mapper；
- 同一 BA；
- 同一 filtering；
- 同一 exporter；
- 同一 viewer。

唯一变量候选按顺序拆开：

1. DSP 开/关；
2. Affine 开/关；
3. RootSIFT 与官方 normalization；
4. max features；
5. peak threshold；
6. octave 设置；
7. Metal extractor 与官方参考 extractor。

每次只能一项。

指标：

```text
特征提取耗时
总重建耗时
每帧 keypoint 数与分位数
raw matches
几何内点
注册相机
点数
observations
track length 分布
reprojection mean / p50 / p90 / p95 / max
覆盖
双层/分裂
漂浮点
热状态
队列深度
快门响应
最终 PLY hash
```

生产 winner 只能由物理 iPhone end-to-end 决定。

## P3：Candidate pairing 对齐

先只做盘点：

1. 导出生产实际 pair plan。
2. 区分：
   - spatial-first；
   - temporal fallback；
   - pure temporal；
   - quadratic；
   - 热降级；
   - finalize 中实际仍会运行的补偿。
3. 对比官方 COLMAP 4.1.0 `fa8e3b3` sequential matcher。
4. 冻结输入后逐项测试：
   - K12 当前；
   - 官方 sequential overlap；
   - quadratic 开关语义。

不要和 feature extractor 同时改。

## P4：AR prior 与官方 mapper 调用图

目标不是删 AR，而是证明每一项 AR 数据在哪里使用：

```text
12MP intrinsics
pose prior
world gravity
metric scale
timestamp
camera center
AR preview overlay
final SfM pose
viewer gauge
```

产出应该是一张调用图和表格：

```text
输入字段
源头
坐标系
时间同步
消费函数
是否固定
是否只用于初始化
是否进入最终优化
是否影响最终 PLY
```

## P5：审计剩余非官方处理

逐项列出，不要一次重写：

```text
feature extractor
matcher backend
candidate pair generation
AR prior usage
live track creation
local BA window
global BA publication scheduler
capture-time filtering
final official filtering
colorization
display-only LOD
photo diagnostics
```

为每项标记：

```text
官方 COLMAP 原生
官方 API 的移动适配
AR 数据增强
产品 UX 调度
自研改变几何
仅显示
已禁用历史代码
未确认
```

## P6：磁盘与历史 orphan

当前删除修复只保证：

- 现在的项目删除完整；
- tombstone 阻止复活；
- 未来不会只删卡片不删 namespace。

历史 orphan 没有清理。

只有用户明确提出时，才能处理备份中约 664MB 的历史 orphan。

## P7：研究仓库同步

研究仓库本地落后远端 4 个提交且有 61 个未跟踪产物。

若要同步：

1. 先做完整状态清单。
2. 备份或固定未跟踪资产。
3. 不在产品仓库操作。
4. 不把 DA3 重新定为主线。
5. 不自动删除大文件。
6. 单独汇报合并冲突与远端新增内容。

---

## 12. 实验纪律

每次算法实验必须先冻结：

```text
product git revision
native source hash
vendored binary hash
effective config
ordered input manifest/hash
AR metadata manifest/hash
pair plan/hash
feature manifest/hash
database table hashes
random seeds
command
hardware/backend
thermal state
metrics
thresholds
stop rules
artifacts
deviations
verdict
```

### 12.1 必须保留失败实验

- 失败不能删。
- 标记 failed / invalid / diagnostic / comparable。
- 不能只留成功图。
- 偏离 contract 后结果不得和基线直接比较。

### 12.2 控制变量

用户非常重视控制变量。

不能：

- 同时改 ratio、feature、pairing、BA 和 filter；
- 用不同拍摄重建后宣称一个参数赢；
- 用桌面 CPU 结果决定手机生产；
- 用不同 viewer 对比两个算法；
- 用点云 ICP 把算法差异“对齐掉”；
- 为了视觉好看改变点数、颜色、点大小后再比较几何。

### 12.3 Viewer 固定

任何 A/B：

- 同一 viewer；
- 同一初始相机；
- 同一投影；
- 同一点大小；
- 同一颜色处理；
- 同一背景；
- 同一同步旋转/缩放/平移；
- 必要的 gauge 对齐只使用共有相机中心 Sim(3)；
- 不使用点云 ICP；
- 原始 PLY 不改。

---

## 13. 不要做的事

1. 不要重装手机 App。
2. 不要让用户再次登录。
3. 不要丢失本地草稿。
4. 不要把手机实验换成桌面实验后仍声称完成生产验证。
5. 不要再建立“自研 / 官方”选择器。
6. 不要恢复草稿卡片“官方”徽标。
7. 不要恢复旧自研 Swift Plugin。
8. 不要恢复旧自研 Dart capture 页面。
9. 不要把 CPU exact matcher 塞进手机生产。
10. 不要在官方 BA/过滤之后补点。
11. 不要恢复 Dart floater filter。
12. 不要用更强删点阈值掩盖产生源头。
13. 不要自动删除 SfM 无法注册的照片。
14. 不要隐藏草稿页 `+`。
15. 不要让重建中点击 `+` 启动第二任务。
16. 不要把 1920 预览图作为 12MP 失败 fallback。
17. 不要同时改多个算法变量。
18. 不要把 RealityScan 推测写成官方事实。
19. 不要清理产品仓库未跟踪 `.bak`、报告或 helper。
20. 不要清理研究仓库的 61 个未跟踪资产。
21. 不要自动 pull/rebase 研究仓库。
22. 不要为了“安全”增加用户未要求的新护栏并改变任务目标。
23. 不要写多余规划文档代替执行；用户要求代码时应直接实施、测试和真机验证。

---

## 14. 下一任务开始时的精确检查

先只读执行：

```bash
cd /Users/kaidongwang/Developer/pocketworld
git status --short --branch
git remote -v
git rev-parse HEAD
git rev-parse origin/main
git log --oneline -n 12
plutil -p ios/Runner/Info.plist
```

然后核对关键源文件：

```bash
rg -n "kProductionOfficialEndpointOnly" \
  /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc

shasum -a 256 \
  /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc

rg -n "researchMaxFeatures|researchKNeighbors|defaultMatchMaxRatio|maxFeatures: 8192" \
  lib/official_aether_sfm_ffi.dart \
  lib/official_capture/sfm_live_recon.dart

rg -n "kOfficialMinimumCaptureFrames|kOfficialGlobalBaGrowthRatio" \
  lib/official_capture/live_sfm_publish_policy.dart
```

检查本地证据仍存在：

```bash
test -f /private/tmp/pw_matcher_official_stop_temporal942_20260725/result_summary.json
test -f /private/tmp/pw_matcher_official_stop_temporal942_20260725/experiment_contract.json
test -f /private/tmp/pw_project_delete_update.Z3Av1y/Documents.before.sha256
test -f /private/tmp/pw_project_delete_update.Z3Av1y/Library.before.sha256
```

若任一 `/private/tmp` 资产已被系统清理：

- 不要声称它仍可恢复；
- 用本文件记录的哈希和 Git 资产判断哪些证据仍可重建；
- 不要从手机重新拷贝“未命名（5）”或安装 App，除非用户明确授权。

---

## 15. 当前验收基线

任何新改动至少要满足：

### 15.1 代码

- `git diff --check` 通过。
- targeted tests 通过。
- 完整 Flutter suite 以 `--no-pub --concurrency=1` 通过，或明确记录阻塞原因。
- 无新的 analyze error。
- 原生 source parity 与 ABI 验证通过。
- 产品仓库不意外暂存未跟踪文件。

### 15.2 数据

- 不改变现有用户项目。
- 不删除原图。
- 不把失败注册等同于删除。
- PLY vertex count 与 Review 显示一致。
- Capture LOD 不改变保存点。

### 15.3 生产实验

- 物理 iPhone。
- 实际生产 Bundle 与实际移动管线。
- immutable capture copy。
- 单一变量。
- 指标、输入 hash、配置和产物完整。
- 不以 host 结果宣布生产 winner。

---

## 16. 执行后的报告格式

每次任务完成后必须简洁但具体地报告：

```text
目标：

产品仓库：
branch：
before commit：
after commit：
remote：

改动文件：

唯一变量：

未改变项：

测试命令与结果：

真机验证：

数据安全：

实验输入/manifest/hash：

产物路径/hash：

结论：

偏差与未决风险：

下一步：
```

如果没有真机验证，必须写：

```text
本轮只有 host diagnostic，不能作为生产接受证据。
```

---

## 17. 最终工作判断

当前版本已经完成了一个重要阶段：

1. 12MP 4:3 原图与同帧 AR 数据进入单一生产路线。
2. 每图独立 PINHOLE 与已知 ARKit 内参显著改善结构稳定性。
3. matcher ratio 已统一到 0.8。
4. 拍摄期全局 BA 发布调度统一为官方 video-oriented 1.40 增长规则。
5. 生产求解停在官方最终 BA/过滤终点。
6. 后置自研加点、repair/enrichment 和 Dart 浮点过滤已禁用。
7. Metal 与 CPU exact 在官方终点差异几乎可忽略。
8. 最终点云完整保存，Review 全显，Capture 使用稳定动态 LOD。
9. 草稿项目删除现在是完整项目 namespace 的永久删除。
10. 产品单一路线与草稿 UI 已简化。

下一阶段不要大改整条线。最优路径是：

> 先用当前稳定版本做一次受控真机验收，然后从“特征提取”开始，每次只对齐一个官方差异；之后才轮到 candidate pairing、AR prior/mapper 关系和 live track/BA 调度审计。

如果新执行者不能证明一个修改来自官方 COLMAP、已审计的成熟开源实现或严格受控的产品实验，就不要把它写进生产算法。

