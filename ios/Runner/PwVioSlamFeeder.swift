// PwVioSlamFeeder.swift — 把 ARKit 帧与 CoreMotion 样本喂给 XRSLAM。
//
// 为什么在原生侧喂:ARFrame 本来就在原生。从 Dart 喂意味着每帧把像素缓冲跨
// FFI 边界拷一次 —— 1920×1440 灰度 = 2.7 MB/帧,30fps 就是 83 MB/s 的纯拷贝。
// 原生侧直接喂是**零拷贝**:XRSLAMImage.data 直接指向 CVPixelBuffer 的亮度平面。
// Dart 侧只读位姿和健康状态,那是几十字节。
//
// 三条来自今天实测的硬约束:
//   ① **按时间戳配对,不按到达顺序** —— 实测 ARFrame 与 CoreMotion 的投递延迟
//      差 34.76 ms(相机链比 IMU 链慢一个数量级)。按到达顺序配会错一整帧,
//      100°/s 下就是 3.5° 姿态误差。所幸两路时间戳同域(都贴 CLOCK_UPTIME_RAW,
//      实测累计休眠 61.69h 下判据信噪比充足),所以直接用时间戳即可。
//   ② **视觉更新降频** —— ARCore 工程师原话:他们的 VIO 只跑约 10Hz,
//      "running 60FPS ... introduces problems with increased device heating"。
//      我们按 30Hz 跑完整 VIO 是在跟一个只做 1/3 工作量的对手比发热。
//   ③ **不丢帧** —— 降的是 RunOneFrame 的节奏,不是丢 PushImage。
//      被跳过的帧仍然进了核内队列,只是不立刻触发求解。

import ARKit
import CoreMotion
import Foundation

@available(iOS 11.0, *)
public final class PwVioSlamFeeder {
  public static let shared = PwVioSlamFeeder()
  private init() {}

  private let lock = NSLock()

  // ── 降采样到 VIO 的工作分辨率 ──
  //
  // ARKit 的 capturedImage 是 1920×1440。按全分辨率喂实测直接把 App 撑崩
  // (imagesPushed=808 / slamState 一直是 0 / 队列只进不出 / 20 秒被 iOS 杀)。
  //
  // 目标分辨率 640×480 = 1920×1440 ÷3。见 kVioDownsampleFactor 的完整依据。
  //
  // 3×3 盒式平均,整数比例无插值歧义,两端能写出逐位相同的实现 ——
  // 不用 vImage(Apple 专有,会制造跨端不对称;同今天关掉 ACCELERATESPARSE 的理由)。
  private var scratch: UnsafeMutablePointer<UInt8>?
  private var scratchCapacity = 0
  private var vioWidth = 0, vioHeight = 0

  /// 降采样倍数。1920×1440 ÷3 = **640×480**。
  ///
  /// 🔴 这个数字的依据经过一次彻底的反转,写清楚免得再翻烧饼:
  ///
  /// 我曾把它设成 2(→960×720),依据是我引的一句话:"VIO 参数按 VGA 调,
  /// 而在 quarter resolution (960×540) 表现更好",出处标的是
  /// Delmerico & Scaramuzza ICRA 2018。**那是误引。** 把该 PDF 全文
  /// grep resolution|downsampl|quarter|960|540 → 零命中,那篇论文
  /// **根本没有分辨率实验**。真实链条是 Joshi et al. ICRA 2022 转述 TUM-VI,
  /// 而 TUM-VI 自己也没做过该对比(Table III/IV 全是 512×512)。三层转述,
  /// 源头是空的。
  ///
  /// 之后做了一次全球多语言穷举调研(52 agent / 297 条声明 / 118 条死胡同):
  ///   • **图像分辨率 vs VIO 精度的消融实验,全球不存在。**
  ///     逐篇核查 Delmerico / UZH-FPV / KAIST-VIO / TUM-VI / Kimera /
  ///     MSCKF-VIO / SVO2 / VIODE;VINS-Mono、VINS-Fusion、ORB-SLAM3、
  ///     OpenVINS 四个 issue tracker 检索全部 0 命中。
  ///     (未覆盖:中文学位论文库 CNKI/万方。)
  ///   • 640×480 是**唯一有先例的配置**:RD-VIO 论文 §IV-D-4 的
  ///     iPhone X 640×480 是全文唯一一处移动端分辨率陈述;上游 18 份
  ///     iPhone 配置全部 resolution: [640, 480];全 GitHub、71 个 fork、
  ///     64 篇引用论文里**没有任何人在 640×480 之外跑过 XRSLAM**。
  ///
  /// ⛔ 所以这条注释**不是**在说"640×480 够用"—— 没有人证明过。
  ///    它是在说"这是唯一有先验的点"。要改分辨率,那是一个**必须自己做**
  ///    的单变量 A/B,不是能查文献解决的问题。
  ///    我们自己的 EuRoC A/B 已经证明这个耦合很暴烈:752×480 → 376×240
  ///    参数不动,尺度误差从 0.28~0.93% 崩到 98~99.98%(s≈0.0002)。
  private static let kVioDownsampleFactor = 3

