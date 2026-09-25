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
import ImageIO

private final class PwCameraSlotImpl: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    static let shared = PwCameraSlotImpl()

    /// 最新一帧的**采集时刻**(host time clock 秒)。见 captureOutput 里的说明。
    /// 🔴 XRSLAM 的 PushImage 有严格递增闸,必须用这个而不是"取帧那一刻"。
    fileprivate var latestFramePTSSeconds: Double = 0

    /// [pw 2026-09-22] 最新一帧的**曝光时长**(秒)。与 PTS 同一回调里读,喂给
    /// `PwXrslamLive.onCameraFrame` 做曝光中点换算(见那边文件头偏离 (d))。
    /// 读法抄 Huai 的 MARS logger(arXiv 2001.00470 §III.B):
    /// "the exposureDuration read from the AVCaptureDevice instance is recorded
    ///  for every frame" —— 回调时刻的设备状态,不是 EXIF 附件。自动曝光下它逐帧变。
    fileprivate var latestExposureSeconds: Double = 0

    /// [pw 2026-09-19] 只读诊断:当前采集设备与所选格式是否 binned。
    /// 加它是为了回答"bench 画面为什么比系统相机暗" —— 不改任何采集设置。
    fileprivate var device: AVCaptureDevice?
    fileprivate var pickedFormatIsBinned: Bool = false

    // ── 高清拍照(见文件末尾 MARK: 高清拍照)────────────────────────────
    /// 最新一帧视频流的实际交付尺寸。**内参按分辨率缩放时的分母就是它**,
    /// 不能用 start() 传进来的请求值 —— 请求值不保证等于实际交付值。
    fileprivate var latestFrameWidth: Int = 0
    fileprivate var latestFrameHeight: Int = 0

    /// [pw 2026-09-23 逐帧内参] start() 里选定的 activeFormat 的尺寸。随每帧 K 一起
    /// 交给 `PwXrslamLive`,由它核对「K 的参照尺寸 == 推给引擎的像素尺寸」。
    fileprivate var activeFormatWidth: Int = 0
    fileprivate var activeFormatHeight: Int = 0

    fileprivate var photoOutput: AVCapturePhotoOutput?
    /// 照片输出没装上时,原因原样记下来写进 sidecar,而不是静默降级。
    fileprivate var photoOutputNote: String = "not_installed"

    /// [ENTRY-ANY-4X3 / ANY43-DEFAULT 2026-09-25] Dart 按共享规则(lib/vio/capture/photo_size_rule.dart
    /// `pickLargestFourByThreeInDefaultMode`)从 [pw_camera_slot_photo_size_candidates] 报的候选里选定的
    /// 照片尺寸,由 [pw_camera_slot_request_photo_dims] 在 start() **之前**写入;start() 配置
    /// 照片输出时读取。0x0 = 没有请求 ⇒ 旧行为(activeFormat 支持的面积最大值)。
    /// 宿主只查、不判:判据只在 Dart(与核外壳 pwofficial_photo_size_status_v1 同一份)。
    fileprivate var requestedPhotoWidth: Int32 = 0
    fileprivate var requestedPhotoHeight: Int32 = 0
    /// 照片最大尺寸是怎么定的,写进视频档快照(→ 每张照片的 sidecar)。
    fileprivate var photoDimsSource: String = "not_configured"
    /// 采集配置完成、**startRunning 之前**拍下的视频档快照。拍照时再拍一张
    /// 与它比,就是"加照片输出没有降低视频流格式/帧率"的运行期自证。
    fileprivate var configuredVideoProof: [String: Any] = [:]

    private let photoLock = NSLock()
    /// 一次拍照一个 delegate 对象(抄 AVCam:`inProgressPhotoCaptureDelegates`,
    /// 因为"The Photo Output keeps a weak reference to the photo capture
    /// delegate so we store it in an array to maintain a strong reference"）。
    private var inFlightPhotos: [Int64: PwPhotoCaptureProcessor] = [:]
    /// 已完成、等待被 poll 取走的结果。**FIFO、有界**:拍得比取得快时丢最老的,
    /// 并把丢弃数计账 —— 不静默。
    private var completedPhotos: [PwPhotoResult] = []
    private var photoDropped: Int64 = 0
    private static let kCompletedPhotoCap = 32

    /// 文件落盘与 JSON 序列化都在这条队列上,**绝不占用 `queue`** ——
    /// `queue` 是相机帧与 IMU 共享的那条串行上下文(见上面 bindSerialQueue),
    /// 在它上面写几 MB 文件等于给 VIO 喂料插一根桩。
    fileprivate let photoQueue = DispatchQueue(
        label: "com.pocketworld.camera.photo", qos: .utility)

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

    /// [fps] / [lensPosition] 见 `pw_camera_slot_start` 的说明。
    func start(width: Int32, height: Int32,
               fps: Double, lensPosition: Double) -> Int32 {
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
        // 🔴 把这条队列登记给引擎喂料侧 —— 上游 `Camera.swift:47` /
        //    `Motion.swift:38` 两处默认都是 `.main`,即**相机与 IMU 共享同一个
        //    串行上下文**,到达顺序因此守序。我们不能占 Flutter 的 UI 线程,
        //    所以共享的是这条队列;被复刻的是"共享"这条性质。见 PwXrslamLive。
        PwXrslamLive.shared.bindSerialQueue(queue)
        guard s.canAddOutput(out) else { s.commitConfiguration(); return -5 }
        s.addOutput(out)

        // ── 照片输出(抄 AVCam `CameraViewController.configureSession()` 的
        //    "// Add photo output." 那一段:`canAddOutput` → `addOutput` →
        //    置高清相关开关)。
        //    🔴 **失败不影响视频流**:装不上就记原因、继续跑 VIO,
        //       只让 pw_camera_slot_capture_photo 返回错误码。
        //    🔴 位置是承重的:必须在 `beginConfiguration` 块内加输出,且必须
        //       在下面 `device.activeFormat = f` **之前** —— 这样 activeFormat
        //       是我们最后一个写的人,照片管线不可能把它改回去。
        let photo = AVCapturePhotoOutput()
        if s.canAddOutput(photo) {
            s.addOutput(photo)
            // 🔴 **.speed,不是 .balanced/.quality**。AVCapturePhotoOutput.h:348
            //    原文:"Setting the maxPhotoQualityPrioritization to .quality
            //    will turn on optical image stabilization if the
            //    -isHighPhotoQualitySupported of the source device's
            //    -activeFormat is true."
            //    而 OIS 一开,像素就与物理位姿脱钩(AVCaptureDevice.h:2311
            //    "The extrinsicMatrix and camera intrinsics should only be used
            //    when video stabilization is disabled"),内参这张照片就作废。
            //    .speed 还顺带关掉多帧融合 —— 融合出来的照片没有单一曝光时刻。
            photo.maxPhotoQualityPrioritization = .speed
            self.photoOutput = photo
            self.photoOutputNote = "installed"
        } else {
            self.photoOutputNote = "can_add_output_false"
        }

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
            guard let f = Self.pickVideoFormat(device: device, width: width, height: height)
            else { return -7 }
            device.activeFormat = f
            let activeDims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            self.activeFormatWidth = Int(activeDims.width)
            self.activeFormatHeight = Int(activeDims.height)

            // 🔴🔴 [pw 2026-09-23 用户拍板「换掉锁定,照生产那套来」]
            //    **下面这段锁焦不再是默认路径**。默认臂已从 A 换成 B
            //    (生产同款苹果 AF,见 `PwFocusArms.swift` 的 `arm = .b`)⇒
            //    不传 `-PWFocusArm` 时下面这个 `if` 条件**不成立**,一行都不跑。
            //
            //    为什么非换不可 —— 生产 `OfficialAetherARKitPlugin.swift:2189-2191`
            //    的注释原文(血的教训,逐字抄在这里):
            //
            //      "Let ARKit drive continuous autofocus. Important: do not
            //       later flip the underlying AVCaptureDevice into one-shot
            //       focus/locked focus; that can leave the preview stuck at a
            //       near lens distance after the user moves."
            //
            //    而下面这一句 `setFocusModeLocked` **正是**那句话点名禁止的动作;
            //    用户实测本机 `minimumFocusDistance = 200 mm`,锁在 0.835(0=最近
            //    1=最远 ⇒ 0.835 几乎锁在远端)拍 10–30 cm 的小物体,成片必糊。
            //
            //    代码**一个字节没删**:它是**阴性对照臂** —— 「对焦这件事从没
            //    发生过」的基线。要它就显式 `-PWFocusArm a`。
            //
            // ── 原来的理由存档(仍然是真的,只是被「先要清晰」压过)──────────
            //    上游 `ViewController.swift:256` 是 `camera.setFocus(0.835)` →
            //    `setFocusModeLocked(lensPosition:)`。整条管线的内参 `frame->K`
            //    来自 yaml(`detail.cpp:107`),**没有任何一处按实际图像重算**;
            //    连续自动对焦会让 fx 全程游走 —— 实测一场 1280.37–1385.30、
            //    跨度 7.7%、1429 个唯一值。镜头不锁 = 拿一个定值内参去解一台
            //    焦距在变的相机。🔴 换成连续 AF 之后这笔账没有消失,只是搬了家:
            //    逐帧 K 那条路(`reference_adaptive_focus_vio_survey_20260922`:
            //    平台逐帧供 K、引擎逐帧消费)是它的正解,尚未接。**本刀不解决它**,
            //    但用户原则在前:「最上游输入必须清晰;模糊的素材后面就完了」。
            //    [lensPosition] < 0 表示"不锁"(保留给需要对比的实验)。
            let focusArm = PwFocusArms.shared.currentArm()
            if lensPosition >= 0 && focusArm == .a {
                device.setFocusModeLocked(
                    lensPosition: Float(min(max(lensPosition, 0), 1)),
                    completionHandler: nil)
            }
            // 🔴 台架第一件事:读 `minimumFocusDistance`(毫米,-1 未知)——
            //    它决定 10 cm 档在主摄上是否物理可达(判决书附录 A.4)。
            //    三臂都调:A 臂(阴性对照)只读能力位与建度量 context,不碰任何
            //    设备设置;**默认的 B 臂就是在这里装上生产同款的连续 AF**
            //    (`isSmoothAutoFocusEnabled` + `.continuousAutoFocus`,逐句对照
            //    `OfficialAetherARKitPlugin.swift:2653-2661`)。
            //    必须在 lockForConfiguration 块内(B/C 要改 focus* 属性)。
            PwFocusArms.shared.configureAtStart(device: device)

            // 🔴 **显式定帧率**,值抄上游 `ViewController.swift:255`
            //    `camera.setFps(30)`。做法也抄 `Camera.setFps`:在 activeFormat
            //    支持的区间里同时钉住 min/max frameDuration。
            //    ⚠️ 我一度传 60(依据是回放上的 30Hz vs 60Hz 对照),那条依据
            //    **不适用于直播**:回放没有实时截止期。实测引擎在 1920×1440 上
            //    只吃得下 24.5 fps,喂 59 fps 会让 58% 的帧被不规则丢掉。
            if fps > 0 {
                let want = Int32(fps.rounded())
                for r in f.videoSupportedFrameRateRanges
                where r.minFrameRate <= Double(want) && r.maxFrameRate >= Double(want) {
                    device.activeVideoMinFrameDuration =
                        CMTime(value: 1, timescale: want)
                    device.activeVideoMaxFrameDuration =
                        CMTime(value: 1, timescale: want)
                    break
                }
            }

            // [pw 2026-09-19] 存住设备,供 pw_camera_slot_exposure 读实际曝光参数。
            self.device = device
            self.pickedFormatIsBinned = f.isVideoBinned
        } catch { return -8 }

        // 只有到这里,activeFormat 才是我们要的那个,校验才会通过。
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
        ]

        // ── 照片最高分辨率。
        //    AVCapturePhotoOutput.h:544 原文:"The dimensions set must match one
        //    of the dimensions returned by
        //    AVCaptureDeviceFormat.supportedMaxPhotoDimensions for the current
        //    active format. Changing this property may trigger a lengthy
        //    reconfiguration of the capture render pipeline so it is recommended
        //    that this is set before calling -[AVCaptureSession startRunning]."
        //    ⇒ 两条约束都在这里被满足:activeFormat 已经定下来了(上面那个
        //      do 块),而 startRunning 还没调(就在下面几行)。
        //    🔴 **取 activeFormat 支持的最大值,不换 activeFormat**。换格式就
        //      会降视频流 —— 而视频流 ≥1920×1440 是铁律。所以照片分辨率的上限
        //      由"视频流要的那个格式"决定,这是刻意的取舍,不是遗漏。
        //    [ENTRY-ANY-4X3 / ANY43-DEFAULT 2026-09-25] 用户规则「平台默认模式下的最大 4:3」:
        //      Dart 已按共享规则从本 activeFormat 的 supportedMaxPhotoDimensions 里挑好
        //      (requestedPhoto*),这里只做「必须是该格式支持的一项」这道官方约束。
        //      此前是「面积最大」,不看宽高比 —— 16:9 更大时会拍出入口不收的图。
        if let photo = self.photoOutput {
            if #available(iOS 16.0, *) {
                let supported = device.activeFormat.supportedMaxPhotoDimensions
                let reqW = requestedPhotoWidth, reqH = requestedPhotoHeight
                if reqW > 0 && reqH > 0 {
                    if let m = supported.first(where: { $0.width == reqW && $0.height == reqH }) {
                        photo.maxPhotoDimensions = m
                        photoDimsSource = "dart_rule_largest_4x3_default_mode"
                    } else {
                        // 不静默换成别的尺寸:照片将按 AVFoundation 默认(最小一档)出,
                        // 入口闸会给出明确原因。来源写进 sidecar。
                        photoDimsSource = "dart_rule_request_unsupported_\(reqW)x\(reqH)"
                    }
                } else {
                    var best = CMVideoDimensions(width: 0, height: 0)
                    for v in supported {
                        let d = v
                        if Int64(d.width) * Int64(d.height)
                            > Int64(best.width) * Int64(best.height) {
                            best = d
                        }
                    }
                    if best.width > 0 && best.height > 0 {
                        photo.maxPhotoDimensions = best
                    }
                    photoDimsSource = "legacy_max_area_no_request"
                }
            } else {
                // iOS 15 档(本工程 IPHONEOS_DEPLOYMENT_TARGET = 15.0)。
                // maxPhotoDimensions 是 iOS 16 才有的;15 上只有这个已废弃的
                // 开关,AVCam 当年抄的也正是它。
                photo.isHighResolutionCaptureEnabled = true
                photoDimsSource = "ios15_high_resolution_flag"
            }
        }

        self.configuredVideoProof = Self.videoProofDict(
            device: device, videoOutput: out, photoOutput: self.photoOutput)
        self.configuredVideoProof["photo_dims_source"] = photoDimsSource

        lock.lock(); session = s; lock.unlock()
        s.startRunning()
        return 0
    }

    fileprivate func requestPhotoDims(width: Int32, height: Int32) -> Int32 {
        lock.lock()
        let running = session != nil
        lock.unlock()
        if running { return -11 }
        requestedPhotoWidth = max(0, width)
        requestedPhotoHeight = max(0, height)
        return 0
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        slot = nil  // ARC + CVPixelBuffer 的 Swift 桥接会释放它
        lock.unlock()
        // [pw 2026-09-23 对焦三臂] 放掉设备引用、把在途的对焦如实记成 error。
        // **不清时间序列** —— Dart 还要把它 drain 进 manifest。
        PwFocusArms.shared.onCameraStopped()
        s?.stopRunning()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 🔴 [pw 2026-09-19] 记下这一帧的**采集时刻**(presentationTimeStamp)。
        // 为什么必须有:XRSLAM 的 `PushImage` 里有一道
        // `gate_monotonic_locked` —— 时间戳**不严格递增就整帧丢弃**
        // (XRSLAMManager.cpp:433-441,日志 "not strictly increasing, frame dropped")。
        // 此前我们推帧时用的是 **Dart 侧 Stopwatch 的当前时刻**,那是"取帧那一刻"
        // 而不是"这一帧何时被采集",既不是同一时间域、也不保证与帧序一致
        // ⇒ 大量帧被闸拒,`cur_image_` 常为空,`RunOneFrame` 立刻返回。
        // PTS 用 host time clock,与 `PwMonotonicClock` 的规范域一致。
        latestFramePTSSeconds = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        // [pw 2026-09-22] 同一回调里读当帧曝光。`device` 在 start() 里存住,
        // 还没存住时为 0 ⇒ 下游按"无曝光信息"如实计数,不猜。
        if let d = device {
            let e = CMTimeGetSeconds(d.exposureDuration)
            latestExposureSeconds = (e.isFinite && e >= 0) ? e : 0
        } else {
            latestExposureSeconds = 0
        }

        // 内参:每帧都读,因为自动对焦全程在动。
        // [pw 2026-09-23 逐帧内参] 读法对齐 `PwVioCapability.swift`
        //   `fromSampleBuffer`:按整个 `matrix_float3x3`(48 字节,simd 列 16 字节对齐)
        //   判长度并 `loadUnaligned`(旧写法按 9×Float=36 字节判长度再 `load` 48 字节)。
        //   列主序:fx = columns.0.x、fy = columns.1.y、cx/cy = columns.2.x/.y
        //   (CMSampleBuffer.h:1852-1857)。参照尺寸 = 这个 sample buffer 的格式描述
        //   ("applied to the current sample buffer",同上)。这一帧的 K 随这一帧进引擎。
        var frameIntrinsics: PwFrameIntrinsics? = nil
        if let raw = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data,
            raw.count >= MemoryLayout<matrix_float3x3>.size
        {
            let m = raw.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            let kfx = Double(m.columns.0.x), kfy = Double(m.columns.1.y)
            let kcx = Double(m.columns.2.x), kcy = Double(m.columns.2.y)
            lock.lock()
            fx = kfx; fy = kfy
            cx = kcx; cy = kcy
            lock.unlock()
            if let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let refDims = CMVideoFormatDescriptionGetDimensions(fd)
                frameIntrinsics = PwFrameIntrinsics(
                    fx: kfx, fy: kfy, cx: kcx, cy: kcy,
                    referenceWidth: Int(refDims.width),
                    referenceHeight: Int(refDims.height),
                    activeFormatWidth: activeFormatWidth,
                    activeFormatHeight: activeFormatHeight)
            }
        }

        // 🔴 **在这个回调里当场喂引擎**,与上游 `XRSLAMer.cameraDidOutput →
        //    trackCamera` 同位(`XRSLAMer.swift:27-33` / `XRSLAM_iOS.mm:152`)。
        //    上一版是 Dart 每渲染帧再来取一次 —— 那既改了节奏也改了顺序。
        //    位姿结果由 `PwXrslamLive` 存住,Dart 只读,不进热路径。
        PwXrslamLive.shared.onCameraFrame(
            pb, ptsSeconds: latestFramePTSSeconds,
            exposureSeconds: latestExposureSeconds,
            intrinsics: frameIntrinsics)

        // [pw 2026-09-23 对焦三臂] **三臂都在这里算同一个度量**(A/B 臂不驱动
        // 镜头,但没有度量就没得比);C 臂在里面顺带把状态机推一步并下发镜头。
        // 位置在喂引擎**之后**:VIO 的实时截止期优先,对焦是观测不是承重。
        PwFocusArms.shared.onFrame(pb, ptsSeconds: latestFramePTSSeconds)

        // 换入即释放。Swift 的 `CVPixelBuffer` 是 CF 桥接类型,赋值即 retain、
        // 覆盖即 release —— 不需要手写 CVPixelBufferRetain/Release。
        lock.lock()
        offered &+= 1
        if slot != nil { displaced &+= 1 }
        slot = pb
        // 拍照时把内参从视频流分辨率缩到照片分辨率,分母就是这两个数。
        latestFrameWidth = CVPixelBufferGetWidth(pb)
        latestFrameHeight = CVPixelBufferGetHeight(pb)
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

