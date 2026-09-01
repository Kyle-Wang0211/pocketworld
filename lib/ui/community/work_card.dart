// WorkCard — one square card in the community feed.
//
// ── 2026-08-16: 静态缩略图打底 + 焦点卡真实时自转 ────────────────────
//
// 底子是缩略图:PublishService 在发布时上传 `official_sparse_thumb.png`
// (斜上 45°, 真彩, 黑底),所以已发布作品看上去和它的草稿一模一样,一张
// 普通卡片只花一次图片解码。
//
// **最居中的那一张**卡额外叠一层实时 mesh viewer(AetherCppCardDemo):真渲、
// 自转 24fps。点云类格式不走这条路(见 build 里 isPointCloudFormat 那段)。
// [2026-08-16 用户拍板] "直接做真实时渲染" —— 08-07 那条"在列表里铺实时点云
// 是往火上加油"的签决管的是**一屏 4-6 张**同时渲(见 sparse_thumbnail.dart),
// 不是一张;旧 PostCard 的自转本来也只开焦点那一张。把前者当后者砍掉是过度
// 解释。压热靠七道闸,不靠"一张也不许"(闸门见 card_live_governor.dart)。
//
// 谁是焦点、现在允不允许 live,由 VaultPage 判(它才看得见滚动状态和整个
// 列表的可见度)。本卡片只是照做:isLive 为真就 mount live 层。
//
// 完整点云仍然只在打开作品时才下载 —— 见 WorkDetailPage。焦点卡下的是同一
// 份 PLY(过 GlbCache),但只渲降点后的前 2.5 万点。没有预测性预取:一朵稀疏
// 点云 ~1.4 MB,替用户可能根本不会打开的作品掏流量是拿"也许"换真钱。

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../../capture/pw_telemetry.dart';
import '../../l10n/app_localizations.dart';
import '../../util/device_log.dart';
import '../design_system.dart';
import '../viewer_social_contract.dart';
import 'aether_cpp_card_demo.dart';
import 'card_live_governor.dart';
import 'skeleton_shimmer.dart';

class WorkCard extends StatefulWidget {
  final FeedWork work;
  final CommunityService service;
  final VoidCallback onTap;

  /// 这张卡是不是 feed 里最居中的那张(VaultPage 按各卡可见度算)。
  /// **只驱动自转**,不决定挂不挂 viewer —— 挂载生命周期是本卡自己的
  /// sticky/debounce/registry 三层在管。
  ///
  /// 五月原注释:"only the focused card runs a Ticker → only it pushes
  /// setMatrices each frame → only it stays dirty on the native side.
  /// Static cards render once after load and then sleep."
  final bool isFocused;

  /// 冒泡给 VaultPage,让它跨卡片算谁是焦点。
  final ValueChanged<double>? onVisibilityChanged;

  /// 热闸说现在不许转(thermal serious / 内存告警 / 后台)。
  final bool rotationAllowed;

  /// 点赞等本地乐观状态变化后回传给父级(五月的 PostCard 有这个口子)。
  final ValueChanged<FeedWork>? onWorkUpdated;

  /// [D7 2026-08-23] 点 @handle → 流内"只看这个人的作品"过滤。
  ///
  /// **不是个人主页**。调研实证:与我们最像的三家里,Sketchfab 的个人主页
  /// URL 是上线约 7 个月后才有的(关注 13 个月),Polycam 约 16-19 个月,
  /// Scaniverse 的 release notes 里 profile/follow/feed 零次出现。
  ///
  /// 但反方有一条成立:`@handle` 已经渲染在这里,**一个长得像链接、带 @、
  /// 按下去没反应的东西,在用户心智里是"这 App 有 bug"**。所以要接上,
  /// 只是接到过滤而不是主页。
  final ValueChanged<FeedWork>? onAuthorTap;

  /// [2026-08-24 用户签决] **置顶栏和作品卡一起加载成功**,不许各揭各的。
  ///
  /// 卡片自己算得出"内容能看了"(见 build 里的 contentReady),但它只**上报**
  /// 这件事;揭不揭幕布由页面统一决定 —— 页面等首屏那几张全就绪(或超时兜底)
  /// 才一起放行。默认 true 是为了让"单独用一张卡"的场景不受影响。
  final bool revealed;

