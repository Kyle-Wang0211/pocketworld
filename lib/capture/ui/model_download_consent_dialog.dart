// model_download_consent_dialog.dart
//
// "吃鸡 mode" pre-download consent dialog. Shown when user enters capture
// flow for the first time and the tier-matched ML stack isn't on device yet.
//
// UX rationale (user 2026-05-20):
//   • App Store install bundle is ~80 MB — UI shell + community + browsing.
//     No ML in initial install.
//   • Community / 二创 / 浏览 / 上传 all work offline-of-models.
//   • Only when user taps "Create my own" → enter capture flow → app
//     prompts: "需要下载 AI 引擎 (X GB),WiFi 推荐?"
//   • User explicitly confirms before any download starts.
//   • Mirrors PUBG Mobile / Genshin Impact pattern (download on demand
//     after install), NOT 王者荣耀 (everything on first launch).
//
// Returns Future<bool>:
//   true  → user tapped "下载" → caller proceeds with ModelDownloadDialog.run()
//   false → user tapped "稍后" → caller should pop the capture page
//
// Tier-aware content:
//   ModelTag.tierLow  (iPhone 11 / 12 base, 4 GB RAM):
//     • DA3-BASE K30 pose-conditioned CoreML bundle
//
//   ModelTag.tierHigh (iPhone 12 Pro+, 6 GB+ RAM):
//     • DA3-BASE K40 pose-conditioned CoreML bundle
//     • SigLIP 材质分类器

import 'package:flutter/material.dart';

import '../model_loader.dart';

/// One row in the consent dialog's manifest. Hardcoded per ODR tag because
/// sizes are deterministic at ship time — no need for a native query.
class _Component {
  const _Component({required this.name, required this.sizeMB});
  final String name;
  final int sizeMB;
}

const List<_Component> _kTierLowComponents = [
  _Component(name: 'DA3-BASE 深度模型(K30 pose)', sizeMB: 350),
];

const List<_Component> _kTierHighComponents = [
  _Component(name: 'DA3-BASE 深度模型(K40 pose)', sizeMB: 500),
  _Component(name: '材质分类器(SigLIP base)', sizeMB: 177),
];

/// Show the consent dialog. Returns true iff user tapped 下载.
///
/// barrierDismissible: false — user must explicitly choose 稍后 or 下载.
/// Tapping outside the dialog (or hitting back) returns false.
Future<bool> showModelDownloadConsentDialog(
  BuildContext context, {
  required ModelTag tier,
}) async {
  final components = tier == ModelTag.tierHigh
      ? _kTierHighComponents
      : _kTierLowComponents;
  final totalMB = components.fold<int>(0, (s, c) => s + c.sizeMB);

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) =>
        _ConsentDialog(components: components, totalMB: totalMB, tier: tier),
  );
  return result ?? false;
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog({
    required this.components,
    required this.totalMB,
    required this.tier,
  });

  final List<_Component> components;
  final int totalMB;
  final ModelTag tier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalLabel = totalMB >= 1024
        ? '${(totalMB / 1024).toStringAsFixed(2)} GB'
        : '$totalMB MB';

    return AlertDialog(
      title: const Text('开启创作功能'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('首次创作需要下载 AI 引擎,后续无需再下载', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 16),
          // Components list
          for (final c in components) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 16,
                    child: Text('•', style: TextStyle(fontSize: 16)),
                  ),
                  Expanded(
                    child: Text(c.name, style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    c.sizeMB >= 1024
                        ? '${(c.sizeMB / 1024).toStringAsFixed(2)} GB'
                        : '${c.sizeMB} MB',
                    style: const TextStyle(
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '总计',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                totalLabel,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.wifi, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tier == ModelTag.tierHigh
                        ? '建议 WiFi 下载,占用约 5-10 分钟'
                        : '建议 WiFi 下载,占用约 3-5 分钟',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('下载'),
        ),
      ],
    );
  }
}
