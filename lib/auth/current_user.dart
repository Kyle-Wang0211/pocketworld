// Dart port of Core/Auth/CurrentUser.swift.
//
// ChangeNotifier between AuthService and UI. Views observe this, not
// AuthService directly. Publishes three states:
//   bootstrapping — persisted session not yet checked
//   signedIn(user) — show the app
//   signedOut — show the sign-in flow
//
// 30-day idle sign-out timestamp mirrors the Swift impl exactly so the
// SharedPreferences key can be shared cross-platform later.

import 'dart:async';

import '../analytics/pw_analytics.dart';
import 'package:flutter/foundation.dart';

import '../aether_prefs.dart';
import '../util/device_log.dart';
import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';
import 'connection_backoff.dart';
import 'unavailable_auth_service.dart';

sealed class CurrentUserState {
  const CurrentUserState();
}

class CurrentUserBootstrapping extends CurrentUserState {
  const CurrentUserBootstrapping();
}

class CurrentUserSignedIn extends CurrentUserState {
  final AuthenticatedUser user;
  const CurrentUserSignedIn(this.user);
}

class CurrentUserSignedOut extends CurrentUserState {
  const CurrentUserSignedOut();
}

/// 登录后端不可用(初始化失败/超时/网络不通)。**不是** signedOut:登录页
/// 不能出现,否则用户会往一个假服务里输真密码(2026-09-07 未命名(18) 事故)。
/// UI 显示失败原因与"重试";重试走 [CurrentUser.retryServiceInit]。
class CurrentUserServiceUnavailable extends CurrentUserState {
  final String reason;
  const CurrentUserServiceUnavailable(this.reason);
}

class CurrentUser extends ChangeNotifier {
  /// If the app hasn't seen activity in this many seconds, the session
  /// is force-signed-out. "Activity" = successful sign-in, successful
  /// bootstrap, or scene-active while already signed-in.
  ///
  /// Done locally (SharedPreferences) rather than through Firebase
  /// because Firebase tokens don't expire by default — we want a hard
  /// lockout the user controls even offline.
  static const Duration idleSignOutInterval = Duration(days: 30);

  AuthService _service;

  CurrentUserState _state = const CurrentUserBootstrapping();
  AuthException? _lastError;
  bool _isPerformingAuthAction = false;

  CurrentUser({required AuthService service, ConnectionBackoff? initBackoff})
    : _service = service,
      initBackoff = initBackoff ?? ConnectionBackoff();

  /// Debug-only: logs every SignedOut state mutation with a stack trace
  /// so we can answer "who flipped me to SignedOut?" when a stale
  /// detail / settings page surfaces AuthRootView underneath. Wired in
  /// front of every `_state = const CurrentUserSignedOut()` site
  /// (bootstrap / signOut / deleteAccount). Keep cheap in release —
  /// debugPrint is a no-op outside debug.
  void _logSignedOut(String reason) {
    // File-log the reason too: release builds swallow debugPrint, and a
    // silent SignedOut flip (AuthGate pops every route → login page) was
    // undiagnosable in the field without this.
    DeviceLog.log('CurrentUser', '→ SignedOut ($reason)');
    debugPrint(
      '[CurrentUser] → SignedOut ($reason)\n'
      '${StackTrace.current}',
    );
  }

  /// Swap the concrete auth backend at runtime. main() uses this to
  /// launch the app on a mock service (so runApp doesn't block on
  /// Firebase.initializeApp) and upgrade to the Firebase-backed
  /// service once initialization settles.
  void swapService(AuthService newService) {
    DeviceLog.log(
      'CurrentUser',
      'swapService → ${newService.runtimeType} (state=${_state.runtimeType})',
    );
    _service = newService;
  }

  CurrentUserState get state => _state;

  /// main() 挂上的"重新初始化登录后端"动作(解析后端地址 → Supabase.initialize
  /// → 会话恢复 → swapService → bootstrap)。UI 的"重试"按钮和自动重连都只调这个。
  Future<void> Function()? retryInit;
  bool _retryingInit = false;
  bool get isRetryingInit => _retryingInit;

  /// 自动重连退避:抄 gRPC 连接退避协议(1 s ×1.6、±20% 抖动、封顶 120 s、
  /// 成功即复位;B 站 kratos 同参),见 connection_backoff.dart。网络级重试
  /// gotrue 自己做;这里管"后端初始化整体失败"之后的自动再试——大厂 SDK 的
  /// 通用做法(腾讯 IM / 火山 RTC / 微信 Mars 都是断线后 SDK 自动重连,只有
  /// 服务器明确判票据失效/被踢才要用户重新登录)。
  final ConnectionBackoff initBackoff;
  Timer? _autoRetryTimer;
  DateTime? _nextAutoRetryAt;

  /// 下一次自动重试的时刻(不可用态且已排期时非空;供 UI 显示)。
  DateTime? get nextAutoRetryAt => _nextAutoRetryAt;

