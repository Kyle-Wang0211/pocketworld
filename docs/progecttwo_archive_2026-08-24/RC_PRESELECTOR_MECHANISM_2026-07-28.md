# RealityCapture 配对预选机制逆向 + 端上候选选择方案

**日期**:2026-07-28
**任务**:尽可能精确地逆向 RC 的"两级候选漏斗"(据称让匹配近线性而非 O(N²)),并映射到端上可实现方案
**方法**:四路并行联网检索(官方文档/CLI 键表/存档论坛/专利库/论文/基准) + 读我方 vendored COLMAP 源码 + **本会话在两个真实 capture 上做的首次实测**
**分级约定**:【实锤】= 官方文档/员工原话/一手数据 · 【三方】= 第三方受控实测 · 【推断】= 有证据的推理 · 【未找到】= 已确认检索无果

---

## 🔴 三句话判决

1. **RC 的 `Preselector features` 根本不是图像对预选,而是"每图从 40k 检出特征里挑 10k 拿去对齐"的特征筛选器。** CR 员工原话钉死。**没有"两级配对漏斗"可抄** —— RC 的配对候选策略零文档、零专利、零日志表面。
2. **"RC 近线性"那句被广泛转引的话出自一句无引用的 Wikipedia**;官方自己说的"线性"是**内存**线性(`RAM = features × images × 200 bytes`,官方公式,逐位可验)。而被当作时间证据的 Falkingham 397 s / 593 s **是全管线时间,对齐只占 1–2.6%** —— 那两个数根本无法说明匹配的复杂度。
3. **我们不需要 RC 的机制,因为我们有 RC 没有的东西:ARKit 逐帧 6-DoF 米制位姿。** 本会话实测:纯位姿(零外观信息)`1.0 m / 45°` 的门**砍掉 31% 匹配预算只损失 2.4% inlier**;等预算把盲发的 2^k 长程对换成位姿选出的 revisit 对,**长程 inlier ×3.0–3.3**(双 capture 一致)。**选择本身的成本 <1 ms(N=300),相对 55 ms/对是 10⁻⁵ 量级。**
   ⚠️ **但我方这套打分有一个必须先修的缺陷**:它以 inlier 数为目标,会系统性地偏向低视差的近邻对,
   而低视差正是我方鬼层/双墙的病因。**必须按 MVSNet 的非对称三角化角项(θ₀=5°,视差不足罚 10×)修正**(③.8)。
   **两条独立文献先例说明这样做不亏反赚**:cuSfM(**7× 更少配对、每项指标都更好**)、
   MASt3R-SfM(**6.9% 的配对 ATE 优于完全图**)。
   **track 长度的量级预期由 ENFT 给定:同 regime 从纯时序 2.28 → 加非连续匹配 3.10(+36%),
   且反超暴力全配对的 2.71。**

---

## ① RC preselector 机制拼图

### ①.0 🔥头号结论:`Preselector features` 不是图像对预选

**这条推翻了本任务的立项前提,也推翻了我方前一份卷宗
(`RS_TEAM_FULL_HISTORY_DOSSIER_2026-07-28.md` §四 第 2 行"preselector 用检出特征 1/4-1/2 子集**先选图像对**")的写法。**

