import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../aether_prefs.dart';
import '../auth/auth_models.dart';

class ResearchConsentSnapshot {
  final bool enabled;
  final bool promptDismissed;
  final int version;
  final DateTime? updatedAt;

  const ResearchConsentSnapshot({
    required this.enabled,
    required this.promptDismissed,
    required this.version,
    required this.updatedAt,
  });

  static const empty = ResearchConsentSnapshot(
    enabled: false,
    promptDismissed: false,
    version: 1,
    updatedAt: null,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'prompt_dismissed': promptDismissed,
    'version': version,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  ResearchConsentSnapshot copyWith({
    bool? enabled,
    bool? promptDismissed,
    int? version,
    DateTime? updatedAt,
  }) {
    return ResearchConsentSnapshot(
      enabled: enabled ?? this.enabled,
      promptDismissed: promptDismissed ?? this.promptDismissed,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class ResearchConsentPromptDecision {
  final bool enabled;
  final bool dontAskAgain;

  const ResearchConsentPromptDecision({
    required this.enabled,
    required this.dontAskAgain,
  });
}

class ResearchConsentService extends ChangeNotifier {
  ResearchConsentService._();

  static final ResearchConsentService instance = ResearchConsentService._();
  static const int currentVersion = 1;

  ResearchConsentSnapshot _snapshot = ResearchConsentSnapshot.empty;
  bool _loaded = false;

  ResearchConsentSnapshot get snapshot => _snapshot;

  Future<ResearchConsentSnapshot> load({bool refreshRemote = true}) async {
    final local = await _loadLocal();
    _setSnapshot(local, notify: false);
    _loaded = true;
    if (refreshRemote) {
      await _pullRemote();
    }
    return _snapshot;
  }

  Future<bool> shouldPromptForTraining() async {
    if (!_loaded) {
      await load(refreshRemote: true);
    }
    return !_snapshot.promptDismissed;
  }

  Future<ResearchConsentSnapshot> savePromptDecision(
    ResearchConsentPromptDecision decision,
  ) {
    return setConsent(
      enabled: decision.enabled,
      promptDismissed: decision.enabled || decision.dontAskAgain,
    );
  }

  Future<ResearchConsentSnapshot> setConsent({
    required bool enabled,
    bool promptDismissed = true,
  }) async {
    final next = ResearchConsentSnapshot(
      enabled: enabled,
      promptDismissed: promptDismissed,
      version: currentVersion,
      updatedAt: DateTime.now().toUtc(),
    );
    _setSnapshot(next);
    await _saveLocal(next);
    await _pushRemote(next);
    return next;
  }

  void _setSnapshot(ResearchConsentSnapshot next, {bool notify = true}) {
    _snapshot = next;
    if (notify) notifyListeners();
  }

  Future<ResearchConsentSnapshot> _loadLocal() async {
    final prefs = await AetherPrefs.getInstance();
    final prefix = await _keyPrefix();
    final enabled = await prefs.getInt('${prefix}enabled');
    final dismissed = await prefs.getInt('${prefix}promptDismissed');
    final version = await prefs.getInt('${prefix}version');
    final updatedRaw = await prefs.getString('${prefix}updatedAt');
    return ResearchConsentSnapshot(
      enabled: enabled == 1,
      promptDismissed: dismissed == 1,
      version: version ?? currentVersion,
      updatedAt: DateTime.tryParse(updatedRaw ?? ''),
    );
  }

  Future<void> _saveLocal(ResearchConsentSnapshot value) async {
    final prefs = await AetherPrefs.getInstance();
    final prefix = await _keyPrefix();
    await prefs.setInt('${prefix}enabled', value.enabled ? 1 : 0);
    await prefs.setInt(
      '${prefix}promptDismissed',
      value.promptDismissed ? 1 : 0,
    );
    await prefs.setInt('${prefix}version', value.version);
    await prefs.setString(
      '${prefix}updatedAt',
      (value.updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
    );
  }

  Future<void> _pullRemote() async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentSession?.user.id;
      if (uid == null) return;
      final row = await client
          .from('profiles')
          .select(
            'research_data_opt_in,'
            'research_data_prompt_dismissed,'
            'research_data_consent_version,'
            'research_data_opt_in_updated_at',
          )
          .eq('id', uid)
          .maybeSingle();
      if (row == null) return;
      final remote = ResearchConsentSnapshot(
        enabled: row['research_data_opt_in'] == true,
        promptDismissed: row['research_data_prompt_dismissed'] == true,
        version:
            (row['research_data_consent_version'] as num?)?.toInt() ??
            currentVersion,
        updatedAt: DateTime.tryParse(
          row['research_data_opt_in_updated_at'] as String? ?? '',
        ),
      );
      _setSnapshot(remote);
      await _saveLocal(remote);
    } catch (e, st) {
      debugPrint('[ResearchConsent] remote load skipped: $e\n$st');
    }
  }

  Future<void> _pushRemote(ResearchConsentSnapshot value) async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentSession?.user.id;
      if (uid == null) return;
      await client
          .from('profiles')
          .update({
            'research_data_opt_in': value.enabled,
            'research_data_prompt_dismissed': value.promptDismissed,
            'research_data_consent_version': value.version,
            'research_data_opt_in_updated_at':
                (value.updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
          })
          .eq('id', uid);
    } catch (e, st) {
      debugPrint('[ResearchConsent] remote save skipped: $e\n$st');
    }
  }

  Future<String> _keyPrefix() async {
    String? uid;
    try {
      uid = Supabase.instance.client.auth.currentSession?.user.id;
    } catch (_) {
      // Supabase may not be initialized in widget tests.
    }
    if (uid == null || uid.isEmpty) {
      final prefs = await AetherPrefs.getInstance();
      uid = await prefs.getString(AuthPersistenceKeys.currentUserID);
    }
    return 'PocketWorld.researchConsent.${uid ?? 'anonymous'}.';
  }
}
