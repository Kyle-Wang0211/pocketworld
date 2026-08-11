// Observation-only diagnostics for the AR live-cloud display path.
//
// This module intentionally contains no display, filtering, reconstruction, or
// stale-generation policy. It only assigns identities and formats JSON-safe
// telemetry fields.

const String liveCloudDiagnosticContractId = 'PW_LIVE_CLOUD_DIAG_V1_20260810';

// Do not route this through --dart-define: this product's device build has a
// verified history of those values not reaching the running AOT. The exact
// signed AOT hash and product manifest are stamped into Info.plist and logged
// by the native capture plugin; this constant identifies the Dart source path.
const String liveCloudDiagnosticDartBuildId =
    'PW_LIVE_CLOUD_DIAG_DART_V1_20260810';
const String liveCloudDiagnosticProductManifestSource = 'native_info_plist';

String liveCloudAnchorSeverity(double translationMeters) {
  if (translationMeters >= 0.10) return 'severe';
  if (translationMeters >= 0.05) return 'warning';
  return 'normal';
}

class LiveCloudTelemetryTag {
  const LiveCloudTelemetryTag({
    required this.receiveSequence,
    required this.source,
    required this.publishVersion,
    required this.pointCount,
    required this.receiveEpochMs,
    this.sourceReceiveSequence,
    this.computeDoneEpochMs,
  });

  final int receiveSequence;
  final String source;
  final int publishVersion;
  final int pointCount;
  final int receiveEpochMs;
  final int? sourceReceiveSequence;
  final int? computeDoneEpochMs;

  LiveCloudTelemetryTag withComputeDone(int epochMs) {
    return LiveCloudTelemetryTag(
      receiveSequence: receiveSequence,
      source: source,
      publishVersion: publishVersion,
      pointCount: pointCount,
      receiveEpochMs: receiveEpochMs,
      sourceReceiveSequence: sourceReceiveSequence,
      computeDoneEpochMs: epochMs,
    );
  }

  Map<String, Object?> get baseFields => <String, Object?>{
    'contract': liveCloudDiagnosticContractId,
    'receive_seq': receiveSequence,
    'source': source,
    'publish_version': publishVersion,
    'points': pointCount,
    'receive_t': receiveEpochMs,
    if (sourceReceiveSequence != null)
      'source_receive_seq': sourceReceiveSequence,
    if (computeDoneEpochMs != null) 'compute_done_t': computeDoneEpochMs,
  };

  Map<String, Object?> channelArguments({required int channelPushSequence}) {
    return <String, Object?>{
      'diagContract': liveCloudDiagnosticContractId,
      'diagReceiveSeq': receiveSequence,
      'diagChannelPushSeq': channelPushSequence,
      'diagSource': source,
      'diagVersion': publishVersion,
      'diagPointCount': pointCount,
      'diagReceiveEpochMs': receiveEpochMs,
      'diagComputeDoneEpochMs': computeDoneEpochMs ?? receiveEpochMs,
      'diagSourceReceiveSeq': sourceReceiveSequence ?? 0,
    };
  }
}

class LiveCloudTelemetrySequencer {
  int _nextReceiveSequence = 0;
  int _nextChannelPushSequence = 0;

  int get latestReceiveSequence => _nextReceiveSequence;

  LiveCloudTelemetryTag receive({
    required String source,
    required int publishVersion,
    required int pointCount,
    required int receiveEpochMs,
    int? sourceReceiveSequence,
  }) {
    return LiveCloudTelemetryTag(
      receiveSequence: ++_nextReceiveSequence,
      source: source,
      publishVersion: publishVersion,
      pointCount: pointCount,
      receiveEpochMs: receiveEpochMs,
      sourceReceiveSequence: sourceReceiveSequence,
    );
  }

  Map<String, Object?> computeDoneFields(
    LiveCloudTelemetryTag tag, {
    required int computeDoneEpochMs,
  }) {
    return <String, Object?>{
      ...tag.baseFields,
      'compute_done_t': computeDoneEpochMs,
      'latest_receive_seq': latestReceiveSequence,
      'stale_at_compute': tag.receiveSequence < latestReceiveSequence,
      'observation_only': true,
    };
  }

  ({int pushSequence, Map<String, Object?> fields}) channelSend(
    LiveCloudTelemetryTag tag, {
    required int channelSendEpochMs,
  }) {
    final pushSequence = ++_nextChannelPushSequence;
    return (
      pushSequence: pushSequence,
      fields: <String, Object?>{
        ...tag.baseFields,
        'channel_push_seq': pushSequence,
        'channel_send_t': channelSendEpochMs,
        'latest_receive_seq': latestReceiveSequence,
        'stale_at_channel': tag.receiveSequence < latestReceiveSequence,
        'observation_only': true,
      },
    );
  }
}