/// 起相机。
/// - `fps`:目标帧率;`<= 0` 表示不设(由系统选)。上游是 30,我们传 60。
/// - `lensPosition`:锁定的镜头位置 0…1;**负数表示不锁**。上游是 0.835。
@_cdecl("pw_camera_slot_start")
public func pw_camera_slot_start(_ width: Int32, _ height: Int32,
                                 _ fps: Double,
                                 _ lensPosition: Double) -> Int32 {
    return PwCameraSlotImpl.shared.start(
        width: width, height: height, fps: fps, lensPosition: lensPosition)
}

/// [ENTRY-ANY-4X3 / ANY43-DEFAULT 2026-09-25] 查询:start(width,height) 将选中的那个 activeFormat
/// 支持的照片最大尺寸(官方 API `AVCaptureDevice.Format.supportedMaxPhotoDimensions`,iOS 16+),
/// 每项按 (w, h, flags) 三元组写进 `outWHF`,最多 `cap` 项;返回候选总数(可能 > cap)。
/// 只报不判 —— 选择规则在 Dart(lib/vio/capture/photo_size_rule.dart
/// pickLargestFourByThreeInDefaultMode,用户 09-25 改判「平台默认模式下的最大 4:3」)。
/// flags(与 Dart kPhotoCandidateFlag* 同值):
///   bit0 = 需主动请求的高分辨率档:高于该格式 `highResolutionStillImageDimensions`
///          (AVCaptureDevice.h:3356「the highest resolution still image that can be produced by this
///          format」,iOS 16 之前的高分辨率静照口径)。48MP 全像素与 24MP 多帧融合都只能经 iOS 16 起的
///          maxPhotoDimensions 请求(AVCapturePhotoOutput.h:545 24MP 还须 deferred delivery),
///          因此都落在 bit0 ⇒ Dart 永不选。该属性读不到(0x0)时退回 Apple 字面默认:除最小项外全标 bit0。
///   bit1 = Apple 字面默认:AVCapturePhotoSettings.maxPhotoDimensions「defaults to the smallest
///          dimensions returned by supportedMaxPhotoDimensions」(AVCapturePhotoOutput.h:1454)。只作审计。
/// 负数:-1 无后置广角,-7 没有匹配的格式,-10 系统 < iOS 16(没有这个 API)。只读,不开相机。
@_cdecl("pw_camera_slot_photo_size_candidates")
public func pw_camera_slot_photo_size_candidates(
    _ width: Int32, _ height: Int32,
    _ outWHF: UnsafeMutablePointer<Int32>?, _ cap: Int32
) -> Int32 {
    guard let device = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .back) else { return -1 }
    guard let f = PwCameraSlotImpl.pickVideoFormat(
        device: device, width: width, height: height) else { return -7 }
    guard #available(iOS 16.0, *) else { return -10 }
    let flagged = PwCameraSlotImpl.photoSizeCandidateFlags(f)
    if let outWHF {
        for (i, c) in flagged.prefix(Int(max(0, cap))).enumerated() {
            outWHF[3 * i] = c.dims.width
            outWHF[3 * i + 1] = c.dims.height
            outWHF[3 * i + 2] = c.flags
        }
    }
    return Int32(flagged.count)
}

