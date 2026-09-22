import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/structural_candidate_ffi.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

List<double> _repeatBirthSupport(List<double> seed, int pointCount) {
  final seedPoints = seed.length ~/ 3;
  return [
    for (var index = 0; index < pointCount; index++)
      for (var axis = 0; axis < 3; axis++)
        seed[(index % seedPoints) * 3 + axis],
  ];
}

Float32List _certificateSparse(double partitionTwoY) {
  final sparse = <double>[];
  for (var sample = -16; sample <= 16; sample++) {
    final x = sample * 0.006;
    final z = ((sample * sample + 3 * sample) % 13) * 0.005 - 0.03;
    sparse.addAll([x, -0.002, z]);
    sparse.addAll([x, 0.002, z]);
    sparse.addAll([x, partitionTwoY, z]);
  }
  return Float32List.fromList(sparse);
}

const _coordinatorCertificateOptions = LocalManifoldBirthOptions(
  maximumNearestM: 0.06,
  maximumNeighborRadiusM: 0.15,
  maximumNeighborRmsM: 0.01,
  maximumPerpendicularM: 0.02,
);

const _nonOwningCertificateFloor = StructuralFloorDomain(
  certified: true,
  normal: [0, 1, 0],
  basisU: [1, 0, 0],
  basisV: [0, 0, 1],
  planeValue: -100,
  boundsU: [-1, 1],
  boundsV: [-1, 1],
);

