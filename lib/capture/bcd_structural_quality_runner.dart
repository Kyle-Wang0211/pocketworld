// Quality-first B structural reconstruction runner.
//
// This file is deliberately synchronous: the product must invoke it from a
// background isolate. All numerics remain in the shared C++/WGSL ABI; Dart
// owns only the frozen adaptive order and fail-closed ownership decisions.

import 'dart:math' as math;
import 'dart:typed_data';

import '../structural_candidate_ffi.dart';
import '../structural_planesweep_ffi.dart';
import 'bcd_finalize_coordinator.dart';

typedef BcdStructuralProgress =
    void Function(String stage, int completed, int total);

class BcdSurfaceSweepResult {
  const BcdSurfaceSweepResult({required this.births, required this.summary});

  final List<BcdStructuralBirthResult> births;
  final BcdStructuralEvidenceSummary summary;
}

/// First-party floor plane produced by the capture-time sparse pipeline.
///
/// This is deliberately separate from the image-selected B floor owner.  The
/// former is the stable vertical reference used to propose wall geometry; the
/// latter alone owns floor point births.  A proposal never gains publication
/// authority merely because this prior exists.
class BcdKnownFloorPlane {
  const BcdKnownFloorPlane({required this.normal, required this.planeValue});

  /// Resolves the sign convention of capture-time `ghost_mask.json` without
  /// trusting a platform-specific `n.x=d` versus `n.x+d=0` convention.  The
  /// sign with more first-party sparse support inside 3 cm wins exactly as in
  /// the frozen pure-A research route.
  factory BcdKnownFloorPlane.fromSignedDistanceMetadata({
    required List<double> normal,
    required double rawPlaneD,
    required Float32List sparseXyz,
    double supportBandM = 0.03,
  }) {
    if (normal.length != 3 ||
        normal.any((value) => !value.isFinite) ||
        !rawPlaneD.isFinite ||
        sparseXyz.length % 3 != 0 ||
        !supportBandM.isFinite ||
        supportBandM <= 0) {
      throw ArgumentError('invalid signed-distance floor metadata');
    }
    final length = math.sqrt(
      normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2],
    );
    if (!(length > 0)) {
      throw ArgumentError('signed-distance floor normal is degenerate');
    }
    final unit = [for (final value in normal) value / length];
    final scaledD = rawPlaneD / length;
    var plusSupport = 0;
    var minusSupport = 0;
    for (var index = 0; index < sparseXyz.length; index += 3) {
      final projection =
          sparseXyz[index] * unit[0] +
          sparseXyz[index + 1] * unit[1] +
          sparseXyz[index + 2] * unit[2];
      if ((projection - scaledD).abs() < supportBandM) plusSupport++;
      if ((projection + scaledD).abs() < supportBandM) minusSupport++;
    }
    return BcdKnownFloorPlane(
      normal: List.unmodifiable(unit),
      planeValue: plusSupport >= minusSupport ? scaledD : -scaledD,
    );
  }

  final List<double> normal;
  final double planeValue;
}

class BcdWallPlaneCalibration {
  const BcdWallPlaneCalibration({
    required this.wallIndex,
    required this.certified,
    required this.bestOffsetM,
    required this.bestAccepted,
    required this.secondAccepted,
    required this.uniqueCountPeak,
    required this.sparseAgrees,
    required this.summariesByOffsetM,
  });

  final int wallIndex;
  final bool certified;
  final double bestOffsetM;
  final int bestAccepted;
  final int secondAccepted;
  final bool uniqueCountPeak;
  final bool sparseAgrees;
  final Map<double, BcdStructuralEvidenceSummary> summariesByOffsetM;
}

abstract interface class BcdStructuralQualityBackend {
  List<StructuralFloorProposal> proposeFloors({
    required Float32List sparseXyz,
    required double minimumCameraHeight,
  });

  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  });

  List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List sparseXyz,
    required Float64List cameraCentersXyz,
    required StructuralFloorDomain floor,
  });

  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request);

  List<BcdSurfaceSweepResult> sweepMany(
    List<BcdStructuralSurfaceRequest> requests,
  );
}

class NativeBcdStructuralQualityBackend implements BcdStructuralQualityBackend {
  const NativeBcdStructuralQualityBackend();

  @override
  List<StructuralFloorProposal> proposeFloors({
    required Float32List sparseXyz,
    required double minimumCameraHeight,
  }) => StructuralPlaneFit.proposeFloors(
    xyz: sparseXyz,
    minimumCameraHeight: minimumCameraHeight,
  );

