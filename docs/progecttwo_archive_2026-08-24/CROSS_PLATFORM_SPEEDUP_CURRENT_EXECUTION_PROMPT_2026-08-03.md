---
artifact_contract: "ce-handoff/v1"
created_at: "2026-08-03T06:08:17Z"
title: "PocketWorld 跨端生产管线提速当前执行提示词"
summary: "汇总当前产品母版纪律、跨端架构、已完成实验、201 帧真机结果、否决路线和下一轮大幅提速计划。"
keywords: ["PocketWorld", "Aether3D", "cross-platform", "speedup", "Metal", "Vulkan", "tail-cache", "strict-8192"]
cwd: "/Users/kaidongwang/Documents/progecttwo"
resume_focus: "保留当前本地完整产品功能，只修改生产重建管线；基于物理 iPhone 冻结输入，优先大幅压低匹配/建图与特征提取耗时，并把算法核心收敛到共享 C++ + 原生 GPU 后端架构。"
---

# 可直接交给下一位 Agent 的极致详细执行提示词

> 以下正文可以原样交给下一位 Agent。它是当前执行入口，但不替代代码、
> OpenSpec、测试、哈希和实验原始数据。发生冲突时，以执行当下的代码、测试、
> 配置、手机日志与本文件列出的权威 artifact 为准。

---

## 你的身份与唯一任务

你接手的是 PocketWorld / Aether3D 的**跨端生产重建管线提速**。你的任务不是
继续搭仪器、重做已经完成的法医调查，也不是重写产品 UI。你的唯一主线是：

1. 保留当前本地 PocketWorld 最新、最全的全部产品功能；
2. 只在明确命名的生产重建管线组件内做提速；
3. iOS 当前继续使用 Metal 热核，Android/鸿蒙以后接 Vulkan，算法、调度、
   数据结构和 C ABI 尽量统一到 C++；
4. 不降低点云质量，不偷换特征/匹配/BA 语义；如候选确实改变特征集合，必须
   作为明确的质量候选单独比较，不能伪装成 exact 优化；
5. Mac/host 只用于诊断、开发、byte-exact 验收和快速筛选；任何生产速度、
   质量、参数赢家最终必须在用户的物理 iPhone 14 Pro / A16、真实生产管线、
   同一冻结输入上裁决；
6. 优先寻找能砍数百毫秒甚至秒级的大结构改造。0.x–几毫秒的优化可以记录，
   但不能占据主线。

当前旧目标是把逐帧处理从约 2827 ms 压到不高于 1642 ms。最新 201 帧 ON
实测 final-third p50 约 2996 ms，因此按最新诊断口径仍约有 **1354 ms/帧**
的缺口。不要把这个缺口用未经实测的“理论收益”填满。

---

## 一、用户的真实产品要求

### 1. 产品与体验要求

- 前端快门必须一直流畅。后端允许排队，但不能因为后端忙让快门长期变灰、
  页面卡死或 170/200 帧闪退。
- 原始高分辨率照片必须保留，因为建模、贴图、颜色恢复和用户项目都需要它。
- 拍摄或重建运行时，后台压缩必须暂停；任务结束后再续跑，而不是取消任务。
- 点云质量不能为速度让路。用户会把原版和候选 PLY 并排肉眼盲评，同时看
  注册帧、连通性、重投影误差、track、覆盖、点数和失败率。
- 不得限制用户拍什么模型、在什么光照下拍摄；算法必须面对真实场景。

### 2. 跨端目标

最终架构方向已经定为：

```text
共享 C++ 算法核心、调度、数据结构和 C ABI
                  ┌─ iOS：Metal
统一 GPU 后端契约 ├─ Android：Vulkan（能力探测后选择 dot4/标量）
                  ├─ 鸿蒙：Vulkan（同样必须能力探测）
                  └─ C++ SIMD：功能保底

Dart / Flutter：产品 UI、任务状态、队列与 FFI 编排；不承载重计算热核
```

这个架构**可行且是当前终态方向**，但不要谎称已经三端完成：

- 当前生产 iOS 已经有 Flutter/Dart 产品层、C++ SFM 核心、Metal
  提取/匹配热核；
- 共享 C++ 核心和 C ABI 已经存在，但仍有后端与产品路径硬编码需要解耦；
- portable Dawn/WGSL matcher 已有 byte-exact 台架，但在 Apple/M3 上仍比
  native Metal 慢约 2.65 倍，只保留作跨端语义验收载体；