/// [ENTRY-ANY-4X3 2026-09-25] 预设下一次 start() 的照片最大尺寸(Dart 按共享规则选定)。
/// 0x0 = 清除请求(旧行为)。相机已在跑时返回 -11 且不改(改 maxPhotoDimensions 会触发
/// 采集管线重配,AVCapturePhotoOutput.h:544 建议在 startRunning 之前设)。
@_cdecl("pw_camera_slot_request_photo_dims")
public func pw_camera_slot_request_photo_dims(_ width: Int32, _ height: Int32) -> Int32 {
    return PwCameraSlotImpl.shared.requestPhotoDims(width: width, height: height)
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

/// [pw 2026-09-19] 曝光实测出口 —— 回答"为什么比系统相机暗",**只读,不改设置**。
///
/// 写入 8 个 double,顺序固定:
///   0 exposureDuration 秒(实际曝光时间;暗光下它会顶到帧间隔上限)
///   1 ISO(感光度;顶满说明已经在用最大增益)
///   2 lensAperture(光圈,iPhone 固定)
///   3 exposureMode(0=locked 1=autoExpose 2=continuousAuto 3=custom)
///   4 exposureTargetOffset EV(测光认为**还差几档**才够亮;负=欠曝)
///   5 pickedFormatIsBinned(1=选了 binned 格式,进光更多)
///   6 activeVideoMinFrameDuration 秒(**曝光时间的硬上限**)
///   7 activeVideoMaxFrameDuration 秒
/// 返回 0 成功,-1 表示还没开始采集。
@_cdecl("pw_camera_slot_exposure")
public func pw_camera_slot_exposure(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    for i in 0..<8 { out[i] = 0 }   // 无条件先清零
    guard let d = PwCameraSlotImpl.shared.device else { return -1 }
    out[0] = CMTimeGetSeconds(d.exposureDuration)
    out[1] = Double(d.iso)
    out[2] = Double(d.lensAperture)
    out[3] = Double(d.exposureMode.rawValue)
    out[4] = Double(d.exposureTargetOffset)
    out[5] = PwCameraSlotImpl.shared.pickedFormatIsBinned ? 1 : 0
    out[6] = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
    out[7] = CMTimeGetSeconds(d.activeVideoMaxFrameDuration)
    return 0
}

// ── 把帧交给 XRSLAM 用:锁定 + 交出基址 ────────────────────────────────────
//
// 🔴 这里**只做 Swift 才能做的那件事** —— 锁住 CVPixelBuffer 并交出基址。
// 填 `XRSLAMImage` 与 `XRSLAMPushSensorData` 都留在 Dart(绑定本来就在那儿),
// 这样 Swift 侧不需要 XRSLAM.h,也就不用改 pbxproj / 桥接头。
//
// 🔴 **不做灰度转换。** 引擎自己就接 4 通道:
//   `XRSLAMManager.cpp:499` → `image->channel == 4` → `CV_8UC4`,
//   转灰度是它内部用**自己那份 OpenCV 4.0.1** 做的。
//   我们在外面再转一次,只会引入一份"与它不逐位一致"的实现 —— 这个代码库
//   为 1 ULP 的像素差栽过(pip cv2 的 -ffp-contract=on vs 设备端 off)。
//   我们的 slot 固定 32BGRA,与上游 demo 喂的 `CV_8UC4` 同型,直接推即可。
//
// 用法(必须成对):
//   let n = pw_camera_slot_lock(addr, &out)   // out: [base, stride, w, h]
//   … Dart 填 XRSLAMImage 并 PushSensorData + RunOneFrame …
//   pw_camera_slot_unlock(addr)
//
// ⚠️ 锁期间**不要**做耗时的事:CVPixelBuffer 被锁住时相机线程拿不到它。

/// 锁定并写出 5 个 UInt64:baseAddress、bytesPerRow、width、height、
/// **采集时刻(纳秒,host time clock)**。
///
/// 🔴 第 5 个是 2026-09-19 加的,不是可选项:XRSLAM 的 `PushImage` 有一道
/// `gate_monotonic_locked`,时间戳**不严格递增就整帧丢弃**。用"取帧那一刻"
/// 的挂钟会让大量帧被拒 —— 必须用这一帧自己的 presentationTimeStamp。
///
/// 返回 0 成功;-1 = 地址为 0 或锁失败。
@_cdecl("pw_camera_slot_lock")
public func pw_camera_slot_lock(_ addr: UInt64,
                                _ out: UnsafeMutablePointer<UInt64>) -> Int32 {
    for i in 0..<5 { out[i] = 0 }   // 无条件先清零
    guard addr != 0 else { return -1 }
    let pb = Unmanaged<CVPixelBuffer>.fromOpaque(
        UnsafeRawPointer(bitPattern: UInt(addr))!).takeUnretainedValue()
    guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else {
        return -1
    }
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        return -1
    }
    out[0] = UInt64(UInt(bitPattern: base))
    out[1] = UInt64(CVPixelBufferGetBytesPerRow(pb))
    out[2] = UInt64(CVPixelBufferGetWidth(pb))
    out[3] = UInt64(CVPixelBufferGetHeight(pb))
    let pts = PwCameraSlotImpl.shared.latestFramePTSSeconds
    out[4] = pts.isFinite && pts > 0
        ? UInt64((pts * 1_000_000_000.0).rounded(.toNearestOrAwayFromZero))
        : 0
    return 0
}

