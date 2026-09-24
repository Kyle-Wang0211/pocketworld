// Widget judges for lib/ui/official_capture/lod_cloud_view.dart over a mocked channel:
// the page creates the texture at its PHYSICAL size, every setCamera carries that same
// viewport, the default is orthographic, gestures send a new matrix, and the toggle sends
// perspective. Negative controls: the first camera is not the dragged one; a disposed page
// disposes its texture.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';
import 'package:pocketworld_flutter/ui/official_capture/lod_cloud_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kPwLodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory oct;

  setUp(() {
    calls.clear();
    oct = Directory.systemTemp.createTempSync('lod_view_oct');
    File('${oct.path}/metadata.json').writeAsStringSync(
      '{"points":1000,"boundingBox":{"min":[-1,-2,-3],"max":[3,2,1]}}',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        final a = call.arguments as Map;
        return {
          'textureId': 5,
          'version': 'deadbeef abi=1',
          'backend': 5,
          'viewport_width_px': a['viewport_width_px'],
          'viewport_height_px': a['viewport_height_px'],
        };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    oct.deleteSync(recursive: true);
  });

  testWidgets(
    'create at physical size; camera viewport = targets; drag + toggle',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: LodCloudView(octreeDir: oct.path, showStats: false),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final create =
          calls.firstWhere((c) => c.method == 'create').arguments as Map;
      expect(create['viewport_width_px'], 1170);
      expect(create['viewport_height_px'], 2532);
      expect(
        calls.map((c) => c.method),
        containsAll(['create', 'setParams', 'loadOctree']),
      );
      expect(
        (calls.firstWhere((c) => c.method == 'loadOctree').arguments
            as Map)['octree_dir'],
        oct.path,
      );

      final cams = calls.where((c) => c.method == 'setCamera').toList();
      expect(cams, isNotEmpty);
      final first = cams.last.arguments as Map;
      expect(first['projection'], 1); // orthographic by default
      expect(first['viewport_width_px'], 1170);
      expect(first['viewport_height_px'], 2532);
      final vp0 = Float64List.fromList(
        first['view_proj_row_major'] as Float64List,
      );

      // one-finger drag = orbit
      await tester.dragFrom(const Offset(200, 400), const Offset(80, 30));
      await tester.pump();
      final dragged =
          calls.where((c) => c.method == 'setCamera').last.arguments as Map;
      final vp1 = dragged['view_proj_row_major'] as Float64List;
      var differs = false;
      for (var i = 0; i < 16; i++) {
        if ((vp1[i] - vp0[i]).abs() > 1e-9) differs = true;
      }
      expect(
        differs,
        isTrue,
        reason: 'NEGATIVE: an orbit must change the matrix',
      );
      expect(dragged['viewport_width_px'], 1170);

      await tester.tap(find.text('正交'));
      await tester.pump();
      final toggled =
          calls.where((c) => c.method == 'setCamera').last.arguments as Map;
      expect(toggled['projection'], 0);
      expect(toggled['fov_y_degrees'] as double, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      expect(calls.last.method, 'dispose');
      expect((calls.last.arguments as Map)['textureId'], 5);
    },
  );
}
