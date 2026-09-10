// ORB 复刻 vs **OpenCV 本尊**逐位对拍。
//
// 判据不是"我觉得对",是"和 OpenCV 5.0.0 逐字节相同"。向量在
// test/fixtures/orb_golden_opencv.json(生成脚本见提交说明)。
// 规矩:复刻规范必须拿官方测试向量对拍;自造用例对没读到的规则失明。
//
// 🔴 查源时的一个关键发现,必须写在这里:**RTAB-Map 的 GFTT/ORB 描述子是
// 按 angle = −1 算的,不是定向的。** `GFTT_ORB::generateDescriptorsImpl`
// (rtabmap_Features2d.cpp:2474)把 GFTT 的关键点直接喂给 `cv::ORB::compute`,
// 而 `goodFeaturesToTrack` 不设方向、`ORB::compute` 对外部关键点**不重算角度**
// —— 实测金标准里 46 个关键点的 angle 取值集合就是 {−1.0}。
// 所以复刻要照它的**实际行为**,不是照 ORB 论文的理想行为。
// ICAngles 仍然复刻并单独对拍(B 部分),因为词典/匹配以后若改走定向 ORB
// 就要用到它,现在先把它钉住。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/orb_descriptor.dart';

void main() {
  late Map<String, dynamic> golden;

  setUpAll(() {
    final f = File('test/fixtures/orb_golden_opencv.json');
    expect(f.existsSync(), isTrue, reason: '金标准向量不在,复刻无从验证');
    golden = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  });

  test('采样表与 umax:结构先自证', () {
    expect(kOrbBitPattern31.length, 1024, reason: 'bit_pattern_31_[256*4]');
    expect(kOrbBitPattern31.reduce((a, b) => a < b ? a : b), -13);
    expect(kOrbBitPattern31.reduce((a, b) => a > b ? a : b), 12);
    final umax = buildOrbUmax();
    expect(umax.length, kOrbHalfPatchSize + 2);
    expect(umax[0], kOrbHalfPatchSize, reason: '中心行半宽 = halfPatchSize');
  });

  test('cvRound 是银行家舍入(Dart 的 .round() 不是)', () {
    expect(cvRound(0.5), 0);
    expect(cvRound(1.5), 2);
    expect(cvRound(2.5), 2);
    expect(cvRound(-0.5), 0);
    expect(cvRound(-1.5), -2);
    expect(0.5.round(), 1, reason: '对照:Dart 逢半远离零,所以不能直接用');
  });

  test('A0. 定点高斯模糊逐像素等于 cv2.GaussianBlur(整图)', () {
    // ⚠️ 这条验的是 [orbBlurBitExact8U],**不是** ORB 用的那条。
    // ORB 传的是金字塔子矩阵,按 smooth.dispatch.cpp:657 的分派条件会跳过
    // 定点路径走浮点 —— 所以 ORB 的模糊由 A 那条(描述子逐字节)间接钉住。
    // ORB 在算描述子前会对图做这一刀(orb.cpp:1234)。2026-09-10 我漏了它,
    // 描述子对拍 44/256 位不同,扫遍 360° 都对不上 —— 那不是角度问题。
    final cases = (golden['gftt'] as List).cast<Map<String, dynamic>>();
    final blurs = (golden['blur7x7sigma2'] as List).cast<List<dynamic>>();
    expect(blurs.length, cases.length);
    var worst = 0;
    var differing = 0;
    var total = 0;
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final w = c['width'] as int;
      final h = c['height'] as int;
      final gray = Uint8List.fromList((c['gray'] as List).cast<int>());
      final want = blurs[i].cast<int>();
      final got = orbBlurBitExact8U(gray, w, h);
      for (var k = 0; k < want.length; k++) {
        final d = (got[k] - want[k]).abs();
        if (d != 0) differing++;
        if (d > worst) worst = d;
        total++;
      }
    }
    expect(buildOrbBlurFixedKernel(), <int>[
      18,
      34,
      48,
      56,
      48,
      34,
      18,
    ], reason: '误差扩散定点核(和必须 = 256)');
    expect(buildOrbBlurFixedKernel().reduce((a, b) => a + b), 256);
    // ignore: avoid_print
    print('  A0: $total 像素,与 OpenCV 不同 $differing 个,最大偏差 $worst');
    expect(worst, 0, reason: '高斯模糊与 OpenCV 不是逐像素相同');
  });

  test('A. GFTT/ORB 描述子逐字节等于 OpenCV(RTAB-Map 的真实路径)', () {
    final cases = (golden['gftt'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    var checked = 0;
    for (final c in cases) {
      final w = c['width'] as int;
      final h = c['height'] as int;
      final gray = Uint8List.fromList((c['gray'] as List).cast<int>());
      for (final k in (c['keypoints'] as List).cast<Map<String, dynamic>>()) {
        final x = (k['x'] as num).toDouble();
        final y = (k['y'] as num).toDouble();
        final angle = (k['angle'] as num).toDouble();
        expect(angle, -1.0, reason: 'GFTT 关键点不带方向 —— 这条路就是这样');
        final blurred = orbBlurForDescriptors(gray, w, h);
        final got = computeOrbDescriptor(blurred, w, h, x, y, angleDeg: angle);
        expect(
          got.toList(),
          (k['desc'] as List).cast<int>(),
          reason: '($x,$y) 描述子与 OpenCV 不是逐字节相同',
        );
        checked++;
      }
    }
    expect(checked, greaterThanOrEqualTo(40));
    // ignore: avoid_print
    print('  A: $checked 个描述子逐字节通过');
  });

  test('B. ICAngles 与 OpenCV 相同(fastAtan2 多项式 + umax)', () {
    final cases = (golden['angles'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    var checked = 0;
    var maxDelta = 0.0;
    for (final c in cases) {
      final w = c['width'] as int;
      final h = c['height'] as int;
      final gray = Uint8List.fromList((c['gray'] as List).cast<int>());
      for (final k in (c['keypoints'] as List).cast<Map<String, dynamic>>()) {
        final x = (k['x'] as num).toDouble();
        final y = (k['y'] as num).toDouble();
        final want = (k['angle'] as num).toDouble();
        final got = orbKeypointAngle(gray, w, h, x, y);
        final d = (got - want).abs();
        if (d > maxDelta) maxDelta = d;
        expect(got, closeTo(want, 1e-3), reason: '($x,$y) 方向角对不上');
        checked++;
      }
    }
    expect(checked, greaterThanOrEqualTo(100));
    // ignore: avoid_print
    print(
      '  B: $checked 个方向角通过,最大偏差 '
      '${maxDelta.toStringAsExponential(2)} 度',
    );
  });
}
