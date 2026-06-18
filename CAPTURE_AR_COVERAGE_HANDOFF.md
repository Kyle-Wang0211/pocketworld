# PocketWorld 拍摄阶段 AR 红/黄/绿覆盖率 UI — 交接指令（接力 Prompt）

> 把这整份文档粘贴进一个全新的 Claude Code 会话（Claude app / ultracode 模式）。你（接力 agent）没有任何之前对话的上下文，本文档是自包含的。所有路径、行号均已对照工作树验证（2026-06-17），不要凭空发明路径。用中文交流（专业术语保留英文即可）。

---

## 1. 你是谁 / 在做什么 & 为什么这一层是命门

你正在为 **PocketWorld** 开发**拍摄阶段（capture-phase）的 AR 引导 UI** —— 也就是用户**一边拍一边看到**的实时引导。对标产品是 **RealityScan**（Epic，原 RealityCapture mobile）的 AR Guidance 模式。

PocketWorld 是一个**商业、跨平台（iOS / Android / HarmonyOS）的纯手机 RGB 三维扫描 app**。

**为什么这一层是产品命门（务必牢记）：**
- 用户**只信任 live preview 里看到的东西**。如果预览只显示了半个房间，用户就只会框选半个房间，下游 MVS 也就只重建半个房间。
- 所以本层的核心 KPI 是 **preview ≈ final**（预览所见 = 最终重建所得）。
- RealityScan 整条链路其实是 preview ≠ final（它靠云端做最终稠密重建来兜底）。**PocketWorld 没有云端**，所以我们的差异化优势必须是：**一个本地稠密几何，既是覆盖率反馈、又是可靠的框选底座**（即 preview ≈ final）。v1 先用稀疏点做覆盖率反馈（见第 6、7 节），稠密框选底座是后续里程碑。

---

## 2. 硬约束（绝不可违反）

- **绝对禁止 LiDAR / 深度相机**（用户的硬规矩）。只能用 **RGB 图像 + VIO 位姿**（ARKit / ARCore / AR Engine 提供位姿）。
- **设备端 RAM ≤ 4.1GB**（iPhone jetsam 上限）。必须 voxel-downsample / LOD / 流式处理，否则 OOM。
- **完全本地**，**禁止任何服务端推理**。
- **跨平台**：iOS 优先，但要为 Android / HarmonyOS 抽象；位姿来自各平台自己的 AR 框架。
- **License**：只允许 **MIT / BSD / Apache**。**禁止 GPL / AGPL / CC-BY-NC**。每个依赖逐一核验。
- **抄商用可用的 SOTA，不要自己发明**（copy commercial-OK SOTA, do NOT self-invent）。每个依赖核验 license。

---

## 3. 已确立的 RealityScan 研究结论（含关键诚实原则）

完整带引用的研究笔记在：
`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/capture_ux/RESEARCH_realityscan_capture.md`

**RealityScan MOBILE ≠ desktop。** Mobile 是**三层设备端几何 + 一层云端最终重建**：
1. **拍摄中**：实时的**稠密彩色点云**（按覆盖率质量 red→green 上色）铺在物体表面 —— 纯 RGB+VIO 摄影测量，**无 LiDAR**（官方确认 "no special hardware"；Android 端 "photogrammetry only"）。
2. **拍完约 1 秒后**：一个更稀疏的 "Color Point Cloud"，用于 ROI **框选**。
3. **最终稠密重建跑在云端**。

**覆盖率上色信号**（RealityScan 官方原文，qualityanalysis.htm）：**"camera coverage of each tie point"** —— 绿=好、红=差。它是**对点云逐点上色**（NOT voxel-grid 外观、NOT 屏幕空间网格）。

**拍摄哲学 = 宽松/引导，而非门禁式（lenient/guided, NOT gated）：** motion-triggered 自动拍照、**不做逐帧模糊/曝光拒绝**、靠 "Take More Pictures" 补缺口、300 张上限、3 种模式（AR Guidance / Object[去背景] / Standard）。

### ⚠️ 关键诚实原则（CRITICAL HONESTY RULE，逐字精神保留）
**RealityScan 没有公布任何红/黄/绿分界的数值阈值。** 任何 count / angle 阈值都是**我们自己的**，必须**在真机上经验性地调出来**，**绝不可以包装成 "RealityScan 的阈值"**。
（本会话早些时候助手凭空编了 "count≥4 且 3 个 azimuth bins"，被用户当场抓出来 —— **不要重蹈覆辙**。改为**复用 app 自己已有的覆盖率启发式**，见第 5 节的 dome promotion gates。）

