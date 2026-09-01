// auto_rotating_cloud_view.dart — 会自己转的点云查看器。
//
// [2026-08-17 用户拍板] "我就看现在社区里的 ply 在 3d viewer 里能不能自转!
// 就完成这一个功能!" —— 打开一个作品,它就该在那儿慢慢转,像 Sketchfab /
// Polycam 的展示位那样。
//
// 这是 SparseCloudView 的**外壳**,不是它的分叉:内部一行都没改。做法和 feed
// live 卡同源 —— CloudViewController.moveTo 投递的目标是直接置位(见
// sparse_cloud_view.dart:569,缓动只服务 reframe / 双击对焦 / 退出编辑),所以
// 每帧 moveTo(yaw + Δ) 就是硬置位自转。草稿页与采集期预览零影响。
//
// 一碰就停,不恢复。用户伸手去转,说明他想看某个角度;两秒后又被拽走是
// 最气人的交互。model-viewer / Sketchfab 都是这个规矩。
//
// 热闸沿用 CardLiveGovernor:不调它的滚动方法时,它的 liveAllowed 就只由
// thermalState(serious 停,回 nominal 才恢复)、内存告警、前后台三件事决定
// —— 正好是一个全屏 viewer 需要的全部。转速与帧率同 feed 卡(24fps 封顶、
// 15 秒一圈),两处观感一致。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../official_util/device_log.dart';
import '../community/card_live_governor.dart';
import 'sparse_cloud_view.dart';

class AutoRotatingCloudView extends StatefulWidget {
  const AutoRotatingCloudView({
    super.key,
    required this.xyz,
    required this.rgb,
    this.showControls = true,
    this.logTag = 'viewer',
  });

  final Float32List xyz;
  final Uint8List rgb;
  final bool showControls;

  /// 进日志用的名字,便于分辨是社区详情还是自己的作品。
  final String logTag;

  @override
  State<AutoRotatingCloudView> createState() => _AutoRotatingCloudViewState();
}

class _AutoRotatingCloudViewState extends State<AutoRotatingCloudView>
    with SingleTickerProviderStateMixin {
  final CloudViewController _controller = CloudViewController();
  late final CardLiveGovernor _governor;
  Ticker? _ticker;

  /// SparseCloudView 自己算的默认取景(fit + 斜上 45°),第一帧后报上来。
  /// 只吃第一次:之后 yaw 由这里推进,其余分量原样沿用,不必重算 fit/pivot。
  CloudViewCamera? _base;
  double _yaw = 0;
  Duration _lastStep = Duration.zero;

  /// 用户已经上手了 —— 自转永久让位。
  bool _userTookOver = false;

  int _frames = 0;
  Duration _fpsWindowStart = Duration.zero;

  @override
  void initState() {
    super.initState();
    _governor = CardLiveGovernor()..addListener(_onGovernorChanged);
    _ticker = createTicker(_onTick)..start();
    DeviceLog.log(
      'AutoRotate',
      '${widget.logTag}:viewer 挂载,${widget.xyz.length ~/ 3} 点,'
          '起转 ${_governor.fpsCap}fps(15 秒一圈)',
    );
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _governor.removeListener(_onGovernorChanged);
    _governor.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onGovernorChanged() {
    if (!mounted) return;
    if (!_governor.liveAllowed && !_userTookOver) {
      DeviceLog.log(
        'AutoRotate',
        '${widget.logTag}:自转暂停(thermal=${_governor.thermalState})',
      );
    }
  }

  void _onTick(Duration elapsed) {
    if (_userTookOver) return;
    if (!_governor.liveAllowed) return; // 热 / 内存 / 后台
    final base = _base;
    if (base == null) return; // 还没收到首帧相机
    final dt = elapsed - _lastStep;
    final interval = Duration(microseconds: 1000000 ~/ _governor.fpsCap);
    if (dt < interval) return;
    _lastStep = elapsed;
    // 按真实经过时间推进 —— 24fps 与 15fps 下角速度一致,降级只是步进变粗。
    _yaw += kCardRotateRadPerSec * (dt.inMicroseconds / 1000000.0);
    _controller.moveTo((
      yaw: _yaw,
      pitch: base.pitch,
      roll: base.roll,
      zoom: base.zoom,
      panX: base.panX,
      panY: base.panY,
      pivotX: base.pivotX,
      pivotY: base.pivotY,
      pivotZ: base.pivotZ,
    ));
    _countFrame(elapsed);
  }

  /// 每 5 秒报一次实测帧率 —— "看着像没转"和"真的没转"必须能分开。
  void _countFrame(Duration elapsed) {
    _frames++;
    final window = elapsed - _fpsWindowStart;
    if (window < const Duration(seconds: 5)) return;
    final fps = _frames / (window.inMilliseconds / 1000.0);
    DeviceLog.log(
      'AutoRotate',
      '${widget.logTag}:实测 fps=${fps.toStringAsFixed(1)} '
          '(封顶 ${_governor.fpsCap}) thermal=${_governor.thermalState}',
    );
    _frames = 0;
    _fpsWindowStart = elapsed;
  }

  void _takeOver() {
    if (_userTookOver) return;
    setState(() => _userTookOver = true);
    _ticker?.stop();
    DeviceLog.log('AutoRotate', '${widget.logTag}:用户上手 → 自转让位(不恢复)');
  }

  @override
  Widget build(BuildContext context) {
    // Listener 而不是 GestureDetector:手势竞技场里 SparseCloudView 自己的
    // orbit/pinch 识别器是赢家,包一层 GestureDetector 会跟它抢。Listener 只
    // 旁听指针事件、不参与竞技,所以"知道用户上手了"和"照常让他转"能共存。
    return Listener(
      onPointerDown: (_) => _takeOver(),
      child: SparseCloudView(
        xyz: widget.xyz,
        rgb: widget.rgb,
        showControls: widget.showControls,
        controller: _controller,
        onCameraChanged: (c) {
          // 每帧 moveTo 都会回调到这里,所以绝不能 setState —— SparseCloudView
          // 头上就是这么写的。只吃第一次拿默认取景。
          if (_base != null) return;
          _base = c;
          _yaw = c.yaw;
        },
      ),
    );
  }
}
