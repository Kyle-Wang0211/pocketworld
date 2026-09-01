// 附属物归档(侧车 + 诊断日志)的合同测试。
//
// 产品编解码器是 iOS 静态链接的 ZPAQ,单测跑不了;这里用一个**逐字节
// 复制**的假编解码器,把事务本身的合同全部钉住:容器可逆、逐条目对账、
// source-last 删除、幂等、以及任一环节不过就一个字节不动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/aux_archive_container.dart';
import 'package:pocketworld_flutter/official_capture/aux_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/aux_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/aux_archive_transaction.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';

/// 逐字节复制。可切换成"损坏一个字节"来验证 fail-closed。
class _CopyCodec implements DatabaseArchiveCodec {
  _CopyCodec({this.corruptOnDecompress = false});

  bool corruptOnDecompress;

  @override
  bool get isSupported => true;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    await destinationArchive.writeAsBytes(
      await sourceDatabase.readAsBytes(),
      flush: true,
    );
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) async {
    final bytes = Uint8List.fromList(await sourceArchive.readAsBytes());
    if (corruptOnDecompress && bytes.isNotEmpty) {
      bytes[bytes.length ~/ 2] ^= 0xff;
    }
    await destinationDatabase.writeAsBytes(bytes, flush: true);
  }

  @override
  void requestCancellation() {}
}