/// 与 `pw_camera_slot_lock` 成对。**漏调会把相机卡死**。
@_cdecl("pw_camera_slot_unlock")
public func pw_camera_slot_unlock(_ addr: UInt64) {
    guard addr != 0 else { return }
    let pb = Unmanaged<CVPixelBuffer>.fromOpaque(
        UnsafeRawPointer(bitPattern: UInt(addr))!).takeUnretainedValue()
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
}

// ════════════════════════════════════════════════════════════════════════
// MARK: - 高清拍照(零 ARKit 路径)
// ════════════════════════════════════════════════════════════════════════
//
// ══ 为什么这块必须存在 ═══════════════════════════════════════════════════
// 生产拍摄页现在由 ARKit 拥有相机:同一个 ARSession 既供预览又出高清照片
// (`OfficialAetherARKitPlugin.swift` 的 `captureHighResolutionFrame`)。
// 而 **iOS 一次只把后置相机给一个会话** —— 想让拍摄流程在完全不启动 ARKit
// 的情况下跑,照片就必须由我们自己这个 `AVCaptureSession` 拍。
//
// ══ 抄的是哪一份 ═════════════════════════════════════════════════════════
// Apple 官方样例 **AVCam: Building a Camera App**
//   文档页:https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app
//   本轮实际对照的源码:AVCam/Swift/AVCam/PhotoCaptureDelegate.swift 与
//   AVCam/Swift/AVCam/CameraViewController.swift(样例包内文件名)。
// 逐条抄了:
//   · `CameraViewController.configureSession()` 里 "// Add photo output." 一段
//     —— `session.canAddOutput(photoOutput)` → `session.addOutput(photoOutput)`
//     → 置高清开关。见上面 start() 里同名注释处。
//   · `CameraViewController.capturePhoto(_:)` 的 settings 构造:
//       `var photoSettings = AVCapturePhotoSettings()`
//       `if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {`
//       `    photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) }`
//     以及 "Use a separate object for the photo capture delegate to isolate
//     each capture life cycle." + 用
//     `inProgressPhotoCaptureDelegates[settings.uniqueID]` 持强引用
//     (样例注释原文:"The Photo Output keeps a weak reference to the photo
//      capture delegate so we store it in an array to maintain a strong
//      reference to this object until the capture is completed.")。
//   · `PhotoCaptureProcessor` 这个类本身:`init(with requestedPhotoSettings:…)`、
//     `didFinish()`、以及四个 delegate 回调
//       `photoOutput(_:willBeginCaptureFor:)`
//       `photoOutput(_:willCapturePhotoFor:)`
//       `photoOutput(_:didFinishProcessingPhoto:error:)`  ← `photoData = photo.fileDataRepresentation()`
//       `photoOutput(_:didFinishCaptureFor:error:)`       ← 错误检查 → `guard let photoData` → 落盘 → `didFinish()`
//
// ══ 三处**刻意的偏离**(不是抄漏,是这条管线要的不一样)═══════════════════
//  (a) 落盘位置:AVCam 在 `didFinishCaptureFor` 里走 `PHPhotoLibrary` +
//      `PHAssetCreationRequest` 存进**用户相册**。我们改成写 app 沙盒
//      `Documents/pw_photos/`。理由:重建管线读的是沙盒里的照片 + sidecar,
//      而且我们没有、也不该要相册写权限。
//  (b) `flashMode`:AVCam 是 `.auto`。我们**钉死 `.off`**。生产的 ARKit 路径
//      根本不会打闪光(ARKit 不给 API),一张打了闪的照片与同批未打闪的照片
//      在光度上不是一套数据;而且闪光会改变曝光时长,`exposure_s` 就不再能
//      与视频流的曝光中点对齐。
//  (c) Live Photo / 深度 / previewPhotoFormat:AVCam 全都接。我们全不接。
//      Live Photo 会多拍一段视频(抢带宽、抢 ISP);深度要虚拟多摄;缩略图
//      我们不用。少接一项就少一处能改变 resolvedSettings 的变量。
//
// ══ 🔴 内参:照片自己的标定数据**拿不到**,这是 Apple 的硬约束 ═══════════
// `AVCapturePhotoOutput.h:1496` 原文:"you may only set this property to YES
// if your AVCapturePhotoOutput's cameraCalibrationDataDeliverySupported
// property is YES **and 2 or more devices are selected for virtual device
// constituent photo delivery**."
// 我们是单摄(`.builtInWideAngleCamera`)⇒ 这条路在本配置下永远关着。
// 所以内参走**第二条**:拿同一会话视频连接上的
// `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`(它只在
// AVCaptureVideoDataOutput 的 connection 上可用,见 AVCaptureSession.h:1282),
// 按分辨率比例缩到照片尺寸。
// **两条路都在代码里,sidecar 里写明这张照片走的是哪一条**(`intrinsics_provenance`)
// —— 不猜、不假装。
//
// ══ 🔴 分辨率铁律:照片不许降视频流 ═══════════════════════════════════════
// 视频流 ≥1920×1440 喂 VIO,是不能动的。所以:
//   · 照片输出在 `beginConfiguration` 块里加,而 `device.activeFormat = f`
//     在那之后才写 ⇒ **我们是最后一个写 activeFormat 的人**;
//   · `maxPhotoDimensions` 只在 `activeFormat.supportedMaxPhotoDimensions`
//     里挑最大的,**绝不为了照片去换 activeFormat**;
//   · 运行期自证:`configuredVideoProof`(startRunning 之前)与拍照完成时
//     再取一次的快照逐项比,连同两次之间视频流交付的帧数一起写进 sidecar 的
//     `video_stream_unchanged`。降档了就会在那里显形。

