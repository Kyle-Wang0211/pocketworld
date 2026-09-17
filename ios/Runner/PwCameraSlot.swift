// PwCameraSlot.swift — 相机帧的**深度 1 保留槽**,C ABI 出口给 Dart FFI。
//
// ══ 为什么需要它,以及为什么不能用更简单的做法 ═══════════════════════════
//
// 目标:把相机帧交给 Filament 的 `Texture::setExternalImage`。
// 天真做法是"把 `CVPixelBufferRef` 的地址通过平台通道发给 Dart"。**那个做法
// 有一个不会崩的错误**:
//
//   `CVPixelBuffer` 的有效期只有 `captureOutput` 回调体内。AVFoundation 回收
//   它进自己的池。而因为底层 **IOSurface 是被复用、而不是解除映射**的,晚到
//   的读者**不会 segfault** —— 它读到的是 AVFoundation 之后写进那块 surface
//   的**别的帧,或撕裂的混合**。静默错像素,比崩溃更坏,任何计数器都抓不到。
//
// 所以像素留在原生侧,由这里持有所有权;Dart 只在**它自己的线程上同步**地
// 来取。四种可选机制里只有这一种没有线程亲和性风险:
//   ⚰️ `NativeCallable.isolateLocal` —— Dart 官方文档原话 "It will **abort the
//      process** if invoked on any other thread."。采集回调不在 Dart mutator
//      线程上,**每帧必 abort**。
//   ⚰️ `NativeCallable.listener` —— 可从任意线程调,但异步 + 只能返回 void +
//      无背压 ⇒ 只能当"有新帧了"的通知,交不出指针。
//   ⚰️ `MethodChannel` 逐帧 —— Flutter 文档要求"必须在平台主线程调用",
//      30–60Hz 会把序列化搬上主线程,而且交到的地址已经过期。
//   ✅ **Dart→原生 FFI 同步调用** —— 在调用方 isolate 线程上执行,无亲和性问题。
//
// ══ 深度 1、换入即释放:不是省事,是复刻已被实测验证的策略 ═══════════════
//
// 台架的 `LumaPlanePool` 注释里记着修之前的实测(引 Apple TN2445):
// **3592 帧掉 539 帧 `OutOfBuffers` = 15%**,p95 流水线延迟 908 ms。根因就是
// "client holding onto buffers for too long"。所以这里**绝不排队**:新帧换入,
// 被顶掉的那个立刻释放。渲染器要的本来就是最新一帧,不是一串旧帧。
//
// ══ 所有权契约(已在 Filament 源码双向核实)═══════════════════════════════
// `MetalExternalImage.mm:109/113/170` 里 Filament 自己 `CVPixelBufferRetain`
// **一份(+1)**,不接管调用方的。所以:
//   `acquire()` 交出的是**已 retain 的 +1,归调用方所有**;
//   调用方把它交给 `setExternalImage` 之后,**必须调 `release()` 还掉自己那份**。
// 不还 = 每帧漏一个全分辨率缓冲,几秒内就会把相机池耗干 ⇒ 回到上面那个 15%。
//
// ══ 像素格式 ═════════════════════════════════════════════════════════════
// 固定 **32BGRA**。Filament 的 Metal 后端只接受 32BGRA 与 420f
// (`MetalExternalImage.mm:96-102`,是 `FILAMENT_CHECK_POSTCONDITION`,**致命
// 检查不是回退**),而 **只有 32BGRA 是真零拷贝** —— 420f 会多跑一个 GPU
// 计算通道转 RGB(`:112-130`)。
// ⚠️ 顺带:Flutter 的 `FlutterTexture.h` 还允许 **VideoRange**,Filament **不**
// 允许 —— 换成 video-range 会在 Filament 里 abort。这里写死 FullRange 之外的
// 那个(32BGRA)就绕开了整个问题。
//
// ══ 🔴 这是验证用的独立通路,不碰生产 ═══════════════════════════════════
// 它自己开一个最小 `AVCaptureSession`,**不经过 `PwARCameraLease`,不碰 ARKit**。
// iOS 把后置相机只给一个会话,所以它和生产的采集**不能同时跑** —— 这是刻意的:
// 本通路只在显式调用 `pw_camera_slot_start` 时才活,其余时间完全惰性。

