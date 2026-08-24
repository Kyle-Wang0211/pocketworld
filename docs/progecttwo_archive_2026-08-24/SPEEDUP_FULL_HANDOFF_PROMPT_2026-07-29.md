# 拍摄期提速 — 全量接管提示词(2026-07-29)

> 你接手的是 **pocketworld 拍摄期流式 SfM 的提速工作**。本文是 07-29 一整天所有尝试、
> 实测、调研、以及**我犯过的每一个错误**的完整记录。**先整篇读完再动手** —— 里面有六条
> 路是我已经走死的,还有八个我掉进去过的坑,重走一遍会浪费你一整天。

---

# 零、最重要的三句话

1. **不要用"拍完等待时间"当性能指标。** 它把「逐帧计算成本」和「用户按快门的速度」混在
   一起,我用它当指标追了半天,连续三个假设全错。**要用逐帧计算成本(ms/帧)。**
2. **host(Mac)和真机(A16)的成本分布完全不同**,而且 host replay **构造性测不到**两块
   大头:特征提取(replay 从数据库读描述子,提取=0)和热降频。**性能优先级只能用真机数据排。**
3. **改动前先从 podspec 的 `-force_load` 反查实际链接的是哪个二进制。** 这个仓有两套栈、
   四个 `.a` 加一个动态 framework,名字相近。我在这上面栽了两次。

---

# 一、系统背景(事实,不要质疑)

## 1.1 三个仓

| 仓 | 用途 |
|---|---|
| `~/Developer/pocketworld/` | 产品 App(Flutter/iOS),分支 `ar-capture-rs` |
| `~/Developer/Aether3D-cross/aether_cpp/` | 原生算法 C++ 源码 |
| `~/Documents/progecttwo/` | 工作区:文档、`_host_fixtures/`(host 实验台) |

⚠️ `Aether3D-cross` 的 `git status` 很慢(全量 grep 会超时);用**窄路径**查询。
⚠️ 两个仓都是**多 agent 共享的脏工作树**:不得 reset/clean/checkout 别人的未提交改动。

## 1.2 ⚠️ 链接拓扑(我在这里栽了两次,重点读)

`ios/Podfile` 装了两个 pod:

```ruby
pod 'aether3d_ffi',  :path => '../vendor/aether_ffi'
pod 'official_sfm',  :path => '../vendor/official_sfm'
```

**`aether3d_ffi.podspec` 的 `OTHER_LDFLAGS` 里 `-force_load` 了两个静态库**:
- `vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a`
- `vendor/aether_ffi/libs/ios-arm64/sfm/libpwsfm_gpu_extract.a` ← **GPU 提取器 + Dawn harness**

**`official_sfm.podspec` 用的是 `vendored_frameworks`**:
- `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework` ← **动态 framework**,
  导出 27 个 `pwofficial_*` 符号,内部 C/C++ 符号隐藏

**判定"哪个二进制在跑"的硬证据**:逐帧遥测 `frame_split` 的字符串**只存在于官方框架里**
(`strings ... | grep -c frame_split` = 1),自研的 `libglomap_core.a` 里是 **0**。
⇒ **SfM 管线跑的是官方框架**;而 **GPU 提取器与 Dawn harness 是两条路线共用的**
(podspec 里有 `-Wl,-U,_aether_dsp_sift_extract_gpu`,官方框架调它)。

**Dart 里 `pwsfm_*` 被引用 65 次、`pwofficial_*` 只有 3 次 —— 那 65 处是已废弃采集栈的残留,
不要据此判断谁在跑。**

### 改 native 的正确流程

```bash
cd ~/Developer/pocketworld/vendor/official_sfm && sh scripts/rebuild_native.sh
```

它依次做:编译 iOS core → 拷贝 → 重生成 ABI 头 → **verify_abi_signatures.py** →
打包 xcframework → **verify_boundary.sh** → **verify_source_parity.py**。三道闸都会**真的拦**
(`set -eu`,`verify_source_parity.py` 退出码 1)。

⚠️ **`verify_source_parity.py` 钉死了 `official_aether_sfm_c.cc` 的 SHA256。** 改这个文件必须
**同步更新钉死值并写明理由**。07-29 已按用户签决重新签认过一次
(`95ea7fb6…` → `12eefda9…`),理由是"官方须镜像自研"的契约前提已不成立(线上只剩一条采集路由)。

