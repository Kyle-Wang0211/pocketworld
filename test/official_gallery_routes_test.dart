import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/official_capture/official_gallery_routes.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_resume_wait_page.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  Future<void> pumpLauncher(
    WidgetTester tester, {
    required bool regenerate,
  }) async {
    final record = ScanRecord(
      id: 'official-resume',
      name: '测试扫描',
      createdAt: DateTime.utc(2026, 7, 22),
      pipelineKind: CapturePipelineKind.official,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey<String>('launch-official-resume'),
              onPressed: () async {
                await pushOfficialResumeRoute(
                  context,
                  record,
                  '/tmp/nonexistent-official-capture',
                  regenerate: regenerate,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('official resume requires confirmation before wait page', (
    tester,
  ) async {
    await pumpLauncher(tester, regenerate: false);

    await tester.tap(
      find.byKey(const ValueKey<String>('launch-official-resume')),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续重建？'), findsOneWidget);
    expect(find.textContaining('「测试扫描」的点云还没有生成'), findsOneWidget);
    expect(find.byType(SfmResumeWaitPage), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(SfmResumeWaitPage), findsNothing);
  });

  testWidgets('official regenerate uses the matching confirmation copy', (
    tester,
  ) async {
    await pumpLauncher(tester, regenerate: true);

    await tester.tap(
      find.byKey(const ValueKey<String>('launch-official-resume')),
    );
    await tester.pumpAndSettle();

    expect(find.text('重新重建？'), findsOneWidget);
    expect(find.text('重新重建'), findsOneWidget);
    expect(find.byType(SfmResumeWaitPage), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(SfmResumeWaitPage), findsNothing);
  });
}