import AVFoundation
import CoreVideo
import Foundation

private final class PwCameraSlotImpl: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    static let shared = PwCameraSlotImpl()

    private let lock = NSLock()
    private var session: AVCaptureSession?
    /// 深度 1。`nil` 表示消费者已取走、还没有新帧。
    private var slot: CVPixelBuffer?

    /// 相机自报的内参,来自 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`。
    /// 逐帧更新 —— 自动对焦全程在动,实测单场 120 秒 fx 漂 10.90%。
    private var fx: Double = 0
    private var fy: Double = 0
    private var cx: Double = 0
    private var cy: Double = 0

    // 计账。没有这些就分不清"没帧"和"帧被丢了"。
    private var offered: Int64 = 0
    private var displaced: Int64 = 0
    private var acquired: Int64 = 0
    private var released: Int64 = 0

    private let queue = DispatchQueue(
        label: "com.pocketworld.camera.slot", qos: .userInitiated)

    func start(width: Int32, height: Int32) -> Int32 {
        lock.lock()
        if session != nil { lock.unlock(); return 0 }  // 已在跑
        lock.unlock()

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back) else { return -1 }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return -2 }

        let s = AVCaptureSession()
        s.beginConfiguration()
        guard s.canSetSessionPreset(.inputPriority) else {
            s.commitConfiguration(); return -3
        }
        s.sessionPreset = .inputPriority
        guard s.canAddInput(input) else { s.commitConfiguration(); return -4 }
        s.addInput(input)

        let out = AVCaptureVideoDataOutput()
        // TN2445:晚到的帧丢掉,不排队。
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { s.commitConfiguration(); return -5 }
        s.addOutput(out)

        // 🔴 顺序是承重的:`videoSettings` 会拿**源设备的 activeFormat** 做校验,
        // 抛的是 ObjC 异常(Swift 接不住,直接 SIGABRT)。所以必须先选定
        // activeFormat,再设 videoSettings。这条是今晚在台架上用一次 SIGABRT
        // 换来的:
        //   "Video settings dimensions must maintain the source device
        //    activeFormat's aspect ratio"
        // 另注:`AVCaptureDevice.Format` 的子类型**永远是 420f/420v/x420**,
        // 没有 BGRA —— BGRA 是输出侧的转换,不是设备格式。拿 BGRA 去过滤
        // `device.formats` 会得到空集。
        guard out.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA)
        else { s.commitConfiguration(); return -6 }

        if let conn = out.connection(with: .video) {
            // 🔴 刻意不设 `videoRotationAngle`(那是 iOS 17+ API,而且本通路
            // 用不上):相机按**传感器方向**交付,旋转由我们自己算的 UV 变换
            // 处理(`display_transform.dart`)。让连接层去转等于把同一件事做
            // 两遍,而且那条路在三端各不相同——正是我们要绕开的东西。
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .off
            }
            // 要相机自报内参 —— 我们自己算投影矩阵,不调任何厂商 AR API。
            if conn.isCameraIntrinsicMatrixDeliverySupported {
                conn.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
        s.commitConfiguration()

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let cands = device.formats.filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
                return d.width == width && d.height == height
                    && sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            }
            guard let f = cands.first(where: { !$0.isVideoBinned }) ?? cands.first
            else { return -7 }
            device.activeFormat = f
        } catch { return -8 }

        // 只有到这里,activeFormat 才是我们要的那个,校验才会通过。
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
        ]

        lock.lock(); session = s; lock.unlock()
        s.startRunning()
        return 0
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        slot = nil  // ARC + CVPixelBuffer 的 Swift 桥接会释放它
        lock.unlock()
        s?.stopRunning()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 内参:每帧都读,因为自动对焦全程在动。
        if let raw = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data,
            raw.count >= MemoryLayout<Float>.size * 9
        {
            let m = raw.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            lock.lock()
            fx = Double(m.columns.0.x); fy = Double(m.columns.1.y)
            cx = Double(m.columns.2.x); cy = Double(m.columns.2.y)
            lock.unlock()
        }

        // 换入即释放。Swift 的 `CVPixelBuffer` 是 CF 桥接类型,赋值即 retain、
        // 覆盖即 release —— 不需要手写 CVPixelBufferRetain/Release。
        lock.lock()
        offered &+= 1
        if slot != nil { displaced &+= 1 }
        slot = pb
        lock.unlock()
    }

    /// 取走当前帧。返回一个**已 retain 的 +1**,归调用方所有。
    /// 槽被清空,所以同一帧不会被取两次。
    func acquire() -> UInt64 {
        lock.lock()
        guard let pb = slot else { lock.unlock(); return 0 }
        slot = nil
        acquired &+= 1
        lock.unlock()
        // 交给 C 世界之前显式 +1 —— 出了 Swift 的作用域 ARC 就不再管它。
        return UInt64(UInt(bitPattern: Unmanaged.passRetained(pb).toOpaque()))
    }

    func release(_ addr: UInt64) {
        guard addr != 0 else { return }
        let p = UnsafeRawPointer(bitPattern: UInt(addr))!
        Unmanaged<CVPixelBuffer>.fromOpaque(p).release()
        lock.lock(); released &+= 1; lock.unlock()
    }

    func intrinsics(into out: UnsafeMutablePointer<Double>) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard fx > 0 else { return -1 }
        out[0] = fx; out[1] = fy; out[2] = cx; out[3] = cy
        return 0
    }

    func stats(into out: UnsafeMutablePointer<Int64>) {
        lock.lock(); defer { lock.unlock() }
        out[0] = offered
        out[1] = displaced
        out[2] = acquired
        out[3] = released
        out[4] = slot != nil ? 1 : 0
    }
}

