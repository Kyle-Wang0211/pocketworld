/*
 * [ENTRY-ANY-4X3 2026-09-25] src/pwofficial_photo_size_rule.h 的单测。
 * 跑法:scripts/test_photo_size_rule.sh(宿主 clang,纯 C,无平台依赖)。
 *
 * A 组 = 上游 AndroidX CameraX AspectRatioUtilTest.kt(revision a12036836c464b39,
 *        sha256 8d5c8112…f187)里全部 hasMatchingAspectRatio 用例,期望值原样照抄。
 * B 组 = 产品判据(4:3 + VGA 下限 + 长边 >= 1920 + 竖向单独一个码)。
 *        Dart 侧 test/official_photo_size_rule_test.dart 用**同一张表**。
 */
#include "../src/pwofficial_photo_size_rule.h"

#include <stdio.h>

typedef struct {
  const char* name;
  int64_t w, h, num, den, lbw, lbh;
  int expect;
} UpstreamCase;

typedef struct {
  const char* name;
  int64_t w, h;
  int32_t expect;
} ProductCase;

int main(void) {
  /* num/den = 0 表示上游的 null aspectRatio。lbw/lbh 缺省 = VGA。 */
  static const UpstreamCase kUp[] = {
      {"withNullAspectRatio", 16, 9, 0, 0, 640, 480, 0},
      {"withSameAspectRatio", 16, 9, 16, 9, 640, 480, 1},
      {"withMod16AspectRatio_720p", 1280, 720, 16, 9, 640, 480, 1},
      {"withMod16AspectRatio_1080p", 1920, 1088, 16, 9, 640, 480, 1},
      {"withMod16AspectRatio_1440p", 2560, 1440, 16, 9, 640, 480, 1},
      {"withMod16AspectRatio_2160p", 3840, 2160, 16, 9, 640, 480, 1},
      {"withMod16AspectRatio_1x1", 1088, 1088, 1, 1, 640, 480, 1},
      {"withMod16AspectRatio_4x3", 1024, 768, 4, 3, 640, 480, 1},
      {"withNonMod16AspectRatio", 1281, 721, 16, 9, 640, 480, 0},
      {"smallerThanDefaultMod16LowerBound", 640, 358, 16, 9, 640, 480, 0},
      {"setCustomMod16LowerBound", 640, 358, 16, 9, 320, 240, 1},
  };
  static const ProductCase kProd[] = {
      {"iPhone 12MP 4032x3024", 4032, 3024, 0},
      {"iPhone 48MP 8064x6048", 8064, 6048, 0},
      {"video 1920x1440", 1920, 1440, 0},
      {"8MP 3264x2448", 3264, 2448, 0},
      {"50MP 8160x6120", 8160, 6120, 0},
      {"50MP quad-bayer 8160x6144 (mod16)", 8160, 6144, 0},
      {"50MP 8192x6144", 8192, 6144, 0},
      {"12MP 4000x3000", 4000, 3000, 0},
      {"Pixel 12.5MP 4080x3072 (mod16)", 4080, 3072, 0},
      {"4:3 but 1904x1428", 1904, 1428, 3},
      {"4:3 but 1600x1200", 1600, 1200, 3},
      {"4:3 but 1440x1080", 1440, 1080, 3},
      {"16:9 1920x1080", 1920, 1080, 2},
      {"16:9 3840x2160", 3840, 2160, 2},
      {"16:9 still 4032x2268", 4032, 2268, 2},
      {"1:1 3024x3024", 3024, 3024, 2},
      {"16MP 4624x3472 (not 4:3 per CameraX)", 4624, 3472, 2},
      {"portrait 3024x4032", 3024, 4032, 4},
      {"portrait 1440x1920", 1440, 1920, 4},
      {"zero", 0, 0, 1},
      {"negative", -4, 3, 1},
  };
  int fail = 0;
  for (size_t i = 0; i < sizeof(kUp) / sizeof(kUp[0]); ++i) {
    const UpstreamCase* c = &kUp[i];
    const int got = pwofficial_has_matching_aspect_ratio(c->w, c->h, c->num,
                                                         c->den, c->lbw, c->lbh);
    if (got != c->expect) {
      fprintf(stderr, "FAIL upstream %s: got %d want %d\n", c->name, got,
              c->expect);
      ++fail;
    }
  }
  for (size_t i = 0; i < sizeof(kProd) / sizeof(kProd[0]); ++i) {
    const ProductCase* c = &kProd[i];
    const int32_t got = pwofficial_photo_size_status_rule(c->w, c->h);
    if (got != c->expect) {
      fprintf(stderr, "FAIL product %s: got %d want %d\n", c->name, (int)got,
              (int)c->expect);
      ++fail;
    }
  }
  if (fail != 0) return 1;
  printf("PASS upstream %zu/%zu, product %zu/%zu\n",
         sizeof(kUp) / sizeof(kUp[0]), sizeof(kUp) / sizeof(kUp[0]),
         sizeof(kProd) / sizeof(kProd[0]), sizeof(kProd) / sizeof(kProd[0]));
  return 0;
}
