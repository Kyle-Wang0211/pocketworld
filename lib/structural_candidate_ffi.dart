// Cross-platform structural candidate preparation C ABI.
//
// Grid construction, competing depths, projection visibility, and view
// selection live in shared C++. Dart only validates buffers and groups the
// returned deterministic plan into background plane-sweep batches.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'aether_ffi.dart';

enum StructuralViewMode { perPoint, perTile }

final class _GridSpec extends Struct {
  @Array(3)
  external Array<Double> normalXyz;
  @Array(3)
  external Array<Double> basisUXyz;
  @Array(3)
  external Array<Double> basisVXyz;
  @Double()
  external double planeValueNDotX;
  @Double()
  external double basisVOriginValue;
  @Double()
  external double uMin;
  @Double()
  external double uMax;
  @Double()
  external double vMin;
  @Double()
  external double vMax;
  @Double()
  external double gridM;
}

final class _Frame extends Struct {
  @Array(12)
  external Array<Double> projection3x4;
  @Array(3)
  external Array<Double> cameraCenter;
  @Int32()
  external int width;
  @Int32()
  external int height;
}

final class _ViewOptions extends Struct {
  @Int32()
  external int maximumViews;
  @Double()
  external double imageMarginPx;
  @Double()
  external double maximumGrazeDeg;
  @Int32()
  external int mode;
}

typedef _ViewDefaultC = Void Function(Pointer<_ViewOptions>);
typedef _ViewDefaultDart = void Function(Pointer<_ViewOptions>);
typedef _GridCountC = Int32 Function(Pointer<_GridSpec>, Pointer<Int32>);
typedef _GridCountDart = int Function(Pointer<_GridSpec>, Pointer<Int32>);
typedef _GridBuildC =
    Int32 Function(
      Pointer<_GridSpec>,
      Pointer<Double>,
      Int32,
      Pointer<Double>,
      Int32,
      Pointer<Double>,
      Int32,
    );
typedef _GridBuildDart =
    int Function(
      Pointer<_GridSpec>,
      Pointer<Double>,
      int,
      Pointer<Double>,
      int,
      Pointer<Double>,
      int,
    );
typedef _PrepareViewsC =
    Int32 Function(
      Pointer<Double>,
      Int32,
      Pointer<Double>,
      Int32,
      Pointer<_Frame>,
      Int32,
      Pointer<Double>,
      Pointer<_ViewOptions>,
      Pointer<Uint8>,
      Int32,
      Pointer<Int32>,
      Int32,
      Pointer<Int32>,
      Int32,
    );
typedef _PrepareViewsDart =
    int Function(
      Pointer<Double>,
      int,
      Pointer<Double>,
      int,
      Pointer<_Frame>,
      int,
      Pointer<Double>,
      Pointer<_ViewOptions>,
      Pointer<Uint8>,
      int,
      Pointer<Int32>,
      int,
      Pointer<Int32>,
      int,
    );

class StructuralCandidateGridSpec {
  const StructuralCandidateGridSpec({
    required this.normal,
    required this.basisU,
    required this.basisV,
    required this.planeValue,
    required this.basisVOriginValue,
    required this.boundsU,
    required this.boundsV,
    required this.gridM,
  });

  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final double basisVOriginValue;
  final List<double> boundsU;
  final List<double> boundsV;
  final double gridM;
}

class StructuralCandidateFrame {
  const StructuralCandidateFrame({
    required this.projection3x4,
    required this.cameraCenter,
    required this.width,
    required this.height,
  });

  final Float64List projection3x4;
  final Float64List cameraCenter;
  final int width;
  final int height;
}

class StructuralPreparedGrid {
  const StructuralPreparedGrid({
    required this.centersXyz,
    required this.pointsXyz,
    required this.candidateCount,
    required this.hypothesesPerCandidate,
  });

  final Float64List centersXyz;
  final Float64List pointsXyz;
  final int candidateCount;
  final int hypothesesPerCandidate;

  Float32List get pointsXyzFloat32 => Float32List.fromList(pointsXyz);
}

class StructuralPreparedViews {
  const StructuralPreparedViews({
    required this.hypothesisVisibility,
    required this.selectedViewIndices,
    required this.frameCount,
  });

  /// Point-major, then frame-major.
  final Uint8List hypothesisVisibility;
  final List<List<int>> selectedViewIndices;
  final int frameCount;
}