/// 一次拍照的结果。与 `pw_camera_slot_photo_result` 的 9 个 double 一一对应。
fileprivate struct PwPhotoResult {
    let requestId: Int64
    let path: String
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let width: Double
    let height: Double
    /// 拍照时刻,秒,**host clock,与视频流 PTS 同域**。
    /// `AVCapturePhotoOutput.h:1990` 原文:"The time at which this image was
    /// captured, synchronized to the synchronizationClock of the
    /// AVCaptureSession … analogous to CMSampleBufferGetPresentationTimeStamp()."
    let tSeconds: Double
    let exposureSeconds: Double
}

// MARK: 视频档快照(自证用)

extension PwCameraSlotImpl {
    /// 把"视频流现在是什么档"原样拍成一个可 JSON 化的字典。
    /// 只读,不改任何设置。
    /// start() 选 activeFormat 的规则(原样抽出,供 [pw_camera_slot_photo_size_candidates]
    /// 复用 —— 查询与启动必须落在同一个格式上):宽高相等、420f 全幅,优先非 binned。
    fileprivate static func pickVideoFormat(
        device: AVCaptureDevice, width: Int32, height: Int32
    ) -> AVCaptureDevice.Format? {
        let cands = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return d.width == width && d.height == height
                && sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        return cands.first(where: { !$0.isVideoBinned }) ?? cands.first
    }

    /// [ANY43-DEFAULT 2026-09-25] 本格式的照片候选及标志(见 pw_camera_slot_photo_size_candidates)。
    @available(iOS 16.0, *)
    fileprivate static func photoSizeCandidateFlags(
        _ f: AVCaptureDevice.Format
    ) -> [(dims: CMVideoDimensions, flags: Int32)] {
        let dims = f.supportedMaxPhotoDimensions
        let legacy = legacyHighResStill(f)
        let smallest = dims.min { Int64($0.width) * Int64($0.height)
            < Int64($1.width) * Int64($1.height) }
        return dims.map { d in
            var flags: Int32 = 0
            let isSmallest = smallest.map { $0.width == d.width && $0.height == d.height } ?? false
            if legacy.width > 0 && legacy.height > 0 {
                if d.width > legacy.width || d.height > legacy.height { flags |= 1 }
            } else if !isSmallest {
                flags |= 1
            }
            if isSmallest { flags |= 2 }
            return (d, flags)
        }
    }

    /// iOS 16 之前的「高分辨率静照」尺寸(已弃用、仍可读)。只在这一处读,作为「不需要 iOS 16 新接口
    /// 主动请求的最大档」的官方来源。
    @available(iOS, deprecated: 16.0)
    fileprivate static func legacyHighResStill(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
        return f.highResolutionStillImageDimensions
    }