  /// 给 Dart 侧做交叉校验用。**唯一真源在上面那个常量**,这里只是暴露。
  static var vioDownsampleFactorForDart: Int { kVioDownsampleFactor }

  /// N×N 盒式降采样。返回 nil 表示尺寸不是 N 的整数倍(不猜,直接拒绝)。
  private func downsampleBox(src: UnsafePointer<UInt8>, srcW: Int, srcH: Int,
                             srcStride: Int) -> (UnsafeMutablePointer<UInt8>, Int, Int)? {
    let n = Self.kVioDownsampleFactor
    guard n >= 1, srcW % n == 0, srcH % n == 0 else { return nil }
    let dw = srcW / n, dh = srcH / n
    let need = dw * dh
    if scratchCapacity < need {
      scratch?.deallocate()
      scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: need)
      scratchCapacity = need
    }
    guard let dst = scratch else { return nil }
    let area = n * n
    let half = area / 2          // 四舍五入的偏置
    for y in 0..<dh {
      let orow = dst + y * dw
      for x in 0..<dw {
        var sum = 0
        for dy in 0..<n {
          let row = src + (y * n + dy) * srcStride + x * n
          for dx in 0..<n { sum += Int(row[dx]) }
        }
        orow[x] = UInt8((sum + half) / area)
      }
    }
    vioWidth = dw; vioHeight = dh
    return (dst, dw, dh)
  }

  /// XRSLAM 是全局单例(C API 没有句柄参数),所以这里也只能有一个实例状态。
  private var created = false

  /// 视觉更新目标周期。默认 0.1s = 10Hz,依据见文件头 ②。
  private var runPeriodSeconds: Double = 0.1
  private var lastRunSeconds: Double = 0

  // 统计 —— 全部是事实,不做解释。
  private var imagesPushed = 0
  private var imagesRejected = 0
  private var accPushed = 0
  private var gyroPushed = 0
  /// 喂进去的加速度分量累加。用于在诊断里看**方向** ——
  /// 符号错靠模长查不出来(模长对符号不变),只有方向能暴露。
  /// 最后一次成功喂入的图像 / IMU 时间戳(同一时钟域,已实测)。
  ///
  /// 用来算「相机停了多久」。这个量以前是混在核内的
  /// `domain_mismatch_active` 里的:相机一停,IMU 继续推,
  /// `|t_cam - t_imu|` 就无限增长,于是「相机停了」被报成「时钟域错配」。
  /// 2026-08-24 真机踩过,把排查方向带偏了。两者必须分开。
  private var lastImageT: Double = 0
  private var lastImuT: Double = 0

  private var accSumX: Double = 0
  private var accSumY: Double = 0
  private var accSumZ: Double = 0
  private var runCalls = 0
  private var lastPushRc: Int32 = 0
  private var lastRunSpanMs: Double = 0

  // ── VIO 跟得上吗(抄 ARCore 的**检测**模式,不是优化模式)──
  //
  // ARCore 自己在 CPU 饥饿时会打 "VIO frequency low"
  // (官方文档教你 `adb logcat | grep 'VIO frequency low'`)——
  // 它**检测并上报**,而不是盲目降频。我们复刻这个。
  //
  // ⚠️ 为什么不复刻它的"优化"部分:Google 的公开指导全是"少占用我们的 SDK"
  //    (关 Instant Placement / Augmented Images),对自研核不适用。
  //    而我们自己试的固定降频已被 EuRoC 实测推翻(难序列 ATE +52%)。
  //    所以这里只做**可见性**,不做自动干预 —— 没有证据之前不该自动改行为。
  private var feedWallStart: CFAbsoluteTime = 0
  private var solveWallSum: Double = 0
  /// 求解占用的墙钟比例。>1 表示求解比数据来得还慢 ⇒ 一定在积压。
  private var dutyCycle: Double = 0
  /// 连续多少次 last_frame_ms 超过帧间隔。ARCore 那条 "VIO frequency low"
  /// 的等价物 —— 单次超时是抖动,连续超时才是跟不上。
  private var behindStreak = 0
  private var behindMax = 0
  private var lastFrameTimestamp: Double = 0
  private var frameIntervalEma: Double = 0

  // MARK: - 生命周期

  /// 用 Dart 侧生成的两份 YAML 创建。配置生成留在 Dart —— 那里有 provenance
  /// 追踪(哪些字段是设备读来的、哪些是占位),原生侧不该再复制一份配置逻辑。
  @discardableResult
  public func start(slamYaml: String, deviceYaml: String,
                    runHz: Double = 0.0) -> Int32 {   // 0 = 不降频(默认)
    lock.lock(); defer { lock.unlock() }
    if created { return 1 }
    // runHz <= 0 ⇒ runPeriodSeconds = 0 ⇒ 每帧求解(默认)
    runPeriodSeconds = runHz > 0 ? 1.0 / runHz : 0.0
    var cfg: UnsafeMutableRawPointer? = nil
    // ⚠️ XRSLAMCreate 是上游遗留约定:**1=成功 / 0=失败**,与其余 API 相反。
    let rc = slamYaml.withCString { s in
      deviceYaml.withCString { d in
        "".withCString { lic in
          "pocketworld".withCString { prod in
            XRSLAMCreate(s, d, lic, prod, &cfg)
          }
        }
      }
    }
    created = (rc == 1)
    if created {
      imagesPushed = 0; imagesRejected = 0
      accPushed = 0; gyroPushed = 0; runCalls = 0
      lastRunSeconds = 0
    }
    return rc
  }

  public func stop() {
    lock.lock(); defer { lock.unlock() }
    guard created else { return }
    XRSLAMDestroy()
    created = false
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return created
  }

  // MARK: - 喂帧

  /// 喂一帧 ARKit 图像。**零拷贝**:直接指向 CVPixelBuffer 的亮度平面。
  ///
  /// ARKit 的 capturedImage 是 420YpCbCr8BiPlanar,**plane 0 就是 Y(亮度)平面**,
  /// 本身就是灰度图 —— 不需要任何色彩转换。这是 ARKit 路径相对 AVCapture 的一个便宜。
  public func feed(frame: ARFrame) {
    lock.lock()
    let live = created
    lock.unlock()
    guard live else { return }

    let pb = frame.capturedImage
    guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return }

    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }

    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)

    // 降采样。失败(尺寸不是倍数的整数倍)就**拒绝这一帧并计数**,
    // 不退回全分辨率 —— 那正是撑崩 App 的那条路。
    let srcPtr = base.assumingMemoryBound(to: UInt8.self)
    guard let (small, sw, sh) =
            downsampleBox(src: srcPtr, srcW: w, srcH: h, srcStride: stride) else {
      lock.lock(); imagesRejected += 1; lock.unlock()
      return
    }

    var img = XRSLAMImage()
    img.data = small
    img.timeStamp = frame.timestamp        // 与 CoreMotion 同域(实测)
    img.stride = Int32(sw)          // 降采样后紧密打包
    img.camera_id = 0
    img.channel = 1                        // 灰度
    // ⚠️ width/height 是我们给上游补的字段。原版只有 stride,分辨率取自 yaml,
    //    调用方喂的图比 yaml 矮就是静默越界读(ASAN 实测越界 76800 字节)。
    img.width = Int32(sw)
    img.height = Int32(sh)
    img.ext = nil

    let rc = XRSLAMPushSensorDataChecked(XRSLAM_SENSOR_CAMERA, &img)
    lock.lock()
    lastPushRc = rc
    if rc == XRSLAM_OK {
      imagesPushed += 1
      if img.timeStamp > lastImageT { lastImageT = img.timeStamp }
    } else {
      imagesRejected += 1
    }
    // [pw] 2026-08-23 撤销降频,默认每帧求解。
    //   原来这里按 ~10Hz 降频,依据是 ARCore 工程师那句"我们的 VIO 只跑约 10Hz"。
    //   **EuRoC 实测把它推翻了**:降频只在最简单的序列上受益,中等/困难序列
    //   全部变差,而且越难越差 ——
    //     V1_01 easy      ATE 0.0645 → 0.0456 (改善)
    //     V1_02 medium    ATE 0.0563 → 0.0724 (+25%)
    //     V1_03 difficult ATE 0.0919 → 0.1520 (+52%,n=3)
    //   尺度误差同向恶化(V1_03 0.465% → 0.830%)。
    //   手持拍摄的运动比无人机平飞乱得多,更接近"难"那一档 ⇒ 按无损铁律出局。
    //   runHz 旋钮保留但默认不生效,便于将来在**自己的数据**上重新评估。
    let now = frame.timestamp
    let due = runPeriodSeconds <= 0
        || (lastRunSeconds == 0) || (now - lastRunSeconds >= runPeriodSeconds)
    if rc == XRSLAM_OK && due {
      lastRunSeconds = now
      runCalls += 1
      lock.unlock()
      let t0 = CFAbsoluteTimeGetCurrent()
      XRSLAMRunOneFrame()
      let span = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
      lock.lock()
      lastRunSpanMs = span
      solveWallSum += span / 1000.0
      if feedWallStart == 0 { feedWallStart = t0 }
      let elapsed = CFAbsoluteTimeGetCurrent() - feedWallStart
      dutyCycle = elapsed > 0 ? solveWallSum / elapsed : 0

      // 帧间隔用指数滑动平均(相机帧率会随光照变,不能写死 1/30)
      if lastFrameTimestamp > 0 {
        let dt = now - lastFrameTimestamp
        if dt > 0 && dt < 1.0 {
          frameIntervalEma = frameIntervalEma == 0 ? dt
                                                   : (frameIntervalEma * 0.9 + dt * 0.1)
        }
      }
      lastFrameTimestamp = now

      // ⚠️ 判据用**核内自报**的 last_frame_ms,不用我们量的 span ——
      //    THREADING=ON 时 RunOneFrame 只是入队,span 会一直接近 0,
      //    拿它当判据会永远显示"跟得上"。这正是今天在 Mac 上踩过的坑。
      var h = XRSLAMHealth()
      if XRSLAMGetHealth(&h) == XRSLAM_OK && frameIntervalEma > 0 {
        let budgetMs = frameIntervalEma * 1000.0
        if h.last_frame_ms > budgetMs {
          behindStreak += 1
          if behindStreak > behindMax { behindMax = behindStreak }
          if behindStreak == 5 {
            // 只在跨过阈值时打一次,不刷屏。
            NSLog("[pw][vio] VIO 跟不上:核内单帧 %.1f ms > 帧预算 %.1f ms,"
                  + "已连续 5 帧。duty=%.2f", h.last_frame_ms, budgetMs, dutyCycle)
          }
        } else {
          behindStreak = 0
        }
      }
      lock.unlock()
    } else {
      lock.unlock()
    }
  }

  /// 喂一个 CoreMotion 样本(加速度 + 陀螺)。
  ///
  /// ⚠️ CMDeviceMotion 给的 userAcceleration 是**去重力**的,而 VIO 要的是
  ///    原始比力(含重力)。所以这里用 userAcceleration + gravity 还原,
  ///    单位从 G 转成 m/s²。搞错这一步 VIO 会以为自己一直在自由落体。
  public func feed(motion m: CMDeviceMotion) {
    lock.lock()
    let live = created
    lock.unlock()
    guard live else { return }

    // 🔴 **符号是负的**。这不是笔误,是逐字复刻上游:
    //   xrslam-ios/visualizer/src/Motion.swift:3
    //       fileprivate let GRAVITY_NOMINAL = -9.80665
    //   同文件 :57
    //       accelerationX: GRAVITY_NOMINAL * record.acceleration.x, ...
    //
    // 为什么:iOS 的加速度约定与 VIO(EuRoC)约定相反。
    //   • iOS:手机屏幕朝上平放时 gravity = (0, 0, -1) —— 指向"下"。
    //   • EuRoC:静止时加速度计读的是**指向"上"**的比力。
    //     实测 V1_01_easy 前 200 个静止样本:|a| = 9.778,方向单位向量
    //     (0.926, 0.012, -0.377) 正是传感器系里的"上"。
    //
    // 我原先写的是 +9.80665。后果是重力方向整个反了 ⇒ 视觉-惯性对齐永远
    // 收敛不了。真机症状:前端完全健康(检出 118 / 跟踪 112 / 内点 118 /
    // 零拒绝零落后),喂了 1473 帧 + 3610 个 IMU 样本,**slamState 恒 0、
    // 一个位姿都不出**。跟外参填 identity 那次的症状**一模一样** ——
    // 两者都是"朝向错了"这一类。
    //
    // ⚠️ 已知的、尚未消除的偏离:上游用**裸** startAccelerometerUpdates
    //    (CMAccelerometerData,G 为单位),我们用 CMDeviceMotion 的
    //    gravity + userAcceleration。Apple 文档说两者相等,但 deviceMotion
    //    是**融合滤波的输出**,有滞后。若改完符号仍不初始化,下一步就是换裸
    //    传感器 —— 见 progecttwo/XRSLAM_UPSTREAM_DEFECTS_2026-08-24.md。
    //    现在不一起改,是为了保持单变量。
    let g = -9.80665
    var acc = XRSLAMAcceleration()
    acc.timestamp = m.timestamp
    acc.data.0 = (m.userAcceleration.x + m.gravity.x) * g
    acc.data.1 = (m.userAcceleration.y + m.gravity.y) * g
    acc.data.2 = (m.userAcceleration.z + m.gravity.z) * g
    // 把喂进去的加速度均值报出来 —— 符号错这类 bug 靠模长查不出来(模长
    // 对符号不变),必须看**方向**。手机竖直手持看取景框时 device +Y 朝上,
    // gravity≈(0,-1,0) ⇒ 喂进去的应该是 (0, +9.81, 0)。
    accSumX += acc.data.0
    accSumY += acc.data.1
    accSumZ += acc.data.2
    _ = XRSLAMPushSensorDataChecked(XRSLAM_SENSOR_ACCELERATION, &acc)

    var gyro = XRSLAMGyroscope()
    gyro.timestamp = m.timestamp
    gyro.data.0 = m.rotationRate.x
    gyro.data.1 = m.rotationRate.y
    gyro.data.2 = m.rotationRate.z
    _ = XRSLAMPushSensorDataChecked(XRSLAM_SENSOR_GYROSCOPE, &gyro)

    lock.lock()
    accPushed += 1; gyroPushed += 1
    if m.timestamp > lastImuT { lastImuT = m.timestamp }
    lock.unlock()
  }

  // MARK: - 读出

  /// 喂进去的加速度均值。静止竖持时应 ≈ (0, +9.81, 0)。
  ///
  /// ⚠️ **模长不能用来判符号** —— 模长对符号不变。必须看分量方向。
  private var accMean: (x: Double, y: Double, z: Double, norm: Double) {
    guard accPushed > 0 else { return (0, 0, 0, 0) }
    let n = Double(accPushed)
    let mx: Double = accSumX / n
    let my: Double = accSumY / n
    let mz: Double = accSumZ / n
    let sq: Double = mx * mx + my * my + mz * mz
    return (mx, my, mz, sq.squareRoot())
  }

  /// 喂帧统计 + 最新位姿 + 健康状态。全部是事实。
  public func snapshot() -> [String: Any] {
    lock.lock()
    var out: [String: Any] = [
      "running": created,
      "imagesPushed": imagesPushed,
      "imagesRejected": imagesRejected,
      "accPushed": accPushed,
      "gyroPushed": gyroPushed,
      "runCalls": runCalls,
      "lastPushRc": Int(lastPushRc),
      "lastRunSpanMs": lastRunSpanMs,
      "runHz": runPeriodSeconds > 0 ? 1.0 / runPeriodSeconds : 0,
      // 🔑 把降采样倍数报出来,让 Dart 侧交叉校验内参缩放用的是同一个数。
      //   两边各写一个常量 = 改了一边忘另一边 ⇒ 内参与实际喂进去的图不匹配,
      //   整条位姿链系统性错**而且不报错**。这类静默失效必须结构性排除。
      // 静止竖持时应≈(0, +9.81, 0)。若 y 是负的,符号又反了。
      // 🔑 相机停了多久(秒)。这条以前被混进核内的 domain_mismatch_active,
      //   导致「相机停了」被报成「时钟域错配」——2026-08-24 真机把排查带偏过。
      //   -1 = 两路还没都到齐,不可用。
      "camStallSeconds": (lastImageT > 0 && lastImuT > 0)
        ? Swift.max(0.0, lastImuT - lastImageT) : -1.0,
      "accMeanX": accMean.x,
      "accMeanY": accMean.y,
      "accMeanZ": accMean.z,
      "accMeanNorm": accMean.norm,
      "vioDownsampleFactor": Self.kVioDownsampleFactor,
      "vioWidth": vioWidth, "vioHeight": vioHeight,
      // ── 跟得上吗 ──
      "dutyCycle": dutyCycle,          // 求解占墙钟比例,>1 必然积压
      "behindStreak": behindStreak,    // 当前连续超时帧数
      "behindMax": behindMax,          // 历史最长连续超时
      "frameIntervalMs": frameIntervalEma * 1000.0,
    ]
    let live = created
    lock.unlock()
    guard live else { return out }

    var pose7 = [Double](repeating: 0, count: 7)
    var ts: Double = 0
    let prc = pose7.withUnsafeMutableBufferPointer { p in
      XRSLAMTryGetLatestPose(p.baseAddress, &ts)
    }
    out["poseRc"] = Int(prc)
    if prc == XRSLAM_OK {
      out["pose"] = pose7
      out["poseTimestamp"] = ts
    }

    var health = XRSLAMHealth()
    let hrc = XRSLAMGetHealth(&health)
    out["healthRc"] = Int(hrc)
    if hrc == XRSLAM_OK {
      // 字段名逐个对过 C 头,不是猜的。
      out["healthOverall"] = Int(health.overall)
      out["slamState"] = Int(health.slam_state)
      out["lastFrameMs"] = health.last_frame_ms
      // 🔑 这几个是今天专门加的诊断量 —— 静默失效全靠它们暴露
      out["domainMismatchActive"] = Int(health.domain_mismatch_active)
      out["inspectionCompiledOut"] = Int(health.inspection_compiled_out)
      out["threadingEnabled"] = Int(health.threading_enabled)
      out["imuSamplesLastFrame"] = Int(health.imu_samples_last_frame)
      out["coreImuSamplesIntegrated"] = Int(health.core_imu_samples_integrated)
      out["latestPoseDegenerate"] = Int(health.latest_pose_degenerate)
      // 视觉侧
      out["detectedKeypoints"] = Int(health.detected_keypoints)
      out["trackedKeypoints"] = Int(health.tracked_keypoints)
      out["inlierKeypoints"] = Int(health.inlier_keypoints)
      out["mappedLandmarks"] = Int(health.mapped_landmarks)
      // landmark 过滤账 —— 被丢掉的必须可见,静默丢就又是一个静默失效
      out["landmarksPublished"] = Int(health.landmarks_published)
      out["landmarksUsable"] = Int(health.landmarks_usable)
      out["landmarksRejectedNonFinite"] = Int(health.landmarks_rejected_non_finite)
      out["landmarksRejectedUntriangulated"] = Int(health.landmarks_rejected_untriangulated)
      // 时基
      out["lastCamImuDelta"] = health.last_cam_imu_delta
      out["maxAbsCamImuDelta"] = health.max_abs_cam_imu_delta
      out["baselineCamImuDelta"] = health.baseline_cam_imu_delta
    }

    return out
  }
}
