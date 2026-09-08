import ARKit
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Flutter
import Foundation
import ImageIO
import simd
import UIKit

// [SPRINT-MODE 2026-07-26] Direct binding to the Metal matcher's
// capture-active flag (pwofficial_gpu_match.mm, linked into this binary via
// the official_sfm pod). 1 = camera live → yield-to-camera pacing (thermal
// duty gaps, small hot chunks); 0 = camera stopped → full-speed matching for
// the queued-frame drain and finalize enrichment. Scheduling only — the
// match set is bit-identical either way.
@_silgen_name("aether_gpu_match_set_capture_active")
func aether_gpu_match_set_capture_active(_ active: Int32)

enum OfficialARKitIdentifiers {
  static let methodChannel = "pocketworld_official_arkit"
  static let poseEventChannel = "pocketworld_official_arkit/pose_stream"
  static let previewView = "pocketworld_official_arkit_preview"
  static let cameraOwner = "official"
}

struct LiveCloudAnchorDeltaV1 {
  let translation: SIMD3<Float>
  let translationMeters: Double
  let rotation: simd_quatf
  let rotationDegrees: Double
}

enum LiveCloudAnchorDiagnostics {
  static func severity(translationMeters: Double) -> String {
    if translationMeters >= 0.10 { return "severe" }
    if translationMeters >= 0.05 { return "warning" }
    return "normal"
  }

  static func delta(
    lock: simd_float4x4,
    current: simd_float4x4
  ) -> LiveCloudAnchorDeltaV1 {
    // ARAnchor.transform is world-from-anchor. Express the current anchor in
    // the lock-time anchor frame so both translation and rotation are true
    // lock-relative deltas even when the lock pose itself is not identity.
    let relative = lock.inverse * current
    let translation = SIMD3<Float>(
      relative.columns.3.x,
      relative.columns.3.y,
      relative.columns.3.z
    )
    let rotation = simd_normalize(simd_quatf(relative))
    let halfAngle = min(1.0, max(0.0, abs(Double(rotation.real))))
    return LiveCloudAnchorDeltaV1(
      translation: translation,
      translationMeters: Double(simd_length(translation)),
      rotation: rotation,
      rotationDegrees: 2.0 * acos(halfAngle) * 180.0 / Double.pi
    )
  }
}

struct LiveCloudRenderMetadataV1 {
  let contract: String
  let sourceReceiveSequence: Int
  let receiveSequence: Int
  let channelPushSequence: Int
  let source: String
  let publishVersion: Int
  let pointCount: Int
  let receiveEpochMs: Int64
  let computeDoneEpochMs: Int64
}

// AetherARKit — in-Runner-binary ARKit bridge.
//
// What it exposes:
//   MethodChannel `pocketworld_official_arkit`
//     • `isAvailable`  → Bool. Whether the device supports
//                        ARWorldTrackingConfiguration. False on iPad
//                        Air 1, iPhone 6 and earlier; true on every
//                        device PocketWorld targets in practice.
//     • `startSession` → Void. Spins up a new ARSession (or restarts
//                        an existing one). Idempotent.
//     • `stopSession`  → Void. Pauses the session and tears down the
//                        delegate.
//     • `lockOrigin`   → {azimuth: Float}. Captures the camera's
//                        current pose as the world reference. The
//                        session keeps running afterwards; subsequent
//                        pose events carry world-relative
//                        position/orientation. Verbatim of
//                        ObjectModeV2ARDomeCoordinator.lockAtCameraForward
//                        with distance=0.5 m.
//
//   EventChannel `pocketworld_official_arkit/pose_stream` → JSON dictionary per
//     ARFrame:
//       {
//         "tx", "ty", "tz"           — camera position in world space
//         "qx", "qy", "qz", "qw"     — camera orientation (unit quat)
//         "extrinsic"                — column-major 16-float 4×4
//         "intrinsicFxFyCxCy"        — 4 floats
//         "isTracking"               — true iff trackingState == .normal
//         "trackingStateName"        — "normal" | "not_available" |
//                                      "limited_initializing" |
//                                      "limited_relocalizing" |
//                                      "limited_excessive_motion" |
//                                      "limited_insufficient_features" |
//                                      "limited_unknown". Mirrors
//                                      ARCamera.TrackingState exactly so
//                                      Tier 1 pose-drift aggregation on
//                                      the Dart side can attribute the
//                                      degraded windows to a root cause.
//         "t"                        — ARFrame timestamp (CACurrentMediaTime)
//       }
//
// Why this lives in the Runner target rather than as a pub plugin:
//   Same reason as AetherPrefsPlugin — keeping AR-specific Swift
//   code inside the app binary avoids the iOS 26 plugin-registrar
//   metadata race that bit shared_preferences. ARKit is a small
//   surface anyway; a plugin would be overkill.
//
// Cross-platform note: this is the iOS-only path. Android (ARCore)
// will register an identically-named MethodChannel from MainActivity
// when the android/ scaffold lands. PlatformARPoseProvider on Dart
// side falls back to MockARPoseProvider when neither is registered
// (e.g. simulator, web, HarmonyOS today).

@available(iOS 11.0, *)
class OfficialAetherARKitPlugin: NSObject {
  // MARK: Singleton wiring

  private static var sharedInstance: OfficialAetherARKitPlugin?

  /// Used by OfficialAetherARKitPreviewFactory so the platform view's ARSCNView
  /// can attach to the SAME ARSession the plugin owns — match iOS's
  /// "single ARSession backs both preview and recorder" architecture
  /// from ObjectModeV2ARCaptureCoordinator.
  static func currentSession() -> ARSession? {
    return sharedInstance?.arSession
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    // ⛔ [SPATIAL-CAND 真机判负 2026-07-29] kill switch 恢复。**这次是干净的单变量
    // 实验**,与上午那次被混淆的回滚不同:提取器库已回滚且本次未动、配对数完全
    // 相同、场景密度相近(extract 1156→1267,+10%),唯一变量就是本臂。
    //
    //   臂            帧    逐帧总    extract  GPU每对  配对/帧  gpuM   拍完等待
    //   纯时序 13:11  170   2827ms    1156     79       11.5     6280   209s
    //   几何   15:06  160   5088ms    1267     245      11.5     6965   520s
    //
    // ⇒ 配对数不变、匹配数仅 +11%,而**每对匹配成本 ×3.1**,等待翻倍。
    // 【推断,未证实】几何臂挑"空间近但时间远"的帧,其描述子已不在 GPU 驻留,
    // 每对都要重新上传 8192×128;纯时序挑最近 12 帧,描述子还在。host 构造性
    // 测不到这一维(统一内存 + replay 全程驻留),所以 host A/B 才会显示"零代价"。
    //
    // ⚠️ 被推翻的只是"它是免费的",**不是它的质量收益**:M5 RU / M1 壳厚 /
    // M4 自由空间三把独立尺子在两个 fixture 上的一致改善仍然成立(逐位确定性
    // 重放)。所以这是一笔**质量 vs 采集吞吐的取舍,须用户签决**,不是纯回归。
    // 若要复活:先解决描述子驻留(例如把候选限制在"空间近 AND 时间不太远",
    // 或为老帧做描述子缓存),而不是直接删本行。
    //
    // ✅ [SPATIAL-REVIVE 2026-08-05 用户签决] 复活条件已满足 —— 上面这条注释要求的
    // "为老帧做描述子缓存"**早已实现且编译在产品里**,只是从未启用:
    //   · C++ 侧 DescriptorResidencyPolicyV1(LRU + 字节预算 + 命中/逐出统计)
    //   · Metal 侧 aether_gpu_match_descriptor_residency_{invalidate,clear_session,stats}
    //   · AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1 宏默认 1(已编译)
    //   · 但运行时开关 OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1 默认关,插件从没设过
    // 默认预算 48MB ≈ 48 帧描述子常驻(8192×128 = 1MB/帧),正好覆盖空间序要的
    // "时间远、空间近"的老帧 —— 即当初判死本臂的那条成本(每对重传 8192×128)。
    // 故本次**成对启用**:开驻留 + 放开空间序,单独开任何一个都没有意义。
    //
    // ⚠️ 仍是"质量 vs 采集吞吐"的取舍,且 host 构造性测不到这一维(统一内存 +
    // replay 全程驻留)⇒ **只能真机判**。判据不是肉眼而是驻留命中率(见下方
    // RESIDENCY_STATS 日志):命中率高 ⇒ 上传代价被消掉,可留;命中率低 ⇒ 48MB
    // 不够,调 OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_BYTES 或按注释收窄候选为
    // "空间近 AND 时间不太远"。
    // ⛔ 应急回滚:恢复下面这行 setenv(改回 "1")即刻回到纯时序 K12。
    // [DEVICE-AB-UNBLOCK 2026-08-08] 本块所有 setenv 的 overwrite 一律由 1 改 0。
    // 语义:env 未设时与之前**逐位相同**(这里的值仍是出货默认);env 设了则
    // 启动参数优先。为什么必须这样:今天想在真机上 A/B 一个旋钮(占空比、
    // tail-cache…)时才发现 overwrite=1 让插件永远赢,**启动 env 进不来,
    // 每试一档都要重编装机**——于是一天下来两场真机采集几乎没换到 A/B 价值。
    // 改成 0 之后,同一个二进制就能用 --environment-variables 逐档试。
    setenv("OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY", "0", 0)
    setenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1", "1", 0)
    // [RESIDENCY-BUDGET 2026-08-05] 48MB(默认)→ 400MB。
    // 依据:一帧描述子 8192×128 = 1MB,单次采集硬上限 300 帧
    // (kOfficialMaximumCaptureFrames)⇒ 400MB 足以装下**整场采集的全部**描述子,
    // 是这个用途的理论天花板;再大只是空缓存,不会再提升命中率。
    // 为什么要加:08-05 17:36 实测(空间序+驻留,184 帧)serious 下每帧 5624ms /
    // 匹配 4065ms,而同规模纯时序(08-03,200-201 帧)是 3196-3459ms / 1926-2219ms。
    // 空间序挑"空间近但时间可能很远"的帧,48MB≈48 帧的窗口在 184 帧采集里
    // 大概率装不下 ⇒ 命中率低 ⇒ 仍在重传 8192×128(正是当初判死空间序的那笔成本)。
    // ⚠️ 这是**推断不是实测**:驻留统计符号按 ABI 边界设计不导出
    // (frozen 26-symbol surface),拿不到 hit/miss,只能靠外部效应(匹配耗时/热)判断。
    // ⚠️ 内存天花板 2GB —— 由 **iPhone 11(4GB 机型)** 决定,不是 14 Pro(jetsam 4.1GB)。
    // 当前 peak 约 1058MB,+400MB 仍有余量;若真机 OOM 先回退本行。
    setenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_BYTES", "419430400", 0)  // 400 MiB
    // [K20 2026-08-05] 空间序放开后实测 `cand=12` 仍恒定、`spatial-first=858 /
    // temporal-fallback=0` —— 即**空间选择确实在工作,但 K 被外层截断到 12**:
    // 候选上限 base_k 取自 `s->options.k_neighbors`(Dart 侧传 12),而不是
    // pair_policy_v2 的 `spatial_k=20`。本 env 是覆盖 base_k 的正规旋钮
    // (official_aether_sfm_c.cc `OFFICIAL_AETHER_LIVE_CAND_K`)。
    // ⚠️ 每帧配对 12→20 = 匹配量 +67%,而当前 20-30 帧即 thermal=serious。
    // 若热失控,先回退本行(回到 K12 空间序),而不是关掉空间序本身。
    // ✅ [K20 2026-08-05 启用] 驻留预算 400MB 已实测通过,阻塞条件解除。
    // 实测依据(201 帧同规模对照,`add_frame` 日志):
    //   · 空间序 + 48MB : serious 下每帧 5624ms / 匹配 4065ms,seq=24 即 serious
    //   · 空间序 + 400MB: serious 下每帧 2776ms / 匹配 1762ms,**seq=59** 才 serious
    //   · 纯时序 K12 基线: 每帧 3196-3459ms / 匹配 1926-2219ms,seq=38-39 serious
    //   ⇒ 空间序+足量驻留**比纯时序还快 13-20% 且更晚发热**,当初判死它的
    //     "每对重传 8192×128" 成本已被驻留消掉。
    // 本行把候选上限从 options.k_neighbors(12)解开到 20 —— 注意 pair_policy_v2 的
    // spatial_k 本来就是 20,此前是被外层 base_k 截断,并非空间选择没生效
    // (当时日志已是 spatial-first=858 / temporal-fallback=0)。
    // ⚠️ 每帧匹配量 +67%;按上面的基线 1762ms 粗估约 2900ms,仍优于 48MB 时的 4065ms。
    // ⛔ 若热提前(serious 早于 seq≈40)或匹配超过 3500ms,先回退本行(回到 K12 空间序)。
    // ⛔ [K20 回滚 2026-08-06 用户签决"K10上产"] K20 触发上面自定的回滚线:
    // 未命名6(200帧,cand=22)实测 match 均值 4247ms(>3500ms 线),21 帧超 8s,
    // 深度降频连带 finalize 113s→299s(enrich 3.3×/stage1 2.6×/stage2 1.7× 全线等比,
    // 热因非代码因)。质量侧同场真机匹配图 A/B(断点续跑,3395对 vs 每帧空间10+时间2
    // 的 2156 对):点数 −0.34%、track≥3 −1.8pp、壳带/远点/重投影持平 ⇒ 空间序 K 在
    // 12 对/帧即饱和,K20 的 1239 对增量几乎全是冗余边。删除本行 = 回到默认
    // base_k=12(pair_policy_v2 空间10+时间2),即实验中的"K10臂"。
    // 证据:_artifacts/floater_removal_20260805/(resume_out vs resume_k10_out)。
    // 原行留档:setenv("OFFICIAL_AETHER_LIVE_CAND_K", "20", 1)
    //
    // 以下为装机依据,留档:
    // [SPATIAL-CAND] kill switch 再次删除。
    //
    // 中途曾因真机变慢回滚一次,事后归因证明**与本臂无关**:
    //   • 配对数 1626→1758(几乎不变,与 host 的 1674/1674 一致)——本臂按定义
    //     不改变匹配量,只改变"匹配哪几帧";
    //   • 同次劣化里**特征提取也翻倍**(745→1437ms/帧),而提取跑在候选选择
    //     **之前**,本臂构造性影响不到它;
    //   • 真凶已定位:4c69e07(07-27 21:06)换掉的 GPU 提取器库
    //     libpwsfm_gpu_extract.a。逐目标文件比对:15 个 .o 里只有
    //     dawn_kernel_harness.o(+5320,新增 SetUncapturedErrorCallback /
    //     take_device_error)与 sift_extract_dawn.o(−40)变了,**13 个 WGSL
    //     着色器逐字节相同**。回滚该库后 GPU 每对匹配 226ms → 79ms(基线 78ms),
    //     拍完等待 526s → 209s(且帧数更多)。
    //
    // 装机依据(未被上述事件推翻,均来自逐位确定性重放):
    // [SPATIAL-CAND 2026-07-29] spatial-first 候选选择器装机依据——
    // 2026-07-11 引入时按"host A/B 出数前默认关死"的约定 setenv 了 kill switch,
    // 数已出,三把参考系互不相干的尺子在两个 fixture 上给出同一排序,故删除该行:
    //   M5 RU(参考系=BA 雅可比)   share(RU>10) 70.4→66.8%(cap7)/ 68.8→67.3%(cap3)
    //   M1 壳厚(参考系=局部邻居)  p50@r30mm  3.088→2.928mm / 3.790→3.723mm
    //   M4 自由空间(参考系=相机视线) 违规率@8px 13.96→12.58% / 25.26→23.63%
    // 代价:配对数与基线**完全相同**(1674/1794),GPU 匹配耗时在 A/A2 噪声带内
    // (13518 vs 带 14185-15473)——流式侧不增负载。⚠️ 但 finalize 在 cap3 上
    // +20%(32-34s→41.2s),根因是点数 +5.5%(更多点=更多要平差的量),**非本刀特有**
    // (K30 臂同样 +20%);真机需复核,见 M5_RU_VERDICT_2026-07-29.md。
    // 应急同二进制回滚:setenv("OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY", "1", 1)
    // [K6 RETIRED 2026-07-26, signed] 热调速器(2026-07-11 引入,cap45 冻结
    // 案的权宜之计:thermal serious 时 live 候选 12→6)正式退役——它是为
    // 旧匹配器(热态 325ms/对、monolithic dispatch 挤死相机)定的。三刀
    // (融合 kernel 3×/分块调度/冲刺模式)落地后的 K12 全程验证采集
    // cap_1785070530166049:155 帧、112 serious、cand=12×143、0 rc=7、
    // 0 errInternal、相机不冻、拍完等待持平。native 默认即无降档;此处
    // 不再 setenv。若极端机型需要重新降档,设
    // OFFICIAL_AETHER_LIVE_CAND_K_HOT=6 即同二进制恢复(finalize 补账
    // 链路仍在:armed 时 rematch 优先,见 native ENRICH-ORDER)。
    // [SIGNED 2026-07-26 → ⚰️2026-08-06 用户签决翻案] 旧签"无损+全量 quadratic
    // +预算关死"的前提被三重实测推翻:①enrich 真机 135-220s 而 quadratic
    // 写入=0(cap6 470 次/cap2 281 次尝试全零,长程 gap128 平均 0.7 内点);
    // ②长程覆盖已由选择式通道接管(空间重访+回环选中的 gap64-128 对
    // p50 内点 100-205);③host 双场 A/B 全关 quadratic 质量零差(误差
    // 0.988→0.984 微优,点数 +0.22%)。行业口径(_artifacts/enrich_budget_
    // 20260806/REPORT.md):COLMAP 对长程的正解=检索式挑选而非盲配,
    // 数量预算是压倒性主流。
    // 动作:quadratic 全关(kill switch,native 注释钦定入口);
    // ENRICH_TIME_BUDGET_MS 行删除 ⇒ 回 kAuto(悬垂截断护栏,RTAB-Map 软
    // 语义:只停发新尝试不 abort 进行中)。rematch/空间重访(高价值,
    // 8 次写 2 条 220 内点)不受影响。回滚:删下面一行 + 恢复
    // setenv("OFFICIAL_AETHER_ENRICH_TIME_BUDGET_MS", "0", 1)。
// [GPU-TIMESTAMP 2026-08-08 用户签"把 GPU 时间戳接进这次的装机批次"]
    // 08-08 真机 150 帧实测:匹配耗时随热态爆炸(nominal 454ms → serious 1776ms,
    // 单对 30ms → 134ms),而提取全程平的(1093 → 1007ms)。两个假设的治法完全相反:
    //   排队 —— 每帧 24 次"提交+阻塞等待"排在相机的 GPU 活后面 ⇒ 治法=减少提交次数
    //   降频 —— GPU 时钟真的被压低了       ⇒ 治法=降能耗,减少提交没用
    // CPU 侧墙钟分不出这两者,GPU 侧 kernel 时长可以:时长平=排队,时长涨=降频。
    // 该设施已在树里(official_gpu_timestamp_writer_v1),此前默认关,日志里恒为
    // "timestamp query not requested"。这里开启以取得判据。纯观测,不改算法。
    setenv("OFFICIAL_AETHER_GPU_TIMESTAMPS", "1", 0)
    // [TAIL-CACHE 证据 2026-08-08] tail-cache 已默认开,但它的逐帧证据字段由
    // TailCacheTraceEnabled() 控制,而那个函数在 env **未设置**时返回 false ——
    // 于是出现了"默认开、却没有任何在跑的证据"这个盲区(08-08 这一场就无法确认)。
    // 显式设成 "1" 既保持默认行为,又把 cache_ms / tail_cache / tail_gen 打进 frame_split。
    setenv("OFFICIAL_AETHER_TAIL_CACHE_V1", "1", 0)
    setenv("OFFICIAL_AETHER_QUADRATIC_OVERLAP", "0", 0)
    // [PREPAY-OFF 2026-07-26, signed] 预付回退:cap_1785078141726265 的
    // finalize_split 铁证 enrich_gate_wait_ms=0 —— quadratic 匹配与 stage-1
    // BA 并行且 stage-1 更慢,预付根本不在关键路径上;它偷走采集期空闲
    // (38 对 ≈ 8-15s)换来 finalize 收益 ≈0,代价是 finish 时队列 33 深
    // (前次 15)、排干 95s。native 机制保留,删本行即重新启用。
    setenv("OFFICIAL_AETHER_QUADRATIC_PREPAY", "0", 0)
    // [SPRINT-MODE 2026-07-26] 拍完等待不得增加(用户硬约束)的两条腿之二:
    // 采集期 serious 占空 100%→25%(匹配墙钟 K12 热态 ~1.8s→~1.1s/帧,
    // 跟上 ~2.3s/帧拍摄节奏 → 队列不积压)。让路余量是为旧匹配器(每对
    // GPU 时间 3× 于现在)定的;新 kernel 下 25% 的绝对让路时间与旧 100%
    // 相当。判据:rc=7 仍为 0、相机不冻;失败删本行回 100%。
    // (腿一 = capture-active 冲刺模式,见 startSession/stopSession。)
    // [DUTY-TUNABLE 2026-08-08] overwrite 由 1 改 0:出货默认仍是 25(env 未设时
    // 与之前逐位相同),但**启动时带 env 就能覆盖**,于是这条"提速 vs 相机流畅"
    // 的定价曲线可以同一个二进制逐档试,不必每档重编装机。
    // 为什么现在要复议这个值:07-26 定 25 时的判据是"跟上 ~2.3s/帧拍摄节奏,
    // 队列不积压";08-08 真机 200 帧实测每帧 2832ms、161/200 帧 serious,
    // 该前提已经不成立。实测占空比政策(休眠 25% × 6ms 小块 19%)约值
    // 1.49×,折合 ~97s / 全场 566s = 17%。
    // ⚠️ 它护的是 cap45 那次"相机冻结 2 分钟",放松必须盯相机。
    // [DUTY 25→12 2026-08-08,证据见下] 前人 07-26 定 25 的**判据有两条**:
    //   ① rc=7 仍为 0 —— 今天 692 帧**全部 rc=ok,0 次失败**,安全余量充足
    //   ② 跟上拍摄节奏、队列不积压 —— 今天 343 帧里 **140 帧队列非空,最深 5**,
    //      每帧 2832ms 远超当初假设的 ~2.3s ⇒ **这条判据已经守不住了**
    // 一条判据仍绿、另一条已红,且红的那条正是这个值存在的目的 ⇒ 减半到 12。
    // 不是取消让路(那会退回 cap45 相机冻结的风险),是把让路调到与今天的
    // 匹配器成本相称的档位。同批装的 m_gpu/m_sleep/m_chunks 三分账会给出
    // 实测的"政策 vs 物理"拆分,下一档按实测定,不再按推算。
    // 回退:启动时 --environment-variables 里设 25(overwrite=0,env 优先)。
    setenv("OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT", "12", 0)
    // [SIGNED 2026-07-26] Point authoring = upstream
    // IncrementalMapper::TriangulateImage with two-view tracks kept; the
    // hand-written live create/grow/merge is off (matching and db writes are
    // untouched — the official triangulator consumes exactly those
    // correspondences, and registration stays ARKit-pose-driven).
    // Evidence: seven-arm host A/B on two device dbs plus one on-device
    // capture. Quality is within capture-to-capture variance of the self-dev
    // authoring in both directions (db-10: official wins depth-sigma, fewer
    // points; db-11: official wins points+reproj, self-dev wins sigma), with
    // two stable advantages for official — waste (points created then killed
    // by official filtering) ~10pp lower on both dbs, and track>=3 parity.
    // User signed the switch under the official-first rule: when quality is
    // a wash, ship the upstream algorithm. Delete these three lines to
    // restore the self-dev authoring.
    setenv("OFFICIAL_AETHER_OFFICIAL_TRIANGULATE", "1", 0)
    setenv("OFFICIAL_AETHER_SELFDEV_TRIANGULATE", "0", 0)
    setenv("OFFICIAL_AETHER_TRI_IGNORE_2VIEW", "0", 0)
    // [SCALE-ANCHOR 2026-07-28 用户签决"四端通用,上生产"] 交付模型米制
    // 尺度锚定:BA 后全局 scale 是无锚 gauge 漂移(单目对 scale 严格不可
    // 观测;35 run 实测每采集 ±4~10.6% 系统性偏移),锚回平台 VIO
    // (IMU 米制,四端皆有:ARKit/ARCore/AREngine;LiDAR 仅 iPhone Pro
    // 加分项非依赖)。相似变换严格保重投影残差——质量零扰动,只把"一米"
    // 变回真一米。Dart 侧实现(sfm_live_recon._gravityAlign 链),
    // fail-open:估计失败/|s−1|>15% 即不缩放。裁决档
    // _host_fixtures/pose_drift_audit/SCALE_VERDICT.md;并排对比
    // _host_fixtures/scale_anchor_compare/(用户肉眼批准)。
    setenv("OFFICIAL_AETHER_SCALE_ANCHOR", "1", 0)
    // [AR-EVERY-FRAME 2026-08-05 设备实验臂] 开启后:拍摄期每个被接受的帧
    // 都把当前 previewTracked(实时局部BA点云)推给 AR,让点云每帧可见生长,
    // 而不是只在稀疏的全局BA检查点(~8次)才刷新。Dart 侧默认关(读此 env);
    // 全局BA仍保留(帮 finalize)。host 前提已证 previewTracked 每帧单调增长
    // (Aether3D-cross openspec .../ar-display-decouple-premise-v1.md)。
    // ⛔ 应急回滚:删除此行即恢复稀疏检查点刷新(Dart env 读不到 → 分支不进)。
    setenv("OFFICIAL_AETHER_AR_EVERY_FRAME", "1", 0)
    // [SPLAT-RADIUS 2026-07-28 用户判决] AR 拍摄期**保持原尺寸(6px)**:
    // 放大到 20 会让红/黄/绿 track-length 分层被点径糊掉(用户实机判负,
    // 截图为证),而 AR 期的诉求是"看清覆盖分层"不是"糊成实体面"。
    // 需要"糊成面"的是草稿页预览(Flutter 侧,另行加大)。
    // ⛔ [SPLAT-RADIUS ROLLED BACK 2026-07-29] 12 → 6(恢复 d9f7c83 之前的硬编码值)。
    //
    // 病因定位:遥测里 queue_drain(拍完 → 队列排空)的历史序列把回归窗口卡死了——
    //   07-26 全天 131-156 帧:26s / 48s / 94s / 95s
    //   07-27 00:18  173 帧:106s
    //   07-27 20:34  142 帧:**23s**   ← 最后一次已知正常
    //   07-28 16:52  146 帧:**208s**  ← 回归首次出现(3.5 分钟)
    //   07-29 11:10  153 帧:**451s**  ← 7.5 分钟,外加 finalize 124s
    // 该窗口内共 27 个提交,**只有 d9f7c83(07-28 16:23,本行)碰了采集期渲染路径**;
    // 其余全是选区页/骰子 UI(拍完才跑)与 SCALE-ANCHOR(finalize 期一次相似变换)。
    // 提交 16:23 → 首次变慢采集 16:52,间隔 29 分钟。
    //
    // 机理:点径上限翻倍 = **每点填充面积 4 倍**,且十万级点在采集全程持续绘制。
    // AR 渲染与 SfM 的 GPU 匹配、GPU 特征提取抢同一块 GPU ⇒ 逐帧法医显示
    // GPU 每对 78→172~219ms、GPU 提取 745→1207~1437ms/帧,并因发热连带把
    // CPU 侧的 local BA 拖慢 4.6×。三次采集的**冷启动速度一致**(27/39/28 ms/对),
    // 说明峰值性能未变、变的是持续能力——与"渲染抢 GPU + 热"一致,与代码回归不符。
    //
    // [SIGNED 2026-07-29] 归因结束:本行**不是**变慢的原因(真凶是 4c69e07 换掉的
    // GPU 提取器库,见 register() 顶部)。用户签决:**点径就保持 6,不再动**。
    // ⚠️ 已知代价:P1 饱和色标(kCaptureQualityRamp)当初是与点径 12 **同批**判的,
    // 两者是复刻 RS 分层读感的一对条件。点径停在 6 意味着 AR 分层会偏"椒盐"一侧;
    // 若日后要拿回那份读感,应从"降低 AR 绘制点数/只在低密度区放大"这类不增加
    // 持续 GPU 负载的方向走,而不是简单把上限调回 12。
    setenv("OFFICIAL_AETHER_AR_SPLAT_MAX_PX", "6", 0)
    // Production ends at COLMAP's final global BA + official filtering.
    // Historical RestoreTemporalDetail / repair / enrichment passes are hard
    // disabled in the native translation unit and are not re-enabled here.
    // [2026-07-12] stage1 轮次帽(59555b8d 钩子 P1-STAGE1-RECIPE):stage-1
    // 循环上限 = min(ba_global_max_refinements, 4);未用轮次按余量公式让给
    // stage 2,enrich AUTO 时间闸窗口随 stage-1 提前收口。host 质量中性、
    // device 外推 finalize −17%;下次实拍看 finalize_segments 验真。
    // 删本行即同二进制回退(native 默认 0 = shipped 行为)。
    // [BA-STAGE1-FULL 2026-07-26, signed] CAP 4→2 与 stage-1 全速化(native
    // 默认线程满+USER_INITIATED)绑定:全速轮 ~11s,窗口 ~36s 能塞 3+ 轮,
    // 不钉住 CAP 会让轮分配从 2/3 漂成 4/1(NOISE-BAND,须另行签决=第二
    // 步)。CAP=2 冻结今晚实测的 2/3 分配,使提速严格 EXACT(轮序不变,
    // 线程数已签逐位全等)。预期 phase-2 80.6→~70s;k(全速 stage-1 与
    // enrich 争核膨胀)由本采集的 enrich_ms 直读。第二步(CAP 回 4 放飘
    // 分配,~58s)拿 ba_rounds 遥测的 ftol 早停证据后签决。
    setenv("OFFICIAL_AETHER_STAGE1_ROUNDS_CAP", "2", 0)
    // [E25-C 2026-07-20] 鬼层 mask 产出**已停用**(原 `setenv("OFFICIAL_AETHER_GHOST_MASK","1",1)`
    // 已删)。native 侧 MaybeWriteGhostMask 由该 env 门控(aether_sfm_c.cc 注释:
    // "Env-gated (OFFICIAL_AETHER_GHOST_MASK=1, default OFF)"),不设即回到 shipped 默认关。
    //
    // 连带停止产出:ghost_mask.bin / ghost_mask.json / ghost_view_mask.bin /
    // arbitration_plan.json|bin / arbitration_points.bin,以及 finalize 尾段的
    // 平面拟合+分箱开销。
    //
    // ⚠️ 原注释曾写「渲染门默认关」,但当时 Dart 侧 kGhostMaskViewFilter 实际是
    // **true(开)** —— 注释与代码矛盾了 8 天,是本轮排障被误导的来源之一。
    //
    // 停用理由与 L1 同批(见 sfm_live_recon.dart 的 E25-B 注释):认证管线无
    // 等价物 / parity 参考已丢失 / 零消费者 / 完整机制无公开先例。
    // 回滚:加回 `setenv("OFFICIAL_AETHER_GHOST_MASK", "1", 1)` 一行即可。
    //
    // 📌 研究仓离线分析脚本(E17/E18/TRAILS/DR5/E14 等)依赖这些 sidecar,
    // 但 cap50/cap51 的 device_full_pull_2026-07-17 fixture 里已存有全套历史
    // 数据,可继续跑;产品侧不再产新数据。
    let plugin = OfficialAetherARKitPlugin(messenger: registrar.messenger())
    sharedInstance = plugin
    let factory = OfficialAetherARKitPreviewFactory(getSession: {
      OfficialAetherARKitPlugin.currentSession()
    })
    registrar.register(factory, withId: OfficialARKitIdentifiers.previewView)
    // 遥测 A【session】:App 启动一条(机型/系统/电池/内存/构建时间戳)。
    // register 在 didFinishLaunching 主线程跑,顺手开电池监控。
    OfficialPwNativeTelemetry.shared.logSession()
  }

