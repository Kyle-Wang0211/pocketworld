# 12MP 每对匹配深度塌陷:机制定罪与修复候选(2026-09-02)

接 `2026-09-02-funnel-remeasure.md`(每对 verified 中位 136–146 ≈ 8192 预算的 2%)。
全程主机侧:未碰手机、未启动 app、未 commit。原始数据 `~/Developer/pw_funnel_20260902/`
(build 89 两场)+ `~/Developer/device-backups/PocketWorld/com.kyle.PocketWorld_20260723T2148_ratio08_preupdate/`
(07-23 三场同 12MP 对照 + **photos_highres 实拍 12MP 照片**,本次机制实验的关键素材)。

## 判决摘要(三句)

1. **塌陷发生在 raw match 段的 Lowe ratio 检验,且其真因是提取端预算裁剪**:build 89 两场全部
   打满 8192,COLMAP (octave↓,scale↓) 裁剪把细尺度整族裁掉(20帧场中位图 **octave 0 全部被裁**,
   最细存活尺度 = 3.20px,恰在尺度晶格 1.6·2^(k/3) 上);用同一批 12MP 实拍照片在主机复现该
   截断点,每对 verified 深度损失实测 **−27%(截到 2.54)/ −50%(截到 3.20)**。
2. **四个候选假设判决**:① 预算裁剪 = **定罪**(方向修正:不是"粗尺度语义漂移",而是细尺度族
   被整体删除,它们贡献每对 27–50% 的匹配);② 像素阈值被动收紧 = **证否**(max_error 4→6px 扫描
   verified 平坦;12MP vs 4K 仿真臂深度打平);③ ratio/互检杀伤 = **确认为死亡地点但非独立机制**
   (单向 8192→256/544,全部死在 ratio;距离门 0 杀伤;其杀伤强度是特征族+场景的函数,参数语义
   从未变过);④ GPU 匹配内部上限 = **证否**(主机全精度暴力重放与设备结果**逐位一致**)。
3. **修复候选按实测收益排序**:guided matching(COLMAP 自身机制)×2.4–3.1 但背着 08-11
   "极线分不出第 N 根木纹"的交付质量判死史;ratio 0.8→0.85 = +25~43% verified、GPU 零成本、
   风险最小;预算配平(12288/16384)+37%~+100% 但 GEMM ×2.25/×4;max_image_size=3200(唯一
   严格"抄上游默认")在不饱和场景实测**负向**,只在饱和场景可能为正,需真机 A/B。

## 0. 尺子与阳性对照(先验一遍,全过)

| 尺子 | 阳性对照 | 结果 |
|---|---|---|
| 主机重放匹配器(角度域 ratio+max_distance+互检,`replay_match.py`) | 与 build89 db `matches` 表逐对比对(140 对 + 46 对) | **逐对相对差中位 = 0.000,p90 = 0.000(逐位一致)** |
| 主机 TVG(pycolmap `estimate_calibrated_two_view_geometry`@4px) | 与 db `two_view_geometries` 行数逐对比对 | 相对差中位 2.4%(20f)/1.7%(51f gap1),p90 ≈ 10%(RANSAC 随机 + 产线是重力 upright 变体) |
| `depth_diag.py` 聚合 | 复现 funnel2 已知量(319/140 对、覆盖 23.7%/19.7%、tvg config 2/6 直方) | 全吻合 |

## 一、"每对能产多少 verified 匹配"的完整判定链(file:line + 现值 + 上游默认)

生产路线(build 89):Dart `official_aether_sfm_ffi.dart` → C `official_aether_sfm_c.cc` AddFrame
匹配循环(9119–9777)→ Metal 匹配核(`pwofficial_gpu_match.mm`,与
`Aether3D-cross/aether_cpp/official_pipeline/src/official_gpu_match.mm` **逐字节相同**,diff 已核)。

### 1.1 提取端(决定"有什么可匹配")

