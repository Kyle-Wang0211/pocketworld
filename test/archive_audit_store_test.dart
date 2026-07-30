import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archive_audit_store.dart';

void main() {
  late Directory documentsDirectory;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'pw_archive_audit_',
    );
  });

  tearDown(() async {
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test('persists append-only history and atomic latest status', () async {
    final store = OfficialArchiveAuditStore(
      documentsDirectory: () async => documentsDirectory,
    );
    final first = ArchiveAuditEvent(
      timestamp: DateTime.utc(2026, 7, 30, 1, 2, 3),
      event: 'capture_enqueued',
      trigger: 'artifacts_persisted',
      captureId: 'cap-a',
      details: const <String, Object?>{'work_remaining': true},
    );
    final second = ArchiveAuditEvent(
      timestamp: DateTime.utc(2026, 7, 30, 1, 3, 4),
      event: 'capture_completed',
      trigger: 'foreground',
      captureId: 'cap-a',
      details: const <String, Object?>{
        'photos_archived': 12,
        'work_remaining': false,
      },
    );

    await store.record(first);
    await store.record(second);

    final journal = File(
      '${documentsDirectory.path}/official_archive_audit.jsonl',
    );
    final rows = await journal.readAsLines().then(
      (lines) => lines.map(jsonDecode).toList(growable: false),
    );
    expect(rows, hasLength(2));
    expect(rows[0], first.toJson());
    expect(rows[1], second.toJson());

    final status =
        jsonDecode(
              await File(
                '${documentsDirectory.path}/official_archive_status.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(status['schema'], 'pw_official_archive_status_v1');
    expect(status['updated_at'], second.timestamp.toIso8601String());
    expect(status['latest'], second.toJson());
    expect(
      (status['captures'] as Map<String, Object?>)['cap-a'],
      second.toJson(),
    );
    expect(
      await File(
        '${documentsDirectory.path}/official_archive_status.json.tmp',
      ).exists(),
      isFalse,
    );
  });

  test('a new store preserves prior per-capture status', () async {
    final firstStore = OfficialArchiveAuditStore(
      documentsDirectory: () async => documentsDirectory,
    );
    final first = ArchiveAuditEvent(
      timestamp: DateTime.utc(2026, 7, 30, 2),
      event: 'capture_completed',
      trigger: 'foreground',
      captureId: 'cap-a',
    );
    await firstStore.record(first);

    final restartedStore = OfficialArchiveAuditStore(
      documentsDirectory: () async => documentsDirectory,
    );
    final second = ArchiveAuditEvent(
      timestamp: DateTime.utc(2026, 7, 30, 3),
      event: 'capture_paused',
      trigger: 'bg_processing',
      captureId: 'cap-b',
      details: const <String, Object?>{'work_remaining': true},
    );
    await restartedStore.record(second);

    final status =
        jsonDecode(
              await File(
                '${documentsDirectory.path}/official_archive_status.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final captures = status['captures'] as Map<String, Object?>;
    expect(captures['cap-a'], first.toJson());
    expect(captures['cap-b'], second.toJson());
    expect(status['latest'], second.toJson());
  });
}