  /// [manual] = 用户点了"重试":走一次引导态让闪屏文案动起来;自动重连保持
  /// 不可用态静默进行,只把按钮置灰,避免每次退避都闪一下。
  Future<void> retryServiceInit({bool manual = true}) async {
    final r = retryInit;
    if (r == null || _retryingInit) return;
    _cancelAutoRetry();
    _retryingInit = true;
    if (manual) _state = const CurrentUserBootstrapping();
    notifyListeners();
    try {
      await r();
    } finally {
      _retryingInit = false;
      if (_state is! CurrentUserServiceUnavailable) {
        // 成功(到了 signedIn/signedOut):复位退避——gRPC 的"连接被接受即复位"。
        initBackoff.reset();
      }
      notifyListeners();
    }
  }

  /// 登录后端不可用:进入显式失败态(带原因),绝不用假服务顶替;并按退避
  /// 排下一次自动重试。
  void markServiceUnavailable(String reason) {
    DeviceLog.log('CurrentUser', '→ ServiceUnavailable ($reason)');
    _state = CurrentUserServiceUnavailable(reason);
    _scheduleAutoRetry();
    notifyListeners();
  }

  void _scheduleAutoRetry() {
    _cancelAutoRetry();
    if (retryInit == null) return;
    final delay = initBackoff.next();
    _nextAutoRetryAt = DateTime.now().add(delay);
    DeviceLog.log(
      'CurrentUser',
      'auto-retry #${initBackoff.failures} in ${delay.inMilliseconds} ms',
    );
    _autoRetryTimer = Timer(delay, () {
      _autoRetryTimer = null;
      _nextAutoRetryAt = null;
      unawaited(retryServiceInit(manual: false));
    });
  }

