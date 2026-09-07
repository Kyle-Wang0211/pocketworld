// 2026-09-07 用户裁决:登录后端异常时必须显示失败并可重试,不得回退成假登录。
// 这组测试钉住三件事:
//   1. UnavailableAuthService 没有用户、任何登录动作抛 providerUnavailable;
//   2. CurrentUser 在不可用服务上 bootstrap 进入 ServiceUnavailable(不是
//      signedOut ⇒ 登录表单不会亮出来);重试走 retryInit 并能换成真服务;
//   3. main.dart 源码不再引用 MockAuthServiceImpl(源码契约)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/auth/auth_error.dart';
import 'package:pocketworld_flutter/auth/auth_models.dart';
import 'package:pocketworld_flutter/auth/auth_service.dart';
import 'package:pocketworld_flutter/auth/current_user.dart';
import 'package:pocketworld_flutter/auth/mock_auth_service.dart';
import 'package:pocketworld_flutter/auth/unavailable_auth_service.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // bootstrap() 里 unawaited 的第一方统计 init 会碰 SharedPreferences。
    SharedPreferences.setMockInitialValues({});
  });

  group('UnavailableAuthService', () {
    const svc = UnavailableAuthService('backend down');

    test('has no current user', () async {
      expect(await svc.currentUser(), isNull);
    });

    test(
      'signIn / signUp / otp / reset all throw providerUnavailable',
      () async {
        final actions = <Future<Object?> Function()>[
          () => svc.signIn(
            const SignInRequest.email(email: 'a@b.c', password: 'x'),
          ),
          () => svc.sendPasswordReset('a@b.c'),
          () => svc.resendEmailOtp(email: 'a@b.c', password: 'x'),
          () => svc.verifyEmailSignupOtp(
            email: 'a@b.c',
            token: '000000',
            password: 'x',
          ),
          () => svc.resetPasswordWithOtp(
            email: 'a@b.c',
            token: '000000',
            newPassword: 'y',
          ),
          () => svc.updateDisplayName('n'),
          () => svc.updateHandle('h'),
          () => svc.deleteAccount(),
        ];
        for (final a in actions) {
          await expectLater(
            a(),
            throwsA(
              isA<AuthException>().having(
                (e) => e.kind,
                'kind',
                AuthErrorKind.providerUnavailable,
              ),
            ),
          );
        }
      },
    );

    test('signOut is a no-op', () async {
      await svc.signOut();
    });
  });

  group('CurrentUser with unavailable backend', () {
    test('bootstrap → ServiceUnavailable, never signedOut', () async {
      final cu = CurrentUser(service: const UnavailableAuthService('init'));
      await cu.bootstrap();
      expect(cu.state, isA<CurrentUserServiceUnavailable>());
      expect(
        (cu.state as CurrentUserServiceUnavailable).reason,
        contains('init'),
      );
    });

    test('markServiceUnavailable carries the reason and notifies', () {
      final cu = CurrentUser(service: const UnavailableAuthService());
      var notified = 0;
      cu.addListener(() => notified++);
      cu.markServiceUnavailable('Supabase.initialize: timeout');
      expect(cu.state, isA<CurrentUserServiceUnavailable>());
      expect(
        (cu.state as CurrentUserServiceUnavailable).reason,
        'Supabase.initialize: timeout',
      );
      expect(notified, 1);
    });

    test(
      'retryServiceInit runs retryInit and can reach signedOut/signedIn',
      () async {
        final cu = CurrentUser(service: const UnavailableAuthService());
        await cu.bootstrap();
        expect(cu.state, isA<CurrentUserServiceUnavailable>());

        var calls = 0;
        cu.retryInit = () async {
          calls++;
          // 模拟后端就绪:换成一个真会回答的服务再 bootstrap。
          cu.swapService(_SignedOutService());
          await cu.bootstrap();
        };
        final states = <Type>[];
        cu.addListener(() => states.add(cu.state.runtimeType));

        await cu.retryServiceInit();
        expect(calls, 1);
        expect(states.first, CurrentUserBootstrapping);
        expect(cu.state, isA<CurrentUserSignedOut>());
        expect(cu.isRetryingInit, isFalse);
      },
    );

    test('retryServiceInit without a hook is a no-op', () async {
      final cu = CurrentUser(service: const UnavailableAuthService());
      await cu.bootstrap();
      await cu.retryServiceInit();
      expect(cu.state, isA<CurrentUserServiceUnavailable>());
    });

    test('a failing retry lands back in ServiceUnavailable', () async {
      final cu = CurrentUser(service: const UnavailableAuthService());
      await cu.bootstrap();
      cu.retryInit = () async {
        cu.markServiceUnavailable('still down');
      };
      await cu.retryServiceInit();
      expect(cu.state, isA<CurrentUserServiceUnavailable>());
      expect((cu.state as CurrentUserServiceUnavailable).reason, 'still down');
    });
  });

  group('source contract', () {
    test('main.dart never falls back to MockAuthServiceImpl', () {
      final src = File('lib/main.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, isNot(contains('MockAuthServiceImpl')));
      expect(code, isNot(contains('mock_auth_service.dart')));
      expect(code, contains('UnavailableAuthService'));
      expect(code, contains('markServiceUnavailable'));
    });

    test(
      'MockAuthServiceImpl still accepts anything (why it must not ship)',
      () async {
        // 说明性断言:这就是"假登录"——任何凭据都过。生产 main 不得再持有它。
        final mock = MockAuthServiceImpl();
        final u = await mock.signIn(
          const SignInRequest.email(email: 'nobody@example.com', password: '?'),
        );
        expect(u.id.rawValue, startsWith('mock_'));
      },
    );
  });
}

/// 一个"真会回答"的服务:没有已登录用户 ⇒ 正常引导到 signedOut。
/// 故意**不是** UnavailableAuthService 的子类(bootstrap 按类型区分)。
class _SignedOutService implements AuthService {
  @override
  Future<AuthenticatedUser?> currentUser() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
