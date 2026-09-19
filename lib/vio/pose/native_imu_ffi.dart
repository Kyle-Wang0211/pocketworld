// native_imu_ffi.dart —— 原生 IMU 源的 Dart 出口。
//
// ══ 它替掉了什么 ═══════════════════════════════════════════════════════════
// 此前:IMU 来自 `sensors_plus`,时间戳来自 **Dart 侧的 `Stopwatch`**;
//       相机帧的时间戳来自 **CMSampleBuffer 的主机时钟**。
//       ⇒ **两个不同的时钟域**,而 VIO 预积分对 dt 极敏感。
// 现在:两者都走 `PwMonotonicClock`(Core Media host clock 纳秒),同一条轴。
//
// 学术依据与**已知局限**写在 `ios/Runner/PwMonotonicClock.swift` 的文件头
// (VersaVIS 的 host clock translation / TUM-VIE 的线性时钟模型 /
//  Li & Mourikis 与 Kalibr 的在线 td 估计 / Ling et al. 的"偏移非常数")。
// 🔴 一句话记住:我们做的是**跨域映射**,**不是**残余偏移的在线估计。
//
// ══ 为什么是轮询而不是回调 ═════════════════════════════════════════════════
// 与 `engine_pose_poller.dart` 同一个理由(抄 `xrslam_bindings.dart` 原注释):
// dart:ffi 是同步同线程的,`NativeCallable.isolateLocal` 从非创建线程调用会
// **硬 abort**。原生侧把最新样本存在锁保护的字段里,Dart 按需取。
//
// ⚠️ 轮询意味着**会漏样本**:原生以 100 Hz 采,而我们每渲染帧才取一次
// (~30-60 Hz)。这对"喂引擎做预积分"是不够的 —— 见 [NativeImu.latest] 的
// 说明。当前用途是**时间戳口径验证**,不是最终的喂数通路。

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// 一条原生 IMU 读数。陀螺与加速度**各带自己的时间戳** —— 照 XRSLAM 上游
/// (`Motion.swift` 是两个独立 delegate,不配对不插值)。
class NativeImuSample {
  const NativeImuSample({
    required this.gyroTimestampSeconds,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.accelTimestampSeconds,
    required this.ax,
    required this.ay,
    required this.az,
  });

  /// 与相机帧同域(Core Media host clock)的秒。
  final double gyroTimestampSeconds;
  final double gx, gy, gz;

  /// 同上。
  final double accelTimestampSeconds;

  /// 🔴 已乘 `GRAVITY_NOMINAL = -9.80665`(XRSLAM 上游 `Motion.swift:3,57`),
  /// 单位 m/s²,**符号与上游一致**。
  final double ax, ay, az;

  /// 两路时间戳的差,秒。用来看陀螺与加速度到达得齐不齐。
  double get crossSensorSkewSeconds =>
      (gyroTimestampSeconds - accelTimestampSeconds).abs();
}

/// 原生 IMU 的计数与健康。
class NativeImuStats {
  const NativeImuStats({
    required this.gyroCount,
    required this.accelCount,
    required this.motionErrors,
    required this.gyroRegressions,
    required this.accelRegressions,
  });

  final int gyroCount, accelCount, motionErrors;

  /// 🔴 时间戳**回退**次数。与台架 `TimestampSequenceValidator` 同口径。
  /// 非零就说明映射出了问题 —— 这是判断"域对齐有没有生效"的硬指标,
  /// 不要凭感觉。
  final int gyroRegressions, accelRegressions;

  bool get healthy =>
      motionErrors == 0 && gyroRegressions == 0 && accelRegressions == 0;

  String toDiagnosticString() => 'gyro=$gyroCount accel=$accelCount '
      'err=$motionErrors regress=$gyroRegressions/$accelRegressions'
      '${healthy ? '' : ' 🔴'}';
}

abstract final class NativeImu {
  static final DynamicLibrary _lib = DynamicLibrary.process();

  /// 起 IMU。返回 0 成功;-1 陀螺不可用;-2 加速度计不可用;-3 host 时钟异常。
  ///
  /// 🔴 **必须在相机启动前后尽量靠近地调** —— 锚点是在这里采的,
  /// 它与相机第一帧之间隔得越久,两个域的对齐越依赖时钟稳定性。
  static int start({double rateHz = 100}) => _start(rateHz);

  static void stop() => _stop();

  /// 取最新一条。`null` = 还没起或还没收到样本。
  ///
  /// ⚠️ **这是轮询,会漏样本**:原生按 `rateHz` 采(默认 100 Hz),
  /// 而调用方通常每渲染帧取一次。要把**每一条** IMU 都喂给引擎,
  /// 需要原生侧直接推(那要 C ABI 回调,dart:ffi 做不到 —— 见文件头)。
  /// 当前用途:**验证时间戳口径**,不是最终喂数通路。
  static NativeImuSample? latest() {
    final Pointer<Double> buf = calloc<Double>(8);
    try {
      if (_latest(buf) != 0) return null;
      return NativeImuSample(
        gyroTimestampSeconds: buf[0],
        gx: buf[1],
        gy: buf[2],
        gz: buf[3],
        accelTimestampSeconds: buf[4],
        ax: buf[5],
        ay: buf[6],
        az: buf[7],
      );
    } finally {
      calloc.free(buf);
    }
  }

  static NativeImuStats stats() {
    final Pointer<Int64> buf = calloc<Int64>(5);
    try {
      _stats(buf);
      return NativeImuStats(
        gyroCount: buf[0],
        accelCount: buf[1],
        motionErrors: buf[2],
        gyroRegressions: buf[3],
        accelRegressions: buf[4],
      );
    } finally {
      calloc.free(buf);
    }
  }

  static final int Function(double) _start = _lib.lookupFunction<
      Int32 Function(Double), int Function(double)>('pw_imu_start');
  static final void Function() _stop =
      _lib.lookupFunction<Void Function(), void Function()>('pw_imu_stop');
  static final int Function(Pointer<Double>) _latest = _lib.lookupFunction<
      Int32 Function(Pointer<Double>),
      int Function(Pointer<Double>)>('pw_imu_latest');
  static final void Function(Pointer<Int64>) _stats = _lib.lookupFunction<
      Void Function(Pointer<Int64>),
      void Function(Pointer<Int64>)>('pw_imu_stats');
}
