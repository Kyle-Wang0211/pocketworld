# 自适应对焦 VIO 调研:镜头持续自动对焦下内参时变的处理路线(2026-09-22)

分支 `research/adaptive-focus-vio-survey`(基于 `origin/feat/ios-zero-arkit-integration`@`78bdc7c`)。
调研 agent 产出;**不含任何实测、不含生产代码**。所有「未核」均为本次没拿到一手证据的项,不补猜。

---

## 0. 判决(一句话)

**走「平台逐帧供 K、引擎逐帧消费」(路线 ①):iOS 用 AVFoundation 每个采样缓冲自带的 3×3 内参矩阵,
沿 XRSLAM 上游已预留、但从未被消费的 `XRSLAMImageExtension` 送进引擎,把 `detail.cpp:105` 的
`frame->K = config->camera_intrinsic()` 改成读当帧 K;XRSLAM 核心本来就是逐帧存 K 的结构,只差源头这 4 处 + Swift 侧 1 处。
Android 优先 API 35 的 `STATISTICS_LENS_INTRINSICS_SAMPLES`,没有就退化为「锁焦 + 拍照瞬间解锁再锁回」(ARCore 官方建议的用法);
HarmonyOS / Web 没有逐帧 K,只能退化到同一策略。**

不选在线内参自标定(路线 ②):**逐仓核过 15 个候选 + Kalibr,凡是实现了在线相机内参估计的
(OpenVINS、XIVO、DM-VIO/DSO)许可全部不可商用;凡是可商用的(Basalt、OKVIS2、ROVIO、Kimera、maplab、ICE-BA、Stella)全部没有实现。**
而且这些实现把内参当**常量**估(无过程噪声),本来就不匹配连续自动对焦;真正把焦距当时变量建模的只有 Nobre 2017,无可商用代码。

次选对焦呼吸 1-D 模型(路线 ③)只作为 Android/HarmonyOS 无逐帧 K 机型的后备,理由见 §6。

---

## 1. 问题定义

- 现状:零 ARKit 臂把镜头锁在 `lensPosition = 0.835`(抄上游 `xrslam-ios/visualizer/src/ViewController.swift:256 camera.setFocus(0.835)` →
  `Camera.swift:75-79 setFocusModeLocked(lensPosition:)`)。pocketworld 侧同位:`ios/Runner/PwCameraSlot.swift:237-239`。
- 原因:出货引擎的内参只在 `XRSLAMCreate` 时从 device yaml 吃一次(`xrslam-interface/src/XRSLAMInternal.cpp:5-17` →
  `YamlConfig` → `xrslam-extra/src/xrslam/extra/yaml_config.cpp:155-161`),C ABI 没有更新内参入口;自动对焦下 fx 游走(台架实测 120 s 漂 10.9%,自测)。
- 代价:成片与 VIO 共用同一颗镜头同一个锁位,拍 20–30 cm 小物体成片偏软;用户主打小物体。
- 目标:「自适应对焦」= **镜头持续自动对焦、内参逐帧变化时 VIO 仍正确**。两半:(a) 平台侧各端能否逐帧给 K / 对焦距离;(b) 算法侧怎么吃时变内参。

---

## 2. 证据表:候选仓 × 许可 × 有没有在线内参 × 单目 × 维护

许可列为 **LICENSE 文件本体**的识别行(不是 README 一句话);⚰️ = 不可抄。「在线内参」指运行中估计/更新**相机**内参(不含 IMU 内参、不含外参/td)。
「最近推送」取自 GitHub API `pushed_at`(2026-09-22 查询)。

