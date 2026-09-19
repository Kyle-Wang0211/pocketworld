// engine_pose_poller.dart —— 引擎 → 链 那一端的接头。
//
// ══ 它补的是什么 ═══════════════════════════════════════════════════════════
// 2026-09-18 grep 实证:`EnginePoseSample` 在整个 lib/ 里**只有探针页构造过,
// 而且写死 `ok: false`** —— 也就是说 [StaticInitPoseChain] 那条链从建成起
// **没有一条真引擎位姿进去过**;Dart 侧也**没有任何地方调
// `XRSLAMTryGetLatestPose`**,只有注释提到它。
// 本文件就是那根缺的水管:把 FFI 的返回码与 7 元组翻译成 [EnginePoseSample]。
//
// ══ 🔴 这是**复刻上游自己的取法**,不是我设计的 ═════════════════════════════
// 出处:上游 iOS demo `xrslam-ios/visualizer/src/XRSLAM_iOS.mm:168-184`:
//
//     XRSLAMState result;
//     XRSLAMGetResult(XRSLAM_RESULT_STATE, &result);
//     if (result == XRSLAM_STATE_TRACKING_SUCCESS) {
//         XRSLAMPose pose_c;
//         XRSLAMGetResult(XRSLAM_RESULT_CAMERA_POSE, &pose_c);
//         … q.x() = pose.quaternion[0] … q.w() = pose.quaternion[3];
//     }
//
// 逐条对应:
// ① **判据是 `XRSLAM_RESULT_STATE == TRACKING_SUCCESS`**,先查状态再读位姿。
//    `XRSLAMGetResult` 返回 **void**,压根没有返回码可判 —— 上游用的就是状态。
// ② **四元数顺序 [x, y, z, w]**,`w` 在**第 4 位**(上游那四行赋值为证;
//    `XRSLAMPose` 的注释也写着 "format [x, y, z, w]")。
//    ⚠️ 多数 SLAM 库把 w 放第 0 位,这是最容易记反的一处。
// ③ 上游取的是 **CAMERA_POSE**;我们取 **BODY_POSE**,因为 [VioPoseSource]
//    的契约写明是 body pose。🔴 与 ARKit 比对时两者差 **3.38 cm 杠杆臂**,
//    我们为此栽过一次 —— 那个转换属于比对层,不在本文件做。
//
// ══ 🔴 出货引擎**只导出 5 个符号** ═════════════════════════════════════════
// nm 逐个核过 libxrslam_generic_4beb1a9.a,与 receipt 的 exported_abi 一致:
//     XRSLAMCreate  XRSLAMDestroy  XRSLAMGetResult
//     XRSLAMPushSensorData  XRSLAMRunOneFrame
// `XRSLAMTryGetLatestPose` / `XRSLAMGetBodyPose` 虽然在 `xrslam_bindings.dart`
// 里有完整绑定和大段文档,**但不在出货归档里** —— 我一开始按它接,链接期直接
// "Undefined symbol: _XRSLAMTryGetLatestPose"。
// 🔴 **绑定存在 ≠ 符号存在**,与 `GetResultFeatures`(接口在、实现是空的)同类。
//
// ══ 🔴 拿到 OK 也不代表位姿可用 ════════════════════════════════════════════
// 引擎在第一个 TRACKING_SUCCESS 时会返回**零范数四元数**(我们实测过:
// first_at_pose=0,之后 804 个位姿全正常)。`xrslam_bindings.dart:163` 的
// 警告也写着"这两个函数在跟踪器尚未初始化时返回 XRSLAM_OK 但 quaternion 全零"。
// ⇒ 本文件把 OK 原样交给 [VioPoseSource],由它再查一次 `isUsableRotation`
//   (那一层已经这么做了,注释写着"防御的成本是两次乘法")。
//   两层都查,不是重复 —— 这一层保真,那一层保安全。
//
// ══ 🔴 符号缺失**绝不能打死渲染回路** ══════════════════════════════════════
// 2026-09-19 真机实测:台架 app 当时根本没链 XRSLAM,于是第一次 poll 去解析
// `XRSLAMTryGetLatestPose` 时抛异常;而那次 poll 在 `requestFrame` 的 hook 里,
// 异常把**整条渲染回路**打断 —— 页面停在"运行中",一帧不跑、日志里还没有异常
// (被 hook 链吞了)。表现成"卡住",根因是"少个符号"。
// ⇒ 本文件把符号解析与调用**全部包起来**:失败就记下原因、此后永久返回
//   `ok: false`,交给 [VioPoseSource] 按"没有新数据"处理。
//   渲染该照跑照跑,静止兜底该出还出。缺引擎是**降级**,不是**崩溃**。
// ⚠️ 这个脆弱性与"台架链不链引擎"无关 —— 任何一次 dead-strip、任何一个
//   改名的符号都会复现它,所以修在这里,不是修在调用方。

