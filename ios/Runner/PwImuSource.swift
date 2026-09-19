// ⛔️ [2026-09-20] **这个文件不是引擎喂料通路,不要再把它接成喂料通路。**
//    引擎喂料在 `ios/Runner/PwXrslamLive.swift`:CoreMotion 回调里当场调
//    `PWXrslamTransportPush{Gyroscope,Acceleration}Raw`,与上游
//    `Motion.swift` → `XRSLAMer.swift` → `XRSLAM_iOS.mm` 同位。
//    本文件是"轮询取最新一条"的**诊断**接口。我曾经拿它当喂料通路 ——
//    两个各约 100 Hz 的时钟互相采样会拍频(重复推 / 漏推),而且它把陀螺与
//    加速度配成一对共用陀螺时间戳(实测 skew 4.987 ms)⇒ 真机位姿 45 秒
//    发散到 1.6 km。
//
// PwImuSource.swift —— 原生 IMU 源:CMMotionManager + 与相机同域的时间戳。
//
// ══ 🔴 抄源(逐项标注,不是我设计的)═══════════════════════════════════════
// basalt-vio-phone-bench-20260829/.../SensorTransport/LiveSensorTransport.swift
//   · 锚点双采样取中点        :convenience init(configuration:…) :182-190
//   · gyro/accel 更新间隔设定 :startMotionUpdates :572-580
//   · 时间戳映射              :handleGyroscope :634-636
//     `clockMapper.motionNanoseconds(uptimeSeconds: data.timestamp)`
// 映射器本体 [PwMonotonicClock.swift] 是逐字节拷贝(sha 1105f9a5d7d30e21)。
//
// ══ 它补的是什么 ═══════════════════════════════════════════════════════════
// 2026-09-19 之前:IMU 时间戳来自 **Dart 的 Stopwatch**,相机帧时间戳来自
// **CMSampleBuffer 的主机时钟** —— **两个不同的时间域**。VIO 预积分对 dt 极
// 敏感,跨域时间戳等于持续给引擎喂错的时间差。
// 本文件把两者统一到台架那条"唯一生产时钟映射"上:
//   规范域 = **Core Media host clock 的纳秒**。
//
// ══ 🔴 不做的事 ════════════════════════════════════════════════════════════
// · **不做陀螺/加速度配对**。台架有 `GyroDrivenIMUAssembler`(以陀螺为主时钟
//   配对加速度),那是 Basalt 那条臂的口径;XRSLAM 的上游 demo
//   (`XRSLAM_iOS.mm:190-210`)是**两者分别推**、各带自己的时间戳。
//   我们喂的是 XRSLAM ⇒ 照上游,分开推。
// · **不改写时间戳去掩盖回退**。回退如实计数(见 `regressions`),
//   与台架 `TimestampSequenceValidator` 同口径。

import CoreMotion
import CoreMedia
import Foundation

private final class PwImuSourceImpl {
    static let shared = PwImuSourceImpl()

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()

    private var mapper: MonotonicClockMapper?
    private var started = false

    // 最新一条样本(供 Dart 轮询取)。分开存 —— 上游就是分开推的。
    private var gyro: (t: UInt64, x: Double, y: Double, z: Double)?
    private var accel: (t: UInt64, x: Double, y: Double, z: Double)?

    private var gyroValidator = TimestampSequenceValidator()
    private var accelValidator = TimestampSequenceValidator()
    private var motionErrors: UInt64 = 0
    private var gyroCount: UInt64 = 0
    private var accelCount: UInt64 = 0

    /// 返回 0 成功;-1 陀螺不可用;-2 加速度计不可用;-3 host 时钟异常。
    func start(rateHz: Double) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if started { return 0 }
        guard motionManager.isGyroAvailable else { return -1 }
        guard motionManager.isAccelerometerAvailable else { return -2 }

