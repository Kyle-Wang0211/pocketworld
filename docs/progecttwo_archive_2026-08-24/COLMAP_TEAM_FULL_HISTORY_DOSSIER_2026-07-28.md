# COLMAP 团队全史档案(2014–2026.07)
**主题**:COLMAP 作者圈的一手记录 —— 增量 SfM 该怎么用/怎么调(尤其序列/视频输入)、作者自认的弱点与最佳实践。
**日期**:2026-07-28。**方法**:全部结论标注来源;[实锤] = 一手原文(论文/thesis/issue/PR/release/代码),[推断] = 由一手材料合理推出。引文均 ≤15 英文词。与既有 ETH-CVG 改装项目 dossier(hloc/PixSfM/GLOMAP/MP-SfM)互补,不重复其内容。

---

## 1. 人物志

### 1.1 Johannes Schönberger(GitHub: `ahojnnes`)—— 唯一核心
- 学术轨迹:UNC Chapel Hill(硕士,导师 Jan-Michael Frahm)→ ETH Zürich CVG 博士(导师 Marc Pollefeys;CVPR16 论文脚注 "This work was done at the University of North Carolina")→ 2018 年 thesis《Robust Methods for Accurate and Efficient 3D Modeling from Unstructured Imagery》(DOI 10.3929/ethz-b-000295763)。[实锤: demuc.de + 论文脚注 + ETH Research Collection]
- 工业轨迹:**6 年 Microsoft MR & AI Lab Principal Scientist**(≈2018–2024,Pollefeys 主持的苏黎世混合现实实验室;LaMAR 时期署名 Microsoft)→ **现任 Meta 苏黎世 Reality AI Research / Spatial AI 团队**。[实锤: demuc.de 自述]
- 奖项:ETH Medal(2019, thesis)、PAMI Mark Everingham Prize(2020, COLMAP)、ECVA Young Researcher Award(2023)。[实锤: demuc.de]
- GitHub 行为模式(用 gh API 实测):**2181 个 commit,是第 2 名的 9 倍**;逐年 commit 数 2023:137 → 2024:148 → 2025:295 → 2026(至7月):274 —— **2025 起活跃度翻倍,COLMAP 处于近十年最活跃期**。他本人写:核心数据结构(rigs/frames)、release 工程、性能优化、GUI;大型新功能(IMU、Caspar、GLOMAP 集成、检索)主要**审并merge 他人 PR**,review 风格:先问 benchmark、再问抽象("find a common abstraction",#4544)。[实锤: contributors/commits API]
- 社交媒体:个人网站只列 GitHub/Scholar/LinkedIn/Email,**未发现活跃 X/Twitter 账号**(见 §10 未找到)。
- 治理风格样本:2026-05 公开批评一位在十几个 issue 里刷广告的项目作者:"this doesn't meaningfully contribute to root causing and solving the issues"(#4376)。2026-02 起系统性清理陈年 issue(大量 "Closing as answered" 带官方结论,这批结论本身就是浓缩的官方口径,见 §4/§5)。[实锤]

### 1.2 核心圈(2023–2026 实际维护者,按 commit 排序,实测)
| 人 | GitHub | commit | 角色/负责面 |
|---|---|---|---|
| Johannes Schönberger | ahojnnes | 2181 | 唯一 BDFL;所有 release;核心重构 |
| **Shaohui Liu**(ETH CVG 博士生,GLOMAP 二作) | B1ueber2y | 235 | #2 维护者:IMU 预积分 PR、frames 实现(PR#2698)、Caspar 精度把关、ETH3D 回归 benchmark |
| **Paul-Edouard Sarlin**(ETH CVG→?) | sarlinpe | 123 | 检索/先验线:LocationPrior 重构(PR#2620)、GeoCalib 重力+内参(#4145)、gravity-only pose prior(PR#4447)、LaMAR 一作 |
| whuaegeanse | — | 36 | 中国社区工程贡献 |
| anmatako(Microsoft) | — | 25 | Microsoft 时期工程贡献 |
| Torsten Sattler | tsattler | 8 | commit 少但 issue 里长期答疑(尺度/已知位姿/BA 自由度);外部"精度良心" |
| Linfei Pan(GLOMAP 一作) | lpanaf | 11 | global mapper 线 |
| Maxime Ferrera | ferreram | 4 | **pose_prior_mapper 作者**(外部贡献者,PR#2660)[实锤;其单位为法国海洋所 Ifremer 系——推断,依据其 GitHub 关联] |
| tordnat(+ Skydio 工程师 emil-martens-skydio 参与测试) | — | 4 | **Caspar GPU BA 作者**(基于 SymForce/caspar) |
| Vincentqyw | — | — | ALIKED/LightGlue/检索(MixVPR/MegaLoc PR#4544)高产外部贡献者 |

- 顾问层:Frahm(UNC)、Pollefeys(ETH+前 Microsoft 苏黎世实验室主任,现 Meta?——Pollefeys 2024 年去向未单独核实,[推断]不影响本档案)。Sattler 现在 CTU Prague(CIIRC)。
- 组织事实:COLMAP 从个人项目变成**双人以上真核心团队**(ahojnnes+B1ueber2y+sarlinpe)是 2024 年后的事;GLOMAP 于 4.0.0 起 "maintained through the COLMAP repository going forward"。[实锤: 4.0.0 release notes]

---

## 2. 正史时间线(2014–2026)

- **2014–2015**(UNC 时期):PAIGE(CVPR15)、two-view geometry 分类(GCPR15)、Reconstructing the World in Six Days(CVPR15,Heinly 合作)——大规模无序照片是原始基因。[实锤: 论文列表]
- **2016-05**:GitHub 首批 issue(#10 已在答 KITTI 序列问题)。**CVPR16《Structure-from-Motion Revisited》**(Schönberger & Frahm)= COLMAP 增量 mapper 定义性论文;**ECCV16 Pixelwise View Selection**(Schönberger, Zheng, Frahm, Pollefeys)= MVS 部分。[实锤]
- **2017**:CVPR17《Comparative Evaluation of Hand-Crafted and Learned Local Features》(Schönberger, Hardmeier, Sattler, Pollefeys):结论 "advanced hand-crafted features still perform on par or better"(见 §3.6)。**2017-07:quadratic overlap 诞生**(#180,d6d2c21,为小基线视频发明,见 §4.2)。CVPR17 tutorial(夏威夷)+ 3DV16 tutorial(Stanford)。[实锤: thesis 13 章]
- **2018**:thesis 答辩;3.4→3.5;截至 2018 年中下载量 10 万+("downloaded more than 100,000 times",thesis)。入职 Microsoft。[实锤]
- **2019–2022**(Microsoft 低频维护期):3.6(2020)、3.7(2022)。研究线转隐私定位/LaMAR(ECCV22,AR 设备序列 + 激光扫描 GT,"pipeline robustly aligns the trajectories against laser scans")。[实锤]
- **2023**:3.8(2023-01,现代化 C++/CMake);ECVA 奖;活跃度回升(137 commits)。
- **2024**:3.9(01)、3.10(07);**PR#2620(2024-07,sarlinpe)LocationPrior 定型**;**PR#2660(2024-09-25 merge,ferreram)pose_prior_mapper**;**3.11.0(2024-11-28)**:pose prior mapper、PoseLib 最小求解器、BA 协方差、实验性 CUDA BA;修复 "sequential feature matcher overlap missing the farthest image. Broken since initial release."(!)。GLOMAP ECCV24 发表。[实锤: release notes]
- **2025**:PR#2698(frames,2025-02 merge,B1ueber2y);**3.12.0(2025-06-30)**:rigs/frames 数据模型落库(新表 rigs/rig_sensors/frames)、**FLANN→faiss**、绝对位姿改成图像域像素误差、RANSAC 停止准则修复(arXiv 2503.07829)、ETH3D/IMC/BlendedMVS 回归 benchmark 进 CI;**3.13.0(2025-11-07)**:`random_seed` 全流程确定性、静止点过滤(stationary point filtering in two-view geometry)、rig 约束几何验证、多 GPU 去全局锁。[实锤]
- **2026**:**4.0.0(2026-03-15)**:GLOMAP 一等公民(`global_mapper`)、ALIKED+LightGlue(ONNX)、EXIF 朝向自动转正、structure-less 注册兜底、OpenImageIO(I/O 2.5×)、BA 提速 10–15%(单 pose 参数块+解析 Jacobian);**4.1.0(2026-06-26)**:**Caspar GPU BA**(比 Ceres CUDA 快 1–2 个数量级)、球面(equirectangular)相机模型、EUCM、**EXIF 重力先验**、advancing-front 网格化、GlobalMapper track 上限/旋转平均选项;4.1.1(07-17)修 RANSAC 匹配 4–6× 减速回归。[实锤: release notes]

**一句话总史**:2014–2018 一个人为"无序互联网照片"写了标准答案 → 2019–2022 半休眠 → 2023–2026 以三人核心复兴,路线转向:**多传感器 rig/frames 数据模型 + 先验(GPS/重力/IMU)+ 全局管线(GLOMAP)+ GPU BA + 学习特征**。

---

## 3. 设计原理钩沉(门槛与取舍的作者原话)

### 3.1 为什么有这些"门"——总纲
- CVPR16 §2.2:"Without further refinement, SfM usually drifts quickly to a non-recoverable state." —— BA/过滤体系的存在理由就是 drift。[实锤]
- CVPR16 §3(挑战定义):失败 = "fail to register a large fraction of images" + "broken models due to mis-registrations or drift";根因一在 correspondence search 给出 "an incomplete scene graph",根因二在注册与三角化的鸡生蛋("symbiotic relationship")。[实锤]

### 3.2 三角化角度门(与 2-view tracks)
- CVPR16 §4.3/式(3):well-conditioned 三角化 = **足够的三角化角 α + 正深度(cheirality)** 两个条件;实验设 α=2°、t=8px、ε0=0.03。RANSAC 递归三角化就是为了 "feature tracks often contain a large number of outliers"(错误合并 4 条 track ⇒ 75% outlier)。[实锤]
- 过滤门(CVPR16 §4.4 Filtering / thesis §7.5.2):BA 后 "filter observations with large reprojection errors";逐点 "enforcing a minimum triangulation angle over all pairs of viewing rays"。代码默认(2026-07 main):`filter_max_reproj_error=4.0`、`filter_min_tri_angle=1.5`、triangulator `min_angle=1.5`、`create/continue_max_angle_error=2.0`、`merge/complete_max_reproj_error=4.0`、`re_max_angle_error=5.0`、**`ignore_two_view_tracks=true`(默认忽略 2-view)**。[实锤: incremental_mapper.h / incremental_triangulator.h]
- 2-view tracks 的官方松绑口径(已知位姿场景):ahojnnes 2026-02-19 在 #2899:"Try `--Mapper.tri_ignore_two_view_tracks 0 --Mapper.tri_min_angle 0.1`",并提醒 images.txt 必须给 "translations (t = -R * position)"。FAQ 增稠密点同款:勾掉 ignore_two_view_tracks + DSP-SIFT(estimate_affine_shape)+ guided_matching。[实锤]
- 初始化门(代码默认):`init_min_num_inliers=100`、`init_max_error=4.0`、**`init_max_forward_motion=0.95`(前向运动禁区)**、**`init_min_tri_angle=16.0`**、每图最多试 2 次。ahojnnes 2019(#568)亲自指路怎么改:"there should be a forward motion threshold on the z coordinate...Set it to 1 and also change the initial triangulation angle" —— 官方承认纯前向视频要动这两个门。[实锤]
- 初始对選择哲学(CVPR16 §2.2):"Initializing from a dense location...results in a more robust and accurate reconstruction";稀疏处起步只是省时间。[实锤]

### 3.3 BA 的取舍(对我们 finalize 直接相关)
- **thesis §7.5.1(论文里没有的細节)**:local BA 用 Cauchy loss,但 "global bundle adjustment does not use a robustifier in order to increase the convergence basin for drift correction" —— 全局 BA 不加鲁棒核是**有意为之**,为了让大 drift 能被拉回来。[实锤]
- 频率控制:local BA 每次注册后做在 "most-connected images";global BA 只在模型增长超过百分比后做(摊销线性)。[实锤: CVPR16 §4.4]
- RT+迭代精化:pre-BA 重三角化抗 drift(继承 VisualSFM),**post-BA RT 是 COLMAP 新增**("continuing the tracks of points that previously failed to triangulate...instead of increasing the triangulation thresholds");BA→RT→filter 迭代到过滤量收敛,"after the second iteration results improve dramatically"。[实锤: CVPR16 §4.4/thesis §7.5.3–7.5.4]
- 相机参数不设先验框:"we do not constrain the focal length and distortion parameters to an a priori fixed range",靠事后 bogus 检测过滤(`min/max_focal_length_ratio` 0.1/10、`max_extra_param=1`);主点 "ill-posed" 固定不动。[实锤]
- 退役史:PBA 后端因 CUDA12 在 3.9 移除;ahojnnes 2026-02 在 Caspar PR 里回忆:"we used to have support for PBA...also a significant gap in terms of accuracy...PBA also by default used single precision" —— **单精度 GPU BA 精度差是官方十年两次踩过的同一坑**。[实锤: #4018]

### 3.4 Next-best-view 与 redundant view mining
- NBV:多分辨率格子打分,"favor a more uniform distribution",因为 "a single bad decision may lead to a cascade of camera mis-registrations"。[实锤: CVPR16 §4.2]
- 场景图增强:WTF(watermark/timestamp/frame)对剔除;全景对(纯旋转)**禁止参与三角化**:"do not triangulate from panoramic image pairs to avoid degenerate...angles"。[实锤: CVPR16 §4.1]

### 3.5 尺度:官方铁口径
- BA 不可能恢复尺度:ahojnnes(#595, 2019/2026):"the scale...cannot be recovered without prior information",出口是 model_aligner 或 pose prior;tsattler(#670):BA 有整体 gauge 自由度 + normalize 步骤会动尺度(指出 incremental_mapper.cc 的 Normalize 调用)。#3410(2026 关闭语)同口径。[实锤]

### 3.6 特征选型的作者结论(CVPR17)
- "advanced hand-crafted features still perform on par or better than recent learned features"(在 3D 重建语境);学习特征 "a high variance across different datasets"。——DSP-SIFT 是该文优胜者之一;这与我们端上 DSP-SIFT 决策同源。2026 年官方态度演进:4.0.0 引入 ALIKED+LightGlue,且 ahojnnes 把 "vocabulary tree for ALIKED features" 列为 4.0 发布 blocker(#4018 评论)——[实锤];说明学习特征已进入官方主线,但 SIFT 仍是默认。[实锤+推断]

---

## 4. 视频/序列输入:作者的全部公开建议(1 手汇编)

### 4.1 官方采集与抽帧口径
- Tutorial(现行文档):"If you use a video as input, consider down-sampling the frame rate.";"each object is seen in at least 3 images";"Do not take images from the same location by only rotating";避免弱纹理/高动态范围。[实锤]
- ahojnnes #254(2017):**"Try skipping frames, eg, use only a frame every 1 or 2 seconds"** + "increase the size of the local bundle adjustment window"(视频 drift 两板斧)。[实锤]
- ahojnnes #388(2018,GoPro):走路速度 **"3-5 frames per second should be more than sufficient"**;共享内参**仅限定焦**("does the gopro do autofocus...Only in the latter case...shared intrinsics");广角用 OPENCV/OPENCV_FISHEYE,自标定失败就离线标定;避免运动模糊。[实锤]
- ahojnnes #10(2016,KITTI):"use sequential matching with loop detection";初始化失败→加大 overlap 或调低 Init 门;可手选初始对+固定标定。[实锤]

### 4.2 sequential matcher 的真实语义与历史
- 现行默认(main, pairing.h):`overlap=10`、**`quadratic_overlap=true`**、`loop_detection=false(默认关!)`、`loop_detection_period=10`、`loop_detection_num_images=50`、3.12 起新增 `expand_rig_images=true`(rig 内同帧+邻帧全配)。文件名必须字典序 = 时序(#2900 ahojnnes:"determined by the lexicographically order sequence of image names")。[实锤]
- quadratic overlap 出生证明(#180, 2017-07):被当 bug 上报后 ahojnnes 答:"This was an intended feature...better results...Especially, when the input is a video with small baseline",随即加开关。**动机 = 小基线视频需要指数间隔配对拉大基线**。[实锤](2024 重构把 additive 改互斥的考古见我们已有 quadratic 决策档,此处不重复。)
- **警示**:3.11.0 修复 "sequential feature matcher overlap missing the farthest image. Broken since initial release."——凡按 2014–2024 版本语义复刻 sequential 配对的实现,都继承了这个 off-by-one。[实锤]
- 回环:多段独立视频合并 → "enable loop closure"(#716);回环质量上限 ≠ SLAM:**"COLMAP probably detects the loops successfully but cannot optimize them as well as ORBSLAM"**,因为 ORB-SLAM 有 pose graph optimization,"better in correcting for large drift than pure bundle adjustment"(#254, 2017)——这是作者对"COLMAP vs SLAM"最直白的一次自我定位。[实锤]
- 回环可视化:GUI database 的 match matrix + "show image connections"(#3198, 2025)。[实锤]
- vocab tree:官方推荐用于 "large image collections (several thousands)";3.12 起 faiss 化+自动下载;4.x 方向是 MixVPR/MegaLoc 全局描述子(#4544,ahojnnes 要求先统一抽象再进)。[实锤]

### 4.3 "COLMAP 是否离线"的口径演变
- 2016–2019:issue 口径 = 与 SLAM 分工明确(#254、#568 "You might have to change the code for that")。文档从未写死 "offline only",但 tutorial 面向无序照片;[实锤]
- 2024–2026 演变:**没有任何官方 real-time/live 路线声明**;演变实际发生在旁路——pycolmap 开放 mapper 内循环(社区 COLMAP-SLAM 等自行搭)、3.13 确定性种子、4.1 Caspar 提速 "especially for the incremental mapper"。[实锤+推断:实时化仍靠外部项目,核心团队押的是"更快的离线"而非"在线"]

### 4.4 已知位姿/三角化管线(我们 finalize 的官方对照)
- 流程(#559, 2019):known poses 走 cameras/images/points3D 文本 + point_triangulator(数据库里的 pose 字段只喂 spatial_matcher);先 point_triangulator 再 bundle_adjuster 不会动尺度,跑 mapper 才会。[实锤]
- 少点诊断(#2899):tsattler:"either the poses or the camera intrinsics are not accurate enough";对 ARKit:"Arcore poses are typically not that accurate. I assume the same holds for Arkit."(2024-11)→ 放宽三角化/合并参数。[实锤]

---

## 5. 外部位姿先验与米制尺度全史

- **数据模型**:PR#2620(sarlinpe, 2024-07)删 `CamFromWorldPrior` 建 `LocationPrior`,**"it does not store any rotation, since this is not used anywhere in the code"** —— 位置-only 是"当时无人用旋转"的务实决定,非理论立场;预留坐标系(WGS84/ECEF/ENU/LV95)与后续精度/时间戳字段。[实锤]
- **pose_prior_mapper**:PR#2660(ferreram,2024-09-25 merge,入 3.11.0):PosePrior 进 Image、PositionPriorBundleAdjuster、**先验只进 global BA**;协方差从库读,`overwrite_priors_covariance` 可覆写;GPS/笛卡尔双支持,参考系取最小 image ID 的 GPS。sarlinpe review 时追问真实数据验证。[实锤]
- FAQ 现口径:EXIF GPS 在特征提取时自动写入 pose_priors 表;`--prior_position_std_x/y/z` 控不确定度。[实锤]
- **已知问题**:#3102(2025,open):NaN Jacobian、尺度漂移,"instability?" 未定论;#4332(2026,open):厘米级 RTK 用户求"锁死"平移先验,无维护者回应 —— **硬约束(fix)模式官方尚未提供**。[实锤]
- **旋转先验现状**:2026 前无;**4.1.0 添加 "extracting gravity pose priors from EXIF orientation tags"**;sarlinpe 连发 GeoCalib 集成(#4145,重力+内参估计,ahojnnes 催 ONNX 化)与 gravity-only prior 写库(PR#4447, 2026-06)。[实锤] → [推断] 旋转先验路线 = 重力(2-DoF)先行,全 3-DoF 旋转先验仍无时间表。
- **IMU**:PR#2561/#2625(B1ueber2y,2024 至今未 merge):On-manifold 预积分 + VI 优化,Aria 实测 scale≈1.001;**明确 gate 在 rig 支持后**:"no point to support IMU preintegration...without rig support";2026-03 深度重构完(解析 Jacobian、RK4、int64 时间戳),2026-07 仍在 review。对 ARKit 用户的直接答复:陀螺仪 rad/s 直接喂,噪声参数必须配对。[实锤]
- 尺度:见 §3.5;rig 配置化后 3.12.5 起支持 "metric scale recovery for configured rigs"。[实锤]

---

## 6. 作者自述弱点清单(不含第三方评论)

1. **弱纹理/反光/重复结构 = 承认的构造性失败面**:thesis Future Work:"current failure cases...such as textureless, reflective, or repetitive objects, require semantic reasoning to be reliably solved"。[实锤]
2. **drift 是增量法的宿命**:CVPR16 "drifts quickly to a non-recoverable state"(无精化时);缓解 = 频繁 BA + pre/post-BA RT + 迭代精化 + 回环。[实锤]
3. **Rolling shutter 至今未建模**(2017 #151 "COLMAP does not account for rolling shutter geometry";2018 #388 同口径;4.1.1 changelog 仍无 RS 条目)——手机/GoPro 视频快速运动的 drift 官方直接归因于此。[实锤]
4. **回环优化弱于 SLAM 的 pose graph**(#254,见 §4.2)。[实锤]
5. **纯前向运动初始化脆弱**(init forward motion 门 + #568 指导)。[实锤]
6. **尺度不可恢复**(§3.5)。[实锤]
7. **GPU/单精度 BA 有精度 gap**:PBA 史 + Caspar 实测(B1ueber2y:"caspar is still consistently behind in accuracy";ahojnnes 拍板:"not as the default backend unless we figure out how to close the accuracy gap";f64 定性更好、H100 上不慢)。[实锤: #4018]
8. **自标定退化**:全景/增强图片导致 bogus 内参,靠事后过滤(§3.3)。[实锤]
9. **ARKit/ARCore 位姿先验精度存疑**(tsattler, #2899)。[实锤]
10. Sattler 侧(pGT ICCV21, Brachmann/Humenberger/Rother/Sattler):COLMAP 伪 GT 不是绝对真值,"evaluation outcomes indeed vary with the choice of the reference algorithm";排名声明必须考虑参考算法类型。[实锤:摘要级]
11. GLOMAP 论文对增量法的定性:"costly repeated bundle adjustments" 限制可扩展性;GLOMAP 自身弱点 = "failure of rotation averaging...due to symmetric structures"(exhibition_hall 双方都挂)。[实锤]

---

## 7. 4.x/5.x 路线信号(团队现在把钱押在哪)

- **① 快**:Caspar(4.1 实验性,`-DCASPAR_ENABLED=ON`,增量 mapper 收益最大)+ Ceres CUDA/cuDSS + BA 参数块微优化(4.0 的 10–15%)。质量红线明确:默认后端不换,精度不让步(§6.7)。[实锤]
- **② 多传感器**:rigs/frames(3.12 落库)→ IMU(PR#2625 排队)→ 重力/GeoCalib(4.1/#4145)→ 全景/球面相机(4.1)。[实锤]
- **③ 全局化**:GLOMAP 进主仓一等公民 + GlobalMapper 持续加旋转平均/track 上限选项(4.1)。[实锤]
- **④ 学习组件入正门**:ALIKED+LightGlue(4.0)、MegaLoc/MixVPR 检索(#4544 in review)、GeoCalib;全部走 ONNX、可选、不动默认。[实锤]
- **⑤ 质量基建**:ETH3D/IMC/BlendedMVS 回归 benchmark 进 CI(3.12)、全管线确定性 random_seed(3.13)、静止点过滤(3.13)。[实锤]
- [推断] "5.x" 无公开提法;版本节奏(3.12→4.0→4.1 一年三大版)+ GLOMAP/Caspar 的吸收模式表明:**质量增益预期主要来自"先验+全局法+更多传感器",而不是继续调增量 mapper 的门**。

---

## 8. COLMAP 圈论 RealityCapture / 商业摄影测量

- thesis §1.2 把 RealityCapture/Pix4D/PhotoScan 定位为"基于研究界创新的商业化"("commercial software packages...released based on the aforementioned innovations")。[实锤]
- **Sattler 组一手对比**(WACV25, Burde, Benbihi, Burget, **Sattler**,对象级重建×位姿估计):RC "takes less than 1 min. on 25 images";"performance of RealityCapture remains stable when the number of images goes down";综合结论 "classical...can even offer a better reconstruction time-pose accuracy tradeoff"(相对学习法);RC 位姿 "slightly worse poses" vs BakedSDF。**注意:该文主要打的是 NeRF 系,不是 COLMAP vs RC 的正面精度对决**。[实锤]
- ETH3D 榜:**未找到 RealityCapture 官方提交**(§10)。Schönberger 本人 2014–2026 公开记录中**无任何直接评价 RC 的言论**(检索 issue/论文未命中)。[实锤:缺失本身]

---

## 9. 对我们的可行动差距(对照:on-device sequential ARKit-registered / DSP-SIFT 8192@4032 / K12+quadratic / 官方三角化留 2-view / RS 式出图 / 官方 finalize)

1. **回环是官方视频最佳实践的缺口,也是我们的缺口**。作者对视频的三板斧 = 抽帧、加大 local BA 窗、**sequential+loop detection**;我们已知缺 128/256/512 长程回环(quadratic 决策档)。4.x 方向(MegaLoc/MixVPR 单向量检索)提示:端上可用一个极小全局描述子 + 余弦近邻替代 vocab tree,成本远低于想象。[对策:把"每 N 帧检索 top-K 远程配对"列为 sparse preview RS-parity 的第一杠杆之一]
2. **quadratic 的官方动机与我们场景同构**:它就是为"小基线视频拉大基线"发明的(#180)。我们 K12+quadratic 抄的是正主;但注意 3.11 才修的 "missing the farthest image" off-by-one——**核对我们复刻的配对表是否含最远邻**。[对策:一次性 diff 我们的 pair 生成 vs 3.11+ 语义]
3. **2-view tracks:官方在 known-pose 场景亲口推荐打开**(#2899:`tri_ignore_two_view_tracks 0` + `tri_min_angle 0.1`)。我们"官方三角化+保留 2-view"的选择有作者背书;且官方连 `tri_min_angle` 都敢降到 0.1(比我们保守值激进得多)——说明官方认为 known-pose 下角度门可以大幅让位于覆盖。[对策:2-view 门后续扫参时,0.1–1.5° 区间有官方口径护身]
4. **全局 BA 不加鲁棒核的官方理由 = drift 修正收敛域**(thesis §7.5.1)。我们 ship CAUCHY@1.0(−9.6%)与官方默认相反;真机黄金基线已验证,但**大回环/大 drift 场景**(未来接回环后)需要重测:鲁棒核可能压制回环拉回。[对策:回环上线时,全局 BA 的 loss 选择重新过一遍对照]
5. **ARKit 先验路线与官方合流且我们更早**:官方 2024 位置-only(理由只是"没人用旋转")→ 2026 重力先验入库;先验只进 global BA、无硬锁模式、#3102 不稳定未决。我们的 ARKit 软先验 BA(含旋转)走在官方前面,没有现成官方参数可抄——**先验协方差设定是官方留白**,我们的标定就是一手工作。[对策:borrow `prior_position_std` 的接口形态,但数值自测]
6. **速度差距的合法化**:官方阵营自己给出 "RC 快且少图稳,但位姿略差";加上 Caspar "1–2 个数量级"与 f32 精度 gap 的公开实验——**"快"与"位姿准"在官方语境里是显式 tradeoff**。RS-parity 的正确姿势是比覆盖/稳定,不必在速度上硬追 RC。
7. **Rolling shutter 盲区**:官方从未修;我们静态拍照(短曝光/低速)天然规避,这是我们相对"视频流派"复刻者的结构性优势,值得写进产品叙事。
8. **确定性**:3.13 的 `random_seed` 全管线确定性 + 3.13 静止点过滤,与我们的 byte-parity 验证文化同向;若未来升 vendored 版本,3.13 的确定性开关能把 cap3 "逐跑不复现" 类问题变成可复现实验。[对策:vendored 升级评估时把 random_seed 列为头号收益]

---

## 10. 未找到清单(检索过但无一手命中)

- Schönberger 的 X/Twitter 账号/推文(个人站不列;多轮检索无);任何播客/访谈/口述史。
- 2024–2026 的公开演讲视频(3DV/CVPR keynote 级;只确认 2016/2017 两个 tutorial 与 2023 ECVA 奖本身)。
- Microsoft 时期关于"实时/序列 SfM"的公开技术声明(LaMAR 之外;Azure Spatial Anchors 无 COLMAP 关联的一手材料)。
- ETH3D 榜上的 RealityCapture 提交;Sattler 对 RC 的直接社媒评论。
- "COLMAP is offline-only" 的官方文档原句(不存在;口径只存在于 issue 答复)。
- 全 3-DoF 旋转先验/pose prior 硬锁(fix)模式的路线声明。
- thesis 中未发现超出 CVPR16 的"门参数数值推导"(门的具体数值在代码而非文献;thesis 增量是 §7.5.1 无鲁棒核理由与 §14 失败面自述)。
- pose_prior_mapper 在 local BA 中使用先验的计划(现状仅 global BA)。

---
*来源索引:colmap/colmap issues #10 #151 #180 #254 #388 #479 #530 #559 #568 #595 #670 #716 #1235 #1916 #2561 #2620 #2625 #2660 #2698 #2899 #2900 #3102 #3163 #3198 #3329 #3410 #4018 #4145 #4332 #4376 #4447 #4544;releases 3.8–4.1.1;src/colmap/{sfm,controllers}/*.h(main@2026-07);CVPR16 SfM Revisited 原文;ETH thesis(ethz-b-000295763)全文;CVPR17 features 原文;colmap.github.io tutorial/faq/changelog;demuc.de;GLOMAP arXiv 2407.20219;pGT arXiv 2109.00524;WACV25 arXiv 2408.08234;lamar.ethz.ch。*
