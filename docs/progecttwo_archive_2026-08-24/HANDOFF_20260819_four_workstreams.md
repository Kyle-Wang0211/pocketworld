# 交接任务书:四条工作线(2026-08-19 晚)

你接手的是"稠密优先架构"落地的四条线。**前置案卷必读**(全部在研究仓
`~/Developer/Aether3D-cross/pocketworld_research_benchmarks`,分支
`research/lightglue-frontend-spike-2026-08-17` 与 `research/casdiffmvs-official-replication-2026-08-17`):

- `experiments/arch_decision_dense_first_2026-08-18/DECISION.md` — 架构五条决策(用户拍板)
- 同目录 `INSTALL_QUEUE.md`(**含 08-19 审计后的强制修订段,以修订段为准**)
- 同目录 `PROVENANCE_AUDIT.md` — 每个数字的出处审计(3 处归因错误已修/自定数字 10 项清单)
- 同目录 `WALL_BATTLE.md` — 墙面战役全档(五连败+真凶+等重训)
- `experiments/casdiffmvs_wgsl_port_2026-08-17/a4_result/A4_RESULT.md` — 真机五关全档

## 用户铁律(违反任何一条立即停手报告)

1. **复刻不自研**:装机配方每个参数必须有官方出处(file:line 或文档原文);机制探针可以自研
   证因果,但装机必须官方血统。给子 agent 的任务书要写死"禁止发明公式",验收逐参数核出处。
2. **交付绝对无损**:永久缺帧绝对禁止;fail-safe 只许推迟不许丢数据;交付全量点云一个点不动。
3. **不改采集 UX**;**永不用 LiDAR**;**热稳定是硬约束**(A16 实测:满载 2 分钟出现降频拐点,
   平台 +21%,4.5 分钟 +34% 未收敛——调度必须尾随让路)。
4. **异常旗=停下找用户**,禁自判"特性非损失"续推(轨迹 −31% 事故前科)。
5. **装机合同**:产品仓(`/Users/kaidongwang/Developer/pocketworld`)与管线仓
   (`~/Developer/Aether3D-cross/aether_cpp`)分开管理;单变量装机;母版快照已做
   (`/Users/kaidongwang/pw_master_snapshots/20260819_phase0/`,85,022 文件三重验证);
   framework 重建必须走 `vendor/official_sfm/scripts/rebuild_native.sh` 的 SHA-promotion,
   **手搓 cp .a = 合同违约**。
6. **装机≠生效**:每组装完必须真机验证真跑了(E24 陷阱:devicectl 同 build 号覆盖装机
   **不换二进制**——每次验证前卸载→重装→拉 telemetry build_stamp 核验)。
7. 环境:Mac M3 **18GB 内存**(MPS 单帧串行,别并发;曾两次搞到 swap 崩会话)、盘常年紧
   (开工先 df);**/tmp 会被系统清空**(已四咬),耐久产物一律落
   `/Users/kaidongwang/Documents/progecttwo/`;判据类输入素材第一时间落耐久盘。
8. 工程卫生:长命令输出重定向文件再 poll(**禁 `| tail` 直连**,三次被咬);
   `pgrep/pkill -f` 用 `"[x]xx"` 写法防自匹配(三次被咬);跨重建逐视图对拍**按 image.name
   配对永不按索引**(两次被咬);workflow 栅栏只捆真依赖(交付物别被无关慢臂堵死);
   调查类子任务一律写死时间上限。
9. 永远用中文回复用户。

## 已判死清单(勿复活,案卷里有死因)

fp16 v1 全转(重建层 −10.9% 点数超地板 69×,系统性非噪声)/ 融合期跨走廊门 / conf 阈值门
(AUC 0.21 反向)/ DA3 一切用途 / 逐帧锚点校正 / 平面先验+全局残差门 / 显示层过滤(肉眼无效)
/ 图切分挤水分(全修 A/B −0.8%=噪声,2.01s 是真 GPU 受限)/ 关键帧筛选(覆盖 1:1 同跌)
/ 为美观抽稀预览(用户:"没必要为了看起来稀疏而抽稀")。

---

# 工作线 ②:GTO 匹配器装机(状态:✅ HOLD 已解除——2026-08-19 用户签字:COLMAP known-pose 口径)

