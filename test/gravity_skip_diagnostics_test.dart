// [GRAV-DIAG 2026-07-30] 重力对齐跳过时必须可诊断的契约。
//
// 病因:`_gravityAlign` 是 fail-open —— `gravityAlignQuatWxyz` 返回 null 就原样
// 交付**未对齐**的点云。fail-open 本身是对的(歪的云胜过没有云),但它此前是
// **静默**的:用户在编辑页用肉眼看出点云是歪的,而日志/遥测里一个字都没有,
// 唯一的事后线索是 `official_sfm_sparse_meta.json` 里 `gravity_align_quat_wxyz`
// 是否为 null。
//
// 三个 null 分支的成因和修法完全不同,所以诊断必须能区分:
//   • no_poses                 → 空重建
//   • not_enough_arkit_quats   → **resume/重启的典型表现**(_fedMeta 是内存态)
//   • degenerate_average       → 位姿或 ARKit 四元数本身可疑
// 只报"失败了"而不报成因,下一次仍然只能靠猜。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/gravity_align.dart';

/// 一帧 packed 位姿:frameId, registered, quat(wxyz), t(xyz) —— 共 9 个 double。
Float64List _poses(int n, {bool registered = true}) {
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    out.addAll([i.toDouble(), registered ? 1 : 0, 1, 0, 0, 0, 0, 0, 0]);
  }
  return Float64List.fromList(out);
}