  // MARK: Photo cards (RealityScan-style anchored capture thumbnails)

  /// Per-card render spec, keyed by anchor name, read by
  /// OfficialAetherARKitPreviewView.renderer(_:didAdd:) when SceneKit hands us the
  /// anchor's node. Static so the preview view (owns the ARSCNView delegate)
  /// and the plugin (adds the anchors) share one source of truth. Anchored at
  /// the capture pose => glued to the world by ARKit, no drift. `height` (meters)
  /// is the card's physical size, sized from the intrinsics to fill the viewport.
  struct PhotoCardSpec {
    let texturePath: String
    let evidencePath: String
    let localCorners: [SCNVector3]  // 4 quad corners [TL,TR,BR,BL] in anchor-local space
    let captureDistance: Float      // camera→card distance at capture
    let worldCentroid: simd_float3  // anchor world position AT PLACEMENT (drift baseline)
    let captureCamPos: simd_float3  // camera world position AT CAPTURE (shrink reference)
  }
  static var photoCardSpecs: [String: PhotoCardSpec] = [:]
  /// 证据 JPEG 路径 → **照片自己的**相机位姿(ARFrame 到手那一刻记下)。
  /// addPhotoCard 用它替代 `session.currentFrame`,见那里的长注释。
  static var photoPoseByEvidencePath: [String: simd_float4x4] = [:]
  // [瞬时快门 2026-07-19] 卡片缩略图解码重试计数:photo43 下 12MP 静照后台
  // 落盘,didAdd 建卡时文件可能还没写完;每 150ms 重试直到落盘(最多~4.5s)。
  static var photoCardThumbRetries: [String: Int] = [:]
  private static var photoCardAnchors: [ARAnchor] = []
  /// 地图还没成熟时先不落世界锚的卡片:名字 → (待落的锚, 相机前距离 z, 记入时刻)。
  /// 见 addPhotoCard 里 worldMappingStatus 那段。渲染器每帧检查,一旦地图转
  /// extending/mapped 就迁移。
  static var photoCardPendingAnchors:
    [String: (anchor: ARAnchor, z: Float, halfX: Float, halfY: Float,
              evidencePath: String, since: CFTimeInterval)] = [:]
  private static var photoCardCounter = 0

  /// T6 — live sparse feature-point overlay toggle. Read by the render loop in
  /// OfficialAetherARKitPreviewView (the separate class that owns the ARSCNView), set via
  /// the `setFeaturePointsVisible` method channel command. Static so the preview
  /// view can read it, mirroring the photoCardSpecs sharing pattern.
  static var featurePointsVisible: Bool = false

  /// RS 复刻显示开关(2026-07-19 用户规格):AR 照片卡片可见性。display-only
  /// ——只隐藏卡片节点,照片/AR 锚点/拍摄记录/SfM 数据全不动;隐藏期间照常
  /// 拍照建卡(生成即隐藏),重开即全量回显。isHidden 在渲染循环逐帧幂等
  /// 套用(见 updateAtTime),与 featurePointsVisible 各自独立、非二选一。
  static var photoCardsVisible: Bool = true

  /// [E24 探针] 会话视频格式模式:"4k"(现行为)| "default43"(留系统默认
  /// 1920×1440 4:3)。startSession 入参设定,格式选择块消费。
  static var videoFormatMode: String = "4k"

  /// T6 v2 — capture-coverage cloud DISPLAY buffer. Per the algorithm-
  /// executor boundary (see ARFrameSaveSpec.dartOwns), ALL coverage policy —
  /// which points exist, how many photos covered each, the red→yellow→green
  /// ramp — lives in Dart (lib/capture/capture_coverage_cloud.dart, shared
  /// across platforms). Native is a dumb display executor: Dart pushes
  /// packed xyz+rgb via the `setCoveragePointCloud` method call whenever
  /// coverage changes (i.e. per shutter), and the preview view's render
  /// loop world-anchors exactly what it was given. Empty buffer ⇒ nothing
  /// rendered (so 0 photos ⇒ 0 dots by construction).
  static let coverageCloudLock = NSLock()
  static var coverageCloudXyz: [Float] = []
  static var coverageCloudRgb: [UInt8] = []
  static var coverageCloudTransform = matrix_identity_float4x4
  static var coverageCloudMetadata = LiveCloudRenderMetadataV1(
    contract: "UNSTAMPED",
    sourceReceiveSequence: 0,
    receiveSequence: 0,
    channelPushSequence: 0,
    source: "unknown",
    publishVersion: 0,
    pointCount: 0,
    receiveEpochMs: 0,
    computeDoneEpochMs: 0
  )
  static var coverageCloudDirty = false

  static func floatArray(_ matrix: simd_float4x4) -> [Float] {
    [
      matrix.columns.0.x, matrix.columns.0.y,
      matrix.columns.0.z, matrix.columns.0.w,
      matrix.columns.1.x, matrix.columns.1.y,
      matrix.columns.1.z, matrix.columns.1.w,
      matrix.columns.2.x, matrix.columns.2.y,
      matrix.columns.2.z, matrix.columns.2.w,
      matrix.columns.3.x, matrix.columns.3.y,
      matrix.columns.3.z, matrix.columns.3.w,
    ]
  }

  static func setCoverageCloudTransform(_ transform: simd_float4x4) {
    coverageCloudLock.lock()
    coverageCloudTransform = transform
    coverageCloudDirty = true
    coverageCloudLock.unlock()
  }

  static func setCoverageCloud(
    xyz: [Float],
    rgb: [UInt8],
    metadata: LiveCloudRenderMetadataV1
  ) {
    coverageCloudLock.lock()
    coverageCloudXyz = xyz
    coverageCloudRgb = rgb
    coverageCloudMetadata = metadata
    coverageCloudDirty = true
    coverageCloudLock.unlock()
  }

  /// Render-thread side: returns the latest buffers iff they changed since
  /// the last take (nil otherwise, so the render loop skips rebuild work).
  static func takeCoverageCloudIfDirty()
    -> (xyz: [Float], rgb: [UInt8], metadata: LiveCloudRenderMetadataV1,
        transform: simd_float4x4)?
  {
    coverageCloudLock.lock()
    defer { coverageCloudLock.unlock() }
    if !coverageCloudDirty { return nil }
    coverageCloudDirty = false
    return (
      coverageCloudXyz,
      coverageCloudRgb,
      coverageCloudMetadata,
      coverageCloudTransform
    )
  }

  // ── Photo-card SfM border states (Dart-owned policy, dumb display) ──
  // 四态边框(用户签决):0=黑(刚拍、SfM 未处理) 1=白(已注册)
  // 2=红(断联,附近补拍) 3=黄(已注册但低视差,换角度补拍)。
  // 判定逻辑 100% 在 Dart(lib/official_capture/photo_card_state.dart)——这里只
  // 存 jpegPath→state 并打 dirty 标志,渲染线程(preview view 的
  // updateAtTime)消费后把颜色刷到边框环 + 背板材质。镜像 coverage
  // cloud 的 lock+dirty 共享模式。
  static let photoCardStateLock = NSLock()
  static var photoCardStates: [String: Int] = [:]  // jpegPath → state
  static var photoCardStatesDirty = false

  static func mergePhotoCardStates(_ update: [String: Int]) {
    photoCardStateLock.lock()
    photoCardStates.merge(update) { _, new in new }
    photoCardStatesDirty = true
    photoCardStateLock.unlock()
  }

  /// Card-add path: current state for a JPEG (0 = pending/black default).
  static func photoCardState(forPath path: String) -> Int {
    photoCardStateLock.lock()
    defer { photoCardStateLock.unlock() }
    return photoCardStates[path] ?? 0
  }

  /// Render-thread side: full merged dict iff anything changed since the
  /// last take (cards added later read the dict via photoCardState(forPath:)
  /// in renderer(_:didAdd:), so consuming the dirty flag here is safe).
  static func takePhotoCardStatesIfDirty() -> [String: Int]? {
    photoCardStateLock.lock()
    defer { photoCardStateLock.unlock() }
    if !photoCardStatesDirty { return nil }
    photoCardStatesDirty = false
    return photoCardStates
  }
  /// RS-style CLOSE anchor depth: the card is placed this many metres in front of
  /// the capture lens (NOT on the subject surface), so it fills the viewport at
  /// capture and shrinks FAST as you pull back (perspective falloff is steep up
  /// close). Smaller = appears closer + shrinks faster. Tunable.
  static let photoCardCloseZ: Float = 0.05
  /// AR photo-card texture is downscaled to this max pixel edge (RS-style: the
  /// floating card is a low-res thumbnail to save GPU memory; the album/pipeline
  /// keep the full-res 4K JPEG). ~96 px → ~0.03 MB/card vs ~33 MB for the full 4K
  /// (deliberately VERY low-res / blurry AR card, RS-style).
  static let photoCardThumbMaxPx = 96

  // MARK: Channels

  private let methodChannel: FlutterMethodChannel
  private let poseEventChannel: FlutterEventChannel
  private let poseStreamHandler = OfficialPoseStreamHandler()

  // MARK: ARKit state

  private var arSession: ARSession?
  private let sessionDelegate = OfficialARSessionForwarder()

  /// `worldOrigin` is the user-locked center of the captured object,
  /// recomputed every broadcast frame from `worldSubjectAnchor.transform`.
  /// `worldYaw` is the camera's bearing at lock time. Subsequent frames'
  /// azimuth = atan2(rel.z, rel.x) − worldYaw, so the dome's az = 0
  /// always corresponds to "where the user was standing at lock".
  private var worldOrigin: simd_float3?
  private var worldYaw: Float = 0

  /// The named `ARAnchor` we install at the locked origin point.
  /// ARKit's contract: this is a fixed real-world point; ARKit tracks
  /// it across world-frame re-alignments (limited→normal recovery,
  /// loop closure) and updates its `transform` accordingly. Reading
  /// the anchor's transform every broadcast frame keeps `worldOrigin`
  /// glued to the real-world point the user locked, regardless of
  /// internal SLAM corrections. WWDC 2018 §610 + Polycam polyform
  /// pattern. We trust ARKit's updates unconditionally; an earlier
  /// 0.5 m drift-rejection threshold got stuck rejecting forever once
  /// ARKit issued a real >0.5 m correction.
  private var worldSubjectAnchor: ARAnchor?

  /// Snapshot of `worldOrigin` at lockOrigin time, kept for the 1 Hz
  /// drift diagnostic in `broadcast`. `simd_distance(currentOrigin,
  /// lockTimeOrigin)` tells us how far ARKit has internally moved the
  /// anchor since we placed it — small drift is normal SLAM refinement,
  /// metres-scale drift means the anchor sits in a feature-poor region
  /// (mid-air with no nearby texture).
  private var lockTimeOrigin: simd_float3?
  private var lockTimeAnchorTransform: simd_float4x4?
  private var lastLoggedAnchorTransform: simd_float4x4?
  private var lastAnchorSeverity: String?
  private var lastDriftLogTime: TimeInterval = 0
  private var lastAnchorV2Transform: simd_float4x4?
  private var lastAnchorV2LogTime: TimeInterval = 0

  /// Last time we computed image-quality metrics from an ARFrame. iOS
  /// `ObjectModeV2ARDomeCoordinator.sampleInterval = 1.0 / 6.0` — we
  /// only run Laplacian + brightness + signature at 6 Hz to keep CPU
  /// cost bounded.
  private var lastQualityComputeTime: TimeInterval = 0
  /// 灰度帧(=自动拍几何判决的节拍)的间隔。
  ///
  /// **默认 1/6 s 不变** —— 这个 6 Hz 抄的是 iOS
  /// `ObjectModeV2ARDomeCoordinator.sampleInterval = 1.0/6.0`,有出处。
  ///
  /// 2026-09-08 实测发现它同时也在**当自动拍的判决节拍**,而那不是它的本职:
  ///   位姿 tick 48.3 Hz,但 **75.9% 因"没有新灰度帧"直接跳过**,
  ///   真正评估到几何只有 **5.1 Hz ⇒ 平均 196 ms 才判一次**。
  ///   用户报"我都已经离开那个位置了才出相框" —— 最坏链:
  ///   等判决 0–196 ms + 被上一张快门挡 0–328 ms + ARKit 126 ms + 相框 54 ms ≈ 700 ms。
  ///   (按快门→黑相框只有 180 ms,不是它。)
  ///
  /// 当年压到 6 Hz 的理由写在下面 qualityQueue 的注释里:1920×1440 上算
  /// Laplacian 要 5–15 ms,放**主线程**会撑爆 16 ms 预算。**但计算早已挪到
  /// 后台队列**,那条理由不再成立 —— 所以这里开一个 env 旋钮,由实测裁决,
  /// 我不自己定新数字:
  ///   OFFICIAL_AETHER_QUALITY_HZ = 6(默认,行为一字不变)/ 12 / 15 / 30 …
  /// 代价看同一个 5 s 窗口的 `quality_window` 遥测(fires/skips/avgMs)
  /// 加上热态与点数,四个数一起裁。
  /// 支持两种写法:
  ///   `12`    固定 12 Hz
  ///   `6,12`  **同一场里交替**,每 5 s 诊断窗口换一次臂
  /// 交替是因为「拍不出完全一样的东西」—— 两场对比不可比,同场交替才可比
  /// (项目规矩:交替 A/B 是唯一合法度量,08-08 提速日总账)。
  /// 两臂看到同一个场景、同一个热态、同一双手,代价三项(avg_compute_ms /
  /// skips / 热态)因此是**场内对照**。
  /// 缺省 [6] ⇒ 行为与改动前一字不差。
  /// 当前生效的判决节拍(Hz)。资源采样器(10 s 一次)把它一起记下来 ——
  /// 2026-09-08 教训:臂周期 5 s、资源采样周期 10 s,**整数倍 ⇒ 每次采样都落在
  /// 同一个相位**,热态/CPU 永远只采到一个臂,分不出来。与其去调周期(还得算
  /// 互质),不如让采样自己带上臂标签:一行,且对任何周期组合都成立。
  /// 初值必须从 arms[0] 取,不能写死 —— `didSet` 不在初始化时触发,写死的话
  /// env 若是 `12,6`,第一个臂会被错报成 6。
  /// 仅诊断用:跨线程读写一个 Double(ARKit 代理队列写、遥测采样线程读),
  /// 不加锁;最坏是某一条采样记错一个臂,不影响任何判决。
  static var currentQualityHz: Double = qualityHzArms[0]
  private static let qualityHzArms: [Double] = {
    guard let raw = getenv("OFFICIAL_AETHER_QUALITY_HZ"),
          let text = String(validatingUTF8: raw) else { return [6.0] }
    let arms = text.split(separator: ",").compactMap { part -> Double? in
      guard let v = Double(part.trimmingCharacters(in: .whitespaces)),
            v.isFinite, v > 0 else { return nil }
      return v
    }
    return arms.isEmpty ? [6.0] : arms
  }()
  /// 当前臂。只在 5 s 诊断窗口收尾处推进(那里同时把该窗口的代价落遥测,
  /// 所以每条 quality_window 记录天然属于且只属于一个臂)。
  private var qualityArmIndex = 0 {
    didSet { OfficialAetherARKitPlugin.currentQualityHz = 1.0 / qualityInterval }
  }
  private var qualityInterval: TimeInterval {
    1.0 / Self.qualityHzArms[qualityArmIndex % Self.qualityHzArms.count]
  }

  /// RealityScan-style capture preview feed. This is intentionally
  /// throttled and decimated: native only reads ARKit's official
  /// rawFeaturePoints and samples camera color; Dart owns voxel hashing,
  /// minimap, quality coloring, and all product policy.
  private var lastPreviewPointPayloadTime: TimeInterval = 0

  /// 自动拍位移阈值的冷启动深度(活体 SfM 云长出来之前的头几秒):屏幕中心
  /// 一束**分级 raycast**,与 lockOrigin 的选点策略同款(estimatedPlane/.any
  /// → existingPlaneInfinite/.horizontal,2.5m 封顶 —— 那套在真机上修过
  /// "深度错了"的战史,见下方 lock 代码的注释)。0.5s 节流;未命中/超封顶
  /// 时保持 -1,Dart 侧读成"没有" —— "不知道"绝不编成一个数
  /// (rawFeaturePoints 中位数撒谎 8 倍的教训,2026-08-24)。
  private var lastCenterRayDepthM: Float = -1
  private var lastCenterRayAt: TimeInterval = 0
  private static let centerRayInterval: TimeInterval = 0.5
  private static let previewPointInterval: TimeInterval = 1.0 / 8.0
  private static let previewPointMaxCount: Int = 220

  /// Serial background queue for the Laplacian / signature compute.
  /// Why: ARSession delivers delegate callbacks on the main thread.
  /// Quality compute on a 1920×1440 pixel buffer was running 5-15 ms
  /// per call at 6 Hz, which combined with Flutter UI work pushed the
  /// per-frame budget over 16 ms. ARKit then queued up 13+ ARFrames
  /// waiting for the delegate, hit its pool limit, and started
  /// dropping/warning. Moving compute to a background queue gets the
  /// per-frame main-thread work down to ~2 ms.
  private let qualityQueue = DispatchQueue(
    label: "com.pocketworld.official.arkit.quality",
    qos: .userInitiated
  )
  /// Latest 128×128 grayscale Y-plane thumbnail from the background
  /// extract. Read & cleared only on the main thread (ARKit delegate
  /// queue) inside `broadcast`, so no lock needed. Stale by 1-3
  /// ARFrames (~17-50 ms). The source timestamp and scaled intrinsics travel
  /// with the bytes; Dart rejects a source older than one 6 Hz quality period.
  ///
  /// All the actual metrics (Laplacian variance, brightness, signature)
  /// derive from this thumbnail in pure Dart — see
  /// lib/quality/quality_compute.dart. Native's job is now ONLY plane
  /// extract + downsample; everything past that is shared code across
  /// the 4 target platforms.
  private var pendingGray128: Data?
  private var pendingGraySourceTimestamp: TimeInterval?
  private var pendingGraySourceFocalX: Double?
  private var pendingGraySourceFocalY: Double?
  /// True iff a quality compute is already in flight; used to skip
  /// firing another one before the previous finishes (defensive — the
  /// timer-based throttle should already prevent overlap, but guards
  /// against pathological CPU stalls where compute > interval).
  private var qualityComputeInFlight: Bool = false

  // ── Diagnostic counters for the off-main-thread quality compute.
  // Aggregated and printed once per 5-second window so we can confirm:
  //   • compute is firing at the expected ~6 Hz (30 per 5s)
  //   • avg elapsed_ms is well under 16 ms (otherwise our budget is
  //     gone again the moment we hop back to main)
  //   • skips=0 (defensive guard never triggers under normal load)
  //   • attached:fires ratio close to 1.0 (quality result actually
  //     reaches the pose payload, isn't getting stranded)
  private var qDiagWindowStart: TimeInterval = 0
  private var qDiagFires: Int = 0
  private var qDiagSkips: Int = 0
  private var qDiagElapsedMsSum: Double = 0
  private var qDiagAttached: Int = 0
  private var qDiagPoseEvents: Int = 0

  // MARK: Latest frame snapshot (Plan G W2 photos-on-disk arch)
  //
  // Replaces the old AVAssetWriter pipeline (deleted 2026-05-16). Plan G
  // is fully local with no .mov upload — DA3 / texrecon / 3DGS all want
  // single RGB photos, not video. We stash one snapshot of the most
  // recent ARFrame (pixel buffer + per-frame ARKit metadata) so when
  // the Dart side admits a frame to a dome cell, `saveCurrentFrameAsJpeg`
  // can encode that snapshot to a `<photosDir>/cell_<i>_slot_<j>.jpg`
  // path with a sibling `.json` carrying extrinsic + intrinsics + sparse
  // anchors. Snapshot is replaced every broadcast tick (~30 Hz); ARC
  // releases the previous CVPixelBuffer so memory stays bounded at one
  // retained 4K buffer (~12 MB).
  //
  // Per-photo .json schema (mirrors the deleted .anchors.jsonl row):
  //   { "version": 1,
  //     "t": double seconds (ARFrame.timestamp),
  //     "image_w": int, "image_h": int,
  //     "extrinsic": [16 floats column-major camera→world],
  //     "intrinsics_fxfycxcy": [4 floats],
  //     "anchors_world": [[x, y, z], ...],
  //     "anchor_ids": [uint64, ...],
  //     "scale_align_premetrics": {...},
  //     "save_target_t": double?, "save_dt": double }
  private struct ScaleAlignPremetrics {
    let anchorDepthCount: Int
    let anchorDepthMinM: Float
    let anchorDepthMaxM: Float
    let anchorDepthSpanM: Float
    let reliabilityPrior: Float
  }

  private struct LatestFrameSnapshot {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
    let extrinsic: [Float]
    let intrinsicsFxFyCxCy: [Float]
    let imageW: Int
    let imageH: Int
    let trackingStateName: String
    let isTracking: Bool
    let anchorsWorld: [[Float]]
    let anchorIds: [UInt64]
    let scaleAlignPremetrics: ScaleAlignPremetrics
  }
  private var lastFrameSnapshot: LatestFrameSnapshot?
  private var recentFrameSnapshots: [LatestFrameSnapshot] = []
  // Keep this intentionally small. Each 4K ARFrame pixel buffer is
  // ~12 MB, and ARKit will warn/freeze if the delegate holds on to too
  // many buffers while ARSCNView is trying to render the live preview.
  // Four frames covers ~130 ms at 30 fps, enough for the Dart method-
  // channel round trip used by timestamp-matched JPEG saves.
  private static let maxRecentFrameSnapshots = 4
  private static let defaultSaveMaxTimestampDelta: TimeInterval = 0.18

  /// Serial off-main queue for JPEG encode + disk write. Keeps the
  /// ARSession delegate (= main thread) free during the ~30-50 ms
  /// CIContext.createCGImage + ImageIO write cost.
  private let jpegEncodeQueue = DispatchQueue(
    label: "com.pocketworld.official.arkit.jpeg",
    qos: .userInitiated
  )

  /// One CIContext shared across all JPEG encodes (creating a fresh one
  /// per encode is several ms of overhead and allocates a GPU command
  /// queue). Lazy because CoreImage init has a non-trivial cost we'd
  /// rather amortize on first save, not at plugin init.
  private lazy var ciContext: CIContext = CIContext(options: nil)

  /// DEDICATED off-main queue for the preview colorizer's per-frame JPEG
  /// decode (`decodeJpegForColor`). Kept SEPARATE from `jpegEncodeQueue`
  /// on purpose: the shutter's own capture encode (`saveCurrentFrameAsJpeg`)
  /// runs on jpegEncodeQueue, and the colorizer decodes N keyframes in a
  /// loop when a background finalize completes. If those decodes ran on the
  /// main thread (they used to, inline) they starved the shutter's channel
  /// reply → `_capturing` stuck true → shutter spinner during background
  /// processing; if they shared jpegEncodeQueue they'd serialize AHEAD of the
  /// shutter's encode instead. A separate `.utility` queue (lower priority
  /// than capture's `.userInitiated`) keeps colorize fully decoupled and
  /// always yielding to capture.
  /// [2026-07-12 colorize 并行化] CONCURRENT(曾是串行):Dart 侧
  /// colorize_pipeline.dart 有界并行发 3 个解码请求,串行队列会把并行度
  /// 吃掉(cap47:121×56ms 串行解码 = 6.8s 的 99%)。in-flight 上限由
  /// Dart 窗口(3)唯一控制 → 最多 3 张 1280px RGB ≈ 11MB 同时在内存;
  /// 解码体是纯 ImageIO + 局部缓冲,无共享可变状态,线程安全。
  private let colorizeQueue = DispatchQueue(
    label: "com.pocketworld.official.arkit.colorize",
    qos: .utility,
    attributes: .concurrent
  )



  // MARK: Init

