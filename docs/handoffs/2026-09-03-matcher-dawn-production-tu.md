# 跨端匹配器生产 TU(Dawn/WGSL)—— 2026-09-03 战役报告

用户裁决:三端(iOS/安卓/鸿蒙)公用一套匹配器优先级最高。本轮目标:把已验证的
便携 WGSL/Dawn 匹配核(`fusedr128-db`,09-02 夜 696/696 逐字节)**生产化**为可上
iOS 单变量装机的 TU,并铺好 Vulkan 车道。主机侧完成;**未装机、未 git commit、
未产 xcframework**;现役 Metal TU 源码零改动(SHA 未变、编译产物 `__text` 段字节
md5 与出货编译完全一致)。

## 0. 一句话结论

`pwofficial_gpu_match_dawn.cc` 已就位:平路径 = parity 19 案例 × 6 变体全绿 +
全量闸 **696/696** 逐字节(+ tiled 后端 162/162、微分块 162/162);guided 两趟 =
**148 个夹具 76,082 对全部与 Metal v1 逐字节相同**(含 8 个骑阈值探针,零发散);
性能 = 8192² 单体提交 11.01ms vs 老台架 11.38ms(−3.3%,6/6 轮);iOS 四个 .o 编过;
分发层默认 `metal`、env `OFFICIAL_AETHER_MATCH_BACKEND=dawn` 切换;tint 把同一份
WGSL lower 成 SPIR-V:tiled→`OpUDot`+`DotProductInput4x8BitPacked`(V1),
mma→`SPV_KHR_cooperative_matrix`(V0)。

## 1. 文件清单(工作区,均未提交)

| 文件 | 状态 | SHA-256(前 16) | 说明 |
|---|---|---|---|
| `vendor/official_sfm/src/pwofficial_gpu_match_dawn.cc` | 新 2116 行 | `fc5fc4179174d22f` | 生产 TU(本报告主角) |
| `vendor/official_sfm/src/pwofficial_gpu_match_dispatch.cc` | 新 270 行 | `b3ce96ead376bf3c` | 薄分发层,拥有公开 `aether_gpu_match_*` ABI |
| `vendor/official_sfm/src/pwofficial_gpu_match_metal_rename.h` | 新 | `b297dbffd3fbb087` | `-include` 强制包含,把 Metal TU 导出改名 `pwmetal_*` |
| `vendor/official_sfm/src/pwofficial_gpu_match_thermal_apple.mm` | 新 | `a2eec46ea60e35cd` | Apple 热状态弱钩子提供者(NSProcessInfo) |
| `vendor/official_sfm/scripts/build_xcframework.sh` | **改**(+40/−1) | `d26d45f13f713e14` | 加 3 条编译 + 3 个 .o 进链接清单;Metal 编译行加 `-include` |
| `vendor/official_sfm/src/pwofficial_gpu_match.mm` | **未动** | `08a6d4854a79ed80` | `git diff` 为空 |
| `vendor/official_sfm/tests/pwofficial_gpu_match_dawn_host_arm.cc` | 新 | `618f1406a97f38be` | host 平路径臂(与 H2 台架 argv/输出契约相同) |
| `vendor/official_sfm/tests/pwofficial_gpu_match_dawn_host_build.sh` | 新 | `953221ed27b8a410` | host 门二进制构建(照 fair_match_build.sh) |
| `vendor/official_sfm/tests/pwofficial_gpu_match_dawn_fullgate.sh` | 新 | `795b96e9e2097061` | 全量闸副本(bin/frames 目录参数化,env 透传) |
| `vendor/official_sfm/tests/pwofficial_gpu_match_guided_fixtures.py` | 新 | `878ce1a96c7817b6` | guided 夹具:db 真实对(复刻 PrepareGuidedGeometry)+ 骑阈值探针 |
| `vendor/official_sfm/tests/pwofficial_gpu_match_guided_compare.mm` | 新 | `131a53617b48ed30` | Metal v1 vs Dawn guided 对拍 + 边界距离分析 |
| `vendor/official_sfm/tests/pwofficial_gpu_match_dawn_abi_test.cc` | 新 | `c985791b63c769ad` | probe_batch / 驻留 / 参数校验 / guided 校验 |
| `docs/handoffs/attachments/2026-09-03-matcher-dawn-tu/` | 新 | — | 全部证据(§9) |

