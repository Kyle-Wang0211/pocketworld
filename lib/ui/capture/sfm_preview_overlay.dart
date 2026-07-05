// sfm_preview_overlay.dart — capture-time sparse-cloud preview layer.
//
// Shown on the AR capture page the moment streaming SfM's finalize phase 1
// lands (LOCAL_READY): renders the FULL sparse point cloud + registered
// camera trajectory with a lightweight software projector (CustomPaint).
// When the background global BA converges the refined snapshot is swapped
// in silently — no interruption, just a small "精修完成" badge.
//
// Rendering may thin points for frame rate (draw stride); the DATA is always
// the full cloud — export/delivery paths never see a downsampled set.
//
// On-device extract_colors is OFF, so point r/g/b is usually all zeros;
// black points are NOT a failure — this painter detects that and falls back
// to a height-ramp grayscale, per the ABI contract.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../capture/sfm_live_recon.dart';

/// Preview lifecycle the capture page drives.
enum SfmPreviewPhase {
  /// finalize_async phase 1 (register + local BA) is running in the worker.
  generating,

  /// Local model live; background global BA still refining.
  localReady,

  /// Refined model swapped in.
  refined,

  /// Reconstruction failed — capture material is untouched and kept.
  error,
}

class SfmPreviewOverlay extends StatefulWidget {
  const SfmPreviewOverlay({
    super.key,
    required this.phase,
    required this.snapshot,
    required this.onDone,
    this.errorText,
  });

  final SfmPreviewPhase phase;
  final SfmLiveSnapshot? snapshot;
  final VoidCallback onDone;
  final String? errorText;

  @override
  State<SfmPreviewOverlay> createState() => _SfmPreviewOverlayState();
}

