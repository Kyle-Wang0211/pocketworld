// VaultPage — community feed (the "社区 / Community" tab).
//
// 2026-04-30 redesign:
//   • Sticky top: search bar + 3-tab segmented control (热门 / 附近 /
//     发现). Tapping a tab refetches the feed with a different sort key;
//     "附近 / Nearby" is a coming-soon stub since profiles.location is
//     plain text and we have no geo schema yet.
//   • Below: a vertical list of WorkCards, sourced from
//     CommunityService.fetchPublicFeed(sortBy, query).
//
// 2026-08-16 — 卡片是缩略图,**最居中的那一张**除外:它真渲点云并自转。
//
// [用户拍板] "直接做真实时渲染"、"那就想办法优化呀,不让手机热呀"。旧
// PostCard 每张卡挂一个真渲染器、还留着约两屏不卸载,那是 GLB 时代的设计,
// 确实该死;但 08-07 那条"在列表里铺实时点云是往火上加油"的签决(见
// sparse_thumbnail.dart)管的是**一屏 4-6 张**同时渲,而 PostCard 的自转
// 本来就只开焦点那一张 —— 拿前者当理由把后者一起砍掉是过度解释。
//
// 所以焦点追踪回来了(下面的 _visibilityByWorkId / _recomputeFocus,阈值和
// 旧实现一致),但这一次它前面挡着七道压热闸:
//
//   闸 1 全 App 同时只允许 1 个 live 卡 —— _liveWorkId 是单值,不是集合
//   闸 2 (已随 live_card_cloud.dart 于 2026-08-23 删除:点云不在 feed 里 live)
//   闸 3 自转封顶 24fps               ┐
//   闸 4 thermalState 自适应/serious 停 ├ card_live_governor.dart
//   闸 5 滚动中不转,静止 300ms 才起  │
//   闸 7 内存告警即释放               ┘
//   闸 6 离焦立即**卸载**(不是隐藏)  —— work_card.dart 的 if (isLive)
//
// cacheExtent 保持默认:2000 那个值当年是为了让屏外的 live 渲染器别被卸载
// (重挂 AetherCppCardDemo 即使缓存命中也要 ~500 ms)。现在屏外卡片就是一张
// 图,重建等于一次缓存查表,而把屏外卡片留在树上恰恰是闸 1/6 要避免的。
//
// Cross-platform: pure Flutter widgets + supabase_flutter. No native
// code, no platform conditionals — same UI on iOS / Android / HarmonyOS
// / Web.(live 层同样是纯 Dart:SparseCloudView 是 CustomPaint。)

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../community/community_service.dart';
import '../community/glb_cache.dart';
import '../community/feed_models.dart';
import '../l10n/app_localizations.dart';
import '../util/device_log.dart';
import 'community/card_live_governor.dart';
import 'community/reveal_gate.dart';
import 'community/skeleton_shimmer.dart';
import 'community/user_profile_page.dart';
import 'community/work_card.dart';
import 'community/work_detail_page.dart';
import 'design_system.dart';

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final CommunityService _service = CommunityService();
  final TextEditingController _searchController = TextEditingController();
  late Future<List<FeedWork>> _feed;
  String _query = '';

  /// Feed 分页(offset 翻页)。此前只拉一次 limit:20 且没有加载更多,第 21
  /// 个作品对所有人永久不可见。_hasMore=false 表示服务端给不满一页了。
  static const int _pageSize = 20;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// 闸 3/4/5/7 的总闸门 —— 它说不行,就一张 live 卡都没有。
  final CardLiveGovernor _governor = CardLiveGovernor();

  /// 每张卡的可见比例(VisibilityDetector 上报),用来挑焦点卡。
  final Map<String, double> _visibilityByWorkId = {};
  String? _focusedWorkId;

  /// 焦点卡必须**明显**是焦点才算数。等大的正方形卡片里,可见度最高的那张
  /// 就是最居中的那张;0.55 这个门槛保证换焦点时不会在两张各露一半的卡之间
  /// 来回横跳(每次横跳 = 一轮卸载 + 重下载解析降点)。沿用旧 PostCard 的值。
  static const double _focusThreshold = 0.55;

  /// 闸 1:全 App 同时只有这一张卡是 live 的。null = 现在一张都没有。
  String? get _liveWorkId => _governor.liveAllowed ? _focusedWorkId : null;

  // ── 页面级统一揭幕 ───────────────────────────────────────────────
  //
  // [2026-08-24 用户签决]「需要置顶栏和任务卡片一起加载成功」。
  // 判决逻辑全在 [RevealGate] 里 —— 抽出去是为了能真把时间推过去验超时兜底,
  // 留在这里就只能写源码文本断言,而那种断言被变异测试当场证明挡不住东西。
  final RevealGate _revealGate = RevealGate();

  bool get _revealed => _revealGate.revealed;

  void _onRevealChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _feed = _loadFeed();
    _governor.addListener(_onGovernorChanged);
    _revealGate.addListener(_onRevealChanged);
  }

  @override
  void dispose() {
    _revealGate.removeListener(_onRevealChanged);
    _revealGate.dispose();
    _governor.removeListener(_onGovernorChanged);
    _governor.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onGovernorChanged() {
    if (mounted) setState(() {});
  }

  /// 换 tab / 换搜索词 / 下拉刷新 —— 列表整个换了,旧的可见度读数全作废。
  void _resetFocus() {
    _visibilityByWorkId.clear();
    _focusedWorkId = null;
  }

  /// 挑焦点卡:可见度最高、且过 [_focusThreshold] 的那张。
  void _recomputeFocus() {
    String? next;
    var best = _focusThreshold;
    for (final entry in _visibilityByWorkId.entries) {
      if (entry.value > best) {
        best = entry.value;
        next = entry.key;
      }
    }
    if (next != _focusedWorkId && mounted) {
      // 闸 1/6 的现场证据:换焦点 = 旧 live 卡卸载 + 新的挂上。真机验收看这
      // 条能确认"同时只有一张"没被破坏(不该出现两条连续的挂载而无卸载)。
      DeviceLog.log(
        'FeedLive',
        '焦点卡:${_focusedWorkId ?? "无"} → ${next ?? "无"} '
            '(可见度 ${best.toStringAsFixed(2)})',
      );
      setState(() => _focusedWorkId = next);
    }
  }

  /// 卡片本地状态(点赞)变化的回传口。见调用点注释 —— 与五月一致,暂空。
  void _onWorkUpdated(String workId, FeedWork updated) {}

  void _onCardVisibilityChanged(String workId, double fraction) {
    _visibilityByWorkId[workId] = fraction;
    _recomputeFocus();
  }

  /// 给下一张卡的**只下字节**预取,发完不管(Reels / TikTok 那套)。
  ///
  /// 去重交给 GlbCache.fetch 自己的 in-flight + 内存 + 磁盘三层,所以每次
  /// 可见度变化都调一次也很便宜。catchError 吞掉网络抖动 —— 用户真滚到那里
  /// 时自然会再试一次。
  ///
  /// **只下字节是刻意的**:走 GlbAssetCache.getOrLoad 会连 GPU 资源一起建,
  /// 而用户可能一划就过去了,那份 GPU 分配纯属浪费。
  ///
  /// [2026-08-17] 我 08-16 在 work_card 的注释里写"No predictive prefetch:
  /// 替用户可能根本不会打开的作品掏流量是拿'也许'换真钱",把这条否掉了 ——
  /// 但五月早就权衡过:只下字节、且只预取紧邻的 1-2 张,换来的是滚到下一张时
  /// 模型已经在磁盘上、零可感等待。这正是 feed 顺滑的来源之一。
  void _kickPrefetch(FeedWork work) {
    final path = work.modelStoragePath;
    if (path == null || path.isEmpty) return;
    final url = _service.modelUrlFor(path);
    unawaited(
      GlbCache.instance.fetch(url).catchError((Object _) {
        return Uint8List(0);
      }),
    );
  }

  Future<List<FeedWork>> _loadFeed() {
    _hasMore = true;
    _loadingMore = false;
    return _service.fetchPublicFeed(
      limit: _pageSize,
      // 标签砍掉后定死 recent。原默认 tab 是 discover,本就映射到 recent,
      // 所以这是**行为不变**的改法,不是换默认值。
      sortBy: FeedSort.recent,
      query: _query.isEmpty ? null : _query,
    );
  }

  /// 快滚到底时补下一页,静默追加(风格同 _kickPrefetch:发完不管)。
  /// offset 翻页 + 按 id 去重 —— 两页之间有新作品发布时,offset 会把上一页
  /// 的尾行再发一遍,去重后追加不闪不跳。失败不提示:用户继续滚会再触发。
  Future<void> _maybeLoadMore(List<FeedWork> current) async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final feedAtStart = _feed;
    try {
      // [KEYSET-PAGINATION 2026-08-23] 用上一页最后一条的 (published_at, id)
      // 作游标,不再用 offset。
      //
      // offset 的病:边翻页边有新作品插到顶部时,整列下移一位,原本在 offset
      // 处的那条挪到 offset+1,第二页从下一条开始 —— **中间那条对该用户永远
      // 不出现**。下面的 id 去重挡得住重复,挡不住漏。
      //
      // 本仓修过一次同类(此前只拉一次 limit:20 且无加载更多,第 21 个作品
      // 对所有人永久不可见);这是它更隐蔽的变体。
      final last = current.isEmpty ? null : current.last;
      final cursorAt = last?.publishedAt;
      final next = await _service.fetchPublicFeed(
        limit: _pageSize,
        // 游标可用就不传 offset;查询里 published_at is not null 已经保证
        // 返回的每一条都有时间戳,这里的 null 兜底只是防御。
        offset: cursorAt == null ? current.length : 0,
        sortBy: FeedSort.recent,
        query: _query.isEmpty ? null : _query,
        afterPublishedAt: cursorAt,
        afterId: cursorAt == null ? null : last!.id,
      );
      // tab / 搜索 / 下拉刷新已经换了整个列表 → 这批结果作废。
      if (!mounted || !identical(_feed, feedAtStart)) return;
      if (next.length < _pageSize) _hasMore = false;
      // 去重保留:keyset 之后重复已不该发生,但它零成本、且能兜住
      // "刷新与加载更多竞态"这类边角。**它挡不住漏项 —— 那是 keyset 修的。**
      final seen = current.map((w) => w.id).toSet();
      final fresh = next.where((w) => !seen.contains(w.id)).toList();
      if (fresh.isEmpty) return;
      setState(() {
        _feed = Future.value(<FeedWork>[...current, ...fresh]);
      });
    } catch (_) {
      // 网络抖动:静默,滚动会重试。
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _refresh() async {
    final next = _loadFeed();
    setState(() {
      _resetFocus();
      _feed = next;
    });
    await next;
  }

  // ignore: unused_element  —— [D2] 搜索代码按用户要求保留,只是不渲染。
  void _onQuerySubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed == _query) return;
    setState(() {
      _resetFocus();
      _query = trimmed;
      _feed = _loadFeed();
    });
  }

  void _onAuthorTap(FeedWork work) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserProfilePage(
          userId: work.userId,
          seedWork: work,
        ),
      ),
    );
  }

  // ignore: unused_element  —— [D2] 搜索代码按用户要求保留,只是不渲染。
  void _onClearQuery() {
    if (_query.isEmpty && _searchController.text.isEmpty) return;
    _searchController.clear();
    setState(() {
      _resetFocus();
      _query = '';
      _feed = _loadFeed();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                // [D1/D2/D3 2026-08-23 用户签决] 冷启动期社区首页 = **单信息流**。
                //
                // 砍掉的两样:
                //   · 三个标签(热门/附近/发现)—— 公开作品个位数,空标签比没有
                //     更伤。且实测「热门」与「发现」本就是同一个流的两个排序键,
                //     合并零信息损失。「附近」的文案是"敬请期待"——**一句没兑现
                //     的承诺比一个空标签更糟**。
                //   · 顶部搜索框 —— 几件作品搜什么。
                //
                // ⚠️ 搜索的**代码全部保留**(_SearchBar / _searchController /
                // _query / _onQuerySubmitted / _onClearQuery / service 的 query
                // 参数),只是不渲染。用户明确要求"先留着别删"。
                // 恢复 = 把下面这个 Padding 的注释解开。
                //
                // if (false) Padding(
                //   padding: const EdgeInsets.fromLTRB(AetherSpacing.lg,
                //       AetherSpacing.md, AetherSpacing.lg, AetherSpacing.sm),
                //   child: _SearchBar(
                //     controller: _searchController,
                //     hasQuery: _query.isNotEmpty,
                //     onSubmitted: _onQuerySubmitted,
                //     onClear: _onClearQuery,
                //   ),
                // ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: _buildFeed(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _showTopicCard => kShowCommunityTopicCard;

  Widget _buildFeed() {
    return FutureBuilder<List<FeedWork>>(
      future: _feed,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _LoadingState(
            animate: _governor.liveAllowed,
            // 主题卡是硬编码的,不等任何请求 —— 加载态就该画上,
            // 否则 feed 到达时整列往下跳一格,那是第三种可见状态。
            showTopicCard: _showTopicCard,
          );
        }
        if (snap.hasError) {
          return _ErrorState(
            // Backend/auth implementation details (JWT, PostgREST codes) are
            // diagnostics, not product copy. Transient future-issued JWTs are
            // already retried by DataApiReadinessGate; persistent failures get
            // one stable, actionable state here.
            message: '内容暂时无法加载，请稍后重试',
            onRetry: _refresh,
          );
        }
        final works = snap.data ?? const <FeedWork>[];
        // 新的一批 feed 到手就重定"一起揭幕"这一组。放在这里而不是 _loadFeed
        // 里,是因为 works 只存在于 FutureBuilder 的 snapshot 里,没进 state。
        _revealGate.setWorks(works.map((w) => w.id).toList());
        if (works.isEmpty) {
          return const _EmptyState();
        }
        final liveId = _liveWorkId;
        // 闸 5:滚动中不转,停下静止 300ms 才起转。判定放在这里而不是卡片里
        // —— 只有列表看得见滚动,卡片看不见。
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification) {
              _governor.onScrollStart();
            } else if (n is ScrollEndNotification) {
              _governor.onScrollEnd();
            }
            // 距底不足 1200px(约三张卡)就补下一页;去重和竞态在
            // _maybeLoadMore 里兜着,这里只管触发。
            if (n.metrics.extentAfter < 1200) {
              unawaited(_maybeLoadMore(works));
            }
            return false; // 别拦,RefreshIndicator 还要用这些通知
          },
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(
              AetherSpacing.lg,
              AetherSpacing.md,
              AetherSpacing.lg,
              140,
            ),
            // 留住约两屏的屏外卡片,让快速回滚不必重挂 AetherCppCardDemo
            // (initState → createTexture → load → fit → 首帧,即使缓存全中
            // 也要 ~500 ms)。默认 cacheExtent 约 250 逻辑像素,2000 覆盖可视
            // 区上下各约 3 张,正好配 _LiveInstanceRegistry 的 cap=3。
            //
            // [2026-08-17] 我 08-16 把这行删了,理由是"卡片就是一张图,重建
            // 等于查表"。mesh viewer 一接回来,这个理由就失效了 —— 更要命的是
            // WorkCard 的 sticky-unmount(5 分钟)**依赖卡片留在树上**:
            // ListView 一把屏外卡片回收,dispose 直接 unregister,sticky 形同
            // 虚设,于是回滚必重挂。这是五月早就付过学费的那条。
            cacheExtent: 2000,
            // [D5 2026-08-23 用户签决] 主题卡 = **流内第一张卡**,与作品卡
            // 同宽同层、可滑走 —— 不做压在流上方的独立横幅层。
            // 依据:Roblox 的 Today's Picks 官方定位是 "a sort on Home";
            // Behance 把 Best of Behance 做成与 For You 平级的 chip。
            // 三家都没做独立横幅层。
            //
            // 落法是**同一个 ListView 里做下标偏移**(不换 CustomScrollView):
            // itemCount 多 1,index 0 是主题卡,其余 works[i - offset]。
            itemCount: works.length + (_showTopicCard ? 1 : 0),
            separatorBuilder: (_, _) =>
                const SizedBox(height: AetherSpacing.lg),
            itemBuilder: (ctx, rawIndex) {
              if (_showTopicCard && rawIndex == 0) {
                // 与作品卡同一个闸 —— 一起灰,一起完成。
                return _revealed
                    ? TopicCard(autoPlay: _governor.liveAllowed)
                    : _SkeletonTopicCard(animate: _governor.liveAllowed);
              }
              final i = rawIndex - (_showTopicCard ? 1 : 0);
              final w = works[i];
              // VisibilityDetector 在 WorkCard **内部** —— 它自己要用可见度跑
              // sticky-mount / debounce / LRU 三层(五月的架构),顺带把读数
              // 冒泡上来给这里算焦点。外面再套一个是重复劳动。
              return WorkCard(
                work: w,
                service: _service,
                isFocused: liveId == w.id,
                rotationAllowed: _governor.liveAllowed,
                revealed: _revealed,
                onContentReady: () => _revealGate.markReady(w.id),
                // 五月留的口子。卡片的乐观点赞状态回传到这里,让父级有机会
                // 把它并回 feed 列表 —— 目前和五月一样是空实现(WorkCard 自己
                // 在 State 里保着,didUpdateWidget 负责不被冲掉),等 feed 状态
                // 提成 ChangeNotifier 时这里才有事做。接上是为了不让调用方
                // 以为"卡片改了状态父级收不到"。
                onWorkUpdated: (updated) => _onWorkUpdated(w.id, updated),
                onAuthorTap: _onAuthorTap,
                onVisibilityChanged: (f) {
                  _onCardVisibilityChanged(w.id, f);
                  // 卡片刚露头就为后面 1-2 张预下字节,等用户滚到那里时
                  // 模型已经在磁盘上。见 _kickPrefetch 的注释。
                  if (f > 0.05) {
                    for (var j = 1; j <= 2; j++) {
                      final nextIdx = i + j;
                      if (nextIdx < works.length) {
                        _kickPrefetch(works[nextIdx]);
                      }
                    }
                  }
                },
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WorkDetailPage(work: w, service: _service),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ignore: unused_element  —— [D2] 搜索代码按用户要求保留,只是不渲染。
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool hasQuery;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.hasQuery,
    required this.onSubmitted,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AetherColors.bgElevated,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        children: [
          const SizedBox(width: AetherSpacing.md),
          const Icon(
            Icons.search_rounded,
            size: 18,
            color: AetherColors.textTertiary,
          ),
          const SizedBox(width: AetherSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              onSubmitted: onSubmitted,
              style: AetherTextStyles.body,
              decoration: InputDecoration(
                hintText: l.communitySearchHint,
                hintStyle: AetherTextStyles.body.copyWith(
                  color: AetherColors.textTertiary,
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (hasQuery)
            GestureDetector(
              onTap: onClear,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: AetherSpacing.md),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AetherColors.textTertiary,
                ),
              ),
            )
          else
            const SizedBox(width: AetherSpacing.md),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  /// [§4] 热闸接到 CardLiveGovernor.liveAllowed —— **一屏跑多个骨架卡是真实的
  /// 发热面**,它说不行就一个都不转(退化成静态灰块,不是继续转着看不见)。
  final bool animate;

  /// [2026-08-23] 加载态也画主题卡。它硬编码、不等请求,画上去 feed 到达时
  /// 就不会整列跳一格 —— 用户签决"只要两个状态",布局跳动就是第三种。
  final bool showTopicCard;

  const _LoadingState({this.animate = true, this.showTopicCard = false});

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Has to be scrollable so RefreshIndicator works above an empty
      // initial state.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        140,
      ),
      children: [
        if (showTopicCard) ...[
          _SkeletonTopicCard(animate: animate),
          const SizedBox(height: AetherSpacing.lg),
        ],
        // [§4 2026-08-23] 原本是一个 28×28 的 CircularProgressIndicator ——
        // 首屏最大的一块视觉空白只放了个转圈。换成 2 张与作品卡同形的骨架:
        // 用户一眼知道"要来的是卡片",而不是"这页在忙什么"。
        //
        // 只放 2 张不放 3 张:首屏可视区本来就放不下第三张,多画一张纯属
        // 白给的重绘面积。
        SkeletonWorkCard(animate: animate),
        const SizedBox(height: AetherSpacing.lg),
        SkeletonWorkCard(animate: animate),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(
          Icons.view_in_ar_rounded,
          size: 56,
          color: AetherColors.textTertiary,
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l.communityEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AetherColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(
          Icons.error_outline_rounded,
          size: 48,
          color: AetherColors.danger,
        ),
        const SizedBox(height: AetherSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: AetherColors.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}

/// [D9(a) 2026-08-23] 主题卡的内容**客户端硬编码**,不建表、不发请求。
///
/// 三选一里选 (a) 的理由:D6 已定为**常青人工精选**(不是限时活动),换得不频繁;
/// 冷启动期最贵的是工时不是发版。等真需要按周换,再升到独立的 topics 表。
///
/// 顺带解决了 D10(判定时机):没有请求 ⇒ 不存在"跟首屏一起请求拖慢首屏"
/// 还是"独立异步请求导致置顶卡晚于列表出现"的取舍。
///
/// **关掉它 = 把这里改成 false**,列表会自动退回纯作品流(itemCount 不再 +1)。
const bool kShowCommunityTopicCard = true;

/// 流内第一张卡:常青人工精选。
///
/// 与作品卡**同宽同层**,跟着一起滚、可以滑走 —— 这是 D5 的核心:
/// 它是"流里的一张卡",不是"压在流上面的一层"。
///
/// 文案走 l10n(communityTopicTitle / communityTopicBody),中英各一份。
/// ⚠️ 公开(而非 `_TopicCard`)是为了让 widget 测试能直接 pump 它。
/// 它本来也是个正经的可复用卡片,没有私有的理由 —— 本文件其余
/// `_LoadingState` / `_EmptyState` 之类仍是私有,因为没人从外面用。
/// 置顶栏的高宽比。
///
/// [2026-08-24 用户签决] **2.5:1**,即移动端 banner 的主流出稿尺寸 750×300。
///
/// 定这个数走了两步,中间被用户自己推翻过一次,值得留着:
///   ① 用户圈出想要的大小并说「至少达到我画红圈的大小」,还点名「去看看
///      网易云音乐或者其他 app 的置顶栏」。红框实测约 840×450 px ≈ 1.87:1,
///      **比行业主流的 2.5:1 高得多**。按"至少"这个字面,我取了 16:9。
///   ② 于是把 2.5:1 / 16:9 / 3:2 / 4:3 四个候选按 361pt 的真实卡片宽度画成
///      一页,让用户在**手机上按真实大小**看。看完他选了 2.5:1 ——
///      比自己圈的那块还矮 49pt。
///
/// 也就是说「至少达到红框」是隔着截图估出来的意向,不是看到实物后的判断;
/// 真实尺寸摆在眼前时判断变了。**以 ② 为准**,别再拿 ① 的那条线当地板。
///
/// 原来是内容自适应高度(361pt 宽下约 99pt),2.5:1 给到 144pt。
const double kTopicCardAspect = 2.5;

/// 自动翻页间隔。网易云那类 banner 的常规节奏。
const Duration kTopicAutoPlayInterval = Duration(seconds: 5);

/// 流内第一张卡:常青人工精选,**可翻页**。
///
/// 与作品卡**同宽同层**,跟着一起滚、可以滑走 —— 这是 D5 的核心:
/// 它是"流里的一张卡",不是"压在流上面的一层"。做成轮播不违反 D5:
/// 它照样在流里、照样滑得走,只是自己内部多了几页。
///
/// 文案走 l10n,中英各一份。
/// ⚠️ 公开(而非 `_TopicCard`)是为了让 widget 测试能直接 pump 它。
class TopicCard extends StatefulWidget {
  /// 自动翻页。
  ///
  /// ⚠️ **默认 false**,由调用方接热闸传 true(与 [SkeletonBox.animate] 一个
  /// 路子)。两个理由:
  ///   ① 一屏已经跑着 live 3D viewer,自动轮播是叠上去的第二个常驻 ticker,
  ///     热是本项目的硬约束,不该由一个卡片自己决定开不开;
  ///   ② 默认开会让所有直接 pump 这张卡的 widget 测试在 pumpAndSettle 上挂死
  ///     —— 周期性 Timer 永远 settle 不了。默认关就没有这个陷阱。
  final bool autoPlay;

  const TopicCard({super.key, this.autoPlay = false});

  @override
  State<TopicCard> createState() => _TopicCardState();
}

class _TopicSlide {
  final IconData icon;
  final String title;
  final String body;
  const _TopicSlide(this.icon, this.title, this.body);
}

class _TopicCardState extends State<TopicCard> {
  final PageController _pc = PageController();
  Timer? _auto;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _syncAutoPlay();
  }

  @override
  void didUpdateWidget(covariant TopicCard old) {
    super.didUpdateWidget(old);
    if (widget.autoPlay != old.autoPlay) _syncAutoPlay();
  }

  void _syncAutoPlay() {
    _auto?.cancel();
    if (!widget.autoPlay) return;
    _auto = Timer.periodic(kTopicAutoPlayInterval, (_) {
      if (!mounted || !_pc.hasClients) return;
      final n = _slides(context).length;
      if (n < 2) return;
      _pc.animateToPage(
        (_page + 1) % n,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _pc.dispose();
    super.dispose();
  }

  List<_TopicSlide> _slides(BuildContext context) {
    final l = AppL10n.of(context);
    return [
      _TopicSlide(
        Icons.auto_awesome_rounded,
        l.communityTopicTitle,
        l.communityTopicBody,
      ),
      _TopicSlide(
        Icons.camera_alt_rounded,
        l.communityTopicCaptureTitle,
        l.communityTopicCaptureBody,
      ),
      _TopicSlide(
        Icons.threed_rotation_rounded,
        l.communityTopicViewerTitle,
        l.communityTopicViewerBody,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AetherRadii.lg),
      child: AspectRatio(
        aspectRatio: kTopicCardAspect,
        child: ColoredBox(
          color: AetherColors.bgElevated,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pc,
                itemCount: slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _TopicSlideView(slide: slides[i]),
              ),
              if (slides.length > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: AetherSpacing.lg,
                  child: _TopicDots(count: slides.length, index: _page),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicSlideView extends StatelessWidget {
  final _TopicSlide slide;

  const _TopicSlideView({required this.slide});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 底部留出圆点的位置,否则正文会压在圆点上。
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.lg,
        AetherSpacing.lg,
        AetherSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(slide.icon, size: 18, color: AetherColors.textPrimary),
              const SizedBox(width: AetherSpacing.sm),
              Flexible(
                child: Text(
                  slide.title,
                  style: AetherTextStyles.body.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AetherColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AetherSpacing.sm),
          // 2.5:1 在 361pt 宽下只有 144pt 高,扣掉上下 padding 与圆点区,正文
          // 只剩三行的余地。英文那几条明显更长(中文 28 字 vs 英文 106 字符),
          // 溢出在固定高度的盒子里就是那条黄黑斜纹。Flexible + ellipsis 兜住。
          Flexible(
            child: Text(
              slide.body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AetherTextStyles.body.copyWith(
                fontSize: 13,
                color: AetherColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopicDots extends StatelessWidget {
  final int count;
  final int index;

  const _TopicDots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final on = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: on ? 16 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: on ? AetherColors.textPrimary : AetherColors.borderStrong,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

/// 主题卡的骨架版。
///
/// [2026-08-23] 原来加载态直接画真 [TopicCard] —— 理由是"它硬编码、不等请求,
/// 画上去就不会跳格"。真机上看下来这条是错的:一张已经完成的卡压在两块加载中的
/// 卡上面,本身就是第三种状态。用户原话:「最上方的置顶栏也没灰色状态的闪烁加载」。
///
/// 但"不跳格"那个约束仍然成立,所以这里**不手算高度**——拿真卡当不可见的尺寸模板,
/// 骨架 Positioned.fill 盖在上面。真卡到位那一刻高度逐像素相同,不可能跳。
class _SkeletonTopicCard extends StatelessWidget {
  final bool animate;

  const _SkeletonTopicCard({this.animate = true});

  @override
  Widget build(BuildContext context) {
    // [2026-08-24] 原来拿一张不可见的真 TopicCard 当尺寸模板。TopicCard 变成
    // 有状态的轮播之后这招不能用了 —— 那个隐形实例会真的建 PageController、
    // 真的跑自动翻页 Timer。现在高度由**同一个比例常量**决定,两边不可能走散。
    return AspectRatio(
      aspectRatio: kTopicCardAspect,
      child: SkeletonBox(
        animate: animate,
        borderRadius: BorderRadius.circular(AetherRadii.lg),
      ),
    );
  }
}
