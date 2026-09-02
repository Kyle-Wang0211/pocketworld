# SR-3C/SR-3D 布局刀族战报(终稿)

日期:2026-09-02。主机:Mac M3 Pro,Dawn 主机库(libwebgpu_dawn.a 081bab5f…,今晚重编)。
夹具:8192×8192 真实夹具(a=d4cef62e… b=2760e2f1…,与 08-01 正式轮逐字一致)。
语义金标准:**pairs SHA 7fdf9f2de0d3…,count 2155 —— 全程每一核、每一轮、每一 rep 一致**(含 native 括号双侧)。

## TL;DR

**前沿定格 = `fusedr128-db`(SR-3D-1 软件流水),paired GPU −2.05ms 中位(7/7 轮铁赢),离 native 从 2.7× 收窄到 ~2.1×,696/696 全量闸逐字节无损已上账。** 机制:xb 探针证得纯 barrier 省除只值 0.5ms,db 赢的主体 ~1.5ms 是访存延迟隐藏。**SR-3C 空间布局刀全军覆没**(tacc 假胜复现被拒/Direct-B 筛选即死/s33 证伪 bank-conflict 假设/tb-resident 0.3ms 小赢被 db 吸收);**SR-3E 时间维度真双缓冲亦判死**(预算逼 BT16、tile 减半惩罚 +1.5ms,而双缓冲本身零收益——db 早已把 staging 藏在长列扫描背后)。空间维度先死、时间维度后死,前沿永久定格 db。

## 0. 执行环境与纪律

- 开工 `df -h /`:24Gi 可用,达标。
- 原件已备份:`fair_match_portable_arm.cc.orig`(本目录)。
- 构建:`/private/tmp/h2-rebuild-20260902/build`,源与二进制 SHA 记录在 `build_identity.txt`。
- ⚠️ 全程后台有间歇性重负载(主线 pycolmap 深度重放 agent 100-579% CPU、随后 OS Spotlight 全库重建多核抖动、HydraRenderingService 常驻 99-100%)。采纳判据分两段:tacc/tb 三刀跑在早段干净窗(native 括号 5.0-5.3,§4.1-4.3);r64/xb/db 跑在后段——Spotlight+Hydra 把括号钉在 6.0-6.9,严格 5.0 括号不可达,改用 **paired ABBA + 轮内守卫**(A 臂 GPU 比值≤1.12 + 镜像双半 + pairs SHA 恒等),对均匀抬高免疫、突发由 A 比值拒。方法论详见 §4.5。

## 1. Parity(fail-closed 三重金标准,19 案例)

第一批(SR-3C 布局变体,9 核):`fusedr64 fusedr128 fusedr128-tb fusedd128 fusedd128-tb fusedr128-tacc fusedr64-s33 fusedr64-tacc fusedd128-s33` → **PARITY_SUITE_PASS 全绿**(`parity_sr3c.log`)。

第二批(SR-3D 调度变体,4 核):`fusedr128-db fusedr128-xb fusedr64-db fusedr128-db-tb` → **PARITY_SUITE_PASS 全绿**(`parity_sr3d_full.log`)。

## 2. SR-3C 结构性事实(不跑就能定的)

**`fusedr128-s33` 结构性超限**:Bsh 16384B + accSh 128×33×4=16896B = 33280B > 32768B,Dawn 直接拒绝建管线(实测 device error 2)。r128 前沿上 stride 填充刀没有预算空间;stride 诊断改在 `fusedr64-s33`(纯单变量)与 `fusedd128-s33`(Direct-B 腾出 Bsh 后可容纳)两处落地。

**解析器静默吞后缀 bug(已修)**:`fusedr128-tb-db` 这种误排序名会被 `atoi("128-tb")` 静默吞成 plain `fusedr128-db`(tb 丢失、无任何报错)——parity 也抓不到(语义相同)。已加严格数字尾校验,误排序名现在响亮 FAIL。正确组合名:`fusedr128-db-tb`。(静默出口教训再 +1。)

