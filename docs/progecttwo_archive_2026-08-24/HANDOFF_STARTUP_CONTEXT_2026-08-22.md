---
artifact_contract: "ce-handoff/v1"
created_at: "2026-08-22T03:46:43Z"
title: "PocketWorld 2026-08-21 至 2026-08-22 极致详细接管提示词"
summary: "接管 PocketWorld 厂商中立 T0、ARKit pose-off 全球研究、A/B1 实验、真彩 PLY 查看器及下一步 B2 的完整上下文。"
keywords: ["PocketWorld", "ARKit", "SfM", "A-B1", "vendor-neutral", "B2", "true-color-PLY", "handoff"]
cwd: "/Users/kaidongwang/Documents/progecttwo"
resume_focus: "先核对 A/B1 已完成事实，再推进 frame59 分诊与端到端 pose-independent B2；不要重做研究，不要把 B1 冒充 T0 完成。"
---

# PocketWorld 极致详细接管提示词

> 生成时间：2026-08-22（Asia/Shanghai）  
> 用法：把本文件整体交给新会话。新会话应先读完本文件及其中点名的权威文件，先复述已完成、未完成和下一步，再等待用户确认；不要一上来改代码、重跑实验或重新联网调研。

---

## 0. 给接手新会话的强制开场动作

你正在接管 PocketWorld。当前不是从零讨论“要不要摆脱 ARKit”，而是接续一个已经完成全球调研、跑完第一轮 A/B1、生成真彩点云并定位漏帧原因的连续任务。

按以下顺序建立上下文：

1. 完整读本文件。
2. 完整读基础交接：
   - `/Users/kaidongwang/Documents/progecttwo/HANDOFF_STARTUP_CONTEXT_2026-08-21.md`
   - SHA-256：`1f4ed7b1c8bc65d47b41b80fa39fefc19b55f38eaf700a61324333329d083f66`
   - 297 行。
   - 它保留产品战略、冷启动、留存、资产框架、IP、竞品、组织融资和协作习惯。
3. 完整读全球研究报告：
   - `/Users/kaidongwang/Documents/progecttwo/ARKit_POSE_REMOVAL_GLOBAL_RESEARCH_2026-08-21.md`
   - SHA-256：`9518b1da3251e82e7ddfb3080730de469f636f1e6f3705df5102c3d0941bb46f`
   - 533 行。
4. 完整读实际实验合同修订和结果：
   - `experiments/arkit_pose_ab_20260821/contract-amendment-01.yaml`
   - `experiments/arkit_pose_ab_20260821/protocol-deviation-01.yaml`
   - `experiments/arkit_pose_ab_20260821/results/summary.json`
   - `experiments/arkit_pose_ab_20260821/results/evidence.md`
   - `experiments/arkit_pose_ab_20260821/results/artifact-sha256.txt`
5. 开场先用中文向用户确认以下五点，不要展开长篇方案：
   - A/B1 第一轮已经完成，不应重跑同一个问题。
   - B1 gross convergence 已通过，但不是品牌中立 T0 完成。
   - A 最终 59/60，B1 最终 57/60；两者输入都是 60/60。
   - 真彩 A/B1 已并排查看，用户肉眼看不出明显差别。
   - 下一技术主线是先分诊 frame59，再做 B2；不是先重写完整 SfM/VIO。
6. 然后等待用户确认或给出新指令。交接文件是上下文，不是擅自执行权限。

---

## 1. 一句话当前状态

PocketWorld 是一个人做了八个月的手机端纯本地 3D 重建产品，战略终局是空间内容平台。2026-08-21 至 08-22 已完成：

- 对“关闭 ARKit pose 后 SfM 是否收敛、慢多少”的全球研究；
- 对 PocketWorld 当前 ARKit 依赖和 pose 外流的源码取证；
- 一条 60 帧真机 capture 上的 A（ARKit known-pose）与 B1（solver pose-off）两轮实验；
- Sim(3)、轨迹、稀疏点云和覆盖率诊断；
- A/B1 真彩 PLY 并排网页；
- A 为何 59/60、B1 为何 57/60 的逐帧根因定位。

当前最关键结论：**现有 visual mapper 在求解器完全看不到 ARKit sidecar、pose priors 和 gravity registry 时，能够重复收敛到 57/60；共同注册部分与 A 非常接近。但冻结的 565-edge TVG 仍来自采集期 mandatory-gravity 前端，因此这只是 B1，不是 B2/B3，也没有完成跨品牌 T0。**

---

## 2. 权威顺序：发生冲突时听谁的

按以下优先级裁决：

1. 用户最近明确说出的硬约束。
2. 冻结实验合同修订、protocol deviation、原始日志、模型二进制和哈希。
3. 当前冻结源码文件的 SHA 和明确行号。
4. 本文件。
5. 2026-08-21 基础交接中未被新证据覆盖的部分。
6. 全球研究报告里的工程建议。
7. 任何聊天摘要、早期假设或 AI 推断。

特别覆盖关系：

- 全球研究报告中“平台位姿可以作为产品可选先验/混合路径”的建议，已经被用户后续 T0 决策覆盖。
- ARKit/ARCore/AREngine/眼镜或机器人厂商 pose 只能进入隔离 benchmark，绝不能回到生产计算图。
- A、B1、C1、C2 无论表现多好，都不能升级成生产候选。
- 如果 B2/B3 暂时比 A 差，正确动作是继续改进许可清洁的开源/自有算法，不是把厂商先验留回产品。

---

## 3. 用户已经拍板的 T0，不要重新论证

### 3.1 允许保留什么

ARKit 可以保留为冻结实验基线，用来测：

- 当前 Apple 路径质量；
- 算法差距；
- 失败场景；
- 研究上限；
- 回归。

研究 capture 内可以保存 raw ARKit pose，前提是它只进入隔离的 A/C benchmark target。

### 3.2 生产中绝对禁止什么

下列任何厂商派生资产不得成为生产计算图的输入、初始化、尺度锚、重力锚、失败兜底或静默回退：

- ARKit pose/depth/mesh/tracking/relocalization；
- ARCore pose/depth/tracking；
- AREngine；
- 眼镜厂商 SDK 的 pose；
- 机器人厂商里程计；
- 由上述资产筛出的关键帧、候选边、TVG 内点集或其他隐式派生资产。

### 3.3 唯一允许的跨端差异

每个平台只保留原始传感器薄适配层，输出统一合同：

