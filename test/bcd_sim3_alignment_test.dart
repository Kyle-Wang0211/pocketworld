import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_sim3_alignment.dart';
import 'package:pocketworld_flutter/capture/gravity_align.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';

void main() {
  const scale = 2.25;
  const angle = math.pi / 6;
  final rotation = <double>[
    math.cos(angle),
    -math.sin(angle),
    0,
    math.sin(angle),
    math.cos(angle),
    0,
    0,
    0,
    1,
  ];
  const translation = <double>[3.5, -1.25, 0.75];
  final centers = <List<double>>[
    <double>[0, 0, 0],
    <double>[1, 0, 0],
    <double>[0, 2, 0],
    <double>[0.5, 0.25, 1],
    <double>[-1, 0.75, 0.4],
    <double>[1.2, -0.4, 0.7],
  ];

  List<double> apply(List<double> point) {
    final r = <double>[
      rotation[0] * point[0] + rotation[1] * point[1] + rotation[2] * point[2],
      rotation[3] * point[0] + rotation[4] * point[1] + rotation[5] * point[2],
      rotation[6] * point[0] + rotation[7] * point[1] + rotation[8] * point[2],
    ];
    return <double>[
      scale * r[0] + translation[0],
      scale * r[1] + translation[1],
      scale * r[2] + translation[2],
    ];
  }

  Float64List posesFor(List<List<double>> values) {
    final packed = <double>[];
    for (var index = 0; index < values.length; index++) {
      final c = values[index];
      // Identity CamFromWorld: t = -cameraCenter.
      packed.addAll(<double>[index + 10, 1, 1, 0, 0, 0, -c[0], -c[1], -c[2]]);
    }
    return Float64List.fromList(packed);
  }

  SfmFedFrameMeta meta(List<double> target) => SfmFedFrameMeta(
    jpegPath: '/unused.jpg',
    imageW: 10,
    imageH: 10,
    grayW: 10,
    grayH: 10,
    fx: 5,
    fy: 5,
    cx: 5,
    cy: 5,
    // With COLMAP q=identity, qArk=C makes gravityAlignedPoints' R_w=I.
    arkitQuatWxyz: const <double>[0, 1, 0, 0],
    arkitTransTxyz: const <double>[0, 0, 0],
    arkitCameraCenterWorld: target,
  );

  Map<int, SfmFedFrameMeta> metadataFor(List<List<double>> targets) =>
      <int, SfmFedFrameMeta>{
        for (var index = 0; index < targets.length; index++)
          index + 10: meta(targets[index]),
      };

  test('shared exact gravity rotation preserves Float32 snapshot bytes', () {
    final half = math.sqrt(0.5);
    final poses = Float64List.fromList(<double>[
      for (var id = 0; id < 3; id++) ...<double>[
        id.toDouble(),
        1,
        half,
        0,
        half,
        0,
        0,
        0,
        0,
      ],
    ]);
    final xyz = Float32List.fromList(const <double>[
      0.123456789,
      -2.34567891,
      4.56789123,
      -7.7777777,
      0.000013579,
      9.9999991,
    ]);
    const qArk = <double>[0.9238795325112867, 0, 0, 0.3826834323650898];

    final exact = gravityAlignmentRotationRowMajor(
      posesPacked: poses,
      arkitQuatWxyzOf: (_) => qArk,
    );
    final legacy = gravityAlignedPoints(
      xyz: xyz,
      posesPacked: poses,
      arkitQuatWxyzOf: (_) => qArk,
    );
    expect(exact, isNotNull);
    expect(legacy, isNotNull);
    final exactRotation = exact!;
    final fromExact = Float32List(xyz.length);
    for (var offset = 0; offset < xyz.length; offset += 3) {
      final rotated = _rotate3(exactRotation, <double>[
        xyz[offset],
        xyz[offset + 1],
        xyz[offset + 2],
      ]);
      fromExact.setRange(offset, offset + 3, rotated);
    }
    expect(
      fromExact.buffer.asUint8List(),
      orderedEquals(legacy!.buffer.asUint8List()),
      reason: 'extracting exact G must not change snapshot Float32 bytes',
    );
    _expectStrictSo3(exactRotation);
  });

  test('recovers a known metric Sim(3) from solved camera centres', () {
    final targets = centers.map(apply).toList();
    final result = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: posesFor(centers),
      fedFrameMeta: metadataFor(targets),
    );

    expect(result.scale, closeTo(scale, 2e-6));
    for (var i = 0; i < 9; i++) {
      expect(result.rotation[i], closeTo(rotation[i], 2e-6));
    }
    for (var i = 0; i < 3; i++) {
      expect(result.translation[i], closeTo(translation[i], 2e-6));
    }
    expect(result.pairedFrameIds, <int>[10, 11, 12, 13, 14, 15]);
    expect(result.residuals.pairCount, 6);
    expect(result.residuals.inlierCount, 6);
    expect(result.residuals.maximum, lessThan(2e-6));
  });

  test('derives camera centres by inverting non-identity CamFromWorld', () {
    final half = math.sqrt(0.5);
    final packed = <double>[];
    final metadata = <int, SfmFedFrameMeta>{};
    for (var index = 0; index < centers.length; index++) {
      final c = centers[index];
      // R_col = +90 degrees around Z; t = -R_col * cameraCenter.
      packed.addAll(<double>[
        index + 10,
        1,
        half,
        0,
        0,
        half,
        c[1],
        -c[0],
        -c[2],
      ]);
      metadata[index + 10] = SfmFedFrameMeta(
        jpegPath: '/unused.jpg',
        imageW: 10,
        imageH: 10,
        grayW: 10,
        grayH: 10,
        fx: 5,
        fy: 5,
        cx: 5,
        cy: 5,
        // qArk = qC * qCol, hence gravityAlignedPoints' R_w remains I.
        arkitQuatWxyz: <double>[0, half, -half, 0],
        arkitTransTxyz: const <double>[0, 0, 0],
        arkitCameraCenterWorld: apply(c),
      );
    }

    final result = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: Float64List.fromList(packed),
      fedFrameMeta: metadata,
    );

    expect(result.scale, closeTo(scale, 2e-6));
    for (var i = 0; i < 9; i++) {
      expect(result.rotation[i], closeTo(rotation[i], 2e-6));
    }
    expect(result.residuals.maximum, lessThan(2e-6));
  });

  test('deterministically rejects a gross AR-centre outlier', () {
    final targets = centers.map(apply).toList();
    targets[4] = <double>[100, -80, 60];

    final result = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: posesFor(centers),
      fedFrameMeta: metadataFor(targets),
    );

    expect(result.scale, closeTo(scale, 2e-6));
    expect(result.residuals.inlierCount, 5);
    expect(result.residuals.rejectedCount, 1);
    expect(result.residuals.median, lessThan(2e-6));
    expect(result.residuals.maximum, greaterThan(100));
  });

  test('bounded hypotheses cover a long trajectory with early outliers', () {
    final longCenters = <List<double>>[
      for (var index = 0; index < 40; index++)
        <double>[
          (index % 8) * 0.31,
          (index ~/ 8) * 0.27,
          (index % 5) * 0.11 + (index ~/ 9) * 0.03,
        ],
    ];
    final targets = longCenters.map(apply).toList();
    for (var index = 0; index < 6; index++) {
      targets[index] = <double>[
        80 + index * 11,
        -90 + index * 7,
        50 - index * 5,
      ];
    }

    final result = const BcdSim3AlignmentEstimator(maximumHypotheses: 128)
        .estimate(
          posesPacked: posesFor(longCenters),
          fedFrameMeta: metadataFor(targets),
        );

    expect(result.scale, closeTo(scale, 2e-6));
    expect(result.residuals.inlierCount, 34);
    expect(result.residuals.rejectedCount, 6);
    expect(result.residuals.median, lessThan(2e-6));
  });

  test(
    '120 exact camera pairs beat the snapshot Float32 quantization floor',
    () {
      final random = math.Random(0x51a3);
      final qGravity = _axisAngleQuaternion(0.31, -0.72, 0.55, 1.137);
      const qConvention = <double>[0, 1, 0, 0];
      final qCol = _qmul(qConvention, qGravity);
      final rCol = _quaternionRotation(qCol);
      final gravity = _quaternionRotation(qGravity);
      final packed = <double>[];
      final metadata = <int, SfmFedFrameMeta>{};
      var float32QuantizationFloor = 0.0;

      for (var index = 0; index < 120; index++) {
        final center = <double>[
          random.nextDouble() * 12.0 - 6.0 + index * 1e-9,
          random.nextDouble() * 4.0 - 2.0 - index * 3e-10,
          random.nextDouble() * 9.0 - 4.5 + index * 7e-10,
        ];
        final rc = _rotate3(rCol, center);
        packed.addAll(<double>[index + 10, 1, ...qCol, -rc[0], -rc[1], -rc[2]]);
        final gravityCenter = _rotate3(gravity, center);
        metadata[index + 10] = SfmFedFrameMeta(
          jpegPath: '/unused.jpg',
          imageW: 10,
          imageH: 10,
          grayW: 10,
          grayH: 10,
          fx: 5,
          fy: 5,
          cx: 5,
          cy: 5,
          arkitQuatWxyz: const <double>[1, 0, 0, 0],
          arkitTransTxyz: const <double>[0, 0, 0],
          arkitCameraCenterWorld: apply(gravityCenter),
        );

        final quantized = Float32List.fromList(center);
        final quantizedGravity = _rotate3(gravity, quantized);
        float32QuantizationFloor = math.max(
          float32QuantizationFloor,
          _distance3(gravityCenter, quantizedGravity),
        );
      }

      final result = const BcdSim3AlignmentEstimator().estimate(
        posesPacked: Float64List.fromList(packed),
        fedFrameMeta: metadata,
      );

      expect(float32QuantizationFloor, greaterThan(1e-8));
      expect(result.residuals.pairCount, 120);
      expect(result.residuals.inlierCount, 120);
      expect(result.residuals.maximum, lessThan(1e-12));
      expect(result.scale, closeTo(scale, 1e-13));
    },
  );

  test(
    '1000-frame solve stays hypothesis-bounded and below the time guard',
    () {
      final largeCenters = <List<double>>[
        for (var index = 0; index < 1000; index++)
          <double>[
            (index % 40) * 0.071 + (index ~/ 400) * 0.0031,
            ((index ~/ 40) % 25) * 0.083 + (index % 7) * 0.0009,
            math.sin(index * 0.031) * 0.47 + (index % 13) * 0.012,
          ],
      ];
      final stopwatch = Stopwatch()..start();
      final result = const BcdSim3AlignmentEstimator().estimate(
        posesPacked: posesFor(largeCenters),
        fedFrameMeta: metadataFor(largeCenters.map(apply).toList()),
      );
      stopwatch.stop();

      expect(result.residuals.pairCount, 1000);
      expect(result.residuals.hypothesisCount, 128);
      expect(result.residuals.maximum, lessThan(2e-12));
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(2000),
        reason:
            '1000 frames must remain bounded; cubic triples would hang here',
      );
    },
  );

  test('the product hypothesis budget cannot exceed its hard cap', () {
    expect(
      () => const BcdSim3AlignmentEstimator(maximumHypotheses: 129).estimate(
        posesPacked: posesFor(centers),
        fedFrameMeta: metadataFor(centers.map(apply).toList()),
      ),
      throwsArgumentError,
    );
  });

  test('200 deterministic rounds retain a 30 percent outlier budget', () {
    final random = math.Random(0x720200);
    for (var round = 0; round < 200; round++) {
      final roundCenters = <List<double>>[
        for (var index = 0; index < 30; index++)
          <double>[
            (index % 6) * 0.23 + random.nextDouble() * 0.007,
            (index ~/ 6) * 0.19 + random.nextDouble() * 0.007,
            math.sin(index * 0.51 + round * 0.01) * 0.21 +
                random.nextDouble() * 0.004,
          ],
      ];
      final targets = roundCenters.map(apply).toList();
      final order = List<int>.generate(30, (index) => index)..shuffle(random);
      for (final index in order.take(9)) {
        targets[index] = <double>[
          random.nextDouble() * 100 + 30,
          random.nextDouble() * -90 - 20,
          random.nextDouble() * 80 + 10,
        ];
      }

      final result = const BcdSim3AlignmentEstimator().estimate(
        posesPacked: posesFor(roundCenters),
        fedFrameMeta: metadataFor(targets),
      );
      expect(result.residuals.hypothesisCount, 128);
      expect(result.scale, closeTo(scale, 3e-6), reason: 'round=$round');
      expect(result.residuals.inlierCount, 21, reason: 'round=$round');
      expect(result.residuals.median, lessThan(3e-6), reason: 'round=$round');
    }
  });

  test('fails closed for collinear or insufficient paired centres', () {
    final collinear = <List<double>>[
      <double>[0, 0, 0],
      <double>[1, 0, 0],
      <double>[2, 0, 0],
      <double>[3, 0, 0],
    ];
    expect(
      () => const BcdSim3AlignmentEstimator().estimate(
        posesPacked: posesFor(collinear),
        fedFrameMeta: metadataFor(collinear.map(apply).toList()),
      ),
      throwsStateError,
    );

    final metadata = metadataFor(centers.map(apply).toList())..remove(12);
    metadata.remove(13);
    metadata.remove(14);
    metadata.remove(15);
    expect(
      () => const BcdSim3AlignmentEstimator().estimate(
        posesPacked: posesFor(centers),
        fedFrameMeta: metadata,
      ),
      throwsStateError,
    );
  });

  test('point roundtrip and inverse birth preserve all source bytes', () {
    final result = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: posesFor(centers),
      fedFrameMeta: metadataFor(centers.map(apply).toList()),
    );
    final sparse = Float32List.fromList(const <double>[
      1.25,
      -2.5,
      3.75,
      -4.5,
      5.25,
      0.125,
    ]);
    final sparseBefore = Uint8List.fromList(
      sparse.buffer.asUint8List(sparse.offsetInBytes, sparse.lengthInBytes),
    );
    final ar = result.forwardPoints(sparse);
    final roundtrip = result.inversePoints(ar);
    for (var i = 0; i < sparse.length; i++) {
      expect(roundtrip[i], closeTo(sparse[i], 2e-6));
    }
    expect(
      sparse.buffer.asUint8List(sparse.offsetInBytes, sparse.lengthInBytes),
      orderedEquals(sparseBefore),
    );

    final birthRgb = Uint8List.fromList(const <int>[9, 8, 7, 6, 5, 4]);
    final birth = BcdPointCloud(xyz: ar, rgb: birthRgb);
    final arBefore = Uint8List.fromList(
      ar.buffer.asUint8List(ar.offsetInBytes, ar.lengthInBytes),
    );
    final rgbBefore = Uint8List.fromList(birthRgb);
    final inverseBirth = result.inverseBirthCloud(birth);
    for (var i = 0; i < sparse.length; i++) {
      expect(inverseBirth.xyz[i], closeTo(sparse[i], 2e-6));
    }
    expect(inverseBirth.rgb, orderedEquals(rgbBefore));
    expect(ar.buffer.asUint8List(ar.offsetInBytes, ar.lengthInBytes), arBefore);
    expect(birthRgb, rgbBefore);

    // Append-only publication retains the exact original sparse byte prefix.
    final mergedXyz = Float32List(sparse.length + inverseBirth.xyz.length)
      ..setRange(0, sparse.length, sparse)
      ..setRange(
        sparse.length,
        sparse.length + inverseBirth.xyz.length,
        inverseBirth.xyz,
      );
    expect(
      mergedXyz.buffer.asUint8List(0, sparse.lengthInBytes),
      orderedEquals(sparseBefore),
    );
  });

  test('forward metric transforms fail closed on every non-finite value', () {
    final result = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: posesFor(centers),
      fedFrameMeta: metadataFor(centers.map(apply).toList()),
    );

    expect(
      () => result.forwardPoint(<double>[double.maxFinite, 1, 2]),
      throwsStateError,
    );
    expect(
      () => result.forwardPoint(<double>[double.nan, 1, 2]),
      throwsArgumentError,
    );
    final finiteDoubleButOverflowingFloat = Float32List(3)
      ..[0] = 3.3e38
      ..[1] = 1
      ..[2] = 2;
    expect(
      () => result.forwardPoints(finiteDoubleButOverflowingFloat),
      throwsStateError,
    );
  });
}

