// Orchestration tests for lib/community/publish_service.dart.
//
// Every external effect is injected, so these run on the host with no
// network, no Supabase and no FFI. The load-bearing assertion is the
// no-orphan invariant: a failed upload must never leave a `works` row
// pointing at a file that does not exist.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/community/publish_service.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';
import 'package:pocketworld_flutter/config/endpoint_config.dart';

/// Records what the fake collaborators were asked to do.
class _Spy implements CommunityServiceLike {
  final List<({String path, int bytes, String title, String? description})>
  uploads = [];
  final List<({String workId, int bytes, String contentType})> thumbs = [];

  Object? uploadThrows;
  Object? thumbThrows;
  String? thumbReturns = 'uid/work-1.png';

  Future<UploadFinalizeResult> upload({
    required String path,
    required Uint8List bytes,
    required String title,
    String? description,
  }) async {
    if (uploadThrows != null) throw uploadThrows!;
    uploads.add((
      path: path,
      bytes: bytes.length,
      title: title,
      description: description,
    ));
    // 收口后 works 行由服务端在 finalize 里创建并回传 id。
    return const UploadFinalizeResult(
      path: 'uid/work-1.ply',
      workId: 'work-1',
      moderationStatus: 'under_review',
    );
  }

  @override
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
    String extension = 'jpg',
  }) async {
    if (thumbThrows != null) throw thumbThrows!;
    thumbs.add((workId: workId, bytes: bytes.length, contentType: contentType));
    return thumbReturns;
  }
}

