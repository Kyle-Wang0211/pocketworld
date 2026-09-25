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
//   ② 拍照端选尺寸 [pickLargestFourByThree]:宿主用各自的官方 API 报出可用照片尺寸,
//      这里挑「通过判据的里面面积最大的一个」。宿主只查不判:
//        iOS      AVCaptureDevice.Format.supportedMaxPhotoDimensions(activeFormat;
//                 零 ARKit 走 PwCameraSlot,ARKit 路线走
//                 ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera)
//        Android  Camera2 CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
//                 .getOutputSizes(ImageFormat.JPEG) + getHighResolutionOutputSizes(JPEG)
//                 (android_ready/kotlin/.../PwCameraProbe.kt jpegOutputSizes)
//        鸿蒙     camera.CameraManager.getSupportedOutputCapability(camera, mode)
//                 .photoProfiles[].size(本仓尚无鸿蒙宿主)
//      超大尺寸(例如 50MP)照样选,**不在这里加上限**(用户规则)。
//
// 「4:3」= AndroidX CameraX 官方 AspectRatioUtil.hasMatchingAspectRatio(Apache-2.0,
// revision a12036836c464b39bde66b7e2a7c4238eef3b884):严格等比,或面积 >= VGA 时允许
// 厂商按 16 对齐造成的偏差(Pixel 4080x3072、50MP 四合一 8160x6144 系统都标成 4:3)。
// 方法地图同 C 头文件:三个函数 semantic_port(逐分支照搬,Rational 相等改交叉相乘),
// [photoSizeVerdict] / [pickLargestFourByThree] 是 product_adapter。
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

/// 拍照端规则:宿主报上来的可用尺寸里,挑通过 [photoSizeVerdict] 的面积最大者;
/// 面积相同取更宽的(确定性)。一个都不过 ⇒ null(宿主保持自己的默认,入口闸照样会拦)。
PhotoDimensions? pickLargestFourByThree(Iterable<PhotoDimensions> candidates) {
  PhotoDimensions? best;
  for (final PhotoDimensions c in candidates) {
    if (!photoSizeVerdict(c.width, c.height).accepted) continue;
    if (best == null ||
        c.area > best.area ||
        (c.area == best.area && c.width > best.width)) {
      best = c;
    }
  }
  return best;
}
