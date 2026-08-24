# 流式 SfM 提速调研定案(拍摄期 / 端上 / 无损优先)

日期:2026-07-29
性质:联网查证(WebSearch/WebFetch/GitHub API 一手)+ **对我方自有 telemetry 与 vendored 源码的实测复算**。
标注约定:**【实测】**=我在本次会话中从你们的 fixture 日志/源码直接算出;**【源码】**=读 vendored/上游源码原文;**【文档/论文/博客】**=一手来源;**【推断】**=由证据外推。
前置:本文**不重复** `BA_ITERATION_CAP_RESEARCH_2026-07-28.md`(global BA 迭代上限已定案:什么都不做)。本文只谈**拍摄期流式**这条链。

---

## ⚡ TL;DR — 五条结论,前三条是我在你们自己的日志里挖出来的,不是文献

1. **🔴 拍摄期 local BA 有 ~78% 的求解跑在 1 个线程上,另外 22% 反而吃满全部核心 —— 两头都错。** 实测 run 日志逐行写着 `threads=1` ×240、`threads=12` ×102。根因是流式路径里那个**局部新建的 `IncrementalPipelineOptions`** 既没继承你们在批处理路径上早就设好的 `ba_min_num_residuals_for_cpu_multi_threading = 6000`(于是吃上游默认 **50000**,而 7 图窗口只有 ~3.9 万 residual → COLMAP 主动强制 `num_threads = 1`),也没设 `num_threads`(于是越过阈值的那批直接 `-1` → 吃满 host 12 核 / 设备 6 核,**采集期不给相机和 UI 留核**)。**这是 51.6s(56.5%)里最便宜的一刀,改两行。**
2. **🔴 每帧都在重建整个 DatabaseCache + CorrespondenceGraph,这是唯一还留在每帧关键路径上的 O(N) 项。** 【实测】`tail_ms = −2.3 + 1.429 × 帧号,R² = 0.958`;其中 `DatabaseCache::Create` 单项从第 26 帧的 12.6ms 涨到第 146 帧的 100.5ms,全程合计 **8.4s**。上游 **PR #4279(已在你们 vendored 的 4.1.0 里)** 就是为"streaming/online use where images and matches arrive incrementally"加的,官方原话 "All changes are additive and have no effects on any existing logics"。
3. **🟠 你们表里"其余 tail 14.8s"不是杂项,是唯一会爆炸的项。** 按实测线性拟合外推:150 帧 212ms/帧、300 帧 **426ms/帧**、累计 64s。local BA 是平的、GPU 匹配是平的、TVG 是平的 —— **只有 tail 在长**。300 帧真采集时它会变成头号成本。

4. **🟠 你们从没给 Ceres 显式 `linear_solver_ordering`,而 Ceres 官方 FAQ 自带的实测是 preprocessor −5.5× / 总时间 −23%。** 不给 ordering 时 Ceres **每次 `Solve()` 都跑一遍近似最大独立集算法**去找第一消元组;而 BA 的正确答案是固定的(3D 点进 group 0、相机进 group 1)。你们每帧 2 次 Solve、每次只十几轮迭代 → 这个固定开销的占比只会比官方例子更高。`grep -n "ordering" estimators/bundle_adjustment_ceres.cc` **零命中**。
5. **🔴 在动任何求解器之前,先跑一次 `Solver::Summary::FullReport()`。** 353ms 里 Preprocessor / Jacobian evaluation / Linear solver 各占多少,**目前没有任何人知道**。这决定了上面 1/4 的天花板,也一次性决定了"移动 GPU 做 BA"这条路值不值得再提(§3.4 的结论是不值得,但那是靠外部证据推的)。

另外补一条你们分账里没有的:`stream_ms=110883` 与五项之和 91.4s 的差 ≈ **`refine_in_feed_ms=17384`(6 次拍摄期增量全局 BA,平均 2.9s/次)**。这 6 次单次就各自击穿 2s 门 —— 而且这个功能**默认是关的**,这份 fixture 是把它用 env 打开跑的(见 §4.4 / C3)。

**结构性判断:你们已经把"算法层"榨得很干了(GPU 匹配 3.12×、CAUCHY、DENSE_SCHUR 路由、线程、gftol、defer global BA)。剩下的钱不在算法里,在**编排层**:线程没开、缓存每帧重建、ordering 没给、GPU 与 CPU 从不重叠。这四条加起来是 −35~50%,而且全部不碰质量。**

---

## 〇、先把分账钉死:我复算了你们那次 run

你给的表(51.6 / 14.8 / 14.2 / 10.1 / 0.7)**唯一匹配**的 fixture 是
`_host_fixtures/spatial_cand_exp/runs/cap7_day_A/`(146 帧,`RESULT n_reg=146 n_points=141758 mean_reproj_px=1.0553 stream_ms=110883.1`)。以下全部基于该 run 的 `sfm_match_fail.jsonl`(每帧一条 `frame_split`)与 `run.log`。【实测】

### 0.1 分段趋势(每帧均值,ms)

| 帧段 | gpu | tvg | tri | **lba** | **tail** | cand |
|---|---|---|---|---|---|---|
| 0–23 | 86.7 | 81.4 | 5.2 | **369.1** | **19.5** | 8.8 |
| 24–47 | 90.2 | 48.4 | 4.0 | 301.3 | 48.7 | 12.0 |
| 48–71 | 104.8 | 69.8 | 4.3 | 356.2 | 75.0 | 12.0 |
| 72–95 | 98.9 | 69.4 | 4.5 | 366.1 | 111.0 | 12.0 |
| 96–119 | 108.9 | 65.8 | 4.4 | 381.8 | 158.5 | 12.0 |
| 120–145 | 93.7 | 77.9 | 6.3 | **346.9** | **188.0** | 12.0 |

- 你说的"local BA 全程平坦"**成立**(369 → 347),而且 p50 = 363.5ms、p90 = 468ms、max = 620ms。
- **tail 涨了 9.6×**。线性回归 `tail_ms = −2.3 + 1.429·fid`,**R² = 0.958**。这是教科书级的 O(N)。
- 单帧总和最大 1094ms(第 130 帧附近),距 2s 门只剩一半余量,而**唯一在长的项是 tail**。

### 0.2 tail 里装的是什么(从 run.log 的 glog 时间戳逐帧算)【实测】

流式每帧的 local-BA 块会执行:
`DatabaseCache::Create(全库)` → `IncrementalMapper mapper(cache)` → `BeginReconstruction(live_recon)`(构造整个 `ObservationManager`) → `IterativeLocalRefinement(...)` → `EndReconstruction()`。
只有 `IterativeLocalRefinement` 被 `t2_lba_ms` 计时,**其余全部落进 tail**。

| 帧段(cache 里的图数) | DatabaseCache 读库 | 建 CorrespondenceGraph | 合计 |
|---|---|---|---|
| ~26 | 3.4ms | 9.2ms | **12.6ms** |
| ~49 | 6.2 | 20.8 | 27.0 |
| ~73 | 9.5 | 31.4 | 41.0 |
| ~97 | 13.9 | 45.7 | 59.6 |
| ~121 | 24.6 | 64.3 | 89.0 |
| ~146 | 23.5 | 76.9 | **100.5** |

**全程 `DatabaseCache::Create` 合计 8.4s = 55.5ms/帧均值 = tail 的 57%。** 剩下的 tail(≈0.7·fid ms/帧)是 `ObservationManager` 全量构造 + 每帧 O(点数) 的 preview 快照拷贝 + 建点/合点循环 —— **同样是 O(N),同样可去**。

### 0.3 每帧确实跑满 2 次 local 精化【实测】

`run.log` 里每个 "Loading rigs..." 之后稳定出现 **2 条** `solver_used=DENSE_SCHUR`(全程均值 2.0–2.6)。也就是说 `ba_local_max_refinements=2` 的**第二轮从不被 `changed < 0.001` 提前打断**,每帧都付两次完整的 Ceres 求解 + 两次 MergeTracks/CompleteTracks/Filter。

> ⚠️ 这一点被你们自己的 AETHER patch 放大了:上游 `IterativeLocalRefinement` 在第 2 轮会把 loss 降级成 `TRIVIAL`(便宜),你们的注释明确写了"keep CAUCHY on every local pass"。所以第 2 轮是**满价的鲁棒 BA**,不是上游那个便宜的收尾轮。这是有意的质量决策(注释里有理由),我只是指出它的成本归属。【源码:`sfm/incremental_mapper.cc` `IterativeLocalRefinement`】

---

## 一、Q1 — local BA 的收敛容差

### 1.1 `function_tolerance=0` + `gradient_tolerance=10.0` + `parameter_tolerance=0` 的**实际停机行为**

我读了你们 vendored 的 Ceres 2.2 源码(`third_party/ceres/internal/ceres/trust_region_minimizer.cc`),三个判据的**确切代码**是:【源码】

```cpp
bool TrustRegionMinimizer::GradientToleranceReached() {
  if (!iteration_summary_.step_is_successful ||
      iteration_summary_.gradient_max_norm > options_.gradient_tolerance) return false;  // 绝对比较
```
```cpp
  const double absolute_function_tolerance = options_.function_tolerance * x_cost_;   // 相对 cost
  if (fabs(iteration_summary_.cost_change) > absolute_function_tolerance) return false;
```
```cpp
  const double step_size_tolerance =
      options_.parameter_tolerance * (x_norm + options_.parameter_tolerance);          // 相对 |x|
```
上游同一段:<https://github.com/ceres-solver/ceres-solver/blob/master/internal/ceres/trust_region_minimizer.cc>

**结论(可以拿去当定论):**

1. `function_tolerance = 0` → `absolute_function_tolerance = 0`,`fabs(cost_change) > 0` 几乎恒真 → **该判据被完全关闭**(唯一例外是 cost_change 精确等于 0.0)。
2. `parameter_tolerance = 0` → `step_size_tolerance = 0` → **同样完全关闭**。
3. 所以 local BA 的**实际停机条件只剩三条**:
   - `gradient_max_norm ≤ 10.0` **且当轮 step 成功**(`GradientToleranceReached`);
   - `iteration ≥ max_num_iterations`(你们 =15);
   - `trust_region_radius ≤ min_trust_region_radius`(默认 1e-32,基本不触发)。
4. **`gradient_tolerance=10.0` 不是"关掉",而是接管者。** Ceres 默认 1e-10,COLMAP 把它抬了 **11 个数量级**,这是刻意把它变成**主停机判据**:先撞上一个很松的梯度门就走人。global BA 用 1.0,local 用 10.0 —— "越内层预算越糙"是上游一贯梯度。【源码 `controllers/incremental_pipeline.cc:171-176 / 212-217`】
5. **它会不会每次都烧满 15 轮?——取决于梯度是否掉到 10 以下,这是可测的,而且你们从没测过。** 这是本节唯一需要做实验的地方(见 1.4)。
6. **一个构造性事实:local BA 永远至少跑 1 次线性求解,即使起点已经是最优。** `IterationZero()` 显式设 `iteration_summary_.step_is_successful = false`,而 `GradientToleranceReached()` 第一个条件就是 `!step_is_successful → return false`。所以第 0 轮**不可能**触发梯度收敛。**这直接意味着:`ba_local_max_refinements=2` 的第二轮,即使模型已经完全收敛,也要付一次完整的 Schur 分解。**【源码,构造性】

### 1.2 COLMAP 为什么把 `ba_local_function_tolerance` 设成 0 —— **有官方答复,而且是"没理由,只是没人重测过"**