void main() {
  test('aligned run leaves skipReason null', () {
    final diag = GravityAlignDiagV1();
    final q = gravityAlignQuatWxyz(
      posesPacked: _poses(5),
      arkitQuatWxyzOf: (_) => const [1.0, 0.0, 0.0, 0.0],
      diag: diag,
    );
    expect(q, isNotNull);
    expect(diag.skipReason, isNull);
    expect(diag.registeredFrames, 5);
    expect(diag.framesWithArkitQuat, 5);
  });

  test('empty poses report no_poses', () {
    final diag = GravityAlignDiagV1();
    final q = gravityAlignQuatWxyz(
      posesPacked: Float64List(0),
      arkitQuatWxyzOf: (_) => const [1.0, 0.0, 0.0, 0.0],
      diag: diag,
    );
    expect(q, isNull);
    expect(diag.skipReason, GravityAlignDiagV1.reasonNoPoses);
  });

  test('resume-shaped run (no ARKit quats at all) is attributable', () {
    // _fedMeta 是内存态:重启/resume 后一个四元数都拿不到。这正是产品上最
    // 可能出现"编辑页点云是歪的"的路径,必须能一眼认出来。
    final diag = GravityAlignDiagV1();
    final q = gravityAlignQuatWxyz(
      posesPacked: _poses(40),
      arkitQuatWxyzOf: (_) => null,
      diag: diag,
    );
    expect(q, isNull);
    expect(diag.skipReason, GravityAlignDiagV1.reasonNotEnoughArkitQuats);
    expect(diag.registeredFrames, 40, reason: '位姿是有的,缺的是 ARKit 四元数');
    expect(diag.framesWithArkitQuat, 0);
  });

  test('two quats is still below the evidence gate and says so', () {
    final diag = GravityAlignDiagV1();
    final q = gravityAlignQuatWxyz(
      posesPacked: _poses(10),
      arkitQuatWxyzOf: (frameId) =>
          frameId < 2 ? const [1.0, 0.0, 0.0, 0.0] : null,
      diag: diag,
    );
    expect(q, isNull);
    expect(diag.skipReason, GravityAlignDiagV1.reasonNotEnoughArkitQuats);
    expect(diag.framesWithArkitQuat, 2);
    expect(diag.requiredFrames, 3, reason: '阈值随遥测落盘,便于日后改门也能解释旧数据');
  });

  test('unregistered frames are not counted as registered', () {
    final diag = GravityAlignDiagV1();
    gravityAlignQuatWxyz(
      posesPacked: _poses(6, registered: false),
      arkitQuatWxyzOf: (_) => const [1.0, 0.0, 0.0, 0.0],
      diag: diag,
    );
    expect(diag.registeredFrames, 0);
  });

  test('diag is optional — omitting it keeps the original behaviour', () {
    // 纯函数被 resume 路径与 tool/gravity_align_check.dart 共用,新增参数
    // 必须是可选的,否则那两处会静默改行为。
    expect(
      gravityAlignQuatWxyz(
        posesPacked: _poses(5),
        arkitQuatWxyzOf: (_) => const [1.0, 0.0, 0.0, 0.0],
      ),
      isNotNull,
    );
  });

  test('preview and final alignment telemetry have distinct contracts', () {
    final src = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    expect(src, contains("TelemetryWriter.instance.event('preview_skip'"));
    expect(src, contains("'reason': 'already_arkit_gravity_metric'"));
    expect(
      src,
      contains("TelemetryWriter.instance.event('final_alignment_result'"),
    );
    expect(src, contains("'authority': 'fallback_candidate'"));
    expect(src, contains("'authority': 'authoritative'"));
    expect(src, contains("'gravity_status':"));
    expect(src, contains("'scale_status':"));
    expect(src, contains("'gravity_quat_wxyz':"));
    expect(src, contains("'scale_factor':"));
    expect(
      src,
      isNot(contains("TelemetryWriter.instance.event('gravity_skip'")),
    );
    expect(
      src,
      isNot(contains("TelemetryWriter.instance.event('scale_anchor_skip'")),
    );
    expect(src, contains('delivering UNALIGNED cloud'));
    // 空点云是合法空结果,不得被计成重力故障。
    expect(src, contains("'empty_cloud'"));
    // fail-open 必须保留:仍然返回 snap,不抛、不改交付。
    expect(src, contains('return snap;'));
  });

  // ═══ [SCALE-DIAG 2026-07-30] 米制尺度锚定的同类契约 ═══
  //
  // 比重力那条更要紧:SCALE-ANCHOR 是**生产开启**的臂,五个 fail-open 分支此前
  // 全部静默。其中 scale_out_of_band 不是"数据不够"而是"量到了却拒绝施加",
  // 丢掉那个 s 等于丢掉证据(已记录 gauge 漂移 ±4~10.6%,>15% 是真实异常)。

  /// 一帧:frameId, registered, quat(单位), t —— 相机中心 = -R^T·t。
  Float64List posesAt(List<List<double>> centers) {
    final out = <double>[];
    for (var i = 0; i < centers.length; i++) {
      final c = centers[i];
      out.addAll([i.toDouble(), 1, 1, 0, 0, 0, -c[0], -c[1], -c[2]]);
    }
    return Float64List.fromList(out);
  }

  test('successful anchor leaves skipReason null', () {
    final diag = ScaleAnchorDiagV1();
    final centers = [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
    final s = scaleAnchorFactor(
      posesPacked: posesAt(centers),
      arkitCenterWorldOf: (id) => [
        centers[id][0] * 1.05,
        centers[id][1] * 1.05,
        centers[id][2] * 1.05,
      ],
      diag: diag,
    );
    expect(s, isNotNull);
    expect(diag.skipReason, isNull);
    expect(diag.rejectedFactor, isNull);
    expect(diag.pairsWithArkitCenter, 4);
  });

  test('resume-shaped run reports not_enough_pairs', () {
    final diag = ScaleAnchorDiagV1();
    final centers = List.generate(30, (i) => [i * 0.1, 0.0, 0.0]);
    final s = scaleAnchorFactor(
      posesPacked: posesAt(centers),
      arkitCenterWorldOf: (_) => null, // _fedMeta 空
      diag: diag,
    );
    expect(s, isNull);
    expect(diag.skipReason, ScaleAnchorDiagV1.reasonNotEnoughPairs);
    expect(diag.registeredFrames, 30);
    expect(diag.pairsWithArkitCenter, 0);
  });

  test('out-of-band rejection REPORTS the measured factor', () {
    // 这是本诊断存在的核心理由:拒绝施加 ≠ 量不出来。
    final diag = ScaleAnchorDiagV1();
    final centers = [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
    final s = scaleAnchorFactor(
      posesPacked: posesAt(centers),
      arkitCenterWorldOf: (id) => [
        centers[id][0] * 1.4,
        centers[id][1] * 1.4,
        centers[id][2] * 1.4,
      ],
      diag: diag,
    );
    expect(s, isNull, reason: '|s-1| = 0.4 > 0.15 门 ⇒ 拒绝施加');
    expect(diag.skipReason, ScaleAnchorDiagV1.reasonOutOfBand);
    expect(diag.rejectedFactor, isNotNull, reason: '被拒的 s 必须上报,否则等于把测量结果丢掉');
    expect(diag.rejectedFactor!, closeTo(1.4, 1e-6));
  });

  test('scale diag is optional too', () {
    final centers = [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
    expect(
      scaleAnchorFactor(
        posesPacked: posesAt(centers),
        arkitCenterWorldOf: (id) => centers[id],
      ),
      isNotNull,
    );
  });

  test('the final record reports the retired Dart scale arm explicitly', () {
    final src = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    // [SCALE-ANCHOR RETIRED 2026-09-24] 交付尺度改由 C++ 核 DEVICE-ALIGN-V1。
    expect(src, isNot(contains('delivering UNSCALED (raw BA gauge)')));
    expect(src, contains("'moved_to_core_device_align_v1'"));
    expect(src, contains("'scale_rejected_factor':"));
  });
}
