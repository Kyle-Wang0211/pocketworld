// CameraIntrinsics.fromWire 的合理性校验测试。
//
// 为什么这些校验重要:**半真半假的内参比明确的占位更危险** ——
// PLACEHOLDER 至少会让交付层拒绝报绝对尺寸,而一组"看起来像内参的垃圾"
// 会一路跑到底,产出一个错误但看起来正常的模型。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';

void main() {
  Map<String, Object?> wire({
    Object? fx = 1500.0, Object? fy = 1500.0,
    Object? cx = 960.0, Object? cy = 540.0,
    Object? width = 1920, Object? height = 1080,
  }) => <String, Object?>{
        'fx': fx, 'fy': fy, 'cx': cx, 'cy': cy,
        'width': width, 'height': height,
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

  test('缺任一字段 → null(半真半假比缺失更危险)', () {
    for (final String missing in <String>['fx','fy','cx','cy','width','height']) {
      final m = wire()..remove(missing);
      expect(CameraIntrinsics.fromWire(m), isNull, reason: '缺 $missing 时应返回 null');
    }
  });

  test('主点落在画幅外 → null', () {
    expect(CameraIntrinsics.fromWire(wire(cx: 5000.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(cy: -1.0)), isNull);
  });

  test('焦距非正 → null', () {
    expect(CameraIntrinsics.fromWire(wire(fx: 0.0)), isNull);
    expect(CameraIntrinsics.fromWire(wire(fy: -100.0)), isNull);
  });

  test('分辨率非正 → null', () {
    expect(CameraIntrinsics.fromWire(wire(width: 0)), isNull);
  });

  test('换分辨率必须等比缩放 —— 不缩放整条位姿链会系统性错', () {
    final k = CameraIntrinsics.fromWire(wire())!;      // 1920x1080, fx=1500, cx=960
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
}
