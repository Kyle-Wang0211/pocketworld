import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';
import 'package:pocketworld_flutter/ui/scan_record_cell.dart';

void main() {
  testWidgets('work cards never expose their pipeline route', (tester) async {
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
    expect(find.text('自研'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('scan-pipeline-badge')),
      findsNothing,
    );

    await pump(CapturePipelineKind.official);
    expect(find.text('官方'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('scan-pipeline-badge')),
      findsNothing,
    );
  });

  testWidgets('completed status remains visible without a pipeline badge', (
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
                artifactPath: 'file:///does-not-need-to-exist.glb',
              ),
              subtitle: '2026-07-22',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('scan-pipeline-badge')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('scan-completed-badge')),
      findsOneWidget,
    );
  });
}
