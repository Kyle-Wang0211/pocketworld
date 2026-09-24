// xrslam_tracking_state_map_test.dart —— 状态映射表的判据。
//
// 表的价值全在「哪几条是猜的」这件事上被写下来了。所以这里查的不只是
// 「映射对不对」,还有:
//   · 右边**全部**落在 `ar_pose.dart` 定死的七词表里(多一个词 `PoseDriftTracker`
//     就归不了类);
//   · 三个**永远产不出**的词确实产不出(不宣称不存在的能力);
//   · 不确定的那条**显式标 unknown**,而不是被写成一个具体原因。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_bindings.dart';
import 'package:pocketworld_flutter/vio/pose/xrslam_tracking_state.dart';

void main() {
  group('表本身', () {
    test('只有三条 —— XRSLAM.h 里 XRSLAMState 就三个取值', () {
      expect(kXrslamTrackingStateMap.keys.toSet(), <int>{0, 1, 2});
      // 与绑定里的枚举逐条对拍,防止哪天头文件改了值而表没跟。
      expect(XRSLAMState.XRSLAM_STATE_INITIALIZING.value, 0);
      expect(XRSLAMState.XRSLAM_STATE_TRACKING_SUCCESS.value, 1);
      expect(XRSLAMState.XRSLAM_STATE_TRACKING_FAIL.value, 2);
    });

    test('每一条的右边都在七词表里', () {
      for (final m in kXrslamTrackingStateMap.values) {
        expect(
          kArTrackingStateVocabulary,
          contains(m.trackingStateName),
          reason: 'XRSLAMState=${m.engineState} 映射到了词表外的 '
              '"${m.trackingStateName}" —— PoseDriftTracker 会归不了类',
        );
      }
      expect(kArTrackingStateVocabulary, contains(kXrslamSessionNotAvailable));
    });

    test('只有 TRACKING_SUCCESS 是 isTracking', () {
      expect(kXrslamTrackingStateMap[1]!.isTracking, isTrue);
      expect(kXrslamTrackingStateMap[0]!.isTracking, isFalse);
      expect(kXrslamTrackingStateMap[2]!.isTracking, isFalse);
    });

    test('把握程度:0/1 是 exact,2 是 unknown(不猜原因)', () {
      expect(
        kXrslamTrackingStateMap[0]!.confidence,
        XrslamStateMappingConfidence.exact,
      );
      expect(
        kXrslamTrackingStateMap[1]!.confidence,
        XrslamStateMappingConfidence.exact,
      );
      expect(
        kXrslamTrackingStateMap[2]!.confidence,
        XrslamStateMappingConfidence.unknown,
        reason: 'TRACKING_FAIL 不说原因 ⇒ 必须显式标 unknown',
      );
      // confidence 的两份记录要一致。
      for (final e in kXrslamTrackingStateMap.entries) {
        expect(
          kXrslamTrackingStateMappingConfidence[e.key],
          e.value.confidence,
        );
      }
    });

    test('每一条都写了 why(表的价值在这)', () {
      for (final m in kXrslamTrackingStateMap.values) {
        expect(m.why.trim(), isNotEmpty);
      }
    });
  });

  group('🔴 三个产不出的词', () {
    test('excessive_motion / insufficient_features / relocalizing 永远不出现', () {
      final produced = <String>{
        for (final m in kXrslamTrackingStateMap.values) m.trackingStateName,
        kXrslamSessionNotAvailable,
      };
      for (final forbidden in kXrslamUnreachableTrackingStates.keys) {
        expect(
          produced,
          isNot(contains(forbidden)),
          reason: '$forbidden 被产出了 —— '
              '${kXrslamUnreachableTrackingStates[forbidden]}',
        );
      }
    });

    test('三个禁用词都给了理由,而且都在七词表里(说明是有意不用,不是拼错)', () {
      expect(kXrslamUnreachableTrackingStates.length, 3);
      for (final e in kXrslamUnreachableTrackingStates.entries) {
        expect(kArTrackingStateVocabulary, contains(e.key));
        expect(e.value.trim(), isNotEmpty);
      }
    });

    test('🔴 回归闸:TRACKING_FAIL 不能被写成 excessive_motion', () {
      // 那个词是 `capture_session.dart:1584` 的 `_isExcessiveMotion` 闸的
      // 触发条件 —— 编它会直接改采集行为。
      expect(
        kXrslamTrackingStateMap[2]!.trackingStateName,
        isNot('limited_excessive_motion'),
      );
      expect(kXrslamTrackingStateMap[2]!.trackingStateName, 'limited_unknown');
    });
  });

  group('xrslamTrackingStateName', () {
    test('会话没建起来 ⇒ not_available,优先级最高', () {
      for (final int? s in <int?>[null, 0, 1, 2, 99]) {
        expect(
          xrslamTrackingStateName(engineState: s, sessionAlive: false),
          'not_available',
        );
      }
    });

    test('会话在、还没读到状态 ⇒ limited_initializing', () {
      expect(
        xrslamTrackingStateName(engineState: null, sessionAlive: true),
        'limited_initializing',
      );
    });

    test('三个已知码逐条', () {
      expect(
        xrslamTrackingStateName(engineState: 0, sessionAlive: true),
        'limited_initializing',
      );
      expect(
        xrslamTrackingStateName(engineState: 1, sessionAlive: true),
        'normal',
      );
      expect(
        xrslamTrackingStateName(engineState: 2, sessionAlive: true),
        'limited_unknown',
      );
    });

    test('未知码 ⇒ limited_unknown,而且 mappingOf 把它标成 unknown、不抛', () {
      expect(
        xrslamTrackingStateName(engineState: 7, sessionAlive: true),
        'limited_unknown',
      );
      final m = xrslamTrackingStateMappingOf(7);
      expect(m.engineState, 7);
      expect(m.confidence, XrslamStateMappingConfidence.unknown);
      expect(m.isTracking, isFalse);
      expect(m.why, contains('7'));
    });
  });

  group('xrslamStateIsSixDof', () {
    test('只有 1 是 6DOF', () {
      expect(xrslamStateIsSixDof(null), isFalse);
      expect(xrslamStateIsSixDof(0), isFalse);
      expect(xrslamStateIsSixDof(1), isTrue);
      expect(xrslamStateIsSixDof(2), isFalse);
      expect(xrslamStateIsSixDof(99), isFalse);
    });

    test('与表里的 isTracking 一致(两处口径不许漂)', () {
      for (final e in kXrslamTrackingStateMap.entries) {
        expect(xrslamStateIsSixDof(e.key), e.value.isTracking);
      }
    });
  });
}
