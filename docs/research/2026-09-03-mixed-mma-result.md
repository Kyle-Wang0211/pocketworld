# 混合精度 MMA 核:实测结果(2026-09-03 23:xx,主线亲手实现与验证)

## 改动(生产 TU `vendor/official_sfm/src/pwofficial_gpu_match_dawn.cc`)
- vendored Dawn 的 Metal 后端登记第三条子组矩阵配置 `f16 in → f32 out 8×8×8`
  (`PhysicalDeviceMTL.mm`,证据链见 2026-09-03-sgmatrix-probe-m3.md);
- TU 新增混合后端:探测 `sgcfg_f16_f32`、按需请求 `ShaderF16`、`MixedWgsl()` 从**同一份 WGSL
  单一真源**派生变体(只把 Left/Right 与 A/B/Bsh 换 f16,**Res/accSh/门/平局语义一字不改**)、
  描述子上传改 u8→f16(**无缩放,u8 在 f16 中精确**)、`DescBytes` 减半;
- guided 两趟 shader 同样走 `MixedWgsl`(否则按 f32 读 f16 数据 ⇒ 0 匹配,已被 ABI 测试抓到并修);
- 可观测面加 `f16_f32=` 与 `mixed=`(装机≠生效的核验手段);env
  `OFFICIAL_AETHER_MATCH_DAWN_KERNEL=mixed` 选中(默认仍 f32,单变量纪律)。

## 为什么逐字节精确(构造性)
u8 ≤255 在 f16 中精确(11 位有效数字);逐积 ≤65,025、K=128 总和 ≤262,144(L2=512 的
Cauchy-Schwarz 上限)均在 f32 的 24 位尾数内精确 ⇒ 点积与 f32 路径**完全相同的整数**。

## 门(全部主线亲手跑,mixed=1 已由可观测面证明生效)
| 门 | 结果 |
|---|---|
| parity 套件 19 案例三重金标准 | **PASS** |
| 全量闸 20 帧库 | **162/162 逐字节** |
| 全量闸 51 帧库 | **534/534 逐字节** |
| guided 对拍(Metal v1 vs 混合 Dawn)148 案例 | **79,082 对全部逐字节相同,0 发散** |
| ABI 测试(probe_batch/驻留/参数/guided) | **0 失败** |

## 速度(镜像 ABBA,7 reps × warmup 2,同 8192² 真实夹具)
| 臂 | GPU p50 | wall p50 |
|---|---|---|
| a1 f32 基线 | 13.889 | 14.853 |
| b1 **混合** | **10.993** | 11.551 |
| b2 **混合** | **8.893** | 9.453 |
| a2 f32 基线 | 13.844 | 14.818 |
| native Metal 括号 | — | 5.280 |

**括号干净**(两个 f32 臂相差 0.045ms)⇒ 采纳。paired:f32 13.867 → 混合 9.943 =
**−3.92ms / −28.3%**。离 Metal 从 ~2.6× 收窄到 **~1.7-2.1×**(混合两臂自身差 2.1ms,
机器仍有 HydraRenderingService 97% + WeChat 51%,安静窗可复测收紧)。

## 下一刀(f16 腾出的预算,尚未做)
Bsh 从 16KiB 降到 8KiB ⇒ 空出 8KiB。之前被 32KiB 预算枪毙的两把刀复活:
(a) 列 tile 32→64(B 复用翻倍、barrier 减半);(b) 真双缓冲。单变量分别量。

## 装机前置(未做)
1. 重编 **iOS** 侧 Dawn(`aether_cpp/build-ios-device-dawn`,带同一补丁);
2. 更新 `build_xcframework.sh` 的 `PWOFFICIAL_DAWN_SHA256` 钉子并记入 PROVENANCE;
3. 决定 dawn 后端的默认核(建议:检测到 `f16_f32` 即默认 mixed);
4. 🔴 **速度闸尚未达标**:我此前写死"dawn 上机前置 = 主机 8192² GPU ≤ Metal 4.9ms",
   现在是 8.9-11.0ms(1.7-2.1×)。**是否在未追平前上机,需用户裁决。**

## 第二刀:关掉 tint 的健壮性代码(2026-09-03 23:5x)—— 再 −28%

**发现方式**:给 TU 加 `dump_shaders`(**设备级** toggle,挂实例无效)+ 设备日志回调,
把 tint 生成的 MSL 打出来,与手写 Metal 核逐段对比。MMA 最内层循环(16 次 / 列块 / 行块)里
tint 生成了:
```
simdgroup_half8x8 v_46 = make_filled_simdgroup_matrix<half,8,8>(0.0h);   // 零填充
if ((((v_45 + (128u*7u)) + 8u) <= 4096u)) { simdgroup_load(...); }        // 边界检查
simdgroup_float8x8 v_49 = make_filled_simdgroup_matrix<float,8,8>(0.0f); // 累加器零填充
simdgroup_multiply_accumulate(v_49, v_25[v_44], v_48, v_43); v_43 = v_49; // 再拷回
```
手写 Metal 是 `simdgroup_multiply_accumulate(c, aFrag[k], bF, c);` —— 原地,无填充无检查。
**确认混合精度真的生效**:`v_49` 是 float、两个操作数是 half ✓。