- Android/鸿蒙 Vulkan 生产后端尚未在真实设备完成，不是当前手机阶段的阻塞项；
- Apple 不应为了“统一”放弃 Metal。统一发生在 C++ 算法、数据结构、接口和
  验收语义，GPU kernel 允许按平台原生实现。

建议后端契约至少覆盖：创建/销毁、能力与加速属性查询、descriptor
prepare/residency、K12 match、同步/结果读取、失效与资源释放。所有后端必须
复刻同一 top-2、严格大于、first-maximum、ratio、absolute gate、cross-check、
mutual 和奇数/空输入语义。

---

## 二、三个工作区与当前现实状态

### 1. 路径

- 产品仓：`/Users/kaidongwang/Developer/pocketworld`
- 跨端/算法仓：`/Users/kaidongwang/Developer/Aether3D-cross`
- 计划与耐久证据：`/Users/kaidongwang/Documents/progecttwo`

### 2. 当前本地状态不是干净提交，绝不能用 Git 提交代替产品母版

在本提示词生成时，只读观察为：

- PocketWorld HEAD：`7e5a0c2e0ddd5385a20f3964605f5dc33c67381b`
- PocketWorld `git status --porcelain -uall`：约 376 项；大量最新功能仍在
  staged/unstaged/untracked 状态；
- Aether3D-cross HEAD：`b930ab185135dfbd172aef7c2bbeed67ef315f75`
- Aether3D-cross 有大量实验源码、OpenSpec、生成物与 build tree；当时状态
  枚举约 45,653 项，绝对禁止 `git clean`、`reset --hard`、整树回滚或“为了
  干净”丢弃任何文件。

这些数字只是 2026-08-03 的观察，执行时必须重新只读核对。**执行当下的本地
完整工作树（HEAD + staged + unstaged + 与产品有关的 untracked）才是产品母版。**

### 3. 旧冻结快照只能用于审计，不能覆盖当前最新版

旧审计快照：

`/Users/kaidongwang/Documents/progecttwo/_artifacts/pocketworld_latest_product_mother_20260803/`

- 归档：`pocketworld-latest-product-source.tar.gz`
- SHA-256：`ff71a1f3dedc6fe92f7c6e145ccaa5dc8e5c75f90f6190068c476fb91dbf5dd6`
- 快照时 HEAD：`c085a84d327f036b2345522889f8d9f422c957b8`

该快照在创建后，别的 Agent 又加入了更新的选区编辑行为，且本地 HEAD 后续
继续前进到 `7e5a0c2...`。因此它是“历史可恢复证据”，**不是下一次构建的
产品母版**。每次开始新的安装任务，应从执行当下的本地完整树重新冻结一个
轻量身份清单，而不是复用旧 carrier。

---

## 三、安装与合并的永久硬规则

用户已经多次遭遇：Agent 为了改一小段 native 管线，从旧 Runner/旧 carrier
整包构建安装，导致选区编辑、取消语义、压缩调度、快门修复等最新产品功能
被覆盖。以后严格执行以下规则：

### 1. 每次先声明更新类型，禁止自行升级范围

- `PRODUCT_ONLY`：只改 Flutter/Dart/Swift 产品功能；生产管线 payload 必须
  与冻结前 unsigned payload 逐字节相同。
- `PIPELINE_ONLY`：只改生产 C++/Metal 管线；Flutter Dart AOT 和产品资源必须
  与执行当下本地产品母版逐字节相同。
- `PRODUCT_AND_PIPELINE`：只有用户明确同时要求两者时才允许。发现意外双变化
  必须停止，不能自行把任务改名成 C 后继续安装。

### 2. 构建时的关键事实

`flutter build ios` / Xcode 可能自动重建并嵌入本地 native framework。即使
Agent 没手改管线源码，产物里的 framework 也可能变化。因此：

- 产品侧构建完成后，如果任务是 `PRODUCT_ONLY`，必须覆盖回冻结的正确 pipeline
  payload，并且覆盖后禁止再触发任何 Xcode/Flutter link；
- 管线任务必须从**当前本地产品母版**构建产品载体，然后只替换/链接本次命名
  的管线变更；不得从旧 Runner 起步；
- 身份比较以**签名前 unsigned payload**为准。codesign 会改变 Mach-O，不能拿
  签名后哈希判断源代码是否被修改；
- 未满足 AOT/pipeline 不变量就停止，不允许“先装了再说”。

### 3. 生产手机数据保护

