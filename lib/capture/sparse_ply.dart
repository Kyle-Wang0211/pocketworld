// sparse_ply.dart — persists each take's sparse reconstruction next to its
// capture bundle (硬性铁律: delivery is ALWAYS the full point set — no
// downsampling here, render-side thinning only ever happens in viewers).
//
// Publication uses a single atomically-renamed commit marker as durable truth.
// Both files are fully written, flushed and cross-validated first. If the
// process dies between the two compatibility-path renames, the transaction
// journal + previous pair deterministically roll forward/back on next verify.
// An existing LOCAL_READY pair may only be replaced by one REFINED pair unless
// an explicit user-requested regeneration opts into REFINED -> REFINED.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../util/device_log.dart';
import 'sfm_live_recon.dart';

const String _plyName = 'sfm_sparse.ply';
const String _metaName = 'sfm_sparse_meta.json';
const String _commitName = 'sfm_sparse_commit.json';
const String _transactionName = '.sfm_sparse_transaction.json';
const String _stagedPlyName = '.sfm_sparse_staged.ply';
const String _stagedMetaName = '.sfm_sparse_staged_meta.json';
const String _previousPlyName = '.sfm_sparse_previous.ply';
const String _previousMetaName = '.sfm_sparse_previous_meta.json';
const String _schema = 'pw_sfm_sparse_meta_v1';
const String _commitSchema = 'pw_sfm_sparse_commit_v1';
const String _transactionSchema = 'pw_sfm_sparse_transaction_v1';
const int _vertexStride = 15;

final Map<String, Future<void>> _persistTails = <String, Future<void>>{};
int _persistSequence = 0;

/// Identity and integrity proof for one successfully published sparse pair.
///
/// Callers that release replay payloads must verify this exact receipt first;
/// merely observing that old files exist is not proof that this write landed.
class SparsePersistReceipt {
  const SparsePersistReceipt({
    required this.artifactId,
    required this.pointCount,
    required this.refined,
    required this.plyBytes,
    required this.plySha256,
    required this.metaBytes,
    required this.metaSha256,
  });

  final String artifactId;
  final int pointCount;
  final bool refined;
  final int plyBytes;
  final String plySha256;
  final int metaBytes;
  final String metaSha256;
}

enum SparsePublicationViewState { none, committed, legacyPlyOnly, invalid }

/// Read-only UI classification. `legacyPlyOnly` is structurally viewable but
/// is deliberately not a durable commit receipt and can never authorize replay
/// cleanup. The caller may additionally require that no DB/queue is present.
class SparsePublicationViewInspection {
  const SparsePublicationViewInspection({
    required this.state,
    this.receipt,
    this.pointCount,
    this.error,
  });

  final SparsePublicationViewState state;
  final SparsePersistReceipt? receipt;
  final int? pointCount;
  final Object? error;
}

/// Atomically publishes a complete PLY/metadata pair and returns proof of this
/// exact generation. Filesystem and validation errors are logged and rethrown.
Future<SparsePersistReceipt> persistSparseSnapshot({
  required String captureDir,
  required SfmLiveSnapshot snapshot,
  required Uint8List rgb,
  bool allowRefinedReplacement = false,
}) {
  return _withSparseLock<SparsePersistReceipt>(
    captureDir,
    () => _persistSparseSnapshot(
      captureDir: captureDir,
      snapshot: snapshot,
      rgb: rgb,
      allowRefinedReplacement: allowRefinedReplacement,
    ),
  );
}

Future<T> _withSparseLock<T>(
  String captureDir,
  Future<T> Function() operation,
) {
  // Writers, verifiers and crash recovery share one lock. Otherwise a scanner
  // could mistake an in-flight journal for a crashed process and roll it back.
  final previous = _persistTails[captureDir] ?? Future<void>.value();
  final result = previous.then<T>((_) => operation());
  late final Future<void> settled;
  settled = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  _persistTails[captureDir] = settled;
  return result.whenComplete(() {
    if (identical(_persistTails[captureDir], settled)) {
      _persistTails.remove(captureDir);
    }
  });
}