  private init(messenger: FlutterBinaryMessenger) {
    self.methodChannel = FlutterMethodChannel(
      name: OfficialARKitIdentifiers.methodChannel,
      binaryMessenger: messenger
    )
    self.poseEventChannel = FlutterEventChannel(
      name: OfficialARKitIdentifiers.poseEventChannel,
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    poseEventChannel.setStreamHandler(poseStreamHandler)
    sessionDelegate.onFrame = { [weak self] frame in
      self?.broadcast(frame: frame)
    }
    sessionDelegate.onSessionFailure = {
      PwARCameraLease.shared.release(
        owner: OfficialARKitIdentifiers.cameraOwner
      )
    }
  }

  // MARK: MethodChannel handler

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(ARWorldTrackingConfiguration.isSupported)
    case "startSession":
      guard PwARCameraLease.shared.acquire(
        owner: OfficialARKitIdentifiers.cameraOwner
      ) else {
        result(FlutterError(
          code: "ar_camera_busy",
          message: "The camera is already owned by another capture pipeline",
          details: nil
        ))
        return
      }
      do {
        let resume =
          (call.arguments as? [String: Any])?["resume"] as? Bool ?? false
        // [E24 探针 2026-07-19] videoFormatMode: "4k"(默认,现行为)|
        // "default43"(跳过 4K 覆盖,留系统默认 1920×1440 4:3 —— 测它的
        // out-of-band 静照分辨率与 tracking 健康;dart-define 门控,默认关)。
        // 缺参时保持现值(而非重置 4k):恢复/内部重启路径不得改变用户
        // 会话格式 —— 2026-07-19 切后台重进混内参 bug 的第二道保险。
        OfficialAetherARKitPlugin.videoFormatMode =
          ((call.arguments as? [String: Any])?["videoFormatMode"] as? String)
            ?? OfficialAetherARKitPlugin.videoFormatMode
        guard OfficialAetherARKitPlugin.videoFormatMode == "hires43" else {
          throw NSError(
            domain: "OfficialAetherARKit",
            code: 217,
            userInfo: [NSLocalizedDescriptionKey:
              "Official capture supports only the locked 1920x1440 preview mode"]
          )
        }
        try startSession(resetWorld: !resume)
        result(nil)
      } catch {
        PwARCameraLease.shared.release(
          owner: OfficialARKitIdentifiers.cameraOwner
        )
        result(FlutterError(
          code: "ar_start_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    case "stopSession":
      stopSession()
      result(nil)
    case "lockOrigin":
      let distance: Float
      if let args = call.arguments as? [String: Any],
         let d = (args["distanceMeters"] as? NSNumber)?.floatValue {
        distance = d
      } else {
        distance = 0.5
      }
      let lockResult = lockOrigin(distanceMeters: distance)
      if let payload = lockResult {
        result(payload)
      } else {
        result(FlutterError(
          code: "ar_no_frame",
          message: "ARSession has no current frame to lock against",
          details: nil
        ))
      }
    case "saveCurrentFrameAsJpeg":
      // Plan G W2 photos-on-disk: encode the most-recent ARFrame as JPEG
      // to `jpegPath` and write per-photo metadata JSON to `metadataPath`.
      // Quality defaults to 0.9 (visually lossless JPEG, ~800 KB at 4K).
      // Replaces the older startRecording/stopRecording AVAssetWriter
      // pipeline — Plan G is fully local, no .mov, no cloud upload.
      guard let args = call.arguments as? [String: Any],
            let jpegPath = args["jpegPath"] as? String,
            let metadataPath = args["metadataPath"] as? String else {
        result(FlutterError(
          code: "ar_save_jpeg_bad_args",
          message: "saveCurrentFrameAsJpeg requires {jpegPath: String, metadataPath: String, quality?: Float}",
          details: nil
        ))
        return
      }
      let quality = (args["quality"] as? NSNumber)?.floatValue ?? 0.9
      let targetTimestamp = (args["targetTimestamp"] as? NSNumber)?.doubleValue
      let maxTimestampDelta = (args["maxTimestampDelta"] as? NSNumber)?.doubleValue
        ?? Self.defaultSaveMaxTimestampDelta
      let metadataSchemaVersion = (args["metadataSchemaVersion"] as? NSNumber)?.intValue ?? 1
      let dartSaveContract = args["dartSaveContract"] as? [String: Any]
      let includeSfmFeed = (args["includeSfmFeed"] as? NSNumber)?.boolValue ?? true
      saveCurrentFrameAsJpeg(
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        maxTimestampDelta: maxTimestampDelta,
        quality: quality,
        metadataSchemaVersion: metadataSchemaVersion,
        dartSaveContract: dartSaveContract,
        includeSfmFeed: includeSfmFeed
      ) { payload, error in
        if let error = error {
          result(FlutterError(
            code: "ar_save_jpeg_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          // Reply now carries the frame-exact SfM feed (gray + intrinsics +
          // extrinsic). Dart treats it as optional — absence just skips SfM.
          result(payload)
        }
      }
    case "captureHighResolutionStill":
      guard let args = call.arguments as? [String: Any],
            let highresPath = args["highresPath"] as? String,
            let previewPath = args["previewPath"] as? String else {
        result(FlutterError(
          code: "ar_highres_bad_args",
          message: "captureHighResolutionStill requires {highresPath: String, previewPath: String, quality?: Float}",
          details: nil
        ))
        return
      }
      let quality = (args["quality"] as? NSNumber)?.floatValue ?? 0.92
      let metadataPath = args["metadataPath"] as? String
      let targetTimestamp = (args["triggerTimestamp"] as? NSNumber)?.doubleValue
      let metadataSchemaVersion = (args["metadataSchemaVersion"] as? NSNumber)?.intValue ?? 1
      let dartSaveContract = args["dartSaveContract"] as? [String: Any]
      // [E24 S2] feedSfm: 静照即证据模式 —— 载荷附带全分辨率 SfM 灰度喂图
      // (photo==fed 的 1:1 不变量在 12MP 世界恢复)。
      let feedSfm = (args["feedSfm"] as? NSNumber)?.boolValue ?? false
      let deriveAuxiliary =
        (args["deriveAuxiliary"] as? NSNumber)?.boolValue ?? true
      captureHighResolutionStill(
        highresPath: highresPath,
        previewPath: previewPath,
        quality: quality,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        metadataSchemaVersion: metadataSchemaVersion,
        dartSaveContract: dartSaveContract,
        feedSfm: feedSfm,
        deriveAuxiliary: deriveAuxiliary
      ) { payload, error in
        if let error = error {
          let nsError = error as NSError
          OfficialPwNativeTelemetry.shared.log("highres_capture", [
            "outcome": "error",
            "domain": nsError.domain,
            "code": nsError.code,
            "message": error.localizedDescription,
          ])
          result(FlutterError(
            code: "ar_highres_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          OfficialPwNativeTelemetry.shared.log("highres_capture", [
            "outcome": "ok",
            "request_to_capture_dt":
              (payload?["timestampDelta"] as? NSNumber)?.doubleValue ?? -1,
            "image_w": (payload?["imageWidth"] as? NSNumber)?.intValue ?? 0,
            "image_h": (payload?["imageHeight"] as? NSNumber)?.intValue ?? 0,
          ])
          result(payload)
        }
      }
    case "beginReconUmbrella":
      // Arm the iOS-26 background-continuation umbrella so the SfM finalize
      // survives the user backgrounding the app mid-solve. MUST be invoked
      // from the foreground (the preview is up) — dasd silently drops a submit
      // made from a background state. No-op below iOS 26.
      let args = call.arguments as? [String: Any]
      let jobID = args?["jobId"] as? String ?? "legacy"
      if #available(iOS 26.0, *) {
        OfficialReconUmbrella.shared.begin(jobID: jobID)
      }
      result(nil)
    case "endReconUmbrella":
      // Finalize + persist done — let the umbrella's handler loop complete the
      // grant and cancel any still-pending request. Idempotent.
      let args = call.arguments as? [String: Any]
      let jobID = args?["jobId"] as? String ?? "legacy"
      if #available(iOS 26.0, *) {
        OfficialReconUmbrella.shared.end(jobID: jobID)
      }
      result(nil)
    case "setReconProgress":
      // 案④【灵动岛真实进度】:Dart 在 finalize 阶段边界推 {fraction 0..1,
      // subtitle 阶段文案}。Swift 侧与合成爬行曲线取 max(严格单调、永不
      // 回退,iOS 30s 递增看门狗仍由合成爬行兜底);100% 仍只由
      // endReconUmbrella 置。No-op below iOS 26。
      let args = call.arguments as? [String: Any]
      let fraction = (args?["fraction"] as? NSNumber)?.doubleValue ?? 0
      let subtitle = args?["subtitle"] as? String
      if #available(iOS 26.0, *) {
        OfficialReconUmbrella.shared.setRealProgress(fraction: fraction, subtitle: subtitle)
      }
      result(nil)
    case "decodeJpegForColor":
      // Fast on-device colorizer decode: downscale-decode a saved 4K JPEG via
      // ImageIO (CGImageSourceCreateThumbnailAtIndex) to maxPx on the long
      // edge — never materializes the full frame, so 30-80 ms vs the 1.5-4 s
      // of a pure-Dart full-res decode on a thermal-throttled A16. WITHOUT the
      // EXIF transform: SfM keypoints live in raw sensor (landscape,
      // top-down) pixel space, exactly what the colorizer samples.
      //   Args: { jpegPath: String, maxPx?: Int=1280 }
      //   Returns: { w, h, rgb: Uint8List (3 B/px, row-major top-down) }
      //
      // OFF-MAIN: the colorizer calls this in an N-keyframe loop the moment a
      // BACKGROUND finalize completes. Run inline on the platform main thread,
      // those N synchronous ImageIO decodes (30-80 ms each hot) saturated main
      // and starved the shutter's own channel reply → `_capturing` stuck true →
      // shutter spinner "during background processing" (the reported bug). The
      // decode body is pure ImageIO + memory (no ARSession/UIKit), so it's safe
      // on `colorizeQueue`; only the FlutterResult is marshaled back to main
      // (tiny closure, matches saveCurrentFrameAsJpeg's convention). Capture is
      // never gated by SfM — see CaptureSession.captureSinglePhoto's contract.
      colorizeQueue.async { [weak self] in
        let mainResult: FlutterResult = { value in
          DispatchQueue.main.async { result(value) }
        }
        guard let self = self else { mainResult(nil); return }
        self.handleDecodeJpegForColor(call: call, result: mainResult)
      }
    case "addPhotoCard":
      // Anchor a RealityScan-style photo thumbnail at the CURRENT camera pose
      // (called immediately after a manual capture, so it == the capture pose).
      // The ARAnchor keeps the card glued to the world — no projection, no drift.
      guard let args = call.arguments as? [String: Any],
            let texturePath = args["textureJpegPath"] as? String,
            let evidencePath = args["evidenceJpegPath"] as? String else {
        result(FlutterError(
          code: "bad_args",
          message: "addPhotoCard requires textureJpegPath and evidenceJpegPath",
          details: nil))
        return
      }
      guard let session = arSession,
            let frame = session.currentFrame else {
        result(FlutterError(
          code: "ar_no_frame", message: "addPhotoCard: no current ARFrame",
          details: nil))
        return
      }
      let camera = frame.camera
      // RS MODEL (verified by user against RealityScan): the card appears CLOSE in
      // front of the lens (~photoCardCloseZ, not on the subject surface), filling
      // the viewport at capture, then shrinks FAST as you pull back — because a
      // CLOSE anchor's apparent size falls off steeply with distance (back off 15 cm
      // from 5 cm away → ~4× smaller from perspective alone, ×the (d0/d)^n scale →
      // tiny almost immediately). Close + fast-shrink is ALSO what makes it read as
      // stable: the card becomes a small chip before any VIO drift grows visible.
      // (Replaces the surface raycast, which placed the card far → big & slow to
      // shrink → drift very visible. RS does NOT anchor on the surface.)
      // ══ 用**照片自己的**位姿,不是调用那一刻的实时位姿 ══
      //
      // 2026-09-08 定罪(实测,非猜):此前这里一直取 `session.currentFrame`,
      // 也就是 addPhotoCard **被调用那一刻**相机在哪。可照片是更早曝好的:
      // ARKit 把 ARFrame 交到我们手上要 220–610 ms(实测中位,随热态摆动),
      // 这段时间手一直在动。
      //   相邻照片相机速度 中位 0.135 m/s、p90 0.238 m/s(三场 71 对实测)
      //   × 投递延迟 220–610 ms ⇒ **落点误差 中位 3.0–8.2 cm、p90 5.2–14.5 cm**
      //   而卡片就锚在镜头前 photoCardCloseZ = **5 cm**
      // 误差和锚点距离本身一个量级 —— 这就是用户看到的"第一张漂移"。
      // 第一张最明显:该场首段速度 0.200 m/s(三场最高),且第一张的
      // request_to_capture_dt = 0.25 s(其余典型 0.033),延迟最长。
      //
      // 照片位姿在早信号那一刻(ARFrame 到手)就记下了,这里直接取。
      // 取不到才退回实时位姿(旧行为,不改判)。
      // 投影矩阵仍用**实时**相机:卡片要填满的是预览视口,那是格式常量,
      // 与位姿无关。朝向修正 R 从 ARKit 自己的 viewMatrix 反推,不自己编:
      //   V = viewMatrix(for:.portrait),V⁻¹ = T · R ⇒ R = T⁻¹ · V⁻¹
      let liveT = camera.transform
      let photoT = OfficialAetherARKitPlugin
        .photoPoseByEvidencePath.removeValue(forKey: evidencePath)
      let camT = photoT ?? liveT
      let camPos = simd_make_float3(camT.columns.3)
      OfficialPwNativeTelemetry.shared.log("photocard_pose_source", [
        "source": photoT == nil ? "live_fallback" : "photo_pose",
        "shift_m": Double(simd_length(
          simd_make_float3(camT.columns.3) - simd_make_float3(liveT.columns.3))),
      ])
      let z: Float = Self.photoCardCloseZ
      NSLog("[PHOTOCARD] addPhotoCard close-anchor z=%.3f", z)
      // SCREEN-ALIGNED quad built at depth z (the surface distance): the 4 viewport
      // corners via ARKit's PORTRAIT view+projection matrices. The `.portrait`
      // orientation handles the sensor→screen 90° rotation internally; at depth z
      // the viewport edges (NDC ±1) sit at ±halfX/±halfY in view space (half =
      // z/projectionScale), so the quad EXACTLY fills the viewport at capture
      // regardless of z, and world-anchored on the surface it peels off the lens.
      // [WYSIWYG 第二步 2026-07-19] 卡片视口 = 预览 letterbox 视口。photo43
      // 下 Flutter 把预览 letterbox 成 3:4(满宽、高=宽×4/3、顶底黑边),所以
      // 卡片按这个 3:4 视口算 → 卡片恰好填满预览、且是照片 4:3 画幅,不再是
      // 屏幕形状裁切。4k 回退保持全屏视口。
      let screenSize = UIScreen.main.bounds.size
      let viewportSize: CGSize =
        OfficialAetherARKitPlugin.videoFormatMode == "hires43"
          ? CGSize(width: screenSize.width, height: screenSize.width * 4.0 / 3.0)
          : screenSize
      let proj = camera.projectionMatrix(for: .portrait,
                                         viewportSize: viewportSize,
                                         zNear: 0.001, zFar: 1000)
      let liveInvView = camera.viewMatrix(for: .portrait).inverse
      let orientationR = liveT.inverse * liveInvView   // = R,见上面推导
      let invView = camT * orientationR
      // View space: +X right, +Y up, -Z forward. halfX/halfY 都按同一 3:4
      // 视口投影算 —— 一致(上次坏在 halfX 全屏、halfY 却强设 3:4 错配)。
      let halfX = z / proj.columns.0.x
      let halfY = z / proj.columns.1.y
      NSLog("[PHOTOCARD] addPhotoCard viewport=%.0fx%.0f z=%.2f halfX=%.3f halfY=%.3f",
            viewportSize.width, viewportSize.height, z, halfX, halfY)
      // Screen order TL, TR, BR, BL (matches texUVs in the renderer).
      let viewCornersV: [simd_float4] = [
        simd_float4(-halfX,  halfY, -z, 1),   // TL
        simd_float4( halfX,  halfY, -z, 1),   // TR
        simd_float4( halfX, -halfY, -z, 1),   // BR
        simd_float4(-halfX, -halfY, -z, 1),   // BL
      ]
      let worldCorners: [simd_float3] = viewCornersV.map {
        simd_make_float3(invView * $0)
      }
      let centroid = (worldCorners[0] + worldCorners[1]
                      + worldCorners[2] + worldCorners[3]) / 4
      let localCorners = worldCorners.map {
        SCNVector3($0.x - centroid.x, $0.y - centroid.y, $0.z - centroid.z)
      }
      // Texture orientation + aspect-fill UVs are computed deterministically in
      // the renderer (uprightPortrait + screen-aspect crop); the spec only needs
      // the world-aligned quad corners.
      let cardName = "official_photo_card_\(OfficialAetherARKitPlugin.photoCardCounter)"
      OfficialAetherARKitPlugin.photoCardCounter += 1
      OfficialAetherARKitPlugin.photoCardSpecs[cardName] =
        PhotoCardSpec(texturePath: texturePath,
                      evidencePath: evidencePath,
                      localCorners: localCorners,
                      captureDistance: z, worldCentroid: centroid, captureCamPos: camPos)
      var anchorT = matrix_identity_float4x4
      anchorT.columns.3 = simd_float4(centroid, 1)
      let cardAnchor = ARAnchor(name: cardName, transform: anchorT)
      OfficialAetherARKitPlugin.photoCardAnchors.append(cardAnchor)
      // ══ 地图没成熟就先不落世界锚 ══
      //
      // 2026-09-08 定罪(读代码,非埋点):用户报"第一张漂移、AR 相框消失,
      // 后面正常"。逐条排除后只剩 ARKit 自己移除锚点这一条路 ——
      // Dart 侧零撤卡(30/30 hires_still 全 ok)、官方采集从不调 lockOrigin、
      // startSession 只在页面挂载时跑一次、clearPhotoCards 只在开场调一次。
      // `renderer(didRemove:)` 里那行注释早写着这个症状:
      //   "ANCHOR REMOVED by ARKit ... world-map re-optimization"
      //
      // 为什么偏偏第一张:它是**唯一一张被放进未成熟地图**的卡片。实测该场
      // 会话 11:05:12.5 起、11:05:14.0 跟踪才转 normal、11:05:15.2 就按了第一次
      // 快门 —— 地图只有 1.2 秒。ARKit 随后重优化,先挪锚点(漂移)再丢掉它
      // (消失);后面的卡片进的是成熟地图,所以没事。
      //
      // 我们此前**从未检查过地图成熟度**(全仓 worldMappingStatus 0 处),
      // 而 ARKit 头文件把语义写得很明白:
      //   NotAvailable 地图不可用 / Limited 该位置不建议用于重定位 /
      //   Extending 正在扩展 / Mapped 已充分建图
      // 判据来自 Apple 自己的枚举,不是我编的阈值。
      //
      // **延迟不变**:卡片此刻照样立刻出现,只是先挂在相机上(屏幕空间,
      // 位置就是它在世界里会在的地方 —— 镜头正前方 z 处);地图一转
      // extending/mapped 就迁到世界锚,形态复原。
      let mapStatus = frame.worldMappingStatus
      let mature = (mapStatus == .extending || mapStatus == .mapped)
      OfficialPwNativeTelemetry.shared.log("photocard_anchor_decision", [
        "name": cardName,
        "world_mapping_status": mapStatus.rawValue,
        "deferred": mature ? 0 : 1,
      ])
      if mature {
        session.add(anchor: cardAnchor)
      } else {
        OfficialAetherARKitPlugin.photoCardPendingAnchors[cardName] =
          (anchor: cardAnchor, z: z, halfX: halfX, halfY: halfY,
           evidencePath: evidencePath, since: CACurrentMediaTime())
      }
      result(nil)
    // [AF-SELFHEAL 2026-08-10 用户签] 自动对焦自愈的薄原语(无 UI、无手势,
    // 手动对焦已按用户指示删除)。病灶:失焦死锁 —— 糊掉的低纹理画面既无
    // 相位信号也无反差梯度,连续 AF 收不到"失焦证据"不触发扫描(健身房
    // 跑步机 10s+ 实测);ARKit 又刻意压制对焦频率(对焦呼吸伤 VIO)。
    // 判定循环全在 Dart(持续糊+静止+节流,跨端同式);这里只执行一脚:
    // 中心单次对焦(强制扫描打破死锁)→ 1.2s 后自动回连续。
    case "focusNudge":
      guard #available(iOS 16.0, *),
            let device =
              ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
      else { result(false); return }
      do {
        try device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
          device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isFocusModeSupported(.autoFocus) {
          device.focusMode = .autoFocus
        }
        device.unlockForConfiguration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          guard let d =
                  ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
          else { return }
          do {
            try d.lockForConfiguration()
            if d.isFocusModeSupported(.continuousAutoFocus) {
              d.focusMode = .continuousAutoFocus
            }
            d.unlockForConfiguration()
          } catch {}
        }
        NSLog("[AF-SELFHEAL] center one-shot nudge fired")
        result(true)
      } catch {
        result(false)
      }
    // [ADAPTIVE-FPS 2026-08-10 用户签] 自适应取景帧率的薄执行器。策略全在
    // Dart(热态滞回:fair≥10s→30fps,nominal≥30s→回 60,比苹果自带热降帧
    // 更早出手,把 serious[帧税3.5×]推得更远)。这里走苹果自家热降帧的同一条
    // 低层路:configurableCaptureDevice 会话内调帧间隔 —— 不换格式、不
    // session.run、跟踪不断。区间越界或 API 不可用返回 false(能力申报)。
    case "setPreviewFps":
      guard #available(iOS 16.0, *),
            let args = call.arguments as? [String: Any],
            let fps = args["fps"] as? Int, fps > 0,
            let device =
              ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
      else { result(false); return }
      let supported = device.activeFormat.videoSupportedFrameRateRanges
        .contains { $0.minFrameRate <= Double(fps) &&
                    Double(fps) <= $0.maxFrameRate }
      guard supported else {
        NSLog("[ADAPTIVE-FPS] fps=%d out of active format ranges — refused", fps)
        result(false)
        return
      }
      do {
        try device.lockForConfiguration()
        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = dur
        device.activeVideoMaxFrameDuration = dur
        device.unlockForConfiguration()
        NSLog("[ADAPTIVE-FPS] preview fps set to %d (in-session)", fps)
        result(true)
      } catch {
        NSLog("[ADAPTIVE-FPS] lockForConfiguration failed: \(error)")
        result(false)
      }
    case "clearPhotoCards":
      OfficialAetherARKitPlugin.clearPhotoCards(in: arSession)
      result(nil)
    case "removePhotoCard":
      guard let args = call.arguments as? [String: Any],
            let evidencePath = args["evidenceJpegPath"] as? String else {
        result(FlutterError(
          code: "bad_args",
          message: "removePhotoCard requires evidenceJpegPath",
          details: nil
        ))
        return
      }
      OfficialAetherARKitPlugin.removePhotoCard(
        evidencePath: evidencePath,
        from: arSession
      )
      result(nil)
    case "setPhotoCardStates":
      // Dart-owned four-state border policy pushes {jpegPath: state} DIFFS
      // here (0 black/pending, 1 white/registered, 2 red/disconnected,
      // 3 yellow/low-parallax — see lib/official_capture/photo_card_state.dart).
      // Dumb executor: merge + mark dirty, zero judgement native-side.
      guard let args = call.arguments as? [String: Any],
            let states = args["states"] as? [String: NSNumber] else {
        result(FlutterError(
          code: "photo_card_states_bad_args",
          message: "setPhotoCardStates requires {states: {jpegPath: Int}}",
          details: nil))
        return
      }
      OfficialAetherARKitPlugin.mergePhotoCardStates(states.mapValues { $0.intValue })
      // 遥测 G【cardpush】:记差量条数;渲染线程应用时(>1ms)合并落行。
      OfficialPwNativeTelemetry.shared.noteCardPush(diffCount: states.count)
      result(nil)
    case "setLogicalWorldDisplayTransform":
      guard let args = call.arguments as? [String: Any],
            let raw = args["platformWorldFromLogicalWorld"] as? [NSNumber],
            raw.count == 16 else {
        result(FlutterError(
          code: "logical_world_transform_bad_args",
          message: "setLogicalWorldDisplayTransform requires 16 values",
          details: nil))
        return
      }
      let values = raw.map { $0.floatValue }
      guard values.allSatisfy({ $0.isFinite }) else {
        result(FlutterError(
          code: "logical_world_transform_non_finite",
          message: "display transform values must be finite",
          details: nil))
        return
      }
      let transform = simd_float4x4(columns: (
        simd_float4(values[0], values[1], values[2], values[3]),
        simd_float4(values[4], values[5], values[6], values[7]),
        simd_float4(values[8], values[9], values[10], values[11]),
        simd_float4(values[12], values[13], values[14], values[15])
      ))
      OfficialAetherARKitPlugin.setCoverageCloudTransform(transform)
      result(nil)
    case "setCoveragePointCloud":
      // Dart-owned coverage policy pushes its rendered state here (packed
      // Float32 xyz triplets + Uint8 rgb triplets). Empty arrays clear.
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(
          code: "coverage_cloud_bad_args",
          message: "setCoveragePointCloud requires {xyz: Float32List, rgb: Uint8List}",
          details: nil))
        return
      }
      var xyz: [Float] = []
      if let t = args["xyz"] as? FlutterStandardTypedData {
        xyz = t.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
      }
      var rgb: [UInt8] = []
      if let t = args["rgb"] as? FlutterStandardTypedData {
        rgb = [UInt8](t.data)
      }
      let metadata = LiveCloudRenderMetadataV1(
        contract: args["diagContract"] as? String ?? "UNSTAMPED",
        sourceReceiveSequence:
          (args["diagSourceReceiveSeq"] as? NSNumber)?.intValue ?? 0,
        receiveSequence:
          (args["diagReceiveSeq"] as? NSNumber)?.intValue ?? 0,
        channelPushSequence:
          (args["diagChannelPushSeq"] as? NSNumber)?.intValue ?? 0,
        source: args["diagSource"] as? String ?? "unknown",
        publishVersion:
          (args["diagVersion"] as? NSNumber)?.intValue ?? 0,
        pointCount:
          (args["diagPointCount"] as? NSNumber)?.intValue ?? xyz.count / 3,
        receiveEpochMs:
          (args["diagReceiveEpochMs"] as? NSNumber)?.int64Value ?? 0,
        computeDoneEpochMs:
          (args["diagComputeDoneEpochMs"] as? NSNumber)?.int64Value ?? 0
      )
      OfficialAetherARKitPlugin.setCoverageCloud(
        xyz: xyz,
        rgb: rgb,
        metadata: metadata
      )
      OfficialPwNativeTelemetry.shared.log("live_cloud_native_receive_v2", [
        "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
        "source_receive_seq": metadata.sourceReceiveSequence,
        "receive_seq": metadata.receiveSequence,
        "channel_push_seq": metadata.channelPushSequence,
        "source": metadata.source,
        "publish_version": metadata.publishVersion,
        "declared_points": metadata.pointCount,
        "received_points": xyz.count / 3,
        "observation_only": true,
      ])
      result(nil)
    case "setFeaturePointsVisible":
      let visible =
        ((call.arguments as? [String: Any])?["visible"] as? NSNumber)?.boolValue
          ?? false
      OfficialAetherARKitPlugin.featurePointsVisible = visible
      NSLog("[OfficialAetherARKit] setFeaturePointsVisible=\(visible)")
      result(nil)
    case "setPhotoCardsVisible":
      let visible =
        ((call.arguments as? [String: Any])?["visible"] as? NSNumber)?.boolValue
          ?? true
      OfficialAetherARKitPlugin.photoCardsVisible = visible
      NSLog("[OfficialAetherARKit] setPhotoCardsVisible=\(visible)")
      result(nil)
    case "telemetryCaptureBegin":
      // 遥测 F【resource】:拍摄页进入 → 10s 定时资源采样
      // (thermal/footprint/电池/CPU/SceneKit FPS → telemetry_official_native.jsonl)。
      OfficialPwNativeTelemetry.shared.startResourceSampling()
      OfficialPwNativeTelemetry.shared.logCaptureIdentity()
      // [2026-08-10 签决撤销] 热亮度调速器(原刀②)已删除:拍摄期屏幕保持
      // 用户亮度不变,不随热状态封顶。
      result(nil)
    case "telemetryCaptureEnd":
      // 拍摄页退出(含等待页完成)→ 停采样,收尾补一条。
      OfficialPwNativeTelemetry.shared.stopResourceSampling()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Session lifecycle

  /// Remove all AR photo-card anchors + specs (the SceneKit nodes go via ARKit's
  /// didRemove). The album JPEGs + pose sidecars on disk are NOT touched — only the
  /// in-AR markers. Used on resume (RS behaviour: a resume relocalization shifts the
  /// world frame, so the old cards are unreliable — clear them; the user keeps
  /// capturing and the album keeps every shot).
  static func clearPhotoCards(in session: ARSession?) {
    // 会话开场清一次:photoPoseByEvidencePath 是 static,不清会跨会话累积
    // (每条 64 B,量小,但静默增长的表迟早咬人)。
    photoPoseByEvidencePath.removeAll()
    if let session = session {
      for a in photoCardAnchors { session.remove(anchor: a) }
    }
    photoCardAnchors.removeAll()
    photoCardSpecs.removeAll()
    // 卡片没了,四态边框状态一并清(新一轮拍摄由 Dart 重新推送)。
    photoCardStateLock.lock()
    photoCardStates.removeAll()
    photoCardStatesDirty = false
    photoCardStateLock.unlock()
  }

  static func removePhotoCard(evidencePath: String, from session: ARSession?) {
    let names = Set(
      photoCardSpecs.compactMap { name, spec in
        spec.evidencePath == evidencePath ? name : nil
      }
    )
    guard !names.isEmpty else { return }
    let removedAnchors = photoCardAnchors.filter {
      guard let name = $0.name else { return false }
      return names.contains(name)
    }
    if let session {
      for anchor in removedAnchors { session.remove(anchor: anchor) }
    }
    photoCardAnchors.removeAll {
      guard let name = $0.name else { return false }
      return names.contains(name)
    }
    for name in names {
      photoCardSpecs.removeValue(forKey: name)
      photoCardThumbRetries.removeValue(forKey: name)
    }
  }

  private func startSession(resetWorld: Bool = true) throws {
    NSLog("[OfficialAetherARKit] startSession(resetWorld=\(resetWorld)) — isSupported=\(ARWorldTrackingConfiguration.isSupported)")
    guard ARWorldTrackingConfiguration.isSupported else {
      throw NSError(
        domain: "OfficialAetherARKit",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey:
          "ARWorldTracking not supported on this device"]
      )
    }
    let configuration = ARWorldTrackingConfiguration()
    // Let ARKit drive continuous autofocus. Important: do not later flip the
    // underlying AVCaptureDevice into one-shot focus/locked focus; that can
    // leave the preview stuck at a near lens distance after the user moves.
    configuration.isAutoFocusEnabled = true
    // World alignment "gravity" — Y axis points up in world coords,
    // X/Z plane left arbitrary at session start. This matches the
    // iOS reference's az/el math which assumes Y-up.
    configuration.worldAlignment = .gravity
    // [2026-07-12 热战役刀①,签决] 关 ARKit 光照估计:默认 ON,每帧跑
    // ambient intensity/color temperature 估计(常开 CPU/ISP 税)。全仓
    // grep 核实零消费:无任何 lightEstimate/ARLightEstimate 读点;预览
    // ARSCNView 虽 automaticallyUpdatesLighting=true,但场景内全部材质
    // (点云/photo card 正反面/边框)lightingModel = .constant(unlit),
    // 场景光对渲染零影响,相机背景帧不经场景光照。纯无损,删本行回默认。
    configuration.isLightEstimationEnabled = false
    // Horizontal plane detection — verbatim of
    // ObjectModeV2ARDomeCoordinator.swift line 165. We don't read
    // the detected planes ourselves, but turning detection ON gives
    // ARKit a much stronger signal for gravity alignment (it fits
    // the Y axis to detected floor/table normals). Without it, the
    // Y axis comes from accelerometer alone and can drift a few
    // degrees, which leaks into elevation = atan2(rel.y, horizDist)
    // and makes the dome look "tilted when phone is level".
    //
    // TODO(热战役刀①-b,评估后缓行 2026-07-12):重力锁定(lockOrigin 成功)
    // 后用 session.run(去掉 planeDetection 的新 config) 关平面检测,省常开
    // 平面拟合热。机械上 <30 行可做,但上面的注释写明平面检测是**整段会话
    // 持续**的重力拟合信号(不只锁定前)——锁定后关闭 = 接受后续陀螺/加计
    // 漂移不再被地面法线纠正,有 dome 倾斜回归风险(质量无损是北极星)。
    // 需先真机 A/B 证明锁定后关闭不动 elevation 精度,再走签决启用。
    configuration.planeDetection = [.horizontal]

