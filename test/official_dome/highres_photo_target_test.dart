// [ANY43-DEFAULT 2026-09-25] ARKit 路线:宿主回报 → 要请求的高清照片尺寸(PlatformARPoseProvider
// .highResRequestFromReport)。规则「平台默认模式下的最大 4:3」;null = 不传参,原生调用与改动前相同。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_dome/platform_pose_provider.dart';
import 'package:pocketworld_flutter/vio/capture/photo_size_rule.dart';

void main() {
  test('本测试机(hires43 1920x1440 格式,ARKit 默认 4032x3024)⇒ 选中 4032x3024 = 默认 ⇒ 不请求', () {
    expect(
      PlatformARPoseProvider.highResRequestFromReport(const {
        'supported': [
          [1920, 1440, kPhotoCandidateFlagLiteralDefault],
          [4032, 3024, 0],
        ],
        'legacyHighResStill': [4032, 3024],
        'default': [4032, 3024],
        'photoSettingsCapture': true,
      }),
      isNull,
    );
  });

  test('48MP iPhone:48MP / 24MP 是主动请求档,ARKit 默认 12MP ⇒ 不请求', () {
    expect(
      PlatformARPoseProvider.highResRequestFromReport(const {
        'supported': [
          [4032, 3024, kPhotoCandidateFlagLiteralDefault],
          [5712, 4284, kPhotoCandidateFlagOptIn],
          [8064, 6048, kPhotoCandidateFlagOptIn],
        ],
        'default': [4032, 3024],
        'photoSettingsCapture': true,
      }),
      isNull,
    );
  });

  test('ARKit 默认小于默认模式下的最大 4:3 ⇒ 请求后者(不越过主动请求档)', () {
    expect(
      PlatformARPoseProvider.highResRequestFromReport(const {
        'supported': [
          [1920, 1440, kPhotoCandidateFlagLiteralDefault],
          [4032, 3024, 0],
          [8064, 6048, kPhotoCandidateFlagOptIn],
        ],
        'default': [1920, 1440],
        'photoSettingsCapture': true,
      }),
      const PhotoDimensions(4032, 3024),
    );
  });

  test('iOS < 26(不能带照片设置取图)⇒ 不请求', () {
    expect(
      PlatformARPoseProvider.highResRequestFromReport(const {
        'supported': [
          [1920, 1440, kPhotoCandidateFlagLiteralDefault],
          [4032, 3024, 0],
        ],
        'photoSettingsCapture': false,
      }),
      isNull,
    );
    expect(PlatformARPoseProvider.highResRequestFromReport(null), isNull);
  });
}