**mma/fused RUN-FAIL 根因(战线情报第 7 条,已查明并修复)**:不是 Dawn 实验特性漂移。08-01 把 acc 布局杠杆接进模板时,`kMmaShader`/`kFusedShader`/`kMma16Shader` 里也埋了 `$ACCOFF$`/`$ACCCM$`/`$ACCSTRIDE$` 占位符,但替换只在 fusedr(wgr≠0)分支执行——plain mma/fused 的 `$` 原样喂给 WGSL 解析器,CreateShaderModule 报 "invalid character"。修复:非 fusedr 路径把占位符钉死为基线 stride-32 布局。修复后 mma/fused/mma16 复活,默认清单 parity(naive tiled mma fused fusedr64 fusedr128)19 案例全绿(`parity_default_revived.log`)。

## 3. 筛选轮(3 reps × warmup 1;仅用于挑候选,数字不作判据)

| 核 | complete p50 | GPU p50 | 备注 |
|---|---|---|---|
| fusedr128(基线) | 18.50 | 17.56 | ⚠️ 显著高于正式轮(见 §4 伪影分析) |
| fusedr128-tb(冷) | 23.10 | 15.97 | 逐 rep 主机转置 5.6ms |
| fusedr128-tb(常驻) | 18.36 | 17.26 | |
| fusedd128 | 35.30 | 34.33 | **筛选即拒** |
| fusedd128-tb(冷) | 33.67 | 27.08 | **筛选即拒**(D1 活口关闭) |
| fusedd128-tb(常驻) | 30.16 | 29.61 | **筛选即拒** |
| fusedd128-s33 | 34.07 | 33.16 | **筛选即拒** |
| fusedr128-tacc | 14.54 | 13.55 | 进正式轮 |
| fusedr64(对照) | 14.55 | 13.57 | 进正式轮 |
| fusedr64-s33 | 14.38 | 13.41 | vs fusedr64 −0.16ms ≈ 噪声 |
| fusedr64-tacc | 16.01 | 14.63 | 反向(变慢) |

**Direct-B 判死**(GPU 27-34ms,输基线 2.1-2.7×,四种布局组合全输):M3 上 Right 片段直读 device storage(无论 colMajor gather 还是转置后连续读)都远慢于经 16KiB 共享 tile 的复用路径。「Direct-B × 预转置」活口就此关闭,不进正式轮(筛选差距 >10ms,远超噪声)。

## 4. 正式轮(镜像 ABBA:base→cand→cand→base ×7reps×warmup2,native 括号双侧)

### 4.1 tacc(转置 accSh)— REJECTED,历史"假胜"逐字复现

括号:native-pre 5.130 / native-post 4.980 —— 干净。

| 臂 | complete p50 | GPU p50 |
|---|---|---|
| A1 fusedr128 | 13.605 | 12.733 |
| B1 fusedr128-tacc | 14.027 | 13.127 |
| B2 fusedr128-tacc | 14.562 | 13.710 |
| A2 fusedr128 | 14.050 | 13.215 |

Paired GPU:tacc (13.13+13.71)/2=13.42 vs 基线 (12.73+13.22)/2=12.97 → **tacc 慢 0.44ms**。
镜像两半方向一致(B1>A1,B2>B2 对应 A2 也 B>A)。
**伪影解剖**:筛选轮里 tacc 13.55 vs 基线 17.56 的"4ms 大胜"是基线被机器状态压高(warmup1×3reps 不足以进入热态);正式轮基线回到 12.7-13.2(与今晚战报 12.8 对上),胜势蒸发并反转。⚠️ 08-01 的"tacc 筛选假胜"在完全独立的一晚被逐字复现——**tacc 这种变体对"冷基线"伪影有系统性亲和,永久拉黑筛选口径,只认 ABBA。**

### 4.2 tb 冷模式(逐调用转置 B)— 双口径全输

括号:native-pre 5.239 / native-post 5.060 —— 干净。

| 臂 | complete p50 | GPU p50 |
|---|---|---|
| A1 fusedr128 | 13.675 | 12.805 |
| B1 fusedr128-tb | 22.460 | 15.700 |
| B2 fusedr128-tb | 23.604 | 17.032 |
| A2 fusedr128 | 13.911 | 12.995 |

