import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Fail-closed error categories for the sparse-to-dense hand-off boundary.
enum DenseHandoffError {
  invalidModel,
  invalidFedFrames,
  invalidRegisteredImages,
  sourceChanged,
}

final class DenseHandoffException implements Exception {
  const DenseHandoffException(this.code, this.message);

  final DenseHandoffError code;
  final String message;

  @override
  String toString() => 'DenseHandoffException($code): $message';
}

/// Immutable identity of one file at the time the hand-off was frozen.
final class DenseHandoffFile {
  const DenseHandoffFile({
    required this.path,
    required this.fileName,
    required this.byteSize,
    required this.sha256,
  });

  final String path;
  final String fileName;
  final int byteSize;
  final String sha256;
}

/// A later workspace stage may hard-link or copy this source to [destinationPath].
/// This module deliberately does not execute that I/O.
final class DenseImageMaterialization {
  const DenseImageMaterialization({
    required this.frameId,
    required this.imageName,
    required this.sourcePath,
    required this.destinationPath,
    required this.byteSize,
    required this.sha256,
  });

  final int frameId;
  final String imageName;
  final String sourcePath;
  final String destinationPath;
  final int byteSize;
  final String sha256;
}

/// Frozen evidence passed from the refined sparse worker to the future dense
/// workspace. All collections are unmodifiable and no source image is copied.
final class OfficialDenseHandoff {
  OfficialDenseHandoff._({
    required this.modelDirectory,
    required List<DenseHandoffFile> modelFiles,
    required this.fedFramesManifest,
    required this.materializationDirectory,
    required List<DenseImageMaterialization> materializationPlan,
  }) : modelFiles = List<DenseHandoffFile>.unmodifiable(modelFiles),
       materializationPlan = List<DenseImageMaterialization>.unmodifiable(
         materializationPlan,
       );

  static const List<String> _requiredModelFiles = <String>[
    'cameras.bin',
    'images.bin',
    'points3D.bin',
  ];
  static final RegExp _registeredImagePattern = RegExp(
    r'^frame_([0-9]{6})\.jpg$',
  );

  final String modelDirectory;
  final List<DenseHandoffFile> modelFiles;
  final DenseHandoffFile fedFramesManifest;
  final String materializationDirectory;
  final List<DenseImageMaterialization> materializationPlan;

  static Future<OfficialDenseHandoff> freeze({
    required String modelDirectory,
    required String fedFramesManifestPath,
    required String materializationDirectory,
    required Iterable<String> registeredImageNames,
  }) async {
    final absoluteModelDirectory = Directory(modelDirectory).absolute.path;
    final modelFiles = <DenseHandoffFile>[];
    for (final fileName in _requiredModelFiles) {
      modelFiles.add(
        await _freezeRequiredFile(
          File(_join(absoluteModelDirectory, fileName)),
          fileName: fileName,
          missingError: DenseHandoffError.invalidModel,
        ),
      );
    }

    final names = registeredImageNames.toList(growable: false);
    if (names.isEmpty || names.toSet().length != names.length) {
      throw const DenseHandoffException(
        DenseHandoffError.invalidRegisteredImages,
        'registered reconstruction image names must be non-empty and unique',
      );
    }

    final registeredFrames = <int, String>{};
    for (final name in names) {
      final match = _registeredImagePattern.firstMatch(name);
      if (match == null) {
        throw DenseHandoffException(
          DenseHandoffError.invalidRegisteredImages,
          'non-canonical registered reconstruction image name: $name',
        );
      }
      final frameId = int.parse(match.group(1)!);
      if (registeredFrames.containsKey(frameId)) {
        throw DenseHandoffException(
          DenseHandoffError.invalidRegisteredImages,
          'more than one registered image resolves to frame $frameId',
        );
      }
      registeredFrames[frameId] = name;
    }

    final fedFile = File(fedFramesManifestPath).absolute;
    final fedSnapshot = await _freezeRequiredFileBytes(
      fedFile,
      fileName: fedFile.uri.pathSegments.last,
      missingError: DenseHandoffError.invalidFedFrames,
    );
    final fedIdentity = fedSnapshot.identity;
    final fedRows = await _readFedFramesBytes(fedSnapshot.bytes);
    for (final frameId in registeredFrames.keys) {
      if (!fedRows.containsKey(frameId)) {
        throw DenseHandoffException(
          DenseHandoffError.invalidFedFrames,
          'registered frame $frameId has no fed-frame evidence',
        );
      }
    }

    final absoluteMaterializationDirectory = Directory(
      materializationDirectory,
    ).absolute.path;
    final sortedFrameIds = registeredFrames.keys.toList()..sort();
    final plan = <DenseImageMaterialization>[];
    for (final frameId in sortedFrameIds) {
      final imageName = registeredFrames[frameId]!;
      final sourceIdentity = fedRows[frameId]!;
      plan.add(
        DenseImageMaterialization(
          frameId: frameId,
          imageName: imageName,
          sourcePath: sourceIdentity.path,
          destinationPath: _join(absoluteMaterializationDirectory, imageName),
          byteSize: sourceIdentity.byteSize,
          sha256: sourceIdentity.sha256,
        ),
      );
    }

    return OfficialDenseHandoff._(
      modelDirectory: absoluteModelDirectory,
      modelFiles: modelFiles,
      fedFramesManifest: fedIdentity,
      materializationDirectory: absoluteMaterializationDirectory,
      materializationPlan: plan,
    );
  }