- RGB 图像；
- 单调时间戳及其语义；
- 与实际图像严格对应的内参；
- 畸变、裁剪、缩放、方向、镜像；
- 原始陀螺仪与加速度计；
- 标定 epoch；
- 设备能力声明；
- 丢帧、热、曝光、对焦等采集健康信息。

同步、标定、关键帧、mask、估姿、尺度/重力恢复、回环、全局优化和重建必须由同一套自有或完整许可放行的品牌无关核心完成。

### 3.4 “任何品牌”的精确定义

不是声称任意缺传感器的硬件都能产生相同质量，而是：

- 任何通过公开 API 满足最低原始传感器合同的设备，均走同一核心；
- 不得维护品牌白名单；
- 不得按品牌分叉估计逻辑；
- 可以做能力检测；
- 对不满足物理输入合同的设备，可以明确拒绝或降功能，但原因必须是能力，不是品牌。

### 3.5 T0 终点

- **B2**：从关键帧、mask、候选配对、TVG/RANSAC、初始化、尺度/重力到求解和下游，全部不读取厂商 AR 或其派生资产。
- **B3**：生产 target 在采集期不链接、不启动、不调用 ARKit/ARCore/AREngine 等厂商 AR 会话。
- **X**：iOS、Android、鸿蒙以及后续眼镜/机器人使用同一版本化核心、行为合同、模型族和 I/O schema。

这三项是不可取消的跨端一致服务 T0。

---

## 4. 这两天到底做了什么：时间线

### 4.1 2026-08-21：建立基础上下文和战略覆盖

1. 完整整理了 PocketWorld 的战略、产品、仓库、ARKit 依赖、IP、竞品、组织和融资上下文。
2. 生成基础交接：
   - `/Users/kaidongwang/Documents/progecttwo/HANDOFF_STARTUP_CONTEXT_2026-08-21.md`
3. 在产品仓源码中确认：
   - `OfficialAetherARKitPlugin.swift` 为 4336 行；
   - 过滤 worktree/build/Pods 后，它是唯一 `import ARKit` 的文件；
   - ARKit 位姿并非只用于 UI，而是逐帧流入 SfM。
4. 用户明确提出：不要一上来自己研发，要联网查全球是否已有 ARKit-off/SfM、ARKit vs COLMAP、VIO、learned pose-free 和开源替代研究。
5. 完成全球研究并形成：
   - `ARKit_POSE_REMOVAL_GLOBAL_RESEARCH_2026-08-21.md`
6. 将“摆脱所有品牌硬件和算法限制”升级为产品 T0，覆盖研究报告里较温和的混合路径建议。
7. 用户明确：第一步仍然是 A/B1，直接开始测试。

### 4.2 2026-08-21 至 08-22：冻结实验、排雷和实现 runner

1. 最初设想是沿 streaming replay 路径，把 pose 置空。
2. 静态审计发现该方案无效：产品 streaming API 在写帧前强制 mandatory ARKit gravity pose，null pose 只会触发 `INVALID_ARG`，不会测试 SfM。
3. 又发现早期归档 DB 是 pruned 版，删除了 descriptors，原 replay driver 会让 60/60 帧全部跳过。
4. 找到同一个 capture 的精确完整 DB：
   - `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_lba_three_arms_20260810/input/cap_1786546115077820/official_sfm_live.db`
   - SHA-256：`6b7ec9ed765645e95c95df69d304c4e73321b0eac538e223463851fc9c5dcaf2`
   - 与 prune manifest 记录的 original DB 字节数和 SHA 完全一致。
5. 确认 official core 已经存在真正的纯视觉 batch 入口：
   - `aether_sfm_run(db_path, "", ...)`
   - 它清空 gravity registry，然后进入当前 `RunIncremental`/COLMAP incremental mapper。
6. 将实验修订为 v2：
   - A 使用当前兼容 known-pose restore/refine 路径；
   - B1 使用纯视觉 batch 路径；
   - 两者共享完整 DB、相机、图片、keypoints、descriptors 和冻结 565-edge TVG。
7. 写了 host-only runner 和 shell 合同测试，冻结其源码与 executable hash。
8. 旧 archived sidecar 恢复失败被定位为 frame identity digest 版本不兼容，而不是 pose 数值错误；失败 run 被保留并排除 reducer。

### 4.3 2026-08-22：跑完 A/B1、量化、真彩查看和漏帧诊断

1. B1 两次重复运行均成功，最终 57/60。
2. A 同一初始图质量对照两次均为 59/60。
3. A production-style replay 两次完成，得到可分账的 stream/finalize 时间。
4. 对两轮模型执行：
   - `model_analyzer`；
   - B1→A 相机中心 Umeyama Sim(3)；
   - 相机旋转/中心残差；
   - sparse symmetric Chamfer-L1；
   - 1/2.5/5 cm F-score。
5. 独立审阅者从四个 COLMAP 二进制模型重新解析并复算，结果通过；只修正过两个旋转统计的末位精度。
6. 生成 A/B1 并排网页。第一次使用原始 PLY 时发现 RGB 全为零，用户指出必须是真彩。
7. 找到 capture 的权威照片主本 `photos.hevc`，解码 60 张 4032×3024 真彩帧，按每个 3D 点全部 track observations 求平均色，重建真彩 PLY。
8. 用户在网页中肉眼查看真彩 A/B1 后反馈：**“肉眼看不出什么差别。”**
9. 用户追问 A 为何也漏帧；完成逐帧根因诊断，明确区分输入、视觉图连通、live pose 和最终几何注册四种 coverage。

---

## 5. 当前仓库和机器路径

### 5.1 产品仓

- 路径：`/Users/kaidongwang/Developer/pocketworld`
- 分支：`main`
- 当前 HEAD 已经前进到：`bb64a955450b96db6acd6ba98c76cce3475ec35e`
- A/B1 合同冻结的是更早 HEAD：`0a90110a...`
- 当前工作树有大量用户改动；不要 reset、checkout、clean、stash 或覆盖。
- 实验复现以合同记录的 HEAD/diff/status manifest 和冻结源文件 SHA 为准，不能把当前 HEAD 冒充实验时 revision。

### 5.2 算法核心

