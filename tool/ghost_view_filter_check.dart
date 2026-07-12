// tool/ghost_view_filter_check.dart — L2 渲染门(ghost_view_filter.dart)
// 纯 Dart VM 断言(host `dart tool/ghost_view_filter_check.dart`;项目惯例
// 同 tool/photo_slot_naming_check.dart)。
//
// 覆盖任务③的三条铁律:
//   1. 开关开(可见性数组生效)时:ghost 隐藏候选点不进渲染 buffer;
//   2. 开关关(visibility=null)时:全量进渲染 buffer;
//   3. 导出永远全量:交付/持久化路径(sparse_ply/sfm_resume/上传)在源码
//      层面 0 引用渲染门,可见性数组无从影响导出。
// 外加:sidecar 容错(缺失/点数错位 → 全显示)、谓词语义(band15 隐藏、
// obs<3 未救援隐藏、救援位救回、obs 未知恒真)、孤点过滤 keepIdx 压实
// 对齐、开关默认 false 且只此一处定义(禁用户滑杆铁律)。

import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/floater_filter.dart';
import 'package:pocketworld_flutter/capture/ghost_view_filter.dart';

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('FAIL: $what');
  }
  // ignore: avoid_print
  print('ok: $what');
}

/// 复刻 SparseCloudPainter.paint 的渲染门(同一行语义:
/// `if (vis != null && vis[i] == 0) continue;`)—— 返回进渲染 buffer 的
/// 点索引。stride=1(渲染抽稀与本门正交)。
List<int> renderBufferIndices(int n, Uint8List? visibility) {
  final vis =
      visibility != null && visibility.length == n ? visibility : null;
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    if (vis != null && vis[i] == 0) continue; // L2 渲染门:ghost 点不进 buffer
    out.add(i);
  }
  return out;
}

