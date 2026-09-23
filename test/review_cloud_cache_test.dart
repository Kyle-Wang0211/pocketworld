// review_cloud_cache_test.dart — 复看点云磁盘缓存的判据。
//
// 每一条判据都带阳性对照:先证明「好输入」上是绿的(缓存命中/文件确实写出来了),
// 再把那一条判据单独弄坏,证明它变红(退回重算)。没有阳性对照的阴性断言等于
// 没断言 —— 一个永远返回 null 的 decode 也能让所有阴性对照通过。
//
// 静默出口是本项目的头号复发缺陷,所以「退回重算」本身也是判据:退回之后
// **必须仍然拿到正确的点云**,而不是拿到 null / 抛出去。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/review_cloud_cache.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart'
    show SparseCloudData, loadReviewCloudWithBudget;

/// 写一份和 sparse_ply.dart 同格式的二进制 PLY(xyz float32 LE + rgb uchar)。
File _writePly(Directory dir, String name, int count, {int seed = 1}) {
  final body = Uint8List(count * 15);
  final bd = ByteData.sublistView(body);
  for (var i = 0; i < count; i++) {
    final o = i * 15;
    // 刻意撒开:让八叉树排序真的有活干(全挤一点的话每层只选一个)。
    bd.setFloat32(o, ((i * 37 + seed) % 101).toDouble(), Endian.little);
    bd.setFloat32(o + 4, ((i * 53 + seed) % 97).toDouble(), Endian.little);
    bd.setFloat32(o + 8, ((i * 71 + seed) % 89).toDouble(), Endian.little);
    body[o + 12] = i & 0xFF;
    body[o + 13] = (i >> 8) & 0xFF;
    body[o + 14] = (i * 7) & 0xFF;
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

List<File> _cacheFiles(Directory dir) =>
    dir.listSync().whereType<File>().where((f) {
      return f.path.endsWith(ReviewCloudCache.kFileSuffix);
    }).toList();

void _expectSameCloud(SparseCloudData a, SparseCloudData b) {
  expect(b.count, a.count);
  expect(b.sourceCount, a.sourceCount);
  expect(b.xyz, orderedEquals(a.xyz));
  expect(b.rgb, orderedEquals(a.rgb));
}

void main() {
  late Directory root;
  late Directory captureDir;
  late Directory cacheDir;
  late File ply;
  const budget = 50;
  const pointCount = 400;

  setUp(() {
    root = Directory.systemTemp.createTempSync('review_cloud_cache_test');
    // 会话目录 captures_official/<cap_id>/ 与缓存目录是**兄弟**,不是父子。
    // (线上缓存目录在系统缓存目录 Library/Caches/review_cache,根本不在
    // Documents 下 —— 那条由 review_cloud_cache_hardening_test.dart 的
    // D 组用真解析出来的路径钉;这里只需要「不在会话目录里」。)
    captureDir = Directory('${root.path}/captures_official/cap_1')
      ..createSync(recursive: true);
    cacheDir = Directory('${root.path}/${ReviewCloudCache.kDirName}')
      ..createSync(recursive: true);
    ply = _writePly(captureDir, 'official_dense.ply', pointCount);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ReviewCloudRequest req({String? dir, int b = budget, File? source}) =>
      ReviewCloudRequest(
        plyPath: (source ?? ply).path,
        cacheDir: dir ?? cacheDir.path,
        budget: b,
      );

  group('阳性对照:缓存确实建立、确实被读', () {
    test('第一次打开算出来的东西 = 不带缓存的老路径,一个数都不差', () {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      final first = loadReviewCloudCached(req())!;
      _expectSameCloud(expected, first);
      // 预算真的咬住了(否则这条测试测的是「没截断」的平凡情形)。
      expect(first.count, budget);
      expect(first.sourceCount, pointCount);
      expect(first.isBudgeted, isTrue);
    });

    test('第一次打开会在旁路目录留下一个缓存文件', () {
      expect(_cacheFiles(cacheDir), isEmpty);
      loadReviewCloudCached(req());
      final files = _cacheFiles(cacheDir);
      expect(files.length, 1);
      expect(
        files.single.lengthSync(),
        greaterThan(ReviewCloudCache.kHeaderBytes),
      );
      // 临时文件不许留下。
      expect(
        cacheDir.listSync().where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('第二次打开读的是缓存,不是重算(把缓存换成另一份合法数据就能看出来)', () {
      final first = loadReviewCloudCached(req())!;
      final stat = ply.statSync();
      // 同样的头(预算/长度/mtime/路径都对得上),但点数据是改过的。
      final tamperedXyz = Float32List.fromList(first.xyz);
      tamperedXyz[0] = 12345.0;
      final file = ReviewCloudCache.fileFor(
        cacheDir: cacheDir.path,
        plyPath: ply.path,
        budget: budget,
      );
      expect(
        ReviewCloudCache.writeEntry(
          file,
          xyz: tamperedXyz,
          rgb: first.rgb,
          sourceCount: first.sourceCount,
          budget: budget,
          sourceLength: stat.size,
          sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
          plyPath: ply.path,
        ),
        isTrue,
      );
      final second = loadReviewCloudCached(req())!;
      // 读到的是被改过的那份 ⇒ 证明它没有重新解 PLY、没有重跑八叉树。
      expect(second.xyz[0], 12345.0);
    });

    test('编解码是恒等的:xyz / rgb / sourceCount 原样回来', () {
      final cloud = loadReviewCloudWithBudget(ply.path, budget)!;
      final bytes = ReviewCloudCache.encode(
        xyz: cloud.xyz,
        rgb: cloud.rgb,
        sourceCount: cloud.sourceCount,
        budget: budget,
        sourceLength: 111,
        sourceModifiedMs: 222,
        plyPath: ply.path,
      );
      final back = ReviewCloudCache.decode(
        bytes,
        budget: budget,
        sourceLength: 111,
        sourceModifiedMs: 222,
        plyPath: ply.path,
      )!;
      expect(back.xyz, orderedEquals(cloud.xyz));
      expect(back.rgb, orderedEquals(cloud.rgb));
      expect(back.sourceCount, cloud.sourceCount);
    });
  });

  group('硬约束:缓存不许写进会话目录', () {
    test('两次打开之后 captures_official/<cap_id>/ 里的条目一个没多', () {
      final before =
          captureDir.listSync(recursive: true).map((e) => e.path).toList()
            ..sort();
      loadReviewCloudCached(req());
      loadReviewCloudCached(req());
      final after =
          captureDir.listSync(recursive: true).map((e) => e.path).toList()
            ..sort();
      expect(after, orderedEquals(before));
      // 阳性对照:同一时间缓存目录里**确实**多了东西,不是「两边都没写」。
      expect(_cacheFiles(cacheDir), isNotEmpty);
    });

    test('缓存文件的路径落在缓存目录里,且不含 captures_official', () {
      loadReviewCloudCached(req());
      final f = _cacheFiles(cacheDir).single;
      expect(f.parent.path, cacheDir.path);
      expect(f.path.contains('captures_official'), isFalse);
    });
  });

  group('失效判据(每条都先证明不动它时命中)', () {
    /// 把缓存换成「一眼能认出来」的哨兵数据;返回后若还读得到哨兵 = 命中缓存。
    void plantSentinel({int? sourceLength, int? sourceModifiedMs}) {
      final cloud = loadReviewCloudCached(req())!;
      final stat = ply.statSync();
      final xyz = Float32List.fromList(cloud.xyz);
      xyz[0] = -999.0;
      ReviewCloudCache.writeEntry(
        ReviewCloudCache.fileFor(
          cacheDir: cacheDir.path,
          plyPath: ply.path,
          budget: budget,
        ),
        xyz: xyz,
        rgb: cloud.rgb,
        sourceCount: cloud.sourceCount,
        budget: budget,
        sourceLength: sourceLength ?? stat.size,
        sourceModifiedMs:
            sourceModifiedMs ?? stat.modified.millisecondsSinceEpoch,
        plyPath: ply.path,
      );
    }

    test('源文件大小变了 ⇒ 重建(不是读到旧数据)', () {
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0); // 阳性对照:命中
      final mtime = ply.lastModifiedSync();
      final sizeBefore = ply.lengthSync();
      ply.writeAsBytesSync(
        Uint8List.fromList(<int>[...ply.readAsBytesSync(), 0, 0, 0, 0]),
        flush: true,
      );
      ply.setLastModifiedSync(mtime); // 只留「大小」这一个自变量
      expect(ply.lengthSync(), sizeBefore + 4);
      expect(
        ply.statSync().modified.millisecondsSinceEpoch,
        mtime.millisecondsSinceEpoch,
      );
      final rebuilt = loadReviewCloudCached(req())!;
      expect(rebuilt.xyz[0], isNot(-999.0));
      _expectSameCloud(loadReviewCloudWithBudget(ply.path, budget)!, rebuilt);
    });

    test('源文件 mtime 变了(大小不变)⇒ 重建', () {
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0); // 阳性对照:命中
      final sizeBefore = ply.lengthSync();
      ply.setLastModifiedSync(
        ply.lastModifiedSync().add(const Duration(seconds: 5)),
      );
      expect(ply.lengthSync(), sizeBefore); // 大小确实没动
      expect(loadReviewCloudCached(req())!.xyz[0], isNot(-999.0));
    });

    test('预算变了 ⇒ 重建,且两个预算各有各的缓存文件', () {
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0); // 阳性对照:命中
      final other = loadReviewCloudCached(req(b: budget + 7))!;
      expect(other.count, budget + 7);
      expect(other.xyz[0], isNot(-999.0));
      expect(_cacheFiles(cacheDir).length, 2);
      // 老预算的那份没被冲掉。
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0);
    });

    test('缓存格式版本不符 ⇒ 重建', () {
      final cloud = loadReviewCloudCached(req())!;
      final stat = ply.statSync();
      final bytes = ReviewCloudCache.encode(
        xyz: cloud.xyz,
        rgb: cloud.rgb,
        sourceCount: cloud.sourceCount,
        budget: budget,
        sourceLength: stat.size,
        sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
        plyPath: ply.path,
      );
      // 阳性对照:不动版本号时 decode 得出来。
      expect(
        ReviewCloudCache.decode(
          bytes,
          budget: budget,
          sourceLength: stat.size,
          sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
          plyPath: ply.path,
        ),
        isNotNull,
      );
      // 对照 _resign 本身:只重签不改内容,必须还是能 decode —— 否则下面那条
      // 阴性对照测的其实是「校验和被我算错了」,不是版本号。
      final resigned = Uint8List.fromList(bytes);
      _resign(resigned);
      expect(
        ReviewCloudCache.decode(
          resigned,
          budget: budget,
          sourceLength: stat.size,
          sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
          plyPath: ply.path,
        ),
        isNotNull,
      );
      // 只把版本号 +1(校验和也一并重算,免得这条测的其实是校验和)。
      final bumped = Uint8List.fromList(bytes);
      ByteData.sublistView(
        bumped,
      ).setUint32(8, ReviewCloudCache.kFormatVersion + 1, Endian.little);
      _resign(bumped);
      expect(
        ReviewCloudCache.decode(
          bumped,
          budget: budget,
          sourceLength: stat.size,
          sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
          plyPath: ply.path,
        ),
        isNull,
      );
    });

    test('换一个源路径 ⇒ 不会拿别人的缓存', () {
      plantSentinel();
      final other = _writePly(
        captureDir,
        'official_sfm_sparse.ply',
        pointCount,
      );
      final loaded = loadReviewCloudCached(req(source: other))!;
      expect(loaded.xyz[0], isNot(-999.0));
      expect(_cacheFiles(cacheDir).length, 2);
    });

    test('缓存文件尾巴上多了几个字节 ⇒ 弃用(长度必须严丝合缝)', () {
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0); // 阳性对照:命中
      final file = _cacheFiles(cacheDir).single;
      // 尾部追加:校验和字段的位置由点数算出来,还在原处、还是对的 ⇒ 只有
      // 「文件长度必须正好等于算出来的长度」这一条判据能挡住它。
      file.writeAsBytesSync(<int>[
        ...file.readAsBytesSync(),
        1, 2, 3, 4, 5, 6, 7, 8, //
      ], flush: true);
      expect(loadReviewCloudCached(req())!.xyz[0], isNot(-999.0));
    });

    test('魔数被改 ⇒ 弃用(哪怕校验和重算过、其它判据全对)', () {
      plantSentinel();
      expect(loadReviewCloudCached(req())!.xyz[0], -999.0); // 阳性对照:命中
      final file = _cacheFiles(cacheDir).single;
      final bytes = file.readAsBytesSync();
      bytes[0] = bytes[0] ^ 0x01;
      _resign(bytes); // 把校验和补对,确保挡住它的是魔数而不是校验和
      file.writeAsBytesSync(bytes, flush: true);
      expect(loadReviewCloudCached(req())!.xyz[0], isNot(-999.0));
    });

    test('缓存文件名撞车时靠头里的源路径哈希兜住(不会把别的项目的云端上来)', () {
      final other = _writePly(captureDir, 'other.ply', pointCount, seed: 9);
      other.setLastModifiedSync(ply.lastModifiedSync());
      final stat = other.statSync();
      expect(stat.size, ply.statSync().size); // 大小/mtime 两条判据都对得上
      final target = ReviewCloudCache.fileFor(
        cacheDir: cacheDir.path,
        plyPath: other.path,
        budget: budget,
      );
      final cloud = loadReviewCloudWithBudget(ply.path, budget)!;
      final sentinel = Float32List.fromList(cloud.xyz);
      sentinel[0] = -999.0;

      Uint8List encodeFor(String pathInHeader) => ReviewCloudCache.encode(
        xyz: sentinel,
        rgb: cloud.rgb,
        sourceCount: cloud.sourceCount,
        budget: budget,
        sourceLength: stat.size,
        sourceModifiedMs: stat.modified.millisecondsSinceEpoch,
        plyPath: pathInHeader,
      );

      // 阳性对照:头里写的就是 other 自己 ⇒ 命中,读到哨兵。
      target.writeAsBytesSync(encodeFor(other.path), flush: true);
      expect(loadReviewCloudCached(req(source: other))!.xyz[0], -999.0);

      // 同一个文件名,头里却写着另一条源路径 ⇒ 必须弃用并重算。
      target.writeAsBytesSync(encodeFor(ply.path), flush: true);
      final rebuilt = loadReviewCloudCached(req(source: other))!;
      expect(rebuilt.xyz[0], isNot(-999.0));
      _expectSameCloud(loadReviewCloudWithBudget(other.path, budget)!, rebuilt);
    });

    test('字节序哨兵不对 ⇒ 弃用缓存', () {
      final cloud = loadReviewCloudCached(req())!;
      final bytes = ReviewCloudCache.encode(
        xyz: cloud.xyz,
        rgb: cloud.rgb,
        sourceCount: cloud.sourceCount,
        budget: budget,
        sourceLength: 5,
        sourceModifiedMs: 6,
        plyPath: ply.path,
      );
      expect(
        ReviewCloudCache.decode(
          bytes,
          budget: budget,
          sourceLength: 5,
          sourceModifiedMs: 6,
          plyPath: ply.path,
        ),
        isNotNull,
      ); // 阳性对照
      final flipped = Uint8List.fromList(bytes);
      // 把哨兵按大端重写 = 模拟一台大端机器写出来的文件。
      ByteData.sublistView(flipped).setUint32(12, 0x01020304, Endian.big);
      _resign(flipped);
      expect(
        ReviewCloudCache.decode(
          flipped,
          budget: budget,
          sourceLength: 5,
          sourceModifiedMs: 6,
          plyPath: ply.path,
        ),
        isNull,
      );
    });
  });

  group('静默退回:缓存坏掉时用户照样打得开', () {
    test('缓存被截断 ⇒ 仍然拿到正确点云,并且缓存被重写成好的', () {
      final good = loadReviewCloudCached(req())!;
      final file = _cacheFiles(cacheDir).single;
      final full = file.readAsBytesSync();
      file.writeAsBytesSync(full.sublist(0, full.length ~/ 2), flush: true);
      final recovered = loadReviewCloudCached(req())!;
      _expectSameCloud(good, recovered);
      // 自愈:再打开一次应该是命中缓存的(文件长度回到完整长度)。
      expect(file.lengthSync(), full.length);
    });

    test('缓存里一个字节被翻掉(长度不变)⇒ 校验和抓住,仍然拿到正确点云', () {
      final good = loadReviewCloudCached(req())!;
      final file = _cacheFiles(cacheDir).single;
      final bytes = file.readAsBytesSync();
      final at = ReviewCloudCache.kHeaderBytes + 3; // 点数据区
      bytes[at] = bytes[at] ^ 0xFF;
      file.writeAsBytesSync(bytes, flush: true);
      expect(file.lengthSync(), bytes.length); // 长度确实没变
      _expectSameCloud(good, loadReviewCloudCached(req())!);
    });

    test('缓存是一堆垃圾 / 空文件 ⇒ 仍然拿到正确点云', () {
      final good = loadReviewCloudCached(req())!;
      final file = _cacheFiles(cacheDir).single;
      file.writeAsBytesSync(Uint8List(0), flush: true);
      _expectSameCloud(good, loadReviewCloudCached(req())!);
      file.writeAsStringSync('not a cache at all, just some text ' * 40);
      _expectSameCloud(good, loadReviewCloudCached(req())!);
    });

    // 注:这条同时被「文件长度必须严丝合缝」兜住,属于纵深防御 —— 单独摘掉
    // _kMaxDecodablePoints 这一行本测试仍是绿的(见 commit message 里的变异记录)。
    // 留着它是为了在点数乘法溢出时也不会先去开一个天文数字的数组。
    test('头里写了一个天文数字的点数 ⇒ 直接弃用,不去开那个数组', () {
      final good = loadReviewCloudCached(req())!;
      final file = _cacheFiles(cacheDir).single;
      final bytes = file.readAsBytesSync();
      ByteData.sublistView(
        bytes,
      ).setInt64(48, 1 << 40, Endian.little); // storedCount
      ByteData.sublistView(bytes).setInt64(40, 1 << 41, Endian.little);
      file.writeAsBytesSync(bytes, flush: true);
      _expectSameCloud(good, loadReviewCloudCached(req())!);
    });

    test('缓存目录写不进去(路径被一个文件占着)⇒ 仍然拿到正确点云', () {
      final blocked = File('${root.path}/blocked');
      blocked.writeAsStringSync('x');
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      _expectSameCloud(
        expected,
        loadReviewCloudCached(req(dir: blocked.path))!,
      );
      // 再来一次也一样(不会因为上次写失败就残留状态)。
      _expectSameCloud(
        expected,
        loadReviewCloudCached(req(dir: blocked.path))!,
      );
    });

    test('没有缓存目录(null)⇒ 逐字走老路径,一个文件都不写', () {
      final expected = loadReviewCloudWithBudget(ply.path, budget)!;
      final got = loadReviewCloudCached(
        ReviewCloudRequest(plyPath: ply.path, cacheDir: null, budget: budget),
      )!;
      _expectSameCloud(expected, got);
      expect(_cacheFiles(cacheDir), isEmpty);
    });

    test('源 PLY 不存在 ⇒ null(和改动前一样),不写缓存', () {
      final missing = '${captureDir.path}/nope.ply';
      expect(
        loadReviewCloudCached(
          ReviewCloudRequest(plyPath: missing, cacheDir: cacheDir.path),
        ),
        isNull,
      );
      expect(_cacheFiles(cacheDir), isEmpty);
    });

    test('源 PLY 在但不是合法 PLY ⇒ null,不写缓存', () {
      final junk = File('${captureDir.path}/junk.ply')
        ..writeAsStringSync('definitely not a ply');
      expect(
        loadReviewCloudCached(
          ReviewCloudRequest(plyPath: junk.path, cacheDir: cacheDir.path),
        ),
        isNull,
      );
      expect(_cacheFiles(cacheDir), isEmpty);
    });
  });

  group('目录不会无限长大', () {
    test('超过上限时按 mtime 从旧到新删,只动自己的文件', () {
      final keep = File('${cacheDir.path}/unrelated.txt')
        ..writeAsStringSync('leave me alone');
      final made = <File>[];
      for (var i = 0; i < 5; i++) {
        final f = File('${cacheDir.path}/f$i${ReviewCloudCache.kFileSuffix}')
          ..writeAsBytesSync(Uint8List(128));
        f.setLastModifiedSync(DateTime(2026, 1, 1 + i));
        made.add(f);
      }
      // 阳性对照:上限够大时一个都不删。
      ReviewCloudCache.prune(cacheDir.path, maxEntries: 5);
      expect(made.where((f) => f.existsSync()).length, 5);

      ReviewCloudCache.prune(cacheDir.path, maxEntries: 2);
      expect(made[0].existsSync(), isFalse);
      expect(made[1].existsSync(), isFalse);
      expect(made[2].existsSync(), isFalse);
      expect(made[3].existsSync(), isTrue); // 最新的两份留下
      expect(made[4].existsSync(), isTrue);
      expect(keep.existsSync(), isTrue); // 不是自己的文件不碰
    });

    test('字节上限也咬得住', () {
      final made = <File>[];
      for (var i = 0; i < 3; i++) {
        final f = File('${cacheDir.path}/b$i${ReviewCloudCache.kFileSuffix}')
          ..writeAsBytesSync(Uint8List(1000));
        f.setLastModifiedSync(DateTime(2026, 2, 1 + i));
        made.add(f);
      }
      ReviewCloudCache.prune(cacheDir.path, maxEntries: 99, maxBytes: 3000);
      expect(made.where((f) => f.existsSync()).length, 3); // 阳性对照
      ReviewCloudCache.prune(cacheDir.path, maxEntries: 99, maxBytes: 2000);
      expect(made[0].existsSync(), isFalse);
      expect(made[1].existsSync(), isTrue);
      expect(made[2].existsSync(), isTrue);
    });

    test('写了一半留下的 .rcc.tmp 够旧就收走,正在写的那份不动', () {
      final stale = File('${cacheDir.path}/aaaa.rcc.tmp')
        ..writeAsBytesSync(Uint8List(64));
      stale.setLastModifiedSync(
        DateTime.now().subtract(ReviewCloudCache.kTmpStaleAfter * 2),
      );
      final fresh = File('${cacheDir.path}/bbbb.rcc.tmp')
        ..writeAsBytesSync(Uint8List(64));
      expect(stale.existsSync(), isTrue); // 阳性对照:两份都在
      expect(fresh.existsSync(), isTrue);
      ReviewCloudCache.prune(cacheDir.path);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('prune 在目录不存在时不抛', () {
      expect(
        () => ReviewCloudCache.prune('${root.path}/no/such/dir'),
        returnsNormally,
      );
    });
  });
}

/// 改过头之后把末尾的校验和重算一遍 —— 这样阴性对照测的是被改的那一条判据
/// 本身,而不是「顺带把校验和弄坏了」。
void _resign(Uint8List bytes) {
  final checksumOffset = bytes.length - 4;
  var hash = 0x811c9dc5;
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < checksumOffset; i += 4) {
    hash = ((hash ^ bd.getUint32(i, Endian.little)) * 0x01000193) & 0xFFFFFFFF;
  }
  bd.setUint32(checksumOffset, hash, Endian.little);
}
