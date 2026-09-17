// camera_feed_triangle.dart — 相机背景的全屏三角形。
//
// ══ 这是复刻 ═══════════════════════════════════════════════════════════════
// 对照件:Filament v1.58.0
//   `ios/samples/hello-ar/hello-ar/FilamentArView/FullScreenTriangle.cpp`
// (Apache-2.0,© The Android Open Source Project)。下面每一个常量、每一个
// 开关都对得上它的某一行,注释里标了行号。
//
// 与上游的差别只有三处,都是"同一件事换个 API 说"而不是换做法:
//   1. 顶点属性 FLOAT3/FLOAT2,上游是 HALF4/HALF2。thermion 的
//      GeometrySceneAssetBuilder.cpp:168-169 把 POSITION 写死成 FLOAT3、
//      UV0 写死成 FLOAT2。数值等价:顶点属性缺的分量按 (0,0,0,1) 补,
//      所以 FLOAT3(-1,-1,1) 到着色器里就是 HALF4(-1,-1,1,1)。
//   2. 视锥剔除用运行时的 `setCulling(false)`,上游是构建期的
//      `.culling(false)`(FullScreenTriangle.cpp:98)。thermion 的
//      GeometrySceneAsset.cpp:43 把它写死成 true,而 Filament 公开了运行时
//      的 setter(RenderableManager.h:640-644),所以不用改共享的几何构建器。
//   3. 用 `createInstance()` 而不是 `getDefaultInstance()`。默认实例是
//      Material 自己的那一个,销毁边界更容易出错。
//
// ══ 🔴 三个一改就黑屏/倒像的点 ═════════════════════════════════════════════
//   * z = 1:`vertexDomain : device` 下顶点直接是裁剪空间。Filament 对
//     device 域会做一次 `z = z * -0.5 + 0.5` 的 GL→反向Z 归一,所以 z=1 落在
//     **远平面**,虚拟内容自然盖在它前面。写 0 或 -1 都会把背景推到前面去。
//   * UV (0,1)/(2,1)/(0,-1):配合 `flipUV : false`,得到的是**左上原点**的
//     UV —— 与 ARKit(`ARCamera.h:111`)和我们 display_transform.dart 的输出
//     同一个约定。
//   * 纹理必须建成 SAMPLER_EXTERNAL。不是 external 的纹理调
//     `setExternalImage` 是 `FILAMENT_CHECK_PRECONDITION(mExternal)` **硬崩**,
//     不是返回错误(filament `details/Texture.cpp:493`)。
//     材质那一侧写 `sampler2d` 是对的,上游就是这么写的 —— Metal 后端把
//     CVPixelBuffer 变成一张普通 MTLTexture(`MetalHandles.mm:700-707`)。

// thermion_flutter 把 thermion_dart 整包再导出(thermion_flutter.dart:6),
// 而 thermion_dart 又再导出 dart:typed_data 与 vector_math_64
// (thermion_dart.dart:3-4)。所以这一行就够了 —— 与 lib/ui/cube_scene.dart
// 的现役写法一致,不另加一个直接依赖。
import 'package:thermion_flutter/thermion_flutter.dart';

import '../pose/display_transform.dart';

/// 相机背景全屏三角形。
///
/// 生命周期:[create] → 每帧 [setFrame] + [setTransform] → [destroy]。
class CameraFeedTriangle {
  CameraFeedTriangle._({
    required this.asset,
    required Material material,
    required MaterialInstance materialInstance,
    required Texture texture,
    required TextureSampler sampler,
  })  : _material = material,
        _materialInstance = materialInstance,
        _texture = texture,
        _sampler = sampler;

  /// 场景里的那个 renderable。调用方负责 `viewer.addToScene`(如果
  /// `createGeometry` 没有自动加)。
  final ThermionAsset asset;

  final Material _material;
  final MaterialInstance _materialInstance;
  final Texture _texture;
  final TextureSampler _sampler;

  bool _destroyed = false;

  // ── 上游 FullScreenTriangle.cpp:38-46 的三个顶点 ─────────────────────────
  //
  //   { { -1, -1, 1, 1 }, { 0,  1 } }
  //   { {  3, -1, 1, 1 }, { 2,  1 } }
  //   { { -1,  3, 1, 1 }, { 0, -1 } }
  //
  // 为什么是"一个超出屏幕的大三角形"而不是两个三角形拼的四边形:没有对角线
  // 接缝、少一次顶点着色、光栅化更连贯。这是标准做法,不是我们想出来的。
  static final Float32List _vertices = Float32List.fromList(<double>[
    -1, -1, 1, //
    3, -1, 1, //
    -1, 3, 1, //
  ]);

  static final Float32List _uvs = Float32List.fromList(<double>[
    0, 1, //
    2, 1, //
    0, -1, //
  ]);

  static final Uint16List _indices = Uint16List.fromList(<int>[0, 1, 2]);

