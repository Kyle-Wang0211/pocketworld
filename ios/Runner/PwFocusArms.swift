// PwFocusArms.swift — **对焦三臂**的 iOS 宿主侧。一次拿手机把三条路同场量完。
//
// ══ 三臂是什么(判决书附录 B.3,`docs/research/autofocus_algorithm_survey_20260922.md`)══
//   A(对照)= 现状 `setFocusModeLocked(lensPosition: 0.835)`,**一个字节不改**。
//   B(最省力)= 苹果自己的 AF:`.continuousAutoFocus` +
//               `autoFocusRangeRestriction = .near` + 对焦区域框住被扫物体。
//               它是唯一吃得到主摄「100% Focus Pixels」全阵列相位硬件的一臂
//               (iOS 不暴露相位数据,B.2)。
//   C(我们的 CDAF)= `vendor/pw_af/` 的状态机驱动 `setFocusModeLocked(lensPosition:)`,
//               每步调一次,用 completionHandler 的 `CMTime` 当「镜头已到位」硬信号。
//
// 选臂:启动参数 `-PWFocusArm a|b|c`,**默认 a** ⇒ 不传参数时行为与本刀之前
// 逐字节相同。读法与 `PwZeroArkitGate.swift` 的 `pw_vio_pose_source` 同一形状
// (NSArgumentDomain 优先、再自扫 argv 作第二证据)。
//
// ══ 三臂必须可比:同一个 ROI、同一个度量函数 ═══════════════════════════════
// 任务书「最上游输入必须清晰」。所以:
//   · ROI 三臂共用同一个矩形 = `PwAfDefaultRoiC(w, h)`(上游 libcamera
//     af.cpp:313-321 的默认 AF 窗口:中 1/2 宽 × 中 1/3 高),B 臂的
//     focusRect/Point 也用**这同一个**矩形归一化后的值;
//   · 度量三臂都走 `PwAfMeasureBgra`(Tenengrad),**A/B 臂不驱动镜头但一样要
//     算度量**,否则没得比;
//   · `PwAfMeasureBgra` 与灰度路逐位相同(pw_af_c.h 头 + pw_af_c_test 钉住)。
//
// ══ 🔴 本文件不含任何对焦算法 ═════════════════════════════════════════════
// B 臂逐条按 `AVCaptureDevice.h`(本机 iPhoneOS26.2.sdk)原文,引文写在调用处;
// C 臂只调 `vendor/pw_af/pw_af_c.h`,一行算法都不在 Swift 里重写。
//
// ══ 🔴 两张验收表分开(判决书 §6.3)═══════════════════════════════════════
//   表 A「按快门瞬间对到物体」:`prepare*` 那一组 —— 每张照片一条记录。
//   表 B「视频流持续对焦」:`series` 那一条时间序列 —— 整场一条。
// manifest 里分两块记,不混。

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

// ── 臂 ───────────────────────────────────────────────────────────────────────

enum PwFocusArm: Int32 {
    case a = 0  // 对照:锁焦
    case b = 1  // 苹果 AF
    case c = 2  // 我们的 CDAF

    var label: String {
        switch self {
        case .a: return "a_locked_baseline"
        case .b: return "b_apple_af"
        case .c: return "c_pw_af_cdaf"
        }
    }

    static func parse(_ raw: String) -> PwFocusArm? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "a", "0", "locked", "baseline": return .a
        case "b", "1", "apple", "apple_af": return .b
        case "c", "2", "cdaf", "pw_af": return .c
        default: return nil
        }
    }
}

/// 臂是从哪儿来的。写进 manifest —— 「以为传了参数其实没传」是要能看出来的。
enum PwFocusArmSource: Int32 {
    case defaultArm = 0   // 没传参数 ⇒ A
    case launchArgument = 1
    case explicitApi = 2  // pw_camera_slot_focus_arm() 显式设置(单测/台架)
}

/// 快门前那一次对焦的进度。表 A 的原始记录。
enum PwFocusPrepareState: Int32 {
    case idle = 0
    case running = 1
    case doneOk = 2       // B:对焦已落定;C:状态机报 Focused
    case doneFailed = 3   // C:状态机报 Failed(它老实报失败,不硬报成功)
    case timeout = 4
    case unsupported = 5  // A 臂:本来就不动镜头 ⇒ 无事可做
    case error = 6
}

/// 逐帧一条。表 B 的原始记录。
private struct PwFocusSample {
    let t: Double              // 帧 PTS 秒(host clock,与照片 sidecar 的 t 同域)
    let lensPosition: Double   // AVCaptureDevice.lensPosition 0…1(0=最近)
    let focusMeasure: Double   // Tenengrad,ROI 内均值
    let isAdjustingFocus: Double
    let armState: Double       // A: 恒 0;B: 0/1 = 是否在调焦;C: PwAfStateC
    let meanLuma: Double
}

// ── 控制器 ───────────────────────────────────────────────────────────────────

final class PwFocusArms {
    static let shared = PwFocusArms()

