import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';

const PinholeIntrinsics native640 = PinholeIntrinsics(
  fx: 437.222, fy: 437.222, cx: 318.878, cy: 239.359,
  imageWidth: 640, imageHeight: 480,
);

void main() {
  group('视锥:总视场是两个半角之和', () {
    test('🔴 主点居中假设会把上游那个 27% 误差算出来', () {
      // 上游 XRSLAM_iOS.mm:121 用的 640x480 标定。
      const double fy = 483.302341374, cy = 314.618580309;
      const double h = 480; // 那份标定的图像高(640x480)
      final double wrong = 2 * math.atan(cy / fy) * 180 / math.pi;
      final double right = (math.atan(cy / fy) + math.atan((h - cy) / fy)) * 180 / math.pi;
      expect(wrong, closeTo(66.13, 0.02), reason: '上游硬编码的值');
      expect(right, closeTo(51.95, 0.02), reason: '真实总垂直视场');
      expect(wrong - right, greaterThan(14.0), reason: '差 14 度以上');
    });

    test('主点居中时两种约定退化成同一个对称视锥', () {
      const PinholeIntrinsics centred = PinholeIntrinsics(
        fx: 400, fy: 400, cx: 320, cy: 240, imageWidth: 640, imageHeight: 480);
      final f = CameraProjection.frustum(centred,
          near: 0.1, far: 100, convention: PrincipalPointConvention.corner)!;
      expect(f.left, closeTo(-f.right, 1e-12));
      expect(f.top, closeTo(-f.bottom, 1e-12));
    });

    test('非居中主点必须产生非对称视锥', () {
      final f = CameraProjection.frustum(native640,
          near: 0.1, far: 100, convention: PrincipalPointConvention.corner)!;
      expect((f.left + f.right).abs(), greaterThan(1e-6), reason: '不能是对称的');
      // cx=318.878 < 320 ⇒ 左边比右边窄。
      expect(f.left.abs(), lessThan(f.right.abs()));
    });

    test('半像素约定:两种约定差恰好半个像素', () {
      final a = CameraProjection.frustum(native640,
          near: 1.0, far: 100, convention: PrincipalPointConvention.corner)!;
      final b = CameraProjection.frustum(native640,
          near: 1.0, far: 100, convention: PrincipalPointConvention.pixelCenter)!;
      // pixelCenter 的 left 多 0.5 像素 ⇒ 差 0.5/fx。
      expect((b.left - a.left).abs(), closeTo(0.5 / native640.fx, 1e-12));
      expect((b.right - a.right).abs(), closeTo(0.5 / native640.fx, 1e-12));
    });

    test('拒绝坏输入而不是返回单位视锥', () {
      expect(CameraProjection.frustum(native640,
          near: 0, far: 100, convention: PrincipalPointConvention.corner), isNull);
      expect(CameraProjection.frustum(native640,
          near: 10, far: 1, convention: PrincipalPointConvention.corner), isNull);
      const bad = PinholeIntrinsics(fx: 0, fy: 1, cx: 1, cy: 1,
          imageWidth: 10, imageHeight: 10);
      expect(CameraProjection.frustum(bad,
          near: 0.1, far: 1, convention: PrincipalPointConvention.corner), isNull);
    });
  });

  group('裁剪:顺序是先减后缩', () {
    test('纯平移裁剪只移主点,不动焦距', () {
      const crop = ImageCrop(offsetX: 100, offsetY: 50, width: 400, height: 300);
      final k = CameraProjection.applyCrop(native640, crop);
      expect(k.fx, native640.fx);
      expect(k.cx, closeTo(native640.cx - 100, 1e-12));
      expect(k.cy, closeTo(native640.cy - 50, 1e-12));
      expect(k.imageWidth, 400);
    });

    test('🔴 先缩后减会给出不同答案 —— 这正是那个经典 bug', () {
      const crop = ImageCrop(offsetX: 100, offsetY: 50, width: 400,
          height: 300, scaleX: 0.5, scaleY: 0.5);
      final correct = CameraProjection.applyCrop(native640, crop);
      // 正确:(cx - 100) * 0.5
      expect(correct.cx, closeTo((native640.cx - 100) * 0.5, 1e-12));
      // 错误顺序会得到 cx*0.5 - 100,两者差 50 像素。
      final wrong = native640.cx * 0.5 - 100;
      expect((correct.cx - wrong).abs(), closeTo(50.0, 1e-9),
          reason: '顺序反了会差 50 像素');
    });

    test('ImageCrop.none 是恒等', () {
      final k = CameraProjection.applyCrop(native640, ImageCrop.none);
      expect(k.cx, native640.cx);
      expect(k.imageWidth, native640.imageWidth);
    });
  });

  group('aspect-fill 裁剪', () {
    test('实算的那一场:1920x1440 进 1179x2556,每边切 277.2px', () {
      final crop = CameraProjection.aspectFillCrop(
        imageWidth: 1440, imageHeight: 1920,   // 旋转后的竖向图
        viewportWidth: 1179, viewportHeight: 2556,
      );
      // scale = max(1179/1440, 2556/1920) = max(0.8188, 1.33125) = 1.33125
      // 可见宽 = 1179/1.33125 = 885.6 ⇒ 每边 (1440-885.6)/2 = 277.2
      expect(crop.offsetX, closeTo(277.2, 0.05));
      expect(crop.width, closeTo(885.6, 0.1));
      expect(crop.offsetY, closeTo(0, 1e-9), reason: '长轴不裁');
      expect(crop.height, closeTo(1920, 1e-6));
    });

    test('比例相同则不裁', () {
      final crop = CameraProjection.aspectFillCrop(
        imageWidth: 640, imageHeight: 480,
        viewportWidth: 1280, viewportHeight: 960);
      expect(crop.offsetX, closeTo(0, 1e-9));
      expect(crop.offsetY, closeTo(0, 1e-9));
    });

    test('裁剪后视场确实变窄', () {
      final crop = CameraProjection.aspectFillCrop(
        imageWidth: 1440, imageHeight: 1920,
        viewportWidth: 1179, viewportHeight: 2556);
      const k = PinholeIntrinsics(fx: 1459, fy: 1459, cx: 720, cy: 960,
          imageWidth: 1440, imageHeight: 1920);
      final full = CameraProjection.frustum(k, near: 0.1, far: 100,
          convention: PrincipalPointConvention.corner)!;
      final cut = CameraProjection.frustum(
          CameraProjection.applyCrop(k, crop),
          near: 0.1, far: 100, convention: PrincipalPointConvention.corner)!;
      expect(cut.horizontalFovDegrees, lessThan(full.horizontalFovDegrees));
      final double ratio = cut.horizontalFovDegrees / full.horizontalFovDegrees;
      expect(ratio, lessThan(0.75), reason: '短轴视场应当少一大截,实得 $ratio');
      expect(cut.verticalFovDegrees,
          closeTo(full.verticalFovDegrees, 1e-6), reason: '长轴不该变');
    });
  });

  group('GL 投影矩阵', () {
    test('把近平面四角映到 NDC 的 ±1', () {
      final f = CameraProjection.frustum(native640, near: 0.1, far: 100,
          convention: PrincipalPointConvention.corner)!;
      final m = CameraProjection.glProjectionColumnMajor(f);
      // 近平面左下角 (left, bottom, -near) 应映到 (-1,-1,-1)。
      List<double> proj(double x, double y, double z) {
        final double cx = m[0]*x + m[4]*y + m[8]*z + m[12];
        final double cy = m[1]*x + m[5]*y + m[9]*z + m[13];
        final double cz = m[2]*x + m[6]*y + m[10]*z + m[14];
        final double cw = m[3]*x + m[7]*y + m[11]*z + m[15];
        return <double>[cx/cw, cy/cw, cz/cw];
      }
      final lb = proj(f.left, f.bottom, -f.near);
      expect(lb[0], closeTo(-1, 1e-9));
      expect(lb[1], closeTo(-1, 1e-9));
      expect(lb[2], closeTo(-1, 1e-9), reason: 'GL 约定:近平面 z_ndc = -1');
      final rt = proj(f.right, f.top, -f.near);
      expect(rt[0], closeTo(1, 1e-9));
      expect(rt[1], closeTo(1, 1e-9));
      // 远平面 z_ndc = +1。
      final far = proj(0, 0, -f.far);
      expect(far[2], closeTo(1, 1e-9));
    });

    test('🔴 GL 约定判别式:近平面 z/w = -1(Metal 会是 0)', () {
      final f = CameraProjection.frustum(native640, near: 0.1, far: 100,
          convention: PrincipalPointConvention.corner)!;
      final m = CameraProjection.glProjectionColumnMajor(f);
      // 这正是用来测 ARKit 矩阵是哪种约定的那一行。
      final double cz = m[2]*0 + m[6]*0 + m[10]*(-f.near) + m[14];
      final double cw = m[3]*0 + m[7]*0 + m[11]*(-f.near) + m[15];
      expect(cz/cw, closeTo(-1, 1e-12));
    });
  });
}