  /// 建出三角形。
  ///
  /// [materialBytes] 是 `assets/materials/pw_camera_feed.filamat` 的内容
  /// (用 `tool/build_materials.sh` 编)。
  ///
  /// [imageWidth]/[imageHeight] 只用来填纹理的记账字段 —— 对 external 纹理
  /// **它们是惰性的**:Filament 从不拿它们做分配,真正的尺寸和格式由
  /// CVPixelBuffer 自己决定(`MetalHandles.mm:700-707` 只把它们塞进
  /// HwTexture 基类;`details/Texture.cpp:265-268` 说得更直白 ——
  /// external 纹理在 build 时根本不分配)。上游干脆一个都不传
  /// (`FullScreenTriangle.cpp:64-67` 只有 `.levels(1).sampler(...)`),
  /// 而 thermion 的 Dart 入口要求必填,所以我们填真值。
  static Future<CameraFeedTriangle> create(
    ThermionViewer viewer, {
    required Uint8List materialBytes,
    required int imageWidth,
    required int imageHeight,
  }) async {
    final FilamentApp app = FilamentApp.instance!;

    final Material material = await app.createMaterial(materialBytes);
    final MaterialInstance mi = await material.createInstance();

    final Texture texture = await app.createTexture(
      imageWidth,
      imageHeight,
      levels: 1,
      // 🔴 这一个参数是整条路能不能走通的开关。
      // Texture.h:234 原话:"If the Sampler is set to SAMPLER_EXTERNAL,
      // external() is implied." —— 也就是说选了它,`mExternal` 才为真,
      // setExternalImage 的硬前置条件才满足。
      textureSamplerType: TextureSamplerType.SAMPLER_EXTERNAL,
      // 惰性字段,见上。填 RGBA8 是因为我们喂的是 32BGRA,不是默认的
      // RGBA16F —— 虽然引擎不看,但别在代码里留一个自相矛盾的声明。
      textureFormat: TextureFormat.RGBA8,
    );

    // 上游用默认构造的 `TextureSampler()`(FullScreenTriangle.cpp:99),
    // Filament 的默认是 NEAREST/CLAMP_TO_EDGE。thermion 的默认是 LINEAR,
    // 所以显式写回 NEAREST 保持与对照件一致。
    // (相机帧会被放大到屏幕,LINEAR 观感更好 —— 但那是一个独立的、要单独
    //  立据的改动,不能在复刻里顺手改。)
    final TextureSampler sampler = await app.createTextureSampler(
      minFilter: TextureMinFilter.NEAREST,
      magFilter: TextureMagFilter.NEAREST,
      wrapS: TextureWrapMode.CLAMP_TO_EDGE,
      wrapT: TextureWrapMode.CLAMP_TO_EDGE,
      wrapR: TextureWrapMode.CLAMP_TO_EDGE,
    );

    await mi.setParameterTexture('cameraFeed', texture, sampler);

    final ThermionAsset asset = await viewer.createGeometry(
      Geometry(_vertices, _indices, uvs: _uvs),
      materialInstances: <MaterialInstance>[mi],
    );

    // 🔴 关视锥剔除。见文件头第 2 点:顶点是 NDC,算出来的 AABB 是坐落在
    // 世界原点的一个约 4 单位的盒子;相机一走开就出视锥,背景**静默消失**。
    await asset.setCulling(false);
    // 上游同时关掉了投影与接收阴影(FullScreenTriangle.cpp:99-100)。
    await asset.setCastShadows(false);
    await asset.setReceiveShadows(false);

    return CameraFeedTriangle._(
      asset: asset,
      material: material,
      materialInstance: mi,
      texture: texture,
      sampler: sampler,
    );
  }

  /// 喂一帧。[pixelBufferAddress] 是 `CVPixelBufferRef` 的地址。
  ///
  /// 🔴 **调用方仍然持有自己那一份 +1,必须在本 future 完成后还掉。**
  /// Filament 在这次调用里自己 `CVPixelBufferRetain` 了一份
  /// (`MetalDriver.mm:1254-1262`,注释原文 "allowing the application to free
  /// their reference to the buffer"),它**不接管**你的那一份。
  /// [PwCameraSlot.withFrame] 的 try/finally 把这件事做成机械保证 ——
  /// 走那条路,不要自己手写 acquire/release。
  Future<void> setFrame(int pixelBufferAddress) async {
    if (_destroyed) return;
    await _texture.setExternalImage(pixelBufferAddress);
  }

  /// 设 UV 变换。对照 `FullScreenTriangle.cpp:112-114`
  /// `setCameraFeedTransform(mat3f)`。
  Future<void> setTransform(UvTransform transform) async {
    if (_destroyed) return;
    // UvTransform 内部是行主序;Matrix3 / GLSL mat3 是列主序。
    final List<double> cm = transform.toColumnMajor();
    await _materialInstance.setParameterMat3(
      'textureTransform',
      Matrix3.fromList(cm),
    );
  }

  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    // 顺序与上游析构一致(FullScreenTriangle.cpp:51-57):先纹理,最后实体。
    // 采样器上游没有单独持有(它用的是临时的 `TextureSampler()`),thermion
    // 把它做成了有句柄的对象,所以要显式还。
    await _texture.dispose();
    await _sampler.dispose();
    await _materialInstance.destroy();
    await _material.destroy();
    await FilamentApp.instance!.destroyAsset(asset);
  }
}