完整 diff:`attachments/2026-09-03-matcher-dawn-tu/workspace_full.diff`(3506 行;
`build_xcframework.sh` 的 `git diff` + 新文件 `--no-index` diff;未碰 index)。

## 2. 分发层设计(最小侵入,Metal TU 一行不动)

- **改名不改源**:`pwofficial_gpu_match.mm` 用 `clang++ -include pwofficial_gpu_match_metal_rename.h`
  编译,11 个导出 C 符号被宏改名为 `pwmetal_*`(gemm_pairs / _resident /
  residency_invalidate / _clear_session / _stats / probe_batch / gemm_pairs_guided /
  last_error / set_ab_phase / set_capture_active / set_preview_fps30)。
  **等价证明**(iOS arm64 `-O3`,同款旗标):改名版与出货版 `.o` 的 `__TEXT,__text`
  原始字节 md5 相同 `656b526ff69e79809f48389ba579b290`;`otool -tv` 反汇编 9547 行,
  diff 仅文件名与 3 个 `.cold.1` 标签名(`attachments/…/ios_proof/`)。
- **不改名的共享词**:`aether_match_gpu_ms/sleep_ms/chunks`(Metal TU 定义,Dawn TU
  在 iOS 构建里 `-DPWOFFICIAL_DAWN_OBSERVABLES_EXTERN=1` 声明为 extern,两后端累加同一
  组变量);`aether_gpu_match_get_capture_active`(Dart dlsym,留在 Metal TU,两后端
  旗一起设)。非 Apple 构建里 Dawn TU 自己定义这四个。
- **分发层** `pwofficial_gpu_match_dispatch.cc`:导出公开 ABI 全集(与 .mm 逐符号
  相同)+ 三个新增:`aether_gpu_match_set_thermal_state(int)`(便携热状态喂入)、
  `aether_gpu_match_backend_name()`(返回 "metal"/"dawn",**装机≠生效**的核验点)、
  `aether_gpu_match_backend_info(buf,cap)`。选择:env `OFFICIAL_AETHER_MATCH_BACKEND`
  进程内读一次,未设/`metal` → Metal(默认路径,单变量纪律),`dawn` → Dawn;
  `-DPWOFFICIAL_MATCH_NO_METAL` 时(安卓/鸿蒙)只有 Dawn。旗 setter(capture_active /
  fps30 / ab_phase)**同时**转发两后端。
- **热状态跨端**:Metal TU 直接读 NSProcessInfo(Apple 专属)。Dawn TU 读弱钩子
  `pwofficial_platform_thermal_state()`(Apple 由 `..._thermal_apple.mm` 提供,同一
  0..3 刻度)或显式 setter;serious/critical 触发块目标/占空隙与 Metal 完全同规则。
- `build_xcframework.sh` 改动(见 diff):派生 iOS Dawn 头路径(从钉定归档路径推,
  两个 `[ -f ]` 守卫)、Metal 编译行加 `-include`、新增 dispatch/dawn/thermal 三条编译、
  设备链接清单加三个 .o。模拟器切片不含匹配器(原样)。契约测试
  `test_official_gpu_carrier_promotion_contract.sh --source-only` 仍 PASS。

## 3. 生产 TU 要点(`pwofficial_gpu_match_dawn.cc`)