- bundle 固定为 `com.kyle.PocketWorld`；
- 绝不 uninstall、reinstall、`flutter drive`、换 bundle、清 App 容器；
- 原位更新前分别备份 `Documents` 和 `Library`，逐文件哈希；
- 只允许 `devicectl device install app` 原位更新；
- 更新后再次复制并核验旧文件全部存在且逐字节一致；仅
  `Library/SplashBoard/Snapshots/**` 可按 runbook 排除；
- 失败就停，不准换包、换安装方式或清数据重试。

### 4. 环境变量不是持久配置

`OFFICIAL_AETHER_TAIL_CACHE_V1=1` 等 env 只属于一次进程。进程上滑关闭、崩溃、
被 iOS 回收、手机重启或重新安装后都会消失；从桌面图标重开不会自动继承。

实验期必须用 fresh-process launch JSON 证明开关；候选正式接受后，应改为：

1. 生产默认 ON；
2. 保留持久化紧急关闭开关；
3. env 只用于实验强制 OFF/ON。

---

## 四、当前生产语义，禁止混淆

- `K12`：每个新帧最多匹配最近/选中的 12 个候选帧，是匹配候选窗口；
- `Local BA = 6 images`：COLMAP `IterativeLocalRefinement` 默认选当前图加最多
  五个最相关邻居，共六图；这不是 K12；
- “official route”并不代表真正调用了另一套上游算法。仓库里的
  `verify_source_parity.py` 明确证明 native official route 是 frozen self-route
  source copy，通常只允许 ownership 名称不同；
- 当前生产 Metal matcher 语义是 u8 descriptor 存储 → 精确转 FP16 → FP16
  乘法 → FP32 累加；不能改成 f16 累加，也不能缩放后舍入冒充 exact；
- descriptor 已经在 legacy clamp 之后计算。旧建议“把选择提前到 descriptor
  前”早已是现状；从 legacy 约 9k–16k 行降到严格 8192 需要改变选择语义，
  不能再声称是纯 exact 止血臂；
- 当前 strict/canonical selector 仍是关闭的实验路线，不得因代码存在就默认为
  生产已启用。

---

## 五、已经完成并取得的成效

### A. 恢复快版并保留安全行为

此前出现过一次约 2.8 倍回退：慢归档只含提取器代码，matcher 代码为零，
但 matcher 耗时也被放大，说明可能有热耦合/GPU 争用乘数。用户已明确：不用
继续追究该负收益路线的根因；保留黑帧、零纹理和错误安全保护，撤下负收益
部分，继续走其他优化。不要重新开这条法医主线。

### B. 前端拍摄稳定性已经显著改善

- 修复了进入拍摄页时快门长期灰色的启动竞态；用户多次 1–3 帧进出测试未复现；
- 建成前端零阻塞快门/后端排队路径；用户 200/201 帧拍摄时前端几乎始终流畅；
- 201 帧 ON 运行 SceneKit p50 28.85 FPS、p90 29.4 FPS，无闪退；
- 这说明 172 帧崩溃不再是必然队列容量上限。当前主要问题已经转为后端每帧
  处理慢和拍摄后等待长，而不是用户不能连续点击快门。

### C. portable exact matcher 台架从 43 ms 压到约 13.4 ms

Mac/M3 host 诊断路线的关键结果：

- f32 exact SR-2：约 26.2 ms；
- SR-3A 双向融合：约 13.87 ms，byte-exact，约 -46.7%；
- 更高功效逐对交替协议确认 `fusedr128` 胜 r64，portable exact 正式约
  13.4 ms；
- native Metal 同口径约 5.0 ms，portable 仍慢约 2.65 倍；
- S1 staged+预转置 resident 约 12.73–12.81 ms，只是 +3.6% 小效应，低于
  预注册门，PARK；
- Direct-B 两布局、WGR 80/96/112 甜点、16-way 列归并均已否决；
- Apple 上“用 WGSL 替代 Metal”路线正式停止。fusedr128 台架继续作为未来
  Vulkan 后端的 byte-exact/golden 验收工具。

边界：这些是 host kernel 台架数据，不是手机生产速度结论。

### D. f16 近似路线被正确否决

`mma16` 约 19.0 ms，但与 native 结果不 exact：2107 对 vs 2155，对集合偏差
约 6.40%。缩放防溢出也会改变阈值边界。该路线只能作为低优先级“近似筛选+
精确复核”研究，当前生产 credit=0。

### E. BatchK12 host 大刀被实测关闭

真实 batch-v2 台架：同一 command buffer、一次 wait、Q 表只上传一次，生产
v2 fused+merge MSL 机械抽取，逐 invocation byte-exact。

