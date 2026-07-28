// view_cube.dart — 右上角 3D 朝向立方体(ViewCube),与点云相机绑定。
//
// [2026-07-28 用户签决] "右上角要做成一个正方体模型,它的转向和点云的转向
// 一致,做绑定":本组件用与点云**完全相同**的 (viewYaw, viewPitch) 经
// CloudCamera(orthographic) 投影渲染一个立方体,六面贴标签(仿射贴面,
// 正交下面投影是平行四边形,仿射精确)。点云转到哪,立方体转到哪 ——
// 含滑杆分量与 Top/Bottom 原地转(此前只有文本 label,原地转毫无反馈,
// 用户实机指认)。
//
// 面→世界法向的标签映射与投影语义一致(推导:pitch=−90° 时朝相机面 =
// +Y ⇒ Top;yaw=0,pitch=0 时朝相机面 = −Z ⇒ Front;yaw=+90° ⇒ +X=Right)。
import 'package:flutter/material.dart';

import 'cloud_camera.dart';

/// 六面定义:标签 + 单位外法向(世界系,Y=重力上)+ 面四角(单位立方体,
/// 逆时针序,从面外侧看)。
typedef ViewCubeFace = ({
  String label,
  List<double> normal,
  List<List<double>> corners,
});

const List<ViewCubeFace> kViewCubeFaces = [
  (
    label: 'Top',
    normal: [0, 1, 0],
    corners: [
      [-1, 1, -1],
      [1, 1, -1],
      [1, 1, 1],
      [-1, 1, 1],
    ],
  ),
  (
    label: 'Bottom',
    normal: [0, -1, 0],
    corners: [
      [-1, -1, 1],
      [1, -1, 1],
      [1, -1, -1],
      [-1, -1, -1],
    ],
  ),
  (
    label: 'Front',
    normal: [0, 0, -1],
    corners: [
      [-1, 1, -1],
      [1, 1, -1],
      [1, -1, -1],
      [-1, -1, -1],
    ],
  ),
  (
    label: 'Back',
    normal: [0, 0, 1],
    corners: [
      [1, 1, 1],
      [-1, 1, 1],
      [-1, -1, 1],
      [1, -1, 1],
    ],
  ),
  (
    label: 'Right',
    normal: [1, 0, 0],
    corners: [
      [1, 1, -1],
      [1, 1, 1],
      [1, -1, 1],
      [1, -1, -1],
    ],
  ),
  (
    label: 'Left',
    normal: [-1, 0, 0],
    corners: [
      [-1, 1, 1],
      [-1, 1, -1],
      [-1, -1, -1],
      [-1, -1, 1],
    ],
  ),
];

/// 当前姿态下可见(朝相机)的面标签。纯函数,测试锁绑定语义。
/// 判据:面中心(=法向×1)的投影深度比立方体中心浅 ⇒ 面朝相机。
List<String> visibleViewCubeFaces(double yaw, double pitch) {
  final proj = CloudCamera(
    yaw: yaw,
    pitch: pitch,
    zoom: 1,
    panX: 0,
    panY: 0,
    pivotX: 0,
    pivotY: 0,
    pivotZ: 0,
    radius: 1,
    orthographic: true,
  ).projectionFor(const Size(100, 100));
  final (_, _, centerDepth) = proj.project(0, 0, 0);
  final out = <String>[];
  for (final f in kViewCubeFaces) {
    final (_, _, d) = proj.project(f.normal[0], f.normal[1], f.normal[2]);
    if (d < centerDepth - 1e-9) out.add(f.label);
  }
  return out;
}

/// 当前姿态下**最正对相机**的面标签(立方体上唯一显示的单词)。
/// 判据:面法向投影深度最小 = 法向最朝向相机。
String primaryViewCubeFace(double yaw, double pitch) {
  final proj = CloudCamera(
    yaw: yaw,
    pitch: pitch,
    zoom: 1,
    panX: 0,
    panY: 0,
    pivotX: 0,
    pivotY: 0,
    pivotZ: 0,
    radius: 1,
    orthographic: true,
  ).projectionFor(const Size(100, 100));
  var best = kViewCubeFaces.first.label;
  var bestD = double.infinity;
  for (final f in kViewCubeFaces) {
    final (_, _, d) = proj.project(f.normal[0], f.normal[1], f.normal[2]);
    if (d < bestD) {
      bestD = d;
      best = f.label;
    }
  }
  return best;
}

