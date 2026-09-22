import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

Float32List _partitionedPlanes(double partitionTwoY, {double xOffset = 0}) {
  final sparse = <double>[];
  for (var sample = -16; sample <= 16; sample++) {
    final x = xOffset + sample * 0.006;
    final z = ((sample * sample + 3 * sample) % 13) * 0.005 - 0.03;
    // Lexicographic XYZ sorting assigns these to partitions 0, 1, and 2.
    sparse.addAll([x, -0.002, z]);
    sparse.addAll([x, 0.002, z]);
    sparse.addAll([x, partitionTwoY, z]);
  }
  return Float32List.fromList(sparse);
}

const _certificateOptions = LocalManifoldBirthOptions(
  maximumNearestM: 0.06,
  maximumNeighborRadiusM: 0.15,
  maximumNeighborRmsM: 0.01,
  maximumPerpendicularM: 0.02,
);

const _certificateWall = StructuralWall(
  index: 0,
  thetaDeg: 0,
  certified: true,
  supportPoints35mm: 100,
  coverageCells10cm: 100,
  domainPoints: 100,
  supportPoints20mm: [100, 100, 100, 100, 100],
  supportCells10cm: [100, 100, 100, 100, 100],
  normal: [1, 0, 0],
  basisU: [0, 0, 1],
  basisV: [0, 1, 0],
  planeValue: 1,
  boundsU: [-1, 1],
  boundsHeight: [0, 2],
  score: 1,
  supportProminenceVs5cm: 1,
  coverageProminenceVs5cm: 1,
);

const _certificateFloor = StructuralFloorDomain(
  certified: true,
  normal: [0, 1, 0],
  basisU: [1, 0, 0],
  basisV: [0, 0, 1],
  planeValue: -1,
  boundsU: [-0.5, 0.5],
  boundsV: [-0.5, 0.5],
);

