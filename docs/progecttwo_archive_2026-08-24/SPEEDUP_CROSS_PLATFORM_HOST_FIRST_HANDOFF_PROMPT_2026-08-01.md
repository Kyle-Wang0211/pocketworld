# PocketWorld / Aether3D 跨端且不降质量的主机优先提速：极详细执行提示词

> 版本：2026-08-01 v1  
> 当前阶段：只做 Mac 主机代码分析、上游调查、严格 A/B 和性能实现  
> 硬门：**电脑上没有在同机、同输入、同完整语义下超过原生 Metal，就不允许考虑安装手机。**

---

## 0. 你的角色与唯一目标

你是 PocketWorld / Aether3D 生产 SfM 管线的资深 C++、GPU、移动端和三维重建性能工程师。继续现有工作时，不要再把时间花在泛泛的“跨端框架搭建”、手机反复安装或不公平微基准上。

唯一主目标是：

> 在不降低特征、匹配、几何验证和最终点云质量的前提下，让生产管线明显变快；尽可能共享 C++ 语义与调度以服务未来 iOS、Android、鸿蒙，但不能为了源码统一而让当前 iOS 热核变慢。

当前最快的预期架构仍然是 **CPU + GPU 混合**：

- 共享 C++：语义、阈值、数据布局、调度、数据库、缓存、几何验证、BA、日志、实验合同；
- Apple 热核：保留实测最快、输出 exact 的 Metal；
- 未来 Android/鸿蒙：按设备能力选择 Vulkan、Dawn 或 CPU SIMD；
- 后端可替换，但不要求所有平台强制使用同一份 WGSL shader。

不要只自研。优先检查 COLMAP、GLOMAP、LightGlue、ALIKED、XFeat、Faiss、Google Highway、Dawn/Vulkan 等上游方案，并用本地同输入实验验证。

---

## 1. 用户不可违背的要求

1. 绝对不能通过减少质量换速度。
2. 不得限制用户拍什么物体、什么光照、什么纹理。
3. 若新算法会改变特征或匹配集合，不要先验认定一定更差；可以单独生成两份 PLY，让用户肉眼比较，并结合指标判断。
4. 但会改变集合的方案不能冒充“零质量损失的等价提速”。
5. 必须联网调查成熟官方和开源方案，不得只继续写自研 kernel。
6. 现在不要构建、签名、安装、更新或卸载手机 App。
7. 主机 portable 完整 workload 没超过 native，就不允许上手机。
8. Android 和鸿蒙目前不用做产品实现，也不用过早搭完整工程；只保留合理的共享层和后端边界。
9. 跨端本身对未来有价值，但不是强制去掉 Metal。
10. 不要触碰点云编辑页、立方体、快门、压缩调度、UI 或其他 agent 的代码。
11. 不要清理共享脏工作树，不要 reset、clean、stash、checkout 或 stage-all。

---

## 2. 两条实验车道必须分开

### Lane E：exact / 零质量损失

允许改变：

- 内存驻留和缓存生命周期；
- 锁粒度、线程调度、阶段重叠；
- CPU SIMD、GPU tile、融合和读回实现；
- 不改变结果的并行化；
- 上游等价 bugfix；
- 复用已经计算的相同数据。

不允许改变：

- feature set 或顺序；
- descriptor 数值；
- ratio test 数学定义；
- absolute threshold；
- mutual cross-check；
- ordered match pairs；
- two-view geometry 语义；
- local BA 成员或 tie-break；
- 重力/尺度/最终对齐语义；
- deterministic DB/PLY。

任何语义差异都把候选从 Lane E 驳回。

### Lane Q：允许质量变化的 Pareto 研究

包括 XFeat、ALIKED、LightGlue、GLOMAP/global mapper、approximate NN、canonical exact-8192 替换 legacy 组截断等。

每个 Lane Q arm 必须报告：

- control 和 candidate 两份 PLY；
- 注册图像数；
- 点数、tracks、平均 track length；
- reprojection error；
- 覆盖率和完整性；
- 失败率/闪退率；
- 完整耗时；
- 模型、权重、许可证和硬件后端。

Lane Q 可能获得更好的点云，但不能称为 byte-exact 优化。

---

## 3. 仓库、身份和边界

### 算法仓库

```text
/Users/kaidongwang/Developer/Aether3D-cross
branch = claude/publish-to-community
observed HEAD = b930ab185135dfbd172aef7c2bbeed67ef315f75
```

工作树非常脏。观察到的 HEAD 不代表所有源码。每次实验都必须记录 dirty diff/hash；不得把用户或其他 agent 的改动清掉。

### 产品仓库

```text
/Users/kaidongwang/Developer/pocketworld
```

本阶段只读，不构建、不修改、不安装。生产 framework 路径仅供理解：

```text
/Users/kaidongwang/Developer/pocketworld/vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework
```

观察到的产品二进制身份：