complete 被逐 rep 主机转置(~5.6ms)拖垮;GPU 口径也慢 3-4ms(冷模式下逐 rep 4MB 转置上传与 GPU 窗口纠缠,未深挖——冷模式已死,不值得归因)。

### 4.3 tb 常驻模式(B 入库时转置一次)— 小赢,SR-3C 唯一幸存刀

括号:native-pre 4.997 / native-post 4.984 —— 干净。

| 臂 | complete p50 | GPU p50 |
|---|---|---|
| A1 fusedr128 | 14.001 | 12.997 |
| B1 fusedr128-tb (resident) | 13.310 | 12.715 |
| B2 fusedr128-tb (resident) | 13.125 | 12.618 |
| A2 fusedr128 | 13.848 | 12.941 |

Paired GPU:12.67 vs 12.97 → **tb-resident 赢 0.30ms(−2.3%)**,镜像两半方向一致(A1−B1=+0.28,A2−B2=+0.32),可信但幅度小。complete 口径赢 0.7ms,但其中含"常驻省掉 B 转换+上传"的摊销红利,与布局收益混在一起,不拆。
生产语义:B 侧(train 图)descriptor 入库时转置一次、常驻复用 —— 摊销合法。冷模式(逐调用转置)则绝对不可用。

### 4.4 r64 对照轮 — r128≥r64 确认(base 选对)

首轮(15:54)与 v2/v3 共 7 次尝试被后台污染(深度重放 agent + 后续 OS Spotlight 全库重建)全部拦下作废,零数据入账。安静窗后用 paired 多轮(`paired_r64_clean`)+ 早先 v5(A 比值 1.06)综合:

| 来源 | paired GPU delta(r64 − r128) | 判据 |
|---|---|---|
| v5(16:19) | +0.51 | A比值1.06,双半一致 |
| r64_clean r1 | +1.68 | A比值1.02,双半一致 |
| r64_clean r2 | −0.43 | **SPLIT,拒** |

干净镜像半一律非负 → **r64 慢于或等于 r128**,幅度噪声大(0.5-1.7ms)但方向确定。**base 选 fusedr128 正确**,r64 维持退役对照。

### 4.5 采纳判据的方法论说明(必读)

安静窗后 HydraRenderingService 常驻 99-100% CPU(渲染服务,非本战役),把 native 括号从今晚早段的 5.0-5.3 钉在 6.0-6.9;OS Spotlight 全库重建期更冲到多核抖动。**严格 6.0 括号在此机器态下不可达**。改用 paired ABBA + **轮内**守卫承载(合法性:paired delta = ((B1−A1)+(B2−A2))/2 对均匀抬高与线性漂移构造性免疫,只有突发抖动能破坏,而突发被 A 臂比值守卫抓住):
- **主守卫**:A 臂 GPU 比值 ≤1.12(收紧;两 base 臂互比,抓轮内突发);
- **辅**:镜像双半符号一致(SPLIT 轮标注/拒用);pairs SHA 全轮=7fdf9f2d(全 True);
- **报**:每轮 native 括号如实记录(诊断,不美化),不以绝对括号数下判决。

## 5. SR-3D(预注册顺延):调度刀 —— **db 是新前沿**

设计(代码已落地、parity 全绿):
- **`-xb` 探针**:staging 拆两半、中间插一个语义惰性 barrier(4 barrier/tile,+256 个)。paired 差 ÷256 = 单 barrier 成本。
- **`-db` 刀(SR-3D-1)**:软件流水。序幕 stage tile0,此后每 tile `{mma; barrier; (本 tile 扫描 ∥ 空闲 lane stage 下一 tile); barrier}` = 2 barrier/tile(原 3)。合法性:mma 在前 barrier 前消费完 Bsh,同区间内扫描读 accSh、staging 写 Bsh 无交集;下一 tile 的 accSh store 在闭合 barrier 之后(WAR 成立)。扫描顺序逐字不变。共享内存预算不变(真双缓冲 2×Bsh=48KiB 超限,此为无预算版流水)。

### 5.1 xb barrier 成本探针(`paired_xb`,4 轮)

