// PwXrslamLive.swift —— 把活体传感器喂给引擎的**原生**通路。
//
// ══ 🔴 这个文件存在的理由:上一版把这件事放在 Dart 里做,做错了 ═══════════
// 2026-09-20 真机实测:位姿 45 秒发散到 1.6 km。取证后定位到喂料侧三处偏离
// 上游(见下)。上游 iOS demo 的形状是:
//
//   Motion.swift:41-57        CoreMotion 回调里**当场**回调 delegate
//   XRSLAMer.swift:36-47      delegate 里**当场**调 trackGyroscope/trackAccelerometer
//   XRSLAM_iOS.mm:190-210     trackXxx 里**当场**调 XRSLAMPushSensorData
//   XRSLAM_iOS.mm:152-188     trackCamera 里 push → RunOneFrame → GetResult **一次做完**
//   Camera.swift:47           `queue ?? .main`  ┐ 两条流**共享同一个串行上下文**
//   Motion.swift:38           `q ?? .main`      ┘
//
// 我们偏离的三处:
//   ① 不是回调即推,而是在 Dart 里轮询 `NativeImu.latest()` ⇒ 同一样本推两遍 /
//      漏推。两个各约 100 Hz 的时钟互相采样必然拍频。
//   ② 把陀螺和加速度**配成一对**,且两条都盖上**陀螺的**时间戳。实测
//      `skew=4.987ms`(正好半个采样周期)⇒ 每条加速度系统性错 5 ms。
//      转动时 ω×5ms 的姿态误差让重力扣不干净,残差约 9.8×0.005≈0.05 m/s²,
//      二次积分几十秒就是几十米。
//   ③ 相机与 IMU 跑在互不相干的执行上下文里,到达顺序不再守序。
//
// ══ 🔴 不要再写第二套:传输层仓里早就有 ═══════════════════════════════════
// `vendor/xrslam/transport/PwXrslamTransportCore.{h,cpp}`(已在
// `Runner.xcodeproj` 的 Sources 里、已被 `Runner-Bridging-Header.h` import):
//   · PWXrslamTransportPushGyroscopeRaw / PushAccelerationRaw
//       —— **分开推、各带自己的时间戳**,与上游同形
//   · PWXrslamTransportPushCameraAndRunRaw
//       —— push → RunOneFrame → GetResult(**CAMERA_POSE**)一次原子调用,
//          与上游 trackCamera 同形
//   · PWXrslamTransportGetCounters —— 计数从 C++ 账本读,头文件原话
//     "Swift must not synthesize them"。
// 生产侧 `PwVioTimebase.swift:747-773` 用的就是它,注释原文:
//     "Match upstream xrslam-ios transport order: raw gyro first, then raw acc."
//
// ══ 🔴 [2026-09-20 第二轮] 上游的"回调里同步跑完"在全分辨率上不成立 ═══════
// 上游 demo 是 **640×480 @30fps**,`trackCamera` 在相机回调里 push→run→读结果
// 一气跑完,没问题。我们喂 **1920×1440**,实测整帧约 51.7 ms(前端 20.22 +
// 其余 31.45)⇒ 回调被算法占住 ⇒ `alwaysDiscardsLateVideoFrames` 把后面的帧
// 全丢掉。传输层账本实测:相机从 24 fps 一路塌到 **12 fps**
// (cam=449 vs acc=3778,acc 恒 100 Hz 就是秒表)。
// 12 fps 手持 ⇒ 帧间位移过大 ⇒ 特征跟不住 ⇒ 视觉不再约束平移 ⇒ 平移只剩 IMU
// 二次积分 ⇒ 位姿无界发散。
//
// 生产侧早就解决过这件事,做法写在 `PwVioSlamFeeder.swift:9` 的文件头里:
//     "回调只尝试**有界入队**,**绝不等算法**;压力不能反向控制拍照。
//      任何溢出都显式计数并使整场影子运行失效,不伪造完整输入。"
// 本文件照这条改:相机/陀螺/加速度三个回调都只做**有界入队**,一条串行
// worker 按到达顺序消费。相机因此永远不被算法堵住;引擎吃不下的帧在**我们
// 自己的闸上被计数丢弃**,而不是被 AVFoundation 静默吞掉。
//
// ══ 与上游的**三处显式偏离**(都有依据,都写在这里)═════════════════════
// (a) 串行上下文用的是相机那条队列,不是 `.main`。上游是个 SceneKit demo,
//     占用 UI 线程无所谓;我们是 Flutter,占 UI 线程会拖垮渲染。
//     **被复刻的性质是"两条流共享同一个串行上下文"**,用
//     `OperationQueue.underlyingQueue` 绑到相机队列上即可满足,换的只是哪条队列。
//     三条流都在这条队列上**入队**,所以入队顺序 = 物理到达顺序。
// (b) 像素格式推 BGRA(channel=4)而不是先转灰度。依据:引擎自己就支持,
//     `XRSLAMManager.cpp:499,541` —— channel==4 ⇒ CV_8UC4 ⇒
//     `cv::cvtColor(img, ..., cv::COLOR_BGRA2GRAY)`,**与上游 trackCamera
//     里那次 cvtColor 是同一个函数、同一个常量**。少一次拷贝,零口径差。
// (c) 算法不在回调里跑,搬到 worker(见上)。依据是生产 `PwVioSlamFeeder`,
//     不是我的设计。
//
// ⚠️ **本文件不解决"引擎在 1920×1440 上跑不到 60fps"** —— 它只保证相机不被
//    堵住、丢帧被如实计数归因。真正吃不下的帧数会出现在 `framesDropped` 上。
//    另有一笔独立的账没算:XRSLAM 的像素单位阈值(min_keypoint_distance 25px /
//    min_parallax 10px / parsac.threshold 1.0px / rpe 3.0px)全是在 640×480
//    上调的,在 1920×1440 上焦距大 3 倍,同样的像素数对应 1/3 的角度。
//    **上游没有 1920×1440 的配置档可抄**,所以这几个值我一个都没动。