- 算法目录：`/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp`
- Git worktree 根：`/Users/kaidongwang/Developer/Aether3D-cross`
- `.git` 是 worktree 指针，指向 `/Users/kaidongwang/Documents/Aether3D/.git/worktrees/Aether3D-cross`
- `aether_cpp` 自身不是独立 Git 根。
- 此 worktree 的 Git 命令偶尔会卡住；实验身份优先看冻结文件 SHA，不要猜 commit。

### 5.3 研究仓

- `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks`

### 5.4 持久工作区

- `/Users/kaidongwang/Documents/progecttwo`
- 这里不是 Git 仓库。
- handoff、研究报告、实验合同、日志、模型、查看器都在这里。
- `/tmp` 会被系统清空，任何耐久产物都不得只放 `/tmp`。

### 5.5 ARKit 唯一入口和关键证据

文件：

`/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift`

关键行：

- 第 1 行：唯一 `import ARKit`。
- 第 2074 行：`let transform = frame.camera.transform`。
- 第 1926 行：`intrinsics_fxfycxcy`。
- 第 898 行：frame-exact SfM feed。

这证明当前产品的 ARKit pose 是逐帧流入求解层，不只是显示层。

---

## 6. 全球研究：已经查过什么，不要重新从零搜索

权威报告：

`/Users/kaidongwang/Documents/progecttwo/ARKit_POSE_REMOVAL_GLOBAL_RESEARCH_2026-08-21.md`

报告覆盖：

- raw ARKit vs refined/COLMAP/BA 的直接实验；
- 经典 COLMAP/GLOMAP；
- VIO/SLAM；
- DUSt3R、MASt3R、VGGSfM、FlowMap、Spann3R、VGGT、ACE0、Reloc3r 等 learned geometry；
- 手机端 raw RGB+IMU 最低输入合同；
- 开源/权重/依赖许可；
- 公共数据集；
- A/B/C/D/E 实验臂与指标。

### 6.1 已确认的全球共识

1. 纯视觉 SfM 本来就不需要 ARKit pose；COLMAP/GLOMAP 可以从图像、内参和匹配图估计相机与稀疏结构。
2. raw ARKit 是连续、实时、带尺度/重力的优秀产品基线，但不是高精度几何 GT。
3. 视觉 BA、COLMAP 或联合 pose 优化在成功时经常优于 raw ARKit，尤其对 NeRF/3DGS 和毫米级重建。
4. 纯单目 SfM 天然只有 Sim(3) gauge；post-hoc Sim(3) 只能用于评分，不能反馈算法或冒充米制尺度。
5. RGB+IMU VIO 可以恢复尺度和短时连续性，但需要同步、相机-IMU 外参、偏置模型、初始化和足够运动激励；不是“接个 IMU 库”就结束。
6. learned pose-free 是前沿，但当前没有一个公开方案同时满足手机实时、米制尺度、闭环、热功耗、长序列和无条件商用许可。
7. 主流工程方向是 learned 前端增强匹配/深度/初始化，经典 PnP/BA/pose graph/loop closure 保证一致性。
8. 局部实时跟踪与异步全局优化分成两个时间尺度。
9. 没有公开统一数字能回答 PocketWorld 关掉 ARKit 后慢多少；必须在本项目冻结输入上测。

### 6.2 最重要的公开定量证据

| 工作 | 与本项目相关的直接结果 | 正确解释 |
|---|---|---|
| MobileBrick, CVPR 2023 | raw ARKit→BA：平移 RMSE 4.454→2.060 mm；旋转 0.581°→0.522°；1mm Acc/Rec 90.1/91.3→93.7/93.8% | 视觉精化能明显提高毫米级重建；不等于从零 SfM 已解决 |
| CamP, TOG 2023 | raw ARKit 21.12 dB→联合 pose/内参优化 25.97 dB | ARKit 对 AR 可用，不代表足够支撑高质量 NeRF |
| PoRF, ICLR 2024 | 0.46°/1.90mm→0.22°/1.23mm；F1@2.5mm 69.18→75.67；Chamfer 5.30→4.67mm | 精度好但单 A40 约 2.5 小时，不是端上实时方案 |
| HANDAL, IROS 2023 | ARKit/ARCore 与 COLMAP Sim(3) 对齐后中位约 1.8cm/11.4°；raw AR pose 令 Instant-NGP 不收敛 | raw AR pose 不能当 GT；COLMAP 也可能有错帧 |
| MuSHRoom 3DGS | ARKit 30.8743 dB/.166717 LPIPS；COLMAP 32.0168/.149968 | 接近只换 pose 的直接消融，但样本小且非同行评审主论文 |
| GLOMAP vs COLMAP | LaMAR 后端约 12,405s vs 354,660s；ETH3D SLAM 133.5s vs 1115.4s | 全局后端可能大幅提速；不包含完整移动端前端 |
| MASt3R-SfM | 200 图全配对 39,800 对/29.9GB/2.2h；稀疏检索图 2,758 对/8.4GB/14.3min，ATE 近似 | 图设计比蛮力全配对重要 |
| VGGSfM | 去 BA 后 IMC AUC@10 73.92→18.34 | learned 前馈仍离不开经典优化后端 |
| ORB-SLAM3 | EuRoC mono-inertial RMS ATE 约 0.043m；尺度初始化约 15 秒才到约 1% | 可做行为基准，但 GPL 且移动生产集成不是即插即用 |

### 6.3 不要误读研究报告

- 研究支持“两时间尺度视觉几何核心”的结构。
- 它不再授权任何平台 pose 进入生产。
- C1 seed-only、C2 soft-prior 即使表现最好，也只能用于隔离上限研究。
- Learned 方法可做 shadow benchmark 或弱纹理救援研究，但当前不能直接成为生产核心。

---

## 7. 实验臂的精确定义

### A：ARKit known-pose 冻结基线

- 输入逐帧 ARKit pose。
- 用于比较当前产品质量、覆盖和时间。
- 不是 GT。
- 不保证最终几何模型强制保留所有 pose-only 相机。
- 永远不能成为厂商中立生产候选。

### B1：solver-input pose off

- 求解器不读取 `.arkit_pose_v1`；
- `pose_priors=0`；
- position/gravity registry 清空；
- 运行后 60 图像 gravity 命中必须为 0；
- 上游关键帧、候选配对、TVG 等保持冻结。

B1 只回答当前 visual mapper 是否能独立收敛，以及 solver 层差距；不证明端到端厂商中立。

### B2：端到端 pose-independent 前端

