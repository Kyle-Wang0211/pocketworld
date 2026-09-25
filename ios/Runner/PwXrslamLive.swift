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
// (d) [2026-09-22] 相机时间戳在推给传输层之前换算到**曝光中点**:
//     `t_canonical = PTS + exposureDuration/2`。上游 `Camera.swift:150-151` 把
//     `presentationTimeStamp` 原样推、19 份 iPhone yaml 里 18 份 `time_offset: 0.0`
//     —— 上游没做,我们此前忠实复刻了这个缺口。
//     依据(不是自研):
//       · Huai arXiv 2001.00470 §IV.B:iOS 帧 "timestamped at the beginning of
//         exposure";修正是 "subtracting half of the sum of [rolling shutter +
//         exposure]"。同一套硬件改曝光 td 就跟着动(Kalibr #267),斜率≈0.5
//         (MDPI Sensors 2026 26(18):5849)。
//       · 我们自己的契约 `xrslam-interface/include/XRSLAM.h` 条目 09:canonical =
//         中心行曝光中点;`XRSLAMManager.cpp:92-99` 的换算就是 `+0.5·exposure+0.5·readout`。
//     为什么不走 `timestamp_convention` 字段让库换算:**出货 vendor 头是 40 字节
//     旧 `XRSLAMImage`**(`vendor/xrslam/include/XRSLAM.h:40-47`),没有那几个字段;
//     头注释对 iOS 的建议本来就是"填 0 并自己换算到 canonical"。
//     卷帘读出时间 iOS 不公开 ⇒ 它的一半连同管线固定延迟一起进**每机常量 c**,
//     由 `PWXrslamTransportCreateWithCameraTimeOffset` 在传输层施加。
//     🔴 自证:`runOneFrame` 推完当帧立刻从 C 账本读 `PWXrslamTimestampTrace`
//     (同一条串行 worker ⇒ 一定是本帧):raw 必须 == 我们推的 canonical,
//     effective − raw 必须 == applied_offset。`timebase(into:)` 把它们报出去。
//     [bench 2026-09-25] 台架默认**重新打开** (d)(09-24 官方配置那次改成了默认原始 PTS,
//     见 `PwXrslamOfficialFeed` ③):完整规则 `t_feed = PTS + exposure/2 + c`,c ≈ readout/2
//     (+管线固定延迟),c 取每机查表(`camera_time_offset.dart`,iPhone15,2 = 3.00 ms 实测)。
//     今天的真机证据(回放 run-13f53d2f,`-PWXrslamExposureMid on -PWBenchReplayCameraTimeOffsetMs 2.65`):
//     XRSLAM/ARKit 尺度 0.963 → 1.0022、ATE 5.4 → 1.79 cm;run-fb5d3a8f 前 17.8 s 1.0089 / 0.71 cm。
//     退回原始 PTS:`-PWXrslamExposureMid off`。
//
// ⚠️ **本文件不解决"引擎在 1920×1440 上跑不到 60fps"** —— 它只保证相机不被
//    堵住、丢帧被如实计数归因。真正吃不下的帧数会出现在 `framesDropped` 上。
//    另有一笔独立的账没算:XRSLAM 的像素单位阈值(min_keypoint_distance 25px /
//    min_parallax 10px / parsac.threshold 1.0px / rpe 3.0px)全是在 640×480
//    上调的,在 1920×1440 上焦距大 3 倍,同样的像素数对应 1/3 的角度。
//    **上游没有 1920×1440 的配置档可抄**,所以这几个值我一个都没动。

import Accelerate
import AVFoundation
import CoreMedia
import CoreMotion
import Foundation

// ══ [pw 2026-09-23] 逐帧内参(per-frame K)════════════════════════════════════
// 引擎侧早已接通(fork `Kyle-Wang0211/xrslam` @ 04c0e83:`XRSLAMImage.ext_size`
// + 72 字节 `XRSLAMImageExtension`,`detail.cpp:105-110` 有当帧 K 就用当帧 K,
// 否则用 yaml 常量)。这里只做宿主那一半:把**这一帧**自己的 K 跟着这一帧
// 推进传输层(`PWXrslamTransportPushCameraAndRunRawWithIntrinsics`)。
//
// K 的来源与参照尺寸 —— 苹果官方头文件原文(iPhoneOS26.2.sdk):
//   · CMSampleBuffer.h:1849-1857 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`:
//       "Indicates the 3x3 camera intrinsic matrix applied to the current sample
//        buffer. ... fx and fy are the focal length in pixels. ... ox and oy are
//        the coordinates of the principal point. The origin is the upper left of
//        the frame."
//   · AVCaptureSession.h:1292 `cameraIntrinsicMatrixDeliveryEnabled`:
//       "the receiver's output will add the kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix
//        sample buffer attachment to all vended sample buffers."
//   · 官方在线文档(2026-09-23 核对,与上面两段头文件同义):
//       https://developer.apple.com/documentation/coremedia/kcmsamplebufferattachmentkey_cameraintrinsicmatrix
//         —— 摘要:矩阵 "to apply to the current sample buffer"
//       https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled
//         —— 开启后 AVCaptureVideoDataOutput 给它交付的每个 sample buffer 带这条附件
//   ⇒ 矩阵参照的就是**被交付的那个 sample buffer 本身**;我们推给引擎的正是
//     它的 image buffer(整帧 BGRA,不降采样)⇒ **不需要换算**,原值直推。
//   官方文档没有写「输出被 videoSettings 缩放时矩阵是否跟着缩放」这一种情况。
//   `PwCameraSlot.start` 里 videoSettings 的宽高 == activeFormat 的宽高(同一个
//   width/height 过滤出来的格式),所以两种读法在我们的路径上重合。运行期仍逐帧
//   核对三组尺寸 —— 推给引擎的像素 / sample buffer 格式描述 / activeFormat ——
//   任何一组不等就**不推逐帧 K**、退回 yaml 常量并按原因计数,不猜换算。
//   [复核修正] 前两组取自同一个 sample buffer,恒等;承重的是第四组:推送像素
//   == 引擎 yaml 的 `cam0.resolution`(引擎按它包 cv::Mat,见 `PwXrslamDeviceYaml`)。
//   「引擎收下了没有」只由构建身份判定(`PwXrslamEngineIdentity`),回读相等不算。
//
// 开关:启动参数 `-PWPerFrameIntrinsics off|on`(键名与读法抄 `PwFocusArms.swift:214-235`
// 的 `-PWFocusArm`:先读 NSArgumentDomain,再自己扫一遍 argv)。本研究分支**默认 on**;
// off = 一字不差地走旧的 `PWXrslamTransportPushCameraAndRunRaw`(A 臂)。
// 两条原生通路(本文件 = 零 ARKit ON 臂;`PwVioSlamFeeder.swift` = ARKit 影子)共用它。
enum PwPerFrameIntrinsicsSwitch {
    static let kLaunchArgumentKey = "PWPerFrameIntrinsics"

    /// 0 = 默认值(没传参数);1 = 启动参数;2 = 传了但解析不了(留在默认)。
    enum Source: Int { case defaultValue = 0, launchArgument = 1, unparseable = 2 }

    struct Resolved {
        let enabled: Bool
        let source: Source
        let raw: String
    }

    /// 进程内解析一次(Swift 的 static let 惰性且线程安全)。
    static let resolved: Resolved = {
        var raw = ""
        if let v = UserDefaults.standard.string(forKey: kLaunchArgumentKey) {
            raw = v
        }
        if raw.isEmpty {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-\(kLaunchArgumentKey)"), i + 1 < args.count {
                raw = args[i + 1]
            }
        }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return Resolved(enabled: true, source: .defaultValue, raw: raw) }
        if ["on", "1", "true", "yes"].contains(v) {
            return Resolved(enabled: true, source: .launchArgument, raw: raw)
        }
        if ["off", "0", "false", "no"].contains(v) {
            return Resolved(enabled: false, source: .launchArgument, raw: raw)
        }
        NSLog("[PwPerFrameIntrinsics] -%@ 值无法解析:「%@」⇒ 留在默认 on", kLaunchArgumentKey, raw)
        return Resolved(enabled: true, source: .unparseable, raw: raw)
    }()

    /// 传了参数但解析不了(仍按默认 on 跑)。这一条**必须进 VIO 诊断**,不能只在
    /// NSLog 里:ON 臂报告里是 source == 2(Dart 侧写成 `switch_parse_failed`),
    /// 影子快照里是 `switchParseFailed` + 原文 `switchRaw`。
    static var parseFailed: Bool { resolved.source == .unparseable }
}