import AVFoundation
import CoreMedia
import CoreMotion
import Foundation

final class PwXrslamLive {
    static let shared = PwXrslamLive()

    private let lock = NSLock()
    private let motionManager = CMMotionManager()
    private var motionQueue: OperationQueue?

    /// 相机那条串行队列。由 `PwCameraSlot` 在 `start()` 里登记进来 ——
    /// **依赖方向故意是反的**:这样 `PwCameraSlotImpl` 可以保持 file-private,
    /// 而"IMU 必须与相机共用同一个串行上下文"这条不变量由 `begin()` 强制
    /// (没登记就返回 -4,不会静默退化成两条独立队列)。
    private var serialQueue: DispatchQueue?

    private var created = false
    /// 上游 `XRSLAMer.stopFlag` 的等价物:false 之前一律不推。
    private var running = false

    private var haveResult = false
    private var lastState: Int32 = 0
    private var lastPose = PWXrslamRawPose()
    private var cameraCallbacks: UInt64 = 0
    private var cameraLockFailures: UInt64 = 0

    // ── 有界入队 + 串行 worker(抄生产 PwVioSlamFeeder)────────────────────
    /// 算法只在这条队列上跑。回调**绝不**在这里等。
    private let workQueue = DispatchQueue(
        label: "com.pocketworld.xrslam.live.work", qos: .userInitiated)

    /// 相机在途帧数上限。取 2:一帧在算、一帧在等。
    /// 🔴 不能大 —— 每一帧都 retain 着一个 AVFoundation 池里的
    ///    `CVPixelBuffer`(1920×1440 BGRA ≈ 11 MB)。押太多帧,采集端会
    ///    `out_of_buffers`,那是把丢帧从我们的闸上推回给系统,归因就没了。
    private static let maxPendingFrames = 2
    /// IMU 在途上限。100 Hz × 4 s —— 只在 worker 被长时间占住时才会命中。
    private static let maxPendingImu = 400

