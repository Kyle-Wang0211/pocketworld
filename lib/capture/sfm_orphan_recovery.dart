import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

const String _manualCaptureLegacyV1 = 'aether_manual_capture_v2_in_process_v1';
const String _manualCaptureDurableV2 = 'aether_manual_capture_v2_durable_v2';

/// The native durable-v2 publisher installs JPEG, metadata, and gray as
/// separate atomic artifacts, then publishes a sibling
/// `.manual-v2-committed.json` receipt last. Any individual artifact may be
/// visible before that receipt; JPEG presence alone never proves commit.
///
/// This scanner never invents camera metadata from a file name.  A source gray
/// can be recovered only when the committed bundle proves its job/frame
/// identity, dimensions, intrinsics, pose, and exact paths.  Every ambiguous
/// bundle is returned as a blocker so finalization cannot silently omit it.
enum SfmOrphanRecoveryBlockKind {
  missingSidecar,
  incompleteNativeCommit,
  invalidEvidence,
  duplicateIdentity,
}

final class SfmOrphanRecoveryBlock {
  const SfmOrphanRecoveryBlock({
    required this.kind,
    required this.message,
    required this.evidencePath,
    this.captureJobId,
  });

  final SfmOrphanRecoveryBlockKind kind;
  final String message;
  final String evidencePath;
  final String? captureJobId;
}

final class SfmCommittedOrphan {
  const SfmCommittedOrphan({
    required this.manualCaptureSchema,
    required this.captureJobId,
    required this.frameId,
    required this.timestamp,
    required this.grayFile,
    required this.jpegFile,
    required this.sidecarFile,
    required this.grayWidth,
    required this.grayHeight,
    required this.imageWidth,
    required this.imageHeight,
    required this.intrinsicFxFyCxCy,
    required this.extrinsic4x4,
    this.snapshotIdentity,
    this.durableCommitMarkerFile,
    this.artifactSha256 = const <String, String>{},
  });

  final String manualCaptureSchema;
  final String captureJobId;
  final String frameId;
  final double timestamp;
  final File grayFile;
  final File jpegFile;
  final File sidecarFile;
  final int grayWidth;
  final int grayHeight;
  final int imageWidth;
  final int imageHeight;
  final List<double> intrinsicFxFyCxCy;
  final List<double> extrinsic4x4;
  final String? snapshotIdentity;
  final File? durableCommitMarkerFile;
  final Map<String, String> artifactSha256;

  int get expectedGrayBytes => grayWidth * grayHeight;

  /// Reconstructs the exact durable metadata shape consumed by
  /// `SfmLiveRecon`. This is derived only after the committed bundle has
  /// passed every evidence check above.
  Map<String, Object?> toDurableQueueMetadata() {
    final scale = grayWidth / imageWidth;
    final c2w = vm.Matrix4.fromList(extrinsic4x4);
    final cameraCenter = c2w.getTranslation();
    final worldToCamera = c2w.getRotation()..transpose();
    final translation = worldToCamera.transform(-cameraCenter);
    final quaternion = vm.Quaternion.fromRotation(worldToCamera)..normalize();
    final metadata = <String, Object?>{
      'schemaVersion': 1,
      'manualCaptureSchema': manualCaptureSchema,
      'captureJobId': captureJobId,
      'frameId': frameId,
      'jpegPath': jpegFile.absolute.path,
      'sidecarPath': sidecarFile.absolute.path,
      'imageW': imageWidth,
      'imageH': imageHeight,
      'grayW': grayWidth,
      'grayH': grayHeight,
      'fx': intrinsicFxFyCxCy[0] * scale,
      'fy': intrinsicFxFyCxCy[1] * scale,
      'cx': intrinsicFxFyCxCy[2] * scale,
      'cy': intrinsicFxFyCxCy[3] * scale,
      'arkitQuatWxyz': <double>[
        quaternion.w,
        quaternion.x,
        quaternion.y,
        quaternion.z,
      ],
      'arkitTransTxyz': <double>[translation.x, translation.y, translation.z],
      'arkitCameraCenterWorld': <double>[
        cameraCenter.x,
        cameraCenter.y,
        cameraCenter.z,
      ],
      'recoveredNativeTimestamp': timestamp,
      if (snapshotIdentity != null) 'snapshotIdentity': snapshotIdentity,
      if (durableCommitMarkerFile != null)
        'durableCommitMarkerPath': durableCommitMarkerFile!.absolute.path,
    };
    final jpegDigest = artifactSha256['jpeg'];
    final metadataDigest = artifactSha256['metadata'];
    final grayDigest = artifactSha256['sfm_gray'];
    if (jpegDigest != null) metadata['jpegSha256'] = jpegDigest;
    if (metadataDigest != null) metadata['metadataSha256'] = metadataDigest;
    if (grayDigest != null) metadata['sfmGraySha256'] = grayDigest;
    for (final entry in metadata.entries) {
      final value = entry.value;
      if (value is double && !value.isFinite) {
        throw StateError('derived ${entry.key} is non-finite');
      }
      if (value is List<double> && value.any((item) => !item.isFinite)) {
        throw StateError('derived ${entry.key} contains non-finite values');
      }
    }
    return Map<String, Object?>.unmodifiable(metadata);
  }
}

