import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/aether_prefs.dart';
import 'package:pocketworld_flutter/auth/auth_models.dart';
import 'package:pocketworld_flutter/auth/current_user.dart';
import 'package:pocketworld_flutter/auth/mock_auth_service.dart';
import 'package:pocketworld_flutter/i18n/locale_notifier.dart';
import 'package:pocketworld_flutter/main.dart';
import 'package:pocketworld_flutter/ui/auth/auth_root_view.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aether_texture');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.invalid',
      anonKey: 'test-anon-key',
    );
  });

  setUp(() {
    AetherPrefs.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createSharedNativeTexture') {
            throw MissingPluginException();
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('AuthGate boots to sign-in when no session is persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final currentUser = CurrentUser(service: MockAuthServiceImpl());
    await currentUser.bootstrap();

    await tester.pumpWidget(
      PocketWorldApp(
        currentUser: currentUser,
        localeNotifier: LocaleNotifier(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    expect(find.byType(AuthRootView), findsOneWidget);
  });

  testWidgets('CurrentUser enters signed-in state after signIn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = MockAuthServiceImpl();
    final currentUser = CurrentUser(service: service);
    await currentUser.bootstrap();

    await tester.pumpWidget(
      PocketWorldApp(
        currentUser: currentUser,
        localeNotifier: LocaleNotifier(),
      ),
    );
    // Let the splash min-duration + auth state transitions settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    // Sign in (mock), then wait for state propagation.
    await currentUser.signIn(
      const SignInRequest.email(email: 'test@aether3d.app', password: '123456'),
    );

    expect(currentUser.isSignedIn, isTrue);
  });
}