| 参数 | 现值 | 出处 | COLMAP 上游默认 | 12MP 语义是否隐性变严 |
|---|---|---|---|---|
| max_num_features | **8192** | Dart `official_aether_sfm_ffi.dart:992` `researchMaxFeatures = 8192`;C 兜底 `official_dsp_sift_gpu_c.cc:192,232` | `SiftExtractionOptions` 默认同为 8192 | **是(核心)**:上游 8192 是与 max_image_size=3200 成对的;12MP 全幅检测数≈1.5–2.8×8192(外推,§2.2),裁剪深入细尺度 |
| max_image_size | **无(全幅 4032 喂入)** | `official_dsp_sift_c.cc:52-57` 直接构造 extractor,绕过 controller;GPU 路同(gpu_sift_feat.log 记 4032x3024) | **3200**:`extractor.cc:118-124` `case FeatureExtractorType::SIFT: return 3200;`;controller 先降采样再把 keypoint `Rescale` 回原坐标(`controllers/feature_extraction.cc:395-398`, `:55`) | **是**:我们没抄上游"降采样后提特征"的默认预处理 |
| 预算裁剪规则 | (octave↓, scale↓) 组裁剪 | `official_dsp_sift_gpu_c.cc:235-278`(注释自证对齐 sift.cc:403-440) | `sift.cc:403-440`:sort "feature1.o > feature2.o … feature1.s > feature2.s",组边界处 `keypoints->size() >= max_num_features` 即停;另一形态 `utils.cc:71-105 ExtractTopScaleFeatures`(按 `ComputeScale()` 降序保前 N) | 语义一致;但 12MP 下同一规则**裁得更深**(§2.2) |
| first_octave | **0**(无 2× 上采样八度) | `sift_pyramid_dawn.h:58` `int first_octave() const { return 0; }`(注释:validated port baseline) | CPU 默认 **-1** | 中性(两个时代设备端都是 0) |
| peak / edge threshold | **0.004 / 15.0** | GPU `sift_extract_dawn.h:95`(与 CPU `official_dsp_sift_c.cc:66-68` lock-step) | 0.02/3≈0.0067 / 10 | 我们更松(更多检测)⇒ 加剧饱和裁剪 |
| DSP / affine | DSP on(10 scales)/ affine off(GPU 路) | `official_dsp_sift_c.cc:60-62`(CPU 路 affine on);GPU 计划文件 AFFINE_OFF | domain_size_pooling 默认 off | 中性 |

### 1.2 匹配端(raw match)

| 参数 | 现值 | 出处 | COLMAP 上游默认 | 12MP 隐性变严? |
|---|---|---|---|---|
| Lowe ratio (max_ratio) | **0.8** | Dart `official_aether_sfm_ffi.dart:996,1020` `defaultMatchMaxRatio = 0.8`;C 默认 `official_aether_sfm_c.cc:8596` `out->match_max_ratio = 0.8f;`;live 取用 `:9229-9231`;契约测试钉死 `pw-head-0827/test/official_match_ratio_contract_test.dart:27,31` | `sift.h:114` `double max_ratio = 0.8;` | **否**(无量纲角度比;但它是全部死亡发生地,§2.1) |
| max_distance | **0.7(rad,角度域)** | 核内硬编码 `pwofficial_gpu_match.mm:737,1578` `float maxDistance = 0.7f;` | `sift.h:117` `double max_distance = 0.7;` | **否——实测 0 杀伤**(两场全部 8192/8192 过此门,§2.1) |
| 距离域 | acos(dot/512²),best/second 取最大点积,second 初值 0→acos(0)=π/2 | 核 `pwofficial_gpu_match.mm:413-432`(注释直引 colmap sift.cc:770,801-816);判定 `keep = (bd <= maxDistance) && (bd < maxRatio * sd)` :432 | 同(`FindBestMatchesOneWayBruteForce`) | 否(逐位一致已证) |
| 互检 (cross_check) | **on**,双向 best 相互指认 | 发射循环 `pwofficial_gpu_match.mm:842-857`(v2 同 :1686) | `sift.h:120` `bool cross_check = true;` | 否(实测互检段再砍 ~33%,两时代同语义) |
| 匹配对上限 | cap = min(n1,n2)(互检唯一性上界,非裁剪) | `official_aether_sfm_c.cc:9512-9515` | — | 否(不可能触顶) |
| 候选集 | k=12(空间10+时间2)+ 回环每10帧≤4 | `official_aether_sfm_c.cc:1640-1651`(K-REWIRE)、`:9157-9226`;Dart k=12 `official_aether_sfm_ffi.dart:993` | COLMAP 无此概念(穷举/词表) | 构成效应:gap>6 的宽基线对占 39–60%,天然浅(§2.4) |
| guided matching | **默认关**(GuidedTemporal/PoseDirectE/EpiPrior 全 env-gated OFF) | `official_aether_sfm_c.cc:2854-2860, 2878-2884, 3075+` | COLMAP 有一等 guided 机制(SiftMatchingOptions.guided_matching,默认 false) | —(修复候选,§3.2) |

