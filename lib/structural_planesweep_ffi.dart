// Shared structural-plane fitting + known-plane plane-sweep C ABI.
//
// The numerical implementation is C++/Dawn/WGSL and is shared by iOS,
// Android/HarmonyOS, and Web. Dart owns only background orchestration and
// lifetime. No platform-specific Swift algorithm lives here.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'aether_ffi.dart';

enum StructuralPlaneSweepResult {
  ok,
  badArguments,
  unsupported,
  gpuFailure,
  bufferTooSmall,
  internalFailure,
}

StructuralPlaneSweepResult _result(int code) {
  if (code < 0 || code >= StructuralPlaneSweepResult.values.length) {
    return StructuralPlaneSweepResult.internalFailure;
  }
  return StructuralPlaneSweepResult.values[code];
}

final class _FitOptions extends Struct {
  @Int32()
  external int maxWalls;
  @Int32()
  external int thetaStepDeg;
  @Double()
  external double minimumHeightM;
  @Double()
  external double wallFitBandM;
  @Double()
  external double rhoStepM;
  @Double()
  external double minimumTangentSpanM;
  @Double()
  external double minimumHeightSpanM;
  @Int32()
  external int preliminaryMinimumSupport;
  @Int32()
  external int certifiedMinimumSupport;
  @Int32()
  external int certifiedMinimumCells;
}

final class _Floor extends Struct {
  @Int32()
  external int certified;
  @Int32()
  external int supportPoints;
  @Int32()
  external int coverageCells10cm;
  @Array(3)
  external Array<Double> normalXyz;
  @Double()
  external double valueNDotX;
  @Double()
  external double rmsErrorM;
}

final class _FloorProposalOptions extends Struct {
  @Int32()
  external int maximumCandidates;
  @Double()
  external double histogramStepM;
  @Int32()
  external int minimumPeakSupport;
  @Double()
  external double refinementBandM;
  @Double()
  external double supportBandM;
  @Int32()
  external int minimumSupportPoints;
  @Int32()
  external int minimumCoverageCells10cm;
  @Double()
  external double maximumTiltDeg;
  @Double()
  external double minimumCameraClearanceM;
  @Double()
  external double distinctPlaneValueM;
}

final class _FloorProposal extends Struct {
  @Int32()
  external int proposalIndex;
  @Int32()
  external int supportPoints20mm;
  @Int32()
  external int coverageCells10cm;
  @Array(3)
  external Array<Double> normalXyz;
  @Double()
  external double valueNDotX;
  @Array(3)
  external Array<Double> basisUXyz;
  @Array(3)
  external Array<Double> basisVXyz;
  @Array(2)
  external Array<Double> boundsUM;
  @Array(2)
  external Array<Double> boundsVM;
  @Double()
  external double rmsErrorM;
  @Double()
  external double tiltDeg;
  @Double()
  external double priorScore;
}

final class _EnvelopeWallOptions extends Struct {
  @Int32()
  external int maximumCandidates;
  @Int32()
  external int thetaStepDeg;
  @Double()
  external double minimumHeightM;
  @Double()
  external double maximumHeightPercentile;
  @Double()
  external double rhoStepM;
  @Double()
  external double fitBandM;
  @Int32()
  external int minimumSupport;
  @Double()
  external double minimumTangentSpanM;
  @Double()
  external double minimumHeightSpanM;
  @Double()
  external double cameraCrossingToleranceM;
  @Int32()
  external int duplicateAngleDeg;
  @Double()
  external double duplicatePlaneValueM;
}

final class _EnvelopeWall extends Struct {
  @Int32()
  external int proposalIndex;
  @Int32()
  external int supportPoints35mm;
  @Int32()
  external int coverageCells10cm;
  @Double()
  external double thetaDeg;
  @Array(3)
  external Array<Double> normalXyz;
  @Array(3)
  external Array<Double> basisUXyz;
  @Array(3)
  external Array<Double> basisVXyz;
  @Double()
  external double planeValueNDotX;
  @Array(2)
  external Array<Double> boundsUM;
  @Array(2)
  external Array<Double> boundsHeightM;
  @Double()
  external double score;
  @Double()
  external double cameraDistanceMinM;
  @Double()
  external double cameraDistanceMaxM;
  @Double()
  external double cameraClearanceMinAbsM;
}

final class _Wall extends Struct {
  @Int32()
  external int wallIndex;
  @Int32()
  external int thetaDeg;
  @Int32()
  external int certified;
  @Int32()
  external int supportPoints35mm;
  @Int32()
  external int coverageCells10cm;
  @Int32()
  external int domainPoints;
  @Array(5)
  external Array<Int32> supportPoints20mm;
  @Array(5)
  external Array<Int32> supportCells10cm;
  @Array(3)
  external Array<Double> normalXyz;
  @Array(3)
  external Array<Double> basisUXyz;
  @Array(3)
  external Array<Double> basisVXyz;
  @Double()
  external double planeValueNDotX;
  @Array(2)
  external Array<Double> boundsUM;
  @Array(2)
  external Array<Double> boundsHeightM;
  @Double()
  external double score;
  @Double()
  external double supportProminenceVs5cm;
  @Double()
  external double coverageProminenceVs5cm;
}

final class _SessionOptions extends Struct {
  @Int32()
  external int pointCount;
  @Int32()
  external int candidateCount;
  @Int32()
  external int hypothesesPerCandidate;
  @Int32()
  external int patchN;
  @Int32()
  external int maxViews;
  @Int32()
  external int scaleCount;
  @Array(3)
  external Array<Float> basisUXyz;
  @Array(3)
  external Array<Float> basisVXyz;
}

final class _BirthOptions extends Struct {
  @Int32()
  external int minimumViews;
  @Float()
  external double nccMin;
  @Float()
  external double minimumParallaxDeg;
  @Float()
  external double uniqueDepthMargin;
  @Float()
  external double postMinNcc;
  @Int32()
  external int postMinimumViews;
  @Float()
  external double postMinimumParallaxDeg;
}

final class _CandidateResult extends Struct {
  @Int32()
  external int accepted;
  @Int32()
  external int supportingViews;
  @Float()
  external double medianNcc;
  @Float()
  external double maxParallaxDeg;
  @Float()
  external double observedDepthMargin;
}

final class _LocalManifoldOptions extends Struct {
  @Int32()
  external int neighbors;
  @Int32()
  external int partitionCount;
  @Int32()
  external int firstPartition;
  @Int32()
  external int secondPartition;
  @Double()
  external double maximumNearestM;
  @Double()
  external double maximumNeighborRadiusM;
  @Double()
  external double maximumNeighborRmsM;
  @Double()
  external double maximumPerpendicularM;
}

/// Mirrors `aether_reference_birth_certificate_result_t` exactly.
final class _ReferenceBirthCertificateResult extends Struct {
  @Uint32()
  external int failedFoldMask;
  @Int32()
  external int preCertificateBirthCount;
  @Int32()
  external int blockedBirthCount;
  @Int32()
  external int finalBirthCount;
}

final class _FiniteFloorDomain extends Struct {
  @Int32()
  external int certified;
  @Array(3)
  external Array<Double> normalXyz;
  @Array(3)
  external Array<Double> basisUXyz;
  @Array(3)
  external Array<Double> basisVXyz;
  @Double()
  external double planeValueNDotX;
  @Array(2)
  external Array<Double> boundsUM;
  @Array(2)
  external Array<Double> boundsVM;
}

typedef _FitDefaultC = Void Function(Pointer<_FitOptions>);
typedef _FitDefaultDart = void Function(Pointer<_FitOptions>);
typedef _FitFloorC =
    Int32 Function(Pointer<Float>, Int32, Pointer<Double>, Pointer<_Floor>);
typedef _FitFloorDart =
    int Function(Pointer<Float>, int, Pointer<Double>, Pointer<_Floor>);
typedef _FloorProposalDefaultC = Void Function(Pointer<_FloorProposalOptions>);
typedef _FloorProposalDefaultDart =
    void Function(Pointer<_FloorProposalOptions>);
typedef _ProposeFloorsC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Pointer<Double>,
      Double,
      Pointer<_FloorProposalOptions>,
      Pointer<_FloorProposal>,
      Int32,
      Pointer<Int32>,
    );
typedef _ProposeFloorsDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<Double>,
      double,
      Pointer<_FloorProposalOptions>,
      Pointer<_FloorProposal>,
      int,
      Pointer<Int32>,
    );
typedef _EnvelopeWallDefaultC = Void Function(Pointer<_EnvelopeWallOptions>);
typedef _EnvelopeWallDefaultDart = void Function(Pointer<_EnvelopeWallOptions>);
typedef _ProposeEnvelopeWallsC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Pointer<Double>,
      Int32,
      Pointer<Double>,
      Double,
      Pointer<_EnvelopeWallOptions>,
      Pointer<_EnvelopeWall>,
      Int32,
      Pointer<Int32>,
    );
typedef _ProposeEnvelopeWallsDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<Double>,
      int,
      Pointer<Double>,
      double,
      Pointer<_EnvelopeWallOptions>,
      Pointer<_EnvelopeWall>,
      int,
      Pointer<Int32>,
    );
typedef _FitWallsC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Pointer<Double>,
      Double,
      Pointer<_FitOptions>,
      Pointer<_Wall>,
      Int32,
      Pointer<Int32>,
    );
typedef _FitWallsDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<Double>,
      double,
      Pointer<_FitOptions>,
      Pointer<_Wall>,
      int,
      Pointer<Int32>,
    );