  @override
  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  }) => StructuralPlaneFit.fitWalls(
    xyz: sparseXyz,
    floorNormal: floor.normal,
    floorValue: floor.planeValue,
  );

  @override
  List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List sparseXyz,
    required Float64List cameraCentersXyz,
    required StructuralFloorDomain floor,
  }) => StructuralPlaneFit.proposeEnvelopeWalls(
    xyz: sparseXyz,
    cameraCentersXyz: cameraCentersXyz,
    floorNormal: floor.normal,
    floorValue: floor.planeValue,
  );

  @override
  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request) {
    return sweepMany([request]).single;
  }

  @override
  List<BcdSurfaceSweepResult> sweepMany(
    List<BcdStructuralSurfaceRequest> requests,
  ) {
    if (requests.isEmpty) return const [];
    final prepared = [
      for (final request in requests)
        BcdFinalizeCoordinator.prepareStructuralBatches(request),
    ];
    final flat = [for (final batches in prepared) ...batches];
    final flatBirths = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
      flat,
    );
    if (flatBirths.length != flat.length) {
      throw StateError('shared image sweep returned a truncated batch list');
    }
    final output = <BcdSurfaceSweepResult>[];
    var cursor = 0;
    for (var index = 0; index < requests.length; index++) {
      final count = prepared[index].length;
      final births = flatBirths.sublist(cursor, cursor + count);
      cursor += count;
      output.add(
        BcdSurfaceSweepResult(
          births: List.unmodifiable(births),
          summary: BcdFinalizeCoordinator.aggregateStructuralEvidence(
            batches: births,
            basisU: requests[index].grid.basisU,
            basisV: requests[index].grid.basisV,
          ),
        ),
      );
    }
    return List.unmodifiable(output);
  }
}

class BcdStructuralQualityResult {
  const BcdStructuralQualityResult({
    required this.qualityPassed,
    required this.rejectedReason,
    required this.floorDecision,
    required this.selectedFloorProposal,
    required this.selectedFloor,
    required this.wallDecision,
    required this.certifiedWalls,
    required this.floorBirths,
    required this.wallBirths,
    required this.structuralBirths,
    this.floorCoarseSummaries = const {},
    this.floorFineSummaries = const {},
    this.wallCandidates = const [],
    this.wallPlaneCalibrations = const [],
  });

  final bool qualityPassed;
  final String? rejectedReason;
  final BcdFloorSelectionDecision floorDecision;
  final StructuralFloorProposal? selectedFloorProposal;
  final StructuralFloorDomain? selectedFloor;
  final BcdWallSelectionDecision? wallDecision;
  final List<StructuralWall> certifiedWalls;
  final List<BcdStructuralBirthResult> floorBirths;
  final List<BcdStructuralBirthResult> wallBirths;
  final List<BcdStructuralBirthResult> structuralBirths;
  final Map<int, BcdStructuralEvidenceSummary> floorCoarseSummaries;
  final Map<int, BcdStructuralEvidenceSummary> floorFineSummaries;
  final List<BcdWallCandidateMetrics> wallCandidates;
  final List<BcdWallPlaneCalibration> wallPlaneCalibrations;
}

class BcdStructuralQualityRunner {
  const BcdStructuralQualityRunner({
    this.backend = const NativeBcdStructuralQualityBackend(),
  });

  final BcdStructuralQualityBackend backend;

