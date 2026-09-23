// review_cloud_cache_hardening_test.dart — 缓存接到生产线(build 168 之上)时补的判据。
//
// review_cloud_cache_test.dart 已经把每条失效判据单独钉过;这里补三处它没有
// 逐一钉死的地方:
//
//   A. 源 PLY 的**内容**真的换了(重跑稠密会重写 official_dense.ply)⇒ 拿到的
//      必须是**新云**,逐数等于不带缓存的老路径。原测试的 mtime 那条只断言
//      「不是哨兵」,没断言退回之后的数据是对的。另把 stat 判据的固有盲区
//      (内容变了但大小和 mtime 都被原样还原)写成一条明文判据,而不是假装没有。
//   B. `.rcc` 在**每一个结构边界**上截断、**每一个头字段**各翻一个字节 ⇒ 不抛、
//      拿到正确点云。原测试只截了一半、只在点数据区翻了一个字节。
//   C. 生产是经 `compute` 进后台 isolate 调的(build 161 出过「isolate 消息发不
//      过去」的事故),原测试全是同步直调;这里走真 isolate 验 未命中 / 命中 /
//      坏缓存 三条路。
//
// 判据纪律:每条阴性对照之前都有阳性对照 —— 先把一份「一眼认得出」的哨兵
// 数据(xyz[0] = -999)种进缓存,证明读到的就是哨兵(= 缓存真的被读了),
// 再弄坏它,证明退回之后拿到的是正确点云、而且不是哨兵。一个恒返回 null 的
// decode 过不了阳性对照;一个不校验的 decode 过不了阴性对照。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/review_cloud_cache.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart'
    show SparseCloudData, loadReviewCloudWithBudget;

const double _kSentinel = -999.0;

/// 与 sparse_ply.dart 同格式的二进制 PLY(xyz float32 LE + rgb uchar)。
/// 同一 [count] 下不同 [seed] 的文件**字节数相同、内容不同**。
File _writePly(Directory dir, String name, int count, {int seed = 1}) {
  final body = Uint8List(count * 15);
  final bd = ByteData.sublistView(body);
  for (var i = 0; i < count; i++) {
    final o = i * 15;
    bd.setFloat32(o, ((i * 37 + seed) % 101).toDouble(), Endian.little);
    bd.setFloat32(o + 4, ((i * 53 + seed) % 97).toDouble(), Endian.little);
    bd.setFloat32(o + 8, ((i * 71 + seed) % 89).toDouble(), Endian.little);
    body[o + 12] = (i + seed) & 0xFF;
    body[o + 13] = (i >> 8) & 0xFF;
    body[o + 14] = (i * 7 + seed) & 0xFF;
  }
  final header =
      'ply\n'
      'format binary_little_endian 1.0\n'
      'element vertex $count\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final f = File('${dir.path}/$name');
  f.writeAsBytesSync(
    Uint8List.fromList(<int>[...header.codeUnits, ...body]),
    flush: true,
  );
  return f;
}

void _expectSameCloud(SparseCloudData expected, SparseCloudData got) {
  expect(got.count, expected.count);
  expect(got.sourceCount, expected.sourceCount);
  expect(got.xyz, orderedEquals(expected.xyz));
  expect(got.rgb, orderedEquals(expected.rgb));
}

bool _sameCloud(SparseCloudData a, SparseCloudData b) =>
    a.count == b.count &&
    a.sourceCount == b.sourceCount &&
    listEquals(a.xyz, b.xyz) &&
    listEquals(a.rgb, b.rgb);

