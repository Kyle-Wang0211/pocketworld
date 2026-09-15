// sparse_cloud_view_perspective_start_test.dart — functional arm for the capture-pose start: the view
// applies the start once it knows its size, emits the exact camera, morphs to the orthographic rig on the
// first gesture, and a view WITHOUT a start behaves as before (negative control).
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/capture_pose_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

Float32List _cloud() {
  final xyz = Float32List(3 * 50);
  for (var i = 0; i < 50; i++) {
    xyz[i * 3] = (i % 5 - 2) * 0.2;
    xyz[i * 3 + 1] = (i ~/ 5 % 5 - 2) * 0.2;
    xyz[i * 3 + 2] =
        -1.5 - (i % 3) * 0.3; // in front of an identity camera looking along −z
  }
  return xyz;
}

void main() {
  const size = Size(393, 756);
  final rect = const Rect.fromLTWH(0, 59, 393, 524);

  PerspectiveStart start(Float32List xyz) {
    final pin = capturePinholeFromPose(
      extrinsic4x4: const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      intrinsicFxFyCxCy: const [1450, 1450, 960, 720],
      imageWidth: 1920,
      imageHeight: 1440,
      viewport: rect,
    )!;
    return capturePoseToRig(pin: pin, xyz: xyz, viewport: rect)!;
  }

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: SizedBox(width: size.width, height: size.height, child: child),
    ),
  );

  testWidgets(
    'applies the capture-pose start and emits its camera; first gesture morphs without errors',
    (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final xyz = _cloud();
      final s = start(xyz);
      CloudViewCamera? cam;
      await tester.pumpWidget(
        host(
          SparseCloudView(
            xyz: xyz,
            rgb: Uint8List(xyz.length),
            initialPerspective: s,
            onCameraChanged: (c) => cam = c,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(cam, isNotNull);
      expect(cam!.yaw, closeTo(s.yaw, 1e-12));
      expect(cam!.pitch, closeTo(s.pitch, 1e-12));
      expect(cam!.roll, closeTo(s.roll, 1e-12));
      expect(cam!.pivotX, closeTo(s.pivotX, 1e-12));
      // the widget the test built has the size of the Scaffold body: pan/zoom follow that size
      final viewSize = tester.getSize(find.byType(SparseCloudView));
      expect(cam!.panX, closeTo(s.ox - viewSize.width / 2, 1e-9));
      expect(cam!.panY, closeTo(s.oy - viewSize.height / 2, 1e-9));
      // a drag = first gesture ⇒ morph runs to completion without throwing
      await tester.drag(find.byType(SparseCloudView), const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'negative control: without a start the default camera is used (yaw/pitch presets)',
    (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final xyz = _cloud();
      CloudViewCamera? cam;
      await tester.pumpWidget(
        host(
          SparseCloudView(
            xyz: xyz,
            rgb: Uint8List(xyz.length),
            onCameraChanged: (c) => cam = c,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(cam, isNotNull);
      expect(cam!.zoom, 1.0);
      expect(cam!.panX, 0);
      expect(cam!.panY, 0);
      // the default rig looks 45° from above; the identity capture pose looks level (pitch 0)
      expect(cam!.pitch, isNot(closeTo(start(xyz).pitch, 1e-6)));
      expect(tester.takeException(), isNull);
    },
  );
}
