// ar_minimal_loop_page.dart — 最小可见回路的宿主页。
//
// 这一页**只为验证一件事**:相机帧能不能经由我们自己算的 UV 与投影,在
// Filament 里显示出来。它不接 VIO、不接锚点、不接采集 —— 那些是下一步。
//
// ══ 🔴 它会打开摄像头 ═══════════════════════════════════════════════════════
// 开的是 [PwCameraSlot] 自己那个最小 AVCaptureSession(640×480 / 32BGRA)。
//   * 要不要动手机:**不用**。静止摆着就能验证背景和方向。
//   * 写多少数据:**零**。深度 1 的槽只在内存里留最新一帧,不落盘。
//   * 时长:由使用者停留决定;离开本页即 [PwCameraSlot.stop]。
// 🔴 iOS 把后置相机只给一个会话 ⇒ 本页与 ARKit / 生产采集**不能同时跑**。
//
// ══ 怎么看结果 ═════════════════════════════════════════════════════════════
// 左上角那块计账条就是判据,不用猜:
//   frame=false  持续为假 ⇒ 相机没在交付(槽空)。
//   K=false      ⇒ 相机没自报内参。
//   proj=false   ⇒ 内参不可用或 near/far 非法,投影没设上。
//   pose=false   ⇒ 本页没接位姿源,**这是预期的**。
//   outstanding  ⇒ 未归还的缓冲数。**恒为 0 或 1;>1 就是漏**。
//   displaced    ⇒ 被新帧顶掉的帧数。**这是正常的**,深度 1 的代价,不是丢帧。

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show rootBundle;
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;

import '../pose/camera_slot_ffi.dart';
import '../pose/display_transform.dart';
import 'ar_render_loop.dart';

/// 采集尺寸。640×480 的出处:XRSLAM 上游 18 份 iPhone 标定 **18/18 全是
/// 640×480**(含 iPhone 16e),且上游 demo 默认就是 `.vga640x480` ——
/// 不是我们挑的数。
const int kFeedWidth = 640;
const int kFeedHeight = 480;

class ArMinimalLoopPage extends StatefulWidget {
  const ArMinimalLoopPage({super.key});

  @override
  State<ArMinimalLoopPage> createState() => _ArMinimalLoopPageState();
}

class _ArMinimalLoopPageState extends State<ArMinimalLoopPage>
    with SingleTickerProviderStateMixin {
  ArRenderLoop? _loop;
  Ticker? _ticker;
  bool _cameraStarted = false;
  String _status = '等待渲染器…';
  ArFrameOutcome? _last;
  CameraSlotStats? _stats;
  bool _stepping = false;

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    // 🔴 先停相机再拆回路。反过来的话,最后一帧可能已经交给了 Filament 而
    // 纹理已被销毁。
    if (_cameraStarted) {
      PwCameraSlot.stop();
      _cameraStarted = false;
    }
    _loop?.dispose();
    super.dispose();
  }

  Future<void> _onViewer(ThermionViewer viewer) async {
    try {
      // 背景色只是为了让"三角形没画出来"和"画出来了但全黑"能分开。
      await viewer.setBackgroundColor(0.0, 0.25, 0.35, 1.0);
      // 🔴 关后处理。相机背景已经用 inverseTonemapSRGB 抵消过一次色调映射,
      // 这一页不需要泛光/FXAA 之类再插一脚。
      await viewer.setPostProcessing(false);

      final ByteData bytes =
          await rootBundle.load('assets/materials/pw_camera_feed.filamat');
      final loop = await ArRenderLoop.create(
        viewer,
        materialBytes: bytes.buffer.asUint8List(),
        imageWidth: kFeedWidth,
        imageHeight: kFeedHeight,
      );

      final int rc = PwCameraSlot.start(width: kFeedWidth, height: kFeedHeight);
      if (rc != 0) {
        setState(() => _status = '相机启动失败,原生返回码 $rc');
        await loop.dispose();
        return;
      }
      _cameraStarted = true;

      // 🔴 自己驱动帧,并且**关掉 viewer 自己的渲染循环** —— 每帧必须先喂
      // 纹理再出图,顺序反了会拿上一帧的内容配这一帧的位姿。
      await viewer.setRendering(false);

      if (!mounted) {
        PwCameraSlot.stop();
        _cameraStarted = false;
        await loop.dispose();
        return;
      }
      setState(() {
        _loop = loop;
        _status = '运行中';
      });
      _ticker = createTicker(_tick)..start();
    } catch (e, st) {
      setState(() => _status = '建回路失败:$e\n$st');
    }
  }

  void _tick(Duration _) async {
    final loop = _loop;
    if (loop == null || !mounted) return;
    // 上一帧还没走完就跳过。不设这道闸的话,await 链会互相穿插,
    // 出现"这一帧的纹理配上一帧的投影"。
    if (_stepping) return;
    _stepping = true;
    try {
      final Size size = MediaQuery.of(context).size;
      final double dpr = MediaQuery.of(context).devicePixelRatio;
      final outcome = await loop.step(
        viewportWidth: (size.width * dpr).round(),
        viewportHeight: (size.height * dpr).round(),
        // 本页锁竖屏。接生产时这里要读真实的屏幕旋转
        // (iOS: UIInterfaceOrientation;安卓/鸿蒙: ScreenRotation.fromIndex)。
        displayRotation: ScreenRotation.degrees0,
      );
      final stats = PwCameraSlot.stats();
      if (mounted) {
        setState(() {
          _last = outcome;
          _stats = stats;
        });
      }
    } finally {
      _stepping = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF001018),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ViewerWidget(
              initial: const ColoredBox(color: Color(0xFF001018)),
              background: const Color(0xFF001018),
              manipulatorType: ManipulatorType.NONE,
              transformToUnitCube: false,
              postProcessing: false,
              destroyEngineOnUnload: true,
              onViewerAvailable: _onViewer,
            ),
          ),
          Positioned(
            left: 12,
            top: MediaQuery.of(context).padding.top + 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: DefaultTextStyle(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(_status),
                      if (_last != null) Text('$_last'),
                      if (_stats != null) Text('$_stats'),
                      if (_stats != null && _stats!.outstanding > 1)
                        const Text('🔴 缓冲泄漏:outstanding > 1',
                            style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