- **平路径核** = `fusedr128-db` 逐字(文本不是手抄:在 scratch 给台架源拷贝打 3 行
  dump 补丁,让台架自己的装配路径吐出 `fusedr128-db` / `tiled` 最终 WGSL,
  SHA `2e4a7d40…` / `1de3662a…`,r63x129 用例 pairs SHA 与冻结金标准 `113f782f…` 一致
  证明补丁未改语义;`attachments/…/wgsl/harness_*.wgsl`)。生产文本仅两处 delta:
  `Params.pad0`→`rowBase`、`let rb = U.rowBase + wg.x` 且 `ColP[c*numWg + rb]`
  (rowBase=0 时与前沿逐位等价;KNIFE-C 分块必需——WebGPU 无 dispatch 基址)。
- **输入格式**:C ABI 仍是 u8 描述子;GPU 侧沿用前沿核的 host 展开 f32(`array<f32>`,
  subgroup-matrix 只有 f32 8×8×8 精确档),每对 2×4MB 上传(0.83ms,与台架 prep 同)。
  任务书写的"u8 packed ABI"指的是 C ABI;把 u8 解包搬进核是未来单变量刀,本轮不动前沿。
- **回退核** = `tiled`(u8 packed `dot4U8Packed`),同 rowBase delta;parity 19 全绿。
- **guided 两趟**(v1 结构):行向单方向核 = 前沿核的行半边(同 MMA 流水、同 160/352
  staging 调度、去掉列偏序/merge)+ 门在 top-2 插入前:mode1 `nom²≤maxResidual·denom`
  (line2=M·p1、line1=Mᵀ·p2、denom>1e-12)、mode2 `|Hq/hz−d|²≤maxResidual`(|hz|≤1e-8 拒),
  终门 √(2−2cos) + 131072 哨兵——表达式树与 .mm v1 `pw_match_gemm`(:340-373, :385-395)
  逐字转写。两次 dispatch(A→B 用 matAB,B→A 镜像 matBA)。tiled 也有 guided 版。
- **可移植平移**(标准 C++):ChunkTargetMs/Cool/FPS30/ALT、ThermalGapPct、EMA 成本模型
  (每核族一个 EMA)、rc 分类、grow-only 池 + 全局互斥、驻留 V1(共享策略头;f32 表以
  `kHalf` 作格式标签、按 f32 字节计账)、probe_batch(K 候选独立区域、同一 pass 顺序
  dispatch、成本模型分组)。
- **watchdog**:`wgpu::Instance::WaitAny(future, timeout)`(TimedWaitAny),env
  `OFFICIAL_AETHER_GPU_MATCH_WAIT_MS` 默认 30000;超时→7。device-lost 回调:
  `Unknown`→7(下次调用拆掉重建,250ms 冷却),`Destroyed/FailedCreation`→8;
  uncaptured `OutOfMemory`→5,其余→7。
- **静默出口封堵(Dawn 特有)**:Dawn Metal 后端的 completed handler
  (`QueueMTL.mm:236`)**不读 `MTLCommandBuffer.error`**,热压 GPU hang 会"成功完成"而
  输出是垃圾。对策:提交前所有输出槽写 `INT32_MIN` 哨兵,回读后残留哨兵 ⇒ rc 7。
  核只写 −1 或 ≥0 索引。跨端通用(Vulkan 亦受益)。
- **V0/V1/V2 分支点**(`CreateCtx()`):V0 = Subgroups + ChromiumExperimentalSubgroupMatrix
  + F32 8×8×8 配置 + subgroup 固定 32 + ≥512 invocations + ≥32KiB workgroup 存储 →
  `fusedr128-db`;否则 tiled(V1/V2 由 Dawn 运行时按 `VK_KHR_shader_integer_dot_product`
  决定原生/polyfill,`PhysicalDeviceVk.cpp:1225-1228`);env
  `OFFICIAL_AETHER_MATCH_DAWN_KERNEL=tiled` 强制回退做 A/B。选中的分支 init 时 stderr
  打印一行并可经 `backend_info` 读回。
- **Dawn 设备不共享**:提取器 harness 的设备创建时未请求 subgroup-matrix 特性(特性在
  设备创建期固定),共享需改 aether_cpp 核心 = 动默认路径 → 独立持有一套
  instance/adapter/device(同一物理 GPU 的第二个 wgpu::Device)。