    /// 启动参数里的键名。`-PWFocusArm b` 会落进 NSArgumentDomain。
    static let kLaunchArgumentKey = "PWFocusArm"

    /// 时间序列的环形上限。30 fps × 20000 ≈ 11 分钟;超了丢最老的并计账,
    /// **不静默**。Dart 侧每秒 drain 一次,正常根本顶不到。
    private static let kSeriesCap = 20000

    /// 表 A 的上限(任务书):B 臂 2 s、C 臂 3 s。
    private static let kPrepareTimeoutB: Double = 2.0
    private static let kPrepareTimeoutC: Double = 3.0

    private let lock = NSLock()

    // ── 臂 ──
    private(set) var arm: PwFocusArm = .a
    private(set) var armSource: PwFocusArmSource = .defaultArm
    private var armResolved = false

    // ── 设备与 pw_af ──
    private weak var device: AVCaptureDevice?
    private var afCtx: OpaquePointer?
    /// 三臂共用的 ROI(像素,交付缓冲的坐标系)与它的归一化形式。
    private var roi = PwAfRectC(x: 0, y: 0, width: 0, height: 0)
    private var roiNormalized = CGRect.zero
    private var roiForWidth = 0
    private var roiForHeight = 0

    // ── 只读事实(进 manifest)──
    private(set) var minimumFocusDistanceMm: Int = -1
    private var notes: [String] = []
    private var capabilities: [String: Any] = [:]

    // ── 逐帧 ──
    private var series: [PwFocusSample] = []
    private var seriesDropped: Int64 = 0
    private var framesMeasured: Int64 = 0
    private var lastMeasure: Double = 0
    private var lastLuma: Double = 0
    private var lastArmState: Double = 0
    private var lastLensPosition: Double = -1
    private var lastIsAdjusting = false

    // ── C 臂的镜头驱动 ──
    /// 已下发但 completionHandler 还没回来 ⇒ 镜头在路上,**这期间不喂状态机**
    /// (任务书:completionHandler 的 CMTime 是四端唯一的「镜头已到位」信号;
    ///  到位之后再按 pw_af 自己的 step_frames 等统计)。
    private var lensInFlight = false
    private var lensCommandedPlatform: Double = -1
    private var lensLastSyncTimeSeconds: Double = 0
    private var lensMoves: Int64 = 0
    private var lensArrivalTotalMs: Double = 0
    private var lensArrivalCount: Int64 = 0
    private var lensInFlightSince: CFTimeInterval = 0

    // ── 快门前那一次(表 A)──
    private var prepareState: PwFocusPrepareState = .idle
    private var prepareStartedAt: CFTimeInterval = 0
    private var prepareElapsedMs: Double = 0
    private var prepareSawAdjusting = false   // B 臂:见过 isAdjustingFocus=true
    private var prepareNote: String = ""
    private var prepareIndex: Int64 = 0

    private init() {}

    // ════════════════════════════════════════════════════════════════════════
    // MARK: 选臂
    // ════════════════════════════════════════════════════════════════════════

    /// 解析 `-PWFocusArm`。读法与 `PwZeroArkitGate.pw_vio_pose_source` 同形:
    /// (a) NSArgumentDomain;(b) 自扫 argv 作第二证据,只在 (a) 空时用。
    /// 解析不出来 ⇒ 留在默认 A,并把原文记进 notes(不猜、不静默)。
    private func resolveArmLocked() {
        guard !armResolved else { return }
        armResolved = true
        var raw = ""
        if let v = UserDefaults.standard.string(forKey: Self.kLaunchArgumentKey) {
            raw = v
        }
        if raw.isEmpty {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-\(Self.kLaunchArgumentKey)"),
               i + 1 < args.count {
                raw = args[i + 1]
            }
        }
        guard !raw.isEmpty else { return }
        if let parsed = PwFocusArm.parse(raw) {
            arm = parsed
            armSource = .launchArgument
        } else {
            notes.append("-\(Self.kLaunchArgumentKey) 值无法解析:「\(raw)」⇒ 留在默认 A")
        }
    }

    /// 当前臂。第一次调用时解析启动参数。
    func currentArm() -> PwFocusArm {
        lock.lock(); defer { lock.unlock() }
        resolveArmLocked()
        return arm
    }

