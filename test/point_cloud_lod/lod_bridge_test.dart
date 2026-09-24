// Judges for lib/point_cloud_lod/lod_bridge.dart over a mocked `pw_lod_texture` channel.
// Field names are read from the frozen C header, so a key that drifts from the ABI
// fails here. Every checker has a negative control run through the same checker.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

/// Field names of `typedef struct <name> { ... } <name>;` in the frozen header.
List<String> headerFields(String header, String name) {
  final m = RegExp(
    'typedef struct $name \\{(.*?)\\} $name;',
    dotAll: true,
  ).firstMatch(header);
  if (m == null) throw StateError('struct $name not in header');
  final body = m.group(1)!.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = <String>[];
  for (final decl in body.split(';')) {
    final t = decl.trim();
    if (t.isEmpty) continue;
    final id = RegExp(
      r'([A-Za-z_][A-Za-z0-9_]*)\s*(\[[^\]]*\])?\s*$',
    ).firstMatch(t);
    out.add(id!.group(1)!);
  }
  return out;
}

/// The row-major checker: element order AND meaning (a known world point must land on
/// the old viewer's pixel when multiplied row-major).
void expectRowMajorViewProj(
  Object? sent,
  LodCameraFrame f,
  CloudProjection oldViewer,
  Size size,
  List<double> worldPoint,
) {
  expect(sent, isA<Float64List>());
  final v = sent! as Float64List;
  expect(v.length, 16);
  for (var i = 0; i < 16; i++) {
    expect(
      v[i],
      f.viewProjRowMajor[i],
      reason: 'element $i (row ${i ~/ 4}, col ${i % 4})',
    );
  }
  double row(int r) =>
      v[r * 4] * worldPoint[0] +
      v[r * 4 + 1] * worldPoint[1] +
      v[r * 4 + 2] * worldPoint[2] +
      v[r * 4 + 3];
  final w = row(3);
  final sx = size.width / 2 * (1 + row(0) / w);
  final sy = size.height / 2 * (1 - row(1) / w);
  final (ox, oy, _) = oldViewer.project(
    worldPoint[0],
    worldPoint[1],
    worldPoint[2],
  );
  expect((sx - ox).abs(), lessThan(1e-6));
  expect((sy - oy).abs(), lessThan(1e-6));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final header = File(
    'vendor/aether_lod/include/pwlod_viewer.h',
  ).readAsStringSync();
  const channel = MethodChannel(kPwLodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? Function(MethodCall) reply = (_) => null;

  setUp(() {
    calls.clear();
    reply = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('the frozen header is the one this test was written against', () {
    expect(header, contains('#define PWLOD_ABI_VERSION 1'));
    expect(headerFields(header, 'pwlod_camera'), [
      'view_proj_row_major',
      'eye_world',
      'projection',
      'fov_y_degrees',
      'ortho_width_world',
      'ortho_height_world',
      'viewport_width_px',
      'viewport_height_px',
    ]);
    // pwlod_status order = kPwLodStatusNames order
    final statusBody = RegExp(
      r'typedef enum pwlod_status \{(.*?)\}',
      dotAll: true,
    ).firstMatch(header)!.group(1)!;
    final names = RegExp(r'(PWLOD_[A-Z_]+)\s*=\s*(\d+)').allMatches(statusBody);
    for (final n in names) {
      expect(kPwLodStatusNames[int.parse(n.group(2)!)], n.group(1));
    }
    expect(names.length, kPwLodStatusNames.length);
  });

  group('setCamera', () {
    final cam = CloudCamera(
      yaw: 2.1,
      pitch: -0.7,
      roll: 0.3,
      zoom: 1.7,
      panX: 37,
      panY: -22,
      pivotX: 1.5,
      pivotY: -3.25,
      pivotZ: 8,
      radius: 4.5,
      orthographic: true,
    );
    const size = Size(390, 844);
    final frame = lodCameraFrame(
      camera: cam,
      logicalSize: size,
      viewportWidthPx: 1170,
      viewportHeightPx: 2532,
      sceneBoxMin: const [-1.0, -6.0, 4.0],
      sceneBoxMax: const [4.0, -0.5, 12.0],
    );
    final old = cam.projectionFor(size);
    const probe = [2.0, -1.0, 9.5];

    test(
      'keys are exactly pwlod_camera + textureId; row-major 16 doubles; ortho fields',
      () async {
        await LodBridge().setCamera(textureId: 7, camera: frame);
        expect(calls.single.method, 'setCamera');
        final a = calls.single.arguments as Map;
        expect(a.keys.toSet(), {
          'textureId',
          ...headerFields(header, 'pwlod_camera'),
        });
        expect(a['textureId'], 7);
        expectRowMajorViewProj(
          a['view_proj_row_major'],
          frame,
          old,
          size,
          probe,
        );
        expect(a['projection'], 1); // PWLOD_PROJ_ORTHOGRAPHIC
        expect(a['fov_y_degrees'], 0.0);
        expect(a['ortho_width_world'], frame.orthoWidthWorld);
        expect(a['ortho_height_world'], frame.orthoHeightWorld);
        expect(a['ortho_width_world'] as double, greaterThan(0));
        expect(
          (a['ortho_width_world'] as double) /
              (a['ortho_height_world'] as double),
          closeTo(size.width / size.height, 1e-12),
        );
        expect(a['viewport_width_px'], 1170);
        expect(a['viewport_height_px'], 2532);
        final eye = a['eye_world'] as Float64List;
        expect(eye.toList(), frame.eyeWorld.toList());
      },
    );

    test('NEGATIVE: the checker rejects a transposed matrix', () async {
      await LodBridge().setCamera(textureId: 7, camera: frame);
      final sent =
          (calls.single.arguments as Map)['view_proj_row_major'] as Float64List;
      final t = Float64List(16);
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          t[c * 4 + r] = sent[r * 4 + c];
        }
      }
      expect(
        () => expectRowMajorViewProj(t, frame, old, size, probe),
        throwsA(isA<TestFailure>()),
      );
    });

    test('NEGATIVE: the checker rejects any shuffled order', () async {
      await LodBridge().setCamera(textureId: 7, camera: frame);
      final sent =
          (calls.single.arguments as Map)['view_proj_row_major'] as Float64List;
      final rng = math.Random(3);
      for (var trial = 0; trial < 50; trial++) {
        final idx = List<int>.generate(16, (i) => i)..shuffle(rng);
        if (List.generate(16, (i) => idx[i] == i).every((b) => b)) continue;
        final shuffled = Float64List.fromList([for (final i in idx) sent[i]]);
        expect(
          () => expectRowMajorViewProj(shuffled, frame, old, size, probe),
          throwsA(isA<TestFailure>()),
          reason: 'order $idx slipped through',
        );
      }
      // Even a single swap of two elements is caught.
      final swapped = Float64List.fromList(sent)
        ..[3] = sent[12]
        ..[12] = sent[3];
      expect(
        () => expectRowMajorViewProj(swapped, frame, old, size, probe),
        throwsA(isA<TestFailure>()),
      );
    });

    test(
      'perspective switch travels as PWLOD_PROJ_PERSPECTIVE with fov, no ortho size',
      () async {
        final persp = lodCameraFrame(
          camera: CloudCamera(
            yaw: 2.1,
            pitch: -0.7,
            zoom: 1.7,
            panX: 37,
            panY: -22,
            pivotX: 1.5,
            pivotY: -3.25,
            pivotZ: 8,
            radius: 4.5,
          ),
          logicalSize: size,
          viewportWidthPx: 1170,
          viewportHeightPx: 2532,
          sceneBoxMin: const [-1.0, -6.0, 4.0],
          sceneBoxMax: const [4.0, -0.5, 12.0],
        );
        await LodBridge().setCamera(textureId: 7, camera: persp);
        final a = calls.single.arguments as Map;
        expect(a['projection'], 0);
        expect(a['fov_y_degrees'] as double, greaterThan(0));
        expect(a['ortho_width_world'], 0.0);
        // and the matrix really is a different one
        expect(
          () => expectRowMajorViewProj(
            a['view_proj_row_major'],
            frame,
            old,
            size,
            probe,
          ),
          throwsA(isA<TestFailure>()),
        );
      },
    );

    test('non-finite matrix is refused before it reaches the channel', () {
      final bad = LodCameraFrame(
        viewProjRowMajor: Float64List(16)..[5] = double.nan,
        eyeWorld: Float64List(3),
        projection: LodProjection.orthographic,
        fovYDegrees: 0,
        orthoWidthWorld: 1,
        orthoHeightWorld: 1,
        viewportWidthPx: 1,
        viewportHeightPx: 1,
        near: 0.1,
        far: 1,
      );
      expect(() => LodBridge.cameraToWire(1, bad), throwsArgumentError);
    });
  });

  group('setParams', () {
    test('full params use exactly the pwlod_params field names', () async {
      await LodBridge().setParams(
        textureId: 3,
        params: const LodParams(
          pointBudget: 3630000,
          targetFrameMs: 33.333,
          pointSizeMode: 1,
          asyncLoading: true,
          cacheBytes: 15 * 3630000,
          backgroundRgba: [0, 0, 0, 1],
          debugRenderSleepMs: 50,
          debugPublishBeforeDone: false,
        ),
      );
      final a = calls.single.arguments as Map;
      expect(a.keys.toSet(), {
        'textureId',
        ...headerFields(header, 'pwlod_params'),
      });
      expect(a['async_loading'], 1);
      expect(a['debug_publish_before_done'], 0);
      expect((a['background_rgba'] as Float64List).length, 4);
    });

    test(
      'partial params send only the set keys (native merges over defaults)',
      () async {
        await LodBridge().setParams(
          textureId: 3,
          params: const LodParams(pointBudget: 5),
        );
        final a = calls.single.arguments as Map;
        expect(a.keys.toSet(), {'textureId', 'point_budget'});
      },
    );

    test('NEGATIVE: a misspelt key would not be a header field', () {
      final fields = headerFields(header, 'pwlod_params').toSet();
      expect(fields.contains('point_budgt'), isFalse);
      expect(fields.contains('point_budget'), isTrue);
    });
  });

  group('decoders cover every header field', () {
    Map<String, Object> wireFor(
      String struct, {
      Set<String> doubles = const {},
    }) {
      var i = 1;
      return {
        for (final f in headerFields(header, struct))
          f: doubles.contains(f) ? (i++) + 0.5 : i++,
      };
    }

    test(
      'stats: all pwlod_frame_stats fields decoded; null before first frame',
      () async {
        final w = wireFor(
          'pwlod_frame_stats',
          doubles: {'min_node_pixel_size', 'cpu_ms', 'gpu_ms'},
        );
        reply = (c) => c.method == 'stats' ? w : null;
        final s = (await LodBridge().stats(textureId: 1))!;
        expect(
          [
            s.frameNumber,
            s.completedFrameNumber,
            s.pointsDrawn,
            s.nodesDrawn,
            s.nodesLoading,
            s.uploadsThisFrame,
            s.droppedForCache,
            s.minNodePixelSize,
            s.cpuMs,
            s.gpuMs,
          ],
          [for (final f in headerFields(header, 'pwlod_frame_stats')) w[f]],
        );
        reply = (_) => null;
        expect(await LodBridge().stats(textureId: 1), isNull);
      },
    );

    test(
      'NEGATIVE: a stats map missing one header field is rejected',
      () async {
        for (final drop in headerFields(header, 'pwlod_frame_stats')) {
          final w = wireFor('pwlod_frame_stats')..remove(drop);
          reply = (_) => w;
          await expectLater(
            LodBridge().stats(textureId: 1),
            throwsFormatException,
            reason: 'dropping $drop went unnoticed',
          );
        }
      },
    );

    test('build / verify reports round-trip every header field', () async {
      final b = {
        ...wireFor('pwlod_build_report', doubles: {'elapsed_ms'}),
        'status': 'PWLOD_OK',
        'error': '',
        'shell_wall_ms': 1.0,
        'peak_footprint_mb': 2.0,
        'baseline_footprint_mb': 1.0,
        'footprint_samples': 9,
        'chunk_dir_removed': true,
      };
      reply = (_) => b;
      final r = await LodBridge().buildFromPly(
        plyPath: '/p.ply',
        outDir: '/o',
        chunkDir: '/c',
      );
      for (final f in headerFields(header, 'pwlod_build_report')) {
        expect(r.toJson()[f], b[f], reason: f);
      }
      final a = calls.single.arguments as Map;
      expect(a.keys.toSet(), {
        'ply_path',
        'out_dir',
        'chunk_dir',
        'memory_budget_mb',
        'threads',
      });

      final v = {...wireFor('pwlod_verify_report'), 'status': 'PWLOD_OK'};
      reply = (_) => v;
      final vr = await LodBridge().verifyOctree(octreeDir: '/o');
      for (final f in headerFields(header, 'pwlod_verify_report')) {
        expect(vr.toJson()[f], v[f], reason: f);
      }
    });
  });

  group('C1 / C2 / S2 judges', () {
    LodBuildReport build({
      String status = 'PWLOD_OK',
      int ply = 36232793,
      int tree = 36232793,
      int? bytes,
      int nodes = 12000,
    }) => LodBuildReport(
      status: status,
      error: '',
      plyPoints: ply,
      treePoints: tree,
      octreeBinBytes: bytes ?? 18 * tree,
      nodes: nodes,
      elapsedMs: 1,
      shellWallMs: 1,
      peakFootprintMb: 1,
      baselineFootprintMb: 1,
      footprintSamples: 1,
      chunkDirRemoved: true,
    );
    LodVerifyReport verify({
      int tree = 36232793,
      int? bytes,
      int nodes = 12000,
      int leaves = 9000,
      int? selected,
      int gaps = 0,
      int overlaps = 0,
    }) => LodVerifyReport(
      status: 'PWLOD_OK',
      treePoints: tree,
      octreeBinBytes: bytes ?? 18 * tree,
      nodes: nodes,
      leaves: leaves,
      leavesSelected: selected ?? leaves,
      byteGaps: gaps,
      byteOverlaps: overlaps,
    );

    test('C1 passes only when tree == ply and bytes == 18 * tree', () {
      expect(judgeC1(build()).pass, isTrue);
      // NEGATIVE controls
      expect(judgeC1(build(tree: 36232792)).pass, isFalse); // one point lost
      expect(
        judgeC1(build(bytes: 18 * 36232793 + 18)).pass,
        isFalse,
      ); // one extra record
      expect(
        judgeC1(build(bytes: 18 * 36232793 - 1)).pass,
        isFalse,
      ); // truncated
      expect(judgeC1(build(status: 'PWLOD_ERR_FORMAT')).pass, isFalse);
      expect(
        judgeC1(build(ply: 0, tree: 0)).pass,
        isFalse,
      ); // empty is not a pass
    });

    test('C2 / S2 / build==verify, each with its negative control', () {
      expect(
        judgeVerify(verify(), build: build()).every((c) => c.pass),
        isTrue,
      );
      expect(
        judgeVerify(verify(gaps: 1)).firstWhere((c) => c.name == 'C2').pass,
        isFalse,
      );
      expect(
        judgeVerify(
          verify(overlaps: 18),
        ).firstWhere((c) => c.name == 'C2').pass,
        isFalse,
      );
      expect(
        judgeVerify(
          verify(selected: 8999),
        ).firstWhere((c) => c.name == 'S2').pass,
        isFalse,
      );
      expect(
        judgeVerify(
          verify(leaves: 0, selected: 0),
        ).firstWhere((c) => c.name == 'S2').pass,
        isFalse,
      );
      expect(
        judgeVerify(
          verify(nodes: 11999),
          build: build(),
        ).firstWhere((c) => c.name == 'build==verify').pass,
        isFalse,
      );
    });
  });

  test('create / dispose / runBench / launchArgs marshal and decode', () async {
    reply = (c) {
      switch (c.method) {
        case 'create':
          return {
            'textureId': 42,
            'version': 'deadbeef abi=1',
            'backend': 5,
            'viewport_width_px': 1170,
            'viewport_height_px': 2532,
          };
        case 'runBench':
          return {
            'result': '/docs/lod_bench/x/lod.json',
            'result_is_file': true,
            'wall_ms': 12.5,
            'probe_start': {
              'thermal_state': 0,
              'footprint_mb': 100.0,
              'avail_mb': 2000.0,
            },
            'probe_end': {
              'thermal_state': 1,
              'footprint_mb': 300.0,
              'avail_mb': 1800.0,
            },
            'version': 'deadbeef abi=1',
          };
        case 'launchArgs':
          return {'PWLodCapture': 'scan1', 'bogus': 3};
      }
      return null;
    };
    final bridge = LodBridge();
    final info = await bridge.create(widthPx: 1170, heightPx: 2532);
    expect(info.textureId, 42);
    expect(calls.last.arguments, {
      'viewport_width_px': 1170,
      'viewport_height_px': 2532,
    });
    await bridge.loadOctree(textureId: 42, octreeDir: '/o');
    expect(calls.last.arguments, {'textureId': 42, 'octree_dir': '/o'});
    final r = await bridge.runBench(
      octreeDir: '/o',
      outDir: '/r',
      args: 'mode=perf',
    );
    expect(r.resultIsFile, isTrue);
    expect(r.probeEnd['thermal_state'], 1);
    expect(await bridge.launchArgs(), {'PWLodCapture': 'scan1'});
    await bridge.dispose(textureId: 42);
    expect(calls.last.method, 'dispose');
    expect(() => bridge.create(widthPx: 0, heightPx: 1), throwsArgumentError);
  });
}
