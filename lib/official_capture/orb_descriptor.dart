// ORB 描述子 —— OpenCV 4.x `modules/features2d/src/orb.cpp` 的逐字复刻。
//
// 为什么需要它:用户 2026-09-10 报"两张空间重合的照片还是都拍了"。定罪见
// docs/handoffs/PLACE_RECOGNITION_RTABMAP_PLAN.md —— 这是**重定位**问题,
// 不是跟踪问题,而 LK 没有「匹配对不对」的概念(跨大位移会收敛到垃圾并报成功)。
// 裁决走 RTAB-Map,其默认 `Kp/DetectorStrategy` 在没有 xfeatures2d 时 = 8 =
// **GFTT/ORB**:关键点用我们已复刻的 goodFeaturesToTrack,描述子用 ORB。
//
// 许可:OpenCV 4.x = Apache-2.0。
//
// 逐位对拍的三处精度坑(都已回源核实,不这么做就对不上 OpenCV):
//   * 方向角用 **fastAtan2 的多项式近似**,不是 atan2 —— 精确 atan2 那支
//     只在 `#ifdef __EMSCRIPTEN__` 下(mathfuncs_core.simd.hpp:43)。
//   * `cvRound` 是**银行家舍入**(ties-to-even):fast_math.hpp 里
//     `vcvtn_s32_f32` / `_mm_cvtss_si32` / `lrint` 全是 IEEE 默认舍入模式。
//     Dart 的 `.round()` 是"逢半远离零",直接用会错。
//   * OpenCV 全程 **float32** 运算;Dart 只有 double,所以每一步都过
//     [_f32] 收敛到 float32,否则多项式与旋转的低位会漂。
//
// 边界:OpenCV 先 `copyMakeBorder(..., BORDER_REFLECT_101)` 填充
// `border = max(edgeThreshold=31, ceil(15*sqrt2)=22) + 1 = 32` 像素(orb.cpp:1031)。
// 采样最远只到 ~22 px(pattern ≤13 经旋转 ≤19,加 halfPatch 15 的圆盘),
// 32 > 22 ⇒ **直接在原图上做 REFLECT_101 采样与之等价**,不必真的建填充图。

import 'dart:math' as math;
import 'dart:typed_data';

/// ORB 的 patch 与描述子尺寸(orb.cpp 默认 patchSize=31、kBytes=32)。
const int kOrbPatchSize = 31;
const int kOrbHalfPatchSize = kOrbPatchSize ~/ 2; // 15
const int kOrbDescriptorBytes = 32; // 256 bit

