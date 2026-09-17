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

class _ArMinimalLoopPageState extends State<ArMinimalLoopPage> {
  ArRenderLoop? _loop;
  Future Function()? _frameHook;
  Size _viewport = Size.zero;
  double _dpr = 1.0;
  bool _cameraStarted = false;
  String _status = '等待渲染器…';
  ArFrameOutcome? _last;
  CameraSlotStats? _stats;
  bool _stepping = false;
  int _ticks = 0;
  bool _capturedOnce = false;

  @override
  void dispose() {
    final hook = _frameHook;
    if (hook != null) {
      FilamentApp.instance?.unregisterRequestFrameHook(hook);
      _frameHook = null;
    }
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
      // 🔴 **不要**用 setBackgroundColor —— 在 thermion 0.3.4 里它会建一个
      // **天空盒**。而我们这个三角形按上游写法坐在**远平面**上
      // (`vertexDomain: device` + z=1,Filament 对 device 域做 z*-0.5+0.5,
      //  反向 Z 下落在远平面),天空盒也在远平面、且在不透明体之后画 ⇒
      // 它会盖掉我们的三角形。上游 hello-ar **没有天空盒**,这一行是我加的。
      //
      // 改用清屏色。颜色选品红,为的是三种失败长得不一样、一眼可分:
      //   品红 = 三角形根本没上屏(清屏色透出来)
      //   全黑 = 三角形画了,但采样到的是空纹理
      //   相机画面 = 成了
      await FilamentApp.instance!.setClearOptions(1.0, 0.0, 1.0, 1.0);
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

      // 🔴 **不要** `setRendering(false)`。
      //
      // 它的名字像是"关掉 viewer 自己的渲染循环",实际做的是
      //     _rendering = render;
      //     await view.setRenderable(render);   // ← 把 View 标成不可渲染
      // (thermion_viewer_ffi.dart:115-118)。View 一旦不可渲染,Filament
      // 渲染时整个跳过它:beginFrame 照跑、清屏色照画,而**场景里的东西
      // 一个都不画**。症状是屏幕永远停在清屏色,同时 FilamentApp.capture
      // 返回空列表 —— 而纹理/投影/UV 的计数全都正常,极具迷惑性。
      //
      // 本会话实测:就是这一行让最小回路一直显示清屏色。

      // 一次性诊断:三角形建出来没有、在不在场景里。
      // 「没显示」有很多种死法,这几行把前几种直接排掉。
      try {
        final e = loop.triangleEntity;
        debugPrint('[arloop] 材质字节 = ${bytes.lengthInBytes}');
        debugPrint('[arloop] 三角形 entity = $e');
        debugPrint('[arloop] isRenderable = '
            '${await FilamentApp.instance!.isRenderable(e)}');
        debugPrint('[arloop] primitiveCount = '
            '${await FilamentApp.instance!.getPrimitiveCount(e)}');
        debugPrint('[arloop] boundingBox = '
            '${await FilamentApp.instance!.getBoundingBox(e)}');
      } catch (e) {
        debugPrint('[arloop] 一次性诊断失败: $e');
      }

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

      // 🔴 挂成 viewer 的 per-frame hook,而不是自己起 Ticker。
      //
      // 对照件 `FilamentApp.cpp:52-70` 的结构是:**唯一一个渲染循环**,每帧
      // 依次「喂纹理 → 喂 UV → 设位姿 → 设投影 → beginFrame/render/endFrame」。
      // ViewerWidget 自带渲染循环,我们再起一个 Ticker 自己 render,就成了同
      // 一个 Renderer 上两对 beginFrame/endFrame 并发 —— 真机实测直接
      // SIGABRT(`Precondition in endFrame:410 / SwapChain must remain valid
      // until endFrame is called.`)。
      //
      // `FilamentApp.requestFrame()` 先**按序 await 所有 hook**、再请求渲染
      // (ffi_filament_app.dart:656-667),所以挂 hook 得到的正是上游那个
      // 「推完状态紧接着出图」的顺序,而循环仍然只有一个。
      final hook = _onFrame;
      _frameHook = hook;
      await FilamentApp.instance!.registerRequestFrameHook(hook);
    } catch (e, st) {
      setState(() => _status = '建回路失败:$e\n$st');
    }
  }

  /// 每帧渲染**之前**跑。由 FilamentApp.requestFrame 按序 await。
  Future<void> _onFrame() async {
    final loop = _loop;
    if (loop == null || !mounted) return;
    // requestFrame 是顺序 await 的,不会重入;这道闸只防万一。
    if (_stepping) return;
    _stepping = true;
    try {
      final Size size = _viewport;
      final double dpr = _dpr;
      if (size.width <= 0 || size.height <= 0) return;
      final outcome = await loop.step(
        viewportWidth: (size.width * dpr).round(),
        viewportHeight: (size.height * dpr).round(),
        // 本页锁竖屏。接生产时这里要读真实的屏幕旋转
        // (iOS: UIInterfaceOrientation;安卓/鸿蒙: ScreenRotation.fromIndex)。
        displayRotation: ScreenRotation.degrees0,
      );
      final stats = PwCameraSlot.stats();
      // 每约 60 帧打一次。屏幕上那块字太小,控制台才读得到。
      if (++_ticks % 60 == 0) {
        debugPrint('[arloop] ${outcome.toDiagnosticString()}');
        debugPrint('[arloop] $stats');
        debugPrint('[arloop] viewport = '
            '${(size.width * dpr).round()}x${(size.height * dpr).round()}');
      }
      // 一次性取像:把"屏幕上到底是什么颜色"变成机器判据,不用人去看。
      // 三态可分:近品红 = 三角形没上屏;近黑 = 上屏了但纹理是空的;
      // 方差大 = 真的是相机画面。
      if (!_capturedOnce && _ticks > 90) {
        _capturedOnce = true;
        await _dumpFramebuffer();
      }

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

  /// 取一帧渲染结果,统计像素。判据见调用处。
  Future<void> _dumpFramebuffer() async {
    try {
      final shots = await FilamentApp.instance!.capture(null);
      if (shots.isEmpty) {
        debugPrint('[arloop] capture 返回空');
        return;
      }
      final (_, Uint8List bytes) = shots.first;
      final Float32List px = bytes.buffer.asFloat32List();
      final int n = px.length ~/ 4;
      debugPrint('[arloop] capture: ${bytes.lengthInBytes} 字节 = $n 像素');
      if (n == 0) return;

      // 均值 / 极值 / 方差 —— 均匀色的方差≈0,相机画面不可能。
      double sr = 0, sg = 0, sb = 0, s2 = 0;
      double lo = 1e9, hi = -1e9;
      for (int i = 0; i < n; i++) {
        final double r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
        sr += r; sg += g; sb += b;
        final double l = (r + g + b) / 3.0;
        s2 += l * l;
        if (l < lo) lo = l;
        if (l > hi) hi = l;
      }
      final double mr = sr / n, mg = sg / n, mb = sb / n;
      final double ml = (mr + mg + mb) / 3.0;
      final double varL = (s2 / n) - ml * ml;
      debugPrint('[arloop] 均值 RGB = '
          '(${mr.toStringAsFixed(3)}, ${mg.toStringAsFixed(3)}, '
          '${mb.toStringAsFixed(3)})');
      debugPrint('[arloop] 亮度 min=${lo.toStringAsFixed(3)} '
          'max=${hi.toStringAsFixed(3)} 方差=${varL.toStringAsFixed(5)}');
      String verdict;
      if (varL < 1e-6 && mr > 0.5 && mg < 0.2 && mb > 0.5) {
        verdict = '🔴 近品红且均匀 ⇒ 三角形没上屏(清屏色透出来)';
      } else if (varL < 1e-6 && ml < 0.05) {
        verdict = '🔴 近黑且均匀 ⇒ 三角形上屏了,但采样到空纹理';
      } else if (varL > 1e-4) {
        verdict = '✅ 方差大 ⇒ 屏上有真实图像内容';
      } else {
        verdict = '❓ 均匀但不是品红也不是黑';
      }
      debugPrint('[arloop] 判据: $verdict');
    } catch (e, st) {
      debugPrint('[arloop] capture 失败: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    // hook 在渲染线程节奏上跑,拿不到 BuildContext,所以在这里存一份。
    _viewport = MediaQuery.of(context).size;
    _dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: const Color(0xFF001018),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ViewerWidget(
              initial: const ColoredBox(color: Color(0xFF001018)),
              // 🔴 **不传 background**。
              //
              // ViewerWidget 拿这个参数去调 viewer.setBackgroundColor
              // (viewer_widget.dart:184-186),而它在 0.3.4 里**建的是天空盒**。
              // 天空盒和这个全屏三角形都坐在**远平面**上,且天空盒在不透明体
              // 之后画 ⇒ 把三角形整个盖掉。
              //
              // 对照件 FilamentApp.cpp 的 setupFilament/setupView **没有建
              // 任何天空盒**,清屏色由 Renderer 给。照它来。
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