---

## 4. 当前进度 & git 状态

- 仓库：`/Users/kaidongwang/Developer/pocketworld`
- 分支：**`capture-ar-coverage`**（已切到，已验证）
- 快照 commit：**`11df911`** —— "WIP snapshot: dome (sphere) capture UI + ARKit point infra, before AR coverage UI"
- **工作树干净**（`git status -s` 为空），已验证。
- 这个快照的目的是**保住 sphere/dome UI**。新的覆盖率 UI 必须**并排新增（add alongside）**，不可破坏 dome。

---

## 5. 项目架构 & 关键文件

技术栈：**Flutter（Dart UI/逻辑）+ 原生 ARKit（Swift，位姿与预览）**。单一 ARSession 同时支撑相机预览和位姿/点流。

### A. 原生 ARKit bridge（Swift，路径前缀 `/Users/kaidongwang/Developer/pocketworld/ios/Runner/`）

- **`AppDelegate.swift:5-79`** —— 所有 in-Runner Swift 插件在 `didFinishLaunchingWithOptions` 里**手动注册**（绕开 iOS 26 plugin-registrar metadata race）。`AetherARKitPlugin.register` 在 `:28-34`（`#available(iOS 11.0,*)` 门禁）。

- **`AetherARKitPlugin.swift`** —— 位姿流 + 预览的核心。
  - 通道契约头注释 `:11-62`。注册 `register` `:78-85`，init `:275-291`。
  - **MethodChannel `aether_arkit`** `:276`，handler `handle(call:result:)` `:295`：`isAvailable` `:297-298`、`startSession` `:299`、`stopSession` `:310`、`lockOrigin` `:313`、以及 `saveCurrentFrameAsJpeg` / `captureHighResolutionStill`。
  - **EventChannel `aether_arkit/pose_stream`** `:279-280`，handler `PoseStreamHandler`（class `:1946`）。
  - **PlatformView 工厂** viewType **`"aether_arkit_preview"`** `:84`（factory `:2033-2052`，view `AetherARKitPreviewView` `:2055`，挂在**同一个 ARSession** `currentSession()` `:74-76` 上，并在原点 anchor 下画一个 3cm 白球 marker `:2135-2149` —— 这就是要保留的 sphere 标记）。
  - **`startSession()` `:469`**：`ARWorldTrackingConfiguration` `:479`、autofocus `:483`、`worldAlignment=.gravity` `:487`、`planeDetection=[.horizontal]` `:496`、`session.run(..., options:[.resetTracking,.removeExistingAnchors])` `:546`。
  - **`broadcast(frame:)` `:1281-1516`**：每帧一个 JSON dict。关键字段：`extrinsic`（16 floats，**column-major** camera→world，`:1295-1304`）、`intrinsicFxFyCxCy`=`[fx,fy,cx,cy]` `:1305-1310`、`tx/ty/tz` + `qx/qy/qz/qw` `:1396-1405`、`isTracking`（仅 `.normal`）`:1313-1316`、`trackingStateName` `:1311`、`imageWidth/imageHeight`、world origin block（`worldOriginX/Y/Z`、`worldYaw`、`hasOrigin`）`:1501-1513`、质量缩略图 `q_gray128`（6Hz）`:1473-1479`。预览点**只在 `previewPointInterval` 时机合并进来** `:1417-1426`。
  - **`makePreviewPointPayload(frame:maxPoints:)`（static `:1714-1771`）—— 彩色点的源头**：
    - 节流 **8Hz**（`previewPointInterval=1.0/8.0` `:139`，门禁 `:1417`），**`previewPointMaxCount=220`** `:140`。
    - 源 = ARKit 官方 `frame.rawFeaturePoints`（VIO 稀疏云）`:1718`，均匀抽样到 ≤220 点（stride `:1729-1742`）。
    - **XYZ 输出的是 raw world-space `p.x/p.y/p.z`** `:1755-1757`（**不是屏幕坐标、不是 origin-relative**）。
    - RGB 通过 `frame.camera.projectPoint(..., .landscapeRight, ...)` 投影后采样 `frame.capturedImage`（YUV→RGB）`:1744-1817`。
    - **confidence 硬编码 `1.0`** `:1761`（ARKit 此处无 per-feature 置信度，是占位符 → **不要把它当覆盖率信号**）。
    - 输出键 `:1765-1770`：`previewPointXYZ`（flat float 3/pt）、`previewPointRGB`（flat int 3/pt）、`previewPointConfidence`、`previewPointSource="arkit_rawFeaturePoints_voxel_preview"`。
  - **`lockOrigin(distanceMeters:)` `:592-726`**：分层 raycast 定原点，装一个具名 `ARAnchor "pocketworld_subject_origin"` `:704-707`，存 `worldSubjectAnchor` `:707`。**每帧重新读 anchor 的 transform，无条件接受更新** `:1367-1377`（旧的 0.5m drift-rejection 已删，因为会卡住）—— 这意味着 **world origin 会跟随 SLAM 重定位钉在真实点上，是抗 drift 的基础**。

