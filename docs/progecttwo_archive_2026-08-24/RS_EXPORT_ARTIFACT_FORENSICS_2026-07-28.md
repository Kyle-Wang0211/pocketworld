# RealityScan / RealityCapture 导出产物法医卷宗(2026-07-28)

**定位**:第三份 RS/RC 卷宗。前两份是官方/团队侧(`RS_TEAM_FULL_HISTORY_DOSSIER_2026-07-28.md`)与第三方观测侧(`RS_THIRD_PARTY_ANALYSIS_DOSSIER_2026-07-28.md`)。本卷只做一件事:**只用厂商主动交给用户的导出产物**(导出格式文档、官方样例代码、用户自行公开的导出文件),反推对齐管线的行为。

**边界(严格遵守)**:无 App 拆解、无抓包、无任何保护绕过。材料 = 公开文档 + 公开仓库 + 公开数据集。下载样本逐条标注许可,**不转发**。

**分级**:【实锤】= 我方亲手下载/解析/计算的一手数字,或官方文档/官方代码原文;【推断】= 由实锤推出;【三方】= 他人转述;【未找到】= 扫过且不存在。

---

## 〇、本轮头条(先说结论)

1. 🏆 **拿到并跑通了 RC 原生 Bundler 导出的完整稀疏模型**(254 图 / **586,258 点** / 1,918,113 观测,带逐点 view list)。**第一次算出 RC 的 track 长度直方图、逐图点数、2-view 占比、三角化角分布**,与我方 cap7_day 指纹逐项并列。**结论:2-view 视差角 p50 = RC 7.15° vs 我方 7.0°,几乎重合;特征漏斗效率 RC 18.9% vs 我方 19.9–36.2%,我方不劣;RC 用 4.9× 的特征预算换来 2.4× 的每图点数。**
2. 🏆 **拿到 440 份真实 RC/RS 导出 XMP + 254 行 RC 原生 CSV 内参导出**,三个独立工程一致确认:**RC 默认给每一张图独立解一套 (f, cx, cy, k1, k2, k3),永不共享相机,且 skew/aspect 冻结、切向畸变恒为 0(brown3)**。⚠️ 并且**推翻了本轮自己的中途结论**:好几何下这套自由参数化极稳(定焦机 152 图焦距 CV = **0.10%**),坏几何下才崩(另一工程 CV 11.9% + 2.3% 相机发散 3 个数量级)。
3. 🔑 **发现 RC 的报告模板引擎才是真正的"导出面"**:`$ExportPoints`/`$ExportTrack`/`$ExportPointsEx`/`$CameraErrors`/`$ComponentStats` 逐变量有官方文档,可 dump 逐点 track、逐图残差直方图、逐图注册点数、组件设置回溯、逐相机位置协方差。**其中 `$ExportPointsEx` 的 flag 枚举暴露了 RC 内部的点分类:`ill` = "apical angle is smaller than a minimal requirement"、`weak` = "unverified two-view point"** —— 与我方双墙/2-view 定案是同一套物理。
4. 🔴 **移动端法医被 Epic 官方一句话堵死**:Epic 员工在官方论坛回答手机 App 导出文件夹里是否含相对位姿:**"it is not stored there, only the images."** 移动端导出面 = USDZ/OBJ(iOS)、GLB(Android)+ 原图,**无 XMP / CSV / Bundler / COLMAP / 稀疏点云**。移动端稀疏统计不是"没人公开",是**用户手上根本不存在这种产物**。
5. ⚠️ **纠正前卷宗一条判决**:前卷宗判"移动端 RS 的第三方定量精度评测 = 空白"。本轮找到**两份**(Mainz 硕士论文 2025-08 + IMEKO TC8 2025 同行评审),两份独立指向同一病理:**系统性负向尺度偏差**(尺度偏差 1.6%、量块距离 −0.760 mm、靶标孔距 −0.829 mm、mesh 需缩放)。详见四.6b。

---

## 一、导出面清单:每种格式携带哪些可反推的统计量

