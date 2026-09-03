# 自动取帧"冗余连拍"抑制:同行/上游规则调研(2026-09-03)

问题(用户原话):"两个产品旋钮(最小快门间隔 / 视差阈值)都不应该我裁。同行在写算法的时候肯定考虑到了这一点,联网查。"

范围:只查"冗余抑制 / 最小间隔 / 关键帧非冗余判据",不重复 09-01 的"信息增益触发"六路调研。
纪律:每条打到源头(论文 PDF 原文 + GitHub 代码 file:line,固定到 commit),不接受二手转述;相关≠机制;本文不发明任何阈值。

现状对照(供读表时对齐口径):
- 开火 = geometry 角色:相邻视差角 ≥10/12/15°(weak/normal/strong)或位移 ≥0.10×d;唯一时间地板 250 ms 防连击;开火前 visualSimilarity(块均值签名)>0.92 判冗余(`lib/quality/frame_quality_constants.dart:29`),但实测开火时相似度 0.84–0.93 仍放行。
- 现役视觉证据 = `lib/official_capture/continuous_feature_tracks.dart` 的 `FrameTrackEvidence`:`seedTrackCount`(参考照片上 Shi-Tomasi 种子数)、`commonTrackCount`(LK 追到当前帧的存活数)、`commonTrackFraction = common/seed`、`meanNormalizedDisplacement`(VINS 口径 10/460)、`hasNewFeatureBurst`(VINS-Fusion 口径 `new > 0.5×live`);开火授权 = `AliceVisionMotionSegment.ready || _newFeatureBurst`(`auto_capture_controller.dart:414`)。**`commonTrackFraction` 目前只进遥测,不参与判决**(`ar_capture_page.dart:2962`、`capture_session.dart:1723`)。

---

## 0. 一页结论

| 系统 | 冗余判据(机制) | 时间地板 | 一句话 |
|---|---|---|---|
| ORB-SLAM/2/3 | **当前帧跟踪到的地图点 < 参考关键帧地图点的 90%(单目)/75%(双目·RGB-D)** 才允许插关键帧;插入后由 Local Mapping **删掉"90% 地图点已被 ≥3 个其他关键帧看到"的冗余关键帧** | **下限 0 帧**(`mMinFrames=0`);上限 `mMaxFrames=fps`(≈1 s)强制;ORB-SLAM3 惯性档另加 ≥0.5 s 强制 | 唯一有源码、专为"最小视觉变化"设计的非冗余规则;两段式(宽进 + 事后剔除) |
| VINS-Mono/Fusion | 均值视差 ≥ 10 px/460(理论上旋转补偿,代码里补偿被注释掉);`last_track_num<20` 强制关键帧(Fusion 再加 `long_track_num<40`、`new>0.5×last`) | **无**(仅前端发布限频 `freq: 10` Hz) | 视差是"够不够三角化",不是"像不像" |
| PTAM | 与最近关键帧的相机距离 / 场景均深 > WiggleScale(默认 0.1 m)归一化值 | **>20 帧**硬地板(约 0.67 s@30 fps)+ 队列 <3 | 最早的"距离+时间"双地板 |
| DSO | 加权(光流均方 + 去旋转光流 + 曝光变化)> 1;"先 5–10 KF/s 多取,再边缘化冗余" | **无**(可选固定 KF/s 模式) | 与 ORB-SLAM 同哲学:宽进严出 |
| SVO | 到所有关键帧的欧氏距离 > 12% 场景均深(分轴 1.0/0.8/1.3 倍) | **无** | 纯几何,与我们的 0.10×d 同族 |
| AliceVision KeyframeSelection(视频离线) | smart:累计光流 ≥ 10% 短边才切段,每段取最锐且居中的一帧,明示"避免选到两张连续、运动无显著差异的锐帧";regular:`minFrameStep=12 / maxFrameStep=36` | regular 有(12 帧);smart **无** | 我们已复刻其 smart 步(`alicevision_motion_segment.dart`) |
| Apple Object Capture | 内部判据**未公开**;公开口径只有"自动选取锐度/清晰度/曝光好的照片、多视角"、"移动太快则暂停自动拍"、手动请求后"有一段时间"不出片(长度未公开) | 未公开 | 无法复刻,只能对齐 UX 语言 |
| RealityScan/RealityCapture | 拍摄指引:相邻 **≥~70% 重叠**、**视点变化 ≤30°**、"不要原地只转相机"、"不要限制张数" | 无 | 只给**上界**(别太稀),从不给"别太密" |
| Polycam | Auto:"按你的移动自动决定何时拍"(判据未公开);Timer:定间隔(转盘用);指引每 15–30° 一张、相邻 70–75% 重叠;非 LiDAR 手动模式 ≥20 张 ~70% 重叠 | Timer 模式有(值未公开);Auto 未公开 | "0.5 s 一张"只是第三方评测,非官方 |
| KIRI Engine | Auto:陀螺仪 + "识别特征点在合适时刻拍"(判据未公开);Timer:"例如每 3 秒";指引 ≥20 张、70% 重叠 | Timer 有(用户设) | 同上 |
| Luma / Scaniverse | Luma 官方文档未找到;Scaniverse 是连续录制,关键帧策略未公开 | — | 未公开 |
| Agisoft / COLMAP | Agisoft:相邻 **≥60–70%** 重叠 = 每点 ≥3 张可见,"多于所需总好过不够,事后可禁用/跳过多余影像";COLMAP:每个物体 ≥3 张可见,"别原地只转相机" | 无 | 摄影测量界处理冗余的位置是**事后**,不在快门 |

**判决(详见 §9)**:唯一可直接复刻、且专为"最小视觉变化"设计的上游规则是 **ORB-SLAM 的 90% 规则**(单目 `mnMatchesInliers < 0.9 × nRefMatches`);它在形式上对应我们已在算的 `commonTrackFraction`,但计数口径不同(3D 地图点·≥3 次观测·位姿优化后内点 vs 2D LK 存活),而且 ORB-SLAM 的完整不变量是"宽进 + 事后剔除"两段,只抄插入一半等于只抄半个不变量。**没有任何一个上游把"最小快门间隔"当作冗余判据**:有时间地板的只有 PTAM(20 帧)和 AliceVision regular(12 帧),且都是离线/SLAM 语境的工程护栏,不是"像不像"的判据;ORB-SLAM/VINS/DSO/SVO 的时间地板都是 0。

---

## 1. ORB-SLAM / ORB-SLAM2 / ORB-SLAM3 关键帧插入

### 1.1 论文原文(ORB-SLAM, Mur-Artal et al., T-RO 2015, arXiv:1502.00956,§V.E "New Keyframe Decision",PDF 第 8 页)