    // 4K capture when the device supports it AND has enough RAM headroom.
    //
    // Device-tier gating (added Phase 6.4f.x):
    //   • 4 GB RAM phones (iPhone 11, 12, 12 mini): system-default
    //     1920×1440. ProcessInfo.physicalMemory reports ~3.86 GB on
    //     these. 4K AR + 4K H.264 + ARSCNView + ARWorldTracking pushes
    //     them to ~2.1 GB phys_footprint, which is at the iOS foreground
    //     jetsam threshold (~1.7–2.0 GB on 4 GB devices, iOS 14+).
    //     Long captures (60s+) reliably hit OOM at 4K on these.
    //   • 6 GB+ RAM phones (iPhone 12 Pro+, 13+, 14+, 15+): 4K AR.
    //     ProcessInfo.physicalMemory reports ~5.78 GB on 6 GB devices,
    //     ~7.83 GB on 8 GB Pro variants. The 5 GB threshold cleanly
    //     separates the two tiers and is forward-compatible with any
    //     future memory bumps.
    //
    // This same threshold gates Task 3 Phase B (MobileSAM on-device
    // inference, +180 MB peak) — 4 GB devices stay SAM-disabled.
    //
    // 4K capture when the device supports it AND has enough RAM headroom.
    //
    // NOTE (Path B reverted, 2026-06-19): we TRIED
    // `recommendedVideoFormatForHighResolutionFrameCapturing` to unlock the full
    // 12 MP still. On this device / iOS 26 it makes ARWorldTracking NEVER reach
    // .normal — tracking stays notAvailable for 20s+, the continuous frame stream
    // stalls, and the live ARSCNView passthrough FREEZES (out-of-band
    // captureHighResolutionFrame still works, which is why capture looked fine).
    // Empirical negative result: on this hardware "12 MP in-session" and "working
    // world tracking" are mutually exclusive. Stay on the 4K format → ~10 MP 16:9
    // out-of-band stills + a live, trackable session. (48 MP/8K needs leaving
    // ARKit entirely — declined to keep the photo-card flow.)
    //
    // Device-tier gating: 4 GB phones stay on system-default 1920×1440 (4K +
    // H.264 + ARSCNView pushes them to jetsam); 6 GB+ get 4K. Must be set BEFORE
    // session.run; the AVAssetWriter recording path reads
    // configuration.videoFormat.imageResolution.
    let physMemBytes = ProcessInfo.processInfo.physicalMemory
    let physMemGB = Double(physMemBytes) / (1024.0 * 1024.0 * 1024.0)
    let kFourKMemThresholdBytes: UInt64 = 5_000_000_000  // 5.0 GB
    // [E24 探针] default43 模式:跳过 4K 覆盖,留在系统默认格式(1920×1440
    // 4:3,LOW 档设备长期实证 tracking 正常)。与当年实测判死的
    // recommendedVideoFormatForHighResolutionFrameCapturing(见上注释)是
    // 不同的格式条目——本探针专测默认格式的 out-of-band 静照分辨率。
    let allow4K = physMemBytes >= kFourKMemThresholdBytes
      && OfficialAetherARKitPlugin.videoFormatMode != "default43"
      && OfficialAetherARKitPlugin.videoFormatMode != "hires43"
    if OfficialAetherARKitPlugin.videoFormatMode == "default43" {
      NSLog("[OfficialAetherARKit] [E24] videoFormatMode=default43 — skipping 4K override")
    }
    // [E24 探针②] hires43:重验历史判死的高清捕获推荐格式(4032×3024 静照
    // 档)。历史实测(本文件上方注释):iOS 26 下 tracking 永不 .normal。
    // 本模式仅为验证苹果是否已在 26.x 修复;若复现冻结即最终判死 E24。
    if OfficialAetherARKitPlugin.videoFormatMode == "hires43", #available(iOS 16.0, *) {
      let hires = ARWorldTrackingConfiguration.supportedVideoFormats
        .filter {
          Int($0.imageResolution.width) == 1920 &&
          Int($0.imageResolution.height) == 1440 &&
          $0.isRecommendedForHighResolutionFrameCapturing
        }
        .max { $0.framesPerSecond < $1.framesPerSecond }
      guard let hires else {
        throw NSError(
          domain: "OfficialAetherARKit",
          code: 215,
          userInfo: [NSLocalizedDescriptionKey:
            "Official capture requires a high-resolution-capable 1920x1440 AR preview format"]
        )
      }
      configuration.videoFormat = hires
      NSLog("[OfficialAetherARKit] hires43 locked preview: \(hires.imageResolution) @ \(hires.framesPerSecond) fps")
    }
    if #available(iOS 16.0, *), allow4K {
      if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
        configuration.videoFormat = fourK
        NSLog("[OfficialAetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM), using 4K videoFormat: \(fourK.imageResolution) @ \(fourK.framesPerSecond) fps")
      } else {
        NSLog("[OfficialAetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM) but recommendedVideoFormatFor4KResolution returned nil; using system default \(configuration.videoFormat.imageResolution)")
      }
    } else {
      let res = configuration.videoFormat.imageResolution
      NSLog("[OfficialAetherARKit] device tier LOW (\(String(format: "%.2f", physMemGB)) GB RAM), staying on default videoFormat \(res) to avoid 4K jetsam risk")
    }

    // [热税刀② 2026-08-10 实验臂 OFFICIAL_AETHER_AR_30FPS=1,默认不存在=
    // 零变化] 取景流 60→30fps:同分辨率、半帧率。取景流不进重建(重建只吃
    // 快门 12MP 静照),砍的是传感器/ISP/ARKit 每秒一半的纯功耗 —— 目标是
    // 推迟/避免 thermal serious(该态下每帧处理慢 3.5×)。风险靶=ARKit 位姿
    // 质量(VIO 吃这条流),真机 A/B 判据:位姿轨迹/交付质量/热态时间线。
    if ProcessInfo.processInfo.environment["OFFICIAL_AETHER_AR_30FPS"] == "1",
       #available(iOS 16.0, *) {
      // ⚠️ [2026-08-10 首测踩坑] 同分辨率同帧率的格式条目有"支持/不支持
      // 高清静照"两个版本,菜单里不支持版排前面 —— 首版 .first 抓错,
      // 12MP 快门 6 连败("有一张高分辨率照片未完成"横幅)。必须保持
      // isRecommendedForHighResolutionFrameCapturing 与基线一致。
      let want = configuration.videoFormat.imageResolution
      let needHires =
        configuration.videoFormat.isRecommendedForHighResolutionFrameCapturing
      let half = ARWorldTrackingConfiguration.supportedVideoFormats
        .filter {
          $0.imageResolution == want && $0.framesPerSecond == 30 &&
          $0.isRecommendedForHighResolutionFrameCapturing == needHires
        }
        .first
      if let half {
        configuration.videoFormat = half
        NSLog("[OfficialAetherARKit] [AR-30FPS] locked \(half.imageResolution) @ 30 fps (hires=\(needHires))")
      } else {
        NSLog("[OfficialAetherARKit] [AR-30FPS] no matching 30fps format at \(want) hires=\(needHires) — staying at \(configuration.videoFormat.framesPerSecond) fps")
      }
    }

    // [E24 探针] 真实格式菜单落盘(ground truth,每次会话覆写):设备实际
    // supportedVideoFormats + 本次选中格式 + 模式。供跨端/格式决策引用,
    // 不再背菜单。
    do {
      var rows: [[String: Any]] = []
      for f in ARWorldTrackingConfiguration.supportedVideoFormats {
        var row: [String: Any] = [
          "width": Int(f.imageResolution.width),
          "height": Int(f.imageResolution.height),
          "fps": f.framesPerSecond,
        ]
        if #available(iOS 16.0, *) {
          row["recommendedForHighResCapture"] =
            f.isRecommendedForHighResolutionFrameCapturing
        }
        rows.append(row)
      }
      var dump: [String: Any] = [
        "mode": OfficialAetherARKitPlugin.videoFormatMode,
        "chosenWidth": Int(configuration.videoFormat.imageResolution.width),
        "chosenHeight": Int(configuration.videoFormat.imageResolution.height),
        "chosenFps": configuration.videoFormat.framesPerSecond,
        "formats": rows,
      ]
      // [ADAPTIVE-FPS 探针 2026-08-10] 选中格式底层 AVFormat 的帧率区间 ——
      // 决定"会话内调帧间隔"(苹果自家热降帧的低层路)是否可行。
      if #available(iOS 16.0, *),
         let dev = ARWorldTrackingConfiguration
           .configurableCaptureDeviceForPrimaryCamera {
        dump["activeFormatFpsRanges"] =
          dev.activeFormat.videoSupportedFrameRateRanges.map {
            ["min": $0.minFrameRate, "max": $0.maxFrameRate]
          }
      }
      let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
      let data = try JSONSerialization.data(
        withJSONObject: dump, options: [.prettyPrinted])
      try data.write(to: docs.appendingPathComponent("official_ar_video_formats.json"))
    } catch {
      NSLog("[OfficialAetherARKit] [E24] formats dump failed: \(error)")
    }

    let session = arSession ?? ARSession()
    // Preserve XRSLAM's single ordered camera/IMU ingress without putting the
    // production AR frame callback on Flutter's UI/main shutter-control path.
    session.delegateQueue = PwVioSensorIngress.dispatchQueue
    session.delegate = sessionDelegate
    if resetWorld {
      // Fresh start: clean reference frame, drop all anchors + the locked origin.
      session.run(configuration,
                  options: [.resetTracking, .removeExistingAnchors])
    } else {
      // RESUME after a transient background: keep the world map (no reset), BUT
      // clear the AR photo cards. ARKit relocalizes on resume and re-aligns the
      // world frame, which shifts all anchors together ("4 cards moved as one").
      // RS handles this by dropping the in-AR markers on resume while KEEPING the
      // album JPEGs + pose sidecars on disk — user just keeps capturing. Match it.
      session.run(configuration)
      OfficialAetherARKitPlugin.clearPhotoCards(in: session)
    }
    arSession = session
    // Resume only an already-configured xrslam shadow. This is native sensor
    // glue; pose comparison and quality decisions remain in shared Dart code.
    PwVioTimebase.shared.resumeShadowPipeline()
    // [SPRINT-MODE 2026-07-26] Camera is live again → matcher back to
    // yield-to-camera pacing (thermal duty gaps + small hot chunks).
    aether_gpu_match_set_capture_active(1)
    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(
        reason: resetWorld ? "session start" : "session resume")
    }
    if resetWorld {
      worldOrigin = nil
      worldYaw = 0
      worldSubjectAnchor = nil
      lockTimeOrigin = nil
      lockTimeAnchorTransform = nil
      lastLoggedAnchorTransform = nil
      lastAnchorSeverity = nil
      lastAnchorV2Transform = nil
    }
    lastDriftLogTime = 0
    lastAnchorV2LogTime = 0
    lastFrameSnapshot = nil
    recentFrameSnapshots.removeAll()
  }

  private func stopSession() {
    PwVioTimebase.shared.suspendShadowPipeline()
    defer {
      PwARCameraLease.shared.release(
        owner: OfficialARKitIdentifiers.cameraOwner
      )
    }
    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(reason: "session stop")
    }
    if let anchor = worldSubjectAnchor {
      arSession?.remove(anchor: anchor)
    }
    // 案③:主动停 → 帧停是预期,解除 stall 看门狗(下一帧到达自动重武装)。
    sessionDelegate.disarmStallWatchdog()
    arSession?.pause()
    // [SPRINT-MODE 2026-07-26] Camera stopped → nothing to yield to. The
    // queued-frame drain + finalize enrichment (full quadratic) now run at
    // full matcher speed: duty gaps off, cool-size chunks. Pure scheduling,
    // match set bit-identical; this is what keeps "全程 K12 + 全量
    // quadratic" from ADDING post-capture wait.
    aether_gpu_match_set_capture_active(0)
    worldOrigin = nil
    worldYaw = 0
    worldSubjectAnchor = nil
    lockTimeOrigin = nil
    lockTimeAnchorTransform = nil
    lastLoggedAnchorTransform = nil
    lastAnchorSeverity = nil
    lastDriftLogTime = 0
    lastAnchorV2Transform = nil
    lastAnchorV2LogTime = 0
    lastFrameSnapshot = nil
    recentFrameSnapshots.removeAll()
  }

  // MARK: Lock origin (verbatim port of lockAtCameraForward)

  /// Places the world origin at `distanceMeters` ahead of the camera's
  /// current optical axis, captures the camera's bearing as worldYaw.
  /// Returns the dictionary that becomes the Dart-side response.
  /// The phone-orientation classification (portrait vs landscape) is
  /// done on the Dart side by `PhoneOrientationClassifier` so the
  /// algorithm stays cross-platform.
  ///
  /// Returns nil when ARKit's tracking state hasn't reached `.normal`
  /// — the first few ARFrames typically arrive under `.notAvailable`
  /// / `.limited` with an identity-ish transform, and locking against
  /// one of those produces a bogus origin / worldYaw. The Dart-side
  /// retry loop in `CaptureSession._lockOriginWhenReady` keeps
  /// polling every 100 ms until tracking stabilises.
  private func lockOrigin(distanceMeters: Float) -> [String: Any]? {
    guard let frame = arSession?.currentFrame else {
      NSLog("[OfficialAetherARKit] lockOrigin: no currentFrame yet")
      return nil
    }
    switch frame.camera.trackingState {
    case .normal:
      break
    case .limited(let reason):
      NSLog("[OfficialAetherARKit] lockOrigin: tracking is .limited(\(reason)) — retrying")
      return nil
    case .notAvailable:
      NSLog("[OfficialAetherARKit] lockOrigin: tracking .notAvailable — retrying")
      return nil
    @unknown default:
      NSLog("[OfficialAetherARKit] lockOrigin: unknown trackingState — retrying")
      return nil
    }
    let t = frame.camera.transform
    let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    // Forward = camera's optical axis (-Z column of the camera
    // transform). Lock targets whatever's at the center of the screen.
    // Y component is preserved on purpose: lock-time tilt is what makes
    // "shoot the object from 45° above → dome shows the +45° cell"
    // work without any extra orientation math.
    let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)

    // Pick the lock POSITION via a tiered raycast strategy:
    //
    //   1. `.estimatedPlane / .any` — ARKit fits a virtual plane to
    //      nearby feature points along the gaze direction, regardless
    //      of orientation. Hits upright surfaces (a paper bag's side,
    //      a chair's back, a figurine) where no detected horizontal
    //      plane exists. This is what fixes the "depth wrong" symptom
    //      where `.existingPlaneInfinite, .horizontal` silently
    //      sailed past the subject and hit the floor 0.47 m in front
    //      of the user instead of the actual subject.
    //   2. `.existingPlaneInfinite, .horizontal` — fallback for the
    //      case where ARKit hasn't accumulated enough feature points
    //      to estimate a plane yet, but has detected a real horizontal
    //      surface. Same behavior as before.
    //   3. forward × distanceMeters — final mid-air fallback if
    //      neither raycast lands.
    //
    // Cap=2.5 m: subjects beyond that are usually mis-aimed (raycast
    // sails past intended subject); fall back to forward × distance
    // so the anchor stays close enough to ARKit's feature cloud for
    // stable tracking.
    let subjectAnchorMaxRange: Float = 2.5
    var origin: simd_float3
    var positionSource: String
    if let session = arSession {
      var hits: [ARRaycastResult] = []
      var raycastSource: String = ""
      if #available(iOS 13.0, *) {
        let estimateQuery = ARRaycastQuery(
          origin: camPos,
          direction: simd_normalize(forward),
          allowing: .estimatedPlane,
          alignment: .any
        )
        hits = session.raycast(estimateQuery)
        if !hits.isEmpty { raycastSource = "estimated plane" }
      }
      if hits.isEmpty {
        let infQuery = ARRaycastQuery(
          origin: camPos,
          direction: simd_normalize(forward),
          allowing: .existingPlaneInfinite,
          alignment: .horizontal
        )
        hits = session.raycast(infQuery)
        if !hits.isEmpty { raycastSource = "existing horizontal plane" }
      }
      if let hit = hits.first {
        let hitPos = simd_float3(
          hit.worldTransform.columns.3.x,
          hit.worldTransform.columns.3.y,
          hit.worldTransform.columns.3.z
        )
        let hitDistance = simd_distance(camPos, hitPos)
        if hitDistance <= subjectAnchorMaxRange {
          origin = hitPos
          positionSource = "\(raycastSource) (\(String(format: "%.2f", hitDistance)) m)"
        } else {
          origin = camPos + simd_normalize(forward) * distanceMeters
          positionSource = "forward fallback (\(raycastSource) hit \(String(format: "%.2f", hitDistance)) m > cap \(subjectAnchorMaxRange) m)"
        }
      } else {
        origin = camPos + simd_normalize(forward) * distanceMeters
        positionSource = "forward fallback (no raycast hit)"
      }
    } else {
      origin = camPos + simd_normalize(forward) * distanceMeters
      positionSource = "forward fallback (no session)"
    }

    // Drop any previous subject anchor — a fresh lock means we're
    // starting over.
    if let oldAnchor = worldSubjectAnchor, let session = arSession {
      session.remove(anchor: oldAnchor)
      worldSubjectAnchor = nil
    }
    lockTimeAnchorTransform = nil
    lastLoggedAnchorTransform = nil
    lastAnchorSeverity = nil
    lastAnchorV2Transform = nil
    lastAnchorV2LogTime = 0

    // Install a single named ARAnchor at the chosen origin. ARKit
    // tracks its transform across world-frame re-alignments;
    // broadcast() re-reads it every frame to update worldOrigin in
    // lock-step. WWDC 2018 §610 + Polycam polyform pattern — the
    // canonical ARKit-correct way to pin a real-world point.
    if let session = arSession {
      var transform = matrix_identity_float4x4
      transform.columns.3 = simd_float4(origin.x, origin.y, origin.z, 1)
      let anchor = ARAnchor(name: "pocketworld_official_subject_origin",
                            transform: transform)
      session.add(anchor: anchor)
      worldSubjectAnchor = anchor
      lockTimeAnchorTransform = transform
      lastLoggedAnchorTransform = nil
      lastAnchorSeverity = nil
      lastAnchorV2Transform = nil
    }

    // worldYaw = "camera's relative bearing at lock". Subsequent
    // frames' azimuth subtracts this so the dome's az=0 ↔ lock pose.
    let relInitial = camPos - origin
    let yaw = atan2(relInitial.z, relInitial.x)

    worldOrigin = origin
    worldYaw = yaw
    lockTimeOrigin = origin
    lastDriftLogTime = 0  // force first drift log on next broadcast
    lastAnchorV2LogTime = 0
    logAnchorObservationV2(
      frameTimestamp: frame.timestamp,
      trackingStateName: "normal",
      currentTransform: lockTimeAnchorTransform,
      anchorState: "locked"
    )

    NSLog("[OfficialAetherARKit] lockOrigin: SUCCESS via \(positionSource) at "
      + "(\(origin.x), \(origin.y), \(origin.z))")

    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(reason: "subject lock")
    }

    return [
      "originX": origin.x,
      "originY": origin.y,
      "originZ": origin.z,
      "worldYaw": yaw,
      "anchorTransform": Self.floatArray(
        lockTimeAnchorTransform ?? matrix_identity_float4x4
      ),
    ]
  }

  // MARK: AVCaptureDevice exposure/focus safety
  //
  // Real-device note 2026-05-22: forcing capture-during focus/exposure on the
  // underlying AVCaptureDevice caused two bad behaviors on iPhone 14 Pro:
  //   • one-shot exposure could blow the preview white for several seconds;
  //   • one-shot/locked focus could stick at a near lens distance, so distant
  //     surfaces looked permanently blurred until the app restarted.
  //
  // For AR capture, the robust behavior is to keep ARKit's continuous camera
  // control alive. Subject lock only fixes the AR world anchor; it does not
  // lock the physical lens or exposure.
  //
  // configurableCaptureDeviceForPrimaryCamera is iOS 16+; deploy
  // target covers all iPhones that support iOS 16 (iPhone 11+).
  @available(iOS 16.0, *)
  private func restoreContinuousExposureFocus(reason: String) {
    // `configurableCaptureDeviceForPrimaryCamera` is a CLASS property on
    // `ARWorldTrackingConfiguration` (iOS 16+), NOT an instance property
    // on ARSession. ARKit currently exposes the primary camera's
    // AVCaptureDevice via the config class for any running session.
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
      NSLog("[OfficialAetherARKit] camera auto restore skipped (\(reason)): configurableCaptureDeviceForPrimaryCamera is nil")
      return
    }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if device.isSmoothAutoFocusSupported {
        device.isSmoothAutoFocusEnabled = true
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      NSLog("[OfficialAetherARKit] camera auto restored (\(reason)): continuous exposure+focus")
    } catch {
      NSLog("[OfficialAetherARKit] camera auto restore failed (\(reason)): \(error)")
    }
  }

  // MARK: Save current frame as JPEG (Plan G W2 photos-on-disk arch)
  //
  // Called by Dart's CaptureSession when a dome cell admits a frame:
  // encode the most-recent ARFrame's pixel buffer to `<photosDir>/
  // cell_<i>_slot_<j>.jpg` and write per-photo metadata JSON to a
  // sibling `.json`. Eviction overwrites both files at the same path.
  //
  // Why on a dedicated background queue: the ImageIO encode of a 4K
  // BGRA pixel buffer to JPEG q=0.9 takes ~30-50 ms on iPhone 14 Pro.
  // Doing it on main thread would block the next pose tick. Doing it
  // on the AR delegate's queue (also main) starves ARKit. The
  // `jpegEncodeQueue` is dedicated and won't fight either.
  //
  // The snapshot is captured by VALUE (struct copy retains the
  // CVPixelBuffer via ARC), so even if `lastFrameSnapshot` is
  // overwritten by the next broadcast() during the encode, the closure
  // holds the older snapshot until done. No race.
  private func selectFrameSnapshot(
    targetTimestamp: TimeInterval?,
    maxTimestampDelta: TimeInterval
  ) -> (
    snapshot: LatestFrameSnapshot?,
    delta: TimeInterval?,
    errorMessage: String?
  ) {
    guard let targetTimestamp else {
      return (lastFrameSnapshot, nil, nil)
    }
    guard !recentFrameSnapshots.isEmpty else {
      return (nil, nil, "saveCurrentFrameAsJpeg: no ARFrame snapshots buffered")
    }
    var best: LatestFrameSnapshot?
    var bestDelta = TimeInterval.greatestFiniteMagnitude
    for snap in recentFrameSnapshots {
      let delta = abs(snap.timestamp - targetTimestamp)
      if delta < bestDelta {
        best = snap
        bestDelta = delta
      }
    }
    if let best, bestDelta <= maxTimestampDelta {
      return (best, bestDelta, nil)
    }
    return (
      nil,
      bestDelta,
      String(
        format: "saveCurrentFrameAsJpeg: nearest ARFrame is %.3fs from target %.6f, over max %.3fs",
        bestDelta,
        targetTimestamp,
        maxTimestampDelta
      )
    )
  }

  private func saveCurrentFrameAsJpeg(
    jpegPath: String,
    metadataPath: String,
    targetTimestamp: TimeInterval?,
    maxTimestampDelta: TimeInterval,
    quality: Float,
    metadataSchemaVersion: Int = 1,
    dartSaveContract: [String: Any]? = nil,
    includeSfmFeed: Bool = true,
    completion: @escaping ([String: Any]?, Error?) -> Void
  ) {
    let selection = selectFrameSnapshot(
      targetTimestamp: targetTimestamp,
      maxTimestampDelta: maxTimestampDelta
    )
    guard let snap = selection.snapshot else {
      completion(nil, NSError(
        domain: "OfficialAetherARKit", code: 200,
        userInfo: [NSLocalizedDescriptionKey:
          selection.errorMessage ?? "saveCurrentFrameAsJpeg: no ARFrame yet — call after lockOrigin"]
      ))
      return
    }
    jpegEncodeQueue.async { [snap, ciContext = self.ciContext] in
      do {
        // Ensure parent dir exists (cheap noop after first frame).
        let parent = (jpegPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
          atPath: parent, withIntermediateDirectories: true
        )
        try Self.encodeCVPixelBufferAsJpeg(
          snap.pixelBuffer,
          to: URL(fileURLWithPath: jpegPath),
          quality: CGFloat(quality),
          ciContext: ciContext
        )
        // Per-photo metadata JSON. Cell admission decides whether the
        // sample is worth retaining; we attach all the per-frame ARKit
        // ground truth a downstream W3 / texrecon consumer will need.
        var metadata: [String: Any] = [
          "version": metadataSchemaVersion,
          "native_role": "thin_arkit_frame_executor",
          "t": snap.timestamp,
          "image_w": snap.imageW,
          "image_h": snap.imageH,
          "extrinsic": snap.extrinsic,
          "intrinsics_fxfycxcy": snap.intrinsicsFxFyCxCy,
          "trackingStateName": snap.trackingStateName,
          "tracking_state": snap.trackingStateName,
          "is_tracking": snap.isTracking,
          "anchors_world": snap.anchorsWorld,
          "anchor_ids": snap.anchorIds.map { NSNumber(value: $0) },
          "scale_align_premetrics": [
            "anchor_depth_count": snap.scaleAlignPremetrics.anchorDepthCount,
            "anchor_depth_min_m": snap.scaleAlignPremetrics.anchorDepthMinM,
            "anchor_depth_max_m": snap.scaleAlignPremetrics.anchorDepthMaxM,
            "anchor_depth_span_m": snap.scaleAlignPremetrics.anchorDepthSpanM,
            "reliability_prior": snap.scaleAlignPremetrics.reliabilityPrior,
          ],
          "save_dt": selection.delta ?? 0.0,
        ]
        if let dartSaveContract {
          metadata["dart_save_contract"] = dartSaveContract
        }
        if let targetTimestamp {
          metadata["save_target_t"] = targetTimestamp
        }
        let json = try PWJSONSafety.data(withJSONObject: metadata)
        try json.write(to: URL(fileURLWithPath: metadataPath))
        // Streaming-SfM feed: attach an aspect-preserving grayscale of the
        // SAME snapshot (so intrinsics/extrinsic below are frame-exact) for
        // `aether_sfm_add_frame`. Best-effort — a nil gray just means the
        // Dart side skips feeding this frame; the JPEG save already
        // succeeded and is authoritative.
        var payload: [String: Any] = [
          "t": snap.timestamp,
          "image_w": snap.imageW,
          "image_h": snap.imageH,
          "intrinsics_fxfycxcy": snap.intrinsicsFxFyCxCy,
          "extrinsic": snap.extrinsic,
        ]
        if includeSfmFeed, let g = Self.extractGrayAspect(
          snap.pixelBuffer, maxSide: Self.sfmFeedMaxSide
        ) {
          payload["sfm_gray"] = FlutterStandardTypedData(bytes: g.data)
          payload["sfm_gray_w"] = g.width
          payload["sfm_gray_h"] = g.height
        }
        DispatchQueue.main.async { completion(payload, nil) }
      } catch {
        DispatchQueue.main.async { completion(nil, error) }
      }
    }
  }

  /// 当前进程 phys_footprint(MB)—— jetsam 实际盯的那个数。读法逐字照搬
  /// AetherTexturePlugin 已验证的 TASK_VM_INFO 口径;失败返回 -1(调用方
  /// 据此不刹车,宁可放行也不因读数失败误伤拍照)。
  static func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reb, &count)
      }
    }
    return (kr == KERN_SUCCESS) ? Double(info.phys_footprint) / 1_048_576.0 : -1.0
  }

  /// 取 ARKit 自己的 defaultPhotoSettings;env 给了档位就覆盖,没给就原样返回
  /// (⇒ 默认行为与旧的无参数调用等价)。顺带把解析结果打进日志 —— ARKit
  /// 默认是哪一档我们从来没看过,这是第一手观测。
  ///
  /// AVCapturePhotoSettings 实例不可复用,每次拍照都要新取一个;
  /// `defaultPhotoSettings` 的 getter 每次返回新实例,正合用。
  @available(iOS 26.0, *)
  private static func resolveHighResPhotoSettings(
    session: ARSession
  ) -> AVCapturePhotoSettings? {
    guard let format = session.configuration?.videoFormat else { return nil }
    let settings = format.defaultPhotoSettings
    // env 用 getenv 直读:Swift 的 ProcessInfo.environment 是进程启动快照,
    // 读不到 official_env.json 经 setenv 写进来的值(08-05 实测踩过同一个坑)。
    var arm = "default"
    if let raw = getenv("OFFICIAL_AETHER_PHOTO_QUALITY"),
       let v = String(validatingUTF8: raw)?.lowercased(), !v.isEmpty {
      switch v {
      case "speed":
        settings.photoQualityPrioritization = .speed; arm = "speed"
      case "balanced":
        settings.photoQualityPrioritization = .balanced; arm = "balanced"
      case "quality":
        settings.photoQualityPrioritization = .quality; arm = "quality"
      default:
        arm = "default(bad env \(v))"
      }
    }
    let dims = settings.maxPhotoDimensions
    // 走**可落盘**的原生遥测(Documents/telemetry_official_native.jsonl),
    // 不用 NSLog —— NSLog 只进设备控制台,电脑侧读不到,等于做了个自己
    // 看不见的测量(2026-09-08 build 118 就犯了这个错)。
    OfficialPwNativeTelemetry.shared.log("hires_settings", [
      "arm": arm,
      "quality_prioritization": settings.photoQualityPrioritization.rawValue,
      "max_photo_w": Int(dims.width),
      "max_photo_h": Int(dims.height),
    ])
    return settings
  }

  private func captureHighResolutionStill(
    highresPath: String,
    previewPath: String,
    quality: Float,
    metadataPath: String? = nil,
    targetTimestamp: TimeInterval? = nil,
    metadataSchemaVersion: Int = 1,
    dartSaveContract: [String: Any]? = nil,
    feedSfm: Bool = false,
    deriveAuxiliary: Bool = true,
    completion: @escaping ([String: Any]?, Error?) -> Void
  ) {
    guard let session = arSession else {
      completion(nil, NSError(
        domain: "OfficialAetherARKit", code: 210,
        userInfo: [NSLocalizedDescriptionKey:
          "captureHighResolutionStill: ARSession is not running"]
      ))
      return
    }
    // The synchronization contract is anchored in ARKit's own monotonic clock
    // at native request receipt. Dart's latest pose sample is diagnostic only:
    // it may be sampled at a lower rate and must never authorize a delayed
    // high-resolution frame.
    guard let requestFrameTimestamp = session.currentFrame?.timestamp else {
      completion(nil, NSError(
        domain: "OfficialAetherARKit", code: 214,
        userInfo: [NSLocalizedDescriptionKey:
          "captureHighResolutionStill: no ARFrame at shutter request"]
      ))
      return
    }
    // [内存刹车 2026-07-19] app 有 increased-memory entitlement,上限约 4GB。
    // 刹车按*预测峰值*判,不按当前值:12MP 捕获瞬时 +~900MB,等 footprint 自己
    // 到 4GB 再刹已经晚了(那一帧会冲到 4.9GB 过 jetsam)。所以门 = 天花板 4000
    // 减尖峰 900 ⇒ 实际触发 footprint>3100,把 4GB 余量吃满且不越线。
    // 正常 footprint 600-1500MB,这道刹车基本碰不到,纯最后保险。
    // 跳过=只保主图(即时帧),Dart 收 nil 自然降级,不影响拍照与相册。
    let kMemCeilingMB = 4000.0
    let kStillSpikeMB = 900.0
    let footprintNow = Self.physFootprintMB()
    if footprintNow + kStillSpikeMB > kMemCeilingMB {
      NSLog("[OfficialAetherARKit] [内存刹车] footprint=%.0fMB +900 尖峰将过 4000MB 天花板, 跳过本帧12MP", footprintNow)
      completion(nil, NSError(
        domain: "OfficialAetherARKit", code: 213,
        userInfo: [NSLocalizedDescriptionKey:
          "captureHighResolutionStill: skipped under memory pressure"]
      ))
      return
    }
    if #available(iOS 16.0, *) {
      let onHighResFrame: (ARFrame?, Error?) -> Void = { [weak self] frame, error in
        guard let self else { return }
        if let error {
          completion(nil, error)
          return
        }
        guard let frame else {
          completion(nil, NSError(
            domain: "OfficialAetherARKit", code: 211,
            userInfo: [NSLocalizedDescriptionKey:
              "captureHighResolutionStill: ARKit returned no frame"]
          ))
          return
        }

        let pixelBuffer = frame.capturedImage
        let timestamp = frame.timestamp
        let requestToCaptureDelta = timestamp - requestFrameTimestamp

        // ══ 「已经拍下」信号:反馈挂这里,不挂「处理完成」 ══
        //
        // 三端官方各自有明文规定的同一条规矩,措辞几乎一样:
        //   iOS      AVCapturePhotoCaptureDelegate.photoOutput(_:willCapturePhotoFor:)
        //            —— "delivered right when the photo is being taken … if you want
        //               to perform a shutter animation, this is the appropriate time"
        //            (处理完成是另一个更晚的回调 didFinishProcessingPhoto)
        //   Android  CameraX ImageCapture.OnImageCapturedCallback.onCaptureStarted
        //            —— "recommended to play the shutter sound or the shutter
        //               animation at this point";底层是 Camera2 的
        //               CameraCaptureSession.CaptureCallback.onCaptureStarted
        //   HarmonyOS photoOutput.on('captureStartWithInfo') —— 带 captureId,
        //            处理完成是另一个 photoAvailable
        //
        // ARKit 的 captureHighResolutionFrame 只有一个 completion,没有
        // willCapture 那种更早的挂点,所以本端能拿到的**最早且诚实**的信号就是
        // 这里:ARFrame 已在手,照片物理上已经存在。此刻之后的 JPEG 编码、
        // gray1024/gray128 派生、建目录、写文件、写元数据全是**我们自己的处理**,
        // 属于三端规矩里 didFinishProcessing 那一半,不该让用户等。
        //
        // 2026-09-07 实测(未命名(25) n=20):12MP 事务中位 702 ms、最长 1567 ms,
        // 而震动与黑相框一直等到事务返回才发 —— 用户报"检测和快门之间还是有
        // 零点几秒的延迟"。原代码注释里 "+255ms 送达 / +304ms 事务完成 / 49ms
        // 感知不出来" 是 build-76 的数字,今天的差值早已不是 49 ms。
        //
        // 诚实性:此信号只在 ARFrame 真的到手后发,绝不在受理时刻发(2026-09-01
        // 那次"震了 30+ 次、相册只有 20 张"正是发在受理时刻)。此刻之后若校验
        // 或落盘失败,Dart 侧既有的 removePhotoCard + 失败提示会把这张撤掉。
        // 顺手记下**照片自己的**位姿。addPhotoCard 稍后会用它,而不是
        // 调用那一刻的实时位姿 —— 见 addPhotoCard 里的定罪注释。
        OfficialAetherARKitPlugin.photoPoseByEvidencePath[highresPath] =
          frame.camera.transform
        let capturedAtHostMs = Date().timeIntervalSince1970 * 1000.0
        DispatchQueue.main.async {
          self.methodChannel.invokeMethod(
            "highResFrameCaptured",
            arguments: [
              "evidenceJpegPath": highresPath,
              "previewJpegPath": previewPath,
              "captureTimestamp": timestamp,
              "capturedAtHostMs": capturedAtHostMs,
            ]
          )
        }

        // [曝光遥测 2026-09-01] 纯观测。09-01 那天有 7 次同物体会话,照片清晰度
        // (Laplacian 中位)从 846 掉到 341、上限从 ~1400 塌到 ~465,而每帧几何
        // 验证过的匹配对数随之从 4431 掉到 554(rho +0.96),最终点数跟着掉 3.5 倍。
        // 节奏被会话内对照否掉了(相关符号都不一致),构建变化也被否掉了
        // (均值那刀实测 0/21 判决分歧)。剩下最可能的是曝光/光照,而我们**一个
        // 字段都没有**,只能靠猜 —— 当天我因此编了一次"天黑了",被用户当场否掉。
        //
        // 成本:`exifData` 在高清帧送达时已经在那儿了,这里只是字典查找,
        // 每张照片一次(约 1.5 秒一次)。**不新增任何计算。**
        //
        // 明确不做的事:不重开 `configuration.isLightEstimationEnabled`。
        // ARLightEstimate.ambientIntensity 正是想要的量,但它是**每帧**跑的
        // CPU/ISP 税,已在 2026-07-12 热战役刀① 里签决关闭。EXIF 的
        // BrightnessValue 在同一个免费字典里,够用。
        //
        // 读点在 completion 里、异步编码跳转**之前** —— 不把 ARFrame 带进闭包
        // (WWDC22:持有 ARFrame 会耗空相机缓冲池、掉帧、tracking 降到 limited)。
        if #available(iOS 16.0, *) {
          let exif = frame.exifData
          func num(_ key: CFString) -> Double? {
            (exif[key as String] as? NSNumber)?.doubleValue
          }
          var row: [String: Any] = [
            // 用文件名当关联键 —— 可与 hires_still / frame 的 jpeg 字段对上。
            "jpeg": URL(fileURLWithPath: highresPath).lastPathComponent,
            "frame_t": timestamp,
          ]
          if let v = num(kCGImagePropertyExifExposureTime) { row["exposure_sec"] = v }
          if let v = num(kCGImagePropertyExifBrightnessValue) { row["brightness_ev"] = v }
          if let arr = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
             let first = arr.first {
            row["iso"] = first.doubleValue
          }
          if let v = num(kCGImagePropertyExifFNumber) { row["f_number"] = v }
          // 只有真的读到东西才发 —— 静默出口纪律:字段缺失时留痕,不是不发。
          row["fields"] = row.count - 2
          OfficialPwNativeTelemetry.shared.log("highres_exif", row)
        }
        // The completion belongs to this exact captureHighResolutionFrame
        // invocation. Its image, pose, intrinsics and timestamp are one ARFrame
        // transaction. Request-to-capture delay is sensor/ISP latency, not a
        // synchronization error; rejecting it caused deterministic failures on
        // valid 12 MP frames whose target-device latency is 0.25-1.23 seconds.
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard imageWidth == 4032, imageHeight == 3024 else {
          completion(nil, NSError(
            domain: "OfficialAetherARKit", code: 216,
            userInfo: [NSLocalizedDescriptionKey:
              "captureHighResolutionStill: expected 4032x3024, got \(imageWidth)x\(imageHeight)"]
          ))
          return
        }
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let trackingStateName = Self.trackingStateString(frame.camera.trackingState)
        let isTracking: Bool
        switch frame.camera.trackingState {
        case .normal: isTracking = true
        default: isTracking = false
        }
        let cameraTransform: [Float] = [
          transform.columns.0.x, transform.columns.0.y,
          transform.columns.0.z, transform.columns.0.w,
          transform.columns.1.x, transform.columns.1.y,
          transform.columns.1.z, transform.columns.1.w,
          transform.columns.2.x, transform.columns.2.y,
          transform.columns.2.z, transform.columns.2.w,
          transform.columns.3.x, transform.columns.3.y,
          transform.columns.3.z, transform.columns.3.w,
        ]
        let intrinsicFxFyCxCy: [Float] = [
          intrinsics[0, 0],
          intrinsics[1, 1],
          intrinsics[2, 0],
          intrinsics[2, 1],
        ]
        var anchorsWorld: [[Float]] = []
        var anchorIds: [UInt64] = []
        if let raw = frame.rawFeaturePoints {
          let n = raw.points.count
          anchorsWorld.reserveCapacity(n)
          anchorIds.reserveCapacity(n)
          for i in 0..<n {
            let p = raw.points[i]
            anchorsWorld.append([p.x, p.y, p.z])
            anchorIds.append(raw.identifiers[i])
          }
        }
        let finiteAnchors = PWJSONSafety.finitePointPairs(
          anchorsWorld,
          identifiers: anchorIds
        )
        anchorsWorld = finiteAnchors.points
        anchorIds = finiteAnchors.identifiers
        do {
          try PWJSONSafety.requireFinite(
            cameraTransform,
            field: "extrinsic"
          )
          try PWJSONSafety.requireFinite(
            intrinsicFxFyCxCy,
            field: "intrinsics_fxfycxcy"
          )
        } catch {
          completion(nil, error)
          return
        }
        let scaleAlignPremetrics = Self.computeScaleAlignPremetrics(
          cameraTransform: transform,
          anchorsWorld: anchorsWorld
        )
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = self.ciContext

        self.jpegEncodeQueue.async {
          // 关键路径逐段计时。完成回调一天不返回,Dart 的 awaitingCaptureBaseline
          // 就一天不清、下一次自动拍就一天不许判 —— 所以这条路径上每一毫秒都
          // 既是延迟也是吞吐。逐段量出来才知道下一刀该切哪儿(2026-09-08)。
          let tStart = CACurrentMediaTime()
          var tGray = tStart, tDirs = tStart, tJpeg = tStart, tSfmGray = tStart
          do {
            let gray1024 = deriveAuxiliary
              ? Self.extractGray(
                  pixelBuffer,
                  targetSide: Self.highResQualityDownsampleSide
                )
              : nil
            let gray128 = deriveAuxiliary
              ? Self.extractGray128(pixelBuffer)
              : nil
            tGray = CACurrentMediaTime()
            try FileManager.default.createDirectory(
              atPath: (highresPath as NSString).deletingLastPathComponent,
              withIntermediateDirectories: true
            )
            if deriveAuxiliary {
              try FileManager.default.createDirectory(
                atPath: (previewPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
              )
            }
            if let metadataPath {
              try FileManager.default.createDirectory(
                atPath: (metadataPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
              )
            }
            tDirs = CACurrentMediaTime()
            try Self.encodeCVPixelBufferAsJpeg(
              pixelBuffer,
              to: URL(fileURLWithPath: highresPath),
              quality: CGFloat(quality),
              ciContext: ciContext
            )
            tJpeg = CACurrentMediaTime()

            var payload: [String: Any] = [
              "highresPath": highresPath,
              "previewPath": previewPath,
              "requestTimestamp": requestFrameTimestamp,
              "timestamp": timestamp,
              "timestampDelta": requestToCaptureDelta,
              "imageWidth": imageWidth,
              "imageHeight": imageHeight,
              "cameraTransform": cameraTransform,
              "intrinsics": intrinsicFxFyCxCy,
              "trackingStateName": trackingStateName,
              "isTracking": isTracking,
              "scaleAlignAnchorCount": scaleAlignPremetrics.anchorDepthCount,
              "scaleAlignDepthSpanM": scaleAlignPremetrics.anchorDepthSpanM,
              "scaleAlignReliabilityPrior": scaleAlignPremetrics.reliabilityPrior,
              "captureKind": "arkit_high_res_still",
              "poseSyncQuality": "ar_session_high_res_frame",
              "nativeRole": "thin_arkit_high_res_still_executor",
            ]
            if let dartSaveContract {
              payload["dartSaveContract"] = dartSaveContract
            }
            if let gray1024 {
              payload["q_gray1024"] = FlutterStandardTypedData(bytes: gray1024)
              payload["q_gray1024W"] = Self.highResQualityDownsampleSide
              payload["q_gray1024H"] = Self.highResQualityDownsampleSide
            }
            if let gray128 {
              payload["q_gray128"] = FlutterStandardTypedData(bytes: gray128)
            }
            // [E24 S2] 静照即证据:全分辨率灰度(4032≤sfmFeedMaxSide=4224,
            // 不降采样)+ 静照自己的位姿/内参已在载荷 —— Dart 据此组
            // SfmFrameFeed 喂流式 SfM,与 saveCurrentFrame 的 sfm_gray
            // 键语义逐字一致。
            if feedSfm, let g = Self.extractGrayAspect(
              pixelBuffer, maxSide: Self.sfmFeedMaxSide
            ) {
              payload["sfm_gray"] = FlutterStandardTypedData(bytes: g.data)
              payload["sfm_gray_w"] = g.width
              payload["sfm_gray_h"] = g.height
            }
            tSfmGray = CACurrentMediaTime()
            // ══ 先返回,再写没人等的东西 ══
            DispatchQueue.main.async { completion(payload, nil) }
            let ms = { (a: CFTimeInterval, b: CFTimeInterval) in Int((b - a) * 1000.0) }
            OfficialPwNativeTelemetry.shared.log("hires_critical_path", [
              "gray_ms": ms(tStart, tGray),
              "mkdir_ms": ms(tGray, tDirs),
              "jpeg12mp_ms": ms(tDirs, tJpeg),
              "sfmgray_ms": ms(tJpeg, tSfmGray),
              "total_ms": ms(tStart, tSfmGray),
            ])
            // 预览 JPEG 与元数据 JSON **挪到完成回调之后**:
            //  · `_highres_preview.jpg` 全仓只有一处引用(拼路径那行),
            //    `still.previewPath` 只被旧的 lib/capture/ 路径读,官方采集
            //    这条路从不读它,归档/上传也不带它 —— 却每张都在关键路径上
            //    编码+落盘一次。文件照写(不删任何数据),只是不再让用户等它。
            //  · 元数据 sidecar 是事后取证用的(2026-09-07 定位 build 113 的
            //    通道缺陷就是靠它),留着;但没有任何同步消费者,同样后置。
            // 失败只记账不改判:照片此刻已经成立,完成回调已经发出去了。
            let tAfter = CACurrentMediaTime()
            do {
            if deriveAuxiliary {
              try Self.encodeCIImageAsJpeg(
                Self.makePreviewImage(from: ciImage),
                to: URL(fileURLWithPath: previewPath),
                quality: CGFloat(quality),
                ciContext: ciContext
              )
            }
            if let metadataPath {
              var metadata: [String: Any] = [
                "version": metadataSchemaVersion,
                "native_role": "thin_arkit_high_res_still_executor",
                "t": timestamp,
                "request_frame_timestamp": requestFrameTimestamp,
                "request_to_capture_dt": requestToCaptureDelta,
                "image_w": imageWidth,
                "image_h": imageHeight,
                "extrinsic": cameraTransform,
                "intrinsics_fxfycxcy": intrinsicFxFyCxCy,
                "trackingStateName": trackingStateName,
                "tracking_state": trackingStateName,
                "is_tracking": isTracking,
                "anchors_world": anchorsWorld,
                "anchor_ids": anchorIds.map { NSNumber(value: $0) },
                "scale_align_premetrics": [
                  "anchor_depth_count": scaleAlignPremetrics.anchorDepthCount,
                  "anchor_depth_min_m": scaleAlignPremetrics.anchorDepthMinM,
                  "anchor_depth_max_m": scaleAlignPremetrics.anchorDepthMaxM,
                  "anchor_depth_span_m": scaleAlignPremetrics.anchorDepthSpanM,
                  "reliability_prior": scaleAlignPremetrics.reliabilityPrior,
                ],
              ]
              if let dartSaveContract {
                metadata["dart_save_contract"] = dartSaveContract
              }
              if let targetTimestamp {
                metadata["save_target_t"] = targetTimestamp
                metadata["save_dt"] = abs(timestamp - targetTimestamp)
              } else {
                metadata["save_dt"] = 0.0
              }
              let json = try PWJSONSafety.data(withJSONObject: metadata)
              try json.write(to: URL(fileURLWithPath: metadataPath))
            }
              OfficialPwNativeTelemetry.shared.log("hires_deferred_writes", [
                "ms": Int((CACurrentMediaTime() - tAfter) * 1000.0),
              ])
            } catch {
              OfficialPwNativeTelemetry.shared.log("hires_deferred_writes", [
                "ms": Int((CACurrentMediaTime() - tAfter) * 1000.0),
                "error": String(describing: error),
              ])
            }
          } catch {
            DispatchQueue.main.async { completion(nil, error) }
          }
        }
      }
      // ══ iOS 26 起 ARKit 才允许把 AVCapturePhotoSettings 传进来 ══
      //
      // 2026-09-08 实测(未命名(26), n=20):快门发出到 ARFrame 到手 **610 ms**
      // 中位,而 ARFrame 自己的曝光时间戳只比请求晚 67 ms(有时为负 —— iOS 17
      // 起的 Zero Shutter Lag 会从环形缓冲里取过去的帧)。也就是说照片早就曝好了,
      // 那 ~540 ms 是 ARKit 自己的处理与投递。三端规矩里的早回调
      // (willCapturePhotoFor / onCaptureStarted / captureStartWithInfo)在 ARKit
      // 高清取图这条路上**拿不到** —— ARSession 不暴露 AVCaptureSession
      // (Apple 论坛:no supported way),WWDC26 讲高分辨率拍照那场也通篇没提它。
      //
      // 所以唯一能碰的是**让 ARKit 自己快一点**:iOS 26 的
      // `captureHighResolutionFrameUsingPhotoSettings:` + ARVideoFormat 的
      // `defaultPhotoSettings`。我们此前一直走 iOS 16 那个没有任何参数的版本 ——
      // 这是一条从没开过的库自带开关。
      //
      // **默认行为一个字节不变**:不设 env 时原样传 ARKit 自己的
      // defaultPhotoSettings,等价于旧调用。换档要动画质(多帧融合),画质掉了
      // 特征就少、点就少 —— 那不叫无损,所以只做成 env 旋钮由实测裁决:
      //   OFFICIAL_AETHER_PHOTO_QUALITY = speed | balanced | quality
      // 一次装机、改 env 换臂,不必重装(设备 env 文件是共享单文件,
      // 推送必须读-改-写合并)。
      // 同时把 ARKit 的默认档打进日志 —— 我们从来不知道它默认是哪一档,
      // 这是第一手观测,不是猜。
      if #available(iOS 26.0, *),
         let settings = Self.resolveHighResPhotoSettings(session: session) {
        session.captureHighResolutionFrame(using: settings,
                                           completion: onHighResFrame)
      } else {
        session.captureHighResolutionFrame(completion: onHighResFrame)
      }
    } else {
      completion(nil, NSError(
        domain: "OfficialAetherARKit", code: 212,
        userInfo: [NSLocalizedDescriptionKey:
          "captureHighResolutionStill requires iOS 16 or newer"]
      ))
    }
  }

  /// CVPixelBuffer (BGRA / NV12 / whatever ARKit hands us) → JPEG file
  /// via CIContext + ImageIO. Quality 0.9 is visually lossless at 4K
  /// (~700-900 KB per frame; H.264 .mov was ~50 MB/min, so 590 photos
  /// ≈ 470 MB/capture — Plan G accepts this for full-quality W3 input).
  private static func encodeCVPixelBufferAsJpeg(
    _ buffer: CVPixelBuffer,
    to url: URL,
    quality: CGFloat,
    ciContext: CIContext
  ) throws {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
      throw NSError(
        domain: "OfficialAetherARKit", code: 201,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCVPixelBufferAsJpeg: CIContext.createCGImage failed"]
      )
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
      throw NSError(
        domain: "OfficialAetherARKit", code: 202,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCVPixelBufferAsJpeg: CGImageDestinationCreateWithURL failed"]
      )
    }
    // Pixels are left in the camera's native LANDSCAPE orientation so they
    // stay consistent with the landscape intrinsics written to the metadata
    // sidecar (DA3/SfM read raw pixels and ignore EXIF). We only TAG the EXIF
    // orientation so viewers that honor it (Flutter Image.file, the album,
    // the AR photo cards, Photos.app) display a portrait capture upright.
    // .right (6) = 90° CW, the portrait-from-landscapeRight sensor mapping.
    let opts: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality,
      kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
    ]
    CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
      throw NSError(
        domain: "OfficialAetherARKit", code: 203,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCVPixelBufferAsJpeg: CGImageDestinationFinalize failed"]
      )
    }
  }

  private static func encodeCIImageAsJpeg(
    _ image: CIImage,
    to url: URL,
    quality: CGFloat,
    ciContext: CIContext
  ) throws {
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      throw NSError(
        domain: "OfficialAetherARKit", code: 204,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCIImageAsJpeg: CIContext.createCGImage failed"]
      )
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
      throw NSError(
        domain: "OfficialAetherARKit", code: 205,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCIImageAsJpeg: CGImageDestinationCreateWithURL failed"]
      )
    }
    CGImageDestinationAddImage(
      dest,
      cgImage,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    if !CGImageDestinationFinalize(dest) {
      throw NSError(
        domain: "OfficialAetherARKit", code: 206,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCIImageAsJpeg: CGImageDestinationFinalize failed"]
      )
    }
  }

  private static func makePreviewImage(from image: CIImage) -> CIImage {
    let maxEdge = max(image.extent.width, image.extent.height)
    guard maxEdge > 1024 else { return image }
    let scale = 1024 / maxEdge
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  }

  private static func computeScaleAlignPremetrics(
    cameraTransform: simd_float4x4,
    anchorsWorld: [[Float]]
  ) -> ScaleAlignPremetrics {
    let cameraPosition = SIMD3<Float>(
      cameraTransform.columns.3.x,
      cameraTransform.columns.3.y,
      cameraTransform.columns.3.z
    )
    let cameraZAxisWorld = SIMD3<Float>(
      cameraTransform.columns.2.x,
      cameraTransform.columns.2.y,
      cameraTransform.columns.2.z
    )

    var count = 0
    var minDepth = Float.greatestFiniteMagnitude
    var maxDepth = -Float.greatestFiniteMagnitude
    for p in anchorsWorld {
      if p.count < 3 { continue }
      let worldPoint = SIMD3<Float>(p[0], p[1], p[2])
      let delta = worldPoint - cameraPosition
      // ARKit camera looks down local -Z. Positive scene depth is -cam.z.
      let depth = -simd_dot(delta, cameraZAxisWorld)
      if depth.isFinite && depth >= 0.10 && depth <= 6.0 {
        count += 1
        minDepth = min(minDepth, depth)
        maxDepth = max(maxDepth, depth)
      }
    }

    if count == 0 {
      return ScaleAlignPremetrics(
        anchorDepthCount: 0,
        anchorDepthMinM: 0,
        anchorDepthMaxM: 0,
        anchorDepthSpanM: 0,
        reliabilityPrior: 0
      )
    }

    let span = max(0, maxDepth - minDepth)
    let countScore = clamp01((Float(count) - 12.0) / 48.0)
    let spanScore = clamp01((span - 0.08) / 0.42)
    let reliability = clamp01(countScore * 0.45 + spanScore * 0.55)
    return ScaleAlignPremetrics(
      anchorDepthCount: count,
      anchorDepthMinM: minDepth,
      anchorDepthMaxM: maxDepth,
      anchorDepthSpanM: span,
      reliabilityPrior: reliability
    )
  }

  private static func clamp01(_ x: Float) -> Float {
    return min(1.0, max(0.0, x))
  }

  private static func cameraControlPayload() -> [String: Any] {
    guard #available(iOS 16.0, *),
          let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
      return [:]
    }
    return [
      "isAdjustingFocus": device.isAdjustingFocus,
      "isAdjustingExposure": device.isAdjustingExposure,
      "lensPosition": device.lensPosition,
      "exposureTargetOffset": device.exposureTargetOffset,
      "iso": device.iso,
      "exposureDurationSec": CMTimeGetSeconds(device.exposureDuration),
      "focusMode": "\(device.focusMode.rawValue)",
      "exposureMode": "\(device.exposureMode.rawValue)",
    ]
  }

  /// Redundant v2 anchor probe. Unlike the v1 row, this emits an explicit
  /// unavailable state instead of silently producing no evidence when either
  /// side of the lock/current pair is absent.
  private func logAnchorObservationV2(
    frameTimestamp: TimeInterval,
    trackingStateName: String,
    currentTransform: simd_float4x4?,
    anchorState: String? = nil
  ) {
    guard let lockTransform = lockTimeAnchorTransform else {
      OfficialPwNativeTelemetry.shared.log("arkit_anchor_delta_v2", [
        "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
        "frame_t": frameTimestamp,
        "anchor_state": anchorState ?? "missing_lock",
        "tracking": trackingStateName,
        "observation_only": true,
      ])
      lastAnchorV2LogTime = frameTimestamp
      return
    }
    guard let currentTransform else {
      OfficialPwNativeTelemetry.shared.log("arkit_anchor_delta_v2", [
        "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
        "frame_t": frameTimestamp,
        "anchor_state": anchorState ?? "missing_current_anchor",
        "tracking": trackingStateName,
        "observation_only": true,
      ])
      lastAnchorV2LogTime = frameTimestamp
      return
    }

    let absolute = LiveCloudAnchorDiagnostics.delta(
      lock: lockTransform,
      current: currentTransform
    )
    let step = LiveCloudAnchorDiagnostics.delta(
      lock: lastAnchorV2Transform ?? lockTransform,
      current: currentTransform
    )
    OfficialPwNativeTelemetry.shared.log("arkit_anchor_delta_v2", [
      "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
      "frame_t": frameTimestamp,
      "anchor_state": anchorState ?? "tracked",
      "dx_m": Double(absolute.translation.x),
      "dy_m": Double(absolute.translation.y),
      "dz_m": Double(absolute.translation.z),
      "translation_m": absolute.translationMeters,
      "qx": Double(absolute.rotation.imag.x),
      "qy": Double(absolute.rotation.imag.y),
      "qz": Double(absolute.rotation.imag.z),
      "qw": Double(absolute.rotation.real),
      "rotation_deg": absolute.rotationDegrees,
      "step_translation_m": step.translationMeters,
      "step_rotation_deg": step.rotationDegrees,
      "severity": LiveCloudAnchorDiagnostics.severity(
        translationMeters: absolute.translationMeters
      ),
      "tracking": trackingStateName,
      "observation_only": true,
    ])
    lastAnchorV2Transform = currentTransform
    lastAnchorV2LogTime = frameTimestamp
  }

  // MARK: Per-frame broadcast

  /// 屏幕中心的分级 raycast 深度(米)。与 lockOrigin 的选点策略同款
  /// (那段代码在下方 ~1651 行,带完整理由注释),但只要**距离**不要位置;
  /// 两级都未命中、贴脸(<5cm)或超 2.5m 封顶时返回 nil。
  private func centerRayDepthM(cameraTransform t: simd_float4x4) -> Float? {
    guard let session = arSession else { return nil }
    let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    let forward = simd_normalize(
      -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
    )
    var hits: [ARRaycastResult] = []
    if #available(iOS 13.0, *) {
      hits = session.raycast(ARRaycastQuery(
        origin: camPos, direction: forward,
        allowing: .estimatedPlane, alignment: .any
      ))
      if hits.isEmpty {
        hits = session.raycast(ARRaycastQuery(
          origin: camPos, direction: forward,
          allowing: .existingPlaneInfinite, alignment: .horizontal
        ))
      }
    }
    guard let hit = hits.first else { return nil }
    let d = simd_distance(
      camPos,
      simd_float3(
        hit.worldTransform.columns.3.x,
        hit.worldTransform.columns.3.y,
        hit.worldTransform.columns.3.z
      )
    )
    return (d > 0.05 && d <= 2.5) ? d : nil
  }

  private func broadcast(frame: ARFrame) {
    // Plan G W2 photos-on-disk arch (replaces the deleted AVAssetWriter
    // pipeline 2026-05-16): keep a short timestamp-addressable snapshot
    // ring so Dart can ask for the ARFrame that actually produced the
    // accepted pose event, not whichever frame happens to be latest after
    // MethodChannel round-trip latency.
    //
    // Why up-front (before payload assembly): saveCurrentFrameAsJpeg can
    // fire from Dart any time after the corresponding pose event reaches
    // the cell. We want the snapshot fresh by the time that round-trip
    // completes (~50-100 ms later) — even if the rest of broadcast is
    // still running, the snapshot is already valid.
    let cameraTransform = frame.camera.transform
    let cameraIntrinsics = frame.camera.intrinsics
    let extrinsicArr: [Float] = [
      cameraTransform.columns.0.x, cameraTransform.columns.0.y,
      cameraTransform.columns.0.z, cameraTransform.columns.0.w,
      cameraTransform.columns.1.x, cameraTransform.columns.1.y,
      cameraTransform.columns.1.z, cameraTransform.columns.1.w,
      cameraTransform.columns.2.x, cameraTransform.columns.2.y,
      cameraTransform.columns.2.z, cameraTransform.columns.2.w,
      cameraTransform.columns.3.x, cameraTransform.columns.3.y,
      cameraTransform.columns.3.z, cameraTransform.columns.3.w,
    ]
    let intrinsicArr: [Float] = [
      cameraIntrinsics.columns.0.x, // fx
      cameraIntrinsics.columns.1.y, // fy
      cameraIntrinsics.columns.2.x, // cx
      cameraIntrinsics.columns.2.y, // cy
    ]
    let trackingStateName = Self.trackingStateString(frame.camera.trackingState)
    let isTracking: Bool
    switch frame.camera.trackingState {
    case .normal: isTracking = true
    default: isTracking = false
    }
    let pixelBuf = frame.capturedImage
    let imgW = CVPixelBufferGetWidth(pixelBuf)
    let imgH = CVPixelBufferGetHeight(pixelBuf)
    var anchorsW: [[Float]] = []
    var anchorIds: [UInt64] = []
    if let raw = frame.rawFeaturePoints {
      let n = raw.points.count
      anchorsW.reserveCapacity(n)
      anchorIds.reserveCapacity(n)
      for i in 0..<n {
        let p = raw.points[i]
        anchorsW.append([p.x, p.y, p.z])
        anchorIds.append(raw.identifiers[i])
      }
    }
    let finiteAnchors = PWJSONSafety.finitePointPairs(
      anchorsW,
      identifiers: anchorIds
    )
    anchorsW = finiteAnchors.points
    anchorIds = finiteAnchors.identifiers
    let scaleAlignPremetrics = Self.computeScaleAlignPremetrics(
      cameraTransform: cameraTransform,
      anchorsWorld: anchorsW
    )
    let snapshot = LatestFrameSnapshot(
      pixelBuffer: pixelBuf,
      timestamp: frame.timestamp,
      extrinsic: extrinsicArr,
      intrinsicsFxFyCxCy: intrinsicArr,
      imageW: imgW,
      imageH: imgH,
      trackingStateName: trackingStateName,
      isTracking: isTracking,
      anchorsWorld: anchorsW,
      anchorIds: anchorIds,
      scaleAlignPremetrics: scaleAlignPremetrics
    )
    lastFrameSnapshot = snapshot
    recentFrameSnapshots.append(snapshot)
    if recentFrameSnapshots.count > Self.maxRecentFrameSnapshots {
      recentFrameSnapshots.removeFirst(
        recentFrameSnapshots.count - Self.maxRecentFrameSnapshots
      )
    }

    // ── Refresh worldOrigin from the subject anchor's latest transform.
    // ARKit re-aligns its world frame continuously (limited→normal
    // recovery, loop closure). Per WWDC 2018 §610 + Polycam polyform:
    // an `ARAnchor`'s transform is updated by ARKit in lock-step with
    // those re-alignments, so reading it every frame keeps `worldOrigin`
    // glued to the real-world point the user locked. We accept the
    // update unconditionally — an earlier 0.5 m drift-rejection
    // threshold got stuck rejecting forever once ARKit issued a real
    // multi-meter correction (no recovery once `diff(old, new)` stayed
    // above the cap; user-facing symptom: "白球还是会大跳去很远的地方").
    if let myAnchor = worldSubjectAnchor,
       let updatedAnchor = frame.anchors.first(
         where: { $0.identifier == myAnchor.identifier }
       ) {
      worldSubjectAnchor = updatedAnchor
      worldOrigin = simd_float3(
        updatedAnchor.transform.columns.3.x,
        updatedAnchor.transform.columns.3.y,
        updatedAnchor.transform.columns.3.z
      )
    }

    if frame.timestamp - lastAnchorV2LogTime > 1.0 {
      logAnchorObservationV2(
        frameTimestamp: frame.timestamp,
        trackingStateName: trackingStateName,
        currentTransform: worldSubjectAnchor?.transform
      )
    }

    // [LIVE-CLOUD-DIAG V1] Observation only: persist the complete 6DoF
    // subject-anchor correction. No value below is fed back to ARKit, the
    // point cloud, or capture policy.
    if let lockTransform = lockTimeAnchorTransform,
       let currentTransform = worldSubjectAnchor?.transform {
      let absolute = LiveCloudAnchorDiagnostics.delta(
        lock: lockTransform,
        current: currentTransform
      )
      let severity = LiveCloudAnchorDiagnostics.severity(
        translationMeters: absolute.translationMeters
      )
      let severityChanged = severity != lastAnchorSeverity
      if frame.timestamp - lastDriftLogTime > 1.0 || severityChanged {
        let step = LiveCloudAnchorDiagnostics.delta(
          lock: lastLoggedAnchorTransform ?? lockTransform,
          current: currentTransform
        )
        OfficialPwNativeTelemetry.shared.log("arkit_anchor_delta_v1", [
          "contract": "PW_LIVE_CLOUD_DIAG_V1_20260810",
          "frame_t": frame.timestamp,
          "dx_m": Double(absolute.translation.x),
          "dy_m": Double(absolute.translation.y),
          "dz_m": Double(absolute.translation.z),
          "translation_m": absolute.translationMeters,
          "qx": Double(absolute.rotation.imag.x),
          "qy": Double(absolute.rotation.imag.y),
          "qz": Double(absolute.rotation.imag.z),
          "qw": Double(absolute.rotation.real),
          "rotation_deg": absolute.rotationDegrees,
          "step_translation_m": step.translationMeters,
          "step_rotation_deg": step.rotationDegrees,
          "severity": severity,
          "tracking": trackingStateName,
          "observation_only": true,
        ])
        NSLog(String(
          format: "[OfficialAetherARKit] anchor drift: %.3f m / %.2f deg (%@)",
          absolute.translationMeters,
          absolute.rotationDegrees,
          severity
        ))
        lastDriftLogTime = frame.timestamp
        lastLoggedAnchorTransform = currentTransform
        lastAnchorSeverity = severity
      }
    }

    // Quaternion (x, y, z, w) from rotation submatrix.
    let q = simd_quaternion(cameraTransform)

    // 冷启动深度:0.5s 节流的中心分级 raycast(见属性注释)。raycast 是
    // 对当前帧状态的纯几何查询,2Hz 的成本可忽略 —— 与"回调里逐帧搬
    // 兆级数据"不是一类事。
    if frame.timestamp - lastCenterRayAt >= Self.centerRayInterval {
      lastCenterRayAt = frame.timestamp
      lastCenterRayDepthM = centerRayDepthM(cameraTransform: cameraTransform) ?? -1
    }

    var payload: [String: Any] = [
      "centerRayDepthM": lastCenterRayDepthM,
      "tx": cameraTransform.columns.3.x,
      "ty": cameraTransform.columns.3.y,
      "tz": cameraTransform.columns.3.z,
      "qx": q.imag.x,
      "qy": q.imag.y,
      "qz": q.imag.z,
      "qw": q.real,
      "extrinsic": extrinsicArr,
      "intrinsicFxFyCxCy": intrinsicArr,
      "isTracking": isTracking,
      "trackingStateName": trackingStateName,
      "t": frame.timestamp,
      "imageWidth": imgW,
      "imageHeight": imgH,
      "scaleAlignAnchorCount": scaleAlignPremetrics.anchorDepthCount,
      "scaleAlignDepthSpanM": scaleAlignPremetrics.anchorDepthSpanM,
      "scaleAlignReliabilityPrior": scaleAlignPremetrics.reliabilityPrior,
    ]
    if frame.timestamp - lastPreviewPointPayloadTime >= Self.previewPointInterval {
      let previewPayload = Self.makePreviewPointPayload(
        frame: frame,
        maxPoints: Self.previewPointMaxCount
      )
      if !previewPayload.isEmpty {
        payload.merge(previewPayload) { _, new in new }
      }
      lastPreviewPointPayloadTime = frame.timestamp
    }
    payload.merge(Self.cameraControlPayload()) { _, new in new }

    // Throttled (6 Hz) frame-quality compute on the AR camera buffer.
    // iOS Aether3D uses AVFoundation pixel buffers from the camera
    // plugin path, but on Flutter we can't run AVCaptureSession
    // alongside ARWorldTrackingConfiguration without colliding for
    // exclusive camera access. So we tap ARFrame.capturedImage
    // directly here — same pattern iOS Aether3D uses on its AR-only
    // path (capture session reads the AR buffer too).
    //
    // Plane extract runs OFF the main thread (qualityQueue) so it
    // doesn't block ARKit's delegate callback chain. Result is cached
    // in `pendingGray128` and attached to the NEXT pose event (1-3
    // frames stale ≈ 17-50 ms). The source receipt below prevents the consumer
    // from silently treating those bytes as the delivery pose.
    qDiagPoseEvents += 1
    if qDiagWindowStart == 0 { qDiagWindowStart = frame.timestamp }
    if frame.timestamp - lastQualityComputeTime >= qualityInterval {
      if qualityComputeInFlight {
        // Defensive guard: previous compute hasn't finished yet (shouldn't
        // happen if compute < interval, but track for diagnostic visibility).
        qDiagSkips += 1
      } else {
        lastQualityComputeTime = frame.timestamp
        qualityComputeInFlight = true
        // Capture the pixel buffer (ARC retains the CVPixelBuffer; the
        // ARFrame itself is NOT captured, so ARKit's frame pool can
        // recycle the wrapping ARFrame as soon as broadcast returns).
        let pixelBuffer = frame.capturedImage
        let graySourceTimestamp = frame.timestamp
        let graySourceWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let graySourceHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        let graySourceFocalX = Double(cameraIntrinsics.columns.0.x)
          * Double(Self.downsampleSide) / graySourceWidth
        let graySourceFocalY = Double(cameraIntrinsics.columns.1.y)
          * Double(Self.downsampleSide) / graySourceHeight
        let computeStart = CACurrentMediaTime()
        qualityQueue.async { [weak self] in
          let g = OfficialAetherARKitPlugin.extractGray128(pixelBuffer)
          let elapsedMs = (CACurrentMediaTime() - computeStart) * 1000
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.pendingGray128 = g
            self.pendingGraySourceTimestamp = graySourceTimestamp
            self.pendingGraySourceFocalX = graySourceFocalX
            self.pendingGraySourceFocalY = graySourceFocalY
            self.qualityComputeInFlight = false
            self.qDiagFires += 1
            self.qDiagElapsedMsSum += elapsedMs
          }
        }
      }
    }
    // Attach the most-recent gray128 thumbnail (from a previous frame)
    // and clear so we don't repeat-send the same payload. Dart side
    // (platform_pose_provider.dart) re-derives sharpness / brightness /
    // signature from these 16 KB via lib/quality/quality_compute.dart.
    if let g = pendingGray128 {
      payload["q_grayW"] = OfficialAetherARKitPlugin.downsampleSide
      payload["q_grayH"] = OfficialAetherARKitPlugin.downsampleSide
      payload["q_gray128"] = FlutterStandardTypedData(bytes: g)
      if let sourceTimestamp = pendingGraySourceTimestamp {
        payload["q_graySourceTimestamp"] = sourceTimestamp
      }
      if let sourceFocalX = pendingGraySourceFocalX {
        payload["q_graySourceFocalX"] = sourceFocalX
      }
      if let sourceFocalY = pendingGraySourceFocalY {
        payload["q_graySourceFocalY"] = sourceFocalY
      }
      pendingGray128 = nil
      pendingGraySourceTimestamp = nil
      pendingGraySourceFocalX = nil
      pendingGraySourceFocalY = nil
      qDiagAttached += 1
    }
    // 5s window aggregate log so we can sanity-check:
    //   • fires ≈ 30 per 5s (6 Hz × 5)
    //   • avgMs ≪ 16 (otherwise compute is starving the next frame)
    //   • skips=0 (compute always finishes before the next interval)
    //   • attached close to fires (every compute eventually reaches a payload)
    if frame.timestamp - qDiagWindowStart >= 5.0 {
      let avgMs = qDiagFires > 0 ? qDiagElapsedMsSum / Double(qDiagFires) : 0
      // 走**可落盘**的原生遥测:这正是提高判决率之后要看的代价
      // (avgMs 是否逼近帧预算、skips 是否开始出现)。NSLog 只进设备控制台,
      // 电脑侧读不到 —— 那等于做自己看不见的测量。
      OfficialPwNativeTelemetry.shared.log("quality_window", [
        "target_hz": 1.0 / qualityInterval,
        "arm_index": qualityArmIndex % Self.qualityHzArms.count,
        "arms": Self.qualityHzArms.count,
        "fires": qDiagFires,
        "skips": qDiagSkips,
        "avg_compute_ms": avgMs,
        "attached": qDiagAttached,
        "pose_events": qDiagPoseEvents,
      ])
      NSLog(String(
        format: "[OfficialAetherARKit] 5s quality: fires=%d skips=%d avgMs=%.1f attached=%d/%d",
        qDiagFires, qDiagSkips, avgMs, qDiagAttached, qDiagPoseEvents
      ))
      // 窗口收尾处换臂:每条 quality_window 只属于一个臂,天然可比。
      qualityArmIndex += 1
      qDiagWindowStart = frame.timestamp
      qDiagFires = 0
      qDiagSkips = 0
      qDiagElapsedMsSum = 0
      qDiagAttached = 0
      qDiagPoseEvents = 0
    }
    // Include worldOrigin / worldYaw so the Dart side can do the
    // (rel = camPos - origin) math without a round-trip back into
    // ARKit. Always sent (zero before lock) so the schema is stable.
    if let origin = worldOrigin {
      payload["worldOriginX"] = origin.x
      payload["worldOriginY"] = origin.y
      payload["worldOriginZ"] = origin.z
      payload["worldYaw"] = worldYaw
      payload["hasOrigin"] = true
      payload["anchorTransform"] = Self.floatArray(
        worldSubjectAnchor?.transform ?? matrix_identity_float4x4
      )
    } else {
      payload["worldOriginX"] = Float(0)
      payload["worldOriginY"] = Float(0)
      payload["worldOriginZ"] = Float(0)
      payload["worldYaw"] = Float(0)
      payload["hasOrigin"] = false
      payload["anchorTransform"] = [Float]()
    }

    poseStreamHandler.send(payload)
  }
}

