# RealityScan 采集引导「呈现层」拆解 —— 为什么它像分区,我们像雪花

日期:2026-07-28
范围:**只谈呈现与交互**(颜色附着在什么粒度、点多大多密、还有哪些引导元素)。不谈检测/重建算法。
关联既有档案:`RS_POINT_RENDERING_EVIDENCE_2026-07-28.md`(点渲染三技术)、`RS_PARITY_FINAL_VERDICT_2026-07-28.md`、`POINTCLOUD_RENDERING_TECHNIQUES_2026-07-28.md`

---

## 0. TL;DR —— 机理判决(先说结论,因为它推翻了本次调研的初始假设)

> **RS 并没有做空间聚合/平滑。RS 的点也是逐点上色的。我们的初始假设("RS 一定做了 voxel 聚合所以才成区")被自己的取证数据打掉了。**

图像取证实测(§3):RS 采集屏点云的**地面区域**同样是红黄绿逐点交错的雪花,滞后相关在 32–64px 就掉到 ~0.1。**RS 的地面和我们的病症是同一个东西。**

真正的差别只有一条,但它是决定性的:

| | RS 的主体(石头) | RS 的地面 | 我们的全场景 |
|---|---|---|---|
| 滞后相关 @64px | **+0.53** | +0.08 | ≈0(推断) |
| 绿点占比 | **67%** | 24% | 混杂 |
| 观感 | **实心绿区** | 雪花 | 雪花 |

**机理**:RS 的 quality = 「有多少台相机看到这个 tie point」。用户绕着主体拍 40 张,主体上**每一个**点都被 30+ 台相机看到 → 全部**撞到色标顶端饱和成纯绿** → 逐点噪声被饱和吃掉 → 成区。地面只被 3–6 台相机看到,正处于色标的陡峭段 → 逐点噪声全部显形 → 雪花。

**我们的病根**:阈值 `≥5 绿 / ≥3 黄 / 2 红`(`ar_capture_page.dart:904-923` —— **代码实锤**)把三个色阶全部塞进 track length 分布**最密最陡的 2–5 区间**。同一个已经拍够的表面上,相邻点的 track length 因为「这一帧这个特征有没有被重新检测+匹配上」而独立涨落 —— **量化台阶宽度 ≈ 逐点采样噪声幅度**,于是噪声被 1:1 翻译成颜色。RS 从来不会落在这个区间,因为它的主体早就饱和了。

> ⚠️ 这条病因判定是**推断(强)**:阈值与整云替换是代码实锤,但"我方 track length 分布重心确实落在 2–5、噪声幅度与台阶同量级"**尚未真机实测**。P1 落地前必须先出直方图(§⑤);若重心远高于 5,头号病因改判为点径过小(§3.3-C)。

**一句话**:不是 RS 平滑了,是**RS 的色标会饱和,我们的色标在量化噪声底**。

⚠️ **而且:我们的逐体素覆盖云早就写好、还用真机遥测标定过,但在 commit `eaf8706` 里被从 AR 通路上摘掉了。**(`capture_coverage_cloud.dart`,4cm 体素,ramp 1红/2-3黄/≥5绿,外加 5° 低视差压黄;设计文档 `docs/capture_guidance_signals.md` 自述就是"学 RealityScan 的采集引导")。**修复的一大半是接回去,不是新写。**

**排名前三的呈现层修复**:
1. **P1 色标改饱和式连续映射**(Dart 一处,~1h)—— 直击头号病因
2. **P2 把逐体素覆盖云接回 AR**(Dart 接线,~0.5–1 天)—— 基建与标定都已就绪
3. **P3 点径上限 6px → 10–12px**(Swift 一行,已有 env 开关可零改码 A/B,~10min)

---

## ① RS 呈现拆解(逐项标证据等级)

### 1.1 颜色附着在什么粒度上 —— **逐点(per tie point),实锤**