⚠️ **验证 App 里装的是不是新框架,不能用 `nm Runner`** —— 动态框架的符号不在主二进制里。
要查 `build/ios/iphoneos/Runner.app/Frameworks/PWOfficialSfm.framework/PWOfficialSfm`。

## 1.3 提取器配置(实测确认)

| 参数 | 值 | 出处 |
|---|---|---|
| 输入 | **4032×3024 灰度**(全程,07-23 至今没变过) | 设备日志 `(4032x3024)` |
| `maxFeatures` | **8192** | `sfm_live_recon.dart:1554`,`git log -S` 全历史零改动 |
| `peak_threshold` | 0.004 | |
| `first_octave` | **0**(COLMAP 上游默认 `-1`) | 见 §六.5 的调和结论 |
| `kDspNumScales` | **6**(不是 10) | `sift_extract_dawn.h:97` |
| `kDspMinScale/MaxScale` | 1/6 / 3.0 | 同上 |
| `estimate_affine_shape` | **开** | ⚠️ **'o' 认证配置带它**(所有 `run_v*.sh` 都有 `--SiftExtraction.estimate_affine_shape 1`) |
| 描述子 kernel | **f16 变体是 A16 生产默认** | 代码注释:1578→1425ms,cosine 0.99998 |

管线顺序:`pyramid → pack → detect → suppress+rb → affine+rb → orient(1→K) → clamp → descriptor → desc-rb`

---

# 二、今天建成的测量基础设施(可直接用)

**全部遵循同一条纪律:env 未设 = 逐位等同改动前**(不请求 feature、不建资源、不读时钟、
命令流不变)。开与不开两态输出必须逐字相同,这是每次改完的第一道验收。

## 2.1 `[AETHER-T2]` local BA 内部拆分

- 位置:`colmap-src/colmap/sfm/incremental_mapper.cc` + `official_aether_sfm_c.cc` drain
- 产出字段(写进 `frame_split` jsonl):`ilr_find / ilr_setup / ilr_solve / ilr_merge /
  ilr_filter / ilr_pre / ilr_min / ilr_post / ilr_rounds / ilr_solves / ilr_iters /
  ilr_conv / ilr_nocnv / ilr_oth`
- **已随框架装机**(07-29 07:47 那个包)

## 2.2 `[GPU-TS]` GPU 侧真实 pass 计时 ⭐

- 位置:`tools/dawn_kernel_harness.{h,cpp}`
- 开关:**`AETHER_GPU_TIMESTAMPS=1`**
- 挂在**全部三条 pass 编码路径**:`dispatch` / `dispatch_batched` / `dispatch_indirect`
- 一帧只 resolve 一次(per-dispatch resolve 会引入正在被调查的那种往返)
- 512 个 pass 槽位,溢出静默停止记录而不是让帧失败

## 2.3 `[HOST-BD]` host 侧开销拆分 ⭐

同一个 env 门。分类:`upload_ms / encode_ms / submit_wait_ms / map_ms / **create_ms**`
+ 计数 `n_upload / n_dispatch / n_readback / **n_create**`。

⚠️ **`create_ms` 是本轮最重要的一个计数器** —— 它是 `load_compute()` **缓存未命中**时的
WGSL→MSL→Metal 编译。**没有它,编译时间会藏进"提取器自己的 host 循环"里,把人引向完全
错误的代码**(我就是这么错了一次,见 §五.5)。

## 2.4 `[WAIT-BUDGET]` 用户等待预算(Dart 侧)

| 埋点 | 含义 |
|---|---|
| `shutter.gap_ms` | 用户按快门的间隔 —— **整笔账的分母,此前从未量过** |
| `queue_drain.backlog` / `.in_flight` | 拍完那一刻欠了多少帧 |
| `finalize_wall.ms`(local_ready / refined) | finalize 墙钟 |

契约测试:`test/wait_budget_telemetry_contract_test.dart`

## 2.5 host 实验台

