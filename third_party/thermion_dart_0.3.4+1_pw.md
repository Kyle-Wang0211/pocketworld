# 本地补丁清单(thermion_dart 0.3.4+1)

这个目录是 pub 上 `thermion_dart 0.3.4+1` 的**可编辑副本**,由 pocketworld
的 `pubspec.yaml` 用 `dependency_overrides` 指过来。下面是相对 pub 原版的**全部**
改动。**上线前必须走完这张表。**

对照基准:上游 `nmfisher/thermion` HEAD = `99dd8cf`,`thermion_dart 0.6.0-pre.0`,
钉 Filament **v1.76.0**(我们这份钉的是 **v1.58.0**)。

---

## A. 回填(backport)—— 这些在上游**已经有了**,升级即自动消失

三处都是从上游 HEAD **逐字抄回来**的,不是我们的设计。已用 diff 验过逐字一致。
升级到 0.6.0-pre.0 时**整段删掉**即可,不需要合并。

| # | 改动 | 上游位置 | 本地位置 |
|---|------|---------|---------|
| A1 | `MaterialInstance_setParameterMat3` + `convert_double_to_mat3f` | `TMaterialInstance.h:109` / `.cpp:202` / `MathUtils.hpp:22` | 同名同位 |
| A2 | `RenderableManager_setCulling` | `TRenderableManager.h:50`(`// Culling` 段)/ `.cpp:284` | 同名同位 |
| A3 | `Camera_setProjection` 的 `switch` 补 `break` | `TCamera.cpp:183-190` | 同 |

**A3 是个真 bug**:原来两个 `case` 之间没有 `break`,`Orthographic` 直接落到
`Perspective`,所以**正交投影永远拿到透视**。上游已修。我们这条路传的就是
`Perspective`,不受影响。

### 🔴 A2 升级时**不是**整段删掉就完事

上游后来把 culling 挪到了一个 **`RenderableManager` Dart 类**上:

- 上游:`RenderableManager.setCulling(ThermionEntity entity, bool enabled)`
  (`interface/renderable_manager.dart:168`)
- 我们(0.3.4 没有那个类):`ThermionAsset.setCulling(bool enabled)`
  —— 照 0.3.4 自己的 `setCastShadows` / `setReceiveShadows` 的位置放的

⇒ 升级时生产侧的调用点要改:
`asset.setCulling(false)` → `renderableManager.setCulling(entity, false)`。
调用点只有一处:`pocketworld/lib/vio/render/camera_feed_triangle.dart`。

---

## B. 真·新增 —— 上游**没有**,需要提 PR

### B1 `Texture_setExternalImagePlatform`(+ RenderThread 变体 + Dart 侧实现)

把平台图像(iOS/macOS 的 `CVPixelBufferRef`)绑成纹理内容。走的是 Filament
**已弃用**的 `Texture::setExternalImage(Engine&, void*)` 重载。

**为什么上游现有的那个不能用**(两条都核对过源码,不是推测):

1. 上游的 `Texture_setExternalImage`(`TTexture.cpp:544-551`)把 `void*`
   `static_cast` 成 `Platform::ExternalImage*`,走 handle 路径。而在上游**自己
   钉的 Filament v1.76.0** 上,Metal 后端的 handle 路径是空函数:
   - `MetalDriver::createTextureExternalImage2R` → `// FIXME: implement`(:667-673)
   - `MetalDriver::setupExternalImage2` → `// FIXME: implement`(:1719-1721)

   同版本的 **void\* 路径是实现了的**(`createTextureExternalImageR`:675-686,
   真的建 `MetalTexture` 并配对 `CVPixelBufferRetain`/`Release`)。

2. 上游 Dart 侧 `FFITexture.setExternalImage` 至今是
   `throw UnimplementedError()`(`ffi_texture.dart:76-79`)。

⇒ 在 Metal 上,**任何 Filament 版本下** deprecated 的 void\* 重载都是唯一能用的。

**所有权契约(反直觉,写错会每帧漏一个全分辨率缓冲)**:Filament **自己 retain
一份,不接管你的**。`setupExternalImage` 在调用线程上同步 `CVPixelBufferRetain`
(`MetalDriver.mm:1723-1731`),注释原文 *"allowing the application to free their
reference to the buffer"*。持有 +1 的调用方必须在调用返回后还掉,而且可以立刻还。

🔴 Filament 官方 AR 样例 `FullScreenTriangle.cpp:104-107` 写的是「不需要 retain,
Filament 会接管」——那**只对那个样例成立**(它的 buffer 是 `ARFrame.capturedImage`,
本来就没持有)。当成通则读就是反的。

---

## C. 走查过但**不改**的

- `ffigen/web.yaml` 要用 **`ffigen_js`** 跑,不是 `ffigen`(上游 `Makefile:36`)。
  用错的那个会把 `thermion_dart_js_interop.g.dart` 整个覆盖成 dart:ffi 版本,
  **web 直接废掉**。我们这份 0.3.4 的 pubspec 里没有 `ffigen_js` 依赖
  (上游 HEAD 有:`ffigen_js: ^0.0.15-pre`),所以**这份副本的 web 绑定无法重新
  生成** —— B1 的 web 绑定是按文件既有风格(零注释)手工补的,位置与头文件同序。
- `native.yaml` 那半可以重生:`dart run ffigen --config ffigen/native.yaml`,
  实测只动我们新增的那几个函数,其余 4300 行零漂移。
- 上游 `test/helpers.dart:40-46` 要求**工作目录名必须叫 `thermion_dart`**,
  否则 `findPackageRoot` 抛 `StateError`。本目录叫 `thermion_dart_pw` ⇒
  **上游测试台架在这份副本里跑不起来**(未改动的 `texture_tests.dart` 也一样失败)。

---

## 升级到 0.6.0-pre.0 的已知代价(尚未评估完)

- Filament **v1.58.0 → v1.76.0**:我们编的 `pw_camera_feed.filamat` 是
  **material version 58**,引擎版本不匹配 `Material::Builder` 会直接拒。
  ⇒ 必须用 **v1.76.0 的 matc** 重编(要重新下官方 mac 发行包)。
- `thermion_flutter` 也要一起动;生产在用 0.3.4 的 `ViewerWidget`。
- 0.5.0 起有破坏性 API 变更,生产侧 `viewer_impl` / `live_model_view` /
  `cube_scene` 都要复验。