/// `bit_pattern_31_[256*4]`,逐字取自 orb.cpp:380。
/// 抽取时过了阳性对照:1024 个整数、取值范围 −13..12。
const List<int> kOrbBitPattern31 = <int>[
  8,
  -3,
  9,
  5,
  4,
  2,
  7,
  -12,
  -11,
  9,
  -8,
  2,
  7,
  -12,
  12,
  -13,
  2,
  -13,
  2,
  12,
  1,
  -7,
  1,
  6,
  -2,
  -10,
  -2,
  -4,
  -13,
  -13,
  -11,
  -8,
  -13,
  -3,
  -12,
  -9,
  10,
  4,
  11,
  9,
  -13,
  -8,
  -8,
  -9,
  -11,
  7,
  -9,
  12,
  7,
  7,
  12,
  6,
  -4,
  -5,
  -3,
  0,
  -13,
  2,
  -12,
  -3,
  -9,
  0,
  -7,
  5,
  12,
  -6,
  12,
  -1,
  -3,
  6,
  -2,
  12,
  -6,
  -13,
  -4,
  -8,
  11,
  -13,
  12,
  -8,
  4,
  7,
  5,
  1,
  5,
  -3,
  10,
  -3,
  3,
  -7,
  6,
  12,
  -8,
  -7,
  -6,
  -2,
  -2,
  11,
  -1,
  -10,
  -13,
  12,
  -8,
  10,
  -7,
  3,
  -5,
  -3,
  -4,
  2,
  -3,
  7,
  -10,
  -12,
  -6,
  11,
  5,
  -12,
  6,
  -7,
  5,
  -6,
  7,
  -1,
  1,
  0,
  4,
  -5,
  9,
  11,
  11,
  -13,
  4,
  7,
  4,
  12,
  2,
  -1,
  4,
  4,
  -4,
  -12,
  -2,
  7,
  -8,
  -5,
  -7,
  -10,
  4,
  11,
  9,
  12,
  0,
  -8,
  1,
  -13,
  -13,
  -2,
  -8,
  2,
  -3,
  -2,
  -2,
  3,
  -6,
  9,
  -4,
  -9,
  8,
  12,
  10,
  7,
  0,
  9,
  1,
  3,
  7,
  -5,
  11,
  -10,
  -13,
  -6,
  -11,
  0,
  10,
  7,
  12,
  1,
  -6,
  -3,
  -6,
  12,
  10,
  -9,
  12,
  -4,
  -13,
  8,
  -8,
  -12,
  -13,
  0,
  -8,
  -4,
  3,
  3,
  7,
  8,
  5,
  7,
  10,
  -7,
  -1,
  7,
  1,
  -12,
  3,
  -10,
  5,
  6,
  2,
  -4,
  3,
  -10,
  -13,
  0,
  -13,
  5,
  -13,
  -7,
  -12,
  12,
  -13,
  3,
  -11,
  8,
  -7,
  12,
  -4,
  7,
  6,
  -10,
  12,
  8,
  -9,
  -1,
  -7,
  -6,
  -2,
  -5,
  0,
  12,
  -12,
  5,
  -7,
  5,
  3,
  -10,
  8,
  -13,
  -7,
  -7,
  -4,
  5,
  -3,
  -2,
  -1,
  -7,
  2,
  9,
  5,
  -11,
  -11,
  -13,
  -5,
  -13,
  -1,
  6,
  0,
  -1,
  5,
  -3,
  5,
  2,
  -4,
  -13,
  -4,
  12,
  -9,
  -6,
  -9,
  6,
  -12,
  -10,
  -8,
  -4,
  10,
  2,
  12,
  -3,
  7,
  12,
  12,
  12,
  -7,
  -13,
  -6,
  5,
  -4,
  9,
  -3,
  4,
  7,
  -1,
  12,
  2,
  -7,
  6,
  -5,
  1,
  -13,
  11,
  -12,
  5,
  -3,
  7,
  -2,
  -6,
  7,
  -8,
  12,
  -7,
  -13,
  -7,
  -11,
  -12,
  1,
  -3,
  12,
  12,
  2,
  -6,
  3,
  0,
  -4,
  3,
  -2,
  -13,
  -1,
  -13,
  1,
  9,
  7,
  1,
  8,
  -6,
  1,
  -1,
  3,
  12,
  9,
  1,
  12,
  6,
  -1,
  -9,
  -1,
  3,
  -13,
  -13,
  -10,
  5,
  7,
  7,
  10,
  12,
  12,
  -5,
  12,
  9,
  6,
  3,
  7,
  11,
  5,
  -13,
  6,
  10,
  2,
  -12,
  2,
  3,
  3,
  8,
  4,
  -6,
  2,
  6,
  12,
  -13,
  9,
  -12,
  10,
  3,
  -8,
  4,
  -7,
  9,
  -11,
  12,
  -4,
  -6,
  1,
  12,
  2,
  -8,
  6,
  -9,
  7,
  -4,
  2,
  3,
  3,
  -2,
  6,
  3,
  11,
  0,
  3,
  -3,
  8,
  -8,
  7,
  8,
  9,
  3,
  -11,
  -5,
  -6,
  -4,
  -10,
  11,
  -5,
  10,
  -5,
  -8,
  -3,
  12,
  -10,
  5,
  -9,
  0,
  8,
  -1,
  12,
  -6,
  4,
  -6,
  6,
  -11,
  -10,
  12,
  -8,
  7,
  4,
  -2,
  6,
  7,
  -2,
  0,
  -2,
  12,
  -5,
  -8,
  -5,
  2,
  7,
  -6,
  10,
  12,
  -9,
  -13,
  -8,
  -8,
  -5,
  -13,
  -5,
  -2,
  8,
  -8,
  9,
  -13,
  -9,
  -11,
  -9,
  0,
  1,
  -8,
  1,
  -2,
  7,
  -4,
  9,
  1,
  -2,
  1,
  -1,
  -4,
  11,
  -6,
  12,
  -11,
  -12,
  -9,
  -6,
  4,
  3,
  7,
  7,
  12,
  5,
  5,
  10,
  8,
  0,
  -4,
  2,
  8,
  -9,
  12,
  -5,
  -13,
  0,
  7,
  2,
  12,
  -1,
  2,
  1,
  7,
  5,
  11,
  7,
  -9,
  3,
  5,
  6,
  -8,
  -13,
  -4,
  -8,
  9,
  -5,
  9,
  -3,
  -3,
  -4,
  -7,
  -3,
  -12,
  6,
  5,
  8,
  0,
  -7,
  6,
  -6,
  12,
  -13,
  6,
  -5,
  -2,
  1,
  -10,
  3,
  10,
  4,
  1,
  8,
  -4,
  -2,
  -2,
  2,
  -13,
  2,
  -12,
  12,
  12,
  -2,
  -13,
  0,
  -6,
  4,
  1,
  9,
  3,
  -6,
  -10,
  -3,
  -5,
  -3,
  -13,
  -1,
  1,
  7,
  5,
  12,
  -11,
  4,
  -2,
  5,
  -7,
  -13,
  9,
  -9,
  -5,
  7,
  1,
  8,
  6,
  7,
  -8,
  7,
  6,
  -7,
  -4,
  -7,
  1,
  -8,
  11,
  -7,
  -8,
  -13,
  6,
  -12,
  -8,
  2,
  4,
  3,
  9,
  10,
  -5,
  12,
  3,
  -6,
  -5,
  -6,
  7,
  8,
  -3,
  9,
  -8,
  2,
  -12,
  2,
  8,
  -11,
  -2,
  -10,
  3,
  -12,
  -13,
  -7,
  -9,
  -11,
  0,
  -10,
  -5,
  5,
  -3,
  11,
  8,
  -2,
  -13,
  -1,
  12,
  -1,
  -8,
  0,
  9,
  -13,
  -11,
  -12,
  -5,
  -10,
  -2,
  -10,
  11,
  -3,
  9,
  -2,
  -13,
  2,
  -3,
  3,
  2,
  -9,
  -13,
  -4,
  0,
  -4,
  6,
  -3,
  -10,
  -4,
  12,
  -2,
  -7,
  -6,
  -11,
  -4,
  9,
  6,
  -3,
  6,
  11,
  -13,
  11,
  -5,
  5,
  11,
  11,
  12,
  6,
  7,
  -5,
  12,
  -2,
  -1,
  12,
  0,
  7,
  -4,
  -8,
  -3,
  -2,
  -7,
  1,
  -6,
  7,
  -13,
  -12,
  -8,
  -13,
  -7,
  -2,
  -6,
  -8,
  -8,
  5,
  -6,
  -9,
  -5,
  -1,
  -4,
  5,
  -13,
  7,
  -8,
  10,
  1,
  5,
  5,
  -13,
  1,
  0,
  10,
  -13,
  9,
  12,
  10,
  -1,
  5,
  -8,
  10,
  -9,
  -1,
  11,
  1,
  -13,
  -9,
  -3,
  -6,
  2,
  -1,
  -10,
  1,
  12,
  -13,
  1,
  -8,
  -10,
  8,
  -11,
  10,
  -6,
  2,
  -13,
  3,
  -6,
  7,
  -13,
  12,
  -9,
  -10,
  -10,
  -5,
  -7,
  -10,
  -8,
  -8,
  -13,
  4,
  -6,
  8,
  5,
  3,
  12,
  8,
  -13,
  -4,
  2,
  -3,
  -3,
  5,
  -13,
  10,
  -12,
  4,
  -13,
  5,
  -1,
  -9,
  9,
  -4,
  3,
  0,
  3,
  3,
  -9,
  -12,
  1,
  -6,
  1,
  3,
  2,
  4,
  -8,
  -10,
  -10,
  -10,
  9,
  8,
  -13,
  12,
  12,
  -8,
  -12,
  -6,
  -5,
  2,
  2,
  3,
  7,
  10,
  6,
  11,
  -8,
  6,
  8,
  8,
  -12,
  -7,
  10,
  -6,
  5,
  -3,
  -9,
  -3,
  9,
  -1,
  -13,
  -1,
  5,
  -3,
  -7,
  -3,
  4,
  -8,
  -2,
  -8,
  3,
  4,
  2,
  12,
  12,
  2,
  -5,
  3,
  11,
  6,
  -9,
  11,
  -13,
  3,
  -1,
  7,
  12,
  11,
  -1,
  12,
  4,
  -3,
  0,
  -3,
  6,
  4,
  -11,
  4,
  12,
  2,
  -4,
  2,
  1,
  -10,
  -6,
  -8,
  1,
  -13,
  7,
  -11,
  1,
  -13,
  12,
  -11,
  -13,
  6,
  0,
  11,
  -13,
  0,
  -1,
  1,
  4,
  -13,
  3,
  -9,
  -2,
  -9,
  8,
  -6,
  -3,
  -13,
  -6,
  -8,
  -2,
  5,
  -9,
  8,
  10,
  2,
  7,
  3,
  -9,
  -1,
  -6,
  -1,
  -1,
  9,
  5,
  11,
  -2,
  11,
  -3,
  12,
  -8,
  3,
  0,
  3,
  5,
  -1,
  4,
  0,
  10,
  3,
  -6,
  4,
  5,
  -13,
  0,
  -10,
  5,
  5,
  8,
  12,
  11,
  8,
  9,
  9,
  -6,
  7,
  -4,
  8,
  -12,
  -10,
  4,
  -10,
  9,
  7,
  3,
  12,
  4,
  9,
  -7,
  10,
  -2,
  7,
  0,
  12,
  -2,
  -1,
  -6,
  0,
  -11,
];