    // ── 🔴 相机 PTS 与 IMU 时间戳的**域差**(唯一没量过的量)────────────
    // 上游把 `pts.seconds`(Core Media host clock)和 `record.timestamp`
    // (CoreMotion,开机以来秒数)**原样透传、不做任何映射**。依据是苹果自己
    // 的 `AVCaptureSession.h:630`:
    //   "Use synchronizationClock to synchronize AVCaptureOutput data with
    //    external data sources (e.g motion samples). All capture output sample
    //    buffer timestamps are on the synchronizationClock timebase."
    // 纯视频会话的同步时钟就是 host clock,而 `CMLogItem.timestamp` 与
    // `ProcessInfo.systemUptime` 同基 —— 两者本该同域。
    //
    // ⚠️ **但这只是文档论证,我没在机器上量过。** 传输层的单调闸只检查
    //    **每条流自己**递增,**捕不到两条流之间的常值偏移**。而视觉-惯性
    //    关联对这个偏移极其敏感:偏一点点,预积分就把错的那段惯性配给了
    //    错的那两帧图像 —— 症状恰恰是平滑的无界漂移。
    // 判读:同域时 `delta` ≈ 相机管线延迟(几十 ms 量级,可能为负,因为
    //       PTS 可能是曝光起点);跨域时会是**开机时长**那个量级。
    private var lastCameraPts: Double = 0
    private var lastImuTs: Double = 0
    private var lastDelta: Double = 0
    private var maxAbsDelta: Double = 0
    private var haveDelta = false

    private var pendingFrames = 0
    private var pendingImu = 0
    private var framesOffered: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var imuDropped: UInt64 = 0
    private var maxObservedPendingFrames = 0

    // MARK: 生命周期

    /// 由 `PwCameraSlot.start()` 调用,登记相机的串行队列。
    func bindSerialQueue(_ q: DispatchQueue) {
        lock.lock(); serialQueue = q; lock.unlock()
    }

    /// 返回沿用冻结的 `XRSLAMCreate` 口径:**1 成功 / 0 失败**。
    func create(slamConfigPath: String, deviceConfigPath: String) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if created { return 1 }

        // 🔴 GPU 前端的运行期开关。只有链了 `gpufenothread` 那条臂时才有东西读它
        //    (`gpu_image.cpp:28`);链 generic 时这个变量没有任何读者,置位无害。
        //
        // ⚠️ **时序是承重的**。`gpu_image.cpp` 的注释(2026-09-09)记着一次教训:
        //    "A namespace-scope initialiser runs when the library loads, which is
        //     BEFORE the app's setenv, so an env-driven arm silently ran the default
        //     path and its measurement looked like a null result."
        //    该文件后来改成**惰性读**,而读它的 `init_once()` 是在
        //    `XRSLAMManager.cpp:133` 的 `GpuImage::create_image()` 里跑,即
        //    `XRSLAMCreate` 期间 —— 所以在这里 setenv 来得及。别往后挪。
        //
        // 🔴 失败会**静默回落 CPU**,所以必须能看见:
        //    · stderr:"[xrslam-gpufe] front end unavailable: … (falling back to CPU)"
        //    · 文件:$HOME/Documents/xrslam_gpufe_init.log(init 各阶段的痕迹)
        //    没有这两条就把"没提速"当成"GPU 前端没用",是又一次误判。
        setenv("PW_XRSLAM_GPU_FRONTEND", "1", 1)

