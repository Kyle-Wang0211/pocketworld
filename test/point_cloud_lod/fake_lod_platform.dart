// fake_lod_platform.dart — a stand-in for the iOS shell (ios/Runner/PwLodTexturePlugin.swift) on the
// `pw_lod_texture` channel, for widget/unit tests. It records every call and answers like the
// shell: create → textureId, stats → a frame whose `source` follows what was loaded, buildFromPly
// → writes a Potree-shaped tree (metadata.json / hierarchy.bin / octree.bin of 18 B per point)
// and reports it, verifyOctree → reads it back. Knobs inject the failures the product must
// survive (tree loses a point, a leaf is unreachable, load fails, no plugin at all).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';

class FakeLodPlatform {
  final calls = <MethodCall>[];
  int _nextId = 7;
  int source = 0; // what the engine holds: 0 none, 1 flat, 2 octree
  int frame = 0;

  /// When false, stats report no published frame yet (frame_number 0).
  bool publishFrames = true;

  // failure knobs
  int buildLosesPoints = 0; // tree_points = ply_points − this
  int verifyUnreachableLeaves = 0;
  bool loadOctreeFails = false;
  bool createFails = false;

  List<String> get methods => [for (final c in calls) c.method];
  Iterable<MethodCall> of(String m) => calls.where((c) => c.method == m);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kPwLodChannel),
      handle,
    );
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kPwLodChannel),
      null,
    );
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final a = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'create':
        if (createFails) throw PlatformException(code: 'PWLOD_ERR_GPU', message: 'no device');
        return {
          'textureId': _nextId++,
          'version': '72ee817f abi=3',
          'backend': 5,
          'viewport_width_px': a['viewport_width_px'],
          'viewport_height_px': a['viewport_height_px'],
        };
      case 'setPoints':
        source = 1;
        return null;
      case 'loadOctree':
        if (loadOctreeFails) throw PlatformException(code: 'PWLOD_ERR_FORMAT', message: 'bad tree');
        source = 2;
        return null;
      case 'stats':
        if (!publishFrames) return null;
        frame++;
        return {
          'frame_number': frame,
          'completed_frame_number': frame,
          'points_drawn': 1000,
          'nodes_drawn': source == 2 ? 12 : 0,
          'nodes_loading': 0,
          'uploads_this_frame': 0,
          'dropped_for_cache': 0,
          'min_node_pixel_size': 1.0,
          'cpu_ms': 1.0,
          'gpu_ms': 1.0,
          'lowest_spacing': source == 2 ? 0.004 : 0.0,
          'source': source,
        };
      case 'buildFromPly':
        return _build(a['ply_path'] as String, a['out_dir'] as String, a['chunk_dir'] as String);
      case 'verifyOctree':
        return _verify(a['octree_dir'] as String);
      default:
        return null; // setParams / setStyle / setCamera / dispose
    }
  }

  static int headerPoints(String ply) {
    final text = latin1.decode(File(ply).readAsBytesSync().take(4096).toList(), allowInvalid: true);
    return int.parse(RegExp(r'element vertex (\d+)').firstMatch(text)!.group(1)!);
  }

  Map<String, Object> _build(String ply, String out, String chunk) {
    final n = headerPoints(ply);
    final tree = n - buildLosesPoints;
    Directory(out).createSync(recursive: true);
    Directory(chunk).createSync(recursive: true);
    File('$out/metadata.json').writeAsStringSync(
      jsonEncode({
        'version': '2.0',
        'points': tree,
        'boundingBox': {
          'min': [-1, -1, -1],
          'max': [1, 1, 1],
        },
      }),
    );
    File('$out/hierarchy.bin').writeAsBytesSync(Uint8List(22));
    File('$out/octree.bin').writeAsBytesSync(Uint8List(18 * tree));
    Directory(chunk).deleteSync(recursive: true); // the shell deletes chunk_dir
    return {
      'status': 'PWLOD_OK',
      'error': '',
      'ply_points': n,
      'tree_points': tree,
      'octree_bin_bytes': 18 * tree,
      'nodes': 1,
      'elapsed_ms': 5.0,
      'shell_wall_ms': 6.0,
      'peak_footprint_mb': 100.0,
      'baseline_footprint_mb': 50.0,
      'footprint_samples': 3,
      'chunk_dir_removed': true,
    };
  }

  Map<String, Object> _verify(String dir) {
    final meta = jsonDecode(File('$dir/metadata.json').readAsStringSync()) as Map;
    final tree = meta['points'] as int;
    return {
      'status': verifyUnreachableLeaves > 0 ? 'PWLOD_ERR_FORMAT' : 'PWLOD_OK',
      'tree_points': tree,
      'octree_bin_bytes': File('$dir/octree.bin').lengthSync(),
      'nodes': 1,
      'leaves': 4,
      'leaves_selected': 4 - verifyUnreachableLeaves,
      'byte_gaps': 0,
      'byte_overlaps': 0,
      'shell_wall_ms': 1.0,
    };
  }
}

/// A binary little-endian PLY exactly like official_dense.ply (xyz float32 + rgb uchar).
File writeDensePly(String path, int n, {int seed = 1}) {
  final header =
      'ply\nformat binary_little_endian 1.0\nelement vertex $n\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n';
  final body = ByteData(n * 15);
  var s = seed;
  double r() {
    s = (1664525 * s + 1013904223) & 0xFFFFFFFF;
    return s / 4294967296.0;
  }

  for (var i = 0; i < n; i++) {
    body.setFloat32(i * 15, r() * 2 - 1, Endian.little);
    body.setFloat32(i * 15 + 4, r() * 2 - 1, Endian.little);
    body.setFloat32(i * 15 + 8, r() * 2 - 1, Endian.little);
    body.setUint8(i * 15 + 12, (r() * 255).round());
    body.setUint8(i * 15 + 13, (r() * 255).round());
    body.setUint8(i * 15 + 14, (r() * 255).round());
  }
  final f = File(path)..parent.createSync(recursive: true);
  f.writeAsBytesSync([...ascii.encode(header), ...body.buffer.asUint8List()]);
  return f;
}
