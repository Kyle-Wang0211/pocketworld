// lod_scene_fit.dart — orbit pivot and framing radius for the LOD page, from the
// octree's metadata.json (Potree 2.0, written by PR #100 buildFromPly on the phone).
//
// product_adapter A2 (see lod_camera.dart): the old viewer fits on the points
// themselves — pivot = centre of the P0.5–P99.5 range (sparse_cloud_view.dart:155-158
// orbitPivotOf @875fe67), radius = SparseCloudPainter.fitOf (:1158, median + 8·MAD). The LOD
// page never holds all points in Dart, so it uses what the octree states about itself:
//   * pivot  = centre of the `position` attribute's min/max (the real point extent;
//              Potree 2.0 metadata.json, PotreeConverter writes it per attribute),
//              falling back to `boundingBox` (the cubic root box) if absent;
//   * radius = half the diagonal of that box ⇒ every point is within `radius` of the
//              pivot (what lod_camera.dart's far plane relies on).
// Consequence: a cloud with long outlier tails frames smaller than in the old viewer.
// Zoom is the user's remedy; the old viewer's robust fit is not reproducible here.
import 'dart:convert';
import 'dart:math' as math;

class LodSceneFit {
  const LodSceneFit({
    required this.pivot,
    required this.radius,
    required this.points,
    required this.source,
  });

  final List<double> pivot;
  final double radius;

  /// metadata.json `points` (the tree's own count), -1 if absent.
  final int points;

  /// 'position.min/max' or 'boundingBox' — which box the fit came from.
  final String source;

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

    List<double>? mn, mx;
    var source = '';
    final attrs = root['attributes'];
    if (attrs is List) {
      for (final a in attrs) {
        if (a is Map && a['name'] == 'position') {
          mn = vec3(a['min']);
          mx = vec3(a['max']);
          source = 'position.min/max';
        }
      }
    }
    if (mn == null || mx == null) {
      final bb = root['boundingBox'];
      if (bb is Map) {
        mn = vec3(bb['min']);
        mx = vec3(bb['max']);
        source = 'boundingBox';
      }
    }
    if (mn == null || mx == null) {
      throw const FormatException(
        'metadata.json: no position min/max nor boundingBox',
      );
    }
    for (var i = 0; i < 3; i++) {
      if (mx[i] < mn[i]) {
        throw const FormatException('metadata.json: max < min');
      }
    }
    final hx = (mx[0] - mn[0]) / 2,
        hy = (mx[1] - mn[1]) / 2,
        hz = (mx[2] - mn[2]) / 2;
    final radius = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (!(radius > 0)) {
      throw const FormatException('metadata.json: empty extent');
    }
    final pts = root['points'];
    return LodSceneFit(
      pivot: <double>[mn[0] + hx, mn[1] + hy, mn[2] + hz],
      radius: radius,
      points: pts is num ? pts.toInt() : -1,
      source: source,
    );
  }
}
