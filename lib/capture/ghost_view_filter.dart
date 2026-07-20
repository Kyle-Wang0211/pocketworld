// ghost_view_filter.dart — L2 渲染门的 Dart 侧可见性谓词层(暗 ship)。
//
// 鬼层歼灭战(07-12)L2:渲染门 = 构造性 100% 不可见 —— COLMAP GUI
// display-only 范式,数据全量不动。本模块只产出"渲染期跳过哪些点"的
// per-point 可见性数组;任何交付/导出路径(sfm_sparse.ply、sfm_live.db、
// 上传素材)绝不消费它(tool/ghost_view_filter_check.dart 有断言)。
//
// 语义源(必须对齐,勿在此自创):
//   aether_cpp/third_party/glomap_vendor/bench/aether_ghost_mask.h
//   aether_sfm_c.cc MaybeWriteGhostMask(env AETHER_GHOST_MASK=1 才写)
//   • sidecar = <db 同目录>/ghost_mask.bin,每点 1 字节 GhostFlagBits;
//     顺序 = native Points3D() 迭代序 == get_points/get_points_tracked
//     枚举序。Dart 侧一旦删过点(spatial two-view 过滤 / 孤点过滤),
//     索引就不再对应 —— 所以加载时必须做点数一致性核对,不一致按
//     "没有 sidecar"容错(全显示)。
//   • DISPLAY-ONLY 铁律:sidecar 是隐藏候选的元数据,不删点不动点。
//
// 可见性谓词(鬼层歼灭战 07-12,用户签决「只藏确证鬼、放行所有 2-view 好点」):
//   visible(p) = ¬band15(p) ∨ rescued(p)
//   等价:hidden(p) = band15(p) ∧ ¬rescued(p) —— 只隐藏「band15 距离门命中
//   (离地板 >1.5cm)且未被 L1 救援」的点。
//   • band15 = kGhostHideBits —— header 唯一 display gate 位,语义 = D@1.5cm
//     slab 外的地板下/远离地板伪影簇(cap49:2840 点整簇在地板下 -17cm,
//     物理在地板下 = 确证反光地板镜像鬼)。cell_ghost/band10 是 L1 仲裁/参考
//     位,渲染门不消费。
//   • rescued = L1 CasDiffMVS 1-bit 仲裁的「真面」白名单位(bit5),误隐=0
//     红线的守门:band15 里被判真几何(踢脚/台阶)的点置 1 → 放行可见。
//     native 仲裁(aether_sfm_arbitrate)把 bit5 回写进 Points3D 序的
//     ghost_mask.bin,而**仲裁跑在 persist 之后**(cap49 telemetry:persist
//     +20ms → l1_arbitrate +22s)。[BIT5-FIX 2026-07-12] sfm_live_recon 的
//     arbitrate_done 钩子按同一 native→snap→floater keep 链(GhostDeliveredMaskRemap)
//     **重算交付点序的 ghost_view_mask.bin**,让回写的 bit5 流到交付 mask —— 草稿
//     查看页下次加载即拿到带救援位的 mask,那 358 个救援点(真踢脚/台阶)不再被
//     隐藏(cap49:hidden 2840→2482)。仲裁前的短窗口内 mask 无 bit5(band15 全隐,
//     构造性误隐,仅渲染;导出永远全量)。
//   • ⚠️ 无 obs 依赖:2-view(obs<3)好点不再被当低质量隐藏 —— 旧规则的
//     「obs≥3 ∨ rescued」那条腿会隐掉全云 64%(cap49:40591 个 2-view 点),
//     按签决删除。点云全量交付,渲染只藏确证鬼。
//   • ⚠️ 真值:cap49 缺 dense truth;raised-structure(真台阶/高台)场景
//     band15 可能误命中真结构,唯一兜底是 rescue 白名单 —— 交付 mask 带上
//     救援位前,草稿查看页对这类点是构造性误隐(仅渲染,导出永远全量)。
//
// 开关:kGhostMaskViewFilter,纯编译期 env 式 flag。用户签决「鬼层必须
// 消失」→ 默认 **true(开门)**,保留 --dart-define=false 暗关退路。铁律:
// 禁止任何用户可见质量滑杆/档位 —— 此开关只允许 --dart-define 翻转,永不接 UI。

import 'dart:io';
import 'dart:typed_data';

