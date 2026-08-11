import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/live_cloud_diagnostics.dart';

void main() {
  test('anchor translation severity uses exact 5 cm and 10 cm boundaries', () {
    expect(liveCloudAnchorSeverity(0.049999), 'normal');
    expect(liveCloudAnchorSeverity(0.05), 'warning');
    expect(liveCloudAnchorSeverity(0.099999), 'warning');
    expect(liveCloudAnchorSeverity(0.10), 'severe');
  });

  test(
    'receive generations are monotonic and stale completion is observation only',
    () {
      final sequencer = LiveCloudTelemetrySequencer();
      final first = sequencer.receive(
        source: 'streaming_local_ba_live',
        publishVersion: 7,
        pointCount: 1200,
        receiveEpochMs: 1000,
      );
      final second = sequencer.receive(
        source: 'streaming_global_ba',
        publishVersion: 8,
        pointCount: 1500,
        receiveEpochMs: 1010,
      );

      expect(first.receiveSequence, 1);
      expect(second.receiveSequence, 2);
      final fields = sequencer.computeDoneFields(
        first,
        computeDoneEpochMs: 1020,
      );
      expect(fields['receive_seq'], 1);
      expect(fields['latest_receive_seq'], 2);
      expect(fields['stale_at_compute'], isTrue);
      expect(fields['observation_only'], isTrue);
      expect(fields['source'], 'streaming_local_ba_live');
      expect(fields['publish_version'], 7);
    },
  );

  test('diagnostic build contract is explicit and never empty', () {
    expect(liveCloudDiagnosticContractId, 'PW_LIVE_CLOUD_DIAG_V1_20260810');
    expect(liveCloudDiagnosticDartBuildId, isNotEmpty);
  });

  test('worker source sequence is carried unchanged into native arguments', () {
    final sequencer = LiveCloudTelemetrySequencer();
    final tag = sequencer.receive(
      source: 'streaming_global_ba',
      publishVersion: 6,
      pointCount: 71810,
      receiveEpochMs: 2000,
      sourceReceiveSequence: 41,
    );

    expect(tag.baseFields['source_receive_seq'], 41);
    expect(
      tag.channelArguments(channelPushSequence: 9)['diagSourceReceiveSeq'],
      41,
    );
  });
}
