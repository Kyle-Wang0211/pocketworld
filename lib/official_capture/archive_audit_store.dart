import 'dart:convert';
import 'dart:io';

class ArchiveAuditEvent {
  const ArchiveAuditEvent({
    required this.timestamp,
    required this.event,
    required this.trigger,
    this.captureId,
    this.details = const <String, Object?>{},
  });

  static const schemaV1 = 'pw_official_archive_audit_v1';

  final DateTime timestamp;
  final String event;
  final String trigger;
  final String? captureId;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schemaV1,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'event': event,
    'trigger': trigger,
    if (captureId != null) 'capture_id': captureId,
    'details': details,
  };
}

class OfficialArchiveAuditStore {
  OfficialArchiveAuditStore({
    required Future<Directory> Function() documentsDirectory,
  }) : _documentsDirectory = documentsDirectory;

  static const journalFileName = 'official_archive_audit.jsonl';
  static const statusFileName = 'official_archive_status.json';
  static const statusSchemaV1 = 'pw_official_archive_status_v1';

  final Future<Directory> Function() _documentsDirectory;
  Future<void> _writeTail = Future<void>.value();
  Map<String, Object?>? _status;

  Future<void> record(ArchiveAuditEvent event) {
    final next = _writeTail
        .catchError((Object _) {})
        .then((_) => _recordSerialized(event));
    _writeTail = next;
    return next;
  }

  Future<void> _recordSerialized(ArchiveAuditEvent event) async {
    final documents = await _documentsDirectory();
    await documents.create(recursive: true);
    final journal = File('${documents.path}/$journalFileName');
    await journal.writeAsString(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );

    final status = await _loadStatus(documents);
    final captures = Map<String, Object?>.from(
      status['captures'] as Map<String, Object?>? ?? const <String, Object?>{},
    );
    if (event.captureId case final captureId?) {
      captures[captureId] = event.toJson();
    }
    final nextStatus = <String, Object?>{
      'schema': statusSchemaV1,
      'updated_at': event.timestamp.toUtc().toIso8601String(),
      'latest': event.toJson(),
      'captures': captures,
    };
    final statusFile = File('${documents.path}/$statusFileName');
    final temporary = File('${statusFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(nextStatus), flush: true);
    await temporary.rename(statusFile.path);
    _status = nextStatus;
  }

  Future<Map<String, Object?>> _loadStatus(Directory documents) async {
    final loaded = _status;
    if (loaded != null) return loaded;
    final file = File('${documents.path}/$statusFileName');
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?> &&
            decoded['schema'] == statusSchemaV1 &&
            decoded['captures'] is Map<String, Object?>) {
          _status = Map<String, Object?>.from(decoded);
          return _status!;
        }
      }
    } on FileSystemException {
      // A later atomic write starts from an empty latest-status snapshot.
    } on FormatException {
      // Preserve the append-only journal and replace only malformed status.
    }
    final empty = <String, Object?>{
      'schema': statusSchemaV1,
      'captures': <String, Object?>{},
    };
    _status = empty;
    return empty;
  }
}
