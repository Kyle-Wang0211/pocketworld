// camera_time_offset.dart —— 每机常量 **c**(相机时间戳偏置)的查表与来源标注。
//
// ══ 一句话 ═════════════════════════════════════════════════════════════════
// 引擎收到的相机时间戳 `t = PTS + 曝光/2 + c`。**本文件只管 c** ——
// 它是一个每机常量,经 `XrslamSession.start(cameraTimeOffsetSeconds:)` →
// `PWXrslamTransportCreateWithCameraTimeOffset` 建会话时传一次,
// 传输层**只把它加在相机时间戳上**(IMU 时间戳不动)。
//
// ══ 🔴 c **不是**曝光/2 ════════════════════════════════════════════════════
// 曝光那一半是**逐帧**的,由原生侧算:`PwCameraSlot.swift` 交出
// `exposureDuration`,`PwXrslamLive.swift` 在推帧前换算成曝光中点
// (见该文件头「偏离 (d)」:`t_canonical = PTS + exposureDuration/2`)。
// 09-22 真机自证实测过同一房间 50 秒里曝光从 8.33 ms 走到 25.69 ms(3×)——
// 逐帧项非常数,**不可能**折进一个常量。
// 剩下的才是 c:**卷帘读出时间的一半 + 管线固定延迟**。
// 读出时间 iOS 不公开任何 API ⇒ 只能整体当常量标定一次。
// 依据不是自研:Huai arXiv 2001.00470 §IV.B 的修正就是
// 「减去(卷帘读出 + 曝光)之和的一半」,曝光那一项我们逐帧算,读出那一项进 c。
//
// ══ c 的口径:**一场定**,相对 ARKit ══════════════════════════════════════
// iPhone 14 Pro(`iPhone15,2`)在录制 run-4ad6e500 上做回放扫描,
// ATE 碗底落在 2–5 ms 的平段里,取中间的 **+3 ms**。
// 🔴 这条要说清的三件事:
//   ① **一场定**,不是多场统计 —— 样本量 1;
//   ② **相对 ARKit 口径**(ATE 的真值是 ARKit 轨迹),不是绝对物理时延;
//   ③ 碗底是个 3 ms 宽的平段,所以 3 ms 这个数本身只精确到「毫秒级」。
//
// ══ 🔴 为什么未知机型给 0 而不是 3 ═════════════════════════════════════════
// 因为**未测就是未测**。c 里的两项(卷帘读出、管线固定延迟)都是逐机型的传感器
// /管线属性,没有任何理由认为 iPhone 14 Pro 的 3 ms 能搬到别的机身上。
// 给 0 与「这一刀之前的现状」逐位相同(生产 ON 臂 c 恒 0),
// 所以未知机型**不会因为本刀而变差**;而给 3 会在 provenance 里留下一个
// 「measured」的假证据 —— 那正是这个代码库反复栽过的那种静默错。
// 对照:`xrslam_extrinsics.dart` 的 `p_bc` 未知机型回退到**分量中位数**,
// 那是因为 18 个已知值构成了一个有界分布(几厘米杠杆臂);
// c 只有**一个**已知值,一个点构不成分布,所以这里没有「中位数回退」这一档。
//
// ══ 抄的是仓里已有的形状,不是新发明 ═══════════════════════════════════════
// * 查表 + 三态 provenance 的形状抄 `xrslam_config.dart:268`
//   `CameraImuExtrinsic.forIosMachine` / `xrslam_extrinsics.dart`:
//   键用 `hw.machine`(如 `iPhone15,2`)而不是营销名 —— 营销名要多经一层
//   字符串映射,多一层就多一个静默错的地方。
// * 机型标识符走**仓里已有的那条通道**:`IosTimebaseChannel.deviceMachine()`
//   (`ios/Runner/PwVioTimebase.swift` 的 `case "deviceMachine"` → `sysctlbyname`)。
//   **没有新起通道**,也没有加原生符号。
// * 粘性缓存(读一次、失败就永久记为不可用)抄
//   `lib/vio/pose/vio_pose_source_runtime_flag.dart` 的三条不变量。
// * `--dart-define` 覆盖抄台架页 `lib/vio/render/ar_minimal_loop_page.dart:493`
//   的**同一个键名** `PW_CAM_TD_MS`,单位同样是**毫秒**。
//
// ══ 🔴 新加的 provenance 取值 ══════════════════════════════════════════════
// `FieldProvenance.devOverride`(见 `xrslam_config.dart`):研发口径的显式覆盖。
// 仓里原有四态(deviceApi / measured / sharedDefault / placeholder)里没有一个
// 说得对「这个数是命令行传进来的,它可能是任何值」——
// 标成 measured 是撒谎,标成 placeholder 又丢掉了「有人故意传了它」这件事。
//
// ══ 🔴 已知窗口:第一次建会话可能查表还没回来 ═══════════════════════════════
// `deviceMachine()` 是 **MethodChannel(异步)**,而 `ZeroArkitCaptureRuntime.start()`
// 在被调用那一刻(第一个 await 之前)就读 c(`ARPoseProvider.start()` 的签名是
// 同步的,`CaptureSession.attach()` 在调它之前一个 await 都没有)。
// ⇒ 进程内**第一次**建会话时缓存可能还没热,
// 那一次会如实打 `provenance=PLACEHOLDER(机型未知)` 并用 c=0。
// 这是**已知缺口,不假装解决了**;要消掉它只有两条路,都超出本刀范围:
//   (a) 给 `PwZeroArkitGate.swift` 加一个同步 C ABI 读 `hw.machine`
//       (与 `pw_vio_pose_source` 同构)—— 要改原生、要真机构建;
//   (b) 让采集页在起采集之前 `await PwDeviceMachine.prime()` ——
//       要改 `ar_capture_page.dart`(本刀被明确禁止碰它)。
// 在此之前,判据就是运行期那行日志:`[zero-arkit] c=…ms provenance=…`,
// 以及台架页每 60 帧那行 `[arloop] 时基 c传入=… c施加=…`。

