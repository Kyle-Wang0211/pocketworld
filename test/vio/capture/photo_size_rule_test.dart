// [ENTRY-ANY-4X3 2026-09-25] lib/vio/capture/photo_size_rule.dart 的单测。
// 向量表与 C 侧 vendor/official_sfm/tests/pwofficial_photo_size_rule_test.c 逐行相同:
//   A 组 = 上游 AndroidX CameraX AspectRatioUtilTest.kt(revision a12036836c464b39)
//          全部 hasMatchingAspectRatio 用例,期望值原样照抄;
//   B 组 = 产品判据(状态码与 C 侧同值)。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/capture/photo_size_rule.dart';

void main() {
  group('上游 CameraX AspectRatioUtilTest 向量', () {
    // (名字, w, h, num, den, 下限 w, 下限 h, 期望);num/den = 0 = 上游 null。
    const List<(String, int, int, int, int, int, int, bool)> up = [
      ('withNullAspectRatio', 16, 9, 0, 0, 640, 480, false),
      ('withSameAspectRatio', 16, 9, 16, 9, 640, 480, true),
      ('withMod16AspectRatio_720p', 1280, 720, 16, 9, 640, 480, true),
      ('withMod16AspectRatio_1080p', 1920, 1088, 16, 9, 640, 480, true),
      ('withMod16AspectRatio_1440p', 2560, 1440, 16, 9, 640, 480, true),
      ('withMod16AspectRatio_2160p', 3840, 2160, 16, 9, 640, 480, true),
      ('withMod16AspectRatio_1x1', 1088, 1088, 1, 1, 640, 480, true),
      ('withMod16AspectRatio_4x3', 1024, 768, 4, 3, 640, 480, true),
      ('withNonMod16AspectRatio', 1281, 721, 16, 9, 640, 480, false),
      ('smallerThanDefaultMod16LowerBound', 640, 358, 16, 9, 640, 480, false),
      ('setCustomMod16LowerBound', 640, 358, 16, 9, 320, 240, true),
    ];
    for (final c in up) {
      test(c.$1, () {
        expect(
          hasMatchingAspectRatio(c.$2, c.$3, c.$4, c.$5,
              lowerBoundWidth: c.$6, lowerBoundHeight: c.$7),
          c.$8,
        );
      });
    }
  });

  group('产品判据(与 C 侧同一张表)', () {
    const List<(String, int, int, int)> prod = [
      ('iPhone 12MP 4032x3024', 4032, 3024, 0),
      ('iPhone 48MP 8064x6048', 8064, 6048, 0),
      ('video 1920x1440', 1920, 1440, 0),
      ('8MP 3264x2448', 3264, 2448, 0),
      ('50MP 8160x6120', 8160, 6120, 0),
      ('50MP quad-bayer 8160x6144 (mod16)', 8160, 6144, 0),
      ('50MP 8192x6144', 8192, 6144, 0),
      ('12MP 4000x3000', 4000, 3000, 0),
      ('Pixel 12.5MP 4080x3072 (mod16)', 4080, 3072, 0),
      ('4:3 but 1904x1428', 1904, 1428, 3),
      ('4:3 but 1600x1200', 1600, 1200, 3),
      ('4:3 but 1440x1080', 1440, 1080, 3),
      ('16:9 1920x1080', 1920, 1080, 2),
      ('16:9 3840x2160', 3840, 2160, 2),
      ('16:9 still 4032x2268', 4032, 2268, 2),
      ('1:1 3024x3024', 3024, 3024, 2),
      ('16MP 4624x3472 (not 4:3 per CameraX)', 4624, 3472, 2),
      ('portrait 3024x4032', 3024, 4032, 4),
      ('portrait 1440x1920', 1440, 1920, 4),
      ('zero', 0, 0, 1),
      ('negative', -4, 3, 1),
    ];
    for (final c in prod) {
      test(c.$1, () => expect(photoSizeVerdict(c.$2, c.$3).code, c.$4));
    }
  });

  // [ANY43-DEFAULT 2026-09-25] 用户改判:「取平台默认模式下的最大 4:3」。
  group('拍照端:默认模式下的最大 4:3', () {
    // iOS 宿主三元组 (w, h, flags):bit0 = 需主动请求的高分辨率档,bit1 = Apple 字面默认(列表最小项)。
    test('模拟 48MP iPhone(4032x3024 格式):默认 12MP,48MP 与 24MP 融合是主动请求档 ⇒ 12MP', () {
      final c = photoSizeCandidatesFromTriples(const [
        [4032, 3024, kPhotoCandidateFlagLiteralDefault],
        [5712, 4284, kPhotoCandidateFlagOptIn], // 24MP 多帧融合(只经 deferred delivery)
        [8064, 6048, kPhotoCandidateFlagOptIn], // 48MP 全像素
      ]);
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(4032, 3024));
    });

    test('本测试机零 ARKit(1920x1440 格式):12MP 不是主动请求档 ⇒ 4032x3024', () {
      // 1920x1440 是 Apple 字面默认(列表最小项);4032x3024 = 该格式 highResolutionStillImageDimensions,
      // 不高于它 ⇒ 不标 bit0。
      final c = photoSizeCandidatesFromTriples(const [
        [1920, 1440, kPhotoCandidateFlagLiteralDefault],
        [4032, 3024, 0],
      ]);
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(4032, 3024));
    });

    test('iOS 宿主读不到 legacy 尺寸时退回 Apple 字面默认(除最小项外全标主动请求)', () {
      final c = photoSizeCandidatesFromTriples(const [
        [1920, 1440, kPhotoCandidateFlagLiteralDefault],
        [4032, 3024, kPhotoCandidateFlagOptIn],
      ]);
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(1920, 1440));
    });

    test('Pixel(Camera2 默认映射 4080x3072)⇒ 4080x3072', () {
      final c = photoSizeCandidatesFromCamera2(const {
        'jpegOutputSizes': [
          [4080, 3072],
          [4080, 2296],
          [4000, 3000],
          [3840, 2160],
          [1920, 1440],
          [1920, 1080],
        ],
        'jpegHighResolutionOutputSizes': [],
      });
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(4080, 3072));
    });

    test('50MP 四拜耳(默认约 12.5MP,全像素只在高分辨率 / MAXIMUM_RESOLUTION 表)⇒ 4080x3072', () {
      final c = photoSizeCandidatesFromCamera2(const {
        'jpegOutputSizes': [
          [4080, 3072],
          [4080, 2296],
          [3264, 2448],
          [1920, 1440],
        ],
        'jpegHighResolutionOutputSizes': [
          [8160, 6144],
        ],
        'jpegMaximumResolutionOutputSizes': [
          [8160, 6144],
          [8160, 4592],
        ],
      });
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(4080, 3072));
      expect(
        c.where((x) => x.requiresHighResolutionOptIn).map((x) => x.dimensions).toSet(),
        {const PhotoDimensions(8160, 6144), const PhotoDimensions(8160, 4592)},
      );
    });

    test('默认映射里更大的 16:9 不选,取 4:3', () {
      final c = photoSizeCandidatesFromCamera2(const {
        'jpegOutputSizes': [
          [4080, 2296],
          [4000, 3000],
        ],
      });
      expect(pickLargestFourByThreeInDefaultMode(c), const PhotoDimensions(4000, 3000));
    });

    test('没有合格的默认模式尺寸 ⇒ null(不退到主动请求档)', () {
      final c = photoSizeCandidatesFromTriples(const [
        [1920, 1080, kPhotoCandidateFlagLiteralDefault],
        [8064, 6048, kPhotoCandidateFlagOptIn],
      ]);
      expect(pickLargestFourByThreeInDefaultMode(c), isNull);
      expect(pickLargestFourByThreeInDefaultMode(const []), isNull);
    });
  });
}
