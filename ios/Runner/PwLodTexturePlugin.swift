// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// ^ Upstream header kept for the two shapes taken from flutter/packages
//   @ fbc80a62002251eaad5c714195bb5ebd22e94b14,
//   packages/camera/camera_avfoundation/darwin/camera_avfoundation/Sources/camera_avfoundation/
//     CameraPlugin.swift:259-268  create off the platform thread, register the texture on it
//     CameraPlugin.swift:341-348  dispose = unregisterTexture on the platform thread, then close
//                                 on the plugin's own queue
// BSD-3-Clause; full license text in PwLodTexture.swift's header.
//
// ── PocketWorld: PwLodTexturePlugin.swift ─────────────────────────────────────────────────
// MethodChannel 'pw_lod_texture' for the LOD point-cloud viewer (plan L4/L6). Dart side:
// lib/point_cloud_lod/lod_bridge.dart — map keys are the C field names of the frozen
// vendor/aether_lod/include/pwlod_viewer.h (v3).
// [v3 2026-09-24, production 171] Registered by the production AppDelegate. Changes against
// feat/lod-viewer@56f3bb9: ONE pwlod_gpu for the whole app (created on the first `create`,
// never destroyed; coordinator: 「GPU 设备整个 App 只建一个,每个视图各建一个 viewer」);
// `setStyle` / `setPoints` (ABI v3); the M1 bench entry (`runBench`, `launchArgs`) is NOT carried
// into production (「M1 入口不接进生产」), so pwlod_run is unreferenced here.
//
// Plugin shape (register / NotificationCenter lifecycle hooks) follows the in-house
// ios/Runner/AetherTexturePlugin.swift:78-96, :107-112 @875fe67. Threads:
//   main       create's registration, setCamera, setParams, stats, dispose, pause/resume
//   per-texture ioQueue   loadOctree and the texture's teardown (never overlap)
//   buildQueue            pwlod_build_from_ply / pwlod_verify_octree (BLOCKING, header :203)
//   createQueue           the app-wide GPU (first use) and each texture's viewer + ring
// Results always go back to Flutter on the main thread.
import Flutter
import Foundation
import UIKit

final class PwLodTexturePlugin: NSObject, FlutterPlugin {
  static let channelName = "pw_lod_texture"

  private let textures: FlutterTextureRegistry
  private var registered: [Int64: PwLodTexture] = [:]
  private let createQueue = DispatchQueue(label: "io.pocketworld.lod.create", qos: .userInitiated)
  private let buildQueue = DispatchQueue(label: "io.pocketworld.lod.build", qos: .userInitiated)
  /// The app-wide device; only touched on createQueue. Created once, kept for the process.
  private var sharedGpu: UnsafeMutablePointer<pwlod_gpu>?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = PwLodTexturePlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    // AetherTexturePlugin.swift:107-112 @875fe67: iOS refuses GPU work in the background.
    let nc = NotificationCenter.default
    nc.addObserver(
      self, selector: #selector(handleBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(handleForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleBackground() {
    for t in registered.values { t.pause() }
  }

  @objc private func handleForeground() {
    for t in registered.values { t.resume() }
  }

  private static func fail(_ result: @escaping FlutterResult, _ code: String, _ message: String) {
    pwLodEnsureToRunOnMainQueue { result(FlutterError(code: code, message: message, details: nil)) }
  }

