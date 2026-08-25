# 提速战线交接:三把剩余刀的极致提示词 · 2026-08-25

给未来会话/agent 的自包含交接。每把刀一段可直接整段粘贴的提示词;前面是共用的
前因后果、铁律与文件地址总表。**先读完 0/1/2 节再动任何一把刀。**

---

## 0. 前因后果(这条战线为什么存在、走到了哪)

**动机(用户裁定,一字不改的方向)**:自动拍摄在热机上被 thermal 闸主导
(serious 压到 2s/发),间距表达不出 0.10×d。用户裁定:*"用户的手机可能是任何
温度,你必须保证手机在最热的时候可以正常运行"* + *"不要把计算滞后。想办法提速,
让所有计算加速完成。这个从根本上解决热问题"*。⇒ 提速=减少真实工作量,
不是摊平/滞后/降质(memory: `feedback_speedup_means_less_work_not_smoothing`)。

**焦耳账(A16,1283 帧实测)**:proc 中位 1294ms/帧;提取 625ms(GPU DSP-SIFT)
+ 匹配 635ms(×12 候选帧,~53ms/对);拍摄期占空比 65%+。

**stream 逐帧账(201 帧,08-08,下刀地图)**:
| 段 | 占比 | 备注 |
|---|---|---|
| 局部 BA | **33.3%** | `ilr_solve` 独占 25.3% = 单项最大 |
| GPU 匹配 | 22.8% | probe-gate 能砍 33%,但该段只占 23% ⇒ 门的天花板 −4% |
| tail | 22.6% | |
| TVG(两视几何验证) | **21.2%** | 本文件刀② 的靶 |

