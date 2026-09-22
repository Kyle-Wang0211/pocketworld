import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String officialDenseHandoffSchema =
    'pocketworld-official-colmap-dense-handoff-v2';

final class DenseTransactionFileIdentity {
  const DenseTransactionFileIdentity({
    required this.path,
    required this.byteSize,
    required this.sha256,
  });

  final String path;
  final int byteSize;
  final String sha256;
}

final class DenseTransactionManifest {
  DenseTransactionManifest._({
    required this.generation,
    required this.modelFiles,
    required this.fedFramesManifest,
    required this.frames,
  });

  static const List<String> modelFileNames = <String>[
    'cameras.bin',
    'images.bin',
    'points3D.bin',
  ];

  final String generation;
  final Map<String, DenseTransactionFileIdentity> modelFiles;
  final DenseTransactionFileIdentity fedFramesManifest;
  final Map<int, DenseTransactionFileIdentity> frames;

  void requireFrameMatchesSync({
    required int frameId,
    required String sourcePath,
  }) {
    final expected = frames[frameId];
    if (expected == null) {
      throw FormatException(
        'frame $frameId is absent from handoff transaction',
      );
    }
    final actual = _freezeRegularFileSync(File(sourcePath).absolute);
    if (expected.path != actual.path) {
      throw FormatException('frame $frameId path changed after model export');
    }
    _requireSameBytes(expected, actual, 'frame $frameId');
  }

  static DenseTransactionManifest writeSync({
    required String stagedModelDirectory,
    required String fedFramesManifestPath,
    required String generation,
  }) {
    if (generation.isEmpty) {
      throw const FormatException('dense handoff generation is empty');
    }
    final modelDirectory = Directory(stagedModelDirectory).absolute;
    _requireRealDirectory(modelDirectory, 'staged model directory');
    final modelFiles = <String, DenseTransactionFileIdentity>{};
    for (final name in modelFileNames) {
      modelFiles[name] = _freezeRegularFileSync(
        File(_join(modelDirectory.path, name)),
      );
    }

    final fedManifest = _freezeRegularFileSync(
      File(fedFramesManifestPath).absolute,
    );
    final frames = _parseAndFreezeFedFramesSync(
      File(fedFramesManifestPath).absolute,
    );
    final manifest = DenseTransactionManifest._(
      generation: generation,
      modelFiles: Map<String, DenseTransactionFileIdentity>.unmodifiable(
        modelFiles,
      ),
      fedFramesManifest: fedManifest,
      frames: Map<int, DenseTransactionFileIdentity>.unmodifiable(frames),
    );
    final marker = File(_join(modelDirectory.path, 'handoff.ready'));
    marker.writeAsStringSync(
      '${jsonEncode(manifest._toJson())}\n',
      flush: true,
    );
    return manifest;
  }

  static DenseTransactionManifest readAndValidateSync({
    required String markerPath,
    required String modelDirectory,
    required String fedFramesManifestPath,
  }) {
    final marker = _freezeRegularFileSync(File(markerPath).absolute);
    final decoded = jsonDecode(
      utf8.decode(File(marker.path).readAsBytesSync()),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['schema'] != officialDenseHandoffSchema) {
      throw const FormatException('invalid official dense handoff schema');
    }
    final generation = decoded['generation'];
    if (generation is! String || generation.isEmpty) {
      throw const FormatException('invalid official dense generation');
    }
    final modelJson = decoded['model_files'];
    if (modelJson is! Map<String, dynamic> ||
        modelJson.keys.toSet().difference(modelFileNames.toSet()).isNotEmpty ||
        modelJson.length != modelFileNames.length) {
      throw const FormatException('invalid official dense model identities');
    }
    final modelIdentities = <String, DenseTransactionFileIdentity>{};
    for (final name in modelFileNames) {
      final expected = _identityFromJson(modelJson[name], pathRequired: false);
      final actual = _freezeRegularFileSync(
        File(_join(Directory(modelDirectory).absolute.path, name)),
      );
      _requireSameBytes(expected, actual, 'model $name');
      modelIdentities[name] = actual;
    }

    final expectedFed = _identityFromJson(
      decoded['fed_frames_manifest'],
      pathRequired: false,
    );
    final actualFed = _freezeRegularFileSync(
      File(fedFramesManifestPath).absolute,
    );
    _requireSameBytes(expectedFed, actualFed, 'fed-frame manifest');

    final framesJson = decoded['frames'];
    if (framesJson is! List<dynamic> || framesJson.isEmpty) {
      throw const FormatException('official dense frame identities are empty');
    }
    final frames = <int, DenseTransactionFileIdentity>{};
    for (final value in framesJson) {
      if (value is! Map<String, dynamic> || value['frame_id'] is! int) {
        throw const FormatException('invalid official dense frame identity');
      }
      final frameId = value['frame_id'] as int;
      if (frameId < 0 || frames.containsKey(frameId)) {
        throw const FormatException('duplicate/invalid dense frame id');
      }
      frames[frameId] = _identityFromJson(value, pathRequired: true);
    }
    return DenseTransactionManifest._(
      generation: generation,
      modelFiles: Map<String, DenseTransactionFileIdentity>.unmodifiable(
        modelIdentities,
      ),
      fedFramesManifest: actualFed,
      frames: Map<int, DenseTransactionFileIdentity>.unmodifiable(frames),
    );
  }

