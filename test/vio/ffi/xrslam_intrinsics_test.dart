// CameraIntrinsics.fromWire 的合理性校验测试。
//
// 为什么这些校验重要:**半真半假的内参比明确的占位更危险** ——
// PLACEHOLDER 至少会让交付层拒绝报绝对尺寸,而一组"看起来像内参的垃圾"
// 会一路跑到底,产出一个错误但看起来正常的模型。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';

void main() {
  Map<String, Object?> wire({
    Object? fx = 1500.0,
    Object? fy = 1500.0,
    Object? cx = 960.0,
    Object? cy = 540.0,
    Object? m10 = 0.0,
    Object? width = 1920,
    Object? height = 1080,
    Object? trackingState = 'normal',
    Object? trackingReason = 'none',
  }) => <String, Object?>{
    'schema': 'pw.vio.ios.intrinsics-raw/1',
    'sessionId': 'session-a',
    'sessionEpoch': 1,
    'sessionGeneration': 1,
    // simd/ARCamera 原始列主序 3x3。由 Dart 选出 fx/fy/cx/cy。
    'intrinsicMatrixColumnMajor': <Object?>[
      fx,
      m10,
      0.0,
      0.0,
      fy,
      0.0,
      cx,
      cy,
      1.0,
    ],
    'imageResolutionWidth': width,
    'imageResolutionHeight': height,
    'source': 'ARCamera.intrinsics',
    'referenceTrackingState': trackingState,
    'referenceTrackingReason': trackingReason,
  };

  test('正常值 → deviceApi', () {
    final k = CameraIntrinsics.fromWire(wire())!;
    expect(k.fx, 1500.0);
    expect(k.resolutionWidth, 1920);
    expect(k.provenance, FieldProvenance.deviceApi);
  });

  test('null 输入 → null(不编数)', () {
    expect(CameraIntrinsics.fromWire(null), isNull);
  });

  test('原生只报 raw tracking，是否可用由 Dart 判定', () {
    expect(
      CameraIntrinsics.fromWire(
        wire(trackingState: 'limited', trackingReason: 'initializing'),
      ),
      isNull,
    );
    expect(
      CameraIntrinsics.fromWire(
        wire(trackingState: 'normal', trackingReason: 'excessiveMotion'),
      ),
      isNull,
    );
    expect(CameraIntrinsics.fromWire(wire()), isNotNull);
  });

  test('缺任一字段 → null(半真半假比缺失更危险)', () {
    for (final String missing in <String>[
      'intrinsicMatrixColumnMajor',
      'imageResolutionWidth',
      'imageResolutionHeight',
    ]) {
      final m = wire()..remove(missing);
      expect(
        CameraIntrinsics.fromWire(m),
        isNull,
        reason: '缺 $missing 时应返回 null',
      );
    }
  });

  test('主点落在画幅外 → null', () {
    expect(CameraIntrinsics.fromWire(wire(cx: 5000.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(cx: 1920.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(cy: -1.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(cy: 1080.0)), isNull);
  });

  test('焦距非正 → null', () {
    expect(CameraIntrinsics.fromWire(wire(fx: 0.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(fy: -100.0)), isNull);
  });

  test('非有限内参一律拒绝', () {
    for (final Object bad in <Object>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(CameraIntrinsics.fromWire(wire(fx: bad)), isNull);
      expect(CameraIntrinsics.fromWire(wire(cy: bad)), isNull);
    }
  });

  test('原始 3x3 中非选择元素也必须有限', () {
    expect(CameraIntrinsics.fromWire(wire(m10: double.nan)), isNull);
  });

  test('分辨率非正 → null', () {
    expect(CameraIntrinsics.fromWire(wire(width: 0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(height: -1)), isNull);
  });

  test('分数分辨率不得经 num.toInt 静默截断', () {
    expect(CameraIntrinsics.fromWire(wire(width: 1920.5)), isNull);
    expect(CameraIntrinsics.fromWire(wire(height: 1080.25)), isNull);
  });

  test('原始内参 wire 必须是精确版本化 schema', () {
    final Map<String, Object?> missingSchema = wire()..remove('schema');
    final Map<String, Object?> futureSchema = wire()
      ..['schema'] = 'pw.vio.ios.intrinsics-raw/2';
    final Map<String, Object?> unknownKey = wire()..['unexpected'] = true;
    final Map<String, Object?> shortMatrix = wire()
      ..['intrinsicMatrixColumnMajor'] = List<double>.filled(8, 0.0);

    expect(CameraIntrinsics.fromWire(missingSchema), isNull);
    expect(CameraIntrinsics.fromWire(futureSchema), isNull);
    expect(CameraIntrinsics.fromWire(unknownKey), isNull);
    expect(CameraIntrinsics.fromWire(shortMatrix), isNull);
  });

  test('换分辨率必须等比缩放 —— 不缩放整条位姿链会系统性错', () {
    final k = CameraIntrinsics.fromWire(wire())!; // 1920x1080, fx=1500, cx=960
    final half = k.scaledTo(960, 540);
    expect(half.fx, 750.0);
    expect(half.cx, 480.0);
    expect(half.resolutionWidth, 960);
    expect(half.provenance, FieldProvenance.deviceApi); // 来源不因缩放而降级
  });

  test('有真内参时 provenance 报告里不再是 PLACEHOLDER', () {
    final k = CameraIntrinsics.fromWire(wire())!;
    final b = XrslamConfigBuilder(intrinsics: k);
    expect(b.provenanceReport()['cam0.intrinsics'], 'device-api');
    // 但外参仍然是占位 —— iOS 无 API,这条不该被内参的成功掩盖
    expect(b.provenanceReport()['cam0.extrinsic'], 'PLACEHOLDER');
    expect(b.hasPlaceholders, isTrue);
  });

  test('官方复刻臂逐项使用 OpenXRLab iPhone 配置值', () {
    final CameraIntrinsics k = CameraIntrinsics.fromWire(wire())!;
    final XrslamConfigBuilder builder = XrslamConfigBuilder(intrinsics: k);
    final String device = builder.buildDeviceConfigYaml();
    final String slam = builder.buildSlamConfigYaml();

    expect(ImuNoise.sharedMems.covBg, 3.7608844899999997e-10);
    expect(ImuNoise.sharedMems.covBa, 9.0e-6);
    expect(device, contains('3.7608844899999997e-10'));
    expect(device, contains('0.000009'));
    expect(slam, contains('max_keypoint_detection: 300'));
    expect(slam, contains('tracker_frequent: 3'));
    expect(slam, isNot(contains('runtime:')));
    expect(slam, isNot(contains('max_pending_camera_frames')));
  });
}