> "The last step is to decide if the current frame is spawned as a new keyframe. As there is a mechanism in the local mapping to cull redundant keyframes, we will try to insert keyframes as fast as possible, because that makes the tracking more robust to challenging camera movements, typically rotations. To insert a new keyframe all the following conditions must be met:
> 1) More than 20 frames must have passed from the last global relocalization.
> 2) Local mapping is idle, or more than 20 frames have passed from last keyframe insertion.
> 3) Current frame tracks at least 50 points.
> 4) Current frame tracks less than 90% points than Kref.
> Instead of using a distance criterion to other keyframes as PTAM, we impose a minimum visual change (condition 4). Condition 1 ensures a good relocalization and condition 3 a good tracking. If a keyframe is inserted when the local mapping is busy (second part of condition 2), a signal is sent to stop local bundle adjustment, so that it can process as soon as possible the new keyframe."

同文 §VI.E "Local Keyframe Culling"(PDF 第 9 页)—— 冗余的**另一半**:

> "In order to maintain a compact reconstruction, the local mapping tries to detect redundant keyframes and delete them. ... We discard all the keyframes in Kc whose 90% of the map points have been seen in at least other three keyframes in the same or finer scale."

同文(PDF 第 5 页)给出设计哲学:

> "Map points and keyframes are created with a generous policy, while a later very exigent culling mechanism is in charge of detecting redundant keyframes and wrongly matched or not trackable map points."

来源:https://arxiv.org/abs/1502.00956 (PDF 本地抽取 `pdftotext`,页码按 PDF 页序)。

### 1.2 ORB-SLAM(v1)代码 — raulmur/ORB_SLAM @ ce199650a256(2016-12-14),`src/Tracking.cc`

- L77–78:`mMinFrames = 0;` `mMaxFrames = 18*fps/30;`(注意:**论文写 20 帧,代码是 18×fps/30**)
- L625–663 `bool Tracking::NeedNewKeyFrame()`:
  - L632:`if(mCurrentFrame.mnId<mnLastRelocFrameId+mMaxFrames && mpMap->KeyFramesInMap()>mMaxFrames) return false;`
  - L642:`const bool c1a = mCurrentFrame.mnId>=mnLastKeyFrameId+mMaxFrames;`
  - L644:`const bool c1b = mCurrentFrame.mnId>=mnLastKeyFrameId+mMinFrames && bLocalMappingIdle;`
  - L645–646:`// Condition 2: Less than 90% of points than reference keyframe and enough inliers` / `const bool c2 = mnMatchesInliers<nRefMatches*0.9 && mnMatchesInliers>15;`
  - L648:`if((c1a||c1b)&&c2)`

URL:https://github.com/raulmur/ORB_SLAM/blob/ce199650a25653808f96b83557333bce3461d29f/src/Tracking.cc#L625-L663

### 1.3 ORB-SLAM2 代码 — raulmur/ORB_SLAM2 @ f2e6f51cdc8d(2017-10-11),`src/Tracking.cc`

- L81–87:`float fps = fSettings["Camera.fps"]; if(fps==0) fps=30;` … `// Max/Min Frames to insert keyframes and to check relocalisation` / `mMinFrames = 0;` / `mMaxFrames = fps;`
- L977–1061 `bool Tracking::NeedNewKeyFrame()`,关键行:
  - L989–990:重定位后 `mMaxFrames` 帧内且地图关键帧数 > `mMaxFrames` 时不插。
  - L992–996:`int nMinObs = 3; if(nKFs<=2) nMinObs=2; int nRefMatches = mpReferenceKF->TrackedMapPoints(nMinObs);` —— **分母 = 参考关键帧中"至少被 nMinObs 个关键帧观测过"的非坏地图点数**(`src/KeyFrame.cc` L250–275 `KeyFrame::TrackedMapPoints(const int &minObs)`)。
  - L1018:`bool bNeedToInsertClose = (nTrackedClose<100) && (nNonTrackedClose>70);`(双目/RGB-D 专用)
  - L1020–1026:`float thRefRatio = 0.75f; if(nKFs<2) thRefRatio = 0.4f; if(mSensor==System::MONOCULAR) thRefRatio = 0.9f;`
  - L1028–1035:
    ```
    // Condition 1a: More than "MaxFrames" have passed from last keyframe insertion
    const bool c1a = mCurrentFrame.mnId>=mnLastKeyFrameId+mMaxFrames;
    // Condition 1b: More than "MinFrames" have passed and Local Mapping is idle
    const bool c1b = (mCurrentFrame.mnId>=mnLastKeyFrameId+mMinFrames && bLocalMappingIdle);
    //Condition 1c: tracking is weak
    const bool c1c =  mSensor!=System::MONOCULAR && (mnMatchesInliers<nRefMatches*0.25 || bNeedToInsertClose) ;
    // Condition 2: Few tracked points compared to reference keyframe. Lots of visual odometry compared to map matches.
    const bool c2 = ((mnMatchesInliers<nRefMatches*thRefRatio|| bNeedToInsertClose) && mnMatchesInliers>15);
    ```
  - L1037:`if((c1a||c1b||c1c)&&c2)`;L1041–1056:mapping 空闲则插,否则 `InterruptBA()`,单目直接 `return false`。
- 分子 `mnMatchesInliers` 定义:L930–974 `Tracking::TrackLocalMap()`,位姿优化后统计**非外点且 `Observations()>0` 的地图点匹配数**(L941–958)。

URL:https://github.com/raulmur/ORB_SLAM2/blob/f2e6f51cdc8d067655d90a78c06261378e07e8f3/src/Tracking.cc#L977-L1061 (commit 前缀 f2e6f51cdc8d;行号以本次 curl 到的 master 为准)

ORB-SLAM2 论文(arXiv:1610.06475,§III.E "Keyframe Insertion",PDF 第 5 页)对 `bNeedToInsertClose` 的原文:

> "ORB-SLAM2 follows the policy introduced in monocular ORB-SLAM of inserting keyframes very often and culling redundant ones afterwards. The distinction between close and far stereo points allows us to introduce a new condition for keyframe insertion, which can be critical in challenging environments where a big part of the scene is far from the stereo sensor ... if the number of tracked close points drops below τt and the frame could create at least τc new close stereo points, the system will insert a new keyframe. We empirically found that τt = 100 and τc = 70 works well in all our experiments."

### 1.4 ORB-SLAM3 代码 — UZ-SLAMLab/ORB_SLAM3 @ 4452a3c4ab75(2022-02-10),`src/Tracking.cc`