| 轮 | A比值 | 镜像 | paired GPU |
|---|---|---|---|
| r1 | 1.013 | SPLIT | +0.489 |
| r2 | 1.013 | agree | **+0.549** |
| r3 | 1.037 | SPLIT | +0.356 |
| r4(括号6.7热) | 1.030 | agree | +1.288 |

最干净 r2(括号 5.93/5.99、双半 +0.40/+0.70)= **+0.549ms**;r1-r3 中位 ~0.5ms。**256 barrier ≈ 0.5ms,单 barrier ~2µs**。

### 5.2 db 刀(`paired_db` 4 轮 + `paired_db_clean` 3 轮 = 7 轮)

**7 轮无一例外镜像一致、双半皆负(db 更快)、A 比值 1.001-1.054 全过**:

| 批/轮 | paired GPU delta(db − fusedr128) |
|---|---|
| db r1-r4 | −2.358 / −1.677 / −2.046 / −0.978 |
| db_clean r1-r3 | −2.931 / −2.363 / −1.950 |
| **合并 n=7** | **中位 −2.046,均值 −2.043,区间 [−2.93, −0.98]** |

绝对(db_clean r3,A比值1.017,最紧):native 6.62 / base 14.56-14.80 / db 12.65-12.82。

**归因**:xb 证得纯 barrier 成本仅 ~0.5ms,而 db 赢 ~2.0ms → **多出的 ~1.5ms 来自软件流水的访存延迟隐藏**(下一 tile 的 device→shared staging 与本 tile 的 accSh 扫描在同一 barrier 区间重叠),不止是省 barrier。这是 db 超出预注册预期的机制根因,已被 xb 探针拆开证实。

### 5.3 db-tb 组合(`paired_dbtb` vs db 3 轮;`paired_dbtb_vs_base` vs fusedr128 2 轮)

- tb-on-db(vs db):r1 −0.76 / r2 −0.57 / r3 −0.13(SPLIT,括号8.28热);增量 0.13-0.76ms;
- db-tb(vs fusedr128):r1 −2.096 / r2 −2.077 —— **比 db 单刀(−2.05 中位)并无可辨改善**。

**判决:tb 在 db 之上的增量落在噪声地板(~0.5ms)内,不可靠叠加**。前沿保持 **db 单刀**,不引入 resident-transposed-B 的入库转置复杂度(§4.3 tb-resident 单刀那 0.3ms 小赢被 db 完全吸收且不叠加)。

## 6. 前沿判决

**最快核 = `fusedr128-db`(SR-3D-1 软件流水)**。对 fusedr128 前沿 paired GPU **−2.05ms 中位(7/7 轮铁赢)**。

离 native 的最终差距:
- 干净基线投影:fusedr128 GPU 12.9ms → db ≈ **10.85ms**;native 5.0ms → **db ≈ 2.17× native**(战役开局 fusedr128 是 2.58×,brief 记 ~2.7×)。
- 同窗横比(Hydra 载,三方同受):native ~6.4 / db ~12.7 → **~2.0×**。两口径一致。
- **本战役净收窄:2.7× → ~2.1×(约 16-19%,单刀 −2.0ms)。**

刀族总账:

| 刀 | paired GPU | 判决 |
|---|---|---|
| **fusedr128-db** | **−2.05ms** | ✅ **前沿(定格,696/696 无损)** |
| dbuf(SR-3E 真双缓冲) | +1.1ms(vs db) | ❌ BT16 惩罚+双缓冲零收益(§7) |
| db16(BT16 单缓冲) | +1.77ms(vs db) | ❌ tile 减半代价 |
| db-tb(组合) | vs db 增量 <噪声 | ➖ tb 不叠加,不采 |
| tb-resident(单) | −0.30ms | ➖ 被 db 吸收 |
| tb 冷模式 | +3~9ms | ❌ 冷转置不可用 |
| tacc | +0.44ms(反向) | ❌ 假胜复现,拉黑 |
| Direct-B(4组合) | +14~21ms | ❌ 筛选即死 |
| s33 | ≈噪声;r128 结构超限 | ❌ bank-conflict 假设证伪 |
| fusedr64 | +0.5~1.7ms | ➖ 退役对照,r128 胜 |
| **xb 探针** | +0.5ms/256barrier | 🔬 单 barrier ~2µs |