RS 的 Registration 导出全表(官方 [Export Registration](https://rshelp.capturingreality.com/en-US/tools/exportregistration.htm) 的 `Save as type` 清单):RealityScan XMP、Boujou、**Bundler v0.3**、**Bundler v0.3 (negative z)**、**COLMAP Text Format**、Maya 2013 ASCII、Radiance Fields Transformation File、Internal/External Camera Parameters、逗号分隔位置、逗号分隔位置+旋转、OpenCV Intrinsics/Extrinsics、ST Maps、Undistorted images with Image List、Original images with Image List、**RealityScan Alignment Component (`.rsalign`/`.rcalign`)**、Image list、CmpMvs_P matrices。另有独立的 **Sparse Point Cloud** 导出。

| 导出面 | 内参+畸变 | 外参 | 稀疏点 | **逐点 track/观测** | 残差 | 组件 | 先验 | 图像分辨率 |
|---|---|---|---|---|---|---|---|---|
| **Bundler v0.3 / neg-Z** | 降维为 `f,k1,k2` | ✅ | ✅ | ✅ **逐点 view list(本卷实测确认)** | ❌ 格式无槽 | ❌ | ❌ | ❌ |
| **COLMAP Text/Bin**(RC 1.5+ / bin 自 RS 2.1.1) | ✅ | ✅ | ✅ | ✅ `images.txt` 侧**官方模板已实证**;`points3D.txt` 侧未证实 | ⚠️ ERROR 列是否填真值未证实 | 单组件导出 | ❌ | ✅ |
| **Sparse Point Cloud**(`-exportSparsePointCloud`) | — | — | ✅ **全量**("exports all tie points… no matter the point selection") | ❌ | ❌ | ❌ | ❌ | — |
| **RealityScan XMP** | ✅ 全量 | ✅ R(9)+C(3) | ❌ | ❌ | ❌ | ❌ | ✅ `PosePrior`/`CalibrationPrior`/两个 Group | ❌ |
| **Internal/External Camera Parameters (CSV)** | ✅ f/px/py/k1–k4/t1/t2 | ✅ x/y/alt+heading/pitch/roll | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **报告模板(`exportReport`/`printReport`)** | ✅ | ✅ | ✅ | ✅ **`$ExportPoints`+`$ExportTrack`** | ✅ **逐图 min/max/mean/sd/median + 16 桶直方图** | ✅ **组件数+逐组件统计+对齐设置** | ✅ `priorError3D` | ✅ |
| **`.rsalign` / `.rcalign`** | 🔒 | 🔒 | 🔒 | 🔒 | 🔒 | ✅(它就是组件) | 🔒 | 🔒 |
| CmpMvs_P / Boujou / Maya / OpenCV / transforms.json | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | 部分 |
| **手机 App 导出** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

### 1.1 关键实证:COLMAP 导出的 `images.txt` 默认写满 2D 观测【实锤(产品内置模板原文)】

Epic 版主与提问者在官方论坛逐字贴出了安装目录 `calibration.xml` 里 COLMAP 导出的**产品内置模板**([Cannot customize Colmap export format](https://forums.unrealengine.com/t/cannot-customize-colmap-export-format/2634244)):

```
$WriteFile("Images.txt",
#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
#   POINTS2D[] as (X, Y, POINT3D_ID)
$ExportCameras( ... $ExportTiePoints("",0,999999,
    $(x*scale+width*0.5) $(y*scale+height*0.5) $(pointIndex+1) ) ))
```

提问者的诉求恰恰是**想去掉**这段("tie points, which are included in 'images.txt' by default"),删掉后 "images.txt now has the revised header and blank lines" —— **反证默认非空**。
⚠️ `points3D.txt` 的 `TRACK[]` 段**官方与社区均无证据**,原语(`$ExportTrack`)存在且有文档,但出货模板是否用了它未证实。

### 1.2 导出侧的两个偏置陷阱(做对照时必须扣掉)【实锤】

- **RS 2.1.1 起 COLMAP 导出"filters low-accuracy points automatically during export"**([2.1.1 changelog 转述](https://digitalproduction.com/2026/04/06/realityscan-2-1-1-adds-better-colmap-support-and-new-xmp-export-options/))。⇒ 用 RS 2.1+ COLMAP 导出算出的点数是**下界**,不能与我方未过滤的点数直接比。本卷用的是 **Bundler 导出**,不受此影响。
- **视口显示 ≠ 导出内容**:Epic 员工 David Dežerický 论坛答复,视口 "filters out tie points that are 'ill-conditioned/unreliable points'",而 "the export of a sparse point cloud is exporting the whole point cloud"。⇒ 用户截图里"看起来干净"的稀疏云与导出文件不是一回事。
- **残差在 Registration 导出面上构造性不可得**:Bundler 格式无残差槽;XMP/CSV 无字段;COLMAP 的 ERROR 列真伪未证。**残差只在报告模板里**(见 1.3)。
- **附带雷**:RC 导 `FULL_OPENCV` 时只写 10 个参数(缺 k5/k6),下游训练器会报参数数错误,Epic 已确认是 bug([brush #285](https://github.com/ArthurBrussee/brush/discussions/285))。

### 1.3 真正的富矿:报告模板引擎【实锤(逐变量官方文档)】

RC 的"报告"不是固定 PDF,是 **HTML+CSS 模板 + 逐变量文档化的脚本语言**,可 `exportReport <out.html> <template>` 或 `printReport` 直接打到 stdout。预置 7 个模板,其中含 **"Tie Points of Selected Component"**(官方:"including the reprojection error and track length histograms")。

可拿到的对齐内部量(全部有官方变量文档):

- **组件级**([reports_fav_components](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_components.htm)):`componentPointCount`("a number of registered points")、`componentTotalProjection`("the total number of image projections")、`componentAverageTrackLength`("the average number of images for each observed 3D point")、`componentMaximalError`/`MedianError`/`MeanError`(px)、`componentAlignmentTime`;**以及对齐设置回溯**:`componentMaxFeaturesPerMpx`、`componentMaxFeaturesPerImage`、`componentDetectorSensitivity`、`componentPreselectorFeatures`、`componentImageDownscaleFactor`、`componentMaxFeatureReprojectionError`、`componentLensDistortionModel`、`componentFinalOptimization`。
- **逐图像**([reports_fav_cameras](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_cameras.htm)):`$CameraErrors.numPoints`(逐图 tie point 数)、`imageCoverage`、`$ReprojectionError`(min/max/mean/stdev/median/mode + 16 桶直方图)、`$TrackingError`、`$ExportRelativeCameraPositionUncertainty`(逐相机位置协方差 `posUncertCovXX..ZZ`)、`priorError3D`、`$ExportMisalignmentCameraConnections.connectionStrength`(视图图边权)。
- **逐点**([reports_fav_points](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_points.htm)):`$ExportPoints` + 嵌套 `$ExportTrack`("this function iterates all images where the point has been tracked",给 `imageIndex`/`featureIndex`/`x`/`y`)、`trackLength`("a number of images where the point has been tracked")、`$TiePointsHistogram`、`$TracksStats`("a histogram of tie points track lengths")、`GetPointCount(flags,minTrack,maxTrack)`。

**🔑 `$ExportPointsEx(flags, minTrack, maxTrack, …)` 的 flag 枚举 = RC 的内部点分类,官方逐条定义:**

| flag | 官方定义 |
|---|---|
| `active` | "active in reconstruction" |
| **`ill`** | **"apical angle is smaller than a minimal requirement"** |
| `outlier` | "invalid projection" |
| **`weak`** | **"unverified two-view point"** |
| `fixed` | "point coordinate is fixed and cannot be moved" |
| `selected` / `hidden` | 选中 / 隐藏 |

**这是本卷对未知 #2/#4 最有价值的一条**:RC 内部**明确按"视差角不足"和"未验证的 2-view 点"给点打标并允许按标志过滤**——与我方 `project_pocketworld_doublewall_root_cause`(双墙终审=视差角)与 `project_pocketworld_track_creation_r1r2_verdict`(`ignore_two_view_tracks`)是同一套物理。**外部独立佐证我方的问题分解是对的。**

**UI 侧的天花板**(纠正前卷宗一处口径):**1Ds/2Ds/3Ds 不是计数器,是视图类型**(场景树/缩略图/3D 视图)。对齐后 UI 只显示 8 个量([alignquality.htm](https://rshelp.capturingreality.com/en-US/tools/alignquality.htm)):Total projections、Average track length、Maximal/Median/Mean error(px)、Geo-referenced、Metric、Alignment time,关系式 `Total projections = Average track length × Points count`。**无 RMS、无 inlier 率、无 BA 收敛统计。**⇒ **我方 harness 量到的粒度已超过 RC 对外暴露的粒度。**

### 1.4 CLI 侧的产物形状【实锤(第三方生产脚本 + 官方命令表)】

`jacobvanbeets/SplatReady` 的公开脚本跑:
```
RealityScan.exe -headless -newScene -addFolder <imgs> -align \
  -selectMaximalComponent -exportRegistration <out> -exportUndistortedImages ...
```
作者实测注释:**"RS 2.1 creates nested: sparse/0/sparse/0/{cameras.txt,images.txt,points3D.txt}"**,**"RS 2.0 dumps .jpg files in sparse/0/"**,并多出 `imagelist.lst`。
⇒ ①RS 的 `-exportRegistration` 走 COLMAP 模板确实产出真实 `points3D.txt`;②**`-selectMaximalComponent` 是官方 CLI 一等公民,"取最大组件"是标准生产动作**,再次坐实组件碎裂是常态(前卷宗增量式判决加固)。
另:**没有** `-exportColmap` 命令(全命令表中含 "Colmap" 的只有 `importColmap`);**`-writeLog` 不存在**,日志只有一个 "Log file" 开关句,格式零文档。

---

## 二、公开样本清单(来源/许可/是否移动端/可算什么)

| # | 样本 | 来源 | 许可 | 桌面/移动 | 携带什么 | 我方实测 |
|---|---|---|---|---|---|---|
| **A** 🏆 | **RC 原生 Bundler `graduation_square_02.out`**(254 图 / 586,258 点 / 带 view list)+ 配套 `*_cam_param.csv`(RC 原生 16 列内参导出)+ kapture 转出的 COLMAP txt | [X-Intelligence-Labs/CULTURE3D](https://github.com/X-Intelligence-Labs/CULTURE3D) → Google Drive `Cambridge/GraduationSquare/export_graduation_square/`;论文 [arXiv 2501.06927](https://arxiv.org/abs/2501.06927) | ⚠️ **仓库无 LICENSE**(论文称将开源)。仅内部分析,**未再分发**;产品化引用前须联系作者 | **桌面**(DJI 无人机 152 图 + Sony DSLR 102 图) | track / 逐图点数 / 3D 点 / 逐图内参 | ✅ **全量解析,见三.1–三.3** |
| **B** | **440 份 RC/RS 导出 XMP**(单工程) | [rupertbauernfeind/gnss-denied-localization](https://github.com/rupertbauernfeind/gnss-denied-localization) `rough_matching/realityscan_positions/` | **MIT** | **桌面**(手机无 XMP 导出;`xcr:Version="3"` ⇒ RS 2.x) | 每图 f35/主点/brown3/R/C/先验字段 | ✅ **全量解析,见三.4** |
| **C** | **Epic 官方 XMP 生成器源码** | [EpicGames/RealityScan](https://github.com/EpicGames/RealityScan)(pano2views,2026-06-08 建仓,49★) | Epic 专有(RealityScan EULA)——只读引用 | 桌面(为 RS 导入准备 sidecar) | XMP 模板 + 先验语义注释 | ✅ 读源码,见三.5 |
| **D** | RC 导出的去畸变图 + `*_P.txt`(3×4 投影矩阵);RC 血统 `bundle.out`(**点段已剥离**,`12 0`) | Inria SIBR 数据集 `tree18_all.zip` / `museum_front27_all.zip` / `yellowhouse12_ulr.zip` | Inria 研究/评估用途(非商用) | 桌面 | P 矩阵、逐图去畸变尺寸 | ✅ HTTP Range 远程抽取(未整包下 GB 级) |
| **E** | 唯一公开的 `.rcalign` 原生对齐 blob(55.7 MB)+ `sfm0.dat` + **`Alignment_Settings.xml`** + 128 图 CSV | [azadbal/Ghazanchetsots_Cathedral_Shushi](https://github.com/azadbal/Ghazanchetsots_Cathedral_Shushi) | **CC-BY-4.0** | 桌面 RC 1.3.x | 私有二进制,**无解析器** | ❌ 未逆向(格式零文档) |
| **F** | RC 标定的 3×4 投影矩阵,6 场景 | [cyberagent/mvscps](https://huggingface.co/datasets/cyberagent/mvscps) | **CC-BY-NC-4.0**(禁商用) | 桌面 | 仅位姿 | ❌ 无 tie point,跳过 |
| **G** | 移动 RealityScan 成品(2022 beta,iPhone 8+/11/12P/13P) | Zenodo/Objaverse 镜像 Sketchfab:[10319791](https://doi.org/10.5281/zenodo.10319791)、[10316225](https://doi.org/10.5281/zenodo.10316225)、[10315705](https://doi.org/10.5281/zenodo.10315705)、[10313000](https://doi.org/10.5281/zenodo.10313000) 等 | CC-BY-4.0(10313000 为 CC-BY-NC-SA-2.0) | **移动** | **只有 .glb 网格** | ✅ 下载 1 份 → `generator: Sketchfab-13.6.0`,**已被 Sketchfab 转码,连网格统计都不是 RS 原生**;零对齐信息 |
| **H** | 第三方 RC 解析器(当"RC 会吐哪些字段"的权威枚举) | [Fraunhofer-IIS/camorph](https://github.com/Fraunhofer-IIS/camorph)、[nerfstudio realitycapture_utils.py](https://github.com/nerfstudio-project/nerfstudio/blob/main/nerfstudio/process_data/realitycapture_utils.py)、[SIBR rc_tools.py](https://sibr.gitlabpages.inria.fr/docs/0.9.6/HowToCapreal.html) | 各自开源 | 桌面 | 畸变模型全家族、35mm 归一化口径 | ✅ 读源码,见三.5 |

**检索规模**:已鉴权 GitHub Code Search(`xcr:DistortionModel` 479 命中 / `xcr:PosePrior` 484 / `filename:bundle.out "# Bundle file"` 42 / `imagelist.lst` 1)、HuggingFace datasets+models API(`RealityCapture`/`RealityScan`/`capturingreality` **全 0**,全文检索仅 mvscps 一真货)、Zenodo API(`RealityCapture` 923 条 / `RealityScan` 37 条,`AND colmap`/`AND bundler`/`AND "sparse point cloud"` **全 0**)、OSF API(0)、Inria SIBR 全 5 数据集远程 zip 目录枚举、Sketchfab(仅 mesh)。

---

## 三、实测法医

> 全部数字由本会话亲手计算。脚本与中间产物已落 `/Users/kaidongwang/Documents/progecttwo/_host_fixtures/rs_export_forensics/`(`parse_bundle.py`、`stats.py`、`xmp_stats.py`、`xmp_deep.py`、`remotezip.py`、`rc_xmp_rows.json`、`rc_camparam_graduation_square.csv`)。原始 69 MB `.out` 留在 `/tmp/rsforensics/`,**⚠️ `/tmp` 会被系统清空**,需长期保留请自行搬运。

### 3.1 RC 稀疏云的完整统计(样本 A,RC 原生 Bundler)【实锤】

```
# Bundle file v0.3
254 586258
```

| 量 | 值 |
|---|---|
| 相机 / 3D 点 / 观测 | 254 / **586,258** / **1,918,113** |
| **平均 track 长度** | **3.272**(中位 3,最大 47) |
| **点数 / 图** | **2,308** |
| **观测数 / 图** | **7,552**(p5 3,117 / p50 7,488 / p95 12,390 / min 1,715 / max 14,201) |
| 逐图检测特征数 | **39,973 平均,251/254 图打满 40,000** ⇒ 该工程 `Max features per image = 40,000`(与 Balabanian 实操超配 20k→40k 吻合) |
| **三角化利用率(注册观测 / 检测特征)** | **均值 18.9%**(p50 18.7%,min 4.4%,max 35.5%) |

**track 长度直方图**:

| L | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | ≥10 |
|---|---|---|---|---|---|---|---|---|---|
| 点数 | 289,767 | 139,239 | 65,130 | 34,075 | 19,397 | 12,098 | 7,710 | 5,029 | 13,813 |
| 占比 | **49.43%** | 23.75% | 11.11% | 5.81% | 3.31% | 2.06% | 1.32% | 0.86% | 2.36% |
| 累计 | 49.4% | 73.2% | 84.3% | 90.1% | 93.4% | 95.5% | 96.8% | 97.6% | 100% |

按**观测**计:2-view 占 30.21%、3-view 21.78%、4+ 占 48.01%。

### 3.2 三角化角分布(本卷最有对照价值的一组)【实锤】

逐点取所有观测相机两两夹角的**最大值**(track>8 时随机抽 8 个相机以控计算量):

| 桶 | n | p5 | p25 | **p50** | p75 | p95 | min |
|---|---|---|---|---|---|---|---|
| 2-view | 289,767 | 1.55° | 4.37° | **7.15°** | 10.63° | 19.45° | **1.146°** |
| 3-view | 139,239 | 4.55° | 9.63° | **14.39°** | 22.41° | 44.09° | 0.994° |
| 4+ view | 157,252 | 8.25° | 16.85° | **25.59°** | 40.86° | 67.16° | 1.051° |
| 全体 | 586,258 | — | — | 11.49° | — | — | **0.994°** |

**全体最小视差角 = 0.994°,<1° 的点占 0.00%,<2° 占 4.50%,<5° 占 17.08%。**

**推断(强)**:0.994° 的硬地板与官方 `ill` flag 定义("apical angle is smaller than a minimal requirement")对上——**RC 的视差角出生门约 1.0°**。我方最小视差 1.506°,**我们比 RC 严**。

### 3.3 与我方指纹的并列对照【核心表】

| 指标 | **RC(样本 A:254 图,40k 特征预算,桌面 RC)** | **我方 cap7_day(146 帧,8192 预算,端上)** | 判读 |
|---|---|---|---|
| 稀疏点总数 | 586,258 | 141,770 | 场景规模不同,不可直接比 |
| **点数 / 图** | **2,308** | **971** | RC 2.4× |
| **特征预算 / 图** | **40,000** | **8,192** | RC 4.9× |
| **三角化利用率** | **18.9%** | **19.9–36.2%**(我方漏斗审计) | **我方不劣,甚至更高** |
| **平均 track 长度** | **3.272** | 未直接量(2-view 62.4% ⇒ 估 ≈2.6) | RC 略长 |
| **2-view 点占比** | **49.43%** | **62.4%** | **RC 更少 2-view(此项 RC 占优)** |
| **视差角 p50,2-view** | **7.15°** | **7.0°** | **几乎重合** |
| 视差角 p50,3-view | 14.39° | 11.7° | RC 略高 |
| 视差角 p50,4+ view | 25.59° | 20.8° | RC 略高 |
| **最小视差角(出生门)** | **0.994°** | **1.506°** | **我方更严** |
| 相机模型 | **每图独立 (f,cx,cy,k1,k2,k3)** | **单相机首帧固化、内参锁死** | 架构级分歧 |
| 切向畸变 | **恒 0**(brown3,三工程一致) | — | — |
| 逐点重投影残差 | **导出面上拿不到**(仅报告模板可出直方图) | 可算 | 我方粒度更细 |
| 组件数 | 多组件常态(`-selectMaximalComponent` 是官方标准动作) | 恒 1(ARKit 逐帧注册) | 我方构造性单组件 |
| 交付降采样 | RS 2.1.1 COLMAP 导出**自动过滤低精度点** | 全量交付(铁律) | 我方口径更严 |
| 粗飞点率 | 超出相机簇半径 3×(>304 m)的点 **0.0138%**,其中 48.1% 是 2-view | 我方地板下鬼层 ~3.2%(不同度量,**不可直接比**) | 明确标注不可比 |

**读法(诚实版)**:
1. **稀疏几何质量本身,我方与 RC 同级**——2-view 视差角 p50 7.0° vs 7.15° 是本卷最强的 parity 证据。
2. **漏斗效率我方不劣**(18.9% vs 19.9–36.2%),RC 的点数优势**纯粹买自 4.9× 的特征预算**。这直接支持我方"不抬 8192"的定案:抬预算能换点数,但换不到效率,而端上预算是热/功耗硬约束。
3. **唯一 RC 占优的项是 2-view 占比(49.4% vs 62.4%)**。但两者拍摄形态不同(RC 是 254 张无人机+地面 DSLR 混拍的大广场,视角多样性天然高;我方是 146 帧序列扫掠)。**这是本卷唯一一处 RC 看起来更好的数字,标为"待受控复核",不因此改判。**
4. **地板下鬼层 3.2% 与 RC 的 0.0138% 粗飞点率不是同一个度量**,不要拿来自我打击——RC 的对照量需要地面平面才能算,本样本无。

### 3.4 相机内参:三工程一致的行为 + 一次自我推翻【实锤】

**共同点(样本 A + B + D 三个独立工程一致)**:
- **每图独立解算**:样本 A 的 CSV 254/254 焦距互不相同;样本 B 的 XMP 440/440 焦距与主点互不相同,`CalibrationGroup = DistortionGroup = -1`;样本 D 的 bundle.out 12 相机焦距全不同。
- **畸变模型恒为 brown3(3 径向、零切向)**:样本 B 的 `DistortionModel="brown3"` 440/440,`DistortionCoeficients` 后 3 位恒 0;样本 A 的 CSV `k1,k2,k3` 全非零、`k4=t1=t2=0` 254/254。
- `Skew=0`、`AspectRatio=1` 全部冻结,未参与解算。
- 旋转矩阵 det = +1.000000000(440/440),`max|RRᵀ−I|` 中位 8.9e-16,15 位有效数字 ⇒ 双精度直出。

**⚠️ 本卷中途结论被自己的第二个样本推翻,必须记录**:

| 工程 | 相机 | n | f35 变异系数 | 主点偏心 \|pp\| p50 | 发散相机 |
|---|---|---|---|---|---|
| **样本 A · DJI 无人机(定焦)** | 单一定焦 | 152 | **0.10%**(截尾 0.08%) | **0.0038** | 0 |
| 样本 A · Sony DSLR | **变焦**(29–181 mm) | 102 | 50.9% | 0.0189 | —(变焦是真实的,非病态) |
| **样本 B · gnss 工程** | 单一定焦 | 430 | **11.87%**(1 m 高度带内仍 8.66%) | **0.1041** | **10/440 = 2.27%**,f35 最高 12,926 mm、位置错到 4,019 m |

**修正后的结论**:
- **好几何下,RC 的"每图自由内参"极稳**:同一台定焦机 152 张图,焦距一致到 **0.10% CV**,主点偏心仅 0.38% 图幅。这套参数化本身不是缺陷。
- **坏几何下,同一套自由度会崩**:样本 B 里焦距 CV 8.7–11.9%,**corr(f35, 相机高度) = +0.667**(train 0.550 / test 0.691;**把高度压到 1 米带内仍有 0.559**,排除"确实在不同高度飞"的平凡解释),主点偏心中位到 10.4% 图幅,k2/k3 符号乱翻(CV 1013%/1669%),并且 **2.27% 的相机内参发散 3 个数量级、位置错 1000 倍**(id 2610–2613 连续 4 张集体失稳)。
- ⇒ **这是 ISPRS 2020 圆顶失效的机制层证据**:焦距在吸收深度/尺度。前卷宗只有"结果"(±1 m 圆顶),本卷补上"过程"(逐图内参与高度锁死相关),并进一步证明 **RC 会把发散到 3 个数量级的相机原样写进导出,而导出面上没有任何残差/质量/置信度字段可供下游辨别**——想识别只能靠下游自己做统计离群检测(本卷就是这么做的)。这与 ISPRS 2020 "reproj 恒 0.5 px 与全局几何无关" 是同一件事的两面。

### 3.5 先验语义:`CalibrationPrior` 与 `PosePrior` 正交,官方代码亲证【实锤】

Epic 自家 [pano2views](https://github.com/EpicGames/RealityScan) `app.js`(2026-06)的注释与模板:

```js
// Minimal RealityScan XMP sidecar: fixed calibration only, no pose.
// CalibrationPrior="exact" tells RS not to refine the intrinsics.
// No xcr:Rotation / xcr:Position / xcr:PosePrior — alignment solves pose freely.
```
模板:`xcr:Version="3" xcr:DistortionModel="perspective" xcr:DistortionCoeficients="0 0 0 0 0 0" xcr:FocalLength35mm=… xcr:Skew="0" xcr:AspectRatio="1" xcr:PrincipalPointU="0" xcr:PrincipalPointV="0" xcr:CalibrationPrior="exact" xcr:CalibrationGroup="-1" xcr:DistortionGroup="-1" xcr:InTexturing="1" xcr:InMeshing="1"`,焦距 `f35 = 18 / tan(fov/2)`。

**相对前卷宗的增量**:
1. **`PosePrior` 与 `CalibrationPrior` 是两个独立字段**——前卷宗把 draft/exact/locked 当成一套整体先验;Epic 官方代码证明可以"锁内参、放开位姿"。**这正是我们的形态**(内参锁死 + 位姿有 ARKit 先验),说明该形态在 RC 语义里是一等公民。
2. **`xcr:Skew` / `xcr:AspectRatio` 是一等字段**(前卷宗缺)。RC 内部相机模型是完整 5 自由度仿射 K + Brown,比 COLMAP 标准模型更一般,只是默认冻结。
3. **畸变模型全家族 = 6 种**:`brown3` / `brown4` / `brown3t2` / `brown4t2` / `division` / `perspective`(枚举来自 camorph 完整分支 + Epic 代码的 `perspective`)。前卷宗只有 3 种。
4. **导出侧先验值是 `initial`**(样本 B 440/440 `PosePrior="initial"` `CalibrationPrior="initial"` `Coordinates="absolute"`),与文档的导入侧 draft/exact/locked 是不同取值域。
5. `xcr:Version="3"` 与命名空间 `xcr/1.1` 解耦,解析器**不能用 namespace 判版本**。
6. **35mm 归一化的 max(w,h) vs width 分歧被定位**:camorph 用 `sensor = (36, 36·h/w)` 即 **width=36 mm**;nerfstudio 与官方 KB 用 `max(w,h)`。**横幅图两者等价,分歧仅影响竖幅图**——前卷宗记的"未决分歧"可以收窄到这一条件。

### 3.6 序列化陷阱(写解析器必看)【实锤】

样本 B 同一份导出里 `xcr:Position` **有两种写法**:398/440 是子元素 `<xcr:Position>…</xcr:Position>`,42/440 是属性 `xcr:Position="…"`;`xcr:Rotation` 则 440/440 都是子元素。**只认子元素形式的解析器(含 camorph)会静默丢掉 ~10% 的位姿。**

### 3.7 交叉验证:我方实测数字 vs 已发表数字【实锤 + 三方】

本卷的一手测量与既有公开发表物**互相印证,且我方的数字落在已发表带内**:

| 我方实测(样本 A) | 已发表对照 | 判读 |
|---|---|---|
| **平均 track 长度 3.272** | **MIT 硕士论文**(Denmark, MIT MEng 2020,[PDF](https://dspace.mit.edu/bitstream/handle/1721.1/129202/1227275209-MIT.pdf?sequence=1&isAllowed=y))Table 7.1 给出 7 个 RC 工程的 average track length:**2.99 / 3.08 / 3.15 / 3.29 / 3.4 / 4.88 / 4.98**;野生 Sketchfab alignment report 截图 **4.7617**([ssh4 合成测试](https://sketchfab.com/3d-models/synthetic-test-realitycapture-b014299cbcfa47ddb351612a0c82ea6d)) | **我方 3.272 落在 RC 实测带 2.99–4.98 的中位附近**,测量方法可信 |
| **该工程 `Max features per image = 40,000`**(251/254 图打满) | 同一份 Sketchfab report 的设置栏:**max features 40000 / detector Medium / preselector 10000 / max reprojection error 0.01 / Brown3**;Balabanian 实操超配 20k→40k | **三源独立吻合**;并**再次证实 Brown3 是 RC 的默认畸变模型**(与三.4 的三工程实测一致) |
| **点数/图 2,308、观测/图 7,552** | Gabara & Sawicki, **Sensors 2018, 18(3):791**([PMC5876754](https://pmc.ncbi.nlm.nih.gov/articles/PMC5876754/),RC v1.0.2.2256,**6 张**极近景):84,728 tie points ⇒ **≈14,121/图**;CRBeDaSet 36 图 ⇒ 1,217/图;圣约翰主教座堂 91,721 图 ⇒ ≈1,496/图 | **RC 每图 tie point 跨度 1.2k–14.1k,由 block 几何决定,不是软件常数**。⚠️ 这**推翻**了前卷宗"RC ≈1.1k–6k/图"的上界认知 |
| 2-view 占 **49.43%** | 对照坐标:**COLMAP** 有效 MTL 带 **3.60–4.20**([Research Square rs-8709145,未同评](https://www.researchsquare.com/article/rs-8709145/v1_covered.pdf?c=1));**Metashape** 航空块 track length **3.72**(arXiv 2411.08712 Puck Lagoon) | **RC 的平均 track 并不比 COLMAP/Metashape 显著更短**;RC 的低 ATL 更像是"背景 2-view 杂点拉低均值"(与 CRBeDaSet 观察到 RC 大量 tie point 落在草/树/车上吻合) |

**⚠️ 一条必须消化的负面证据**:MIT 论文摘要原文 —— "these metrics do not provide meaningful insight to the model's quality"。其表内**质量最好的模型(Hercules,>8000 张 RAW)ATL 最低(2.99)**,而 ATL 最高的珊瑚(4.98)质量并不更好(作者归因于深海黑背景没有背景特征去拉低均值)。⇒ **mean track length 是场景/背景属性的函数,不是质量指标;不能拿它当端上验收门。**上面那条 COLMAP 的 3.60–4.20 "有效带"只在"同一构件、只变图数"的受控条件下成立。

**RC 对齐失败率的公开硬数据**(补 #1 组件问题):
- MIT 论文玩具船实验:sparse(112 张)+JPG1 时,**最连通 component 只注册了 41/112 = 36%**;其余组注册率 75–89%。
- [ISPRS Annals X-M-2-2025, 215](https://isprs-annals.copernicus.org/articles/X-M-2-2025/215/2025/isprs-annals-X-M-2-2025-215-2025.pdf)(同行评审):6 件韩国文物,**RC 与 COLMAP 均只有 2 件对齐成功**;Chimi(167 张)"appeared as two separate fragments"。
- [Data in Brief 2020, PMC7557925](https://pmc.ncbi.nlm.nih.gov/articles/PMC7557925/)(RC BETA 1.0.3.9696,同一机房三设备):Nikon D810 **84.4%**、iPhone XS **95.7%**、iPhone 6 **48.8%** 注册率。
- **圣约翰主教座堂**(arXiv 2604.24316,已逐条核实):RC **v1.5.1**、91,721/93,066 = 98.6% 注册进**单一 component**,但**靠 108 个手工控制点**桥接自动对齐失败的多个 component;对齐耗时 ≈24 h(检测 1.5 h + 注册 22.5 h);137.2M tie points、mean reproj 0.26 px、过滤阈值 2.00 px。**该论文不报告 track length 分布、逐图点数、残差直方图、交会角统计。**

### 3.8 去畸变导出的形态指纹【实锤】

- 样本 A 的 COLMAP `cameras.txt`:254 相机对应 254 图(**一图一相机**),模型 `PINHOLE`,`fx == fy` 严格相等,`cx = W/2`、`cy = H/2` 严格居中 ⇒ 导出的是**已去畸变**图像。
- 样本 D 的 `scene_metadata.txt`:12 张图分辨率**全不相同**(2090×1251 / 2116×1248 / 2108×1248 / 2114×1251 …)⇒ RC 的 "undistorted, fit=Inner_region" 逐图裁剪。
- 样本 D 的 `capreal/undistorted/*_P.txt`:内容仅 `CONTOUR` + 3×4 投影矩阵。

---

## 四、对 19 项未知的二次收口(仅列相对第三方卷宗的**增量**)

| # | 未知项 | 本卷增量 | 分级 |
|---|---|---|---|
| 1 | incremental vs global | `-selectMaximalComponent` 是官方 CLI 一等公民且被第三方生产脚本常规使用 ⇒ **多组件是官方预期的常态输出**;报告变量有 `$IterateComponents` 与逐组件 `componentAlignmentTime` | 【实锤(官方)】 |
| **2** | **检测器身份** | 仍零约束,但**新增两条侧面**:①该工程 `Max features per image = 40,000` 且 251/254 图打满 ⇒ 检测器可稳定产出 4 万点/图;②**三角化利用率只有 18.9%** ⇒ RC 的前端同样是"广撒网+低转化",与我方漏斗审计(19.9–36.2%)同量级。检测器身份在导出面上**构造性不可达**(无描述子导出) | 【实锤(行为)+ 未找到(身份)】 |
| 3 | 匹配/preselector | `componentPreselectorFeatures` 可从报告回溯设置;机制内幕仍无 | 【三方】 |
| **4** | **内部 BA / 自标定** | **大幅收口**:①每图独立解 (f,cx,cy,k1,k2,k3),skew/aspect 冻结,切向恒 0(三工程一致);②好几何下 CV **0.10%**,坏几何下 CV **11.87%** + **corr(f35,高度)=0.56–0.69** + **2.27% 相机发散 3 个数量级且导出零标记**;③官方只对外暴露 5 个对齐质量标量(total projections / avg track length / max·median·mean 重投影误差),**无 RMS、无 inlier 率、无 BA 收敛统计** | 【实锤(一手实测+官方文档)】 |
| 5 | RS 2.0 "smarter alignment" | 仍无 before/after 定量;但 RS **2.1.1** changelog 首次给出可核实的导出行为变更 | 【实锤(官方 changelog)】 |
| **6** | **移动端特征预算 / 每图点数** | **由"没人公开"改判为"结构性不可得"**:Epic 员工官方论坛原话 **"it is not stored there, only the images."**;移动导出面 = USDZ/OBJ(iOS)、GLB(Android)+ 原图;公开的移动 RS 产物(Zenodo/Objaverse)全是 Sketchfab 转码 .glb。⚠️ 灰区:官方 Project Files 文档确实提到设备上 session 文件夹含 "point cloud and camera files",但**格式/语义/坐标系零文档、零社区逆向**,属未验证路径,**不可当方案规划** | 【实锤(缺席可复核)】 |
| **6b** | **⚠️ 纠正前卷宗:移动端 RS 的定量精度评测不再是空白** | 前卷宗判"RealityScan Mobile 在精度文献中系统性缺席"。本轮找到**两份**:①**Mainz 应用技术大学硕士论文**(Bärwinkel 2025-08,德语,[PDF](https://www.dot3d.app/s/Masterarbeit_Lukas_Baerwinkel.pdf)):iPhone 12 Pro × 6 App vs FARO TLS 真值,**RealityScan 总分 41/73 排第 4/6**;**尺度偏差 1.6%**、ICP RMS 0.020 m、**M3C2 面偏差 RMS 0.0726 m**(LOA10 上限 0.075,擦线)、表面点密度 41,214 P/m²、球半径缩放后仍偏 −0.0071 m;判词 "homogene, aber falsch skalierte Punktwolke"(均匀但**尺度错了**的点云),球/柱普遍成棱面。⚠️ **利益冲突:托管方 DotProduct 是该文冠军 Dot3D 的厂商**,原始数据表可复核但排名需打折。②**IMEKO TC8 2025**(同行评审,[PDF](https://www.imeko.org/publications/tc8-2025/IMEKO-TC8-11-24-2025-028.pdf),DOI 10.21014/tc8-2025.028,~60 张/组,70–110 mm 被测件):量块距离偏差 **−0.760 mm**、靶标孔距 **−0.829 mm**、球杆 −0.171 mm、平面度 0.251 mm、45°/90° 角偏差 0.206°/−0.163°。**两份独立来源都指向同一病理:系统性的负向尺度偏差**(距离量普遍偏小、mesh 需缩放)。这与我方记忆库里的双墙/球壳歧义同源。**⇒ 移动 RS 的成品有可量化的尺度问题;我方 ARKit VIO 米制尺度 + 重力先验在这一项上构造性占优** | 【实锤(其中 1 篇同行评审)】 |
| 8 | 20/300 限额 rationale | 无增量 | 【未找到】 |
| 10 | 重建搬端上表态 | 再加固:移动导出面停留在成品网格,与"云端出成品"完全自洽;1.5 release notes 反证 "Cropping now happens on your device instead of on the server" ⇒ 端上只做裁剪 | 【推断(强)】 |
| 12 | 云基础设施 | 无增量(本卷不做网络分析) | 【未找到】 |
| 18 | 已删档 staff 帖 | 无增量 | 【未找到】 |
| **19** | **官方典型 tie point 数** | **首次拿到逐点级一手数据**:2,308 点/图、7,552 观测/图、平均 track 3.272、2-view 49.43%(样本 A)。**⚠️ 同时推翻前卷宗的"1.1k–6k/图"上界**:Sensors 2018(RC v1.0.2.2256,6 张极近景)实测 **≈14,121 tie points/图**。**RC 每图 tie point 的真实跨度是 1.2k–14.1k,由 block 几何(重叠度/物距/图数)决定,不是软件常数**——拿单一数字当端上目标是错的,要按视差/重叠分档。官方文档对 average track length 只说"越高越好"、对 median/mean error 说 "ideally under 0.5px",**不给任何典型数值区间** | 【实锤】 |
| **新增** | **track length 不能当质量门** | MIT 硕士论文构造性反证:其表内质量最好的模型 ATL 最低(2.99),ATL 最高的(4.98)质量并不更好;摘要原文 "these metrics do not provide meaningful insight to the model's quality"。⇒ **若我方打算用 track length 做端上验收门,这是必须先消化的负面证据** | 【三方(学位论文)】 |
| **新增** | **相机模型与先验语义** | 6 种畸变模型全枚举;`PosePrior` ⊥ `CalibrationPrior`(Epic 官方代码亲证);Skew/AspectRatio 一等但默认冻结;35mm 归一化分歧收窄到"仅竖幅图" | 【实锤】 |
| **新增** | **RC 内部点分类** | `$ExportPointsEx` flags:`active`/**`ill`(视差角不足)**/`outlier`(无效投影)/**`weak`(未验证 2-view 点)**/`fixed`/`selected`/`hidden` —— RC 内部**也**把低视差点与 2-view 点单列并允许过滤,外部佐证我方双墙/2-view 定案的问题分解 | 【实锤(官方文档)】 |
| **新增** | **RC 的视差出生门** | 实测最小三角化角 **0.994°**,<1° 占 0.00% ⇒ 门槛 ≈1.0°;我方 1.506°,**更严** | 【实锤(实测)+推断(门槛值)】 |

---

## 五、未找到清单(明说)

1. **RC 1.5+ 原生 COLMAP exporter 的公开产物**——一份都没有。样本 A 的 COLMAP 三件套是 **RC → Bundler `.out` → kapture → COLMAP** 转出来的(header 写 `# Sensor list … # NB cameras : 254`,是 kapture 的 writer 签名,不是 COLMAP 官方的 `# Number of cameras:`),因此 **ERROR 列全 0**。GitHub code search 12+ 条 query 全空(客观原因:`points3D.txt` 通常 >350 KB,GitHub code search 不索引大文件)。
2. **`points3D.txt` 是否带 `TRACK[]`、Bundler `.out` 的 view list 是否被 RC 官方模板填充**——本卷用样本 A 证明了**RC 导出的 `.out` 确实带 view list**(1,918,113 条观测被我方逐条读出),但**不能反推 RC 原生 COLMAP exporter 的 points3D 是否也带 track**。仍属未证实。唯一可靠裁决 = 在装了 RealityScan 的 Windows 机上导一份样本 `awk` 数行尾字段。
3. **逐点重投影残差的任何导出通道**——Bundler 无槽、XMP/CSV 无字段、COLMAP ERROR 列真伪未证。**只有报告模板能出直方图**(`$ReprojectionError` 16 桶、`$TiePointsHistogram`),不给逐点值。
4. **移动端的任何对齐产物**——见四.6,**构造性不存在**。
5. **`.rsalign`/`.rcalign`/`.rcproj`/`sfm0.dat` 的格式**——零公开逆向。官方 [defineexportformat.htm](https://rshelp.capturingreality.com/en-US/tools/defineexportformat.htm) 显示 `.rsalign` 的 writer 是 `rca`,属"无 `<body>` 元素的 writer"名单 ⇒ **二进制内建格式,模板语言读写不了**。样本 E 是全网唯一一份公开的 `.rcalign`(CC-BY-4.0,55.7 MB),留作未来逆向标的。
6. **RC 对齐期日志的字段**——只有一个 "Log file" 开关句;`-writeLog` 命令不存在;`-writeProgress` 格式有文档但只有 5 列进度信息,**无特征数/逐图点数/组件合并**。
7. ⚠️ **一处曾疑似命中、核对后不采信的数字**:UE 论坛 [1212467](https://forums.unrealengine.com/t/error-while-opening-colmap-text-format/1212467) 里的 cameras.txt 14 KB / images.txt 1.07 GB / points3D.txt 109 MB / 1093 图 / 867,487 点——**逐帖核对后判定那是 COLMAP 自己的导出,用户拿去导入 RC 的**,不是 RC 产物,**不入账**。

8. **公开发表物里,RC 的下列统计量一条都没有**(25+ 条学术检索,Crossref 全库 `"RealityScan"` 仅 3 条,MDPI 全系零命中):track length **分布/直方图**(只有 MIT 论文的 7 个均值)、**逐图注册点数**、**残差直方图**(只有 mean/median 单值)、**交会角/apical angle 统计**(RC 自己有这个工具,但没人发表数值)、**组件数**(只有 MIT 的 41/112 与 ISPRS Annals 的"裂成 2 片")。
9. **未能取得的两处**:Kingsland《Comparative analysis of digital photogrammetry software for cultural heritage》(DAACH 2020)全文被付费墙/反爬挡住,其 tie point 表未取得(**建议后续用机构权限取**);Epic Dev Community 两个教程页(`.../tutorials/yXol`、`9Xld`)反复超时未抓取,**可能含示例数值,是已知缺口**。

**两处口径纠正(前卷宗/常见误解)**:
- **1Ds/2Ds/3Ds 不是计数器,是视图类型**(场景树/缩略图/3D 视图),不能当 features/observations/points 三级计数读。
- **移动端仍是 1.x 线(1.8.1),2.x 是桌面版**;桌面的 registration 导出能力**一条都没下放到手机**。旧站 `rchelp.capturingreality.com` 已 301 到 `rshelp.*`。

---

## 六、对"稀疏侧零落后"判决的影响

**维持"零落后",并且第一次从 parity 猜测升级为 parity 实测。**

- **✅ 最强新证据(parity)**:2-view 三角化角 p50 **RC 7.15° vs 我方 7.0°**,3-view/4+ 也只差 2–5°。**这是首次拿到 RC 逐点级几何质量并与我方并列,结论是同级。**
- **✅ 效率证据**:三角化利用率 RC **18.9%** vs 我方 19.9–36.2%,**我方不劣**;RC 的 2.4× 每图点数完全买自 4.9× 特征预算。**直接加固"不抬 8192"的定案**——抬预算买点数不买效率,而端上预算是热/功耗硬约束。
- **✅ 严格度证据**:视差出生门 RC ≈**0.994°** vs 我方 **1.506°**,我方更严;交付侧 RS 2.1.1 起 COLMAP 导出自动过滤低精度点,我方全量交付。
- **✅ 架构证据(升级为实锤)**:RC 每图自由内参在坏几何下会崩(CV 11.9%、corr(f35,高度) 0.56–0.69、2.27% 相机发散 3 个数量级且导出零标记);我方单相机首帧固化+内参锁死,**这个自由度我们根本没放开**——不是"做得更好",是构造性免疫。⚠️ 同时诚实记录:**好几何下 RC 这套极稳(CV 0.10%)**,不能拿坏样本当 RC 的常态。
- **✅ 外部佐证**:RC 内部 `ill`(视差角不足)/`weak`(未验证 2-view 点)两个官方点分类,与我方双墙终审、`ignore_two_view_tracks` 定案是同一套物理——**我方的问题分解与行业最成熟的商业实现同构**。
- **⚠️ 唯一一处 RC 数字更好**:2-view 点占比 **RC 49.4% vs 我方 62.4%**。**不因此改判**,但列为**待受控复核项**:两者拍摄形态不可比(RC 是 254 张无人机+地面 DSLR 混拍的大广场,视角多样性天然高;我方是 146 帧序列扫掠)。若要真裁决,需在同一场景同一批图上跑对照。
- **⚠️ 不可比项**:我方地板下鬼层 3.2% 与 RC 粗飞点率 0.0138% **不是同一个度量**,不要拿来自我打击。
- **✅ 移动端子域新增正面证据**(纠正前卷宗"无对手数据"):两份独立研究(Mainz 硕士论文 + IMEKO TC8 2025 同行评审)都测出移动 RS 有**系统性负向尺度偏差**(1.6% / −0.76 mm / −0.83 mm,mesh 需缩放才对得上真值)。我方 ARKit VIO 米制尺度 + 重力先验在这一项上构造性占优。**前卷宗"移动子域无对手数据可比"应改为"有数据,且对手在尺度上有可量化缺陷"。**
- **📌 新增的方法论风险(三条)**:
  1. 未来若用 RS 2.1+ 的 COLMAP 导出算 RC 点数,**必须扣掉导出侧的低精度点过滤偏置**,否则会低估 RC 而误判我方领先。
  2. **不要用 mean track length 做端上验收门** —— MIT 论文构造性反证(最好的模型 ATL 最低),官方文档也只说"越高越好"不给区间。
  3. **不要拿单一"每图 tie point 数"当目标** —— RC 实测跨度 1.2k–14.1k,完全由 block 几何决定;要按视差/重叠分档。
- **🔧 一条可行动的下一步(比继续查文献高效)**:RC 自带 `$TracksStats`("a histogram of tie points track lengths")+ `$TiePointsHistogram` + 内置模板 "Tie Points of Selected Component",在装 RealityScan 的 Windows 机上跑一次 `-exportReport` 就能直接拿到 RC 的 track 长度与残差直方图,同时可一并 `awk` 数 `points3D.txt` 行尾字段数,关掉五.2 的未证实项。

**总判决:维持"稀疏侧零落后差距";证据等级由【第三方论文的量级推断】升为【逐点级一手实测 parity】,方向不变。唯一新出现的可疑落后项(2-view 占比)标为待受控复核,不构成改判。**

---

## 附:一手材料与脚本

- 落盘位置:`/Users/kaidongwang/Documents/progecttwo/_host_fixtures/rs_export_forensics/` —— `parse_bundle.py`(RC Bundler 全量解析)、`stats.py`(track/逐图/视差角/网络统计)、`xmp_stats.py`·`xmp_deep.py`(XMP 字段与内参散布)、`remotezip.py`(HTTP Range 远程读 zip 中央目录、只抽单成员,避免下载 GB 级包)、`rc_xmp_rows.json`(440 行解析结果)、`rc_camparam_graduation_square.csv`(RC 原生 16 列内参导出,254 行)、**`rc_bundler_graduation_square_derived.json`**(样本 A 的全部派生数据:track 长度直方图、254 图逐图观测数与检测特征数、254 个 bundler 焦距、254 个相机中心 —— 24 KB,**即使原始 69 MB `.out` 丢失也可复算大部分结论**)。
- 原始大文件(69 MB `.out`、46 MB `points3D.txt`、39 MB `images.txt`)留在 `/tmp/rsforensics/culture3d/`,**⚠️ `/tmp` 会被系统清空**;重下地址见样本 A 行(Drive file id `1BVoPzhj4PbqjL9QhC1M4eiokl-owsPEL`,需带 `confirm=t` 绕病毒扫描确认页)。
- **许可与再分发**:样本 A(CULTURE3D)**仓库无 LICENSE**,仅内部分析,未再分发;样本 B MIT;样本 E CC-BY-4.0;样本 F CC-BY-NC-4.0(未使用);样本 G CC-BY-4.0/CC-BY-NC-SA-2.0;Inria SIBR 为研究/评估用途。
- 核心链接:[Export Registration](https://rshelp.capturingreality.com/en-US/tools/exportregistration.htm) · [XMP](https://rshelp.capturingreality.com/en-US/tools/xmpalign.htm) · [点报告变量](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_points.htm) · [相机报告变量](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_cameras.htm) · [组件报告变量](https://rshelp.capturingreality.com/en-US/appbasics/reports_fav_components.htm) · [Alignment report 面板](https://rshelp.capturingreality.com/en-US/tools/alignquality.htm) · [CLI](https://rshelp.capturingreality.com/en-US/tutorials/commandline_1.htm) · [EpicGames/RealityScan](https://github.com/EpicGames/RealityScan) · [CULTURE3D](https://github.com/X-Intelligence-Labs/CULTURE3D) · [COLMAP 导出模板论坛帖](https://forums.unrealengine.com/t/cannot-customize-colmap-export-format/2634244) · [移动端不导位姿(Epic 员工)](https://forums.unrealengine.com/t/possibility-to-export-reality-scan-images-with-camera-pose-to-reality-capture/2115522) · [SIBR RC 教程](https://sibr.gitlabpages.inria.fr/docs/0.9.6/HowToCapreal.html) · [camorph](https://github.com/Fraunhofer-IIS/camorph) · [RS 2.1.1 changelog 转述](https://digitalproduction.com/2026/04/06/realityscan-2-1-1-adds-better-colmap-support-and-new-xmp-export-options/)
- 本卷新增的学术/评测来源:[MIT MEng 论文(RC track length 表)](https://dspace.mit.edu/bitstream/handle/1721.1/129202/1227275209-MIT.pdf?sequence=1&isAllowed=y) · [Sensors 2018 18(3):791](https://pmc.ncbi.nlm.nih.gov/articles/PMC5876754/) · [ISPRS Annals X-M-2-2025 215](https://isprs-annals.copernicus.org/articles/X-M-2-2025/215/2025/isprs-annals-X-M-2-2025-215-2025.pdf) · [Data in Brief 2020 PMC7557925](https://pmc.ncbi.nlm.nih.gov/articles/PMC7557925/) · [Sketchfab 野生 alignment report](https://sketchfab.com/3d-models/synthetic-test-realitycapture-b014299cbcfa47ddb351612a0c82ea6d) · **移动端**:[Mainz 硕士论文 2025](https://www.dot3d.app/s/Masterarbeit_Lukas_Baerwinkel.pdf)(⚠️利益冲突)、[IMEKO TC8 2025](https://www.imeko.org/publications/tc8-2025/IMEKO-TC8-11-24-2025-028.pdf) · 对照坐标:[COLMAP MTL 预印本](https://www.researchsquare.com/article/rs-8709145/v1_covered.pdf?c=1)(未同评)、[arXiv 2411.08712 Metashape](https://arxiv.org/abs/2411.08712)