class _NativeStructuralCandidate {
  _NativeStructuralCandidate._();

  static DynamicLibrary get _library => AetherFfi.resolveLibraryForBindings();

  static final _ViewDefaultDart viewDefault = _library
      .lookupFunction<_ViewDefaultC, _ViewDefaultDart>(
        'aether_structural_view_options_default',
      );
  static final _GridCountDart gridCount = _library
      .lookupFunction<_GridCountC, _GridCountDart>(
        'aether_structural_grid_count',
      );
  static final _GridBuildDart gridBuild = _library
      .lookupFunction<_GridBuildC, _GridBuildDart>(
        'aether_structural_grid_build',
      );
  static final _PrepareViewsDart prepareViews = _library
      .lookupFunction<_PrepareViewsC, _PrepareViewsDart>(
        'aether_structural_prepare_views',
      );
}

class StructuralCandidatePreparation {
  StructuralCandidatePreparation._();

  static StructuralPreparedGrid buildGrid({
    required StructuralCandidateGridSpec spec,
    required List<double> depthOffsetsM,
  }) {
    _validateSpec(spec);
    if (depthOffsetsM.isEmpty ||
        depthOffsetsM.first.abs() > 1e-12 ||
        depthOffsetsM.any((value) => !value.isFinite)) {
      throw ArgumentError('depth offsets must be finite and start at zero');
    }
    final nativeSpec = malloc<_GridSpec>();
    final count = malloc<Int32>();
    final offsets = malloc<Double>(depthOffsetsM.length);
    try {
      _writeSpec(nativeSpec.ref, spec);
      var rc = _NativeStructuralCandidate.gridCount(nativeSpec, count);
      if (rc != 0 || count.value <= 0) {
        throw StateError('aether structural grid count failed: $rc');
      }
      offsets.asTypedList(depthOffsetsM.length).setAll(0, depthOffsetsM);
      final centers = malloc<Double>(count.value * 3);
      final points = malloc<Double>(count.value * depthOffsetsM.length * 3);
      try {
        rc = _NativeStructuralCandidate.gridBuild(
          nativeSpec,
          offsets,
          depthOffsetsM.length,
          centers,
          count.value * 3,
          points,
          count.value * depthOffsetsM.length * 3,
        );
        if (rc != 0) {
          throw StateError('aether structural grid build failed: $rc');
        }
        return StructuralPreparedGrid(
          centersXyz: Float64List.fromList(
            centers.asTypedList(count.value * 3),
          ),
          pointsXyz: Float64List.fromList(
            points.asTypedList(count.value * depthOffsetsM.length * 3),
          ),
          candidateCount: count.value,
          hypothesesPerCandidate: depthOffsetsM.length,
        );
      } finally {
        malloc.free(centers);
        malloc.free(points);
      }
    } finally {
      malloc.free(nativeSpec);
      malloc.free(count);
      malloc.free(offsets);
    }
  }

