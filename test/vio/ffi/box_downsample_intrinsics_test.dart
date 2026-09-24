// [pw 2026-09-23] ARKit 影子通路的 yaml 常量 K 与逐帧 K 用同一个换算。
//
// 逐帧 K:传输层 PWXrslamTransportScaleIntrinsicsForBoxNxN(C++ 单测对这份
// fixture 逐行差 0)。常量 K:CameraIntrinsics.boxDownsampledBy(本文件)。
// 两者都钉在离线转换器 arloopbench tools/pwvi_to_euroc.py:224-226 的真实输出上
// (fixture 由 vendor/xrslam/transport/tests/make_rescale_fixture.py 生成,
// 录制 run-6e2d4b99 前 120 帧),所以 A/B 两臂只差「逐帧 vs 常量」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';

void main() {
  const String fixture =
      'vendor/xrslam/transport/tests/fixtures/pwvi_to_euroc_rescale_6e2d4b99_d3.csv';

  test('boxDownsampledBy == pwvi_to_euroc.py --downscale 3 on every fixture row', () {
    int rows = 0;
    double maxAbs = 0;
    for (final String line in File(fixture).readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final List<String> c = line.split(',');
      expect(c, hasLength(10));
      final int factor = int.parse(c[5]);
      final CameraIntrinsics raw = CameraIntrinsics(
        fx: double.parse(c[1]),
        fy: double.parse(c[2]),
        cx: double.parse(c[3]),
        cy: double.parse(c[4]),
        resolutionWidth: 1920,
        resolutionHeight: 1440,
        provenance: FieldProvenance.deviceApi,
      );
      final CameraIntrinsics got = raw.boxDownsampledBy(factor);
      final List<double> want = <double>[
        for (int i = 6; i < 10; i++) double.parse(c[i]),
      ];
      final List<double> have = <double>[got.fx, got.fy, got.cx, got.cy];
      for (int i = 0; i < 4; i++) {
        final double d = (have[i] - want[i]).abs();
        if (d > maxAbs) maxAbs = d;
        expect(d, lessThanOrEqualTo(1e-9), reason: 'row $rows col $i');
      }
      expect(got.resolutionWidth, 640);
      expect(got.resolutionHeight, 480);
      rows++;
    }
    expect(rows, 120);
    // ignore: avoid_print
    print('boxDownsampledBy vs converter: rows=$rows max_abs_diff=$maxAbs');
    expect(maxAbs, 0);
  });

  test('the legacy scaledTo differs by exactly the pixel-center term (1/3 px at n=3)', () {
    const CameraIntrinsics k = CameraIntrinsics(
      fx: 1347.7943115234375,
      fy: 1347.7943115234375,
      cx: 957.4692993164062,
      cy: 718.9641723632812,
      resolutionWidth: 1920,
      resolutionHeight: 1440,
      provenance: FieldProvenance.deviceApi,
    );
    final CameraIntrinsics box = k.boxDownsampledBy(3);
    final CameraIntrinsics lin = k.scaledTo(640, 480);
    expect(box.fx, lin.fx);
    expect(box.fy, lin.fy);
    expect(lin.cx - box.cx, closeTo(1 / 3, 1e-12));
    expect(lin.cy - box.cy, closeTo(1 / 3, 1e-12));
  });

  test('non-dividing factor is rejected, not silently truncated', () {
    const CameraIntrinsics k = CameraIntrinsics(
      fx: 1000,
      fy: 1000,
      cx: 500,
      cy: 400,
      resolutionWidth: 1000,
      resolutionHeight: 800,
      provenance: FieldProvenance.deviceApi,
    );
    expect(() => k.boxDownsampledBy(3), throwsArgumentError);
    expect(() => k.boxDownsampledBy(0), throwsArgumentError);
  });

  test('the ARKit shadow session yaml K goes through boxDownsampledBy', () {
    final String recorder =
        File('lib/vio/diagnostics/vio_diagnostics_recorder.dart').readAsStringSync();
    expect(recorder, contains('final CameraIntrinsics kVio = k.boxDownsampledBy(n);'));
    expect(recorder, isNot(contains('k.scaledTo(')));
  });
}