> **用户签字(2026-08-19)**:口径 = **COLMAP known-pose 家**(px 阈值、零 octave 依赖)。
> 背景:原版门规格含两处 ORB-SLAM 出处错误(见下方勘误块),且 ORB 家族逐 octave 门
> 在我们链上结构性装不了(DSP-SIFT keypoint 无离散 octave,colmap/feature/types.h:52-100,
> 三条提取路径 clamp 后即弃 octave;TVG 入口只收 2D 点,mandatory_gravity_tvg_v1.cc:56-64)。
>
> **签字后的完整配方(全 COLMAP 血统,零自创)**:
> - 极线预门 = 已有 guided 语义(official_gpu_match.mm 即 COLMAP guided E/F Sampson band
>   复刻,注释自证 :423/:921-929),由 ARKit 先验位姿驱动:有内参走 CALIBRATED(E)分支;
>   门宽 **max_error = 4.0px**(COLMAP 默认,two_view_geometry.h:119)——
>   **唯一契约数字就是像素域的 4.0**,归一化与平方一律交给既有转换链(见下方单位块)。
> - **ratio = 0.8**(COLMAP 标准,sift.h:113);互检开(sift.h:119-120)。
>   原 0.6 自定值废弃。
> - 后置校验 = 现行 5 处 TVG("colmap defaults")原样保留,不加任何 ORB 门。
> - w99 只保留其判决效力("原始 ARKit 位姿可信,可直接建门"),其像素数字不进任何阈值。
> ⚠️ 配方与 08-18 实验版(ratio 0.6 + 1.96px)不同——**10.2ms/对与重投影 1.1563 的旧数字
> 不再是承诺**,装机后按本节验收协议(真机交替 A/B + 粗糙度尺 + 132/132)重测重报。

## 目标
生产稀疏管线的匹配器加 GTO 臂(极线门控互检),开关默认关,LightGlue 不在生产内(从未装过,
现生产是 DSP-SIFT 暴力 ratio 0.8)。GTO 的角色=**内部位姿引擎**(用户永远不看稀疏云)。

## 已验证的事实(直接引用)
- w99 判决(commit 见 phase0 档):**原始 ARKit 位姿可直接建门**——1192 个生产验证内点对上,
  超阈(w99>2%对角线=100.8px)仅 1.3%(判据线 10%),不可信 0.1%(线 5%)。
  w99 分布 p50=19.8px / p90=45.9px(**4032 宽坐标系,对称口径**)。
- 位姿层 GTO≈LightGlue(gauge 残差 2.08mm < 两次 LightGlue 互差 2.21mm),
  稠密层 +0.79% 点数在噪声地板内。

## 门规格(按出处审计修订版执行,PROVENANCE_AUDIT.md 修正 1-7)
- **预门(极线)**:σ=1px = ORB-SLAM octave-0 档(最严;官方生效门实为 1.96~7.0px 逐层),
  出处 ORB_SLAM2/src/ORBmatcher.cc:154-156(`dsqr<3.84*mvLevelSigma2[octave]`)。
  🔴 三个口径必须声明并一致:①分辨率——门在哪个坐标系表达就按该分辨率定数
  (ORB-SLAM 等效门 @4032 宽 ≈12-13px);②单侧点线距(ORB 口径)vs 对称双向取大(我们
  w99 的口径)——门与尺子同口径,禁跨口径搬数;③生产吃原始 ARKit 位姿 ⇒ 门宽按 w99
  分位数定(p90≈46px@4032 起步,这是"经验分位数标定的 χ² 门代理",OKVIS 在真协方差缺失时
  的官方同款做法)。逐对自适应若做:AC-RANSAC(OpenMVG)/MAGSAC++(OpenCV USAC)现成机制,
  或固定门对齐 COLMAP `TwoViewGeometryFromKnownRelativePose`(two_view_geometry.cc:1586-1626,
  tangent Sampson,默认 max_error=4.0)——三家口径互不相同,选定一家写死。
- **ratio**:0.6 在 ORB-SLAM 三角化路径是**死参数**(LocalMapping.cc:215 传入但
  SearchForTriangulation 从不读)。二选一并标注:走官方有效门浮点等价(TH_LOW=50 的
  float 等价阈自定,如实标注)或 ratio=0.8(Lowe/COLMAP 标准,COLMAP sift.h:113)。
- **互检**:保留(kernel 硬约束,pwofficial_gpu_match.mm:82-83 本来就做),
  出处标 COLMAP 默认(sift.h:119-120),不标 ORB-SLAM。
- 🔴 **"三道官方后置门"勘误(2026-08-19 按钉死 commit 4452a3c 逐行核查,原版 3 条错 2 条)**:
  ①重投影 χ² 门:**真后置门,保留**——但仅单目分支是 5.991·σ²(2DOF,
  LocalMapping.cc:633-634/:659-660),双目观测分支是 7.8·σ²(3DOF,:645/:670)。
  ②视差角:**不是后置门**——是三角化前的方法选择器(cos<0.9998 非惯性 / 0.9996 惯性
  才走三角化,否则用双目深度,纯单目低视差直接丢弃;LocalMapping.cc:582-604),
  且对双目点被 bStereo 短路。原版"后置门"定性错误。
  ③极点邻域:**不是后置门**——是 SearchForTriangulation 的匹配预门,式为
  **d² < 100·mvScaleFactors[octave](即 d < 10·√scaleFactor,不是 10px·scale)**,
  且仅纯单目分支生效(ORBmatcher.cc:1026-1034)。原版公式与阶段双错。
  ⇒ 结合上面 HOLD 块:②③依赖 octave,我们链上无米之炊;整族 ORB 门废弃。
