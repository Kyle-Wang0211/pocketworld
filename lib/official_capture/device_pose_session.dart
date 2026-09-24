// device_pose_session.dart — 一次重建只许信**一个**设备跟踪会话的位姿(纯 Dart,零 IO)。
//
// [2026-09-24 定罪] cap_1789119308200005:第一次拍摄 7 张后手机重启(ARKit 时钟
// 13388 s → 321 s),补拍 16 张;收尾的整项目重喂把两次会话的照片**连同各自旧世界
// 的外参**一起喂给核(ar_capture_page `_startArchivedRefeed` ← sfm_resume
// `planArchivedRefeed` ← archived_photo_rebuild `parseArchivedPhoto` 原样透传
// sidecar `extrinsic`)。两个会话的世界系差绕重力 34.4° + 平移 + 5.1% 尺度,
// 第 0–6 帧离设备位姿 218–363 mm,闸报警;ARKit 本身没错,是**我们把两个坐标系
// 当成一个**。
//
// ── 官方口径(照抄,不自创)──────────────────────────────────────────────
// • ARKit:每个会话自己的世界系。`ARConfiguration.WorldAlignment.gravity`:
//   "The origin is the initial position of the device"(Y 平行重力,水平朝向与
//   原点随会话而定)。跨会话连续**只**有一条官方路:`initialWorldMap` 重定位,
//   成功后 "the current world coordinate system and anchors match those from the
//   recorded world map";`sessionShouldAttemptRelocalization(_:)` 不实现时
//   "ARKit spends a few seconds trying to relocalize before restarting your
//   session",重启即新世界系(`resetTracking` "discards all world-tracking state")。
//   本 App 不用 ARWorldMap、也不实现该回调 ⇒ 每次 run(resetTracking)、每次重启
//   都是新坐标系。
// • ARCore:local anchor "valid only for that instance of the app";跨会话共享
//   坐标只有 Cloud Anchor(resolve 相对托管锚定位)。本 App 不用 ⇒ 同上。
// • XRSLAM:每次 XRSLAMCreate 从重力对齐开始,偏航/平移/尺度自由 ⇒ 新坐标系。
// • COLMAP 3.14(glomap_vendor/colmap-src/colmap):
//   - 位姿先验只有**一个**世界系:`PosePrior` 一个 position + 一个
//     coordinate_system 枚举(geometry/pose_prior.h:43-66),没有"第几个坐标系"。
//   - 对先验的对齐是**一个** Sim3,且至少 3 对
//     (estimators/alignment.cc:241-279 AlignReconstructionToPosePriors,
//     `src.size() < 3` → 失败;model_aligner `min_common_images = 3`,
//     exe/model.cc:267)。
//   - 两个**各自坐标系**的重建,官方按**图像证据**(重投影)求 Sim3 合并,从不信
//     各自的外部坐标:model_merger(exe/model.cc:764-805)→
//     MergeAndFilterReconstructions(sfm/observation_manager.cc:44-53)→
//     MergeReconstructions(estimators/alignment.cc:474-503)→
//     AlignReconstructionsViaReprojections(alignment.cc:282);层级建图的
//     MergeClusters 同一条(controllers/hierarchical_pipeline.cc:42-95)。
//
// ⇒ 做法:每张喂给核的照片带 `deviceSessionId`;选**一个**参考会话,只有它的
//   照片 `devicePoseTrusted = true`;其余会话的照片像上游"没有先验的图像"那样
//   按图像证据注册(核侧由 C 实现;证据不足就不注册)。
//
// 参考会话怎么选:
// • 整项目重喂(本文件 [planDevicePoseTrust]):**照片最多**的会话(≥3 张,
//   alignment.cc:271);并列取**最早**开拍的。理由:把所有会话的位姿都交给
//   COLMAP 的 LO-RANSAC Sim3(alignment.cc:276-277 EstimateSim3dRobust),它选的
//   正是内点最多的那一组 —— 我们只是把"会被当成外点的其它会话"提前、确定地
//   摘出来,不让 RANSAC 在两个坐标系之间凑一个混合解;并列取最早,对应 ARWorldMap
//   "新会话重定位进旧会话坐标系"的方向。
// • 拍摄期实时喂帧([DevicePoseSessionTracker]):参考 = **本场第一个**会话
//   (它的帧已经按设备位姿进了核,事后改不了;这也是 ARKit 重定位的方向)。一旦
//   本场出现第二个会话,收尾改走整项目重喂,由上面那条规则重新定参考。
//
// 旧数据(没有逐张会话记录)只按**证据**分组,见 [planDevicePoseTrust]。