### 1.3 几何验证端(TVG)

| 参数 | 现值 | 出处 | 上游默认 | 12MP 隐性变严? |
|---|---|---|---|---|
| TVG options | **colmap 默认全套** | `official_aether_sfm_c.cc:9232` `const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults` | `two_view_geometry.h:118-124`:max_error **4.0**、confidence 0.999、min/max_num_trials 100/10000、ransac min_inlier_ratio 0.25;`:47` min_num_inliers **15**;`:51` TVG 级 min_inlier_ratio 0.0(禁用) | max_error 名义上是像素域,但见下行 |
| max_error 的实际语义 | 4px ÷ 焦距 → 归一化 Sampson 阈值 | `mandatory_gravity_tvg_v1.cc:104-117`(`0.5*(CamFromImgThreshold(a)+CamFromImgThreshold(b))`,平方) | `EstimateCalibratedTwoViewGeometry` 同法 | **基本否**:fx(12MP)=2834–2873 vs 07-23 同镜头 2944–2996,像素/角度密度同量级;**实测扫描 4→4.58→5.23→6px 的 verified 中位平坦**(§2.5)⇒ 该假设证否 |
| 估计器 | 重力约束 upright 相对位姿 RANSAC(E)+ colmap `EstimateTwoViewGeometry`(force_H)做平面判定 | `mandatory_gravity_tvg_v1.cc:122-196`;入口 `official_aether_sfm_c.cc:9722-9725`;可持久化判据 kValid∥kPlanar `:468-472` | 上游是 E/F/H 多模型;此为经签决的 mandatory-gravity 变体 | 主机 plain-COLMAP TVG 重放行数与 db 差中位 ≤2.4% ⇒ 对深度问题两者等价 |
| 写库 | 仅 Persistable 对写 matches+TVG | `official_aether_sfm_c.cc:9727-9735` | — | — |
| finalize 消费门 | min_num_matches=15 | `official_aether_sfm_c.cc:5621,5625`;上游 `incremental_pipeline.h:49`;live 有效对门 `:5705` kRematchValidInlierGate=15 | 15 | 否 |

其他:热降 K(默认关,hot_k=0,`:9164-9169`)、probe-gate(默认关,08-08 判死回滚,`:2315-2340`)、
match-TVG overlap 默认**开**(`:3037-3043`,只影响耗时归账不影响结果集)。

## 二、真数据拆解

### 2.1 塌陷环节定位:全部死在 ratio 检验,验证层无罪

主机重放(与设备逐位一致的尺子)单向分解,**逐对中位**:

| 段 | B89-20f(140 对全量) | B89-51f(46 个 gap-1 对) |
|---|---|---|
| 入口特征 nA | 8192 | 8192 |
| 过 max_distance(≤0.7 rad) | **8192(0 杀伤)** | **8192(0 杀伤)** |
| 过 ratio 0.8 | **256(−96.9%)** | **544(−93.4%)** |
| 互检后(=写库 raw) | 152(−41%) | 358(−34%) |
| TVG verified | 136(−10.5%,存活 87.5%) | 276(存活 ~78%) |

raw→verified 存活率两场 82.7%/87.5%(07-23 三场 81–93%)⇒ **几何验证段不是塌陷点**。
死亡全部集中在 ratio 检验:2nd-NN 距离 ≥ 0.8×1st-NN 的特征只有 3–7%。
(max_distance=0.7 rad 对全正的 RootSIFT 向量天然钝刀——任意两个全正向量的夹角很少超过 40°。)