| 结论 | 等级 | 出处 |
|---|---|---|
| 采集期 AR 那层官方叫 "quality point cloud" | **实锤** | 1.8 release notes:"Uses Augmented Reality to display a live quality point cloud over your subject" — https://forums.unrealengine.com/t/realityscan-mobile-1-8-release-notes/2676487 |
| Review 屏是 color / quality **双档** | **实锤** | Review Scan 页:"color render on the left and quality render on the right" — https://dev.epicgames.com/documentation/en-us/realityscan-mobile/realityscan-review-scan |
| 图例文案 | **实锤** | 同上:"Quality is shown using a color scale from red to green";"greener shades mean higher quality (good coverage)" |
| 采集屏**默认就是 quality 档** | **实锤** | Step-by-Step:"The point cloud shows up in the camera view after the initial analysis";"helping you to notice parts where the image coverage could be improved" — https://dev.epicgames.com/documentation/en-us/realityscan-mobile/RealityScan-Step-by-Step-Guide |
| 商品页把它定义成覆盖度 | **实锤** | App Store 描述:"Preview portrayal in colors to reflect photo coverage of the model" — iTunes lookup id=1584832280,v1.8.1 |
| quality 的定义 = 每个 tie point 的相机覆盖数 | **推断**(桌面实锤,手机无官方等号) | 桌面帮助:"It primarily evaluates the camera coverage of each tie point" — https://rshelp.capturingreality.com/en-US/tools/qualityanalysis.htm |
| **粒度是逐点,不是空间聚合** | **实锤(措辞) + 实锤(像素取证)** | 官方措辞 "each tie point" 明确逐点;§3 的像素取证独立确认地面存在逐点交错 |

**同一页官方还给出了一个「面级聚合」变体**,这是我们方案的直接授权先例:
> "Calculates the quality of the mesh by evaluating camera coverage for each triangle"
> —— 桌面 Mesh Quality,可 Bake 成贴图或 Colorize 到顶点。同源指标、**逐三角**粒度。

⇒ **Capturing Reality 自己就同时提供 per-point 和 per-triangle 两种粒度的同一指标。**「聚合到面/格再上色」不是我们的发明,是他们的既有产品形态。

### 1.2 空间平滑 / 聚合 / 时间平滑 —— **未找到任何证据,且像素取证倾向"没做"**

- 官方文档零处提到 voxel / binning / smoothing / filtering / 邻域。
- 像素取证(§3):地面区域滞后相关 64px 处 +0.08 ⇒ **若做过邻域多数滤波,不可能这么低**。
- **时间平滑:间接反证**。官方:图片"will be analyzed after you take 20 images",上传与分析交替进行。⇒ 点云是**每 20 张整批云端重算后整体替换**,不是逐帧累积。**没有可平滑的时间轴**,因此不需要时间平滑 —— 每次刷新时全部点的 quality 都是在**同一套相机集合**上算的,天然没有"新点因为年轻所以红"的年龄污染。
- ⚠️ 这一条对我们极重要,详见 §3.3。

### 1.3 显示点的大小与密度 —— **推断(像素取证,中强)**

对官方商品页素材(Epic 自上传)做连通域分析,同一场景两份独立素材(iPhone / iPad 画布):

| 素材 | 圆盘等效直径 | 最近邻间距中位数 | **直径/间距** | 点云屏占比 |
|---|---|---|---|---|
| `s03`(iPhone 画布 1242×2208) | 7.0 px | 11.1 px | **0.64** | 31.7% |
| `s11`(iPad 画布 1799×2400) | 8.5 px | 12.8 px | **0.66** | 28.4% |

**「直径/间距 ≈ 0.65」是本表唯一尺度无关、因而唯一可信的数字**(营销素材经过缩放,绝对像素值要打折)。它的含义:**点几乎连成毯**,相邻点边缘只差三分之一个间距。这个密度下,人眼会把局部的红绿交错**空间平均成一个中间色调**(抖动/dithering),而不是看成一颗颗独立的斑点。

- 采集屏是否降采样、点预算是多少 —— **未找到**。官方无任何点预算表述。
- 采集屏 vs Review 屏的密度对比 —— **未找到**。15 张官方商品页素材里**只有 2 张**含真实点云(均为 AR 采集屏),**没有一张 Review 屏点云**,无法比对。
- ⚠️ 与既有档案一致:`RS_POINT_RENDERING_EVIDENCE` 测得 5–11px、圆盘剖面、近大远小。本次独立复现了圆盘与 7–8.5px 量级。