// MARK: - Frame quality plane extract (cross-platform handoff to Dart)

@available(iOS 11.0, *)
extension OfficialAetherARKitPlugin {
  /// Output edge length of `extractGray128`. Must match
  /// `kQualityGraySide` in lib/quality/quality_compute.dart.
  static let downsampleSide = 128
  static let highResQualityDownsampleSide = 1024

  /// Long-edge target for the streaming-SfM grayscale feed attached to the
  /// `saveCurrentFrameAsJpeg` reply. Aspect-preserving (unlike the square
  /// `extractGray`), because the on-device SfM self-calibrates a single
  /// shared SIMPLE_PINHOLE camera — a non-uniform squash would break the
  /// single-focal-length premise.
  ///
  /// LIVE TIER = 4224 (full 4K, no downscale) — restored 2026-07-08.
  /// This feeds the SIFT detector the full 3840×2160 gray, which with
  /// maxFeatures=8192 + peak=0.004 yields the dense ~49k-point live cloud
  /// (bedsheets/low-texture filled) at extract ~1.1 s/frame, mem ~1.6 GB,
  /// feed queue ~6 — heavy but the capture path keeps pace (proven on
  /// 30–70-frame captures). The contention that broke the shutter/album was
  /// maxFeatures=12288 (14–17k keypoints, ~1.5 s/frame, queue→32), NOT this
  /// 8192 tier — 8192@4K is the current best working config, so we keep 4K.
  ///
  /// A 2000-long-edge downscale was tried (extract 468 ms, mem 932 MB, queue
  /// 0 — much safer margin) but it costs ~40% of the points: the live cloud
  /// dropped to ~30k because 2000px physically loses the weak-texture
  /// gradients (a box-average pre-filter did NOT help — SIFT rebuilds its own
  /// Gaussian pyramid, so the pre-filter is redundant; resolution is the
  /// binding constraint). Density was preferred over margin. If sustained/hot
  /// captures later erode the margin, drop this toward 3200/2800 for a Pareto
  /// point. Independent of storage/texturing either way (the on-disk 4K JPEG
  /// is a separate encode pass; cloud reconstruction reads those full-res).
  /// Prior tiers: 1280 (old live), 2000 (safe/sparse), 4224 (this / dense).
  static let sfmFeedMaxSide = 4224

