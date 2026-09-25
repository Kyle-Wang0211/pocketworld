// PwXrReconChain.swift —— 台架 XRSLAM → SfM 重建链的 iOS 宿主半边(只进台架 com.kyle.arloopbench)。
//
// ══ 分工(用户 2026-09-25 拍板的链路,见 vendor/xrslam/chain/PwXrReconChainCore.h 文件头)════════════
//   · 规则(等哪个后端帧、等多久、何时不可信、怎么外推)全在跨端 C++ 核心 PwXrReconChainCore.cpp,
//     Mac 回放(pwvi_runner --chain)跑的是同一份源码。
//   · 本文件只做**平台**那一点:
//       ① 每推完一帧,把引擎时刻与 XRSLAM_RESULT_STATE 报给核心(借 PwXrslamLive 的逐帧观察者,
//          时刻取传输层 C 账本里的 effective 时间戳 = 引擎实际收到的那个数);
//       ② 宿主单调时钟 now(CMClockGetHostTimeClock,与相机 PTS / CoreMotion 时间戳同域)+ 50 ms 轮询计时器;
//       ③ 照片时刻换算:t_photo = PTS + exposure/2 + (c + Δ) —— 与视频帧**同一规则、同一组数**:
//          exposure/2 的开关与 PwXrslamLive.onCameraFrame 同一个(PwXrslamOfficialFeed.resolved.exposureMid),
//          c + Δ 就是建会话时交给传输层的那个偏移(PwXrslamLive.appliedCameraTimeOffsetSeconds),
//          加法次序与传输层 `effective = raw + offset` 相同(raw = PTS + exposure/2);
//       ④ 收尾前让调用方看得到喂料 worker 与引擎 worker 是否排空(收尾窗口必须是最终窗口)。
//   · 相机 / 快门 / 照片落盘仍是 PwCameraSlot.swift(AVCapturePhotoOutput,.speed,不开 OIS);
//     本文件不碰相机。
//
// ══ t_photo 的语义(见交付报告;代码里只写依据)═══════════════════════════════════════
//   AVCapturePhoto.timestamp:AVCapturePhotoOutput.h:1990 原文 "The time at which this image was captured,
//   synchronized to the synchronizationClock of the AVCaptureSession … analogous to
//   CMSampleBufferGetPresentationTimeStamp()" ⇒ 与视频 PTS 同一时钟、同一口径(视频 PTS 在本台架按曝光起点处理,
//   PwXrslamLive 文件头偏离 (d))。曝光:PwCameraSlot 先取照片自己的 EXIF ExposureTime,拿不到才退回回调时
//   设备的 exposureDuration(sidecar 的 exposure_provenance 如实记)。
//
// ══ 🔴 td Δ 只是台架实验设置 ═══════════════════════════════════════════════════════════
//   Δ(默认 −5 ms,启动参数 -PWXrslamTdExtraMs 覆盖)由 Dart 页叠进建会话时的 c;不写进任何产品规则。

import CoreMedia
import Foundation

enum PwXrReconChainHost {
    private static let lock = NSLock()
    private static var timer: DispatchSourceTimer?
    private static let queue = DispatchQueue(label: "com.pocketworld.xrchain.poll", qos: .utility)
    private static var framesNoted: UInt64 = 0
    private static var framesSkipped: UInt64 = 0

    /// 宿主单调时钟(秒)。AVCaptureSession 的同步时钟 = host time clock(AVCaptureSession.h:630),
    /// CoreMotion 时间戳同基(PwXrslamLive 文件头「域差」段)。
    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    static func begin(timeoutSeconds: Double, maxExtrapolationSeconds: Double) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        var cfg = PwXrChainConfig(final_timeout_s: timeoutSeconds, max_extrapolation_s: maxExtrapolationSeconds)
        pw_xrchain_reset(&cfg)
        framesNoted = 0
        framesSkipped = 0
        PwXrslamLive.shared.setFrameObserver { obs in
            // 只报引擎真的跑过、且 C 账本给出了 effective 时间戳的帧。
            guard obs.rc == PW_XRSLAM_OK.rawValue, obs.traceOk else {
                PwXrReconChainHost.countSkip()
                return
            }
            pw_xrchain_note_frame(obs.effectiveTimestamp, obs.state)
            PwXrReconChainHost.countNote()
        }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { _ = pw_xrchain_poll(PwXrReconChainHost.now()) }
        t.resume()
        timer = t
        return 0
    }

    fileprivate static func countNote() { lock.lock(); framesNoted &+= 1; lock.unlock() }
    fileprivate static func countSkip() { lock.lock(); framesSkipped &+= 1; lock.unlock() }

    static func end() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        PwXrslamLive.shared.setFrameObserver(nil)
    }

    static func counters() -> (noted: UInt64, skipped: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (framesNoted, framesSkipped)
    }
}

