# ⑤ XRSLAM 生产接入：范围书

> 2026-09-15 初版。**这不是实施计划，是范围与约束的界定。**
> 每条判据都标了出处；没有出处的地方明确写"未定，阻塞"。

## 0. 一句话范围

**本阶段只建「晋级闸」——用证据回答"XRSLAM 够不够格接管"；不做运行时接管。**

理由（09-14 查实）：接管需要一个"此刻可不可信"的运行时判据，而
**唯一许可干净且跨端的判据（ROVIO `lightweight_filtering/OutlierDetection.hpp:32/41-42` 的 NIS）
需要状态协方差 P，XRSLAM 拿不出**（`ceres::Covariance` 用 0 次；三个 `sqrt_inv_cov` 分别是
2×2 像素噪声 / 15×15 IMU 因子 / 边缘化里 1e15 的规范固定假数）。
详见 `reference_vio_pose_confidence_criteria_survey_20260914`。

⇒ **没有运行时判据就接管 = 无法在出错时发现**。本阶段不做。

## 1. 硬约束（违反即方案无效）

| # | 约束 | 出处 |
|---|---|---|
| C1 | **不允许静默切换/回退** | `lib/official_dome/platform_pose_provider.dart` 文件头："deliberately fail-closed … must never produce synthetic poses or borrow the self-developed channel" |
| C2 | **权限只能由代码开，数据不能提权** | `lib/vio/diagnostics/vio_shadow_se3_comparison.dart:34-36`："The authority boundary is code, not input data" |
| C3 | **喂给 XRSLAM 的有效帧率 ≤30** | 60fps 下初始化窗口 `gap×(num−1)=35` 帧仅 0.58s，攒不出 `min_parallax=10px` ⇒ 零位姿（09-14 四场对照实测） |
| C4 | **跨端**：判据不得依赖 ARKit/ARCore 等平台专有能力 | 用户 09-14 明示；另见 `feedback_no_platform_specific_knives_all_platforms_together` |
| C5 | **阈值必须有出处**：只接受①自测噪声地板 p99 ②官方配置常数 | `feedback_threshold_needs_provenance_before_experiment` |
| C6 | **门槛 = 同机同条件逐项不劣于生产 ARKit** | `feedback_replacement_bar_is_relative_to_production_arkit` |

🔴 **C1 与 C4 的交互（易错点）**：拿"与 ARKit 的一致度"当判据，**只能用在晋级闸**
（影子期、iOS、离线判断"够不够格"）；**不能用作运行时判据**，因为安卓/鸿蒙没有 ARKit。
这两件事 09-14 之前我混为一谈过，必须分开。

## 2. 消费点清单与风险分级

`ARPoseProvider`（`lib/official_dome/ar_pose.dart:571`）是既有的接缝，已有
`PlatformARPoseProvider`(ARKit) 与 `MockARPoseProvider` 两类实现。
⚠️ **但它不是纯位姿接口**：还包含 `saveCurrentFrameAsJpeg` / `saveCurrentFrame` /
`captureHighResolutionStill` / `lockOrigin`。**XRSLAM 只能供位姿那一路**，
相机帧、照片、锚点仍必须来自 ARKit ⇒ **不存在"整体替换"，只有"位姿换源"**。

生产里消费位姿的位置（09-14 grep 统计，按风险排）：

| 风险 | 消费点 | 后果 |
|---|---|---|
| 🔴 最高 | `official_capture/official_highres_reconstruction_input.dart`(6 处) | 每张照片配的位姿 ⇒ 错了**整个重建作废**（09-07 有先例：接口两端拆开导致每张照片都废） |
| 🔴 高 | `official_capture/sfm_live_recon.dart`(3 处) | 实时重建输入 |
| 🟠 中 | `official_capture/capture_session.dart`(4 处) | 会话级几何 |
| 🟠 中 | 自动拍触发几何（`auto_capture_geometry` / `governor`） | 拍摄间距判据错 ⇒ 拍得过密/过疏 |
| 🟡 低 | `official_capture/capture_coverage_cloud.dart`(3 处) | 覆盖显示与引导 |
| 🟡 低 | `ui/official_capture/ar_capture_page.dart`(2 处) | AR 显示 |
| — | `archived_photo_rebuild.dart` / `sfm_db_regen.dart` | 离线路径，不在本范围 |

**本阶段范围内的消费点：零个。** 晋级闸只观察，不改变任何消费点的数据来源。

## 3. 晋级判据

### 3.1 已经有尺子的部分
| 项 | 尺子 | 现状 |
|---|---|---|
| 绝对精度 | EuRoC 动捕真值，三档难度 | 已打通：ATE **5.14 / 9.54 / 10.50 cm**（easy/medium/difficult） |
| 与 ARKit 一致度 | 设备录像回放，两条 `.tum` 电脑侧比 | 通道可用（`replay-device-recording` 用录像自己的标定尺寸=1920×1440） |
| 热态 | 台架 300s 直播 | 口径已定，但需在部署配置（≤30fps）下重测 |
| 吞吐 | 每帧处理耗时 | 1920×1440 实测 **17.6 ms/帧**（851 帧 15 秒） |

