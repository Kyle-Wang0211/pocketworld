// B1 配方化的机件测试(不含真再生——那属于设备门 pw_b1_gate)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_transaction.dart';
import 'package:pocketworld_flutter/official_capture/database_recipe_transaction.dart';

class _NoopDbCodec implements DatabaseArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> compress(
          {required File sourceDatabase, required File destinationArchive}) =>
      throw UnsupportedError('must not run for recipe captures');

  @override
  Future<void> decompress(
          {required File sourceArchive, required File destinationDatabase}) =>
      throw UnsupportedError('not used');

  @override
  void requestCancellation() {}
}

void main() {
  late Directory captureDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_recipe_');
    await DatabaseArchivePolicy.writeForNewCapture(captureDir);
  });

  tearDown(() async {
    if (await captureDir.exists()) await captureDir.delete(recursive: true);
  });

  Future<void> writeRecipe() async {
    await File('${captureDir.path}/${DatabaseRecipeManifest.fileName}')
        .writeAsString(jsonEncode({
      'schema': DatabaseRecipeManifest.schema,
      'grade': 'semantic',
      'frame_count': 1,
      'frames': [
        {'name': 'a.jpg', 'sidecar_sha256': 'x'},
      ],
    }));
  }

  test('生产总闸关闭:recipeCapture 恒不适用,不删任何字节', () async {
    final db = File(
        '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}');
    await db.writeAsBytes(List.filled(4096, 1));
    final r = await const DatabaseRecipeTransaction()
        .recipeCapture(captureDir);
    expect(DatabaseRecipeTransaction.enabled, isFalse,
        reason: '设备 V4/V5 门未过前禁止翻闸');
    expect(r.applicable, isFalse);
    expect(r.reason, 'gate_closed');
    expect(await db.exists(), isTrue);
  });

  test('recipe manifest 读写与 schema 门', () async {
    expect(await DatabaseRecipeManifest.exists(captureDir), isFalse);
    await writeRecipe();
    expect(await DatabaseRecipeManifest.exists(captureDir), isTrue);
    final json = await DatabaseRecipeManifest.read(captureDir);
    expect(json!['grade'], 'semantic');
    // 错 schema 一律判 null。
    await File('${captureDir.path}/${DatabaseRecipeManifest.fileName}')
        .writeAsString(jsonEncode({'schema': 'wrong'}));
    expect(await DatabaseRecipeManifest.read(captureDir), isNull);
  });

  test('ZPAQ 事务对已配方化 capture 直接 skip(不触碰 codec)', () async {
    await writeRecipe();
    // durable artifacts 齐全也必须 skip 在 recipe 检查这一步。
    for (final rel in [
      'official_photo_bundle.json',
      'official_sfm_sparse.ply',
      'official_sfm_sparse_meta.json',
    ]) {
      await File('${captureDir.path}/$rel').writeAsBytes([1, 2, 3]);
    }
    final result = await DatabaseArchiveTransaction(codec: _NoopDbCodec())
        .archiveCapture(captureDir);
    expect(result.skipped, isTrue);
    expect(result.failed, isFalse);
  });

  test('resolver 认得配方化 capture:isRecoverable=true', () async {
    await writeRecipe();
    final resolver = DatabaseArchiveResolver(codec: _NoopDbCodec());
    expect(await resolver.isRecoverable(captureDir), isTrue);
  });
}