- 关键帧、mask、候选配对、TVG/RANSAC、初始化、求解和下游均不读厂商 pose/gravity 或其派生资产。
- 这是下一技术主线。

### B3：采集期彻底关闭厂商 AR

- 生产 target 不链接、不启动、不调用厂商 AR session。
- 只用公开相机/原始 IMU API。
- B2 通过后单独做，避免把算法变化和相机/曝光/热/调度变化混成一个实验。

### C1 / C2

- C1：ARKit 只 seed，之后完全移除并自由 BA。
- C2：ARKit 作为带协方差和鲁棒核的 soft prior。
- 只测研究上限，永不进入生产。

### X：跨端一致性

- iOS/Android/鸿蒙/未来眼镜和机器人走同一核心、schema、模型族和验收门。
- 不同算力可有声明过的 kernel/量化/资源配置，但不能按品牌分叉估计逻辑。

---

## 8. A/B1 实验根目录和权威文件

实验根：

`/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821`

按以下顺序读：

1. `experiment-contract.yaml`
   - v1 原始意图。
   - SHA：`c0e9e37b24a835a74abaf254f2d532d74c071af6e5cd8c1c41e4d030c44ea625`
   - 已被 amendment 标记为执行前无效，不得把它当实际 arm 定义。
2. `contract-amendment-01.yaml`
   - 实际有效 v2 合同。
   - SHA：`6a6b98958d524a9d95a084baa41fbabc6bb258b86718adb5d25fbdd634142e53`
3. `protocol-deviation-01.yaml`
   - 旧 sidecar、运行顺序和 post-hoc 诊断偏差。
   - SHA：`c16424b98f074d7ee94086472ba9b7ae32e46c7952deb71b2c95044d4a82d700`
4. `results/summary.json`
   - 机器可读最终状态。
   - SHA：`44ccac3a9d06c0273132b587530ec017b20c910fe49a199576f8de643254d926`
5. `results/evidence.md`
   - 人工可读最终事实。
   - SHA：`ee1be9c6d63a64574972359f082fe5dc33b0f8ffc76112fead2db8284b082b28`
6. `results/experiment-log.ndjson`
   - 关键事件和原始数值。
   - SHA：`4854b21cccd9526e46ce0ed62044316b1bd1404612ae329574ff87a97f0ae0c2`
7. `results/artifact-sha256.txt`
   - 54 项冻结 artifact 的哈希账本。
8. `results/environment.txt`
   - M3 Pro、macOS、COLMAP、线程和随机性边界。
9. `tools/official_pose_solver_ab_runner.cc`
   - 实际 host-only runner。
   - SHA：`d63188d925dc61f808ed6574ccd6d1f5cc655eaa4c335c606fe788474a830f07`
10. `tests/test_pose_solver_ab_contract.sh`
    - 隔离、泄漏和输出 gate。
    - SHA：`c20a008c68d323305e6a4eb2ea8822f21c8c07d92b9fac32a86ddb0275327376`

runner executable SHA：

`7567870bb6308e46841f3288ec3292b713306adcb8f9477f55d539ab543e6745`

冻结 official core source SHA：

`9e254f4d52860d4cfd48bdaf0ca8df74a500d85794c19de44cd1390ecbb1d16c`

---

## 9. 实验输入身份

capture：`cap_1786546115077820`

完整 DB：

- 60 images，ID 1..60；
- 图像名 `frame_%06d.jpg`，严格对应 frame ID 0..59；
- 60 份 keypoints；
- 422,190 keypoints，cols=6；
- 60 份 descriptors；
- 422,190×128 descriptors；
- keypoint/descriptor row mismatch=0；
- 565 matches；
- 565 two_view_geometries；
- `pose_priors=0`；
- SQLite integrity `ok`；
- 字节数 67,506,176；
- SHA-256：`6b7ec9ed765645e95c95df69d304c4e73321b0eac538e223463851fc9c5dcaf2`。

不要再用早期 pruned DB SHA `616d...`：它删除了 descriptors，只适合部分 batch 读取，不能作为权威 A/B replay 输入。

照片真彩主本：

`/Users/kaidongwang/pw_device_backups/20260817_pre_install/Documents/captures_official/cap_1786546115077820/photos_hevc/photos.hevc`

- SHA-256：`d3254c0868fd09a772cd22477d14b431bb047a6dada7787f8c870bddd33c7512`
- 60 帧；
- 4032×3024；
- HEVC Main；
- yuv420p；
- `photos.pwvi` 保存 frame→原始 JPEG 名映射；
- 原 JPEG 已按归档策略删除，不能假装可以恢复原 JPEG 字节；
- 可恢复的是归档 HEVC 中的真彩像素。

---

## 10. v1 为什么无效，以及实际 v2 比的是什么

### v1 无效原因

1. streaming `AddFrameFeaturesImpl` 在落库前调用 mandatory ARKit gravity pose builder。
2. q/t 为 null 时明确返回 `INVALID_ARG`。
3. 因此 pose-off JSONL 会得到 fed=0，测试的是 ABI guard，不是 SfM 收敛。
4. 早期 pruned DB 没 descriptors，原 replay driver 同样会跳过全部帧。
5. v1 在执行前作废，失败没有被包装成实验结果。

### v2 实际定义

- A：当前 compatible sidecar + known-pose restore/refine API。
- B1：`aether_sfm_run(db, "", ...)` 的 visual incremental mapper。
- 两者共享相机、图片、特征、descriptors 和初始 565-edge TVG。
- 两者不是“同一个 streaming 入口只切一个 pose bool”。

因此 v2 能证明：

- B1 visual solver 是否 gross converge；
- 覆盖和共同几何的方向性差异；
- solver 成本量级。

v2 不能证明：

- 严格 identical-code-path 单变量因果；
- 严格端到端 slowdown；
- 端到端厂商中立；
- 跨设备非劣。

---

## 11. 必须区分的三种 A，绝不能混

### A_current_sidecar_01/02：质量对照

- 与 B1 共享同一个初始 565-edge DB。
- 最终 59 帧、20,407 点。
- 用于 Sim(3)、Chamfer、F-score 和质量指标。
- wall 中位约 35.96s，其中约 35s 是 known-pose restore 的 CPU rematch enrichment。
- 不能作为干净 slowdown 对照。

### A_stream_replay_01/02：生产 replay 时间对照

- 最终 59 帧、21,625 点。
- 用于分账 stream、finalize、total。
- 中位总时间约 11.577s。
- 它不是 B1 同初始 565-edge 质量模型。

