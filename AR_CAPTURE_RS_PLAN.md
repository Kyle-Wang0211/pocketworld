# 新 AR 拍摄 UI(完全复刻 RealityScan)— 实现计划

分支:`ar-capture-rs`(从 `capture-ar-coverage` @ `11df911` 派生)。dome 球型 capture UI **原样保留**在 `capture-ar-coverage`,本分支不改 `lib/ui/capture/capture_page.dart`。

## Context
用户决定:保留 PocketWorld 现有 dome 球型 capture UI,从它派生出一个**全新的 AR 拍摄 UI,尽力完全复刻 RealityScan**。原则:AR 硬件用苹果原生(ARKit),但渲染/逻辑/UI 尽量用 Dart(为后续跨端 iOS/Android/鸿蒙)。这与现状契合——点云与照片卡本就在 Dart 侧投影渲染,只有 ARSCNView 相机 + pose 是原生。

## 架构定位(从代码核实)
- AR 相机:原生 `ARSCNView`(`ios/Runner/AetherARKitPlugin.swift`,`AetherARKitPreviewView`),以 `UiKitView(viewType:'aether_arkit_preview')` 嵌入 Flutter(`capture_page.dart:1102`)。
- 照片卡 + 点云:**Flutter 侧 2D 投影 overlay**(不是原生 SCNNode)。投影 `_projectCameraSampleToScreen`(`capture_page.dart:1374`),照片卡 `_PhotoPositionCard`(`:1398`,现为白框 `:1425`)。
- 拍摄存储:`CaptureSession`(`lib/capture/capture_session.dart`)+ `DomeTargetPoints`(`lib/capture/dome/dome_target_points.dart`)。每张高清照片走 `poseProvider.captureHighResolutionStill(...)`(`capture_session.dart:1159`)+ `targetPoints.stampJpegPath(cellIdx,slotIdx,jpegPath)`(`:1205`);路径 `cell_<c>_slot_<s>.jpg` + 同名 `.json` sidecar。

## 锁定决策(Option B 的务实解读)
砍掉 dome 的 **UI / aim-lock 显式步骤 / 自动连拍触发**,**保留存储层**(不动下游 curation/manifest/pipeline 契约,稳为先)。
1. 新页 `ARCapturePage` / `_ARCapturePageState`(由 dome 页复制改造),dome 页不动。
2. **拍摄模型**:开页后静默 auto-lock(复用 `start(autoLock:true)` → `_lockOriginWhenReady`,拿世界锚 + scale,**无十字准星 aim UI**);中间快门 **每点一次 = `session.captureSinglePhoto()` 拍一张**。
3. **照片卡**:默认黑框;`CapturePreviewCameraSample` 加 `bool sfmConfirmed`(默认 false → 黑;true → 白)。SfM 不接,恒 false,只留判定。
4. **左下角**:最新照片缩略图 + 实时计数(读 `targetPoints.retainedJpegPaths.length`),**无 300 上限**。
5. **相册**:新建全屏 `ARAlbumPage`(`Navigator.push(MaterialPageRoute)`),按拍摄时间排序(非 path 排序),点开放大(`InteractiveViewer`),删除(复用 `_deleteRetainedPhoto` 逻辑)+ 返回键。
6. ARKit 原生层不动。

## 接口契约(供并行实现对齐)
- `Future<String?> CaptureSession.captureSinglePhoto()` —— 用当前 pose 造 `CapturedFrameSample`,force-admit 到最近 dome cell(复用 `ingest` 路由或新增 `forceAdmit`),调 `captureHighResolutionStill` + `stampJpegPath`,返回 jpegPath 或 null;并把样本 + 时间戳记入,使照片卡 + 计数 + 相册可读。
- `ARAlbumPage({required DomeTargetPoints targetPoints, required Future<void> Function(String path) onDelete})` —— 全屏页,监听 `targetPoints`(ChangeNotifier)刷新。
- 照片卡读 `targetPoints.retainedJpegPaths`(已存在,`dome_target_points.dart:340`);按时间序需 sidecar/sample 的 timestamp。

## 文件改动
| 文件 | 改动 |
|---|---|
| `lib/ui/capture/ar_capture_page.dart`(新,复制 dome 页) | 改类名;删 aim/lock UI 与自动连拍依赖;静默 auto-lock;中间按钮→`captureSinglePhoto`;照片卡黑/白框;左下角缩略图+计数;打开 `ARAlbumPage` |
| `lib/ui/capture/ar_album_page.dart`(新) | 全屏时间序相册:网格 + 放大 + 删除 + 返回 |
| `lib/capture/capture_session.dart` | 新增 `captureSinglePhoto()` |
| `lib/capture/realtime_capture_preview.dart` | `CapturePreviewCameraSample` 加 `sfmConfirmed`(默认 false) |
| `lib/ui/app_shell.dart` | 入口指向 `ARCapturePage`(或并存一个入口) |
| `lib/ui/capture/capture_page.dart`(dome) | **不改** |

## 验证
- `flutter analyze`(必须 0 error;迭代修到绿)。
- 真机:开页→点中间按钮→AR 中出现黑框照片卡 + 左下角缩略图计数+1→多拍几张→进相册看时间序、放大、删除一张→计数同步回退。
- 回归:`capture-ar-coverage` 分支 dome 页不受影响。
