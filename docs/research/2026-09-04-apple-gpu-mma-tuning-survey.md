# 线 B 调研:Apple GPU 矩阵核(simdgroup_matrix / subgroup matrix)业界调优实践

调研日期 2026-09-04。全部源码从上游 HEAD 直取并本地逐行读过:
`ml-explore/mlx@b6368984b8e0`(2026-09-03)、`ggml-org/llama.cpp@d30500b83b0f`(2026-09-03)。
本文**不碰** Dawn/tint 代码生成与 toggle(另一 agent 的战线),只谈 tile / fragment 配比、
Apple GPU 架构事实、以及由此推出的重排方案。

战场前提(已由 `2026-09-03-mixed-mma-result.md` 定格,本文不复测):
M3 Pro,8192×8192×128 一对;混合精度 WGSL **GPU p50 7.9-8.7ms**,手写 Metal **5.2-6.6ms**,
比值 ~1.3-1.6×;两者结构完全一致(工作组 128 行 × 32 列、16 子组 × 512 线程、
Bsh 8KiB f16 + accSh 16KiB f32 = 24KiB、K=128 拆 16 条 8×8×8 混合精度 MMA);
16.7M 条 MMA = 8.6 GMAC,零冗余;MMA 占 60-70%。

---

## 0. 三条结论(先说结果)

1. **我们的子组 tile 是全业界最"瘦"的一档。** 我们每个子组只累加 **4** 个 8×8 输出块
   (8 行 × 32 列 = TM=1 行片段 × TN=4 列片段)。MLX / llama.cpp 的 Metal 核 / llama.cpp 的
   WebGPU 核 **三家独立实现全部是每子组 8 个块**(32 行 × 16 列 = TM=4 × TN=2),
   Vulkan coopmat 与 MLX 的大设备档到 **16-32 个块**。
   直接后果:**我们每条 MMA 都要从 threadgroup 现取一个 B 片段(1.0 载入/MMA);
   业界是 0.5-0.75。** 因为 TM=1 时 B 片段无处复用 —— 复用次数恰等于 TM。

2. **Apple GPU 上 f16 MMA 不比 f32 MMA 快(实测 102.5 vs 101.7 FFMA/核-周期),
   matrix 指令跑在同一批 FP32 流水上,峰值反而低于标量 FFMA(128/核-周期)。**
   这解释了我们"f16→f16 判死"和"混合精度只值 1.39× 而非 2×"两个已知结果 —— 混合精度的
   收益来自**带宽与共享内存预算**,不是 MMA 吞吐。M5/A19 才第一次有独立的 Neural Accelerator。

3. **Metal 那 5.2ms 已经接近 Apple GPU 矩阵路径的公开天花板(约 50% 标量 ALU roofline,
   与 M4 Max 上第三方实测的 46% 同量级)。** 我们的目标只能是"追平",不存在"超越"的公开路径。
   现有 7.9-8.7ms ≈ 38-42% roofline,与 Metal 的差距在**每条 MMA 之外**的开销上,
   而 tile 重排正是唯一还没试过的、能**整体减少指令条数**(而非摊平)的杠杆。

---

## 1. 主表:来源 → 配比 → 机制 → 对我们的改法 → 预期 → license

| 来源(file:line) | 工作组 tile | 子组数/线程 | **每子组 8×8 块** | 载入/MMA | 共享内存 | 机制要点 | 对我们的具体改法 | 预期 | License |
|---|---|---|---|---|---|---|---|---|---|
| **我们现役** | 128×32, K=128 | 16 / 512 | **4** (TM=1 × TN=4) | **1.0**(A 全在寄存器,B 每条一取) | Bsh 8K + accSh 16K = **24K(相加)** | A 的 16 个 k 片段常驻寄存器;B 每条 MMA 现取 | — | 基线 8.0ms | — |
| **MLX** `metal/matmul.cpp:98-104`(小设备 nt 分支) | 64×32, BK=32 | 4 / 128 | **8** (TM=4 × TN=2) | 0.75 | A 5K + B 2.5K ≈ **7.5K** | 累加器全在寄存器;A/B 也在寄存器里做片段;**无双缓冲**;tgp lead dim 补 16 字节 | 子组 tile 从 8×32 改成 32×16 或 16×16 | B 载入 −50~75% | **MIT** |
| **MLX** `metal/matmul.cpp:166-170`(中等设备默认) | 64×64, BK=16 | 4 / 128 | **16** (4×4) | 0.5 | ~9K | 同上 | 同上 | 同上 | MIT |
| **MLX** `metal/matmul.cpp:105-109`(小设备 half/bf 的 nn) | 64×64, BK=16 | **2 / 64** | **32** (TM=8 × TN=4) | 0.375 | ~9K | 极端寄存器化:每 lane 64 个 f32 累加器 = 256B | (仅作上界参考,我们 A 常驻寄存器时吃不下) | — | MIT |
| **llama.cpp Metal** `kernels/mul_mm.metal:163-166, 202-205, 290-311` | 64×32 (NR0=64, NR1=32), NK=32 | 4 / 128 | **8** (`simdgroup_float8x8 mc[8]`,4 行 × 2 列) | 0.75 | sa 4K + sb 2K = **6K** | **共享内存按 8×8 片段分块存放**(`sa + 64*ib + 8*ly + lx`),`simdgroup_load(..., 8, 0, false)` 读的是 **64 个连续元素**,不需要任何 stride 补齐;无双缓冲;`simdgroup_barrier(mem_none)` 隔开 A/B 载入与 MMA | (a) 子组 tile 改 4×2;(b) Bsh 改片段分块布局 | B 载入 −50%;stride 问题消失 | **MIT** |
| **llama.cpp WebGPU/WGSL** `ggml-webgpu-shader-lib.hpp:42-49` + `wgsl-shaders/mul_mat_subgroup_matrix.wgsl:127-165` | 64×64, TILE_K=32 | 8 / 256 | **8** (`SUBGROUP_MATRIX_M=4` × `SUBGROUP_MATRIX_N=2`,注释原文:"The number of subgroup matrices each subgroup accumulates over") | 0.75 | **`SHMEM_SIZE = max(A+B, 累加器)`** —— 一个 `var<workgroup>` 复用,不是相加 | 与我们同语言同接口;累加器是 `array<array<subgroup_matrix_result<...>,N>,M>` 放寄存器;外层 loop 载 M 个 left,内层 loop 每载 1 个 right 就打 M 条 MMA | (a) **Bsh 与 accSh 并集复用**;(b) 子组 tile 4×2 | 共享内存 24K→16K;B 载入 −50% | **MIT** |
| **llama.cpp Vulkan** `ggml-vulkan.cpp:4342-4344` + `vulkan-shaders/mul_mm.comp:311-320` | l: 128×128 / m: 64×64 / s: 32×32,BK=16 | 4 / 128 | 每 warp **32×32 输出**(= 16 个 8×8,或 4 个 16×16) | 0.5(8×8 档) | 有 `bank_conflict_offset = coopmat ? 8 : 1` 的 stride 补齐 | 与 WGSL 结构同形:`sums[cms_per_row*cms_per_col]`,外层 cm_row 载 A、内层 cm_col 载 B 再打 MMA | 同上,并且给了"32×32/子组"的上界参考 | 0.5 | **MIT** |
| **candle(反例)** issue #3302 | 32×32, BK=16, wm=wn=2 → **4 块/子组**(与我们同档) | 4 / 128 | **4** | 1.0 | — | 单一硬编码 tile | —(反例) | 在 M 系列上比 MLX 慢 **5.3-11.2×**(其 issue 自述归因于固定 tile;有批量/派发混淆,当相关不当机制) | Apache-2.0/MIT |
| **Apple 官方** WWDC26 "Optimize custom ML operations with Metal tensors" | — | — | — | — | — | 原文:"In macOS 26, you would have had to first store it to threadgroup memory. But it's now possible to use cooperative tensors directly as inputs to matmul operations." | 方向背书:**少走 threadgroup、多留寄存器** | — | — |

