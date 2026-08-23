// MeStatsViewModel — backs the trailing values on the Me settings page
// (notifications + privacy). One-shot Supabase fetch on load(), with a
// notifyListeners() so the page rebuilds when the values arrive.
//
// Sources:
//   • notificationsEnabled → public.notification_settings.push_enabled
//     for the signed-in uid. Null when the row hasn't been created yet
//     (UI shows "未配置 / Not configured").
//   • isPrivate            → public.profiles.is_private. Null on RLS or
//     network failure.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show Supabase, SupabaseClient;

class MeStatsViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool? _notificationsEnabled;
  bool? _isPrivate;
  String? _handle;
  String? _lastRegion;

  bool? get notificationsEnabled => _notificationsEnabled;
  bool? get isPrivate => _isPrivate;

  /// 唯一 handle。null = 尚未设置(迁移 20260823010000 允许 handle 为 NULL,
  /// 不自动生成 —— GitHub 的教训是自动分配 + 旧名释放会被抢注冒充)。
  String? get handle => _handle;

  /// profiles.last_region —— 账号信息页面展示的 IP 属地,
  /// 《互联网用户账号信息管理规定》第十二条。
  ///
  /// 🔴 客户端**只读**。它由 report-region Edge Function 从请求头判定后写入,
  /// 且被 guard_profile_identity_columns 挡住不让 anon/authenticated 写
  /// (迁移 20260824000000)—— 客户端可写 = 属地可伪造 = 等于没做第十二条。
  ///
  /// null = 还没上报过,或 IP 库尚未导入 ⇒ 设置页那一行显示"未知"占位而非
  /// 隐藏(与作品卡片不同:账号页面这一行是法条明确要求"应当展示"的,
  /// 藏起来会让人以为我们没做;作品卡上少一行则不会)。
  String? get lastRegion => _lastRegion;

  Future<void> load() => _loadRemote();

  Future<void> _loadRemote() async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentSession?.user.id;
      if (uid == null) return;
      // profiles.is_private — auto_init_user_profile trigger guarantees a
      // row exists, but maybeSingle() returning null is still tolerated
      // (e.g. RLS denies the read in tests).
      final profile = await client
          .from('profiles')
          .select('is_private, handle, last_region')
          .eq('id', uid)
          .maybeSingle();
      if (_disposed) return;
      if (profile != null && profile['is_private'] is bool) {
        _isPrivate = profile['is_private'] as bool;
      }
      if (profile != null) {
        _handle = profile['handle'] as String?;
        _lastRegion = (profile['last_region'] as String?)?.trim();
        if (_lastRegion != null && _lastRegion!.isEmpty) _lastRegion = null;
      }
      // notification_settings — the row is created lazily the first time
      // the user touches notification preferences, so a null here means
      // "未配置 / Not configured" rather than an error.
      final settings = await client
          .from('notification_settings')
          .select('push_enabled')
          .eq('user_id', uid)
          .maybeSingle();
      if (_disposed) return;
      if (settings != null && settings['push_enabled'] is bool) {
        _notificationsEnabled = settings['push_enabled'] as bool;
      }
      notifyListeners();
      // [IP-REGION 2026-08-24] 属地上报。放在最后、不 await 结果的原因:
      // 它是装饰性信息,不该拖慢设置页,更不该在失败时影响上面任何一项。
      unawaited(_reportRegion(client));
    } catch (e, s) {
      debugPrint('[MeStats] remote load failed: $e\n$s');
    }
  }

  /// 调 report-region,把**当前**属地刷新到 profiles.last_region。
  ///
  /// 🔴 请求体是空的,而且必须是空的 —— 属地只能由服务端从 x-forwarded-for
  /// 判定。任何"客户端上报自己在哪"的设计都等于属地可伪造。
  ///
  /// 节流到 6 小时一次:业界(微博/抖音)的更新粒度也是会话级,不是每次请求。
  /// 用 last_region_at 在**服务端**已有的时间戳做判断成本更高(要多一次
  /// 往返),这里用本地时间戳节流即可 —— 节流失效的最坏后果只是多打一次
  /// 无害的请求,服务端还有 60/小时的限流兜底。
  static DateTime? _lastReportAt;
  Future<void> _reportRegion(SupabaseClient client) async {
    final now = DateTime.now();
    final prev = _lastReportAt;
    if (prev != null && now.difference(prev) < const Duration(hours: 6)) {
      return;
    }
    _lastReportAt = now;
    try {
      final res = await client.functions.invoke('report-region');
      final region = (res.data is Map)
          ? (res.data as Map)['region'] as String?
          : null;
      if (_disposed || region == null || region.isEmpty) return;
      if (region != _lastRegion) {
        _lastRegion = region;
        notifyListeners();
      }
    } catch (e) {
      // fail-open:拿不到属地就沿用上一次的值,不打扰用户。
      debugPrint('[MeStats] report-region failed: $e');
    }
  }

  /// 改完 handle 后重新拉一次。handle 不在 AuthenticatedUser 上
  /// (它存在 public.profiles 而不是 auth metadata),所以设置页要靠这个回读。
  Future<void> refresh() => _loadRemote();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
