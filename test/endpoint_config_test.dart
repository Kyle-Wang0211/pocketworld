// Tests for lib/config/endpoint_config.dart.
//
// The security-relevant assertions are the `isAcceptable` ones: that
// method is the only thing standing between a spoofed config response
// and the app sending its auth traffic to an attacker's host.

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/aether_prefs.dart';
import 'package:pocketworld_flutter/config/endpoint_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AetherPrefs.setMockInitialValues({});
  });

  group('isAcceptable', () {
    test('accepts an https URL on an allow-listed host', () {
      expect(
        EndpointConfigResolver.isAcceptable(
          'https://tzvwkqmgaourwqrmxbyb.supabase.co',
          'some-anon-key',
        ),
        isTrue,
      );
    });

    test('rejects plain http even on an allow-listed host', () {
      expect(
        EndpointConfigResolver.isAcceptable(
          'http://tzvwkqmgaourwqrmxbyb.supabase.co',
          'some-anon-key',
        ),
        isFalse,
      );
    });

    test('rejects a host outside the allow list', () {
      expect(
        EndpointConfigResolver.isAcceptable(
          'https://evil.example.com',
          'some-anon-key',
        ),
        isFalse,
      );
    });

    test('rejects a host that only embeds an allowed suffix', () {
      // `.supabase.co.evil.com` must not pass a naive "contains" check.
      expect(
        EndpointConfigResolver.isAcceptable(
          'https://x.supabase.co.evil.com',
          'some-anon-key',
        ),
        isFalse,
      );
    });

    test('rejects an empty anon key', () {
      expect(
        EndpointConfigResolver.isAcceptable(
          'https://tzvwkqmgaourwqrmxbyb.supabase.co',
          '   ',
        ),
        isFalse,
      );
    });

    test('rejects an unparseable URL', () {
      expect(
        EndpointConfigResolver.isAcceptable('not a url', 'some-anon-key'),
        isFalse,
      );
    });
  });

  group('resolve', () {
    test(
      'falls back to the built-in constants with no cache and no endpoints',
      () async {
        final cfg = await EndpointConfigResolver.resolve();
        expect(cfg.source, EndpointConfigSource.builtin);
        expect(cfg.supabaseUrl, EndpointConfigResolver.builtinUrl);
        expect(cfg.supabaseAnonKey, EndpointConfigResolver.builtinAnonKey);
      },
    );

    test('prefers a valid cached endpoint over the built-in', () async {
      AetherPrefs.setMockInitialValues({
        'flutter.endpoint_config.supabase_url':
            'https://cached-project.supabase.co',
        'flutter.endpoint_config.supabase_anon_key': 'cached-key',
        'flutter.endpoint_config.fetched_at_ms':
            DateTime.now().millisecondsSinceEpoch,
      });

      final cfg = await EndpointConfigResolver.resolve();
      expect(cfg.source, EndpointConfigSource.cache);
      expect(cfg.supabaseUrl, 'https://cached-project.supabase.co');
      expect(cfg.supabaseAnonKey, 'cached-key');
    });

    test('ignores a cached endpoint that fails validation', () async {
      // A cache poisoned with a disallowed host must not be trusted just
      // because it is already on disk.
      AetherPrefs.setMockInitialValues({
        'flutter.endpoint_config.supabase_url': 'https://evil.example.com',
        'flutter.endpoint_config.supabase_anon_key': 'cached-key',
        'flutter.endpoint_config.fetched_at_ms':
            DateTime.now().millisecondsSinceEpoch,
      });

      final cfg = await EndpointConfigResolver.resolve();
      expect(cfg.source, EndpointConfigSource.builtin);
      expect(cfg.supabaseUrl, EndpointConfigResolver.builtinUrl);
    });

    test('never throws and always yields a usable URL', () async {
      final cfg = await EndpointConfigResolver.resolve();
      expect(cfg.supabaseUrl, isNotEmpty);
      expect(cfg.supabaseAnonKey, isNotEmpty);
      expect(Uri.parse(cfg.supabaseUrl).scheme, 'https');
    });
  });
}
