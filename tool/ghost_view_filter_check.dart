// tool/ghost_view_filter_check.dart — L2 渲染门(ghost_view_filter.dart)
// 纯 Dart VM 断言(host `dart tool/ghost_view_filter_check.dart`;项目惯例
// 同 tool/photo_slot_naming_check.dart)。
//
// 规则(鬼层歼灭战 07-12,用户签决「只藏确证鬼、放行所有 2-view 好点」):
//   visible = ¬band15 ∨ rescued   ⇔   hidden = band15 ∧ ¬rescued
// 覆盖铁律:
//   1. 开关开(默认 true,可见性数组生效)时:band15∧¬rescued 确证鬼点不进
//      渲染 buffer;band15∧rescued(L1 白名单)与所有 2-view 好点照进 buffer;
//   2. 开关关(visibility=null)时:全量进渲染 buffer;
//   3. 导出永远全量:交付/持久化路径(sparse_ply/sfm_resume/上传)在源码
//      层面 0 引用渲染门,可见性数组无从影响导出。
// 外加:sidecar 容错(缺失/点数错位 → 全显示)、谓词逐点语义、孤点过滤
// keepIdx 压实对齐、开关默认 true 且只此一处定义(禁用户滑杆铁律)。

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
    if (vis != null && vis[i] == 0) continue; // L2 渲染门:确证鬼点不进 buffer
    out.add(i);
  }
  return out;
}

void main() {
  // ── 合成点云:6 点覆盖全部谓词分支 ──────────────────────────────────
  //   0: 干净                       → 可见
  //   1: band15、无救援              → hidden(确证鬼)
  //   2: 干净(代表 2-view 好点)     → 可见(2-view 不再被当低质量隐藏)
  //   3: 干净 + 救援位               → 可见(非 band15,救援位无影响)
  //   4: band15 + 救援位             → 可见(rescue 白名单放行,新规则关键翻转)
  //   5: cell_ghost/band10 参考位     → 可见(渲染门只消费 band15)
  final flags = Uint8List.fromList([
    kGhostFlagInRegion,
    kGhostFlagInRegion | kGhostFlagBand15,
    kGhostFlagInRegion,
    kGhostFlagInRegion | kGhostFlagRescued,
    kGhostFlagInRegion | kGhostFlagBand15 | kGhostFlagRescued,
    kGhostFlagInRegion | kGhostFlagCellGhost | kGhostFlagBand10,
  ]);
  final n = flags.length;

  // ── 谓词语义 ────────────────────────────────────────────────────────
  final gv = computeGhostViewVisibility(flags);
  check(gv.visibility.length == n, '可见性数组与点数逐位对齐($n)');
  check(
    gv.visibility[0] == 1 &&
        gv.visibility[2] == 1 &&
        gv.visibility[3] == 1 &&
        gv.visibility[4] == 1 &&
        gv.visibility[5] == 1 &&
        gv.visibility[1] == 0,
    '谓词逐点:仅 band15∧¬rescued(点1)隐藏;干净/2-view/rescue白名单/参考位可见',
  );
  check(gv.stats.hiddenGhost == 1, 'hidden_ghost=1(band15∧¬rescued)');
  check(
    gv.stats.rescuedVisible == 1,
    'rescued_visible=1(band15∧rescued → 白名单放行,不算隐藏)',
  );
  check(gv.stats.shown == 5, 'shown=5 = n − hidden_ghost(2-view 零隐藏)');

  // ── 2-view 好点零隐藏(核心签决):无 obs 依赖,隐藏集 ⊆ band15 ────────
  // 遍历确认每个被隐藏的点都是 band15(没有任何点因 2-view/低 track 被隐藏)。
  for (var i = 0; i < n; i++) {
    if (gv.visibility[i] == 0) {
      check(
        flags[i] & kGhostFlagBand15 != 0 && flags[i] & kGhostFlagRescued == 0,
        '隐藏点 $i 必为 band15∧¬rescued(绝不因 2-view 隐藏)',
      );
    }
  }

  // ── 渲染 buffer(painter 同款门)─────────────────────────────────────
  final onIdx = renderBufferIndices(n, gv.visibility);
  check(
    !onIdx.contains(1) && onIdx.contains(4),
    '开关开:band15∧¬rescued(1)不进 buffer;band15∧rescued(4)照进',
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
  // 向同一批点:原点 1 隐藏 → 压实后索引 1 隐藏,其余可见(含点4 rescue)。
  final keepIdx = Int32List.fromList([0, 1, 3, 4, 5]);
  final compactVis = compactVisibilityByIndices(gv.visibility, keepIdx);
  check(
    compactVis.length == keepIdx.length &&
        compactVis[0] == 1 &&
        compactVis[1] == 0 &&
        compactVis[2] == 1 &&
        compactVis[3] == 1 &&
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

  // ── 源码层断言:交付路径 0 引用渲染门 + 开关默认开且只此一处 ─────────
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
        modSrc.contains('defaultValue: true'),
    '开关 kGhostMaskViewFilter = env 式编译期常量,默认 true(用户签决开门)',
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
