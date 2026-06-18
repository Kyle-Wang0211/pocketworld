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
    let plugin = AetherARKitPlugin(messenger: registrar.messenger())
    sharedInstance = plugin
    let factory = AetherARKitPreviewFactory(getSession: {
      AetherARKitPlugin.currentSession()
    })
    registrar.register(factory, withId: "aether_arkit_preview")
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
  }
  static var photoCardSpecs: [String: PhotoCardSpec] = [:]
  private static var photoCardAnchors: [ARAnchor] = []
  private static var photoCardCounter = 0

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

  // MARK: BiRefNet saliency (Plan H — capture-after mask source)
  //
  // Used by post-capture saliency MethodChannels. Earlier capture-during
  // experiments tried to push AVCaptureDevice focus/exposure POIs from tap or
  // saliency, but real-device testing on iPhone 14 Pro showed that single-shot
  // hardware focus can get stuck at a near lens distance and make the AR preview
  // look "near-sighted". Capture now leaves ARKit's continuous autofocus and
  // autoexposure in charge; BiRefNet remains capture-after only.
  //
  // Same `Any?` boxing rationale as edgeTamSession (iOS 16+ type stashed on
  // an iOS 11 class). Serial queue ensures the single-threaded MLModel
  // predictions don't overlap if Dart fires lock → re-lock in quick succession.
  private var biRefNetSession: Any?
  private let biRefNetQueue = DispatchQueue(
    label: "com.pocketworld.arkit.birefnet",
    qos: .userInitiated
  )

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
      ) { error in
        if let error = error {
          result(FlutterError(
            code: "ar_save_jpeg_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(nil)
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
      captureHighResolutionStill(
        highresPath: highresPath,
        previewPath: previewPath,
        quality: quality,
        metadataPath: metadataPath,
        targetTimestamp: targetTimestamp,
        maxTimestampDelta: maxTimestampDelta,
        metadataSchemaVersion: metadataSchemaVersion,
        dartSaveContract: dartSaveContract
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
    case "runBiRefNetOnJpeg":
      // Plan G W2 D1.5 Step 2: post-capture per-frame BiRefNet saliency.
      // Reads JPEG at jpegPath, runs BiRefNetWrapper.Session.predictSaliency
      // (auto-tier: HR@1024 on HIGH ≥5GB, lite@1024 on LOW 4GB), writes the
      // 1024×1024 fp32 mask as raw bytes to maskOutPath (4 MB per mask).
      // Caller (Dart capture_session.stop()) fires unawaited for top-N
      // retained cell-photos. Returns inference metadata for logging /
      // upload manifest.
      //   Args: { jpegPath: String, maskOutPath: String }
      //   Returns: { width, height, fgRatio, inferenceTimeMs, tier, ok }
      if #available(iOS 16.0, *) {
        handleRunBiRefNetOnJpeg(call: call, result: result)
      } else {
        result(FlutterError(
          code: "ar_birefnet_unavailable",
          message: "BiRefNet requires iOS 16+ (MLMultiArray .float16).",
          details: nil
        ))
      }
    case "lockFocusAtTapPoint":
      // Deprecated capture-during focus hook. Keep the MethodChannel shape for
      // old Dart/hot-reload clients, but do not touch AVCaptureDevice focus or
      // exposure during AR capture.
      //
      // Args:
      //   { x: Double in [0,1] (buffer-relative, top-left origin),
      //     y: Double in [0,1] }
      // Returns:
      //   { x: Double, y: Double, applied: false }
      if #available(iOS 16.0, *) {
        handleLockFocusAtTapPoint(call: call, result: result)
      } else {
        result(FlutterError(
          code: "ar_lock_focus_unavailable",
          message: "lockFocusAtTapPoint requires iOS 16+ (configurableCaptureDeviceForPrimaryCamera).",
          details: nil
        ))
      }
    case "getDeviceTier":
      // Reports device memory tier so the Dart side can decide whether
      // to start MobileSAM (HIGH only — LOW devices would OOM, see
      // project_pocketworld_device_tier.md memory). Single source of
      // truth for the 5 GB threshold lives in startSession() above
      // where the 4K AR videoFormat decision uses the same boundary.
      let physMemBytes = ProcessInfo.processInfo.physicalMemory
      let physMemGB = Double(physMemBytes) / (1024.0 * 1024.0 * 1024.0)
      let tier = physMemBytes >= 5_000_000_000 ? "high" : "low"
      result([
        "tier": tier,
        "physicalMemoryBytes": NSNumber(value: physMemBytes),
        "physicalMemoryGB": physMemGB,
      ])
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
      // SCREEN-ALIGNED quad, ZERO tuning, FULLY DETERMINISTIC. We build the 4
      // viewport-corner world points from ARKit's PORTRAIT view + projection
      // matrices. The `.portrait` orientation makes ARKit handle the sensor→screen
      // 90° rotation internally, so the quad comes out screen-portrait (not the
      // sensor-landscape shape). At depth z the viewport edges (NDC ±1) sit at
      // ±halfX / ±halfY in view space, where half = z / projectionScale; the quad
      // therefore EXACTLY fills the viewport at capture and, world-anchored, peels
      // off the lens as the camera moves. (Replaces unprojectPoint(ontoPlane:),
      // which failed 2-4/4 corners — the plane went edge-on to the corner rays —
      // and dropped to a sensor-landscape fallback that rotated the card 90°.)
      let viewportSize = UIScreen.main.bounds.size
      let z: Float = 0.4
      let proj = camera.projectionMatrix(for: .portrait,
                                         viewportSize: viewportSize,
                                         zNear: 0.001, zFar: 1000)
      let invView = camera.viewMatrix(for: .portrait).inverse
      // View space: +X right, +Y up, -Z forward.
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
      let cardName = "photo_card_\(AetherARKitPlugin.photoCardCounter)"
      AetherARKitPlugin.photoCardCounter += 1
      AetherARKitPlugin.photoCardSpecs[cardName] =
        PhotoCardSpec(path: jpegPath, localCorners: localCorners)
      var anchorT = matrix_identity_float4x4
      anchorT.columns.3 = simd_float4(centroid, 1)
      let cardAnchor = ARAnchor(name: cardName, transform: anchorT)
      AetherARKitPlugin.photoCardAnchors.append(cardAnchor)
      session.add(anchor: cardAnchor)
      result(nil)
    case "clearPhotoCards":
      if let session = arSession {
        for a in AetherARKitPlugin.photoCardAnchors {
          session.remove(anchor: a)
        }
      }
      AetherARKitPlugin.photoCardAnchors.removeAll()
      AetherARKitPlugin.photoCardSpecs.removeAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Session lifecycle

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
    // Horizontal plane detection — verbatim of
    // ObjectModeV2ARDomeCoordinator.swift line 165. We don't read
    // the detected planes ourselves, but turning detection ON gives
    // ARKit a much stronger signal for gravity alignment (it fits
    // the Y axis to detected floor/table normals). Without it, the
    // Y axis comes from accelerometer alone and can drift a few
    // degrees, which leaks into elevation = atan2(rel.y, horizDist)
    // and makes the dome look "tilted when phone is level".
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
    let allow4K = physMemBytes >= kFourKMemThresholdBytes
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

    let session = arSession ?? ARSession()
    session.delegate = sessionDelegate
    if resetWorld {
      // Fresh start: clean reference frame, drop all anchors + the locked origin.
      session.run(configuration,
                  options: [.resetTracking, .removeExistingAnchors])
    } else {
      // RESUME after a transient background: keep the world map + existing
      // photo-card anchors so the AR cards survive (no reset, no anchor removal).
      session.run(configuration)
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
    completion: @escaping (Error?) -> Void
  ) {
    let selection = selectFrameSnapshot(
      targetTimestamp: targetTimestamp,
      maxTimestampDelta: maxTimestampDelta
    )
    guard let snap = selection.snapshot else {
      completion(NSError(
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
        DispatchQueue.main.async { completion(nil) }
      } catch {
        DispatchQueue.main.async { completion(error) }
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

  /// Shared CIContext for the SAM frame snapshot path. CIContext is
  /// expensive to create (~10ms cold-start, allocates Metal device +
  /// program cache), so we keep one alive for the lifetime of the
  /// process. CoreImage internally uses Metal/IOSurface and reuses
  /// pipeline state across `render(toBitmap:)` calls; per-frame cost
  /// is dominated by the YUV→RGB conversion shader + bilinear scale,
  /// typically 8–20 ms on iPhone 12 Pro+ for a 1024×1024 output.
  ///
  /// Thread-safety: CIContext.render is documented as thread-safe
  /// (see Apple's CIContext.h header). All callers run on
  /// `qualityQueue` (serial), so even if Apple's docs were wrong
  /// we'd still serialize accesses.
  private static let samCIContext: CIContext = {
    // High-quality color management adds ~30% latency for ARKit
    // YUV→RGB but doesn't change the SAM mask (SAM is colorspace-
    // agnostic at the binary mask level). Keep colorspace nil →
    // CoreImage auto-detects from CVPixelBuffer attachments.
    return CIContext(options: [
      .useSoftwareRenderer: false,  // force GPU
      .priorityRequestLow: true,    // don't compete with ARKit's
                                    // own GPU rendering for the
                                    // preview view
    ])
  }()

  /// Snapshot the current ARFrame's `capturedImage` (typically a
  /// 1920×1440 or 3840×2160 BiPlanar YUV CVPixelBuffer), convert to
  /// RGBA, and downsample bilinearly to (target × target). Used by
  /// the Dart-side `requestSamFrame` MethodChannel handler to feed
  /// MobileSAM at its native 1024×1024 input resolution.
  ///
  /// Why a square output: SAM expects ResizeLongestSide(1024) input
  /// with the short side zero-padded. Returning a square buffer
  /// already-padded keeps the Dart wrapper trivial — it can feed the
  /// bytes straight into the encoder ONNX without further reshape.
  ///
  /// We do NOT preserve the source aspect ratio. ARKit landscape
  /// frames are 4:3 (1920×1440) or 16:9 (3840×2160); both squashed
  /// to a square introduces vertical/horizontal stretch in SAM input.
  /// MobileSAM was trained on stretched-to-1024² ImageNet, so this
  /// matches its training distribution; the binary mask snaps back
  /// to a true square the worker upsamples NEAREST onto the original
  /// (non-square) JPEG, restoring the aspect.
  ///
  /// Returns nil if pixel buffer can't be wrapped as CIImage (would
  /// only happen for a corrupted ARFrame, which we've never seen in
  /// practice).
  static func captureRgbaSquare(
    pixelBuffer: CVPixelBuffer,
    target: Int
  ) -> Data? {
    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    guard srcWidth > 0, srcHeight > 0, target > 0 else {
      return nil
    }

    // CIImage(cvPixelBuffer:) accepts BiPlanar YUV directly and
    // CoreImage handles the YUV→RGB conversion lazily on render.
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

    // Squash to (target, target) via affine scale. Independent X/Y
    // scales = stretch (matches MobileSAM's training preprocessing).
    let scaleX = CGFloat(target) / CGFloat(srcWidth)
    let scaleY = CGFloat(target) / CGFloat(srcHeight)
    let scaled = ciImage.transformed(
      by: CGAffineTransform(scaleX: scaleX, y: scaleY)
    )

    // Pre-allocate the destination RGBA8 byte buffer. CIContext.render
    // writes into this directly (no extra copy).
    var rgba = Data(count: target * target * 4)
    let rect = CGRect(x: 0, y: 0, width: target, height: target)

    rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      guard let baseAddr = raw.baseAddress else { return }
      samCIContext.render(
        scaled,
        toBitmap: baseAddr,
        rowBytes: target * 4,
        bounds: rect,
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
    }
    return rgba
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


  // MARK: - Deprecated capture-during focus hook
  //
  // Older Dart clients may still call `lockFocusAtTapPoint` while the user is
  // aiming. We intentionally no-op it now: ARKit's continuous autofocus is
  // more stable than forcing a one-shot lens move from the app layer.
  @available(iOS 16.0, *)
  private func handleLockFocusAtTapPoint(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let x = (args["x"] as? NSNumber)?.doubleValue,
          let y = (args["y"] as? NSNumber)?.doubleValue else {
      result(FlutterError(
        code: "ar_lock_focus_bad_args",
        message: "lockFocusAtTapPoint requires {x: Double, y: Double} in [0,1]",
        details: nil
      ))
      return
    }
    let poi = CGPoint(x: CGFloat(x), y: CGFloat(y))
    restoreContinuousExposureFocus(reason: "deprecated tap focus")
    NSLog("[AetherARKit] lockFocusAtTapPoint ignored; keeping ARKit continuous auto at (\(poi.x), \(poi.y))")
    result([
      "x": x,
      "y": y,
      "applied": false,
    ])
  }

  /// Plan G W2 D1.5 Step 2: post-capture per-frame BiRefNet trigger.
  /// Loads JPEG → BiRefNetWrapper.Session.predictSaliency → writes raw
  /// fp32 mask (4 MB / 1024×1024) to disk. Runs on biRefNetQueue (serial)
  /// so concurrent calls from the Dart batch loop pipeline rather than
  /// thrash. Mask file format: 4-byte LE uint32 width + 4-byte LE uint32
  /// height + width×height×4 bytes of fp32 saliency [0,1].
  @available(iOS 16.0, *)
  private func handleRunBiRefNetOnJpeg(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let jpegPath = args["jpegPath"] as? String,
          let maskOutPath = args["maskOutPath"] as? String else {
      result(FlutterError(
        code: "ar_birefnet_bad_args",
        message: "runBiRefNetOnJpeg requires {jpegPath: String, maskOutPath: String}",
        details: nil
      ))
      return
    }
    biRefNetQueue.async { [weak self] in
      guard let self = self else { return }
      do {
        let session = try self.loadBiRefNetSessionIfNeeded()

        guard let uiImage = UIImage(contentsOfFile: jpegPath),
              let cgImage = uiImage.cgImage else {
          throw NSError(
            domain: "AetherARKit", code: 500,
            userInfo: [NSLocalizedDescriptionKey:
              "runBiRefNetOnJpeg: failed to load JPEG at \(jpegPath)"]
          )
        }

        let pred = try session.predictSaliency(image: cgImage)
        NSLog("[AetherARKit] BiRefNet on \(jpegPath as NSString).lastPathComponent: " +
              "fgRatio=\(pred.foregroundRatio) ms=\(pred.inferenceTimeMs)")

        // Wire format: u32 width + u32 height + N×fp32 mask.
        let w = UInt32(BiRefNetWrapper.inputSize).littleEndian
        let h = UInt32(BiRefNetWrapper.inputSize).littleEndian
        var blob = Data(capacity: 8 + pred.mask.count * 4)
        withUnsafeBytes(of: w) { blob.append(contentsOf: $0) }
        withUnsafeBytes(of: h) { blob.append(contentsOf: $0) }
        pred.mask.withUnsafeBufferPointer { buf in
          blob.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        // Ensure parent dir exists.
        let parent = (maskOutPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
          atPath: parent, withIntermediateDirectories: true
        )
        try blob.write(to: URL(fileURLWithPath: maskOutPath))

        DispatchQueue.main.async {
          result([
            "width": BiRefNetWrapper.inputSize,
            "height": BiRefNetWrapper.inputSize,
            "fgRatio": Double(pred.foregroundRatio),
            "inferenceTimeMs": pred.inferenceTimeMs,
            "ok": true,
          ])
        }
      } catch {
        NSLog("[AetherARKit] runBiRefNetOnJpeg failed: \(error)")
        DispatchQueue.main.async {
          result(FlutterError(
            code: "ar_birefnet_failed",
            message: "BiRefNet inference failed: \(error.localizedDescription)",
            details: nil
          ))
        }
      }
    }
  }

  @available(iOS 16.0, *)
  private func loadBiRefNetSessionIfNeeded() throws -> BiRefNetWrapper.Session {
    if let cached = biRefNetSession as? BiRefNetWrapper.Session {
      return cached
    }
    let session = try BiRefNetWrapper.Session()
    biRefNetSession = session
    NSLog("[AetherARKit] BiRefNet session loaded (lite GPU, single track)")
    return session
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

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    if !loggedFirstFrame {
      loggedFirstFrame = true
      NSLog("[AetherARKit] first ARFrame received")
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
  }

  func sessionWasInterrupted(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interrupted")
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interruption ended")
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
    guard let spec = AetherARKitPlugin.photoCardSpecs[name],
          let raw = UIImage(contentsOfFile: spec.path) else {
      NSLog("[PHOTOCARD] renderer: spec or image MISSING for %@", name)
      return
    }
    NSLog("[PHOTOCARD] renderer building quad for %@ (%d corners)", name,
          spec.localCorners.count)

    // Orientation, DETERMINISTICALLY (no displayTransform convention guessing):
    // rotate the texture to upright PORTRAIT by pixel dimensions, then aspect-
    // FILL it onto the screen-aligned quad with computed UVs (crop, no stretch).
    let image = Self.uprightPortrait(raw)
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
    NSLog("[PHOTOCARD] tex raw=%.0fx%.0f upright=%.0fx%.0f cgUp=%dx%d texAsp=%.3f quadAsp=%.3f (EXPECT upright h>w, texAsp<1~0.75, quadAsp~0.46)",
          raw.size.width, raw.size.height, image.size.width, image.size.height,
          image.cgImage?.width ?? -1, image.cgImage?.height ?? -1,
          texAspect, quadAspect)

    let positionSource = SCNGeometrySource(vertices: spec.localCorners)
    let texSource = SCNGeometrySource(textureCoordinates: texUVs)
    let element = SCNGeometryElement(indices: [Int32]([0, 1, 2, 0, 2, 3]),
                                     primitiveType: .triangles)
    let geometry = SCNGeometry(sources: [positionSource, texSource],
                               elements: [element])
    let mat = SCNMaterial()
    mat.diffuse.contents = image
    mat.isDoubleSided = true
    mat.lightingModel = .constant       // unlit — show the photo as captured
    mat.transparency = 0.75             // RS-style translucent (more see-through)
    mat.writesToDepthBuffer = false
    mat.diffuse.wrapS = .clamp
    mat.diffuse.wrapT = .clamp
    geometry.materials = [mat]

    // RS-style FRAME: a black border RING around the photo. Placeholder colour —
    // will flip to WHITE once this frame's SfM registration succeeds (flag wired
    // later). Built as a hollow ring (inner edge == photo edge, outer == +3%) so
    // it never overlaps the photo (no z-fight, no darkening of the image).
    let inner = spec.localCorners
    let outer = inner.map { SCNVector3($0.x * 1.03, $0.y * 1.03, $0.z * 1.03) }
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

    node.addChildNode(SCNNode(geometry: frameGeo))       // border behind/around
    node.addChildNode(SCNNode(geometry: geometry))       // photo on top
  }

  /// Returns a UIImage whose BACKING PIXELS are physically upright PORTRAIT
  /// (identity .up orientation, height > width), with the EXIF/imageOrientation
  /// baked into the pixels. Canonical UIKit "normalize orientation" recipe:
  /// `UIImage(contentsOfFile:)` keeps RAW landscape pixels with only
  /// `.imageOrientation == .right` metadata, which SceneKit/CIImage ignore when
  /// reading `.cgImage` (→ sideways texture). `img.draw(in:)` HONORS
  /// imageOrientation, so redrawing into a renderer sized by `img.size` (already
  /// orientation-corrected → portrait) bakes upright portrait pixels. Self-
  /// describing: reads imageOrientation at runtime, so it can't drift.
  private static func uprightPortrait(_ img: UIImage) -> UIImage {
    // Fast path: already upright .up AND already portrait pixels — use as-is.
    if img.imageOrientation == .up,
       let cg = img.cgImage, cg.height >= cg.width {
      return img
    }
    let fmt = UIGraphicsImageRendererFormat.default()
    fmt.scale = 1   // 1:1 pixels — don't let @2x/@3x inflate the texture
    let renderer = UIGraphicsImageRenderer(size: img.size, format: fmt)
    return renderer.image { _ in
      img.draw(in: CGRect(origin: .zero, size: img.size))
    }
  }

  /// Fires when ARKit removes our anchor (re-lock or stopSession).
  /// SceneKit auto-removes child nodes when the parent goes — nothing
  /// to do, but log for visibility.
  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    guard anchor.name == Self.subjectAnchorName else { return }
    NSLog("[AetherARKitPreview] subject anchor removed; marker went with it")
  }

  deinit {
    pollTimer?.invalidate()
  }
}
