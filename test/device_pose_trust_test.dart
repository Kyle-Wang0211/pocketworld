// [DEVICE-POSE-TRUST 2026-09-24] 喂帧「设备位姿可信」位的判据与落盘。
//
// 每条判据都配阴性/阳性对照:limited_initializing 必须出不可信,normal 必须出
// 可信;真机那一场(cap_1787733401226757)的 20 帧状态原样回放,只许第 1–3 帧
// 不可信。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/device_pose_trust.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_shadow_se3_comparison.dart';

SfmFedFrameMeta _meta({required bool trusted, String? state}) =>
    SfmFedFrameMeta(
      jpegPath: '/cap/photos_highres/official_tap-7.jpg',
      imageW: 4032,
      imageH: 3024,
      grayW: 4032,
      grayH: 3024,
      fx: 2853.8,
      fy: 2853.8,
      cx: 2019.4,
      cy: 1512.1,
      captureTimestamp: 82203.28,
      arkitQuatWxyz: const <double>[1, 0, 0, 0],
      arkitTransTxyz: const <double>[0, 0, 0],
      arkitCameraCenterWorld: const <double>[0, 0, 0],
      devicePoseTrusted: trusted,
      deviceTrackingState: state,
      devicePoseTrustReason: DevicePoseTrust.fromTrackerState(state).reason,
    );