| 工具 | 用途 |
|---|---|
| `_host_fixtures/spatial_cand_exp/tools/sfm_replay_bench_cand` | 流式 SfM 重放(**逐位确定性**) |
| `_host_fixtures/tools/ba_cov_tool_m5` | RU / σ_depth / 视差角 |
| `_host_fixtures/tools/m1_roughness.py` | M1 局部壳厚 |
| `_host_fixtures/tools/m4_freespace` | M4 自由空间冲突 |
| `_host_fixtures/tools/cam_scale_tool` | gauge 尺子(相机中心两两距离中位数) |
| `glomap_vendor/build-verify/gpu_extract_e2e_exe` | **整条 GPU 提取链**(host 上唯一能跑提取的) |
| `glomap_vendor/build-verify/clamp_parity_exe` | 描述子逐字节一致 |

⚠️ `build-verify` 链的是 `aether_cpp/build/libaether_dawn_kernel_harness.a`。**那个库到 07-29
之前停留在 7 月 7 日** —— 改了 harness 必须先 `cmake --build aether_cpp/build --target
aether_dawn_kernel_harness` 再建 bench,否则链接失败或跑的是旧代码。

⚠️ `gpu_extract_e2e_exe` 的 recall 门现在**仍是 FAIL**(重编后 0.4222)。不要拿它当验收;
用 `clamp_parity_exe` 或自己做描述子逐字节 diff。

**关键 env**:`SED_TIMING=1`(打印分阶段) `SED_DEBUG=1`(打印计数) `E2E_CLAMP=1`(启用
max_features=8192) `AETHER_GPU_TIMESTAMPS=1`

---

# 三、真机实测(iPhone 14 Pro / A16)

## 3.1 逐帧成本分布 ⭐ 这是排优先级的唯一依据

采集 `cap_1785296330116361`(170 帧,提取器库已回滚,纯时序 K12):

| | ms/帧 | 占比 |
|---|---|---|
| **特征提取** | **1156-1267** | **45%** |
| **GPU 匹配** | **917** | **32%** |
| local BA | 456 | 16% |
| tail | ~180 | 6% |
| 两视图几何 | 143 | 5% |
| 三角化 | ~10 | 0.3% |
| **合计** | **2827** | |

**对比 host(replay)的分布:提取 0% / GPU 匹配 15.5% / local BA 56.5%。**
**⇒ 我按 host 分布花了一整天优化 local BA,而它在真机上只占 16%。**

## 3.2 提取的逐阶段(真机)

| 阶段 | ms/帧 |
|---|---|
| `desc` 描述子 | 390 |
| `ori` 方向分配 | 272 |
| `pyr` 金字塔 | 168 |
| `det` DoG 检测 | 168 |
| `aff` 仿射形状 | 130 |
| `pack` 打包 | 101 |
| `sup` 非极大抑制 | 50 |
| `rb` 回读 | 4 |

## 3.3 用户等待的构成 ⭐

```
用户等待 = 拍完那一刻的欠债排空 + finalize
```

| 采集 | 帧 | backlog | 排空 | finalize | 总等待 |
|---|---|---|---|---|---|
| 07-29 11:10(库回归中) | 153 | 75 | 451s | 124.5s | ~9.6 min |
| 07-29 11:53(库回归中) | 167 | 92 | 526s | — | — |
| **07-29 13:11(库已回滚)** | **172** | **63** | **209s** | 115.2s | ~5.4 min |
| 07-29 15:06(几何选择器) | 160 | 80 | 520s | 113.8s | — |
| **历史最好:07-27 20:34** | **142** | — | **23s** | — | — |

**用户按快门:p10 = 1077-1168ms,p50 = 1642-1669ms。**

| | 快门间隔 | 逐帧计算 | 结果 |
|---|---|---|---|
| 07-27(等 23 秒) | ~2697ms | 2001ms | **富余 34%,零欠债** |
| 07-29 | 1642ms | 2827ms | **超出 72%,必然欠债** |

⭐ **这是全局最重要的一张表。** 等待是**悬崖效应**:计算 < 快门间隔时等待≈0,一旦越过就
无上界增长。**07-27 那次的余量只有 34%**,所以任何退化都会掉下悬崖。
**目标:逐帧计算从 2827ms 压到 1642ms 以下,要砍 42%。**

## 3.4 热

