# 特征提取提速与压缩调研(A16 端上 GPU DSP-SIFT)

日期:2026-07-29
对象:`aether_cpp/tools/sift_extract_dawn.cc` + `dawn_kernel_harness.cpp`(Dawn/WGSL,iPhone 14 Pro / A16)
基线:提取 1267 ms/帧(占逐帧流式 45%);desc 390 / ori 272 / pyr 168 / det 168 / aff 130 / pack 101 / sup 50 / rb 4 / clamp 3

证据标签:【实测】=真机或本仓 harness 实测;【源码】=我本次实际读过的代码行;【官方文档】;【论文】;【推断】=我的推理,未验证。

---

## 0. 执行摘要

**七条最重要的结论,按重要性:**

1. **【压缩问题基本已经没了】** 描述子在入库前已被量化成 **uint8 128 维**(COLMAP `types.h:102-108`)。f16 比它**还大**,而且 f16 在我方 shader 里早就是 A16 生产默认。【实测】uint8 里也没有冗余可榨:8→7 bit 就改 2.07% 的匹配,8→6 bit 改 8.3%。**PCA/PQ/二值化整类死路**,详见第 8.1 节。真实的"压缩"只剩一条:回读通道现在传 f32,是 4× 冗余(Q2.1)。

2. **【Q1 前提要修正,但方向对】** `sup/aff/ori/desc` **不能直接合批** —— 四段之间夹着 5 次强制 GPU→CPU 回读 + host 串行改写 + 重新上传。真正的杠杆不是 `begin_batch()`,而是**删掉这 5 次往返**;本仓已有全部原语(`prefix_sum_*.wgsl`、`dispatch_indirect`)只是没接。规范侧完全允许合批:同一 compute pass 内的多次 dispatch **有隐式屏障**(Dawn 技术负责人原话)。

3. **【最高杠杆是两条逐位一致的免费项】**
   - **Q5-E**:一个只依赖 patch 坐标的**常量**高斯掩膜被逐关键点逐像素重算 —— `ori` 每帧 ~13.8M 次 `exp()`,`aff` 最坏 ~207M 次。预计算成 1681 项表(6.6 KB)即可。
   - **Q5-A**:`aff`+`ori`(402 ms)跑在 ~21002 个检测点上,而 COLMAP 的 clamp 只按 `(octave, scale)` 保留 ~11881 个。排序键与 affine/orientation **无关**,所以"任何方向数下都必死"的最细 (o,s) 组可以在 affine 之前剪掉,**输出逐字节不变**,而且直方图能挂在已有的 `det_counter` 回读上,**零新增往返**。

4. **【`ori` 272 ms 不是异常,别为它单独开战役】** 我中途提出的 occupancy 假设被三条独立证据推翻(见 6.8):按 patch-像素归一 `ori` 比 `desc` 还便宜;横向对比 21% 低于每一条已发表基线(DASIP 28.1% / Wang 33.7% / Rice 37-53%)。它贵是因为**算了太多注定被丢的点** → 正解是第 3 条的剪枝。

5. **【框架修正:带宽,不是算力】**【推断】8 MP 端上 SIFT 需要 ~1.5 TB/s 带宽而 A16 差 1-2 个数量级。这抬高了所有减少内存流量的动作(每帧新分配的 160-320 MB 金字塔拷贝、4.7 MB 零填充上传、4× 冗余回读、blur 无 tile 缓存),压低了所有"加并行度"的动作(你们已实测 scale-parallel 慢 44%)。

6. **【换提取器:几乎全军覆没,但下游比你以为的现代】** SuperPoint 全系(含"干净"镜像)、R2D2、SURF、PopSift/CudaSift/ArrayFire 全部出局,理由各不相同(见第 8.2 节)。唯一干净的是 **ALIKE**(BSD-3 三件套齐)。⚠️ 但 **vendored COLMAP 4.1.x 里已经内建 ALIKED + LightGlue + ONNX**,只是我方 iOS 构建没编进去 —— 这改变了"换前端的下游代价"的整个估算。

7. **【三处文档/记忆错误,会误导下一个人】** `first_octave` 的两份矛盾记录我调和了(6.3,答案是"两份都对,因为输入分辨率不同");SCALE-6 的 header 论证**算错了**且掩盖了一次真实质量变化(6.14);记忆库"RS 4 万特征预算"应更正为"检测 4 万、进匹配 1 万"(6.11)。

**⚠️ 第 0 号动作是装 GPU 侧 `timestamp-query`。** 现在那 9 个数字是 host 墙钟,把 host 循环 / 上传 / 阻塞回读 / GPU 真算全混在一起,而上面大半条建议优化的恰恰是被混进去的非 GPU 部分。没有它,你分不清"省了 100 ms"和"什么也没省"。

---

## Q1 — Dawn/WGSL 的 dispatch 批处理与同步

### Q1.1 规范语义:同一个 compute pass 内多次 dispatch 之间有没有隐式屏障?

**有。可以合批,即使有数据依赖。**

- 【官方文档】WebGPU 规范:"In a compute pass, each dispatch command … is one usage scope."
  https://gpuweb.github.io/gpuweb/#programming-model-synchronization
- 【官方文档】Dawn 技术负责人 Corentin Wallez(Kangz)在规范仓的回答:dispatch 各自是同步作用域,内存语义"as-if they were run serially";实现应当只在**没有写冲突**时才并行化。
  https://github.com/gpuweb/gpuweb/discussions/4434
- 同帖 greggman(WebGPU 维护者):"WebGPU handles this for you. There is no need to manually synchronize."

**对我方的意义:WGSL/WebGPU 没有、也不需要显式 barrier API。**串行依赖的 SIFT 各段可以编码进同一个 command encoder(甚至同一个 compute pass),Dawn 自动插入后端屏障。本仓 `begin_batch()` 的注释里已经写对了这一点(【源码】`dawn_kernel_harness.h:103-111`:"Dawn 自动 hazard 追踪 → bit-identical"),且金字塔段已经这么用了。

**代价提示**:实现侧的 hazard 追踪是 per-dispatch × per-resource 的,资源极多时 CPU 编码成本会爆(wgpu 实测:1000 dispatch × 6000 资源 = 140 ms 编码;10000 dispatch × 6 资源 = 19 ms)。
https://github.com/gfx-rs/wgpu/issues/5766
我方每个 pass 只有 4-7 个 binding,**不在这个坑里**。

### Q1.2 「减少 submit」的官方推荐与开销数据

- 【官方文档】Apple Metal 最佳实践,原文:"Submit the fewest possible command buffers per frame without underutilizing the GPU",并明确 preferably one per frame;并指出更频繁提交会 "introduce CPU stalls caused by CPU-GPU synchronization"。
  https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html
- 【官方文档】`wgpuInstanceWaitAny` 语义:timeout 非 0 时**阻塞调用线程**直到至少一个 future 完成。
  https://webgpu-native.github.io/webgpu-headers/Asynchronous-Operations.html
- 我没有找到 Dawn 官方发布的 submit/WaitAny 微基准数字。网上流传的「Metal 提交开销 10-50 µs」只出现在低可信度的二手博客上,**我不采信,不作为依据**。

**最可靠的量化证据是你们自己的**:【实测】库回归中批处理过的 `pyr` 只涨 ×1.19,逐次同步的 `sup`/`ori`/`aff` 涨 ×2.1-3.4。这与「每次 dispatch 都 submit+阻塞等 = CPU 与 GPU 完全串行化」的模型一致:开销不是加性的固定 µs,而是**乘性的流水线塌陷**。

### Q1.3 ⛔ 关键修正:sup/aff/ori/desc 现在**不能**直接合批

【源码】读 `aether_cpp/tools/sift_extract_dawn.cc` 后的真实拓扑 —— 四段之间不是"裸 dispatch 挨着裸 dispatch",而是每一对之间都夹着 host 往返:

| 位置 | 中间发生了什么 | 阻断原因 |
|---|---|---|
| `sup` → `aff` | `read_u32(det_buf)` + `read_u32(keep_buf)` → **host 串行压缩循环**(按 keep 标志紧凑化)→ upload `aff_in_buf` (`:238-268`) | 数据依赖的流压缩在 host 上做 |
| `aff` → `ori` | `read_u32(ell_buf)` → **host 重打包循环**(把椭圆 a11..a22 合进 kp 记录 + NaN 检查)→ upload `ori_in_buf` (`:290-331`) | 纯算术改写,但在 host |
| `ori` → `clamp` | `read_u32(ori_counter, 1)` —— **为了 4 个字节做一次完整 GPU→CPU 往返**(`:365`) | 下一段的 workgroup 数与 buffer 尺寸依赖它 |
| `clamp` | `read_u32(ori_out_buf, n×8)`(~0.7 MB)→ **host std::sort** → 重新 upload (`:383-421`) | 排序在 host |

所以 `harness.begin_batch()` 包起来会**直接产生错误结果**(bind 的 buffer 内容还没生成)。这是我对你陈述的第一处纠正,写在第 6 节。

**但结论方向不变、力度更大**:这 5 次往返每次都是 `MapAsync + WaitAny` 全阻塞(【源码】`dawn_kernel_harness.cpp` `readback()`),而且每次 `read_u32` 都**新建一个 staging buffer**(`alloc_staging_for_readback` 每调用一次 `device_.CreateBuffer`),没有复用池。

### Q1.4 Q1 的可执行动作(按顺序)

**A1 — 先装 GPU 侧计时,别盲优化。**
现在 9 个 `mark()` 用的是 `std::chrono` host 墙钟(【源码】`sift_extract_dawn.cc:127-135`),它把「host 循环 + upload + 回读阻塞 + GPU 真算」全部混在一个数字里。**`ori`=272 ms 里有多少是 GPU、多少是那 2.5 MB 零填充上传(`ori_out_init` 65536×8 u32 = 2 MB + `dbg_init` 512 KB,每帧在 host memset 后上传,`:335-343`)和 4 字节回读,目前完全未知。**

WebGPU `timestamp-query` 的 **pass 边界写入(`timestampWrites`)在 Apple Silicon 上是可用的** —— TBDR 不支持的是 pass *内部* 的 `writeTimestamp()`(Metal `atDispatchBoundary/atDrawBoundary` 返回 false),但 `atStageBoundary` 返回 true,pass 首尾正好落在 stage boundary。
https://github.com/gpuweb/gpuweb/issues/2046
https://developer.chrome.com/blog/new-in-webgpu-121
harness 目前只请求了 `Subgroups` + `ShaderF16`(【源码】`dawn_kernel_harness.cpp:186-191`),需加 `wgpu::FeatureName::TimestampQuery`。
【预计收益】0 ms,但**这是后面所有条目的先决条件**。【无损】【跨端:是,WebGPU 标准 feature,需 `hasFeature` 守门】【许可:自研】【成本:小】【证据:官方文档】

**A2 — 消掉 `ori→clamp` 的 4 字节往返:改 indirect dispatch。**
`dispatch_indirect` 已经在 harness 里(【源码】`dawn_kernel_harness.cpp`),而且 `alloc_indirect_storage` 的注释明确说这个 buffer 既能当 compute storage 写又能当 indirect 源 —— 就是为这个场景设计的,只是 descriptor 段没用。让 `ori` 直接把 workgroup 数写进 indirect buffer,`desc` 用 `DispatchWorkgroupsIndirect` 起飞。
【预计收益】省 1 次全阻塞往返 + 1 次 staging 分配;绝对值待 A1 测出【无损:逐位一致】【跨端:是】【成本:小】【证据:源码 + 官方文档】

**A3 — 把 `sup` 后的 host 压缩搬上 GPU。**
本仓**已经有** `shaders/wgsl/prefix_sum_scan.wgsl` / `prefix_sum_scan_sums.wgsl` / `prefix_sum_add_scanned_sums.wgsl`(【源码】`aether_cpp/shaders/wgsl/`),标准 scan-based stream compaction 三件套齐全。接上后 `sup→aff` 变成纯 GPU,可与 `det` 合进同一个 encoder。
【预计收益】省 2 次回读(`det_buf` n×8 u32 + `keep_buf` n×1 u32,~0.7 MB)+ host 循环;`sup`=50 ms 里大概率大部分是这个【无损:压缩是稳定的顺序保持,可逐位验】【跨端:是】【成本:中】【证据:源码】

**A4 — 融合 `aff` + `ori` 成一个 kernel。**
【源码】两个 shader 结构几乎同构:都是 `@workgroup_size(64)`、一个 workgroup 一个关键点、都常驻 `var<workgroup> wpatch: array<f32,1681>`(41×41)、都从同一个 `packed` 金字塔跨-octave warp 采样。中间那段 host 重打包(`:300-327`)是**纯算术**,完全可以在 shader 里做。
⚠️ 注意:不能共用同一份 patch —— `aff` 迭代收敛出 A 之后,`ori` 用的是 SVD 分解出的 `A_ud = U·D` 重新 warp(【源码】`sift_orientation.wgsl:69`),几何不同。所以收益来自**消掉一次往返 + 一次 21002×32B 的上传/下载 + 一次 kernel 启动**,不是省掉 patch 采样。
【预计收益】省 1 次往返 + host 循环;GPU 计算量基本不变【无损】【跨端:是】【成本:中-大(要合并两个各 300-430 行的 shader)】【证据:源码】

