// PwImuCalibCapture.swift —— 六位置法 IMU 内参标定的**采集端**。
//
// ══ 🔴 这个文件只做一件事:把原始 IMU 落盘。不做任何估计、不做任何滤波。═══════
//
// ══ 为什么需要它(别再问"直接用现有录制不行吗")═════════════════════════════
// 现有录制走 `OfficialAetherARKitPlugin.startSession`,IMU 是**搭着相机一起录**的:
// 28.3 秒写了 **4.7 GB**(`run-6e2d4b99/recording_manifest.json` frames.bin)。
// 六位置法要六段静止,按那条路径要写约 60 GB —— 盘上没有。
// 而且标定**根本不需要图像**。⇒ 必须有一条纯 IMU 通路。
//
// ══ 🔴 逐项抄源(不是我设计的)═════════════════════════════════════════════
// 全部抄自同目录的 `PwImuSource.swift`(它自己的抄源标注见那个文件头):
//   · host 时钟前后各采一次取中点 + systemUptime 锚点 :PwImuSource.swift start() :77-91
//   · queue.maxConcurrentOperationCount = 1 / .userInitiated / 更新间隔 :同上 :93-97
//   · 陀螺与加速度**分别** startXxxUpdates            :同上 :98-103
//   · 时间戳映射 `m.motionNanoseconds(uptimeSeconds:)` :同上 :117 / :123
//   · 🔴 加速度常数 **-9.80665**(负号!)            :同上 :126-135
//     出处是 XRSLAM 上游自己的文件 `xrslam-ios/visualizer/src/Motion.swift:3,57`
//     @4beb1a9 —— `GRAVITY_NOMINAL = -9.80665`;陀螺 x/y/z **原样透传不换算**。
//     CoreMotion 的 `acceleration` 单位是 **g**,乘 -9.80665 后得到"静止时比力朝上、
//     模长 +g"的标准约定 —— 与 ROS `sensor_msgs/Imu` 同约定,iKalibr 可直接吃。
//
// ══ 🔴 与 PwImuSource 的唯一差别,以及为什么 ════════════════════════════════
// PwImuSource 是**轮询式诊断接口**("只存最新一条",供 Dart 取)。它的文件头写明:
// 两个各约 100 Hz 的时钟互相采样会**拍频**(重复推 / 漏推)⇒ 采集绝不能轮询。
// 本文件在**回调里直接 append**,一条不丢。
//
// ══ 🔴 不做配对 ═══════════════════════════════════════════════════════════
// PwImuSource 明确规定"**不做陀螺/加速度配对**"(上游 XRSLAM 是分开推的,
// 实测两路 skew 4.987 ms)。本文件守同一条规矩:**写两个文件,各带自己的时间戳**。
// iKalibr 吃的 `sensor_msgs/Imu` 要求两者同条消息 ⇒ 配对放到**主机侧转换**时做,
// 在那里可见、可审、可以把 skew 数字打出来。
// 另:六位置法**全部是静止段**,静止数据上配对误差在物理上无影响。
//
// ══ 采集协议(不是我定的)═════════════════════════════════════════════════
// iKalibr `config/tool/config-imu-intri-calib.yaml` 里六个 bag 名逐字写着:
//   X_DOWN_STATIC / X_UP_STATIC / Y_DOWN_STATIC / Y_UP_STATIC / Z_DOWN_STATIC / Z_UP_STATIC
// 同文件注释原文:
//   "Multiple data pieces are required, they are collected stationary using different
//    placement patterns. For example, collect data using the same pattern as the
//    six-position calibration"
//   "for static intrinsic calibration, the scale and non-orthogonal factor (matrix) of
//    gyroscope are lacking observability (for low-cost MEMS IMUs, which almost can not
//    aware the earth rotation)"
// ⇒ 静态标定给出:加速度计**标度 + 非正交 + 零偏**,陀螺**零偏**。陀螺标度拿不到。

import CoreMotion
import CoreMedia
import Foundation

private final class PwImuCalibCaptureImpl {
    static let shared = PwImuCalibCaptureImpl()

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()

    private var mapper: MonotonicClockMapper?
    private var started = false
    private var label = ""

