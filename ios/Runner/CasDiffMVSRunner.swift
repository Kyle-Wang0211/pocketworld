import Foundation
import CoreML
import ImageIO
import CoreGraphics

/// [L1-ARBITRATE 2026-07-12] CasDiffMVS CoreML runner for the ghost-layer L1
/// arbitration — the PLATFORM SHIM half of the chain. All scheduling and all
/// numeric contracts live in C++ (aether_l1_plan.h writes
/// `<db_dir>/arbitration_plan.json` at finalize tail when AETHER_GHOST_MASK=1;
/// aether_sfm_arbitrate consumes the depth bins this class writes). This file
/// only: decodes JPEGs (off-main), resizes to the model's 896x512 input
/// (cv2.INTER_AREA-equivalent separable area average — parity band recorded
/// on the Mac harness), copies the plan's precomputed projection matrices +
/// inverse-depth bins into MLMultiArrays, runs CasDiffMVS_fp32 with
/// computeUnits = .cpuAndGPU (ANE is BANNED: Apple-only + it garbages the
/// 3D-conv/grid_sample ops — 签决), and writes
/// `<db_dir>/l1_depth_<frameId>.bin` (L1DP v1: header + depth f32 HxW + conf
/// f32 HxW, atomic tmp+rename).
///
/// Model asset: CasDiffMVS_fp32.mlpackage (8.5MB, ios/Runner/Models/, Xcode
/// compiles it into CasDiffMVS_fp32.mlmodelc in the bundle). Outputs
/// var_16044 = depth / var_16002 = photometric confidence — verified on the
/// Mac harness (coremltools, cap46/47); a value-range guard re-checks at
/// runtime because the traced names are toolchain-generated.
///
/// Concurrency: everything runs on the caller's queue (AetherARKitPlugin
/// dispatches on a dedicated serial utility queue — decode must NEVER run on
/// the platform main thread, colorize 主线程教训). Fail-soft: any error
/// returns a message; the Dart side treats a failed run as "no depth bins" —
/// the C++ arbitration then abstains (fail-open, 误隐=0 policy).
final class CasDiffMVSRunner {

  struct RunResult {
    var ok = false
    var refsPlanned = 0
    var refsDone = 0
    var totalMs = 0
    var decodeMs = 0
    var inferMs = 0
    var perRefMs: [Int] = []
    var error: String?
  }

  private static let procW = 896
  private static let procH = 512
  private static let nViews = 5
  private static let nDepth = 384

  // Decoded+resized CHW float cache (a frame recurs as ref/src across refs).
  // ~5.5MB per entry; capped — eviction only re-decodes, never changes bytes.
  private static let cacheCap = 16
  private var chwCache: [String: [Float]] = [:]
  private var cacheOrder: [String] = []

  private var model: MLModel?

