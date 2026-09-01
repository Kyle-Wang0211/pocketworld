import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/official_actual_photo_gate.dart';

/// 「交付绝对无损」在 12MP 实拍判据上的钉子。
///
/// 2026-09-01 实测(build-75,08-27 基线):一次会话 23 次快门触发 45 次 12MP
/// 原生取图,`rejectDuplicate` 25 次,只活下来 20 张 —— 重复判决被接到了删除
/// 路径上。上游 VINS 的 addFeatureCheckParallax() 返回这个布尔是用来选边缘化
/// 策略的,false 分支仍然保留新帧;删除是本次复刻自己加的。
///
/// 这个缺陷此前**没有任何测试钉住**,所以它在 08-30 修好之后又随回滚回来了。
void main() {
  // 判据基线只被「确认新颖」的照片推进 —— 这是保留非新颖照片的前提。
  // 基线若被非新颖照片推进,慢速平移会永远攒不够位移,自动拍会饿死。
  test('rejectDuplicate 不推进判据基线,accept 才推进', () {
    final gate = OfficialActualPhotoGate();
    final intrinsics = <double>[1200, 1200, 2016, 1512];
    Uint8List frame(int seed) {
      final g = Uint8List(128 * 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          g[y * 128 + x] = (((x + seed) ~/ 6) + (y ~/ 6)).isEven ? 24 : 232;
        }
      }
      return g;
    }

    final first = gate.evaluate(
      gray128: frame(0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(first.decision, OfficialActualPhotoDecision.accept);
    final baseline = gate.acceptedCount;

    // 同一帧再来一次必然是重复。
    final dup = gate.evaluate(
      gray128: frame(0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(dup.decision, OfficialActualPhotoDecision.rejectDuplicate);
    expect(gate.acceptedCount, baseline, reason: '重复判决不得推进基线,否则慢速平移永远攒不够位移');
  });

  test('重复判决不得流进 12MP 事务的删除路径', () {
    // 只看代码,不看注释 —— 注释里出现的字样不算数(2026-08-22 定则)。
    final source = File('lib/official_capture/capture_session.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n')
        .replaceAll(RegExp(r'\s+'), ' ');

    expect(
      source,
      contains(
        'final retainedAsNonNovel = actualGate.decision == '
        'OfficialActualPhotoDecision.rejectDuplicate;',
      ),
      reason: '重复判决必须被单独标出来,而不是和其他拒绝混在一起',
    );
    expect(
      source,
      contains('if (!actualGate.accepted && !retainedAsNonNovel) {'),
      reason:
          '删除路径必须把 retainedAsNonNovel 排除在外 —— '
          '去掉这个守卫就等于恢复毁片行为',
    );
  });
}