- 生产 v2 ABI×12 p50：70.6 ms；
- Batch：67.99 ms；
- paired median 收益：2.236 ms / 3.2%，95% CI 不含 0；
- 低于预注册 10% 门，`REJECT_BELOW_GATE`；
- 不因台架已完成而降低门槛。

设备上的热压/相机竞争假设没有由 host 判死，但不得把 BatchK12 当作当前主线。

### F. strict-8192 真机 count-only 探针已成功拿到第一手分布

31 帧 production GPU Stage-B 观测，join 完整：

- preclamp：min 7406 / median 14321 / p90 19531 / max 21782；
- legacy descriptor rows：min 7406 / median 9280 / max 10885；
- 29/31 帧 legacy 超过 8192；
- strict-8192 相对 legacy 共少 36,712 行，平均约 1184 行/帧；
- 24/31 帧 preclamp 超过 12288，因此 Fixed-12288 不构成性塌缩；
- 该窗口只证明规模，不证明 strict/coverage 质量，也没有 production speed
  credit。

权威文件：

`/Users/kaidongwang/Documents/progecttwo/_artifacts/strict8192_stage_b_on_smoke_raw_SWIyNB/on-smoke-summary.json`

重要判断：strict-8192 确实有计算空间，但 legacy median 9280 → 8192 只是约
11.7% descriptor 行数下降，**它不是单独把整帧砍半的大刀**。它仍可能通过
降低热负载产生乘数效应，但必须由物理 iPhone 同输入实测。

### G. CPU preclamp host fixture 被正确判为不能替代生产 GPU

3 帧生产 CPU 路径虽然每帧产生至少 100,000 候选，但 stored GPU 表只获得
约 85.8–87.3% @1px、90.1–91.4% @2px 召回。JPEG、灰度路径和检测器差异
不可分离，因此 `HOST_FIXTURE_NOT_PRODUCTION_GRADE`。不要拿 CPU fixture
替 strict/coverage 做生产质量结论。

### H. tail-cache/dirty-epoch 已完成 host exact、故障恢复和 201 帧真机安全门

Host：

- shadow 正确证书 144/144 `EXACT`；
- exact 范围是 LocalBundle 选图序列，不是 PLY 字节固定；
- remove-frame、pair-overwrite、late-pair、model-replacement 等真实生产失效
  路径已覆盖；device reset 在拆除路径自然观察；
- 证据见：
  `/Users/kaidongwang/Documents/progecttwo/_host_experiments/tailcache-host-exact-20260802/REPORT.md`
  和
  `/Users/kaidongwang/Documents/progecttwo/_host_experiments/tailcache-fault-injection-20260802/REPORT_V4.md`。

Phone OFF/ON 诊断如下。

---

## 六、刚完成的物理 iPhone 200/201 帧数据

### 1. OFF 基线：未命名(2)

- Capture：`cap_1785724011025414`
- 保存高分辨率帧 201，SFM fed/registered 200/200；
- 未闪退，快门无长期灰色；
- final-third：total 3.126 s、extract 1.217 s、match+mapping 1.865 s、
  GPU matcher 1.068 s、TVG 162 ms、Local BA 311 ms、tail 328 ms；
- tail first-third p50 52 ms → final-third p50 328 ms，旧路径明显 O(N)；
- 停拍时 72 queued + 2 in-flight；queue drain 255.243 s；
- native final refinement 165.057 s；
- delivered 211,790 points，reproj 1.1285 px，mean track 2.705；
- 证据：
  `/Users/kaidongwang/Documents/progecttwo/_artifacts/tailcache_phone_ab_20260803/off_unnamed2_200/OFF_BASELINE.md`

### 2. ON：未命名(3)

- Capture：`cap_1785735066569094`
- 保存/fed/registered：201/201/201；
- tail-cache 在 199/201 个 frame split 中 `tail_cache=1`、generation=1；前两帧
  尚未进入可读缓存；
- 396 条 LocalBundle 记录全部 `cache=on`、`cache_reused=1`、generation=1；
- frame-split exception 计数 0；仅在结果持久化后 session dispose 出现预期
  `device_reset` dirty；
