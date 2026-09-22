// 我们自己相机栈的「高清拍照」门面测试。
//
// 🔴 这里**不开相机、也不需要真机**:测的是两件在主机上就能证伪的事 ——
//   ① 记录解析(9 个 double + 路径 ⇄ PwCapturedPhoto)的口径与拒绝条件;
//   ② 符号不在时的**降级**行为(主机上 `pw_camera_slot_*` 必然查不到,
//      所以这条是天然的阴性对照,不是模拟出来的)。
// 原生侧拍照本身只能在真机上验(见 PwCameraSlot.swift 的 MARK: 高清拍照)。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/pw_camera_photo_ffi.dart';
import 'package:pocketworld_flutter/vio/pose/camera_slot_ffi.dart';

void main() {
  group('PwCapturedPhoto.parse', () {
    test('按冻结顺序解析 9 个 double', () {
      final PwCapturedPhoto? p = PwCapturedPhoto.parse(
        '/tmp/pw_photos/7.heic',
        <double>[7, 3200.5, 3201.25, 2016, 1512, 4032, 3024, 12345.678, 0.0083],
      );
      expect(p, isNotNull);
      expect(p!.requestId, 7);
      expect(p.path, '/tmp/pw_photos/7.heic');
      expect(p.fx, 3200.5);
      expect(p.fy, 3201.25);
      expect(p.cx, 2016);
      expect(p.cy, 1512);
      expect(p.width, 4032);
      expect(p.height, 3024);
      expect(p.timestampSeconds, 12345.678);
      expect(p.exposureSeconds, 0.0083);
    });

    test('sidecar 是同目录同名 .json', () {
      final PwCapturedPhoto p = PwCapturedPhoto.parse(
        '/var/mobile/Documents/pw_photos/42.heic',
        <double>[42, 1, 1, 1, 1, 8, 6, 0, 0],
      )!;
      expect(p.sidecarPath, '/var/mobile/Documents/pw_photos/42.json');
    });

    test('没有扩展名时 sidecar 直接追加 .json,不吃掉目录里的点', () {
      final PwCapturedPhoto p = PwCapturedPhoto.parse(
        '/a.b/photos/9',
        <double>[9, 1, 1, 1, 1, 8, 6, 0, 0],
      )!;
      expect(p.sidecarPath, '/a.b/photos/9.json');
    });

    test('半条记录一律判 null —— 宁可当没结果', () {
      // 少于 9 个数
      expect(
        PwCapturedPhoto.parse('/p.heic', <double>[1, 2, 3]),
        isNull,
      );
      // 空路径
      expect(
        PwCapturedPhoto.parse('', <double>[1, 1, 1, 1, 1, 8, 6, 0, 0]),
        isNull,
      );
      // 尺寸为 0:原生侧连文件头都没读出来,内参无处可缩
      expect(
        PwCapturedPhoto.parse('/p.heic', <double>[1, 1, 1, 1, 1, 0, 6, 0, 0]),
        isNull,
      );
      expect(
        PwCapturedPhoto.parse('/p.heic', <double>[1, 1, 1, 1, 1, 8, 0, 0, 0]),
        isNull,
      );
      // 非有限
      expect(
        PwCapturedPhoto.parse(
            '/p.heic', <double>[1, 1, 1, 1, 1, double.nan, 6, 0, 0]),
        isNull,
      );
      expect(
        PwCapturedPhoto.parse(
            '/p.heic', <double>[double.infinity, 1, 1, 1, 1, 8, 6, 0, 0]),
        isNull,
      );
    });
  });

  group('符号不在时的降级(主机上跑 = 天然阴性对照)', () {
    test('available 为 false 且不抛', () {
      expect(PwCameraPhoto.available, isFalse);
      expect(PwCameraSlot.photoAvailable, isFalse);
    });

    test('capture/result 返回 null 而不是抛', () {
      expect(PwCameraPhoto.capture(1), isNull);
      expect(PwCameraPhoto.result(), isNull);
      expect(PwCameraPhoto.drain(), isEmpty);
    });

    test('冻结的门面名字在 PwCameraSlot 上,且同样降级', () {
      // 另一位 agent 按这两个名字调用 —— 名字改了就是接口破坏。
      expect(PwCameraSlot.capturePhoto(1), isNull);
      expect(PwCameraSlot.photoResult(), isNull);
    });
  });
}
