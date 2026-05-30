import 'package:supabase_flutter/supabase_flutter.dart';

import '../me/scan_record_store.dart';
import '../ui/scan_record.dart';

class CloudCaptureRawDeleteException implements Exception {
  final String message;
  const CloudCaptureRawDeleteException(this.message);

  @override
  String toString() => 'CloudCaptureRawDeleteException: $message';
}

class CloudCaptureRawRetentionService {
  CloudCaptureRawRetentionService({
    SupabaseClient? client,
    ScanRecordStore? store,
  }) : _client = client ?? Supabase.instance.client,
       _store = store ?? ScanRecordStore.instance;

  final SupabaseClient _client;
  final ScanRecordStore _store;

  Future<DateTime?> deleteCloudRaw(ScanRecord record) async {
    final scanId = record.cloudScanId;
    if (scanId == null || scanId.isEmpty) {
      throw const CloudCaptureRawDeleteException('cloud scan id missing');
    }
    if (record.cloudUploadStatus == ScanCloudUploadStatus.queued ||
        record.cloudUploadStatus == ScanCloudUploadStatus.processing) {
      throw const CloudCaptureRawDeleteException(
        'scan is queued or processing; raw assets cannot be deleted now',
      );
    }

    final row = await _client
        .from('scans')
        .select('raw_storage_path,metadata,cloud_raw_deleted_at')
        .eq('id', scanId)
        .single();
    final cloudDeletedAt = _parseDate(row['cloud_raw_deleted_at']);
    if (cloudDeletedAt != null) return cloudDeletedAt;

    final paths = _rawObjectPaths(row);
    if (paths.isEmpty) {
      throw const CloudCaptureRawDeleteException(
        'cloud raw object list missing',
      );
    }

    for (final chunk in _chunks(paths, 100)) {
      await _client.storage.from('scans').remove(chunk);
    }

    final result = await _client.rpc(
      'mark_scan_cloud_raw_deleted',
      params: <String, Object?>{'p_scan_id': scanId},
    );
    final deletedAt = _parseDate((result as Map?)?['cloud_raw_deleted_at']);
    await _store.addOrUpdate(record.copyWith(cloudRawDeletedAt: deletedAt));
    return deletedAt;
  }

  List<String> _rawObjectPaths(Map<String, dynamic> row) {
    final out = <String>{};
    final rawManifest = row['raw_storage_path'] as String?;
    if (rawManifest != null && rawManifest.isNotEmpty) out.add(rawManifest);

    final metadata = row['metadata'];
    if (metadata is Map) {
      final uploaded = metadata['uploaded_objects'];
      if (uploaded is List) {
        for (final item in uploaded) {
          if (item is Map) {
            final path = item['storage_path'] as String?;
            if (path != null && path.isNotEmpty) out.add(path);
          }
        }
      }
    }
    return out.toList(growable: false);
  }

  Iterable<List<T>> _chunks<T>(List<T> values, int size) sync* {
    for (var i = 0; i < values.length; i += size) {
      final end = i + size > values.length ? values.length : i + size;
      yield values.sublist(i, end);
    }
  }

  DateTime? _parseDate(Object? value) {
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }
}
