// 图像元数据剥离。
//
// 为什么需要:2026-08-18 实测确认 EXIF **会**穿过缩略图编码路径
// (decode → bakeOrientation → copyRotate → copyResize → encodeJpg),
// 产物仍带 Make/Model。此前"从像素重编码所以不带 EXIF"的推断是错的。
//
// 当前 GPS 风险为零 —— Info.plist 只有 NSCamera/NSLocalNetwork/NSMotion,
// **零 NSLocation***,且代码零 CoreLocation 引用,所以 iOS 不会往照片写 GPS。
// 剥离的真正价值是**消除对"永不加位置权限"这个假设的依赖**:08-16 已在讨论
// "出生证明"(时间+地点)功能,那条线一旦点亮,发布链路就会开始携带住址级信息。
// 一个 3D 扫描作品往往就是在家里拍的。
//
// 顺带去掉设备指纹(Make/Model/Software/拍摄时间)。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocketworld_flutter/util/image_sanitize.dart';

img.Image _tagged({int w = 1200, int h = 900}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(120, 30, 30));
  im.exif.imageIfd['Make'] = 'ProbeCam';
  im.exif.imageIfd['Model'] = 'SecretDevice';
  im.exif.imageIfd['Software'] = 'PocketWorld/1.0';
  return im;
}

void main() {
  test('控制组:未剥离时 EXIF 确实会穿过(否则本测试无意义)', () {
    final raw = Uint8List.fromList(img.encodeJpg(_tagged(), quality: 88));
    final back = img.decodeJpg(raw)!;
    // 注意类型:image 包返回 IfdValueAscii 而非 String,直接与字符串比较
    // 会失败得像'功能坏了',实则只是断言写法不对。
    expect(
      back.exif.imageIfd['Make']?.toString(),
      'ProbeCam',
      reason: 'image 包若不写 EXIF,剥离就是多余的 —— 这条断言守住前提',
    );
  });

  test('encodeSanitizedJpg 产物不含 Make/Model/Software', () {
    final out = encodeSanitizedJpg(_tagged(), quality: 88);
    final back = img.decodeJpg(out)!;
    expect(back.exif.imageIfd['Make'], isNull);
    expect(back.exif.imageIfd['Model'], isNull);
    expect(back.exif.imageIfd['Software'], isNull);
  });

  test('经过完整缩略图路径(bake→rotate→resize)后仍不含 EXIF', () {
    // 复刻 capture_page.dart:55-71 的处理顺序
    final tagged = _tagged(w: 1600, h: 1200);
    final encoded = Uint8List.fromList(img.encodeJpg(tagged, quality: 92));
    var image = img.bakeOrientation(img.decodeJpg(encoded)!);
    if (image.width > image.height) {
      image = img.copyRotate(image, angle: 90);
    }
    const maxEdge = 1024;
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge > maxEdge) {
      image = img.copyResize(
        image,
        width: image.width >= image.height ? maxEdge : null,
        height: image.height > image.width ? maxEdge : null,
        interpolation: img.Interpolation.average,
      );
    }
    final out = encodeSanitizedJpg(image, quality: 88);
    final back = img.decodeJpg(out)!;
    expect(back.exif.imageIfd['Make'], isNull);
    expect(back.exif.gpsIfd.keys, isEmpty);
  });

  test('像素内容不受影响 —— 剥离的是元数据,不是画面', () {
    final im = _tagged(w: 64, h: 64);
    final sanitized = img.decodeJpg(encodeSanitizedJpg(im, quality: 100))!;
    expect(sanitized.width, 64);
    expect(sanitized.height, 64);
    // JPEG 有损,取中心像素做量级比较而非逐位相等
    final p = sanitized.getPixel(32, 32);
    expect((p.r - 120).abs() < 12, isTrue, reason: 'r=${p.r}');
    expect((p.g - 30).abs() < 12, isTrue, reason: 'g=${p.g}');
  });

  test('输入本就无 EXIF 时也不报错', () {
    final plain = img.Image(width: 32, height: 32);
    img.fill(plain, color: img.ColorRgb8(10, 20, 30));
    final out = encodeSanitizedJpg(plain, quality: 88);
    expect(img.decodeJpg(out), isNotNull);
  });
}
