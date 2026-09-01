// Supabase implementation of the lib/auth/AuthService contract.
// Replaces the Firebase implementation 2026-04-28. UI layer doesn't
// change — it still talks to AuthService through the sealed
// SignInRequest / SignUpRequest types.
//
// Wiring:
//   • Supabase.initialize(url, anonKey) called once in main.dart before
//     anything else.
//   • CurrentUser holds an instance of this and dispatches to it.
//   • Phone OTP is wired through Supabase's signInWithOtp (channel:sms).
//
// Errors: every failure path maps to AuthException with a typed
// AuthErrorKind. The detail string stays in English (Supabase's
// upstream message) — UI shows the localized message from
// AuthException.message.

// Hide Supabase's own AuthException so our app-level AuthException is
// the only one that compiles into call sites. We catch the underlying
// Supabase errors via AuthApiException (still imported below) and
// re-throw as the app type with a typed AuthErrorKind.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

import '../i18n/locale_notifier.dart';
import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';

class SupabaseAuthServiceImpl implements AuthService {
  final SupabaseClient _client;
  // When wired through main.dart, signUp passes the user's current UI
  // locale ('zh' or 'en') in user_metadata.locale so the Supabase email
  // template can branch on `{{ if eq .Data.locale "zh" }}`. Optional so
  // tests can construct without one.
  final LocaleNotifier? _localeNotifier;

  SupabaseAuthServiceImpl({
    SupabaseClient? client,
    LocaleNotifier? localeNotifier,
  }) : _client = client ?? Supabase.instance.client,
       _localeNotifier = localeNotifier;

  @override
  Future<AuthenticatedUser?> currentUser() async {
    final session = _client.auth.currentSession;
    final user = session?.user;
    if (user == null) return null;
    return _wrap(user);
  }