### 更早 archived A

- `input-manifest.yaml` 记录 60 帧、21,573 点。
- 这是历史产物，不能与当前 paired A 或 replay A 混用。
- 旧 metadata 中 `n_registered=60` 也不能覆盖当前二进制模型的最终 59。

---

## 12. A/B1 两轮原始结果

### 12.1 同一初始视觉图质量比较

| 指标 | A01 | A02 | A 中位 | B1-01 | B1-02 | B1 中位 |
|---|---:|---:|---:|---:|---:|---:|
| 最终注册帧 | 59 | 59 | 59 | 57 | 57 | 57 |
| raw points | 20,407 | 20,407 | 20,407 | 20,348 | 20,355 | 20,351.5 |
| track≥3 | 7,376 | 7,376 | 7,376 | 7,034 | 7,023 | 7,028.5 |
| observations | 65,328 | 65,328 | 65,328 | 65,749 | 65,788 | 65,768.5 |
| final_diag reproj px | 1.099154 | 1.099154 | 1.099154 | 1.091523 | 1.091572 | 1.0915475 |
| wall ms | 35,890.297 | 36,030.760 | 35,960.5285 | 7,244.661 | 7,281.598 | 7,263.1295 |
| B1 gravity hits | — | — | — | 0 | 0 | 0 |

B1 相对 A：

- 最终注册覆盖：98.33%→95.00%，少 2 帧，下降 3.33 个百分点；
- raw points：-0.271966%；
- track≥3：-4.711226%；
- observations：+0.674290%；
- final_diag reprojection：-0.692032%，即数值略低；这只是内部一致性，不是绝对准确率 GT。

正式 verdict：

- B1 gross convergence：**PASS**；
- 覆盖退化：**确认**；
- 正式质量非劣：**尚未建立**；
- T0 vendor-neutral：**远未完成**。

### 12.2 模型复现性边界

- 两轮注册帧稳定 57；
- B1 点数有小幅非确定性：20,348 / 20,355；
- 后续 completion fresh run 出现 20,343，但注册仍 57、gravity hits 仍 0；
- 不得声称模型二进制逐字节确定性；
- 结论应依赖预注册的稳定指标和噪声地板，而不是单次点数末位。

---

## 13. Sim(3)、轨迹和点云诊断

纯单目 B1 具有任意 Sim(3) gauge。评分时用 57 个同名共同相机中心，将 B1 对齐到 A；A 是参考，不是 GT。

### 13.1 相机

| 指标 | Pair 01 | Pair 02 | 两轮中位 |
|---|---:|---:|---:|
| rotation median | 0.134700° | 0.139779° | 0.1372392° |
| rotation P90 | 0.476859° | 0.472494° | 0.4746764° |
| camera center median | 1.933865 mm | 2.344141 mm | 2.139 mm |
| camera center P90 | 4.581709 mm | 6.752951 mm | 5.66733 mm |

### 13.2 稀疏云

| 指标 | Pair 01 | Pair 02 | 两轮中位 |
|---|---:|---:|---:|
| symmetric Chamfer-L1 | 3.822687 mm | 4.010824 mm | 3.916756 mm |
| F-score @1 cm | 95.1368% | 95.1745% | 95.1557% |
| F-score @2.5 cm | 98.9390% | 98.9342% | 98.9366% |
| F-score @5 cm | 99.7595% | 99.7620% | 99.7608% |

正确结论：在这条 capture 上，B1 关闭 solver pose 后，共同注册部分没有整体崩坏；主要回归集中在帧覆盖。

禁止结论：

- A/B1 已完全等价；
- A 是 GT；
- 这些毫米数是对真实世界真值误差；
- 一条 capture 足以证明跨场景非劣。

---

## 14. “慢多少”的唯一诚实口径

A production replay：

- run 01：stream 8,307.9 ms；finalize 3,280.4 ms；total 11,588.4 ms；
- run 02：stream 8,301.8 ms；finalize 3,263.3 ms；total 11,565.1 ms；
- 中位：stream 8,304.85 ms；finalize 3,271.85 ms；total 11,576.75 ms。

B1 visual solver 中位：7,263.1295 ms。

当前可以说：

- 只比 solver 阶段，B1 是 A finalize 的 `2.2199×`；
- 多 `3,991.28 ms`；
- 如果账面假设 B1 与 A 共享同一个 8,304.85 ms 前端，则 B1 反事实端到端约 15,567.98 ms；
- 约 `1.3448×`，即 `+34.5%`。

必须同时说：

- 15.568s 是 counterfactual 加法，不是实测端到端 B1；
- A/B1 当前使用不同公共入口；
- A quality comparator 的 35.96s 被 rematch enrichment 污染；
- 绝不能宣传“B1 比 A 快 80%”；
- 严格 slowdown 仍为 `unresolved`。

严格 slowdown 实验未来必须：同一 pipeline、同一入口、同一前端，只切显式 pose constraint mode，并同时测 wall、RAM、功耗、温度和降频。

---

## 15. 为什么 A 是 59/60，B1 是 57/60

这部分已经彻底查清近因。绝不能再把 59/57 写成“采集丢帧”。

### 15.1 四种 coverage

| 阶段 | A | B1 |
|---|---:|---:|
| 输入/DB 帧 | 60/60 | 60/60 |
| 冻结视觉图连通 | 59/60 | 59/60 |
| A live ARKit pose 覆盖 | 60/60 | 不适用 |
| 最终有效几何注册 | 59/60 | 57/60 |

### 15.2 A 为什么也少一帧

原始证据：

- `work/A_stream_replay_01/runner.log:248`：`fed=60 missing_pose=0`；
- 第 249 行：phase1 `n_registered=60`；
- 第 292 行：`before=60 after=59 ... frame_000059.jpg(obs=0)`。

`frame_000059.jpg`（第 60 张）：

- 1,547 keypoints；
- 0 matches incident edges；
- 0 TVG incident edges；
- 0 三维 observations。

ARKit pose 可以先把它作为 pose-only 相机带入模型，但不能凭空制造视觉对应和三维结构。最终 `RefineReconstruction` 调用 `FilterFrames`，后者使用 `min_num_observations=1`；零 observation 相机被注销。

因此：