  BcdStructuralQualityResult run({
    required Float32List sparseXyz,
    required List<BcdPlaneSweepView> registeredViews,
    BcdKnownFloorPlane? knownFloorPlane,
    BcdStructuralProgress? onProgress,
  }) {
    if (sparseXyz.length < 300 ||
        sparseXyz.length % 3 != 0 ||
        registeredViews.length < 3) {
      throw ArgumentError('B quality runner needs >=100 points and >=3 views');
    }
    final minimumCameraHeight = registeredViews
        .map((view) => view.cameraCenter[1])
        .reduce((left, right) => left < right ? left : right);
    final floorProposals = backend.proposeFloors(
      sparseXyz: sparseXyz,
      minimumCameraHeight: minimumCameraHeight,
    );
    if (floorProposals.isEmpty) {
      throw StateError('shared floor proposal stage returned no candidates');
    }
    final floorByIndex = {
      for (final proposal in floorProposals) proposal.index: proposal,
    };
    final coarse = <int, BcdSurfaceSweepResult>{};
    for (var index = 0; index < floorProposals.length; index++) {
      final proposal = floorProposals[index];
      onProgress?.call('floor_coarse', index, floorProposals.length);
      coarse[proposal.index] = backend.sweep(
        BcdFinalizeCoordinator.floorSurfaceRequest(
          proposal: proposal,
          frames: registeredViews,
          gridM: 0.10,
        ),
      );
    }
    onProgress?.call(
      'floor_coarse',
      floorProposals.length,
      floorProposals.length,
    );
    var floorDecision = BcdFinalizeCoordinator.selectFloorOwner(
      coarse: [
        for (final proposal in floorProposals)
          _floorMetrics(proposal.index, coarse[proposal.index]!.summary),
      ],
    );
    final fine = <int, BcdSurfaceSweepResult>{};
    if (!floorDecision.decisive) {
      final requiredFine = floorDecision.requiredFineProposalIndices;
      for (var index = 0; index < requiredFine.length; index++) {
        final proposalIndex = requiredFine[index];
        onProgress?.call('floor_fine', index, requiredFine.length);
        final proposal = floorByIndex[proposalIndex];
        if (proposal == null) {
          throw StateError('floor refinement requested an absent proposal');
        }
        fine[proposalIndex] = backend.sweep(
          BcdFinalizeCoordinator.floorSurfaceRequest(
            proposal: proposal,
            frames: registeredViews,
            gridM: 0.05,
          ),
        );
      }
      onProgress?.call('floor_fine', requiredFine.length, requiredFine.length);
      floorDecision = BcdFinalizeCoordinator.selectFloorOwner(
        coarse: [
          for (final proposal in floorProposals)
            _floorMetrics(proposal.index, coarse[proposal.index]!.summary),
        ],
        fine: [
          for (final entry in fine.entries)
            _floorMetrics(entry.key, entry.value.summary),
        ],
      );
    }
    final winnerIndex = floorDecision.winnerProposalIndex;
    if (!floorDecision.decisive || winnerIndex == null) {
      return BcdStructuralQualityResult(
        qualityPassed: false,
        rejectedReason: 'floor_owner_ambiguous',
        floorDecision: floorDecision,
        selectedFloorProposal: null,
        selectedFloor: null,
        wallDecision: null,
        certifiedWalls: const [],
        floorBirths: const [],
        wallBirths: const [],
        structuralBirths: const [],
        floorCoarseSummaries: Map.unmodifiable({
          for (final entry in coarse.entries) entry.key: entry.value.summary,
        }),
        floorFineSummaries: Map.unmodifiable({
          for (final entry in fine.entries) entry.key: entry.value.summary,
        }),
      );
    }
    final floorProposal = floorByIndex[winnerIndex]!;
    final selectedFloor = StructuralFloorDomain(
      certified: true,
      normal: floorProposal.normal,
      basisU: floorProposal.basisU,
      basisV: floorProposal.basisV,
      planeValue: floorProposal.planeValue,
      boundsU: floorProposal.boundsU,
      boundsV: floorProposal.boundsV,
    );
    final cameraCenters = Float64List(registeredViews.length * 3);
    for (var index = 0; index < registeredViews.length; index++) {
      cameraCenters.setRange(
        index * 3,
        index * 3 + 3,
        registeredViews[index].cameraCenter,
      );
    }
    final wallCandidateFloor = knownFloorPlane == null
        ? selectedFloor
        : _knownWallCandidateFloor(knownFloorPlane, selectedFloor);
    final rawLegacy = backend.fitLegacyWalls(
      sparseXyz: sparseXyz,
      floor: wallCandidateFloor,
    );
    final wallPlaneCalibrations = <BcdWallPlaneCalibration>[];
    final legacy = knownFloorPlane == null
        ? rawLegacy
        : _calibrateKnownFloorWalls(
            rawWalls: rawLegacy,
            sourceFloor: wallCandidateFloor,
            frames: registeredViews,
            onProgress: onProgress,
            calibrations: wallPlaneCalibrations,
          );
    final envelope = backend.proposeEnvelopeWalls(
      sparseXyz: sparseXyz,
      cameraCentersXyz: cameraCenters,
      floor: selectedFloor,
    );
    final wallSweeps = <String, BcdSurfaceSweepResult>{};
    final candidates = <BcdWallCandidateMetrics>[];
    final baseEntries =
        <
          ({
            String id,
            StructuralWall? legacy,
            StructuralEnvelopeWallProposal? envelope,
            StructuralFloorDomain wallFloor,
            BcdStructuralSurfaceRequest request,
          })
        >[
          for (final proposal in legacy)
            (
              id: 'legacy__wall_${proposal.index}',
              legacy: proposal,
              envelope: null,
              wallFloor: wallCandidateFloor,
              request: BcdFinalizeCoordinator.legacyWallSurfaceRequest(
                proposal: proposal,
                selectedFloor: wallCandidateFloor,
                frames: registeredViews,
              ),
            ),
          for (final proposal in envelope)
            (
              id: 'envelope__wall_envelope_${proposal.index}',
              legacy: null,
              envelope: proposal,
              wallFloor: selectedFloor,
              request: BcdFinalizeCoordinator.wallSurfaceRequest(
                proposal: proposal,
                selectedFloor: selectedFloor,
                frames: registeredViews,
              ),
            ),
        ];
    final wallTotal = baseEntries.length;
    final baseRequestById = {
      for (final entry in baseEntries) entry.id: entry.request,
    };
    var wallCompleted = 0;
    const surfaceWave = 8;
    for (var start = 0; start < baseEntries.length; start += surfaceWave) {
      onProgress?.call('wall_base', wallCompleted, wallTotal);
      final end = (start + surfaceWave).clamp(0, baseEntries.length);
      final wave = baseEntries.sublist(start, end);
      final results = backend.sweepMany([
        for (final entry in wave) entry.request,
      ]);
      if (results.length != wave.length) {
        throw StateError('wall base wave returned a truncated result list');
      }
      for (var local = 0; local < wave.length; local++) {
        final entry = wave[local];
        final sweep = results[local];
        wallSweeps[entry.id] = sweep;
        if (entry.legacy != null) {
          candidates.add(
            _legacyMetrics(
              entry.id,
              entry.legacy!,
              sweep.summary,
              entry.wallFloor.normal,
              entry.wallFloor.planeValue,
              _birthSupportXyz(sweep.births),
            ),
          );
        } else {
          candidates.add(
            _envelopeMetrics(
              entry.id,
              entry.envelope!,
              sweep.summary,
              entry.wallFloor.normal,
              entry.wallFloor.planeValue,
              _birthSupportXyz(sweep.births),
            ),
          );
        }
        wallCompleted++;
      }
    }
    onProgress?.call('wall_base', wallCompleted, wallTotal);

    BcdStructuralQualityResult rejectWallQuality(
      String reason,
      BcdWallSelectionDecision decision,
    ) => BcdStructuralQualityResult(
      qualityPassed: false,
      rejectedReason: reason,
      floorDecision: floorDecision,
      selectedFloorProposal: floorProposal,
      selectedFloor: selectedFloor,
      wallDecision: decision,
      certifiedWalls: const [],
      // B is a floor+wall product contract. A decisive floor must not leak
      // through as a successful structural publication when the required wall
      // has no image-certified birth authority.
      floorBirths: const [],
      wallBirths: const [],
      structuralBirths: const [],
      floorCoarseSummaries: Map.unmodifiable({
        for (final entry in coarse.entries) entry.key: entry.value.summary,
      }),
      floorFineSummaries: Map.unmodifiable({
        for (final entry in fine.entries) entry.key: entry.value.summary,
      }),
      wallCandidates: List.unmodifiable(candidates),
      wallPlaneCalibrations: List.unmodifiable(wallPlaneCalibrations),
    );

    final legacyIds = {
      for (final proposal in legacy) 'legacy__wall_${proposal.index}',
    };
    final anchorAdjudicated = _adjudicateLegacyAnchors(candidates, legacyIds);
    candidates
      ..clear()
      ..addAll(anchorAdjudicated);
    var wallDecision = BcdFinalizeCoordinator.selectWallOwners(candidates);
    if (candidates.isEmpty) {
      return rejectWallQuality('wall_candidates_absent', wallDecision);
    }
    if (wallDecision.selectedCandidateIds.isEmpty &&
        wallDecision.requiredStrictCandidateIds.isEmpty) {
      return rejectWallQuality(
        candidates.every((candidate) => candidate.accepted == 0)
            ? 'wall_birth_evidence_absent'
            : 'wall_owner_unresolved',
        wallDecision,
      );
    }
    final baseSelectedCandidateIds = List<String>.of(
      wallDecision.selectedCandidateIds,
    );
    final strictMerges = <String, BcdStrictWallRescueResult>{};
    final candidateById = {for (final row in candidates) row.candidateId: row};
    final envelopeById = {
      for (final proposal in envelope)
        'envelope__wall_envelope_${proposal.index}': proposal,
    };
    final legacyById = {
      for (final proposal in legacy) 'legacy__wall_${proposal.index}': proposal,
    };

    BcdStructuralSurfaceRequest strictRequest(String id) {
      final envelopeProposal = envelopeById[id];
      final legacyProposal = legacyById[id];
      final baseline = wallSweeps[id];
      if ((envelopeProposal == null && legacyProposal == null) ||
          baseline == null) {
        throw StateError('strict wall replay requested an absent candidate');
      }
      return envelopeProposal != null
          ? BcdFinalizeCoordinator.strictWallSurfaceRequest(
              proposal: envelopeProposal,
              selectedFloor: selectedFloor,
              frames: registeredViews,
              baseline: baseline.summary,
            )
          : BcdFinalizeCoordinator.strictLegacyWallSurfaceRequest(
              proposal: legacyProposal!,
              selectedFloor: wallCandidateFloor,
              frames: registeredViews,
              baseline: baseline.summary,
            );
    }

    BcdStrictWallRescueResult mergeStrict(
      String id,
      BcdSurfaceSweepResult combined,
    ) {
      final envelopeProposal = envelopeById[id];
      final legacyProposal = legacyById[id];
      final baseline = wallSweeps[id];
      if ((envelopeProposal == null && legacyProposal == null) ||
          baseline == null) {
        throw StateError('strict wall merge requested an absent candidate');
      }
      return BcdFinalizeCoordinator.mergeStrictWallRescue(
        baselineBatches: baseline.births,
        combinedBatches: combined.births,
        basisU: envelopeProposal?.basisU ?? legacyProposal!.basisU,
        basisV: envelopeProposal != null
            ? selectedFloor.normal
            : wallCandidateFloor.normal,
      );
    }

    void replayStrictWave(List<String> ids, String stage) {
      var completed = 0;
      onProgress?.call(stage, 0, ids.length);
      for (var start = 0; start < ids.length; start += surfaceWave) {
        final end = (start + surfaceWave).clamp(0, ids.length);
        final waveIds = ids.sublist(start, end);
        final results = backend.sweepMany([
          for (final id in waveIds) strictRequest(id),
        ]);
        if (results.length != waveIds.length) {
          throw StateError('strict wall wave returned a truncated result list');
        }
        for (var local = 0; local < waveIds.length; local++) {
          final id = waveIds[local];
          strictMerges[id] = mergeStrict(id, results[local]);
        }
        completed = end;
        onProgress?.call(stage, completed, ids.length);
      }
    }

    if (wallDecision.requiredStrictCandidateIds.isNotEmpty) {
      final strictIds = wallDecision.requiredStrictCandidateIds;
      replayStrictWave(strictIds, 'wall_strict');
      final updated = <BcdWallCandidateMetrics>[];
      for (final row in candidates) {
        final strict = strictMerges[row.candidateId]?.strictMetrics;
        updated.add(_withStrict(row, strict));
      }
      final adjudicated = BcdFinalizeCoordinator.selectWallOwners(updated);
      if (!adjudicated.selectedCandidateIds.toSet().containsAll(
        baseSelectedCandidateIds,
      )) {
        throw StateError('strict wall replay displaced a decisive base owner');
      }
      wallDecision = BcdWallSelectionDecision(
        selectedCandidateIds: List.unmodifiable([
          ...baseSelectedCandidateIds,
          for (final id in adjudicated.selectedCandidateIds)
            if (!baseSelectedCandidateIds.contains(id)) id,
        ]),
        requiredStrictCandidateIds: adjudicated.requiredStrictCandidateIds,
        unresolvedFamilyCount: adjudicated.unresolvedFamilyCount,
      );
      candidates
        ..clear()
        ..addAll(updated);
      if (wallDecision.requiredStrictCandidateIds.isNotEmpty) {
        return rejectWallQuality(
          'wall_strict_evidence_incomplete',
          wallDecision,
        );
      }
      // Keep the map live in debug builds and make absent candidate IDs an
      // explicit invariant rather than a later certification surprise.
      if (wallDecision.selectedCandidateIds.any(
        (id) => !candidateById.containsKey(id),
      )) {
        throw StateError('wall selector returned an unknown candidate');
      }
    }
    if (wallDecision.selectedCandidateIds.isEmpty) {
      return rejectWallQuality('wall_owner_unresolved', wallDecision);
    }

    // The frozen quality route replays the strict physical scale for every
    // selected owner, not only candidates that needed strict evidence to win.
    // It can only append sites while preserving every baseline byte and metric;
    // an ineligible replay is ignored during publication below.
    final finalRescueIds = [
      for (final id in wallDecision.selectedCandidateIds)
        if (!strictMerges.containsKey(id)) id,
    ];
    replayStrictWave(finalRescueIds, 'wall_rescue');
    final rescuedCandidates = [
      for (final row in candidates)
        _withStrict(row, strictMerges[row.candidateId]?.strictMetrics),
    ];
    candidates
      ..clear()
      ..addAll(rescuedCandidates);

    final rawCertifiedWalls = BcdFinalizeCoordinator.certifyWallOwners(
      legacyProposals: legacy,
      envelopeProposals: envelope,
      decision: wallDecision,
    );
    final certifiedWalls = <StructuralWall>[
      for (var index = 0; index < rawCertifiedWalls.length; index++)
        if (knownFloorPlane != null &&
            wallDecision.selectedCandidateIds[index].startsWith('legacy__'))
          _rebaseWallHeightDomain(
            rawCertifiedWalls[index],
            sourceFloorValue: wallCandidateFloor.planeValue,
            targetFloorValue: selectedFloor.planeValue,
          )
        else
          rawCertifiedWalls[index],
    ];
    if (certifiedWalls.isEmpty) {
      return rejectWallQuality('wall_owner_not_certified', wallDecision);
    }

    // Coarse/fine sweeps above exist only to select the unique structural
    // owners. Publishing those 10 cm / 5 cm samples made a certified plane
    // look like a sparse scatter in the product viewer. Once every owner is
    // fixed, replay exactly the same image/depth/quality contracts on a 1 cm
    // tile-bounded grid. Native [sweepMany] shares decoded images across the
    // floor and all selected walls; only these dense winner results receive
    // birth authority.
    final floorSelectionRequest = BcdFinalizeCoordinator.floorSurfaceRequest(
      proposal: floorProposal,
      frames: registeredViews,
      gridM: fine.containsKey(winnerIndex) ? 0.05 : 0.10,
    );
    final denseRequests = <BcdStructuralSurfaceRequest>[
      _densePublicationRequest(floorSelectionRequest),
      for (final id in wallDecision.selectedCandidateIds) ...[
        _densePublicationRequest(baseRequestById[id]!),
        _densePublicationRequest(strictRequest(id)),
      ],
    ];
    onProgress?.call('structural_dense', 0, denseRequests.length);
    final denseSweeps = backend.sweepMany(denseRequests);
    if (denseSweeps.length != denseRequests.length) {
      throw StateError('dense structural wave returned a truncated result');
    }
    onProgress?.call(
      'structural_dense',
      denseRequests.length,
      denseRequests.length,
    );
    final floorBirths = List<BcdStructuralBirthResult>.unmodifiable(
      denseSweeps.first.births,
    );
    final floorBirthPointCount = floorBirths.fold<int>(
      0,
      (sum, birth) => sum + birth.cloud.pointCount,
    );
    if (floorBirthPointCount == 0) {
      return rejectWallQuality('floor_birth_evidence_absent', wallDecision);
    }
    final wallBirths = <BcdStructuralBirthResult>[];
    for (
      var ownerIndex = 0;
      ownerIndex < wallDecision.selectedCandidateIds.length;
      ownerIndex++
    ) {
      final base = denseSweeps[1 + ownerIndex * 2];
      final combined = denseSweeps[2 + ownerIndex * 2];
      final request = denseRequests[1 + ownerIndex * 2];
      final denseStrict = BcdFinalizeCoordinator.mergeStrictWallRescue(
        baselineBatches: base.births,
        combinedBatches: combined.births,
        basisU: request.grid.basisU,
        basisV: request.grid.basisV,
      );
      if (denseStrict.eligible) {
        wallBirths.add(denseStrict.publication);
      } else {
        wallBirths.addAll(base.births);
      }
    }
    final wallBirthPointCount = wallBirths.fold<int>(
      0,
      (sum, birth) => sum + birth.cloud.pointCount,
    );
    if (wallBirthPointCount == 0) {
      return rejectWallQuality('wall_birth_evidence_absent', wallDecision);
    }
    return BcdStructuralQualityResult(
      qualityPassed: true,
      rejectedReason: null,
      floorDecision: floorDecision,
      selectedFloorProposal: floorProposal,
      selectedFloor: selectedFloor,
      wallDecision: wallDecision,
      certifiedWalls: certifiedWalls,
      floorBirths: floorBirths,
      wallBirths: List.unmodifiable(wallBirths),
      structuralBirths: List.unmodifiable([...floorBirths, ...wallBirths]),
      floorCoarseSummaries: Map.unmodifiable({
        for (final entry in coarse.entries) entry.key: entry.value.summary,
      }),
      floorFineSummaries: Map.unmodifiable({
        for (final entry in fine.entries) entry.key: entry.value.summary,
      }),
      wallCandidates: List.unmodifiable(candidates),
      wallPlaneCalibrations: List.unmodifiable(wallPlaneCalibrations),
    );
  }