- **`Da3DepthPlugin.swift`**（CoreML 深度，**未接入 live capture**）：MethodChannel `pocketworld/da3_depth`，仅 `runDa3DepthWindow`，**离线/批处理**，从磁盘读图，`computeUnits: cpuOnly` `:168`。v1 不碰它。

### B. Dart AR 契约 + voxel 模型

- **`/Users/kaidongwang/Developer/pocketworld/lib/dome/platform_pose_provider.dart`** —— `PlatformARPoseProvider`，订阅两个通道 `:29-30`。解析 `extrinsic`→`extrinsic4x4`、`intrinsicFxFyCxCy` `:150-153`；`_decodePreviewPoints` `:185-221` 把 native 点解成 `ARPreviewPoint(position, color, confidence)`。**预览点 XYZ 与 `extrinsic` 在同一 ARKit world frame**，因此用同一帧的 extrinsic+intrinsic 投影即可对齐到屏幕。预览点 8Hz，位姿 60Hz —— **要紧贴覆盖层就缓存最新点，用每个新 extrinsic 重投影**。

- **`/Users/kaidongwang/Developer/pocketworld/lib/dome/ar_pose.dart`**：
  - `ARPreviewPoint` `:21-35`：`position`（Vector3，**world-space，已锚定**）、`r/g/b`（int 0-255）、`confidence`（native 给 `1.0`）。
  - `ARPose` `:40-245`：`position` `:41`、`orientation` `:45`、`azimuth` `:51`（`atan2(rel.z,rel.x)-worldYaw`，`rel=position-worldOrigin`，lock 前为占位）、`elevation` `:56`、`isTracking` `:59`、`trackingStateName` `:78`、`timestamp` `:82`、`hasOrigin` `:87`、`worldOrigin` `:91`（lock 前为零向量）、`worldYaw` `:94`、**`extrinsic4x4`** `:100`（16-float column-major camera→world）、**`intrinsicFxFyCxCy`** `:104`、`imageWidth/imageHeight` `:108-109`、**`previewPoints`** `:145`（**Dart 负责所有 voxel hashing/上色/策略**）。`copyWith` `:180-213` **不改 `previewPoints`，原样透传** `:203`。

