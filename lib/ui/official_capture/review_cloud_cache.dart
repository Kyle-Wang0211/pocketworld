// review_cloud_cache.dart — 复看点云的「算完存盘、再打开直接读」缓存。
//
// 为什么要它:相册里点开一个已完成项目走 `_enterReviewMode`,稠密云
// (official_dense.ply,实测 6,922,990 点 / 103,845,031 字节)每次都要
//   1) 把 99 MB 整个读进内存、再 sublist 复制一份;
//   2) 逐点 getFloat32 解 692 万次;
//   3) 因为 692 万 > 预算 100 万,跑 ProgressiveOctreeOrder.reorder
//      (11 层 × 692 万 ≈ 7600 万次迭代,每次 3 次除法取整 + 一次
//      Map<int,_CellChoice> 哈希查找);
//   4) 最后 sublist(0, budget*3) 只留前 100 万,其余 592 万排完即扔。
// 这四步的产物**只取决于**(PLY 文件内容, 预算, 排序算法),所以把第 4 步的
// 结果原样落盘,第二次打开就只剩「读一个 15 MB 的定长文件 + 校验」。
//
// 硬约束(改这个文件前先读):
//   * 缓存文件**绝不**写进 `captures_official/<cap_id>/` —— 装机闸 B 逐场比对
//     「设备条目数 vs 备份条目数」,往会话目录里加文件会让每一场都被判成
//     「备份不完整」。缓存一律落在 `<Documents>/review_cache/`,和闸 B 自己的
//     `<Documents>/pw_b1_gate/` 同级(见 official_capture/b1_gate_runner.dart)。
//   * ProgressiveOctreeOrder 是 Potree 口径的复刻,本文件只缓存它的**输出**,
//     一行算法都不碰。**算法一旦改动就必须把 [ReviewCloudCache.kFormatVersion]
//     加一**,否则旧缓存会把旧顺序喂回给用户。
//   * 读缓存路径上任何异常(截断、损坏、版本不符、字节序不符)都必须静默退回
//     重算,绝不能让用户打不开点云。见 review_cloud_cache_test.dart 的阴性对照。

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../point_cloud_display/progressive_octree_order.dart'
    show ReviewPointCloudPolicy;
import 'sparse_cloud_viewer_page.dart'
    show SparseCloudData, loadReviewCloudWithBudget;

/// 一次「装复看点云」的请求。`compute` 的入参只能是一个对象,而缓存目录必须在
/// 主 isolate 上用 path_provider 解析好再传进来(后台 isolate 没有插件通道)。
class ReviewCloudRequest {
  const ReviewCloudRequest({
    required this.plyPath,
    required this.cacheDir,
    this.budget = ReviewPointCloudPolicy.kPointBudget,
  });

  final String plyPath;

  /// 缓存目录;null / 空 ⇒ 完全不走缓存,行为与改动前逐字一致。
  final String? cacheDir;

  final int budget;
}

/// 缓存命中后取出来的东西。
class ReviewCloudCacheEntry {
  const ReviewCloudCacheEntry({
    required this.xyz,
    required this.rgb,
    required this.sourceCount,
  });

  final Float32List xyz;
  final Uint8List rgb;

  /// 源 PLY 里的点数(> xyz.length ~/ 3 时说明被预算截断过)。
  final int sourceCount;
}

/// 磁盘缓存的编解码 + 失效判据。纯函数 + 同步文件读写,可在 isolate 里跑。
abstract final class ReviewCloudCache {
  /// 文件头 8 字节魔数 "PWRCLD01"。
  static const List<int> _magic = <int>[
    0x50, 0x57, 0x52, 0x43, 0x4C, 0x44, 0x30, 0x31, //
  ];

  /// 缓存格式版本。**改 PLY 解析、改预算截断口径、或改
  /// ProgressiveOctreeOrder 的排序结果,都必须把它加一。**
  static const int kFormatVersion = 1;

  /// 字节序哨兵:以小端写入 0x01020304。读回来不是这个数,说明写它的机器
  /// (或读它的机器)不是小端 ⇒ 底下那片按主机序摆的 float32 不能信,弃用缓存。
  static const int _endianSentinel = 0x01020304;

  /// 头部固定 64 字节(8 的倍数,保证后面的 float32 块天然 4 字节对齐)。
  static const int kHeaderBytes = 64;

