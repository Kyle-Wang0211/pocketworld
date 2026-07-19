import ARKit
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Flutter
import Foundation
import ImageIO
import simd
import UIKit

// AetherARKit — in-Runner-binary ARKit bridge.
//
// What it exposes:
//   MethodChannel `aether_arkit`
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
//   EventChannel `aether_arkit/pose_stream` → JSON dictionary per
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
class AetherARKitPlugin: NSObject {
  // MARK: Singleton wiring

  private static var sharedInstance: AetherARKitPlugin?

  /// Used by AetherARKitPreviewFactory so the platform view's ARSCNView
  /// can attach to the SAME ARSession the plugin owns — match iOS's
  /// "single ARSession backs both preview and recorder" architecture
  /// from ObjectModeV2ARCaptureCoordinator.
  static func currentSession() -> ARSession? {
    return sharedInstance?.arSession
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    // [2026-07-11] spatial-first 匹配 kill switch:native(aether_sfm_c.cc)读
    // AETHER_STREAM_TEMPORAL_ONLY=1 时强制走旧的纯时间 K12 候选(已验证行为)。
    // spatial-first 的 host A/B 尚未出数——验证通过前默认关死;通过后删本行即启用。
    setenv("AETHER_STREAM_TEMPORAL_ONLY", "1", 1)
    // [2026-07-11] ④ 热调速器 opt-in(45 号冻结案):thermal serious/critical
    // 时 live 匹配候选 12→6,给相机/系统让 GPU;被降档帧由 finalize 补匹配
    // 恢复全窗口(native 默认 OFF,此行是唯一开关,删掉即同二进制回退)。
    // host A/B(设备一致配置 TEMPORAL_ONLY=1,GPU matcher):cap45 点数
    // +1.26%/reproj +0.0016、cap44 +0.49%/+0.0090,注册数持平 —— 全门绿。
    // ⚠️ 与上面的 kill switch 绑定:若未来启用 spatial-first,须先重跑
    // 热调速 A/B(spatial-first 臂实测点数 +2.4% 超 ±2% 带,方向为正)。
    setenv("AETHER_LIVE_CAND_K_HOT", "6", 1)
    // [2026-07-11 签决:减厚组合刀@4px] finalize 减厚组合(native 默认全 OFF,
    // 以下开关行是唯一开关,删行即同二进制回退)。host 已定价过门:
    // 刀A 2-view 升维(TRACK_UPGRADE)+ 定向 enrich(TARGETED,pair cap 300)。
    // rc=7 退避重试与 enrich AUTO 时间闸是 C++ 默认开,无需开关。
    //
    // [2026-07-11 法医定罪关停] 47 号采集双层地板案:host 同数据消融定罪
    // FRAG_MERGE@4px 主犯(鬼层 4.3%→6.7%)、TD_GROW_REFIT 从犯(→5.5%),
    // 组合叠加交互 ≈2.1×——把低视差深度歧义弥散壳凝聚成相干第二片。
    // TRACK_UPGRADE/ENRICH_TARGETED/PAIR_CAP=300 消融无罪且正收益,保留。
    // 重开条件:须以 tri-angle θ≥5° 门重新定价(鬼层 tri-angle p50=4.1°,
    // 主层 5.7°),过九门再启。
    // setenv("AETHER_TD_GROW_REFIT", "1", 1)   // 07-11 法医定罪关停(从犯)
    setenv("AETHER_TRACK_UPGRADE", "1", 1)
    setenv("AETHER_ENRICH_TARGETED", "1", 1)
    setenv("AETHER_ENRICH_PAIR_CAP", "300", 1)
    // setenv("AETHER_FRAG_MERGE", "1", 1)      // 07-11 法医定罪关停(主犯)
    // setenv("AETHER_FRAG_MERGE_REPROJ_PX", "4", 1)  // 随 FRAG_MERGE 关停
    // [2026-07-12] stage1 轮次帽(59555b8d 钩子 P1-STAGE1-RECIPE):stage-1
    // 循环上限 = min(ba_global_max_refinements, 4);未用轮次按余量公式让给
    // stage 2,enrich AUTO 时间闸窗口随 stage-1 提前收口。host 质量中性、
    // device 外推 finalize −17%;下次实拍看 finalize_segments 验真。
    // 删本行即同二进制回退(native 默认 0 = shipped 行为)。
    setenv("AETHER_STAGE1_ROUNDS_CAP", "4", 1)
    // [2026-07-12] 鬼层 L1 暗舱标定采集:finalize 尾段写 ghost_mask.bin 鬼层
    // 标记 + refined 交付后跑 L1 推理仲裁(CasDiffMVS 1-bit)。渲染门默认关,
    // 不影响任何显示/交付数据——纯 sidecar+telemetry 采集,为 L1/L2 标定攒
    // 真机数据。推理预算 ~12s 在交付之后,不 gate 用户。删本行即同二进制回退。
    setenv("AETHER_GHOST_MASK", "1", 1)
    let plugin = AetherARKitPlugin(messenger: registrar.messenger())
    sharedInstance = plugin
    let factory = AetherARKitPreviewFactory(getSession: {
      AetherARKitPlugin.currentSession()
    })
    registrar.register(factory, withId: "aether_arkit_preview")
    // 遥测 A【session】:App 启动一条(机型/系统/电池/内存/构建时间戳)。
    // register 在 didFinishLaunching 主线程跑,顺手开电池监控。
    PwNativeTelemetry.shared.logSession()
  }

  // MARK: Photo cards (RealityScan-style anchored capture thumbnails)

  /// Per-card render spec, keyed by anchor name, read by
  /// AetherARKitPreviewView.renderer(_:didAdd:) when SceneKit hands us the
  /// anchor's node. Static so the preview view (owns the ARSCNView delegate)
  /// and the plugin (adds the anchors) share one source of truth. Anchored at
  /// the capture pose => glued to the world by ARKit, no drift. `height` (meters)
  /// is the card's physical size, sized from the intrinsics to fill the viewport.
  struct PhotoCardSpec {
    let path: String
    let localCorners: [SCNVector3]  // 4 quad corners [TL,TR,BR,BL] in anchor-local space
    let captureDistance: Float      // camera→card distance at capture
    let worldCentroid: simd_float3  // anchor world position AT PLACEMENT (drift baseline)
    let captureCamPos: simd_float3  // camera world position AT CAPTURE (shrink reference)
  }
  static var photoCardSpecs: [String: PhotoCardSpec] = [:]
  // [瞬时快门 2026-07-19] 卡片缩略图解码重试计数:photo43 下 12MP 静照后台
  // 落盘,didAdd 建卡时文件可能还没写完;每 150ms 重试直到落盘(最多~4.5s)。
  static var photoCardThumbRetries: [String: Int] = [:]
  private static var photoCardAnchors: [ARAnchor] = []
  private static var photoCardCounter = 0

