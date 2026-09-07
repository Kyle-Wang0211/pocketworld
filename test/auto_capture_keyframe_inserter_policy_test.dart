// stella_vslam `module::keyframe_inserter::new_keyframe_is_needed()` 的逐条对拍。
// 上游: stella-cv/stella_vslam, src/stella_vslam/module/keyframe_inserter.{h,cc}
// 许可: BSD 2-Clause(LICENSE.original AIST 2019 / LICENSE.fork stella-cv 2022)。
//
// 常数一个不调:max_interval 1.0 / min_interval 0.1 / max_distance -1 /
// min_distance -1 / almost_all 0.9 / view_changed 0.8 / enough_lms 100 /
// num_enough_keyfrms 5 / num_tracked_lms_thr_unstable 15。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/live_sfm_publish_policy.dart'
    show kOfficialMaximumCaptureFrames;

AutoCaptureDecision _decide({
  bool trackingNormal = true,
  int capturedCount = 10,
  double elapsedSec = 10,
  bool tooDark = false,
  bool awaitingCaptureBaseline = false,
  bool blurry = false,
  bool initialized = true,
  bool mapperAccepting = true,
  bool mapperSkippingLocalBA = false,
  bool hasTrackEvidence = true,
  int numTrackedLms = 120,
  int numReliableLms = 120,
  int numReliableLmsRef = 160,
  double? sinceLastKeyframeSec = 0.5,
  double? distanceTraveledM = 0.2,
  double maxIntervalSec = kStellaMaxIntervalSec,
  double minIntervalSec = kStellaMinIntervalSec,
  double maxDistanceM = kStellaMaxDistanceM,
  double minDistanceM = kStellaMinDistanceM,
}) => stellaVslamNewKeyframeIsNeeded(
  trackingNormal: trackingNormal,
  capturedCount: capturedCount,
  elapsedSec: elapsedSec,
  tooDark: tooDark,
  awaitingCaptureBaseline: awaitingCaptureBaseline,
  blurry: blurry,
  initialized: initialized,
  mapperAccepting: mapperAccepting,
  mapperSkippingLocalBA: mapperSkippingLocalBA,
  hasTrackEvidence: hasTrackEvidence,
  numTrackedLms: numTrackedLms,
  numReliableLms: numReliableLms,
  numReliableLmsRef: numReliableLmsRef,
  sinceLastKeyframeSec: sinceLastKeyframeSec,
  distanceTraveledM: distanceTraveledM,
  maxIntervalSec: maxIntervalSec,
  minIntervalSec: minIntervalSec,
  maxDistanceM: maxDistanceM,
  minDistanceM: minDistanceM,
);

