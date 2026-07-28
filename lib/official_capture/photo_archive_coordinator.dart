import 'dart:collection';
import 'dart:io';

import 'photo_archive_codec.dart';
import 'photo_archive_policy.dart';
import 'photo_archive_transaction.dart';

class PhotoArchiveActivityLease {
  PhotoArchiveActivityLease(this._onClose);

  final Future<void> Function() _onClose;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }
}

/// Serializes cold JPEG XL archive work across official captures.
class PhotoArchiveCoordinator {
  PhotoArchiveCoordinator({required this.codec});

  final PhotoArchiveCodec codec;
  final LinkedHashMap<String, Directory> _pending =
      LinkedHashMap<String, Directory>();
  final Set<String> _reconstructionOwners = <String>{};
  int _foregroundActivityCount = 0;
  Future<void>? _pumpFuture;

  PhotoArchiveActivityLease beginCaptureActivity() {
    _foregroundActivityCount++;
    return PhotoArchiveActivityLease(() async {
      if (_foregroundActivityCount > 0) _foregroundActivityCount--;
      await _pumpQueue();
    });
  }

  PhotoArchiveActivityLease beginReconstructionActivity(
    Directory captureDirectory,
  ) {
    final path = _canonicalKey(captureDirectory);
    _foregroundActivityCount++;
    _reconstructionOwners.add(path);
    return PhotoArchiveActivityLease(() async {
      if (_foregroundActivityCount > 0) _foregroundActivityCount--;
      _reconstructionOwners.remove(path);
      _pending[path] = captureDirectory.absolute;
      await _pumpQueue();
    });
  }

  Future<void> noteArtifactsPersisted(Directory captureDirectory) async {
    _pending[_canonicalKey(captureDirectory)] = captureDirectory.absolute;
    await _pumpQueue();
  }

  /// Restarts only work explicitly opted in by the creation-time marker.
  Future<void> discoverUnderDocuments(Directory documentsDirectory) async {
    final captures = Directory('${documentsDirectory.path}/captures_official');
    try {
      if (!await captures.exists()) return;
      final directories = <Directory>[];
      await for (final entity in captures.list(followLinks: false)) {
        if (entity is Directory) directories.add(entity);
      }
      directories.sort((left, right) => left.path.compareTo(right.path));
      for (final capture in directories) {
        if (await PhotoArchivePolicy.readCompatible(capture) == null) {
          continue;
        }
        _pending[_canonicalKey(capture)] = capture.absolute;
      }
      await _pumpQueue();
    } on FileSystemException {
      // Startup recovery is best effort and always fails closed.
    }
  }

  Future<void> _pumpQueue() {
    final existing = _pumpFuture;
    if (existing != null) return existing;
    late final Future<void> started;
    started = _runPump().whenComplete(() {
      if (identical(_pumpFuture, started)) _pumpFuture = null;
    });
    _pumpFuture = started;
    return started;
  }

  Future<void> _runPump() async {
    while (_pending.isNotEmpty && _foregroundActivityCount == 0) {
      final item = _pending.entries.first;
      _pending.remove(item.key);
      if (_reconstructionOwners.contains(item.key)) {
        _pending[item.key] = item.value;
        return;
      }
      if (!await _isDurablyReady(item.value)) continue;
      final result = await PhotoArchiveTransaction(
        codec: codec,
        canStartNext: () => _foregroundActivityCount == 0,
      ).archiveCapture(item.value);
      if (result.paused) {
        _pending[item.key] = item.value;
        return;
      }
    }
  }

  Future<bool> _isDurablyReady(Directory captureDirectory) async {
    if (await PhotoArchivePolicy.readCompatible(captureDirectory) == null) {
      return false;
    }
    for (final relativePath in const <String>[
      'official_photo_bundle.json',
      'official_sfm_sparse.ply',
      'official_sfm_sparse_meta.json',
    ]) {
      final file = File('${captureDirectory.path}/$relativePath');
      try {
        if (!await file.exists() || await file.length() == 0) return false;
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  String _canonicalKey(Directory directory) => directory.absolute.path;
}
