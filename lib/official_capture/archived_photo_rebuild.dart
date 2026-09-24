// archived_photo_rebuild.dart — 从**存档照片**重建(纯函数部分)。
//
// [2026-09-08 实机定罪] 「未完成」项目的真正成因不是"重建被打断、还能续跑",
// 而是 **db 压根没写成**:拍摄被杀时(闪退 / jetsam / 用户划掉),流式核写进
// sqlite 的东西还压在一个没提交的长事务里,进程一死全没。三方对照:
//   跑完 finalize 的  db=41 MB, wal=0,  有 .work.tmp, 有 PLY
//   被杀的两个        db=4096(1 页), wal=32 KB, 无 .work.tmp, 无 PLY
// 那个 4096 字节的 db **单独拿出来(不带 wal / 不带 shm)也是 malformed**,
// `sqlite3 .recover` 抢不出任何表。
//
// ⇒ 对这些项目,「开始训练」和「补拍」都必然 `aether_sfm_create: errDb` ——
//   两条路都建立在"db 里有东西"这个前提上,而该前提不成立。
//
// **但原料没丢**:照片和每张的 ARKit 位姿/内参都完整留在 `photos_highres/`。
// 所以解药是把存档照片重新喂一遍 —— 这就是本文件。
//
// 本文件只做**解析与判据**(纯 Dart、零 IO 依赖、可在 host 上穷举断言);
// 真正的喂帧与 finalize 在 sfm_resume.dart,走与拍摄期**完全同一条**
// `offerFrame` 路径。

import 'dart:convert';

import 'official_highres_reconstruction_input.dart';
import 'photo_slot_naming.dart';

/// 一张存档照片解析出来的喂帧输入,或一条**带原因**的拒绝。
///
/// 失败必须带原因、必须逐张可见:跳过一张就少救一张,而用户无从察觉 ——
/// 静默出口是本项目的头号复发缺陷。
class ArchivedPhotoParse {
  const ArchivedPhotoParse.accepted(this.jpegPath, this.input)
    : failure = null;
  const ArchivedPhotoParse.rejected(this.jpegPath, this.failure) : input = null;

  final String jpegPath;
  final OfficialHighResReconstructionInput? input;

  /// 人类可读的拒绝原因(已含字段名);accepted 时为 null。
  final String? failure;

  bool get isAccepted => input != null;
}

/// 把一张照片的 sidecar JSON 解析成喂帧输入。
///
/// **位姿约定(已实测验证,不是推断)**:sidecar 的 `extrinsic` 是 16 个 double 的
/// **列主序 camera-to-world** 矩阵,与 `offerFrame` 期望的 `cameraTransform`
/// 逐字段同构 —— 所以这里**原样透传**,不做任何转换。
///
/// 验证方法(2026-09-08,cap_1788845271610360):拿 `official_sfm_fed_frames.jsonl`
/// 里**已知约定**的记录当标尺(它明写 "CamFromWorld inverted from ARKit
/// cameraToWorld"),把 sidecar 的 extrinsic 按"列主序 cam2world 再求逆"换算成
/// 四元数与之对拍 —— 4/4 张误差 **0.000000**;而按"extrinsic 本身就是
/// CamFromWorld"解释则差 **1.29–1.40**。⇒ 约定是验出来的,不是猜的。
/// 这处若弄反,不会报错,只会出一朵歪的点云。
///
/// **为什么读 sidecar 而不读 fed_frames.jsonl**:jsonl 只记**已经喂进去**的帧,
/// 被杀时还在队列里的照片它没有(实测该项目 9 张照片 / jsonl 仅 6 条)。
/// 读 jsonl 会少救 3 张,而且少得悄无声息。
ArchivedPhotoParse parseArchivedPhoto({
  required String jpegPath,
  required String sidecarJson,
}) {
  final Map<String, dynamic> j;
  try {
    final decoded = jsonDecode(sidecarJson);
    if (decoded is! Map<String, dynamic>) {
      return ArchivedPhotoParse.rejected(jpegPath, 'sidecar 不是 JSON 对象');
    }
    j = decoded;
  } catch (e) {
    return ArchivedPhotoParse.rejected(jpegPath, 'sidecar 解析失败: $e');
  }

  List<double>? doubles(Object? v, int want) {
    if (v is! List || v.length < want) return null;
    final out = <double>[];
    for (final e in v.take(want)) {
      if (e is num && e.toDouble().isFinite) {
        out.add(e.toDouble());
      } else {
        return null;
      }
    }
    return out;
  }

  final intrinsics = doubles(j['intrinsics_fxfycxcy'], 4);
  if (intrinsics == null) {
    return ArchivedPhotoParse.rejected(jpegPath, '缺 intrinsics_fxfycxcy');
  }
  final transform = doubles(j['extrinsic'], 16);
  if (transform == null) {
    return ArchivedPhotoParse.rejected(jpegPath, '缺 extrinsic(16 个有限数)');
  }
  final w = j['image_w'];
  final h = j['image_h'];
  if (w is! int || h is! int) {
    return ArchivedPhotoParse.rejected(jpegPath, '缺 image_w/image_h');
  }
  // `t` = 这一帧真正拍成的时刻;`save_target_t` = 快门请求的目标时刻。
  // validate() 两个都要,且只判有限性(相机流水线延迟不是失同步,见其注释)。
  final captureT = j['t'];
  final triggerT = j['save_target_t'] ?? captureT;
  if (captureT is! num || triggerT is! num) {
    return ArchivedPhotoParse.rejected(jpegPath, '缺时间戳 t / save_target_t');
  }

  // [DEVICE-SESSION 2026-09-24] 这张照片**自己那一帧**的追踪状态(原生 sidecar
  // 同一 ARFrame 写下的 `trackingStateName` / `tracking_state`)。不传的话
  // validate 按缺失 fail-closed ⇒ 整项目重喂的每一帧都不可信、一对 Sim3 都
  // 没有(A 的判据,device_pose_trust.dart)。
  final tracking = j['trackingStateName'] ?? j['tracking_state'];
  final v = OfficialHighResReconstructionInput.validate(
    jpegPath: jpegPath,
    imageWidth: w,
    imageHeight: h,
    triggerTimestamp: triggerT.toDouble(),
    captureTimestamp: captureT.toDouble(),
    cameraTransform: transform,
    intrinsics: intrinsics,
    trackingStateName: tracking is String ? tracking : null,
  );
  final input = v.input;
  if (input == null) {
    // 复用拍摄期同一个 validate —— 判据只有一处,不另立标准。
    return ArchivedPhotoParse.rejected(jpegPath, 'validate 拒绝: ${v.failure}');
  }
  return ArchivedPhotoParse.accepted(jpegPath, input);
}