void main() {
  late Directory captureDir;

  Future<void> writeDurableArtifacts() async {
    await File('${captureDir.path}/official_sfm_sparse.ply').writeAsString('p');
    await File(
      '${captureDir.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{}');
  }

  Future<List<File>> writeSidecars(int count) async {
    final dir = Directory('${captureDir.path}/photos_highres');
    await dir.create(recursive: true);
    final files = <File>[];
    for (var index = 0; index < count; index++) {
      final file = File('${dir.path}/official_tap-$index.json');
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'anchors_world': <List<double>>[
            <double>[index + 0.5, 1.25, -2.5],
          ],
          'anchor_ids': <int>[100000 + index],
          't': 1234.5 + index,
        }),
      );
      files.add(file);
    }
    return files;
  }

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_aux_');
  });

  tearDown(() async {
    if (await captureDir.exists()) await captureDir.delete(recursive: true);
  });

  group('PWSC1 容器', () {
    test('编解码逐字节可逆,且条目顺序与写入顺序无关', () {
      final a = AuxContainerEntry(
        relativePath: 'b/second.json',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      final b = AuxContainerEntry(
        relativePath: 'a/first.json',
        bytes: Uint8List.fromList(<int>[9]),
      );
      final one = encodeAuxContainer(<AuxContainerEntry>[a, b]);
      final two = encodeAuxContainer(<AuxContainerEntry>[b, a]);
      expect(one, two, reason: '同一批文件必须生成逐字节相同的容器');
      final decoded = decodeAuxContainer(one);
      expect(decoded.map((e) => e.relativePath), <String>[
        'a/first.json',
        'b/second.json',
      ]);
      expect(decoded[1].bytes, a.bytes);
    });

    test('空容器可逆', () {
      expect(decodeAuxContainer(encodeAuxContainer(const [])), isEmpty);
    });

    test('坏 magic / 截断 / 尾部多字节 一律抛出', () {
      final good = encodeAuxContainer(<AuxContainerEntry>[
        AuxContainerEntry(
          relativePath: 'x.json',
          bytes: Uint8List.fromList(<int>[7, 7]),
        ),
      ]);
      final badMagic = Uint8List.fromList(good)..[0] = 0;
      expect(() => decodeAuxContainer(badMagic), throwsA(isA<Exception>()));
      expect(
        () =>
            decodeAuxContainer(Uint8List.sublistView(good, 0, good.length - 1)),
        throwsA(isA<Exception>()),
      );
      expect(
        () => decodeAuxContainer(Uint8List.fromList(<int>[...good, 0])),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('归档事务', () {
    test('侧车:压缩→回读对账→写清单→删源(source-last)', () async {
      await writeDurableArtifacts();
      final sidecars = await writeSidecars(5);
      final before = <String, String>{
        for (final file in sidecars)
          file.path: sha256.convert(await file.readAsBytes()).toString(),
      };

      final result = await AuxArchiveTransaction(
        codec: _CopyCodec(),
      ).archiveCapture(captureDir);

      expect(result.applicable, isTrue);
      expect(result.committedBundles, contains(kAuxSidecarBundleId));
      for (final file in sidecars) {
        expect(await file.exists(), isFalse, reason: '校验通过后源文件才消失');
      }
      final manifest = await AuxArchiveManifest.read(captureDir);
      final bundle = manifest!.bundles[kAuxSidecarBundleId]!;
      expect(bundle.files, hasLength(5));
      // 清单里的逐文件摘要必须等于归档前的真实摘要。
      for (final file in bundle.files) {
        final original = before.entries
            .firstWhere(
              (e) => e.key.endsWith(file.relativePath.split('/').last),
            )
            .value;
        expect(file.sha256, original);
      }
      expect(
        await File('${captureDir.path}/$kAuxSidecarArchiveFileName').exists(),
        isTrue,
      );
    });

    test('解压对不上时:归档不写、源文件一个字节不动', () async {
      await writeDurableArtifacts();
      final sidecars = await writeSidecars(3);
      final result = await AuxArchiveTransaction(
        codec: _CopyCodec(corruptOnDecompress: true),
      ).archiveCapture(captureDir);

      expect(result.failed, isTrue);
      expect(result.committedBundles, isEmpty);
      for (final file in sidecars) {
        expect(await file.exists(), isTrue);
      }
      expect(await AuxArchiveManifest.read(captureDir), isNull);
      expect(
        await File('${captureDir.path}/$kAuxSidecarArchiveFileName').exists(),
        isFalse,
      );
    });

    test('未出交付物(ply/meta)时不适用,不碰任何文件', () async {
      final sidecars = await writeSidecars(2);
      final result = await AuxArchiveTransaction(
        codec: _CopyCodec(),
      ).archiveCapture(captureDir);
      expect(result.applicable, isFalse);
      expect(result.reason, 'not_ready');
      for (final file in sidecars) {
        expect(await file.exists(), isTrue);
      }
    });

    test('幂等:源已归档后再跑一次不产生新提交', () async {
      await writeDurableArtifacts();
      await writeSidecars(4);
      final codec = _CopyCodec();
      await AuxArchiveTransaction(codec: codec).archiveCapture(captureDir);
      final second = await AuxArchiveTransaction(
        codec: codec,
      ).archiveCapture(captureDir);
      expect(second.committedBundles, isEmpty);
      expect(second.deletedBytes, 0);
    });

    test('诊断日志:第二轮新文件作为新世代并入,旧世代逐字节保留', () async {
      await writeDurableArtifacts();
      final log = File('${captureDir.path}/$kAuxDiagLogSourceName');
      await log.writeAsString('{"a":1}\n{"a":2}\n');
      final codec = _CopyCodec();
      await AuxArchiveTransaction(codec: codec).archiveCapture(captureDir);
      expect(await log.exists(), isFalse);

      // 核在下一轮重建时会新建一个只含新行的文件。
      await log.writeAsString('{"b":3}\n');
      final second = await AuxArchiveTransaction(
        codec: codec,
      ).archiveCapture(captureDir);
      expect(second.committedBundles, contains(kAuxDiagLogBundleId));

      final manifest = await AuxArchiveManifest.read(captureDir);
      final bundle = manifest!.bundles[kAuxDiagLogBundleId]!;
      expect(bundle.files.map((f) => f.relativePath), <String>[
        kAuxDiagLogSourceName,
        '$kAuxDiagLogSourceName.1',
      ]);
      final restored = await restoreAuxBundle(
        captureDirectory: captureDir,
        bundle: bundle,
        codec: codec,
      );
      expect(
        utf8.decode(restored![0].bytes),
        '{"a":1}\n{"a":2}\n',
        reason: '第一代必须逐字节等于当初的源文件',
      );
      expect(utf8.decode(restored[1].bytes), '{"b":3}\n');
    });
  });

  group('侧车 resolver', () {
    test('未归档时直接给 photos_highres', () async {
      await writeSidecars(2);
      final session = await AuxArchiveResolver(
        codec: _CopyCodec(),
      ).openSidecars(captureDir);
      expect(session, isNotNull);
      expect(session!.materialized, isFalse);
      expect(session.directory.path, endsWith('photos_highres'));
      await session.dispose();
    });

    test('归档后物化出内容相同的临时目录,dispose 后清理', () async {
      await writeDurableArtifacts();
      final sidecars = await writeSidecars(3);
      final expected = <String, String>{
        for (final file in sidecars)
          file.uri.pathSegments.last: await file.readAsString(),
      };
      final codec = _CopyCodec();
      await AuxArchiveTransaction(codec: codec).archiveCapture(captureDir);

      final session = await AuxArchiveResolver(
        codec: codec,
      ).openSidecars(captureDir);
      expect(session, isNotNull);
      expect(session!.materialized, isTrue);
      for (final entry in expected.entries) {
        final file = File('${session.directory.path}/${entry.key}');
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), entry.value);
      }
      final path = session.directory.path;
      await session.dispose();
      expect(await Directory(path).exists(), isFalse);
    });

    test('归档文件被改坏时返回 null(fail closed)', () async {
      await writeDurableArtifacts();
      await writeSidecars(2);
      final codec = _CopyCodec();
      await AuxArchiveTransaction(codec: codec).archiveCapture(captureDir);
      final archive = File('${captureDir.path}/$kAuxSidecarArchiveFileName');
      final bytes = Uint8List.fromList(await archive.readAsBytes());
      bytes[bytes.length ~/ 2] ^= 0xff;
      await archive.writeAsBytes(bytes, flush: true);

      expect(
        await AuxArchiveResolver(codec: codec).openSidecars(captureDir),
        isNull,
      );
    });
  });
}