typedef _SessionDefaultC = Void Function(Pointer<_SessionOptions>);
typedef _SessionDefaultDart = void Function(Pointer<_SessionOptions>);
typedef _BirthDefaultC = Void Function(Pointer<_BirthOptions>);
typedef _BirthDefaultDart = void Function(Pointer<_BirthOptions>);
typedef _SessionCreateC =
    Int32 Function(
      Pointer<_SessionOptions>,
      Pointer<Float>,
      Pointer<Pointer<Void>>,
    );
typedef _SessionCreateDart =
    int Function(
      Pointer<_SessionOptions>,
      Pointer<Float>,
      Pointer<Pointer<Void>>,
    );
typedef _AddJpegViewC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int32,
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Float>,
      Float,
      Float,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _AddJpegViewDart =
    int Function(
      Pointer<Void>,
      int,
      int,
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Float>,
      double,
      double,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _AddJpegViewScalesC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Int32,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _AddJpegViewScalesDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      int,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _DecodeJpegImageC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _DecodeJpegImageDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _AddImageViewScalesC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Void>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Int32,
    );
typedef _AddImageViewScalesDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Void>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      int,
    );
typedef _ImageFreeC = Void Function(Pointer<Void>);
typedef _ImageFreeDart = void Function(Pointer<Void>);
typedef _SessionFinishC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<_BirthOptions>,
      Int32,
      Pointer<_CandidateResult>,
      Int32,
    );
typedef _SessionFinishDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<_BirthOptions>,
      int,
      Pointer<_CandidateResult>,
      int,
    );
typedef _SessionFinishRgbC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<_BirthOptions>,
      Int32,
      Pointer<_CandidateResult>,
      Int32,
      Pointer<Uint8>,
      Int32,
    );
typedef _SessionFinishRgbDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<_BirthOptions>,
      int,
      Pointer<_CandidateResult>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _SessionDebugReadbackC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Float>,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<Float>,
      Int32,
    );
typedef _SessionDebugReadbackDart =
    int Function(
      Pointer<Void>,
      Pointer<Float>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      int,
    );
typedef _SessionFreeC = Void Function(Pointer<Void>);
typedef _SessionFreeDart = void Function(Pointer<Void>);
typedef _LocalManifoldDefaultC = Void Function(Pointer<_LocalManifoldOptions>);
typedef _LocalManifoldDefaultDart =
    void Function(Pointer<_LocalManifoldOptions>);
typedef _LocalManifoldCreateC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Pointer<_LocalManifoldOptions>,
      Pointer<Pointer<Void>>,
    );
typedef _LocalManifoldCreateDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<_LocalManifoldOptions>,
      Pointer<Pointer<Void>>,
    );
typedef _LocalManifoldFilterC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Float>,
      Int32,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
    );
typedef _LocalManifoldFilterDart =
    int Function(
      Pointer<Void>,
      Pointer<Float>,
      int,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
    );
typedef _LocalManifoldFilterReferenceCertifiedC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Float>,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<_ReferenceBirthCertificateResult>,
    );
typedef _LocalManifoldFilterReferenceCertifiedDart =
    int Function(
      Pointer<Void>,
      Pointer<Float>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<_ReferenceBirthCertificateResult>,
    );
typedef _LocalManifoldFreeC = Void Function(Pointer<Void>);
typedef _LocalManifoldFreeDart = void Function(Pointer<Void>);
typedef _FiniteFloorOwnershipC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Pointer<_FiniteFloorDomain>,
      Double,
      Double,
      Pointer<Uint8>,
      Int32,
    );
typedef _FiniteFloorOwnershipDart =
    int Function(
      Pointer<Float>,
      int,
      Pointer<_FiniteFloorDomain>,
      double,
      double,
      Pointer<Uint8>,
      int,
    );
typedef _FiniteWallOwnershipC =
    Int32 Function(
      Pointer<Float>,
      Int32,
      Double,
      Pointer<_Wall>,
      Int32,
      Double,
      Double,
      Pointer<Uint8>,
      Int32,
    );
typedef _FiniteWallOwnershipDart =
    int Function(
      Pointer<Float>,
      int,
      double,
      Pointer<_Wall>,
      int,
      double,
      double,
      Pointer<Uint8>,
      int,
    );

class StructuralWall {
  const StructuralWall({
    required this.index,
    required this.thetaDeg,
    required this.certified,
    required this.supportPoints35mm,
    required this.coverageCells10cm,
    required this.domainPoints,
    required this.supportPoints20mm,
    required this.supportCells10cm,
    required this.normal,
    required this.basisU,
    required this.basisV,
    required this.planeValue,
    required this.boundsU,
    required this.boundsHeight,
    required this.score,
    required this.supportProminenceVs5cm,
    required this.coverageProminenceVs5cm,
  });

  final int index;
  final int thetaDeg;
  final bool certified;
  final int supportPoints35mm;
  final int coverageCells10cm;
  final int domainPoints;
  final List<int> supportPoints20mm;
  final List<int> supportCells10cm;
  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final List<double> boundsU;
  final List<double> boundsHeight;
  final double score;
  final double supportProminenceVs5cm;
  final double coverageProminenceVs5cm;
}

class StructuralFloor {
  const StructuralFloor({
    required this.certified,
    required this.supportPoints,
    required this.coverageCells10cm,
    required this.normal,
    required this.planeValue,
    required this.rmsErrorM,
  });

  final bool certified;
  final int supportPoints;
  final int coverageCells10cm;
  final List<double> normal;
  final double planeValue;
  final double rmsErrorM;
}

/// A proposal-only gravity-low plane. It has no point-birth authority until
/// B's multi-view unique-depth adjudication selects one decisive owner.
class StructuralFloorProposal {
  const StructuralFloorProposal({
    required this.index,
    required this.supportPoints20mm,
    required this.coverageCells10cm,
    required this.normal,
    required this.planeValue,
    required this.basisU,
    required this.basisV,
    required this.boundsU,
    required this.boundsV,
    required this.rmsErrorM,
    required this.tiltDeg,
    required this.priorScore,
  });

  final int index;
  final int supportPoints20mm;
  final int coverageCells10cm;
  final List<double> normal;
  final double planeValue;
  final List<double> basisU;
  final List<double> basisV;
  final List<double> boundsU;
  final List<double> boundsV;
  final double rmsErrorM;
  final double tiltDeg;
  final double priorScore;
}

/// Proposal-only wall generated from sparse support plus the complete camera
/// envelope. It can become a product wall only after B's multi-view owner
/// selector certifies one physical plane in its competing family.
class StructuralEnvelopeWallProposal {
  const StructuralEnvelopeWallProposal({
    required this.index,
    required this.supportPoints35mm,
    required this.coverageCells10cm,
    required this.thetaDeg,
    required this.normal,
    required this.basisU,
    required this.basisV,
    required this.planeValue,
    required this.boundsU,
    required this.boundsHeight,
    required this.score,
    required this.cameraDistanceMinM,
    required this.cameraDistanceMaxM,
    required this.cameraClearanceMinAbsM,
  });

  final int index;
  final int supportPoints35mm;
  final int coverageCells10cm;
  final double thetaDeg;
  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final List<double> boundsU;
  final List<double> boundsHeight;
  final double score;
  final double cameraDistanceMinM;
  final double cameraDistanceMaxM;
  final double cameraClearanceMinAbsM;
}

/// The finite floor selected by B's decisive image-only plane adjudication.
/// A sparse proposal alone must never set [certified] to true.
class StructuralFloorDomain {
  const StructuralFloorDomain({
    required this.certified,
    required this.normal,
    required this.basisU,
    required this.basisV,
    required this.planeValue,
    required this.boundsU,
    required this.boundsV,
  });

  final bool certified;
  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final List<double> boundsU;
  final List<double> boundsV;
}

class PlaneSweepBirthOptions {
  const PlaneSweepBirthOptions({
    this.minimumViews = 3,
    this.nccMin = 0.70,
    this.minimumParallaxDeg = 5.0,
    this.uniqueDepthMargin = 0.02,
    this.postMinNcc = 0,
    this.postMinimumViews = 0,
    this.postMinimumParallaxDeg = 0,
  });

  final int minimumViews;
  final double nccMin;
  final double minimumParallaxDeg;
  final double uniqueDepthMargin;
  final double postMinNcc;
  final int postMinimumViews;
  final double postMinimumParallaxDeg;
}

class PlaneSweepCandidateResult {
  const PlaneSweepCandidateResult({
    required this.accepted,
    required this.supportingViews,
    required this.medianNcc,
    required this.maxParallaxDeg,
    required this.observedDepthMargin,
  });

  final bool accepted;
  final int supportingViews;
  final double medianNcc;
  final double maxParallaxDeg;
  final double observedDepthMargin;
}

class PlaneSweepFinishResult {
  const PlaneSweepFinishResult({required this.candidates, required this.rgb});

  final List<PlaneSweepCandidateResult> candidates;

  /// Candidate-major RGB triplets. Rejected candidates are black.
  final Uint8List rgb;
}

class _NativeStructuralPlaneSweep {
  _NativeStructuralPlaneSweep._();

  static DynamicLibrary get _library => AetherFfi.resolveLibraryForBindings();

