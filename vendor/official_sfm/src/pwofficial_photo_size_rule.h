#ifndef POCKETWORLD_PWOFFICIAL_PHOTO_SIZE_RULE_H
#define POCKETWORLD_PWOFFICIAL_PHOTO_SIZE_RULE_H

/*
 * [ENTRY-ANY-4X3 2026-09-25] 官方重建入口的照片尺寸判据 —— 纯算术,三端同一份。
 *
 * 用户 2026-09-25 拍板:「只要是4:3,都行,不同手机就用4:3能做到的最大尺寸(自适应)」,
 * 取代此前写死的 4032x3024。另一条铁律不变:最上游输入必须清晰 ⇒ 长边 ≥ 1920。
 *
 * 判据在**原始像素网格**上做(= 传感器方向,不应用 EXIF 朝向):解码器
 * (pwofficial_jpeg_decode.mm 的 CGImageSourceCreateImageAtIndex)交给核的就是这张
 * 网格,同帧内参 fx/fy/cx/cy 也在这张网格上。像素被转成竖向(3:4)存放的图,
 * 内参与网格对不上,稠密模型分辨率(768x576,4:3 横向)也对不上,所以单独给一个码拒收。
 *
 * 「4:3」的定义 = AndroidX CameraX 官方 AspectRatioUtil.hasMatchingAspectRatio:
 *   上游:https://github.com/androidx/androidx
 *         camera/camera-core/src/main/java/androidx/camera/core/impl/utils/AspectRatioUtil.java
 *         revision a12036836c464b39bde66b7e2a7c4238eef3b884(文件 sha256 f5ad9b37…a768d)
 *   许可:Apache-2.0,Copyright 2022 The Android Open Source Project。
 *   为什么用它而不是 w*3==h*4:Android 厂商常把尺寸按 16 对齐(官方注释原文:
 *   "OEMs may make the supported sizes to be mod16 alignment"),例如 Pixel 的
 *   4080x3072、常见 50MP 四合一传感器的 8160x6144,系统自己都标成 4:3,严格等式会拒掉。
 *
 * 方法地图(pocketworld CLAUDE.md「上游算法复刻铁律」):
 *   exact_upstream  —— 无(上游是 Java)
 *   semantic_port   —— pwofficial_has_matching_aspect_ratio / _is_possible_mod16 /
 *                      _ratio_intersects_mod16_segment:逐分支照搬;Rational 相等改写成
 *                      交叉相乘(android.util.Rational 构造即约分,正整数下二者等价);
 *                      int 乘法换 int64,防超大尺寸溢出(上游量级内结果相同)。
 *   product_adapter —— pwofficial_photo_size_status_rule:固定 4:3 + 上游默认下限 VGA
 *                      (SizeUtil.RESOLUTION_VGA = 640x480)+ 长边 ≥ 1920 + 竖向单列一个码。
 *   not_implemented —— 上游的其它比较器 / 排序工具(与判据无关)。
 * 上游单测 AspectRatioUtilTest.kt(同一 revision,sha256 8d5c8112…f187)的全部
 * hasMatchingAspectRatio 向量,在 tests/pwofficial_photo_size_rule_test.c 与
 * Dart 侧 test/official_photo_size_rule_test.dart 里原样跑。
 *
 * 只含 <stdint.h>,无任何平台宏/厂商 API:iOS(ImageIO 载体)、安卓(JNI)、
 * 鸿蒙(NAPI)编的都是这一份。
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 状态码 —— 与 official_sfm_io_c.h 的 PWOFFICIAL_PHOTO_SIZE_* 同值(那边是对外声明)。 */
enum {
  PWOFFICIAL_PHOTO_SIZE_RULE_OK = 0,
  PWOFFICIAL_PHOTO_SIZE_RULE_INVALID = 1,
  PWOFFICIAL_PHOTO_SIZE_RULE_NOT_4_3 = 2,
  PWOFFICIAL_PHOTO_SIZE_RULE_LONG_SIDE_BELOW_MIN = 3,
  PWOFFICIAL_PHOTO_SIZE_RULE_NOT_SENSOR_ORIENTATION = 4,
};