  static Future<Map<int, DenseHandoffFile>> _readFedFramesBytes(
    List<int> bytes,
  ) async {
    final result = <int, DenseHandoffFile>{};
    var lineNumber = 0;
    try {
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        lineNumber += 1;
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw FormatException('row is not a JSON object');
        }
        final frameIdValue = decoded['frameId'];
        final jpegPathValue = decoded['jpegPath'];
        if (frameIdValue is! int ||
            frameIdValue < 0 ||
            jpegPathValue is! String ||
            jpegPathValue.isEmpty) {
          throw FormatException('frameId/jpegPath has the wrong type or value');
        }
        if (result.containsKey(frameIdValue)) {
          throw FormatException('duplicate frameId $frameIdValue');
        }
        final source = File(jpegPathValue).absolute;
        result[frameIdValue] = await _freezeRequiredFile(
          source,
          fileName: 'frame_${frameIdValue.toString().padLeft(6, '0')}.jpg',
          missingError: DenseHandoffError.invalidFedFrames,
        );
      }
    } on DenseHandoffException {
      rethrow;
    } catch (error) {
      throw DenseHandoffException(
        DenseHandoffError.invalidFedFrames,
        'invalid fed-frame row $lineNumber: $error',
      );
    }
    if (result.isEmpty) {
      throw const DenseHandoffException(
        DenseHandoffError.invalidFedFrames,
        'fed-frame manifest has no evidence rows',
      );
    }
    return result;
  }

  static Future<DenseHandoffFile> _freezeRequiredFile(
    File file, {
    required String fileName,
    required DenseHandoffError missingError,
  }) async {
    final snapshot = await _freezeRequiredFileBytes(
      file,
      fileName: fileName,
      missingError: missingError,
    );
    return snapshot.identity;
  }

  static Future<({DenseHandoffFile identity, List<int> bytes})>
  _freezeRequiredFileBytes(
    File file, {
    required String fileName,
    required DenseHandoffError missingError,
  }) async {
    final absolute = file.absolute;
    final type = await FileSystemEntity.type(absolute.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw DenseHandoffException(
        missingError,
        'required source must be a regular file: ${absolute.path}',
      );
    }
    FileStat before;
    try {
      before = await absolute.stat();
    } on FileSystemException catch (error) {
      throw DenseHandoffException(missingError, '${absolute.path}: $error');
    }
    if (before.type != FileSystemEntityType.file || before.size <= 0) {
      throw DenseHandoffException(
        missingError,
        'required non-empty file is missing: ${absolute.path}',
      );
    }

    final bytes = await absolute.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final afterType = await FileSystemEntity.type(
      absolute.path,
      followLinks: false,
    );
    final after = await absolute.stat();
    if (after.type != FileSystemEntityType.file ||
        afterType != FileSystemEntityType.file ||
        after.size != before.size ||
        after.modified != before.modified ||
        bytes.length != before.size) {
      throw DenseHandoffException(
        DenseHandoffError.sourceChanged,
        'source changed while freezing hand-off: ${absolute.path}',
      );
    }
    return (
      identity: DenseHandoffFile(
        path: absolute.path,
        fileName: fileName,
        byteSize: after.size,
        sha256: digest,
      ),
      bytes: bytes,
    );
  }

  static String _join(String directory, String fileName) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$fileName';
    }
    return '$directory${Platform.pathSeparator}$fileName';
  }
}