```text
core archive:
1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04

GPU extract archive:
565f267ebaec5a4386bea3e5df6cffd518fbfe7388874ad7c9af67350551c370

framework device binary:
2770bc0ce76a2c96016d8b4703bab7a9590d680489356d09c85247500279cc7b
```

### Dawn

```text
pinned revision = 12ee391c7411285895f4289a3d889a182c093014
```

不得为了实验升级 Dawn 或下载另一套依赖。

### 当前 source identity 风险

`aether_cpp/official_pipeline/src/official_aether_sfm_c.cc` 当前是未跟踪文件，当前研究 core 混有多个变化。产品 `verify_source_parity.py` 目前存在 endpoint source identity 失败。因此当前 core 不能作为“仅 tail cache 的单变量产品候选”。本阶段不晋升产品，只做主机实验。

---

## 4. 必读文档位置

### 原完整计划

```text
/Users/kaidongwang/Documents/progecttwo/SPEEDUP_FULL_HANDOFF_PROMPT_2026-07-29.md
```

### OpenSpec 根目录

```text
/Users/kaidongwang/Developer/Aether3D-cross/openspec/changes/portable-sfm-speedup-v1/
```

关键文件：

```text
README.md
proposal.md
design.md
experiment-contract.md
tasks.md
specs/descriptor-residency-v1/spec.md
specs/tail-cache-first-v1/spec.md
specs/portable-canonical-selector/spec.md
specs/portable-frontend-pareto-benchmark/spec.md
specs/phase0-measurement-contract/spec.md
specs/portable-sfm-rollout-gates/spec.md
```

### 本轮最新权威证据

```text
/Users/kaidongwang/Developer/Aether3D-cross/openspec/changes/portable-sfm-speedup-v1/evidence/host-first-open-source-speed-screen-2026-08-01.md
```

这是 603 行完整证据，包含：

- 禁止手机的当前边界；
- native/portable 公平基准合同；
- 本地实验明细和哈希；
- 当前 WGSL 候选的语义缺口；
- 开源调查和许可证/平台限制；
- 下一步优先级和停止条件。

其他历史证据：

```text
openspec/changes/portable-sfm-speedup-v1/evidence/shared-carrier-regression-amplification-2026-07-30.md
openspec/changes/portable-sfm-speedup-v1/evidence/portable-canonical-selector-vertical-slice-2026-07-31.md
openspec/changes/portable-sfm-speedup-v1/evidence/p2-device-probe-prebuild-2026-07-30.md
openspec/changes/portable-sfm-speedup-v1/evidence/p3a1-algorithm-carrier-2026-07-30.md
```

P2/P3 手机门属于历史，本轮不执行。

---

## 5. 生产管线与跨端现状

`official` 是产品入口/所有权命名，不等于上游原版算法。历史 parity 脚本曾明确写：

```text
Prove that the native official route is the frozen self-route source copy.
may differ only in ownership names.
```

生产路线混合了：

- COLMAP/GLOMAP/Ceres/Eigen 上游组件；
- 自定义 affine/DSP SIFT GPU 提取；
- 自定义 Metal matcher；
- K12 调度、流式重建、local BA、tail/cache、对齐和产品封装。

已经适合共享的部分：

- C/C++ ABI；
- 数据结构和阈值语义；
- feature/match deterministic contract；
- DB、cache、tail dirty epoch；
- scheduler/backpressure；
- 几何验证和 BA 的大部分 C++；
- host replay harness；
- contract tests 和 telemetry schema。

不应强制统一的部分：

- Apple 最热 matcher Metal kernel；
- 设备能力相关 subgroup matrix/integer dot kernel；
- 未来 Vulkan backend 和具体 GPU 同步。

准确结论：共享框架已有相当一部分，但 portable GPU hot kernel 尚未在 Apple 主机上达到原生速度和完整语义，不能取代 Metal。

---

## 6. 已完成实验与真实结论

### 6.1 生产 Metal v2 matcher

源码：

```text
aether_cpp/official_pipeline/src/official_gpu_match.mm
SHA-256 = 6b428cf1720be773bd1923748e2d7311a59e20424c15e703d0f6892d1757aa1d
```

生产语义：

1. uint8 × 128 SIFT descriptors；
2. A→B nearest/second-nearest；
3. B→A nearest/second-nearest；
4. `acos` angular distance；
5. Lowe ratio；
6. absolute threshold；
7. mutual cross-check；
8. deterministic ordered pair emission。

源文件记录 402 个 K12 fixture pair 上 256,418/256,418 ordered matches 一致。它是 exact native reference。

M3 Pro 两张真实 8192-row table 诊断约 5.2–5.9 ms。按 N² 外推到 11568 rows 约 10–12 ms，但这只是估计，不可作为最终比较。

### 6.2 旧 Dawn/WGSL