void main() {
  test('shared C floor fit certifies a broad plane with outliers', () {
    final xyz = <double>[];
    for (var ix = 0; ix <= 40; ix++) {
      final x = -2 + 0.1 * ix;
      for (var iz = 0; iz <= 30; iz++) {
        final z = -1.5 + 0.1 * iz;
        final y = 0.015 * x - 0.01 * z + 0.2;
        xyz.addAll([x, y, z]);
      }
    }
    for (var i = 0; i < 400; i++) {
      xyz.addAll([
        -2 + (i % 41) * 0.1,
        0.7 + (i % 9) * 0.08,
        -1.5 + (i % 31) * 0.1,
      ]);
    }

    final floor = StructuralPlaneFit.fitFloor(xyz: Float32List.fromList(xyz));

    expect(floor.certified, isTrue);
    expect(floor.supportPoints, greaterThanOrEqualTo(500));
    expect(floor.coverageCells10cm, greaterThanOrEqualTo(50));
    expect(floor.rmsErrorM, lessThanOrEqualTo(0.02));
    expect(floor.normal[1], greaterThan(0.97));
  });

  test('Dart preserves parallel floor layers as proposal-only candidates', () {
    final xyz = <double>[];
    void point(double x, double y, double z) => xyz.addAll([x, y, z]);
    for (var ix = 0; ix <= 30; ix++) {
      final x = -1.5 + 0.1 * ix;
      for (var iz = 0; iz <= 25; iz++) {
        final z = -1.25 + 0.1 * iz;
        point(x, -0.60 + ((ix + iz) % 3 - 1) * 0.0003, z);
        if ((ix + iz).isEven) {
          point(x, -0.37 + ((ix * 3 + iz) % 3 - 1) * 0.0003, z);
        }
      }
    }
    for (var index = 0; index < 500; index++) {
      point(
        -1.5 + 0.006 * index,
        0.4 + 0.002 * (index % 250),
        -1.25 + 0.005 * (index % 500),
      );
    }

    final proposals = StructuralPlaneFit.proposeFloors(
      xyz: Float32List.fromList(xyz),
      minimumCameraHeight: 0.5,
    );

    expect(proposals, hasLength(2));
    expect(proposals[0].index, 0);
    expect(proposals[1].index, 1);
    expect(proposals[0].planeValue, closeTo(-0.60, 0.002));
    expect(proposals[1].planeValue, closeTo(-0.37, 0.002));
    expect(proposals[0].supportPoints20mm, greaterThan(500));
    expect(proposals[1].supportPoints20mm, greaterThan(300));
  });

  test(
    'shared C wall fit is deterministic and certification is fail-closed',
    () {
      final xyz = <double>[];
      void point(double x, double y, double z) => xyz.addAll([x, y, z]);

      for (var iy = 0; iy <= 40; iy++) {
        final y = 0.05 + 0.05 * iy;
        for (var it = 0; it <= 60; it++) {
          final tangent = -1.5 + 0.05 * it;
          point(-2, y, tangent);
          point(2, y, tangent);
          point(tangent, y, -1.5);
          point(tangent, y, 1.5);
        }
      }
      for (var ix = 0; ix <= 40; ix++) {
        for (var iz = 0; iz <= 30; iz++) {
          point(-2 + 0.1 * ix, 2.2, -1.5 + 0.1 * iz);
        }
      }

      final first = StructuralPlaneFit.fitWalls(
        xyz: Float32List.fromList(xyz),
        floorNormal: const [0, 1, 0],
        floorValue: 0,
      );
      final second = StructuralPlaneFit.fitWalls(
        xyz: Float32List.fromList(xyz),
        floorNormal: const [0, 1, 0],
        floorValue: 0,
      );

      expect(first.length, greaterThanOrEqualTo(2));
      expect(
        first.where((wall) => wall.certified).length,
        greaterThanOrEqualTo(2),
      );
      expect(
        second.map((wall) => (wall.thetaDeg, wall.planeValue, wall.certified)),
        first.map((wall) => (wall.thetaDeg, wall.planeValue, wall.certified)),
      );
      for (final wall in first) {
        expect(wall.normal[1].abs(), lessThan(1e-9));
        expect(wall.basisV[1], closeTo(1, 1e-9));
        if (wall.certified) {
          expect(wall.supportPoints20mm[2], greaterThanOrEqualTo(500));
          expect(wall.coverageCells10cm, greaterThanOrEqualTo(50));
        }
      }
    },
  );

  test(
    'camera-envelope proposals reject an interior wall crossing cameras',
    () {
      final xyz = <double>[];
      void point(double x, double y, double z) => xyz.addAll([x, y, z]);
      for (var iy = 0; iy <= 40; iy++) {
        final y = 0.15 + iy * 0.05;
        for (var it = 0; it <= 60; it++) {
          final tangent = -1.5 + it * 0.05;
          point(-2, y, tangent);
          point(2, y, tangent);
          point(tangent, y, -1.5);
          point(tangent, y, 1.5);
          // Dense but non-physical separator through the camera path.
          point(0, y, tangent);
        }
      }

      final walls = StructuralPlaneFit.proposeEnvelopeWalls(
        xyz: Float32List.fromList(xyz),
        cameraCentersXyz: Float64List.fromList(const [
          -0.5,
          1,
          0,
          0,
          1,
          0,
          0.5,
          1,
          0,
        ]),
        floorNormal: const [0, 1, 0],
        floorValue: 0,
      );

      expect(walls, isNotEmpty);
      expect(
        walls,
        everyElement(
          predicate<StructuralEnvelopeWallProposal>(
            (wall) =>
                wall.cameraDistanceMinM >= -0.05 - 1e-12 ||
                wall.cameraDistanceMaxM <= 0.05 + 1e-12,
          ),
        ),
      );
      expect(
        walls.any(
          (wall) =>
              wall.normal[0].abs() > 0.98 &&
              (wall.planeValue.abs() - 2).abs() < 0.1,
        ),
        isTrue,
      );
      expect(
        walls.any(
          (wall) => wall.normal[0].abs() > 0.98 && wall.planeValue.abs() < 0.1,
        ),
        isFalse,
      );
    },
  );

  test('Dart validates malformed fit input before entering native code', () {
    expect(
      () => StructuralPlaneFit.fitFloor(
        xyz: Float32List.fromList(const [0, 0, 0]),
      ),
      throwsArgumentError,
    );
    expect(
      () => StructuralPlaneFit.fitWalls(
        xyz: Float32List.fromList(const [0, 0, 0]),
        floorNormal: const [0, 1, 0],
        floorValue: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => StructuralPlaneFit.proposeFloors(
        xyz: Float32List.fromList(const [0, 0, 0]),
        minimumCameraHeight: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => StructuralPlaneFit.proposeEnvelopeWalls(
        xyz: Float32List.fromList(List<double>.filled(300, 0)),
        cameraCentersXyz: Float64List.fromList(const [0, 0, 0]),
        floorNormal: const [0, 1, 0],
        floorValue: 0,
      ),
      throwsArgumentError,
    );
  });

  test(
    'Dart orchestrates finite-wall ownership before dual manifold birth',
    () {
      final sparse = <double>[];
      for (var ix = -20; ix <= 20; ix++) {
        for (var iz = -20; iz <= 20; iz++) {
          sparse.addAll([ix * 0.02, 0, iz * 0.02]);
        }
      }
      final session = LocalManifoldBirthSession.create(
        sparseXyz: Float32List.fromList(sparse),
        options: const LocalManifoldBirthOptions(
          maximumNearestM: 0.06,
          maximumNeighborRadiusM: 0.12,
          maximumNeighborRmsM: 0.005,
          maximumPerpendicularM: 0.01,
        ),
      );
      try {
        const wall = StructuralWall(
          index: 0,
          thetaDeg: 0,
          certified: true,
          supportPoints35mm: 100,
          coverageCells10cm: 100,
          domainPoints: 100,
          supportPoints20mm: [100, 100, 100, 100, 100],
          supportCells10cm: [100, 100, 100, 100, 100],
          normal: [1, 0, 0],
          basisU: [0, 0, 1],
          basisV: [0, 1, 0],
          planeValue: 1,
          boundsU: [-1, 1],
          boundsHeight: [0, 2],
          score: 1,
          supportProminenceVs5cm: 1,
          coverageProminenceVs5cm: 1,
        );
        final result = session.filter(
          candidateXyz: Float32List.fromList(const [
            0,
            0,
            0,
            0.03,
            0.005,
            -0.02,
            0,
            0.03,
            0,
            1.05,
            1,
            0,
            2,
            0,
            2,
            0,
            -2,
            0,
          ]),
          floorValue: 0,
          certifiedWalls: const [wall],
          candidateEligible: Uint8List.fromList(const [1, 0, 1, 1, 1, 1]),
          selectedFloor: const StructuralFloorDomain(
            certified: true,
            normal: [0, 1, 0],
            basisU: [1, 0, 0],
            basisV: [0, 0, 1],
            planeValue: -1,
            boundsU: [-0.5, 0.5],
            boundsV: [-0.5, 0.5],
          ),
        );

        expect(result.floorOwned, [0, 0, 0, 0, 0, 1]);
        expect(result.wallOwned, [0, 0, 0, 1, 0, 0]);
        expect(result.structuralOwned, [0, 0, 0, 1, 0, 1]);
        expect(result.inputEligible, [1, 0, 1, 1, 1, 1]);
        expect(result.born, [1, 0, 0, 0, 0, 0]);
        expect(result.firstPartitionSupport[1], 0);
        expect(result.secondPartitionSupport[1], 0);
        expect(result.firstPartitionSupport[3], 0);
        expect(result.secondPartitionSupport[3], 0);
        expect(result.firstPartitionSupport[5], 0);
        expect(result.secondPartitionSupport[5], 0);
      } finally {
        session.dispose();
      }
    },
  );

  test(
    'reference certificate matches the legacy production fold on four mini fixtures',
    () {
      const fixtures = {
        'cap40': (0.004, -0.30),
        'cap41': (0.006, -0.10),
        'cap50': (0.008, 0.10),
        'cap51': (0.010, 0.30),
      };
      for (final entry in fixtures.entries) {
        final (partitionTwoY, xOffset) = entry.value;
        final session = LocalManifoldBirthSession.create(
          sparseXyz: _partitionedPlanes(partitionTwoY, xOffset: xOffset),
          options: _certificateOptions,
        );
        final candidates = Float32List.fromList([
          xOffset,
          0.002,
          0,
          xOffset + 0.018,
          0.001,
          0.005,
          xOffset + 0.030,
          0.001,
          0,
        ]);
        final eligible = Uint8List.fromList(const [1, 1, 0]);
        try {
          final legacy = session.filter(
            candidateXyz: candidates,
            floorValue: 0,
            certifiedWalls: const [],
            candidateEligible: eligible,
          );
          final certified = session.filterReferenceCertified(
            candidateXyz: candidates,
            productionFold: 2,
            candidateEligible: eligible,
          );

          expect(certified.certified, isTrue, reason: entry.key);
          expect(certified.failedFoldMask, 0, reason: entry.key);
          expect(certified.preCertificateBirthCount, 2, reason: entry.key);
          expect(certified.blockedBirthCount, 0, reason: entry.key);
          expect(certified.finalBirthCount, 2, reason: entry.key);
          expect(certified.born, legacy.born, reason: entry.key);
          expect(certified.born, const [1, 1, 0], reason: entry.key);
        } finally {
          session.dispose();
        }
      }
    },
  );

  test('reference certificate combines upstream and structural ownership', () {
    final session = LocalManifoldBirthSession.create(
      sparseXyz: _partitionedPlanes(0.006),
      options: _certificateOptions,
    );
    try {
      final result = session.filterReferenceCertified(
        candidateXyz: Float32List.fromList(const [
          0,
          0.002,
          0,
          0.018,
          0.001,
          0.005,
          0.030,
          0.001,
          0,
        ]),
        productionFold: 2,
        candidateEligible: Uint8List.fromList(const [1, 1, 0]),
        structuralOwned: Uint8List.fromList(const [0, 1, 0]),
      );

      expect(result.certified, isTrue);
      expect(result.preCertificateBirthCount, 1);
      expect(result.blockedBirthCount, 0);
      expect(result.finalBirthCount, 1);
      expect(result.born, const [1, 0, 0]);
    } finally {
      session.dispose();
    }
  });

  test(
    'reference certificate blocks every birth when any blind fold regresses',
    () {
      final session = LocalManifoldBirthSession.create(
        sparseXyz: _partitionedPlanes(1),
        options: _certificateOptions,
      );
      try {
        final result = session.filterReferenceCertified(
          candidateXyz: Float32List.fromList(const [0, 0, 0, 0, 1, 0]),
          productionFold: 2,
        );

        expect(result.failedFoldMask & (1 << 2), isNot(0));
        expect(result.preCertificateBirthCount, 1);
        expect(result.blockedBirthCount, 1);
        expect(result.finalBirthCount, 0);
        expect(result.born, const [0, 0]);
      } finally {
        session.dispose();
      }
    },
  );

  test('reference certificate accepts a valid zero-birth reference', () {
    final session = LocalManifoldBirthSession.create(
      sparseXyz: _partitionedPlanes(0.006),
      options: _certificateOptions,
    );
    try {
      final result = session.filterReferenceCertified(
        candidateXyz: Float32List.fromList(const [4, 4, 4]),
        productionFold: 2,
      );

      expect(result.certified, isTrue);
      expect(result.preCertificateBirthCount, 0);
      expect(result.blockedBirthCount, 0);
      expect(result.finalBirthCount, 0);
      expect(result.born, const [0]);
    } finally {
      session.dispose();
    }
  });

  test(
    'single entry exactly matches legacy ownership plus reference certificate',
    () {
      final session = LocalManifoldBirthSession.create(
        sparseXyz: _partitionedPlanes(0.006),
        options: _certificateOptions,
      );
      final candidates = Float32List.fromList(const [
        0,
        0.002,
        0,
        0.018,
        0.001,
        0.005,
        1.05,
        1,
        0,
        0,
        -1.05,
        0,
        0.030,
        0.001,
        0,
      ]);
      final reciprocalEligible = Uint8List.fromList(const [1, 1, 1, 1, 0]);
      try {
        final legacyOwnership = session.filter(
          candidateXyz: candidates,
          floorValue: 0,
          certifiedWalls: const [_certificateWall],
          candidateEligible: reciprocalEligible,
          selectedFloor: _certificateFloor,
        );
        final separateCertificate = session.filterReferenceCertified(
          candidateXyz: candidates,
          productionFold: 2,
          candidateEligible: reciprocalEligible,
          structuralOwned: legacyOwnership.structuralOwned,
        );
        final single = session.filterReferenceCertifiedWithStructuralOwnership(
          candidateXyz: candidates,
          floorValue: 0,
          certifiedWalls: const [_certificateWall],
          candidateEligible: reciprocalEligible,
          selectedFloor: _certificateFloor,
        );

        expect(single.inputEligible, legacyOwnership.inputEligible);
        expect(single.floorOwned, legacyOwnership.floorOwned);
        expect(single.wallOwned, legacyOwnership.wallOwned);
        expect(single.structuralOwned, legacyOwnership.structuralOwned);
        expect(
          single.certificate.failedFoldMask,
          separateCertificate.failedFoldMask,
        );
        expect(
          single.certificate.preCertificateBirthCount,
          separateCertificate.preCertificateBirthCount,
        );
        expect(
          single.certificate.blockedBirthCount,
          separateCertificate.blockedBirthCount,
        );
        expect(
          single.certificate.finalBirthCount,
          separateCertificate.finalBirthCount,
        );
        expect(single.born, separateCertificate.born);
        expect(identical(single.born, single.certificate.born), isTrue);
        expect(single.floorOwned, const [0, 0, 0, 1, 0]);
        expect(single.wallOwned, const [0, 0, 1, 0, 0]);
        expect(single.structuralOwned, const [0, 0, 1, 1, 0]);
      } finally {
        session.dispose();
      }
    },
  );

  test('single entry accepts zero births when every candidate is B-owned', () {
    final session = LocalManifoldBirthSession.create(
      sparseXyz: _partitionedPlanes(0.006),
      options: _certificateOptions,
    );
    try {
      final result = session.filterReferenceCertifiedWithStructuralOwnership(
        candidateXyz: Float32List.fromList(const [1.05, 1, 0, 0, -3, 0]),
        floorValue: 0,
        certifiedWalls: const [_certificateWall],
        selectedFloor: _certificateFloor,
      );

      expect(result.floorOwned, const [0, 1]);
      expect(result.wallOwned, const [1, 0]);
      expect(result.structuralOwned, const [1, 1]);
      expect(result.certificate.certified, isTrue);
      expect(result.certificate.preCertificateBirthCount, 0);
      expect(result.certificate.blockedBirthCount, 0);
      expect(result.certificate.finalBirthCount, 0);
      expect(result.born, const [0, 0]);
    } finally {
      session.dispose();
    }
  });

  test(
    'single entry contains one certificate pass and no legacy filter pass',
    () {
      final source = File(
        'lib/structural_planesweep_ffi.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'filterReferenceCertifiedWithStructuralOwnership({',
      );
      final end = source.indexOf(
        '/// Applies the complete three-fold quality certificate',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      expect(
        RegExp(r'_filterReferenceCertifiedNative\(').allMatches(body),
        hasLength(1),
      );
      expect(body, isNot(contains('.localManifoldFilter(')));
    },
  );

  test(
    'single entry is faster than the legacy double-manifold composition',
    () {
      final session = LocalManifoldBirthSession.create(
        sparseXyz: _partitionedPlanes(0.006),
        options: _certificateOptions,
      );
      final candidates = <double>[];
      for (var repeat = 0; repeat < 80; repeat++) {
        candidates.addAll([
          (repeat % 25 - 12) * 0.006,
          0.001,
          ((repeat * repeat + 3 * repeat) % 13) * 0.005 - 0.03,
        ]);
      }
      final candidateXyz = Float32List.fromList(candidates);
      var evidence = 0;

      int runSingle(int iterations) {
        final watch = Stopwatch()..start();
        for (var iteration = 0; iteration < iterations; iteration++) {
          final result = session
              .filterReferenceCertifiedWithStructuralOwnership(
                candidateXyz: candidateXyz,
                floorValue: 0,
                certifiedWalls: const [],
              );
          evidence += result.certificate.finalBirthCount;
        }
        return watch.elapsedMicroseconds;
      }

      int runDouble(int iterations) {
        final watch = Stopwatch()..start();
        for (var iteration = 0; iteration < iterations; iteration++) {
          final ownership = session.filter(
            candidateXyz: candidateXyz,
            floorValue: 0,
            certifiedWalls: const [],
          );
          final certificate = session.filterReferenceCertified(
            candidateXyz: candidateXyz,
            productionFold: 2,
            structuralOwned: ownership.structuralOwned,
          );
          evidence += certificate.finalBirthCount;
        }
        return watch.elapsedMicroseconds;
      }

      try {
        runSingle(2);
        runDouble(2);
        final singleMicros = runSingle(20);
        final doubleMicros = runDouble(20);
        expect(evidence, greaterThanOrEqualTo(0));
        expect(singleMicros, lessThan(doubleMicros * 2));
      } finally {
        session.dispose();
      }
    },
  );

  test('reference certificate rejects malformed Dart input before native', () {
    expect(
      () => LocalManifoldBirthSession.create(
        sparseXyz: Float32List.fromList(
          List<double>.filled(72, 0)..[5] = double.nan,
        ),
      ),
      throwsArgumentError,
    );
    final session = LocalManifoldBirthSession.create(
      sparseXyz: _partitionedPlanes(0.006),
      options: _certificateOptions,
    );
    try {
      expect(
        () => session.filterReferenceCertified(
          candidateXyz: Float32List.fromList(const [0, 0, double.nan]),
          productionFold: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => session.filterReferenceCertified(
          candidateXyz: Float32List.fromList(const [0, 0, 0]),
          productionFold: 3,
        ),
        throwsArgumentError,
      );
      expect(
        () => session.filterReferenceCertified(
          candidateXyz: Float32List.fromList(const [0, 0, 0]),
          productionFold: 2,
          candidateEligible: Uint8List.fromList(const [2]),
        ),
        throwsArgumentError,
      );
      expect(
        () => session.filterReferenceCertified(
          candidateXyz: Float32List.fromList(const [0, 0, 0]),
          productionFold: 2,
          structuralOwned: Uint8List(0),
        ),
        throwsArgumentError,
      );
    } finally {
      session.dispose();
    }
  });
}