final Float32List _f32Scratch = Float32List(1);

/// 把 double 收敛到 float32 —— OpenCV 全程 float 运算,不收敛就对不上低位。
double _f32(double v) {
  _f32Scratch[0] = v;
  return _f32Scratch[0];
}

/// OpenCV `cvRound`:**ties-to-even**(fast_math.hpp;lrint / vcvtn / cvtss 都是
/// IEEE 默认舍入模式)。Dart 的 `.round()` 是逢半远离零,不能用。
int cvRound(double value) {
  final floor = value.floor();
  final diff = value - floor;
  if (diff > 0.5) return floor + 1;
  if (diff < 0.5) return floor;
  return floor.isEven ? floor : floor + 1;
}

const double _atan2P1 = 0.9997878412794807 * (180 / math.pi);
const double _atan2P3 = -0.3258083974640975 * (180 / math.pi);
const double _atan2P5 = 0.1555786518463281 * (180 / math.pi);
const double _atan2P7 = -0.04432655554792128 * (180 / math.pi);

/// C 的 `DBL_EPSILON`,被 OpenCV 转成 float 用作除零保护。
const double _dblEpsilon = 2.220446049250313e-16;

/// OpenCV `atan_f32`(即 `fastAtan2`)—— mathfuncs_core.simd.hpp:54 的
/// 非 EMSCRIPTEN 分支,逐字。返回度数,范围 [0, 360)。
double fastAtan2(double y, double x) {
  final double ax = x.abs();
  final double ay = y.abs();
  double a;
  if (ax >= ay) {
    final double c = _f32(ay / _f32(ax + _f32(_dblEpsilon)));
    final double c2 = _f32(c * c);
    a = _f32(
      _f32(_f32(_f32(_f32(_atan2P7 * c2) + _atan2P5) * c2) + _atan2P3) * c2 +
          _atan2P1,
    );
    a = _f32(a * c);
  } else {
    final double c = _f32(ax / _f32(ay + _f32(_dblEpsilon)));
    final double c2 = _f32(c * c);
    double t = _f32(
      _f32(_f32(_f32(_f32(_atan2P7 * c2) + _atan2P5) * c2) + _atan2P3) * c2 +
          _atan2P1,
    );
    t = _f32(t * c);
    a = _f32(90.0 - t);
  }
  if (x < 0) a = _f32(180.0 - a);
  if (y < 0) a = _f32(360.0 - a);
  return a;
}