  /// T6 — live sparse feature-point overlay toggle. Read by the render loop in
  /// AetherARKitPreviewView (the separate class that owns the ARSCNView), set via
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
  static var coverageCloudDirty = false

  static func setCoverageCloud(xyz: [Float], rgb: [UInt8]) {
    coverageCloudLock.lock()
    coverageCloudXyz = xyz
    coverageCloudRgb = rgb
    coverageCloudDirty = true
    coverageCloudLock.unlock()
  }

  /// Render-thread side: returns the latest buffers iff they changed since
  /// the last take (nil otherwise, so the render loop skips rebuild work).
  static func takeCoverageCloudIfDirty() -> (xyz: [Float], rgb: [UInt8])? {
    coverageCloudLock.lock()
    defer { coverageCloudLock.unlock() }
    if !coverageCloudDirty { return nil }
    coverageCloudDirty = false
    return (coverageCloudXyz, coverageCloudRgb)
  }

  // ── Photo-card SfM border states (Dart-owned policy, dumb display) ──
  // 四态边框(用户签决):0=黑(刚拍、SfM 未处理) 1=白(已注册)
  // 2=红(断联,附近补拍) 3=黄(已注册但低视差,换角度补拍)。
  // 判定逻辑 100% 在 Dart(lib/capture/photo_card_state.dart)——这里只
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
  private let poseStreamHandler = PoseStreamHandler()

  // MARK: ARKit state

  private var arSession: ARSession?
  private let sessionDelegate = ARSessionForwarder()

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
  private var lastDriftLogTime: TimeInterval = 0

  /// Last time we computed image-quality metrics from an ARFrame. iOS
  /// `ObjectModeV2ARDomeCoordinator.sampleInterval = 1.0 / 6.0` — we
  /// only run Laplacian + brightness + signature at 6 Hz to keep CPU
  /// cost bounded.
  private var lastQualityComputeTime: TimeInterval = 0
  private static let qualityInterval: TimeInterval = 1.0 / 6.0

