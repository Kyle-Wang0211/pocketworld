# 生产接线勘察:手机端流式稠密预览 + A_refined 无感替换(2026-08-22)

只读勘察产出。范围 = 产品仓 `/Users/kaidongwang/Developer/pocketworld`(下称 PW)、隔离 worktree
`/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/four-workstreams-20260819`(下称 WT)、
`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline`(下称 AC;**注意 aether_cpp 实际在 Aether3D-cross 下,不在 pocketworld 内**;PW/vendor/official_sfm 是其冻结拷贝)、
`~/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/pw_diffmvs_stream.py`。
零代码修改、零 git 命令;全程未遇 dataless 文件(所有 `ls -lO` 旗位为 `-`)。

---

## ① 最小接线图(数据流逐跳:现有 / 缺失)

### C_journal 拍摄期链

| 跳 | 现有(file:line) | 缺失(需新建) |
|---|---|---|
| 1. 帧被接受事件 | `offerFrame` PW/lib/official_capture/sfm_live_recon.dart:651(校验+ARKit c2w→CamFromWorld 换算 :673-682;热闸/spool :700-742)。worker `frame_done` 消息 :1203,成功/失败统一发 `SfmLiveFrameFed(seq, frameId, elapsedMs, result, jpegPath)` :1331(spool 不可读路径 :937)。UI 监听:ar_capture_page.dart:1634 `recon.events.listen(_onSfmEvent)`,ok 分支 :1805 | C_journal 的订阅者本身(新 Dart 模块,挂同一 events 流即可,零 ABI 改动) |
| 2a. 冻结 pose | 每注册帧的 ARKit CamFromWorld(quat wxyz + t + 相机中心)已在 `SfmFedFrameMeta` :359-398,喂帧时填 :684-698,并**已持久化**到 `<captureDir>/official_sfm_fed_frames.jsonl`(`_persistFedMeta` :1113-1145,含坐标约定声明字段)。live 流式云的 gauge 钉在 ARKit-world(:1843-1846 注释),ARKit pose 与 preview 云同系 ⇒ C_journal 用它是自洽的 | 无(若坚持用 SfM-live 解算位姿:native 无导出口——official_sfm_c.h 只有 `pwofficial_get_poses`(读 finalize recon,:411)与 `get_preview_points/get_preview_tracked`(:415/:419,只有点+track 无 pose),与 08-19 定案一致。那要新增 C ABI,不建议进最小切片) |
| 2b. 冻结 depth range | preview 快照**带全量点云+逐点 track 观测**:`sendSnapshot(preview:true)` 读 `previewTracked()` :1793-1794,快照字段 xyz/rgb/obsOffsets/obsFrameIds/obsXY :101-117。由"帧 f 观测到的点 + f 的 ARKit CamFromWorld"即可复刻 pw_diffmvs_stream.py:112-122 的 drange(p2×0.70‥p99.5×1.5,<8 观测回退 0.3/4.0) | Dart 端 drange 计算器(~50 行纯函数)。**节奏缺口**:preview 快照是 checkpoint 节流(`streaming_global_ba` 约 8 次/拍摄;逐帧的 `streaming_local_ba_live` 是默认关的实验臂,ar_capture_page.dart:1741-1748)⇒ 逐帧冻结要么挂"FrameFed+最近一次快照",要么接受 checkpoint 粒度 |
| 2c. 冻结 source list | 同一快照的 obsFrameIds 给出帧间共享 track;相机中心在 `_fedMeta`(:531 `fedFrameMeta` getter 公开)⇒ 可复刻 covis_select(MVSNet 三角化角)+ nearest(min_base 0.06m)回退 | Dart 端选源函数(~80 行;语义抄 pw_diffmvs_stream.py:66-69/:125-126 或 AC include/aether_l1_plan.h:150-201 的 C++ 端口) |
| 3. 推理(dense runner) | **产品仓零接线**:`grep pwofficial_dense/official_dense` 在 PW/lib、ios/Runner、Podfile、pubspec 全空;PW/vendor/ 只有 aether_ffi、lepton_jpeg、official_sfm。接口边界已备好:`DenseStageLauncher` PW/lib/official_capture/dense_stage.dart:65-73(isAvailable + start 立即返回),全局注入点 :91(默认 `UnavailableDenseStageLauncher` :79-88,诚实报 unavailable)。UI 已接:ar_capture_page.dart:2444-2461(`_startDenseStage`,传 captureDir/sparsePlyPath/pointCount/selection)与 :4037-4047(isAvailable 灰按钮);sparse_cloud_viewer_page.dart:204-218 与 :677 | ①launcher 真实实现(新 Dart 文件);②FFI 绑定;③vendor/official_dense 装进产品(见④,WT 是 source-only 脚手架,`pwofficial_dense_run` **尚无张量参数、fail-closed 返回 MODEL_IO_UNVERIFIED**,张量 ABI 未冻结) |
| 4. 增量融合 | 设备端**零实现**:WT/vendor/official_dense/src/pwofficial_dense_fusion.cc 只有 15 行占位。host 语义已证:pw_diffmvs_stream.py 的 dep-graph READY(:72-75)与 streamed==monolithic 逐位验证(:201-226) | 官方 filter.py 融合(photo 三阶段 AND + geo_mask≥3 + 深度平均)的 native 移植 + READY 调度。四件套里最大的一件 |
| 5. 几何块→renderer | `SfmPreviewOverlay` ar_capture_page.dart:3998(`snapshot: _sfmSnapshot` :4000)→ SparseCloudView(sfm_preview_overlay.dart:103,注释 :79"同一个 SparseCloudView 实例、同一份相机,零跳变")。数据以 xyz/rgb 数组 prop 传入(sparse_cloud_view.dart:280-283),换数组即换云:painter 颜色缓存/fit 缓存按数组 identity 键控(:1119-1125、:1172)自动重算 | 无"append"式增量 API——每次全量换数组,`_displayColors` 全量 O(n) 重算 :1126-1162。checkpoint 节奏(~8 次)可接受;逐帧+稠密百万点级需另评(渲染热预算判决:卡片=缩略图/详情=SparseCloud) |

