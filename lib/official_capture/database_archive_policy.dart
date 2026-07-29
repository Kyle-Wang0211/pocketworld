import 'dart:convert';
import 'dart:io';

/// Immutable creation-time capability for official database archival.
///
/// A capture without this exact marker is historical data and is never
/// automatically compressed.
class DatabaseArchivePolicy {
  const DatabaseArchivePolicy({
    required this.schema,
    required this.sourceFile,
    required this.codec,
    required this.version,
    required this.revision,
    required this.method,
    required this.createdAt,
  });

  static const fileName = 'official_database_archive_policy.json';
  static const schemaV1 = 'pw_official_database_archive_policy_v1';
  static const sourceFileName = 'official_sfm_live.db';
  static const codecName = 'zpaq';
  static const version715 = '7.15';
  static const method5 = 5;
  static const pinnedRevision =
      'e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418';

  final String schema;
  final String sourceFile;
  final String codec;
  final String version;
  final String revision;
  final int method;
  final String createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'source_file': sourceFile,
    'codec': codec,
    'version': version,
    'revision': revision,
    'method': method,
    'created_at': createdAt,
  };

  static Future<DatabaseArchivePolicy> writeForNewCapture(
    Directory captureDirectory,
  ) async {
    final policy = DatabaseArchivePolicy(
      schema: schemaV1,
      sourceFile: sourceFileName,
      codec: codecName,
      version: version715,
      revision: pinnedRevision,
      method: method5,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    final marker = File('${captureDirectory.path}/$fileName');
    final temporary = File('${marker.path}.tmp');
    await temporary.writeAsString(jsonEncode(policy.toJson()), flush: true);
    await temporary.rename(marker.path);
    return policy;
  }

  static Future<DatabaseArchivePolicy?> readCompatible(
    Directory captureDirectory,
  ) async {
    final marker = File('${captureDirectory.path}/$fileName');
    try {
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final policy = DatabaseArchivePolicy(
        schema: decoded['schema'] as String,
        sourceFile: decoded['source_file'] as String,
        codec: decoded['codec'] as String,
        version: decoded['version'] as String,
        revision: decoded['revision'] as String,
        method: decoded['method'] as int,
        createdAt: decoded['created_at'] as String,
      );
      if (policy.schema != schemaV1 ||
          policy.sourceFile != sourceFileName ||
          policy.codec != codecName ||
          policy.version != version715 ||
          policy.revision != pinnedRevision ||
          policy.method != method5 ||
          DateTime.tryParse(policy.createdAt) == null) {
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
