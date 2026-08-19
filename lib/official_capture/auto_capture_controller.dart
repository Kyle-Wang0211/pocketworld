// auto_capture_controller.dart — 自动采集的有状态编排。
//
// 挂在现成的 6 Hz pose 流上,维护基准帧与 tick 计时,判定 fire 就回调
// 宿主的快门入口。**不自建捕获路径** —— onFire 回调里必须是现有的
// `_onShutterTap()` 等价物,这样 300 张上限、in-flight 守卫、12MP 静照、
// 落盘、SfM 喂帧全部自动继承。
//
// 时钟一律取 ARPose.timestamp(ARFrame 时间轴),不用 DateTime.now(),
// 这样纯 Dart 测试可确定性复现。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何在 auto_capture_geometry.dart,决策谓词在 auto_capture_governor.dart;
// 本文件只做"状态 + 接线",不新造任何阈值。

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';
import 'auto_capture_geometry.dart';
import 'auto_capture_governor.dart';
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 特征点不足以估深度时的兜底深度(米)。此时平移判据不可信,
/// 由 [_Baseline.depthTrusted] 关掉视差路径,只留视线转角路径。
const double kAutoCaptureFallbackDepthM = 1.0;

class _Baseline {
  _Baseline({
    required this.camera,
    required this.forward,
    required this.target,
    required this.depthTrusted,
  });

  final Vector3 camera;
  final Vector3 forward;
  final Vector3 target;
  final bool depthTrusted;
}

class AutoCaptureController {
  AutoCaptureController({
    required bool Function() onFire,
    required ShutterPace Function() paceProvider,
    required int Function() capturedCountProvider,
  }) : _onFire = onFire,
       _paceProvider = paceProvider,
       _capturedCountProvider = capturedCountProvider;

  /// 触发快门。**返回 true 表示入队成功** —— 只有 true 才更新基准帧。
  final bool Function() _onFire;

  /// 每个 pose 现问一次,不在 start() 缓存 —— 背压分级本来就是跑着变的,
  /// 缓存等于把一次采集的节奏钉死在起跑那一刻的队列深度上。
  final ShutterPace Function() _paceProvider;

  /// 同上:张数由宿主队列现问。自动拍跑着的时候手动快门也可能在加张数。
  final int Function() _capturedCountProvider;

  bool _running = false;
  _Baseline? _baseline;
  double _startedAtSec = 0;
  double _lastTickSec = 0;

  bool get isRunning => _running;

  /// 基准帧的场景深度,null 表示尚未起跑。供遥测与测试断言基准是否更新。
  double? get baselineDepthM {
    final b = _baseline;
    if (b == null) return null;
    return (b.target - b.camera).length;
  }

  void start(ARPose pose) {
    _running = true;
    _startedAtSec = pose.timestamp;
    _lastTickSec = pose.timestamp;
    _baseline = _baselineFrom(pose);
  }

  void stop() {
    _running = false;
    _baseline = null;
  }