- A 的 Apple/live tracking coverage 是 60/60；
- A 的最终几何 coverage 是 59/60；
- 这不是 ARKit 没有给 pose；
- 强留 frame59 只会虚增注册数，不会增加几何。

源码：

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_incremental_pipeline.cc:838-857`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/sfm/incremental_mapper.cc:1428-1455`

### 15.3 B1 额外少哪两帧

| 帧 | DB image_id | keypoints | TVG 边/内点 | B1 可见 3D | 结果 |
|---|---:|---:|---:|---:|---|
| `frame_000038.jpg` | 39 | 6,931 | 4 / 92 | 15 个可见目标，16 个 distinct 3D IDs | 未达到 30 门槛，从未进入 PnP |
| `frame_000040.jpg` | 41 | 2,704 | 3 / 82 | 16 | 未达到 30 门槛，从未进入 PnP |
| `frame_000059.jpg` | 60 | 1,547 | 0 / 0 | 0 | 无图连接，DatabaseCache 已排除 |

默认 absolute-pose 最少 inliers 为 30：

- `incremental_mapper.h:86`
- `incremental_mapper_impl.cc:351-355` 在 `NumVisiblePoints3D < 30` 时直接 `continue`。

off-by-one 陷阱：日志里的 `Registering image #38/#40` 是 DB IDs 38/40，对应 `frame_000037/39`，不是缺失的 `frame_000038/40`。实际缺失的 DB IDs 39/41 从未进入注册尝试。

A 已有 ARKit pose，可以绕过纯视觉初次注册门槛，之后让 frame38/40 获得三维 observations 并通过最终清理。

### 15.4 frame59 的上游根因仍未决

已知：

- frame59 被完整喂入；
- replay 为它产生 `cand=20`；
- frozen DB 中最终 0 TVG edges；
- `tvg_ms=0 / tri_ms=0 / lba_ms=0`。

未知：

- 照片本身模糊、弱纹理或缺乏重叠；
- 还是最后一帧结束时 matcher/verification 队列没有完整 flush。

在离线重匹配前，不得猜。

---

## 16. B1 仍然残留什么 ARKit 泄漏

B1 solver 内部已确认：

- 没有 sidecar；
- `pose_priors=0`；
- position/gravity registries 已清空；
- `gravity_hits=0`；
- 调用纯视觉 `aether_sfm_run`。

但是：

- frozen 565-edge TVG 是采集期 mandatory-gravity estimator 生成的；
- keyframe selection、候选 pairing 和 TVG 内点集仍有厂商派生 provenance；
- capture 时仍启动了 ARKit session；
- 单目 B1 不原生提供米制尺度。

所以正确命名是：

**B1 solver pose-off / gross convergence smoke。**

错误命名是：

- 端到端 ARKit-off；
- vendor-neutral 完成；
- B2；
- 跨端核心已经验证。

---

## 17. 真彩 PLY 并排网页

最终有效页面：

`/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/index.html`

manifest：

`/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/viewer-manifest.json`

真彩 PLY：

- A：`viewer/data/A_raw_same_graph.ply`
  - 20,407 vertices；
  - SHA：`f1f8e452ae8e152abd6cb609c0a697374db7e2a30cedf172c19b6344464f0eb6`。
- B1：`viewer/data/B1_raw_aligned_to_A.ply`
  - 20,348 vertices；
  - SHA：`cead6cf781cfae27b68e3fef854176137bf2ec86fbf63191c025b849bdbfb207`。

页面和 manifest：

- HTML SHA：`37a92cba25bf7e63c8b400c2e09d6d49dd0abe59928e88c8fab656c6201f4b97`
- manifest SHA：`5dba962c44b218daad545af7b92fe2fb69135d30bc962d37f90988a5546a8562`

真彩来源与处理：

- 原始 COLMAP 模型 RGB 全为 `(0,0,0)`；
- 颜色来自同 capture 的 60 张 HEVC 解码帧；
- 每个 3D 点按全部 track observations 采样并求 RGB 均值；
- A 非黑点 20,407/20,407；
- B1 非黑点 20,348/20,348；
- A unique RGB 14,726；
- B1 unique RGB 14,577；
- 不过滤、不去噪、不补点；
- `filtering=false`；
- `synthetic_colors=false`；
- B1 只施加相机中心 Sim(3) 对齐；
- RGB 不因 Sim(3) 改变。

用户最终肉眼结论：

> “肉眼看不出什么差别。”

这是一条用户定性观察，不是量化 GT。

旧伪色/height-color 页面已经作废。早于 v2 真彩重建时间的截图也不能冒充最终页面验收。

重新打开：

```bash
cd /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821
python3 -m http.server 8765 --bind 127.0.0.1 --directory viewer
```

浏览器打开：

`http://127.0.0.1:8765/index.html`

HTTP server 是易失运行态；新会话不能假设它仍在运行。

查看器验证：

```bash
/Users/kaidongwang/Developer/Aether3D-cross/.venv-da3-coreml27/bin/python \
  /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/tests/verify_viewer.py
```

预期：

```text
PASS viewer contract A=20407 B1=20348
```

默认 `python3` 当前未必有 `pycolmap`；需要重建 viewer 时使用上述 venv。

---

## 18. 开源方案与许可边界

这些是工程预筛，不是法律意见，也不是商业放行。

| 项目 | 当前状态 | 关键原因 |
|---|---|---|
| COLMAP | conditional | 顶层 BSD-3，但默认 LSD/AGPL 和 SiftGPU 非商业条款必须通过构建闭包排除 |
| GLOMAP | conditional | 顶层 BSD-3；独立仓已归档，优先冻结 COLMAP 集成版本并审完整依赖 |
| ORB-SLAM3 | conflict | GPL-3.0；只能研究基准或另谈商业授权 |
| OpenVINS | conflict | GPL-3.0 |
| VINS-Mono / VINS-Mobile | conflict | GPL-3.0，且移动证据陈旧 |
| ROVIO | conditional | BSD-3，但旧依赖、ROS/OpenGL 拆除和移动性能未闭合 |
| Kimera-VIO | conditional | 顶层 BSD，依赖重，移动端/单摄适配和完整闭包未审 |
| Basalt | conditional/not-fit | BSD-3，但当前核实主要 stereo+IMU，不匹配手机单目假设 |
| DUSt3R / MASt3R | block | 代码、权重或训练数据存在 NC/附加限制 |
| VGGSfM | block | CC BY-NC |
| 原始 VGGT-1B | block | 原权重 CC BY-NC；commercial gated 权重是另一协议，未完成审计 |
| FlowMap | insufficient evidence | 核心 MIT，但初始化、完整 3DGS 路径和权利链未闭合 |
| InstantSplat | block | 顶层 Apache 不能覆盖 MASt3R/DUSt3R/3DGS 下游限制 |