采集期 `thermal=serious` 占 140/140 采样。GPU 每对匹配在一次采集内从 27ms 爬到 117-333ms
(**4.3-8.8× 热退化**)。**冷启动速度在所有采集里都一样(27/39/28 ms/对)—— 峰值性能没变,
变的是持续能力。** 这条是排除"代码回归"的关键证据。

---

# 四、host 实测(Mac,`gpu_extract_e2e_exe`,2400×1800 合成图)

`n_detect=28148 → n_kept(suppress)=27152 → n_oriented=36054`(展开系数 1.328)

## 4.1 ⚠️ 冷 vs 热差 3.4 倍 —— 必须先扣掉着色器编译

```
pipeline_compiles=8 (1314.4 ms)
```

**冷跑总计 1707ms,其中 1314ms 是着色器编译。** 生产上是持久单例 + pipeline 缓存
(那正是当年修"每帧 2s 税"的方案),**每帧不会有这笔**。

## 4.2 热态真实分布(扣掉编译后 ≈ 500ms)

| 阶段 | GPU | 回读 map | 有效 | 占比 |
|---|---|---|---|---|
| **descriptor** | **201.5** | 0.0 | **202** | **40%** |
| **desc readback** | 0.0 | **75.6** | **76** | **15%** |
| affine | 55.8 | 2.3 | 58 | 12% |
| orient | 55.4 | 0.0 | 56 | 11% |
| detect | 31.1 | 0.4 | 32 | 6% |
| pyramid | 22.2 | 0.0 | 31 | 6% |
| suppress | 26.3 | 4.2 | 31 | 6% |
| clamp | 0.0 | 4.8 | 5 | 1% |

**两条结构性结论:**
1. **`wait` 每一行都 ≈ `gpu`**(30.7/22.2、31.9/31.1、56.4/55.8、202.0/201.5)——
   **WaitAny 就是在等 GPU 算,没有额外同步税。"每次 dispatch 都同步很贵"这个推断不成立。**
2. **提取器自己的 host 循环只有 1-5ms/阶段** —— 压缩循环、椭圆重打包、host 排序**都不是瓶颈**。
3. 上传 138 次合计 3ms,回读 7 次合计 6.6ms —— **都不是瓶颈**。

⚠️ 盲区:`CopyBufferToBuffer` 不是 compute pass 拿不到时间戳,所以 `pack`/`clamp`/`desc-rb`
的 GPU 列显示 0 **不代表免费**(成本落在 `map`/`wait` 列)。

---

# 五、⛔ 已经走死的路(每条都别再走一遍)

## 5.1 异步 preview BA(A1b)
六代方案穷尽,**结构性不可能无损**,用户明确拒绝"精化晚几帧落地"。**永久关闭。**

## 5.2 quadratic 预付
验证为 NOT-EXACT(提前算会改变 RANSAC 流)且**零净收益**。**永久关闭。**

## 5.3 几何候选选择器(spatial-first)⚠️ 真机判负,但质量结论未被推翻

**host 上三把独立尺子(RU / 局部壳厚 / 自由空间冲突)在两个 fixture 上一致改善,
且配对数与基线完全相同(1674/1674)⇒ host 判定"零代价"。**

**真机单变量 A/B 判负**(提取器库已回滚且两臂相同、配对数相同 11.5、场景密度相近):

| 臂 | 逐帧总 | GPU 每对 | 配对/帧 | gpuM | 拍完等待 |
|---|---|---|---|---|---|
| 纯时序 | 2827ms | **79** | 11.5 | 6280 | **209s** |
| 几何 | 5088ms | **245** | 11.5 | 6965 | **520s** |

**配对数不变、匹配数仅 +11%,而每对成本 ×3.1。**

【推断,未证实】几何臂挑"空间近但**时间远**"的帧,其描述子已不在 GPU 驻留,每对都要重新上传
8192×128;纯时序挑最近 12 帧,描述子还在。**host 构造性测不到这一维**(统一内存 + replay 全程驻留)。

⚠️ **被推翻的只是"它是免费的",不是它的质量收益。** 要复活须**先解决描述子驻留**
(例如限制成"空间近 AND 时间不太远",或给老帧做描述子缓存),不是直接删 kill switch。
现状:`setenv("OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY","1",1)` 在 plugin 里,**已关**。

## 5.4 回读 f32 → uint8 ❌ 被 WGSL 无 f64 堵死