- **`/Users/kaidongwang/Developer/pocketworld/lib/capture/realtime_capture_preview.dart`** —— **`RealtimeCapturePreviewModel`（要改的核心模型）**：
  - 常量：`maxStoredVoxels=60000` `:79`、`maxCameraSamples=420` `:80`。状态 `_voxels: Map<String,_MutablePreviewVoxel>` `:82-83`、`_cameraSamples` `:84-85`、`_phase`（由 photoCount 推导）`:90`。
  - `voxels` getter `:98-106`：把每个 voxel `snapshot(_phase)` 成不可变 `CapturePreviewVoxel`，按 observations 降序 → 仅被 `_DraftPointCloudMiniMap` 消费。
  - **`updateFromPose(pose,{photoCount})` `:118-152`**（已读源码核对）：存 `_lastPose`/`_photoCount`/`_phase`；photoCount 增长时 append camera sample 并裁到 420；**对每个 `pose.previewPoints`**：`distance=(point.position-pose.position).length` `:137` → `level=_voxelLevelForDistance(distance)` `:138` → `size=_voxelSizeForLevel(level)` `:139` → `key=_voxelKey(point.position, level, size)` `:140` → `putIfAbsent` + `voxel.add(point, pose.timestamp)` `:141-145`；**`if(_voxels.length>maxStoredVoxels) _pruneVoxels(...)` `:148-150`（← 驱逐触发点）**；`notifyListeners()`。
  - `_phaseForPhotoCount` `:154-158`（<5 veryRough / <20 initializing / else qualityPointCloud）。
  - **`_voxelLevelForDistance` `:160-164`（<1.25m→0, <3.5m→1, else 2）—— 用的是相机相对距离，所以同一世界点在不同帧会落到不同 LOD**。`_voxelSizeForLevel` `:166-175`（L0 0.035 / L1 0.075 / L2 0.16m）。
  - **`_voxelKey` `:177-182`：`'$level:$ix:$iy:$iz'`，key 含 `level` —— 同一世界点在两个距离下产生两个不同 key，导致同一表面 voxel 翻倍/翻三倍**。
  - `_MutablePreviewVoxel` `:198-253`：`add` `:217-226` 增 observations、位置取增量均值（会**朝均值漂**）、r/g/b/confidence 跑动平均、记 `lastTimestamp`。`snapshot(phase)` `:228-248` 质量公式 `obsScore=(observations/7).clamp(0,1)`，按 phase 加权并 clamp（veryRough≤0.45 / init≤0.72 / quality≤1.0）—— **每次 phase 推进会重算所有 voxel 的质量**。
  - **`_pruneVoxels(targetCount)` `:184-195`（已读源码核对）—— 这就是驱逐/回退**：按 observations 升序、再 lastTimestamp 升序排序，删掉最低的 `len-targetCount` 个。一旦到 60000，**刚转过去看的新表面（低 observation）和旧的真实几何都会被删 → 覆盖率非单调 → 回头看已扫区域会发现它又空了（这就是用户说的 "backtrack"）**。

### C. Dome（sphere）UI —— **必须保留、不可删**

> 澄清：代码里的 "dome" 不是全屏 3D overlay。它是两部分：(1) **数据模型 `DomeTargetPoints`**（118 点球面网格 + gates，是唯一覆盖率信号）；(2) **视觉上的 "dome"** = 底部快门按钮里画的 mini-map（class `_CaptureButtonOrDome`）。

- **活的（wired into CapturePage）**：
  - `/Users/kaidongwang/Developer/pocketworld/lib/capture/dome/dome_target_points.dart` —— `DomeTargetPoints`（118 点网格 + ingest + curation）。`capture_page.dart:31` import，`:79` 实例化，`:263` 喂进 `CaptureSession`。
  - `/Users/kaidongwang/Developer/pocketworld/lib/capture/dome/ring_buffer_cell.dart` —— **promotion gate 计算（即上色启发式）**。
  - `/Users/kaidongwang/Developer/pocketworld/lib/capture/dome/dome_thresholds.dart`（所有 gate 常量）、`dome_config.dart`（118 点拓扑）、`dome_cell_state.dart`（状态枚举 + 颜色）。
- **死代码（不要复活，也不要删，保持现状）**：`lib/ui/capture/dome_view.dart`、`lib/ui/capture/dome_painter.dart`、`lib/dome/dome_view.dart`、`lib/dome/coverage_map.dart` —— 都构造于无处、无人 import。当前的实时可视化是 `_PhotoPositionOverlay` + `_RecordingBottomPanel` 里的 mini-map。

#### ★ 可复用的 dome promotion-gate 数值（你的上色启发式种子，来自 `ring_buffer_cell.dart::computeRawState` `:131-159` + `dome_thresholds.dart` `:112-116`）

状态机 `empty → weak → ok → excellent`（对应 灰 / 黄 / 浅绿 / 深绿）：
- `_buf.isEmpty` → **empty** `:132`
- `_buf.length <= 2` → **weak**（1-2 帧）`:135`
- `_buf.length >= excellentMinFrames(=2)` 跑 **excellent** 检查，**四条全过才 excellent**，否则 **ok** `:136,151-156`：
  - azimuth spread `azSpread >= excellentMinAzSpreadDeg = 3°`（短边 wrap）
  - time spread `timeSpread >= excellentMinTimeSpreadSec = 0.5s`
  - median sharpness `medSharp >= excellentMinSharpnessMedian = 600`
  - max motion `maxMotion <= excellentMaxMotion = 0.50`