## 4. 门

### 4.1 平路径 parity(19 案例三重金标准 pairs+OutAB+OutBA,`fair_match_parity_suite.sh` 原脚本)

| 变体(env) | 结果 |
|---|---|
| 默认(mma,16ms 分块) | PARITY_SUITE_PASS 19/19 |
| `DAWN_KERNEL=tiled` | 19/19 |
| `CHUNK_TARGET_MS=0`(单体) | 19/19 |
| `CHUNK_TARGET_MS=0.001` + COOL 同(微分块,rowBase>0) | 19/19 |
| tiled + 单体 / tiled + 微分块 | 19/19 / 19/19 |

### 4.2 全量闸(native Metal 出货 TU vs 新 TU,时间 K12 全对,pairs SHA 逐对逐字节)

| 库 | 对数 | 变体 | 结果 |
|---|---|---|---|
| db51(20 帧 12MP,build-89) | 162 | 默认 | **162/162** |
| db_second(51 帧) | 534 | 默认 | **534/534** |
| db51 | 162 | tiled 回退 | **162/162** |
| db51 | 162 | 1ms 微分块(实测每对 64 次分块提交,rowBase 遍历全部 64 行块) | **162/162** |

合计默认路径 **696/696**。日志 `attachments/…/fullgate/`。host 臂自检:TU 输出的
pairs 与共享 host 参考 `MutualPairs(dirmaps)` 逐字节相同(每次调用都比)。

### 4.3 guided(Metal v1 两趟 vs Dawn)

夹具:db51 全部 140 条 two_view_geometries(114 × CALIBRATED/E → mode1 归一化坐标,
残差 (4px/f̄)²=1.94e-6;26 × PLANAR_OR_PANORAMIC/H → mode2 像素,残差 16;复刻
`PrepareGuidedGeometry` :3602-3660,相机 PINHOLE 4032×3024)+ 8 个合成探针(F/H 各
4 档 eps∈{0,1e-6,1e-4,1e-2},候选点被放在 `nom²/denom = res·(1±eps)` 上,半上半下)。

| 组 | 夹具 | 逐字节相同 | Metal 总对 | Dawn 总对 | 差集 |
|---|---|---|---|---|---|
| real E mode1 | 114 | 114 | 67,309 | 67,309 | 0 |
| real H mode2 | 26 | 26 | 9,820 | 9,820 | 0 |
| probe F mode1 | 4 | 4 | 1,670 | 1,670 | 0 |
| probe H mode2 | 4 | 4 | 283 | 283 | 0 |

**边界发散计数 = 0**(验收口径是 ±1 match/对量级的边界受限发散,实测优于口径)。
诚实口径:这是 148 个夹具上的经验结果,**不宣称构造性逐位**——.mm 头部证明过融合核
的门代数跨编译不逐位;本 TU 的行向核经 tint→MSL 恰好复现了 v1 的门比特,原因未定罪
(推测:同为"单方向、门在循环内、矩阵从 device 读"的表达式树,tint 未重结合),
换 Dawn/tint 版本或换 GPU 后可能出现边界发散,对拍臂已备好可复跑。
门确实生效:real_E_1_2 平路径 984 对 vs guided 303 对(4px 带在 12MP 上很紧,两端一致)。

### 4.4 ABI 测试(`pwofficial_gpu_match_dawn_abi_test`,8192² 夹具)

四种配置(mma+驻留 / mma 单体 / tiled+驻留+0.5ms 分块 / mma+驻留+0.5ms 分块)全 PASS:
参数校验 9 项 rc=1;probe_batch 12 个候选(nB∈{8192,4000,1000,513,512,129,128,127,64,7,1,2500})
计数与逐对 `gemm_pairs` **完全相等**(和=367);驻留:plain==resident#1==resident#2
(sha 94449fe3…),stats hits=2/misses=2/entries=2,generation bump 计 stale=1,
invalidate→entries=1,clear_session→会话消失。