```text
source = aether_cpp/tools/aether_dawn_descriptor_matcher_bench.cpp
SHA-256 = 84cd41768936aa5a8aaa5d429f88d742e1eb59005a741f899299e9799c1e5015
```

M3 诊断：

```text
naive   330.657 ms
tiled   287.650 ms
blocked 241.586 ms
```

### 6.3 新 subgroup-matrix / packed-u8 WGSL

```text
source = aether_cpp/experiments/portable_frontend_pareto/tools/subgroup_matrix_matcher_bench.cpp
SHA-256 = b8f8576c91b6df8d540384fa187e60966f15c58a93d661082d8857e924f0a40c
rows = 11568
dimensions = 128
```

M3 诊断：

```text
f32 subgroup matrix p50 ≈ 79.7–80.8 ms
packed-u8 dot4 p50      = 77.8978 ms
```

它相对旧 generic blocked 约快 3.1×，但不能进生产，因为：

- 使用 dot score 上简化的 `best > ratioSq * second`；
- 没有 production angular `acos` ratio；
- 没有 production absolute threshold；
- 两个方向虽都 dispatch，但没有 mutual intersection；
- 没有最终 ordered pair compaction/readback；
- 没有与 Metal 输出做 byte digest。

因此：

- 当前生产 App 质量没有被它降低，因为它没有安装；
- 候选若直接部署会改变 match set，不能保证质量；
- 它必须保持关闭，先补完整语义再比较。

### 6.4 为什么 generic 慢

1. Metal v2 融合两方向，当前 WGSL 两次 dispatch；
2. Metal 保持 packed uint8；f32 matrix 带宽是 4 倍；
3. M3 Dawn 只暴露 f32/f16 8×8×8 subgroup matrix，没有 u8 matrix；
4. `dot4U8Packed` 在 Metal backend 是 polyfill；
5. Metal 针对 32-wide simdgroup/tile 手调；
6. Dawn abstraction 有额外开销，但 kernel formulation 和硬件映射是主因；
7. WGSL 尚未做完整 ratio/mutual/readback，补齐只会增加时间。

本地 Dawn probe：

```text
Apple M3 Pro
subgroup size 32..32
subgroup matrix available
f32→f32 8×8×8
f16→f16 8×8×8
no u8 matrix config
```

### 6.5 Descriptor Residency

合同命令：

```bash
cd /Users/kaidongwang/Developer/Aether3D-cross
bash aether_cpp/tests/sfm/test_portable_speed_arms_v1_contract.sh
```

已通过 descriptor residency、tail cache、总合同。

Objective-C++ compile object：

```text
2348e15bb8a322e5a867e98d2024d0414d85677f2a53d8fae8358b77810e4f48
```

smoke：127 real mutual matches exact，hits=2，misses=2，upload=49152，eviction/failure=0。

M3 real-8192 baseline/resident：

```text
5.947 / 5.230
4.958 / 5.250
5.288 / 5.510
5.197 / 5.888
5.294 / 5.217 ms
```

方向反复翻转，总体打平。结论：default-off；只有真实 batch 证明 table 多次复用才重测。

### 6.6 Tail cache / dirty epoch

artifact：

```text
/private/tmp/aether-tail-determinism4.xNfWOW
```

时间：

```text
off_a 39393.1 ms
off_b 39580.4 ms
on    39553.0 ms
```

exact：registered=4、points=3145、reprojection=0.7760、track=2.231、final cloud=2915。

```text
PLY SHA-256:
b1f12260e519517d8ec80327a4a440707a82b59bded625e0595f9b708bbe801b

session.db SHA-256:
e582943a37ca01cdac1b762620a2d7dcbd41c77991ad9ba366194801feeba227

local bundle trace SHA-256:
1a0a2ab6c8d11d99903e85015b0f004d1d34b09c18937ac3324ba8741c98610c
```

结论：4 帧只证明 exact，没有 speed win。应在 146 帧或最长 fixture、优先 already-matched DB 上测。

### 6.7 Local BA threads

`official_aether_sfm_c.cc` 约 6968–6969 行记录：

```text
34.9 s → 26.4 s，约 -26.2%，byte-identical
```

已 ship，不能再次认领未来预算。

### 6.8 overlap

当前已有 extraction/matching prefetch 和 finalization overlap。新 overlap 必须指明当前不存在的 DAG 边，并证明 thread-local PRNG、guided-match order 和 deterministic output 不变。泛泛“做 overlap”没有预算。

### 6.9 canonical exact-8192

legacy group rule 会由 8192 冲到 16570；exact-8192 会改变 feature set。它对未来确定性有价值，但属于 Lane Q，当前已从生产撤下并保持关闭。

### 6.10 XFeat frozen arm

```text
/private/tmp/aether-xfeat-full-1600-8192-cos090-20260801-a/visual_pair/compare.html
```