/* 用户铁律:最上游输入必须清晰。 */
#define PWOFFICIAL_PHOTO_SIZE_RULE_MIN_LONG_SIDE 1920

/* 上游 ALIGN16 与 SizeUtil.RESOLUTION_VGA。 */
#define PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16 16
#define PWOFFICIAL_PHOTO_SIZE_RULE_VGA_W 640
#define PWOFFICIAL_PHOTO_SIZE_RULE_VGA_H 480

/* 上游 ratioIntersectsMod16Segment(height, mod16Width, aspectRatio)。 */
static inline int pwofficial_ratio_intersects_mod16_segment(
    int64_t height, int64_t mod16_width, int64_t num, int64_t den) {
  const double aspect_ratio_width = (double)(height * num) / (double)den;
  const int64_t lo = mod16_width - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16 > 0
                         ? mod16_width - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16
                         : 0;
  return aspect_ratio_width > (double)lo &&
         aspect_ratio_width <
             (double)(mod16_width + PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16);
}

/* 上游 isPossibleMod16FromAspectRatio(resolution, aspectRatio)。 */
static inline int pwofficial_is_possible_mod16(
    int64_t width, int64_t height, int64_t num, int64_t den) {
  if (width % 16 == 0 && height % 16 == 0) {
    const int64_t h16 = height - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16 > 0
                            ? height - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16
                            : 0;
    const int64_t w16 = width - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16 > 0
                            ? width - PWOFFICIAL_PHOTO_SIZE_RULE_ALIGN16
                            : 0;
    return pwofficial_ratio_intersects_mod16_segment(h16, width, num, den) ||
           pwofficial_ratio_intersects_mod16_segment(w16, height, den, num);
  } else if (width % 16 == 0) {
    return pwofficial_ratio_intersects_mod16_segment(height, width, num, den);
  } else if (height % 16 == 0) {
    return pwofficial_ratio_intersects_mod16_segment(width, height, den, num);
  }
  return 0;
}

/* 上游 hasMatchingAspectRatio(resolution, aspectRatio, mod16ResolutionLowerBound)。
 * num/den <= 0 对应上游 aspectRatio == null ⇒ false。 */
static inline int pwofficial_has_matching_aspect_ratio(
    int64_t width, int64_t height, int64_t num, int64_t den,
    int64_t lower_bound_w, int64_t lower_bound_h) {
  if (num <= 0 || den <= 0) return 0;
  if (width * den == height * num) return 1;
  if (width * height >= lower_bound_w * lower_bound_h) {
    return pwofficial_is_possible_mod16(width, height, num, den);
  }
  return 0;
}

/* 产品判据。 */
static inline int32_t pwofficial_photo_size_status_rule(int64_t width,
                                                         int64_t height) {
  if (width <= 0 || height <= 0) return PWOFFICIAL_PHOTO_SIZE_RULE_INVALID;
  if (!pwofficial_has_matching_aspect_ratio(
          width, height, 4, 3, PWOFFICIAL_PHOTO_SIZE_RULE_VGA_W,
          PWOFFICIAL_PHOTO_SIZE_RULE_VGA_H)) {
    if (pwofficial_has_matching_aspect_ratio(
            height, width, 4, 3, PWOFFICIAL_PHOTO_SIZE_RULE_VGA_W,
            PWOFFICIAL_PHOTO_SIZE_RULE_VGA_H)) {
      return PWOFFICIAL_PHOTO_SIZE_RULE_NOT_SENSOR_ORIENTATION;
    }
    return PWOFFICIAL_PHOTO_SIZE_RULE_NOT_4_3;
  }
  const int64_t long_side = width > height ? width : height;
  if (long_side < PWOFFICIAL_PHOTO_SIZE_RULE_MIN_LONG_SIDE) {
    return PWOFFICIAL_PHOTO_SIZE_RULE_LONG_SIDE_BELOW_MIN;
  }
  return PWOFFICIAL_PHOTO_SIZE_RULE_OK;
}

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  /* POCKETWORLD_PWOFFICIAL_PHOTO_SIZE_RULE_H */