void main() {
  group('DevicePoseTrust.fromTrackerState(该帧自己的追踪状态)', () {
    test('阳性对照:normal ⇒ 可信', () {
      final t = DevicePoseTrust.fromTrackerState('normal');
      expect(t.trusted, isTrue);
      expect(t.reason, 'tracker_normal');
    });

    test('🔴 阴性对照:limited_initializing ⇒ 不可信', () {
      final t = DevicePoseTrust.fromTrackerState('limited_initializing');
      expect(t.trusted, isFalse);
      expect(t.trackerState, 'limited_initializing');
      expect(t.reason, 'tracker_limited_initializing');
    });

    test('其余 limited_* 与 not_available 一律不可信', () {
      for (final s in const <String>[
        'limited_relocalizing',
        'limited_excessive_motion',
        'limited_insufficient_features',
        'limited_unknown',
        'not_available',
      ]) {
        expect(DevicePoseTrust.fromTrackerState(s).trusted, isFalse, reason: s);
      }
    });

    test('🔴 状态缺失 ⇒ 不可信(fail-closed,不知道就不能宣称可信)', () {
      expect(DevicePoseTrust.fromTrackerState(null).trusted, isFalse);
      expect(DevicePoseTrust.fromTrackerState('').trusted, isFalse);
      expect(
        DevicePoseTrust.fromTrackerState(null).reason,
        'tracker_state_missing',
      );
    });

    test('真机回放 cap_1787733401226757:20 帧里只有 1–3 不可信', () {
      // 原样取自该场 official_photo_bundle.json frames[].trackingState(与各帧
      // 原生 sidecar 的 trackingStateName 一致)。
      const states = <String>[
        'normal',
        'limited_initializing',
        'limited_initializing',
        'limited_initializing',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
        'normal',
      ];
      final untrusted = <int>[
        for (var i = 0; i < states.length; i++)
          if (!DevicePoseTrust.fromTrackerState(states[i]).trusted) i,
      ];
      expect(untrusted, <int>[1, 2, 3]);
    });
  });

  group('trackerReportsDegraded(预览流上的自动快门硬闸)', () {
    test('只有明确报了非 normal 才算降级;null 退回 isTracking', () {
      expect(
        DevicePoseTrust.trackerReportsDegraded('limited_initializing'),
        isTrue,
      );
      expect(DevicePoseTrust.trackerReportsDegraded('not_available'), isTrue);
      expect(DevicePoseTrust.trackerReportsDegraded('normal'), isFalse);
      expect(DevicePoseTrust.trackerReportsDegraded(null), isFalse);
    });
  });

  group('XRSLAM 官方状态 → 同一判据', () {
    // 与生产传输层同形的 wire(PwXrslamTransportCore.cpp:223-231 读
    // XRSLAM_RESULT_STATE + CAMERA_POSE),经既有 classifyRawXrslamPose。
    // q = [qx, qy, qz, qw](XRSLAMPose 的字段序)。
    Map<String, Object?> wire(int state, List<double> q) => <String, Object?>{
      'rawStateCallCompleted': true,
      'rawCameraPoseCallCompleted': true,
      'rawXrslamState': state,
      'xrslamPoseTimestamp': 12.5,
      'xrslamWorldFromCamera': <String, Object?>{
        'qx': q[0],
        'qy': q[1],
        'qz': q[2],
        'qw': q[3],
        'tx': 0.1,
        'ty': 0.2,
        'tz': 0.3,
      },
    };
    bool trustedOf(Map<String, Object?> w) => DevicePoseTrust.fromTrackerState(
      xrslamTrackerStateName(classifyRawXrslamPose(w)),
    ).trusted;

    test('映射表:只有 valid ⇒ normal', () {
      expect(
        xrslamTrackerStateName(RawXrslamPoseClassification.valid),
        kTrackerStateNormal,
      );
      for (final c in RawXrslamPoseClassification.values) {
        if (c == RawXrslamPoseClassification.valid) continue;
        expect(
          DevicePoseTrust.fromTrackerState(xrslamTrackerStateName(c)).trusted,
          isFalse,
          reason: c.name,
        );
      }
    });

    test('🔴 XRSLAM_STATE_INITIALIZING(0) ⇒ 不可信', () {
      expect(
        classifyRawXrslamPose(wire(0, <double>[0, 0, 0, 1])),
        RawXrslamPoseClassification.initializing,
      );
      expect(trustedOf(wire(0, <double>[0, 0, 0, 1])), isFalse);
    });

    test('🔴 TRACKING_SUCCESS 但全零四元数(上游首帧)⇒ 不可信', () {
      expect(trustedOf(wire(1, <double>[0, 0, 0, 0])), isFalse);
    });

    test('阳性对照:TRACKING_SUCCESS + 合法位姿 ⇒ 可信', () {
      final w = wire(1, <double>[0, 0, 0, 1]);
      expect(classifyRawXrslamPose(w), RawXrslamPoseClassification.valid);
      expect(trustedOf(w), isTrue);
    });
  });

  group('official_sfm_fed_frames.jsonl 记录', () {
    test('🔴 limited 帧:devicePoseTrusted=false 与原始状态一起落盘,位姿照记', () {
      final r = sfmFedFrameRecord(
        1,
        _meta(trusted: false, state: 'limited_initializing'),
        coreHonorsDevicePoseTrust: true,
      );
      expect(r['devicePoseTrusted'], isFalse);
      expect(r['deviceTrackingState'], 'limited_initializing');
      expect(r['devicePoseTrustReason'], 'tracker_limited_initializing');
      expect(r['coreHonorsDevicePoseTrust'], isTrue);
      expect(r['arkitCamFromWorldQwxyz'], isNotNull, reason: '审计/续跑仍要这份位姿');
    });

    test('阳性对照:normal 帧 devicePoseTrusted=true', () {
      final r = sfmFedFrameRecord(0, _meta(trusted: true, state: 'normal'));
      expect(r['devicePoseTrusted'], isTrue);
      expect(r['deviceTrackingState'], 'normal');
      expect(r.containsKey('coreHonorsDevicePoseTrust'), isTrue);
      expect(r['coreHonorsDevicePoseTrust'], isNull);
    });

    test('旧核回退(v1 ABI)如实记 coreHonorsDevicePoseTrust=false', () {
      final r = sfmFedFrameRecord(
        2,
        _meta(trusted: false, state: 'limited_initializing'),
        coreHonorsDevicePoseTrust: false,
      );
      expect(r['devicePoseTrusted'], isFalse);
      expect(r['coreHonorsDevicePoseTrust'], isFalse);
    });
  });
}