/// 渲染门总开关。**默认 false(关门)—— 用户 2026-07-20 当面看图签决。**
///
/// 历史:07-12 曾签决「鬼层必须消失」→ 默认 true;07-18 用户看图后改判
/// 「L2 也不是正收益」,但那条指令一直没落地,默认值停在 true 两天。
/// 07-20 用同 gauge 双窗对照(未命名5,6,401 点全量 vs 4,997 过滤后,被隐藏的
/// 1,404 点涂红)当面复核,用户判定**这些不是鬼点**,明确要求关闭。
///
/// 关闭后连带消除的 UX 缺陷(实测,三次采集全复现):预览先出 4,668 点,
/// 等 L1 深度推理(CoreML 4 参考帧,实测 10.7s)+ 仲裁跑完再补上 371 个
/// 救援点 → 用户看到「点云延迟弹出」;且标题的 6,401 与画面永远对不上。
///
/// 暗开退路(排障/回归对照):
///   flutter build ios --profile --dart-define=PW_GHOST_VIEW_FILTER=true
/// 铁律不变:只允许 --dart-define 翻转,永不接 UI 滑杆/档位;导出/PLY/上传
/// 路径永远全量,绝不消费此门。
const bool kGhostMaskViewFilter = bool.fromEnvironment(
  'PW_GHOST_VIEW_FILTER',
  defaultValue: false,
);

// ── GhostFlagBits(逐字对齐 aether_ghost_mask.h)────────────────────────
const int kGhostFlagInRegion = 1 << 0; // footprint cell & |sd| < 8cm slab
const int kGhostFlagBand15 = 1 << 1; // D@1.5cm 隐藏候选(display gate)
const int kGhostFlagCellGhost = 1 << 2; // 双峰 cell 鬼模成员(L1 仲裁输入)
const int kGhostFlagInClean = 1 << 3; // cell 无上方结构
const int kGhostFlagBand10 = 1 << 4; // Phase0 1.0cm 参考位

/// L1 救援位(未来扩展):CasDiffMVS 1-bit 仲裁判"真面"的点置 1。
/// native 当前不写(恒 0)—— 谓词已消费此位,L1 落地时 Dart 侧零改动。
const int kGhostFlagRescued = 1 << 5;

/// 渲染门实际消费的隐藏位。header 语义:band15 是唯一 display gate;
/// 其余位是仲裁/参考元数据,不得掺进隐藏判定。
const int kGhostHideBits = kGhostFlagBand15;

/// sidecar 文件名(与 native MaybeWriteGhostMask 写出名一致,位于
/// sfm_live.db 同目录 == captureDir)。native 顺序 = Points3D 迭代序;
/// **L1 仲裁(aether_sfm_arbitrate)拥有此文件**,仲裁后在 native 点序上
/// 回写 rescued/confirmed 位 —— 所以绝不能被 Dart 改写点序(会毁掉仲裁
/// 与 arbitration_points.bin 的索引对应)。
const String kGhostMaskFileName = 'ghost_mask.bin';

/// [L2-ALIGN 2026-07-12] 交付点序 mask sidecar。native `ghost_mask.bin` 在
/// Points3D 序(persist 前),而交付 PLY 经 spatial-two-view + 孤点过滤后
/// 点数更少且重排 —— 草稿查看页(从 PLY 加载,拿不到运行期 keep 映射)
/// 无法把 native mask 对齐到 PLY。故 persist 时把 native mask 按
/// spatial→floater 两级 keep 重排成**交付点序**另存此文件,点数/点序逐位
/// == sfm_sparse.ply。查看页优先读它即可 aligned。
/// 写两次:①persist(L1 仲裁之前)时按 keep 链重排 native mask(此刻无
/// rescued/bit5);②[BIT5-FIX 2026-07-12] L1 仲裁 done 后(sfm_live_recon 的
/// arbitrate_done → ar_capture_page._recomputeDeliveredGhostMaskAfterArbitration)
/// 用 GhostDeliveredMaskRemap 按**同一 keep 链**重算此文件 —— 此刻 native
/// ghost_mask.bin 已带回写的 bit5(cap49 实测 358),rescue 位随之流到交付
/// 点序。新规则 visible=¬band15∨rescued 消费 bit5:第②步落盘后草稿查看页
/// 下次加载即 hidden=band15∧¬rescued(cap49:2840→2482),358 救援点放行。
const String kGhostViewMaskFileName = 'ghost_view_mask.bin';

/// 视图过滤统计(遥测载荷)。
class GhostViewStats {
  const GhostViewStats({
    required this.hiddenGhost,
    required this.rescuedVisible,
    required this.shown,
  });

  /// 实际被隐藏的点数 = band15 ∧ ¬rescued(确证鬼,未被 L1 救援)。
  final int hiddenGhost;

  /// band15 命中但被 L1 救援位放行可见的点数(误隐=0 红线的观测窗;
  /// 交付 mask 暂无 bit5 时恒 0 —— 见 kGhostViewMaskFileName 注释)。
  final int rescuedVisible;

  /// 可见点数(= n − hiddenGhost)。
  final int shown;
}