  @override
  Future<AuthenticatedUser> signIn(SignInRequest request) async {
    try {
      switch (request) {
        case SignInRequestEmail(email: final email, password: final pw):
          final res = await _signInWithPasswordWithWarmRetry(
            email: email,
            password: pw,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidCredentials);
          }
          return _wrap(user);

        case SignInRequestPhone(phoneNumber: final phone, code: final code):
          final res = await _client.auth.verifyOTP(
            phone: phone,
            token: code,
            type: OtpType.sms,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidVerificationCode);
          }
          return _wrap(user);
      }
    } on AuthRetryableFetchException catch (e) {
      throw AuthException(AuthErrorKind.network, e.message);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      final recovered = _client.auth.currentUser;
      if (recovered != null) return _wrap(recovered);
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  Future<AuthResponse> _signInWithPasswordWithWarmRetry({
    required String email,
    required String password,
  }) async {
    try {
      return await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } on AuthRetryableFetchException catch (e) {
      debugPrint(
        '[SupabaseAuthService] first signInWithPassword fetch failed; '
        'retrying once: ${e.message}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return _client.auth.signInWithPassword(email: email, password: password);
    }
  }

  @override
  Future<AuthenticatedUser> signUp(SignUpRequest request) async {
    try {
      switch (request) {
        case SignUpRequestEmail(
          email: final email,
          password: final pw,
          displayName: final name,
        ):
          // Strict-confirmation flow. The signup-start Edge Function
          // writes a row into pending_signups and emails an OTP — it
          // does NOT touch auth.users. The real auth.users row is
          // created server-side at OTP verification time
          // (verifyEmailSignupOtp). The password is held in
          // EmailVerificationPending so the OTP page can call
          // signInWithPassword once the row exists; without it, we'd
          // have to ask the user to retype their password.
          await _client.functions.invoke(
            'signup-start',
            body: {
              'email': email,
              'password': pw,
              'display_name': ?name,
              'locale': _localeNotifier?.locale.languageCode ?? 'en',
            },
          );
          throw EmailVerificationPending(email, pw);

        case SignUpRequestPhone(
          phoneNumber: final phone,
          code: final code,
          displayName: final name,
        ):
          // Phone path unchanged — Supabase's native verifyOTP on a
          // never-seen phone creates the user in one shot, no
          // pending_signups detour needed.
          final res = await _client.auth.verifyOTP(
            phone: phone,
            token: code,
            type: OtpType.sms,
          );
          final user = res.user;
          if (user == null) {
            throw const AuthException(AuthErrorKind.invalidVerificationCode);
          }
          if (name != null) {
            await _client.auth.updateUser(
              UserAttributes(data: {'display_name': name}),
            );
          }
          return _wrap(user);
      }
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } on EmailVerificationPending {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<PhoneVerificationChallenge> startPhoneVerification(
    String phoneNumber,
  ) async {
    try {
      await _client.auth.signInWithOtp(phone: phoneNumber);
      return PhoneVerificationChallenge(
        // Supabase does not return a server-side verification ID; the
        // pair (phone, code) is enough for verifyOTP. Pass the phone
        // back as the handle so callers can keep the same shape as
        // Firebase did.
        verificationID: phoneNumber,
        phoneNumber: phoneNumber,
      );
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> sendEmailVerification() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    final email = user.email;
    if (email == null) {
      throw const AuthException(
        AuthErrorKind.unknown,
        'User has no email on file',
      );
    }
    try {
      await _client.auth.resend(type: OtpType.signup, email: email);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> resendEmailOtp({
    required String email,
    required String password,
  }) async {
    try {
      // signup-start is idempotent on email: upserts pending_signups,
      // rotates the OTP, resets attempts to zero, sends a fresh email.
      await _client.functions.invoke(
        'signup-start',
        body: {
          'email': email,
          'password': password,
          'locale': _localeNotifier?.locale.languageCode ?? 'en',
        },
      );
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<AuthenticatedUser> verifyEmailSignupOtp({
    required String email,
    required String token,
    required String password,
  }) async {
    try {
      await _client.functions.invoke(
        'signup-verify',
        body: {'email': email, 'otp': token},
      );
      // The Edge Function just created the auth.users row pre-confirmed
      // (email_confirm: true). Sign in with the password the user
      // typed at the start of signup — yields a real Supabase session
      // identical to a normal email/password login.
      final res = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final user = res.user;
      if (user == null) {
        throw const AuthException(
          AuthErrorKind.unknown,
          'signInWithPassword returned no user after signup-verify',
        );
      }
      return _wrap(user);
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      // Strict-OTP reset, mirroring the signup flow. password-reset-start
      // looks up the user, generates an OTP, stores hash in
      // pending_password_resets, and emails the OTP via Resend with
      // locale-aware copy. Existing-vs-nonexisting emails are
      // indistinguishable to the caller (silent success either way).
      await _client.functions.invoke(
        'password-reset-start',
        body: {
          'email': email,
          'locale': _localeNotifier?.locale.languageCode ?? 'en',
        },
      );
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<AuthenticatedUser> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    try {
      // 1. Have the Edge Function verify the OTP and rotate the
      // password via admin.updateUserById (server-side, bypasses RLS).
      await _client.functions.invoke(
        'password-reset-verify',
        body: {'email': email, 'otp': token, 'new_password': newPassword},
      );
      // 2. Sign in with the freshly-rotated password — yields a real
      // Supabase session identical to a normal email/password login.
      final res = await _client.auth.signInWithPassword(
        email: email,
        password: newPassword,
      );
      final user = res.user;
      if (user == null) {
        throw const AuthException(
          AuthErrorKind.unknown,
          'signInWithPassword returned no user after password-reset-verify',
        );
      }
      return _wrap(user);
    } on FunctionException catch (e) {
      throw _mapFunctionException(e);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      // signOut failures are best-effort — we still wipe local state.
      // (Network outage shouldn't trap the user signed-in.)
    }
  }

  @override
  Future<void> deleteAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    try {
      // App Store Guideline 5.1.1(v) requires deletion to be initiable
      // from inside the app, and to actually remove the account plus its
      // personal data — deactivating is explicitly not enough, and Apple
      // forbids routing users through an email/support flow for this.
      //
      // The anon-key client can't self-delete, so this calls the
      // delete-account Edge Function, which runs as service_role. It
      // enumerates every storage object the user owns (including orphans
      // found by prefix sweep, and quarantined assets from any taken-down
      // works) BEFORE deleting auth.users — the delete cascades across
      // every business table, after which those paths would be
      // unrecoverable. See supabase/functions/delete-account/index.ts.
      //
      // `confirm: true` is required by the function so a stray call can't
      // destroy an account; the UI gates on its own confirmation dialog
      // before we ever get here.
      final res = await _client.functions.invoke(
        'delete-account',
        body: const {'confirm': true},
      );
      if (res.status != 200) {
        final data = res.data;
        final code = data is Map ? data['error']?.toString() : null;
        throw AuthException(
          AuthErrorKind.providerUnavailable,
          'Account deletion failed (${res.status}${code == null ? '' : ': $code'}).',
        );
      }
      // The account is gone server-side; drop the local session too.
      // signOut() may itself fail now that the user no longer exists —
      // that must not turn a successful deletion into a reported
      // failure, so it is best-effort.
      try {
        await _client.auth.signOut();
      } catch (_) {
        /* user already deleted; local state cleared by caller */
      }
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<AuthenticatedUser> updateDisplayName(String displayName) async {
    final current = _client.auth.currentUser;
    if (current == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    // [NAME-CHOKEPOINT 2026-08-23] 改名从"客户端直写"改为"只调 Edge Function"。
    //
    // 之前这里做两件事,两件都已经不成立:
    //   1. `auth.updateUser({display_name})` —— 写 auth.users.raw_user_meta_data。
    //      这条路 RLS 关不掉(是 Supabase Auth 的内置能力),原先靠迁移
    //      20260510000000 的 SECURITY DEFINER 触发器把它同步进 profiles,
    //      于是任何客户端都能绕过全部校验把任意字符串送进 feed 展示的那一列。
    //      迁移 20260823010000 已删掉那个触发器。
    //   2. `from('profiles').update({display_name})` —— 同一迁移加的列级守卫
    //      guard_profile_identity_columns 会对 authenticated 角色抛 42501。
    //      而旧代码把这一步的异常 catch 成 non-fatal 只 print 一行 ⇒ 用户会看到
    //      "改名成功"而 feed 纹丝不动。这正是必须同批替换掉它的原因。
    //
    // 现在唯一入口是 set-profile-name(service_role),它按固定顺序做:
    //   RFC 8266 enforce → 字素簇长度 → 保留词 → 改名冷却 → 写 profiles
    //   → 同步 auth metadata → 审计
    try {
      final res = await _client.functions.invoke(
        'set-profile-name',
        body: <String, dynamic>{'display_name': displayName},
      );
      final data = res.data;
      final newName = (data is Map ? data['display_name'] as String? : null);
      // CurrentUser.updateDisplayName 直接拿这个返回值当新的本地状态
      // (current_user.dart:357 `_state = CurrentUserSignedIn(updated)`),
      // 所以不需要 refreshSession —— 服务端返回的就是权威值。
      return AuthenticatedUser(
        id: InternalUserID(current.id),
        email: current.email,
        phone: current.phone,
        displayName: newName ?? displayName,
      );
    } on FunctionException catch (e) {
      throw _mapSetProfileName(e);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  @override
  Future<void> updateHandle(String handle) async {
    final current = _client.auth.currentUser;
    if (current == null) {
      throw const AuthException(AuthErrorKind.notSignedIn);
    }
    try {
      await _client.functions.invoke(
        'set-profile-name',
        body: <String, dynamic>{'handle': handle},
      );
    } on FunctionException catch (e) {
      throw _mapSetProfileName(e);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
    }
  }

  /// 把 set-profile-name 的非 2xx 响应翻译成 UI 能直接显示的话。
  ///
  /// UI 走的是 `l.meDisplayNameUpdateFailed(err)`,err 取自
  /// AuthException.message —— 所以这里的文案会原样出现在用户眼前。
  ///
  /// ⚠️ 文案暂时硬编码在这一层。正确的位置是 l10n,但 app_zh.arb /
  ///    app_en.arb 及其生成物当前有未提交改动(属于另一条工作线),
  ///    不能碰。等那条线落地后把这些串搬进 l10n。
  AuthException _mapSetProfileName(FunctionException e) {
    final d = e.details;
    final code = (d is Map ? d['error']?.toString() : null) ?? '';
    final reason = (d is Map ? d['reason']?.toString() : null) ?? '';
    switch (code) {
      case 'cooldown':
        final ms = (d is Map ? d['retry_after_ms'] : null);
        final days = ms is num ? (ms / 86400000).ceil() : 3;
        return AuthException(AuthErrorKind.rateLimited, '改名太频繁,请 $days 天后再试');
      case 'rate_limited':
        return const AuthException(AuthErrorKind.rateLimited, '操作过于频繁,请稍后再试');
      case 'reserved_name':
        final kind = (d is Map ? d['kind']?.toString() : null) ?? '';
        return AuthException(
          AuthErrorKind.unknown,
          kind == 'impersonation' ? '该名称可能被误认为官方身份' : '该名称需要进一步核验',
        );
      case 'invalid_display_name':
        return AuthException(AuthErrorKind.unknown, switch (reason) {
          'too_long' => '名字太长了',
          'empty_after_enforcement' => '名字不能为空',
          'control_character' ||
          'ignorable_character' ||
          'unassigned_or_surrogate' => '名字含有不可见或非法字符',
          _ => '名字格式不正确',
        });
      case 'invalid_handle':
        return AuthException(AuthErrorKind.unknown, switch (reason) {
          'too_short' => 'ID 太短了',
          'too_long' => 'ID 太长了',
          'bad_charset' => 'ID 只能用小写字母、数字、点和下划线',
          'bad_edge' => 'ID 不能以点或下划线开头/结尾',
          'repeated_punct' => 'ID 不能有连续的点或下划线',
          'looks_like_file' => 'ID 不能像文件名',
          _ => 'ID 格式不正确',
        });
      case 'handle_taken':
        return const AuthException(AuthErrorKind.unknown, '该 ID 已被使用');
      case 'profile_not_found':
        return const AuthException(AuthErrorKind.unknown, '找不到你的资料');
      default:
        return AuthException(
          AuthErrorKind.unknown,
          code.isEmpty ? 'http_${e.status}' : code,
        );
    }
  }

  // ─── helpers ─────────────────────────────────────────────────────

  AuthenticatedUser _wrap(User user) {
    final meta = user.userMetadata ?? const {};
    final display =
        meta['display_name'] as String? ??
        meta['full_name'] as String? ??
        meta['name'] as String?;
    return AuthenticatedUser(
      id: InternalUserID(user.id),
      email: user.email,
      phone: user.phone,
      displayName: display,
    );
  }

  /// Maps a non-2xx response from our signup-start / signup-verify
  /// Edge Functions onto the AuthException surface the UI already
  /// understands. The Edge Functions return JSON like `{"error": "..."}`
  /// — supabase-flutter parses it into `e.details` as a Map.
  AuthException _mapFunctionException(FunctionException e) {
    final details = e.details;
    String code = '';
    if (details is Map) {
      code = (details['error']?.toString() ?? '').toLowerCase();
    } else if (details is String) {
      code = details.toLowerCase();
    }
    switch (e.status) {
      case 400:
        // password-reset-verify returns 400 weak_password for too-short
        // new passwords; other 400s are validation errors that should
        // never happen given client-side gating.
        if (code == 'weak_password') {
          return const AuthException(AuthErrorKind.weakPassword);
        }
        return AuthException(AuthErrorKind.unknown, 'bad_request: $code');
      case 401:
      case 404:
      case 410:
        // 401 = wrong code, 404 = no pending row (probably reaped),
        // 410 = expired. UI message ("验证码错误或已过期") covers all.
        return AuthException(AuthErrorKind.invalidVerificationCode, code);
      case 409:
        return const AuthException(AuthErrorKind.accountAlreadyExists);
      case 429:
        return const AuthException(AuthErrorKind.rateLimited);
      case 502:
        return AuthException(AuthErrorKind.providerUnavailable, code);
      default:
        return AuthException(
          AuthErrorKind.unknown,
          'edge function ${e.status}${code.isEmpty ? '' : ': $code'}',
        );
    }
  }

  AuthErrorKind _mapAuthApi(AuthApiException e) {
    final code = e.code?.toLowerCase() ?? '';
    final msg = e.message.toLowerCase();
    if (code.contains('invalid_credentials') ||
        msg.contains('invalid login') ||
        msg.contains('invalid password')) {
      return AuthErrorKind.invalidCredentials;
    }
    if (code.contains('user_already_exists') ||
        msg.contains('already registered') ||
        msg.contains('already exists')) {
      return AuthErrorKind.accountAlreadyExists;
    }
    if (code.contains('weak_password') || msg.contains('password')) {
      return AuthErrorKind.weakPassword;
    }
    if (code.contains('over_request_rate_limit') ||
        msg.contains('rate limit') ||
        msg.contains('too many')) {
      return AuthErrorKind.rateLimited;
    }
    if (code.contains('otp') ||
        msg.contains('otp') ||
        msg.contains('expired') ||
        msg.contains('verification code')) {
      return AuthErrorKind.invalidVerificationCode;
    }
    if (code.contains('network') || msg.contains('network')) {
      return AuthErrorKind.network;
    }
    return AuthErrorKind.unknown;
  }
}