import 'dart:convert';

/// 与 COLMAP `AlignReconstructionToPosePriors` 的 `src.size() < 3` 同一个数
/// (estimators/alignment.cc:271)。少于它的会话连 Sim3 都解不出,不能当参考。
const int kDevicePoseAlignMinPairs = 3;

/// 逐张会话记录的文件名(capture 目录下,Dart 独占;**不**在
/// `sidelineDatabaseForFreshSession` 的挪开名单里 —— 它跨补拍累积)。
const String kDeviceSessionLedgerFileName = 'official_device_sessions.jsonl';

// ════════════════════════════════════════════════════════════════════════
// 一、实时:会话边界检测
// ════════════════════════════════════════════════════════════════════════

/// 跨平台归一的跟踪相位。只区分会影响"世界系是否连续"的几档。
enum DeviceTrackingPhase {
  /// 正常跟踪。
  normal,

  /// 初始化中 —— 平台正在**建立**世界系(ARKit `.limited(.initializing)`;
  /// XRSLAM 未完成初始化)。在已经 normal 过之后再出现 = 会话被重启。
  initializing,

  /// 重定位中(ARKit `.limited(.relocalizing)`)。成功回到 normal 时世界系
  /// 连续(Apple:"your app's virtual content appears in the same position")。
  relocalizing,

  /// 其它受限(快速运动 / 特征不足)。世界系不变,只是质量差 —— 由 A 的
  /// 就绪闸处理,不构成会话边界。
  limitedOther,

  /// 不可用。已 normal 过之后出现 = 跟踪状态被丢弃,按新会话处理。
  notAvailable,
}

/// 跨端追踪状态词表(`ARPose.trackingStateName`:ARKit `trackingStateString`,
/// OfficialAetherARKitPlugin.swift;XRSLAM 经 A 的 `xrslamTrackerStateName`
/// 映射进同一词表)→ 相位。
/// null / 认不出的名字按 [DeviceTrackingPhase.limitedOther]:不据此切会话,
/// 也不据此证明连续(连续性只由 relocalizing→normal 证明)。
DeviceTrackingPhase deviceTrackingPhaseFromArkitName(String? name) {
  switch (name) {
    case 'normal':
      return DeviceTrackingPhase.normal;
    case 'limited_initializing':
      return DeviceTrackingPhase.initializing;
    case 'limited_relocalizing':
      return DeviceTrackingPhase.relocalizing;
    case 'not_available':
      return DeviceTrackingPhase.notAvailable;
    default:
      return DeviceTrackingPhase.limitedOther;
  }
}

/// 一个会话的起点。[startTimestamp] 在**设备位姿时钟**上(ARKit `ARFrame.timestamp`
/// / XRSLAM 同域时间戳),与每张照片的 captureTimestamp 同一时钟,所以照片归属
/// 按时间戳查,不受异步喂帧先后影响。
class DevicePoseSessionBoundary {
  const DevicePoseSessionBoundary({
    required this.sessionId,
    required this.startTimestamp,
    required this.reason,
  });
  final String sessionId;

  /// null = 本会话从第一次观测前就开始(本场第一个会话)。
  final double? startTimestamp;
  final String reason;
}