### 3.2 ✅ ⑥ 已查清（09-15）：**不存在"精度达标线"这个东西**
`BenchGateEvaluator.swift:80-89` 的四个绝对阈值
（`ate>0.10` / `rpe_t>0.05` / `rpe_r>5°` / `coverage<0.99`）：
- **代码零注释**；引入提交 `d051a76`(08-30) **提交信息零说明**；
  唯一提到它们的文档 `VIO_THREE_ARM_BENCH_HANDOFF_2026-08-30.md:722-727`
  **只是复述四个数** ⇒ 文档引代码、代码引空气 = **自我引用，不是出处**。
- 按 09-03 裁决（否决 1800ms/30fps 的同一条），**这四个数不合法**。

🔴 **结构性空洞**：合法的"不劣于 ARKit"**在 EuRoC 上用不了**——
ARKit 跑不了 EuRoC（`ActiveVIOEngineSession.swift` 在回放路径对 ARKit 后端直接抛异常）。
⇒ EuRoC 回放闸**目前没有任何合法的通过/不通过判据**。

### 3.3 因此晋级判据的合法形态（定案）
| 用法 | 合法性 |
|---|---|
| 设备上**逐项不劣于 ARKit**（热态/帧率/p95/内存/有限位姿比等 ARKit 能跑的项） | ✅ 合法（09-03 用户裁决） |
| EuRoC **不劣于改动前**（无损闸） | ✅ 合法（09-03 用户补充原话） |
| EuRoC ATE < 某绝对值 | ❌ **不合法**，除非该值有出处 |

⇒ **ATE 5.14/9.54/10.50 cm 只能作为证据陈述，不能当闸。**
⇒ "够不够格晋级"最终是**用户判断**，不是一条自动化的及格线。

## 4. 验证方法

### 4.0 🔴 配置前置（09-15 新增，最高优先级）
**被测的臂必须是生产实际出货的引擎档。**
- 生产现役 = `libxrslam_generic_4beb1a9.a`（**threading OFF + GPU 前端 OFF**）；
  生产 vendor 目录里**只有** generic 与 official 两个库。
- 台架 `-PWXrslamGpuFrontend` 臂 = `libxrslam_gpufe_4beb1a9.a`
  （`pw_build_gpufe_arm.sh` 头注释：**GPU_FRONTEND=ON, threading+gate as thrbp**）
  —— **这个库生产树里不存在**。
- ⇒ **09-09~09-14 的全部测量都在非出货配置上做的**（热态 253s / EuRoC ATE 三档 /
  1920×1440 799 位姿 / 17.6ms 每帧），用于晋级论证前必须注明，或用 generic 臂重测。

### 4.1 每一场测量的有效性前置（不满足即作废，不得当数据用）
1. **存活闸**：连查两次进程 >200 行 + 热态非 −1 + 日志见 `Launched application`
2. **硬性 300 秒上限**，到点强制停，过程中每 60 秒报进展
3. **挂死判别**：`heartbeat.written_at_utc − receipt.started_at_utc` 停在 +10s 量级
   且 `receipt.state` 卡在 `started` ⇒ 挂死，**不是算法失败**，该场作废
4. **重复 ≥2 次**：单场结果不可信（09-14：同配置一次 15 秒 799 位姿、一次挂死零位姿）

### 4.2 晋级证据要同时具备
- **绝对精度**：EuRoC 三档，重复 ≥2 次，取中位
- **一致度**：≥2 份设备录像，在 ≤30fps 与 1920×1440 下回放
- **热态**：部署配置下与 ARKit 同条件对照（ARKit 基线**必须重测**——现有的
  "600s 全程不出 fair" 是 09-03 在**不跑重建**的台架上单场测的，不可用）
- **吞吐/内存**：同上

### 4.3 判决形式
逐项相对比（C6），**任何一项劣于 ARKit 即不晋级**；证据不足也不晋级（fail-closed，C1）。

## 5. 明确不在本范围内
- ❌ 运行时接管、运行时可信度判据（缺协方差，见 §0）
- ❌ 改 `productionAuthorityEligible`（那是接管才需要的）
- ❌ 改 XRSLAM 引擎（加协方差属研究不属复刻）
- ❌ 改 `maxRetainedImages` 2→30（会扣住 ARKit 缓冲池，风险大于收益，需单独方案）

## 6. 依赖与阻塞清单
| # | 阻塞项 | 影响 |
|---|---|---|
| ~~B1~~ | ~~⑥ 阈值出处未查~~ | ✅ **09-15 已解除**：四个数确认无出处、不合法；晋级改用相对判据（§3.3） |
| B2 | ARKit 热态基线需在可比条件下重测 | 阻塞热态那一项 |
| B3 | 偶发挂死未定案（**已排除 GPU 等待**：harness 零 `UINT64_MAX`、每个 `WaitAny` 都有限超时；新嫌疑=**线程化死锁**） | 每场测量都可能被静默污染（§4.1 第 3/4 条是缓解不是根治） |
| **B5** | **台架臂 ≠ 生产引擎档**（见 §4.0） | **所有既有测量的可用性存疑**；这是当前最大的证据缺口 |
| B4 | 影子 `transportValid` 的时基那半未定案 | 需装机读新加的计数器 |