### 2.2 预算裁剪定罪(假设①,方向修正)

**(a) 裁剪深度的直接观测(build89 自己的 db)**:keypoints blob(6 列 affine)解出尺度,
每图最细存活尺度恰落在 DoG 尺度晶格 σ=1.6·2^(k/3) 上 —— 这是 (octave,scale) 组裁剪的指纹:

| | 51帧场 | 20帧场 | 07-23 三场(同 12MP 对照) |
|---|---|---|---|
| 打满 8192 图占比 | 45/51 | **20/20** | 6–8/25–38(基本不饱和) |
| 每图最细存活尺度 p10/中位/p90 | 1.60 / **2.54** / 3.20 | 2.54 / **3.20** / 4.03 | (07-23 build 未持久化尺度,blob 全 1.0) |
| 存活集尺度中位 | 5.67 | 7.64 | 主机同场景无裁剪提取的中位 ≈2.6–2.8(46% 特征 <2.54) |

20帧场中位图:**octave 0 整个被裁**(<3.20px 的检测一个都没进库)。按主机同分辨率场景的
尺度分布外推,raw 检测量 ≈ 8192/0.36 ≈ **2.3 万**(51帧场 ≈1.5 万)——外推值,build89 的
`gpu_sift_feat.log` 未拉取(在设备上,本任务不碰手机),07-23 的该日志证实不饱和场 feat_raw
2.4k–6.9k 与 kept 相等。

**(b) 裁剪代价的同场景实测(`clamp_cost.py`,07-23 实拍 12MP 照片,COLMAP 自身提取+裁剪语义,
产线同参:first_octave=0 / peak 0.004 / edge 15 / DSP on / 8192 语义)**,3 个相邻对中位:

| 臂 | 每图特征 | raw/对 | verified/对 | 相对 full |
|---|---|---|---|---|
| full(不裁) | 7468 | 1464 | 1372 | — |
| top8192(现役预算,此场景不触发) | 7468 | 1464 | 1376 | 0 |
| **cut@2.54(= 51帧场实测截断点)** | 3997 | 1059 | **995** | **−27%** |
| **cut@3.20(= 20帧场实测截断点)** | 2673 | 733 | **686** | **−50%** |

细尺度族(<2.54/<3.20)贡献每对 27–50% 的 verified 匹配;被裁后每对深度相应塌掉。
注意方向修正:**不是"粗尺度特征匹配差"**——粗尺度存活者的人均匹配率反而更高
(cut320 臂 27.4%/特征 vs full 臂 19.6%)——**是数量被删**。build89 自己的分尺度命中率表
同样显示紧贴截断点的细尺度 bin 命中率被压到 5.8–9.8%(伙伴图里对应特征被裁的"边界翻腾"),
平台区 25–32%。

### 2.3 分辨率本身证否(假设②提取侧)+ 同帧三方对拍(假设④与提取器质量)

**跨分辨率三臂(`xres_experiment.py`,同一批 12MP 照片)**:A=4032 全幅、B=3200(COLMAP 默认)、
C=中央裁 4032×2268→3840×2160(复刻 4K 时代取景与像素密度)。gap-1:
A raw 990 / B 868 / C 968 —— **A≈C**,12MP 口径本身不塌陷(不饱和时);B(降采样)在不饱和场景
还**略负**(特征少了)。

**同帧同对三方对拍(`exact_pair_cmp.py`,07-23 场 10 帧)**:
(i) db 行数(设备 GPU 提取+当时的 GPU 匹配);(ii) 主机匹配@设备描述子;(iii) 主机匹配@主机
COLMAP-CPU 提取(同 jpg 同参)。gap-1 raw 中位:(i) 887 <(iii) 990 <(ii) **1167**。
- (ii)>(iii):**设备 GPU 提取器不劣于 COLMAP CPU 提取,反而更深** ⇒ 提取器质量嫌疑排除;
- (ii)>(i) 约 +20%:07-23 备份是 "preupdate" 旧匹配核(角度域 COLMAP-parity 核的修复注释列明
  旧核缺 max_distance 门、域不对,`pwofficial_gpu_match.mm:254-266`);build89 上 (i)==(ii) 逐位
  ⇒ **现役匹配器无罪(假设④证否)**,且 07-23 对照臂的 raw 数字系统性偏低 ~20%(对照更保守)。