  static StructuralPreparedViews prepareViews({
    required StructuralPreparedGrid grid,
    required List<StructuralCandidateFrame> frames,
    required List<double> normal,
    required int maximumViews,
    required StructuralViewMode mode,
    double imageMarginPx = 2,
    double maximumGrazeDeg = 72,
  }) {
    if (grid.candidateCount <= 0 ||
        grid.centersXyz.length != grid.candidateCount * 3 ||
        grid.pointsXyz.length !=
            grid.candidateCount * grid.hypothesesPerCandidate * 3 ||
        frames.isEmpty ||
        maximumViews <= 0 ||
        maximumViews > frames.length ||
        normal.length != 3 ||
        normal.any((value) => !value.isFinite) ||
        !imageMarginPx.isFinite ||
        imageMarginPx < 0 ||
        !maximumGrazeDeg.isFinite ||
        maximumGrazeDeg <= 0 ||
        maximumGrazeDeg >= 90 ||
        frames.any(
          (frame) =>
              frame.projection3x4.length != 12 ||
              frame.cameraCenter.length != 3 ||
              frame.width <= 0 ||
              frame.height <= 0 ||
              frame.projection3x4.any((value) => !value.isFinite) ||
              frame.cameraCenter.any((value) => !value.isFinite),
        )) {
      throw ArgumentError('invalid structural view preparation input');
    }
    final centers = malloc<Double>(grid.centersXyz.length);
    final points = malloc<Double>(grid.pointsXyz.length);
    final nativeFrames = malloc<_Frame>(frames.length);
    final nativeNormal = malloc<Double>(3);
    final options = malloc<_ViewOptions>();
    final pointCount = grid.pointsXyz.length ~/ 3;
    final visibility = malloc<Uint8>(pointCount * frames.length);
    final selected = malloc<Int32>(grid.candidateCount * maximumViews);
    final selectedCounts = malloc<Int32>(grid.candidateCount);
    try {
      centers.asTypedList(grid.centersXyz.length).setAll(0, grid.centersXyz);
      points.asTypedList(grid.pointsXyz.length).setAll(0, grid.pointsXyz);
      nativeNormal.asTypedList(3).setAll(0, normal);
      for (var frameIndex = 0; frameIndex < frames.length; frameIndex++) {
        final source = frames[frameIndex];
        final target = (nativeFrames + frameIndex).ref;
        for (var index = 0; index < 12; index++) {
          target.projection3x4[index] = source.projection3x4[index];
        }
        for (var index = 0; index < 3; index++) {
          target.cameraCenter[index] = source.cameraCenter[index];
        }
        target
          ..width = source.width
          ..height = source.height;
      }
      _NativeStructuralCandidate.viewDefault(options);
      options.ref
        ..maximumViews = maximumViews
        ..imageMarginPx = imageMarginPx
        ..maximumGrazeDeg = maximumGrazeDeg
        ..mode = mode.index;
      final rc = _NativeStructuralCandidate.prepareViews(
        centers,
        grid.candidateCount,
        points,
        pointCount,
        nativeFrames,
        frames.length,
        nativeNormal,
        options,
        visibility,
        pointCount * frames.length,
        selected,
        grid.candidateCount * maximumViews,
        selectedCounts,
        grid.candidateCount,
      );
      if (rc != 0) {
        throw StateError('aether structural prepare views failed: $rc');
      }
      final selectedRows = <List<int>>[];
      for (var candidate = 0; candidate < grid.candidateCount; candidate++) {
        final count = selectedCounts[candidate];
        if (count < 0 || count > maximumViews) {
          throw StateError('native structural view count is invalid: $count');
        }
        selectedRows.add(
          List<int>.unmodifiable([
            for (var index = 0; index < count; index++)
              selected[candidate * maximumViews + index],
          ]),
        );
      }
      return StructuralPreparedViews(
        hypothesisVisibility: Uint8List.fromList(
          visibility.asTypedList(pointCount * frames.length),
        ),
        selectedViewIndices: List.unmodifiable(selectedRows),
        frameCount: frames.length,
      );
    } finally {
      malloc.free(centers);
      malloc.free(points);
      malloc.free(nativeFrames);
      malloc.free(nativeNormal);
      malloc.free(options);
      malloc.free(visibility);
      malloc.free(selected);
      malloc.free(selectedCounts);
    }
  }

  static void _validateSpec(StructuralCandidateGridSpec spec) {
    final vectors = [spec.normal, spec.basisU, spec.basisV];
    if (vectors.any(
          (vector) =>
              vector.length != 3 || vector.any((value) => !value.isFinite),
        ) ||
        !spec.planeValue.isFinite ||
        !spec.basisVOriginValue.isFinite ||
        spec.boundsU.length != 2 ||
        spec.boundsV.length != 2 ||
        spec.boundsU.any((value) => !value.isFinite) ||
        spec.boundsV.any((value) => !value.isFinite) ||
        spec.boundsU[1] < spec.boundsU[0] ||
        spec.boundsV[1] < spec.boundsV[0] ||
        !spec.gridM.isFinite ||
        spec.gridM <= 0) {
      throw ArgumentError('invalid structural candidate grid');
    }
  }

  static void _writeSpec(_GridSpec target, StructuralCandidateGridSpec source) {
    for (var index = 0; index < 3; index++) {
      target.normalXyz[index] = source.normal[index];
      target.basisUXyz[index] = source.basisU[index];
      target.basisVXyz[index] = source.basisV[index];
    }
    target
      ..planeValueNDotX = source.planeValue
      ..basisVOriginValue = source.basisVOriginValue
      ..uMin = source.boundsU[0]
      ..uMax = source.boundsU[1]
      ..vMin = source.boundsV[0]
      ..vMax = source.boundsV[1]
      ..gridM = source.gridM;
  }
}
