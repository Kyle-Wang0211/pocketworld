// 文件类型签名(magic bytes)校验 —— L2 通用防御。
//
// 为什么不能信任扩展名与 Content-Type:
//   两者都是**调用方声明**的,攻击者完全控制。OWASP 的口径是文件类型必须
//   由内容判定,而不是由声明判定。真实后果不是抽象的:公开可下载的存储桶
//   被当作免费的恶意软件分发 CDN,是有大量公开先例的一类滥用 —— 代价是
//   出口流量账单、域名信誉、以及应用商店层面的连带风险。
//
// 本文件只做**判定**,不做处置。判定规则是纯函数、无依赖,因此:
//   • 客户端可以在上传前用它挡住误操作;
//   • 服务端将来做强制校验时用**同一套规则**,不会出现两端标准不一致;
//   • 海外与国内两个部署共用同一份 —— 这正是 L2 的定义。
//
// ⚠️ 边界要说清楚:客户端调用**不是安全边界**。攻击者会直接改客户端。
//    它挡的是误操作,以及为服务端强制校验预备规则。真正的强制必须在
//    服务端,见 PENDING 一节的说明。

import 'dart:typed_data';

/// 本项目允许的 3D 资产格式。
enum AssetKind {
  /// PLY 点云 —— 当前发布链路的主格式(publish_service 写 `<uid>/<hash>.ply`)。
  ply,

  /// glTF 二进制 —— works 桶 MIME 白名单里的 model/gltf-binary。
  glb,

  /// JPEG 缩略图。
  jpeg,

  /// PNG 缩略图(采集路线的 official_sparse_thumb.png 走这条)。
  png,
}

/// 判定 [bytes] 的真实类型;无法识别时返回 null。
///
/// 只读取文件头,不解析整个文件 —— 调用方可以只传前几百字节(例如服务端用
/// HTTP Range 请求取头部),避免为了校验而下载整个模型。
AssetKind? detectAssetKind(Uint8List bytes) {
  if (_matchesAscii(bytes, 'ply')) return AssetKind.ply;
  if (_matchesAscii(bytes, 'glTF')) return AssetKind.glb;
  if (_matchesBytes(bytes, const [0xFF, 0xD8, 0xFF])) return AssetKind.jpeg;
  if (_matchesBytes(bytes, const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ])) {
    return AssetKind.png;
  }
  return null;
}

/// 判定内容是否与**声明的**扩展名相符。
///
/// 这是真正要问的问题:不是"这是什么",而是"它是不是它自称的那个"。
bool matchesDeclaredExtension(Uint8List bytes, String path) {
  final expected = kindForExtension(path);
  if (expected == null) return false;
  return detectAssetKind(bytes) == expected;
}

/// 由路径后缀推断应有的类型;不认识的后缀返回 null(默认拒绝而非放行)。
AssetKind? kindForExtension(String path) {
  final lower = path.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return null;
  switch (lower.substring(dot + 1)) {
    case 'ply':
      return AssetKind.ply;
    case 'glb':
      return AssetKind.glb;
    case 'jpg':
    case 'jpeg':
      return AssetKind.jpeg;
    case 'png':
      return AssetKind.png;
    default:
      return null;
  }
}

/// 判定所需的最小字节数。服务端做 Range 请求时取这么多就够。
const int kSignatureProbeBytes = 16;

bool _matchesAscii(Uint8List bytes, String magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

bool _matchesBytes(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}
