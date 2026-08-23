// live_card_cloud.dart — 社区 feed 焦点卡的真实时点云自转层。
//
// [2026-08-16 用户拍板] "直接做真实时渲染" —— feed 里**最居中的那一张**卡真
// 渲点云并自转,其余卡片保持静态缩略图。此前 08-07 签决的"在列表里铺实时点云
// 是往火上加油"管的是**一屏 4-6 张**同时渲,不是一张;把前者当后者砍掉是过度
// 解释(旧 PostCard 的自转本来就只开焦点那一张)。
//
// ── 复用现役渲染器,零侵入 ──────────────────────────────────────────
//
// 渲染走 SparseCloudView —— 采集期预览 + 草稿"查看点云" + 社区详情页都是它。
// **本文件没有改它一行**:CloudViewController.moveTo 是公开的一次性目标投递,
// 而 _onControllerTarget 对 moveTo 的目标是**直接 setState 置位**(缓动只服务
// reframe / 双击对焦 / 退出编辑三条路,见 sparse_cloud_view.dart:569)。所以
// "每帧 moveTo(yaw + Δ)" 就是硬置位自转,不会每帧重启一次缓动动画。
// 草稿页与采集期预览零影响,那份文件头上"行为不能在两个界面间漂移"的约束
// 自动满足。
//
// ── 闸 2:八叉树 LOD 降点 ────────────────────────────────────────────
//
// 卡片只有 ~350pt 见方,渲全量 10 万点是把详情页的预算花在一张缩略图大小的
// 面上。ProgressiveOctreeOrder 的任意前缀都是空间均布的稳定子集(Potree 式
// 可见性遍历),取前 kCardPointBudget 个就是一次"看不出来的"降点。
//
// ⚠️ 这是 **display-only**,与"点云全量交付"不冲突:PLY / 持久化点序 / 导出
// 路径全不经过这里,详情页(WorkDetailPage)照旧渲全量。降点只发生在 feed
// 卡片这一个渲染面上,和 progressive_octree_order.dart 头注释里
// "Capture may choose a display-only prefix" 是同一类用法。
//
// 闸 1(单 live 卡)/ 闸 5(滚动中不转)/ 闸 6(离焦即回落)由 VaultPage 决定
// ——本 widget 被 mount 就转,被卸载就没了,不做"隐藏但还活着"的状态。
// 闸 3/4/7 在 CardLiveGovernor。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../../community/glb_cache.dart';
import '../../point_cloud_display/progressive_octree_order.dart';
import '../../util/device_log.dart';
import '../official_capture/sparse_cloud_view.dart';
import '../official_capture/sparse_cloud_viewer_page.dart' show loadSparsePly;
import 'card_live_governor.dart';

/// 闸 2:一张 feed 卡最多渲这么多点。
///
/// [2026-08-16 用户指定 "2–3 万"] 卡片 ~350pt 见方,再多的点落在同一个像素上
/// 只是白烧 CPU:SparseCloudPainter 每帧对可见点做一次投影 + 一次画家算法深度
/// 排序(O(n log n)),点数是每帧成本的直接因子。
const int kCardPointBudget = 25000;

/// 降点后的卡片点云。[sourcePointCount] 留着是为了让日志能说清降了多少 ——
/// 真机验收要能分辨"热是渲染压的"还是"点根本没降下来"。
class CardCloud {
  const CardCloud({
    required this.xyz,
    required this.rgb,
    required this.pointCount,
    required this.sourcePointCount,
  });

  final Float32List xyz;
  final Uint8List rgb;
  final int pointCount;
  final int sourcePointCount;
}