  /// Converts an already-adjudicated surface request into its publication
  /// sweep. Geometry and every evidence threshold remain byte-for-byte the
  /// same; only the tangent-plane sampling pitch changes to 1 cm. Tile size is
  /// preserved so peak memory remains bounded independently of surface area.
  static BcdStructuralSurfaceRequest _densePublicationRequest(
    BcdStructuralSurfaceRequest selectedOwnerRequest,
  ) => BcdStructuralSurfaceRequest(
    grid: StructuralCandidateGridSpec(
      normal: selectedOwnerRequest.grid.normal,
      basisU: selectedOwnerRequest.grid.basisU,
      basisV: selectedOwnerRequest.grid.basisV,
      planeValue: selectedOwnerRequest.grid.planeValue,
      basisVOriginValue: selectedOwnerRequest.grid.basisVOriginValue,
      boundsU: selectedOwnerRequest.grid.boundsU,
      boundsV: selectedOwnerRequest.grid.boundsV,
      gridM: 0.01,
    ),
    depthOffsetsM: selectedOwnerRequest.depthOffsetsM,
    tilePoints: selectedOwnerRequest.tilePoints,
    viewMode: selectedOwnerRequest.viewMode,
    maximumViews: selectedOwnerRequest.maximumViews,
    patchN: selectedOwnerRequest.patchN,
    frames: selectedOwnerRequest.frames,
    patchRadiusMByScale: selectedOwnerRequest.patchRadiusMByScale,
    minimumStdU8ByScale: selectedOwnerRequest.minimumStdU8ByScale,
    birthOptionsByScale: selectedOwnerRequest.birthOptionsByScale,
    imageMarginPx: selectedOwnerRequest.imageMarginPx,
    maximumGrazeDeg: selectedOwnerRequest.maximumGrazeDeg,
  );

