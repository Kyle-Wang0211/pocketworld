// 09-08 真机冒烟闸判红之后补的两条回归断言。
//
// 现场:补拍撞上一个**本来就损坏**的 db(4096 字节、malformed,备份证明 09-07
// 就已如此),`aether_sfm_create` 每帧 errDb ⇒ 20 张全废。两个缺陷被照出来:
//   ① 采集期"逐帧失败只记日志"的口子:该闸只认 errInternal,而本例结果串是
//      exception ⇒ `sfm internal fault` 在设备日志里 0 次,20 帧一路放行。
//   ② 补拍复用同一 captureId ⇒ addOrUpdate 覆盖原记录,而记录无条件重取名字
//      + 重打时间戳 ⇒ 用户看到"原卡片没了、变成未命名(N)"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _stripComments(String src) => src
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

void main() {
  final code = _stripComments(
    File('lib/ui/official_capture/ar_capture_page.dart').readAsStringSync(),
  );

  test('原生抛出的帧一律记内部故障,不涂红让用户白拍', () {
    // errInternal 与 exception 同类:都是 fid==-1、帧没进重建、重拍无用。
    expect(
      code,
      contains(
        "if (event.result == 'errInternal' || event.result == 'exception')",
      ),
    );
    // 且必须真的接进那个计数器 —— 它才会在第 3 帧停下并告诉用户。
    final start = code.indexOf("event.result == 'errInternal'");
    expect(start, greaterThanOrEqualTo(0));
    final body = code.substring(start, start + 260);
    expect(body, contains('_noteSfmInternalFailure('));
    // 阈值仍是既有常数,不许在这里另发明一个。
    expect(code, contains('_kSfmInternalFailureWarnStreak = 3'));
  });

  test('补拍沿用原名,但时间必须刷新', () {
    // 名字 = 项目身份,补拍不该改。
    expect(code, contains('existing?.name ??'));
    // 时间 = 最后动过它的时刻,补了照片就该更新(作品页按它新→旧排序,
    // 刚补过的项目要浮到最前)。沿用旧时间会让它沉回原位,用户找不着。
    expect(code, contains('createdAt: createdAt,'));
    expect(code, isNot(contains('existing?.createdAt')));
    // 覆盖判据必须按 id 找已有记录,不是按名字。
    expect(code, contains('.where((r) => r.id == captureId)'));
  });

  test('补拍开拍前必须把已有照片装回相册', () {
    // 只在清空之后装 —— 顺序反了会被 clear() 抹掉。
    final clearAt = code.indexOf('_projectPhotos.clear();');
    final adoptAt = code.indexOf('_adoptExistingProjectPhotos(session)');
    expect(clearAt, greaterThanOrEqualTo(0));
    expect(adoptAt, greaterThan(clearAt));
    // 只对补拍生效,普通拍摄一字未动。
    final s = code.indexOf('Future<void> _adoptExistingProjectPhotos(');
    expect(s, greaterThanOrEqualTo(0));
    final body = code.substring(s, s + 900);
    expect(body, contains('widget.extendCaptureDir'));
    expect(body, contains('_projectPhotos.adoptExisting('));
    // 失败要留痕,不许静默装 0 张。
    expect(body, contains('DeviceLog.log('));
  });

  test('张数以盘为准,补拍不把 30 张记成 20 张', () {
    expect(code, contains('_photosOnDiskCount(photosDir'));
    // 列不动时退回调用方的值,不静默记 0。
    final s = code.indexOf('Future<int> _photosOnDiskCount(');
    expect(s, greaterThanOrEqualTo(0));
    final body = code.substring(s, s + 700);
    expect(body, contains('return fallback'));
    expect(body, isNot(contains('return 0')));
  });
}
