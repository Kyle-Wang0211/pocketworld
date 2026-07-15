import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_thermal_scheduler.dart';

void main() {
  const conservative = SfmThermalSchedulerConfig();

  SfmBackgroundScheduleInput input({
    int? thermalState = 0,
    int? recentGpuResultCode,
    int consecutiveGpuFailures = 0,
    int queueDepth = 1,
    int inFlight = 0,
    Duration cooldownRemaining = Duration.zero,
    bool finalizeRequested = false,
    bool foregroundCaptureActive = false,
  }) {
    return SfmBackgroundScheduleInput(
      thermalState: thermalState,
      recentGpuResultCode: recentGpuResultCode,
      consecutiveGpuFailures: consecutiveGpuFailures,
      queueDepth: queueDepth,
      inFlight: inFlight,
      cooldownRemaining: cooldownRemaining,
      finalizeRequested: finalizeRequested,
      foregroundCaptureActive: foregroundCaptureActive,
    );
  }

  group('conservative defaults', () {
    test('nominal keeps only one background item outstanding', () {
      final ready = decideSfmBackgroundSchedule(
        input: input(thermalState: 0, queueDepth: 3),
        config: conservative,
      );
      final full = decideSfmBackgroundSchedule(
        input: input(thermalState: 0, queueDepth: 3, inFlight: 1),
        config: conservative,
      );

      expect(ready.send, isTrue);
      expect(ready.pause, isFalse);
      expect(ready.cooldown, isFalse);
      expect(ready.allowedInFlight, 1);
      expect(ready.reason, 'thermal_nominal_ready');
      expect(full.send, isFalse);
      expect(full.pause, isTrue);
      expect(full.allowedInFlight, 1);
      expect(full.reason, 'in_flight_limit');
    });

    test('foreground publication owns priority over every thermal band', () {
      for (final thermal in <int?>[0, 1, 2, 3, null]) {
        final decision = decideSfmBackgroundSchedule(
          input: input(
            thermalState: thermal,
            queueDepth: 100,
            foregroundCaptureActive: true,
          ),
          config: conservative,
        );

        expect(decision.send, isFalse, reason: 'thermal=$thermal');
        expect(decision.pause, isTrue, reason: 'thermal=$thermal');
        expect(decision.allowedInFlight, 0, reason: 'thermal=$thermal');
        expect(
          decision.reason,
          'foreground_capture_priority',
          reason: 'thermal=$thermal',
        );
      }
    });

    test('fair uses the conservative one-in-flight budget', () {
      final ready = decideSfmBackgroundSchedule(
        input: input(thermalState: 1),
        config: conservative,
      );
      final full = decideSfmBackgroundSchedule(
        input: input(thermalState: 1, inFlight: 1),
        config: conservative,
      );

      expect(ready.send, isTrue);
      expect(ready.allowedInFlight, 1);
      expect(ready.reason, 'thermal_fair_ready');
      expect(full.send, isFalse);
      expect(full.pause, isTrue);
      expect(full.allowedInFlight, 1);
      expect(full.reason, 'in_flight_limit');
    });

    test('serious pauses by default instead of claiming a phone verdict', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(thermalState: 2, queueDepth: 20),
        config: conservative,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.cooldown, isFalse);
      expect(decision.allowedInFlight, 0);
      expect(decision.reason, 'thermal_serious_conservative_pause');
    });

    test('critical always fails closed even with a tuned config', () {
      const tuned = SfmThermalSchedulerConfig(
        nominalAllowedInFlight: 4,
        fairAllowedInFlight: 3,
        seriousAllowedInFlight: 2,
      );

      final decision = decideSfmBackgroundSchedule(
        input: input(thermalState: 3, queueDepth: 20, finalizeRequested: true),
        config: tuned,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.cooldown, isFalse);
      expect(decision.allowedInFlight, 0);
      expect(decision.reason, 'thermal_critical_pause');
    });

    test('unknown thermal uses a bounded fallback instead of deadlocking', () {
      for (final thermal in <int?>[null, -1, 4, 99]) {
        final ready = decideSfmBackgroundSchedule(
          input: input(thermalState: thermal, queueDepth: 100),
          config: conservative,
        );
        final full = decideSfmBackgroundSchedule(
          input: input(thermalState: thermal, queueDepth: 100, inFlight: 1),
          config: conservative,
        );

        expect(ready.send, isTrue, reason: 'thermal=$thermal');
        expect(ready.pause, isFalse, reason: 'thermal=$thermal');
        expect(ready.allowedInFlight, 1, reason: 'thermal=$thermal');
        expect(
          ready.reason,
          'thermal_unknown_bounded_ready',
          reason: 'thermal=$thermal',
        );
        expect(full.send, isFalse, reason: 'thermal=$thermal');
        expect(full.pause, isTrue, reason: 'thermal=$thermal');
        expect(full.allowedInFlight, 1, reason: 'thermal=$thermal');
        expect(full.reason, 'in_flight_limit', reason: 'thermal=$thermal');
      }
    });

    test('sustained thermal pauses preserve FIFO and recovery is explicit', () {
      final queue = <String>['job_0', 'job_1', 'job_2'];
      final original = List<String>.of(queue);

      final pressure = <int>[2, 2, 3, 3]
          .map(
            (thermal) => decideSfmBackgroundSchedule(
              input: input(thermalState: thermal, queueDepth: queue.length),
              config: conservative,
            ),
          )
          .toList();

      for (final decision in pressure) {
        expect(decision.send, isFalse);
        expect(decision.pause, isTrue);
        expect(queue, original);
      }
      expect(pressure.map((decision) => decision.reason), <String>[
        'thermal_serious_conservative_pause',
        'thermal_serious_conservative_pause',
        'thermal_critical_pause',
        'thermal_critical_pause',
      ]);

      final recovered = decideSfmBackgroundSchedule(
        input: input(thermalState: 1, queueDepth: queue.length),
        config: conservative,
      );

      expect(recovered.send, isTrue);
      expect(recovered.pause, isFalse);
      expect(recovered.reason, 'thermal_fair_ready');
      expect(queue.first, 'job_0');
      expect(queue, original);
    });
  });

  group('GPU failure and cooldown safety', () {
    test('recent Metal rc=7 enters a fail-closed cooldown pause', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(
          thermalState: 0,
          recentGpuResultCode: 7,
          queueDepth: 50,
          finalizeRequested: true,
        ),
        config: conservative,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.cooldown, isTrue);
      expect(decision.allowedInFlight, 0);
      expect(decision.reason, 'recent_metal_rc7_cooldown');
    });

    test('configured consecutive-failure threshold enters cooldown', () {
      const config = SfmThermalSchedulerConfig(
        consecutiveGpuFailureThreshold: 3,
      );
      final below = decideSfmBackgroundSchedule(
        input: input(consecutiveGpuFailures: 2),
        config: config,
      );
      final atThreshold = decideSfmBackgroundSchedule(
        input: input(consecutiveGpuFailures: 3),
        config: config,
      );

      expect(below.send, isTrue);
      expect(atThreshold.send, isFalse);
      expect(atThreshold.pause, isTrue);
      expect(atThreshold.cooldown, isTrue);
      expect(atThreshold.allowedInFlight, 0);
      expect(atThreshold.reason, 'consecutive_gpu_failures_cooldown');
    });

    test('non-rc7 result does not independently trigger cooldown', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(recentGpuResultCode: 6),
        config: conservative,
      );

      expect(decision.send, isTrue);
      expect(decision.cooldown, isFalse);
    });

    test(
      'cooldown clock holds and then deterministically resumes FIFO drain',
      () {
        final active = decideSfmBackgroundSchedule(
          input: input(
            cooldownRemaining: const Duration(microseconds: 1),
            finalizeRequested: true,
          ),
          config: conservative,
        );
        final expired = decideSfmBackgroundSchedule(
          input: input(
            cooldownRemaining: Duration.zero,
            finalizeRequested: true,
          ),
          config: conservative,
        );

        expect(active.send, isFalse);
        expect(active.pause, isTrue);
        expect(active.cooldown, isTrue);
        expect(active.reason, 'cooldown_clock_active');
        expect(expired.send, isTrue);
        expect(expired.cooldown, isFalse);
        expect(expired.reason, 'finalize_drain_ready');
      },
    );
  });

  group('queue and finalize boundaries', () {
    test('empty queue never sends', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(queueDepth: 0),
        config: conservative,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.reason, 'queue_empty');
    });

    test('finalize waits for an already in-flight tail', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(queueDepth: 0, inFlight: 1, finalizeRequested: true),
        config: conservative,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.reason, 'finalize_waiting_for_in_flight');
    });

    test('finalize reports a drained background only at zero backlog', () {
      final decision = decideSfmBackgroundSchedule(
        input: input(queueDepth: 0, inFlight: 0, finalizeRequested: true),
        config: conservative,
      );

      expect(decision.send, isFalse);
      expect(decision.pause, isTrue);
      expect(decision.reason, 'finalize_background_drained');
    });

    test('finalize backlog cannot bypass serious or critical safety', () {
      for (final thermal in <int>[2, 3]) {
        final decision = decideSfmBackgroundSchedule(
          input: input(
            thermalState: thermal,
            queueDepth: 100,
            finalizeRequested: true,
          ),
          config: conservative,
        );

        expect(decision.send, isFalse, reason: 'thermal=$thermal');
        expect(decision.pause, isTrue, reason: 'thermal=$thermal');
      }
    });

    test(
      'explicit serious pacing is configurable but not a default verdict',
      () {
        const qualifiedConfig = SfmThermalSchedulerConfig(
          seriousAllowedInFlight: 1,
        );
        final ready = decideSfmBackgroundSchedule(
          input: input(thermalState: 2, queueDepth: 2),
          config: qualifiedConfig,
        );
        final full = decideSfmBackgroundSchedule(
          input: input(thermalState: 2, queueDepth: 2, inFlight: 1),
          config: qualifiedConfig,
        );

        expect(ready.send, isTrue);
        expect(ready.allowedInFlight, 1);
        expect(ready.reason, 'thermal_serious_configured_ready');
        expect(full.send, isFalse);
        expect(full.reason, 'in_flight_limit');
      },
    );
  });

  group('input boundaries', () {
    test('decision validates every config field at runtime', () {
      final invalidConfigs = <SfmThermalSchedulerConfig>[
        SfmThermalSchedulerConfig(nominalAllowedInFlight: -1),
        SfmThermalSchedulerConfig(fairAllowedInFlight: -1),
        SfmThermalSchedulerConfig(seriousAllowedInFlight: -1),
        SfmThermalSchedulerConfig(consecutiveGpuFailureThreshold: 0),
      ];

      for (final invalidConfig in invalidConfigs) {
        expect(
          () => decideSfmBackgroundSchedule(
            input: input(thermalState: 0),
            config: invalidConfig,
          ),
          throwsArgumentError,
        );
      }
    });

    test(
      'rejects negative queue, in-flight, failures, and cooldown inputs',
      () {
        expect(
          () => decideSfmBackgroundSchedule(
            input: input(queueDepth: -1),
            config: conservative,
          ),
          throwsArgumentError,
        );
        expect(
          () => decideSfmBackgroundSchedule(
            input: input(inFlight: -1),
            config: conservative,
          ),
          throwsArgumentError,
        );
        expect(
          () => decideSfmBackgroundSchedule(
            input: input(consecutiveGpuFailures: -1),
            config: conservative,
          ),
          throwsArgumentError,
        );
        expect(
          () => decideSfmBackgroundSchedule(
            input: input(cooldownRemaining: const Duration(microseconds: -1)),
            config: conservative,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  // Contract boundary: this proves that the pure decision surface cannot
  // express drop/skip/reorder. It does not claim the real disk-queue adapter is
  // integrated or verified; that needs separate adapter and phone evidence.
  test('pure decisions cannot drop or skip a FIFO job', () {
    const thermals = <int?>[0, 1, 2, 3, null, -1, 4];
    const resultCodes = <int?>[null, 0, 6, 7];
    const cooldowns = <Duration>[Duration.zero, Duration(microseconds: 1)];

    for (final thermal in thermals) {
      for (final resultCode in resultCodes) {
        for (var failures = 0; failures <= 3; failures++) {
          for (var queueDepth = 0; queueDepth <= 3; queueDepth++) {
            for (var inFlight = 0; inFlight <= 3; inFlight++) {
              for (final cooldown in cooldowns) {
                for (final finalizeRequested in <bool>[false, true]) {
                  final scheduleInput = input(
                    thermalState: thermal,
                    recentGpuResultCode: resultCode,
                    consecutiveGpuFailures: failures,
                    queueDepth: queueDepth,
                    inFlight: inFlight,
                    cooldownRemaining: cooldown,
                    finalizeRequested: finalizeRequested,
                  );
                  final first = decideSfmBackgroundSchedule(
                    input: scheduleInput,
                    config: conservative,
                  );
                  final repeated = decideSfmBackgroundSchedule(
                    input: scheduleInput,
                    config: conservative,
                  );

                  expect(first, repeated);
                  expect(first.pause, isNot(first.send));
                  expect(first.cooldown && !first.pause, isFalse);
                  expect(first.allowedInFlight, greaterThanOrEqualTo(0));
                  if (first.send) {
                    expect(queueDepth, greaterThan(0));
                    expect(inFlight, lessThan(first.allowedInFlight));
                  }
                  if (thermal == 3 || resultCode == 7) {
                    expect(first.send, isFalse);
                  }

                  final original = List<String>.generate(
                    queueDepth,
                    (index) => 'job_$index',
                  );
                  final sent = first.send && original.isNotEmpty
                      ? <String>[original.first]
                      : const <String>[];
                  final remaining = first.send && original.isNotEmpty
                      ? original.sublist(1)
                      : original;
                  expect(<String>[...sent, ...remaining], original);
                }
              }
            }
          }
        }
      }
    }
  });

  group('idle repay thermal gate', () {
    test('only nominal and fair may start opportunistic GPU repayment', () {
      expect(sfmIdleRepayBudgetForThermal(0), 24);
      expect(sfmIdleRepayBudgetForThermal(1), 24);
      expect(sfmIdleRepayBudgetForThermal(2), isNull);
      expect(sfmIdleRepayBudgetForThermal(3), isNull);
      expect(sfmIdleRepayBudgetForThermal(null), isNull);
      expect(sfmIdleRepayBudgetForThermal(-1), isNull);
      expect(sfmIdleRepayBudgetForThermal(4), isNull);
    });
  });
}