  /// Re-expresses legacy finite-wall height bounds in the scalar gauge used
  /// by D ownership. Legacy walls fitted against capture-time known-floor
  /// metadata store `h = dot(x, basisV) - sourceFloorValue`, while the shared
  /// ownership ABI receives the selected B floor scalar. Shifting both bounds
  /// preserves the exact same finite wall rectangle without changing its
  /// plane, basis, sparse evidence, or point births.
  static StructuralWall _rebaseWallHeightDomain(
    StructuralWall wall, {
    required double sourceFloorValue,
    required double targetFloorValue,
  }) {
    final shift = sourceFloorValue - targetFloorValue;
    return StructuralWall(
      index: wall.index,
      thetaDeg: wall.thetaDeg,
      certified: wall.certified,
      supportPoints35mm: wall.supportPoints35mm,
      coverageCells10cm: wall.coverageCells10cm,
      domainPoints: wall.domainPoints,
      supportPoints20mm: wall.supportPoints20mm,
      supportCells10cm: wall.supportCells10cm,
      normal: wall.normal,
      basisU: wall.basisU,
      basisV: wall.basisV,
      planeValue: wall.planeValue,
      boundsU: wall.boundsU,
      boundsHeight: [
        wall.boundsHeight[0] + shift,
        wall.boundsHeight[1] + shift,
      ],
      score: wall.score,
      supportProminenceVs5cm: wall.supportProminenceVs5cm,
      coverageProminenceVs5cm: wall.coverageProminenceVs5cm,
    );
  }