- L584–585 / L1157–1158:`mMinFrames = 0; mMaxFrames = settings->fps();`(两条构造路径同值)
- L3064–3214 `bool Tracking::NeedNewKeyFrame()`,在 ORB-SLAM2 之上新增的**时间条件只针对惯性档**:
  - L3066–3074:IMU 未初始化时,`(mCurrentFrame.mTimeStamp-mpLastKeyFrame->mTimeStamp)>=0.25` 即插(单目惯性/双目惯性/RGB-D 惯性)。
  - L3147–3153:`if(mSensor==System::IMU_MONOCULAR){ if(mnMatchesInliers>350) thRefRatio = 0.75f; else thRefRatio = 0.90f; }`
  - L3165–3179:`// Temporal condition for Inertial cases` … `if ((mCurrentFrame.mTimeStamp-mpLastKeyFrame->mTimeStamp)>=0.5) c3 = true;`
  - L3181–3185:`c4` = 单目惯性 `15<mnMatchesInliers<75` 或 `RECENTLY_LOST`。
  - L3187:`if(((c1a||c1b||c1c) && c2)||c3 ||c4)`
- 纯视觉档(`MONOCULAR`)逻辑与 ORB-SLAM2 一致:仍是 0.9 规则,时间下限 0。

URL:https://github.com/UZ-SLAMLab/ORB_SLAM3/blob/4452a3c4ab75b1cde34e5505a36ec3f9edcdc4c4/src/Tracking.cc#L3064-L3214

论文(arXiv:2007.11898,PDF 第 7 页,IMU 初始化):"We initialize pure monocular SLAM [2] and run it during 2 seconds, inserting keyframes at 4Hz." —— 这是初始化阶段的固定频率,不是常态判据。

### 1.5 读法(机制,不是相关)

- **时间地板 = 0**:`mMinFrames=0` 且 `c1b` 只要求 Local Mapping 空闲;因此常态下 **90% 规则是唯一的"像不像"闸**。`mMaxFrames=fps` 是**上限**(约 1 s 无关键帧则强制,前提仍要 c2)。
- 90% 规则的**测量量**是"参考关键帧的 3D 地图点(≥3 次观测)在当前帧位姿优化后还有多少是内点",本质是**共视率下降到 90% 以下**。它不看相机走了几厘米、转了几度,也不看图像相似度。
- ORB-SLAM 自己承认这条规则**宽**("we will try to insert keyframes as fast as possible"),冗余的真正清理在 §VI.E 的事后剔除(90% 地图点被 ≥3 个其他关键帧看到 → 删)。论文实验部分(PDF 第 13 页):"most of the keyframes are destroyed by the culling procedure soon after creation, and only a small subset survive until the end".

---

## 2. VINS-Mono / VINS-Fusion 关键帧判据

### 2.1 论文原文(VINS-Mono, Qin/Li/Shen, T-RO 2018, arXiv:1708.03852,§IV.A "Vision Processing Front-end",PDF 第 4 页)

> "Keyframes are also selected in this step. We have two criteria for keyframe selection. The first one is the average parallax apart from the previous keyframe. If the average parallax of tracked features is between the current frame and the latest keyframe is beyond a certain threshold, we treat frame as a new keyframe. Note that not only translation but also rotation can cause parallax. However, features cannot be triangulated in the rotation-only motion. To avoid this situation, we use short-term integration of gyroscope measurements to compensate rotation when calculating parallax. Note that this rotation compensation is only used to keyframe selection, and is not involved in rotation calculation in the VINS formulation. ... Another criterion is tracking quality. If the number of tracked features goes below a certain threshold, we treat this frame as a new keyframe. This criterion is to avoid complete loss of feature tracks."

### 2.2 VINS-Mono 代码 — HKUST-Aerial-Robotics/VINS-Mono @ 90dabb5ec799(2024-05-23)

`vins_estimator/src/feature_manager.cpp` L45–97 `bool FeatureManager::addFeatureCheckParallax(int frame_count, const map<...> &image, double td)`:
- L51/L70:`last_track_num` = 本帧续上的已有轨迹数。
- L74–75:`if (frame_count < 2 || last_track_num < 20) return true;`
- L77–85:对 `start_frame <= frame_count-2` 且延续到 `frame_count-1` 的轨迹累加 `compensatedParallax2(it_per_id, frame_count)`。
- L95:`return parallax_sum / parallax_num >= MIN_PARALLAX;`

`compensatedParallax2` L355–388:比较的是 **`frame_count-2` 与 `frame_count-1`**(倒数第三与倒数第二帧),L357–358 注释 `//check the second last frame is keyframe or not` / `//parallax betwwen seconde last frame and third last frame`;**旋转补偿代码被注释掉**(L373 `//p_i_comp = ric[...]...` → L374 `p_i_comp = p_i;`),即代码里实际是未补偿视差(与论文叙述不一致,复刻时以代码为准)。`FeaturePerFrame::point` 是归一化平面坐标(`feature_manager.h` L21–33)。

阈值:`parameters.cpp` L56–57 `MIN_PARALLAX = fsSettings["keyframe_parallax"]; MIN_PARALLAX = MIN_PARALLAX / FOCAL_LENGTH;`;`parameters.h` L11 `const double FOCAL_LENGTH = 460.0;`;`config/euroc/euroc_config.yaml` L56 `keyframe_parallax: 10.0 # keyframe selection threshold (pixel)`。

判决出口:`estimator.cpp` L124–127 `if (f_manager.addFeatureCheckParallax(frame_count, image, td)) marginalization_flag = MARGIN_OLD; else marginalization_flag = MARGIN_SECOND_NEW;` —— **非关键帧不是被丢弃,而是被"边缘化次新帧"(保留其 IMU 预积分)**。

**时间间隔**:关键帧逻辑里**没有**。唯一的时间量在前端 `feature_tracker/src/feature_tracker_node.cpp` L51–62,把发布给估计器的帧限到 `FREQ`(`euroc_config.yaml` L47 `freq: 10 # frequence (Hz) of publish tracking result. At least 10Hz for good estimation.`),这是前端限频,不是"像不像"判据。

URL:https://github.com/HKUST-Aerial-Robotics/VINS-Mono/blob/master/vins_estimator/src/feature_manager.cpp#L45-L97

### 2.3 VINS-Fusion 代码 — HKUST-Aerial-Robotics/VINS-Fusion @ be55a937a574(2021-07-26)