    fileprivate static func videoProofDict(
        device: AVCaptureDevice,
        videoOutput: AVCaptureVideoDataOutput,
        photoOutput: AVCapturePhotoOutput?
    ) -> [String: Any] {
        let f = device.activeFormat
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        var dict: [String: Any] = [
            "active_format_w": Int(d.width),
            "active_format_h": Int(d.height),
            "active_format_subtype": Int(sub),
            "active_format_binned": f.isVideoBinned,
            // 🔴 必须过一道有限性闸:CMTimeGetSeconds 对 invalid/indefinite
            //    的 CMTime 会给出 NaN,而 NaN 进 JSONSerialization 会让整张
            //    sidecar 写不出去 —— 那会把一张本来好的照片连坐删掉。
            "min_frame_duration_s": Self.finite(
                CMTimeGetSeconds(device.activeVideoMinFrameDuration)),
            "max_frame_duration_s": Self.finite(
                CMTimeGetSeconds(device.activeVideoMaxFrameDuration)),
        ]
        if let vs = videoOutput.videoSettings,
           let w = vs[kCVPixelBufferWidthKey as String] as? Int,
           let h = vs[kCVPixelBufferHeightKey as String] as? Int {
            dict["video_settings_w"] = w
            dict["video_settings_h"] = h
        }
        if let conn = videoOutput.connection(with: .video) {
            dict["intrinsic_delivery_enabled"] = conn.isCameraIntrinsicMatrixDeliveryEnabled
            dict["active_stabilization_mode"] = conn.activeVideoStabilizationMode.rawValue
        }
        if let p = photoOutput, #available(iOS 16.0, *) {
            dict["photo_max_w"] = Int(p.maxPhotoDimensions.width)
            dict["photo_max_h"] = Int(p.maxPhotoDimensions.height)
            // [ENTRY-ANY-4X3 / ANY43-DEFAULT 2026-09-25] 本格式的全部候选与标志(optin = 需主动请求的
            // 高分辨率档,Dart 不选;default = Apple 字面默认),供事后核对「选的是默认模式下的最大 4:3」。
            dict["photo_supported_dims"] = Self.photoSizeCandidateFlags(f).map {
                "\($0.dims.width)x\($0.dims.height)"
                    + ($0.flags & 1 != 0 ? ":optin" : "")
                    + ($0.flags & 2 != 0 ? ":default" : "")
            }
            let legacy = Self.legacyHighResStill(f)
            dict["photo_legacy_high_res_still"] = "\(legacy.width)x\(legacy.height)"
        }
        return dict
    }

    /// 非有限值一律记 0 —— JSON 里出现 NaN 会让整条 sidecar 作废。
    fileprivate static func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// 取当前视频档快照。会话没起来时返回空字典。
    fileprivate func currentVideoProof() -> [String: Any] {
        lock.lock()
        let s = session
        lock.unlock()
        guard let dev = device, let sess = s else { return [:] }
        guard let vout = sess.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first
        else { return [:] }
        return Self.videoProofDict(
            device: dev, videoOutput: vout, photoOutput: photoOutput)
    }
}

// MARK: 拍照受理 / 结果轮询

extension PwCameraSlotImpl {
    /// 触发一次高清拍照。同步只做校验与受理,拍照本身是异步的。
    fileprivate func capturePhoto(requestId: Int64) -> Int32 {
        lock.lock()
        let running = session != nil
        lock.unlock()
        guard running else { return -1 }
        guard let out = photoOutput else { return -2 }

        photoLock.lock()
        if inFlightPhotos[requestId] != nil {
            photoLock.unlock()
            return -3
        }
        photoLock.unlock()

        guard let dir = Self.photosDirectory() else { return -4 }

        // ── settings 构造:抄 AVCam `capturePhoto(_:)`,**编码改成 JPEG**。
        // 偏离 (c) [pw 2026-09-22]:AVCam 在支持 HEVC 的机型上选 `.hevc`
        // (写出 .heic)。我们的成片契约是 JPEG:`CaptureSession` 的 sidecar 提升
        // 路径(`vio_ar_pose_provider.dart` `saveCurrentFrame`)收到非 JPEG 会
        // 如实报 `native_format_not_jpeg` 并把文件留在原地 —— 在 14 Pro 上
        // 那就是每一张。ARKit 臂写的也是 JPEG。所以这里只在
        // `availablePhotoCodecTypes` 含 `.jpeg` 时显式要 JPEG(AVCam 同一句式,
        // 只换了 codec),否则退回默认设置并由 `ext` 那行如实按
        // processedFileType 命名,不改名伪装。
        var photoSettings = AVCapturePhotoSettings()
        if out.availablePhotoCodecTypes.contains(.jpeg) {
            photoSettings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        // 偏离 (b):AVCam 是 `.auto`。见文件上方说明。
        photoSettings.flashMode = .off
        // 与 output 的 maxPhotoQualityPrioritization 同档 —— 不开 OIS、不做多帧融合。
        photoSettings.photoQualityPrioritization = .speed
        if #available(iOS 16.0, *) {
            // 逐张也要写一遍:AVCapturePhotoOutput.h:1454 —— settings 的
            // maxPhotoDimensions "defaults to the smallest dimensions returned
            // by AVCaptureDeviceFormat.supportedMaxPhotoDimensions"。
            // **默认是最小的那个**,不写这一行就等于主动要了最低分辨率。
            photoSettings.maxPhotoDimensions = out.maxPhotoDimensions
        } else {
            photoSettings.isHighResolutionPhotoEnabled = true
        }

        let ext = photoSettings.processedFileType == .jpg ? "jpg" : "heic"
        let url = dir.appendingPathComponent("\(requestId).\(ext)")

        let beforeProof = configuredVideoProof
        lock.lock(); let offeredBefore = offered; lock.unlock()

        // 抄 AVCam:"Use a separate object for the photo capture delegate to
        // isolate each capture life cycle."
        let processor = PwPhotoCaptureProcessor(
            with: photoSettings,
            requestId: requestId,
            outputURL: url,
            beforeProof: beforeProof,
            offeredBefore: offeredBefore
        ) { [weak self] proc, result in
            guard let self else { return }
            // 抄 AVCam 的 completionHandler:结果收走之后立刻把 delegate 放掉。
            self.photoLock.lock()
            self.inFlightPhotos[proc.requestId] = nil
            if let r = result {
                self.completedPhotos.append(r)
                while self.completedPhotos.count > Self.kCompletedPhotoCap {
                    self.completedPhotos.removeFirst()
                    self.photoDropped &+= 1
                }
            }
            let dropped = self.photoDropped
            self.photoLock.unlock()
            if result == nil {
                NSLog("[PwCameraSlot] photo \(proc.requestId) failed")
            } else if dropped > 0 {
                NSLog("[PwCameraSlot] photo results dropped: \(dropped) "
                    + "(消费方轮询太慢,FIFO 上限 \(Self.kCompletedPhotoCap))")
            }
        }

        // 🔴 **先持强引用再发起**。AVCam 原文:"The Photo Output keeps a weak
        //    reference to the photo capture delegate so we store it in an array
        //    to maintain a strong reference to this object until the capture is
        //    completed." 顺序反了 = delegate 可能在回调前就被释放。
        photoLock.lock()
        inFlightPhotos[requestId] = processor
        photoLock.unlock()

        photoQueue.async { [weak self] in
            guard let self else { return }
            processor.attach(slot: self)
            out.capturePhoto(with: photoSettings, delegate: processor)
        }
        return 0
    }