    /// 显式设臂(台架/单测)。**只在相机没起来时生效** —— 中途换臂会让同一条
    /// 时间序列里混两种设备配置,那条序列就没法用了。
    @discardableResult
    func setArm(_ next: PwFocusArm) -> Bool {
        lock.lock(); defer { lock.unlock() }
        resolveArmLocked()
        guard device == nil else {
            notes.append("相机已起,拒绝把臂从 \(arm.label) 改成 \(next.label)")
            return false
        }
        arm = next
        armSource = .explicitApi
        return true
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: 起相机时的配置(在 PwCameraSlot.start 的 lockForConfiguration 块内调)
    // ════════════════════════════════════════════════════════════════════════

    /// 🔴 台架第一件事:读 `minimumFocusDistance`。
    /// `AVCaptureDevice.h:1291-1298` 原文:"The minimum focus distance is given
    /// in millimeters, -1 if unknown."(iOS 15+,本工程 deployment target 就是 15.0)
    /// 判决书附录 A.4:主摄在 10–15 cm 以内根本对不上焦,原生「微距」是切超广角
    /// 实现的 ⇒ **它决定 10 cm 档在主摄上能不能成立**。
    ///
    /// [device] 必须已经 `lockForConfiguration()`;本函数不自己加锁(调用方那边
    /// 已经在锁里,重复加锁会抛 NSGenericException)。
    func configureAtStart(device: AVCaptureDevice) {
        lock.lock()
        resolveArmLocked()
        let a = arm
        self.device = device
        minimumFocusDistanceMm = device.minimumFocusDistance
        var caps: [String: Any] = [
            "minimum_focus_distance_mm": device.minimumFocusDistance,
            "minimum_focus_distance_note":
                "AVCaptureDevice.h:1296 原文「given in millimeters, -1 if unknown」",
            "focus_point_of_interest_supported": device.isFocusPointOfInterestSupported,
            "auto_focus_range_restriction_supported":
                device.isAutoFocusRangeRestrictionSupported,
            "locking_focus_with_custom_lens_position_supported":
                device.isLockingFocusWithCustomLensPositionSupported,
            "supports_locked": device.isFocusModeSupported(.locked),
            "supports_auto_focus": device.isFocusModeSupported(.autoFocus),
            "supports_continuous_auto_focus":
                device.isFocusModeSupported(.continuousAutoFocus),
            "auto_focus_system": device.activeFormat.autoFocusSystem.rawValue,
            "auto_focus_system_note":
                "1 = ContrastDetection, 2 = PhaseDetection(AVCaptureDevice.h AVCaptureAutoFocusSystem)",
        ]
        if #available(iOS 26.0, *) {
            caps["focus_rect_of_interest_supported"] = device.isFocusRectOfInterestSupported
            let m = device.minFocusRectOfInterestSize
            caps["min_focus_rect_of_interest_size"] = ["w": m.width, "h": m.height]
        } else {
            caps["focus_rect_of_interest_supported"] = false
            caps["focus_rect_of_interest_note"] =
                "focusRectOfInterest 是 iOS 26.0+;本机低于 26.0 ⇒ 回落 focusPointOfInterest"
        }
        capabilities = caps
        lock.unlock()

        // pw_af context:三臂都建(A/B 只用它算度量,不驱动镜头)。
        // macro 档 = 3–15 屈光度 = 33 cm–6.7 cm,覆盖用户口径的 10–30 cm。
        ensureAfContext()

        switch a {
        case .a:
            // A 臂在这里**什么都不做** —— 锁焦那三行留在 PwCameraSlot.start 里
            // 原样不动(git diff 可核)。
            return
        case .b:
            configureAppleAf(device: device)
        case .c:
            configurePwAf(device: device)
        }
    }

    private func ensureAfContext() {
        lock.lock(); defer { lock.unlock() }
        if afCtx == nil {
            afCtx = PwAfCreate(Int32(PW_AF_RANGE_MACRO.rawValue), 0, 0)
            if afCtx == nil {
                notes.append("PwAfCreate 失败 ⇒ 本场没有焦点度量")
            }
        }
    }

    /// B 臂 —— 逐条按 `AVCaptureDevice.h`(iPhoneOS26.2.sdk)原文。
    private func configureAppleAf(device: AVCaptureDevice) {
        // (1) 近端限制。`AVCaptureDevice.h:1215` 原文:
        //     "This property only has an effect when the focusMode property is
        //      set to AVCaptureFocusModeAutoFocus or
        //      AVCaptureFocusModeContinuousAutoFocus. Note that setting
        //      autoFocusRangeRestriction alone does not initiate a focus
        //      operation. After setting autoFocusRangeRestriction, call
        //      -setFocusMode: to apply the new restriction."
        //     ⇒ 先设限制,最后统一 setFocusMode。
        //     `:1207` 原文:"The receiver's autoFocusRangeRestriction property
        //      can only be set if this property returns YES." ⇒ 先查 supported。
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
            appendNote("B:autoFocusRangeRestriction = .near")
        } else {
            appendNote("🔴 B:isAutoFocusRangeRestrictionSupported = false ⇒ 没设近端限制")
        }

        // (2) 对焦区域 = 三臂共用的那个矩形。
        applyFocusRegion(device: device)