[colmap/colmap#2703](https://github.com/colmap/colmap/issues/2703)(2024-08,标题就是"Why does COLMAP set the Ceres solver tolerance value to 0"):

- 维护者 **@sarlinpe**(Paul-Edouard Sarlin)确认:gradient/parameter tolerance 在 local 与 global BA 里被覆盖,function tolerance "indeed set to zero",并写道他认为**需要更完整的 benchmark 来调这些参数、确认放大它们能省时间且不掉质量**,并且他**怀疑 parameter tolerance 帮助最大**。
- 维护者 **@ahojnnes**(Johannes Schönberger,COLMAP 作者)回复:这些参数是 **"tuned in a rather empirical manner many years ago"**,底层算法与实现之后都大改过,**"It will be good to revisit these."**

> 这是你们能拿到的最强背书:**上游作者本人承认 ftol=0 是多年前的经验值、值得重估**。你们把 global 改成 1e-6 拿到 −30% 且质量在噪声带内,已经是在替上游做这件事;**local 侧同样没有"上游有理由"这层阻力**。
> 补充【明示缺口】:除 #2703 外,我没有找到任何 commit message / PR / 邮件列表贴解释 `ba_local_function_tolerance=0` 的初始动机。#2703 的讨论**至今没有后续 PR**。

相关但不同的一条:[#4446 "Unify BA options OR expose solver thresholds during incremental_mapping"](https://github.com/colmap/colmap/issues/4446) 说明上游至今没把"更细的收敛控制"排上优先级。

### 1.3 参数默认值核对(vendored 4.1.0 源码逐字)【源码】

`controllers/incremental_pipeline.h`:
```
ba_local_function_tolerance   = 0.0     // 你们 = 0.0(未改)
ba_local_max_num_iterations   = 25      // 你们 = 15   ← 已比上游紧
ba_local_max_refinements      = 2
ba_local_max_refinement_change= 0.001
ba_global_function_tolerance  = 0.0     // 你们 = 1e-6 ← 已认证
ba_global_max_num_iterations  = 50
ba_global_max_refinements     = 5
ba_global_max_refinement_change=0.0005
```
`sfm/incremental_mapper.h`:`ba_local_num_images = 6`。
`controllers/incremental_pipeline.cc`:local 段硬编码 `gradient_tolerance = 10.0`、`parameter_tolerance = 0.0`、`max_linear_solver_iterations = 100`;global 段硬编码 `gradient_tolerance = 1.0`。

> ⚠️ **`max_linear_solver_iterations = 100` 对你们是死参数**:它只作用于迭代解法(ITERATIVE_SCHUR / CGNR),而 local BA 6–7 图必然路由到 **DENSE_SCHUR**(`max_num_images_direct_dense_cpu_solver = 50`,直接解)。你们配置清单里把它列为"local BA 的实际配置"是**无害但无意义**的一项。【源码 `estimators/bundle_adjustment_ceres.h:69` + `.cc` 路由】

### 1.4 建议(Q1)

| # | 动作 | 收益 | 无损? | 跨端 | 许可 | 成本 | 证据 |
|---|---|---|---|---|---|---|---|
| **A1** | **先测,别改**:在 local BA 的 `Solve()` 后把 `summary.termination_type` / `num_successful_steps` / `iterations.size()` / 最后一轮 `gradient_max_norm` 打进 `frame_split` | 0(但决定后面全部) | 无损(纯观测) | ✅ | 无 | ~1h | 【源码】 |
| **A2** | 若 A1 显示**大多数 solve 以 NO_CONVERGENCE 打满 15 轮** → 试 `ba_local_function_tolerance = 1e-6`(与 global 同口径),A/B 逐位 + reproj | 按 global 的经验 −20~30% 的 local BA 时间(即 −10~17% 总时长) | **有损(位级必变)**,需按 global 的同一套"噪声带内"验收 | ✅ | 无 | ~半天 A/B | 【类比 global 已认证 −30%】 |
| **A3** | 若 A1 显示**大多数 solve 已经因 gtol=10 提前收敛** → ftol 无用,直接放弃这条线 | — | — | — | — | — | — |
| **A4** | sarlinpe 亲口"怀疑 parameter tolerance 帮助最大" → A2 的同一轮里顺手把 `parameter_tolerance` 也做一个 arm(注意它被**硬编码**在 `incremental_pipeline.cc`,要改源码不是改 option) | 未知 | 有损(位级) | ✅ | 无 | 同 A2 | 【维护者原话】 |

**关于"增量 SfM 的 local BA 实际需要几轮"的公开数据**:我没有找到任何论文/博客量过 COLMAP local BA 的迭代数分布【明示缺口】。相邻证据是 SLAM 界的固定小预算(ORB-SLAM2 local BA = 5 轮 + 剔外点后 10 轮,[Optimizer.cc](https://github.com/raulmur/ORB_SLAM2/blob/master/src/Optimizer.cc))和 Engels/Nistér《Bundle Adjustment Rules》的"3 轮×3 视图或 4 轮×4 视图即可够到谷底"([ISPRS PDF](https://www.isprs.org/proceedings/xxxvi/part3/singlepapers/O_24.pdf))—— 这些都指向 15 轮**远超**实际需要,但都不是 COLMAP 口径,**不能当证据用,只能当假设**。A1 一小时就能把这个假设变成事实。

---

## 二、Q2 — 窗口与频率

### 2.1 参数语义(源码级,别再从二手表格抄)

- **`ba_local_num_images`(6)**:不是"最近 6 帧",是 `FindLocalBundle()` 选出的 **当前图 + 共视 3D 点最多的 (N−1) 张邻图**。选完还要过一个**八级逐步放松**的筛子:`(ba_local_min_tri_angle/1.0, 0.6·NumPoints3D)` → … → `(/6.0, 0.1·NumPoints3D)`,先卡视差角再卡共视数,都不够才退回"就取最重叠的"。`ba_local_min_tri_angle` 默认 **6°**(`sfm/incremental_mapper.h:101`)。你们代码注释里那句 "selects the six most-connected images (not the six most recent frames)" 是对的。【源码 `sfm/incremental_mapper_impl.cc::FindLocalBundle`】
  > ⚠️ 一个和 §4.2 直接相关的细节:候选表是从 **`std::unordered_map<image_t, size_t> shared_observations`** 拷出来再用**非稳定 `std::sort`** 按共视数降序排的 → **共视数相同的图,谁进窗口取决于 unordered_map 的迭代顺序**。这就是为什么"持久化 DatabaseCache"必须做 byte-diff 而不能靠推理:只要 hash 桶布局变了,选进窗口的图就可能换人。
- **`ba_local_max_refinements`(2)** / **`ba_local_max_refinement_change`(0.001)**:外层循环最多 2 轮;每轮结束算
  `changed = (merged + completed + filtered) / adjusted_observations`,`changed < 0.001` 才 break。**实测你们从不 break。**
- **一个被普遍忽略的事实:`AdjustLocalBundle` 里 Ceres 只是其中一段。** 同一函数还要跑 `MergeTracks` + `CompleteTracks` + `CompleteImage` + `FilterPoints3DInImages` + `FilterPoints3D`(后两个还带一句上游注释:"This results in duplicate work ... but the filtering is not a bottleneck at this point")。你们的 353ms 是**这一整包 × 2 轮**,不是 2 次 Ceres。**A1 的仪表必须把 Ceres 时间和三角化/过滤时间分开** —— 否则你们可能一直在优化错的那一半。【源码】

### 2.1b 官方 FAQ 的"Speedup bundle adjustment"一节 **完全没提 local BA**

我逐条读了 <https://colmap.github.io/faq.html> 的提速章节,给出的旋钮只有:
- `--Mapper.ba_global_max_num_iterations`、`--Mapper.ba_global_function_tolerance`("trade a small amount of accuracy for runtime")
- `--Mapper.ba_global_frames_freq` / `ba_global_points_freq` / `ba_global_frames_ratio` / `ba_global_points_ratio`(降低**全局** BA 频率)
- 减少特征数 / 限制匹配对来缩小问题规模

**`ba_local_max_num_iterations`、`ba_local_max_refinements`、`ba_local_num_images` 一个都没出现。**【文档】

> 这解释了很多事:在上游的**离线**工作流里,local BA 从来不是瓶颈——周期性 global BA 才是,所以官方所有提速建议都指向 global。**你们把 in-loop global BA 全部 defer 到 finalize(`defer_global_ba = true`)之后,local BA 才第一次变成主成本。这是一个上游从未优化过的 regime。** 也就是说:这条路上没有现成答案可抄,但也没有"上游有理由不动它"的阻力(见 §1.2 维护者原话)。

### 2.2 "少跑 local BA" 的可证明无损做法 —— **诚实结论:不存在**

我把这条问题拆成两半:

- **真无损(能证明这一帧不需要 BA)**:没有任何已发表方法能做到。理由是构造性的:BA 之前你不知道新观测会把窗口推到哪里,唯一能"证明不需要"的判据就是先解一遍。所有候选(关键帧选择、条件触发、位姿变化阈值)都是**用一个便宜的代理量替代真解**,代理量必然有假阴性 → 质量换速度。
- **业界确实在做的**:ORB-SLAM3 / OpenMVG / Theia 等都是**关键帧制**(只对关键帧跑 local BA),on-the-fly SfM 系列同理。但那是"少建图"不是"无损少 BA"。

> 对你们:因为**用户每按一次快门才喂一帧**,你们的每一帧本来就是关键帧。关键帧稀释在你们的产品形态里等于"丢掉用户拍的照片",直接违反"点云全量交付"。**这条线关闭。**

**唯一一个我认为值得写下来的"接近无损"变体(仍需签决)**:`ba_local_max_refinements` 的第 2 轮,在 `changed` 已经很小时其实是在做重复功。实测你们从不 break,说明 0.001 这个阈值对你们的数据太严。把它放宽到上游 global 的量级(0.0005 → 更松,如 0.01)会让部分帧只跑一轮。**这是纯粹的质量换速度,位级必变,列入"需签决"一节。**

### 2.3 Ceres 结构复用 / warm start

【源码 + 文档】Ceres 没有"跨 Solve 复用符号分解"的公开 API:`Solver::Options::linear_solver_ordering` 可以复用(省掉每次重算 ordering),但 `DENSE_SCHUR` 根本不做符号分解(稠密直接解),所以**对你们这条路由没有可复用的东西**。真正每帧重复的开销是 **`ceres::Problem` 的构建**(每个观测一个 ResidualBlock),而那部分被 COLMAP 封在 `CreateDefaultBundleAdjuster` 里,和 §0.2 的 `ObservationManager` 重建是同一类问题 —— **解法在 §四,不在 Ceres 侧。**

---

## 三、Q3 — 更快的求解器 / 线性代数

### 3.1 结论先行:**6 相机的窗口比整个 BA 加速领域的最小 benchmark 还小 8 倍**

近三年所有 BA 加速工作(MegBA / PoBA / RootBA / DeepLM / STBA / Caspar / Graphite / TurboMap / InstantSfM / BAE)的**最小实验规模是 BAL 的 Ladybug-49:49 相机 / 7776 点 / 31843 观测**(<https://grail.cs.washington.edu/projects/bal/ladybug.html>)。你们的 local BA 是 **6–7 相机**。它们优化的对象是"reduced camera system(RCS)太大导致 Cholesky 爆炸";你们的 RCS 只有 **36–54 维**,整个矩阵在 L1 cache 里,**不存在被加速的对象**。【论文 + 推断,但由算法定义直接推出】

- **PoBA(Power Bundle Adjustment, CVPR'23)**摘要自我定位为 `"expansion type algorithm for solving large-scale bundle adjustment problems"`(<https://arxiv.org/abs/2204.12834>)。它用幂级数展开替代对大 RCS 的 Cholesky/CG —— 54 维矩阵直接 LLT 是微秒级,展开只会更慢。
- **RootBA / √BA(CVPR'21)**对你们唯一有价值的是它的**单精度结论**,不是速度(见 3.4)。
- 我(和子代理)**没有找到任何一篇 BA 加速论文在 <49 相机上做过评测**。【明示缺口】

### 3.2 各方案的 CUDA 依赖与许可(逐个读过 LICENSE 原文)

| 项目 | CUDA 硬依赖? | 许可 | LICENSE URL | 对 6 图窗口 |
|---|---|---|---|---|
| MegBA | **是**(CUDA≥11.2 + NCCL2,无 CPU 路径) | Apache-2.0 ✅ | <https://github.com/MegviiRobot/MegBA/blob/main/LICENSE> | ❌ |
| DeepLM | 是 | **GPL-3.0** ⛔ | <https://github.com/hjwdzh/DeepLM/blob/main/LICENSE> | ❌ 许可 |
| PBA / Multicore BA (Wu) | 有 CPU 路径 | **GPL-3.0** ⛔ | <https://github.com/cbalint13/pba/blob/master/src/pba/pba.cpp>(源码头) | ❌ 许可 |
| STBA | 否 | MIT ✅ | <https://github.com/zlthinker/STBA/blob/master/LICENSE> | ❌ 规模(分块,6 相机无块可分) |
| PoBA | 否 | BSD-3 ✅ | <https://github.com/simonwebertum/poba/blob/main/LICENSE> | ❌ 规模 |
| RootBA / √BA | 否(BLAS/LAPACK/TBB) | BSD-3 ✅ | <https://github.com/NikolausDemmel/rootba/blob/master/LICENSE> | ⚠️ 只有单精度结论有用 |
| g2o | 可选 | **混合**:主体 BSD,`csparse_extension`=LGPL-2.1+,`g2o_viewer`/`g2o_incremental`=GPL3+ ⛔ | <https://github.com/RainerKuemmerle/g2o/blob/master/README.md> | ❌ 许可要逐目录裁 |
| GTSAM | 否 | BSD-3 ✅(4.3 起 Boost 可完全关) | <https://github.com/borglab/gtsam/blob/develop/LICENSE> | ⚠️ 换后端成本大 |
| SymForce (Skydio) | 后端有 C++/Python/CUDA(实验);**无 Metal/WGSL/GLSL** | Apache-2.0 ✅ ⚠️ **全仓 bundle 了 LGPL 的 `third_party/skymarshal`,vendor 必须排除** | <https://github.com/symforce-org/symforce/blob/main/LICENSE> | ⚠️ 见 3.6 |
| Theseus (Meta) | PyTorch | MIT ✅ | <https://github.com/facebookresearch/theseus/blob/main/LICENSE> | ❌ 端上不可部署 |
| DABA (Meta) | 是 | MIT ✅ | <https://github.com/facebookresearch/DABA/blob/main/LICENSE> | ❌ 分布式多 GPU |
| Graphite | **CUDA C++ only** | MIT ✅ | <https://github.com/sfu-rsl/graphite/blob/master/LICENSE.md> | ❌ |
| TurboMap | **CUDA 12.5** | MIT ✅ | <https://github.com/sfu-rsl/TurboMap/blob/main/LICENSE> | ❌ |
| InstantSfM | NVIDIA only | 仓库许可**未落地,未找到证据** | <https://arxiv.org/html/2510.13310v1> | ❌ |
| Ceres `TinySolver` | 否,header-only | BSD-3 ✅ | <https://github.com/ceres-solver/ceres-solver/blob/master/include/ceres/tiny_solver.h> | ⚠️ **dense-only**,只有 pose-only(冻结 3D 点)才进甜区;头注释自称 `"experimental and will change"` |

### 3.3 Ceres 自身的余量:**真正的钱在固定开销侧,不在算法侧**

#### 🔥 3.3.1 官方自带的 −23% 实测:**手动指定 `linear_solver_ordering`,而你们没做**

Ceres 官方 FAQ 同一问题的两份 FullReport【官方文档,逐字数字,我在本地 `third_party/ceres/docs/source/solving_faqs.rst:104-162` 复核过】:

```
自动 ordering :  Preprocessor 0.283 | Jacobian 0.361 | Linear solver 0.382 | Minimizer 0.895
-ordering=user:  Preprocessor 0.051 | Jacobian 0.344 | Linear solver 0.372 | Minimizer 0.854
```
Preprocessor **−5.5×**,总时间 **−23%**。

原因【官方文档 `nnls_solving.rst:1150-1155`】:不给 ordering 时,Ceres **每次 Solve 都要跑一遍近似最大独立集算法**来找第一消元组;而标准 BA 的正确答案是**固定的**——`"the first elimination group containing all the 3d points, and the second containing the parameter blocks for all the cameras"`。

**为什么这对你们比对别人更重要**:preprocessor 是**每次 `Solve()` 的固定开销**,和迭代数无关。你们 local BA 每帧 2 次 Solve、每次只跑十几轮迭代、每帧还重建 Problem —— 固定开销的占比**必然高于**官方那个 23% 的例子。

**已核实:vendored COLMAP 的 `estimators/bundle_adjustment_ceres.cc` 里 `grep -n "ordering\|Ordering"` 零命中**,你们的 `official_bundle_adjustment_ceres.cc` 同样没有 `SetParameterBlockOrdering`。**这个杠杆完全没被用过。**

⚠️ 无损性:如果显式给出的消元组与 Ceres 自动算出的**相同**,数值路径不变 → 有机会逐位一致;若不同,浮点求和顺序变 → 位级必变。**必须 byte-diff 验收**,但即使位级变了,它也属于"同一个最优解的不同到达路径",风险低于改 tolerance。

#### 3.3.2 后端与枚举现状【官方源码/文档】

- `SparseLinearAlgebraLibraryType { SUITE_SPARSE, EIGEN_SPARSE, ACCELERATE_SPARSE, CUDA_SPARSE, NO_SPARSE }`;`DenseLinearAlgebraLibraryType { EIGEN, LAPACK, CUDA }`(<https://github.com/ceres-solver/ceres-solver/blob/master/include/ceres/types.h>)。
- **ACCELERATE_SPARSE 不是实验性**(2.0 起正式,`internal/ceres/accelerate_sparse.cc`,CMake 里 `option(ACCELERATESPARSE ... ON)` 仅 APPLE 默认开)。**但你们已经实测它在 CAUCHY 重加权的 Schur 补上 `SparseFactorizationFailed`,并已切 EIGEN_SPARSE —— 这个结论不需要推翻。**
- 🔥 **反直觉**:Ceres **官方 iOS 工具链主动 `update_cache_variable(LAPACK OFF)`**,并打印 "Building for iOS: SuiteSparse, LAPACK are not available."(<https://github.com/ceres-solver/ceres-solver/blob/master/CMakeLists.txt>)。你们要在 iOS 上用 Accelerate 的 LAPACK,必须自己 `-DLAPACK=ON` + 链 `Accelerate.framework`。
- **Ceres 的 GPU 只有 CUDA**。`CUDA_SPARSE`(cuDSS)在 2.2.0 里**枚举存在但工厂没实现**(2.2.0 tag 的 `sparse_cholesky.cc` 只有三个分支;真实现 2024-07 才进 master)。**Metal / Vulkan / OpenCL / SYCL 一个都没有**(诉求 issue <https://github.com/ceres-solver/ceres-solver/issues/760>,无实现)。**2.3 尚未发布**,最新 stable 仍是 2.2.0。
- **小规模选型,官方逐字**:`"For bundle adjustment problems with up to a hundred or so cameras, use DENSE_SCHUR."`(<https://ceres-solver.readthedocs.io/latest/solving_faqs.html>)→ **6 相机 ≪ 100,你们的 DENSE_SCHUR 路由是官方口径,没有可换的。**

#### 3.3.3 各选项在 6 相机下的真实语义(逐条判死)

| 选项 | 判决 | 依据 |
|---|---|---|
| `use_explicit_schur_complement` | ❌ **代码路径根本不读**。源码注释逐字:`"Use an explicitly computed Schur complement matrix with ITERATIVE_SCHUR."` | `solver.h` |
| `max_linear_solver_iterations` | ❌ 只对 ITERATIVE_SCHUR/CGNR 有效 | 官方文档 |
| `linear_solver_ordering_type`(AMD/NESDIS) | ❌ 稀疏 fill-reducing ordering,DENSE_SCHUR 无意义 | 官方文档 |
| `use_mixed_precision_solves` | ⚠️ 语义比传闻宽(double 组装 + **single 分解** + double 迭代精化,dense/sparse 都支持),但 **54 维矩阵本来就在 L1,预期收益 ≈ 0**。你们已有 env-gated 实现,可以直接量一次收工 | `nnls_solving.rst` |
| `use_inner_iterations` | ❌ 收益集中在早期迭代;你们每次只跑十几轮;与 `EvaluationCallback` 不兼容 | `nnls_solving.rst` / `problem.h` |
| **`linear_solver_ordering`** | ✅ **见 3.3.1,最高价值** | 官方 FAQ 实测 |
| `Problem::Options::enable_fast_removal` | ⚠️ `"trades memory for faster RemoveResidualBlock()"`,只有在复用 Problem 做滑窗增删时才有用 | `problem.h` |
| `Problem::Options::context` | ⚠️ `"Ceres can reuse expensive objects to create"` —— 跨帧共享同一 `Context`(线程池)可省掉每帧线程池重建 | `problem.h` |
| `disable_all_safety_checks` | ❌ 官方明说只省"构造期的 ~5%",且警告别开 | `problem.h` |

⚠️ 一条**不要当事实用**的东西:维护者 Sameer Agarwal 在邮件列表说 `"You should have no problems adding and removing parameter or residual blocks."`(<https://groups.google.com/g/ceres-solver/c/vkmVaSMLswA>),但**该线程没有给出复用 vs 重建的实测数字**。"复用一定更快"是推断。

#### 3.3.4 Apple AMX / Accelerate 在小矩阵上:**证据不支持,大概率负收益**

- **未找到任何 Eigen vs Accelerate 在几十~几百维上的直接 benchmark。**【明示缺口】
- 【博客实测】Apple Silicon 上 OpenBLAS vs Accelerate:`"For very small input sizes, the performance difference is insignificant"`,作者归因于 `"memory access and function call overhead dominate"`,优势要到 512 元素以上才出现(<https://dev.to/frosnerd/comparing-openblas-and-accelerate-on-apple-silicon-for-blas-routines-2pb9>)。
- 【Apple 论坛】Accelerate 的函数 `"are not inline, as far as I can tell"`(<https://developer.apple.com/forums/thread/765217>)。
- 最接近的真机参照(M1 + iPhone 13 mini,含 Cholesky 章节):<https://github.com/shoyamanishi/AppleNumericalComputing>
- 【推断】54×54 Cholesky ≈ 5 万 flop,A16 上微秒级,BLAS 调用开销摊不开。**local BA 的 dense 后端从 EIGEN 换 LAPACK 不推荐**(注:你们 finalize 段那条 DENSE→LAPACK 分层是 180 图以上的大问题,和这里不是一回事,不要混淆)。
- ⚠️ 一个你们该自查的点:Ceres 对 `ACCELERATE_NEW_LAPACK` 宏没有任何处理;macOS 13.3+ / iOS 16.4+ 不定义它拿到的是 **legacy LAPACK 3.2.1 接口**(<https://developer.apple.com/documentation/accelerate/blas/>)。**未找到证据说明这会影响正确性,但值得 grep 一下 vendored 树。**

### 3.4 Dawn/WGSL 或移动 GPU 做 BA 线性求解:**死路,而且有一手数字**

**唯一真实先例**:SFU 硕士论文(2023)*Improving the Performance of Bundle Adjustment for On-Device SLAM using GPU Resources*,Shishir Gopinath(导师 Steven Ko,即 Graphite/TurboMap 那个实验室)。<https://summit.sfu.ca/_flysystem/fedora/2023-06/etd22484.pdf>
做法:`"develop Vulkan compute shaders for calculating the Schur complement of a sparse matrix"`,集成进 **g2o + ORB-SLAM3**。

**实测结果,规模与你们几乎一样(local BA 314ms vs 你们 353ms):**

| 平台 | local BA CPU | local BA GPU(Vulkan) | 提升 |
|---|---|---|---|
| Jetson Xavier NX(TUM-VI) | **314.02 – 355.83 ms** | 254.69 – 288.99 ms | **−13.8% – −20.1%** |
| 桌面(5800X + RTX3080) | 68.40 – 75.91 ms | 52.25 – 63.56 ms | −16.3% – −25.8% |

🔥 **最致命的一句**(§4.4.2,逐字):`"the linear solver step performs similarly despite the readback overhead"` —— **线性求解那一步搬到 GPU 后基本没提速**,全部收益来自 Schur 补构造与 landmark 更新。
🔥 **第二致命**:该实现跑的是 **fp64**(Vulkan `shaderFloat64`)。

**而 Metal / WGSL 没有 f64:**
- Apple GPU 硬件无 FP64;唯一模拟项目 `metal-float64`(MIT)自述吞吐 `"1/32-1/64 the throughput of their 32-bit counterparts"`,且 **2024-08-11 已归档为只读**,作者自称 `"not a finished library"`(<https://github.com/philipturner/metal-float64>)。
- WGSL 规范里 binary64 只用于编译期类型检查,`"cannot be spelled in source"`;f64 扩展仍是 open issue(<https://github.com/gpuweb/gpuweb/issues/2805>)。

**f32 对滑窗 BA 有论文直接定罪**【论文,逐字】Demmel et al., *Square Root Marginalization for Sliding-Window Bundle Adjustment*(<https://arxiv.org/abs/2109.02182>):
> `"in single precision, conventional Hessian-based marginalization leads to numeric failures and reduced accuracy"`

**反面条件**:RootBA/√BA 摘要说单精度**可行**,但前提是改成平方根/QR 形式(<https://arxiv.org/abs/2103.01843>)。→ **f32 BA 不是"小心点就行",是必须换掉整条 Schur 路线。**

**再加一层规模障碍**【论文】*Characterizing WebGPU Dispatch Overhead*(<https://arxiv.org/abs/2604.02344>):每次 dispatch API 开销 `"24-36 μs on Vulkan and 32-71 μs on Metal"`,结论 `"per-operation overhead dominates regardless of kernel quality"`。54 维 Cholesky ≈ 5 万 flop,**一次 Metal dispatch 的时间里 CPU 已经算完好几遍**。更致命的是 LM 外层每轮都要把 cost 读回 CPU 判断步长接受/拒绝 → 15 轮 × 2 refinement = 30 次往返。

**生态**:**不存在任何 WebGPU/WGSL 的稀疏线性求解器或 CG 库**(搜遍 GitHub topics / awesome-webgpu,未找到证据)。Apple `MPSMatrixDecompositionCholesky` 只有 f32/f16 且不跨端。

> **判决:关闭。** 复活的假设性条件是"先在 CPU 上把 local BA 改写成 √BA/平方根边缘化形式,证明 f32 无损后再谈 GPU" —— 两个季度的工作量,天花板是 353ms 里"线性求解那一段"的 20%。**在 3.5 拆开 353ms 之前,连这个天花板都是猜的。**

### 3.5 🔴 在选任何方案之前:**先用 `Solver::Summary::FullReport()` 把 353ms 拆开**

Ceres 的 FullReport 天然给出 `Preprocessor / Residual evaluation / Jacobian evaluation / Linear solver / Minimizer` 五段。官方 FAQ 那个例子里线性求解只占 0.382/1.220 = **31%**。
**如果你们的 local BA 里线性求解只占 10–20%(6 相机的 RCS 极小,这是我的预期),那 §3.4 的 GPU 路线天花板就是 −2~4%,直接闭案;而 §3.3.1 的 preprocessor 与 §四的 Problem 构造开销会变成主角。**
这是本节唯一的必做项,成本 <1 小时。

### 3.6 唯一还活着的"抄"方向(需签决):SymForce 的 **C++ codegen**,不是 CUDA

CASPAR 的真杠杆不是 CUDA,是"用符号微分把 residual + Jacobian 融合成一个 kernel,消掉 AutoDiff 与内存往返"。SymForce 的 **C++ 后端是成熟非实验的**,可以为你们的 `SimpleRadial + Pose + Point` 因子生成手写级 C++ Jacobian,替掉 Ceres AutoDiff —— **纯 CPU、跨端、Apache-2.0**。
⚠️ vendor 时必须排除 **LGPL 的 `third_party/skymarshal`**。
⚠️ SymForce **没有 Metal/WGSL/GLSL 后端**,官方只把 GLSL/HLSL 列在"欢迎贡献"(<https://symforce.org/>)。
⚠️ 这会改变数值(手写 Jacobian vs AutoDiff 的浮点路径不同)→ **位级必变,属于需签决的大动作**,且收益要先由 3.5 的 Jacobian evaluation 占比来定价。


### 3.7 COLMAP 4.x 的 CASPAR:**对移动端是构造性死路**

- COLMAP **4.1.0 release notes** 原文:"Added Caspar, a **GPU-accelerated** bundle adjustment backend ... often 1-2 orders of magnitude faster than **the Ceres CUDA backend**"。
- COLMAP **4.1.1 release notes**:"**Fail the Caspar build early with a clear error on CUDA architectures below 7.0.**"
  → CASPAR = **CUDA-only**,连 CUDA 7.0 以下都不支持,手机上不存在可行路径。
- 你们 vendored 的构建已经正确地把它排除了:`build(4.1.0): exclude bundle_adjustment_caspar.cc from vendored glob`(你们自己的 commit 44d50715)。
- 出处:<https://github.com/colmap/colmap/releases>(4.1.0 / 4.1.1 tag)
- **身份补全(我在你们树里直接查的)**:`colmap-src/thirdparty/Symforce-Caspar/` = Skydio **SymForce** 的 Caspar 模块,论文 *"Caspar: CUDA Accelerator for Symbolic Programming with Adaptive Reordering"*(ICRA 2026,<https://arxiv.org/abs/2605.30583>)。目录里 `generated/{f32,f64}/` 共 **482 个 `.cu` 文件**,全是 `__global__` kernel + `cooperative_groups` + `cuda_runtime.h`;`estimators/bundle_adjustment_caspar.cc` 无条件 `#include "colmap/util/cuda.h"`。许可 = **Apache-2.0**(`thirdparty/Symforce-Caspar/LICENSE`,我读过原文),**许可干净但跑不了**。
- 🔥 一个值得注意的旁证:`bundle_adjustment_caspar.h` 里 `#ifdef CASPAR_USE_DOUBLE` → **CASPAR 默认走 `generated/f32/`,即默认单精度**。COLMAP 官方自己的新 GPU BA 后端默认 fp32 —— 这是 §3.4 精度讨论的重要参照(但注意它仍有 f64 版本可选,而 Metal/WGSL 连选项都没有)。

**判定:CASPAR 关闭,不需要再评估。** `BundleAdjustmentBackend::{CERES, CASPAR}` 这个枚举在 4.1.0 的 `estimators/bundle_adjustment.h:60` 存在,但对我们只有 `CERES` 一个可选值。

---

## 四、Q5(提前说,因为它是最大的)— 你们没看到的结构性机会

### 4.1 🥇 **local BA 单线程**(最高杠杆 × 最低风险)

**证据链(全是你们自己的数据):**

1. `run.log` 里 `threads=` 的分布:**`threads=1` × 240、`threads=12` × 102、`threads=6` × 5**。逐帧对齐后更精确:每帧第 1 次 local solve 有 **116/152 帧是 threads=1**、34 帧是 threads=12;第 2 次 solve 118 帧是 1、32 帧是 12。**即 ~78% 的 local BA 求解跑在单线程上**,其余的按 `num_threads=-1` 吃满 host 的 12 核(**这在设备上意味着吃满 A16 全部 6 核,采集期完全不给相机/UI 留核** —— 是另一个方向的问题)。5 次 `threads=6` = 拍摄期增量全局 BA(走 `LiveBaThreads()`)。【实测】
2. 根因【源码】:`estimators/bundle_adjustment_ceres.cc` 的 `CreateSolverOptions()` 末尾:
   ```cpp
   if (problem.NumResiduals() < min_num_residuals_for_cpu_multi_threading) {
     custom_solver_options.num_threads = 1;
   ```
   `min_num_residuals_for_cpu_multi_threading` 上游默认 **50000**(`bundle_adjustment_ceres.h:65`)。
   **算术对得上**:这次 run 最终 `n_obs=411770 / n_reg=146` ≈ **2820 观测/图**,7 图窗口 ≈ 19,700 观测 → `NumResiduals()` ≈ **39,400 < 50000** → 强制单线程。窗口偏大(共视多)的那 22% 才越过 5 万线,于是变成 `threads=12`。**阈值恰好卡在你们的问题尺寸中间,这就是为什么会出现 78/22 这种诡异的混合。**
3. 你们**早就知道这个坑并修过**:批处理路径 `RunIncremental()` 里写着 `pipeline_opts->ba_min_num_residuals_for_cpu_multi_threading = 6000;`(注释:"liter15 + mt6000 (multi-thread above 6k residuals)")。
4. **但流式路径没继承**:`official_aether_sfm_c.cc` 的每帧 local-BA 块里 `colmap::IncrementalPipelineOptions official_options;` 是**新建的默认对象**,只设了 `min_num_matches / triangulation / load_all_images / ba_refine_* / mapper.ba_local_num_images`,**既没设 `ba_min_num_residuals_for_cpu_multi_threading`,也没设 `num_threads`**。→ 吃默认 50000 → 6 图窗口 ~1–3 万 residual → 强制 1 线程。日志逐字印证。
5. Ceres 2.2 的相关能力【文档】:2.2 release notes "Substantial improvement to threading performance across the board" + "Improvements to multi-threaded performance for **small problems**";`DENSE_SCHUR` 自 2.0 起支持多线程;官方 nnls 文档在 BA 章节写 "Setting `Solver::Options::num_threads` to the maximum number possible is highly recommended."(<https://github.com/ceres-solver/ceres-solver/blob/master/docs/source/nnls_solving.rst>)

**动作**:在流式 `official_options` 上补两行 —
```cpp
official_options.ba_min_num_residuals_for_cpu_multi_threading = 6000;  // 与批处理路径一致
official_options.num_threads = LiveBaThreads();                        // 采集期保留两核
```

| 项 | 判定 |
|---|---|
| 预计收益 | 78% 的 solve 从 1 线程升到 4 线程。若 Ceres 在这个尺寸上拿到 1.5–2× → **−13~20s = 总流式时长的 −12~18%**。**这是本文最大的单刀。**(⚠️ 收益上界受 §3.5 的分段结果限制:只有 Jacobian evaluation 与 Schur 消元会并行,Preprocessor 与 Problem 构造不会) |
| 无损/有损 | **需实测判定**。你们已有先例:finalize BA 线程 4→6 实测**逐字节等**(`_host_fixtures/prepay_threads_exact`,T4/T6 各 ×2 PLY byte-identical、迭代数相同)。Ceres 2.2 的并行 Schur 消元用 per-chunk 缓冲 + 确定性归约,你们的 T4/T6 实验已经构造性证明了这条路由的位级稳定性。**但必须对 local BA 单独重跑 byte-diff**,不能靠 finalize 的结论外推。 |
| 跨端 | ✅ 纯 Ceres option,四端一致 |
| 许可 | 无(Ceres = Apache-2.0 / BSD-3,见 §八) |
| 实施成本 | **2 行 + 一次 host A/B** |
| 证据强度 | 【实测】根因与现状;【推断】收益倍数 |

> ⚠️ 一个必须同时做的检查:采集期 CPU 已经被 4K 相机 + GPU matcher CPU 侧 + Dart UI 占着。`LiveBaThreads() = min(6, hw-2)`,A16 是 6 核 → 4 线程,留 2 核。**上机前必须做热受控计时**,否则可能只是把时间从 BA 挪到相机丢帧。

### 4.2 🥈 **持久化 DatabaseCache / IncrementalMapper**(唯一的 O(N) 项)

**证据**:§0.2 的实测表 + 线性拟合 R²=0.958。

**而且 `DatabaseCache::Create` 只是这一坨里的 57%,另一半更狠**【源码】:`IncrementalMapper::BeginReconstruction()` 还会
1. `reconstruction_->Load(*database_cache_)` —— 把全部 camera/image/points2D 重新灌进 reconstruction;
2. `std::make_shared<ObservationManager>(...)` —— 它的构造函数**遍历每一张已注册图 × 每一个 point2D × 该 point2D 的每一条 correspondence**(`sfm/observation_manager.cc` 构造函数尾部的三重循环),外加 `NumMatchesBetweenAllImages()` 建全部 image-pair 统计。
   这次 run 最终有 **411,770 个观测**、平均每个观测十几条共视 → **每帧要跑几百万次内层循环**,而且随 N 线性增长。这就是 tail 里剩下那 ~0.7·fid ms/帧 的主要来源。
3. 还有一个每帧 O(点数) 的 `preview_points` 全量快照(14 万个 `Vector3d`)。

**上游已经为你们做好了**:[colmap/colmap#4279 "Support incremental CorrespondenceGraph and ObservationManager construction"](https://github.com/colmap/colmap/pull/4279)(2026-03-21 合入,**在你们 vendored 的 4.1.0 里**)。PR 原文:

> "Allow CorrespondenceGraph to be queried **without calling Finalize()**, enabling **streaming/online use where images and matches arrive incrementally**. Finalize() remains available as a memory optimization."
> "Add `ObservationManager::AddImage()` so that new images can be registered and triangulated **without rebuilding the entire ObservationManager**."
> "All changes are additive and **have no effects on any existing logics**."

我确认这两个 API 在你们 vendored 树里存在:
- `scene/database_cache.h:97` `void AddImage(class Image image);` → 内部调 `correspondence_graph_->AddImage(...)`(`database_cache.cc:442-446`)
- `scene/correspondence_graph.h:104/110` `AddImage` / `AddTwoViewGeometry`,且 `FindCorrespondences` 有 `if (!finalized_)` 分支(`correspondence_graph.cc:209-212`)
- `sfm/observation_manager.h:76` `void AddImage(image_t image_id);`

**动作**:会话级持有一个 `DatabaseCache` + 一个 `IncrementalMapper`,每帧只 `DatabaseCache::AddImage(new_image)` + 对本帧新写的 TVG 调 `CorrespondenceGraph()->AddTwoViewGeometry(...)` + `ObservationManager::AddImage(image_id)`,**不再** `DatabaseCache::Create` / 不再重建 mapper / 不再 `BeginReconstruction`+`EndReconstruction`。

| 项 | 判定 |
|---|---|
| 预计收益 | 当前 146 帧:**−8.4s(DatabaseCache)+ 大部分剩余 tail** ≈ **−10~14s = −9~13%**;300 帧时 ≈ **−60s**,并把每帧曲线从 O(N) 压平 |
| 无损/有损 | **意图无损,但必须 byte-diff 验收。** 三个已知风险点:① 未 `Finalize()` 的 corr graph 查询路径与 finalized 路径的**遍历顺序**可能不同(`corrs` vs `flat_corrs`)→ 影响 `FindLocalBundle` 的并列打破;② 持久 `IncrementalMapper` 的 `modified_points3D_` / `reg_stats_` 跨帧累积语义与"每帧新建"不同;③ `unordered_map` 迭代顺序。**这三条都是可以用你们现有 SHA/byte-diff harness 一次跑清楚的**,不是理论障碍。 |
| 跨端 | ✅ 纯 C++ |
| 许可 | 无(COLMAP BSD-3) |
| 实施成本 | 中(~1–2 天 + 一次全量 parity) |
| 证据强度 | 【实测】成本与增长;【文档】上游 PR 明示为 streaming 场景所加;【推断】位级等价 |

> 附带:每帧那次 `preview_points` 全量快照(遍历 `live_recon.Points3D()` 拷 14 万个 `Vector3d`)也是 O(N) 且在同一段里。改成"只在 UI 真的要读时才快照"或增量维护,是同一刀的顺手部分。

### 4.3 🥉 **把 TVG 从 GPU 匹配的关键路径上摘下来(流水线,不是异步 BA)**

**先说清楚这**不是**你们杀掉的那条路**:被永久关闭的是"精化晚几帧落地"。这里说的是**同一帧内部**的生产者/消费者重叠 —— 本帧结束前必须全部 join,落地时刻与顺序完全不变。

**现状**【源码】:每帧对 ~12 个候选对做 `GPU 匹配 → EstimateTwoViewGeometry`,**串行,同一个线程**。GPU 匹配 97ms(GPU 忙、CPU 闲),TVG 69ms(CPU 忙、GPU 闲)。**两种资源从不重叠。**

**动作**:开一个**专用 TVG 线程**,GPU 匹配完第 i 对就投递给它,主线程继续匹配第 i+1 对;本帧末尾 join。

| 项 | 判定 |
|---|---|
| 预计收益 | 上界 = min(97, 69) ≈ **69ms/帧 → −10s = −9%**;实际因首尾气泡约 −6~8% |
| 无损/有损 | **可以做到逐位一致,但有一个必须遵守的约束**:COLMAP 的 PRNG 是 **`thread_local`**(`math/random.h:41` `extern thread_local std::unique_ptr<std::mt19937> PRNG;`,默认 seed 0)。只要**所有 `EstimateTwoViewGeometry` 都在同一个专用线程上、按与今天完全相同的顺序执行**,该线程的 mt19937 流与今天逐字相同 → RANSAC 采样序列相同 → **位级一致**。⚠️ **反过来,把 TVG 拆到多个线程并行做 pair,一定不是位级一致**(每个新线程的 PRNG 从 seed 0 重新开始)。 |
| 跨端 | ✅ `std::thread` |
| 许可 | 无 |
| 实施成本 | 中(需要保证 guided-match 的 pair 内依赖:`match → TVG → guided match → TVG2` 必须保持 pair 内串行,只在 **pair 之间** 流水) |
| 证据强度 | 【源码】PRNG thread_local 是构造性事实;【实测】97/69ms 分账 |

### 4.4 拍摄期增量全局 BA:6 次 × 2.9s = 17.4s 的隐形账

`RESULT` 行:`refine_in_feed_ms=17384.4`、`refine_calls=6`、`publishes=6`。你们的五项分账合计 91.4s,而 `stream_ms=110883` —— **差额基本就是它**。平均 2.9s/次,**单次就击穿 2s 门**。

这不在你给我的表里,所以我不知道你们是否已经在管它。三个观察【实测+源码】:
- 它走 `LiveBaThreads()`(日志里那 5 次 `threads=6`),**已经是多线程**,所以 4.1 那刀对它无效。
- 它是 O(N) 的(全局 BA over live_recon)。
- `MaybeIncrementalGlobalRefine` **默认 OFF**,只有 `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1` 才启用;节奏 `EveryN=25`(热 serious 时减半)、`Window=40`(最近 40 帧自由位姿,更早的冻结成锚)。146 帧 ÷ 25 ≈ 6 次 —— **与日志里的 `refine_calls=6` 逐字吻合,说明这个 fixture run 是把它用 env 打开跑的。**【源码 `official_aether_sfm_c.cc:1476-1502`】
- **所以第一步不是优化它,是先确认出货二进制里到底开没开。** 如果出货是关的,那你们真实的流式总时长应该是 ~93s 而不是 111s,分账里"82%"这个数字本身就要改写;如果开着,它是继 local BA 之后的第二大项,且是唯一单次就爆 2s 门的东西。

### 4.5 **给 Ceres 显式 ordering + 跨帧共享 Context**(详见 §3.3.1)

放在这里再点一次,因为它属于"你们没看到的结构性机会"而不是"求解器选型":
- **没有任何 `SetParameterBlockOrdering` 调用** → Ceres 每次 `Solve()` 都跑一遍近似最大独立集算法。官方 FAQ 的实测是 preprocessor **−5.5×**、总时间 **−23%**。你们每帧 2 次 Solve、每次只十几轮迭代 → 固定开销占比只会更高。
- `ceres::Problem::Options::context` 跨帧复用(线程池不必每帧重建)、`enable_fast_removal`(只有做滑窗增删才有用)。
- 【实测占比未知】必须先做 §3.5 的 FullReport 分段才能定价。

### 4.6 一条零成本的观测性改进

`frame_split` 已经有 `gpu/tvg/tri/lba/tail`,但 **tail 是减出来的**,里面混了 DatabaseCache、ObservationManager、建点循环、preview 快照四样。加三个显式计时器(cache、mapper 构造、preview 快照)就能把 §4.2 的收益变成实测而不是估算。**改动 <20 行,零风险。**

---

## 五、Q4 — 特征提取(手机上才有的那块)

> 前置提醒:host replay 里提取为 0(描述子从 DB 读),所以本节**没有你们自己的实测占比**。你们的 `frame_split` 已经有 `ex[0..8]`(pyr, pack, det, sup, aff, ori, clamp, desc, rb)九段分账,**上机跑一次就有真数据**;下面的排序在拿到那九段之前只是先验。

### 5.1 哪一阶段是瓶颈:有一手论文答案

**PopSift 论文 §6.2**【论文】:高斯金字塔构建通常最耗时,但对给定图像尺寸它是**常数**;随特征数变化的**动态主导项是描述子提取**。
PDF:<https://home.simula.no/~paalh/publications/files/mmsys2018-popsift.pdf> · ACM DL:<https://dl.acm.org/doi/10.1145/3204949.3208136>
(⚠️ simula 站点 TLS 证书链不完整,子代理是 `curl -k` + `pdftotext` 抽的原文。)

**对你们的直接含义**:特征预算被钉死在 8192 → 描述子那部分的"动态"余量比通用场景小;金字塔那部分是固定成本。**所以余量主要在"每个候选/每个特征的常数因子",不在"少算几个特征"。**

### 5.2 我认为**真实存在的无损余量**(三条,按杠杆排)

#### ① 极值候选提前剪枝 + subgroup ballot 压缩 —— ✅ **完全无损**

OpenCV 4.x 在做 26 邻域比较**之前**先过对比度门(<https://github.com/opencv/opencv/blob/4.x/modules/features2d/src/sift.simd.hpp>,SIMD 路径 ~467 行 `v_gt(v_abs(val), threshold)`;标量路径 ~573 行 `if (std::abs(val) <= threshold) continue`)。
**为什么无损**:对比度门本来就是必过条件,先过门再比邻域与先比邻域再过门**结果集完全相同**。
**为什么在 GPU 上收益远大于 CPU**:它把 26-neighbor 的分支/访存从"每像素"降到"每候选像素",并且可以直接配 `subgroupBallot` 做 stream compaction,避免整个 subgroup 为少数候选空转。

**A16 上 subgroups 到底能不能用 —— 有 Dawn 源码级答案**【源码,强】:
`dawn/src/dawn/native/metal/PhysicalDeviceMTL.mm` 里 `EnableFeature(Feature::Subgroups)` 的门是 **`MTLGPUFamilyApple6 || MTLGPUFamilyMac2`**(Apple6 = A13);Apple GPU 上 subgroup size 被**硬编码 min = max = 32**(注释引 M1 tech talk)。**A16 是 Apple family 9,远超门槛,且 subgroup size 恒 32 = CUDA warp 32,PopSift 的 `shfl/ballot/popc` 方案可逐条映射。**
<https://github.com/google/dawn/blob/main/src/dawn/native/metal/PhysicalDeviceMTL.mm>
WGSL 规范(可用内建全表,仅 compute/fragment):<https://github.com/gpuweb/gpuweb/blob/main/proposals/subgroups.md>
Chrome 134 已稳定发布 subgroups:<https://developer.chrome.com/blog/new-in-webgpu-134>

> ⚠️ 那条流传的"iOS GPU 不支持 simdgroup shuffle"来自 **2017 年 Apple 开发者论坛帖(A11 时代)**,**已过时**。Apple 自己的 tech talk 说 A13 引入 quad shuffle、A15 引入 simd shuffle-and-fill(<https://developer.apple.com/videos/play/tech-talks/10876/>),与 Dawn 把门设在 Apple6 一致。

> 🔴 **但 Dawn 源码同时暴露了 subgroups 的真实驱动地雷**,这对你们的跨端约束是强警告:同一文件里有 `CollapseSubgroupMinMax`(默认开,因为嵌套 `subgroupMin/Max` 会**崩 AMD 驱动**,crbug 508265321);Intel Gen-9 上 `subgroupBroadcast(f16)` 边角失败,Dawn **默认在该设备上禁用 Subgroups**(crbug 391680973);还有 `MetalPolyfillTanhF16`、`MetalPolyfillClampFloat`。**这印证了你们 Adreno f16 matcher 崩过不是孤例。任何 subgroups 路径必须带 non-subgroup fallback。**
> Web 端(第四端):WebGPU 本体已在 Safari 26 / iOS 26 默认开(<https://webkit.org/blog/17333/webkit-features-in-safari-26-0/>),但 **subgroups 是 optional feature,未找到 Safari 已实现的证据 → Web 端不要假设可用。**

#### ② 边缘响应判据改**无除法**等价形式 —— ✅ 完全无损,零成本

OpenCV(同文件 ~385 行):
```cpp
if( det <= 0 || tr*tr*edgeThreshold >= (edgeThreshold + 1)*(edgeThreshold + 1)*det ) return false;
```
把 Lowe 原式 `tr²/det < (r+1)²/r` 两边同乘消掉除法,并前置 `det <= 0` 保证不等号方向合法。GPU 上 f32 精确除法比乘法贵得多。**先 grep 你们 WGSL 里是不是已经是这个形式。**

#### ③ 方向分配用 16 线程/keypoint + `shfl/ballot/popc` 映射到 WGSL subgroup

PopSift 一手方案:必须 2ⁿ 线程且 ≤ warp 32,所以**不能**用 36 线程对应 36 个 bin;实测最优是 **16 线程/keypoint**;二级主方向用定制 32-cell bitonic sort。描述子侧 PopSift 有三种并存实现(`loop` 512 线程 / `grid` 256 线程用插值 texture / `notile` 32 线程利用方块重叠只采样一次)。
HartSift(ICPADS'17 / JPDC'19)是同方向更激进版:FFT 高斯卷积 + **warp-based、atomic-free histogram** + 负载再平衡,自称比 SiftGPU 快 5.17–6.88×、比 CudaSift 快 1.25–1.79×。⚠️ 正文在付费墙后,**只拿到摘要,逐阶段数字未核实**。
<https://ieeexplore.ieee.org/document/8368358/> · <https://www.sciencedirect.com/science/article/abs/pii/S0743731518307858>

#### ④ "无损"的可操作判据:**最终描述子已经量化到 uint8**

COLMAP 默认 `Normalization::L1_ROOT`(RootSIFT);OpenCV 的 uint8 路径是 `saturate_cast<uchar>(sqrt(rawDst[k]*nrm1)*SIFT_INT_DESCR_FCTR)`。
→ **无损的验收口径不是中间张量逐位相等,而是量化后的 128 字节逐位相等。** 这给等价重排(改累加顺序、用 FMA、用 subgroup reduce)留出了实打实的浮点空间。
⚠️ `saturate_cast` 含 round-to-nearest,**恰好落在 .5 边界的值对最后 1 ulp 敏感** → "大概率相等"而非构造性相等,**必须用你们现有的 byte-diff harness 实测**。

### 5.3 高斯金字塔:哪些无损、哪些有损(**别再考虑滤波器替换**)

| 手段 | 定性 | 依据 |
|---|---|---|
| 可分离卷积(2D → 两遍 1D) | ✅ **数学等价 = 无损** | G(x,y)=G₁(x)·G₁(y) 是精确因式分解;PopSift 一手确认它 "exploits the separability property" |
| 核对称性复用(先加对称像素对再乘系数) | ✅ 等价,乘法数减半 | PopSift §3 |
| 核宽度截断 | ⚠️ **有损但可控** | PopSift 默认 `ceil(4σ)+1`(保留所有 >1e-8 的项);收窄 = 提速换质量 |
| 递归/IIR 高斯(Deriche、Young-van Vliet) | ❌ **近似 = 有损** | 文献统一称 "fast approximate Gaussian filtering";且 **YvV 两遍无法并行**,GPU 上反而不利 |
| box filter 反复卷积 | ❌ **近似 = 有损** | CLT 逼近,3 次迭代约 3% 误差 |

<https://arxiv.org/pdf/2311.11317>(离散高斯逼近综述) · <https://arxiv.org/pdf/1107.4958>

> ⚠️ **对 DoG 的额外放大风险【推断】**:上面的百分比是对**模糊图本身**说的;SIFT 用的是 **DoG = 相邻两层高斯之差**,是两个接近相等的量相减。3% 的模糊误差在差分后相对误差会被显著放大,直接影响极值位置与亚像素定位。**未找到直接测量 DoG 上误差放大倍数的论文**,但方向明确:对 SIFT 而言 IIR/box 近似比通用模糊场景更危险。

### 5.4 fp16:分层判定

| 用法 | 判定 | 理由 |
|---|---|---|
| 高斯金字塔存 fp16 | ❌ **有损且高风险** | DoG 是经典 catastrophic cancellation;fp16 仅 11 位尾数 |
| 描述子直方图**累加器**用 fp16 | ❌ **有损** | 每 bin 累加数百个加权梯度,误差累积 |
| 高斯核系数 / 梯度权重 LUT 存 fp16、**算 fp32** | ⚠️ 可能可行 | 是乘数不是累加器,单次舍入不累积;需实测 |

叠加驱动层风险(见 5.2 的 Dawn toggles)。**你们 Adreno f16 matcher 崩过属于同一类问题的另一个采样点,不是偶发。**

### 5.5 🔴 `first_octave = 0` —— **四方证据一致指向"这是速度档,不是质量档"**

这是本次调研里**与你陈述冲突最直接的一条**,我只摆证据不下建议:

- **COLMAP 上游默认就是 `-1`**【源码】:`// First octave in the pyramid, i.e. -1 upsamples the image by one level.` / `int first_octave = -1;`(<https://github.com/colmap/colmap/blob/main/src/colmap/feature/sift.h>)。同文件 `max_num_features = 8192`、`octave_resolution = 3`、DSP 参数 `1/6, 3.0, 10`、`normalization = L1_ROOT` —— 这些都与你们一致,**唯独 first_octave 不一致**。
- **VLFeat 文档**:负 index 从更高分辨率图开始、用于提取非常小的特征,并提醒 `"it does not make much sense to go past -1"`(<https://www.vlfeat.org/api/sift.html>)。
- **PopSift 论文**:把 upscale ×2 列为 SIFT 的**第一个标准步骤**,并直言实现通常允许跳过它来 `"sacrifice accuracy for speed"`。
- **Lowe IJCV 2004 §3.3**:主张先双线性 2× 上采样再建金字塔,keypoint 数约 4×。

→ **`-1` 在 VLFeat / COLMAP / Lowe / PopSift 四方一致是质量档,`0` 是速度档。** 你把 `first_octave=0` 记为"为守质量"与上游语义相反。
按你们"参数全抄认证配置('o'),不自创"的铁律,**这条应该走 AskUserQuestion 签决**:要么确认 Mac 'o' 管线本身就是 0(那就无事),要么这是一个未记录的偏离。
⚠️ 搜到过一条 "first_octave=-1 时 mean AP +54%" 的数字,溯源指向专利全文而非同行评审论文,**未能定位一手出处 → 不要引用**。

### 5.6 12MP 输入:**你们其实是在超越 'o' 而不是等同 'o'**

【源码】COLMAP main(4.1.x)把 `max_image_size` 改为 `-1` + `EffMaxImageSize()` 分派:`FeatureExtractorType::SIFT → 3200`;ALIKED → 1600(<https://github.com/colmap/colmap/blob/main/src/colmap/feature/extractor.cc>)。COLMAP 3.8 时代是硬默认 3200。
12MP = 4032×3024 → 官方口径会压到长边 3200,**面积 0.63×**。也就是说上游"认证"的 SIFT 输入本来就不是全 12MP。
⚠️ **未找到任何公开发表的、专门测量"3200 下采样对 SIFT 质量影响"的实验** —— 这个默认值在 COLMAP 里没有引用出处,是工程经验值(与你们之前"参数出处审计"的结论同类)。
按"'o' 是下限不是天花板"的原则,超越是允许的,但**需要受控对照 + 热受控计时来证明,不能默认它无害**。

### 5.7 许可:🔴 一条必须写进常驻结论的纠错

**COLMAP vendored 的 SiftGPU 不是 MIT,是 UNC Chapel Hill 的学术/非营利许可,禁商用。**
原文逐字限定 `"educational, research and non-profit purposes"`,版权 2007 University of North Carolina at Chapel Hill:
<https://github.com/colmap/colmap/blob/main/src/thirdparty/SiftGPU/LICENSE>
COLMAP 官方也主动划清:BSD 只覆盖本体,第三方依赖单独授权(<https://colmap.github.io/license.html>)。
→ **COLMAP 的 `use_gpu = true` SIFT 提取路径走的就是这份非商用代码。你们自研 WGSL 提取器不只是跨端需要,它是唯一合规的出货路径。**
旁证:PopSift 作者在论文引言里写明没有基于 SiftGPU 开发,原因正是 `"our need for a more flexible license"`。

**SIFT 专利已过期**:US6711293B1,权利人 UBC,发明人 David G. Lowe,优先权 1999-03-08,授权 2004-03-23,**到期 2020-03-06,状态 Expired - Lifetime**(<https://patents.google.com/patent/US6711293B1/en>)。OpenCV 因此在 4.3.0 把 SIFT 移回主库。PopSift README 里残留的专利警告是历史遗留。

**CudaSift 是"速度买自算法有损"**:PopSift §5 实证它直接从输入图近似 LoG 且用窄滤波器,图 2 用 Bikes/Bark 的 repeatability / matching score 曲线证明它偏离标准 SIFT,**不能 drop-in 替换**。在你们"参数全抄认证配置"的铁律下直接出局。


---

## 六、有损优化(**需用户签决**,不要和上面混着看)

| # | 方向 | 预计收益 | 为什么有损 | 证据 |
|---|---|---|---|---|
| L1 | `ba_local_function_tolerance` 0 → 1e-6 | local BA −20~30%(≈ 总 −11~17%) | 位级必变;改变停机点。但与 global 已认证的那刀**完全同构**,验收口径可以照抄(±0.003 reproj 噪声带) | 【维护者背书 + global 已认证】 |
| L2 | `ba_local_max_num_iterations` 15 → 8~10 | local BA 线性下降 | 位级必变。仅当 A1 显示"确实烧满 15 轮"才有意义 | 【SLAM 界普遍 5–10 轮】 |
| L3 | `ba_local_max_refinement_change` 0.001 → 0.01 | 部分帧只跑 1 轮而非 2 轮,最多 −50% local BA | 位级必变;直接少做优化 | 【实测:当前从不 break】 |
| L4 | `ba_local_num_images` 6 → 4 | 你们自己的注释:**每帧 max 511→389ms(−24%)**,代价 reproj 1.1455→1.1574(+1.0%) | 明确的质量下降,已被你们记为"仅当设备扛不住 2s 门才用" | 【你们自己的实测,写在代码注释里】 |
| L5 | 第 2 轮 local 精化回归上游的 `TRIVIAL` loss | 第 2 轮显著变便宜 | 你们的 AETHER 注释明确写了保留 CAUCHY 是为了质量(clean orbit 数据上每轮都有用) | 【源码注释】 |
| L6 | `first_octave` 0 → 保持,但**先核对定性**(见 §七) | — | — | — |

**我的建议:L1 先做**(与 global 同构、有维护者背书、验收口径现成),L3/L4 只在设备端确实撞 2s 门时才动,L2/L5 最后。

---

## 七、我查证后发现的、与你陈述相矛盾的事实

> 你说"我宁可被纠正也不要被附和"。以下六条按重要性排。

**C1 —— 「num_threads = min(6, 核数−2) = 4」对 local BA 是**不成立**的。**
你的配置清单写 local BA `num_threads=4`。实测日志是 **`threads=1`,240 次**。原因见 §4.1(流式路径新建的 `IncrementalPipelineOptions` 没继承 mt6000)。**你们一直以为在跑 4 线程的那段,一直是 1 线程。** 【实测,run.log 逐行】

**C2 —— 「其余 tail 14.8s / 16.2%」不是杂项,是唯一的 O(N) 项,而且它会在 300 帧时变成头号成本。**
`tail_ms = −2.3 + 1.429·fid`,R²=0.958。你的分账表把它排在第二位、当成背景噪声看待;实际它是**唯一在长的东西**。【实测】

**C3 —— 「已计入 = 流式总时长的 82%」,剩下的 18% 不是测量误差,是 6 次拍摄期增量全局 BA(17.4s,平均 2.9s/次),而且它默认是关的。**
`RESULT ... stream_ms=110883.1`,`refine_in_feed_ms=17384.4`,`refine_calls=6`。`MaybeIncrementalGlobalRefine` 需要 `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1` 才跑(默认 OFF,EveryN=25 → 146/25≈6 次,逐字吻合)。**结论:你手上这份分账是"增量全局 BA 开着"那条配置的分账。出货配置若是关的,分母该是 ~93s,`local BA` 的占比就不是 56.5% 而是 ~55%,`tail` 是 ~16%。这不改变结论排序,但改变你对"还剩多少没查清"的判断——其实 100% 都查清了。**【实测 + 源码】

**C4 —— `max_linear_solver_iterations=100` 在 local BA 上是死参数。**
DENSE_SCHUR 是直接解,不迭代;该选项只作用于 ITERATIVE_SCHUR/CGNR。【源码】

**C5 —— 「`function_tolerance=0` 即关闭了收敛判据」只对了一半。**
函数值与参数判据确实被完全关闭,但 `gradient_tolerance=10.0`(Ceres 默认的 10¹¹ 倍)是**被刻意抬起来接管停机的主判据**,不是"异常大的值"忘了改。同时:**第 0 轮永远不可能触发它**(`step_is_successful=false`),所以每次 `Solve()` 至少一次完整线性求解。【源码,构造性】

**C6 —— `ba_local_num_images` 在你们仓库里有两个不同的值。**
生产流式路径(`official_aether_sfm_c.cc`)= **6**(与你陈述一致 ✅);但批处理/finalize 路径(`aether_sfm_c.cc` `RunIncremental`)= **10**,注释写"lnum=10: better preview (0.936→0.86) + lower drift"。这两条路的窗口大小不同是**有意还是漂移**,值得确认一下。【源码】

**C8 —— 「`first_octave=0`(为守质量)」与上游语义相反:四方一致把 `-1` 当质量档、`0` 当速度档。**
COLMAP 上游 `sift.h` 默认就是 `first_octave = -1`,注释逐字 "-1 upsamples the image by one level";VLFeat 文档、Lowe IJCV 2004 §3.3、PopSift 论文("sacrifice accuracy for speed")全部同向。详见 §5.5。**建议按铁律走签决,而不是我替你们改。**【源码 + 论文】

**C9 —— 「12MP 全分辨率喂 SIFT」不是"抄认证配置",是超越它。**
COLMAP 的 SIFT 默认 `max_image_size = 3200`(4.1.x 里由 `EffMaxImageSize()` 分派),12MP 会被压到面积 0.63×。超越是被你们自己的"'o' 是下限不是天花板"允许的,但**需要受控对照证明,不能默认无害**。详见 §5.6。【源码】

**C10 —— 「Ceres 底层在 Mac 上本就走 Accelerate」这句对 local BA 不成立。**
你们 local BA 日志逐行是 `dense_backend=EIGEN`,不是 LAPACK/Accelerate。而且 Ceres **官方 iOS 工具链主动 `update_cache_variable(LAPACK OFF)`**。Accelerate 只在你们显式 `AETHER_DENSE_LAPACK` / finalize 那条 180 图以上的分层里才进场。详见 §3.3.2 / §3.3.4。【实测日志 + Ceres CMake 源码】

**C7(版本)—— 上游已发 4.1.1,你们 vendored 的是 4.1.0。**
4.1.1 的修复里有一条 **"Fix feature matching slowdown (~4-6x) caused by a process-global OpenMP critical section in RANSAC/LORANSAC"**([PR #4553](https://github.com/colmap/colmap/pull/4553))。**我核实过:这条对你们无效** —— 你们的 `optim/ransac.h:304` / `loransac.h:211,282` 确实还带着那个 unnamed `#pragma omp critical`,但你们的 CMake **从不给 `glomap_core` 加 `-fopenmp`**(注释:"OpenMP (<omp.h>), which the iOS toolchain lacks"),所以该 pragma 被编译器整体忽略。**结论:不用升级,但如果将来有人打开 OpenMP,必须同时拿 #4553。**同理,PR #4169 给 RANSAC 加的多线程你们也吃不到 —— 这反过来支持 §4.3 用 `std::thread` 自己做 pair 级流水。【源码 + 一手 PR】

---

## 八、许可判定(逐个读过 LICENSE 原文)

BA 加速方案的许可全表在 **§3.2**;特征提取侧的在 **§5.7**。以下是**你们出货二进制里实际链接的那几个**:

| 组件 | 许可 | 商用 | LICENSE 原文 URL |
|---|---|---|---|
| COLMAP 本体 | "new BSD"(BSD-3-Clause),版权 ETH Zurich + UNC Chapel Hill;原文明确 **"refers only to the license for COLMAP itself, independent of its dependencies"** | ✅ | <https://github.com/colmap/colmap/blob/main/COPYING.txt>(⚠️ 文件名是 `COPYING.txt` 不是 `LICENSE`) · 官方说明 <https://colmap.github.io/license.html> |
| Ceres Solver | 新 BSD-3(部分文件 Apache-2.0) | ✅ | <https://github.com/ceres-solver/ceres-solver/blob/master/LICENSE> |
| Eigen(MPL2 子集) | MPL-2.0(你们已 `EIGEN_MPL2_ONLY`) | ✅ | <https://gitlab.com/libeigen/eigen/-/blob/master/COPYING.MPL2> |
| glog | BSD-3-Clause | ✅ | <https://github.com/google/glog/blob/master/COPYING> |
| **COLMAP vendored SiftGPU** | **UNC Chapel Hill 学术/非营利,禁商用** | ❌ | <https://github.com/colmap/colmap/blob/main/src/thirdparty/SiftGPU/LICENSE> |
| **CASPAR(COLMAP 4.1 GPU BA)** | 随 COLMAP,但 **CUDA-only** | ⛔ 技术上不可用 | <https://github.com/colmap/colmap/releases>(4.1.0/4.1.1 notes) |
| SuiteSparse/CHOLMOD | GPL/LGPL 混合(CHOLMOD supernodal 是 GPL) | ❌ | 你们代码里已标注"iOS would NOT ship this (GPL-adjacent CHOLMOD)" |
| VLFeat(你们 vendored) | BSD-2-Clause | ✅ | <https://www.vlfeat.org/license.html> |
| **SIFT 算法专利 US6711293B1** | **已到期 2020-03-06,Expired - Lifetime** | ✅ 无风险 | <https://patents.google.com/patent/US6711293B1/en> |

---

## 九、我查证后判定为**死路**的方向(和建议同样重要)

| # | 方向 | 理由 | 出处 |
|---|---|---|---|
| D1 | **COLMAP CASPAR backend** | CUDA-only,4.1.1 明确"CUDA architectures below 7.0"直接编译失败;移动端不存在路径 | [releases](https://github.com/colmap/colmap/releases) |
| D2 | **升级到 4.1.1 以拿 RANSAC OpenMP 修复** | 你们根本没开 `-fopenmp`,该 pragma 被忽略,收益为 0 | 【源码:vendored CMakeLists 无 `-fopenmp`;`optim/ransac.h:253,304`】 |
| D3 | **`max_linear_solver_iterations` 调优** | DENSE_SCHUR 路由下是死参数 | 【源码】 |
| D4 | **Ceres 复用符号分解 / warm-start 线性求解器** | DENSE_SCHUR 不做符号分解,无可复用物;Ceres 也没有公开 API | 【源码 + 文档】 |
| D5 | **"证明这一帧不需要 BA 所以跳过"** | 构造性不可能:判据本身需要先解一遍。所有替代品都是质量换速度 | 【推断,但是构造性论证】 |
| D6 | **关键帧稀释 local BA 频率** | 你们每帧 = 用户主动按快门 = 天然关键帧;稀释等于丢用户的照片 | 【产品约束】 |
| D7 | **把 TVG 拆成多线程并行做 pair** | COLMAP PRNG 是 `thread_local`,并行必然改变 RANSAC 采样序列 → 位级必变。要重叠只能用**单条专用 TVG 线程**(§4.3) | 【源码 `math/random.h:41`】 |

| D8 | **MegBA / Graphite / TurboMap / InstantSfM / BAE / DeepLM / DABA** | 全部 CUDA 或 Python-only;手机上构造性不存在。DeepLM 与 PBA 另有 **GPL-3.0**,连抄都不行 | §3.2 表 |
| D9 | **PoBA / RootBA / STBA 的"加速"部分** | 目标规模 ≥49 相机(BAL 最小样本);6 相机的 RCS 只有 36–54 维,没有可加速的对象 | [BAL Ladybug](https://grail.cs.washington.edu/projects/bal/ladybug.html) |
| D10 | **Ceres 的 GPU 后端(CUDA dense / CUDA_SPARSE / cuDSS)** | 只有 CUDA;`CUDA_SPARSE` 在 2.2.0 里连工厂实现都没有;**Metal/Vulkan/OpenCL/SYCL 一个都没有** | [issue #760](https://github.com/ceres-solver/ceres-solver/issues/760) |
| D11 | **移动 GPU / Dawn / WGSL 做 BA 线性求解** | 三重构造性障碍,见 §3.4:唯一 fp64 Vulkan 先例在同量级 local BA 上只拿 14–20% 且**线性求解那一步零收益**;Metal/WGSL 无 f64,常规 Schur + f32 有论文记录"数值失败";54 维问题比一次 dispatch 开销还小 | [SFU 2023](https://summit.sfu.ca/_flysystem/fedora/2023-06/etd22484.pdf) · [arXiv 2109.02182](https://arxiv.org/abs/2109.02182) · [arXiv 2604.02344](https://arxiv.org/abs/2604.02344) |
| D12 | **`use_explicit_schur_complement` / `use_inner_iterations` / NESDIS ordering** | DENSE_SCHUR 下语义不适用,代码路径根本不读 | 【Ceres 源码/文档】 |
| D13 | **local BA 的 dense 后端 EIGEN → LAPACK(Accelerate/AMX)** | 小矩阵 BLAS 调用开销主导;Ceres **官方 iOS 工具链主动关闭 LAPACK**。(与你们 finalize 段 180 图以上那条分层不是一回事) | [Ceres CMakeLists](https://github.com/ceres-solver/ceres-solver/blob/master/CMakeLists.txt) · [博客实测](https://dev.to/frosnerd/comparing-openblas-and-accelerate-on-apple-silicon-for-blas-routines-2pb9) |
| D14 | **任何形式复用 SiftGPU(含 COLMAP vendored 版)** | UNC 非商用学术许可,原文逐字核实 → **COLMAP 官方 GPU SIFT 路径本身即污染源** | [LICENSE](https://github.com/colmap/colmap/blob/main/src/thirdparty/SiftGPU/LICENSE) |
| D15 | **递归/IIR 高斯、box-filter 近似、CudaSift 的窄滤波器** | 全是近似不是等价变换;DoG 差分还会放大误差;CudaSift 已被 PopSift 用 repeatability 曲线实证偏离标准 SIFT | [PopSift PDF](https://home.simula.no/~paalh/publications/files/mmsys2018-popsift.pdf) |
| D16 | **fp16 存高斯金字塔 / fp16 累加描述子直方图** | catastrophic cancellation + 累加误差;叠加各家驱动 f16 边角不一致(Dawn 里多个 polyfill toggle 为证) | [Dawn PhysicalDeviceMTL.mm](https://github.com/google/dawn/blob/main/src/dawn/native/metal/PhysicalDeviceMTL.mm) |
| D17 | **把 subgroups 做成唯一路径(无 fallback)** | A16 上 Dawn 确实开(Apple6 门槛、size 恒 32),但 AMD 嵌套 subgroupMin/Max 崩、Intel Gen-9 默认禁用、Safari 支持未证实 | 同上 |
| D18 | **SuperPoint 权重(任何形式)** | Magic Leap **非商用**;用 LightGlue 时尤其要盯 —— 它默认配 SuperPoint。ALIKED + LightGlue 是唯一全 permissive 组合 | <https://huggingface.co/magic-leap-community/superpoint/blob/main/LICENSE> |

---

## 十、建议实施顺序(最高杠杆 × 最低风险)

| 序 | 动作 | 预计收益 | 风险 | 成本 |
|---|---|---|---|---|
| **1** | **§4.1 local BA 补 `ba_min_num_residuals_for_cpu_multi_threading=6000` + `num_threads=LiveBaThreads()`** | **−14~27%** | 低(有 T4/T6 byte-identical 先例,但需对 local BA 重验) | 2 行 |
| **2** | **仪表三件套(零风险,决定后面全部)**:① §3.5 `Solver::Summary::FullReport()` 拆 Preprocessor/Jacobian/Linear-solver;② §1.4-A1 termination_type / iterations / gradient_max_norm;③ §4.6 tail 三段拆分(cache / mapper 构造 / preview 快照) | 0(但 3–7 的取舍全靠它) | 零 | ~2h |
| **2.5** | **§3.3.1 显式 `linear_solver_ordering`**(3D 点→group 0,相机→group 1)。Ceres 官方自带 preprocessor −5.5× / 总时间 −23% 的实测,你们完全没做 | 视 FullReport 里 preprocessor 占比;官方例子 −23% | 低(需 byte-diff) | ~2h |
| **3** | **§4.2 持久 DatabaseCache / IncrementalMapper**(用上游 #4279 的增量 API) | 现在 −9~13%,300 帧 −60s,并压平 O(N) | 中(需 byte-diff parity) | 1–2 天 |
| **4** | **§4.4 先确认拍摄期增量全局 BA 是否出货开启**;开着就单独立项(17.4s / 6 次 / 2.9s 单次爆门) | 潜在 −16% | 低(先只是量) | ~2h |
| **5** | **§4.3 专用 TVG 线程与 GPU 匹配流水** | −6~9%,位级可一致 | 中(pair 内依赖 + 单线程约束) | 1 天 |
| **6** | **§六 L1**(local ftol 1e-6,与 global 同构)—— **需签决** | −11~17% | 有损,需噪声带验收 | 半天 A/B |
| 7 | **§5.2 特征提取的三条无损项**(极值候选提前剪枝 + subgroup ballot 压缩、边缘判据去除法、方向分配 16 线程/keypoint) | 未知(先看 `ex[0..8]` 九段真机分账) | 低-中(必须带 non-subgroup fallback) | 中 |
| — | **需签决(不排序)**:§5.5 `first_octave` 定性复核、§3.6 SymForce C++ codegen 替 AutoDiff、§六 全部有损项 | — | — | — |

> 前 5 项**全部是无损或位级可验证**的,叠加上界约 **−35~50%**(有重叠,不能简单相加)。第 6 项才开始动质量。

---

## 十一、来源索引

**COLMAP**:[issue #2703(ftol=0 的官方答复)](https://github.com/colmap/colmap/issues/2703) · [issue #4446](https://github.com/colmap/colmap/issues/4446) · [PR #4279(增量 CorrespondenceGraph/ObservationManager)](https://github.com/colmap/colmap/pull/4279) · [PR #4281](https://github.com/colmap/colmap/pull/4281) · [PR #4553(RANSAC omp critical)](https://github.com/colmap/colmap/pull/4553) · [issue #4482](https://github.com/colmap/colmap/issues/4482) · [PR #4169](https://github.com/colmap/colmap/pull/4169) · [releases 4.1.0/4.1.1](https://github.com/colmap/colmap/releases) · [FAQ(Speedup bundle adjustment 一节)](https://colmap.github.io/faq.html) · [license](https://colmap.github.io/license.html) · [参数表(社区)](https://github.com/mwtarnowski/colmap-parameters)

**Ceres**:[trust_region_minimizer.cc](https://github.com/ceres-solver/ceres-solver/blob/master/internal/ceres/trust_region_minimizer.cc) · [nnls_solving.rst](https://github.com/ceres-solver/ceres-solver/blob/master/docs/source/nnls_solving.rst) · [version_history.rst](https://github.com/ceres-solver/ceres-solver/blob/master/docs/source/version_history.rst) · [LICENSE](https://github.com/ceres-solver/ceres-solver/blob/master/LICENSE)

**学术/SLAM**:[ORB-SLAM2 Optimizer.cc](https://github.com/raulmur/ORB_SLAM2/blob/master/src/Optimizer.cc) · [Engels/Nistér, Bundle Adjustment Rules](https://www.isprs.org/proceedings/xxxvi/part3/singlepapers/O_24.pdf) · [Schönberger & Frahm CVPR16](https://demuc.de/papers/schoenberger2016sfm.pdf)

**BA 加速**:[BAL Ladybug 数据集规模](https://grail.cs.washington.edu/projects/bal/ladybug.html) · [PoBA arXiv:2204.12834](https://arxiv.org/abs/2204.12834) · [RootBA arXiv:2103.01843](https://arxiv.org/abs/2103.01843) · [Square Root Marginalization arXiv:2109.02182](https://arxiv.org/abs/2109.02182) · [Caspar arXiv:2605.30583](https://arxiv.org/abs/2605.30583) · [MegBA](https://github.com/MegviiRobot/MegBA/blob/main/LICENSE) · [DeepLM(GPL)](https://github.com/hjwdzh/DeepLM/blob/main/LICENSE) · [STBA](https://github.com/zlthinker/STBA/blob/master/LICENSE) · [GTSAM](https://github.com/borglab/gtsam/blob/develop/LICENSE) · [SymForce](https://github.com/symforce-org/symforce/blob/main/LICENSE) · [Theseus](https://github.com/facebookresearch/theseus/blob/main/LICENSE) · [Graphite](https://github.com/sfu-rsl/graphite/blob/master/LICENSE.md) · [TurboMap](https://github.com/sfu-rsl/TurboMap/blob/main/LICENSE)

**移动 GPU BA**:[SFU 2023 硕士论文(Vulkan Schur 补,唯一先例)](https://summit.sfu.ca/_flysystem/fedora/2023-06/etd22484.pdf) · [WebGPU dispatch overhead arXiv:2604.02344](https://arxiv.org/abs/2604.02344) · [metal-float64(已归档)](https://github.com/philipturner/metal-float64) · [WGSL f64 open issue](https://github.com/gpuweb/gpuweb/issues/2805) · [Ceres GPU 后端诉求 #760](https://github.com/ceres-solver/ceres-solver/issues/760)

**特征提取**:[PopSift 论文 PDF](https://home.simula.no/~paalh/publications/files/mmsys2018-popsift.pdf) · [OpenCV sift.simd.hpp](https://github.com/opencv/opencv/blob/4.x/modules/features2d/src/sift.simd.hpp) · [COLMAP sift.h(first_octave=-1)](https://github.com/colmap/colmap/blob/main/src/colmap/feature/sift.h) · [COLMAP extractor.cc(max_image_size 分派)](https://github.com/colmap/colmap/blob/main/src/colmap/feature/extractor.cc) · [VLFeat SIFT 文档](https://www.vlfeat.org/api/sift.html) · [WGSL subgroups 提案](https://github.com/gpuweb/gpuweb/blob/main/proposals/subgroups.md) · [Dawn Metal subgroups 门槛](https://github.com/google/dawn/blob/main/src/dawn/native/metal/PhysicalDeviceMTL.mm) · [Chrome 134 subgroups](https://developer.chrome.com/blog/new-in-webgpu-134) · [Apple tech talk 10876](https://developer.apple.com/videos/play/tech-talks/10876/) · [US6711293B1](https://patents.google.com/patent/US6711293B1/en)

**许可**:[COLMAP COPYING.txt](https://github.com/colmap/colmap/blob/main/COPYING.txt) · [COLMAP 官方 license 说明](https://colmap.github.io/license.html) · [COLMAP vendored SiftGPU LICENSE(非商用)](https://github.com/colmap/colmap/blob/main/src/thirdparty/SiftGPU/LICENSE) · [SuperPoint LICENSE(非商用)](https://huggingface.co/magic-leap-community/superpoint/blob/main/LICENSE) · [XFeat](https://github.com/verlab/accelerated_features/blob/main/LICENSE) · [ALIKED](https://github.com/Shiaoming/ALIKED/blob/main/LICENSE) · [LightGlue](https://github.com/cvg/LightGlue/blob/main/LICENSE) · [VLFeat](https://www.vlfeat.org/license.html)

**我方实测数据源**:`_host_fixtures/spatial_cand_exp/runs/cap7_day_A/{sfm_match_fail.jsonl, run.log}`(146 帧);`_host_fixtures/prepay_threads_exact/`(T4/T6 byte-identical 先例)
**我方源码**:`aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`(生产流式);`aether_cpp/third_party/glomap_vendor/`(vendored COLMAP 4.1.0 + CMake);`aether_cpp/third_party/ceres/`(Ceres 2.2.0)