`vins_estimator/src/estimator/feature_manager.cpp` L52–119,同名函数,新增三个计数并把强制条件扩为(L93–96,含作者留下的两版旧条件注释):
```
//if (frame_count < 2 || last_track_num < 20)
//if (frame_count < 2 || last_track_num < 20 || new_feature_num > 0.5 * last_track_num)
if (frame_count < 2 || last_track_num < 20 || long_track_num < 40 || new_feature_num > 0.5 * last_track_num)
    return true;
```
其中 `long_track_num` = 轨迹长度 ≥4 帧的续上数(L88–89),`new_feature_num` = 本帧新建轨迹数(L82)。视差阈值同样 `keyframe_parallax: 10.0`(`config/euroc/euroc_mono_imu_config.yaml` L46、`config/realsense_d435i/realsense_stereo_imu_config.yaml` L59),`FOCAL_LENGTH = 460.0`(`parameters.h` L23)。**无最小时间间隔**。

URL:https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/vins_estimator/src/estimator/feature_manager.cpp#L52-L119

### 2.4 读法

VINS 的两条都不是"冗余抑制":视差 ≥10/460 是"够不够三角化",`last_track_num<20` / `new>0.5×last` 是"再不切窗口就丢轨迹"。VINS 处理"太像"的方式是把该帧**边缘化**而不是不接收 —— 与我们"重复的保留不销毁"其实同构(帧进来了,只是不当关键帧)。我们现役 `hasNewFeatureBurst`(`continuous_feature_tracks.dart` L105–111)复刻的是 VINS-Fusion 第三条。

---

## 3. Apple Object Capture(ObjectCaptureSession)

### 3.1 API 文档原文(developer.apple.com,经 `tutorials/data/documentation/realitykit/objectcapturesession*.json` 抽取)

- `CaptureState.capturing`:"Auto-capture is in progress."
- `isAutoCaptureEnabled`:"Enables/disables auto-capture system. If disabled, only manually triggered shots are taken."
- `canRequestImageCapture`:"Will be `true` only when a call to requestImageCapture() is expected to be successful. It will be `false` when not in the `.capturing` state or if the session is too busy to currently process a new request. **There is a period of time after requesting an image capture where this property will be `false` and a new call to requestImageCapture() will not produce a new image.**"(时长未公开)
- `Feedback.movingTooFast`:"The user is moving too quickly for clear images and the capturing may be paused to ensure quality."
- `Feedback.outOfFieldOfView`:"The bounding box of the object is not in the field of view of the camera so auto-capture will not operate."
- `Feedback.environmentTooDark`:"Auto-capture will stop and the user will need to increase lighting levels ..."
- `Feedback.overCapturing`:"If the `numberOfShotsTaken > maximumNumberOfInputImages` then any additional shots will not be used in an on-device reconstruction ..."
- `userCompletedScanPass`:"... will switch to `true` when the user has moved the device in a full circular scan pass around the bounding box of the target object and captured enough data to fill completely the capture dial."
- `Feedback` 全部 case:environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected, objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing —— **没有任何"重复/冗余/间隔"反馈**。

URL:https://developer.apple.com/documentation/realitykit/objectcapturesession (及其子页 feedback-swift.enum / canrequestimagecapture / isautocaptureenabled / usercompletedscanpass)

### 3.2 WWDC23 Session 10191 "Meet Object Capture for iOS"(Lei Zhou)原文

> "In the capturing state, the session automatically takes images while you slowly move around the object."
> "When you circle around an object, our system will automatically select image shots with good sharpness, clarity, and exposure, and collect LiDAR points from various view angles."
> "If you move too fast, automatic capture will stop and remind you to slow down."
> "Image overlap between different scan passes is also important. Part of the object in a scan pass should be captured in previous passes."

URL:https://developer.apple.com/videos/play/wwdc2023/10191/

### 3.3 Apple 拍摄指引(文章 "Capturing photographs for RealityKit Object Capture")

> "The number of pictures that RealityKit needs in order to create an accurate 3D representation varies depending on the complexity and size of the object, but adjacent shots must have substantial overlap. Position sequential images so they have a 70% overlap or more. Anything less than 50% overlap between neighboring shots, and the object-creation process may fail or result in a low-quality recreation."

URL:https://developer.apple.com/documentation/realitykit/capturing-photographs-for-realitykit-object-capture

WWDC21 10076:"Depending on the object, 20 to 200 close-up images should be enough to get good results." / "try to maintain a high degree of overlap between the images."

### 3.4 读法

Apple **公开的**自动拍口径只有三样:按锐度/清晰度/曝光选片、多视角、移动太快就停。"该拍了"的内部判据(是否有最小间隔、是否查重叠)**未公开**;唯一能证实的时间量是手动请求后的"a period of time"不出片,长度未公开。不可复刻,只能对齐 UX 文案。

---

## 4. RealityScan / RealityCapture 拍摄指引

### 4.1 RealityScan Mobile 文档 "Photogrammetry Camera Movement"(dev.epicgames.com;**直连超时,经 r.jina.ai 阅读代理取回,建议本机浏览器复核一次**)

> "Maintain high overlap between images. They should overlap by approximately 70% in all directions"
> "Do not change the camera viewpoint by more than 30 degrees between neighboring camera poses"
> "Avoid taking shots from the same spot while only changing the camera angle. An organized variety of camera positions and angles will give you better results"
> "Avoid hasty movements, as those can result in blurry and unusable photos"
> "Each point you want to recreate should be visible in at least two images"
> "Take loops around it at different elevations or follow a grid"

URL:https://dev.epicgames.com/documentation/en-us/realityscan-mobile/Photogrammetry-Camera-Movement

### 4.2 RealityScan(桌面,原 RealityCapture)帮助 "How to Take Photographs"(直连成功)

> "Do not limit image count, RealityScan can handle any."
> "Always move when taking photos. Standing at one point produces just a panorama and it does not contribute to a 3D model creation."
> "Do not change a view point more than 30 degrees."
> "Complete loops. ..."

该页**没有**重叠百分比,也没有任何"太多/太像"的警告。搜索引擎摘要里的"至少 60%、80% 更好"来自第三方(Creative Bloq / 80.lv),不算源头。

URL:https://rshelp.capturingreality.com/en-US/tutorials/takingpictures.htm

### 4.3 读法

Epic 两份文档给的都是**上界**(视点变化 ≤30°、重叠 ≥70%)和"张数不限"。**没有任何一句要求"别拍太密"**。摄影测量厂商把冗余当成无害(甚至"do not limit image count")。

---

## 5. Polycam / Luma / Scaniverse / KIRI

### 5.1 Polycam(learn.poly.cam,经 Zendesk Help Center API 取到正文)

"How to Use Object Mode":
> "Auto Mode — Tap the capture button once, and the app automatically decides when to take photos based on your movement. Recommended for most capture sessions as it ensures images are taken sequentially for the best results."
> "Manual Mode — Tap the capture button to take individual photos at your own pace."
> "Timer Mode — Automatically captures photos at set intervals. This mode is ideal for objects placed on a rotating turntable."
> "Take photos every 15-30 degrees around the circle" / "Have between 70-75% overlap between consecutive shots" / "Maintain consistent 3-5 foot distance"