  /// 内容第一次可看时上报给页面。只报一次。
  final VoidCallback? onContentReady;

  const WorkCard({
    super.key,
    required this.work,
    required this.service,
    required this.onTap,
    this.isFocused = false,
    this.onVisibilityChanged,
    this.rotationAllowed = true,
    this.onWorkUpdated,
    this.onAuthorTap,
    this.revealed = true,
    this.onContentReady,
  });

  @override
  State<WorkCard> createState() => _WorkCardState();
}

class _WorkCardState extends State<WorkCard> {
  /// 本地副本。父级(VaultPage)因为热闸/焦点变化会频繁 setState 重建,而
  /// 点赞是乐观更新 —— 需要一个不被父级每次重建冲掉、又能在真正拿到新数据
  /// 时跟上的中间层。五月的做法,照搬。
  late FeedWork _work;
  bool _likeInFlight = false;

  @override
  void initState() {
    super.initState();
    _authorTapRecognizer = TapGestureRecognizer()
      ..onTap = () => widget.onAuthorTap?.call(_work);
    _work = widget.work;
  }

  @override
  void didUpdateWidget(covariant WorkCard old) {
    super.didUpdateWidget(old);
    // in-flight 期间不接受父级的旧值(会把乐观更新冲掉);换了另一个作品则
    // 无条件接管。没有这个,feed 刷新后 State 被复用,点赞数会一直停在
    // 创建时那一刻的值 —— `late _liked = widget.work.likedByMe` 只跑一次。
    if (!_likeInFlight && widget.work.id == old.work.id) {
      _work = widget.work;
    } else if (widget.work.id != old.work.id) {
      _work = widget.work;
    }
  }

  // ── 以下三层防护逐字取自五月的 PostCard(git HEAD:lib/ui/community/
  //    post_card.dart)。它们不是"可以想想要不要加"的优化,每一条都是真机
  //    上踩出来并写进注释的:
  //
  //    L1 可见度阈值 0.3
  //    L2 mount debounce 150ms —— 不加就是"mount 完立刻被 evict",每轮白付
  //       768² IOSurface + cgltf parse + GPU upload + 全部 destroy。五月原话:
  //       "On iPhone 14 Pro this hits thermal=serious within ~10s of fast
  //        scrolling, dropping fps to 12-15"
  //    L3 _LiveInstanceRegistry 全局上限 3 —— 原本 5,2026-05-02 真机实测降到 3
  //
  //    sticky unmount 5 分钟:卡片滑出屏幕后不立刻卸载,专治"push 详情页 →
  //    可见度瞬间掉 0 → 卸载 → pop 回来重新加载"。
  //
  //    [2026-08-17] 我第一版把这些全漏了,只抄了 isFocused,结果真机内存峰值
  //    从 624MB 涨到 1133MB —— 焦点在两张卡之间来回切,每次都是一整轮
  //    mount/dispose,正是 L2 要防的循环。
  //    这三个值**不是**我拍的,来自 lib/ui/viewer_social_contract.dart 的
  //    ViewerSocialPolicyContract —— 那份契约把 "live viewer mount/unmount
  //    policy" 明确划给 Dart 侧所有(`executorMustNotOwn: ['when a card
  //    becomes live']`)。硬编码等于把契约抄成第二份真值,以后改契约改不动这里。
  //    (五月这三个值是硬编码的,契约只当文档;这里改成从契约读 —— Dart 的
  //    const 不能读实例字段,所以是 static final。多花一次惰性初始化,换掉
  //    "契约和实现两份真值"的隐患。)
  static final double _liveMountThreshold =
      kViewerSocialPolicyContract.feedLiveMountThreshold;
  static final Duration _mountDebounce = Duration(
    milliseconds: kViewerSocialPolicyContract.feedMountDebounceMs,
  );
  static final Duration _unmountDelay = Duration(
    milliseconds: kViewerSocialPolicyContract.feedUnmountDelayMs,
  );

