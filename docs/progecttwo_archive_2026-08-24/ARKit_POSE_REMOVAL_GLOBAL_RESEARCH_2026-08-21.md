# 关闭 ARKit 位姿之后：全球方案、实验数据与 PocketWorld 路线判断

**研究日期：** 2026-08-21（Asia/Shanghai）  
**冻结项目上下文：** `HANDOFF_STARTUP_CONTEXT_2026-08-21.md`，SHA-256 `6be2d5c024008845c7a132fd3d826e921a35ee7c36ef90fb3db06aca15fd5bea`  
**研究范围：** 只讨论“ARKit 位姿不再作为必需输入后，视觉/视觉惯性方案能否收敛、质量与成本如何、应该采用哪条产品路线”。LiDAR/激光仅作为公开数据集中的独立评测真值，不作为 PocketWorld 的产品输入。  
**证据优先级：** 同一数据直接消融 > 同领域定量实验 > 官方实现与文档 > 工程经验。本文把论文事实、工程推论与仍未知的问题分开标注。

---

## 0. 一页结论

### 0.1 直接回答

我们当然不是第一个研究这个问题。全球已有四类相邻且互补的工作：

1. **raw ARKit 对比视觉重估/BA 精化**：MobileBrick、HANDAL、CamP、PoRF、MuSHRoom 等都表明，raw ARKit 通常足以提供连续、实时、带尺度和重力的初值，但对毫米级重建或高质量 NeRF/3DGS 往往不够准；视觉 BA、COLMAP 或联合位姿优化成功时，下游质量通常明显提高。
2. **完全不输入平台位姿的经典 SfM**：COLMAP、GLOMAP 等本来就能从图像估计相机位姿。前提是纹理、重叠、平移视差和匹配图足够；纯单目结果只有相似变换意义上的形状与轨迹，天然没有米制尺度和重力方向。
3. **不用 ARKit 的单目 VIO/SLAM**：VINS、ORB-SLAM3、OpenVINS、ROVIO 等证明 RGB+IMU 可以恢复米制尺度并持续跟踪，但需要可靠的时间同步、camera–IMU 外参、运动激励和初始化状态机。桌面论文成绩不等于当前 iPhone 上可持续实时。
4. **pose-free / learned geometry**：DUSt3R、MASt3R-SfM、VGGSfM、FlowMap、VGGT、VGGT-SLAM 等可以在没有输入 pose 时重建或估计相机，但今天仍普遍依赖全局对齐、BA、GPU、大显存或逐场景优化；它们还没有同时满足“手机端实时、米制尺度、闭环、可商用许可”四个条件。

所以，正确问题不是“ARKit 还是 SfM”，而是：

> **平台位姿应当是必需真值、可选先验，还是完全不进入求解器？**

对 PocketWorld 的证据综合建议是：**把平台位姿降级为可选先验/尺度与重力来源，视觉几何负责校正；不要把 raw ARKit 当最终真值，也不要在证据不足时把它从已采集实验包中删掉。**

### 0.2 对 PocketWorld 的立即判断

现在不该先自研通用 VIO，也不该先移植一个大型 learned-SfM。第一步应该是一个严格的、可复现的**同传感器包回放消融**：

- A：当前路径，注入 ARKit pose。
- B1：完全相同的上游资产，只在求解器入口抑制 ARKit pose；它回答 solver-input 消融，不自动证明整条产品链已独立于 ARKit。
- C1/C2：分别测试“ARKit 只给初值、随后自由 BA”和“ARKit 作为带协方差/鲁棒核的持续软先验”。
- D1/D2：分别运行纯视觉 COLMAP incremental 与 GLOMAP global，作为独立诊断臂。

这四类臂能回答三个不同问题：B1 是否收敛、慢多少；C1/C2 是否以较低工程风险取得明显质量收益；D1/D2 能否帮助定位当前视觉前端或后端的差距。只有后续 B2 从不使用 ARKit pose 的上游资产重新生成关键帧、mask、初始化与求解输入，才有资格证明产品链上的 pose optional。

**重要纠正：**“回放时不注入 ARKit pose”和“采集时彻底关闭 ARKit session”不是一个实验。前者是干净的单变量因果测试；后者可能同时改变相机曝光、焦点、帧调度、深度、热状态或资产格式，必须作为第二阶段系统实验单独做。

### 0.3 我给出的路线结论

| 判断 | 结论 | 置信度 |
|---|---|---|
| 纯视觉 SfM 能否在无 ARKit pose 时收敛 | 在静态、纹理/重叠/视差充分的场景，能；退化场景会失败，且失去绝对尺度与重力 | 高 |
| raw ARKit 是否应作为最终高精度 pose | 不应默认如此；多组直接实验证明视觉/联合优化可显著改善 | 高 |
| 删除 ARKit 是否是当前最优动作 | 不是。已采集实验包先保留 raw pose 并让求解输入可选；产品长期存储再单独权衡隐私、容量、功耗和平台耦合 | 高 |
| 现在是否该自研 VIO | 不该。先跑同包 A/B1/C1/C2/D1/D2；只有结果证明连续跟踪和米制尺度是缺口时再进入 VIO 选型 | 高 |
| learned pose-free 是否可直接替换手机采集期跟踪 | 目前不行；适合作为离线研究上限、初始化/匹配前端或失败救援 | 高 |
| “关闭后慢多少”是否有全球统一数字 | 没有。公开研究缺少严格同包、只开关 ARKit pose 的统一 runtime 消融，必须在本项目测 | 高 |

---

## 1. 先把问题拆对：这里其实有四个不同实验

用户口中的“关掉 ARKit 位姿”至少可能指四件事；把它们混在一起，结果就无法解释。

### 1.1 求解器消融：不把 pose 喂给现有 SfM

这是当前最应该做的实验。保持采集和所有上游资产不变，只在 SfM/重建求解器边界将 ARKit pose 设为缺失。它回答：**在既定上游资产下，求解器能否不直接读取逐帧 pose 而建立相机图，注册率多少，收敛时间增加多少。**

这是一项可逆、风险最低、因果最干净的修改。依据冻结交接文档，当前代码存在逐帧位姿外流链路（交接记录的证据位置为 2074、1926、898），因此最小实验应在消费端或回放适配层抑制 pose，而不是先拆 ARKit 捕获链路。与此同时，必须为关键帧、动态 mask、裁剪、深度/点云初始化逐项记录 provenance：如果其中任何资产由 ARKit pose 派生，B1 就只能被称为“求解器入口 pose-off”，不能被宣传为端到端无 ARKit。

### 1.2 初始化消融：视觉从零开始，还是允许 ARKit 给初值

