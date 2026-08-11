import 'dart:convert';
import 'dart:io';

/// Immutable, creation-time capability for byte-exact photo archival.
///
/// A capture without this exact marker is legacy data and is never eligible
/// for automatic photo archive work.
class PhotoArchivePolicy {
  const PhotoArchivePolicy({
    required this.schema,
    required this.codec,
    required this.mode,
    required this.codecVersion,
    required this.codecRevision,
    required this.createdAt,
  });

  static const fileName = 'official_photo_archive_policy.json';
  static const schemaV1 = 'pw_photo_archive_policy_v1';
  static const schemaV2 = 'pw_photo_archive_policy_v2';
  static const jpegXlCodec = 'jpeg-xl';
  static const leptonCodec = 'lepton';
  static const jpegReconstructionMode = 'jpeg-reconstruction';
  static const pinnedLibjxlVersion = '0.12.0';
  static const pinnedLibjxlRevision =
      'a7a9c787341cf703dede03c2009fa460cae5e5df';
  static const pinnedLeptonVersion = '0.5.8';
  static const pinnedLeptonRevision =
      '90fdc27828676892fbb41777cfcc6bad1e470516';

  final String schema;
  final String codec;
  final String mode;
  final String codecVersion;
  final String codecRevision;
  final String createdAt;

  String get libjxlRevision => codec == jpegXlCodec ? codecRevision : '';

  String get archiveSuffix => codec == leptonCodec ? '.lep' : '.jxl';

  Map<String, Object?> toJson() {
    if (schema == schemaV1) {
      return <String, Object?>{
        'schema': schema,
        'codec': codec,
        'mode': mode,
        'libjxl_revision': codecRevision,
        'created_at': createdAt,
      };
    }
    return <String, Object?>{
      'schema': schema,
      'codec': codec,
      'mode': mode,
      'codec_version': codecVersion,
      'codec_revision': codecRevision,
      'created_at': createdAt,
    };
  }

  static Future<PhotoArchivePolicy> writeForNewCapture(
    Directory captureDirectory,
  ) async {
    final policy = PhotoArchivePolicy(
      schema: schemaV2,
      codec: leptonCodec,
      mode: jpegReconstructionMode,
      codecVersion: pinnedLeptonVersion,
      codecRevision: pinnedLeptonRevision,
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
      final schema = decoded['schema'] as String? ?? '';
      final codec = decoded['codec'] as String? ?? '';
      final mode = decoded['mode'] as String? ?? '';
      final createdAt = decoded['created_at'] as String? ?? '';
      if (schema == schemaV1) {
        final revision = decoded['libjxl_revision'] as String? ?? '';
        if (codec != jpegXlCodec ||
            mode != jpegReconstructionMode ||
            revision != pinnedLibjxlRevision ||
            createdAt.isEmpty) {
          return null;
        }
        return PhotoArchivePolicy(
          schema: schemaV1,
          codec: jpegXlCodec,
          mode: jpegReconstructionMode,
          codecVersion: pinnedLibjxlVersion,
          codecRevision: pinnedLibjxlRevision,
          createdAt: createdAt,
        );
      }
      if (schema != schemaV2 ||
          codec != leptonCodec ||
          mode != jpegReconstructionMode ||
          decoded['codec_version'] != pinnedLeptonVersion ||
          decoded['codec_revision'] != pinnedLeptonRevision ||
          createdAt.isEmpty) {
        return null;
      }
      return PhotoArchivePolicy(
        schema: schemaV2,
        codec: leptonCodec,
        mode: jpegReconstructionMode,
        codecVersion: pinnedLeptonVersion,
        codecRevision: pinnedLeptonRevision,
        createdAt: createdAt,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
