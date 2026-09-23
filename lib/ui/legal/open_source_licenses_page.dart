// 开源许可页 —— 设置页第四个法律入口。
// =====================================================================
// [OSS-NOTICE 2026-09-23] 这一页是一次声明载体普查的产物。普查发现:出货包
// 里真正到用户手里的许可文本有两条互不相干的链,而**两条都没有出口**:
//
//   1. 原生静态库那条。Filament(经 thermion 链入,iOS arm64 的
//      thermion_dart.framework 7,598,928 字节 / 5,394 个 filament 符号)、
//      XRSLAM、OpenCV、ONNX Runtime、COLMAP/Ceres/Dawn…… 它们的许可正文以
//      Flutter 资产的形式进包了,但"哪份正文属于哪个组件"这层映射只存在于
//      仓里的 THIRD_PARTY_NOTICES,而那个文件此前根本不是资产。
//   2. Dart/pub 包那条。Flutter 工具链会自动把每个 pub 包的 LICENSE 聚合成
//      flutter_assets/NOTICES.Z 打进 App.framework —— thermion 本身就在里面
//      (第 29384-29388 行 + Copyright 2024 Nick Fisher)。但我们从没调过
//      showLicensePage,所以那个 blob 用户永远读不到。
//
// 所以这一页只做两件事:把 THIRD_PARTY_NOTICES 显示出来(并让每份正文可点
// 开),以及把 Flutter 内建的 showLicensePage 接上。两件都不是新造的声明,
// 是给已经出货的东西开一个能看的口子。
//
// 语言:与另外三份法律文本一致,正文按原文显示(许可全文本来就是英文),
// 页面 chrome 跟随界面语言。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../design_system.dart';
import '../../l10n/app_localizations.dart';

/// 声明索引本身。pubspec 的 assets 里有这一条,改名要同步改。
const String kThirdPartyNoticesAsset = 'THIRD_PARTY_NOTICES';

/// 逐份许可正文所在的资产目录/文件。每一条都在 pubspec 的 assets 里,
/// 且都被 THIRD_PARTY_NOTICES 的 "Bundled license:" 行指名。
///
/// 这里写成前缀而不是写死文件名:正文文件的增减跟着 vendored 依赖走,
/// 写死一份清单只会和 pubspec 各说各话。实际清单从 AssetManifest 读。
const List<String> kLicenseTextPrefixes = <String>[
  'assets/licenses/',
  'ios/Vendor/JXL/licenses/',
  'ios/Vendor/NativeCore/licenses/',
  'ios/Vendor/Zpaq/',
  'vendor/lepton_jpeg/licenses/',
];

class OpenSourceLicensesPage extends StatefulWidget {
  const OpenSourceLicensesPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const OpenSourceLicensesPage(),
      ));

  @override
  State<OpenSourceLicensesPage> createState() => _OpenSourceLicensesPageState();
}

