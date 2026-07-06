// sparse_ply.dart — persists each take's sparse reconstruction next to its
// capture bundle (硬性铁律: delivery is ALWAYS the full point set — no
// downsampling here, render-side thinning only ever happens in viewers).
//
// Written on every LOCAL_READY/REFINED snapshot (refined overwrites local):
//   <captureDir>/sfm_sparse.ply        — binary little-endian, xyz float32
//                                        + rgb uchar (true colors when the
//                                        JPEG colorizer has run)
//   <captureDir>/sfm_sparse_meta.json  — solver summary + CamFromWorld
//                                        poses + counts + timestamps
// The desktop research viewers and any standard tool open the PLY directly.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sfm_live_recon.dart';
import '../util/device_log.dart';

Future<void> persistSparseSnapshot({
  required String captureDir,
  required SfmLiveSnapshot snapshot,
  required Uint8List rgb, // colorized (or gray-fallback) colors, 3B/point
}) async {
  try {
    final n = snapshot.pointCount;
    if (n == 0) return;
    final xyz = snapshot.xyz;

    // ── binary PLY ──
    final header = 'ply\n'
        'format binary_little_endian 1.0\n'
        'comment PocketWorld capture-time sparse reconstruction (full set)\n'
        'element vertex $n\n'
        'property float x\n'
        'property float y\n'
        'property float z\n'
        'property uchar red\n'
        'property uchar green\n'
        'property uchar blue\n'
        'end_header\n';
    final headerBytes = utf8.encode(header);
    final body = Uint8List(n * 15);
    final bd = ByteData.view(body.buffer);
    for (var i = 0; i < n; i++) {
      final o = i * 15;
      bd.setFloat32(o, xyz[i * 3], Endian.little);
      bd.setFloat32(o + 4, xyz[i * 3 + 1], Endian.little);
      bd.setFloat32(o + 8, xyz[i * 3 + 2], Endian.little);
      body[o + 12] = i * 3 + 2 < rgb.length ? rgb[i * 3] : 200;
      body[o + 13] = i * 3 + 2 < rgb.length ? rgb[i * 3 + 1] : 200;
      body[o + 14] = i * 3 + 2 < rgb.length ? rgb[i * 3 + 2] : 205;
    }
    final ply = File('$captureDir/sfm_sparse.ply');
    final sink = ply.openWrite();
    sink.add(headerBytes);
    sink.add(body);
    await sink.close();

    // ── meta JSON (poses stay CamFromWorld, 9 doubles per frame) ──
    final poses = snapshot.posesPacked;
    final posesJson = <Map<String, Object?>>[];
    for (var i = 0; i < poses.length; i += 9) {
      posesJson.add({
        'frame_id': poses[i].toInt(),
        'registered': poses[i + 1] != 0,
        'quat_wxyz': [poses[i + 2], poses[i + 3], poses[i + 4], poses[i + 5]],
        't': [poses[i + 6], poses[i + 7], poses[i + 8]],
      });
    }
    await File('$captureDir/sfm_sparse_meta.json').writeAsString(jsonEncode({
      'schema': 'pw_sfm_sparse_meta_v1',
      'written_at': DateTime.now().toIso8601String(),
      'refined': snapshot.refined,
      'n_points': n,
      'summary': snapshot.summary,
      'poses': posesJson,
    }));
    DeviceLog.log('SfmLive',
        'sparse persisted: $n pts (refined=${snapshot.refined}) → $captureDir/sfm_sparse.ply');
  } catch (e) {
    DeviceLog.log('SfmLive', 'sparse persist FAILED: $e');
  }
}
