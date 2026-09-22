# 自动对焦算法调研:用自己的反差式 AF 驱动四端镜头(2026-09-22)

分支 `research/adaptive-focus-vio-survey`。调研 agent 产出;**不含实测、不含生产代码、没碰 iPhone**。
所有「未核」是本次没拿到一手证据的项,不补猜。上一份 `adaptive_focus_vio_survey_20260922.md`
讲的是「镜头动了 VIO 内参怎么跟」,本份**不重做**,只在 §6.1 末一句话带过。

---

## 0. 判决(一句话)

**主线:抄 libcamera 树莓派 IPA 的 CDAF 状态机(`src/ipa/rpi/controller/rpi/af.cpp`,BSD-2-Clause)——粗扫/细扫/抛物线找峰/场景变化重触发/稳定判据整段可抄;
它唯一缺的一块「焦点度量」它自己不算(从 ISP 硬件统计拿),这一块用 Pertuz 2013 评测里的梯度能量类算子(Tenengrad / Laplacian 方差)在我们 GPU 前端已有的 Sobel dx/dy 纹理上做窗口归约;
四端只换「镜头接口」一层。** 没有任何一个可商用仓能「整段抄含焦点度量」——最接近的是 libcamera,差的就是那一个函数 `getContrast()`。
**学习型 SOTA(Herrmann CVPR 2020 / Wang TCI 2021)全线不可复刻**:要么没放代码,要么仓里没有 LICENSE,数据集也没写许可(§2.3)。

用户原则(本次拍板口径):**锁焦是因为看不清;对焦算法的目标函数是被拍的小物体(10–30 cm)在成片上的清晰度**,不是全画面平均清晰度,更不是让 VIO 舒服;VIO 要适应镜头动,而不是镜头迁就 VIO。

两条本次核出来、会直接改方案的事实:
1. 🔴 **iOS `lensPosition` 的 `0.0` 是「最近」、`1.0` 是「最远」**(Apple 文档原文,§4)⇒ 现状锁的 **0.835 偏在远端**,与「拍 20–30 cm 小物体」方向相反。本调研无实测,不下断言,但验收表 A 会直接量出来。
2. 🔴 **苹果主摄是「100% Focus Pixels」= 全画幅 PDAF**(Apple 规格页,§5.2)⇒ 它单帧到位,我们的软件 CDAF 要 16.8–20.1 步 × 4–5 帧 ≈ 2–3 s(发表基准)。**速度上我们先天赢不了**,所以主指标是「对在物体上」而不是「对得快」。

---

## 1. 问题边界

- 现状:零 ARKit 臂 `ios/Runner/PwCameraSlot.swift:237-241` 把镜头锁在 `setFocusModeLocked(lensPosition: 0.835)`(抄上游 `xrslam-ios/visualizer/src/ViewController.swift:256`);
  快门 `PwCameraSlot.swift:707 capturePhoto(requestId:)` **拍照前不动镜头**。拍 20–30 cm 小物体成片糊。
- 目标形态:**软件对焦** = 视频帧算清晰度(focus measure)+ 搜索策略驱动各端手动镜头位置接口 + 何时重对焦 + 稳定判据;四端算法一份,只有镜头接口逐端不同。
- 两个分开评估的任务(用户要求):
  1. **快门瞬间对焦到物体**(主指标:成片在物体上的锐度)——近距景深只有毫米级(§5.3),这一条最关键;
  2. **视频流持续对焦**(预览/VIO 输入清晰)——次要,且每次镜头动都换内参,由另一份调研接。

## 2. 权威论文(DOI 逐条解析确认;出版商页面对抓取一律 403,摘要改从作者自托管 PDF / arXiv / OpenAlex 取)

### 2.1 焦点度量算子:选哪个算子有发表依据