- 无闪退、无长期灰快门；SceneKit p50 28.85 / p90 29.4 FPS；
- 内存 p50 977 MB、max 1790 MB；thermal serious 27 个 resource 样本、critical 0；
- delivered 184,375 points，reproj 1.1698 px，mean track 3.018；
- native final refinement 144.844 s；colorize 18.858 s；
- 停拍时 92 queued + 2 in-flight；queue drain 315.041 s；
- capture stop → persisted PLY 约 479.5 s；
- 完整报告：
  `/Users/kaidongwang/Documents/progecttwo/_artifacts/tailcache_phone_ab_20260803/on_unnamed3_201/ON_RESULT.md`

### 3. OFF vs ON 阶段结果

| 指标 | OFF | ON | 观测变化 |
|---|---:|---:|---:|
| tail all-frame p50 | 247 ms | 107 ms | -56.7% |
| tail first-third p50 | 52 ms | 26 ms | -50.0% |
| tail final-third p50 | 328 ms | 134 ms | -59.1% |
| tail final-third p90 | 404 ms | 177 ms | -56.1% |
| tail 线性斜率 | +2.182 ms/frame | +1.009 ms/frame | -53.8% |
| total all-frame p50 | 2.914 s | 2.923 s | +0.3% |
| total final-third p50 | 3.126 s | 2.996 s | -4.2% |
| total final-third p90 | 4.490 s | 3.941 s | -12.2% |
| extract final-third p50 | 1.217 s | 1.163 s | -4.4% |
| match/mapping final-third p50 | 1.865 s | 1.765 s | -5.4% |
| GPU matcher final-third p50 | 1.068 s | 1.070 s | +0.2% |
| TVG final-third p50 | 162 ms | 155 ms | -4.3% |
| Local BA final-third p50 | 311 ms | 354 ms | +13.8% |
| 每个待处理帧的 drain | 3.449 s | 3.352 s | -2.8% |

### 4. 正确判决

- tail-cache **机械生效且 201 帧安全门通过**；
- 它将自己的目标阶段砍约 56–59%，应继续保留为领先候选；
- 它没有解决全管线，因为 tail 不是最大阶段：whole-frame final-third p50
  只改善约 4%；
- OFF/ON 是不同现场拍摄，而且 ON 期间产品/包身份比 OFF 更新，因此不是严格
  单变量质量/总速度 A/B；不能从点数差异判质量优劣，也不能把 final BA 的
  -12.2% 全算给 tail-cache；
- 可以停止为了 tail-cache 再拍 300 帧。当前更有价值的是转向匹配和提取；
- 正式生产默认 ON 前，最好用同一冻结 capture 的物理 iPhone replay 做一次
  gate-clean OFF/ON。完成后把它改成持久默认 ON + 紧急关闭开关，不再依赖 env。

---

## 七、已否决、关闭或暂存的路线：不要重复浪费时间

| 路线 | 判决 | 原因 |
|---|---|---|
| Apple 用 WGSL 替 native Metal | CLOSED | portable exact 13.4 ms vs native ~5 ms |
| f16 缩放/累加 | REJECT | match 集合偏差 6.40%，非 exact |
| BatchK12 host 主路线 | REJECT_BELOW_GATE | paired +3.2% < 10% |
| Direct-B 两布局 | REJECT | 27–35 ms，跨 subgroup 共享流量爆炸 |
| WGR 80/96/112 甜点 | REJECT | 无稳定收益 |
| 16-way 列归并 | REJECT | 列阶段几乎不在关键路径 |
| staged 预转置 S1 | PARK | 约 +3.6%，低于 5%/0.75 ms 门 |
| CPU preclamp fixture 冒充 GPU | BLOCK | GPU stored 表不是 CPU 流超集 |
| 旧 RANSAC omp critical 补丁 | INVALID_PREMISE | 构建无 `-fopenmp`，omp critical 未编译存在 |
| descriptor residency host | NO CREDIT / default OFF | host 实测约打平；设备收益未证 |
| canonical/strict-8192 直接上生产 | OFF EXPERIMENT | 会改变特征集合，质量尚未终审 |
| overlap 直接并行 guided match | DEFER | thread_local PRNG/线程归属尚未定义，exact 风险 |
| 继续调查旧 2.8× 回退根因 | STOP | 已绕开负收益路线，用户明确不再投入主线时间 |

如果提出新版本，必须说明它与上述失败路线的结构差异；换名字重跑不算新方案。

---

## 八、下一步计划：按“大幅收益”排序

### Phase N0：用不超过一个短窗口冻结执行身份，不再搞一天仪器