| 指标 | XFeat | Control |
|---|---:|---:|
| tracks | 58,776 | 65,751 |
| reprojection | 1.571 | 1.4899 |
| reconstruction | 104.75 s | 52.70 s |

用户肉眼认为两份 PLY 都可接受，但该候选慢约 2×且数值更弱。只淘汰此固定配置。

### 6.11 52.70 s 的含义

这是 Mac 上对已经提取/匹配 DB 做 GLOMAP 重建的时间，不是 iPhone 端到端，也不是 Apple-only。GLOMAP 改重建算法，属于 Lane Q。

---

## 7. 联网调查结果

### 7.1 COLMAP 4.1.1 RANSAC/LORANSAC lock fix——第一优先

官方：<https://colmap.github.io/changelog.html>

上游修复了 process-global OpenMP critical section 导致的约 4–6× feature-matching slowdown。

本地 vendored 4.1.0 已存在对应未提交补丁：

```text
aether_cpp/third_party/glomap_vendor/colmap-src/colmap/optim/ransac.h
aether_cpp/third_party/glomap_vendor/colmap-src/colmap/optim/loransac.h
```

当前 diff：

- 每个 `Estimate()` 自己一个 `std::mutex`；
- 去掉 process-global `#pragma omp critical`；
- 仅该调用内部 `num_threads>1` 时 lock；
- 外层多个单线程 RANSAC 不再争全进程一把锁。

它不换 estimator、residual、model、threshold、support measure，属于最有希望的 Lane E 上游候选。但本地尚未 A/B，因此当前 speed credit=0，不能把上游 4–6×写成产品收益。

### 7.2 COLMAP Caspar GPU BA

同一官方 changelog 称合适场景可比 Ceres CUDA 快 1–2 个数量级。但它依赖 NVIDIA CUDA，M3/iPhone 不可用。当前移动主线不采用。

### 7.3 COLMAP learned feature/matcher

官方：<https://colmap.github.io/features.html>

COLMAP 支持 ALIKED via ONNX、SIFT_LIGHTGLUE、ALIKED_LIGHTGLUE。属于成熟上游入口，但会改变 feature/match，放 Lane Q。

### 7.4 LightGlue

仓库：<https://github.com/cvg/LightGlue>  
论文：<https://openaccess.thecvf.com/content/ICCV2023/papers/Lindenberger_LightGlue_Local_Feature_Matching_at_Light_Speed_ICCV_2023_paper.pdf>

自适应 depth/width，支持 SIFT、SuperPoint、DISK、ALIKED。输出会改变。LightGlue code/weights 为 Apache-2.0，但 SuperPoint 权重有限制，ALIKED 是 BSD。未来可测 SIFT+LightGlue 和 ALIKED+LightGlue，不是 exact drop-in。

### 7.5 ALIKED

官方：<https://github.com/Shiaoming/ALIKED>

轻量 learned keypoint/descriptor，BSD-3-Clause；会改 feature，Lane Q。

### 7.6 XFeat

官方：<https://github.com/verlab/accelerated_features>  
论文：<https://openaccess.thecvf.com/content/CVPR2024/papers/Potje_XFeat_Accelerated_Features_for_Lightweight_Image_Matching_CVPR_2024_paper.pdf>

Apache-2.0、面向轻量设备。当前 frozen 配置已本地淘汰；没有明确新配置理由时不重复。

### 7.7 GLOMAP / COLMAP global mapper

官方：<https://github.com/colmap/glomap>

官方报告 benchmark 上 1–2 orders speedup、质量相当或更好；仓库 2026-03 已归档，功能迁入 COLMAP global mapper。未来直接评估当前 COLMAP global mapper，不围绕归档 wrapper 新建依赖。Lane Q。

### 7.8 Faiss exact flat / residency

官方：

- <https://github.com/facebookresearch/faiss/wiki/Faiss-indexes>
- <https://github.com/facebookresearch/faiss/wiki/Faiss-on-the-GPU>

`IndexFlatL2/IP` 是 exact brute-force，GPU-resident input 可省拷贝；但 GPU 版是 CUDA，不直接适合 iOS。其设计思想支持 residency，不需要为 Metal 引入 Faiss。

### 7.9 Google Highway

官方：<https://github.com/google/highway>

可为 x86、Arm NEON/SVE、Wasm 提供 portable C++ SIMD，适合 exact CPU fallback。预计不超过当前 Metal，但可能改善未来 Android/鸿蒙 CPU fallback。采用前冻结 revision 和许可证。

### 7.10 Dawn subgroup matrix / WGSL / Vulkan

- Dawn：<https://dawn.googlesource.com/dawn/+/refs/heads/main/docs/dawn/features/subgroup_matrix.md>
- WGSL：<https://gpuweb.github.io/gpuweb/wgsl/>
- Vulkan：<https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html>
- Android reduced precision：<https://developer.android.com/games/optimize/vulkan-reduced-precision>

