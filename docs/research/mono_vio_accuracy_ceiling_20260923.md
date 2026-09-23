# 单目 VIO 精度与米制尺度的今日天花板 —— 多语言调研

日期:2026-09-23 · 引擎:XRSLAM(RD-VIO,openxrlab,Apache-2.0)· 约束:手机实时 + 单目 + 许可可商用 + 可插进现有引擎

---

## 0. 判决(一句话)

**在「手机实时 + 单目 + 许可可商用」这三条同时成立的前提下,今天不存在一个能显著超过 RD-VIO 的现成开源方案可以整体替换;
天花板不在算法族的选择上,而在一个具体机制上——把「尺度只在初始化解一次」改成「尺度作为显式变量被周期性重优化」。
这个机制有逐字出处(ORB-SLAM3 TRO 2021),有公开的收益数字(5% → 1% 尺度误差),而且实现它所需的线性求解器
已经在我们自己的 Apache-2.0 代码树里(`initializer.cpp:426 / :467`)——只是被关在初始化器里、只跑一次。**

---

## 1. 先纠正一个前提:尺度并没有从估计器里消失

上游任务书写的是「`estimation/solver.cpp` 与 `preintegrator.cpp` 里 "scale" 出现 0 次 ⇒ 尺度从估计器里消失、不再更新」。
**这个推论结构上不成立**,理由是两条独立证据:

**(a) 源码证据(本机 `~/Developer/xrslam`,已逐行核)**
- `xrslam/src/xrslam/estimation/solver.cpp:152-162` —— `add_factor(PreIntegrationErrorFactor*)` 把
  `frame_i->pose.p / motion.v / motion.bg / motion.ba` 与 `frame_j` 的同四组一起绑进一个残差块。
  IMU 预积分残差本身是**米制**的(Δp、Δv 的单位是米),所以只要它在窗里,视觉的无量纲结构就被持续钉在米上。
- `solver.cpp:100-110` —— `add_frame_states(frame, with_motion=true)` 把每一帧的 `v / bg / ba` 都作为**自由参数块**加入。
- `core/sliding_window_tracker.cpp:387-391` —— 每个关键帧对之间重新 `integrate()` 并 `put_factor(create_preintegration_error_factor(...))`。
- `estimation/marginalization_factor.h:20-26` 与 `ceres/marginalization_factor.h:40-44` —— 边缘化先验保存
  `pose_linearization_point / motion_linearization_point` 并对残差取相对量(这是 FEJ 形式的线性化点固定)。

⇒ **任何紧耦合 VIO 在初始化之后都没有显式的 `scale` 变量**:VINS-Mono、OKVIS、ORB-SLAM3 的跟踪期同样如此。
grep 不到 "scale" 是这一族的常态,不是缺陷指纹。