void main() {
  // ── 合成点云:6 点覆盖全部谓词分支 ──────────────────────────────────
  //   0: 干净、obs=5            → 可见
  //   1: band15 鬼候选、obs=5    → hidden_ghost
  //   2: 干净、obs=2、无救援     → hidden_lowtrack
  //   3: 干净、obs=2、救援位     → rescued_visible(可见)
  //   4: band15 且救援位、obs=5  → 仍 hidden_ghost(¬ghost 是 AND 项)
  //   5: cell_ghost/band10 参考位、obs=3 → 可见(渲染门只消费 band15)
  final flags = Uint8List.fromList([
    kGhostFlagInRegion,
    kGhostFlagInRegion | kGhostFlagBand15,
    kGhostFlagInRegion,
    kGhostFlagInRegion | kGhostFlagRescued,
    kGhostFlagInRegion | kGhostFlagBand15 | kGhostFlagRescued,
    kGhostFlagInRegion | kGhostFlagCellGhost | kGhostFlagBand10,
  ]);
  final obs = Int32List.fromList([0, 5, 10, 12, 14, 19, 22]); // CSR,长度 n+1
  final n = flags.length;

  // ── 谓词语义 ────────────────────────────────────────────────────────
  final gv = computeGhostViewVisibility(flags, obsOffsets: obs);
  check(gv.visibility.length == n, '可见性数组与点数逐位对齐($n)');
  check(
    gv.visibility[0] == 1 &&
        gv.visibility[3] == 1 &&
        gv.visibility[5] == 1 &&
        gv.visibility[1] == 0 &&
        gv.visibility[2] == 0 &&
        gv.visibility[4] == 0,
    '谓词逐点:干净/救援/参考位可见,band15/低track隐藏',
  );
  check(gv.stats.hiddenGhost == 2, 'hidden_ghost=2(含 ghost∧rescued 仍隐藏)');
  check(gv.stats.hiddenLowTrack == 1, 'hidden_lowtrack=1(obs=2 无救援)');
  check(gv.stats.rescuedVisible == 1, 'rescued_visible=1(obs=2 有救援位)');
  check(gv.stats.shown == 3, 'shown=3 = n − hidden_ghost − hidden_lowtrack');

  // ── obs 未知(渲染层拿不到观测计数)→ 低 track 项恒真 ───────────────
  final gvNoObs = computeGhostViewVisibility(flags);
  check(
    gvNoObs.visibility[2] == 1 && gvNoObs.stats.hiddenLowTrack == 0,
    'obs 未知:低 track 项恒真,只有 band15 过滤生效',
  );
  check(gvNoObs.stats.hiddenGhost == 2, 'obs 未知:ghost 位过滤不受影响');
  // obsOffsets 长度不符(≠ n+1)→ 与未知同语义(容错)。
  final gvBadObs =
      computeGhostViewVisibility(flags, obsOffsets: Int32List.fromList([0, 5]));
  check(gvBadObs.stats.hiddenLowTrack == 0, 'obsOffsets 长度错位 → 低 track 项恒真');

  // ── 渲染 buffer(painter 同款门)─────────────────────────────────────
  final onIdx = renderBufferIndices(n, gv.visibility);
  check(
    !onIdx.contains(1) && !onIdx.contains(4),
    '开关开:band15 鬼候选点(1,4)不进渲染 buffer',
  );
  check(
    onIdx.length == gv.stats.shown,
    '开关开:渲染 buffer 点数 == shown(${gv.stats.shown})',
  );
  final offIdx = renderBufferIndices(n, null);
  check(offIdx.length == n, '开关关(visibility=null):全量 $n 点进渲染 buffer');
  final mismatchIdx = renderBufferIndices(n, Uint8List(n + 3));
  check(mismatchIdx.length == n, '可见性数组长度错位 → painter 整组忽略(全显示)');

  // ── 导出永远全量:可见性对"交付集"零影响(渲染门只在 paint 消费)──
  // 交付集 = xyz/rgb 全量(compactXyzRgbByIndices 只由孤点过滤驱动,与
  // 渲染门无关);这里断言 ghost 全隐藏时交付集仍是全量 n 点。
  final xyz = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    xyz[i * 3] = i.toDouble();
  }
  final rgb = Uint8List(n * 3);
  final allIdx = Int32List(n);
  for (var i = 0; i < n; i++) {
    allIdx[i] = i;
  }
  final delivered = compactXyzRgbByIndices(xyz, rgb, allIdx);
  check(
    delivered.xyz.length == n * 3 && delivered.rgb.length == n * 3,
    '导出全量:交付 xyz/rgb 与渲染门无关,始终 $n 点',
  );

  // ── 孤点过滤 keepIdx 压实对齐 ───────────────────────────────────────
  // 模拟 floater 删掉点 2(保序索引 [0,1,3,4,5]),压实后可见性必须还指
  // 向同一批点:原点 1/4 隐藏 → 压实后索引 1/3 隐藏。
  final keepIdx = Int32List.fromList([0, 1, 3, 4, 5]);
  final compactVis = compactVisibilityByIndices(gv.visibility, keepIdx);
  check(
    compactVis.length == keepIdx.length &&
        compactVis[0] == 1 &&
        compactVis[1] == 0 &&
        compactVis[2] == 1 &&
        compactVis[3] == 0 &&
        compactVis[4] == 1,
    'keepIdx 压实后可见性与显示点序逐位对齐(隐藏跟着点走)',
  );

  // ── sidecar 容错 ────────────────────────────────────────────────────
  final tmp = Directory.systemTemp.createTempSync('ghost_view_filter_check_');
  try {
    check(
      tryLoadGhostMaskSidecar(tmp.path, n) == null,
      'sidecar 缺失 → null(全显示)',
    );
    final f = File('${tmp.path}/$kGhostMaskFileName');
    f.writeAsBytesSync(Uint8List.fromList([...flags, 0, 0])); // 点数错位
    check(
      tryLoadGhostMaskSidecar(tmp.path, n) == null,
      'sidecar 点数不一致(上游删过点)→ 拒用(全显示,绝不隐藏错点)',
    );
    f.writeAsBytesSync(flags);
    final loaded = tryLoadGhostMaskSidecar(tmp.path, n);
    check(
      loaded != null && loaded.length == n && loaded[1] == flags[1],
      'sidecar 点数一致 → 逐字节加载',
    );
    check(tryLoadGhostMaskSidecar(tmp.path, 0) == null, 'n=0 拒用(退化云)');
  } finally {
    tmp.deleteSync(recursive: true);
  }

  // ── 源码层断言:交付路径 0 引用渲染门 + 开关默认关且只此一处 ────────
  final repoRoot = File(Platform.script.toFilePath()).parent.parent.path;
  String src(String rel) => File('$repoRoot/$rel').readAsStringSync();
  for (final rel in [
    'lib/capture/sparse_ply.dart', // PLY 交付写手
    'lib/capture/sfm_resume.dart', // 断点续跑持久化腿
    'lib/capture/cloud_capture_uploader.dart', // 素材上传
  ]) {
    final s = src(rel).toLowerCase();
    check(
      !s.contains('ghost') && !s.contains('visibility'),
      '交付路径 $rel 零引用渲染门(导出永远全量)',
    );
  }
  final viewSrc = src('lib/ui/capture/sparse_cloud_view.dart');
  check(
    RegExp(r'vis\[i\] == 0\) continue')
            .allMatches(viewSrc)
            .length >=
        2,
    'painter 的 paint 与双击拾取都装了渲染门(vis[i]==0 → continue)',
  );
  final modSrc = src('lib/capture/ghost_view_filter.dart');
  check(
    modSrc.contains("'PW_GHOST_VIEW_FILTER'") &&
        modSrc.contains('defaultValue: false'),
    '开关 kGhostMaskViewFilter = env 式编译期常量,默认 false(暗 ship)',
  );
  var defineCount = 0;
  for (final e in Directory('$repoRoot/lib').listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      if (e.readAsStringSync().contains('PW_GHOST_VIEW_FILTER')) {
        defineCount++;
      }
    }
  }
  check(
    defineCount == 1,
    'PW_GHOST_VIEW_FILTER 只在模块内定义一处(无 UI 滑杆/档位,铁律)',
  );

  // ignore: avoid_print
  print('ALL PASS');
}