  void _cancelAutoRetry() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    _nextAutoRetryAt = null;
  }

  @override
  void dispose() {
    _cancelAutoRetry();
    super.dispose();
  }

  AuthException? get lastError => _lastError;
  bool get isPerformingAuthAction => _isPerformingAuthAction;
  bool get isSignedIn => _state is CurrentUserSignedIn;
  AuthenticatedUser? get signedInUser {
    final s = _state;
    return s is CurrentUserSignedIn ? s.user : null;
  }

  void clearLastError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Called once at app launch. Reads the persisted session and jumps
  /// to signedIn / signedOut. Force-signs-out if idle.
  Future<void> bootstrap() async {
    // [ANALYTICS 2026-08-24] 第一方统计初始化(队列/定时器/生命周期钩子)。
    // init 本身不发任何事件;track 在未登录时是 no-op ⇒ 登录墙即同意门,
    // 注册(同意协议与隐私政策)之前不会有任何统计数据离开设备。
    // 错误钩子链式接管,原 handler 照常执行。
    unawaited(
      PwAnalytics.instance.init().then((_) {
        PwAnalytics.instance.installErrorHandlers();
      }),
    );
    // 后端还没就绪就不"引导":引导到 signedOut 会把登录页亮出来,而此时的
    // 服务连凭据都收不了。保持/进入不可用态,等重试。
    if (_service is UnavailableAuthService) {
      final reason = (_service as UnavailableAuthService).reason;
      markServiceUnavailable('bootstrap: $reason');
      return;
    }
    try {
      final user = await _service.currentUser();
      // ignore: avoid_print
      print(
        '[AUTH-DEBUG] CurrentUser.bootstrap: _service.currentUser() '
        '→ ${user == null ? "null (will go to signedOut)" : "user=${user.email ?? user.id.rawValue}"}',
      );
      if (user == null) {
        await _clearPersistedUserID();
        _logSignedOut('bootstrap: currentUser==null');
        _state = const CurrentUserSignedOut();
        notifyListeners();
        return;
      }
      final idleExpired = await _isIdleExpired();
      // ignore: avoid_print
      print('[AUTH-DEBUG] CurrentUser.bootstrap: isIdleExpired=$idleExpired');
      if (idleExpired) {
        try {
          await _service.signOut();
        } catch (_) {
          /* best effort */
        }
        await _clearIdleTimestamp();
        await _clearPersistedUserID();
        _logSignedOut('bootstrap: idle expired');
        _state = const CurrentUserSignedOut();
        notifyListeners();
        return;
      }
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      notifyListeners();
    } catch (e) {
      _logSignedOut('bootstrap: caught exception: $e');
      _state = const CurrentUserSignedOut();
      notifyListeners();
    }
  }

  /// Called on scene-active transitions from lifecycle observer.
  Future<void> refreshIdleSession() async {
    if (_state is! CurrentUserSignedIn) return;
    if (await _isIdleExpired()) {
      await signOut();
      return;
    }
    await _touchIdleTimestamp();
  }

  Future<void> signIn(SignInRequest request) async {
    await _runAuthAction(() => _service.signIn(request));
  }

  Future<void> signUp(SignUpRequest request) async {
    // Inline (instead of _runAuthAction) so we can surface
    // EmailVerificationPending to the UI: the email/password sign-up
    // form catches it and pushes the OTP verification page.
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.signUp(request);
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
    } on EmailVerificationPending {
      rethrow;
    } on AuthException catch (e) {
      _lastError = e;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Re-issue the 6-digit signup OTP for a pending email account.
  /// Returns true on success; populates `lastError` on failure (so the
  /// OTP page can show "频率太高，稍后再试" / similar).
  ///
  /// Requires the password the user typed at signup. In the strict-
  /// confirmation backend the resend goes through the same Edge
  /// Function as initial signup, which writes (still-unverified) into
  /// pending_signups.
  Future<bool> resendSignupOtp({
    required String email,
    required String password,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      await _service.resendEmailOtp(email: email, password: password);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Verify a 6-digit signup OTP. Promotes state to CurrentUserSignedIn
  /// on success. Sets lastError on failure (caller's UI shows it).
  ///
  /// Requires the password the user typed at signup. The Edge Function
  /// creates the auth.users row server-side, then this method calls
  /// signInWithPassword to obtain the session.
  Future<bool> verifySignupOtp({
    required String email,
    required String token,
    required String password,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.verifyEmailSignupOtp(
        email: email,
        token: token,
        password: password,
      );
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<PhoneVerificationChallenge?> startPhoneVerification(
    String phoneNumber,
  ) async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      final result = await _service.startPhoneVerification(phoneNumber);
      return result;
    } on AuthException catch (e) {
      _lastError = e;
      return null;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return null;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<bool> sendPasswordReset(String email) async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      await _service.sendPasswordReset(email);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Verify the password-reset OTP and rotate to a new password in a
  /// single round trip. On success, the user is signed in (Supabase
  /// recovery verifyOTP issues a session) and we promote state to
  /// CurrentUserSignedIn so AuthGate routes to HomeScreen.
  Future<bool> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.resetPasswordWithOtp(
        email: email,
        token: token,
        newPassword: newPassword,
      );
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      await _service.signOut();
    } catch (_) {
      /* best effort */
    }
    await _clearIdleTimestamp();
    await _clearPersistedUserID();
    _logSignedOut('signOut() called');
    _state = const CurrentUserSignedOut();
    _lastError = null;
    notifyListeners();
  }

  Future<bool> deleteAccount() async {
    _isPerformingAuthAction = true;
    notifyListeners();
    try {
      await _service.deleteAccount();
      await _clearIdleTimestamp();
      await _clearPersistedUserID();
      _logSignedOut('deleteAccount() succeeded');
      _state = const CurrentUserSignedOut();
      _lastError = null;
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Update the signed-in user's display name. Returns true on success
  /// (local state refreshed + listeners notified); false on failure
  /// (caller can read [lastError] for the user-facing reason). No-op +
  /// false if there's no signed-in user.
  Future<bool> updateDisplayName(String displayName) async {
    if (signedInUser == null) return false;
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final updated = await _service.updateDisplayName(displayName);
      _state = CurrentUserSignedIn(updated);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  /// Set the unique handle. Returns true on success; false on failure
  /// (caller reads [lastError]: "该 ID 已被使用" / "改名太频繁,请 N 天后再试" /
  /// "该名称可能被误认为官方身份" 都从这条路上来).
  ///
  /// 与 [updateDisplayName] 不同,这里不刷新本地状态 —— handle 不属于
  /// AuthenticatedUser(后者由 auth session 的 metadata 构造,而 handle 存在
  /// public.profiles)。设置页在成功后重新走 MeStatsViewModel 读回。
  Future<bool> updateHandle(String handle) async {
    if (signedInUser == null) return false;
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      await _service.updateHandle(handle);
      return true;
    } on AuthException catch (e) {
      _lastError = e;
      return false;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
      return false;
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────

  Future<void> _runAuthAction(
    Future<AuthenticatedUser> Function() action,
  ) async {
    _isPerformingAuthAction = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await action();
      await _touchIdleTimestamp();
      await _persistUserID(user.id.rawValue);
      _state = CurrentUserSignedIn(user);
    } on AuthException catch (e) {
      _lastError = e;
    } catch (e) {
      _lastError = AuthException(AuthErrorKind.unknown, e.toString());
    } finally {
      _isPerformingAuthAction = false;
      notifyListeners();
    }
  }

  Future<bool> _isIdleExpired() async {
    final prefs = await AetherPrefs.getInstance();
    final lastMs =
        (await prefs.getInt(AuthPersistenceKeys.lastActivityAt)) ?? 0;
    if (lastMs <= 0) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (nowMs - lastMs) > idleSignOutInterval.inMilliseconds;
  }

  Future<void> _touchIdleTimestamp() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.setInt(
      AuthPersistenceKeys.lastActivityAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _clearIdleTimestamp() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.remove(AuthPersistenceKeys.lastActivityAt);
  }

  static Future<void> _persistUserID(String uid) async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.setString(AuthPersistenceKeys.currentUserID, uid);
  }

  static Future<void> _clearPersistedUserID() async {
    final prefs = await AetherPrefs.getInstance();
    await prefs.remove(AuthPersistenceKeys.currentUserID);
  }

  /// Synchronous read of the persisted user ID for modules that need
  /// to scope per-user storage at allocation time. Returns null if no
  /// one's signed in. Prefer this over awaiting CurrentUser.
  static Future<String?> readPersistedUserID() async {
    final prefs = await AetherPrefs.getInstance();
    return prefs.getString(AuthPersistenceKeys.currentUserID);
  }
}
