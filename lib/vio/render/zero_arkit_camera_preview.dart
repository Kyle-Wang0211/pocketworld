// zero_arkit_camera_preview.dart — 开关 ON 时采集页的预览:我们自己的相机流
// 经 Filament 画成背景,替掉 ARKit 的 `UiKitView`。
//
// ══ 这是复刻,不是新页面 ═════════════════════════════════════════════════
// 逐段抄 `ar_minimal_loop_page.dart`(09-18 真机跑通:capture 方差 0.045;
// 09-19 接上位姿)。那一页是「相机帧经我们自己算的 UV + 投影在 Filament 里
// 显示出来」的唯一已验路径。本文件把它拆成一个能塞进任何布局的 widget,
// **去掉**了不属于渲染的三件事:
//   * 不起相机、不建会话 —— 归 `ZeroArkitCaptureRuntime`
//     (由 `VioArPoseProvider.start()` 在 `CaptureSession.attach()` 里起);
//   * 不起 IMU、不做静止兜底 —— 采集页的 IMU 已被 `OrientationTracker` 占着
//     (vio_ar_pose_provider.dart 的 tick() 注释);
//   * 不建 B3 方向自检的三个球 —— 那是探针,不是产品画面。
// 剩下的就是:ViewerWidget + ArRenderLoop + 每帧 hook。
//
// ══ 🔴 不开摄像头 ═════════════════════════════════════════════════════════
// 本 widget 只从 `PwCameraSlot` 的深度 1 槽里**取**最新帧。相机的开与关由
// 运行时负责;本 widget 被挂上时相机已经在跑(或者起失败了 —— 那时槽里
// 永远没有帧,`hadFrame` 恒 false,画面保持黑,**不假装有预览**)。
// 渲染侧是槽的唯一 Dart 消费者:引擎那一路在原生相机回调里直喂
// (`PwCameraSlot.captureOutput` → `PwXrslamLive.onCameraFrame`),不经过槽。
//
// ══ 与 ARKit 那块 UiKitView 的对应关系 ═══════════════════════════════════
// 布局一字不改:仍在 `CapturePreviewRect`(满宽 3:4)里。相机采 1920×1440,
// 转 90° 之后是 1440×1920 = 3:4,**与预览框同比** ⇒ aspect-fill 的裁剪是
// 恒等,内参不被裁(`test/zero_arkit_camera_preview_test.dart` 钉住)。
// ARKit 那条路的所见即所得(WYSIWYG 2026-07-19)在这条路上靠这一点成立。
//
// ══ 🔴 三处与台架页的刻意差别,都有理由 ═══════════════════════════════════
// 1. 清屏色黑,不是品红。台架用品红是为了「三角形没上屏 / 纹理空 / 真图像」
//    三态肉眼可分;产品页面不能给用户看品红。三态判别改由**机器判据**承担:
//    第 [kZeroArkitPreviewCaptureAtTick] 帧一次性 `capture` 统计方差(抄台架页
//    `_dumpFramebuffer`)+ 建回路时打一次 entity/primitiveCount/boundingBox。
// 2. `destroyEngineOnUnload: false`。采集页会压在持有 ViewerWidget 的页面
//    (社区页 `live_model_view`)之上;台架页那个 `true` 会把别人的引擎一起
//    销毁。与 `live_model_view.dart` 同款。
// 3. 上面盖一层黑 cover,直到第一帧 `hadFrame`。`ViewerWidget` 不把 `initial`
//    往下传,内层在纹理分配前画的是**红色**(`live_model_view.dart` 文件头
//    第 (1) 条,同一个修法)。
//
// ══ 🔴 生命周期:GPU 资源谁销毁 ══════════════════════════════════════════
// `viewer.dispose()`(ViewerWidget 拆卸时调)会 `destroyAssets()` —— 把经
// `viewer.createGeometry` 建的三角形**一起销毁**。若我们之后再
// `destroyAsset` 一次,就是 `live_model_view.dart` 记的那个双重释放
// EXC_BAD_ACCESS。而 Flutter 拆树是**子先父后**,ViewerWidget 一定先于本
// widget 的 dispose 拆掉 ⇒ 不能在 dispose 里拆回路。
// 正解是 thermion 自己留的接缝 `viewer.onDispose(callback)`
// (thermion_viewer_base.dart:299):回调在 `viewer.dispose()` **内部**、
// `destroyAssets()` 之后、`destroyScene/View` 之前跑。我们在那里:
// 停 hook → 等在途的 step 收尾 → 只销毁纹理/采样器/材质(不碰 asset)。
// ⚠️ 台架页 `ArMinimalLoopPage` 走的仍是 `loop.dispose()`,它是根页面从不
//    被 pop,所以那条双重释放从没被踩到;本文件不改它。
//
// ══ 位姿 ══════════════════════════════════════════════════════════════════
// [ZeroArkitCameraPreview.poseReader] 交**引擎系**的 `TrackedPose`
// (`VioArPoseProvider.lastTrackedPose`),`WorldToRenderer` 自己做
// z-up → y-up。本刀场景里没有虚拟内容,位姿只影响相机矩阵、不影响背景;
// 接上它是为了日志里 `pose=true` 这一位有据可查。
// ⚠️ 与 `xrslam_world_axis.dart`(ARPose 那条,给 dome/落盘用)差一个绕竖轴
//    的偏航 —— 两者都 y-up,偏航在 VIO 里不可观(world_to_renderer.dart
//    文件头)。画虚拟内容之前必须把两条统一成一条;本刀不画,所以不在这里定。
//
// ══ 屏幕旋转 ══════════════════════════════════════════════════════════════
// 默认 `ScreenRotation.degrees0`(竖屏)。`CapturePreviewRect` 本身就是按
// 竖屏满宽算 3:4 的,整个采集页没有横屏布局 ⇒ 与它同口径。真要横屏时
// 两处一起改;台架页那句「接生产时要读真实屏幕旋转」指的就是这里。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;