  static final _FitDefaultDart fitDefault = _library
      .lookupFunction<_FitDefaultC, _FitDefaultDart>(
        'aether_structural_plane_fit_options_default',
      );
  static final _FitFloorDart fitFloor = _library
      .lookupFunction<_FitFloorC, _FitFloorDart>('aether_structural_fit_floor');
  static final _FloorProposalDefaultDart floorProposalDefault = _library
      .lookupFunction<_FloorProposalDefaultC, _FloorProposalDefaultDart>(
        'aether_structural_floor_proposal_options_default',
      );
  static final _ProposeFloorsDart proposeFloors = _library
      .lookupFunction<_ProposeFloorsC, _ProposeFloorsDart>(
        'aether_structural_propose_floors',
      );
  static final _EnvelopeWallDefaultDart envelopeWallDefault = _library
      .lookupFunction<_EnvelopeWallDefaultC, _EnvelopeWallDefaultDart>(
        'aether_structural_envelope_wall_options_default',
      );
  static final _ProposeEnvelopeWallsDart proposeEnvelopeWalls = _library
      .lookupFunction<_ProposeEnvelopeWallsC, _ProposeEnvelopeWallsDart>(
        'aether_structural_propose_envelope_walls',
      );
  static final _FitWallsDart fitWalls = _library
      .lookupFunction<_FitWallsC, _FitWallsDart>('aether_structural_fit_walls');
  static final _SessionDefaultDart sessionDefault = _library
      .lookupFunction<_SessionDefaultC, _SessionDefaultDart>(
        'aether_planesweep_session_options_default',
      );
  static final _BirthDefaultDart birthDefault = _library
      .lookupFunction<_BirthDefaultC, _BirthDefaultDart>(
        'aether_planesweep_birth_options_default',
      );
  static final _SessionCreateDart sessionCreate = _library
      .lookupFunction<_SessionCreateC, _SessionCreateDart>(
        'aether_planesweep_session_create',
      );
  static final _AddJpegViewDart addJpegView = _library
      .lookupFunction<_AddJpegViewC, _AddJpegViewDart>(
        'aether_planesweep_session_add_jpeg_view',
      );
  static final _AddJpegViewScalesDart addJpegViewScales = _library
      .lookupFunction<_AddJpegViewScalesC, _AddJpegViewScalesDart>(
        'aether_planesweep_session_add_jpeg_view_scales',
      );
  static final _DecodeJpegImageDart decodeJpegImage = _library
      .lookupFunction<_DecodeJpegImageC, _DecodeJpegImageDart>(
        'aether_planesweep_image_decode_jpeg',
      );
  static final _AddImageViewScalesDart addImageViewScales = _library
      .lookupFunction<_AddImageViewScalesC, _AddImageViewScalesDart>(
        'aether_planesweep_session_add_image_view_scales',
      );
  static final _ImageFreeDart imageFree = _library
      .lookupFunction<_ImageFreeC, _ImageFreeDart>(
        'aether_planesweep_image_free',
      );
  static final _SessionFinishDart sessionFinish = _library
      .lookupFunction<_SessionFinishC, _SessionFinishDart>(
        'aether_planesweep_session_finish',
      );
  static final _SessionFinishRgbDart sessionFinishRgb = _library
      .lookupFunction<_SessionFinishRgbC, _SessionFinishRgbDart>(
        'aether_planesweep_session_finish_rgb',
      );
  static final _SessionDebugReadbackDart sessionDebugReadback = _library
      .lookupFunction<_SessionDebugReadbackC, _SessionDebugReadbackDart>(
        'aether_planesweep_session_debug_readback',
      );
  static final _SessionFreeDart sessionFree = _library
      .lookupFunction<_SessionFreeC, _SessionFreeDart>(
        'aether_planesweep_session_free',
      );
  static final _LocalManifoldDefaultDart localManifoldDefault = _library
      .lookupFunction<_LocalManifoldDefaultC, _LocalManifoldDefaultDart>(
        'aether_local_manifold_options_default',
      );
  static final _LocalManifoldCreateDart localManifoldCreate = _library
      .lookupFunction<_LocalManifoldCreateC, _LocalManifoldCreateDart>(
        'aether_local_manifold_session_create',
      );
  static final _LocalManifoldFilterDart localManifoldFilter = _library
      .lookupFunction<_LocalManifoldFilterC, _LocalManifoldFilterDart>(
        'aether_local_manifold_session_filter',
      );
  static final _LocalManifoldFilterReferenceCertifiedDart
  localManifoldFilterReferenceCertified = _library
      .lookupFunction<
        _LocalManifoldFilterReferenceCertifiedC,
        _LocalManifoldFilterReferenceCertifiedDart
      >('aether_local_manifold_session_filter_reference_certified');
  static final _LocalManifoldFreeDart localManifoldFree = _library
      .lookupFunction<_LocalManifoldFreeC, _LocalManifoldFreeDart>(
        'aether_local_manifold_session_free',
      );
  static final _FiniteFloorOwnershipDart finiteFloorOwnership = _library
      .lookupFunction<_FiniteFloorOwnershipC, _FiniteFloorOwnershipDart>(
        'aether_filter_finite_floor_ownership',
      );
  static final _FiniteWallOwnershipDart finiteWallOwnership = _library
      .lookupFunction<_FiniteWallOwnershipC, _FiniteWallOwnershipDart>(
        'aether_filter_finite_wall_ownership',
      );
}

class StructuralPlaneFit {
  StructuralPlaneFit._();

  static StructuralFloor fitFloor({
    required Float32List xyz,
    List<double> upHint = const [0, 1, 0],
  }) {
    if (xyz.length < 300 || xyz.length % 3 != 0 || upHint.length != 3) {
      throw ArgumentError(
        'fitFloor requires >=100 XYZ points and a 3D up hint',
      );
    }
    final xyzPtr = malloc<Float>(xyz.length);
    final upPtr = malloc<Double>(3);
    final floor = malloc<_Floor>();
    try {
      xyzPtr.asTypedList(xyz.length).setAll(0, xyz);
      upPtr.asTypedList(3).setAll(0, upHint);
      final rc = _NativeStructuralPlaneSweep.fitFloor(
        xyzPtr,
        xyz.length ~/ 3,
        upPtr,
        floor,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError('aether_structural_fit_floor failed: ${_result(rc)}');
      }
      return StructuralFloor(
        certified: floor.ref.certified != 0,
        supportPoints: floor.ref.supportPoints,
        coverageCells10cm: floor.ref.coverageCells10cm,
        normal: [for (var i = 0; i < 3; i++) floor.ref.normalXyz[i]],
        planeValue: floor.ref.valueNDotX,
        rmsErrorM: floor.ref.rmsErrorM,
      );
    } finally {
      malloc.free(xyzPtr);
      malloc.free(upPtr);
      malloc.free(floor);
    }
  }

