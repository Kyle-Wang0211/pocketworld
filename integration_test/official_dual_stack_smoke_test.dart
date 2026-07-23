import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocketworld_flutter/official_aether_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const officialARKit = MethodChannel('pocketworld_official_arkit');

  testWidgets('official Swift transport and native image are independent', (
    tester,
  ) async {
    expect(
      await officialARKit.invokeMethod<bool>('isAvailable'),
      isTrue,
      reason: 'OfficialAetherARKitPlugin must be registered on a real device',
    );

    final library = OfficialAetherFfi.resolveLibraryForBindings();
    expect(
      library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'pwofficial_options_default',
      ),
      isNotNull,
    );
    expect(
      () => library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'pwsfm_options_default',
      ),
      throwsA(isA<ArgumentError>()),
      reason: 'The official framework must not expose the self-route ABI',
    );
  });
}