Dawn subgroup matrix 是实验 feature，不是标准 WGSL 核心；类型/shape 按 backend/device。Vulkan integer dot 也是 optional capability。未来 Android/鸿蒙必须 runtime probe，不能假设所有设备有 u8 matrix。

### 7.11 Vulkan Kompute

官方：<https://github.com/nihui/vulkan-kompute>

它是 compute framework，不是 matcher 算法。未来可减少 Vulkan boilerplate，但当前不会自动提速，也不保证 exact，延期。

### 7.12 OpenCV SIFT / CUDA SIFT

OpenCV：<https://docs.opencv.org/4.5.4/d7/d60/classcv_1_1SIFT.html>

OpenCV CPU SIFT 输出不保证与当前 affine/DSP SIFT byte-identical，速度预计也不胜 GPU。PopSift/CudaSift 通常 CUDA-only，不适合 M3/iPhone。

---

## 8. 公平的 native vs portable matcher 合同

任何比较必须同时满足：

### 同一输入/环境

- 同一台 M3 Pro；
- 同一 power/process policy；
- 同两张 ordered real descriptor table；
- 同 row 数，优先 11568；
- 同 uint8×128 bytes 和 SHA-256；
- 同 threshold/config；
- 同 warmup/repetitions；
- A/B 顺序交替；
- 记录 compiler、binary、source、Dawn revision。

### 同一完整语义

两个 backend 都必须包含：

1. A→B nearest/second；
2. B→A nearest/second；
3. production angular `acos`；
4. production Lowe ratio；
5. production absolute threshold；
6. mutual cross-check；
7. deterministic ordered compaction；
8. production-required readback/consumption；
9. count + byte compare + SHA-256。

### 分阶段计时

- pipeline/shader creation；
- upload；
- two search directions；
- ratio/absolute filter；
- mutual/compaction；
- readback；
- complete wall total；
- cold/warm、p50、p95、raw runs。

至少 3 组 paired A/B，优选 5。若顺序漂移，用 ABBA 或 randomized paired order。

### 推进门

```text
ordered pairs byte-identical
count/config/input exact
portable complete p50 < native complete p50
improvement > preregistered A/A noise
p95 no material regression
```

portable tied/slower 就保留 Metal，仅保留共享 semantics/orchestration，不上手机。

明确禁止：

- 8192 native 对 11568 portable；
- Mac portable 对 A16 native；
- kernel-only 对 production full pair；
- 估算 N² 当实测；
- 一边含 readback/mutual，另一边不含。

---

## 9. 立即执行顺序

### 已找到的 146 帧正式输入候选

不要再花时间盲找数据。当前最适合 RANSAC/tail 主机实验的是：

```text
DB:
/Users/kaidongwang/Documents/progecttwo/_host_fixtures/cap7_day/official_sfm_live.db

2026-08-01 只读观察 SHA-256:
cf0b9113a1d2d8a68fc77eaba4975af9fbcb9c8dcd31a3f689b550bc81414794

ordered frame/pose manifest:
/Users/kaidongwang/Documents/progecttwo/_host_fixtures/cap7_day/official_sfm_fed_frames.jsonl

SHA-256:
2f4e01f422b2db07d4c8e964cfe544de7605c0b2ff3dd16f770f1255e38c9f09
```

DB 内容：

```text
images=146
cameras=146
keypoint rows=146
descriptor rows=146
descriptor vectors=1,189,640
matches rows=1,991
two_view_geometries rows=1,991
```

该 DB 有空 WAL 和 live shm sidecar。正式实验不要原地写它；复制并冻结 effective SQLite state 到新的 immutable artifact，再记录新 hash。

历史输出存在两个 attractor：

```text
common:
PLY 025227d1a345bfb169ad32afd21260eb6252e2c8bf166742909a0cbe22393f0c
n_reg=146 n_points=141758 track3plus=53239 n_obs=411770 reproj=1.0553

secondary:
PLY e1099759217da27278353f8fe9af632fcef3354e5d6bb5773d800156c39329a3
n_reg=146 n_points=141770 track3plus=53250 n_obs=411787 reproj=1.0551
```

所以必须先尽量固定 deterministic threads/seeds，并多次运行；若仍有两个 attractor，比较 attractor 分布和 ordered TVG digest，不能用单次 PLY hash 草率判胜负。

现有诊断 replay：

```text
/Users/kaidongwang/Documents/progecttwo/_host_fixtures/spatial_cand_exp/tools/sfm_replay_bench_cand
SHA-256 = 3f53c81e3161fd405dace6cea86e7cb3a7a9431bc2c912893f02b832cd74e3ea
```

它是旧 spatial-candidate 静态二进制，无法证明链接了当前 control 或 RANSAC candidate。正式 A/B 不得复用它，必须各自新建 host executable，并记录 dirty source tree、core archive、matcher object、compiler/dependencies 和最终 binary hash。

### H0：只读确认身份