原则：**顶层 BSD/MIT/Apache 不等于最终 binary 可以闭源商用。**必须分别审代码、依赖、模型、权重、数据、资产、NOTICE、商标和专利，并以最终 link map/SBOM 为准。

当前可立即继续诊断的路线：

- 当前 official mapper；
- 冻结 COLMAP；
- COLMAP 集成 GLOMAP；
- 如果 B2 真正暴露连续米制跟踪缺口，再做最小 VIO-only spike。

不要先移植巨型 learned-SfM，也不要直接把 GPL/NC 仓库放进 App。

---

## 19. 已经踩过的坑和禁止重走的路

1. **不要再用 null pose streaming replay 测 B1。**它只触发 ABI guard。
2. **不要再用 pruned DB 做 A replay。**它没有 descriptors。
3. **不要直接使用旧 archived sidecar。**它与当前 frame identity digest 版本 60/60 mismatch。
4. 旧 sidecar 的 q/t/gravity 数值其实与新 sidecar一致到浮点误差；这是身份版本不兼容，不是 pose 本身坏了。
5. **不要把 A_current_sidecar 的 35.96s 和 B1 7.26s直接比。**前者含大额 CPU rematch。
6. **不要说 B1 比 A 快 80%。**这是错误口径。
7. **不要把 59/57 写成采集丢帧。**输入都是 60/60。
8. **不要把 A 叫 GT。**A 只是冻结当前产品基线。
9. **不要把 B1 叫端到端 ARKit-off。**TVG 有 mandatory-gravity provenance。
10. **不要先盲目降低 PnP 30-inlier 门槛。**先补真实有效约束和弱帧图连接。
11. A enrich 后的 619-edge 图仍稳定丢 frame38/40；泛化 rematch 不是现成修复。
12. **不要用旧伪色 PLY 冒充真彩。**只认 v2 true-color manifest 和 hash。
13. **不要在 `/tmp` 保存耐久产物。**系统会清。
14. zsh 下 `grep --include=*.swift` 的 glob 要加引号。
15. 搜索产品仓时过滤 `.claude/worktrees|build|Pods|.dart_tool|DerivedData`，避免把副本当唯一实现。
16. 不要清理产品 dirty worktree；改动属于用户。
17. 不要把 H100/A100 论文耗时换算成 iPhone 产品耗时。
18. 不要因为 B1 首轮好看就取消 B2/B3/X。

---

## 20. 当前状态板

### 已完成并有证据

- [x] 基础创业/产品/技术交接。
- [x] ARKit 逐帧 pose 外流源码取证。
- [x] 全球 ARKit-off/SfM/VIO/learned geometry/开源许可研究。
- [x] A/B1 v1 静态否证。
- [x] 找到同 capture 完整 descriptor DB。
- [x] 定位 official visual batch 入口。
- [x] 写 runner 和合同测试。
- [x] 两轮 B1。
- [x] 两轮 A 同图质量对照。
- [x] 两轮 A production replay 时间分账。
- [x] 独立模型/指标复算和证据审阅。
- [x] B1 gross convergence PASS。
- [x] Sim(3)、相机残差、Chamfer、F-score。
- [x] 真彩 A/B1 并排网页。
- [x] 用户完成肉眼对比。
- [x] A 59/60 和 B1 57/60 近因诊断。

### 未完成，禁止写成完成

- [ ] frame59 是内容退化还是尾帧 flush bug。
- [ ] B2 pose-independent 关键帧/配对/TVG。
- [ ] B3 不启动/链接 ARKit session。
- [ ] 严格相同 code path 的 pose-on/pose-off 单变量实验。
- [ ] 严格实测端到端 slowdown。
- [ ] 多场景噪声地板与正式单侧非劣。
- [ ] iPhone 真机 RAM、功耗、温度和降频。
- [ ] 品牌中立米制尺度/重力恢复。
- [ ] 许可清洁的移动端 VIO 产品候选。
- [ ] Android/鸿蒙原始传感器 adapter。
- [ ] 跨品牌 X 验收。
- [ ] 完整商用 SBOM/link-map/权重/数据审计。

---

## 21. 下一步：顺序已经很清楚

### 第 0 步：任何实验前先验 hash

```bash
cd /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821
shasum -a 256 -c results/artifact-sha256.txt
```

预期 54 项全部 `OK`。任何一项不匹配，立即停止，不得继续称为同一冻结实验。

### 第 1 步：frame59 最小独立分诊

目的只回答：内容/重叠不够，还是 live 结束/flush 生命周期 bug。

约束：

- 不重跑完整 SfM；
- 不改 solver；
- 不改阈值；
- 使用冻结 frame59、时间相邻帧和 frozen top-K 候选；
- 离线重新做 matching + geometry verification；
- 保存 pair、raw matches、TVG inliers、失败原因和耗时。

判定：

- 离线可形成有效 TVG：强烈指向 live 尾帧 flush/队列问题；
- 离线仍为 0：强烈指向内容、重叠或真实几何退化；
- 不允许在跑之前先认定是哪一种。

### 第 2 步：写 B2 冻结合同，再测试

B2 的最小目标不是重写 SfM，而是让上游图真正 pose-independent：

- 关键帧选择不得读 vendor pose；
- mask 不得依赖 vendor tracking；
- candidate pairing 不得读 vendor pose/gravity；
- TVG/RANSAC 不得使用 mandatory-gravity；
- 初始化、PnP、BA、尺度/重力状态显式记录 provenance；
- frame38/40/59 作为第一组回归 fixture；
- 输出逐帧 graph degree、inliers、NumVisiblePoints3D、PnP gate 原因；
- 先补时间邻接、回看匹配和弱段候选，不先降 30-inlier 门槛。

B2 成功门至少包括：

- graph connectivity；
- final registration coverage；
- 逐帧失败原因；
- Sim(3) 后相机/几何；
- A 非 GT 的明确标注；
- 重复运行噪声地板；
- 不读取任何厂商派生资产的机器可验证 gate。

### 第 3 步：另做严格 slowdown

不要和 B2 第一轮混在一起。需要：