/// [pw 2026-09-23 复核修正] 链进来的引擎核**认不认**逐帧 K,是**构建**的属性,
/// 不是运行期数值能证明的:传输层回读 `XRSLAM_INFO_INTRINSICS` 只有「不等 ⇒ 这一帧
/// 没被收下」这一侧是结论;相等时,不认扩展的核报的是 yaml K(上游 4beb1a9
/// XRSLAMManager.cpp:183-188),而 yaml K 可能正是从同一来源写的(例如第一帧的 K),
/// 数值相等却什么都没吃(`PwXrslamTransportCore.h` WithIntrinsics 那段注释)。
///
/// 所以「引擎收下了」只从构建身份来:Release 构建时 `ios/scripts/stamp_runtime_identity.sh`
/// 先在链接产物里核本臂指纹在场、另两条臂指纹不在场(:183-196),再把臂名写进
/// Info.plist 的 `PWXrslamEngineArm`(:208)。Debug/Profile 不盖章(:24 非 Release
/// 直接退出)⇒ 这里就是「无法核实」,不猜。
enum PwXrslamEngineIdentity {
    static let kInfoPlistKey = "PWXrslamEngineArm"
    /// [bench 2026-09-24 官方配置臂] 构建设置盖章:Info.plist 里写 `$(PW_XRSLAM_LINKED_ENGINE)`,
    /// Xcode 在**任何**配置下都展开(`PWXrslamEngineArm` 只由 Release/Profile 的盖章脚本写)。
    static let kBuildSettingPlistKey = "PWXrslamBuildEngine"
    /// 认逐帧 K 的臂:fork 04c0e83 编出的 `libxrslam_gpufenothread_pfk_6f6aa21c.a`,
    /// 以及同一血统 + 官方规则的 `libxrslam_official_rules_*.a`(feat/official-ios-rules)。
    static let kPerFrameKArm = "gpufenothread_pfk"
    static let kPerFrameKArms: Set<String> = [kPerFrameKArm, "official_rules"]

    /// Info.plist 里盖的臂名;`nil` = 没盖章。先认盖章脚本写的,再认构建设置展开的。
    static let stampedArm: String? = {
        for key in [kInfoPlistKey, kBuildSettingPlistKey] {
            if let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               !v.isEmpty, !v.hasPrefix("$(") {
                return v
            }
        }
        return nil
    }()

    /// 1 = 盖章为认逐帧 K 的臂;0 = 盖章为别的臂(核不读扩展);-1 = 没盖章,无法核实。
    static let consumesPerFrameK: Int = {
        guard let arm = stampedArm else { return -1 }
        return kPerFrameKArms.contains(arm) ? 1 : 0
    }()

    /// 页面上显示的构建戳:链的是哪条臂 / 哪个归档 / sha16(构建设置展开,Debug 也有)。
    static let buildStamp: String = {
        func v(_ k: String) -> String {
            guard let s = Bundle.main.object(forInfoDictionaryKey: k) as? String,
                  !s.isEmpty, !s.hasPrefix("$(") else { return "?" }
            return s
        }
        let arm = v("PWXrslamBuildBenchArm")
        return "engine=\(v("PWXrslamBuildEngine")) bench_arm=\(arm == "?" ? "default" : arm)"
            + " lib=\(v("PWXrslamBuildLib")) sha16=\(v("PWXrslamBuildSha16"))"
            + " threading=\(v("PWXrslamBuildThreading")) rules=\(v("PWXrslamBuildRules"))"
    }()
}

// ══ [bench 2026-09-24] 官方配置的喂料口径(台架默认)══════════════════════════════
// 官方 iOS demo:AVCapture `.vga640x480` @30 fps,`presentationTimeStamp` 原样推,yaml
// `time_offset: 0.0`。台架照这个口径喂同一个引擎(官方规则 + 线程化的那条臂):
//   ① 相机准入 30 Hz —— 形状抄生产 `PwVioSlamFeeder.enqueue(frame:)`:
//      `t − t_上一次准入 < 门限` 就不收(对原始时间戳判,在有界闸之前)。
//      门限 = 0.8/R,不是生产的 1/R:直播相机本身就定在 30 fps(上游 setFps(30)),
//      帧间隔 33.33 ms ± 抖动,1/R 会把一半「略短于 33.333 ms」的帧挡掉、实际只剩 ~20 Hz。
//      0.8/R 对 60 Hz 源(ARKit 录制)照样隔帧取(16.7 挡、33.3 收),对 30 Hz 源全收,
//      对 120 Hz 源取每 4 帧一帧。三段 ARKit 录制上与生产 1/R 规则只差 1 帧/段,
//      Mac 回放已用同一门限重跑(xrofficial 报告)。
//      启动参数 `-PWXrslamCameraHz <R>`,默认 30;0 = 不设准入(旧行为)。
//   ② 分辨率跟 device yaml 走:源帧宽高恰是 yaml `cam0.resolution` 的整数 n 倍(n>1)
//      ⇒ 先转灰度(BGRA 用与 OpenCV `COLOR_BGRA2GRAY` 逐位相同的定点系数),再
//      `PWXrslamTransportPrepareGrayBoxNxN` 做 box n×n,推 channel 1;逐帧 K 走
//      `PWXrslamTransportScaleIntrinsicsForBoxNxN`。n 由 Dart 写 yaml 决定,原生只照做。
//      相等 ⇒ 原样推(旧行为)。
//   ③ 时间戳:[bench 2026-09-25 起] **默认曝光中点**(文件头偏离 (d)),不再是官方的原始 PTS。
//      规则 `t_feed = PTS + exposure/2 + c`,c ≈ readout/2(Huai arXiv 2001.00470 §IV.B,09-22 定案):
//      帧时间戳是曝光**起点**,而画面内容对应曝光**中点**;exposure/2 在这里逐帧加,
//      c 由调用方按每机查表传进 create(`camera_time_offset.dart`,iPhone15,2 = 3.00 ms,
//      直播页 / 回放页在本开关为 on 时查表,为 off 时用官方 0)。
//      证据(真机回放 run-13f53d2f,on + c=2.65 ms):XRSLAM/ARKit 0.963 → 1.0022,ATE 5.4 → 1.79 cm;
//      run-fb5d3a8f 前 17.8 s:1.0089 / 0.71 cm。3.00 与 2.65 之差 0.35 ms 落在实测最优平台
//      (总偏移 +8…+12 ms)之内。
//      退回官方原始 PTS:启动参数 `-PWXrslamExposureMid off`(Dart 侧同时把 c 默认回 0)。
//      🔴 30 Hz 准入 ① 与台架 LiDAR 录制器(bench-only ruler)都只看**原始** PTS,不受本开关影响;
//         回放按录制帧键控也用原始 PTS 的位模式(PwBenchReplay.observe)。
enum PwXrslamOfficialFeed {
    /// 曝光中点开关的台架默认值(2026-09-25 起为 on)。
    static let kExposureMidDefault = true

    struct Resolved {
        let cameraHz: Double
        let exposureMid: Bool
        let rawHz: String
        let rawExposure: String
        /// "default"(没传参数)/ "launch_argument" / "unparseable"(传了但解析不了 ⇒ 留在默认)。
        let exposureMidSource: String
    }

    private static func launchValue(_ key: String) -> String {
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-\(key)"), i + 1 < args.count { return args[i + 1] }
        return ""
    }

