// lod_scene_fit.dart — the LOD page's framing box/sphere, taken the way Potree takes it.
//
// Potree @5636cd471d9eb464969e758be45c44d7613d3859 (BSD-2-Clause), the revision the rest of
// the LOD path is pinned to:
//   * src/modules/loader/2.0/OctreeLoader.js:408-420 — the octree's boundingBox is
//     metadata.json `boundingBox` (min/max); tightBoundingBox is a clone of it (:418). The line
//     that would have used the `position` attribute's min/max is commented out upstream
//     (:405-406), so the position extent is deliberately NOT used here either.
//     The box is stored relative to offset = boundingBox.min (:412-414) and the point cloud is
//     placed at that offset (src/PointCloudOctree.js:115 `this.position.copy(geometry.offset)`),
//     so in world space it is exactly metadata `boundingBox` again.
//   * src/viewer/Scene.js:106-121 getBoundingBox — the scene box is the (union of the) point
//     clouds' tightBoundingBox in world space. One cloud here ⇒ that box.
//   * src/viewer/viewer.js:890-898 fitToScreen(factor = 1) → zoomTo(node{boundingBox}, 1)
//     (:790-809) → the node's bounding sphere = boundingBox.getBoundingSphere(), whose centre
//     becomes the orbit target (`endTarget = bs.center`, :815).
//   * three.js r124 as bundled by that Potree (libs/three.js/build/three.module.js:4258-4272,
//     Box3.getBoundingSphere): centre = box centre, radius = |size| · 0.5.
//
// pivot = that centre, radius = that radius; both feed the old viewer's CloudCamera
// (lod_camera.dart). The box itself is also kept: Potree's far plane is computed from it
// (lod_camera.dart potreeNearFar).
import 'dart:convert';
import 'dart:math' as math;

class LodSceneFit {
  const LodSceneFit({
    required this.boxMin,
    required this.boxMax,
    required this.pivot,
    required this.radius,
    required this.points,
  });

  /// Scene box in world space (Scene.getBoundingBox).
  final List<double> boxMin;
  final List<double> boxMax;

  /// Box3.getBoundingSphere of that box.
  final List<double> pivot;
  final double radius;

  /// metadata.json `points` (the tree's own count), -1 if absent.
  final int points;

  /// Throws [FormatException] on anything that is not a usable Potree 2.0 metadata.
  static LodSceneFit fromMetadataJson(String text) {
    final Object? root = jsonDecode(text);
    if (root is! Map) {
      throw const FormatException('metadata.json: not an object');
    }

    List<double>? vec3(Object? v) {
      if (v is! List || v.length != 3) return null;
      final out = <double>[];
      for (final e in v) {
        if (e is! num || !e.isFinite) {
          return null;
        }
        out.add(e.toDouble());
      }
      return out;
    }

    // OctreeLoader.js:408-409
    final bb = root['boundingBox'];
    final mn = bb is Map ? vec3(bb['min']) : null;
    final mx = bb is Map ? vec3(bb['max']) : null;
    if (mn == null || mx == null) {
      throw const FormatException('metadata.json: no boundingBox min/max');
    }
    for (var i = 0; i < 3; i++) {
      if (mx[i] < mn[i]) {
        throw const FormatException('metadata.json: max < min');
      }
    }
    // three.js r124 Box3.getCenter / getSize / getBoundingSphere (three.module.js:4258-4272)
    final sx = mx[0] - mn[0], sy = mx[1] - mn[1], sz = mx[2] - mn[2];
    final radius = math.sqrt(sx * sx + sy * sy + sz * sz) * 0.5;
    if (!(radius > 0)) {
      throw const FormatException('metadata.json: empty boundingBox');
    }
    final pts = root['points'];
    return LodSceneFit(
      boxMin: mn,
      boxMax: mx,
      pivot: <double>[
        (mn[0] + mx[0]) * 0.5,
        (mn[1] + mx[1]) * 0.5,
        (mn[2] + mx[2]) * 0.5,
      ],
      radius: radius,
      points: pts is num ? pts.toInt() : -1,
    );
  }
}