/// 喂帧顺序 = 按文件名里的**帧序号 N 数值**升序。
///
/// 三个候选键,只有 N 站得住:
///  · **字符串序**:会把 `tap-99` 排在 `tap-129` 之后 —— 直接排错。
///  · **拍摄时刻 `t`**:`t` 是 ARKit 的 uptime 时钟,**跨会话归零**,而补拍
///    天然跨会话。实测 cap_1788845271610360:tap-1..182 的 t≈47901,补拍进来的
///    tap-203/226/233 t≈2145(晚 36 分钟、中间重启过)—— 按 t 排会把补拍那三张
///    排到最前面。(本函数最初就是按 t 排的,是这份真机数据把它推翻的。)
///  · **N**:由采集会话单调发放,补拍时 `maxFrameSeqInNames` 接着往上排,
///    所以 N 是我们自己保证的全局拍摄序,不依赖任何时钟。
///
/// 顺序错了不会报错,但流式匹配的时序候选窗口(k_neighbors)会挑错邻居。
/// 认不出 N 的名字(老式 `cell_i_slot_j`)排在最后,并按 `t` 再按路径稳定排序 ——
/// 排到最后而不是丢掉:少喂一张就少救一张。
List<ArchivedPhotoParse> orderForRefeed(Iterable<ArchivedPhotoParse> parses) {
  final list = parses.toList();
  int seqOf(ArchivedPhotoParse p) =>
      frameSeqInName(p.jpegPath.split('/').last) ?? (1 << 31);
  list.sort((a, b) {
    final c = seqOf(a).compareTo(seqOf(b));
    if (c != 0) return c;
    final ai = a.input, bi = b.input;
    if (ai != null && bi != null) {
      final d = ai.captureTimestamp.compareTo(bi.captureTimestamp);
      if (d != 0) return d;
    }
    return a.jpegPath.compareTo(b.jpegPath);
  });
  return list;
}

// ════════════════════════════════════════════════════════════════════════
// 「这个 db 覆盖了盘上所有照片吗」—— 路由判据的第二条腿。
//
// [2026-09-11 实机定罪] 用户报「未命名(8) 分两次拍，前 20 帧好像没参与训练」。
// 查实:确实一张都没参与。设备日志的完整时序:
//     13:49:42  第一次拍摄,打了 20 次快门,喂进去 14 帧
//     13:50:22  日志戛然而止(thermal=serious / mem peak 1803MB,无 finalize、
//               无 dispose、无 Uncaught)⇒ 被系统杀掉,db 落成 0 字节
//     13:55:00  用户点「拍摄更多照片」→ 补拍只把老照片 adopt 进**相册**,
//               一帧都没喂给重建;新会话在同一个 db 上从 frameId 0 重新数
//     13:55:21  拍摄结束自动 finalize(live_reuse)⇒ 交付的云只有那 6 张新照片
// 结果:`n_registered=6`、db 的 images 表只有 6 行、4538 点;而第一次拍摄当时
// 屏幕上的实时云是 **12808 点 / 14 帧**。26 张里 20 张颗粒无收。
//
// 光有 sqlite_db_health 那条判据挡不住这个:事后那个 db **头完全自洽**
// (3032 页对 3032 页),它只是「健全但只装了 6 张」。所以「开始训练」要再问
// 一句:**这个 db 覆盖盘上所有照片吗**。
//
// 🔴 为什么不直接数 db 的 images 行数:ABI 里没有「只看一眼 db」的导出,
// 加一个就是原生改动(还会打破 DART_ONLY 的装机形态);纯 Dart 数 sqlite 的
// b-tree 是另一个真相源。所以改用**我们自己记的账**:`official_sfm_fed_frames.jsonl`
// 由 native 每注册一帧追加一行(frameId + jpegPath),它就是「这个 db 里有谁」。

