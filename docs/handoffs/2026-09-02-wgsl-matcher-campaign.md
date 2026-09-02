# 跨端 WGSL 匹配器战役(2026-09-02 夜,进行中)

用户令:匹配器跨端(苹果/安卓/鸿蒙公共一套)+ 极致无损提速;通宵自主执行。

## 发现:战役早有前身(H2,2026-08-01),接管而非重来

`aether_cpp/experiments/portable_frontend_pareto/` 藏着完整的 H2 台架:
Dawn/WGSL 便携匹配臂(完整产线语义:双向、in-kernel acos Lowe ratio、互检、
确定性平局)、六个核、fail-closed 三重金标准 parity 套件(19 案例)、
8192×8192 真实夹具(cap7_day db)。当年判决:便携最好 13.87ms vs 原生
4.97ms(2.79×),预注册 SR-3B/C/D 刀族后战役中断于 SR-3C 门口。

关键判决书(已核,原件正被 ~/Documents 的 iCloud 现场蒸发,要点抢救如下):
- fusedr128 = 前沿(≈13.4ms);fusedr64 退役;16-way 列归并 REJECTED;
- 行扫描是长杆(疑 accSh 步长 32 bank conflict);
- 批准路线:SR-3C 2×2(staged/direct × B 原样/预转置)+ accSh 布局杠杆;
  「Direct-B×预转置」= 未测活口;tacc 变体曾筛选假胜(教训:必须正式轮);
- BatchK12 +3.2% < 10% 门,REJECTED;
- MMA 只有 f32 8×8×8 精确(f16 溢出 u8 点积和,构造性不可用);
- Vulkan 车道预注册 V0/V1/V2:dot4U8Packed 在 Metal 是 polyfill,
  在 Vulkan 1.3 lowering 到原生整数点积(Android 15 profile 要求)——
  同一份 WGSL 在安卓/鸿蒙上相对更快,这正是跨端答案的底气。

## 今晚已完成

1. 主机 Dawn 重建(build/third_party/dawn,20MB .a)。
2. 台架重编 + parity 套件:金标准全部仍成立;前沿核 fusedr128 全绿;
   两个历史臂(mma/fused)在新 Dawn 下 RUN-FAIL(实验特性漂移,不挡路)。
3. 速度基线重立(ABBA,与 08-01 连续):native p50 5.0-5.2ms,
   fusedr128 p50 13.7(GPU 12.8),pairs SHA 三方全等 = 冻结金标准 7fdf9f2d…。
4. SR-3C 执行官(子 agent)按预注册协议开工:单变量刀族 + parity 门 +
   镜像 ABBA 正式轮,产物落 ~/Developer/pw_h2_sr3c_20260902/。
5. 并行:12MP 每对匹配深度塌陷侦探在跑(漏斗复测钉出的新头号瓶颈:
   每对 verified 中位仅 136-146 = 预算 2%,vs 4K 时代塌 2.4-7×)。

## 跨端路线共识(供明早裁决)

一套 WGSL/Dawn 代码 = 三端公共实现(Dawn: iOS→Metal,安卓/鸿蒙→Vulkan);
iOS 上与现役 Metal 核逐字节同语义(parity 套件为证)。iOS 差距(目前 2.7×,
今晚在砍)是"一套代码"的代价;Vulkan 端因原生整数点积预期显著更优。
生产化缺口(明日以后):guided 两趟路径 WGSL 化、production ABI TU、
Android/鸿蒙实机 V0/V1/V2 探针。

## 附件

attachments/2026-09-02-h2-matcher/:fair_match_common.h、
fair_match_portable_arm.PRE_SR3C.cc(SR-3C 前原件)、fair_match_parity_suite.sh
(aether_cpp git 经 iCloud 挂死,照旧在本仓保底)。

## 生产化设计(草案,待 SR-3C 定核后落地)

现役 Metal TU(pwofficial_gpu_match.mm,2103 行)的完整 ABI 面(已盘点):
- `aether_gpu_match_gemm_pairs`(主入口,weak 引用,缺席自动回退 CPU)
- `aether_gpu_match_gemm_pairs_resident` + `descriptor_residency_invalidate/clear_session`(描述子驻留)
- `aether_gpu_match_last_error`(rc=7 错误桥接到 sfm_match_fail.jsonl)
- `aether_match_set_ab_phase` / `set_capture_active` / `set_preview_fps30`(热/相机竞争节流)
- 观测量:`aether_match_gpu_ms/sleep_ms/chunks`
- 行为:KNIFE-C 分块(env OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS,自校准
  成本模型 + 热占空隙)、30s 超时 watchdog(可移植 condition_variable,
  返回码 0/7/8 分类已按 Vulkan DEVICE_LOST 映射预留)、零填充不变量、
  buffer 池互斥。