1. 只读核对产品仓和算法仓当前 HEAD/status；
2. 冻结当前本地产品完整树的源清单和关键 AOT/native 输入身份；
3. 明确本轮是 `PIPELINE_ONLY`；产品所有 staged/unstaged/untracked 功能必须保留；
4. 声明本轮唯一写域；不要碰选区、压缩、快门、相册、编辑器和其他 Agent 文件；
5. 使用隔离副本/build dir，但输入必须来自当前本地完整母版，不是旧 carrier；
6. 不等待共享树“干净”，不清缓存，不重置别人的文件。

完成这些后立即进入算法，不得继续扩张流程文档。

### Phase N1：第一大刀——匹配/建图热态路径

最新 final-third `match+mapping = 1.765 s/帧`，是当前最大阶段；其中 GPU matcher
约 1.070 s，Local BA 约 0.354 s，TVG 约 0.155 s，tail 已降至 0.134 s。

必须先用现有日志和最小代码检查回答：

- 12 对里每对 descriptor 行数、encode、submit、wait、Metal GPU、mutual、TVG
  的实际分布；
- GPU matcher p50 约 1.07 s，但 Mac native kernel 同类台架每对约 5 ms，
  剩余差距到底来自 A16 热降频、每对规模、提交等待、资源转换还是 GPU/相机争用；
- 逐帧将 thermal、extract、per-pair matcher、Local BA、backlog 对齐。已有字段能
  回答的不要新加探针；只有缺字段才加 O(1) 日志。

候选顺序：

1. **ThermalLoadGovernorV1 / GPU 调度重排**：仅限语义等价 kernel、控制
   in-flight、去投机、backpressure、chunk/duty；严禁跳帧、减特征、改质量。
   目标是防止 matcher 在 serious thermal 下被放大，而不是单纯延迟工作；
2. **现有 Metal v2 host 编排的重复转换/资源生命周期**：只有设备数据证明
   Q/D prepare、上传或 wait 有至少 10% 可回收空间才动；descriptor residency
   host 已打平，不可直接启用；
3. **native Metal exact kernel 的结构改造**：保持 u8→FP16 multiply→FP32
   accumulation 和完整匹配语义；WGSL 只做 parity，不取代 Metal；
4. **共享 C++ scheduler/backend contract**：把获胜的资源管理和批次语义放到
   C++，Metal/Vulkan/SIMD 分别实现，不把平台算法写回 Dart。

晋级门建议：

- match+mapping final-third p50 至少下降 20%（当前约 353 ms/帧的最低绝对收益）；
- whole-frame final-third p50 至少下降 10%；
- final-third p90 不恶化；
- 同一冻结输入、相同特征/匹配/TVG/LocalBundle/PLY 质量门；
- 热态最后 1/3 不得重新爬升到第一 1/3 的不可控倍数。

任何候选低于门槛就停止，不因实现成本高而保留。

### Phase N2：第二大刀——特征提取 exact 热核

当前 final-third extract 约 1.163 s/帧。旧 host 拆分提示 descriptor ~40%、
descriptor readback ~15%、affine ~12%、orientation ~11%，但必须以 A16 设备
数据重新确认，不得直接套 Mac 比例。

优先检查：

1. orientation 41×41 patch 和“总是执行”的各向异性平滑是否存在 exact
   可消除的重复工作；
2. descriptor kernel 的读写、融合、局部共享与 readback 是否能减少数据移动；
3. affine/orientation/descriptor 是否存在一次网格多次 dispatch、重复中间量、
   重复格式转换；
4. 保留黑帧/零纹理/错误 fail-closed 路径，严禁为速度删安全检查。

不能使用：f16 累加、缩放舍入、WGSL f64 幻想、已被否决的 pre-affine
SED_PRUNE，或任何仅在合成 Mac 图上成立的收益。

晋级门建议：extract final-third p50 至少下降 15–20%（约 175–230 ms/帧），
且输出 byte-exact；如果无法 byte-exact，必须转质量候选车道，不能混入 exact。

### Phase N3：feature-budget 质量车道——strict 是标尺，coverage 更可能是赢家

只在 exact 大刀不足时进入。顺序固定：

```text
legacy control
→ strict-8192（速度上界/质量下界标尺）
→ coverage-8192（同预算，确定性覆盖重选，最可能候选）
→ fixed-12288（两个 8192 臂质量失败才测）
→ adaptive（所有定额臂失败才付复杂度）
```

关键约束：

- Coverage-8192 只从 legacy 已保留、已计算 descriptor 的候选域重选，不能偷偷
  从 preclamp 丢弃点里捞回新点；后者是另一实验；
