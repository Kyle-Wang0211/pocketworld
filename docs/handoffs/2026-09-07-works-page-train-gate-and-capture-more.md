# 作品页「开始训练」闸 + 追加拍摄（2026-09-07）

## 起因（实机指认）

用户在作品页看到「未命名(24)」是 **未完成** 状态、照片不足 20 张，却照样能点
「继续重建」开始训练。

查下来：**20 张的判定全 app 只有一处** —— 拍摄页「结束任务」按钮上的
`officialCaptureCanFinish`（`lib/ui/official_capture/ar_capture_page.dart:3409`，
常数 `kOfficialMinimumCaptureFrames = 20` 在
`lib/official_capture/live_sfm_publish_policy.dart:10`）。

而「未完成」卡片**按定义就是没走那条出口的**：闪退 / 被杀 / 中途退出，capture
目录被孤儿恢复捡回来。恢复的门槛只有
`if (photos.isEmpty) continue;`（`lib/me/scan_record_store.dart:369`）——
**1 张也会变成一张「未完成」卡片**。

异常路径绕过唯一的闸，作品页又不复查 ⇒ 不足 20 张照样能开始重建。
作品页原来的路由决策 `draftCardActionFor`（`lib/me/draft_card_action.dart`）
入参里**根本没有张数**，只有：capture 目录、有没有 GLB、有没有 PLY、有没有
`sfm_live.db`、有没有别的重建在跑。

---

## 第一部分：已完成（本次落地）

长按任务卡的底部菜单，**未完成**的卡片改为四栏：

| 栏 | 状态 |
|---|---|
| 开始训练 | 够 20 张且有可续跑数据 → 黑字可点；否则灰字 |
| 拍摄更多照片 | 入口已在，动作待第二部分 |
| 改名 | 原样 |
| 删除 | 原样 |

已经出过点云的卡片保留原来的「查看点云 / 重新重建点云 / 改名 / 删除」——
对它们「开始训练」不是待办而是重跑，那条路是 08-24 之后一直在用的。

### 落地要点

- **阈值不复制**：`lib/me/train_gate.dart` 直接调用拍摄页同一个
  `officialCaptureCanFinish`。常数只有一处定义，将来改 20 不会漏掉一边。
- **张数以磁盘为准**：`_countCapturePhotos` 数 `photosDir` 里的 JPEG，不用
  `record.photoCount`（保存时的快照，用户删过照片后偏大 ⇒ 闸会放行一个其实
  不足 20 张的项目）。`photoCount` 只在没有 `photosDir` 的旧记录上兜底。
  只数 JPEG、不要求 `.json` 伴生文件：孤儿恢复要伴生文件是因为它要重建
  manifest（需要位姿），而这里问的是"拍了几张"；把伴生文件写进判据，一个
  sidecar 丢失就会把张数静默算成 0、整个菜单错误置灰。
- **置灰项仍然可点**，点击弹屏幕正中的提示、3 秒后自己消失（Overlay，不用
  SnackBar —— SnackBar 贴底会被 tab bar 压住）。
- **三个 blocked 分开说**，不合并成笼统的"暂时不可用"：
  张数不足（去补拍）/ 另有重建在跑（去等）/ 无可续跑数据（无解）。
  用户下一步该做什么完全取决于是哪一个。张数不足**优先级最高**，因为它是
  唯一用户能自己解决的。

### 验证

- `test/train_gate_test.dart` —— 纯函数穷举：0..19 逐值必须拦，20 / 300 放行；
  优先级；四个枚举值互不吞没。
- `test/me_page_train_gate_wiring_test.dart` —— 接线契约，断言只打在**去注释后
  的源码**上（判据不能匹配自己刚写的注释）。
- **阴性对照做了，而且第一版没过**：最初只断言"源码里出现过 `trainGateFor(`"，
  把 `trainGate = TrainGate.ready` 硬塞进去、真调用改名成 `unusedGate` 之后
  测试照样全绿 —— 绕过闸的最省事改法恰恰保留那个字符串。改成断言**赋值链**
  （`final trainGate = trainGateFor(` + 全文件只有一处 `trainGate =` 赋值）后
  重跑同一变异，被抓到；源码已 `diff -q` 确认逐字节还原。