  /// [SPLAT-RADIUS 2026-07-28] AR 点云近处点径上限(像素)。实验臂:
  /// `OFFICIAL_AETHER_AR_SPLAT_MAX_PX` 覆盖(6=旧行为 / 20 / 50 三档对比),
  /// 未设时用 6 —— **默认即旧行为,不设环境变量则渲染逐像素不变**。
  /// 真机对比拍板后把默认值改成签决档,再删这个旋钮。
  static let arSplatMaxScreenRadius: CGFloat = {
    if let raw = ProcessInfo.processInfo.environment["OFFICIAL_AETHER_AR_SPLAT_MAX_PX"],
       let v = Double(raw), v >= 2, v <= 200 {
      return CGFloat(v)
    }
    return 6
  }()

  /// Stringified `ARCamera.TrackingState` for the pose stream's
  /// `trackingStateName` field. Mirrors the enum 1:1 so the Dart side
  /// (PoseDriftTracker) can attribute degraded windows to a root cause
  /// without smuggling a Swift enum across the platform channel.
  ///
  /// `@unknown default` exists because Apple has added new
  /// `.limited(reason:)` cases between SDKs (e.g. relocalizing landed
  /// in iOS 11.3); falling through to "limited_unknown" is the
  /// forward-compatible behaviour rather than crashing.
  static func trackingStateString(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal:
      return "normal"
    case .notAvailable:
      return "not_available"
    case .limited(let reason):
      switch reason {
      case .initializing: return "limited_initializing"
      case .relocalizing: return "limited_relocalizing"
      case .excessiveMotion: return "limited_excessive_motion"
      case .insufficientFeatures: return "limited_insufficient_features"
      @unknown default: return "limited_unknown"
      }
    }
  }

  /// Pull the Y (luma) plane out of a YUV CVPixelBuffer and nearest-
  /// neighbour downsample it to a 128×128 uint8 thumbnail.
  ///
  /// This is the new shape of what used to be `computeQuality` — the
  /// Laplacian-variance + brightness + signature math has moved to
  /// `lib/quality/quality_compute.dart` so it can run identically on
  /// iOS / Android / Web / HarmonyOS without four separate ports.
  /// Native still does the platform-specific plane extraction (only
  /// way to get at the YUV buffer) but everything past that lives in
  /// shared Dart.
  ///
  /// Cost: ~2-3 ms on iPhone 12 Pro (down from ~5-15 ms of the full
  /// pre-Dart-port quality compute). Returns nil only when the pixel
  /// buffer isn't one of the BiPlanar YUV variants ARKit normally
  /// produces — caller treats nil as "skip this quality tick".
  ///
  /// Output is exactly 128×128 = 16384 bytes, row-major, top-left
  /// origin, ready to ship across the platform channel as a single
  /// FlutterStandardTypedData blob.
  static func extractGray128(_ pixelBuffer: CVPixelBuffer) -> Data? {
    return extractGray(pixelBuffer, targetSide: downsampleSide)
  }

  static func extractGray(
    _ pixelBuffer: CVPixelBuffer,
    targetSide: Int
  ) -> Data? {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isYUV =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard isYUV, targetSide > 0 else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
    else { return nil }
    let src = baseAddr.assumingMemoryBound(to: UInt8.self)

    let tw = targetSide
    let th = targetSide
    var data = Data(count: tw * th)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      let dst = raw.bindMemory(to: UInt8.self).baseAddress!
      // Fixed-point bilinear-step-and-pick (nearest-neighbour). Match
      // the math the previous Swift implementation used so the Dart
      // port's results are byte-identical with the old wire format
      // during the migration window.
      let sxFixed = (width << 16) / tw
      let syFixed = (height << 16) / th
      for dy in 0..<th {
        let srcY = (dy * syFixed) >> 16
        let srcRowOffset = srcY * rowStride
        let dstRowOffset = dy * tw
        for dx in 0..<tw {
          let srcX = (dx * sxFixed) >> 16
          dst[dstRowOffset + dx] = src[srcRowOffset + srcX]
        }
      }
    }
    return data
  }

  /// Aspect-preserving variant of `extractGray` for the streaming-SfM feed:
  /// scales the Y plane uniformly so the LONG edge equals `maxSide` (never
  /// upscales). Uniform scale keeps fx/fy shrinking by the same factor, which
  /// the SfM's single-focal SIMPLE_PINHOLE self-calibration requires — the
  /// square `extractGray` squash must NOT be used for SfM input.
  /// Output is row-major top-down 8-bit gray (CGImage convention), exactly
  /// what `aether_sfm_add_frame` consumes.
  static func extractGrayAspect(
    _ pixelBuffer: CVPixelBuffer,
    maxSide: Int
  ) -> (data: Data, width: Int, height: Int)? {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isYUV =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard isYUV, maxSide > 0 else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    guard width > 0, height > 0 else { return nil }
    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
    else { return nil }
    let src = baseAddr.assumingMemoryBound(to: UInt8.self)

    let longEdge = max(width, height)
    // Never upscale: uniform factor <= 1.
    let scaleNum = min(maxSide, longEdge)
    let tw = max(1, width * scaleNum / longEdge)
    let th = max(1, height * scaleNum / longEdge)
    var data = Data(count: tw * th)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      let dst = raw.bindMemory(to: UInt8.self).baseAddress!
      // Box-average (area) downsample — replaces the old nearest-neighbor
      // step-and-pick (2026-07-08). At the 3840→2000 live tier (~1.9× down)
      // nearest-neighbor kept only 1 of every ~3.7 source pixels and discarded
      // the rest, which aliased and — the real damage for photogrammetry —
      // erased the weak-texture gradients (bedsheets, flat detail) the SIFT DoG
      // detector needs, so those keypoints vanished and the live cloud thinned
      // (28k vs 49k at full-res). Averaging each destination pixel over its full
      // source block preserves those gradients so more real keypoints survive
      // the downscale. The dst blocks tile the source plane exactly, so this is
      // ONE pass over the source (~a few ms; detector is ~468 ms/frame — free).
      // COLMAP downsamples with a proper filter for the same reason; the
      // nearest-neighbor pick was the bug. Reduces to identity when tw==width
      // (no-downscale research tier), block size 1.
      for dy in 0..<th {
        let sy0 = dy * height / th
        var sy1 = (dy + 1) * height / th
        if sy1 <= sy0 { sy1 = sy0 + 1 }
        let dstRowOffset = dy * tw
        for dx in 0..<tw {
          let sx0 = dx * width / tw
          var sx1 = (dx + 1) * width / tw
          if sx1 <= sx0 { sx1 = sx0 + 1 }
          var sum = 0
          var cnt = 0
          var sy = sy0
          while sy < sy1 {
            let rowOff = sy * rowStride
            var sx = sx0
            while sx < sx1 {
              sum += Int(src[rowOff + sx])
              cnt += 1
              sx += 1
            }
            sy += 1
          }
          dst[dstRowOffset + dx] = UInt8(sum / cnt)
        }
      }

      // Photogrammetry preflight (2026-07-05, "微暗是常态"): percentile
      // contrast stretch so DIM indoor captures — the normal case — feed
      // the SIFT DoG detector at full contrast instead of starving it.
      // 2%..98% of the histogram maps to 0..255; bright scenes are near
      // identity (p2≈0, p98≈255), gain is capped at 8× so near-black
      // noise is never amplified into fake texture. One extra pass over
      // the buffer (~5 ms at 4K) — same normalization every frame, so the
      // shared-camera / consistent-appearance premise holds.
      let n = tw * th
      var hist = [Int](repeating: 0, count: 256)
      for i in 0..<n { hist[Int(dst[i])] += 1 }
      let lowCount = n / 50        // 2%
      let highCount = n - n / 50   // 98%
      var acc = 0
      var p2 = 0
      var p98 = 255
      for v in 0..<256 {
        acc += hist[v]
        if acc <= lowCount { p2 = v }
        if acc < highCount { p98 = v }
      }
      let span = max(32, p98 - p2)  // cap gain at ~8×
      if p2 > 0 || span < 250 {
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
          let stretched = (v - p2) * 255 / span
          lut[v] = UInt8(min(255, max(0, stretched)))
        }
        for i in 0..<n { dst[i] = lut[Int(dst[i])] }
      }
    }
    return (data, tw, th)
  }

  /// Build a small, color-sampled preview point payload from ARKit's
  /// official VIO feature cloud. This mirrors the RealityScan/Polycam
  /// capture-time idea at the executor boundary: native only exposes
  /// raw world-space points + sampled RGB; Dart performs multi-scale
  /// voxel hashing and UI policy.
  static func makePreviewPointPayload(
    frame: ARFrame,
    maxPoints: Int
  ) -> [String: Any] {
    guard maxPoints > 0, let raw = frame.rawFeaturePoints else {
      return [:]
    }
    let rawCount = raw.points.count
    guard rawCount > 0 else { return [:] }

    let pixelBuffer = frame.capturedImage
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return [:] }

    let step = max(1, rawCount / maxPoints)
    let viewport = CGSize(width: width, height: height)
    var xyz: [Float] = []
    var rgb: [Int] = []
    var confidence: [Float] = []
    xyz.reserveCapacity(min(maxPoints, rawCount) * 3)
    rgb.reserveCapacity(min(maxPoints, rawCount) * 3)
    confidence.reserveCapacity(min(maxPoints, rawCount))

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    for i in Swift.stride(from: 0, to: rawCount, by: step) {
      if confidence.count >= maxPoints { break }
      let p = raw.points[i]
      let projected = frame.camera.projectPoint(
        p,
        orientation: .landscapeRight,
        viewportSize: viewport
      )
      let x = Int(projected.x.rounded())
      let y = Int(projected.y.rounded())
      guard x >= 0, y >= 0, x < width, y < height else { continue }
      guard let color = sampleYuvRgbLocked(pixelBuffer, x: x, y: y) else {
        continue
      }
      xyz.append(p.x)
      xyz.append(p.y)
      xyz.append(p.z)
      rgb.append(Int(color.r))
      rgb.append(Int(color.g))
      rgb.append(Int(color.b))
      confidence.append(1.0)
    }

    if confidence.isEmpty { return [:] }
    return [
      "previewPointXYZ": xyz,
      "previewPointRGB": rgb,
      "previewPointConfidence": confidence,
      "previewPointSource": "arkit_rawFeaturePoints_voxel_preview",
    ]
  }

  private static func sampleYuvRgbLocked(
    _ pixelBuffer: CVPixelBuffer,
    x: Int,
    y: Int
  ) -> (r: UInt8, g: UInt8, b: UInt8)? {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isYUV =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard isYUV else { return nil }

    let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
    let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    guard x >= 0, y >= 0, x < yWidth, y < yHeight else { return nil }

    guard
      let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
      return nil
    }

    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
    let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)

    let uvX = min(max(x / 2, 0), max(uvWidth - 1, 0))
    let uvY = min(max(y / 2, 0), max(uvHeight - 1, 0))
    let yValue = Float(yPtr[y * yStride + x])
    let uvIndex = uvY * uvStride + uvX * 2
    let cb = Float(uvPtr[uvIndex]) - 128.0
    let cr = Float(uvPtr[uvIndex + 1]) - 128.0

    let r = yValue + 1.402 * cr
    let g = yValue - 0.344136 * cb - 0.714136 * cr
    let b = yValue + 1.772 * cb
    return (
      r: clampRgb(r),
      g: clampRgb(g),
      b: clampRgb(b)
    )
  }

  private static func clampRgb(_ value: Float) -> UInt8 {
    return UInt8(max(0, min(255, Int(value.rounded()))))
  }


  /// Downscale-decode a saved JPEG to `maxPx` (long edge) via ImageIO, no EXIF
  /// transform, packed RGB — the preview colorizer's per-frame sampler. Runs on
  /// colorizeQueue (see the decodeJpegForColor case), never the main thread.
  private func handleDecodeJpegForColor(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let path = args["jpegPath"] as? String else {
      result(FlutterError(code: "ar_decode_bad_args",
                          message: "decodeJpegForColor requires {jpegPath}",
                          details: nil))
      return
    }
    let maxPx = (args["maxPx"] as? Int) ?? 1280
    // No EXIF transform → raw sensor (landscape) orientation, matching the
    // gray fed to SfM and thus the keypoint coordinates.
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: false,
      kCGImageSourceThumbnailMaxPixelSize: maxPx,
    ]
    guard let src = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(
            src, 0, opts as CFDictionary) else {
      result(FlutterError(code: "ar_decode_failed",
                          message: "thumbnail decode failed: \(path)",
                          details: nil))
      return
    }
    let w = cg.width, h = cg.height
    guard w > 0, h > 0 else {
      result(FlutterError(code: "ar_decode_empty", message: "0-size",
                          details: nil))
      return
    }
    // Draw into a top-down RGBA8 bitmap (row 0 = top-left), then pack RGB.
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ok: Bool = rgba.withUnsafeMutableBytes { buf -> Bool in
      guard let ctx = CGContext(
              data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
              bytesPerRow: w * 4, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
      }
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok else {
      result(FlutterError(code: "ar_decode_ctx", message: "CGContext failed",
                          details: nil))
      return
    }
    var rgb = Data(count: w * h * 3)
    rgb.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) in
      let dst = d.bindMemory(to: UInt8.self).baseAddress!
      var si = 0, di = 0
      let px = w * h
      for _ in 0..<px {
        dst[di] = rgba[si]; dst[di + 1] = rgba[si + 1]; dst[di + 2] = rgba[si + 2]
        si += 4; di += 3
      }
    }
    result(["w": w, "h": h, "rgb": FlutterStandardTypedData(bytes: rgb)])
  }
}

