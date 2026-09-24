// imu_calib_ffi.dart —— 多姿态静止法 IMU 内参标定采集的 Dart 出口。
//
// 原生侧:`ios/Runner/PwImuCalibCapture.swift`(抄源逐项标在那个文件头)。
//
// ══ 🔴 与 `native_imu_ffi.dart` 的关键差别 ═════════════════════════════════
// `NativeImu` 是**轮询**接口(只取最新一条),它的文件头写明会漏样本。
// 标定采集**一条都不能漏** ⇒ 原生侧在 CoreMotion 回调里 append,
// Dart 这边只负责 start / stop / 看进度,**不经手样本**。
//
// ══ 协议(不是我定的)═════════════════════════════════════════════════════
// Tedaldi/Pretto/Menegatti ICRA 2014 §IV —— 姿态数与时长的要求见下方
// `imuCalibPoseLabel` 的注释(那里逐字引了原文)。
//
// iKalibr `config/tool/config-imu-intri-calib.yaml` 注释原文
// (为什么必须静止、为什么陀螺标度拿不到):
//   "Multiple data pieces are required, they are collected stationary using
//    different placement patterns."
//   "for static intrinsic calibration, the scale and non-orthogonal factor
//    (matrix) of gyroscope are lacking observability (for low-cost MEMS IMUs,
//    which almost can not aware the earth rotation)"
//
// ⇒ 这套采集**只能**标出:加速度计 标度 + 非正交 + 零偏,陀螺 零偏。
//   **陀螺标度标不出来** —— 别指望,也别事后声称标出来了。

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// 🔴 **不再用固定的六个方位。** 依据 Tedaldi/Pretto/Menegatti ICRA 2014 §IV 原文:
///   "To avoid unobservability in the calibration parameters estimation, **a minimum of
///    nine different attitudes** has to be collected. In our experience, **a higher number
///    N of distinct attitudes are required to get better calibration results**, while
///    **keeping reduced the duration of each static interval** in order to preserve the
///    assumption of temporal [stability]"
///
/// 我第一版照 iKalibr 配置里那六个 bag 名(X_DOWN_STATIC …)做成六个固定方位,**那是错的**:
/// 6 个姿态对 9 个未知量(3 标度 + 3 非正交 + 3 零偏)**欠定**,除非六个姿态是**精确的**
/// ±x/±y/±z 对称组 —— 而手持根本做不到精确,也不该被要求做到。
///
/// 🔑 **姿态不需要准,只需要彼此不同。** 代价函数 `L(θ)=Σ(‖g‖²−‖h(a_k,θ)‖²)²`
///    **只用 ‖g‖ 的模长,朝向从不进入方程**(论文 Eq.10)。
///    ⇒ 随便垫、靠、斜着放都算数;倒立差 10°、转了 85° 而非 90°,一样有效。
///
/// 目录名用序号 `POSE_01`…,主机侧转换脚本遍历所有子目录,不认名字。
String imuCalibPoseLabel(int index) => 'POSE_${index.toString().padLeft(2, '0')}';

/// 采集计数与健康。字段与 `NativeImuStats` 同口径。
class ImuCalibCaptureStats {
  const ImuCalibCaptureStats({
    required this.gyroCount,
    required this.accelCount,
    required this.motionErrors,
    required this.gyroRegressions,
    required this.accelRegressions,
  });

  final int gyroCount, accelCount, motionErrors;

  /// 🔴 时间戳**回退**次数,与台架 `TimestampSequenceValidator` 同口径。
  /// 非零 ⇒ 这一段作废重录,不要拿去标定。
  final int gyroRegressions, accelRegressions;

  bool get healthy =>
      motionErrors == 0 && gyroRegressions == 0 && accelRegressions == 0;

  String toDiagnosticString() => 'gyro=$gyroCount accel=$accelCount '
      'err=$motionErrors regress=$gyroRegressions/$accelRegressions'
      '${healthy ? '' : ' 🔴 作废重录'}';
}

abstract final class ImuCalibCapture {
  static final DynamicLibrary _lib = DynamicLibrary.process();

  /// 开始一段采集。落盘到
  /// `Documents/imu_calib/<label>/{gyro.csv,accel.csv,capture_meta.json}`。
  ///
  /// 返回 0 成功;-1 陀螺不可用;-2 加速度计不可用;-3 host 时钟异常;-4 已在录。
  ///
  /// `rateHz` 传 100 —— 与现有 `imu.csv` 实测 100.3 Hz 同档,不要另设。
  static int start(String label, {double rateHz = 100}) {
    final Pointer<Utf8> p = label.toNativeUtf8();
    try {
      return _start(p.cast<Char>(), rateHz);
    } finally {
      calloc.free(p);
    }
  }

  /// 停止并落盘。返回写出的样本总数(gyro + accel);
  /// -1 没在录;-5 建目录失败;-6 写文件失败。
  static int stopAndWrite() => _stop();

  static ImuCalibCaptureStats stats() {
    final Pointer<Int64> buf = calloc<Int64>(5);
    try {
      _stats(buf);
      return ImuCalibCaptureStats(
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

  static final int Function(Pointer<Char>, double) _start =
      _lib.lookupFunction<Int32 Function(Pointer<Char>, Double),
          int Function(Pointer<Char>, double)>('pw_imu_calib_start');
  static final int Function() _stop = _lib
      .lookupFunction<Int64 Function(), int Function()>('pw_imu_calib_stop');
  static final void Function(Pointer<Int64>) _stats = _lib.lookupFunction<
      Void Function(Pointer<Int64>),
      void Function(Pointer<Int64>)>('pw_imu_calib_stats');
}
