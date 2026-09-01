# 「信息增益触发快门」六路调研 —— 判据、出处、专利禁区

2026-09-01 深夜,六路 agent(开源关键帧 / Apple OC / RS+Polycam 文档 / 专利学术 /
中文 / 日韩俄欧),关键引文均回源核过。动因:用户目标「**最少的照片数量内获得
最多的新特征**」,并假设 RS/Polycam 必然不止"动够了就拍"。

## 总判决

1. **用户假设被证据推翻:RS 与 Polycam 的自动快门就是运动触发。**
   - Epic 官方:"the images will be captured with the **detected motion**"
     ([Step by Step Guide](https://dev.epicgames.com/documentation/en-us/realityscan-mobile/realityscan-step-by-step-guide))
   - Polycam 官方:"automatically decides when to take photos **based on your movement**"
     ([Object Mode](https://learn.poly.cam/hc/en-us/articles/27425185907348))
   - 结构铁证①:**两家都为转台专门做定时器模式** —— 若快门按内容触发,转台
     (机不动、物在转)根本不需要定时器。
   - 结构铁证②:RS 1.7.1 把 auto-capture 开进**没有实时点云**的 Camera Control
     模式;且点云需 20 张 + 云端分析才出现,auto-capture 从第 1 张就工作
     ⇒ 快门不依赖任何重建内容。
   - 点云/覆盖图两家均明说是给**人**看的("helping **you** to notice" /
     "so **you** can spot gaps")。
2. **我们的现状不落后于量产公开水平**:Polycam 教条 15–30°/张、70–75% 重叠;
   我们 12° 视差角 = 82% 重叠,更严。
3. **逐帧信息触发,五语种六路查证:没有任何量产 app 公开做过。** 做即第一批,
   但每个构件都有出处(见下)。

## 判据全景(源码级,文件存 ~/Developer/upstream_kf_sources_20260901/,19 份)

| 上游 | 判据(逐字) | 常数 |
|---|---|---|
| **VINS-Fusion** | `if (frame_count < 2 \|\| last_track_num < 20 \|\| long_track_num < 40 \|\| new_feature_num > 0.5 * last_track_num) return true;` | 0.5 / 20 / 40(≥4帧为长轨迹) |
| VINS-Mono(我们已复刻) | 同函数,只有 `last_track_num < 20` + 视差均值 | 源码里注释掉的两行是 Mono→Fusion 的演化痕迹 |
| ORB-SLAM2 单目 | `mnMatchesInliers < nRefMatches*0.9 && mnMatchesInliers > 15`(c2) | 0.9 / 15;论文自称 "minimum visual change" |
| stella_vslam | 追踪比 <0.5 触发;**>0.9 硬性禁拍**(冗余抑制) | 0.5 / 0.9 / 100 |
| RTAB-Map | 内点 ≤ 0.3×上一关键帧特征数 | 为里程计鲁棒性设计,太松 |
| DSO | 均方光流+光度加权 >1(**纯旋转项权重=0**) | 即"动够了";可借鉴其不为纯旋转建帧的立场 |
| COLMAP / AliceVision | 多层网格占据分(细层 w=dim² / 粗层 w=2^(L−l)) | **选图侧**;反向用于采集=无先例,判自研 |
| Kimera | 时间+中位视差 | 无增量 |

**理由出处**(为何信息判据优于运动判据):Bernoth 2016(FU Berlin 硕论,德语,
[PDF](https://www.mi.fu-berlin.de/inf/groups/ag-ki/Theses/Completed-theses/Master_Diploma-theses/2016/Bernoth/Master-Bernoth.pdf)):
"Durch die Sicherstellung, dass ausreichend neue Merkmale im KeyFrame gefunden
wurden, kann die exakte Distanz zwischen den KeyFrames unberücksichtigt bleiben"
—— 并给出失效案例:倒行机器人+前向相机,一直在动但永无新特征。
法国学派(Mouragnon 2006 血统):2D 匹配数跌破阈值即立关键帧。

## 🔴 专利禁区(FTO,两路独立命中)

- **Shopify US12361636B2**(active,2042 到期):独立权利要求 =「新增**不重叠 3D
  点数**超阈值 → 自动拍 2D」。**"数点云新点触发快门"这条最直觉的路字面命中,封死。**
- **Google US9648297B1**:3D/2D 特征比 ≥ 阈值 → 辅助拍摄(说明书含自动拍)。回避。
- **2D 轨迹判据(VINS-Fusion / ORB)不含"存储的 3D 扫描点集"要素,不落入上述权利要求。**
- 未穷尽:Samsung/Sony/Matterport/Occipital/Epic 专利检索没查完;另有一件
  "视锥交叠超 X% 触发"的专利未定位到号。这些是"没查完",不是"查过为零"。

## Apple Object Capture(黑盒,但有可抄的文档化行为)

- 架构是"**从流里选帧**"不是"事件触发快门":WWDC23 原话 "automatically **select**
  image shots with good sharpness, clarity, and exposure";自家专利 US11580692B2
  同口径(按运动缺陷选子集)。逐张触发算法未公开,官方示例代码零 cadence 逻辑。
- 可抄:capture dial = **方位角切段**,每段 "has adequate images" 才点亮(覆盖判据,
  不踩 Shopify);两级光照(lowLight 警告继续拍 / tooDark 才停);**拍后冷却期是
  文档化行为**(`canRequestImageCapture` 有一段时间为 false)—— 我们的 250ms
  地板第一次有了同类先例。

## 落刀决定(见对应 commit)

**复刻 VINS-Fusion 的 `new_feature_num > 0.5 * last_track_num`。** 理由:唯一直接
数"新特征"的;与我们已复刻的视差判据**同仓库同函数**,是上游自己的下一版;
2D 轨迹,避开专利。适配边界(须逐条标注):①用途从滑窗边缘化改为快门触发;
②new 的数法 = 当前帧检测的角点中不在任何存活轨迹 MIN_DIST 邻域内者(对应上游
setMask+addPoints 结构);③检测节流到 2–4Hz(上游前端 10Hz;host 实测检测
1.36ms/次,不能上 60Hz 位姿流);④`long_track_num<40` 绑定上游 10Hz 帧率,
不搬。stella 的 >0.9 禁拍闸、ORB c2 为备选,混第二家上游需用户裁决。

相关:[[2026-09-01-realityscan-instant-photo-card-and-arkit-capture-stall]](同日
上一轮调研)、memory `project-pocketworld-0827-rollback-baseline`。
