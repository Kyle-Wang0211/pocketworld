// 点「完成拍摄」那一刻,相机必须**立刻**被黑色等待页盖住 —— 两种快门模式一致。
//
// 🔴 用户 2026-09-14 实机指认:自动快门模式点完成后相机还亮着。
// 查实:两条快门路径走的是**同一个** `_finalizeRecording`,**一行 mode 分支
// 都没有**。差别是时延 —— 收尾第一件事 `_shutterQueue.freezeAndDrain()`
// 要等**所有在飞的快门票拍完**(manual_capture_queue.dart:89-96 等
// outstandingCount 归零,不是丢弃),之后还有 `waitForPendingPhotoSaves()`。
// 手动模式在飞通常 0–1 张 ⇒ 看着像"立刻";自动模式一秒一张、在飞好几张
// ⇒ 相机要多亮好几秒。此前那次「相机立刻关」的修正管的是**相对 finalize 的
// 顺序**,从来没有覆盖这段排空。
//
// 判据:盖页(`_sfmPhase = SfmPreviewPhase.generating`)必须排在
// `freezeAndDrain()` **之前**;而拆除顺序不许动 —— 在飞的 12MP 必须拍完
// 才停 ARSession,否则就是永久缺帧。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;
  late List<String> lines;
  // 🔴 判据必须**先定位到 _finalizeRecording 的函数体**再找 —— 这些字符串
  // (freezeAndDrain / stopSession / _finalizingRecording = false)在文件里
  // 前面还有同名出现,第一版直接 indexWhere 全文,三条判据一起锚错了。
  late List<String> body;
  late int bodyStart;

  setUpAll(() {
    final f = File('lib/ui/official_capture/ar_capture_page.dart');
    expect(f.existsSync(), isTrue);
    lines = f
        .readAsStringSync()
        .split('\n')
        .where(
          (l) =>
              !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
        )
        .toList();
    src = lines.join('\n');
    bodyStart = lines.indexWhere(
      (l) => l.contains('Future<void> _finalizeRecording({'),
    );
    expect(bodyStart, greaterThanOrEqualTo(0), reason: '函数改名了 —— 先修锚');
    final end = lines.indexWhere(
      (l) => l.contains('_finalizingRecording = false;'),
      bodyStart,
    );
    expect(end, greaterThan(bodyStart));
    body = lines.sublist(bodyStart, end + 1);
  });

  int at(String pat) => body.indexWhere((l) => l.contains(pat));

  test('锚点自身可读(阳性对照)', () {
    expect(src.contains('_finalizingRecording = true;'), isTrue);
    expect(src.contains('await _shutterQueue.freezeAndDrain();'), isTrue);
    expect(src.contains('stopSession'), isTrue);
  });

  test('🔴 盖页排在排空之前 —— 两种模式都是这一条路', () {
    final enter = at('_finalizingRecording = true;');
    final drain = at('await _shutterQueue.freezeAndDrain();');
    expect(enter, greaterThanOrEqualTo(0));
    expect(drain, greaterThan(enter));
    final beforeDrain = body.sublist(enter, drain);
    expect(
      beforeDrain.any(
        (l) => l.contains('_sfmPhase = SfmPreviewPhase.generating'),
      ),
      isTrue,
      reason: '等待页必须在等在飞快门之前就盖上,否则自动模式相机会多亮几秒',
    );
  });

  test('🔴 拆除顺序不许动:停相机仍排在排空与落盘之后(永久缺帧红线)', () {
    final drain = at('await _shutterQueue.freezeAndDrain();');
    final saves = at('waitForPendingPhotoSaves()');
    final stop = at("invokeMethod<void>('stopSession')");
    expect(drain, greaterThanOrEqualTo(0));
    expect(saves, greaterThanOrEqualTo(0));
    expect(stop, greaterThanOrEqualTo(0));
    expect(saves, greaterThan(drain), reason: '落盘屏障在排空之后');
    expect(stop, greaterThan(saves), reason: '停 ARSession 必须在所有在飞 12MP 落盘之后');
  });

  test('不重建的分支必须把等待页收回(否则 pop 被永远挂起)', () {
    // _exitToDrafts 看到 _sfmPhase != null 会把 pop 挂起等浮层的「完成」,
    // 而不重建的路上那张页根本没有「完成」可点。
    expect(src.contains('_sfmPhase = null'), isTrue);
    final clears = '_sfmPhase = null'.allMatches(src).length;
    expect(
      clears,
      greaterThanOrEqualTo(2),
      reason: '零张照片、以及有 recon 但不预览这两条路都要收回',
    );
  });

  test('收尾没有按快门模式分叉(统一性判据)', () {
    final text = body.join('\n');
    for (final forbidden in <String>[
      'autoCaptureMode',
      'isAutoMode',
      '_autoMode ==',
    ]) {
      expect(
        text.contains(forbidden),
        isFalse,
        reason: '收尾一旦按模式分叉,两种模式的行为就会再次走散:$forbidden',
      );
    }
  });
}
