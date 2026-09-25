// colorize_pipeline.dart — 取色解码的有界并行 pipeline(纯 Dart,无 Flutter
// 依赖,tool/ 断言脚本可在 host VM 直接驱动)。
//
// 背景(cap47 遥测):colorize 总耗时 6,794ms ≈ 121 次串行 native 解码
// (p50 56ms),~99% 解码受限;双线性采样摊在 await 间隙里近零成本。
// 两把刀(设计已评审,SP/colorize_parallel_design.md):
//   ① 按 jpegPath 去重 —— 槽位重拍历史等场景同一文件喂给多个 frameId,
//      解码一次共享结果(同文件同字节,采样输入逐位不变);解码缓存按
//      引用计数在“最后一个使用帧”消费后立刻释放,不整段驻留内存。
//   ② 有界并行解码(producer 窗口默认 3)+ 单 consumer 严格按帧顺序采样
//      —— 采样/归约顺序与旧逐帧串行完全一致;内存上限 ≈ 3 张 1280px
//      RGB ≈ 11MB(LOW 档设备安全)。
//
// 确定性论证(输出必须与串行逐位一致):样本进 RepresentativeColorSamples
// 的顺序 = [jobs] 列表顺序(调用方按旧 byFrame.entries 插入序构造),每帧
// 内部双线性循环逐字未改;native 解码是纯函数(同路径同字节)。因此并行
// 度/去重只改墙钟,不改任何输出字节。断言脚本
// tool/colorize_parallel_check.dart 对“旧串行逐帧解码”基线做逐位对拍。
//
// live(ar_capture_page._colorizeSnapshot)与冷恢复(sfm_resume)共享此
// 实现,保证两条腿取色逐点一致(与 representative_color.dart 同一模式)。
//
// ⚠️ iOS native 侧配套:AetherARKitPlugin.colorizeQueue 必须是并发队列
// (attributes: .concurrent),否则 3 个 pending 解码请求在 native 侧仍会
// 排队串行,并行度白给(Dart 侧窗口是唯一的 in-flight 上限)。

import 'dart:typed_data';

import 'representative_color.dart';

/// 交付取色的解码长边上限(px)。
///
/// **出处 = A/B 类:回抄认证配置。** 认证 'o' 口径是**全分辨率**双线性
/// (TRAILS README 白纸黑字 3840×2160);端上的 1280 是 2026-07-09 streaming
/// 大 commit 沿用旧 live 灰度档带进来的,**早于** 07-12 的取色对齐定案,
/// 且从无有损签决 —— 违反"参数全抄认证配置,不自创"铁律。
/// 07-18 参数审计实测(cap51,61,761 点,1280 vs 全分辨率):ΔRGB p50=3/p90=12,
/// **边缘层 10,013 点里 21% 偏色 >16 级、3.7% >32 级**,平坦层仅 1.6% ——
/// 边缘混色病灶实锤。用户 2026-07-20 签决升全分辨率。
///
/// 取 8192 而非"无上限":ImageIO 需要一个具体的
/// `kCGImageSourceThumbnailMaxPixelSize`,8192 已高于任何在产照片边长
/// (主图 1920×1440、12MP 静照 4032×3024;[ENTRY-ANY-4X3 2026-09-25] 起照片可为任意 4:3,
/// 48MP 8064、50MP 8160 仍 < 8192 ⇒ 不降采样;长边 > 8192 才按比例降,关键点坐标照样按
/// JPEG/gray 比例换算),等效于不降采样,同时保留一道
/// 防御性上限,避免将来接入更大图源时无意中撑爆内存。
///
/// ⚠️ live **预览**取色不受此约束(审计原文"live 预览可留 1280") —— 本常量
/// 只用于**交付**云的取色(ar_capture_page 的 _colorizeSnapshot 与
/// sfm_resume 的冷恢复取色,两者共享本 pipeline)。
const int kColorizeDecodeMaxPx = 8192;

/// native 解码回调签名(live/resume 各自的 `_decodeJpegNative`):
/// 按 [kColorizeDecodeMaxPx] 降采样(实际=不降)、raw sensor 方向、
/// 3B/px top-down;失败返回 null。
typedef ColorJpegDecoder = Future<({Uint8List rgb, int w, int h})?> Function(
  String jpegPath,
);

/// 一帧的取色工作项:tri = 该帧要采样的 [pointIndex, kpX, kpY]* 扁平三元组
/// (kp 坐标在 fed-gray 像素空间,采样时按 JPEG/gray 比例缩放)。
class ColorizeFrameJob {
  const ColorizeFrameJob({
    required this.jpegPath,
    required this.grayW,
    required this.grayH,
    required this.tri,
  });

  final String jpegPath;
  final int grayW;
  final int grayH;
  final List<double> tri;
}

/// 解码遥测。[decodeMs] 记录**每次真实发起的 native 解码**耗时(按文件
/// 去重后的 unique 次数,≤ 帧数);帧级计数与旧遥测语义对齐。
class ColorizeDecodeStats {
  /// 采样成功的帧数(旧 `decoded` 语义:同一文件喂多帧时逐帧计数)。
  int framesSampled = 0;

  /// 解码失败的帧数(同一坏文件喂多帧时逐帧计数,与旧语义一致)。
  int decodeFail = 0;

  /// 真实发起的 native 解码次数(按 jpegPath 去重;差值 = 去重省下的解码)。
  int uniqueDecodes = 0;