即使最终结果由视觉 BA 决定，“从零估计”“ARKit 仅给初值后完全移除先验”和“整个优化期保留带权软先验”也是三种不同算法。弱纹理、模糊、重复纹理和长序列中，初值常决定能否进入正确吸引域；持续先验还会改变最终最优点。MobileBrick、HANDAL、TMO、Shape of Motion 等实践支持混合思路，但 PocketWorld 必须用 C1/C2 分臂，不能把两种干预揉成一个结果。

### 1.3 采集系统消融：彻底不启动 ARKit

这会改变更多变量：相机控制路径、可获得的内参/深度、帧时间语义、处理负载和温度。它回答的是：**一个不依赖 ARKit 的原始传感器采集栈是否成立。**它不应被拿来直接解释“pose 先验有没有帮助”。

### 1.4 产品架构消融：跨端接口不再要求 Apple pose

这不是一个算法实验，而是接口决策。正确接口应允许：

- 原始图像、精确时间戳、内参/畸变/裁剪/方向；
- 可选 IMU、camera–IMU 外参与时间偏移；
- 可选平台 pose，以及它的协方差、tracking state、reset/relocalization 事件和来源；
- 求解输出自身的坐标系、尺度状态、置信度和修订版本。

这样 Windows/Android/iOS 共用几何层时，不需要伪造一个 Apple 风格 pose，也不会丢掉可利用的设备先验。产品级验证另设 B2：从 pose-independent 的关键帧选择、mask、初始化和视觉输入重新跑到求解器；B2 通过后才能判断跨端接口是否真的不要求平台 pose。

---

## 2. 已经有人做过什么：最接近本问题的直接实验

### 2.1 定量证据矩阵