host 量化(`official_dsp_sift_gpu_c.cc: finish_descriptor`)用 **`double`** 累加 L1 与开方:
```cpp
double l1 = 0.0;
for (int i=0;i<128;++i) l1 += std::abs((double)raw128[i]);
root[i] = (float)std::sqrt(std::abs((double)raw128[i]) / l1);
```
**WGSL 只有 f32/f16,没有 f64** ⇒ 搬 GPU **构造性不可能逐位一致**。

f16 退路也不通:f16 kernel 只是内部用 f16(`wpatch : array<f16,961>`),
**直方图是 `array<f32,128>`、输出是 `array<f32>`,注释写着 "f32 mean"** —— 6 档 DSP 的均值
必须在 f32 里累加。

【推断】若硬做:最终值 `round(512·sqrt(|x|/L1))`,f32 vs f64 的 L1 相对误差 ~1e-7 传到结果
约 5e-5,翻档概率 ~1e-4/元素 ⇒ 每帧 270 万元素**约 270 字节会变**。**属有损,需签决**,
且这个 1e-4 是推断不是测量。**判定:收益中等(~57ms)、代价是打破逐位一致这条验收线,不划算。**

## 5.5 (o,s) 剪枝提到 affine 之前 ❌ 实测集合不等价

**动机是对的**:affine+orient 是 114ms GPU(23%),跑在 27152 个点上,而 clamp 只保留
~max_features。排序键 `(octave desc, scale desc)` 在 **detect** 阶段就写好(偏移 6/7),
与 affine/orientation 输出无关。

**我的论证**:展开只会让计数变多 ⇒ 用原始计数算的截断点不早于真实截断点 ⇒ 保留超集。

**实测(`E2E_CLAMP=1`,同一二进制只切 `SED_PRUNE_PRE_AFFINE`)**:

| | 不剪枝 | 剪枝 |
|---|---|---|
| n_kept | 27152 | 11447(5 组保留 2 组) |
| affine GPU | 57.3 | 42.0 |
| orient GPU | 55.8 | 33.7 |
| descriptor GPU | 114.6 | 86.9 |
| **最终 count** | **16570** | **14568** ❌ |

**GPU 省了 65ms,但输出少了 2002 个特征 ⇒ 不是超集,论证有 bug。**

【推断】clamp 的规则是
```cpp
if (os != prev_os && kept >= max_features) break;   // 达到阈值后还要吃完当前组
```
**它在"达到 max_features 之后的下一个组边界"才停**,所以保留量可以远超 max_features
(基线 16570 ≫ 8192)。而我在 `cum >= 8192` 时就停,**停得太早**。

**要重做的话:剪枝的停止规则必须逐字复刻 clamp 的规则,而不是自己另写一个"等价"的。**
代码在树里,`SED_PRUNE_PRE_AFFINE` **默认关**;**那段注释里"set-identical"的论证是错的,
必须改掉**。

## 5.6 其余已排除(各附理由)

| 方向 | 裁决 |
|---|---|
| 每 octave 预计算梯度图(Lowe 原文规定,VLFeat 实做) | ❌ **我们是 patch 重采样路径**(covdet),梯度在重采样后的 patch 上算,不在 octave 图上 |
| orientation 窗口 `4.5σ` 随尺度爆炸 | ❌ 我们是**固定 41×41**(`PATCH_RESOLUTION 20 → side 41`),问题不存在 |
| 关掉 `estimate_affine_shape`(130ms) | ❌ **'o' 认证配置带它**,关掉=偏离认证,需签决 |
| f16 描述子 | ❌ **已是 A16 生产默认** |
| 并行档描述子(`SED_PARALLEL_DESC`) | ❌ 已验**逐字节一致**(21002/21002)但 **A16 上慢 44%**,已否决 |
| 把 sup/aff/ori/desc 简单合批 | ❌ **会算错**:四段之间夹着强制回读 + host 串行改写 + 重新上传 |
| PCA-SIFT | ❌ M&S TPAMI 2005 **在 NNDR(=我们的 ratio 0.8)口径下明确判它显著劣于 SIFT**;且它只省匹配不省提取 |
| 乘积量化 PQ | ❌ 真风险不是距离量化,是**候选池收缩会毁掉 ratio test**(CVPR 2021 实测:重建视图 282→136) |
| 二值描述子(BinBoost/LDAHash/BRIEF/BRISK) | ❌ 质量差数量级;BinBoost 是 **GPL v2**;LDAHash 许可未核实 |
| SURF | ❌ **专利 US8165401 仍有效** |
| 移动 GPU 做 BA 线性求解 | ❌ 唯一非 CUDA 先例要求 `shaderFloat64`,移动端全线不支持;RTX 3090 上 local BA 只有 1.2× |
| local BA `function_tolerance` | ❌ **实测判死**:撞满迭代上限那次根本走不到容差判据,收敛那次已被 `gradient_tolerance=10.0` 提前停 |
| ANE / LiDAR | ❌ 用户明令禁止 |