import '../ffi/xrslam_config.dart' show FieldProvenance, FieldProvenanceLabel;
import '../timebase/ios_timebase_channel.dart' show IosTimebaseChannel;

/// `--dart-define` 的键名。**与台架页同一个键**,不另起一个。
const String kCameraTimeOffsetOverrideKey = 'PW_CAM_TD_MS';

/// 覆盖值(**毫秒**)。默认空串 = 没人传 ⇒ 走查表。
///
/// 🔴 台架页那处默认值写的是 `'0'`;这里写空串,因为本文件要区分
/// 「没传」(⇒ 查表)与「显式传了 0」(⇒ devOverride,c=0 但有人为它负责)。
const String kCameraTimeOffsetOverrideRaw = String.fromEnvironment(
  kCameraTimeOffsetOverrideKey,
  defaultValue: '',
);

/// `hw.machine` → c(**秒**)。
///
/// 🔴 表里只有一行,而且只会在**真的测过**之后才加行。
/// 加一行的判据(与 09-22 那条同口径):同一录制上回放扫描 c,
/// ATE 碗底所在的平段中点,并把录制 id 写进 [kIosCameraTimeOffsetNotes]。
const Map<String, double> kIosCameraTimeOffsetSeconds = <String, double>{
  // iPhone 14 Pro
  'iPhone15,2': 0.003,
};

/// 每一行是**怎么来的**。与 [kIosCameraTimeOffsetSeconds] 键一一对应。
const Map<String, String> kIosCameraTimeOffsetNotes = <String, String>{
  'iPhone15,2': '09-22 run-4ad6e500 回放扫描碗底 2–5 ms 取 3 ms(一场定,相对 ARKit 口径)',
};

/// 一次 c 的解析结果:值 + 来源 + 人话说明。
///
/// 三个字段都要能进日志与回执 —— 「这次跑用的 c 是测的还是 0」必须随时可答。
class CameraTimeOffset {
  const CameraTimeOffset({
    required this.seconds,
    required this.provenance,
    required this.machine,
    required this.note,
  });

  /// c,单位**秒**。原样交给 `XrslamSession.start(cameraTimeOffsetSeconds:)`。
  final double seconds;

  final FieldProvenance provenance;

  /// 解析时用的 `hw.machine`。`null` = 当时还不知道机型(查表没回来 / 非 iOS)。
  final String? machine;

  /// 这个值**怎么来的**。进日志,不参与任何判定。
  final String note;

  double get milliseconds => seconds * 1000.0;

  /// 这个 c 是不是**这台机实测**的。
  /// 落盘/报告要报绝对时延口径之前必须问这一句。
  bool get isMeasuredForThisDevice =>
      provenance == FieldProvenance.measured;

  /// 可核的一行。样子:`c=3.00ms provenance=measured(iPhone15,2)`。
  String get describe => 'c=${milliseconds.toStringAsFixed(2)}ms '
      'provenance=${provenance.label}(${machine ?? '机型未知'})';

  @override
  String toString() => '$describe note=$note';
}