  private static func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    pwLodEnsureToRunOnMainQueue { result(value) }
  }

  private func texture(_ a: [String: Any], _ result: @escaping FlutterResult) -> PwLodTexture? {
    guard let id = (a["textureId"] as? NSNumber)?.int64Value, let t = registered[id] else {
      result(FlutterError(code: "PWLOD_SHELL_UNKNOWN_TEXTURE", message: "no such textureId", details: nil))
      return nil
    }
    return t
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create": create(a, result)
    case "loadOctree": loadOctree(a, result)
    case "setCamera": setCamera(a, result)
    case "setParams":
      guard let t = texture(a, result) else { return }
      let s = t.setParams(a)
      s == PWLOD_OK ? result(nil) : result(FlutterError(code: pwLodStatusName(s), message: "set_params", details: nil))
    case "stats":
      guard let t = texture(a, result) else { return }
      result(t.stats())
    case "setStyle":
      guard let t = texture(a, result) else { return }
      let s = t.setStyle(a)
      s == PWLOD_OK ? result(nil) : result(FlutterError(code: pwLodStatusName(s), message: "set_style", details: nil))
    case "setPoints": setPoints(a, result)
    case "buildFromPly": buildFromPly(a, result)
    case "verifyOctree": verifyOctree(a, result)
    case "dispose": dispose(a, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - viewer

  private func create(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let w = PwLodArgs.int(a, "viewport_width_px"), let h = PwLodArgs.int(a, "viewport_height_px"),
      w > 0, h > 0, w <= 16384, h <= 16384
    else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "viewport_width_px/height_px", details: nil))
      return
    }
    // CameraPlugin.swift:259-268: build off the platform thread, register on it.
    createQueue.async { [weak self] in
      let made: PwLodTexture
      do {
        guard let gpu = try self?.gpuOnCreateQueue() else {
          PwLodTexturePlugin.fail(result, "PWLOD_SHELL_GONE", "plugin released")
          return
        }
        made = try PwLodTexture.make(widthPx: UInt32(w), heightPx: UInt32(h), gpu: gpu)
      } catch let e as PwLodError {
        PwLodTexturePlugin.fail(result, e.code, e.message)
        return
      } catch {
        PwLodTexturePlugin.fail(result, "PWLOD_SHELL_UNKNOWN", "\(error)")
        return
      }
      pwLodEnsureToRunOnMainQueue {
        guard let self = self else {
          made.ioQueue.async { made.close() }
          result(FlutterError(code: "PWLOD_SHELL_GONE", message: "plugin released", details: nil))
          return
        }
        let id = self.textures.register(made)
        self.registered[id] = made
        made.attach(textureId: id, registry: self.textures)
        // Created while in the background: no GPU work until willEnterForeground resumes it.
        let backgrounded = UIApplication.shared.applicationState == .background
        let s = backgrounded ? PWLOD_OK : made.resume()
        guard s == PWLOD_OK else {
          self.textures.unregisterTexture(id)
          self.registered.removeValue(forKey: id)
          made.ioQueue.async { made.close() }
          result(FlutterError(code: pwLodStatusName(s), message: "pwlod_viewer_start", details: nil))
          return
        }
        result([
          "textureId": NSNumber(value: id),
          "version": made.version,
          "backend": NSNumber(value: made.backend),
          "viewport_width_px": NSNumber(value: made.widthPx),
          "viewport_height_px": NSNumber(value: made.heightPx),
        ])
      }
    }
  }

  /// createQueue only. PwLodSurfaceCreateGpu = pwlod_gpu_create + the two IOSurface features
  /// (PwLodSurface.h). A failure is retried on the next `create`; a success is kept for the app's
  /// lifetime (pwlod_gpu_destroy must follow every viewer on it, and viewers come and go).
  private func gpuOnCreateQueue() throws -> UnsafeMutablePointer<pwlod_gpu> {
    if let g = sharedGpu { return g }
    let g = UnsafeMutablePointer<pwlod_gpu>.allocate(capacity: 1)
    g.initialize(to: pwlod_gpu())
    let s = PwLodSurfaceCreateGpu(g)
    guard s == PWLOD_OK else {
      g.deallocate()
      throw PwLodError(code: pwLodStatusName(s), message: "pwlod_gpu_create (IOSurface features)")
    }
    sharedGpu = g
    return g
  }

  /// v3 set_points on the texture's ioQueue (a 1 M-point set is ~15 MB to copy; keep it off the
  /// main thread). xyz Float32List (3·n), rgb Uint8List (≥ 3·n), optional visibility Uint8List (n).
  private func setPoints(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let t = texture(a, result) else { return }
    guard let xyz = PwLodArgs.typedData(a, "xyz", .float32),
      let rgb = PwLodArgs.typedData(a, "rgb", .uInt8),
      let count = PwLodArgs.int(a, "count"), count >= 0
    else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "setPoints xyz/rgb/count", details: nil))
      return
    }
    let colored = (a["colored"] as? NSNumber)?.boolValue ?? true
    let vis = PwLodArgs.typedData(a, "visibility", .uInt8)
    t.ioQueue.async {
      let s = t.setPoints(xyz: xyz, rgb: rgb, count: UInt64(count), colored: colored, visibility: vis)
      s == PWLOD_OK
        ? PwLodTexturePlugin.reply(result, nil)
        : PwLodTexturePlugin.fail(result, pwLodStatusName(s), "set_points n=\(count)")
    }
  }

  private func loadOctree(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let t = texture(a, result) else { return }
    guard let dir = PwLodArgs.string(a, "octree_dir") else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "octree_dir", details: nil))
      return
    }
    t.ioQueue.async {
      let s = t.loadOctree(dir)
      s == PWLOD_OK
        ? PwLodTexturePlugin.reply(result, nil)
        : PwLodTexturePlugin.fail(result, pwLodStatusName(s), "load_octree \(dir)")
    }
  }

  private func setCamera(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let t = texture(a, result) else { return }
    guard let vp = PwLodArgs.float64s(a, "view_proj_row_major", count: 16),
      let eye = PwLodArgs.float64s(a, "eye_world", count: 3),
      let focal = PwLodArgs.double(a, "focal_px"),
      let orbit = PwLodArgs.double(a, "orbit_distance"),
      let mix = PwLodArgs.double(a, "ortho_mix"),
      let vw = PwLodArgs.int(a, "viewport_width_px"),
      let vh = PwLodArgs.int(a, "viewport_height_px"),
      vw > 0, vh > 0
    else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "setCamera arguments", details: nil))
      return
    }
    let s = t.setCamera(
      viewProjRowMajor: vp, eyeWorld: eye, focalPx: focal, orbitDistance: orbit,
      orthoMix: mix, viewportWidthPx: UInt32(vw), viewportHeightPx: UInt32(vh))
    s == PWLOD_OK ? result(nil) : result(FlutterError(code: pwLodStatusName(s), message: "set_camera", details: nil))
  }

  /// CameraPlugin.swift:341-348: unregister on the platform thread, close on our own queue.
  private func dispose(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let id = (a["textureId"] as? NSNumber)?.int64Value else {
      result(nil)
      return
    }
    textures.unregisterTexture(id)
    if let t = registered.removeValue(forKey: id) {
      t.ioQueue.async { t.close() }
    }
    result(nil)
  }

  // MARK: - plan L6: on-device build + self-check

  private func buildFromPly(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let ply = PwLodArgs.string(a, "ply_path"), let out = PwLodArgs.string(a, "out_dir"),
      let chunk = PwLodArgs.string(a, "chunk_dir")
    else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "ply_path/out_dir/chunk_dir", details: nil))
      return
    }
    let budget = Int32(clamping: PwLodArgs.int(a, "memory_budget_mb") ?? 0)
    let threads = Int32(clamping: PwLodArgs.int(a, "threads") ?? 0)
    buildQueue.async {
      let fm = FileManager.default
      do {
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: chunk, withIntermediateDirectories: true)
      } catch {
        PwLodTexturePlugin.fail(result, "PWLOD_ERR_IO", "mkdir: \(error)")
        return
      }
      var report = pwlod_build_report()
      var err = [CChar](repeating: 0, count: 1024)
      let peak = PwLodFootprintPeak()
      peak.start()
      let t0 = DispatchTime.now().uptimeNanoseconds
      let s = pwlod_build_from_ply(ply, out, chunk, budget, threads, &report, &err, UInt32(err.count))
      let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
      var m = peak.stop()
      // chunk_dir is caller-owned scratch the caller deletes afterwards (pwlod_viewer.h:204).
      var removed = true
      do { try fm.removeItem(atPath: chunk) } catch { removed = !fm.fileExists(atPath: chunk) }
      m["status"] = pwLodStatusName(s)
      m["error"] = String(cString: err)
      m["ply_points"] = pwLodWireInt(report.ply_points)
      m["tree_points"] = pwLodWireInt(report.tree_points)
      m["octree_bin_bytes"] = pwLodWireInt(report.octree_bin_bytes)
      m["nodes"] = NSNumber(value: report.nodes)
      m["elapsed_ms"] = report.elapsed_ms
      m["shell_wall_ms"] = wallMs
      m["chunk_dir_removed"] = removed
      m["threads"] = NSNumber(value: threads)
      m["memory_budget_mb"] = NSNumber(value: budget)
      PwLodTexturePlugin.reply(result, m)
    }
  }

  private func verifyOctree(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let dir = PwLodArgs.string(a, "octree_dir") else {
      result(FlutterError(code: "PWLOD_ERR_ARG", message: "octree_dir", details: nil))
      return
    }
    buildQueue.async {
      var r = pwlod_verify_report()
      let t0 = DispatchTime.now().uptimeNanoseconds
      let s = pwlod_verify_octree(dir, &r)
      PwLodTexturePlugin.reply(result, [
        "status": pwLodStatusName(s),
        "tree_points": pwLodWireInt(r.tree_points),
        "octree_bin_bytes": pwLodWireInt(r.octree_bin_bytes),
        "nodes": NSNumber(value: r.nodes),
        "leaves": NSNumber(value: r.leaves),
        "leaves_selected": NSNumber(value: r.leaves_selected),
        "byte_gaps": NSNumber(value: r.byte_gaps),
        "byte_overlaps": NSNumber(value: r.byte_overlaps),
        "shell_wall_ms": Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
      ])
    }
  }
}
