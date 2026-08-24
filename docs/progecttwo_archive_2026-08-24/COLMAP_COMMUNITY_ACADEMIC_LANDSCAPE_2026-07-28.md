# COLMAP 社区/学术改造版图 — 面向端上顺序采集的两大目标
**日期**:2026-07-28 · **目标**:①稀疏云出生期少鬼点/飞点 ②数百帧顺序采集的位姿精度(零鬼影/双面容忍)
**我方基线**:vendored COLMAP 4.0.4,ARKit 位姿直接注册(无 PnP、BA 无 prior)、DSP-SIFT GPU + RootSIFT、K12 时序窗 + 官方 quadratic 长程配对、finalize = 官方 IterativeGlobalRefinement×5 + 官方过滤。
**已判死/已有,不再推荐**:事后鬼点清算(≤4% 天花板)、阈值联合扫(拓扑天花板)、detector-free 前端(弱纹理线另存)、GLOMAP 整体换血(我们选定 incremental)、外部 BA 库、PixSfM/APD-MVS 已在路线图(本文只补证据与排位)。

---

## TL;DR

1. **社区"COLMAP 高手圈"高度集中在 ETH CVG(Sarlin/Lindenberger/Pan/Barath/Schönberger)**,他们的改法全部是"换前端 + 在三角化/BA 内加残差",而不是调官方阈值;视频/顺序采集的社区民间定式 = sequential matcher + overlap≈10 + vocab tree 周期性回环 + 更勤的 global BA + 帧清晰度预筛(sharp-frames)。
2. **出生期鬼点**:学术界的真答案有三条——featuremetric 亚像素(PixSfM,SIFT 位姿 AUC@1cm 55.4→60.5)、单目先验进 BA(MP-SfM,专治低视差,正中我们双墙病理)、不确定度门(Polic USfM 系)。3DGS 社区基本全靠事后手工/SuperSplat 清,出生期基本没有 lore,反而印证我们"出生期治理"方向是对的。
3. **数百帧位姿**:COLMAP 官方 pose_prior_mapper 只有 position-only prior 且**从未发表过量化收益**;真正有published 证据的是 (a) 重力先验进旋转平均(ECCV 2024,+13 AUC@1°,代码已在 colmap/glomap,BSD-3)——ARKit 每帧就有重力,这是白捡的;(b) 摄影测量学几十年的 GNSS-assisted BA 文献证明"位置先验进 BA 消走廊漂移/碗形变形"。6-DoF 全旋转先验 BA 的开源主线实现:未找到(COLMAP 只到 position+gravity)。
4. **Top-5 刀**(详见 §5):重力先验旋转平均混合精化 > ARKit 位置先验进 global BA > ARKit 深度门治低视差出生 > PixSfM-KA(蒸馏版)> sequential 内建 vocab-tree 回环。全部是质量改动,须走矩阵验收;无一是 EXACT。

---

## Q1 · 社区 power-users 与 fork:他们改了什么、为什么