**读法**:载入/MMA = (TM+TN)/(TM·TN)(MLX/llama.cpp 三家 A、B 都每 k 步现取);
我们把 A 全部提到寄存器 ⇒ 载入/MMA = 1/TM = 1.0。**TM 就是 B 片段的复用次数,我们的 TM=1。**

---

## 2. 逐来源证据(原文摘录 + 行号)

### 2.1 MLX(Apple 自家 ML 框架,Apple Inc. 版权,MIT)

`mlx/backend/metal/kernels/steel/gemm/mma.h:453-537`:

```
struct BlockMMA {
  STEEL_CONST short kFragSize = 8;
  STEEL_CONST short TM = BM / (kFragSize * WM);   // 每子组的行片段数
  STEEL_CONST short TN = BN / (kFragSize * WN);   // 每子组的列片段数
  MMATile<AccumType, TM, 1, MMAFrag_acc_t> Atile;
  MMATile<AccumType, 1, TN, MMAFrag_acc_t> Btile;
  MMATile<AccumType, TM, TN, MMAFrag_acc_t> Ctile;   // ← 累加器 TM×TN 个片段,全在寄存器
  METAL_FUNC void mma(const threadgroup T* As, const threadgroup T* Bs) thread {
    for (short kk = 0; kk < BK; kk += kFragSize) {
      simdgroup_barrier(mem_flags::mem_none);
      Atile.template load<T, WM, 1, A_str_m, A_str_k>(As);
      simdgroup_barrier(mem_flags::mem_none);
      Btile.template load<T, 1, WN, B_str_k, B_str_n>(Bs);
      simdgroup_barrier(mem_flags::mem_none);
      tile_matmad(Ctile, Atile, Btile, Ctile);       // ← TM×TN 条 MMA
      As += tile_stride_a; Bs += tile_stride_b;
    }
  }
```

三条值得抄的细节:
- **`tile_matmad`(mma.h:407-427)用蛇形序**:`short n_serp = (m % 2) ? (N - 1 - n) : n;` ——
  相邻 m 行反向遍历 n,让上一条 MMA 刚用过的 B 片段立刻被下一条复用(寄存器局部性)。
- **片段不走 `simdgroup_load`**:`BaseMMAFrag<T,8,8>` 的 `kElemsPerFrag = 64/32 = 2`,
  `frag_type = metal::vec<T,2>`,`load()` 是**逐 lane 两个标量读**(mma.h:57-67),
  最后 `reinterpret_cast` 进 `simdgroup_matrix` 再 `simdgroup_multiply_accumulate`(mma.h:181-206)。
  ⚠️ **这条不可移植到 WGSL** —— WGSL 的 subgroup matrix 是不透明类型,只能 `subgroupMatrixLoad`。
- **累加类型默认 `AccumType = float`**(mma.h:441),即使 T=half:A/B 片段在寄存器里被
  升成 f32,MMA 走 `simdgroup_matrix<float,8,8>`。**MLX 在 Apple GPU 上根本没用 f16 操作数的 MMA。**
  (与第 3 节的吞吐表一致:f16 MMA 不比 f32 快。)

`mlx/backend/metal/kernels/steel/gemm/gemm.h:38-44`:
```
STEEL_CONST short tgp_padding_a = 16 / sizeof(T);   // 半精度=8 个元素=16 字节
STEEL_CONST short tgp_mem_size_a = transpose_a ? BK*(BM+tgp_padding_a) : BM*(BK+tgp_padding_a);
```
`gemm.h:97-119` 主循环:
```
for (int k = 0; k < gemm_k_iterations; k++) {
  threadgroup_barrier(mem_flags::mem_threadgroup);
  loader_a.load_unsafe(); loader_b.load_unsafe();
  threadgroup_barrier(mem_flags::mem_threadgroup);
  mma_op.mma(As, Bs);
  loader_a.next(); loader_b.next();
}
```
⇒ **MLX 没有软件流水/双缓冲**,单缓冲 + 两道 barrier。它靠的是高算术强度(TM×TN)
和小共享内存(7.5-9KiB ⇒ 高驻留),不是流水。
(我们的 db 流水实测有效,不必推翻;但这说明"流水"不是业界共识的必需品。)

设备分档 `mlx/backend/metal/matmul.cpp:90-171`(`devc = d.get_architecture().back()`):
- `'g'/'p'` = 小设备(手机/基础档),`'d'` = 大设备,其余 = 中等;
- **小设备 + nt(= 我们的布局:A 行主 M×K,B 行主 N×K)⇒ `bm=64, bn=32, bk=32, wm=2, wn=2`**
  ⇒ TM=4, TN=2 ⇒ **每子组 8 个 8×8 块**;
