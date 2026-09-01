// CubeScene — milestone 1 of the REAL 3D cube (thermion / Filament).
// A single cube auto-rotating on a dark stage, to prove the render pipeline
// (viewer + geometry + camera + per-frame transform) works on device. UI
// faces, lighting polish and the login→personal camera move come next.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;
import 'package:vector_math/vector_math_64.dart' as vm;

class CubeScene extends StatefulWidget {
  const CubeScene({super.key});

  @override
  State<CubeScene> createState() => _CubeSceneState();
}

class _CubeSceneState extends State<CubeScene>
    with SingleTickerProviderStateMixin {
  ThermionViewer? _viewer;
  ThermionAsset? _cube;
  Ticker? _ticker;
  double _angle = 0;

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    super.dispose();
  }

  Future<void> _onViewer(ThermionViewer viewer) async {
    _viewer = viewer;
    await viewer.setBackgroundColor(0.043, 0.043, 0.047, 1.0); // dark stage

    // key + fill directional lights so the cube faces shade differently and
    // read as real volume (instead of a flat white blob).
    await viewer.addDirectLight(DirectLight.sun(
      intensity: 60000,
      castShadows: false,
      direction: vm.Vector3(-0.4, -0.8, -0.55)..normalize(),
    ));
    await viewer.addDirectLight(DirectLight.sun(
      intensity: 16000,
      castShadows: false,
      direction: vm.Vector3(0.7, -0.1, 0.45)..normalize(),
    ));

    final mat = await FilamentApp.instance!
        .createUbershaderMaterialInstance(unlit: false);
    await mat.setParameterFloat4('baseColorFactor', 0.82, 0.82, 0.86, 1.0);

    _cube = await viewer.createGeometry(
      GeometryHelper.cube(flipUvs: true),
      materialInstances: [mat],
    );

    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) async {
    final v = _viewer;
    final c = _cube;
    if (v == null || c == null) return;
    _angle += 0.012;
    final m = vm.Matrix4.identity()
      ..rotateY(_angle)
      ..rotateX(0.45);
    await c.setTransform(m);
  }

  @override
  Widget build(BuildContext context) {
    return ViewerWidget(
      initial: const ColoredBox(color: Color(0xFF0B0B0C)),
      background: const Color(0xFF0B0B0C),
      manipulatorType: ManipulatorType.NONE,
      transformToUnitCube: false,
      postProcessing: true,
      destroyEngineOnUnload: true,
      initialCameraPosition: vm.Vector3(0, 0, 9),
      onViewerAvailable: _onViewer,
    );
  }
}
