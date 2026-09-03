# 实测:M3 Pro 上 Dawn 暴露的子组矩阵配置(2026-09-03,主线亲测)

探针源码 `~/Developer/pw_matcher_speed_20260903/sgmatrix_probe.cc`(枚举全部 config,
非只查 f32;需 `allow_unsafe_apis` toggle 才能看见实验特性 —— 与生产 TU 同法,
pwofficial_gpu_match_dawn.cc:855-861)。本机 Dawn = aether_cpp 固定子模块。

```
adapter="Apple M3 Pro"  subgroup range=[32,32]
features: subgroups=1 subgroup-matrix=1 shader-f16=1 timestamp-query=1
subgroup matrix configs: 2
  cfg[0] in=f32 out=f32 M=8 N=8 K=8
  cfg[1] in=f16 out=f16 M=8 N=8 K=8
```

**判决**:Dawn 的 `SubgroupMatrixComponentType` 枚举**有** U8/I8/U32/I32/F16/F32
(webgpu_cpp.h:716-722),但 M3 的 Metal 后端**只填两条同进同出配置**:
- **没有 f16→f32 混合精度**(= Metal `simdgroup_matrix<half>`+f32 累加,原生 4.9ms 的根因);
- **没有 u8/i8→i32 整数 MMA**。

⇒ "用 WGSL 拿到 Metal 同款混合精度 MMA"这条路在本机 Dawn 上**不可得**(上游 tip-of-tree
是否已加、需要哪个 toggle,英文线在查)。**timestamp-query=1** 是好消息:分块成本模型
可以换成每缓冲 GPU 时间戳(之前只能用墙钟,是默认分块多花 2.5ms 的一半原因)。

## 由此得到的主攻方向:f16 两阶段精确法(算法路,不依赖硬件)

f16→f16 MMA **可用**,且 08-01 实测在老结构上 26.2→19.0ms(1.38×)。u8 点积和上限
128×255²=8,323,200 远超 f16 上限 65504 ⇒ 直算必溢出;**但可缩放**:u8/16 → 值域 [0,15.94],
逐积 ≤254,K=128 累加 ≤32,512,**在 f16 内不溢出**(累加结果 = 精确 dot/256)。
两阶段构造(可证逐字节等价):
1. 阶段一 f16 MMA 得近似 dot 与**误差界** ε(需推导:16 次 K=8 累加的 f16 舍入界);
2. 每行取"近似最大值 ± 2ε 覆盖到的候选集"(通常 1-3 个),**只对候选做精确整数重算**
   (每行几×128 MAC,相对 8192×128 可忽略);
3. 阶段二给出精确 dot ⇒ top-2 与 ratio 门与全精确路径**逐位相同**。
理论天花板:8192×8192×128 = 8.6 GMAC = 17.2 GFLOP;M3 Pro f32 峰值 ~7 TFLOPS ⇒
Metal 4.9ms ≈ 3.5 TFLOPS(50% 峰值),我们 11.0ms ≈ 1.6 TFLOPS(22%)。f16 通道翻倍
+ 候选重算开销 ⇒ 有望进入 5-6ms 区间,即**追平量级**。风险:f16 误差界若太松会让候选集
过大、阶段二吃掉收益;需实测。