        let rc = PWXrslamTransportCreate(slamConfigPath, deviceConfigPath)
        if rc == 1 { created = true }
        return rc
    }

    /// GPU 前端初始化痕迹。读 `gpu_image.cpp` 写的那个文件,**原样返回**,
    /// 不解释、不判定 —— 判定是上层的事。空串 = 文件不存在(= 没链 GPU 前端那条臂,
    /// 或者根本没走到 init)。
    func gpuFrontEndTrail() -> String {
        let home = NSHomeDirectory()
        let path = home + "/Documents/xrslam_gpufe_init.log"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// 起 CoreMotion 并允许推送。0 成功;-1 陀螺不可用;-2 加速度计不可用;
    /// -3 还没 create;**-4 相机还没起**(串行队列没登记)。
    ///
    /// 🔴 `rateHz` 抄上游 `Motion.init(updateInterval: 0.01)` = **100 Hz**。
    func begin(rateHz: Double) -> Int32 {
        lock.lock()
        guard created else { lock.unlock(); return -3 }
        if running { lock.unlock(); return 0 }
        guard motionManager.isGyroAvailable else { lock.unlock(); return -1 }
        guard motionManager.isAccelerometerAvailable else { lock.unlock(); return -2 }
        guard let camQueue = serialQueue else { lock.unlock(); return -4 }
        running = true
        lock.unlock()

        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        // 见文件头偏离 (a):绑到相机那条串行队列上,等价于上游的"共用 .main"。
        q.underlyingQueue = camQueue
        motionQueue = q

        let interval = 1.0 / (rateHz > 0 ? rateHz : 100.0)
        motionManager.gyroUpdateInterval = interval
        motionManager.accelerometerUpdateInterval = interval

        // 🔴 顺序照抄上游:**先陀螺,后加速度**
        //    (`PwVioTimebase.swift:747` 的注释把这条钉死过)。
        motionManager.startGyroUpdates(to: q) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            self.onGyro(data)
        }
        motionManager.startAccelerometerUpdates(to: q) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            self.onAccel(data)
        }
        return 0
    }

    func destroy() {
        lock.lock()
        let wasCreated = created
        running = false
        created = false
        haveResult = false
        lock.unlock()
        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        motionQueue = nil
        if wasCreated { PWXrslamTransportDestroy() }
    }

    // MARK: 三条喂料 —— 回调里当场推,不缓冲、不配对、不轮询

    /// IMU 入队的公共部分:闸 → async → 在 worker 上推。
    /// 回调**只做这些**,一次算法调用都不在这里发生。
    private func enqueueImu(_ push: @escaping () -> Void) {
        lock.lock()
        guard running else { lock.unlock(); return } // 上游 stopFlag 早退
        if pendingImu >= Self.maxPendingImu {
            imuDropped &+= 1
            lock.unlock()
            return
        }
        pendingImu += 1
        lock.unlock()
        workQueue.async { [weak self] in
            push()
            guard let self else { return }
            self.lock.lock(); self.pendingImu -= 1; self.lock.unlock()
        }
    }

    private func onGyro(_ data: CMGyroData) {
        // 🔴 陀螺 x/y/z **原样透传不换算**(上游 Motion.swift:47 就是原值),
        //    时间戳用**这条样本自己的** `data.timestamp`。
        let t = data.timestamp
        let r = data.rotationRate
        lock.lock(); lastImuTs = t; lock.unlock()
        enqueueImu { _ = PWXrslamTransportPushGyroscopeRaw(t, r.x, r.y, r.z) }
    }

    private func onAccel(_ data: CMAccelerometerData) {
        // 🔴 **常数是负的**:上游 `Motion.swift:3` `GRAVITY_NOMINAL = -9.80665`,
        //    并在 `Motion.swift:56` 直接乘上去。符号反了重力方向整个反过来。
        let g = -9.80665
        let t = data.timestamp
        let a = data.acceleration
        enqueueImu {
            _ = PWXrslamTransportPushAccelerationRaw(
                t, a.x * g, a.y * g, a.z * g)
        }
    }

    /// 由 `PwCameraSlot` 的 `captureOutput` 调用。
    ///
    /// 🔴 **只入队,不跑算法**(生产 `PwVioSlamFeeder.swift:9`:
    ///    "回调只尝试有界入队,绝不等算法")。在途满了就**计数丢弃**并立刻
    ///    返回 —— 让相机继续按自己的节奏交付,而不是被算法拖成 12 fps。
    func onCameraFrame(_ pixelBuffer: CVPixelBuffer, ptsSeconds: Double) {
        lock.lock()
        guard running else { lock.unlock(); return }
        framesOffered &+= 1
        lastCameraPts = ptsSeconds
        if lastImuTs > 0 {
            lastDelta = ptsSeconds - lastImuTs
            haveDelta = true
            if abs(lastDelta) > maxAbsDelta { maxAbsDelta = abs(lastDelta) }
        }
        if pendingFrames >= Self.maxPendingFrames {
            framesDropped &+= 1
            lock.unlock()
            return
        }
        pendingFrames += 1
        if pendingFrames > maxObservedPendingFrames {
            maxObservedPendingFrames = pendingFrames
        }
        lock.unlock()

        // `CVPixelBuffer` 是 CF 桥接类型,捕获进闭包即 retain、闭包销毁即
        // release —— 池里的这一格在 worker 用完之前不会被覆盖。
        workQueue.async { [weak self] in
            self?.runOneFrame(pixelBuffer, ptsSeconds: ptsSeconds)
        }
    }

    /// 在 worker 上跑。与上游 `trackCamera`(`XRSLAM_iOS.mm:152-188`)同形:
    /// push → RunOneFrame → GetResult 由传输层一次原子做完。
    private func runOneFrame(_ pixelBuffer: CVPixelBuffer, ptsSeconds: Double) {
        defer {
            lock.lock(); pendingFrames -= 1; lock.unlock()
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else {
            lock.lock(); cameraLockFailures &+= 1; lock.unlock()
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var state: Int32 = 0
        var pose = PWXrslamRawPose()
        // channel = 4:BGRA 直推,引擎内部转灰度(见文件头偏离 (b))。
        let rc = PWXrslamTransportPushCameraAndRunRaw(
            base.assumingMemoryBound(to: UInt8.self),
            ptsSeconds, Int32(stride), /*camera_id=*/0, /*channel=*/4,
            &state, &pose)

        lock.lock()
        cameraCallbacks &+= 1
        if rc == PW_XRSLAM_OK.rawValue {
            lastState = state
            // 🔴 只有 TRACKING_SUCCESS 才更新位姿 —— 抄上游 XRSLAM_iOS.mm:171
            //    `if (result == XRSLAM_STATE_TRACKING_SUCCESS)`,其余状态下
            //    引擎返回的是陈旧/未定义值。
            if state == 1 {
                lastPose = pose
                haveResult = true
            }
        }
        lock.unlock()
    }

    // MARK: 读出

    /// 写 4 个 double:最近相机 PTS、最近 IMU 时间戳、两者之差、|差| 的最大值。
    /// 返回 0 = 有样本;-1 = 还没有。见 [lastDelta] 上面那段说明。
    func timing(into out: UnsafeMutablePointer<Double>) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        out[0] = lastCameraPts
        out[1] = lastImuTs
        out[2] = lastDelta
        out[3] = maxAbsDelta
        return haveDelta ? 0 : -1
    }

    /// 写 9 个 double:state t qx qy qz qw px py pz。
    /// 0 = 有位姿;-1 = 还没有(state 仍写出,供诊断)。
    func latest(into out: UnsafeMutablePointer<Double>) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        out[0] = Double(lastState)
        out[1] = lastPose.timestamp
        out[2] = lastPose.quaternion.0
        out[3] = lastPose.quaternion.1
        out[4] = lastPose.quaternion.2
        out[5] = lastPose.quaternion.3
        out[6] = lastPose.translation.0
        out[7] = lastPose.translation.1
        out[8] = lastPose.translation.2
        return haveResult ? 0 : -1
    }

    /// 写 14 个 int64。前 8 个**直接来自 C++ 账本**,不在 Swift 里合成
    /// (`PwXrslamTransportCore.h` 原话 "Swift must not synthesize them");
    /// 后 6 个是本文件自己的入队闸计数。
    func stats(into out: UnsafeMutablePointer<Int64>) {
        var c = PWXrslamTransportCounters()
        _ = PWXrslamTransportGetCounters(&c)
        out[0] = Int64(bitPattern: c.camera_submitted)
        out[1] = Int64(bitPattern: c.camera_run_calls)
        out[2] = Int64(bitPattern: c.acceleration_submitted)
        out[3] = Int64(bitPattern: c.gyroscope_submitted)
        out[4] = Int64(bitPattern: c.rejected_non_monotonic)
        out[5] = Int64(bitPattern: c.rejected_invalid_argument)
        out[6] = Int64(bitPattern: c.rejected_not_running)
        out[7] = Int64(c.running)
        lock.lock()
        out[8] = Int64(bitPattern: cameraCallbacks)
        out[9] = Int64(bitPattern: cameraLockFailures)
        out[10] = Int64(bitPattern: framesOffered)
        out[11] = Int64(bitPattern: framesDropped)
        out[12] = Int64(bitPattern: imuDropped)
        out[13] = Int64(maxObservedPendingFrames)
        lock.unlock()
    }
}