  static List<StructuralFloorProposal> proposeFloors({
    required Float32List xyz,
    required double minimumCameraHeight,
    List<double> upHint = const [0, 1, 0],
    int maximumCandidates = 16,
  }) {
    if (xyz.length < 300 ||
        xyz.length % 3 != 0 ||
        upHint.length != 3 ||
        !minimumCameraHeight.isFinite ||
        maximumCandidates <= 0) {
      throw ArgumentError(
        'proposeFloors requires >=100 XYZ points, a finite camera bound, '
        'a 3D up hint, and positive capacity',
      );
    }
    final xyzPtr = malloc<Float>(xyz.length);
    final upPtr = malloc<Double>(3);
    final options = malloc<_FloorProposalOptions>();
    final count = malloc<Int32>();
    Pointer<_FloorProposal> proposals = nullptr;
    try {
      xyzPtr.asTypedList(xyz.length).setAll(0, xyz);
      upPtr.asTypedList(3).setAll(0, upHint);
      _NativeStructuralPlaneSweep.floorProposalDefault(options);
      options.ref.maximumCandidates = maximumCandidates;
      proposals = malloc<_FloorProposal>(maximumCandidates);
      count.value = 0;
      final rc = _NativeStructuralPlaneSweep.proposeFloors(
        xyzPtr,
        xyz.length ~/ 3,
        upPtr,
        minimumCameraHeight,
        options,
        proposals,
        maximumCandidates,
        count,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_structural_propose_floors failed: ${_result(rc)}',
        );
      }
      return List.unmodifiable([
        for (var index = 0; index < count.value; index++)
          _floorProposalFromNative(proposals[index]),
      ]);
    } finally {
      malloc.free(xyzPtr);
      malloc.free(upPtr);
      malloc.free(options);
      malloc.free(count);
      if (proposals != nullptr) malloc.free(proposals);
    }
  }

  static StructuralFloorProposal _floorProposalFromNative(
    _FloorProposal proposal,
  ) => StructuralFloorProposal(
    index: proposal.proposalIndex,
    supportPoints20mm: proposal.supportPoints20mm,
    coverageCells10cm: proposal.coverageCells10cm,
    normal: [for (var i = 0; i < 3; i++) proposal.normalXyz[i]],
    planeValue: proposal.valueNDotX,
    basisU: [for (var i = 0; i < 3; i++) proposal.basisUXyz[i]],
    basisV: [for (var i = 0; i < 3; i++) proposal.basisVXyz[i]],
    boundsU: [for (var i = 0; i < 2; i++) proposal.boundsUM[i]],
    boundsV: [for (var i = 0; i < 2; i++) proposal.boundsVM[i]],
    rmsErrorM: proposal.rmsErrorM,
    tiltDeg: proposal.tiltDeg,
    priorScore: proposal.priorScore,
  );

  static List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List xyz,
    required Float64List cameraCentersXyz,
    required List<double> floorNormal,
    required double floorValue,
    int maximumCandidates = 64,
  }) {
    if (xyz.length < 300 ||
        xyz.length % 3 != 0 ||
        cameraCentersXyz.length < 9 ||
        cameraCentersXyz.length % 3 != 0 ||
        floorNormal.length != 3 ||
        !floorValue.isFinite ||
        floorNormal.any((value) => !value.isFinite) ||
        cameraCentersXyz.any((value) => !value.isFinite) ||
        maximumCandidates <= 0) {
      throw ArgumentError(
        'proposeEnvelopeWalls requires >=100 XYZ points, >=3 finite camera '
        'centers, a finite floor, and positive capacity',
      );
    }
    final xyzPtr = malloc<Float>(xyz.length);
    final camerasPtr = malloc<Double>(cameraCentersXyz.length);
    final normalPtr = malloc<Double>(3);
    final options = malloc<_EnvelopeWallOptions>();
    final count = malloc<Int32>();
    Pointer<_EnvelopeWall> walls = nullptr;
    try {
      xyzPtr.asTypedList(xyz.length).setAll(0, xyz);
      camerasPtr
          .asTypedList(cameraCentersXyz.length)
          .setAll(0, cameraCentersXyz);
      normalPtr.asTypedList(3).setAll(0, floorNormal);
      _NativeStructuralPlaneSweep.envelopeWallDefault(options);
      options.ref.maximumCandidates = maximumCandidates;
      walls = malloc<_EnvelopeWall>(maximumCandidates);
      count.value = 0;
      final rc = _NativeStructuralPlaneSweep.proposeEnvelopeWalls(
        xyzPtr,
        xyz.length ~/ 3,
        camerasPtr,
        cameraCentersXyz.length ~/ 3,
        normalPtr,
        floorValue,
        options,
        walls,
        maximumCandidates,
        count,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_structural_propose_envelope_walls failed: ${_result(rc)}',
        );
      }
      return List.unmodifiable([
        for (var index = 0; index < count.value; index++)
          _envelopeWallFromNative(walls[index]),
      ]);
    } finally {
      malloc.free(xyzPtr);
      malloc.free(camerasPtr);
      malloc.free(normalPtr);
      malloc.free(options);
      malloc.free(count);
      if (walls != nullptr) malloc.free(walls);
    }
  }

  static StructuralEnvelopeWallProposal _envelopeWallFromNative(
    _EnvelopeWall wall,
  ) => StructuralEnvelopeWallProposal(
    index: wall.proposalIndex,
    supportPoints35mm: wall.supportPoints35mm,
    coverageCells10cm: wall.coverageCells10cm,
    thetaDeg: wall.thetaDeg,
    normal: [for (var i = 0; i < 3; i++) wall.normalXyz[i]],
    basisU: [for (var i = 0; i < 3; i++) wall.basisUXyz[i]],
    basisV: [for (var i = 0; i < 3; i++) wall.basisVXyz[i]],
    planeValue: wall.planeValueNDotX,
    boundsU: [for (var i = 0; i < 2; i++) wall.boundsUM[i]],
    boundsHeight: [for (var i = 0; i < 2; i++) wall.boundsHeightM[i]],
    score: wall.score,
    cameraDistanceMinM: wall.cameraDistanceMinM,
    cameraDistanceMaxM: wall.cameraDistanceMaxM,
    cameraClearanceMinAbsM: wall.cameraClearanceMinAbsM,
  );

  static List<StructuralWall> fitWalls({
    required Float32List xyz,
    required List<double> floorNormal,
    required double floorValue,
    int maxWalls = 6,
  }) {
    if (xyz.length < 300 || xyz.length % 3 != 0 || floorNormal.length != 3) {
      throw ArgumentError('fitWalls requires >=100 XYZ points and a 3D normal');
    }
    final pointCount = xyz.length ~/ 3;
    final xyzPtr = malloc<Float>(xyz.length);
    final normalPtr = malloc<Double>(3);
    final options = malloc<_FitOptions>();
    final count = malloc<Int32>();
    Pointer<_Wall> walls = nullptr;
    try {
      xyzPtr.asTypedList(xyz.length).setAll(0, xyz);
      normalPtr.asTypedList(3).setAll(0, floorNormal);
      _NativeStructuralPlaneSweep.fitDefault(options);
      options.ref.maxWalls = maxWalls;
      walls = malloc<_Wall>(maxWalls);
      count.value = 0;
      final rc = _NativeStructuralPlaneSweep.fitWalls(
        xyzPtr,
        pointCount,
        normalPtr,
        floorValue,
        options,
        walls,
        maxWalls,
        count,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError('aether_structural_fit_walls failed: ${_result(rc)}');
      }
      return [
        for (var index = 0; index < count.value; index++)
          _wallFromNative(walls[index]),
      ];
    } finally {
      malloc.free(xyzPtr);
      malloc.free(normalPtr);
      malloc.free(options);
      malloc.free(count);
      if (walls != nullptr) malloc.free(walls);
    }
  }

  static StructuralWall _wallFromNative(_Wall wall) => StructuralWall(
    index: wall.wallIndex,
    thetaDeg: wall.thetaDeg,
    certified: wall.certified != 0,
    supportPoints35mm: wall.supportPoints35mm,
    coverageCells10cm: wall.coverageCells10cm,
    domainPoints: wall.domainPoints,
    supportPoints20mm: [for (var i = 0; i < 5; i++) wall.supportPoints20mm[i]],
    supportCells10cm: [for (var i = 0; i < 5; i++) wall.supportCells10cm[i]],
    normal: [for (var i = 0; i < 3; i++) wall.normalXyz[i]],
    basisU: [for (var i = 0; i < 3; i++) wall.basisUXyz[i]],
    basisV: [for (var i = 0; i < 3; i++) wall.basisVXyz[i]],
    planeValue: wall.planeValueNDotX,
    boundsU: [for (var i = 0; i < 2; i++) wall.boundsUM[i]],
    boundsHeight: [for (var i = 0; i < 2; i++) wall.boundsHeightM[i]],
    score: wall.score,
    supportProminenceVs5cm: wall.supportProminenceVs5cm,
    coverageProminenceVs5cm: wall.coverageProminenceVs5cm,
  );
}

/// One decoded source image shared across a bounded wave of tile sessions.
///
/// The native object owns the exact STB-decoded RGBA bytes and one lazy Dawn
/// upload. Product orchestration keeps only one instance alive at a time, so
/// repeated tiles stop decoding/uploading the same JPEG without turning the
/// capture into an unbounded image cache.
class StructuralPlaneSweepImage {
  StructuralPlaneSweepImage._(this._image, this.width, this.height);

  Pointer<Void> _image;
  final int width;
  final int height;

  static StructuralPlaneSweepImage decodeJpeg(String jpegPath) {
    if (jpegPath.isEmpty) {
      throw ArgumentError.value(jpegPath, 'jpegPath', 'must not be empty');
    }
    final path = jpegPath.toNativeUtf8();
    final out = malloc<Pointer<Void>>();
    final width = malloc<Int32>();
    final height = malloc<Int32>();
    try {
      out.value = nullptr;
      final rc = _NativeStructuralPlaneSweep.decodeJpegImage(
        path,
        out,
        width,
        height,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok ||
          out.value == nullptr ||
          width.value <= 1 ||
          height.value <= 1) {
        if (out.value != nullptr) {
          _NativeStructuralPlaneSweep.imageFree(out.value);
        }
        throw StateError(
          'aether_planesweep JPEG image decode failed: ${_result(rc)}',
        );
      }
      return StructuralPlaneSweepImage._(out.value, width.value, height.value);
    } finally {
      malloc.free(path);
      malloc.free(out);
      malloc.free(width);
      malloc.free(height);
    }
  }

  void dispose() {
    if (_image == nullptr) return;
    _NativeStructuralPlaneSweep.imageFree(_image);
    _image = nullptr;
  }

  void _checkLive() {
    if (_image == nullptr) {
      throw StateError('plane-sweep image disposed');
    }
  }
}

class StructuralPlaneSweepSession {
  StructuralPlaneSweepSession._(
    this._session,
    this.candidateCount,
    this.hypothesesPerCandidate,
    this.patchN,
    this.maxViews,
    this.scaleCount,
  );

  Pointer<Void> _session;
  final int candidateCount;
  final int hypothesesPerCandidate;
  final int patchN;
  final int maxViews;
  final int scaleCount;

  static StructuralPlaneSweepSession create({
    required Float32List pointsXyz,
    required int candidateCount,
    required int hypothesesPerCandidate,
    required int patchN,
    required int maxViews,
    required int scaleCount,
    required List<double> basisU,
    required List<double> basisV,
  }) {
    final expected = candidateCount * hypothesesPerCandidate * 3;
    if (pointsXyz.length != expected ||
        basisU.length != 3 ||
        basisV.length != 3 ||
        patchN <= 0 ||
        maxViews <= 0 ||
        scaleCount <= 0) {
      throw ArgumentError('invalid plane-sweep session dimensions');
    }
    final options = malloc<_SessionOptions>();
    final points = malloc<Float>(pointsXyz.length);
    final out = malloc<Pointer<Void>>();
    try {
      _NativeStructuralPlaneSweep.sessionDefault(options);
      options.ref
        ..pointCount = pointsXyz.length ~/ 3
        ..candidateCount = candidateCount
        ..hypothesesPerCandidate = hypothesesPerCandidate
        ..patchN = patchN
        ..maxViews = maxViews
        ..scaleCount = scaleCount;
      for (var i = 0; i < 3; i++) {
        options.ref.basisUXyz[i] = basisU[i];
        options.ref.basisVXyz[i] = basisV[i];
      }
      points.asTypedList(pointsXyz.length).setAll(0, pointsXyz);
      out.value = nullptr;
      final rc = _NativeStructuralPlaneSweep.sessionCreate(
        options,
        points,
        out,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok ||
          out.value == nullptr) {
        throw StateError(
          'aether_planesweep_session_create failed: ${_result(rc)}',
        );
      }
      return StructuralPlaneSweepSession._(
        out.value,
        candidateCount,
        hypothesesPerCandidate,
        patchN,
        maxViews,
        scaleCount,
      );
    } finally {
      malloc.free(options);
      malloc.free(points);
      malloc.free(out);
    }
  }