/// 读取并核对 sidecar。返回 per-point flag 字节(长度 == [expectedCount]);
/// 文件缺失 / 读取失败 / 点数不一致 → null(容错:按"没有 sidecar"全显示,
/// 绝不让一个错位的 mask 隐藏错点)。
Uint8List? tryLoadGhostMaskSidecar(
  String dirPath,
  int expectedCount, {
  String fileName = kGhostMaskFileName,
}) {
  if (expectedCount <= 0) return null;
  try {
    final f = File('$dirPath/$fileName');
    if (!f.existsSync()) return null;
    if (f.lengthSync() != expectedCount) return null; // 索引已错位,拒用
    final bytes = f.readAsBytesSync();
    if (bytes.length != expectedCount) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// 计算可见性数组(1 = 可见,0 = 渲染期跳过)+ 统计。
///
/// [flags] 是与当前点序逐位对齐的 GhostFlagBits。规则:
///   visible = ¬band15 ∨ rescued  ⇔  hidden = band15 ∧ ¬rescued。
/// 纯函数,永不改动输入。2-view(obs<3)点不再参与隐藏判定 —— 用户签决
/// 「只藏确证鬼、放行所有 2-view 好点」,故不再需要 obs 观测计数。
({Uint8List visibility, GhostViewStats stats}) computeGhostViewVisibility(
  Uint8List flags,
) {
  final n = flags.length;
  final visibility = Uint8List(n);
  var hiddenGhost = 0;
  var rescuedVisible = 0;
  var shown = 0;
  for (var i = 0; i < n; i++) {
    final f = flags[i];
    final isBand = f & kGhostHideBits != 0;
    final isRescued = f & kGhostFlagRescued != 0;
    if (isBand && !isRescued) {
      hiddenGhost++; // visibility[i] 保持 0 = 隐藏(确证鬼)
      continue;
    }
    if (isBand && isRescued) {
      rescuedVisible++; // band15 但 L1 救援 → 放行可见(白名单)
    }
    visibility[i] = 1;
    shown++;
  }
  return (
    visibility: visibility,
    stats: GhostViewStats(
      hiddenGhost: hiddenGhost,
      rescuedVisible: rescuedVisible,
      shown: shown,
    ),
  );
}

/// 按 [keepIdx](floater_filter.compactXyzRgbByIndices 同款保序索引)压实
/// 可见性数组,使其与孤点过滤后的显示点序保持逐位对齐。
Uint8List compactVisibilityByIndices(Uint8List visibility, Int32List keepIdx) {
  final out = Uint8List(keepIdx.length);
  for (var k = 0; k < keepIdx.length; k++) {
    out[k] = visibility[keepIdx[k]];
  }
  return out;
}

/// [BIT5-FIX 2026-07-12] 交付点序 mask 的重算配方 —— persist 时与 L1 仲裁
/// 完成后**复用同一 native→snap→floater keep 链**,把任意版本的 native
/// `ghost_mask.bin`(persist 时无 bit5;仲裁 +22s 后带 bit5=rescued)重排成
/// 交付 PLY 点序的 flags。捕获链路一次(persist),仲裁 done 后再放一次相同
/// 输入即可让 rescue 位流到交付 mask —— 无需保留运行期快照,只存两级索引。
///
/// 两级 keep 语义与 persist 现场逐字一致:
///   • [spatialKeep] = finalize spatial-two-view 过滤的 compacted→native 序
///     索引(native Points3D 序 → 该快照序);null == 恒等(该过滤没删点)。
///   • [floaterKeep] = 孤点过滤的 compacted→snap 序索引(快照序 → 交付 PLY
///     序);null == 恒等(没删孤点)。
/// [nativeCount] = native mask 应有的点数(= 快照点数 + spatial 删除数);
/// [deliveredCount] = 交付 PLY 点数(== 最终 mask 长度,写盘前核对)。
class GhostDeliveredMaskRemap {
  const GhostDeliveredMaskRemap({
    required this.nativeCount,
    required this.spatialKeep,
    required this.floaterKeep,
    required this.deliveredCount,
  });

  final int nativeCount;
  final Int32List? spatialKeep;
  final Int32List? floaterKeep;
  final int deliveredCount;

  /// native Points3D 序 flags → 交付 PLY 序 flags。长度不符(mask 与本次
  /// 重建点数错位)→ null(容错:调用方按"不重算"处理,保留旧交付 mask)。
  /// compactVisibilityByIndices 是逐位 gather —— 对 flag 字节同样成立(重排
  /// 不改位),故此处直接复用作 flag 重映射。
  Uint8List? remap(Uint8List nativeFlags) {
    if (nativeFlags.length != nativeCount) return null;
    final snapFlags = spatialKeep == null
        ? nativeFlags
        : compactVisibilityByIndices(nativeFlags, spatialKeep!);
    final delivered = floaterKeep == null
        ? snapFlags
        : compactVisibilityByIndices(snapFlags, floaterKeep!);
    if (delivered.length != deliveredCount) return null;
    return delivered;
  }
}
