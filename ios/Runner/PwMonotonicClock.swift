// PwMonotonicClock.swift
//
// ══ 🔴 严格复刻:**代码部分逐字节抄自台架,一行未改** ═══════════════════════
// 源:basalt-vio-phone-bench-20260829/tools/ios_basalt_vio_bench/
//     BasaltVIOBench/SensorTransport/MonotonicClockMapper.swift
// 原件 sha256 前 16 位:1105f9a5d7d30e21
// 本文件 = 该原件 + **仅本段头注释**。验证方法(应为逐字节相同):
//     awk '/^import /{f=1} f' <本文件> | diff - <(awk '/^import /{f=1} f' <原件>)
// 🔴 要改先改台架那边,再整份拷回来。**不要只改这一侧**。
//
// ══ 它解决什么 ═════════════════════════════════════════════════════════════
// 2026-09-19 之前:我们的 IMU 时间戳来自 **Dart 的 Stopwatch**,相机帧时间戳
// 来自 **CMSampleBuffer 的主机时钟** —— **两个不同的时钟域**。VIO 预积分对 dt
// 极敏感,跨域时间戳等于持续给引擎喂错的时间差。
// 规范域 = **Core Media host clock 的纳秒**(见下方原注释)。
//
// ══ 学术依据(2026-09-19 联网核过,非凭记忆)═════════════════════════════════
// 🔴 我一度说这条"没有论文背书"——**那句话是错的**,已收回。文献直接覆盖:
//
// 【我们做的这一步:跨时钟域映射】
//  · Tschopp et al., "VersaVIS: An Open Versatile Multi-Camera Visual-Inertial
//    Sensor Suite", arXiv:1912.02469 —— 开源套件明确提供 **host clock
//    translation**(主机时钟转换)+ 曝光补偿,与本文件同一工程范式。
//  · Klenk et al., "TUM-VIE: The TUM Stereo Visual-Inertial Event Dataset",
//    arXiv:2108.07329 —— 实测不同时钟之间是**线性关系:常数偏移 + 小的时钟漂移**,
//    并逐序列校正。本文件的 (anchor + delta) 正是这个线性模型的常数项部分。
//  · Monado SLAM Dataset, arXiv:2508.00088 —— 明确指出相机与 IMU 可能用**不同
//    时钟**,无法直接比较测量值。
//  · OSU PCVLab, mobile-ar-sensor-logger(github.com/OSUPCVLab/mobile-ar-sensor-logger)
//    —— 专门处理 Android/iOS **手机上**这两路时间戳的记录器。
//
// 【我们**没有**做的那一步:残余时间偏移的在线估计】
//  · Li & Mourikis, "Online Temporal Calibration for Camera-IMU Systems:
//    Theory and Algorithms", IJRR 2014 —— 把时间偏移作为**状态量**与位姿/速度/
//    零偏/外参联合估计,并证明**局部可辨识**(退化运动除外)。
//  · Furgale, Rehder & Siegwart, "Unified Temporal and Spatial Calibration for
//    Multi-Sensor Systems", IROS 2013(**Kalibr** 的理论基础)—— 连续时间
//    B 样条 + 极大似然,时空联合标定。
//  · Qin & Shen, "Online Temporal Calibration for Monocular Visual-Inertial
//    Systems", IROS 2018, arXiv:1808.00692 —— VINS-Mono 的在线时间标定。
//
// ══ 🔴 已知局限:**单次锚点,不跟踪漂移** ═══════════════════════════════════
// 本文件只在启动时采**一次**锚点(host clock 前后各采一次取中点 + 同刻
// systemUptime),此后**不再更新**。
// 而 Ling et al., "Modeling Varying Camera-IMU Time Offset in Optimization-Based
// Visual-Inertial Odometry", ECCV 2018 / arXiv:1810.05456 明确指出:
//   **时间偏移不是常数** —— 它会因时钟不准和 **CPU 过载引起的抖动**随时间变化。
// ⇒ 长会话下本文件的映射会逐渐带上未建模的漂移。
// ⇒ 这是**已知且未解决**的局限,不是"已经对齐了"。要消除它需要上面那一层
//   (把 td 作为状态量在线估计),那是另一项工作,**本文件不声称做到**。
// ⚠️ 判断它有没有咬到我们:看 `TimestampSequenceValidator.regressionCount`
//   与真机上的初始化延迟/跟踪稳定性,不要凭感觉。

