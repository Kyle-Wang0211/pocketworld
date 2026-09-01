// official_project_photo_album_test.dart
//
// 〔2026-08-30 迁移〕本文件原来测的是「相册自己持有照片列表」的旧模型:
// `commitVerified` 能新增成员、`remove` 能删除成员、`clear` 能清空成员。
//
// 实现已按交接 §10.3 重写成 **AcceptedPhotoRecordRegistry 的投影**:
//   - `commitVerified` 降级为**只读回执** —— 源码注释逐字写着
//     "This method **cannot add membership**. It returns true only when the
//      durable canonical ledger has already published an exactly matching record."
//   - `remove()` **恒返回 false** —— "The album is only a projection and
//      therefore cannot remove it."(移除成员需要 canonical store 的持久墓碑)
//   - `clear()` 只清投影侧的分析态,**不动成员资格**
//   - `count / latestPath / photos / paths` 全部从 registry 读
//
// 所以这里不是"把断言改到能过"，而是**把测试迁到新契约上**：语义翻转的三处
// (增/删/清)各自留了一条明确断言,防止旧行为哪天悄悄复活。
//
// ⚠️ registry 是 **static 全局**,所以每个用例必须自己清场(见 setUp)。
// 不清场会让用例之间互相污染 —— 那种失败最难查。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_record_store.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';

const String _scope = 'official_project_photo_album_test';