  double _visibility = 0;
  bool _isLive = false;
  bool _viewerFirstFrameReady = false;

  /// onContentReady 只报一次 —— 每帧都报会把页面拖进重建风暴。
  bool _reportedReady = false;

  /// 缩略图是否已经画出第一帧。
  ///
  /// [2026-08-23] 与 [_viewerFirstFrameReady] 一起构成**唯一的就绪闸**。
  /// 在此之前整张卡被骨架盖住 —— 见 build 里 `ready` 的注释。
  bool _thumbReady = false;
  /// [D7] @handle 的点击识别器。
  ///
  /// ⚠️ TapGestureRecognizer **必须 dispose**,否则每张卡漏一个 —— feed 滚起来
  /// 就是持续泄漏。放在 State 里而不是 build 里现建,正是为了有地方 dispose。
  late final TapGestureRecognizer _authorTapRecognizer;
  Timer? _mountTimer;
  Timer? _unmountTimer;

  /// 记忆化 —— 没有 `late final`,每次 `_forceUnmount` tear-off 都是一个新
  /// 闭包,registry 既匹配不上 unregister,也删不掉自己那条。
  late final void Function() _forceUnmountCallback = _forceUnmount;

  void _onVisibilityChanged(VisibilityInfo info) {
    // visibility_detector 在 widget 拆下树后还会补一发 visibleFraction=0,
    // 那时 mounted 已是 false,setState 会 assert。
    if (!mounted) return;
    final next = info.visibleFraction;
    if ((next - _visibility).abs() > 0.02) {
      setState(() => _visibility = next);
    }
    widget.onVisibilityChanged?.call(next);

    if (next >= _liveMountThreshold) {
      _unmountTimer?.cancel();
      _unmountTimer = null;
      if (!_isLive && _mountTimer == null) {
        _mountTimer = Timer(_mountDebounce, () {
          _mountTimer = null;
          // 到点再核一次:debounce 期间卡片可能已经滑走或被销毁。
          if (mounted && _visibility >= _liveMountThreshold && !_isLive) {
            _setLive(true);
          }
        });
      }
    } else {
      // 停留时间没够就滑走了 —— GPU 上传那笔钱一分没花。
      _mountTimer?.cancel();
      _mountTimer = null;
      if (_isLive && _unmountTimer == null) {
        _unmountTimer = Timer(_unmountDelay, () {
          if (mounted) _setLive(false);
          _unmountTimer = null;
        });
      }
    }
  }

  /// 把 _isLive 的 setState 和全局实例登记合到一处。上线 → 注册,可能挤掉
  /// LRU 的那位(registry 会回调它的 _forceUnmount);下线 → 注销。
  void _setLive(bool next) {
    if (!mounted) return;
    if (next == _isLive) return;
    if (next) {
      CardViewerRegistry.register(_forceUnmountCallback);
    } else {
      CardViewerRegistry.unregister(_forceUnmountCallback);
    }
    // 挂/卸两侧都打内存 —— [2026-08-17 用户签决"内存必须永远保持在 1500MB
    // 以下"] 要定 cap 就得先知道**一个 viewer 到底吃多少**,而不是继续拿
    // 峰值猜。前后两条 mem 相减就是这一个实例的真实成本。
    final mb = PwTelemetry.sample()?.physFootprintMb;
    DeviceLog.log('FeedLive',
        '${next ? "挂载" : "卸载"} live viewer:${widget.work.id} '
        '(format=${widget.work.format},存活 ${CardViewerRegistry.aliveCount}'
        '/${CardViewerRegistry.cap}'
        '${mb == null ? "" : ",mem=${mb.toStringAsFixed(0)}MB"})');
    setState(() {
      _isLive = next;
      // 每次挂/卸都重置首帧标志。挂:缩略图 backdrop 盖着,直到 viewer 报出
      // 第一帧。卸:Texture 本来就没了,backdrop 是唯一可见层。
      _viewerFirstFrameReady = false;
      // ⚠️ _reportedReady **不跟着重置**。它的语义是"这张卡至少可看过一次",
      // 是给页面揭幕闸的一次性信号;viewer 因 LRU 被挤掉再挂回来,不该让页面
      // 重新收到一次就绪上报。
    });
  }