/// `umax` —— 圆形 patch 每一行的半宽,orb.cpp:861-876 逐字。
List<int> buildOrbUmax() {
  const int half = kOrbHalfPatchSize;
  final umax = List<int>.filled(half + 2, 0);
  final int vmax = (half * math.sqrt(2.0) / 2 + 1).floor();
  final int vmin = (half * math.sqrt(2.0) / 2).ceil();
  for (var v = 0; v <= vmax; ++v) {
    umax[v] = cvRound(math.sqrt(half * half - v * v).toDouble());
  }
  var v0 = 0;
  for (var v = half; v >= vmin; --v) {
    while (umax[v0] == umax[v0 + 1]) {
      ++v0;
    }
    umax[v] = v0;
    ++v0;
  }
  return umax;
}

final List<int> _umax = buildOrbUmax();

/// `cv2.getGaussianKernel(7, 2.0)` 的输出 —— 直接取 OpenCV 自己算出的值,
/// 与抄 `bit_pattern_31_` 同性质(它内部用 softdouble 做逐位可复现,
/// 在 Dart 里重搬那套代价不成比例)。
const List<double> kOrbBlurKernel7Sigma2 = <double>[
  7.01593269590260609769e-02,
  1.31074878967365970883e-01,
  1.90712823569637340837e-01,
  2.16105941007941143583e-01,
  1.90712823569637340837e-01,
  1.31074878967365970883e-01,
  7.01593269590260609769e-02,
];