// ── C ABI ────────────────────────────────────────────────────────────────

/// 建会话。**1 成功 / 0 失败**(冻结的 XRSLAMCreate 口径)。
@_cdecl("pw_xrslam_live_create")
public func pw_xrslam_live_create(
    _ slamConfigPath: UnsafePointer<CChar>,
    _ deviceConfigPath: UnsafePointer<CChar>
) -> Int32 {
    return PwXrslamLive.shared.create(
        slamConfigPath: String(cString: slamConfigPath),
        deviceConfigPath: String(cString: deviceConfigPath))
}

/// 起 IMU 并开始推送。0 成功;-1/-2 传感器不可用;-3 还没 create。
@_cdecl("pw_xrslam_live_begin")
public func pw_xrslam_live_begin(_ rateHz: Double) -> Int32 {
    return PwXrslamLive.shared.begin(rateHz: rateHz)
}

@_cdecl("pw_xrslam_live_destroy")
public func pw_xrslam_live_destroy() {
    PwXrslamLive.shared.destroy()
}

/// 写 9 个 double:state t qx qy qz qw px py pz。返回 0 有位姿 / -1 还没有。
@_cdecl("pw_xrslam_live_latest")
public func pw_xrslam_live_latest(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    return PwXrslamLive.shared.latest(into: out)
}

