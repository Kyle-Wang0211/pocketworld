// photo_size_rule.dart — [ENTRY-ANY-4X3 2026-09-25] 照片尺寸规则,三端共享的 Dart 层。
//
// 用户 2026-09-25 拍板:「只要是4:3,都行,不同手机就用4:3能做到的最大尺寸(自适应)」。
// 取代全链写死的 4032x3024。两件事都在这里,一处定义:
//
//   ① 入口判据 [photoSizeVerdict]:原始像素网格(传感器方向,不应用 EXIF 朝向)是 4:3,
//      且长边 >= 1920(用户铁律「最上游输入必须清晰」)。与核的外壳
//      vendor/official_sfm/src/pwofficial_photo_size_rule.h **同一份判据、同一组状态码**,
//      两边的单测跑同一张向量表(test/vio/capture/photo_size_rule_test.dart ↔
//      vendor/official_sfm/tests/pwofficial_photo_size_rule_test.c)。
//
//   ② 拍照端选尺寸 [pickLargestFourByThreeInDefaultMode]:[ANY43-DEFAULT 2026-09-25 用户改判]
//      「取平台默认模式下的最大 4:3」—— 不是设备支持的最大 4:3。48/50MP 手机因此拿到约 12MP 的
//      合并(binned)输出,三端对称,核不用改。宿主用各自官方 API 报候选,并逐项标出「需要主动请求
//      的高分辨率档」([PhotoSizeCandidate.requiresHighResolutionOptIn]),这里把它们排除后取面积最大
//      且过 [photoSizeVerdict] 的一个。宿主只报不判:
//        iOS      AVCaptureDevice.Format.supportedMaxPhotoDimensions(零 ARKit 走 PwCameraSlot 的
//                 activeFormat;ARKit 路线走 configurableCaptureDeviceForPrimaryCamera.activeFormat)。
//                 高于该格式 highResolutionStillImageDimensions(iOS 16 之前的「高分辨率静照」,
//                 48MP 全像素与 24MP 多帧融合都只能经 iOS 16 起的 maxPhotoDimensions 主动请求)
//                 的档标为需主动请求 ⇒ 48MP、24MP 永不请求。另标出 Apple 的字面默认
//                 (AVCapturePhotoSettings.maxPhotoDimensions 默认取列表最小项)供审计。
//        Android  Camera2 SENSOR_PIXEL_MODE_DEFAULT 的 SCALER_STREAM_CONFIGURATION_MAP
//                 .getOutputSizes(ImageFormat.JPEG) = 默认模式;同一映射的
//                 getHighResolutionOutputSizes(JPEG) 与 SCALER_STREAM_CONFIGURATION_MAP_MAXIMUM_RESOLUTION
//                 标为需主动请求 —— 与 CameraX 默认 ResolutionSelector.PREFER_CAPTURE_RATE_OVER_HIGHER_RESOLUTION
//                 完全一致(androidx a12036836c464b39 ResolutionSelector.java:92-122)。
//                 [photoSizeCandidatesFromCamera2] 解析 android_ready PwCameraProbe.characteristics。
//        鸿蒙     camera.CameraManager.getSupportedOutputCapability(camera, mode).photoProfiles[].size,
//                 全部按默认模式(官方文档未说明是合并还是全像素输出;本仓尚无鸿蒙宿主)。
//
// 「4:3」= AndroidX CameraX 官方 AspectRatioUtil.hasMatchingAspectRatio(Apache-2.0,
// revision a12036836c464b39bde66b7e2a7c4238eef3b884):严格等比,或面积 >= VGA 时允许
// 厂商按 16 对齐造成的偏差(Pixel 4080x3072、50MP 四合一 8160x6144 系统都标成 4:3)。
// 方法地图同 C 头文件:三个函数 semantic_port(逐分支照搬,Rational 相等改交叉相乘),
// [photoSizeVerdict] / [pickLargestFourByThreeInDefaultMode] 是 product_adapter。
//
// 纯 Dart,无平台分支。

