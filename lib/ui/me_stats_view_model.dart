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

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

class MeStatsViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool? _notificationsEnabled;
  bool? _isPrivate;
  String? _handle;

  bool? get notificationsEnabled => _notificationsEnabled;
  bool? get isPrivate => _isPrivate;

  /// 唯一 handle。null = 尚未设置(迁移 20260823010000 允许 handle 为 NULL,
  /// 不自动生成 —— GitHub 的教训是自动分配 + 旧名释放会被抢注冒充)。
  String? get handle => _handle;

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
          .select('is_private, handle')
          .eq('id', uid)
          .maybeSingle();
      if (_disposed) return;
      if (profile != null && profile['is_private'] is bool) {
        _isPrivate = profile['is_private'] as bool;
      }
      if (profile != null) {
        _handle = profile['handle'] as String?;
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
    } catch (e, s) {
      debugPrint('[MeStats] remote load failed: $e\n$s');
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
