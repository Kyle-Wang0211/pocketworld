// 图像元数据剥离 —— L2 通用防御。
//
// 背景(2026-08-18 实测,不是推断):
//   EXIF **会**穿过缩略图编码路径。走完
//   decode → bakeOrientation → copyRotate → copyResize → encodeJpg
//   之后,产物里 Make/Model 仍在。此前"从像素重新编码所以不带 EXIF"的
//   想法被证伪 —— `image` 包的 copyResize/copyRotate 会把 exif 一并带到
//   新的 Image 对象上。
//
// 当前 GPS 泄露风险为零:Info.plist 只有 NSCamera / NSLocalNetwork /
// NSMotion,**零 NSLocation***,代码零 CoreLocation 引用 ⇒ iOS 不会往
// 照片写 GPS。
//
// 那为什么还要做:
//   因为"零 GPS"是一个**依赖于未来不改变的假设**。08-16 已经在讨论
//   "出生证明"(时间 + 精准地点)功能;那条线一旦点亮,发布链路立刻开始
//   携带住址级信息 —— 而 3D 扫描作品往往就是在家里拍的。把剥离放在编码
//   这一层,意味着即便将来加了定位权限,社区产物默认仍是干净的:安全属性
//   不该建立在"记得在另一处也改一下"之上。
//
// 顺带去掉设备指纹(Make/Model/Software/拍摄时间)。
//
// 可移植性:纯 Dart + image 包,与后端无关 ⇒ 海外与国内两个部署共用同一份。

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 编码为 JPEG,并确保产物不携带任何 EXIF/GPS 元数据。
///
/// 是 `img.encodeJpg` 的直接替代:签名相同,像素输出相同,只是元数据被清空。
/// 传入的 [image] 会被就地清除 exif —— 调用方此后若还要读它的元数据,需要
/// 自己先取走。缩略图链路上没有这种用法。
Uint8List encodeSanitizedJpg(img.Image image, {int quality = 88}) {
  _stripMetadata(image);
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// 清空全部 EXIF 目录。
///
/// 逐个目录清而不是只清 gpsIfd:设备型号、软件版本、拍摄时间同样是指纹,
/// 且"只清 GPS"会随着 image 包新增目录而悄悄漏掉新字段。
void _stripMetadata(img.Image image) {
  final exif = image.exif;
  exif.imageIfd.data.clear();
  exif.thumbnailIfd.data.clear();
  exif.exifIfd.data.clear();
  exif.gpsIfd.data.clear();
  exif.interopIfd.data.clear();
}