### 4.5 性能(8192² 真实夹具 f2×f3,paired ABBA 6 轮 `A B C N N C B A`,每臂 10 rep/3 warmup,GPU 空闲;pycolmap 审计 agent 占 CPU load≈2.8)

| 臂 | submit→done p50 中位 (ms) | 墙钟 p50 中位 |
|---|---|---|
| A 老台架 `fusedr128-db` | 11.381 | 12.198 |
| **B 新 TU 单体**(CHUNK=0) | **11.009** | 11.825 |
| C 新 TU 默认分块(16ms) | 13.509 | 14.302 |
| N native Metal 出货 TU | 4.899 | 4.899 |

配对:B−A 中位 **−0.372ms(−3.3%),6/6 轮 B 更快**(池化省掉台架每 rep 建缓冲);
在 ±5% 门内。C−B 中位 **+2.51ms** = Dawn 上 KNIFE-C 政策的单价:同政策下多两次
提交往返(实测 aether_match_chunks=2:首探 8 行块 + 余下 56 块,再加 merge 提交 = 3 次),Dawn 每次提交往返 ≈1.2ms(Metal TU 同
政策但 command buffer 更便宜)。A/N = 2.32×(本夹具;09-02 的 ~2.1× 是另一夹具)。
四臂 pairs SHA 全等 `70dd9690…`。原始 `attachments/…/abba_perf.tsv`。

### 4.6 iOS 编译(不装机、不产 xcframework)

SDK iPhoneOS 26.2,Apple clang 17.0.0;与 `build_xcframework.sh` 同款旗标:

```
SDK=$(xcrun --sdk iphoneos --show-sdk-path); R=~/Developer/Aether3D-cross/aether_cpp
F="-target arm64-apple-ios14.0 -isysroot $SDK -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 -std=c++17"
xcrun clang++ $F -DPWOFFICIAL_DAWN_OBSERVABLES_EXTERN=1 -I$R/third_party/dawn/include \
  -I$R/build-ios-device-dawn/third_party/dawn/gen/include -Iinclude \
  -c src/pwofficial_gpu_match_dawn.cc -o gpu_match_dawn.o          # 167,848 B
xcrun clang++ $F -c src/pwofficial_gpu_match_dispatch.cc -o gpu_match_dispatch.o   # 8,840 B
xcrun clang++ $F -fobjc-arc -c src/pwofficial_gpu_match_thermal_apple.mm -o gpu_match_thermal_apple.o
xcrun clang++ $F -fobjc-arc -include src/pwofficial_gpu_match_metal_rename.h \
  -c src/pwofficial_gpu_match.mm -o gpu_match.o                     # 改名版,__text md5 = 出货版
```
(zsh 下 `$F` 不分词,实际逐条展开执行;`attachments/…/ios_proof/ios_objects_sha256.txt`)。
符号核对:改名版 Metal .o 只导出 `pwmetal_*` + 三个观测量 + `get_capture_active`;
dispatch .o 定义全部 `aether_gpu_match_*`、引用 `pwmetal_*`/`pwdawn_*`;Dawn .o 引用
extern 观测量与弱钩子;thermal .o 定义钩子。链接侧 Dawn 归档已由脚本 `-force_load`
(提取器在用,SHA `625cf65d…` Debug-iphoneos,与主机 Dawn 同源 commit
`12ee391c7411285895f4289a3d889a182c093014`)。

## 5. Vulkan 车道(主机能做的部分)

- tint 单独构建(主机 Dawn 构建 `TINT_BUILD_SPV_WRITER=OFF`):同一 dawn 源树,
  `-DTINT_BUILD_CMD_TOOLS=ON -DTINT_BUILD_SPV_WRITER=ON -DDAWN_ENABLE_METAL=OFF …`,
  须 `-DPython3_EXECUTABLE=/usr/bin/python3`(homebrew 3.14 的 pyexpat 链错 expat)。
  产物在 scratch,不入库。
