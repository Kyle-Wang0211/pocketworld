// sparse_ply.dart — persists each take's sparse reconstruction next to its
// capture bundle (硬性铁律: delivery is ALWAYS the full point set — no
// downsampling here, render-side thinning only ever happens in viewers).
//
// Written on every LOCAL_READY/REFINED snapshot (refined overwrites local):
//   <captureDir>/official_sfm_sparse.ply        — binary little-endian, xyz float32
//                                        + rgb uchar (true colors when the
//                                        JPEG colorizer has run)
//   <captureDir>/official_sfm_sparse_meta.json — solver summary + CamFromWorld
//                                        poses + counts + timestamps
// The desktop research viewers and any standard tool open the PLY directly.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sfm_live_recon.dart';
import 'photo_archive_runtime.dart';
import '../official_util/device_log.dart';

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
    final header =
        'ply\n'
        'format binary_little_endian 1.0\n'
        'comment PocketWorld capture-time sparse reconstruction (full set)\n'
        // [DEEPSYN-MARK 2026-08-23] 《互联网信息服务深度合成管理规定》第十六条:
        // "采取技术措施添加不影响用户使用的标识"。PLY comment 是 Stanford PLY
        // 格式标准的一部分,且本文件上面那行 comment 已经在生产里跑了很久 ——
        // 三个 parser(ui/sparse_thumbnail.dart、ui/*/sparse_cloud_viewer_page.dart、
        // aether_view/format_detect.dart)全部按 `end_header` 标记定位 + 正则取
        // `element vertex`,不依赖行号,所以加行安全。
        //
        // method 显式记 photogrammetry-sfm:该规定第二十三条把"三维重建"列为
        // 深度合成技术,但限定语是"生成或者编辑数字人物、**虚拟场景**";这条管线
        // 是从真实照片测量重建真实场景。把方法写进产物本身,是可验证的立场声明。
        //
        // ⚠️ 禁止在此写入时间戳或任何每次变化的值:发布路径是 {uid}/{sha1}.ply,
        //    sha1 对 PLY 全字节计算,可变 comment 会让同一份点云每次得到不同的
        //    storage path。时间信息已在 official_sfm_sparse_meta.json 的
        //    `written_at`(schema pw_sfm_sparse_meta_v2)。
        // ⚠️ header 总长必须 < 4096B —— ui/sparse_thumbnail.dart 的扫描循环
        //    写死了 `i < 4096`,超出会导致缩略图静默加载失败。
        'comment generator=PocketWorld\n'
        'comment method=photogrammetry-sfm\n'
        'comment synthetic-content-marker=v1\n'
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
    final ply = File('$captureDir/official_sfm_sparse.ply');
    final sink = ply.openWrite();
    sink.add(headerBytes);
    sink.add(body);
    await sink.close();

    // ── meta JSON v2 ──
    // [GRAV-CONSIST 2026-07-28] `poses` 与 PLY 点**同一坐标系**(整模型一致,
    // COLMAP Reconstruction::Transform 语义 —— 行业查无"只转点不转位姿"的
    // 先例);所施加的 R_w 记在 `gravity_align_quat_wxyz`(nerfstudio
    // dataparser_transforms.json 先例:x' = R_w·x,C' = C∘R_w⁻¹,纯旋转、
    // 平移不变;null = 没对齐);raw-COLMAP 位姿以显式字段 `poses_raw_colmap`
    // 保留逐位真值(host parity 复核用,浮点逆旋转不保逐位)。
    Map<String, Object?> poseEntry(Float64List p, int i) => {
      'frame_id': p[i].toInt(),
      'registered': p[i + 1] != 0,
      'quat_wxyz': [p[i + 2], p[i + 3], p[i + 4], p[i + 5]],
      't': [p[i + 6], p[i + 7], p[i + 8]],
    };
    final poses = snapshot.posesPacked;
    final posesJson = <Map<String, Object?>>[
      for (var i = 0; i < poses.length; i += 9) poseEntry(poses, i),
    ];
    final rawPoses = snapshot.posesPackedRawColmap;
    await File('$captureDir/official_sfm_sparse_meta.json').writeAsString(
      jsonEncode({
        'schema': 'pw_sfm_sparse_meta_v2',
        'written_at': DateTime.now().toIso8601String(),
        'refined': snapshot.refined,
        'n_points': n,
        'summary': snapshot.summary,
        'poses': posesJson,
        'gravity_align_quat_wxyz': snapshot.gravityAlignQuatWxyz,
        // [SCALE-ANCHOR] 应用的米制锚定因子;null=臂关/估计失败(未缩放)。
        'scale_anchor_factor': snapshot.scaleAnchorFactor,
        if (rawPoses != null)
          'poses_raw_colmap': <Map<String, Object?>>[
            for (var i = 0; i < rawPoses.length; i += 9) poseEntry(rawPoses, i),
          ],
      }),
    );
    // ── track-length histogram (de-risk the ignore_two_view_tracks lever) ──
    // Point i's track length = obsOffsets[i+1]-obsOffsets[i] (CSR offsets).
    // The count in the len=2 bucket answers whether 2-view tracks are already
    // KEPT (lever already spent) or absent/EXCLUDED (lever has headroom before
    // we touch native / rebuild libglomap_core.a). Pure Dart, no rebuild.
    final off = snapshot.obsOffsets;
    if (off.length >= n + 1) {
      final buckets = List<int>.filled(11, 0); // idx=len; 2..9, idx10 = 10+
      var sumLen = 0;
      var maxLen = 0;
      for (var i = 0; i < n; i++) {
        final len = off[i + 1] - off[i];
        sumLen += len;
        if (len > maxLen) maxLen = len;
        final b = len >= 10 ? 10 : (len < 2 ? 2 : len);
        buckets[b]++;
      }
      final twoView = buckets[2];
      final pct = (100.0 * twoView / n).toStringAsFixed(1);
      final mean = (sumLen / n).toStringAsFixed(2);
      final hist = [
        for (var l = 2; l <= 9; l++) 'L$l=${buckets[l]}',
        'L10+=${buckets[10]}',
      ].join(' ');
      DeviceLog.log(
        'SfmLive',
        'track-hist: n=$n 2view=$twoView($pct%) mean=$mean max=$maxLen | $hist (refined=${snapshot.refined})',
      );
    }

    DeviceLog.log(
      'SfmLive',
      'sparse persisted: $n pts (refined=${snapshot.refined}) → $captureDir/official_sfm_sparse.ply',
    );
    unawaited(
      photoArchiveCoordinator.noteArtifactsPersisted(Directory(captureDir)),
    );
  } catch (e) {
    DeviceLog.log('SfmLive', 'sparse persist FAILED: $e');
  }
}
