// 局部地图的**大小**必须跟着三个量一起落进遥测。
//
// 未命名(12)(build 152)测到的是:
//   map_reliable_lms_ref_p50 = 389 / map_tracked_lms_p50 = 64 / map_reliable_lms_p50 = 9
// 只有这三个数,塌陷的两种病分不开:
//   ① 局部地图本来就只有几十个候选(收窄 acquireStellaLocalMap 那一步的问题);
//   ② 局部地图很大、可观测只剩 64(can_observe 三条中的某一条的问题)。
// 组合器**早就算出**了 localKeyframeCount / localLandmarkCount
// (map_keyframe_evidence.dart:193-194),只是没露出来。这个文件钉住
// 「算出来了」到「JSONL 里看得见」这条链不许再断。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_telemetry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

void main() {
  test('🔴 两个局部地图规模从 recordDecision 一路活到 snapshot', () {
    final t = AutoCaptureTelemetry()..recordSessionStart(0);
    // placeDescribeMicros 是 evidence 这一段的总闸(与现役同一条件)。
    for (final v in <int>[40, 60, 50]) {
      t.recordDecision(
        AutoCaptureDecision.skipNotMoved,
        tSec: 1,
        pace: ShutterPace.normal,
        placeDescribeMicros: 1,
        evidenceSource: 'map',
        mapNumTrackedLms: 64,
        mapNumReliableLms: 9,
        mapNumReliableLmsRef: 389,
        mapLocalKeyframeCount: 6,
        mapLocalLandmarkCount: v,
      );
    }
    final e = t.snapshot()['evidence']! as Map<String, Object>;
    expect(e['ticks_map'], 3);
    expect(e['map_local_keyframes_p50'], 6);
    expect(e['map_local_landmarks_p50'], 50, reason: '中位数,与其它三个量同口径');
  });

  test('阴性对照:不给这两个数时不许凭空冒出来', () {
    final t = AutoCaptureTelemetry()..recordSessionStart(0);
    t.recordDecision(
      AutoCaptureDecision.skipNotMoved,
      tSec: 1,
      pace: ShutterPace.normal,
      placeDescribeMicros: 1,
      evidenceSource: 'tracks',
    );
    final e = t.snapshot()['evidence']! as Map<String, Object>;
    expect(e['map_local_keyframes_p50'], 0);
    expect(e['map_local_landmarks_p50'], 0);
  });

  test('🔴 页面确实把组合器的这两个字段接上了(源码契约)', () {
    final src = File('lib/ui/official_capture/ar_capture_page.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    for (final pair in <List<String>>[
      <String>['mapLocalKeyframeCount:', 'lastMapEvidence?.localKeyframeCount'],
      <String>['mapLocalLandmarkCount:', 'lastMapEvidence?.localLandmarkCount'],
    ]) {
      expect(src.contains(pair[0]), isTrue, reason: '没传 ${pair[0]}');
      expect(
        src.contains(pair[1]),
        isTrue,
        reason: '${pair[0]} 接的不是组合器已经算好的那个数 —— '
            '接错源就等于又造了一个新量',
      );
    }
  });
}