  /// Locate + load the model once. Prefers the Xcode-compiled .mlmodelc in
  /// the bundle; falls back to compiling a raw .mlpackage (first-run only,
  /// cached by the OS in tmp).
  private func loadModel() throws -> MLModel {
    if let m = model { return m }
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .cpuAndGPU  // NEVER .all — ANE ban (签决)
    var url = Bundle.main.url(forResource: "CasDiffMVS_fp32",
                              withExtension: "mlmodelc")
    if url == nil,
       let pkg = Bundle.main.url(forResource: "CasDiffMVS_fp32",
                                 withExtension: "mlpackage") {
      url = try MLModel.compileModel(at: pkg)
    }
    guard let modelURL = url else {
      throw NSError(domain: "CasDiffMVSRunner", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "CasDiffMVS_fp32 model not in bundle"])
    }
    let m = try MLModel(contentsOf: modelURL, configuration: cfg)
    model = m
    return m
  }

  /// Decode a saved capture JPEG WITHOUT the EXIF transform (SfM poses/K live
  /// in raw sensor landscape space — decodeJpegForColor convention) and
  /// area-resize to procW x procH, returning CHW float32 in [0,1].
  /// Quantizes to uint8 after the resize to mirror the Mac reference
  /// (cv2 uint8 resize then /255) — the recorded parity band applies.
  private func decodeResizeCHW(_ path: String) throws -> [Float] {
    if let hit = chwCache[path] { return hit }
    guard let src = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceShouldCache: false] as CFDictionary) else {
      throw NSError(domain: "CasDiffMVSRunner", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "decode failed: \(path)"])
    }
    let sw = img.width, sh = img.height
    // RGBA8 raster (no EXIF rotation — ImageIO never applies it here).
    var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
    guard let ctx = CGContext(
            data: &rgba, width: sw, height: sh, bitsPerComponent: 8,
            bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
              CGBitmapInfo.byteOrder32Big.rawValue) else {
      throw NSError(domain: "CasDiffMVSRunner", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "CGContext failed"])
    }
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))

    // ── separable INTER_AREA: per-axis fractional box weights ──
    func axisWeights(_ srcN: Int, _ dstN: Int)
      -> (starts: [Int], counts: [Int], weights: [Float]) {
      let scale = Double(srcN) / Double(dstN)
      var starts = [Int](repeating: 0, count: dstN)
      var counts = [Int](repeating: 0, count: dstN)
      var weights: [Float] = []
      for d in 0..<dstN {
        let f0 = Double(d) * scale
        let f1 = f0 + scale
        let s0 = Int(f0.rounded(.down))
        let s1 = min(srcN, Int(f1.rounded(.up)))
        starts[d] = s0
        counts[d] = s1 - s0
        for s in s0..<s1 {
          let ov = min(f1, Double(s + 1)) - max(f0, Double(s))
          weights.append(Float(ov / scale))
        }
      }
      return (starts, counts, weights)
    }
    let (xs, xc, xw) = axisWeights(sw, Self.procW)
    let (ys, yc, yw) = axisWeights(sh, Self.procH)

    // horizontal pass: (sh x procW x 3) float
    var mid = [Float](repeating: 0, count: sh * Self.procW * 3)
    rgba.withUnsafeBufferPointer { rp in
      mid.withUnsafeMutableBufferPointer { mp in
        for y in 0..<sh {
          let rowOff = y * sw * 4
          let midOff = y * Self.procW * 3
          var wIdx = 0
          for x in 0..<Self.procW {
            var r: Float = 0, g: Float = 0, b: Float = 0
            let s0 = xs[x]
            for k in 0..<xc[x] {
              let w = xw[wIdx + k]
              let p = rowOff + (s0 + k) * 4
              r += w * Float(rp[p])
              g += w * Float(rp[p + 1])
              b += w * Float(rp[p + 2])
            }
            wIdx += xc[x]
            let o = midOff + x * 3
            mp[o] = r
            mp[o + 1] = g
            mp[o + 2] = b
          }
        }
      }
    }
    // vertical pass + uint8 quantization + CHW [0,1]
    let plane = Self.procW * Self.procH
    var chw = [Float](repeating: 0, count: 3 * plane)
    mid.withUnsafeBufferPointer { mp in
      chw.withUnsafeMutableBufferPointer { cp in
        var wIdx = 0
        for y in 0..<Self.procH {
          let s0 = ys[y]
          for x in 0..<Self.procW {
            var r: Float = 0, g: Float = 0, b: Float = 0
            for k in 0..<yc[y] {
              let w = yw[wIdx + k]
              let o = (s0 + k) * Self.procW * 3 + x * 3
              r += w * mp[o]
              g += w * mp[o + 1]
              b += w * mp[o + 2]
            }
            let o = y * Self.procW + x
            cp[o] = min(255, max(0, r)).rounded(.toNearestOrEven) / 255.0
            cp[plane + o] = min(255, max(0, g)).rounded(.toNearestOrEven) / 255.0
            cp[2 * plane + o] = min(255, max(0, b)).rounded(.toNearestOrEven) / 255.0
          }
          wIdx += yc[y]
        }
      }
    }
    chwCache[path] = chw
    cacheOrder.append(path)
    if cacheOrder.count > Self.cacheCap {
      chwCache.removeValue(forKey: cacheOrder.removeFirst())
    }
    return chw
  }

  private func multiArray(_ shape: [NSNumber], _ values: [Float]) throws
    -> MLMultiArray {
    let arr = try MLMultiArray(shape: shape, dataType: .float32)
    values.withUnsafeBufferPointer { bp in
      arr.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        .update(from: bp.baseAddress!, count: values.count)
    }
    return arr
  }

  /// Atomic L1DP v1 depth-bin write.
  private func writeDepthBin(dbDir: String, frameId: Int, depth: [Float],
                             conf: [Float]) throws {
    var data = Data(capacity: 20 + depth.count * 4 + conf.count * 4)
    data.append(contentsOf: [0x4C, 0x31, 0x44, 0x50])  // "L1DP"
    var v: UInt32 = 1
    withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    var fid = Int32(frameId)
    withUnsafeBytes(of: &fid) { data.append(contentsOf: $0) }
    var h = UInt32(Self.procH), w = UInt32(Self.procW)
    withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
    depth.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    conf.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    let dst = URL(fileURLWithPath: dbDir)
      .appendingPathComponent("l1_depth_\(frameId).bin")
    let tmp = dst.appendingPathExtension("tmp")
    try data.write(to: tmp)
    _ = try? FileManager.default.removeItem(at: dst)
    try FileManager.default.moveItem(at: tmp, to: dst)
  }

  /// Run the whole plan. Synchronous — call on a background queue only.
  func run(planPath: String, dbDir: String) -> RunResult {
    var res = RunResult()
    let t0 = CFAbsoluteTimeGetCurrent()
    do {
      let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
      guard let plan = try JSONSerialization.jsonObject(with: planData)
              as? [String: Any],
            let refs = plan["refs"] as? [[String: Any]] else {
        res.error = "plan parse failed"
        return res
      }
      res.refsPlanned = refs.count
      let m = try loadModel()
      // output naming guard (see header): pick by value range on first ref
      var depthKey = "var_16044"
      var confKey = "var_16002"
      for ref in refs {
        guard let fid = ref["frame_id"] as? Int,
              let views = ref["views"] as? [[String: Any]],
              views.count == Self.nViews,
              let dv = ref["dv"] as? [Any], dv.count == Self.nDepth,
              let proj = ref["proj"] as? [String: Any] else { continue }
        var feats: [String: MLFeatureValue] = [:]
        let tDec = CFAbsoluteTimeGetCurrent()
        var decodeOk = true
        for (i, view) in views.enumerated() {
          guard let jpeg = view["jpeg"] as? String, !jpeg.isEmpty else {
            decodeOk = false
            break
          }
          let chw = try decodeResizeCHW(jpeg)
          feats["i\(i)"] = MLFeatureValue(multiArray: try multiArray(
            [1, 3, NSNumber(value: Self.procH), NSNumber(value: Self.procW)],
            chw))
        }
        if !decodeOk { continue }
        res.decodeMs += Int((CFAbsoluteTimeGetCurrent() - tDec) * 1000)
        for st in 1...4 {
          guard let p = proj["stage\(st)"] as? [Any], p.count == 160 else {
            decodeOk = false
            break
          }
          feats["p\(st)"] = MLFeatureValue(multiArray: try multiArray(
            [1, 5, 2, 4, 4], p.map { Float(($0 as? NSNumber)?.doubleValue ?? 0) }))
        }
        if !decodeOk { continue }
        feats["dv"] = MLFeatureValue(multiArray: try multiArray(
          [1, NSNumber(value: Self.nDepth)],
          dv.map { Float(($0 as? NSNumber)?.doubleValue ?? 0) }))

        let tInf = CFAbsoluteTimeGetCurrent()
        let out = try m.prediction(
          from: try MLDictionaryFeatureProvider(dictionary: feats))
        let refMs = Int((CFAbsoluteTimeGetCurrent() - tInf) * 1000)
        res.perRefMs.append(refMs)
        res.inferMs += refMs

        func plane(_ name: String) -> [Float]? {
          guard let arr = out.featureValue(for: name)?.multiArrayValue else {
            return nil
          }
          let n = Self.procW * Self.procH
          guard arr.count == n else { return nil }
          let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
          return [Float](UnsafeBufferPointer(start: p, count: n))
        }
        guard var depth = plane(depthKey), var conf = plane(confKey) else {
          continue
        }
        // range guard: conf lives in [0,1]; depth spans metres (dv max >1.5)
        if (depth.max() ?? 0) <= 1.01 && (conf.max() ?? 0) > 1.5 {
          swap(&depth, &conf)
          swap(&depthKey, &confKey)
        }
        try writeDepthBin(dbDir: dbDir, frameId: fid, depth: depth,
                          conf: conf)
        res.refsDone += 1
      }
      res.ok = res.refsDone > 0
      if !res.ok && res.error == nil {
        res.error = "no ref produced a depth bin"
      }
    } catch {
      res.error = "\(error)"
    }
    res.totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    // The CHW cache is per-run scratch — free the ~90MB before returning.
    chwCache.removeAll()
    cacheOrder.removeAll()
    return res
  }
}