  /// RealityScan-style capture preview feed. This is intentionally
  /// throttled and decimated: native only reads ARKit's official
  /// rawFeaturePoints and samples camera color; Dart owns voxel hashing,
  /// minimap, quality coloring, and all product policy.
  private var lastPreviewPointPayloadTime: TimeInterval = 0
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
    label: "com.pocketworld.arkit.quality",
    qos: .userInitiated
  )
  /// Latest 128×128 grayscale Y-plane thumbnail from the background
  /// extract. Read & cleared only on the main thread (ARKit delegate
  /// queue) inside `broadcast`, so no lock needed. Stale by 1-3
  /// ARFrames (~17-50 ms) which is well under the 167 ms qualityInterval.
  ///
  /// All the actual metrics (Laplacian variance, brightness, signature)
  /// derive from this thumbnail in pure Dart — see
  /// lib/quality/quality_compute.dart. Native's job is now ONLY plane
  /// extract + downsample; everything past that is shared code across
  /// the 4 target platforms.
  private var pendingGray128: Data?
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
    label: "com.pocketworld.arkit.jpeg",
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
    label: "com.pocketworld.arkit.colorize",
    qos: .utility,
    attributes: .concurrent
  )

  /// [L1-ARBITRATE 2026-07-12] Dedicated SERIAL queue for the ghost-layer L1
  /// CasDiffMVS runner (`runCasDiffMVSL1`). Serial by design: the fp32 model
  /// holds ~634MB at inference peak — one prediction at a time. `.utility`
  /// so it never competes with capture (finalize has already delivered the
  /// refined snapshot when Dart invokes this). The runner instance is reused
  /// so the compiled model loads once per process.
  private let diffmvsQueue = DispatchQueue(
    label: "com.pocketworld.arkit.diffmvs_l1",
    qos: .utility
  )
  private let diffmvsRunner = CasDiffMVSRunner()


  // MARK: Init

  private init(messenger: FlutterBinaryMessenger) {
    self.methodChannel = FlutterMethodChannel(
      name: "aether_arkit",
      binaryMessenger: messenger
    )
    self.poseEventChannel = FlutterEventChannel(
      name: "aether_arkit/pose_stream",
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
  }

  // MARK: MethodChannel handler

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(ARWorldTrackingConfiguration.isSupported)
    case "startSession":
      do {
        let resume =
          (call.arguments as? [String: Any])?["resume"] as? Bool ?? false
        // [E24 探针 2026-07-19] videoFormatMode: "4k"(默认,现行为)|
        // "default43"(跳过 4K 覆盖,留系统默认 1920×1440 4:3 —— 测它的
        // out-of-band 静照分辨率与 tracking 健康;dart-define 门控,默认关)。
        // 缺参时保持现值(而非重置 4k):恢复/内部重启路径不得改变用户
        // 会话格式 —— 2026-07-19 切后台重进混内参 bug 的第二道保险。
        AetherARKitPlugin.videoFormatMode =
          ((call.arguments as? [String: Any])?["videoFormatMode"] as? String)
            ?? AetherARKitPlugin.videoFormatMode
        try startSession(resetWorld: !resume)
        result(nil)
      } catch {
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
      saveCurrentFrameAsJpeg(
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        maxTimestampDelta: maxTimestampDelta,
        quality: quality,
        metadataSchemaVersion: metadataSchemaVersion,
        dartSaveContract: dartSaveContract
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
      let maxTimestampDelta = (args["maxTimestampDelta"] as? NSNumber)?.doubleValue
        ?? Self.defaultSaveMaxTimestampDelta
      let metadataSchemaVersion = (args["metadataSchemaVersion"] as? NSNumber)?.intValue ?? 1
      let dartSaveContract = args["dartSaveContract"] as? [String: Any]
      // [E24 S2] feedSfm: 静照即证据模式 —— 载荷附带全分辨率 SfM 灰度喂图
      // (photo==fed 的 1:1 不变量在 12MP 世界恢复)。
      let feedSfm = (args["feedSfm"] as? NSNumber)?.boolValue ?? false
      captureHighResolutionStill(
        highresPath: highresPath,
        previewPath: previewPath,
        quality: quality,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        maxTimestampDelta: maxTimestampDelta,
        metadataSchemaVersion: metadataSchemaVersion,
        dartSaveContract: dartSaveContract,
        feedSfm: feedSfm
      ) { payload, error in
        if let error = error {
          result(FlutterError(
            code: "ar_highres_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(payload)
        }
      }
    case "runCasDiffMVSL1":
      // [L1-ARBITRATE 2026-07-12] Ghost-layer L1 depth inference over the
      // finalize-tail arbitration plan (written by native C++ when
      // AETHER_GHOST_MASK=1). Pure platform shim: decode/resize/predict/write
      // depth bins — every numeric contract (proj matrices, dv, scheduling)
      // is precomputed in the plan by aether_l1_plan.h. Runs on the dedicated
      // serial diffmvsQueue (fp32 peak ~634MB, one prediction at a time;
      // decode strictly off-main — colorize 主线程教训). Dart calls
      // pwsfm_arbitrate AFTER this reply; a failed run just means no depth
      // bins → the C++ arbitration abstains (fail-open).
      guard let args = call.arguments as? [String: Any],
            let planPath = args["planPath"] as? String,
            let dbDir = args["dbDir"] as? String else {
        result(FlutterError(
          code: "bad_args",
          message: "runCasDiffMVSL1 requires {planPath, dbDir}",
          details: nil))
        return
      }
      diffmvsQueue.async { [weak self] in
        let mainResult: FlutterResult = { value in
          DispatchQueue.main.async { result(value) }
        }
        guard let self = self else { mainResult(nil); return }
        let r = self.diffmvsRunner.run(planPath: planPath, dbDir: dbDir)
        mainResult([
          "ok": r.ok,
          "refsPlanned": r.refsPlanned,
          "refsDone": r.refsDone,
          "refsFailed": r.refsFailed,
          "degraded": r.degraded,
          "backend": r.backend,
          "totalMs": r.totalMs,
          "decodeMs": r.decodeMs,
          "inferMs": r.inferMs,
          "perRefMs": r.perRefMs,
          "error": r.error as Any,
        ])
      }
    case "beginReconUmbrella":
      // Arm the iOS-26 background-continuation umbrella so the SfM finalize
      // survives the user backgrounding the app mid-solve. MUST be invoked
      // from the foreground (the preview is up) — dasd silently drops a submit
      // made from a background state. No-op below iOS 26.
      let args = call.arguments as? [String: Any]
      let jobID = args?["jobId"] as? String ?? "legacy"
      if #available(iOS 26.0, *) {
        ReconUmbrella.shared.begin(jobID: jobID)
      }
      result(nil)
    case "endReconUmbrella":
      // Finalize + persist done — let the umbrella's handler loop complete the
      // grant and cancel any still-pending request. Idempotent.
      let args = call.arguments as? [String: Any]
      let jobID = args?["jobId"] as? String ?? "legacy"
      if #available(iOS 26.0, *) {
        ReconUmbrella.shared.end(jobID: jobID)
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
        ReconUmbrella.shared.setRealProgress(fraction: fraction, subtitle: subtitle)
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
            let jpegPath = args["jpegPath"] as? String else {
        result(FlutterError(
          code: "bad_args", message: "addPhotoCard requires jpegPath",
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
      let camT = camera.transform
      let camPos = simd_make_float3(camT.columns.3)
      let z: Float = Self.photoCardCloseZ
      NSLog("[PHOTOCARD] addPhotoCard close-anchor z=%.3f", z)
      // SCREEN-ALIGNED quad built at depth z (the surface distance): the 4 viewport
      // corners via ARKit's PORTRAIT view+projection matrices. The `.portrait`
      // orientation handles the sensor→screen 90° rotation internally; at depth z
      // the viewport edges (NDC ±1) sit at ±halfX/±halfY in view space (half =
      // z/projectionScale), so the quad EXACTLY fills the viewport at capture
      // regardless of z, and world-anchored on the surface it peels off the lens.
      let viewportSize = UIScreen.main.bounds.size
      let proj = camera.projectionMatrix(for: .portrait,
                                         viewportSize: viewportSize,
                                         zNear: 0.001, zFar: 1000)
      let invView = camera.viewMatrix(for: .portrait).inverse
      // View space: +X right, +Y up, -Z forward.
      let halfX = z / proj.columns.0.x
      // [第一步:12MP 4:3 照片,卡片几何保持 909a6a2 原样=填满屏幕视口贴镜头]
      // 预览 4:3 与卡片按画幅对齐留到第二步(须按预览实际 letterbox 视口算)。
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
      let cardName = "photo_card_\(AetherARKitPlugin.photoCardCounter)"
      AetherARKitPlugin.photoCardCounter += 1
      AetherARKitPlugin.photoCardSpecs[cardName] =
        PhotoCardSpec(path: jpegPath, localCorners: localCorners,
                      captureDistance: z, worldCentroid: centroid, captureCamPos: camPos)
      var anchorT = matrix_identity_float4x4
      anchorT.columns.3 = simd_float4(centroid, 1)
      let cardAnchor = ARAnchor(name: cardName, transform: anchorT)
      AetherARKitPlugin.photoCardAnchors.append(cardAnchor)
      session.add(anchor: cardAnchor)
      result(nil)
    case "clearPhotoCards":
      AetherARKitPlugin.clearPhotoCards(in: arSession)
      result(nil)
    case "setPhotoCardStates":
      // Dart-owned four-state border policy pushes {jpegPath: state} DIFFS
      // here (0 black/pending, 1 white/registered, 2 red/disconnected,
      // 3 yellow/low-parallax — see lib/capture/photo_card_state.dart).
      // Dumb executor: merge + mark dirty, zero judgement native-side.
      guard let args = call.arguments as? [String: Any],
            let states = args["states"] as? [String: NSNumber] else {
        result(FlutterError(
          code: "photo_card_states_bad_args",
          message: "setPhotoCardStates requires {states: {jpegPath: Int}}",
          details: nil))
        return
      }
      AetherARKitPlugin.mergePhotoCardStates(states.mapValues { $0.intValue })
      // 遥测 G【cardpush】:记差量条数;渲染线程应用时(>1ms)合并落行。
      PwNativeTelemetry.shared.noteCardPush(diffCount: states.count)
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
      AetherARKitPlugin.setCoverageCloud(xyz: xyz, rgb: rgb)
      result(nil)
    case "setFeaturePointsVisible":
      let visible =
        ((call.arguments as? [String: Any])?["visible"] as? NSNumber)?.boolValue
          ?? false
      AetherARKitPlugin.featurePointsVisible = visible
      NSLog("[AetherARKit] setFeaturePointsVisible=\(visible)")
      result(nil)
    case "setPhotoCardsVisible":
      let visible =
        ((call.arguments as? [String: Any])?["visible"] as? NSNumber)?.boolValue
          ?? true
      AetherARKitPlugin.photoCardsVisible = visible
      NSLog("[AetherARKit] setPhotoCardsVisible=\(visible)")
      result(nil)
    case "telemetryCaptureBegin":
      // 遥测 F【resource】:拍摄页进入 → 10s 定时资源采样
      // (thermal/footprint/电池/CPU/SceneKit FPS → telemetry_native.jsonl)。
      PwNativeTelemetry.shared.startResourceSampling()
      // [2026-07-12 热战役刀②,签决] 拍摄页进入 → 亮度调速器上岗
      //(fair 封 70% / serious+ 封 60%,退出恢复;只在拍摄页生效)。
      PwCaptureBrightnessGovernor.shared.begin()
      result(nil)
    case "telemetryCaptureEnd":
      // 拍摄页退出(含等待页完成)→ 停采样,收尾补一条。
      PwNativeTelemetry.shared.stopResourceSampling()
      // 刀②:退出拍摄页(含 dispose 路径,Dart 侧 dispose() 必调)→ 恢复原亮度。
      PwCaptureBrightnessGovernor.shared.end()
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

  private func startSession(resetWorld: Bool = true) throws {
    NSLog("[AetherARKit] startSession(resetWorld=\(resetWorld)) — isSupported=\(ARWorldTrackingConfiguration.isSupported)")
    guard ARWorldTrackingConfiguration.isSupported else {
      throw NSError(
        domain: "AetherARKit",
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
      && AetherARKitPlugin.videoFormatMode != "default43"
      && AetherARKitPlugin.videoFormatMode != "hires43"
    if AetherARKitPlugin.videoFormatMode == "default43" {
      NSLog("[AetherARKit] [E24] videoFormatMode=default43 — skipping 4K override")
    }
    // [E24 探针②] hires43:重验历史判死的高清捕获推荐格式(4032×3024 静照
    // 档)。历史实测(本文件上方注释):iOS 26 下 tracking 永不 .normal。
    // 本模式仅为验证苹果是否已在 26.x 修复;若复现冻结即最终判死 E24。
    if AetherARKitPlugin.videoFormatMode == "hires43", #available(iOS 16.0, *) {
      if let hires =
        ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
        configuration.videoFormat = hires
        NSLog("[AetherARKit] [E24] hires43 probe: \(hires.imageResolution) @ \(hires.framesPerSecond) fps")
      } else {
        NSLog("[AetherARKit] [E24] hires43 probe: recommended format nil, system default")
      }
    }
    if #available(iOS 16.0, *), allow4K {
      if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
        configuration.videoFormat = fourK
        NSLog("[AetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM), using 4K videoFormat: \(fourK.imageResolution) @ \(fourK.framesPerSecond) fps")
      } else {
        NSLog("[AetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM) but recommendedVideoFormatFor4KResolution returned nil; using system default \(configuration.videoFormat.imageResolution)")
      }
    } else {
      let res = configuration.videoFormat.imageResolution
      NSLog("[AetherARKit] device tier LOW (\(String(format: "%.2f", physMemGB)) GB RAM), staying on default videoFormat \(res) to avoid 4K jetsam risk")
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
      let dump: [String: Any] = [
        "mode": AetherARKitPlugin.videoFormatMode,
        "chosenWidth": Int(configuration.videoFormat.imageResolution.width),
        "chosenHeight": Int(configuration.videoFormat.imageResolution.height),
        "formats": rows,
      ]
      let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
      let data = try JSONSerialization.data(
        withJSONObject: dump, options: [.prettyPrinted])
      try data.write(to: docs.appendingPathComponent("ar_video_formats.json"))
    } catch {
      NSLog("[AetherARKit] [E24] formats dump failed: \(error)")
    }

    let session = arSession ?? ARSession()
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
      AetherARKitPlugin.clearPhotoCards(in: session)
    }
    arSession = session
    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(
        reason: resetWorld ? "session start" : "session resume")
    }
    if resetWorld {
      worldOrigin = nil
      worldYaw = 0
      worldSubjectAnchor = nil
      lockTimeOrigin = nil
    }
    lastDriftLogTime = 0
    lastFrameSnapshot = nil
    recentFrameSnapshots.removeAll()
  }

  private func stopSession() {
    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(reason: "session stop")
    }
    if let anchor = worldSubjectAnchor {
      arSession?.remove(anchor: anchor)
    }
    // 案③:主动停 → 帧停是预期,解除 stall 看门狗(下一帧到达自动重武装)。
    sessionDelegate.disarmStallWatchdog()
    arSession?.pause()
    worldOrigin = nil
    worldYaw = 0
    worldSubjectAnchor = nil
    lockTimeOrigin = nil
    lastDriftLogTime = 0
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
      NSLog("[AetherARKit] lockOrigin: no currentFrame yet")
      return nil
    }
    switch frame.camera.trackingState {
    case .normal:
      break
    case .limited(let reason):
      NSLog("[AetherARKit] lockOrigin: tracking is .limited(\(reason)) — retrying")
      return nil
    case .notAvailable:
      NSLog("[AetherARKit] lockOrigin: tracking .notAvailable — retrying")
      return nil
    @unknown default:
      NSLog("[AetherARKit] lockOrigin: unknown trackingState — retrying")
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

    // Install a single named ARAnchor at the chosen origin. ARKit
    // tracks its transform across world-frame re-alignments;
    // broadcast() re-reads it every frame to update worldOrigin in
    // lock-step. WWDC 2018 §610 + Polycam polyform pattern — the
    // canonical ARKit-correct way to pin a real-world point.
    if let session = arSession {
      var transform = matrix_identity_float4x4
      transform.columns.3 = simd_float4(origin.x, origin.y, origin.z, 1)
      let anchor = ARAnchor(name: "pocketworld_subject_origin",
                            transform: transform)
      session.add(anchor: anchor)
      worldSubjectAnchor = anchor
    }

    // worldYaw = "camera's relative bearing at lock". Subsequent
    // frames' azimuth subtracts this so the dome's az=0 ↔ lock pose.
    let relInitial = camPos - origin
    let yaw = atan2(relInitial.z, relInitial.x)

    worldOrigin = origin
    worldYaw = yaw
    lockTimeOrigin = origin
    lastDriftLogTime = 0  // force first drift log on next broadcast

    NSLog("[AetherARKit] lockOrigin: SUCCESS via \(positionSource) at "
      + "(\(origin.x), \(origin.y), \(origin.z))")

    if #available(iOS 16.0, *) {
      restoreContinuousExposureFocus(reason: "subject lock")
    }

    return [
      "originX": origin.x,
      "originY": origin.y,
      "originZ": origin.z,
      "worldYaw": yaw,
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
      NSLog("[AetherARKit] camera auto restore skipped (\(reason)): configurableCaptureDeviceForPrimaryCamera is nil")
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
      NSLog("[AetherARKit] camera auto restored (\(reason)): continuous exposure+focus")
    } catch {
      NSLog("[AetherARKit] camera auto restore failed (\(reason)): \(error)")
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
    completion: @escaping ([String: Any]?, Error?) -> Void
  ) {
    let selection = selectFrameSnapshot(
      targetTimestamp: targetTimestamp,
      maxTimestampDelta: maxTimestampDelta
    )
    guard let snap = selection.snapshot else {
      completion(nil, NSError(
        domain: "AetherARKit", code: 200,
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
        let json = try JSONSerialization.data(
          withJSONObject: metadata, options: []
        )
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
        if let g = Self.extractGrayAspect(
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

  private func captureHighResolutionStill(
    highresPath: String,
    previewPath: String,
    quality: Float,
    metadataPath: String? = nil,
    targetTimestamp: TimeInterval? = nil,
    maxTimestampDelta: TimeInterval =
      AetherARKitPlugin.defaultSaveMaxTimestampDelta,
    metadataSchemaVersion: Int = 1,
    dartSaveContract: [String: Any]? = nil,
    feedSfm: Bool = false,
    completion: @escaping ([String: Any]?, Error?) -> Void
  ) {
    guard let session = arSession else {
      completion(nil, NSError(
        domain: "AetherARKit", code: 210,
        userInfo: [NSLocalizedDescriptionKey:
          "captureHighResolutionStill: ARSession is not running"]
      ))
      return
    }
    if #available(iOS 16.0, *) {
      session.captureHighResolutionFrame { [weak self] frame, error in
        guard let self else { return }
        if let error {
          completion(nil, error)
          return
        }
        guard let frame else {
          completion(nil, NSError(
            domain: "AetherARKit", code: 211,
            userInfo: [NSLocalizedDescriptionKey:
              "captureHighResolutionStill: ARKit returned no frame"]
          ))
          return
        }

        let pixelBuffer = frame.capturedImage
        let timestamp = frame.timestamp
        if let targetTimestamp {
          let delta = abs(timestamp - targetTimestamp)
          guard delta <= maxTimestampDelta else {
            completion(nil, NSError(
              domain: "AetherARKit", code: 212,
              userInfo: [NSLocalizedDescriptionKey: String(
                format: "captureHighResolutionStill: captured frame is %.3fs from target %.6f, over max %.3fs",
                delta,
                targetTimestamp,
                maxTimestampDelta
              )]
            ))
            return
          }
        }
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
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
        let scaleAlignPremetrics = Self.computeScaleAlignPremetrics(
          cameraTransform: transform,
          anchorsWorld: anchorsWorld
        )
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = self.ciContext

        self.jpegEncodeQueue.async {
          do {
            let gray1024 = Self.extractGray(
              pixelBuffer,
              targetSide: Self.highResQualityDownsampleSide
            )
            let gray128 = Self.extractGray128(pixelBuffer)
            try FileManager.default.createDirectory(
              atPath: (highresPath as NSString).deletingLastPathComponent,
              withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
              atPath: (previewPath as NSString).deletingLastPathComponent,
              withIntermediateDirectories: true
            )
            if let metadataPath {
              try FileManager.default.createDirectory(
                atPath: (metadataPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
              )
            }
            try Self.encodeCVPixelBufferAsJpeg(
              pixelBuffer,
              to: URL(fileURLWithPath: highresPath),
              quality: CGFloat(quality),
              ciContext: ciContext
            )
            try Self.encodeCIImageAsJpeg(
              Self.makePreviewImage(from: ciImage),
              to: URL(fileURLWithPath: previewPath),
              quality: CGFloat(quality),
              ciContext: ciContext
            )

            if let metadataPath {
              var metadata: [String: Any] = [
                "version": metadataSchemaVersion,
                "native_role": "thin_arkit_high_res_still_executor",
                "t": timestamp,
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
              let json = try JSONSerialization.data(
                withJSONObject: metadata, options: []
              )
              try json.write(to: URL(fileURLWithPath: metadataPath))
            }

            var payload: [String: Any] = [
              "highresPath": highresPath,
              "previewPath": previewPath,
              "timestamp": timestamp,
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
            DispatchQueue.main.async { completion(payload, nil) }
          } catch {
            DispatchQueue.main.async { completion(nil, error) }
          }
        }
      }
    } else {
      completion(nil, NSError(
        domain: "AetherARKit", code: 212,
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
        domain: "AetherARKit", code: 201,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCVPixelBufferAsJpeg: CIContext.createCGImage failed"]
      )
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
      throw NSError(
        domain: "AetherARKit", code: 202,
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
        domain: "AetherARKit", code: 203,
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
        domain: "AetherARKit", code: 204,
        userInfo: [NSLocalizedDescriptionKey:
          "encodeCIImageAsJpeg: CIContext.createCGImage failed"]
      )
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
      throw NSError(
        domain: "AetherARKit", code: 205,
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
        domain: "AetherARKit", code: 206,
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

  // MARK: Per-frame broadcast

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

    // Diagnostic: 1 Hz drift log against lock-time origin. Tells us
    // whether the anchor is sitting in a feature-rich region (drift
    // < 5 cm) or feature-poor mid-air (drift in metres).
    if let lockTime = lockTimeOrigin, let curr = worldOrigin {
      if frame.timestamp - lastDriftLogTime > 1.0 {
        let drift = simd_distance(curr, lockTime)
        NSLog(String(
          format: "[AetherARKit] anchor drift: %.3f m from lock origin "
            + "(curr=(%.3f, %.3f, %.3f) lock=(%.3f, %.3f, %.3f))",
          drift, curr.x, curr.y, curr.z,
          lockTime.x, lockTime.y, lockTime.z
        ))
        lastDriftLogTime = frame.timestamp
      }
    }

    // Quaternion (x, y, z, w) from rotation submatrix.
    let q = simd_quaternion(cameraTransform)

    var payload: [String: Any] = [
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
    // frames stale ≈ 17-50 ms, irrelevant for the 6 Hz sample rate).
    qDiagPoseEvents += 1
    if qDiagWindowStart == 0 { qDiagWindowStart = frame.timestamp }
    if frame.timestamp - lastQualityComputeTime >= Self.qualityInterval {
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
        let computeStart = CACurrentMediaTime()
        qualityQueue.async { [weak self] in
          let g = AetherARKitPlugin.extractGray128(pixelBuffer)
          let elapsedMs = (CACurrentMediaTime() - computeStart) * 1000
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.pendingGray128 = g
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
      payload["q_grayW"] = AetherARKitPlugin.downsampleSide
      payload["q_grayH"] = AetherARKitPlugin.downsampleSide
      payload["q_gray128"] = FlutterStandardTypedData(bytes: g)
      pendingGray128 = nil
      qDiagAttached += 1
    }
    // 5s window aggregate log so we can sanity-check:
    //   • fires ≈ 30 per 5s (6 Hz × 5)
    //   • avgMs ≪ 16 (otherwise compute is starving the next frame)
    //   • skips=0 (compute always finishes before the next interval)
    //   • attached close to fires (every compute eventually reaches a payload)
    if frame.timestamp - qDiagWindowStart >= 5.0 {
      let avgMs = qDiagFires > 0 ? qDiagElapsedMsSum / Double(qDiagFires) : 0
      NSLog(String(
        format: "[AetherARKit] 5s quality: fires=%d skips=%d avgMs=%.1f attached=%d/%d",
        qDiagFires, qDiagSkips, avgMs, qDiagAttached, qDiagPoseEvents
      ))
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
    } else {
      payload["worldOriginX"] = Float(0)
      payload["worldOriginY"] = Float(0)
      payload["worldOriginZ"] = Float(0)
      payload["worldYaw"] = Float(0)
      payload["hasOrigin"] = false
    }

    poseStreamHandler.send(payload)
  }
}

// MARK: - Frame quality plane extract (cross-platform handoff to Dart)

@available(iOS 11.0, *)
extension AetherARKitPlugin {
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
private class PoseStreamHandler: NSObject, FlutterStreamHandler {
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
// that pulls Objective-C inheritance into the Swift-only AetherARKitPlugin
// (would have to inherit NSObject + add @objc on every call). Cleaner
// to use a tiny forwarder.

@available(iOS 11.0, *)
private class ARSessionForwarder: NSObject, ARSessionDelegate {
  var onFrame: ((ARFrame) -> Void)?

  // Diagnostic state — log only on transitions, not every frame.
  private var loggedFirstFrame = false
  private var lastTrackingDescription: String = ""

  // ── ①【ARSession 帧监视 2026-07-11】帧到达间隔水位遥测 ──────────────
  // 44/45 号相机冻结:预览黑屏 ~2min,但没有任何"ARSession 断供"的一手
  // 证据(NSLog 拔线全丢)。这里补上:1s 看门狗计时器盯 didUpdate 的到达
  // 间隔,>1s 无新帧 → telemetry_native.jsonl 记一条 ar_frame_stall(带
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
    label: "com.pocketworld.arframe.watchdog",
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
    NSLog("[AetherARKit] frame-stall watchdog disarmed (session stopped)")
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
      PwNativeTelemetry.shared.log(e.type, [
        "gap_ms": e.gapMs,
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        "interrupted": isInterrupted,
      ])
    }
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    if !loggedFirstFrame {
      loggedFirstFrame = true
      NSLog("[AetherARKit] first ARFrame received")
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
      PwNativeTelemetry.shared.log("ar_frame_resume", [
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
      NSLog("[AetherARKit] trackingState → \(desc)")
    }
    onFrame?(frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    NSLog("[AetherARKit] ARSession failed: \(error.localizedDescription)")
    PwNativeTelemetry.shared.log("ar_session_failed", [
      "error": error.localizedDescription,
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
  }

  func sessionWasInterrupted(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interrupted")
    stallLock.lock()
    interrupted = true
    stallLock.unlock()
    PwNativeTelemetry.shared.log("ar_interrupted", [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interruption ended")
    stallLock.lock()
    interrupted = false
    stallLock.unlock()
    PwNativeTelemetry.shared.log("ar_interruption_ended", [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
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
// avoid. AetherARKitPlugin.swift is already in the project; piggyback.

@available(iOS 11.0, *)
class AetherARKitPreviewFactory: NSObject, FlutterPlatformViewFactory {
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
    return AetherARKitPreviewView(frame: frame, getSession: getSession)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

@available(iOS 11.0, *)
class AetherARKitPreviewView: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  private let arscnView: ARSCNView
  private let getSession: () -> ARSession?
  private var pollTimer: Timer?

  // ── Subject marker (Remy-style locked-origin visualization) ────────
  //
  // Kept post-SAM-revert for ongoing validation: user wanted more
  // capture sessions before deciding whether the marker is signal or
  // noise. Mechanism: lockOrigin installs the named
  // `pocketworld_subject_origin` ARAnchor → ARKit fires
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
  private static let subjectAnchorName = "pocketworld_subject_origin"

  // ── 距离补偿缩放(用户签决,替换旧"额外收缩+0.15 下限"方案)────────
  // 旧方案纯透视(视觉大小∝1/d)+额外收缩,2m 外卡片就看不见。新曲线:
  // 保持近大远小,但远处衰减变缓 —— 节点缩放 node_scale = (d/d0)^β,
  // 视觉大小 ∝ scale/d = d^(β-1) = d^-0.5(β=0.5):2m 处比纯透视大
  // ~1.4×,10m ~3.2×,100m 仍持续变小。**绝无最小尺寸下限**:拍房子时
  // 100m 处的卡片可以一路缩到 1 像素(旧 photoCardMinScale=0.15 下限已
  // 删)。代价:远处卡片比旧方案大 → 平面卡片对场景的视差滑移更可见,
  // 用户签决接受。photoCardNodes holds the per-card CONTAINER node we scale.
  private var photoCardNodes: [String: SCNNode] = [:]
  /// 距离补偿锚点 d0(米):d ≤ d0 时不放大(scale=1,保持原透视);
  /// d > d0 时 scale=(d/d0)^β。真机调参常量。
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

  // ── T6 v2: capture-coverage cloud — DUMB DISPLAY EXECUTOR ────────────────
  // All coverage policy (point selection, per-photo frustum counting, the
  // red→yellow→green ramp, 0-photos-⇒-0-dots gating) lives in DART — see
  // lib/capture/capture_coverage_cloud.dart and the algorithm-executor
  // boundary in ARFrameSaveSpec. Native's only job: world-anchor the packed
  // xyz+rgb Dart pushed via `setCoveragePointCloud`, as one SceneKit
  // `.point` geometry on the world root (depth-correct, no 2D-projection
  // parallax — same reason the photo cards are native).
  private var pointCloudNode: SCNNode?

  /// Render-loop tick: apply the latest Dart-pushed cloud when it changed.
  /// Toggled off → tear the node down.
  private func updateFeaturePointOverlay() {
    if !AetherARKitPlugin.featurePointsVisible {
      if pointCloudNode != nil {
        pointCloudNode?.removeFromParentNode()
        pointCloudNode = nil
      }
      _ = AetherARKitPlugin.takeCoverageCloudIfDirty() // drop stale pushes
      return
    }
    guard let cloud = AetherARKitPlugin.takeCoverageCloudIfDirty() else {
      return
    }
    rebuildPointCloud(xyz: cloud.xyz, rgb: cloud.rgb)
  }

  private func rebuildPointCloud(xyz: [Float], rgb: [UInt8]) {
    let n = xyz.count / 3
    guard n > 0, rgb.count >= n * 3 else {
      pointCloudNode?.removeFromParentNode()
      pointCloudNode = nil
      return
    }
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
    element.pointSize = 6
    element.minimumPointScreenSpaceRadius = 2
    element.maximumPointScreenSpaceRadius = 6
    let geo = SCNGeometry(sources: [vSource, cSource], elements: [element])
    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = UIColor.white      // × per-vertex colour
    mat.writesToDepthBuffer = false
    mat.readsFromDepthBuffer = false
    geo.materials = [mat]
    if let node = pointCloudNode {
      node.geometry = geo
    } else {
      let node = SCNNode(geometry: geo)
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
    arscnView.preferredFramesPerSecond = 30
    arscnView.antialiasingMode = .none
    arscnView.delegate = self
    attachSessionIfReady()
  }

  func view() -> UIView {
    return arscnView
  }

  /// AetherARKitPlugin creates the ARSession lazily on `startSession`,
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
      NSLog("[AetherARKitPreview] attached to ARSession on first try")
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
        NSLog("[AetherARKitPreview] attached to ARSession after poll")
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
    guard let name = anchor.name, name.hasPrefix("photo_card_") else { return }
    NSLog("[PHOTOCARD] renderer didAdd %@", name)
    guard let spec = AetherARKitPlugin.photoCardSpecs[name] else {
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
      kCGImageSourceThumbnailMaxPixelSize: AetherARKitPlugin.photoCardThumbMaxPx,
    ]
    guard let imgSrc = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: spec.path) as CFURL, nil),
          let thumbCG = CGImageSourceCreateThumbnailAtIndex(
            imgSrc, 0, thumbOpts as CFDictionary) else {
      // [瞬时快门] 12MP 静照后台落盘,文件可能还没写完 → 解码读空。卡片
      // 锚点/几何已建好(贴镜头),只差纹理;每 150ms 重试直到落盘(最多
      // 30 次~4.5s)。位姿/几何在 spec 里,重试不动位姿。
      let tries = AetherARKitPlugin.photoCardThumbRetries[name, default: 0]
      if tries < 30 {
        AetherARKitPlugin.photoCardThumbRetries[name] = tries + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak node] in
          guard let self, let node else { return }
          self.renderer(renderer, didAdd: node, for: anchor)
        }
      } else {
        NSLog("[PHOTOCARD] renderer: thumbnail decode FAILED (gave up) for %@", name)
        AetherARKitPlugin.photoCardThumbRetries.removeValue(forKey: name)
      }
      return
    }
    AetherARKitPlugin.photoCardThumbRetries.removeValue(forKey: name)
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
    let initialState = AetherARKitPlugin.photoCardState(forPath: spec.path)
    if initialState != 0 {
      let c = Self.photoCardStateColor(initialState)
      frameMat.diffuse.contents = c
      backMat.diffuse.contents = c
    }
  }

  /// Per-frame: distance-compensated scaling for the floating photo cards +
  /// four-state border colour application. Cheap: one distance + scale per
  /// card per frame (~百级节点一次 sqrt 可忽略), all on the SceneKit render
  /// thread.
  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    PwNativeTelemetry.shared.noteRenderFrame()  // 遥测 F:FPS 计帧(纳秒级)
    updateFeaturePointOverlay()    // T6: live sparse coverage cloud (independent of cards)
    applyPhotoCardStatesIfDirty()  // 四态边框:消费 Dart 推来的状态差量
    guard !photoCardNodes.isEmpty, let cam = renderer.pointOfView else { return }
    let camPos = cam.simdWorldPosition
    for card in photoCardNodes.values {
      // RS 复刻显示开关:逐帧幂等套用可见性 —— 隐藏期新建的卡片下一帧即
      // 隐藏,重开下一帧全量回显,无需遍历时机协调。
      card.isHidden = !AetherARKitPlugin.photoCardsVisible
      // 距离补偿缩放(签决,常量注释见 photoCardDistanceBeta):
      // d ≤ d0(1m)→ scale=1 保持原透视;d > d0 → scale=(d/d0)^β,
      // 视觉大小 ∝ d^(β-1)=d^-0.5 —— 近大远小保持、远处衰减变缓,
      // 无最小尺寸下限(100m 处可以小到 1 像素,继续缩)。
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
    guard let states = AetherARKitPlugin.takePhotoCardStatesIfDirty() else {
      return
    }
    // 遥测 G【cardpush】:渲染线程应用耗时(>1ms 才落行,防刷屏)。
    let t0 = CACurrentMediaTime()
    for (name, mats) in photoCardStateMats {
      guard let path = AetherARKitPlugin.photoCardSpecs[name]?.path else {
        continue
      }
      let color = Self.photoCardStateColor(states[path] ?? 0)
      for m in mats { m.diffuse.contents = color }
    }
    PwNativeTelemetry.shared.logCardPushApply(
      applyMs: (CACurrentMediaTime() - t0) * 1000.0,
      cardCount: photoCardStateMats.count
    )
  }

  /// Fires when ARKit removes our anchor (re-lock or stopSession).
  /// SceneKit auto-removes child nodes when the parent goes — drop our
  /// per-card scaling reference too so the dict doesn't leak.
  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    if let name = anchor.name {
      if name.hasPrefix("photo_card_") {
        // DIAGNOSTIC: ARKit removed a photo-card anchor (tracking loss / world-map
        // re-optimization after walking away+back). This is the "card disappeared
        // when I came back" symptom — confirms removal vs mere shrink.
        NSLog("[PHOTOCARD] *** ANCHOR REMOVED by ARKit: %@ (card gone) ***", name)
      }
      photoCardNodes.removeValue(forKey: name)
      photoCardStateMats.removeValue(forKey: name)
    }
    guard anchor.name == Self.subjectAnchorName else { return }
    NSLog("[AetherARKitPreview] subject anchor removed; marker went with it")
  }

  deinit {
    pollTimer?.invalidate()
  }
}

// MARK: - PwCaptureBrightnessGovernor(热战役刀②:拍摄期屏幕亮度封顶)
//
// [2026-07-12 签决] 热二轮审计:常开基线(4K 相机 + 渲染 + OLED 满亮度)是
// 热大头,OLED 亮度是其中少数可无损干预的旋钮。策略(用户签决):
//   nominal        → 不动(用户亮度自主)
//   fair           → 封顶 70%
//   serious/critical → 封顶 60%
//   退出拍摄页     → 恢复进入时亮度
// 只在拍摄页生效(telemetryCaptureBegin/End 已是拍摄页进/出的可靠配对,
// Dart dispose() 必调 End)。封顶=min(基线, cap),绝不调高;用户拍摄中
// 手动改亮度会被识别为新基线(当前值 ≠ 上次我们设的值 → 重新基线),
// 不与用户抢方向盘。切后台恢复原亮度(封顶不外泄到别的 App),回前台重套。
// 遥测:brightness_cap 事件(apply/restore,from/to/cap/thermal)。
// 定义在本文件里同 PwNativeTelemetry 的理由:蹭已有 pbxproj 文件零风险。
final class PwCaptureBrightnessGovernor {
  static let shared = PwCaptureBrightnessGovernor()

  private var active = false
  private var baselineBrightness: CGFloat = 1.0
  private var lastApplied: CGFloat?  // 我们最后设置的值;nil = 尚未干预
  private init() {}

  /// 拍摄页进入(主线程,channel handler)。幂等。
  func begin() {
    guard !active else { return }
    active = true
    baselineBrightness = UIScreen.main.brightness
    lastApplied = nil
    let nc = NotificationCenter.default
    nc.addObserver(
      self, selector: #selector(thermalDidChange),
      name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    applyPolicy(reason: "captureBegin")
  }

  /// 拍摄页退出/dispose(主线程)。幂等。恢复基线亮度。
  func end() {
    guard active else { return }
    active = false
    NotificationCenter.default.removeObserver(self)
    rebaselineIfUserChanged()
    if let last = lastApplied, abs(last - baselineBrightness) > 0.004 {
      let from = UIScreen.main.brightness
      UIScreen.main.brightness = baselineBrightness
      PwNativeTelemetry.shared.log("brightness_cap", [
        "action": "restore",
        "from": Double(from),
        "to": Double(baselineBrightness),
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
      ])
    }
    lastApplied = nil
  }

  // ── 内部 ──────────────────────────────────────────────────────────

  private func cap(for state: ProcessInfo.ThermalState) -> CGFloat? {
    switch state {
    case .nominal: return nil
    case .fair: return 0.70
    case .serious, .critical: return 0.60
    @unknown default: return nil  // 未来新档位:宁可不干预
    }
  }

  /// 基线追随用户:未干预状态(lastApplied == nil,如 begin 后首次 / 切走
  /// 归还后回前台)当前值就是用户意志 → 无条件作基线;干预中若当前值 ≠ 我们
  /// 最后设的值 = 用户手动改过 → 以新值为基线并视为未干预。
  private func rebaselineIfUserChanged() {
    let current = UIScreen.main.brightness
    if let last = lastApplied {
      if abs(current - last) > 0.01 {
        baselineBrightness = current
        lastApplied = nil  // 视为未干预,restore 语义随基线走
      }
    } else {
      baselineBrightness = current
    }
  }

  private func applyPolicy(reason: String) {
    guard active else { return }
    rebaselineIfUserChanged()
    let state = ProcessInfo.processInfo.thermalState
    let target: CGFloat
    if let c = cap(for: state) {
      target = min(baselineBrightness, c)
    } else {
      target = baselineBrightness
    }
    let from = UIScreen.main.brightness
    guard abs(from - target) > 0.004 else { return }
    UIScreen.main.brightness = target
    lastApplied = target
    PwNativeTelemetry.shared.log("brightness_cap", [
      "action": "apply",
      "reason": reason,
      "from": Double(from),
      "to": Double(target),
      "cap": cap(for: state).map { Double($0) } ?? -1.0,
      "thermal": state.rawValue,
    ])
    NSLog("[BrightnessGov] %@ thermal=%ld %.2f→%.2f", reason, state.rawValue,
          Double(from), Double(target))
  }

  @objc private func thermalDidChange() {
    // thermal 通知可能在后台线程投递;UIScreen 必须主线程。
    DispatchQueue.main.async { self.applyPolicy(reason: "thermalDidChange") }
  }

  @objc private func appWillResignActive() {
    // 切走(控制中心/App 切换)→ 还原,封顶不外泄;回前台 didBecomeActive 重套。
    DispatchQueue.main.async {
      guard self.active, let last = self.lastApplied else { return }
      let current = UIScreen.main.brightness
      // 用户切走前手动改过 → 不抢方向盘(回前台 applyPolicy 会重新基线)。
      if abs(current - last) <= 0.01 {
        UIScreen.main.brightness = self.baselineBrightness
        self.lastApplied = nil
      }
    }
  }

  @objc private func appDidBecomeActive() {
    DispatchQueue.main.async { self.applyPolicy(reason: "didBecomeActive") }
  }
}

// MARK: - PwNativeTelemetry(真机验收显微镜,native 侧 JSONL)
//
// 产物:Documents/telemetry_native.jsonl,每行 {"t":epoch_ms,"type":...}。
// 与 Dart 侧 Documents/telemetry_dart.jsonl(lib/capture/telemetry_writer.dart)
// 配对,devicectl 一次拉走。定义在本文件里(而非独立 .swift)是沿用
// AetherARKitPreviewView 的同一理由:Runner.xcodeproj 只编译已列入
// PBXFileReference 的文件,新文件要动 pbxproj —— 蹭已有文件零风险。
//
// 事件:
//   session  — App 启动一条(AetherARKitPlugin.register 时):构建时间戳、
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
final class PwNativeTelemetry {
  static let shared = PwNativeTelemetry()

  private let queue = DispatchQueue(
    label: "com.pocketworld.telemetry",
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
    let url = docs.appendingPathComponent("telemetry_native.jsonl")
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

  /// SceneKit 渲染 tick(AetherARKitPreviewView.updateAtTime 每帧调用)。
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
