import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AR 相框贴图的朝向契约。**同一个症状躺倒过两次**:
///
///   2026-09-08 build ~126:`encodeCIImageAsJpeg` 漏写 EXIF 朝向标签,而卡片
///     用 `kCGImageSourceCreateThumbnailWithTransform: true` 解码 —— 没标签就是
///     恒等变换,图保持传感器原生横向。
///   2026-09-10 build 131:我把贴图从磁盘解耦到内存(为了"黑框与照片同时出现"),
///     新生产者只挂了 `UIImage(cgImage:orientation: .right)`。**但消费端
///     `SCNMaterial.diffuse.contents` 只读像素,不看 UIImage.imageOrientation**
///     (那个标志只有 UIKit 绘制路径才认)⇒ 又躺倒。
///
/// 两次的共同点不是"忘了转朝向",是**耦合**:消费端有一个"旋转必须已经烤进
/// 像素"的隐含契约,而它哪儿都没写 —— 不在类型里、不在断言里、不在测试里。
/// 第一个生产者碰巧满足,第二个生产者满足的是另一个看起来同样合理的契约。
///
/// 修法是把契约抬进**类型**:整条链的载体从 UIImage 换成 CGImage,"朝向标志"
/// 在这条路上根本不存在,生产者只剩一个选择 —— 把旋转烤进像素。
/// 这个测试钉住的就是"类型里说得清楚",不是钉某一行写法。
void main() {
  final plugin = File('ios/Runner/OfficialAetherARKitPlugin.swift');

  late String swift;

  setUpAll(() {
    expect(plugin.existsSync(), isTrue, reason: '插件源码不在,契约无从谈起');
    swift = plugin.readAsStringSync();
  });

  /// 只留代码行。判据**绝不能匹配到注释** —— 这条规矩是 2026-08-22 立的,
  /// 今天写这个测试时又当场踩了一次:函数体的说明文字里提到 `UIImage(`,
  /// "这条路上不许出现 UIImage" 就被自己的注释判红了。
  String codeOnly(String src) =>
      src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

  /// 取一个 Swift 函数的函数体(按大括号配平),找不到就让调用方大声失败。
  String bodyOf(String signature) {
    final start = swift.indexOf(signature);
    expect(
      start,
      greaterThan(0),
      reason:
          '锚点没了:$signature —— 改名字可以,但要连这条契约一起改,'
          '别让它静默失明',
    );
    var i = swift.indexOf('{', start);
    var depth = 0;
    for (var j = i; j < swift.length; j++) {
      if (swift[j] == '{') depth++;
      if (swift[j] == '}') {
        depth--;
        if (depth == 0) return swift.substring(i, j + 1);
      }
    }
    fail('大括号没配平:$signature');
  }

  test('贴图链的载体是 CGImage —— 接口表达不出"朝向标志"', () {
    expect(
      swift.contains('let textureCGImage: CGImage?'),
      isTrue,
      reason:
          'PhotoCardSpec 的贴图字段必须是 CGImage。换回 UIImage 就等于把'
          '「像素已转正」这个契约重新藏进注释里',
    );
    expect(
      swift.contains(
        'static var photoCardThumbByEvidencePath: [String: CGImage]',
      ),
      isTrue,
      reason:
          '早信号那一刻寄存贴图的表也必须是 CGImage,否则链条中间还能塞进'
          '一个带朝向标志的 UIImage',
    );
    expect(
      swift.contains('private func buildPhotoCard(\n    image: CGImage,'),
      isTrue,
      reason:
          '消费端入参必须是 CGImage —— 它把这张图直接交给 '
          'SCNMaterial.diffuse.contents,而 SceneKit 不看 imageOrientation',
    );
  });

  test('内存生产者把旋转烤进像素,且不经手 UIImage', () {
    final body = codeOnly(bodyOf('private static func makePhotoCardThumb('));
    expect(
      body.contains('.oriented('),
      isTrue,
      reason:
          '内存路径必须在 CIImage 阶段把旋转烤进像素;'
          '只挂 UIImage 的朝向标志是 build 131 躺倒的原因',
    );
    expect(
      body.contains('UIImage('),
      isFalse,
      reason:
          '这条路上一旦出现 UIImage,"朝向标志被 SceneKit 无视"这个坑就'
          '又能踩进来了',
    );
  });

  test('磁盘生产者仍然让 ImageIO 烤旋转(阳性对照:另一条路没被改坏)', () {
    expect(
      swift.contains('kCGImageSourceCreateThumbnailWithTransform: true'),
      isTrue,
      reason: '磁盘路径靠它把 EXIF 旋转烤进像素;改成 false 就回到 09-08',
    );
  });

  test('宽高取真实像素,不问会按朝向撒谎的 UIImage.size', () {
    final body = codeOnly(bodyOf('private func buildPhotoCard('));
    expect(
      body.contains('CGFloat(image.width) / CGFloat(image.height)'),
      isTrue,
      reason:
          'texAspect 必须用 CGImage 的真实像素宽高。UIImage.size 会按 '
          'imageOrientation 交换宽高 —— 131 躺倒的第二半:纹理是横的、size 报'
          '竖的 0.75,UV 裁剪跟着算错',
    );
  });
}