/// 把 GPU 前端初始化痕迹写进 `out`(最多 `cap` 字节,含结尾 0),返回写了多少字节。
@_cdecl("pw_xrslam_live_gpufe_trail")
public func pw_xrslam_live_gpufe_trail(
    _ out: UnsafeMutablePointer<CChar>, _ cap: Int32
) -> Int32 {
    let t = PwXrslamLive.shared.gpuFrontEndTrail()
    let bytes = Array(t.utf8)
    let n = min(bytes.count, Int(cap) - 1)
    if n > 0 {
        bytes.withUnsafeBufferPointer { src in
            out.withMemoryRebound(to: UInt8.self, capacity: n) { dst in
                dst.update(from: src.baseAddress!, count: n)
            }
        }
    }
    out[n] = 0
    return Int32(n)
}

/// 写 4 个 double:相机 PTS / IMU 时间戳 / 差 / |差| 峰值。0 有样本 / -1 没有。
@_cdecl("pw_xrslam_live_timing")
public func pw_xrslam_live_timing(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    return PwXrslamLive.shared.timing(into: out)
}

/// 写 14 个 int64,见 `PwXrslamLive.stats`。
@_cdecl("pw_xrslam_live_stats")
public func pw_xrslam_live_stats(_ out: UnsafeMutablePointer<Int64>) {
    PwXrslamLive.shared.stats(into: out)
}
