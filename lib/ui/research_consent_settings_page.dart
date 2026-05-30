import 'package:flutter/material.dart';

import '../i18n/locale_notifier.dart';
import '../privacy/research_consent_service.dart';
import 'design_system.dart';

class ResearchConsentSettingsPage extends StatefulWidget {
  const ResearchConsentSettingsPage({super.key});

  @override
  State<ResearchConsentSettingsPage> createState() =>
      _ResearchConsentSettingsPageState();
}

class _ResearchConsentSettingsPageState
    extends State<ResearchConsentSettingsPage> {
  final ResearchConsentService _service = ResearchConsentService.instance;
  ResearchConsentSnapshot _snapshot = ResearchConsentService.instance.snapshot;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_sync);
    _load();
  }

  @override
  void dispose() {
    _service.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    setState(() => _snapshot = _service.snapshot);
  }

  Future<void> _load() async {
    final snapshot = await _service.load(refreshRemote: true);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_saving) return;
    setState(() => _saving = true);
    final next = await _service.setConsent(enabled: enabled);
    if (!mounted) return;
    setState(() {
      _snapshot = next;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final copy = _ResearchSettingsCopy.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: AetherColors.textPrimary),
        title: Text(copy.title, style: AetherTextStyles.h2),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            140,
          ),
          children: [
            Container(
              padding: const EdgeInsets.all(AetherSpacing.lg),
              decoration: BoxDecoration(
                color: AetherColors.bgCanvas,
                borderRadius: BorderRadius.circular(AetherRadii.xl),
                border: Border.all(color: AetherColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(copy.switchTitle, style: AetherTextStyles.body),
                        const SizedBox(height: 6),
                        Text(
                          copy.switchSubtitle,
                          style: AetherTextStyles.caption,
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: _snapshot.enabled,
                    onChanged: (_loading || _saving) ? null : _setEnabled,
                    activeThumbColor: AetherColors.primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AetherSpacing.lg),
            Text(copy.body, style: AetherTextStyles.bodySm),
            const SizedBox(height: AetherSpacing.md),
            Text(
              _snapshot.updatedAt == null
                  ? copy.neverUpdated
                  : copy.updated(_snapshot.updatedAt!.toLocal()),
              style: AetherTextStyles.caption,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResearchSettingsCopy {
  final String title;
  final String switchTitle;
  final String switchSubtitle;
  final String body;
  final String neverUpdated;
  final String Function(DateTime) updated;

  const _ResearchSettingsCopy({
    required this.title,
    required this.switchTitle,
    required this.switchSubtitle,
    required this.body,
    required this.neverUpdated,
    required this.updated,
  });

  static _ResearchSettingsCopy of(BuildContext context) {
    final zh = LocaleScope.of(context).isChinese;
    if (zh) {
      return _ResearchSettingsCopy(
        title: 'AI 模型改进授权',
        switchTitle: '允许用于算法改进',
        switchSubtitle: '用于改进重建质量、失败案例分析和未来 AI 模型。',
        body:
            '开启后，本次以及未来拍摄素材可以进入独立的研发数据池。关闭后，普通用户素材仍按产品默认逻辑在最终结果确认后删除；已进入研发数据池的数据后续会按撤回/删除流程处理。',
        neverUpdated: '尚未设置',
        updated: (t) =>
            '上次更新：${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
      );
    }
    return _ResearchSettingsCopy(
      title: 'AI Improvement Consent',
      switchTitle: 'Allow algorithm improvement',
      switchSubtitle:
          'Used to improve reconstruction quality, failure analysis, and future AI models.',
      body:
          'When enabled, this and future captures may enter a separate research dataset. When disabled, normal user raw assets still follow the default deletion policy after the final result is confirmed.',
      neverUpdated: 'Not configured yet',
      updated: (t) =>
          'Last updated: ${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
    );
  }
}