import '../pose/camera_slot_ffi.dart';
import '../pose/display_transform.dart';
import '../pose/tracked_pose.dart';
import 'ar_render_loop.dart';

/// 材质资产路径。与台架页同一个文件(pubspec `assets/materials/`)。
const String kZeroArkitCameraFeedMaterial =
    'assets/materials/pw_camera_feed.filamat';

/// 一次性 `capture` 统计在第几帧之后做。抄台架页的 90。
const int kZeroArkitPreviewCaptureAtTick = 90;

/// 每隔多少帧打一行诊断。抄台架页的 60。
const int kZeroArkitPreviewLogEveryTicks = 60;

/// 日志前缀。grep 这个词就能把预览这条路的现场证据全拉出来。
const String kZeroArkitPreviewLogTag = '[zero-arkit-preview]';

/// 引擎系位姿的读法。`null` = 还没有位姿(引擎初始化中)。
typedef ZeroArkitPoseReader = TrackedPose? Function();

/// 零 ARKit 臂的相机预览。
class ZeroArkitCameraPreview extends StatefulWidget {
  const ZeroArkitCameraPreview({
    super.key,
    required this.imageWidth,
    required this.imageHeight,
    this.poseReader,
    this.displayRotation = ScreenRotation.degrees0,
    this.coverColor = const Color(0xFF000000),
  });

  /// 相机交付帧的尺寸,**传感器方向**。必须与
  /// `ZeroArkitCaptureRuntime.captureWidth/Height` 同一个数 —— 它既是
  /// external 纹理的记账尺寸,也是 UV 变换与投影的输入。
  final int imageWidth;
  final int imageHeight;

  /// 引擎系位姿。见文件头「位姿」。
  final ZeroArkitPoseReader? poseReader;

  /// 见文件头「屏幕旋转」。
  final ScreenRotation displayRotation;

