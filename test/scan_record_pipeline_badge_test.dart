import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';
import 'package:pocketworld_flutter/ui/scan_record_cell.dart';

void main() {
  testWidgets('work card labels self and official routes', (tester) async {
    Future<void> pump(CapturePipelineKind kind) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 360,
              child: ScanRecordCell(
                record: ScanRecord(
                  id: kind.wireName,
                  name: 'record',
                  createdAt: DateTime.utc(2026, 7, 22),
                  pipelineKind: kind,
                ),
                subtitle: '2026-07-22',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(CapturePipelineKind.self);
    expect(find.text('自研'), findsOneWidget);

    await pump(CapturePipelineKind.official);
    expect(find.text('官方'), findsOneWidget);
  });

  testWidgets('route badge and completed badge occupy opposite corners', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 360,
            child: ScanRecordCell(
              record: ScanRecord(
                id: 'official-completed',
                name: 'record',
                createdAt: DateTime.utc(2026, 7, 22),
                pipelineKind: CapturePipelineKind.official,
                artifactPath: 'file:///does/not-need-to-exist.glb',
              ),
              subtitle: '2026-07-22',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final official = tester.getTopLeft(
      find.byKey(const ValueKey<String>('scan-pipeline-badge')),
    );
    final completed = tester.getTopLeft(
      find.byKey(const ValueKey<String>('scan-completed-badge')),
    );
    expect(official.dx, lessThan(completed.dx));
    expect(official.dy, completed.dy);
  });
}