/// 一个项目的「db 覆盖度」判定,带原因。
class ProjectCoverage {
  const ProjectCoverage({
    required this.photosOnDisk,
    required this.fedDistinct,
    required this.duplicateFrameIds,
    required this.neverFed,
    this.ledgerMayMixDeviceSessions = false,
  });

  final int photosOnDisk;

  /// 账本里出现过的**不同**照片数。
  final int fedDistinct;

  /// 账本里 frameId 的重复次数。>0 = 这份账跨了不止一个会话。
  final int duplicateFrameIds;

  /// 盘上有、账本里却没有的照片名(排序后)。
  final List<String> neverFed;

  /// [DEVICE-SESSION 2026-09-24] 第三条腿:这个 db 是改前写的(账本没有信任位)
  /// 且有多会话痕迹 —— 照 db 续跑会把混进来的旧世界位姿原样再用一遍
  /// (device_pose_session.dart legacyLedgerMayMixDeviceSessions)。
  final bool ledgerMayMixDeviceSessions;

  /// 覆盖齐 ⇒ 可以照 db 续跑;否则必须全量重喂。
  bool get covered =>
      neverFed.isEmpty &&
      duplicateFrameIds == 0 &&
      !ledgerMayMixDeviceSessions;

  /// 不齐的原因(人话);覆盖齐时为 null。
  String? get reason {
    if (covered) return null;
    final parts = <String>[];
    if (neverFed.isNotEmpty) parts.add('盘上有 ${neverFed.length} 张没喂过');
    if (duplicateFrameIds > 0) {
      parts.add('账本 frameId 重复 $duplicateFrameIds 次(跨了多个会话)');
    }
    if (ledgerMayMixDeviceSessions) {
      parts.add('db 可能混了多个设备跟踪会话且没记信任位');
    }
    return parts.join(' | ');
  }
}

/// 纯判据:盘上的照片名 × `official_sfm_fed_frames.jsonl` 全文 → 覆盖度。
///
/// 两条独立的腿,任一条命中就判「不齐」:
///  ① **盘上有照片从没出现在账本里** —— 它必然不在 db 里。
///  ② **账本里 frameId 有重复** —— frameId 是**每会话从 0 重数**的
///    (`official_aether_sfm_c.cc:9266  frame_id = s->frames.size()`),
///    所以重复 = 这份账被两个会话写过 = 它已经描述不了当前这个 db。
///    这条是必须的:①单独不够,账本只会**高估**覆盖(老会话的行还在,
///    而它们对应的 db 行可能早没了),高估正是危险的那个方向。
///
/// **真机标定(2026-09-11,设备上全部 7 个项目)**:
///   未命名(1)(89 张)/(2)(35)/(3)(20)/(4)(20)/(5)(20)/(6)(35) —— 六个健康项目
///   盘上数 == 账本数 == 独立数,重复 frameId **全为 0** ⇒ 一个都不误报;
///   未命名(8)(26 张) —— **两条腿各自独立命中**(6 张没喂过、6 次 fid 重复)。
/// 阈值不是我定的,是这组数据分出来的。
ProjectCoverage projectCoverageFrom({
  required Iterable<String> jpegNamesOnDisk,
  required String fedFramesJsonl,
  bool ledgerMayMixDeviceSessions = false,
}) {
  final fedNames = <String>{};
  final frameIdCounts = <int, int>{};
  for (final line in const LineSplitter().convert(fedFramesJsonl)) {
    if (line.trim().isEmpty) continue;
    try {
      final m = jsonDecode(line);
      if (m is! Map<String, dynamic>) continue;
      final path = m['jpegPath'];
      if (path is String && path.isNotEmpty) {
        fedNames.add(path.split('/').last);
      }
      final fid = m['frameId'];
      if (fid is int) frameIdCounts[fid] = (frameIdCounts[fid] ?? 0) + 1;
    } catch (_) {
      // 坏行不算数,但也不能让整条判据崩 —— 账本是 best-effort 追加写的。
      continue;
    }
  }
  var dup = 0;
  for (final n in frameIdCounts.values) {
    if (n > 1) dup += n - 1;
  }
  final disk = jpegNamesOnDisk.toSet();
  final never = disk.difference(fedNames).toList()..sort();
  return ProjectCoverage(
    photosOnDisk: disk.length,
    fedDistinct: fedNames.length,
    duplicateFrameIds: dup,
    neverFed: never,
    ledgerMayMixDeviceSessions: ledgerMayMixDeviceSessions,
  );
}