/// 与 C 侧 PWOFFICIAL_PHOTO_SIZE_* 同值。
enum PhotoSizeVerdict {
  ok(0),
  invalid(1),
  notFourByThree(2),
  longSideBelowMin(3),
  notSensorOrientation(4);

  const PhotoSizeVerdict(this.code);
  final int code;

  bool get accepted => this == PhotoSizeVerdict.ok;
}

/// 用户铁律:最上游输入必须清晰。
const int kPhotoMinLongSide = 1920;

const int _align16 = 16;
const int _vgaW = 640;
const int _vgaH = 480;

class PhotoDimensions {
  const PhotoDimensions(this.width, this.height);
  final int width;
  final int height;
  int get area => width * height;

  @override
  bool operator ==(Object other) =>
      other is PhotoDimensions && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// 上游 ratioIntersectsMod16Segment。
bool _ratioIntersectsMod16Segment(int height, int mod16Width, int num, int den) {
  final double aspectRatioWidth = (height * num) / den;
  final int lo = mod16Width - _align16 > 0 ? mod16Width - _align16 : 0;
  return aspectRatioWidth > lo && aspectRatioWidth < mod16Width + _align16;
}

/// 上游 isPossibleMod16FromAspectRatio。
bool _isPossibleMod16(int width, int height, int num, int den) {
  if (width % 16 == 0 && height % 16 == 0) {
    final int h16 = height - _align16 > 0 ? height - _align16 : 0;
    final int w16 = width - _align16 > 0 ? width - _align16 : 0;
    return _ratioIntersectsMod16Segment(h16, width, num, den) ||
        _ratioIntersectsMod16Segment(w16, height, den, num);
  } else if (width % 16 == 0) {
    return _ratioIntersectsMod16Segment(height, width, num, den);
  } else if (height % 16 == 0) {
    return _ratioIntersectsMod16Segment(width, height, den, num);
  }
  return false;
}

/// 上游 hasMatchingAspectRatio(resolution, aspectRatio, mod16ResolutionLowerBound)。
/// [num]/[den] <= 0 对应上游 aspectRatio == null。
bool hasMatchingAspectRatio(
  int width,
  int height,
  int num,
  int den, {
  int lowerBoundWidth = _vgaW,
  int lowerBoundHeight = _vgaH,
}) {
  if (num <= 0 || den <= 0) return false;
  if (width * den == height * num) return true;
  if (width * height >= lowerBoundWidth * lowerBoundHeight) {
    return _isPossibleMod16(width, height, num, den);
  }
  return false;
}

/// 入口判据。宽高是**原始像素网格**(传感器方向)。
PhotoSizeVerdict photoSizeVerdict(int width, int height) {
  if (width <= 0 || height <= 0) return PhotoSizeVerdict.invalid;
  if (!hasMatchingAspectRatio(width, height, 4, 3)) {
    if (hasMatchingAspectRatio(height, width, 4, 3)) {
      return PhotoSizeVerdict.notSensorOrientation;
    }
    return PhotoSizeVerdict.notFourByThree;
  }
  final int longSide = width > height ? width : height;
  if (longSide < kPhotoMinLongSide) return PhotoSizeVerdict.longSideBelowMin;
  return PhotoSizeVerdict.ok;
}

/// [ANY43-DEFAULT 2026-09-25] 宿主上报的一项照片尺寸候选。
class PhotoSizeCandidate {
  const PhotoSizeCandidate(
    this.width,
    this.height, {
    this.requiresHighResolutionOptIn = false,
    this.platformLiteralDefault = false,
  });

  final int width;
  final int height;

  /// 需要主动请求的高分辨率档(iOS:高于格式的 highResolutionStillImageDimensions,
  /// 即 48MP 全像素、24MP 多帧融合;Android:getHighResolutionOutputSizes 与
  /// MAXIMUM_RESOLUTION 映射)。**永不选。**
  final bool requiresHighResolutionOptIn;