List<double> _qmul(List<double> a, List<double> b) => <double>[
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];

List<double> _axisAngleQuaternion(double x, double y, double z, double angle) {
  final axisNorm = math.sqrt(x * x + y * y + z * z);
  final half = angle / 2;
  final sine = math.sin(half) / axisNorm;
  return <double>[math.cos(half), x * sine, y * sine, z * sine];
}

List<double> _quaternionRotation(List<double> q) {
  final n = math.sqrt(q.fold<double>(0, (sum, v) => sum + v * v));
  final w = q[0] / n, x = q[1] / n, y = q[2] / n, z = q[3] / n;
  return <double>[
    1 - 2 * (y * y + z * z),
    2 * (x * y - z * w),
    2 * (x * z + y * w),
    2 * (x * y + z * w),
    1 - 2 * (x * x + z * z),
    2 * (y * z - x * w),
    2 * (x * z - y * w),
    2 * (y * z + x * w),
    1 - 2 * (x * x + y * y),
  ];
}

List<double> _rotate3(List<double> rotation, List<double> point) => <double>[
  rotation[0] * point[0] + rotation[1] * point[1] + rotation[2] * point[2],
  rotation[3] * point[0] + rotation[4] * point[1] + rotation[5] * point[2],
  rotation[6] * point[0] + rotation[7] * point[1] + rotation[8] * point[2],
];

double _distance3(List<double> a, List<double> b) {
  final dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
  return math.sqrt(dx * dx + dy * dy + dz * dz);
}

void _expectStrictSo3(List<double> rotation) {
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 3; column++) {
      var dot = 0.0;
      for (var axis = 0; axis < 3; axis++) {
        dot += rotation[row * 3 + axis] * rotation[column * 3 + axis];
      }
      expect(dot, closeTo(row == column ? 1 : 0, 1e-14));
    }
  }
  final determinant =
      rotation[0] * (rotation[4] * rotation[8] - rotation[5] * rotation[7]) -
      rotation[1] * (rotation[3] * rotation[8] - rotation[5] * rotation[6]) +
      rotation[2] * (rotation[3] * rotation[7] - rotation[4] * rotation[6]);
  expect(determinant, closeTo(1, 1e-14));
}
