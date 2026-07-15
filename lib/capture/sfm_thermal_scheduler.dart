// Pure scheduling policy for the disk-backed SfM background consumer.
//
// This module deliberately has no frame identity, payload, resolution, feature,
// or queue-mutation API. A `send` decision authorizes the caller to offer only
// the current durable FIFO head. `pause`/`cooldown` leave every accepted job in
// the same denominator and order. Phone qualification, not this host policy,
// must choose any less-conservative serious-thermal pacing values.
// This API boundary does not prove that the real disk-queue adapter obeys the
// decision; adapter integration and physical-device evidence remain unverified.

/// Explicit consumption limits used by [decideSfmBackgroundSchedule].
///
/// Defaults are deliberately conservative and are not an iPhone thermal
/// verdict: serious thermal state does not start new work. A future
/// device-qualified caller may provide an explicit serious budget without
/// changing the scheduler or its no-drop contract. Missing or future thermal
/// values use a fixed one-in-flight fallback so an unavailable probe cannot
/// deadlock the durable queue. Critical heat and GPU-failure risk remain hard
/// fail-closed and cannot be configured open.
final class SfmThermalSchedulerConfig {
  const SfmThermalSchedulerConfig({
    this.nominalAllowedInFlight = 2,
    this.fairAllowedInFlight = 1,
    this.seriousAllowedInFlight = 0,
    this.consecutiveGpuFailureThreshold = 2,
  });

  final int nominalAllowedInFlight;
  final int fairAllowedInFlight;
  final int seriousAllowedInFlight;

  /// Number of adjacent GPU failures that is treated as a recovery risk.
  final int consecutiveGpuFailureThreshold;
}

/// One immutable observation used to decide whether the background consumer
/// may offer the next durable FIFO item.
final class SfmBackgroundScheduleInput {
  const SfmBackgroundScheduleInput({
    required this.thermalState,
    required this.recentGpuResultCode,
    required this.consecutiveGpuFailures,
    required this.queueDepth,
    required this.inFlight,
    required this.cooldownRemaining,
    required this.finalizeRequested,
  });

  /// Platform thermal bucket: 0 nominal, 1 fair, 2 serious, 3 critical.
  /// Null and every other value use the bounded unknown-state fallback.
  final int? thermalState;

  /// Most recent Metal/GPU result code, if one is available. rc=7 is the
  /// command-buffer failure risk and is always fail-closed.
  final int? recentGpuResultCode;

  final int consecutiveGpuFailures;

  /// Number of durable FIFO items waiting to be offered. In-flight work is not
  /// included in this count.
  final int queueDepth;

  final int inFlight;

  /// Monotonic-clock remainder owned by the caller. Zero means expired. The
  /// scheduler intentionally does not invent a device pacing duration.
  final Duration cooldownRemaining;

  final bool finalizeRequested;
}

/// A background-consumption decision. [cooldown] is a subtype of [pause].
///
/// The output intentionally contains no drop, skip, reorder, quality, or
/// accepted-denominator operation.
final class SfmBackgroundScheduleDecision {
  const SfmBackgroundScheduleDecision._({
    required this.send,
    required this.pause,
    required this.cooldown,
    required this.allowedInFlight,
    required this.reason,
  });

  const SfmBackgroundScheduleDecision._send({
    required int allowedInFlight,
    required String reason,
  }) : this._(
         send: true,
         pause: false,
         cooldown: false,
         allowedInFlight: allowedInFlight,
         reason: reason,
       );

  const SfmBackgroundScheduleDecision._pause({
    required int allowedInFlight,
    required String reason,
  }) : this._(
         send: false,
         pause: true,
         cooldown: false,
         allowedInFlight: allowedInFlight,
         reason: reason,
       );

  const SfmBackgroundScheduleDecision._cooldown({required String reason})
    : this._(
        send: false,
        pause: true,
        cooldown: true,
        allowedInFlight: 0,
        reason: reason,
      );

  /// Whether the caller may offer exactly the current durable FIFO head.
  final bool send;

  /// Whether the caller must refrain from starting another item.
  final bool pause;

  /// Whether the pause is specifically a GPU recovery/cooldown pause.
  final bool cooldown;

  /// Maximum target concurrency for the observed state. Existing work is not
  /// cancelled when the target falls below [SfmBackgroundScheduleInput.inFlight].
  final int allowedInFlight;

  /// Stable, telemetry-safe explanation of the decision.
  final String reason;

  @override
  bool operator ==(Object other) {
    return other is SfmBackgroundScheduleDecision &&
        other.send == send &&
        other.pause == pause &&
        other.cooldown == cooldown &&
        other.allowedInFlight == allowedInFlight &&
        other.reason == reason;
  }

  @override
  int get hashCode =>
      Object.hash(send, pause, cooldown, allowedInFlight, reason);

  @override
  String toString() {
    return 'SfmBackgroundScheduleDecision('
        'send: $send, pause: $pause, cooldown: $cooldown, '
        'allowedInFlight: $allowedInFlight, reason: $reason)';
  }
}

enum _ThermalBand { nominal, fair, serious, critical, unknown }

_ThermalBand _thermalBand(int? raw) {
  return switch (raw) {
    0 => _ThermalBand.nominal,
    1 => _ThermalBand.fair,
    2 => _ThermalBand.serious,
    3 => _ThermalBand.critical,
    _ => _ThermalBand.unknown,
  };
}