  /// 平台「什么都不设」时实际给的那一档(iOS:列表最小项;只作审计,不参与选择)。
  final bool platformLiteralDefault;

  PhotoDimensions get dimensions => PhotoDimensions(width, height);

  @override
  String toString() =>
      '${width}x$height${requiresHighResolutionOptIn ? '[optin]' : ''}'
      '${platformLiteralDefault ? '[default]' : ''}';
}

/// 宿主上报的位标志(iOS 两个宿主共用)。
const int kPhotoCandidateFlagOptIn = 1;
const int kPhotoCandidateFlagLiteralDefault = 2;

/// iOS 宿主上报的 [[w, h, flags], ...] → 候选。
List<PhotoSizeCandidate> photoSizeCandidatesFromTriples(Iterable<Object?> triples) {
  final out = <PhotoSizeCandidate>[];
  for (final Object? e in triples) {
    if (e is! List || e.length < 2) continue;
    final int w = (e[0] as num).toInt();
    final int h = (e[1] as num).toInt();
    final int flags = e.length >= 3 ? (e[2] as num).toInt() : 0;
    out.add(PhotoSizeCandidate(
      w,
      h,
      requiresHighResolutionOptIn: flags & kPhotoCandidateFlagOptIn != 0,
      platformLiteralDefault: flags & kPhotoCandidateFlagLiteralDefault != 0,
    ));
  }
  return out;
}

/// Android:android_ready PwCameraProbe.characteristics 的回报 → 候选。
///   jpegOutputSizes                   默认模式(CameraX 默认只用这张表)
///   jpegHighResolutionOutputSizes     需主动请求(CameraX PREFER_HIGHER_RESOLUTION_OVER_CAPTURE_RATE)
///   jpegMaximumResolutionOutputSizes  需主动请求(SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION;CameraX 从不用)
/// 同一尺寸同时出现在默认表与高分辨率表里,按默认表算。
List<PhotoSizeCandidate> photoSizeCandidatesFromCamera2(
    Map<Object?, Object?> characteristics) {
  List<PhotoDimensions> sizes(String key) => <PhotoDimensions>[
        for (final Object? e in (characteristics[key] as List?) ?? const [])
          if (e is List && e.length >= 2)
            PhotoDimensions((e[0] as num).toInt(), (e[1] as num).toInt()),
      ];
  final defaults = sizes('jpegOutputSizes').toSet();
  final out = <PhotoSizeCandidate>[
    for (final d in defaults) PhotoSizeCandidate(d.width, d.height),
  ];
  for (final d in {
    ...sizes('jpegHighResolutionOutputSizes'),
    ...sizes('jpegMaximumResolutionOutputSizes'),
  }) {
    if (defaults.contains(d)) continue;
    out.add(PhotoSizeCandidate(d.width, d.height,
        requiresHighResolutionOptIn: true));
  }
  return out;
}

/// 拍照端规则(用户 2026-09-25 改判):**平台默认模式下**的最大 4:3。
/// 排除需主动请求的高分辨率档,在剩下的里挑通过 [photoSizeVerdict] 的面积最大者;
/// 面积相同取更宽的(确定性)。一个都不过 ⇒ null(宿主保持自己的默认,入口闸照样会拦)。
PhotoDimensions? pickLargestFourByThreeInDefaultMode(
    Iterable<PhotoSizeCandidate> candidates) {
  PhotoDimensions? best;
  for (final PhotoSizeCandidate c in candidates) {
    if (c.requiresHighResolutionOptIn) continue;
    if (!photoSizeVerdict(c.width, c.height).accepted) continue;
    final d = c.dimensions;
    if (best == null ||
        d.area > best.area ||
        (d.area == best.area && d.width > best.width)) {
      best = d;
    }
  }
  return best;
}