- 🔴 **单位规范(08-19 晚二次勘误——本条曾写"两入口传 16.0",被执行 agent 阻断并经
  源码核查证实是我的单位错误,已废)**:在已签的 calibrated-E/known-pose 口径下,
  upright 的 max_squared_sampson_error 与 CALIBRATED 分支流向 maxResidual 的值都在
  **归一化域**(正确量级 ≈(4/焦距)²≈1e-6),手塞字面 16.0 = 把门放宽约两百万倍 = 关闭几何校验。
  **正确规范**:①唯一契约数字 = max_error **4.0(px)**,全线只在像素域传 4.0;
  ②upright 入口:设 options.ransac_options.max_error=4.0,由函数内
  CamFromImgThreshold 折算+平方(mandatory_gravity_tvg_v1.cc:104-109);
  ③guided 入口:传 max_error_pixels=4.0(默认 kGuidedMaxErrorPixels,:2449),
  由 PrepareGuidedGeometry 按分支产出——CALIBRATED=归一化²(:3559-3562)、
  F/H=px²=16.0(:3571/:3585);kernel 只吃同域平方值不做单位处理;
  ④**16.0 只允许作为 F/H 像素分支的回归断言**出现,任何入口禁止手塞;
  ⑤现行 5 处 TVG 调用点保持不动。
- 🔴 **w99 数字不可搬进 Sampson 门**:46/100.8px 是 4032 宽对称极线距离;
  对称极线距离 ≥ 2×Sampson 且比值无上界(AM-GM,极点近图内时发散),不存在固定换算,
  分位数排序在两个度量下不同。要用 w99 思路,唯一干净做法=同批匹配数据上
  **按目标度量(归一化域平方 Sampson)重算分位数**。

## 接入点(勘察已完成,file:line 全部核实)
- 管线仓 `aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`:
  匹配调度 GpuMatchGemmPairsRetry(:2319-2346)→ 弱符号 `aether_gpu_match_gemm_pairs`
  (产品仓 vendor/official_sfm/src/pwofficial_gpu_match.mm 提供,Metal GEMM);
  **照 EPI-PRIOR 模式**(:2980-3031,env 门 + guided kernel 弱导入 :238 + RunGuidedMatch
  4px band :3833-3848)加 GtoMatchEnabled()/GtoRatio()/GtoEpiPx() 三个 static-cached env 门;
  ratio 消费点 5 处(:5936/6298/9115/12333/12480);TVG 5 处("colmap defaults",
  :5937/6299/9118/12334/12481)收敛成一个 MakeTvgOptions() helper。
- 开关机制:`Documents/official_env.json` → AetherEnvFile.applyFrom
  (lib/official_aether_sfm_ffi.dart:81-104,只认 OFFICIAL_ 前缀,main() await 保证首次进
  native 前应用)。🔴 两个坑:native 门 static cached ⇒ 翻旗必须重启 app;
  TWOLEVEL 符号解析曾让旗打到旧栈副本(:106-108 注释)⇒ **必须加框架导出的遥测计数**
  (device_log 行或 stream_stats 字段)真机自证旗生效。
- env 文件是共享单文件 ⇒ 推旗**读-改-写合并**,别整体覆盖(08-11 事故)。

## 验收(装机≠生效)
- 旗关:完整采集一遍,行为逐字节同今日(负向对照)。
- 旗开:遥测计数非零;**这是语义改动不是无损提速**——匹配数会跌,若出现注册丢帧/轨迹异常,
  **停下找用户**;质量定夺只认**真机交替 A/B**(host 重放绝对数字失真 18-26% 前科,
  噪声地板 18%);表面粗糙度尺子对拍(ALIKED 8.95mm 基准,唯一复现过肉眼判浮点的尺);
  132/132 注册是红线(永久缺帧禁止)。
- 下游复核:GTO 位姿喂 CasDiffMVS 的稠密与 LightGlue 位姿版对拍已做过一次(+0.79% 地板内),
  装机后用真机采集再做一次同口径复核。

---

# 工作线 ③+④:流式调度 + 交付切换(改动清单③④组,已签)

## 前置:①组的产品仓接线(ORT 产物已在,还没进产品)
- ORT 产物:`~/ort_ios_build/build_ios/Release/Release-iphoneos/`(11 个 .a +
  libonnxruntime.1.29.0.dylib 38MB,arm64/minos16.3,WebGPU EP 在 dylib 内)。
  ⚠️ 构建树在用户主目录,建议先归档一份到耐久盘再接线。
- 新建 `vendor/official_dense/` pod(照 vendor/official_sfm 模式:动态 framework、
  **符号隐藏**——防与产品里旧 ORT 1.15.1(MobileSAM 用,Podfile:110-165 -force_load)撞
  OrtGetApiBase;审计修订:藏符号只保链接期,**必须加运行时冒烟**——同一装机里
  MobileSAM 旧路径与 dense 新路径各跑一次金标准比对;退路=dlopen 显式加载(官方唯一书面建议))。