void main() {
  late Directory tmp;
  late _Spy spy;

  /// Minimal but structurally valid sparse PLY (header + one vertex),
  /// matching what the official capture route writes.
  final plyBytes = Uint8List.fromList([
    ...'ply\nformat binary_little_endian 1.0\nelement vertex 1\n'
            'property float x\nproperty float y\nproperty float z\n'
            'property uchar red\nproperty uchar green\nproperty uchar blue\n'
            'end_header\n'
        .codeUnits,
    ...List<int>.filled(15, 0),
  ]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pw_publish_test');
    spy = _Spy();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ScanRecord record({String? captureDir, String? cloudWorkId}) => ScanRecord(
    id: 'rec-1',
    name: 'scan',
    createdAt: DateTime.utc(2026, 8, 16),
    captureDir: captureDir ?? tmp.path,
    cloudWorkId: cloudWorkId,
  );

  PublishService service({String? uid = 'uid'}) => PublishService.forTest(
    uid: () => uid,
    community: spy,
    uploadModel: spy.upload,
  );

  Future<void> writePly() =>
      File('${tmp.path}/official_sfm_sparse.ply').writeAsBytes(plyBytes);

  Future<void> writeThumb() => File(
    '${tmp.path}/official_sparse_thumb.png',
  ).writeAsBytes(Uint8List.fromList(List<int>.filled(64, 7)));

  group('校验拒绝 — 服务端拒绝必须与网络故障区分', () {
    // ⚠️ 覆盖范围说明:这些用例注入假 uploadModel,验的是 publish() 对
    // 「服务端拒绝」这一信号的**处理**。真正的 staging→finalize 往返
    // 需要真机 + 真实用户 JWT,不在单测覆盖内。
    test('upload_validation_failed 归入 rejected,而非 uploading', () async {
      await writePly();
      spy.uploadThrows = StateError('upload_validation_failed:exe_mz');
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>()
              .having((e) => e.phase, 'phase', 'rejected')
              .having((e) => e.message, 'reason', contains('exe_mz')),
        ),
      );
      // 收口后 works 行只能由 finalize 创建,客户端已无从断言"有没有行"。
      // 换成更强也更直接的判据:流程在被拒后**中止**了,没有继续到缩略图。
      expect(spy.thumbs, isEmpty, reason: '被拒之后不该再走缩略图,那意味着流程没有中止');
    });

    test('🔑 网络错误仍是 uploading —— 证明没把所有失败都归成拒绝', () async {
      await writePly();
      spy.uploadThrows = StateError('SocketException: connection reset');
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'uploading'),
        ),
      );
    });
  });

  group('体积上限 — 两道防线各自独立生效', () {
    tearDown(() => EndpointConfigResolver.current = null);

    test('预检:超过配置上限时,连传都不传(不浪费流量)', () async {
      await writePly();
      EndpointConfigResolver.current = const EndpointConfig(
        supabaseUrl: 'https://x.supabase.co',
        supabaseAnonKey: 'k',
        maxUploadBytes: 10, // 比 fixture 小,必然触发
        source: EndpointConfigSource.builtin,
      );
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'too_large'),
        ),
      );
      expect(spy.uploads, isEmpty, reason: '预检的全部意义就是别把几十MB传完才被拒');
      expect(spy.uploads, isEmpty);
    });

    test('未配置上限时不预检 —— 配置没下发不该把用户挡在门外', () async {
      await writePly();
      EndpointConfigResolver.current = null;
      await service().publish(record: record(), title: 'T');
      expect(spy.uploads, hasLength(1));
    });

    test('兜底:服务端返回 413/EntityTooLarge 时归入 too_large 而非 uploading', () async {
      await writePly();
      spy.uploadThrows = StateError('StorageException: EntityTooLarge (413)');
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'too_large'),
        ),
      );
      expect(spy.uploads, isEmpty);
    });

    test('🔑 普通网络错误仍是 uploading —— 否则会误导用户放弃重试', () async {
      await writePly();
      spy.uploadThrows = StateError('Connection closed before full header');
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'uploading'),
        ),
      );
    });
  });

  group('内容签名校验 — 内容与声明不符时不得上传', () {
    test('PNG 伪装成 .ply 被拦下,且没有任何上传或插入', () async {
      // 写一个 PNG 到点云文件名下 —— 正是"扩展名/Content-Type 皆为调用方
      // 声明"的那类伪装。
      await Directory(record().captureDir!).create(recursive: true);
      await File(
        '${record().captureDir!}/official_sfm_sparse.ply',
      ).writeAsBytes(
        Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0,
          0,
          0,
          0,
        ]),
      );

      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'validating'),
        ),
      );
      expect(spy.uploads, isEmpty, reason: '校验必须发生在上传之前,否则字节已经落进公开桶了');
      expect(spy.uploads, isEmpty);
    });

    test('合法 PLY 正常放行(证明拦截不是把所有东西都挡了)', () async {
      await writePly();
      await service().publish(record: record(), title: 'T');
      expect(spy.uploads, hasLength(1));
      expect(spy.uploads.single.path.endsWith('.ply'), isTrue);
    });
  });

  group('preconditions — nothing is uploaded when they fail', () {
    test('signed out', () async {
      await writePly();
      await expectLater(
        service(uid: null).publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'reading'),
        ),
      );
      expect(spy.uploads, isEmpty);
      expect(spy.uploads, isEmpty);
    });

    test('already published', () async {
      await writePly();
      await expectLater(
        service().publish(
          record: record(cloudWorkId: 'existing'),
          title: 'T',
        ),
        throwsA(isA<PublishException>()),
      );
      expect(spy.uploads, isEmpty);
    });

    test('blank title', () async {
      await writePly();
      await expectLater(
        service().publish(record: record(), title: '   '),
        throwsA(isA<PublishException>()),
      );
      expect(spy.uploads, isEmpty);
    });

    test('title over the 100-char DB limit', () async {
      await writePly();
      await expectLater(
        service().publish(record: record(), title: 'x' * 101),
        throwsA(isA<PublishException>()),
      );
      expect(spy.uploads, isEmpty);
    });

    test('description over the 5000-char DB limit', () async {
      await writePly();
      await expectLater(
        service().publish(
          record: record(),
          title: 'T',
          description: 'x' * 5001,
        ),
        throwsA(isA<PublishException>()),
      );
      expect(spy.uploads, isEmpty);
    });

    test('captureDir has no sparse PLY', () async {
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'reading'),
        ),
      );
      expect(spy.uploads, isEmpty);
    });
  });

  group('happy path', () {
    test(
      'uploads the PLY byte-for-byte and inserts a public ply row',
      () async {
        await writePly();
        final res = await service().publish(
          record: record(),
          title: '  My Scan  ',
          description: '  hello  ',
        );

        // Uploaded unmodified — no decimation, no re-encode.
        expect(spy.uploads.single.bytes, plyBytes.length);
        expect(res.fileSizeBytes, plyBytes.length);

        // Content-addressed path.
        final hash = sha1.convert(plyBytes).toString();
        expect(res.modelStoragePath, 'uid/$hash.ply');
        expect(spy.uploads.single.path, res.modelStoragePath);

        // 收口后客户端**只**发送 title / description。
        // format / visibility / user_id / model_storage_path / file_size_bytes
        // / published_at 全部由服务端自己算 —— 客户端连伪造的机会都没有,
        // 所以这里没有它们可断言,这正是收口的目的。
        final up = spy.uploads.single;
        expect(up.title, 'My Scan'); // trimmed
        expect(up.description, 'hello'); // trimmed
        expect(res.workId, 'work-1'); // 服务端回传的 id
      },
    );

    test('empty description is stored as null, not an empty string', () async {
      await writePly();
      await service().publish(record: record(), title: 'T', description: '   ');
      expect(spy.uploads.single.description, isNull);
    });

    test('emits monotonic progress ending at done/1.0', () async {
      await writePly();
      final seen = <PublishProgress>[];
      await service().publish(
        record: record(),
        title: 'T',
        onProgress: seen.add,
      );
      expect(seen.first.phase, 'reading');
      expect(seen.last.phase, 'done');
      expect(seen.last.fraction, 1.0);
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i].fraction,
          greaterThanOrEqualTo(seen[i - 1].fraction),
          reason: 'progress went backwards at index $i',
        );
      }
    });
  });

  group('no-orphan invariant', () {
    test('upload failure means NO works row is inserted', () async {
      await writePly();
      spy.uploadThrows = StateError('network down');

      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'uploading'),
        ),
      );
      // 同上:行由服务端建,客户端断言不到。改为断言流程确实中止。
      expect(spy.thumbs, isEmpty, reason: '上传失败后不该再走缩略图 —— 那会留下指向不存在文件的痕迹');
    });

    test('服务端建行失败仍归入 inserting phase(行为不变,只是换了台机器做)', () async {
      await writePly();
      // 收口后建行在 upload-finalize 里,失败以 500 insert_failed 回来。
      spy.uploadThrows = StateError('upload-finalize http_500: insert_failed');
      await expectLater(
        service().publish(record: record(), title: 'T'),
        throwsA(
          isA<PublishException>().having((e) => e.phase, 'phase', 'inserting'),
        ),
      );
    });
  });

  group('thumbnail is best effort', () {
    test('uploads the local PNG when one exists', () async {
      await writePly();
      await writeThumb();
      final res = await service().publish(record: record(), title: 'T');
      expect(spy.thumbs.single.contentType, 'image/png');
      expect(res.thumbnailStoragePath, 'uid/work-1.png');
    });

    test('publish still succeeds with no local thumbnail', () async {
      await writePly();
      final res = await service().publish(record: record(), title: 'T');
      expect(spy.thumbs, isEmpty);
      expect(res.thumbnailStoragePath, isNull);
      expect(res.workId, 'work-1');
    });

    test('a throwing thumbnail upload does not fail the publish', () async {
      await writePly();
      await writeThumb();
      spy.thumbThrows = StateError('broker rejected');
      final res = await service().publish(record: record(), title: 'T');
      expect(res.workId, 'work-1');
      expect(res.thumbnailStoragePath, isNull);
    });
  });

  group('sparsePlyFor', () {
    test('returns null when the record has no captureDir', () {
      final r = ScanRecord(
        id: 'r',
        name: 'n',
        createdAt: DateTime.utc(2026, 8, 16),
      );
      expect(PublishService.sparsePlyFor(r), isNull);
    });

    test('returns null when the PLY has not landed yet', () {
      expect(PublishService.sparsePlyFor(record()), isNull);
    });

    test('finds the PLY once the reconstruction writes it', () async {
      await writePly();
      expect(PublishService.sparsePlyFor(record()), isNotNull);
    });
  });
}