- 常量：`excellentMinFrames=2`、`excellentMinSharpnessMedian=600`、`excellentMinAzSpreadDeg=3`、`excellentMinTimeSpreadSec=0.5`、`excellentMaxMotion=0.50`、ring buffer `maxFramesPerCell=12`。
- **单调 high-water（上色绝不回退）** `ring_buffer_cell.dart:124-127, 95-97`：`state()` 返回 `max(computeRawState, _highWater)`，`bumpHighWater` 只升不降。**这是你要复刻到 voxel 上的单调性范式。**
- 颜色（iOS palette，`dome_cell_state.dart:39-50`）：empty `0x66525252`（灰）、weak `0xBFFABD29`（黄）、ok `0xE078DB78`（浅绿）、excellent `0xF21FB31F`（深绿）。

> 注意：上面这些**帧数/角度/时间阈值，能直接借来当 voxel 覆盖率上色的种子**，但它们**不是 RealityScan 的阈值**，是我们自己的，最终要在真机上调（见第 3 节诚实原则）。

#### 118 点球面网格（`dome_target_points.dart` + `dome_config.dart`）
- cosine-weighted lat-long，`_initRingsAndPoints` `:222-301`；config `equatorAzCount=18`、`elCount=11`、每环 az 数 `1,6,11,15,17,18,17,15,11,6,1=118`；最近点路由 = 单位球上最大点积 `:636-649`。

### D. 拍摄流程 & UI 集成点

- **`/Users/kaidongwang/Developer/pocketworld/lib/ui/capture/capture_page.dart`** —— live host：
  - build 里的 layer Stack `:899-1064`（paint 顺序，越靠后越在上）：
    1. ARKit 相机预览 `Positioned.fill(_buildPreviewLayer())` `:905`（iOS `UiKitView(viewType:'aether_arkit_preview')` `:1102-1108`）
    3. Aim overlay `:936-937`（`if(_isAiming)`）
    4. Hard-reject toast `:947-960`
    5. **Photo-position overlay** `_PhotoPositionOverlay(model, targetPoints)` `:962-970`（widget `:1277-1346`，**投影数学 `:1374-1396`**）
    6. Motion-speed toast `:972-985`
    8. **Recording bottom panel** `_RecordingBottomPanel` `:1011-1030`（含 **`_DraftPointCloudMiniMap` `:1500-1517`**，painter `:1519-1652`）
    9. **Capture button / dome** `_CaptureButtonOrDome` `:1032-1060`（widget `:1963-2038`，底部快门里的 dome mini-map）
  - 状态机字段 `:78` 起：`_recording` `:92`、`_isAiming` `:106`、`_lockInProgress` `:93`、`_arWarmupComplete` `:127`。转换入口 `_onCenterTap`（body `:440-512`）：AIM→`lockOrigin(distanceMeters:1.0)` `:462` → 成功后 `session.start(autoLock:false)` `:478`、`_previewModel.reset()` `:480`、`setState(_recording=true)` `:481-485`。
  - **`_previewModel`**：字段 `:80-81`，**在 page 自己的 pose 订阅里 `_previewModel.updateFromPose(p, photoCount:_targetPoints.retainedJpegPaths.length)` `:286-289`**；session 构造 `CaptureSession(targetPoints:_targetPoints)` `:263`，`_poseSub=session.poseStream.listen(...)` `:264`；reset 于 start `:480` / stop `:435`，dispose `:891`。
  - **投影 helper `_projectCameraSampleToScreen` `:1374-1391`** —— **复用它做 world→screen，别自己重推 focal/projection**。

- **`/Users/kaidongwang/Developer/pocketworld/lib/capture/capture_session.dart`**：`poseStream` getter `:93`，`_poseCtrl.add(p)` `:524`，`_onPoseTick` `:963`。数据路径：`poseProvider → _resolveHybridPose(:522) → _poseCtrl.add(:524)`（session 侧），**page 侧再 `session.poseStream.listen → _previewModel.updateFromPose`（`capture_page.dart:264-289`）**。构造 `:431-444`，`DomeTargetPoints` 是注入的（default `:440`）。
- **`/Users/kaidongwang/Developer/pocketworld/lib/ui/app_shell.dart`**：`_openCapture()` `:142-156`，push `const CapturePage()` `:146-148`（`CapturePage` 当前无构造参数 `:43-44`）。

---

## 6. 本次已锁定的决策

