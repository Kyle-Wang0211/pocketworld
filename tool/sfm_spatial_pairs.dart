// Generate spatial-near / time-far SfM image pairs from sfm_fed_frames.jsonl.
//
// Run:
//   dart run tool/sfm_spatial_pairs.dart \
//     --fed-meta /path/to/sfm_fed_frames.jsonl \
//     --out /tmp/spatial_pairs.txt
//
// The output format matches COLMAP's image-pairs text format:
//   frame_000012.jpg frame_000085.jpg

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

void main(List<String> args) {
  final opt = _Options.parse(args);
  if (opt.help) {
    stdout.writeln(_Options.usage);
    return;
  }
  if (opt.fedMetaPath == null || opt.outPath == null) {
    stderr.writeln('FAIL: --fed-meta and --out are required.\n');
    stderr.writeln(_Options.usage);
    exit(64);
  }

  final frames = _readFrames(opt.fedMetaPath!);
  final posed = frames.where((f) => f.center != null).toList()
    ..sort((a, b) => a.frameId.compareTo(b.frameId));
  if (posed.length < 2) {
    stderr.writeln(
      'FAIL: ${opt.fedMetaPath} has ${posed.length} frames with '
      'arkitCameraCenterWorld. Capture with the pose-sidecar build first.',
    );
    exit(2);
  }

  final candidates = <_Candidate>[];
  for (var i = 0; i < posed.length; i++) {
    for (var j = i + 1; j < posed.length; j++) {
      final a = posed[i];
      final b = posed[j];
      final gap = (b.frameId - a.frameId).abs();
      if (gap < opt.minFrameGap) continue;
      final distance = a.center!.distanceTo(b.center!);
      if (distance > opt.maxDistanceM) continue;
      final forwardDot = a.forward == null || b.forward == null
          ? 1.0
          : a.forward!.dot(b.forward!);
      if (forwardDot < opt.minForwardDot) continue;
      candidates.add(_Candidate(a, b, gap, distance, forwardDot));
    }
  }

  candidates.sort((a, b) {
    final d = a.distance.compareTo(b.distance);
    if (d != 0) return d;
    final g = b.gap.compareTo(a.gap);
    if (g != 0) return g;
    final i = a.a.frameId.compareTo(b.a.frameId);
    return i != 0 ? i : a.b.frameId.compareTo(b.b.frameId);
  });

  final perFrame = <int, int>{};
  final selected = <_Candidate>[];
  for (final c in candidates) {
    final ca = perFrame[c.a.frameId] ?? 0;
    final cb = perFrame[c.b.frameId] ?? 0;
    if (ca >= opt.perFrameCap || cb >= opt.perFrameCap) continue;
    selected.add(c);
    perFrame[c.a.frameId] = ca + 1;
    perFrame[c.b.frameId] = cb + 1;
    if (selected.length >= opt.maxPairs) break;
  }

  selected.sort((a, b) {
    final i = a.a.frameId.compareTo(b.a.frameId);
    return i != 0 ? i : a.b.frameId.compareTo(b.b.frameId);
  });

  final out = File(opt.outPath!);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    selected.map((c) => '${c.a.imageName} ${c.b.imageName}').join('\n') +
        (selected.isEmpty ? '' : '\n'),
  );

  stdout.writeln('loaded_frames=${frames.length}');
  stdout.writeln('posed_frames=${posed.length}');
  stdout.writeln('candidate_pairs=${candidates.length}');
  stdout.writeln('selected_pairs=${selected.length}');
  stdout.writeln('out=${out.path}');
  stdout.writeln(
    'thresholds: min_frame_gap=${opt.minFrameGap} '
    'max_distance_m=${opt.maxDistanceM} '
    'min_forward_dot=${opt.minForwardDot} '
    'per_frame_cap=${opt.perFrameCap} max_pairs=${opt.maxPairs}',
  );
}

List<_Frame> _readFrames(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('FAIL: file not found: $path');
    exit(66);
  }
  final frames = <_Frame>[];
  var lineNo = 0;
  for (final rawLine in file.readAsLinesSync()) {
    lineNo++;
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (e) {
      stderr.writeln('FAIL: bad JSON at $path:$lineNo: $e');
      exit(65);
    }
    if (decoded is! Map<String, Object?>) {
      stderr.writeln('FAIL: expected JSON object at $path:$lineNo');
      exit(65);
    }
    final frameId = _intValue(decoded['frameId']);
    if (frameId == null) {
      stderr.writeln('FAIL: missing frameId at $path:$lineNo');
      exit(65);
    }
    final center = _vec3(decoded['arkitCameraCenterWorld']);
    final quat = _vec4(decoded['arkitCamFromWorldQwxyz']);
    final forward = quat == null
        ? null
        : _rotateByQuat(_quatConj(quat), const _Vec3(0, 0, -1)).normalized();
    frames.add(_Frame(frameId, center, forward));
  }
  return frames;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