// ══ C ABI 出口 ══════════════════════════════════════════════════════════
// `@_cdecl` 给 Swift 函数 C 链接,Dart 侧用 `DynamicLibrary.process()` 查找
// (仓里 `official_aether_sfm_ffi.dart:31` 已有同样的用法)。

@_cdecl("pw_camera_slot_start")
public func pw_camera_slot_start(_ width: Int32, _ height: Int32) -> Int32 {
    return PwCameraSlotImpl.shared.start(width: width, height: height)
}

@_cdecl("pw_camera_slot_stop")
public func pw_camera_slot_stop() {
    PwCameraSlotImpl.shared.stop()
}

/// 返回一个**已 retain 的 `CVPixelBufferRef` 地址**;0 = 当前无新帧。
/// 🔴 调用方拿到后**必须**配一次 `pw_camera_slot_release`。
@_cdecl("pw_camera_slot_acquire")
public func pw_camera_slot_acquire() -> UInt64 {
    return PwCameraSlotImpl.shared.acquire()
}

@_cdecl("pw_camera_slot_release")
public func pw_camera_slot_release(_ addr: UInt64) {
    PwCameraSlotImpl.shared.release(addr)
}

/// 写入 4 个 double:fx, fy, cx, cy。返回 0 成功,-1 表示还没拿到内参。
@_cdecl("pw_camera_slot_intrinsics")
public func pw_camera_slot_intrinsics(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    return PwCameraSlotImpl.shared.intrinsics(into: out)
}

/// 写入 5 个 int64:offered, displaced, acquired, released, slotOccupied。
/// `acquired - released` 就是当前泄漏量;它应当恒为 0 或 1。
@_cdecl("pw_camera_slot_stats")
public func pw_camera_slot_stats(_ out: UnsafeMutablePointer<Int64>) {
    PwCameraSlotImpl.shared.stats(into: out)
}