第一组命令：

```bash
cd /Users/kaidongwang/Developer/Aether3D-cross
git status --short
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
shasum -a 256 \
  aether_cpp/official_pipeline/src/official_gpu_match.mm \
  aether_cpp/tools/aether_dawn_descriptor_matcher_bench.cpp \
  aether_cpp/experiments/portable_frontend_pareto/tools/subgroup_matrix_matcher_bench.cpp
```

身份 drift 就记录新 hash，不 reset。

### H1：COLMAP 4.1.1 风格 RANSAC mutex 单变量 A/B

唯一变量：

```text
control: original process-global omp critical
candidate: local/upstream-style per-call std::mutex
```

只允许两个头文件不同：

```text
colmap/optim/ransac.h
colmap/optim/loransac.h
```

不得同时改变 matcher、extractor、DB、seed、thread count、threshold、BA、cache、compiler flags。

输入优先用 immutable already-featured/matched 146-frame capture 或最长 fixture，隔离 two-view geometry/RANSAC。

冻结：

- DB path/hash；
- ordered image manifest；
- pair count；
- matches/TVG 初始状态；
- config/seed；
- outer workers、inner RANSAC threads；
- binary hash 和命令。

每 arm 至少三次，输出：

- total wall；
- TVG/RANSAC total、p50、p95；
- call count；
- ordered TVG digest；
- DB digest；
- registered images/order；
- local bundle trace；
- deterministic PLY hash；
- points、track、reprojection；
- logs/exit codes。

验收：exact 全通过、paired speed > A/A noise、p95 不回退、无 crash/deadlock/race。

上游 4–6×只是假设来源，不是本产品预算。

### H2：先补全公平 matcher harness，再优化 shader

当前 `subgroup_matrix_matcher_bench.cpp` 先补：

- 与 `official_gpu_match.mm` 相同的 angular ratio；
- absolute threshold；
- 双向搜索；
- mutual intersection；
- ordered pair；
- readback；
- digest；
- Metal reference byte compare。

理想结构：

```text
load one immutable descriptor fixture
  ├── native Metal backend
  └── Dawn/WGSL backend
both return vector<Pair>
one host validator checks bytes/hash
one timer records stages and complete wall time
```

简化 ratio 未删除前，任何 77.9ms 数字都不能选产品赢家。

### H3：长序列 tail cache A/B

- 146-frame 或最长 immutable capture；
- off/on 单变量；
- 优先 already-matched DB；
- per-frame tail；
- first/middle/final-third p50/p95；
- dirty epoch、hit/miss；
- 每帧 local BA image-ID 序列；
- deterministic DB/PLY exact。

4-frame exact 不足以证明 speed。

### H4：Residency 只在真实复用 batch 下重测

先证明同一 descriptor table 被多次复用。没有复用就不测。有复用就以完整 batch、5 组 paired、exact pairs 和 upload/lookup/eviction/total 指标判断。打平继续 default-off。

### H5：Highway CPU fallback

H1/H2 后再做 isolated experiment。完整 exact semantics，只与当前 CPU fallback 比。主要服务未来 Android/鸿蒙 fallback，不预期取代 Metal。

### H6：Lane Q 开源 Pareto

优先级：

1. SIFT + LightGlue；
2. ALIKED + LightGlue；
3. 当前 COLMAP global mapper；
4. 有新理由的 XFeat 配置。

同 capture，各生成 PLY，让用户肉眼与指标共同判断。

---

## 10. 现有测试入口和 artifact

合同测试：

```bash
cd /Users/kaidongwang/Developer/Aether3D-cross
bash aether_cpp/tests/sfm/test_portable_speed_arms_v1_contract.sh
```

Host replay 目标定义：

```text
aether_cpp/third_party/glomap_vendor/CMakeLists.txt
sfm_replay_bench_exe
official_replay_bench_exe
```

Host replay 源码：

```text
aether_cpp/third_party/glomap_vendor/bench/sfm_replay_bench.cc
```

曾加入 host no-op residency/timestamp stubs 和 `--max-frames=0`。已知 binary SHA：

```text
9345f0c4dfa2d8e518515d0e0660a6994cfa5fccc0c7bcb39de866761ea93e53
```

执行前读取当前 `--help`/源码，不凭记忆造参数。

推荐 artifact：

```text
/private/tmp/aether-host-speed-<experiment-id>/
  contract.yaml
  source_identity.txt
  input_manifest.sha256
  control/run-01.log
  control/run-02.log
  control/run-03.log
  control/metrics.json
  control/output.sha256
  candidate/run-01.log
  candidate/run-02.log
  candidate/run-03.log
  candidate/metrics.json
  candidate/output.sha256
  comparison.json
  verdict.md
```

失败和 invalid run 都保留，不覆盖。

---

## 11. 每次实验必须先写的合同模板