### 1.4 采集屏的全部引导元素(官方逐项,**实锤**)

来源:https://dev.epicgames.com/documentation/en-us/realityscan-mobile/realityscan-camera-view

| 元素 | 官方语义 | 它传达什么 |
|---|---|---|
| 1 Quick Start Guide | 打开快速指南 | 首次教学 |
| 2 Application settings | 应用设置 | — |
| 3 Footer menu | 工具随扫描模式变化 | — |
| 4 **Images 计数器** | "Image counter; tap to view images." | **进度**(配合 "The image limit is set to 300 images.") |
| 5 **Auto-capture 开关** | "Available only with the AR Guidance." | 自动按运动触发快门 → **用户只需移动,不需判断何时拍** |
| 6 Capture 按钮 | 点击拍照 / 暂停自动拍 | — |
| 7 Next step | 进入 Review | — |

AR Guidance 模式的 footer 两个可见性开关(**实锤**):
| | 官方原文 | |
|---|---|---|
| 1 **图片缩略图** | "Toggle the visibility of the image thumbnails in the camera view." | **已拍机位的 AR 实体化** |
| 2 **点云** | "Toggle the point cloud visibility in the camera view if images have been analyzed." | 覆盖热图 |

**关键补充(1.8 release notes,实锤)**:AR Guidance =
> "real-time visualization of your captured photo positions"
> "allowing you to check where more pictures are needed as you scan"

**⚠️ 本次调研最被低估的一条**:从 `s03`/`s11` 截图看,**照片缩略图是带绿色描边的小卡片,按实际机位摆在 AR 空间里,沿着用户走过的弧线排成一圈**。这个元素:
- **本身就是零噪声的分区信号** —— 一圈卡片里缺了一段,就是"这边没拍过",一眼可读,且**完全不受逐点噪声影响**;
- 它在**点云出现之前就已经存在**(`s00` 截图:计数器 25 张,有缩略图弧线,无点云);
- 它承担了「哪里没拍」的主要引导职责,**点云只是补充**。

**缩略图描边是否编码质量 —— 实测:否(推断,图像取证)**。对 `s11` 里三张 AR 缩略图量描边环平均色:(174,186,82) / (168,178,76) / (155,172,68) —— **同一个黄绿色**,差异随卡片变小而变暗,是抗锯齿与背景混合所致,不是语义。⇒ 描边只表示"这里拍过一张",**不携带每张照片的质量**。这条很重要:**RS 的机位指示器是纯二值信号,故永远不可能抖动或雪花**。