- 全量 `flutter test`：1553 passed，1 failed ——
  `xrslam_official_replica_contract_test.dart` 缺 Android 产物
  `libxrslam_generic_4beb1a9.so`，与本次改动无关（先于本次改动存在）。

### 未上机

代码只在 Mac 上验过（analyze + test）。**没有装机。**

---

## 第二部分：追加拍摄（未做，方案已定案）

### 一次作废的方向（留档，别再走回去）

最初提的是复刻 Apple 的 "Saving and Loading World Data"（`ARWorldMap` +
`initialWorldMap`）。**用户 09-07 否决：必须跨端，苹果/安卓/鸿蒙三端一致服务。**

否得对，而且不只是"苹果专属"这一条：

- ARCore **没有本地持久化世界地图**。它的持久化只有 Cloud Anchors 和
  Geospatial，都要走云端 / VPS —— 撞"绝对纯本地"红线。
- 鸿蒙 AR Engine 是第三套独立机制。

三个厂商机制拼出来的不是一致服务，是三种行为。**厂商 AR SDK 这条路整条作废。**

### 定案方向：坐标系从图像本身恢复

平台位姿降级为"仅本次会话内的取帧 / 触发判据"。**跨会话的几何基准不问 AR SDK
要**，靠图像匹配 + 绝对位姿求解拿回来。三端跑的是同一份 C++，零平台分支。

### 复刻源：COLMAP（已是本管线血统，非新引入）

- ABI 注释直接引用 `colmap::ObservationManager::DeRegisterFrame`
  （`vendor/official_sfm/include/official_sfm_c.h:105`）。
- 仓库已 vendored：**BSD-3-Clause**，revision `9820ff3d5f362cccb15d2b7cf05bd9ffe4a65113`，
  license 文本已入 `THIRD_PARTY_NOTICES:101`。
- 要复刻的功能在 COLMAP 里是现成的：把新图像注册进已有重建
  （`image_registrator` / incremental mapper 的 register-next-image，
  2D-3D 对应 + PnP/RANSAC）。**不是拼盘，是导出一个已经编在核里的能力。**

### 两堵墙

**墙一：位姿先验是强制的，且 ABI 里没有注册入口。**
`pwofficial_add_frame` 头文件原话（`official_sfm_c.h:368`）：位姿 `NULL`、
非有限、零范数，在**任何 db 写入之前**就被拒，并明写
"It is not permission to create an unposed frame."
生产 ABI 全部 29 个导出（`pwofficial_abi_symbols.txt`）里没有任何
register / localize 入口。新增 ABI 面意味着重建冻结 core ——
`PROVENANCE.md` 用 SHA-256 钉死了身份，重建有自己的审计仪式。

**墙二：重建引擎今天只有 iOS。**
`vendor/official_sfm/libs` 只有 `ios-arm64`，Frameworks 只有 xcframework；
`android_ready` 下唯一的 `.so` 是 `libpw_xrslam_transport.so`（VIO 传输壳），
**没有 SfM core**；也没有 `android/` 应用工程，只有 `android_ready/` 暂存树。
⇒ 「开始训练」这个功能本身在安卓 / 鸿蒙上还不存在。

### 用户裁决（09-07）

**实现写成平台无关，iOS 先验。** 追加拍摄一行不碰 ARKit / ARCore / AR Engine，
也不写任何平台分支；代码从第一天就是三端的，只是暂时只有 iOS 跑得起来。
引擎上安卓 / 鸿蒙时它自动跟随，不需要重写。引擎移植是另一场战役，不阻塞这个。

### 下一步：先做主机侧实验，不碰设备、不重建 core

在为墙一付出重建 core 的代价之前，先验一条**可能根本不需要新 ABI** 的路：

`pwofficial_run(db_path, image_path, ...)` 已经在 ABI 里、也已经在 FFI 里绑了名
（`lib/official_aether_sfm_ffi.dart:766`），头文件说它"在预建的 COLMAP sqlite db
+ image dir 上跑 IncrementalPipeline"。而 COLMAP 的 IncrementalPipeline
**本来就不需要位姿先验** —— 它自己定义世界坐标系。若成立，老照片 + 新照片
整组重跑就会自然落进同一个坐标系，两堵墙里的墙一直接绕过。