### 2.4 候选构成对"每对中位"的稀释(不是缺陷,是口径警告)

TVG 深度按 gap 分层(db 实测,逐场):

| gap | 51帧场 n/中位 | 20帧场 n/中位 |
|---|---|---|
| 1 | 46 / 276 | 19 / 497 |
| 2–3 | 51 / 129 | 33 / 141 |
| 4–6 | 31 / 56 | 33 / 132 |
| 7–12 | 59 / 138 | 34 / 102 |
| ≥13 | 132 / 149 | 21 / 65 |

gap>6 的宽基线/回环对占 60%(51f)/39%(20f),天然浅。07-19@4K 的每对深度未存分层数
(db 已失),用"每 kp 0.44–1.24 × 8192 ÷ 伙伴 5.3–10.3"反推每对均值 ≈ 990–1900——但那批会话
walk 路径、触发参数、(很可能)ratio 口径都不同(07-19 审计读的是 self 路 `sfm_live.db`,self 路
Dart 默认 ratio **0.7**,`aether_sfm_ffi.dart:713`;若属实,4K 臂还是在更严的 ratio 下达到的,
塌陷倍数只会更大,不会更小)。**2.4–7× 里有构成效应与口径噪声,机制归因以 §2.2 的同场景
实测为准。**

### 2.5 COLMAP 语义内的敏感性扫描(主机重放,尺子逐位)

**ratio(max_ratio ∈ {0.7, 0.8, 0.85, 0.9},max_distance 固定 0.7)× TVG max_error ∈ {4.0, 4.58, 5.23, 6.0}**:

B89-20f 全量 140 对(verified 中位):

| | @4.0px | @4.58 | @5.23 | @6.0 |
|---|---|---|---|---|
| ratio 0.7 | 56 | 56 | 56 | 56 |
| **ratio 0.8(现役)** | **138** | 140 | 140 | 142 |
| ratio 0.85 | 197 | 198 | 200 | 202 |
| ratio 0.9 | 266 | 272 | 276 | 280 |

B89-51f gap-1 46 对:0.8→278,0.85→348,0.9→420;max_error 4→6px 仅 +11% 以内。

⇒ **max_error 抬高(哪怕到"对角线等比"的 5.23)对 verified 深度无实质作用——假设②证否**;
ratio 是唯一有杠杆的匹配段参数:0.85 = +25~43%,0.9 = +51~93%。
(附:12MP 对 4K 的真实对角比是 5040/4406 = **1.144**,不是任务书里的 1.31;1.31 是把
(4032·3024)/(3840·2160) 面积比 1.47 开平方后的误传。扫描无论按哪个比都平,不影响结论。)
代价侧:raw→verified 存活率 0.8/0.85/0.9 = 91%/85%/73%(20f),外点进入量随之升。

### 2.6 guided matching 重放(COLMAP 自身机制;在树已有实现,默认关)

`guided_replay.py`:产线 raw match → TVG@4px 得 F → F 的 4px 对称外极带内重配
(带内 L2 域 ratio 0.8,带外候选=COLMAP 哨兵距离,互检)→ 新 TVG,**仅严格更多才采纳**
(在树 RED LINE 语义,`official_aether_sfm_c.cc:9632-9637`)。B89-20f 分层抽 24 对(覆盖各 gap):

- **24/24 采纳,verified 中位 132 → 350(逐对提升中位 ×3.12),总 inlier +133%**。
- 机制上这正是 §2.1 的镜像:ratio 杀伤源于 2nd-NN 拥挤,外极带把带外的 2nd-NN 拿掉后
  同一批对应就活了 ⇒ **"12MP 下 ratio 杀伤大"的本质是描述子空间拥挤,不是阈值语义漂移**。
