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
// 可见性谓词(任务①签发形式):
//   visible(p) = ¬ghost_flag(p) ∧ [obs(p) ≥ 3 ∨ rescued_flag(p) ∨ obs 未知]
//   • ghost_flag = kGhostHideBits(band15 —— header 里唯一的 display gate 位;
//     cell_ghost/band10 是 L1 仲裁与参考位,渲染门不消费)。
//   • obs 来自 colorize 已有的 per-point track 观测计数(CSR obsOffsets);
//     渲染层拿不到 obs 时(草稿查看页从 PLY 加载)该项恒真 —— 本期容错,
//     未来可从 sidecar 扩展位读(见 kGhostFlagRescued 注释)。
//   • rescued = L1 CasDiffMVS 1-bit 仲裁的救援位(误隐=0 红线)。native
//     当前不写此位(bits 文档只到 bit4),这里先定义 bit5 为救援位做
//     前向兼容;正式启用前必须与 native 侧敲定位号。
//
// 开关(任务②):kGhostMaskViewFilter,纯编译期 env 式 flag,默认 false
// (暗 ship)。铁律:禁止任何用户可见质量滑杆/档位 —— 此开关只允许
// --dart-define 翻转,永不接 UI。

import 'dart:io';
import 'dart:typed_data';

/// 渲染门总开关(默认关 = 全显示)。翻转方式:
///   flutter build ios --profile --dart-define=PW_GHOST_VIEW_FILTER=true
/// 等完整包(L1 救援 + 误隐=0 验证)过门后才允许默认置 true。
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

/// 低 track 隐藏阈值:obs ≥ 3 的点有第三视角深度确认,直接可见;
/// 2-view 点须 L1 救援位背书(与 floater_filter 的 ≥3 保护同一语义锚)。
const int kGhostMinTrackLen = 3;

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
/// ⚠️写在 L1 仲裁之前 → 暂不含 rescued 位(当前 rescue=0 无影响;rescue
/// 落地后需在仲裁后重算此文件)。
const String kGhostViewMaskFileName = 'ghost_view_mask.bin';

/// 视图过滤统计(任务④遥测载荷)。
class GhostViewStats {
  const GhostViewStats({
    required this.hiddenGhost,
    required this.hiddenLowTrack,
    required this.rescuedVisible,
    required this.shown,
  });

  /// 因 hide 位(band15)被隐藏的点数。
  final int hiddenGhost;

  /// 非鬼、obs 已知且 <3、无救援位 → 被隐藏的点数。
  final int hiddenLowTrack;

  /// 非鬼、obs<3 但被 L1 救援位救回可见的点数(误隐=0 红线的观测窗)。
  final int rescuedVisible;

  /// 可见点数(= n − hiddenGhost − hiddenLowTrack)。
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
/// [flags] 是与当前点序逐位对齐的 GhostFlagBits;[obsOffsets] 是 colorize
/// 同源的 CSR 观测偏移(长度 n+1),传 null / 长度不符时低 track 项恒真
/// (只有鬼位过滤生效)。纯函数,永不改动输入。
({Uint8List visibility, GhostViewStats stats}) computeGhostViewVisibility(
  Uint8List flags, {
  Int32List? obsOffsets,
}) {
  final n = flags.length;
  final hasObs = obsOffsets != null && obsOffsets.length == n + 1;
  final visibility = Uint8List(n);
  var hiddenGhost = 0;
  var hiddenLowTrack = 0;
  var rescuedVisible = 0;
  var shown = 0;
  for (var i = 0; i < n; i++) {
    final f = flags[i];
    if (f & kGhostHideBits != 0) {
      hiddenGhost++; // visibility[i] 保持 0
      continue;
    }
    if (hasObs) {
      final obs = obsOffsets[i + 1] - obsOffsets[i];
      if (obs < kGhostMinTrackLen) {
        if (f & kGhostFlagRescued == 0) {
          hiddenLowTrack++;
          continue;
        }
        rescuedVisible++;
      }
    }
    visibility[i] = 1;
    shown++;
  }
  return (
    visibility: visibility,
    stats: GhostViewStats(
      hiddenGhost: hiddenGhost,
      hiddenLowTrack: hiddenLowTrack,
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