_Vec3? _vec3(Object? value) {
  if (value is! List || value.length != 3) return null;
  final x = _doubleValue(value[0]);
  final y = _doubleValue(value[1]);
  final z = _doubleValue(value[2]);
  return x == null || y == null || z == null ? null : _Vec3(x, y, z);
}

List<double>? _vec4(Object? value) {
  if (value is! List || value.length != 4) return null;
  final out = <double>[];
  for (final v in value) {
    final d = _doubleValue(v);
    if (d == null) return null;
    out.add(d);
  }
  return out;
}

double? _doubleValue(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

List<double> _quatConj(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

_Vec3 _rotateByQuat(List<double> q, _Vec3 v) {
  final w = q[0], x = q[1], y = q[2], z = q[3];
  final norm = math.sqrt(w * w + x * x + y * y + z * z);
  if (norm < 1e-12) return v;
  final qw = w / norm, qx = x / norm, qy = y / norm, qz = z / norm;

  final tx = 2.0 * (qy * v.z - qz * v.y);
  final ty = 2.0 * (qz * v.x - qx * v.z);
  final tz = 2.0 * (qx * v.y - qy * v.x);
  return _Vec3(
    v.x + qw * tx + (qy * tz - qz * ty),
    v.y + qw * ty + (qz * tx - qx * tz),
    v.z + qw * tz + (qx * ty - qy * tx),
  );
}

class _Options {
  const _Options({
    required this.fedMetaPath,
    required this.outPath,
    required this.minFrameGap,
    required this.maxDistanceM,
    required this.minForwardDot,
    required this.perFrameCap,
    required this.maxPairs,
    required this.help,
  });

  final String? fedMetaPath;
  final String? outPath;
  final int minFrameGap;
  final double maxDistanceM;
  final double minForwardDot;
  final int perFrameCap;
  final int maxPairs;
  final bool help;

  static const usage = '''
Usage:
  dart run tool/sfm_spatial_pairs.dart --fed-meta PATH --out PATH [options]

Options:
  --min-frame-gap N       Require frame-id gap >= N. Default: 20
  --max-distance-m X      Require ARKit camera centers within X meters. Default: 0.35
  --min-forward-dot X     Require camera forward-vector dot >= X. Default: 0.25
  --per-frame-cap N       Max selected pairs incident to one frame. Default: 8
  --max-pairs N           Max selected output pairs. Default: 400
  --help                  Show this help.
''';

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--help' || arg == '-h') {
        help = true;
        continue;
      }
      if (!arg.startsWith('--')) {
        stderr.writeln('FAIL: unexpected argument: $arg');
        exit(64);
      }
      final eq = arg.indexOf('=');
      if (eq >= 0) {
        values[arg.substring(2, eq)] = arg.substring(eq + 1);
      } else {
        if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
          stderr.writeln('FAIL: missing value for $arg');
          exit(64);
        }
        values[arg.substring(2)] = args[++i];
      }
    }

    return _Options(
      fedMetaPath: values['fed-meta'],
      outPath: values['out'],
      minFrameGap: _parseInt(values, 'min-frame-gap', 20),
      maxDistanceM: _parseDouble(values, 'max-distance-m', 0.35),
      minForwardDot: _parseDouble(values, 'min-forward-dot', 0.25),
      perFrameCap: _parseInt(values, 'per-frame-cap', 8),
      maxPairs: _parseInt(values, 'max-pairs', 400),
      help: help,
    );
  }

  static int _parseInt(Map<String, String> values, String key, int fallback) {
    final value = values[key];
    if (value == null) return fallback;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      stderr.writeln('FAIL: --$key must be a non-negative integer');
      exit(64);
    }
    return parsed;
  }

  static double _parseDouble(
    Map<String, String> values,
    String key,
    double fallback,
  ) {
    final value = values[key];
    if (value == null) return fallback;
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite) {
      stderr.writeln('FAIL: --$key must be a finite number');
      exit(64);
    }
    return parsed;
  }
}

class _Frame {
  const _Frame(this.frameId, this.center, this.forward);

  final int frameId;
  final _Vec3? center;
  final _Vec3? forward;

  String get imageName => 'frame_${frameId.toString().padLeft(6, '0')}.jpg';
}

class _Candidate {
  const _Candidate(this.a, this.b, this.gap, this.distance, this.forwardDot);

  final _Frame a;
  final _Frame b;
  final int gap;
  final double distance;
  final double forwardDot;
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double distanceTo(_Vec3 other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double dot(_Vec3 other) => x * other.x + y * other.y + z * other.z;

  _Vec3 normalized() {
    final n = math.sqrt(x * x + y * y + z * z);
    if (n < 1e-12) return this;
    return _Vec3(x / n, y / n, z / n);
  }
}