其他(**实锤**):
- 模式差异:"In Camera Control mode, the point cloud cannot be displayed in the AR view"(https://dev.epicgames.com/documentation/en-us/realityscan-mobile/realityscan-application-settings)⇒ **AR 引导与相机手控二选一**,Epic 认为二者不可兼得。
- 文字引导集中在**文档而非屏幕**:Step-by-Step 里的 "make circles and arches around the object at multiple heights"。
- **未找到**:箭头 / 进度环 / minimap / 覆盖球 / dome / 幽灵轮廓 / "keep taking pictures" 类实时文案。RS 采集屏**没有**这些。屏上引导只有三样:**点云热图 + 机位缩略图 + 张数计数器**。

### 1.5 Review 屏

- 双档切换(color / quality),同一图例文案(见 1.1)。
- 目的官方表述:帮你 "find parts of the scan that can be improved"。
- 下一步 Reconstruction Area 裁剪框 + "Take More Pictures" 返回键。
- **未找到**:Review 屏点云是否与采集屏同密度/同点预算。

---

## ② 竞品呈现模式清单

> ⚠️ 本节的竞品逐家横评由并行子 agent 承担,**在本文写作时该任务尚未返回**。以下是本人在学术/平台侧独立取证到的、可立即采信的部分;逐家(Polycam/KIRI/Scaniverse/Luma/Matterport)的官方帮助中心措辞**待补**,已列入 §⑤ 未找到清单。

| 系统 | 视觉形态 | 颜色/信号附着的粒度 | 它解决的可读性问题 |
|---|---|---|---|
| **Apple Object Capture (iOS)** — WWDC23 #10191 | 先拉 bounding box 圈范围;再用 **capture dial** 环形刻度盘标示哪些**方位**还缺图。官方原话:`ObjectCaptureView` "provides a dial indicating areas that require scanning";另有 `ObjectCaptureSession.Feedback` 枚举驱动的文字/箭头提示(补光、放慢、翻转物体) | **per-angular-sector(环形扇区)**,极粗 | 把三维覆盖度**压成一维圆环**,彻底消灭空间噪声。苹果在最贴近我们的场景里选了**最粗**的聚合,且**完全不显示任何点** |
| **ARKit `ARCoachingOverlayView`** | 半透明遮罩 + 动画手绘手机图示 + 一句文案 | **会话级**,零几何着色 | 官方立场是引导期**减元素**:HIG "hide unnecessary app UI while people are using a coaching view" |
| **ARKit `rawFeaturePoints`** | 逐点显示 | per-point | ⚠️ **苹果自己定性为**"main intention is a debug visualization"(开发者论坛)。**即平台方明确不认为逐点云是产品 UI** |
| **Hoppe 2012 (TU Graz)** 在线 SfM 反馈 | 从稀疏点云 graph-cut 抽出**三角网格**,把 GSD 与冗余度刷在网格上 | **per-triangle** | 动机原文:"it is difficult for a user to derive this information from the point cloud" |
| **IntelliCap (ISMAR 2025)** | proxy mesh 上未采样区涂**粉白条纹**;重点物体外套**球形 proxy**,拍过的扇区消失 | **per-mesh-face + per-sphere-region** | 主动**合并临近球体**以减少数量 —— 又一次"显示前空间聚合" |
| **Error Peaking (2025)** | 重建渲染 vs 实时帧逐像素比对,超阈值涂红 | **per-pixel 但二值阈值** | 主动放弃连续色带改硬阈值;批评既有 AR 引导 "the visualizations hiding the subject to be photographed" |
| **Bogaerts 2019 (VR 检测规划)** | 质量刷在网格顶点,OpenGL 三角插值成连续场 | **per-vertex + 均匀重网格 + 插值** | "allowed inexperienced users to design high quality camera networks" |
| **KinectFusion / MonoFusion** | **没有**覆盖着色 UI;反馈就是实时增长的 TSDF 表面本身 | **per-voxel → raycast 成连续面** | 用户看哪里有洞补哪里 |
| **V-PCC / MPEG(工业标准)** | 解码点云切 voxel grid,算每格颜色质心,**tri-linear 滤波** | **per-voxel** | 动机纯粹是主观视觉质量;少量变色点显著伤害观感 |

**跨系统的硬结论(可直接用于签决)**:
> **没有任何一个已发表系统 / 平台官方 UI 把 per-point 质量原样刷给用户看。**全部先聚合:per-triangle、per-vertex、per-mesh-face、per-angular-sector、per-voxel,或 per-pixel 但二值化。**RS 是唯一的例外,而它靠"色标饱和"逃过了这一劫(§3)。**

**感知学理论底座**:
- Rosenholtz *Measuring visual clutter* (J.Vision 2007, doi:10.1167/7.2.17):clutter 被定义为**局部特征方差**(颜色/朝向/亮度对比)。⇒ **逐点独立着色 = 局部颜色方差最大化 = 该度量下的最坏情况。这不是审美偏好,是有量化模型的。**
- Mayorga & Gleicher *Splatterplots* (TVCG 2013):"Overdrawing occurs when the glyphs that are used to visualize data points overlap."关键设计原则:**抽象要在 screen space 做**,因为屏幕空间是感知空间的代理 —— 对 AR 里"点随距离变密"尤其关键。

---

## ③ 「为什么 RS 看起来是分区、我们是雪花」—— 机理判断

### 3.1 取证数据(本次实测,可复现)

方法:官方商品页素材 → HSV 提取暖色点(h<150°, s>0.5, v>0.4)→ (a) 连通域质心 + kNN Moran's I(k=8,200 次置换零分布);(b) 与连通域无关的**滞后距离相关**(水平+垂直 pair)。脚本与素材:`/private/tmp/claude-501/.../scratchpad/rs2/`(⚠️ /tmp 会被清空)。

**Moran's I(k=8)**
| 区域 | I | 置换零分布 | z |
|---|---|---|---|
| 全云 | **+0.835** | −0.003±0.042 | +20.1 |
| 石头(主体) | **+0.842** | −0.001±0.049 | +17.3 |
| 地面 | **+0.361** | −0.011±0.061 | +6.1 |

⚠️ 诚实交代:连通域会把相邻同色点**并成一个 blob**,这会系统性**高估** Moran's I。因此下表(与连通域无关)才是主证据。

**滞后距离相关(iPad 素材 `s11`,点间距 ~12.8px)**
| 区域 | 4px | 8px | 16px | 32px | 64px | 128px |
|---|---|---|---|---|---|---|
| **石头(主体)** | +0.93 | +0.87 | +0.84 | **+0.75** | **+0.53** | +0.18 |
| **地面** | +0.64 | +0.25 | +0.24 | +0.17 | **+0.08** | −0.02 |
| 全云 | +0.84 | +0.68 | +0.65 | +0.56 | +0.38 | +0.17 |

iPhone 素材 `s03` 独立复现同一模式(地面 64px 处 −0.008)。

**颜色分布**
| 区域 | 红 | 橙 | 黄 | 绿 |
|---|---|---|---|---|
| 全云 | 17.7% | 20.2% | 18.0% | 44.1% |
| **石头(主体)** | 8.9% | 17.1% | 7.0% | **67.0%** |
| 地面 | 24.5% | 23.2% | 28.1% | 24.2% |

### 3.2 判读

1. **RS 的地面就是雪花。** 相关在 ≫ 点间距的尺度(64px ≈ 5 个点间距)已经归零。**RS 没有做任何邻域平滑** —— 初始假设被证伪。
2. **RS 的主体是真·实心区。** 相关在 64px 仍有 +0.53,绿点占 67%,红仅 8.9%。这不是平滑出来的,是**饱和**出来的:主体上每个点都被 30+ 相机看到,全部撞到色标顶端。
3. **人眼看到的"分区"= 主体饱和绿 vs 外围杂色毯的二元对比。** 用户读到的是"我关心的东西已经绿了",而不是去解析地面那片雪花。**地面的雪花被认知性地忽略了,因为它不是任务目标。**
4. **点密度放大了这个效应。** 直径/间距 ≈0.65 的近连毯 + 主体 67% 绿 ⇒ 主体在视网膜上就是一片实心绿。若把同样的色值画成稀疏小点,饱和优势会被稀释。

### 3.3 我们为什么是雪花 —— 四条,按杠杆排序

代码事实来自 `~/Developer/pocketworld`(⚠️ 实际 checkout 在 `main`,不是 `ar-capture-rs`;`origin/ar-capture-rs` 是更旧的祖先)。

**(A) 【头号】色标落在量化噪声底,且永不饱和 —— `ar_capture_page.dart:904-923`**
```dart
if (trackLength >= 5)      { 56, 220, 110 }   // 绿
else if (trackLength >= 3) { 255, 210, 45 }   // 黄
else                       { 255,  82, 47 }   // 红
```
三个色阶全部塞进 track length 的 **2–5** 区间 —— 按既有档案(`project_pocketworld_feature_budget_funnel_audit`:仅 19.9–36.2% 特征进三角化)这恰是分布最密最陡处。同一块已拍够的表面上,相邻点的 track length 因"这一帧这个特征有没有被重新检测并匹配上"而**独立涨落**。**台阶宽度(1–2)≈ 逐点采样噪声幅度 ⇒ 噪声被 1:1 翻译成颜色。**

> ⚠️ **证据等级:推断(强)**。色标阈值与"整云原子替换"是**代码实锤**;"track length 在 2–5 区间最密、逐点噪声幅度与台阶同量级"**尚未在真机直方图上实测**。P1 落地前必须先测(见 §⑤)。若实测发现分布重心远高于 5,则头号病因要改判为 (C) 点径。
RS 永远不落在这个区间:主体 30+ 相机,全部饱和;所以 RS 用同一个逐点指标却不会雪花。
> **这一条单独解释了我们 80% 的观感差距。**

**(B) 逐点噪声没有任何空间聚合去抵消。** 我们把 per-point 值直接送渲染。§② 表明**没有任何已发表系统这么做**。

**(C) 点太小,眼睛无法空间平均 —— `OfficialAetherARKitPlugin.swift:3102-3116` + `:2285-2291`**
```swift
element.pointSize = 6                       // world units
element.minimumPointScreenSpaceRadius = 2
element.maximumPointScreenSpaceRadius = 6   // arSplatMaxScreenRadius 默认 6
```
最大屏幕**半径** 6px。RS 实测**直径** 7–8.5px(素材内,真机更大)、直径/间距≈0.65。我们的点更小更散 ⇒ 每颗点被独立解析 ⇒ 交错读作噪声而非混色。(该文件 `[SPLAT-RADIUS 2026-07-28]` 注释块已经记录了这个 6px 上限与 RS 7–11px 的对比。)

**(D) 年龄污染 —— 比预想的轻,但存在。** 我们的 AR 云**只在整体全局 BA 后整云原子替换**(`live_sfm_publish_policy.dart:35-47`:首发 20 帧,之后帧数或点数增长 ≥1.40× 才再发),这在结构上**与 RS 的每 20 张整批重算是同构的**。所以年龄污染不是主因 —— **主因是 (A) 的色标设计**。但两次发布之间新三角化的点仍会以短 track 出现。

---

## ④ 可行方案(只改呈现,不碰检测算法)

> 铁律核对:全部为**显示层**改动,点云数据仍全量交付(`feedback_no_downsampled_pointcloud_delivery`);不新增任何用户可见质量旋钮(`feedback_no_user_quality_knobs`);计算不搬 Dart 之外的新地方,Swift 只做既有 shim。

### P1 —— 色标改为「饱和式连续映射」(复刻 RS 的真实机理)
- **做什么**:废掉 2/3/5 三段硬阈值,改为 `t = clamp(trackLength / T_sat, 0, 1)` 的连续红→绿渐变,`T_sat` 取**主体典型覆盖数**(建议 10–12,需按真机 track 分布标定)。达到 `T_sat` 即纯绿、**不再变化**。
- **为什么**:这就是 RS 成区的真实机理(§3.2-2)。拍够的地方全部饱和成同一个绿,逐点噪声**在饱和区被数学地抹平**;只有真正欠拍的地方才落在陡峭段。
- **实现面**:Dart 单点,`lib/ui/official_capture/ar_capture_page.dart:904-923`。
- **工作量**:**~1 小时**(改映射)+ 标定 `T_sat` 需一次真机采集的 track length 直方图。
- **风险**:`T_sat` 定错则要么全绿(过松)要么全红(过严)。必须用真机分布标定,不要拍脑袋。

### P2 —— 体素聚合上色(把已有的覆盖云接回 AR)
- **做什么**:按 4cm 体素聚合,体素内所有点**共用一个颜色**;聚合算子取**高分位(p75 或 max)而非均值**。
  - 取 max/p75 的理由:同一体素里既有老点也有刚三角化的新点。**只要有一个成熟点存在,就证明这块地方被拍够了**;新点只是同一位置上新检测到的特征,不代表覆盖变差。取均值会被新点拖下去,取高分位则正确。
- **为什么**:§② 全部先例的共同做法;V-PCC 的 voxel 质心 + tri-linear 是成熟工业配方。
- **实现面**:**Dart,且基础设施已存在**:
  - `lib/official_capture/true_parallax.dart:32-45` —— `kCoverageVoxelSizeM = 0.04` + `coverageVoxelKeyFor()`(21-bit/lane 打包键)**已经写好**;
  - `lib/official_capture/true_parallax.dart:109-180` `trueParallaxAggregate()` **已经在对同一份 tracked 云做逐体素中位数聚合**;
  - `lib/official_capture/capture_coverage_cloud.dart:351-375` —— 完整的红黄绿体素覆盖云(`coverageSaturation = 5`,低视差钳到黄)**已经写好,只是在 `eaf8706` 被从 AR 通路摘掉了**(见 `ar_capture_page.dart:864-875` 注释)。
- ⚠️ **本次调研最重要的工程发现**:`~/Developer/pocketworld/docs/capture_guidance_signals.md`(2026-07-10)证明这套东西**不只是写好了,还用真机遥测标定过**:
  - 体素 ramp **1 拍红 / 2–3 黄 / ≥5 绿**(`coverageSaturation = 5`)—— 注意它是**逐体素**的,天生无逐点噪声;
  - 额外的低视差压黄:`parallaxMinDeg = 5.0°`(2026-07-11 由 8° 校准而来,依据:帧真值 p50=8.75°、金标 LAPa lt8=43.5% 无重影、重影厚区 5.2°);
  - 文档开头自述这两个信号就是"**学 RealityScan 的采集引导**,纯 Dart、零 native/ABI 改动"。
  ⇒ **我们曾经做对过,后来把它从 AR 通路上摘了。P2 的本质是"接回来"而不是"做出来"。**
- **工作量**:**~0.5–1 天**。主要是接线与在 `_publishOfficialSfmCloudToAr` 里插入聚合,而非新写算法。
- ⚠️ 消歧:该设计文档写的是 legacy 树 `lib/capture/`;现役树是 `lib/official_capture/`,两处都有 `capture_coverage_cloud.dart`,接线前先确认改的是现役那份。
- ⚠️ **必须核对**:`buildProgressivePointCloud`(`ar_capture_page.dart:926`)返回**置换后的副本**,颜色数组必须跟着同一个 permutation 走(`progressive_octree_order.dart:22-34` 已暴露 `progressiveOrder`)。
- ⚠️ **不违反"局部增密"禁令**:这是**上色**聚合,不新增/不删除任何点。

### P3 —— 放大点径上限,让眼睛做空间平均
- **做什么**:`arSplatMaxScreenRadius` 默认 6 → **10–12**,目标是把「直径/间距」推到 RS 的 ~0.65。
- **为什么**:Splatterplots 的核心原则——抽象在 screen space 做。近连毯让局部交错**在视网膜上混色**,而不是被逐颗解析。
- **实现面**:Swift 一行,`ios/Runner/OfficialAetherARKitPlugin.swift:2285-2291`(已有 env 覆盖 `OFFICIAL_AETHER_AR_SPLAT_MAX_PX`,可**零改码真机 A/B**)。
- **工作量**:**~10 分钟改码 + 一次真机对比**。
- ⚠️ 与 `RS_POINT_RENDERING_EVIDENCE` §7 的圆盘/抛物面建议同源,可一并做。
- ⚠️ 注意 `pointSize = 6` 是**世界单位**不是像素,别改错那一行。

### P4 —— 强化「机位缩略图弧线」(RS 真正的主力引导,我们最可能漏掉的)
- **做什么**:把已拍机位以带描边的小卡片按真实位姿摆进 AR,连成弧线。
- **为什么**:**零噪声的分区信号**,不受任何逐点指标影响;RS 在点云出现前(前 20 张)就靠它引导(`s00` 实证)。1.8 官方把它与点云并列为 AR Guidance 的两大要素。
- **实现面**:SceneKit(新增 SCNNode/billboard),位姿数据在 `SfmLiveSnapshot.poses` **已经传到 Dart**(`sfm_live_recon.dart:1369-1478` payload 含 `poses`)。
- **工作量**:**~1–2 天**(SceneKit 节点管理 + 缩略图纹理上传 + 数量上限)。

### P5 —— 分层渲染:主体 vs 环境
- **做什么**:重建框/主体范围内用全饱和色标,框外点统一降饱和/降透明度作背景。
- **为什么**:复刻 §3.2-3 的认知机制 —— 让用户的注意力被**强制**分配到任务目标上,外围雪花自然退场。
- **实现面**:Dart 上色 + 复用已有裁剪框范围。**工作量 ~0.5 天**。⚠️ 需确认采集期是否已有重建框(Review 期才有,采集期**未确认**)。

### P6 —— 引导文案 + 方向指示
- **未找到 RS 有这些**(§1.4),因此这是**超越 RS 而非复刻 RS**,需按 `feedback_o_pipeline_is_floor_not_ceiling` 的门槛(受控对照 + 质量不退)证明有效。
- ⚠️ **同样已有既成设计**:`docs/capture_guidance_signals.md` 的「动作语言表」已定案 —— 甜区 8°–30°,话术**必须教动作**("横移一大步",因为横移量≈0.14×距离才到 8°;>30° SIFT 匹配失败率飙升);**不要在文案里报体素数**("还有 1683 处区域…"既吓人又不可执行,该条明确标注为"抄 RS");不按单体素闪烁,只按"存在压黄区域"这一布尔信号提示(`parallax_banner_gate.dart` 已有去抖+滞回)。⇒ 若做 P6,**先复用这套已标定话术**,别重新发明。
- ⚠️ 反向证据:Apple HIG 主张引导期 "hide unnecessary app UI";Error Peaking 论文批评 AR 引导 "the visualizations hiding the subject to be photographed";*Don't Look Now* (CHI 2024) 甚至证明撤掉屏幕视觉反馈改走音频/触觉更好。**加元素有反效果风险,优先级最低。**

### 不建议做
- ❌ **最近邻多数滤波 / kNN 平滑**:P1+P2 已从源头解决;kNN 需新建 kd-tree(代码库中无),成本高于收益。
- ❌ **抽稀点云求可读**:违反全量交付铁律,且 §3.2-4 表明**密度是我们的朋友**不是敌人。

---

## ⑤ 未找到清单(诚实边界,别在下游当事实用)

| 问题 | 状态 |
|---|---|
| RS 采集屏的点预算 / 是否降采样 | **未找到**,官方零表述 |
| RS 采集屏 vs Review 屏的点密度对比 | **未找到**。15 张官方素材中仅 2 张含点云,**均为采集屏**,无 Review 屏点云素材 |
| RS mobile 的 quality 与桌面 tie-point quality 是否同一指标 | **推断**,无官方等号(沿用既有档案判定) |
| RS 是否做任何时间平滑 / 帧间迟滞 | **未找到**;整批重算的架构使其非必需(间接反证) |
| RS color 档是否真 RGB 取色 | **未找到**(沿用既有档案) |
| RS 采集屏是否有箭头/进度环/minimap/覆盖球/幽灵轮廓 | **实锤(负面)**:官方元素表逐项列全,无此类 |
| RS 是否有实时文字提示("keep taking pictures"等) | **未找到**。文字引导只在文档与 Quick Start Guide |
| **Polycam / KIRI / Scaniverse / Luma / Matterport 的逐家官方帮助中心措辞** | **本次未完成** —— 并行子 agent 在本文定稿时尚未返回;§② 仅含本人独立取证的平台/学术侧 |
| Apple HIG 与 ARCoachingOverlayView 原文 | ⚠️ **二手**:该页 JS 渲染,引文来自搜索快照而非亲抓正文。写进正式文档前需人工核对 |
| 我们真机上 track length 的实际直方图(P1 标定所需) | **未测**。P1 落地前必须先测 |
| 采集期是否已有重建框(P5 前提) | **未确认**;文档中裁剪框属 Review 之后的步骤 |
| RS 素材的绝对像素尺寸 | **不可信**:营销素材经缩放/再压缩;仅「直径/间距≈0.65」是尺度无关可采信量 |

### 排雷提醒
- `dev.epicgames.com` 本机直连超时,本文官方正文全部经 `https://r.jina.ai/<url>` 文本代理抓取,**可复现**,原始 URL 均已标注。
- 代码实际 checkout 在 **`main`** 而非 `ar-capture-rs`;且存在 `lib/capture/`(legacy)与 `lib/official_capture/`(现役)两套并行树,本文全部指现役树。
- 别把 `MetalRenderer.swift` 当 AR 路径 —— 那是 macOS 的 Dawn/splat 查看器。
- `sparse_cloud_view.dart:152` 的 `pointSize = 3.0` 是**草稿页 Flutter canvas**,不是 AR 路径。
