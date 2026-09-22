// ScanRecordStore — durable on-device store for the user's own scans.
//
// Persistence model:
//   • Records live in a single JSON file at
//     `${app_documents_dir}/scan_records.json`. JSON is plenty fast for
//     the ~tens-to-low-hundreds of records we expect per user; if the
//     file ever grows past ~1 MB we switch to sqflite.
//   • GLB artifacts live next to that file under
//     `${app_documents_dir}/scans/<recordId>.glb`.
//
// Lifecycle (Plan G W2 全本地, 2026-05-16):
//   1. Capture finishes → cell-admitted JPEGs live in
//      `${app_documents_dir}/captures/<captureId>/photos/`. A future
//      Drafts UI revamp will call `addOrUpdate` with a ScanRecord
//      pointing at that capture directory.
//   2. W3 local pipeline (待实现) iterates the JPEGs, runs DA3 +
//      ScaleAlign + PoissonRecon + texrecon + gltfpack, writes the
//      final GLB to `scans/<id>.glb` and calls `addOrUpdate` again with
//      `artifactPath` set.
//   3. UI (HomeViewModel / _MyWorksSection) listens via the broadcast
//      stream so the gallery refreshes without a manual reload.
//
// Concurrency: writes are serialized through `_writeLock`. Multiple
// readers are fine — `records` returns a snapshot list.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../capture/captured_photo_catalog.dart';
import '../capture/capture_session.dart';
import '../capture/sfm_feed_queue.dart';
import '../capture/sfm_orphan_recovery.dart';
import '../dome/platform_pose_provider.dart';
import '../ui/scan_record.dart';

Uint8List? _uprightLandscapeThumbnailBytes(String path) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) return null;

  var image = img.bakeOrientation(decoded);
  if (image.width <= image.height) return null;

  image = img.copyRotate(image, angle: 90);
  const maxEdge = 1024;
  final longEdge = math.max(image.width, image.height);
  if (longEdge > maxEdge) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxEdge : null,
      height: image.height > image.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 88));
}

class ScanRecordStore {
  ScanRecordStore._();
  static final ScanRecordStore instance = ScanRecordStore._();

  /// Snapshot of the current store. Modifying this list directly is a
  /// no-op (we always return a defensive copy from `records`).
  List<ScanRecord> _records = const <ScanRecord>[];
  Future<void>? _loadFuture;
  final _ctrl = StreamController<List<ScanRecord>>.broadcast();
  Future<void> _writeLock = Future<void>.value();

  /// Snapshot of records, sorted newest-first by createdAt. UI binds
  /// to this through HomeViewModel which forwards changes via
  /// notifyListeners() each time the store fires.
  List<ScanRecord> get records => List<ScanRecord>.unmodifiable(_records);

  /// Fires every time the records list changes (add / update / delete /
  /// initial load). Listeners receive the new snapshot synchronously.
  Stream<List<ScanRecord>> get changes => _ctrl.stream;