    static let resolved: Resolved = {
        let rh = launchValue("PWXrslamCameraHz")
        let re = launchValue("PWXrslamExposureMid")
        var hz = 30.0
        let t = rh.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "off" { hz = 0 } else if let v = Double(t), v.isFinite, v >= 0 { hz = v }
        let e = re.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var mid = kExposureMidDefault
        var src = "default"
        if ["on", "1", "true", "yes"].contains(e) {
            mid = true; src = "launch_argument"
        } else if ["off", "0", "false", "no"].contains(e) {
            mid = false; src = "launch_argument"
        } else if !e.isEmpty {
            src = "unparseable"
            NSLog("[PwXrslamOfficialFeed] -PWXrslamExposureMid \"%@\" 解析不了 ⇒ 按默认 %@",
                  re, kExposureMidDefault ? "on" : "off")
        }
        return Resolved(cameraHz: hz, exposureMid: mid, rawHz: rh, rawExposure: re,
                        exposureMidSource: src)
    }()

    /// [bench 2026-09-24 rec30] 准入闸 ① 的**唯一**实现,`onCameraFrame` 与台架录制器
    /// (PwBenchLidarSession,🔴 bench-only ruler)都调它 ⇒ 录制时挑的 30 Hz 帧与回放时引擎收的帧
    /// 是同一条式子、同一组 Double 运算挑出来的。`ptsSeconds` 必须是回放推给引擎的那个值:
    /// `Double(t_ns) * 1e-9`(PwBenchReplay.swift 投递处),录制器按同一式子从整数纳秒换回。
    /// 返回 true = 收;调用方收下后把 `ptsSeconds` 记成新的 lastAdmitted。
    /// 幂等:一串已经过闸的时间戳(相邻 ≥ 0.8/R)再过一次闸,全收 —— 录制按 30 Hz 落盘后,
    /// 回放时的同一道闸不会再挡掉任何一帧,与从哪一帧开始喂无关。
    @inline(__always)
    static func admits(ptsSeconds: Double, lastAdmittedPts: Double, haveAdmitted: Bool,
                       cameraHz: Double) -> Bool {
        guard cameraHz > 0 else { return true }
        return !(haveAdmitted && ptsSeconds - lastAdmittedPts < 0.8 / cameraHz)
    }
}

/// [pw 2026-09-23 复核修正] 一帧「用的是哪份 K」的标签。两条原生通路共用,
/// 与 Dart `XrslamLiveIntrinsics.lastSourceLabel` 一一对应。
///   config                         没推逐帧 K ⇒ yaml 常量
///   per_frame                      推了,且构建身份 = 认逐帧 K 的臂,且回读没有反证
///   per_frame_not_consumed         推了,但回读 ≠ 推的值(核没收下),或构建身份 = 不认的臂
///   per_frame_attached_unverified  推了,回读相等,但没有构建身份可核(相等不算证据)
enum PwPerFrameIntrinsicsSource: Int {
    case none = 0, config = 1, perFrame = 2, perFrameNotConsumed = 3,
         perFrameAttachedUnverified = 4

    var label: String {
        switch self {
        case .none: return "none"
        case .config: return "config"
        case .perFrame: return "per_frame"
        case .perFrameNotConsumed: return "per_frame_not_consumed"
        case .perFrameAttachedUnverified: return "per_frame_attached_unverified"
        }
    }

    static func classify(attached: Bool, engineReportDiffers: Bool) -> PwPerFrameIntrinsicsSource {
        guard attached else { return .config }
        if engineReportDiffers { return .perFrameNotConsumed }
        switch PwXrslamEngineIdentity.consumesPerFrameK {
        case 1: return .perFrame
        case 0: return .perFrameNotConsumed
        default: return .perFrameAttachedUnverified
        }
    }
}

/// [pw 2026-09-23 复核修正] 引擎按 yaml 的 `cam0.resolution` 包 cv::Mat
/// (fork 04c0e83 `XRSLAMManager.cpp:143-144` `config_->camera_resolution()`,
/// 键名 `yaml_config.cpp:177` `cam0.resolution`)。推的缓冲不是这个尺寸时,
/// 引擎看到的不是整帧,逐帧 K 的参照就对不上 ⇒ 不推逐帧 K。
/// 读的是**引擎自己要读的那个文件**;格式是 Dart `XrslamConfigBuilder.buildDeviceConfigYaml`
/// (`lib/vio/ffi/xrslam_config.dart` 的 `  resolution: [ W, H ]`,`cam0:` 下两格缩进)写的,
/// 这条格式由 `test/vio/ffi/per_frame_intrinsics_host_contract_test.dart` 钉住。
/// 解析不出来 ⇒ `nil`(不推逐帧 K,按原因计数,不猜)。
enum PwXrslamDeviceYaml {
    static func cam0Resolution(atPath path: String) -> (width: Int, height: Int)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inCam0 = false
        var found: (Int, Int)? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if let first = line.first, first != " ", first != "#", first != "%" {
                inCam0 = (line.trimmingCharacters(in: .whitespaces) == "cam0:")
                continue
            }
            guard inCam0, line.hasPrefix("  resolution:") else { continue }
            let body = line.dropFirst("  resolution:".count)
                .trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("["), let close = body.firstIndex(of: "]") else { return nil }
            let inner = body[body.index(after: body.startIndex)..<close]
            let parts = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  w > 0, h > 0 else { return nil }
            if found != nil { return nil }  // 出现两次 ⇒ 不猜是哪一个
            found = (w, h)
        }
        guard let f = found else { return nil }
        return (width: f.0, height: f.1)
    }
}

/// 一帧自带的针孔内参 + 它所参照的尺寸(见上面那段官方原文)。
struct PwFrameIntrinsics {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    /// `CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sb))`
    /// —— 与 `PwVioCapability.swift` `fromSampleBuffer` 取参照尺寸的口径相同。
    let referenceWidth: Int
    let referenceHeight: Int
    /// 采集设备 activeFormat 的尺寸(`PwCameraSlot.start` 里选定的那个)。
    let activeFormatWidth: Int
    let activeFormatHeight: Int
}