/// 拍摄期的会话边界跟踪器(一个采集页一只)。平台无关:ARKit 与 XRSLAM 只是
/// 往里喂不同的事件。
///
/// 边界规则(每条都对应上面引用的官方行为):
///  1. [beginRun]:平台开了一个**新 run**(ARKit run(resetTracking) / XRSLAM
///     create)→ 新会话。
///  2. [observe] 在本会话已经 normal 过之后看到 initializing / notAvailable
///     → 平台重启了跟踪 → 新会话,起点 = 这一帧。Apple 对 initializing 的定义:
///     "This value occurs temporarily after starting a new AR session or
///     changing configurations";notAvailable:"Camera position tracking is not
///     available"(不保证之后世界系连续,按新会话;是否真的跳变要上台架量)。
///     真机实证:cap_1787733401226757 同一次拍摄里 normal → limited_initializing
///     → normal,第 0 张(之前拍的)交付后离设备位姿 59 mm,锚点跳 51 mm / 7.8°。
///     XRSLAM:离开 TRACKING_SUCCESS(A 映射成 limited_initializing /
///     not_available)再回来,同一规则。
///  3. [suspend](切后台 / 被打断)之后,只有**先 relocalizing、再 normal**
///     才算接回原世界系(ARKit 文档对重定位成功的定义);其余任何路径(直接
///     initializing、平台不支持重定位如 XRSLAM、或没观测到 relocalizing 就
///     normal)→ 新会话,起点 = 暂停那一刻(暂停后拍的每一张都不属于旧会话)。
///  4. 暂停后、判定出来之前拍的照片归属未知 → [sessionAt] 返回 null(调用方按
///     不可信处理)。
class DevicePoseSessionTracker {
  DevicePoseSessionTracker({required this.idPrefix});

  /// 会话 id 前缀,要求**跨采集页唯一**(调用方传 run 开始的墙钟毫秒 + 平台名)。
  final String idPrefix;

  final List<DevicePoseSessionBoundary> _boundaries =
      <DevicePoseSessionBoundary>[];
  bool _sawNormal = false;
  double? _lastTimestamp;

  // 暂停后待判定的状态。
  bool _suspended = false;
  bool _suspendCanRelocalize = true;
  bool _sawRelocalizingSinceSuspend = false;
  double? _suspendAfterTimestamp;

  List<DevicePoseSessionBoundary> get boundaries =>
      List<DevicePoseSessionBoundary>.unmodifiable(_boundaries);

  int get sessionCount => _boundaries.length;

  /// 实时参考会话 = 本场第一个会话(见文件头"参考会话怎么选")。
  String? get referenceSessionId =>
      _boundaries.isEmpty ? null : _boundaries.first.sessionId;

  String? get currentSessionId =>
      _boundaries.isEmpty ? null : _boundaries.last.sessionId;

  /// 暂停后尚未判定是否接回原世界系。
  bool get awaitingRelocalizationVerdict => _suspended;

  String _nextId() => '$idPrefix#${_boundaries.length}';

  void _open(String reason, double? at) {
    _boundaries.add(
      DevicePoseSessionBoundary(
        sessionId: _nextId(),
        startTimestamp: at,
        reason: reason,
      ),
    );
    _sawNormal = false;
  }

  /// 规则 1。[atTimestamp] 为 null 表示"从现在起的所有帧"(本场第一个 run)。
  void beginRun({required String reason, double? atTimestamp}) {
    _suspended = false;
    final last = _lastTimestamp;
    _open(
      reason,
      atTimestamp ?? (_boundaries.isEmpty || last == null ? null : last + 1e-6),
    );
  }

  /// 规则 3 的起点。[platformCanRelocalize]:ARKit = true;XRSLAM 没有重定位
  /// (跟丢也从不重置,只靠 IMU 硬撑)⇒ false,恢复后一律新会话。
  void suspend({bool platformCanRelocalize = true}) {
    if (_boundaries.isEmpty) return;
    if (_suspended) return; // 连续两次暂停只算一次
    _suspended = true;
    _suspendCanRelocalize = platformCanRelocalize;
    _sawRelocalizingSinceSuspend = false;
    _suspendAfterTimestamp = _lastTimestamp;
  }