  /// 每次真实 native 解码的墙钟毫秒(完成序,未排序)。
  final List<double> decodeMs = <double>[];
}

/// 有界并行解码 + 单 consumer 顺序归约:把 [jobs] 的双线性观测样本灌进
/// [samples](池按点预分配,见调用方 obsCap)。
///
/// - 采样顺序严格 = [jobs] 顺序(逐位一致的关键,见文件头论证)。
/// - [maxInFlight] 限制同时 pending 的解码数(=1 退化为纯串行,断言脚本
///   用作基线;生产默认 3,内存 ≈ 3×3.5MB)。
/// - [isCancelled] 每帧消费前查询(调用方传 `!identical(_colorizeTarget,
///   snap)` 哨兵):true 时立刻停止发起/消费并返回,在途解码结果被丢弃。
Future<ColorizeDecodeStats> sampleColorsPipelined({
  required List<ColorizeFrameJob> jobs,
  required RepresentativeColorSamples samples,
  required ColorJpegDecoder decode,
  int maxInFlight = 3,
  bool Function()? isCancelled,
}) async {
  final stats = ColorizeDecodeStats();
  if (jobs.isEmpty) return stats;
  final window = maxInFlight < 1 ? 1 : maxInFlight;

  // 去重刀①的簿记:每个 jpegPath 还有几帧要用(消费后递减,归零即释放
  // 解码缓存引用 → GC 可回收,防止把整段解码图驻留内存)。
  final remainingUses = <String, int>{};
  for (final j in jobs) {
    remainingUses[j.jpegPath] = (remainingUses[j.jpegPath] ?? 0) + 1;
  }
  final pending = <String, Future<({Uint8List rgb, int w, int h})?>>{};

  Future<({Uint8List rgb, int w, int h})?> launch(String path) {
    return pending.putIfAbsent(path, () async {
      stats.uniqueDecodes++;
      final dsw = Stopwatch()..start();
      ({Uint8List rgb, int w, int h})? r;
      try {
        r = await decode(path);
      } catch (_) {
        r = null; // 防御:decoder 约定不 throw,但 prefetch 的 future 若
        //           在取消后无人 await,throw 会成为 unhandled error。
      }
      dsw.stop();
      stats.decodeMs.add(dsw.elapsedMilliseconds.toDouble());
      return r;
    });
  }

  var nextLaunch = 0;
  for (var k = 0; k < jobs.length; k++) {
    if (isCancelled?.call() ?? false) return stats; // 被更新快照取代 → 停
    // producer:窗口内预发解码(含本帧;同路径 putIfAbsent 自动共享)。
    while (nextLaunch < jobs.length && nextLaunch < k + window) {
      launch(jobs[nextLaunch].jpegPath);
      nextLaunch++;
    }
    final job = jobs[k];
    final sj = await pending[job.jpegPath]!; // consumer 严格按 jobs 顺序
    // 引用计数释放:本帧是该文件最后一个使用者时丢缓存引用。
    final left = remainingUses[job.jpegPath]! - 1;
    if (left <= 0) {
      remainingUses.remove(job.jpegPath);
      pending.remove(job.jpegPath);
    } else {
      remainingUses[job.jpegPath] = left;
    }
    if (sj == null) {
      stats.decodeFail++;
      continue;
    }
    stats.framesSampled++;
    // ── 以下双线性采样循环从旧串行实现逐字搬入(勿改:逐位一致的前提)──
    // Keypoint coords live in fed-gray pixel space; the JPEG shares the same
    // sensor orientation, only the scale differs.
    final scaleX = sj.w / job.grayW, scaleY = sj.h / job.grayH;
    final rgbP = sj.rgb;
    final jw = sj.w, jh = sj.h;
    final tri = job.tri;
    for (var t = 0; t < tri.length; t += 3) {
      final i = tri[t].toInt();
      // COLMAP samples at xy - 0.5 (upper-left pixel center = (0.5,0.5)),
      // bilinear, out-of-bounds skipped — Bitmap::InterpolateBilinear.
      final fx = tri[t + 1] * scaleX - 0.5;
      final fy = tri[t + 2] * scaleY - 0.5;
      final x0 = fx.floor(), y0 = fy.floor();
      final x1 = x0 + 1, y1 = y0 + 1;
      if (x0 < 0 || y0 < 0 || x1 >= jw || y1 >= jh) continue;
      final dx = fx - x0, dy = fy - y0;
      final w00 = (1 - dx) * (1 - dy), w01 = dx * (1 - dy);
      final w10 = (1 - dx) * dy, w11 = dx * dy;
      final o00 = (y0 * jw + x0) * 3, o01 = (y0 * jw + x1) * 3;
      final o10 = (y1 * jw + x0) * 3, o11 = (y1 * jw + x1) * 3;
      samples.add(
        i,
        w00 * rgbP[o00] + w01 * rgbP[o01] + w10 * rgbP[o10] + w11 * rgbP[o11],
        w00 * rgbP[o00 + 1] +
            w01 * rgbP[o01 + 1] +
            w10 * rgbP[o10 + 1] +
            w11 * rgbP[o11 + 1],
        w00 * rgbP[o00 + 2] +
            w01 * rgbP[o01 + 2] +
            w10 * rgbP[o10 + 2] +
            w11 * rgbP[o11 + 2],
        k, // [RS-CORRECT-COLORS] 样本来自第 k 帧(jobs 下标)
      );
    }
  }
  return stats;
}