**bank-conflict 假设证伪**:08-01 怀疑 `accSh[lid*32+c]` 步长 32 的 bank conflict 是行扫描长杆,故设计 tacc(转置 acc 消 conflict)/s33(填充错开 bank)。实测:tacc 反而慢 0.44ms、s33 ≈ 噪声——**accSh 布局不是瓶颈,行扫描的长杆是访存延迟**,由 db 的流水重叠(而非改 acc 布局)拿下。假设方向错,db 从另一维度(时间重叠而非空间布局)命中真因。

**db 机制拆解(xb 探针背书)**:db 的 2.0ms 里,纯 barrier 省除只值 ~0.5ms(xb 实测),**主体 ~1.5ms 是延迟隐藏**——staging 下一 tile 与扫描本 tile 在同一 barrier 区间并行,把原本串行的 device→shared 访存藏进 ALU 扫描的影子里。

## 7. SR-3E:真双缓冲(staging∥mma)—— **判死,前沿定格 fusedr128-db**

预注册活口:让 staging 与 **mma 本身**重叠(db 只重叠了 staging 与扫描)。

### 7.1 预算(先算后写)

真双缓冲需两块 Bsh。M3 上限 32768 B。**BT 减半到 16** 是唯一可行配置(BT 减半时 accSh 列数也 32→16 同步减半):

| 配置 | Bsh | accSh | 合计 | |
|---|---|---|---|---|
| db(现役 BT32) | 1×16K | 16K | 32768 | 顶满 |
| dbuf naive BT32 | 2×16K | 16K | 49152 | ❌ 超 16K |
| **dbuf BT16** | 2×8K | 8K | **24576** | ✅ 富余 8K |
| db16(BT16 单缓冲对照) | 1×8K | 8K | 16384 | ✅ |

Direct-B 借内存账:**非启动项**——Direct-B 恰因无 staging 才慢,而双缓冲全部意义是重叠 staging;无 staging 可借。

实现两个自包含核(不碰冻结的 db BT32 前沿装配,696/696 无损):`fusedr128-dbuf`(BT16 双缓冲,mma∥stage)+ `fusedr128-db16`(BT16 单缓冲对照,隔离 tile 尺寸代价)。parity 19×2 三金标准全绿,四个误用守卫全响。

### 7.2 paired 结果(合并,轮内守卫)

| 对比 | paired GPU | 判决 |
|---|---|---|
| **dbuf vs db(前沿)** | 干净轮 **+1.25/+1.09**,均 +1.17 | ❌ **dbuf 慢 ~1.1ms** |
| db16 vs db(BT16 惩罚) | +2.57/+1.77/+1.00,中位 +1.77 | BT16 tile 减半代价 |
| dbuf vs db16(纯双缓冲) | −0.77/+0.94/−0.87/+0.50,中位 **−0.14** | ➖ **双缓冲零收益** |

### 7.3 机制拆解(三段闭环)

1. **BT16 惩罚 ~+1.5ms**:预算逼 tile 减半 → tile 数 256→512、barrier 翻倍(512→1024,xb 口径 ~+1.0ms)+ mma 分块 8×32→8×16 变小效率降。
2. **双缓冲本身 ~0ms**:dbuf vs db16 中位 −0.14(噪声内)。**mma∥stage 的重叠不值钱——因为 db 早已把 staging 藏在 128 迭代的长列扫描背后,staging 根本不是瓶颈,换个地方藏等于没藏。**
3. **净:dbuf = db + 1.5(BT16) + 0(双缓冲) ≈ 慢 1.1-1.5ms**。

**连"更激进的 1-barrier 全双缓冲(Bsh+accSh 双缓冲,BT16 恰 32KiB)"也不必建**:它至多把 barrier 数从 1024 抠回 512(= db BT32),但 8×16 的 mma 低效(~1.0ms,即 BT16 惩罚里非 barrier 的那半)照付 → 仍慢 ~1ms。**它优化的重叠(§7.3-2)本就免费,省不出 mma 效率。**