// ══ 为什么是**拉取**不是回调 ═══════════════════════════════════════════════
// 抄 `xrslam_bindings.dart` 对该函数的原注释:dart:ffi 是同步同线程的,
// `NativeCallable.isolateLocal` 从非创建线程调用会**硬 abort**(不是抛异常),
// 而 threading 打开时库内确有后台工作线程;`NativeCallable.listener` 只支持
// 返回 void 且异步投递,拿不到同步结果。所以正确形状就是 Dart 侧按需 poll。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../ffi/xrslam_bindings.dart';
import '../ffi/xrslam_session.dart';
import 'vio_pose_source.dart';

/// 引擎一次读数的快照。测试用它注入,生产由 [EnginePosePoller._readFromEngine] 产。
class EngineSnapshot {
  const EngineSnapshot({
    required this.state,
    required this.quaternionXyzw,
    required this.translationXyz,
    required this.timestampSeconds,
  });
  final int state;
  final List<double> quaternionXyzw;
  final List<double> translationXyz;
  final double timestampSeconds;
}

/// 四元数各分量的下标。写成常量是因为 ② 那条最容易记反。
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
  /// [tryGetLatestPose] 仅用于测试注入。生产不传 ⇒ 第一次调用时才去解析符号
  /// (`late` + try/catch),**构造本身永远不抛**。
  EnginePosePoller({EngineSnapshot? Function()? readEngine})
      : _injected = readEngine;

  final EngineSnapshot? Function()? _injected;
  bool _disposed = false;

  XrslamBindings? _resolved;
  bool _resolveAttempted = false;

  /// 上一次读到的引擎状态(0=初始化中 / 1=跟踪成功 / 2=跟踪失败)。
  int? get lastState => _lastState;
  int? _lastState;

  /// 引擎不可用的原因。`null` = 还没试过或一切正常。
  /// 🔴 它是**粘性**的:一旦解析失败就不再重试 —— 每帧都去 lookup 一个不存在
  /// 的符号是纯浪费,而且异常本身不便宜。
  Object? get unavailableReason => _unavailableReason;
  Object? _unavailableReason;

  bool get isAvailable => _unavailableReason == null;

  XrslamBindings? _fn() {
    if (_injected != null) return null; // 注入模式不走真绑定
    if (_resolveAttempted) return _resolved;
    _resolveAttempted = true;
    try {
      _resolved = XrslamBindings(ffi.DynamicLibrary.process());
    } catch (e) {
      // 最典型的一种:整个 app 没链 XRSLAM,或链了但符号被 dead-strip。
      _unavailableReason = e;
      _resolved = null;
    }
    return _resolved;
  }

  /// 拉一次。**永远返回一个 [EnginePoseSample]**,不返回 `null` ——
  /// "没有新数据"本身就是链需要知道的信息([VioPoseSource] 靠它走
  /// lastKnown / orientationOnly / none 三档)。
  EnginePoseSample poll({required double nowSeconds}) {
    if (_disposed) return _noData(nowSeconds);
    // 🔴 粘性闸放在**最顶上**:解析失败与调用失败都要被它挡住。
    //    只挡解析那条路是不够的 —— 若是 ABI 不匹配导致**调用**每帧抛,
    //    照样会每帧付一次异常的钱。(这条是测试抓出来的,不是我想到的。)
    if (_unavailableReason != null) return _noData(nowSeconds);

    try {
      final EngineSnapshot? snap =
          _injected != null ? _injected() : _readFromEngine();
      if (snap == null) return _noData(nowSeconds);
      _lastState = snap.state;
      // ① 判据照抄上游:状态不是 TRACKING_SUCCESS 就当没有位姿。
      if (snap.state != XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value) {
        return _noData(nowSeconds);
      }
      return EnginePoseSample(
        ok: true,
        // ② [x, y, z, w],w 在第 4 位。
        quaternionXyzw: snap.quaternionXyzw,
        translationXyz: snap.translationXyz,
        // 引擎给的是**图像时刻**,不是显示时刻。补显示延迟是另一刀
        // (要 Monado 的 m_predict_relation + CADisplayLink.targetTimestamp),
        // 不在这里做,也不假装做了。
        timestampSeconds: snap.timestampSeconds,
      );
    } catch (e) {
      _unavailableReason = e;
      _resolved = null;
      return _noData(nowSeconds);
    }
  }

  EngineSnapshot? _readFromEngine() {
    // 🔴 **没有会话就绝不碰引擎。** 2026-09-19 真机 SIGABRT 实证:
    //    栈 = `XRSLAMManager::GetResultState` → `Detail::get_system_state()`,
    //    后者要解引用 `Detail`,而 `XRSLAMCreate` 没跑过时它是空的 ⇒ 崩。
    //    这不是"偶发" —— 是**必崩**,之前几轮没崩只是因为内参来得早、
    //    会话先建上了。一旦启动时序变化(例如先起原生 IMU),立刻暴露。
    //    ⚠️ 这也接不住:C++ 侧的空指针解引用不是异常,Dart 的 catch 拦不住。
    //       唯一的防线就是**不调**。
    if (XrslamSession.current == null) return null;
    final XrslamBindings? b = _fn();
    if (b == null) return null;
    final ffi.Pointer<ffi.UnsignedInt> statePtr = calloc<ffi.UnsignedInt>();
    final ffi.Pointer<XRSLAMPose> posePtr = calloc<XRSLAMPose>();
    try {
      b.XRSLAMGetResult(
          XRSLAMResultType.XRSLAM_RESULT_STATE, statePtr.cast<ffi.Void>());
      final int state = statePtr.value;
      if (state != XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value) {
        return EngineSnapshot(
          state: state,
          quaternionXyzw: const <double>[0, 0, 0, 0],
          translationXyz: const <double>[0, 0, 0],
          timestampSeconds: 0,
        );
      }
      b.XRSLAMGetResult(
          XRSLAMResultType.XRSLAM_RESULT_BODY_POSE, posePtr.cast<ffi.Void>());
      final XRSLAMPose pose = posePtr.ref;
      return EngineSnapshot(
        state: state,
        quaternionXyzw: <double>[
          pose.quaternion[EnginePose7.qx],
          pose.quaternion[EnginePose7.qy],
          pose.quaternion[EnginePose7.qz],
          pose.quaternion[EnginePose7.qw],
        ],
        translationXyz: <double>[
          pose.translation[0],
          pose.translation[1],
          pose.translation[2],
        ],
        timestampSeconds: pose.timestamp,
      );
    } finally {
      calloc.free(statePtr);
      calloc.free(posePtr);
    }
  }

  static EnginePoseSample _noData(double nowSeconds) => EnginePoseSample(
        ok: false,
        quaternionXyzw: const <double>[0, 0, 0, 0],
        translationXyz: const <double>[0, 0, 0],
        timestampSeconds: nowSeconds,
      );

  void dispose() => _disposed = true;
}
