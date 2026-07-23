// Cell state for the spherical capture-guidance UI.
//
// Ported from Aether3D's `ObjectModeV2CoverageMap.swift::DomeCellState`.
// Four states corresponding to four colors painted on the dome's 12×5 grid:
//
//   empty     灰  — no usable frame captured for this cell yet
//   weak      黄  — has frames but not enough for a confident contribution
//   ok        浅绿 — enough frames at acceptable quality
//   excellent 深绿 — enough frames spread over time + angle, sharp + stable
//
// Numeric ordering matters: a "high water mark" mechanism in the state
// machine never reverts a cell to a lower state (see ring_buffer_cell.dart).

import 'package:flutter/widgets.dart';

enum DomeCellState {
  /// Gray. Nothing recorded yet.
  empty(0),

  /// Yellow / orange. Has 1–2 frames or fails the excellent gates.
  weak(1),

  /// Light green. Confident contribution but not yet "perfect".
  ok(2),

  /// Dark green. Hits all the excellence thresholds (frame count, sharpness,
  /// azimuth spread, time spread, motion ceiling).
  excellent(3);

  final int rank;
  const DomeCellState(this.rank);

  /// Exact color values copied from
  /// `ObjectModeV2CoverageMap.swift::DomeCellState.uiColor` so the Flutter
  /// dome looks identical to the iOS reference. ARGB hex; alpha bakes in
  /// the UIColor's alpha channel.
  ///
  ///   empty     UIColor(white: 0.32, alpha: 0.40)        → 0x66525252
  ///   weak      UIColor(R 0.98 G 0.74 B 0.16 a 0.75)     → 0xBFFABD29
  ///   ok        UIColor(R 0.47 G 0.86 B 0.47 a 0.88)     → 0xE078DB78
  ///   excellent UIColor(R 0.12 G 0.70 B 0.12 a 0.95)     → 0xF21FB31F
  Color get color {
    switch (this) {
      case DomeCellState.empty:
        return const Color(0x66525252);
      case DomeCellState.weak:
        return const Color(0xBFFABD29);
      case DomeCellState.ok:
        return const Color(0xE078DB78);
      case DomeCellState.excellent:
        return const Color(0xF21FB31F);
    }
  }
}
