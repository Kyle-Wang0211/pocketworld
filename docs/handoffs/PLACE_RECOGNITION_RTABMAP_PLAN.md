# 「这个视角我是不是拍过」—— 复刻 RTAB-Map 的地点识别

用户 2026-09-10 圈出两张空间重合的卡片:"为什么会判定可以拍摄呢?虽然这两张
照片拍摄的时间相隔很长"。裁决:**走 RTAB-Map**。

## 为什么不是光流(已判死,别再走回头路)

先用 LK 做过一次性两帧匹配,**失败**。根因不是接线:
`_trackPyramidal` 是 OpenCV `calcOpticalFlowPyrLK` 的忠实移植,而
**OpenCV 的 status 只表示「没飞出边界 / 矩阵没退化」,不检验匹配正确性**。
位移小时起点贴着真答案所以没事;跨几十像素时 LK 会收敛到垃圾并**报成功** ——
实测:相机早已走远,老照片却"匹配"上 156/160,判决被假阳性淹没
(接进判决路径后 `skipRedundant` 刷 301 次、只出 17 张)。
**"这地方来过没有"是重定位问题,不是跟踪问题。**

## 源与许可(2026-09-10 拉源核实,源码在 ~/Developer/upstream_reloc_sources_20260910)

- **RTAB-Map** — BSD-3(`rtabmap_LICENSE`)。**不带预训练词表**:
  `Kp/IncrementalDictionary=true`、`Kp/DictionaryPath=""` ⇒ **出货成本 0**。
  (对比 stella_vslam BSD-2 但要带 **42.9 MB** ORB 词表。)
- 默认检测/描述:`Kp/DetectorStrategy` 有 `#ifdef` 分叉 —— 有 xfeatures2d 是
  `6`(GFTT/BRIEF),**没有是 `8` = GFTT/ORB**。我们没有 BRIEF ⇒ 照抄
  **GFTT/ORB**。GFTT 已在 `continuous_feature_tracks.dart` 复刻完毕
  (OpenCV goodFeaturesToTrack,qualityLevel=.01 / minDistance=7)。
- ORB 描述子取 OpenCV 4.x `modules/features2d/src/orb.cpp`(Apache-2.0),
  采样表 `bit_pattern_31_[256*4]` 已抽出并**过阳性对照**(1024 个整数、
  范围 −13..12)⇒ `orb_bit_pattern_31.json`。

## 判决怎么接(有一处**明确不抄**)

🔴 `Rtabmap/LoopThr = 0.11` 是**贝叶斯滤波后验**的门,不是原始似然的门。
直接拿它卡似然 = 移位前提。所以:

- **RTAB-Map 供匹配机制**:GFTT → ORB 描述子 → 增量词典量化成"词" →
  倒排索引 → 取共享词最多的那张。**词的比对不怕大位移**,这正是 LK 死的地方。
- **stella 供判决**:那张 = 上游的 `ref_keyfrm`,再喂进我们**已经复刻好的**
  `almost_all_lms_are_tracked`(比例 0.9)。两边都不新增阈值。
- 相似度形状对得上:RTAB-Map 关掉 TF-IDF 时 `Signature::compareTo` 就是
  `配对词数 / max(两边词数)`,与我们现役的 `commonTrackCount / seedTrackCount`
  同一个形状。

抄来的常数(全部有出处,`rtabmap_Parameters.h`):
`Kp/MaxFeatures 500` · `Kp/NndrRatio 0.8`(Lowe) · `Kp/BadSignRatio 0.5` ·
`Kp/TfIdfLikelihoodUsed true` · `Kp/NewWordsComparedTogether true`
TF-IDF 公式逐字(`rtabmap_Memory.cpp:2283` `Memory::computeLikelihood`):
`likelihood[j] += (nwi * log10(N/nw)) / ni`

**不抄**:PnP/RANSAC(stella 那半)、时序贝叶斯滤波(RTAB-Map 那半)——
我们的问题止于"哪张老照片覆盖了当前视角"。

## 步骤

1. ORB 描述子(方向用灰度质心矩 + steered rBRIEF),拿 OpenCV 官方测试向量对拍。
2. 增量词典:新描述子对已有词做近邻,NNDR 0.8 判"是老词还是新词"。
3. 倒排索引 + TF-IDF 似然,取 argmax = `ref_keyfrm`。
4. 接进 `numReliableLms` / `numReliableLmsRef`(**argmax**,不是替换 ——
   最近那张仍用传播式读数,它对小位移更准;老照片只有共享词更多时才夺参考权)。
5. 遥测带上扫描代价,复用已落地的成本基线
   `test/ref_keyframe_scan_cost_bench_test.dart`。

## 已落地的部分

`f3fec72`:一次性匹配内核 + **无损分支限界**(只取 argmax ⇒ 追不上就放弃,
结果逐位不变)。剪枝实测 35 张 393.9→6.3 ms(63×)、300 张 3500.6→19.3 ms
(181×)。内核本身因上面的 LK 缺陷**未接进判决路径**;分支限界这套骨架与
成本基线对 RTAB-Map 这条路同样适用。
