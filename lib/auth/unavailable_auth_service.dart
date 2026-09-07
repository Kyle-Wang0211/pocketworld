// unavailable_auth_service.dart — 生产启动期/后端不可达时的**显式失败**登录服务。
//
// 2026-09-07 用户裁决:服务异常时必须显示失败并可重试,**不得回退成假登录**。
// 此前 main() 在 Supabase 初始化失败/超时时"继续用 MockAuthServiceImpl",而
// Mock 不校验任何凭据、直接造一个 `mock_<email>` 本地用户 —— 未命名(18) 那场
// 用户就是这样"登进"了一个服务器不认识的假账号。
//
// 这个实现的全部行为就是:没有用户、任何登录/注册/改资料动作都抛
// AuthErrorKind.providerUnavailable,交给 UI 显示失败与重试。
import 'auth_error.dart';
import 'auth_models.dart';
import 'auth_service.dart';

class UnavailableAuthService implements AuthService {
  const UnavailableAuthService([this.reason = 'auth backend not ready']);

  final String reason;

  Never _unavailable() =>
      throw AuthException(AuthErrorKind.providerUnavailable, reason);

  @override
  Future<AuthenticatedUser?> currentUser() async => null;

  @override
  Future<AuthenticatedUser> signIn(SignInRequest request) async =>
      _unavailable();

  @override
  Future<AuthenticatedUser> signUp(SignUpRequest request) async =>
      _unavailable();

  @override
  Future<PhoneVerificationChallenge> startPhoneVerification(
    String phoneNumber,
  ) async => _unavailable();

  @override
  Future<void> sendEmailVerification() async => _unavailable();

  @override
  Future<void> resendEmailOtp({
    required String email,
    required String password,
  }) async => _unavailable();

  @override
  Future<AuthenticatedUser> verifyEmailSignupOtp({
    required String email,
    required String token,
    required String password,
  }) async => _unavailable();

  @override
  Future<void> sendPasswordReset(String email) async => _unavailable();

  @override
  Future<AuthenticatedUser> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  }) async => _unavailable();

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async => _unavailable();

  @override
  Future<AuthenticatedUser> updateDisplayName(String displayName) async =>
      _unavailable();

  @override
  Future<void> updateHandle(String handle) async => _unavailable();
}
