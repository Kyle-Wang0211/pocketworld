import 'package:supabase_flutter/supabase_flutter.dart';

import '../privacy/research_consent_service.dart';
import '../ui/scan_record.dart';

class CloudCaptureTrainingException implements Exception {
  final String message;
  const CloudCaptureTrainingException(this.message);

  @override
  String toString() => 'CloudCaptureTrainingException: $message';
}

class CloudCaptureTrainingService {
  CloudCaptureTrainingService({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<void> requestTraining({
    required ScanRecord record,
    required ResearchConsentSnapshot researchConsent,
  }) async {
    final scanId = record.cloudScanId;
    if (scanId == null || scanId.isEmpty) {
      throw const CloudCaptureTrainingException(
        'cloud scan id missing; upload must finish before training starts',
      );
    }
    await _client.rpc(
      'request_scan_training',
      params: <String, Object?>{
        'p_scan_id': scanId,
        'p_research_consent': researchConsent.toJson(),
      },
    );
  }
}