- ORB-SLAM3 GPL-3.0 代码一行不能复制；可以自写思想或审计合适许可证的 ANMS；
- Adaptive 不得塞进现有 repay，因为 `FinalizeRematchStarvedFrames` 遇到已有
  matches 会跳过，且已有 write-once 持久化约束；
- 每帧不同预算可能造成密度接缝，必须加入质量门；
- 白墙没有候选时，coverage 不能凭空创造特征；不要承诺弱纹理奇迹；
- host 只提名，物理 iPhone 同输入全生产管线终审；肉眼盲评“更差”一票否决。

现有质量车道草案：

`/Users/kaidongwang/Developer/Aether3D-cross/openspec/changes/portable-sfm-speedup-v1/quality-lane-budget-v1-draft.md`

### Phase N4：Local BA 与 final BA

不要忽略用户拍完后的长等待：201 帧 ON 的 native final refinement 仍约
144.844 s，stage1/stage2 各约 76.8/67.6 s。Local BA final-third p50 约
354 ms/帧。

- K12 是匹配候选，Local BA 是六图，禁止混淆；
- 当前 host 记录曾显示 4 线程相对 all-single 在六图窗口 exact 下降约 26%，
  且 12 线程反而更慢；iPhone 上仍需同输入验证；
- 优先做 solver/线程/持久工作区/构造复用等 exact 候选；
- 不得减少 BA 轮数、放宽收敛、降低残差精度后声称 exact；
- final BA 是用户等待的大块，应与逐帧优化并列计账，但不能把重叠计时相加。

### Phase N5：Vulkan 车道（等有设备再终审）

- Vulkan 必须分别探测功能位与 `integerDotProduct4x8BitPackedUnsignedAccelerated`
  加速属性；功能可用不等于硬件加速；
- V0：功能+加速都真 → `OpUDot`；
- V1：功能真、加速假 → 实测 UDot 与 scalar tiled 后选择；
- V2：功能不可用 → scalar/pack4 fallback；
- 可借鉴 ncnn/llama.cpp 的 pack4、tiling、能力分派、尾 lane 保护思想，但不复制
  不同量化/GEMM 语义；
- 当前 Mac WGSL fusedr128 + 19-case 三重 golden 套件是 Vulkan 候选的语义门；
- 没有 Android/鸿蒙真实设备前，不得宣称 Vulkan 更快或三端完成。

---

## 九、实验和证据纪律：严格但必须轻量

不要再花一天只搭探针。每个候选只需一张短合同：

1. 唯一变量；
2. 当前产品树、pipeline 源、产物、输入 capture 的哈希；
3. 指标和门槛先写；
4. stop 条件；
5. host 诊断与 iPhone 终审边界；
6. 原始日志和判决文件的耐久路径。

速度测试优先使用同一个冻结 capture 的隔离副本，禁止重新拍两个不同场景后把
差异都算给算法。测试顺序：

```text
A/A 定噪声
→ 紧邻交替 paired A/B（平衡对内顺序）
→ final-third + p90 + 热态
→ exact/质量门
→ 才允许晋级
```

匹配 exact 门至少包括：19-case golden、奇数行、空输入、single candidate、
相同 dot tie、best==second、absolute/ratio 边界、OutAB、OutBA、mutual pairs。

质量门至少包括：注册帧集合、最大连通分量、重投影、覆盖 32×32 p50/p10/
final-third、点数、track≥3、mean track、失败率，以及隐藏臂名的 PLY 肉眼盲评。

基线自身可能存在多个 PLY attractor。不要要求不可能的整文件 hash；先固定线程/
seed，仍不确定时使用已有 attractor 纪律、ordered TVG/LocalBundle 语义和质量分布。

---

## 十、当前手机与测试状态

当前已安装 bundle：`com.kyle.PocketWorld`。最近观察到的安装目录为：

`/private/var/containers/Bundle/Application/6A71B8F8-B0A7-4777-BDEF-C4DD6C87BB2B/Runner.app`

当时签名后身份：

- Runner：`f4bf8214fb166c6d50b4e7b9621171e8b0dfcdf7c75679a3de0ba92074eda1aa`
- Dart AOT：`3b43a7dfbb36bde377ef9fba4b369ea328681ebfbc3cb8a95bb6298831025b82`
- signed pipeline framework：`15a43e7d4720fa493798b7403441f0034d82529a9acb1331cbcfd5b57b08b200`

这些是“当时手机已安装身份”，不是当前本地完整工作树的母版，也不是 unsigned
源身份。当前手机包包含 tail-cache 能力，也编译有 descriptor-residency 能力，
但后者 default OFF。不要从 strings 看到能力就断言实验已启用。