/// Verifies the on-disk pair against the snapshot/generation the caller just
/// persisted. This is the only safe predicate before acknowledging and
/// deleting replay-owned gray payloads.
Future<SparsePersistReceipt> verifyPersistedSparseSnapshot({
  required String captureDir,
  required SparsePersistReceipt expectedReceipt,
}) async {
  final committed = await recoverSparsePublication(captureDir: captureDir);
  if (committed == null) {
    throw StateError('no committed sparse artifact exists');
  }
  if (!_sameReceipt(committed, expectedReceipt)) {
    throw StateError('committed sparse artifact does not match write receipt');
  }
  return committed;
}

/// Repairs an interrupted two-path materialization according to the atomic
/// commit marker, then returns the only generation safe to acknowledge.
Future<SparsePersistReceipt?> recoverSparsePublication({
  required String captureDir,
}) => _withSparseLock<SparsePersistReceipt?>(
  captureDir,
  () => _recoverSparsePublication(captureDir: captureDir),
);

Future<SparsePublicationViewInspection> inspectSparsePublicationForViewing({
  required String captureDir,
}) => _withSparseLock<SparsePublicationViewInspection>(captureDir, () async {
  try {
    final receipt = await _recoverSparsePublication(captureDir: captureDir);
    return SparsePublicationViewInspection(
      state: receipt == null
          ? SparsePublicationViewState.none
          : SparsePublicationViewState.committed,
      receipt: receipt,
      pointCount: receipt?.pointCount,
    );
  } catch (error) {
    final ply = File('$captureDir/$_plyName');
    final isUnambiguousLegacyPlyOnly =
        await ply.exists() &&
        !await File('$captureDir/$_metaName').exists() &&
        !await File('$captureDir/$_commitName').exists() &&
        !await File('$captureDir/$_transactionName').exists();
    if (isUnambiguousLegacyPlyOnly) {
      try {
        final validated = await _validatePly(ply);
        return SparsePublicationViewInspection(
          state: SparsePublicationViewState.legacyPlyOnly,
          pointCount: validated.pointCount,
          error: error,
        );
      } catch (plyError) {
        return SparsePublicationViewInspection(
          state: SparsePublicationViewState.invalid,
          error: plyError,
        );
      }
    }
    return SparsePublicationViewInspection(
      state: SparsePublicationViewState.invalid,
      error: error,
    );
  }
});

Future<SparsePersistReceipt?> _recoverSparsePublication({
  required String captureDir,
}) async {
  final directory = Directory(captureDir);
  if (!await directory.exists()) {
    throw FileSystemException(
      'capture directory does not exist or is not a directory',
      captureDir,
    );
  }
  await _recoverInterruptedTransaction(captureDir);
  final ply = File('$captureDir/$_plyName');
  final meta = File('$captureDir/$_metaName');
  final markerFile = File('$captureDir/$_commitName');
  final hasPly = await ply.exists();
  final hasMeta = await meta.exists();
  if (hasPly != hasMeta) {
    throw StateError('committed sparse PLY/metadata pair is partial');
  }
  if (!hasPly) {
    if (await markerFile.exists()) {
      throw StateError('sparse commit marker exists without its artifact');
    }
    return null;
  }

  final pair = await _validatePair(ply, meta, requireLinkedMetadata: false);
  if (!await markerFile.exists()) {
    // One-time migration for captures created before the commit marker. The
    // marker pins exact bytes/count; the legacy pair itself remains untouched.
    // A new-format linked pair without a marker is instead an uncommitted
    // crash remnant and must never be promoted merely because both paths exist.
    if (pair.receipt != null) {
      throw StateError('linked sparse pair has no atomic commit marker');
    }
    final legacy = SparsePersistReceipt(
      artifactId:
          'legacy-${pair.plySha256.substring(0, 16)}-'
          '${pair.pointCount}-${pair.refined ? 1 : 0}',
      pointCount: pair.pointCount,
      refined: pair.refined,
      plyBytes: pair.plyBytes,
      plySha256: pair.plySha256,
      metaBytes: pair.metaBytes,
      metaSha256: pair.metaSha256,
    );
    await _publishCommitMarker(captureDir, legacy);
    return legacy;
  }
  final marker = await _readCommitMarker(markerFile);
  _requireMarkerMatchesPair(marker, pair);
  return marker;
}