  /// Read back shader intermediates for deterministic backend-parity tests.
  /// Product finalize never calls this method.
  ({Float32List normalized, Uint8List valid, Float32List stddevU8})
  debugReadback() {
    _checkLive();
    final pointCount = candidateCount * hypothesesPerCandidate;
    final slotCount = scaleCount * maxViews;
    final normalizedCount = slotCount * pointCount * patchN * patchN;
    final valueCount = slotCount * pointCount;
    final normalized = malloc<Float>(normalizedCount);
    final valid = malloc<Uint8>(valueCount);
    final stddev = malloc<Float>(valueCount);
    try {
      final rc = _NativeStructuralPlaneSweep.sessionDebugReadback(
        _session,
        normalized,
        normalizedCount,
        valid,
        valueCount,
        stddev,
        valueCount,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_planesweep debug readback failed: ${_result(rc)}',
        );
      }
      return (
        normalized: Float32List.fromList(
          normalized.asTypedList(normalizedCount),
        ),
        valid: Uint8List.fromList(valid.asTypedList(valueCount)),
        stddevU8: Float32List.fromList(stddev.asTypedList(valueCount)),
      );
    } finally {
      malloc.free(normalized);
      malloc.free(valid);
      malloc.free(stddev);
    }
  }

  ({int width, int height}) addJpegView({
    required int scaleIndex,
    required int viewIndex,
    required String jpegPath,
    required Float32List projection3x4,
    required Float32List cameraCenter,
    required double patchRadiusM,
    double minimumStdU8 = 6,
  }) {
    _checkLive();
    if (projection3x4.length != 12 || cameraCenter.length != 3) {
      throw ArgumentError(
        'projection must be 3x4 and camera center must be 3D',
      );
    }
    final path = jpegPath.toNativeUtf8();
    final projection = malloc<Float>(12);
    final center = malloc<Float>(3);
    final width = malloc<Int32>();
    final height = malloc<Int32>();
    try {
      projection.asTypedList(12).setAll(0, projection3x4);
      center.asTypedList(3).setAll(0, cameraCenter);
      final rc = _NativeStructuralPlaneSweep.addJpegView(
        _session,
        scaleIndex,
        viewIndex,
        path,
        projection,
        center,
        patchRadiusM,
        minimumStdU8,
        width,
        height,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError('aether_planesweep add JPEG failed: ${_result(rc)}');
      }
      return (width: width.value, height: height.value);
    } finally {
      malloc.free(path);
      malloc.free(projection);
      malloc.free(center);
      malloc.free(width);
      malloc.free(height);
    }
  }

  /// Decodes [jpegPath] once and submits the same pixels to every quality
  /// scale. Numerical scoring is identical to repeated [addJpegView] calls;
  /// only redundant JPEG decode work is removed.
  ({int width, int height}) addJpegViewAllScales({
    required int viewIndex,
    required String jpegPath,
    required Float32List projection3x4,
    required Float32List cameraCenter,
    required List<double> patchRadiusMByScale,
    required List<double> minimumStdU8ByScale,
  }) {
    _checkLive();
    if (projection3x4.length != 12 ||
        cameraCenter.length != 3 ||
        patchRadiusMByScale.length != scaleCount ||
        minimumStdU8ByScale.length != scaleCount ||
        patchRadiusMByScale.any((value) => !value.isFinite || value <= 0) ||
        minimumStdU8ByScale.any((value) => !value.isFinite || value <= 0)) {
      throw ArgumentError('invalid multi-scale JPEG plane-sweep input');
    }
    final path = jpegPath.toNativeUtf8();
    final projection = malloc<Float>(12);
    final center = malloc<Float>(3);
    final patchRadii = malloc<Float>(scaleCount);
    final minimumStd = malloc<Float>(scaleCount);
    final width = malloc<Int32>();
    final height = malloc<Int32>();
    try {
      projection.asTypedList(12).setAll(0, projection3x4);
      center.asTypedList(3).setAll(0, cameraCenter);
      patchRadii.asTypedList(scaleCount).setAll(0, patchRadiusMByScale);
      minimumStd.asTypedList(scaleCount).setAll(0, minimumStdU8ByScale);
      final rc = _NativeStructuralPlaneSweep.addJpegViewScales(
        _session,
        viewIndex,
        path,
        projection,
        center,
        patchRadii,
        minimumStd,
        scaleCount,
        width,
        height,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_planesweep add multi-scale JPEG failed: ${_result(rc)}',
        );
      }
      return (width: width.value, height: height.value);
    } finally {
      malloc.free(path);
      malloc.free(projection);
      malloc.free(center);
      malloc.free(patchRadii);
      malloc.free(minimumStd);
      malloc.free(width);
      malloc.free(height);
    }
  }

  /// Feeds an already decoded/uploaded image to this tile session.
  ///
  /// A bounded batch runner can call this on several sessions before disposing
  /// [image]. The image bytes and GPU buffer are shared; every tile still owns
  /// its independent points, masks, patch tensors, and finish result.
  void addImageViewAllScales({
    required int viewIndex,
    required StructuralPlaneSweepImage image,
    required Float32List projection3x4,
    required Float32List cameraCenter,
    required List<double> patchRadiusMByScale,
    required List<double> minimumStdU8ByScale,
  }) {
    _checkLive();
    image._checkLive();
    if (projection3x4.length != 12 ||
        cameraCenter.length != 3 ||
        patchRadiusMByScale.length != scaleCount ||
        minimumStdU8ByScale.length != scaleCount ||
        patchRadiusMByScale.any((value) => !value.isFinite || value <= 0) ||
        minimumStdU8ByScale.any((value) => !value.isFinite || value <= 0)) {
      throw ArgumentError('invalid shared-image plane-sweep input');
    }
    final projection = malloc<Float>(12);
    final center = malloc<Float>(3);
    final patchRadii = malloc<Float>(scaleCount);
    final minimumStd = malloc<Float>(scaleCount);
    try {
      projection.asTypedList(12).setAll(0, projection3x4);
      center.asTypedList(3).setAll(0, cameraCenter);
      patchRadii.asTypedList(scaleCount).setAll(0, patchRadiusMByScale);
      minimumStd.asTypedList(scaleCount).setAll(0, minimumStdU8ByScale);
      final rc = _NativeStructuralPlaneSweep.addImageViewScales(
        _session,
        viewIndex,
        image._image,
        projection,
        center,
        patchRadii,
        minimumStd,
        scaleCount,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_planesweep add shared image failed: ${_result(rc)}',
        );
      }
    } finally {
      malloc.free(projection);
      malloc.free(center);
      malloc.free(patchRadii);
      malloc.free(minimumStd);
    }
  }

  List<PlaneSweepCandidateResult> finish({
    required Uint8List candidateViewMasks,
    required List<PlaneSweepBirthOptions> scales,
  }) {
    _checkLive();
    final pointCount = candidateCount * hypothesesPerCandidate;
    final expectedMasks = scaleCount * pointCount * maxViews;
    if (scales.length != scaleCount ||
        candidateViewMasks.length != expectedMasks) {
      throw ArgumentError(
        'plane-sweep scale/mask dimensions do not match session',
      );
    }
    final masks = malloc<Uint8>(candidateViewMasks.length);
    final options = malloc<_BirthOptions>(scaleCount);
    final results = malloc<_CandidateResult>(candidateCount);
    try {
      masks
          .asTypedList(candidateViewMasks.length)
          .setAll(0, candidateViewMasks);
      for (var index = 0; index < scaleCount; index++) {
        _NativeStructuralPlaneSweep.birthDefault(options + index);
        final source = scales[index];
        (options + index).ref
          ..minimumViews = source.minimumViews
          ..nccMin = source.nccMin
          ..minimumParallaxDeg = source.minimumParallaxDeg
          ..uniqueDepthMargin = source.uniqueDepthMargin
          ..postMinNcc = source.postMinNcc
          ..postMinimumViews = source.postMinimumViews
          ..postMinimumParallaxDeg = source.postMinimumParallaxDeg;
      }
      final rc = _NativeStructuralPlaneSweep.sessionFinish(
        _session,
        masks,
        options,
        scaleCount,
        results,
        candidateCount,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_planesweep_session_finish failed: ${_result(rc)}',
        );
      }
      return [
        for (var index = 0; index < candidateCount; index++)
          PlaneSweepCandidateResult(
            accepted: results[index].accepted != 0,
            supportingViews: results[index].supportingViews,
            medianNcc: results[index].medianNcc,
            maxParallaxDeg: results[index].maxParallaxDeg,
            observedDepthMargin: results[index].observedDepthMargin,
          ),
      ];
    } finally {
      malloc.free(masks);
      malloc.free(options);
      malloc.free(results);
    }
  }

  PlaneSweepFinishResult finishWithRgb({
    required Uint8List candidateViewMasks,
    required List<PlaneSweepBirthOptions> scales,
  }) {
    _checkLive();
    final pointCount = candidateCount * hypothesesPerCandidate;
    final expectedMasks = scaleCount * pointCount * maxViews;
    if (scales.length != scaleCount ||
        candidateViewMasks.length != expectedMasks) {
      throw ArgumentError(
        'plane-sweep scale/mask dimensions do not match session',
      );
    }
    final masks = malloc<Uint8>(candidateViewMasks.length);
    final options = malloc<_BirthOptions>(scaleCount);
    final results = malloc<_CandidateResult>(candidateCount);
    final rgb = malloc<Uint8>(candidateCount * 3);
    try {
      masks
          .asTypedList(candidateViewMasks.length)
          .setAll(0, candidateViewMasks);
      for (var index = 0; index < scaleCount; index++) {
        _NativeStructuralPlaneSweep.birthDefault(options + index);
        final source = scales[index];
        (options + index).ref
          ..minimumViews = source.minimumViews
          ..nccMin = source.nccMin
          ..minimumParallaxDeg = source.minimumParallaxDeg
          ..uniqueDepthMargin = source.uniqueDepthMargin
          ..postMinNcc = source.postMinNcc
          ..postMinimumViews = source.postMinimumViews
          ..postMinimumParallaxDeg = source.postMinimumParallaxDeg;
      }
      final rc = _NativeStructuralPlaneSweep.sessionFinishRgb(
        _session,
        masks,
        options,
        scaleCount,
        results,
        candidateCount,
        rgb,
        candidateCount * 3,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_planesweep_session_finish_rgb failed: ${_result(rc)}',
        );
      }
      return PlaneSweepFinishResult(
        candidates: [
          for (var index = 0; index < candidateCount; index++)
            PlaneSweepCandidateResult(
              accepted: results[index].accepted != 0,
              supportingViews: results[index].supportingViews,
              medianNcc: results[index].medianNcc,
              maxParallaxDeg: results[index].maxParallaxDeg,
              observedDepthMargin: results[index].observedDepthMargin,
            ),
        ],
        rgb: Uint8List.fromList(rgb.asTypedList(candidateCount * 3)),
      );
    } finally {
      malloc.free(masks);
      malloc.free(options);
      malloc.free(results);
      malloc.free(rgb);
    }
  }

  void dispose() {
    if (_session == nullptr) return;
    _NativeStructuralPlaneSweep.sessionFree(_session);
    _session = nullptr;
  }

  void _checkLive() {
    if (_session == nullptr) throw StateError('plane-sweep session disposed');
  }
}