/// Returns the opportunistic idle-repayment budget for a fresh thermal sample.
///
/// Idle repayment is optional latency work, not durable FIFO consumption. It
/// must therefore be stricter than the queue's bounded unknown-state fallback:
/// only nominal/fair devices may start it. Serious, critical, missing, and
/// future thermal values defer every pair until a later cool sample.
int? sfmIdleRepayBudgetForThermal(int? thermalState) {
  return switch (_thermalBand(thermalState)) {
    _ThermalBand.nominal || _ThermalBand.fair => 24,
    _ThermalBand.serious ||
    _ThermalBand.critical ||
    _ThermalBand.unknown => null,
  };
}

/// Decides whether the background SfM consumer may offer its FIFO head.
///
/// This is a pure function: identical observations return identical decisions,
/// and neither the input nor the durable queue is mutated.
SfmBackgroundScheduleDecision decideSfmBackgroundSchedule({
  required SfmBackgroundScheduleInput input,
  SfmThermalSchedulerConfig config = const SfmThermalSchedulerConfig(),
}) {
  // Do not rely on constructor asserts: release builds may disable them. Check
  // every field on every decision, even if the current thermal band would not
  // otherwise read that field.
  _validateConfig(config);
  _requireNonNegative('queueDepth', input.queueDepth);
  _requireNonNegative('inFlight', input.inFlight);
  _requireNonNegative('consecutiveGpuFailures', input.consecutiveGpuFailures);
  if (input.cooldownRemaining.isNegative) {
    throw ArgumentError.value(
      input.cooldownRemaining,
      'cooldownRemaining',
      'must not be negative',
    );
  }

  final thermal = _thermalBand(input.thermalState);

  // Critical heat and rc=7 are not device-tunable: never start more GPU work.
  if (thermal == _ThermalBand.critical) {
    return const SfmBackgroundScheduleDecision._pause(
      allowedInFlight: 0,
      reason: 'thermal_critical_pause',
    );
  }
  if (input.recentGpuResultCode == 7) {
    return const SfmBackgroundScheduleDecision._cooldown(
      reason: 'recent_metal_rc7_cooldown',
    );
  }
  if (input.consecutiveGpuFailures >= config.consecutiveGpuFailureThreshold) {
    return const SfmBackgroundScheduleDecision._cooldown(
      reason: 'consecutive_gpu_failures_cooldown',
    );
  }
  if (input.cooldownRemaining > Duration.zero) {
    return const SfmBackgroundScheduleDecision._cooldown(
      reason: 'cooldown_clock_active',
    );
  }

  final allowedInFlight = switch (thermal) {
    _ThermalBand.nominal => config.nominalAllowedInFlight,
    _ThermalBand.fair => config.fairAllowedInFlight,
    _ThermalBand.serious => config.seriousAllowedInFlight,
    // Telemetry can be absent on unsupported hosts and during probe startup.
    // One-at-a-time progress prevents a permanent queue deadlock while keeping
    // unknown values below the normal nominal budget.
    _ThermalBand.unknown => 1,
    _ThermalBand.critical => 0,
  };

  if (allowedInFlight == 0) {
    final reason = switch (thermal) {
      _ThermalBand.serious => 'thermal_serious_conservative_pause',
      _ThermalBand.unknown => 'thermal_unknown_bounded_pause',
      _ThermalBand.nominal => 'thermal_nominal_configured_pause',
      _ThermalBand.fair => 'thermal_fair_configured_pause',
      _ThermalBand.critical => 'thermal_critical_pause',
    };
    return SfmBackgroundScheduleDecision._pause(
      allowedInFlight: 0,
      reason: reason,
    );
  }

  if (input.queueDepth == 0) {
    if (input.finalizeRequested) {
      return SfmBackgroundScheduleDecision._pause(
        allowedInFlight: allowedInFlight,
        reason: input.inFlight == 0
            ? 'finalize_background_drained'
            : 'finalize_waiting_for_in_flight',
      );
    }
    return SfmBackgroundScheduleDecision._pause(
      allowedInFlight: allowedInFlight,
      reason: 'queue_empty',
    );
  }

  if (input.inFlight >= allowedInFlight) {
    return SfmBackgroundScheduleDecision._pause(
      allowedInFlight: allowedInFlight,
      reason: 'in_flight_limit',
    );
  }

  if (input.finalizeRequested) {
    return SfmBackgroundScheduleDecision._send(
      allowedInFlight: allowedInFlight,
      reason: 'finalize_drain_ready',
    );
  }

  final reason = switch (thermal) {
    _ThermalBand.nominal => 'thermal_nominal_ready',
    _ThermalBand.fair => 'thermal_fair_ready',
    _ThermalBand.serious => 'thermal_serious_configured_ready',
    _ThermalBand.unknown => 'thermal_unknown_bounded_ready',
    _ThermalBand.critical => 'thermal_critical_pause',
  };
  return SfmBackgroundScheduleDecision._send(
    allowedInFlight: allowedInFlight,
    reason: reason,
  );
}

void _validateConfig(SfmThermalSchedulerConfig config) {
  _requireNonNegative(
    'config.nominalAllowedInFlight',
    config.nominalAllowedInFlight,
  );
  _requireNonNegative('config.fairAllowedInFlight', config.fairAllowedInFlight);
  _requireNonNegative(
    'config.seriousAllowedInFlight',
    config.seriousAllowedInFlight,
  );
  if (config.consecutiveGpuFailureThreshold <= 0) {
    throw ArgumentError.value(
      config.consecutiveGpuFailureThreshold,
      'config.consecutiveGpuFailureThreshold',
      'must be greater than zero',
    );
  }
}

void _requireNonNegative(String name, int value) {
  if (value < 0) {
    throw ArgumentError.value(value, name, 'must not be negative');
  }
}
