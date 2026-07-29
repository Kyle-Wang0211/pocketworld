import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';

void main() {
  late Directory captureDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_db_archive_policy_');
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  test('writes and reloads the exact future official policy', () async {
    final policy = await DatabaseArchivePolicy.writeForNewCapture(captureDir);

    expect(policy.schema, DatabaseArchivePolicy.schemaV1);
    expect(policy.sourceFile, DatabaseArchivePolicy.sourceFileName);
    expect(policy.codec, DatabaseArchivePolicy.codecName);
    expect(policy.version, DatabaseArchivePolicy.version715);
    expect(policy.method, DatabaseArchivePolicy.method5);
    expect(policy.revision, DatabaseArchivePolicy.pinnedRevision);
    expect(policy.createdAt, isNotEmpty);
    expect(
      await File(
        '${captureDir.path}/${DatabaseArchivePolicy.fileName}',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${captureDir.path}/${DatabaseArchivePolicy.fileName}.tmp',
      ).exists(),
      isFalse,
    );

    final reloaded = await DatabaseArchivePolicy.readCompatible(captureDir);

    expect(reloaded?.toJson(), policy.toJson());
  });

  test('missing malformed and incompatible markers are ineligible', () async {
    expect(await DatabaseArchivePolicy.readCompatible(captureDir), isNull);

    final marker = File('${captureDir.path}/${DatabaseArchivePolicy.fileName}');
    await marker.writeAsString('{', flush: true);
    expect(await DatabaseArchivePolicy.readCompatible(captureDir), isNull);

    await marker.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': DatabaseArchivePolicy.schemaV1,
        'source_file': DatabaseArchivePolicy.sourceFileName,
        'codec': DatabaseArchivePolicy.codecName,
        'version': DatabaseArchivePolicy.version715,
        'revision': DatabaseArchivePolicy.pinnedRevision,
        'method': 4,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    expect(await DatabaseArchivePolicy.readCompatible(captureDir), isNull);
  });

  test(
    'manifest round trips only fixed paths and exact codec identity',
    () async {
      const sourceHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const archiveHash =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const manifest = DatabaseArchiveManifest(
        sourceBytes: 100,
        sourceSha256: sourceHash,
        archiveBytes: 60,
        archiveSha256: archiveHash,
        verifiedAt: '2026-07-29T00:00:00.000Z',
      );

      await manifest.writeAtomic(captureDir);
      final reloaded = await DatabaseArchiveManifest.read(captureDir);

      expect(reloaded?.sourceBytes, 100);
      expect(reloaded?.sourceSha256, sourceHash);
      expect(reloaded?.archiveBytes, 60);
      expect(reloaded?.archiveSha256, archiveHash);
      expect(reloaded?.toJson(), manifest.toJson());
      expect(
        await File(
          '${captureDir.path}/${DatabaseArchiveManifest.fileName}.tmp',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'manifest rejects unsafe paths invalid hashes and unknown identity',
    () async {
      const manifest = DatabaseArchiveManifest(
        sourceBytes: 100,
        sourceSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        archiveBytes: 60,
        archiveSha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        verifiedAt: '2026-07-29T00:00:00.000Z',
      );
      await manifest.writeAtomic(captureDir);
      final file = File(
        '${captureDir.path}/${DatabaseArchiveManifest.fileName}',
      );

      final unsafe =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      unsafe['archive_file'] = '../outside.zpaq';
      await file.writeAsString(jsonEncode(unsafe), flush: true);
      expect(await DatabaseArchiveManifest.read(captureDir), isNull);

      final invalidHash = Map<String, dynamic>.from(manifest.toJson());
      invalidHash['source_sha256'] = 'ABC';
      await file.writeAsString(jsonEncode(invalidHash), flush: true);
      expect(await DatabaseArchiveManifest.read(captureDir), isNull);

      final unknownRevision = Map<String, dynamic>.from(manifest.toJson());
      unknownRevision['revision'] = 'unknown';
      await file.writeAsString(jsonEncode(unknownRevision), flush: true);
      expect(await DatabaseArchiveManifest.read(captureDir), isNull);
    },
  );
}