  /// Resolves once the disk store has been read for the first time.
  /// Callers that want to display records on first frame should `await`
  /// this in initState.
  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _storeFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.isNotEmpty) {
          final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
          _records = list.map(_recordFromJson).toList(growable: false);
        }
      }
    } catch (e, st) {
      debugPrint('[ScanRecordStore] load failed: $e\n$st');
      _records = const <ScanRecord>[];
    }
    final recovered = await _recoverOrphanCaptures();
    // Re-anchor stale absolute paths.
    //
    // `thumbnailPath` / `artifactPath` are persisted as ABSOLUTE paths
    // (including the iOS sandbox UUID, e.g.
    //   `/var/mobile/Containers/Data/Application/<UUID>/Documents/...`).
    // The UUID rotates on app reinstall and occasionally on OS upgrades,
    // which makes the stored path point at a non-existent location even
    // though the file is still on disk under the CURRENT UUID's
    // Documents directory.
    //
    // User-facing symptom (caught 2026-05-10): all "Failed to process"
    // cards lose their thumbnail JPEG and fall back to the gray sparkle
    // placeholder, even though `Documents/scans/<id>.jpg` is sitting
    // right there.
    //
    // Fix: after deserializing, walk every record. If `thumbnailPath`
    // points at a missing file but `thumbnailFileFor(id)` exists, patch
    // the record's path. Same logic for `artifactPath` (`<id>.glb`).
    final patched = <ScanRecord>[];
    var rewrites = 0;
    for (final r in _records) {
      var rec = r;
      if (rec.thumbnailPath != null && rec.thumbnailPath!.isNotEmpty) {
        if (!File(rec.thumbnailPath!).existsSync()) {
          final fresh = await thumbnailFileFor(rec.id);
          if (await fresh.exists()) {
            rec = rec.copyWith(thumbnailPath: fresh.path);
            rewrites++;
          }
        }
      }
      if (rec.artifactPath != null && rec.artifactPath!.isNotEmpty) {
        // artifactPath is stored as `file://<absolute>` (Image / 3D
        // viewer's URI convention).
        final p = rec.artifactPath!.startsWith('file://')
            ? rec.artifactPath!.substring(7)
            : rec.artifactPath!;
        if (!File(p).existsSync()) {
          final fresh = await glbFileFor(rec.id);
          if (await fresh.exists()) {
            rec = rec.copyWith(artifactPath: 'file://${fresh.path}');
            rewrites++;
          }
        }
      }
      if (rec.captureDir != null && rec.captureDir!.isNotEmpty) {
        if (!Directory(rec.captureDir!).existsSync()) {
          final fresh = await captureDirFor(rec.id);
          if (await fresh.exists()) {
            rec = rec.copyWith(
              captureDir: fresh.path,
              photosDir: Directory('${fresh.path}/photos').path,
              captureManifestPath: File(
                '${fresh.path}/capture_manifest.json',
              ).path,
            );
            rewrites++;
          }
        }
      }
      if (rec.captureDir != null &&
          rec.thumbnailPath != null &&
          rec.thumbnailPath!.isNotEmpty) {
        final thumbnail = File(rec.thumbnailPath!);
        if (await thumbnail.exists() &&
            await _normalizePortraitCaptureThumbnail(thumbnail)) {
          rewrites++;
        }
      }
      patched.add(rec);
    }
    _records = _sortNewestFirst(patched);
    if (rewrites > 0 || recovered > 0) {
      debugPrint(
        '[ScanRecordStore] re-anchored $rewrites stale path(s), '
        'recovered $recovered orphan capture(s)',
      );
      // Persist the patched paths so the next load doesn't have to
      // re-scan + re-write.
      await _flush();
    }
    _emit();
  }

  Future<bool> _normalizePortraitCaptureThumbnail(File thumbnail) async {
    try {
      final bytes = await compute(
        _uprightLandscapeThumbnailBytes,
        thumbnail.path,
        debugLabel: 'scan-record-thumbnail-upright',
      );
      if (bytes == null) return false;
      await thumbnail.writeAsBytes(bytes, flush: true);
      return true;
    } catch (e) {
      debugPrint('[ScanRecordStore] thumbnail normalize skipped: $e');
      return false;
    }
  }

  /// Recovery net for interrupted capture finalization.
  ///
  /// The native capture path writes JPEG/JSON sidecars incrementally during
  /// recording. If the app is backgrounded or killed after those files are on
  /// disk but before `_persistDraft()` writes scan_records.json, we would have
  /// valuable raw material with no user-visible draft card. On load, scan
  /// `Documents/captures/*/photos_highres` and rehydrate any missing record.
  Future<int> _recoverOrphanCaptures() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final capturesRoot = Directory('${root.path}/captures');
      if (!await capturesRoot.exists()) return 0;
      final existingIds = _records.map((r) => r.id).toSet();
      final recovered = <ScanRecord>[];
      await for (final entity in capturesRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final captureId = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .lastOrNull;
        if (captureId == null || existingIds.contains(captureId)) continue;
        final manualLedger = File(
          '${entity.path}/manual_capture_registration_ledger.json',
        );
        final hasManualRecoveryIdentity = await _manualLedgerNeedsRecovery(
          manualLedger,
        );
        var photosDir = Directory('${entity.path}/photos_highres');
        if (!await photosDir.exists()) {
          // Read-only compatibility for captures created before the local
          // high-resolution directory rename.
          final legacyPhotosDir = Directory('${entity.path}/photos');
          if (await legacyPhotosDir.exists()) {
            photosDir = legacyPhotosDir;
          } else if (hasManualRecoveryIdentity) {
            // A failed/ACK-only shutter can durably own a job before its JPEG
            // appears. Recreate only the empty canonical directory so the
            // resulting recovery handle has a stable local photos path.
            await photosDir.create(recursive: true);
          }
        }
        if (!await photosDir.exists()) continue;
        final discoveredPhotos = (await discoverCapturedPhotoPaths(
          photosDir,
        )).map(File.new).toList(growable: false);
        final hasNativeRecoveryIdentity = await _hasManualV2RecoveryEvidence(
          photosDir,
        );
        final photos = await _committedVisiblePhotos(
          captureDir: entity,
          photosDir: photosDir,
          ledger: manualLedger,
          discovered: discoveredPhotos,
        );
        if (photos.isEmpty &&
            !hasManualRecoveryIdentity &&
            !hasNativeRecoveryIdentity) {
          continue;
        }
        final localBundle = File('${entity.path}/photo_bundle.json');
        final manifestFile = await localBundle.exists()
            ? localBundle
            : File('${entity.path}/capture_manifest.json');
        final stat = await entity.stat();
        final createdAt = stat.modified;
        if (!await manifestFile.exists()) {
          await _writeRecoveredCaptureManifest(
            manifestFile: manifestFile,
            captureId: captureId,
            createdAt: createdAt,
            captureDir: entity,
            photosDir: photosDir,
            photos: photos,
          );
        }
        String? thumbnailPath;
        if (photos.isNotEmpty) {
          try {
            final thumbnail = await thumbnailFileFor(captureId);
            await thumbnail.parent.create(recursive: true);
            await photos.first.copy(thumbnail.path);
            thumbnailPath = thumbnail.path;
          } on FileSystemException {
            thumbnailPath = photos.first.path;
          }
        }
        recovered.add(
          ScanRecord(
            id: captureId,
            name: '未命名(${_records.length + recovered.length + 1})',
            createdAt: createdAt,
            preferredCaptureMode: CaptureMode.local,
            thumbnailPath: thumbnailPath,
            captureDir: entity.path,
            photosDir: photosDir.path,
            captureManifestPath: manifestFile.path,
            photoCount: photos.length,
          ),
        );
        existingIds.add(captureId);
      }
      if (recovered.isEmpty) return 0;
      _records = _sortNewestFirst([..._records, ...recovered]);
      return recovered.length;
    } catch (e, st) {
      debugPrint('[ScanRecordStore] orphan capture recovery failed: $e\n$st');
      return 0;
    }
  }

  Future<bool> _manualLedgerNeedsRecovery(File ledger) async {
    if (!await ledger.exists()) return false;
    try {
      final decoded = jsonDecode(await ledger.readAsString());
      if (decoded is! Map) return await ledger.length() > 0;
      final events = decoded['events'];
      if (events is List) return events.isNotEmpty;
      // Forward-compatible reducer snapshots use materialized jobs instead
      // of an event list. They carry the same recovery identity.
      final jobs = decoded['jobs'];
      if (jobs is List) return jobs.isNotEmpty;
      // Unknown non-empty JSON is still evidence that capture persistence
      // began. Keep it visible so resume can surface the exact format error.
      return decoded.isNotEmpty;
    } catch (_) {
      // A corrupt non-empty ledger is still user-visible recovery state. The
      // resume inspector will report the exact validation error; silently
      // dropping its capture card would make repair/discard impossible.
      return await ledger.length() > 0;
    }
  }

  Future<bool> _hasManualV2RecoveryEvidence(Directory photosDir) async {
    if (!await photosDir.exists()) return false;
    await for (final entity in photosDir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.manual-v2-committed.json') ||
          entity.path.endsWith('.sfm-gray')) {
        return true;
      }
      if (!entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map &&
            decoded['manual_capture_schema'] ==
                'aether_manual_capture_v2_durable_v2') {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// A durable-v2 JPEG is not user-visible merely because its rename landed.
  /// Swift publishes the three artifacts before its commit marker. Visibility
  /// therefore requires either Dart's durable `photo_committed` ledger stage
  /// or a fully validated native three-artifact receipt.
  Future<List<File>> _committedVisiblePhotos({
    required Directory captureDir,
    required Directory photosDir,
    required File ledger,
    required List<File> discovered,
  }) async {
    final committed = <String>{};
    final claimed = <String>{};
    final userDeleted = <String>{};
    if (await ledger.exists()) {
      try {
        final raw = jsonDecode(await ledger.readAsString());
        if (raw is Map) {
          final mapping = raw['job_to_jpeg_path'];
          if (mapping is Map) {
            for (final value in mapping.values.whereType<String>()) {
              if (value.isNotEmpty) claimed.add(File(value).absolute.path);
            }
          }
          final events = raw['events'];
          if (events is List) {
            for (final event in events.whereType<Map>()) {
              if (event['event'] == 'attempted' &&
                  event['identity_token'] is String) {
                claimed.add(
                  File(event['identity_token'] as String).absolute.path,
                );
              }
            }
          }
        }
      } catch (_) {}
      try {
        final persisted = await loadPersistedManualCaptureEvidence(
          captureDir.path,
        );
        for (final entry in persisted.jobToJpegPath.entries) {
          final job = persisted.ledger.job(entry.key);
          if (job != null) {
            final path = File(entry.value).absolute.path;
            if (job.userDeleted) {
              userDeleted.add(path);
            } else if (job.photoCommitted) {
              committed.add(path);
            }
          }
        }
      } catch (_) {
        // The malformed ledger is still a visible zero-photo recovery handle;
        // it is not authority to publish a possibly partial JPEG.
      }
    }

    try {
      final native = await scanCommittedSfmOrphans(photosDir);
      committed.addAll(
        native.committedOrphans.map((orphan) => orphan.jpegFile.absolute.path),
      );
    } catch (_) {
      // Fail closed for visibility; the bytes stay on disk for reconciliation.
    }
    for (final photo in discovered) {
      final sidecar = File(
        photo.absolute.path.replaceFirst(RegExp(r'\.[^.]+$'), '.json'),
      );
      if (await _hasExactDurableV2PhotoReceipt(jpeg: photo, sidecar: sidecar)) {
        committed.add(photo.absolute.path);
      }
    }
    committed.removeAll(userDeleted);

    final visible = <File>[];
    for (final photo in discovered) {
      final canonical = photo.absolute.path;
      if (userDeleted.contains(canonical)) continue;
      if (committed.contains(canonical)) {
        visible.add(photo);
        continue;
      }
      if (claimed.contains(canonical)) continue;
      final sidecar = File(
        canonical.replaceFirst(RegExp(r'\.[^.]+$'), '.json'),
      );
      var durableV2 = false;
      try {
        final decoded = jsonDecode(await sidecar.readAsString());
        durableV2 =
            decoded is Map &&
            decoded['manual_capture_schema'] ==
                'aether_manual_capture_v2_durable_v2';
      } catch (_) {}
      if (!durableV2) visible.add(photo);
    }
    return List<File>.unmodifiable(visible);
  }

  Future<bool> _hasExactDurableV2PhotoReceipt({
    required File jpeg,
    required File sidecar,
  }) async {
    try {
      if (!await jpeg.exists() || !await sidecar.exists()) return false;
      final sidecarRaw = jsonDecode(await sidecar.readAsString());
      if (sidecarRaw is! Map ||
          sidecarRaw['manual_capture_schema'] !=
              'aether_manual_capture_v2_durable_v2') {
        return false;
      }
      final jobId = sidecarRaw['capture_job_id'];
      final snapshot = sidecarRaw['snapshot_identity'];
      final markerPath = sidecarRaw['durable_commit_marker_path'];
      final grayPath = sidecarRaw['sfm_gray_path'];
      if (jobId is! String ||
          jobId.isEmpty ||
          snapshot is! String ||
          snapshot.isEmpty ||
          markerPath is! String ||
          grayPath is! String) {
        return false;
      }
      final sidecarStem = sidecar.absolute.path.endsWith('.json')
          ? sidecar.absolute.path.substring(
              0,
              sidecar.absolute.path.length - '.json'.length,
            )
          : sidecar.absolute.path;
      final expectedMarker = File('$sidecarStem.manual-v2-committed.json');
      if (!File(markerPath).isAbsolute ||
          File(markerPath).absolute.path != expectedMarker.absolute.path ||
          !await expectedMarker.exists()) {
        return false;
      }
      final markerRaw = jsonDecode(await expectedMarker.readAsString());
      if (markerRaw is! Map ||
          markerRaw['schemaVersion'] != 1 ||
          markerRaw['captureJobID'] != jobId ||
          markerRaw['snapshotIdentity'] != snapshot ||
          markerRaw['preparedSha256'] is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(markerRaw['preparedSha256'] as String) ||
          markerRaw['committedUnixMicros'] is! int ||
          (markerRaw['committedUnixMicros'] as int) <= 0) {
        return false;
      }
      final artifacts = markerRaw['artifacts'];
      if (artifacts is! List || artifacts.length != 3) return false;
      final expectedPaths = <String, String>{
        'jpeg': jpeg.absolute.path,
        'metadata': sidecar.absolute.path,
        'sfm_gray': File(grayPath).absolute.path,
      };
      final seen = <String>{};
      for (final raw in artifacts) {
        if (raw is! Map) return false;
        final kind = raw['kind'];
        final finalPath = raw['finalPath'];
        final byteLength = raw['byteLength'];
        final digest = raw['sha256'];
        if (kind is! String ||
            !seen.add(kind) ||
            finalPath != expectedPaths[kind] ||
            byteLength is! int ||
            byteLength <= 0 ||
            digest is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          return false;
        }
        final file = kind == 'jpeg'
            ? jpeg
            : kind == 'metadata'
            ? sidecar
            : File(grayPath);
        if (kind != 'sfm_gray' || await file.exists()) {
          if (!await file.exists() ||
              await file.length() != byteLength ||
              await _sha256(file) != digest) {
            return false;
          }
        }
      }
      return seen.length == expectedPaths.length &&
          seen.containsAll(expectedPaths.keys);
    } catch (_) {
      return false;
    }
  }

  Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _writeRecoveredCaptureManifest({
    required File manifestFile,
    required String captureId,
    required DateTime createdAt,
    required Directory captureDir,
    required Directory photosDir,
    required List<File> photos,
  }) async {
    final frames = <Map<String, Object?>>[];
    for (final photo in photos) {
      final metadata = File(
        photo.path.replaceFirst(RegExp(r'\.[^.]+$'), '.json'),
      );
      frames.add(<String, Object?>{
        'image_path': photo.path,
        'metadata_path': metadata.path,
        'image_file': photo.uri.pathSegments.last,
        'metadata_file': metadata.uri.pathSegments.last,
      });
    }
    final manifest = <String, Object?>{
      'schema': 'pocketworld.capture_manifest.v1',
      'capture_id': captureId,
      'created_at': createdAt.toIso8601String(),
      'capture_dir': captureDir.path,
      'photos_dir': photosDir.path,
      'photo_count': photos.length,
      'frames': frames,
      'recovered_from_orphan_capture': true,
    };
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
  }

  /// Insert or replace by id. The store keeps records sorted newest-
  /// first so the gallery natural order is "most recent on top".
  Future<void> addOrUpdate(ScanRecord r) async {
    await ensureLoaded();
    final next = <ScanRecord>[
      r,
      for (final old in _records)
        if (old.id != r.id) old,
    ];
    _records = _sortNewestFirst(next);
    _emit();
    await _flush();
  }

  /// Look up by id. Returns null if no record matches.
  ScanRecord? byId(String id) {
    for (final r in _records) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Delete by id after deleting its owned local source bundle.
  ///
  /// The record remains visible if any filesystem deletion fails. This is
  /// deliberate: removing the card first would hide an orphan capture and
  /// make the user's explicit deletion impossible to retry.
  Future<void> delete(
    String id, {
    Future<void> Function(Directory directory)? coordinatedCleanup,
    Future<void> Function(File index, List<ScanRecord> records)?
    recordIndexWriter,
  }) async {
    await ensureLoaded();
    final record = byId(id);
    if (record == null) return;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(id)) {
      throw StateError('scan record id is not a safe direct-child token: $id');
    }

    final capture = await _validatedCaptureDirectoryForDelete(record);
    if (capture != null) {
      final capturePath = capture.path;
      if (await capture.exists()) {
        final queueOwner = await SfmDurableFeedQueue.processOwnerSnapshot(
          Directory('$capturePath/sfm_live.db.sfm-feed'),
        );
        if (queueOwner != null) {
          throw StateError(
            'capture is still owned by an active reconstruction: $capturePath',
          );
        }
        if (coordinatedCleanup != null) {
          await coordinatedCleanup(capture);
        } else {
          // On iOS this joins the serial native writer, refuses non-terminal
          // registry jobs, and releases exact private raw claims first.
          if (Platform.isIOS) {
            await PlatformARPoseProvider().discardManualCaptureV2Jobs(
              capturePath,
            );
          }
          await capture.delete(recursive: true);
        }
      }
    }
    final artifact = await glbFileFor(id);
    if (await artifact.exists()) await artifact.delete();
    final thumbnail = await thumbnailFileFor(id);
    if (await thumbnail.exists()) await thumbnail.delete();

    final next = _records.where((r) => r.id != id).toList(growable: false);
    await _writeRecordsStrict(next, writer: recordIndexWriter);
    _records = next;
    _emit();
  }

  Future<Directory?> _validatedCaptureDirectoryForDelete(
    ScanRecord record,
  ) async {
    final storedPath = record.captureDir;
    if (storedPath == null || storedPath.isEmpty) return null;
    if (!File(storedPath).isAbsolute ||
        storedPath.split(Platform.pathSeparator).contains('..')) {
      throw StateError('capture path is not normalized absolute: $storedPath');
    }

    final documents = await getApplicationDocumentsDirectory();
    final capturesRoot = Directory('${documents.path}/captures');
    final expected = Directory('${capturesRoot.path}/${record.id}');
    final stored = Directory(storedPath);
    final storedExists = await stored.exists();
    final expectedExists = await expected.exists();
    if (!storedExists && !expectedExists) return null;
    if (!expectedExists) {
      throw StateError(
        'capture path is not the current owned record directory: $storedPath',
      );
    }
    if (!await capturesRoot.exists()) {
      throw StateError('capture root is missing for ${record.id}');
    }

    final canonicalRoot = await capturesRoot.resolveSymbolicLinks();
    final canonicalExpected = await expected.resolveSymbolicLinks();
    final expectedResolved = Directory(canonicalExpected);
    final expectedLeaf = expectedResolved.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    if (expectedResolved.parent.path != canonicalRoot ||
        expectedLeaf != record.id) {
      throw StateError(
        'capture directory escapes its owned direct child: $canonicalExpected',
      );
    }

    if (storedExists) {
      final normalizedStored = stored.absolute.path;
      if (normalizedStored != expected.absolute.path ||
          await stored.resolveSymbolicLinks() != canonicalExpected) {
        throw StateError(
          'capture record points at a different capture: $storedPath',
        );
      }
    }
    // A stale app-container UUID may no longer exist while the same record ID
    // is present under the current Documents root. Return the exact re-anchored
    // direct child; no other missing stored path is trusted.
    return expectedResolved;
  }

  Future<void> _writeRecordsStrict(
    List<ScanRecord> records, {
    Future<void> Function(File index, List<ScanRecord> records)? writer,
  }) async {
    final last = _writeLock;
    final completer = Completer<void>();
    _writeLock = completer.future;
    try {
      await last;
      final file = await _storeFile();
      if (writer != null) {
        await writer(file, records);
        return;
      }
      final temp = File(
        '${file.path}.delete-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await temp.writeAsString(
          jsonEncode(records.map(_recordToJson).toList()),
          flush: true,
        );
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } finally {
      completer.complete();
    }
  }

  /// Where on disk to persist `<id>.glb` for a given record. W3 (待实现)
  /// will write the local-generated GLB here.
  Future<File> glbFileFor(String id) async {
    final dir = await _scansDir();
    return File('${dir.path}/$id.glb');
  }

  Future<Directory> captureDirFor(String id) async {
    final root = await getApplicationDocumentsDirectory();
    return Directory('${root.path}/captures/$id');
  }

  /// Where on disk to persist the scan card's cover thumbnail. Plan G
  /// W2 全本地 (2026-05-16) — a future Drafts UI revamp can populate
  /// this from the first cell-admitted JPEG in `<captureDir>/photos/`.
  Future<File> thumbnailFileFor(String id) async {
    final dir = await _scansDir();
    return File('${dir.path}/$id.jpg');
  }

  Future<Directory> _scansDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/scans');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _storeFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/scan_records.json');
  }

  void _emit() {
    if (!_ctrl.isClosed) _ctrl.add(records);
  }

  Future<void> _flush() async {
    // Serialize writes — two concurrent updates would otherwise race
    // on the JSON file.
    final last = _writeLock;
    final completer = Completer<void>();
    _writeLock = completer.future;
    try {
      await last;
      final file = await _storeFile();
      final json = jsonEncode(_records.map(_recordToJson).toList());
      await file.writeAsString(json, flush: true);
    } catch (e, st) {
      debugPrint('[ScanRecordStore] flush failed: $e\n$st');
    } finally {
      completer.complete();
    }
  }

  static List<ScanRecord> _sortNewestFirst(List<ScanRecord> rs) {
    final out = [...rs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  // ─── (de)serialization ──────────────────────────────────────────────

  static Map<String, dynamic> _recordToJson(ScanRecord r) => <String, dynamic>{
    'id': r.id,
    'name': r.name,
    'createdAt': r.createdAt.toIso8601String(),
    if (r.preferredCaptureMode != CaptureMode.local)
      'preferredCaptureMode': r.preferredCaptureMode.name,
    if (r.thumbnailPath != null) 'thumbnailPath': r.thumbnailPath,
    if (r.artifactPath != null) 'artifactPath': r.artifactPath,
    if (r.captureDir != null) 'captureDir': r.captureDir,
    if (r.photosDir != null) 'photosDir': r.photosDir,
    if (r.captureManifestPath != null)
      'captureManifestPath': r.captureManifestPath,
    if (r.photoCount != null) 'photoCount': r.photoCount,
    if (r.cloudUploadStatus != ScanCloudUploadStatus.none)
      'cloudUploadStatus': r.cloudUploadStatus.wireName,
    if (r.cloudScanId != null) 'cloudScanId': r.cloudScanId,
    if (r.cloudManifestPath != null) 'cloudManifestPath': r.cloudManifestPath,
    if (r.cloudWorkId != null) 'cloudWorkId': r.cloudWorkId,
    if (r.cloudArtifactPath != null) 'cloudArtifactPath': r.cloudArtifactPath,
    if (r.uploadedFrameCount != null)
      'uploadedFrameCount': r.uploadedFrameCount,
    if (r.uploadedAt != null) 'uploadedAt': r.uploadedAt!.toIso8601String(),
    if (r.localRawDeletedAt != null)
      'localRawDeletedAt': r.localRawDeletedAt!.toIso8601String(),
    if (r.cloudRawDeletedAt != null)
      'cloudRawDeletedAt': r.cloudRawDeletedAt!.toIso8601String(),
    if (r.cloudUploadFailureMessage != null)
      'cloudUploadFailureMessage': r.cloudUploadFailureMessage,
    if (r.localRawRetainedForDebug)
      'localRawRetainedForDebug': r.localRawRetainedForDebug,
    if (r.caption != null) 'caption': r.caption,
    // Plan G W2 全本地 (2026-05-16): jobStatus / jobId / pipelineStage
    // / publishedWorkId / videoSizeBytes / failureMessage were
    // cloud-lifecycle fields. Legacy on-disk records that still have
    // those keys are dropped silently by `_recordFromJson`.
  };

  static ScanRecord _recordFromJson(Map<String, dynamic> j) {
    final captureModeName = j['preferredCaptureMode'] as String?;
    return ScanRecord(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      preferredCaptureMode: captureModeName == null
          ? CaptureMode.local
          : CaptureMode.values.firstWhere(
              (m) => m.name == captureModeName,
              orElse: () => CaptureMode.local,
            ),
      thumbnailPath: j['thumbnailPath'] as String?,
      artifactPath: j['artifactPath'] as String?,
      captureDir: j['captureDir'] as String?,
      photosDir: j['photosDir'] as String?,
      captureManifestPath: j['captureManifestPath'] as String?,
      photoCount: (j['photoCount'] as num?)?.toInt(),
      cloudUploadStatus: ScanCloudUploadStatusWire.fromWireName(
        j['cloudUploadStatus'] as String?,
      ),
      cloudScanId: j['cloudScanId'] as String?,
      cloudManifestPath: j['cloudManifestPath'] as String?,
      cloudWorkId: j['cloudWorkId'] as String?,
      cloudArtifactPath: j['cloudArtifactPath'] as String?,
      uploadedFrameCount: (j['uploadedFrameCount'] as num?)?.toInt(),
      uploadedAt: DateTime.tryParse(j['uploadedAt'] as String? ?? ''),
      localRawDeletedAt: DateTime.tryParse(
        j['localRawDeletedAt'] as String? ?? '',
      ),
      cloudRawDeletedAt: DateTime.tryParse(
        j['cloudRawDeletedAt'] as String? ?? '',
      ),
      cloudUploadFailureMessage: j['cloudUploadFailureMessage'] as String?,
      localRawRetainedForDebug:
          (j['localRawRetainedForDebug'] as bool?) ?? false,
      caption: j['caption'] as String?,
      // Plan G W2 全本地 (2026-05-16): legacy records may still have
      // `jobStatus`, `jobId`, `pipelineStage`, `publishedWorkId`,
      // `videoSizeBytes`, `failureMessage`, `videoFilePath`,
      // `curatedManifestPath` keys from the cloud-upload era. All
      // dropped silently here.
    );
  }
}