- 生产 WGSL(从 TU 源抽出的四份文本,SHA 见 `attachments/…/spirv/`)lower 结果:

| 核 | Capability / Extension | 关键指令 |
|---|---|---|
| tiled_plain / tiled_guided | `DotProduct`, `DotProductInput4x8BitPacked`, `SPV_KHR_integer_dot_product` | `OpUDot`×4(**V1 原生整数点积**) |
| mma_fused(`--ep main`)/ mma_guided | `CooperativeMatrixKHR`, `GroupNonUniform`, `VulkanMemoryModel(+DeviceScope)`, `SPV_KHR_cooperative_matrix`, `SPV_KHR_vulkan_memory_model` | `OpCooperativeMatrixLoadKHR`×2 / `MulAddKHR` / `StoreKHR`(**V0**) |
| mma_fused(`--ep merge`) | Shader + VulkanMemoryModel | 无 |

  对照 MSL:tint 把 tiled 的 `dot4U8Packed` lower 成 `tint_dot(uint4, uint4&255)` 标量
  polyfill(`attachments/…/spirv/tiled_plain.msl:64`),证实"Metal 上是 polyfill";
  mma 核 lower 出 `simdgroup_load/multiply_accumulate/store`(14 处)。
- **V2** 无法用 tint 命令行单独复现(polyfill 开关 `dot_4x8_packed` 只由 Dawn 运行时
  按设备 ext 置位:`PhysicalDeviceVk.cpp:1225`→`Toggle::PolyFillPacked4x8DotProduct`;
  tint `builtin_polyfill.cc DotPacked4x8` 默认发 `OpUDot`)。代码里的三条路线分支点
  = `CreateCtx()` 的 `mma_ok` 判定(V0)与 tiled 回退(V1/V2 由 Dawn 决定),已注释。
- SPIR-V 只经 tint 内部 IR 校验;`spirv-val` 目标在此配置不存在,未跑。
- **安卓前提**(未实机,基于已有日志判断):Android 15 基线 Vulkan 1.3 ⇒
  `shaderIntegerDotProduct` 核心 ⇒ V1 原生;V0 需 `VK_KHR_cooperative_matrix` +
  vulkanMemoryModel + computeFullSubgroups 且 **subgroup 固定 32**——Mali 是 16、
  Adreno 常 64(Dawn 有 `ChromiumExperimentalSubgroupSizeControl`,
  `PhysicalDeviceVk.cpp:538`,可作未来刀),所以安卓大概率先落 V1。**不确定**。
- **鸿蒙 NEXT 前提**(不确定,标注):Dawn 源树无 OHOS 平台移植;计算-only 不需窗口/
  surface,需要的只是 (a) OHOS NDK(clang/libc++)的 CMake 工具链能编 Dawn native +
  tint,(b) Vulkan loader `libvulkan.so` 的 dlopen 路径,(c) 目标 GPU(如 Maleoon 910)
  的 Vulkan 版本与 `VK_KHR_shader_integer_dot_product`/cooperative_matrix 支持——三项
  均未核。同一份 WGSL 与 TU 源码不需改。

## 6. 未做 / 不确定 / 已知偏差(宁空勿编)

1. **未装机、未跑 xcframework、未真机验证 Dawn 后端**;`OFFICIAL_AETHER_MATCH_BACKEND=dawn`
   在设备上是否生效必须用 `aether_gpu_match_backend_name()`/`backend_info` 核实。
2. **成本模型单位含提交开销**:Metal TU 用 `GPUStartTime/EndTime` 纯 GPU 时间;本 TU 用
   submit→done 墙钟(Dawn 无每缓冲 GPU 时间戳,查询集要多一次往返)。后果:块目标
   ≲3ms 时反馈把块压到 1 行块/提交(host 实测 1ms 目标:8192² submit 段 160ms、64 次分块提交
   (实测 aether_match_chunks);语义仍 162/162)。默认 16/24ms 目标不受影响。下一刀:TimestampQuery(主机有,
   iPhone 是否有未知)或对开销做扣除。