  /// 每一帧设备位姿都喂进来(ARKit pose 流 / XRSLAM 输出)。
  void observe(DeviceTrackingPhase phase, double timestamp) {
    if (!timestamp.isFinite) return;
    if (_boundaries.isEmpty) {
      // 没 beginRun 就来了帧:当作本场第一个 run。
      _open('implicit_first_run', null);
    }
    if (_suspended) {
      switch (phase) {
        case DeviceTrackingPhase.relocalizing:
          _sawRelocalizingSinceSuspend = true;
        case DeviceTrackingPhase.normal:
          if (_suspendCanRelocalize && _sawRelocalizingSinceSuspend) {
            // 重定位成功:世界系连续,仍是原会话。
            _suspended = false;
          } else {
            _suspended = false;
            _open('resumed_without_relocalization', _suspendPoint(timestamp));
          }
        case DeviceTrackingPhase.initializing:
        case DeviceTrackingPhase.notAvailable:
          _suspended = false;
          _open('restarted_after_suspend', _suspendPoint(timestamp));
        case DeviceTrackingPhase.limitedOther:
          break;
      }
    } else {
      switch (phase) {
        case DeviceTrackingPhase.initializing:
        case DeviceTrackingPhase.notAvailable:
          if (_sawNormal) _open('tracking_restarted', timestamp);
        case DeviceTrackingPhase.relocalizing:
          // 没有经过我们的 suspend 也进了重定位(系统级打断):按 suspend 处理。
          if (_sawNormal) {
            suspend(platformCanRelocalize: true);
            _sawRelocalizingSinceSuspend = true;
          }
        case DeviceTrackingPhase.normal:
        case DeviceTrackingPhase.limitedOther:
          break;
      }
    }
    if (phase == DeviceTrackingPhase.normal) _sawNormal = true;
    _lastTimestamp = timestamp;
  }

  /// 新会话的起点:暂停前最后一帧之后。取一个严格大于它、且不大于当前帧的值。
  double _suspendPoint(double now) {
    final before = _suspendAfterTimestamp;
    if (before == null || !(before < now)) return now;
    return before + (now - before) * 1e-6;
  }

  /// 在 [captureTimestamp] 拍下的照片属于哪个会话;待判定时返回 null。
  String? sessionAt(double captureTimestamp) {
    if (_boundaries.isEmpty || !captureTimestamp.isFinite) return null;
    final pendingFrom = _suspendAfterTimestamp;
    if (_suspended && pendingFrom != null && captureTimestamp > pendingFrom) {
      return null;
    }
    String id = _boundaries.first.sessionId;
    for (final b in _boundaries) {
      final s = b.startTimestamp;
      if (s == null || captureTimestamp >= s) id = b.sessionId;
    }
    return id;
  }

  /// 实时喂帧的信任位:属于参考会话才可信。
  bool isTrustedAt(double captureTimestamp) {
    final id = sessionAt(captureTimestamp);
    return id != null && id == referenceSessionId;
  }
}

// ════════════════════════════════════════════════════════════════════════
// 二、逐张会话记录(official_device_sessions.jsonl)
// ════════════════════════════════════════════════════════════════════════

/// 一行记录。[deviceSessionId] 为 null(待判定)时写成 JSON null,
/// 重喂时按"归属不明"处理(永不可信)。
String encodeDeviceSessionLedgerLine({
  required String photoName,
  required String? deviceSessionId,
  required double captureTimestamp,
  required String source,
}) =>
    '${jsonEncode(<String, Object?>{'photo': photoName, 'deviceSessionId': deviceSessionId, 'captureTimestamp': captureTimestamp, 'source': source})}\n';