> **勘误**：本节初稿把 `pwofficial_run_dir` 也列为候选。它是个**诚实的 stub**
> （`official_aether_sfm_c.cc:8683` 明写 "run_dir not implemented"），也不在
> ABI 导出表里。候选只有 `pwofficial_run` 一个。

⚠️ 它**从没被生产代码调用过**（FFI 只绑了符号）。所以这是"待验证的假设"，
不是结论。

实验形态（全部在 Mac 上，零设备风险）：

1. 取一次真实 capture（照片 + `official_sfm_live.db`）。
2. host 侧调 `pwofficial_run` 跑整组，与现有 resume 产物对拍。
3. 判据：位姿是否落进单一一致坐标系、点数/重投影是否不劣于 resume 基线。

结论只有两种：
- 成立 ⇒ 追加拍摄退化成"照片续号 + 整组重跑"，不需要动冻结 core。
- 不成立 ⇒ 回到墙一，按 COLMAP `image_registrator` 补 ABI，走 core 重建的审计仪式。

**先做这个实验，再谈动采集路径。**

---

## 主机侧实验结果（2026-09-07，已执行）

**素材**：已有 device-backup，只读复制到临时目录，**没有写进备份**。
`device-backups/PocketWorld/com.kyle.PocketWorld_20260723T2149_ratio08_preupdate/
Documents/captures_official/cap_1784792081923324` —— 25 张照片、
`official_sfm_live.db`(24 MB)、已有成品 `official_sfm_sparse.ply` 当基线。

**工具**：`colmap_bench_exe`，由 `third_party/glomap_vendor` 独立工程
（`-DBUILD_BENCH=ON`）在 Mac 上现编。它按 CMake 注释就是
"reads a prebuilt database and runs incremental SfM only"。
零设备操作、零 core 改动、零装机。

### 结论一：批处理路径确实不需要平台位姿 ✅

两条独立证据：

1. **db 里的 `pose_priors` 表是空的（0 行）。** 设备端流式核把 ARKit 位姿用在
   自己的状态里，**不写进 COLMAP 的先验表**。所以在这个 db 上跑 incremental SfM
   天然就是无先验的。
2. `aether_sfm_run` 实现里第一件事就是 `aether_ba_clear_gravity_priors()`，
   注释原话："Batch/reference inputs do not carry the mandatory per-frame ARKit
   gravity contract."（`official_aether_sfm_c.cc:8637`）

Arm A 实跑（原样 db，无任何先验）：**23/25 注册，落进单一模型**
（`outA/images.txt` 一个模型，均值 519.8 观测/图）。

⇒ **补拍的照片在原理上可以不靠任何厂商 AR SDK 就和老照片落进同一坐标系。**
墙一（新增 ABI / 重建冻结 core）在这条路上可以绕过。

### 结论二：但质量明显低于生产基线 ⚠️

| | 生产基线（resume，`phase1: live_reuse`） | Arm A（整组重跑，无先验） |
|---|---|---|
| n_registered | **25** | 23 |
| n_points3d | **6971** | 3478 |
| reproj_px | **0.7269** | 1.1934 |
| track_len | 2.178 | 3.437 |

丢 2 张图、少一半点。这是"扔掉 ARKit 先验喂出来的流式重建、纯靠匹配重来"的代价。

⚠️ 口径提醒：基线是**设备**产物且走 `live_reuse` 路径，Arm A 是**主机**产物，
按 host 复放失真的旧账，绝对值不可直接比。但 **23 vs 25 是结构差异不是计时差异**，
这一条是实的。且 fixture 是 07-23 的，相对 HEAD 偏旧。

### 结论三：k=6 流式匹配图不是瓶颈（原以为是）

Arm B（`--match=1` 穷举重匹配）：匹配对 190 → 300（= C(25,2) 全部），
但 `rows>0` 的 two-view geometry **纹丝不动仍是 94**，重建结果与 Arm A **逐位相同**。

数字逐位相同先按探针失明处理，做了**阳性对照**：把 matches + two_view_geometries
**全部清空**再穷举重匹配 —— 匹配器从零找回 300 对中的 91 对、验证通过 91 对，
重建出 `n_reg=23 n_pts=3353 reproj=1.1927`。

