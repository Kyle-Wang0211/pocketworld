// 草稿卡片的稀疏点云缩略图 —— 离屏渲染 + 磁盘缓存。
//
// [2026-08-07 用户签决,学 Polycam] 卡片展示稀疏点云(斜上 45°、真彩、纯黑底)
// 而不是照片。这里守两件事:缓存的新鲜度判据(错了会让用户看到过期的点云),
// 以及初始视角常量(卡片与详情页必须同一姿态,否则放大那一下角度会跳)。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/sparse_thumbnail.dart';

/// 造一个最小合法 PLY(n 个点,真彩)。
Future<File> writePly(Directory dir, int n, {String name = 'p.ply'}) async {
  final head =
      'ply\nformat binary_little_endian 1.0\nelement vertex $n\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final body = BytesBuilder();
  for (var i = 0; i < n; i++) {
    final bd = ByteData(15);
    bd.setFloat32(0, i * 0.01, Endian.little);
    bd.setFloat32(4, (i % 7) * 0.01, Endian.little);
    bd.setFloat32(8, (i % 5) * 0.01, Endian.little);
    bd.setUint8(12, 200);
    bd.setUint8(13, 120);
    bd.setUint8(14, 60);
    body.add(bd.buffer.asUint8List());
  }
  final f = File('${dir.path}/$name');
  await f.writeAsBytes([...head.codeUnits, ...body.toBytes()]);
  return f;
}