void main() {
  test('four-scene frozen image evidence selects the same physical floor', () {
    BcdFloorCandidateMetrics row(int index, int accepted, double ncc) =>
        BcdFloorCandidateMetrics(
          proposalIndex: index,
          accepted: accepted,
          coverageCells5cm: accepted,
          medianNcc: ncc,
        );

    final cap40 = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: [
        row(0, 97, 0.8516464154041505),
        row(1, 15, 0.8318626201081736),
        row(2, 8, 0.8126601483135294),
      ],
    );
    expect(cap40.decisive, isTrue);
    expect(cap40.winnerProposalIndex, 0);
    expect(cap40.stage, BcdFloorSelectionStage.coarse10cm);

    final cap41Coarse = [
      row(0, 9, 0.7969505760639897),
      row(1, 8, 0.8211455424430676),
      row(2, 8, 0.8496873125078828),
      row(3, 23, 0.8734918857280253),
      row(4, 27, 0.839002668235008),
      row(5, 13, 0.8491878604472887),
    ];
    final cap41NeedsFine = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: cap41Coarse,
    );
    expect(cap41NeedsFine.decisive, isFalse);
    expect(cap41NeedsFine.requiredFineProposalIndices, unorderedEquals([3, 4]));
    final cap41 = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: cap41Coarse,
      fine: [row(3, 68, 0.8680303421616664), row(4, 99, 0.8696285812925926)],
    );
    expect(cap41.decisive, isTrue);
    expect(cap41.winnerProposalIndex, 4);
    expect(cap41.stage, BcdFloorSelectionStage.fine5cmTop2);

    final cap50 = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: [row(0, 8, 0.8212328661413896), row(1, 29, 0.8343313160648356)],
    );
    expect(cap50.decisive, isTrue);
    expect(cap50.winnerProposalIndex, 1);

    final cap51 = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: [row(0, 16, 0.8031266844798615)],
    );
    expect(cap51.decisive, isTrue);
    expect(cap51.winnerProposalIndex, 0);
  });

  test('ambiguous floor evidence fails closed without publishing a winner', () {
    const coarse = [
      BcdFloorCandidateMetrics(
        proposalIndex: 0,
        accepted: 20,
        coverageCells5cm: 20,
        medianNcc: 0.8,
      ),
      BcdFloorCandidateMetrics(
        proposalIndex: 1,
        accepted: 19,
        coverageCells5cm: 19,
        medianNcc: 0.8,
      ),
    ];
    final needsFine = BcdFinalizeCoordinator.selectFloorOwner(coarse: coarse);
    expect(needsFine.decisive, isFalse);
    final rejected = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: coarse,
      fine: const [
        BcdFloorCandidateMetrics(
          proposalIndex: 0,
          accepted: 40,
          coverageCells5cm: 40,
          medianNcc: 0.82,
        ),
        BcdFloorCandidateMetrics(
          proposalIndex: 1,
          accepted: 38,
          coverageCells5cm: 38,
          medianNcc: 0.82,
        ),
      ],
    );
    expect(rejected.decisive, isFalse);
    expect(rejected.winnerProposalIndex, isNull);
    expect(rejected.stage, BcdFloorSelectionStage.rejectedAmbiguous);
  });

  test(
    'cap40 wall survives only when image and sparse evidence both dominate',
    () {
      const realWall = BcdWallCandidateMetrics(
        candidateId: 'envelope__wall_envelope_9',
        thetaDeg: 55.60761631684947,
        planeValue: -2.4830913050532146,
        sparseScore: 2313.9783922932384,
        sparseSupportPoints: 581,
        accepted: 12,
        coverageCells5cm: 12,
        medianNcc: 0.911547377493498,
        nccP10: 0.8862045943018788,
      );
      const competingLayer = BcdWallCandidateMetrics(
        candidateId: 'envelope__wall_envelope_14',
        thetaDeg: 60.65791449426142,
        planeValue: -2.5237372288269997,
        sparseScore: 1066,
        sparseSupportPoints: 516,
        accepted: 10,
        coverageCells5cm: 10,
        medianNcc: 0.8908839719430772,
        nccP10: 0.8737458603409366,
      );

      final decision = BcdFinalizeCoordinator.selectWallOwners(const [
        realWall,
        competingLayer,
      ]);

      expect(decision.complete, isTrue);
      expect(decision.unresolvedFamilyCount, 0);
      expect(decision.selectedCandidateIds, [realWall.candidateId]);

      final noIndependentSparseLead = BcdFinalizeCoordinator.selectWallOwners([
        realWall,
        const BcdWallCandidateMetrics(
          candidateId: 'same_sparse_layer',
          thetaDeg: 60.65791449426142,
          planeValue: -2.5237372288269997,
          sparseScore: 2000,
          sparseSupportPoints: 600,
          accepted: 10,
          coverageCells5cm: 10,
          medianNcc: 0.8908839719430772,
          nccP10: 0.8737458603409366,
        ),
      ]);
      expect(noIndependentSparseLead.selectedCandidateIds, isEmpty);
      expect(
        noIndependentSparseLead.requiredStrictCandidateIds,
        unorderedEquals([realWall.candidateId, 'same_sparse_layer']),
      );
    },
  );

  test('certified cap51-style finite walls anchor distinct families', () {
    final first = BcdWallCandidateMetrics(
      candidateId: 'legacy__wall_1',
      thetaDeg: 74,
      planeValue: 1.184863,
      sparseScore: 3440,
      sparseSupportPoints: 3440,
      accepted: 20,
      coverageCells5cm: 20,
      medianNcc: 0.91,
      nccP10: 0.86,
      incumbent: true,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [0, 0, 1],
        basisV: [0, 1, 0],
        planeValue: 1.184863,
        basisVOriginValue: 0,
        boundsU: [0, 1],
        boundsV: [0, 1],
      ),
      birthSupportXyz: _repeatBirthSupport(const [
        1.184863,
        0.2,
        0.2,
        1.184863,
        0.4,
        0.5,
        1.184863,
        0.7,
        0.8,
      ], 20),
    );
    final second = BcdWallCandidateMetrics(
      candidateId: 'legacy__wall_2',
      thetaDeg: 62,
      planeValue: 0.706660,
      sparseScore: 4475,
      sparseSupportPoints: 4475,
      accepted: 13,
      coverageCells5cm: 13,
      medianNcc: 0.90,
      nccP10: 0.85,
      incumbent: true,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [0.9781476007, 0, 0.2079116908],
        basisU: [-0.2079116908, 0, 0.9781476007],
        basisV: [0, 1, 0],
        planeValue: 0.706660,
        basisVOriginValue: 0,
        boundsU: [1.13, 2.13],
        boundsV: [0, 1],
      ),
      birthSupportXyz: _repeatBirthSupport(const [
        0.399,
        0.2,
        1.517,
        0.337,
        0.4,
        1.811,
        0.295,
        0.7,
        2.006,
      ], 13),
    );

    final decision = BcdFinalizeCoordinator.selectWallOwners([first, second]);

    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(first, second),
      isFalse,
    );
    // The old infinite-plane rule grouped these because 12 deg <= 15 deg and
    // |1.184863 - 0.706660| <= 0.75 m. Their finite rectangles are about
    // 0.77 m apart, so neither physical wall is allowed to suppress the other.
    expect(
      decision.selectedCandidateIds,
      unorderedEquals([first.candidateId, second.candidateId]),
    );
    expect(decision.unresolvedFamilyCount, 0);
  });

  test('overlapping parallel finite domains compete in one wall family', () {
    final winner = BcdWallCandidateMetrics(
      candidateId: 'real_wall',
      thetaDeg: 30,
      planeValue: 1,
      sparseScore: 2000,
      sparseSupportPoints: 600,
      accepted: 20,
      coverageCells5cm: 20,
      medianNcc: 0.92,
      nccP10: 0.88,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [0, 0, 1],
        basisV: [0, 1, 0],
        planeValue: 1,
        basisVOriginValue: 0,
        boundsU: [0, 1],
        boundsV: [0, 2],
      ),
      birthSupportXyz: _repeatBirthSupport(const [
        1,
        0.2,
        0.2,
        1,
        0.8,
        0.5,
        1,
        1.4,
        0.8,
      ], 20),
    );
    final parallelLayer = BcdWallCandidateMetrics(
      candidateId: 'parallel_layer',
      thetaDeg: 30,
      planeValue: 1.05,
      sparseScore: 900,
      sparseSupportPoints: 400,
      accepted: 10,
      coverageCells5cm: 10,
      medianNcc: 0.88,
      nccP10: 0.82,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [0, 0, 1],
        basisV: [0, 1, 0],
        planeValue: 1.05,
        basisVOriginValue: 0,
        boundsU: [0.05, 1.05],
        boundsV: [0.05, 1.95],
      ),
      birthSupportXyz: _repeatBirthSupport(const [
        1.05,
        0.2,
        0.2,
        1.05,
        0.8,
        0.5,
        1.05,
        1.4,
        0.8,
      ], 10),
    );

    final decision = BcdFinalizeCoordinator.selectWallOwners([
      winner,
      parallelLayer,
    ]);

    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(winner, parallelLayer),
      isTrue,
    );
    expect(decision.selectedCandidateIds, [winner.candidateId]);
    expect(decision.unresolvedFamilyCount, 0);
  });

  test('finite-domain majority includes Float32 points exactly 10 cm away', () {
    final fourBoundaryAndFourOutside = Float32List.fromList([
      for (var index = 0; index < 4; index++) ...[1.1, 0.2, 0.2],
      for (var index = 0; index < 4; index++) ...[1.2, 0.2, 0.2],
    ]).toList();
    final left = BcdWallCandidateMetrics(
      candidateId: 'left',
      thetaDeg: 0,
      planeValue: 2,
      sparseScore: 10,
      sparseSupportPoints: 8,
      accepted: 8,
      coverageCells5cm: 8,
      medianNcc: 0.9,
      nccP10: 0.8,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [0, 0, 1],
        basisV: [0, 1, 0],
        planeValue: 2,
        basisVOriginValue: 0,
        boundsU: [0, 1],
        boundsV: [0, 1],
      ),
      birthSupportXyz: fourBoundaryAndFourOutside,
    );
    final right = BcdWallCandidateMetrics(
      candidateId: 'right',
      thetaDeg: 0,
      planeValue: 1,
      sparseScore: 10,
      sparseSupportPoints: 8,
      accepted: 8,
      coverageCells5cm: 8,
      medianNcc: 0.9,
      nccP10: 0.8,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [0, 0, 1],
        basisV: [0, 1, 0],
        planeValue: 1,
        basisVOriginValue: 0,
        boundsU: [0, 1],
        boundsV: [0, 1],
      ),
      birthSupportXyz: _repeatBirthSupport(const [1, 0.8, 0.8], 8),
    );

    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(left, right),
      isTrue,
    );
    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(right, left),
      isTrue,
    );
  });

  test('wall finite-domain evidence fails closed when snapshots disagree', () {
    BcdWallCandidateMetrics row({required List<double> support}) =>
        BcdWallCandidateMetrics(
          candidateId: 'wall',
          thetaDeg: 0,
          planeValue: 1,
          sparseScore: 10,
          sparseSupportPoints: 8,
          accepted: 8,
          coverageCells5cm: 8,
          medianNcc: 0.9,
          nccP10: 0.8,
          finiteDomain: const BcdWallFiniteDomain(
            normal: [1, 0, 0],
            basisU: [0, 0, 1],
            basisV: [0, 1, 0],
            planeValue: 1,
            basisVOriginValue: 0,
            boundsU: [0, 1],
            boundsV: [0, 1],
          ),
          birthSupportXyz: support,
        );

    expect(
      () => BcdFinalizeCoordinator.selectWallOwners([
        row(support: _repeatBirthSupport(const [1, 0.2, 0.2], 7)),
      ]),
      throwsArgumentError,
    );
  });

  test('wall finite domains require a unit orthogonal coordinate frame', () {
    final malformed = BcdWallCandidateMetrics(
      candidateId: 'wall',
      thetaDeg: 0,
      planeValue: 1,
      sparseScore: 10,
      sparseSupportPoints: 8,
      accepted: 8,
      coverageCells5cm: 8,
      medianNcc: 0.9,
      nccP10: 0.8,
      finiteDomain: const BcdWallFiniteDomain(
        normal: [1, 0, 0],
        basisU: [1, 0, 0],
        basisV: [0, 1, 0],
        planeValue: 1,
        basisVOriginValue: 0,
        boundsU: [0, 1],
        boundsV: [0, 1],
      ),
      birthSupportXyz: _repeatBirthSupport(const [1, 0.2, 0.2], 8),
    );

    expect(
      () => BcdFinalizeCoordinator.selectWallOwners([malformed]),
      throwsArgumentError,
    );
  });

  test('certified finite walls remain distinct near one corner', () {
    BcdWallCandidateMetrics row(
      String id,
      int accepted,
      double sparseScore,
      List<double> boundsU,
      List<double> boundsV,
    ) => BcdWallCandidateMetrics(
      candidateId: id,
      thetaDeg: 45,
      planeValue: 2,
      sparseScore: sparseScore,
      sparseSupportPoints: sparseScore.round(),
      accepted: accepted,
      coverageCells5cm: accepted,
      medianNcc: id == 'first' ? 0.92 : 0.86,
      nccP10: id == 'first' ? 0.88 : 0.80,
      incumbent: true,
      finiteDomain: BcdWallFiniteDomain(
        normal: const [1, 0, 0],
        basisU: const [0, 0, 1],
        basisV: const [0, 1, 0],
        planeValue: 2,
        basisVOriginValue: 0,
        boundsU: boundsU,
        boundsV: boundsV,
      ),
      birthSupportXyz: _repeatBirthSupport(
        id == 'first'
            ? const [2, 0.2, 0.2, 2, 0.4, 0.4, 2, 0.6, 0.6]
            : const [2, 1.3, 1.3, 2, 1.5, 1.5, 2, 1.7, 1.7],
        accepted,
      ),
    );

    final first = row('first', 20, 2000, const [0, 1], const [0, 1]);
    final corner = row(
      'corner_only',
      10,
      900,
      const [1.05, 2.05],
      const [1.05, 2.05],
    );
    final decision = BcdFinalizeCoordinator.selectWallOwners([first, corner]);

    // The nearest corners are sqrt(0.05^2 + 0.05^2) ~= 0.071 m apart, but
    // the rectangles have no meaningful shared domain and are not competitors.
    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(first, corner),
      isFalse,
    );
    expect(
      decision.selectedCandidateIds,
      unorderedEquals(['first', 'corner_only']),
    );
    expect(decision.unresolvedFamilyCount, 0);
  });

  test('certified incumbents anchor distinct physical wall families', () {
    const first = BcdWallCandidateMetrics(
      candidateId: 'legacy_0',
      thetaDeg: 0,
      planeValue: 1,
      sparseScore: 100,
      sparseSupportPoints: 500,
      accepted: 12,
      coverageCells5cm: 12,
      medianNcc: 0.9,
      nccP10: 0.85,
      incumbent: true,
    );
    const second = BcdWallCandidateMetrics(
      candidateId: 'legacy_1',
      thetaDeg: 5,
      planeValue: 1.4,
      sparseScore: 90,
      sparseSupportPoints: 450,
      accepted: 10,
      coverageCells5cm: 10,
      medianNcc: 0.88,
      nccP10: 0.82,
      incumbent: true,
    );

    final decision = BcdFinalizeCoordinator.selectWallOwners(const [
      first,
      second,
    ]);

    expect(decision.selectedCandidateIds, [
      first.candidateId,
      second.candidateId,
    ]);
    expect(decision.unresolvedFamilyCount, 0);
  });

  test('ambiguous open wall family requests and applies strict evidence', () {
    BcdWallCandidateMetrics row(
      String id,
      int accepted, {
      BcdWallStrictMetrics? strict,
    }) => BcdWallCandidateMetrics(
      candidateId: id,
      thetaDeg: id == 'a' ? 20 : 23,
      planeValue: id == 'a' ? 1.0 : 1.05,
      sparseScore: id == 'a' ? 100 : 90,
      sparseSupportPoints: id == 'a' ? 300 : 290,
      accepted: accepted,
      coverageCells5cm: accepted,
      medianNcc: 0.9,
      nccP10: 0.85,
      strict: strict,
    );

    final pending = BcdFinalizeCoordinator.selectWallOwners([
      row('a', 10),
      row('b', 9),
    ]);
    expect(pending.complete, isFalse);
    expect(pending.requiredStrictCandidateIds, unorderedEquals(['a', 'b']));

    final decided = BcdFinalizeCoordinator.selectWallOwners([
      row(
        'a',
        10,
        strict: const BcdWallStrictMetrics(
          eligible: true,
          accepted: 20,
          coverageCells5cm: 20,
          medianNcc: 0.9284,
          nccP10: 0.8961,
        ),
      ),
      row(
        'b',
        9,
        strict: const BcdWallStrictMetrics(
          eligible: true,
          accepted: 12,
          coverageCells5cm: 12,
          medianNcc: 0.9282,
          nccP10: 0.8599,
        ),
      ),
    ]);
    expect(decided.complete, isTrue);
    expect(decided.selectedCandidateIds, ['a']);
    expect(decided.unresolvedFamilyCount, 0);
  });

  test('only a complete wall decision can mint finite birth ownership', () {
    const proposal = StructuralEnvelopeWallProposal(
      index: 9,
      supportPoints35mm: 581,
      coverageCells10cm: 96,
      thetaDeg: 55.6076,
      normal: [0.56, 0, -0.83],
      basisU: [-0.83, 0, -0.56],
      basisV: [0, 1, 0],
      planeValue: -2.48,
      boundsU: [-2.68, -1.76],
      boundsHeight: [0.30, 2.25],
      score: 2313,
      cameraDistanceMinM: -0.01,
      cameraDistanceMaxM: 3.22,
      cameraClearanceMinAbsM: 0.01,
    );
    const selected = BcdWallSelectionDecision(
      selectedCandidateIds: ['envelope__wall_envelope_9'],
      requiredStrictCandidateIds: [],
      unresolvedFamilyCount: 0,
    );

    final walls = BcdFinalizeCoordinator.certifyEnvelopeWallOwners(
      proposals: const [proposal],
      decision: selected,
    );

    expect(walls, hasLength(1));
    expect(walls.single.certified, isTrue);
    expect(walls.single.index, proposal.index);
    expect(walls.single.normal, proposal.normal);
    expect(walls.single.boundsHeight, proposal.boundsHeight);
    expect(walls.single.supportPoints20mm, [0, 0, 581, 0, 0]);

    expect(
      () => BcdFinalizeCoordinator.certifyEnvelopeWallOwners(
        proposals: const [proposal],
        decision: const BcdWallSelectionDecision(
          selectedCandidateIds: [],
          requiredStrictCandidateIds: ['envelope__wall_envelope_9'],
          unresolvedFamilyCount: 1,
        ),
      ),
      throwsStateError,
    );
  });

  test('complete wall decision certifies legacy and envelope proposals', () {
    const legacy = StructuralWall(
      index: 2,
      thetaDeg: 0,
      certified: false,
      supportPoints35mm: 100,
      coverageCells10cm: 50,
      domainPoints: 100,
      supportPoints20mm: [1, 2, 3, 4, 5],
      supportCells10cm: [1, 2, 3, 4, 5],
      normal: [1, 0, 0],
      basisU: [0, 0, 1],
      basisV: [0, 1, 0],
      planeValue: 1,
      boundsU: [-1, 1],
      boundsHeight: [0, 2],
      score: 10,
      supportProminenceVs5cm: 1,
      coverageProminenceVs5cm: 1,
    );
    const envelope = StructuralEnvelopeWallProposal(
      index: 4,
      supportPoints35mm: 80,
      coverageCells10cm: 40,
      thetaDeg: 90,
      normal: [0, 0, 1],
      basisU: [1, 0, 0],
      basisV: [0, 1, 0],
      planeValue: 2,
      boundsU: [-2, 2],
      boundsHeight: [0, 2],
      score: 8,
      cameraDistanceMinM: -3,
      cameraDistanceMaxM: -1,
      cameraClearanceMinAbsM: 1,
    );
    final walls = BcdFinalizeCoordinator.certifyWallOwners(
      legacyProposals: const [legacy],
      envelopeProposals: const [envelope],
      decision: const BcdWallSelectionDecision(
        selectedCandidateIds: ['legacy__wall_2', 'envelope__wall_envelope_4'],
        requiredStrictCandidateIds: [],
        unresolvedFamilyCount: 0,
      ),
    );
    expect(walls, hasLength(2));
    expect(walls, everyElement(predicate<StructuralWall>((w) => w.certified)));
    expect(walls[0].supportPoints20mm, legacy.supportPoints20mm);
    expect(walls[1].normal, envelope.normal);
  });

  test('registered AR poses project gravity-world points into JPEG pixels', () {
    BcdRegisteredCameraFrame frame({
      required int id,
      required String path,
      required List<double> translation,
    }) => BcdRegisteredCameraFrame(
      frameId: id,
      jpegPath: path,
      imageWidth: 4000,
      imageHeight: 3000,
      grayWidth: 1000,
      grayHeight: 750,
      grayFx: 500,
      grayFy: 500,
      grayCx: 500,
      grayCy: 375,
      cameraFromWorldQuaternionWxyz: const [1, 0, 0, 0],
      cameraFromWorldTranslation: translation,
    );

    final views = BcdFinalizeCoordinator.buildRegisteredPlaneSweepViews([
      frame(id: 2, path: '/tmp/translated.jpg', translation: const [-1, 0, 0]),
      frame(id: 1, path: '/tmp/origin.jpg', translation: const [0, 0, 0]),
    ]);

    ({double x, double y, double z}) project(
      BcdPlaneSweepView view,
      List<double> point,
    ) {
      final p = view.projection3x4;
      final x = p[0] * point[0] + p[1] * point[1] + p[2] * point[2] + p[3];
      final y = p[4] * point[0] + p[5] * point[1] + p[6] * point[2] + p[7];
      final z = p[8] * point[0] + p[9] * point[1] + p[10] * point[2] + p[11];
      return (x: x / z, y: y / z, z: z);
    }

    expect(views.map((view) => view.jpegPath), [
      '/tmp/origin.jpg',
      '/tmp/translated.jpg',
    ]);
    final center = project(views[0], const [0, 0, -2]);
    expect(center.x, closeTo(2000, 1e-9));
    expect(center.y, closeTo(1500, 1e-9));
    expect(center.z, closeTo(2, 1e-9));
    final rightAndUp = project(views[0], const [1, 1, -2]);
    expect(rightAndUp.x, closeTo(3000, 1e-9));
    expect(rightAndUp.y, closeTo(500, 1e-9));
    final translatedCenter = project(views[1], const [1, 0, -2]);
    expect(translatedCenter.x, closeTo(2000, 1e-9));
    expect(translatedCenter.y, closeTo(1500, 1e-9));
    expect(views[1].cameraCenter, orderedEquals(const [1, 0, 0]));
  });

  test('malformed registered pose fails before structural native work', () {
    expect(
      () => BcdFinalizeCoordinator.buildRegisteredPlaneSweepViews(const [
        BcdRegisteredCameraFrame(
          frameId: 0,
          jpegPath: '/tmp/frame.jpg',
          imageWidth: 100,
          imageHeight: 100,
          grayWidth: 50,
          grayHeight: 50,
          grayFx: 30,
          grayFy: 30,
          grayCx: 25,
          grayCy: 25,
          cameraFromWorldQuaternionWxyz: [0, 0, 0, 0],
          cameraFromWorldTranslation: [0, 0, 0],
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('Dart groups shared-C structural candidates into bounded batches', () {
    BcdPlaneSweepView frame(double cameraX) => BcdPlaneSweepView(
      jpegPath: '/tmp/frame_$cameraX.jpg',
      projection3x4: Float64List.fromList([
        100,
        0,
        50,
        -100 * cameraX,
        0,
        100,
        50,
        0,
        0,
        0,
        1,
        0,
      ]),
      cameraCenter: Float64List.fromList([cameraX, 0, 0]),
      width: 100,
      height: 100,
    );

    final batches = BcdFinalizeCoordinator.prepareStructuralBatches(
      BcdStructuralSurfaceRequest(
        grid: const StructuralCandidateGridSpec(
          normal: [0, 0, 1],
          basisU: [1, 0, 0],
          basisV: [0, 1, 0],
          planeValue: 2,
          basisVOriginValue: 0,
          boundsU: [0, 0.1],
          boundsV: [0, 0],
          gridM: 0.1,
        ),
        depthOffsetsM: const [0, 0.05],
        tilePoints: 2,
        viewMode: StructuralViewMode.perPoint,
        maximumViews: 2,
        patchN: 7,
        frames: [frame(-0.2), frame(0.2), frame(0)],
        patchRadiusMByScale: const [0.015, 0.03],
        minimumStdU8ByScale: const [6, 6],
        birthOptionsByScale: const [
          PlaneSweepBirthOptions(),
          PlaneSweepBirthOptions(),
        ],
      ),
    );

    expect(batches, isNotEmpty);
    expect(
      [for (final batch in batches) ...batch.sourceCandidateIndices]..sort(),
      [0, 1],
    );
    for (final batch in batches) {
      expect(batch.candidateCount, batch.sourceCandidateIndices.length);
      expect(batch.hypothesesPerCandidate, 2);
      expect(batch.pointsXyz.length, batch.candidateCount * 2 * 3);
      expect(
        batch.candidateViewMasks.length,
        2 * batch.candidateCount * 2 * batch.views.length,
      );
      expect(batch.candidateViewMasks, everyElement(1));
    }
  });

  test('B publishes only the certified center hypothesis', () {
    final result = BcdFinalizeCoordinator.assembleStructuralBirths(
      pointsXyz: Float32List.fromList(const [
        1,
        2,
        3,
        10,
        20,
        30,
        11,
        21,
        31,
        4,
        5,
        6,
        40,
        50,
        60,
        41,
        51,
        61,
      ]),
      hypothesesPerCandidate: 3,
      finish: PlaneSweepFinishResult(
        candidates: const [
          PlaneSweepCandidateResult(
            accepted: true,
            supportingViews: 4,
            medianNcc: 0.9,
            maxParallaxDeg: 8,
            observedDepthMargin: 0.2,
          ),
          PlaneSweepCandidateResult(
            accepted: false,
            supportingViews: 2,
            medianNcc: 0.4,
            maxParallaxDeg: 2,
            observedDepthMargin: 0.01,
          ),
        ],
        rgb: Uint8List.fromList(const [10, 20, 30, 0, 0, 0]),
      ),
    );

    expect(result.acceptedCandidateIndices, [0]);
    expect(result.cloud.xyz, orderedEquals(const [1, 2, 3]));
    expect(result.cloud.rgb, orderedEquals(const [10, 20, 30]));
  });

  test('B aggregates tiled birth evidence with the frozen quality metrics', () {
    BcdStructuralBirthResult batch({
      required List<int> evaluated,
      required List<int> accepted,
      required List<double> xyz,
      required List<PlaneSweepCandidateResult> evidence,
    }) => BcdStructuralBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(xyz),
        rgb: Uint8List(accepted.length * 3),
      ),
      evaluatedCandidateIndices: evaluated,
      acceptedCandidateIndices: accepted,
      evidence: evidence,
    );

    final summary = BcdFinalizeCoordinator.aggregateStructuralEvidence(
      batches: [
        batch(
          evaluated: const [0, 1, 2],
          accepted: const [0, 2],
          xyz: const [0.01, 0, 0.01, 0.06, 0, 0.01],
          evidence: const [
            PlaneSweepCandidateResult(
              accepted: true,
              supportingViews: 3,
              medianNcc: 0.7,
              maxParallaxDeg: 5,
              observedDepthMargin: 0.02,
            ),
            PlaneSweepCandidateResult(
              accepted: false,
              supportingViews: 2,
              medianNcc: 0.5,
              maxParallaxDeg: 2,
              observedDepthMargin: -1,
            ),
            PlaneSweepCandidateResult(
              accepted: true,
              supportingViews: 5,
              medianNcc: 0.9,
              maxParallaxDeg: 25,
              observedDepthMargin: double.infinity,
            ),
          ],
        ),
        batch(
          evaluated: const [3, 4],
          accepted: const [3, 4],
          xyz: const [0.11, 0, 0.01, 0.111, 0, 0.011],
          evidence: const [
            PlaneSweepCandidateResult(
              accepted: true,
              supportingViews: 4,
              medianNcc: 0.8,
              maxParallaxDeg: 15,
              observedDepthMargin: 0.04,
            ),
            PlaneSweepCandidateResult(
              accepted: true,
              supportingViews: 6,
              medianNcc: 1.0,
              maxParallaxDeg: 35,
              observedDepthMargin: 0.06,
            ),
          ],
        ),
      ],
      basisU: const [1, 0, 0],
      basisV: const [0, 0, 1],
    );

    expect(summary.evaluated, 5);
    expect(summary.accepted, 4);
    expect(summary.coverageCells5cm, 3);
    expect(summary.medianNcc, closeTo(0.85, 1e-12));
    expect(summary.nccP10, closeTo(0.73, 1e-12));
    expect(summary.medianSupportingViews, closeTo(4.5, 1e-12));
    expect(summary.medianParallaxDeg, closeTo(20, 1e-12));
    expect(summary.depthMarginMin, closeTo(0.02, 1e-12));
    expect(summary.depthMarginMedian, closeTo(0.04, 1e-12));
  });

  test('B evidence aggregation rejects duplicate or mismatched tiles', () {
    final malformed = BcdStructuralBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(const [0, 0, 0]),
        rgb: Uint8List(3),
      ),
      evaluatedCandidateIndices: const [4],
      acceptedCandidateIndices: const [5],
      evidence: const [
        PlaneSweepCandidateResult(
          accepted: true,
          supportingViews: 3,
          medianNcc: 0.8,
          maxParallaxDeg: 8,
          observedDepthMargin: 0.03,
        ),
      ],
    );
    expect(
      () => BcdFinalizeCoordinator.aggregateStructuralEvidence(
        batches: [malformed],
        basisU: const [1, 0, 0],
        basisV: const [0, 0, 1],
      ),
      throwsArgumentError,
    );
  });

  test('frozen B floor and wall requests preserve the quality contract', () {
    BcdPlaneSweepView frame(int index) => BcdPlaneSweepView(
      jpegPath: '/tmp/frame_$index.jpg',
      projection3x4: Float64List.fromList(const [
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      cameraCenter: Float64List.fromList([index.toDouble(), 0, 0]),
      width: 100,
      height: 100,
    );

    final frames = [for (var index = 0; index < 12; index++) frame(index)];
    const floor = StructuralFloorProposal(
      index: 4,
      supportPoints20mm: 100,
      coverageCells10cm: 50,
      normal: [0, 1, 0],
      planeValue: -1.2,
      basisU: [1, 0, 0],
      basisV: [0, 0, 1],
      boundsU: [-2, 2],
      boundsV: [-3, 3],
      rmsErrorM: 0.01,
      tiltDeg: 0,
      priorScore: 10,
    );
    final floorRequest = BcdFinalizeCoordinator.floorSurfaceRequest(
      proposal: floor,
      frames: frames,
      gridM: 0.10,
    );
    expect(floorRequest.grid.basisVOriginValue, 0);
    expect(floorRequest.grid.gridM, 0.10);
    expect(floorRequest.depthOffsetsM, [0, -0.05, 0.05]);
    expect(floorRequest.viewMode, StructuralViewMode.perPoint);
    expect(floorRequest.minimumStdU8ByScale, [6.05]);
    expect(floorRequest.maximumViews, 10);
    expect(floorRequest.patchRadiusMByScale, [0.015]);
    expect(floorRequest.birthOptionsByScale.single.uniqueDepthMargin, 0.02);

    const selectedFloor = StructuralFloorDomain(
      certified: true,
      normal: [0, 1, 0],
      basisU: [1, 0, 0],
      basisV: [0, 0, 1],
      planeValue: -1.2,
      boundsU: [-2, 2],
      boundsV: [-3, 3],
    );
    const wall = StructuralEnvelopeWallProposal(
      index: 9,
      supportPoints35mm: 80,
      coverageCells10cm: 40,
      thetaDeg: 90,
      normal: [1, 0, 0],
      basisU: [0, 0, 1],
      basisV: [0, 1, 0],
      planeValue: 2,
      boundsU: [-3, 3],
      boundsHeight: [0, 2.5],
      score: 20,
      cameraDistanceMinM: -4,
      cameraDistanceMaxM: -1,
      cameraClearanceMinAbsM: 1,
    );
    final wallRequest = BcdFinalizeCoordinator.wallSurfaceRequest(
      proposal: wall,
      selectedFloor: selectedFloor,
      frames: frames,
    );
    expect(wallRequest.grid.basisV, selectedFloor.normal);
    expect(wallRequest.grid.basisVOriginValue, selectedFloor.planeValue);
    expect(wallRequest.grid.gridM, 0.05);
    expect(wallRequest.depthOffsetsM, [0, -0.10, -0.05, 0.05, 0.10]);
    expect(wallRequest.viewMode, StructuralViewMode.perTile);
    expect(wallRequest.tilePoints, 64);
    expect(wallRequest.patchN, 9);
    expect(wallRequest.patchRadiusMByScale, [0.03]);
    expect(wallRequest.birthOptionsByScale.single.minimumViews, 4);
    expect(wallRequest.birthOptionsByScale.single.nccMin, 0.80);
    expect(wallRequest.birthOptionsByScale.single.minimumParallaxDeg, 10);

    const baseline = BcdStructuralEvidenceSummary(
      evaluated: 100,
      accepted: 20,
      coverageCells5cm: 20,
      medianNcc: 0.92,
      nccP10: 0.88,
      medianSupportingViews: 6.2,
      medianParallaxDeg: 21,
      depthMarginMin: 0.03,
      depthMarginMedian: 0.04,
    );
    final strict = BcdFinalizeCoordinator.strictWallSurfaceRequest(
      proposal: wall,
      selectedFloor: selectedFloor,
      frames: frames,
      baseline: baseline,
    );
    expect(strict.patchRadiusMByScale, [0.03, 0.06]);
    expect(strict.minimumStdU8ByScale, [6, 6]);
    expect(strict.birthOptionsByScale[1].minimumViews, 5);
    expect(strict.birthOptionsByScale[1].nccMin, 0.80);
    expect(strict.birthOptionsByScale[1].minimumParallaxDeg, 18);
    expect(strict.birthOptionsByScale[1].uniqueDepthMargin, 0.06);
    expect(strict.birthOptionsByScale[1].postMinimumViews, 7);
    expect(strict.birthOptionsByScale[1].postMinimumParallaxDeg, 21);
    expect(strict.birthOptionsByScale[1].postMinNcc, 0.92);
  });

  test(
    'strict wall rescue preserves baseline bytes and only appends births',
    () {
      BcdStructuralBirthResult result({
        required List<int> evaluated,
        required List<int> accepted,
        required List<double> xyz,
        required List<int> rgb,
        required List<PlaneSweepCandidateResult> evidence,
      }) => BcdStructuralBirthResult(
        cloud: BcdPointCloud(
          xyz: Float32List.fromList(xyz),
          rgb: Uint8List.fromList(rgb),
        ),
        evaluatedCandidateIndices: evaluated,
        acceptedCandidateIndices: accepted,
        evidence: evidence,
      );

      const acceptedBase = PlaneSweepCandidateResult(
        accepted: true,
        supportingViews: 5,
        medianNcc: 0.9,
        maxParallaxDeg: 20,
        observedDepthMargin: 0.04,
      );
      const rejected = PlaneSweepCandidateResult(
        accepted: false,
        supportingViews: 0,
        medianNcc: double.negativeInfinity,
        maxParallaxDeg: 0,
        observedDepthMargin: double.negativeInfinity,
      );
      const acceptedRescue = PlaneSweepCandidateResult(
        accepted: true,
        supportingViews: 6,
        medianNcc: 0.95,
        maxParallaxDeg: 25,
        observedDepthMargin: 0.07,
      );
      final baseline = result(
        evaluated: const [0, 1, 2],
        accepted: const [0],
        xyz: const [0.01, 0, 0.01],
        rgb: const [10, 20, 30],
        evidence: const [acceptedBase, rejected, rejected],
      );
      final combined = result(
        evaluated: const [0, 1, 2],
        accepted: const [0, 2],
        xyz: const [0.01, 0, 0.01, 0.11, 0, 0.01],
        rgb: const [10, 20, 30, 40, 50, 60],
        evidence: const [acceptedBase, rejected, acceptedRescue],
      );

      final merge = BcdFinalizeCoordinator.mergeStrictWallRescue(
        baselineBatches: [baseline],
        combinedBatches: [combined],
        basisU: const [1, 0, 0],
        basisV: const [0, 0, 1],
      );
      expect(merge.eligible, isTrue);
      expect(merge.addedBirths, 1);
      expect(
        merge.publication.cloud.xyz,
        Float32List.fromList(const [0.01, 0, 0.01, 0.11, 0, 0.01]),
      );
      expect(merge.publication.cloud.rgb, [10, 20, 30, 40, 50, 60]);
      expect(merge.publication.acceptedCandidateIndices, [0, 2]);
      expect(merge.strictMetrics.accepted, 2);
      expect(merge.strictMetrics.coverageCells5cm, 2);
    },
  );

  test('strict wall rescue fails closed on any quality regression', () {
    const baseEvidence = PlaneSweepCandidateResult(
      accepted: true,
      supportingViews: 6,
      medianNcc: 0.95,
      maxParallaxDeg: 25,
      observedDepthMargin: 0.07,
    );
    const weakRescue = PlaneSweepCandidateResult(
      accepted: true,
      supportingViews: 3,
      medianNcc: 0.7,
      maxParallaxDeg: 5,
      observedDepthMargin: 0.02,
    );
    const rejected = PlaneSweepCandidateResult(
      accepted: false,
      supportingViews: 0,
      medianNcc: double.negativeInfinity,
      maxParallaxDeg: 0,
      observedDepthMargin: double.negativeInfinity,
    );
    BcdStructuralBirthResult one({
      required List<int> accepted,
      required List<double> xyz,
      required List<PlaneSweepCandidateResult> evidence,
    }) => BcdStructuralBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(xyz),
        rgb: Uint8List(accepted.length * 3),
      ),
      evaluatedCandidateIndices: const [0, 1],
      acceptedCandidateIndices: accepted,
      evidence: evidence,
    );

    final merge = BcdFinalizeCoordinator.mergeStrictWallRescue(
      baselineBatches: [
        one(
          accepted: const [0],
          xyz: const [0, 0, 0],
          evidence: const [baseEvidence, rejected],
        ),
      ],
      combinedBatches: [
        one(
          accepted: const [0, 1],
          xyz: const [0, 0, 0, 0.1, 0, 0],
          evidence: const [baseEvidence, weakRescue],
        ),
      ],
      basisU: const [1, 0, 0],
      basisV: const [0, 0, 1],
    );
    expect(merge.eligible, isFalse);
    expect(merge.nonRegressionChecks['median_ncc_not_lower'], isFalse);
    expect(merge.strictMetrics.eligible, isFalse);
  });

  test(
    'D reciprocal candidates pass floor and wall ownership before birth',
    () {
      final sparse = <double>[];
      for (var ix = -20; ix <= 20; ix++) {
        for (var iz = -20; iz <= 20; iz++) {
          sparse.addAll([ix * 0.02, 0, iz * 0.02]);
        }
      }
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

      final result = BcdFinalizeCoordinator.gateDetectorFreeCandidates(
        sparseXyz: Float32List.fromList(sparse),
        candidateXyz: Float32List.fromList(const [
          0,
          0,
          0,
          0.03,
          0.005,
          -0.02,
          1.05,
          1,
          0,
          0,
          -2,
          0,
        ]),
        candidateRgb: Uint8List.fromList(const [
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
        ]),
        reciprocalBorn: Uint8List.fromList(const [1, 0, 1, 1]),
        floorValue: 0,
        selectedFloor: const StructuralFloorDomain(
          certified: true,
          normal: [0, 1, 0],
          basisU: [1, 0, 0],
          basisV: [0, 0, 1],
          planeValue: -1,
          boundsU: [-0.5, 0.5],
          boundsV: [-0.5, 0.5],
        ),
        certifiedWalls: const [wall],
        options: const LocalManifoldBirthOptions(
          maximumNearestM: 0.06,
          maximumNeighborRadiusM: 0.12,
          maximumNeighborRmsM: 0.005,
          maximumPerpendicularM: 0.01,
        ),
      );

      expect(result.bornCandidateIndices, [0]);
      expect(result.floorRerouteCandidateIndices, [3]);
      expect(result.ownership.inputEligible, [1, 0, 1, 1]);
      expect(result.ownership.floorOwned, [0, 0, 0, 1]);
      expect(result.ownership.wallOwned, [0, 0, 1, 0]);
      expect(result.ownership.born, [1, 0, 0, 0]);
      expect(result.certificate.certified, isTrue);
      expect(result.certificate.failedFoldMask, 0);
      expect(result.certificate.preCertificateBirthCount, 1);
      expect(result.certificate.blockedBirthCount, 0);
      expect(result.certificate.finalBirthCount, 1);
      expect(result.certificate.born, result.ownership.born);
      expect(identical(result.certificate.born, result.ownership.born), isTrue);
      expect(result.cloud.xyz, orderedEquals(const [0, 0, 0]));
      expect(result.cloud.rgb, orderedEquals(const [1, 2, 3]));
    },
  );

  test('D certificate preserves every certified reciprocal birth', () {
    final result = BcdFinalizeCoordinator.gateDetectorFreeCandidates(
      sparseXyz: _certificateSparse(0.006),
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
      candidateRgb: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8, 9]),
      reciprocalBorn: Uint8List.fromList(const [1, 1, 0]),
      floorValue: -100,
      selectedFloor: _nonOwningCertificateFloor,
      certifiedWalls: const [],
      options: _coordinatorCertificateOptions,
    );

    expect(result.certificate.certified, isTrue);
    expect(result.certificate.failedFoldMask, 0);
    expect(result.certificate.preCertificateBirthCount, 2);
    expect(result.certificate.blockedBirthCount, 0);
    expect(result.certificate.finalBirthCount, 2);
    expect(result.certificate.born, const [1, 1, 0]);
    expect(result.ownership.born, result.certificate.born);
    expect(identical(result.certificate.born, result.ownership.born), isTrue);
    expect(result.bornCandidateIndices, const [0, 1]);
    expect(result.cloud.pointCount, 2);
  });

  test('D failed blind fold blocks the whole reference and legacy mask', () {
    final sparse = _certificateSparse(1);
    final candidates = Float32List.fromList(const [0, 0, 0, 0, 1, 0]);
    final legacySession = LocalManifoldBirthSession.create(
      sparseXyz: sparse,
      options: _coordinatorCertificateOptions,
    );
    try {
      final legacy = legacySession.filter(
        candidateXyz: candidates,
        candidateEligible: Uint8List.fromList(const [1, 1]),
        floorValue: -100,
        selectedFloor: _nonOwningCertificateFloor,
        certifiedWalls: const [],
      );
      expect(legacy.born.where((value) => value != 0), isNotEmpty);
    } finally {
      legacySession.dispose();
    }

    final result = BcdFinalizeCoordinator.gateDetectorFreeCandidates(
      sparseXyz: sparse,
      candidateXyz: candidates,
      candidateRgb: Uint8List.fromList(const [1, 2, 3, 4, 5, 6]),
      reciprocalBorn: Uint8List.fromList(const [1, 1]),
      floorValue: -100,
      selectedFloor: _nonOwningCertificateFloor,
      certifiedWalls: const [],
      options: _coordinatorCertificateOptions,
    );

    expect(result.certificate.certified, isFalse);
    expect(result.certificate.failedFoldMask & (1 << 2), isNot(0));
    expect(result.certificate.preCertificateBirthCount, 1);
    expect(result.certificate.blockedBirthCount, 1);
    expect(result.certificate.finalBirthCount, 0);
    expect(result.certificate.born, const [0, 0]);
    expect(result.ownership.born, const [0, 0]);
    expect(identical(result.certificate.born, result.ownership.born), isTrue);
    expect(result.bornCandidateIndices, isEmpty);
    expect(result.cloud.pointCount, 0);
  });

  test('D certified zero-birth reference remains a valid empty result', () {
    final result = BcdFinalizeCoordinator.gateDetectorFreeCandidates(
      sparseXyz: _certificateSparse(0.006),
      candidateXyz: Float32List.fromList(const [4, 4, 4]),
      candidateRgb: Uint8List.fromList(const [1, 2, 3]),
      reciprocalBorn: Uint8List.fromList(const [1]),
      floorValue: -100,
      selectedFloor: _nonOwningCertificateFloor,
      certifiedWalls: const [],
      options: _coordinatorCertificateOptions,
    );

    expect(result.certificate.certified, isTrue);
    expect(result.certificate.preCertificateBirthCount, 0);
    expect(result.certificate.blockedBirthCount, 0);
    expect(result.certificate.finalBirthCount, 0);
    expect(result.certificate.born, const [0]);
    expect(result.ownership.born, const [0]);
    expect(identical(result.certificate.born, result.ownership.born), isTrue);
    expect(result.cloud.pointCount, 0);
  });

  test('D empty candidate input has one certified empty truth', () {
    final result = BcdFinalizeCoordinator.gateDetectorFreeCandidates(
      sparseXyz: Float32List(0),
      candidateXyz: Float32List(0),
      candidateRgb: Uint8List(0),
      reciprocalBorn: Uint8List(0),
      floorValue: -100,
      selectedFloor: _nonOwningCertificateFloor,
      certifiedWalls: const [],
      options: _coordinatorCertificateOptions,
    );

    expect(result.certificate.certified, isTrue);
    expect(result.certificate.preCertificateBirthCount, 0);
    expect(result.certificate.blockedBirthCount, 0);
    expect(result.certificate.finalBirthCount, 0);
    expect(result.certificate.born, isEmpty);
    expect(identical(result.certificate.born, result.ownership.born), isTrue);
    expect(result.cloud.pointCount, 0);
  });

  test('D product coordinator has one certificate pass and fixed fold two', () {
    final source = File(
      'lib/capture/bcd_finalize_coordinator.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'static BcdDetectorFreeBirthResult gateDetectorFreeCandidates({',
    );
    final end = source.indexOf(
      'static void _validateDetectorFreeDepthJob(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(
      RegExp(
        r'filterReferenceCertifiedWithStructuralOwnership\(',
      ).allMatches(body),
      hasLength(1),
    );
    expect(body, contains('productionFold: 2'));
    expect(body, isNot(contains('session.filter(')));
    expect(body, isNot(contains('filterReferenceCertified(')));
  });

  test('final publication preserves the original sparse cloud byte order', () {
    final structural = BcdStructuralBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(const [7, 8, 9]),
        rgb: Uint8List.fromList(const [70, 80, 90]),
      ),
      acceptedCandidateIndices: const [0],
      evidence: const [],
    );
    final emptyMask = Uint8List(1);
    final detectorFree = BcdDetectorFreeBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(const [10, 11, 12]),
        rgb: Uint8List.fromList(const [100, 110, 120]),
      ),
      bornCandidateIndices: const [0],
      floorRerouteCandidateIndices: const [],
      ownership: ReferenceCertifiedBirthOwnershipResult(
        inputEligible: Uint8List.fromList(const [1]),
        floorOwned: emptyMask,
        wallOwned: Uint8List(1),
        structuralOwned: Uint8List(1),
        certificate: ReferenceBirthCertificateResult(
          failedFoldMask: 0,
          preCertificateBirthCount: 1,
          blockedBirthCount: 0,
          finalBirthCount: 1,
          born: Uint8List.fromList(const [1]),
        ),
      ),
    );

    final result = BcdFinalizeCoordinator.appendPreservingSparse(
      originalXyz: Float32List.fromList(const [1, 2, 3, 4, 5, 6]),
      originalRgb: Uint8List.fromList(const [10, 20, 30, 40, 50, 60]),
      structural: [structural],
      detectorFree: detectorFree,
    );

    expect(result.originalPointCount, 2);
    expect(result.structuralBirthCount, 1);
    expect(result.detectorFreeBirthCount, 1);
    expect(
      result.cloud.xyz,
      orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
    );
    expect(
      result.cloud.rgb,
      orderedEquals(const [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]),
    );
  });

  test('final publication cannot bypass a failed D certificate', () {
    final failed = ReferenceBirthCertificateResult(
      failedFoldMask: 1 << 2,
      preCertificateBirthCount: 1,
      blockedBirthCount: 1,
      finalBirthCount: 0,
      born: Uint8List.fromList(const [0]),
    );
    final detectorFree = BcdDetectorFreeBirthResult(
      cloud: BcdPointCloud(
        xyz: Float32List.fromList(const [10, 11, 12]),
        rgb: Uint8List.fromList(const [100, 110, 120]),
      ),
      bornCandidateIndices: const [0],
      floorRerouteCandidateIndices: const [],
      ownership: ReferenceCertifiedBirthOwnershipResult(
        inputEligible: Uint8List.fromList(const [1]),
        floorOwned: Uint8List(1),
        wallOwned: Uint8List(1),
        structuralOwned: Uint8List(1),
        certificate: failed,
      ),
    );

    expect(
      () => BcdFinalizeCoordinator.appendPreservingSparse(
        originalXyz: Float32List.fromList(const [1, 2, 3]),
        originalRgb: Uint8List.fromList(const [10, 20, 30]),
        structural: const [],
        detectorFree: detectorFree,
      ),
      throwsStateError,
    );
  });
}