// MARK: - EventChannel pose stream

@available(iOS 11.0, *)
private class OfficialPoseStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.sink = nil
    return nil
  }

  func send(_ payload: [String: Any]) {
    // EventChannel sinks must be invoked on the main thread (Flutter
    // platform thread). ARSessionDelegate callbacks fire on a
    // dedicated AR queue, so dispatch.
    if Thread.isMainThread {
      sink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?(payload)
      }
    }
  }
}

// MARK: - ARSessionDelegate forwarder
//
// We don't subclass ARSessionDelegate inside the plugin class because
// that pulls Objective-C inheritance into the Swift-only OfficialAetherARKitPlugin
// (would have to inherit NSObject + add @objc on every call). Cleaner
// to use a tiny forwarder.

@available(iOS 11.0, *)
private class OfficialARSessionForwarder: NSObject, ARSessionDelegate {
  var onFrame: ((ARFrame) -> Void)?
  var onSessionFailure: (() -> Void)?

  // Diagnostic state — log only on transitions, not every frame.
  private var loggedFirstFrame = false
  private var lastTrackingDescription: String = ""

  // ── ①【ARSession 帧监视 2026-07-11】帧到达间隔水位遥测 ──────────────
  // 44/45 号相机冻结:预览黑屏 ~2min,但没有任何"ARSession 断供"的一手
  // 证据(NSLog 拔线全丢)。这里补上:1s 看门狗计时器盯 didUpdate 的到达
  // 间隔,>1s 无新帧 → telemetry_official_native.jsonl 记一条 ar_frame_stall(带
  // gap_ms + thermal + 是否 interrupted),停摆期间每 10s 续记一条,恢复
  // 时记 ar_frame_resume(总 gap_ms)。低频水位事件,绝不逐帧写。
  // 线程模型:didUpdate 在 AR 专属队列,计时器在自己的 utility 队列 ——
  // 共享状态全部锁保护;didUpdate 热路径只做一次锁内赋值(纳秒级)。
  private let stallLock = NSLock()
  private var lastFrameAt: CFTimeInterval = 0
  private var stalledSince: CFTimeInterval = 0  // 0 = not stalled
  private var lastStallLogAt: CFTimeInterval = 0
  private var interrupted = false
  private var watchdog: DispatchSourceTimer?
  private let watchdogQueue = DispatchQueue(
    label: "com.pocketworld.official.arframe.watchdog",
    qos: .utility
  )

  private func startWatchdogIfNeeded() {
    watchdogQueue.async { [weak self] in
      guard let self = self, self.watchdog == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
      timer.schedule(deadline: .now() + 1, repeating: 1)
      timer.setEventHandler { [weak self] in self?.watchdogTick() }
      timer.resume()
      self.watchdog = timer
    }
  }

  /// ──【案③ 2026-07-11】主动停 ARSession(finish/stopSession)后解除
  /// 武装:pause 后没有帧本来就是预期,继续报 stall 全是假告警(46 号
  /// finish 后 54 条假 ar_frame_stall 污染遥测)。做法:清 lastFrameAt,
  /// watchdogTick 的 `last > 0` 门自然短路;下一帧真的到达时 didUpdate
  /// 重新填 lastFrameAt → 自动重新武装(恢复采集零额外调用)。
  func disarmStallWatchdog() {
    stallLock.lock()
    lastFrameAt = 0
    stalledSince = 0
    lastStallLogAt = 0
    stallLock.unlock()
    NSLog("[OfficialAetherARKit] frame-stall watchdog disarmed (session stopped)")
  }

  private func watchdogTick() {
    let now = CACurrentMediaTime()
    stallLock.lock()
    let last = lastFrameAt
    let wasStalled = stalledSince > 0
    let isInterrupted = interrupted
    var emit: (type: String, gapMs: Int)? = nil
    if last > 0, now - last > 1.0 {
      if !wasStalled {
        stalledSince = last
        lastStallLogAt = now
        emit = ("ar_frame_stall", Int((now - last) * 1000))
      } else if now - lastStallLogAt >= 10.0 {
        lastStallLogAt = now
        emit = ("ar_frame_stall", Int((now - last) * 1000))
      }
    }
    stallLock.unlock()
    if let e = emit {
      OfficialPwNativeTelemetry.shared.log(e.type, [
        "gap_ms": e.gapMs,
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        "interrupted": isInterrupted,
      ])
    }
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // [pw][vio] 必须是本方法的第一行:晚一行就多一行固定投递延迟,而 min-filter
    //   只能吃掉抖动,吃不掉你自己加进去的固定延迟。
    //   ⚠️ ARFrame.timestamp 的时钟域 Apple 全文未文档化(只有一句 "The time at
    //   which the frame was captured."),且 ARKit 不交出 CMSampleBuffer,
    //   synchronizationClock 那条换算桥在这条链上用不了 ⇒ 只能纯测量。
    PwVioTimebase.shared.noteARFrame(frame)
    // [pw][vio] 只把 CVPixelBuffer 引用放进有界 shadow 队列;降采样和
    //   XRSLAM 调用在 worker 上完成。feeder 未 start 时是空操作。
    _ = PwVioSlamFeeder.shared.enqueue(frame: frame)
    if !loggedFirstFrame {
      loggedFirstFrame = true
      NSLog("[OfficialAetherARKit] first ARFrame received")
      startWatchdogIfNeeded()
    }
    // 帧监视:恢复检测(热路径只碰锁一次;水位事件写盘走 telemetry 队列)。
    let now = CACurrentMediaTime()
    stallLock.lock()
    let stalledFrom = stalledSince
    lastFrameAt = now
    stalledSince = 0
    stallLock.unlock()
    if stalledFrom > 0 {
      OfficialPwNativeTelemetry.shared.log("ar_frame_resume", [
        "gap_ms": Int((now - stalledFrom) * 1000),
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
      ])
    }
    let desc: String
    switch frame.camera.trackingState {
    case .normal: desc = "normal"
    case .limited(let r): desc = "limited(\(r))"
    case .notAvailable: desc = "notAvailable"
    @unknown default: desc = "unknown"
    }
    if desc != lastTrackingDescription {
      lastTrackingDescription = desc
      NSLog("[OfficialAetherARKit] trackingState → \(desc)")
    }
    onFrame?(frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    PwVioTimebase.shared.suspendShadowPipeline()
    NSLog("[OfficialAetherARKit] ARSession failed: \(error.localizedDescription)")
    OfficialPwNativeTelemetry.shared.log("ar_session_failed", [
      "error": error.localizedDescription,
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
    onSessionFailure?()
  }

  func sessionWasInterrupted(_ session: ARSession) {
    PwVioTimebase.shared.suspendShadowPipeline()
    NSLog("[OfficialAetherARKit] ARSession interrupted")
    stallLock.lock()
    interrupted = true
    stallLock.unlock()
    OfficialPwNativeTelemetry.shared.log("ar_interrupted", [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    NSLog("[OfficialAetherARKit] ARSession interruption ended")
    stallLock.lock()
    interrupted = false
    stallLock.unlock()
    OfficialPwNativeTelemetry.shared.log("ar_interruption_ended", [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
    PwVioTimebase.shared.resumeShadowPipeline()
  }

  deinit {
    watchdog?.cancel()
  }
}

// MARK: - ARKit preview platform view (verbatim port of
// ObjectModeV2ARKitPreview.swift — UIViewRepresentable → FlutterPlatformView).
//
// Defined in this file (rather than its own) so the Runner.xcodeproj
// pickup is automatic — the project only compiles files that are
// already listed in the project's PBXFileReference list, and adding
// new sources programmatically requires pbxproj surgery we'd rather
// avoid. OfficialAetherARKitPlugin.swift is already in the project; piggyback.

@available(iOS 11.0, *)
class OfficialAetherARKitPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let getSession: () -> ARSession?

  init(getSession: @escaping () -> ARSession?) {
    self.getSession = getSession
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return OfficialAetherARKitPreviewView(frame: frame, getSession: getSession)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Capture-only adaptive point budget.
///
/// The full progressive cloud remains resident. Lower tiers are strict
/// prefixes of the Potree-style octree order prepared by Dart, so a tier
/// change never reshuffles surviving points. Decisions use a smoothed render
/// cadence, thermal pressure, two-second decision windows, and a long upgrade
/// hysteresis; the final PLY and Review viewer never pass through this class.
private final class CapturePointCloudLodController {
  private let fractions = [1.0, 0.67, 0.40, 0.25]
  private var tier = 0
  private var lastFrameTime: TimeInterval?
  private var smoothedFrameSeconds = 1.0 / 30.0
  private var lastDecisionTime: TimeInterval = 0
  private var healthySince: TimeInterval?

  func reset(totalPoints: Int) -> Int {
    lastFrameTime = nil
    healthySince = nil
    // Small clouds are cheaper than rebuilding a lower tier.
    if totalPoints <= 24_000 { tier = 0 }
    return renderCount(totalPoints: totalPoints)
  }

  func renderCount(totalPoints: Int) -> Int {
    guard totalPoints > 0 else { return 0 }
    if totalPoints <= 24_000 { return totalPoints }
    let fraction = fractions[min(tier, fractions.count - 1)]
    return min(totalPoints, max(12_000, Int((Double(totalPoints) * fraction).rounded(.up))))
  }

  /// Returns a new prefix size only when the stable tier actually changes.
  func observeFrame(time: TimeInterval, totalPoints: Int) -> Int? {
    defer { lastFrameTime = time }
    guard totalPoints > 24_000, let previous = lastFrameTime else { return nil }
    let dt = time - previous
    guard dt > 0, dt < 0.25 else { return nil }
    smoothedFrameSeconds = smoothedFrameSeconds * 0.92 + dt * 0.08
    guard time - lastDecisionTime >= 2.0 else { return nil }
    lastDecisionTime = time

    let fps = 1.0 / max(smoothedFrameSeconds, 1.0 / 120.0)
    let thermal = ProcessInfo.processInfo.thermalState
    let oldTier = tier

    switch thermal {
    case .critical:
      tier = max(tier, 3)
      healthySince = nil
    case .serious:
      tier = max(tier, 2)
      healthySince = nil
    case .nominal, .fair:
      if fps < 24.0 {
        tier = min(tier + 1, fractions.count - 1)
        healthySince = nil
      } else if fps >= 28.5 {
        if healthySince == nil { healthySince = time }
        // Upgrades need a long healthy window; downgrades react in one window.
        if tier > 0, time - (healthySince ?? time) >= 8.0 {
          tier -= 1
          healthySince = time
        }
      } else {
        healthySince = nil
      }
    @unknown default:
      healthySince = nil
    }

    guard tier != oldTier else { return nil }
    let count = renderCount(totalPoints: totalPoints)
    OfficialPwNativeTelemetry.shared.log("capture_point_lod", [
      "from_tier": oldTier,
      "to_tier": tier,
      "render_points": count,
      "source_points": totalPoints,
      "fps_ewma": (fps * 10).rounded() / 10,
      "thermal": thermal.rawValue,
    ])
    return count
  }
}

@available(iOS 11.0, *)
class OfficialAetherARKitPreviewView: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  private let arscnView: ARSCNView
  private let getSession: () -> ARSession?
  private var pollTimer: Timer?

  // ── Subject marker (Remy-style locked-origin visualization) ────────
  //
  // Kept post-SAM-revert for ongoing validation: user wanted more
  // capture sessions before deciding whether the marker is signal or
  // noise. Mechanism: lockOrigin installs the named
  // `pocketworld_official_subject_origin` ARAnchor → ARKit fires
  // `renderer(_:didAdd:for:)` with an auto-managed SCNNode whose
  // transform tracks the anchor across ARKit world-frame
  // re-alignments. We attach a 3 cm white sphere as a CHILD of that
  // node — SceneKit hierarchy propagates ARKit's transform updates
  // automatically. WWDC 2018 §610 + Polycam polyform pattern.
  //
  // writesToDepthBuffer=false renders the sphere OVER any geometry —
  // diagnostic, not scene element. If the dot sits "behind" the
  // subject visually, the user sees that the lock missed.
  private static let subjectMarkerRadius: CGFloat = 0.03 // 3 cm
  private static let subjectAnchorName = "pocketworld_official_subject_origin"

  // ── 照片卡距离补偿缩放 ────────────────────────────────────────
  // photoCardNodes holds the per-card CONTAINER node we scale.
  private var photoCardNodes: [String: SCNNode] = [:]
  /// 距离锚点 d0:d ≤ d0 时卡片就是一块世界里的实体板(scale=1,纯透视,
  /// 视觉大小 ∝ 1/d);d > d0 才开始按 β 衰减补偿。
  private static let photoCardDistanceAnchorM: Float = 1.0
  /// 补偿指数 β:视觉大小 ∝ d^(β-1)。0.5=签决默认(远处衰减减半);
  /// 0=纯透视;1=恒定屏幕大小(billboard 感,不要)。真机调参常量。
  private static let photoCardDistanceBeta: Float = 0.5

  /// 四态边框材质(name → [边框环材质, 背板材质]),didAdd 登记、
  /// didRemove 清理;applyPhotoCardStatesIfDirty 在渲染线程按 Dart 推的
  /// 状态刷 diffuse 颜色。
  private var photoCardStateMats: [String: [SCNMaterial]] = [:]

  /// Dumb state→colour map(policy lives in Dart, photo_card_state.dart):
  /// 0 黑=SfM 未处理 / 1 白=已注册 / 2 红=断联 / 3 黄=已注册但低视差。
  private static func photoCardStateColor(_ state: Int) -> UIColor {
    switch state {
    case 1: return .white
    case 2: return .systemRed
    case 3: return .systemYellow
    default: return .black
    }
  }

  // ── Capture sparse cloud: full resident data + stable dynamic LOD ─────────
  // Dart sends a complete Potree-style progressive octree order. Native keeps
  // the full display copy resident and draws one SceneKit point batch. Under
  // sustained render/thermal pressure only the prefix budget
  // changes; final PLY and Review are outside this display path.
  private var pointCloudNode: SCNNode?
  private var fullPointCloudXyz: [Float] = []
  private var fullPointCloudRgb: [UInt8] = []
  private var pointCloudTransform = matrix_identity_float4x4
  private let pointCloudLod = CapturePointCloudLodController()
  private var renderedPointCount = 0
  private var liveCloudRenderApplySequence = 0

  /// Render-loop tick: apply the latest Dart-pushed cloud when it changed.
  /// Toggled off → tear the node down.
  private func updateFeaturePointOverlay(at time: TimeInterval) {
    if !OfficialAetherARKitPlugin.featurePointsVisible {
      if pointCloudNode != nil {
        pointCloudNode?.removeFromParentNode()
        pointCloudNode = nil
      }
      renderedPointCount = 0
      if let dropped = OfficialAetherARKitPlugin.takeCoverageCloudIfDirty() {
        pointCloudTransform = dropped.transform
        let m = dropped.metadata
        OfficialPwNativeTelemetry.shared.log("live_cloud_render_drop_v1", [
          "contract": m.contract,
          "source_receive_seq": m.sourceReceiveSequence,
          "receive_seq": m.receiveSequence,
          "channel_push_seq": m.channelPushSequence,
          "source": m.source,
          "publish_version": m.publishVersion,
          "points": m.pointCount,
          "reason": "hidden",
          "observation_only": true,
        ])
      }
      return
    }
    if let cloud = OfficialAetherARKitPlugin.takeCoverageCloudIfDirty() {
      fullPointCloudXyz = cloud.xyz
      fullPointCloudRgb = cloud.rgb
      pointCloudTransform = cloud.transform
      let totalPoints = fullPointCloudXyz.count / 3
      renderedPointCount = pointCloudLod.reset(totalPoints: totalPoints)
      rebuildPointCloud(renderCount: renderedPointCount)
      liveCloudRenderApplySequence += 1
      let m = cloud.metadata
      OfficialPwNativeTelemetry.shared.log("live_cloud_render_v1", [
        "contract": m.contract,
        "source_receive_seq": m.sourceReceiveSequence,
        "receive_seq": m.receiveSequence,
        "channel_push_seq": m.channelPushSequence,
        "render_apply_seq": liveCloudRenderApplySequence,
        "source": m.source,
        "publish_version": m.publishVersion,
        "declared_points": m.pointCount,
        "received_points": totalPoints,
        "rendered_points": renderedPointCount,
        "receive_t": m.receiveEpochMs,
        "compute_done_t": m.computeDoneEpochMs,
        "observation_only": true,
      ])
      OfficialPwNativeTelemetry.shared.log("live_cloud_render_v2", [
        "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
        "source_receive_seq": m.sourceReceiveSequence,
        "receive_seq": m.receiveSequence,
        "channel_push_seq": m.channelPushSequence,
        "render_apply_seq": liveCloudRenderApplySequence,
        "source": m.source,
        "publish_version": m.publishVersion,
        "declared_points": m.pointCount,
        "received_points": totalPoints,
        "rendered_points": renderedPointCount,
        "receive_t": m.receiveEpochMs,
        "compute_done_t": m.computeDoneEpochMs,
        "observation_only": true,
      ])
    }
    let totalPoints = fullPointCloudXyz.count / 3
    if let nextCount = pointCloudLod.observeFrame(
      time: time,
      totalPoints: totalPoints
    ), nextCount != renderedPointCount {
      renderedPointCount = nextCount
      rebuildPointCloud(renderCount: nextCount)
    }
  }

  private func rebuildPointCloud(renderCount: Int) {
    let available = min(fullPointCloudXyz.count / 3, fullPointCloudRgb.count / 3)
    let n = min(max(0, renderCount), available)
    guard n > 0 else {
      pointCloudNode?.removeFromParentNode()
      pointCloudNode = nil
      return
    }
    // Stable nested LOD: every lower tier is a prefix of the higher tier.
    let xyz = Array(fullPointCloudXyz.prefix(renderCount * 3))
    let rgb = Array(fullPointCloudRgb.prefix(renderCount * 3))
    var verts: [SCNVector3] = []
    var colors: [SIMD4<Float>] = []
    verts.reserveCapacity(n)
    colors.reserveCapacity(n)
    for i in 0..<n {
      verts.append(SCNVector3(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]))
      colors.append(SIMD4<Float>(
        Float(rgb[i * 3]) / 255.0,
        Float(rgb[i * 3 + 1]) / 255.0,
        Float(rgb[i * 3 + 2]) / 255.0,
        1.0))
    }
    let vSource = SCNGeometrySource(vertices: verts)
    let cData = colors.withUnsafeBytes { Data($0) }
    let cSource = SCNGeometrySource(
      data: cData, semantic: .color, vectorCount: colors.count,
      usesFloatComponents: true, componentsPerVector: 4,
      bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
      dataStride: MemoryLayout<SIMD4<Float>>.stride)
    let element = SCNGeometryElement(
      indices: (0..<verts.count).map { Int32($0) }, primitiveType: .point)
    // [SPLAT-RADIUS 2026-07-28] 实验臂:近处点径上限。SceneKit 的 pointSize
    // 是**世界单位**,min/max ScreenSpaceRadius 把投影后的像素半径钳在区间内
    // —— 即"1/深度 透视自适应 + 钳制",与 Potree 的出货配方同构
    // (`pointSize = size * spacing * projFactor` 后 clamp)。
    //
    // 病灶:上限 6px 把近处点焊死在小圆点,表面永远糊不成片。参照:Potree
    // 出货推荐 clamp(2, 50);RS 手机端截图取证近端实测 7-11px(我们上限
    // 6px 连它的下沿都够不到)。⇒ 放开上限是唯一"一行见效"的动作。
    //
    // 纯渲染:点数据一个字节不动,几何/交付/导出全不受影响。
    // 档案:project_pocketworld_pointcloud_rendering_audit(记忆库)。
    element.pointSize = 6
    element.minimumPointScreenSpaceRadius = 2
    element.maximumPointScreenSpaceRadius =
      OfficialAetherARKitPlugin.arSplatMaxScreenRadius
    let geo = SCNGeometry(sources: [vSource, cSource], elements: [element])
    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = UIColor.white      // × per-vertex colour
    mat.writesToDepthBuffer = false
    mat.readsFromDepthBuffer = false
    geo.materials = [mat]
    if let node = pointCloudNode {
      node.geometry = geo
      node.simdTransform = pointCloudTransform
    } else {
      let node = SCNNode(geometry: geo)
      node.simdTransform = pointCloudTransform
      node.renderingOrder = -10               // render under the photo cards
      arscnView.scene.rootNode.addChildNode(node)
      pointCloudNode = node
    }
  }

  init(frame: CGRect, getSession: @escaping () -> ARSession?) {
    self.arscnView = ARSCNView(frame: frame)
    self.getSession = getSession
    super.init()
    arscnView.automaticallyUpdatesLighting = true
    arscnView.scene = SCNScene()         // empty scene — camera feed only
    arscnView.rendersContinuously = true
    // [热税刀② 2026-08-10 实验臂] 同一开关下渲染帧率也砍半(点云/卡片
    // 显示层,不进重建)。默认不存在=零变化。
    if ProcessInfo.processInfo.environment["OFFICIAL_AETHER_AR_30FPS"] == "1" {
      arscnView.preferredFramesPerSecond = 30
    }
    arscnView.preferredFramesPerSecond = 30
    arscnView.antialiasingMode = .none
    arscnView.delegate = self
    attachSessionIfReady()
  }

  func view() -> UIView {
    return arscnView
  }

  /// OfficialAetherARKitPlugin creates the ARSession lazily on `startSession`,
  /// which the Dart side does inside CaptureSession.attach(). The
  /// preview widget can be in the tree before attach() runs, so we
  /// poll briefly until the session shows up.
  ///
  /// We deliberately do NOT install `ARCoachingOverlayView` here —
  /// CapturePage's own "AR warmup" gate (1500 ms continuous
  /// trackingState == .normal before enabling the lock button) covers
  /// the same user-guidance role and is cross-platform (Android /
  /// HarmonyOS / Web each get the same widget). Polycam's UX runs
  /// effectively the same shape with their own widget — same path,
  /// our wrapper.
  private func attachSessionIfReady() {
    if let session = getSession() {
      arscnView.session = session
      NSLog("[OfficialAetherARKitPreview] attached to ARSession on first try")
      return
    }
    pollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.05, repeats: true
    ) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      if let session = self.getSession() {
        self.arscnView.session = session
        NSLog("[OfficialAetherARKitPreview] attached to ARSession after poll")
        timer.invalidate()
        self.pollTimer = nil
      }
    }
  }

  // MARK: ARSCNViewDelegate

  /// Fires when ARKit adds an anchor to the session. ARSCNView creates
  /// the parent SCNNode for us; we attach a child sphere if this is OUR
  /// subject anchor (filtered by name to ignore plane anchors that
  /// `planeDetection = [.horizontal]` adds automatically).
  func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    // Subject-origin anchor: no visible marker.
    // Photo-card anchors: build a CUSTOM QUAD whose 4 corners are the unprojected
    // viewport corners (so it pixel-aligns with the live view at capture). The
    // texture is normalized to upright portrait (uprightPortrait) then aspect-
    // filled with top-left-origin UVs. World-anchored, it "peels off the lens"
    // as the camera moves. No orientation/size tuning.
    guard let name = anchor.name, name.hasPrefix("official_photo_card_") else { return }
    NSLog("[PHOTOCARD] renderer didAdd %@", name)
    guard let spec = OfficialAetherARKitPlugin.photoCardSpecs[name] else {
      NSLog("[PHOTOCARD] renderer: spec MISSING for %@", name)
      return
    }
    // LOW-RES AR texture (RS-style memory saver). Decode a small thumbnail
    // DIRECTLY from the 4K JPEG via ImageIO — it never decodes the full frame,
    // so each floating card holds a ~1 MB texture instead of ~33 MB and hundreds
    // of cards won't OOM. The album + DA3/SfM still read the full-res 4K JPEG on
    // disk; only the AR card is downscaled. kCGImageSource…WithTransform bakes the
    // EXIF orientation → upright portrait (replaces the manual uprightPortrait).
    let thumbOpts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: OfficialAetherARKitPlugin.photoCardThumbMaxPx,
    ]
    guard let imgSrc = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: spec.texturePath) as CFURL, nil),
          let thumbCG = CGImageSourceCreateThumbnailAtIndex(
            imgSrc, 0, thumbOpts as CFDictionary) else {
      // [瞬时快门] 12MP 静照后台落盘,文件可能还没写完 → 解码读空。卡片
      // 锚点/几何已建好(贴镜头),只差纹理;每 150ms 重试直到落盘(最多
      // 30 次~4.5s)。位姿/几何在 spec 里,重试不动位姿。
      // 2026-09-08:**先把黑色相框立起来**,再去等贴图。
      // 用户报"震动和黑色相框之间有明显延迟",实测中位 2090 ms(1269–8020)。
      // 根因:build 116 把震动提前到 ARFrame 到手(照片物理存在的那一刻),
      // 而预览 JPEG 要等 jpegEncodeQueue 写完才落盘 —— 这个 guard 在解不出
      // 缩略图时**直接 return**,于是边框环/背板/照片面一个都还没建,卡片要
      // 等文件写完才第一次出现。上面那段注释说"锚点/几何已建好,只差纹理",
      // 代码并不是这么做的。
      // 相框(黑边框环 + 不透明背板 + 正面黑填充)一个像素都不需要照片,
      // 所以立刻建;照片面等贴图解出来再换上。不新增任何常数:重试节奏
      // 仍是既有的 150 ms × 30 次。
      if photoCardNodes[name] == nil {
        buildPhotoCardShell(corners: spec.localCorners,
                            evidencePath: spec.evidencePath,
                            name: name, on: node)
      }
      let tries = OfficialAetherARKitPlugin.photoCardThumbRetries[name, default: 0]
      if tries < 30 {
        OfficialAetherARKitPlugin.photoCardThumbRetries[name] = tries + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak node] in
          guard let self, let node else { return }
          self.renderer(renderer, didAdd: node, for: anchor)
        }
      } else {
        NSLog("[PHOTOCARD] renderer: thumbnail decode FAILED (gave up) for %@", name)
        OfficialAetherARKitPlugin.photoCardThumbRetries.removeValue(forKey: name)
      }
      return
    }
    OfficialAetherARKitPlugin.photoCardThumbRetries.removeValue(forKey: name)
    let image = UIImage(cgImage: thumbCG)   // upright portrait, ~thumb px long edge
    NSLog("[PHOTOCARD] renderer building quad for %@ (%d corners) thumb=%dx%d",
          name, spec.localCorners.count, thumbCG.width, thumbCG.height)
    let c = spec.localCorners
    let quadW = CGFloat(simd_length(simd_float3(
      c[1].x - c[0].x, c[1].y - c[0].y, c[1].z - c[0].z)))   // TL->TR
    let quadH = CGFloat(simd_length(simd_float3(
      c[3].x - c[0].x, c[3].y - c[0].y, c[3].z - c[0].z)))   // TL->BL
    let texAspect = image.size.height > 0
      ? image.size.width / image.size.height : 0.75
    let quadAspect = quadH > 0 ? quadW / quadH : 0.46
    var u0: CGFloat = 0, u1: CGFloat = 1, v0: CGFloat = 0, v1: CGFloat = 1
    if texAspect > quadAspect {            // texture relatively wider → crop width
      let f = quadAspect / texAspect; u0 = (1 - f) / 2; u1 = 1 - u0
    } else {                               // texture relatively taller → crop height
      let f = texAspect / quadAspect; v0 = (1 - f) / 2; v1 = 1 - v0
    }
    let texUVs = [CGPoint(x: u0, y: v0), CGPoint(x: u1, y: v0),
                  CGPoint(x: u1, y: v1), CGPoint(x: u0, y: v1)]   // TL,TR,BR,BL
    NSLog("[PHOTOCARD] tex thumb=%.0fx%.0f texAsp=%.3f quadAsp=%.3f",
          image.size.width, image.size.height, texAspect, quadAspect)

    let positionSource = SCNGeometrySource(vertices: spec.localCorners)
    let texSource = SCNGeometrySource(textureCoordinates: texUVs)
    let element = SCNGeometryElement(indices: [Int32]([0, 1, 2, 0, 2, 3]),
                                     primitiveType: .triangles)
    let geometry = SCNGeometry(sources: [positionSource, texSource],
                               elements: [element])
    let mat = SCNMaterial()
    mat.diffuse.contents = image
    mat.isDoubleSided = false            // photo on the CAPTURE-FACING side only
    mat.cullMode = .front                // = the exact face the double-sided card
                                         // showed toward the camera (unchanged view)
    mat.lightingModel = .constant       // unlit — show the photo as captured
    mat.transparency = 0.7              // RS-style translucent (more see-through)
    mat.writesToDepthBuffer = false
    mat.diffuse.wrapS = .clamp
    mat.diffuse.wrapT = .clamp
    geometry.materials = [mat]

    // 相框已经立起来了(上面的占位路径)⇒ 只把正面的黑填充换成照片,
    // 边框/背板/四态材质都不重建,位姿几何一动不动。
    if let shell = photoCardNodes[name] {
      photoCardFrontFill[name]?.removeFromParentNode()
      photoCardFrontFill.removeValue(forKey: name)
      shell.addChildNode(SCNNode(geometry: geometry))
      OfficialPwNativeTelemetry.shared.log("photocard_photo_in", ["name": name])
      NSLog("[PHOTOCARD] renderer: photo swapped into standing shell for %@", name)
      return
    }

    // OPAQUE BACK: same quad, rendered only from the AWAY side (cullMode
    // .back = the face opposite the photo), so orbiting behind the card shows a
    // solid panel instead of the see-through/mirrored photo. Colour follows the
    // border's four-state rule (black→white/red/yellow via setPhotoCardStates).
    let backGeo = SCNGeometry(sources: [positionSource], elements: [element])
    let backMat = SCNMaterial()
    backMat.diffuse.contents = UIColor.black
    backMat.isDoubleSided = false
    backMat.cullMode = .back             // the face opposite the photo (away side)
    backMat.lightingModel = .constant
    backMat.transparency = 1.0           // opaque
    backMat.writesToDepthBuffer = false
    backGeo.materials = [backMat]

    // RS-style FRAME: the four-state border RING around the photo. Starts
    // BLACK (= SfM pending); Dart's judgement (photo_card_state.dart) flips it
    // white (registered) / red (disconnected) / yellow (low parallax) via the
    // setPhotoCardStates channel — applied in applyPhotoCardStatesIfDirty.
    // Built as a hollow ring (inner edge == photo edge, outer == +12%) so
    // it never overlaps the photo (no z-fight, no darkening of the image).
    let inner = spec.localCorners
    let outer = inner.map { SCNVector3($0.x * 1.12, $0.y * 1.12, $0.z * 1.12) }  // 4× the original 3% — 边框加粗一倍(签决:四态颜色要醒目)
    let frameVerts = inner + outer                       // 0-3 inner, 4-7 outer
    let frameIdx: [Int32] = [4, 5, 1, 4, 1, 0,           // top edge
                             5, 6, 2, 5, 2, 1,           // right edge
                             6, 7, 3, 6, 3, 2,           // bottom edge
                             7, 4, 0, 7, 0, 3]           // left edge
    let frameGeo = SCNGeometry(
      sources: [SCNGeometrySource(vertices: frameVerts)],
      elements: [SCNGeometryElement(indices: frameIdx, primitiveType: .triangles)])
    let frameMat = SCNMaterial()
    frameMat.diffuse.contents = UIColor.black
    frameMat.isDoubleSided = true
    frameMat.lightingModel = .constant
    frameMat.transparency = 0.95
    frameMat.writesToDepthBuffer = false
    frameGeo.materials = [frameMat]

    // Wrap border + photo in a CONTAINER we scale per-frame (renderer:updateAtTime)
    // for the deliberate distance shrink. Container origin == anchor centroid, so
    // scaling shrinks the card toward its own centre without moving it.
    let container = SCNNode()
    container.addChildNode(SCNNode(geometry: frameGeo))   // border behind/around
    container.addChildNode(SCNNode(geometry: backGeo))    // opaque back panel
    container.addChildNode(SCNNode(geometry: geometry))   // photo on the front
    node.addChildNode(container)
    photoCardNodes[name] = container
    // 四态边框:登记环+背板材质,并立刻套用 Dart 已推过的状态(卡片
    // 节点可能晚于状态到达 —— didAdd 是异步回调)。
    photoCardStateMats[name] = [frameMat, backMat]
    let initialState = OfficialAetherARKitPlugin.photoCardState(
      forPath: spec.evidencePath
    )
    if initialState != 0 {
      let c = Self.photoCardStateColor(initialState)
      frameMat.diffuse.contents = c
      backMat.diffuse.contents = c
    }
  }

  /// 正面黑填充节点(照片解出来后被换掉);key = anchor name。
  /// 与 photoCardNodes 同生命周期,故同为实例成员。
  private var photoCardFrontFill: [String: SCNNode] = [:]

  /// 立起「黑色相框」——**不需要照片的那三件**:黑边框环、不透明背板、
  /// 正面黑填充。位姿/几何全部来自 spec,与带照片的那条路径逐字同源,
  /// 所以照片换上时卡片不会跳动。
  ///
  /// 为什么要有这个:用户底线是「震动和黑色相框同时出现」。震动发在照片
  /// 物理存在那一刻(ARFrame 到手),而预览 JPEG 还要等后台编码落盘 ——
  /// 相框一个像素都不依赖那个文件,没有理由一起等。
  private func buildPhotoCardShell(
    corners: [SCNVector3],
    evidencePath: String,
    name: String,
    on node: SCNNode
  ) {
    let positionSource = SCNGeometrySource(vertices: corners)
    let element = SCNGeometryElement(indices: [Int32]([0, 1, 2, 0, 2, 3]),
                                     primitiveType: .triangles)

    // 正面黑填充:占住照片的位置,解出贴图后被移除换成照片面。
    // 参数与照片材质逐项对齐(cullMode/lighting/transparency/depth),
    // 这样换上照片时只有内容变、形态不变。
    let fillGeo = SCNGeometry(sources: [positionSource], elements: [element])
    let fillMat = SCNMaterial()
    fillMat.diffuse.contents = UIColor.black
    fillMat.isDoubleSided = false
    fillMat.cullMode = .front
    fillMat.lightingModel = .constant
    fillMat.transparency = 0.7
    fillMat.writesToDepthBuffer = false
    fillGeo.materials = [fillMat]

    let backGeo = SCNGeometry(sources: [positionSource], elements: [element])
    let backMat = SCNMaterial()
    backMat.diffuse.contents = UIColor.black
    backMat.isDoubleSided = false
    backMat.cullMode = .back
    backMat.lightingModel = .constant
    backMat.transparency = 1.0
    backMat.writesToDepthBuffer = false
    backGeo.materials = [backMat]

    let inner = corners
    let outer = inner.map { SCNVector3($0.x * 1.12, $0.y * 1.12, $0.z * 1.12) }
    let frameVerts = inner + outer
    let frameIdx: [Int32] = [4, 5, 1, 4, 1, 0,
                             5, 6, 2, 5, 2, 1,
                             6, 7, 3, 6, 3, 2,
                             7, 4, 0, 7, 0, 3]
    let frameGeo = SCNGeometry(
      sources: [SCNGeometrySource(vertices: frameVerts)],
      elements: [SCNGeometryElement(indices: frameIdx, primitiveType: .triangles)])
    let frameMat = SCNMaterial()
    frameMat.diffuse.contents = UIColor.black
    frameMat.isDoubleSided = true
    frameMat.lightingModel = .constant
    frameMat.transparency = 0.95
    frameMat.writesToDepthBuffer = false
    frameGeo.materials = [frameMat]

    let container = SCNNode()
    container.addChildNode(SCNNode(geometry: frameGeo))
    container.addChildNode(SCNNode(geometry: backGeo))
    let fillNode = SCNNode(geometry: fillGeo)
    container.addChildNode(fillNode)
    node.addChildNode(container)
    photoCardNodes[name] = container
    photoCardFrontFill[name] = fillNode
    photoCardStateMats[name] = [frameMat, backMat]
    let initialState = OfficialAetherARKitPlugin.photoCardState(
      forPath: evidencePath
    )
    if initialState != 0 {
      let c = Self.photoCardStateColor(initialState)
      frameMat.diffuse.contents = c
      backMat.diffuse.contents = c
    }
    // 2026-09-08:这两个时刻此前**只有 NSLog**,电脑侧读不到 —— 用户不得不
    // 用眼睛替我当传感器("震动和黑框是几乎同时出现")。落成可读遥测。
    OfficialPwNativeTelemetry.shared.log("photocard_shell_up", ["name": name])
    NSLog("[PHOTOCARD] shell up (black frame, photo pending) for %@", name)
  }

  /// Per-frame: distance-compensated scaling for the floating photo cards +
  /// four-state border colour application. Cheap: one distance + scale per
  /// card per frame (~百级节点一次 sqrt 可忽略), all on the SceneKit render
  /// thread.
  /// 待落世界锚期间挂在相机上的卡片容器(名字 → 挂点)。
  private var photoCardCameraHolders: [String: SCNNode] = [:]

  /// 每帧两件事(都只在有待落锚卡片时才有开销):
  /// ① 还没有节点的待落锚卡片 —— **立刻**挂到相机前 z 处建出来,所以「震动 →
  ///    黑相框」的 35 ms 一点没变;几何用**相机坐标系**的角点(±halfX, ±halfY, 0),
  ///    不能用 spec.localCorners(那是世界朝向的,挂到相机上会被相机旋转叠加一次)。
  /// ② 地图一转 extending/mapped 就迁到世界锚:摘掉挂相机那份,`session.add`,
  ///    随后走正常的 didAdd 路径按拍摄时的世界位姿重建 —— 形态复原、位置就是
  ///    照片拍摄处。
  private func servicePendingPhotoCardAnchors(_ renderer: SCNSceneRenderer) {
    let pending = OfficialAetherARKitPlugin.photoCardPendingAnchors
    guard !pending.isEmpty else { return }
    if let pov = renderer.pointOfView {
      for (name, p) in pending where photoCardCameraHolders[name] == nil {
        let holder = SCNNode()
        holder.position = SCNVector3(0, 0, -p.z)
        pov.addChildNode(holder)
        photoCardCameraHolders[name] = holder
        let c: [SCNVector3] = [
          SCNVector3(-p.halfX,  p.halfY, 0),   // TL
          SCNVector3( p.halfX,  p.halfY, 0),   // TR
          SCNVector3( p.halfX, -p.halfY, 0),   // BR
          SCNVector3(-p.halfX, -p.halfY, 0),   // BL
        ]
        buildPhotoCardShell(corners: c, evidencePath: p.evidencePath,
                            name: name, on: holder)
      }
    }
    guard let status = arscnView.session.currentFrame?.worldMappingStatus,
          status == .extending || status == .mapped else { return }
    for (name, p) in pending {
      photoCardCameraHolders[name]?.removeFromParentNode()
      photoCardCameraHolders.removeValue(forKey: name)
      photoCardNodes.removeValue(forKey: name)
      photoCardStateMats.removeValue(forKey: name)
      photoCardFrontFill.removeValue(forKey: name)
      OfficialAetherARKitPlugin.photoCardThumbRetries.removeValue(forKey: name)
      arscnView.session.add(anchor: p.anchor)
      OfficialPwNativeTelemetry.shared.log("photocard_anchor_migrated", [
        "name": name,
        "waited_ms": Int((CACurrentMediaTime() - p.since) * 1000.0),
        "world_mapping_status": status.rawValue,
      ])
      // **只删迁移过的这一个**。`pending` 是这一帧开头的快照;若用
      // removeAll(),本帧内新进来的卡片会被静默丢掉 —— 那张就永远拿不到
      // 世界锚,而且没有任何痕迹(正是「静默出口」那类缺陷)。
      OfficialAetherARKitPlugin.photoCardPendingAnchors.removeValue(forKey: name)
    }
  }

  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    OfficialPwNativeTelemetry.shared.noteRenderFrame()  // 遥测 F:FPS 计帧(纳秒级)
    servicePendingPhotoCardAnchors(renderer)
    updateFeaturePointOverlay(at: time) // stable dynamic LOD; independent of cards
    applyPhotoCardStatesIfDirty()  // 四态边框:消费 Dart 推来的状态差量
    guard !photoCardNodes.isEmpty, let cam = renderer.pointOfView else { return }
    let camPos = cam.simdWorldPosition
    for card in photoCardNodes.values {
      // RS 复刻显示开关:逐帧幂等套用可见性 —— 隐藏期新建的卡片下一帧即
      // 隐藏,重开下一帧全量回显,无需遍历时机协调。
      card.isHidden = !OfficialAetherARKitPlugin.photoCardsVisible
      // 距离补偿缩放(签决,常量注释见 photoCardDistanceBeta):
      // d ≤ d0(1m)→ scale=1 保持原透视;d > d0 → scale=(d/d0)^β,
      // 视觉大小 ∝ d^(β-1)=d^-0.5 —— 近大远小保持、远处衰减变缓,
      // 无最小尺寸下限(100m 处可以小到 1 像素,继续缩)。
      //
      // [AR-REGRESSION 2026-07-26] 回退 eaf8706 的 travel 曲线。那一版把
      // 视觉大小写成「离拍摄点的位移 travel」的函数,并用
      // currentDistance/captureDistance 抵消透视 —— 代数上屏占比
      // ∝ visualScale/captureDistance,与「相机到卡片的距离 d」完全无关。
      // 后果有二,都是用户真机报的回归:① 走近时卡片拒绝按 1/d 变大,观感
      // 像在「躲开」;② 后退时不再有 1/d 的连续缩小,也就没有了「照片从
      // 镜头飞出去」的效果 —— 那个效果从来不是动画代码,就是卡片作为
      // 世界实体板、锚在 5cm close-anchor 处的自然透视。
      let d = simd_distance(camPos, card.simdWorldPosition)
      let s = d > Self.photoCardDistanceAnchorM
        ? powf(d / Self.photoCardDistanceAnchorM, Self.photoCardDistanceBeta)
        : 1.0
      card.simdScale = simd_float3(repeating: s)
    }
  }

  /// Render-thread consumer of the Dart-pushed four-state border states:
  /// recolours every card's ring + back-panel materials when the merged dict
  /// changed (dirty flag). Cards added AFTER a push pick their state up in
  /// renderer(_:didAdd:) via photoCardState(forPath:) — consuming the dirty
  /// flag here never loses state. Judgement stays 100% in Dart.
  private func applyPhotoCardStatesIfDirty() {
    guard let states = OfficialAetherARKitPlugin.takePhotoCardStatesIfDirty() else {
      return
    }
    // 遥测 G【cardpush】:渲染线程应用耗时(>1ms 才落行,防刷屏)。
    let t0 = CACurrentMediaTime()
    for (name, mats) in photoCardStateMats {
      guard let path =
        OfficialAetherARKitPlugin.photoCardSpecs[name]?.evidencePath else {
        continue
      }
      let color = Self.photoCardStateColor(states[path] ?? 0)
      for m in mats { m.diffuse.contents = color }
    }
    OfficialPwNativeTelemetry.shared.logCardPushApply(
      applyMs: (CACurrentMediaTime() - t0) * 1000.0,
      cardCount: photoCardStateMats.count
    )
  }

  /// Fires when ARKit removes our anchor (re-lock or stopSession).
  /// SceneKit auto-removes child nodes when the parent goes — drop our
  /// per-card scaling reference too so the dict doesn't leak.
  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    if let name = anchor.name {
      if name.hasPrefix("official_photo_card_") {
        // DIAGNOSTIC: ARKit removed a photo-card anchor (tracking loss / world-map
        // re-optimization after walking away+back). This is the "card disappeared
        // when I came back" symptom — confirms removal vs mere shrink.
        NSLog("[PHOTOCARD] *** ANCHOR REMOVED by ARKit: %@ (card gone) ***", name)
      }
      photoCardNodes.removeValue(forKey: name)
      photoCardStateMats.removeValue(forKey: name)
      photoCardFrontFill.removeValue(forKey: name)  // 与 photoCardNodes 同生命周期
    }
    guard anchor.name == Self.subjectAnchorName else { return }
    NSLog("[OfficialAetherARKitPreview] subject anchor removed; marker went with it")
  }

  deinit {
    pollTimer?.invalidate()
  }
}