class _SfmPreviewOverlayState extends State<SfmPreviewOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat();

  double _yaw = 0.6;
  double _pitch = -0.42;
  double _zoom = 1.0;
  bool _dragging = false;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _spin.addListener(_onTick);
  }

  void _onTick() {
    final now = _spin.lastElapsedDuration ?? Duration.zero;
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (!_dragging && dt > 0 && dt < 0.25 && widget.snapshot != null) {
      setState(() => _yaw += dt * 0.25); // idle auto-orbit
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return Positioned.fill(
      child: Container(
        color: const Color(0xE6000000),
        child: Stack(
          children: [
            if (snapshot != null && snapshot.pointCount > 0)
              Positioned.fill(
                child: GestureDetector(
                  onScaleStart: (_) => _dragging = true,
                  onScaleEnd: (_) => _dragging = false,
                  onScaleUpdate: (d) {
                    setState(() {
                      _yaw += d.focalPointDelta.dx * 0.008;
                      _pitch = (_pitch + d.focalPointDelta.dy * 0.006)
                          .clamp(-1.35, 1.35);
                      if (d.scale != 1.0) {
                        _zoom = (_zoom * (1 + (d.scale - 1) * 0.08))
                            .clamp(0.3, 4.0);
                      }
                    });
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _SparseCloudPainter(
                        snapshot: snapshot,
                        yaw: _yaw,
                        pitch: _pitch,
                        zoom: _zoom,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            // ── status chip (top center)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Center(child: _statusChip(context)),
                ),
              ),
            ),
            // ── generating spinner (center, before any snapshot exists)
            if (widget.phase == SfmPreviewPhase.generating)
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white70,
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      '正在生成预览…',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            if (widget.phase == SfmPreviewPhase.error)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded,
                          color: Colors.white38, size: 40),
                      const SizedBox(height: 14),
                      const Text(
                        '本次未能重建，已保留素材',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      if (widget.errorText != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // ── done button (bottom)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Center(
                    child: GestureDetector(
                      onTap: widget.onDone,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 44, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: const Text(
                          '完成',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BuildContext context) {
    final snapshot = widget.snapshot;
    final String text;
    final IconData? icon;
    switch (widget.phase) {
      case SfmPreviewPhase.generating:
        text = '实时重建';
        icon = null;
      case SfmPreviewPhase.localReady:
        final n = snapshot?.pointCount ?? 0;
        text = '预览 · $n 点 · 精修中…';
        icon = null;
      case SfmPreviewPhase.refined:
        final n = snapshot?.pointCount ?? 0;
        text = '精修完成 · $n 点';
        icon = Icons.check_circle_rounded;
      case SfmPreviewPhase.error:
        text = '实时重建';
        icon = null;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xB31C1C1E),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: const Color(0xFF6EE7A0), size: 15),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

// ─── painter ─────────────────────────────────────────────────────────

class _SparseCloudPainter extends CustomPainter {
  _SparseCloudPainter({
    required this.snapshot,
    required this.yaw,
    required this.pitch,
    required this.zoom,
  });

  final SfmLiveSnapshot snapshot;
  final double yaw;
  final double pitch;
  final double zoom;

  // Fit-cache keyed by the snapshot identity (recomputed on swap-in).
  static Float32List? _cachedXyz;
  static double _cx = 0, _cy = 0, _cz = 0, _radius = 1;
  static double _minY = 0, _invYSpan = 1;

  static const int _maxDrawnPoints = 22000; // render thinning ONLY

  void _ensureFit() {
    final xyz = snapshot.xyz;
    if (identical(xyz, _cachedXyz) || xyz.isEmpty) return;
    _cachedXyz = xyz;
    final n = xyz.length ~/ 3;
    // Sampled percentile fit: robust against far outlier points, cheap on
    // clouds of any size.
    final step = math.max(1, n ~/ 4000);
    final xs = <double>[], ys = <double>[], zs = <double>[];
    for (var i = 0; i < n; i += step) {
      xs.add(xyz[i * 3]);
      ys.add(xyz[i * 3 + 1]);
      zs.add(xyz[i * 3 + 2]);
    }
    xs.sort();
    ys.sort();
    zs.sort();
    double pct(List<double> v, double p) => v[(v.length * p).floor()
        .clamp(0, v.length - 1)];
    _cx = pct(xs, 0.5);
    _cy = pct(ys, 0.5);
    _cz = pct(zs, 0.5);
    final rx = (pct(xs, 0.92) - pct(xs, 0.08)).abs();
    final ry = (pct(ys, 0.92) - pct(ys, 0.08)).abs();
    final rz = (pct(zs, 0.92) - pct(zs, 0.08)).abs();
    _radius = math.max(1e-6, math.max(rx, math.max(ry, rz)) * 0.62);
    _minY = pct(ys, 0.05);
    final ySpan = pct(ys, 0.95) - _minY;
    _invYSpan = ySpan.abs() < 1e-9 ? 1 : 1 / ySpan;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final xyz = snapshot.xyz;
    if (xyz.isEmpty || size.isEmpty) return;
    _ensureFit();

    final n = xyz.length ~/ 3;
    final stride = math.max(1, n ~/ _maxDrawnPoints);
    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosP = math.cos(pitch), sinP = math.sin(pitch);
    final half = size.shortestSide * 0.5;
    final f = half * 1.55 * zoom / _radius;
    final camDist = _radius * 3.2;
    final ox = size.width * 0.5, oy = size.height * 0.5;

    // Height-ramp brightness buckets (device point colors are usually all
    // zero — see file header). 6 buckets × drawRawPoints keeps this one
    // canvas pass per bucket, comfortably 60 fps at ~22k drawn points.
    const buckets = 6;
    final bucketPts = List.generate(buckets, (_) => <double>[]);

    for (var i = 0; i < n; i += stride) {
      final px = xyz[i * 3] - _cx;
      final py = xyz[i * 3 + 1] - _cy;
      final pz = xyz[i * 3 + 2] - _cz;
      // yaw about Y, then pitch about X
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;
      final depth = z2 + camDist;
      if (depth <= _radius * 0.15) continue; // behind/too close to camera
      final vx = ox + x1 * f / depth; // perspective divide
      final vy = oy - y2 * f / depth;
      if (vx < -8 || vx > size.width + 8 || vy < -8 || vy > size.height + 8) {
        continue;
      }
      final t = ((xyz[i * 3 + 1] - _minY) * _invYSpan).clamp(0.0, 1.0);
      final b = (t * (buckets - 1)).round();
      bucketPts[b]
        ..add(vx)
        ..add(vy);
    }

    final paint = Paint()
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (var b = 0; b < buckets; b++) {
      final pts = bucketPts[b];
      if (pts.isEmpty) continue;
      final lum = 120 + (b * 135 ~/ (buckets - 1));
      paint.color = Color.fromARGB(235, lum, lum, math.min(255, lum + 6));
      canvas.drawRawPoints(
          ui.PointMode.points, Float32List.fromList(pts), paint);
    }

    // Registered camera trajectory: CamFromWorld → camera center -Rᵀt.
    final poses = snapshot.posesPacked;
    if (poses.isNotEmpty) {
      final camPts = <double>[];
      for (var i = 0; i < poses.length; i += 9) {
        if (poses[i + 1] == 0) continue; // unregistered
        final qw = poses[i + 2], qx = poses[i + 3];
        final qy = poses[i + 4], qz = poses[i + 5];
        final tx = poses[i + 6], ty = poses[i + 7], tz = poses[i + 8];
        // C = -Rᵀ t, with R from the (unit) quaternion — Rᵀ row·t written out.
        final r00 = 1 - 2 * (qy * qy + qz * qz);
        final r01 = 2 * (qx * qy - qz * qw);
        final r02 = 2 * (qx * qz + qy * qw);
        final r10 = 2 * (qx * qy + qz * qw);
        final r11 = 1 - 2 * (qx * qx + qz * qz);
        final r12 = 2 * (qy * qz - qx * qw);
        final r20 = 2 * (qx * qz - qy * qw);
        final r21 = 2 * (qy * qz + qx * qw);
        final r22 = 1 - 2 * (qx * qx + qy * qy);
        final cxw = -(r00 * tx + r10 * ty + r20 * tz);
        final cyw = -(r01 * tx + r11 * ty + r21 * tz);
        final czw = -(r02 * tx + r12 * ty + r22 * tz);
        final px = cxw - _cx, py = cyw - _cy, pz = czw - _cz;
        final x1 = px * cosY + pz * sinY;
        final z1 = -px * sinY + pz * cosY;
        final y2 = py * cosP - z1 * sinP;
        final z2 = py * sinP + z1 * cosP;
        final depth = z2 + camDist;
        if (depth <= _radius * 0.15) continue;
        camPts
          ..add(ox + x1 * f / depth)
          ..add(oy - y2 * f / depth);
      }
      if (camPts.isNotEmpty) {
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(camPts),
          Paint()
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xCC000000),
        );
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(camPts),
          Paint()
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xFFFFD54F),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SparseCloudPainter old) =>
      old.snapshot != snapshot ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom;
}