  /// 第一帧到来之前盖在上面的颜色。默认黑,与旧的黑屏占位同色 ——
  /// 从「恒黑」到「黑直到第一帧」,用户看到的差别只有画面出现那一刻。
  final Color coverColor;

  @override
  State<ZeroArkitCameraPreview> createState() =>
      _ZeroArkitCameraPreviewState();
}

class _ZeroArkitCameraPreviewState extends State<ZeroArkitCameraPreview> {
  ArRenderLoop? _loop;
  Future Function()? _frameHook;

  /// hook 在渲染节奏上跑,拿不到 BuildContext,所以在 build 里存一份。
  Size _size = Size.zero;
  double _dpr = 1.0;

  bool _stepping = false;
  bool _tornDown = false;
  bool _hadFrameOnce = false;
  bool _capturedOnce = false;
  int _ticks = 0;

  @override
  void dispose() {
    // 只做两件不碰 GPU 的事:标记 + 摘 hook。GPU 资源在 viewer.onDispose 里拆
    // (见文件头「生命周期」)。ViewerWidget 若从未建出 viewer
    // (onViewerAvailable 没触发),也就没有任何 GPU 资源要拆。
    _tornDown = true;
    final Future Function()? hook = _frameHook;
    _frameHook = null;
    if (hook != null) unawaited(_unregister(hook));
    super.dispose();
  }

  Future<void> _unregister(Future Function() hook) async {
    try {
      await FilamentApp.instance?.unregisterRequestFrameHook(hook);
    } catch (e) {
      debugPrint('$kZeroArkitPreviewLogTag 摘 hook 失败(引擎可能已销毁):$e');
    }
  }

  Future<void> _onViewer(ThermionViewer viewer) async {
    try {
      // 🔴 **不要**用 setBackgroundColor —— 在 thermion 0.3.4 里它会建一个
      // **天空盒**,而三角形按上游写法坐在远平面上,会被天空盒盖掉
      // (台架页 _onViewer 的说明)。改用清屏色,黑;理由见文件头第 1 条。
      await FilamentApp.instance!.setClearOptions(0.0, 0.0, 0.0, 1.0);
      // 🔴 后处理必须开着:材质里的 inverseTonemapSRGB 是配着后处理阶段的
      // tonemapper 一起工作的,关掉后处理只剩「反向」那一半,画面整体偏暗
      // (台架页 2026-09-19 修正)。构造里传 false、这里显式开,与台架页同序。
      await viewer.setPostProcessing(true);

      final ByteData bytes = await rootBundle.load(kZeroArkitCameraFeedMaterial);
      final ArRenderLoop loop = await ArRenderLoop.create(
        viewer,
        materialBytes: bytes.buffer.asUint8List(),
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
      );

      // 一次性诊断:三角形建出来没有、在不在场景里。「没显示」有很多种死法,
      // 这几行把前几种直接排掉(台架页同款)。
      try {
        final ThermionEntity e = loop.triangleEntity;
        final FilamentApp app = FilamentApp.instance!;
        debugPrint('$kZeroArkitPreviewLogTag 材质字节=${bytes.lengthInBytes} '
            'entity=$e isRenderable=${await app.isRenderable(e)} '
            'primitiveCount=${await app.getPrimitiveCount(e)} '
            'boundingBox=${await app.getBoundingBox(e)} '
            '图像=${widget.imageWidth}x${widget.imageHeight}');
      } catch (e) {
        debugPrint('$kZeroArkitPreviewLogTag 一次性诊断失败: $e');
      }

      if (!mounted || _tornDown) {
        // 建到一半页面已经没了:viewer 可能已经(或正在)dispose,asset 归它;
        // 我们只还自己那几样。
        await loop.disposeForViewerTeardown();
        return;
      }

      // 🔴 GPU 资源的销毁挂在 viewer 自己的拆卸序列里,见文件头「生命周期」。
      viewer.onDispose(() => _teardownGpu(loop));

      setState(() => _loop = loop);

      // 🔴 挂成 viewer 的 per-frame hook,而不是自己起 Ticker:同一个 Renderer
      // 上两对 beginFrame/endFrame 并发在真机上直接 SIGABRT(台架页实测)。
      // `FilamentApp.requestFrame()` 先按序 await 所有 hook 再请求渲染,
      // 正是上游 hello-ar `FilamentApp.cpp:52-70` 那个「推完状态紧接着出图」
      // 的顺序。
      final Future Function() hook = _onFrame;
      _frameHook = hook;
      await FilamentApp.instance!.registerRequestFrameHook(hook);
    } catch (e, st) {
      debugPrint('$kZeroArkitPreviewLogTag 建回路失败:$e\n$st');
    }
  }