  static StructuralFloorDomain _knownWallCandidateFloor(
    BcdKnownFloorPlane known,
    StructuralFloorDomain selectedFloor,
  ) {
    if (known.normal.length != 3 ||
        known.normal.any((value) => !value.isFinite) ||
        !known.planeValue.isFinite) {
      throw ArgumentError('known floor plane is not finite 3D geometry');
    }
    final lengthSquared = known.normal.fold<double>(
      0,
      (sum, value) => sum + value * value,
    );
    if (lengthSquared < 0.99 || lengthSquared > 1.01) {
      throw ArgumentError('known floor normal must be unit length');
    }
    return StructuralFloorDomain(
      certified: true,
      normal: List.unmodifiable(known.normal),
      basisU: selectedFloor.basisU,
      basisV: selectedFloor.basisV,
      planeValue: known.planeValue,
      boundsU: selectedFloor.boundsU,
      boundsV: selectedFloor.boundsV,
    );
  }

  List<StructuralWall> _calibrateKnownFloorWalls({
    required List<StructuralWall> rawWalls,
    required StructuralFloorDomain sourceFloor,
    required List<BcdPlaneSweepView> frames,
    required List<BcdWallPlaneCalibration> calibrations,
    BcdStructuralProgress? onProgress,
  }) {
    const offsets = <double>[-0.10, -0.05, 0, 0.05, 0.10];
    final eligible = [
      for (final wall in rawWalls)
        if (wall.certified) wall,
    ];
    final accepted = <StructuralWall>[];
    final total = eligible.length * offsets.length;
    onProgress?.call('wall_calibration', 0, total);
    final requests = <BcdStructuralSurfaceRequest>[
      for (final wall in eligible)
        for (final offset in offsets)
          BcdFinalizeCoordinator.calibrationLegacyWallSurfaceRequest(
            proposal: wall,
            sourceFloor: sourceFloor,
            frames: frames,
            planeOffsetM: offset,
          ),
    ];
    final sweepResults = backend.sweepMany(requests);
    if (sweepResults.length != requests.length) {
      throw StateError('wall calibration returned a truncated result list');
    }
    var resultIndex = 0;
    for (final wall in eligible) {
      final rows = <double, BcdStructuralEvidenceSummary>{
        for (final offset in offsets)
          offset: sweepResults[resultIndex++].summary,
      };
      final ranked = offsets.toList()
        ..sort((left, right) {
          final leftSummary = rows[left]!;
          final rightSummary = rows[right]!;
          var order = rightSummary.accepted.compareTo(leftSummary.accepted);
          if (order != 0) return order;
          order = (rightSummary.medianNcc ?? -1).compareTo(
            leftSummary.medianNcc ?? -1,
          );
          if (order != 0) return order;
          return rightSummary.coverageCells5cm.compareTo(
            leftSummary.coverageCells5cm,
          );
        });
      final bestOffset = ranked[0];
      final best = rows[bestOffset]!;
      final second = rows[ranked[1]]!;
      final uniqueCountPeak =
          best.accepted >= 5 &&
          best.accepted >= second.accepted + 3 &&
          best.accepted >= second.accepted * 1.20;
      final bestIndex = offsets.indexOf(bestOffset);
      final selectedSparsePoints = wall.supportPoints20mm[bestIndex];
      final centerSparsePoints = wall.supportPoints20mm[2];
      final sparseAgrees = selectedSparsePoints >= centerSparsePoints * 0.50;
      final certified =
          uniqueCountPeak && sparseAgrees && bestOffset.abs() <= 0.05;
      calibrations.add(
        BcdWallPlaneCalibration(
          wallIndex: wall.index,
          certified: certified,
          bestOffsetM: bestOffset,
          bestAccepted: best.accepted,
          secondAccepted: second.accepted,
          uniqueCountPeak: uniqueCountPeak,
          sparseAgrees: sparseAgrees,
          summariesByOffsetM: Map.unmodifiable(rows),
        ),
      );
      if (certified) {
        accepted.add(_withWallPlaneValue(wall, wall.planeValue + bestOffset));
      }
    }
    onProgress?.call('wall_calibration', total, total);
    return List.unmodifiable(accepted);
  }