  static const String kFileSuffix = '.rcc';
  static const String _tmpSuffix = '.rcc.tmp';

  /// 缓存目录名(挂在 Documents 下,**不在** captures_official 里面)。
  static const String kDirName = 'review_cache';

  /// 目录里最多留几份 / 最多占多少字节;超了按 mtime 从旧到新删。
  /// 一份 100 万点的缓存 ≈ 15 MB。
  static const int kMaxEntries = 8;
  static const int kMaxBytes = 192 * 1024 * 1024;

  /// 多旧的 `.rcc.tmp` 才算「写了一半被杀掉的残骸」而不是「正在写」。
  static const Duration kTmpStaleAfter = Duration(hours: 1);

  /// 主 isolate 专用:`<Documents>/review_cache/`,失败返回 null(⇒ 不缓存)。
  static Future<String?> resolveDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$kDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  /// 缓存键 = 源路径 + 预算 + 格式版本 的 64 位 FNV-1a。三者任一不同 ⇒ 不同文件。
  static String keyFor({required String plyPath, required int budget}) {
    final hash = _fnv1a64('$plyPath|$budget|v$kFormatVersion');
    final hi = (hash >> 32) & 0xFFFFFFFF;
    final lo = hash & 0xFFFFFFFF;
    return '${hi.toRadixString(16).padLeft(8, '0')}'
        '${lo.toRadixString(16).padLeft(8, '0')}';
  }

  static File fileFor({
    required String cacheDir,
    required String plyPath,
    required int budget,
  }) =>
      File('$cacheDir/${keyFor(plyPath: plyPath, budget: budget)}$kFileSuffix');