class _OpenSourceLicensesPageState extends State<OpenSourceLicensesPage> {
  late final Future<_NoticesBundle> _bundle = _NoticesBundle.load();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        elevation: 0,
        title: Text(l.legalOpenSourceLicenses, style: AetherTextStyles.h2),
      ),
      body: SafeArea(
        child: FutureBuilder<_NoticesBundle>(
          future: _bundle,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              // 资产读不出来是**打包出了问题**,不是可以静默吞掉的空态 ——
              // 声明进不了包正是这一页要修的那个毛病。
              return _ErrorBody(message: '${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return _Body(bundle: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final _NoticesBundle bundle;
  const _Body({required this.bundle});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.xxl,
      ),
      children: [
        Text(l.legalOpenSourceIntro, style: AetherTextStyles.bodySm),
        const SizedBox(height: AetherSpacing.lg),

        // ① Dart / Flutter 包。Flutter 自己聚合好的那份,一直在包里躺着。
        _LinkTile(
          icon: Icons.inventory_2_outlined,
          title: l.legalOpenSourceFlutterPackages,
          subtitle: l.legalOpenSourceFlutterPackagesHint,
          onTap: () => showLicensePage(context: context),
        ),
        const SizedBox(height: AetherSpacing.sm),

        // ② 逐份许可正文。
        _LinkTile(
          icon: Icons.folder_open_outlined,
          title: l.legalOpenSourceLicenseTexts,
          subtitle:
              l.legalOpenSourceLicenseTextsCount(bundle.licenseTexts.length),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => _LicenseTextListPage(paths: bundle.licenseTexts),
          )),
        ),

        const SizedBox(height: AetherSpacing.xl),
        Text(l.legalOpenSourceNativeComponents,
            style: AetherTextStyles.cardTitle),
        const SizedBox(height: AetherSpacing.sm),

        // ③ 声明索引原文。等宽显示 —— 它是逐行对齐的清单,不是散文。
        SelectableText(
          bundle.notices,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: <String>['Menlo', 'Courier'],
            fontSize: 11,
            height: 1.55,
            color: AetherColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 逐份许可正文的清单页。
class _LicenseTextListPage extends StatelessWidget {
  final List<String> paths;
  const _LicenseTextListPage({required this.paths});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        elevation: 0,
        title:
            Text(l.legalOpenSourceLicenseTexts, style: AetherTextStyles.h2),
      ),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: AetherSpacing.sm),
          itemCount: paths.length,
          separatorBuilder: (_, _) => const Divider(
            height: 1,
            thickness: 1,
            color: AetherColors.border,
          ),
          itemBuilder: (context, index) {
            final path = paths[index];
            return ListTile(
              title: Text(path.split('/').last, style: AetherTextStyles.body),
              subtitle: Text(path, style: AetherTextStyles.caption),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: AetherColors.textTertiary,
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => _LicenseTextPage(path: path),
              )),
            );
          },
        ),
      ),
    );
  }
}

/// 单份许可正文。原样显示,不做任何折行以外的加工。
class _LicenseTextPage extends StatelessWidget {
  final String path;
  const _LicenseTextPage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        elevation: 0,
        title: Text(path.split('/').last, style: AetherTextStyles.h3),
      ),
      body: SafeArea(
        child: FutureBuilder<String>(
          future: rootBundle.loadString(path),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _ErrorBody(message: '${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.lg,
                AetherSpacing.md,
                AetherSpacing.lg,
                AetherSpacing.xxl,
              ),
              children: [
                SelectableText(
                  snapshot.data!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: <String>['Menlo', 'Courier'],
                    fontSize: 11,
                    height: 1.55,
                    color: AetherColors.textPrimary,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AetherRadii.md),
      child: Container(
        padding: const EdgeInsets.all(AetherSpacing.md),
        decoration: BoxDecoration(
          color: AetherColors.bgElevated,
          borderRadius: BorderRadius.circular(AetherRadii.md),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AetherColors.textSecondary),
            const SizedBox(width: AetherSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AetherTextStyles.body),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AetherTextStyles.caption),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AetherColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String message;
  const _ErrorBody({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      child: Text(
        message,
        style: const TextStyle(
          fontSize: 12,
          height: 1.6,
          color: AetherColors.danger,
        ),
      ),
    );
  }
}

/// 从资产包里取声明索引 + 逐份正文的实际清单。
class _NoticesBundle {
  final String notices;
  final List<String> licenseTexts;

  const _NoticesBundle({required this.notices, required this.licenseTexts});

  static Future<_NoticesBundle> load() async {
    final notices = await rootBundle.loadString(kThirdPartyNoticesAsset);
    // 清单从 AssetManifest 读,不写死 —— 正文文件的增减跟着 vendored 依赖
    // 走,写死一份只会和 pubspec 各说各话。
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest
        .listAssets()
        .where((path) =>
            kLicenseTextPrefixes.any((prefix) => path.startsWith(prefix)))
        .toList()
      ..sort();
    return _NoticesBundle(notices: notices, licenseTexts: paths);
  }
}
