/// Pure-Dart algorithm core for the PocketWorld Android capture layer.
///
/// Nothing here imports dart:ui, Flutter or any Android binding, so every
/// decision the capture layer makes is unit-testable on a host machine with no
/// device and no Android project. The Kotlin under `android_ready/kotlin/` is
/// deliberately a thin marshaller: it reads platform values and hands them to
/// these classes, which own all of the judgement.
library pw_android_capture;

export 'src/camera_timebase.dart';
export 'src/channel_codec.dart';
export 'src/clock_offset.dart';
export 'src/deferred_frame_buffer.dart';
export 'src/exit_triage.dart';
export 'src/sensor_delivery_monitor.dart';
export 'src/thermal_policy.dart';