    /// 取走**最早一个**已完成的结果。0 = 有结果(已消费),-1 = 还没有,
    /// -2 = 路径放不下(结果**不消费**,加大 cap 再来)。
    fileprivate func photoResult(
        into outPath: UnsafeMutablePointer<CChar>, cap: Int32,
        nums: UnsafeMutablePointer<Double>
    ) -> Int32 {
        guard cap > 0 else { return -2 }
        photoLock.lock()
        guard let r = completedPhotos.first else {
            photoLock.unlock()
            return -1
        }
        let bytes = Array(r.path.utf8)
        guard bytes.count + 1 <= Int(cap) else {
            photoLock.unlock()
            return -2
        }
        completedPhotos.removeFirst()
        photoLock.unlock()

        for (i, b) in bytes.enumerated() { outPath[i] = CChar(bitPattern: b) }
        outPath[bytes.count] = 0
        nums[0] = Double(r.requestId)
        nums[1] = r.fx
        nums[2] = r.fy
        nums[3] = r.cx
        nums[4] = r.cy
        nums[5] = r.width
        nums[6] = r.height
        nums[7] = r.tSeconds
        nums[8] = r.exposureSeconds
        return 0
    }

    /// 拍照时刻的视频流内参 + 它所参照的分辨率。`nil` = 还没收到过内参。
    fileprivate func videoIntrinsicsSnapshot()
        -> (fx: Double, fy: Double, cx: Double, cy: Double, w: Int, h: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard fx > 0, latestFrameWidth > 0, latestFrameHeight > 0 else { return nil }
        return (fx, fy, cx, cy, latestFrameWidth, latestFrameHeight)
    }

    fileprivate var offeredCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return offered
    }

    /// `Documents/pw_photos/`,不存在就建。建不出来返回 nil。
    fileprivate static func photosDirectory() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("pw_photos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
            } catch {
                NSLog("[PwCameraSlot] pw_photos 建不出来: \(error)")
                return nil
            }
        }
        return dir
    }
}

// MARK: - PwPhotoCaptureProcessor
//
// 抄 AVCam 的 `PhotoCaptureProcessor`(AVCam/Swift/AVCam/PhotoCaptureDelegate.swift)。
// 一次拍照一个实例;`completionHandler` 让持有者在拍完后把它放掉。

fileprivate final class PwPhotoCaptureProcessor: NSObject {
    private(set) var requestedPhotoSettings: AVCapturePhotoSettings
    let requestId: Int64

    private let outputURL: URL
    private let beforeProof: [String: Any]
    private let offeredBefore: Int64
    private let completionHandler: (PwPhotoCaptureProcessor, PwPhotoResult?) -> Void

    private weak var slot: PwCameraSlotImpl?

    // 回调之间攒下来的东西。全部只在 delegate 回调里写,在 didFinish 里读。
    private var photoData: Data?
    private var photoTimestamp: Double = 0
    private var resolvedWidth: Int = 0
    private var resolvedHeight: Int = 0
    private var exifExposureSeconds: Double = -1
    private var photoCalibration:
        (fx: Double, fy: Double, cx: Double, cy: Double, refW: Double, refH: Double)?
    private var deviceExposureSeconds: Double = -1
    private var failureNote: String?

    init(with requestedPhotoSettings: AVCapturePhotoSettings,
         requestId: Int64,
         outputURL: URL,
         beforeProof: [String: Any],
         offeredBefore: Int64,
         completionHandler: @escaping (PwPhotoCaptureProcessor, PwPhotoResult?) -> Void) {
        self.requestedPhotoSettings = requestedPhotoSettings
        self.requestId = requestId
        self.outputURL = outputURL
        self.beforeProof = beforeProof
        self.offeredBefore = offeredBefore
        self.completionHandler = completionHandler
    }

    func attach(slot: PwCameraSlotImpl) { self.slot = slot }

    /// 抄 AVCam 的 `didFinish()`:收尾 + 调 completionHandler。
    /// 我们的收尾是"落盘 + 写 sidecar",AVCam 的是"存进相册"(偏离 (a))。
    private func didFinish() {
        guard let data = photoData else {
            completionHandler(self, nil)
            return
        }

        // 真实像素尺寸从**文件头**读,不是从 resolvedSettings 抄。
        // CGImageSource 只读头不解码,代价可忽略;两者不一致时两个数都写进
        // sidecar,由人去看,而不是我们挑一个。
        var fileW = 0
        var fileH = 0
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            as? [CFString: Any] {
            fileW = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            fileH = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
        let imageW = fileW > 0 ? fileW : resolvedWidth
        let imageH = fileH > 0 ? fileH : resolvedHeight
        let dimsProvenance = fileW > 0 ? "image_file_header" : "resolved_photo_settings"

        // ── 内参 ──────────────────────────────────────────────────────────
        var fx = 0.0, fy = 0.0, cx = 0.0, cy = 0.0
        var intrinsicsProvenance = "none"
        var scaleInfo: [String: Any] = [:]
        if let c = photoCalibration, c.refW > 0, c.refH > 0, imageW > 0, imageH > 0 {
            // 第一条路:照片自己的 AVCameraCalibrationData。本配置(单摄)下
            // 按 Apple 头文件它永远拿不到 —— 留着是因为多摄/虚拟设备一旦接上
            // 它就活了,而且真活了的时候必须优先用它。
            let sx = Double(imageW) / c.refW
            let sy = Double(imageH) / c.refH
            fx = c.fx * sx; fy = c.fy * sy
            cx = c.cx * sx; cy = c.cy * sy
            intrinsicsProvenance = "photo_camera_calibration_data"
            scaleInfo = ["ref_w": c.refW, "ref_h": c.refH, "sx": sx, "sy": sy]
        } else if let v = slot?.videoIntrinsicsSnapshot(), imageW > 0, imageH > 0 {
            // 第二条路:同一会话视频连接的逐帧内参,按分辨率比例缩。
            let sx = Double(imageW) / Double(v.w)
            let sy = Double(imageH) / Double(v.h)
            fx = v.fx * sx; fy = v.fy * sy
            cx = v.cx * sx; cy = v.cy * sy
            intrinsicsProvenance = "video_connection_scaled"
            scaleInfo = [
                "video_w": v.w, "video_h": v.h, "sx": sx, "sy": sy,
                // 非等比就是宽高比不一致,缩放这件事本身就不对 —— 写出来。
                "aspect_mismatch": abs(sx - sy) > 1e-3,
            ]
        }

        // ── 曝光 ──────────────────────────────────────────────────────────
        var exposure = 0.0
        var exposureProvenance = "none"
        if exifExposureSeconds >= 0 {
            exposure = exifExposureSeconds
            exposureProvenance = "photo_exif_exposure_time"
        } else if deviceExposureSeconds >= 0 {
            exposure = deviceExposureSeconds
            exposureProvenance = "device_exposure_duration_at_completion"
        }

        // ── 落盘 ──────────────────────────────────────────────────────────
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            NSLog("[PwCameraSlot] 照片写不下去 \(outputURL.path): \(error)")
            completionHandler(self, nil)
            return
        }

        // ── sidecar。键与生产 ARKit 路径同名(`t` / `intrinsics_fxfycxcy`,
        //    见 OfficialAetherARKitPlugin.swift 的 per-photo .json schema),
        //    额外键只加不改。
        let afterProof = slot?.currentVideoProof() ?? [:]
        let offeredAfter = slot?.offeredCount ?? 0
        var sidecar: [String: Any] = [
            "version": 1,
            "source": "avfoundation_photo_output",
            "native_role": "pw_camera_slot_photo_output",
            "request_id": requestId,
            "t": photoTimestamp,
            "image_w": imageW,
            "image_h": imageH,
            "image_dims_provenance": dimsProvenance,
            "resolved_photo_w": resolvedWidth,
            "resolved_photo_h": resolvedHeight,
            "intrinsics_fxfycxcy": [fx, fy, cx, cy],
            "intrinsics_provenance": intrinsicsProvenance,
            "intrinsics_scale": scaleInfo,
            "exposure_s": exposure,
            "exposure_provenance": exposureProvenance,
            "photo_file_type": requestedPhotoSettings.processedFileType?.rawValue ?? "unknown",
            "photo_settings_unique_id": requestedPhotoSettings.uniqueID,
            "flash_mode": requestedPhotoSettings.flashMode.rawValue,
            "video_stream_unchanged": [
                "configured": beforeProof,
                "at_photo": afterProof,
                "unchanged": PwPhotoCaptureProcessor.proofsEqual(beforeProof, afterProof),
                "video_frames_offered_before": offeredBefore,
                "video_frames_offered_after": offeredAfter,
            ],
        ]
        if let note = failureNote { sidecar["capture_note"] = note }

        let sidecarURL = outputURL.deletingPathExtension()
            .appendingPathExtension("json")
        do {
            let json = try PWJSONSafety.data(withJSONObject: sidecar)
            try json.write(to: sidecarURL, options: .atomic)
        } catch {
            // sidecar 写不出去 = 这张照片没有内参,对下游等于废片。
            // 照片一并删掉,免得留下一张"看起来有、其实用不了"的文件。
            NSLog("[PwCameraSlot] sidecar 写不下去 \(sidecarURL.path): \(error)")
            try? FileManager.default.removeItem(at: outputURL)
            completionHandler(self, nil)
            return
        }

        completionHandler(self, PwPhotoResult(
            requestId: requestId,
            path: outputURL.path,
            fx: fx, fy: fy, cx: cx, cy: cy,
            width: Double(imageW), height: Double(imageH),
            tSeconds: photoTimestamp,
            exposureSeconds: exposure))
    }

    /// 只比"会改变视频流质量"的那几项,不比 photo_max_*(那本来就是照片侧的)。
    fileprivate static func proofsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let keys = ["active_format_w", "active_format_h", "active_format_subtype",
                    "active_format_binned", "min_frame_duration_s",
                    "max_frame_duration_s", "video_settings_w", "video_settings_h",
                    "intrinsic_delivery_enabled", "active_stabilization_mode"]
        if a.isEmpty || b.isEmpty { return false }
        for k in keys {
            let x = a[k], y = b[k]
            if x == nil && y == nil { continue }
            guard let xv = x as? NSObject, let yv = y as? NSObject, xv == yv else {
                return false
            }
        }
        return true
    }
}

