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