"How to Use Space Mode (Non-LiDAR Devices)":
> "Auto (default). Captures continuously as you move. Your device buzzes to confirm it is collecting data. Walk through the space at a steady pace."
> "Manual. You decide when each photo is taken. Needs at least 20 images with roughly 70% overlap between consecutive shots for reconstruction to succeed."

URL:https://learn.poly.cam/hc/en-us/articles/27425185907348-How-to-Use-Object-Mode ; https://learn.poly.cam/hc/en-us/articles/43933482446996-How-to-Use-Space-Mode-Non-LiDAR-Devices

**注意**:网上流传的"Polycam Auto 每 0.5 s 拍一张、随移动自动调整"出自第三方评测(3dwithus),官方文档只说 "based on your movement",**判据未公开**。

### 5.2 KIRI Engine(kiriengine.app 博客/教程,直连成功)

"Exploring 3 Capturing Methods: Manual, Auto, and Video":
> "The app utilizes gyroscope data to precisely track the user's phone movements. As the user rotates around the object, the app automatically recognizes and captures the object's feature points, taking photos at the appropriate moments."

"KIRI Engine Launches the Timer Mode":
> "In the software, set a time interval for auto photo capture, such as every 3 seconds. As the user moves around, the phone will automatically take photos at a consistent speed."

"Photo Scan"/"Failed Photo Scan Tips":
> "Aim for at least 20 photos with a 70% overlap between adjacent shots" / "Ensure 70% overlap between each photo taken."

URL:https://www.kiriengine.app/blog/explained/exploring-three-innovative-3d-scanning-methods ; https://www.kiriengine.app/blog/announcement/kiri-engine-timer-mode-automated-3d-scanning ; https://www.kiriengine.app/blog/explained/photo-scan-mode

Auto 模式"合适时刻"的判据**未公开**。

### 5.3 Scaniverse(nianticspatial.com/docs/scaniverse/techniques)

> "Maintain overlap with previous views of the same features." / "Keep a continuous motion, even if very slow." / "Move your device steadily. Avoid sudden movements to prevent blur or position tracking loss."

Scaniverse 是连续录制(Record)而非自动拍照,关键帧策略**未公开**。URL:https://www.nianticspatial.com/docs/scaniverse/techniques/

### 5.4 Luma

官方 capture guide 未找到(旧地址 docs.lumalabs.ai/MCrGAEukR4orR9 现 404;App Store 页描述无拍摄口径;lumalabs.ai 搜索无命中)。网上"60–80% 重叠、reticle 变橙表示太快"均为第三方教程。**记为未公开/未查到源头**。

---

## 6. 学术经典:PTAM / DSO / SVO / AliceVision

### 6.1 PTAM(Klein & Murray, ISMAR 2007,§6.2 "Keyframe insertion and epipolar search",PDF 第 5 页)

> "Keyframes are added whenever the following conditions are met: Tracking quality must be good; time since the last keyframe was added must exceed twenty frames; and the camera must be a minimum distance away from the nearest keypoint already in the map. The minimum distance requirement avoids the common monocular SLAM problem of a stationary camera corrupting the map, and ensures a stereo baseline for new feature triangulation. The minimum distance used depends on the mean depth of observed features, so that keyframes are spaced closer together when the camera is very near a surface, and further apart when observing distant walls."

代码 Oxford-PTAM/PTAM-GPL @ d9dca71ad57b:
- `Src/Tracker.cc` L151–155:`// Heuristics to check if a key-frame should be added to the map:` `if(mTrackingQuality == GOOD && mMapMaker.NeedNewKeyFrame(mCurrentKF) && mnFrame - mnLastKeyFrameDropped > 20 && mMapMaker.QueueSize() < 3)`
- `Src/MapMaker.cc` L689–698 `NeedNewKeyFrame`:`dDist = KeyFrameLinearDist(kCurrent, *pClosest); dDist *= (1.0 / kCurrent.dSceneDepthMean); if(dDist > GV2.GetDouble("MapMaker.MaxKFDistWiggleMult",1.0,SILENT) * mdWiggleScaleDepthNormalized) return true;`
- `Src/MapMaker.cc` L38:`GV3::Register(mgvdWiggleScale, "MapMaker.WiggleScale", 0.1, SILENT); // Default to 10cm between keyframes`;L320:`mdWiggleScaleDepthNormalized = mdWiggleScale / pkFirst->dSceneDepthMean;`

URL:https://www.robots.ox.ac.uk/~gk/publications/KleinMurray2007ISMAR.pdf ; https://github.com/Oxford-PTAM/PTAM-GPL/blob/master/Src/Tracker.cc#L151-L155 ; https://github.com/Oxford-PTAM/PTAM-GPL/blob/master/Src/MapMaker.cc#L689-L698

读法:PTAM 是**唯一**把"时间地板"(20 帧)写进关键帧规则的经典系统;但其距离判据与我们的 `0.10×d` 同族(距离/场景均深)。ORB-SLAM 论文明说自己**放弃**了 PTAM 的距离判据换成 90% 视觉变化。

### 6.2 DSO(Engel/Koltun/Cremers, arXiv:1607.02565,§3.1 "Frame Management" → "Step 2: Keyframe Creation",PDF 第 8 页)

> "Similar to ORB-SLAM, our strategy is to initially take many keyframes (around 5-10 keyframes per second), and sparsify them afterwards by early marginalizing redundant keyframes. We combine three criteria to determine if a new keyframe is required:
> 1. New keyframes need to be created as the field of view changes. We measure this by the mean square optical flow (from the last keyframe to the latest frame) f := ... during initial coarse tracking.
> 2. Camera translation causes occlusions and dis-occlusions, which requires more keyframes to be taken (even though f may be small). This is measured by the mean flow without rotation, i.e., ft := ..., where pt is the warped point position with R = I.
> 3. If the camera exposure time changes significantly, a new keyframe should be taken. This is measured by the relative brightness factor between two frames a := |log(e^{aj−ai} tj ti^{-1})|.
> ... Finally, a new keyframe is taken if wf f + wft ft + wa a > Tkf, where wf, wft, wa provide a relative weighting of these three indicators, and Tkf = 1 by default."

"Step 3: Keyframe Marginalization":"2. Frames with less than 5% of their points visible in I1 are marginalized."

