// Keychain-backed session storage for Supabase auth, with a one-time
// migration off the plaintext default.
//
// ── The problem ─────────────────────────────────────────────────────────
// `Supabase.initialize` without a custom `localStorage` persists the
// session through `SharedPreferencesLocalStorage`, which on iOS is
// `UserDefaults`. That means the session JSON — INCLUDING the long-lived
// refresh_token — sits in plaintext in the app's preferences plist:
//
//   • not in the Keychain, so it has no Keychain ACL protection;
//   • included in unencrypted iTunes/Finder and iCloud backups, so the
//     token leaves the device with the backup;
//   • trivially readable on a jailbroken device or by forensic tooling.
//
// A refresh_token is enough to mint fresh access tokens indefinitely
// (Supabase refresh tokens do not expire; they are single-use but rotate),
// so leaking one is equivalent to a durable account takeover.
//
// ── Why the details below are not interchangeable ───────────────────────
// 1. THE KEY. supabase_flutter derives its storage key as
//    `sb-<project-ref>-auth-token` (supabase.dart, verified in the 2.12.4
//    source we actually depend on). The `supabasePersistSessionKey`
//    constant that the package README's own example passes to
//    FlutterSecureStorage is NOT that key — the package annotates it
//    "Only used for migration from Hive to SharedPreferences. Not actually
//    in use." Copying the README verbatim yields a store that can never
//    see the existing session, silently logging everyone out.
//
// 2. ACCESSIBILITY. The package default is `unlocked`
//    (kSecAttrAccessibleWhenUnlocked), under which a read fails while the
//    device is locked — background token refresh would then fail and the
//    user would appear logged out. `first_unlock_this_device`
//    (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) is readable after
//    the first unlock following a reboot, and per Apple's Keychain data
//    protection documentation "ThisDeviceOnly" items "aren't backed up" —
//    which is precisely the exposure being closed here. Choosing plain
//    `first_unlock` would fix the lock-screen read but leave the token in
//    backups, i.e. fix half the bug.
//
// 3. WRITE-BEFORE-DELETE. Migration writes the new store first and only
//    then removes the legacy value. If the process dies in between, the
//    session exists in one store or the other — never in neither. This
//    mirrors what supabase-flutter's own newer migration code does.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reproduces supabase_flutter's own default key derivation.
///
/// Hard-coded rather than imported because the helper that computes it
/// (`defaultPersistSessionKey`) does not exist in the version we pin — it
/// only landed on the package's main branch. If a future upgrade adds it,
/// switch to it and delete this.
String supabaseSessionKeyFor(String supabaseUrl) =>
    'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage({required this.supabaseUrl});

  final String supabaseUrl;

  late final String _key = supabaseSessionKeyFor(supabaseUrl);

  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      // See note 2 in the header: readable after first unlock, and never
      // included in a backup or migrated to another device.
      accessibility: KeychainAccessibility.first_unlock_this_device,
      // Do not sync to iCloud Keychain — a session belongs to one device.
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  @override
  Future<void> initialize() async {
    // Runs before Supabase attempts recoverSession(), so a signed-in user
    // upgrading to this build keeps their session instead of landing on
    // the login screen.
    await _migrateFromPlaintextIfNeeded();
  }

  Future<void> _migrateFromPlaintextIfNeeded() async {
    try {
      if (await _secure.containsKey(key: _key)) return;

      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_key);
      if (legacy == null || legacy.isEmpty) return;

      // Write first, delete second (see note 3).
      await _secure.write(key: _key, value: legacy);
      if (await _secure.containsKey(key: _key)) {
        await prefs.remove(_key);
      }
    } catch (_) {
      // A failed migration must not block startup. Worst case the user
      // signs in again; a thrown exception here would break app launch,
      // which is strictly worse.
    }
  }

  @override
  Future<bool> hasAccessToken() => _secure.containsKey(key: _key);

  @override
  Future<String?> accessToken() => _secure.read(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _secure.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _secure.delete(key: _key);
}