  AutoCaptureDecision onPose(ARPose pose) {
    if (!_running) return AutoCaptureDecision.skipNotMoved;
    final base = _baseline;
    if (base == null) return AutoCaptureDecision.skipNotMoved;

    final intr = pose.intrinsicFxFyCxCy;
    final hasIntrinsics = intr.length >= 2 && intr[0] > 0 && intr[1] > 0;

    // 注意这里与下面的 shift **刻意不同**:parallax 退化成 0.0 是对的。
    // 它喂的是**下限**判据(`parallaxDeg >= 5.0`),0.0 是该判据的中性/保守值
    // ——"没动够",不会误触发。而 shift 喂的是**上限**判据,那里 0.0 会变成
    // 一句"目标正在正中"的正向断言,所以必须用 null。
    final parallax = base.depthTrusted
        ? parallaxAngleDeg(
            baseCamera: base.camera,
            currentCamera: pose.position,
            target: base.target,
          )
        : 0.0;

    final turn = viewAxisTurnDeg(
      baseForward: base.forward,
      currentForward: _forwardOf(pose),
    );

    // 〔2026-08-19 T2 评审改正〕拿不到深度或内参时传 **null**,不是 0.0。
    //
    // 0.0 是一句**正向断言**——"目标正在画面正中"——而我们此刻恰恰不知道。
    // null 才是"无法求值":governor 收到它会跳过上限判据 R2、只用下限判据
    // (spec §7 "只用下限判据决定")。
    //
    // governor 的 centerShift 参数就是 `double?`,**直接传穿,不要用 `?? 0.0`
    // 之类去翻译** —— 翻译权收在类型里,调用方就没有译错的机会;
    // 若误译成 `?? double.infinity`,R2 会每帧判"立刻拍",快门失控。
    //
    // ⚠️ fx/fy/画幅是 `normalizedCenterShift` 自己也守的门(非正即返回 null),
    // 这里的 hasIntrinsics 只为避免对空列表取下标;两道门方向一致,不冲突。
    //
    // ⚠️ **同一坐标帧**(spec §5.2):intrinsicFxFyCxCy 与 imageWidth/imageHeight
    // 必须成对取自同一个 ARPose —— native `broadcast(frame:)` 里
    // `frame.camera.intrinsics` 与 `CVPixelBufferGetWidth/Height(frame.capturedImage)`
    // 出自同一个 ARFrame、进同一个 payload,都是原生相机图口径(横向)。
    // 绝不可换成预览/显示(竖向)尺寸,否则 sx/sy 整体错一个宽高比。
    final double? shift = (base.depthTrusted && hasIntrinsics)
        ? normalizedCenterShift(
            target: base.target,
            currentCamera: pose.position,
            currentOrientation: pose.orientation,
            fx: intr[0],
            fy: intr[1],
            imageWidth: pose.imageWidth,
            imageHeight: pose.imageHeight,
          )
        : null;

    final tickInterval = autoCaptureTickInterval(_paceProvider());
    final decision = autoCaptureDecide(
      // 两路 tracking 信号都要正常才算正常(spec §7「tracking 丢失 / limited」)。
      // 只看字符串会漏掉 ARKit 之外的后端:它们根本不发 trackingStateName
      // (null),丢跟踪只体现在 isTracking 上 —— 那时 `null => 'normal'` 会
      // 把丢跟踪读成正常。只看 isTracking 又会漏掉 CaptureSession 的混合位姿:
      // IMU 推算锚定时它把 isTracking 强行掰回 true,而字符串仍留着
      // limited_* 的真实原因。两个都查,才两头都堵上。
      trackingNormal:
          pose.isTracking && (pose.trackingStateName ?? 'normal') == 'normal',
      capturedCount: _capturedCountProvider(),
      elapsedSec: pose.timestamp - _startedAtSec,
      sinceLastTickSec: pose.timestamp - _lastTickSec,
      tickIntervalSec: tickInterval.inMilliseconds / 1000.0,
      parallaxDeg: parallax,
      turnDeg: turn,
      centerShift: shift,
    );

    switch (decision) {
      case AutoCaptureDecision.skipCapped:
      case AutoCaptureDecision.skipTimeLimit:
        // 到顶就停,不再每帧撞一次墙。
        _running = false;
        return decision;
      case AutoCaptureDecision.skipTracking:
      case AutoCaptureDecision.skipNotMoved:
      case AutoCaptureDecision.skipPaced:
        return decision;
      case AutoCaptureDecision.fire:
        // tick 先记账:入队失败按 spec §7「下 tick 重试」,不是下一帧重试。
        _lastTickSec = pose.timestamp;
        // 入队失败时基准帧**不动** —— 否则下一 tick 会拿一个根本没拍成
        // 的位置当基准,位移闸直接漏判。
        if (_onFire()) {
          _baseline = _baselineFrom(pose);
        }
        return decision;
    }
  }

  static Vector3 _forwardOf(ARPose pose) =>
      pose.orientation.rotated(Vector3(0, 0, -1));

  static _Baseline _baselineFrom(ARPose pose) {
    final forward = _forwardOf(pose);
    final depth = medianSceneDepthM(
      cameraPosition: pose.position,
      forward: forward,
      points: pose.previewPoints,
    );
    final d = depth ?? kAutoCaptureFallbackDepthM;
    return _Baseline(
      camera: pose.position.clone(),
      forward: forward,
      target: pose.position + forward * d,
      depthTrusted: depth != null,
    );
  }
}
