// 补拍时相册必须继承已有照片 —— 行为测试(真建临时文件,不是源码 grep)。
//
// [2026-09-08 用户指认] 补拍时相册显示 20/300,而项目原本已有 10 张 ⇒ 用户
// 以为还得再拍满 20 张才够。这个计数同时喂着 N/300 显示、「至少 20 张」完成闸、
// 300 张上限,所以修在源头:开拍前把上一次已落盘的照片装回相册。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('album_adopt'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File jpeg(String name, {int bytes = 16}) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
    return f;
  }

  test('装入已有照片后,count 是项目总数而不是本次会话数', () {
    final album = OfficialProjectPhotoAlbum();
    expect(album.count, 0);
    final adopted = album.adoptExisting([
      jpeg('cell_0_slot_0_tap-1.jpg').path,
      jpeg('cell_1_slot_0_tap-2.jpg').path,
      jpeg('cell_2_slot_0_tap-3.jpg').path,
    ]);
    expect(adopted, 3);
    expect(album.count, 3);
    // 差几张够 20 要按这个数算 —— 10 张的项目只需再拍 10 张。
    expect(20 - album.count, 17);
  });

  test('空文件 / 不存在 / 重复 一律不计,且不抛', () {
    final album = OfficialProjectPhotoAlbum();
    final good = jpeg('a_tap-1.jpg').path;
    final empty = jpeg('b_tap-2.jpg', bytes: 0).path;
    expect(
      album.adoptExisting([
        good,
        empty,
        '${tmp.path}/does_not_exist.jpg',
        '',
        good, // 同一批里的重复
      ]),
      1,
    );
    expect(album.count, 1);
    // 再装一次同一个,不该翻倍。
    expect(album.adoptExisting([good]), 0);
    expect(album.count, 1);
  });

  test('装入的照片是 pending —— 不稀释已分析比例,也不凭空点亮红字警告', () {
    final album = OfficialProjectPhotoAlbum();
    album.adoptExisting([for (var i = 0; i < 25; i++) jpeg('p${i}_tap-$i.jpg').path]);
    expect(album.count, 25);
    expect(album.photos.every((p) => p.analysisState == PhotoCardSfmState.pending), isTrue);
    // pending 不进 analyzedCount ⇒ 比例分母为 0 ⇒ 警告不该亮。
    expect(album.analyzedCount, 0);
    expect(album.disconnectedRatio, 0);
    expect(album.shouldWarnDisconnected, isFalse);
  });

  test('装入之后仍能正常提交新照片,且不与老照片重号', () {
    final album = OfficialProjectPhotoAlbum();
    album.adoptExisting([jpeg('old_tap-1.jpg').path]);
    final fresh = jpeg('new_tap-2.jpg').path;
    expect(
      album.commitVerified(
        jpegPath: fresh,
        captureTimestamp: 1.0,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
    );
    expect(album.count, 2);
    expect(album.paths, containsAll(<String>[fresh]));
  });
}
