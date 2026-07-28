import 'dart:convert';
import 'dart:io';

/// Immutable, creation-time capability for byte-exact photo archival.
///
/// A capture without this exact marker is legacy data and is never eligible
/// for automatic JPEG XL work.
class PhotoArchivePolicy {
  const PhotoArchivePolicy({
    required this.schema,
    required this.codec,
    required this.mode,
    required this.libjxlRevision,
    required this.createdAt,
  });

  static const fileName = 'official_photo_archive_policy.json';
  static const schemaV1 = 'pw_photo_archive_policy_v1';
  static const jpegXlCodec = 'jpeg-xl';
  static const jpegReconstructionMode = 'jpeg-reconstruction';
  static const pinnedLibjxlRevision =
      'a7a9c787341cf703dede03c2009fa460cae5e5df';

  final String schema;
  final String codec;
  final String mode;
  final String libjxlRevision;
  final String createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'codec': codec,
    'mode': mode,
    'libjxl_revision': libjxlRevision,
    'created_at': createdAt,
  };

  static Future<PhotoArchivePolicy> writeForNewCapture(
    Directory captureDirectory,
  ) async {
    final policy = PhotoArchivePolicy(
      schema: schemaV1,
      codec: jpegXlCodec,
      mode: jpegReconstructionMode,
      libjxlRevision: pinnedLibjxlRevision,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    final marker = File('${captureDirectory.path}/$fileName');
    final temporary = File('${marker.path}.tmp');
    await temporary.writeAsString(jsonEncode(policy.toJson()), flush: true);
    await temporary.rename(marker.path);
    return policy;
  }

  static Future<PhotoArchivePolicy?> readCompatible(
    Directory captureDirectory,
  ) async {
    final marker = File('${captureDirectory.path}/$fileName');
    try {
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final policy = PhotoArchivePolicy(
        schema: decoded['schema'] as String? ?? '',
        codec: decoded['codec'] as String? ?? '',
        mode: decoded['mode'] as String? ?? '',
        libjxlRevision: decoded['libjxl_revision'] as String? ?? '',
        createdAt: decoded['created_at'] as String? ?? '',
      );
      if (policy.schema != schemaV1 ||
          policy.codec != jpegXlCodec ||
          policy.mode != jpegReconstructionMode ||
          policy.libjxlRevision != pinnedLibjxlRevision ||
          policy.createdAt.isEmpty) {
        return null;
      }
      return policy;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
