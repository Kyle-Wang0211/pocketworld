// 2026-09-07:登录后端不可用时,登录门必须显示失败 + 重试,**不显示登录表单**。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/auth/current_user.dart';
import 'package:pocketworld_flutter/auth/unavailable_auth_service.dart';
import 'package:pocketworld_flutter/i18n/locale_notifier.dart';
import 'package:pocketworld_flutter/main.dart';
import 'package:pocketworld_flutter/ui/auth/auth_root_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AuthGate shows failure + retry, never the sign-in form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 不走 bootstrap()(它会拉起统计定时器);直接进入不可用态,和 main 里
    // Supabase.initialize 失败/超时后的状态一致。
    final currentUser = CurrentUser(service: const UnavailableAuthService())
      ..markServiceUnavailable('Supabase.initialize: TimeoutException');
    var retries = 0;
    currentUser.retryInit = () async {
      retries++;
      currentUser.markServiceUnavailable('still down');
    };

    await tester.pumpWidget(
      PocketWorldApp(
        currentUser: currentUser,
        localeNotifier: LocaleNotifier(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    expect(find.byType(AuthRootView), findsNothing);
    expect(find.textContaining('Supabase.initialize'), findsOneWidget);
    final retry = find.byType(FilledButton);
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(retries, 1);
    expect(find.byType(AuthRootView), findsNothing);
    expect(find.textContaining('still down'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    // 失败后按 gRPC 退避排了自动重试(1 s 起);推进时间让它真的自己再试。
    expect(currentUser.nextAutoRetryAt, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, greaterThanOrEqualTo(2));
    expect(find.byType(AuthRootView), findsNothing);
    currentUser.dispose();
  });
}
