import 'package:flutter/material.dart';

import '../i18n/locale_notifier.dart';
import '../privacy/research_consent_service.dart';
import 'design_system.dart';

Future<ResearchConsentPromptDecision?> showResearchConsentDialog(
  BuildContext context,
) {
  return showDialog<ResearchConsentPromptDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _ResearchConsentDialog(),
  );
}

class _ResearchConsentDialog extends StatefulWidget {
  const _ResearchConsentDialog();

  @override
  State<_ResearchConsentDialog> createState() => _ResearchConsentDialogState();
}

class _ResearchConsentDialogState extends State<_ResearchConsentDialog> {
  bool _dontAskAgain = false;

  @override
  Widget build(BuildContext context) {
    final copy = _ResearchConsentCopy.of(context);
    return AlertDialog(
      backgroundColor: AetherColors.bgCanvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AetherRadii.lg),
      ),
      title: Text(copy.title, style: AetherTextStyles.h2),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(copy.body, style: AetherTextStyles.bodySm),
          const SizedBox(height: AetherSpacing.md),
          CheckboxListTile(
            value: _dontAskAgain,
            onChanged: (v) => setState(() => _dontAskAgain = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AetherColors.primary,
            title: Text(copy.dontAskAgain, style: AetherTextStyles.caption),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            ResearchConsentPromptDecision(
              enabled: false,
              dontAskAgain: _dontAskAgain,
            ),
          ),
          child: Text(copy.decline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            const ResearchConsentPromptDecision(
              enabled: true,
              dontAskAgain: true,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: AetherColors.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(copy.accept),
        ),
      ],
    );
  }
}

class _ResearchConsentCopy {
  final String title;
  final String body;
  final String dontAskAgain;
  final String decline;
  final String accept;

  const _ResearchConsentCopy({
    required this.title,
    required this.body,
    required this.dontAskAgain,
    required this.decline,
    required this.accept,
  });

  static _ResearchConsentCopy of(BuildContext context) {
    final zh = LocaleScope.of(context).isChinese;
    if (zh) {
      return const _ResearchConsentCopy(
        title: '帮助 Pocketworld 改进 3D 模型？',
        body:
            '如果你同意，我们会使用本次以及未来的拍摄素材来改进 3D 重建算法、AI 模型和服务质量。你可以随时在设置里关闭；关闭后不会影响本次生成。',
        dontAskAgain: '以后不再显示此弹窗',
        decline: '不同意，继续生成',
        accept: '同意，开始生成',
      );
    }
    return const _ResearchConsentCopy(
      title: 'Help Pocketworld improve 3D models?',
      body:
          'If you agree, Pocketworld may use this and future captures to improve reconstruction algorithms, AI models, and service quality. You can turn this off anytime in Settings; declining will not block generation.',
      dontAskAgain: 'Do not show again',
      decline: 'Decline and continue',
      accept: 'Agree and generate',
    );
  }
}