guided 语义(WGSL 化时逐字对齐):
- mode1 E/F:对称极线残差 `nom²≤maxResidual·denom`(两条线都算);
- mode2 H:重投影 `|Hq/hz−d|²≤maxResidual`,hz≤1e-8 拒;
- 距离域:plain=acos(dot/512²) 角度 + 绝对门;guided=归一化 L2
  √(2−2cos),second 以 131072 点积哨兵垫底(=COLMAP 哨兵距离 512);
- ⚠️ 已证明:guided 门的浮点代数跨编译不逐位(1575 假设全败);验收口径
  = 边界受限发散(±1 match/对量级)+ 下游无损,产线 Metal 自己也因此
  guided→v1 两趟。
- 平局铁律:best=max dot,平局最小下标;升序严格 >;merge 平局保 ours。

跨端 TU 形态(建议):`pwofficial_gpu_match_dawn.cc` 导出同一 weak ABI,
iOS 端 env 开关择 Metal/Dawn(默认 Metal 不动,单变量上机),安卓/鸿蒙端
唯一实现;chunking/watchdog/池子逻辑平移(全部已是可移植 C++)。

## 全量闸就绪(2026-09-02 16:0x)

- iCloud 把 ~/Documents 下的 cap7_day 夹具库(195MB)现场蒸发(EPERM,
  brctl 下载也被拒)—— 8192 基准夹具幸存于 /private/tmp;全量闸改用
  **今天 build-89 的两场 12MP 会话库**(20 帧 + 51 帧,已在 ~/Developer,
  比 cap7 更能代表现役口径)。
- `~/Developer/pw_h2_fullgate_20260902/run_fullgate.sh <kernel> [maxf]`:
  逐帧抽描述子 → 时间 K12 全对(20 帧 ≈ 222 对)→ native vs 候选核
  每对 pairs SHA 逐字节对拍。烟测 10/10 全等;fusedr128 全量在跑。
  51 帧库(db_second.db)已备作第二阶段。

## 全量闸结果:696/696 逐字节全等(2026-09-02 16:1x)

fusedr128 对 native Metal,今天两场 build-89 真实 12MP 会话的时间 K12 全对:
20 帧场 162/162 + 51 帧场 534/534 = **696 对,零失配**。08-01 的
parity-scope 顾虑("byte-exact 只验过一对")就此关闭 —— 便携核在现役口径
的真实数据上语义防弹。最终候选(SR-3C 胜者)出炉后同闸复跑。

## SR-3C 中期战报(执行官,2026-09-02 16:05)

- **Direct-B 全族筛选即死**(GPU 27-34ms,四种布局组合全输 2.1-2.7×):
  M3 上 Right 片段直读 device 远慢于 16KiB 共享 tile 复用。
  「Direct-B×预转置」活口正式关闭。
- **tacc 正式轮 REJECTED(慢 0.44ms)**,且 08-01 的"筛选假胜"机制被独立
  复现定罪:该类变体对冷基线伪影系统性亲和 —— 筛选口径永久拉黑,只认
  镜像 ABBA。
- **tb-常驻 = SR-3C 唯一幸存刀**:GPU paired −0.30ms(−2.3%),镜像两半
  方向一致;生产语义 = B 侧描述子入库时转置一次常驻(与现役
  descriptor residency ABI 天然契合)。冷模式(逐调用转置)绝对不可用。
- s33(stride 填充):r128 结构性超 32KiB 预算;r64 上 ≈ 噪声。
  bank-conflict 假设未获支持。
- 顺手修两个静默 bug:核名解析器吞后缀(误排序名静默降级)、
  mma/fused RUN-FAIL 真因 = 占位符只在 fusedr 分支替换(非 Dawn 漂移),
  已修复活,parity 全绿。
- SR-3D 已实现待测:-db 软件流水(3→2 barrier/tile,预算内版)、
  -xb barrier 成本探针。r64 对照轮被机器负载污染作废 —— 污染源含并行
  侦探的重放(主线调度失误,已改为串行:等深度侦探收工再补正式轮)。
