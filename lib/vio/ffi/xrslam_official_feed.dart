// xrslam_official_feed.dart — [bench 2026-09-24] 台架默认的 XRSLAM 喂料口径 = 官方 iOS 配置。
//
// 官方 iOS demo(openxrlab/xrslam @4beb1a9 xrslam-ios/visualizer):AVCapture `.vga640x480`
// @30 fps,`slam_params.yaml`,每机 yaml `time_offset: 0.0`,presentationTimeStamp 原样推。
// 台架链的引擎是同一血统 + 官方规则 + 线程化(`libxrslam_official_rules_*.a`,
// xrslam feat/official-ios-rules);这里只定「喂什么尺寸」:
//
//   · Dart 把 device yaml 的 `cam0.resolution` 写成 640×480,内参按 box n×n 换算
//     (源尺寸恰是 640×480 的整数 n 倍时;公式与传输层
//     `PWXrslamTransportScaleIntrinsicsForBoxNxN` / `tools/pwvi_to_euroc.py` 相同:
//     fx' = fx/n, cx' = (cx+0.5)/n − 0.5)。
//   · 原生(`PwXrslamLive.runOneFrame`)看到「源帧 = yaml 的 n 倍」就做同一个 box n,
//     逐帧 K 走同一个公式;30 Hz 准入与原始 PTS 也在原生(`PwXrslamOfficialFeed`)。
//   · 源尺寸不是 640×480 的整数倍 ⇒ 内参原样(原生原样推),不猜换算。
//
// 保留的偏离(有意):逐帧内参(自动对焦开着;官方锁焦 0.835 + 固定 K);图像源是
// 1920×1440 box/3(ARKit Y 平面 / AVCapture BGRA 先按 OpenCV 系数转灰),不是 AVCapture
// vga640x480 BGRA。
// [2026-09-25] 时间戳偏离官方:台架默认**曝光中点** `t_feed = PTS + exposure/2 + c`
// (c 每机查表,iPhone15,2 = 3.00 ms;Huai arXiv 2001.00470 §IV.B,09-22 定案;真机回放
// run-13f53d2f 尺度 0.963 → 1.0022、ATE 5.4 → 1.79 cm)。退回官方原始 PTS + c=0:
// 原生 `-PWXrslamExposureMid off`(见 PwXrslamLive.swift `PwXrslamOfficialFeed` ③)。
//
// 回退到旧口径(整幅 1920 直推):`--dart-define=PW_XRSLAM_FULLRES_FEED=true`,
// 同时原生 `-PWXrslamCameraHz 0`(曝光中点现在本来就默认 on)。
import 'xrslam_config.dart';

/// 官方喂料宽高(上游 18/18 份 iPhone 标定都是 640×480)。
const int kXrslamOfficialFeedWidth = 640;
const int kXrslamOfficialFeedHeight = 480;

/// 官方喂料帧率(原生 `-PWXrslamCameraHz` 的默认值,这里只用于显示与回执)。
const double kXrslamOfficialCameraHz = 30.0;

/// 编译期回退开关:true = 旧口径(整幅直推)。
const bool kXrslamFullResFeed =
    bool.fromEnvironment('PW_XRSLAM_FULLRES_FEED', defaultValue: false);

/// 源帧尺寸 → 官方喂料的 box 因子;0 = 不是整数倍(不降采样)。
int xrslamOfficialFeedFactor(int sourceWidth, int sourceHeight) {
  if (kXrslamFullResFeed) return 1;
  if (sourceWidth % kXrslamOfficialFeedWidth != 0 ||
      sourceHeight % kXrslamOfficialFeedHeight != 0) {
    return 0;
  }
  final int nx = sourceWidth ~/ kXrslamOfficialFeedWidth;
  final int ny = sourceHeight ~/ kXrslamOfficialFeedHeight;
  return nx == ny && nx >= 1 ? nx : 0;
}

/// 采集尺寸的内参 → 官方喂料尺寸的内参(box n×n,像素中心在整数坐标的约定)。
/// n == 1 或不成整数倍 ⇒ 原样返回。
CameraIntrinsics xrslamOfficialFeedIntrinsics(CameraIntrinsics k) {
  final int n = xrslamOfficialFeedFactor(k.resolutionWidth, k.resolutionHeight);
  if (n <= 1) return k;
  return CameraIntrinsics(
    fx: k.fx / n,
    fy: k.fy / n,
    cx: (k.cx + 0.5) / n - 0.5,
    cy: (k.cy + 0.5) / n - 0.5,
    resolutionWidth: k.resolutionWidth ~/ n,
    resolutionHeight: k.resolutionHeight ~/ n,
    provenance: k.provenance,
  );
}