| # | 仓 / 链接 | LICENSE 文件识别行 | SPDX | 在线相机内参 | 证据(文件:行) | 单目 | 最近推送 | 判 |
|---|---|---|---|---|---|---|---|---|
| 1 | [OpenVINS](https://github.com/rpng/open_vins) | `LICENSE`:GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007;README:182 亦声明 GPL-3 | GPL-3.0 | **有**(常量估) | `ov_msckf/src/state/StateOptions.h` `do_calib_camera_intrinsics = false`;`ov_msckf/src/state/State.h:162 _cam_intrinsics`、`:165 _cam_intrinsics_cameras`;`ov_msckf/src/update/UpdaterHelper.cpp:218`(if do_calib_camera_intrinsics)、`:367 compute_distort_jacobian(uv_norm, dz_dzn, dz_dzeta)`、`:416-417`(H_x 填 dz_dzeta);`ov_core/src/cam/CamBase.h:158`;`Propagator.cpp` 只给 IMU 内参过程噪声,相机内参**无过程噪声=常量** | 是 | 2025-11-30 | ⚰️ GPL |
| 2 | [XIVO](https://github.com/ucla-vision/xivo) | `LICENSE`:Academic Software License / XIVO / No Commercial Use;README:59 商用需联系 UCLA TDG | 无 SPDX(非商用) | **有** | `common/camera_autocalib.h`(头注:可调内参相机模型,用于在线标定);`common/camera_base.h`(jacc = 像点对内参的雅可比,"for online calibration");`src/feature.cpp` `#ifdef USE_ONLINE_CAMERA_CALIB` | 是 | 2023-02-24 | ⚰️ 非商用 |
| 3 | [Basalt](https://gitlab.com/VladyslavUsenko/basalt) | `LICENSE`:BSD 3-Clause License, Copyright (c) 2019, Vladyslav Usenko and Nikolaus Demmel | BSD-3-Clause | 无 | `include/basalt/vi_estimator/sqrt_keypoint_vio.h:93` 构造函数吃 `const basalt::Calibration<double>& calib`(固定);`:215 using BundleAdjustmentBase<Scalar>::calib`;标定是离线工具 `src/calibrate.cpp`/`calibrate_imu.cpp` | 以双目为主(单目未核) | 镜像 2026-03-22 | 可商用但无 |
| 4 | [OKVIS2](https://github.com/smartroboticslab/okvis2) | `LICENSE`:OKVIS ... Copyright (c) 2015 ASL/ETH, 2020 SRL/Imperial, 2024 SRL/TUM,BSD 三条款 | BSD-3-Clause | 无(弱阴性) | `okvis_ceres/include/okvis/ViGraph.hpp`、`Estimator.hpp`、`ceres/ReprojectionError.hpp` grep `intrinsic` 0 命中;GitHub 代码搜索 0 命中(索引可能未覆盖,故标弱阴性) | 是(09-22 已做过单目回放) | 2026-08-07 | 可商用但无 |
| 5 | [ROVIO](https://github.com/ethz-asl/rovio) | `LICENSE`:Copyright (c) 2014, Autonomous Systems Lab,BSD 三条款 | BSD-3-Clause | 无(只有在线外参) | `include/rovio/RovioFilter.hpp:90 Common.doVECalibration`(外参);`:94 CameraN.CalibrationFile`(内参来自文件);`cfg/rovio.info` 同 | 是 | 2026-09-03 | 可商用但无 |
| 6 | [Kimera-VIO](https://github.com/MIT-SPARK/Kimera-VIO) | `LICENSE.BSD`:Copyright 2019 Massachusetts Institute of Technology,BSD 二条款 | BSD-2-Clause | 无 | `include/kimera-vio/frontend/Camera.h` `gtsam::Cal3_S2 getCalibration()` 返回构造时固定的 `calibration_`(`src/frontend/Camera.cpp` 由 `CameraParams.intrinsics_` 构造) | 双目优先(单目未核) | 2026-08-06 | 可商用但无 |
| 7 | [maplab](https://github.com/ethz-asl/maplab) | `LICENSE`:Apache License Version 2.0, January 2004 | Apache-2.0 | 无(VIO 前端=ROVIOLI=ROVIO) | `aslam_cv2/aslam_cv_cameras/src/camera-pinhole.cc` 只在「被请求时」算对内参的雅可比(离线标定工具用);VIO 状态不含内参 | 是 | 2024-05-31 | 可商用但无 |
| 8 | [HybVIO](https://github.com/SpectacularAI/HybVIO) | `LICENSE`:GNU GENERAL PUBLIC LICENSE Version 3;README:115 GPLv3、商用另议 | GPL-3.0 | 无 | 代码搜索 20 命中全为读 `parameters.txt` 标定,无估计代码 | 是 | 2022-05-05 | ⚰️ GPL |
| 9 | [ICE-BA](https://github.com/baidu/ICE-BA) | `LICENSE`:Copyright 2017-2018 Baidu Robotic Vision Authors,Apache 2.0 | Apache-2.0 | 无 | `Backend/IBA/IBA_internal.h` `Camera::Calibration m_K`(固定);`Frontend/cameras/*` 的 `intrinsicsJacobian` 参数是从 OKVIS 相机模型继承的接口,后端不估 | 是 | 2018-09-12(停更) | 可商用但无 |
| 10 | [Stella VSLAM](https://github.com/stella-cv/stella_vslam) | `LICENSE` 指向两文件:`LICENSE.original` BSD 2-Clause (c) 2019 AIST;`LICENSE.fork` BSD 2-Clause (c) 2022 stella-cv | BSD-2-Clause | 无(且**非 VIO**,无 IMU) | 代码搜索 6 命中皆为配置读取 | 纯视觉 | 2026-08-26 | 可商用但无、非 VIO |
| 11 | [ORB-SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3) | `LICENSE`:GNU GENERAL PUBLIC LICENSE Version 3 | GPL-3.0 | 无 | 36 命中只在 `Examples/Calibration/recorder_*.cc` | 单目-惯性 是 | 2024-07-24 | ⚰️ GPL |
| 12 | [VINS-Fusion](https://github.com/HKUST-Aerial-Robotics/VINS-Fusion) | `LICENSE`:GNU GENERAL PUBLIC LICENSE Version 3;README:172 GPLv3 | GPL-3.0 | 无(只有在线外参 + td) | README:10-11;内参走 camodocal 离线(`camera_models/`);`vins_estimator/src/estimator/estimator.cpp` `featureTracker.readIntrinsicParameter(CAM_NAMES)` | 是 | 2024-05-23 | ⚰️ GPL |
| 13 | [DM-VIO](https://github.com/lukasvst/dm-vio) | `LICENSE`(GPL-3.0 徽章);README:"Like DSO, DM-VIO is licensed under ... GPLv3" | GPL-3.0 | **有**(继承 DSO,4 个针孔参数进滑窗光度 BA) | `src/dso/IOWrapper/Output3DWrapper.h:117`(CalibHessian fxl()/fyl()/cxl()/cyl() = 优化后的最新针孔内参);`src/dso/FullSystem/HessianBlocks.h:309-319 struct CalibHessian{value_scaled, step}`;`src/dso/util/settings.h:83 setting_initialCalibHessian` | 是 | 2024-10-27 | ⚰️ GPL |
| 14 | [SVO-Pro](https://github.com/uzh-rpg/rpg_svo_pro_open) | `LICENSE`(GPL-3.0);README:"licensed under GPLv3. For commercial use, please contact ..." | GPL-3.0 | 无 | 40 命中皆为标定 yaml / 回环里的固定 `K_` | 是 | 2024-01-19 | ⚰️ GPL |
| 15 | [MSCKF-VIO (Penn)](https://github.com/KumarRobotics/msckf_vio) | `LICENSE.txt`:COPYRIGHT AND PERMISSION NOTICE / Penn Software MSCKF_VIO ... "for non-profit research purposes only" | 无 SPDX(非营利) | 无 | README「Calibration」节:离线标定,内参固定 | 仅双目 | 2023-11-22 | ⚰️ 非营利 |
| — | [Kalibr](https://github.com/ethz-asl/kalibr) | `LICENSE`:(c) 2014 Furgale/Maye/Rehder ASL ETH;(c) 2014 Schneider Skybotix;含广告条款 | BSD-4-Clause | 离线工具;**无对焦相关内参模型**(代码未逐行核,OpenVINS 文档 `docs/gs-calibration.dox` 亦把它当离线工具引用) | — | — | 可商用(带广告条款义务) |

算法出处(DOI 已解析):
- Li, Yu, Zheng, Mourikis, *High-fidelity sensor modeling and self-calibration in vision-aided inertial navigation*, ICRA 2014, DOI [10.1109/ICRA.2014.6906889](https://doi.org/10.1109/ICRA.2014.6906889)(MSCKF 在线相机内参 / 卷帘 / td 联合估计的经典)。
- Eckenhoff, Geneva, Bloecker, Huang, *Multi-Camera Visual-Inertial Navigation with Online Intrinsic and Extrinsic Calibration*, ICRA 2019, DOI [10.1109/ICRA.2019.8793886](https://doi.org/10.1109/ICRA.2019.8793886)(OpenVINS 的实现依据)。
- Yang, Geneva, Zuo, Huang, *Online Self-Calibration for Visual-Inertial Navigation: Models, Analysis, and Degeneracy*, IEEE T-RO 2023, DOI [10.1109/TRO.2023.3275878](https://doi.org/10.1109/TRO.2023.3275878)(含**退化运动分析**:平面/单轴等运动下内参不可观)。
- Keivan, Sibley, *Online SLAM with any-time self-calibration and automatic change detection*, ICRA 2015, DOI [10.1109/ICRA.2015.7140008](https://doi.org/10.1109/ICRA.2015.7140008)。
- Nobre, Kasper, Heckman, *Drift-correcting self-calibration for visual-inertial SLAM*, ICRA 2017, DOI [10.1109/ICRA.2017.7989771](https://doi.org/10.1109/ICRA.2017.7989771)——**唯一把焦距等标定量建模为连续时变**并做变化检测的 VIO 论文;代码许可未核。

结论:「**没有一家可商用开源 VIO 实现在线相机内参自标定**」成立,证据在上表逐仓给出。

---

## 3. XRSLAM 自身:内参在哪被消费、逐帧 K 要动多少处

仓:`~/Developer/xrslam`,分支 `build/gpufe-nothread-20260922`(实际检出在工作树 `~/Developer/xrslam-4beb1a9-thr`,HEAD `8a1cc12`)。仓许可 `LICENSE`:Copyright 2022 XRSLAM Authors,Apache License 2.0。

### 3.1 内参的唯一源头与唯一注入点
| 位置 | 内容 |
|---|---|
| `xrslam/include/xrslam/xrslam.h:76` | `virtual matrix<3> camera_intrinsic() const = 0;`(Config 接口;`:77 camera_distortion()`、`:80 camera_distortion_flag()`) |
| `xrslam-extra/src/xrslam/extra/yaml_config.cpp:155-161, 380` | 从 yaml `cam0.intrinsics` 读 fu/fv/cu/cv 一次,存 `m_camera_intrinsic` |
| `xrslam-interface/src/XRSLAMInternal.cpp:5-17` | `XRSLAMCreate` 建 `YamlConfig` → `XRSLAMManager::Init` |
| **`xrslam/src/xrslam/core/detail.cpp:105`** | **`frame->K = config->camera_intrinsic();`** —— 每帧新建 `Frame` 时从 Config 拷一份;`:107-109` 由 K 推 `sqrt_inv_cov`(关键点噪声按 K 缩放) |

### 3.2 核心里所有读 K 的地方——**全部读的是 `frame->K`(逐帧成员,`xrslam/src/xrslam/map/frame.h:63 matrix<3> K;`)**
- `xrslam/src/xrslam/map/frame.cpp:58, 70, 79, 91, 103`(检测/跟踪时 `apply_k`/`remove_k`,跨帧用 `next_frame->K`——**相邻两帧 K 不同已被结构支持**)
- `xrslam/src/xrslam/core/initializer.cpp:251-252`
- `xrslam/src/xrslam/core/sliding_window_tracker.cpp:417-418, 604-605, 745-746, 755-756, 765(F = K_kf^-T E K_cur^-1,两帧各自 K), 776-783`
- `xrslam/src/xrslam/core/feature_tracker.cpp:160`(仅调试绘制)
- 几何工具:`xrslam/src/xrslam/geometry/stereo.h:8-12 apply_k/remove_k`

### 3.3 只读 Config 内参、不在热路径的地方
- `xrslam-interface/src/XRSLAMManager.cpp:324-328 GetInfoIntrinsics`(对外报 fx/fy/cx/cy,`XRSLAM.h:110 XRSLAM_INFO_INTRINSICS`、`:124-129 XRSLAMIntrinsics`)
- `xrslam/src/xrslam/config.cpp:87-88`(日志)、`xrslam/src/xrslam/localizer/localizer.cpp:12`(视觉定位,默认编译掉,`2016ee4`)、`xrslam-pc/player/src/IO/*.cpp`(台架读数据集)

### 3.4 契约里已预留但**零消费**的扩展字段
`xrslam-interface/include/XRSLAM.h:33-38`:
```
typedef struct XRSLAMImageExtension {
    double exposure_time;          /*!< image exposure time. */
    double default_focus_distance; /*!< default focus info. */
    double focal_length;           /*!< current focal length. */
    double focus_distance;         /*!< current focus distance. */
} XRSLAMImageExtension;
```
`XRSLAMImage.ext`(`:50`)指向它;`XRSLAMManager::PushImage`(`XRSLAMManager.cpp:128-170`)**完全不读 `image->ext`**,整仓 grep `ext->|focal_length|focus_distance` 仅头文件命中。上游为「当前焦距/对焦距离」留了口,没接。`xrslam::Image` 基类(`xrslam/include/xrslam/xrslam.h:155-167`)只有 `t`,没有 K。

### 3.5 在线标定:**无**
grep `self.?calib|online.?calib|estimate/refine/optimize.*intrinsic` 在 `xrslam/ xrslam-interface/ xrslam-extra/` 只命中 `sliding_window_tracker.cpp:66-68` 的注释(说明 rpe 阈值是按 640×480 iPhone 标定写死的)。

### 3.6 畸变
`xrslam/src/xrslam/config.cpp:7` 默认畸变为零;iOS 机型 yaml(如 `xrslam-ios/visualizer/configs/iPhone 14 Pro.yaml:41-43`)`camera_distortion_flag: 0`、`distortion: [0,0,0,0]`;核心无去畸变代码(去畸变只在台架 `xrslam-pc/player/src/IO/tum_dataset_reader.cpp:63-72`)。⇒ 逐帧 K 方案只动 K,畸变保持零,与 Apple 只给 3×3 矩阵(不给畸变)一致。

### 3.7 逐帧 K 要动的处数:**引擎 4 处 + 报告 1 处 + iOS 宿主 1 处**
1. `XRSLAM.h:33-38` —— `XRSLAMImageExtension` 加 `fx, fy, cx, cy`(或约定 `focal_length` 存像素焦距,但 cx/cy 也随对焦挪,Won & Jeon 已发表主点会漂,故加全 4 个)。C ABI 不加符号;结构体追加字段需版本位或 `has_intrinsics` 标志。
2. `xrslam/include/xrslam/xrslam.h:155-167` —— `class Image` 加 `matrix<3> K; bool has_K;`。
3. `XRSLAMManager.cpp:128-170` —— `PushImage` 把 `image->ext` 拷进 `opencv_image`。
4. `detail.cpp:105-109` —— `frame->K = image->has_K ? image->K : config->camera_intrinsic();` 并保持 `sqrt_inv_cov` 按当帧 K 重算。
5. `XRSLAMManager.cpp:324-328` —— `GetInfoIntrinsics` 改报最新帧 K(可选)。
6. pocketworld `ios/Runner/PwCameraSlot.swift:351-361` 已逐帧读 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` 存 fx/fy/cx/cy,`:365-367` 当场喂 `PwXrslamLive.shared.onCameraFrame` —— 只需把这 4 个数塞进 `ext` 一并传;`:237-239` 的锁焦改为不锁(`lensPosition < 0` 分支已预留,`:426`)。

不需要动:3.2 列出的所有读 K 处(已逐帧)。

---

## 4. 平台矩阵:自动对焦下逐帧能拿到什么

| 端 | 逐帧 K | 逐帧对焦距离/镜头位置 | 对焦状态 | 结论 |
|---|---|---|---|---|
| **iOS**(AVFoundation) | **有**:`AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled`(iOS 11+)打开后,`AVCaptureVideoDataOutput` 每个采样缓冲带 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` 3×3 附件;须在 `startRunning()` 前设,且 `isCameraIntrinsicMatrixDeliverySupported` 为真(iOS 11 时只有 VideoDataOutput 支持) | `AVCaptureDevice.lensPosition`(0…1,KVO;文档明说**不对应物理距离、机型间不一致、1.0 不是无穷远**) | `isAdjustingFocus`(KVO) | **走逐帧 K** |
| **Android**(camera2) | 静态 `CameraCharacteristics.LENS_INTRINSIC_CALIBRATION`(API 23,[fx,fy,cx,cy,s],可为 null);同键在 AOSP `metadata_definitions.xml` 里 `<dynamic><clone entry="android.lens.intrinsicCalibration" kind="static"/>` ⇒ 也出现在 `CaptureResult`,但语义是静态克隆,厂商是否随对焦更新**未核**;**API 35 新增 `CaptureResult.STATISTICS_LENS_INTRINSICS_SAMPLES`(`LensIntrinsicsSample[]`,帧内多样本、建议 ≥200 Hz,文档要求把对焦距离与焦距等因素都算进去)**,可选,用 `getAvailableCaptureResultKeys()` 查 | `CaptureResult.LENS_FOCUS_DISTANCE`(FULL 级;单位由 `LENS_INFO_FOCUS_DISTANCE_CALIBRATION` 决定:CALIBRATED/APPROXIMATE 为屈光度,UNCALIBRATED 无物理意义) | `CaptureResult.LENS_STATE` STATIONARY/MOVING(LIMITED 级) | API 35 且厂商实现 ⇒ 逐帧 K;否则退化 |
| **HarmonyOS**(OpenHarmony Camera Kit 文档,GitHub 镜像 `openharmony/docs` master) | **无逐帧**;API 24 静态 `CameraDevice.lensIntrinsicCalibration`(数组)、`lensDistortion`、`lensFocalLength`(mm)、`minimumFocusDistance`、`sensorPhysicalSize/PixelArraySize` | `ManualFocus.getFocusDistance()/setFocusDistance()`(API 24,归一化 0…1,语义同 iOS lensPosition);`Focus.getFocalLength()`(API 11,mm,非像素) | `on('focusStateChange')` → `FocusState` SCAN/FOCUSED/UNFOCUSED(API 11,仅自动对焦模式触发);`FocusMode` MANUAL/CONTINUOUS_AUTO/AUTO/LOCKED | 退化(锁焦 + 拍照瞬间解锁);华为 HarmonyOS NEXT 官网页面为 JS 渲染,本次未抓到,以 OpenHarmony 镜像为准 |
| **Web**(getUserMedia + W3C MediaStream Image Capture) | **无**任何内参/像素焦距 | 规范有 `focusMode`、`focusDistance`(MediaTrackSettings/Constraints/Capabilities),浏览器实现状态未核(MDN MediaTrackSettings 页 2025-10-15 版未列这两项) | 无 | 退化或不支持 VIO |

同构先例(官方文档):
- ARKit:`ARWorldTrackingConfiguration.isAutoFocusEnabled` —— iOS 11.3 起默认开启自动对焦;`ARCamera.intrinsics`(fx/fy 为像素焦距)挂在每个 `ARFrame` 上。
- ARCore:`Config.FocusMode` 默认 **FIXED**,文档建议为跟踪性能沿用默认;**拍照/录像时切 AUTO,用完切回**;`CameraIntrinsics` 是长生命周期对象,属性可在每次 `Session.update()` 更新。

文档链接:
- Apple:[isCameraIntrinsicMatrixDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)、[isCameraIntrinsicMatrixDeliverySupported](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliverysupported)、[kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix](https://developer.apple.com/documentation/coremedia/kcmsamplebufferattachmentkey_cameraintrinsicmatrix)、[lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)、[setFocusModeLocked](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:))、[isAdjustingFocus](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isadjustingfocus)、[ARCamera.intrinsics](https://developer.apple.com/documentation/arkit/arcamera/intrinsics)、[isAutoFocusEnabled](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/isautofocusenabled)(正文来自 developer.apple.com 的 `tutorials/data/documentation/*.json`)。
- Android:[CameraCharacteristics#LENS_INTRINSIC_CALIBRATION](https://developer.android.com/reference/android/hardware/camera2/CameraCharacteristics#LENS_INTRINSIC_CALIBRATION)、[CaptureResult#LENS_FOCUS_DISTANCE](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#LENS_FOCUS_DISTANCE)、[CaptureResult#LENS_STATE](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#LENS_STATE)、[CaptureResult#STATISTICS_LENS_INTRINSICS_SAMPLES](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#STATISTICS_LENS_INTRINSICS_SAMPLES)、[LensIntrinsicsSample](https://developer.android.com/reference/android/hardware/camera2/params/LensIntrinsicsSample)、[AOSP metadata_definitions.xml](https://android.googlesource.com/platform/system/media/+/refs/heads/main/camera/docs/metadata_definitions.xml)(`android.statistics.lensIntrinsicsSamples`,`hal_version="3.10"`)。
- ARCore:[Config.FocusMode](https://developers.google.com/ar/reference/java/com/google/ar/core/Config.FocusMode)、[CameraIntrinsics](https://developers.google.com/ar/reference/java/com/google/ar/core/CameraIntrinsics)。
- OpenHarmony:[arkts-apis-camera-i.md(CameraDevice)](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-camera-kit/arkts-apis-camera-i.md)、[ManualFocus](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-camera-kit/arkts-apis-camera-ManualFocus.md)、[Focus](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-camera-kit/arkts-apis-camera-Focus.md)、[PhotoSession on('focusStateChange')](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-camera-kit/arkts-apis-camera-PhotoSession.md)、[枚举 FocusMode/FocusState](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-camera-kit/arkts-apis-camera-e.md)。
- Web:[W3C MediaStream Image Capture(编辑草案)](https://w3c.github.io/mediacapture-image/)。

---

## 5. 发表数据(用户铁律:先查有没有人发表过)

### 5.1 对焦呼吸的模型(focal length vs focus distance)
- **薄透镜公式**(Won & Jeon, *Learning Depth from Focus in the Wild*, ACCV 2022, [arXiv 2207.09658](https://arxiv.org/abs/2207.09658),Pixel 3):像距 s = F·f/(F−f),相对视场 = s_min/s_n;并指出手机 VCM 靠弹簧,弹性随温度与使用变化 ⇒ 元数据里的对焦距离与真实有误差;**主点也会随对焦漂**(镜头与传感器不完全平行)。
- **线性模型(专利)**:Sony, US 11,151,746 B2(优先权 2017-08-31,授权 2021-10-19),[Google Patents](https://patents.google.com/patent/US11151746B2/en):相机内建模型把对焦距离线性映射到有效焦距(y1 = m1·x1 + b1),再线性映射到畸变参数;说明书示例相邻标定帧放大率 1.0004。**权利要求 1 覆盖「在相机内用对焦距离→内参的模型逐帧确定内参」** ⇒ 路线 ③ 在美国有专利风险(仅提示,非法律意见)。
- Herrmann et al., *Learning to Autofocus*, CVPR 2020, [arXiv 2004.12260](https://arxiv.org/abs/2004.12260)(Pixel 3):确认对焦呼吸导致边缘进出视场,用缩放-裁剪配准补偿;未给百分比。
- Ricolfe-Viala & Esparza, *The Influence of Autofocus Lenses in the Camera Calibration Process*, [arXiv 2402.04686](https://arxiv.org/abs/2402.04686)(2024,工业相机 EoSens 12CXP+ + 18 mm 手动对焦镜头,机械臂给真值,**非手机**):恒定焦距标定在对焦随距离变化时,Z 向位置系统性偏近,均值 100 mm(60–160 mm);提出「焦距随距离变化」的针孔模型。
- InFlux 基准(Liang et al., [arXiv 2510.23589](https://arxiv.org/abs/2510.23589)):动态内参(变焦/对焦)视频自标定基准,用 ARRI Alexa Mini + 电影变焦头(**非手机**);六个学习法基线里最好的 GeoCalib 也只有 52.9% 帧点对 EPE<300 px ⇒ **靠学习法逐帧估 K 目前不可用**。
- Ha et al., *Accurate Camera Calibration Robust to Defocus Using a Smartphone*, ICCV 2015, DOI [10.1109/ICCV.2015.101](https://doi.org/10.1109/ICCV.2015.101):讲的是标定板离焦模糊的鲁棒性,不是呼吸模型(旁证)。

### 5.2 手机自动对焦下 fx 漂移的发表量级
- **未见任何发表的 iPhone 数字**。Apple 开发者论坛 [thread 654288](https://developer.apple.com/forums/thread/654288)(iPad,iOS 13.5.1):锁焦后 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` 的 fx/fy 仍在变,无数字、0 回复。
- 由薄透镜公式**推算**(非实测,物理焦距 f 未逐机型核;手机主摄量级取 f ≈ 5.7 mm):f_px(F)/f_px(∞) = F/(F−f) ⇒ F=0.30 m +1.9%、0.20 m +2.9%、0.10 m +6.0%、0.07 m +8.9%、0.05 m +12.9%。台架自测 120 s 漂 10.9% 与「镜头在 ~6–7 cm 与远焦之间来回」量级相符,但 VCM 非理想(见 Won & Jeon),不能反推。

### 5.3 「focus-dependent intrinsics」有没有进标定/VIO 工具
- Kalibr:无(仅许可核过,代码未逐行核)。
- OpenVINS / Yang 2023 / Li 2014:内参在线估但**当常量**;Yang 2023 给出退化运动集合。
- 仅 Nobre 2017(DOI 10.1109/ICRA.2017.7989771)把焦距当连续时变量,代码许可未核。

---

## 6. 复刻方案(判决,不是菜单)

### 6.1 推荐:路线 ①「平台逐帧供 K,引擎逐帧消费」
抄谁:**不是抄算法,是抄管线形态**——ARKit(每帧 `ARCamera.intrinsics`)与 ARCore(`CameraIntrinsics` 每次 update 更新)就是这么做的;XRSLAM 核心(§3.2)本来就逐帧存 K、跨帧用各自 K,只差源头。
改动(全部列在 §3.7):引擎 4 处 + 报告 1 处 + iOS 宿主 1 处;C ABI 不加符号,只扩 `XRSLAMImageExtension`。

四端供 K:
- iOS:`PwCameraSlot.swift:351-361` 已逐帧读到 fx/fy/cx/cy,塞进 `ext` 即可;去掉 `:237-239` 锁焦(`lensPosition < 0` 分支已预留)。成片走既有 AVCapturePhotoOutput 路径,自动对焦下自然清晰。
- Android:运行时三段判定——(a) `getAvailableCaptureResultKeys()` 含 `STATISTICS_LENS_INTRINSICS_SAMPLES` ⇒ 取与帧时间戳最近的样本作当帧 K;(b) 否则读 `CaptureResult.LENS_INTRINSIC_CALIBRATION`,若其值随 `LENS_FOCUS_DISTANCE` 变化则当逐帧 K;(c) 都不满足 ⇒ 退化策略。
- HarmonyOS:无逐帧 K ⇒ 退化策略;`lensIntrinsicCalibration`(API 24)作静态 K。
- Web:退化策略或不支持 VIO。

退化策略(抄 ARCore 文档的用法):跟踪期 **锁焦**(Android `LENS_FOCUS_DISTANCE` 手动 / HarmonyOS `FocusMode.LOCKED`),**按快门瞬间切自动对焦、成片后锁回**;对焦运动期间(Android `LENS_STATE == MOVING` / HarmonyOS `FocusState.SCAN` / iOS `isAdjustingFocus`)的帧**不进滑窗**,只做 IMU 传播(XRSLAM 已有 `predict_pose`)。锁位不再固定 0.835,而是锁在「最近一次成功对焦位」,小物体时即近焦 ⇒ 成片与 VIO 同时受益。

验收判据(台架既有工具,不新造尺子):
1. 三臂同场回放:A 锁 0.835(基线)/ B 自动对焦 + 静态 K(阴性对照,预期变差)/ C 自动对焦 + 逐帧 K。**C 的 ATE 对 ARKit 回放不劣于 A**,B 显著劣于 A(证明 K 真的是变量)。
2. fx 漂移曲线:sidecar 已带每帧内参,画 fx(t) 与 `lensPosition(t)`;C 臂里 VIO 重投影残差不随 fx 漂移而抬升。
3. 尺度:沿用 ±5% 口径(09-22 拍板),C 不得比 A 差。
4. 成片:20–30 cm 小物体,用户肉眼判锐度(指标放行肉眼否决的先例已有四次,肉眼是终审)。

### 6.2 次选:路线 ③「对焦呼吸 1-D 模型」(只作后备)
做法:每机型一次离线标定 f(lensPosition) 查表或线性拟合(Sony 专利式),运行时用平台的 `lensPosition`/`LENS_FOCUS_DISTANCE`/`getFocusDistance()` 查 K。
为什么不选为主线:(a) 每机型一次标定 + 拟合是自研,违反「禁止自研」;(b) 线性映射被 US 11,151,746 B2 覆盖(风险);(c) 发表数据说 VCM 位置读数本身随温度/使用漂(Won & Jeon),而 iOS 文档明说 `lensPosition` 不是物理量、机型间不一致 ⇒ 模型输入不可靠;(d) 主点漂移也要建模。
何时用:Android/HarmonyOS 上「退化策略」影响体验且机型量大时,再对头部机型做。

### 6.3 不选:路线 ②「在线内参自标定」
§2 逐仓:可商用仓全无实现;有实现的全不可抄;实现者都当常量估;时变建模只有 Nobre 2017 无可商用代码;退化运动下不可观(Yang 2023)——小物体绕拍恰是近平面/小平移运动。

---

## 7. 风险与未核

- **Apple 逐帧内参矩阵的精度未核**:文档只说「当前成像参数」,未说是查表还是实测;台架 10.9% 漂移是它给的数,是否等于真实呼吸量未核。若它是粗查表,路线 ① 的 C 臂会在验收 1 里露馅。
- Apple 矩阵不含畸变;XRSLAM 走零畸变(§3.6),iPhone 主摄畸变量级未核。
- 滑窗内旧关键帧 K 各异时 `sqrt_inv_cov` 用当帧 K,数值影响未核(结构已支持)。
- Android:实现 `STATISTICS_LENS_INTRINSICS_SAMPLES` 的机型占比未知(可选键);`CaptureResult.LENS_INTRINSIC_CALIBRATION` 是否被厂商逐帧更新未核。
- HarmonyOS NEXT 华为官网文档未抓到(JS 页面),以 OpenHarmony 镜像文档为准;两者是否一致未核。
- Web:`focusDistance` 的浏览器实现状态未核。
- OKVIS2「无在线内参」为弱阴性(头文件 grep + 代码搜索索引均 0 命中)。
- Basalt/Kimera 单目支持未核(与本题无关,如实标注)。
- 推算的呼吸百分比用的物理焦距未逐机型核;iPhone 自动对焦 fx 漂移**无发表数据**,自测 10.9% 仍是孤证。
- 专利风险只针对路线 ③;路线 ① 为平台公开 API 的直接消费。

---

## 8. 一手来源清单
- 仓库 LICENSE 原文:各仓 raw 文件(§2 表内链接)。
- XRSLAM 源码:`~/Developer/xrslam-4beb1a9-thr`(分支 `build/gpufe-nothread-20260922`@`8a1cc12`)。
- pocketworld 源码:`~/.config/superpowers/worktrees/pocketworld/zero-arkit-preview-20260922`(`ios/Runner/PwCameraSlot.swift`、`PwVioCapability.swift:156-169`)。
- Apple/Android/ARCore/OpenHarmony/W3C 文档:§4 链接。
- 论文 DOI:§2、§5(Crossref 解析)。
- 专利:US 11,151,746 B2(Google Patents)。