  /// registry 挤掉 LRU 时调这里。它已经把我们的回调从 _alive 摘掉了,
  /// 所以只翻 _isLive,不再走一遍 unregister。
  void _forceUnmount() {
    if (!mounted || !_isLive) return;
    setState(() => _isLive = false);
  }

  @override
  void dispose() {
    _authorTapRecognizer.dispose();
    _unmountTimer?.cancel();
    _unmountTimer = null;
    _mountTimer?.cancel();
    _mountTimer = null;
    if (_isLive) {
      CardViewerRegistry.unregister(_forceUnmountCallback);
    }
    super.dispose();
  }

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    final wasLiked = _work.likedByMe;
    // 乐观更新 —— 心必须和点击同一帧响应。
    setState(() {
      _likeInFlight = true;
      _work = _work.copyWith(
        likedByMe: !wasLiked,
        likesCount: _work.likesCount + (wasLiked ? -1 : 1),
      );
    });
    widget.onWorkUpdated?.call(_work);
    try {
      final nowLiked = await widget.service.toggleLike(
        workId: _work.id,
        currentlyLiked: wasLiked,
      );
      // 服务端的真值与我们猜的不一致就以它为准 —— 比如同一账号在另一台
      // 设备上已经点过。**这个返回值我上一版直接丢了**,于是 UI 会一路错到
      // 下次刷新。五月是拿它校正的。
      if (nowLiked != !wasLiked) {
        if (!mounted) return;
        setState(() {
          _work = _work.copyWith(
            likedByMe: nowLiked,
            likesCount: _work.likesCount + (nowLiked ? 1 : -1),
          );
        });
        widget.onWorkUpdated?.call(_work);
      }
    } catch (e) {
      debugPrint('[WorkCard] toggleLike failed: $e');
      if (!mounted) return;
      // 回滚到服务端的真相。
      setState(() {
        _work = _work.copyWith(
          likedByMe: wasLiked,
          likesCount: _work.likesCount + (wasLiked ? 1 : -1),
        );
      });
      widget.onWorkUpdated?.call(_work);
    } finally {
      if (mounted) setState(() => _likeInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbPath = _work.thumbnailStoragePath;
    final thumbUrl = thumbPath == null || thumbPath.isEmpty
        ? null
        : widget.service.thumbnailUrlFor(thumbPath);
    // Decode at roughly the on-screen size rather than the source 512²
    // for every card — the ImageCache holds decoded bitmaps, so this is
    // the difference between a few MB and tens of MB on a long feed.
    final points = _work.approxPointCount;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = MediaQuery.sizeOf(context).width - AetherSpacing.lg * 2;
    final cacheWidth = (width * dpr).round().clamp(64, 1024);

    final modelPath = _work.modelStoragePath;
    final modelUrl = modelPath == null || modelPath.isEmpty
        ? null
        : widget.service.modelUrlFor(modelPath);

    // 点云类格式(SPZ / gsplat / PLY)在 feed 卡里**只给静态缩略图**,
    // live 渲染只发生在详情页。
    //
    // ⚠️ [2026-08-23 核实] 这条规则**保留**,但原来的两条理由**都被推翻了**:
    //
    //   ✗ 「每个约 1 GB unified memory,同时挂两个就把 iPhone 12 打到 OOM」
    //     —— 被本文件自己的第 20 行推翻:「一朵稀疏点云 ~1.4 MB」。
    //     闸 2 降到 2.5 万点后更只有 300 KB xyz + 75 KB rgb。**差三个数量级。**
    //     外部换算也对不上:未压缩 3DGS 约 236–248 B/splat,移动端渲染器
    //     MetalSplatter 逐字段是 SH0≈68 B / SH3≈158 B —— 吃满 1 GB 要 ~660 万 splat。
    //
    //   ✗ 「Polycam 就是这么处理的」—— 主语不存在。Polycam app 里没有"点云"
    //     这种作品类型:官方捕获模式只有 Space / Object / Floorplan / AI Capture / 360,
    //     点云是 Space 模式的**导出格式**(ply/las/xyz/pts/dxf),不会作为条目出现在
    //     库列表里。官方对 app 列表的唯一描述是"对所有类型统一的缩略图网格 + 类型角标",
    //     全文不出现 3D / point cloud / mesh / splat 任何一词。
    //
    // ✓ 真正成立的理由(与内存无关):
    //   **最终交付物是 mesh,点云只是中间物。** 在 feed 里把中间物渲给用户看,
    //   本身就违反产品定义。项目另有独立判定"点云肉眼不可接受"(鬼墙 / 浮点战役)。
    //   顺带印证:Khronos KHR_gaussian_splatting 的降级条款写着
    //   "implementations are expected to … render the splat primitive as a point cloud"
    //   —— **退化成点云是全行业的兜底态,不是特性。**
    //
    // 将来若要放开(比如上 splat),判据应该是**能算的预算**而不是格式黑名单:
    //   预算 ≈ N × (32 B 位置/协方差 + SH 阶带来的 0/18/48/90 B + 36 B 排序开销)
    // 且**必须先用 Instruments 实测一次** —— 公开资料给不出 iOS 上渲染 N splat
    // 的实测 RSS,这个数只能自己量。
    final fmt = _work.format.toLowerCase();
    final isPointCloudFormat =
        fmt == 'spz' || fmt == 'gsplat' || fmt == 'ply';
    final canMountLiveViewer =
        _isLive && modelUrl != null && !isPointCloudFormat;

    // [2026-08-23 用户签决] **卡片只有两种状态:灰色闪烁的骨架,和完成态。**
    //
    // 在此之前这里漏出至少三种中间态(真机截图为证):
    //   ① feed 级 _LoadingState —— 2 张骨架卡,连主题卡都还没有
    //   ② 黑底 + **无条件画出来的玻璃板** —— 文字浮在纯黑上几乎看不见,
    //      因为玻璃板那一层不等缩略图、也不等 viewer 出第一帧
    //   ③ 完成态
    // ② 是最难看的一种:它既不是"在加载"也不是"好了",是个幽灵。
    //
    // 现在收成一个闸:内容真的能看了才算 ready,在那之前骨架**盖住整张卡**
    // (包括玻璃板)。三种情形:
    //   · 焦点卡要挂 viewer  → 等 viewer 的第一帧
    //   · 只有缩略图         → 等图的第一帧(图挂了也放行,见 errorBuilder)
    //   · 两者都没有         → 立刻 ready,否则骨架会永远盖着
    final contentReady = canMountLiveViewer
        ? _viewerFirstFrameReady
        : (thumbUrl == null ? true : _thumbReady);

    // 上报给页面。build 期间不能直接回调(会在布局中触发父级 setState),排到帧后。
    if (contentReady && !_reportedReady) {
      _reportedReady = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onContentReady?.call();
      });
    }