**(b) 数字证据(反向,来自 RD-VIO 同一个实验室)**
XR-VIO(arXiv [2502.01297](https://arxiv.org/abs/2502.01297),2025,Zhai/Wang/Chen/Xie/Bao/**Guofeng Zhang**,ZJU-SenseTime)
Table 2 报 EuRoC 上**只给 4 / 5 个关键帧**时各家初始化的尺度误差:
Closed-form 29.95 / 25.39 % · Inertial-only(ORB-SLAM3 的初始化)48.84 / 39.09 % · VINS-Mono 32.64 / 28.75 % ·
DRT-l 41.79 / 34.57 % · DRT-t 61.54 / 50.46 % · **XR-VIO 26.88 / 22.71 %**。
⇒ **初始化瞬间的尺度误差在 20–60% 量级**。我们实测同场四段是 **0.73%–10.80%**。
如果尺度真的「被前 1.2 秒定死、之后不再更新」,我们不可能落在 10% 以内。**这正好证明滑窗里的 IMU 因子一直在修尺度。**

**(c) 上游自己的原话(2026-09-23 新取,Campos 博士论文 UZ 2021,ORB-SLAM3 一作)**
> 「pure inertial parameters like `g_dir` and `s` **do not appear**, but they are **implicitly included in keyframe poses**」(p.35,讲 visual-inertial BA)

⇒ **连 ORB-SLAM3 本身在跟踪期也没有常驻 scale 变量。**它的 scale 只活在一个专门的
`inertial-only optimization` 里(状态 `X_k = {s, R_wg, b, v̄_{0:k}}`),并且这个通道**有终止条件**
(>100 关键帧或初始化后 >75 秒,之后就永久关闭)。
同一份论文 p.36 还给了一句对我们直接对口的对比:
> **VINS-Mono 边缘化旧状态,ORB-SLAM3 固定旧状态,所以前者的初始尺度误差还能在后续被继续压下去。**

我们的边缘化实现与 VINS-Mono 同型(`marginalization_factor.h`),**这就是「我们实测 0.73%–10.80%
而不是 XR-VIO 表里那 20–60%」的机制解释**。

**所以真正的缺口要重新表述:**
我们缺的不是「尺度变量」,而是 ORB-SLAM3 那一条**显式尺度参数化 + 周期性重优化**的通道。
ORB-SLAM3 原话(arXiv [2007.11898](https://arxiv.org/abs/2007.11898) §V-B,TRO 2021):
> "As shown in [56], **scale converges much faster when it is explicitly represented as an optimization variable**."
> "Our exhaustive initialization experiments on the EuRoC dataset show that this initialization is very efficient,
>  achieving **5% scale error with trajectories of 2 seconds**. To improve the initial estimation, visual-inertial BA
>  is performed **5 and 15 seconds after initialization, converging to 1% scale error**."
> "This optimization … is performed in the Local Mapping thread **every ten seconds**, until the map has more than
>  100 keyframes, or more than 75 seconds have passed since initialization."

其中 [56] = Campos/Montiel/Tardós,*Inertial-Only Optimization for Visual-Inertial Initialization*,ICRA 2020
(arXiv [2003.05766](https://arxiv.org/abs/2003.05766)),摘要逐字:「able to initialize in less than 4 seconds in almost
any point of the trajectory, with a **scale error of 5.3% on average**」。

DM-VIO(arXiv [2201.04114](https://arxiv.org/abs/2201.04114),RA-L 2022,TUM)摘要逐字给了同一条判断:
> "we **continue to optimize scale and gravity direction in the main system after IMU initialization is complete**"
配套机制是 **delayed marginalization**:「maintain a second factor graph, where marginalization is delayed」,
从而能「readvance this delayed graph, yielding an **updated marginalization prior with new and consistent
linearization points**」。这正是「改了尺度之后旧先验怎么办」的公开解法。

---

## 2. 精度天花板表(口径已逐项标注,口径不同的数不能横比)

| 方法 | 年份 | 数据集 | 数字 | 口径 | 实时性 | 许可 |
|---|---|---|---|---|---|---|
| **ORB-SLAM3 mono-inertial** | 2021 TRO | EuRoC | ATE 平均 **0.043 m**;尺度误差平均 **0.9%** | SE3(米制,不拟合尺度) | 实时,i7-7700K 桌面 | **GPL-3.0 ❌** |
| ORB-SLAM3 初始化 | 2020 ICRA | EuRoC | 2 s → 5% 尺度误差;5/15 s VI-BA → **1%** | 尺度误差 | — | GPL-3.0 ❌ |
| Campos inertial-only | 2020 ICRA | EuRoC | <4 s 初始化,**5.3%** 平均尺度误差 | 尺度误差 | — | GPL-3.0 ❌ |
| **DM-VIO mono-inertial** | 2022 RA-L | TUM-VI | 16/若干序列最优,**平均 drift 0.472**(Basalt 双目 0.939) | drift(非 ATE) | **实时,2013 MacBook Pro i7 2.3GHz,无 GPU** | **GPL-3.0 ❌** |
| **XR-VIO 初始化** | 2025 arXiv | EuRoC | 4KF **26.88%** / 5KF **22.71%** 尺度误差(全表最好) | 尺度误差 | 手机视频演示;2-View 24.2 ms + VG-BA 12.1 + VA-Align 0.09 + VI-BA 14.9 ms | **无代码发布** 🟡 |
| SLIM-init | 2026 IROS | EuRoC | 初始化 **4.1 ms**,位姿 RMSE **0.110 m** | RMSE | — | GPL-3.0 ❌ |
| DL-VINS-Factory 最好学习前端 | 2026 arXiv | EuRoC 单目 | ALIKED+LightGlue **0.146 m**;经典 GFTT+LK **0.154 m** | ATE,≤256 特征 | 29–47 FPS,**Jetson AGX Orin + TensorRT** | 仓库标 CC0 🟡 |
| **RD-VIO(= 我们)** | 2024 TVCG | 论文自报头对头,VICON | 慢扫 **22.4 mm** vs ARKit 15.6 mm | — | **iPhone X 实时,640×480@30Hz** | **Apache-2.0 ✅** |
| 我们的复刻 | 2026 | 自采共享录制 | 1920 臂 **19.9 mm** / 尺度 0.22%;ARKit 同录 26.0 mm | SE3 因果 | iPhone 实时 | Apache-2.0 ✅ |

**读表的三条纪律**
1. 我们的 19.9 mm 与 ORB-SLAM3 的 43 mm **不能比**:不同数据集、不同运动、不同真值。能比的只有**同一份录制**上的数。
2. 唯一可以跨论文比的是**尺度误差**这个无量纲量:ORB-SLAM3 EuRoC 平均 **0.9%**,我们同场分段 **0.73%–10.80%**。
   ⇒ 我们的好段已经在它的量级,**差段差 10 倍**。天花板的位置就在这两个数之间。
3. 另一条独立的量纲刻度:arXiv [2603.26740](https://arxiv.org/abs/2603.26740)(2026-03,*Quantifying Motion
   Excitation for Metric Scale Observability in Monocular VIO*)在差速轮机器人上实测同一系统不同运动的尺度误差:
   **直线 9.2% / 圆周 6.4% / 8 字 4.8%**,激励度量跨 **4 个数量级**。
   ⇒ **「同一套代码、同一场景、不同运动 ⇒ 尺度误差 5–10%」是已发表的常态,不是我们的 bug。**

**「这是不是今天的 SOTA?」**
- ORB-SLAM3(2021)与 DM-VIO(2022)在单目+惯性这条线上**到 2026 年仍是被普遍引用的参照系**:
  2026 年的 DL-VINS-Factory 原话「EuRoC … is largely solved under its well-lit, structured conditions」,
  2026 年新论文(KLTNet 2608.24544、ROFT-VINS、OTPL-VIO)仍以 VINS-Mono / OpenVINS 为底座做消融。
- 换句话说:**这条赛道 2022 年之后没有出现量级性的新 SOTA**,新论文的增益集中在**鲁棒性**(退化、动态、低纹理)而非 EuRoC 上的绝对精度。
- ⚠️ 未核:LaMAria(ICCV 2025,ETH+Meta,lamaria.ethz.ch)有 leaderboard,但其指标是 "score / R@5m",
  **页面未定义是否等价于 ATE**,因此本表不收它的数。

---

## 3. 尺度持续可观:机制清单与可商用参考实现

### 3.1 机制(按「能不能在不换引擎的前提下装上」排序)

| # | 机制 | 出处 | 可商用参考实现 | 我们能不能装 |
|---|---|---|---|---|
| M1 | **显式尺度变量 + 周期性重优化**(2s 初始化 → 5/15 s VI-BA → 之后每 10 s) | ORB-SLAM3 TRO 2021 §V-B;Campos ICRA 2020 | 🔑 **我们自己的树**:`initializer.cpp:426 solve_gravity_scale_velocity()`(线性解 g/s/v)、`:467 refine_scale_velocity_via_gravity()`(g 降到 2DoF 切空间 + damp 0.1)、`:543 apply_init()`(把 s 乘进位姿与三角化点) | ✅ 求解器已有,**被 `initializer.h:22` 的 `private:` 关在一次性初始化器里** |
| M2 | **delayed marginalization**:第二份延迟边缘化的因子图,改完尺度后 readvance 出一致的新先验 | DM-VIO RA-L 2022 摘要逐字 | ⛔ 代码 GPL-3.0;**无任何宽松实现** | 🟡 机制可自实现,是 M1 的配套难点 |
| M3 | **尺度漂移风险指标**(相对平移信息矩阵的 PCA,作为不确定度的隐式度量) | granite,IROS 2021,arXiv [2109.05509](https://arxiv.org/abs/2109.05509) 原话「a novel approach to estimate the current **risk of scale drift** based on a **principal component analysis of the relative translation information matrix**」 | ✅ **DLR-RM/granite,MIT** | ✅ 只读指标,当闸用,零风险 |
| M4 | **激励度量**(从原始 IMU 算,不需要真值) | arXiv 2603.26740,2026 | 🟡 论文无代码 | ✅ 可自实现,极轻 |
| M4b | **可观测性闸**:对首次 BA 的 Hessian 做 SVD,**最小奇异值 < `t_obs` 就整个丢弃这次解**(不求逆) | Campos 博士论文 §3.3,完整参数 `M=200, l=200, m=20, n=5, **t_obs=0.1**, t_cons=90%`(**只在学位论文里,会议论文无此表**) | 🟡 无宽松代码,但只有几行 | ✅ 强烈建议,和 M3 二选一或并用 |
| M4c | **`b_a` 先验残差** `r_p = ‖b_a‖²_Σp` 替代「置零或等待」:激励不足时把加速度计零偏压在 0 附近,激励够时自然收敛 | Campos 博士论文 p.34 | 🟡 几行 | ✅ 与 M1 同批做 |
| M5 | **神经惯性位移因子**(独立于视觉的米制平移约束) | RNIN-VIO,ISMAR 2021 | ✅ **zju3dv/rnin-vio,Apache-2.0,含预训练权重** | ✅ 见 §5 |
| M6 | **等变滤波 / 不变 EKF**(结构上正确处理不可观方向,改善一致性) | MSCEqF,arXiv 2311.11649;Brossard/Bonnabel/Barrau FUSION 2018 | ✅ **aau-cns/MSCEqF Apache-2.0**;**artivis/kalmanif MIT**(右不变 IEKF,含 `demo_se_2_3.cpp`)+ `artivis/manif` MIT;`RossHartley/invariant-ekf` BSD-3 | ❌ 需换整个后端(滤波 vs 优化);且**尺度收益本轮未验到**(法语侧正文被反爬挡住) |
| M7 | **把尺度做成群元素**(Sim(d) 的推广,误差传播不依赖估计值) | Chauchat/Barrau/Bonnabel, IFAC 2024, doi:10.1016/j.ifacol.2024.08.300 | 🟡 无实现 | ❌ 论文算例是**轮半径/加速度计标度因数**,**没做单目重建尺度** ⇒ 迁移=自研 |
| M8 | **相机-IMU 时偏的独立测量**(陀螺互相关) | Skoltech `twist-n-sync`,doi:10.3390/s21010068 | ✅ **Apache-2.0** | ✅ 白捡的排查工具:时偏是尺度漂移的常见根因 |

### 3.2 逐仓许可裁决(全部用 GitHub API 取 LICENSE **文件本体**或 `.license.spdx_id`,不看徽章)

**✅ 可商用**
`openxrlab/xrslam` Apache-2.0 · `zju3dv/PVIO` Apache-2.0 · `zju3dv/RLP_VIO` Apache-2.0 · `zju3dv/rnin-vio` Apache-2.0 ·
`zju3dv/eval-vislam` Apache-2.0 · `baidu/ICE-BA` Apache-2.0 · `ethz-asl/maplab` Apache-2.0 · `aau-cns/MSCEqF` Apache-2.0 ·
`DLR-RM/granite` **MIT** · `VladyslavUsenko/basalt-mirror` BSD-3 · `smartroboticslab/okvis2` BSD-3 · `ethz-asl/rovio` BSD-3 ·
`MIT-SPARK/Kimera-VIO` BSD-2 · `CathIAS/TLIO` BSD-3(Facebook)· `verlab/accelerated_features`(XFeat)Apache-2.0 ·
`cvg/LightGlue` Apache-2.0(⚠️见下)· `Shiaoming/ALIKED` BSD-3 · `princeton-vl/DPVO` MIT · `mbrossar/denoise-imu-gyro` MIT

**❌ 不可商用**
`UZ-SLAMLab/ORB_SLAM3` GPL-3.0 · `lukasvst/dm-vio` GPL-3.0 · `rpng/open_vins` GPL-3.0 · `uzh-rpg/rpg_svo_pro_open` GPL-3.0 ·
`SpectacularAI/HybVIO` GPL-3.0 · **`bytedance/SchurVINS` GPL-3.0**(README 原文「The code is licensed under GPLv3」,派生自 SVO2.0)·
HKUST VINS 全族 GPL-3.0 · i2Nav-WHU 全族 GPL-3.0 · `url-kaist/dynaVINS` GPL-3.0 · `url-kaist/Patchwork2` **AGPL-3.0** ·
SLIM-init(`cjunwan/SLIM-init`)GPL-3.0 · `Sachini/ronin` GPL-3.0 ·
`KumarRobotics/msckf_vio` Penn 学术许可「**non-profit research purposes only**」且禁止再分发 ·
`aau-cns/mars_lib` BSD-2 + **「the License does not grant to you, the right to Sell the Software」** ·
`ucla-vision/xivo` **Academic Software License — No Commercial Use**

**🔴 三个「根 LICENSE 骗人」的陷阱(同一天撞到三次,已成规矩:判许可必须开源码文件头)**
1. **`cvg/LightGlue`**:根 LICENSE = Apache-2.0,但 `lightglue/superpoint.py` 文件头逐字是
   「Magic Leap, Inc. ("COMPANY") **CONFIDENTIAL** … All Rights Reserved … Dissemination of this information or
   reproduction of this material is **strictly forbidden**」。⇒ **LightGlue + SuperPoint 组合被污染**;
   只有 LightGlue + **DISK / ALIKED / SIFT** 是干净的。
2. **`url-kaist/VinsFusionSC`**:根 LICENSE 写 MIT,但 `vins_estimator/src/estimator/estimator.cpp` 文件头是 HKUST 的
   GPLv3 —— 下游无权把上游 GPL 改成 MIT,**实际是 GPLv3**。
3. **`PetWorm/LARVIO`**:根目录无 LICENSE;`licenses/` 里同时躺着 VINS-Mono GPLv3、ORB-SLAM2 GPLv3、Penn 非商用;
   `src/initial_alignment.cpp` 等是 VINS-Mono 逐文件搬运且 **GPL 头被剥掉了**。⇒ 双重禁用。

**🟡 无许可 = 保留一切权利(不可用)**
`sair-lab/AirIMU`(GitHub API 404:仓内没有 LICENSE 文件)· `Yuantai-Z/FF-VIO-Init`(只有 README,代码未发布)· `glim_ext`(README 自承依赖 ORB_SLAM3 GPL)

### 3.3 「有没有人做过同样的改造」

- **有,而且做过两次,但两次的代码都是 GPL**:ORB-SLAM3(周期性 inertial-only MAP + VI-BA)和 DM-VIO(尺度/重力进主能量 + delayed marginalization)。
- **宽松许可这一侧是空地**:逐仓核过,`Kimera-VIO/include/kimera-vio/initial/OnlineGravityAlignment.h` 通篇**没有 scale**
  (它是双目,尺度天生可观);`granite` 的 `doc/VioMapping.md:55-56` 逐字写
  「Currently only stereo, stereo-inertial and monocular odometry setups are supported. **Monocular-inertial setups
  can not be handled.**」;`basalt` 是 stereo-inertial;`okvis2` 我们已实测同口径因果 SE3 4.70–6.42 cm(差 RD-VIO 约 2×)。
- ⇒ **结论:没有现成的宽松许可实现可以移植,但也不需要——线性求解器我们自己有,要做的是生命周期改造。**

### 3.4 工程量估计(基于本机源码实读)

| 步骤 | 内容 | 量级 |
|---|---|---|
| 1 | 把 `Initializer` 的 `solve_gyro_bias / solve_gravity_scale_velocity / refine_scale_velocity_via_gravity` 从 `private` 抽成一个可在任意 `Map*` 上跑的 `ScaleRefiner`(纯函数化,不碰现有初始化路径) | 小(~200 行,零行为变更) |
| 2 | 在 `SlidingWindowTracker` 里按节拍(参照 ORB-SLAM3:5 s / 15 s,之后每 10 s)在**当前滑窗**上跑一次 g/s/v 线性解,拿到 `s_new` | 中 |
| 3 | 🔴 **真正的难点**:把 `s_new` 应用到滑窗位姿+逆深度后,`map->marginalization_factor` 的 `pose_linearization_point / motion_linearization_point`(`marginalization_factor.h:35-36`)还停在旧尺度上 ⇒ 必须**重建先验**(最简单:丢弃并重新累积)或实现 M2 的 delayed marginalization | 大,是全部风险所在 |
| 4 | 用 M3/M4 做闸:只在激励足够时才接受 `s_new`,否则跳过 | 小 |
| 5 | 验收尺子:接 `zju3dv/eval-vislam`(Apache-2.0)的 `initialization` 工具 | 小 |

---

## 4. 多语言普查(英文为基底;每语种都报「查了什么 / 命中什么 / 零命中」)

### 4.1 西班牙语(最高优先级:Zaragoza = ORB-SLAM3 娘家)

**判决:西语渠道对「方法」的增量为零,但对「机制的完整描述」增量极大。**
Campos 博士论文《Precise and Robust Visual SLAM with Inertial Sensors and Deep Learning》(UZ 2021,导师 Tardós,
[Zaguan record 110854](https://zaguan.unizar.es/record/110854),PDF `TESIS-2022-050.pdf`)**正文是英语**,
只有 `Agradecimientos` 与 `Resumen` 是西语(Dialnet 的「语言=español」是行政字段,不可信)。
子 agent 逐条把四个最像「未发表工程细节」的点回查英文原文,**四个全部已在英文论文里**
(尺度种子取场景中值深度 1/4/16 m 三次起优化取残差最小;`s_new = s_old·exp(δs)` 正性参数化;
`∂r_Δv/∂δs`、`∂r_Δp/∂δs` 的解析雅可比;每 10 s 一次的 refinement 节拍)。
⇒ **不要再指望西语学位论文补 ORB-SLAM3 的工程细节,这一家把东西都发在英文里了。**

🔑🔑 **但学位论文把「初始化之后尺度到底怎么活」讲清楚了,而且它的结论和我们 §1 的纠正完全一致:**
- **显式 scale 变量只活在一个专门的优化里**:`inertial-only optimization` 的状态
  `X_k = {s, R_wg, b, v̄_{0:k}}`,`s ∈ R⁺`,重力方向 `R_wg` **只用两个角 (α,β) 参数化**
  (绕 z 无效),retraction `R_wg ← R_wg·Exp(δα_g, δβ_g, 0)`。
- **"scale refinement" 是第四种优化(论文图 4.2d),不是 BA**:把**所有已插入关键帧**放进来,
  但**只估 s 和重力方向两项**,bias 取 mapping 估好的值并**固定**(原文明说此时「constant biases 假设不成立」)。
  跑在 Local Mapping 线程,**每 10 秒一次,终止条件 >100 KF 或 >75 s**。
- 🔑 **之后 s 就彻底消失了**。论文 p.35 逐字:
  > 「pure inertial parameters like `g_dir` and `s` **do not appear**, but they are **implicitly included in keyframe poses**」
  ⇒ **ORB-SLAM3 自己也没有常驻 scale 变量**,它靠的是「初始化后 75 秒内反复重解 s 并整体缩放地图」这一段**有限时窗**。
  这条逐字出处把 §1 的纠正钉死了。
- 🔑🔑 **最对口的一句(p.36)**:
  > VINS-Mono **边缘化**旧状态,ORB-SLAM3 **固定**旧状态,所以**前者的初始尺度误差还能在后续被继续压下去**。
  **我们和 VINS-Mono 同型(边缘化)** ⇒ 这是「我们实测 0.73%–10.80% 而不是 20–60%」的机制解释,
  也再次说明**问题不是「尺度不再更新」,而是「没有一个专门把尺度压到 1% 的通道」**。

**收敛时间与激励(数字出自 §3.3.2 / §3.2.3)**
- **2 s 轨迹 → 尺度误差 ~5%**(`tInit≈2.16 s`、`tTot<4 s` 时 5.29%);轨迹缩到 1.25 s 明显变差。
- **<1% 需要 10 秒**:表 3.4,三条 EuRoC 序列在第一关键帧后 5 s / 10 s 各跑一次全 VI-BA,**10 s 后全部 <1%**。
  对照:ORB-SLAM-VI 需 15 s 才出第一个尺度,VI-DSO 需 **20–30 s 才收到 1%**。
- 激励是决定性的:VINS-Mono 在整条序列上 ATE 0.08–0.32 m,但穷举初始化测试里尺度误差 **22.05%**;
  论文归因「从头启动时初始化发生在**无人机起飞阶段,意味着大加速度,使惯性参数更可观**」。
- 各方法在 VI-BA 之前**普遍低估尺度**(图 3.9),VINS-Mono 有大量解的尺度接近 0。

**失败模式与闸(明文)**
- p.25 逐字:「if the motion performed gives low observability... the optimization can converge to
  **arbitrarily bad solutions**. For example this happens in case of **pure rotational motion or non-accelerated motions**」。
- p.44:「when **slow motion** does not provide good observability... initialization may fail to converge」
  —— 这正是 scale refinement 存在的理由。
- **可观测性闸**:对第一次 BA 的 Hessian 做 SVD,**最小奇异值 < `t_obs` 就整个丢弃这次初始化**
  (不求逆,避免大方阵求逆)。**表 3.1 的完整参数值 `M=200, l=200, m=20, n=5, t_obs=0.1, t_cons=90%`
  是学位论文独有的**,ISMAR/ICRA 论文里没有完整表。
- `b_a` 的处理是**加先验残差 `r_p = ‖b_a‖²_Σp`**(p.34)而不是置零或等待:激励不足时先验把它压在 0 附近。
- 作者自承缺口(p.39):希望做「**information self-aware** 的 inertial-only 优化」—— 不固定初始化时长,
  按惯性参数的信息量自适应选轨迹长度,并**只取轨迹中信息量高的片段**。**这是他们自己指出的、尚未实现的方向。**

**其他西语材料(全西语,价值有限)**
- Domínguez Conti《Inicialización SLAM Visual-Inercial: una formulación lineal general》TFM, UZ 2020
  ([Zaguan 90016](https://zaguan.unizar.es/record/90016)):指出闭式法的结构性限制是
  「**precisan de features comunes a todos los frames durante la inicialización**」,其贡献是允许初始化中动态加入新特征。
- Oliva Maza《Inicialización del estado para un sistema monocular inercial》TFG, UZ 2018
  ([Zaguan 77796](https://zaguan.unizar.es/record/77796)):报闭式初始化在 EuRoC 上**成功率约 75%** ⇒ **四分之一的时间直接失败**。
- Vizárraga Huerta TFG, UZ 2018([Zaguan 76574](https://zaguan.unizar.es/record/76574))。
- **UMA-VI 数据集**(Málaga,González-Jiménez 组,[doi:10.1177/0278364920938439](https://doi.org/10.1177/0278364920938439)):
  **低纹理 + 动态光照**,32 序列,只在首尾给真值 —— 与我们的白墙工况同型,🟡 **许可本轮未核**。
- Solà《Quaternion kinematics for the error-state Kalman filter》(IRI, CSIC-UPC)**仅英语,无西语版**。

**零命中(明确声明)**
Zaguan 搜 `escala metrica monocular` → 相关命中 **0**;SciELO / Redalyc 搜 `odometría visual inercial` + `escala monocular`
→ 一手论文 **0**;西语术语 `observabilidad de la escala` → 一手西语文献 **0**;
拉美圈(CIMAT / INAOE / 阿根廷 / 智利)关于「初始化后尺度持续估计」→ **0**。
🔴 **TDX(tesisenred.net)与 TESEO 本轮未能真正检索到**(两次 curl 均无返回体,只拿到入口页)⇒
「我搜过了」这句话在这两个库上**不成立**。

### 4.2 中文
- 🏆 **`zju3dv/eval-vislam`(Apache-2.0)**:商汤/浙大官方评测工具,`src/initialization.cpp` 一手定义
  `s_g = umeyama(gt, in, fix_scale=has_inertial)`(**VISLAM 走 SE3,VSLAM 才走 Sim3**)、
  对称尺度误差 `0.5*(|r-1| + |1/r-1|)`、收敛判据 `init_th = 0.03` / `window_size = 5.0 s`、
  综合分 `E_init = t_init * sqrt(E_scale + 0.01)`。**我们 0.73%–10.80% 正好横跨它的 3% 线。**
- 🏆 **XR-VIO(2025)** 见 §1(b):EuRoC 初始化尺度误差全表 + ZJU-SenseTime ATE(含闭源 SenseSLAM V1.0 = 31.233 mm)。**论文无代码。**
- **《视觉惯性导航系统初始化方法综述》**,国防科技大学学报 2023, 45(2): 15-26:中文一手原话
  「潜在的**运动退化**(例如悬停或匀速运动)风险,也有可能导致初始化结果出现偏差」;
  「**初始化不应只存在于系统初始阶段,而应在系统运行的全阶段持续进行**」。
- **章国锋等《基于单目视觉惯性的 SLAM 方法综述》**,中国图象图形学报 2024, 29(10)
  [doi:10.11834/jig.230863](http://www.cjig.cn/en/article/doi/10.11834/jig.230863/):EuRoC + ZJU-SenseTime + LSFB 三套横评,但**尺度不是主题**。
- **零命中**:知网 kns.cnki.net **检索页连接超时(http=000),本轮未取得任何知网全文**;
  **RD-VIO / 李锦瑜 / 潘晓坤 的中文学位论文零命中**;zjucvg.net TLS 失败;
  openxrlab 中文技术分享零命中;腾讯/OPPO/小米/影石/大疆 手机 VIO 一手工程文**全部零命中**;
  华为 AR Engine 官方页只到「结合图像特征和 IMU 实现 6DoF」,尺度细节零公开;
  中文综述里的 **TUM-VI 横评表:一个都没有**(中文圈只用 EuRoC + ZJU-SenseTime)。

### 4.3 德语
- **零命中**:「Skalendrift」「Maßstabsdrift」「Maßstab Schätzung monokular」「Initialisierung visuell-inertiell」
  在 TIB / OPUS / mediaTUM 上没有对口德语学位论文;**TUM 的相关产出全是英文,不存在德语版**;Bosch / Continental 公开材料零命中。
- 命中:KIT 博士论文 Gräter 2019《Monokulare Visuelle Odometrie auf Multisensorplattformen》
  ([链接](https://publikationen.bibliothek.kit.edu/1000093133)),原文「die Translation nur bis auf einen
  Skalierungsfaktor bestimmt werden kann --- die sogenannte Skale」,三条尺度来源=相机安装高度 / 地面几何 / 低分辨率 LiDAR,
  **全文不用 IMU** ⇒ 德国车厂圈的答案是「引入第二个米制线索」。
- 命中:Fraunhofer《Self-Supervised Deep Learning für visuelle Odometrie und monokulare Tiefenschätzung in
  absolutem Maßstab》—— 用 IMU 当自监督信号把单目深度拉到绝对尺度。
- 🔑 方法学警告:德语查询返回的 `alphaxiv.org/de/…` 全是 arXiv 机器翻译,**不是德语一手文献**,已剔除。

### 4.4 日语
- **判决:日文圈在「VIO 尺度」这一题上是空地,且是结构性的**——日本 SLAM 社区的方法性产出直接用英文投 ICRA/IROS。
- **零命中(逐条实测)**:CiNii 上 `VIO スケール 推定`=0、`慣性 スケール 可観測性`=0、`IMU 事前積分`=0、
  `ARKit ARCore 精度 評価`=0;`視覚慣性オドメトリ` CiNii 共 **4 条**、J-STAGE **1 条**;
  ソニー/PFN/DeNA/リコー/NTT/パナソニック/デンソー **全部零工程博客**。
- 命中:足立/原/中村(法政大+千葉工大)ROBOMECH 2024「単眼 ORB-SLAM3 におけるポーズグラフ最適化での**スケール修正**の調査」
  [doi:10.1299/jsmermd.2024.1A1-P03](https://doi.org/10.1299/jsmermd.2024.1A1-P03) —— 日文圈唯一持续的 scale drift 实测线,但纯单目不碰 IMU。
- 命中:産総研 **L-C\***([新闻稿](https://www.aist.go.jp/aist_j/press_release/pr2023/pr20230529/pr20230529.html),ICRA 2023):
  VIO 只负责补「1 Hz 图像-地图匹配之间」的运动,算力降到前代 1/30;30 Hz 匹配 **3 mm**、1 Hz 匹配 **44 mm**。未开源。
- 命中:東芝レビュー 2023-01「ズームレンズ付き単眼カメラを用いた**絶対スケール**3次元計測技術」—— 多视角相对深度 + 镜头 defocus,
  官方明说**不需要陀螺仪也不需要参照物**。
- 🔑 一致性本身就是结论:**日文圈给出的所有尺度答案都是「外部米制锚」**(3D 地图 / 2D LiDAR / 既有地图 / defocus),
  没有一条是靠改进 IMU 初始化。
- `stella_vslam`(AIST 出身):LICENSE.original / LICENSE.fork 均 **BSD-2 ✅**,但 **README 把 "IMU integration" 仍列在
  *Currently working on*** ⇒ **至今无 IMU 支持,对本题直接出局**;且 <0.3 版本须按 ORB_SLAM2 的 GPL 处理、g2o 的
  `csparse_extension` 是 LGPLv3+ 必须动态链接。

### 4.5 韩语
- **零命中**:「시각 관성 주행계」是直译生造词,零命中(韩国实际用「시각-관성 오도메트리」/ VIO / VINS);
  「관성 항법 초기화」零一手命中;JKROS **2024–2026 年单目 VIO 尺度方向韩文期刊论文零命中**;
  `irapkaist` 与 `rpmsnu` 两个组织账号 **public_repos = 0**(Ayoung Kim 已迁至 SNU,旧仓全部转出);
  LG / 三星本体**没有**手机端单目 VIO 尺度的工程材料。
- 🏆 命中(最值钱):**NAVER LABS VLSDK 开发者文档《VIO의 정확도에 영향을 주는 요소》**
  (<https://ar.naverlabs.com/docs/vlsdk/docs/intro/good-pose/vio/>)—— 手机端 VIO 四条一手工程经验:
  (a) 开场地图未建好时精度差,要求用户慢慢左右环视;
  (b) 「VIO의 정확도는 카메라가 바라보는 장면의 **시각적 특징 밀도**에 크게 의존합니다」(白墙/素地板误差显著变大);
  (c) 🔑 **等速运动杀手**:「**엘리베이터, 에스컬레이터, 무빙워크** 등과 같은 **등속도 운동** 환경에서는 VIO가
  비정상적인 6DOF를 계산하는 경우가 많습니다」——**与 §2 的激励度量论文是同一个机制的两个独立来源**;
  (d) 磁性配件干扰磁力计导致 6DOF 偶发大跳。
- 命中:Samsung R&D Poland 官方博客的**开源+开硬件 VO/SLAM 真值系统**(MIT,Livox Mid-360 + RPi4B,整机 <1 kg,
  与地面激光扫描对比最大垂直偏差 <10 cm、水平 3 cm),其结论原话:「state-of-the-art visual SLAM algorithms are
  **not an out-of-the-box solution for smartphone cameras without IMU**」。
- 命中:`cjunwan/SLIM-init`(IROS 2026,KAIST Hyun Myung 组)—— **GPLv3 ❌**,但数字可用:
  EuRoC 每次初始化 **4.1 ms**、位姿 RMSE **0.110 m**,机制=2D 线特征 + 消失点的 **structureless** 初始化(不三角化),
  正对我们白墙少特征的初始化工况,**可自行重实现**。

### 4.6 法语
- **零命中**:HAL 上 `initialisation inertielle` **0**、`observabilité de l'échelle` **0**、
  `dérive d'échelle` 6 篇但**零篇是 VIO**(全是 GNSS/水文/航电);IGN/LASTIG(MicMac 一系)与 VIO 尺度**完全不相交**;
  **Parrot / Thales / Safran / Navya / Dassault 在 HAL 与公开渠道上零一手技术材料**。
- 🔑 命中(最值钱):Chauchat / Barrau / **Bonnabel**《Two-Frame Groups with Scalings》,IFAC-PapersOnLine 58(6):315-320, 2024,
  [doi:10.1016/j.ifacol.2024.08.300](https://doi.org/10.1016/j.ifacol.2024.08.300) / [HAL hal-04691569](https://hal.science/hal-04691569v1)。
  原文:「we can build a two-frame group (TFG) structure not only using rotations as its basic building block,
  but also **rotations and scalings**… a generalization of the group of **similarity transformations Sim(d)**」。
  = **把未知尺度做成群元素,使误差传播不依赖估计值**。🔴 但它的两个算例是**轮半径未知**与**加速度计标度因数未知**,
  **没有做单目重建尺度** ⇒ 迁移到我们的问题上是自研,不是照抄。
- 命中:Brossard / Bonnabel / Barrau《Invariant Kalman Filtering for Visual Inertial SLAM》FUSION 2018
  ([hal-01588669](https://hal.science/hal-01588669v2)):位姿+速度+p 个路标合成 SE_{2+p}(3) 单个群元素。
  🔴 **摘要里没有 scale 字样,正文被反爬挡住,IEKF 对尺度的量化收益本轮没验到**。
- 命中:Bouazza《Contributions to geometric observer design for visual-inertial navigation》2024
  (Côte d'Azur / I3S,Hamel 组,[tel-04989966](https://theses.hal.science/tel-04989966v1)):
  **显式给出 uniform observability conditions** —— 法语圈唯一直接回答「尺度何时可观」的入口。
- 命中:Caruso 2018(ONERA + Sysnav,[2018SACLS133](https://theses.fr/2018SACLS133))—— 视觉不利时**加磁场这条独立证据轴**,
  与日文圈「外部米制锚」的模式同构。
- **许可裁决(全部开 LICENSE 本体)**:`artivis/kalmanif` **MIT ✅**(README 明写实现**右不变 IEKF + UKFM**,含
  `demo_se_2_3.cpp`)+ 依赖 `artivis/manif` **MIT ✅** ⇒ **唯一许可干净且真有 IEKF 的可抄件**;
  `CAOR-MINES-ParisTech/ukfm` **BSD-3 ✅**(文件名是英式 `LICENCE.md`)🔴 但 `python/examples` 里**没有 VIO 例子**,是滤波库不是 VIO;
  `RossHartley/invariant-ekf` **BSD-3 ✅**;`mbrossar/ai-imu-dr` / `denoise-imu-gyro` **MIT ✅**;
  ⛔ `ov2slam/ov2slam`(ONERA)**GPL-3.0**、⛔ `pvangoor/eqvio`(EqVIO)**GPL-3.0**。
- 🔴 方法学:**HAL 全站(网页与 PDF)被 Anubis 反爬拦截**,三条路全返回拦截页 ⇒ 法语侧**只有摘要级证据,正文数字与消融一个都没取到**。

### 4.7 俄语
- 🔑 **术语陷阱(本轮最重要的方法学发现)**:俄语 «масштабный коэффициент» 几乎永远指
  **陀螺/加速度计的标度因数**,不是单目重建尺度 ⇒ 直译关键词搜不到东西,必须绕道 «наблюдаемость» / «привязка к метрике»。
- **实质零命中**:`наблюдаемость масштаба`、`дрейф масштабного коэффициента`、`инерциальная инициализация масштаба`
  在 CyberLeninka 上命中数虚高(引擎是模糊 OR),**前十条全部不相关**;
  Innopolis 两个 GitHub 组织**无任何 VIO/SLAM 仓**;МФТИ、ИПМ РАН 无单目 VIO 尺度一手材料;
  **Yandex 与 VisionLabs 公开技术材料里零单目 VIO 尺度工程内容**(Yandex 公开口径是 LiDAR + 高精地图配准)。
- 命中:Циоплиакис(ЮУрГУ)《Быстрый блочный фильтр Калмана…》《Гироскопия и навигация》34(1), **2026** —
  O(N) 块卡尔曼、单目、仿真;🔴 **它不讨论尺度可观测性**,而是用**地面先验**绕开
  (原文:特征初始深度假设它在「горизонтальном участке поверхности Земли с высотой z₀」)。
- 命中:Цай / Цзинь / Бобков(МГТУ им. Баумана)《Инженерный вестник Дона》2025 —— 🔴 **是双目不是单目**,KITTI,**无任何尺度数字**。
- **许可裁决**:Skoltech `MobileRoboticsSkoltech` 32 个仓**没有一个是 VIO 估计器**;
  `mrob` **Apache-2.0 ✅**、`map-metrics` **Apache-2.0 ✅**、
  🏆 `twist-n-sync` **Apache-2.0 ✅**([doi:10.3390/s21010068](https://doi.org/10.3390/s21010068),
  陀螺互相关做跨设备时间同步 —— **相机-IMU 时偏是手机 VIO 尺度崩的常见根因,这是一个白捡的排查工具**);
  ⛔ `OpenCamera-Sensors` **GPL-3.0**、⛔ `ORB_SLAM3` fork **GPL-3.0**、⛔ `VIO-feeder` **无 LICENSE**。

### 4.8 跨语种的两条方法学警告(三路 agent 独立撞到)
1. 🔴 **`alphaxiv.org/<lang>/…` 是 arXiv 的机器翻译农场**:德语、韩语、西语、俄语搜索里都返回它,
   **看上去是该语种一手文献,其实是英文 arXiv 的机译** ⇒ 必须剔除,否则会把英文来源重复计成「该语种命中」。
2. 🔴 **多个学术库本轮不可达**:知网 kns.cnki.net 超时、HAL 全站被 Anubis 拦、TDX/TESEO 无返回体、
   cad.zju.edu.cn TLS 被拒、MDPI 403。凡受此影响的结论已在 §7 单列为「未核」。

---

## 5. 学习型 / 混合型前端:逐个核许可 + 消融证据

### 5.1 最要紧的一条消融(2026,对我们是负面消息)
**DL-VINS-Factory**(arXiv [2607.01757](https://arxiv.org/abs/2607.01757),2026-07):在同一个滑窗 Ceres 后端上换前端。
- **EuRoC 单目**:最好的学习前端 ALIKED+LightGlue **0.146 m**,只比经典 **GFTT+LK 0.154 m** 好 **5%**;
  所有配置挤在 0.146–0.176 m,经典基线是单目组第二好。
- 退化场景才有肉:NTU-VIRAL 双目 −12%;Botanic Garden 灰度 SuperPoint+LK −29%;RGB RaCo+LK −38%。
- 作者结论逐字:「Learned front-ends are **viable** for real-time embedded VI-SLAM, but are **not universally
  superior to classical tracking**.」
- 🔴 **算力口径**:29–47 FPS(单目)是在 **Jetson AGX Orin + TensorRT** 上;**不是手机**。
- ⇒ **在我们的良好光照室内工况上,换学习型视觉前端的期望收益约 5%,而算力代价未知。优先级低。**
- 佐证:arXiv [2607.17956](https://arxiv.org/abs/2607.17956)(2026-07)结论「learned flow alone is insufficient:
  the gains arise from **combining learned correspondence proposals with geometric verification** and
  uncertainty-aware weighting」——与我们记忆里「独立置信度门控」的架构模式同源。该论文代码「open-source upon
  acceptance」**尚未发布**,论文本身 CC BY-**NC**-ND。

### 5.2 逐个许可裁决
| 组件 | 类型 | 代码许可 | 权重 | 裁决 |
|---|---|---|---|---|
| **XFeat**(CVPR 2024) | 轻量特征 | **Apache-2.0** | `weights/xfeat.pt` **在仓内** | ✅ 干净,面向 CPU/资源受限 |
| **ALIKED** | 特征 | **BSD-3** | 仓内 | ✅ |
| **LightGlue** | 匹配 | Apache-2.0 | 仓内 | ⚠️ **只能配 DISK/ALIKED/SIFT**;`superpoint.py` 是 Magic Leap 机密头 |
| SuperPoint / SuperGlue | 特征/匹配 | Magic Leap 非商用 | — | ❌ |
| **DPVO / DPV-SLAM** | 学习 VO | **MIT** | — | 🟡 干净但**需要 GPU**,且**纯视觉无米制** |
| **RAFT / SEA-RAFT 系** | 光流 | BSD-3 | — | 🟡 需 GPU |
| **`mbrossar/denoise-imu-gyro`** | 学习型陀螺去噪 | **MIT** | — | ✅ 干净,但只治陀螺,**不给尺度** |
| **TLIO**(Meta) | 学习惯性位移+协方差 | **BSD-3** | 🔴 **无预训练权重**(README:「requires the user to **generate its own dataset and retrain**」);数据集文件名 `golden-new-format-**cc-by-nc**-with-imus-v1.5.zip` | 🟡 代码可用,**权重与数据非商用** ⇒ 要自采自训 |
| **RoNIN** | 学习惯性 | **GPL-3.0** | — | ❌ |
| 🏆 **RNIN-VIO**(zju3dv) | 学习惯性 + 紧耦合进 VIO | **Apache-2.0**(版权属商汤,但是 Apache 授权,含专利许可) | ✅ **预训练权重已发布**;训练数据 = IDOL 20 h(**CC-BY-4.0,商用允许**)+ 自采 7 h(**许可未声明 🟡**) | ✅ **唯一「代码 + 权重都能商用」的学习惯性方案,且出自 RD-VIO 同一实验室** |
| `sair-lab/AirIMU` | 学习 IMU | 🔴 **仓内无 LICENSE 文件** | — | ❌ 保留一切权利 |

### 5.3 RNIN-VIO 为什么对我们特别重要
ISMAR 2021,Danpeng Chen / Nan Wang / Runsen Xu / Weijian Xie / Hujun Bao / **Guofeng Zhang**,ZJU + SenseTime + Tetras.AI
—— 与 RD-VIO 同一个实验室、同一批人、面向**手持 AR 与 AR 眼镜**。
机制:一个只吃 IMU 的 ResNet+LSTM 网络(RNIN)输出**一段时间窗内的 3D 位移及其不确定度**,
再把视觉 / IMU / NIN 三路**紧耦合**进同一个估计器。
⇒ 它提供一条**与视觉完全独立、天生带米的平移约束**,在纯旋转、匀速、白墙这些**视觉与 IMU 都给不出尺度**的工况下
仍然输出米制位移 —— 正是 §4.5 NAVER 说的「电梯/扶梯/自动步道」那一类失效。
🔴 限制:仓里**只发布了惯性网络部分**(README 原文「This code is the inertial neural network of the paper」),
**VIO 紧耦合那一半没有开源**,需要我们自己把它做成滑窗里的一个位移因子。

---

## 6. 判决:一条主线 + 一条次选

### 主线 A —— 把一次性尺度初始化改造成「周期性尺度再精化 + 激励闸」
- **配方(已精确到变量与节拍,出自 Campos 博士论文 §4.3.1 / 图 4.2d)**:
  周期性跑的**不是全 BA**,而是一个只有**两组变量**的轻优化 —— `s ∈ R⁺`(用 `s←s·exp(δs)` 保正)
  与**重力方向的 2 个角** `R_wg ← R_wg·Exp(δα_g, δβ_g, 0)`;**bias 取当前估计值并固定**;
  参与的是**所有已插入关键帧**;节拍 **5 s / 15 s,此后每 10 s**,终止于 >100 关键帧或初始化后 >75 s。
  这和我们 `refine_scale_velocity_via_gravity()` 的结构**高度同构**(它已经是「g 降到 2 DoF 切空间 + 解 s + 解 v」),
  差别只是:我们的版本还解 v、只迭代一次、且只在初始化器里跑一次。
- **抄谁**:机制抄 ORB-SLAM3 TRO 2021 §V-B + Campos 博士论文 §4.3.1(把 s 做成显式变量、只估 s 与重力两参数);
  闸抄 Campos §3.3 的 Hessian 最小奇异值判据(`t_obs=0.1`)与 granite(MIT)的 PCA 风险指标;
  闸抄 granite(**MIT**)的 scale-drift risk = 相对平移信息矩阵 PCA;
  尺子抄 `zju3dv/eval-vislam`(**Apache-2.0**)的对称尺度误差 + 3%/5 s 收敛判据。
  **一行 GPL 代码都不需要碰** —— 线性求解器是我们自己树里的
  `xrslam/src/xrslam/core/initializer.cpp:426 / :467 / :543`。
- **预期收益(引消融数字)**:ORB-SLAM3 自报 2 s 初始化 5% → 5/15 s VI-BA 后 **1%**;
  学位论文表 3.4 更精确:**第一关键帧后 10 秒,三条 EuRoC 序列的尺度误差全部 <1%**
  (对照:ORB-SLAM-VI 需 15 s、VI-DSO 需 **20–30 s** 才到 1%)。其 EuRoC 平均尺度误差 **0.9%**。
  我们当前同场分段 0.73%–10.80% ⇒ 目标是把 10.80% 那种段拉回 1–2%。
  注意这是**尺度**的收益,ATE 的收益无法从这些论文直接推导(口径不同),**不应预支**。
- **工程量**:§3.4 的五步,真实难点只有第 3 步(边缘化先验与新尺度的一致性)。中等偏大,但**全部在我们自己的 Apache-2.0 代码里**。
- **风险**:
  1. 🔴 **尺度跳变**会让 AR 虚拟物体尺寸/位置一跳 —— 必须限幅 + 平滑,且只在闸通过时接受;
  2. 🔴 **边缘化先验不一致**是发散源;最保守的做法是「丢弃并重建先验」(代价:丢掉历史信息,短时精度下降),
     激进做法是实现 DM-VIO 的 delayed marginalization(**无宽松实现可抄,纯自研**);
  3. 我们自己的 `refine_scale_velocity_via_gravity()` 只迭代 1 次(`for (iter = 0; iter < 1; ++iter)`)且 `damp = 0.1`
     —— 这两个常数是为「一次性初始化」调的,搬到周期性场景需要重调。

### 次选 B —— 接 RNIN-VIO 的神经惯性位移因子(**Apache-2.0 + 权重齐全**)
- **抄谁**:`zju3dv/rnin-vio`(Apache-2.0,含预训练权重);训练数据 IDOL CC-BY-4.0。
- **预期收益**:在视觉退化(白墙、纯旋转、匀速)时提供独立米制平移约束 —— 即 §4.5 NAVER 和 §2 激励度量论文
  **两条独立来源**共同指认的失效工况。🔴 **我未能取到 RNIN-VIO 的消融数字**(cad.zju.edu.cn 连接被拒,IEEE Xplore 需订阅)
  ⇒ **收益量级目前是未核项,不能写成数字**。
- **工程量**:大。仓里只有网络,紧耦合那一半要自己写;还要把 PyTorch 模型搬到手机端推理。
- **风险**:
  1. 🔴 **训练分布错配**:RNIN 的数据是「五个人走路、跑步、上下楼、随机晃」的**行人手持**运动;
     我们的主要用户是**近距离绕着小物体拍**。这与我们记忆里 MonoSDF 的教训同构
     ——先验若不在我们的分布上,可能把歧义换个名字重新引进来。**上线前必须先量它在我们自采数据上的位移误差。**
  2. 自采 7 h 数据的许可未声明(权重是用它训的)⇒ 若要重训需先澄清;若直接用发布的权重,靠的是仓的 Apache-2.0 授权。
  3. 手机端算力与功耗。

### 明确不推荐
- ❌ **整体换引擎**:OKVIS2(BSD-3)我们已实测差 2×;granite(MIT)明文不支持 mono-inertial;
  basalt(BSD-3)是 stereo-inertial;Kimera-VIO(BSD-2)是双目;stella_vslam(BSD-2)无 IMU;
  MSCEqF(Apache-2.0)要换成滤波后端。**「没有能显著超过 RD-VIO 的可商用方案」在这一轮是成立的答案。**
- ❌ **换学习型视觉前端**:EuRoC 单目只值 5%(DL-VINS-Factory 2026),且需 Orin 级算力。
- ❌ **DUSt3R 族前馈 3D 初始化**(FF-VIO-Init 路线):许可整族关闭,且该仓代码未发布、无 LICENSE。

---

## 7. 风险与未核(明说)

1. 🔴 **本轮没有任何实测**,所有收益都是引用他人论文的数字;口径差异已逐条标注,但**跨数据集的数不能当作我们的预期值**。
2. 🔴 **知网(kns.cnki.net)本轮连接超时**,中文学位论文这一路**没有真正打开过**;
   「RD-VIO 的中文学位论文」是否存在**仍未证实**(网面零命中 ≠ 不存在)。
3. 🔴 **RNIN-VIO 的消融数字未取到**(cad.zju.edu.cn TLS 被拒;IEEE Xplore 需订阅)⇒ 次选 B 的收益是空的。
4. 🔴 **LaMAria(ICCV 2025)leaderboard 的 "score / R@5m" 未定义是否等价 ATE**,故未入表。
5. 🔴 **MDPI Drones 2026 的 GTSAM 单目 VIO 论文返回 403**,未核。
6. 🟡 RNIN-VIO 的**预训练权重托管在 Google Drive / 百度网盘**,权重本身没有独立的许可声明;
   我们依赖的是仓库 LICENSE 的 Apache-2.0 覆盖。若要出货,建议向作者要一份书面确认。
7. 🟡 DL-VINS-Factory 自称 CC0,**本轮未打开其仓库 LICENSE 文件本体核实**。
8. ⚠️ §1 的纠正依据的是**本机 `~/Developer/xrslam` 的源码**;若箱上/出货分支与本机树不一致,行号需重取。
9. 🔴 **HAL 全站(网页与 PDF)被 Anubis 反爬拦截** ⇒ 法语侧只有摘要级证据,
   **IEKF / 不变滤波对尺度的量化收益本轮完全没验到**(M6 的收益是空的)。
10. 🔴 **TDX(tesisenred.net)与 TESEO 未能真正检索到**(只拿到入口页)⇒ 西语博士论文库这一路「搜过了」不成立。
11. 🟡 **UMA-VI 数据集**(低纹理+动态光照,与我们白墙工况同型)的许可**本轮未核**。
12. 🟡 Campos 博士论文的页码与章节号来自子 agent 的转述,**我本人未逐页复核 PDF**;
    引用前建议对 `TESIS-2022-050.pdf` 的 p.25 / p.34 / p.35 / p.36 / p.44 与表 3.1 / 表 3.4 做一次逐字核对。

---

## 附录:语种覆盖清单

英文(基底)· 西班牙语 · 法语 · 俄语 · 中文 · 德语 · 日语 · 韩语 —— 共 8 种,全部完成,
每种的「查了什么 / 命中什么 / 零命中」见 §4.1–§4.7。

---

# 附录:重力与尺度的持续估计(2026-09-23 第二轮 · 零实测)

**范围**:只回答「**初始化之后要不要继续估重力方向 / 要不要周期性重优化尺度**」。
方法:12 个实现**逐仓打开源码**核「重力方向是不是常量」;许可一律以**源码文件头本体**为准;
每个数字标口径(数据集 / 单目双目 / 对齐方式 / 因果性)。本轮**没有任何实测**。

## A.0 判决(一句话)

**重力方向:固定是压倒性主流(12 个实现里 10 个把它写成编译期常量或初始化后烘进世界系),
而且这不是偷懒 —— Basalt 在自己的运行时自检里逐字写着「for VIO only yaw rotation shift is in nullspace」,
即重力的 roll/pitch 是**可观**的,一次对齐就把这 2 个自由度折进了世界系的定义。
但「可观」有前提(旋转轴要持续变化),手持近距离拍小物体正好不满足 ⇒ 残余 `ba` 与重力方向会互相冒充。
真正值得抄的不是「加一个重力变量」,而是 **ICE-BA(CVPR 2018,Apache-2.0,与 RD-VIO 同一实验室)
把重力方向表示成「相对参考关键帧的 2 自由度活变量并常驻在边缘化先验里」** —— 这一个设计同时把
「改了重力/尺度之后旧先验怎么办」那道坎从根上绕开。
尺度:紧耦合单目这一侧,「周期性重优化」的全部先例 = ORB-SLAM3 / VI-DSO / DM-VIO(全 GPL-3.0)
+ 一篇**无代码但 CC BY 4.0** 的 Hong & Lim (Sensors 2018);宽松许可的真实现只在**松耦合滤波**一侧(ssf/msf)。
⇒ **建议:做「重力方向的相对参数化 + 边缘化先验相对化」这一半(有干净出处、有干净实现可抄),
不要现在做「周期性整窗尺度重缩放」那一半(没有许可干净的紧耦合先例,且它的发表收益在我们这类场景上是空的 —— 见 A.3.4)。**

---

## A.1 逐实现:重力方向是固定还是继续估(全部本轮实读源码)

| 系统 | 口径 | 文件:行(实读) | 重力方向 | 许可(**文件头本体**) |
|---|---|---|---|---|
| **XRSLAM(我们)** | 2024 TVCG,单目 | `estimation/ceres/preintegration_factor.h:22` `static const vector<3> gravity = {0,0,-XRSLAM_GRAVITY_NOMINAL}`;`common.h:41` `#define XRSLAM_GRAVITY_NOMINAL 9.80665`;另见 `preintegrator.cpp:129`、`core/detail.cpp:20` | **编译期常量,固定** | Apache-2.0 ✅ |
| **VINS-Mono** | 2018 T-RO,单目 | `parameters.cpp:11` `Eigen::Vector3d G{0.0,0.0,9.8}`(`:74` 只从 yaml 读 `g_norm` 改**模**);`factor/integration_base.h:180,182` 残差用的就是这个全局 `G`;`estimator.cpp:369` 初始化解 `g`,`:424-427` `R0=g2R(g); g=R0*g` 只用来**转世界系** | **初始化解一次,之后固定** | GPL-3.0 ⚰️(🔴 文件名是 **`LICENCE`** 英式拼写,见 A.6) |
| **VINS-Fusion** | 2019,单/双目 | `estimator/parameters.cpp:20` 同一行常量;`factor/integration_base.h:189,191` 同一残差 | **固定** | GPL-3.0 ⚰️ |
| **OpenVINS** | 2020 ICRA,MSCKF | `ov_msckf/src/state/Propagator.h:57` `_gravity << 0.0, 0.0, gravity_mag;`(成员 `:442`);`state/State.h` 状态清单里**零重力变量**;`ov_init/.../DynamicInitializer.cpp:227` 初始化状态序 `[features, velocity, gravity]`,`:551-557` `gram_schmidt(gravity_inI0, R_GtoI0)` 之后改用常量 | **初始化估,之后固定** | GPL-3.0 ⚰️ |
| **ORB-SLAM3** | 2021 T-RO,单目惯性 | `G2oTypes.h:274` `class VertexGDir : public g2o::BaseVertex<**2**,GDirection>`(类型层面就是 2 自由度);`Optimizer.cc:3434-3440` `VertexGDir(Rwg)->setFixed(false)` + `VertexScale->setFixed(false)`(ScaleRefinement 用的那支,同时 `:3414-3429` 把 VP/VV/VG/VA 全 `setFixed(true)`);`:3117-3123`(InitializeIMU 那支);`:3291-3297` 第三支 `VGDir->setFixed(true)` 注释「scale is obtained from already well initialized map」;🔑 **`LocalInertialBA`(:2383)/`FullInertialBA`(:392)/`PoseInertialOptimization*`(:4491,:4875) 里 `VertexGDir` 零出现** | **有限时窗内重估,窗口关闭后固定**(`LocalMapping.cc:1477-1478` `ApplyScaledRotation` 把重力烘进世界系) | GPL-3.0 ⚰️ |
| **Basalt** | 2020 RA-L,双目惯性 | `include/basalt/utils/imu_types.h:62` `static const Eigen::Vector3d g(0, 0, -9.81);`;`vi_estimator/sqrt_keypoint_vio.h:225` `const Vec3 g;`(`sqrt_keypoint_vio.cpp:65` 构造时赋值,**`const` 成员**) | **编译期常量,固定** | BSD-3(文件头) ✅ |
| **granite** | 2021 IROS,basalt 派生 | `include/granite/vi_estimator/keypoint_vio.h:210` `const Eigen::Vector3d g;` | **固定**;且 `doc/VioMapping.md:55-56` 明文「Monocular-inertial setups can not be handled」 | MIT(文件头)+ 原 BSD-3 ✅ |
| **OKVIS2** | 2024,双目惯性 | `okvis_ceres/src/ImuError.cpp:746 / 885 / 1065` `const Eigen::Vector3d g_W = imuParams.g * Eigen::Vector3d(0,0,6371009).normalized();`(每次求残差现算的常量);config 里只有**模** `g: 9.81007` | **固定**(只有模可配,方向硬编码世界 z) | BSD-3(文件头) ✅ |
| **Kimera-VIO** | 2020 ICRA,双目/RGBD/单目 | `include/kimera-vio/imu-frontend/ImuFrontendParams.h:61` `gtsam::Vector3 n_gravity_`;`src/imu-frontend/ImuFrontend.cpp:71,95,228` 传进 GTSAM `PreintegrationParams`(= 预积分的**固定参数**);`initial/OnlineGravityAlignment.h` 文件头自述抄 Qin & Shen IROS 2017,**是初始化模块**,全文件 `scale` 零命中 | **只在初始化对齐,之后固定** | 🔴 **不是干净的 BSD-2**,见 A.6 |
| **maplab** | 2018 RA-L / 2023 v2 | `common/maplab-common/include/maplab-common/gravity-provider.h` 整个类只产出 `getGravityMagnitude()`(按纬度/海拔算**模**,默认苏黎世);`algorithms/ceres-error-terms/include/ceres-error-terms/inertial-error-term.h:93` 构造参数是 `double gravity_magnitude` | **固定**(方向=世界 z,连变量都不存在) | Apache-2.0 ✅(🟡 打开的源文件无文件头,逐文件未核) |
| **SVO-Pro** | 2021,单/双目惯性 | `svo_ceres_backend/src/imu_error.cpp:500` `g_W = imu_params.g * Eigen::Vector3d(0,0,1.0)`;`:603` `g_W = Eigen::Vector3d(0,0,imu_parameters_.g)` | **固定** | 仓根 GPL-3.0 ⚰️(该文件头本体是 OKVIS 的 BSD-3 ⇒ **混合许可仓**) |
| 🏆 **ICE-BA** | **CVPR 2018**,双目惯性 | `Backend/Geometry/IMU.h:1084-1091` 计算 `J->m_JvgT / m_JpgT` = **IMU 残差对重力方向的解析雅可比**(`g1 = C1.m_T.GetColumn2()`);`Backend/Geometry/CameraPrior.h:869` `LA::Vector2f m_er;`(**2 维**旋转误差)+ `:1273 m_Arr.Set(arr, 0.0f, arr)`(2×2 信息块);`Backend/IBA/Parameter.cpp:120-124` 三个重力先验方差 `FIRST=(10°)² / NEW=0 / RESET=(1°)²`;`Backend/Utility/Utility.h:253-255` `Inverse(v,s,eps){return v==0?0:max(s/v,eps);}` ⇒ **方差 0 = 信息 0 = 自由**;`LocalBundleAdjustor.cpp:2430-2433` 每次边缘化把先验重锚到新参考关键帧 | 🔑 **一直估**:重力方向是**相对参考关键帧的 2 自由度活变量**,常驻滑窗先验 | **Apache-2.0 ✅**(根 LICENSE + `Backend/IBA/IBA.cpp` 文件头逐字 Apache-2.0) |
| ssf / msf(旁证) | 松耦合 EKF | `ssf_core/.../state.h:63` `double L_; ///< visual scale`、`:63-66` `q_wv_; ///< vision-world attitude drift`;`SSF_Core.cpp:548` `delaystate.L_ = delaystate.L_ + correction_(15);`;msf `pose_measurement.h:273` 注释逐字「fix vision world yaw drift **because unobservable otherwise** (see PhD Thesis)」,`:317-321` 用一条伪测量把 `q_wv` 的 **yaw** 钉住(`R_(6,6)=1e-6`),**roll/pitch 留自由** | **尺度与重力方向都一直估**(但架构是松耦合) | ssf BSD-3 / msf Apache-2.0 ✅(🔴 两仓**都没有根 LICENSE 文件**,只有文件头) |

**计票(主表 12 行):固定 10 · 持续估 1(ICE-BA,紧耦合)· 有限时窗内重估 1(ORB-SLAM3)。
表外旁证:ssf / msf 持续估,但架构是松耦合。⇒ 固定是压倒性主流。**

**全树复核(补做)**:VINS-Mono / VINS-Fusion / OpenVINS / ORB-SLAM3 这四个仓上面只读了选定文件,
事后拿到完整克隆又做了一次**全树 grep**,结论不变,并且收紧了两处:
- **ORB-SLAM3 全树 `VertexGDir` 只有 3 个实例化点**(`Optimizer.cc:3117 / 3291 / 3434`),
  全在三支 `InertialOptimization` 里 ⇒ `LocalInertialBA` / `FullInertialBA` / `PoseInertialOptimization*`
  确实一个重力顶点都没有,**「窗口关闭后固定」是全树结论不是抽样结论**。
- **OpenVINS 全树 `gravity` 的每一处**都落在 ①config 的模 ②文档 ③`ov_init/`(初始化)三类里,
  估计器状态里没有任何重力变量。

---

## A.2 为什么固定是主流:理论依据

### A.2.1 不可观的是 4 个方向,重力的 roll/pitch 不在其中

- 🔑 **源码级、可执行、能失败的证据**(最硬的一条):Basalt `src/vi_estimator/sqrt_ba_base.cpp:59-65` 的
  `checkNullspace()` 注释逐字:
  > "We construct increments that we know should lie in the null-space of the prior … shift global
  > translations (x,y,z separately), or global rotations (r,p,y separately); **for VIO only yaw rotation
  > shift is in nullspace**. … If they increase over time, we accumulate spurious information on
  > unobservable degrees of freedom."
  这不是论文里的一句话,而是**每帧都跑的运行时自检**:VIO 的零空间 = 3 个全局平移 + yaw,
  **roll/pitch(= 重力方向)被排除在外 ⇒ 可观**。(VO 才额外含 roll/pitch。)
- 🔑 **第二条源码级证据,且正好在 FEJ 文档里**:OpenVINS `docs/fej.dox:177`(作者是 Huang 组,即写
  可观测性文献的那批人)逐字:
  > "where 𝒩 should be **4dof** corresponding to **global rotation about the gravity (yaw) and global
  > translation** of our visual-inertial systems."
  与 Basalt 那条互为独立来源,而且它说的正是**先验零空间**——即 A.4 那道坎的同一个对象。
- **论文侧最早取到全文的一手**:Hesch, Kottas, Bowman, Roumeliotis, *Towards Consistent Vision-aided
  Inertial Navigation*, WAFR 2012(Springer STAR 86:559-574,[doi:10.1007/978-3-642-36279-8_34](https://doi.org/10.1007/978-3-642-36279-8_34))§2:
  > "the VINS model has four unobservable degrees of freedom, corresponding to three-d.o.f. global
  > translations and one-d.o.f. global rotation about the gravity vector."
  ⚠️ 同一段自称 "we leverage the key result of the **existing** VINS observability analysis" ⇒ **它不是首证**。
- **现代逐字**:Yang, Geneva, Huang, *Online Self-Calibration for VINS*, **T-RO 2023**,
  [arXiv:2201.09170](https://arxiv.org/abs/2201.09170) 摘要:
  > "VINS with full sensor calibration has four unobservable directions, corresponding to the system's
  > global yaw and translation, while all sensor calibration parameters are observable given fully-excited 6-axis motion."
- 🔴 **归属线互相不一致(这是本轮的真发现,不是含糊)**:Huang ICRA 2019 综述把「4 个」归给 Hesch 等人 IJRR 2014;
  Zhang & Scaramuzza IROS 2018 §III-A 把同一结论归给 **Kelly & Sukhatme IJRR 2011**;
  2026 年的 `arXiv:2606.19307` 又引 Hesch 等人 T-RO 30(1)。⇒ **引用时必须带上自己实际读过的那一篇,不要转述归属。**
- **ICE-BA 自己也这么写**(CVPR 2018 §3.1,本轮从 PDF 抽取的逐字):
  > "The absolute position and yaw around the gravity are unobservable in VI-SLAM [14]. A prior is imposed on the camera C0"
- **VINS-Mono 作者的自述**(Qin/Li/Shen, T-RO 2018, [arXiv:1708.03852](https://arxiv.org/abs/1708.03852) §VIII):
  > "Since our visual-inertial setup renders roll and pitch angles **fully observable**, the accumulated
  > drift only occurs in four degrees-of-freedom … To this end, we **ignore estimating the drift-free roll and pitch states**."
  ⇒ **「固定重力」是一个有明确理由的设计决定,不是疏漏。**

### A.2.2 但「可观」有前提,而我们的工况正好踩在前提外

- **ba 与重力耦合**(Campos et al., ICRA 2020, [arXiv:2003.05766](https://arxiv.org/abs/2003.05766) §III):
  > "**gravity and accelerometer bias tends to be coupled, being difficult to distinguish in most cases**."
- **可观的条件**(Nemiroff/Chen/Lopez, [arXiv:2303.03505](https://arxiv.org/abs/2303.03505) §I):
  > "a nonzero angular velocity which **changes axis of rotation** at some point is required";
  > "the bias and gravity estimates may **not converge for a significant time** after robot initialization,
  > and **if drift occurs the new values may not be immediately observable**."
- **退化运动的逐字**(Wu & Roumeliotis, *Unobservable Directions of VINS Under Special Motions*,
  UMN MARS Lab **TR-2016-002**,2016,**技术报告非期刊**):
  - 无旋转(Thm 2):「one cannot distinguish the direction of the local gravitational acceleration from that
    of the accelerometer bias … **the roll and pitch angles become ambiguous**」⇒ 不可观方向从「3 平移+yaw」
    膨胀成「3 平移 + **全 3 自由度姿态**」。
  - 常加速度(Thm 1):加速度不变时,真实加速度的**模**与 `ba` 不可分 ⇒ **尺度不可观**。
  - ⚠️ 这份 TR **只覆盖「常加速度」与「无旋转」**;**纯旋转下重力方向是否可观,本轮零命中**。
- ⇒ **结论**:roll/pitch 原则上可观 ⇒ 对齐一次够;**但可观性依赖旋转轴持续变化**。
  「手持、近距离、绕着一个小物体缓慢移动」正是旋转轴变化慢、加速度接近常量的工况,
  与 §4.5 NAVER 的「电梯/扶梯/自动步道」和 §2 激励度量论文是**同一族失效**。

### A.2.3 「固定 vs 继续估」的量化对照:VIO 侧零命中,只有一条 LiDAR 惯性的受控实验

- **DM-VIO:零命中。** 摘要确有「we continue to optimize scale and gravity direction in the main system
  after IMU initialization is complete」,但补充材料的消融只有 IMU 初始化器三档与动态光度权重,
  **没有任何一档单独关掉「继续估重力」**;其基线 1 还明写 "Note that the scale is still optimized in the
  main system after initialization"。它给的理由是**收敛快**不是**防漂移**:"convergence is improved when
  optimizing them explicitly instead"。并且它也只估 2 自由度:"As yaw is not observable using an IMU,
  we fix the last coordinate of R_VI"。
- **VI-DSO:零命中。**(🔴 正确编号 [arXiv:1804.05625](https://arxiv.org/abs/1804.05625),ICRA 2018)
  Table I 是跨方法比较,无重力消融;动机句 "in order to deal with cases where the **scale** is not
  immediately observable" ⇒ 冲的是尺度,不是重力漂移。
- **唯一的受控对照在 LiDAR-惯性,不是 VIO**:*Does Online Gravity Estimation Matter?*,
  [arXiv:2609.13675](https://arxiv.org/abs/2609.13675)(v3,2026-09-22,**预印本,未见期刊/会议**)。
  FAST-LIO2 / 12 条序列:固定重力 vs 在线估重力,**RMSEz 中位 +0.9%、ATE 中位 −0.1%,90% 置信区间在 ±2% 内**;
  绝对差中位 **0.017 m / 0.014 m**;固定重力省下的算力 "attributable saving was **0.06%**"。
  §IV-E 直接量到耦合:"The paired intervention shifts b_a by **0.342 m/s²** while preserving g − Rb_a
  within 2.0×10⁻⁷ m/s²"(= 两个配置把同一个物理量在 `ba` 与 `g` 之间重新分配,轨迹几乎不动)。
  作者结论仍是 "We recommend keeping both g and b_a online by default"(理由是传感器断连/动态启动这类非稳态)。
  🔴 **口径**:LiDAR 提供持续的米制几何修正,VIO 没有;该文**明确不主张外推到 VIO**。**不能当作我们的预期值。**
- 🔴 **手机/AR 上「X 分钟后重力对齐偏了 Y 度」这种数:本轮零命中。** 三个最接近的都不是这个量(见 A.7)。

---

## A.3 周期性尺度重优化:非 ORB 系有没有人做过

### A.3.1 命中清单

| 来源 | 机制(逐字/源码) | 数字与口径 | 许可 |
|---|---|---|---|
| **Hong & Lim, Sensors 2018, 18(12):4287**,[doi:10.3390/s18124287](https://doi.org/10.3390/s18124287) 🎯 | §4.3 把 local scale `e^{s'}` 放进滑窗 BA:"**When a new keyframe is added … perform joint optimization including the local scale s′ variable**";"**the optimized local scale is marginalized to prior information along with the poses of the old keyframes**" | EuRoC 11 序列,**单目**,位置 RMSE,**SE(3) 对齐(不吸收尺度)**,因果。MH01–05 = 0.14/0.13/0.20/0.22/0.20 m;V1 = 0.05/0.07/0.16;V2 = 0.04/0.11/0.17 | ✅ **无代码发布**;论文 **CC BY 4.0** ⇒ 可照论文自实现,不碰任何 GPL |
| `ethz-asl/ethzasl_sensor_fusion` (SSF) | `ssf_core/.../state.h:63` `double L_; ///< visual scale`;`SSF_Core.cpp:548` `delaystate.L_ = delaystate.L_ + correction_(15);` ⇒ **每次量测都吃一次 EKF 修正** | 松耦合(吃尺度自由的 VSLAM 位姿);**发表数字未取到** | ✅ **BSD-3**(文件头;**无根 LICENSE**) |
| `ethz-asl/ethzasl_msf`(后继) | `msf_statedef.hpp` `L, msf_core::Auxiliary ///< Visual scale.`;`pose_measurement.h:206` `scalefix` 冻结开关 | 同上 | ✅ **Apache-2.0**(文件头;**无根 LICENSE**) |
| Spaenlehauer & Frémont,[arXiv:1707.07518](https://arxiv.org/abs/1707.07518) | λ 逐帧 KF 递推 | 🔴 **数字很差**:eλ 最高 208.66,RMSE 最高 216 m | 无代码;前端 ORB-SLAM ⚰️ |

### A.3.2 反面(全是一次性初始化)

- **VINS-Mono/Fusion**:`estimator.cpp:399` `double s = (x.tail<1>())(0);` 是 `visualInitialAlign()` 里的
  **局部变量,用完即弃**;唯一的「重来」是 `failureDetection() → clearState()` **全量重启**(`:193-197`,
  打印 `"system reboot!"`)。**没有中间档。** 派生工作加周期性尺度重优化:**零命中(英文 5 轮 + 中文 1 轮)**。
- **OpenVINS `ov_init`**:`DynamicInitializer` 恢复 rotation/velocity/|g|/features,**状态里无 scale**;
  失败可重跑,但不是「周期性重优化」。
- **Basalt / OKVIS2 全仓 grep `scale` 零命中**;maplab 的 `MissionBaseFrame` 只有 SE(3)+6×6 协方差。
- 🔑 **ICE-BA 有一个带 `m_s` 的 `Similarity3D`,但是死代码**(全仓只在自身定义文件出现一次)——
  本轮唯一一个「看起来像 Sim3 尺度状态、实际没接上」的假阳性。
- 🔑 **SVO-Pro 有一个尺度健康度监视器(非状态)**:`frame_handler_base.cpp:298`
  `const double scale_change = opt_dist_first_two_kfs / svo_dist_first_two_kfs - 1.0;`,
  阈值 `backend_scale_stable_thresh = 0.02`。**这是全部普查里最接近「周期性查尺度」的非 ORB 机制,
  但它只算一个比值做闸门,不重解尺度、不进状态。** 它恰好证明:同行想到了要盯尺度,没人把它做成可重优化的变量。
- **2024–2026 的方向是相反的**:XR-VIO(4–5 关键帧)、DRT 解耦、SLIM-init 线特征、FF-VIO-Init 前馈 3D、
  `2511.18910` 闭式解 —— 全押在「把一次性初始化做得更快更稳」,**没人跟进「初始化后继续重解尺度」**。

### A.3.3 为什么紧耦合 MSCKF 结构上不需要显式 scale(有出处)

Delaune et al., RA-L 2021,[arXiv:2103.15215](https://arxiv.org/abs/2103.15215) §IV-B2:尺度在滤波系里
**不是状态变量,而是状态空间里的一个方向** —— 可观测性矩阵右零空间的向量
`N_s = [pᵀ vᵀ 0₆ᵀ … p_Fᵀ]ᵀ`,横跨位置/速度/特征位置。摘要:"scale is no longer in the right nullspace
of the observability matrix for zero or constant acceleration motion"。
⇒ **分界线不是滤波 vs 优化,而是「视觉后端有没有自己的尺度规范自由度」**:
紧耦合(特征与 IMU 位姿同在一个米制系)⇒ 没有 s;视觉后端尺度自由(DSO / 松耦合 VSLAM 位姿)⇒ 必须显式 s。
**我们是紧耦合,所以 XRSLAM 里 grep 不到 `scale` 是这一族的常态**(与正文 §1 的纠正一致)。
🔴 陷阱:在 OpenVINS 里 grep `scale` 命中的是 `_calib_imu_dw/_da` 的 "scale imperfection" = **IMU 标度因子**,与度量尺度无关。

### A.3.4 综述那句话指向的是谁(已定位)

《视觉惯性导航系统初始化方法综述》国防科技大学学报 2023, 45(2):15-26,[doi:10.11887/j.cn.202302002](https://doi.org/10.11887/j.cn.202302002)
§7「VINS 初始化未来发展趋势」第 3 点原文:
> 「……初始化不应只存在于系统初始阶段,而应在系统运行的全阶段持续进行……**文献[59-61]所提出的视觉惯性系统,
> 均在系统运行的全过程中加入类似初始化的模块,对系统尺度信息进行持续更新。然而,需要注意的是,持续初始化在
> 提升状态估计精度的同时,不可避免地会带来时间开销的增长。**」

逐条取出:**[59] = VI-DSO、[60] = Hong & Lim (Sensors 2018)、[61] = DM-VIO**。
⇒ **综述给的三条里只有一条落在 ORB/DSO 两族之外,而那一条没有代码。这就是全部。**
并且 **Hong & Lim 全网仅被引 22 次,逐条看过,无一篇继承其 local-scale 机制** ⇒ 这条机制在文献里是**断头路**。

🔴 **一个必须记住的口径警告**:2024–2026 那些论文的 scale error 是「几个关键帧的短窗一次性」值,
与 ORB-SLAM3 的「15 s 后 <1%」**完全不可比** —— 同一张 XR-VIO Table 2 里,ORB-SLAM3 的 inertial-only
在 4KF 窗口下是 **48.84%**。Merrill(RSS 2023,OpenVINS 组)自己写明:
> "We measure the full orientation error and scale error **over the whole trajectory** rather than just the
> gravity and scale error over well-excited trajectory segments, and thus **can not directly compare**."

---

## A.4 那道坎:改了 s / R_wg 之后,边缘化先验怎么办

### A.4.1 解法清单

| # | 机制 | 一手出处 | 发表代价(口径) | 许可 |
|---|---|---|---|---|
| 1 | **Delayed marginalization + readvance** | DM-VIO §III-D/E/F,[arXiv:2201.04114](https://arxiv.org/abs/2201.04114) | 常驻开销 **0.44 ms/KF = 关键帧总耗时的 0.8%**;每次 marg. replacement **21.02 ms**(readvance 19.87);触发阈值 `threshScale = 1.02`(**尺度变 2% 就重建一次**);新先验保留 ≥ `d−Nf+1 = 93` 个 IMU 因子,丢失 >`θ_lost=50%` 则禁用该次替换 | ⚰️ 代码 GPL-3.0(`GravityInitializer.cpp` 文件头);**机制是公开方法学,可自实现** |
| 2 | **Dynamic marginalization**(三份先验轮换) | VI-DSO §III-F.3,[arXiv:1804.05625](https://arxiv.org/abs/1804.05625) | EuRoC avg RMSE **0.089 m / 尺度误差 0.7%**;DM-VIO 评它 "loses most prior inertial information when the scale changes quickly" | 🟡 代码未公开(未核) |
| 3 | **FEJ / OC-EKF** | Huang/Mourikis/Roumeliotis TR-2008-0001 | 🔴 **结构上不够用**:FEJ 干的正是「把老线性化点钉死」,而相似变换恰恰让那个点变错 | ✅ 纯方法学 |
| 4 | **丢弃并重建先验** | VINS-Mono `estimator.cpp:193-199` `clearState()` | **无人量化**(A.4.3) | ⚰️ |
| 5 | **不边缘化,改固定旧状态** | ORB-SLAM3 `Optimizer.cc:2436` `lFixedKeyFrames` | 无先验 ⇒ 零代价,代价转移到窗口边界的固定偏差 | ⚰️ |
| 6 | **先验 → 可重线性化的非线性因子(NFR)** | Basalt-mapping [arXiv:1904.06504](https://arxiv.org/abs/1904.06504) §V-B;Mazuran NFR IJRR 2016;Hsiung IROS 2018 | Hsiung Table I(EuRoC ATE m):Proposed 0.059/0.060/0.099/0.238/0.187 vs 自家稠密线性先验基线 0.182/0.144/0.278/0.310/0.401 ⚠️ **基线是他们自己重实现的 OKVIS,官方 OKVIS 在 MH01 上是 0.160 优于 0.182 ⇒ 增益有基线偏弱风险** | ✅ **Basalt BSD-3**(`nfr_mapper.cpp` 文件头核过) |
| 7 | **先验换成二元相对位姿边 + 可「复活」** | OKVIS2 [arXiv:2202.09199](https://arxiv.org/abs/2202.09199) §V-D/E | 未单变量消融 | ✅ **BSD-3** |
| 8 | **完整因子图 + fluid relinearization** | GTSAM `ISAM2.h` @brief;`ISAM2Params.h` `relinearizeThreshold=0.1 / relinearizeSkip=10` | 只在**全平滑**下成立 | ✅ BSD-3 |
| 🏆 9 | **相对边缘化(把先验表达在参考关键帧下)** | **ICE-BA CVPR 2018 §5**(逐字):"the relative representation is more complicated for VI-SLAM since **the gravity direction becomes observable**. … We can represent the global pose T_i and **the gravity direction in reference of frame i's closest keyframe k0** as follows: k0T_i = T_i T_k0⁻¹ and **g_k0 = R_k0 g**";§1:"Previous methods **either skip marginalization [26], or apply marginalization without resolving the [conflict] [28]**" | **ICE-BA Table 1(整个 EuRoC,双目,平移 RMSE,对齐不调尺度,i7@3.6GHz,滑窗 50 帧)**:Proposed **0.1208 m** / w/o rel.marg. **0.1797 m**(**去掉它错误涨 48.7%**)/ w/o I-PCG 0.1521 / **w/o 固定线性化点 0.1180 m 但 LBA 10.3 ms、GBA 103.94 ms(对照 2.45 / 12.90 ms)** | **Apache-2.0 ✅** |

### A.4.2 最重要的一条:第 9 行把问题的形状换了

ICE-BA 的做法不是「改完尺度/重力后去修先验」,而是**先验一开始就不表达在全局系里**:
位姿存 `k0T_i`(相对最近关键帧),重力存 `g_k0 = R_k0 g`(相对同一个关键帧),
所以**任何全局相似变换(回环、尺度重缩放、重力重对齐)都不会让先验的线性化点失效** —— 它压根不在全局系里。
**OKVIS2 是同一族的独立实现**:仓里**根本没有 `MarginalizationError.cpp`**(OKVIS1 有),
整体换成 `TwoPoseGraphError`,`TwoPoseGraphError.hpp:198` 存的是 `linearisationPoint_T_S0S1_`(**相对**位姿),
并提供 `convertToReprojectionErrors()` 把边缘化**反解回**路标+观测(与 DM-VIO 的 readvance 同族)。
⇒ **两个独立的、许可干净的实现(Apache-2.0 / BSD-3)指向同一个架构答案。**

### A.4.3 「丢弃重建先验」的代价:**没有人直接量化过**(零命中)

三轮不同关键词检索未找到任何「丢弃先验 vs 保留先验」的单变量消融。两个**间接**数:
1. VI-DSO 0.089 → DM-VIO 0.069 avg RMSE(−22.5%)、尺度误差 0.7%→0.6%(DM-VIO Table I,EuRoC,同作者同底座)
   = 「尺度变了就重置先验」vs「尺度变了就用新线性化点重建先验」。🔴 **不是单变量**(DM-VIO 同时换了 PGBA、粗初始化、动态光度权重)。
2. 工业实做上最保守那条就是**全重启**(VINS-Mono `clearState()`),没有中间档。

🔴 **「对先验因子本身施加同一相似变换」的闭式推导:三轮独立检索零命中。**
坐标变换那半是平凡的(`H′ = A⁻ᵀHA⁻¹`),障碍在于先验是**围绕旧线性化点的二次近似**,
状态被拉远后近似本身失效 —— 这是线性化误差不是坐标误差,任何正确的坐标变换都修不了。
(**此句为推论,非引文**;但它正是 DM-VIO 选择「重建」而非「变换」的原因。)
📌 顺带:Zhang & Scaramuzza RA-L 2018 给了自由规范↔固定规范的闭式协方差变换 Eq.(12),
但**只覆盖 4 个不可观 DoF(yaw + 平移),不含尺度**。
(🔴 我在本轮任务书里把它的 arXiv 号写成 `1810.02539` 是错的 —— 那是一篇无线网络论文。)

### A.4.4 三处源码级确认(都对我们的改造有直接后果)

- **VINS-Mono 对 s 和 R_wg 的整窗相似变换只发生一次**,在 `visualInitialAlign()`,此时
  `solver_flag==INITIAL`、**先验尚不存在**。之后再无改 s 的通路。
- **VINS-Mono 的回环/重定位不动 VIO 窗口**:修正量导出为 `drift_correct_yaw/t` 交给**独立的 4-DoF pose graph**;
  `double2vector()` 每轮把 pose[0] 的 yaw 与位置**重新锚回** `origin_R0/origin_P0`,
  等于每次都把 gauge 漂移撤销回去 ⇒ **先验的线性化点所在规范永不被动**。
- **ORB-SLAM3 根本没有边缘化先验**:`LocalInertialBA` 只有 `lFixedKeyFrames`;
  `Optimizer::Marginalize()` 唯一用处是 tracking 里每帧重建的 15×15 `ConstraintPoseImu`。
  所以 `ApplyScaledRotation` 改完整张地图后**没有陈旧先验需要处理**。
  ⇒ 🔴 **「抄 ORB-SLAM3 的 ScaleRefinement」这句话是不完整的:它能那么做,是因为它没有我们这种先验。**

---

## A.5 判决与最小改动集

### A.5.1 做 / 不做

| 项 | 判决 | 理由 |
|---|---|---|
| **继续估重力方向(加一个全局 2 自由度重力变量进滑窗)** | **不做** | roll/pitch 可观(Basalt 运行时自检 + Hesch WAFR 2012 + VINS-Mono 自述),10/12 实现固定;**没有任何 VIO 侧的「固定 vs 继续估」量化对照**;唯一受控实验在 LiDAR-惯性且 ATE 中位 −0.1%、置信区间 ±2%,作者明确不外推到 VIO ⇒ **已发表证据不足以支持这个改动** |
| 🏆 **把边缘化先验改成相对参考关键帧表达(顺带让重力方向自然成为 2 自由度活变量)** | **可做,推荐** | 两个独立、许可干净的实现(ICE-BA Apache-2.0 / OKVIS2 BSD-3);ICE-BA 有**单变量消融**:去掉它 EuRoC 平移 RMSE 0.1208→0.1797 m(**+48.7%**);它同时解掉 A.4 那道坎 |
| **周期性整窗尺度重缩放(抄 ORB-SLAM3 ScaleRefinement)** | **暂不做** | ①紧耦合侧零个许可干净的先例;②ORB-SLAM3 能那么干是因为它**没有边缘化先验**(A.4.4);③DM-VIO 自己承认其贡献 "on TUM-VI and EuRoC **do not bring a significant performance improvement**",增益只在 4Seasons 那种初始尺度误差极大的室外大尺度上;④Hong & Lim 这条唯一的干净出路**被引 22 次零人继承** |
| **激励闸 / 尺度健康度监视(只读,不改状态)** | **做,最便宜** | SVO-Pro `backend_scale_stable_thresh = 0.02` 的比值闸是同行已有做法;granite(MIT)的 PCA 尺度漂移风险指标;Campos 的 Hessian 最小奇异值闸 `t_obs=0.1`。**零发散风险,先拿到「我们到底漂不漂」的读数** |

### A.5.2 如果要做,最小改动集(按代价排序)

1. **(只读,零风险)尺度/重力健康度探针** —— 在 `refine_window()` 末尾算两个量并打日志:
   (a) 抄 SVO-Pro 的比值闸:窗口首末关键帧距离 vs 预积分位移的比值;
   (b) 抄 Basalt `sqrt_ba_base.cpp:59-120` 的 `checkNullspace()`:构造 6 个增量(x/y/z/roll/pitch/yaw)
   打到先验的 `sqrt_inv_cov` 上,**VIO 里只有 yaw 那个应该接近零**。这一条同时是**我们自己的阴性对照**
   —— 如果 roll/pitch 的读数随时间增长,才说明重力方向真的在漂;如果不增长,A.5.1 的「不做」就被数据坐实。
   涉及文件:`xrslam/src/xrslam/core/sliding_window_tracker.cpp`(加探针)。
2. **(中,推荐)先验相对化** —— 抄 ICE-BA §5 的思路:`estimation/marginalization_factor.h:22-26`
   现在存的是**绝对** `pose_linearization_point / motion_linearization_point`;改成存
   「相对窗口内某个参考帧」的量,并把参考帧的 roll/pitch 作为一个 2 维块带上。
   ⚠️ **抄的是机制不是代码**(ICE-BA 是 Apache-2.0,代码也可用,但它的数据结构与我们完全不同,
   照搬不现实);OKVIS2 的 `TwoPoseGraphError`(BSD-3)是更接近 Ceres 风格的参考实现。
3. **(如果最终还是要改尺度)最保守的先验处置 = 丢弃重建** —— 在我们树里这是**一行**:
   `map->marginalization_factor.reset()`,因为 `sliding_window_tracker.cpp:311-313` 本来就是
   「为空则重建」;但必须保证 `map.cpp:53-55` 的 `marginalize_frame` 断言在重建之后才被触发。
   🔴 代价无人量化(A.4.3),必须自己量。
4. **不要抄的**:FEJ(A.4 第 3 行,结构上不解决这个问题)、DM-VIO 的 delayed marginalization
   (机制可自实现但是纯自研,且它自己承认在 EuRoC/TUM-VI 上无显著增益)。

### A.5.3 预期收益(引谁的数字 + 口径)

- **先验相对化**:ICE-BA Table 1,**整个 EuRoC,双目,平移 RMSE,对齐不调尺度,i7@3.6GHz 桌面,滑窗 50 帧**
  —— 0.1208 m(有) vs 0.1797 m(无),**+48.7%**。
  🔴 **口径不符之处必须说在前面**:它是**双目**、**桌面**、**EuRoC 无人机**;我们是**单目手机手持近距离**。
  **这个数不能当作我们的预期值**,只能当作「这个机制在一个真实系统上被单变量验证过、且方向明确」的证据。
- **继续估重力的收益**:**没有可引用的 VIO 数字**。唯一的受控数是 LiDAR-惯性的 ±2%。**不应预支。**
- **周期性尺度重优化的收益**:ORB-SLAM3 的「10 s 后 <1%」仍然是唯一的数,但它成立的前提是
  「没有边缘化先验 + 可以整张地图重缩放」,我们不满足前提。

---

## A.6 对既有正文的更正(本轮查出的)

1. 🔴🔴 **§3.2 把 `MIT-SPARK/Kimera-VIO` 列为「✅ 可商用 BSD-2」是错的 —— 第四次「根 LICENSE 骗人」。**
   根 LICENSE 确是 BSD-2,但仓内 vendor 了 Shewchuk 的 Triangle 且**无条件链接**:
   `CMakeLists.txt:73` `add_subdirectory(third_party)`、`:121-124` `target_link_libraries(${PROJECT_NAME} … triangle::triangle)`
   (不是可选项,不是 test-only),而 `third_party/triangle/src/triangle.c:33-35` 逐字:
   > "Distribution of this code as part of a commercial system is permissible **ONLY BY DIRECT ARRANGEMENT WITH THE AUTHOR**."
   ⇒ **Kimera-VIO 要商用必须先和 Shewchuk 单独谈,或把 Triangle 整块摘掉。**(本条我已亲自 curl 原文复核。)
2. 🔴 **「根 LICENSE 骗人」的反向版本同样存在**:`ethzasl_sensor_fusion` 与 `ethzasl_msf`
   **都没有根 LICENSE 文件**,许可只活在文件头里(BSD-3 / Apache-2.0)。只看根目录会得出
   「无许可 ⇒ 不可用」的**错误否定**。⇒ 规矩升级为:**两个方向都要开文件头。**
3. 🔴 **文件名拼写陷阱**:`HKUST-Aerial-Robotics/VINS-Mono` 的许可文件是 **`LICENCE`(英式)**,
   所以 `raw.githubusercontent.com/.../LICENSE` 返回 404,会被误判成「无许可」。
   (与上一轮 `CAOR-MINES-ParisTech/ukfm` 的 `LICENCE.md` 是**同一个坑第二次**。)裁决不变:GPL-3.0 ⚰️。
4. 🔴 **§6 主线 A 引的 ORB-SLAM3 节拍是论文的,不是代码的。** 发布代码 `LocalMapping.cc:200`
   的外层门是 `if ((mTinit<50.0f) && mbInertial)`,而 scale refinement 的时间分支写到 `:235-237` 的
   55/65/75 s —— **那三支是死代码**。实际只在 **25 / 35 / 45 s** 各跑一次。
   关键帧上限 `:231` 是 `KeyFramesInMap() <= 200`,**不是论文说的 100**。
   ⇒ 引 ORB-SLAM3 的节拍必须标明「论文」还是「代码」。
5. 🔴 **我在本轮任务书里给出的两个 arXiv 号是错的**:gauge freedom 不是 `1810.02539`
   (正确件:Zhang & Scaramuzza, RA-L 2018);VI-DSO 不是 `1712.05101`,是 **`1804.05625`**。

---

## A.7 未核与风险(明说)

1. 🔴🔴 **专利不是空地了。** 两件标题直接对口、**权项本轮未核**:
   - **US11328475B2 / US2021/0118218A1,《Gravity estimation and bundle adjustment for visual-inertial odometry》,受让人 Magic Leap**;
   - **US11662805B2(及续案 US12210672),《Periodic parameter estimation for visual-inertial tracking systems》,受让人 Snap Inc.**
     (发明人 Halmetschlager-Funek / Kalkgruber / Wolf / Zillner)。
   Google Patents 对 WebFetch 与带 UA 的 curl 一律 503/拦截;USPTO 的 PDF **是扫描图像(CCITTFaxDecode)无文字层**,
   本轮抽不出权项。⇒ **在动手前必须单独做一次权项与法律状态核查。** 这一条推翻了记忆里「自由空间/重复面是专利空地」
   那条经验在本题上的适用性 —— **本题不是空地。**
2. 🔴 **「固定重力 vs 继续估重力」在 VIO 上零量化对照**;唯一的受控实验在 LiDAR-惯性(`arXiv:2609.13675`,
   **预印本,未见期刊/会议**),且作者明确不外推。
3. 🔴 **纯旋转下重力方向是否可观:零命中。** UMN TR-2016-002 只覆盖常加速度与无旋转。
4. 🔴 **「手机/AR 长时间 roll/pitch 漂移」的发表数字:零命中。** 三个最接近的都不是这个量,**不要当它用**:
   (i) `2609.13675` §IV-F "Maximum roll/pitch change is 0.052°" = 两配置之**差**不是对真值的漂移;
   (ii) 同文手持末 10 秒两配置重力估计相差 0.73–0.74°;
   (iii) `arXiv:2006.06017` §V "the angle error of gravity estimation … can reach 3 degrees at very short
   integration times" = **初始化窗口**误差(≥0.5 s 后可接受),不是长期漂移。
5. 🔴 **「4 个不可观方向」的首证归属未定**:Hesch WAFR 2012 自认转述;Huang 2019 归 Hesch IJRR 2014,
   Zhang & Scaramuzza 2018 归 Kelly & Sukhatme IJRR 2011。
   **Li & Mourikis IJRR 2013、Hesch T-RO/IJRR 2014、Martinelli T-RO 2012/IJCV 2014、Jones & Soatto IJRR 2011、
   Kelly & Sukhatme IJRR 2011 全文本轮一篇都没取到**(闭源 / 反爬 / 401)。
   ⚠️ 「roll/pitch 可观」目前**只有转引级论文证据 + 一条源码级证据(Basalt)**,没有 Martinelli 本人的逐字。
   🔴 方法学:搜索返回的 `pdfs.semanticscholar.org/0be0/…` **不是论文,是第三方讲解幻灯片**,已剔除。
6. 🟡 **ICE-BA CVPR 2018 的参考文献页本轮未能从 PDF 抽出** ⇒ 它为「position/yaw 不可观」所引的 **[14] 是谁,未核**。
   Table 1/Table 2 的数字来自我自己抽取的 PDF 文字层,**列对齐是我人工切分的**(原文串是 `0.120792 2.45 12.90` 这种),
   引用前建议对原始 PDF 的表格再看一眼。
7. 🟡 **Hong & Lim 的表格行值来自 PMC 渲染页**(MDPI 正站 403),未与 PDF 原件逐行核对。
8. 🟡 **maplab 逐文件许可未核**(打开的源文件无文件头,根 LICENSE 是 Apache-2.0);**ROVIO 本轮完全没覆盖**。
9. 🟡 DM-VIO 的消融只有**累积误差曲线 Fig. S1**,没有标量表;其诚实句
   "on TUM-VI and EuRoC the contributions **do not bring a significant performance improvement**" 必须与其增益一起引。
10. 🟡 iSAM2 IJRR 2012 正文四个镜像全拿不到;fluid relinearization 的逐字只到 GTSAM **源码层**。
    并且 `ISAM2::marginalizeLeaves` 自己的文档写着边缘化后 "the linearization points of any variables
    involved in this linear marginal **become fixed**" ⇒ 用 `IncrementalFixedLagSmoother` 会把问题原样带回来。
11. 🟡 Basalt 的 sqrt marginalization(ICCV 2021)**解的不是本题**(治数值条件),§3.2.2 仍明写
    "the linearization point x0κ of the κ-variables **may not be changed**"。

---

# 附录二:我们自己这份 XRSLAM 的边缘化先验长什么样(2026-09-23 第三轮 · 源码穷举 · 零实测)

前面 §A.4 查的是**别人**的实现怎么处理「改了 s 之后先验失效」。本附录拆的是**我们自己仓里这一份**。
读的是 `/Users/kaidongwang/Developer/xrslam` 分支 `pw/vio`,全部逐行实读,下面每条都给行号。

## B.0 判决(一句话)

**周期性尺度精化与这份先验的当前写法是结构性不兼容的,而且不兼容的原因不是「先验太强」,
是「先验用绝对量表达」** —— 这正是 ICE-BA 相对化要解决的那一条,与 §A.4 的调研独立吻合。
另有一条**数值条件**上的怀疑(B.4),它还没被证实,需要 5 行只读插桩才能定论。

## B.1 状态里没有尺度、没有重力 —— 这是穷举不是抽样

全仓参数块声明只有 6 个互不重复的形状,全部列在下面(`grep AddParameterBlock|push_back(3)|push_back(4)` 全量命中 19 条,
去掉 `cost_function_validator.h:36` 那个转发壳与 marginalization 的两处重复声明后即下表):

| 变量 | 维度 | 声明处 |
| --- | --- | --- |
| `frame->pose.q` | 4 | `estimation/solver.cpp:91` |
| `frame->pose.p` | 3 | `estimation/solver.cpp:94` |
| `frame->motion.v` | 3 | `estimation/solver.cpp:101` |
| `frame->motion.bg` | 3 | `estimation/solver.cpp:102` |
| `frame->motion.ba` | 3 | `estimation/solver.cpp:103` |
| `track->landmark.inv_depth` | 1 | `estimation/solver.cpp:115` |

`grep -i "scale\|gravity"` 在这 19 条参数块声明上 **零命中**。
误差状态的布局由 `estimation/state.h:12-19` 钉死:

```
enum ErrorStateLocation { ES_Q = 0, ES_P = 3, ES_V = 6, ES_BG = 9, ES_BA = 12, ES_SIZE = 15 };
```

⇒ **ES_SIZE = 15,没有第 16 维**。尺度与重力方向不是「被固定的变量」,是**根本不存在的变量**。
这与 `preintegrator.cpp:129` 的 `static const vector<3> gravity` 是同一件事的两面。

## B.2 先验用的是绝对量,不是相对量 —— 这是不兼容的真正原因

`ceres/marginalization_factor.h:40-44`,先验残差逐字:

```cpp
rq  = logmap(pose_linearization_point[i].q.conjugate() * q);
rp  = p  - pose_linearization_point[i].p;
rv  = v  - motion_linearization_point[i].v;
rbg = bg - motion_linearization_point[i].bg;
rba = ba - motion_linearization_point[i].ba;
```

而线性化点就是**帧的绝对位姿本身**(`marginalization_factor.h:19-21` 基类构造、`ceres/…:466-467` 每次边缘化后重设):

```cpp
pose_linearization_point[i]   = frame->pose;      // 绝对
motion_linearization_point[i] = frame->motion;    // 绝对
```

⇒ 对全图施加任意全局相似变换(乘尺度 s、或绕水平轴转一个重力修正角),
**`rp` 与 `rv` 会整体跳变 (s−1)·‖p‖ 量级,`rq` 会整体跳变那个修正角**,
而这些残差上挂着的信息矩阵是过去几十帧累积下来的。先验不是「变松了」,是**直接指向错误的地方**。

这就是 §A.4 里 ICE-BA 用 `g_k0 = R_k0 · g` 把先验存成**相对参考关键帧**的形式所绕开的那一条。
两条证据链(读别人的论文 / 读我们自己的源码)独立得到同一个结论。

## B.3 零空间不用移植 Basalt 的探针 —— 这份代码每次边缘化都已经在算了

`ceres/marginalization_factor.h:441-454`:

```cpp
Eigen::SelfAdjointEigenSolver<matrix<>> saesolver(pose_motion_infomat);
vector<> lambdas     = (saesolver.eigenvalues().array() > 1.0e-8).select(saesolver.eigenvalues(), 0);
vector<> lambdas_inv = (saesolver.eigenvalues().array() > 1.0e-8).select(saesolver.eigenvalues().cwiseInverse(), 0);
sqrt_inv_cov = lambdas.cwiseSqrt().asDiagonal() * saesolver.eigenvectors().transpose();
```

即:**信息矩阵每次都做完整特征分解,小于 `1e-8` 的特征值被置零**(标准 VINS-Mono 式零空间截断)。
⇒ 原计划的「移植 Basalt `checkNullspace`」是多余的。**要拿到零空间维数,只需要把
`saesolver.eigenvalues()` 打出来数一下有多少个落在阈值下**,这是只读插桩,不改任何行为。

## B.4 🟡 未证实的怀疑:那个 `1e-8` 阈值可能是失效的

基类构造 `marginalization_factor.h:29-31` 给**第 0 帧**的 P 与 Q 各压了一个 `1.0e15` 的规范固定:

```cpp
sqrt_inv_cov.block<3, 3>(ES_P, ES_P) = 1.0e15 * matrix<3>::Identity();
sqrt_inv_cov.block<3, 3>(ES_Q, ES_Q) = 1.0e15 * matrix<3>::Identity();
```

(偏移量是裸 `ES_P`/`ES_Q` 没乘帧号 ⇒ 确实只作用于第 0 帧。)
它经由 `ceres/…:132` 的 `Evaluate(...)` 进入第一次边缘化,以 `Jᵀ J` 的形式落进信息矩阵 ⇒ 量级 **1e30**。

**怀疑**:信息矩阵特征值跨度 1e30 ↔ O(1),动态范围 1e30;double 的相对精度约 1e-16
⇒ 小特征值的绝对误差约 1e30 × 1e-16 = **1e14**,远大于 1e-8 的阈值。
若成立,则 `1e-8` 这道闸**分不出任何东西**,零空间截断实际上没在工作。

🔴 **这一条目前只是推理,没有测。** 判据:打印 `saesolver.eigenvalues()` 的完整谱,
看最大/最小特征值之比,以及有没有特征值真的落在 1e-8 以下。同一次插桩同时回答 B.3 和 B.4。
在测到之前不得引用本节作为结论。

⚠️ 另注:`1e15` 压的是第 0 帧的**完整 3 自由度姿态**,不只是 yaw。
而重力在世界系里是常量(B.1)⇒ 初始化时第 0 帧姿态里的重力误差被这道规范固定一起焊死。
这条与 §A.2「roll/pitch 可观所以不用估」并不矛盾(可观 ≠ 有变量去承载修正),但方向相反,值得在插桩里一并看。

## B.5 本附录没做什么

- 没有跑任何录制、没有产生任何新实验数据(遵 §A 同一口径)。
- 没有改动 `/Users/kaidongwang/Developer/xrslam` 的任何一行。
- B.4 的插桩**没有写**,因为它属于「动手」,而周期性尺度精化仍卡在专利核查上。
  但 B.1/B.2/B.3 是纯事实,不依赖专利结论,可以现在就定。