**A4b — `dispatch_batched()` 现在每个 dispatch 都开一个新 compute pass,应该合成一个 pass。**
【源码】`dawn_kernel_harness.cpp` `dispatch_batched()` 里每次调用都 `batch_encoder_.BeginComputePass() … pass.End()`。金字塔那 ~80 个 blur 因此变成**一个 command buffer 里 ~80 个 compute pass**。
Metal 侧唯一能编码 dispatch 的对象是 `MTLComputeCommandEncoder`,所以每个 WebGPU compute pass 至少对应一次 encoder 开关(【推断】,我没能从 Dawn 官方文档直接确认这个映射,只能从 Metal API 的构造约束推)。而由 Q1.1,**同一个 pass 内的多次 `DispatchWorkgroups` 已经有隐式同步**,把 pipeline/bindgroup 切换留在 pass 内即可,完全不需要每次新开 pass。
改法:`dispatch_batched` 接受可选的"沿用当前 pass"模式,在 `begin_batch()` 里开一次 pass,`end_batch()` 里 `End()`。
【预计收益】金字塔段(pyr 168 + pack 101)上最明显;绝对值待 A1 测【无损:Dawn 仍自动做 hazard 追踪】【跨端:是】【成本:小】【证据:源码 + 官方文档(隐式屏障) + 推断(Metal 映射)】

**A5 — staging buffer 池化。**
`alloc_staging_for_readback` 每次都 `CreateBuffer`(【源码】`dawn_kernel_harness.cpp`)。描述子回读那次是 ~6 MB(11881×128×4),每帧新建新释放。改成按尺寸分档的复用池。
【预计收益】小,但零风险【无损】【跨端:是】【成本:小】

**A6 — 每帧 ~4.7 MB 的 host 零填充 + 上传,几乎全是纯浪费。**
【源码】逐个数出来(`sift_extract_dawn.h:101-102` 给出 cap):

| buffer | 尺寸 | 位置 | 真的需要清零吗? |
|---|---|---|---|
| `det_init` | `kDetectCap` 48000 × 8 u32 = **1.54 MB** | `:160` | **不需要** —— 槽位由 atomic append 先写后读 |
| `ori_out_init` | `kOrientCap` 65536 × 8 u32 = **2.10 MB** | `:335` | **不需要** —— 同上 |
| `dbg_init` | 65536 × 2 f32 = **0.52 MB** | `:340` | **`dbg_buf` 是 Stage D 的调试残留,应该直接删** |
| `ell_init` | n_kept × 5 f32 ≈ **0.42 MB** | `:271` | 由 affine kernel 全写 |
| `keep_init` | n_detect u32 ≈ 84 KB(填 1 不是 0) | `:233` | 需要,但可用 clear kernel |

合计每帧 **~4.7 MB 的 host `std::vector` 分配 + memset + memcpy 进上传路径**。改成**持久 buffer + 只清 4 字节计数器**即可,绝大部分连 clear kernel 都不需要。
⚠️ 顺带:`dbg_buf` 这个调试 binding 还在 `sift_orientation.wgsl` 的 bind group 里占位。历史记录显示 descriptor kernel 的 `dbg_patch` 已经清掉过一次(要同步改 binding 编号 + orchestrator + 所有 parity driver),orientation 这个是同一类残留、同样的清理手法。
【预计收益】省 ~4.7 MB/帧 host memset + upload;分布在 `det`(168)、`aff`(130)、`ori`(272)三段里【无损】【跨端:是】【成本:小】【证据:源码】

---

## Q2 — 描述子"压缩":先钉死一个事实,它让半个问题消失

### Q2.0 我方描述子最终是什么精度?**uint8,128 字节。**

【源码】vendored COLMAP `colmap/feature/types.h:102-108`:

```
using FeatureDescriptor  = Eigen::Matrix<uint8_t, 1, Eigen::Dynamic, Eigen::RowMajor>;
using FeatureDescriptorsData = Eigen::Matrix<uint8_t, Eigen::Dynamic, Eigen::Dynamic, Eigen::RowMajor>;
```
【源码】`sift.cc:67-68`:`// SIFT descriptors are normalized to length 512 (w/ quantization errors)` / `constexpr int kSqSiftDescriptorNorm = 512 * 512;`

【源码】我方 `official_pipeline/src/official_dsp_sift_gpu_c.cc:71-87` `finish_descriptor()`:GPU 回读 f32 raw → **L1RootNormalize → `round(512 * root[i])` → clamp → uint8 → VLFeat→UBC bin 重排**。

**推论(这条决定了 Q2(a) 的大部分答案)**:

1. **描述子在进入匹配之前已经被量化到 8 bit/维。** 任何"把描述子变成 f16"的方案对下游 **零收益** —— f16 是 2 字节/维,比现状的 1 字节/维**还大**。我方那个 `sift_dsp_descriptor_f16_wgsl.o` 的价值**纯粹在 shader 内部的算术吞吐**(A16 上 1578→1425 ms,~10%),与"描述子压缩"无关,不要把两件事混为一谈。
2. **PCA-SIFT / PQ / 二值化 的"省带宽"论点在我方已经被 uint8 吃掉了大半。** 128 B/描述子已经是 SIFT 生态的实际下限;再往下压就要改 COLMAP 的 `FeatureDescriptorsData` 类型、数据库 schema、以及我方 GPU matcher 的 packed-u8 ABI —— 这是**改下游**,不是改提取器。
3. **ratio test 的语义前提**:Lowe ratio 0.8 依赖的是**真实**最近/次近距离比。PQ 给的是**近似**距离,近似误差直接污染 ratio 判据;二值描述子换成 Hamming 距离后,0.8 这个阈值的标定完全失效(需要重新标定,且 COLMAP 的 `cross_check` + 后续几何验证阈值都建立在 SIFT 距离分布上)。**这不是"换个描述子"级别的改动,是重标定整条前端。**

### Q2.0b 【实测】uint8 里到底还有多少冗余?—— 答案:很少,这条硬约束不依赖任何论文

我们在真实库(`latest_capture_414/.../database.db`,5362 个描述子)上直接量了:

- 值域 min **0** / max **187**;`==255` 出现率 **0.000000**(**clamp-255 在生产中从未触发**);per-descriptor max 的 p99 = 159 → 实际只用了约 **180/256 个离散值 ≈ 7.5 bit**
- 隐含 L2 范数 p50 = **1.0000**(证实 RootSIFT → 单位范数 → ×512 这条链自洽)

**粗量化敏感度**(真实描述子,COLMAP 语义 ratio 0.8 + max_dist 0.7,量匹配集合变化率):

| 量化 | 匹配集合变化 |
|---|---|
| 8 → 7 bit | **2.07%** |
| 8 → 6 bit | **8.3%** |
| 8 → 5 bit | 14.5% |
| 8 → 4 bit | 23.7% |

**→ uint8 并没有大量冗余。任何低于 8 bit 的压缩(PQ / 二值化 / 降维)都会直接改变匹配结果。** 这是对 Q2(a) 整类方案的硬约束,而且是我们自己数据量出来的,不需要引任何论文。

### Q2.0c 匹配侧的两个反直觉事实(会改变你对"换描述子"的成本估计)

【源码】COLMAP GPU/CPU 匹配用的是 **uint8 整数点积**,不是浮点:SiftGPU CUDA kernel(`ProgramCU.cu:1453-1466`)用 `IMUL(p1[k],p2[k])` 累进 `int results[]`;CPU 路径先 `.cast<int>()` 再 `dot()`。

【源码】⚠️ **比值检验实际作用在角度上,不是 L2 距离上**:`d = acos(dot / 512²)`,再判 `best >= max_ratio * second`。COLMAP 注释写的是 "Convert to L2 distance",但算的是 `acos`。
**这对"换成近似距离(PQ)或汉明距离后 ratio 0.8 还成不成立"是决定性前提** —— 0.8 这个阈值是标定在 **acos 角度比**上的,不是欧氏距离比。任何换描述子度量的方案都必须重新标定,而不是"沿用 0.8"。

一手佐证:DISK 官方 matcher 的默认 ratio 是 **0.95** 而不是 0.8 —— 这本身就是"0.8 不能跨描述子直接搬"的证据。

### Q2.1 一条真实的、无损的"压缩"机会:回读通道是 4× 冗余的

【源码】`sift_extract_dawn.cc:518`:`rbytes = n_oriented * 128 * sizeof(float)` —— 我们从 GPU **回读 f32**(11881 × 128 × 4 ≈ 6.1 MB),然后在 host 上做 L1Root(**每帧 ~1.5M 次 `sqrt`**)+ round + 重排,压成 1.5 MB 的 uint8。

把 `L1RootNormalize + round(512) + UBC 重排` 挪进描述子 shader 的收尾(shader 内保持 f32 算这一段以保证同序同精度):
- 回读 6.1 MB → **1.5 MB**(4×)
- 干掉每帧 1.5M 次 host sqrt + 1.5M 次 round

⚠️ 注意:`finish_descriptor()` 在 `official_dsp_sift_gpu_c.cc` 里,**在那 9 个 `mark()` 之外** —— 也就是说它的耗时**根本不在你那张 1267 ms 分账表里**。9 段相加 = 1286 ms ≈ 1267 ms,说明这张表已经覆盖了 `sift_extract_dawn.cc` 的全部,`finish_descriptor` 是**额外的、未计量的**开销。先量它。

【预计收益】回读 -4.6 MB + 干掉 1.5M host sqrt;绝对值未测【**无损:同序 f32 运算可逐字节验**】【跨端:是】【许可:自研】【成本:小-中(shader 收尾 + 重排索引表)】【证据:源码】

### Q2.2 RootSIFT 已经在用,不是可选项

【源码】COLMAP 默认 `normalization = Normalization::L1_ROOT`(`sift.h:98`),我方 `finish_descriptor` 也走 L1Root。所以 RootSIFT(Arandjelović & Zisserman, CVPR 2012)**已经吃满了**,不是待开发的杠杆。

---

## Q3 — 更快的可商用提取器:逐仓读 LICENSE 原文

### Q3.0 头条:vendored COLMAP 4.1.x **已经内建 ALIKED + LightGlue**

【源码】`colmap/feature/types.h:42-50` 的枚举:
- 提取器:`UNDEFINED, SIFT, ALIKED_N16ROT, ALIKED_N32`
- 匹配器:`UNDEFINED, SIFT_BRUTEFORCE, SIFT_LIGHTGLUE, ALIKED_BRUTEFORCE, ALIKED_LIGHTGLUE`

`colmap/feature/aliked.cc`、`onnx_matchers.cc`、`onnx_utils.h`(`#include <onnxruntime_cxx_api.h>`)都已在树内,`resources.h` 硬编码模型 URI 指向 `github.com/colmap/colmap/releases/download/3.13.0/{aliked-n16rot,aliked-n32,aliked-lightglue,sift-lightglue,bruteforce-matcher}.onnx`,整条链由 CMake `ONNX_ENABLED` 门控。

【源码】我方 iOS 构建产物核对(`build-ios-device/CMakeFiles/pwofficial_core.dir/`):只有 `VLFeat/sift.c.o`、`VLFeat/dsift.c.o`、`colmap/feature/sift.cc.o`、`official_dsp_sift_c.cc.o` —— **没有任何 aliked/onnx 目标文件,也没有 SiftGPU 目标文件**。

**两个推论**:① 若要换 ALIKED,下游改造成本 ≈ 0(官方已实现);换任何别的候选都要自己加枚举 + 提取器 + 匹配器。② **NC 的 SiftGPU 目前没有被链进出货二进制**(好消息),但这是构建配置的偶然结果,**应该在 CI 加断言钉死**。

### Q3.1 下游对非 SIFT 描述子的真实支持(retrofit cost)

| 通路 | 结论 |
|---|---|
| `feature_importer` | 🔴 **SIFT 专用**。【源码】`controllers/feature_extraction.cc:633` 调 `LoadSiftFeaturesFromTextFile`;`feature/sift.cc:1595` 硬断言 `THROW_CHECK_EQ(dim, kSiftDescriptorDim)`(=128),并硬写 `type = FeatureExtractorType::SIFT`。**非 128 维走不通** |
| `matches_importer` | ✅ 存在,可绕过描述子直接灌 matches + TVG |
| `image_pairs_importer` | ❌ **不存在**(`exe/colmap.cc` 命令表里只有 `feature_importer` 与 `matches_importer`)—— 这是你 Q3 提示里的一处事实错误 |
| DB schema | 【源码】`database_sqlite.cc:2023` `descriptors(image_id, type, rows, cols, data BLOB)` —— 4.x **新增了 `type` 列**,DB 原生带描述子类型 |
| float 描述子存储 | 【源码】`types.h` `FeatureDescriptors::FromFloat()` 把 f32 **按字节重解释**塞进 uint8 blob(cols = dim×4)。ALIKED 128-d float 存成 cols=512 |
| 【官方文档】 | https://colmap.github.io/features.html:SIFT = "128-dimensional uint8 descriptors";ALIKED 产出浮点描述子需 `-DONNX_ENABLED=ON`;且**提取器与匹配器必须配套** |