/// 造一条与生产同形状的 canonical record 并发布到 registry。
///
/// 相册只是投影,所以**测试必须从台账这一端注入** —— 这本身就是新契约的一部分。
AcceptedPhotoRecord _publish({
  required String jpegPath,
  required double captureTimestamp,
  int imageWidth = 4032,
  int imageHeight = 3024,
  String? transactionId,
}) {
  final record = AcceptedPhotoRecord(
    transactionId: transactionId ?? 'txn-${captureTimestamp.toInt()}',
    generation: 1,
    frameId: 'frame-${captureTimestamp.toInt()}',
    jpegPath: jpegPath,
    previewPath: '$jpegPath.preview',
    automaticSelection: true,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    triggerTimestamp: captureTimestamp,
    captureTimestamp: captureTimestamp,
    intrinsics: const <double>[1000, 1000, 500, 500],
    captureKind: 'auto',
    poseSyncQuality: 'exact',
    trackingStateName: 'normal',
    gray128Base64: null,
    sample: const <String, Object?>{},
    quality: const <String, Object?>{},
  );
  AcceptedPhotoRecordRegistry.publish(_scope, record);
  return record;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'official_project_photo_album_test_',
    );
    // registry 是 static 全局 —— 每个用例开场必须清空,否则跨用例污染。
    AcceptedPhotoRecordRegistry.replaceScope(
      _scope,
      const <AcceptedPhotoRecord>[],
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
    AcceptedPhotoRecordRegistry.replaceScope(
      _scope,
      const <AcceptedPhotoRecord>[],
    );
  });

  test('相册是台账的投影:成员资格只由已发布的 record 决定', () {
    final album = OfficialProjectPhotoAlbum();
    final first = File('${tempDir.path}/first.jpg')..writeAsBytesSync(<int>[1]);
    final second = File('${tempDir.path}/second.jpg')
      ..writeAsBytesSync(<int>[2]);

    expect(album.count, 0, reason: '台账为空时相册必须为空');

    _publish(jpegPath: first.path, captureTimestamp: 10);
    _publish(jpegPath: second.path, captureTimestamp: 11);

    expect(album.count, 2);
    expect(album.paths, <String>[first.path, second.path]);
  });

  test('commitVerified 是只读回执:数据逐字匹配才为 true,且不新增成员', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);

    // 🔑 语义翻转点一:台账里没有这条时,回执为 false 且**不会**把它加进来。
    expect(
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isFalse,
      reason: 'commitVerified 不能新增成员 —— 它只是回执',
    );
    expect(album.count, 0, reason: '回执为 false 之后相册仍须为空');

    _publish(jpegPath: photo.path, captureTimestamp: 10);

    expect(
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
      reason: '台账已发布且逐字匹配 ⇒ 回执 true',
    );
    // 纯读函数 ⇒ 幂等,重复调用结果不变(旧模型这里第二次是 false)。
    expect(
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
      reason: '纯读函数必须幂等',
    );
    expect(album.count, 1, reason: '调多少次回执都不改变成员数');
  });

  test('回执对不上的数据一律 false:缺失、时间戳不符、画幅不符', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    _publish(jpegPath: photo.path, captureTimestamp: 10);

    expect(
      album.commitVerified(
        jpegPath: '${tempDir.path}/missing.jpg',
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isFalse,
      reason: '台账里没有这条路径',
    );
    expect(
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: 99,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isFalse,
      reason: '时间戳与台账不符 —— 逐字匹配,不许放宽',
    );
    expect(
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: 10,
        imageWidth: 1920,
        imageHeight: 1440,
      ),
      isFalse,
      reason: '画幅不是台账里那条 12MP —— 预览帧不能冒充正式照片',
    );
    expect(album.count, 1, reason: '三次失败的回执都不许动成员');
  });

  test('applyCanonicalRecord 同样只认台账里已有的那条', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);

    final record = AcceptedPhotoRecord(
      transactionId: 'txn-not-published',
      generation: 1,
      frameId: 'frame-x',
      jpegPath: photo.path,
      previewPath: '${photo.path}.preview',
      automaticSelection: true,
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 10,
      captureTimestamp: 10,
      intrinsics: const <double>[1000, 1000, 500, 500],
      captureKind: 'auto',
      poseSyncQuality: 'exact',
      trackingStateName: 'normal',
      gray128Base64: null,
      sample: const <String, Object?>{},
      quality: const <String, Object?>{},
    );

    expect(album.applyCanonicalRecord(record), isFalse,
        reason: '未发布到台账的 record 不能被投影承认');
    expect(album.count, 0);

    AcceptedPhotoRecordRegistry.publish(_scope, record);
    expect(album.applyCanonicalRecord(record), isTrue);
    expect(album.count, 1);
  });

  test('🔑 相册不能删除成员 —— remove 恒为 false', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    _publish(jpegPath: photo.path, captureTimestamp: 10);

    expect(album.count, 1);
    // 语义翻转点二:旧模型这里返回 true 并把成员删掉。新契约下删除必须先由
    // canonical store 写持久墓碑,投影层无权移除 —— 否则 App 重启后照片复活。
    expect(album.remove(photo.path), isFalse,
        reason: '投影层删除成员 = 台账与相册无声分叉');
    expect(album.count, 1, reason: 'remove 之后成员必须原样还在');
    expect(album.paths, <String>[photo.path]);
  });

  test('🔑 clear 只清分析态,不动成员资格', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    _publish(jpegPath: photo.path, captureTimestamp: 10);
    album.updateAnalysisState(photo.path, PhotoCardSfmState.disconnected);
    expect(album.photos.single.analysisState, PhotoCardSfmState.disconnected);

    album.clear();

    // 语义翻转点三:旧模型 clear 会清空成员。
    expect(album.count, 1, reason: 'clear 不许影响成员资格');
    expect(album.latestPath, photo.path);
    expect(album.photos.single.analysisState, PhotoCardSfmState.pending,
        reason: 'clear 应该把分析态清回 pending');
  });

  test('latestPath 跟随台账顺序', () {
    final album = OfficialProjectPhotoAlbum();
    final first = File('${tempDir.path}/latest-first.jpg')
      ..writeAsBytesSync(<int>[1]);
    final second = File('${tempDir.path}/latest-second.jpg')
      ..writeAsBytesSync(<int>[2]);

    expect(album.latestPath, isNull);
    _publish(jpegPath: first.path, captureTimestamp: 10);
    expect(album.latestPath, first.path);
    _publish(jpegPath: second.path, captureTimestamp: 11);
    expect(album.latestPath, second.path);
  });

  test('analysis status never changes project membership or count', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    _publish(jpegPath: photo.path, captureTimestamp: 10);

    expect(album.photos.single.analysisState, PhotoCardSfmState.pending);
    expect(
      album.updateAnalysisState(photo.path, PhotoCardSfmState.disconnected),
      isTrue,
    );

    expect(album.count, 1);
    expect(album.paths, <String>[photo.path]);
    expect(album.photos.single.analysisState, PhotoCardSfmState.disconnected);
  });

  test('warns only after 20 analyzed photos and over 20 percent are red', () {
    final album = OfficialProjectPhotoAlbum();
    for (var i = 0; i < 20; i++) {
      final photo = File('${tempDir.path}/photo_$i.jpg')
        ..writeAsBytesSync(<int>[i]);
      _publish(jpegPath: photo.path, captureTimestamp: i.toDouble());
      album.updateAnalysisState(
        photo.path,
        i < 4 ? PhotoCardSfmState.disconnected : PhotoCardSfmState.registered,
      );
    }

    expect(album.analyzedCount, 20);
    expect(album.disconnectedCount, 4);
    expect(album.disconnectedRatio, 0.2);
    expect(album.shouldWarnDisconnected, isFalse);

    album.updateAnalysisState(
      '${tempDir.path}/photo_4.jpg',
      PhotoCardSfmState.disconnected,
    );
    expect(album.disconnectedCount, 5);
    expect(album.disconnectedRatio, 0.25);
    expect(album.shouldWarnDisconnected, isTrue);
  });

  test('pending photos do not enter the disconnected warning denominator', () {
    final album = OfficialProjectPhotoAlbum();
    for (var i = 0; i < 24; i++) {
      final photo = File('${tempDir.path}/photo_$i.jpg')
        ..writeAsBytesSync(<int>[i]);
      _publish(jpegPath: photo.path, captureTimestamp: i.toDouble());
      if (i < 19) {
        album.updateAnalysisState(
          photo.path,
          i < 5 ? PhotoCardSfmState.disconnected : PhotoCardSfmState.registered,
        );
      }
    }

    expect(album.count, 24);
    expect(album.analyzedCount, 19);
    expect(album.shouldWarnDisconnected, isFalse);
  });
}