- ⚠️ 历史红旗(必须一起交代):08-11 用户签决判死的是引导链**第二级**(ARKit 位姿自举救饿死对):
  achieved 101/101 注册但米制尺度崩到 0.70/0.78、P@2cm 99%→85%、净增 935 孤立浮点,
  根因"极线分不出第 N 根木纹和第 N+1 根"(`official_aether_sfm_c.cc:2862-2877`,"保持默认关,
  勿复活")。本次测的是**第一级**(数据自证种子,只在严格更好时替换),没被判死但同一失效
  模式未清 —— **inlier 数不是交付质量,此候选只能连着交付质量门上机**。

## 三、判决

### (a) 主因

**提取预算与输入分辨率失配 → COLMAP (octave,scale) 裁剪整族删除细尺度特征 → 每对可匹配
对应体量塌缩,死亡在 ratio 检验处显形。** 证据链:①饱和率 88–100% + 最细存活尺度落晶格
(2.54/3.20,直接观测);②同场景同参数复现该截断点损失 −27%/−50%(实测);③分辨率三臂打平
+ 同帧三方对拍排除匹配器/提取器/阈值语义(实测/逐位);④验证段存活 82–93%(无罪)。
残差:build89 两场与对照场景不同(疯狂拐弯/运动模糊),场景项无法在无 build89 照片的条件下
从裁剪项中完全剥离——裁剪解释 1.4–2.0×,观测总塌陷(对 4K 锚点)2.4–7× 的其余部分由
场景难度、候选构成(§2.4)与 07-19 口径不确定性分担。

### (b) 修复候选(全部 = COLMAP 自身参数/机制;预估用重放数据)

| 候选 | 上游出处 | 预估每对 verified 中位(现 136–146) | 忠实度 | 备注 |
|---|---|---|---|---|
| **R1: max_ratio 0.8→0.85** | `sift.h:114`(COLMAP 参数,非默认值;任务书指定扫描范围) | **→ ~195–205**(20f 全量实测 +43%,51f gap1 +25%) | 语义内,偏离默认 | GPU 零成本;外点存活率 91%→85% |
| R1′: 0.9 | 同上 | → ~265–280(+51~93%) | 同上 | 存活率降到 73%,下游 tri/BA 压力需 A/B |
| **R2: guided matching** | COLMAP 一等机制(upstream `guided_matching` 选项,默认 false);在树 `OFFICIAL_AETHER_GUIDED_TEMPORAL` 已实现 | **→ ~350**(24 对分层抽样 ×3.12) | 机制忠实,默认关 | **08-11 姊妹判死史**(§2.6),必须带米制尺度/P@2cm/浮点三门上机;可只对浅对启用 |
| **R3: 预算配平 max_num_features 12288/16384** | COLMAP 参数(8192 亦是默认,但默认与 max_image_size=3200 成对;12MP 全幅喂图时 8192 违背该搭配) | 12288 → 截断点约下移一级 ≈ cut320→cut254,**+37%**;16384 ≈ 去裁剪,**+100%**(同场景实测外推) | 语义内 | GEMM ×2.25/×4;07-08 12288 回滚史(CPU 提取时代,GPU 时代需重测);热/队列风险 |
| R4: max_image_size=3200 | **COLMAP SIFT 默认预处理**(`extractor.cc:118-124`;controller 降采样+Rescale 回写 `feature_extraction.cc:395-398,:55`) | 不饱和场景实测 **−8~−12%**;饱和场景(build89 类)预计为正(检测 ×0.64→裁剪变浅),**未实测** | **唯一严格抄默认** | 提取像素 −37%(提取 ms 降);方向双刃,须真机 A/B 定生死 |
| ~~R5: max_error 4→5.23~~ | `two_view_geometry.h:119` | **无效**(扫描平坦,§2.5) | — | 弃 |

### (c) 上机成本(基于 build89 遥测,`frame_split`)

现役:m_gpu(匹配 GPU 时间)中位 282ms/帧 ÷ 12 候选 ≈ **24ms/对**,tvg_ms ≈ 1.7ms/对
(match= 墙钟口径的 44–50ms/对 含排队与重叠;overlap 默认开,`:3037-3043`)。
- R1/R1′:GPU 不变(阈值在核尾,GEMM 同);TVG 输入 ×1.5–2 → +1~2ms/对。**≈免费**,仍须按
  毫秒对照纪律实测每张。
- R2:每对 +1 次带内 GEMM(≈24ms)+1 次 TVG ⇒ ~×2;只对 verified<200 的对启用可摊薄到 +~15ms/对。
- R3\@12288:GEMM 面积 ×2.25 ⇒ ~54ms/对(帧匹配段 282→~640ms),另加提取/描述子 ×1.5。
- R4:匹配不变,提取像素 −37%。

### (d) 与「交付绝对无损」红线

- **没有一个候选是构造上纯增益**:R1 的单对匹配集是 0.8 集的超集,但 RANSAC/下游结果不保证
  逐点超集;R2 是"替换"(guided 集不必包含 raw 集)且有已记录的质量污染模式;R3 改变特征集的
  NN 竞争(新特征可当 2nd-NN 杀死旧匹配);R4 整个特征集换血。
- 按 08-11/08-08 两次判死的先例(inlier/注册数达标≠交付无损),任何一刀上机必须:单变量、
  每张毫秒对照、交付三门(米制尺度、P@2cm、孤立浮点),live 云与交付云都比。
- 相对安全序:R1(0.85)< R3 < R4 < R1′(0.9)< R2。

## 四、不确定/未验(宁空不编)

1. build89 两场的 **feat_raw 未观测**(gpu_sift_feat.log 在设备上,本任务不碰手机);1.5万/2.3万
   是用 07-23 场景尺度分布外推的,场景不同。下次采集顺手拉该日志即可闭环。
2. 场景/运动模糊项与裁剪项**未完全剥离**(无 build89 照片可做同帧重放);裁剪项的 −27%/−50%
   是别的 12MP 场景上的同截断点实测。
3. 07-19\@4K 锚点的 ratio 口径(self 路 0.7 vs official 0.8)与提取路(CPU/GPU)**未核实**
   (db 已失);故"塌陷 2.4–7×"的倍数带只当方向,不当精确账。
4. R4(3200)在**饱和场景**的净效应未实测——那正是它唯一可能赢的地方。
5. 所有 verified 预估用 plain-COLMAP TVG 代替产线 mandatory-gravity TVG(两者行数差中位 ≤2.4%,
   但未逐位);R2 的 ×3.12 里含"带内候选先天过 RANSAC"的自证成分,只能当上界。
6. 主机重放的 TVG 阳性对照 p90 相对差 ~10%(RANSAC 随机性),逐对结论只用中位。

## 五、复算索引(全部在 `~/Developer/pw_funnel_20260902/`)

- `depth_diag.py <db> <label>`:§2.1/2.2(a)/2.4 的全部数字(尺度解码、分 gap、分尺度 bin)
- `replay_match.py <db> <label> all|gap1|nN`:§0 阳性对照、§2.1 分解、§2.5 扫描
  (产物 `replay_20f_all.log`、`replay_51f_gap1.log`)
- `exact_pair_cmp.py <session_dir> N`:§2.3 三方对拍
- `xres_experiment.py <photos_dir> N fx`:§2.3 分辨率三臂
- `clamp_cost.py <session_dir> fid,fid,... fx`:§2.2(b) 裁剪代价
- `guided_replay.py <db> <label> N`:§2.6(产物 `guided_20f.log`)
- `ms_budget2.py`:§(c) 遥测口径
- 运行环境:`~/Developer/Aether3D-cross/.venv-da3/bin/python`(numpy 1.26.4 + pycolmap 4.0.4,
  后者与 vendored colmap 同源)
- 对照臂数据:`~/Developer/device-backups/PocketWorld/com.kyle.PocketWorld_20260723T2148_ratio08_preupdate/Documents/captures_official/`(三场 + photos_highres + gpu_sift_feat.log)

(本报告未 commit;未写 /tmp、未碰设备、未改产品代码;db 全部 `mode=ro` 打开。)