// ══ [pw 2026-09-23] 台架回放用的三样东西 ═════════════════════════════════════
// arloopbench 的回放页(`lib/vio/render/bench_replay_page.dart` → `PwBenchReplay.swift`)
// 要把录制好的帧与 IMU 喂进**本文件这条 ON 臂通路**,而不是另写一套:
//   ① `beginReplay` —— 与 `begin` 同一个「允许推送」开关,只是不起 CoreMotion;
//   ② `pushReplayImu` —— 录制里的一行 IMU 走与 onGyro/onAccel 同一个 `enqueueImu`;
//   ③ 逐帧观察者 —— `runOneFrame` 推完一帧,把本帧已有的局部量与 C 账本交出去,
//      台架据此写 TUM / 逐帧计时 / 逐帧 K 账。
// 🔴 直播与生产路径上观察者恒为 nil(唯一例外:台架重建链页,见 frameObserver 注释):不计时、不构造下面这个结构体,
//    唯一多出来的是在**已有的**锁里多读一个指针。相机帧像素格式为 32BGRA 时
//    channel 仍是 4(见 runOneFrame),与改动前逐字相同。
/// `runOneFrame` 推完一帧后交给观察者的事实。字段全部来自本帧的局部量或 C 账本,
/// 不另算任何东西。
struct PwXrslamFrameObservation {
    let rc: Int32
    /// `XRSLAMState` 原值(rc != OK 时为 0)。
    let state: Int32
    /// 传输层交出的 CAMERA_POSE(`PwXrslamTransportCore.cpp` 读的就是它)。
    let pose: PWXrslamRawPose
    /// onCameraFrame 收到的原始时间戳与换算后的曝光中点(文件头偏离 (d))。
    let rawPts: Double
    let canonical: Double
    /// C 账本 `PWXrslamTimestampTrace`(本帧)。`traceOk == false` 时后两项无意义。
    let traceOk: Bool
    let submittedSequence: UInt64
    let effectiveTimestamp: Double
    let channel: Int32
    let pushedWidth: Int
    let pushedHeight: Int
    let stride: Int
    /// 0 = 推了逐帧 K;1..6 = 宿主没推的原因(与 runOneFrame 里 hostReason 同码)。
    let hostReason: Int
    /// `PwPerFrameIntrinsicsSource.rawValue`(rc != OK 时为 0)。
    let intrinsicsSource: Int
    /// C 账本 `PWXrslamIntrinsicsTrace`(本帧)。`intrinsicsTraceOk == false` 时无意义。
    let intrinsicsTraceOk: Bool
    let intrinsicsTrace: PWXrslamIntrinsicsTrace
    /// 传输层那**一次**调用(push → RunOneFrame → GetResult,threading OFF 时整条
    /// 流水线都同步跑在里面)的墙钟与本线程 CPU 时间,毫秒。
    /// 计时形状抄 `PwVioSlamFeeder.swift:1694-1720`(调用前后各取一次时钟)。
    let solveWallMs: Double
    let solveCpuMs: Double
    /// onCameraFrame 入队 → runOneFrame 开始,毫秒
    /// (同 `PwVioSlamFeeder.swift:1674` 的 enqueueLatency)。
    let queueWaitMs: Double
}

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

    // ── [pw 2026-09-22] 时基自证账本(见文件头偏离 (d)) ──────────────────
    /// create 时传给传输层的每机常量 c(秒)。只作对照;报出的以 C 账本为准。
    private var cameraTimeOffsetSeconds: Double = 0
    private var tbFrames: UInt64 = 0
    /// 曝光 > 0 的帧数。== tbFrames ⇒ 每帧都拿到了曝光;< ⇒ 有帧按 0 换算过。
    private var tbFramesWithExposure: UInt64 = 0
    private var tbExposureSum: Double = 0
    private var tbExposureMin: Double = .infinity
    private var tbExposureMax: Double = 0
    /// 实际加到时间戳上的 exposure/2 之和。
    private var tbHalfAppliedSum: Double = 0
    private var lastCanonicalPts: Double = 0
    /// 以下来自 C 账本 `PWXrslamTransportGetLastTimestampTrace`,不是 Swift 合成。
    private var tbTraceReads: UInt64 = 0
    private var tbLastAppliedOffset: Double = 0
    /// 引擎实际收到的时刻 − 原始 PTS(最近一帧)。应 ≈ exposure/2 + c。
    private var tbLastEffectiveMinusPts: Double = 0
    /// |C 收到的 raw − 我们推的 canonical| 峰值。**必须恒 0**。
    private var tbMaxAbsRawResidual: Double = 0
    /// |(effective − raw) − applied_offset| 峰值。**必须恒 0**。
    private var tbMaxAbsOffsetResidual: Double = 0

    // ── [pw 2026-09-23] 逐帧内参账本(见文件头「逐帧内参」段)──────────────
    /// 走过决策、推成功的相机帧数。
    private var ikFrames: UInt64 = 0
    /// 宿主侧**没推** K 的原因计数(传输层自己拒的在 C 账本里,不在这里)。
    private var ikSwitchOff: UInt64 = 0
    private var ikNoAttachment: UInt64 = 0
    private var ikReferenceMismatch: UInt64 = 0
    private var ikActiveFormatMismatch: UInt64 = 0
    /// [复核修正] 推送尺寸 ≠ 引擎 yaml 的 `cam0.resolution`;yaml 里读不出尺寸。
    private var ikConfigResolutionMismatch: UInt64 = 0
    private var ikConfigResolutionUnknown: UInt64 = 0
    /// create 时从 device yaml 读到的 `cam0.resolution`;`nil` = 读不出来。
    private var ikConfigResolution: (width: Int, height: Int)? = nil
    /// 最近一帧的来源,`PwPerFrameIntrinsicsSource.rawValue`(0 none / 1 config /
    /// 2 per_frame / 3 per_frame_not_consumed / 4 per_frame_attached_unverified)。
    private var ikLastSource: Int = 0
    private var ikFxMin: Double = .infinity
    private var ikFxMax: Double = 0
    private var ikLastPushedWidth: Int = 0
    private var ikLastPushedHeight: Int = 0
    /// 以下来自 C 账本 `PWXrslamTransportGetIntrinsicsTrace`,不在 Swift 合成。
    private var ikTrace = PWXrslamIntrinsicsTrace()
    /// trace 描述的那一帧 != 本帧(camera submitted_sequence 对不上)的次数。**应恒 0**。
    private var ikTraceSequenceMismatch: UInt64 = 0

    /// [pw 2026-09-23 台架回放] 逐帧观察者。台架回放装;[xr-recon-chain 2026-09-25] 台架重建链页
    /// (PwXrReconChain.swift)直播时也装一个,只把本帧引擎时刻与状态报给链路核心。其余直播 / 生产恒为 nil。
    private var frameObserver: ((PwXrslamFrameObservation) -> Void)?

    // ── [bench 2026-09-24] 官方喂料账本(见 `PwXrslamOfficialFeed`)───────────────
    private var feedHaveAdmitted = false
    private var feedLastAdmittedPts: Double = 0
    /// 被 30 Hz 准入挡掉的帧数(不计入 framesOffered,与 framesDropped 分开)。
    private var feedRateSampledOut: UInt64 = 0
    /// 最近一帧的源尺寸 / box 因子 / 推送尺寸;box 失败次数(失败就不推这一帧)。
    private var feedLastSourceWidth = 0
    private var feedLastSourceHeight = 0
    private var feedLastFactor = 0
    private var feedBoxFailures: UInt64 = 0
    private var feedBoxedFrames: UInt64 = 0
    /// 只在 workQueue 上碰:灰度全幅与 box 输出两块 scratch,按需扩容、会话间复用。
    private var feedGrayScratch: UnsafeMutablePointer<UInt8>? = nil
    private var feedGrayCapacity = 0
    private var feedBoxScratch: UnsafeMutablePointer<UInt8>? = nil
    private var feedBoxCapacity = 0

    // MARK: 生命周期

    /// 由 `PwCameraSlot.start()` 调用,登记相机的串行队列。
    func bindSerialQueue(_ q: DispatchQueue) {
        lock.lock(); serialQueue = q; lock.unlock()
    }

    /// 返回沿用冻结的 `XRSLAMCreate` 口径:**1 成功 / 0 失败**。
    ///
    /// [cameraTimeOffsetSeconds] = 每机常量 c(见文件头偏离 (d)),由传输层在推相机
    /// 样本前加到时间戳上(`PwXrslamTransportCore.cpp` `ValidateTimestampLocked`:
    /// `effective = raw + offset`),IMU 不动。0 = 不加。
    func create(slamConfigPath: String, deviceConfigPath: String,
                cameraTimeOffsetSeconds: Double) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if created { return 1 }
        self.cameraTimeOffsetSeconds =
            cameraTimeOffsetSeconds.isFinite ? cameraTimeOffsetSeconds : 0
        tbFrames = 0; tbFramesWithExposure = 0
        tbExposureSum = 0; tbExposureMin = .infinity; tbExposureMax = 0
        tbHalfAppliedSum = 0; lastCanonicalPts = 0
        tbTraceReads = 0; tbLastAppliedOffset = 0; tbLastEffectiveMinusPts = 0
        tbMaxAbsRawResidual = 0; tbMaxAbsOffsetResidual = 0
        ikFrames = 0; ikSwitchOff = 0; ikNoAttachment = 0
        ikReferenceMismatch = 0; ikActiveFormatMismatch = 0
        ikConfigResolutionMismatch = 0; ikConfigResolutionUnknown = 0
        ikConfigResolution = PwXrslamDeviceYaml.cam0Resolution(atPath: deviceConfigPath)
        if ikConfigResolution == nil {
            NSLog("[PwPerFrameIntrinsics] device yaml 里读不出 cam0.resolution(%@)⇒ 本场不推逐帧 K",
                  deviceConfigPath)
        }
        ikLastSource = 0; ikFxMin = .infinity; ikFxMax = 0
        ikLastPushedWidth = 0; ikLastPushedHeight = 0
        ikTrace = PWXrslamIntrinsicsTrace(); ikTraceSequenceMismatch = 0
        feedHaveAdmitted = false; feedLastAdmittedPts = 0; feedRateSampledOut = 0
        feedLastSourceWidth = 0; feedLastSourceHeight = 0; feedLastFactor = 0
        feedBoxFailures = 0; feedBoxedFrames = 0

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

        // 🔴 痕迹文件**每次会话清一次**。`gpu_image.cpp:25` 用的是 `fopen(..., "a")`
        //    —— 跨启动累积。我曾据一份**上一轮留下的**痕迹判断"GPU 前端起来了",
        //    而那一轮链的其实是 generic:整轮归因作废。
        //    清空之后,这个文件就成了"本次会话到底链没链 GPU 前端那条臂"的
        //    可靠判据:空 = 没链(generic 里根本没有 GpuImage 这个编译单元)。
        try? FileManager.default.removeItem(
            atPath: NSHomeDirectory() + "/Documents/xrslam_gpufe_init.log")

        // [pw 2026-09-22] 换成带相机时间偏移的版本 —— 同一个 C 入口,多一个 c。
        // 生产 `PwVioSlamFeeder.swift:937` 用的就是它;此前这里传的是不带 offset 的
        // `PWXrslamTransportCreate`(等价于 c=0)。
        let rc = PWXrslamTransportCreateWithCameraTimeOffset(
            slamConfigPath, deviceConfigPath, self.cameraTimeOffsetSeconds)
        if rc == 1 { created = true }
        return rc
    }

    /// [xr-recon-chain 2026-09-25] 本会话交给传输层的相机时间偏移(秒)= create 时的 c(台架重建链页里是
    /// c + Δ)。重建链按它把照片 PTS 换到引擎时域,与视频帧同一个数、同一个加法。
    var appliedCameraTimeOffsetSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return cameraTimeOffsetSeconds
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

    // MARK: [pw 2026-09-23] 台架回放入口(见 PwXrslamFrameObservation 上方那段)

    /// 与 [begin] 同一个「允许推送」开关,但**不起 CoreMotion**:IMU 由回放器经
    /// [pushReplayImu] 按录制顺序喂进来。也不要求相机串行队列已登记 —— 回放器是
    /// **单线程**按事件时间顺序入队到同一条 workQueue,文件头偏离 (a) 要的性质
    /// 「三条流共享同一个串行上下文、入队顺序 = 到达顺序」由它直接满足。
    /// 0 成功;-3 还没 create(与 [begin] 同码)。
    func beginReplay() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard created else { return -3 }
        running = true
        return 0
    }

    /// 录制里的一行 IMU = 一次陀螺推送 + 一次加速度推送,**先陀螺后加速度**
    /// (与 [begin] 里 start 的顺序、`PwVioTimebase.swift:747` 的注释、上游
    /// EuRoC reader 同时间戳的插入顺序一致)。两次推送各走一次 [enqueueImu] ——
    /// 与直播 onGyro / onAccel 同一道有界闸、同一条 worker、同两个传输层入口。
    /// 加速度**原样透传**:录制里存的已经是 m/s²,换算正是 [onAccel] 里那个
    /// `× −9.80665`(录制器 BasaltVIOBench `ARKitReferenceSession.swift:437-441`)。
    func pushReplayImu(timestamp t: Double,
                       gyro g: (Double, Double, Double),
                       accelerationMps2 a: (Double, Double, Double)) {
        lock.lock(); lastImuTs = t; lock.unlock()
        enqueueImu { _ = PWXrslamTransportPushGyroscopeRaw(t, g.0, g.1, g.2) }
        enqueueImu { _ = PWXrslamTransportPushAccelerationRaw(t, a.0, a.1, a.2) }
    }

    /// [xr-recon-chain 2026-09-25] 新 IMU 录制格式(PwBenchReplayRecording D11)的两路:陀螺 / 加计
    /// 各自一个事件、各带自己的时间戳,各走一次 [enqueueImu](与直播 [onGyro] / [onAccel] 同一道闸、
    /// 同两个传输层入口)。加计原样透传(录制里已是 m/s²)。旧格式仍走 [pushReplayImu],一字未动。
    func pushReplayGyro(timestamp t: Double, gyro g: (Double, Double, Double)) {
        lock.lock(); lastImuTs = t; lock.unlock()
        enqueueImu { _ = PWXrslamTransportPushGyroscopeRaw(t, g.0, g.1, g.2) }
    }

    func pushReplayAccel(timestamp t: Double, accelerationMps2 a: (Double, Double, Double)) {
        enqueueImu { _ = PWXrslamTransportPushAccelerationRaw(t, a.0, a.1, a.2) }
    }

    /// 回放器的背压读数:在途帧 / 在途 IMU / 已走完 runOneFrame 的帧数。
    /// 回放器在两道闸**满之前**自己等(抄 BasaltVIOBench
    /// `BenchmarkCoordinator.swift:1457-1508` waitForReplayCapacity),
    /// 所以 [framesDropped] / [imuDropped] 在 paced / max 两档应恒 0。
    func pendingWork() -> (frames: Int, imu: Int, cameraCallbacks: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (pendingFrames, pendingImu, cameraCallbacks)
    }

    /// 两道有界闸的容量(= [maxPendingFrames] / [maxPendingImu],原样交出)。
    static var replayCapacity: (frames: Int, imu: Int) {
        (maxPendingFrames, maxPendingImu)
    }

    /// 装 / 卸逐帧观察者。必须在推第一帧之前装、在 destroy 之前卸。
    func setFrameObserver(_ observer: ((PwXrslamFrameObservation) -> Void)?) {
        lock.lock(); frameObserver = observer; lock.unlock()
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
    /// [ptsSeconds] 是**原始** presentationTimeStamp(曝光起点);[exposureSeconds]
    /// 是当帧曝光时长(0 = 未知)。这里换算到曝光中点再推(文件头偏离 (d))。
    /// [intrinsics] = 这一帧 sample buffer 自带的 K(`nil` = 这一帧没有附件)。
    ///   跟着这一帧进 worker,**不**从共享状态里再读 —— 否则算的是 A 帧、用的是 B 帧的 K。
    func onCameraFrame(_ pixelBuffer: CVPixelBuffer, ptsSeconds: Double,
                       exposureSeconds: Double,
                       intrinsics: PwFrameIntrinsics? = nil) {
        // 曝光中点换算。exposure 非法/未知按 0:等价于"没换算",并计数暴露出来。
        let exposure = (exposureSeconds.isFinite && exposureSeconds >= 0)
            ? exposureSeconds : 0
        // [bench 2026-09-25] 默认曝光中点 (d):t_feed = PTS + exposure/2 + c(c 由传输层加);
        //   -PWXrslamExposureMid off 退回官方原始 PTS。准入闸与回放键控仍用原始 ptsSeconds。
        let feed = PwXrslamOfficialFeed.resolved
        let half = feed.exposureMid ? 0.5 * exposure : 0
        let canonical = ptsSeconds + half

        lock.lock()
        guard running else { lock.unlock(); return }
        // [bench 2026-09-24] 30 Hz 准入(生产 PwVioSlamFeeder 的形状,门限 0.8/R,见 PwXrslamOfficialFeed)。
        if feed.cameraHz > 0 {
            if !PwXrslamOfficialFeed.admits(ptsSeconds: ptsSeconds, lastAdmittedPts: feedLastAdmittedPts,
                                            haveAdmitted: feedHaveAdmitted, cameraHz: feed.cameraHz) {
                feedRateSampledOut &+= 1
                lock.unlock()
                return
            }
            feedHaveAdmitted = true
            feedLastAdmittedPts = ptsSeconds
        }
        framesOffered &+= 1
        lastCameraPts = ptsSeconds   // 保持原始 PTS:timing() 比的是时钟域,不是换算
        lastCanonicalPts = canonical
        tbFrames &+= 1
        if exposure > 0 {
            tbFramesWithExposure &+= 1
            tbExposureSum += exposure
            if exposure < tbExposureMin { tbExposureMin = exposure }
            if exposure > tbExposureMax { tbExposureMax = exposure }
        }
        tbHalfAppliedSum += half
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
        // [pw 2026-09-23 台架回放] 只有装了观察者才取入队时刻(直播恒 nil ⇒ 不取)。
        let observed = frameObserver != nil
        lock.unlock()
        let enqueuedAtNs: UInt64 = observed ? DispatchTime.now().uptimeNanoseconds : 0

        // `CVPixelBuffer` 是 CF 桥接类型,捕获进闭包即 retain、闭包销毁即
        // release —— 池里的这一格在 worker 用完之前不会被覆盖。
        workQueue.async { [weak self] in
            self?.runOneFrame(pixelBuffer, canonical: canonical, rawPts: ptsSeconds,
                              intrinsics: intrinsics, enqueuedAtNs: enqueuedAtNs)
        }
    }

    /// 在 worker 上跑。与上游 `trackCamera`(`XRSLAM_iOS.mm:152-188`)同形:
    /// push → RunOneFrame → GetResult 由传输层一次原子做完。
    private func runOneFrame(_ pixelBuffer: CVPixelBuffer, canonical: Double,
                             rawPts: Double, intrinsics: PwFrameIntrinsics?,
                             enqueuedAtNs: UInt64 = 0) {
        defer {
            lock.lock(); pendingFrames -= 1; lock.unlock()
        }
        let startedAtNs: UInt64 = enqueuedAtNs != 0 ? DispatchTime.now().uptimeNanoseconds : 0
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else {
            lock.lock(); cameraLockFailures &+= 1; lock.unlock()
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let isGray =
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent8

        // [bench 2026-09-24] 官方喂料 ②:源尺寸恰是 yaml cam0.resolution 的 n 倍(n>1)⇒ box n。
        lock.lock()
        let cfgRes = ikConfigResolution
        lock.unlock()
        var factor = 1
        if let c = cfgRes, c.width > 0, c.height > 0,
           sourceWidth % c.width == 0, sourceHeight % c.height == 0,
           sourceWidth / c.width == sourceHeight / c.height, sourceWidth / c.width > 1 {
            factor = sourceWidth / c.width
        }
        var base = UnsafeMutableRawPointer(srcBase)
        var stride = srcStride
        var pushedWidth = sourceWidth
        var pushedHeight = sourceHeight
        var boxed = false
        if factor > 1 {
            // 灰度源:ARKit/录制的 Y 平面原样;BGRA:与 OpenCV COLOR_BGRA2GRAY 同一组定点系数
            // (B 1868 / G 9617 / R 4899,>>14,+8192 取整),逐位等于引擎自己那次 cvtColor。
            var grayPtr: UnsafePointer<UInt8>? = nil
            var grayStride = 0
            if isGray {
                grayPtr = UnsafePointer(srcBase.assumingMemoryBound(to: UInt8.self))
                grayStride = srcStride
            } else if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
                let need = sourceWidth * sourceHeight
                if feedGrayCapacity < need {
                    feedGrayScratch?.deallocate()
                    feedGrayScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: need)
                    feedGrayCapacity = need
                }
                var src = vImage_Buffer(data: srcBase, height: vImagePixelCount(sourceHeight),
                                        width: vImagePixelCount(sourceWidth), rowBytes: srcStride)
                var dst = vImage_Buffer(data: UnsafeMutableRawPointer(feedGrayScratch), height: vImagePixelCount(sourceHeight),
                                        width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth)
                let m: [Int16] = [1868, 9617, 4899, 0]   // 内存序 B G R A
                let e = vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &src, &dst, m, 16384, nil, 8192, vImage_Flags(kvImageNoFlags))
                if e == kvImageNoError {
                    grayPtr = UnsafePointer(feedGrayScratch!)
                    grayStride = sourceWidth
                }
            }
            let outW = sourceWidth / factor, outH = sourceHeight / factor
            if feedBoxCapacity < outW * outH {
                feedBoxScratch?.deallocate()
                feedBoxScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: outW * outH)
                feedBoxCapacity = outW * outH
            }
            var w: Int32 = 0, h: Int32 = 0
            let brc: Int32 = grayPtr.map {
                PWXrslamTransportPrepareGrayBoxNxN(
                    $0, Int32(sourceWidth), Int32(sourceHeight), Int32(grayStride),
                    Int32(factor), feedBoxScratch, Int32(feedBoxCapacity), &w, &h)
            } ?? -1
            guard brc == PW_XRSLAM_OK.rawValue, Int(w) == outW, Int(h) == outH else {
                lock.lock(); feedBoxFailures &+= 1; lock.unlock()
                return
            }
            base = UnsafeMutableRawPointer(feedBoxScratch!)
            stride = outW
            pushedWidth = outW
            pushedHeight = outH
            boxed = true
        }
        lock.lock()
        feedLastSourceWidth = sourceWidth; feedLastSourceHeight = sourceHeight
        feedLastFactor = factor
        if boxed { feedBoxedFrames &+= 1 }
        lock.unlock()

        // [pw 2026-09-23] 这一帧推不推自己的 K(文件头「逐帧内参」段)。
        //   整帧直推、不降采样 ⇒ K 原值即推送像素上的 K,不做任何算术。
        //   参照尺寸对不上就退回 yaml 常量并计数 —— 不猜换算。
        //   [复核修正] 还要核「推送尺寸 == 引擎 yaml 的 cam0.resolution」:引擎按 yaml
        //   尺寸包 cv::Mat(fork XRSLAMManager.cpp:143-144),不等时它看到的不是这整帧
        //   (例如显式传了更小的 feedWidth,`zero_arkit_capture_runtime.dart` 构造参数)。
        //   上面两组尺寸都取自同一个 sample buffer,本来就相等;真正要核的是这一组。
        lock.lock()
        let configResolution = ikConfigResolution
        let observer = frameObserver   // [pw 2026-09-23 台架回放] 直播恒 nil
        lock.unlock()
        var frameK: [Double]? = nil
        // 0 推;1 开关 off;2 无附件;3 参照≠推送;4 activeFormat≠推送;
        // 5 yaml cam0.resolution≠推送;6 yaml 里读不出 cam0.resolution
        var hostReason = 0
        if !PwPerFrameIntrinsicsSwitch.resolved.enabled {
            hostReason = 1
        } else if configResolution == nil {
            hostReason = 6
        } else if let cfg = configResolution,
                  cfg.width != pushedWidth || cfg.height != pushedHeight {
            hostReason = 5
        } else if let k = intrinsics {
            // [bench 2026-09-24] 参照尺寸对的是**源帧**;box 之后 K 用传输层同一公式换算。
            if k.referenceWidth != sourceWidth || k.referenceHeight != sourceHeight {
                hostReason = 3
            } else if k.activeFormatWidth != sourceWidth
                        || k.activeFormatHeight != sourceHeight {
                hostReason = 4
            } else if factor > 1 {
                var src = [k.fx, k.fy, k.cx, k.cy]
                var dst = [Double](repeating: 0, count: 4)
                let krc = PWXrslamTransportScaleIntrinsicsForBoxNxN(&src, Int32(factor), &dst)
                if krc == PW_XRSLAM_OK.rawValue { frameK = dst } else { hostReason = 3 }
            } else {
                frameK = [k.fx, k.fy, k.cx, k.cy]
            }
        } else {
            hostReason = 2
        }

        var state: Int32 = 0
        var pose = PWXrslamRawPose()
        // channel = 4:BGRA 直推,引擎内部转灰度(见文件头偏离 (b))。
        // [pw 2026-09-23 台架回放] 通道数跟着像素格式走:台架回放推的是录制里的
        //   luma 平面(OneComponent8 ⇒ 1,与 `PwVioSlamFeeder.swift:1701` 推灰度用的
        //   同一个值;引擎 channel==1 分支原样 clone,fork XRSLAMManager.cpp:167-169)。
        //   直播相机槽恒为 32BGRA ⇒ 仍是 4,与改动前逐字相同。
        let channel: Int32 = (boxed || isGray) ? 1 : 4
        // [pw 2026-09-23 台架回放] 只有装了观察者才计时(直播恒 nil ⇒ 不取时钟)。
        let timed = observer != nil
        let wall0: UInt64 = timed ? DispatchTime.now().uptimeNanoseconds : 0
        let cpu0: UInt64 = timed ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        let rc: Int32
        if let k = frameK {
            rc = k.withUnsafeBufferPointer { kp in
                PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
                    base.assumingMemoryBound(to: UInt8.self),
                    canonical, Int32(stride), /*camera_id=*/0, channel,
                    kp.baseAddress, &state, &pose)
            }
        } else {
            rc = PWXrslamTransportPushCameraAndRunRaw(
                base.assumingMemoryBound(to: UInt8.self),
                canonical, Int32(stride), /*camera_id=*/0, channel,
                &state, &pose)
        }
        let wall1: UInt64 = timed ? DispatchTime.now().uptimeNanoseconds : 0
        let cpu1: UInt64 = timed ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0

        // [pw 2026-09-22] 时基自证(文件头偏离 (d)):刚推完就读 C 账本里相机流的
        //   最近一条 trace。workQueue 是串行的、只有这里推相机 ⇒ 读到的必是本帧。
        //   `tr.stream` 的内容校验不依赖返回码语义。
        var tr = PWXrslamTimestampTrace()
        let trc = PWXrslamTransportGetLastTimestampTrace(
            Int32(PW_XRSLAM_STREAM_CAMERA.rawValue), &tr)
        // [pw 2026-09-23] 逐帧内参的 C 账本:同一条串行 worker、只有这里推相机
        //   ⇒ 读到的是本帧;仍用 camera submitted_sequence 对一次账。
        var observedIk = PWXrslamIntrinsicsTrace()   // [台架回放] 交给观察者的本帧账
        var observedIkOk = false
        var observedSource = 0
        if rc == PW_XRSLAM_OK.rawValue {
            var ik = PWXrslamIntrinsicsTrace()
            let ikrc = PWXrslamTransportGetIntrinsicsTrace(&ik)
            if ikrc == PW_XRSLAM_OK.rawValue { observedIk = ik; observedIkOk = true }
            lock.lock()
            ikFrames &+= 1
            ikLastPushedWidth = pushedWidth
            ikLastPushedHeight = pushedHeight
            switch hostReason {
            case 1: ikSwitchOff &+= 1
            case 2: ikNoAttachment &+= 1
            case 3: ikReferenceMismatch &+= 1
            case 4: ikActiveFormatMismatch &+= 1
            case 5: ikConfigResolutionMismatch &+= 1
            case 6: ikConfigResolutionUnknown &+= 1
            default: break
            }
            if ikrc == PW_XRSLAM_OK.rawValue {
                ikTrace = ik
                if trc == PW_XRSLAM_OK.rawValue,
                   ik.camera_submitted_sequence != tr.submitted_sequence {
                    ikTraceSequenceMismatch &+= 1
                }
                // [复核修正] 回读相等**不算**「引擎吃到」;见 PwPerFrameIntrinsicsSource。
                ikLastSource = PwPerFrameIntrinsicsSource.classify(
                    attached: ik.last_per_frame_attached == 1,
                    engineReportDiffers: ik.last_engine_report_differs == 1).rawValue
                observedSource = ikLastSource
                if ik.last_per_frame_attached == 1 {
                    let fx = ik.last_attached_fxfycxcy.0
                    if fx < ikFxMin { ikFxMin = fx }
                    if fx > ikFxMax { ikFxMax = fx }
                }
            }
            lock.unlock()
        }

        if trc == PW_XRSLAM_OK.rawValue,
           tr.stream == Int32(PW_XRSLAM_STREAM_CAMERA.rawValue) {
            let rRaw = abs(tr.raw_timestamp - canonical)
            let rOff = abs((tr.effective_timestamp - tr.raw_timestamp) - tr.applied_offset)
            lock.lock()
            tbTraceReads &+= 1
            tbLastAppliedOffset = tr.applied_offset
            tbLastEffectiveMinusPts = tr.effective_timestamp - rawPts
            if rRaw > tbMaxAbsRawResidual { tbMaxAbsRawResidual = rRaw }
            if rOff > tbMaxAbsOffsetResidual { tbMaxAbsOffsetResidual = rOff }
            lock.unlock()
        }

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

        // [pw 2026-09-23 台架回放] 逐帧观察者(直播恒 nil)。在 worker 上、本帧的
        //   pendingFrames 递减之前调用 ⇒ 回放器看到「在途 = 0」时,所有帧的记录都已交出。
        if let observer {
            observer(PwXrslamFrameObservation(
                rc: rc,
                state: rc == PW_XRSLAM_OK.rawValue ? state : 0,
                pose: pose,
                rawPts: rawPts,
                canonical: canonical,
                traceOk: trc == PW_XRSLAM_OK.rawValue
                    && tr.stream == Int32(PW_XRSLAM_STREAM_CAMERA.rawValue),
                submittedSequence: tr.submitted_sequence,
                effectiveTimestamp: tr.effective_timestamp,
                channel: channel,
                pushedWidth: pushedWidth,
                pushedHeight: pushedHeight,
                stride: stride,
                hostReason: hostReason,
                intrinsicsSource: observedSource,
                intrinsicsTraceOk: observedIkOk,
                intrinsicsTrace: observedIk,
                solveWallMs: Double(wall1 &- wall0) / 1_000_000.0,
                solveCpuMs: Double(cpu1 &- cpu0) / 1_000_000.0,
                queueWaitMs: startedAtNs > enqueuedAtNs
                    ? Double(startedAtNs - enqueuedAtNs) / 1_000_000.0 : 0))
        }
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

    /// [pw 2026-09-22] 写 12 个 double —— 相机时间戳换算的运行期自证(文件头偏离 (d)):
    ///   0 c 传入值(秒)          1 c 实际施加值(C 账本 applied_offset)
    ///   2 帧数                   3 其中曝光>0 的帧数
    ///   4 曝光均值  5 曝光最小  6 曝光最大(秒;3 为 0 时 4/5 写 0)
    ///   7 平均实际加上的 exposure/2(秒)
    ///   8 |C 收到的 raw − 我们推的 canonical| 峰值   **必须 0**
    ///   9 |(effective−raw) − applied_offset| 峰值     **必须 0**
    ///  10 引擎收到的时刻 − 原始 PTS(最近一帧,秒)= exposure/2 + c
    ///  11 trace 读取次数
    /// 返回 0 = 已有 trace;-1 = 还没推过帧。
    func timebase(into out: UnsafeMutablePointer<Double>) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        out[0] = cameraTimeOffsetSeconds
        out[1] = tbLastAppliedOffset
        out[2] = Double(tbFrames)
        out[3] = Double(tbFramesWithExposure)
        out[4] = tbFramesWithExposure > 0
            ? tbExposureSum / Double(tbFramesWithExposure) : 0
        out[5] = tbFramesWithExposure > 0 ? tbExposureMin : 0
        out[6] = tbExposureMax
        out[7] = tbFrames > 0 ? tbHalfAppliedSum / Double(tbFrames) : 0
        out[8] = tbMaxAbsRawResidual
        out[9] = tbMaxAbsOffsetResidual
        out[10] = tbLastEffectiveMinusPts
        out[11] = Double(tbTraceReads)
        return tbTraceReads > 0 ? 0 : -1
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

    /// [pw 2026-09-23;复核修正后] 写 31 个 double —— 逐帧内参这一场的账:
    ///   0 开关(1 on / 0 off)
    ///   1 开关来源(0 默认 / 1 启动参数 / 2 传了但解析不了 ⇒ 按默认 on 跑)
    ///   2 走过决策并推成功的相机帧数
    ///   ── C 账本(`PWXrslamTransportGetIntrinsicsTrace`,不在 Swift 合成)──
    ///   3 带逐帧 K 推下去的帧数(= 宿主推了什么,**不是**引擎收下了什么)
    ///   4 没带逐帧 K 的帧数(= yaml 常量)   5 其中给了 K 但传输层拒收(非有限/fx,fy≤0)
    ///   6 推了、回读 ≠ 推的值的帧数 ⇒ **证明**核没收下
    ///   7 推了、回读 == 推的值的帧数 ⇒ **不是**证据(不认扩展的核报 yaml K,也可能相等)
    ///   ── 构建身份 ──
    ///   8 链的核认不认逐帧 K:1 盖章为 gpufenothread_pfk / 0 盖章为别的臂 / -1 没盖章(无法核实)
    ///   ── 宿主侧不推的原因 ──
    ///   9 开关 off  10 该帧无附件  11 参照尺寸≠推送  12 activeFormat≠推送
    ///  13 yaml cam0.resolution≠推送  14 yaml 里读不出 cam0.resolution
    ///  15 最近一帧来源 `PwPerFrameIntrinsicsSource.rawValue`
    ///  16-19 最近一次推下去的 fx fy cx cy   20-23 最近一次回读的 fx fy cx cy
    ///  24/25 推下去的 fx 最小/最大(没推过写 0)  26/27 最近一帧推送宽/高
    ///  28/29 yaml cam0.resolution 宽/高(读不出写 0)
    ///  30 trace 与本帧序号对不上的次数(**应恒 0**)
    /// 返回 0 = 已有帧;-1 = 还没推过帧。
    static let intrinsicsReportCount = 31
    func intrinsicsReport(into out: UnsafeMutablePointer<Double>) -> Int32 {
        let sw = PwPerFrameIntrinsicsSwitch.resolved
        lock.lock(); defer { lock.unlock() }
        let t = ikTrace
        out[0] = sw.enabled ? 1 : 0
        out[1] = Double(sw.source.rawValue)
        out[2] = Double(ikFrames)
        out[3] = Double(t.attached)
        out[4] = Double(t.not_attached)
        out[5] = Double(t.rejected_invalid)
        out[6] = Double(t.engine_report_differs)
        out[7] = Double(t.engine_report_equal)
        out[8] = Double(PwXrslamEngineIdentity.consumesPerFrameK)
        out[9] = Double(ikSwitchOff)
        out[10] = Double(ikNoAttachment)
        out[11] = Double(ikReferenceMismatch)
        out[12] = Double(ikActiveFormatMismatch)
        out[13] = Double(ikConfigResolutionMismatch)
        out[14] = Double(ikConfigResolutionUnknown)
        out[15] = Double(ikLastSource)
        out[16] = t.last_attached_fxfycxcy.0
        out[17] = t.last_attached_fxfycxcy.1
        out[18] = t.last_attached_fxfycxcy.2
        out[19] = t.last_attached_fxfycxcy.3
        out[20] = t.last_engine_fxfycxcy.0
        out[21] = t.last_engine_fxfycxcy.1
        out[22] = t.last_engine_fxfycxcy.2
        out[23] = t.last_engine_fxfycxcy.3
        out[24] = ikFxMin.isFinite ? ikFxMin : 0
        out[25] = ikFxMax
        out[26] = Double(ikLastPushedWidth)
        out[27] = Double(ikLastPushedHeight)
        out[28] = Double(ikConfigResolution?.width ?? 0)
        out[29] = Double(ikConfigResolution?.height ?? 0)
        out[30] = Double(ikTraceSequenceMismatch)
        return ikFrames > 0 ? 0 : -1
    }

    /// [bench 2026-09-24] 官方喂料口径与账本,给回放回执与页面构建戳。
    /// [bench 2026-09-25] 加曝光中点的来源 / 台架默认值 / 规则,以及本场 create 时传入的 c。
    func feedReport() -> [String: Any] {
        let f = PwXrslamOfficialFeed.resolved
        lock.lock(); defer { lock.unlock() }
        return [
            "camera_hz_gate": f.cameraHz,
            "camera_hz_arg": f.rawHz,
            "exposure_mid": f.exposureMid,
            "exposure_mid_arg": f.rawExposure,
            "exposure_mid_source": f.exposureMidSource,
            "exposure_mid_default": PwXrslamOfficialFeed.kExposureMidDefault,
            "exposure_mid_rule": f.exposureMid
                ? "t_feed = pts + exposure/2 + c (Huai arXiv 2001.00470 IV.B; bench default since 2026-09-25)"
                : "t_feed = pts + c (raw PTS, official iOS demo; -PWXrslamExposureMid off)",
            "camera_time_offset_s": cameraTimeOffsetSeconds,
            "mean_half_exposure_applied_s": tbFrames > 0 ? tbHalfAppliedSum / Double(tbFrames) : 0,
            "config_resolution": ikConfigResolution.map { [$0.width, $0.height] } ?? [],
            "last_source_wh": [feedLastSourceWidth, feedLastSourceHeight],
            "last_box_factor": feedLastFactor,
            "last_pushed_wh": [ikLastPushedWidth, ikLastPushedHeight],
            "boxed_frames": feedBoxedFrames,
            "box_failures": feedBoxFailures,
            "rate_sampled_out": feedRateSampledOut,
            "frames_offered": framesOffered,
            "frames_dropped": framesDropped,
            "build_stamp": PwXrslamEngineIdentity.buildStamp,
        ]
    }

    /// 一行人读的构建戳 + 当前喂料(页面显示用)。
    func buildStampLine() -> String {
        let f = PwXrslamOfficialFeed.resolved
        lock.lock()
        let res = ikConfigResolution
        let src = (feedLastSourceWidth, feedLastSourceHeight)
        let n = feedLastFactor
        let so = feedRateSampledOut
        lock.unlock()
        let feedRes = res.map { "\($0.width)x\($0.height)" } ?? "?"
        let hz = f.cameraHz > 0 ? String(format: "%.0fHz", f.cameraHz) : "no-gate"
        return PwXrslamEngineIdentity.buildStamp
            + " | feed=\(feedRes)@\(hz) src=\(src.0)x\(src.1) box=\(n)"
            + " exposure_mid=\(f.exposureMid ? "on" : "off") rate_sampled_out=\(so)"
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
    _ deviceConfigPath: UnsafePointer<CChar>,
    _ cameraTimeOffsetSeconds: Double
) -> Int32 {
    return PwXrslamLive.shared.create(
        slamConfigPath: String(cString: slamConfigPath),
        deviceConfigPath: String(cString: deviceConfigPath),
        cameraTimeOffsetSeconds: cameraTimeOffsetSeconds)
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

/// [pw 2026-09-22] 写 12 个 double,见 `PwXrslamLive.timebase`。0 有样本 / -1 还没推过帧。
@_cdecl("pw_xrslam_live_timebase")
public func pw_xrslam_live_timebase(_ out: UnsafeMutablePointer<Double>) -> Int32 {
    return PwXrslamLive.shared.timebase(into: out)
}

/// [pw 2026-09-23] 写 31 个 double,见 `PwXrslamLive.intrinsicsReport`。
/// `cap` = 调用方分配的 double 个数;不够 31 返回 -2 且不写(不截断)。
/// 0 有帧 / -1 还没推过帧。
@_cdecl("pw_xrslam_live_intrinsics")
public func pw_xrslam_live_intrinsics(
    _ out: UnsafeMutablePointer<Double>, _ cap: Int32
) -> Int32 {
    guard Int(cap) >= PwXrslamLive.intrinsicsReportCount else { return -2 }
    return PwXrslamLive.shared.intrinsicsReport(into: out)
}

/// [bench 2026-09-24] 构建戳 + 当前喂料口径(UTF-8,最多 cap 字节含结尾 0),返回写入字节数。
@_cdecl("pw_xrslam_live_build_stamp")
public func pw_xrslam_live_build_stamp(
    _ out: UnsafeMutablePointer<CChar>, _ cap: Int32
) -> Int32 {
    let bytes = Array(PwXrslamLive.shared.buildStampLine().utf8)
    let n = max(0, min(bytes.count, Int(cap) - 1))
    if n > 0 {
        bytes.withUnsafeBufferPointer { src in
            out.withMemoryRebound(to: UInt8.self, capacity: n) { dst in
                dst.update(from: src.baseAddress!, count: n)
            }
        }
    }
    if cap > 0 { out[n] = 0 }
    return Int32(n)
}

/// [bench 2026-09-25] 曝光中点开关的**解析结果**(`PwXrslamOfficialFeed.resolved`):
/// 1 = on(t_feed = PTS + exposure/2 + c),0 = off(原始 PTS)。
/// Dart 据此决定 c 的默认值(on ⇒ 每机查表,off ⇒ 官方 0),与原生只有一处解析,不在 Dart 里再解析一遍启动参数。
@_cdecl("pw_xrslam_live_exposure_mid")
public func pw_xrslam_live_exposure_mid() -> Int32 {
    return PwXrslamOfficialFeed.resolved.exposureMid ? 1 : 0
}

/// 写 14 个 int64,见 `PwXrslamLive.stats`。
@_cdecl("pw_xrslam_live_stats")
public func pw_xrslam_live_stats(_ out: UnsafeMutablePointer<Int64>) {
    PwXrslamLive.shared.stats(into: out)
}