**已装的刀(勿重提立项)**:DSP 10→6(07-11,SCALE-6);解析 Jacobian
(COLMAP #4513 backport,08-08 抄入、08-10 上生产,真机 jac 仅占 BA 20-25%);
b31 热态空间保底(08-25 装机);probe-gate 机件全在库但默认熄火(见刀③)。

**⚰️ 死刀墓碑(判决链在源码注释里,永不再提)**:
- **finalize 总轮数 5→3**:08-10 签装、**08-13 用户签字撤回**(`official_aether_sfm_c.cc`
  `[ROUNDS-REVERT 2026-08-13 用户签]`)。撤回依据=肉眼:5 轮作品浮点少很多——外层每轮
  多跑一次 FilterPoints,3 轮少删的 0.6~0.8% 是**脏点**;"点数正向"聚合指标把脏点当成绩。
  现役默认 `ba_global_max_refinements = 5`。**用户 08-25 原话:"我之前做过,完全是负收益"。**
- STAGE1_ROUNDS_CAP=1:轮预算自平衡流给 stage2,净 +0.5s 且点 −0.3%,判死;
- 局部 BA ftol=1e-6:host A/B −0.09% = 噪声,判死(旋钮 `OFFICIAL_AETHER_LIVE_LBA_FTOL` 留档);
- probe-gate MIN=3 默认开:跳过的配对不进 AR live 云(−0.89%),违反 live 无损硬线,
  08-08 当天回退(机件保留,`PROBE_GATE_MIN=3` 一行可复活——但 live 无损不解决就不许复活);
- DSP 6→3:用户裁定不做("DSP 6 已经是 meshroom 标准了,就没必要变 3 了")。

---

## 1. 全局铁律(三把刀通用,违反任何一条=作废重来)

1. **交替 A/B 是唯一合法度量**(同设备同素材 ABAB 交错);host 复放只定方向,
   ratio 失真 18-26%(memory: `project_pocketworld_host_replay_ratio_fidelity`),
   上桌数字必须真机;
2. **判据序:肉眼(浮点/鬼层)> 覆盖四档 > 粗糙度 > 点数**。finalize 教训:
   点数正向可能恰恰是脏点没被筛;凡触碰"筛点次数/内点集合"的改动必做并排肉眼;
3. **交付绝对无损,live 云也无损**(`feedback_delivery_lossless_absolute_no_frame_loss`
   / `feedback_lossless_means_live_cloud_too`);
4. **单变量**;装机合同=产品与管线分开(`feedback_install_contract_product_pipeline_split`);
5. **跨端一致(苹果/安卓/鸿蒙)**:改 C 层默认,禁 Swift setenv 承载默认值;
6. **设备 env 是共享单文件**,推送必须读-改-写合并(`feedback_env_file_is_shared_read_modify_write`);
7. **重编 `libpwofficial_core.a` 前先与「位姿+ui」会话协调**——重编会把该会话在
   Aether3D-cross 的在飞改动一起卷进产物。env 旋钮实验(刀①)不需要重编,优先做;
8. **装机 fail-closed 流程**:先构建→装前最后一刻拉 `Documents/official_pw_device_log.txt`
   查 10 分钟活动(worker up/session created/shutter ticket/add_frame/finalize/
   RefineGlobalBA,copy 失败即中止、HITS 非数字即中止)→`devicectl device install app`
   不进管道直取 RC→`devicectl device info apps` 验 build 号→**永不 uninstall、装完不 launch**;
9. **License exhaustive**(全依赖树逐个查,无 LICENSE 文件=NOASSERTION=红线);
   不捏造版本号、不估时;
10. **读记忆必须读到勘定段 + 核现役代码注释的判决链**——08-25 同日三次拿过时账当待办
    (DSP 档数/解析 Jacobian/finalize 5→3),源码注释比记忆多活一次翻案
    (`feedback_read_memory_verdict_section_and_verify_code`)。

---

## 2. 文件地址总表(本地 + 远端)

**仓库拓扑**(memory: `project_pocketworld_three_repo_topology`):

| 仓 | 本地 | 远端 |
|---|---|---|
| 产品(Flutter app) | `/Users/kaidongwang/Developer/pocketworld` | `https://github.com/Kyle-Wang0211/pocketworld.git` |
| 算法(C++/管线) | `/Users/kaidongwang/Developer/Aether3D-cross` | **无远端(本地唯一,动前先备份)** |
| 研究基准(嵌套) | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks` | 无独立远端 |
| 上游对照树 | `/Users/kaidongwang/Developer/A3X-colmap41`(COLMAP 4.1.0 原样) | 无远端 |

⚠️ **双树分叉险**:PINHOLE 解析 Jacobian backport **只在** Aether3D-cross 的 vendored 树;
A3X-colmap41 仍是上游原样(kPinhole has_jac=false)。**任何 BA 计时/质量实验禁止
在 A3X 树做**——会误测 autodiff 路径。

**生产核心代码**(`$A = /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp`):
- 管线主文件:`$A/official_pipeline/src/official_aether_sfm_c.cc`
  - `:6749` env `OFFICIAL_AETHER_LIVE_LBA_FTOL`(局部 BA ftol,判死存档)
  - `:7223` env `OFFICIAL_AETHER_FINALIZE_TOTAL_ROUNDS`(死刀,注释即墓志铭)
  - `:2242` `ProbeGateMin()` / `:2275` `kProbeGateRowsDefault = 512` / `:918` 回退注释
  - `:3819/:3844/:5937` TVG options 构造点;`:6154` 附近 = 出货匹配器的
    `colmap::EstimateTwoViewGeometry` 验证路径;`:7338` 遥测键 `probe_ms`
- BA 封装:`$A/official_pipeline/src/official_bundle_adjustment_ceres.cc`
  - `:374` `parameter_tolerance = 0.0`(COLMAP parity 出货值)
  - `:482-486` env `OFFICIAL_AETHER_GLOBAL_PTOL`(**旋钮已在,实验未跑** = 刀①)
- 重力 TVG 变体:`$A/official_pipeline/src/mandatory_gravity_tvg_v1.cc`
- vendored COLMAP(生产,带 #4513):`$A/third_party/glomap_vendor/colmap-src/colmap/`
  - `estimators/two_view_geometry.cc`(LORANSAC 调用层)/ `optim/loransac.h` / `optim/ransac.h`
  - `sensor/models.h` + `sensor/models_jacobian.h`(解析 Jacobian)
  - `controllers/incremental_pipeline.h:115,135`(局部 ftol=0 出处 / 全局 5 轮出处)
- iOS core 构建脚本:`$A/official_pipeline/build_ios_core.sh`
- 产品侧插件:`/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift`

**上游远端(证据链)**:
- COLMAP:`https://github.com/colmap/colmap`(vendored 基线=4.1.0,commit 16a5d851)
  - 解析 Jacobian:PR #4017 / **#4513**(已抄)/ #4516
  - **issue #2703**(标 bug):sarlinpe *"I suspect that the parameter tolerance could
    help most"*;ahojnnes *"tuned in a rather empirical manner many years ago"* ⇒ 刀①出处
- Ceres:`https://github.com/ceres-solver/ceres-solver`(收敛语义文档)
- MAGSAC++:`https://github.com/danini/magsac`;GC-RANSAC:
  `https://github.com/danini/graph-cut-ransac`(08-08 调研口径=BSD ✅,动手前按铁律 9 复核)
- OpenCV USAC(内含 MAGSAC++,Apache-2.0):`https://github.com/opencv/opencv`
  (`modules/calib3d/src/usac/`)——备选抄源,许可最干净
- SupeRANSAC(MIT,主打精度非速度):`https://github.com/danini/superansac`
- ⛔ VSAC:`https://github.com/ivashmak/vsac` **无 LICENSE=NOASSERTION=商业红线,禁 vendor**
- ⛔ GPL 永不进仓:ORB-SLAM2/3、VINS-Mono/Fusion(数学在 g2o(BSD)/XRSLAM(Apache-2.0)有同源)

**度量工具**:三臂实验样板 `/Users/kaidongwang/Developer/pw_spacing_ab_20260825/`;
唯一点云尺子 `cloud_vs_ref.py`(研究仓);装机备份配方
memory: `project_pocketworld_device_backup_verified_recipe`。

---

## 3. 刀① parameter_tolerance(风险最低,先做这把)

> **提示词(整段粘贴)**:
>
> 你在 PocketWorld 提速战线上执行 parameter_tolerance 实验。先读
> `/Users/kaidongwang/Developer/pocketworld/docs/SPEEDUP_LEVERS_HANDOFF_2026-08-25.md`
> 的 0/1/2 节,遵守全部铁律。
>
> **背景**:我们的 BA 收敛判据沿 COLMAP 出货值:`function_tolerance=0.0`、
> `gradient_tolerance`(全局 1e-4 见 `official_bundle_adjustment_ceres.cc:373`,
> 局部 10.0)、`parameter_tolerance=0.0`(`:374`)。ftol/gtol 双双拧死 ⇒ 大量 solve
> 以 NO_CONVERGENCE 打满迭代上限(局部 15、全局 50;cap201 实测局部 50.8% 打满)。
> COLMAP 维护者在 issue #2703 亲口点名 parameter_tolerance 是最可能有用的松绑。
> 局部 ftol=1e-6 已试判死(−0.09%=噪声,原因:局部上限才 15,多数 solve 真需要);
> parameter_tolerance **从未试过**。
>
> **现状**:全局旋钮已在代码里——`OFFICIAL_AETHER_GLOBAL_PTOL=<x>`
> (`official_bundle_adjustment_ceres.cc:482-486`,只作用于 custom_solver_options
> 路径,先确认 finalize 两段全局 BA 走的就是这条路径);**局部 BA 没有对应旋钮**,
> 需照 `OFFICIAL_AETHER_LIVE_LBA_FTOL`(`official_aether_sfm_c.cc:6749`)样式补一个
> `OFFICIAL_AETHER_LIVE_LBA_PTOL`(补旋钮=改 C 层,需重编 core ⇒ 铁律 7 先协调;
> 或先只做全局,零重编)。
>
> **步骤**:①host 复放矩阵定方向:ptol ∈ {0, 1e-8, 1e-7, 1e-6},同 DB 每臂 ≥3 发,
> 确认同臂逐位相同再比跨臂;看迭代数/NO_CONVERGENCE 率/solve 墙钟/点数/reproj;
> ②方向为正 ⇒ 真机交替 A/B(env 文件读-改-写推旋钮,免重装);③质量门:
> 并排肉眼(浮点!)+ 覆盖四档 + reproj;④判死就把结论写进 `:374` 旁注释
> (照 `[LOCAL-FTOL-AB]` 格式),旋钮留档。
>
> **预期与陷阱**:Ceres 语义里 ptol 是"步长相对参数模长"判据,对接近收敛、
> 步子已很小的 solve 最有效——正对我们"打满上限"的病;但局部 BA 可能复现
> ftol 的教训(上限 15 太低,松绑无肉可省)。**全局(finalize 两段)更可能有肉**:
> s2 四轮 7.1/3.9/3.6/2.05s 递减,后几轮正是小步长阶段。收益若 <2× 复放噪声带,判死。

---

## 4. 刀② TVG 换 MAGSAC++/GC-RANSAC(动手面最大,质量敏感)

> **提示词(整段粘贴)**:
>
> 你在 PocketWorld 提速战线上评估把两视几何验证(TVG)从 vendored COLMAP 的
> LORANSAC 换成 MAGSAC++ 或 GC-RANSAC。先读
> `/Users/kaidongwang/Developer/pocketworld/docs/SPEEDUP_LEVERS_HANDOFF_2026-08-25.md`
> 的 0/1/2 节,遵守全部铁律——本刀改变内点集合=改变交付质量,**必须走
> 三臂消融 + 用户签决,禁止夜里偷改默认**。
>
> **背景**:TVG 占拍摄期 stream 21.2%(201 帧账)。⚠️ 关键前科:probe-gate 跳掉
> 25.3% 配对时 TVG 只省 1.8% ⇒ **TVG 成本集中在匹配多的"贵对"上**,贵对的
> RANSAC 迭代才是肉。现役路径:`official_aether_sfm_c.cc:6154` 附近的
> `colmap::EstimateTwoViewGeometry`(vendored `estimators/two_view_geometry.cc` →
> `optim/loransac.h`);另有重力先验变体 `mandatory_gravity_tvg_v1.cc` 复用同一
> options——**换引擎必须两条路径一致,单换一条=平行同名实现,前科在案**
> (memory: `feedback_parallel_trees_and_verify_existing`)。
>
> **候选与许可(动手前逐仓复核 LICENSE 文件,铁律 9)**:
> MAGSAC++ `github.com/danini/magsac`、GC-RANSAC `github.com/danini/graph-cut-ransac`
> (08-08 调研口径=BSD);**优先考察 OpenCV USAC 实现的 MAGSAC++**
> (`opencv/modules/calib3d/src/usac/`,Apache-2.0,工程质量高、无 OpenCV 整库依赖时
> 需评估摘取面);⛔ VSAC 无 LICENSE=禁;⛔ GPL 名单禁。
>
> **步骤**:①先量化靶:在 stream 遥测里按对拆 TVG 耗时,确认贵对分布与
> RANSAC 迭代数(若迭代早饱和,换引擎收益有限——先测再抄,
> memory: `feedback_test_the_builtin_lever_before_declaring_dead_end`);
> ②host 三臂消融(参考臂=现役 LORANSAC / 效应臂=新引擎 / 噪声地板臂=同臂重放),
> 同素材同匹配输入,单变量只换 TVG 引擎;比:内点集合差、注册链完整性、
> 最终点云肉眼+覆盖四档+粗糙度、TVG 墙钟;③跨端约束:候选实现须纯 CPU/C++、
> 无平台私有依赖(苹果/安卓/鸿蒙同一份);④方向为正 ⇒ 真机交替 A/B ⇒ 呈签
> (质量带变化+速度收益+许可结论);⑤签后才动默认,重编 core 走铁律 7/8。
>
> **判死线**:内点集合变化导致任何肉眼可见的浮点/断链,或真机收益 < 拍摄期 2%,
> 或许可复核不过 ⇒ 判死写档,禁止"精度换速度"的默默权衡。

---

## 5. 刀③ 探针自身成本(probe_ms ~3.3s/场)

> **提示词(整段粘贴)**:
>
> 你在 PocketWorld 提速战线上追查 probe(预匹配探针)的自身成本。先读
> `/Users/kaidongwang/Developer/pocketworld/docs/SPEEDUP_LEVERS_HANDOFF_2026-08-25.md`
> 的 0/1/2 节,遵守全部铁律。
>
> **背景**:probe-gate = Wu ICCV'13 Preemptive Matching 复刻(512 行低清描述子
> GEMM 预筛,`official_aether_sfm_c.cc:2233-2320` 一带,`kProbeGateRowsDefault=512`,
> 遥测键 `probe_ms` 在 `:7338`)。08-08 曾默认开门(MIN=3,−4.0% 真机干净数),
> **当天回退**:被跳过的 25-40% 配对不进 AR live 云,违反 live 无损硬线
> (`ProbeGateMin()` 默认回 0,机件全保留)。⇒ 现状疑点:**门关着(MIN=0)时,
> 探针 GEMM 是否还在跑?若在跑,~3.3s/场 是纯浪费。**
>
> **步骤**:①先读源码回答三个问题:MIN=0 时探针路径是否短路;`PROBE_GATE_TOP`
> (`:2313`)是否让探针结果参与候选排序(若参与,砍掉探针会变行为=质量敏感);
> 遥测 `probe_ms` 在现役真机日志里实际是多少(拉最近几场
> `Documents/official_pw_device_log.txt` 的 stream 账,别信 3.3s 旧账——出处是
> 08-08 的 201 帧场,规模不同数字会变);②若确认纯浪费 ⇒ 补短路(MIN=0 时零
> GEMM 零日志开销),这是零质量风险的净减工作量,host 验证 + 真机交替 A/B 收数
> 即可装(仍走铁律 7/8);③若探针喂了排序 ⇒ 变成质量敏感改动,走三臂消融+签决;
> ④顺手确认:probe 复活(MIN=3)的前置=解决 live 无损(跳过对进 live 云的补账
> 机制),这是独立立项,别混进本刀。
>
> **判死线**:若 MIN=0 已经短路、probe_ms≈0 ⇒ 本刀是幽灵靶,写档关闭,
> 别为了"做了点什么"去动机件。

---

## 6. 本文件之外还挂着的候选(未立项,仅备忘)

- 候选帧 12→10(匹配段 ∝ 候选数;质量敏感,须三臂);
- BA-ITER-CAP(`:~7240` 研究旋钮,stage1 两 solve 各 51 iters 打满,COLMAP FAQ
  认可减 LM 迭代——与刀①同族,ptol 若有效可能顺带解决);
- colorize 6.8s 并行化;LAPACK 收尾(−65% 需重编 iOS ceres,门槛高);
- 「AR每帧显示」**已是现役默认**(08-25 核实:`pocketworld/lib/official_capture/`
  `sfm_live_recon.dart:76` `_arEveryFrameEnabled = true`,真机日志 `worker up:
  arEveryFrame=true`;Swift 侧 `OfficialAetherARKitPlugin.swift:357` 同步 setenv)
  = 体验线不是提速线,但它增加每帧求解压力——做提速 A/B 时两臂必须同开。