| 论文 | DOI | 一句话结论(含数字) | 代码 | 许可 |
|---|---|---|---|---|
| **Pertuz, Puig, Garcia 2013**, Pattern Recognition 46(5):1415–1432 | [10.1016/j.patcog.2012.11.011](https://doi.org/10.1016/j.patcog.2012.11.011)([全文 PDF](http://isp-utb.github.io/seminario/papers/Pattern_Recognition_Pertuz_2013.pdf)) | 评 **36 个算子**(梯度/拉普拉斯/小波/统计/DCT/杂项):**正常成像条件下拉普拉斯系整体最优**;**统计系最抗噪**(噪声 3–5 级时 STA2 最准、GRA7 次之),拉普拉斯系对噪声最敏感;**评价窗小时小波系最好**,梯度系对窗口大小最敏感 | MATLAB FileExchange #27314(28 个算子码) | **BSD-3**([view_license](https://www.mathworks.com/matlabcentral/fileexchange/view_license?file_info_id=27314)) |
| **Mir, Xu, van Beek 2014**, Proc. SPIE 9023 90230I | [10.1117/12.2042350](https://doi.org/10.1117/12.2042350)([作者 PDF](https://cs.uwaterloo.ca/~vanbeek/Publications/spie2014.pdf)) | **真实照片**上的大规模评测(25 焦点栈 / 4,303 张 Canon 550D 实拍 / >30 种度量,判据 precision-recall-MAE):**Brenner 与 squared gradient(一阶导)最优 = 100 / 99 / 0.00**;3×3 Sobel/Prewitt/Scharr 98 / 97 / 0.02;LoG 98 / 99 / 0.32;**直方图 / 方差 / Vollath / 压缩类很差**(variance 32/35/20.8,Vollath F4 62/87/24.6);一阶导方向要选全(只算竖向 Brenner 掉到 91/90/0.23) | `focus_measures.zip`([页面](https://cs.uwaterloo.ca/~vanbeek/Research/research_cp.html)) | 🔴**页面无任何许可声明**,商用前须问作者 |
| Zhang 等 2018, IEEE TCSVT | [10.1109/TCSVT.2016.2602308](https://doi.org/10.1109/TCSVT.2016.2602308) | 重组 DCT 中高频系数作度量 + MAD 噪声自适应调权,抗噪且对最佳焦位敏感 | 未找到 | — |
| Minhas, Mohammed, Wu 2012, IEEE TCSVT | [10.1109/34.709612 系列](https://doi.org/10.1109/TCSVT.2011.2133930) | 可操控滤波器度量,**计算量与邻域大小无关(常数时间)** | 未找到 | — |
| Subbarao & Tyan 1998, PAMI / Krotkov 1988, IJCV | [10.1109/34.709612](https://doi.org/10.1109/34.709612) / [10.1007/BF00127822](https://doi.org/10.1007/BF00127822) | 度量噪声敏感度理论 / Fibonacci 搜索的常被引出处(仅核 DOI,未读全文) | — | — |

⇒ **两篇系统评测在「梯度能量类」上一致**(Pertuz 说正常条件拉普拉斯系最优、小窗用小波;Mir 在真实照片上说一阶导最优、Sobel 次之)。我们要在**小 ROI**(物体框)上算 ⇒ 取**双向 Sobel 平方和(Tenengrad / squared gradient)**,与我们 GPU 前端已有的核完全重合(§6)。

### 2.2 搜索策略与规则式 AF

| 论文 | DOI | 一句话结论 | 代码 |
|---|---|---|---|
| **Kehtarnavaz & Oh 2003**, Real-Time Imaging 9(3):197–203 | [10.1016/S1077-2014(03)00037-8](https://doi.org/10.1016/S1077-2014(03)00037-8) | 平方梯度 + **规则式搜索**,TI DM310 上实时;对比全局搜索与二分搜索,迭代次数更少。据 Chen & van Beek 2015 转述:**从近焦端向远焦端整段扫**,规则定每步取粗/中/细 | 未找到 |
| **He, Zhou, Hong 2003**, IEEE TCE 49(2):257–262 | [10.1109/TCE.2003.1209511](https://doi.org/10.1109/TCE.2003.1209511) | 焦点值 + 阈值梯度 + 边缘点计数,「相对差比」驱动**自适应步长爬山**,做进 0.25 µm CMOS。第三方基准(Chen & van Beek 2015 Table 2,32 场景×165 起点):**准确率 91.5%、平均 16.8 步** | 未找到 |
| **Chen & van Beek 2015**, Pattern Recognition Letters | [10.1016/j.patrec.2015.01.010](https://doi.org/10.1016/j.patrec.2015.01.010)([作者 PDF](https://cs.uwaterloo.ca/~vanbeek/Publications/prl-2015.pdf)) | 决策树学「先往近还是往远」+「继续/回退/转细搜」:**准确率 91.5%→98.5%(常规)、70.3%→94.0%(弱光)**,代价平均步数 16.8→20.1 | `ml_autofocus.zip`,🔴无许可 |
| Chen, Hong, Chuang 2006, IEEE TCE | [10.1109/TCE.2006.273125](https://doi.org/10.1109/TCE.2006.273125) | 差分方程预测模型 + 二分粗/细,预测拐点跳过多余采样("requires few focusing iterations",无数字) | 未找到 |
| Ma 等 2025, Applied Optics | [10.1364/AO.568432](https://doi.org/10.1364/AO.568432) | 全局+爬山混合(PCHC)对比**黄金分割 / Fibonacci / 纯爬山:平均步数 −40%、总时间 −45%** | 未找到 |
| Jia 等 2022, MTAP | [10.1007/s11042-022-12191-w](https://doi.org/10.1007/s11042-022-12191-w) | 改进拉普拉斯 + 增强爬山,称**对焦时间比传统减少 76%**(全文未取到) | 未找到 |
| Xu 等 2011, Sensors | [10.3390/s110908281](https://doi.org/10.3390/s110908281) | 弱光下"scans the entire focus range in a forward direction",4 步/次,**不早停**以免把噪声假峰当真峰 | 开放获取 |

⇒ 爬山+自适应步长是 2003 年就定型的工业做法,libcamera 的粗/细两段扫 + 抛物线取峰是它的工程化版本;学习型搜索(Chen & van Beek)能把准确率推到 98.5% 但代价是**多走 3.3 步**且代码无许可。

### 2.3 学习型 AF(2020–2025)

| 论文 | DOI | 一句话结论 | 代码 | 许可 |
|---|---|---|---|---|
| **Herrmann 等 2020**, CVPR「Learning to Autofocus」 | [10.1109/CVPR42600.2020.00230](https://doi.org/10.1109/CVPR42600.2020.00230) / [arXiv 2004.12260](https://arxiv.org/abs/2004.12260) | Pixel 3 五机架:51 场景×10 栈=**510 栈、每栈 49 片**(0.102–3.91 m 逆深度均匀)、RGB+双像素+MVS 深度。**单片输入:最佳传统基线 MAE 11.3 片 vs 模型 3.1 片(3.6×)**;全栈 2.06 vs 1.60。评价按 **128×128 patch** 做,真值=该 patch 深度中值最近的焦片 | 论文称 code public,但**项目页无代码链接、`google-research` 无仓**;第三方复现 `Blaze-Leo/Learning-to-Autofocus`(MIT) | 数据集 README **无许可条款**;89 GB test + ~681 GB train |
| **Wang 等 2021**, IEEE TCI 7:258–271「Deep Learning for Camera Autofocus」 | [10.1109/TCI.2021.3059497](https://doi.org/10.1109/TCI.2021.3059497) / [arXiv 2002.12389](https://arxiv.org/abs/2002.12389) | **1–2 张采样直接回归焦位,比搜索式 CDAF 快 5–10×**,无需 PDAF 硬件 | [ChengyuWang1007/Deep-Learning-for-Camera-Autofocus](https://github.com/ChengyuWang1007/Deep-Learning-for-Camera-Autofocus) | 🔴**仓内无 LICENSE**(API `/license` 404)⇒ ⚰️ 不可商用 |
| **Lin 等 2022**, CVPR「Autofocus for Event Cameras」 | [10.1109/CVPR52688.2022.01586](https://doi.org/10.1109/CVPR52688.2022.01586) | 事件率作度量 + 事件版黄金分割搜索;焦位 MAE 56.3 / RMSE 79.7,帧法在暗+动态下 MAE 飙到 ~1,630 | [eleboss/eaf_code](https://github.com/eleboss/eaf_code) | 代码 **MIT**;数据集 CC BY-**NC** 4.0(我们无事件相机,只作旁证) |
| Wang 等 2024, Sensors 24(13):4336 | [10.3390/s24134336](https://doi.org/10.3390/s24134336) | MobileViT **动态选 ROI** + 序回归:全栈 MAE 0.094 / 27.8 ms,单帧 MAE 0.142 / 27.5 ms | 未找到 | 文章 CC BY |
| Ho, Chan, Chen 2020, IEEE TIP「AF-Net」 | [10.1109/TIP.2019.2947349](https://doi.org/10.1109/TIP.2019.2947349) | PDAF:CNN 读左右相位图回归镜头移动量,**焦位误差比统计式 PDAF 小 5×** | 未找到 | — |
| Anikina 等 2023, IEEE Access「DASHA」 | [10.1109/ACCESS.2023.3303844](https://doi.org/10.1109/ACCESS.2023.3303844) | 多智能体 RL 在潜空间上无参考自对焦 | 未找到 | 文章 CC BY-NC-ND |
| Kou 等 2025, Neural Processing Letters「FDNet」 | [10.1007/s11063-025-11788-0](https://doi.org/10.1007/s11063-025-11788-0) | 轻量「是否合焦」判别网:准确率 +4%,**0.2 GFLOPs / 0.5M 参数 / 0.06 s** | 未找到 | CC BY-NC-ND |

⇒ **学习型 AF 一条也不能复刻**:最强的 Herrmann 2020 与 Wang 2021 要么没代码、要么无许可;数据集许可也没写。**这条路今天不通**,不是我们不想用 SOTA。
(注:`AutoFocusFormer` 是分割骨干网,与相机对焦无关,已排除。)

### 2.4 ROI / 对焦窗:目标是「被拍的物体」,文献怎么做

| 论文 | DOI | 结论 |
|---|---|---|
| Lee 等 2008, IEEE TCSVT 18(9) | [10.1109/TCSVT.2008.924105](https://doi.org/10.1109/TCSVT.2008.924105) | 中频 DCT 度量**先检测画面里的多个物体**,再用三条模糊隶属函数**推理选目标物**;0.35 µm CMOS 全数字实现 |
| Rahman & Kehtarnavaz 2008, IEEE TCE 54(4) | [10.1109/TCE.2008.4711194](https://doi.org/10.1109/TCE.2008.4711194) | **以检出的人脸区作 ROI** 接进规则式 AF,真实相机平台实时 |
| Tian 等 2005, SPIE | [10.1117/12.586482](https://doi.org/10.1117/12.586482) | 薄透镜模型证明不同场景需要不同对焦窗;**注视点驱动的动态窗**,只用 <1% 像素算度量 |
| Tsai & Lin 2008 | [10.1109/ISCCSP.2008.4537305](https://doi.org/10.1109/ISCCSP.2008.4537305) | 运动检测得 ROI → 选焦点窗并**逐帧跟踪** |
| Wei & Su 2017 | [10.1109/ICIVC.2017.7984650](https://doi.org/10.1109/ICIVC.2017.7984650) | 显著性图最显著区的最小外接矩形作对焦窗 |
| **Abuolaim, Punnappurath, Brown 2018, ECCV** | [10.1007/978-3-030-01267-0_32](https://doi.org/10.1007/978-3-030-01267-0_32) | 把手机 AF 的 ROI 目标归为四种:**全局 / 9 点 / 51 点 / 人脸区**;80 人用户研究:**镜头总运动量(而不是画面里谁合焦)才是偏好主因** |
| Herrmann 2020 | 见上 | 评价**按 128×128 patch** 做、真值取 patch 深度中值 ⇒ 学界评 AF 也是按局部区域,不是全画面平均;但没有「最近主体优先」的选片规则 |

🔴 **对「10–30 cm 小物体」这一条,文献里没有一篇专门验证过**「中心加权 vs 最近主体 vs 主体检测框」的优劣。最接近的是 Lee 2008(多物体检测后模糊选目标)与 Abuolaim 2018(偏向少动镜头)。Chen & van Beek 2015 明言沿用「ROI = 整幅图」的假设 ⇒ **学界基准多数根本没做主体窗**,这正是我们要偏离基准的地方。

### 2.5 近焦优先 / 扫描方向:有先例,但「取最近峰」的明文只在专利里

- **近→远整段扫有先例**:Chen & van Beek 2015 §3 转述 Kehtarnavaz & Oh 2003 原话 "as it sweeps the lens from near focus to far focus";并称 Gamadia & Kehtarnavaz 2009([10.1109/ICIP.2009.5414125](https://doi.org/10.1109/ICIP.2009.5414125))**在第一个峰就终止** —— 在近→远扫描里这等价于「最近峰优先」(该判断来自 PRL 的转述,ICIP 摘要本身未提方向)。
- He 2003 与 Chen & van Beek 2015 都是**先预测方向**再粗步到首峰,不固定从近端起。
- 🔴 **「多峰取最近者」的明文依据只在专利里找到**:Samsung **US 8,447,179 B2**([Google Patents](https://patents.google.com/patent/US8447179B2/en)):多点对比度扫描,"the main subject determination unit may determine a subject corresponding to the peak of the nearest multi-point as the main subject"。**未找到同等内容的期刊/会议论文** ⇒ 见 §8 风险。


## 3. 可商用开源实现(逐仓核 LICENSE 原文 / 文件头 SPDX;⚰️ = 不可抄)

行号取自 2026-09-22 拉的 raw 源码。GitHub 侧栏许可徽章不作证据。

| 仓 | 许可(原文出处) | 算法在哪(文件:行) | 最近提交 | 焦点度量 / 搜索 / 重对焦 / 稳定判据 | 判 |
|---|---|---|---|---|---|
| **libcamera RPi IPA** [链接](https://github.com/raspberrypi/libcamera) | `src/ipa/rpi/controller/rpi/af.cpp:1` `/* SPDX-License-Identifier: BSD-2-Clause */`(af.h / af_algorithm.h / af_status.h 同);`COPYING.rst`:"The IPA modules, located in src/ipa/, are covered by free software licenses chosen by the module authors" | `getContrast` 368–390、`computeWeights` 267–322、`findPeak` 502–533、`doScan` 535–586、`doAF` 588–690、`startProgrammedScan` 736–757、`triggerScan` 922–927、`pause` 947–964;参数 38–69;枚举 `af_algorithm.h:42-57` | 2026-04-24 `554c5c7fa1`(维护中) | 度量=**ISP 硬件 FoM**,软件只加权求和(这就是缺口);粗扫 1.0 屈光度 → 反向细扫 0.25 → 三点抛物线取峰 → Settle;稳定 `prevContrast_ ≥ 0.75×max && min ≤ 0.75×max` 否则 Failed;重对焦=对比度或 AWB R/G/B 任一变化超 `retrigger_ratio` 0.8 后再稳 `retrigger_delay` 10 帧 | ✅ **主线** |
| libcamera IPU3 IPA | `src/ipa/ipu3/algorithms/af.cpp:1` `LGPL-2.1-or-later`(Red Hat 2021) | `afScan` 277–323、`afEstimateVariance` 357–374、`afIsOutOfFocus` 386–400 | 2026-03-23 | 度量=ISP AF 滤波 y1/y2 的**方差**;爬山(粗步 30 / 细步 1,±5%),方差跌 10% 判过峰;重对焦=变化率 > 0.5 | ⚰️ LGPL |
| libcamera rkisp1 / libipa / mali-c55 | — | 目录列表**无 af.\*** | — | 无 AF(阴性结果,非未核) | — |
| **OpenCV** [示例](https://github.com/opencv/opencv/blob/4.x/samples/cpp/videocapture_gphoto2_autofocus.cpp) | 文件头 1–25 是 **BSD-2 原文**(Copyright (c) 2015, Piotr Dobrowolski);仓 `LICENSE` = Apache-2.0。**注意**:旧路径 `samples/cpp/autofocus.cpp` 已于 2018-11-16 `43002c0c` 改名 | `rateFrame` 131–147、`correctFocus` 149–204、`FocusState` 58–67 | 2019-08-14 | 度量=灰度→高斯 7×7 σ1.5→**Canny(0,30) 边缘像素占比**;搜索=变步长爬山(方向错就反向且步长 ×0.75,3 步无提升退回峰);**无重对焦、无稳定判据、无 ROI**;驱动的是 gPhoto2 单反 | 可商用但太薄 |
| **Micro-Manager OughtaFocus** [链接](https://github.com/micro-manager/micro-manager) | `OughtaFocus.java:19` "LICENSE: This file is distributed under the BSD license.";`autofocus/license.txt` BSD-3(Caltech 2007);🔴 `mmCoreAndDevices/MMCore/license.txt` = **LGPL**(别碰核心) | 搜索 `optimizers/BrentFocusOptimizer.java:146-181`;度量 `ImgSharpnessAnalysis.java`:`computeTenengrad` 261–281、`computeEdges` 145–157、`computeVolath` 287、`computeRedondo` 232、`computeFFTBandpass` 370;**ROI:`CropFactor`** `OughtaFocus.java:71/91/149-150`,应用在 `fullFocus:187-194`(居中裁 w×cf、h×cf) | 2026-06-24(维护中) | 11 种度量(Tenengrad / NormalizedVariance / Volath / Edges…);搜索=**commons-math3 Brent 一维优化**,`MAXIMIZE`,`MaxEval(100)`;**无重对焦、无稳定判据**(按需一次 `fullFocus`) | ✅ 次选 |
| **Pertuz `fmeasure`**(MATLAB) [FileExchange](https://www.mathworks.com/matlabcentral/fileexchange/27314-focus-measure) | zip 内 `license.txt`:"Copyright (c) 2017, Said Pertuz … Neither the name of the Universidad Industrial de Santander"(**BSD-3**) | `fmeasure.m`:签名 `fmeasure(Image, Measure, ROI)`,**ROI 裁剪 20–22**;算子 case 行:LAPV 146、LAPM 139、LAPE 134、TENG 188、TENV 195、GLVN 91、GRAE 94、DCTE 62、VOLA 202、WAVS 209…(`operators.txt` 列 28 种) | v2.2.0.0 2017-08-31 | **纯度量库,无搜索**;论文 §1 的算子实现出处 | ✅ 度量抄这里 |
| PetteriAimonen/focus-stack | `LICENSE.md` MIT | `src/task_focusmeasure.cc:18-45` | 2026-01-11(665★) | **Tenengrad**(Sobel 平方和→阈值→高斯);只度量 | 可商用 |
| cmcguinness/focusstack | `LICENSE` Apache-2.0 | `FocusStack.py doLap:112-121` | 2024-04-26(185★) | 高斯+Laplacian(ksize 5);只度量 | 可商用 |
| raspberrypi/picamera2 | `LICENSE` BSD-2 (c) 2021 Raspberry Pi | `picamera2.py autofocus_cycle:2771-2790` | 2026-09-21(1243★) | 只设 `AfMode=Auto, AfTrigger=Start` 等 `AfState∈{Focused,Failed}`,**算法全在 libcamera** | 可商用但无算法 |
| Teddy939/mycamera | `LICENSE` MIT (c) 2023 | `src/focuser.cpp`:`contrast_` 150–162、`setRoi` 30、`scanCoarse_` 250–275、`scanFine_` 287–313、`goBackToPeak_` 315 | 2023-07-31(1★) | 度量=**ROI 灰度标准差**;粗全扫→峰附近细扫→回峰;有 ROI,无重对焦 | 可商用(太小众) |
| lozuwa/autofocus_…_microscopes | `LICENSE.md` Apache-2.0 | `AutofocusActivity.java:370-420` | 2018-06-03(7★) | Laplacian 方差,**四象限 ROI 各算一份**+全图,3 帧平均;Android | 可商用(参考 ROI 做法) |
| pylablib | `LICENSE`:"GNU GENERAL PUBLIC LICENSE Version 3" | 无 AF 例程 | 2026-05-02 | 无算法 | ⚰️ GPL-3 |
| libgphoto2 | `COPYING`:"GNU LESSER GENERAL PUBLIC LICENSE Version 2.1" | `examples/focus.c:23,89` | 2026-09-20 | **只驱动机身自带 AF,无软件 AF** | 无可抄 |
| AOSP EmulatedCamera | 文件头 Apache-2.0 | `EmulatedRequestState.cpp ProcessAF:277-455`(注释 315–318 "Focusing always succeeds");老 `EmulatedFakeCamera3.cpp doFakeAF:2097+` 用 `rand()%3` 跳态 | 维护中 | **纯假状态机**,无度量无搜索 | 可商用但没东西可抄 |
| Google「Learning to Autofocus」 | 站点**无许可文本**;只有 arXiv/CVF + GCS 数据集 tar | **无代码**(页面只留邮箱答疑);`google-research` 仓 0 命中 | — | 论文法,无复刻源 | ⚰️ 无代码 |
| Windaway/Autofocus(51★)、russwong89/sharpness_detection_autofocus(35★)、antonio490/Autofocus(22★) | **根目录无 LICENSE 文件** | Windaway `autofocus.cpp`:`get_region_contrast:93`(8×4 块均值差取最大)、`get_roi_region:157`(**多区域选 ROI**)、`focusstrategy:236-289`;russwong89 `sharpness_calc.py:47` Sobel + `golden_section.py:89` 黄金分割 | 2019 / 2017 / 2020 | 思路可参考(块反差 + 自适应步长;黄金分割搜索) | ⚰️ 无许可 = 保留所有权利 |

**结论:没有一个可商用仓能整段抄**。最接近的是 libcamera RPi(BSD-2,状态机/重对焦/稳定判据/窗口加权全有),**差的正好是一个函数** `getContrast()` —— 它的 FoM 来自树莓派 ISP 硬件统计,手机上没有这条硬件通路,要用 Pertuz(BSD-3)的算子自己在 GPU/CPU 上算。次选 OughtaFocus(BSD-3)反过来:度量齐全(11 种,含 Tenengrad)、ROI 有 `CropFactor`,但**只有 Brent 单次优化,没有重对焦与稳定判据**。


### 3.1 libcamera 树莓派 CDAF:逐行核(本 agent 自核,文件下载于 2026-09-22,`raspberrypi/libcamera` main)

许可:`src/ipa/rpi/controller/rpi/af.cpp`、`af.h`、`../af_algorithm.h`、`../af_status.h` 文件头均为 `/* SPDX-License-Identifier: BSD-2-Clause */`,版权 `Raspberry Pi Ltd 2022-2023`。
仓根 `COPYING.rst`:"The IPA modules, located in src/ipa/, are covered by free software licenses chosen by the module authors. ... Those modules are compiled as separate binaries and dynamically loaded by the libcamera core at runtime." ⇒ 抄这四个文件不沾 LGPL(核心 `src/libcamera/` 才是 LGPL-2.1+)。
对照:IPU3 的 `src/ipa/ipu3/algorithms/af.cpp` 头是 `LGPL-2.1-or-later`(Red Hat 2021)⇒ ⚰️不抄;rkisp1 / libipa / mali-c55 的 algorithms 目录**没有 af 文件**(GitHub API 目录列表核过)。
`af.cpp` 最近提交 2026-04-24 `554c5c7fa1`(仍维护)。

`af.h:15-38` 头注自述:"hybrid of CDAF and PDAF, favouring PDAF ... When PDAF confidence is low ... fall back to CDAF with a programmed scan pattern. A coarse and fine scan are performed, using the ISP's CDAF contrast FoM ... Image changes are detected using both contrast and AWB statistics (within the AF window[s])." 手机上没有它的 PDAF 通道,**只抄 CDAF 分支**。

| 模块 | 位置 | 要点(源码事实) |
|---|---|---|
| 单位 | `af.h` `RangeDependentParams`:`focusMin /* lower (far) limit in dioptres */`、`focusMax /* upper (near) limit */`;`control_ids_core.yaml` `LensPosition`:"reciprocal of the focal distance in metres, also known as dioptres ... 0 moves the lens to infinity ... 2 moves the lens to focus on objects 50cm away" | 内部全用**屈光度**;到硬件 DAC 靠 `cfg_.map`(分段线性,`imx708.json` `"map": [0.0, 445, 15.0, 925]`),`setLensPosition():889-904` `*hwpos = cfg_.map.eval(fsmooth_)` |
| 焦点度量 | `getContrast():368-390` = `Σ w[i]·focusStats.get(i).val / Σw`;`process():824-829` `prevContrast_ = getContrast(stats->focusRegions)` | **FoM 来自 ISP 硬件 `focusRegions` 统计**,软件只做加权求和 ⇒ 这就是我们要自己补的那一块 |
| 窗口/ROI | `computeWeights():267-322`:把所有 `AfWindows` 按面积合并成一张权重图(最多 `MaxWindows = 10`,`:171`);**无窗口时默认「中 1/2 宽 × 中 1/3 高」**(`:311-318` "Default AF window is the middle 1/2 width of the middle 1/3 height");`:279-281` 作者 `\todo`:"find the phase in each window and choose either the closest or the highest-confidence one?" | 多窗口「取最近者」**未实现**,只是 todo;libcamera 公共文档 `AfWindows` 说"a typical implementation might find the optimal focus position for each one and finally select the window where ... objects ... are closest to the camera" |
| 扫描起点/方向 | `startProgrammedScan():736-757`:非 CAF 或当前位置靠近远端 ⇒ `ftarget_ = focusMin`(无穷远)、步长 `+stepCoarse`(向近);靠近近端 ⇒ 从 `focusMax`(最近)向远;否则 `Coarse1` 从当前位置**先向远**扫,峰没被夹住再反向(`doScan():559-562`) | **没有「近焦优先」**;要 macro-first 只需把起点改成 `focusMax`、步长取负——这是配置级改动,不是算法改动。`AfRangeMacro` 在 `imx708.json` 为 3–15 屈光度(33 cm–6.7 cm),`default 4.0`(25 cm) |
| 粗/细扫 | `doScan():535-586`:每步记录 `{focus, contrast}`,终止条件 `:548-551`:撞界 / 细扫已 3 点 / **对比度跌到 `contrastRatio(0.75)×max` 以下**;细扫从峰 ±`stepFine` 反向走 3 点 | `imx708.json` normal:`step_coarse 1.0`、`step_fine 0.25`(屈光度)、`step_frames 5`(每步等 5 帧再读统计)、fast:`1.25 / 0.0 / 4` |
| 找峰 | `findPeak():502-533`:最高点与两邻点**抛物线拟合**(`denom ≥ 1/64` 且同号才用,否则取样本点),夹在邻点区间内 | 亚步精度来自拟合,不靠加密扫描 |
| 每步等待 | `doScan():585` `stepCount_ = (ftarget_ == fsmooth_) ? 0 : stepFrames`;`doAF():650-658` 计数到 0 才读下一次统计 | 这就是「镜头整定 + ISP 统计延迟」的经验帧数(5 帧@30 fps ≈ 167 ms/步) |
| 稳定/完成 | `doAF():661-667`(`Settle` 态):`prevContrast_ ≥ contrastRatio×scanMax && scanMin ≤ contrastRatio×scanMax` ⇒ `AfState::Focused`,否则 `Failed`(峰不够尖=失败,不硬报成功) | |
| 场景变化重触发 | `doAF():629-647`(仅 `AfModeContinuous` 且不在扫描):对比度或 AWB 的 R/G/B 均值任一项相对上次定焦时变化超过 `retriggerRatio`(json `0.8`,即 ±20%)⇒ 开始计数;连续 `retriggerDelay`(json 10 帧)稳定后 `startProgrammedScan()` | 「变了、又停下来了」才重扫——正是防振荡的关键;VIO 场景里可以把「镜头位姿速度」也并进这个判据(但那是自研,先不做) |
| 模式/暂停 | `af_algorithm.h:41-52` `AfModeManual/Auto/Continuous`、`AfPauseImmediate/Deferred/Resume`;`triggerScan():922-927`、`cancelScan():915-920`、`pause():947-964` | 「快门瞬间对焦」= `AfModeAuto + triggerScan()`;「拍照时冻结镜头」= `AfPauseDeferred`(扫完再停) |

估算(**由参数推导,非发表值**):normal 档粗扫从当前位置到峰再反向最坏 ≈ 12 屈光度 / 1.0 × 5 帧 ≈ 60 帧,细扫 3 × 5 = 15 帧,再加 Settle 5 帧 ⇒ **最坏 ≈ 80 帧(2.7 s @30 fps),典型(峰在 3–4 步内被夹住)≈ 30–40 帧(1–1.3 s)**;macro 档只有 12 屈光度的范围减半。

## 4. 四端手动镜头接口矩阵(全部经官方文档原文核过)

| | **iOS** AVFoundation | **Android** camera2 | **HarmonyOS** `@ohos.multimedia.camera` | **Web** W3C Image Capture |
|---|---|---|---|---|
| **A. 能否定位** | ✅ `setFocusModeLocked(lensPosition:completionHandler:)`(iOS 8+),前提 `isLockingFocusWithCustomLensPositionSupported`(iOS 10+)+ `lockForConfiguration()` | ✅ `CONTROL_AF_MODE = OFF` + `LENS_FOCUS_DISTANCE`(API 21);需 `MANUAL_SENSOR` 能力(FULL 必含,LIMITED 需查)且 `LENS_INFO_MINIMUM_FOCUS_DISTANCE > 0`;LEGACY 只能设 0(无穷远) | ✅ `ManualFocus.setFocusDistance(distance)`,门槛 `isFocusDistanceSupported()` + `FocusMode.FOCUS_MODE_MANUAL` | ⚠️ 规范有:`applyConstraints({focusMode:'manual', focusDistance:x})` |
| **B. 单位/语义** | **0…1 归一化**,`0.0` = 能对焦的**最近**,`1.0` = **最远**(且「1.0 不代表无穷远」),默认 1.0 | **屈光度 1/m**,`0.0f` = **无穷远**,越大越近;钳到 `[0, minimumFocusDistance]`。**方向与 iOS 相反** | **0…1 归一化**,`0.0` = 最近、`1.0` = 最远,默认 1.0。**与 iOS 同向** | `double`,规范说「**usually** represents distance in **meters**」;能力表 `{min,max,step}` |
| **C. 到位回调** | ✅ **`completionHandler(CMTime)`** —— 时间戳 = 第一帧已应用全部设置的 buffer;多次调用 FIFO。**四端里唯一的「镜头已到位」硬信号** | ❌ 无 completion;逐帧看 `LENS_STATE` MOVING→STATIONARY;文档明说「may take several frames」 | ❌ 同步 `void`,**无回调**;`focusStateChange` **仅自动对焦模式触发**,手动模式拿不到 | ⚠️ `applyConstraints()` 的 Promise 只表示约束被接受,**不承诺镜头已到位** |
| **D. 读当前位置** | `lensPosition`(只读,**KVO**)、`isAdjustingFocus`(KVO);非逐帧 | ✅ **逐帧在 CaptureResult**:`LENS_FOCUS_DISTANCE`、`LENS_FOCUS_RANGE`(near/far 屈光度对)、`LENS_STATE` | `getFocusDistance()` 同步轮询,非逐帧 | `getSettings().focusDistance`,轮询 |
| **E. 步进/延迟** | ❌ 全未文档化;不支持的值抛异常 | 无最小步进;`LENS_STATE` 有定义;无到达时间上限 | ❌ 全未文档化 | `MediaSettingsRange.step` 有定义;延迟无规范文字 |
| **F. 模式组合** | `setFocusModeLocked` 会把 `focusMode` 置 `.locked`,锁后仍可 KVO 读值;无闪帧说明 | `AF_MODE_OFF`:"The auto-focus routine does not control the lens; android.lens.focusDistance is controlled by the application";OFF 下 `CONTROL_AF_STATE` 恒 INACTIVE | `FOCUS_MODE_MANUAL`「不支持对焦点设置」;`getFocusDistance()` 与模式无关 | 规范只在示例里把 manual 与 focusDistance 一起下发;非 manual 下行为未规定 |
| **G. 标定等级** | ❌ **无标定**:"doesn't correspond to an exact physical distance, nor does it represent a consistent focus distance from device to device" | ✅ **三档** `LENS_INFO_FOCUS_DISTANCE_CALIBRATION`:UNCALIBRATED / APPROXIMATE(屈光度但不可重复)/ CALIBRATED(屈光度且对应真实物理距离) | ❌ 无标定说明,纯归一化 | ❌ 无保证 |
| **可用性红线** | 稳:iOS 8+ | 稳:API 21+,但要查能力 | 🔴 **`ManualFocus` 在 API 12–20 是系统接口(仅系统应用,错误码 202 Not System Application),API 24 / HarmonyOS 6.1.1(2026-05-26)起才开放**;且**只混入 `PhotoSession`,`VideoSession` 不含 ManualFocus** | 🔴 **只有 Chromium 实现**(Chrome/Chrome Android **76+**);**WebKit 的 IDL 里 focusMode/focusDistance 只存在于 FIXME 注释 ⇒ Safari(含 iOS)不支持**;Firefox 的 webidl 里没有这两个成员 |

**关键原文**(链接见 §8):
- iOS `lensPosition`:"The range of possible positions is 0.0 to 1.0, with **0.0 being the shortest distance at which the lens can focus and 1.0 the furthest**. Note that 1.0 doesn't represent focus at infinity. The default value is 1.0."
- iOS `setFocusModeLocked` 的 handler:"The system passes a time value that matches that of **the first buffer to which its applied all settings**. It synchronizes the timestamp to the device clock…"
- Android 标定:"APPROXIMATE and CALIBRATED devices report the focus metadata in units of diopters (1/meter), so **0.0f represents focusing at infinity**…";UNCALIBRATED:"…do not correspond to any physical units… **0.0f still represents farthest focus**"
- Android `LENS_FOCUS_DISTANCE`:"…it may take **several frames** before the lens can move to the requested focus distance. While the lens is still moving, android.lens.state will be set to MOVING."
- HarmonyOS `setFocusDistance`:"…in the range [0.0, 1.0], where **0.0 indicates the shortest achievable focus distance and 1.0 indicates the longest focus distance**. The default value is 1.0."(`arkts-apis-camera-ManualFocus.md`,API 24+)
- Web:"Focus distance is a numeric camera setting that controls the focus distance of the lens. The setting **usually represents distance in meters** to the optimal focus distance."

**对我们的三条后果**
1. **单位三套、方向两套**(iOS/HarmonyOS 归一化近→远 = 0→1;Android 屈光度远→近 = 0→大;Web 米)⇒ 算法内部必须用**一个统一的内部标度**,四端各写一个薄薄的换算 + 标度校准(libcamera 的 `cfg_.map` 分段线性就是干这个的,可直接沿用它的结构)。
2. **只有 iOS 有「到位回调」**;Android 靠 `LENS_STATE`,HarmonyOS 和 Web **什么都没有** ⇒ 跨端统一的等待策略只能是 libcamera 那套「**等 N 帧**」(`step_frames`),iOS/Android 上再用回调/状态提前结束。
3. 🔴 **现状锁的 `lensPosition = 0.835` 偏在远端**(0=最近,1=最远)。拍 20–30 cm 小物体本该往 0 那一侧走。这是「一直无法对焦」最直接的一条解释 —— 但**本调研没做实测,不下断言**,仅指出文档语义与当前取值的方向矛盾(验收表 A 会直接量出来)。

**Flutter `camera` 插件(0.12.1)**:只有 `setFocusMode(FocusMode.auto/locked)` 与 `setFocusPoint`,**没有任何 lensPosition / focusDistance 接口** ⇒ 四端都得走我们自己的平台通道(iOS 已有 `PwCameraSlot`)。CameraX `CameraControl` 同样没有手动焦距,只能经 `@ExperimentalCamera2Interop` 下发 `CaptureRequest.Key`。


## 5. 发表数据(用户铁律:提议测量前先查有没有人发表过)

### 5.1 镜头执行器与每步等待

| 量 | 值 | 来源 | 原文 |
|---|---|---|---|
| 每步「等统计稳定」的帧预算 | **normal 5 帧 / fast 4 帧**(@30 fps ≈ 167 / 133 ms) | libcamera `imx708.json` 的 `rpi.af.speeds.*.step_frames`;用法见 `af.cpp:585` | `"step_frames": 5` / `"step_frames": 4` |
| 每帧最大移动量(防跳) | normal **1.5** / fast **2.0** 屈光度 | 同上 `max_slew` | `"max_slew": 1.5` |
| 镜头到位的时间语义 | 「可能要好几帧」,移动中 `LENS_STATE = MOVING`,**无时间上限** | Android `LENS_FOCUS_DISTANCE` 文档 | "it may take **several frames** before the lens can move to the requested focus distance. While the lens is still moving, android.lens.state will be set to MOVING." |
| 屈光度 ↔ 驱动 DAC 的映射 | imx708:`map = [0.0 → 445, 15.0 → 925]`(即 0–15 屈光度对应 DAC 445–925,**480 级**) | `imx708.json` `rpi.af.map`;`af.cpp:889-904 cfg_.map.eval` | — |
| 🔴 VCM 行程 / DAC 位数 / 整定时间 / 迟滞 | **未核** | — | 本轮负责这块的调研 agent 仍在运行未返回;VCM 驱动芯片(DW9714/AK7371/LC898 系)datasheet 未打开 |

⇒ 目前能引用的「每步要等多久」,唯一的**发表实现级数字**是 libcamera 的 4–5 帧。这既含镜头整定也含 ISP 统计延迟;我们自己算 FoM 没有 ISP 延迟,但有 GPU 归约+读回延迟,**必须在台架重标**(§7)。

### 5.2 收敛所需步数(发表的第三方基准)

| 算法 | 准确率 | 平均步数 | 来源 |
|---|---|---|---|
| He 等 2003 自适应步长爬山 | 91.5% | **16.8 步** | Chen & van Beek 2015 PRL Table 2(32 场景 × 165 起点),[10.1016/j.patrec.2015.01.010](https://doi.org/10.1016/j.patrec.2015.01.010) |
| Chen & van Beek 2015 决策树 | 98.5%(常规)/ 94.0%(弱光) | **20.1 步** | 同上 |
| 学习型(Herrmann 2020,单帧输入) | 焦片 MAE **3.1 片** vs 最佳传统基线 **11.3 片** | 1 帧 | [10.1109/CVPR42600.2020.00230](https://doi.org/10.1109/CVPR42600.2020.00230) |
| Ma 等 2025 PCHC(多光谱) | — | 比黄金分割/Fibonacci/纯爬山 **少 40% 步、少 45% 时间** | [10.1364/AO.568432](https://doi.org/10.1364/AO.568432) |

**换算**:16.8–20.1 步 × 4–5 帧/步 ≈ **67–100 帧 ≈ 2.2–3.4 s @30 fps**。这是纯 CDAF 的量级。
🔴 **苹果主摄是「100% Focus Pixels」= 全画幅 PDAF**(Apple 技术规格页原文:"48MP Fusion: 24 mm, ƒ/1.78 aperture … **100% Focus Pixels**",[support.apple.com/en-us/121031](https://support.apple.com/en-us/121031))⇒ **它单帧就能定到位,我们的软件 CDAF 在速度上先天落后一个量级**。这正是把**「成片锐度」定为主指标、对焦时间定为次指标**的现实依据 —— 我们赢不了速度,要赢的是「对在被拍的那个小物体上」。

### 5.3 近距离景深(用发表参数计算,**不是实测**)

参数:`f = 6.86 mm`(🔴 iPhone 主摄真实焦距的 EXIF 惯例值,**Apple 规格页只发布 35 mm 等效 24 mm,不发布真实焦距** —— 这是本节最弱的一环)、`N = 1.78`(Apple 规格页)。薄透镜公式 `near/far = s·f² / (f² ± N·c·(s−f))`。

| 物距 | 弥散圆 c=2.44 µm(2 像元 @48MP) | c=4.88 µm(2 像元 @12MP 合并) | c=8.24 µm(对角线/1500) |
|---|---|---|---|
| 100 mm | **1.7 mm** | 3.4 mm | 5.8 mm |
| 150 mm | 4.0 mm | 7.9 mm | 13.4 mm |
| 200 mm | **7.1 mm** | 14.3 mm | 24.2 mm |
| 250 mm | 11.2 mm | 22.5 mm | 38.1 mm |
| 300 mm | **16.2 mm** | 32.6 mm | 55.3 mm |
| 超焦距 | 10.8 m | 5.4 m | 3.2 m |

⇒ **10–30 cm 上景深只有几毫米到几厘米**。两条直接后果:
1. **「按快门瞬间对到物体」比「视频流一直对焦」重要得多** —— 视频流糊一点只影响预览与 VIO 特征,成片糊了这张就废了,而景深这么浅意味着「差一档镜位」就是废片。两者必须分开评估(§6.3)。
2. 一次扫描内**镜头步长必须细到景深量级**:libcamera 的 `step_fine = 0.25` 屈光度在 20 cm(5 屈光度)处对应 ±1 cm 的物距变化,**比 7 mm 的景深还粗** ⇒ macro 档的 `step_fine` 要按近距重标,不能照抄树莓派。

🔴 **iPhone 主摄的最近对焦距离决定 10 cm 这一档能不能成立**:Apple 不发布该值,只能在机上读 `minimumFocusDistance`(iOS 15+,毫米,未知为 −1);若主摄最近对焦距离 > 10 cm,10 cm 档必须切超广角(原生「微距」就是这么切的)—— **那是换一颗镜头、换一套内参,影响远超对焦本身**。本调研不碰 iPhone,此项留给台架。

🔴 **`lensPosition` ↔ 物理距离的标定曲线:未找到任何发表数据**。Apple 明文说它「不对应确切物理距离,机型间也不一致」(§4),因此这条曲线只能逐机型自测,而那违反「不自研」的口径 ⇒ 主线方案**不依赖**这条映射(状态机在归一化标度上爬山,不需要知道物理距离)。

---

## 6. 复刻判决

### 6.1 主线:抄 libcamera RPi 的 CDAF 状态机 + 自己算焦点度量 + 四端镜头适配

**抄哪几个文件(全部 BSD-2-Clause,保留版权头与许可文本)**

| 要抄的件 | 来源(文件:行) | 落到我们哪 |
|---|---|---|
| 搜索状态机(Idle/Trigger/Coarse1/Coarse2/Fine/Settle)、`doScan`、`findPeak`(三点抛物线)、`startProgrammedScan`、`doAF` 的 CDAF 分支、`triggerScan/cancelScan/pause/setMode` | `src/ipa/rpi/controller/rpi/af.cpp:502-767, 915-964`、`af.h` | 一份 C++(与 XRSLAM 同语言,四端共用)`pw_af/af_scan.{h,cpp}`;**删掉** `getPhase/doPDAF/earlyTerminationByPhase/getAverageAndTestIr`(PDAF 与 IR 检测手机上没有这条输入) |
| 参数结构与 json 键(`ranges.normal/macro`、`speeds.normal/fast`) | `af.cpp:38-169` + `imx708.json` 的 `rpi.af` 段 | 同名保留,便于与上游对照;数值必须按手机重标(见 §8) |
| 接口 | `af_algorithm.h:42-57`(`AfRange/AfSpeed/AfMode/AfPause` 四个枚举)、`af_status.h` | 原样保留 |
| 窗口加权 | `computeWeights:267-322`(多窗口按面积合并;无窗口时默认「中 1/2 宽 × 中 1/3 高」) | **默认窗口换成被扫描物体的框**(自动拍摄链已有主体框 / `subjectFootprintRatio`);拿不到主体框时退回 libcamera 的中央窗 |
| **焦点度量(libcamera 没有,这是唯一的缺口)** | Pertuz `fmeasure.m` 的 `TENG`(:188)/`GRAT`(:102),BSD-3;结论依据 Mir 2014 的「一阶导最优 100/99/0.00」 | `getContrast()` 换成「ROI 内 Σ(dx²+dy²)」(Tenengrad),见下 |
| 重对焦与稳定判据 | `doAF:629-667`(`retrigger_ratio` + `retrigger_delay` 双门;Settle 判 Focused/Failed) | 原样抄,只把 AWB R/G/B 那三项换成我们能拿到的亮度统计 |

**焦点度量算在 GPU:是现有管线的副产品,不是新算子**
- `pw_gpu_frontend.cpp:58` 已装载 `sobel_dxdy` 核,`:120` 每帧在 GFTT 前把整幅 CLAHE 图的 Sobel dx/dy 写进 `b_dx_/b_dy_`(`pw_gpufe_wgsl.h:13 k_sobel_dxdy`,OpenCV 4.0.1 `corner.cl` 语义,逐位对过);`:380 k_gftt_max` 已是一支归约核。
- 只需补一支「**ROI 内 Σ(dx²+dy²) 归约**」,读回 1 个 float。纯拍照(VIO 停、GFTT 关)时单独跑 sobel + 归约。
- **不用**现有 `lib/quality/quality_compute.dart` 的 Laplacian 方差驱动镜头:它算在 128×128 缩略图、6 Hz(`:4-21`),分辨率与节奏都不够(AF 每步要 30 Hz 级读数、且要在 ROI 内按全分辨率算)。但它**原样留作验收尺子**(§6.3),因为它跨四端已经一致。
- CPU 退路(Android/Web 无 GPU 前端时):同一算子在 ROI 内用 NEON/WASM 算,ROI 压到 512² 以内即可,3×3 算子成本与像素数线性。

**接在 iOS 相机槽哪一层**
- 读数:`PwCameraSlot.swift:323-395 captureOutput(_:didOutput:)` 已逐帧拿到 `CVPixelBuffer` + PTS + 曝光 + 内参 —— 在这里把 Y 平面交给 `pw_af`;
- 驱动:`:237-241` 的 `setFocusModeLocked(lensPosition:completionHandler:)` 从「启动锁一次」改成「状态机每步调一次」,**`completionHandler` 的 `CMTime` 就是「镜头已到位」的硬信号**(四端里只有 iOS 有),到达后再等 ISP/统计延迟即可读 FoM,不必死等 `step_frames` 帧;
- 快门:`:707 capturePhoto(requestId:)` 之前插一次 `triggerScan()`,等 `Focused`(或 `Failed`/超时)再拍,拍完 `AfPauseDeferred`;
- **标度与方向**:libcamera 内部是屈光度、`focusMin`=远、`focusMax`=近;**iOS/HarmonyOS 的归一化值方向相反(0=最近、1=最远)**,Android 屈光度同向,Web 是米 ⇒ 内部统一用「屈光度式标度(大=近)」,四端各写一个换算,**沿用 libcamera 已有的 `cfg_.map` 分段线性结构**(`setLensPosition:889-904` 的 `cfg_.map.eval`)。iOS 上 `lensPosition = 1 − 归一化近度`。
- **近焦优先**:`startProgrammedScan:736-757` 的起点改成近端 + 步长取负,范围用 `AfRangeMacro` 语义(libcamera `imx708.json` 的 macro = 3–15 屈光度 ≈ 33–6.7 cm,正好覆盖 10–30 cm)。这是**参数与起点的选择**,不是自研算法;首峰即停 ⇒ 多峰时天然取最近者。

**对 VIO 的影响(一句话)**:镜头每动一步 fx 就变,iOS 走「逐帧 `CameraIntrinsicMatrix` 喂引擎」、扫描期间的帧不进滑窗只做 IMU 传播 —— 这是另一份调研(`adaptive_focus_vio_survey_20260922.md`)的题,本份不展开。**口径是:VIO 适应镜头动,不是镜头迁就 VIO。**

### 6.2 次选:Micro-Manager `OughtaFocus`(BSD-3)——为什么不选

`OughtaFocus` 的度量比 libcamera 全(11 种,含 Tenengrad/NormalizedVariance/Volath,`ImgSharpnessAnalysis.java`),而且**自带 ROI**(`CropFactor`,`OughtaFocus.java:71/91/149-150`,居中裁 w×cf、h×cf)。但:
1. 搜索是 **commons-math3 的 Brent 一维优化**(`BrentFocusOptimizer.java:146-181`),假设焦点曲线在搜索区间内单峰 —— 显微镜上成立(样品在载物台,范围窄),手机上对着桌面小物体**多半多峰**(物体 + 背景),Brent 会收到哪个峰不可控,且**没有「取最近峰」的位置**;
2. **没有重对焦触发,也没有稳定判据** —— 用户要的「反复对焦不振荡」「场景变了要重对」这两件事它一件都没有,等于要我们自研这两块(违反「禁止自研」);
3. Java + `MaxEval(100)` 的预算模型不适合逐帧实时;移植到 C++ 等于重写。

⇒ **只从它借两样**:`CropFactor` 的 ROI 做法,和 `computeTenengrad:261-281` 的算子实现参照(与 Pertuz 的 TENG 同式)。

### 6.3 验收判据(台架,不碰 iPhone;两条任务分开评)

用户口径:**主指标是成片在物体上的锐度,对焦时间是次指标**。

| 任务 | 主指标 | 次指标 | 阴性对照 |
|---|---|---|---|
| **A. 按快门瞬间对到物体**(最关键,因为 §5 的景深只有毫米级) | **成片在物体 ROI 上的锐度**:`quality_compute.dart` 同一 Laplacian 方差算子(ROI=主体框),或台架有 ISO 12233 靶时用 MTF50;**与苹果 AF 同场同物成片对照**(`focusMode = .autoFocus` + 同一快门路径);10 / 20 / 30 cm 各 ≥10 次,报**中位数与最差值** | 触发→`Focused` 的帧数与时间;`Failed` 率 | ① 现状锁 `lensPosition = 0.835` 的成片(必须显著低于两者);② 把 ROI 换成全画面算同一指标 —— 若两者排序一致,说明 ROI 策略没起作用,要重新设计 |
| **B. 视频流持续对焦** | 预览帧**物体 ROI** 锐度的时间中位数 | 重触发次数/分钟;**振荡**(连续两次扫描的峰位差 < `step_fine` 却仍重扫 ⇒ 判振荡);每次扫描帧数 | 关掉场景变化门(`retrigger_delay = 0`)看振荡是否出现 —— 证明这道门是承重的 |
| 通用 | 同一静止场景 60 s 内扫描次数 ≤ 1 | 镜头位置曲线可回放(sidecar 已带逐帧内参,可同时画 fx(t)) | |

**数值门槛不预设**:先出对照表,肉眼裁。(历史上四次「指标放行了肉眼否决的东西」,不重蹈。)

---

## 7. 风险与未核

**许可 / 专利**
- 🔴 **「多峰取最近者」的明文只在 Samsung 专利 US 8,447,179 B2 里找到**("determine a subject corresponding to the peak of the nearest multi-point as the main subject"),未找到同等内容的论文。我们的「近焦优先 + 首峰即停」在 libcamera 里是**参数与起点的选择**(`startProgrammedScan` 起点 + `AfRangeMacro`),不是新算法,但**上生产前需专利检索**(本调研未做 FTO)。
- 🔴 Mir 2014 的 `focus_measures.zip` 与 Chen & van Beek 2015 的 `ml_autofocus.zip` **页面无任何许可声明** ⇒ 不抄代码,只用论文结论。
- 🔴 Wang 2021(TCI)仓**无 LICENSE 文件**、Herrmann 2020 **无代码且数据集无许可条款** ⇒ 学习型 AF 全线不可商用复刻。
- 🔴 Windaway / russwong89 / antonio490 三个 GitHub 实现**无 LICENSE = 保留所有权利**,只可读思路不可抄码。
- libcamera IPU3 的 AF 是 **LGPL-2.1**(与 RPi 的 BSD-2 不同),别抄错目录。
- `af.cpp` 行号取自 `raspberrypi/libcamera` main 今日快照;上游 libcamera-org 做过 `std::span` 重构,行号可能偏移,抄的时候按函数名对齐。

**平台**
- 🔴 **HarmonyOS**:`ManualFocus` 在 API 12–20 是**系统接口**(错误码 202 Not System Application),API 24 / HarmonyOS 6.1.1(2026-05-26)起才公开;且**只混入 `PhotoSession`,`VideoSession` 不含** ⇒ 鸿蒙上「视频流持续对焦」这条路**文档上就是堵的**,只能做「拍照会话里对焦」。C API 有无对应接口未核。
- 🔴 **Web**:`focusDistance` 只有 Chromium 实现(Chrome 76+);**WebKit IDL 里只存在于 FIXME 注释 ⇒ Safari 与 iOS Safari 不支持**;Firefox 的 webidl 无此成员 ⇒ Web 端软件对焦**只能在 Chrome 上做**,其余退化为用浏览器自带 AF。
- iOS:`lensPosition` 的 KVO 是否逐帧触发、锁焦切换是否闪帧、最小步进多少 —— **Apple 文档全无表述**,只能台架量。
- Android:UNCALIBRATED 机型移动中 `LENS_FOCUS_DISTANCE` 报请求值还是实际值只在 HAL 文本里对一种情形有要求;无最小步进、无到达时间上限。

**算法**
- 🔴 **景深数是用发表参数算的,不是实测**(见 §5),且真实焦距 6.86 mm 来自 EXIF 惯例而非 Apple 规格页明文 —— 这一条是本报告里最弱的一环。
- 🔴 iPhone 主摄**最近对焦距离**决定 10 cm 这一档能不能成立(`minimumFocusDistance` 只能在机上读,本调研不碰 iPhone)。若主摄最近对焦距离 > 10 cm,10 cm 档必须切超广角(原生「微距」就是这么做的),**这会换一颗镜头、换一套内参**,影响远超对焦本身。
- 文献里**没有一篇**验证过「中心加权 vs 最近主体 vs 主体检测框」在 10–30 cm 小物体上的优劣;学界基准多数直接取 ROI = 整幅图 ⇒ 我们的 ROI 策略**没有发表依据背书**,必须靠台架 A/B 自证。
- libcamera 的 `step_frames`(5 帧)是给树莓派 ISP 统计延迟定的,**手机上要重标**;我们自己算 FoM 没有 ISP 延迟,但有 GPU 归约与读回的延迟。
- 收敛帧数估算(§3.1 末)是**由参数推导**,不是任何人发表的实测值。

**未核**
- Kehtarnavaz & Oh 2003 的具体迭代步数(付费全文);Yao 2006 哪种搜索最省步(SPIE 403)。
- 「Chen 等 Fibonacci vs global vs hill-climbing」的那篇未能定位,最接近的两篇(2006 TCE / 2010 ASC)已列。
- 厂商一手 AF 论文:除 Google(Herrmann 2020)外,Samsung/华为/OPPO 未找到署名的 AF 算法论文,只有专利。
- VCM 执行器的发表值见 §5,凡没拿到 datasheet 原文的逐条标注。

---

## 8. 一手来源清单

**源码 / 许可**
- libcamera RPi AF:[af.cpp](https://github.com/raspberrypi/libcamera/blob/main/src/ipa/rpi/controller/rpi/af.cpp)、[af.h](https://github.com/raspberrypi/libcamera/blob/main/src/ipa/rpi/controller/rpi/af.h)、[af_algorithm.h](https://github.com/raspberrypi/libcamera/blob/main/src/ipa/rpi/controller/af_algorithm.h)、[COPYING.rst](https://github.com/raspberrypi/libcamera/blob/main/COPYING.rst)、调参 [imx708.json](https://github.com/raspberrypi/libcamera/blob/main/src/ipa/rpi/pisp/data/imx708.json)、公共控制语义 [control_ids_core.yaml](https://github.com/libcamera-org/libcamera/blob/master/src/libcamera/control_ids_core.yaml)
- [OpenCV videocapture_gphoto2_autofocus.cpp](https://github.com/opencv/opencv/blob/4.x/samples/cpp/videocapture_gphoto2_autofocus.cpp)、[Micro-Manager](https://github.com/micro-manager/micro-manager)、[Pertuz fmeasure 许可页](https://www.mathworks.com/matlabcentral/fileexchange/view_license?file_info_id=27314)、[focus-stack](https://github.com/PetteriAimonen/focus-stack)、[picamera2](https://github.com/raspberrypi/picamera2)

**平台文档**
- Apple:[lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)、[setFocusModeLocked](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:))、[isLockingFocusWithCustomLensPositionSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islockingfocuswithcustomlenspositionsupported)、[minimumFocusDistance](https://developer.apple.com/documentation/avfoundation/avcapturedevice/minimumfocusdistance)、[isAdjustingFocus](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isadjustingfocus)、[focusPointOfInterest](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focuspointofinterest)、[autoFocusRangeRestriction 枚举](https://developer.apple.com/documentation/avfoundation/avcapturedevice/autofocusrangerestriction-swift.enum)(正文取自 `developer.apple.com/tutorials/data/documentation/*.json`)
- Android:[LENS_FOCUS_DISTANCE](https://developer.android.com/reference/android/hardware/camera2/CaptureRequest#LENS_FOCUS_DISTANCE)、[LENS_INFO_FOCUS_DISTANCE_CALIBRATION](https://developer.android.com/reference/android/hardware/camera2/CameraCharacteristics#LENS_INFO_FOCUS_DISTANCE_CALIBRATION)、[LENS_STATE](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#LENS_STATE)、[LENS_FOCUS_RANGE](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#LENS_FOCUS_RANGE)、[CONTROL_AF_MODE_OFF](https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#CONTROL_AF_MODE_OFF)、[AOSP metadata_definitions.xml](https://android.googlesource.com/platform/system/media/+/refs/heads/main/camera/docs/metadata_definitions.xml)
- HarmonyOS:[ManualFocus(API 24+)](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-camera-kit/arkts-apis-camera-ManualFocus.md)、[ManualFocusQuery](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-camera-kit/arkts-apis-camera-ManualFocusQuery.md)、[FocusMode/FocusState 枚举](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-camera-kit/arkts-apis-camera-e.md)、[PhotoSession 混入表](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-camera-kit/arkts-apis-camera-PhotoSession.md)、[系统接口版 js-apis-camera-sys.md(6.0-Release)](https://gitee.com/openharmony/docs/blob/OpenHarmony-6.0-Release/zh-cn/application-dev/reference/apis-camera-kit/js-apis-camera-sys.md)
- Web:[W3C MediaStream Image Capture(ED 2025-04-23)](https://w3c.github.io/mediacapture-image/)、[Chrome status: focusDistance constraint](https://chromestatus.com/feature/5181454237564928)、[WebKit MediaTrackSupportedConstraints.idl](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/mediastream/MediaTrackSupportedConstraints.idl)
- Flutter:[CameraController](https://pub.dev/documentation/camera/latest/camera/CameraController-class.html)、[FocusMode](https://pub.dev/documentation/camera/latest/camera/FocusMode.html)

**我们自己的代码**(路径为工作树 `zero-arkit-preview-20260922`)
- `ios/Runner/PwCameraSlot.swift`:`:130-132` start 签名、`:237-241` 锁焦、`:323-395` 逐帧回调、`:707` 快门、`:468-483` 曝光/光圈读出
- `lib/quality/quality_compute.dart`:`:4-21` 128×128 缩略图上的 Laplacian 方差(现有清晰度算子,6 Hz)
- GPU 前端:`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/tools/pw_gpu_frontend.cpp:58,120`(sobel/harris 管线装载与派发)、`pw_gpufe_wgsl.h:13 k_sobel_dxdy`、`:380 k_gftt_max`
