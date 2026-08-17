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
      } catch (_) {/* user already deleted; local state cleared by caller */}
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
    try {
      // Supabase persists this into auth.users.raw_user_meta_data
      // (JSONB). The same `display_name` key is what `_wrap` already
      // reads at sign-in time, so subsequent sessions / reloads pick up
      // the new value without a separate cache.
      final res = await _client.auth.updateUser(
        UserAttributes(data: {'display_name': displayName}),
      );
      final user = res.user;
      if (user == null) {
        throw const AuthException(
          AuthErrorKind.unknown,
          'updateUser returned no user after display-name update',
        );
      }
      // Phase 5: mirror into public.profiles so the community feed
      // (which JOINs works → profiles for the author handle) shows
      // the new name immediately for all this user's previously-
      // published works. Without this mirror, profiles.display_name
      // stays at the signup-time value until the SQL trigger from
      // migration 20260510000000 fires server-side. RLS policy
      // `profiles_update_self` (migration 20260429020000:78) allows
      // the signed-in user to update their own row.
      // Non-fatal: if this UPDATE fails (RLS misconfig / network
      // blip), we still surface success because auth.users is the
      // canonical store; the server-side UPDATE trigger acts as
      // backup.
      try {
        await _client
            .from('profiles')
            .update({'display_name': displayName})
            .eq('id', user.id);
      } catch (e) {
        // ignore: avoid_print
        print(
          '[SupabaseAuthService] profiles display_name mirror '
          'update failed (non-fatal): $e',
        );
      }
      return _wrap(user);
    } on AuthApiException catch (e) {
      throw AuthException(_mapAuthApi(e), e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException(AuthErrorKind.unknown, e.toString());
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