    // 回调里 append —— 不是"只存最新一条"。
    private var gyroRows: [(UInt64, Double, Double, Double)] = []
    private var accelRows: [(UInt64, Double, Double, Double)] = []

    private var gyroValidator = TimestampSequenceValidator()
    private var accelValidator = TimestampSequenceValidator()
    private var motionErrors: UInt64 = 0

    private static let accelScale = -9.80665   // 🔴 见文件头:出处 Motion.swift:3,57

    private var outDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/imu_calib", isDirectory: true)
    }

    /// 返回 0 成功;-1 陀螺不可用;-2 加速度计不可用;-3 host 时钟异常;-4 已在录。
    func start(label: String, rateHz: Double) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if started { return -4 }
        guard motionManager.isGyroAvailable else { return -1 }
        guard motionManager.isAccelerometerAvailable else { return -2 }

        // ── 抄 PwImuSource.swift:77-91(它抄 LiveSensorTransport 的锚点双采样取中点)──
        let hostBefore = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let uptime = ProcessInfo.processInfo.systemUptime
        let hostAfter = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let hostAnchor = (hostBefore + hostAfter) * 0.5
        let nanoseconds = hostAnchor * 1_000_000_000.0
        guard hostAnchor.isFinite, hostAnchor >= 0,
              nanoseconds.isFinite, nanoseconds >= 0,
              nanoseconds < Double(UInt64.max) else { return -3 }

        mapper = MonotonicClockMapper(
            cameraHostTimeAnchorSeconds: hostAnchor,
            coreMotionUptimeAnchorSeconds: uptime,
            monotonicAnchorNanoseconds: UInt64(
                nanoseconds.rounded(.toNearestOrAwayFromZero)
            )
        )

        self.label = label
        gyroRows.removeAll(keepingCapacity: true)
        accelRows.removeAll(keepingCapacity: true)
        // 60 s @ 100 Hz = 6000;预留 4 倍,避免录制中途扩容。
        gyroRows.reserveCapacity(24_000)
        accelRows.reserveCapacity(24_000)
        gyroValidator = TimestampSequenceValidator()
        accelValidator = TimestampSequenceValidator()
        motionErrors = 0

        // ── 抄 PwImuSource.swift:93-103 ──
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let interval = 1.0 / rateHz
        motionManager.gyroUpdateInterval = interval
        motionManager.accelerometerUpdateInterval = interval
        motionManager.startGyroUpdates(to: queue) { [weak self] data, error in
            self?.onGyro(data, error)
        }
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, error in
            self?.onAccel(data, error)
        }
        started = true
        return 0
    }

    private func onGyro(_ data: CMGyroData?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if error != nil { motionErrors += 1; return }
        guard let data, let m = mapper,
              let t = try? m.motionNanoseconds(uptimeSeconds: data.timestamp)
        else { motionErrors += 1; return }
        gyroValidator.observe(t)
        // 陀螺原样透传,不换算(PwImuSource.swift:128 同)。
        gyroRows.append((t, data.rotationRate.x, data.rotationRate.y, data.rotationRate.z))
    }

    private func onAccel(_ data: CMAccelerometerData?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if error != nil { motionErrors += 1; return }
        guard let data, let m = mapper,
              let t = try? m.motionNanoseconds(uptimeSeconds: data.timestamp)
        else { motionErrors += 1; return }
        accelValidator.observe(t)
        let g = PwImuCalibCaptureImpl.accelScale
        accelRows.append((t,
                          data.acceleration.x * g,
                          data.acceleration.y * g,
                          data.acceleration.z * g))
    }

    /// 停止并落盘。返回写出的样本数(gyro + accel);负数为错误码。
    /// -1 没在录;-5 建目录失败;-6 写文件失败。
    func stopAndWrite() -> Int64 {
        lock.lock()
        guard started else { lock.unlock(); return -1 }
        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        started = false
        let g = gyroRows, a = accelRows, lb = label
        let errs = motionErrors
        let gReg = gyroValidator.regressionCount, aReg = accelValidator.regressionCount
        lock.unlock()

        let dir = outDir.appendingPathComponent(lb, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch { return -5 }

        // 两个文件,各带自己的时间戳 —— 见文件头「不做配对」。
        var gs = "timestamp_ns,wx,wy,wz\n"
        gs.reserveCapacity(g.count * 64)
        for r in g { gs += "\(r.0),\(r.1),\(r.2),\(r.3)\n" }
        var accs = "timestamp_ns,ax,ay,az\n"
        accs.reserveCapacity(a.count * 64)
        for r in a { accs += "\(r.0),\(r.1),\(r.2),\(r.3)\n" }

        // 采集元数据:让主机侧不用猜任何约定。
        let meta = """
        {
          "schema": "pw_imu_calib_capture_v1",
          "label": "\(lb)",
          "gyro_count": \(g.count),
          "accel_count": \(a.count),
          "motion_errors": \(errs),
          "gyro_timestamp_regressions": \(gReg),
          "accel_timestamp_regressions": \(aReg),
          "timestamp_domain": "core_media_host_clock_nanoseconds",
          "gyro_units": "rad/s (CoreMotion rotationRate, passed through unchanged)",
          "accel_units": "m/s^2 (CoreMotion acceleration[g] * -9.80665)",
          "accel_scale_constant": -9.80665,
          "accel_scale_provenance": "xrslam-ios/visualizer/src/Motion.swift:3,57 @4beb1a9 GRAVITY_NOMINAL",
          "paired": false,
          "pairing_note": "gyro and accel are NOT paired on device; pair on host at conversion time",
          "protocol": "six-position static (iKalibr config/tool/config-imu-intri-calib.yaml)"
        }
        """
        do {
            try gs.write(to: dir.appendingPathComponent("gyro.csv"),
                         atomically: true, encoding: .utf8)
            try accs.write(to: dir.appendingPathComponent("accel.csv"),
                           atomically: true, encoding: .utf8)
            try meta.write(to: dir.appendingPathComponent("capture_meta.json"),
                           atomically: true, encoding: .utf8)
        } catch { return -6 }
        return Int64(g.count + a.count)
    }

    /// 写 5 个 int64:gyroCount accelCount motionErrors gyroRegressions accelRegressions。
    /// 录制中可随时调用,用于在 UI 上显示进度。
    func stats(into out: UnsafeMutablePointer<Int64>) {
        lock.lock(); defer { lock.unlock() }
        out[0] = Int64(gyroRows.count)
        out[1] = Int64(accelRows.count)
        out[2] = Int64(motionErrors)
        out[3] = Int64(gyroValidator.regressionCount)
        out[4] = Int64(accelValidator.regressionCount)
    }
}

