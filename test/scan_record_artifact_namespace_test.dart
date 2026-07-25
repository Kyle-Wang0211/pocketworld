import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocketworld_flutter/me/scan_record_store.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScanRecordStore route-owned artifact namespaces', () {
    late Directory documentsDirectory;
    late ScanRecordStore store;

    setUp(() async {
      documentsDirectory = await Directory.systemTemp.createTemp(
        'scan_record_artifact_namespace_test_',
      );
      store = ScanRecordStore.forTesting(
        documentsDirectory: documentsDirectory,
      );
    });

    tearDown(() async {
      if (await documentsDirectory.exists()) {
        await documentsDirectory.delete(recursive: true);
      }
    });

    test('self and official resolve the same id to disjoint files', () async {
      final selfThumbnail = await store.thumbnailFileFor(
        'same-id',
        pipelineKind: CapturePipelineKind.self,
      );
      final officialThumbnail = await store.thumbnailFileFor(
        'same-id',
        pipelineKind: CapturePipelineKind.official,
      );
      final selfGlb = await store.glbFileFor(
        'same-id',
        pipelineKind: CapturePipelineKind.self,
      );
      final officialGlb = await store.glbFileFor(
        'same-id',
        pipelineKind: CapturePipelineKind.official,
      );

      expect(
        selfThumbnail.path,
        '${documentsDirectory.path}/scans/same-id.jpg',
      );
      expect(selfGlb.path, '${documentsDirectory.path}/scans/same-id.glb');
      expect(
        officialThumbnail.path,
        '${documentsDirectory.path}/scans_official/same-id.jpg',
      );
      expect(
        officialGlb.path,
        '${documentsDirectory.path}/scans_official/same-id.glb',
      );
      expect(officialThumbnail.path, isNot(selfThumbnail.path));
      expect(officialGlb.path, isNot(selfGlb.path));
    });

    test('official stale paths never re-anchor to self artifacts', () async {
      final selfDir = Directory('${documentsDirectory.path}/scans');
      await selfDir.create(recursive: true);
      await File('${selfDir.path}/official-id.jpg').writeAsString('self-jpg');
      await File('${selfDir.path}/official-id.glb').writeAsString('self-glb');
      final staleThumbnail = '/stale/scans_official/official-id.jpg';
      final staleArtifact = 'file:///stale/scans_official/official-id.glb';
      await File('${documentsDirectory.path}/scan_records.json').writeAsString(
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'official-id',
            'name': 'official',
            'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
            'pipeline_kind': 'official',
            'thumbnailPath': staleThumbnail,
            'artifactPath': staleArtifact,
          },
        ]),
      );

      await store.ensureLoaded();

      expect(store.records.single.thumbnailPath, staleThumbnail);
      expect(store.records.single.artifactPath, staleArtifact);
      expect(
        Directory('${documentsDirectory.path}/scans_official').existsSync(),
        isTrue,
      );
    });

    test('official stale paths re-anchor only inside scans_official', () async {
      final officialDir = Directory(
        '${documentsDirectory.path}/scans_official',
      );
      await officialDir.create(recursive: true);
      final officialThumbnail = File('${officialDir.path}/official-id.jpg');
      final officialGlb = File('${officialDir.path}/official-id.glb');
      await officialThumbnail.writeAsString('official-jpg');
      await officialGlb.writeAsString('official-glb');
      await File('${documentsDirectory.path}/scan_records.json').writeAsString(
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'official-id',
            'name': 'official',
            'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
            'pipeline_kind': 'official',
            'thumbnailPath': '/stale/official-id.jpg',
            'artifactPath': 'file:///stale/official-id.glb',
          },
        ]),
      );

      await store.ensureLoaded();

      expect(store.records.single.thumbnailPath, officialThumbnail.path);
      expect(store.records.single.artifactPath, 'file://${officialGlb.path}');
    });

    test(
      'official record rejects existing files in the self namespace',
      () async {
        final selfDir = Directory('${documentsDirectory.path}/scans');
        await selfDir.create(recursive: true);
        final selfThumbnail = File('${selfDir.path}/official-id.jpg');
        final selfGlb = File('${selfDir.path}/official-id.glb');
        await selfThumbnail.writeAsString('self-jpg');
        await selfGlb.writeAsString('self-glb');
        await File(
          '${documentsDirectory.path}/scan_records.json',
        ).writeAsString(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'official-id',
              'name': 'official',
              'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
              'pipeline_kind': 'official',
              'thumbnailPath': selfThumbnail.path,
              'artifactPath': 'file://${selfGlb.path}',
            },
          ]),
        );

        await store.ensureLoaded();

        expect(store.records.single.thumbnailPath, isNull);
        expect(store.records.single.artifactPath, isNull);
        expect(selfThumbnail.existsSync(), isTrue);
        expect(selfGlb.existsSync(), isTrue);
      },
    );

    test(
      'official orphan recovery creates its card in scans_official',
      () async {
        final photos = Directory(
          '${documentsDirectory.path}/captures_official/orphan/photos_highres',
        );
        await photos.create(recursive: true);
        final jpeg = img.encodeJpg(img.Image(width: 1, height: 2));
        await File('${photos.path}/frame_0001.jpg').writeAsBytes(jpeg);
        await File('${photos.path}/frame_0001.json').writeAsString('{}');

        await store.ensureLoaded();

        final record = store.records.single;
        expect(record.pipelineKind, CapturePipelineKind.official);
        expect(
          record.thumbnailPath,
          '${documentsDirectory.path}/scans_official/orphan.jpg',
        );
        expect(File(record.thumbnailPath!).existsSync(), isTrue);
        expect(
          File('${documentsDirectory.path}/scans/orphan.jpg').existsSync(),
          isFalse,
        );
      },
    );

    test('new records fail closed when paths cross route namespaces', () async {
      await expectLater(
        store.addOrUpdate(
          ScanRecord(
            id: 'invalid-official',
            name: 'invalid official',
            createdAt: DateTime.utc(2026, 7, 22),
            pipelineKind: CapturePipelineKind.official,
            thumbnailPath: '${documentsDirectory.path}/scans/invalid.jpg',
            artifactPath: 'file://${documentsDirectory.path}/scans/invalid.glb',
          ),
        ),
        throwsStateError,
      );
      expect(store.records, isEmpty);

      await expectLater(
        store.addOrUpdate(
          ScanRecord(
            id: 'invalid-self',
            name: 'invalid self',
            createdAt: DateTime.utc(2026, 7, 22),
            thumbnailPath:
                '${documentsDirectory.path}/scans_official/invalid.jpg',
          ),
        ),
        throwsStateError,
      );
      expect(store.records, isEmpty);
    });

    test(
      'new records reject every capture metadata field from the other route',
      () async {
        ScanRecord recordWithCrossRouteField({
          required CapturePipelineKind pipelineKind,
          required String field,
        }) {
          final otherRoot = pipelineKind == CapturePipelineKind.official
              ? '${documentsDirectory.path}/captures'
              : '${documentsDirectory.path}/captures_official';
          final captureDir = '$otherRoot/${pipelineKind.wireName}-$field';
          return ScanRecord(
            id: '${pipelineKind.wireName}-$field',
            name: 'invalid capture metadata',
            createdAt: DateTime.utc(2026, 7, 22),
            pipelineKind: pipelineKind,
            captureDir: field == 'captureDir' ? captureDir : null,
            photosDir: field == 'photosDir'
                ? '$captureDir/photos_highres'
                : null,
            captureManifestPath: field == 'captureManifestPath'
                ? '$captureDir/photo_bundle.json'
                : null,
          );
        }

        for (final pipelineKind in CapturePipelineKind.values) {
          for (final field in <String>[
            'captureDir',
            'photosDir',
            'captureManifestPath',
          ]) {
            await expectLater(
              store.addOrUpdate(
                recordWithCrossRouteField(
                  pipelineKind: pipelineKind,
                  field: field,
                ),
              ),
              throwsStateError,
              reason: '${pipelineKind.wireName} must reject $field',
            );
          }
        }
        expect(store.records, isEmpty);
      },
    );

    test(
      'persisted cross-route capture metadata is cleared in both directions',
      () async {
        final selfCapture = Directory(
          '${documentsDirectory.path}/captures/self-owned',
        );
        final officialCapture = Directory(
          '${documentsDirectory.path}/captures_official/official-owned',
        );
        await Directory(
          '${selfCapture.path}/photos_highres',
        ).create(recursive: true);
        await Directory(
          '${officialCapture.path}/photos_highres',
        ).create(recursive: true);
        await File('${selfCapture.path}/photo_bundle.json').writeAsString('{}');
        await File(
          '${officialCapture.path}/official_photo_bundle.json',
        ).writeAsString('{}');
        final persistedRecords = <Map<String, Object?>>[];
        for (final pipelineKind in CapturePipelineKind.values) {
          final otherCapture = pipelineKind == CapturePipelineKind.official
              ? selfCapture
              : officialCapture;
          final otherManifest = pipelineKind == CapturePipelineKind.official
              ? '${otherCapture.path}/photo_bundle.json'
              : '${otherCapture.path}/official_photo_bundle.json';
          for (final field in <String>[
            'captureDir',
            'photosDir',
            'captureManifestPath',
          ]) {
            persistedRecords.add(<String, Object?>{
              'id': '${pipelineKind.wireName}-$field-cross-route',
              'name': '${pipelineKind.wireName} invalid $field',
              'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
              'pipeline_kind': pipelineKind.wireName,
              if (field == 'captureDir') 'captureDir': otherCapture.path,
              if (field == 'photosDir')
                'photosDir': '${otherCapture.path}/photos_highres',
              if (field == 'captureManifestPath')
                'captureManifestPath': otherManifest,
            });
          }
        }
        await File(
          '${documentsDirectory.path}/scan_records.json',
        ).writeAsString(jsonEncode(persistedRecords));

        await store.ensureLoaded();

        expect(store.records, hasLength(6));
        for (final record in store.records) {
          expect(record.captureDir, isNull, reason: record.id);
          expect(record.photosDir, isNull, reason: record.id);
          expect(record.captureManifestPath, isNull, reason: record.id);
        }
        final persisted =
            (jsonDecode(
                      await File(
                        '${documentsDirectory.path}/scan_records.json',
                      ).readAsString(),
                    )
                    as List)
                .cast<Map<String, dynamic>>();
        for (final record in persisted) {
          expect(record.containsKey('captureDir'), isFalse);
          expect(record.containsKey('photosDir'), isFalse);
          expect(record.containsKey('captureManifestPath'), isFalse);
        }
      },
    );

    test('valid capture metadata remains route-owned after reload', () async {
      Future<Map<String, Object?>> validRecord({
        required String id,
        required CapturePipelineKind pipelineKind,
      }) async {
        final rootName = pipelineKind == CapturePipelineKind.official
            ? 'captures_official'
            : 'captures';
        final manifestName = pipelineKind == CapturePipelineKind.official
            ? 'official_photo_bundle.json'
            : 'photo_bundle.json';
        final captureDir = Directory(
          '${documentsDirectory.path}/$rootName/$id',
        );
        final photosDir = Directory('${captureDir.path}/photos_highres');
        await photosDir.create(recursive: true);
        final manifest = File('${captureDir.path}/$manifestName');
        await manifest.writeAsString('{}');
        return <String, Object?>{
          'id': id,
          'name': id,
          'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
          'pipeline_kind': pipelineKind.wireName,
          'captureDir': captureDir.path,
          'photosDir': photosDir.path,
          'captureManifestPath': manifest.path,
        };
      }

      final selfRecord = await validRecord(
        id: 'valid-self',
        pipelineKind: CapturePipelineKind.self,
      );
      final officialRecord = await validRecord(
        id: 'valid-official',
        pipelineKind: CapturePipelineKind.official,
      );
      await File('${documentsDirectory.path}/scan_records.json').writeAsString(
        jsonEncode(<Map<String, Object?>>[selfRecord, officialRecord]),
      );

      await store.ensureLoaded();

      expect(store.records, hasLength(2));
      final byId = <String, ScanRecord>{
        for (final record in store.records) record.id: record,
      };
      for (final expected in <Map<String, Object?>>[
        selfRecord,
        officialRecord,
      ]) {
        final record = byId[expected['id']]!;
        expect(record.captureDir, expected['captureDir']);
        expect(record.photosDir, expected['photosDir']);
        expect(record.captureManifestPath, expected['captureManifestPath']);
      }
    });

    test('new valid capture metadata is accepted for both routes', () async {
      for (final pipelineKind in CapturePipelineKind.values) {
        final id = 'new-valid-${pipelineKind.wireName}';
        final captureDir = await store.captureDirFor(
          id,
          pipelineKind: pipelineKind,
        );
        final photosDir = Directory('${captureDir.path}/photos_highres');
        await photosDir.create(recursive: true);
        final manifestName = pipelineKind == CapturePipelineKind.official
            ? 'official_photo_bundle.json'
            : 'photo_bundle.json';
        final manifest = File('${captureDir.path}/$manifestName');
        await manifest.writeAsString('{}');

        await store.addOrUpdate(
          ScanRecord(
            id: id,
            name: id,
            createdAt: DateTime.utc(2026, 7, 22),
            pipelineKind: pipelineKind,
            captureDir: captureDir.path,
            photosDir: photosDir.path,
            captureManifestPath: manifest.path,
          ),
        );
      }

      expect(store.records, hasLength(2));
      for (final record in store.records) {
        final expectedRoot = record.pipelineKind == CapturePipelineKind.official
            ? '${documentsDirectory.path}/captures_official/'
            : '${documentsDirectory.path}/captures/';
        expect(record.captureDir, startsWith(expectedRoot));
        expect(record.photosDir, startsWith(expectedRoot));
        expect(record.captureManifestPath, startsWith(expectedRoot));
      }
    });

    test('deleting official removes only official artifact files', () async {
      final record = ScanRecord(
        id: 'delete-id',
        name: 'official',
        createdAt: DateTime.utc(2026, 7, 22),
        pipelineKind: CapturePipelineKind.official,
      );
      await store.addOrUpdate(record);
      final selfThumbnail = await store.thumbnailFileFor(
        record.id,
        pipelineKind: CapturePipelineKind.self,
      );
      final selfGlb = await store.glbFileFor(
        record.id,
        pipelineKind: CapturePipelineKind.self,
      );
      final officialThumbnail = await store.thumbnailFileFor(
        record.id,
        pipelineKind: CapturePipelineKind.official,
      );
      final officialGlb = await store.glbFileFor(
        record.id,
        pipelineKind: CapturePipelineKind.official,
      );
      for (final file in <File>[
        selfThumbnail,
        selfGlb,
        officialThumbnail,
        officialGlb,
      ]) {
        await file.writeAsString(file.path);
      }

      await store.delete(record.id);

      expect(selfThumbnail.existsSync(), isTrue);
      expect(selfGlb.existsSync(), isTrue);
      expect(officialThumbnail.existsSync(), isFalse);
      expect(officialGlb.existsSync(), isFalse);
    });

    test(
      'deleting official permanently removes its complete project namespace',
      () async {
        const id = 'delete-complete-project';
        await store.ensureLoaded();
        final officialCapture = await store.captureDirFor(
          id,
          pipelineKind: CapturePipelineKind.official,
        );
        final officialPhotos = Directory(
          '${officialCapture.path}/photos_highres',
        );
        final officialCache = Directory(
          '${officialCapture.path}/matcher_cache/nested',
        );
        await officialPhotos.create(recursive: true);
        await officialCache.create(recursive: true);
        final jpeg = img.encodeJpg(img.Image(width: 1, height: 2));
        await File('${officialPhotos.path}/frame_0001.jpg').writeAsBytes(jpeg);
        await File(
          '${officialPhotos.path}/frame_0001.json',
        ).writeAsString('{}');
        await File(
          '${officialCapture.path}/official_photo_bundle.json',
        ).writeAsString('{}');
        await File(
          '${officialCapture.path}/official_sfm_live.db',
        ).writeAsString('database');
        await File(
          '${officialCapture.path}/official_sfm_sparse.ply',
        ).writeAsString('point cloud');
        await File('${officialCache.path}/matches.bin').writeAsString('cache');

        final officialThumbnail = await store.thumbnailFileFor(
          id,
          pipelineKind: CapturePipelineKind.official,
        );
        final officialGlb = await store.glbFileFor(
          id,
          pipelineKind: CapturePipelineKind.official,
        );
        await officialThumbnail.writeAsString('thumbnail');
        await officialGlb.writeAsString('mesh');

        final selfCapture = await store.captureDirFor(
          id,
          pipelineKind: CapturePipelineKind.self,
        );
        final selfPhotos = Directory('${selfCapture.path}/photos_highres');
        await selfPhotos.create(recursive: true);
        await File('${selfPhotos.path}/frame_0001.jpg').writeAsBytes(jpeg);
        await File('${selfPhotos.path}/frame_0001.json').writeAsString('{}');
        final selfThumbnail = await store.thumbnailFileFor(
          id,
          pipelineKind: CapturePipelineKind.self,
        );
        final selfGlb = await store.glbFileFor(
          id,
          pipelineKind: CapturePipelineKind.self,
        );
        await selfThumbnail.writeAsString('self thumbnail');
        await selfGlb.writeAsString('self mesh');

        await store.addOrUpdate(
          ScanRecord(
            id: id,
            name: 'official',
            createdAt: DateTime.utc(2026, 7, 25),
            pipelineKind: CapturePipelineKind.official,
            thumbnailPath: officialThumbnail.path,
            artifactPath: 'file://${officialGlb.path}',
            captureDir: officialCapture.path,
            photosDir: officialPhotos.path,
            captureManifestPath:
                '${officialCapture.path}/official_photo_bundle.json',
            photoCount: 1,
          ),
        );

        await store.delete(id);

        expect(store.byId(id), isNull);
        expect(officialCapture.existsSync(), isFalse);
        expect(officialThumbnail.existsSync(), isFalse);
        expect(officialGlb.existsSync(), isFalse);
        expect(selfCapture.existsSync(), isTrue);
        expect(selfThumbnail.existsSync(), isTrue);
        expect(selfGlb.existsSync(), isTrue);

        // A late reconstruction writer must not resurrect a project after the
        // user confirmed permanent deletion.
        await officialPhotos.create(recursive: true);
        await File('${officialPhotos.path}/late_frame.jpg').writeAsBytes(jpeg);
        await File(
          '${officialPhotos.path}/late_frame.json',
        ).writeAsString('{}');
        await officialThumbnail.writeAsString('late thumbnail');
        final lateScanCache = File(
          '${officialThumbnail.parent.path}/$id.preview-cache',
        );
        await lateScanCache.writeAsString('late cache');

        // A finalize callback already queued before deletion may still try to
        // persist the same record. Tombstones must reject direct late writes
        // as well as orphan-directory recovery.
        await store.addOrUpdate(
          ScanRecord(
            id: id,
            name: 'late finalize',
            createdAt: DateTime.utc(2026, 7, 25),
            pipelineKind: CapturePipelineKind.official,
            captureDir: officialCapture.path,
            photosDir: officialPhotos.path,
            photoCount: 1,
          ),
        );
        expect(store.byId(id), isNull);
        expect(officialCapture.existsSync(), isFalse);

        // Simulate one more late native write after the direct callback so a
        // cold-load recovery pass also has material it might resurrect.
        await officialPhotos.create(recursive: true);
        await File(
          '${officialPhotos.path}/recovery_late.jpg',
        ).writeAsBytes(jpeg);
        await File(
          '${officialPhotos.path}/recovery_late.json',
        ).writeAsString('{}');

        final reloaded = ScanRecordStore.forTesting(
          documentsDirectory: documentsDirectory,
        );
        await reloaded.ensureLoaded();
        expect(
          reloaded.records.where(
            (record) =>
                record.id == id &&
                record.pipelineKind == CapturePipelineKind.official,
          ),
          isEmpty,
          reason: 'a deleted project must never be recovered as an orphan',
        );
        expect(officialCapture.existsSync(), isFalse);
        expect(officialThumbnail.existsSync(), isFalse);
        expect(lateScanCache.existsSync(), isFalse);

        final tombstones = File(
          '${documentsDirectory.path}/scan_record_deletion_tombstones.json',
        );
        expect(tombstones.existsSync(), isTrue);
        expect(
          await tombstones.readAsString(),
          isNot(contains(id)),
          reason: 'the permanent deletion guard must not retain project ids',
        );
      },
    );

    test(
      'legacy record without pipeline_kind remains in self namespace',
      () async {
        final selfDir = Directory('${documentsDirectory.path}/scans');
        final officialDir = Directory(
          '${documentsDirectory.path}/scans_official',
        );
        await selfDir.create(recursive: true);
        await officialDir.create(recursive: true);
        final selfThumbnail = File('${selfDir.path}/legacy-id.jpg');
        await selfThumbnail.writeAsString('self');
        await File(
          '${officialDir.path}/legacy-id.jpg',
        ).writeAsString('official');
        await File(
          '${documentsDirectory.path}/scan_records.json',
        ).writeAsString(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'legacy-id',
              'name': 'legacy',
              'createdAt': DateTime.utc(2026, 7, 22).toIso8601String(),
              'thumbnailPath': '/stale/legacy-id.jpg',
            },
          ]),
        );

        await store.ensureLoaded();

        expect(store.records.single.pipelineKind, CapturePipelineKind.self);
        expect(store.records.single.thumbnailPath, selfThumbnail.path);
      },
    );
  });
}
