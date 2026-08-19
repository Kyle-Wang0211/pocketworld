// auto_capture_controller.dart — 自动采集的有状态编排。
//
// 挂在现成的 pose 流上(**逐 ARFrame,20–60 Hz,不是 6 Hz** —— 6 Hz 是画质块
// 的节流频率,与 pose 无关;特征点另按 8 Hz 节流,见 spec §5.4 与
// _lastTrustedDepthM 的注释),维护基准帧与 tick 计时,判定 fire 就回调
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

/// **本轮从头到尾一次可信深度都没测到过**时的兜底深度(米)。此时平移判据
/// 不可信,由 [_Baseline.depthTrusted] 关掉视差路径,只留视线转角路径。
///
/// ⚠️ 这不是"当前帧没特征点"时走的路 —— 那种情况沿用
/// [AutoCaptureController._lastTrustedDepthM],见那里的注释。本常数只在
/// 「这一轮里从来没有过任何一帧能估出深度」时才用得上,它是一句
/// **没人量过的断言**,所以配 `depthTrusted=false` 一起用。
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

  /// 本轮最近一次**可信**的场景中位深度(米);本轮从未测到过则为 null。
  ///
  /// 为什么需要它(spec §5.4,核实自 `OfficialAetherARKitPlugin.swift`):
  /// pose 事件是**逐 ARFrame** 广播的(`sessionDelegate.onFrame`,无节流,
  /// 20–60 Hz),而特征点 `previewPoints` 单独按 `previewPointInterval = 1/8`
  /// 节流 —— 30 fps 下约 **3/4 的 pose 帧根本不带特征点**
  /// (Dart 侧 `_decodePreviewPoints` 对缺字段返回**空列表**,不是沿用上一帧)。
  /// 而基准帧只在 `start()` 与**每次成功入队**时重算,两者都有约 3/4 的概率
  /// 落在空帧上。
  ///
  /// 没有这份记忆,基准帧就会被推迟到"入队后第一个带特征点的帧"才落定,
  /// 最多晚 125 ms;按 1 m/s 步行 = **12.5 cm**,与 1 m 物距处的平移下限
  /// 8.8 cm 同量级,且**方向恒定** —— 是系统性偏置,不是噪声。
  ///
  /// 沿用它时 `depthTrusted` **保持 true**:场景深度在 125 ms 内不会突变,
  /// 而它是这一轮里对**这个场景**的真实测量;相比之下退回
  /// [kAutoCaptureFallbackDepthM] 是断言一个没人量过的深度,还会把视差与
  /// 重叠两条路一起关掉(即 §7 那条死锁的成因)。
  ///
  /// **轮内不设过期时限,轮的边界就是唯一的过期边界**:`stop()` 与 `start()`
  /// 都清空它(见那里)。理由:一轮之内按定义是同一个场景,而跨轮可能换了场景;
  /// 且"过期"之后唯一能退到的状态(兜底深度 + 两条路全关)在任何时刻都比
  /// 一个偏了的深度更差 —— 过期只会把用户送回死锁那一侧。真要设时限,
  /// 依据得来自真机标定(spec §11),不能在这里凭空取一个数。
  double? _lastTrustedDepthM;

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
    // 新一轮 = 可能是另一个场景。**先清空**上一轮的深度记忆,再由本帧重建 ——
    // 顺序不能反,否则起跑帧没特征点时会拿上一轮的深度当"可信"。
    // 清在这里而不是只清在 stop() 里:连着调两次 start() 不经 stop() 也算新一轮。
    _lastTrustedDepthM = null;
    // spec §7「tracking 丢失 / limited ⇒ 暂停触发,**且基准帧不更新**」是无条件的,
    // 起跑那一帧也算。丢跟踪时的位置估计不可信,拿它当基准会毒化整轮的位移判据。
    // 播种推迟到 onPose 里第一帧正常的位姿(见那里的补播种/回滚入口)。
    // ⇒ 起跑帧 tracking 异常时深度记忆也不建立(_baselineFrom 才刷新记忆)。
    _baseline = _trackingNormal(pose) ? _baselineFrom(pose) : null;
  }

  void stop() {
    _running = false;
    _baseline = null;
    // 深度记忆是**这一轮这个场景**的测量,绝不能被下一轮继承。
    _lastTrustedDepthM = null;
  }

  AutoCaptureDecision onPose(ARPose pose) {
    if (!_running) return AutoCaptureDecision.skipNotMoved;
    final base = _baseline;
    final trackingOk = _trackingNormal(pose);

    // 逐帧收下场景深度(spec §5.4 要的是"**最近一次**可信深度")。
    //
    // 为什么不只在 _baselineFrom 里刷新:_baselineFrom 只在 start()、开火后、
    // 重播种时被调用 —— 至多约 1 次/秒。只在那里刷新的话,这个字段实际记的是
    // "上一次成功播种那一帧的深度",在连续多次开火都落在空帧上时可以陈旧到
    // **分钟**级,而不是文档承诺的 125 ms。8 Hz 的特征点每一帧都送到手边,
    // 空帧上 medianSceneDepthM 的循环体一次都不进(点列表为空)、直接返回 null,
    // 逐帧收下它的代价可忽略。
    //
    // 只从 tracking 正常的帧取:与"丢跟踪期间不播种"(spec §7)同一条纪律 ——
    // 深度是拿相机位姿与特征点算出来的,位姿不可信时算出来的深度也不可信,
    // 而它会直接进下一个基准帧。
    if (trackingOk) _refreshDepthMemory(pose);

    // 需要(重)播种的两种情形,共用下面 switch 里的一个入口:
    //  · base == null —— start() 那帧 tracking 不正常,没敢播种;
    //  · !base.depthTrusted —— 基准落在无纹理面上。它**同时**关掉视差与上限
    //    两条路,只剩转角;用户只横移不转身就永不开火、永不重播种 ⇒ 死锁。
    //    实测:起跑帧特征点不足时 30 秒横移产出 0 张,充足时 30 张。
    //    见 spec §7「⚠️ 死锁:降级必须可逆」。
    final needsSeed = base == null || !base.depthTrusted;

    final intr = pose.intrinsicFxFyCxCy;
    final hasIntrinsics = intr.length >= 2 && intr[0] > 0 && intr[1] > 0;

    // 注意这里与下面的 shift **刻意不同**:parallax 退化成 0.0 是对的。
    // 它喂的是**下限**判据(`parallaxDeg >= 5.0`),0.0 是该判据的中性/保守值
    // ——"没动够",不会误触发。而 shift 喂的是**上限**判据,那里 0.0 会变成
    // 一句"目标正在正中"的正向断言,所以必须用 null。
    final parallax = (base != null && base.depthTrusted)
        ? parallaxAngleDeg(
            baseCamera: base.camera,
            currentCamera: pose.position,
            target: base.target,
          )
        : 0.0;

    // 没有基准帧就没有参考光轴 —— 退化成 0.0(下限判据的中性值),
    // 与深度不可信时 parallax 退 0.0 同一个道理。
    final turn = base != null
        ? viewAxisTurnDeg(
            baseForward: base.forward,
            currentForward: _forwardOf(pose),
          )
        : 0.0;

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
    final double? shift = (base != null && base.depthTrusted && hasIntrinsics)
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
      trackingNormal: trackingOk,
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
        // 丢跟踪期间**不播种**:位置估计不可信(spec §7)。
        return decision;
      case AutoCaptureDecision.skipNotMoved:
      case AutoCaptureDecision.skipPaced:
        if (needsSeed) {
          final candidate = _baselineFrom(pose);
          // base == null:第一帧正常位姿,无条件播种(哪怕这帧也没纹理,
          //   有个基准总比没有强,后续可信帧会再把它换掉)。
          // base 不可信:只有当前帧**确实可信**才换,否则原地不动 ——
          //   拿一个同样不可信的帧去换,只是每帧把基准往前挪一格,
          //   位移永远归零,那是另一种形式的锁死。
          if (base == null || candidate.depthTrusted) {
            _baseline = candidate;
            // 本帧只播种、不判定:相对新基准的位移必然为 0。
            // tick 时钟**不重置** —— 播种不是一次拍摄,不该消耗节奏预算。
            return AutoCaptureDecision.skipNotMoved;
          }
        }
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

  /// 两路 tracking 信号都要正常才算正常(spec §7「tracking 丢失 / limited」)。
  ///
  /// 只看字符串会漏掉 ARKit 之外的后端:它们根本不发 trackingStateName(null),
  /// 丢跟踪只体现在 isTracking 上 —— 那时 `null => 'normal'` 会把丢跟踪读成正常。
  /// 只看 isTracking 又会漏掉 CaptureSession 的混合位姿:IMU 推算锚定时它把
  /// isTracking 强行掰回 true,而字符串仍留着 limited_* 的真实原因。
  /// 两个都查,才两头都堵上。**全类只此一份**,start() 与 onPose 共用。
  static bool _trackingNormal(ARPose p) =>
      p.isTracking && (p.trackingStateName ?? 'normal') == 'normal';

  static Vector3 _forwardOf(ARPose pose) =>
      pose.orientation.rotated(Vector3(0, 0, -1));

  /// 当前帧能估出深度就记下来。**幂等**:同一个 pose 算两次结果相同
  /// (medianSceneDepthM 是 pose 的纯函数),所以重复调用无副作用。
  void _refreshDepthMemory(ARPose pose) {
    final measured = medianSceneDepthM(
      cameraPosition: pose.position,
      forward: _forwardOf(pose),
      points: pose.previewPoints,
    );
    // 估不出来时**不覆盖**:空帧不该抹掉 125 ms 前的真实测量。
    if (measured != null) _lastTrustedDepthM = measured;
  }

  _Baseline _baselineFrom(ARPose pose) {
    // 自足:任何新增的调用点都不必记得"先刷新记忆"。幂等,所以与 onPose
    // 开头那次刷新重复调用也没有副作用(每秒至多多算一次中位数)。
    _refreshDepthMemory(pose);
    final forward = _forwardOf(pose);
    // 当前帧没特征点时沿用最近一次可信深度,并**保持 depthTrusted=true**:
    // 30 fps 下约 3/4 的帧不带特征点(spec §5.4),而基准帧必须锚在**真正
    // 入队的那一帧**上,不能推迟到之后第一个带特征点的帧 —— 那是一个方向
    // 恒定的系统性偏置。字段注释里有完整理由,包括为什么轮内不设过期时限。
    final remembered = _lastTrustedDepthM;
    final d = remembered ?? kAutoCaptureFallbackDepthM;
    return _Baseline(
      camera: pose.position.clone(),
      forward: forward,
      target: pose.position + forward * d,
      // 本轮从未测到过深度时才是"不可信" —— 那时 d 是没人量过的兜底值。
      depthTrusted: remembered != null,
    );
  }
}