// MARK: - (已删除) OfficialPwCaptureBrightnessGovernor
// [2026-08-10 用户签决] 原"热战役刀②:拍摄期亮度封顶"(2026-07-12 签决,
// fair→70%/serious+→60%)整体删除:拍摄期屏幕亮度保持用户设定,恒定不变。
// 历史实现见 git 历史与 docs 热二轮审计记录。

// MARK: - OfficialPwNativeTelemetry(真机验收显微镜,native 侧 JSONL)
//
// 产物:Documents/telemetry_official_native.jsonl,每行 {"t":epoch_ms,"type":...}。
// 与 Dart 侧 Documents/telemetry_dart.jsonl(lib/capture/telemetry_writer.dart)
// 配对,devicectl 一次拉走。定义在本文件里(而非独立 .swift)是沿用
// OfficialAetherARKitPreviewView 的同一理由:Runner.xcodeproj 只编译已列入
// PBXFileReference 的文件,新文件要动 pbxproj —— 蹭已有文件零风险。
//
// 事件:
//   session  — App 启动一条(OfficialAetherARKitPlugin.register 时):构建时间戳、
//              机型/系统、电池、physicalMemory。
//   resource — 拍摄页在场时 10s 一条(telemetryCaptureBegin/End 控制):
//              thermalState / phys_footprint(TASK_VM_INFO)/ 电池 /
//              进程 CPU(单核 % 口径,DeviceHealthPlugin 原语)/
//              SceneKit 渲染 FPS(updateAtTime 计帧的 10s 窗口均值)。
//   cardpush — setPhotoCardStates 差量应用:差量条数 + 渲染线程应用耗时
//              (>1ms 才记,防刷屏)。
//
// 铁律:所有写盘都在专用串行 utility 队列;渲染线程/主线程只做入队
// (dispatch async)或一次锁保护的计数自增,绝不等 IO。
final class OfficialPwNativeTelemetry {
  static let shared = OfficialPwNativeTelemetry()

  private let queue = DispatchQueue(
    label: "com.pocketworld.official.telemetry",
    qos: .utility
  )
  private var handle: FileHandle?
  private var handleFailed = false
  private var resourceTimer: DispatchSourceTimer?

  // SceneKit 渲染 FPS 计帧(updateAtTime 每帧自增;10s 采样窗清零)。
  private let frameLock = NSLock()
  private var renderFrames = 0
  private var frameWindowStart = CACurrentMediaTime()

  // cardpush 差量条数(channel 线程写,渲染线程消费;同 photoCardStates
  // 一样用锁保护)。
  private let cardPushLock = NSLock()
  private var pendingCardPushCount = 0

  private init() {}

  // ── 写入(仅在 queue 上) ──────────────────────────────────────────

  private func ensureHandle() -> FileHandle? {
    if let h = handle { return h }
    if handleFailed { return nil }
    guard
      let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first
    else {
      handleFailed = true
      return nil
    }
    let url = docs.appendingPathComponent("telemetry_official_native.jsonl")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let h = try? FileHandle(forWritingTo: url) else {
      handleFailed = true
      return nil
    }
    h.seekToEndOfFile()
    handle = h
    return h
  }

  /// 记一行(任意线程可调;真正的 JSON 编码 + 写盘在串行队列上)。
  func log(_ type: String, _ fields: [String: Any] = [:]) {
    let t = Int(Date().timeIntervalSince1970 * 1000)
    queue.async { [weak self] in
      guard let self = self, let h = self.ensureHandle() else { return }
      var obj: [String: Any] = ["t": t, "type": type]
      for (k, v) in fields { obj[k] = v }
      guard JSONSerialization.isValidJSONObject(obj),
            var data = try? JSONSerialization.data(withJSONObject: obj)
      else { return }
      data.append(0x0A)  // '\n'
      h.write(data)
    }
  }

  // ── A【session】 ───────────────────────────────────────────────────

  /// App 启动一条。主线程调用(plugin register 时)——顺手开电池监控,
  /// 后续 resource 采样才能读到 batteryLevel。
  func logSession() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    var sysinfo = utsname()
    uname(&sysinfo)
    let model = withUnsafePointer(to: &sysinfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 256) {
        String(cString: $0)
      }
    }
    var buildStamp = "unknown"
    if let exe = Bundle.main.executablePath,
       let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
       let mtime = attrs[.modificationDate] as? Date {
      buildStamp = ISO8601DateFormatter().string(from: mtime)
    }
    let version =
      (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
      ?? "?"
    let build =
      (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    let diagnosticBuildId =
      (Bundle.main.infoDictionary?["PWLiveCloudDiagnosticBuildId"] as? String)
      ?? "UNSTAMPED"
    let productManifest =
      (Bundle.main.infoDictionary?["PWProductSourceManifestSHA256"] as? String)
      ?? "UNSTAMPED"
    let dartAotSHA =
      (Bundle.main.infoDictionary?["PWDartAOTSHA256"] as? String)
      ?? "UNSTAMPED"
    let officialSfmSHA =
      (Bundle.main.infoDictionary?["PWOfficialSfmSHA256"] as? String)
      ?? "UNSTAMPED"
    let battery = UIDevice.current.batteryLevel  // -1 = 未知(刚开监控)
    log("session", [
      "build_stamp": buildStamp,
      "app_version": "\(version)(\(build))",
      "model": model,
      "os": UIDevice.current.systemVersion,
      "battery": Double(battery),
      "phys_mem_mb": Double(ProcessInfo.processInfo.physicalMemory)
        / 1_048_576.0,
      "cores": ProcessInfo.processInfo.processorCount,
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
      "diagnostic_build_id": diagnosticBuildId,
      "product_manifest": productManifest,
      "dart_aot_sha256": dartAotSHA,
      "official_sfm_sha256": officialSfmSHA,
    ])
    log("live_cloud_diag_build_v1", [
      "contract": "PW_LIVE_CLOUD_DIAG_V1_20260810",
      "diagnostic_build_id": diagnosticBuildId,
      "product_manifest": productManifest,
      "dart_aot_sha256": dartAotSHA,
      "official_sfm_sha256": officialSfmSHA,
      "app_version": "\(version)(\(build))",
      "observation_only": true,
    ])
  }

  /// Repeat the signed runtime identity at the start of every capture page.
  /// This makes a later in-place installation or stale process immediately
  /// visible in the same time window as the take being diagnosed.
  func logCaptureIdentity() {
    let info = Bundle.main.infoDictionary
    log("live_cloud_diag_capture_v2", [
      "contract": "PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810",
      "diagnostic_build_id":
        (info?["PWLiveCloudDiagnosticBuildId"] as? String) ?? "UNSTAMPED",
      "product_manifest":
        (info?["PWProductSourceManifestSHA256"] as? String) ?? "UNSTAMPED",
      "dart_aot_sha256":
        (info?["PWDartAOTSHA256"] as? String) ?? "UNSTAMPED",
      "official_sfm_sha256":
        (info?["PWOfficialSfmSHA256"] as? String) ?? "UNSTAMPED",
      "app_version":
        "\((info?["CFBundleShortVersionString"] as? String) ?? "?")"
        + "(\((info?["CFBundleVersion"] as? String) ?? "?"))",
      "observation_only": true,
    ])
  }

  // ── F【resource】 ──────────────────────────────────────────────────

  /// 拍摄页进入 → 10s 定时资源采样(串行队列上;幂等)。
  func startResourceSampling() {
    queue.async { [weak self] in
      guard let self = self, self.resourceTimer == nil else { return }
      self.frameLock.lock()
      self.renderFrames = 0
      self.frameWindowStart = CACurrentMediaTime()
      self.frameLock.unlock()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + 10, repeating: 10)
      timer.setEventHandler { [weak self] in
        self?.sampleResourcesOnQueue()
      }
      timer.resume()
      self.resourceTimer = timer
      self.log("resource_begin")
    }
  }

  /// 拍摄页退出 → 停采样(收尾补一条,拿到 finalize 末段的状态)。
  func stopResourceSampling() {
    queue.async { [weak self] in
      guard let self = self, let timer = self.resourceTimer else { return }
      timer.cancel()
      self.resourceTimer = nil
      self.sampleResourcesOnQueue()
      self.log("resource_end")
    }
  }

  /// SceneKit 渲染 tick(OfficialAetherARKitPreviewView.updateAtTime 每帧调用)。
  /// 一次锁自增,纳秒级 —— 渲染线程零等待。
  func noteRenderFrame() {
    frameLock.lock()
    renderFrames += 1
    frameLock.unlock()
  }

  private func sampleResourcesOnQueue() {
    // FPS 窗口(帧数 / 实际窗口秒)。
    frameLock.lock()
    let frames = renderFrames
    let windowS = CACurrentMediaTime() - frameWindowStart
    renderFrames = 0
    frameWindowStart = CACurrentMediaTime()
    frameLock.unlock()
    let fps = windowS > 0.1 ? Double(frames) / windowS : 0

    let footprint = Self.physFootprintMB()
    let cpu = Self.processCpuOneCorePercent()
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    // batteryLevel 走主线程读(UIDevice 主线程约定),拿到后回队列写行。
    DispatchQueue.main.async { [weak self] in
      let battery = Double(UIDevice.current.batteryLevel)
      let appState: String
      switch UIApplication.shared.applicationState {
      case .active: appState = "active"
      case .inactive: appState = "inactive"
      case .background: appState = "background"
      @unknown default: appState = "unknown"
      }
      self?.log("resource", [
        "thermal": thermal,
        "footprint_mb": (footprint * 10).rounded() / 10,
        "battery": battery,
        "cpu_one_core_pct": (cpu * 10).rounded() / 10,
        "scn_fps": (fps * 10).rounded() / 10,
        "app_state": appState,
        // 判决节拍的当前臂 —— 让热态/CPU 能按臂分组(见 currentQualityHz 注释)。
        "quality_hz": OfficialAetherARKitPlugin.currentQualityHz,
      ])
    }
  }

  // ── G【cardpush】 ──────────────────────────────────────────────────

  /// channel 线程:记录一次 setPhotoCardStates 推送的差量条数。
  func noteCardPush(diffCount: Int) {
    cardPushLock.lock()
    pendingCardPushCount += diffCount
    cardPushLock.unlock()
  }

  /// 渲染线程:差量应用完成,>1ms 才落一行(防刷屏)。
  func logCardPushApply(applyMs: Double, cardCount: Int) {
    cardPushLock.lock()
    let n = pendingCardPushCount
    pendingCardPushCount = 0
    cardPushLock.unlock()
    guard applyMs > 1.0 else { return }
    log("cardpush", [
      "n": n,
      "apply_ms": (applyMs * 100).rounded() / 100,
      "cards": cardCount,
    ])
  }

  // ── 底层原语 ────────────────────────────────────────────────────────

  /// jetsam 相关的 phys_footprint(TASK_VM_INFO;pw_telemetry.mm 同款)。
  private static func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576.0
  }

  /// 进程 CPU(单核 100% 口径;搬自退役 DeviceHealthPlugin.swift 的原语)。
  private static func processCpuOneCorePercent() -> Double {
    var threadList: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threadList, &threadCount)
            == KERN_SUCCESS,
          let threadList
    else { return 0 }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threadList)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
      )
    }
    var total = 0.0
    for index in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(THREAD_INFO_MAX)
      let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(
            threadList[index],
            thread_flavor_t(THREAD_BASIC_INFO),
            $0,
            &count
          )
        }
      }
      guard result == KERN_SUCCESS else { continue }
      if (info.flags & TH_FLAGS_IDLE) == 0 {
        total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }
    return total
  }
}
