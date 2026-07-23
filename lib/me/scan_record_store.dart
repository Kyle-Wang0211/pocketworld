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
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

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
  ScanRecordStore._({Directory? documentsDirectory})
    : _documentsDirectoryOverride = documentsDirectory;
  static final ScanRecordStore instance = ScanRecordStore._();

  /// Isolated store used by persistence contract tests. Production continues
  /// to use [instance] and `path_provider`.
  @visibleForTesting
  ScanRecordStore.forTesting({required Directory documentsDirectory})
    : _documentsDirectoryOverride = documentsDirectory;

  final Directory? _documentsDirectoryOverride;

  /// Snapshot of the current store. Modifying this list directly is a
  /// no-op (we always return a defensive copy from `records`).
  List<ScanRecord> _records = const <ScanRecord>[];
  Future<void>? _loadFuture;
  Object? _loadFailure;
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
      _loadFailure = e;
      _records = const <ScanRecord>[];
      _emit();
      return;
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
        final crossesRoute = _crossesPipelineNamespace(
          rec.thumbnailPath!,
          pipelineKind: rec.pipelineKind,
        );
        if (!File(rec.thumbnailPath!).existsSync() || crossesRoute) {
          final fresh = await thumbnailFileFor(
            rec.id,
            pipelineKind: rec.pipelineKind,
          );
          if (await fresh.exists()) {
            rec = rec.copyWith(thumbnailPath: fresh.path);
            rewrites++;
          } else if (crossesRoute) {
            // A path into the other route must not become valid later merely
            // because a same-id artifact is created there.
            rec = rec.copyWith(clearThumbnailPath: true);
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
        final crossesRoute = _crossesPipelineNamespace(
          p,
          pipelineKind: rec.pipelineKind,
        );
        if (!File(p).existsSync() || crossesRoute) {
          final fresh = await glbFileFor(
            rec.id,
            pipelineKind: rec.pipelineKind,
          );
          if (await fresh.exists()) {
            rec = rec.copyWith(artifactPath: 'file://${fresh.path}');
            rewrites++;
          } else if (crossesRoute) {
            rec = rec.copyWith(clearArtifactPath: true);
            rewrites++;
          }
        }
      }
      final captureMetadata = <String?>[
        rec.captureDir,
        rec.photosDir,
        rec.captureManifestPath,
      ].whereType<String>().where((path) => path.isNotEmpty).toList();
      if (captureMetadata.isNotEmpty) {
        final routeRoot = await _capturesRoot(pipelineKind: rec.pipelineKind);
        final suppliedCaptureDir = rec.captureDir == null
            ? null
            : Directory(rec.captureDir!);
        final allPathsOwned = captureMetadata.every(
          (path) =>
              !_crossesPipelineNamespace(
                path,
                pipelineKind: rec.pipelineKind,
              ) &&
              _isWithinDirectory(path, routeRoot.path),
        );
        var captureDir = allPathsOwned && suppliedCaptureDir != null
            ? suppliedCaptureDir
            : await captureDirFor(rec.id, pipelineKind: rec.pipelineKind);
        if (!await captureDir.exists()) {
          captureDir = await captureDirFor(
            rec.id,
            pipelineKind: rec.pipelineKind,
          );
        }
        if (await captureDir.exists() &&
            _isWithinDirectory(captureDir.path, routeRoot.path)) {
          final paths = await _capturePaths(
            captureDir,
            pipelineKind: rec.pipelineKind,
          );
          if (rec.captureDir != captureDir.path ||
              rec.photosDir != paths.photosDir.path ||
              rec.captureManifestPath != paths.manifestFile.path) {
            rec = rec.copyWith(
              captureDir: captureDir.path,
              photosDir: paths.photosDir.path,
              captureManifestPath: paths.manifestFile.path,
            );
            rewrites++;
          }
        } else {
          // Never retain stale or cross-route capture metadata. In particular,
          // an official record must not spring back to life if a self capture
          // with the same id later appears (and vice versa).
          rec = _withoutCaptureMetadata(rec);
          rewrites++;
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
  /// `Documents/captures/*/photos` and rehydrate any missing record.
  Future<int> _recoverOrphanCaptures() async {
    try {
      final root = await _documentsDirectory();
      final existingIds = _records.map((r) => r.id).toSet();
      final recovered = <ScanRecord>[];
      final roots = <(Directory, CapturePipelineKind)>[
        (Directory('${root.path}/captures'), CapturePipelineKind.self),
        (
          Directory('${root.path}/captures_official'),
          CapturePipelineKind.official,
        ),
      ];
      for (final (capturesRoot, pipelineKind) in roots) {
        if (!await capturesRoot.exists()) continue;
        await for (final entity in capturesRoot.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final captureId = entity.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull;
          if (captureId == null || existingIds.contains(captureId)) continue;
          final paths = await _capturePaths(entity, pipelineKind: pipelineKind);
          final photosDir = paths.photosDir;
          if (!await photosDir.exists()) continue;
          final photos = <File>[];
          await for (final photoEntity in photosDir.list(followLinks: false)) {
            if (photoEntity is! File) continue;
            final path = photoEntity.path.toLowerCase();
            if (!path.endsWith('.jpg') && !path.endsWith('.jpeg')) continue;
            final metadata = File(
              photoEntity.path.replaceFirst(RegExp(r'\.[^.]+$'), '.json'),
            );
            if (await metadata.exists()) photos.add(photoEntity);
          }
          if (photos.isEmpty) continue;
          photos.sort((a, b) => a.path.compareTo(b.path));
          final manifestFile = paths.manifestFile;
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
              pipelineKind: pipelineKind,
            );
          }
          String? thumbnailPath;
          try {
            final thumbnail = await thumbnailFileFor(
              captureId,
              pipelineKind: pipelineKind,
            );
            await thumbnail.parent.create(recursive: true);
            await photos.first.copy(thumbnail.path);
            thumbnailPath = thumbnail.path;
          } on FileSystemException {
            thumbnailPath = photos.first.path;
          }
          recovered.add(
            ScanRecord(
              id: captureId,
              name: '未命名(${_records.length + recovered.length + 1})',
              createdAt: createdAt,
              pipelineKind: pipelineKind,
              preferredCaptureMode: CaptureMode.newRemote,
              thumbnailPath: thumbnailPath,
              captureDir: entity.path,
              photosDir: photosDir.path,
              captureManifestPath: manifestFile.path,
              photoCount: photos.length,
              cloudUploadStatus: ScanCloudUploadStatus.localPending,
              localRawRetainedForDebug: true,
            ),
          );
          existingIds.add(captureId);
        }
      }
      if (recovered.isEmpty) return 0;
      _records = _sortNewestFirst([..._records, ...recovered]);
      return recovered.length;
    } catch (e, st) {
      debugPrint('[ScanRecordStore] orphan capture recovery failed: $e\n$st');
      return 0;
    }
  }

  /// Resolve the route-owned image directory and manifest without ever mixing
  /// the recovery manifest schema into the canonical photo-bundle filename.
  /// Existing canonical and legacy manifests are left untouched; when neither
  /// exists, callers receive the route-specific legacy filename.
  Future<({Directory photosDir, File manifestFile})> _capturePaths(
    Directory captureDir, {
    required CapturePipelineKind pipelineKind,
  }) async {
    final photosHighres = Directory('${captureDir.path}/photos_highres');
    final photosDir = await photosHighres.exists()
        ? photosHighres
        : Directory('${captureDir.path}/photos');
    final preferredManifest = pipelineKind == CapturePipelineKind.official
        ? File('${captureDir.path}/official_photo_bundle.json')
        : File('${captureDir.path}/photo_bundle.json');
    final legacyManifest = pipelineKind == CapturePipelineKind.official
        ? File('${captureDir.path}/official_capture_manifest.json')
        : File('${captureDir.path}/capture_manifest.json');
    final manifestFile = await preferredManifest.exists()
        ? preferredManifest
        : legacyManifest;
    return (photosDir: photosDir, manifestFile: manifestFile);
  }

  Future<void> _writeRecoveredCaptureManifest({
    required File manifestFile,
    required String captureId,
    required DateTime createdAt,
    required Directory captureDir,
    required Directory photosDir,
    required List<File> photos,
    required CapturePipelineKind pipelineKind,
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
      'pipeline_kind': pipelineKind.wireName,
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
    _ensureWritable();
    await _ensureRouteOwnedPaths(r);
    final previous = byId(r.id);
    if (previous != null && previous.pipelineKind != r.pipelineKind) {
      throw StateError(
        'Cannot change pipeline kind for existing scan ${r.id}: '
        '${previous.pipelineKind.wireName} -> ${r.pipelineKind.wireName}',
      );
    }
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

  /// Delete by id. Best-effort removes the on-disk GLB + thumbnail too —
  /// failure to delete either doesn't fail the call (the record vanishes
  /// from the gallery either way; orphan files just leak ~30 MB of disk
  /// until next reinstall).
  Future<void> delete(String id) async {
    await ensureLoaded();
    _ensureWritable();
    // Resolve ownership before removing the record from memory. Legacy callers
    // that delete an unknown id retain the historical self-route behaviour,
    // while an official record can never touch `Documents/scans`.
    final pipelineKind = byId(id)?.pipelineKind ?? CapturePipelineKind.self;
    _records = _records.where((r) => r.id != id).toList(growable: false);
    _emit();
    await _flush();
    // Cleanup artifact + thumbnail + retry sources, best-effort.
    try {
      final f = await glbFileFor(id, pipelineKind: pipelineKind);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      final t = await thumbnailFileFor(id, pipelineKind: pipelineKind);
      if (await t.exists()) await t.delete();
    } catch (_) {}
  }

  /// Where on disk to persist `<id>.glb` for a given record. W3 (待实现)
  /// will write the local-generated GLB here.
  Future<File> glbFileFor(
    String id, {
    CapturePipelineKind pipelineKind = CapturePipelineKind.self,
  }) async {
    final dir = await _scansDir(pipelineKind: pipelineKind);
    return File('${dir.path}/$id.glb');
  }

  Future<Directory> captureDirFor(
    String id, {
    CapturePipelineKind pipelineKind = CapturePipelineKind.self,
  }) async {
    final root = await _capturesRoot(pipelineKind: pipelineKind);
    return Directory('${root.path}/$id');
  }

  Future<Directory> _capturesRoot({
    required CapturePipelineKind pipelineKind,
  }) async {
    final root = await _documentsDirectory();
    final directoryName = pipelineKind == CapturePipelineKind.official
        ? 'captures_official'
        : 'captures';
    return Directory('${root.path}/$directoryName');
  }

  /// Where on disk to persist the scan card's cover thumbnail. Plan G
  /// W2 全本地 (2026-05-16) — a future Drafts UI revamp can populate
  /// this from the first cell-admitted JPEG in `<captureDir>/photos/`.
  Future<File> thumbnailFileFor(
    String id, {
    CapturePipelineKind pipelineKind = CapturePipelineKind.self,
  }) async {
    final dir = await _scansDir(pipelineKind: pipelineKind);
    return File('${dir.path}/$id.jpg');
  }

  Future<Directory> _scansDir({
    required CapturePipelineKind pipelineKind,
  }) async {
    final root = await _documentsDirectory();
    final directoryName = pipelineKind == CapturePipelineKind.official
        ? 'scans_official'
        : 'scans';
    final dir = Directory('${root.path}/$directoryName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _storeFile() async {
    final root = await _documentsDirectory();
    return File('${root.path}/scan_records.json');
  }

  Future<Directory> _documentsDirectory() async {
    return _documentsDirectoryOverride ??
        await getApplicationDocumentsDirectory();
  }

  static bool _crossesPipelineNamespace(
    String rawPath, {
    required CapturePipelineKind pipelineKind,
  }) {
    final path = rawPath.startsWith('file://') ? rawPath.substring(7) : rawPath;
    final segments = path
        .split(RegExp(r'[/\\]+'))
        .where((segment) => segment.isNotEmpty)
        .toSet();
    final otherRouteDirectories = pipelineKind == CapturePipelineKind.official
        ? const <String>{'scans', 'captures'}
        : const <String>{'scans_official', 'captures_official'};
    return segments.any(otherRouteDirectories.contains);
  }

  Future<void> _ensureRouteOwnedPaths(ScanRecord record) async {
    final paths = <String?>[record.thumbnailPath, record.artifactPath];
    for (final path in paths) {
      if (path == null || path.isEmpty) continue;
      if (_crossesPipelineNamespace(path, pipelineKind: record.pipelineKind)) {
        throw StateError(
          'Scan ${record.id} (${record.pipelineKind.wireName}) references '
          'an artifact owned by the other pipeline: $path',
        );
      }
    }

    final captureRoot = await _capturesRoot(pipelineKind: record.pipelineKind);
    final capturePaths = <String?>[
      record.captureDir,
      record.photosDir,
      record.captureManifestPath,
    ];
    for (final path in capturePaths) {
      if (path == null || path.isEmpty) continue;
      if (_crossesPipelineNamespace(path, pipelineKind: record.pipelineKind) ||
          !_isWithinDirectory(path, captureRoot.path)) {
        throw StateError(
          'Scan ${record.id} (${record.pipelineKind.wireName}) references '
          'capture metadata outside its route-owned namespace: $path',
        );
      }
    }
  }

  static bool _isWithinDirectory(String rawPath, String rawRoot) {
    final path = _normalizedFilePath(rawPath);
    final root = _normalizedFilePath(rawRoot);
    return path == root || path.startsWith('$root${Platform.pathSeparator}');
  }

  static String _normalizedFilePath(String rawPath) {
    final path = rawPath.startsWith('file://')
        ? Uri.parse(rawPath).toFilePath()
        : File(rawPath).absolute.path;
    return Uri.file(path).normalizePath().toFilePath();
  }

  static ScanRecord _withoutCaptureMetadata(ScanRecord record) {
    final json = _recordToJson(record)
      ..remove('captureDir')
      ..remove('photosDir')
      ..remove('captureManifestPath');
    return _recordFromJson(json);
  }

  void _ensureWritable() {
    final failure = _loadFailure;
    if (failure != null) {
      throw StateError(
        'scan_records.json failed validation; refusing to overwrite it: '
        '$failure',
      );
    }
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
    'pipeline_kind': r.pipelineKind.wireName,
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
    final pipelineKind = j.containsKey('pipeline_kind')
        ? CapturePipelineKindWire.fromWireName(j['pipeline_kind'])
        : CapturePipelineKind.self;
    return ScanRecord(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      pipelineKind: pipelineKind,
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