class LocalManifoldBirthOptions {
  const LocalManifoldBirthOptions({
    this.neighbors = 8,
    this.partitionCount = 3,
    this.firstPartition = 0,
    this.secondPartition = 1,
    this.maximumNearestM = 0.12,
    this.maximumNeighborRadiusM = 0.25,
    this.maximumNeighborRmsM = 0.03,
    this.maximumPerpendicularM = 0.02,
  });

  final int neighbors;
  final int partitionCount;
  final int firstPartition;
  final int secondPartition;
  final double maximumNearestM;
  final double maximumNeighborRadiusM;
  final double maximumNeighborRmsM;
  final double maximumPerpendicularM;
}

class BirthOwnershipResult {
  const BirthOwnershipResult({
    required this.inputEligible,
    required this.floorOwned,
    required this.wallOwned,
    required this.structuralOwned,
    required this.firstPartitionSupport,
    required this.secondPartitionSupport,
    required this.born,
  });

  final Uint8List inputEligible;
  final Uint8List floorOwned;
  final Uint8List wallOwned;
  final Uint8List structuralOwned;
  final Uint8List firstPartitionSupport;
  final Uint8List secondPartitionSupport;
  final Uint8List born;
}

/// Result of D's per-reference three-fold quality certificate.
///
/// [failedFoldMask] uses bit N for the fold whose blind truth is sparse
/// partition N. A reference with no eligible births is a valid certified
/// result; in that case every count is zero and [born] is all zero.
class ReferenceBirthCertificateResult {
  const ReferenceBirthCertificateResult({
    required this.failedFoldMask,
    required this.preCertificateBirthCount,
    required this.blockedBirthCount,
    required this.finalBirthCount,
    required this.born,
  });

  final int failedFoldMask;
  final int preCertificateBirthCount;
  final int blockedBirthCount;
  final int finalBirthCount;
  final Uint8List born;

  bool get certified => failedFoldMask == 0;
}

/// Single-source product result for B structural ownership followed by D's
/// per-reference certificate. [born] is exactly [certificate.born]; it is not
/// recomputed in Dart or copied from the legacy two-partition filter.
class ReferenceCertifiedBirthOwnershipResult {
  const ReferenceCertifiedBirthOwnershipResult({
    required this.inputEligible,
    required this.floorOwned,
    required this.wallOwned,
    required this.structuralOwned,
    required this.certificate,
  });

  final Uint8List inputEligible;
  final Uint8List floorOwned;
  final Uint8List wallOwned;
  final Uint8List structuralOwned;
  final ReferenceBirthCertificateResult certificate;

  Uint8List get born => certificate.born;
}

/// Capture-scoped D birth coordinator. The shared C++ core owns finite floor
/// and wall exclusion plus dual-partition local-manifold numerics; Dart owns
/// only the capture lifetime and ordered batch calls.
class LocalManifoldBirthSession {
  LocalManifoldBirthSession._(this._session);

  Pointer<Void> _session;

  static LocalManifoldBirthSession create({
    required Float32List sparseXyz,
    LocalManifoldBirthOptions options = const LocalManifoldBirthOptions(),
  }) {
    if (sparseXyz.length % 3 != 0 ||
        sparseXyz.any((value) => !value.isFinite) ||
        sparseXyz.length < options.neighbors * options.partitionCount * 3 ||
        options.neighbors < 3 ||
        options.neighbors > 64 ||
        options.partitionCount != 3 ||
        options.firstPartition < 0 ||
        options.secondPartition < 0 ||
        options.firstPartition >= options.partitionCount ||
        options.secondPartition >= options.partitionCount ||
        options.firstPartition == options.secondPartition ||
        !options.maximumNearestM.isFinite ||
        options.maximumNearestM <= 0 ||
        !options.maximumNeighborRadiusM.isFinite ||
        options.maximumNeighborRadiusM < options.maximumNearestM ||
        !options.maximumNeighborRmsM.isFinite ||
        options.maximumNeighborRmsM < 0 ||
        !options.maximumPerpendicularM.isFinite ||
        options.maximumPerpendicularM < 0) {
      throw ArgumentError('invalid local-manifold birth options or sparse XYZ');
    }
    final sparse = malloc<Float>(sparseXyz.length);
    final nativeOptions = malloc<_LocalManifoldOptions>();
    final out = malloc<Pointer<Void>>();
    try {
      sparse.asTypedList(sparseXyz.length).setAll(0, sparseXyz);
      _NativeStructuralPlaneSweep.localManifoldDefault(nativeOptions);
      nativeOptions.ref
        ..neighbors = options.neighbors
        ..partitionCount = options.partitionCount
        ..firstPartition = options.firstPartition
        ..secondPartition = options.secondPartition
        ..maximumNearestM = options.maximumNearestM
        ..maximumNeighborRadiusM = options.maximumNeighborRadiusM
        ..maximumNeighborRmsM = options.maximumNeighborRmsM
        ..maximumPerpendicularM = options.maximumPerpendicularM;
      out.value = nullptr;
      final rc = _NativeStructuralPlaneSweep.localManifoldCreate(
        sparse,
        sparseXyz.length ~/ 3,
        nativeOptions,
        out,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok ||
          out.value == nullptr) {
        throw StateError(
          'aether_local_manifold_session_create failed: ${_result(rc)}',
        );
      }
      return LocalManifoldBirthSession._(out.value);
    } finally {
      malloc.free(sparse);
      malloc.free(nativeOptions);
      malloc.free(out);
    }
  }