### 7.4 定格

**空间维度(tacc/s33)先死,时间维度(dbuf)后死。SR-3E 是预注册最后一口,前沿永久定格 `fusedr128-db`(BT32 无预算版流水),paired −2.05ms、2.1× native、696/696 无损已上账。** a-priori 预测(建核前写下"db 已隐藏 staging + BT16 惩罚 ⇒ dbuf 难赢")被实测逐条证实。

## 8. 不确定项(宁空勿编)

- **db 精确幅度**:−2.0ms 是 7 轮中位,但单轮方差 ±0.5ms(Hydra+Spotlight 期机器态)。真正 5.0ms 括号的 pristine 窗今晚未再现(Hydra 常驻),幅度可能在更静机器上略变;方向与量级(~2ms、2.1× native)稳。
- **tb-on-db 增量**:0.13-0.76ms,骑在噪声地板上,未能证实/证伪叠加——判"不采"是保守选择,非"证明无效"。
- tb 冷模式 GPU 口径为何比基线还慢 3-4ms:未归因(冷模式已判死)。
- 单 barrier 2µs 是 r2 单轮外推,未做多轮收敛(探针目的已达:确立 db 上限量级)。

## 9. 交付物清单(本目录 `~/Developer/pw_h2_sr3c_20260902/`)

- `fair_match_portable_arm.SR3E_READY.cc` — 最终战备源快照(SHA ae3a0c37…,含 SR-3E db16/dbuf 自包含核;db 前沿装配字节未动);工作区 `~/Developer/Aether3D-cross/.../fair_match_portable_arm.cc` 同 SHA,已留原位。(前一快照 `.SR3CD_READY.cc` SHA 1dbcb75e… 保留为 SR-3D 里程碑。)
- `sr3cde_code.diff` — 最终完整 diff(vs 原件,609 行);SR-3D 关键 WGSL 见 §附。
- `parity_sr3c.log` / `parity_sr3d_full.log` / `parity_sr3e.log` / `parity_default_revived.log` — 全批 fail-closed parity 全绿证据。
- `paired_*/` + `paired_*_summary.txt` — 全 paired 轮原始日志与逐轮守卫判据(含 SR-3E:`paired_dbuf_vs_db`、`paired_db16_vs_db{,_b}`、`paired_dbuf_vs_db16`)。
- `run_paired.sh` / `run_formal.sh` — 度量脚本;`/tmp/budget.py` 预算演算。

## 附:db 关键 WGSL diff(节选自 `sr3cde_code.diff`)

序幕 + 每 tile 2-barrier 流水骨架(模板 `kFusedRDbTemplate`):
```wgsl
  // 序幕:全 lane stage tile0
$STAGE0$
  workgroupBarrier();
  var tile0 = 0u;
  loop {
    if (tile0 >= U.numB) { break; }
    for (var nt = 0u; nt < 4u; nt = nt + 1u) {   // mma 消费本 tile
      var acc = Res(0.0);
      for (var k = 0u; k < 16u; k = k + 1u) {
        let bF = $RIGHT_LOAD$;
        acc = subgroupMatrixMultiplyAccumulate(aFrag[k], bF, acc);
      }
      subgroupMatrixStore(&accSh, $ACCOFF$, acc, $ACCCM$, $ACCSTRIDE$u);
    }
    workgroupBarrier();                          // mma 完成,Bsh 可覆盖
    let nextT = tile0 + BT;
$STAGENEXT$   // lid>=WGR+BT 的空闲 lane 在此 stage 下一 tile 进 Bsh
$ROWSCAN$$COLSCAN$  // 同区间:lid<WGR 行扫描 + WGR<=lid<WGR+BT 列扫描 读 accSh
    workgroupBarrier();                          // 下一 tile 的 accSh store 前 WAR 屏障
    tile0 = nextT;
  }
```
关键:`$STAGENEXT$`(写 Bsh)与 `$ROWSCAN$/$COLSCAN$`(读 accSh)在**同一对 barrier 之间**并行,数组不相交无 hazard;这是延迟隐藏的落点。