代码 JakobEngel/dso @ 7b0c99f01d23:
- `src/util/settings.cpp` L35–42:`/* Parameters controlling when KF's are taken */` `float setting_keyframesPerSecond = 0; // if !=0, takes a fixed number of KF per second.` `bool setting_realTimeMaxKF = false; // if true, takes as many KF's as possible (will break the system if the camera stays stationary)` `float setting_maxShiftWeightT= 0.04f * (640+480);` `float setting_maxShiftWeightR= 0.0f * (640+480);` `float setting_maxShiftWeightRT= 0.02f * (640+480);` `float setting_kfGlobalWeight = 1; // general weight on threshold, the larger the more KF's are taken (e.g., 2 = double the amount of KF's).` `float setting_maxAffineWeight= 2;`
- `src/FullSystem/FullSystem.cpp` L869–886:固定频率模式 `(fh->shell->timestamp - allKeyFramesHistory.back()->timestamp) > 0.95f/setting_keyframesPerSecond`;默认模式 `needToMakeKF = allFrameHistory.size()==1 || kfGlobalWeight*maxShiftWeightT*sqrt(tres[1])/(w+h) + ...R*sqrt(tres[2])/(w+h) + ...RT*sqrt(tres[3])/(w+h) + ...maxAffineWeight*|log(refToFh[0])| > 1 || 2*coarseTracker->firstCoarseRMSE < tres[0];`

URL:https://github.com/JakobEngel/dso/blob/master/src/FullSystem/FullSystem.cpp#L869-L886 ; https://github.com/JakobEngel/dso/blob/master/src/util/settings.cpp#L35-L42

读法:时间地板 0(固定频率是可选替代模式);判据是**光流位移占图像尺寸比例**(与 AliceVision 同族)。同样是"先多取再边缘化"。

### 6.3 SVO(Forster/Pizzoli/Scaramuzza, ICRA 2014,§VI "Implementation Details",PDF 第 5 页)

> "A keyframe is selected if the Euclidean distance of the new frame relative to all keyframes exceeds 12% of the average scene depth. When a new keyframe is inserted in the map, the keyframe farthest apart from the current position of the camera is removed."

代码 uzh-rpg/rpg_svo @ d6161063b47f:`svo/src/frame_handler_mono.cpp` L304–315 `needNewKf(double scene_depth_mean)`:对每个共视关键帧 `relpos = new_frame_->w2f(kf->pos())`,若 `|x|/depth < kfSelectMinDist && |y|/depth < kfSelectMinDist*0.8 && |z|/depth < kfSelectMinDist*1.3` 则 `return false`;`svo/src/config.cpp` L46 `kfselect_mindist(vk::getParam<double>("svo/kfselect_mindist", 0.12))`。L188:`if(!needNewKf(depth_mean) || tracking_quality_ == TRACKING_BAD)` 不建关键帧。

URL:https://rpg.ifi.uzh.ch/docs/ICRA14_Forster.pdf ; https://github.com/uzh-rpg/rpg_svo/blob/master/svo/src/frame_handler_mono.cpp#L304-L315

读法:纯几何,无时间地板;与我们的 `0.10×d` 同族(它是 0.12×d,且分轴不等)。

### 6.4 AliceVision KeyframeSelection(MPL-2.0,alicevision/AliceVision @ 2cb1a3933bd0,2026-08-28 develop)

`src/software/utils/main_keyframeSelection.cpp` L46–51 默认值:
```
bool useSmartSelection = true;          // enable the smart selection instead of the regular one
unsigned int minFrameStep = 12;         // minimum number of frames between two keyframes (regular selection)
unsigned int maxFrameStep = 36;         // maximum number of frames between two keyframes (regular selection)
unsigned int minNbOutFrames = 40;       // minimum number of selected keyframes (smart selection)
unsigned int maxNbOutFrames = 2000;     // maximum number of selected keyframes (both selections)
float pxDisplacement = 10.0;            // percentage of pixels that have moved across frames since last keyframe (smart selection)
```
L130–132 帮助文本:"Percentage of pixels in the image that have been displaced since the last selected frame. The absolute number of moving pixels is determined using min(imageWidth, imageHeight)."

`src/aliceVision/keyframe/KeyframeSelector.hpp` L69–87 `processSmart` 说明(原文节选):
> "- Step 1: split the whole sequence into subsequences depending on the accumulated movement ("motion step")
> - Step 3: for each subsequence, find the frame that best fit both a sharpness criteria (as sharp as possible) and a temporal criteria (as in the middle of the subsequence as possible); the goal of these criteria is to avoid the following cases: - the selected frame is well located temporally but is blurry - the selected frame is very sharp but is located at the very beginning or very end of the subsequence, meaning that it is likely adjacent to another very sharp frame in another subsequence; in that case, we might select two very sharp frames that are consecutive with no significant differences in their motion"

`KeyframeSelector.cpp` L220 `float step = pxDisplacement * std::min(_frameWidth, _frameHeight) / 100.0;` L228 `if (motionAcc >= step)` 切段;`processRegular()` L144–148 `step = _minFrameStep + (_maxFrameStep-_minFrameStep)/2`。

URL:https://github.com/alicevision/AliceVision/blob/develop/src/aliceVision/keyframe/KeyframeSelector.hpp#L64-L100 ; https://github.com/alicevision/AliceVision/blob/develop/src/software/utils/main_keyframeSelection.cpp#L46-L51

读法:AliceVision 是**唯一**把"避免两张连续、运动无差异的锐帧"写成显式目标的上游,其解法不是最小间隔,而是"每个运动段只出一帧、取段中央"。我们 `alicevision_motion_segment.dart` 已复刻 smart 的切段(10% 短边);但它的**前提**是"素材已录好、每段必出一帧"(09-01 记忆已指出),实时场景下"段中央"无法定义,所以我们只复刻了"段满才切"。regular 模式的 12/36 帧是固定采样而非判据。

---

## 7. 摄影测量重叠率标准

| 来源 | 原文 | URL |
|---|---|---|
| Agisoft Metashape Pro 2.3 User Manual,"Capturing scenarios"(PDF 第 17 页,印刷页 11) | "The overlap between the images should be at least 60-70%, i.e. each point should be visible on at least three photos." | https://www.agisoft.com/pdf/metashape-pro_2_3_en.pdf |
| 同上,PDF 第 16 页 | "Taking more images than needed is always better than having insufficient image overlap or incomplete dataset." / "Number of photos: more than required is better than not enough." | 同上 |
| Agisoft Helpdesk "General image capture tips" | "60% of side overlap + 80% of forwarding overlap"(航拍);"more than required is better than not enough. Later on, you can disable or skip excessive images." | https://agisoft.freshdesk.com/support/solutions/articles/31000149337-general-image-capture-tips |
| COLMAP Tutorial,"Structure-from-Motion" | "Capture images with **high visual overlap**. Make sure that each object is seen in at least 3 images – the more images the better." / "Capture images from **different viewpoints**. Do not take images from the same location by only rotating the camera." | https://colmap.github.io/tutorial.html |
| Apple(§3.3) | "70% overlap or more"; "<50% ... may fail" | 见 §3.3 |
| RealityScan(§4) | "approximately 70% in all directions"; "≤30°" | 见 §4 |
| Polycam(§5.1) | "70-75% overlap between consecutive shots"; "every 15-30 degrees" | 见 §5.1 |
| KIRI(§5.2) | "70% overlap between adjacent shots" | 见 §5.2 |