/// `getGaussianKernelFixedPoint_ED`(smooth.dispatch.cpp:224)—— **误差扩散**
/// 把浮点核转成 8 位小数的定点核。8U 通道走的就是这条:`createGaussianKernels`
/// 用 `ufixedpoint16`(向量名 `fixed_256` ⇒ 1<<8)。
List<int> buildOrbBlurFixedKernel() {
  const int fractionMultiplier = 1 << 8;
  final res = List<int>.filled(7, 0);
  var err = 0.0;
  var sum = 0;
  for (var i = 0; i < 3; i++) {
    final double adj = kOrbBlurKernel7Sigma2[i] * fractionMultiplier + err;
    final int v0 = cvRound(adj);
    err = adj - v0;
    res[i] = v0;
    res[6 - i] = v0;
    sum += v0;
  }
  // 中心项由「总和必须正好等于 1<<8」倒推,不是四舍五入出来的(上游同款)。
  res[3] = fractionMultiplier - 2 * sum;
  return res;
}

final List<int> _orbBlurFixedKernel = buildOrbBlurFixedKernel();

/// `GaussianBlur` 的**逐位定点**路径(8U):与 `cv2.GaussianBlur(整图)` 逐像素
/// 相同。⚠️ **ORB 走的不是这条** —— 见 [orbBlurForDescriptors]。留着它是因为
/// 别处若要复刻标准的 8U 高斯模糊,这份是对的,且有测试钉住。
Uint8List orbBlurBitExact8U(Uint8List gray, int width, int height) {
  final k = _orbBlurFixedKernel;
  const r = 3;
  final tmp = Int32List(width * height);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      var acc = 0;
      for (var i = -r; i <= r; i++) {
        acc += k[i + r] * gray[row + _reflect101(x + i, width)];
      }
      tmp[row + x] = acc;
    }
  }
  final out = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var acc = 0;
      for (var i = -r; i <= r; i++) {
        acc += k[i + r] * tmp[_reflect101(y + i, height) * width + x];
      }
      final v = (acc + (1 << 15)) >> 16;
      out[y * width + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
  return out;
}

/// ORB 在算描述子**之前**对图做的那一刀:
/// `GaussianBlur(workingMat, workingMat, Size(7,7), 2, 2, BORDER_REFLECT_101)`
/// (orb.cpp:1234)。方向角(ICAngles)用的是**模糊前**的图 —— 两者别搞混。
///
/// 🔴 **这里是浮点,不是定点,而且这是对的。** smooth.dispatch.cpp:657:
///
///     if (sdepth == CV_8U && ((borderType & BORDER_ISOLATED) || !_src.isSubmatrix()))
///     { /* 逐位定点路径 */ }
///
/// ORB 传进去的 `workingMat` 是**金字塔的子矩阵**、又没带 `BORDER_ISOLATED`
/// ⇒ 条件为假 ⇒ **跳过定点路径**,走通用浮点滤波。而
/// `cv2.GaussianBlur(整图)` 不是子矩阵,走的是定点路径 —— 两者本来就不同。
/// 2026-09-10 我先按"定点才是对的"改过一版,描述子反而从 46/46 掉到 29/46,
/// 差的三处全是**汉明距 1 的平局**(t0==t1),顺着它才查到这条分派条件。
/// 判据:描述子是否与 OpenCV 逐字节相同 —— 浮点版 46/46,定点版 29/46。
Uint8List orbBlurForDescriptors(Uint8List gray, int width, int height) {
  final tmp = Float64List(width * height);
  const r = 3;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      var acc = 0.0;
      for (var i = -r; i <= r; i++) {
        acc +=
            kOrbBlurKernel7Sigma2[i + r] *
            gray[row + _reflect101(x + i, width)];
      }
      tmp[row + x] = acc;
    }
  }
  final out = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var acc = 0.0;
      for (var i = -r; i <= r; i++) {
        acc +=
            kOrbBlurKernel7Sigma2[i + r] *
            tmp[_reflect101(y + i, height) * width + x];
      }
      final v = cvRound(acc);
      out[y * width + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
  return out;
}