**处置**:开启 Dawn 设备 toggle `disable_robustness` + `disable_workgroup_init`。
安全性论证:索引由构造在界内(主机把两张描述子表补齐到 128 行倍数并零填充、outAB 按补齐
行数超额分配 —— TU 头部的 Zero-padding invariant;Bsh/accSh 偏移由 BT/WGR 常量界定);
共享内存 Bsh/accSh **全部写后读**(Bsh 每块整体覆盖含填充列,accSh 由 subgroupMatrixStore
16 个子组 × 4 个 nt 全覆盖),不依赖自动清零。生成的 MSL 里边界检查已消失。
env `OFFICIAL_AETHER_MATCH_DAWN_ROBUST=1` 可切回做单变量 A/B。

**镜像 ABBA(括号 11.046/11.217,差 0.17ms,干净)**:
| 臂 | GPU p50 | wall |
|---|---|---|
| 健壮性 ON | 11.046 / 11.217 | 11.6 / 11.9 |
| **健壮性 OFF** | **7.890 / 8.113** | 8.4 / 8.8 |
paired **−3.13ms / −28.1%**;四臂 pairs SHA 全同。

**门(全部重跑)**:parity 19 案例 PASS · 全量闸 162/162 + 534/534 · guided 148 案例
79,082 对逐字节 · ABI 0 失败。

## 累积进度
| 配置 | GPU p50 | 对 Metal(5.28 wall) |
|---|---|---|
| f32 + 健壮性(战役起点) | 13.87 | 2.6× |
| 混合精度 | 9.94 | 1.9× |
| **混合精度 + 关健壮性** | **8.00** | **~1.5×** |
累积 **−42%**,全程逐字节无损。分块只值 0.22ms(2.4%,已用干净 ABBA 结案,不是杠杆)。

## 第三、四刀:两个负面结果(都已撤销,机制记账)

### 手工展开 K=16 循环 —— 无可测收益
动机:生成的 MSL 把 A 片段做成 `tint_array<simdgroup_half8x8,16>` 并在内层用**变量下标**
访问(`v_22[v_35]`),担心它落到线程内存而非寄存器;tint 还把 for 生成成
`while(true){if(c){}else break;}`,不利于后端展开。
实装:把两个 K=16 循环在 WGSL 里写成 16 条直白语句(A 片段变成 16 个独立命名变量),
生成的 MSL 里矩阵数组确实消失(`tint_array<simdgroup_half8x8` 0 处,16 条独立 MMA)。
**镜像 ABBA:循环 7.932 vs 展开 7.886 = 0.046ms,而括号自身差 0.38ms ⇒ 噪声内,不采纳。**
结论:Metal 后端编译器本来就处理好了这个模式(常量循环边界),tint 的动态下标不是瓶颈。

### 向量化 B staging(vec4<f16>)—— 反向,被 WGSL 接口堵死
动机(对比手写 Metal):Metal 的 tile 是 `threadgroup half4 Bsh4[...]`,每次访存 8 字节;
我们逐个 f16 搬(2 字节)。B 的设备内存流量约 134MB/对(64 workgroup × 8192 × 128 × 2B)。
实装:B **绑定**改 `array<vec4<f16>>`(主机字节不变,只换视图),staging 一次读一个 vec4
写 4 个 Bsh 元素;pairs SHA 仍逐字节相同。
**镜像 ABBA:标量 11.12 vs 向量化 14.16 = 慢 3.0ms**(两个镜像半程方向一致)。
机制:**只有设备端的读被向量化,写进共享内存仍是 4 次标量写** —— 而
`subgroupMatrixLoad<Right>(&Bsh, …)` 要求**标量数组**,所以 Bsh 无法像 Metal 那样直接存成
half4。读写不对称反而更差。⇒ **WGSL 的 subgroupMatrixLoad 接口封死了这条路**,撤销。

## 本轮小结(累积 −42%,两把失败刀已撤净)
| 配置 | GPU p50 | 对 Metal(5.28) |
|---|---|---|
| f32 + 健壮性(起点) | 13.87 | 2.6× |
| 混合精度 | 9.94 | 1.9× |
| **混合精度 + 关健壮性(现役候选)** | **7.9-8.1** | **~1.5×** |
未尝试(需结构改动,风险较高):WGR 128→256 + BT 32→16(B 流量减半、barrier 翻倍;
f16 预算下装得下,但扫描循环按 lid↔行 映射,改 WGR 要动线程/行的对应关系)。
