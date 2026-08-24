# RealityCapture / RealityScan 团队全史卷宗(2013 → 2026-07)

**日期**:2026-07-28 · **目的**:穷尽 Capturing Reality s.r.o.(布拉迪斯拉发,2013-08-14 成立,2021-03-09 被 Epic Games 收购,现 Epic Games Slovakia s.r.o.)团队与产品的公开记录,聚焦**拍摄期 / 对齐 / 稀疏阶段**,为端上复刻 RS 稀疏预览补最后的信息缺口。
**方法**:4 路并行深挖(人物志 / 桌面对齐 / 移动端考古 / 专利与算法拼图,合计 ~230 次检索/抓取)+ 主线交叉核验。
**证据分级**:【实锤】=官方文档/专利/注册记录 · 【员工发言】 · 【三方实测】=第三方 benchmark/学术评测 · 【三方】=媒体转述 · 【论文推断】 · 【纯猜】

**总目录**:一、人物志 → 二、专利考古 → 三、产品考古(A 桌面对齐 / B 移动端逐版本)→ 四、算法拼图 → 五、差距清单 → 六、未找到清单

---

## 一、人物志

### 1.1 创始团队(注册记录铁证)

【实锤】斯洛伐克商业登记 orsr.sk(IČO 47356081):2013-08-14 成立于 Bratislava;konateľ(执行董事)= **RNDr. Michal Jančošek, PhD.** 与 **RNDr. Martin Bujňák, PhD.**(任至 2022-01-24,之后换 Epic 高管 Randy Gelber / Christopher Pike / Julie LoBean)。股权链:创始人个人 → RCRES Invest s.r.o.(2020-11)→ **Epic Games Slovakia s.r.o.**(2022-01-25)。收购官宣 2021-03-09,登记变更迟至 2022-01。
- https://www.orsr.sk/vypis.asp?ID=275322&SID=2&P=1

【实锤(专利发明人栏)】三位联合创始人齐名出现在公司唯一专利 EP3510513 发明人栏:**Michal Jančošek、Martin Bujňák、Tomáš Bujňák** —— 第三联创 Tomáš Bujňák 由此坐实(orsr.sk 可见摘录被截断,未显示其早期股权)。
- 公司从未用过 CEO/CTO 头衔(斯洛伐克 s.r.o. 的 konateľ 制);Jančošek 对外称 "Managing Partner"(Sketchfab 博客),Bujňák 现任 **Engineering Director – Capturing Reality @ Epic Games**(Crunchbase/Wiza)【三方】。
- 团队规模约 8 人(RocketReach,弱源)【三方】。
- 定性:公司 = CTU-CMP Pajdla 实验室两条研究线合流(Bujňák 的最小求解器 SfM + Jančošek 的 CMP-MVS 成面)+ 纯工程侧的 Tomáš Bujňák;**不是** CTU 官方 spin-off(无任何官方表述)【论文推断】。

### 1.2 Michal Jančošek(MVS/成面线)

- 博士:CTU Prague CMP 实验室,导师 Tomáš Pajdla,弱支撑表面重建方向。
- 【实锤(论文)】**CVPR 2011《Multi-View Reconstruction Preserving Weakly-Supported Surfaces》**(w/ Pajdla):Delaunay 四面体化 + s-t 图割,创新在用可见性信息改 t-edge 权重("free-space support"),保住弱纹理墙面/玻璃等弱支撑面 = **RealityCapture fuseCut 成面血统**(与我方记忆库结论互证);期刊扩充版 ISRN 2014。
- 其他:ECCV-W 2010《Hallucination-Free MVS》、ICCV-W 2009《Scalable MVS》、《3D with Kinect》系列、MVA 2015《CMP SfM web service》(w/ Heller, Havlena, Torii, Pajdla —— 与大规模 SfM 线直接同框)。
- CMPMVS = 该线开源实现(v0.6.0,2012-09-28);【员工发言(转述)】Jancosek 在 CHI 论坛称 RC "implemented completely from scratch" 且比 CMPMVS ~50× 快(原帖 403,引自搜索摘要)。
- 发声渠道:X @JancosekMichal(2013-07 注册,公司成立前一个月);无 GitHub/博客;在 Epic 的现职头衔未知。

### 1.3 Martin Bujňák(SfM 最小求解器/位姿线)