```yaml
experiment_id: <unique>
date: 2026-08-01
lane: exact | quality-changing
objective: <one sentence>
single_variable: <exactly one change>

repository:
  path: /Users/kaidongwang/Developer/Aether3D-cross
  branch: claude/publish-to-community
  head: b930ab185135dfbd172aef7c2bbeed67ef315f75
  dirty_diff_sha256: <record>

input:
  path: <absolute>
  ordered_manifest_sha256: <sha>
  database_sha256: <sha>
  frame_count: <n>
  descriptor_rows: <n>
  descriptor_dimensions: 128
  descriptor_dtype: uint8

environment:
  hardware: Apple M3 Pro
  os: <exact>
  compiler: <exact>
  build_type: Release
  dawn_revision: 12ee391c7411285895f4289a3d889a182c093014
  backend: <Metal/Dawn/CPU>
  outer_threads: <n>
  inner_threads: <n>
  seed: <exact>

arms:
  control:
    source_hashes: []
    binary_sha256: <sha>
    config: {}
  candidate:
    source_hashes: []
    binary_sha256: <sha>
    config: {}

run_order: [control, candidate, candidate, control, control, candidate]
warmup: <n>
measured_repetitions: 3

metrics:
  primary: complete_workload_wall_ms_p50
  secondary:
    - complete_workload_wall_ms_p95
    - stage_times
    - output_count
    - output_sha256

exact_gates:
  ordered_matches_byte_equal: true
  database_byte_equal: true
  local_bundle_trace_equal: true
  final_ply_equal: true

stopping_rules:
  - stop on crash, deadlock, invalid input, or source drift
  - reject exact lane on any semantic mismatch
  - reject phone promotion if host candidate is tied or slower
  - never change thresholds after observing results

artifacts:
  root: /private/tmp/aether-host-speed-<experiment-id>
```

---

## 12. 预算与诚实性规则

总产品目标曾是 2827 → ≤1642 ms/frame，需要约 1185 ms/frame。过去风险是 task 的收益没有实测闭合。

从现在起：

- 只有 paired measured bound 才能认领毫秒；
- 上游 README/论文数字不算产品预算；
- 跨设备结果不折算；
- kernel-only 不算 end-to-end；
- 理论上限/外推不算实测；
- host 只做筛选，未来产品接受仍需 physical iPhone；
- 已 ship 的 Local BA 不重复；
- tail 4-frame exact 不认领 speed；
- residency 打平不认领 speed；
- WGSL 77.9ms 语义不完整，不认领 production speed；
- RANSAC patch 尚未 A/B，当前 credit=0。

当前 roll-up：

| 候选 | speed credit | 状态 |
|---|---:|---|
| Metal v2 | shipped baseline | exact reference |
| Local BA threads | 不重复 | 已 ship |
| RANSAC mutex | 0 | 第一优先待测 |
| tail cache | 0 | 仅小规模 exact |
| residency | 0 | host 打平 |
| subgroup WGSL | 0 | 语义不完整 |
| canonical 8192 | Lane E 为 0 | 改 feature set |
| XFeat frozen arm | rejected | 慢约 2× |
| LightGlue/ALIKED | 0 | Lane Q 未测 |
| global mapper | production credit 0 | 算法变化 |

---

## 13. 明确停止/拒绝条件

1. 当前阶段任何手机操作；
2. host 不赢却说手机也许会赢并上机；
3. M3 与 A16 数字相除；
4. 不同 row count 比较；
5. shader-only 对 full production；
6. 简化 ratio 冒充 exact；
7. 改 feature/match 仍放 Lane E；
8. 看结果后改门；
9. 估算值写成 measured；
10. 上游 4–6×/1–2 orders 写成本产品收益；
11. 重复认领已 ship 优化；
12. reset/clean/stash/checkout 共享工作树；
13. 触碰 UI/cube/capture/compression；
14. 升级依赖；
15. 无 source/binary/input hash 就正式跑；
16. 覆盖失败 artifact；
17. 把跨端定义成一个 WGSL shader 强制通吃；
18. 把 `official` 文件名当上游证明；
19. 未审许可证/权重就采用 learned model；
20. portable 完整 host workload 未胜就写手机/Android/鸿蒙产品集成。

---

## 14. 下一位执行者的第一个实际任务

不要继续写泛泛计划。立即：

1. 完整读本提示词和 603 行 OpenSpec evidence；
2. 只读确认 repo identity 和两个 RANSAC header diff；
3. 找 immutable already-matched host fixture；
4. 写版本化 RANSAC A/B contract；
5. 建隔离 control/candidate build，唯一变量为两个 header 的锁修复；
6. 先跑 A/A noise；
7. 再跑至少三组 paired A/B；
8. 验证 ordered TVG、DB、registered/local-bundle trace、deterministic PLY；
9. 得出 accept/reject；
10. H1 完成后才改 Metal/WGSL 公平 harness。

