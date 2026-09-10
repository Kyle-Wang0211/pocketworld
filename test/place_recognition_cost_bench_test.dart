// 地点识别的**成本曲线**:每 tick 要花多少,随已拍张数怎么涨。
//
// 用户 2026-09-10:"全比、接受随张数增长的开销,先达到效果,然后去做优化提速
// +降本"。这个文件就是那笔账 —— 优化之前先有数,免得变成"感觉慢"。
// 不设阈值、不当判据,只把数打出来。
//
// 生产口径:判决跟位姿 60 Hz,但灰度按 `OFFICIAL_AETHER_QUALITY_HZ=6` 算
// ⇒ **每秒 6 次**。上限 `kOfficialMaximumCaptureFrames = 300` 张。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';
import 'package:pocketworld_flutter/official_capture/orb_descriptor.dart';
import 'package:pocketworld_flutter/official_capture/visual_word_dictionary.dart';

const int _w = 128;
const int _h = 128;

List<Uint8List> describe(Uint8List gray) {
  final corners = goodFeaturesToTrack(
    gray: gray,
    width: _w,
    height: _h,
    maxCorners: kRtabmapMaxFeatures,
  );
  final blurred = orbBlurForDescriptors(gray, _w, _h);
  return <Uint8List>[
    for (final c in corners)
      computeOrbDescriptor(blurred, _w, _h, c.$1, c.$2, angleDeg: -1.0),
  ];
}

void main() {
  test('成本曲线:描述一帧 + 查询 N 张已拍', () {
    final g =
        jsonDecode(
              File('test/fixtures/orb_golden_opencv.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final first = (g['gftt'] as List)[0] as Map<String, dynamic>;
    final base = Uint8List.fromList((first['gray'] as List).cast<int>());
    expect(base.length, _w * _h);

    // 每张"已拍照片"用不同横移造出,保证词典真的长起来。
    Uint8List shifted(int dx) {
      final out = Uint8List(_w * _h);
      for (var y = 0; y < _h; y++) {
        for (var x = 0; x < _w; x++) {
          out[y * _w + x] = base[y * _w + ((x + dx) % _w)];
        }
      }
      return out;
    }

    final sw = Stopwatch()..start();
    final probe = describe(base);
    sw.stop();
    final describeUs = sw.elapsedMicroseconds;

    final report = StringBuffer(
      '\n  描述一帧(GFTT+ORB,${probe.length} 个描述子)= '
      '${(describeUs / 1000).toStringAsFixed(1)} ms\n'
      '  N\t词数\t查询\t每 tick 合计\t占一个核@6Hz\n',
    );
    final dict = VisualWordDictionary();
    var added = 0;
    for (final n in <int>[1, 8, 35, 100, 300]) {
      while (added < n) {
        dict.addNewWords(describe(shifted(added * 3 + 1)), added + 1);
        added++;
      }
      final q = describe(base);
      final t = Stopwatch()..start();
      final counts = dict.quantizeQuery(q);
      dict.computeLikelihood(counts);
      for (final s in dict.signatures) {
        dict.sharedWordsWith(counts, s.signatureId);
      }
      t.stop();
      final queryUs = t.elapsedMicroseconds;
      final perTickMs = (describeUs + queryUs) / 1000.0;
      report.writeln(
        '  $n\t${dict.wordCount}\t${(queryUs / 1000).toStringAsFixed(1)} ms'
        '\t${perTickMs.toStringAsFixed(1)} ms'
        '\t${(perTickMs * 6 / 10).toStringAsFixed(1)}%',
      );
    }
    // ignore: avoid_print
    print(report.toString());
    expect(dict.signatureCount, 300);
  });
}