### A_refined 替换链

| 跳 | 现有(file:line) | 缺失 |
|---|---|---|
| 后台重推三输入 | refined 位姿:`pwofficial_get_poses`(official_sfm_c.h:411,REFINED 后读 refined recon);refined 点+track:`get_points_tracked` :404;depth range/选源可由 AC aether_l1_plan.h 的 header-only 端口直接算(见③) | A_refined 驱动器(把 refined 三输入喂 runner 的后台任务) |
| 原地替换 | **先例现成**:LOCAL→REFINED 静默换 = colorize 尾部 `setState(_sfmSnapshot = display)` ar_capture_page.dart:2248-2252;SparseCloudView State 存活(相机 _yaw/_pitch/_zoom/_panX/_panY 在 _SparseCloudViewState :323-328),外加 initialCamera/onCameraChanged 上报(:273-277)与页面级 `ValueNotifier<CloudViewCamera?>` sparse_cloud_viewer_page.dart:128/:540 | dense→refined 替换只需复用同一 pattern(几十行) |
| 选区/视角保留 | SelectionBox 持久化到 `<captureDir>/kSelectionBoxFileName`(viewer_page :188-194 写、:159 `SelectionBox.loadFrom` 读、AR 页 :2469 同源);3D 框顶点 `selectionBoxCorners` sparse_cloud_view.dart:30;viewcube/朝向预设 `kOrientationPresets` selection_tools_layer.dart:37,`rectPoseOverride` sparse_cloud_view.dart:140 | ⚠️ **坐标系风险**:C_journal 云在 ARKit gravity 世界;A_refined 在 COLMAP 系再经 gravityAlign+scaleAnchor(快照自带 `gravityAlignQuatWxyz` :135、`scaleAnchorFactor` :146、raw 真值 `posesPackedRawColmap` :141)。两系之间是一个相似变换,不显式桥接则替换瞬间选区框/相机 pivot 漂移。需要变换器(材料都在快照里,~100 行)+ 真机肉眼验证 |