/// compute 入口(顶层函数)—— 解析 PLY + 八叉树降点全在 isolate 里做完,
/// 主 isolate 只收降点后的小数组。
///
/// 全量 10 万点是 1.2 MB xyz + 0.3 MB rgb;降到 2.5 万后是 300 KB + 75 KB。
/// 在 isolate 里裁完再回传,主 isolate 上就**从来没有**出现过全量副本 ——
/// 闸 7(内存告警即释放)要守的是这个量级。
CardCloud? loadCardCloud((String, int) req) {
  final (path, budget) = req;
  final full = loadSparsePly(path);
  if (full == null) return null;
  final n = full.xyz.length ~/ 3;
  if (n == 0) return null;
  if (n <= budget) {
    return CardCloud(
      xyz: full.xyz,
      rgb: full.rgb,
      pointCount: n,
      sourcePointCount: n,
    );
  }
  final order = ProgressiveOctreeOrder.build(full.xyz);
  final xyz = Float32List(budget * 3);
  final rgb = Uint8List(budget * 3);
  for (var k = 0; k < budget; k++) {
    final s = order[k] * 3;
    final o = k * 3;
    xyz[o] = full.xyz[s];
    xyz[o + 1] = full.xyz[s + 1];
    xyz[o + 2] = full.xyz[s + 2];
    rgb[o] = full.rgb[s];
    rgb[o + 1] = full.rgb[s + 1];
    rgb[o + 2] = full.rgb[s + 2];
  }
  return CardCloud(
    xyz: xyz,
    rgb: rgb,
    pointCount: budget,
    sourcePointCount: n,
  );
}

/// 焦点卡的 live 层。叠在静态缩略图**之上**:点云没下下来之前卡片就是原来的
/// 缩略图,下好了淡入 —— 起始姿态与缩略图同为斜上 45°(kSparseThumbYaw /
/// Pitch,SparseCloudView 的浏览态默认),所以淡入时几何是连续的,不会跳。
///
/// 加载失败(网络断 / 旧 GLB 作品 / PLY 解析不了)一律静默:下面就是缩略图,
/// 用户看到的仍是一张正常的卡。live 是增强,不是必需品。
class LiveCardCloud extends StatefulWidget {
  const LiveCardCloud({
    super.key,
    required this.work,
    required this.service,
    required this.fpsCap,
  });

  final FeedWork work;
  final CommunityService service;

  /// 闸 3/4 —— 由 CardLiveGovernor 给,thermal 变化时会变。
  final int fpsCap;

  @override
  State<LiveCardCloud> createState() => _LiveCardCloudState();
}