最近一次 tail-cache fresh-process ON 启动证据：

`/Users/kaidongwang/Documents/progecttwo/_artifacts/current_latest_app_tail_on_20260803/launch_ready_20260803_1330.json`

SHA-256：`0783db067edd18b74d741e989879ea3ecc5605f2767e36e9359a7ef44e5fec85`

但 env 不持久。接手时进程可能已经退出，绝不能根据这份旧 launch JSON 声称
现在仍 ON；每次实验要 fresh launch 并保存新的 JSON。

---

## 十一、你接手后的第一轮具体动作

请直接按以下顺序工作，不要先问用户重复已经回答的问题：

1. 读本提示词和列出的权威报告；
2. 只读冻结执行当下 PocketWorld/Aether3D-cross 的 HEAD、dirty manifest、
   本次唯一写域；
3. 从 201 帧 ON capture `cap_1785735066569094` 和 200 帧 OFF evidence 重新生成
   一张 roll-up：当前 2996 ms/帧如何分给 extract/matcher/TVG/LBA/tail；
4. 只读审查生产 matcher 每对路径和已有 telemetry，找出“1.07 s GPU matcher”
   与 host native ~5 ms/pair 之间的可验证组成；
5. 提出最多三个**结构不同**、预期至少 20% match-stage 收益的候选，明确哪个是
   shared C++、哪个是 Metal backend、哪个将来可移植 Vulkan；
6. 选择证据最强的一刀，在隔离目录实现 host exact 原型/诊断；
7. host 不改变语义且收益过门后，再准备当前本地产品母版的 `PIPELINE_ONLY`
   iPhone 候选；不允许带入任何产品侧回滚；
8. 物理 iPhone 使用同一冻结 capture 的隔离副本做 A/A + paired A/B；
9. 结果立刻落耐久 artifact，并给出 ACCEPT / REWORK / REJECT，而不是只说
   “需要用户再测试看看”。

如果第一刀是纯设备热态假设，host 不能证明也不能否证，那么可以直接设计最小
phone-only 单变量实验，但仍须先保证当前本地产品母版不变、输入相同、数据安全。

---

## 十二、绝对禁止事项

- 不得从旧 carrier、旧 Runner、旧 commit 构建并覆盖当前产品；
- 不得 reset、clean、stash、checkout/revert 用户或其他 Agent 的工作；
- 不得为了“只改一点 native”而整包丢失最新 Dart/Swift/UI 功能；
- 不得自行把单变量任务改成 product+pipeline 双变量并继续安装；
- 不得 uninstall/reinstall/`flutter drive` 生产 bundle；
- 不得把 host/Mac/模拟器结果宣布为生产赢家；
- 不得把不同现场拍摄的 PLY 点数差直接归因给候选算法；
- 不得为速度删黑帧/零纹理/错误安全、原图保存、贴图/颜色链路；
- 不得启用 strict-8192、coverage、descriptor residency、overlap、RANSAC 等
  未授权组合，造成无法归因；
- 不得把数毫秒小优化包装成解决 1354 ms 缺口的“大刀”；
- 不得重复已经判死的 WGSL-on-Apple、f16 approximate、BatchK12 host 等路线；
- 不得只做测试不分析代码，也不得只读代码不跑最小验证；代码归因和实验必须
  互相闭环。

---

## 十三、给用户的沟通方式

用户要大白话、结果优先，不要流程术语堆砌。每个阶段汇报四件事：

1. 现在在改哪一块：跨端接口、提取、匹配、BA，还是只做测量；
2. 改了什么文件/算法，是否改变质量语义；
3. 当前数字：原来多少、现在多少、差多少，是否过门；
4. 下一步具体做什么，何时能进入物理 iPhone 同输入测试。

不要让用户等几个小时只收到“还在审计”。超过一个短窗口没有可见进展时，必须
说明阻塞点并立即转向可执行工作。不要要求用户替你分析代码、安装 App 或重复
已经完成的拍摄。

最终成功标准不是“跨端代码存在”，而是：

- 当前本地产品功能一个不丢；
- iPhone 生产管线 final-third p50 明显接近或低于 1642 ms；
- final-third/p90/热态稳定；
- PLY 肉眼和指标质量不差；
- 获胜算法位于共享 C++ 核心或明确的 Metal backend contract 中，可由 Vulkan
  和 SIMD 后端复刻；
- 安装与切换不再依赖旧 carrier，也不再让用户每次手工提醒“只改管线”。

