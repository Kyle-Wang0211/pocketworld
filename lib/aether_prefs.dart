// Thin facade over the standard `shared_preferences` pub package.
//
// History: this used to route through an in-Runner MethodChannel
// (`aether_prefs` + AetherPrefsPlugin.swift) to dodge a
// shared_preferences_foundation iOS-26 direct-launch registrar race
// (EXC_BAD_ACCESS in SharedPreferencesPlugin.register). That race no
// longer reproduces — shared_preferences is already linked + registered
// on every launch (via supabase_flutter) and the app runs clean — so the
// custom native plugin was retired (2026-07-07) and this file is now a
// straight pass-through to the cross-platform package. The static API is
// unchanged, so the call sites (auth / locale / lifecycle / consent) are
// untouched. Keys are passed through as-is; shared_preferences manages its
// own `flutter.` storage prefix transparently.

import 'package:shared_preferences/shared_preferences.dart';

class AetherPrefs {
  AetherPrefs._(this._prefs);

  final SharedPreferences _prefs;

  /// Test seam — mirrors `SharedPreferences.setMockInitialValues` so widget
  /// tests keep working without any per-call channel mock.
  static void setMockInitialValues(Map<String, Object> values) {
    SharedPreferences.setMockInitialValues(values);
  }

  /// Same shape as `SharedPreferences.getInstance()`. The underlying
  /// instance is cached by the package, so repeated calls are cheap.
  static Future<AetherPrefs> getInstance() async {
    return AetherPrefs._(await SharedPreferences.getInstance());
  }

  Future<String?> getString(String key) async => _prefs.getString(key);

  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);

  Future<int?> getInt(String key) async => _prefs.getInt(key);

  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  Future<bool> remove(String key) => _prefs.remove(key);
}