        // (3) 最后 setFocusMode —— 上面两条原文都说「单独设它不触发对焦,
        //     设完要再 setFocusMode:」。
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
            appendNote("B:focusMode = .continuousAutoFocus")
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
            appendNote("🔴 B:不支持 .continuousAutoFocus ⇒ 退回 .autoFocus")
        } else {
            appendNote("🔴 B:.continuousAutoFocus 与 .autoFocus 都不支持")
        }
    }

    /// 把 ROI 装进设备:优先 `focusRectOfInterest`(iOS 26.0+),否则
    /// `focusPointOfInterest`。ROI 尚未确定(还没来第一帧)时用画面中心的
    /// 同比例矩形 —— 比例与 `PwAfDefaultRoi` 一样(中 1/2 宽 × 中 1/3 高),
    /// 所以两者是同一个框,不是两套。
    private func applyFocusRegion(device: AVCaptureDevice) {
        lock.lock()
        let rect = roiNormalized.isEmpty
            ? CGRect(x: 0.25, y: 1.0 / 3.0, width: 0.5, height: 1.0 / 3.0)
            : roiNormalized
        lock.unlock()

        if #available(iOS 26.0, *), device.isFocusRectOfInterestSupported {
            // `:1171` 原文:"a value of CGRectMake(0, 0, 1, 1) tells the device
            //  to use the entire field of view … Setting focusRectOfInterest
            //  throws an NSInvalidArgumentException if your provided
            //  rectangle's size is smaller than the minFocusRectOfInterestSize."
            let minSize = device.minFocusRectOfInterestSize
            if rect.width >= minSize.width && rect.height >= minSize.height {
                device.focusRectOfInterest = rect
                appendNote(String(
                    format: "focusRectOfInterest = (%.4f,%.4f,%.4f,%.4f)",
                    rect.origin.x, rect.origin.y, rect.width, rect.height))
                return
            }
            appendNote(String(
                format: "🔴 ROI 小于 minFocusRectOfInterestSize (%.4f,%.4f) ⇒ 回落 point",
                minSize.width, minSize.height))
        }

        // `:1155` 原文:"A value of (0,0) indicates that the camera should focus
        //  on the top left corner of the image, while a value of (1,1)
        //  indicates that it should focus on the bottom right. … Note that
        //  setting focusPointOfInterest alone does not initiate a focus
        //  operation. After setting focusPointOfInterest, call -setFocusMode:"
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = CGPoint(x: rect.midX, y: rect.midY)
            appendNote(String(format: "focusPointOfInterest = (%.4f,%.4f)",
                              rect.midX, rect.midY))
        } else {
            appendNote("🔴 isFocusPointOfInterestSupported = false ⇒ 全画面对焦")
        }
    }

    /// C 臂 —— 只调 pw_af,起手位取 macro 档的 focusDefault(25 cm)。
    private func configurePwAf(device: AVCaptureDevice) {
        lock.lock()
        let ctx = afCtx
        lock.unlock()
        guard let ctx = ctx else {
            appendNote("🔴 C:没有 pw_af context ⇒ 退化成不动镜头")
            return
        }
        _ = PwAfSetRange(ctx, Int32(PW_AF_RANGE_MACRO.rawValue))
        _ = PwAfSetSpeed(ctx, Int32(PW_AF_SPEED_NORMAL.rawValue))
        // af_scan.cpp:413-423 —— SetMode(Continuous) 自己就会起一次扫描,
        // 之后按场景变化重扫 ⇒ 这就是验收表 B「视频流持续对焦」那一档。
        // 表 A「快门瞬间」走 SetMode(Auto) + TriggerScan()(见 prepareBegin)。
        _ = PwAfSetMode(ctx, Int32(PW_AF_MODE_CONTINUOUS.rawValue))

        var startPos: Double = 0
        if PwAfDefaultLensPlatform(ctx, &startPos) == PW_AF_OK.rawValue {
            device.setFocusModeLocked(
                lensPosition: Float(min(max(startPos, 0), 1)),
                completionHandler: nil)
            appendNote(String(format: "C:起手 lensPosition = %.4f(macro 档 focusDefault)",
                              startPos))
        } else {
            appendNote("🔴 C:PwAfDefaultLensPlatform 失败 ⇒ 没设起手位")
        }
    }

    private func appendNote(_ s: String) {
        lock.lock(); notes.append(s); lock.unlock()
    }

    /// 相机停了。清掉设备引用与在途标记;**不清** series(Dart 还要 drain)。
    func onCameraStopped() {
        lock.lock()
        device = nil
        lensInFlight = false
        if prepareState == .running {
            prepareState = .error
            prepareNote = "相机在对焦过程中停了"
        }
        lock.unlock()
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: 逐帧(在 PwCameraSlot 的 captureOutput 里调,相机串行队列上)
    // ════════════════════════════════════════════════════════════════════════

    /// 三臂都要走这里 —— A/B 臂不驱动镜头,但**必须**记同一口径的度量,
    /// 否则三臂不可比。
    func onFrame(_ pixelBuffer: CVPixelBuffer, ptsSeconds: Double) {
        lock.lock()
        let ctx = afCtx
        let a = arm
        lock.unlock()
        guard let ctx = ctx else { return }

        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0 && height > 0 else { return }
        ensureRoi(width: width, height: height)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var measure: Double = 0
        var luma: Double = 0
        var rc = PW_AF_ERR_INVALID_ARGUMENT.rawValue
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        lock.lock()
        var r = roi
        lock.unlock()

        if format == kCVPixelFormatType_32BGRA {
            // 本通路固定 32BGRA(PwCameraSlot.swift 文件头写明理由:Filament 的
            // Metal 后端只接 32BGRA 与 420f,而只有 32BGRA 是真零拷贝)。
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                rc = PwAfMeasureBgra(
                    ctx, base.assumingMemoryBound(to: UInt8.self), width, height,
                    Int32(CVPixelBufferGetBytesPerRow(pixelBuffer)), &r,
                    Int32(PW_AF_OP_TENENGRAD.rawValue), &measure, &luma)
            }
        } else if CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                  let plane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            // 双平面 YUV:plane 0 就是 Y。本通路现在走不到,留着是因为一旦
            // videoSettings 改回 420f 这条路要立刻可用,而不是静默算错。
            rc = PwAfMeasureGray(
                ctx, plane.assumingMemoryBound(to: UInt8.self),
                Int32(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
                Int32(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
                Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)), &r,
                Int32(PW_AF_OP_TENENGRAD.rawValue), &measure, &luma)
        }
        guard rc == PW_AF_OK.rawValue else { return }

        let dev = { () -> AVCaptureDevice? in
            lock.lock(); defer { lock.unlock() }
            return device
        }()
        let lensPosition = dev.map { Double($0.lensPosition) } ?? -1
        let adjusting = dev?.isAdjustingFocus ?? false

        var armState: Double = 0
        if a == .b {
            armState = adjusting ? 1 : 0
        } else if a == .c {
            armState = driveArmC(ctx: ctx, device: dev, measure: measure, luma: luma)
        }

        lock.lock()
        framesMeasured &+= 1
        lastMeasure = measure
        lastLuma = luma
        lastArmState = armState
        lastLensPosition = lensPosition
        lastIsAdjusting = adjusting
        series.append(PwFocusSample(
            t: ptsSeconds, lensPosition: lensPosition, focusMeasure: measure,
            isAdjustingFocus: adjusting ? 1 : 0, armState: armState,
            meanLuma: luma))
        while series.count > Self.kSeriesCap {
            series.removeFirst()
            seriesDropped &+= 1
        }
        lock.unlock()
    }

    /// C 臂:喂状态机、按结果下发镜头。返回本帧的 `PwAfStateC`。
    private func driveArmC(ctx: OpaquePointer, device: AVCaptureDevice?,
                           measure: Double, luma: Double) -> Double {
        lock.lock()
        let inFlight = lensInFlight
        let idx = framesMeasured
        let heldState = lastArmState
        lock.unlock()
        // 镜头在路上 ⇒ 这一帧的像素还是旧焦位拍的,不喂状态机
        // (completionHandler 的 CMTime 是唯一可信的「已到位」信号)。
        if inFlight { return heldState }

        var out = PwAfSampleC()
        guard PwAfUpdate(ctx, UInt64(idx), measure, luma, 1, &out) == PW_AF_OK.rawValue
        else { return 0 }

        if out.scan_finished != 0 {
            lock.lock()
            if prepareState == .running {
                prepareState = out.state == PW_AF_STATE_FOCUSED.rawValue
                    ? .doneOk : .doneFailed
                prepareElapsedMs = (CACurrentMediaTime() - prepareStartedAt) * 1000.0
            }
            lock.unlock()
        }

        if out.lens_valid != 0 && out.lens_move_requested != 0, let d = device {
            applyLens(device: d, platform: out.lens_platform)
        }
        return Double(out.state)
    }

    /// 下发一步镜头。`completionHandler` 的 `CMTime` 是四端里唯一的
    /// 「镜头已到位」硬信号(`AVCaptureDevice.h:1283` 原文:"A block to be
    /// called when lensPosition has been set to the value specified and
    /// focusMode is set to AVCaptureFocusModeLocked. … The block receives a
    /// timestamp which matches that of the first buffer to which all settings
    /// have been applied.")。
    private func applyLens(device: AVCaptureDevice, platform: Double) {
        let clamped = min(max(platform, 0), 1)
        do {
            try device.lockForConfiguration()
        } catch {
            appendNote("🔴 C:lockForConfiguration 失败 \(error)")
            return
        }
        lock.lock()
        lensInFlight = true
        lensInFlightSince = CACurrentMediaTime()
        lensCommandedPlatform = clamped
        lensMoves &+= 1
        lock.unlock()
        device.setFocusModeLocked(lensPosition: Float(clamped)) { [weak self] syncTime in
            guard let self = self else { return }
            self.lock.lock()
            self.lensInFlight = false
            self.lensLastSyncTimeSeconds = CMTimeGetSeconds(syncTime).isFinite
                ? CMTimeGetSeconds(syncTime) : 0
            self.lensArrivalTotalMs +=
                (CACurrentMediaTime() - self.lensInFlightSince) * 1000.0
            self.lensArrivalCount &+= 1
            self.lock.unlock()
        }
        device.unlockForConfiguration()
    }

    /// ROI 只在分辨率变化时重算一次。三臂共用它。
    private func ensureRoi(width: Int32, height: Int32) {
        lock.lock()
        let need = roiForWidth != Int(width) || roiForHeight != Int(height)
        lock.unlock()
        guard need else { return }

        var r = PwAfRectC(x: 0, y: 0, width: 0, height: 0)
        guard PwAfDefaultRoiC(width, height, &r) == PW_AF_OK.rawValue else { return }
        let norm = CGRect(x: CGFloat(r.x) / CGFloat(width),
                          y: CGFloat(r.y) / CGFloat(height),
                          width: CGFloat(r.width) / CGFloat(width),
                          height: CGFloat(r.height) / CGFloat(height))
        lock.lock()
        roi = r
        roiNormalized = norm
        roiForWidth = Int(width)
        roiForHeight = Int(height)
        let a = arm
        let d = device
        lock.unlock()

        // B 臂:第一帧到了才知道真实分辨率 ⇒ 用真实 ROI 再装一次。
        // 🔴 `:1171` 原文:"If you change your activeFormat, the point of
        //    interest and rectangle of interest both revert to their default
        //    values." —— 所以这一次重装是必要的,不是冗余。
        guard a == .b, let dev = d else { return }
        do {
            try dev.lockForConfiguration()
        } catch {
            appendNote("🔴 B:第一帧后重装 ROI 时 lockForConfiguration 失败 \(error)")
            return
        }
        applyFocusRegion(device: dev)
        if dev.isFocusModeSupported(.continuousAutoFocus) {
            dev.focusMode = .continuousAutoFocus  // 原文:设完区域要再 setFocusMode
        }
        dev.unlockForConfiguration()
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: 快门前那一次对焦(表 A)
    // ════════════════════════════════════════════════════════════════════════

    /// 受理一次「拍之前先对焦」。**不阻塞** —— 进度由 `stateSnapshot` 轮询。
    /// A 臂返回 `.unsupported`(本来就不动镜头);B/C 各自起自己的那一套。
    @discardableResult
    func prepareBegin() -> PwFocusPrepareState {
        lock.lock()
        resolveArmLocked()
        let a = arm
        let d = device
        let ctx = afCtx
        prepareIndex &+= 1
        prepareStartedAt = CACurrentMediaTime()
        prepareElapsedMs = 0
        prepareSawAdjusting = false
        prepareNote = ""
        lock.unlock()

        switch a {
        case .a:
            lock.lock()
            prepareState = .unsupported
            prepareNote = "A 臂锁焦,快门前不动镜头(对照臂)"
            lock.unlock()
            return .unsupported

        case .b:
            guard let dev = d else { return finishPrepare(.error, "相机没起来") }
            // `AVCaptureDevice.h` `.autoFocus` 的语义:对一次然后自动转 locked。
            // 区域与近端限制在 configureAtStart / ensureRoi 里已经设好;这里
            // 只做「触发一次」那一步(原文:设完区域/限制要再 setFocusMode:)。
            do {
                try dev.lockForConfiguration()
            } catch {
                return finishPrepare(.error, "lockForConfiguration 失败 \(error)")
            }
            applyFocusRegion(device: dev)
            if dev.isFocusModeSupported(.autoFocus) {
                dev.focusMode = .autoFocus
            } else if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            } else {
                dev.unlockForConfiguration()
                return finishPrepare(.error, "不支持 .autoFocus / .continuousAutoFocus")
            }
            dev.unlockForConfiguration()
            lock.lock(); prepareState = .running; lock.unlock()
            return .running

        case .c:
            guard let ctx = ctx else { return finishPrepare(.error, "没有 pw_af context") }
            // af_scan.cpp:426 注释原话:「快门瞬间对焦」= SetMode(Auto) + TriggerScan()。
            _ = PwAfSetMode(ctx, Int32(PW_AF_MODE_AUTO.rawValue))
            _ = PwAfTriggerScan(ctx)
            lock.lock(); prepareState = .running; lock.unlock()
            return .running
        }
    }

    @discardableResult
    private func finishPrepare(_ s: PwFocusPrepareState, _ note: String)
        -> PwFocusPrepareState {
        lock.lock()
        prepareState = s
        prepareNote = note
        prepareElapsedMs = (CACurrentMediaTime() - prepareStartedAt) * 1000.0
        lock.unlock()
        return s
    }

    /// 轮询一次进度(Dart 每帧调)。B 臂在这里判 `isAdjustingFocus` 落定;
    /// C 臂的落定在 `driveArmC` 里(状态机报 scan_finished),这里只判超时。
    func preparePoll() -> PwFocusPrepareState {
        lock.lock()
        guard prepareState == .running else {
            let s = prepareState
            lock.unlock()
            return s
        }
        let a = arm
        let d = device
        let started = prepareStartedAt
        lock.unlock()

        if a == .b {
            // `AVCaptureDevice.h:1197` 原文:"Clients can observe the value of
            // this property to determine whether the camera's focus is stable."
            // 判据:见过它 true(扫描真的起来了)之后再见到 false ⇒ 落定。
            // 一直没 true 就靠超时兜底,并把「从没 true 过」记进 note。
            let adjusting = d?.isAdjustingFocus ?? false
            lock.lock()
            if adjusting { prepareSawAdjusting = true }
            let saw = prepareSawAdjusting
            lock.unlock()
            if saw && !adjusting {
                return finishPrepare(.doneOk, "isAdjustingFocus 已落定")
            }
        }

        let elapsed = CACurrentMediaTime() - started
        let cap = (a == .c) ? Self.kPrepareTimeoutC : Self.kPrepareTimeoutB
        if elapsed >= cap {
            lock.lock()
            let saw = prepareSawAdjusting
            lock.unlock()
            return finishPrepare(
                .timeout,
                a == .b
                    ? "超过 \(cap)s;isAdjustingFocus 见过 true=\(saw)"
                    : "超过 \(cap)s;pw_af 未落下 Focused/Failed")
        }
        lock.lock()
        prepareElapsedMs = elapsed * 1000.0
        lock.unlock()
        return .running
    }

    /// 拍完之后把 C 臂放回连续档(表 B 那条序列要继续)。A/B 臂无事可做,
    /// B 臂的 `.autoFocus` 由系统自己转回 locked —— 我们再显式设回连续,
    /// 否则拍一张之后 B 臂就变成「锁在那一次的结果上」,与它的定义不符。
    func prepareEnd() {
        lock.lock()
        let a = arm
        let d = device
        let ctx = afCtx
        lock.unlock()
        switch a {
        case .a:
            return
        case .b:
            guard let dev = d, dev.isFocusModeSupported(.continuousAutoFocus) else { return }
            do { try dev.lockForConfiguration() } catch { return }
            dev.focusMode = .continuousAutoFocus
            dev.unlockForConfiguration()
        case .c:
            guard let ctx = ctx else { return }
            _ = PwAfSetMode(ctx, Int32(PW_AF_MODE_CONTINUOUS.rawValue))
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: 读出
    // ════════════════════════════════════════════════════════════════════════

    /// 16 个 double,顺序见 `pw_camera_slot_focus_state` 的注释。
    func stateSnapshot(into out: UnsafeMutablePointer<Double>) {
        lock.lock()
        resolveArmLocked()
        out[0] = Double(arm.rawValue)
        out[1] = Double(armSource.rawValue)
        out[2] = lastLensPosition
        out[3] = lastMeasure
        out[4] = lastIsAdjusting ? 1 : 0
        out[5] = lastArmState
        out[6] = Double(prepareState.rawValue)
        out[7] = prepareElapsedMs
        out[8] = Double(minimumFocusDistanceMm)
        out[9] = Double(framesMeasured)
        out[10] = Double(series.count)
        out[11] = Double(seriesDropped)
        out[12] = Double(roi.x)
        out[13] = Double(roi.y)
        out[14] = Double(roi.width)
        out[15] = Double(roi.height)
        lock.unlock()
    }

    /// 取走最多 `capSamples` 条时间序列(FIFO,取走即消费)。每条 6 个 double。
    func drainSeries(into out: UnsafeMutablePointer<Double>, capSamples: Int) -> Int {
        guard capSamples > 0 else { return 0 }
        lock.lock()
        let n = min(capSamples, series.count)
        for i in 0..<n {
            let s = series[i]
            let b = i * 6
            out[b + 0] = s.t
            out[b + 1] = s.lensPosition
            out[b + 2] = s.focusMeasure
            out[b + 3] = s.isAdjustingFocus
            out[b + 4] = s.armState
            out[b + 5] = s.meanLuma
        }
        if n > 0 { series.removeFirst(n) }
        lock.unlock()
        return n
    }

    /// manifest 用的那一块:非数值的事实(能力位、注释、ROI、臂来源)。
    func reportDictionary() -> [String: Any] {
        lock.lock()
        resolveArmLocked()
        let dict: [String: Any] = [
            "schema": "pw.focus_arms/1",
            "arm": arm.rawValue,
            "arm_label": arm.label,
            "arm_source": armSource == .launchArgument
                ? "launch_argument(-\(Self.kLaunchArgumentKey))"
                : (armSource == .explicitApi ? "explicit_api" : "default_no_argument"),
            "roi_pixels": ["x": roi.x, "y": roi.y, "w": roi.width, "h": roi.height],
            "roi_normalized": [
                "x": roiNormalized.origin.x, "y": roiNormalized.origin.y,
                "w": roiNormalized.width, "h": roiNormalized.height,
            ],
            "roi_source":
                "PwAfDefaultRoiC = libcamera af.cpp:313-321 的默认 AF 窗口(中 1/2 宽 × 中 1/3 高);三臂共用",
            "focus_measure_operator": "Tenengrad(3x3 Sobel 平方模,ROI 内均值)",
            "focus_measure_path":
                "PwAfMeasureBgra(BT.601 定点灰度 → PwAfFocusMeasure),与灰度路逐位相同",
            "frames_measured": framesMeasured,
            "series_dropped": seriesDropped,
            "lens_moves": lensMoves,
            "lens_arrival_mean_ms": lensArrivalCount > 0
                ? lensArrivalTotalMs / Double(lensArrivalCount) : 0,
            "lens_arrival_samples": lensArrivalCount,
            "lens_last_commanded_position": lensCommandedPlatform,
            "lens_last_sync_time_s": lensLastSyncTimeSeconds,
            "capabilities": capabilities,
            "notes": notes,
            "prepare_last_note": prepareNote,
            "prepare_count": prepareIndex,
        ]
        lock.unlock()
        return dict
    }
}

// ══ C ABI 出口 ══════════════════════════════════════════════════════════════

/// 读/设当前臂。
/// - `arm < 0`:只读,不设。
/// - `arm ∈ {0,1,2}`:显式设置(**只在相机没起来时生效**)。
///
/// 返回当前臂(0=A 1=B 2=C);`-1` = 参数非法;`-2` = 相机已起、拒绝改。
@_cdecl("pw_camera_slot_focus_arm")
public func pw_camera_slot_focus_arm(_ arm: Int32) -> Int32 {
    if arm < 0 { return PwFocusArms.shared.currentArm().rawValue }
    guard let next = PwFocusArm(rawValue: arm) else { return -1 }
    if !PwFocusArms.shared.setArm(next) { return -2 }
    return PwFocusArms.shared.currentArm().rawValue
}

/// 写入 **16 个 double**,顺序固定:
///   0  arm(0=A 1=B 2=C)
///   1  armSource(0=默认 1=启动参数 2=API)
///   2  lensPosition(设备当前值 0…1,**0 = 最近**;-1 = 还没有设备)
///   3  focusMeasure(最近一帧,Tenengrad ROI 均值)
///   4  isAdjustingFocus(0/1)
///   5  armState(A 恒 0;B 0/1=是否在调焦;C = PwAfState 0 Idle 1 Scanning
///               2 Focused 3 Failed)
///   6  prepareState(0 idle 1 running 2 doneOk 3 doneFailed 4 timeout
///                   5 unsupported(A 臂) 6 error)
///   7  prepareElapsedMs
///   8  minimumFocusDistance 毫米(**-1 = 未知**,Apple 头文件原文)
///   9  framesMeasured
///   10 series 待取条数
///   11 series 已丢条数(环形上限撑爆才会 > 0)
///   12..15 ROI 像素 x / y / w / h
/// 返回 0。
@_cdecl("pw_camera_slot_focus_state")
public func pw_camera_slot_focus_state(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    for i in 0..<16 { out[i] = 0 }
    PwFocusArms.shared.stateSnapshot(into: out)
    return 0
}

/// 快门前对焦:`begin = 1` 受理一次;`begin = 0` 轮询一次;`begin = 2`
/// 收尾(拍完之后把臂放回常时状态)。返回 `PwFocusPrepareState` 的 rawValue。
@_cdecl("pw_camera_slot_focus_prepare")
public func pw_camera_slot_focus_prepare(_ begin: Int32) -> Int32 {
    switch begin {
    case 1: return PwFocusArms.shared.prepareBegin().rawValue
    case 2:
        PwFocusArms.shared.prepareEnd()
        return PwFocusPrepareState.idle.rawValue
    default: return PwFocusArms.shared.preparePoll().rawValue
    }
}

/// 取走时间序列。`out` 至少要有 `capSamples * 6` 个 double 的空间。
/// 每条 6 个:`[t, lensPosition, focusMeasure, isAdjustingFocus, armState, meanLuma]`。
/// 返回实际写入的**条数**(不是 double 数);0 = 暂时没有。
@_cdecl("pw_camera_slot_focus_series")
public func pw_camera_slot_focus_series(_ out: UnsafeMutablePointer<Double>,
                                        _ capSamples: Int32) -> Int32 {
    return Int32(PwFocusArms.shared.drainSeries(into: out,
                                                capSamples: Int(capSamples)))
}

/// 把 manifest 要的那一块(能力位 / 注释 / ROI / 臂来源)序列化成 JSON 写进
/// `out`。返回写入的字节数(不含结尾 NUL);`-1` = 放不下;`-2` = 序列化失败。
@_cdecl("pw_camera_slot_focus_report")
public func pw_camera_slot_focus_report(_ out: UnsafeMutablePointer<CChar>,
                                        _ cap: Int32) -> Int32 {
    guard cap > 0 else { return -1 }
    let dict = PwFocusArms.shared.reportDictionary()
    guard let data = try? PWJSONSafety.data(withJSONObject: dict) else { return -2 }
    let bytes = Array(data)
    guard bytes.count + 1 <= Int(cap) else { return -1 }
    for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
    out[bytes.count] = 0
    return Int32(bytes.count)
}