  BirthOwnershipResult filter({
    required Float32List candidateXyz,
    required double floorValue,
    required List<StructuralWall> certifiedWalls,
    Uint8List? candidateEligible,
    StructuralFloorDomain? selectedFloor,
    double floorSlabM = 0.08,
    double floorDomainMarginM = 0.05,
    double wallSlabM = 0.08,
    double wallDomainMarginM = 0.05,
  }) {
    _checkLive();
    if (candidateXyz.length % 3 != 0 ||
        (candidateEligible != null &&
            (candidateEligible.length != candidateXyz.length ~/ 3 ||
                candidateEligible.any((value) => value > 1))) ||
        !floorValue.isFinite ||
        !floorSlabM.isFinite ||
        floorSlabM <= 0 ||
        !floorDomainMarginM.isFinite ||
        floorDomainMarginM < 0 ||
        !wallSlabM.isFinite ||
        wallSlabM <= 0 ||
        !wallDomainMarginM.isFinite ||
        wallDomainMarginM < 0 ||
        certifiedWalls.any(
          (wall) =>
              wall.normal.length != 3 ||
              wall.basisU.length != 3 ||
              wall.basisV.length != 3 ||
              wall.boundsU.length != 2 ||
              wall.boundsHeight.length != 2 ||
              wall.supportPoints20mm.length != 5 ||
              wall.supportCells10cm.length != 5,
        ) ||
        (selectedFloor != null &&
            (selectedFloor.normal.length != 3 ||
                selectedFloor.basisU.length != 3 ||
                selectedFloor.basisV.length != 3 ||
                selectedFloor.boundsU.length != 2 ||
                selectedFloor.boundsV.length != 2 ||
                !selectedFloor.planeValue.isFinite ||
                selectedFloor.normal.any((value) => !value.isFinite) ||
                selectedFloor.basisU.any((value) => !value.isFinite) ||
                selectedFloor.basisV.any((value) => !value.isFinite) ||
                selectedFloor.boundsU.any((value) => !value.isFinite) ||
                selectedFloor.boundsV.any((value) => !value.isFinite)))) {
      throw ArgumentError('invalid structural birth ownership input');
    }
    final count = candidateXyz.length ~/ 3;
    if (count == 0) {
      return BirthOwnershipResult(
        inputEligible: Uint8List(0),
        floorOwned: Uint8List(0),
        wallOwned: Uint8List(0),
        structuralOwned: Uint8List(0),
        firstPartitionSupport: Uint8List(0),
        secondPartitionSupport: Uint8List(0),
        born: Uint8List(0),
      );
    }
    final candidates = malloc<Float>(candidateXyz.length);
    final walls = certifiedWalls.isEmpty
        ? nullptr.cast<_Wall>()
        : malloc<_Wall>(certifiedWalls.length);
    final floor = selectedFloor == null
        ? nullptr.cast<_FiniteFloorDomain>()
        : malloc<_FiniteFloorDomain>();
    final floorOwned = calloc<Uint8>(count);
    final wallOwned = calloc<Uint8>(count);
    final structuralOwned = calloc<Uint8>(count);
    final eligible = malloc<Uint8>(count);
    final first = calloc<Uint8>(count);
    final second = calloc<Uint8>(count);
    final born = calloc<Uint8>(count);
    try {
      candidates.asTypedList(candidateXyz.length).setAll(0, candidateXyz);
      for (var index = 0; index < certifiedWalls.length; index++) {
        final source = certifiedWalls[index];
        final target = walls[index];
        target
          ..wallIndex = source.index
          ..thetaDeg = source.thetaDeg
          ..certified = source.certified ? 1 : 0
          ..supportPoints35mm = source.supportPoints35mm
          ..coverageCells10cm = source.coverageCells10cm
          ..domainPoints = source.domainPoints
          ..planeValueNDotX = source.planeValue
          ..score = source.score
          ..supportProminenceVs5cm = source.supportProminenceVs5cm
          ..coverageProminenceVs5cm = source.coverageProminenceVs5cm;
        for (var axis = 0; axis < 5; axis++) {
          target.supportPoints20mm[axis] = source.supportPoints20mm[axis];
          target.supportCells10cm[axis] = source.supportCells10cm[axis];
        }
        for (var axis = 0; axis < 3; axis++) {
          target.normalXyz[axis] = source.normal[axis];
          target.basisUXyz[axis] = source.basisU[axis];
          target.basisVXyz[axis] = source.basisV[axis];
        }
        for (var axis = 0; axis < 2; axis++) {
          target.boundsUM[axis] = source.boundsU[axis];
          target.boundsHeightM[axis] = source.boundsHeight[axis];
        }
      }
      if (selectedFloor != null) {
        floor.ref
          ..certified = selectedFloor.certified ? 1 : 0
          ..planeValueNDotX = selectedFloor.planeValue;
        for (var axis = 0; axis < 3; axis++) {
          floor.ref.normalXyz[axis] = selectedFloor.normal[axis];
          floor.ref.basisUXyz[axis] = selectedFloor.basisU[axis];
          floor.ref.basisVXyz[axis] = selectedFloor.basisV[axis];
        }
        for (var axis = 0; axis < 2; axis++) {
          floor.ref.boundsUM[axis] = selectedFloor.boundsU[axis];
          floor.ref.boundsVM[axis] = selectedFloor.boundsV[axis];
        }
        final floorRc = _NativeStructuralPlaneSweep.finiteFloorOwnership(
          candidates,
          count,
          floor,
          floorSlabM,
          floorDomainMarginM,
          floorOwned,
          count,
        );
        if (_result(floorRc) != StructuralPlaneSweepResult.ok) {
          throw StateError(
            'aether_filter_finite_floor_ownership failed: '
            '${_result(floorRc)}',
          );
        }
      }
      var rc = _NativeStructuralPlaneSweep.finiteWallOwnership(
        candidates,
        count,
        floorValue,
        walls,
        certifiedWalls.length,
        wallSlabM,
        wallDomainMarginM,
        wallOwned,
        count,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_filter_finite_wall_ownership failed: ${_result(rc)}',
        );
      }
      final floorOwnedView = floorOwned.asTypedList(count);
      final wallOwnedView = wallOwned.asTypedList(count);
      final structuralOwnedView = structuralOwned.asTypedList(count);
      final eligibleView = eligible.asTypedList(count);
      if (floorOwnedView.any((value) => value > 1) ||
          wallOwnedView.any((value) => value > 1)) {
        throw StateError(
          'native structural ownership returned a non-binary mask',
        );
      }
      for (var index = 0; index < count; index++) {
        final owned = floorOwnedView[index] != 0 || wallOwnedView[index] != 0;
        structuralOwnedView[index] = owned ? 1 : 0;
        final inputAllows =
            candidateEligible == null || candidateEligible[index] != 0;
        eligibleView[index] = inputAllows && !owned ? 1 : 0;
      }
      rc = _NativeStructuralPlaneSweep.localManifoldFilter(
        _session,
        candidates,
        count,
        eligible,
        first,
        second,
        born,
        count,
      );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_local_manifold_session_filter failed: ${_result(rc)}',
        );
      }
      return BirthOwnershipResult(
        inputEligible: Uint8List.fromList(
          candidateEligible ?? Uint8List.fromList(List.filled(count, 1)),
        ),
        floorOwned: Uint8List.fromList(floorOwnedView),
        wallOwned: Uint8List.fromList(wallOwnedView),
        structuralOwned: Uint8List.fromList(structuralOwnedView),
        firstPartitionSupport: Uint8List.fromList(first.asTypedList(count)),
        secondPartitionSupport: Uint8List.fromList(second.asTypedList(count)),
        born: Uint8List.fromList(born.asTypedList(count)),
      );
    } finally {
      malloc.free(candidates);
      if (certifiedWalls.isNotEmpty) malloc.free(walls);
      if (selectedFloor != null) malloc.free(floor);
      calloc.free(floorOwned);
      calloc.free(wallOwned);
      calloc.free(structuralOwned);
      malloc.free(eligible);
      calloc.free(first);
      calloc.free(second);
      calloc.free(born);
    }
  }

  /// Product single-entry path: compute B's finite structural ownership and
  /// then run D's three-fold reference certificate exactly once.
  ///
  /// This deliberately does not call [filter], because doing so would run the
  /// legacy two-partition local-manifold gate before running the complete
  /// certificate a second time. [born] in the result is therefore the sole
  /// publication truth returned by the certificate.
  ReferenceCertifiedBirthOwnershipResult
  filterReferenceCertifiedWithStructuralOwnership({
    required Float32List candidateXyz,
    required double floorValue,
    required List<StructuralWall> certifiedWalls,
    Uint8List? candidateEligible,
    StructuralFloorDomain? selectedFloor,
    int productionFold = 2,
    double floorSlabM = 0.08,
    double floorDomainMarginM = 0.05,
    double wallSlabM = 0.08,
    double wallDomainMarginM = 0.05,
  }) {
    _checkLive();
    final count = candidateXyz.length ~/ 3;
    bool finiteList(List<double> values) =>
        values.every((value) => value.isFinite);
    if (candidateXyz.length % 3 != 0 ||
        candidateXyz.any((value) => !value.isFinite) ||
        productionFold < 0 ||
        productionFold >= 3 ||
        (candidateEligible != null &&
            (candidateEligible.length != count ||
                candidateEligible.any((value) => value > 1))) ||
        !floorValue.isFinite ||
        !floorSlabM.isFinite ||
        floorSlabM <= 0 ||
        !floorDomainMarginM.isFinite ||
        floorDomainMarginM < 0 ||
        !wallSlabM.isFinite ||
        wallSlabM <= 0 ||
        !wallDomainMarginM.isFinite ||
        wallDomainMarginM < 0 ||
        certifiedWalls.any(
          (wall) =>
              wall.normal.length != 3 ||
              wall.basisU.length != 3 ||
              wall.basisV.length != 3 ||
              wall.boundsU.length != 2 ||
              wall.boundsHeight.length != 2 ||
              wall.supportPoints20mm.length != 5 ||
              wall.supportCells10cm.length != 5 ||
              !finiteList(wall.normal) ||
              !finiteList(wall.basisU) ||
              !finiteList(wall.basisV) ||
              !finiteList(wall.boundsU) ||
              !finiteList(wall.boundsHeight) ||
              !wall.planeValue.isFinite ||
              !wall.score.isFinite ||
              !wall.supportProminenceVs5cm.isFinite ||
              !wall.coverageProminenceVs5cm.isFinite,
        ) ||
        (selectedFloor != null &&
            (selectedFloor.normal.length != 3 ||
                selectedFloor.basisU.length != 3 ||
                selectedFloor.basisV.length != 3 ||
                selectedFloor.boundsU.length != 2 ||
                selectedFloor.boundsV.length != 2 ||
                !selectedFloor.planeValue.isFinite ||
                !finiteList(selectedFloor.normal) ||
                !finiteList(selectedFloor.basisU) ||
                !finiteList(selectedFloor.basisV) ||
                !finiteList(selectedFloor.boundsU) ||
                !finiteList(selectedFloor.boundsV)))) {
      throw ArgumentError(
        'invalid reference-certified structural ownership input',
      );
    }
    if (count == 0) {
      final certificate = ReferenceBirthCertificateResult(
        failedFoldMask: 0,
        preCertificateBirthCount: 0,
        blockedBirthCount: 0,
        finalBirthCount: 0,
        born: Uint8List(0),
      );
      return ReferenceCertifiedBirthOwnershipResult(
        inputEligible: Uint8List(0),
        floorOwned: Uint8List(0),
        wallOwned: Uint8List(0),
        structuralOwned: Uint8List(0),
        certificate: certificate,
      );
    }

    final candidates = malloc<Float>(candidateXyz.length);
    final walls = certifiedWalls.isEmpty
        ? nullptr.cast<_Wall>()
        : malloc<_Wall>(certifiedWalls.length);
    final floor = selectedFloor == null
        ? nullptr.cast<_FiniteFloorDomain>()
        : malloc<_FiniteFloorDomain>();
    final floorOwned = calloc<Uint8>(count);
    final wallOwned = calloc<Uint8>(count);
    final structuralOwned = calloc<Uint8>(count);
    final eligible = malloc<Uint8>(count);
    try {
      candidates.asTypedList(candidateXyz.length).setAll(0, candidateXyz);
      for (var index = 0; index < certifiedWalls.length; index++) {
        final source = certifiedWalls[index];
        final target = walls[index];
        target
          ..wallIndex = source.index
          ..thetaDeg = source.thetaDeg
          ..certified = source.certified ? 1 : 0
          ..supportPoints35mm = source.supportPoints35mm
          ..coverageCells10cm = source.coverageCells10cm
          ..domainPoints = source.domainPoints
          ..planeValueNDotX = source.planeValue
          ..score = source.score
          ..supportProminenceVs5cm = source.supportProminenceVs5cm
          ..coverageProminenceVs5cm = source.coverageProminenceVs5cm;
        for (var axis = 0; axis < 5; axis++) {
          target.supportPoints20mm[axis] = source.supportPoints20mm[axis];
          target.supportCells10cm[axis] = source.supportCells10cm[axis];
        }
        for (var axis = 0; axis < 3; axis++) {
          target.normalXyz[axis] = source.normal[axis];
          target.basisUXyz[axis] = source.basisU[axis];
          target.basisVXyz[axis] = source.basisV[axis];
        }
        for (var axis = 0; axis < 2; axis++) {
          target.boundsUM[axis] = source.boundsU[axis];
          target.boundsHeightM[axis] = source.boundsHeight[axis];
        }
      }
      if (selectedFloor != null) {
        floor.ref
          ..certified = selectedFloor.certified ? 1 : 0
          ..planeValueNDotX = selectedFloor.planeValue;
        for (var axis = 0; axis < 3; axis++) {
          floor.ref.normalXyz[axis] = selectedFloor.normal[axis];
          floor.ref.basisUXyz[axis] = selectedFloor.basisU[axis];
          floor.ref.basisVXyz[axis] = selectedFloor.basisV[axis];
        }
        for (var axis = 0; axis < 2; axis++) {
          floor.ref.boundsUM[axis] = selectedFloor.boundsU[axis];
          floor.ref.boundsVM[axis] = selectedFloor.boundsV[axis];
        }
        final floorRc = _NativeStructuralPlaneSweep.finiteFloorOwnership(
          candidates,
          count,
          floor,
          floorSlabM,
          floorDomainMarginM,
          floorOwned,
          count,
        );
        if (_result(floorRc) != StructuralPlaneSweepResult.ok) {
          throw StateError(
            'aether_filter_finite_floor_ownership failed: '
            '${_result(floorRc)} (native rc=$floorRc)',
          );
        }
      }
      final wallRc = _NativeStructuralPlaneSweep.finiteWallOwnership(
        candidates,
        count,
        floorValue,
        walls,
        certifiedWalls.length,
        wallSlabM,
        wallDomainMarginM,
        wallOwned,
        count,
      );
      if (_result(wallRc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_filter_finite_wall_ownership failed: '
          '${_result(wallRc)} (native rc=$wallRc)',
        );
      }

      final floorOwnedView = floorOwned.asTypedList(count);
      final wallOwnedView = wallOwned.asTypedList(count);
      final structuralOwnedView = structuralOwned.asTypedList(count);
      final eligibleView = eligible.asTypedList(count);
      if (floorOwnedView.any((value) => value > 1) ||
          wallOwnedView.any((value) => value > 1)) {
        throw StateError(
          'native structural ownership returned a non-binary mask',
        );
      }
      for (var index = 0; index < count; index++) {
        final owned = floorOwnedView[index] != 0 || wallOwnedView[index] != 0;
        structuralOwnedView[index] = owned ? 1 : 0;
        final inputAllows =
            candidateEligible == null || candidateEligible[index] != 0;
        eligibleView[index] = inputAllows && !owned ? 1 : 0;
      }
      final certificate = _filterReferenceCertifiedNative(
        candidates: candidates,
        count: count,
        eligible: eligible,
        productionFold: productionFold,
      );
      return ReferenceCertifiedBirthOwnershipResult(
        inputEligible: candidateEligible == null
            ? (Uint8List(count)..fillRange(0, count, 1))
            : Uint8List.fromList(candidateEligible),
        floorOwned: Uint8List.fromList(floorOwnedView),
        wallOwned: Uint8List.fromList(wallOwnedView),
        structuralOwned: Uint8List.fromList(structuralOwnedView),
        certificate: certificate,
      );
    } finally {
      malloc.free(candidates);
      if (certifiedWalls.isNotEmpty) malloc.free(walls);
      if (selectedFloor != null) malloc.free(floor);
      calloc.free(floorOwned);
      calloc.free(wallOwned);
      calloc.free(structuralOwned);
      malloc.free(eligible);
    }
  }

  /// Applies the complete three-fold quality certificate before any D
  /// candidate receives product point identity.
  ///
  /// [candidateEligible] is the upstream D eligibility mask. A one in
  /// [structuralOwned] means B owns that candidate, so Dart combines the two
  /// masks into `candidateEligible && !structuralOwned` before the single C
  /// ABI call. [productionFold] is the blind fold used for production and
  /// must be 0, 1, or 2. The session itself owns the three immutable sparse
  /// partitions and the local-manifold options supplied to [create].
  ReferenceBirthCertificateResult filterReferenceCertified({
    required Float32List candidateXyz,
    required int productionFold,
    Uint8List? candidateEligible,
    Uint8List? structuralOwned,
  }) {
    _checkLive();
    final count = candidateXyz.length ~/ 3;
    if (candidateXyz.length % 3 != 0 ||
        candidateXyz.any((value) => !value.isFinite) ||
        productionFold < 0 ||
        productionFold >= 3 ||
        (candidateEligible != null &&
            (candidateEligible.length != count ||
                candidateEligible.any((value) => value > 1))) ||
        (structuralOwned != null &&
            (structuralOwned.length != count ||
                structuralOwned.any((value) => value > 1)))) {
      throw ArgumentError('invalid reference-certificate input');
    }
    if (count == 0) {
      return ReferenceBirthCertificateResult(
        failedFoldMask: 0,
        preCertificateBirthCount: 0,
        blockedBirthCount: 0,
        finalBirthCount: 0,
        born: Uint8List(0),
      );
    }

    final candidates = malloc<Float>(candidateXyz.length);
    final eligible = malloc<Uint8>(count);
    try {
      candidates.asTypedList(candidateXyz.length).setAll(0, candidateXyz);
      final eligibleView = eligible.asTypedList(count);
      for (var index = 0; index < count; index++) {
        final upstreamAllows =
            candidateEligible == null || candidateEligible[index] != 0;
        final ownedByStructural =
            structuralOwned != null && structuralOwned[index] != 0;
        eligibleView[index] = upstreamAllows && !ownedByStructural ? 1 : 0;
      }
      return _filterReferenceCertifiedNative(
        candidates: candidates,
        count: count,
        eligible: eligible,
        productionFold: productionFold,
      );
    } finally {
      malloc.free(candidates);
      malloc.free(eligible);
    }
  }

  ReferenceBirthCertificateResult _filterReferenceCertifiedNative({
    required Pointer<Float> candidates,
    required int count,
    required Pointer<Uint8> eligible,
    required int productionFold,
  }) {
    final born = calloc<Uint8>(count);
    final nativeResult = calloc<_ReferenceBirthCertificateResult>();
    try {
      final rc =
          _NativeStructuralPlaneSweep.localManifoldFilterReferenceCertified(
            _session,
            candidates,
            count,
            eligible,
            productionFold,
            born,
            count,
            nativeResult,
          );
      if (_result(rc) != StructuralPlaneSweepResult.ok) {
        throw StateError(
          'aether_local_manifold_session_filter_reference_certified failed: '
          '${_result(rc)} (native rc=$rc)',
        );
      }

      final failedFoldMask = nativeResult.ref.failedFoldMask;
      final preCertificateBirthCount =
          nativeResult.ref.preCertificateBirthCount;
      final blockedBirthCount = nativeResult.ref.blockedBirthCount;
      final finalBirthCount = nativeResult.ref.finalBirthCount;
      final bornList = Uint8List.fromList(born.asTypedList(count));
      var bornCount = 0;
      var binaryBirthMask = true;
      for (final value in bornList) {
        if (value > 1) binaryBirthMask = false;
        if (value != 0) bornCount++;
      }
      final structurallyValid =
          failedFoldMask & ~0x7 == 0 &&
          preCertificateBirthCount >= 0 &&
          preCertificateBirthCount <= count &&
          blockedBirthCount >= 0 &&
          blockedBirthCount <= preCertificateBirthCount &&
          finalBirthCount >= 0 &&
          finalBirthCount <= preCertificateBirthCount &&
          binaryBirthMask &&
          bornCount == finalBirthCount &&
          (failedFoldMask == 0
              ? blockedBirthCount == 0 &&
                    finalBirthCount == preCertificateBirthCount
              : blockedBirthCount == preCertificateBirthCount &&
                    finalBirthCount == 0);
      if (!structurallyValid) {
        throw StateError(
          'aether reference-certificate returned an inconsistent result: '
          'failedFoldMask=$failedFoldMask, '
          'pre=$preCertificateBirthCount, blocked=$blockedBirthCount, '
          'final=$finalBirthCount, born=$bornCount',
        );
      }
      return ReferenceBirthCertificateResult(
        failedFoldMask: failedFoldMask,
        preCertificateBirthCount: preCertificateBirthCount,
        blockedBirthCount: blockedBirthCount,
        finalBirthCount: finalBirthCount,
        born: bornList,
      );
    } finally {
      calloc.free(born);
      calloc.free(nativeResult);
    }
  }

  void dispose() {
    if (_session == nullptr) return;
    _NativeStructuralPlaneSweep.localManifoldFree(_session);
    _session = nullptr;
  }

  void _checkLive() {
    if (_session == nullptr) {
      throw StateError('local-manifold birth session disposed');
    }
  }
}