3. **rc 8 的 NotPermitted/AccessRevoked 分档不可得**:Dawn 抽象掉了 MTLCommandBuffer
   error;后台无权跑 GPU 会表现为反复 rc 7(重试封装两次退避后 fail-closed 跳过)。
4. **Dawn Metal 不读命令缓冲错误** → 已用哨兵封堵,但 GPU hang 的"为什么"(错误域文本)
   进不了 sfm_match_fail.jsonl,只有"输出不完整"。
5. guided 逐位相同是经验结果(§4.3),不是构造性保证。
6. probe_batch 在 WebGPU 里是同一 pass 内顺序 dispatch(无 Metal concurrent encoder),
   只省往返;主机上未量化其相对 Metal 的收益。
7. 驻留 V1 的 f32 表用 `kHalf` 作格式标签(策略头无 f32 枚举;进程内后端不变故仅需稳定)。
8. 默认分块路径在 Dawn 上比单体多 +2.5ms(§4.5),是政策单价不是核变慢;是否值得为
   Dawn 调整块政策(如凉态一次提交)是另一刀,本轮不动。
9. host 测试臂/对拍臂链接了 Apple 热钩子 .mm(ld64 两级命名空间下弱声明仍需定义);
   安卓侧用 `__attribute__((weak))` 未定义即 NULL,未验证。
10. `fair_match_portable_arm.cc`(台架)未改;dump 补丁只在 scratch 的拷贝上
    (`attachments/…/wgsl/harness_dump_patch_copy.cc` 留档)。
11. 磁盘:开工 6.1G→清派生 build 目录(~/Developer/pocketworld/build 等)→11G。

## 7. 复跑口令

```
# host 门二进制
vendor/official_sfm/tests/pwofficial_gpu_match_dawn_host_build.sh <out>
# parity(任意 env 变体)
aether_cpp/experiments/portable_frontend_pareto/tools/fair_match_parity_suite.sh <out> <work> dawntu
# 全量闸
BIN=<out> FULLGATE_DB=~/Developer/pw_h2_fullgate_20260902/db51.db FULLGATE_LIB=~/Developer/pw_h2_fullgate_20260902/frames MAXF=20 LABEL=x vendor/official_sfm/tests/pwofficial_gpu_match_dawn_fullgate.sh
# guided 夹具 + 对拍
/usr/bin/python3 tests/pwofficial_gpu_match_guided_fixtures.py real <db> <frames> <fx>; … probe <fx>
<out>/pwofficial_gpu_match_guided_compare <fx>/<case> <outdir>
# ABI
OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1=1 <out>/pwofficial_gpu_match_dawn_abi_test <8192 fixture>
```

## 8. 下一步建议(不自作主张)

1. 装机单变量:`OFFICIAL_AETHER_MATCH_BACKEND=dawn` vs 默认,同场交替 A/B
   (`aether_match_set_ab_phase` 两后端同旗),先核 `backend_name`。
2. 成本模型改纯 GPU 时间(§6.2)。
3. 安卓实机 V0/V1/V2 探针(`backend_info` 一行即答)。

## 9. 附件(`docs/handoffs/attachments/2026-09-03-matcher-dawn-tu/`)

`workspace_full.diff`(完整 diff)、`build_xcframework.diff`、`sources_sha256.txt`、
`build_identity.txt`(host 门二进制身份)、`abba_perf.tsv`、`wgsl/`(台架吐出的三份 +
生产四份 + dump 补丁拷贝)、`spirv/`(spvasm ×5、msl ×2)、`parity/`(5 变体日志)、
`fullgate/`(4 道闸日志)、`guided/guided_compare.jsonl`(148 行)、`ios_proof/`
(.o SHA、`__text` md5 ×2、反汇编 diff)、`git_status.txt`。