1. **v1 覆盖率几何源 = app 已有的 ARKit `rawFeaturePoints` 稀疏点 → voxels**（**不是** DiffMVS 稠密）。稠密 DiffMVS 预览（为了可信框选 / preview≈final）是**后续里程碑**。稀疏做覆盖率反馈是 OK 的、也匹配 RealityScan；稠密框选层之后再做。
2. **复用 app 已有的覆盖率/质量启发式（dome promotion gates，第 5C★）来上色 —— 不要发明数字。**
3. **保留 dome（sphere）UI，把 AR 覆盖点 UI 并排新增**（CapturePage 里的一个新 layer/mode）。

---

## 7. 下一步要做的事（THE TASK）

### 用户原话（必须满足）
> "拍摄过程中有红/黄/绿的彩色点；保证这些点**不回退（do not backtrack）**、**不漂移（do not drift）**；随着拍的图越来越多，**覆盖区域变大、出现更多彩色点**。"

### 实现规格

**(a) 让覆盖率单调 + 不驱逐 + 世界锚定（修掉 60k LRU prune）。** 改 `/Users/kaidongwang/Developer/pocketworld/lib/capture/realtime_capture_preview.dart`：
- **删除驱逐**：移除 `_pruneVoxels`（`:184-195`）及其调用点（`:148-150`）。让 store **append-only**：一个 key 一旦出现，整个 capture session 生命周期内**绝不删除**（只有 `reset()` `:108-116` 清空）。60000 个 `_MutablePreviewVoxel`（~7 doubles + int）约 5MB，常驻可接受。若仍想要内存上限：**大幅调高 `maxStoredVoxels`（`:79`），溢出时停止接受新 key，绝不删已有 key**（封顶增长，绝不回退）。
- **让 voxel key 与 level 无关（一个世界格 = 一个 voxel）**：改 `_voxelKey`（`:177-182`）去掉 key 里的 `level`，用单一固定世界网格尺寸（例如最细的 0.035m）。`level`/`size` 只用来**决定渲染点的大小，不参与身份判定**。等价地：让 `level` 由**稳定量**（固定世界网格）而非相机距离（`_voxelLevelForDistance` `:160` 当前用 `(point-cameraPos).length` `:137`）推导，使同一表面无论相机远近都映射到同一 key。这同时减缓增长、降低驱逐压力。
- **让显示指标单调**：在 `_MutablePreviewVoxel`（`:198-253`）里**额外记一个 max-ever 的 quality/observation**（high-water），或**别让 `snapshot` 重读 live `_phase`（`:228`）** —— 在首次/最佳观测时锁定 phase（或一个单调置信度下限），使 voxel 的覆盖率贡献**永不下降**。复刻 `ring_buffer_cell.dart:124-127` 的 high-water 范式。
- **世界锚定：断言它，不要重新引入 drift**：位置**已经是 world-space**（plugin `:1755-1757`）。**不要**在 `updateFromPose`（`:137-145`）里给 `point.position` 叠加任何 `pose.position`/`pose.orientation` 变换 —— 那会把它 un-anchor。唯一的相机相对量 `distance`（`:137`）应按上一条从**键控路径**里移除（可仅保留用于装饰性点大小）。ARKit relocalization 的世界帧漂移由 native 侧处理（`lockOrigin` 的 anchor 每帧重读 `:1367-1377`）；本模型把入参当作**已在锁定世界帧**对待。

**(b) 覆盖率信号 = distinct-camera count + view-angle diversity → 颜色。** 当前 voxel 只记 `observations`（不分相机），需要扩展：
- 给 `_MutablePreviewVoxel` 增加**不同相机的计数**与**观测方位多样性**（例如把每次观测的相机方位/视线方向量化进 azimuth bins，统计去重后的 bin 数）。注意：`updateFromPose` 已能拿到 `pose.position`/`pose.orientation`，可据此为每个 voxel 算"从哪个相机、哪个角度看到的"。
- 映射到 **red(低) / yellow(中) / green(覆盖良好)**，阈值 = **可调参数**，**种子取自第 5C★ 的 dome gates**（例如把 `excellentMinAzSpreadDeg=3°`、`excellentMinTimeSpreadSec=0.5s`、帧数门 `≥3`（=weak 之上）作为初值），**最终在真机上调**。
- **不要用 native confidence**（硬编码 1.0，无信号 `:1761`）做覆盖率决策；靠 distinct-camera count + 角度多样性 + occupancy。
- **诚实原则**：把这些阈值标注为"我们的、待真机调"，绝不写成 RealityScan 的。

