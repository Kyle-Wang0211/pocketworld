// sparse_thumbnail.dart — 草稿卡片的稀疏点云缩略图(离屏渲染 + 磁盘缓存)。
//
// [2026-08-07 用户签决,学 Polycam] 草稿页卡片展示**稀疏点云**(斜上 45°)而不是
// 照片;真彩 PLY、背景纯黑。
//
// 🔴 为什么必须缓存成图片而不是每张卡片实时渲染:草稿页是滚动网格,一屏 4-6 张、
// 全量十几张,每张几十万点。这个 App 的热稳定是硬约束(拍摄链路已因热压挂死过
// GPU、冻结过相机),在列表里铺实时点云是往火上加油。所以:离屏画一次 → 存 PNG
// → 卡片只是 Image.file。PLY 换了(mtime 变新)才重画。
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'official_capture/sparse_cloud_view.dart';

/// 缩略图文件名(与 PLY 同目录)。
const String kSparseThumbFileName = 'official_sparse_thumb.png';

/// 缩略图边长(正方形)。卡片按 BoxFit.cover 裁,所以取够用的最小尺寸 ——
/// 512 在 3x 屏上覆盖约 170pt 宽的卡片,再大只是浪费磁盘和渲染时间。
const int kSparseThumbSize = 512;

/// 缩略图与详情页初始视角:**斜上 45°**。
///
/// [2026-08-07 用户签决] "在草稿页面就展示稀疏点云(斜上45度)……打开后稀疏点云
/// 的默认角度也变成了斜上45度,而非正上方。在用户进入编辑页面的时候,点云在转向
/// 正上方。"
///
/// 俯视为负 pitch,所以斜上 45° = −π/4。yaw 取 π 与"顶"预设同侧,这样从缩略图
/// 放大进详情、再进编辑页归位到正上方,是同一条经线上的连续运动、不会横向甩。
const double kSparseThumbPitch = -math.pi / 4;
const double kSparseThumbYaw = math.pi;

/// 缩略图路径(不保证存在)。
String sparseThumbPathFor(String captureDir) =>
    '$captureDir/$kSparseThumbFileName';

/// 缓存是否可用:PNG 存在、非空,且**不比 PLY 旧**。
///
/// 比 mtime 而不是只看存在:重新跑一遍重建会产出新的 PLY,旧缩略图必须失效。
bool sparseThumbFresh({required String plyPath, required String thumbPath}) {
  try {
    final ply = File(plyPath).statSync();
    if (ply.type == FileSystemEntityType.notFound || ply.size <= 0) {
      return false;
    }
    final thumb = File(thumbPath).statSync();
    if (thumb.type == FileSystemEntityType.notFound || thumb.size <= 0) {
      return false;
    }
    return !thumb.modified.isBefore(ply.modified);
  } catch (_) {
    return false;
  }
}

/// 点精灵(白色圆盘)—— painter 用 drawRawAtlas,必须给它一张图。
/// 离屏渲染每次都建一张成本可忽略(16×16),但多张缩略图连着画时复用更省。
Future<ui.Image> buildPointSprite() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawCircle(
    const Offset(8, 8),
    7,
    Paint()
      ..color = Colors.white
      ..isAntiAlias = true,
  );
  return rec.endRecording().toImage(16, 16);
}

/// 把点云离屏画成 PNG 字节。纯函数(不碰文件系统),便于测试。
///
/// 背景**纯黑**,与三维编辑舱和详情页一致(用户签决"整个屏幕背景统一纯黑")。
Future<Uint8List?> renderSparseThumbBytes({
  required Float32List xyz,
  required Uint8List rgb,
  required ui.Image sprite,
  int size = kSparseThumbSize,
}) async {
  if (xyz.length < 3) return null;
  // pivot 与查看器同源(orbitPivotOf = 范围中心):卡片缩略图和打开后的详情页
  // 必须同一姿态,否则放大那一下会跳(见 kSparseThumbPitch 的注释)。
  final pivot = orbitPivotOf(xyz);
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final box = Size(size.toDouble(), size.toDouble());

  canvas.drawRect(
    Rect.fromLTWH(0, 0, box.width, box.height),
    Paint()..color = Colors.black,
  );

  SparseCloudPainter(
    xyz: xyz,
    rgb: rgb,
    sprite: sprite,
    yaw: kSparseThumbYaw,
    pitch: kSparseThumbPitch,
    zoom: 1,
    panX: 0,
    panY: 0,
    pivotX: pivot[0],
    pivotY: pivot[1],
    pivotZ: pivot[2],
    // 缩略图比屏幕小得多,点要相应放大才不至于稀成一片噪点。
    pointSize: 3.0,
    exposure: 1.0,
    tone: 2, // Khronos PBR Neutral —— 与详情页同一个色调映射,颜色不跳
    orthographic: kCloudOrthographic,
    drawSelectionWireframe: false,
  ).paint(canvas, box);

  final img = await rec.endRecording().toImage(size, size);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data?.buffer.asUint8List();
}

/// 正在渲染中的缩略图路径 —— 防止"落盘即画"和草稿页的懒补图同时画同一张。
/// 两者写的是同一个文件、内容也一样,所以竞态无害,但白烧一次 GPU 不值得。
final Set<String> _inFlight = <String>{};