  static StructuralWall _withWallPlaneValue(
    StructuralWall wall,
    double planeValue,
  ) => StructuralWall(
    index: wall.index,
    thetaDeg: wall.thetaDeg,
    certified: wall.certified,
    supportPoints35mm: wall.supportPoints35mm,
    coverageCells10cm: wall.coverageCells10cm,
    domainPoints: wall.domainPoints,
    supportPoints20mm: wall.supportPoints20mm,
    supportCells10cm: wall.supportCells10cm,
    normal: wall.normal,
    basisU: wall.basisU,
    basisV: wall.basisV,
    planeValue: planeValue,
    boundsU: wall.boundsU,
    boundsHeight: wall.boundsHeight,
    score: wall.score,
    supportProminenceVs5cm: wall.supportProminenceVs5cm,
    coverageProminenceVs5cm: wall.coverageProminenceVs5cm,
  );

  static BcdFloorCandidateMetrics _floorMetrics(
    int proposalIndex,
    BcdStructuralEvidenceSummary summary,
  ) => BcdFloorCandidateMetrics(
    proposalIndex: proposalIndex,
    accepted: summary.accepted,
    coverageCells5cm: summary.coverageCells5cm,
    medianNcc: summary.medianNcc ?? 0,
  );

  static BcdWallCandidateMetrics _legacyMetrics(
    String id,
    StructuralWall proposal,
    BcdStructuralEvidenceSummary summary,
    List<double> floorNormal,
    double floorPlaneValue,
    List<double> birthSupportXyz,
  ) => BcdWallCandidateMetrics(
    candidateId: id,
    thetaDeg: proposal.thetaDeg.toDouble(),
    planeValue: proposal.planeValue,
    sparseScore: proposal.score,
    sparseSupportPoints: proposal.supportPoints35mm,
    accepted: summary.accepted,
    coverageCells5cm: summary.coverageCells5cm,
    medianNcc: summary.medianNcc ?? 0,
    nccP10: summary.nccP10 ?? 0,
    // Sparse certification anchors a distinct physical candidate family; it
    // never grants point-birth authority. The selector still requires the
    // same multi-view birth minimum and lets a decisive image-backed envelope
    // challenger replace this anchor. This matches the frozen research port.
    incumbent: proposal.certified,
    finiteDomain: BcdWallFiniteDomain(
      normal: proposal.normal,
      basisU: proposal.basisU,
      basisV: floorNormal,
      planeValue: proposal.planeValue,
      basisVOriginValue: floorPlaneValue,
      boundsU: proposal.boundsU,
      boundsV: proposal.boundsHeight,
    ),
    birthSupportXyz: birthSupportXyz,
  );