/// Removes only an invalid/uncommitted sparse publication so reconstruction
/// can retry. A valid committed generation is never deleted by this API.
/// User JPEGs, AR sidecars, the live DB and replay gray are outside its scope.
Future<void> discardInvalidSparsePublication({required String captureDir}) =>
    _withSparseLock<void>(captureDir, () async {
      SparsePersistReceipt? valid;
      Object? invalidReason;
      try {
        valid = await _recoverSparsePublication(captureDir: captureDir);
      } catch (error) {
        invalidReason = error;
      }
      if (valid != null) {
        throw StateError(
          'refusing to discard valid sparse artifact ${valid.artifactId}',
        );
      }
      final names = <String>[
        _plyName,
        _metaName,
        _commitName,
        _transactionName,
        '$_transactionName.tmp',
        _stagedPlyName,
        _stagedMetaName,
        _previousPlyName,
        _previousMetaName,
      ];
      for (final name in names) {
        await _deleteRequired(File('$captureDir/$name'));
      }
      if (invalidReason != null) {
        DeviceLog.log(
          'SfmLive',
          'discarded invalid sparse publication before retry: $invalidReason',
        );
      }
    });

Future<SparsePersistReceipt> _persistSparseSnapshot({
  required String captureDir,
  required SfmLiveSnapshot snapshot,
  required Uint8List rgb,
  required bool allowRefinedReplacement,
}) async {
  try {
    _validateSnapshot(snapshot, rgb);
    final directory = Directory(captureDir);
    if (!await directory.exists()) {
      throw FileSystemException(
        'capture directory does not exist or is not a directory',
        captureDir,
      );
    }

    final previousReceipt = await _recoverSparsePublication(
      captureDir: captureDir,
    );
    if (previousReceipt != null) {
      final isLocalToRefined = !previousReceipt.refined && snapshot.refined;
      final isExplicitRegeneration =
          previousReceipt.refined &&
          snapshot.refined &&
          allowRefinedReplacement;
      if (!isLocalToRefined && !isExplicitRegeneration) {
        throw StateError(
          'refusing sparse overwrite: existing refined='
          '${previousReceipt.refined}, incoming refined=${snapshot.refined}, '
          'allowRefinedReplacement=$allowRefinedReplacement',
        );
      }
    }

    final artifactId =
        '${DateTime.now().microsecondsSinceEpoch}-$pid-'
        '${_persistSequence++}';
    final payload = _encodeArtifact(snapshot, rgb, artifactId);
    final finalPly = File('$captureDir/$_plyName');
    final finalMeta = File('$captureDir/$_metaName');
    final stagedPly = File('$captureDir/$_stagedPlyName');
    final stagedMeta = File('$captureDir/$_stagedMetaName');
    final previousPly = File('$captureDir/$_previousPlyName');
    final previousMeta = File('$captureDir/$_previousMetaName');
    final transaction = File('$captureDir/$_transactionName');
    await _deleteRequired(stagedPly);
    await _deleteRequired(stagedMeta);
    await _deleteRequired(previousPly);
    await _deleteRequired(previousMeta);

    var transactionStarted = false;
    var cleanupStaging = true;
    try {
      await stagedPly.writeAsBytes(payload.plyBytes, flush: true);
      await stagedMeta.writeAsBytes(payload.metaBytes, flush: true);
      await _validatePair(
        stagedPly,
        stagedMeta,
        requireLinkedMetadata: true,
        expectedArtifactId: artifactId,
        expectedRefined: snapshot.refined,
        expectedPointCount: snapshot.pointCount,
      );

      await _writeJsonAtomically(transaction, <String, Object?>{
        'schema': _transactionSchema,
        'new_artifact_id': artifactId,
        'had_previous': previousReceipt != null,
        'previous_artifact_id': previousReceipt?.artifactId,
      });
      transactionStarted = true;
      if (previousReceipt != null) {
        await finalPly.rename(previousPly.path);
        await finalMeta.rename(previousMeta.path);
      }
      await stagedPly.rename(finalPly.path);
      await stagedMeta.rename(finalMeta.path);

      final published = await _validatePair(
        finalPly,
        finalMeta,
        requireLinkedMetadata: true,
        expectedArtifactId: artifactId,
        expectedRefined: snapshot.refined,
        expectedPointCount: snapshot.pointCount,
      );
      final receipt = published.receipt!;
      // This single rename is the commit point. Before it, recovery restores
      // the previous marker generation; after it, recovery keeps this pair.
      await _publishCommitMarker(captureDir, receipt);
      await _deleteBestEffort(previousPly);
      await _deleteBestEffort(previousMeta);
      await _deleteBestEffort(transaction);
      _logTrackHistogram(snapshot);
      DeviceLog.log(
        'SfmLive',
        'sparse persisted: ${snapshot.pointCount} pts '
            '(refined=${snapshot.refined}, artifact=$artifactId) '
            '→ $captureDir/$_plyName',
      );
      return receipt;
    } catch (error, stackTrace) {
      if (transactionStarted || await transaction.exists()) {
        cleanupStaging = false;
        try {
          await _recoverInterruptedTransaction(captureDir);
          cleanupStaging = true;
        } catch (rollbackError) {
          Error.throwWithStackTrace(
            StateError(
              'sparse publication failed ($error); recovery also failed: '
              '$rollbackError',
            ),
            stackTrace,
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (cleanupStaging) {
        await _deleteBestEffort(stagedPly);
        await _deleteBestEffort(stagedMeta);
      }
    }
  } catch (error, stackTrace) {
    DeviceLog.log('SfmLive', 'sparse persist FAILED: $error');
    Error.throwWithStackTrace(error, stackTrace);
  }
}

Future<void> _recoverInterruptedTransaction(String captureDir) async {
  final transaction = File('$captureDir/$_transactionName');
  if (!await transaction.exists()) return;

  dynamic decoded;
  try {
    decoded = jsonDecode(await transaction.readAsString());
  } catch (error) {
    throw StateError('sparse transaction journal is corrupt: $error');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['schema'] != _transactionSchema ||
      decoded['new_artifact_id'] is! String ||
      decoded['had_previous'] is! bool) {
    throw StateError('sparse transaction journal is incomplete');
  }
  final newArtifactId = decoded['new_artifact_id'] as String;
  final hadPrevious = decoded['had_previous'] as bool;
  final previousArtifactId = decoded['previous_artifact_id'];
  if (hadPrevious && previousArtifactId is! String) {
    throw StateError('sparse transaction has no previous generation');
  }

  final finalPly = File('$captureDir/$_plyName');
  final finalMeta = File('$captureDir/$_metaName');
  final previousPly = File('$captureDir/$_previousPlyName');
  final previousMeta = File('$captureDir/$_previousMetaName');
  final stagedPly = File('$captureDir/$_stagedPlyName');
  final stagedMeta = File('$captureDir/$_stagedMetaName');
  final markerFile = File('$captureDir/$_commitName');
  final marker = await markerFile.exists()
      ? await _readCommitMarker(markerFile)
      : null;

  if (marker?.artifactId == newArtifactId) {
    // Commit marker already advanced: the new pair is authoritative.
    final pair = await _validatePair(
      finalPly,
      finalMeta,
      requireLinkedMetadata: true,
      expectedArtifactId: newArtifactId,
      expectedRefined: marker!.refined,
      expectedPointCount: marker.pointCount,
    );
    _requireMarkerMatchesPair(marker, pair);
  } else if (hadPrevious) {
    if (marker == null || marker.artifactId != previousArtifactId) {
      throw StateError('sparse transaction previous marker is missing/stale');
    }
    await _restoreOnePath(finalPly, previousPly);
    await _restoreOnePath(finalMeta, previousMeta);
    final restored = await _validatePair(
      finalPly,
      finalMeta,
      requireLinkedMetadata: false,
    );
    _requireMarkerMatchesPair(marker, restored);
  } else {
    // No prior committed generation existed, so every installed path belongs
    // to the uncommitted transaction and must be removed.
    if (marker != null) {
      throw StateError('unexpected sparse marker in initial transaction');
    }
    await _deleteRequired(finalPly);
    await _deleteRequired(finalMeta);
  }

  await _deleteBestEffort(stagedPly);
  await _deleteBestEffort(stagedMeta);
  await _deleteBestEffort(previousPly);
  await _deleteBestEffort(previousMeta);
  await _deleteRequired(transaction);
}

Future<void> _restoreOnePath(File current, File previous) async {
  if (await previous.exists()) {
    await _deleteRequired(current);
    await previous.rename(current.path);
  } else if (!await current.exists()) {
    throw StateError('sparse rollback has neither current nor previous path');
  }
}

Future<void> _publishCommitMarker(
  String captureDir,
  SparsePersistReceipt receipt,
) async {
  final marker = File('$captureDir/$_commitName');
  await _writeJsonAtomically(marker, <String, Object?>{
    'schema': _commitSchema,
    'artifact_id': receipt.artifactId,
    'n_points': receipt.pointCount,
    'refined': receipt.refined,
    'ply_bytes': receipt.plyBytes,
    'ply_sha256': receipt.plySha256,
    'meta_bytes': receipt.metaBytes,
    'meta_sha256': receipt.metaSha256,
  });
  final written = await _readCommitMarker(marker);
  if (!_sameReceipt(written, receipt)) {
    throw StateError('sparse commit marker did not persist exact receipt');
  }
}

Future<void> _writeJsonAtomically(
  File destination,
  Map<String, Object?> value,
) async {
  final temporary = File('${destination.path}.tmp');
  await _deleteRequired(temporary);
  try {
    await temporary.writeAsString(jsonEncode(value), flush: true);
    final check = jsonDecode(await temporary.readAsString());
    if (check is! Map<String, dynamic>) {
      throw StateError('staged JSON is not an object');
    }
    await temporary.rename(destination.path);
  } finally {
    await _deleteBestEffort(temporary);
  }
}

Future<SparsePersistReceipt> _readCommitMarker(File marker) async {
  dynamic decoded;
  try {
    decoded = jsonDecode(await marker.readAsString());
  } catch (error) {
    throw StateError('sparse commit marker is not valid JSON: $error');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['schema'] != _commitSchema ||
      decoded['artifact_id'] is! String ||
      (decoded['artifact_id'] as String).isEmpty ||
      decoded['n_points'] is! int ||
      (decoded['n_points'] as int) <= 0 ||
      decoded['refined'] is! bool ||
      decoded['ply_bytes'] is! int ||
      (decoded['ply_bytes'] as int) <= 0 ||
      decoded['ply_sha256'] is! String ||
      (decoded['ply_sha256'] as String).length != 64 ||
      decoded['meta_bytes'] is! int ||
      (decoded['meta_bytes'] as int) <= 0 ||
      decoded['meta_sha256'] is! String ||
      (decoded['meta_sha256'] as String).length != 64) {
    throw StateError('sparse commit marker is incomplete');
  }
  return SparsePersistReceipt(
    artifactId: decoded['artifact_id'] as String,
    pointCount: decoded['n_points'] as int,
    refined: decoded['refined'] as bool,
    plyBytes: decoded['ply_bytes'] as int,
    plySha256: decoded['ply_sha256'] as String,
    metaBytes: decoded['meta_bytes'] as int,
    metaSha256: decoded['meta_sha256'] as String,
  );
}

void _requireMarkerMatchesPair(
  SparsePersistReceipt marker,
  _ValidatedPair pair,
) {
  if (marker.pointCount != pair.pointCount ||
      marker.refined != pair.refined ||
      marker.plyBytes != pair.plyBytes ||
      marker.plySha256 != pair.plySha256 ||
      marker.metaBytes != pair.metaBytes ||
      marker.metaSha256 != pair.metaSha256 ||
      (pair.receipt != null && marker.artifactId != pair.receipt!.artifactId)) {
    throw StateError('sparse commit marker does not match artifact bytes');
  }
}

bool _sameReceipt(SparsePersistReceipt a, SparsePersistReceipt b) =>
    a.artifactId == b.artifactId &&
    a.pointCount == b.pointCount &&
    a.refined == b.refined &&
    a.plyBytes == b.plyBytes &&
    a.plySha256 == b.plySha256 &&
    a.metaBytes == b.metaBytes &&
    a.metaSha256 == b.metaSha256;

void _validateSnapshot(SfmLiveSnapshot snapshot, Uint8List rgb) {
  final xyz = snapshot.xyz;
  if (xyz.isEmpty || xyz.length % 3 != 0) {
    throw ArgumentError.value(xyz.length, 'snapshot.xyz.length');
  }
  if (rgb.length != xyz.length) {
    throw ArgumentError.value(
      rgb.length,
      'rgb.length',
      'must be exactly 3 bytes per point (${xyz.length})',
    );
  }
  for (var i = 0; i < xyz.length; i++) {
    if (!xyz[i].isFinite) {
      throw ArgumentError('snapshot.xyz[$i] is not finite');
    }
  }
  final poses = snapshot.posesPacked;
  if (poses.length % 9 != 0) {
    throw ArgumentError.value(poses.length, 'snapshot.posesPacked.length');
  }
  final frameIds = <int>{};
  for (var i = 0; i < poses.length; i += 9) {
    for (var j = 0; j < 9; j++) {
      if (!poses[i + j].isFinite) {
        throw ArgumentError('snapshot.posesPacked[${i + j}] is not finite');
      }
    }
    if (poses[i] != poses[i].truncateToDouble()) {
      throw ArgumentError('frame id at pose ${i ~/ 9} is not an integer');
    }
    if (!frameIds.add(poses[i].toInt())) {
      throw ArgumentError('duplicate frame id ${poses[i].toInt()}');
    }
    if (poses[i + 1] != 0 && poses[i + 1] != 1) {
      throw ArgumentError('registered flag at pose ${i ~/ 9} is not 0/1');
    }
  }
}

({Uint8List plyBytes, Uint8List metaBytes}) _encodeArtifact(
  SfmLiveSnapshot snapshot,
  Uint8List rgb,
  String artifactId,
) {
  final n = snapshot.pointCount;
  final headerBytes = utf8.encode(
    'ply\n'
    'format binary_little_endian 1.0\n'
    'comment PocketWorld capture-time sparse reconstruction (full set)\n'
    'comment artifact_id $artifactId\n'
    'element vertex $n\n'
    'property float x\n'
    'property float y\n'
    'property float z\n'
    'property uchar red\n'
    'property uchar green\n'
    'property uchar blue\n'
    'end_header\n',
  );
  final plyBytes = Uint8List(headerBytes.length + n * _vertexStride);
  plyBytes.setRange(0, headerBytes.length, headerBytes);
  final body = ByteData.view(
    plyBytes.buffer,
    plyBytes.offsetInBytes + headerBytes.length,
    n * _vertexStride,
  );
  final xyz = snapshot.xyz;
  for (var i = 0; i < n; i++) {
    final offset = i * _vertexStride;
    body.setFloat32(offset, xyz[i * 3], Endian.little);
    body.setFloat32(offset + 4, xyz[i * 3 + 1], Endian.little);
    body.setFloat32(offset + 8, xyz[i * 3 + 2], Endian.little);
    body.setUint8(offset + 12, rgb[i * 3]);
    body.setUint8(offset + 13, rgb[i * 3 + 1]);
    body.setUint8(offset + 14, rgb[i * 3 + 2]);
  }
  final digest = sha256.convert(plyBytes).toString();

  final poses = snapshot.posesPacked;
  final posesJson = <Map<String, Object?>>[];
  for (var i = 0; i < poses.length; i += 9) {
    posesJson.add(<String, Object?>{
      'frame_id': poses[i].toInt(),
      'registered': poses[i + 1] != 0,
      'quat_wxyz': <double>[
        poses[i + 2],
        poses[i + 3],
        poses[i + 4],
        poses[i + 5],
      ],
      't': <double>[poses[i + 6], poses[i + 7], poses[i + 8]],
    });
  }
  final metadata = <String, Object?>{
    'schema': _schema,
    'artifact_id': artifactId,
    'written_at': DateTime.now().toIso8601String(),
    'refined': snapshot.refined,
    'n_points': n,
    'ply_bytes': plyBytes.length,
    'ply_sha256': digest,
    'vertex_stride': _vertexStride,
    'summary': snapshot.summary,
    'poses': posesJson,
  };
  final metaBytes = Uint8List.fromList(utf8.encode(jsonEncode(metadata)));
  return (plyBytes: plyBytes, metaBytes: metaBytes);
}

class _ValidatedPair {
  const _ValidatedPair({
    required this.pointCount,
    required this.refined,
    required this.plyBytes,
    required this.plySha256,
    required this.metaBytes,
    required this.metaSha256,
    this.receipt,
  });

  final int pointCount;
  final bool refined;
  final int plyBytes;
  final String plySha256;
  final int metaBytes;
  final String metaSha256;
  final SparsePersistReceipt? receipt;
}

class _ValidatedPly {
  const _ValidatedPly({
    required this.header,
    required this.pointCount,
    required this.byteCount,
    required this.sha256,
  });

  final String header;
  final int pointCount;
  final int byteCount;
  final String sha256;
}

Future<_ValidatedPly> _validatePly(File ply) async {
  if (!await ply.exists()) throw StateError('sparse PLY does not exist');
  final bytes = await ply.readAsBytes();
  if (bytes.isEmpty) throw StateError('sparse PLY is empty');
  final headerEnd = _indexOfBytes(bytes, utf8.encode('end_header\n'));
  if (headerEnd < 0) throw StateError('sparse PLY header is incomplete');
  final bodyOffset = headerEnd + 'end_header\n'.length;
  final header = utf8.decode(bytes.sublist(0, bodyOffset));
  if (!header.contains('format binary_little_endian 1.0\n')) {
    throw StateError('sparse PLY format is not binary little-endian');
  }
  final match = RegExp(
    r'^element vertex ([0-9]+)$',
    multiLine: true,
  ).firstMatch(header);
  final pointCount = int.tryParse(match?.group(1) ?? '');
  if (pointCount == null || pointCount <= 0) {
    throw StateError('sparse PLY vertex count is invalid');
  }
  if (bytes.length != bodyOffset + pointCount * _vertexStride) {
    throw StateError('sparse PLY byte length does not match its vertex count');
  }
  return _ValidatedPly(
    header: header,
    pointCount: pointCount,
    byteCount: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

Future<_ValidatedPair> _validatePair(
  File ply,
  File meta, {
  required bool requireLinkedMetadata,
  String? expectedArtifactId,
  bool? expectedRefined,
  int? expectedPointCount,
}) async {
  if (!await ply.exists() || !await meta.exists()) {
    throw StateError('sparse PLY/metadata pair is incomplete');
  }
  final validatedPly = await _validatePly(ply);

  final metaBytes = await meta.readAsBytes();
  if (metaBytes.isEmpty) throw StateError('sparse metadata is empty');
  final metaDigest = sha256.convert(metaBytes).toString();
  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(metaBytes));
  } catch (error) {
    throw StateError('sparse metadata is not valid JSON: $error');
  }
  if (decoded is! Map<String, dynamic> || decoded['schema'] != _schema) {
    throw StateError('sparse metadata schema is invalid');
  }
  final refined = decoded['refined'];
  final metaPoints = decoded['n_points'];
  if (refined is! bool || metaPoints is! int || metaPoints <= 0) {
    throw StateError('sparse metadata refined/count fields are invalid');
  }
  if (metaPoints != validatedPly.pointCount) {
    throw StateError('sparse metadata/PLY point counts do not match');
  }
  if (expectedRefined != null && refined != expectedRefined) {
    throw StateError('sparse refined flag does not match current snapshot');
  }
  if (expectedPointCount != null && metaPoints != expectedPointCount) {
    throw StateError('sparse point count does not match current snapshot');
  }

  final artifactId = decoded['artifact_id'];
  final declaredBytes = decoded['ply_bytes'];
  final declaredDigest = decoded['ply_sha256'];
  final declaredStride = decoded['vertex_stride'];
  if (requireLinkedMetadata &&
      (artifactId is! String ||
          artifactId.isEmpty ||
          declaredBytes is! int ||
          declaredDigest is! String ||
          declaredDigest.length != 64 ||
          declaredStride != _vertexStride)) {
    throw StateError('sparse metadata has no complete artifact identity');
  }
  if (artifactId is String) {
    if (!validatedPly.header.contains('comment artifact_id $artifactId\n')) {
      throw StateError('sparse metadata/PLY artifact identities do not match');
    }
    if (expectedArtifactId != null && artifactId != expectedArtifactId) {
      throw StateError('sparse artifact generation is stale');
    }
  } else if (expectedArtifactId != null) {
    throw StateError('sparse artifact has no generation identity');
  }
  if (declaredBytes != null && declaredBytes != validatedPly.byteCount) {
    throw StateError('sparse metadata/PLY byte lengths do not match');
  }
  if (declaredDigest != null && declaredDigest != validatedPly.sha256) {
    throw StateError('sparse metadata/PLY SHA-256 values do not match');
  }
  if (declaredStride != null && declaredStride != _vertexStride) {
    throw StateError('sparse metadata vertex stride is invalid');
  }

  final receipt =
      artifactId is String && declaredBytes is int && declaredDigest is String
      ? SparsePersistReceipt(
          artifactId: artifactId,
          pointCount: metaPoints,
          refined: refined,
          plyBytes: declaredBytes,
          plySha256: declaredDigest,
          metaBytes: metaBytes.length,
          metaSha256: metaDigest,
        )
      : null;
  return _ValidatedPair(
    pointCount: metaPoints,
    refined: refined,
    plyBytes: validatedPly.byteCount,
    plySha256: validatedPly.sha256,
    metaBytes: metaBytes.length,
    metaSha256: metaDigest,
    receipt: receipt,
  );
}

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return 0;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (error) {
    DeviceLog.log('SfmLive', 'sparse staging cleanup deferred: $error');
  }
}

Future<void> _deleteRequired(File file) async {
  if (await file.exists()) await file.delete();
}

void _logTrackHistogram(SfmLiveSnapshot snapshot) {
  final n = snapshot.pointCount;
  final offsets = snapshot.obsOffsets;
  if (offsets.length < n + 1) return;
  final buckets = List<int>.filled(11, 0);
  var sumLength = 0;
  var maxLength = 0;
  for (var i = 0; i < n; i++) {
    final length = offsets[i + 1] - offsets[i];
    sumLength += length;
    if (length > maxLength) maxLength = length;
    final bucket = length >= 10 ? 10 : (length < 2 ? 2 : length);
    buckets[bucket]++;
  }
  final twoView = buckets[2];
  final percent = (100.0 * twoView / n).toStringAsFixed(1);
  final mean = (sumLength / n).toStringAsFixed(2);
  final histogram = <String>[
    for (var length = 2; length <= 9; length++) 'L$length=${buckets[length]}',
    'L10+=${buckets[10]}',
  ].join(' ');
  DeviceLog.log(
    'SfmLive',
    'track-hist: n=$n 2view=$twoView($percent%) mean=$mean '
        'max=$maxLength | $histogram (refined=${snapshot.refined})',
  );
}