        // 🔴 抄 LiveSensorTransport:host 时钟**前后各采一次取中点**,
        //    把采样本身的抖动摊掉;同一时刻取 systemUptime 作为 CoreMotion 锚点。
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

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        started = false
    }

    private func onGyro(_ data: CMGyroData?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if error != nil { motionErrors += 1; return }
        guard let data, let m = mapper,
              let t = try? m.motionNanoseconds(uptimeSeconds: data.timestamp)
        else { motionErrors += 1; return }
        gyroValidator.observe(t)
        gyro = (t, data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        gyroCount += 1
    }

    private func onAccel(_ data: CMAccelerometerData?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if error != nil { motionErrors += 1; return }
        guard let data, let m = mapper,
              let t = try? m.motionNanoseconds(uptimeSeconds: data.timestamp)
        else { motionErrors += 1; return }
        accelValidator.observe(t)
        // 🔴 **常数是负的**,而且出处是 XRSLAM 上游自己的文件:
        //    `xrslam-ios/visualizer/src/Motion.swift:3,57` @4beb1a9 —— 
        //    `GRAVITY_NOMINAL = -9.80665`;陀螺 x/y/z **原样透传不换算**。
        //    (台架 `SensorTransportModels.swift:387-389` 把这条出处钉死了。)
        //    ⚠️ 我第一版写成 +9.80665,那会让重力方向整个反过来 —— 
        //    符号不是细节,是判死初始化能不能成的东西。
        let g = -9.80665
        accel = (t,
                 data.acceleration.x * g,
                 data.acceleration.y * g,
                 data.acceleration.z * g)
        accelCount += 1
    }

    /// 写 8 个 double:gyroT(秒) gx gy gz accelT(秒) ax ay az。
    /// 返回 0 = 两者都有;-1 = 还没起;-2 = 还没收到样本。
    func latest(into out: UnsafeMutablePointer<Double>) -> Int32 {
        for i in 0..<8 { out[i] = 0 }
        lock.lock(); defer { lock.unlock() }
        guard started else { return -1 }
        guard let g = gyro, let a = accel else { return -2 }
        let ns = 1_000_000_000.0
        out[0] = Double(g.t) / ns; out[1] = g.x; out[2] = g.y; out[3] = g.z
        out[4] = Double(a.t) / ns; out[5] = a.x; out[6] = a.y; out[7] = a.z
        return 0
    }

    /// 写 5 个 int64:gyroCount accelCount motionErrors gyroRegressions accelRegressions。
    func stats(into out: UnsafeMutablePointer<Int64>) {
        lock.lock(); defer { lock.unlock() }
        out[0] = Int64(gyroCount)
        out[1] = Int64(accelCount)
        out[2] = Int64(motionErrors)
        out[3] = Int64(gyroValidator.regressionCount)
        out[4] = Int64(accelValidator.regressionCount)
    }
}

// ── C ABI:与 PwCameraSlot 同样的 @_cdecl 风格 ────────────────────────────

/// 起 IMU。`rateHz` 建议 100(与我们此前 Dart 侧 sensors_plus 的 10 ms 一致)。
@_cdecl("pw_imu_start")
public func pw_imu_start(_ rateHz: Double) -> Int32 {
    return PwImuSourceImpl.shared.start(rateHz: rateHz > 0 ? rateHz : 100)
}

@_cdecl("pw_imu_stop")
public func pw_imu_stop() {
    PwImuSourceImpl.shared.stop()
}

/// 写 8 个 double:gyroT gx gy gz accelT ax ay az(时间戳=秒,与相机同域)。
@_cdecl("pw_imu_latest")
public func pw_imu_latest(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    return PwImuSourceImpl.shared.latest(into: out)
}

/// 写 5 个 int64:gyro/accel 计数、错误数、两路时间戳回退数。
@_cdecl("pw_imu_stats")
public func pw_imu_stats(_ out: UnsafeMutablePointer<Int64>) {
    PwImuSourceImpl.shared.stats(into: out)
}