  Map<String, dynamic> _toJson() {
    final sortedFrameIds = frames.keys.toList()..sort();
    return <String, dynamic>{
      'schema': officialDenseHandoffSchema,
      'generation': generation,
      'model_files': <String, dynamic>{
        for (final name in modelFileNames)
          name: _identityToJson(modelFiles[name]!, includePath: false),
      },
      'fed_frames_manifest': _identityToJson(
        fedFramesManifest,
        includePath: false,
      ),
      'frames': <Map<String, dynamic>>[
        for (final frameId in sortedFrameIds)
          <String, dynamic>{
            'frame_id': frameId,
            ..._identityToJson(frames[frameId]!, includePath: true),
          },
      ],
    };
  }
}

Map<int, DenseTransactionFileIdentity> _parseAndFreezeFedFramesSync(
  File manifest,
) {
  final bytes = manifest.readAsBytesSync();
  final result = <int, DenseTransactionFileIdentity>{};
  var lineNumber = 0;
  for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
    lineNumber += 1;
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic> ||
        decoded['frameId'] is! int ||
        decoded['jpegPath'] is! String) {
      throw FormatException('invalid fed-frame row $lineNumber');
    }
    final frameId = decoded['frameId'] as int;
    final path = decoded['jpegPath'] as String;
    if (frameId < 0 || path.isEmpty || result.containsKey(frameId)) {
      throw FormatException('duplicate/invalid fed-frame row $lineNumber');
    }
    result[frameId] = _freezeRegularFileSync(File(path).absolute);
  }
  if (result.isEmpty) {
    throw const FormatException('fed-frame manifest has no rows');
  }
  return result;
}

DenseTransactionFileIdentity _freezeRegularFileSync(File file) {
  final absolute = file.absolute;
  final beforeType = FileSystemEntity.typeSync(
    absolute.path,
    followLinks: false,
  );
  final before = absolute.statSync();
  if (beforeType != FileSystemEntityType.file ||
      before.type != FileSystemEntityType.file ||
      before.size <= 0) {
    throw FileSystemException(
      'required transaction input is not a non-empty regular file',
      absolute.path,
    );
  }
  final bytes = absolute.readAsBytesSync();
  final afterType = FileSystemEntity.typeSync(
    absolute.path,
    followLinks: false,
  );
  final after = absolute.statSync();
  if (afterType != FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      after.size != before.size ||
      after.modified != before.modified ||
      bytes.length != before.size) {
    throw FileSystemException(
      'transaction input changed while hashing',
      absolute.path,
    );
  }
  return DenseTransactionFileIdentity(
    path: absolute.path,
    byteSize: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

void _requireRealDirectory(Directory directory, String label) {
  final type = FileSystemEntity.typeSync(
    directory.absolute.path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException(
      '$label must be a real directory',
      directory.path,
    );
  }
}

DenseTransactionFileIdentity _identityFromJson(
  Object? value, {
  required bool pathRequired,
}) {
  if (value is! Map<String, dynamic> ||
      value['byte_size'] is! int ||
      value['sha256'] is! String ||
      (pathRequired && value['path'] is! String)) {
    throw const FormatException('invalid transaction file identity');
  }
  final byteSize = value['byte_size'] as int;
  final digest = value['sha256'] as String;
  final path = pathRequired ? value['path'] as String : '';
  if (byteSize <= 0 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
      (pathRequired && path.isEmpty)) {
    throw const FormatException('invalid transaction file identity values');
  }
  return DenseTransactionFileIdentity(
    path: path,
    byteSize: byteSize,
    sha256: digest,
  );
}

Map<String, dynamic> _identityToJson(
  DenseTransactionFileIdentity identity, {
  required bool includePath,
}) {
  return <String, dynamic>{
    if (includePath) 'path': identity.path,
    'byte_size': identity.byteSize,
    'sha256': identity.sha256,
  };
}

void _requireSameBytes(
  DenseTransactionFileIdentity expected,
  DenseTransactionFileIdentity actual,
  String label,
) {
  if (expected.byteSize != actual.byteSize ||
      expected.sha256 != actual.sha256) {
    throw FormatException('$label does not match handoff transaction');
  }
}

String _join(String directory, String child) {
  if (directory.endsWith(Platform.pathSeparator)) return '$directory$child';
  return '$directory${Platform.pathSeparator}$child';
}