---

# 六、调研结论(全部带出处)

## 6.1 法务(⚠️ 有两条是新风险)

| 项 | 结论 |
|---|---|
| **SURF 专利 US8165401B2** | ⚠️ **仍然有效**。两个 agent 给的到期日不一致(**2029-04-13** vs **约 2027-04**),**要用到再单独核**。别把 US7970226 当成 SURF 专利(那是微软的) |
| **DSP-SIFT 专利申请 15/345373** | ⚠️ **新风险,未记录过**。UC Regents,"Domain-Size Pooling for Image Descriptors",2016 申请,US2017/0243084A1。**授权状态未核实**(Google Patents 503)。**我们是出货 DSP-SIFT 的**,而 COLMAP 以 BSD 分发实现 —— **版权许可 ≠ 专利许可**。建议查 USPTO Patent Center |
| SIFT 专利 US6711293B1 | ✅ 2020-03 已过期 |
| **COLMAP vendored 的 SiftGPU** | ❌ **UNC 非商用学术许可,不是 MIT**。即官方 `use_gpu=true` 的 SIFT 路径本身就是污染源,**我们自研 WGSL 提取器是唯一合规出货路径** |
| FAISS / OpenCV 4.x / VLFeat / CudaSift | ✅ MIT / Apache-2.0 / BSD-2 / MIT |
| PopSift | ✅ MPL-2.0(文件级 copyleft,链接进闭源 OK) |
| BinBoost | ❌ GPL v2 |

## 6.2 COLMAP 官方源码里的两条硬事实

- **`feature/index.cc` 逐字**:*"SIFT descriptors are natively uint8, so QT_8bit_direct
  quantization is lossless and faster than flat indexing."*
  ⇒ **COLMAP 的工程答案:候选可近似(IVF/nprobe),距离必须无损。它刻意没用 PQ。**
- COLMAP 官方 FAQ 的提速清单里**完全没有 `ba_local_num_images`** —— 上游从未把它当性能杠杆。

## 6.3 `first_octave` 两份矛盾记录的调和(两份都对)

- **@4032px**:`fo=0` 单独就产 21002 候选 ≫ 8192 上限,`o=-1` 多出来的被粗优先 clamp 砍光
  ⇒ **等价,且省 2× 检测 / 4× 显存**
- **@2048px**:只产 3322 < 上限,`o=-1` 真进保留集 ⇒ **`fo=-1` 确实更好**

**旧记录"first_octave=0 守质量"需加「@2048 才成立」的限定。**

## 6.4 ratio test 的两条实测(与我们的 0.8 + cross-check 直接相关)

- **CVPR 2021**(Barath et al., Efficient Initial Pose-graph Generation):缩小候选池会让
  ratio test 失效 —— 不修正阈值,**重建视图数 282→136(−52%)、track 数 −68%**
- **IJCV 2021**(Image Matching across Wide Baselines):**ratio test 在 ORB/AKAZE/FREAK 上
  也优于距离阈值** ⇒ "Hamming 破坏 ratio test"这个常见说法**站不住**

## 6.5 RootSIFT ⭐ 唯一零成本的**质量**杠杆(不是速度)

L1 归一化 + 逐元素开方,**两行数学**。零成本、零存储、零许可风险、**下游一行不用改**
(仍是欧氏距离)。原论文 14/14 组对比全胜(tf-idf 基线 +7.4%~+12.8% mAP)。
⚠️ **那是图像检索口径,在 SfM 注册/三角化上的收益未核实。**

