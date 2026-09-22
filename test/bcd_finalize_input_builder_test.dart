import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_input_builder.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';

void main() {
  late Directory temporaryDirectory;
  const solvedCenters = <int, List<double>>{
    2: <double>[0, 0, 0],
    3: <double>[1, 0, 0],
    8: <double>[0, 1, 0],
    9: <double>[0.2, 0.3, 1],
  };

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'bcd-finalize-input-',
    );
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  String grayPath(int id, {int byteCount = 80}) {
    final file = File('${temporaryDirectory.path}/frame-$id.gray');
    file.writeAsBytesSync(Uint8List(byteCount), flush: true);
    return file.path;
  }

  List<double> metricCenter(
    List<double> center, {
    double scale = 2,
    List<double> translation = const <double>[3, -1, 0.5],
  }) => <double>[
    scale * center[0] + translation[0],
    scale * center[1] + translation[1],
    scale * center[2] + translation[2],
  ];

  SfmFedFrameMeta meta(
    int id, {
    double scale = 2,
    List<double> translation = const <double>[3, -1, 0.5],
    bool validK = true,
    bool includeMetricCenter = true,
  }) => SfmFedFrameMeta(
    jpegPath: '/capture/photos_highres/frame_$id.jpg',
    imageW: 40,
    imageH: 32,
    grayW: 10,
    grayH: 8,
    fx: validK ? 5 : double.nan,
    fy: validK ? 5.1 : double.nan,
    cx: validK ? 5 : double.nan,
    cy: validK ? 4 : double.nan,
    // For identity solved rotations this makes gravity alignment exactly I.
    arkitQuatWxyz: const <double>[0, 1, 0, 0],
    arkitCameraCenterWorld: includeMetricCenter
        ? metricCenter(
            solvedCenters[id]!,
            scale: scale,
            translation: translation,
          )
        : null,
  );

  List<double> poseRow(int id, {bool registered = true}) {
    final center = solvedCenters[id] ?? const <double>[2, 2, 2];
    return <double>[
      id.toDouble(),
      registered ? 1 : 0,
      1,
      0,
      0,
      0,
      -center[0],
      -center[1],
      -center[2],
    ];
  }

  SfmLiveSnapshot snapshot({
    List<int> order = const <int>[8, 2, 9, 3],
    bool refined = true,
    Float32List? xyz,
    List<int> unregistered = const <int>[],
  }) {
    final poses = <double>[];
    for (final id in order) {
      poses.addAll(poseRow(id, registered: !unregistered.contains(id)));
    }
    final points =
        xyz ?? Float32List.fromList(const <double>[0, 0, 2, 0.5, 0.25, 1]);
    return SfmLiveSnapshot(
      xyz: points,
      rgb: Uint8List(points.length),
      posesPacked: Float64List.fromList(poses),
      summary: const <String, dynamic>{},
      refined: refined,
      obsOffsets: Int32List(points.length ~/ 3 + 1),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
  }

  List<SfmDurableFedFrameInput> durableInputs({
    double scale = 2,
    List<double> translation = const <double>[3, -1, 0.5],
  }) => <SfmDurableFedFrameInput>[
    for (final id in solvedCenters.keys)
      SfmDurableFedFrameInput(
        sequence: id,
        frameId: id,
        grayPath: grayPath(id),
        meta: meta(id, scale: scale, translation: translation),
      ),
  ];

  BcdFinalizeInputBundle buildDefault({SfmLiveSnapshot? source}) =>
      BcdFinalizeInputBuilder.buildFromDurableFedFrames(
        snapshot: source ?? snapshot(),
        durableFedFrames: durableInputs(),
      );

  ({double x, double y}) project(BcdPlaneSweepView view, List<double> point) {
    final p = view.projection3x4;
    final x = p[0] * point[0] + p[1] * point[1] + p[2] * point[2] + p[3];
    final y = p[4] * point[0] + p[5] * point[1] + p[6] * point[2] + p[7];
    final z = p[8] * point[0] + p[9] * point[1] + p[10] * point[2] + p[11];
    return (x: x / z, y: y / z);
  }

  test(
    'builds stable metric solved cameras and never forwards raw AR pose',
    () {
      final source = snapshot(order: const <int>[8, 2, 9, 3]);
      final result = buildDefault(source: source);

      expect(result.registeredFrames.map((frame) => frame.frameId), <int>[
        2,
        3,
        8,
        9,
      ]);
      expect(result.sim3.scale, closeTo(2, 2e-6));
      expect(
        result.sim3.translation,
        closeToList(const <double>[3, -1, 0.5], 2e-6),
      );
      expect(
        result.metricSparseXyz,
        closeToList(<double>[3, -1, 4.5, 4, -0.5, 2.5], 2e-6),
      );
      // Positive-depth t=-C is [-3,1,-.5]. The frame stores C*t because the
      // coordinator converts OpenGL back to the original CV convention.
      expect(
        result.registeredFrames.first.cameraFromWorldTranslation,
        closeToList(const <double>[-3, -1, 0.5], 2e-6),
      );
      expect(
        result.registeredFrames.first.cameraFromWorldQuaternionWxyz,
        closeToList(const <double>[0, 1, 0, 0], 2e-6),
      );
      expect(
        result.metricSolvedPosesPacked.sublist(0, 9),
        closeToList(const <double>[2, 1, 1, 0, 0, 0, -3, 1, -0.5], 2e-6),
      );
    },
  );

  test(
    'Sim3 camera conversion preserves projection of every transformed point',
    () {
      final result = buildDefault();
      final frameId = 3;
      final sourceMeta = meta(frameId);
      final metricView = result.registeredViews.singleWhere(
        (view) => view.jpegPath.endsWith('frame_3.jpg'),
      );
      const rawPoint = <double>[0.2, 0.1, 2];
      final metricPoint = result.sim3.forwardPoint(rawPoint);
      // Independent COLMAP/CV oracle K*[I|-C]*X. It deliberately bypasses the
      // coordinator so a camera-convention error cannot make both sides wrong.
      final fullFx = sourceMeta.fx * sourceMeta.imageW / sourceMeta.grayW;
      final fullFy = sourceMeta.fy * sourceMeta.imageH / sourceMeta.grayH;
      final fullCx = sourceMeta.cx * sourceMeta.imageW / sourceMeta.grayW;
      final fullCy = sourceMeta.cy * sourceMeta.imageH / sourceMeta.grayH;
      final cameraX = rawPoint[0] - 1;
      final cameraY = rawPoint[1];
      final cameraZ = rawPoint[2];
      final before = (
        x: fullFx * cameraX / cameraZ + fullCx,
        y: fullFy * cameraY / cameraZ + fullCy,
      );
      final after = project(metricView, metricPoint);
      expect(after.x, closeTo(before.x, 2e-6));
      expect(after.y, closeTo(before.y, 2e-6));
    },
  );

  test(
    'non-identity gravity SO(3) adds no error beyond Float32 XYZ rounding',
    () {
      // qArk=identity and qSolved=identity gives shared gravity G=C, a 180°
      // rotation about X. This catches any return to rounded-basis recovery.
      final gravityMeta = <int, SfmFedFrameMeta>{
        for (final entry in solvedCenters.entries)
          entry.key: SfmFedFrameMeta(
            jpegPath: '/capture/photos_highres/frame_${entry.key}.jpg',
            imageW: 40,
            imageH: 32,
            grayW: 10,
            grayH: 8,
            fx: 5,
            fy: 5.1,
            cx: 5,
            cy: 4,
            arkitQuatWxyz: const <double>[1, 0, 0, 0],
            arkitCameraCenterWorld: <double>[
              entry.value[0],
              -entry.value[1],
              -entry.value[2],
            ],
          ),
      };
      const rawPoint = <double>[0.234567891, 0.123456789, 2.345678912];
      final deliveredPoint = Float32List.fromList(<double>[
        rawPoint[0],
        -rawPoint[1],
        -rawPoint[2],
      ]);
      final source = snapshot(xyz: deliveredPoint);
      final result = BcdFinalizeInputBuilder.build(
        snapshot: source,
        fedFrameMeta: gravityMeta,
        grayPathByFrameId: <int, String>{
          for (final id in solvedCenters.keys) id: grayPath(id),
        },
      );
      final metricView = result.registeredViews.singleWhere(
        (view) => view.jpegPath.endsWith('frame_3.jpg'),
      );
      final after = project(metricView, result.metricSparseXyz.toList());
      final fullFx = 5 * 40 / 10;
      final fullFy = 5.1 * 32 / 8;
      final fullCx = 5 * 40 / 10;
      final fullCy = 4 * 32 / 8;
      final before = (
        x: fullFx * (rawPoint[0] - 1) / rawPoint[2] + fullCx,
        y: fullFy * rawPoint[1] / rawPoint[2] + fullCy,
      );
      expect(after.x, closeTo(before.x, 1e-5));
      expect(after.y, closeTo(before.y, 1e-5));
      expect(source.xyz, orderedEquals(deliveredPoint));
    },
  );

  test('near-metric cap51-style bridge remains near unit scale', () {
    // Frozen from the real cap51 OFF 105/105-frame fit.
    const translation = <double>[0.061946, 0.036396, 0.001419];
    final result = BcdFinalizeInputBuilder.buildFromDurableFedFrames(
      snapshot: snapshot(),
      durableFedFrames: durableInputs(
        scale: 0.99942811,
        translation: translation,
      ),
    );
    expect(result.sim3.scale, closeTo(0.99942811, 2e-6));
    expect(result.sim3.scale, inInclusiveRange(0.98, 1.02));
    expect(result.sim3.translation, closeToList(translation, 2e-6));
    expect(result.sim3.residuals.maximum, lessThan(2e-6));
  });

  test(
    'metric birth inverse roundtrip preserves birth and original sparse',
    () {
      final source = snapshot();
      final sourceBytes = Uint8List.fromList(source.xyz.buffer.asUint8List());
      final result = buildDefault(source: source);
      final snapshotBirth = Float32List.fromList(const <double>[
        0.25,
        -0.5,
        -1.25,
      ]);
      final metricBirthXyz = result.sim3.forwardPoints(snapshotBirth);
      final metricBirth = BcdPointCloud(
        xyz: metricBirthXyz,
        rgb: Uint8List.fromList(const <int>[7, 8, 9]),
      );
      final restored = result.metricBirthToSnapshot(metricBirth);
      expect(restored.xyz, closeToList(snapshotBirth, 2e-6));
      expect(restored.rgb, orderedEquals(const <int>[7, 8, 9]));
      expect(source.xyz.buffer.asUint8List(), orderedEquals(sourceBytes));
      expect(
        metricBirth.xyz,
        orderedEquals(metricBirthXyz),
        reason: 'inverse conversion must not mutate metric births',
      );
    },
  );

  test('ignores unregistered rows but requires all registered metadata', () {
    final source = snapshot(
      order: const <int>[8, 2, 9, 3, 4],
      unregistered: const <int>[4],
    );
    final result = buildDefault(source: source);
    expect(result.registeredFrames.map((frame) => frame.frameId), <int>[
      2,
      3,
      8,
      9,
    ]);

    final missing = <int, SfmFedFrameMeta>{
      for (final id in <int>[2, 3, 8]) id: meta(id),
    };
    expect(
      () => BcdFinalizeInputBuilder.build(
        snapshot: snapshot(),
        fedFrameMeta: missing,
        grayPathByFrameId: <int, String>{
          for (final id in missing.keys) id: grayPath(id),
        },
      ),
      throwsStateError,
    );
  });

  test('rejects legacy missing K and missing AR metric center', () {
    final missingK = <int, SfmFedFrameMeta>{
      for (final id in solvedCenters.keys) id: meta(id, validK: id != 2),
    };
    expect(
      () => BcdFinalizeInputBuilder.build(
        snapshot: snapshot(),
        fedFrameMeta: missingK,
        grayPathByFrameId: <int, String>{
          for (final id in solvedCenters.keys) id: grayPath(id),
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('intrinsics'),
        ),
      ),
    );

    final missingCenter = <int, SfmFedFrameMeta>{
      for (final id in solvedCenters.keys)
        id: meta(id, includeMetricCenter: id != 2),
    };
    expect(
      () => BcdFinalizeInputBuilder.build(
        snapshot: snapshot(),
        fedFrameMeta: missingCenter,
        grayPathByFrameId: <int, String>{
          for (final id in solvedCenters.keys) id: grayPath(id),
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('metric center'),
        ),
      ),
    );
  });

  test('rejects non-refined snapshots and malformed gray assets', () {
    expect(
      () => BcdFinalizeInputBuilder.buildFromDurableFedFrames(
        snapshot: snapshot(refined: false),
        durableFedFrames: durableInputs(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('refined'),
        ),
      ),
    );

    final inputs = durableInputs();
    inputs[0] = SfmDurableFedFrameInput(
      sequence: inputs[0].sequence,
      frameId: inputs[0].frameId,
      grayPath: grayPath(inputs[0].frameId, byteCount: 79),
      meta: inputs[0].meta,
    );
    expect(
      () => BcdFinalizeInputBuilder.buildFromDurableFedFrames(
        snapshot: snapshot(),
        durableFedFrames: inputs,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('expected 80'),
        ),
      ),
    );
  });

  test(
    'rejects duplicate registered ids and fewer than three correspondences',
    () {
      final duplicatedPoses = <double>[
        ...poseRow(2),
        ...poseRow(2),
        ...poseRow(3),
        ...poseRow(8),
      ];
      final duplicated = SfmLiveSnapshot(
        xyz: Float32List.fromList(const <double>[0, 0, -1]),
        rgb: Uint8List(3),
        posesPacked: Float64List.fromList(duplicatedPoses),
        summary: const <String, dynamic>{},
        refined: true,
        obsOffsets: Int32List(2),
        obsFrameIds: Int32List(0),
        obsXY: Float32List(0),
      );
      expect(
        () => BcdFinalizeInputBuilder.buildFromDurableFedFrames(
          snapshot: duplicated,
          durableFedFrames: durableInputs(),
        ),
        throwsArgumentError,
      );

      expect(
        () => BcdFinalizeInputBuilder.buildFromDurableFedFrames(
          snapshot: snapshot(order: const <int>[2, 3]),
          durableFedFrames: durableInputs(),
        ),
        throwsStateError,
      );
    },
  );
}

Matcher closeToList(List<num> expected, double delta) => predicate<Object?>((
  actual,
) {
  if (actual is! Iterable) return false;
  final values = actual.cast<num>().toList();
  if (values.length != expected.length) return false;
  for (var index = 0; index < values.length; index++) {
    if ((values[index].toDouble() - expected[index].toDouble()).abs() > delta) {
      return false;
    }
  }
  return true;
}, 'numeric list within $delta of $expected');