- 大设备 half/bf 且 K 合理 ⇒ `64,64,16,1,2` ⇒ TM=8, TN=4 ⇒ 32 块。

### 2.2 llama.cpp 的 Metal 核(MIT)

`ggml/src/ggml-metal/kernels/mul_mm.metal:163-166, 202-205, 290-311`:
```
constexpr int NR0 = 64;   // 输出行
constexpr int NR1 = 32;   // 输出列
constexpr int NK  = 32;
S0_8x8 ma[4];  S1_8x8 mb[2];  simdgroup_float8x8 mc[8];      // ← 4 行 × 2 列 = 8 个累加块
...
threadgroup const S0 * lsma = (sa + 4*64*(sgitg%2));          // 子组网格 2×2
threadgroup const S1 * lsmb = (sb + 2*64*(sgitg/2));
FOR_UNROLL (short ik = 0; ik < NK/8; ik++) {
    simdgroup_barrier(mem_flags::mem_none);
    FOR_UNROLL (short i = 0; i < 4; i++) simdgroup_load(ma[i], lsma + 64*i, 8, 0, false);
    simdgroup_barrier(mem_flags::mem_none);
    FOR_UNROLL (short i = 0; i < 2; i++) simdgroup_load(mb[i], lsmb + 64*i, 8, 0, false);
    simdgroup_barrier(mem_flags::mem_none);
    FOR_UNROLL (short i = 0; i < 8; i++) simdgroup_multiply_accumulate(mc[i], mb[i/4], ma[i%4], mc[i]);
    lsma += 8*64;  lsmb += 4*64;
}
```
6 次载入 → 8 条 MMA(0.75)。**共享内存布局是"8×8 片段连续"**:
`*(sa + 64*ib + 8*ly + lx)`,`ib = 8*sx + sy`(sx = k 片, sy = 行片),
所以 `simdgroup_load(..., stride=8, ...)` 读的是**一段 128 字节连续内存**,
`sa` 是 4096 字节、`sb` 是 2048 字节,**一个补齐字节都没有**。
👉 这与我们"stride 填充无效"的实测**互相印证**:Apple 上正确的解法不是补 stride,
是**换成片段分块布局让每次片段读退化成线性突发**。

### 2.3 llama.cpp 的 WebGPU / WGSL 核(与我们同语言同接口,MIT)—— **最重要的对照物**

`ggml/src/ggml-webgpu/ggml-webgpu-shader-lib.hpp:41-49`:
```
// Subgroup matrix parameters
// The number of subgroups in the M dimension
#define WEBGPU_MUL_MAT_SUBGROUP_M            2
// The number of subgroups in the N dimension
#define WEBGPU_MUL_MAT_SUBGROUP_N            4
// The number of subgroup matrices each subgroup accumulates over
#define WEBGPU_MUL_MAT_SUBGROUP_MATRIX_M     4
#define WEBGPU_MUL_MAT_SUBGROUP_MATRIX_N     2
#define WEBGPU_MUL_MAT_SUBGROUP_TILE_K_FLOAT 32
```
⇒ 8 子组(256 线程)、工作组 tile 64×64、TILE_K=32、**每子组 4×2 = 8 个 8×8 块**。

`wgsl-shaders/mul_mat_subgroup_matrix.wgsl:77-82`:
```
const SG_MAT_ACCUM_SHMEM = SUBGROUP_M*SUBGROUP_MATRIX_M*SUBGROUP_N*SUBGROUP_MATRIX_N
                           * SUBGROUP_MATRIX_M_SIZE * SUBGROUP_MATRIX_N_SIZE;
// We reuse shmem for accumulation matrices
const SHMEM_SIZE = max(TILE_SRC0_SHMEM + TILE_SRC1_SHMEM, SG_MAT_ACCUM_SHMEM);
var<workgroup> shmem: array<f16, SHMEM_SIZE>;
```
🔴 **他们的 A/B staging 与累加器 staging 是同一块 `var<workgroup>`,取 max 不是相加。**
我们现在是 `Bsh 8K + accSh 16K = 24K` 相加。

`mul_mat_subgroup_matrix.wgsl:127, 138-165`:
```
var acc_sg_mat : array<array<subgroup_matrix_result<f16, N_SIZE, M_SIZE>, SUBGROUP_MATRIX_N>, SUBGROUP_MATRIX_M>;
...
for (var k_inner = 0u; k_inner < TILE_K; k_inner += SUBGROUP_MATRIX_K_SIZE) {
    var src0_sg_mats: array<subgroup_matrix_left<...>, SUBGROUP_MATRIX_M>;
    for (var m = 0u; m < SUBGROUP_MATRIX_M; m++) {          // 载 4 个 A 片段
        src0_sg_mats[m] = subgroupMatrixLoad<...>(&shmem, ..., false, TILE_K);
    }
    for (var n = 0u; n < SUBGROUP_MATRIX_N; n++) {          // 每载 1 个 B 片段
        let src1_sg_mat = subgroupMatrixLoad<...>(&shmem, ..., true, TILE_K);
        for (var m = 0u; m < SUBGROUP_MATRIX_M; m++) {      // 打 4 条 MMA
            acc_sg_mat[m][n] = subgroupMatrixMultiplyAccumulate(src0_sg_mats[m], src1_sg_mat, acc_sg_mat[m][n]);
        }
    }
}
```
👉 **这就是"B 片段复用 TM 次"的标准写法,而且它是合法 WGSL、已在生产里跑。**
另注:`subgroupMatrixLoad` 的 stride 就是 `TILE_K = 32`(f16 = 64 字节行),**没有任何补齐**。
再注:他们用 `subgroup_matrix_result<f16,...>` 累加,**已知会 NaN**
(shader 顶部 TODO 引 issue 21602)—— 我们用 f32 累加是对的,不要跟。