void main() {
  test('初始视角常量:斜上 45°,且与"顶"预设同一条经线', () {
    // [2026-08-07 用户签决] "在草稿页面就展示稀疏点云(斜上45度)……打开后稀疏
    // 点云的默认角度也变成了斜上45度,而非正上方。"
    expect(kSparseThumbPitch, closeTo(-math.pi / 4, 1e-12));
    // yaw 必须与正俯视的"顶"预设同值(π):这样 45° → 正上方(进编辑页时)是
    // 同一条经线上的纯俯仰,不会横向甩一下。
    expect(kSparseThumbYaw, closeTo(math.pi, 1e-12));
    // 俯视是负 pitch —— 写成正的会变成从下往上看。
    expect(kSparseThumbPitch, lessThan(0), reason: '斜上应为负 pitch');
  });

  group('缓存新鲜度', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sparse_thumb_');
    });
    tearDown(() => dir.delete(recursive: true));

    test('没有 PLY ⇒ 不新鲜(还在生成中的记录不能显示旧图)', () async {
      final thumb = File(sparseThumbPathFor(dir.path));
      await thumb.writeAsBytes([1, 2, 3]);
      expect(
        sparseThumbFresh(
          plyPath: '${dir.path}/missing.ply',
          thumbPath: thumb.path,
        ),
        isFalse,
      );
    });

    test('有 PLY 没缩略图 ⇒ 不新鲜', () async {
      final ply = await writePly(dir, 8);
      expect(
        sparseThumbFresh(
          plyPath: ply.path,
          thumbPath: sparseThumbPathFor(dir.path),
        ),
        isFalse,
      );
    });

    test('空缩略图不算数 —— 写盘中途被读到会显示一片空白', () async {
      final ply = await writePly(dir, 8);
      final thumb = File(sparseThumbPathFor(dir.path));
      await thumb.writeAsBytes([]);
      expect(
        sparseThumbFresh(plyPath: ply.path, thumbPath: thumb.path),
        isFalse,
      );
    });

    test('缩略图比 PLY 旧 ⇒ 不新鲜(重跑重建后必须重画)', () async {
      final ply = await writePly(dir, 8);
      final thumb = File(sparseThumbPathFor(dir.path));
      await thumb.writeAsBytes([1, 2, 3]);
      // 把缩略图的时间戳推早到 PLY 之前。
      await thumb.setLastModified(
        ply.statSync().modified.subtract(const Duration(minutes: 5)),
      );
      expect(
        sparseThumbFresh(plyPath: ply.path, thumbPath: thumb.path),
        isFalse,
        reason: '过期缓存被当成新鲜 ⇒ 用户看到的是上一轮重建的点云',
      );
    });

    test('缩略图不比 PLY 旧 ⇒ 新鲜,不重画', () async {
      final ply = await writePly(dir, 8);
      final thumb = File(sparseThumbPathFor(dir.path));
      await thumb.writeAsBytes([1, 2, 3]);
      await thumb.setLastModified(
        ply.statSync().modified.add(const Duration(seconds: 1)),
      );
      expect(
        sparseThumbFresh(plyPath: ply.path, thumbPath: thumb.path),
        isTrue,
      );
    });
  });

  group('离屏渲染', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sparse_thumb_render_');
    });
    tearDown(() => dir.delete(recursive: true));

    test('点太少 ⇒ 不出图(空点云别产出一张纯黑方块)', () async {
      final sprite = await buildPointSprite();
      addTearDown(sprite.dispose);
      final bytes = await renderSparseThumbBytes(
        xyz: Float32List(0),
        rgb: Uint8List(0),
        sprite: sprite,
        size: 64,
      );
      expect(bytes, isNull);
    });

    test('ensureSparseThumb:出图、落盘、第二次直接命中缓存', () async {
      final ply = await writePly(dir, 64, name: 'official_sfm_sparse.ply');
      final sprite = await buildPointSprite();
      addTearDown(sprite.dispose);

      final p1 = await ensureSparseThumb(
        captureDir: dir.path,
        plyPath: ply.path,
        sprite: sprite,
      );
      expect(p1, sparseThumbPathFor(dir.path));
      final f = File(p1!);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(0), reason: '出了个空文件');
      // PNG magic —— 确认真是图片而不是别的东西。
      expect(f.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      // 第二次:缓存新鲜 ⇒ 不重画(mtime 不变)。
      final t1 = f.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final p2 = await ensureSparseThumb(
        captureDir: dir.path,
        plyPath: ply.path,
        sprite: sprite,
      );
      expect(p2, p1);
      expect(
        f.statSync().modified,
        t1,
        reason: '缓存新鲜却重画了 ⇒ 每次进草稿页都要重渲染十几张,热预算白烧',
      );
    });

    test('writeSparseThumbFrom:落盘现场直接出图,且比 PLY 新(不会被判过期)', () async {
      // [2026-08-08 用户实机指认] "点云诞生出来的那一刻就删除封面照片然后立刻替换
      // 成点云截图" —— 生成必须发生在 PLY 落盘现场,不能等草稿页轮询补图。
      final ply = await writePly(dir, 64, name: 'official_sfm_sparse.ply');
      final xyz = Float32List.fromList(
        List<double>.generate(64 * 3, (i) => (i % 11) * 0.01),
      );
      final rgb = Uint8List.fromList(
        List<int>.generate(64 * 3, (i) => i % 256),
      );

      final made = await writeSparseThumbFrom(
        captureDir: dir.path,
        xyz: xyz,
        rgb: rgb,
      );
      expect(made, sparseThumbPathFor(dir.path));
      final f = File(made!);
      expect(f.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      // 关键:必须在 PLY 之后写,否则 mtime 更旧 ⇒ 草稿页立刻判过期又重画一遍,
      // "落盘即出封面"就白做了。
      expect(
        sparseThumbFresh(plyPath: ply.path, thumbPath: made),
        isTrue,
        reason: '落盘现场画的封面被判成过期缓存 ⇒ 草稿页还会重画,跳变依旧',
      );
    });

    test('空点云 ⇒ 不产出封面文件(别在卡片上糊一块纯黑)', () async {
      final made = await writeSparseThumbFrom(
        captureDir: dir.path,
        xyz: Float32List(0),
        rgb: Uint8List(0),
      );
      expect(made, isNull);
      expect(File(sparseThumbPathFor(dir.path)).existsSync(), isFalse);
    });

    test('没有 PLY ⇒ 返回 null,不写出任何文件', () async {
      final p = await ensureSparseThumb(
        captureDir: dir.path,
        plyPath: '${dir.path}/nope.ply',
      );
      expect(p, isNull);
      expect(File(sparseThumbPathFor(dir.path)).existsSync(), isFalse);
    });
  });
}