/// 开始一场:清空核心、装逐帧观察者、起 50 ms 轮询。须在 XRSLAM 会话建好之后、相机帧开始推之前或刚开始时调。
@_cdecl("pw_xrchain_begin")
public func pw_xrchain_begin(_ timeoutSeconds: Double, _ maxExtrapolationSeconds: Double) -> Int32 {
    PwXrReconChainHost.begin(timeoutSeconds: timeoutSeconds, maxExtrapolationSeconds: maxExtrapolationSeconds)
}

/// 停轮询、卸观察者(核心里的结果仍可取)。
@_cdecl("pw_xrchain_end")
public func pw_xrchain_end() {
    PwXrReconChainHost.end()
}

/// 提交一张照片。[ptsSeconds] = AVCapturePhoto.timestamp(秒),[exposureSeconds] = 照片曝光(秒,0 = 未知)。
/// out[0] t_photo(引擎时域) [1] 实际加上的 exposure/2 [2] c + Δ [3] 提交时的 now。返回核心的返回码(0 / -1 重复)。
@_cdecl("pw_xrchain_submit_photo_host")
public func pw_xrchain_submit_photo_host(_ requestId: Int64, _ ptsSeconds: Double, _ exposureSeconds: Double,
                                         _ out: UnsafeMutablePointer<Double>) -> Int32 {
    let exposure = (exposureSeconds.isFinite && exposureSeconds >= 0) ? exposureSeconds : 0
    let half = PwXrslamOfficialFeed.resolved.exposureMid ? 0.5 * exposure : 0
    let canonical = ptsSeconds + half                       // 同 PwXrslamLive.onCameraFrame
    let offset = PwXrslamLive.shared.appliedCameraTimeOffsetSeconds
    let tPhoto = canonical + offset                         // 同传输层 effective = raw + offset
    let now = PwXrReconChainHost.now()
    out[0] = tPhoto
    out[1] = half
    out[2] = offset
    out[3] = now
    return pw_xrchain_submit_photo(requestId, tPhoto, now)
}

/// 取走一条结果,摊平成 double 给 Dart(布局见 lib/bench_xrchain/xrchain_native.dart kXrChainResultDoubles)。
/// 返回 1 = 取到,0 = 没有。
@_cdecl("pw_xrchain_take_result_host")
public func pw_xrchain_take_result_host(_ out: UnsafeMutablePointer<Double>, _ n: Int32) -> Int32 {
    guard n >= 32 else { return 0 }
    var r = PwXrChainPhotoResult()
    guard pw_xrchain_take_result(&r) == 1 else { return 0 }
    out[0] = Double(r.photo_id)
    out[1] = r.t_photo
    out[2] = r.submitted_at
    out[3] = r.resolved_at
    out[4] = r.t_state
    out[5] = r.extrapolation_s
    out[6] = r.camera_q.0; out[7] = r.camera_q.1; out[8] = r.camera_q.2; out[9] = r.camera_q.3
    out[10] = r.camera_p.0; out[11] = r.camera_p.1; out[12] = r.camera_p.2
    out[13] = r.body_q.0; out[14] = r.body_q.1; out[15] = r.body_q.2; out[16] = r.body_q.3
    out[17] = r.body_p.0; out[18] = r.body_p.1; out[19] = r.body_p.2
    out[20] = r.propagated_t
    out[21] = Double(r.frame_id)
    out[22] = Double(r.source)
    out[23] = Double(r.trusted)
    out[24] = Double(r.untrusted_reasons)
    out[25] = Double(r.engine_state_at_photo)
    out[26] = Double(r.state_kind)
    out[27] = Double(r.propagate_status)
    out[28] = Double(r.imu_samples)
    out[29] = Double(r.has_pose)
    out[30] = 0
    out[31] = 0
    return 1
}

/// 收尾前的排空读数:out[0] 喂料在途帧 [1] 喂料在途 IMU [2] 引擎 worker 队列里的帧(-1 = 符号不在)
/// [3] 核心里仍在等的照片 [4] 观察者报过的帧数 [5] 观察者跳过的帧数。
@_cdecl("pw_xrchain_drain_state")
public func pw_xrchain_drain_state(_ out: UnsafeMutablePointer<Double>) {
    let p = PwXrslamLive.shared.pendingWork()
    let c = PwXrReconChainHost.counters()
    out[0] = Double(p.frames)
    out[1] = Double(p.imu)
    out[2] = Double(PWBenchReplayEnginePendingFrames())
    out[3] = Double(pw_xrchain_pending_count())
    out[4] = Double(c.noted)
    out[5] = Double(c.skipped)
}

/// 收尾(R5):调用方已停相机并确认 [pw_xrchain_drain_state] 排空后调。返回本次给出结果的照片数。
@_cdecl("pw_xrchain_close_host")
public func pw_xrchain_close_host() -> Int32 {
    pw_xrchain_close(PwXrReconChainHost.now())
}

/// 核心计数(14 个,见 PwXrReconChainCore.h pw_xrchain_stats)。
@_cdecl("pw_xrchain_stats_host")
public func pw_xrchain_stats_host(_ out: UnsafeMutablePointer<Int64>, _ n: Int32) {
    pw_xrchain_stats(out, n)
}