  static BcdWallCandidateMetrics _envelopeMetrics(
    String id,
    StructuralEnvelopeWallProposal proposal,
    BcdStructuralEvidenceSummary summary,
    List<double> floorNormal,
    double floorPlaneValue,
    List<double> birthSupportXyz,
  ) => BcdWallCandidateMetrics(
    candidateId: id,
    thetaDeg: proposal.thetaDeg,
    planeValue: proposal.planeValue,
    sparseScore: proposal.score,
    sparseSupportPoints: proposal.supportPoints35mm,
    accepted: summary.accepted,
    coverageCells5cm: summary.coverageCells5cm,
    medianNcc: summary.medianNcc ?? 0,
    nccP10: summary.nccP10 ?? 0,
    finiteDomain: BcdWallFiniteDomain(
      normal: proposal.normal,
      basisU: proposal.basisU,
      basisV: floorNormal,
      planeValue: proposal.planeValue,
      basisVOriginValue: floorPlaneValue,
      boundsU: proposal.boundsU,
      boundsV: proposal.boundsHeight,
    ),
    birthSupportXyz: birthSupportXyz,
  );

  static BcdWallCandidateMetrics _withStrict(
    BcdWallCandidateMetrics row,
    BcdWallStrictMetrics? strict,
  ) => BcdWallCandidateMetrics(
    candidateId: row.candidateId,
    thetaDeg: row.thetaDeg,
    planeValue: row.planeValue,
    sparseScore: row.sparseScore,
    sparseSupportPoints: row.sparseSupportPoints,
    accepted: row.accepted,
    coverageCells5cm: row.coverageCells5cm,
    medianNcc: row.medianNcc,
    nccP10: row.nccP10,
    incumbent: row.incumbent,
    strict: strict,
    finiteDomain: row.finiteDomain,
    birthSupportXyz: row.birthSupportXyz,
  );

  static List<BcdWallCandidateMetrics> _adjudicateLegacyAnchors(
    List<BcdWallCandidateMetrics> candidates,
    Set<String> legacyIds,
  ) => List.unmodifiable([
    for (final row in candidates)
      if (!row.incumbent || !legacyIds.contains(row.candidateId))
        row
      else if (row.accepted < 8 || row.coverageCells5cm < 8)
        _withIncumbent(row, false)
      else
        _withIncumbent(
          row,
          !candidates.any(
            (other) =>
                other.candidateId != row.candidateId &&
                legacyIds.contains(other.candidateId) &&
                other.accepted >= 8 &&
                other.coverageCells5cm >= 8 &&
                BcdFinalizeCoordinator.wallBirthSupportsCompete(row, other),
          ),
        ),
  ]);

  static BcdWallCandidateMetrics _withIncumbent(
    BcdWallCandidateMetrics row,
    bool incumbent,
  ) => BcdWallCandidateMetrics(
    candidateId: row.candidateId,
    thetaDeg: row.thetaDeg,
    planeValue: row.planeValue,
    sparseScore: row.sparseScore,
    sparseSupportPoints: row.sparseSupportPoints,
    accepted: row.accepted,
    coverageCells5cm: row.coverageCells5cm,
    medianNcc: row.medianNcc,
    nccP10: row.nccP10,
    incumbent: incumbent,
    strict: row.strict,
    finiteDomain: row.finiteDomain,
    birthSupportXyz: row.birthSupportXyz,
  );

  static Float32List _birthSupportXyz(List<BcdStructuralBirthResult> births) {
    final length = births.fold<int>(
      0,
      (sum, birth) => sum + birth.cloud.xyz.length,
    );
    final output = Float32List(length);
    var offset = 0;
    for (final birth in births) {
      output.setRange(offset, offset + birth.cloud.xyz.length, birth.cloud.xyz);
      offset += birth.cloud.xyz.length;
    }
    return output;
  }
}