- 博士论文【实锤】:《Algebraic solutions to absolute pose problems》,CTU 2013,导师 Pajdla(https://cmp.felk.cvut.cz/ftp/articles/pajdla/Bujnak-PhD-2013.pdf)。
- 论文族(DBLP pid/67/3947,几乎全部与 Kukelova/Pajdla 合作):
  - **CVPR 2008**:P4P + 未知焦距一般解(4 点求 R,t,f)【实锤】
  - ECCV 2008《Automatic Generator of Minimal Problem Solvers》(领域奠基作)
  - ICCV 2009 单已知焦距图集重建;ACCV 2009 焦距投票;**ACCV 2010 绝对位姿 + 未知焦距 + 径向畸变**(平面/非平面分治,快 40×/160×);已知竖直方向(重力先验)闭式解
  - CVPR 2012《Making minimal solvers fast》;TPAMI 2012;**ICCV 2013 实时绝对位姿 + 未知径向畸变/焦距**;3DV 2013 L2 三视三角化;CVPR 2015 径向畸变单应
- 【三方(媒体)】Startitup 称其曾在 Microsoft 参与 Kinect 和 Photosynth(未独立核实);Kinect 位姿专利发明人栏无其名【实锤反证】。
- 无 GitHub/X;Google Scholar Ge4w-ZkAAAAJ(1700+ 引用)。
- 【勘误】P3.5P 未知焦距是 Changchang Wu(CVPR 2015)的工作,**不是** Bujnak 的。
- 收购官宣语录:"a proven track record of taking existing technologies"(谈 Epic,MCV 转载)【员工发言】;RealityScan beta 官宣:"AR-powered 3D scanning of the real world is the future"【员工发言】。

### 1.4 Tomáš Bujňák(纯工程线)

- DBLP 无条目,零学术论文;【三方(媒体)】Startitup:曾任职 Microsoft 与 Caligari(trueSpace),获 Werner von Siemens 优秀奖。与 Martin 的兄弟关系【纯猜】(同姓推断)。X @tomasbujnak / tomasbujnak.com 是否同一人未证实【纯猜】。

### 1.5 Tomáš Pajdla 与 Zuzana Kukelova(CTU 学术后场)

- Pajdla = 两位技术联创的共同博士导师【实锤】;CMP-MVS、CMP SfM web service、minimal solver 系列全部合著;Google Patents 名下 0 专利【实锤】;orsr.sk 无其股权/职位【实锤反证】。
- Kukelova:minimal solver 三人组核心;【三方(媒体)】mosaic51:"helped to write some of the underlying solvers"(为 RC 写过底层求解器)。正式合同/股权关系未找到。
- 关联学术线(Pajdla 组,Havlena):CVPR 2009 atomic 3D models(三元组原子模型拼合)、ECCV 2010 graph optimization SfM、**VocMatch(ECCV 2014)**2 层 4096² 视觉词典配对 —— "先小块再归并 + 检索式配对"的学院版【论文推断】;Havlena 本人去了 ETH→Vuforia/PTC,无入职 CR 证据。

### 1.6 周边/支持人物

- **Miloš Lukač**("Wishgranter" / wishgranter042):RC 内测元老,2016-2017 Head of customer support;早期论坛技术答疑主力(下文 Ultra 档内幕出自他);现 Global Digital Heritage【实锤(ArtStation 简历)】。
- **Jana Budošová**:早期 Marketing Executive → RealityScan App QA Analyst;GeoWeek/SPAR3D 采访代言人(增量对齐关键发言出自她)。
- **Ondrej Trhan**(测量学 PhD):CR/Epic 支持与社区专员,RC 1.4/1.5 官方教程署名作者(mobile LiDAR 表态出自他);近期被裁,现 3gon Slovakia【三方(LinkedIn)】。
- **Jakub Vanko**:Epic staff,论坛对齐规则答疑(见 3A.4)。
- RealityScan mobile 由 Capturing Reality + **Quixel**(Teddy Bergsman)合作开发【实锤(Epic 官宣)】;具体 mobile 工程 lead 名单未挖到。

### 1.7 人物侧与"对齐"直接相关的发言汇总 ⭐

| 发言(<15 词引语) | 出处 | 分级 |
|---|---|---|
| "the next alignment will re-use the existing information" — Budošová(加图增量注册,不重跑全量) | GeoWeek 采访 | 【员工发言】 |
| "align and register hundreds of unordered images on a laptop" — Budošová | 同上 | 【员工发言】 |
| 速度来源 = "proprietary algorithms" + 多核并行流 — Budošová | 同上 | 【员工发言】 |
| "MEDIUM setting is the best case scenario" — wishgranter042(检测敏度) | Epic 论坛(2016 镜像) | 【员工发言】 |
| ULTRA 档 "you would get a lot of false positive points";"ULTRA was added for full-body scans" — wishgranter042 | Epic 论坛 | 【员工发言】 |
| "every single point...needs to be visible in at least two photos";建议 ~70% overlap — Jakub Vanko | Epic 论坛 | 【员工发言】 |
| "RealityScan doesn't use iPhone's LiDAR. It uses only images." — OndrejTrhan(2024-09) | Epic 论坛 | 【员工发言】 |
| 接 LiDAR "is one of our future plans to implement" — OndrejTrhan(2025-06) | 同上 | 【员工发言】 |
| "10 times faster than anything on the market" | 官网旧宣传/Crunchbase | 【实锤为"说过",非技术证据】 |

---

## 二、专利考古

**核心结论【实锤】:算法层零专利。** Google Patents 直查 inventor/assignee:

- 唯一专利族 **EP3510513 A1/B1/B8**《A method of data processing and providing access to the processed data on user hardware devices...》:优先权 2016-09-12,授权 2021-03-24;发明人 = 三位创始人;受让人 Capturing Reality s.r.o. → Epic Games Slovakia s.r.o.;同族 AU2017325525B2、DK/LT,CN/JP/KR 活跃。
  - 内容 = **PPI/PPR(pay-per-input / pay-per-result)付费解锁商业模式**:本地算完模型、看质量、付费解密导出;"pays and acquires right to further use model"(说明书例1);核心设计:原始数据永不上传,只传签名描述换 key。
  - https://patents.google.com/patent/EP3510513A1/en
- 排除项:EP4240575(Jancosek 个人,3D 打印分层成型,无关);Pajdla 名下 0;Epic Games 名下 photogrammetry/SfM 检索 0;USPTO/Justia 检索 Bujnak/Jancosek 亦 0(与 Google Patents 结果一致)。
- **含义**:特征检测、匹配、位姿求解、增量注册、组件合并、out-of-core 全部是**商业秘密**——无专利文本可逆向,拼图只能靠论文谱系 + 官方参数面 + 员工发言 + 第三方实测(第四章)。
- 营销所称 "patented technology" 落点就是这件商业模式专利【推断,高置信】。

---

## 三、产品考古 A:RealityCapture 桌面对齐(2016 → 2026)

### 3A.1 对齐设置逐项官方语义(全【实锤】,rshelp.capturingreality.com Alignment Settings)

| 设置 | 官方语义(短引语) |
|---|---|
| Max features per mpx | "maximum number of features per megapixel for the feature detector";更多特征更慢但 "can result in less components" |
| Max features per image | 当前默认 **40,000/图**(官方帮助+Puget RAM 公式);Azad Balabanian 记录的旧版默认 20,000(preselector 10,000)【实锤+三方实测,默认值随版本变过】 |
| Image overlap | "how much of the image space is covered with the same part of the object";建议 >60%,<20% 设 Low |
| Image downscale factor | "multiplier by which the size of an image is reduced before feature detection";最高精度用 1 |
| Detector sensitivity | 高档(High/Ultra):"detection of more features, even in areas with weak texture" 但 "may also include less reliable points caused by image noise" ← **Ultra 引入噪点的官方原始出处**;低档 "more selective and ignores weaker features" |
| Preselector features | "number of features that will be used in alignment from the detected ones";官方建议 = 检出量 1/4–1/2 → **两级匹配漏斗的公开线索** |
| Max feature reprojection error | "Internal precision level used during alignment",建议 ≤3px |
| Force component rematch | "uses existing camera poses to search for new matches" |
| Background feature detection | "automatically detect feature points in the background with a low priority" —— **导入期后台预检特征**;changelog 佐证 "Features calculation on background disables the align button" |
| Merge components only | 开启后不吸新图,只合并既有组件(CLI mergeComponents 同语义) |
| 相机先验 | "prior positions for the images are used in the alignment process";accuracy = 视作相等的窗口,hardness = "the greater the value, the closer...to the prior" —— **精度窗+硬度权重的软先验双参数制** |
| Merge georeferenced components | 各自地理参考的组件 "merged even without visual overlap" |

**XMP 先验三档**【实锤】:draft = "subject to adjustment during the alignment process";exact = "cameras maintain their relative positions";locked = "positions remain fixed and are not adjusted"。(对照:我方 ARKit 注册+BA 精化 ≈ 介于 draft 与 exact 之间的自定义档。)

### 3A.2 对齐输出与组件语义【实锤】

- "Each component contains camera poses and a sparse point cloud."(Quickstart 3)
- Align Images = 特征检测 + "matching common tie points to create a sparse point cloud",逐图解出 "positions, orientations, and internal camera parameters"(Quickstart 2)。
- 多组件成因官方原话:"disjoint scenes...texture is weak, there are not enough images, or change in perspective is too high"。
- 组件合并三模式:overlap-based / "only the points used in the alignment of the imported component"(最快省内存)/ all features。
- **Update ≠ realign**:"does not change relative positions of cameras" —— Update 只做刚体放置/缩放去贴控制点约束;CLI 无独立增量对齐命令(align/draft/update/detectFeatures/mergeComponents),再跑 align 时 "engine will apply fixes from the corrected component"(组件复用式增量)。
- 控制点可 "create artificial tie points between images"(需 ≥2 图)。

### 3A.3 Draft mode【实锤】

- 目的 "estimate poses of all inputs"、"on-site analysis";本质 "you exchange quality for speed"(降采样对齐);独立设置组含 Final model optimization = "a final bundle adjustment is performed"(可关)。

### 3A.4 弱纹理/反光官方立场

- 【实锤】Ultra 换覆盖但含噪(3A.1);【实锤(mobile 文档)】"glass objects, which may not be reconstructed at all";"Smooth or reflective surfaces...may not provide enough unique points"(桌面帮助未找到同款措辞,只有 "texture is weak" 类间接表述)。
- 【员工发言】Vanko:每个点须 ≥2 图可见、建议 ~70% overlap。
- 【实锤】RS 2.0(2025-06):"New default settings improve image alignment, especially on surfaces with minimal features"、"Say goodbye to broken components";三方细化:默认切到 "higher-quality feature detection mode"、组件碎裂更少;CG Channel:"part of the alignment process can now be accelerated on the GPU"【三方转述】——**2016 以来对齐算法层唯一一次公开可见的实质变动**。

### 3A.5 版本变迁中的对齐条目(官方 changelog PDF + 论坛)【实锤】

- 1.0.2.1952:"Support for alpha masking in alignment"
- 1.0.3:Image layers(对齐/成面/贴图可用不同图);实验性 "custom HDR/16bit to 8bit tonemapping algorithm for better alignment"
- **1.1.1 Blaze:"Real-time alignment assistant on a smart device with a local network processing"(CLI)** —— 拍摄期实时对齐助手存在的最早证据:手机采集、局域网内桌面机算对齐 ⇒ **CR 从 2021 年起就把"拍摄期实时对齐"设计为离机计算(LAN 桌面或云),从未做过端上 SfM**【实锤+推断】
- 1.2.1 Tarasque:"Added relative alignment precision options";"Support for colmap scenes"(导入)
- 1.3(2023-11)/1.4(2024):对齐无改动(1.4 主要是免费化)
- 1.5(2024-11):"Export RealityCapture components in the COLMAP text format"
- RealityScan 2.0(2025-06):见 3A.4;另 AI masking、航空 LiDAR
- RealityScan 2.1(2025-11):SLAM 数据导入、OpenCV 格式注册数据导出、gRPC/REST 无头服务、Linux CLI(Wine);2.1.1(2026-04):COLMAP 支持增强 + XMP 导出选项;2.2(2026-06-24):AMD GPU 支持、AMD+NVIDIA 混跑【三方(CGPress/DIGITAL PRODUCTION)】

### 3A.6 三方实测硬数据(Remondino et al., ISPRS XLII-2/W5, 2017;RC v1.0.2.2600)【三方实测】

- 速度:Duomo 359 图对齐 RC **3'15"** vs PhotoScan 1h10'、Pix4D 41'(≈20×)。
- tie point 量级:359 图→797K(~2.2k/图);565 手机图→3.38M(~6k/图);1484 图→1.59M(~1.1k/图)——**每图稀疏点数与场景强相关,无固定值**;重投影 mean 0.41–1.04 px。
- 组件碎裂 + 低可重复性:514 图集三次跑分别裂成 5/505/4、4/12/8/6/19/463、5/5/8/4/4/4/4/479 个组件;"ReCap is not able to process the entire dataset in a unique block";**换图像输入顺序结果就变** ⇒ 增量式指纹 + 非确定性(与我方 cap3 逐跑不复现记忆呼应:RC 自己也非确定)。
- "max multiplicity drops immediately after image pairs" —— 多数 3D 点仅 2 视图(激进 2-view track)。
- 当时版本 GCP 不能设先验精度;稠密与 meshing 融合、无独立 DIM 点云输出。

---

## 三、产品考古 B:RealityScan Mobile 逐版本(2022 → 2026-07)

### 3B.1 版本时间线

| 版本/日期 | 要点 | 分级 |
|---|---|---|
| **2022-04-06 Beta**(iOS TestFlight,首批 1 万人) | 官方措辞:"interactive feedback, AR guidance, and data quality-checks";Bujnak:"AR-powered 3D scanning of the real world is the future" | 【实锤(Epic 新闻稿,经 Auganix 转载核实)】 |
| **2022-12-01 iOS 正式免费** | Sketchfab 集成(FBX→glTF/USDZ);"The photographs are then processed in the cloud"(Sketchfab 官博)= 云端处理最早白纸黑字;媒体:点云叠加被摄体,红=还需拍,绿=覆盖够 | 【实锤+三方(CG Channel)】 |
| **2023-06-21 Android** | iOS 一年 20 万+下载;step-based workflow;Android 7+ 且**必须支持 ARCore** | 【实锤(官方 docs)】 |
| **1.2** | 离线采集("capturing images while offline and uploading them later"——离线只免"传",重建仍须回线);上限 250;多项目并行 | 【实锤】 |
| **1.3** | Auto-capture;**Unguided Mode**:关 Live Guidance = "prevent automatic photo uploads" 且停用实时点云(架构钥匙,见 3B.3) | 【实锤】 |
| **1.4** | **最少 20 张才允许提交处理**;自动清浮空三角碎片;精确裁剪框 | 【实锤】 |
| **1.5**(2024) | 模型可下载本地(iOS=OBJ,Android=GLB);Sketchfab 改可选;砍 preview mesh 步骤 | 【实锤】 |
| **1.6** | 模式定型:**AR 模式**("provides a real-time point cloud and displays camera positions")vs **Camera Control**(手动曝光,无实时引导/点云);mesh Normal ≤100K / High ≤1M 面,纹理 4K/8K | 【实锤】 |
| **2025-06-17 品牌合并** | 桌面 RealityCapture → RealityScan 2.0;手机 → RealityScan Mobile;2.0 新特性全是桌面的,"It isn't clear which of those new features will be included in the mobile app"(CG Channel);Mobile 免费 | 【实锤+三方】 |
| **2025-06-26 Mobile 1.7** | 自动物体 masking(物体可转动/翻转);**Re-process 补图重跑**;上限 250→**300**("More photos mean better reconstructions") | 【实锤】 |
| **2025-11 Mobile 1.8** | 三模式:**AR Guidance**(叠加 "a live quality point cloud over your subject"+相机位)/ Object Mode(自动去背)/ Standard Mode;focus peaking;间隔定时拍;mesh 套索清理;watertight 选项 | 【实锤】 |
| **2025-12-02 Mobile 1.8.1** | 修 ISO/黑屏;**截至 2026-07 仍是最新版,2026 上半年无新版本** | 【实锤(App Store)】 |

### 3B.2 拍摄期反馈设计(彩色点 = 覆盖热图,非 RGB)——定案

- 【实锤】点云双渲染:**Color render(自然色)** 与 **Quality render(红→绿)**;语义 "greener shades mean higher quality (good coverage)"(Review Scan 文档)。
- 【实锤】拍摄期 AR 视图默认 quality 模式:"the point cloud shows up in the camera view after the initial analysis in the quality render mode"(Step-by-Step Guide);首轮分析 **20 张后**触发。
- 【实锤】App Store 官方描述:"Preview portrayal in colors to reflect photo coverage of the model"。
- **结论:我方记忆库"RS 彩色点云=覆盖热图非 RGB 取色"由官方文档坐实**(1.8 官方名词 "live quality point cloud");真彩渲染存在但在非 AR 的回看/浏览里。
- 20/300 数字的官方 rationale 从未给出(仅"防失败提交"与"更多照片=更好重建")。

### 3B.3 云 vs 端(证据链)

- 【实锤】重建 100% 云端:"The photographs are then processed in the cloud"(Sketchfab 官博 2022);处理完 "automatically downloaded to your device"(官方 docs)。
- 【实锤+推断】**拍摄期"实时"对齐也在云端**:官方 step-by-step "the processes of uploading and analyzing are interleaved, with uploading occurring first";1.3 Unguided Mode 关 Live Guidance = 不自动上传 + 无实时点云。两条官方陈述合并 ⇒ AR 实时点云是**边拍边传、云端对齐、回流显示**,不是端上 SfM。与我方记忆 project_realityscan_capture_cloud_incremental.md 一致,证据链升级到官方文档级。旁证:桌面 1.1.1 的 "Real-time alignment assistant...with a local network processing"(3A.5)同范式。
- 【实锤(AWS 官方博客,re:Invent 2022)】云侧栈:EC2 GPU 实例做 scanning 处理、RDS PostgreSQL 存会话、S3+CloudFront、ElastiCache;"uses AWS to process image data in real time and provide creators with a preview mesh"。此后基础设施零更新信息。
- 【员工发言】LiDAR:OndrejTrhan:"RealityScan doesn't use iPhone's LiDAR. It uses only images."(2024-09);接 LiDAR "is one of our future plans to implement"(2025-06)。截至 2026-07 手机端仍纯 photogrammetry;ARCore/ARKit 仅用于 AR 引导与尺度("models appear at the right scale",官网)。
- 【三方转述 EULA】默认允许 Epic 用扫描数据训练产品,可 opt-out(CG Channel 2025-06)。
- 2024-2026 **零**"把重建搬上设备"的官方表态;1.2 的 offline 只是离线拍。

---

## 四、算法拼图:RS 对齐管线"最可能的样子"(逐块证据分级)

> 前提【实锤】:算法层零专利(第二章)、零官方算法论文 → 拼图 = 官方参数面 + 员工发言 + 论文谱系 + 第三方行为指纹。

| # | 管线块 | 最可能的样子 | 关键证据 | 分级 |
|---|---|---|---|---|
| 1 | 特征检测 | **自研/未披露检测器**,高预算(默认 20k→40k/图,版本期不同),sensitivity 分档控制点稳定性;Ultra 官方自认含噪("less reliable points caused by image noise"),员工补刀 "a lot of false positive points"、"ULTRA was added for full-body scans"、"MEDIUM...best case scenario";RS 2.0 起默认切 "higher-quality feature detection mode" | rshelp;wishgranter042 论坛帖;RS 2.0 官宣 | 参数面【实锤】;员工【员工发言】;"自研"定性【论文推断】(找遍 2016-2025 无 "SIFT/非 SIFT" 员工原话) |
| 2 | 候选配对 | **两级漏斗**:preselector 用检出特征 1/4-1/2 子集先选图像对,再全量精配;overlap 档位先验;"works linearly, so doubling the inputs roughly doubles the processing time" ⇒ 非 O(n²) 穷举,检索/预选式。学院血统:VocMatch(ECCV 2014)+ atomic 3D models(CVPR 2009) | rshelp;Wikipedia/官方 FAQ;Havlena 论文族 | 参数面【实锤】;线性扩展【三方】;机制内幕【论文推断】 |
| 3 | 注册/位姿 | **增量式 SfM**:Bujnak 最小求解器族直接吞未知焦距+径向畸变(P4Pf CVPR2008、P4Pf+r ACCV2010、实时版 ICCV2013、已知竖直方向闭式解=重力先验)+ 高效 RANSAC ⇒ 免预标定、注册快。行为指纹:改图像输入顺序结果就变(ISPRS 2017,增量式典型;全局式与顺序无关) | Budošová "performed incrementally";ISPRS 2017;求解器论文族 | 【员工发言】+【三方实测】+【论文推断,高置信】;官方 incremental/global 明文表态**不存在** |
| 4 | 容错架构 | **组件归并**:注册失败的连通分量各自成 component;再对齐 "first use special algorithms designed for merging components";合并三策略;georeferenced 可无视觉重叠合并 | rshelp Components/Merging | 【实锤】 |
| 5 | 轨迹拓扑 | 激进 2-view:"max multiplicity drops immediately after image pairs" | ISPRS 2017 | 【三方实测】 |
| 6 | 精化/BA | 内部求解器零一手披露;暴露 "Max feature reprojection error"(≤3px)、位置/朝向先验 accuracy(窗)+hardness(权)双参数;draft 模式含可关的 "final bundle adjustment" | rshelp | 参数面【实锤】;求解器【未知】 |
| 7 | 内存架构 | **对齐是唯一 in-core 阶段**:"All processing steps except alignment are out of core";RAM ≈ features × images × 200 bytes(只依赖特征数不依赖分辨率) | 官方支持文档(Puget 转引) | 【实锤】 |
| 8 | 算力分工 | 对齐=CPU("image registration works without one");CUDA 仅 depth-map/mesh/texture;RS 2.0 起 "part of the alignment process can now be accelerated on the GPU" | Wikipedia/官方要求;Techgage;CG Channel | 【实锤+三方】 |
| 9 | 增量复用 | 加图不重跑全量("re-use the existing information");Update 命令只做刚体贴合不动相对位姿;Draft=降采样快对齐;Background feature detection=导入期后台预检 | Budošová;rshelp/CLI | 【员工发言+实锤】 |
| 10 | 成面(下游) | Delaunay 四面体化 + s-t 图割 + 弱支撑面 t-edge 加权(free-space support)= Jancosek CVPR 2011 从零重写的工业版(自称 ~50× 快于 CMPMVS) | CVPR 2011;CHI 论坛 | 【实锤(论文)+员工发言(转述)】 |
| 11 | 移动端拍摄期 | **云端增量对齐回流**:边拍边传(interleaved upload/analyze)、20 张触发首析、AR 显示 quality 点云+相机位;端上零 SfM;桌面 1.1.1 LAN 版同范式 | 3B.3 证据链;3A.5 | 【实锤+推断】 |

**一句话画像**:RC 对齐 = 自研高预算检测器 + 检索式两级配对 + 最小求解器驱动的增量注册 + component 归并容错 + in-core 特征驻留;速度来自 (a) 免标定最小解 (b) 预选漏斗 (c) 全特征驻留内存 (d) 多核并行流【综合推断,分块分级见上】。移动端拍摄期反馈 = 同一桌面引擎跑在云上的回流显示,**CR/Epic 从未做过端上 SfM**【实锤+推断】。

---

## 五、差距清单:RS 稀疏预览 vs 我们(逐项)

我方基准(2026-07-28 装机态,见 OFFICIAL_ALIGNMENT_AUDIT_2026-07-28.md):端上顺序采集、逐帧 ARKit 位姿注册(无 PnP)、GPU DSP-SIFT 8192@4032px、ratio 0.8+cross-check、K12 时序窗+官方 quadratic 长程配对、官方 COLMAP 增量三角化(保 2-view)、RS 式发布政策(首发 20 帧、+40% 增长)的官方迭代全局精化、finalize=官方全局 BA+过滤、142-156 帧交付 ~80-155k 稀疏点、重力对齐+VIO 米制尺度、均匀稀疏审美、AR 真彩稀疏预览。

| # | 维度 | RS(证据) | 我们 | 判定 | 可行动? |
|---|---|---|---|---|---|
| 1 | 拍摄期稀疏算力位置 | **云端**:边拍边传、AWS EC2 GPU 分析;关 Live Guidance = "skip uploading photos with live processing"【实锤】;桌面 1.1.1 LAN 助手同范式 | 全端上 | **我们领先**(RS 拍摄期反馈依赖网络;我们无网可跑) | 不动:护城河,与"永远没有云端"铁律一致 |
| 2 | 首次反馈时机 | 20 张后首次分析出点云;1.4 起最少 20 张才可提交【实锤】 | 首发 20 帧(RS 式发布政策) | **一致**(逐字吻合) | 保持 |
| 3 | 拍摄期注册方式 | 云端增量 SfM(无证据用 ARKit/ARCore 位姿做注册先验;AR 传感器仅引导+尺度)【实锤+推断】 | ARKit 位姿直接注册+BA 精化 | **我们领先**(零 PnP 失败模式、注册瞬时、无组件碎裂) | 不动 |
| 4 | 拍摄期预览语义 | AR 视图默认 **quality render**(红→绿覆盖热图,"live quality point cloud");真彩(color render)只在非 AR 回看【实锤】 | AR 真彩稀疏点云 | **有意差异**:RS 把拍摄期预览当**引导工具**,我们当**成品预览** | 可选:加 quality/coverage 渲染切换(coverage cloud 策略已全 Dart 化,低成本);真彩保默认 |
| 5 | 特征预算 | 桌面默认 20k→40k/图(版本变迁);Ultra 官方自认含噪、员工称假阳性多、MEDIUM 最优【实锤+员工发言】;移动端预算未公开 | 8192@4032px | 数值不可比(RS 面向无序 DSLR 图集) | 不动(我方漏斗实测:瓶颈在匹配非检测);员工"预算↑=质量↓"的表态反向支持我们不抬 8192 |
| 6 | 候选配对 | preselector 两级漏斗 + overlap 先验,近线性【实锤+三方】 | K12 时序窗 + 官方 quadratic 长程 | **范式一致**(都避开 O(n²));我们吃顺序性,RS 吃检索预选 | 保持;未来做无序补拍可借鉴 preselector |
| 7 | 2-view 轨迹 | "max multiplicity drops immediately after image pairs"【三方实测】 | 保 2-view(七臂签决) | **一致**——RC 同样激进保 2-view,佐证我方签决 | 保持 |
| 8 | 容错架构 | component 碎裂+归并+控制点兜底;复跑组件数都不稳定【实锤+三方实测】 | 单 component(ARKit 保证全注册) | **我们领先**(RS 的组件机制在解我们靠 ARKit 天然免掉的问题);RC 也非确定(呼应 cap3) | 不动 |
| 9 | 弱纹理立场 | Ultra 换覆盖含噪【实锤】;mobile 文档 "glass objects, which may not be reconstructed at all"【实锤】;RS 2.0 唯一一次对齐默认值实质改动("higher-quality feature detection mode"+组件更不碎)【实锤+三方】 | DSP-SIFT + 已知平面 plane-sweep 榨密(+112%) | 方向一致:都认弱纹理是检测问题;RS 2.0 具体改了什么未披露 | 跟踪 RS 2.x 后续披露;我方 detector-free(ELoFTR)路线已立案 |
| 10 | 尺度/重力 | AR 模式 "models appear at the right scale"(AR 传感器尺度)【实锤】;桌面靠 GPS/控制点;XMP 先验三档(draft/exact/locked)+ accuracy/hardness 软先验双参数【实锤】 | VIO 米制尺度+重力对齐(R_w 落盘);ARKit 注册后 BA 精化 | **一致偏我们更深**(RS 位置先验不含旋转注册;我们全位姿注册) | 保持 |
| 11 | 照片上限 | 移动端 300/scan(250→300,1.7)【实锤】;绑云端成本【推断】 | 142-156 帧实测,无硬上限设计 | 差异:RS 限额是云成本产物 | 不动;若设上限应绑内存实测 |
| 12 | 稀疏点量级 | 桌面实测 ~1.1k-6k tie points/图(场景相关,ISPRS 2017);移动端从未公开 | ~550-1000 点/帧交付(80-155k/142-156 帧) | 同量级下限;RS 桌面上限更高但面向 DSLR 无序集 | 不动(我方密度绑检测分辨率已有定案) |
| 13 | 增量复用/续跑 | "re-use the existing information"【员工发言】;1.7 Re-process 补图重跑【实锤】;Update 只刚体贴合 | sfm_live.db 断点续跑 + finalize 复用 live 模型 | **一致**(范式相同) | 保持 |
| 14 | 交付语义 | 移动端稀疏云 = 引导中间产物;交付物 = 云端 mesh+纹理;1.5 起才可下载本地模型 | 稀疏云即首个交付物(拍完≤30s 出云) | **有意差异**(北极星不同,已签决) | 不动 |

**总判定**:在"拍摄期稀疏预览"子问题上,公开记录里**没有我们落后的项**;RS 移动端的实时反馈是云端算的覆盖热图,我们是端上真彩稀疏云——机制上我们更像"RS 桌面增量对齐搬上手机",而这正是 CR/Epic 自己从未做过的东西(他们选了 LAN/云离机计算)。唯一值得抄的增量 = **第 4 条:覆盖/质量(红→绿)渲染模式切换**。

---

## 六、未找到清单(明说查不到的)

**算法内幕类**
1. 官方/员工关于 incremental vs global SfM 的直接表态(只有员工 "incrementally" 一词+行为指纹)。
2. "RC 用什么检测器 / 是不是 SIFT" 的任何一手披露(2016-2025 论坛全无)。
3. 匹配策略/epipolar/preselector 机制内幕(只有参数语义)。
4. 内部 BA 求解器任何披露。
5. RS 2.0 "smarter alignment" 具体改了哪些默认值。
6. 移动端特征预算、每图点数、云端算法版本。
7. 任何 SfM/匹配/位姿算法专利(确认不存在,非检索失败)。

**产品/运营类**
8. 20 张最小 / 300 张上限的官方 rationale。
9. "0/300" 计数器的官方文字描述(docs 只提 image counter)。
10. 2024-2026 任何"重建搬端上"的官方表态(零)。
11. RealityScan Mobile 专场技术讲座 / 移动团队架构访谈(不存在)。
12. AWS 之后的云基础设施更新信息。

**人物类**
13. 正式 CEO/CTO 头衔(公司从未使用);Jancosek 在 Epic 的现职头衔。
14. 创始人的 CVPR/SIGGRAPH/GDC/Unreal Fest 演讲、播客(零命中)。
15. Martin Bujnak 的 GitHub/X;Jancosek 的 GitHub。
16. RealityScan mobile 工程 lead 名单。
17. Tomáš Bujňák 早期股权记录(orsr.sk 摘录截断)与现状;Kukelova 与公司的正式关系。
18. 老 Zendesk 社区(support.capturingreality.com)大量 staff 技术帖已删档/迁移;CHI 论坛原帖 403;Forbes.sk / index.sme.sk 深度访谈付费墙;PCT 公开号(疑似 WO2018/050138)未直接确认;web.archive.org 本环境不可用;dev.epicgames.com 直连超时(经代理/转载核实)。

**桌面帮助中的措辞差异**
19. 桌面版帮助无 "may not be reconstructed" 确切措辞(只在 mobile 文档);官方"典型每图 tie point 数"不存在。

---

## 附:核心来源索引

官方:rshelp.capturingreality.com(Alignment Settings / Components / Quickstart 2/3 / Draft / CLI / XMP / Control Points)· dev.epicgames.com(RealityScan Mobile docs:Step-by-Step / Review Scan / Camera View / 1.2-1.8 release notes / Objects and Backgrounds)· realityscan.com/news(2.0 与 Mobile 1.7 官宣)· 官方 Release Notes PDF(cdn.capturingreality.com)· EP3510513(Google Patents)· orsr.sk · AWS 官方博客(re:Invent)· Epic/Sketchfab 新闻稿。
员工发言:GeoWeek(Budošová)· Epic 论坛(wishgranter042 / Jakub Vanko / OndrejTrhan)· CHI 论坛(Jancosek,转述)· 收购/发布新闻稿语录(Jancosek/Bujnak/Bergsman)。
三方:ISPRS XLII-2/W5(2017)591-598(Remondino et al.)· Puget Systems · Techgage · CG Channel · DIGITAL PRODUCTION · CGPress · 80.lv · Azad Balabanian(Medium)· Peter Falkingham 博客 · Wikipedia · Startitup/Sector.sk(斯洛伐克媒体)· mosaic51 · Crunchbase/Tracxn/RocketReach。
学术:Jancosek&Pajdla CVPR 2011 / ISRN 2014 · Bujnak CVPR 2008 / ACCV 2010 / ICCV 2013 / PhD 2013 · Kukelova 系列 · Havlena CVPR 2009 / ECCV 2010 / VocMatch ECCV 2014 · CMP SfM web service MVA 2015。