/// 与点云相机绑定的 3D 朝向立方体。
class ViewCube extends StatelessWidget {
  const ViewCube({
    super.key,
    required this.viewYaw,
    required this.viewPitch,
    this.size = 72,
  });

  final double viewYaw;
  final double viewPitch;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ViewCubePainter(yaw: viewYaw, pitch: viewPitch),
      ),
    );
  }
}

class _ViewCubePainter extends CustomPainter {
  const _ViewCubePainter({required this.yaw, required this.pitch});

  final double yaw;
  final double pitch;

  @override
  void paint(Canvas canvas, Size size) {
    // 半边 1 的立方体,占画布 ~64%(对角伸展留白)。
    // 正交 scale = f/camDist;f = half·fillK·zoom,camDist = radius·3.2。
    // radius=1 → 半边屏幕尺寸 = fillK·half/3.2;取 fillK=2.05 → ~0.64·half。
    final proj = CloudCamera(
      yaw: yaw,
      pitch: pitch,
      zoom: 1,
      panX: 0,
      panY: 0,
      pivotX: 0,
      pivotY: 0,
      pivotZ: 0,
      radius: 1,
      fillK: 2.05,
      orthographic: true,
    ).projectionFor(size);
    final (_, _, centerDepth) = proj.project(0, 0, 0);

    // 远面先画(半透明背景板),近面后画 —— 无深度缓冲的画家算法。
    final faces = [...kViewCubeFaces]
      ..sort((a, b) {
        final (_, _, da) = proj.project(a.normal[0], a.normal[1], a.normal[2]);
        final (_, _, db) = proj.project(b.normal[0], b.normal[1], b.normal[2]);
        return db.compareTo(da);
      });

    // [2026-07-28 用户实机反馈] 标签只画**最正对**的一个面:斜视角下多面
    // 同时朝相机时逐面画标签会拼成 "RightBack",且仿射贴面在反侧手性下
    // 文字镜像、沿倾斜面延伸还会跑出面界。
    final primary = primaryViewCubeFace(yaw, pitch);
    for (final f in faces) {
      final (_, _, nd) = proj.project(f.normal[0], f.normal[1], f.normal[2]);
      final facing = nd < centerDepth - 1e-9;
      final pts = f.corners
          .map((c) {
            final (sx, sy, _) = proj.project(c[0], c[1], c[2]);
            return Offset(sx, sy);
          })
          .toList(growable: false);
      final path = Path()..addPolygon(pts, true);
      if (facing) {
        canvas.drawPath(path, Paint()..color = const Color(0x2EFFFFFF));
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = const Color(0xB3FFFFFF),
        );
        if (f.label == primary) _drawFaceLabel(canvas, f.label, pts);
      } else {
        // 背面只画极淡描边,保留立方体体积感。
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = const Color(0x22FFFFFF),
        );
      }
    }
  }

  /// 标签:水平居中画在面投影中心(带小暗底)。
  ///
  /// [2026-07-28 用户实机反馈修订] 不再仿射贴面:贴面文字在反侧手性下会
  /// 镜像("ЯightBack"),沿倾斜面延伸会跑出面界。水平画法永不镜像、
  /// 永不出界、任何角度可读;转向反馈由立方体轮廓的转动承担。
  void _drawFaceLabel(Canvas canvas, String label, List<Offset> pts) {
    final cx = (pts[0].dx + pts[1].dx + pts[2].dx + pts[3].dx) / 4;
    final cy = (pts[0].dy + pts[1].dy + pts[2].dy + pts[3].dy) / 4;

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bg = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: tp.width + 10,
        height: tp.height + 4,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(bg, Paint()..color = const Color(0x99000000));
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_ViewCubePainter old) =>
      old.yaw != yaw || old.pitch != pitch;
}