---

## ② 缺口清单(按四件套,含量级与风险)

**A. dense runner 接入**
- A1 冻结 `pwofficial_dense_run` 张量 ABI(现声明刻意无张量参数,include/pwofficial_dense_c.h:70-77)——native ~200-400 行 + 头文件改;**高风险**(七输入/四输出名已知但符号维度与前处理/持久噪声/golden 契约未签,WT README 明言)。
- A2 Dart FFI 绑定 + DenseStageLauncher 实现:2 个新文件,~300-500 行;低风险(接口边界已定)。
- A3 vendor/official_dense 装机:平移目录 + Podfile 一行;**中风险**——WT 无二进制,candidate_v2 构建物在 `progecttwo/_artifacts/four_workstreams_20260819/official_dense_candidate_v2`(V3 树 efac60d8…),`promote_official_dense.py` 现拒绝一切生产激活(ACTIVATION_LAYOUT_BLOCKED),激活布局要另签。
- A4 模型资产:casdiffmvs_v5_clipfix.onnx(sha 已锁 84135dcd…)进 Resources,16MB 级考量不适用(app bundle)。

**B. 增量融合**
- B1 READY/dep-graph 调度平移(语义 30 行,实现 ~100-200 行 Dart 或 native);低风险,host 已证 streamed==monolithic 逐位。
- B2 融合本体 native 移植(官方 filter.py 三阶段光度门+geo_mask≥3+深度平均):~500-1000 行 C++,1-2 新文件;**高风险**——必须金标准逐层对拍(08-14 教训),且"先 100% 复刻官方"红线适用。
- B3 逐帧推理缓存(冻结输入→缓存深度图,依赖齐了融合):磁盘布局+生命周期 ~200 行;中风险(18GB/手机内存预算,深度图必须落盘不驻留)。

**C. renderer 状态持久化**
- C1 相机/选区已持久化(见①表);**零缺口**。
- C2 dense 云重载:viewer page 已有 PLY 盘读(sparse_cloud_viewer_page.dart:31-58 二进制 LE 解析);dense PLY 走同码路,~0-50 行。
- C3 大点云渲染能力:现 renderer 是 CPU 投影 CustomPainter(sparse_cloud_view.dart:1436 paint,drawAtlas 路径 :1586-1608);千万点级不可行,但热预算判决已把详情页钉在 SparseCloud 稀疏/降载展示——**本切片不动,超出范围**。

**D. A_refined 原地替换**
- D1 替换器:复用 `_sfmSnapshot` swap 先例,~50-150 行;低风险。
- D2 坐标系桥接(ARKit 世界 ↔ refined 世界):~100 行 + 真机验证;**中风险,最容易被忽略的一处**。
- D3 交付层事务:WT delivery_artifact.dart 已完整(见④),cherry-pick 即可;低风险。

---

## ③ OFFICIAL_AETHER_GHOST_MASK 语义核实结论