/// 照片名 → 会话 id(可能为 null = 记录过但归属不明)。同一张多次出现取最后一行。
/// 坏行跳过(账本是 best-effort 追加写的)。
Map<String, String?> parseDeviceSessionLedger(String text) {
  final out = <String, String?>{};
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    try {
      final m = jsonDecode(line);
      if (m is! Map<String, dynamic>) continue;
      final photo = m['photo'];
      if (photo is! String || photo.isEmpty) continue;
      final id = m['deviceSessionId'];
      out[photo.split('/').last] = id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      continue;
    }
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════
// 三、整项目重喂:分组 + 选参考
// ════════════════════════════════════════════════════════════════════════

/// 一张项目照片的会话证据(调用方按拍摄序 tap-N 排好)。
class DevicePoseSessionEvidence {
  const DevicePoseSessionEvidence({
    required this.photoName,
    required this.captureTimestamp,
    this.hasRecord = false,
    this.recordedSessionId,
  });

  final String photoName;

  /// sidecar `t`(设备位姿时钟,开机秒数;重启归零)。
  final double captureTimestamp;

  /// [kDeviceSessionLedgerFileName] 里有这张的记录。
  final bool hasRecord;

  /// 记录里的会话 id;[hasRecord] 且为 null = 拍的时候归属就不明。
  final String? recordedSessionId;
}

/// 重喂的信任计划。
class DevicePoseTrustPlan {
  const DevicePoseTrustPlan({
    required this.sessionOf,
    required this.sessionSizes,
    required this.referenceSession,
    required this.notes,
  });

  /// 照片名 → 会话键。
  final Map<String, String> sessionOf;

  /// 会话键 → 张数(按首次出现顺序)。
  final Map<String, int> sessionSizes;

  /// null = 没有任何会话够 [kDevicePoseAlignMinPairs] 张且有归属证据。
  final String? referenceSession;

  /// 人话账(进设备日志)。
  final List<String> notes;

  bool isTrusted(String photoName) {
    final ref = referenceSession;
    return ref != null && sessionOf[photoName.split('/').last] == ref;
  }

  int get sessionCount => sessionSizes.length;

  int get trustedCount {
    final ref = referenceSession;
    return ref == null ? 0 : (sessionSizes[ref] ?? 0);
  }
}

bool _isUnprovenKey(String k) =>
    k.startsWith('unproven:') || k.startsWith('unknown:');

/// 分组 + 选参考。
///
/// 分组(按证据强弱,只信证据):
///  1. 有逐张记录([DevicePoseSessionEvidence.hasRecord])→ 按记录的会话 id;
///     记录为 null(拍时待判定)→ 自成一组、永不可信。
///  2. 旧照片(没有记录):
///     • 时钟倒退(sidecar `t` 沿 tap-N 变小)= 中间重启过 —— ARKit 时间戳是
///       开机秒数,同一次开机内单调(archived_photo_rebuild.dart `orderForRefeed`
///       注释里的实测:t≈47901 → 补拍 t≈2145)。
///     • 若没有任何多会话痕迹([legacyMultiSessionTrace] 为 false 且无时钟倒退)
///       → 按时钟段分组(正常单次拍摄 = 一组,全部可信,行为与改前一致)。
///     • 若有痕迹 → 只认**证据**:一份"实拍账本"(拍摄期的 fed-frames 账本;
///       与别的账本有交集的是重喂账本,不算)覆盖的照片,加上 tap-N 落在它首尾
///       之间、且中间没有时钟倒退的照片,是同一个会话 —— tap-N 由采集会话单调
///       发放、会话之间不交错(photo_slot_naming.dart `frameSeqInName` 注释)。
///       其余旧照片归属未证实 → 各自成组、永不可信。
/// 选参考:有归属证据的组里张数最多且 ≥ [kDevicePoseAlignMinPairs];并列取
/// 最早开拍的(文件头"参考会话怎么选")。
DevicePoseTrustPlan planDevicePoseTrust({
  required List<DevicePoseSessionEvidence> shotsInOrder,
  List<Set<String>> ledgerPhotoSets = const <Set<String>>[],
  bool legacyMultiSessionTrace = false,
}) {
  final n = shotsInOrder.length;
  final names = [for (final s in shotsInOrder) s.photoName.split('/').last];
  final keys = List<String?>.filled(n, null);
  final notes = <String>[];

  // 时钟段:沿拍摄序,t 变小就换段。
  final clockSeg = List<int>.filled(n, 0);
  var reversals = 0;
  for (var i = 1; i < n; i++) {
    final back =
        shotsInOrder[i].captureTimestamp < shotsInOrder[i - 1].captureTimestamp;
    if (back) reversals++;
    clockSeg[i] = clockSeg[i - 1] + (back ? 1 : 0);
  }

  // 1. 有记录的照片。
  for (var i = 0; i < n; i++) {
    final s = shotsInOrder[i];
    if (!s.hasRecord) continue;
    final id = s.recordedSessionId;
    keys[i] = id == null ? 'unknown:${names[i]}' : 'rec:$id';
  }

  // 2. 旧照片。
  final legacy = [
    for (var i = 0; i < n; i++)
      if (keys[i] == null) i,
  ];
  if (legacy.isNotEmpty) {
    final trace = legacyMultiSessionTrace || reversals > 0;
    if (!trace) {
      for (final i in legacy) {
        keys[i] = 'clk:${clockSeg[i]}';
      }
    } else {
      // 实拍账本:与其它账本两两不相交的那些(从小到大贪心;重喂账本包含了
      // 各次实拍的照片,必然与它们相交而被排除)。
      final sets =
          ledgerPhotoSets
              .map((s) => s.map((p) => p.split('/').last).toSet())
              .where((s) => s.isNotEmpty)
              .toList()
            ..sort((a, b) => a.length.compareTo(b.length));
      final live = <Set<String>>[];
      for (final s in sets) {
        if (live.every((o) => o.intersection(s).isEmpty)) live.add(s);
      }
      final ranges = <({int lo, int hi})>[];
      for (final s in live) {
        final idx = [
          for (final i in legacy)
            if (s.contains(names[i])) i,
        ];
        if (idx.isEmpty) continue;
        final lo = idx.first, hi = idx.last;
        // 账本自己跨了重启 ⇒ 不是一次实拍,不作证据。
        if (clockSeg[lo] != clockSeg[hi]) {
          notes.add('账本 ${s.length} 张跨越时钟倒退,不作会话证据');
          continue;
        }
        // 区间里夹着有记录的照片 ⇒ 数据自相矛盾,不作证据。
        var mixed = false;
        for (var i = lo; i <= hi; i++) {
          if (!legacy.contains(i)) mixed = true;
        }
        if (mixed) continue;
        ranges.add((lo: lo, hi: hi));
      }
      // 区间两两重叠 ⇒ 两边都不作证据。
      final ok = List<bool>.filled(ranges.length, true);
      for (var a = 0; a < ranges.length; a++) {
        for (var b = a + 1; b < ranges.length; b++) {
          if (ranges[a].lo <= ranges[b].hi && ranges[b].lo <= ranges[a].hi) {
            ok[a] = false;
            ok[b] = false;
          }
        }
      }
      var proved = 0;
      for (var r = 0; r < ranges.length; r++) {
        if (!ok[r]) continue;
        proved++;
        for (var i = ranges[r].lo; i <= ranges[r].hi; i++) {
          keys[i] = 'live:$r';
        }
      }
      var unproven = 0;
      for (final i in legacy) {
        if (keys[i] == null) {
          keys[i] = 'unproven:${names[i]}';
          unproven++;
        }
      }
      notes.add(
        '旧照片有多会话痕迹(时钟倒退 $reversals 处'
        '${legacyMultiSessionTrace ? ",有补拍/重喂/孤儿恢复痕迹" : ""}):'
        '实拍账本证实 $proved 段,'
        '$unproven 张归属未证实',
      );
    }
  }

  final sizes = <String, int>{};
  final firstIndex = <String, int>{};
  final sessionOf = <String, String>{};
  for (var i = 0; i < n; i++) {
    final k = keys[i]!;
    sizes[k] = (sizes[k] ?? 0) + 1;
    firstIndex.putIfAbsent(k, () => i);
    sessionOf[names[i]] = k;
  }
  String? ref;
  for (final k in sizes.keys) {
    if (_isUnprovenKey(k)) continue;
    if (sizes[k]! < kDevicePoseAlignMinPairs) continue;
    if (ref == null ||
        sizes[k]! > sizes[ref]! ||
        (sizes[k]! == sizes[ref]! && firstIndex[k]! < firstIndex[ref]!)) {
      ref = k;
    }
  }
  final proven = sizes.keys.where((k) => !_isUnprovenKey(k)).length;
  final unprovenPhotos = sizes.entries
      .where((e) => _isUnprovenKey(e.key))
      .fold<int>(0, (a, e) => a + e.value);
  notes.add(
    '设备会话 $proven 个'
    '${unprovenPhotos > 0 ? " + 归属未证实 $unprovenPhotos 张" : ""};'
    '参考=${ref ?? "无(没有 ≥$kDevicePoseAlignMinPairs 张的会话)"}'
    '${ref == null ? "" : " ${sizes[ref]} 张"};'
    '可信 ${ref == null ? 0 : sizes[ref]}/$n',
  );
  return DevicePoseTrustPlan(
    sessionOf: sessionOf,
    sessionSizes: sizes,
    referenceSession: ref,
    notes: notes,
  );
}

/// 「这份新账本的参考会话不是它里面最大的会话」—— 拍摄期实时那一路只能信
/// 本场**第一个**会话;第一个会话很小(甚至 <3 张)时照 db 续跑会让 Sim3 对得很少
/// 或对不上。收尾本该走整项目重喂重新定参考(ar_capture_page
/// `multiDeviceSessionTake`),若 App 在那之前被杀,就由「开始训练」的覆盖度
/// 判据送去重喂。**不会混会话**(非参考帧的信任位已随帧存进核),只是参考不优。
/// 规则与 [planDevicePoseTrust] 同一条:有会话 id 的行按会话计数,参考 = 含可信帧
/// 的那个会话;它若不是 ≥[kDevicePoseAlignMinPairs] 张里最大的 ⇒ 需要重排。
bool ledgerNeedsDeviceSessionReplan(String fedFramesJsonl) {
  final counts = <String, int>{};
  final trustedSessions = <String>{};
  for (final line in const LineSplitter().convert(fedFramesJsonl)) {
    if (line.trim().isEmpty) continue;
    try {
      final m = jsonDecode(line);
      if (m is! Map<String, dynamic>) continue;
      final id = m['deviceSessionId'];
      if (id is! String || id.isEmpty) continue;
      if (_isUnprovenKey(id)) continue;
      counts[id] = (counts[id] ?? 0) + 1;
      if (m['devicePoseTrusted'] == true) trustedSessions.add(id);
    } catch (_) {
      continue;
    }
  }
  if (counts.length < 2) return false;
  if (trustedSessions.length > 1) return true;
  final largest = counts.values.reduce((a, b) => a > b ? a : b);
  if (largest < kDevicePoseAlignMinPairs) return false;
  if (trustedSessions.isEmpty) return true;
  return counts[trustedSessions.first]! < largest;
}

/// 「这份 fed-frames 账本可能混了多个设备会话、又没记信任位」—— 这种 db 不能
/// 照 db 续跑(续跑会把混进来的旧世界位姿原样再用一遍)。
///
/// 只用廉价证据(长按菜单弹出前要跑):账本里有行没写 `devicePoseTrusted`
/// (改前写的),且 ① 有 `.dead-*` 账本(补拍开场或整项目重喂都会挪一次,
/// sfm_resume.dart `sidelineDatabaseForFreshSession`),或 ② 账本自己的
/// captureTimestamp 沿 tap-N 倒退(中间重启过)。
bool legacyLedgerMayMixDeviceSessions(
  String fedFramesJsonl, {
  required bool deadLedgersPresent,
  required int? Function(String photoName) frameSeqOf,
}) {
  var anyLine = false;
  var lacksTrust = false;
  final rows = <({int seq, double t})>[];
  for (final line in const LineSplitter().convert(fedFramesJsonl)) {
    if (line.trim().isEmpty) continue;
    try {
      final m = jsonDecode(line);
      if (m is! Map<String, dynamic>) continue;
      anyLine = true;
      if (!m.containsKey('devicePoseTrusted')) lacksTrust = true;
      final p = m['jpegPath'];
      final t = m['captureTimestamp'];
      if (p is String && t is num) {
        final seq = frameSeqOf(p.split('/').last);
        if (seq != null) rows.add((seq: seq, t: t.toDouble()));
      }
    } catch (_) {
      continue;
    }
  }
  if (!anyLine || !lacksTrust) return false;
  if (deadLedgersPresent) return true;
  rows.sort((a, b) => a.seq.compareTo(b.seq));
  for (var i = 1; i < rows.length; i++) {
    if (rows[i].t < rows[i - 1].t) return true;
  }
  return false;
}