void main() {
  late Directory root;
  late Directory captureDir;
  late Directory cacheDir;
  late File ply;
  const budget = 50; // < pointCount ⇒ 八叉树截断真的在跑
  const pointCount = 400;

  // budget = 50 ⇒ 缓存布局(见 ReviewCloudCache.encode):
  const header = ReviewCloudCache.kHeaderBytes; // 64
  const xyzBytes = budget * 12; // 600
  const rgbBytes = budget * 3; // 150
  const rgbPadded = (rgbBytes + 3) & ~3; // 152
  const checksumAt = header + xyzBytes + rgbPadded; // 816
  const fullLength = checksumAt + 4; // 820

  setUp(() {
    root = Directory.systemTemp.createTempSync('review_cloud_cache_hardening');
    captureDir = Directory('${root.path}/captures_official/cap_1')
      ..createSync(recursive: true);
    cacheDir = Directory('${root.path}/${ReviewCloudCache.kDirName}')
      ..createSync(recursive: true);
    ply = _writePly(captureDir, 'official_dense.ply', pointCount);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ReviewCloudRequest req([File? source]) => ReviewCloudRequest(
    plyPath: (source ?? ply).path,
    cacheDir: cacheDir.path,
    budget: budget,
  );

  File cacheFile([File? source]) => ReviewCloudCache.fileFor(
    cacheDir: cacheDir.path,
    plyPath: (source ?? ply).path,
    budget: budget,
  );

  /// 把「与当前源文件 stat 完全对得上、但 xyz[0] 是哨兵」的一份缓存写进去,
  /// 返回写进去的全部字节(之后可以原样再种回去)。
  Uint8List plantSentinel({File? source}) {
    final src = source ?? ply;
    final cloud = loadReviewCloudWithBudget(src.path, budget)!;
    final stat = src.statSync();
    final xyz = Float32List.fromList(cloud.xyz)..[0] = _kSentinel;
    final bytes = ReviewCloudCache.encode(
      xyz: xyz,
      rgb: cloud.rgb,
      sourceCount: cloud.sourceCount,
      budget: budget,
      sourceLength: stat.size,
      sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
      plyPath: src.path,
    );
    cacheFile(src).writeAsBytesSync(bytes, flush: true);
    return bytes;
  }

  group('A. 源 PLY 内容换了 ⇒ 拿到新云(逐数对),不是旧缓存', () {
    test('布局常量自检:种进去的缓存正好 $fullLength 字节', () {
      expect(plantSentinel().length, fullLength);
    });

    test('只变大小(点数不同,mtime 原样还原)⇒ 新云', () {
      final oldCloud = loadReviewCloudWithBudget(ply.path, budget)!;
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], _kSentinel); // 阳性对照:命中

      final mtime = ply.lastModifiedSync();
      final sizeBefore = ply.lengthSync();
      _writePly(captureDir, 'official_dense.ply', pointCount + 10, seed: 3);
      ply.setLastModifiedSync(mtime); // 只留「大小」一个自变量
      expect(ply.lengthSync(), isNot(sizeBefore));
      expect(
        ply.statSync().modified.millisecondsSinceEpoch,
        mtime.millisecondsSinceEpoch,
      );

      final newCloud = loadReviewCloudWithBudget(ply.path, budget)!;
      // 阴性对照的前提:新旧两份云确实分得开,否则下面的断言测不出任何东西。
      expect(_sameCloud(oldCloud, newCloud), isFalse);

      final got = loadReviewCloudCached(req())!;
      expect(got.xyz[0], isNot(_kSentinel));
      _expectSameCloud(newCloud, got);
      expect(got.sourceCount, pointCount + 10);
    });

    test('只变 mtime(字节数相同、内容不同)⇒ 新云', () {
      final oldCloud = loadReviewCloudWithBudget(ply.path, budget)!;
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], _kSentinel); // 阳性对照:命中

      final mtime = ply.lastModifiedSync();
      final sizeBefore = ply.lengthSync();
      _writePly(captureDir, 'official_dense.ply', pointCount, seed: 7);
      ply.setLastModifiedSync(mtime.add(const Duration(seconds: 2)));
      expect(ply.lengthSync(), sizeBefore); // 只留「mtime」一个自变量

      final newCloud = loadReviewCloudWithBudget(ply.path, budget)!;
      expect(_sameCloud(oldCloud, newCloud), isFalse); // 分得开

      final got = loadReviewCloudCached(req())!;
      expect(got.xyz[0], isNot(_kSentinel));
      _expectSameCloud(newCloud, got);
    });

    test('退回重算之后会把新云写回缓存(下一次命中的是新云)', () {
      plantSentinel();
      final mtime = ply.lastModifiedSync();
      _writePly(captureDir, 'official_dense.ply', pointCount, seed: 11);
      ply.setLastModifiedSync(mtime.add(const Duration(seconds: 2)));
      final newCloud = loadReviewCloudWithBudget(ply.path, budget)!;
      _expectSameCloud(newCloud, loadReviewCloudCached(req())!);

      // 写回的那份必须对得上新 stat:直接 readEntry 能读出来且等于新云。
      final stat = ply.statSync();
      final entry = ReviewCloudCache.readEntry(
        cacheFile(),
        budget: budget,
        sourceLength: stat.size,
        sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
        plyPath: ply.path,
      );
      expect(entry, isNotNull);
      expect(entry!.xyz, orderedEquals(newCloud.xyz));
      expect(entry.rgb, orderedEquals(newCloud.rgb));
    });

    // 这不是想要的行为,是 stat 判据(大小 + mtime)的固有盲区,如实钉住:
    // 内容变了但字节数相同、mtime 又被原样还原 ⇒ 仍然读到旧缓存。
    // 生产上重写 PLY 必然刷新 mtime,只有「保留时间戳的恢复/拷贝」能撞上它。
    // 同时它也是 A 组的阳性对照:证明上面两条变绿,靠的正是大小/mtime 判据。
    test('已知盲区:同字节数 + mtime 原样还原 ⇒ 仍命中旧缓存', () {
      plantSentinel();
      final mtime = ply.lastModifiedSync();
      final sizeBefore = ply.lengthSync();
      _writePly(captureDir, 'official_dense.ply', pointCount, seed: 7);
      ply.setLastModifiedSync(mtime);
      expect(ply.lengthSync(), sizeBefore);
      expect(loadReviewCloudCached(req())!.xyz[0], _kSentinel);
    });
  });

  group('B. .rcc 截断 / 翻字节 ⇒ 不抛,拿到正确点云', () {
    // 每一个结构边界的前后:空、魔数中间、魔数后、各头字段起点、头尾、
    // xyz 中间/末尾、rgb 中间/末尾、补齐区、校验和的每一个字节。
    const cuts = <int>[
      0, 1, 7, 8, 12, 16, 24, 32, 40, 48, 56, 60, 63, header, header + 1, //
      header + xyzBytes ~/ 2, header + xyzBytes, header + xyzBytes + 1,
      header + xyzBytes + rgbBytes ~/ 2, header + xyzBytes + rgbBytes,
      checksumAt, checksumAt + 1, checksumAt + 2, checksumAt + 3,
    ];

    test('在 ${cuts.length} 个结构边界上逐一截断', () {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      final planted = plantSentinel();
      final file = cacheFile();
      for (final cut in cuts) {
        expect(cut, lessThan(fullLength), reason: 'cut=$cut 必须真的截掉东西');
        // 阳性对照(每一轮都做,因为上一轮的退回重算会把缓存改写成好的)。
        file.writeAsBytesSync(planted, flush: true);
        expect(
          loadReviewCloudCached(req())!.xyz[0],
          _kSentinel,
          reason: 'cut=$cut 阳性对照:完整缓存应命中',
        );
        file.writeAsBytesSync(planted.sublist(0, cut), flush: true);
        final got = loadReviewCloudCached(req());
        expect(got, isNotNull, reason: 'cut=$cut 退回后必须仍有点云');
        expect(got!.xyz[0], isNot(_kSentinel), reason: 'cut=$cut');
        _expectSameCloud(expected, got);
        // 自愈:截断的文件被重写成完整长度。
        expect(file.lengthSync(), fullLength, reason: 'cut=$cut 应自愈');
      }
    });

    // 不重签校验和:每个字段各翻一个字节,挡住它的要么是该字段自己的判据,
    // 要么是校验和(保留字段/补齐区/源点数这类没有专门判据的,只靠校验和)。
    const flips = <String, int>{
      'magic': 0,
      'version': 8,
      'endian': 12,
      'budget': 16,
      'sourceLength': 24,
      'sourceMtime': 32,
      'sourceCount': 40,
      'storedCount': 48,
      'pathHash': 56,
      'reserved': 60,
      'xyz[0] 首字节': header,
      'xyz 末字节': header + xyzBytes - 1,
      'rgb 首字节': header + xyzBytes,
      'rgb 末字节': header + xyzBytes + rgbBytes - 1,
      'rgb 补齐区': header + xyzBytes + rgbBytes,
      'checksum': checksumAt,
    };

    test('${flips.length} 个字段各翻一个字节(不重签)', () {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      final planted = plantSentinel();
      final file = cacheFile();
      flips.forEach((field, at) {
        file.writeAsBytesSync(planted, flush: true);
        expect(
          loadReviewCloudCached(req())!.xyz[0],
          _kSentinel,
          reason: '$field 阳性对照:完整缓存应命中',
        );
        final bad = Uint8List.fromList(planted);
        bad[at] ^= 0xFF;
        file.writeAsBytesSync(bad, flush: true);
        expect(file.lengthSync(), fullLength, reason: '$field 长度没变');
        final got = loadReviewCloudCached(req());
        expect(got, isNotNull, reason: '$field 退回后必须仍有点云');
        expect(got!.xyz[0], isNot(_kSentinel), reason: field);
        _expectSameCloud(expected, got);
      });
    });

    test('缓存路径被一个目录占着 ⇒ 不抛,拿到正确点云', () {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      Directory(cacheFile().path).createSync(recursive: true);
      _expectSameCloud(expected, loadReviewCloudCached(req())!);
      _expectSameCloud(expected, loadReviewCloudCached(req())!);
      expect(
        cacheDir.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
        reason: '写不成时 .rcc.tmp 必须收掉',
      );
    });
  });

  group('C. 走真 isolate(生产就是 compute 调的)', () {
    test('未命中 / 命中 / 坏缓存 三条路都能跨 isolate 往返', () async {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;

      // 未命中:算出来的 = 老路径,并写下缓存。
      expect(cacheFile().existsSync(), isFalse);
      final first = await compute(loadReviewCloudCached, req());
      expect(first, isNotNull);
      _expectSameCloud(expected, first!);
      expect(cacheFile().lengthSync(), fullLength);

      // 命中:种哨兵后经 isolate 读到的就是哨兵 ⇒ 后台 isolate 真的读了缓存。
      final planted = plantSentinel();
      final hit = await compute(loadReviewCloudCached, req());
      expect(hit!.xyz[0], _kSentinel);

      // 坏缓存:截一半 ⇒ isolate 里退回重算,拿到正确点云,不抛。
      cacheFile().writeAsBytesSync(
        planted.sublist(0, planted.length ~/ 2),
        flush: true,
      );
      final recovered = await compute(loadReviewCloudCached, req());
      expect(recovered, isNotNull);
      expect(recovered!.xyz[0], isNot(_kSentinel));
      _expectSameCloud(expected, recovered);
    });

    test('cacheDir 为 null 时经 isolate 逐字走老路径,一个文件都不写', () async {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      final got = await compute(
        loadReviewCloudCached,
        ReviewCloudRequest(plyPath: ply.path, cacheDir: null, budget: budget),
      );
      _expectSameCloud(expected, got!);
      expect(cacheDir.listSync(), isEmpty);
    });
  });
}