import Foundation

/// Maps every sensor timestamp into one process-independent monotonic domain.
///
/// The canonical domain is nanoseconds on the Core Media host clock. Camera
/// presentation timestamps are offsets from a sampled host-clock anchor. Core
/// Motion timestamps are seconds since boot, so they are translated through a
/// `ProcessInfo.systemUptime` sample taken at the same anchor. Wall clock time is
/// never consulted, and the mapper never rewrites a timestamp to hide a
/// regression.
public struct MonotonicClockMapper: Sendable {
    public enum MappingError: Error, Equatable {
        case invalidAnchor
        case invalidTimestamp
        case outOfRange
    }

    private static let nanosecondsPerSecond = 1_000_000_000.0

    public let cameraHostTimeAnchorSeconds: Double
    public let coreMotionUptimeAnchorSeconds: Double
    public let monotonicAnchorNanoseconds: UInt64

    public init(
        cameraHostTimeAnchorSeconds: Double,
        coreMotionUptimeAnchorSeconds: Double,
        monotonicAnchorNanoseconds: UInt64
    ) {
        self.cameraHostTimeAnchorSeconds = cameraHostTimeAnchorSeconds
        self.coreMotionUptimeAnchorSeconds = coreMotionUptimeAnchorSeconds
        self.monotonicAnchorNanoseconds = monotonicAnchorNanoseconds
    }

    public func cameraNanoseconds(hostTimeSeconds: Double) throws -> UInt64 {
        try map(
            sourceSeconds: hostTimeSeconds,
            sourceAnchorSeconds: cameraHostTimeAnchorSeconds
        )
    }

    public func motionNanoseconds(uptimeSeconds: Double) throws -> UInt64 {
        try map(
            sourceSeconds: uptimeSeconds,
            sourceAnchorSeconds: coreMotionUptimeAnchorSeconds
        )
    }

    private func map(sourceSeconds: Double, sourceAnchorSeconds: Double) throws -> UInt64 {
        guard sourceAnchorSeconds.isFinite, sourceAnchorSeconds >= 0 else {
            throw MappingError.invalidAnchor
        }
        guard sourceSeconds.isFinite, sourceSeconds >= 0 else {
            throw MappingError.invalidTimestamp
        }

        let deltaNanoseconds =
            (sourceSeconds - sourceAnchorSeconds) * Self.nanosecondsPerSecond
        let mapped = Double(monotonicAnchorNanoseconds) + deltaNanoseconds

        // Double(UInt64.max) rounds up to 2^64, which UInt64 cannot represent.
        guard mapped.isFinite, mapped >= 0, mapped < Double(UInt64.max) else {
            throw MappingError.outOfRange
        }
        return UInt64(mapped.rounded(.toNearestOrAwayFromZero))
    }
}

public struct TimestampSequenceValidator: Sendable {
    public enum Observation: Equatable, Sendable {
        case accepted
        case regression(previous: UInt64, received: UInt64)
    }

    public private(set) var lastAcceptedTimestamp: UInt64?
    public private(set) var regressionCount: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func observe(_ timestamp: UInt64) -> Observation {
        if let previous = lastAcceptedTimestamp, timestamp <= previous {
            regressionCount += 1
            return .regression(previous: previous, received: timestamp)
        }
        lastAcceptedTimestamp = timestamp
        return .accepted
    }
}