### 1.1 ETH CVG 系(事实上的 COLMAP 改装中心)
- **hloc(Sarlin)**:把 stock COLMAP 的 SIFT+暴力/词树检索整套换成 SuperPoint/NetVLAD 检索 + SuperGlue,再用 COLMAP 做三角化与 BA——理念是"COLMAP 的几何后端是对的,错的是前端匹配"。Apache-2.0(已核 LICENSE)。[repo](https://github.com/cvg/Hierarchical-Localization)
- **PixSfM(Lindenberger)**:不换后端,在匹配后/BA 后各加一层 featuremetric 优化(见 §2.1)。Apache-2.0(已核)。[repo](https://github.com/cvg/pixel-perfect-sfm)
- **glue-factory**:训练/评测匹配器的框架(LightGlue 等),本身不改 COLMAP internals。Apache-2.0(已核)。[repo](https://github.com/cvg/glue-factory)
- **GLOMAP(Pan/Barath/Pollefeys/Schönberger)**:把"翻译平均"换成"global positioning(相机位置与 3D 点联合估计)",精度与 COLMAP 持平或更好、快 1-2 个数量级;论文自己承认顺序/近共线前进运动是传统平移平均的退化场景,这正是他们改 global positioning 的动机。BSD-3(已核)。[paper](https://arxiv.org/pdf/2407.20219) [repo](https://github.com/colmap/glomap) [解读](https://www.emergentmind.com/topics/glomap)。⚠️ GLOMAP 自己的 issue 也记录了环形轨迹上 COLMAP incremental 回环失败的病例:[glomap#180](https://github.com/colmap/glomap/issues/180)
- **sfm-disambiguation-colmap**:对称/重复结构消歧(Yan 2017 / Cui 2015 思路)预过滤 matches 而非事后修模型——同一"出生期优于事后"哲学。⚠️ **仓库无 LICENSE 文件(已核,API 返回 NONE)= 默认不可商用,只能借鉴思想**。[repo](https://github.com/cvg/sfm-disambiguation-colmap)

### 1.2 视频/顺序采集的社区民间定式(folklore + 出处)
- **官方口径**:视频用 sequential matcher;overlap≈10 已能给出每对 400-1000 匹配;回环靠 `SequentialMatching.loop_detection`(vocab tree 周期性触发)。[COLMAP tutorial](https://colmap.github.io/tutorial.html) [FAQ](https://colmap.github.io/faq.html) [sequential 语义 issue#2759](https://github.com/colmap/colmap/issues/2759)
- **手工回环 folklore**(多段视频合并场景):对回环索引 i,j,按 `i±2^l × j±2^m, (l,m)∈[0,5]²` 加配对——即官方 quadratic 思路的双边版。[issue#716](https://github.com/colmap/colmap/issues/716)
- **更勤的 global BA 抗漂移**:`ba_global_images_ratio/ba_global_points_ratio` 从默认 1.1(大集合建议 1.2)往下调 = 更频繁全局 BA、更少漂移、更多算力,社区当作视频序列的标准旋钮。[issue#2572](https://github.com/colmap/colmap/issues/2572) [DeepWiki 汇总](https://deepwiki.com/colmap/colmap/8-pose-estimation-and-bundle-adjustment)
- **nerfstudio/3DGS 预处理 lore**:ns-process-data 视频默认走 COLMAP sequential/vocab_tree;COLMAP 3.12+ 词树从 FLANN 迁到 faiss(旧树要 `vocab_tree_upgrader`)。[nerfstudio#3664](https://github.com/nerfstudio-project/nerfstudio/issues/3664) [nerfstudio#1377](https://github.com/nerfstudio-project/nerfstudio/issues/1377)
- **实践者派(Jonathan Stephens / Reflct)**:帧选择先于一切——锐度打分抽帧(batched selection + 邻域离群剔除),模糊帧是 floater 的第一来源。工具 [Reflct sharp-frames-python](https://github.com/Reflct/sharp-frames-python)(⚠️自定义 license,API 返回 NOASSERTION,商用前须逐字读)、[报道](https://radiancefields.com/reflct-sharp-frame-selector);Stephens 的 3DGS 数据集教程被官方 3DGS 仓 README 引用:[graphdeco-inria/gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting)。
- **3DGS 社区清 floater 的主流做法是事后的**:SuperSplat/网页版 COLMAP 编辑器手工框选删除。[3DGS 学生指南](https://medium.com/@Jamesroha/gaussian-splatting-a-complete-student-guide-to-3d-capture-in-2026-1195a6265870) [colmap-editor](https://www.3dgsviewers.com/colmap-editor/help)。**结论:出生期治理在社区层面是空白,我们不落后。**
- **Agisoft vs COLMAP 对照**:综述类结论 = COLMAP 大数据集位姿更准但更慢;Metashape 在部分室内/复杂场景成功率更高。[MVS 方法对照综述](https://arxiv.org/html/2604.10246v1) [珊瑚礁重建对照](https://arxiv.org/pdf/2502.20154)。对我们无直接可抄参数。
- **XRLocalization(OpenXRLab)**:hloc 同范式的定位工具箱,Apache-2.0(已核),对 COLMAP internals 无修改,略。[repo](https://github.com/openxrlab/xrlocalization)

### 1.3 上游 COLMAP 4.x 自身的相关演进(我们停在 4.0.4)
[CHANGELOG](https://github.com/colmap/colmap/blob/main/CHANGELOG.rst) / [Releases](https://github.com/colmap/colmap/releases/tag/4.1.0):
- **4.0.0(2026-03)**:GLOMAP 并入为 GlobalMapper;pose priors 泛化为"传感器测量"并加**重力先验**(EXIF);ALIKED+LightGlue 进主线;Ceres 单 pose 参数块 +10%。
- **4.1.0(2026-06)**:Caspar GPU BA(比 Ceres CUDA 后端快 1-2 个数量级,⚠️CUDA 向,端上无关);**旋转平均加抗 180° 翻转鲁棒化与重力选项**;`GlobalMapper.keep_max_num_tracks`(track 精选);**修复 sequential matching + loop detection 挂死**;增量三角化 BFS 分配复用提速。
- **4.1.1(2026-07)**:修 RANSAC 里 OpenMP 全局临界区导致的匹配 4-6× 减速。
**注**:若上重力/旋转平均的刀,升级到 ≥4.1 或 cherry-pick 是前置工程项。

---

## Q2 · 出生期减鬼点/飞点(非事后)

### 2.1 Featuremetric 亚像素:PixSfM(ICCV 2021 最佳学生论文)
- 两级:**KA(keypoint adjustment)**在任何几何估计前用稠密特征(S2DNet)把互相匹配的 2D 关键点拉齐;**BA 级** featuremetric 精化点+位姿。[paper](https://arxiv.org/pdf/2108.08291) [repo](https://github.com/cvg/pixel-perfect-sfm)
- **量化证据(ETH3D)**:三角化 accuracy@2cm 室内 87.77%→94.09%(SuperPoint);位姿 AUC@1cm SIFT 55.39→60.47、SuperPoint 63.41→73.86。KA 阶段的 track 参考点选择规则:"选连接度最高的点",BA 阶段"选特征空间 robust mean 最近的点"——即成体系的 track 质量治理。
- **代价**:稠密特征抽取需 GPU,大场景缓存到盘(Aachen 7k 图 ≈350GB);有 low_memory 模式(稀疏 patch + 分块)。绑定 COLMAP 3.8 源码编译,移植到我们 4.0.4 是真工程。Apache-2.0(已核)。
- **对我们**:S2DNet 可换成任意稠密特征(论文声明对 off-the-shelf 特征均有效);端上做法是"KA-only + 小蒸馏网络 + CoreML",BA 级可只在 finalize 跑。

### 2.2 学习型亚像素偏移:keypt2subpx(ECCV 2024)
- 轻量模块给任意检测器学一个亚像素 offset,+~7ms;**只支持 SuperPoint/ALIKED/DeDoDe/XFeat,不支持 SIFT**;需要 descriptor(256d)+(部分)稠密 score map。Apache-2.0(已核)。[paper](https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/10082.pdf) [repo](https://github.com/KimSinjeong/keypt2subpx)
- **对我们**:DSP-SIFT 本身已有亚像素定位,此刀只在未来 XFeat/学习型前端线上有意义。README 无 SfM/COLMAP 集成、无表格数字——证据薄,排位靠后。
- 同类:XRefine(Bosch 2026,attention 匹配精化)⚠️ **AGPL-3.0(已核)= 商用禁区**。[repo](https://github.com/boschresearch/xrefine)

### 2.3 单目先验进管线:MP-SfM(CVPR 2025, ETH CVG)——正中我们双墙病理
- 在 COLMAP 式增量管线(基于其 pycolmap fork)里加:单目 depth+normal 先验残差进 BA、**depth-consistency 检查**、**带不确定度传播的三角化**;明确主打 **low-parallax / low-overlap / 高对称**场景,在 ETH3D/SMERF/RealEstate10k/T&T 上超 COLMAP、GLOMAP、MASt3R-SfM。[paper](https://arxiv.org/pdf/2504.20040) [repo](https://github.com/cvg/mpsfm)(Apache-2.0,已核)[官方页](https://opencv.org/mp-sfm/)
- **代价**:默认 Metric3Dv2-Giant2 / DepthPro 级别的大网——端上直接跑不现实。
- **对我们的转译**:先验不必来自大网——**ARKit sceneDepth/LiDAR 就是免费的 metric depth 先验**。ScanNet++ 用同思想做门:iPhone 深度 vs 激光渲染深度差 >0.3m 即拒(见 §4.2)。把"ARKit 深度 vs 三角化深度一致性"做成**出生门/降权**,专杀 5.2° 低视差深度噪声壳,是本次调研最贴我们病理的刀。
- 同宗:StudioSfM/Depth-Guided SfM(CVPR 2022,影视小视差视频,深度先验参与两视图初始化+深度正则化注册)证明小视差顺序帧上深度先验路线有效;公开代码未找到。[paper](https://openaccess.thecvf.com/content/CVPR2022/papers/Liu_Depth-Guided_Sparse_Structure-From-Motion_for_Movies_and_TV_Shows_CVPR_2022_paper.pdf)

### 2.4 Track 质量门与不确定度门
- 上游新增 `GlobalMapper.keep_max_num_tracks`(track 精选进主线,4.1.0)[release](https://github.com/colmap/colmap/releases/tag/4.1.0);track selection 加速 BA 的近作 [SPIE 2024](https://www.spiedigitallibrary.org/conference-proceedings-of-spie/13256/132560U/A-fast-bundle-adjustment-method-based-on-track-selection/10.1117/12.3038009.short);经典"学习选长 track"[ECCV-W 2016](https://link.springer.com/chapter/10.1007/978-3-319-45886-1_33)。
- **不确定度门(CTU Polic 系)**:大规模 SfM 的相机/点协方差可在几十秒内精确算完(稀疏传播,~10×加速)[ECCV 2018](https://www.ecva.net/papers/eccv_2018/papers_ECCV/papers/Michal_Polic_Fast_and_Precise_ECCV_2018_paper.pdf)——理论上可做"出生即按协方差门/降权"。⚠️ 参考实现 michalpolic/usfm **无 LICENSE(已核)**,只能借思想自写。与我们已判死的"事后清算天花板"不同:这是把 σ_depth 观测粒度显式化,但注意我们 E2-E11 已证事后过滤 ≤4%——此刀只有做进 birth 才有增量,证据薄,需自证。
- 3DGS 侧出生期基本无 lore(见 §1.2),唯一普适共识 = min track length / reprojection / min_tri_angle 三件套,我们已扫过并撞拓扑天花板。

---

## Q3 · 数百帧顺序采集的位姿精度

### 3.1 (a) 增量漂移与混合/全局精化
- **漂移病理**:顺序近共线运动下,传统平移平均尺度漂移无解,GLOMAP 论文明确指认并以 global positioning 绕开(§1.1);增量线的对策是更勤 global BA(§1.2)与回环。
- **混合范式先例**:HSfM(CVPR 2017)= 全局旋转平均 + 增量位置估计,证明"旋转全局解、平移增量解"可同时要鲁棒与精度。[paper](https://openaccess.thecvf.com/content_cvpr_2017/papers/Cui_HSfM_Hybrid_Structure-from-Motion_CVPR_2017_paper.pdf)
- **对我们**:不必换 GLOMAP——**把旋转平均当"finalize 里的一次全局精化 pass"**(读入现有 view graph 两视几何 → RA → 回填 → 官方 BA 收尾),GlobalMapper 已在我们同宗的 4.0 里,BSD-3、纯 C++/Ceres、无 CUDA。这是"incremental 为主、全局做精化"的混合,不违背我们对 GLOMAP 的既有裁决。
- 辅证:延长特征(线/消失点)抗漂移 [arXiv 2008.12295](https://arxiv.org/pdf/2008.12295);LiMAP 线建图(ETH,BSD-3 已核)[repo](https://github.com/cvg/limap)——重、端上不推荐,仅记档。

### 3.2 (b) 外部先验(ARKit/VIO)进 BA——published 证据审计
- **COLMAP 官方现状**:pose_prior_mapper([PR#2660](https://github.com/colmap/colmap/pull/2660))= **position-only** 先验、只进 global BA、逐轴 std 构造协方差、可加 robust loss;**PR 内无任何量化精度对比**(作者只给了合成数据测试与一个 UAV 数据链接)——"官方先验帮多少"在 COLMAP 语境下是未发表状态。硬锁平移(constant translation)至今不支持:[issue#4332](https://github.com/colmap/colmap/issues/4332)。
- **4.0 起的增量**:先验泛化 + **重力先验**;4.1 旋转平均支持重力。[CHANGELOG](https://github.com/colmap/colmap/blob/main/CHANGELOG.rst)
- **旋转先验的真证据**:Gravity-aligned Rotation Averaging(ECCV 2024,Pan/Pollefeys/Barath):重力把 RA 从 3-DoF 降到 1-DoF(circular regression,支持部分帧无重力的分层求解),**比 SfM 基线平均 +13 AUC@1° 且快 8×,比平面 pose graph 优化 +23 AUC@1°**;代码并入 colmap/glomap。[paper](https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/05651.pdf) [repo](https://github.com/colmap/glomap) [示例 issue#173](https://github.com/colmap/glomap/issues/173)。**ARKit 每帧免费给重力方向——这是我们独有而通用管线没有的输入。**
- **位置先验的真证据(摄影测量文献,几十年成熟)**:GNSS-assisted BA 消长走廊漂移与"碗形/穹顶"系统误差是行业定论:[Sensors 2018 走廊制图](https://doi.org/10.3390/s18092783)、[Remote Sens. 2021 弱结构长走廊自标定+GNSS 约束 BA](https://www.mdpi.com/2072-4292/13/21/4222)。类比成立的条件:先验误差特性(GNSS 绝对小误差 vs ARKit VIO 相对漂移)不同,**协方差必须按 VIO 漂移建模(随距离/时间膨胀),否则先验会把 BA 往 ARKit 自己的漂移上拉**——这是必须自证的点。
- **全 6-DoF(含旋转)先验 BA 的开源主线实现:未找到**(COLMAP 只有 position+gravity;完整 6-DoF prior 因子常见于 VI-mapping 框架而非 SfM 主线)。近例:多相机 VINS 轨迹作 COLMAP 先验的系统论文 [arXiv 2412.04287](https://arxiv.org/html/2412.04287)(用于空间配对与全局 BA 约束)。
- **裁决口径**:published 证据支持的是"**priors-in-BA(位置软先验+重力进 RA)优于纯无先验精化**"这个方向(GNSS 文献 + ECCV24 重力 RA),但**没有任何论文直接测过"ARKit 先验进 BA vs ARKit 仅作初值"这一对照**——该对照要我们自己拿矩阵打(cap 序列 A/B,双墙率+重投影+与激光/已知几何对距)。

### 3.3 (c) 回环:quadratic 之外
- COLMAP sequential matcher 内建 `loop_detection`:每隔 loop_detection_period 帧用 vocab tree 检索候选并匹配——即"周期性回环"官方实现;3.12+ 词树基于 faiss(MIT);4.1.0 修复了 loop_detection 挂死。[tutorial](https://colmap.github.io/tutorial.html) [nerfstudio#3664](https://github.com/nerfstudio-project/nerfstudio/issues/3664) [release 4.1.0](https://github.com/colmap/colmap/releases/tag/4.1.0)
- **端上成本/收益的 published 数据:未找到**(词树体积、faiss 检索在 A16 上的耗时、以及"我们的绕物采集是否真有长程回环可闭"都要自测)。我们已知缺 128/256/512 长程配对(记忆库),此刀是对症的、但证据自建。
- 环形轨迹上 incremental 回环失败病例:[glomap#180](https://github.com/colmap/glomap/issues/180)——若自测,先用环绕采集复现此病理再谈收益。

---

## Q4 · 高校/大厂改 COLMAP internals 的清单(2023-2026 为主)

| 机构 | 工作 | 改了什么 internals | License |
|---|---|---|---|
| ETH CVG | PixSfM / GLOMAP / 重力RA / MP-SfM / sfm-disambiguation / LiMAP | KA+featuremetric BA;global positioning 取代平移平均;RA 降维;深度/法线残差+不确定度三角化;match 预过滤;线 track | Apache-2.0 / BSD-3 / BSD-3 / Apache-2.0 / **无LICENSE** / BSD-3(均已核) |
| TUM(Angela Dai 组) | [ScanNet++](https://arxiv.org/pdf/2308.11417) | 激光扫描渲染伪图并入 COLMAP SfM 定 metric 尺度;稠密光度误差精化位姿;**iPhone 帧按"LiDAR深度 vs 激光深度差>0.3m"剔除**([文档](https://scannetpp.mlsg.cit.tum.de/scannetpp/documentation)) | 数据协议,管线思想可抄 |
| CTU Prague(Polic/Pajdla) | [协方差快算](https://www.ecva.net/papers/eccv_2018/papers_ECCV/papers/Michal_Polic_Fast_and_Precise_ECCV_2018_paper.pdf) / [不确定度选相机模型](https://openaccess.thecvf.com/content_CVPR_2020/papers/Polic_Uncertainty_Based_Camera_Model_Selection_CVPR_2020_paper.pdf) | SfM 不确定度传播提速 ~10×;按不确定度选 camera model | 参考代码无 LICENSE(已核) |
| NAVER LABS | [kapture / kapture-localization](https://github.com/naver/kapture)(BSD-3 已核) | 数据管道包 stock COLMAP,internals 未改;**MASt3R/MASt3R-SfM 为 NC 系(CC BY-NC-SA),商用禁区** | BSD-3 / ⚠️NC |
| Microsoft + ETH | [LaMAR](https://lamar.ethz.ch/files/LaMAR.pdf)([repo](https://github.com/microsoft/lamar-benchmark)) | AR 设备(HoloLens/iPhone)VIO 轨迹 + COLMAP 式管线对激光真值自动配准的 GT 流水线;"VIO 段内刚性、段间配准"的范式对 ARKit 序列极具参考 | 仓库标 CC-BY-4.0(已核,代码用途须细读) |
| Meta Reality Labs | [projectaria_tools](https://github.com/facebookresearch/projectaria_tools)(Apache-2.0 已核) | MPS(闭源云服务)出 SLAM 位姿供离线用;**公开"修改 COLMAP internals"论文:未找到** | Apache-2.0(工具) |
| ZJU zju3dv | [DetectorFreeSfM](https://github.com/zju3dv/DetectorFreeSfM)(Apache-2.0 已核,CVPR 2024) | 量化 detector-free 匹配出粗模 → attention 多视图 track 精化 + 几何精化迭代(IMC2023 冠军) | Apache-2.0 |
| Netflix/Amazon | [StudioSfM](https://arxiv.org/abs/2204.02509)(CVPR 2022) | 深度先验进两视图初始化+注册正则(小视差影视视频) | 代码未找到 |
| NVIDIA | [cuSfM](https://arxiv.org/pdf/2510.15271) | CUDA 加速 SfM | ⚠️CUDA-only,违反跨端约束 |

---

## Q5 · 五刀终审排位

评分维度:目标命中(鬼点/位姿)× 端上可行 × license × 与"ARKit 直注册"架构兼容。**全部为质量改动,无 EXACT;逐刀标注 NOISE-BAND(期望落噪声带内的中性重构)或 SIGNED(有向质量变化,须矩阵签收)。**

### 🥇 刀1:ARKit 重力 → 1-DoF 重力对齐旋转平均,作 finalize 前的全局旋转精化 pass
- **改什么**:finalize 时从 two-view geometry 图跑 gravity-aligned RA(colmap/glomap 已实现,BSD-3),回填帧旋转,再走官方 IterativeGlobalRefinement。旋转全局一致化 → 平移/结构在 BA 中随之收敛,直接打数百帧旋转漂移。
- **证据**:ECCV 2024 平均 **+13 AUC@1°、快 8×**,对部分帧缺重力也有分层解([paper](https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/05651.pdf));GLOMAP 主线代码即含([repo](https://github.com/colmap/glomap))。
- **类别**:SIGNED(位姿变化有向)。**工期:4-7 天**(含从 4.1 cherry-pick RA 模块 + ARKit 重力接线 + 矩阵)。
- **须自证**:我们的 ARKit 初值已很好,RA 增量可能被 BA 吸收——A/B 打双墙率与长序列端点闭合误差。

### 🥈 刀2:ARKit 位置(+重力)软先验进 global BA(covariance 按 VIO 漂移建模)
- **改什么**:vendored 4.0.4 已含 pose_prior 机制(PR#2660 血统):给每帧 ARKit 平移加 covariance 加权残差 + Cauchy,协方差随"距上次 BA 锚点的行进距离"膨胀,只进 IterativeGlobalRefinement 的 global BA。
- **证据**:GNSS-assisted BA 消走廊漂移/碗形是摄影测量定论([Sensors 2018](https://doi.org/10.3390/s18092783)、[RS 2021](https://www.mdpi.com/2072-4292/13/21/4222));⚠️ COLMAP 自家 PR **零量化数据**([PR#2660](https://github.com/colmap/colmap/pull/2660))、"ARKit 先验 vs 仅初值"的直接对照**全网未找到**——证据最薄的高潜力刀,必须自建矩阵。
- **类别**:SIGNED。**工期:2-4 天**(机制在库,主要是协方差模型与验收)。
- **风险**:协方差错标会把 BA 拉向 ARKit 自身漂移;须与刀1 分开控变量。

### 🥉 刀3:ARKit 深度一致性出生门(MP-SfM/ScanNet++ 思想的零网络版)——专杀双墙
- **改什么**:三角化出生时(及 retriangulation),比较三角化深度 vs ARKit sceneDepth/LiDAR 深度;低视差观测(<某视差角)且深度差超阈 → 拒生或按深度先验降权。这是把我们"5.2° 低视差深度噪声壳"病理在出生处截断,而非事后清算(不撞 ≤4% 天花板)。
- **证据**:MP-SfM 证明深度先验进 BA/三角化在 low-parallax 场景全面超 COLMAP([paper](https://arxiv.org/pdf/2504.20040),Apache-2.0);ScanNet++ 用 0.3m 深度差门剔不可靠 iPhone 帧([文档](https://scannetpp.mlsg.cit.tum.de/scannetpp/documentation));StudioSfM 证明小视差视频线([paper](https://arxiv.org/abs/2204.02509))。⚠️ 三者都不是"ARKit 深度做出生门"的直接实测——组合创新,须自证;且 ARKit 深度 4m 外不可靠,门须带距离衰减。
- **类别**:SIGNED-LOSSY 倾向(点数会降,换鬼层下降;按签决文化须用户签)。**工期:5-8 天**。

### 4️⃣ 刀4:PixSfM 式 featuremetric KA(蒸馏小网,只做匹配后 2D 拉齐)
- **改什么**:匹配后、三角化前,用小蒸馏稠密特征(CoreML/WGSL)做 KA 把 track 内 2D 点亚像素对齐——出生即更干净的 track,σ_depth 地板整体下移。
- **证据**:ETH3D 三角化 accuracy@2cm 87.77→94.09%、SIFT 位姿 AUC@1cm +5.1([paper](https://arxiv.org/pdf/2108.08291),Apache-2.0 已核)。**社区公认、数字最硬的出生期精度刀。**
- **代价**:S2DNet 级稠密特征端上太重,须蒸馏+热预算评审;绑 COLMAP 3.8 的实现要移植到 4.0.4。**工期:10-20 天**,本清单最贵。已在我们路线图,本次调研确认其证据等级最高但应排在刀1-3 之后。
- **类别**:SIGNED。

### 5️⃣ 刀5:sequential matcher 内建 vocab-tree 周期回环(补 128/256/512 长程)
- **改什么**:开 `SequentialMatching.loop_detection`(faiss 词树,周期检索+匹配),或按 [issue#716](https://github.com/colmap/colmap/issues/716) 的 `2^l×2^m` 双边配对手工补长程——补齐我们已知缺失的长程回环配对。
- **证据**:官方机制([tutorial](https://colmap.github.io/tutorial.html));**端上成本与收益数据未找到**,且我们绕物采集是否存在可闭长环未知——最便宜也最不确定的刀。⚠️ 4.0.4 需确认已含 4.1.0 的 loop_detection 挂死修复([release](https://github.com/colmap/colmap/releases/tag/4.1.0))。
- **类别**:配对集合变化→SIGNED(点/位姿都会动)。**工期:1-2 天试跑 + 词树体积/耗时实测**。

**落选记档**:keypt2subpx(不支持 SIFT,留给 XFeat 线,Apache-2.0)、USfM 不确定度门(无 LICENSE、且逼近事后清算天花板)、GLOMAP 整体替换(既有裁决)、XRefine(AGPL)、MASt3R 系(NC)、cuSfM(CUDA-only)、LiMAP(端上过重)、sharp-frames(我们拍照非抽帧,思想已覆盖:模糊帧门)。

---

## 附:License 审计表(逐仓 API 核验,2026-07-28)

| 仓库 | SPDX | 商用 |
|---|---|---|
| cvg/pixel-perfect-sfm | Apache-2.0 | ✅ |
| cvg/mpsfm | Apache-2.0 | ✅ |
| cvg/Hierarchical-Localization | Apache-2.0 | ✅ |
| cvg/glue-factory | Apache-2.0 | ✅ |
| colmap/glomap | BSD-3-Clause | ✅ |
| cvg/limap | BSD-3-Clause | ✅ |
| naver/kapture, kapture-localization | BSD-3-Clause | ✅ |
| KimSinjeong/keypt2subpx | Apache-2.0 | ✅ |
| zju3dv/DetectorFreeSfM | Apache-2.0 | ✅ |
| zju3dv/EfficientLoFTR | Apache-2.0 | ✅ |
| openxrlab/xrlocalization | Apache-2.0 | ✅ |
| facebookresearch/projectaria_tools | Apache-2.0 | ✅(MPS 服务闭源) |
| colmap/colmap | 自定义 BSD 系(API NOASSERTION) | ✅(既有审计) |
| microsoft/lamar-benchmark | CC-BY-4.0 | ⚠️代码用途须细读 |
| Reflct/sharp-frames-python | NOASSERTION(自定义) | ⚠️须逐字读 |
| cvg/sfm-disambiguation-colmap | 无 LICENSE | ❌只借思想 |
| michalpolic/usfm | 无 LICENSE | ❌只借思想 |
| boschresearch/xrefine | AGPL-3.0 | ❌ |
| naver/mast3r 系 | NC(CC BY-NC-SA) | ❌ |