⇒ 匹配器是好的；那多出来的 110 对**是真的没有重叠**（25 帧绕物一圈，
隔得远的视角本来就看不到同一片）。不是失明。

顺带两个收获：
- **健全性检查**：匹配清空且不重匹配 ⇒ `n_reg=0`。重建完全由匹配图驱动，
  没有任何隐藏的位姿旁路。
- **这个对照本身就是追加拍摄的上界实验**：匹配全空比补拍的处境**更难**
  （补拍至少老照片之间还留着匹配），它照样重建出单一一致的模型。

### 下一步该问的问题（不是"能不能"，是"划不划算"）

"能不能不靠 AR SDK 对齐"已经答了：**能**。剩下的是质量账：

1. 整组重跑丢的那 2 张图 / 一半点，是 fixture 老、还是 host/device 口径、
   还是这条路的固有代价？⇒ 需要拿**新 fixture** 复跑，并让设备端也跑一次同口径。
2. 若代价是固有的，那就回到墙一：按 COLMAP `image_registrator`
   （把新图像注册进**已有**重建，保留老重建的成果）补 ABI，而不是整组推倒重来。
   这条才是 COLMAP 为"往已有模型加图"提供的正牌入口。

**在这笔质量账算清之前，不要动采集路径。**

---

# 定案：完全复刻 RealityScan（2026-09-08）

## 用户裁决

> 「那就完全复刻 RS。RS 都做不到的，我们也不用去妄想做到。」

## 一处必须挑明的前提

**RS 是闭源的，指不到源码行。** 按铁律"判据/常数指到源码行"，复刻分两层：

- **行为契约** ← RS 官方公开文档（可引用、可核）
- **实现** ← COLMAP（已 vendored、BSD-3、且本来就是本管线血统，源码行可指）

RS 的引擎 RealityCapture 与我们的核同属增量 SfM + 组件这一族，所以这不是拼盘。

## RS 怎么做（一手文档）

- **加照片就是加照片**：新图丢进工程 → Align Images。重跑对齐时它
  "will continue from the previous state"（从上一次的状态继续）—— **不是推倒重来**。
- **对不上会分裂成多个 component**（= 一组能对齐到一起的图像）。文档列的成因：
  拍的是不相连的物体、纹理弱、图片不够、**视角变化太大**。
- **合并策略三选一**：靠重叠图像 / 靠组件特征 / 靠全部图像特征；另有控制点。
- **全文零 AR**：没有 AR tracking、world map、anchor、GPS。

