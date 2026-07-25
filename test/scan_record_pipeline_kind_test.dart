import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocketworld_flutter/me/draft_card_action.dart';
import 'package:pocketworld_flutter/me/scan_record_store.dart';
import 'package:pocketworld_flutter/ui/me_page.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CapturePipelineKind', () {
    test('has stable wire names and labels', () {
      expect(CapturePipelineKind.self.wireName, 'self');
      expect(CapturePipelineKind.official.wireName, 'official');
      expect(CapturePipelineKind.self.displayLabel, '自研');
      expect(CapturePipelineKind.official.displayLabel, '官方');
      expect(
        CapturePipelineKindWire.fromWireName('self'),
        CapturePipelineKind.self,
      );
      expect(
        CapturePipelineKindWire.fromWireName('official'),
        CapturePipelineKind.official,
      );
      expect(
        () => CapturePipelineKindWire.fromWireName('experimental'),
        throwsFormatException,
      );
    });

    test('ScanRecord defaults to self and copyWith preserves identity', () {
      final legacyCompatible = ScanRecord(
        id: 'self-1',
        name: 'self',
        createdAt: DateTime.utc(2026, 7, 22),
      );
      final official = ScanRecord(
        id: 'official-1',
        name: 'official',
        createdAt: DateTime.utc(2026, 7, 22),
        pipelineKind: CapturePipelineKind.official,
      );

      expect(legacyCompatible.pipelineKind, CapturePipelineKind.self);
      expect(
        official.copyWith(name: 'renamed').pipelineKind,
        CapturePipelineKind.official,
      );
    });

    test('record re-entry artifact names are route-specific', () {
      expect(
        sparsePlyFileNameForPipeline(CapturePipelineKind.self),
        'sfm_sparse.ply',
      );
      expect(
        sparsePlyFileNameForPipeline(CapturePipelineKind.official),
        'official_sfm_sparse.ply',
      );
      expect(
        sfmDatabaseFileNameForPipeline(CapturePipelineKind.self),
        'sfm_live.db',
      );
      expect(
        sfmDatabaseFileNameForPipeline(CapturePipelineKind.official),
        'official_sfm_live.db',
      );
      expect(
        pipelineOwnsActiveReconstruction(
          recordPipelineKind: CapturePipelineKind.official,
          activePipelineKind: CapturePipelineKind.self,
        ),
        isFalse,
      );
    });

    test('sparse viewer dispatch never falls back across pipelines', () async {
      var selfOpens = 0;
      var officialOpens = 0;

      final missingOfficial = await dispatchSparseCloudViewerForPipeline(
        pipelineKind: CapturePipelineKind.official,
        openSelf: () async => selfOpens++,
      );
      expect(missingOfficial, isFalse);
      expect(selfOpens, 0);

      final openedOfficial = await dispatchSparseCloudViewerForPipeline(
        pipelineKind: CapturePipelineKind.official,
        openSelf: () async => selfOpens++,
        openOfficial: () async => officialOpens++,
      );
      expect(openedOfficial, isTrue);
      expect(selfOpens, 0);
      expect(officialOpens, 1);

      final openedSelf = await dispatchSparseCloudViewerForPipeline(
        pipelineKind: CapturePipelineKind.self,
        openSelf: () async => selfOpens++,
        openOfficial: () async => officialOpens++,
      );
      expect(openedSelf, isTrue);
      expect(selfOpens, 1);
      expect(officialOpens, 1);
    });
  });

  group('ScanRecordStore pipeline persistence', () {
    late Directory documentsDirectory;
    late File storeFile;

    setUp(() async {
      documentsDirectory = await Directory.systemTemp.createTemp(
        'scan_record_pipeline_test_',
      );
      storeFile = File('${documentsDirectory.path}/scan_records.json');
    });

    tearDown(() async {
      if (await documentsDirectory.exists()) {
        await documentsDirectory.delete(recursive: true);
      }
    });

    test('every newly persisted record writes pipeline_kind', () async {
      final store = ScanRecordStore.forTesting(
        documentsDirectory: documentsDirectory,
      );
      await store.addOrUpdate(
        ScanRecord(
          id: 'self-1',
          name: 'self',
          createdAt: DateTime.utc(2026, 7, 22, 10),
        ),
      );
      await store.addOrUpdate(
        ScanRecord(
          id: 'official-1',
          name: 'official',
          createdAt: DateTime.utc(2026, 7, 22, 11),
          pipelineKind: CapturePipelineKind.official,
        ),
      );

      final json = jsonDecode(await storeFile.readAsString()) as List<dynamic>;
      final byId = <String, Map<String, dynamic>>{
        for (final item in json.cast<Map<String, dynamic>>())
          item['id'] as String: item,
      };
      expect(byId['self-1']!['pipeline_kind'], 'self');
      expect(byId['official-1']!['pipeline_kind'], 'official');
      expect(store.records.map((record) => record.id), <String>[
        'official-1',
        'self-1',
      ]);
    });

    test(
      'a legacy record migrates only when pipeline_kind is absent',
      () async {
        await storeFile.writeAsString(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'legacy-1',
              'name': 'legacy',
              'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
            },
          ]),
        );
        final store = ScanRecordStore.forTesting(
          documentsDirectory: documentsDirectory,
        );

        await store.ensureLoaded();

        expect(store.records.single.pipelineKind, CapturePipelineKind.self);
      },
    );

    test('orphan recovery keeps both route roots in one tagged list', () async {
      Future<void> writeCapture(String rootName, String id) async {
        final photos = Directory(
          '${documentsDirectory.path}/$rootName/$id/photos_highres',
        );
        await photos.create(recursive: true);
        final jpeg = img.encodeJpg(img.Image(width: 1, height: 2));
        await File('${photos.path}/frame_0001.jpg').writeAsBytes(jpeg);
        await File('${photos.path}/frame_0001.json').writeAsString('{}');
      }

      await writeCapture('captures', 'self-orphan');
      await writeCapture('captures_official', 'official-orphan');
      final store = ScanRecordStore.forTesting(
        documentsDirectory: documentsDirectory,
      );

      await store.ensureLoaded();

      expect(store.records, hasLength(2));
      expect(
        <String, CapturePipelineKind>{
          for (final record in store.records) record.id: record.pipelineKind,
        },
        <String, CapturePipelineKind>{
          'self-orphan': CapturePipelineKind.self,
          'official-orphan': CapturePipelineKind.official,
        },
      );
      final persisted = (jsonDecode(await storeFile.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      expect(
        persisted.map((record) => record['pipeline_kind']).toSet(),
        <String>{'self', 'official'},
      );
      expect(
        (await store.captureDirFor(
          'official-orphan',
          pipelineKind: CapturePipelineKind.official,
        )).path,
        '${documentsDirectory.path}/captures_official/official-orphan',
      );

      final byId = <String, ScanRecord>{
        for (final record in store.records) record.id: record,
      };
      final selfManifest = File(byId['self-orphan']!.captureManifestPath!);
      final officialManifest = File(
        byId['official-orphan']!.captureManifestPath!,
      );
      expect(selfManifest.uri.pathSegments.last, 'capture_manifest.json');
      expect(
        officialManifest.uri.pathSegments.last,
        'official_capture_manifest.json',
      );
      final selfJson =
          jsonDecode(await selfManifest.readAsString()) as Map<String, dynamic>;
      final officialJson =
          jsonDecode(await officialManifest.readAsString())
              as Map<String, dynamic>;
      expect(selfJson['schema'], 'pocketworld.capture_manifest.v1');
      expect(selfJson['pipeline_kind'], 'self');
      expect(officialJson['schema'], 'pocketworld.capture_manifest.v1');
      expect(officialJson['pipeline_kind'], 'official');
    });

    test('reanchoring preserves official photos and manifest conventions', () async {
      final officialDir = Directory(
        '${documentsDirectory.path}/captures_official/reanchored-official',
      );
      final photos = Directory('${officialDir.path}/photos_highres');
      await photos.create(recursive: true);
      final manifest = File('${officialDir.path}/official_photo_bundle.json');
      await manifest.writeAsString('{}');
      await storeFile.writeAsString(
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'reanchored-official',
            'name': 'official',
            'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
            'pipeline_kind': 'official',
            'captureDir': '/stale/container/captures_official/reanchored-official',
            'photosDir': '/stale/container/photos_highres',
            'captureManifestPath': '/stale/container/official_photo_bundle.json',
          },
        ]),
      );
      final store = ScanRecordStore.forTesting(
        documentsDirectory: documentsDirectory,
      );

      await store.ensureLoaded();

      final record = store.records.single;
      expect(record.captureDir, officialDir.path);
      expect(record.photosDir, photos.path);
      expect(record.captureManifestPath, manifest.path);
    });

    for (final invalid in <Object?>[null, 'experimental', 1, true]) {
      test('explicit invalid pipeline_kind=$invalid fails closed', () async {
        final original = jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'invalid-1',
            'name': 'invalid',
            'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
            'pipeline_kind': invalid,
          },
        ]);
        await storeFile.writeAsString(original);
        final store = ScanRecordStore.forTesting(
          documentsDirectory: documentsDirectory,
        );

        await store.ensureLoaded();

        expect(store.records, isEmpty);
        await expectLater(
          store.addOrUpdate(
            ScanRecord(
              id: 'replacement',
              name: 'replacement',
              createdAt: DateTime.utc(2026, 7, 22),
            ),
          ),
          throwsStateError,
        );
        expect(await storeFile.readAsString(), original);
      });
    }

    test('an existing record cannot change pipeline identity', () async {
      final store = ScanRecordStore.forTesting(
        documentsDirectory: documentsDirectory,
      );
      final self = ScanRecord(
        id: 'immutable-1',
        name: 'self',
        createdAt: DateTime.utc(2026, 7, 22),
      );
      await store.addOrUpdate(self);
      final before = await storeFile.readAsString();

      await expectLater(
        store.addOrUpdate(
          ScanRecord(
            id: self.id,
            name: 'changed',
            createdAt: self.createdAt,
            pipelineKind: CapturePipelineKind.official,
          ),
        ),
        throwsStateError,
      );

      expect(store.byId(self.id)!.pipelineKind, CapturePipelineKind.self);
      expect(await storeFile.readAsString(), before);
    });
  });

  test('an active reconstruction blocks resume in the other pipeline', () {
    expect(
      draftCardActionFor(
        recordCaptureDir: '/captures/self-draft',
        hasArtifact: false,
        sparsePlyExists: false,
        sfmDbExists: true,
        activeReconstructionCaptureDir: '/captures_official/live-official',
        hasActiveReconstructionCallback: false,
      ),
      DraftCardAction.none,
    );
  });

  test('only the matching route-owned card can cancel itself for deletion', () {
    expect(
      recordOwnsActiveReconstruction(
        recordCaptureDir: '/captures_official/live-official/',
        recordPipelineKind: CapturePipelineKind.official,
        activeCaptureDir: '/captures_official/live-official',
        activePipelineKind: CapturePipelineKind.official,
      ),
      isTrue,
    );
    expect(
      recordOwnsActiveReconstruction(
        recordCaptureDir: '/captures_official/other',
        recordPipelineKind: CapturePipelineKind.official,
        activeCaptureDir: '/captures_official/live-official',
        activePipelineKind: CapturePipelineKind.official,
      ),
      isFalse,
    );
    expect(
      recordOwnsActiveReconstruction(
        recordCaptureDir: '/captures_official/live-official',
        recordPipelineKind: CapturePipelineKind.self,
        activeCaptureDir: '/captures_official/live-official',
        activePipelineKind: CapturePipelineKind.official,
      ),
      isFalse,
    );
  });
}