**同一 PR(#17031)在 M3 上给出的 WebGPU vs Metal 数字**:
Llama-3.2-1B-F16 pp512:WebGPU **1014.17 ± 9.38** t/s vs Metal **1368.47 ± 0.95** t/s
⇒ Metal 快 **1.35×**。
👉 **另一支独立团队、另一套 WGSL matmul,在 Apple GPU 上量到的 WGSL/Metal 比值与我们的
1.3-1.6× 完全同档。** 这是一个重要的外部标尺:这个 gap 不是我们核写坏了,
而是 WGSL→Metal 这条链在 Apple 上的**结构性成本**(与它们的 tile 更优无关)。

### 2.4 llama.cpp 的 Vulkan coopmat 核(MIT,给 Vulkan 臂参考)

`ggml-vulkan.cpp:4342-4344`(warptile 格式 = {wg_size, BM, BN, BK, WM, WN, WMITER, TM, TN, TK, subgroup}):
```
l_warptile = { 128, 128, 128, 16, mm_warp_8*2, 64, 2, tm_l, tn_l, tk_l, mm_warp_8 };
m_warptile = { 128,  64,  64, 16, mm_warp_8,   32, 2, tm_m, tn_m, tk_m, mm_warp_8 };
s_warptile = { 32,   32,  32, 16, 32,          32, 2, ... };
```
subgroup=32 时 `m_warptile` 的每 warp tile = **32×32 输出**;`l_warptile` = 64×64 输出/warp。
`vulkan-shaders/mul_mm.comp:311-320` 的内层与 WGSL 版同形(外层载 A、内层载 B 再打 MMA)。
`ggml-vulkan.cpp:4052`:`bank_conflict_offset = intel_shmem_stride_pad_zero ? 0 : (coopmat_support ? 8 : 1)`
⇒ Vulkan 侧仍然补 stride(**8 个元素**),与 Metal 侧的"片段分块、零补齐"是两种流派。

---

## 3. Apple GPU 架构事实(决定上面的选择)

来源:`philipturner/metal-benchmarks`(MIT,Apple GPU 微架构逆向,业界事实标准)、
`tzakharko.github.io/apple-neural-accelerators-benchmark`、arXiv Rigel(M4 Max 张量路径逆向)、
techboards.net 上 leman 的 threadgroup 内存微基准。

### 3.1 矩阵指令吞吐 —— **f16 和 f32 一样快,而且都低于标量 FFMA**

metal-benchmarks README 的表(单位:每核-周期):

| Per Core-Cycle | A11-A13 | A14 | **A15+, M1+** |
|---|---|---|---|
| Matrix FFMA8 | 0 | 0 | 0 |
| Matrix FFMA16 | 83.7 | TBD | **102.5** |
| Matrix FFMA32 | 43.6 | ~56.9 | **101.7** |
| Matrix FFMA64 | 0 | 0 | 0 |

同文件的标量表:M1/A15 的 `F32 OPs (FMA) = 256`、`F16 OPs (FMA) = 256`(即 128 FFMA/核-周期)。
⇒ **matrix 路径 = 102 / 128 = 80% 的标量 FFMA 峰值,f16 与 f32 之差 < 1%。**
作者原文(README:122):
> Apple's "tensor core" is the `simdgroup_matrix` instruction, which decreases register pressure
> and improves ALU utilization in existing FP32 pipelines.

BaseRT(arXiv 2607.19438)同意:
> It runs on the GPU's general-purpose arithmetic units... The M5 breaks this coupling.
> Its redesigned GPU places a dedicated Neural Accelerator inside each GPU core.

A19/M5 的 Neural Accelerator 才是真张量核:**~1024 FLOPS/核-周期 fp16**
(= 512 FMA,是 FP32 FMA 的 4×;tzakharko 实测 A19 5 核 ≈ 7.4 TFLOPS fp16、13.4 TOPS int8)。
M3 Pro **没有**。

🔴 **对我们的意义(三条)**:
1. "f16→f16 判死"、"混合精度只值 1.39× 而非 2×" 全部得到机制解释 —— **混合精度的收益
   在带宽/预算,不在 MMA 吞吐**,已被我们自己的实测(第二次 −11.4%)独立证实。
2. **不要再找"更快的 MMA 数据类型"**。M3 上 8×8×8 就是 8×8×8,f16/f32 同价。
   (u8/i8→i32 的整数 MMA 在 WGSL 语言层有重载,但 M3 的 Metal 后端不暴露 —— 已由
   `2026-09-03-sgmatrix-probe-m3.md` 实测;而且即使有,int8 MMA 在 M3 上也不会更快,
   只有 A19/M5 的 NA 才把 int8 拉到 ~1900 OPS/核-周期。)
3. **唯一还能动的是"每条 MMA 之外的指令"** —— 也就是 `subgroupMatrixLoad` 的条数。

### 3.2 roofline 对账(M3 Pro,我们的夹具)

8192×8192×128 = 8.59 GMAC。按 102.5 MAC/核-周期、M3 Pro 18 核 @ ~1.4GHz:
理论下限 ≈ **3.3 ms**。

| 臂 | GPU 时间 | 对 matrix roofline |
|---|---|---|
| 手写 Metal | 4.9-5.3 ms | **62-68%** |
| 混合 WGSL(现役) | 7.9-8.7 ms | 38-42% |

外部标尺:Rigel(arXiv 2606.12765,M4 Max)原文
> Tiled fp16 matmul2d peaks at 14.8 TFLOP/s, approximately **46% of the scalar-ALU roofline**.
以及
> MPP beats simdgroup_matrix by only 1.05–1.21×
(即 Metal 4 的张量 API 在 M4 Max 上只比 simdgroup_matrix 快 5-21%,没有另一条快车道。)

👉 **手写 Metal 已在公开水平的上沿,"超越 Metal"没有已知路径;能拿的只有 7.9→~5.5 这一段。**
⚠️ 注意:102.5 这个数是 Turner 在 Apple 7/8(A15/M1/M2)上量的,**M3 = Apple 9,
带 Dynamic Caching,矩阵吞吐没有公开复量**。这是本文最大的一个不确定项(见第 7 节),
**建议我们自己补一次纯 MMA 微基准做阳性对照**(第 5 节 P0)。

### 3.3 寄存器 / 共享内存 / occupancy

metal-benchmarks "On-Chip Memory" 表(Apple 7,8 列):

| 项 | Apple 7,8 |
|---|---|
| Max Threads / 核 | 384-3072 |
| Register File / 核 | **~208 KB** |
| Shared Memory / 核 | **~60 KB** |
| Instruction Cache | 12 KB |
| Data Cache (L1) | 8 KB |
| **Shared Bank Size** | **TBD** |
| **Shared Banks** | **TBD** |
| Global Cache Line | 128 B |
| SIMD Shuffle BW/Cycle | 256 B(业界最高) |
| Shared BW/Cycle | **TBD** |
| On-Core Data BW/Cycle | 64 B |

同文件脚注(README:770):
> Apple also reduces the amount of threadgroup memory bandwidth. Addressing circuitry probably
> cannot scale power consumption at the resolution of nanoseconds. The solution: make less of it.
> Instead, invest in industry-leading SIMD shuffle bandwidth and matrix instructions!

以及 ALU 饱和点(README:208):
> Note that ALU utilization maxes out at **24 simds/core**.

**occupancy 估算(我们的核)**:
- 512 线程/工作组 = 16 simds;共享内存 24 KiB。
- 若每核共享池 = 64 KiB ⇒ 驻留 **2 个工作组** = 32 simds ✅ 已过 24 simds 饱和点;
- 若每核共享池 = 32 KiB(= Metal 的单工作组上限)⇒ 驻留 **1 个** = 16 simds ❌ 未达饱和;
- 寄存器侧:A 的 16 个 k 片段 = 每 lane 32 个 half = **64 B**;累加器 4 块 × 2 f32 = **32 B**;
  合计 ~96 B + 临时。1024 线程 × ~150 B ≈ 150 KB,在 ~208 KB 内。
🔴 **每核共享池到底是 32 还是 64 KiB,决定了"并集复用"这一刀值不值 —— 必须实测**(第 5 节 P0)。

### 3.4 bank conflict:M1 有,M3 没人解释得清 —— 我们的"补 stride 无效"是可复现的现象

techboards.net "The mystery of Apple M3 on-chip shared memory",用户 leman 的微基准原话:
> "M1 is easy — this is a classical shared memory with **32 independent banks**."
> (M3, store-only)"we can see some bank conflict-like effects (strides 8, 16, 24, 32 are slower)"
> "I have no idea how this memory is organised in the background."
(load-accumulate 核在 M3 上"even strides"有惩罚,而 **stride 32 反而 really fast**。)

metal-benchmarks 的 On-Chip Memory 表里 Apple 的 Shared Banks / Shared Bank Size 一栏
**明写 TBD**(Nvidia/AMD/Intel 都填了 32 banks × 4 B)⇒ **公开世界没有 Apple 的 bank 模型**。

👉 结论:**"补 stride"在 Apple 上不是可靠工具**(我们实测无效是正常的、与 M3 的观测一致);
llama.cpp 的 Metal 核干脆**换布局**(8×8 片段连续存放、stride=8 的线性突发),
MLX 则补固定 **16 字节**(不是按 bank 数推的,是按向量访问对齐推的)。
两者都不是"按 32 banks 算 padding"。

### 3.5 Apple 官方口径(唯一能引到的两条)

- Tech Talk 10858 "Discover Metal enhancements for A14 Bionic"(simdgroup_matrix 首发):
  > "In the Metal shading language, we now have SIMD group scope data structures to represent
  > 8 by 8 and 4 by 4 matrices."
  给的是**端到端**收益(相对 A13:GEMM 平均 +37%、CNN 卷积 +36%、Inception V3 训练 +22%),
  **没有任何 tile / 寄存器 / threadgroup 调优建议**。
- WWDC26 session 330 "Optimize custom machine learning operations with Metal tensors":
  > "The basic approach is to slice the input matrices into smaller tiles, and then perform
  > tile-wise matrix multiplications using TensorOps. This maximizes parallelism and keeps data in the cache."
  > "Cooperative tensors distribute their storage across the **thread private memory** of the threads
  > participating in the matmul operation."
  > "In macOS 26, you would have had to first store it to threadgroup memory. But it's now possible
  > to use cooperative tensors directly as inputs to matmul operations."
  ⇒ Apple 自己的演进方向就是**把片段留在寄存器、少走 threadgroup**,与本文主张同向。
  ⚠️ 官方**没有**公布任何 tile 尺寸建议或 MPS/MPSGraph 的 TFLOPS 官方口径(见第 7 节)。
- 旁证:Apple 自家 MPS 的矩阵乘用私有指令 `air.simdgroup_async_copy_2d`
  (dougallj/applegpu issue #28:"In Apple's NDArrayMatrixMultiplyNNA14 kernel in MPS for matrix
  multiply, they use a private simdgroup API `air.simdgroup_async_copy_2d`",类比 Nvidia 的 `cp.async`)
  —— **公开 API 拿不到**,MLX / llama.cpp / 我们都用不了。

---

## 4. 我们这颗核的算术强度账(数字,不是形容词)

设 TM = 每子组的**行**片段数、TN = 每子组的**列**片段数。

- MMA 条数 = 8.59 GMAC / 512 = **16.78 M**(与我们已核的 16.7M 一致,固定不变)。
- 我们把 A 的 16 个 k 片段提到寄存器 ⇒ **A 载入 ≈ 0**;
- B 片段每条 MMA 取一次 ⇒ **B 载入 = MMA / TM**。

| 配比 | 每子组块数 | B 载入(百万条) | 相对现役 | 每 lane A 寄存器 | 每 lane 累加器 |
|---|---|---|---|---|---|
| **TM=1, TN=4(现役)** | 4 | **16.78** | 1.00× | 64 B | 32 B |
| TM=2, TN=2 | 4 | 8.39 | **0.50×** | 128 B | 32 B |
| TM=2, TN=4 | 8 | 8.39 | 0.50× | 128 B | 64 B |
| TM=4, TN=2 | 8 | 4.19 | **0.25×** | 256 B | 64 B |
| TM=4, TN=4 | 16 | 4.19 | 0.25× | 256 B | 128 B |

B 的 threadgroup 读流量:现役 16.78M × 128 B = **2.15 GB / 对**,8ms 内 ⇒ **~270 GB/s**。
(参照:on-core data BW 64 B/cycle × 18 核 × 1.4 GHz ≈ 1.6 TB/s;所以**不是带宽饱和**,
问题是**指令条数**:16.78M 条载入 + 16.78M 条 MMA。)

⚠️ **诚实的双模型**(必须靠实验裁决,不能先信一个):
- **模型 A(载入很便宜)**:按 102.5 FFMA/核-周期,一条 8×8×8 MMA 折合约 5 个核-周期,
  而一条 lane 级载入折合约 0.25 个核-周期 ⇒ 16.78M 条载入只占 MMA 时间的 ~6%。
  若成立,砍掉 75% 的载入只换来 ~4%,这条路基本无收益。
- **模型 B(WGSL 的载入很贵)**:tint 生成的 `subgroupMatrixLoad` 每条都带
  零填充 + 边界检查(我们已实测:关健壮性就值 −28%),即使关掉健壮性,
  它仍是"取地址 → `simdgroup_load` → 拷进新变量",不是 Metal 的原地 `simdgroup_load`。
  若成立,砍 50-75% 的载入是**超线性**地收窄我们与 Metal 的差(因为被砍掉的正是
  WGSL 比 Metal 贵的那部分)。
- 已知偏向模型 B 的证据:我们自己量到"关健壮性 −28%",而健壮性代码**主要长在载入路径上**;
  砍掉载入 = 连带砍掉剩下那部分健壮性/寄存器搬运。

**两个模型都由同一个廉价实验裁决**(第 5 节 P1),这就是这份调研能给的最有价值的一刀。

---

## 5. 具体重排方案(按"一次一个变量 + 阳性对照"排序)

### P0(必做,先于任何改核):两个阳性对照

**P0-a 纯 MMA roofline 微基准(WGSL 与 MSL 各一份,同机同窗)**
一个只有 `subgroupMatrixMultiplyAccumulate` 的循环(操作数常驻寄存器,**零载入**、零 barrier),
跑 16.78M 条,量 GPU 时间。产出:
- M3 Pro 上 8×8×8 MMA 的**真实**每核-周期吞吐(Turner 的 102.5 是 Apple 7/8,M3 未复量);
- **WGSL 的 MMA 指令本身是否就比 MSL 慢** —— 如果是,tile 重排的天花板立刻可算;
  如果不是(应该不是,tint 直发 `simdgroup_multiply_accumulate`),那 1.3-1.6× 全在载入/staging/扫描上。
这是整条战线的判据边界,**没有它,后面任何"预期收益"都是猜**。

**P0-b 每核共享内存池探针**
在现役核里加一个**从不被读**的 `var<workgroup> pad: array<f32, X>`,扫 X 使总量 = 16/20/24/28/32 KiB,
量 GPU p50。时间出现台阶的位置 = 每核池被 24→32 KiB 挤掉一个工作组的位置。
产出:每核共享池是 32 还是 64 KiB ⇒ 决定"并集复用"和"BT 32→64"值不值。
(⚠️ 死代码可能被 tint/Metal 优化掉 —— 必须 dump MSL 确认 `threadgroup` 声明还在,
这是我们自己踩过的"判据必须先过阳性对照"。)

### P1(第一刀,单变量,只动 B 载入条数):**子组 tile 8×32 → 16×16**

改动面**极小**:
- 工作组 tile **不变**(128 行 × 32 列)、线程数**不变**(512)、子组数**不变**(16)、
  共享内存布局**不变**(Bsh 8K + accSh 16K)、扫描/门/平局语义**一字不改**;
- 只把子组网格从 **16×1**(每子组 8 行 × 32 列)改成 **8×2**(每子组 16 行 × 16 列):
  - 子组 s:行块 = `s / 2`(16 行),列块 = `s % 2`(16 列);
  - A 片段:`array<Left, 2>` × 16 个 k(共 32 个)—— 每 lane 从 64 B 涨到 **128 B**;
  - 累加器:**仍是 4 块**(2×2),每 lane 仍 32 B;
  - 内层:每个 k 载 **2** 个 B 片段(而不是 4)、打 4 条 MMA。
- **MMA 条数 0 变化,累加器 0 变化,共享内存 0 变化,accSh 写入的地址集合 0 变化**
  (128×32 个 f32 还是那 128×32 个,只是由哪个子组写变了);
- **唯一变量:B 载入 16.78M → 8.39M(−50%)。**

判据:镜像 ABBA,GPU p50。
- 若 −8% 以上 ⇒ 模型 B 成立,继续 P2/P3;
- 若 −2% 以内 ⇒ 模型 A 成立,**整条 tile 重排线判死**,写进账本、撤净。
逐字节闸照旧(parity 19 · 全量闸 162+534 · guided 148/79k · ABI)。

### P2(P1 赢了才做):**Bsh 与 accSh 并集复用**(抄 llama.cpp WGSL 的 `max`)

现役是 `Bsh 8K + accSh 16K = 24K` **相加**;llama.cpp 的 WGSL 核是
`SHMEM_SIZE = max(A+B, ACC)`(mul_mat_subgroup_matrix.wgsl:80)。
我们的 tile 内相位是:`写 Bsh → barrier → MMA(Bsh 活,accSh 死)→ barrier →
subgroupMatrixStore 进 accSh + 扫描(accSh 活,Bsh 死)→ barrier → 下一 tile 写 Bsh`。
⇒ **两块在时间上不重叠,可以并到一个 `var<workgroup> shmem: array<f16, N>` 里**
(accSh 视图按 f32 用需要额外的类型处理 —— WGSL 不能对同一 `var<workgroup>` 开两种元素类型的视图,
所以实做上应该是 **统一声明成 `array<f32, 8192>` = 32 KiB 的一半 16 KiB**,
Bsh 借用其前 4096 个 f32 存 8192 个 f16(需要手工 pack/unpack)—— **这是实现风险点,
如果 pack 成本 > 省下的 occupancy,就退回不做**)。
- 收益:24 KiB → **16 KiB**;若 P0-b 显示每核池是 32 KiB,则驻留工作组 1 → 2(16 → 32 simds),
  跨过 24 simds 的 ALU 饱和点,预期是这份方案里**最大的一块**;
- 若 P0-b 显示池是 64 KiB(24K 时已驻留 2 个),则本刀几乎无收益,**不做**。
- 🔴 依赖:必须先确认 db 软件流水的预取目标是**寄存器**而不是 Bsh 的第二半;
  若预取直接写 Bsh,则 Bsh 在扫描期仍活,**并集不成立**(去读 TU 的实际相位,别猜)。

### P3(结构刀,P1+P2 都赢才做):**BT 32 → 64,列 tile 翻倍**

`2026-09-03-mixed-mma-result.md` 把它按 `accSh 32K + Bsh 16K = 48K 超限` 判死了 ——
**那是按"相加"算的**。若 P2 的并集成立:`max(16K, 32K) = 32K`,**正好压线可行**。
- 工作组 tile 128 行 × 64 列;16 子组网格 8×2 ⇒ 每子组 16 行 × 32 列 = TM=2 × TN=4 = **8 块**;
- B 载入 = 16.78M/2 = 8.39M(与 P1 同),但 **tile 数 256 → 128 ⇒ barrier 数减半**
  (这正是原文档想要的第二把刀);
- 代价:共享内存 32 KiB 顶满 ⇒ 每核驻留可能掉到 1 个工作组。**与 P2 的收益直接冲突**,
  必须在 P0-b 的池尺寸已知之后再决定;若池 = 64 KiB 则仍可驻留 2 个,这刀纯赚。

### P4(独立于 P1-P3,可并行试):**Bsh 换成"8×8 片段连续"布局**

抄 llama.cpp Metal 核(`mul_mm.metal:226-228 / 264-266`):把 Bsh 从"行主 + stride"改成
"每个 8×8 片段 64 个元素连续、片段按 (k 片, 列片) 排",`subgroupMatrixLoad` 的 stride 传 **8**。
- 动机:我们实测"stride 填充无效",而 M3 的 shared memory 行为公开无解释(3.4 节);
  片段连续布局让每次片段读退化成 **128 字节线性突发**,**绕开整个 bank 问题**;
- 代价:staging 写入端的地址计算变复杂(llama.cpp 用 `ib = 8*sx + sy` + `64*ib + 8*ly + lx`);
- 风险:我们已实测 "vec4<f16> staging 反向(慢 3.0ms)",原因是 **写共享内存那侧仍是标量**;
  片段布局同样只改地址不改写宽度,**可能同样无效**。列为低优先级,但成本低、值得一试。

### 明确不建议做的

- ❌ 换 MMA 数据类型找吞吐(f16 与 f32 在 M3 上同价,3.1 节);
- ❌ 按 bank 数补 stride(Apple 无公开 bank 模型,M3 行为反常,3.4 节);
- ❌ 去掉软件流水改成 MLX/llama.cpp 的"单缓冲 + 两 barrier"(我们的 db 已实测有效,
  业界没做只说明它不是必需,不说明它是负的);
- ❌ 每子组 16 块以上(TM=4):A 常驻寄存器的设计下每 lane 要 256 B,
  1024 线程就要 256 KB > ~208 KB 寄存器文件 ⇒ 必溢出。若要走 TM=4 必须先改成
  "A 也分 K 块从共享内存现取"(= MLX/llama.cpp 的形态),那是重写不是重排,**不在本轮**。

---

## 6. 同类任务的公开最优实现(part 3)

**结论:公开世界里没有"比我们更快的 Apple GPU 描述子匹配器"可抄;
业界的做法就是"把暴力匹配化归成 GEMM",我们已经在做,而且已经用上了 MMA。**

| 实现 | 做法 | 与我们的关系 | License |
|---|---|---|---|
| **COLMAP / SiftGPU** `src/thirdparty/SiftGPU/SiftMatch.cpp:122-129, 291-297` | GLSL **片元着色器**,把点积矩阵渲染进 `_texDot` 纹理(`__max_sift × __max_sift`),再两趟取 top-2 | 2007 年的形态,无 MMA、无 threadgroup tiling、受纹理尺寸限制(`__max_sift/16` 行)⇒ **不是性能对照物**,只是我们已经超越的起点 | SiftGPU 自有许可(**非 BSD/MIT,禁止逐字节 port**) |
| **OpenCV `cuda::BFMatcher`** | 手写 CUDA 分块 L2/Hamming,无 tensor core | 同上,结构比我们旧 | Apache-2.0 |
| **FAISS `bfKnn`** | 精确 L2/IP **化归成 GEMM(cuBLAS)+ top-k 归约**,`‖a−b‖² = ‖a‖² + ‖b‖² − 2aᵀb` | **与我们的架构完全一致**;它的"最优"就等于 cuBLAS 的最优 ⇒ 印证"匹配器的上限 = 该平台 GEMM 的上限" | MIT |
| **CudaSIFT** | GPU 暴力匹配,单对 ~5ms(RTX 级) | 不同硬件,不可比 | 自有(可商用需核) |
| **PopSift** | 提取为主,匹配为 demo | 无参考价值 | MPL-2.0 |

**量级换算(供对账)**:我们 8192×8192×128 = 8.59 GMAC / 对。
- 手写 Metal 4.9ms ⇒ **1.75 TMAC/s**;混合 WGSL 8.0ms ⇒ 1.07 TMAC/s。
- FAISS 论文口径的"4×Titan X 上 9500 万张 128D 图片做 k=10 暴力 kNN 用 35 分钟"
  ⇒ 换算约 95e6 × 95e6 … 不可直接对账(它是分块 + 近似流水),**不作为标尺**。
- 唯一可信的标尺仍是 **3.2 节的 matrix roofline**:M3 Pro 的 3.3ms 理论下限,
  Metal 已到 62-68%,这已经是 Apple GPU 上公开可见的最好水平(Rigel 在 M4 Max 上量到 46%)。

---

## 7. 未查到 / 不确定(单列,不许当结论用)

1. **M3(Apple 9)的 simdgroup_matrix 每核-周期吞吐没有公开复量。** metal-benchmarks 的
   102.5/101.7 是 Apple 7/8(A15/M1/M2)。Dynamic Caching 对寄存器/共享内存的分配也改了模型。
   ⇒ 第 3.2 节的 3.3ms 下限是**外推**,必须用 P0-a 自测替换。
2. **Apple threadgroup 内存的 bank 结构:M1 = 32 banks(第三方微基准),M3 = 未知。**
   metal-benchmarks 明写 TBD;leman 的 M3 数据自相矛盾(store-only 有 conflict 迹象、
   load-accumulate 偶数 stride 惩罚、stride 32 反而最快),作者自述 "I have no idea"。
3. **Apple threadgroup 内存的每核物理池大小。** metal-benchmarks 给 "~60 KB / 核"(Apple 7,8),
   Metal 的**每工作组**上限是 32 KiB。两者关系(能否驻留 2 个 24 KiB 工作组)**没有官方文档**,
   必须用 P0-b 自测。
4. **Apple 官方从未给过 simdgroup_matrix 的 tile/寄存器调优建议。** Tech Talk 10858 只有端到端
   百分比;WWDC26 session 330 只有"切 tile、用 cooperative tensor 少走 threadgroup"的定性说法,
   并把细节推给 "Metal Performance Primitives Programming Guide"(未取到该 PDF 正文)。
5. **MPS / MPSGraph 在 M 系列上的官方 TFLOPS 口径未取到。** 第三方(arXiv 2502.05317,
   PDF 文本抽取失败,数字来自二手检索摘要,**未打到源头**):MPS 在 M3 上 2.47 TFLOPS、
   M4 上 2.9 TFLOPS,Cutlass 风格自写 Metal 只有 0.27/0.34 TFLOPS。
   🔴 **这组数没验源,不要引用**;若要用必须自己下 PDF 核。
6. **中/日/俄社区**:知乎/CSDN、Zenn/Qiita、Habr 上**没有找到** Apple GPU simdgroup_matrix
   的 tile 调优一手材料(搜到的都是通用 CUDA tiling 或 CPU SIMD)。这条线**空手**。
   唯一有价值的非英文源是 techboards.net 论坛的 M3 shared memory 微基准(英文)。
7. **`air.simdgroup_async_copy_2d`**(Apple 自家 MPS GEMM 用的 device→threadgroup 异步拷贝,
   类比 `cp.async`)是**私有指令**,Xcode 14.3 后连 `__asm("@air.symbol")` 都拿不到。
   ⇒ Apple 自己的 GEMM 有一条我们和 MLX/llama.cpp 都用不上的快车道。这是"永远追不平"的
   一部分理由,但**与我们和手写 Metal 的差无关**(手写 Metal 也用不上)。
8. **我们 TU 里 db 软件流水的预取目标(寄存器 vs Bsh 第二半)本文没读源码确认**,
   P2 的并集复用**成立与否取决于它**。动手前必须读 `pwofficial_gpu_match_dawn.cc` 的实际相位。

---

## 8. 一页纸给用户的判断

- 业界共识非常清楚:**每子组 8-16 个 8×8 累加块**(MLX 小设备档 8、llama.cpp Metal 8、
  llama.cpp WGSL 8、Vulkan 16),**我们是 4**,而且因为 A 全在寄存器,
  我们的 B 片段复用次数 = TM = **1**(业界 2-8)。这是**唯一一条还没试过的结构性杠杆**。
- 但**它到底值不值钱,取决于 WGSL 的 `subgroupMatrixLoad` 有多贵**,而这一点我们只有间接证据
  (关健壮性 −28%)。所以本方案的第一步不是改结构,是 **P0 两个阳性对照 + P1 一个
  零副作用的单变量探针(子组 tile 8×32 → 16×16,只砍 50% 载入,其余一字不改)**。
- 外部标尺给了两条硬边界:
  (a) 另一支团队的 WGSL matmul 在 M3 上对 Metal 也是 **1.35×** —— 我们的 1.3-1.6× 是**行业常态**,
      不是我们写坏了;
  (b) Apple GPU 上矩阵路径的公开最好水平是 **~46-68% of roofline**,手写 Metal 已在其中,
      **"超越 Metal"没有公开路径**。
- 所有可抄的源(MLX / llama.cpp 全家)都是 **MIT**,**允许逐字节 port**。
  唯一需要回避的是 SiftGPU(非 BSD/MIT)。

---

## 附录:源头 URL(每条都亲手取过正文/源码)

**源码(全部从上游 HEAD 直取,本地读过)**
- MLX `@b6368984b8e0`(2026-09-03,MIT)
  - https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/steel/gemm/mma.h
  - https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/steel/gemm/gemm.h
  - https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/steel/gemm/loader.h
  - https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/matmul.cpp
- llama.cpp `@d30500b83b0f`(2026-09-03,MIT)
  - https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/kernels/mul_mm.metal
  - https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-webgpu/wgsl-shaders/mul_mat_subgroup_matrix.wgsl
  - https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-webgpu/ggml-webgpu-shader-lib.hpp
  - https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-vulkan/vulkan-shaders/mul_mm.comp
  - https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-vulkan/ggml-vulkan.cpp
- COLMAP / SiftGPU:https://github.com/colmap/colmap/blob/main/src/thirdparty/SiftGPU/SiftMatch.cpp

**架构与实测**
- Philip Turner, metal-benchmarks(MIT):https://github.com/philipturner/metal-benchmarks
- Philip Turner, metal-flash-attention(MIT,M1 Max 83% ALU 利用率的注记):
  https://github.com/philipturner/metal-flash-attention
- M3 threadgroup 内存微基准(leman):
  https://techboards.net/threads/the-mystery-of-apple-m3-on-chip-shared-memory.4452/
- `air.simdgroup_async_copy_2d`(Apple MPS 私有指令):
  https://github.com/dougallj/applegpu/issues/28
- Rigel: Reverse-Engineering the Metal 4.1 Tensor Compute Path on the Apple M4 Max GPU:
  https://arxiv.org/html/2606.12765v1
- BaseRT(M5 Neural Accelerators):https://arxiv.org/html/2607.19438v1
- A19/M5 Neural Accelerator 实测:https://tzakharko.github.io/apple-neural-accelerators-benchmark/

**WGSL/Metal 比值的外部对照**
- llama.cpp PR #17031(WebGPU matmul,M3 上 WebGPU 1014 vs Metal 1368 t/s):
  https://github.com/ggml-org/llama.cpp/pull/17031
- candle issue #3302(固定 tile 的反例):https://github.com/huggingface/candle/issues/3302

**Apple 官方**
- Tech Talk 10858 "Discover Metal enhancements for A14 Bionic":
  https://developer.apple.com/videos/play/tech-talks/10858/
- WWDC26 session 330 "Optimize custom machine learning operations with Metal tensors":
  https://developer.apple.com/videos/play/wwdc2026/330/