- **触发链**:env=1 时,finalize REFINED 尾部(AC src/official_aether_sfm_c.cc:8446 → `MaybeWriteGhostMask` :7637,env 检查 :7639-7640)跑鬼层 mask(ghost_mask.bin/json,:7663-7706),随后 :7720 调 `WriteL1PlanSidecars`(:7504-7635)写 **arbitration_plan.json / arbitration_plan.bin / arbitration_points.bin**。plan 用最终 recon 的 CamFromWorld/K(:7560-7572)、tracks(:7583-7593)、jsonl 的 JPEG 映射(:7516-7532,读的正是 Dart `_persistFedMeta` 写的 official_sfm_fed_frames.jsonl)。
- **历史语义 = 鬼层歼灭战役 L1 仲裁,不是中性稠密计划**。07-20 E25 签决停用:iOS 插件 setenv 已删(PW/ios/Runner/OfficialAetherARKitPlugin.swift:403-416,注释明言回滚=加回一行);Dart 侧 SfmLiveArbitrateDone 事件/FFI/ghostSpatialKeepIdx 管道已删(sfm_live_recon.dart:352-354);C 符号 `pwofficial_arbitrate`(消费 sidecars,official_sfm_c.h:324 注释、:432 声明)仍在 ABI 但无 Dart 调用方。
- **schema 是不是稠密三通道的现成序列化?——是,但挑选政策不是。** `L1PlanRef {frame, srcs[4], dv[384], 4 级 proj matrices}` + `L1Frame {w2c 4×4, K@896×512, jpeg, obs}`(aether_l1_plan.h:70-95)正是 pose/depth range/source list 三通道,dv 由该 ref 自身稀疏观测深度 p2×0.70‥p99.5×1.5 生成、bit-match `depth_values_tensor`(:123-134),选源 = covis_select 端口(:150-201)——常量与生产口径一致(kProcW=896/kProcH=512/kNumViews=5/kNumDepth=384,:56-59)。但 **ref 挑选是 band15 鬼层 marked-cell 的预算化贪心 set-cover**(:5-16,时间预算/960ms):直接复用只会给鬼层嫌疑区域排推理,不产整云稠密。
- **建议**:借 schema 与 header-only 函数(dv linspace、drange、covis_select、proj 构造可直接 include 复用),**不要复用这个 env 名与开关**——它把 plan 生成捆死在 ghost mask 计算与"停用中的战役"上,混淆风险实在;C_journal 冻结应新开自己的 env/文件名。另注意它只在 finalize 尾部执行(吃最终 recon),天然对位的是 **A_refined 的三输入冻结**,而非拍摄期 C_journal。

---

## ④ 可复用资产清单

**WT lib/official_capture/delivery_artifact.dart(507 行,未提交)+ test/delivery_artifact_test.dart**
- dense/sparse 交付选择器 `deliveryPlyFor`(:200-220):dense 只在 `deliverDense` 旗(默认 **false**,:12)且 `DenseArtifactProof`(fileName/complete/byteLength/pointCount/md5,:65-79)全对齐时选中,任何失败回退 sparse;严格二进制 PLY 头校验(:326-373)、有限性逐顶点扫描(:428-458)、句柄级 stage→verify→commit 事务(:118-163,不重开路径防 inode 换)。文件名常量 `official_dense.ply`/`official_sfm_sparse.ply` 与产品现有 persist 路径(ar_capture_page.dart:2221)一致。**可直接 cherry-pick,零依赖冲突。**

**WT vendor/official_dense(source-only 脚手架)**
- 7 符号 C ABI(create/destroy/run/receipt/last_error/backend_name/abi_version;abi_symbols.txt 核对无误);ORT 1.29 WebGPU EP、图优化锁 `ORT_ENABLE_BASIC`(与 32145 tanh bug"BASIC 干净"定罪一致);模型/include/runtime/ORT 修订全 sha 锁定;`run` fail-closed(张量契约未冻结前不推理)。src 共 314 行(ort.cc 219 / sim 80 / **fusion 15 行占位**)。Frameworks/libs/Resources 目录为空——无二进制入库。构建物:candidate_v2 已验证于 `progecttwo/_artifacts/four_workstreams_20260819/official_dense_candidate_v2`,未安装未激活;promote 脚本拒绝生产激活。

**pw_diffmvs_stream.py 可平移语义**
- READY 判定:`dep(n) = {n} ∪ nearest(n, NEIGH, refs, min_base_fuse)`(:72-75),由相机中心提前确定 ⇒ 调度确定性、"绝不在邻居深度存在前融合";verify 模式证明 streamed==monolithic **逐位一致**(:201-226)——无损铁律的现成验证法,装机前应照搬成 A/B 门。
- drange(:112-122)与 covis_select→nearest 回退(:125-126)——Dart 冻结器的参考实现。
- contend 模式(:256-319)的"重叠净收益=可藏融合时间−推理污染罚时"账法,可平移为设备端是否开推理-融合重叠的判据。
- 不可平移:mp.fork 池(Dart 侧用 isolate;PW 已有 worker isolate 先例)。