- 同一 code path；
- 同一输入；
- 同一上游；
- 只切 pose constraint mode；
- 同一设备背靠背重复；
- 预注册 wall/RAM/功耗/温度/降频；
- 失败 run 全保留。

### 第 4 步：扩大 capture 集并测噪声地板

当前只有一条 60 帧 capture，不能外推。

正式集至少覆盖：

- 弱纹理；
- 重复纹理；
- 纯旋转；
- 小视差；
- 模糊；
- 暗光；
- 动态物体；
- rolling shutter；
- 房间切换/图断裂；
- 长时热稳态。

### 第 5 步：B3 与 X

B2 过门后再做 B3，最后做 iOS/Android/鸿蒙跨端 X。市场首发顺序可以另定，但产品核心不能是 Apple-only。

---

## 22. 用户协作方式

- 永远中文回复。
- 用户反驳时先假设他对，再用代码和产物核验。
- 用户明确重复第二次的前提，立即换框架，不要继续论证旧框架。
- 不捏造版本、论文结果、许可或耗时。
- 需要最新事实时联网；已有实验事实优先读本地 artifact，不要重新搜索替代。
- 用户不喜欢流程表演和无谓等待；明确任务应快速做出可见产物。
- 不要把简单交接、查看文件等任务过度工程化。
- 对照实验要单变量；不能单变量时必须明确 protocol deviation。
- 点云交付全量无损；不要用户可见质量滑杆。
- 永远不用 LiDAR 作为最低输入合同。
- 热稳定是硬约束。
- 能用 Dart 就用 Dart，少碰 Swift；但 T0 原始传感器 adapter 必要的原生部分除外。
- 用户明确只接受真彩 PLY；伪色、高度色、synthetic color 均不可冒充。
- 解释 registered 时必须拆成输入、视觉图连通、live pose、最终几何四层。
- 用户已亲眼看过 A/B1 真彩并认为肉眼无明显差别；不要把这条定性观察夸大成数学等价。
- 规模感规律：每次把规模砍小，问题常常自解；当觉得做不了，先检查是不是把实验范围想大了。

---

## 23. 常用验证命令

### 基础文档身份

```bash
cd /Users/kaidongwang/Documents/progecttwo
shasum -a 256 \
  HANDOFF_STARTUP_CONTEXT_2026-08-21.md \
  ARKit_POSE_REMOVAL_GLOBAL_RESEARCH_2026-08-21.md
```

### 实验 artifact

```bash
cd /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821
shasum -a 256 -c results/artifact-sha256.txt
```

### 查看权威结论

```bash
cd /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821
sed -n '1,180p' results/evidence.md
python3 -m json.tool results/summary.json >/dev/null
```

### 真彩 viewer

```bash
/Users/kaidongwang/Developer/Aether3D-cross/.venv-da3-coreml27/bin/python \
  /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/tests/verify_viewer.py
```

### 重新打开 viewer

```bash
cd /Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821
python3 -m http.server 8765 --bind 127.0.0.1 --directory viewer
```

### 检查 ARKit 唯一 import

```bash
rg -n --glob '*.swift' --glob '!**/.claude/worktrees/**' --glob '!**/build/**' \
  --glob '!**/Pods/**' --glob '!**/.dart_tool/**' --glob '!**/DerivedData/**' \
  '^import ARKit$' /Users/kaidongwang/Developer/pocketworld
```

---

## 24. 最重要的文件总索引

### 上下文与研究

- `/Users/kaidongwang/Documents/progecttwo/HANDOFF_STARTUP_CONTEXT_2026-08-21.md`
- `/Users/kaidongwang/Documents/progecttwo/HANDOFF_STARTUP_CONTEXT_2026-08-22.md`
- `/Users/kaidongwang/Documents/progecttwo/ARKit_POSE_REMOVAL_GLOBAL_RESEARCH_2026-08-21.md`

### 实验合同和结果

- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/experiment-contract.yaml`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/contract-amendment-01.yaml`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/protocol-deviation-01.yaml`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/results/summary.json`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/results/evidence.md`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/results/experiment-log.ndjson`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/results/artifact-sha256.txt`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/results/environment.txt`

### runner 和测试

- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/tools/official_pose_solver_ab_runner.cc`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/tests/test_pose_solver_ab_contract.sh`

### 原始 run

- `work/A_current_sidecar_01`
- `work/A_current_sidecar_02`
- `work/A_stream_replay_01`
- `work/A_stream_replay_02`
- `work/B1_contract_smoke_01`
- `work/B1_contract_smoke_02`
- `work/B1_paired_A1_graph`
- `work/B1_paired_A2_graph`
- `work/sidecar_identity_audit.log`
- `work/main_same_graph_pointcloud_diag.log`

上述相对路径均锚定：

`/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821`

### 真彩查看器

- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/index.html`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/viewer-manifest.json`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/data/A_raw_same_graph.ply`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/data/B1_raw_aligned_to_A.ply`
- `/Users/kaidongwang/Documents/progecttwo/experiments/arkit_pose_ab_20260821/viewer/tests/verify_viewer.py`

### 照片主本

- `/Users/kaidongwang/pw_device_backups/20260817_pre_install/Documents/captures_official/cap_1786546115077820/photos_hevc/photos.hevc`
- 同目录 `photos.pwvi`
- 同目录 `master-manifest.json`

### 产品/算法源码

- `/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_incremental_pipeline.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/sfm/incremental_mapper_impl.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/sfm/incremental_mapper.cc`

---

## 25. 给新会话的最终短指令

不要再问“要不要摆脱 ARKit”，答案已经是必须。不要重做已经完成的全球调研和 B1 gross-convergence 实验。先确认 artifact hash，然后把工作拆成最小因果问题：

1. frame59 离线重匹配，区分内容退化与尾帧 flush；
2. 冻结 B2 合同，让关键帧、配对、TVG/RANSAC 真正 pose-independent；
3. 以 frame38/40/59 为回归 fixture，加强真实图连接，不先粗暴降 PnP 门槛；
4. 另开严格相同 code path 的 slowdown 实验；
5. B2 通过后再做 B3 和跨端 X。

始终记住：A 是冻结 Apple 基线，不是 GT；B1 证明 solver 能无 pose 收敛，不等于产品已摆脱厂商依赖；用户肉眼已确认当前真彩 A/B1 无明显差别，但正式跨场景非劣仍未建立。