### Q3.2 逐候选裁定(LICENSE 均为实际打开过的 raw 文件)

| 候选 | 许可 | 权重许可 | 描述子 | 跨端 | 专利 | 判定 |
|---|---|---|---|---|---|---|
| **ALIKE** | BSD-3 `raw.githubusercontent.com/Shiaoming/ALIKE/main/LICENSE` | BSD-3 + 训练码公开 | 128-d f32 | ✅ **无 DCN、无自定义 CUDA op** | 未检索到 | ✅ **可用(跨端最干净)** |
| **ALIKED** | BSD-3 `raw.githubusercontent.com/Shiaoming/ALIKED/main/LICENSE`(与 ALIKE 逐字节同文) | BSD-3 同仓 | **128-d f32** ✅维度对 | 🔴 SDDH 用 **DCN**:coremltools 8.0-9.0 全 tag grep 命中 0(只有未发布 main 分支);**MNN 全仓 grep `Deform` = 0**;SDDH 逐关键点动态形状须自研 C++ | 未检索到 | **需签决** |
| **DISK** | Apache-2.0 `raw.githubusercontent.com/cvlab-epfl/disk/master/LICENSE.txt`(⚠️ `/LICENSE` 是 404) | Apache-2.0 —— **"NC 权重"传闻不成立** | 128-d f32 | 🔴 **真雷在子模块**:`.gitmodules` 引的 `jatentaki/unets`(骨干网实际实现)与 `torch-dimcheck` **无 LICENSE = 默认版权保留,不可商用分发**;另 **98.97 GFLOPs**(ALIKE-N 的 12.5×) | 未检索到 | **需签决** |
| **R2D2** | 🔴 **CC BY-NC-SA 3.0 Unported**(不是 4.0)`raw.githubusercontent.com/naver/r2d2/master/LICENSE` | NC | — | — | — | 🔴 **不可用,禁参考** |
| **Key.Net** | Clear BSD(TF 仓)/ **MIT**(PyTorch 仓) | HyNet/HardNet++ 均 **MIT**(GitHub 标 NOASSERTION 是误判) | detector-only;配 HyNet = 128-d f32 | 无 DCN;两段式(检测→32×32 patch→HyNet)**与我方 DSP-SIFT 形态同构**,最好嵌 | ⚠️ Clear BSD 明文 "NO EXPRESS OR IMPLIED LICENSES TO ANY PARTY'S PATENT RIGHTS ARE GRANTED" | ✅ 可用(专利裸奔) |
| **SuperPoint (MagicLeap)** | 🔴 `ACADEMIC OR NON-PROFIT ORGANIZATION NONCOMMERCIAL RESEARCH USE ONLY`;**衍生物所有权归 Licensor**;全文无商用授权联系方式 | NC | 256-d | — | 🔴 **US11537894 B2**(2022-12-27 授权)+ 母案 **US10977554 B2**(2021-04-13),受让 Magic Leap,【推断】到期 ≈**2038-11** | 🔴 **不可用** |
| **rpautrat/SuperPoint** | MIT `raw.../rpautrat/SuperPoint/master/LICENSE.txt`(⚠️ 不是 `/LICENSE`) | ✅ **真 clean-room**:权重 SHA-1 `f645e8db…`/5,251,225B vs MagicLeap `107a444c…`/5,206,086B,**双双不同** | 256-d | — | 🔴 **专利打在训练方法上,换实现躲不掉**;MIT **不含专利授权条款** | 🟡 版权净但专利敞口 → **建议整条线永久关闭** |
| eric-yyjau / shaofengzeng / yuefanhao-TensorRT / HF magic-leap-community | 声明 MIT/Apache-2.0 | 🔴 **仓内权重 SHA-1 与 MagicLeap 逐字节全等 `107a444c…`** | — | — | — | 🔴 **全部不可用**(宽松 LICENSE 是假象) |
| **SuperGlue** | 🔴 同一份 MagicLeap NC 模板 | NC | 匹配器 | — | US2021/0150252 A1(优先权 2019-11-14) | 🔴 **不可用** |
| **LightGlue (cvg)** | ✅ **Apache-2.0**(已 curl 确认);`cvg/glue-factory` 同 | LG 权重(sift/aliked/disk flavor)ETH 自训 Apache-2.0 | 匹配器 | ⚠️ 自适应早退 = 数据依赖控制流,导出须 `depth_confidence=-1, width_confidence=-1` 关掉(丢掉核心提速卖点) | 未检索到 | ✅ **可用**,⚠️ vendoring **必须物理删除 `lightglue/superpoint.py`**(该文件在 Apache 仓里仍带 Magic Leap "CONFIDENTIAL" 横幅,release 里 `superpoint_v1.pth` SHA-256 与 MagicLeap 全等 `52b67086…`) |
| **XFeat** | ✅ Apache-2.0(已 curl 确认,stock 模板无附加条款) | 仓内 `weights/xfeat.pt` 受同一许可;蒸馏源 ALIKE = BSD-3,链干净 | 🔴 **64-d f32**,与 128-d uint8 构造性不兼容 | ✅ 纯 CNN 无 DCN;⚠️ `grid_sample` 用 **bicubic**(CoreML `resample` 不支持)+ `nonzero` NMS 须 C++ 重写;🔴 **XFeat\* 是 pairwise,与"抽一次/任意配对"的 SfM 架构冲突** | Apache-2.0 §3 自带专利授权 | ✅ 仅 sparse 版可用;⚠️ **禁 vendored `meyiao/xfeatc`(无 LICENSE = 全权保留)** |
| **OpenCV SIFT** | ✅ Apache-2.0。【源码】**SIFT 已在主模块** `modules/features2d/`,文件头逐字写 **"Patent US6711293 expired in March 2020."** —— SIFT 专利到期由 OpenCV 源码自证 | — | 128-d | CPU only | 已到期 | ✅ 可用(但比我方慢) |
| **AKAZE / KAZE** | ✅ 也在**主模块** `modules/features2d/src/{akaze,kaze}.cpp`,Apache-2.0,无专利门 | — | 二值/浮点,非 SIFT | — | 无 | ✅ 可用但精度不足 |
| **ORB / FAST / BRIEF** | ✅ OpenCV 主模块 Apache-2.0;【论文】ORB 明确定位为规避 SIFT/SURF 专利的替代品,未检索到专利 | — | 二值 | — | 无 | ✅ 可用,**但精度差距过大**(MegaDepth-1500 AUC@5 = 17.9 vs XFeat 42.6 / DISK 53.8) |
| **VLFeat** | ✅ **BSD-2**(上游 `COPYING` 与 COLMAP 内 `thirdparty/VLFeat/LICENSE` 同文)。维护:0.9.21 后实质休眠,119 open issues —— **但对我方无影响**(COLMAP 自维护裁剪版,已在 iOS 跑通) | — | 128-d | CPU | 已到期 | ✅ 已在用 |
| **PopSift** | ✅ **MPL-2.0**(`COPYING.md`)。README 自证 SIFT 专利 1999-03-08→2020-03-28 | — | 128-d | 🔴 **CUDA-only,四端全灭** | 已到期 | 🔴 不可用,但 **MPL-2.0 意味着算法与代码合法可研读**(且比 CudaSift 更忠实 Lowe) |
| **CudaSift** | 🔴 **许可自相矛盾**:`Maxwell` 分支 `LICENSE` = **MIT (c) 2017 Mårten Björkman**,但**同分支 README 第 9 行**逐字写 "The code is free to use for non-commercial applications." | — | — | CUDA-only | — | 🔴 **需法务澄清,不能按 MIT 使用** |
| **SiftGPU** | 🔴 确认 NC。**它就在我方 vendored COLMAP 树里**(`thirdparty/SiftGPU/`),文件头 UNC 版权 + "educational, research and non-profit purposes" | — | — | — | — | 🔴 只可读算法事实,不可抄代码;✅ 当前未链进 iOS 产物 |
| **ArrayFire SIFT** | BSD-3,但 `CMakeLists.txt:104` `option(AF_WITH_NONFREE … OFF)` 至今默认关;后端只有 CUDA/OpenCL/CPU | — | — | 🔴 **无 Metal/WebGPU** | — | 🔴 不可用 |
| **ncnn** | BSD-3,是推理框架,**不提供 SIFT** | — | — | — | — | 不适用 |
| **`stevel705/sift-wgpu`** | README 声明 MIT(**无独立 LICENSE 文件**) | — | 128-d | Rust + wgpu,非 C++ | — | 🟡 唯一找到的 WebGPU SIFT;无已发表基准、成熟度低。价值仅在 **WGSL shader 可合法研读** |

### Q3.3 🔴 你 Q3 提示里的一处事实错误:SURF 专利号

**US7970226 不是 SURF 专利** —— 它是 **Microsoft Corporation** 的 "Local image descriptors"(申请号 11/738875,2007-04-23 申请,2011-06-28 公开)。

真正的 SURF 专利是 **US 8,165,401 B2 "Robust interest point detector and descriptor"**,受让人 **Toyota Motor Europe NV + K.U. Leuven R&D + ETH Zurich**,申请号 12/298879,**2007-04-30 申请,2012-04-24 授权**。
【推断】法定期 = 申请日 + 20 年 ≈ **2027-04-30 到期,即当前(2026-07)仍在有效期内 → SURF 商用仍不可用。**

⚠️ 全部专利检索是在 Google Patents 503 / Justia 403 的环境下经 Web 索引间接完成的;**US8165401 与 US11537894 的官方 anticipated-expiration 与年费维持状态未一手核实**。若要作为签决依据,应委托律师做正式 FTO。

### Q3.4 一个白捡的相邻机会(不在提取器上,但值得单独立项)

**`SIFT_LIGHTGLUE`(Apache-2.0)+ 我方现有 DSP-SIFT**:不换前端、不动 128-d uint8 描述子、不碰专利,**下游 COLMAP 已内建**。【官方文档】COLMAP 文档称 LightGlue 匹配"typically produces more matches and higher inlier ratios than brute-force"。
唯一新依赖是 ONNX Runtime(MIT),其 CoreML EP 支持 `MLComputeUnits=CPUAndGPU` / `COREML_FLAG_USE_CPU_AND_GPU`,**满足"锁 CPU+GPU、绝不用 ANE"的铁律**。
这冲的是 **GPU 匹配那 917 ms / 32%**,不是提取的 1267 ms —— 属于本调研范围外,但杠杆与风险比极好,**建议单独立项做热受控对照**。

---

## Q4(上游侧)— COLMAP 官方 SIFT 路径的一个决定性事实

【源码】vendored COLMAP `colmap/feature/sift.cc:750-755`:

```
if (options.sift->estimate_affine_shape ||
    options.sift->domain_size_pooling ||
    options.sift->force_covariant_extractor) {
  return CovariantSiftCPUFeatureExtractor::Create(options);
} else if (options.use_gpu) { ... }
```

**我方配置(affine-on + DSP-on)在上游 COLMAP 里是构造性地走 CPU 的 —— 上游对这条配置根本没有 GPU 路径。** `SiftCPUFeatureExtractor` 和 GPU 路径都硬 `THROW_CHECK(!estimate_affine_shape)` / `THROW_CHECK(!domain_size_pooling)`(`sift.cc:143-144, 560-561`)。

推论(重要):
1. **SiftGPU 与我方无关**——它做不了 affine shape 也做不了 DSP。它的 UNC 非商用许可对我方是个**不需要触碰**的问题,不是需要绕开的障碍。
2. **不存在可对标的上游 GPU 实现**。我方这条 Dawn/WGSL 覆盖 covariant DSP-SIFT 的路,据我查证是**唯一的一份**。所以"和上游比慢了多少"这个问题没有基准可比;唯一有意义的基线是我方自己的 CPU 参考实现(已实测 CPU ~5000 ms → GPU 1448 ms,3.5×)。

### COLMAP `SiftExtractionOptions` 默认值(逐字,vendored `sift.h:42-98`)

| 字段 | COLMAP 默认 | 我方 | 差异方向 |
|---|---|---|---|
| `max_num_features` | 8192 | 8192 | 一致 |
| `first_octave` | **-1** | **0** | 见第 6 节 |
| `num_octaves` | 4 | 全 octave | 我方更多 |
| `octave_resolution` | 3 | 3 | 一致 |
| `peak_threshold` | `0.02/3` = 0.00667 | **0.004** | 我方更敏感 → 更多点 |
| `edge_threshold` | 10.0 | 15.0 | 我方更宽松 → 更多点 |
| `estimate_affine_shape` | **false** | **true** | 我方开(=aff 130 ms) |
| `max_num_orientations` | 2(仅 affine 关时) | affine 开 → VLFeat 内部 4 | |
| `domain_size_pooling` | **false** | **true** | 我方开 |
| `dsp_num_scales` | **10** | **6**(SCALE-6) | 我方更省 |
| `dsp_min/max_scale` | 1/6, 3.0 | 1/6, 3.0 | 一致 |
| `normalization` | `L1_ROOT`(RootSIFT) | 同 | 一致 |

