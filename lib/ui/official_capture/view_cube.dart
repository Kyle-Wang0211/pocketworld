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
import 'dart:math' as math;

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
    fillK: kViewCubeFillK,
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

/// 点击立方体时命中的面(建模软件同款:点哪面就转到那面正对)。
/// 判据:点落在该面投影四边形内 且 该面朝相机;多面命中取最靠前的。
String? hitViewCubeFace(
  double yaw,
  double pitch,
  double roll,
  Size size,
  Offset local,
) {
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
    fillK: kViewCubeFillK,
    orthographic: true,
    roll: roll,
  ).projectionFor(size);
  final (_, _, centerDepth) = proj.project(0, 0, 0);
  String? best;
  var bestDepth = double.infinity;
  for (final f in kViewCubeFaces) {
    final (_, _, nd) = proj.project(f.normal[0], f.normal[1], f.normal[2]);
    if (nd >= centerDepth - 1e-9) continue; // 背面不接受点击
    final pts = f.corners
        .map((c) {
          final (sx, sy, _) = proj.project(c[0], c[1], c[2]);
          return Offset(sx, sy);
        })
        .toList(growable: false);
    if (!_pointInQuad(pts, local)) continue;
    if (nd < bestDepth) {
      bestDepth = nd;
      best = f.label;
    }
  }
  return best;
}

bool _pointInQuad(List<Offset> q, Offset p) {
  var sign = 0;
  for (var i = 0; i < q.length; i++) {
    final a = q[i], b = q[(i + 1) % q.length];
    final cr = (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    if (cr.abs() < 1e-12) continue;
    final s = cr > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return sign != 0;
}

/// 立方体投影充满系数(命中与绘制必须同值,否则点击与所见错位)。
/// 立方体填充系数。与 kCamDistK 同比:原 2.9 是 camDist=3.2 时代的值,
/// 相机改远摄后要 ×(8.0/3.2) 才能保持同样大小(且立方体不再被透视拉歪)。
const double kViewCubeFillK = 2.9 * kCamDistK / 3.2;

/// 与点云相机绑定的 3D 朝向立方体。
class ViewCube extends StatelessWidget {
  const ViewCube({
    super.key,
    required this.viewYaw,
    required this.viewPitch,
    this.viewRoll = 0,
    this.size = 60,
    this.faceLabels,
    this.onFaceTap,
  });

  /// 点击某个面 → 回调该面 ID(建模软件同款一键归位)。
  final ValueChanged<String>? onFaceTap;

  final double viewYaw;
  final double viewPitch;

  /// 屏幕滚转(过极翻面动画期间与点云同步;见 CloudCamera.roll)。
  final double viewRoll;
  final double size;

  /// 面 ID → 本地化显示词(null 时直接显示英文 ID;内部语义/测试恒用
  /// 英文 ID,翻译只发生在绘制层)。
  final Map<String, String>? faceLabels;

  @override
  Widget build(BuildContext context) {
    final cube = SizedBox(
      width: size,
      height: size,
      // [2026-07-28 用户反馈] 不裁剪:此前 ClipRect 在转动时把伸出画布的
      // 边角裁没了(用户视觉上像被"相框"遮挡)。CustomPaint 允许溢出。
      child: CustomPaint(
        painter: _ViewCubePainter(
          yaw: viewYaw,
          pitch: viewPitch,
          roll: viewRoll,
          faceLabels: faceLabels,
        ),
      ),
    );
    if (onFaceTap == null) return cube;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final f = hitViewCubeFace(
          viewYaw,
          viewPitch,
          viewRoll,
          Size(size, size),
          d.localPosition,
        );
        if (f != null) onFaceTap!(f);
      },
      child: cube,
    );
  }
}

class _ViewCubePainter extends CustomPainter {
  const _ViewCubePainter({
    required this.yaw,
    required this.pitch,
    required this.roll,
    this.faceLabels,
  });

  final double yaw;
  final double pitch;
  final double roll;
  final Map<String, String>? faceLabels;

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
      // [2026-07-28] 与 hitViewCubeFace 同源常量:两处必须一致,否则
      // 点击位置与所见错位。
      fillK: kViewCubeFillK,
      orthographic: true,
      roll: roll,
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
    // [2026-07-28 用户签决] 面**实心不透明**(此前 0x2E 半透明,叠在一起
    // 像玻璃);**每个朝相机的面都一直显示文字**(此前只画最正对的一面)。
    final primary = primaryViewCubeFace(yaw, pitch);
    for (final f in faces) {
      final (_, _, nd) = proj.project(f.normal[0], f.normal[1], f.normal[2]);
      final facing = nd < centerDepth - 1e-9;
      if (!facing) continue; // 实心后背面被完全遮挡,不画
      final pts = f.corners
          .map((c) {
            final (sx, sy, _) = proj.project(c[0], c[1], c[2]);
            return Offset(sx, sy);
          })
          .toList(growable: false);
      final path = Path()..addPolygon(pts, true);
      canvas.drawPath(
        path,
        Paint()
          // 当前正对的面提亮,一眼看出朝向。
          ..color = f.label == primary
              ? const Color(0xFF8A8A90)
              : const Color(0xFF5A5A60),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFFFFFFFF),
      );
      _drawFaceLabel(canvas, faceLabels?[f.label] ?? f.label, pts);
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
    // 面投影包围盒 —— 斜视角下的面很窄,字号要自适应,否则文字跑出面外。
    var minX = pts[0].dx, maxX = pts[0].dx, minY = pts[0].dy, maxY = pts[0].dy;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final availW = (maxX - minX) * 0.86, availH = (maxY - minY) * 0.86;

    TextPainter build(double fs) => TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: fs,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Color(0x99000000), blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    for (var fs = 11.0; fs >= 6.0; fs -= 1.0) {
      final tp = build(fs);
      if (tp.width <= availW && tp.height <= availH) {
        tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
        return;
      }
    }
    // 面太窄(接近侧视)⇒ 放弃这一面的文字,不硬塞出界。
  }

  @override
  bool shouldRepaint(_ViewCubePainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.roll != roll ||
      old.faceLabels != faceLabels;
}