| 证据 | 内容 | 分级 |
|---|---|---|
| CR 员工 "Wishgranter",帖 *Disable preselector*(2016-03-07)[存档](http://web.archive.org/web/20220211195938/https://support.capturingreality.com/hc/en-us/community/posts/115001356352-Disable-preselector) | 提问者原话推测"preselector 决定哪些图与哪些图匹配";员工回:**"Preselector is related to point selection for actual alignment."** 另一句:**"its useles to do every pair image matching"** | **【实锤·员工原话】** |
| 官方 [Alignment Settings](https://rshelp.capturingreality.com/en-US/appbasics/alignsettings.htm) | Preselector features = **"the number of features that will be used in alignment from the detected ones"**,建议设为检出量的 1/4–1/2 | **【实锤·官方】** |
| 官方 [setKeyValue 表](https://rshelp.capturingreality.com/en-US/tutorials/setkeyvaluetable.htm) | `sfmPreselectorFeatures` 默认 **10000**;`sfmMaxFeaturesPerImage` 默认 **40000** | **【实锤·官方】** |

⇒ 提问者把它跟 Metashape 的 "pair preselection"(那个才是配对预选)搞混了,而这个混淆被整个社区
(包括我方前卷宗)继承了下来。

**⚠️ 一个诱人但被我方数据当场证伪的推论**:"RC 检测 40k 只匹配 10k,所以 RC 的匹配效率是 75%"。
用我方 `RS_EXPORT_ARTIFACT_FORENSICS` 的样本 A 一手数据核验:**该工程有 54/254 张图的注册观测数
超过 10,000(最大 14,201)**,单图观测数不可能超过参与对齐的特征数
⇒ **该工程的 preselector 不是 10,000,或该设置并不封顶可注册观测**。**此推论作废,不要引用。**

### ①.1 第二个被推翻的常识:`Image overlap` 是**裁图**,不是邻域窗口

| 证据 | 内容 | 分级 |
|---|---|---|
| Wishgranter,帖 *Image overlap setting*(2016-01-06)[存档](http://web.archive.org/web/2021/https://support.capturingreality.com/hc/en-us/community/posts/115001354592-Image-overlap-setting) | **"low-> it try use whole img area"** / **"high-> it will use "central" part ( best optical quality) of img"**;**"for the speed "degradation" is minimal ( few % )"** | **【实锤·员工原话】** |

⇒ Low/Medium/High 控制的是**特征检测使用的图像区域**,不是"每图配多少邻居"。
这解释了官方文档里那句反直觉的 "Bigger overlap improves speed"。
**独立互证**:Balabanian 实操记录"overlap 设 Low 改变特征提取行为"(我方 `RS_THIRD_PARTY_ANALYSIS_DOSSIER` §3.1)。
另注:Image overlap **只有 Low/Medium/High,没有 Sequential 档**。

### ①.2 官方对齐参数与默认值全表【实锤】

来源:[setKeyValue 表](https://rshelp.capturingreality.com/en-US/tutorials/setkeyvaluetable.htm)(该表列名逐字是 `Name | Key | Value | Default value`)

| Key | 名称 | 默认 |
|---|---|---|
| `sfmFeatureDetectionQuality` | Feature detection quality | **High** |
| `sfmMaxFeaturesPerMpx` | Max features per mpx | **10000** |
| `sfmMaxFeaturesPerImage` | Max features per image | **40000** |
| `sfmImagesOverlap` | Images' overlap | **Medium** |
| `sfmImageDownscaleFactor` | Image downscale factor | **1** |
| `sfmMaxFeatureReprojectionError` | Max feature reprojection error | **2.0** |
| **`sfmPreselectorFeatures`** | **Preselector features** | **10000** |
| `sfmDetectorSensitivity` | Detector sensitivity | **Medium** |
| `sfmForceComponentRematch` | Force component rematch | **false** |
| `sfmDistortionModel` | Distortion model | **Brown3** |
| `sfmEnableCameraPrior` | Use camera priors | **true** |
| `sfmCameraPriorAccuracyX/Y/Z` | 位置精度 | **10 / 10 / 20** |
| `sfmCameraPriorWeight` | 位置先验硬度 | **1.0** |

**不存在**任何 `AlignmentSettings/...` 路径式键,全部是扁平 `sfm*` 前缀;
**不存在**任何与配对选择、检索、词典、匹配广度相关的键。

### ①.3 RC 的图像对候选策略:零文档、零专利、零日志

| 项 | 结论 | 分级 |
|---|---|---|
| 是否 vocabulary tree / BoW / kd-tree / hashing / min-hash? | **无任何证据支持或排除** | **【未找到】** |
| CLI 是否有匹配/预选命令? | **没有**。[命令表](https://rshelp.capturingreality.com/en-US/tutorials/commandline_1.htm)只有 `align`/`draft`/`detectFeatures`/`mergeComponents`/`update`/`selectMaximalComponent` | **【实锤·缺席】** |
| 专利? | Capturing Reality s.r.o. **只有一族专利** `EP3510513B8`/`CA3036404A1`(Michal Jancosek / Martin Bujnák / Tomáš Bujnák,2016 优先权,现属 Epic Games Slovakia),CPC 分类是 **DRM/加密/支付** —— 那是 **PPI 计费模式专利,不是视觉算法**。`inventor:"Michal Jancosek"`(2 命中)/`"Martin Bujnak"`(4 命中)全查,**无一件涉及匹配/检索/配对** | **【实锤·缺席】** |
| 对齐日志能反推阶段吗? | **找不到任何带 "preselecting"/"matching"/"candidate pairs" 阶段名的用户日志**。RC 只给事后 Alignment Report。**这是"已确认该表面不存在",不是"没搜到"** | **【未找到·已穷尽】** |
| 有 sequential/有序匹配模式吗? | **没有**。帖 *Sequential Image Matching*(2019-12-16)CR 员工 Erik Kubiňan 只给拍摄建议。另有员工原话 **"No, filenames matter not for actual alignment"** | **【实锤·缺席】** |
| 用 GPS / 先验位姿限制配对吗? | **官方从未说先验限制配对**。`sfmEnableCameraPrior`(默认 true)措辞是先验 "used in the alignment process and for georeferencing"。**唯一一处 RC 承认用位姿驱动配对的是 `Force component rematch`(默认 false):"It uses existing camera poses to search for new matches."** —— 对**已注册**相机的可选第二遍 | **【实锤】** |

**⚠️ 创始人勘误**:RC 创始人是 **Jancosek + Martin Bujnak**;**Tomas Pajdla 是他们 CTU 的导师/合作者,不是创始人**。

### ①.4 唯一能反推内部结构的官方证据:对齐工作集是**描述子**,不是配对表

CR 开发者说法,经 Puget Systems [RealityScan 硬件页](https://www.pugetsystems.com/solutions/photogrammetry-workstations/realityscan/hardware-recommendations/) 转述:

> "All processing steps except alignment are out of core."
> "Memory consumption during the alignment phase depends on the number of images (not size)"
> **"The approximate formula is: RAM = features x images x 200 bytes."**

校验:2,000 图 × 40,000 特征 × 200 B = **16 GB**,与官方给的 2000图/16GB 逐位对上(4000/32GB、8000/64GB、16000/128GB 同样成立)。

⇒ **【推断(强)】对齐期内存严格线性于图数,工作集 = 特征描述子而非 O(N²) 配对表。**
一个不驻留配对矩阵的架构不像在做穷举配对 —— 但**内存线性 ≠ 时间线性**,这条不能当复杂度证明。

### ①.5 已确证的 RC 对齐三段

1. **特征检测**(可在导入期后台低优先级预跑:`Background feature detection` + `Background thread priority`;结果写 App cache;CLI `detectFeatures` 原话 "Detected features will be saved in the application cache")
2. **Preselector**:从检出的挑出 N 个最好的进入对齐
3. **匹配 / 注册 / BA**

**⚠️ 对基准测试的致命影响**:因为检测可以在导入期后台跑完,**用户看到的 "aligning" 6–9 s 很可能不含特征检测**。任何 RC 对齐计时都必须先控制这一项。

**联合创始人 Martin Bujnak 关于匹配图的一手描述**(帖 *Inspection - How does it work?*,2016-01-08,[存档](http://web.archive.org/web/2021/https://support.capturingreality.com/hc/en-us/community/posts/115001354472-Inspection-How-does-it-work-)):
> "two cameras are connected if they have at least 100 matches in common such that those matches are visible in at least 5 cameras (consistency)"

(注:这是 Inspection **可视化面板**的显示阈值,**不是配对生成规则**,官方 [Inspection 文档](https://rshelp.capturingreality.com/en-US/tools/inspection.htm) 同义。别误读。)

### ①.6 第三方对 preselector 的受控实验(唯一的行为学约束)【三方】

帖 *Optimising Alignment*([存档](http://web.archive.org/web/20230327195441/https://support.capturingreality.com/hc/en-us/community/posts/115003012052-Optimising-Alignment)):
- Preselector 从 100k 降到 **6k**:点数/误差 **零变化**
- 降到 **5k 及以下**:注册**塌成多个 component**
- "adjusting this can massively affect ram usage and how long it take to align"

⇒ preselector 有明显的"够用即可"平台期,与官方"设成检出量 1/4–1/2"的建议一致。

### ①.7 学院血统假说必须降级

`VocMatch`(Havlena & Schindler, **ECCV 2014**,[PDF](http://vigir.missouri.edu/~gdesouza/Research/Conference_CDs/ECCV_2014/papers/8691/86910046.pdf))逐字核实:
- 词典 **两层 4096×4096 = 1600 万 visual words**,用 **110 亿个 SIFT 描述子**训练
- 对应关系直接由 word 共现给出,门限是 **"index words must be rare in the database and unique in each image"**;实测约 3,500 个 word 因太频繁被剔除
- 复杂度:分配/索引 **"linear in the number N of images"**,但配对计数矩阵 Q 明确二次 —— 论文自陈 **"generation of Q 16 hours (quadratic ...)"**
- 提速 **"2-3 orders of magnitude faster than conventional pairwise matching"**(实测 27×–2480×);质量 **"delivers results similar to those of the conventional method"**

**⚠️ 降级理由**:Havlena 写这篇时在 **ETH Zurich 跟 Schindler**,**不在 Capturing Reality**。
**把 VocMatch 当"RC 的 preselector"没有任何证据支撑**,只能当**架构类比**。
(我方前卷宗列为"论文推断",本卷进一步降级为**"无证据关联"**。)

---

## ② 复杂度与成本模型(带数字)

### ②.1 🔥"RC 近线性"的真实出处:一句无引用的 Wikipedia 句子

- 被广泛转引的 **"works linearly, so doubling the inputs roughly doubles the processing time"** 出自
  [Wikipedia: RealityCapture](https://en.wikipedia.org/wiki/RealityCapture),**无任何引用来源。不要当官方说法引用。**
- 官方说的"线性"是**内存**线性:CR 2016 官方 brochure([PDF](https://www.geo3d.hr/sites/default/files/2018-06/RC%20brochure%20A4.pdf))
  原话 **"It scales linearly, so you need twice more memory (32GB RAM) for 6,000 images."**
- 同一 brochure 的时间口径:**"align hundred images in less than 100 seconds on a $1,000 notebook"**、
  **"Can you align/register 3,000 images in two hours?"**
  ⇒ 100 图 ≈ **1.0 s/图**,3000 图 ≈ **2.4 s/图**。**30× 数据量只让每图成本涨 2.4×,与朴素 O(N²) 穷举不兼容**
  —— 但 CR 从未说机制是什么。【推断(中)】

### ②.2 🔥Falkingham 的 397 s / 593 s 被误读了:那是全管线

| 数据集 | 版本 / 硬件 | **只算对齐** | 全管线 | 对齐占比 |
|---|---|---:|---:|---:|
| 53 图 | RC 1.3,SLS + eGPU RTX 3070([2023-11-08](https://peterfalkingham.com/2023/11/08/reality-capture-v1-3-the-fastest-just-got-faster/)) | **9 s** | 343 s | 2.6% |
| 53 图 | RC 1.5.1,i9-14900K/RTX 4090([2025-06-19](https://peterfalkingham.com/2025/06/19/realityscan-2-0-released-formerly-realitycapture/)) | **6.308 s** | 609.4 s | **1.0%** |
| 53 图 | RealityScan 2.0,同机 | 20 s | 278.5 s | 7.2% |
| 53 图 | RC 1.0,i7-4790K/GTX 970([2019](https://peterfalkingham.com/2019/05/17/photogrammetry-testing-reality-capture-commercial-software/)) | draft 对齐 14.5 s | 397.3 s(**不含贴图**) | — |
| 218 图 | 同上 | 未单独给 | 593 s(**"start to finish"**) | — |

**⇒ 397 s / 593 s 里 97–99% 是网格化和贴图。用它们推匹配复杂度无效。**
(RC 1.5.1 分项:对齐 6.308 s / **网格化 479.532 s** / 贴图 123.560 s —— 网格化占 79%。)

**⚠️ 而且这两个数不同口径**:397 s 明确排除贴图,593 s 是 "start to finish";物体不同、拍摄条件不同、
218 那次质量被作者自评 "a bit messy"。**这不是受控扩展实验。**
**⚠️ 更糟**:RC 1.5.1 vs RS 2.0 那组(6.3 s vs 20 s)作者自陈 "I was heavily compiling something at the same time"、
"was not done scientifically"。**且 Epic 员工确认 RC 对齐非确定性**:"each alignment in RealityCapture is slightly different"([论坛](https://forums.unrealengine.com/t/why-different-pcs-reality-captures-align-image-results-are-different/2447634))⇒ **单次跑不可信。**

### ②.3 那条 4.11× 的增长比只能说明网格化

53 → 218 图 = **4.11×** 图;穷举配对数会涨 **17.2×**(1,378 → 23,653 对)。

| 软件 | 53 图 | 218 图 | 增长 |
|---|---:|---:|---:|
| RealityCapture | 397.3 s | 593 s | **1.49×** |
| Agisoft Metashape([同机同期](https://peterfalkingham.com/2019/06/27/photogrammetry-testing-agisoft-metashape-commercial-software/)) | 301.7 s | 3591.92 s | **11.91×** |

Metashape 的 11.9× 贴近 17.2× 的配对数增长 ⇒ 其时间被逐对匹配主导。
RC 的 1.49× 亚线性,但那是网格化主导的时间,**对匹配的证据力很弱**。

### ②.4 COLMAP 侧对照(官方明文)

[COLMAP tutorial](https://colmap.github.io/tutorial.html) 原话:
> "Exhaustive matching scales quadratically with the number of images"
> "a few minutes for tens of images to a few hours for hundreds of images to days or weeks for thousands"

同机同数据集(i7-4790K/GTX 970,53 图,[2017](https://peterfalkingham.com/2017/04/04/photogrammetry-testing-8-colmap/)):
特征提取 **10 s** / **匹配 64 s** / 稀疏重建 54 s = 128 s。
**53 图时匹配已占稀疏段的 50%**,而 RC 整个对齐 6–9 s。

**唯一一条能孤立出"预选价值"的实测**(Metashape,1,800 图,[Agisoft 论坛](https://www.agisoft.com/forum/index.php?topic=6750.0)):
关闭配对预选 + 40k 关键点 → **85+ 小时**;开启 reference preselection + 20k 关键点 → **3 小时**(**~28×**)。
⚠️ 硬件与关键点预算同时变了,**预选的贡献被混淆**。

### ②.5 我们自己的成本模型(一手)

| 量 | 值 | 出处 |
|---|---:|---|
| GPU 匹配 1 对(采集期空闲、机器凉) | **~16 ms** | `official_aether_sfm_c.cc` P1-LIVE-REPAY 注释 |
| GPU 匹配 1 对(采集期常态) | ~55 ms | 题述实测 |
| GPU 匹配 1 对(finalize、GPU 热) | **~410 ms** | 同注释;cap46 实测 336 对 → **137.9 s** |
| 候选**选择**成本(位姿点积) | ~20 ns/对 ⇒ N=300 全比 **<1 ms** | 本会话估算;`SelectStreamCandidates` 注释亦称 "~ns per previous frame" |
| CPU 暴力匹配(host) | 18.6 s/对(比 Metal 慢 **420×**) | 记忆库 `pair_gap_attribution_measured` |

**🔥关键不对称:同一对的成本随热态摆动 25×(16 ms ↔ 410 ms)。
候选方案的优劣,一半取决于"什么时候把它匹配掉",而不只是"选了几对"。**

**规模外推(每帧候选数 P 封顶 ⇒ 严格线性)**:

| N | 穷举对数 | 穷举 @55 ms | P=16 时对数 | @16 ms(采集期) | @55 ms |
|---:|---:|---:|---:|---:|---:|
| 142 | 10,011 | 9.2 min | 2,272 | 36 s | 125 s |
| 300 | 44,850 | 41 min | 4,800 | **77 s** | 264 s |
| 1000 | 499,500 | 7.6 h | 16,000 | 4.3 min | 14.7 min |

**⇒ 我们要的"近线性"不需要任何检索机制:每帧候选数封顶,配对数就是 O(N·P)。
难点从来不是"怎么变线性",而是"这 P 个名额给谁"。**

---

## ③ 候选选择方法全景表

### ③.1 COLMAP 五种配对生成器的官方默认值(一手,读 vendored 源码 + upstream 核对)

出处:`aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/pairing.h`(与 upstream `main` **逐位相同**)
⚠️ 结构体已从 `*MatchingOptions` 更名为 **`*PairingOptions`**,但 CLI 前缀仍是 `VocabTreeMatching.*`。

| 生成器 | 关键默认值 | 判据 |
|---|---|---|
| `Exhaustive` | `block_size = 50` | 全配对 O(N²) |
| `VocabTree` | **`num_images = 100`**、`num_nearest_neighbors = 5`、**`num_checks = 64`**(3.11.1 时是 256)、`num_images_after_verification = 0`(**默认关空间验证**)、`max_num_features = -1` | 检索 top-100 |
| `Sequential` | **`overlap = 10`**、**`quadratic_overlap = true`**、`expand_rig_images = true`;**`loop_detection = false`**、`loop_detection_period = 10`、**`loop_detection_num_images = 50`**、`loop_detection_num_nearest_neighbors = 1` | 时序 + 2^k 跳步 |
| `Spatial` | **`ignore_z = true`**、**`max_num_neighbors = 50`**、`min_num_neighbors = 0`、**`max_distance = 100`**(米) | **只用位置先验 kNN(faiss `IndexFlatL2`,d=3)——完全不看朝向** |
| `Transitive` | `batch_size = 1000`、`num_iterations = 3` | 已有匹配的传递闭包 |

**🔥三条对我们直接有用的观察**:
1. **COLMAP 的"位姿候选选择"极其原始**:`SpatialPairGenerator` 只吃 `PosePrior.position`,**默认还扔掉 Z**
   (`ignore_z=true`,为航拍 GPS 设计),**完全不看朝向**。我方 `SelectStreamCandidates` 早有 45° 朝向门,
   `ScoreEnrichPair` 更是直接算共视 —— **这一块我们领先 upstream,不是落后。**
2. `quadratic_overlap` 在 4.x 是**互斥的 2^k**(offsets 1,2,4,…,512),**不叠加线性邻居** —— 与我方
   `project_colmap_quadratic_overlap_verdict` 记忆一致(2024-08 重构才变互斥)。
3. 图像顺序按**文件名字符串排序**(`GetOrderedImageIds`),**不是时间戳**。
4. `automatic_reconstruction` 在 **`num_images < 200` 时选穷举**,以上才用词典树;`DataType::VIDEO` 才默认开 `loop_detection`。

### ③.2 COLMAP 词典树的真身(2025 年 5 月起已不是 Nister HKM 树)

- **2025-05 之前**:FLANN `AutotunedIndex` + 层次 k-means(`branching = 256`)—— 那才是 HKM 风格。
- **现在是 FAISS**。`visual_index.cc` 的错误串原话:*"COLMAP switched from flann to faiss in May 2025"*。
  `Build()` 跑的是**扁平** `faiss::Clustering`,**词典本身没有层次**;"树"只是词表上的 ANN 结构:
  出厂 256K SIFT 词典 = **`IVF1024,ITQ64,SH`**(1024 粗中心 + ITQ 转 64 bit + 谱哈希)。
- `num_checks` 现在直接映射 **`faiss::IVFSearchParameters::nprobe`** ⇒ `num_checks=64` 扫 1024 个列表里的 64 个
  ≈ **每个描述子只看 6.25% 的词**。
- 打分**不是朴素 TF-IDF**:每个 posting 存 **64-bit Hamming embedding**,票权 `exp(-h²/σ²)`(σ=16,硬截 24),
  再除 `sqrt(num_image_votes)` 抑制 burstiness,乘 **idf²**,最后 L2 归一 —— 血统是
  Schönberger 等 **ACCV 2016 vote-and-verify** + Arandjelović & Zisserman **ACCV 2014**。
- **索引时只用 1 个近邻词**(`index_options.num_neighbors = 1`),源码注释自陈
  "experiments showed only marginal improvements that do not justify the memory/compute increase"。

**出厂词典实际字节数**(GitHub release API 实取):

| 文件 | 词数 | 大小 |
|---|---|---:|
| `vocab_tree_faiss_flickr100K_words32K.bin` | 32K | **9.5 MB** |
| **`vocab_tree_faiss_flickr100K_words256K.bin`(SIFT 默认)** | 256K | **72.4 MB** |
| `vocab_tree_faiss_flickr100K_words1M.bin` | 1M | 282.1 MB |
| 旧 FLANN 版 256K / 1M | | 117.9 MB / 461.0 MB |

⚠️ **陷阱**:[demuc.de/colmap](https://demuc.de/colmap/) 至今仍挂**旧 FLANN 文件**,新 COLMAP 读不了
(= [issue #4483](https://github.com/colmap/colmap/issues/4483))。
另:`BuildOptions::num_visual_words = 256*256` = **65,536**,即**构建默认是 64K,不是出厂那棵 256K**。

**🔴 端上可行性的决定性一手事实**:我方 `glomap_vendor/CMakeLists.txt:75-80` 原文——
COLMAP 的 `feature_matching*` / `matcher_cache` / `pairing` / `retrieval/*` 是
**"DELIBERATELY NOT here — it drags in FAISS + OpenMP (\<omp.h\>), which the iOS toolchain lacks,
and would break the device glomap_core build"**,只为 host 原型保留。
FAISS 本身 MIT,但**官方无移动端支持**([issue #1059](https://github.com/facebookresearch/faiss/issues/1059) 无人回),
社区 `faiss-android.aar` = **44.6 MB**,**鸿蒙无任何构建**。

### ③.3 COLMAP PR #4544(学习式全局描述子)——**尚未合并**

[PR #4544](https://github.com/colmap/colmap/pull/4544) *"Add configurable global descriptor image retrieval (MixVPR, MegaLoc)"*,
作者 Vincentqyw,2026-07-15 开,**STATE: open,未合并**(+1562/−35)。
管线:`Bitmap::Read → Rescale → Normalize → ONNXModel → L2 归一 → FAISS IndexFlatIP → top-K`,默认 `num_images = 100`。

| | MixVPR | MegaLoc |
|---|---|---|
| 输入 | 320×320 | 518×518 |
| 描述子维 | 4096 | 8448 |
| 权重 | `mixvpr_fp16.onnx` **22.0 MB** | `megaloc_fp16.onnx` **458 MB** |
| 批处理 | 支持 | **不支持**(源码注释 "gemm_input_reshape hardcodes batch=1") |

- 运行时 ONNX Runtime 1.27.1,**不需要 CUDA**;COLMAP `main` 的 `onnx_utils.cc` **已有 CoreML EP**
  (`COREML_FLAG_CREATE_MLPROGRAM` + CPU 回退)。
- **权重从第三方 HF 镜像 [Realcat/image_retrieval_checkpoints](https://huggingface.co/Realcat/image_retrieval_checkpoints) 下载,该仓库不声明任何 license。**
- 维护者 ahojnnes 的评审原话:**"Is your initial selection of global descriptor methods backed by some benchmarking in terms of precision/recall/runtime?"** —— **连上游都还没验收。**
- ⚠️ 疑似 bug:PR 用 mean=0/std=1 归一化 MegaLoc,而 [hloc 的 megaloc.py](https://github.com/cvg/Hierarchical-Localization/blob/master/hloc/extractors/megaloc.py) 用 ImageNet 均值方差。**两者必有一错。**

### ③.4 全景对照表

| 方法 | 每图成本 | 索引/词典体积 | 每图内存 | 商用许可 | 跨端(iOS/安卓/鸿蒙,无 CUDA) | 需外观模型 |
|---|---|---|---|---|---|---|
| **纯位姿几何门(我方方案)** | **~N 次点积,N=300 全比 <1 ms** | **0** | **~50 B**(位姿) | **不适用(自有代码)** | ✅ **纯 Eigen 算术,四端零依赖** | ❌ |
| COLMAP 词典树 32K | 索引+查询各需 F 次 IVF 搜索 | **9.5 MB** | 32 B/特征 ⇒ 8192 特征 = **256 KB** | BSD-3 ✅ | 🔴 需 FAISS(44.6 MB aar)+ OpenMP;**鸿蒙无** | ❌(用 SIFT) |
| COLMAP 词典树 256K(默认) | 同上 | **72.4 MB** | 同上(N=300 共 **79 MB** postings) | BSD-3 ✅ | 🔴 同上 | ❌ |
| DBoW2 / DBoW3 | BoW 转换 **3.59 ms** + 查询 **3.08 ms**(i7-2.67GHz,26k 图) | `ORBvoc.txt` **145 MB**;`orbvoc.dbow3` 49.4 MB | — | BSD-3 **+第 4 条通知义务** ⚠️ | ⚠️ ARM 冷加载实测 **77 s**(Exynos5422,ASCII)/1 s(二进制) | ❌ |
| FBoW | 号称 6.4× | — | — | 🔴 **README 说 MIT 但仓库无 LICENSE 文件** | 🔴 **`cpu.h` 对非 x86/非 Android 直接 `#error`;全仓 grep `neon\|arm` 零命中** | ❌ |
| **MegaLoc** | **CoreML fp32/int8 74 ms/图**(Apple Silicon 笔记本) | **914 MB** fp32 / 458 MB onnx-fp16 / 219 MB CoreML-int8 | 33 KB(8448 维) | ✅ **代码+权重均 MIT** | ⚠️ 需 CoreML+MNN 双导出;**CoreML fp16 路径坏掉**(cos=0.944,官方 README 自陈) | ✅ |
| **EigenPlaces R18-512** | **无任何公开延迟数据** | **43.7 MB** | 2 KB(512 维) | ✅ MIT(代码+权重) | ✅ 纯 ResNet,CoreML/MNN 最好导 | ✅ |
| MixVPR | 6 ms(Titan Xp);**CoreML fp16 3.1 ms / 20.8 MB** | 43.7 MB fp32 | 16 KB | 🔴 **仓库无 LICENSE 文件 = 保留所有权利** | ✅ | ✅ |
| SALAD | — | 335.7 MB | 33 KB | 🔴 **GPL-3.0 硬阻断** | — | ✅ |
| NetVLAD(原版) | 17 ms(Titan Xp)/ 92 ms(GTX 1080) | 528.9 MB `.mat` | 16 KB | ⚠️ 代码 MIT,**权重无明确授权** | ❌ 体积 | ✅ |
| AnyLoc | — | **4.34 GB** | 192 KB | BSD-3 ✅ | ❌ 体积 | ✅ |
| DINOv2 ViT-S/14 | ~10 FPS CoreML(M2 Air,非正式) | 84.2 MB | 1.5 KB | ✅ **Apache-2.0(2023-08-31 从 CC-BY-NC 改的,[commit 81b2b64](https://github.com/facebookresearch/dinov2/commit/81b2b6419385a321287de91e00282ef7cbd26f94))** | ⚠️ ViT 导出坑多 | ✅ |
| **VLAD 小码本(OpenSfM 式)** | FLANN KD-tree 查询 | **33.7 KB**(64 中心)/ **4.57 MB**(10k 词) | ~KB | BSD-2 ✅ | ✅ 无重依赖 | ❌ |
| GIST | **35 ms**(8 核,Flickr1M);二值签名版 36 ms 提取 / **2 ms** 检索 | 0 | 3,840 B | 代码 **PSFL ✅**(不是 GPL,2011 改的) | 🔴 依赖 **FFTW = GPLv2+**(可换 Accelerate/KissFFT) | ❌ |
| 感知哈希 | **aHash ~7.4 µs/图**、pHash ~39 µs/图(OpenCV img_hash) | 0 | 8–336 B | ✅ **OpenCV img_hash Apache-2.0**;🔴 **phash.org 那个库是 GPLv3** | ✅ | ❌ |
| 颜色直方图 / tiny image | <1 ms | 0 | 96–3072 B | ✅ | ✅ | ❌ |

### ③.5 四条来自这张表的硬结论

1. **N ≤ 3000 时暴力算相似度全胜,不要建 ANN 索引。** 描述子 L2 归一后整个全配对问题就是一次
   `S = X·Xᵀ` 的 SGEMM。真正的隐藏成本是 N×N 分数矩阵(`N²·4 B`,与维度无关):N=3000 才 36 MB。
2. **检索方法的选择只动最终 SfM 质量 ~1%,却动成本 36–108×。**
   Jiang 等([arXiv 2307.04520](https://arxiv.org/pdf/2307.04520),21,647 张无人机图):
   配对选择耗时 COLMAP BoW **1,335.5 min** / DBoW2 **2,848.3 min** / VLAD+HNSW **12.4 min**;
   检索精度 97.6% vs 94.4%;**最终 SfM 精度 0.766 vs 0.752 px、9.25 M vs 8.92 M 点 —— 约 1% 差异。**
3. **没人在手机上带大词典。** ORB_SLAM2 的安卓移植**拒绝把 145 MB 词典打进 APK**,要求用户手动拷到
   `/storage/emulated/0/SLAM/VOC/`。而 OpenSfM 用 **4.57 MB** 扁平 10K 词典、Theia 用 **16 个 GMM 中心**
   干同样的活。Nister 自己的 Table 1:**扁平 10K 词 = 86.0% vs 1M 词 = 90.6%**(且那是 6,376 图的库,不是 300 帧)。
4. **🔑 成熟系统的实际选择是"关掉检索":** OpenSfM 的
   [`config.py`](https://raw.githubusercontent.com/mapillary/OpenSfM/main/opensfm/config.py) 里
   **`matching_bow_neighbors = 0` 且 `matching_vlad_neighbors = 0`(检索默认关闭)**,靠
   **`matching_gps_distance = 150`**(GPS 邻近)选配对。OpenMVG 默认只有 EXHAUSTIVE / CONTIGUOUS,不带词典。
   **我们有的 ARKit 米制 6-DoF 位姿严格强于 GPS。**

### ③.6 🔥位姿驱动候选选择的生产实现全表(这才是我们该抄的东西)

**统一发现:所有拿得到位姿先验的生产系统,都把每台相机化约成一个代表点
`look-at point = 相机中心 + 光轴 × 场景深度`,再对**那些点**做 kNN —— 而不是对相机中心做 kNN。**
两个独立实现(Agisoft Metashape、OpenSfM)收敛到完全一样的构造。

| 系统 | 判据 | 默认值 |
|---|---|---|
| **Agisoft Metashape "Reference" preselection** | 三档 Source / Estimated / Sequential。**给了 Capture Distance + 姿态角时**:"from the original camera locations the vector is sent according to the orientation angles",长度 = Capture Distance,**"these new points are used for the neighbors estimation"**;没给时"will consider only XYZ coordinates" | ⚠️ **邻居数从未公开**(手册/API/论坛全无);`keypoint_limit=40000`、`tiepoint_limit=4000` |
| **OpenSfM `pairs_selection.py`** | `get_gps_opk_point` 返回 `center` 与 `z_axis` 归一到 z=1 的前向点;`find_best_altitude` 从 1 扫到 8000 步长 100,**取"前向投影点 XY 包围盒最小"的深度**(二次拟合取顶点);再对这些点建 `cKDTree` | `matching_gps_distance = 150`;**`matching_gps_neighbors = 0`**(⚠️ **检索与 kNN 默认全关**) |
| **hloc `pairs_from_poses.py`** ⭐**与我们场景逐字对应** | ①按**相机中心欧氏距离**排序;②算**主轴(principal axis)夹角**而非完整旋转(源码注释:"as two images rotated around their principal axis still observe the same scene");③**硬否决 `dR ≥ DEFAULT_ROT_THRESH = 30°`**;④取 top-`num_matched` | 4Seasons(位姿驱动)`num_ref_pairs = 20` |
| **MicMac `GrapheHom`** | 唯一真做**地面足迹多边形求交**的生产实现:`euclid(C1−C2) > Dist` 否决,再 `aPol1 * aPol2` 求交,`Surf() ≤ 0` 否决 | `Dist=-1`(自动 = 平均足迹直径)、`Rab=0.2`(把地平面推远 20% 作 fail-open 余量)、**`Terr=false`(地面模式直接跳过足迹检验)**;`OriConvert --NbImC = 50` |
| **ODM** | `--matcher-neighbors` 默认 **0** = "match by triangulation";实际下发 `matching_graph_rounds: 50`(抖动 Delaunay 并集)、`matching_gps_neighbors: 0` | ⚠️ `--matcher-distance` **已不存在** |
| **Pix4D** | `matchTimeNbNeighbours=2`、`matchUseTriangulation=true`、`matchMtpMaxImagePair=50` | ⚠️ **全流程未见任何使用相机朝向的文档** —— 几何比 Metashape 弱 |
| **ORB-SLAM2/3 `CreateNewMapPoints`**(与我们最同构:新关键帧对 N 个旧帧建新点) | 取共视图 top-N;**建点前先用位姿算基线门**:单目 `baseline / medianSceneDepth < 0.01`(≈0.57° 视差)直接跳过 | **ORB-SLAM2 单目 `nn=20`**、双目 `nn=10`;**ORB-SLAM3 单目 `nn=30`**;共视边阈值 **≥15 共同点**;Essential graph θ_min=**100**;回环候选 θ_min=**30** |
| COLMAP `Spatial` | **只读 `pose_prior->position`,从不读 `->rotation`** | `max_num_neighbors=50`、`max_distance=100 m`、`ignore_z=true` |

**⚠️ 鸡生蛋澄清**:ORB-SLAM 的共视图是**从匹配结果建的**,**不能当先验候选选择器用**。
但它解决问题的方式对我们直接有用:**用位姿把每次匹配变便宜** ——
`SearchForTriangulation` 由两个已知位姿算出 `F12`,把搜索降成**沿极线的 1-D 搜索**,
`dsqr < 3.84·σ²`(1 自由度 95% 卡方)直接否决。
**这是对我方 55 ms/对的第二条、正交的杠杆**(我方树里已有 `ArkitGuidedMatchPair`,`EpiPriorMatchEnabled()` 默认关)。

### ③.7 🔥"每图几个候选够用"的文献共识与拐点实测

| 出处 | 每图候选数 |
|---|---|
| MASt3R-SfM | ~13.8(N_a=20 关键帧 + k=10) |
| Building Rome in a Day | 20(10+10)+ 4 轮扩展 |
| **hloc 全部 SfM 管线** | **20**(7-Scenes 用 30) |
| **hloc 位姿驱动(4Seasons)—— 我们的场景** | **20 + 30° 门** |
| Rome on a Cloudless Day | 10(或 150 m 半径);簇内验证只 **6 对** |
| ORB-SLAM2 单目 / ORB-SLAM3 单目 | **20 / 30** |
| COLMAP 出厂 | 10 时序 / 50 空间 / 50 回环 / 100 词典 |
| MicMac `OriConvert --NbImC` | 50 |
| **PAIGE 与 ICRA-2020 实测拐点** | **~25,到 50 就平了** |

**拐点的两组硬数据**:
- **PAIGE**(Schönberger 等 CVPR 2015,五个 ~7k 图数据集):检索 25→50 花 **1.6× 时间换 +14.3% 注册图**;
  50→100 花 2.2× 换 +7.3%;Rome 上 25→100 是 **2.6× 算力换 −0.2%**。
  原话:**"there is no need to find all true positive image pairs to produce good reconstructions"**、
  **"SfM does not substantially gain from finding all true positives"**。
- **Ye 等 ICRA 2020**(14 数据集 58k 图,NetVLAD top-k):5→25 **+44.6% 注册图 / 4.5× 时间**;
  25→50 **+8.5% / 1.8× 时间**;且检索精度从 45.3% 单调塌到 26.1%
  —— 印证 PAIGE 说的"**runtimes are mostly determined by the overhead, since RANSAC is especially expensive for false positive pairs**"。

**⭐ MASt3R-SfM 的等预算对照(Tanks&Temples,200 视图)—— 本卷最贴切的一张表**:

| 场景图 | ATE ↓ | RTA@5 ↑ | 配对数 | 耗时 |
|---|---:|---:|---:|---:|
| 完全图 | 0.01256 | 75.9 | 39,800 | 2.2 h |
| **纯时序窗** | 0.02509 | **33.1** | 2,744 | 14.1 min |
| 随机 | 0.01558 | 55.2 | 2,754 | 14.7 min |
| **检索** | **0.01243** | 70.9 | 2,758 | 14.3 min |

**三条结论:①6.9% 的配对(~13.8/图)ATE 比完全图还好,快 9.2×;
②同预算下"怎么选"能让 RTA@5 从 33.1 摆到 70.9 —— 纯时序窗是同预算里最差的一档;
③消融(Table 5):只 kNN 64.1、只关键帧 58.1、**关键帧+kNN 70.9** —— 两者缺一不可。**
⚠️ T&T-200 是**抽帧**视频,时序邻接远弱于我们 142 帧连拍;应读作"纯时序窗关不上回环",而非"时序邻接没用"。

**另外两条"更少更好的配对反而更准"的先例**:
- **Zhu 等**(倾斜航拍,足迹中心 kNN + `w_ij = 0.6·w_area + 0.4·cos(angle)`):
  对 MicMac GrapheHom **664 对 vs 13,491 对(~20× 少)**,水平 BA 精度相当。
- **cuSfM**(NVIDIA 2025,**已知 VSLAM 位姿的视频全局 SfM,与我们最同构**):
  用位姿图边(时序 + 回环 + 外参)建视图图,**半径搜索产出 ~7× 更多配对却每项指标都更差**;
  KITTI 每 100 帧总耗时 108.0 s → **58.8 s**,RMSE **0.131 m vs COLMAP 1.100 m**。
  ⚠️ KITTI 是前向行驶几乎无 revisit,**不能直接迁移到绕物拍摄**;可迁移的是方向性结论。

### ③.8 🔥选择判据必须含"三角化角",不能只看邻近(对我方 A.3/A.5 的自我纠正)

**这是本卷唯一一处文献推翻了我自己的实测设计。**

我方 A.3/A.5 的打分是"越近越好、夹角越小越好",目标函数是 **inlier 数**。
但 **inlier 多 ≠ 3D 点好**:低视差对给出的是深度噪声壳(我方 `doublewall_root_cause` 已定罪:
厚墙 5.2° vs 薄墙 11.4°)。**纯邻近选择会系统性地饿死视差。**

文献里唯一在**选择期**就保护三角化角的机制:

- **MVSNet 分段高斯视图分**(§4.1)—— 正典形式:
  ```
  G(θ) = exp(−(θ−θ₀)²/2σ₁²)   θ ≤ θ₀
         exp(−(θ−θ₀)²/2σ₂²)   θ > θ₀
  ```
  **θ₀ = 5°,σ₁ = 1,σ₂ = 10** —— **视差不足被惩罚得比视差过大狠 10 倍**,这正是朴素 kNN 做反了的地方。
- **Zhu 等**:`w_ij = R_w·w_area + (1−R_w)·w_angle`,`w_angle = cos(angle)`(>90° 取 0),**`R_w = 0.6` 选定**;
  只看面积(`R_w=1.0`)只能定向 700 张图。
- **DeepVideoMVS**(**室内手持,与我们最同构**):关键帧惩罚 `α(‖t‖−0.15)² + (2/3)tr(I−R)`,
  **`α = 5.0` 当 ‖t‖ ≤ 0.15 否则 1.0** —— 同样的非对称:偏好 15 cm 基线,太近了罚 5 倍。
  ⚠️ 可迁移的是**比值 baseline/depth ≈ 0.05–0.15(≈3–9° 三角化角)**,不是 15 cm 这个绝对值。
- **COLMAP 自己的角度门**:`init_min_tri_angle = 16°`、`ba_local_min_tri_angle = 6°`、`filter_min_tri_angle = 1.5°`
  —— **COLMAP 承认配对质量由角度决定,却只在匹配之后才用它。没人在选择期用。这就是我们的机会。**

### ③.9 Wu 2013 preemptive matching:对 55 ms/对本身的正交杠杆

[VisualSFM 论文](http://ccwu.me/vsfm/vsfm.pdf) §3 逐字算法:
> "1. Sort the features of each image into decreasing scale order.
> 2. Generate the list of pairs that need to be matched...
> 3. (a) Match the first h features of the two images.
> (b) If the number of matches from the subset is smaller than t_h, return and skip the next step.
> (c) Do regular matching and geometry estimation."

- **h = 100**(原话 "we choose h = 100 with consideration of both efficiency and robustness")
- **t_h 是自适应的,不是固定值**:Table 1 caption "We first try t_h = 4, and then try t_h = 8 if the result is complete, or try t_h = 2 if the resulting reconstruction is incomplete"
- 机理:**"the top-scale subset has roughly h/k chance to preserve a match, which is much higher than the h²/(k₁k₂) chance of random sampling"**
- 动机:**"the majority of image pairs do not match (75% − 98%...)"**
- **🔥对我们最关键的一行(Table 1)**:`Loop`(4342 帧**视频**)在 t_h=4 下保留 38% 配对、**95% 匹配、丢 0 台相机**。
  **顺序采集是 preemption 最友好的场景。**
  反例:Arts Quad 在 t_h=4 丢了 **24%** 相机;Colosseum "breaks into the interior and the exterior"。
- ⚠️ **论文没有做"固定配对表下开/关 preemption 的墙钟 A/B"**,那个 95% 是**配对数**口径。
- ⚠️ PAIGE 的批评:**"a small change in L_P has great effect on the performance"**;小重叠的对容易被误杀。
- ⚠️ 注意 step 2:论文**是把 preemption 与候选表组合使用**,不是替代。

### ③.10 hloc 的实践取值(候选数参考)

[cvg/Hierarchical-Localization](https://github.com/cvg/Hierarchical-Localization),Apache-2.0。
`pairs_from_retrieval.py` 的 `--num_matched` **无默认值(required)**,所以不存在"hloc 默认"。实践值:

| 场景 | 每图候选数 |
|---|---|
| **小场景从零跑 SfM**(`pipeline_SfM.ipynb`) | **`num_matched=5`** |
| 大场景 SfM(Aachen/CMU/Cambridge/RobotCar) | `--num_covis 20`(**共视,不是检索**) |
| 7-Scenes | `--num_covis 30` |
| 定位(localization) | 10–50 |

**⇒ 对我们这个规模(N ≤ 300)最贴切的参考是"小场景 SfM top-5",不是"定位 top-50"。**
这与本会话实测的最优 M=3–4 独立吻合。

---

## ④ 给我们的推荐方案

### ④.-1 立项前提被两次证伪

**第一次**:"RC 有个两级配对漏斗可以抄" —— **不存在**(见①)。
**第二次**:"RC 的 tie point 被更多图看到" —— **只对了一点点**(见④.0)。

### ④.0 先纠正命题本身(否则会做错事)

| | 平均 track 长度 | 出处 |
|---|---:|---|
| RC 桌面(254 图原生 Bundler 导出) | **3.272**(中位 3,max 47,2-view 占 49.4%) | 本仓 `RS_EXPORT_ARTIFACT_FORENSICS_2026-07-28.md` §3.1 |
| RC 七个工程(MIT 硕士论文 Table 7.1) | 2.99 / 3.08 / 3.15 / 3.29 / 3.4 / 4.88 / 4.98 | 同上 |
| COLMAP 有效带 | 3.60–4.20 | 同上 |
| **我方对应图拓扑天花板**(本会话实测) | **3.70–4.14** | 附录 A.6 |
| 我方交付 | **2.52–2.9** | 记忆库 cap50/51 + 设备日志 |

⇒ **我方的对应图已经支撑 3.7–4.1 的 track 长度,和 RC 交付值(3.27)同档甚至更高。
交付掉到 2.6 的那 1.1–1.5 个观测,主要丢在三角化/过滤段。**

**但候选选择也确实有份**——本会话首次做了归因(附录 A.9),把 track 内部**缺失的边**分成两类:

| | cap7_day | cap3_eve |
|---|---:|---:|
| 已建立的边 | 57.2% | 51.1% |
| **帧对匹配过、但该特征对应没建立**(匹配/比值检验的锅) | **27.0%** | **25.1%** |
| **帧对从未匹配**(**候选选择的锅**) | **15.8%** | **23.8%** |

⇒ **候选选择只占 track 缺口的 16–24%,匹配段占 25–27%,两者都不是主因(已建立 51–57%)。**

**🔥文献给了一个比我这条实测更乐观、也更具体的预测** —— **ENFT**(Zhang 等,
[ar5iv](https://ar5iv.labs.arxiv.org/html/1510.08012))Table IV 是本题最对症的一次测量:

| 方法 | 平均 track 长度 |
|---|---:|
| C-SIFT | 1.73 |
| **CPT(consecutive point tracking = 纯时序)** | **2.28** |
| BF-SIFT(暴力全配对) | 2.71 |
| **CPT + NCTM(non-consecutive track matching)** | **3.10** |

论文对病因的原话:尺度不变匹配在连续跟踪下
*"generally produce many short tracks in consecutive point tracking due primarily to the global indistinctiveness and feature dropout problems"*。

**⇒ 我方 2.6–2.9 不是异常,而是"纯时序窗匹配"的教科书指纹**(ENFT 在同一 regime 量到 2.28)。
**而他们靠加"非连续匹配"把 2.28 抬到 3.10(+36%),正是我们要做的这件事;
且 CPT+NCTM(3.10)反超暴力全配对(2.71)** —— 再次印证"更少但更对的配对可以更强"。

**所以交付 track 的预期应上调为 +0.3~0.6【文献先例,中等强度】**,而不是我原先据 A.9 估的 +0.1~0.2。
两条证据不矛盾:A.9 说的是"候选缺口只占 track 缺口的 16–24%",ENFT 说的是"补上这 16–24% 值 +36%"。
**但仍不要期待到 4+**:那需要同时修三角化段(见 P3)。

### ④.1 我们比 RC 多一张 RC 没有的牌

RC 必须从像素反推重叠(它拿不到位姿),所以只能上外观。**我们每帧有 ARKit 6-DoF 米制位姿 + 内参 + 重力。**

本会话实测钉死了这张牌的成色:

- 纯位姿(中心距 + 朝向夹角,**零外观信息**):`1.0 m / 45°` 门砍掉 **31%** 预算只损失 **2.4%** inlier(A.3)。
- **控制住位姿几何后,时间 gap 没有独立预测力**(留出验证比值 0.84–1.20,A.4)⇒
  **官方 quadratic 的 2^k 偏移在几何上是任意的,它只是"没有位姿时的盲猜"。**
- 选择成本:N=300 全比 **<1 ms**,相对 55 ms/对是 **10⁻⁵ 量级**。
- **额外收获**:A.4 里 gap 41–80 的过门对实测/模型比 0.87–0.90 ⇒ **ARKit VIO 在这些跨度上的漂移
  小到不影响位姿判据的有效性**(这也是"位姿够用、不需要外观回环检测"的直接证据)。

**⇒ 结论(强):对我们这个场景,位姿驱动的候选选择严格优于 RC 的外观漏斗** ——
更准(直接算几何而不是猜相似度)、更便宜(无索引、无模型、无词典)、更跨端(纯 Eigen,四端零依赖)。
**不要移植 RC 的 preselector,也不要上 vocab tree / NetVLAD / MegaLoc。**

### ④.2 位姿候选选择真正买到的四样东西(按价值排序)

1. **真 revisit 的闭合**:**90% 的帧**有几何成立、生产从未尝试的 revisit 伙伴(A.8);
   而 blind quadratic 的 2^k **整簇够不着**真实回环(记忆库 cap51 回环在 gap 50–54,quadratic 只发 32/64)。
   直接对着 BA gauge 漂移(实测 ±4–10.6%)。
2. **等预算下长程 inlier ×3.0–3.3**(A.5,双 capture 一致)。
3. **回收 ~20% 匹配预算**(cap7:1991 对里 393 条不过门;全丢掉 track 长度只 −0.025、track≥3 −0.0%,A.7)。
4. **re-triangulation 资格**:COLMAP `Retriangulate` 只遍历 `ImagePairs()`,**从未匹配过的对永远不会被重三角化**
   (记忆库 quadratic 定案 §3)。

### ④.3 推荐设计(具体到参数)

#### 🔴 先纠正我自己:纯邻近打分会系统性饿死视差

本会话 A.3/A.5 的打分是"越近越好、夹角越小越好",目标函数是 **inlier 数**。
**但 inlier 多 ≠ 3D 点好**:低视差对给的是深度噪声壳(我方 `doublewall_root_cause` 已定罪,
厚墙 5.2° vs 薄墙 11.4°;`ghost_layer_final_verdict` 同源)。
文献一致指出这是朴素 kNN 的固有缺陷,并给出唯一的修法:**在打分里放一个非对称的三角化角项**
(MVSNet θ₀=5°/σ₁=1/σ₂=10;Zhu `R_w=0.6`;DeepVideoMVS α=5.0)。
**⇒ 下面的判据已按此修正。A.5 那个 ×3.0–3.3 是"inlier 口径"的上界,不是"好点口径"的。**

#### 判据(三级,由粗到细)

**一级(几何门,O(1)/对)** —— 朝向优先,因为 ARKit 的旋转比位置可靠得多(见④.4风险节)
```
过门 ⟺  ∠(axis_i, axis_j) ≤ 30~45°   且   d(Ci, Cj) ≤ D_max   且   |i − j| > K_near
```
- **朝向门放在第一位**:实测 ARKit 旋转 RPE < 4°、roll/pitch 被重力锁定,而位置 ATE 有 10–40 cm。
  **30°** 是 hloc `pairs_from_poses.py` 与 Cartographer-2D 的取值;**45°** 是 RTAB-Map 与我方现有
  `kStreamCandViewAngleMaxRad`。**建议起步 45°(零新常数),再扫 30°。**
  ⚠️ 与 hloc 一致,**夹角要算主轴(principal axis)夹角,不是完整旋转** ——
  源码注释 "as two images rotated around their principal axis still observe the same scene"。
- **`D_max` 不能写死成米。** 1.0–1.5 m 只是这两个室内 capture(~3 m 房间)的最优值。
  **归一化方案(按可靠性排序)**:
  1. **【首选,有两个生产先例】改成对 look-at 点做 kNN**,而不是对相机中心:
     `P_i = C_i + axis_i · z̄`。Metashape 的 Capture Distance 与 OpenSfM 的
     `get_representative_points` 是同一构造。这自动把"距离"变成场景尺度相关量。
     `z̄` 取 live 预览重建的中位观测深度(端上现成);
     ⚠️ **不要照抄 OpenSfM 的 `find_best_altitude`** —— 它最小化的是 **XY** 包围盒(下视无人机假设),
     对我们这种水平外向的房间扫描会走到负顶点并退化回相机中心。
  2. 退路:`D_max = 0.5 · z̄`。⚠️ **该系数是本会话由两个样本反推的,未受控验证。**
- **`K_near`**:revisit 候选必须与时序邻居分开(hdl_graph_slam / LIO-SAM 的通用做法)。取 K_near = 12(现窗宽)。

**二级(打分排序,只对过门的候选算)**
```
score = w_prox · G(θ_tri)  +  (1 − w_prox) · cos(θ_axis)
G(θ) = exp(−(θ−5°)²/2·1²)     θ ≤ 5°        ← 视差不足,罚 10 倍
       exp(−(θ−5°)²/2·10²)    θ > 5°
```
- `θ_tri` = 两相机中心对 look-at 点张的角(= 三角化角的位姿期近似)。
- 起步 `w_prox = 0.6`(Zhu 实测选定值)。
- ⚠️ 我方实测的双门(`d ≤ 1.5m` / `θ ≤ 45°`)对应 A.3 的 1.42 效率点,**保留作一级门**;
  二级打分换成上式后**必须重跑 A.5,那个 ×3 会变**(大概率数值下降但点质量上升)。

**三级(升级判据,已有代码)**:`ScoreEnrichPair`(`official_aether_sfm_c.cc:2310`)——
把 live 预览的 2-view / 低视差 track 投影到候选帧,数"能被这一对升级成 **≥5°** 视差第三观测"的 track 数。
**它内建的 5° 门与 MVSNet 的 θ₀=5° 独立吻合**,是直接对着目标函数的判据。
目前被 `kProductionOfficialEndpointOnly` 关死。

**四级(正交,不属候选选择但同样省钱)**:**位姿引导的极线 1-D 搜索**。
ORB-SLAM `SearchForTriangulation` 由两个已知位姿算 `F12`,`dsqr < 3.84·σ²` 卡方否决,
把 2-D 描述子匹配降成沿极线的 1-D 搜索。**这是对 55 ms/对本身的杠杆,与候选数无关。**
我方树里已有 `ArkitGuidedMatchPair`(`EpiPriorMatchEnabled()` 默认关,标注为实验臂)。
另可叠加 **Wu 2013 preemptive**(先匹配 top-100 大尺度特征,< t_h=4 就跳过)——
其 Table 1 显示**视频序列(Loop, 4342 帧)在 t_h=4 下保留 38% 配对、95% 匹配、丢 0 台相机**,
**顺序采集是该技巧最友好的场景**。

#### 候选数

| 段 | 每帧候选数 | 依据 |
|---|---|---|
| 近链 gap 1..4 | **4**,无条件保底 | 保注册链;gap≤4 平均 inlier 373–1476,永远值 |
| 近窗其余 gap 5..12 | **≤8,过门才发** | 回收 A.7 那批不过门的近对 |
| **长程 revisit gap>12** | **M = 3–4** | A.5 收益递减:M=3 吃 80%、M=4 吃 86%,M>6 平掉 |
| 同帧伙伴去冗余 | 彼此至少隔 **4 帧** | 复用现有 `SelectDiverseAnchors` 的 `min_separation` |
| **连通性硬底** | 每帧**至少参与 1 个三元环** | Sweeney ICCV 2015 §4.1:最大生成树 + 反复加"闭合三元组"的边,直到每个视图都在某个三元环里。**这是最便宜的、可证明不碎组件的下界**;Wu 的 "Colosseum breaks into interior and exterior" 就是没有它的后果 |

**总计每帧 ≤ 16 对**(现状 12),**总配对数 = O(N·16),严格线性**。

**⚠️ 与文献共识的落差要说清楚**:③.7 的共识带是 **10–25 候选/帧**,ORB-SLAM 单目用 20/30,
hloc 位姿驱动用 20。**我们的 16(其中长程只 3–4)落在共识带的下沿。**
理由是我方"拍完 ≤30 s"的产品硬约束(记忆库 `rs_replication_direction_30s_budget`):
142 帧 × 12 ÷ 2 ≈ 852 对 × 55 ms ≈ **47 s,已经超预算** —— 只有把长程候选压到个位数、
且**在采集期空闲预付**,才装得下。**这是一个被预算逼出来的、比文献更激进的取值,
所以"选得准"对我们比对任何一个工具都更重要**(MASt3R-SfM 实测:同预算下选法能让 RTA@5 从 33.1 摆到 70.9)。

#### 何时匹配(比参数更重要)

**长程候选必须在采集期空闲窗口预付,绝不能留给 finalize**(16 ms vs 410 ms,差 25×)。
这正是 `PrepayQuadraticTick` 已经在做的事(`OFFICIAL_AETHER_QUADRATIC_PREPAY` 默认开,
Dart 侧 `_maybePrepay()` 每次队列见底发 budget=2)。

**改动面极小**:把 `PrepayQuadraticTick` 里那段
```cpp
for (int k = 0; k < overlap; ++k) { gap = 1<<k; ... prepay_due.emplace_back(j-gap, j); }
```
换成"位姿门 + 打分 + top-M"生成 `prepay_due`。
**其余(matcher、ratio、COLMAP 默认 TVG、写库序列、finalize backstop)一字不动。**

#### 成本估算

| N | 候选对数(16/帧) | 采集期空闲 @16 ms | 全落 finalize @55 ms |
|---:|---:|---:|---:|
| 142 | 2,272 | **36 s**(摊到 142 帧 = 256 ms/帧) | 125 s |
| 300 | 4,800 | **77 s**(摊到 300 帧 = 256 ms/帧) | 264 s |
| 300 暴力全配对 | 44,850 | 12 min | 41 min |

**相对暴力:N=300 省 9.3×,且成本严格线性于 N。**
相对现状(12/帧 live + 官方 quadratic ~10/帧),**总匹配次数基本持平**,
只是把预算从"盲发的 2^k"挪到"位姿证明有重叠的 revisit"。

#### 预期效果(诚实分级)

| 指标 | 预期 | 强度 |
|---|---|---|
| 长程 inlier(gap>12) | **×3.0–3.3** | 【实测预测 + 留出验证】**但未真跑**,且这是"inlier 口径"上界,加了视差项后会降 |
| 匹配预算浪费 | −20% | 【实测,A.7】 |
| 拓扑平均 track 长度 | **+0.15 ~ +0.4**(3.84 → 4.0–4.2) | 【外推】A.6 剂量-响应强饱和 |
| **交付平均 track 长度** | **+0.3 ~ +0.6**(2.6–2.9 → 3.0–3.4) | 【文献先例,中】**ENFT 实测 2.28 → 3.10(+36%)是同 regime 同疗法**;A.9 的 16–24% 责任占比是下限侧的约束 |
| 位姿精度 / 漂移 | 可能**同时变好** | 【文献先例,中】Zhu(20× 少配对,精度相当)、cuSfM(7× 少配对,**每项指标都更好**)、MASt3R-SfM(6.9% 配对 ATE 优于完全图) |
| 回环 | 有真回环的 capture 上是**质变** | 【推断,中】90% 帧有未尝试 revisit(A.8)+ gauge 漂移 ±4–10.6% |
| 点质量(σ_depth / 视差) | **加了视差项后应改善;不加则可能变差** | 【推断,中】见 ④.3 的自我纠正 |

### ④.4 🔴 风险清单(必须在 P1 之前想清楚)

1. **🔥ARKit 会打不连续的重定位补丁,这会打断位姿判据。**
   [Here To Stay(arXiv 2109.14757)](https://arxiv.org/abs/2109.14757),iPhone 11,1363 场景实测:
   ARKit 平均漂移按用户动作分——聚焦移动 2.0 cm / 失焦 1.2 cm / 失焦移动 12.8 cm /
   **走开再回来 43.2 cm** / 暂停 2.5 cm。
   且所有"走开"场景里漂移 <3 cm 的,**都出现了帧间位移 >5 cm 的位置跳变**
   ⇒ **ARKit 内部在做地点识别并施加不连续修正**;命中就塌到 3 cm,不命中就是 43 cm。
   重定位延迟:暂停平均 2.9 s(0.5–5.1 s)、放下平均 1.4 s(0.0–7.1 s)。
   Kok & Solin 独立确认并实现了"启发式滤掉重定位跳变"。
   **⇒ ①"走开再回来"正是我们要抓的 revisit 场景,也正是 ARKit 位姿最不可信的时刻;
   ②ARKit 不会回写历史 `ARFrame.camera.transform`,采集时缓存的位姿与修正后读到的位姿可能处在不同 gauge。**
   **对策(有先例)**:Kimera-VIO 的 odometry-consistency 检查(`odom_trans_threshold=0.05 m`、
   `odom_rot_threshold=0.005 rad`,要求 odom+loop 环路复合近似单位阵)是最便宜的公开防线;
   我方现有的 `ProcessRevisitAnchors` **2-of-3 邻域确认**(seed ±1 至少 2 条过)本质上是同类防线,应保留。
2. **朝向门比位置门可信。** 实测 ARKit 旋转 RPE < 4°、roll/pitch 被重力锁定;位置 ATE 10–40 cm
   (Sensors 2022 OptiTrack:iPad Pro 11 **0.121 ± 0.027 m**、iPhone 11 **0.369 ± 0.105 m**,13 m 路径 160 s;
   多圈后**第 5 圈起稳定在 0.187 ± 0.005 m,不无界增长**)。
   ⇒ 固定米制半径 + **0.3–0.5 m 余量**对 3 分钟采集是站得住的;**不需要做协方差传播**(没有任何出货系统这么干)。
3. **A.5 的 ×3 有自证循环**(选择与评估用同一模型);A.4 的留出验证是唯一反证,
   且**从未在"生产候选集之外"的配对上验证过** —— 那正是新配对所在区域。
4. **本会话只有 2 个 capture,且都是室内小房间高 revisit 形态。**
   ⚠️ Skeletal Sets 的 Pisa2 结果提示:**单人有意采集的冗余度显著低于网络图集**
   (骨架集占 32% vs 11%)⇒ **文献里的 k 值对我们应当作下限,必须在自家 fixture 上标定。**

### ④.5 落地顺序(每步可独立签决)

1. **P0(零风险纯回收)**:在 `PrepayQuadraticTick` / `AddOfficialQuadraticPairs` 前加位姿门,
   把不过门的 2^k 对直接跳过。预期省 20% 匹配、质量不变,host 可逐位验证。
2. **P1(主菜)**:把 2^k 生成器换成"位姿门 + score + top-M(M=4)+ 隔 4 帧去冗余"。
   **必须先在 host harness 用真 db 跑一次,量实际 inlier / track / σ_depth**,
   兑现或推翻 A.5 的 ×3(**A.5 有自证循环风险,见该节 ⚠️**)。
3. **P2(升级判据)**:score 换成 `ScoreEnrichPair`(已有代码),直接对 track 升级需求排序。
4. **P3(另一场战役,杠杆更大)**:交付 2.6 vs 拓扑 3.7 的那 1.1 个观测在三角化/过滤段。
   A.9 显示 **27%/25% 的 track 缺口是"帧对匹配过但该对应没建立"** —— 那是匹配/比值检验与
   **track 缝合**的锅。COLMAP 的 post-BA re-triangulation 存在的理由原话就是
   "merge tracks and thereby provide increased redundancy for the next BA step",
   且自陈 **"after the second iteration results improve dramatically"**;
   Wu 2013 的 r₀=25% re-triangulation 同理("similar to loop-closing... able to reduce the drift
   errors without explicit loop detections")。
   **先确认我方的 re-triangulation 到底跑了几轮、有没有真在缝合 2-view 点** ——
   这比再加配对便宜得多。与已签决的"官方 TriangulateImage + `ignore_two_view_tracks=false`"路线合流。
5. **P4(正交省钱,可与 P1 并行)**:开 `EpiPriorMatchEnabled()`(位姿引导极线 1-D 搜索)
   与/或 Wu preemptive(top-100 大尺度特征预筛,t_h=4)。**它们降的是 55 ms 本身,不是配对数。**

### ④.6 明确不做

- ❌ **不上 vocabulary tree / BoW**:我方 vendored COLMAP 的 `colmap/retrieval/*` 被**刻意排除在 iOS 构建之外**
  (原文 "drags in FAISS + OpenMP, which the iOS toolchain lacks")。
  出厂 SIFT 词典 72.4 MB(32K 版 9.5 MB),再加 FAISS(安卓 aar 44.6 MB)+ OpenMP,**鸿蒙无任何构建**。
  **我们有位姿,不需要猜。**
- ❌ **不上 NetVLAD / MegaLoc / MixVPR / DINO 全局描述子**:多一个 ML 模型、多一套 CoreML+MNN 双导出、
  多几十~几百 MB 包体,换一个我们用位姿能更准算出来的东西。
  且 **MixVPR(PR #4544 的默认模型!)仓库无 LICENSE 文件、SALAD 是 GPL-3.0** —— 直接踩我方 license 铁律。
  唯一 license 干净的 SOTA 是 **MegaLoc(MIT 代码+权重)**,但 **914 MB、CoreML fp16 路径坏掉、不支持批处理**。
  若将来非上不可,**EigenPlaces-R18-512(MIT,43.7 MB,纯 ResNet 最好导)是风险调整后的首选**,
  ⚠️ 但它**没有任何公开延迟数据**,且这几个模型全部训练在 Google Street View 上,**权属另需法务过一遍**。
- ❌ **不做纯外观 revisit 检测**:A.4 的 gap 41–80 结果证明 ARKit VIO 漂移在该跨度内不影响位姿判据。
- ❌ **不抬 blind quadratic 的 overlap**:gap 128 段实测 **0 inlier**(A.2)。

---

## ⑤ 未找到清单

| # | 项 | 检索强度 | 状态 |
|---|---|---|---|
| 1 | **RC 的图像对候选生成机制**(是否有检索/预选,用什么索引) | 官方文档全表 + CLI 键表 + 存档论坛 + 专利库 + 学术产出,四路 | 🔴 **零证据支持或排除。这是本题的核心未知,且已确认公开面上不存在。** |
| 2 | RC 对齐控制台日志的阶段名 | 全网找用户贴的日志 | 🔴 **确认该表面不存在**(RC 只出事后 Alignment Report) |
| 3 | **RC 的对齐时间 vs 图数曲线** | Falkingham 全部帖子 + Puget + 论坛 | 🔴 **不存在公开数据**。Falkingham 两次承诺要测大数据集,两次没做 |
| 4 | Puget 的 RC 分阶段基准数值 | 抓了页面 | 🟠 **他们跑了 45/51/278/758 图的对齐独立脚本,但结果只以图片图表发布,HTML 无数值表** ⇒ **提取那些图表是本题性价比最高的后续动作** |
| 5 | RC 特征检测器身份 | 沿用前卷宗 | 🔴 未找到(既无指认也无排除) |
| 6 | COLMAP 词典树的每图索引/查询耗时 | 读了 ACCV 2016 原文 | 🔴 **论文原话 "We ignore retrieval and setup time"**;GitHub issue 里的报数 0.06–1.08 s/图,不可控 |
| 7 | 任何 VPR 模型在移动 SoC 上的延迟 | 全查 | 🔴 **全survey 无一个有手机 SoC 数字**;只有 Apple Silicon 笔记本的 CoreML 表 ⇒ **任何选型前必须先在 A16 上实测** |
| 8 | EigenPlaces 的推理延迟 | 论文+仓库 | 🔴 无任何公开数字 |
| 9 | 我方 ×3.0–3.3 的真跑验收 | 本会话只做了模型预测 + 留出验证 | 🟠 **必须 host harness 真跑**;A.5 存在自证循环风险 |
| 10 | `D_max = 0.5·z̄` 的标定 | 两个样本反推 | 🟠 未受控验证,需多场景标定(尤其室外) |
| 11 | RC 的 `sfmImagesOverlap` 到底改变哪一段耗时 | 只有员工的定性说法 | 🟠 员工说 "degradation is minimal (few %)",无数值 |
| 12 | **"每图配对数 → 平均 track 长度"的连续曲线** | 全查 | 🔴 **不存在这样的论文**。所有来源只给 3–4 个离散工作点;k≈25 的拐点是跨 PAIGE 与 ICRA-2020 推出来的,不是拟合的 |
| 13 | **与我们完全同构的消融**(~100–200 帧单人手持、已知米制位姿) | 全查 | 🔴 **不存在**。所有扫描都在网络图集或抽帧视频上,冗余更高且无位姿先验 |
| 14 | Metashape reference preselection 的邻居数 / 距离规则 | 手册 + Java API + 论坛 | 🔴 **Agisoft 从未公开** |
| 15 | Pix4D `matchRelativeDistanceImages = -1.5` 的符号语义;"Free Flight or Terrestrial" 内部 | 官方支持页 + 模板 | 🔴 无文档 |
| 16 | RTAB-Map `LocalRadius=10 m` 是否就是 proximity detection 用的半径 | 文档有,源码未逐行核 | 🟠 "10 m + depth 50 + 45°" 按**高置信但未源码验证**处理 |
| 17 | MicMac 官方文档 | `DocMicMac.pdf` 下载损坏、`micmac.ensg.eu` TLS 失败 | 🟠 所有 MicMac 结论来自源码 + CLI 补全 |

### ⑤.1 本次检索中被推翻的既有说法(含我方自己的)

| 说法 | 判决 |
|---|---|
| "RC 的 preselector 是图像对预选漏斗"(**我方前卷宗**) | 🔴 **推翻**。它是每图特征筛选(CR 员工原话) |
| "RC 的 Image overlap 控制邻域窗口" | 🔴 **推翻**。它是裁图(用中央区域 vs 全图) |
| "works linearly, so doubling the inputs roughly doubles processing time" 是官方说法 | 🔴 **推翻**。无引用的 Wikipedia 句子;官方的"线性"指内存 |
| Falkingham 的 397 s / 593 s 能说明匹配扩展性 | 🔴 **推翻**。那是全管线,对齐只占 1–2.6% |
| "RC 检测 40k 只匹配 10k,所以效率 75%" | 🔴 **推翻**(我方样本 A 有 54/254 张图观测数 >10,000,最大 14,201) |
| "VocMatch 能拿到更长的 track" | 🔴 **推翻**。论文自陈 **"vocabulary-based matching is in fact stricter and cannot always find the complete track"**、**"shorter tracks mean fewer rays per point and thus higher uncertainty"**;PAIGE 佐证其注册图数只 4,247 vs 13,544–14,767 |
| "Sweeney ICCV 2015 是配对数削减论文" | 🔴 **推翻**。它优化相对几何**质量**;可复用的是 §4.1 的 MST + 三元环闭合 |
| "OpenSfM `matching_gps_neighbors` 默认 20" | 🔴 **推翻**。默认 **0**(检索默认全关),只有 `matching_gps_distance=150` 非零 |
| Wu 2013 的 `t_h` 是固定 4 | 🔴 **推翻**。自适应(先试 4,再试 8 或 2) |
| ODM 有 `--matcher-distance` | 🔴 **推翻**。当前 ODM 已无此参数 |
| 我方 A.3/A.5 的"越近越好"打分足够 | 🟠 **自我纠正**。纯邻近会饿死三角化角,必须加非对称视差项(③.8) |
| "RC 用 O(n²) → k·m² overlap-aware subscene scheduling",归因 arXiv:2505.16951 | 🔴 **编造**。抓取原文核实:该论文根本不讨论对齐复杂度。**不要引用** |

**⚠️ 一条被识破的编造**:检索过程中出现过一个说法,称 RC 用
"O(n²) → k·m² overlap-aware subscene scheduling",归因到 [arXiv:2505.16951](https://arxiv.org/abs/2505.16951)。
**抓取该论文核实:全文根本不讨论对齐复杂度。该说法系编造,不要引用。**

---

## 附录 A:本会话首次实测(cap7_day / cap3_eve 双 capture)

数据源:`_host_fixtures/{cap7_day,cap3_eve}/official_sfm_live.db`(两视图几何 inlier + keypoints)
与 `official_sfm_fed_frames.jsonl`(逐帧 ARKit 位姿)。脚本落 `_host_fixtures/preselector_sim/pairsim.py`。
**朝向夹角的计算与 ARKit/COLMAP 轴向约定无关**(两个前向向量同时翻号,夹角不变;已数值验证)。

### A.1 两个 capture 的形态

| | cap7_day | cap3_eve |
|---|---:|---:|
| 帧数 | 146 | 156 |
| 相机中心 bbox | 2.37 × 1.23 × 3.45 m | 2.66 × 1.51 × 3.22 m |
| **路径总长** | **29.5 m** | **33.5 m** |
| 已验证配对(TVG 行) | 1991 | 1675 |
| 全部 inlier | 705,667 | 495,136 |
| 相邻帧朝向变化 | 均值 11.0°,中位 7.9°,max 47.1° | — |

**路径 29.5 m 却只在 3.4 m 的盒子里** ⇒ 来回走了约 8 遍。**这类采集天然充满 revisit,
而 revisit 恰恰是纯时序候选集构造性看不见的。**

### A.2 生产候选集的 gap 直方图(cap7_day)

| gap | 配对数 | 非零 | 平均 inlier |
|---:|---:|---:|---:|
| 1 | 145 | 99% | 1475.7 |
| 4 | 142 | 86% | 372.7 |
| 8 | 133 | 77% | 223.0 |
| 12 | 134 | 63% | 142.8 |
| **16** | 130 | 64% | **143.3** |
| **32** | 110 | 39% | **37.3** |
| **64** | 81 | 11% | **15.2** |
| **128** | 15 | **0%** | **0.0** |

官方 quadratic 的 gap 64/128 段(96 对)**产出 0.0–15 inlier,近乎纯浪费**。
与代码里已有的注记("gap-16 pairs average ~130 inliers while gap-128 pairs average 0.7",
`official_aether_sfm_c.cc` ENRICH-ORDER)独立吻合。

### A.3 🔥核心实测一:纯位姿(零外观)是配对价值的强预测器

**cap7_day,按朝向夹角分桶**

| θ | n | 非零 | 平均 inlier |
|---|---:|---:|---:|
| <10° | 401 | 91.8% | 793.0 |
| 10–20° | 571 | 85.8% | 414.5 |
| 20–30° | 376 | 80.1% | 284.1 |
| 30–45° | 334 | 65.6% | 108.1 |
| 45–60° | 179 | 43.6% | 40.4 |
| 60–90° | 119 | 12.6% | 6.9 |
| >90° | 11 | 9.1% | 1.5 |

**按相机中心距分桶**

| d | n | 非零 | 平均 inlier |
|---|---:|---:|---:|
| <0.25 m | 242 | 99.6% | 1310.3 |
| 0.25–0.5 | 513 | 91.8% | 494.6 |
| 0.5–0.75 | 481 | 85.2% | 205.2 |
| 0.75–1.0 | 314 | 65.6% | 82.6 |
| 1.0–1.5 | 261 | 50.6% | 37.8 |
| 1.5–2.0 | 63 | 17.5% | 4.3 |
| 2.0–3.0 | 107 | **0.9%** | 0.2 |
| >3.0 | 10 | **0%** | 0.0 |

**门限扫描(两 capture 合并)**

| 门 (d, θ) | 保留配对 | 保住 inlier | 效率 |
|---|---:|---:|---:|
| 0.75 m / 30° | 45.9% | 87.9% | 1.92 |
| **1.0 m / 45°** | **68.9%** | **97.6%** | **1.42** |
| 1.25 m / 45° | 75.9% | 98.4% | 1.30 |
| 1.5 m / 45° | 79.0% | 98.8% | 1.25 |
| 1.5 m / 60° | 86.7% | 99.8% | 1.15 |
| ∞ / 45° | 83.2% | 98.8% | 1.19 |
| 1.5 m / ∞ | 90.2% | 99.9% | 1.11 |

⇒ **1.0 m / 45° 砍掉 31% 预算只损失 2.4% inlier。** 距离与角度都有独立判别力,联合最优。

### A.4 🔥核心实测二:留出验证(模型只用 gap≤12 拟合,测 gap>12)

| gap | cap7 实测/模型 | cap3 实测/模型 |
|---|---:|---:|
| 13–20 | 0.96 (n=93) | 0.96 (n=111) |
| 21–40 | 0.84 (n=49) | 1.20 (n=53) |
| 41–80 | 0.87 (n=10) | 0.90 (n=9) |

**⇒ 控制住位姿几何后,时间 gap 本身几乎没有独立预测力(比值 0.84–1.20,均值≈0.95)。
这构造性地判死了"用时间 gap 当候选判据"。**
⚠️ gap 41–80 样本仅 n=9/10,该段强度低。

### A.5 🔥核心实测三:等预算替换,长程 inlier ×3.2–3.3

候选池 = 全部 (i,j),gap>12、生产从未匹配、过 1.5 m/45° 门;按 (d/1.5 + θ/45) 升序、
同一 i 的伙伴彼此至少隔 4 帧,每帧取 top-M:

| M | cap7 新增对 | cap7 预测 inlier | cap3 新增对 | cap3 预测 inlier | @55 ms | @16 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 2 | 250 | 66,874 | 267 | 70,714 | ~14 s | ~4 s |
| **3** | **357** | **80,167** | **368** | **85,785** | ~20 s | ~6 s |
| 4 | 445 | 86,414 | 455 | 97,104 | ~25 s | ~7 s |
| 6 | 561 | 94,041 | 578 | 109,595 | ~31 s | ~9 s |
| 8 | 612 | 97,354 | 651 | 115,721 | ~34 s | ~10 s |
| 12 | 646 | 100,658 | 704 | 119,865 | ~36 s | ~11 s |

**等预算对照(M=3 vs blind quadratic)**

| | cap7_day | cap3_eve |
|---|---|---|
| blind quadratic | 336 对 → **23,962 inlier(实测)** | 389 对 → **26,987(实测)** |
| 位姿门 M=3 | 357 对 → 80,167(预测) | 368 对 → 85,785(预测) |
| **同预算 inlier 倍数** | **×3.3**(按 A.4 打 0.95 折 ⇒ **×3.2**) | **×3.2**(打折 ⇒ **×3.0**) |

**收益递减**:M>6 基本平掉(cap7:M=6→12 只 +7%)。**推荐 M=3–4。**

⚠️ **循环性声明**:预测值来自同一个位姿→inlier 模型,选择也用它,**存在自证风险**。
A.4 的留出验证是唯一反证据(模型跨 gap 泛化良好),但**从未在"生产候选集之外"的配对上验证过**
—— 那正是新配对所在区域。**该 ×3 必须由 host harness 真跑一次才算落地。**

### A.6 🔥核心实测四:track 长度的真实天花板

对 `two_view_geometries` 的 inlier 对应做并查集(对应图的拓扑 track):

| | 全部生产配对 | 只留 gap≤12 |
|---|---:|---:|
| cap7_day 平均 track | **3.838** | 3.671 |
| cap3_eve 平均 track | **4.138** | 3.815 |

过并合污染检查(同一 track 含同图两点):cap7 仅 **1.3%**,干净 track 均值 **3.699** ⇒ 这个数是实的。

**剂量-响应(cap7,近窗 + 按 inlier 排序取 top-k 长程对)**

| 长程对数 | 长程 inlier | 平均 track |
|---:|---:|---:|
| 0 | 0 | 3.671 |
| 50 | 20,161 | 3.811 |
| 100 | 23,198 | 3.834 |
| 全部 135 | 23,962 | 3.838 |

**头 50 条高质量长程对吃掉 84% 的 track 增益**,后面 85 条几乎白给
⇒ 价值高度集中在少数高质量长程对,**这正是位姿门能精准命中的那批**。

### A.7 实测五:门外配对可安全丢弃

| | 平均 track | track≥3 |
|---|---:|---:|
| cap7 全部 1472 条非零对 | 3.838 | 69,280 |
| 仅过 1.5m/45° 门的 1367 条 | 3.813(**−0.025**) | 69,268(**−0.0%**) |
| cap3 全部 1241 条 | 4.138 | 38,917 |
| 仅过门的 1159 条 | 4.111(**−0.027**) | 39,002(**+0.2%**) |

⇒ **位姿门是零质量代价的预算回收**(cap7 生产 1991 对里 393 条不过门 = 19.7%)。

### A.8 revisit 密度:纯时序方案漏掉了什么

| | cap7_day | cap3_eve |
|---|---:|---:|
| 每帧过门的更早帧数 | 均值 27.0 / 中位 26 / max 70 | 均值 27.8 / 中位 26 / max 74 |
| 其中 gap>12(真 revisit) | 均值 **17.0** / max 62 | 均值 **18.1** / max 66 |
| **至少有 1 个 revisit 伙伴的帧** | **131/146 = 90%** | **140/156 = 90%** |

**⇒ 90% 的帧存在几何上成立、生产从未尝试的 revisit 伙伴。**

### A.9 🔥核心实测五:track 缺口的责任归因(决定该往哪投入)

对拓扑 track(长度 3–12)内部所有"本应存在的边"分三类:

| | cap7_day | cap3_eve |
|---|---:|---:|
| 可能边总数 | 734,320 | 416,570 |
| **已建立** | 419,722(**57.2%**) | 212,899(**51.1%**) |
| **帧对匹配过、但该对应没建立** ← 匹配/比值检验 | 198,464(**27.0%**) | 104,679(**25.1%**) |
| **帧对从未匹配** ← **候选选择** | 116,134(**15.8%**) | 98,992(**23.8%**) |

**⇒ 候选选择只占 track 缺口的 16–24%。这是本卷对"该投多少资源在候选选择上"最直接的定价。**

track 边密度(cap7,按 track 长度):

| L | 2 | 3 | 4 | 5 | 6 | 8 | 10+ |
|---|---:|---:|---:|---:|---:|---:|---:|
| 边密度 | 1.000 | 0.820 | 0.722 | 0.655 | 0.596 | 0.522 | 0.367 |
| "近乎完全图"占比 | 100% | 46.1% | 40.1% | 29.6% | 19.7% | 9.0% | 1.5% |

**长 track 是稀疏链而不是完全图** —— 这既是"加对能帮上忙"的机制,也是"帮不了太多"的上界。

---

## 相关文件

- 本会话脚本:`_host_fixtures/preselector_sim/pairsim.py`
- 生产候选选择代码:`aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`
  —— `SelectStreamCandidates:753`、`BuildSpatialAnchors:2053`、`BuildQuadraticAnchors:2120`、
  `ScoreEnrichPair:2310`、`AddOfficialQuadraticPairs:3875`、`PrepayQuadraticTick:7651`
- 出货开关:`ios/Runner/OfficialAetherARKitPlugin.swift` 的 `setenv` 块
  (`OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY=1`、`OFFICIAL_AETHER_LIVE_CAND_K_HOT=6`)
- 前置卷宗:`RS_EXPORT_ARTIFACT_FORENSICS_2026-07-28.md`、`RS_TEAM_FULL_HISTORY_DOSSIER_2026-07-28.md`
  (⚠️ 后者 §四 第 2 行关于 preselector 的描述**被本卷推翻**)、
  `COLMAP_QUADRATIC_OVERLAP_RESEARCH_REPORT_2026-07-20.md`