### Q4.1b 五个上游忠实性的隐蔽坑(实现 WGSL 版必须对齐,permalink 基准 `64805cb`)

1. **GPU 路径根本不传 `num_octaves`。** sift_gpu_args 只有 `-fo/-d/-t/-e/-mo/-maxd/-tc2`,**没有 `-no`**(`sift.cc:576-645`)。SiftGPU 默认 octave 数无上限,而 CPU/VLFeat 路径拿的是 `num_octaves=4` → **CPU 与 GPU 的金字塔深度不同**。parity 对不上时先查这条。
2. **`-maxd` 带 first_octave 补偿**(`sift.cc:605-612`):`compensation_factor = 1 << -min(0, first_octave)`,fo=−1 + 3200 → **`-maxd 6400`**,因为 SiftGPU 的 maxd 指的是"第一个 octave 的最大边"。
3. **半像素偏移**:CPU 路径写 keypoint 时是 `vl_keypoints[i].x + 0.5f`(`sift.cc:260-261`),对齐 SiftGPU 的角点原点约定。
4. **多朝向选取规则 CPU/GPU 不一致**,COLMAP 自己在注释里认了(`sift.cc:252-254`):"this is different from SiftGPU, which selects the top global maxima…"。
5. **DSP 尺度步长是 `/n` 不是 `/(n-1)`**(`sift.cc:463-466`)—— 独立佐证了第 6.14 节:默认 10 档时顶档只到 **2.7167,永远取不到 3.0**。且 DSP 的 `colwise().mean()` 发生在**归一化之前**(`sift.cc:519`)。
6. `max_image_size` 在 4.1.x 已从 `SiftExtractionOptions` 搬到 `FeatureExtractionOptions`(`extractor.h:66`,默认 −1 → `EffMaxImageSize()` 给 SIFT **3200** / ALIKED **1600**)。命令行 flag 相应变成 `--FeatureExtraction.max_image_size`。

**注**:`estimate_affine_shape` 与 `domain_size_pooling` 都是 COLMAP 的**非默认**开关,是我方主动开的质量选项。它们分别对应 `aff` 130 ms 和 `desc` 390 ms 里的 6 倍系数。关掉它们能拿到极大提速,但那是**有损**,必须签决(见第 5 节)。

---

## Q4-2 — RealityCapture / RealityScan:**算法侧公开信息完全空白**(这是本次最有价值的负结果)

### 专利:一个都没有(与特征提取相关的)

【专利】Capturing Reality s.r.o. 名下**全库只有 1 个专利族**:
**EP3510513B8 / US20190197249A1 / WO2018048361A1** — *A method of data processing and providing access to the processed data on user hardware devices*
发明人 Michal Jancosek / Martin Bujnák / Tomáš Bujňák,受让人已转 **Epic Games Slovakia s.r.o.**;优先权 2016-09-12,EP 2021-03-24 授权,**预期到期 2037-09-11**;**美国同族已放弃**(2022 未答复 OA)。
https://patents.google.com/patent/EP3510513B8/en
**内容是 pay-per-input 许可/DRM**,CPC 落 G06F 安全 / G06Q 商业方法 / H04L,**不落 G06T**,全文不出现 feature detection / SIFT / matching / SfM。

其余检索**全为 0**:`assignee="Epic Games"` 仅 18 件全是游戏/HMD/音乐,叠加 "structure from motion" / "point cloud" / "3D reconstruction" → 各 0 结果;`inventor="Tomas Pajdla"` → **0 结果**(**Pajdla 与 CR 专利无任何关联**,只是学术导师身份)。

**→ 没有任何专利障碍阻止我们实现类似前端;反过来也没有任何可抄的公开配方。**

### 检测器算法:官方从未命名

遍查 RealityScan Help、dev.epicgames.com、RealityScan 2.0 发布博客,**全篇只写 "the feature detector" / "features",没有一处出现 SIFT/SURF/AKAZE/ORB/learned detector**。

唯一实质技术表态来自 CR 官方支持 Milos Lukac(wishgranter):https://forums.unrealengine.com/t/detector-sensitivity/707058 —— "MEDIUM setting is the best case scenario";高档位是为全身 DSLR 扫描加的;detector 检测更多点时 "QUALITY of the features goes down"。**官方自认 Ultra 是数量换质量。**

### 🔴 参数表(唯一硬地面),并修正记忆库里"RS 4 万特征预算"那条

【官方文档】https://rshelp.capturingreality.com/en-US/tutorials/setkeyvaluetable.htm

| Key | 默认 |
|---|---|
| `sfmFeatureDetectionQuality` | **High** |
| `sfmMaxFeaturesPerMpx` | **10000** |
| `sfmMaxFeaturesPerImage` | **40000** |
| `sfmPreselectorFeatures` | **10000** |
| `sfmDetectorSensitivity` | **Medium**(不是 Ultra) |
| `sfmImageDownscaleFactor` | **1** |
| `sfmMaxFeatureReprojectionError` | **2.0** |
| `sfmDistortionModel` | **Brown3** |

**🔴 关键读数:40000 是_检测_预算(且受 10000/mpx 约束),真正进匹配的只有 `sfmPreselectorFeatures` = 10000。** 官方建议 preselector 取检测量的 1/4–1/2。
→ 记忆库里 `project_pocketworld_weak_texture_reflective_coverage.md` 那条"RS 弱纹理出点 = 4 万特征预算"应更正为:**检测 4 万、进匹配 1 万**。我方 8192 与 RS 的 10000 preselector 其实是**同一量级**,不是差 5 倍。

### 学术谱系:只到 meshing,不到前端