extension PwPhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    /*
     抄 AVCam:"This extension includes all the delegate callbacks for
     AVCapturePhotoCaptureDelegate protocol"。我们只实现用得到的四个;
     Live Photo 那两个不实现,因为我们根本没开 Live Photo。
    */

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // AVCam 在这里判 Live Photo;我们在这里把**系统解析后的**照片尺寸
        // 记下来(AVCapturePhotoOutput.h:1806:"The resolved dimensions of the
        // photo buffer that will be delivered")。它是"我们要到了多大"的凭据,
        // 与最终文件头里的尺寸互为对照。
        resolvedWidth = Int(resolvedSettings.photoDimensions.width)
        resolvedHeight = Int(resolvedSettings.photoDimensions.height)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // AVCam 在这里放快门动画。我们没有 UI —— 这里只抓一次设备当前曝光,
        // 作为 EXIF 拿不到时的兜底(读法与 captureOutput 里那处同源)。
        if let d = slot?.device {
            let e = CMTimeGetSeconds(d.exposureDuration)
            deviceExposureSeconds = (e.isFinite && e >= 0) ? e : -1
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            // AVCam 原文只 print。我们把它记下来写进 sidecar。
            failureNote = "didFinishProcessingPhoto: \(error.localizedDescription)"
            NSLog("[PwCameraSlot] Error capturing photo: \(error)")
            return
        }
        photoData = photo.fileDataRepresentation()   // ← AVCam 逐字同句

        let t = CMTimeGetSeconds(photo.timestamp)
        photoTimestamp = t.isFinite ? t : 0

        // EXIF 曝光时间 = 这张照片自己的曝光,不是"回调那一刻设备的曝光"。
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String]
            as? [String: Any],
           let e = exif[kCGImagePropertyExifExposureTime as String] as? Double,
           e.isFinite, e >= 0 {
            exifExposureSeconds = e
        }

        // 单摄下按 Apple 头文件这里永远是 nil;留着是为了多摄接上时它自动生效。
        if let cal = photo.cameraCalibrationData {
            let m = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            photoCalibration = (
                fx: Double(m.columns.0.x), fy: Double(m.columns.1.y),
                cx: Double(m.columns.2.x), cy: Double(m.columns.2.y),
                refW: Double(ref.width), refH: Double(ref.height))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // 结构逐条抄 AVCam:错误 → didFinish();没数据 → didFinish();否则落盘。
        if let error = error {
            NSLog("[PwCameraSlot] Error capturing photo: \(error)")
            failureNote = (failureNote.map { $0 + " | " } ?? "")
                + "didFinishCaptureFor: \(error.localizedDescription)"
            didFinish()
            return
        }
        guard photoData != nil else {
            NSLog("[PwCameraSlot] No photo data resource")
            didFinish()
            return
        }
        didFinish()
    }
}

// ── C ABI 出口 ───────────────────────────────────────────────────────────

/// 触发一次高清拍照。**只受理,不等待** —— 结果异步进槽,用
/// `pw_camera_slot_photo_result` 轮询。
///
/// 返回 0 已受理;负数是失败码:
///   -1 相机没起来(先调 `pw_camera_slot_start`)
///   -2 这台设备/这个会话上装不了 AVCapturePhotoOutput(原因见 NSLog)
///   -3 同一个 requestId 还在飞
///   -4 沙盒 `Documents/pw_photos/` 建不出来
@_cdecl("pw_camera_slot_capture_photo")
public func pw_camera_slot_capture_photo(_ requestId: Int64) -> Int32 {
    return PwCameraSlotImpl.shared.capturePhoto(requestId: requestId)
}

/// 取走一个已完成的拍照结果。
///
/// - `outPath`:UTF-8 文件路径,写到 `cap` 字节为止(含结尾 NUL)。
/// - `outNums`:9 个 double,顺序固定
///   `[requestId, fx, fy, cx, cy, width, height, t, exposure]`。
///   `t` 是 host clock 秒,**与视频流 PTS 同域**;`exposure` 是秒。
///
/// 返回 0 = 有结果(已从队列里消费掉);-1 = 还没有;
/// -2 = `cap` 放不下这条路径(**结果不消费**,加大 cap 再来)。
///
/// 🔴 语义是 **FIFO 逐个取走**,不是"读最近一次"。连拍时先完成的先出,
/// 不会因为来不及轮询就被后一张顶掉(上限 32 张,超了丢最老的并 NSLog 计账)。
@_cdecl("pw_camera_slot_photo_result")
public func pw_camera_slot_photo_result(_ outPath: UnsafeMutablePointer<CChar>,
                                        _ cap: Int32,
                                        _ outNums: UnsafeMutablePointer<Double>) -> Int32 {
    return PwCameraSlotImpl.shared.photoResult(into: outPath, cap: cap, nums: outNums)
}