/// BORDER_REFLECT_101:−1→1、−2→2、n→n−2、n+1→n−3。
int _reflect101(int p, int n) {
  if (n == 1) return 0;
  var v = p;
  while (v < 0 || v >= n) {
    if (v < 0) {
      v = -v;
    } else {
      v = 2 * (n - 1) - v;
    }
  }
  return v;
}

int _at(Uint8List gray, int width, int height, int x, int y) =>
    gray[_reflect101(y, height) * width + _reflect101(x, width)];

/// `ICAngles` —— 灰度质心矩定方向,orb.cpp:ICAngles 逐字。返回度数。
double orbKeypointAngle(
  Uint8List gray,
  int width,
  int height,
  double px,
  double py,
) {
  final int cx = cvRound(px);
  final int cy = cvRound(py);
  var m01 = 0;
  var m10 = 0;
  for (var u = -kOrbHalfPatchSize; u <= kOrbHalfPatchSize; ++u) {
    m10 += u * _at(gray, width, height, cx + u, cy);
  }
  for (var v = 1; v <= kOrbHalfPatchSize; ++v) {
    var vSum = 0;
    final int d = _umax[v];
    for (var u = -d; u <= d; ++u) {
      final int valPlus = _at(gray, width, height, cx + u, cy + v);
      final int valMinus = _at(gray, width, height, cx + u, cy - v);
      vSum += valPlus - valMinus;
      m10 += u * (valPlus + valMinus);
    }
    m01 += v * vSum;
  }
  return fastAtan2(m01.toDouble(), m10.toDouble());
}

/// `computeOrbDescriptors` 的 wta_k==2 分支,orb.cpp 逐字。
///
/// 🔴 [blurred] 必须是 [orbBlurForDescriptors] 的输出 —— ORB 在算描述子前会
/// 对图做 7×7/σ=2 高斯模糊(orb.cpp:1234)。喂原图会得到**看起来对、其实错**
/// 的描述子(2026-09-10 就是漏了这一步,对拍 44/256 位不同)。
/// [angleDeg] 传 null 则按 [orbKeypointAngle] 求(注意:方向角要用**模糊前**
/// 的图,RTAB-Map 的 GFTT/ORB 路径实际传的是 −1,见该文件头)。
Uint8List computeOrbDescriptor(
  Uint8List blurred,
  int width,
  int height,
  double px,
  double py, {
  double? angleDeg,
}) {
  final double angle = _f32(
    (angleDeg ?? orbKeypointAngle(blurred, width, height, px, py)) *
        (math.pi / 180.0),
  );
  final double a = _f32(math.cos(angle));
  final double b = _f32(math.sin(angle));
  final int cx = cvRound(px);
  final int cy = cvRound(py);
  final desc = Uint8List(kOrbDescriptorBytes);
  var p = 0;
  for (var i = 0; i < kOrbDescriptorBytes; ++i) {
    var val = 0;
    for (var bit = 0; bit < 8; ++bit) {
      final int px0 = kOrbBitPattern31[p];
      final int py0 = kOrbBitPattern31[p + 1];
      final int px1 = kOrbBitPattern31[p + 2];
      final int py1 = kOrbBitPattern31[p + 3];
      p += 4;
      final int ix0 = cvRound(_f32(_f32(px0 * a) - _f32(py0 * b)));
      final int iy0 = cvRound(_f32(_f32(px0 * b) + _f32(py0 * a)));
      final int ix1 = cvRound(_f32(_f32(px1 * a) - _f32(py1 * b)));
      final int iy1 = cvRound(_f32(_f32(px1 * b) + _f32(py1 * a)));
      final int t0 = _at(blurred, width, height, cx + ix0, cy + iy0);
      final int t1 = _at(blurred, width, height, cx + ix1, cy + iy1);
      if (t0 < t1) val |= 1 << bit;
    }
    desc[i] = val;
  }
  return desc;
}

/// 汉明距离 —— RTAB-Map 的词典按它做近邻(二进制描述子)。
int hammingDistance(Uint8List a, Uint8List b) {
  var d = 0;
  for (var i = 0; i < a.length; ++i) {
    var x = a[i] ^ b[i];
    while (x != 0) {
      x &= x - 1;
      d++;
    }
  }
  return d;
}
