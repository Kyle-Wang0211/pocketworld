# AliceVision 抄单执行账本(1–4 项)· 2026-08-25 凌晨批

四路调研(许可/管线/采集/横评)合成后的抄单前四项执行记录。原则:**能复刻的直接复刻,
不信自己的脑子**;但触碰生产质量取舍的,按本仓既有铁律(九门 A/B、单变量、用户签决)走门,
不在夜里偷改。每项给:做了什么 / 出处 / 剩什么。

## ① DSP-SIFT 档位对账 —— ✅ 对账完成,结论:范围已同源,唯一差异是档数(待签)

07-11 参数家谱(memory: pocketworld-dsp-param-genealogy)+ 本次管线调研合并对表:

| 参数 | 我们(COLMAP CPU parity 的 WGSL 移植) | AliceVision NORMAL | 判定 |
|---|---|---|---|
| dsp 范围 | (1/6, 3) | (1/6, 3) | **同源同值**(AliceVision 实现逐字抄 COLMAP) |
| dsp 档数 | **6**〔纠正 08-25:查现役源码 kDspNumScales=6,SCALE-6 2026-07-11 已合法换档+parity 过门;本行首版误写 10(照抄家谱的 COLMAP 锚点没核现役)〕 | **6**(NORMAL;MEDIUM=3) | **已同值** |
| 采样语义 | C++ fencepost(端点 3.0 采不到) | 同 COLMAP | 同源 |

〔08-25 纠正〕10→6 **已于 07-11 完成**(host A/B −7% wall,parity 门过)。剩余档位刀
= **6→3**(Meshroom MEDIUM 先例;论文消融 3 档保 88.5% DSP 增益、但 mAP 让 ~1-3 点)
—— 这一刀是真质量取舍,按家谱须 A/B + 用户签决;改动跨 header+4 个 WGSL(S5 事故
警示:shader 硬编码 DSP_NUM,必须同步动)。
peak/上限(0.005/20k)是桌面默认 vs 我们的设备预算漏斗(已审计),不属对账差异。

## ② 开火锐度择优 —— ✅ 已实装(跨端版),201 测试全绿,进 build 27

用户裁定:不用任何平台私有信号(iOS/Android/鸿蒙一致);"事后挑流"翻译成"事前缓拍"。

- 判据:**当前锐度 < 本段锐度中位 ⇒ 缓拍**,上限 0.25s(复用去抖地板,零新常数);
- 锐度源 = FrameQualityReport(128 灰度图纯 Dart Laplacian,四端一份实现,6Hz);
- "段" = 两次开火之间 = AliceVision KeyframeSelection 的 subsequence(相对排序、无绝对
  阈值,与其源码语义同构);样本 <3 fail-open(覆盖压过锐度,无损铁律);
- 代码:auto_capture_governor.dart(skipBlurry + kAutoCaptureBlurDeferMaxSec)、
  auto_capture_controller.dart(_segmentSharpness/_currentlyBlurry);测试:governor 4 条 +
  controller 4 条。**真机待验**(装 build 27 后看 skipBlurry 计数与糊片率)。

## ③ DepthMapFilter 两条精细化 —— ✅ 变体已写,待 MVS 产物对照验证

`Aether3D-cross/pocketworld_research_benchmarks/tools/python/filter_avplus.py`
(官方复刻件 diffmvs/filter.py **一字节未动**,尺子完整性优先):

1. geo_pixel_thres 1.0→2.0:AliceVision `pixToleranceFactor=2.0` 的图像空间等价
   (2×pixSize 的 3D 容差在图像空间恰好塌成 2px);
2. 低置信度救回:photo_mask 不过但 **≥4 源视图几何一致**仍保留(AliceVision
   `minNumOfConsistentCamsWithLowSimilarity=4`)—— 官方 AND 直接丢掉的强一致像素
   有条件捞回,涨覆盖不放鬼点。

验证计划:cap136 三臂 MVS 产物落地后,官方口径 vs AV+ 口径 A/B(覆盖四档/粗糙度/肉眼)。

## ④ SfM 质量门对表 —— ✅ 对表完成;三个结构差异 = 抄单第 6 项的消融候选

AliceVision(节点+引擎源码逐字)vs 我们 vendored COLMAP 4.1(A3X-colmap41 源码逐字):

| 门 | AliceVision | COLMAP 4.1(我们) | 判定 |
|---|---|---|---|
| 三角化最小角 | 3.0° | `min_angle = 1.5°` | AV 严 2×,消融候选 |
| BA 后保点角 | 2.0°(任一对观测) | `filter_min_tri_angle = 1.5°` | 近似 |
| BA 后保观测 | 4.0(**按特征尺度归一**) | `filter_max_reproj_error = 4.0`(裸像素) | 数同,归一化不同 → **结构差异①** |
| BA 重迭代 | 外点 >50 再来一轮 | 无对应 | **结构差异②** |
| 初始对 | 角度带 [5°,40°] + 金字塔占格分 | `init_min_tri_angle = 16°` + 内点数 | 准则族不同;我们端上流式为 ARKit 先验起步,不走经典自举 |
| resection | ACRANSAC 自适应(fallback 4px) | `abs_pose_max_error = 12.0` | **结构差异③(自适应阈值)** |
| pose 保留 | minPointsPerPose = 30 | `abs_pose_min_num_inliers = 30` | 同值 |
| 局部 BA | 图距离 1;前 30 逐台,后每 30 一组 | `ba_local_num_images = 6` | 策略族不同 |

判定沿横评路的举证反转(AliceVision SfM 整体基准输 COLMAP):数值门**不改**;
三个结构差异只经三臂消融法(参考臂+效应臂+噪声地板臂,判据序 肉眼>覆盖>粗糙>点数)进入。

## 并行进行中

- cap136 间距三臂(FULL 136 / SEL10 83 / SEL18 57):SfM 后台跑,MVS/融合/密度归一/并排页依次接力;
- filter_avplus 的 A/B 搭 MVS 产物顺风车。