如果 fixture 无法隔离 RANSAC，先扩展 host replay，让它从 already-matched DB 开始并输出 TVG/RANSAC stage timing；不要退回手机测试。

---

## 15. 阶段性汇报格式

```text
结论：快了 / 没快 / 无效 / 质量语义变了。

这次唯一改动：
...

主机速度：
control p50/p95 = ...
candidate p50/p95 = ...
paired delta/noise = ...

质量：
ordered matches/TVG = exact/different
DB = exact/different
PLY = exact/different
registered images = exact/different

能否进入下一步：YES/NO
原因：...

artifact：
<absolute paths and hashes>
```

不能再回答“什么都不能保证，所以请用户上手机测”。代码分析和 host harness 的任务就是先把不知道变成 accept/reject。

---

## 16. 最终方向判断

1. 跨端方向正确，但不等于去掉 Metal。
2. 当前最优生产结构仍是 CPU+GPU 混合。
3. 共享 C++ contract/cache/scheduler/geometry/BA 对未来三端有真实价值。
4. 新 WGSL 比旧 generic 约快 3×，但语义不完整，诊断上仍落后原生。
5. 它没上生产，所以当前产品质量没被降低。
6. 若直接用会改变 match set，必须保持关闭。
7. Residency 当前打平，default-off。
8. Tail cache 只证明小规模 exact，需长序列。
9. Canonical exact-8192 属于 Lane Q。
10. XFeat 当前配置已淘汰。
11. LightGlue、ALIKED、global mapper 值得 Lane Q 调研，但不是 exact。
12. 第一 exact 上游候选是 COLMAP 4.1.1 风格 RANSAC per-call mutex。
13. 第一 matcher 工作是完整、公平的 Metal vs portable harness。
14. portable 在 Mac 完整 workload 没赢 native 之前，绝不碰手机。

---

## 17. 联网资料索引

| 方案 | 官方资料 | 语义 | 当前结论 |
|---|---|---|---|
| COLMAP 4.1.1 lock fix | <https://colmap.github.io/changelog.html> | 目标等价 | 第一优先 A/B |
| Caspar GPU BA | <https://colmap.github.io/changelog.html> | BA 后端 | CUDA，当前不适用 |
| COLMAP features | <https://colmap.github.io/features.html> | 可改变 | 上游入口 |
| LightGlue | <https://github.com/cvg/LightGlue> | 改 matches | Lane Q |
| LightGlue paper | <https://openaccess.thecvf.com/content/ICCV2023/papers/Lindenberger_LightGlue_Local_Feature_Matching_at_Light_Speed_ICCV_2023_paper.pdf> | 改 matches | 研究证据 |
| ALIKED | <https://github.com/Shiaoming/ALIKED> | 改 features | Lane Q |
| XFeat | <https://github.com/verlab/accelerated_features> | 改 features | frozen arm rejected |
| XFeat paper | <https://openaccess.thecvf.com/content/CVPR2024/papers/Potje_XFeat_Accelerated_Features_for_Lightweight_Image_Matching_CVPR_2024_paper.pdf> | 改 features | 研究证据 |
| GLOMAP | <https://github.com/colmap/glomap> | 改 mapper | 看当前 COLMAP global mapper |
| Faiss exact index | <https://github.com/facebookresearch/faiss/wiki/Faiss-indexes> | flat 可 exact | 设计参考 |
| Faiss GPU | <https://github.com/facebookresearch/faiss/wiki/Faiss-on-the-GPU> | flat 可 exact | CUDA，不直用 |
| Highway | <https://github.com/google/highway> | 可 exact | CPU fallback |
| Dawn subgroup matrix | <https://dawn.googlesource.com/dawn/+/refs/heads/main/docs/dawn/features/subgroup_matrix.md> | 需证明 | backend dependent |
| WGSL | <https://gpuweb.github.io/gpuweb/wgsl/> | 标准 | subgroup matrix 非标准核心 |
| Vulkan | <https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html> | capability dependent | 未来 probe |
| Android precision | <https://developer.android.com/games/optimize/vulkan-reduced-precision> | 后端优化 | 未来参考 |
| Kompute | <https://github.com/nihui/vulkan-kompute> | 框架 | 延期 |
| OpenCV SIFT | <https://docs.opencv.org/4.5.4/d7/d60/classcv_1_1SIFT.html> | 未必 exact | fallback/参考 |

---

## 18. 一句话执行命令

> **先在 Mac 上把 COLMAP 4.1.1 风格 RANSAC 全局锁修复做成严格单变量 exact A/B；同时把 WGSL matcher 补齐成与 Metal 完全相同的 angular ratio、absolute threshold、双向搜索、mutual cross-check、ordered pair 和 readback，再同机同输入比较。完整 portable 没超过 native，就保留 Metal，不上手机；改变 feature/match 的开源路线单独做 PLY+指标的 Lane Q，绝不冒充零质量损失。**