**AC include/aether_l1_plan.h(631 行,header-only)**
- `detail::depth_values_tensor` 端口(float64 linspace 末转 float32,bit-match)、drange 端口、covis_select 端口、make_proj_matrices 端口——C++ 侧三通道计算全套现成函数,可脱离 set-cover 政策单独 include。

**已在盘上的冻结原料**
- `official_sfm_fed_frames.jsonl`:每注册帧 frameId/jpegPath/grayW/grayH/captureTimestamp/ARKit CamFromWorld(quat+t)/相机中心 + 坐标约定声明(sfm_live_recon.dart:1113-1145);C++ 解析先例在 AC :7516-7532。

---

## ⑤ "最小垂直切片"建议改动清单(供签字;**全部旗默认关**)

1. **新** PW/lib/official_capture/dense_journal.dart:订阅 `SfmLiveRecon.events`(SfmLiveFrameFed + SfmLivePreview checkpoint),按 pw_diffmvs_stream 语义冻结三输入,append 到 `<captureDir>/dense_journal.jsonl`。旗 `kDenseJournalEnabled = false`。零 ABI/零 native 改动。
2. **新** PW/lib/official_capture/dense_stage_impl.dart:`DenseStageLauncher` 实现骨架;启动路径注入 `denseStageLauncher`(runner 未装机时 `isAvailable=false`,UI 行为不变——dense_stage_boundary_test.dart 已锁默认语义)。
3. **cherry-pick** WT 的 delivery_artifact.dart + delivery_artifact_test.dart 进 PW(`kOfficialAetherDeliverDenseDefault=false`,独立无依赖)。
4. **平移** WT/vendor/official_dense 目录进 PW/vendor(不进 Podfile,或进 Podfile 但 run fail-closed ⇒ 行为等价于未装);张量 ABI 冻结**单独一笔另签**,不进本切片。
5. A_refined 替换器与 ARKit↔refined 坐标桥:等 runner 有真输出后另签(先例与材料已备,见①D 表)。
6. **不动**:sfm_live_recon.dart 现有 ABI、vendor/official_sfm、OFFICIAL_AETHER_GHOST_MASK 及其 sidecar 链。

---

## ⑥ 勘察意外与档案矛盾

- **锚点漂移**:ar_capture_page.dart 的稠密调用点实为 **:2448**(start)与 **:4039**(isAvailable),勘察提示里的 2333/3643 已过期;sparse_cloud_viewer_page 的 :204/:677 准确;offerFrame :651 与 SfmFedFrameMeta 位置准确。
- **aether_cpp 路径**:勘察提示写"aether_cpp/official_pipeline"仿佛在 PW 内;实际在 `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline`。PW/vendor/official_sfm 与 PW/.claude/worktrees/ 下两个旧 worktree(beautiful-williams-464029、epic-volhard-4524ea)各有一份同语义头文件——平行同名三处教训再次适用。
- **"live 位姿无导出口"定案再确认**:属实,且比定案更细——preview 快照虽无 pose,但**带全量点+逐点 track 观测**(depth range/选源的原料够),ARKit 逐帧 pose 已持久化在 jsonl;三输入冻结在 Dart 侧**零 native 改动即可起步**,这是本次勘察最有利的一条。
- **融合是真空**:pwofficial_dense_fusion.cc 15 行占位。四件套里"增量融合"不是接线问题而是移植问题,量级最大。
- **每帧冻结的节奏缺口**:depth range/source 的数据源(preview 快照)是 checkpoint 节流(~8 次/拍摄);逐帧粒度依赖默认关的 `streaming_local_ba_live` 实验臂,或接受 checkpoint 粒度——需要用户拍板。
- **无 dataless 文件**;未发现与既有档案(08-19 核查、E25 停用、热预算判决)矛盾之处,仅上述锚点/路径级修正。

