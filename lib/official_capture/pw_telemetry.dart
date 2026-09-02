// pw_telemetry.dart — FFI binding for the native capture telemetry probe
// (PWOfficialSfm's copied telemetry probe). Pure FFI, so it works from the
// SfM worker isolate: the worker samples it right after each add_frame — the
// per-frame memory PEAK — with no platform-channel round-trip.
//
// Numbers exposed, and the honest limits:
//   • physFootprintMb — the jetsam-relevant resident cost (task_info
//     TASK_VM_INFO phys_footprint). The figure the OS kills you by.
//   • peakFootprintMb — high-water mark of the same over the process lifetime.
//   • thermalState — ProcessInfo's 4-level bucket. Apple exposes NO numeric
//     temperature to shipping apps; this bucket is the only thermal signal.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../official_aether_ffi.dart' show OfficialAetherFfi;

/// One telemetry sample.
class PwTelemetrySample {
  const PwTelemetrySample({
    required this.physFootprintMb,
    required this.peakFootprintMb,
    required this.thermalState,
  });

  /// Jetsam-relevant resident footprint, MB. -1 if the mach query failed.
  final double physFootprintMb;

  /// Process-lifetime high-water footprint, MB.
  final double peakFootprintMb;

  /// 0 nominal · 1 fair · 2 serious · 3 critical.
  final int thermalState;

  String get thermalName => switch (thermalState) {
    0 => 'nominal',
    1 => 'fair',
    2 => 'serious',
    3 => 'critical',
    _ => 'unknown',
  };

  @override
  String toString() =>
      'mem=${physFootprintMb.toStringAsFixed(0)}MB '
      'peak=${peakFootprintMb.toStringAsFixed(0)}MB '
      'thermal=$thermalName';
}

typedef _TelemetryC = Int32 Function(
  Pointer<Double> physMb,
  Pointer<Double> peakMb,
  Pointer<Int32> thermal,
);
typedef _TelemetryDart = int Function(
  Pointer<Double> physMb,
  Pointer<Double> peakMb,
  Pointer<Int32> thermal,
);

class PwTelemetry {
  PwTelemetry._();

  static _TelemetryDart? _fn;
  static bool _resolveFailed = false;

  static _TelemetryDart? _resolve() {
    if (_fn != null) return _fn;
    if (_resolveFailed) return null;
    try {
      _fn = OfficialAetherFfi.resolveLibraryForBindings()
          .lookupFunction<_TelemetryC, _TelemetryDart>('pwofficial_telemetry');
      return _fn;
    } catch (_) {
      _resolveFailed = true; // simulator / symbol missing — telemetry off
      return null;
    }
  }

  /// Samples now. Returns null if the native probe is unavailable (e.g. the
  /// simulator, where the symbol is not linked).
  static PwTelemetrySample? sample() {
    final fn = _resolve();
    if (fn == null) return null;
    final phys = malloc<Double>();
    final peak = malloc<Double>();
    final therm = malloc<Int32>();
    try {
      phys.value = -1;
      peak.value = -1;
      therm.value = -1;
      fn(phys, peak, therm);
      return PwTelemetrySample(
        physFootprintMb: phys.value,
        peakFootprintMb: peak.value,
        thermalState: therm.value,
      );
    } finally {
      malloc.free(phys);
      malloc.free(peak);
      malloc.free(therm);
    }
  }
}