// ── C ABI:与 PwImuSource / PwCameraSlot 同样的 @_cdecl 风格 ────────────────

/// 开始一段标定采集。`label` 用六位置法的方位名,逐字对齐 iKalibr 的六个 bag 名:
/// X_DOWN_STATIC / X_UP_STATIC / Y_DOWN_STATIC / Y_UP_STATIC / Z_DOWN_STATIC / Z_UP_STATIC。
/// `rateHz` 传 100(与现有 imu.csv 实测 100.3 Hz 同档)。
@_cdecl("pw_imu_calib_start")
public func pw_imu_calib_start(_ label: UnsafePointer<CChar>, _ rateHz: Double) -> Int32 {
    return PwImuCalibCaptureImpl.shared.start(
        label: String(cString: label), rateHz: rateHz > 0 ? rateHz : 100)
}

/// 停止并落盘到 Documents/imu_calib/<label>/{gyro.csv,accel.csv,capture_meta.json}。
/// 返回样本总数,负数为错误码。
@_cdecl("pw_imu_calib_stop")
public func pw_imu_calib_stop() -> Int64 {
    return PwImuCalibCaptureImpl.shared.stopAndWrite()
}

/// 写 5 个 int64:gyroCount accelCount motionErrors gyroRegressions accelRegressions。
@_cdecl("pw_imu_calib_stats")
public func pw_imu_calib_stats(_ out: UnsafeMutablePointer<Int64>) {
    PwImuCalibCaptureImpl.shared.stats(into: out)
}
