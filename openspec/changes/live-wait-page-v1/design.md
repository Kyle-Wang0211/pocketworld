# design — live-wait-page-v1

## 1. 页面:等待页就是 viewer
等待层 `SfmPreviewOverlay` 本来就画 `SparseCloudView`(与个人页点云页同一套)。改动:
- 点"完成"那一个 setState(be8a480 的"先盖页再拆"之前)同时把**最后一版流式云**(ARKit 世界系)做成全白快照上屏
  (`_sfmLiveSnapshot`,`_whiteSnapshot`),并把那一刻的 ARKit 相机做成 viewer 起始态(`_sfmPerspectiveStart`)。
- worker:`finish_pending` 后不再压住逐帧 `previewTracked()`(只压 interim 全局 BA);phase-1 落地后再发一版
  `finalize_local_live`。页面在 generating 期把这些源路由成白云(`_onSfmEvent` 早退分支),不取色、不落盘。
- refined 到 → 取色 → 落盘 → `_sfmSnapshot` 接管(相机不动)。
- 顶部 chip 整个删除;底部胶囊 `waitLabel`(null ⇒ "计算中…")。

## 2. 相机:拍摄位姿 → 轨道相机(全部有出处,见 capture_pose_camera.dart 文件头)
1. 相机轴向:Apple `ARCamera.transform` 文档(x 沿长边指向 Home 键,y 在 landscapeLeft 下朝上,z 指向屏幕外)。
2. 竖屏换轴:U3DC/Unity-ARKit-Plugin(MIT)`ARSessionNative.mm` L543-548/569 的 R 矩阵 ⇒ 屏幕右 = 相机 +y,屏幕下 = 相机 +x。
3. 传感器针孔:COLMAP `pinhole.h` L46-54(BSD-3);内参定义 = Apple `ARCamera.intrinsics`。
4. aspect-fill:Apple `ARFrame.displayTransform`("rotation and aspect-fill")+ `resizeAspectFill` 对称裁切 ⇒ s = max(vpW/H, vpH/W),居中。
5. 轨道相机:pivot = C + forward·r(Potree `View.getPivot`);r = 屏幕中心下那个点的距离(Cesium `Camera.calculateOrthographicFrustumWidth`
   在透视→正交切换时用的就是它);角度由 rig 自己的视矩阵 `decomposeViewMatrix` 反解。
6. 透视→正交:rig 起始 `orthoMix = 0`(除数 = depth,眼睛在 C),第一次手势 / 进编辑时 280 ms 过渡到 1(除数 = camDist);
   pivot 平面上尺寸全程不变(Cesium SceneTransitioner 的不变量)。`reframe` 回到历史 rig(无 override、正交)。
   两个端点与历史投影**逐位一致**(test/capture_pose_camera_test.dart)。

调研结论(记录):没有任何开源项目数值重推 `displayTransform(for: .portrait)` 的六个系数,全部直接调 API;
我们不调 Swift,因此用上面 1-4 的文档 + MIT 源码推到像素;真机第一场拍摄 = 最终阳性对照(旋转/镜像错误一眼可见)。

## 3. 倒计时(lib/eta,全部复刻,文件头列出处)
- 预测:Ninja ≥1.12 `status_printer.cc` `RecalculateProgressPrediction`(Apache-2.0)逐行移植:单元 = 帧,先验 = 本机上一次
  同阶段每单元耗时(Ninja 的 .ninja_log 角色 = `official_eta_prior_log.json`),15 s / 5 % / 10× 三道门原样。
- 阶段:sparse.drain(排空帧)/ phase1 / refine / colorize / persist,单元数 = 帧数(Parallax α·(N−K) 模型)。
- 显示:Ninja 的 "?" ⇒ "计算中…";第一次有预测即提交,标签 = "不到一分钟"(<60 s)或"约 N 分钟"(向上取整,Kontur
  progress-bar 规范"round remaining time up"),此后**永不改变**(用户签决)。
- 尺子:Komatsu et al. CHI 2024(晚 ≤10% 感知不到)⇒ 晚 >10% 不合格;早于标签下界不合格(用户:早了也不合格)。
  每场落 `eta_ruler` 遥测 + 设备日志,按热态可统计通过率。
- 不用的:indicatif 双重 EMA(提交一次后无需平滑)、Firefox 阻尼(同理)、本机中位数分热态(用户否决)。

## 4. 不变量 / 防耦合
- 个人页点云页、社区自转卡、选区编辑:`orthoMix` 默认 1、`camDistOverride` 默认 null ⇒ 投影逐位不变(测试锁)。
- 拍摄路径(快门/喂帧)零改动;`finish_hides_camera_immediately_test` 仍绿。
- 覆盖层 refined/error 态按钮不变(`sfm_preview_overlay_buttons_test` 仍绿)。
