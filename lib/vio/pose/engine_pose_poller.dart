// engine_pose_poller.dart —— 引擎 → 链 那一端的接头。
//
// ══ 它补的是什么 ═══════════════════════════════════════════════════════════
// 2026-09-18 grep 实证:`EnginePoseSample` 在整个 lib/ 里**只有探针页构造过,
// 而且写死 `ok: false`** —— 也就是说 [StaticInitPoseChain] 那条链从建成起
// **没有一条真引擎位姿进去过**;Dart 侧也**没有任何地方调
// `XRSLAMTryGetLatestPose`**,只有注释提到它。
// 本文件就是那根缺的水管:把 FFI 的返回码与 7 元组翻译成 [EnginePoseSample]。
//
// ══ 🔴 三条口径,全部有出处,别改 ═══════════════════════════════════════════
//
// ① **布局是 `[qx, qy, qz, qw, px, py, pz]`** —— 四元数在前、**实部 w 在第 4 位**。
//    出处是 `xrslam_bindings.dart` 对该函数的文档:"布局钉死为
//    [qx, qy, qz, qw, px, py, pz] …… 与 XRSLAMPose 的 quaternion[4] = {x,y,z,w}
//    完全一致"。而 [PoseQuaternion] 的构造顺序也是 (x, y, z, w),两边对齐。
//    ⚠️ 这是最容易错的一处:多数 SLAM 库把 w 放**第 0 位**。
//
// ② **是 body pose,不是 camera pose**(同上文档:"位姿口径 = body pose,
//    与 XRSLAMGetBodyPose 同源,即已乘 imu_to_body")。
//    🔴 与 ARKit 比对时这里差一个 **3.38 cm 的杠杆臂**(ARKit 报相机位姿),
//    我们为此栽过一次。本文件**不做**那个转换 —— 它属于比对层,不属于取数层。
//
// ③ **返回码 `XRSLAM_OK` 是 0**(`xrslam_status.dart:13`)。
//    ⚠️ 同一个头文件里 `XRSLAMCreate` 的约定**正好相反**(1=成功),
//    那份文件的注释专门警告过不要混用。本文件只判本函数的 0。
//
// ══ 🔴 拿到 OK 也不代表位姿可用 ════════════════════════════════════════════
// 引擎在第一个 TRACKING_SUCCESS 时会返回**零范数四元数**(我们实测过:
// first_at_pose=0,之后 804 个位姿全正常)。`xrslam_bindings.dart:163` 的
// 警告也写着"这两个函数在跟踪器尚未初始化时返回 XRSLAM_OK 但 quaternion 全零"。
// ⇒ 本文件把 OK 原样交给 [VioPoseSource],由它再查一次 `isUsableRotation`
//   (那一层已经这么做了,注释写着"防御的成本是两次乘法")。
//   两层都查,不是重复 —— 这一层保真,那一层保安全。
//
// ══ 为什么是**拉取**不是回调 ═══════════════════════════════════════════════
// 抄 `xrslam_bindings.dart` 对该函数的原注释:dart:ffi 是同步同线程的,
// `NativeCallable.isolateLocal` 从非创建线程调用会**硬 abort**(不是抛异常),
// 而 threading 打开时库内确有后台工作线程;`NativeCallable.listener` 只支持
// 返回 void 且异步投递,拿不到同步结果。所以正确形状就是 Dart 侧按需 poll。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../ffi/xrslam_bindings.dart';
import '../ffi/xrslam_status.dart';
import 'vio_pose_source.dart';

/// 7 元组里各分量的下标。写成常量是因为 ① 那条最容易记反。
abstract final class EnginePose7 {
  static const int qx = 0;
  static const int qy = 1;
  static const int qz = 2;

  /// 🔴 实部在**第 4 位**,不是第 0 位。
  static const int qw = 3;
  static const int px = 4;
  static const int py = 5;
  static const int pz = 6;

  static const int length = 7;
}

/// 每帧向引擎拉一次最新位姿。
///
/// 缓冲区**建一次用到底** —— 每帧 `calloc` 再 `free` 是纯浪费,而且在渲染
/// 循环里做分配会把抖动引进帧时间。用完记得 [dispose]。
class EnginePosePoller {
  EnginePosePoller({XrslamBindings? bindings})
      : _bindings = bindings ?? XrslamBindings(ffi.DynamicLibrary.process()),
        _pose7 = calloc<ffi.Double>(EnginePose7.length),
        _timestamp = calloc<ffi.Double>();

  final XrslamBindings _bindings;
  final ffi.Pointer<ffi.Double> _pose7;
  final ffi.Pointer<ffi.Double> _timestamp;
  bool _disposed = false;

  /// 上一次的返回码,给探针/日志看。没调用过时为 `null`。
  int? get lastReturnCode => _lastCode;
  int? _lastCode;

  /// 拉一次。**永远返回一个 [EnginePoseSample]**,不返回 `null` ——
  /// "没有新数据"本身就是链需要知道的信息([VioPoseSource] 靠它走
  /// lastKnown / orientationOnly / none 三档)。
  EnginePoseSample poll({required double nowSeconds}) {
    if (_disposed) {
      return EnginePoseSample(
        ok: false,
        quaternionXyzw: const <double>[0, 0, 0, 0],
        translationXyz: const <double>[0, 0, 0],
        timestampSeconds: nowSeconds,
      );
    }

    final int code = _bindings.XRSLAMTryGetLatestPose(_pose7, _timestamp);
    _lastCode = code;

    // ③ 本函数的成功码是 0。出参在**任何**返回码下都已被引擎无条件清零
    //   (头文件契约:"非 NULL,**无条件先清零**"),所以失败路径读它是安全的,
    //   只是读到零而已 —— 我们不读,直接交 ok:false。
    if (code != xrslamOk) {
      return EnginePoseSample(
        ok: false,
        quaternionXyzw: const <double>[0, 0, 0, 0],
        translationXyz: const <double>[0, 0, 0],
        timestampSeconds: nowSeconds,
      );
    }

    return EnginePoseSample(
      ok: true,
      // ① w 在第 4 位;PoseQuaternion 的顺序也是 (x, y, z, w)。
      quaternionXyzw: <double>[
        _pose7[EnginePose7.qx],
        _pose7[EnginePose7.qy],
        _pose7[EnginePose7.qz],
        _pose7[EnginePose7.qw],
      ],
      translationXyz: <double>[
        _pose7[EnginePose7.px],
        _pose7[EnginePose7.py],
        _pose7[EnginePose7.pz],
      ],
      // 引擎给的是**图像时刻**,不是显示时刻。补显示延迟是另一刀
      // (要 Monado 的 m_predict_relation + CADisplayLink.targetTimestamp),
      // 不在这里做,也不假装做了。
      timestampSeconds: _timestamp.value,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    calloc.free(_pose7);
    calloc.free(_timestamp);
  }
}