**(c) 渲染成 AR overlay（不只是现有的俯视 mini-map）。** 像 photo-position overlay 那样，把 voxel 的 world 位置通过**当前帧 extrinsic + intrinsic 投影到屏幕**，让彩色点贴在真实表面上（RealityScan 风格）：
- 复用 `_projectCameraSampleToScreen`（`capture_page.dart:1374-1391`）做 world→screen；ARKit 约定相机看向 **−Z**，intrinsics 是 `.landscapeRight` 下按 `imageWidth×imageHeight` 算的。
- 预览点 8Hz、位姿 60Hz —— **缓存最新 voxels，用每个新 extrinsic 重投影**，避免点跟手抖。

**(d) 接进 CapturePage（并排新增，不动 dome），再 build 到真机。**
- 推荐 **Option A（新 overlay 层，最低风险）**：在 `capture_page.dart` 的 `_PhotoPositionOverlay`（`:1277`）附近新增 widget `_ArCoverageOverlay`，参数 `final RealtimeCapturePreviewModel model; final DomeTargetPoints targetPoints;`，用 `AnimatedBuilder(animation: model)` 或 `Listenable.merge([model, targetPoints])`（`DomeTargetPoints` 是 `ChangeNotifier`）。
- **插入位置：build Stack 里 `:970` 与 `:972` 之间**（即 `_PhotoPositionOverlay` 块之后、`_MotionSpeedToast` 之前），用 `IgnorePointer` 包裹，保持 `if(_recording)` 守卫：
  ```dart
  if (_recording)
    Positioned.fill(
      child: IgnorePointer(
        child: _ArCoverageOverlay(model: _previewModel, targetPoints: _targetPoints),
      ),
    ),
  ```
  这样它在相机预览之上、在 toasts/底部面板之下，dome mini-map（`_DraftPointCloudMiniMap` `:1500`）和 `_CaptureButtonOrDome`（`:1963`）完全不动。
- **无需改 session**：数据已经全部经 `_previewModel` 与 `_targetPoints` 流动。
- 若想做成可切换的"模式"（Option B）：在 `_CapturePageState` 加 `enum CaptureMode{dome,coverageOverlay}` + 默认 `dome`，用独立 `if` 条件 `&& _mode==...` 共存，**绝不在 `_onPoseTick` 里分支**；如需不同 ingest 行为，照 `pointConfig`/`targetZoneMode` 的方式**参数化 `CaptureSession`**（`:435-437`），从 `:263` 传入。

> 注意：overlay 只在 `_recording` 时有 live 数据（`_previewModel` 在 start `:480` / stop `:435` 被 reset，否则 `lastPose`/`cameraSamples` 为空）—— 匹配现有 `if(_recording)` 守卫。

---

## 8. 如何构建并装到真机测试

ARKit 需要**真机**（`flutter devices` 已确认 Kyle's iPhone 无线连接，id `00008120-00146C4A1AEBC01E`，iOS 26.5）。Flutter 3.41.8 / Dart 3.11.5。签名 team `26AH7V448L`（Automatic），bundle id `com.kyle.PocketWorld`。

主路径（release，ARKit 性能推荐）：
```
cd /Users/kaidongwang/Developer/pocketworld
flutter pub get
flutter run --release -d 00008120-00146C4A1AEBC01E
```
（也可 `-d ios`；需要断点/热重载用 `--debug`，ARKit 在 debug 下也能跑。）

若 Pods/codegen 漂了或原生链接报错，先刷新：
```
cd /Users/kaidongwang/Developer/pocketworld
flutter clean
flutter pub get
( cd ios && pod install )
flutter run --release -d 00008120-00146C4A1AEBC01E
```

仅构建不自动启动：`flutter build ios --release`。
Xcode 兜底（**必须用 `.xcworkspace`，不要 `.xcodeproj`**）：`open /Users/kaidongwang/Developer/pocketworld/ios/Runner.xcworkspace`，选 Runner scheme + Kyle's iPhone，确认 Signing 是 team `26AH7V448L` 自动管理，Cmd-R。

