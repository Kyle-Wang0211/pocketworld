// sparse_cloud_viewer_page.dart — full-screen viewer for a take's persisted
// sparse cloud (<captureDir>/sfm_sparse.ply), opened from the drafts
// long-press menu ("查看点云"). Same SparseCloudView as the capture-time
// preview, so the experience is identical everywhere.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import 'sparse_cloud_view.dart';

/// Parsed cloud (full set — delivery never downsamples).
class SparseCloudData {
  const SparseCloudData(this.xyz, this.rgb);
  final Float32List xyz;
  final Uint8List rgb;
  int get count => xyz.length ~/ 3;
}

/// Loads the app's own binary-little-endian PLY (xyz float32 + rgb uchar,
/// as written by sparse_ply.dart / the host regeneration tool).
SparseCloudData? loadSparsePly(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    // Find end_header\n
    const marker = 'end_header\n';
    final headEnd = _indexOfAscii(bytes, marker);
    if (headEnd < 0) return null;
    final header = String.fromCharCodes(bytes.sublist(0, headEnd));
    final m = RegExp(r'element vertex (\d+)').firstMatch(header);
    if (m == null || !header.contains('binary_little_endian')) return null;
    final n = int.parse(m.group(1)!);
    final body = bytes.sublist(headEnd + marker.length);
    if (body.length < n * 15) return null;
    final xyz = Float32List(n * 3);
    final rgb = Uint8List(n * 3);
    final bd = ByteData.sublistView(body);
    for (var i = 0; i < n; i++) {
      final o = i * 15;
      xyz[i * 3] = bd.getFloat32(o, Endian.little);
      xyz[i * 3 + 1] = bd.getFloat32(o + 4, Endian.little);
      xyz[i * 3 + 2] = bd.getFloat32(o + 8, Endian.little);
      rgb[i * 3] = body[o + 12];
      rgb[i * 3 + 1] = body[o + 13];
      rgb[i * 3 + 2] = body[o + 14];
    }
    return SparseCloudData(xyz, rgb);
  } catch (_) {
    return null;
  }
}

int _indexOfAscii(Uint8List bytes, String needle) {
  final n = needle.codeUnits;
  final limit = bytes.length - n.length;
  for (var i = 0; i <= limit && i < 4096; i++) {
    var hit = true;
    for (var j = 0; j < n.length; j++) {
      if (bytes[i + j] != n[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

class SparseCloudViewerPage extends StatefulWidget {
  const SparseCloudViewerPage({
    super.key,
    required this.plyPath,
    this.title,
  });

  final String plyPath;
  final String? title;

  @override
  State<SparseCloudViewerPage> createState() => _SparseCloudViewerPageState();
}

class _SparseCloudViewerPageState extends State<SparseCloudViewerPage> {
  SparseCloudData? _cloud;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cloud = await compute(loadSparsePly, widget.plyPath,
        debugLabel: 'sparse_ply_load');
    if (!mounted) return;
    setState(() {
      _cloud = cloud;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          cloud != null
              ? '${widget.title ?? '稀疏点云'} · ${cloud.count} 点'
              : (widget.title ?? '稀疏点云'),
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white70,
                  ),
                ),
              )
            : cloud == null
                ? const Center(
                    child: Text(
                      '点云文件读取失败',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SparseCloudView(xyz: cloud.xyz, rgb: cloud.rgb),
                  ),
      ),
    );
  }
}