- 会话必须 `ORT_ENABLE_BASIC`(#32145,我们首报未确认;bench_main.cc:104 有样板);
  模型用 `_artifacts/casdiffmvs_onnx_20260818/casdiffmvs_v5_clipfix.onnx`(Cast→int32 版,
  parity 与原版同数,消"not assigned"警告与中段排空)或原版+session config
  `ep.webgpuexecutionprovider.enableInt64=1`(webgpu_provider_options.h:18)。
- 构建目标 iOS deploy ≥16.3(string_utils.h:91 std::to_chars,16.0 编到深处才炸)。
- 接 DenseStageLauncher:`lib/official_capture/dense_stage.dart`(接口 :65,注入点 :91
  默认 UnavailableDenseStageLauncher),UI 已接好(ar_capture_page.dart:2333/3643、
  sparse_cloud_viewer_page.dart:204/677),注释原话"真实实现落地时替换 denseStageLauncher
  即可,UI 侧一行不用改"。开关 OFFICIAL_AETHER_DENSE_ORT 默认 0。

## ③流式调度(开关 OFFICIAL_AETHER_DENSE_STREAM,依赖①)

🔴 **三条边界先钉死**(2026-08-19 用户纠偏后补):
①**live 稀疏的流式一行不碰**——它是采集期的眼睛和位姿来源,继续原样跑;
③号线是给**稠密**加"边拍边长",不是重做任何已有流式。
②这里的"调度"没有任何新算法,就是回答"哪一帧什么时候推理、什么时候融合"
——机制即用户 08-18 拍板的"必须实时生长/第一帧就出现/每帧都更新"的执行体。
③**调度器不挑权重**:checkpoint 换了=换一个 .onnx 文件,调度逻辑零改动
——所以它不必等重训,但见下面④的闸门。

🔴 **位姿现实(08-19 晚核查定案)**:拍摄期 Dart 快照的位姿字段是**全零合成占位**
(sfm_live_recon.dart:1760-1772,故意为之——零四元数让 _gravityAlign 变 no-op),
但真实位姿两处都在:Dart 主 isolate 逐帧 ARKit CamFromWorld(:673-698 _fedMeta)、
native live_recon 的 ARKit 初始化+窗口 BA 精化位姿(official_aether_sfm_c.cc:8995-9002,
:7987 注释"已接近全局最优")——只缺一个导出口(纯工程,照 get_preview_tracked 加一个
读 live_recon 的 pose getter)。refined 位姿要等 finalize phase-2 全局 BA(host 36-66s)。
⚠️ **流式 MD5=官方的已证口径**:实验(schedule_sim.py)是"位姿从第 0 步固定为终态重建、
帧集流式生长"——**只证了"位姿已定"情形**,没证"位姿边拍边变"情形。
由此产生一个只有用户能拍的口径决策(见执行顺序节"成品位姿口径 A/B")。
- 新建 `lib/official_capture/dense_stream_scheduler.dart`:吃 sfm_live_recon 的快照
  (LOCAL_READY/REFINED,sfm_live_recon.dart:1055;offerFrame :651;全部 FFI 走单一
  worker isolate 背压不丢帧),产出位姿 + 稀疏 1%/99% 分位 depth range + **有序 top-10** 配对。
- 调度=冻结(有序 top-10 连续 M 步不变即融;**M 做成可调参数**,默认 10,自定数字已标注)
  + 尾部重融。**闭包必须收严一档**(MD5 战役定案):列表变了的 ref 重推理+重融;
  列表没变但**某个源在它上次融合之后被重推过**的 ref 只重融。
- 融合=官方 filter_depth 语义逐字(photo 三阶段 [0.3,0.5,0.5] AND + geo_mask≥3 +
  深度平均 + num_view=10——引用写"官方 T&T/ETH3D 真实场景档",DTU 档是 5);
  参考实现 `pocketworld_research_benchmarks/experiments/casdiffmvs_blendmvg_scratch_2026-08-16/`。
  kernel 首版落 native C ABI 还是 Dart:**待用户签**,默认建议 Dart 先行(可 debug)+
  性能达标后下沉(融合数学 M3 实测 209ms/帧,手机预算见下)。
- **三条口径铁则**(违者 MD5 对不上官方):①深度平均按源视图次序**有序**浮点累加,
  重融判据比有序列表不比集合;②选源打分复刻官方 calc_score 的**小下标重数**语义
  (occ_i×occ_j 口径会把 44% ref 的 top-10 排错,修正版:
  `experiments/lightglue_spike_2026-08-18/` 相关 streaming 代码);③按 image.name 配对。
- **MD5 验收**(我方独创的强尺,MVS 领域无先例):流式最终产物与官方 batch 逐字节相同;
  绑定同设备同后端,跨设备不可外推;融合内浮点累加次序改动即作废。
- 快速导出(46.6s→0.5s,逐字节等价已证)一并装;冻结 chunk 增量写
  `<captureDir>/official_dense.ply`(格式照 sparse_ply.dart:binary LE xyz f32 + rgb u1)。
- **热预算(A16 实测热曲线)**:冷态 2010ms/帧稳 2 分钟,拐点后平台 2430-2485,4.5 分钟
  2686 未收敛 ⇒ 调度按热态 ~2.5s/帧 规划;用户拍摄节奏 3.5-5 分钟,5 分钟档零尾巴,
  3.5-4.5 分钟尾巴 1-2 分钟(架构已按此签认)。**OOM 纪律**:中间深度图落盘不驻留
  (真机 35 帧 OOM 根治史;host 调试守 mmap)。

## ④交付切换(开关 OFFICIAL_AETHER_DELIVER_DENSE,依赖③产物)
- 新建 `lib/official_capture/delivery_artifact.dart` 唯一解析器 deliveryPlyFor(record):
  旗关 ⇒ official_sfm_sparse.ply(今日行为);旗开 ∧ official_dense.ply 存在 ∧ 完整性校验过
  ⇒ dense;**否则回退 sparse,永不空手**。
  ✅ **此失败语义 2026-08-19 用户签字确认**——执行门文档"决定 6"的
  "停在 processing/recoverable failure 态"提案落败,该文档须回改对齐本条。
- 改引用不删旧物:me_page.dart:399/:524、sparse_cloud_viewer_page 与
  sfm_resume_wait_page.dart:65/96 的 plyPath、publish_service.dart sparsePlyFor(:247)、
  ar_capture_page.dart:2106/:2336。UI/渲染零改动(SparseCloudView 本就渲染完整 PLY;
  社区 work_detail_page.dart:291 只认 format:'ply' 不动)。
- 预览=稠密直出(用户拍板"没必要为了看起来稀疏而抽稀"),端上按设备做**透明性能 LOD**
  (非产品外观);渲染家底:点云渲染审计/Polycam 秒开/fastload spike,桌面查看器实测扛 22M/59M 点。

---

# 工作线 ⑤(常备服务):BlendedMVG 重训 checkpoint 雾基准

用户在训 BlendedMVG(BlendedMVS 113 + GL3D 389 = 502 场景 / 11 万图,CC BY 4.0)。
**每当用户丢来一个 checkpoint,4 分钟内回雾数**:

1. 跑 `/Users/kaidongwang/Documents/progecttwo/_artifacts/lever1_source_reform_20260818/run_official_chain.sh`,
   把脚本里 `CKPT=` 换成新权重路径(b28,132 帧,固定噪声 seed=20260818+帧序,与全部基线
   逐比特可比;推理 MPS ~50s + 融合 ~90s + 量测秒级)。
2. **基线:C_long_ep31 = 雾 4.13%(42,285 / 墙面 1,023,491)**。同时报总点数别只报雾
   (新权重可能整体换分布)。
3. 判据树(WALL_BATTLE.md 已写死):雾 <1% ⇒ 墙面战役收官,选源多样性不装;
   没掉 ⇒ 多样性机制升格必需品(须用户裁决自研配方或租 GPU 跑 ACMMP 作背书)。
4. 若新权重要上真机:重导 ONNX(`tools/export_onnx.py`),先跑 `#32145` 的 8 节点最小复现当
   回归(`experiments/casdiffmvs_wgsl_port_2026-08-17/ort_issue/`,我们首报的 bug 无上游修复
   可指望,换权重必重验非有限值),再走 clipfix 同款处理,bench app 换模型即测。
5. ⚠️ fp16 教训:像素 parity 对随机扩散模型是错尺;**重建层对拍才是终审**
   (方法与产物:`_artifacts/casdiffmvs_fp16_recon_20260819/`——换种子地板极窄,
   点数 −0.16%/覆盖 0.11-0.62%,官方融合把种子噪声洗到无痕,判据按这个地板画)。

---

# 工作线 ⑥:#32145 上游狩猎(EXTENDED NaN)

## 为什么值得打
BASIC 锁死留下 **5026 个碎片节点**(Mul/Add/Slice/Sub/Div 元素级碎片是派发与带宽大头)——
解锁 EXTENDED 的 Conv+BN/激活融合是**唯一剩余的无损提速路**,而且**省的每瓦都推迟
A16 的 2 分钟热拐点**(双收益)。图切分诊断已证其他路全死(全修 A/B −0.8%=噪声)。

## 资产
- 我们报的 issue:microsoft/onnxruntime **#32145**(WebGPU EXTENDED+ 静默产生非有限值),
  0 评论无 assignee;最小复现全套在
  `experiments/casdiffmvs_wgsl_port_2026-08-17/ort_issue/`(model.onnx 8 节点复现 +
  repro.py + input_small.npz + decode.sh)。
- 本地 ORT checkout `~/ort_ios_build/onnxruntime`(v1.29.0 + ARC 补丁,工作树只有那一个 M);
  macOS WebGPU 特制轮子(A3 用的,系统 python3.11)可快速迭代,复现在 Mac 上便宜。
- #32147 里维护者(qjia7)已邀请我们提 PR——上游通道是热的。

## 打法(建议,可自调)
1. **定位**:session option 落盘各优化档的 optimized model
   (`optimized_model_filepath`),diff BASIC vs EXTENDED 图,找被融合出来的可疑节点;
   对 8 节点复现逐节点二分(切图跑半段),钉死是哪个 fusion pass / 哪个融合后 kernel 产非有限。
2. **判性质**:是 WGSL codegen 的数值 bug(如 exp/pow 边界)、融合改变求值顺序放大溢出、
   还是 Dawn 后端问题——`ort_issue/README` 里有 08-17 的三个已证伪假设,别重走
   (当时定位靠"暴露中间量后 bug 消失"这个没复现的线索)。
3. **两条出口**:①上游 PR(优先——精确 culprit + 复现 + 修法,挂在 #32145);
   ②本地绕行——若能定位到单一 fusion 规则,寻找 ORT 有没有禁用单条规则的会话开关;
   没有就做**离线图手术**(把安全的融合离线烘进 onnx,运行时仍 BASIC——快速导出同款
   "字节等价改形式"思路,但这里是数值等价,需 parity 验收)。
4. **验收**:Mac 上 EXTENDED(或部分融合集)零非有限 + parity 在 fp32 舍入量级
   (参考 run_ort 口径 p50~2.5e-7)+ 实测提速数;然后真机确认 + 热曲线复测
   (拐点推迟多少)。**任何 parity 不过的加速一律不算数**(fp16 前车之鉴)。

---

# 执行顺序建议与汇报

- **③ 与 ② 解耦(2026-08-19 用户签字)**:③ 的依赖 = ① accepted + 现生产匹配器
  (③ 吃 sfm_live_recon 快照,不硬依赖 GTO);② 的进度不阻塞 ③。④ 仍依赖 ③ 产物。
  ⑤ 是常备服务随到随跑;⑥ 完全独立可并行。
- 🔴 **B 签字已被数据双杀,异常旗触发,待用户改签 A**(2026-08-20 晚,两路实验,
  全档 _host_experiments/live_vs_refined_20260820/):
  ①**时间账证伪**:逐位闭包下深度范围/选源跟着稀疏云长到最后一刻(cap160 最后 20 步
  才定格:深度范围 98%/top-10 70%/位姿 52%)⇒ B-strict 尾巴≈全量重推,只比 A 省一次
  10-25s 的 BA;②**质量证伪**:live_end vs refined 稠密对拍——粗糙度 +26.9%(超换种子
  地板 ~400×)、覆盖 FAIL、点数 −1.95%、两臂世界尺度差 1.4%(refined BA 修的就是它)。
  C(journal 冻结口径)被逻辑蕴含判死(其质量上限=B-strict,已判负)。
  **净菜单 = A:成品用 refined 位姿拍完全量重推(A16 热态 98 帧≈4.1 分钟/160 帧≈6.7 分钟);
  拍摄期稠密生长保留为预览**(live 位姿喂预览合法——预览不进成品)。
  以下 B 条款仅留档,一律作废:

- ~~✅ **成品位姿口径已签 = B(live_recon 位姿)**(2026-08-20 用户拍板)。后果与义务:~~
  1. **成品口径定义**:成品稠密 = 以**拍摄结束时刻的 live_recon 状态**(位姿+稀疏点)喂
     官方 batch 链(colmap_input→推理→filter_depth)所得产物;refined 全局 BA 位姿照常
     产出并保留(稀疏交付/存档/对拍用),但不再定义稠密成品。
  2. **MD5 验收改绑**:流式产物 ≟ 上述"终态 live_recon 官方 batch"逐字节。
  3. **冻结闭包升级为三输入**:一帧的推理只有当它的 **位姿 / depth range(该帧稀疏分位)/
     有序 top-10** 三者都等于拍摄结束终值时才算成品级;任何一项在推理后漂移 ⇒ 尾部重推。
     (live_recon 窗口 BA 出窗即基本不动,预期漂移小;但这是预期不是证据,见 4。)
  4. 🔴 **③ 装机前必做实验(Mac,零手机)**:把 schedule_sim 从"输入固定终态"改为
     "回放演化中的 live 输入"口径,实测 B 口径下的真实重推尾巴帧数与 MD5 是否仍逐字节
     ——这是 B 的时间账("尾巴 1-2 分钟")从推断变实测的唯一途径。
  5. **一次性 B-vs-A 稠密对拍**(验收必做):同采集分别用 live_recon 终态与 refined 位姿
     跑官方 batch,粗糙度尺+换种子地板判,肉眼终审留用户;**B 若掉出地板 ⇒ 异常旗,
     停下找用户**,不得自判"差不多"续推。
  6. 新工程件:native 导出 live_recon 位姿 getter(照 get_preview_tracked 模式读
     s->live_recon,同线程契约,official_aether_sfm_c.cc:11390 一带为模板)。
- 🔴 **④ 的总闸门 = 墙面战役收官**(2026-08-19 用户纠偏后写死):模型还在重训、
  雾没收口(现 4.13%)之前,**交付切换连旗都不许开**——④ 只允许做到"代码就绪、
  旗默认关、验证过回退路径"为止;把稠密真正端给用户,必须先有 ⑤ 的雾判决 +
  用户肉眼终审两道章。①②③ 全是旗关的引擎准备工作,不赌模型,可以先行。
- 每组装机前:df + 检查用户是否在拍摄/训练(装机窗口纪律);装机后按各组"装机≠生效"清单验证。
- 提交:研究仓按既有分支;产品仓改动逐组单独 commit,信息里写开关名与验证状态;
  **产品仓第一次 push 前把改动清单发给用户过目**(他要求签字制)。
- 遇到任何"官方参数与实测冲突/异常旗/判据模糊"的情况:停下,把证据摆给用户,等拍板。
  今天的历史证明:他的直觉推翻过五次"看似合理"的方案,他要看的是真彩 PLY 并排页和
  事先写死的判据,不是论文式散点图。

---

# 附录 A:项目进度快照(2026-08-19 晚)

```
✅ 架构定案并真机验证   稠密优先五决策(用户拍板)+ A16 五关全档
✅ 第 0 阶段            母版快照(三重验证)/ w99 双判据通过 / 出处审计(3错1漏全修)
✅ ①组(Mac+真机)      ORT iOS 构建 → A4 打点 → fp16 判死 → 挤水分判死 → 热曲线
⏳ ②③④组             规格修订完毕已签,一行产品代码未动(本任务书的主体)
⏳ 墙面战役             五连败后等 BlendedMVG 重训 checkpoint(⑤号服务)
⏳ #32145 战役          已立案(⑥号线),唯一剩余无损提速路
🗑️ LightGlue           光荣退役(从"必须攻破"到"不再需要",全程案卷在档)
```

**架构终态一句话**:拍摄期 live 稀疏(不动)+ GTO 位姿引擎 + 稠密实时生长(尾随相机)
→ 拍完官方全档交付;用户拍摄节奏 3.5–5 分钟下,5 分钟档零尾巴、3.5–4.5 分钟尾巴 1–2 分钟
(热口径);预览=稠密直出+透明 LOD,选区画在稠密上,交付全量无损。

# 附录 B:胜利与挫折(读懂它们才能不重蹈)

## 胜利(每条都有档)
1. **稠密优先架构**——用户的直觉("抽走95%的稠密就是完美稀疏")推翻了整条"把稀疏做好看"
   的战线;后又亲手砍掉美观抽稀("直接稠密就行")。
2. **MVS 消融定案**:稀疏预算对稠密无影响(每档差异 < 噪声地板)⇒ 稀疏只剩位姿职责。
3. **GTO 门控匹配**:算力 1/4.2,位姿反而全场最准(1.1563);w99 证明可直接吃原始 ARKit 位姿。
4. **流式 MD5=官方**:冻结+尾部重融的产物逐字节等于官方 batch——MVS 领域无先例的验收强尺。
5. **快速导出 2.8×**:官方融合 62% 耗时是 Python tuple 导出形式,列赋值后 MD5 逐字节相同。
6. **融合=噪声洗衣机**:扩散换种子在重建层只剩 −0.16%——可复现性焦虑连根拔除(fp16 判死实验的副产)。
7. **三个全球第一**:ORT v1.29.0 iOS WebGPU 构建 / iPhone 跑 ORT WebGPU / iPhone WebGPU-vs-CPU 对照。
8. **选源多样性机制**:同走廊互证是雾的成因,跨走廊换源雾 −94.9% 墙 +7.9%(机制已证,配方待重训裁决)。
9. **w99 生产内点版**:预注册实验换素材时重推导"实验真正要什么"——生产库自带验证内点=现成探针,
   零 GPU 零解码,比原设计更贴生产。

## 挫折(死因全部入档,别复活也别重犯)
1. **LightGlue 提速战役 17 试 16 负**:注意力 66% 且 fp32/fp16/compile 三测纹丝不动=无冗余;
   最大误判是把一整天杠杆砸在只占 6% 的匹配上(建图才是 16 倍)。
2. **墙面雾五连败**(DA3/conf/平面先验/逐帧校正/显示过滤)+ 官方选源复刻也失败
   (OpenMVS 的干净墙功劳在求解器不在选源公式——归因修正)。
3. **fp16 重建层判死**,且我的"≈换种子"假说被同一实验证伪——像素尺对随机模型是错尺,
   但重建尺分得清随机与系统。
4. **挤水分判死**:"not assigned"警告=1 个节点的红鲱鱼;23% 的 Memcpy 是重叠同步;
   全修 A/B −0.8%。教训:profiler 的"名义可回收"≠真实,决定性 A/B 才算数。
5. **三次违反"复刻不自研"**(profile 预处理 antialias/门控参数 tol6-ratio0.95/选源公式)——
   规则已升级:给 agent 的任务书写死禁自研,验收逐参数核出处。
6. **两次 workflow 栅栏错误**(交付物被无关慢臂堵死 40+ 分钟)——依赖图先画,交付路径上的
   每个 await 都要问"真需要吗"。
7. **数据永久丢失**:b28 的 ARKit 位姿死于 /tmp 清空+卸载事故叠加 ⇒ 归档制度已立
   (arkit_pose_archive + sync 脚本),判据类素材第一时间落耐久盘。
8. **报时两次失信**("30-45 分钟"实际 15 分钟/纯算力几分钟)——报耗时分开报:纯算力 vs
   agent 工程开销,别把缓冲报成工期。

# 附录 C:与这位用户协作的 tips

1. **判据先写死再跑**,失败判据和成功判据一样重要;判负结果他照单全收,含糊结论他不收。
2. **肉眼 > 覆盖 > 粗糙度 > 点数**;交付判断用的是**真彩 PLY 并排页**
   (`_artifacts/lightglue_spike/build_local_page.py --set <name>` 机制,同采样率=密度可比,
   相机同步,自包含 HTML 双击开),**不是散点图**——交过一次论文式图被打回。
3. 他的直觉经常对:"看全了吗"逼出 OpenMVS 参照、"素材收集"引出采集诊断、"抽稀稠密"改写架构。
   **他质疑时先查自己,别先辩护**。
4. >10 分钟等待必被质问;"没卡,在跑"要先核依赖图再说(两次里一次真是编排错了)。
5. 讨厌比喻("雾的氧气??这是什么东西??"),说人话,给数字。
6. 中途插话常带纠偏(LightGlue 已退役还在跑/18GB 又要崩),**立刻停手认账**,别护盘。
7. 大改动他要**签字制**:产品仓动手前给文件级清单;偏离官方口径的每一处单独列出待签。
8. 报告格式:结论先行、表格化、判据线并排、代价与口径标注齐全。

# 附录 D:文件地址总表

## 远端(GitHub)
- 研究仓 `github.com:Kyle-Wang0211/pocketworld-research-benchmarks`
  - 分支 `research/lightglue-frontend-spike-2026-08-17`:架构决策书/审计/清单/墙面案卷
    (关键 commit:7d1b150 决策书 / 98515e1+3695446 墙案 / 395da39+40fd9ab 审计 / lightglue spike 75f773c)
  - 分支 `research/casdiffmvs-official-replication-2026-08-17`:ORT 移植/A4 全档/bench
    (df1d19c 壳落地 / 0808a2d A4 / 45024b2 fp16 / 1269520 挤水分 / b119067 热曲线 / b5fd63c MVS消融)
- 上游 issue:microsoft/onnxruntime **#32145**(EXTENDED NaN,⑥号线靶子)、**#32147**(ARC 补丁,已验证)

## 本地仓库
- 研究仓:`~/Developer/Aether3D-cross/pocketworld_research_benchmarks`(主检出在 casdiffmvs 分支;
  动 lightglue 分支用 worktree,别切主检出)
- 产品仓:`/Users/kaidongwang/Developer/pocketworld`(main@bf159e3 + 35 条未提交;
  bf159e3/007123d 是 0f30529 之后新进的**自动采集**两条 docs 提交——那是另一条战线,
  它的文件你一律不碰;母版快照做于 0f30529 时点;**动产品仓前看清单签字**)
- 管线仓:`~/Developer/Aether3D-cross/aether_cpp`(official_pipeline + vendored COLMAP/GLOMAP)
- 母版快照:`/Users/kaidongwang/pw_master_snapshots/20260819_phase0/`(12.96GB,勿动)
- 设备备份:`/Users/kaidongwang/pw_device_backups/`(只读;b28 的 live.db 已解出在 cap 目录)
- ORT 构建树:`~/ort_ios_build/`(onnxruntime checkout + build_ios 产物 + check_build.sh)

## 耐久产物(/Users/kaidongwang/Documents/progecttwo/)
- `_artifacts/lightglue_spike/`:全部对比页(compare_*.html)+ build_local_page.py + 匹配臂脚本
  + box_0818/(5090 存档三 tgz)+ wall_forensics_20260818/(墙面法医全套+conf ROC+OpenMVS 参照)
- `_artifacts/ios_bench_20260819/`:CasDiffBench{,_fp16,_loop}.app + 全部 bench_result*.txt + 输入包
- `_artifacts/casdiffmvs_onnx_20260818/`:casdiffmvs_v5.onnx / _fp16.onnx(判死留档)/ _clipfix.onnx
- `_artifacts/arkit_pose_archive/`:8 cap 的 ARKit 负载 + sync_arkit_payloads.sh(每次拉备份后跑)
- `_artifacts/lever1_source_reform_20260818/`:**run_official_chain.sh(⑤号雾基准入口)**+ 选源实验全套
- `_artifacts/capture_geom_20260818/`(采集诊断)、`_artifacts/delaunay_prior_20260818/`、
  `_artifacts/perframe_corr_20260818/`、`_artifacts/da3_separation_probe_20260818/`(判死档案)
- `_artifacts/casdiffmvs_fp16_recon_20260819/`:重建层终审方法与产物(换种子地板口径)
- `_artifacts/phase0_20260819/`:快照凭证 / w99 全套 / 脚手架勘察
- `_host_experiments/pose_ablation_20260818/`:MVS 消融全套(深度图/稠密云/融合脚本/fullres 查看器)
- `_host_experiments/gto_dense_20260818/`、`streaming_fuse_md5_20260818/`(MD5 证明)、
  `aggressive_schedule_20260818/`(激进调度模拟)
- `HANDOFF_20260819_four_workstreams.md`:本文件
- 记忆(背景知识,只读参考):`~/.claude/projects/-Users-kaidongwang-Documents-progecttwo/memory/`