来源：[Component Workflow](https://rshelp.capturingreality.com/en-US/appbasics/components.htm)、
[Merging Components Using Images](https://rshelp.capturingreality.com/en-US/tutorials/mergecomponents_images.htm)

## 对照组 Polycam：恰好是被否掉的那条路

Polycam 的 **Extend** 工具功能相同，但限制清单暴露了代价：需要原始扫描数据来
**重新建立 tracking**、**只能在拍摄它的那台设备上用**、建议光照与原来一致。
= 厂商 AR 重定位路线，**换台手机就没了**。

（Polycam 帮助页对 WebFetch 返回 403，此段仅据搜索摘录，未取到原文。）

## 复刻清单：每行都指得到源码

| RS 行为（官方文档） | COLMAP 源码行 |
|---|---|
| 加图 → Align → 从上次状态继续 | `RunImageRegistrator` — `colmap/exe/image.cc:253` |
| 单张注册（2D-3D + PnP） | `IncrementalMapper::RegisterNextImage` — `colmap/sfm/incremental_mapper.h:216` |
| 对不上 → 分裂成多个 component | `ReconstructionManager` — `colmap/scene/reconstruction_manager.h:39` |
| 合并 component | `MergeReconstructions` — `colmap/estimators/alignment.h:120` |
| 上限 300 张 | 我方已有 `kOfficialMaximumCaptureFrames = 300`（与 RS Mobile 1.7 一致） |

`RunImageRegistrator` 的语义（读源码确认）：

```
reconstruction->Read(input_path);          // 读入已有重建
mapper.BeginReconstruction(reconstruction);
for (image : reconstruction->Images())
  if (image.HasPose()) continue;           // 跳过老照片
  mapper.RegisterNextImage(...);           // 只注册新照片
mapper.EndReconstruction(discard=false);   // 老的点与位姿全部保留
```

**老重建的点一个不丢** —— 这正是 RS 不掉点、而"整组重跑"掉一半的原因。

## "RS 做不到的不妄想"划掉了什么

- **不保证新照片一定接得上**。RS 也不保证 —— 接不上就分裂成 component 并告知用户。
  我们照做：检测 + 提示，**绝不拿 AR 兜底**。
- **不做设备锁定**（Polycam 路线，弃）。
- **不自研重定位**，一行不写。

---

## 主机侧实验总账（四个 fixture，已结束）

测的形态是**整组重跑**（`pwofficial_run` / incremental SfM over the prebuilt db）。

| fixture | 采集日 | 张数 | kp_max | 基线 n_reg → 重跑 | 基线 pts3d → 重跑 | 点数比 | reproj 基线 → 重跑 |
|---|---|---|---|---|---|---|---|
| cap_1784792081923324 | 07-23 | 25 | 8192 | 25 → 23 | 6971 → 3478 | **50%** | 0.7269 → 1.1934 |
| cap_1788764232382558 | 09-07 | 40 | 13312 | 39 → **40** | 39437 → 22347 | **57%** | 1.1996 → 1.2854 |
| cap_1788712695193490 | 09-07 | 39 | 13312 | 39 → 34 | 18745 → 7172 | **38%** | 1.1410 → 1.2802 |
| cap_1788679937631770 | 09-06 | 30 | 13312 | 30 → 29 | 25102 → 12273 | **49%** | 1.1321 → 1.1774 |

**结论**：
1. **无位姿先验可行** —— db 的 `pose_priors` 表恒为空（0 行），`aether_sfm_run` 开头就
   `aether_ba_clear_gravity_priors()`；实跑均落进单一模型。补拍不需要任何 AR SDK。
2. **注册数不是稳定劣势**（一个 fixture 反超基线 40 vs 39）。
3. **点数稳定腰斩（38–57%）**，跨 8192/13312 两代一致。reproj 只差几个百分点。
   ⇒ 整组重跑的代价是**点数**，不是精度。而产品目标正是"更多点云"。
4. ⇒ **整组重跑这个形态作废**，它本来就不是 RS 的做法。

### Arm C（清空匹配 + 穷举重匹配）已于 187/435 对处主动停止

理由：它验证的是"整组重跑"形态，而该形态已被 RS 对照判死；跑完也不改变结论。
（25 张那次已经答过同一问题：从零重匹配能找回 91/300 对并重建出同一模型。）

## 内存事故与修正（09-07 夜）

**事故**：主机实验把 18GB Mac 跑爆。

**根因算术**（三次修正才对）：
1. 我用 07-23 fixture 的 `kp_max=8192` 当生产口径 → 生产是
   `researchMaxFeatures = 13312`（`lib/official_aether_sfm_ffi.dart:995`），
   实测新 capture `kp_mean` 12716/12093，几乎张张顶格。
2. 我只算了**一个** kp² 矩阵（709MB）；实测单线程 RSS **1914MB**
   （距离 + 索引 + cross-check 反向，约三块）。
3. ⇒ 12 线程满跑 ≈ **23GB** > 18GB，**必然 OOM**，不是"可能"。

**闸的实测结论**：
- `ulimit -v` 在 macOS 上**是空的**（阳性对照：1GB 上限下 2GB malloc+写入照样过）。
- 唯一真闸 = **RSS 看门狗**（阳性：2GB/上限512 ⇒ 杀；阴性：1GB/上限4096 ⇒ 放行）。
  盲区：200ms 内的瞬时尖峰。
- 单线程：给 `colmap_bench.cc` 加了 `--threads`（默认 -1 不改变既有行为；
  回归检查逐位复现 `23/3478/1.1934`）。原文件备份于 `/tmp/colmap_bench.cc.orig`。

**可复用判据**：**fixture 的 kp 上限能给它定代** —— 09-04 23:31 的 capture 张张恰好
8192，正好印证代码注释"09-03 已裁决过一次但机上每帧恒为 8192 才发现"。
拿旧 fixture 反推生产规模 = 把已被推翻的数字抬回来。

---

## 复刻 RS 的两个新发现（都在挡路）

**发现一：设备上没有持久化的 COLMAP 重建。**
capture 目录里只有 `official_sfm_live.db`（特征+匹配）、`official_sfm_sparse.ply`
（仅 xyz+rgb）、`official_sfm_sparse_meta.json`（有位姿）、ARKit 位姿旁文件。
**没有 cameras/images/points3D**，Dart 侧也无任何代码写它们。
而 `RunImageRegistrator` 第一行就是 `reconstruction->Read(input_path)`。

**发现二：track 出口给的是坐标，不是 COLMAP 要的索引。**
`pwofficial_get_points_tracked`（已在 Dart 绑定，`official_aether_sfm_ffi.dart:780`）
确实返回点 + 每点的观测列表，但 `aether_sfm_track_obs_t` 是
`{int32_t frame_id; float x, y;}` —— 是**关键点坐标**，而 COLMAP 的 `points3D`
track 项要的是 `(IMAGE_ID, POINT2D_IDX)`。

⇒ 想纯 app 侧拼出模型，必须把 (x,y) 反查回 keypoint 索引（浮点相等 + 半像素
约定），**脆弱**。更稳的是让核直接写（COLMAP 自带 `Reconstruction::Write()`），
一个 `pwofficial_write_model` 的小出口。反正注册入口本来就要重建核，同一次
重建里加这个写出口是顺手的事。

---

# 第 2 步进展：核 ABI 已落地并自证，但卡在产品晋级评审闸（2026-09-08）

## 已完成并已验证

**主机形态验证（第 1 步补充）**：`--mode=continue` 才是 RS 的对应形态。
30 张 split（前 19 张为种子）：

| 臂 | n_reg | n_pts | reproj |
|---|---|---|---|
| 种子（前 19 张） | 19 | 7496 | 1.0732 |
| `image_registrator`（只注册） | 29 | 7496 | 1.0732 |
| **`continue`（注册+三角化+BA）** | **29** | **12247** | 1.1749 |
| 整组重跑（30 张从零） | 29 | 12273 | 1.1774 |

`COMPONENTS n=1`，无分裂，老点全保。

**🔴 一处自我纠正**：此前据 `image_registrator` 的 7496→7496 断言"掉点是重跑形态的
代价"，**是错的**。continue(12247) ≈ 整组重跑(12273)，差 0.2% —— 续跑与重跑点数
基本相同。真正的差是**主机 vs 设备**（主机两条路均 ~12.2k，设备基线 25.1k）：
设备走 `live_reuse`，种子是采集期积累 + 局部 BA 的流式重建，起点本就更肥。
这与追加拍摄形态无关，是另一笔账。

**核 ABI 两个新出口已实现并编过**（`aether_cpp`）：
- `aether_sfm_write_model(s, out_dir)` — 按 COLMAP 格式落盘（补拍的前置件）
- `aether_sfm_continue_from_model(db, images, model_in, model_out, ...)` —
  复刻 `colmap/exe/sfm.cc:344` RunMapper 的 `--input_path` 分支
- 实现方式：给 `RunIncremental` 加 `seed_model_path` 参数（默认空 = 原行为一字未动），
  **复用其全套调优的 BA / 三角化参数，绝不复制第二份真相**
- 头文件 ×2 + `pwofficial_export_shim.c` 转发已加

**自证**：
```
基线核 cfbc16f7118456f186079d20f22d5cd0e4ef49c15f2ca8f353e2607e21ede3c5
新核   dd0b799bc9264410ea7f8edb6f6f799be291ccc0b8da28ca2f3c415eaad40065
       T _aether_sfm_continue_from_model
       T _aether_sfm_write_model
```
（基线构建先跑过一次作阳性对照，证明构建链本身是好的。）

## 🔴 卡在哪：产品晋级评审闸

SOP §3.1 已写明三件事，全部与本次改动直接相关：

1. **`flutter build ios` 不会重链 `PWOfficialSfm`**。pod 吃的是预制 xcframework，
   把新 `.a` 拷进 `libs/` 再构建，产出的仍是旧 framework（09-08 实测新符号 0 命中）。
   ⇒ 新核**到不了设备**。
2. 换 framework 只有 `build_xcframework.sh`（10 个 env），其唯一正经调用者
   `rebuild_native.sh` **带评审闸**，三个必需输入在仓外：
   `PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST`（fresh-review 已接受的产品清单）、
   其 SHA256、`PWOFFICIAL_IDENTITY_OBSERVER`（SHA 须等于脚本内钉值）。
3. **SOP 自己标红的已知不一致（未修）**：`ALGORITHM_REVISION=b930ab18` 是 07-21，
   而出货归档里的 `official_bundle_adjustment_ceres.cc.o` 源码 08-10 才加进来
   ⇒ **按这个钉子跑复现不出生产机上正在跑的二进制**。SOP 原文：
   修正钉子"是评审动作，要用户签"。

**我没有绕过这道闸**：它守的正是要装到生产机上的那个产物，绕过它就等于废掉这套审计。

## 需要用户决定的三条路

- **A（正路）**：提供 accepted product manifest + SHA + identity observer，并先签掉
  `ALGORITHM_REVISION` 钉子的修正。之后 `rebuild_native.sh` 可机械跑完。
- **B（本仓已有先例）**：不整树重编，把重编的 `.o` 用 `ar r` 换进钉定归档 + `ranlib`
  （SOP §3.1 记载的正解，09-08 局部 BA 两刀即如此做）。本次改动涉及**两个** `.o`
  （`official_aether_sfm_c.cc.o` + `pwofficial_export_shim.c.o`），判据相应改为
  "只有这两个 + `__.SYMDEF` 不同，且无任一边独有的 `.o`"。
  ⚠️ 但这只解决 `.a`；`.a → framework` 仍需 `build_xcframework.sh`。
- **C**：明确授权我直接调用 `build_xcframework.sh`（绕开 `rebuild_native.sh` 的评审闸）。
  **这需要你单独、明确地授权这一次绕过**，我不会自己做这个决定。

## 未开始

第 3 步（采集路径）、第 4 步（UI）、装机。它们全部排在 framework 之后 ——
新核进不了设备，做完也验不了。

## 走 A（正路）的前置件清单（2026-09-08 逐项核过）

### 已就位（我核过，不用管）
- 新核已编、符号已验：`dd0b799b…`，`T _aether_sfm_continue_from_model` / `T _aether_sfm_write_model`
- 构建链健康（先跑基线 `cfbc16f7…` 作阳性对照）
- Dawn 归档在（09-07 重钉那份，680MB）
- Ceres / glog 归档在 `~/Developer/dist/libs/ios-arm64/sfm/`
- SDK 的 `libsqlite3.tbd` 由 `xcrun` 现取

### 只有用户能给（仓外）
- `PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST`（文件）+ `..._SHA256`
- `PWOFFICIAL_IDENTITY_OBSERVER`（可执行文件）
  —— 已按 SHA `eb493fd4…` 在 `pw_builds_20260904` / `pw_backups` / `dist` /
  `vendor/official_sfm` 下逐文件搜过，**不在磁盘上**。

### 需要用户签的两处钉子修正

**钉子一 `ALGORITHM_REVISION`（rebuild_native.sh:30）**
```
脚本钉         b930ab185135dfbd172aef7c2bbeed67ef315f75
PROVENANCE:31  - Rejected later revision:  ← 同一个 hash
Aether3D-cross HEAD  c281dd3785714188dbaee001f4040dc4a2441e64
```
硬闸不等即 `exit 66`。即：晋级脚本要求 HEAD 等于一个**产物溯源文件自己标为“已否决”
的版本**。比 SOP 原先记的“日期对不上”更硬——那是直接的自相矛盾。

**钉子二 `PWOFFICIAL_EXPECTED_CORE_SHA256`（rebuild_native.sh:55）**
```
脚本钉                    1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04
仓内 libs/ 实际           290ab3c1e40b51ee728e1b478b1a538c8c3d618aa23557fdd3a02b21e455adef
```
比对目标是仓内 `libs/ios-arm64/libpwofficial_core.a`（脚本:157），不等即 `exit 68`。
⇒ **现在就对不上，与本次改动无关**。本次改动另需把它改成新核 `dd0b799b…`。
（两种可能：仓内核被换过而钉子没跟着改；或该钉子本就是“已接受身份”的记录、
每次晋级由评审更新。哪一种要用户定——我不替这个判断。）

---

# 追加拍摄落地(2026-09-08)：四步做完，全是 Dart，核一行没动

## 🔴 先纠正我自己的一个大绕路

我据"整组重跑掉一半点"推出"必须加新 ABI"→"必须重建冻结核"→撞评审闸。
**但这条链的第一环我自己就推翻过**：continue 12247 点 vs 整组重跑 12273 点，
差 0.2%。为一个我已证明不存在的差距，绕了一大圈。

实测确认：`_pwofficial_run` / `_pwofficial_create` / `_pwofficial_add_frame`
**都已经在生产机那份 framework 的导出表里**，Dart 也已绑定
(`official_aether_sfm_ffi.dart:766`)。**追加拍摄不需要动核、不需要重打包、
不需要过评审闸。**

## 四处改动（全部 Dart）

1. **`photo_slot_naming.dart`** — 新增 `maxFrameSeqInNames()`。
   该文件开头写着唯一性依据是"每次重建全新 captureDir + `_frameSeq` 归零"，
   **补拍复用目录直接踩碎这条**：归零会让新照片与老照片同名覆盖，正是
   cap47 那个 16% 点色彩污染的成因。补拍必须把序号接到已有最大值之后。
2. **`capture_session.dart`** — `start({… String? extendCaptureDir})`。
   复用分支**绝不 delete**（那句 delete 在这里会毁掉用户上一次的全部照片和 db），
   并把 `_frameSeq` 接上；`writeForNewCapture` 只在新建时写。留空 = 原行为一字未动。
3. **`ar_capture_page.dart`** — `OfficialARCapturePage({this.extendCaptureDir})`，
   透传到两处 `session.start(...)`。
4. **`official_gallery_routes.dart` + `me_page.dart` + `app_shell.dart`** —
   `pushOfficialExtendRoute` + `OfficialExtendCaptureRoute` 注入，
   「拍摄更多照片」从占位提示换成真动作；四个不可用分支各自说明原因。

## 第 3 步（跑整组重建）不需要写代码

`sfm_live_recon.dart:2295` 的 worker `resume` 分支注释原话：
`aether_sfm_create` 打开已有 db，**`finalizeAsync` 的 `RunIncremental` 直接从 db
读 keypoints/matches**（image_path 为空 ⇒ 全部状态来自 db），且用
`researchMaxFeatures`(13312) + `researchKNeighbors`(12)。
⇒ 补拍的新照片进了同一个 db，用户点「开始训练」时本来就会新老一起重建。

## 验证

- `flutter test` 全量：**1563 passed，1 failed** ——
  仍是 `xrslam_official_replica_contract_test`(缺 Android `.so`)，
  先于今日全部改动存在。
- 新增/补强断言：`photo_slot_naming_extend_test.dart`（序号续排、陌生文件不崩）；
  `me_page_train_gate_wiring_test.dart` 增三条（补拍接的是真动作而非 toast 占位、
  路由从 app_shell 注入到菜单、复用分支内绝无 `delete(`）。
- **变异对照**：把 `extendRoute(...)` 换回占位提示 ⇒ 测试变红；源码 `diff -q`
  逐字节还原后重跑全绿。（第一版张数闸的断言就是被同类变异骗过的，不再犯。）

## ⚠️ 一次并行改动事故（已恢复，无损失）

做到一半时本仓另一路（build 116 相框/震动）执行了 stash，**把我 6 个已跟踪文件的
未提交改动一起卷走**（未跟踪的新文件幸存）。HEAD 从 `778b87b` 走到 `3d4cb44`。

处置：`git diff --name-only 778b87b HEAD` 确认那期间他们只改了
`APP_INSTALL_SOP.md`，与我 6 个文件**零相交**；随后用
`git show stash@{0}:<path> > <path>` **只取回我的 6 个文件**，
不 pop、不 drop、不碰暂存区 —— stash 里还有他们的
`PWOfficialSfm` 框架二进制与 `libpwofficial_core.a`，那不是我的东西。
stash 至今原封未动。

## 未上机

只在 Mac 上验过（analyze + test）。采集路径改动的上机闸是**每张毫秒对照**，
那个数字只有真机能出。装机需单独授权。