  /// 在 `viewer.dispose()` 内部被调(destroyAssets 之后)。
  ///
  /// 🔴 开头结尾各打一行:「拆没拆、拆完没崩」要在日志里**直接可读**,而不是
  ///    靠 ArFrame 行的间隔去推(09-22 三个抓日志窗口都靠推,读起来太绕)。
  Future<void> _teardownGpu(ArRenderLoop loop) async {
    _tornDown = true;
    debugPrint('$kZeroArkitPreviewLogTag 拆卸开始:viewer.onDispose 已到,'
        'ticks=$_ticks stepping=$_stepping');
    final Future Function()? hook = _frameHook;
    _frameHook = null;
    if (hook != null) await _unregister(hook);
    // 等在途的 step 收尾:它可能正 await 一个渲染线程往返。上限 1 s,
    // 到点就不等了 —— 拆卸不能被一个卡死的帧永远拖住。
    int spins = 0;
    while (_stepping && spins++ < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (_stepping) {
      debugPrint('$kZeroArkitPreviewLogTag 在途 step 1 s 未收尾,强行拆');
    }
    await loop.disposeForViewerTeardown();
    debugPrint('$kZeroArkitPreviewLogTag 拆卸完成:纹理/采样器/材质已还,'
        'asset 归 viewer(等了 ${spins * 5} ms)');
  }

  /// 每帧渲染**之前**跑。由 FilamentApp.requestFrame 按序 await。
  Future<void> _onFrame() async {
    final ArRenderLoop? loop = _loop;
    if (loop == null || _tornDown || !mounted) return;
    // requestFrame 是顺序 await 的,不会重入;这道闸只防万一。
    if (_stepping) return;
    _stepping = true;
    try {
      final Size size = _size;
      final double dpr = _dpr;
      if (size.width <= 0 || size.height <= 0) return;

      final ArFrameOutcome outcome = await loop.step(
        viewportWidth: (size.width * dpr).round(),
        viewportHeight: (size.height * dpr).round(),
        displayRotation: widget.displayRotation,
        pose: widget.poseReader?.call(),
      );
      _ticks++;

      if (outcome.hadFrame && !_hadFrameOnce && mounted) {
        setState(() => _hadFrameOnce = true);
      }

      if (_ticks % kZeroArkitPreviewLogEveryTicks == 0) {
        debugPrint('$kZeroArkitPreviewLogTag ${outcome.toDiagnosticString()}');
        // 槽的账:outstanding 恒为 0 或 1(>1 就是漏);displaced 是深度 1
        // 的正常代价,不是丢帧(台架页文件头的判读)。
        String slot;
        try {
          slot = '${PwCameraSlot.stats()}';
        } catch (e) {
          slot = '(槽统计不可读:$e)';
        }
        debugPrint('$kZeroArkitPreviewLogTag $slot viewport='
            '${(size.width * dpr).round()}x${(size.height * dpr).round()} '
            'cover=${_hadFrameOnce ? "已撤" : "在"}');
      }

      // 一次性取像:把「屏幕上到底是什么颜色」变成机器判据,不用人去看。
      if (!_capturedOnce && _ticks > kZeroArkitPreviewCaptureAtTick) {
        _capturedOnce = true;
        await _dumpFramebuffer();
      }
    } finally {
      _stepping = false;
    }
  }

  /// 取一帧渲染结果,统计像素。逐字抄台架页 `_dumpFramebuffer`,只改前缀与
  /// 「近品红」那一态(本页清屏色是黑,所以「近黑且均匀」同时覆盖
  /// 「三角形没上屏」与「纹理空」两种死法 —— 分不开时看上面那行一次性诊断)。
  Future<void> _dumpFramebuffer() async {
    try {
      // 🔴 不写 `View` 这个类型名:Flutter 的 material.dart 与 thermion 都导出
      //    同名类型,写出来就是 ambiguous import(ar_render_loop 里 `Material`
      //    同一个坑)。抄台架页,用推断。
      final shots = await FilamentApp.instance!.capture(null);
      if (shots.isEmpty) {
        debugPrint('$kZeroArkitPreviewLogTag capture 返回空');
        return;
      }
      final (_, Uint8List bytes) = shots.first;
      final Float32List px = bytes.buffer.asFloat32List();
      final int n = px.length ~/ 4;
      debugPrint('$kZeroArkitPreviewLogTag capture: ${bytes.lengthInBytes} '
          '字节 = $n 像素');
      if (n == 0) return;

      double sr = 0, sg = 0, sb = 0, s2 = 0;
      double lo = 1e9, hi = -1e9;
      for (int i = 0; i < n; i++) {
        final double r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
        sr += r;
        sg += g;
        sb += b;
        final double l = (r + g + b) / 3.0;
        s2 += l * l;
        if (l < lo) lo = l;
        if (l > hi) hi = l;
      }
      final double mr = sr / n, mg = sg / n, mb = sb / n;
      final double ml = (mr + mg + mb) / 3.0;
      final double varL = (s2 / n) - ml * ml;
      debugPrint('$kZeroArkitPreviewLogTag 均值 RGB = '
          '(${mr.toStringAsFixed(3)}, ${mg.toStringAsFixed(3)}, '
          '${mb.toStringAsFixed(3)}) 亮度 min=${lo.toStringAsFixed(3)} '
          'max=${hi.toStringAsFixed(3)} 方差=${varL.toStringAsFixed(5)}');
      final String verdict;
      if (varL < 1e-6 && ml < 0.05) {
        verdict = '🔴 近黑且均匀 ⇒ 三角形没上屏,或上屏了但采样到空纹理'
            '(看一次性诊断那行分)';
      } else if (varL > 1e-4) {
        verdict = '✅ 方差大 ⇒ 屏上有真实图像内容';
      } else {
        verdict = '❓ 均匀但不是黑';
      }
      debugPrint('$kZeroArkitPreviewLogTag 判据: $verdict');
    } catch (e, st) {
      debugPrint('$kZeroArkitPreviewLogTag capture 失败: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 视口 = 本 widget 拿到的那块(CapturePreviewRect 给的 3:4),
        // 不是整屏 —— 台架页用的是整屏,那是它自己就是整屏。
        _size = (constraints.maxWidth.isFinite && constraints.maxHeight.isFinite)
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : Size.zero;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ViewerWidget(
              initial: ColoredBox(color: widget.coverColor),
              // 🔴 **不传 background**:它会建天空盒盖掉三角形(台架页说明)。
              manipulatorType: ManipulatorType.NONE,
              transformToUnitCube: false,
              // 台架页同序:构造传 false,_onViewer 里显式 setPostProcessing(true)。
              postProcessing: false,
              // 见文件头第 2 条:别人的引擎不能跟着本页一起销毁。
              destroyEngineOnUnload: false,
              onViewerAvailable: _onViewer,
            ),
            // 见文件头第 3 条:盖住内层纹理分配前的红色,直到第一帧。
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hadFrameOnce ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: ColoredBox(color: widget.coverColor),
              ),
            ),
          ],
        );
      },
    );
  }
}
