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

  // ── [BIT5-FIX 2026-07-12] 仲裁后重算交付 mask:bit5 时序 gap ────────────
  // 病理:交付点序 ghost_view_mask.bin 写在 persist(l1_arbitrate 回写 bit5
  // rescue 约 22s 之前)→ 无救援位,草稿页 hidden=band15(把 L1 救援真点也隐)。
  // 修复:仲裁 done 后按 persist 时保存的同一 native→snap→floater keep 链
  // (GhostDeliveredMaskRemap)把带 bit5 的 native ghost_mask.bin 重排回交付点序。
  // 本节复刻 ar_capture_page._recomputeDeliveredGhostMaskAfterArbitration 的算术。

  // ① cap49 量级头条(恒等 keep 链):2840 band15,仲裁回写 358 个 bit5。
  //    persist 面(无 bit5)hidden=2840;仲裁后重算面 hidden=2482、rescued=358。
  {
    const total = 5000;
    const bandN = 2840;
    const rescueN = 358;
    // native Points3D 序:前 bandN 个是 band15(其余干净);仲裁把前 rescueN
    // 个 band15 置 bit5(真踢脚/台阶白名单)。
    final persistNative = Uint8List(total); // persist 时的 native mask(无 bit5)
    final arbNative = Uint8List(total); // 仲裁回写后的 native mask(带 bit5)
    for (var i = 0; i < total; i++) {
      final band = i < bandN ? kGhostFlagBand15 : 0;
      persistNative[i] = kGhostFlagInRegion | band;
      final rescue = i < rescueN ? kGhostFlagRescued : 0;
      arbNative[i] = kGhostFlagInRegion | band | rescue;
    }
    // 恒等 keep 链(spatial/floater 都没删点):deliveredCount == nativeCount。
    final remap = GhostDeliveredMaskRemap(
      nativeCount: total,
      spatialKeep: null,
      floaterKeep: null,
      deliveredCount: total,
    );
    final persistDelivered = remap.remap(persistNative);
    final arbDelivered = remap.remap(arbNative);
    check(persistDelivered != null && arbDelivered != null,
        'cap49 头条:恒等链 remap 成功(交付点序 == native 点序)');
    final pv = computeGhostViewVisibility(persistDelivered!);
    final av = computeGhostViewVisibility(arbDelivered!);
    check(pv.stats.hiddenGhost == bandN && pv.stats.rescuedVisible == 0,
        'persist 面(无 bit5):hidden=2840、rescued_visible=0(358 救援点被误隐)');
    check(av.stats.hiddenGhost == bandN - rescueN,
        '仲裁后重算面:hidden=${bandN - rescueN}(=2482,非 2840;358 救援点放行)');
    check(av.stats.rescuedVisible == rescueN,
        '仲裁后重算面:rescued_visible=358(band15∧rescued 白名单可见)');
    check(av.stats.shown - pv.stats.shown == rescueN,
        '仲裁重算净放行 = 358 点(shown 增量 == 救援点数,误隐→0)');
  }

  // ② 非恒等两级 keep 链:bit5 必须穿过 spatial + floater 两次重排到达交付点序
  //    的正确位置(证明重算不是只在恒等下成立)。native 10 点,band15∈{2,4,6,8};
  //    spatial 删 native#8,floater 删 snap#5(=native#5);仲裁给 native#6 置
  //    bit5。交付点序 = native[0,1,2,3,4,6,7,9](8 点),band15∈{2,4,6},其中
  //    native#6 落在交付索引 5 且带 rescued。
  {
    Uint8List native({required Set<int> band, Set<int> rescued = const {}}) {
      final f = Uint8List(10);
      for (var i = 0; i < 10; i++) {
        f[i] = kGhostFlagInRegion |
            (band.contains(i) ? kGhostFlagBand15 : 0) |
            (rescued.contains(i) ? kGhostFlagRescued : 0);
      }
      return f;
    }

    const bandSet = {2, 4, 6, 8};
    final persistNative = native(band: bandSet);
    final arbNative = native(band: bandSet, rescued: {6});
    final spatialKeep = Int32List.fromList([0, 1, 2, 3, 4, 5, 6, 7, 9]); // 删#8
    final floaterKeep = Int32List.fromList([0, 1, 2, 3, 4, 6, 7, 8]); // snap 序删#5
    final remap = GhostDeliveredMaskRemap(
      nativeCount: 10,
      spatialKeep: spatialKeep,
      floaterKeep: floaterKeep,
      deliveredCount: 8,
    );
    final pd = remap.remap(persistNative);
    final ad = remap.remap(arbNative);
    check(pd != null && ad != null && pd.length == 8 && ad.length == 8,
        '两级链 remap 成功,交付点序 8 点');
    final pv = computeGhostViewVisibility(pd!);
    final av = computeGhostViewVisibility(ad!);
    check(pv.stats.hiddenGhost == 3 && pv.stats.rescuedVisible == 0,
        '两级链 persist 面:hidden=3(交付 band15 = native{2,4,6})、rescued=0');
    check(av.stats.hiddenGhost == 2 && av.stats.rescuedVisible == 1,
        '两级链仲裁面:hidden=2、rescued_visible=1(native#6 的 bit5 穿链到达)');
    // native#6 → 交付索引 5:persist 面隐藏、仲裁面可见(bit5 精确落位)。
    final pView = computeGhostViewVisibility(pd);
    final aView = computeGhostViewVisibility(ad);
    check(pView.visibility[5] == 0 && aView.visibility[5] == 1,
        '救援位精确落位:交付索引 5(native#6)persist 隐 → 仲裁后放行');
  }

  // ③ 容错:native mask 点数与配方 nativeCount 不符(过期/错配)→ remap 返回
  //    null(调用方保留 persist 版本交付 mask,绝不隐藏错点)。
  {
    final remap = GhostDeliveredMaskRemap(
      nativeCount: 100,
      spatialKeep: null,
      floaterKeep: null,
      deliveredCount: 100,
    );
    check(remap.remap(Uint8List(101)) == null,
        'nativeCount 错位 → remap=null(fail-open,保留 persist 交付 mask)');
    check(remap.remap(Uint8List(100)) != null, '点数一致 → remap 成功');
    // deliveredCount 与链推出的长度不符也返回 null(自检兜底)。
    final badDelivered = GhostDeliveredMaskRemap(
      nativeCount: 100,
      spatialKeep: null,
      floaterKeep: null,
      deliveredCount: 99, // 与恒等链输出长度 100 不符
    );
    check(badDelivered.remap(Uint8List(100)) == null,
        'deliveredCount 自检不符 → remap=null');
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