## 6.6 几条需要修正的既有记录

1. **SCALE-6 在 `sift_extract_dawn.h` header 里的论证算错了** —— 声称顶档落在 3.0,
   **实为 2.528**(10 档时 2.717),且掩盖了一次真实质量变化。**我引用过这条代码注释当证据,
   是错的。**
2. **记忆库"RS 4 万特征预算"应改为"检测 4 万、进匹配 1 万"** —— 和我方 8192 同量级
3. `GPU_DSP_SIFT_PLAN_AFFINE_OFF.md` 是**已被否决**的方案,需标注作废(我引用过它)
4. **vendored COLMAP 4.1.x 已内建 ALIKED + LightGlue + ONNX**,只是 iOS 没编进去 ——
   这改变了"换前端"的下游代价估算

## 6.7 WebGPU/Dawn 的硬约束

- **WGSL 只有 f32/f16,没有 f64**;f64 提案(gpuweb#2805)2022 年开到今天没动工;
  Apple GPU 也不会有硬件 f64
- 单次 dispatch API 开销:**Metal/Safari 31.7 μs、wgpu-native 71.1 μs**(Apple M2 实测)
- **同一 compute pass 内多次 dispatch 有隐式屏障**(Dawn 技术负责人 Kangz)

---

# 七、⚠️ 我今天犯的八个错误(重点读,别重犯)

| # | 错误 | 根因 | 教训 |
|---|---|---|---|
| 1 | 用**等待时间**当性能指标 | 它混合了「计算成本」和「用户拍多快」 | **只用 ms/帧** |
| 2 | 换库换错目录(`aether_ffi` vs `official_sfm`) | 没查 podspec 就按名字猜 | **先从 `-force_load` 反查** |
| 3 | 用 `nm Runner` 验证动态框架 | 动态框架符号不在主二进制 | 查 `.app/Frameworks/…` 里那份 |
| 4 | 查"native 有没有变"查错目录,得出"native 未变"的错误结论 | 同 #2 | 同 #2 |
| 5 | 断言"host 循环占 53%" | **冷启动的着色器编译(1314ms)藏在残差里** | **先加 `create_ms` 再下结论** |
| 6 | (o,s) 剪枝的保守界论证 | 自己另写了一个"等价"规则,没逐字复刻 clamp | **铁律:逐字照搬,不自创** |
| 7 | 引用**代码注释**当证据(SCALE-6 顶档 3.0) | 注释的算术是错的 | 注释不是证据,要自己算 |
| 8 | `cmd \| grep -c` 放在链尾 → 计数 0 时 grep 返回 1 → 误判构建失败 | | **别把 grep 放链尾** |

**共同模式:三次"变慢"排查我都是先有假设再找证据,连错三次;第四次改成先看数据
(冷启动速度一致)才排除了代码。**

---

# 八、07-27 → 07-29 的那次回归(已解决,存档)

**症状**:拍完等待从历史的 23 秒劣化到 451-526 秒。

**定位**:遥测里 `queue_drain` 的历史序列卡死窗口 → 窗口内 27 个提交只有一个碰了 native →
`4c69e07 07-27 21:06 feat(selection): 选区交互精修…;gpu-extract 归档同步`
(**native 二进制替换被埋在一个 UI 提交里,标题只在末尾附了半句**)。

**逐目标文件取证**(`ar x` 后逐个 `cmp`):

| | 旧 → 新 | |
|---|---|---|
| `dawn_kernel_harness.o` | 50232 → 55552 | +5320,新增 `SetUncapturedErrorCallback` + `take_device_error` |
| `sift_extract_dawn.o` | 44344 → **44304** | **−40** |
| **13 个 WGSL 着色器** | — | **全部逐字节相同** ⇒ **检测算法一个字节没改** |

**回滚**(`git show 5d272d9:<path> > <path>`)后:**GPU 每对匹配 226 → 79ms(基线 78)**,
拍完等待 526 → 209s(且帧数更多)。

⚠️ **精确因果仍未逐行坐实** —— 只做到"只有这两个文件变了 + 机理自洽"。
`aether_cpp` 侧的源码 diff 没拿到(那个仓 git 慢,查询转后台后未回收)。

---

# 九、现在手机上的状态(07-29 07:47 那个包)

| | |
|---|---|
| 候选选择器 | **纯时序 K12**(`STREAM_TEMPORAL_ONLY=1` 活代码) |
| `LIVE_CAND_K` | **从未设过**,K30 没上过机 |
| GPU 提取器库 | **已回滚**到 `5d272d9` 版(261368 字节) |
| AR 点径 | **6**(用户签决,不再动) |
| local BA 线程 | **`LiveBaThreads()`=4 + 多线程门槛 6000**(已装机) |
| T2 插桩 | 已装机 |
| Dart 等待埋点 | 已装机 |
| 自动命名 | 已修(读已占用名字集合,补最小空号) |

---

# 十、还开着的口子(建议优先级)

## 10.1 真机上最大的两块

| | ms/帧 | 占比 | 已知情况 |
|---|---|---|---|
| **特征提取** | 1156-1267 | **45%** | 见 §四.2 的热态拆分:descriptor 40% / desc-rb 15% |
| **GPU 匹配** | 917 | **32%** | 每对 79ms 已回到基线;**热降频 4.3-8.8× 是独立问题** |

## 10.2 具体候选

1. **⭐ 先在真机上跑一次 `AETHER_GPU_TIMESTAMPS=1`**
   —— host 的热态分布(descriptor 40%)**没在 A16 上验证过**,而 A16 的 GPU/CPU 比例和 Mac
   完全不同。**在真机数据出来之前,不要按 host 的比例排序。**
   ⚠️ 需要把 env 传进 App(plugin 的 `setenv` 块),并确认 A16 的 adapter 支持 `TimestampQuery`。

2. **(o,s) 剪枝重做** —— 停止规则**逐字复刻** clamp(达到阈值后吃完当前组)。
   host 实测的 GPU 收益是 **−65ms/帧**(affine 57→42、orient 56→34、desc 115→87),真实可观。

3. **热降频本身** —— GPU 每对 27→117-333ms。冷启动一致说明不是代码。
   **这是"发热不是借口=热稳定是硬约束"那条铁律的第一份完整定量证据。**

4. **tail 里的 O(N) 项** —— 每帧一次 `DatabaseCache::Create` +
   `BeginReconstruction` 的全量三重循环,拟合 `tail_ms = −2.3 + 1.429×帧号(R²=0.958)`,
   **外推 300 帧 = 426ms/帧、累计 64s**。上游 **PR #4279 已在 vendored 的 4.1.0 里**,
   原话就是为 "streaming/online use" 加的。

5. **K30(质量杠杆,不是速度)** —— host 四臂实测:配对数 ×2.34,但每对成本降到 0.71 倍
   (更多配对摊薄固定开销),**host 流式总时长只 +16%**,local BA 几乎不涨。
   折算真机【推断】:逐帧 2827 → ~3570ms(+26%),等待 209 → ~340s。
   质量:`share(RU>10)` 70.4% → 65.6%(−4.8pp,拿到几何+K30 组合收益的 3/4,且不带几何臂那个坑)。
   **⚠️ 在逐帧成本压到快门间隔以下之前上 K30,是在已欠债的系统上加杠杆。**

## 10.3 验收纪律(每一刀都要过)

1. **默认关**:env 未设 = 逐位等同改动前
2. **开关两态输出逐字相同**
3. **几何逐位一致**:`n_points` / `track3plus` / `n_obs` / `mean_reproj_px` 四项全等
4. 不逐位 → **必须用三把尺子(RU / M1 壳厚 / M4 自由空间)证明落在噪声带内**,
   并**明确报"噪声带内"而不是"无损"**
5. **单变量**:一次只动一个东西。今天三次误判的根子都在"一次动多个 + 没有干净基线"

---

# 十一、给你的第一句建议

**别急着写代码。先做 10.2 的第 1 条:在真机上开 `AETHER_GPU_TIMESTAMPS=1` 拍一次。**

理由:今天全部的提取器优先级都来自 **Mac 上 2400×1800 合成图的热态数字**。而真机是
**A16 + 4032×3024 + 8192 特征 + thermal=serious**,四个维度全不同。
**我已经因为"拿 host 的比例排真机的优先级"浪费了一整天优化 local BA(host 56.5% / 真机 16%)。
别重犯。**