/// 解析 c。**纯函数**,不碰通道、不缓存 —— 便于单测逐条钉死。
///
/// 优先级(高 → 低):
///   ① `--dart-define=PW_CAM_TD_MS=<毫秒>` 非空 ⇒ 覆盖,标 [FieldProvenance.devOverride];
///   ② [machine] 命中 [kIosCameraTimeOffsetSeconds] ⇒ 实测值,标 measured;
///   ③ 其余(机型未知 / 机型没测过)⇒ **0.0**,标 placeholder。
///
/// 🔴 ③ 不猜数。理由见文件头「为什么未知机型给 0 而不是 3」。
/// 🔴 覆盖值解析不了(打错字)也**不静默当 0** —— 落到 ③ 并在 note 里点名,
///    这样日志里能看出「你传了个解析不了的值」,而不是安静地按 0 跑完一整场。
CameraTimeOffset resolveCameraTimeOffset({
  String? machine,
  String? overrideMillisRaw,
}) {
  final String raw = (overrideMillisRaw ?? kCameraTimeOffsetOverrideRaw).trim();
  if (raw.isNotEmpty) {
    final double? ms = double.tryParse(raw);
    if (ms != null && ms.isFinite) {
      return CameraTimeOffset(
        seconds: ms / 1000.0,
        provenance: FieldProvenance.devOverride,
        machine: machine,
        note: '--dart-define=$kCameraTimeOffsetOverrideKey=$raw 覆盖'
            '(研发口径,不是这台机的实测值)',
      );
    }
    return CameraTimeOffset(
      seconds: 0.0,
      provenance: FieldProvenance.placeholder,
      machine: machine,
      note: '$kCameraTimeOffsetOverrideKey="$raw" 解析不出有限毫秒数 ⇒ '
          '按未测处理(c=0),不替你猜一个',
    );
  }

  final double? table =
      machine == null ? null : kIosCameraTimeOffsetSeconds[machine];
  if (table != null) {
    return CameraTimeOffset(
      seconds: table,
      provenance: FieldProvenance.measured,
      machine: machine,
      note: kIosCameraTimeOffsetNotes[machine] ?? '查表命中(来源未记录)',
    );
  }

  return CameraTimeOffset(
    seconds: 0.0,
    provenance: FieldProvenance.placeholder,
    machine: machine,
    note: machine == null
        ? '机型还不知道(deviceMachine 查表没回来 / 非 iOS)⇒ c=0,与本刀之前逐位相同'
        : '$machine **没测过** ⇒ c=0。不拿 iPhone15,2 的 3 ms 顶别的机型 ——'
            '未测就是未测',
  );
}

/// `hw.machine` 的粘性缓存。
///
/// ══ 抄的是 `vio_pose_source_runtime_flag.dart` 的三条不变量 ═══════════════
/// 1. **只读一次。** 机型在进程生存期内不会变;每次都去过一遍 MethodChannel
///    是纯浪费,而这个值在采集页上会被反复问到。
/// 2. **通道不可用是降级不是崩溃。** 模拟器/单测/安卓上那个方法不存在 ⇒
///    `MissingPluginException` ⇒ 永久记成「机型未知」,不上抛。
///    09-19 栽过一次:一个缺失符号的异常打断了整条渲染回路,
///    表现成「卡住」而日志里什么都没有。
/// 3. **只读不写。**
///
/// 🔴 通道本身是**仓里已有的** `pw_vio_timebase`(`IosTimebaseChannel`),
///    方法是已有的 `deviceMachine`。本文件**没有新起通道、没有加原生符号**。
abstract final class PwDeviceMachine {
  /// 仅供测试/台架的覆盖。`null` = 不覆盖。生产代码**不要**写它。
  static String? debugOverride;

  static bool _primed = false;
  static String? _cached;
  static Future<String?>? _inflight;

  /// 是否已经问过一次(诊断用)。
  static bool get primed => _primed;

  /// 同步读。`null` = 还没问到 / 问不到 ⇒ 调用方按**机型未知**处理。
  static String? get cached => debugOverride ?? _cached;

  /// 问一次并缓存。**幂等**,并发调用共用同一个 in-flight future。
  static Future<String?> prime({IosTimebaseChannel? channel}) {
    if (debugOverride != null) return Future<String?>.value(debugOverride);
    if (_primed) return Future<String?>.value(_cached);
    return _inflight ??= _read(channel).then((String? value) {
      _cached = value;
      _primed = true;
      _inflight = null;
      return value;
    });
  }

  static Future<String?> _read(IosTimebaseChannel? channel) async {
    try {
      return await (channel ?? IosTimebaseChannel()).deviceMachine();
    } catch (_) {
      // 通道/方法不存在(模拟器、单测、安卓)—— 降级成「机型未知」。
      return null;
    }
  }

  /// 仅供测试。
  static void debugReset() {
    debugOverride = null;
    _primed = false;
    _cached = null;
    _inflight = null;
  }
}