【论文】Jancosek & Pajdla, *Multi-view reconstruction preserving weakly-supported surfaces*, CVPR 2011,DOI 10.1109/CVPR.2011.5995693 —— 与记忆库"fuseCut = RC 同源"互相印证。但 Jancosek 全部论文都是 MVS/meshing,**没有一篇讲前端**。
Martin Bujnak(CR 联合创始人)全是 minimal solver 线(P4P 未知焦距、5pt/6pt polynomial eigenvalue、*Making minimal solvers fast* CVPR'12)。【推断】RC 的 RANSAC 内核极可能用这一系的 Gröbner 基解算器,**但无任何官方或论文明说**。

⚠️ **辟谣**:网上流传"团队与 Pajdla/Kukelova 合写论文里的 solver 构成 RC 基础"这句 —— 回访 Wikipedia 与 Geo Week News 原文**均无此句**,疑似来自聚合页,**不可引用**。

### 诚实裁决

检测器算法本身、描述子(维度/是否二值/是否 root-norm)、Detector sensitivity 四档到底调什么、是否 ratio test / cross-check、preselector 的筛选准则、增量 SfM 的各种门限、BA 求解器、RS Mobile 端云分界、GPU 化程度 —— **全部从未公开披露**。
**元结论:RC 前端既无专利也无论文。想复刻只能靠上面那张参数表逐项对标 + 自己的法医测量,不存在"读论文照抄"的路径。**

---

## Q4-3 — 已发表的移动/嵌入式 GPU SIFT 数字:**你们没有同级对手**

| 实现 | 设备 | 分辨率 | 特征数 | ms |
|---|---|---|---|---|
| **PopSift(唯一可比锚点)** | GTX 1080 | **3840×2160** | **44930** | **43** |
| VLFeat CPU(同图同参) | i5-4590 | 3840×2160 | 44666 | **7195**(167×) |
| OpenCL-SIFT | AMD R9-290 | 1920×1200 | 4539/oct | 27.68 |
| Wang 异构完整 SIFT | Adreno 320 | **320×256** | 95 | 169.54 |
| Rister detector(**无描述子**) | Snapdragon S4 | **320×240** | 88 | 101 |
| 同上 | Mali-400 | 320×240 | 88 | 132(其中 **readback 43.1**) |

- PopSift MMSys'18:https://home.simula.no/~paalh/publications/files/mmsys2018-popsift.pdf
- DASIP'14:https://publica.fraunhofer.de/bitstreams/d2a675e0-d03b-496c-adad-31431082fd2b/download
- Rister ICASSP'13:https://repository.rice.edu/bitstream/1911/75008/1/2013_ICASSP_Rister_0002674.pdf

**三条读表警告:**
1. **≥1080p 的移动 GPU SIFT 学术数据点为零;≥8MP 的更不存在。** 所有移动论文都停在 320×240 / 88–95 个点。**对外报数请锚 PopSift 43 ms @ 4K/44930(GTX 1080),并诚实说明移动侧没有同级公开对手。**
2. **不要拿 CudaSift 对标** —— PopSift 论文明指它 "does not actually behave like SIFT"(窄滤波器近似 LoG、octave 低层非忠实降采样),4K 只出 2829 点。
3. **WGSL/WebGPU SIFT 的公开计时是空白。**

### 🔴 关键框架修正:8MP 端上 SIFT 是**带宽瓶颈,不是算力瓶颈**

【推断,基于 Wang 对 320×240@15fps 的 5.2 GFLOPS + 13.75 GB/s 建模,线性外推 ×108 到 8.29 MP】≈ **560 GFLOPS + ~1.5 TB/s 带宽**。A16 的算力够,**带宽差 1-2 个数量级**。

**这条改变了本报告的优先级排序**:凡是减少内存流量的动作(Q5-C 干掉几百 MB 的金字塔拷贝、Q5-D blur tile 化、Q2.1 回读 4× 压缩、A6 少传 4.7 MB),**都比"减少算术"更值钱**。而"加并行度"在 A16 上已被你们自己实测判死(scale-parallel 慢 44%),两条独立证据指向同一个方向。

---

## Q5 — 你们没想到的:一个可证明逐位一致的免费剪枝

### 发现

【源码】COLMAP `sift.cc:388-439` 的实际顺序是:

```
vl_covdet_detect(max_num_features)      // 检测
→ vl_covdet_extract_affine_shape()      // ★ 对全部检测点做 affine
→ vl_covdet_extract_orientations()      // ★ 对全部检测点做 orientation(1→K 膨胀)
→ std::sort(按 o 降序, 同 o 内 s 降序)
→ clamp:逐个 push,当 size>=max 且下一个进入新的 (o,s) 组 时 break
→ 计算描述子
```

clamp 的排序键与截断键都是 **`features[i].o * 1000 + features[i].s`,即只依赖 (octave, scale)**。而 **affine shape 和 orientation 都不改变 o 和 s**。

我方管线完全忠实复刻了这个顺序(【源码】`sift_extract_dawn.cc:376-422`,clamp 在 descriptor 之前、orientation 之后)。后果:

- `aff`(130 ms)跑在 **n_kept ≈ 21002** 个点上
- `ori`(272 ms)跑在同样 21002 个点上,1→K 膨胀
- clamp 之后只剩 **~11881** 个进 descriptor

即 **aff + ori = 402 ms 里,有相当大一部分算在必然被 clamp 丢掉的点上。**

### 为什么可以在 affine 之前剪、且逐位一致

因为保留集只由 (o,s) 分组顺序决定,`det` 之后就已经知道每个 (o,s) 组的**检测点数** `n[o,s]`。设每个检测点的方向数 `k ∈ [1, 4]`(affine 开时 VLFeat 上限为 4)。从最粗组开始累加:

- 用 `k=4` 的上界累加 → 得到**最早可能**的 break 组 `G_early`
- 用 `k=1` 的下界累加 → 得到**最晚可能**的 break 组 `G_late`

则**严格比 `G_late` 更细的所有 (o,s) 组,在任何 k 取值下都 100% 被丢弃**,可以在 `aff` 之前无条件剪掉,输出逐字节不变。

SIFT 的检测点在最细 octave 上高度集中,而 COLMAP 是**粗优先保留**——被丢的正是数量最大的那批。所以这个剪枝的期望收益不小,但**具体多少完全取决于 (o,s) 直方图,这个直方图你们一条 log 就能打出来**,我不猜数。

**实现上它几乎是免费的**:【源码】detect kernel 已经在 atomic append 时把 `o`、`s` 写进每条记录(`sift_extract_dawn.cc:181-193`),再加一个 `atomic<u32> osHist[num_octaves * octave_resolution]` 即可;而 `det_counter` **本来就要回读一次**(`:197`),把直方图挂在同一次回读里 → **零新增往返**。host 上算出保守阈值 `min_os`,当作 uniform 传给 affine dispatch,shader 里一行 early-return。

另外提醒一个放大因子:【源码】我方 `peak_threshold = 0.004`(COLMAP 默认 0.00667)、`edge_threshold = 15.0`(COLMAP 默认 10.0),两个都比上游更激进 → 检测数被主动放大,而 `max_num_features` 仍是 8192。**所以"检测 21002 → 保留 11881"这个漏斗是我们自己开大的**,这条剪枝要咬的肉也就更多。

【预计收益】未知但可能是 aff+ori 的显著比例;先测直方图再决定【**无损:可构造性证明逐位一致**】【跨端:是】【许可:自研,依据是已 vendored 的 COLMAP BSD 代码逻辑】【成本:小(检测阶段加一个 (o,s) 直方图 + 一个保守阈值)】【证据:源码 + 推断(证明是我推的,数值未测)】

⚠️ 诚实边界:这与记忆里 2026-06-30 那条"clamp 前提错 / 无免费 win"**不冲突**。那次否掉的是「把 clamp 从 descriptor 前挪到 orientation 前」——那确实不忠实,因为 clamp 计数是在 1→K 膨胀**之后**的。我这里提的是**保守双边界剪枝**,只剪"任何 k 都活不下来"的组,规避了那个陷阱。

### Q5-E ★★ 常量高斯掩膜被逐关键点、逐像素地 `exp()` 重算

【源码】`sift_orientation.wgsl:306-308` 与 `sift_affine_shape.wgsl:333-338` 在算**同一个式子**,而它**只依赖 patch 内坐标**(`EXTENT=9` / `SIDE=41` / `INTEG_SIGMA=3` 全是编译期常量),**与关键点无关**。

- `ori`:每帧约 **13.8M 次 `exp()`**(21k kp × 1681 px)
- `aff`:每次 Baumberg 迭代重来一遍,`MAX_ITER=15` → 最坏 **~207M 次 `exp()`**

修法:预计算 41×41 = 1681 个 f32(**6.6 KB**)进一个 storage buffer,两个 shader 共读。用一个 WGSL prepass 生成(而不是 host 上用 f64 算再降 f32),即可避开 1 ulp 漂移,做到**逐位一致**。

【预计收益】402 ms(aff+ori)中 `exp` 那部分;保守 10-25%(40-100 ms/帧),**必须实测**【**无损:可做到逐位一致**】【跨端:纯 WGSL,四端通吃】【许可:自研】【成本:小】【证据:源码,强】

### Q5-F ★ `ori` 的 36-bin 归约是 36 次串行树归约,而同仓已经有正确解法

【源码】`sift_orientation.wgsl:318-325`:36 个 bin **逐个**做 64-lane 树归约 → **每关键点约 288 次 `workgroupBarrier()`**。shader 里的注释还写着"太大放不下"所以放弃了分块。

但 `sift_dsp_descriptor.wgsl:75-78, 282-296` **已经实现了正确解法**:`BLK=32` 的 `redM[64][BLK]` 分块归约,注释自述 "4 blocks × 7 barriers = 28 per scale (was ~1024)"。
orientation 只有 36 个 bin,`BLK=18` 两块即可(64×18×4 = 4608 B);而且**此时 `wsmooth` 已经用完可以复用它的空间**,threadgroup 占用不必增加。barrier 从 ~288 降到 ~16(**18×**)。

⚠️ 与 Q5-B/B1 的关系:B1 说 `redM` 的 8 KB 伤 occupancy。**两者的正解是合并的** —— orientation 直接上 **subgroup 归约**(`subgroupAdd`),既拿到分块归约的 barrier 收益,又不付 threadgroup 内存代价。别把描述子那个 8 KB 的方案原样搬过来。

【预计收益】参照描述子那次 1024→28 的同类改造,须 A/B 实测【**无损**(若保持 bin 内 lane 树形状不变、只改"一次收几个 bin")/ subgroup 版则需 parity gate】【跨端:是】【许可:自研】【成本:小,有现成范式可抄】【证据:源码,强 —— 两个 shader 并排,同一问题一个解了一个没解】

### Q5-C `pack` 101 ms 是一次纯 buffer→buffer 拷贝,而且每帧重新分配几百 MB

【源码】`sift_pyramid_dawn.cc:329-353` `pack_levels()`:

```
wgpu::Buffer packed = harness.alloc(total_bytes, Storage|CopySrc|CopyDst);   // ← 每帧新分配
harness.begin_batch();
for (o, s) 全 48 层: harness.copy_region_batched(level_buffer(o,s), 0, packed, dst_byte, level_bytes);
harness.end_batch();
```

两个问题:

1. **`packed` 每帧重新 `alloc`。** 【实测,来自本仓记录】这块在 fo=0 下是 **160 MB**(早期记录另有 "320MB packed 金字塔" 的配置)。输入尺寸每帧固定,这个 buffer 完全可以**持久化复用**。⚠️ 而且 WebGPU 规范要求新建 buffer 的内容为零,Dawn 用 `lazy_clear_resource_on_first_use` toggle 实现(https://crbug.com/dawn/145)—— 也就是说**每帧可能还附带一次几百 MB 的 GPU memset**。这很可能就是 101 ms 的主项。
   【预计收益】可能是 pack 的绝大部分【无损】【跨端:是】【成本:小】【证据:源码 + 官方文档 + 推断(memset 是否真触发需 A1 计时或 Xcode GPU trace 证实)】

2. **更彻底:让 blur/resample 直接写进 `packed` 的目标 offset,`pack_levels` 整个消失。** 跨-octave 采样用的 `meta` 偏移表已经存在(affine/orientation/descriptor 都在用),blur 的读写只需带上 base offset。省掉整整一次全金字塔拷贝 + 一份重复驻留。
   【预计收益】pack 101 ms 归零【无损:纯搬运,可逐字节验】【跨端:是】【成本:中(改 3 个 pyramid shader 的寻址)】【证据:源码】

这条我认为被漏掉的原因是:`pack_levels` 已经批处理过了(64→35 ms 那次),看起来"优化过了",所以没人再问"**它为什么还要存在**"。

### Q5-D 金字塔 blur 没有 tile 缓存,而且它是**唯一一个 tile 化后仍逐位一致**的 kernel

【源码】`shaders/wgsl/sift_gss_blur.wgsl` 全文 60 行,`@compute @workgroup_size(8,8,1)`,**没有任何 `var<workgroup>`**:

```
for (k = 0; k < len; k++) { acc = acc + taps[k] * src[base + sx]; }   // 水平
for (k = 0; k < len; k++) { acc = acc + taps[k] * src[sy*width + x]; } // 垂直
```

每个线程为自己那一个输出像素从**全局内存**读 `len`(半径 ~7-15 → 15-31 抽头)个样本,相邻线程之间**完全没有复用**。这是可分离卷积的教科书反例:标准做法是把 tile + halo 载入 `var<workgroup>` 再算。

**关键性质:tile 化对这个 kernel 是逐位一致的。** 因为每个输出像素的累加顺序(`k=0..len-1`,同一组 taps)完全不变,只是**样本来自 threadgroup memory 而不是 global memory**。不像 B1/B3 那样改求和顺序。这是所有候选里**唯一一个既可能有大收益、又零质量风险**的。

两个附带的形状问题:
- 水平 pass 用 `8×8` → 每行只有 8 个连续线程,合并访存宽度差;水平 pass 更适合 `64×1`。
- 垂直 pass 的 `src[sy*width + x]` 是 **stride = width 的跨行访问**,是这两个 pass 里更慢的那个,也是 tile 化收益最大的那个。

【预计收益】可分离卷积 tile 化的典型区间是 2-4×,若成立 pyr 168 ms → 40-80 ms;**但我没有 A16 上的实测数,Apple 的 L1 可能已经吃掉了一部分复用,收益可能远小于教科书值**【**无损:可逐字节验**】【跨端:是】【许可:自研】【成本:中】【证据:源码 + 推断】

### Q5-B ⬇️ 占用率(occupancy):我一度认为这是最大杠杆,查证后**自行降级**——完整推翻过程留档

【官方文档】Apple Silicon **每个 GPU core 只有 32 KB threadgroup memory**;分配越多,能并发驻留的 threadgroup 越少(16 KB → 2 个,8 KB → 4 个)。对复杂 kernel,"1K-2K concurrent threads per shader core is very good occupancy"。
https://developer.apple.com/videos/play/tech-talks/10580/
https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

【源码】把我方三个"一个 workgroup 一个关键点"的 kernel 的 threadgroup 分配算出来(全部 `@workgroup_size(64,1,1)`):

| kernel | `var<workgroup>` 明细 | 合计 | 可驻留 tg/core | 驻留线程/core | 实测耗时 |
|---|---|---|---|---|---|
| `sift_affine_shape` | wpatch 1681×f32=6724 + red 64×f32=256 + 小量 | **≈7.1 KB** | **4** | 256 | **130 ms** |
| `sift_orientation` | wpatch 6724 + **wsmooth 6724** + hist 144 + red 256 | **≈13.9 KB** | **2** | 128 | **272 ms** |
| `sift_dsp_descriptor_f16` | wpatch 961×f16=1922 + hist 512 + accum 512 + **redM 2048×f32=8192** | **≈11.2 KB** | **2** | 128 | **390 ms** |

**~~推论 1~~ —— 我自己撤回这一条。**
我原本写:aff 与 ori 跑同一批 ~21002 个关键点,occupancy 比 2.0 与耗时比 272/130 = 2.09 吻合,故 ori 是 occupancy-bound。
**这个论证不成立**,因为两个 kernel 每个关键点的工作量根本不同:`aff` 是 Baumberg 迭代(最多 15 轮,每轮重采 patch),`ori` 是两趟可分离高斯(每像素 ~15-31 抽头)+ 36-bin 直方图 + 6 次 box blur。"同样的 patch 大小"不等于"同样的工作量",2.09 ≈ 2.0 大概率是巧合。

**按每 patch-像素归一化后的正确画面**(把各阶段真实关键点数代进去):
- `desc`:8192(clamp 后)× 6 档 × 961 px = 47.2M patch-px / 390 ms = **8.26 ns/px**
- `ori`:21k-27k × 1681 px = 35-45M patch-px / 272 ms = **6.0-7.7 ns/px**

→ **`ori` 每像素比 `desc` 还便宜,一点也不异常。272 ms 是被 2.6-3.3 倍的关键点数量撑起来的,不是被 occupancy 撑起来的。**
这反过来**强化了 Q5-A(保守 (o,s) 剪枝)**:ori 贵在"算了太多注定被丢的点",而不是贵在"每个点算得慢"。**Q5-A 才是 ori 的正解,B2 是次要的。**

**第三重独立佐证:与已发表的 GPU SIFT 阶段占比并排,你们的 `ori` 21% 低于每一条基线。**

| 来源 | orientation | descriptor | pyramid |
|---|---|---|---|
| **你们(原始分账)** | **21%** | 31% | 13% |
| 你们(剔 affine 归一到 90%) | 23.3% | 34.4% | 14.4% |
| DASIP'14 / Tesla C2050 / 1920×1200 | **28.1%** | 38.4% | 20.3% |
| Wang / Adreno 320【推断换算】 | **33.7%** | 35.7% | 12.5% |
| Rice ICASSP'13 / 四款移动 SoC【推断换算】 | **37–53%** | n/a | 28–42% |

【论文】DASIP'14 Table V vs Table IX 是最锋利的一条:**同一份代码,orientation 在 GPU 上占 28.1%,在 CPU 上只占 8.76%** —— 直方图串行、并行度低,**orientation 天生对 GPU 不友好**。Wang 在 Adreno 320 上实测 orientation 用 GPU 比 CPU **慢 4.6×**(140 ms vs 30.17 ms),最终把这一段划回 CPU。

而且 DASIP 那个 28.1% 已经是**优化后**的数字(orientation kernel 26.8 → 3.8 ms,7.05×,是全文最大单核加速);用 baseline 会是 ~70%。**你们 21% 说明已经站在"优化后"这一档**,而且 COLMAP `max_num_orientations` 口径(affine 开时 VLFeat 上限 4)比 DASIP 的 1-orientation 口径**更重** —— 更重的口径下拿到更低的占比。

**推论 1'(保留但大幅降级)**:occupancy 差异本身是真的(`aff` 4 tg/core vs `ori` 2 tg/core,源码可数),B3 探针仍值得花 30 分钟证伪。但它现在被**三条独立证据**围攻:①"2.09 吻合"是巧合;②按 patch-像素归一 ori 比 desc 还便宜;③横向对比 ori 占比低于所有已发表基线。**结论:不要为 `ori` 单独开战役。** 它的 272 ms 是"算了太多注定被丢的关键点"的结果 —— **正解是 Q5-A 剪枝,不是 occupancy。**

**推论 2 — 为什么优化②(128-bin barrier 树形归约)在 A16 上是零增益?**
【源码】② 引入的 `redM : array<f32, 2048>` = **8192 B**,是描述子 kernel 里最大的单笔 threadgroup 分配(比 f16 patch 本身大 4 倍)。它把 threadgroup 占用推到 11.2 KB → 只能驻留 2 个 tg/core。
所以 ② 是:**barrier 数 1024→28(赚)+ occupancy 大约减半(赔)= 净零**。你们当时的结论"归约非瓶颈"可能是错的 —— 更可能是**两个真实效应互相抵消了**。

**推论 3 — 为什么 f16 描述子只快 10%?**
f16 把 wpatch 从 3844 B 压到 1922 B,总占用 13.1 → 11.2 KB。**两边都落在 `32/x = 2` 这一档里,occupancy 一格没动。** 所以只剩纯 ALU 收益(~10%),完全符合实测。

### Q5-B 的三个动作(按信心排序)

**B1 — 用 subgroup 归约替掉 `redM`(拿②的 barrier 收益,不付 occupancy 代价)。**
harness **已经请求了** `wgpu::FeatureName::Subgroups`(【源码】`dawn_kernel_harness.cpp:187`),但三个 SIFT kernel 一个都没用。WGSL `enable subgroups; subgroupAdd()` 已在 Chrome 134 / Dawn 落地。
https://github.com/gpuweb/gpuweb/blob/main/proposals/subgroups.md
https://developer.chrome.com/blog/new-in-webgpu-134
【源码】现在的归约(`sift_dsp_descriptor_f16.wgsl:293-309`)是:每个 lane 把自己的 `BLK=32` 个私有 bin 写进 `redM[lane*32 + k]`,然后跨 64 lane 做 6 层树形归约,`128/32 = 4` 个 block 循环 4 遍。`redM` 因此必须是 `64 × 32 = 2048` f32 = **8192 B**。

改法:64 线程 = Apple SIMD 宽 32 → **2 个 subgroup**。`subgroupAdd(lh[blk+k])` 直接给出组内 32 lane 的和(**零 threadgroup 内存、零 barrier**),只剩 2 个 subgroup 的部分和需要合并 → scratch 从 8192 B 降到 **2 × 32 × 4 = 256 B**。
kernel 总占用:`wpatch 1922 + hist 512 + accum 512 + 256 + 小量 ≈ **3.2 KB**` → 理论 `32/3.2 = 10` tg/core(实际会被寄存器压力先卡住,但**至少 4**)→ **2-5× occupancy**。
⚠️ 求和顺序改变 → **不是逐位一致**,但落在已建立的 `cosine ≥ 0.998` 门内(现状中位 0.99998,余量巨大)。必须过 `dsp_descriptor_parity` gate。
⚠️ Metal 不提供 subgroup size 控制,shader 必须按 `subgroup_size` 内建值自适应,不能硬编码 32。
【预计收益】若推论 2 成立,描述子有 2-4× occupancy 空间;实际收益取决于是否真 latency-bound —— **待 A1 计时后 A/B**【有损但在既有质量门内(需 parity gate,不需用户签决)】【跨端:Subgroups 是 WebGPU 标准 feature,需 `HasFeature` 守门 + 非 subgroup 回退路径(Adreno 前科)】【许可:自研】【成本:中】【证据:源码 + 官方文档 + 推断】

**B2 — `ori` 的 `wpatch`/`wsmooth` 改 f16(有现成先例,改动最小、收益最直接)。**
【源码】`sift_orientation.wgsl:254-271`:各向异性高斯是可分离的 ping-pong —— v-pass `wpatch → wsmooth`,x-pass `wsmooth → wpatch`。所以 `wsmooth` 是**必需的临时缓冲**,不能直接删。

但可以换精度:两个 41×41 数组从 `f32` 换成 `f16`:
- `2 × 1681 × 4 = 13448 B` → `2 × 1681 × 2 = 6724 B`
- 总占用 **13.9 KB → ~7.2 KB** → **2 tg/core → 4 tg/core(occupancy 2×)**

**先例已经存在且已上生产**:`sift_dsp_descriptor_f16.wgsl:81` 就是 `var<workgroup> wpatch : array<f16, 961>`,累加器保留 f32,实测 cosine 中位 0.99998 / min 0.99790,已是 A16 默认路径。orientation 的 patch 是同一份金字塔数据、同一个量级,**风险画像基本相同**。

⚠️ 但 orientation 的输出是**角度**,不是描述子 —— f16 patch 的舍入会经由梯度 → 36-bin 直方图 → 抛物线拟合传到主方向上,再放大进 descriptor 的 patch warp。现有的 orient parity gate 是 `median 0.14-0.36°`,必须重跑,不能拿 descriptor 的 0.99998 当背书。
⚠️ Adreno 无 `ShaderF16` → 必须保留 f32 回退路径(与描述子同一套 `has_f16()` 逻辑)。

【预计收益】若推论 1 成立,上界接近 2×(ori 272 → ~140 ms)【**有损(f16 舍入),但走既有 orient parity gate,不是新的质量取舍档位**】【跨端:是,`has_f16()` 守门 + f32 回退已有先例】【许可:自研】【成本:小-中(照抄描述子的 f16 改法)】【证据:源码 + 官方文档 + 推断】

**B3 — 试 `@workgroup_size(64)` → `128/256`。**
threadgroup 内存不变,但每 core 驻留线程数按倍数涨(`ori` 128 → 256/512)。Apple 的建议是"the smallest multiple of the thread execution width that works" —— 64 对 1681 像素的 patch 偏小(每线程 ~26 像素)。
⚠️ `red : array<f32,64>` 之类的归约 scratch 要跟着改尺寸,**求和顺序会变 → 需 parity gate**。这是三个里最便宜的实验,应该**第一个试**,用来验证"到底是不是 occupancy-bound"这个前提。
【预计收益】未知,但**这是验证 Q5-B 整个假设的最低成本探针**【需 parity gate】【跨端:是】【成本:小】【证据:官方文档 + 推断】

**诚实边界**:推论 1/2/3 三条都是【推断】。它们互相印证(2.09 对 2.0、②零增益、f16 只 10%),但**我没有真机 occupancy 计数器数据**。B3 是 30 分钟能证伪的实验 —— 如果加大 workgroup_size 毫无变化,整个 Q5-B 就该丢掉。**请先做 B3,别先做 B1。**

### Q5-G 文献里已实测过的 GPU SIFT 算法级技巧(可抄思想,全部来自论文/官方文档,不碰 NC 代码)

| 技巧 | 已发表收益 | 出处 | 对我方适用性 |
|---|---|---|---|
| **2×2 灰度打包进 RGBA texel** | 取数 **−4×**,Gaussian 算术强度 2→8;**Gaussian 金字塔 −28%,梯度金字塔 −40%** | Rister §4.2 / Wang §5.3.2 | ★★★ **直击带宽瓶颈**;WGSL 用 `vec4<f32>` 或纹理即可,四端通吃 |
| 每 octave 只做 3 次 blur + 纯降采样接力(octave n 的 layer 0-2 由 n−1 的 layer 3-5 降采样,零卷积) | 卷积次数近半 | Wang §5.3.3 / PopSift §3 | ★★ 需核对我方 `sift_gss_resample.wgsl` 是否已这么做 |
| 递归增量高斯 σa²=σb²+σc²,只卷 Δσ | 核长降到 ~6σ+1 | Wang §5.3.3 | ★★ 同上,需核对 |
| prefix-sum stream compaction 建 keypoint 列表 | 只占 5.7% 总时长,"avoids redundant work-items" | DASIP §IV-A | ★★★ **正是我方 A3**,而且 `prefix_sum_*.wgsl` 已在仓里 |
| 用纹理引擎(Image2D)替代裸 buffer | 免费边界处理 + 硬件双线性 + texture cache | Wang §5.3.2 / PopSift §3 | ★★ 我方 warp 采样全是手写双线性读 storage buffer,换 texture 可能省一大截 |
| descriptor:128 WI/feature 分 16 个 8-WI 子组 | 相对 1-WI-per-histogram **3.4×** | DASIP Table VIII | ✅ 我方已是 64-lane workgroup,已在这一档 |
| **不要什么都上 GPU**:DoG 算术强度太低、extrema/refine 并行度低+分支发散 | — | Wang Table 5.12 | ⚠️ 与我方"全 GPU"取向相反,但我方 det 只占 13%,不急 |
| readback 会 stall 管线且无法被并发计算隐藏 | Mali-400 上 readback 占总时长 **33%** | Rister §4.1 Table 2 | ★★★ **直接支撑 A2/A3/A4**(我方有 5 次 host 往返) |
| SiftGPU:orientation 采样窗口用 2.0σ 而非 3.0σ | 官方自称 3.0 让该步**慢 40%**,匹配只微幅改善 | SiftGPU `speed_and_accuracy.txt` #2 | ⚠️ **有损**,且偏离 COLMAP/VLFeat 认证配置 → 需签决 |
| SiftGPU:多朝向的 1→K 列表重建放 **CPU** | — | SiftGPU manual p.1 | ⚠️ 与"计算不搬 Dart/host"取向相反,不推荐 |

⛔ **一条我要驳回的文献建议**:Wang §5.3.2 的"梯度预建成金字塔、orientation 与 descriptor 共享上游"在**我方架构上不成立**。
【源码】我方三个 kernel(`sift_affine_shape` / `sift_orientation` / `sift_dsp_descriptor_f16`)都是**先把图像 warp 进 patch 帧,再在 patch 空间算中心差分梯度**;而且三者的 warp 几何各不相同(aff 用迭代中的 A,ori 用 `A_ud = U·D`,desc 每个 DSP 档一个缩放 A)。图像空间的预计算梯度金字塔要用,必须**旋转梯度向量**再重采样,**不可能逐位一致**,而且 covdet 语义本身就要求 patch 空间梯度。这条是给经典 `vl_sift` 路径的,不是给 covdet 路径的。

### 与已判死条目的关系(不重提)

【实测,来自本仓记录】以下已榨干,我不再建议:
- clamp 前移到 descriptor 前:**已装机**,desc 1134→673 ms
- 128-bin workgroup barrier 树形归约:**已做,A16 零增益**(GPU 已饱和)
- 10-scale 并行化(`SED_PARALLEL_DESC`):**已实测负优化**(982 vs 682 ms),已默认关
- f16 描述子:**已装机为默认**,1578→1425 ms,cosine 中位 0.99998
- DSP 10→6(SCALE-6):**已装机**,host 侧 ~-7%
- pyramid/pack 批处理:**已装机**,190→132 / 64→35 ms
- detect 批处理:已做,几乎无省(compute-bound)
- 持久 harness + pipeline 缓存:**已装机**(`load_compute` 带 cache)

一个小观察:`load_compute` 的 cache key 是 `entry_point + '\0' + 完整 WGSL 源码`,每帧每 pass 做一次 O(源码长度) 的字符串哈希+比较。量级上相对 390 ms 可忽略,但改成编译期常量 id 是零成本的整洁化。

---

## 5. 有损项(必须单独签决,不要混进上面的无损建议)

以下每一条都会改变输出,**我把它们隔离在这里**:

1. **`estimate_affine_shape = false`** → 直接省掉 `aff` 130 ms,且 `ori` 的 patch warp 退化为各向同性(更便宜),VLFeat 方向数上限也从 4 降到 2(→ 1→K 膨胀更小 → clamp 前的点更少 → 连带省)。这是**上游 COLMAP 的默认值**。代价:椭圆 → 圆,宽基线/斜视角鲁棒性下降。记忆里 2026-06-29 用户已经**签决过"保 affine"**,所以这条是**复议**,不是新建议。
2. **`dsp_num_scales` 6 → 更低** → desc 近似线性下降(390 ms ÷ 6 ≈ 65 ms/scale;**DSP 税合计 = +325 ms/帧,是 1267 ms 里最大的单项可议成本**)。记忆里 10→3 已被 veto,10→6 已执行。⚠️ 头号陷阱已记录在案:header 常量与 4 个 wgsl 里硬编码的 `DSP_NUM` **必须同步移动**,否则 dstep 拉伸(2026-07-08 的 S5 事故)。

   🔴 **顺带查出一个文档错误,而且它掩盖了一次真实的质量变化 —— 见第 6.14 节。**
3. **`domain_size_pooling = false`** → desc 降到 ~1/6。这等于放弃 DSP-SIFT,回到普通 SIFT,与"DSP-SIFT 0.83px vs XFeat 1.09px"的前端定案直接冲突。**不建议**,仅列出以求完整。

上述任一项都直接动质量北极星,按铁律走 `AskUserQuestion` 签决。

---

## 6. 与你陈述相矛盾的事实(你要求被纠正,这里不附和)

### 6.1 ⛔ 「sup/aff/ori/desc 全是裸 dispatch,所以合批就能赢」—— 前提不成立

见 Q1.3。四段之间夹着 5 次强制 host 往返 + host 串行循环。`begin_batch()` 包起来会**算错**。真正的动作是 A2/A3/A4(消往返),不是"加两行批处理"。这不削弱你的判断方向,只是把动作从"一行"变成"三个中等改动"。

### 6.2 ⛔ 「harness 的 `dispatch()` 每次 submit + WaitAny」—— 这条你说对了,但成本模型要修正

【源码】确认:`dispatch()`、`dispatch_indirect()` 都是 `Submit` + `OnSubmittedWorkDone` + `WaitAny(UINT64_MAX)` 全阻塞。
但「×2.1-3.4 vs ×1.19」的差距**不能全部归给 submit 开销**。`pyr` 是 ~80 个小 blur pass(每个都很便宜,同步开销占比自然高),而 `ori`/`desc` 是**单次 dispatch、每个关键点一个 workgroup 的大 kernel**——它们只同步 1 次。所以 `ori` 的 272 ms 里 submit 开销至多是**一次**往返,不可能是主项。

`ori` 那 272 ms 的真实构成目前**是未知的**,它混了:host 重打包循环(n_kept 次 memcpy)+ 上传 `ori_in_buf` + 上传 **2 MB 零填充** `ori_out_init` + 上传 512 KB `dbg_init`(调试残留)+ 一次 dispatch + **一次为 4 字节的完整回读**。**在装 timestamp-query(动作 A1)之前,任何针对 ori 的优化都是在猜。**

### 6.3 ✅ `first_octave`:两份矛盾记录我找到了,并且能调和 —— **两份都是对的,因为输入分辨率不同**

先把语义钉死:

- 【官方文档】VLFeat:"By convention, the octave of index 0 starts with the image full resolution … specifying a negative index starts the scale space at an higher resolution image",且 -1 "can be useful to extract very small features (since this is obtained by interpolating the input image…)"。
  https://www.vlfeat.org/api/sift.html
- 【源码】vendored COLMAP `sift.h:45-46`:`// First octave in the pyramid, i.e. -1 upsamples the image by one level.` `int first_octave = -1;`

**所以,同一张输入图上比较:`-1` = 先 2× 上采样 → 多一个最细 octave → 更多(小尺度)特征 + 4× 显存/计算;`0` = 原生分辨率起步 → 更少特征 + 更快更省。`0` 不可能既"更快"又"更多特征"。**

你的两份记录:

| 记录 | 日期 | 结论 | 实验条件 |
|---|---|---|---|
| `project_pocketworld_glomap_ondevice_port.md` | 06-22 | **fo=0 被否**:3322 kp(少 2.9×),reproj 1.16→**1.21 变差** | 输入 **2048 px**,~9555 kp/图 |
| `project_pocketworld_frontend_extractor_decision.md` / `gpu_sift_port_plan.md` | 06-29 | **fo=0 采纳**:与 fo=-1 保留集 **等价**,纯省 2× 检测 / 4× 显存(642→160 MB) | 输入 **4224 px**,fo=0 单独已产 **21002** 候选 |

**调和(这是关键,不是折中)**:COLMAP 的 clamp 是**粗 octave 优先**保留(`sift.cc:401-410` 按 `o` 降序排序)。fo=-1 多出来的 `o=-1` 是**最细**的 octave,排在最末。

- 当 `fo=0` 自身产出的候选数就 **远超** `max_num_features` 时(4032 px → 21002 ≫ 8192),`o=-1` 那一组 **100% 被 clamp 砍光**,于是 fo=-1 的保留集 ≡ fo=0 的保留集 —— 输出相同,但 fo=-1 白算 2× 检测、白占 4× 显存。**此时 fo=0 严格占优。**
- 当输入只有 2048 px 时,`fo=0` 只产出 3322 kp < 8192 cap,`o=-1` 的点**不会被砍**,真的进入了保留集 → fo=-1 确实更多特征、reproj 更好。

**结论(适用于你们当前生产配置 4032×3024 + max=8192)**:`first_octave=0` 是**又快又省又等价**的那个,不是质量妥协。06-22 那条记录的适用域是低分辨率输入,现在已经不适用,建议在记忆里给它加上「@2048 才成立」的限定,否则以后还会撞第三次。

⚠️ 附带的真实张力(不要被上面的好消息盖掉):`project_pocketworld_current_pipeline_sfm_casdiffmvs.md` 记着 "first_octave=0 会掉 ~1.6% 最小点"。这与"100% 被砍光 → 完全等价"有 1.6% 的缝隙,大概率来自 clamp 的**组扩展**规则(`sift.cc:433-438`:size≥max 之后还要**把当前 (o,s) 组走完**才 break,所以实际保留 ~11881 > 8192,组边界处会漏进一点 `o=-1` 的点)。这 1.6% 是真实存在的、极小的质量差,**如果你们要 100% 严谨,应该说"fo=0 相对 fo=-1 丢 ~1.6% 最细点,换 2× 检测 + 4× 显存",而不是说"完全等价"。**

### 6.4 ⚠️ `desc` 注释与常量已经不一致(轻微,但会误导下一个人)

【源码】`sift_extract_dawn.cc:498` 的注释写 "serial (one workgroup per kp, **10 scales** looped)",但 `sift_extract_dawn.h:97` 已经是 `kDspNumScales = 6`(SCALE-6,2026-07-11)。注释是 stale 的。

### 6.5 ⚠️ 「pack 101 ms 是打包描述子」

【源码】`mark("pack_levels")` 在 `:150`,是**金字塔层拼进单 buffer**(`pack_levels()`,`sift_pyramid_dawn.cc:338-352`),已经批处理过。它属于金字塔段,不属于描述子段。分账归类要改。

### 6.6 ⛔ 「GPU 匹配 917 ms」这条路**不是 Dawn/WGSL,是手写 Metal**,而且它已经吃过 f16 了

【源码】生产匹配核在 `third_party/glomap_vendor/iosapp/Sources/MatchKernelGEMM.metal` —— Metal `simdgroup_matrix<half,8,8>` GEMM,A/B 都是 `half`。`MatchKernel.metal:33` 的注释写得很清楚:"Descriptors are half (uint8 0-255 → half is LOSSLESS: 255 < 2048)"。

所以对 Q2 里"描述子小 = 匹配也快"这条:
- 描述子**值域**已经是 uint8;matcher 把它**放进 half 存储**是为了吃 simdgroup matrix 硬件,是**有意的、无损的**选择,不是浪费。
- 真要降到 int8 存储,A16 的 `simdgroup_matrix` 不提供等价的 int8 路径,会丢掉矩阵单元 → **大概率净负**。
- ⚠️ 顺带的跨端事实:这个核是 Metal 手写的,**不满足 Dawn/WGSL 跨端约束**(与记忆里"🔴f16 matcher Adreno 崩"一致)。不在本次提取器议题内,但列出来免得后面被当成"已跨端"。

### 6.7 ✅ 你说 SiftGPU 是 UNC 非商用 —— 正确,但**与本议题无关**

见 Q4:我方开了 affine + DSP,COLMAP 构造性走 CPU covariant 路径,SiftGPU 根本不在链路上,也做不了这两件事。这不是需要绕开的红线,是一个**不需要进入的房间**。

---

### 6.8 ⛔ 我自己在本报告中途写错的一条(留证,不删)

我先写了"`ori` 是 occupancy-bound,因为 aff/ori 耗时比 2.09 与 occupancy 比 2.0 吻合",随后自己推翻了它 —— aff 是 Baumberg 迭代(最多 15 轮),ori 是两趟可分离高斯 + 36-bin 直方图,**每关键点工作量根本不同,不能拿"同样的 patch 大小"当同工作量**。按 patch-像素归一化后 `ori` 是 6.0-7.7 ns/px、`desc` 是 8.26 ns/px,**ori 一点也不异常**。
完整推翻过程留在 Q5-B 里没删。**你要的是被纠正而不是被附和,那也包括纠正我自己中途的错误。**

### 6.9 🔴 你 Q3 提示里的一处专利事实错误

"SURF 专利 US7970226" —— **US7970226 是 Microsoft 的 "Local image descriptors",不是 SURF**。真正的 SURF 专利是 **US 8,165,401 B2**(Toyota Motor Europe + K.U. Leuven R&D + ETH Zurich,2007-04-30 申请),【推断】约 **2027-04-30** 才到期,**当前仍在有效期内**。详见 Q3.3。

### 6.10 ⛔ 你 Q3 提示里提到的 `image_pairs_importer` 不存在

【源码】`exe/colmap.cc` 的命令表里只有 `feature_importer` 与 `matches_importer`。而 `feature_importer` 是 **SIFT 专用**(硬断言 128 维 + 硬写 `type = SIFT`),所以"用 importer 灌非 SIFT 描述子"这条路是堵死的。详见 Q3.1。

### 6.11 ⚠️ 记忆库里"RS 4 万特征预算"需要更正

【官方文档】RC 的 `sfmMaxFeaturesPerImage = 40000` 是**检测**预算(还受 `sfmMaxFeaturesPerMpx = 10000` 约束),真正进匹配的是 `sfmPreselectorFeatures = **10000**`。
→ 我方 8192 与 RS 的 10000 preselector 是**同一量级**,不是差 5 倍。`project_pocketworld_weak_texture_reflective_coverage.md` 里那条应改为"检测 4 万、进匹配 1 万"。
另:`sfmDetectorSensitivity` 默认是 **Medium** 不是 Ultra,且 CR 官方支持明说 "MEDIUM setting is the best case scenario"。

### 6.12 ⚠️ 仓里有一份 `GPU_DSP_SIFT_PLAN_AFFINE_OFF.md`,与已签决结论相反

该文档在 `aether_cpp/third_party/glomap_vendor/GPU_DSP_SIFT_PLAN_AFFINE_OFF.md`(与正牌 `GPU_DSP_SIFT_PLAN.md` 并排),主张"默认关 affine + workgroup 内存降到 512B"。但记忆库明确记着 **2026-06-29 用户签决 = 保 affine(质量优先)**,affine-off 计划已被否。
**这份文档是 stale 的,建议在头部加一行"已被 2026-06-29 签决否决,勿按此实施"**,否则下一个 agent 会照着它改,而 desc31/ori21/aff10 这套分账口径**只对 affine-ON 成立**。

### 6.13 ✅ 一个你没问但应该知道的:vendored COLMAP 里**已经有** ALIKED + LightGlue

见 Q3.0。这改变了"换前端要付多少下游代价"的整个估算 —— ALIKED 路径下游成本 ≈ 0,而其它候选都要自己加枚举 + 提取器 + 匹配器。

### 6.14 🔴 `sift_extract_dawn.h:92` 对 SCALE-6 的论证是**算错的**,而且它盖住了一次真实的质量变化

header 里为 10→6 写的理由是:

> "dstep becomes (3 - 1/6)/6 and **the top pooled scale lands exactly at kDspMaxScale=3.0**"

【源码】但 shader 里的取值是 `dsp_scale = dsp_min + f32(sc) * dsp_step`,`sc = 0 … DSP_NUM-1`(`sift_dsp_descriptor_f16.wgsl:191`),host 侧 `dstep = (kDspMaxScale - kDspMinScale) / kDspNumScales`(`sift_extract_dawn.cc:446`)。**顶档是 `min + (N-1)·step`,永远取不到 `max`**:

| N | step | 顶档 |
|---|---|---|
| 10(COLMAP 默认) | 0.28333 | **2.7167** |
| 6(我方 SCALE-6) | 0.47222 | **2.5278** |

**所以 10→6 不只是"采样点少一半",还把 pooling 的上界从 2.717 压到 2.528(−7%),同时把档距从 0.283 拉粗到 0.472(1.67×)。** 这是三个同时发生的质量变化,而 header 的论证把它说成"顶档反而更准了"。

⚠️ 澄清边界(别过度解读):**公式本身是忠实于 COLMAP 的** —— COLMAP 自己也是 `(max-min)/num_scales` 且 `i` 取 `0..num-1`,同样够不到 `dsp_max_scale`。**错的只是 header 里那句论证,不是实现。** SCALE-6 当时过了 parity gate、点云在噪声带内,所以它是"已验证有效但理由写错"的变更,不是回归。

**但按 CLAUDE.md 铁律"参数全抄认证配置('o'),不自创"** —— `dsp_num_scales = 6` 相对 COLMAP 认证默认 10 是一处**主动偏离**,而它现在挂在一条算错的理由上。建议:①把 header 注释改对;②把"6 vs 10"重新作为一条**显式的有损取舍**摆上台面签决,而不是让它藏在一句错误论证后面。

---

## 7. 建议实施顺序(最高杠杆 × 最低风险)

| # | 动作 | 无损? | 预计收益 | 成本 | 风险 | 证据 |
|---|---|---|---|---|---|---|
| **0** | **A1 装 `timestamp-query`(pass 边界)+ 把 `finish_descriptor` 纳入计时** | 无损 | 0 ms,但**解锁一切** | 小 | 极低 | 官方文档 |
| **1** | **Q5-E 常量高斯掩膜预计算成 1681-entry 表**(ori 每帧 13.8M 次 `exp`,aff 最坏 207M 次) | **可逐位一致** | aff+ori 402 ms 的 10-25%,须实测 | 小 | 极低 | 源码,强 |
| **2** | **Q5-A 保守双边界 (o,s) 剪枝**:剪掉"任何方向数下都必死"的最细组,再跑 aff/ori。**直方图挂在已有的 `det_counter` 回读上,零新增往返** | **可证逐位一致** | 直击 aff+ori 402 ms 的过量关键点(21-27k → 目标 ~12k) | 小 | 低 | 源码+推断 |
| **3** | **Q5-F `ori` 的 36 次串行树归约 → 分块/subgroup 归约**(barrier ~288 → ~16) | 分块版可逐位一致 | 参照描述子 1024→28 那次 | 小(有现成范式) | 低 | 源码,强 |
| **4** | Q5-C `packed` 金字塔 buffer 持久化(每帧新 alloc 160-320 MB,还可能附带 Dawn 零初始化 memset) | 无损 | 可能是 `pack` 101 ms 的主项 | 小 | 极低 | 源码+官方文档 |
| **5** | A6 干掉每帧 **~4.7 MB** host 零填充上传 + 删 `dbg_buf` 调试残留 | 无损 | 分布在 det/aff/ori 三段 | 小 | 极低 | 源码 |
| **6** | A2 `ori→desc` 改 `dispatch_indirect`(原语已在 harness) | 逐位一致 | 省 1 次全阻塞往返 | 小 | 低 | 源码 |
| **7** | Q2.1 L1Root + round(512) + UBC 重排挪进 shader | 无损(同序 f32) | 回读 6.1→1.5 MB,干掉 1.5M 次 host `sqrt` | 小-中 | 低 | 源码 |
| **8** | A4b `dispatch_batched` 合成单个 compute pass(现在每 dispatch 开一个新 pass) | 无损 | 金字塔段 ~80 个 pass → 1 个 | 小 | 低 | 源码+官方文档 |
| **9** | A5 staging buffer 池化 | 无损 | 小 | 小 | 极低 | 源码 |
| **10** | A3 `sup` 后用已有的 `prefix_sum_*.wgsl` 做 GPU 流压缩 | 无损 | 省 2 次回读 + host 循环 | 中 | 中 | 源码 |
| **11** | Q5-C(彻底版)blur/resample 直接写进 `packed`,`pack_levels` 整段消失 | 无损 | pack 101 ms 归零 | 中 | 中 | 源码 |
| **12** | **Q5-D 金字塔 blur tile 化 + Q5-G 的 2×2 RGBA 打包**(已发表:取数 −4×,Gaussian 金字塔 −28%) | **可逐位一致** | 直击带宽瓶颈;pyr 168 ms | 中 | 低 | 论文+源码 |
| **13** | B3 探针 `workgroup_size` 64→256 / B2 ori patch 转 f16 / B1 subgroup 替 `redM` | 需 parity gate | **先验信心已被三条证据打掉**(见 6.8) | 小-中 | 中 | 推断 |
| — | 有损项(第 5 节 + 6.14:affine off / DSP 档数 / DSP off / SiftGPU 式 2.0σ 朝向窗) | **有损** | 很大(DSP 税 = +325 ms/帧) | 小 | **需用户签决** | 源码+官方文档 |

**排序理由的两次变化(都是被证据推着走的)**:
1. 我最初把 occupancy(旧 B1/B2/B3)排在第 1.5,现在降到第 13 —— 三条独立证据(见 6.8 / Q5-B)指出 `ori` 一点也不异常。
2. 【推断】8 MP 端上 SIFT 是**带宽瓶颈不是算力瓶颈**(Q4-3 末尾),这抬高了所有**减少内存流量**的条目:第 4 项(金字塔 buffer 持久化)、第 5 项(4.7 MB 零填充)、第 7 项(回读 4× 压缩)、第 11-12 项(干掉 pack 拷贝 + blur tile/打包)。而"加并行度"已被你们自己实测判死(scale-parallel 慢 44%),两条独立证据同向。

**顶起来的是 Q5-E(常量 `exp` 重算)和 Q5-A(剪枝)** —— 两条都是逐位一致、成本小、证据强,且都属于"减少每 workgroup 的工作量 / 减少无效工作量"这个 A16 上唯一还通的方向。

### 7.1 验收协议(照铁律走,别用单次墙钟)

每一项都要过:
1. **逐字节 parity**:`clamp_parity` / `dsp_descriptor_parity` / 9 个 gate 全绿。B1/B3 会改浮点求和顺序 → 退到 `cosine ≥ 0.998`(现状中位 0.99998,余量足够,但要**报中位也报 min**)。
2. **热受控计时**:同进程 back-to-back 交替对照(A-B-A-B),不用两次独立启动比。单次墙钟 ±30% 不可信。
3. **GPU 侧 timestamp** 与 host 墙钟**分别报**,这样才能看出省掉的到底是 GPU 时间还是 host/往返时间。
4. **点云端到端**:同 gauge 直出 `compare.html?right=候选ply` 并排肉眼过一遍(每次进步的铁律),reproj 在既有噪声带内。

**关键判断**:第 0 项不是形式主义。你现在这 9 个数字是 host 墙钟,把「host 循环 + 上传 + 阻塞回读 + GPU 真算」混在一起,而**第 4-11 项优化的正是那些被混进去的非 GPU 部分**。没有 GPU 侧计时,你无法区分"我省掉了 100 ms 开销"和"我什么也没省,只是噪声"。铁律里"计时必须热受控 / 单次墙钟 ±30% 不可信"在这里加倍适用。

---

## 8. 查证后判定为死路的方向

### 8.1 描述子压缩(降维 / PQ / 二值化 / f16)—— 整类基本死透

| 方向 | 死因 |
|---|---|
| **f16 描述子省带宽** | 【源码】COLMAP 存的是 **uint8 128 维**(`types.h:102-108`)。f16 = 2 B/维,比现状**还大**。而且 f16 在我方 shader 里**早就是 A16 生产默认**(`sift_extract_dawn.cc:502-507`),收益已经收割完(10%),且只作用于 patch 存储不作用于算术 |
| **PCA-SIFT / PQ / 二值化** | 【实测】uint8 里没有冗余可榨:8→7 bit 就改 **2.07%** 的匹配,8→6 bit 改 **8.3%**。而且【源码】ratio 0.8 是标定在 **`acos(dot/512²)` 角度比**上的,换近似距离(PQ)或汉明距离后阈值语义直接失效。一手佐证:DISK 官方 matcher 默认 ratio 是 **0.95** 不是 0.8 |
| **降到 int8 GEMM 省匹配带宽** | 【源码】我方 matcher 是 Metal `simdgroup_matrix<half,8,8>`;A16 没有等价 int8 矩阵路径,降精度会**丢掉矩阵单元 → 大概率净负** |
| **RootSIFT** | 【源码】COLMAP 默认 `L1_ROOT`,我方 `finish_descriptor` 也在做。**已经吃满,不是待开发项** |

### 8.2 换提取器 —— 逐个死因

| 候选 | 死因 |
|---|---|
| **SuperPoint(全部变体)** | 🔴 MagicLeap 权重 NC;所谓"宽松许可"的镜像仓(eric-yyjau / shaofengzeng / TensorRT / HF)权重 SHA-1 与 MagicLeap **逐字节全等**;唯一真 clean-room 的 rpautrat 版本版权干净,但 **US11537894 B2 打在训练方法上,换实现躲不掉**,【推断】到期 ≈2038 → **整条线建议永久关闭** |
| **SuperGlue** | 🔴 同一份 MagicLeap NC 模板 |
| **R2D2** | 🔴 **CC BY-NC-SA 3.0**,禁用禁参考 |
| **PopSift / CudaSift / ArrayFire SIFT** | 🔴 **全是 CUDA/OpenCL-only,四端全灭**。CudaSift 另有 LICENSE(MIT)与 README("non-commercial")**自相矛盾**,不能按 MIT 用 |
| **SiftGPU** | 🔴 UNC NC。但**与本议题无关**:我方开了 affine + DSP,COLMAP 构造性走 CPU covariant 路径,SiftGPU 根本做不了这两件事 |
| **OpenCV SURF / xfeatures2d nonfree** | 🔴 真正的 SURF 专利 **US8165401 B2** 【推断】约 2027-04 才到期,**现在仍有效** |
| **ORB / AKAZE / FAST / BRIEF** | 许可干净(OpenCV 主模块 Apache-2.0,ORB 明确为规避专利而设计),但**精度差距过大**(MegaDepth-1500 AUC@5 = 17.9 vs XFeat 42.6 / DISK 53.8),与"质量是北极星"直接冲突 |
| **XFeat** | 许可干净(Apache-2.0),但 🔴 **64 维描述子,与 128-d uint8 构造性不兼容**;XFeat\* 是 pairwise,与"抽一次 / 任意配对"的 SfM 架构冲突。⚠️ 另:**禁用 `meyiao/xfeatc`(无 LICENSE = 全权保留)** |
| **DISK** | 🔴 真雷不在权重(权重是 Apache-2.0,"NC 权重"传闻不成立),而在 `.gitmodules` 引的 `jatentaki/unets`(骨干网实际实现)与 `torch-dimcheck` —— **两个仓都无 LICENSE = 默认版权保留,不可商用分发**;另 98.97 GFLOPs = ALIKE-N 的 12.5× |
| **ALIKED** | BSD-3 干净、128 维对得上、COLMAP 已内建 —— 但 🔴 SDDH 用 **DCN**:coremltools 8.0-9.0 全 tag 命中 0,**MNN 全仓 `Deform` 命中 0**。跨端要自研算子 → **需签决,不是现成可用** |
| **`stevel705/sift-wgpu`** | 唯一的 WebGPU SIFT,但 README 声明 MIT 而**无 LICENSE 文件**、无已发表基准、Rust 不是 C++ → 只能当 WGSL 参考读,不能采用 |

**唯一没被判死的换前端候选是 ALIKE**(BSD-3 代码 + 权重 + 训练码三件套齐、无 DCN、无自定义 CUDA op)。但它仍是**换前端 pivot**,按铁律必须签决,不在本报告的"提速"建议里。

### 8.3 已被你们自己实测判死的(我核实过,不重提)

| 方向 | 死因(全是【实测】) |
|---|---|
| scale-parallel 描述子 | 逐字节一致(21002/21002)但 A16 上**慢 44%** —— A16 在 ~12k workgroup 已饱和。**重要推论:A16 上"加并行度"这条路已堵死,收益只能来自"减少每 workgroup 的工作量"** —— 这正好是 Q5-E/Q5-F 的方向 |
| clamp 前移到 descriptor 前 | **已装机**(1134→673 ms),不是待办 |
| 128-bin barrier 树形归约(描述子侧) | 已做,A16 零增益 |
| detect 批处理 | 已做,几乎无省(compute-bound) |
| 持久 harness + pipeline 缓存 | 已装机 |
| 降检测分辨率 / 降采样点云 / 用户可见质量档位 | 用户明令禁止 |
| detector-free 前端(LoFTR/ELoFTR/XFeat) | 已实测定位为"弱纹理专项",非主线替换 |

---

## 9. 合规待办(不做会出事的三件)

1. **CI 加断言**:禁止 `colmap_sift_gpu` / SiftGPU 目标文件进出货二进制。当前 iOS 产物里确实没有,但**这是构建配置的偶然结果,不是被强制的**。
2. **CI 加断言**:禁止 `superpoint_v1.pth`(SHA-256 `52b67086…`)落盘。
3. 若将来 vendoring LightGlue:**必须物理删除 `lightglue/superpoint.py`** —— 该文件在 Apache-2.0 仓里仍带 Magic Leap "CONFIDENTIAL" 横幅。

---

## 10. 本报告的置信度边界(哪些没查实,别当事实用)

**未一手核实、不可作为签决依据的:**
- 所有专利的官方 anticipated-expiration 与年费维持状态。检索是在 Google Patents 503 / Justia 403 的环境下经 Web 索引间接完成的。**US8165401(SURF)与 US11537894(SuperPoint)若要作为决策依据,应委托律师做正式 FTO。**
- Dawn 的 Metal 后端把一个 WebGPU compute pass 映射成一个 `MTLComputeCommandEncoder` —— 我没能从 Dawn 官方文档直接确认,只能从 Metal API 的构造约束推(A4b)。
- Dawn 的 `lazy_clear_resource_on_first_use` 是否真的在我方每帧那次 `packed` 分配上触发几百 MB memset —— 需 Xcode GPU trace 或 timestamp 证实(Q5-C)。
- "8 MP 端上 SIFT 是带宽瓶颈"是从 Wang 对 320×240 的建模**线性外推 ×108** 得到的,不是实测。
- Q5-A 剪枝的**收益量级**完全取决于 (o,s) 直方图,我没有这个数,**没有猜**。
- Q5-B/Q5-D 的收益区间(occupancy 2-4×、blur tile 2-4×)是教科书/官方文档的一般值,**不是 A16 实测**。

**明确弃用的低置信度数据点(查证时遇到但判定不可信):**
- 网上流传的「Metal 提交开销 10-50 µs」—— 只出现在低可信度二手博客。
- 某次抓取返回的「CudaSift RTX 4060 Ti 3.53 ms」基准表 —— 与 README 原文对不上,判定为抓取端幻觉。
- 「iPhone 14 Pro Max 用 OpenCVforUnity 做 SIFT 检测+提取 36 ms」—— 未标注分辨率与特征数、无法定位原始出处。
- 「CR 团队与 Pajdla/Kukelova 合写论文里的 solver 构成 RC 基础」—— 回访 Wikipedia 与 Geo Week News 原文均无此句。

**本次调研的一条方法论教训**:三个候选(SuperPoint 镜像仓、DISK、CudaSift)的许可陷阱都**不在 LICENSE 文件本身**,而在权重 SHA、`.gitmodules` 子模块、以及 README 与 LICENSE 的自相矛盾里。**"读了 LICENSE"不等于"审计完了"。**

---