    // [2026-08-24] 幕布归**页面**统一揭:自己好了也要等同批的其他卡。
    final ready = contentReady && widget.revealed;

    return VisibilityDetector(
      key: Key('work-card-${_work.id}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: GestureDetector(
        onTap: widget.onTap,
        // 五月有,我漏了。没有它,卡片上任何"没画东西"的像素都不吃点击 ——
        // 玻璃板与边缘之间的留白点下去会没反应。
        behavior: HitTestBehavior.opaque,
        child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Black plate under everything — matches the thumbnail's own
              // background so a letterboxed image has no visible seam.
              const ColoredBox(color: Colors.black),
              if (thumbUrl != null)
                Image.network(
                  thumbUrl,
                  fit: BoxFit.cover,
                  cacheWidth: cacheWidth,
                  gaplessPlayback: true,
                  // [2026-08-23] 首帧画出来才算就绪。
                  // frameBuilder 在 build 期间被调,不能直接 setState。
                  frameBuilder: (ctx, child, frame, wasSync) {
                    if ((frame != null || wasSync) && !_thumbReady) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !_thumbReady) {
                          setState(() => _thumbReady = true);
                        }
                      });
                    }
                    return child;
                  },
                  // 图挂了也要放行 —— 否则骨架会永远盖着,那是第三种状态。
                  errorBuilder: (ctx, _, _) {
                    if (!_thumbReady) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !_thumbReady) {
                          setState(() => _thumbReady = true);
                        }
                      });
                    }
                    return const SizedBox.shrink();
                  },
                ),
              // 焦点卡的 live 层 —— 叠在缩略图之上、玻璃板之下。
              //
              // 闸 6「离开焦点立即回落静态图,不留后台渲染」在这里是**卸载**
              // 而不是隐藏:isLive 转 false,viewer 整个从树上消失,
              // ticker 停、点云引用断开。隐藏的 widget 还会 build/paint,那不
              // 叫停。
              //
              // 玻璃板压在它上面是对的:liquid_glass 采样 Flutter framebuffer
              // 里它背后的东西,而 SparseCloudView 是纯 Dart CustomPaint,画在
              // 同一个 framebuffer 里 —— 所以焦点卡的玻璃板下面是**转着的
              // 点云**,这正是 PostCard 时代的观感。(当年需要 Thermion 才做到
              // 这点,是因为旧的 WKWebView 路径画成 iOS 硬件 overlay,着色器
              // 根本读不到。)
              // 只在 backdrop(缩略图)之上淡入,而且要等 viewer 报出第一帧
              // 才淡 —— 否则会闪一下刚分配、还没渲染过的空 IOSurface,就是
              // 五月注释里那个"小黑点 / 灰色 reload"。
              if (canMountLiveViewer)
                AnimatedOpacity(
                  opacity: _viewerFirstFrameReady ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: AetherCppCardDemo(
                    key: ValueKey('mv-aether-${_work.id}'),
                    modelUrl: modelUrl,
                    // 只有焦点卡跑 Ticker、只有它每帧 setMatrices 标脏。别的
                    // 卡加载完渲一帧就睡,等被滚到中间才醒 —— 这是五月为了
                    // 躲开 Dawn 的 MTLTexture import 风暴定下的。
                    isFocused: widget.isFocused && widget.rotationAllowed,
                    onFirstFrameReady: _onViewerFirstFrameReady,
                  ),
                ),
              // Floating glass info plate — restored from PostCard.
              //
              // The plate never depended on a live renderer: liquid_glass
              // samples whatever sits behind it in the FLUTTER framebuffer,
              // and an Image.network thumbnail qualifies. (Thermion was
              // needed only to escape the older WKWebView path, which drew
              // as an iOS hardware overlay the shader could not read.) So
              // the glass survives the move to static posters unchanged —
              // and gets cheaper, since there is no renderer under it.
              //
              // Settings are PostCard's tuned values, kept verbatim. They
              // encode real feedback:
              //   • "更厚"          → thickness 20→50 (overshot)
              //   • "更透明 + 太厚了" → thickness 50→20, α 0x14→0x08,
              //                        refractiveIndex 1.45→1.20
              // [2026-08-23] 加闸:没就绪就不画。此前它是**无条件**的,
              // 于是在黑底上浮出一块几乎看不见文字的玻璃板 —— 那是中间态 ②。
              if (ready)
                Positioned(
                  left: AetherSpacing.md,
                  right: AetherSpacing.md,
                  bottom: AetherSpacing.md,
                  child: LiquidGlassLayer(
                  settings: const LiquidGlassSettings(
                    thickness: 20,
                    blur: 4,
                    glassColor: Color(0x08FFFFFF),
                    refractiveIndex: 1.20,
                    lightIntensity: 1.0,
                    saturation: 1.0,
                  ),
                  child: LiquidGlass(
                    shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                    glassContainsChild: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _work.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AetherColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // 作者行。五月是纯 `@author`;点数是 08-16 为
                                // 点云作品加的,GLB 时代没有这个概念,保留。
                                Text.rich(
                                  TextSpan(children: [
                                    // [D7] 只有 @handle 这一段可点;点数那段不可点。
                                    // 用 TextSpan 而不是套 GestureDetector ——
                                    // 后者会把整行的命中区抢走,连带压掉卡片本身的
                                    // onTap(整张卡是可点的)。
                                    TextSpan(
                                      // [HANDLE-SEMANTICS 2026-08-23]
                                      // `@` 只跟唯一 ID,不跟昵称。
                                      //
                                      // 迁移 20260823010000 把命名做成双轨:
                                      //   display_name 可重复(中文/emoji 都行)
                                      //   handle       全局唯一(小写 ASCII)
                                      // 抖音号 / 小红书号 / 微信号都是这个结构。
                                      //
                                      // 在此之前这里渲染的是 '@${'$'}{authorDisplayName}' ——
                                      // `@` 在 Twitter/Instagram/GitHub/Discord 里
                                      // 都专指唯一标识,跟在一个**可以有无数同名**的
                                      // 昵称后面,等于告诉用户"这是唯一的",而它不是。
                                      //
                                      // 没设 handle 的用户显示昵称且**不带 @** ——
                                      // 诚实地反映"这个人还没有 ID",而不是拿昵称冒充。
                                      // 点击过滤仍然按 userId 走(见 onAuthorTap),
                                      // 所以行为不受影响,变的只是那串字符说了什么。
                                      // 判空串而不只判 null:DB 的 CHECK 保证
                                      // handle 是 2-32 字符,但渲染层不该依赖
                                      // 上游的约束 —— 一个空串会渲染成孤零零的
                                      // '@'。(这条边界是被测试当场抓到的。)
                                      text: (_work.authorHandle?.isNotEmpty ?? false)
                                          ? '@${_work.authorHandle}'
                                          : _work.authorDisplayName,
                                      recognizer: _authorTapRecognizer,
                                      style: widget.onAuthorTap == null
                                          ? null
                                          : const TextStyle(
                                              color: AetherColors.textPrimary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                    ),
                                    if (points != null)
                                      TextSpan(
                                        text: '  ·  '
                                            '${_formatPointCount(points, AppL10n.of(context).communityPointsSuffix)}',
                                      ),
                                  ]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: AetherColors.textSecondary,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                // 简介 —— 五月有,我整块漏了。发布时填的描述
                                // 在 feed 里根本没露过面。
                                if (_work.description != null &&
                                    _work.description!.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    _work.description!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w400,
                                      color: AetherColors.textSecondary,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          // 五月是**竖排**:心在上、眼在下,各自图标配数字。
                          // 我第一版摊成一行(眼 图标+数字 心 图标+数字),
                          // 占宽更多、标题被挤,和原设计不是一个东西。
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _LikeButton(
                                liked: _work.likedByMe,
                                count: _work.likesCount,
                                busy: _likeInFlight,
                                onTap: _toggleLike,
                              ),
                              // [D8] 浏览块被藏掉时这道间距也要跟着消失,
                              // 否则心形下方留一段无来由的空白。
                              if (_work.viewsCount >= kWorkCardMinViewsToShow)
                                const SizedBox(height: 4),
                              _ViewsChip(count: _work.viewsCount),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // ── 加载态:骨架**盖在最上层**,盖住黑底、缩略图、玻璃板全部。
              //
              // [2026-08-23 用户签决]「我就要两个状态:灰色闪烁的加载状态,
              // 和最终的完成状态。」所以这里不是"某一层的占位",而是一整块
              // 幕布 —— 在 ready 之前,用户看到的就只有灰色骨架。
              //
              // 用 IgnorePointer 让点击穿透到下面的卡片手势(加载中点一下也该
              // 能进详情页,而不是被幕布吞掉)。
              //
              // 200ms 淡出与 viewer 的淡入同时长,两者交叉过渡,不会出现
              // "骨架已经没了但内容还没上来"的第三帧。
              IgnorePointer(
                ignoring: ready,
                child: AnimatedOpacity(
                  opacity: ready ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: SkeletonWorkCard(
                    fill: true,
                    animate: widget.rotationAllowed,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// AetherCppCardDemo 在它的 Texture 画出第一帧真像素时回调这里,于是把
  /// viewer 从 backdrop 上淡进来。
  void _onViewerFirstFrameReady() {
    if (!mounted) return;
    if (_viewerFirstFrameReady) return;
    setState(() => _viewerFirstFrameReady = true);
  }
}

/// 全 App 同时存活的 viewer 实例硬上限。每个实例握着一块 768×768 IOSurface、
/// 一份 Dawn SharedTextureMemory import、逐 primitive 的顶点/索引/因子缓冲,
/// 以及一条逐 primitive 的 BindGroup 链(光那个国际象棋场景就有 49 个)。
///
/// 原本是 5(compose-reels 的 `(preloadCount*2)+1`,preloadCount=2)。
/// 2026-05-02 真机实测降到 3:iPhone 14 Pro 上快速滚动 ~10 秒就 thermal=
/// serious、掉到 12-15fps —— 即便已经有了 150ms 的 mount debounce,5 个渲染器
/// 同时握着 768² IOSurface + ~10 个 GPU 缓冲 + Metal 命令队列状态,A16 也扛不住。
/// cap=3 = 当前卡 + 前一张 + 后一张。
///
/// 逐字取自五月的 post_card.dart。
/// "101,325 点" / "101,325 points" — the scan's size in the unit that
/// means something to someone browsing 3D captures. Thousands-separated
/// rather than the Chinese 万 form so one formatter serves both locales.
String _formatPointCount(int n, String suffix) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '$buf $suffix';
}

class _LikeButton extends StatelessWidget {
  final bool liked;
  final int count;

  /// 请求在飞 —— 禁用点击。五月有这个,我第一版漏了:连点会连发
  /// toggleLike,乐观更新和服务端返回值交错,计数就乱了。
  final bool busy;
  final VoidCallback onTap;

  const _LikeButton({
    required this.liked,
    required this.count,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              size: 22,
              // 五月用的是设计系统里的 danger,不是我第一版硬编码的
              // 0xFFFF4D6D;未点赞态是 textPrimary(我写成了 textSecondary,
              // 在玻璃板上偏淡)。
              color: liked ? AetherColors.danger : AetherColors.textPrimary,
            ),
            // [D8 2026-08-23 用户签决] 0 不渲染 —— 不是显示 "0"。
            // 依据:低数字本身就是负向信号。冷启动期公开作品个位数,
            // 一张写着"0 个赞"的卡片比不写更伤。
            // ⚠️ 心形图标**必须保留** —— 它是点赞的可供性,不是计数。
            // 藏掉图标等于把功能藏了,那是另一回事。
            if (count > 0) ...[
              const SizedBox(height: 2),
              Text(
                formatCount(count),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AetherColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 1000 以上收成 K —— 五月的 _formatCount。我第一版直接印原数,
  /// 上了万就把玻璃板撑变形。
  static String formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '${(n / 1000).round()}K';
  }
}

/// 浏览数 —— 与点赞同款竖排,颜色更淡(它是次要信息)。
/// [D8 2026-08-23 用户签决] 浏览数低于此值时整块不渲染(图标一并藏)。
///
/// 与点赞不同:浏览数**没有可供性** —— 它不可点,藏掉不损失任何功能,
/// 所以连图标一起藏,而不是只藏数字。
///
/// 为什么是 2 而不是 1:冷启动期公开作品个位数,一件作品的"1 次浏览"
/// 几乎必然是创作者自己点进去的那次。把它印在卡片上,等于告诉每个访客
/// "除了作者没人看过"。
///
/// 这是**产品判断不是技术约束** —— 一行可改。若哪天想连 0 都显示,设 1;
/// 想更狠,设更大。
const int kWorkCardMinViewsToShow = 2;

class _ViewsChip extends StatelessWidget {
  final int count;
  const _ViewsChip({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count < kWorkCardMinViewsToShow) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.remove_red_eye_outlined,
            size: 18,
            color: AetherColors.textSecondary,
          ),
          const SizedBox(height: 2),
          Text(
            _LikeButton.formatCount(count),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AetherColors.textSecondary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