class _LiveCardCloudState extends State<LiveCardCloud>
    with SingleTickerProviderStateMixin {
  final CloudViewController _controller = CloudViewController();

  CardCloud? _cloud;
  Ticker? _ticker;

  /// SparseCloudView 自己算出来的默认取景(fit + 斜上 45°)。它在第一帧后经
  /// onCameraChanged 报上来,我们只吃第一次 —— 之后 yaw 由这里推进,其余分量
  /// 原样沿用,所以不必在这边重算一遍 fit/pivot。
  CloudViewCamera? _base;
  double _yaw = 0;
  Duration _lastStep = Duration.zero;

  /// 实测帧率窗口 —— 验收要"实际帧率",不是"我们设的上限"。闸 3 是否真的
  /// 生效、闸 4 降到 15fps 后是否真降下来了,只有实测数能回答。
  int _frames = 0;
  Duration _fpsWindowStart = Duration.zero;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // 闸 6/7:卸载即真停 —— ticker 停掉,点云引用断开,等 GC。
    _ticker?.dispose();
    _ticker = null;
    _controller.dispose();
    super.dispose();
  }

  /// 已经报告过"不能 live"的作品 —— 用户滚来滚去会让同一张卡反复成为焦点,
  /// 没有这个去重,一个 GLB 种子作品能把日志刷满。
  static final Set<String> _reportedIneligible = <String>{};

  /// 这张卡为什么没起转 —— **必须留痕**。
  ///
  /// [2026-08-17 实机踩到] 首轮实机"看不到自转",日志里焦点切换和闸门放行
  /// 全都正常,却一条 LiveCardCloud 的记录都没有,只能反查数据库才定位到
  /// "feed 里 5 个作品全是 format=glb 的老种子"。**静默 return 让一个非
  /// 故障状态看起来和故障一模一样。**
  void _reportIneligible(String why) {
    if (!_reportedIneligible.add(widget.work.id)) return;
    DeviceLog.log(
      'FeedLive',
      '不 live(卡片留静态缩略图):${widget.work.id} — $why',
    );
  }

  Future<void> _load() async {
    final storagePath = widget.work.modelStoragePath;
    if (storagePath == null || storagePath.isEmpty) {
      _reportIneligible('没有 model_storage_path');
      return;
    }
    // 旧 GLB 行(2026-05 前的种子数据)解析不了 —— 留在缩略图上。
    final format = widget.work.format.toLowerCase();
    if (format != 'ply') {
      _reportIneligible('format=$format,不是 ply(只有官方采集发布的稀疏点云能 live)');
      return;
    }
    try {
      final url = widget.service.modelUrlFor(storagePath);
      final localPath = await GlbCache.instance.fetchPath(url);
      if (!mounted) return;
      final cloud = await compute(
        loadCardCloud,
        (localPath, kCardPointBudget),
      );
      if (!mounted || cloud == null) return;
      DeviceLog.log(
        'FeedLive',
        '闸 2 降点:${widget.work.id} '
            '${cloud.sourcePointCount} → ${cloud.pointCount} 点 · 起转',
      );
      setState(() => _cloud = cloud);
      // createTicker(不是裸 Ticker)—— 挂到 TickerProvider 后会跟随
      // TickerMode:用户点开 WorkDetailPage 时 feed 页仍在路由栈里、本
      // widget 仍 mounted,裸 Ticker 会在被盖住的页面上继续转,正是闸 6
      // "不留后台渲染"要禁的。muted 期间 elapsed 不累加,所以恢复时 dt
      // 不会暴冲成一大跳。
      _ticker = createTicker(_onTick)..start();
    } catch (e) {
      DeviceLog.log(
        'FeedLive',
        '${widget.work.id} 点云加载失败(卡片留静态缩略图): $e',
      );
    }
  }

  /// 每 vsync 唤醒,但只在够一个 [widget.fpsCap] 帧间隔时才真的推进相机 ——
  /// 闸 3 的 24fps 封顶就是这道门。Ticker 回调本身极轻,真正的成本(setState
  /// + 全量重投影 + 深度排序)被门在后面。
  void _onTick(Duration elapsed) {
    final base = _base;
    if (base == null) return; // 还没收到首帧相机
    final dt = elapsed - _lastStep;
    final interval = Duration(microseconds: 1000000 ~/ widget.fpsCap);
    if (dt < interval) return;
    _lastStep = elapsed;
    // 按**真实经过时间**推进,不是固定步长:24fps 与 15fps 下角速度一致,
    // 降级表现为"步进变粗"而不是"忽然转慢了"(后者会被当成卡死)。
    _yaw += kCardRotateRadPerSec * (dt.inMicroseconds / 1000000.0);
    _frames++;
    final window = elapsed - _fpsWindowStart;
    if (window >= const Duration(seconds: 5)) {
      final fps = _frames / (window.inMicroseconds / 1000000.0);
      DeviceLog.log(
        'FeedLive',
        '实测 fps=${fps.toStringAsFixed(1)} (封顶 ${widget.fpsCap}) '
            '${widget.work.id}',
      );
      _frames = 0;
      _fpsWindowStart = elapsed;
    }
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
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    if (cloud == null) return const SizedBox.shrink();
    // TweenAnimationBuilder(不是 AnimatedOpacity):后者只在 opacity **变化**
    // 时才动,首帧就给 1 是直接硬切。这里要的是"点云一就位就淡进来"。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      // IgnorePointer 是必须的,不是保险:SparseCloudView 自带单指 orbit /
      // 双指缩放平移的手势竞技场参与者,盖在卡片上会同时吃掉"点卡片进详情页"
      // 和 ListView 的滚动。feed 卡的交互只有一个 —— 点开。
      child: IgnorePointer(
        child: SparseCloudView(
          xyz: cloud.xyz,
          rgb: cloud.rgb,
          // 卡片上没有地方放点大小 / 曝光滑轨,也不该有:这是 feed,不是查看器。
          showControls: false,
          controller: _controller,
          onCameraChanged: (c) {
            // 只吃第一次(默认取景)。每次 moveTo 都会回调到这里,所以这里
            // 绝不能 setState —— SparseCloudView 头上就是这么写的。
            if (_base != null) return;
            _base = c;
            _yaw = c.yaw;
          },
        ),
      ),
    );
  }
}