  /// 把一份已算好的复看点云编码成缓存字节。
  ///
  /// 布局(头部小端;点数据按主机序,由 [_endianSentinel] 把关):
  ///   0  magic[8] | 8  u32 version | 12 u32 endianSentinel
  ///   16 i64 budget | 24 i64 源文件字节数 | 32 i64 源文件 mtime(ms)
  ///   40 i64 源点数 | 48 i64 存下来的点数 | 56 u32 源路径哈希 | 60 u32 保留
  ///   64 float32 × 3n (xyz) | 之后 uint8 × 3n (rgb,补齐到 4 字节)
  ///   末尾 u32 校验和(对前面所有 32 位字做 FNV-1a)
  static Uint8List encode({
    required Float32List xyz,
    required Uint8List rgb,
    required int sourceCount,
    required int budget,
    required int sourceLength,
    required int sourceModifiedMs,
    required String plyPath,
  }) {
    final storedCount = xyz.length ~/ 3;
    if (xyz.length != storedCount * 3 || rgb.length < storedCount * 3) {
      throw ArgumentError('xyz/rgb must hold packed triplets of equal length');
    }
    final xyzBytes = storedCount * 12;
    final rgbBytes = storedCount * 3;
    final rgbPadded = (rgbBytes + 3) & ~3;
    final checksumOffset = kHeaderBytes + xyzBytes + rgbPadded;
    final out = Uint8List(checksumOffset + 4);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 8, _magic);
    bd.setUint32(8, kFormatVersion, Endian.little);
    bd.setUint32(12, _endianSentinel, Endian.little);
    bd.setInt64(16, budget, Endian.little);
    bd.setInt64(24, sourceLength, Endian.little);
    bd.setInt64(32, sourceModifiedMs, Endian.little);
    bd.setInt64(40, sourceCount, Endian.little);
    bd.setInt64(48, storedCount, Endian.little);
    bd.setUint32(56, _pathHash32(plyPath), Endian.little);
    bd.setUint32(60, 0, Endian.little);
    out.setRange(
      kHeaderBytes,
      kHeaderBytes + xyzBytes,
      Uint8List.view(xyz.buffer, xyz.offsetInBytes, xyzBytes),
    );
    final rgbOffset = kHeaderBytes + xyzBytes;
    out.setRange(rgbOffset, rgbOffset + rgbBytes, rgb);
    bd.setUint32(checksumOffset, _checksum(out, checksumOffset), Endian.little);
    return out;
  }

  /// 解码 + 逐条比对失效判据。任何一条不过都返回 null(调用方据此重算)。
  static ReviewCloudCacheEntry? decode(
    Uint8List bytes, {
    required int budget,
    required int sourceLength,
    required int sourceModifiedMs,
    required String plyPath,
  }) {
    try {
      if (bytes.length < kHeaderBytes + 4) return null;
      for (var i = 0; i < 8; i++) {
        if (bytes[i] != _magic[i]) return null;
      }
      final bd = ByteData.sublistView(bytes);
      if (bd.getUint32(8, Endian.little) != kFormatVersion) return null;
      if (bd.getUint32(12, Endian.little) != _endianSentinel) return null;
      if (bd.getInt64(16, Endian.little) != budget) return null;
      if (bd.getInt64(24, Endian.little) != sourceLength) return null;
      if (bd.getInt64(32, Endian.little) != sourceModifiedMs) return null;
      final sourceCount = bd.getInt64(40, Endian.little);
      final storedCount = bd.getInt64(48, Endian.little);
      if (bd.getUint32(56, Endian.little) != _pathHash32(plyPath)) return null;
      if (storedCount < 0 || sourceCount < storedCount) return null;
      // 纵深防御:挡住点数乘法溢出成一个「看着合法」的长度的极端情形。
      // 正常的截断/拼接/乱填由下面那条长度判据抓。
      if (storedCount > _kMaxDecodablePoints) return null;
      // 点数是文件里自报的 ⇒ 先按它算出「这份缓存应该有多长」,和实际长度
      // 严丝合缝才往下走。截断、尾部多字节、乱填点数都在这一步出局,绝不会
      // 拿一个没核对过的点数去开数组。
      final xyzBytes = storedCount * 12;
      final rgbBytes = storedCount * 3;
      final checksumOffset = kHeaderBytes + xyzBytes + ((rgbBytes + 3) & ~3);
      if (bytes.length != checksumOffset + 4) return null;
      if (bd.getUint32(checksumOffset, Endian.little) !=
          _checksum(bytes, checksumOffset)) {
        return null;
      }
      final xyz = Float32List(storedCount * 3);
      final base = bytes.offsetInBytes + kHeaderBytes;
      if (base % Float32List.bytesPerElement == 0) {
        xyz.setAll(0, Float32List.view(bytes.buffer, base, storedCount * 3));
      } else {
        for (var i = 0; i < storedCount * 3; i++) {
          xyz[i] = bd.getFloat32(kHeaderBytes + i * 4, Endian.little);
        }
      }
      final rgb = Uint8List(rgbBytes);
      rgb.setRange(0, rgbBytes, bytes, kHeaderBytes + xyzBytes);
      return ReviewCloudCacheEntry(
        xyz: xyz,
        rgb: rgb,
        sourceCount: sourceCount,
      );
    } catch (_) {
      return null;
    }
  }

  /// 15 字节/点,2 亿点 = 3 GB —— 比任何真实 PLY 都大得多,只用来挡住
  /// 损坏文件里的离谱点数,避免 decode 自己先 OOM。
  static const int _kMaxDecodablePoints = 200 * 1000 * 1000;

  /// 读一份缓存;文件不存在、读不动、或任何一条判据不过都返回 null。
  static ReviewCloudCacheEntry? readEntry(
    File file, {
    required int budget,
    required int sourceLength,
    required int sourceModifiedMs,
    required String plyPath,
  }) {
    try {
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      return decode(
        bytes,
        budget: budget,
        sourceLength: sourceLength,
        sourceModifiedMs: sourceModifiedMs,
        plyPath: plyPath,
      );
    } catch (_) {
      return null;
    }
  }

  /// 写一份缓存。先写 `.rcc.tmp` 再 rename ⇒ 读方永远看不到半截文件。
  /// 任何失败都吞掉(缓存写不成只是慢,不是错),返回是否写成。
  static bool writeEntry(
    File file, {
    required Float32List xyz,
    required Uint8List rgb,
    required int sourceCount,
    required int budget,
    required int sourceLength,
    required int sourceModifiedMs,
    required String plyPath,
  }) {
    final tmp = File('${_stripSuffix(file.path)}$_tmpSuffix');
    try {
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      tmp.writeAsBytesSync(
        encode(
          xyz: xyz,
          rgb: rgb,
          sourceCount: sourceCount,
          budget: budget,
          sourceLength: sourceLength,
          sourceModifiedMs: sourceModifiedMs,
          plyPath: plyPath,
        ),
        flush: true,
      );
      tmp.renameSync(file.path);
      return true;
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  /// 目录超限时按 mtime 从旧到新删,只动本缓存自己的文件。永不抛。
  static void prune(
    String cacheDir, {
    int maxEntries = kMaxEntries,
    int maxBytes = kMaxBytes,
  }) {
    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) return;
      final entries = <({File file, int bytes, int modifiedMs})>[];
      final staleBefore = DateTime.now()
          .subtract(kTmpStaleAfter)
          .millisecondsSinceEpoch;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final stat = e.statSync();
        final modifiedMs = stat.modified.millisecondsSinceEpoch;
        // 写到一半被杀留下的 .rcc.tmp:够旧了就收走(够新的可能正在写)。
        if (e.path.endsWith(_tmpSuffix)) {
          if (modifiedMs < staleBefore) {
            try {
              e.deleteSync();
            } catch (_) {}
          }
          continue;
        }
        if (!e.path.endsWith(kFileSuffix)) continue;
        entries.add((file: e, bytes: stat.size, modifiedMs: modifiedMs));
      }
      entries.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      var kept = 0;
      var keptBytes = 0;
      for (final e in entries) {
        final fits = kept < maxEntries && keptBytes + e.bytes <= maxBytes;
        if (fits) {
          kept++;
          keptBytes += e.bytes;
          continue;
        }
        try {
          e.file.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _stripSuffix(String path) => path.endsWith(kFileSuffix)
      ? path.substring(0, path.length - kFileSuffix.length)
      : path;

  static int _pathHash32(String path) => _fnv1a64(path) & 0xFFFFFFFF;

  static int _fnv1a64(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in text.codeUnits) {
      hash ^= unit & 0xFF;
      hash *= 0x100000001b3;
      if (unit > 0xFF) {
        hash ^= (unit >> 8) & 0xFF;
        hash *= 0x100000001b3;
      }
    }
    return hash;
  }

  /// 对 [0, end) 这段(必是 4 的倍数)按 32 位字做 FNV-1a。
  static int _checksum(Uint8List bytes, int end) {
    var hash = 0x811c9dc5;
    final base = bytes.offsetInBytes;
    if (base % Uint32List.bytesPerElement == 0) {
      final words = Uint32List.view(bytes.buffer, base, end >> 2);
      for (final w in words) {
        hash = ((hash ^ w) * 0x01000193) & 0xFFFFFFFF;
      }
      return hash;
    }
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < end; i += 4) {
      hash =
          ((hash ^ bd.getUint32(i, Endian.little)) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

/// `compute` 入口:能读缓存就读,读不成就按老路子解 PLY + 排序,然后把结果存盘。
///
/// 第一次打开与改动前逐字同路(解 PLY → ProgressiveOctreeOrder → 截断),只多
/// 一次落盘;第二次及以后省掉的正是这三步。
SparseCloudData? loadReviewCloudCached(ReviewCloudRequest request) {
  final path = request.plyPath;
  final budget = request.budget;
  final cacheDir = request.cacheDir;
  final stat = _statOrNull(path);
  if (cacheDir == null || cacheDir.isEmpty || stat == null) {
    return loadReviewCloudWithBudget(path, budget);
  }
  final sourceLength = stat.size;
  final sourceModifiedMs = stat.modified.millisecondsSinceEpoch;
  final file = ReviewCloudCache.fileFor(
    cacheDir: cacheDir,
    plyPath: path,
    budget: budget,
  );
  final hit = ReviewCloudCache.readEntry(
    file,
    budget: budget,
    sourceLength: sourceLength,
    sourceModifiedMs: sourceModifiedMs,
    plyPath: path,
  );
  if (hit != null) {
    return SparseCloudData(hit.xyz, hit.rgb, sourceCount: hit.sourceCount);
  }
  final fresh = loadReviewCloudWithBudget(path, budget);
  if (fresh == null) return null;
  final wrote = ReviewCloudCache.writeEntry(
    file,
    xyz: fresh.xyz,
    rgb: fresh.rgb,
    sourceCount: fresh.sourceCount,
    budget: budget,
    sourceLength: sourceLength,
    sourceModifiedMs: sourceModifiedMs,
    plyPath: path,
  );
  if (wrote) ReviewCloudCache.prune(cacheDir);
  return fresh;
}

FileStat? _statOrNull(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.statSync();
  } catch (_) {
    return null;
  }
}
