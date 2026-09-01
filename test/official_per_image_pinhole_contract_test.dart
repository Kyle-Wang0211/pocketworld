import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pocketWorld = Directory.current;
  final officialSource = File(
    '${pocketWorld.parent.path}/Aether3D-cross/'
    'aether_cpp/official_pipeline/src/official_aether_sfm_c.cc',
  );

  test('official route uses one fixed ARKit PINHOLE camera per image', () {
    expect(officialSource.existsSync(), isTrue);
    final source = officialSource.readAsStringSync();

    expect(source, contains('colmap::PinholeCameraModel::model_id'));
    expect(
      source,
      isNot(
        contains(
          'colmap::kInvalidCameraId, '
          'colmap::SimplePinholeCameraModel::model_id',
        ),
      ),
    );
    expect(source, contains('camera.SetFocalLengthX(fx);'));
    expect(source, contains('camera.SetFocalLengthY(fy);'));
    expect(source, contains('camera.SetPrincipalPointX(cx);'));
    expect(source, contains('camera.SetPrincipalPointY(cy);'));
    expect(source, contains('rec.camera_id = camera_id;'));
    expect(source, contains('rec.camera = camera;'));
    expect(source, contains('image.SetCameraId(camera_id);'));
    expect(source, contains('rimg.SetCameraId(rec.camera_id);'));
  });

  // [重锚 2026-08-22 用户签决] official 路线的两视几何已于 [TVG-SPLIT 2026-08-08]
  // 拆成两个独立 RANSAC:**位姿**来自自研 EstimateUprightRelativePoseV1
  // (重力约束的 upright 相对位姿),**平面退化标签**仍由 COLMAP 官方
  // colmap::EstimateTwoViewGeometry(force_H_use) 产出。
  //
  // 该替换无 kill switch、14 个调用点全覆盖,已由用户签决并补入
  // vendor/official_sfm/scripts/verify_source_parity.py 的 reviewed-delta 账本。
  //
  // 原断言锚在 `colmap::EstimateTwoViewGeometry(\n      a.camera, ...)` 上 ——
  // 那条路径已整体不在 official_aether_sfm_c.cc 里(实测 0 命中),故重锚到
  // **真正产出几何的主干道**,并把"每对用各自的相机"这层做成数量+语义护栏。
  test('official geometry uses each image camera through COLMAP APIs', () {
    final source = officialSource.readAsStringSync();

    expect(source, contains('CopyNormalizedPoints(a.camera, a.points, xy_a);'));
    expect(source, contains('CopyNormalizedPoints(b.camera, b.points, xy_b);'));

    // ① helper 转发那一跳:两侧相机与各自的重力向量成对传入,不共用。
    expect(
      source,
      contains(
        'EstimateMandatoryGravityTwoViewGeometryV1(\n'
        '      frame1.camera, points1, FrameGravityArray(frame1), frame2.camera,',
      ),
    );

    // ② 数量护栏:14 个调用点(源文件共 15 次命中 = 1 处顶格定义 + 14 处调用)。
    //    新增调用点必须显式过审 —— 数字变了就红。
    expect(
      RegExp(r'EstimateMandatoryFrameTwoViewGeometry\(').allMatches(source).length,
      15,
      reason: '两视几何调用点数变化必须显式过审(1 定义 + 14 调用)',
    );

    // ③ 语义护栏:每个调用点的第 1 与第 3 个实参必须是**不同**的帧,
    //    否则就是"两侧共用同一个相机/帧",正是本测试要挡的东西。
    final callArgs = RegExp(
      r'EstimateMandatoryFrameTwoViewGeometry\(\s*([^;]*?)\)\s*;',
      dotAll: true,
    ).allMatches(source);
    for (final m in callArgs) {
      final args = m.group(1)!.split(',').map((e) => e.trim()).toList();
      if (args.length < 3) continue;
      expect(
        args[0],
        isNot(equals(args[2])),
        reason: '两侧必须是不同的帧,不得共用:${m.group(1)}',
      );
    }

    // ④ 三角化 / 重投影仍走各自相机的 COLMAP API(指针形式,非旧的值形式)。
    expect(source, contains('v1.camera->CamFromImg((*v1.points)[i1])'));
    expect(source, contains('v2.camera->CamFromImg((*v2.points)[i2])'));
    expect(source, contains('v1.camera->ImgFromCam(X_prev)'));
    expect(source, contains('v2.camera->ImgFromCam(X_cur)'));
  });

  // [新增 2026-08-22] 把 TVG-SPLIT 这个例外**本身**做成可测的:
  // 位姿走自研、标签走官方,两条都必须在;且账本必须记录这条例外。
  // 这样既不会因代码演进反复误红,也不会让未签决的替换隐形。
  test('TVG-SPLIT: pose from upright RANSAC, planar label from COLMAP', () {
    final gravity = File(
      '${pocketWorld.parent.path}/Aether3D-cross/'
      'aether_cpp/official_pipeline/src/mandatory_gravity_tvg_v1.cc',
    );
    expect(gravity.existsSync(), isTrue);
    final g = gravity.readAsStringSync();

    // 主干道:每侧用**自己**的相机把像点反投成射线。
    expect(
      g,
      contains(
        'const std::optional<Eigen::Vector3d> ray1 = '
        'camera1.CamRayFromImg(point1);',
      ),
    );
    expect(
      g,
      contains(
        'const std::optional<Eigen::Vector3d> ray2 = '
        'camera2.CamRayFromImg(point2);',
      ),
    );
    // 位姿来自自研 upright RANSAC。
    expect(g, contains('EstimateUprightRelativePoseV1('));
    // 平面退化标签仍由 COLMAP 官方 estimator 产出 —— 这一半没有被替换掉。
    expect(g, contains('colmap::EstimateTwoViewGeometry('));
    expect(g, contains('force_H_use'));

    // 账本必须记录这条例外(否则等于替换又隐形了)。
    final ledger = File(
      'vendor/official_sfm/scripts/verify_source_parity.py',
    ).readAsStringSync();
    expect(
      ledger,
      contains('TVG-SPLIT'),
      reason: '自研 upright 两视几何是 reviewed delta,账本必须记录',
    );
  });

  test('official BA fixes every per-image camera intrinsic block', () {
    final source = officialSource.readAsStringSync();

    expect(source, contains('SetAllCameraIntrinsicsConstant('));
    expect(
      source,
      contains('config.SetConstantCamIntrinsics(image.CameraId());'),
    );
  });
}