/// 用**内存里**的点云直接画封面 —— 在稀疏 PLY 刚落盘那一刻调用。
///
/// [2026-08-08 用户实机指认] "在刚完成后我退出到草稿页面,还是显示照片,等了几秒
/// 才变成点云截图。我需要点云诞生出来的那一刻就删除封面照片然后立刻替换成点云
/// 截图。" —— 原先唯一的生成路径是草稿页每 2 秒轮询后懒补(见 me_page 的
/// _ensureCloudThumbs),所以"PLY 已落盘、封面还没画"这段窗口里卡片显示照片,
/// 画完才肉眼跳变一下。这里把生成提前到落盘现场:
///   ① 时机对 —— 点云诞生的同一刻,用户还在预览页看结果,回到草稿页时封面已就位;
///   ② 不回读磁盘 —— 调用方手里就是刚写出去的那份 xyz/rgb,省一次 PLY 解析。
///
/// 必须在 PLY 写完之后调用:[sparseThumbFresh] 比的是 mtime,先画封面会让它比
/// PLY 旧、立刻被判定过期而重画。
Future<String?> writeSparseThumbFrom({
  required String captureDir,
  required Float32List xyz,
  required Uint8List rgb,
}) async {
  final thumbPath = sparseThumbPathFor(captureDir);
  if (_inFlight.contains(thumbPath)) return null;
  _inFlight.add(thumbPath);
  ui.Image? sprite;
  try {
    sprite = await buildPointSprite();
    final bytes = await renderSparseThumbBytes(
      xyz: xyz,
      rgb: rgb,
      sprite: sprite,
    );
    if (bytes == null) return null;
    await File(thumbPath).writeAsBytes(bytes, flush: true);
    return thumbPath;
  } catch (e, st) {
    // 不静默吞:失败只是退回"卡片先显示照片、草稿页稍后补图",但真机上这是唯一线索。
    debugPrint('[SparseThumb] live write failed for $captureDir: $e\n$st');
    return null;
  } finally {
    sprite?.dispose();
    _inFlight.remove(thumbPath);
  }
}

/// 生成并写盘;已有新鲜缓存则直接返回路径,不重画。
///
/// 返回 null 表示这条记录还没有可用的 PLY(仍在生成中 / 被中断)。
Future<String?> ensureSparseThumb({
  required String captureDir,
  required String plyPath,
  ui.Image? sprite,
}) async {
  final thumbPath = sparseThumbPathFor(captureDir);
  if (sparseThumbFresh(plyPath: plyPath, thumbPath: thumbPath)) {
    return thumbPath;
  }
  // 落盘现场已经在画这一张了 ⇒ 让给它,别重复烧 GPU。
  if (_inFlight.contains(thumbPath)) return null;
  final cloud = _loadPly(plyPath);
  if (cloud == null) {
    debugPrint('[SparseThumb] cannot read ply: $plyPath');
    return null;
  }

  final ownSprite = sprite == null;
  final s = sprite ?? await buildPointSprite();
  try {
    final bytes = await renderSparseThumbBytes(
      xyz: cloud.$1,
      rgb: cloud.$2,
      sprite: s,
    );
    if (bytes == null) {
      debugPrint('[SparseThumb] render returned null for $plyPath');
      return null;
    }
    await File(thumbPath).writeAsBytes(bytes, flush: true);
    return thumbPath;
  } catch (e, st) {
    // ⚠️ 不要静默吞:真机上失败时这是唯一线索(release 日志走 DeviceLog)。
    debugPrint('[SparseThumb] failed for $plyPath: $e\n$st');
    return null;
  } finally {
    if (ownSprite) s.dispose();
  }
}

/// 极简 PLY 读取(与 sparse_cloud_viewer_page 的 loadSparsePly 同格式)。
/// 这里独立实现是为了不把整个 viewer 页面拖进草稿列表的依赖里。
(Float32List, Uint8List)? _loadPly(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    const marker = 'end_header\n';
    var headEnd = -1;
    final n = marker.codeUnits;
    final limit = bytes.length - n.length;
    for (var i = 0; i <= limit && i < 4096; i++) {
      var hit = true;
      for (var j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        headEnd = i;
        break;
      }
    }
    if (headEnd < 0) return null;
    final header = String.fromCharCodes(bytes.sublist(0, headEnd));
    final m = RegExp(r'element vertex (\d+)').firstMatch(header);
    if (m == null || !header.contains('binary_little_endian')) return null;
    final count = int.parse(m.group(1)!);
    final body = bytes.sublist(headEnd + marker.length);
    if (count <= 0 || body.length < count * 15) return null;
    final xyz = Float32List(count * 3);
    final rgb = Uint8List(count * 3);
    final bd = ByteData.sublistView(body);
    for (var i = 0; i < count; i++) {
      final o = i * 15;
      xyz[i * 3] = bd.getFloat32(o, Endian.little);
      xyz[i * 3 + 1] = bd.getFloat32(o + 4, Endian.little);
      xyz[i * 3 + 2] = bd.getFloat32(o + 8, Endian.little);
      rgb[i * 3] = body[o + 12];
      rgb[i * 3 + 1] = body[o + 13];
      rgb[i * 3 + 2] = body[o + 14];
    }
    return (xyz, rgb);
  } catch (_) {
    return null;
  }
}