void main() {
  test('constants are the stella_vslam source values, untouched', () {
    expect(kStellaMaxIntervalSec, 1.0);
    expect(kStellaMinIntervalSec, 0.1);
    expect(kStellaMaxDistanceM, -1.0);
    expect(kStellaMinDistanceM, -1.0);
    expect(kStellaLmsRatioThrAlmostAllLmsAreTracked, 0.9);
    expect(kStellaLmsRatioThrViewChanged, 0.8);
    expect(kStellaEnoughLmsThr, 100);
    expect(kStellaNumEnoughKeyfrmsThr, 5);
    expect(kStellaNumTrackedLmsThrUnstable, 15);
  });

  group('!almost_all_lms_are_tracked —— 强制项:画面里还是同一批东西就不拍', () {
    test(
      '>90% of the reference landmarks still tracked blocks every trigger',
      () {
        // 站着不动 / 原地转头 / 在一个区域里上下左右挪:内容没换 ⇒ 一律不拍。
        for (final since in <double>[0.5, 1.0, 5.0, 60.0]) {
          for (final dist in <double>[0.0, 0.05, 0.5, 5.0]) {
            expect(
              _decide(
                numReliableLms: 150, // 150 > 160*0.9 = 144
                numTrackedLms: 150,
                sinceLastKeyframeSec: since,
                distanceTraveledM: dist,
              ),
              AutoCaptureDecision.skipRedundant,
              reason: 'since=$since dist=$dist',
            );
          }
        }
      },
    );

    test('exactly at the 0.9 ratio it is not "almost all"', () {
      expect(_decide(numReliableLms: 145), AutoCaptureDecision.skipRedundant);
      // 144 == 160*0.9,上游用严格 > ⇒ 不算 almost_all
      expect(
        _decide(numReliableLms: 144),
        isNot(AutoCaptureDecision.skipRedundant),
      );
    });
  });

  group(
    '触发项 (max_interval_elapsed || max_distance_traveled || view_changed || not_enough_lms)',
    () {
      test(
        'view_changed: fewer than 80% of the reference landmarks tracked',
        () {
          // 128 == 160*0.8 ⇒ 不算 view_changed;127 才算。
          expect(
            _decide(numReliableLms: 127, sinceLastKeyframeSec: 0.5),
            AutoCaptureDecision.fire,
          );
          expect(
            _decide(numReliableLms: 130, sinceLastKeyframeSec: 0.5),
            AutoCaptureDecision.skipNotMoved,
          );
        },
      );

      test('max_interval_elapsed: 1 s since the last photo', () {
        expect(
          _decide(numReliableLms: 130, sinceLastKeyframeSec: 0.99),
          AutoCaptureDecision.skipNotMoved,
        );
        expect(
          _decide(numReliableLms: 130, sinceLastKeyframeSec: 1.0),
          AutoCaptureDecision.fire,
        );
      });

      test('not_enough_lms: fewer than 100 landmarks left', () {
        expect(
          _decide(
            numReliableLms: 99,
            numTrackedLms: 99,
            numReliableLmsRef: 400,
            sinceLastKeyframeSec: 0.5,
          ),
          AutoCaptureDecision.fire,
        );
      });

      test(
        'max_distance is off by default; enabling it makes distance a trigger',
        () {
          expect(
            _decide(
              numReliableLms: 130,
              sinceLastKeyframeSec: 0.5,
              distanceTraveledM: 99.0,
            ),
            AutoCaptureDecision.skipNotMoved,
            reason: 'max_distance = -1 ⇒ 距离不是触发项',
          );
          expect(
            _decide(
              numReliableLms: 130,
              sinceLastKeyframeSec: 0.5,
              distanceTraveledM: 99.0,
              maxDistanceM: 1.0,
            ),
            AutoCaptureDecision.fire,
          );
        },
      );
    },
  );

  group(
    '强制项 (!enough_keyfrms || (min_interval_elapsed && min_distance_traveled))',
    () {
      test('min_interval 0.1 s applies only after more than 5 photos', () {
        expect(
          _decide(
            capturedCount: 6,
            numReliableLms: 127,
            sinceLastKeyframeSec: 0.05,
          ),
          AutoCaptureDecision.skipPaced,
        );
        expect(
          _decide(
            capturedCount: 5,
            numReliableLms: 127,
            sinceLastKeyframeSec: 0.05,
          ),
          AutoCaptureDecision.fire,
          reason: '上游 num_enough_keyfrms_thr = 5,严格 > ⇒ 第 6 张起才受限',
        );
      });

      test(
        'min_distance is off by default; enabling it gates the 3D spacing',
        () {
          expect(
            _decide(numReliableLms: 127, distanceTraveledM: 0.0),
            AutoCaptureDecision.fire,
            reason: 'min_distance = -1 ⇒ 这道门不存在',
          );
          expect(
            _decide(
              numReliableLms: 127,
              distanceTraveledM: 0.0,
              minDistanceM: 0.05,
            ),
            AutoCaptureDecision.skipMinDistance,
          );
          expect(
            _decide(
              numReliableLms: 127,
              distanceTraveledM: 0.06,
              minDistanceM: 0.05,
            ),
            AutoCaptureDecision.fire,
          );
        },
      );
    },
  );

  group('强制项 !tracking_is_unstable / mapper', () {
    test('fewer than 15 tracked landmarks is unstable', () {
      expect(
        _decide(numTrackedLms: 14, numReliableLms: 14, numReliableLmsRef: 160),
        AutoCaptureDecision.skipTracking,
      );
      expect(
        _decide(numTrackedLms: 15, numReliableLms: 15, numReliableLmsRef: 160),
        AutoCaptureDecision.fire,
      );
    });

    test(
      'mapper paused blocks everything; skipping localBA blocks insertion',
      () {
        expect(
          _decide(mapperAccepting: false),
          AutoCaptureDecision.skipMapperStopped,
        );
        expect(
          _decide(numReliableLms: 127, mapperSkippingLocalBA: true),
          AutoCaptureDecision.skipMapperBusy,
        );
      },
    );
  });

  test(
    'no last keyframe yet: intervals/distances are permissive by construction',
    () {
      expect(
        _decide(
          numReliableLms: 127,
          sinceLastKeyframeSec: null,
          distanceTraveledM: null,
          minDistanceM: 0.05,
        ),
        AutoCaptureDecision.fire,
        reason: '上游:!last_inserted_keyfrm ⇒ min_* 为 true、max_* 为 false',
      );
    },
  );

  group('min_distance 取值 —— SVO 论文的式子(12% 场景深度)', () {
    test(
      'threshold scales with scene depth; unknown depth disables the gate',
      () {
        expect(kSvoKeyframeMinDistanceSceneDepthRatio, 0.12);
        expect(autoCaptureMinDistanceMetres(1.0), closeTo(0.12, 1e-12));
        expect(autoCaptureMinDistanceMetres(10.0), closeTo(1.2, 1e-12));
        expect(autoCaptureMinDistanceMetres(0.5), closeTo(0.06, 1e-12));
        // 没有活体点云深度 ⇒ 退回 stella 的默认 -1(门关闭),不猜绝对米数。
        expect(autoCaptureMinDistanceMetres(null), kStellaMinDistanceM);
        expect(autoCaptureMinDistanceMetres(0), kStellaMinDistanceM);
        expect(autoCaptureMinDistanceMetres(-3), kStellaMinDistanceM);
        expect(autoCaptureMinDistanceMetres(double.nan), kStellaMinDistanceM);
        expect(
          autoCaptureMinDistanceMetres(double.infinity),
          kStellaMinDistanceM,
        );
      },
    );

    test('pure rotation cannot pass it: distance 0 always fails the gate', () {
      for (final depth in <double>[0.5, 1.0, 5.0, 20.0]) {
        expect(
          _decide(
            numReliableLms: 127, // view_changed:转头把画面换了
            distanceTraveledM: 0.0,
            minDistanceM: autoCaptureMinDistanceMetres(depth),
          ),
          AutoCaptureDecision.skipMinDistance,
          reason: 'depth=$depth',
        );
      }
    });

    test('12% of scene depth is exactly the boundary', () {
      final thr = autoCaptureMinDistanceMetres(1.0); // 0.12 m
      expect(
        _decide(
          numReliableLms: 127,
          distanceTraveledM: 0.12,
          minDistanceM: thr,
        ),
        AutoCaptureDecision.skipMinDistance,
        reason: '上游用严格 > ⇒ 正好等于阈值不算走够',
      );
      expect(
        _decide(
          numReliableLms: 127,
          distanceTraveledM: 0.13,
          minDistanceM: thr,
        ),
        AutoCaptureDecision.fire,
      );
    });
  });

  test('product gates keep their place', () {
    expect(
      _decide(capturedCount: kOfficialMaximumCaptureFrames),
      AutoCaptureDecision.skipCapped,
    );
    expect(
      _decide(elapsedSec: kAutoCaptureTimeLimitSec),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(_decide(trackingNormal: false), AutoCaptureDecision.skipTracking);
    expect(_decide(tooDark: true), AutoCaptureDecision.skipTooDark);
    expect(
      _decide(awaitingCaptureBaseline: true),
      AutoCaptureDecision.skipAwaitingCapture,
    );
    expect(_decide(initialized: false), AutoCaptureDecision.skipNotMoved);
    expect(
      _decide(hasTrackEvidence: false),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
    expect(
      _decide(numReliableLms: 127, blurry: true),
      AutoCaptureDecision.skipBlurry,
    );
  });
}