---

## ⑦ 主会话核查勘误(2026-08-22,三处抽查)

- ✅ preview 快照观测字段(obsOffsets/obsFrameIds/obsXY)属实——"三输入冻结零 native 起步"成立。
- ✅ 稠密调用点 :2448/:4039 属实;文件全路径为 PW/lib/**ui**/official_capture/ar_capture_page.dart。
- 🔴 **③节"常量与生产口径逐位对齐"勘误**:aether_l1_plan.h 实测 kProcW=896/kProcH=512/
  kNumViews=5(1 ref+4 src)/kNumDepth=384——这是鬼层战役 L1 lane 自己的配置,
  **不是**今日官方稠密档(768×576、num_view=10)。结论修正为:**schema 结构与
  header-only 函数(dv linspace/drange/covis_select/proj 构造)可借,但全部常量必须
  按官方档重参数化;"bit-match"承诺只在原 896×512@5 配置下验证过,重参数化后须
  对 host 官方链重做逐位对拍**。

## ⑧ 用户签字(2026-08-22)

1. **⑤节最小垂直切片:签,开工**(全部旗默认关,只在隔离 worktree,不碰主仓)。
2. **冻结节奏:逐帧粒度**(用户原话"我需要直接做逐帧粒度")。实现路线=复用
   `boot.arEveryFrame` 实验臂(AR-EVERY-FRAME 2026-08-04,默认关):开启后每个被接受帧
   推送 source='streaming_local_ba_live' 的 previewTracked 快照(sfm_live_recon.dart:2050-2072,
   复用 beforeGlobal 零二次拷贝;AR 侧 400ms 合并节流是既有传输防线;删除帧也会推
   :2228-2240)。dense_journal 冻结器订阅该流+SfmLiveFrameFed,逐帧记账。
   ⚠️ 物理诚实账:冻结是逐帧的,但几何**生长速度受推理钳制**(A16 2.0-2.7s/帧 vs
   采集 ~1 帧/s)——预览按推理节奏长,队列保证零丢帧;"每完成一帧推理就长"是准确承诺。
   ⚠️ 热账:SfM+逐帧快照+推理并发的整机热口径是热曲线定案的未覆盖项,装机后须真机复核。

## ⑨ 逐帧冻结器实现的三条口径核查(主会话,按源裁决)

1. **源数=10,实现正确**(agent 自疑"是否该是 9"):官方 A_refined 链的 pair.txt 实测
   **132/132 个 ref 各恰有 10 个源条目**(_host_experiments/pose_ablation_20260818/mvs_P16k/pair.txt),
   与 colmap_input 的 `--num_src_images 10` 一致 ⇒ journal 冻结 10 个源与官方产物同形。
   (若 runner 日后只吃 9,取前缀即可;冻结 10 是超集不是偏离。)
2. **深度符号翻转 `-(R·X+t).z` 必需且正确**——规格漏写,agent 补对了:
   sfm_live_recon.dart:1127-1134 明确声明"CamFromWorld in ARKit CAMERA AXES
   (COLMAP C=diag(1,-1,-1) flip **NOT** applied)",ARKit 相机 −Z 朝前 ⇒ 前方点的 z 为负;
   不翻则 z>0.05 门滤光全部点、journal 全废。journal 行内 pose 仍 raw 入账(正确)。
3. **s_al=1 成立**:host 除以 s_al 是因 COLMAP 世界尺度任意;ARKit gravity 世界是 IMU 米制,
   回退常量 [0.3,4.0] 本就是米 ⇒ 直接以米入账正确。
4. 行号勘误采纳:covis_select 本体在 pw_diffmvs_sfm_trio.py:404-429(stream.py:66-69 是 nearest)。
5. 纪律自查复核通过:主仓 35 项 WIP 一字未动(HEAD ab3ad77 是另一条线的提交);
   worktree 仅 4 新文件 + 3 项他人未提交资产,零 commit/push/install。