预检：
- 工作树应干净（分支 `capture-ar-coverage`）。
- **先确保 LFS 资产是真文件**：`git -C /Users/kaidongwang/Developer/pocketworld lfs pull`（`.onnx`/`.glb`/`.ktx` 是 LFS-tracked，pointer stub 会让 MobileSAM/Thermion 运行时崩）。
- iPhone 需已信任配对 + **Developer Mode 开启**（iOS 16+）。

---

## 9. 已知坑

- **LRU 驱逐 = backtrack，必须修**（第 7a）。`_pruneVoxels` `:184-195` + 调用 `:148-150` 是 "回头看已扫区域又空了" 的直接原因。
- **`rawFeaturePoints` drift**：位置已是 world-space，**别叠 pose 变换**；world origin 由 native anchor 每帧重读维持（`:1367-1377`）。
- **CoreML（后续 DiffMVS 里程碑）必须 `.cpuAndGPU`，绝不 `.all`**（ANE 抖动 10×）。
- **DiffMVS source-view 选择必须保证 baseline ≥ ~6cm**。
- **稀疏点会误导框选**：v1 稀疏覆盖率够用，但**稠密 DiffMVS 才是可信框选（preview≈final）的后续里程碑**。
- **重度拍摄的热/电**：4K video + 持续 ARKit + overlay 会发热掉电；注意节流（点流已 8Hz，overlay 用缓存重投影别每帧重算全部 voxel）。
- **confidence 硬编码 1.0**（`:1761`）无信号，别拿来做覆盖率决策。
- **`level`-in-key churn**（`:181`+`:160`）会让同一表面在 LOD 间闪烁并加速撞上限 —— 修 key 时一并解决。

---

## 10. 参考资料 & 记忆

- 研究笔记：`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/capture_ux/RESEARCH_realityscan_capture.md`
- v1 计划：`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/capture_ux/PLAN_capture_ui_v1.md`
- **算法原型（覆盖率累积参考设计，正被 in-app 实现取代）**：`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/capture_ux/coverage_replay.py` —— 它按拍摄顺序 backproject 每帧 DiffMVS 深度进固定世界 voxel 网格，累积 per-voxel camera count + azimuth diversity（**单调、无 drift/backtrack**），写 voxels.bin/meta.json/cams.bin 给 Three.js viewer。**它的覆盖率累积逻辑就是你要在 app 里复刻的参考。**
- Web 原型输出：`/Users/kaidongwang/Desktop/pocketworld_coverage/`（meta.json: 459,774 voxels / 317 steps / voxel 0.03m / conf_thr 0.3；voxels.bin 16M；cams.bin）。
- DiffMVS engine（后续里程碑）：`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs/`；export `.../tools/python/pw_export_coreml.py`；CoreML 模型 `.../tools/ios_diffmvs_bench/DiffMVSBench/DiffMVS.mlpackage`（4.9M）；缓存 `.../tools/python/diffmvs_out/p1cache_diffmvs.npz`（123M）。
- 414 帧数据：高清 JPEG `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres`；位姿 manifest（**路径已校正，在 dataset 内**）`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/external_pose_k_vs_res_2026_06_10/k414_spatial_order_manifest.json`（per-frame {frameID, jpegPath, 4x4 cameraExtrinsic, fx/fy/cx/cy}）。
- 记忆目录：`/Users/kaidongwang/.claude/projects/-Users-kaidongwang/memory/`，相关文件：`MEMORY.md`、`realityscan-mobile-capture-ux.md`、`user-pocketworld.md`、`realityscan-pipeline-architectural-tax.md`、`diffmvs-mobile-assessment.md`、`diffmvs-desktop-validation.md`、`sfm-cross-platform-pose-recipe.md`、`commercial-mvs-algorithms.md`、`monomvsnet-mobile-assessment.md`、`pocketworld-upstream-geometry-winner.md`、`pocketworld-upstream-negative-results.md`。

---

## 11. 工作方式

- **用中文交流**（专业术语保留英文）。
- **只在用户明确说 "commit" 时才提交**，且**先建分支**（当前已在 `capture-ar-coverage`）。commit message 结尾必须有：
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- **抄 SOTA，不发明**；每个依赖**核验 license**（MIT/BSD/Apache）。
- **无 LiDAR**。
- **用户在真机上测试** —— 你必须能从终端/Xcode 构建并安装（命令见第 8 节）。
- 长任务放后台 + watcher。
- **绝不把任何数值阈值说成 RealityScan 的**（第 3 节诚实原则）。