读法:所有厂商都只规定**下限重叠**(60–80%)/**上限角度**(≤30°、每 15–30°)。**没有一家规定"重叠不得超过 X%"或"两张之间至少隔 Y 秒"**。Agisoft 明说多余影像事后"disable or skip"。摄影测量的冗余处理位置是事后策展,不是快门。

---

## 8. 时间地板总账(有/无,值,出处)

| 系统 | 最小时间/帧间隔 | 出处 |
|---|---|---|
| ORB-SLAM v1 | 下限 `mMinFrames = 0`;上限 `mMaxFrames = 18*fps/30`(论文写 20 帧) | Tracking.cc L77–78 |
| ORB-SLAM2 | 下限 0;上限 `mMaxFrames = fps`(≈1 s 强制,仍需 c2) | Tracking.cc L86–87, L1029 |
| ORB-SLAM3 | 下限 0(纯视觉);惯性档 ≥0.5 s 强制、IMU 未初始化 ≥0.25 s 强制 | Tracking.cc L584–585, L3068–3071, L3171–3177 |
| VINS-Mono/Fusion | **无**;前端发布限频 `freq: 10` Hz | feature_tracker_node.cpp L51–62;euroc_config.yaml L47 |
| PTAM | **>20 帧**(且队列 <3) | Tracker.cc L154–155;论文 §6.2 |
| DSO | **无**(可选 `setting_keyframesPerSecond` 固定频率) | settings.cpp L36;FullSystem.cpp L870–874 |
| SVO | **无** | frame_handler_mono.cpp L304–315 |
| AliceVision regular | `minFrameStep=12`/`maxFrameStep=36` | main_keyframeSelection.cpp L47–48 |
| AliceVision smart | **无**(累计光流 ≥10% 短边) | KeyframeSelector.cpp L220–228 |
| Apple | 手动请求后"a period of time"不出片,长度未公开;自动拍判据未公开 | canRequestImageCapture 文档 |
| Polycam Timer / KIRI Timer | 固定间隔(用户设;KIRI 例"every 3 seconds") | §5 |
| Polycam Auto / KIRI Auto | 未公开 | §5 |

**结论**:上游里"最小快门间隔"要么不存在(ORB-SLAM/VINS/DSO/SVO/AliceVision smart),要么是转盘/离线采样语境的固定节拍(Timer/regular),要么是 PTAM 的 20 帧工程护栏。**没有一个上游把时间间隔当作"像不像"的判据**;我们的 250 ms 防连击与上游的定位一致(护栏,不是判据),不必往上加。

---

## 9. 判决:哪条可直接复刻,与我们口径能否对齐

### 9.1 可直接复刻的非冗余规则 = ORB-SLAM 90% 规则(单目)

理由:
1. 上游明说它就是为"minimum visual change"而设,且是替代 PTAM 距离判据的(§1.1)。
2. 有源码、有常量、有分子分母定义(§1.3),三代实现一致(v1 0.9;v2/v3 单目 0.9、双目 0.75、惯性单目 0.75/0.90 按 >350 内点切换)。
3. 它直接回答用户症状:"相机挪了 10–17 cm/转 6–12°、相似度 0.84–0.93 还拍不拍"——ORB-SLAM 不看厘米/度/相似度,只看**参考关键帧的内容还有多少在当前帧里能被跟踪到**;≥90% 还在 → 不是新关键帧。

### 9.2 与我们 `commonTrackFraction` 的对齐(形式同、口径不同)

| | ORB-SLAM2 单目 c2 | 我们 `FrameTrackEvidence` |
|---|---|---|
| 分母 | `nRefMatches = mpReferenceKF->TrackedMapPoints(nMinObs=3)`:参考关键帧中**已三角化、≥3 个关键帧观测、非坏**的地图点数 | `seedTrackCount`:参考照片 128×128 灰度上的 Shi-Tomasi 种子数(2D,无三角化、无多视图验证) |
| 分子 | `mnMatchesInliers`:当前帧对局部地图投影匹配、**位姿优化后非外点**且 `Observations()>0` 的地图点数 | `commonTrackCount`:金字塔 LK 从上一预览帧续到当前帧、锚定到参考照片的存活轨迹数(无几何验证) |
| 阈值 | 0.9(单目) | (无;当前只遥测) |
| 附加下限 | `mnMatchesInliers > 15`;`nRefMatches` 用 `nMinObs=2` 当 `nKFs<=2` | `commonTrackCount >= 20` 才 `comparable` |
| 参考帧更新 | 每插一个关键帧,`mpReferenceKF` 随之更新;分母随 culling/点剔除变化 | 每次开火 `_commitTrackSource` 重置种子 |

结论:**`commonTrackFraction < 0.9` 是 ORB-SLAM c2 的形式对应**,可作为开火前的"最小视觉变化"闸;但要写明它是**同形不同量**——上游数的是经位姿优化验证的 3D 地图点,我们数的是 2D 光流存活。0.9 这个数字属于上游的计数口径(点池是 BA 验证过的、外点已剔),搬到 LK 存活率上时"0.9"没有被上游背书;若要用,需按记忆里的纪律(阳性对照/A-B 交替)在真机上验它对症状(相似度 0.84–0.93 仍开火)的判别力,而不是当成"上游定的阈值"。本文不裁这个数。

### 9.3 只抄插入一半 = 只抄半个不变量

ORB-SLAM/DSO/AliceVision 三家的完整不变量都是两段:**宽进**(90% / 5–10 KF/s / 段满就切)+ **事后剔除**(90% 地图点被 ≥3 KF 看到 → 删 / <5% 点可见 → 边缘化 / 每段只留最锐居中一帧)。我们"拍后判据 VINS 均值视差,重复的保留不销毁",等于只有宽进没有剔除。若要"冗余照片不进交付"而又不违反"交付绝对无损"铁律,上游给的位置是**事后策展(标记/跳过,不删)**,Agisoft 原话 "you can disable or skip excessive images"。这是策展层的问题,不是快门层。

### 9.4 上游对"10–17 cm / 6–12°"的口径

- SVO:`0.12×场景均深`(1 m 深 → 12 cm;2 m → 24 cm);PTAM:`WiggleScale 0.1 m` 按首关键帧深度归一化。我们的 `0.10×d` 与二者同族但更松(0.10 < 0.12)。**本文不建议改数**,只指出这两家都没有角度阈值,角度只在摄影测量厂商指引里以**上界**出现(≤30°、每 15–30° 一张)。
- 没有任何上游用图像块均值相似度做冗余判据;我们 `maxFrameSimilarity=0.92` 在上游无对应物(文件注释也承认是块均值签名)。

### 9.5 许可

ORB-SLAM/2/3、DSO、SVO、PTAM-GPL、VINS-Mono/Fusion 均为 **GPLv3/GPL**:只能独立重写规则(阈值和条件不受版权保护),**不许复制代码文本**(记忆红线)。AliceVision 为 **MPL-2.0**,可逐字节 port(我们已这么做)。

---

## 10. 专利红线复核(Shopify US12361636B2 / Google US9648297B1)

两颗雷的权利要求(patents.google.com 取回;Shopify 一条来自摘要/定义段,**未拿到编号 claim 1 全文,需律师/原文复核**):

- **Shopify US12361636B2**("Image generation based on tracked 3D scanning"):"... obtaining new 3D data points to include in the set of 3D scanning data from a subsequent perspective of the 3D object, the new 3D data points being non-overlapping with 3D data points already in the set of 3D scanning data; and responsive to determining that a number of the new 3D data points exceeds a predetermined threshold, automatically capturing a subsequent 2D image ..." —— 数的是**自上张以来新增的、不重叠的 3D 点数**超阈值就拍。
- **Google US9648297B1**("Systems and methods for assisting a user in capturing images for three-dimensional reconstruction",claim 1):"... identifying 3D feature points of the current video image data and of at least one previous image ... to identify two-dimensional (2D) feature points ... determining a 3D information ratio based on a number of the 3D feature points and a number of the 2D feature points; assisting the user with capturing an additional image of the target based on whether the 3D information ratio is greater than or equal to a threshold ..." —— 数的是 **3D 点数 / 2D 点数比**。

逐条对照:

| 上游规则 | 计量 | 踩 Shopify(新增 3D 点数 ≥ 阈值 → 拍)? | 踩 Google(3D/2D 比 ≥ 阈值 → 拍)? |
|---|---|---|---|
| ORB-SLAM 单目 90%(`mnMatchesInliers < 0.9×nRefMatches`) | 参考帧**已有** 3D 点在当前帧的**留存比**,触发方向是"留存下降" | 不踩:不数新增点,方向相反(留存减少而非新增超阈) | 不踩:分子分母都是 3D 地图点,不是 3D/2D 比 |
| 我们的 `commonTrackFraction`(2D LK 留存比) | 2D/2D | 不踩:无 3D 点 | 不踩:无 3D/2D 比 |
| ORB-SLAM2 双目 `bNeedToInsertClose = nTrackedClose<100 && nNonTrackedClose>70` | "可新建的近距 3D 点 >70" | **邻近雷区**(数"可以新建的 3D 点"超阈值 → 插关键帧);单目路径不启用,**不要复刻这一条** | 不踩 |
| VINS 视差 ≥10/460、`last_track_num<20`、`new_feature_num>0.5×last_track_num` | 2D 视差 / 2D 轨迹计数 | 不踩(全是 2D) | 不踩 |
| PTAM / SVO 距离判据 | 相机位姿距离 / 场景深度 | 不踩(不数点) | 不踩 |
| DSO 光流加权 | 2D 光流 + 曝光 | 不踩 | 不踩 |
| AliceVision pxDisplacement | 2D 光流累计 | 不踩 | 不踩 |

结论:ORB-SLAM 90% 规则与 VINS/AliceVision/PTAM/SVO 都数 2D 或位姿,与两颗雷的"新增 3D 点数""3D/2D 比"不同构;**唯一邻近雷区的是 ORB-SLAM2/3 双目/RGB-D 的 `bNeedToInsertClose`(数可新建 3D 点)**,单目路径不使用,我们也不应引入。09-01 那轮的结论(3D 点数阈值触发、3D/2D 比触发是雷)不变。

---

## 11. 未查到 / 不确定(单列)

1. **Apple ObjectCaptureSession 自动拍的内部判据**(是否查重叠、是否有最小间隔、间隔多长):未公开;`canRequestImageCapture` 的"a period of time"无数值。
2. **Polycam Auto / KIRI Auto 的"基于移动"判据**:未公开;"0.5 s"是第三方评测。
3. **Luma 官方拍摄指引**:未找到官方页面(旧 docs 链接 404)。
4. **RealityScan Mobile 文档**:直连 dev.epicgames.com 超时(隧道),经 r.jina.ai 代理取回,建议本机浏览器复核原文。
5. **Shopify 专利 claim 1 编号全文**:本次只拿到摘要/定义段的等价语句,红线复核需律师读原 claim。
6. **论文与代码不一致两处**(复刻以代码为准,已标):ORB-SLAM 论文"20 帧"vs 代码 `18*fps/30`(v1)/`fps`(v2/v3);VINS-Mono 论文"陀螺仪旋转补偿视差"vs 代码 `compensatedParallax2` 里补偿被注释掉。
7. **"0.9 搬到 LK 存活率上是否仍合适"**:上游未背书,属待验假设,不在本文裁定范围。

---

## 附:本次取证清单(本地副本在会话 scratchpad `src/`、`pdf/`、`apple/`、`web/`)

- 代码(curl raw.githubusercontent.com,commit 见各节):ORB_SLAM/ORB_SLAM2/ORB_SLAM3 Tracking.cc、KeyFrame.cc;VINS-Mono/Fusion feature_manager.cpp、parameters.cpp/.h、estimator.cpp、feature_tracker_node.cpp、euroc 配置;dso FullSystem.cpp、settings.cpp/.h;rpg_svo frame_handler_mono.cpp、config.cpp/.h;PTAM-GPL Tracker.cc、MapMaker.cc/.h;AliceVision KeyframeSelector.cpp/.hpp、main_keyframeSelection.cpp。
- 论文 PDF(arXiv/作者站,`pdftotext` 抽取):1502.00956、1610.06475、2007.11898、1708.03852、1607.02565、KleinMurray2007ISMAR、ICRA14_Forster;Agisoft metashape-pro_2_3_en.pdf。
- Apple:developer.apple.com `tutorials/data/documentation/realitykit/*.json`;WWDC23 10191、WWDC21 10076 页面。
- 厂商:rshelp.capturingreality.com、dev.epicgames.com(代理)、learn.poly.cam(Zendesk API)、kiriengine.app、nianticspatial.com、colmap.github.io、agisoft.freshdesk.com、patents.google.com。