| 工作 | 控制变量与数据 | 关键结果 | 能证明什么 | 不能证明什么 |
|---|---|---|---|---|
| [MobileBrick, CVPR 2023](https://openaccess.thecvf.com/content/CVPR2023/html/Li_MobileBrick_Building_LEGO_for_3D_Reconstruction_on_Mobile_Devices_CVPR_2023_paper.html) | 10 条真实 ChArUco 标定序列；raw ARKit 对比全序列 BA refined pose | 平移 RMSE `4.454→2.060 mm`；旋转 `0.581°→0.522°`；1 mm 几何 Acc/Rec `90.1/91.3→93.7/93.8%` | raw ARKit 漂移会实质影响毫米级对象重建，视觉 BA 有直接收益 | 不是完全不输入 pose 的从零 SfM；其“GT pose”仍含人工对齐和 BA |
| [CamP, TOG 2023](https://arxiv.org/html/2308.10902) | 9 个 iPhone 13 Pro / NeRFCapture 场景；同一 NeRF 开关相机优化 | raw ARKit `21.12 dB / .615 SSIM / .432 LPIPS`；联合位姿、内参与 CamP 后 `25.97 / .817 / .258` | ARKit 对 AR 可用，但不一定足以支持高质量 NeRF；相机参数优化可带来巨大下游收益 | 没有 COLMAP 臂，也没有轨迹误差和手机端运行成本 |
| [PoRF, ICLR 2024](https://proceedings.iclr.cc/paper_files/paper/2024/hash/cbc80272426028bd561f3889af65c704-Abstract-Conference.html) | MobileBrick 18 场景；所有方法从同一 raw ARKit 起步 | 旋转/平移 `0.46°/1.90 mm→0.22°/1.23 mm`；F1@2.5mm `69.18→75.67`；Chamfer `5.30→4.67 mm` | 视觉/辐射场联合 pose refinement 能超过 raw ARKit，甚至接近其 GT 上限 | 单 A40 约 2.5h；不是手机实时方案；某些通用优化器会把场景优化得更差 |
| [HANDAL, IROS 2023](https://arxiv.org/html/2308.01477) | 手机 ARKit/ARCore pose 与 COLMAP 经过 Sim(3) 对齐 | 中位差 `1.8 cm / 11.4°`；作者称 raw AR pose 足以令 Instant-NGP 不收敛 | 直接证明某些真实采集里，AR pose 精度可低到破坏神经重建 | 没有统一的渲染数表；COLMAP 自身偶有错误帧，需要人工剔除 |
| [MuSHRoom 3DGS, 2025 学位论文](https://er.ucu.edu.ua/items/af9625b9-7614-490b-9dbc-1e10223715a9) | 10 个 iPhone 室内场景；相同 RGB-D 初始化和 3DGS，仅换 pose | ARKit `30.8743 dB / .166717 LPIPS`；COLMAP pose `32.0168 / .149968` | 目前最接近“同下游只换 pose”的 3DGS 直接消融 | 非同行评审、样本小；不能把完整 COLMAP 运行时间只归因于 pose |
| [Shape of Motion](https://arxiv.org/html/2407.13764) | iPhone 动态数据；统一用 refined pose | 作者称 raw ARKit 不够准，使用 COLMAP 全局 BA，再以 Sim(3) 对齐回米制 ARKit | 典型混合实践：视觉负责精化，ARKit 保留尺度和世界方向 | 无 raw-vs-refined 下游定量；近静止/小基线时 COLMAP 会灾难性失败，作者改用 DROID-SLAM/MegaSaM |
| [ADVIO, ECCV 2018](https://www.ecva.net/papers/eccv_2018/papers_ECCV/papers/Santiago_Cortes_ADVIO_An_Authentic_ECCV_2018_paper.pdf) | iPhone 6s，23 序列、4.47 km，含 ARKit 轨迹 | ARKit 大多持续工作，但少量失败使 95 分位位置误差约 10m；电梯使所有方法失效 | ARKit 的价值是实时覆盖，不是精度保证；移动端真实失败域存在 | 参考轨迹精度和独立性有限，不是 COLMAP 直接对照 |

MuSHRoom 数值来自作者官方复现实验仓库冻结 commit [`04f6abc`](https://github.com/rwmutel/rgbd2colmap/tree/04f6abcacb0635a670e3f0bca01f82be6d3f1f19) 的 30,000-step 原始 CSV，而不是不可稳定访问的论文落地页摘要：[`all_psnrs.csv`](https://github.com/rwmutel/rgbd2colmap/blob/04f6abcacb0635a670e3f0bca01f82be6d3f1f19/artifacts/wandb_csvs/all_psnrs.csv)，SHA-256 `32d4b6833bd93ca663465ae712b588f0e76d48a97fb9a064d0e18dcae5a09422`；[`all_lpips.csv`](https://github.com/rwmutel/rgbd2colmap/blob/04f6abcacb0635a670e3f0bca01f82be6d3f1f19/artifacts/wandb_csvs/all_lpips.csv)，SHA-256 `1d3b4fbdd5425a7129541fb0eacccaca648b0597550b85dadbd41f5acfd5b4f1`。论文的非同行评审、小样本限制仍然成立。

### 2.2 对这些数字的正确解读

第一，**方向非常一致，但实验并不完整。** raw ARKit 在高精度几何和新视角合成里常常不是最佳 pose；视觉 BA、COLMAP 或联合优化成功时，结果通常更好。这个结论已经足够支持我们测试“pose 可选化”。

第二，**“COLMAP 成功时更准”不等于“COLMAP 总能成功”。** HANDAL 需要人工剔除 COLMAP 错帧；Shape of Motion 在近静止、小基线场景明确遇到灾难性失败；弱纹理、重复纹理、动态前景、滚动快门和运动模糊都会让纯视觉匹配图断裂。

第三，**下游 PSNR 不能单独裁定 pose。** PoRF 中某些方法可能得到不错的 NVS 指标，却有更差的几何或位姿误差。PocketWorld 必须同时看轨迹、注册覆盖、几何和渲染。

第四，**公开文献没有一个权威统一试验同时包含** `raw ARKit / ARKit-seeded BA / pure COLMAP / learned pose / no-pose / external GT`，并且严格保持相同帧、点云初始化、内参和下游训练预算。因此，“我们自己的同包消融”不是重复造轮子，而是补齐公共证据没有覆盖的产品特定因果问题。

### 2.3 “慢多少”为什么不能直接抄一个数字

平台 pose 是实时产生的，视觉重建的成本取决于帧数、分辨率、匹配图、特征类型、是否做全局 BA、是否复用 IMU，以及硬件。公开数字只能给量级，不能给 PocketWorld 的答案：

- MuSHRoom 的 RGB-D/ARKit 初始化平均约 `7.52s`，完整 COLMAP 约 `123.53s`，但同时换了点云和 pose，不能把约 16 倍差距归因于“关 pose”。
- [GLOMAP](https://arxiv.org/html/2407.20219) 在 LaMAR 的大规模手机/AR 数据上，论文报告的 **mapping/backend runtime** 约 `12,405s`，COLMAP 约 `354,660s`；该口径明确排除了特征提取与匹配。它说明现代全局后端可比经典增量后端快一个数量级以上，但不能当作完整视觉管线 wall time，而且数据规模与手机单房间不可直接等比缩放。
- [MASt3R-SfM](https://arxiv.org/html/2409.19152) 在 200 张图像上，完全图约 `2.2h / 29.9GB`；检索稀疏图约 `14.3min / 8.4GB`，轨迹误差几乎不变。真正决定成本的是图构造和后端，而不是“用了神经网络”这个标签。
- [VGGT](https://arxiv.org/html/2503.11651) 在 H100 上 10 帧前馈约 `0.2s`，加 BA 约 `1.8s`；但 200 帧约 `40.63GB` 显存。它证明前馈初始化很快，也证明高质量结果依然受益于 BA，同时完全不等于 iPhone 可运行。

所以本项目可用于产品决策的确切“慢多少”，必须来自同一不可变输入包、同一目标设备、同一构建上的 wall time、峰值内存、能耗和热稳定测量。

---

## 3. 经典 SfM：不需要 ARKit pose，但有严格的可观测性边界

### 3.1 被反复验证的基础事实

COLMAP 的标准增量 SfM 和 GLOMAP 的全局 SfM 都可以从图像匹配开始，不要求外部位姿。典型流程是：

```text
图像 + 内参
  → 局部特征/学习特征
  → 两视图几何与匹配图
  → 初始化相机对
  → 注册新相机 / 求全局旋转与平移方向
  → 三角化
  → 局部或全局 Bundle Adjustment
  → 稀疏相机与点云
```

[COLMAP 官方 FAQ](https://colmap.github.io/faq.html)也支持已知/共享内参和位置先验；当前 `pose_prior_mapper` 是带位置约束的增量 mapper，但它并不是一个开箱即用的“任意 6DoF ARKit 软先验+完整协方差”接口，仍需明确转换和权重策略。

### 3.2 纯单目 SfM 会失去什么

纯单目图像只能恢复到一个未知相似变换：整体平移、旋转和**绝对尺度**都没有物理锚点。关掉 ARKit pose 后，如果仍然拿米制 ATE 或厘米阈值直接比较，就会把“不可观测”误判成算法错误。正确做法是：

- 纯视觉臂先做 Sim(3) 对齐，再报告 ATE/RPE；
- 单独报告尺度恢复误差和尺度来源；
- 如果产品需要真实米制尺度，要由 IMU、已知物体、人体尺度、设备高度或其它独立约束恢复；不能靠视觉模型“猜出来”后当真值。

### 3.3 成功条件与失败域

纯视觉 SfM 最需要：

- 足够纹理和非重复视觉特征；
- 相邻视图重叠，同时又有足够平移视差；
- 合理曝光和低运动模糊；
- 较少动态前景；
- 准确的内参、畸变和图像裁剪语义；
- 连通的匹配图与闭环视图。

常见退化包括纯旋转、近静止、长白墙、镜面/透明物体、重复门窗、快速甩动、暗光、滚动快门、动态人群和跨房间图断裂。ARKit 与 COLMAP 的失败域并不相同：平台 VIO 可能在弱纹理时靠 IMU 连续输出，视觉离线 SfM 可能在纹理充足时纠正平台漂移。这正是混合系统比单一路线稳的原因。

### 3.4 COLMAP 还是 GLOMAP

[GLOMAP 论文](https://arxiv.org/html/2407.20219)在 LaMAR 上报告：平均 recall@1m `49.1`，COLMAP 为 `32.0`；AUC@1m `24.5` 对 `13.8`；AUC@5m `50.9` 对 `39.4`；时间约 `12,405s` 对 `354,660s`。在 ETH3D SLAM 上 recall@0.1m 为 `66.4` 对 `57.9`，时间 `133.5s` 对 `1115.4s`。

这使 GLOMAP 很适合做长序列纯视觉诊断。但 CAB 等前向运动、昼夜变化、对称与重复结构场景对所有方法都很难。独立 GLOMAP 仓库后来已归档，当前产品研究应以集成进 COLMAP 的 global mapper 为主，冻结准确版本。

---

## 4. ARKit、视觉 BA 与混合后端：证据最充分的常见实用路线

### 4.1 为什么论文与工程实践经常保留 AR pose

ARKit 给出的价值不是“最终精度必然最高”，而是：

- 采集期实时连续覆盖；
- IMU 支持的短时运动预测；
- 米制尺度和重力方向；
- 弱纹理或短暂模糊时的可用初值；
- 对匹配候选的空间裁剪；
- 纯视觉失败后的完整轨迹兜底。

HANDAL 的做法非常典型：最终用 COLMAP pose，但保留 AR pose 来恢复尺度和重力。Shape of Motion 也用 Sim(3) 把视觉精化轨迹对齐回 ARKit 的物理框架。

### 4.2 为什么最终结果又必须经过视觉校正

平台 VIO 会积累漂移、发生重定位跳变、受相机–IMU 标定、rolling shutter、OIS、时间同步和动态环境影响；高质量重建对微小旋转误差尤其敏感。MobileBrick 的毫米级几何提升、CamP 的 `+4.85dB`、MuSHRoom 的约 `+1.14dB` 都说明：采集期“看起来稳”的 pose 不等于优化后重建所需的相机一致性。

### 4.3 推荐的混合模式

```text
原始 RGB / K / timestamps / 可选 IMU
             │
             ├── 可选平台 pose：只作初始化、软先验、尺度/重力、失败兜底
             │
             ▼
视觉匹配 ──→ 局部注册 / 关键帧选择
             │
             ▼
局部 BA ──→ 回环/位姿图 ──→ 全局 BA 或地图形变
             │
             ├── 几何状态层：相机、稀疏/稠密几何、残差与置信度
             └── 外观层：3DGS/NeRF，不反过来冒充唯一几何裁判
```

这里当前阶段最关键的实验原则是：**已采集研究包先保存 raw ARKit，并让 refined pose 成为版本化派生物。**raw pose 能做失败诊断、尺度对齐和回滚；等算法路线确定后，再按隐私、容量、功耗和平台耦合设计产品留存策略，不能把“研究期保留”偷换成“产品永久保存”。

---

## 5. RGB+IMU 的替代：VIO/SLAM 已成熟，但不是“拿一个库就结束”

### 5.1 算法共识

单目+IMU 能恢复米制尺度、roll 和 pitch，但需要足够的平移、视差和非退化加速度激励。静止、恒速直线、过于平滑的移动会使尺度、偏置和重力分量弱可观。IMU 也不会给出全球 yaw 或绝对位置；没有回环或外部锚点时，轨迹仍会漂移。

滤波式路线（MSCKF/OpenVINS/ROVIO）通常更轻、更适合本地实时里程计；滑窗非线性优化路线（VINS/ORB-SLAM3/OKVIS/Kimera）通常精度和全局扩展能力更强，但依赖和计算更重。回环 pose graph、状态内长期 landmarks 和 full global BA 是不同能力，不能用“支持 SLAM”三个字混为一谈。

### 5.2 一手定量参照

- [ORB-SLAM3](https://arxiv.org/html/2007.11898)在 EuRoC 的 mono-inertial 平均 RMS ATE 约 `0.043m`，平均尺度误差 `0.9%`；其初始化实验显示约 2 秒时尺度误差仍约 `5%`，到约 15 秒才到 `1%`。慢运动可导致初始化失败。桌面 i7-7700 上 tracking 约 `23.22ms/帧`，mapping 约 `191.5ms/关键帧`。
- [OpenVINS](https://docs.openvins.com/)支持 mono/stereo、静态与动态初始化，并明确存在尺度可观测性与运动条件；其滤波式核心较轻，但官方没有当前 iPhone 持续运行证据。
- VINS-Mobile 曾在 iPhone 7 Plus 上以 `640×480@30Hz`、IMU `100Hz` 跑过约 `264m`，证明 2017 年移动端可行；它使用旧 Xcode/iOS、GPL 代码且长期未维护，不能直接作为今天的产品底座。

### 5.3 传感器合同才是最大的隐性工程

不依赖 ARKit 后，至少需要版本化记录：

- 图像实际像素坐标对应的 K、畸变、裁剪、旋转和缩放；
- 图像曝光时间、时间戳含义和统一单调时钟映射；
- IMU SI 单位、坐标轴、偏置/噪声模型、丢包与插值；
- `T_imu_camera`、时间偏移及其不确定度；
- global/rolling shutter 模型和读出时间；
- OIS/对焦造成的内参或视线变化能否观察。

Apple 的 [AVFoundation 相机内参接口](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)可以在支持时随 sample buffer 传递 K；[相机间外参接口](https://developer.apple.com/documentation/avfoundation/avcapturedevice/extrinsicmatrix%28from%3Ato%3A%29)只解决物理相机之间的关系，并不等于公开、可靠的 camera–IMU 外参。CoreMotion 能提供 IMU，但公共 API 仍不足以自动给出完整的标定合同。Android Camera2 暴露的 rolling-shutter skew、intrinsics、OIS 或高频 intrinsics 更丰富，但很多字段依设备可选，必须 capability-gate 和残差验证。

[Kalibr 官方指南](https://github.com/ethz-asl/kalibr/wiki/Calibrating-the-VI-Sensor)建议相机约 20Hz、IMU 约 200Hz，充分激励各轴；良好标定的重投影误差约 `0.1–0.2px`。这说明“拿到 RGB+IMU”离“得到可用 VIO 输入”还有一整层同步与标定产品工作。

### 5.4 对 PocketWorld 的选择建议

在 A/B1/C1/C2/D1/D2 结果出来前，不进入实现选型。如果实验表明必须有独立 VIO：

1. 用 ORB-SLAM3、VINS、OpenVINS 作为**行为和质量基线**，不要因为论文数字好就直接嵌入闭源 App。
2. 先做 `VIO-only` 的最小端上 spike，而不是一开始做回环、永久地图、重定位和全局 BA 全家桶。
3. 建立状态机：`waiting → initializing → scale-converging → tracking → degraded → reinit`；UI 必须区分“已有 pose”和“尺度已稳定”。
4. 真机验收必须包括 20–30 分钟热稳态、弱激励、低照、快速甩动、丢帧恢复、重定位、内存、能耗和 p95 延迟。

---

## 6. Learned geometry 与 pose-free NeRF/3DGS：研究前沿，不是现成的采集期替代

### 6.1 三条研究路线

**路线 A：前馈几何预测。** [DUSt3R](https://arxiv.org/html/2312.14132)用图像对预测 pointmaps，不需要输入内参或 pose；多视图仍需全局对齐，输出尺度未知，而且预测点图未必对应物理可实现的单一相机模型。MASt3R 加强匹配与 SfM，VGGSfM、VGGT、MUSt3R 进一步做多视图或长序列。

**路线 B：神经初始化 + 经典后端。** learned matcher、深度、置信度或相机初始化进入 PnP、BA、位姿图和回环。综合当前系统论文，这是工程共识最强的一条趋势：神经网络增强关联和初始化，几何后端负责一致性、可解释残差和全局修正。

**路线 C：直接对辐射场优化相机。** BARF、NeRF--、NoPe-NeRF、FlowMap 等试图联合求相机和场景。它们能在部分数据上无 pose 起步，但常依赖好初值、单目深度、光流/track、密集视图或长时间逐场景优化；外观损失还可能用“看起来对”掩盖几何错误。

### 6.2 关键数据

- [MASt3R-SfM](https://arxiv.org/html/2409.19152)：200 张 Tanks & Temples 图像，完全图 `39,800` 对、`29.9GB`、`2.2h`；检索图 `2,758` 对、`8.4GB`、`14.3min`，ATE `0.01256→0.01243`，说明稀疏图设计比蛮力全配对重要。
- [VGGSfM](https://arxiv.org/html/2312.04563v1#A1.SS2) 在单张 A100 80GB、25 图像、4096 query points 下，按论文分项估算一次 reconstruction run 名义约 `26.4s`；论文未直接给出重复 run 至收敛的完整端到端总时长。其 [BA 消融](https://arxiv.org/html/2312.04563v1#A2.T6) 将 IMC AUC@10 从 `73.92` 降到 `18.34`，说明在该系统里前馈组件尚不能取代经典后端。
- [FlowMap](https://arxiv.org/html/2404.15259)处理 150 帧约 `20min`、峰值 `36GB`，另需约 2 分钟 tracks/flow；长序列上比 COLMAP 高质量配置还慢约 30%，轨迹鲁棒性也并非普遍更好。
- VGGT 在 H100 上 10/20/50/100/200 帧约 `0.14/0.31/1.04/3.12/8.75s`，显存约 `3.63/5.58/11.41/21.15/40.63GB`；10 帧加 BA 后相机 AUC 明显改善。
- [VGGT-SLAM 2.0](https://arxiv.org/html/2601.19887)在 RTX 3090 上 16 帧 submap 约 `8.4 FPS`，其中 VGGT 部分约 `1248ms`；这是很好的“前馈+submap+图优化”研究证据，不是 iPhone 实时证据。

### 6.3 当前前沿的高置信趋势

截至 2026 年，研究大方向不是用一个巨型网络直接吞掉全部 SLAM，而是：

1. 对称 N-view / feed-forward 几何模型提供更强初始化；
2. 用检索、关键帧、submap 和 memory 控制长序列复杂度；
3. 用经典 BA、PnP、pose graph、回环和自标定恢复全局一致性；
4. 将实时局部跟踪与异步全局修正分成两个时间尺度；
5. 把可审计的几何状态层与 NeRF/3DGS 外观层分开；
6. learned scale 只作先验和置信区间，不直接冒充物理尺度。

### 6.4 对 PocketWorld 的结论

learned pose-free 现在适合作为：

- 离线研究上限；
- 低纹理/宽基线匹配和初始化前端；
- 纯视觉失败后的救援；
- 对当前 SfM 是否落后于研究前沿的 shadow benchmark。

它不适合作为当前产品采集期跟踪核心，因为不满足端上持续实时、物理尺度、闭环、热功耗和商业许可的组合要求。PocketWorld 的“全部本机计算”战略尤其排除了把 H100/A100 论文数字直接当产品方案。

---

## 7. 开源不等于可直接商用：技术与许可闸门

以下为工程筛查，不是法律意见。状态针对“闭源、可能通过 App Store 分发、全部本机计算”的产品语境；任何候选在发布前都需要准确构建的 SBOM、文件级版权扫描、NOTICE、模型/数据 provenance 和最终链接闭包审计。

| 候选 | 技术适配 | 许可工程状态 | 产品含义 |
|---|---|---|---|
| COLMAP | 离线经典 SfM/BA 基线 | `conditional` | 顶层 BSD-3；冻结 SHA 的默认 `LSD_ENABLED=ON` 会引入 AGPL LSD，SiftGPU 许可仅覆盖教育、研究和非营利。产品 spike 必须明确关闭/排除这些组件，并以最终 link map、SBOM 和 NOTICE 验证，而不只是笼统写“CPU 构建” |
| GLOMAP | 离线高效全局 SfM | `conditional` | 顶层 BSD-3；独立仓库已归档，优先使用 COLMAP 集成版本并冻结 SHA、依赖和构建开关 |
| ORB-SLAM3 | 高质量 mono-inertial SLAM 基线 | `conflict` | GPL-3.0；闭源嵌入需商业授权或独立法律/架构方案 |
| OpenVINS | 轻量 VIO 研究基线 | `conflict` | GPL-3.0；适合比较，不等于可直接进 App |
| VINS-Mono / Mobile | mono-inertial；仅有历史 iOS 证据 | `conflict` | GPL-3.0，移动仓库老旧；仅作算法和接口参考 |
| ROVIO | 轻量直接滤波 VIO；无当前 iOS 证据 | `conditional` | BSD-3，但 ROS/OpenGL/旧依赖需剥离，完整传递依赖仍待审计 |
| Kimera-VIO | 模块化 VIO/PGO；依赖重，mono 证据弱于 stereo | `conditional` | BSD-2 顶层宽松，但最终依赖闭包、性能和移动构建未核 |
| Basalt | 当前核实实现为 stereo+IMU，不适合单目输入假设 | `conditional` | BSD-3、macOS arm64 活跃；许可方向可继续审计，技术输入当前不匹配 |
| DUSt3R / MASt3R | learned geometry/matching；GPU 研究路径 | `block` | 代码/权重 CC BY-NC-SA 或训练数据附加限制，商业产品阻断 |
| VGGSfM | learned SfM；GPU 研究路径 | `block` | CC BY-NC，商业阻断 |
| 原始 VGGT-1B | 前馈几何；端上算力不匹配 | `block` | 原权重 CC BY-NC；另有 gated commercial 权重，必须单独审核自定义协议、AUP、分发和完整依赖 |
| FlowMap | 离线 pose/geometry 优化 | `insufficient-evidence` | 核心 MIT，但预训练初始化权利链未闭合；论文 3DGS 路径含非商业组件，当前完整路径不可放行 |
| InstantSplat | sparse-view 3DGS；GPU 批处理 | `block` | 顶层 Apache 不会覆盖所依赖的 MASt3R/DUSt3R/3DGS 非商业条款 |

已冻结用于本次技术核查的仓库 HEAD 包括：COLMAP `d2da19444e7c9f73ae4a5926c2d6710d04b91f03`、ORB-SLAM3 `4452a3c4ab75b1cde34e5505a36ec3f9edcdc4c4`、OpenVINS `69488123ed9362dd44b6f28e7f4680abbff1442b`、VGGT `a288dd0f14786c93483e45524328726ab7b1b4ce`、Basalt `0f3b2b52c807f70ff4e2973ce253c73329eea7bc`。这些 SHA 只冻结研究对象，不构成完整商业放行。

---

## 8. 公共基准能回答什么，不能回答什么

没有一个公开数据集同时具备“手机 raw RGB+IMU、同帧 raw ARKit pose、完全独立的高精度全轨迹 GT、激光级几何 GT、运行时间/能耗/温度”。必须采用两层证据：公共基准做资格测试，PocketWorld 同包回放做因果决策。

| 数据集 | 最有价值的资产 | 最适合回答 | 关键限制 |
|---|---|---|---|
| [EuRoC MAV](https://projects.asl.ethz.ch/datasets/euroc-mav/) | 20Hz 双目、200Hz IMU、Vicon/Leica、完整标定 | VIO 初始化、ATE/RPE、算法回归 | 不是手机，主要是全局快门；不能替代 iPhone 真机 |
| [TUM-VI](https://cvg.cit.tum.de/data/datasets/visual-inertial-dataset) | 28 序列、约 20km、硬件同步 | 长程漂移与 VIO 退化；room 有全程 GT | 很多长序列只有首尾 GT；论文把末端 ATE >2m 记为发散 |
| [ADVIO](https://github.com/AaltoVision/ADVIO) | iPhone 6s，同一移动端数据含 RGB、IMU、ARKit | 最接近公开的“有/无 ARKit”配对回放 | GT 与同一手机 IMU 不完全独立且精度有限，不能做厘米级裁决 |
| [ScanNet++ v2](https://scannetpp.mlsg.cit.tum.de/scannetpp/documentation) | 1,006 场景、约 1,000 万 iPhone 帧、raw/aligned ARKit、IMU、COLMAP、Faro 几何 | 同 iPhone 帧流下比较 pose 对 NVS/3DGS/几何的影响 | 数据约 1.5TB、非商业研究条款；COLMAP pose 不是独立轨迹 GT |
| [ARKitScenes](https://github.com/apple/ARKitScenes) | 大规模 iPad/ARKit 与 Faro 几何 | 移动端重建几何验证 | 当前发布的轨迹 provenance 不够清晰，不能直接宣称 raw/refined 成对 GT |
| [ETH3D SLAM](https://eth3d.ethz.ch/slam_overview) | 强独立 GT、官方运行时协议 | 视觉 SfM/SLAM 收敛和 runtime | 非手机、数据非商业；官方插值可能掩盖短暂失锁 |

推荐用 EuRoC/TUM-VI 做 estimator 单元级回归，用 ADVIO 做旧手机域 sanity check，用 ScanNet++ 的同帧资产做离线 pose/downstream 研究；最终产品判断仍由自有目标 iPhone 的同包实验决定。激光资产只作独立裁判，不进入产品计算图。

---

## 9. PocketWorld 的最小决定性实验

### 9.1 预注册目标

**主问题：**在完全相同的原始输入包和既定上游资产上，仅从求解器入口移除 ARKit pose（B1）时，视觉管线是否稳定收敛，native-gauge 资源成本增加多少；经过固定的评测归一化后，轨迹、几何和下游质量是否非劣？

**次问题：**ARKit 仅作初值后自由 BA（C1）与整个优化期保留带权软先验（C2），各自是否比 raw ARKit 有稳定且足够大的收益？上游资产也完全 pose-independent 的 B2 是否仍成立？

**诊断停止条件：**早期 6 条序列只作 gross-feasibility 检查。如果 B1 在任一正常纹理序列的注册图像率低于 `80%`，或 6 条中至少 2 条在规定重试次数内稳定不收敛，就先停止扩大实验，定位上游泄漏、匹配图、内参/时间戳、gauge 或实现问题。这里的 `80%` 是单序列帧注册率诊断线，`2/6` 是序列失败计数；它们都不是正式发布成功率门槛。不要通过无限重跑挑成功样本。

### 9.2 不可变输入合同

每次真实采集只记录一次。所有算法臂共享不可变的原始输入；派生资产则必须显式记录来源：

- 有序图像文件及内容哈希；
- 原始时间戳及时间基；
- 内参、畸变、裁剪、方向和分辨率；
- B1 使用同一关键帧列表、动态 mask、裁剪和初始化，以隔离求解器入口；同时记录这些资产是否由 ARKit pose 派生；
- B2 从不读取 ARKit pose 的路径重新生成关键帧、mask、裁剪、初始化和求解输入，用来验证端到端 pose optional；
- 可选 IMU 原始流及标定；
- raw ARKit pose/tracking state 仅作为某些臂的输入或离线比较资产；
- 3DGS/NeRF 的训练预算、随机种子和验证帧固定；点云初始化、near/far、尺度相关正则和几何阈值作为显式实验因子，禁止暗中复用 A 的 ARKit 派生几何。

每个 run 记录代码 revision/dirty-diff hash、有效 config、输入 manifest hash、每项派生资产的 provenance、模型/权重 hash、环境 lock hash、随机种子、命令、硬件/backend、指标、产物、偏差和 verdict。失败 run 必须保留。

### 9.3 最小场景集

先做 6 条，而不是一上来做几十个房间：

- 2 条正常纹理、有闭环的房间，60–90 秒；
- 2 条低纹理/重复结构/楼梯或跨房间，90–120 秒；
- 2 条低照、快速移动或明显模糊，60–90 秒。

每条都要求有平移视差、一次闭环、一次短暂停顿；另外记录 tracking reset、丢帧、曝光变化和热状态。这个规模只用于粗判可行性，不足以宣称统计意义上的发布质量。

### 9.4 核心实验臂

| 臂 | 输入 pose | 求解 | 目的 |
|---|---|---|---|
| A 当前基线 | raw ARKit | 当前管线 | 现状质量、时间和稳定性 |
| B1 solver-input pose off | 求解器不读 pose；上游资产固定 | 当前视觉求解器从零开始 | 干净回答“只关求解器 pose 是否收敛、native 成本多少”；不能证明端到端独立 |
| B2 end-to-end pose independent | 整条上游和求解器均不读 pose | pose-independent 关键帧、mask、初始化与视觉求解 | 用于支持产品接口 pose optional 的算法实验；仍不等于采集时关闭 ARKit session |
| C1 seed-only | ARKit 仅给初值，随后彻底移除 | 自由视觉 BA | 测初值是否足以避开错误吸引域，以及最终结果能偏离多少 |
| C2 soft-prior | 全程保留 ARKit 软先验 | 明确协方差、鲁棒核和权重的视觉 BA | 测持续先验的稳定性/偏置权衡；不可与 C1 合并归因 |
| C3 gauge-only（可选） | 无逐帧 pose；仅尺度/重力锚 | 视觉求解 + 独立尺度/重力约束 | 区分“视觉不收敛”和“单目 gauge 天然缺失” |
| D1 经典诊断 | 无 | 冻结版 COLMAP incremental | 独立后端/前端资格测试，不是 oracle |
| D2 全局诊断 | 无 | 冻结版 GLOMAP global | 检查 global mapper 是否改善连通性/速度，不是 oracle |

若资源允许，再加 E：高质量外部/refined pose，只作下游上限归因；不作为产品输入。D1/D2 同时失败时原因仍为未决，可能是场景退化，也可能是共同的内参、滚动快门、匹配图或阈值问题。

### 9.5 指标层级

先把 gauge 操作性隔离成两层，避免用评测对齐“帮助”求解器：

1. **原生输出层：**直接记录每臂的收敛、覆盖、相机图、native gauge、wall time、内存、能耗和失败；不得把 Sim(3) 对齐结果反馈给算法。
2. **评测归一化层：**使用冻结、只用于评分的 post-hoc Sim(3) 将纯视觉结果对齐到独立参考，然后比较 L2–L4。点云初始化、near/far、尺度相关正则和几何阈值必须在统一归一化坐标中定义；需要米制输出的产品能力另由 B2/C3/VIO 分支评估。

**L0 输入健康：**帧率、丢帧、时间戳单调性、内参变化、模糊、曝光、IMU gaps。  
**L1 收敛与覆盖：**初始化时间、注册图像率、最大连通分量率、组件数、重定位/重启次数、失败率。  
**L2 相机轨迹：**纯视觉单独报告 post-hoc Sim(3) ATE/RPE、对齐自由度与原生尺度；VIO/米制分支单独报告 SE(3) ATE/RPE、尺度误差；另报旋转误差和闭环误差，不跨 gauge 混成一个平均数。  
**L3 几何：**Chamfer、precision/recall/F1、完整率、深度误差；至少两档阈值。  
**L4 下游：**held-out PSNR/SSIM/LPIPS，验证帧不得参与 pose 优化。  
**L5 系统成本：**wall time、p50/p95、峰值 RAM/VRAM、CPU/GPU/NPU 占用、能耗、温度、降频和 OOM。

### 9.6 建议判定阈值

以下是工程预注册建议，不是论文给出的行业标准；正式阈值应在扩大样本前冻结：

- B2 的正式序列收敛成功率目标 `≥95%`，并报告置信区间；早期 6 条只用于发现 gross failure，不能估计发布成功率。
- 注册图像率/最大连通分量率 `≥95%`，且不比 A 低超过 `10` 个百分点。
- 有独立 GT 时，纯视觉用冻结的 post-hoc Sim(3) ATE/RPE 非劣比值 `≤1.25`；VIO/米制分支另用 SE(3) ATE/RPE 非劣比值 `≤1.25`，两者不直接互排。
- 只有声明可输出米制世界的 B2/C3/VIO 分支才要求尺度误差 `≤2%`；纯单目 SfM 缺尺度不记为“不收敛”。
- 几何 F-score **绝对下降** `≤5` 个百分点。
- 下游相对 A：PSNR 下降不超过 `1dB`，SSIM 不超过 `.02`，LPIPS 增加不超过 `.02`。
- B1 原生输出层的 median wall time 不超过 A 的 `2×`，同时满足产品绝对 SLA；峰值内存和能耗不超过 `1.5×`，无 OOM 或严重热降频。
- C1/C2 必须分别验收；若其中一臂稳定优于 A 且成本可接受，可优先采用相应混合精化，不必等 B2 完全追平。

### 9.7 决策树

```text
B1「只关求解器 pose」是否在正常与困难场景都收敛？
  ├─ 是
  │   ├─ 质量/成本过门 → 继续跑 B2，审计并移除上游 pose 派生资产
  │   │                    ├─ B2 也过门 → 算法接口可 pose optional
  │   │                    └─ B2 失败 → 上游仍依赖 pose，定位关键帧/mask/初始化
  │   └─ 成本过高或缺米制 gauge → 测 C3 或保留可选 ARKit/IMU 锚；优化图和后端
  └─ 否
      ├─ C1/C2 有一臂稳定成功 → 采用明确的「平台先验 + 视觉精化」架构，暂不自研 VIO
      └─ C1/C2 也失败
          ├─ D1 或 D2 成功 → 修当前视觉前端/标定/匹配图/后端
          └─ D1/D2 都失败 → 原因未决；检查视差、内点、连通性、内参与滚动快门，
                              再用独立前端或受控数据复核；不能直接宣布「场景退化」

算法接口通过 B2 后，如仍要彻底不启动 ARKit session，再单独进行采集系统实验。
```

---

## 10. 推荐执行顺序与明确不做项

### 10.1 未来两周内的顺序

1. **冻结回放包与指标定义。**先选 2 条正常序列跑通全链路，再扩到 6 条；不更换算法。
2. **审计派生资产 provenance，并实现 B1 pose 注入开关。**只在消费端屏蔽，保留已录制 raw ARKit；确认 A 与旧结果 bit-for-bit 或指标等价。
3. **跑 A/B1。**先得到“只关 solver pose 是否收敛、native 成本多少”的答案，并保存失败日志、匹配图、注册覆盖和资源曲线。
4. **分开跑 C1/C2。**先测 seed-only 自由 BA，再测带协方差/鲁棒核的 soft-prior BA；这是文献支持较强、预期回报较高的混合对照。
5. **分别跑 D1/D2。**冻结 COLMAP incremental 与 GLOMAP global，只作资格与失败归因，不把它们叫 oracle，也不急着产品化。
6. **若 B1 通过，再跑 B2。**从 pose-independent 的关键帧、mask 和初始化重建上游；根据完整决策树决定是否需要 C3 或独立 VIO spike。

### 10.2 现在不要做

- 不要先删除已采集实验包里的 ARKit pose 或相关字段；先让求解器输入可选，再单独决定产品留存策略。
- 不要用“完整 COLMAP 比 ARKit 慢多少”的混杂数字回答本项目。
- 不要只看 PSNR，忽略 pose、几何、失败率和尺度。
- 不要因一条成功 demo 宣称通用；困难场景和失败 run 必须纳入分母。
- 不要把 GPL/NC 研究代码直接进闭源产品。
- 不要把 H100/A100 速度换算成 iPhone 产品速度。
- 不要把 learned metric scale 当物理真值。
- 不要在第一阶段同时改采集、帧选择、内参、solver 和 3DGS 配置。

---

## 11. 最终立场

现有一手证据的综合足以推翻两个极端说法：

- “ARKit pose 已经足够准，所以不用视觉重估”——不成立。MobileBrick、CamP、PoRF、HANDAL 和 MuSHRoom 都给出反例。
- “既然纯 SfM 能估 pose，就应该立刻删掉 ARKit”——也不成立。纯视觉有尺度不可观测性和明确失败域；ARKit 的实时覆盖、尺度、重力和初值仍然有工程价值。

综合当前研究，工程风险最低的大方向是一个**两时间尺度的混合几何系统**：采集期局部跟踪保证连续性，异步视觉后端通过匹配、BA、回环和全局图改善一致性；learned geometry 增强前端而不是替代所有几何；3DGS/NeRF 负责外观而不是垄断 pose 裁决。

对 PocketWorld 而言，最先做的仍然是：**用相同的已录制传感器包，仅关闭求解器 pose 注入，跑 A/B1；同时准备拆开的 C1/C2 混合对照。**这不是自研，而是用最低成本把外部研究结论落到我们的具体帧、具体房间、具体代码和具体 iPhone 上。B1 只回答 solver-input 问题；只有 B2 再去掉上游 pose 派生资产后，通用位姿层是否真正只需“pose optional”才有资格下结论。若 B1/C1/C2/D1/D2 证明连续米制跟踪仍是缺口，再进入独立 VIO 选型。

---

## 12. 主要一手来源

### ARKit、COLMAP 与下游重建

- Li et al., [MobileBrick: Building LEGO for 3D Reconstruction on Mobile Devices](https://openaccess.thecvf.com/content/CVPR2023/html/Li_MobileBrick_Building_LEGO_for_3D_Reconstruction_on_Mobile_Devices_CVPR_2023_paper.html), CVPR 2023.
- Park et al., [CamP: Camera Preconditioning for Neural Radiance Fields](https://arxiv.org/html/2308.10902), ACM TOG 2023.
- Bian et al., [PoRF: Pose Residual Field for Accurate Neural Surface Reconstruction](https://proceedings.iclr.cc/paper_files/paper/2024/hash/cbc80272426028bd561f3889af65c704-Abstract-Conference.html), ICLR 2024.
- Guo et al., [HANDAL: A Dataset of Real-World Manipulable Object Categories](https://arxiv.org/html/2308.01477), IROS 2023.
- Wang et al., [Shape of Motion](https://arxiv.org/html/2407.13764), 2024.
- Mutel, [Accelerating 3D Gaussian Splatting via RGBD-Guided Point Cloud Initialization](https://er.ucu.edu.ua/items/af9625b9-7614-490b-9dbc-1e10223715a9), UCU 2025.
- Mutel, [rgbd2colmap reproducibility repository at frozen commit](https://github.com/rwmutel/rgbd2colmap/tree/04f6abcacb0635a670e3f0bca01f82be6d3f1f19), 2025.
- Pan et al., [GLOMAP: Global Structure-from-Motion Revisited](https://arxiv.org/html/2407.20219), ECCV 2024.
- [COLMAP FAQ and pose-prior documentation](https://colmap.github.io/faq.html).

### VIO/SLAM 与传感器

- Campos et al., [ORB-SLAM3](https://arxiv.org/html/2007.11898), IEEE TRO 2021.
- Geneva et al., [OpenVINS](https://docs.openvins.com/), official documentation and ICRA 2020 implementation.
- Qin et al., [VINS-Mono](https://arxiv.org/abs/1708.03852), IEEE TRO 2018.
- [Apple AVFoundation camera intrinsic matrix delivery](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled).
- [Apple physical camera extrinsic matrix](https://developer.apple.com/documentation/avfoundation/avcapturedevice/extrinsicmatrix%28from%3Ato%3A%29).
- [Kalibr visual–inertial calibration guide](https://github.com/ethz-asl/kalibr/wiki/Calibrating-the-VI-Sensor).

### Learned geometry 与 pose-free 方法

- Wang et al., [DUSt3R](https://arxiv.org/html/2312.14132), CVPR 2024.
- Leroy et al., [MASt3R-SfM](https://arxiv.org/html/2409.19152), 3DV 2025.
- Wang et al., [VGGSfM](https://arxiv.org/html/2312.04563v1), CVPR 2024.
- Wang et al., [VGGT](https://arxiv.org/html/2503.11651), CVPR 2025.
- Charatan et al., [FlowMap](https://arxiv.org/html/2404.15259), ECCV 2024.
- [VGGT-SLAM 2.0](https://arxiv.org/html/2601.19887), 2026.
- Lin et al., [BARF](https://openaccess.thecvf.com/content/ICCV2021/html/Lin_BARF_Bundle-Adjusting_Neural_Radiance_Fields_ICCV_2021_paper.html), ICCV 2021.
- Wang et al., [NeRF--](https://arxiv.org/abs/2102.07064), 2021.
- Bian et al., [NoPe-NeRF](https://openaccess.thecvf.com/content/CVPR2023/html/Bian_NoPe-NeRF_Optimising_Neural_Radiance_Field_With_No_Pose_Prior_CVPR_2023_paper.html), CVPR 2023.

### 数据集与评测

- [EuRoC MAV dataset](https://projects.asl.ethz.ch/datasets/euroc-mav/).
- [TUM-VI dataset](https://cvg.cit.tum.de/data/datasets/visual-inertial-dataset).
- [ADVIO dataset](https://github.com/AaltoVision/ADVIO).
- [ScanNet++ v2 documentation](https://scannetpp.mlsg.cit.tum.de/scannetpp/documentation).
- [ARKitScenes](https://github.com/apple/ARKitScenes).
- [ETH3D SLAM benchmark](https://eth3d.ethz.ch/slam_overview).

---

## 附录 A：证据状态与仍未解决的问题

| 主张 | 状态 | 依据 | 限制 |
|---|---|---|---|
| raw ARKit 可被视觉/联合优化显著改善 | `confirmed` | MobileBrick、CamP、PoRF、HANDAL、MuSHRoom | 场景、下游和 GT 定义不统一 |
| 纯视觉 SfM 不需要 ARKit pose | `confirmed` | COLMAP/GLOMAP 方法与大规模实验 | 只恢复到 Sim(3)，退化场景可失败 |
| ARKit-seeded BA 是当前低风险高收益路线 | `supported` | 多篇论文的共同工程模式 | PocketWorld 的收益和成本仍须同包验证 |
| learned pose-free 可替代端上采集期跟踪 | `disputed` | 计算、尺度、闭环、许可均存在缺口 | 新模型更新很快，需要持续复核 |
| 关闭 pose 后的确切 slowdown | `unresolved` | 没有严格匹配 PocketWorld 的公开单变量 runtime 消融 | 只能通过本项目回放实验得到 |
| 当前 iPhone 上独立 VIO 可持续 30 分钟实时 | `unresolved` | 仅有旧设备或桌面证据 | 需目标设备热稳态实测 |
| 任一开源候选可无条件商用 | `insufficient evidence` | 尚无候选完成完整传递依赖与权重 BOM | 发布前必须专项审计 |

## 附录 B：研究边界

- 没有使用聊天摘要或搜索摘要代替论文方法/结果；关键数值尽量回到论文正文、官方项目页、官方仓库或原始结果文件。
- citation count、搜索排名和厂商宣传不作为真值判断。
- 没有把“开源可读”“可下载权重”“顶层宽松许可证”“可商用”视为同一件事。
- 没有把公开数据集中的激光/深度资产推荐为 PocketWorld 的产品依赖；它们只用于独立评估。
- 没有执行 PocketWorld 代码修改或真实实验；本文给出的是外部证据综合与实验合同，而不是虚构的项目实测结果。