final class SfmOrphanRecoveryScan {
  const SfmOrphanRecoveryScan({
    required this.committedOrphans,
    required this.blocks,
  });

  final List<SfmCommittedOrphan> committedOrphans;
  final List<SfmOrphanRecoveryBlock> blocks;

  bool get blocked => blocks.isNotEmpty;
}

/// Finds manual-v2 captures that native committed but the durable SfM queue
/// has not yet taken ownership of (their `*.sfm-gray` is still in the capture
/// directory).
///
/// Results are stable FIFO: native AR timestamp, then capture job, then frame.
/// Repeated scans are read-only and return the same identities.  Queue
/// integration must move each returned gray through `enqueueGrayFile`; after a
/// successful move it naturally disappears from the next scan while the user
/// JPEG and sidecar remain untouched.
Future<SfmOrphanRecoveryScan> scanCommittedSfmOrphans(
  Directory sourceDirectory, {
  Set<String> queueOwnedCaptureJobIds = const <String>{},
  Set<String> queueOwnedJpegPaths = const <String>{},
}) async {
  if (!await sourceDirectory.exists()) {
    return const SfmOrphanRecoveryScan(
      committedOrphans: <SfmCommittedOrphan>[],
      blocks: <SfmOrphanRecoveryBlock>[],
    );
  }

  final entities = await sourceDirectory
      .list(followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
  entities.sort((a, b) => a.path.compareTo(b.path));

  final grayByStem = <String, File>{};
  final sidecarByStem = <String, File>{};
  for (final file in entities) {
    final path = file.absolute.path;
    if (path.endsWith('.sfm-gray')) {
      grayByStem[path.substring(0, path.length - '.sfm-gray'.length)] = file;
    } else if (path.endsWith('.json')) {
      sidecarByStem[path.substring(0, path.length - '.json'.length)] = file;
    }
  }

  final blocks = <SfmOrphanRecoveryBlock>[];
  final recovered = <SfmCommittedOrphan>[];
  final candidateStems = <String>{...grayByStem.keys};

  // A published manual-v2 sidecar without its gray is an incomplete intent.
  // Do not treat arbitrary JSON files in photos_highres as capture intents.
  for (final entry in sidecarByStem.entries) {
    if (candidateStems.contains(entry.key)) continue;
    final decoded = await _tryDecodeMap(entry.value);
    final schema = decoded?['manual_capture_schema'];
    if (schema == _manualCaptureLegacyV1 || schema == _manualCaptureDurableV2) {
      final jobId = _nonEmptyString(decoded?['capture_job_id']);
      if (jobId != null && queueOwnedCaptureJobIds.contains(jobId)) {
        continue;
      }
      final rawContract = decoded?['dart_save_contract'];
      final contract = rawContract is Map
          ? Map<String, Object?>.from(rawContract)
          : null;
      final jpegPath = _nonEmptyString(contract?['jpeg_path']);
      if (jpegPath != null &&
          queueOwnedJpegPaths.contains(File(jpegPath).absolute.path)) {
        continue;
      }
      if (schema == _manualCaptureDurableV2) {
        final marker = _physicalDurableMarkerForSidecar(entry.value);
        if (!await marker.exists()) {
          // The Swift durable store owns partial-v2 reconciliation. Absence of
          // its last-written marker is not a committed orphan and must not
          // poison the Dart queue.
          continue;
        }
      }
      blocks.add(
        SfmOrphanRecoveryBlock(
          kind: schema == _manualCaptureDurableV2
              ? SfmOrphanRecoveryBlockKind.invalidEvidence
              : SfmOrphanRecoveryBlockKind.incompleteNativeCommit,
          message: schema == _manualCaptureDurableV2
              ? 'durable-v2 commit receipt exists but gray is missing'
              : 'manual-v2 intent has no frame-exact gray payload',
          evidencePath: entry.value.absolute.path,
          captureJobId: jobId,
        ),
      );
    }
  }

  final orderedStems = candidateStems.toList()..sort();
  for (final stem in orderedStems) {
    final gray = grayByStem[stem]!;
    final sidecar = sidecarByStem[stem];
    if (sidecar == null) {
      blocks.add(
        SfmOrphanRecoveryBlock(
          kind: SfmOrphanRecoveryBlockKind.missingSidecar,
          message: 'frame-exact gray has no durable camera sidecar',
          evidencePath: gray.absolute.path,
        ),
      );
      continue;
    }

    try {
      recovered.add(await _parseCommittedBundle(gray, sidecar));
    } on _PendingNativeReconciliation {
      // Durable-v2 has not published its final receipt yet. Swift owns this
      // job and may complete or fail it from its private raw-spill ledger.
      continue;
    } catch (error) {
      blocks.add(
        SfmOrphanRecoveryBlock(
          kind: error is _IncompleteCommit
              ? SfmOrphanRecoveryBlockKind.incompleteNativeCommit
              : SfmOrphanRecoveryBlockKind.invalidEvidence,
          message: '$error',
          evidencePath: sidecar.absolute.path,
          captureJobId: error is _BundleEvidenceError
              ? error.captureJobId
              : null,
        ),
      );
    }
  }

  final jobCounts = <String, int>{};
  final frameCounts = <String, int>{};
  for (final item in recovered) {
    jobCounts[item.captureJobId] = (jobCounts[item.captureJobId] ?? 0) + 1;
    frameCounts[item.frameId] = (frameCounts[item.frameId] ?? 0) + 1;
  }
  final duplicateJobs = jobCounts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toSet();
  final duplicateFrames = frameCounts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toSet();
  if (duplicateJobs.isNotEmpty || duplicateFrames.isNotEmpty) {
    recovered.removeWhere((item) {
      if (!duplicateJobs.contains(item.captureJobId) &&
          !duplicateFrames.contains(item.frameId)) {
        return false;
      }
      blocks.add(
        SfmOrphanRecoveryBlock(
          kind: SfmOrphanRecoveryBlockKind.duplicateIdentity,
          message: 'capture job or frame identity is not unique',
          evidencePath: item.sidecarFile.absolute.path,
          captureJobId: item.captureJobId,
        ),
      );
      return true;
    });
  }

  recovered.sort((a, b) {
    final byTime = a.timestamp.compareTo(b.timestamp);
    if (byTime != 0) return byTime;
    final byJob = a.captureJobId.compareTo(b.captureJobId);
    if (byJob != 0) return byJob;
    return a.frameId.compareTo(b.frameId);
  });
  blocks.sort((a, b) => a.evidencePath.compareTo(b.evidencePath));
  return SfmOrphanRecoveryScan(
    committedOrphans: List<SfmCommittedOrphan>.unmodifiable(recovered),
    blocks: List<SfmOrphanRecoveryBlock>.unmodifiable(blocks),
  );
}

Future<SfmCommittedOrphan> _parseCommittedBundle(
  File gray,
  File sidecar,
) async {
  final decoded = await _tryDecodeMap(sidecar);
  if (decoded == null) {
    throw const _BundleEvidenceError('sidecar is not a JSON object');
  }
  final jobId = _requiredToken(decoded, 'capture_job_id');
  try {
    final schema = decoded['manual_capture_schema'];
    if (schema != _manualCaptureLegacyV1 && schema != _manualCaptureDurableV2) {
      throw const FormatException('sidecar is not manual-v2 evidence');
    }
    final contractRaw = decoded['dart_save_contract'];
    if (contractRaw is! Map) {
      throw const FormatException('missing sealed Dart save contract');
    }
    final contract = Map<String, Object?>.from(contractRaw);
    final contractFrameId = _requiredToken(contract, 'frame_id');
    final frameId = schema == _manualCaptureDurableV2
        ? _requiredToken(decoded, 'frame_identity')
        : contractFrameId;
    if (frameId != contractFrameId) {
      throw const FormatException(
        'frame_identity does not match the sealed Dart frame_id',
      );
    }
    final expectedGrayPath = _requiredAbsolutePath(decoded, 'sfm_gray_path');
    final expectedJpegPath = _requiredAbsolutePath(contract, 'jpeg_path');
    final expectedSidecarPath = _requiredAbsolutePath(
      contract,
      'metadata_path',
    );
    if (expectedGrayPath != gray.absolute.path) {
      throw const FormatException('sfm_gray_path does not bind this gray');
    }
    if (expectedSidecarPath != sidecar.absolute.path) {
      throw const FormatException('metadata_path does not bind this sidecar');
    }
    final stem = gray.absolute.path.substring(
      0,
      gray.absolute.path.length - '.sfm-gray'.length,
    );
    if (expectedJpegPath != '$stem.jpg' ||
        expectedSidecarPath != '$stem.json') {
      throw const FormatException(
        'manual-v2 JPEG, sidecar, and gray do not share one bundle identity',
      );
    }

    final jpeg = File(expectedJpegPath);
    final durableReceipt = schema == _manualCaptureDurableV2
        ? await _validateDurableV2Receipt(
            decoded: decoded,
            jobId: jobId,
            jpeg: jpeg,
            sidecar: sidecar,
            gray: gray,
          )
        : null;
    if (!await jpeg.exists()) {
      throw schema == _manualCaptureDurableV2
          ? const FormatException(
              'durable-v2 receipt references a missing JPEG',
            )
          : const _IncompleteCommit(
              'JPEG commit marker is absent; native publication is incomplete',
            );
    }
    if (await jpeg.length() <= 0) {
      throw const FormatException('JPEG commit marker is empty');
    }

    final grayWidth = _requiredPositiveInt(decoded, 'sfm_gray_w');
    final grayHeight = _requiredPositiveInt(decoded, 'sfm_gray_h');
    final imageWidth = _requiredPositiveInt(decoded, 'image_w');
    final imageHeight = _requiredPositiveInt(decoded, 'image_h');
    final expectedGrayBytes = grayWidth * grayHeight;
    if (await gray.length() != expectedGrayBytes) {
      throw FormatException(
        'gray byte length does not match $grayWidth x $grayHeight',
      );
    }
    final timestamp = _requiredFiniteDouble(decoded, 't');
    final intrinsics = _requiredFiniteList(decoded, 'intrinsics_fxfycxcy', 4);
    if (intrinsics[0] <= 0 || intrinsics[1] <= 0) {
      throw const FormatException('focal lengths must be positive');
    }
    final extrinsic = _requiredFiniteList(decoded, 'extrinsic', 16);
    _validateRigidCameraToWorld(extrinsic);
    return SfmCommittedOrphan(
      manualCaptureSchema: schema as String,
      captureJobId: jobId,
      frameId: frameId,
      timestamp: timestamp,
      grayFile: gray,
      jpegFile: jpeg,
      sidecarFile: sidecar,
      grayWidth: grayWidth,
      grayHeight: grayHeight,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      intrinsicFxFyCxCy: List<double>.unmodifiable(intrinsics),
      extrinsic4x4: List<double>.unmodifiable(extrinsic),
      snapshotIdentity: durableReceipt?.snapshotIdentity,
      durableCommitMarkerFile: durableReceipt?.markerFile,
      artifactSha256:
          durableReceipt?.artifactSha256 ?? const <String, String>{},
    );
  } on _PendingNativeReconciliation {
    rethrow;
  } on _IncompleteCommit {
    rethrow;
  } on _BundleEvidenceError {
    rethrow;
  } catch (error) {
    throw _BundleEvidenceError('$error', captureJobId: jobId);
  }
}

File _physicalDurableMarkerForSidecar(File sidecar) {
  final path = sidecar.absolute.path;
  final stem = path.endsWith('.json')
      ? path.substring(0, path.length - '.json'.length)
      : path;
  return File('$stem.manual-v2-committed.json');
}

final class _DurableV2Receipt {
  const _DurableV2Receipt({
    required this.markerFile,
    required this.snapshotIdentity,
    required this.artifactSha256,
  });

  final File markerFile;
  final String snapshotIdentity;
  final Map<String, String> artifactSha256;
}

Future<_DurableV2Receipt> _validateDurableV2Receipt({
  required Map<String, Object?> decoded,
  required String jobId,
  required File jpeg,
  required File sidecar,
  required File gray,
}) async {
  final expectedMarker = _physicalDurableMarkerForSidecar(sidecar);
  final markerPathRaw = _nonEmptyString(decoded['durable_commit_marker_path']);
  if (!await expectedMarker.exists()) {
    throw const _PendingNativeReconciliation();
  }
  if (markerPathRaw == null ||
      !File(markerPathRaw).isAbsolute ||
      File(markerPathRaw).absolute.path != expectedMarker.absolute.path) {
    throw const FormatException(
      'durable_commit_marker_path does not bind the sibling receipt',
    );
  }
  final marker = await _tryDecodeMap(expectedMarker);
  if (marker == null) {
    throw const FormatException('durable-v2 commit receipt is not JSON');
  }
  if (_requiredPositiveInt(marker, 'schemaVersion') != 1) {
    throw const FormatException('unsupported durable-v2 receipt schema');
  }
  final markerJob = _requiredToken(marker, 'captureJobID');
  if (markerJob != jobId) {
    throw const FormatException('durable-v2 receipt belongs to another job');
  }
  final sidecarSnapshot = _requiredToken(decoded, 'snapshot_identity');
  final markerSnapshot = _requiredToken(marker, 'snapshotIdentity');
  if (markerSnapshot != sidecarSnapshot) {
    throw const FormatException(
      'durable-v2 receipt snapshot does not match sidecar',
    );
  }
  _requiredSha256(marker, 'preparedSha256');
  final committedMicros = marker['committedUnixMicros'];
  if (committedMicros is! int || committedMicros <= 0) {
    throw const FormatException(
      'durable-v2 receipt committedUnixMicros must be positive',
    );
  }
  final rawArtifacts = marker['artifacts'];
  if (rawArtifacts is! List || rawArtifacts.length != 3) {
    throw const FormatException(
      'durable-v2 receipt must seal exactly three artifacts',
    );
  }
  final expectedFiles = <String, File>{
    'jpeg': jpeg,
    'metadata': sidecar,
    'sfm_gray': gray,
  };
  final receipts = <String, ({File file, int byteLength, String sha256})>{};
  for (final raw in rawArtifacts) {
    if (raw is! Map) {
      throw const FormatException('durable-v2 artifact receipt is not JSON');
    }
    final artifact = Map<String, Object?>.from(raw);
    final kind = _requiredToken(artifact, 'kind');
    final expectedFile = expectedFiles[kind];
    if (expectedFile == null || receipts.containsKey(kind)) {
      throw FormatException('duplicate or unknown durable-v2 artifact: $kind');
    }
    final finalPath = _requiredAbsolutePath(artifact, 'finalPath');
    if (finalPath != expectedFile.absolute.path) {
      throw FormatException(
        'durable-v2 $kind receipt path does not bind the final artifact',
      );
    }
    final byteLength = _requiredPositiveInt(artifact, 'byteLength');
    final digest = _requiredSha256(artifact, 'sha256');
    receipts[kind] = (
      file: expectedFile,
      byteLength: byteLength,
      sha256: digest,
    );
  }
  if (receipts.length != expectedFiles.length) {
    throw const FormatException('durable-v2 receipt has incomplete artifacts');
  }
  for (final entry in receipts.entries) {
    final receipt = entry.value;
    if (!await receipt.file.exists()) {
      throw FormatException(
        'durable-v2 ${entry.key} artifact is missing after commit',
      );
    }
    final actualLength = await receipt.file.length();
    if (actualLength != receipt.byteLength) {
      throw FormatException(
        'durable-v2 ${entry.key} byte length mismatch: '
        '$actualLength != ${receipt.byteLength}',
      );
    }
    final actualDigest = await _sha256File(receipt.file);
    if (actualDigest != receipt.sha256) {
      throw FormatException('durable-v2 ${entry.key} SHA-256 mismatch');
    }
  }
  return _DurableV2Receipt(
    markerFile: expectedMarker,
    snapshotIdentity: sidecarSnapshot,
    artifactSha256: Map<String, String>.unmodifiable(<String, String>{
      for (final entry in receipts.entries) entry.key: entry.value.sha256,
    }),
  );
}

String _requiredSha256(Map<String, Object?> map, String key) {
  final value = _nonEmptyString(map[key]);
  if (value == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$key is not a lowercase SHA-256 digest');
  }
  return value;
}

Future<String> _sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void _validateRigidCameraToWorld(List<double> matrix) {
  const tolerance = 5e-3;
  if (matrix[3].abs() > tolerance ||
      matrix[7].abs() > tolerance ||
      matrix[11].abs() > tolerance ||
      (matrix[15] - 1).abs() > tolerance) {
    throw const FormatException('extrinsic has an invalid homogeneous row');
  }
  final c0 = <double>[matrix[0], matrix[1], matrix[2]];
  final c1 = <double>[matrix[4], matrix[5], matrix[6]];
  final c2 = <double>[matrix[8], matrix[9], matrix[10]];
  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  double norm(List<double> value) => math.sqrt(dot(value, value));
  if ((norm(c0) - 1).abs() > tolerance ||
      (norm(c1) - 1).abs() > tolerance ||
      (norm(c2) - 1).abs() > tolerance ||
      dot(c0, c1).abs() > tolerance ||
      dot(c0, c2).abs() > tolerance ||
      dot(c1, c2).abs() > tolerance) {
    throw const FormatException('extrinsic rotation is not orthonormal');
  }
  final determinant =
      c0[0] * (c1[1] * c2[2] - c1[2] * c2[1]) -
      c1[0] * (c0[1] * c2[2] - c0[2] * c2[1]) +
      c2[0] * (c0[1] * c1[2] - c0[2] * c1[1]);
  if ((determinant - 1).abs() > tolerance) {
    throw const FormatException('extrinsic rotation is not right-handed');
  }
}

Future<Map<String, Object?>?> _tryDecodeMap(File file) async {
  try {
    final value = jsonDecode(await file.readAsString());
    return value is Map ? Map<String, Object?>.from(value) : null;
  } catch (_) {
    return null;
  }
}

String _requiredToken(Map<String, Object?> map, String key) {
  final value = _nonEmptyString(map[key]);
  if (value == null || !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    throw FormatException('$key is not a normalized token');
  }
  return value;
}

String? _nonEmptyString(Object? value) {
  if (value is! String || value.isEmpty || value.trim() != value) return null;
  return value;
}

String _requiredAbsolutePath(Map<String, Object?> map, String key) {
  final path = _nonEmptyString(map[key]);
  if (path == null || !File(path).isAbsolute) {
    throw FormatException('$key is not an absolute path');
  }
  return File(path).absolute.path;
}

int _requiredPositiveInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! num || !value.isFinite || value != value.roundToDouble()) {
    throw FormatException('$key is not an integer');
  }
  final result = value.toInt();
  if (result <= 0) throw FormatException('$key must be positive');
  return result;
}

double _requiredFiniteDouble(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be finite');
  }
  return value.toDouble();
}

List<double> _requiredFiniteList(
  Map<String, Object?> map,
  String key,
  int length,
) {
  final value = map[key];
  if (value is! List || value.length != length) {
    throw FormatException('$key must contain exactly $length values');
  }
  final result = <double>[];
  for (final item in value) {
    if (item is! num || !item.isFinite) {
      throw FormatException('$key contains a non-finite value');
    }
    result.add(item.toDouble());
  }
  return result;
}

class _BundleEvidenceError implements Exception {
  const _BundleEvidenceError(this.message, {this.captureJobId});
  final String message;
  final String? captureJobId;

  @override
  String toString() => message;
}

class _IncompleteCommit extends _BundleEvidenceError {
  const _IncompleteCommit(super.message);
}

class _PendingNativeReconciliation implements Exception {
  const _PendingNativeReconciliation();
}
