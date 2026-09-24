// zero_arkit_preview_probe_page.dart — 台架页:把 `ZeroArkitCameraPreview`
// 放进与生产同尺寸的 3:4 框里跑,看控制台那一行
//     [zero-arkit-preview] 判据: ✅ 方差大 ⇒ 屏上有真实图像内容
//
// ══ 🔴 它会打开摄像头 ═══════════════════════════════════════════════════════
// 开的是 [PwCameraSlot] 自己那个最小 AVCaptureSession(1920×1440 / 32BGRA)。
//   * 要不要动手机:**不用**。静止摆着就能出判据。
//   * 写多少数据:**零**。深度 1 的槽只在内存里留最新一帧,不落盘。
//   * 时长:由使用者停留决定;离开本页即 [PwCameraSlot.stop]。
//
// ══ 为什么在台架而不是生产包上跑 ══════════════════════════════════════════
// 「没全面持平/超越 ARKit 之前绝不上生产」—— 手机上的 PocketWorld 是生产包,
// 一个字节不碰。台架是独立 bundle(com.kyle.arloopbench),`lib/vio/**` 是生产
// 的镜像(真源在 pocketworld,`sync_from_production.sh` 同步并自证逐字节一致)。
//
// ══ 与生产 ON 臂的差别(有意,不是漏)══════════════════════════════════════
//   * 相机由本页直接起。生产由 `ZeroArkitCaptureRuntime` 经租约闸起 —— 那道闸
//     防的是 ARKit 抢相机,台架里没有 ARKit,没什么可防。
//   * 不建 XRSLAM 会话,`poseReader` 为 null ⇒ 日志里 `pose=false` 是**预期**。
//     本页只判「预览画出来了没有」这一件事。
//   * 生产的 3:4 框是 `CapturePreviewRect`(满宽,顶部按安全区算偏移);这里用
//     `AspectRatio(3/4)` 满宽 —— 视口像素完全一样(1179×1572 @ 14 Pro),
//     只是纵向位置不同,对判据无影响。
//
// ══ 第二个判据:拆装 ═══════════════════════════════════════════════════════
// 「关闭预览」把 widget 从树上拆掉 —— 走的正是生产退出采集页时那条序:
// ViewerWidget 先拆、`viewer.onDispose` 里只拆纹理/材质不碰 asset。
// 「再开」重新挂上。判据:拆装一次**不崩**,第二次仍出画(引擎没被一起销毁)。

import 'package:flutter/material.dart';

import '../pose/camera_slot_ffi.dart';
import 'zero_arkit_camera_preview.dart';

/// 采集尺寸,与生产 `ZeroArkitCaptureRuntime` 默认值同一个数。
const int kZeroArkitProbeWidth = 1920;
const int kZeroArkitProbeHeight = 1440;

class ZeroArkitPreviewProbePage extends StatefulWidget {
  const ZeroArkitPreviewProbePage({super.key});

  @override
  State<ZeroArkitPreviewProbePage> createState() =>
      _ZeroArkitPreviewProbePageState();
}

class _ZeroArkitPreviewProbePageState extends State<ZeroArkitPreviewProbePage> {
  int? _cameraRc;
  bool _showPreview = true;
  int _mountCount = 1;

  @override
  void initState() {
    super.initState();
    // 🔴 相机先起。预览 widget 自己不开相机,只从槽里取。
    final int rc = PwCameraSlot.start(
      width: kZeroArkitProbeWidth,
      height: kZeroArkitProbeHeight,
    );
    _cameraRc = rc;
    debugPrint('$kZeroArkitPreviewLogTag 台架:相机启动 rc=$rc '
        '(${kZeroArkitProbeWidth}x$kZeroArkitProbeHeight)');
  }

  @override
  void dispose() {
    if (_cameraRc == 0) PwCameraSlot.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int? rc = _cameraRc;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                  height: 1.4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(rc == 0
                        ? '相机已起(rc=0)· 第 $_mountCount 次挂载'
                        : '🔴 相机启动失败 rc=$rc'),
                    const Text('判据看控制台:[zero-arkit-preview] 判据:'),
                  ],
                ),
              ),
            ),
            // 与生产 CapturePreviewRect 同比:满宽 3:4。
            AspectRatio(
              aspectRatio: 3 / 4,
              child: _showPreview
                  ? ZeroArkitCameraPreview(
                      key: ValueKey<int>(_mountCount),
                      imageWidth: kZeroArkitProbeWidth,
                      imageHeight: kZeroArkitProbeHeight,
                    )
                  : const ColoredBox(
                      color: Color(0xFF202020),
                      child: Center(
                        child: Text('预览已拆',
                            style: TextStyle(color: Colors.white54)),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: _showPreview
                          ? () => setState(() => _showPreview = false)
                          : null,
                      child: const Text('关闭预览(走拆卸序)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _showPreview
                          ? null
                          : () => setState(() {
                                _showPreview = true;
                                _mountCount++;
                              }),
                      child: const Text('再开'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
