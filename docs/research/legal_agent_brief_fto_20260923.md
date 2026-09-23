# 任务书:单目 VIO 若干功能的专利自由实施(FTO)分析

> 版本 2026-09-23 · 起草:PocketWorld 研发会话(非法律人士)
> 本任务书里的「事实」都注明了来源。标 **[待核]** 的地方,起草方没有亲自核实过;标 **[待用户确认]** 的地方,只有产品负责人能回答。
> 附录 A、B 是两份由检索 agent 做的事实搜集报告,原样附上;附录 C 待补;附录 D 是我们自己代码的逐字摘录。

---

## 0. 你的角色、交付物、红线

**角色**:你是专利自由实施(FTO)分析助理。你的产出会交给**持证的中国专利代理师/律师**,以及(视出货市场而定)**美国专利律师**审阅。你不能替代他们,也**不要把你的结论写成法律意见**。你的价值在于:把权项逐要素拆开,和我们的技术逐条对照;找出现有技术线索、设计规避空间,以及需要人类律师拍板的问题。这样可以显著减少律师要花的时间。

**交付物**:见 §9。

**红线(违反任何一条都视为任务失败)**:
1. **不对外做任何事。** 不联系任何人,不向任何专利局提交任何文件(包括中国的「公众意见」、美国的第三方提交 / preissuance submission),不发帖,不把本任务书或你的产出上传到任何公开位置。如果你认为应该提交第三方意见,**写成建议**,由人类决定。
2. **事实和观点分开写。** 每条事实都要标来源:URL、公开号/授权号、文献 DOI/arXiv 号,或者我们代码的 `文件:行`。取不到的写「未取得」,并写明尝试过哪些来源。**不许用看起来合理的猜测填空。**
3. **权项只引原文。** 中文权项用中文,英文权项用英文,**不翻译**(翻译会改变保护范围)。每次引用都要标明是**申请公布文本**还是**授权公告文本**。摘要在法律上不界定保护范围(中国《专利法》第 64 条;美国同理),只能用来定位。
4. **不替我们做商业决定。** 给出选项和每个选项的风险,由人来选。
5. **标了 [待核] 的内容**,你要么核实,要么在产出里继续标待核。不要默认它是对的。
6. **先回答 §8 的 Q7(证据与保密)**,再决定你的产出怎么保存、放在哪里。

---

## 1. 产品与市场背景

| 项 | 事实 / 状态 |
|---|---|
| 产品 | PocketWorld:消费级 3D 扫描 App。用户手持手机拍摄,主力场景是拍小物体,但也会拍房间、家具、墙面。**要求模型有绝对米制尺度**(用户要能在模型上量尺寸)。 |
| 当前平台 | iOS(iPhone)。生产版本的相机位姿依赖苹果 ARKit。 |
| 研发目标 | 用开源单目 VIO(XRSLAM)替代 ARKit,让**同一套管线**跑在 iOS / Android / 鸿蒙 / Web 上,不依赖任何手机操作系统、厂商硬件或厂商 AR 算法。**研发版本尚未上生产。** |
| 设备形态 | 手机。**未来会不会做头戴设备 / AR 眼镜:[待用户确认]** ⚠️ 这一条直接决定 Snap 专利族的风险(见 §4)。 |
| 出货市场 | **中国大陆:[待用户确认:已上架 / 计划上架]**;**美国及其他地区:[待用户确认]**。⚠️ 专利是地域性的,这一条决定哪些专利与我们相关。 |
| 实施主体 | **[待用户确认:个人开发者 / 公司名称 / 注册地]** |
| 商业模式 | **[待用户确认:免费 / 付费 / 订阅 / 内购]**(影响损害赔偿的计算基础) |

---

## 2. 我们实际拥有的代码(逐字摘录见附录 D)

### 2.1 XRSLAM(单目视觉惯性里程计)

- **来源与许可**:OpenXRLab 的 XRSLAM,与 RD-VIO 同一谱系,**Apache-2.0**。根目录 `LICENSE` 首行是 `Copyright 2022 XRSLAM Authors. All rights reserved.`。核心源文件**没有**文件头许可声明,例如 `estimation/ceres/marginalization_factor.h`。「XRSLAM Authors」具体对应哪个法人实体:**[待核]**,线索是 OpenXRLab / 上海人工智能实验室 / 商汤 / 浙江大学。
- **我们的 fork**:`github.com/Kyle-Wang0211/xrslam`(**公开仓**),工作分支 `pw/vio`。
- **架构**:滑动窗口 + 边缘化,用 Ceres 求解。
- **状态变量(穷举,不是抽样)**:每帧有 `q(4) p(3) v(3) bg(3) ba(3)`,每个路标有 `逆深度(1)`。全仓的参数块声明**只有这 6 种**;在这些声明上 grep `scale` / `gravity`,**零命中**。误差状态维数 `ES_SIZE=15`(附录 D.1、D.2)。
- **尺度**:只在初始化器里解一次(`core/initializer.cpp:388,394,426,467`)。之后没有尺度变量,但 IMU 预积分残差本身是米制的,所以尺度一直受到**隐式**约束。
- **重力**:初始化之后是编译期常量(附录 D.3)。
- **边缘化先验**:
  - 先验用**绝对量**表达:`rp = p − p_lin`、`rq = logmap(q_lin* · q)`,线性化点就是帧的**绝对**位姿(附录 D.6、D.7)。
  - **边缘化时不调整参考坐标系。**
  - 首帧的 P、Q 各有一个 `1e15` 的规范固定(附录 D.5)。
  - 每次边缘化都做特征分解,特征值低于 1e-8 的截断(附录 D.8)。
- **没有全局 BA、没有回环、没有位姿图**:在全源码树里 grep `global_BA | loop_closure | pose_graph | global_optim`,零命中。`localizer/` 目录只是一个 HTTP + JSON 远程定位客户端,不做任何优化。

### 2.2 手机端 SfM(生产在用;专有封装 + 开源库)

- **组成**:内置 COLMAP 3.14.0.dev0,加上 GLOMAP、PoseLib、Ceres。各自许可:**[待核]**;起草方的理解是 COLMAP 为 BSD 系、Ceres 为 BSD-3,尚未逐文件核对。
- **专有封装**:出货冻结版 `aether_sfm_c.cc@ea77244a`;官方路线是 `official_pipeline/src/official_aether_sfm_c.cc`。
- **流程**:
  1. 每进一帧,用设备 VIO 位姿(**目前是 ARKit**)把这一帧注册进重建;
  2. 拍摄过程中,对最近 12 帧做窗口局部 BA;
  3. 拍完后做 Cauchy 损失的全局 BA。
- **规范固定**:`FixGauge(THREE_POINTS)`。BA 里**没有**米制位置先验项(`pose_priors` 表 0 行),模型尺度从设备位姿继承而来(附录 D.9)。
- **依赖设备位姿的四处**:
  1. 每帧强制要求有位姿;
  2. 按相机中心做 K 近邻来选匹配对;
  3. 两视几何只走已知重力的 3 点解 `poselib::relpose_upright_3pt`;
  4. 每次 BA 都挂 σ=0.5° 的姿态锚(`MaybeAddAetherGravityPriors`)。
- **可用但未启用**:COLMAP 官方的 `CreatePosePriorBundleAdjuster`(Sim3 对齐 + 带协方差的位置先验)。bench 工具里有 `--useprior` 开关,默认关;出货代码里 0 处使用。

---

## 3. 拟实施的功能(逐要素)

**已经定下、分析时请当作前提的三条设计约束**:
- (i) **不加**「应用空闲时再估一遍」的支路;
- (ii) **不把**本次会话估出的尺度/标定量存起来,留给下次启动当初值;
- (iii) **不把** xrslam 边缘化的产物(先验、相对约束)输入 SfM 的 BA。

### F-A 周期性尺度精化

| 编号 | 要素 |
|---|---|
| A1 | 单目 VIO 运行在**手机**上 |
| A2 | 在**跟踪进行中**运行(应用正在消费位姿),属于在线处理 |
| A3 | **每隔固定时间触发一次**。候选节拍是 5 s、15 s,之后每 10 s(配方来自 ORB-SLAM3 / Campos 博士论文 §4.3.1,我们只照配方复刻,**不拷贝其 GPL 代码**) |
| A4 | 只优化两组量:尺度 `s`(用 `s ← s·exp(δs)` 保证为正)和重力方向的 2 个角。零偏取当前值并固定;全部关键帧都参与 |
| A5 | 其余地图状态保持固定 |
| A6 | 把求得的全局相似变换应用到地图上 |
| A7 | 在同一会话内完成,**不跨会话存储** |
| A8 | 要么配合 F-B,要么在改尺度后「丢弃并重建」边缘化先验,否则会和绝对量表达的先验冲突(见 §2.1)。「丢弃并重建」在现有技术里出自哪里:**[待核]** |

### F-B 相对边缘化先验(ICE-BA CVPR 2018 的机制)

| 编号 | 要素 |
|---|---|
| B1 | 滑动窗口移出最早的一帧时,做边缘化 |
| B2 | 先验**相对于某个参考关键帧**表达,而不是用世界系的绝对量 |
| B3 | 重力也在参考帧里表达:`g_k0 = R_k0 · g` |
| B4 | ICE-BA 原版还会生成「相对约束」交给全局 BA。**我们没有全局 BA,也不打算生成这个相对约束** |
| B5 | **参考帧选哪一帧还没定**:可以是被移出的首帧(ICE-BA 原版的做法,也是 CN108592919B 权 1 的字面写法),也可以是**窗口内剩下的最早一帧**、某个固定锚点帧,或者其他选择。**请把这一条当作可能的设计规避点来重点分析** |
| B6 | 如果最终要引入 ICE-BA 的代码,有两种做法:(a) 直接引入 ICE-BA 的 Apache-2.0 代码;(b) 按机制在 XRSLAM 里重写。**这两条路在 Apache-2.0 §3 专利许可下可能结论不同,见 Q3** |

### F-C 把重力方向作为在线估计变量

我们目前的判断是**不做**。只需要在分析 CN108592919B 从权 5 时顺带评估。

### F-D 把 xrslam 位姿接入手机端 SfM(替代 ARKit 的位姿槽)

| 编号 | 要素 |
|---|---|
| D1 | xrslam 输出的每帧位姿(世界系,重力对齐)作为 SfM 的注册初值,替代 ARKit 位姿 |
| D2 | SfM 的局部/全局 BA 保持现状:纯图像重投影 BA,加 σ=0.5° 的姿态锚 |
| D3 | **不把** xrslam 的边缘化产物输入 SfM 的 BA |
| D4 | (可选变体 F-D')把 xrslam 的相机位置作为 COLMAP `PosePrior`(带协方差),在全局 BA 里加位置先验,并先做 Sim3 对齐 |

### F-E 研发内部的只读诊断插桩

把边缘化时的特征值谱打印出来。**不进产品**,只在研发内部使用。

---

## 4. 已检索到的专利(摘要表;权项全文见附录 A、B)

| 专利 | 权利人 | 状态 | 地域 | 对应我们的功能 | 检索报告给的分诊标签 |
|---|---|---|---|---|---|
| **CN108592919B** 《制图与定位方法、装置、存储介质和终端设备》(申请公布时的标题是《**相对边缘化的**制图与定位方法…》) | 百度在线网络技术(北京)有限公司 | **授权 2019-09-17,有效,预计届满 2038-04-27** | 只有中国,无同族 | **F-B**(权 1),**F-C**(从权 5) | 高(仅中国大陆) |
| CN108572939B 《VI-SLAM的优化方法…》 | 同上 | 授权 2020-05-08,有效 | 只有中国 | 增量式 BA 求解器。我们**不实施** | 上一轮误命中 |
| CN108564625B 《图优化方法…》 | 同上 | 授权 2019-08-23,有效 | 只有中国 | 把三维点节点复制成多份后再边缘化,用来稀疏化。**还没和我们的代码对照** | 未评 |
| **US11662805B2** | Snap Inc. | 授权 2023-05-30,在册 | 美国 | F-A | 低(手机、在线) |
| **US12210672B2** | Snap Inc. | 授权 2025-01-28,在册(2025-03-25 有一份更正证书,只改了一个标点) | 美国 | F-A | 低 |
| **US12704900B2** | Snap Inc. | **授权 2026-08-11**,在册,**族内保护范围最宽** | 美国 | F-A | 低 |
| **CN116830067A** | Snap Inc.(斯纳普公司) | **仍在实审**(实审生效 2023-10-20 之后再没有新事务) | 中国 | F-A | **公布文本的权项没有头戴/可穿戴载体限定**,只保留了「不接收跟踪请求」这一道 |
| EP4272053B1 / EP 分案 25203697 | Snap Inc. | 前者已授权;**分案在审** | 欧洲 | F-A | — |
| KR 10-2932214 B1 / KR 分案 10-2026-7005604 | Snap Inc. | 前者已授权;**分案在审** | 韩国 | F-A | — |
| US11328475B2(Magic Leap,重力估计与 BA) | Magic Leap | **结果待补(附录 C)** | 美国 | F-A / F-C | — |
| CN114387342A 《一种基于相对边缘化的orbslam3的优化算法》 | 上海师范大学 | **状态和权项都没取到** | 中国 | F-B | 未评 |

**主会话亲自复核过的部分**(其余内容来自检索 agent 的报告,请当作待复核的事实):
- US12704900B2 和 US12210672B2 的 claim 1:从 FreePatentsOnline 直接取回,逐字比对一致。
- 这两件的说明书:`gravity` 出现 0 次;`scale` 只出现 1 次,是 "grayscale" 这个词的一部分;`bundle adjust`、`marginaliz` 都是 0 次;**`smartphone` / `smart phone` 共出现 3 处**。
- CN108592919B:权 1、权 5 原文,法律状态 Active,预计届满 2038-04-27,同族只有中国一件。这些都从 Google Patents 直接取回,逐字一致。

---

## 5. 现有技术线索(未经法律核实,供你核查)

- **ICE-BA 自己的公开时间**:百度 '919 的申请日是 **2018-04-27**。ICE-BA 仓库在这个日期之前公开的内容**只有 README**:标题、作者和 "Accepted by CVPR 2018",**没有描述任何机制**(README 在 commit `edf44461`,时间 2018-03-19;其中「边缘化」「相对」零命中)。**代码首次提交是 2018-06-18**(`c49560c8 ICE-BA first commit`),在申请日之后。CVPR 2018 论文正式公开的日期:**[待核]**(会议在 2018 年 6 月)。
  ⇒ 百度自己的公开大概率**不构成**对 '919 的现有技术。请核实:这篇论文是否在 2018-04-27 之前已有 arXiv 版本或其他公开;以及中国《专利法》第 24 条的新颖性宽限期,是否适用于这种情况。
- **「相对」表达的 BA 早于 2018 年的线索 [待核]**:
  - Sibley 等,"Adaptive Relative Bundle Adjustment",RSS 2009;
  - Mei 等,"RSLAM: A System for Large-Scale Mapping in Constant-Time Using Stereo",IJCV 2011。
  这两篇用的都是相对位姿表达。请判断它们能否作为 '919 权 1「调整边缘化参考坐标系」的现有技术或结合对比文件。另外请检索:2018-04-27 之前,是否有别的滑窗 VIO 在边缘化时重设参考系,线索包括 OKVIS、VINS-Mono 的 `slideWindow` 等。
- **早于 Snap 优先权日(2020-12-30)的周期性尺度精化 [待核]**:
  - Campos 等,"Inertial-Only Optimization for Visual-Inertial Initialization",ICRA 2020,arXiv 2003.05766;
  - Campos 等,"ORB-SLAM3",arXiv 2007.11898(2020-07),T-RO 2021;ORB-SLAM3 代码 2020-07 以 GPL-3.0 发布。
  这些工作描述的是**在线**、仅惯性量参与的尺度 + 重力优化,在 5 s、15 s、之后每 10 s 运行。它们和 Snap 族(特别是**在审的 CN116830067A**,以及可能存在的**未公开美国续案**)高度相关。
- **在视觉惯性优化里把重力当 2 自由度变量 [待核]**:
  - VINS-Mono(Qin 等,T-RO 2018,arXiv 1708.03852);
  - ORB-SLAM3 的 `VertexGDir`(`G2oTypes.h:274`,`BaseVertex<2,GDirection>`)。
- Magic Leap 那件的最早公开时间线:见附录 C(待补)。

---

## 6. 许可事实

| 组件 | 许可 | 事实 |
|---|---|---|
| XRSLAM | Apache-2.0 | 版权行写 "XRSLAM Authors",对应的法人实体 **[待核]** |
| ICE-BA(`github.com/baidu/ICE-BA`) | Apache-2.0 | 托管在 GitHub 组织 `baidu` 下(不是 fork)。`LICENSE` 写 `Copyright 2017-2018 Baidu Robotic Vision Authors`。**没有** `NOTICE` / `PATENTS` / `CONTRIBUTING` / CLA 文件。共 13 次提交,提交者邮箱包括 `liuhaomin@baidu.com`、`chenmingyu01@baidu.com`、`wangzhihao05@baidu.com`,另有两名外部贡献者。README 署名:刘浩敏、陈明裕、包英泽、王志昊。**'919 的发明人是刘浩敏、陈明裕、包英泽、范一舟**:范一舟不在 README 署名里,王志昊不在 '919 发明人里。专利权人是「百度在线网络技术(北京)有限公司」。它和 GitHub 组织、和 "Baidu Robotic Vision Authors" 之间的法律对应关系:**未取得** |
| COLMAP / GLOMAP / PoseLib / Ceres | BSD 系 **[待核]** | 生产在用 |
| ORB-SLAM3、DM-VIO、VINS-Mono、OpenVINS | GPL-3.0 | **没有拷贝任何代码**,只读论文、照配方复刻 |
| Basalt | BSD-3 **[待核]** | 只读过源码,用作证据 |

---

## 7. 已知的检索空白(请补上;按优先级排序)

1. 🔴 **我们所用代码的作者方自己的专利**:XRSLAM / RD-VIO / XR-VIO 的作者是浙江大学章国锋团队和商汤 SenseTime。**完全没有检索过**他们在中国或美国的专利。我们用的正是他们的代码;Apache-2.0 §3 的覆盖范围取决于「谁是 Contributor」以及「我们改了多少」。
2. 🔴 **F-D**:「把 VIO 位姿作为手机端 SfM 的注册初值或位置先验,再做全局 BA」这件事,**完全没有检索过**。
3. 🟡 **F-A 的更广检索**:Apple、Google、Qualcomm、Huawei、Meta、Microsoft、Niantic、商汤、字节跳动、OPPO、vivo、小米。Magic Leap 那份报告会覆盖其中一部分(附录 C)。
4. 🟡 CN116830067A 的审查档案(CPQuery,需要实名登录)**未取得**。实审中权项有没有被收窄,目前不知道。
5. 🟡 Snap 美国族很可能还有一件**尚未公开**的续案(按其惯例推断),公开之前结构上检索不到。
6. 🟡 CN114387342A(上海师范大学)的权项和法律状态;CN108564625B(百度)的权项与我们代码的对照。

---

## 8. 需要你回答的问题

**Q7(请最先回答)证据、保密与故意侵权风险**
我们已经留下了书面的专利分析。它们存放在:
- 私有 GitHub 仓 `Kyle-Wang0211/pocketworld`:`docs/research/patent_fto_*.md` 等文件;
- 研发会话的本地记忆文件里。

公开的 `Kyle-Wang0211/xrslam` fork **不包含**任何专利分析(已核:只有许可证样板文字命中 "patent")。

请评估:
- (a) 美国故意侵权(35 U.S.C. §284,Halo v. Pulse 2016)和中国故意侵权惩罚性赔偿(《专利法》第 71 条,1 到 5 倍)下,这些书面记录意味着什么;
- (b) 这类分析是否应当改由律师主导,以争取特权或保密保护;
- (c) 对已经存在的记录,**建议怎么处理**(只写建议,不要执行任何删除操作);
- (d) 你自己这份产出应该怎么保存。

**Q1 CN108592919B 对 F-B**
- 按中国法的**全面覆盖原则**,把权 1、权 9 与 F-B(B1 到 B6)逐要素对照。
- 分析权 1 的「生成相对约束……所述相对约束用于在全局集束调整中优化……」这一要素:我们没有全局 BA,也不生成这个相对约束。在中国方法权项的解释实践中(「用于」这类目的/用途限定怎么解释),这一要素缺失能否导致不落入?请引用相关司法解释,例如最高法《关于审理侵犯专利权纠纷案件应用法律若干问题的解释》(一)(二)。
- **等同原则**的风险评估。
- **B5 的设计规避**:如果参考帧不选「被移出的首帧」,而选窗口内剩下的最早一帧或某个固定锚点帧,能否避开权 1「调整所述边缘化处理的参考坐标系为所述首帧」的字面范围?等同风险有多大?
- 从权 5(重力相对化)对 F-C 意味着什么。

**Q2 CN108592919B 的有效性**
依据 §5 的线索,评估无效宣告的可行性:现有技术的检索方向、可能的对比文件组合、创造性论证思路。**只做评估,不要提交任何东西。**

**Q3 Apache-2.0 §3 的覆盖范围**
§3 的专利许可授予对象是 "the Work",即该仓库的代码本身,由每个 "Contributor" 授予。请分以下三种情形分析,百度对 '919 的专利权是否因 §3 被许可给我们:
- (a) 原样使用 ICE-BA 代码;
- (b) 把 ICE-BA 代码整合进 XRSLAM,形成衍生作品;
- (c) 只按机制在 XRSLAM 里**重写**。
同时请分析:
- 「百度在线」这个法人是否就是 Contributor(提交者用 @baidu.com 邮箱、仓库在 `baidu` 组织下,但仓库里没有任何法人声明);
- 在中国法下,Apache-2.0 §3 的效力,以及默示许可 / 禁止反言的论证空间;
- 如果选 (a) 或 (b),我们在许可和工程上要付出什么代价(例如 §4 的再分发义务,以及 ICE-BA 代码对 SSE/NEON 的依赖)。

**Q4 Snap 美国族对 F-A**
在美国法下做权项解释:
- "head-mounted device" / "wearable device" 与智能手机的关系(说明书举例里列了 smartphone);
- "calibration parameter value" 是否涵盖尺度和重力方向(说明书举的例子都是传感器标定量);
- "calibration trigger event" 是否涵盖一个定时器;
- "not requesting tracking operations" / "offline" 与我们的在线运行。
另请评估:在「很可能存在一件未公开续案」的前提下,怎样的设计规避能**对未来放宽后的权项也保持稳健**。

**Q5 CN116830067A(在审)**
- 按它的**公布文本**权项,评估 F-A 的风险;
- 预测实审中可能怎么收窄;
- 我们是否应该(**仅作建议**)用 §5 的 ORB-SLAM3 / Campos 2020 现有技术,向 CNIPA 提交公众意见;这样做的利弊。

**Q6 F-D 的风险**
- F-D 以及 F-D' 是否会让我们落入 CN108592919B 权 1(我们的理解是:D1 只用位姿做初值,D3 明确不输入边缘化产物,所以没有「相对约束」;请检验这个理解);
- F-D / F-D' 的其他专利风险(需要你先补上 §7 第 2 项的检索)。

**Q8 设计规避方案**
对 F-A、F-B、F-D 分别列出可行的规避方案,按「风险下降程度 ÷ 工程代价」排序。要明确写出**哪些做法会显著增加风险、必须避免**,我们已知的有 §3 那三条;请补充。

**Q9 F-E 的研发内部诊断**
在中国《专利法》第 75 条(专为科学研究和实验而使用有关专利)和美国(实验性使用例外非常窄)下,只在研发内部运行、不进产品的诊断插桩,有没有风险。

**Q10 必须由人类律师核实或拍板的事项清单**
包括:是否需要正式的 FTO 意见书;在中国和美国各需要什么资质的律师;预计要准备哪些材料(我们的代码、设计文档等)。

---

## 9. 输出格式

1. **一页结论**:每个功能(F-A、F-B、F-C、F-D、F-E)在每个相关法域(中国、美国,以及出货市场确认后涉及的其他地区)的风险分诊,标注**高 / 中 / 低 / 无法判断**,并附一句理由和置信度。明确写出:这是分诊标签,不是法律意见。
2. **逐专利的权项对照表**(claim chart):左列是权项要素(原文),中列是我们的对应要素(引用 §3 的编号和附录 D 的 `文件:行`),右列是「字面落入 / 不落入 / 等同风险 / 不确定」加理由。
3. **Q1 到 Q10 的逐条回答**。Q7 放在最前面。
4. **新检索结果**:§7 各项。每件专利都要给出著录项、法律状态(两个来源)、独立权项原文。
5. **现有技术时间线**:文献、日期、DOI/arXiv 号,以及它针对的是哪件专利的哪条权项。
6. **给律师的材料清单与问题清单**。
7. **你自己没做到的事**,以及原因。

语言:中文。权项和文献标题保持原文。

---

# 附录 A:Snap「Periodic parameter estimation」专利族事实搜集报告(检索 agent 原文,原样附上)

> 来源文件:`docs/research/patent_fto_snap_periodic_calibration_20260923.md`(commit `bc2b69c`)。以下「一句话结论」「落内/落外」「风险低」等,都是检索 agent 的**分诊标签**,不是法律结论。

<!-- 来源:专利事实搜集 agent 最终报告,原样落盘(2026-09-23)。
     主会话复核:US12704900 / US12210672 的 claim 1 已用 FreePatentsOnline 直取逐字比对一致;
     两件说明书 grep:gravity 0、scale 仅 'grayscale' 1、bundle adjust 0、marginaliz 0、smartphone/smart phone 共 3。
     本文件是事实搜集,不是法律意见。 -->


---

# 专利事实搜集报告 — Snap「Periodic parameter estimation for visual-inertial tracking systems」族

**检索日期:2026-09-23｜性质:事实搜集(fact-gathering),非法律意见**

---

## 1. 一句话结论

**对特征 (A)「跟踪运行中每 N 秒周期性重优化 metric scale + 2DoF 重力方向」,这一族三件美国专利的风险是【低】** —— 依据是三件专利**全部独立权项**都含两条与 (A) 结构相反的限定语:(i) 载体必须是 **"head-mounted device"**(US11662805、US12210672)或 **"wearable device"**(US12704900);(ii) 参数估计发生在**应用不请求跟踪的空闲/offline 阶段**(`'805`: *"is not requesting tracking operations"*;`'672`: *"during an offline calibration parameter estimation"*;`'900`: *"detecting a calibration trigger event"* + *"as a starting point"*),再在**收到 tracking request 那一刻**把存下的值当作起点。我们的 (A) 恰恰是**在 online 跟踪进行中**周期性重解——落在这些限定语之外。

附带一条更硬的事实:**三件专利的说明书全文中 "scale" 作为"尺度"一次未出现、"gravity" 零命中**(`scale` 唯一一次命中出现在 "grayscale" 一词中)。说明书对 "calibration parameter" 的举例是 *extrinsic(传感器间相对位姿)、intrinsic(相机/镜头)、IMU biases、机架形变、auto exposure* —— 不含 metric scale 与重力方向。

---

## 2. 逐件专利

### 2.1 US 11,662,805 B2

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc.(2023-04-14 记录转让,生效日 2021-04-08,REEL/FRAME 063323/0903) |
| 发明人 | Halmetschlager-Funek, Georg; Kalkgruber, Matthias; Wolf, Daniel; Zillner, Jakob |
| 申请号 | US 17/301,655 |
| 申请日 | 2021-04-09 |
| 优先权日 | **2020-12-30**(US 63/131,981 临时申请) |
| 授权日 | 2023-05-30 |
| 公开 | US 2022/0206565 A1 (2022-06-30) |
| IPC/CPC | G06F3/01; G06F3/038; H04L67/131 / G06F3/012 |
| 现状 | 已授权在册。INPADOC 最后事件 `US STCF — INFORMATION ON STATUS: PATENT GRANT / PATENTED CASE`(2023-05-10),其后**无**失效、放弃、再审查事件 |
| 年费 | INPADOC 事件表中**未见授权后缴费(MAFP)事件**。按授权日推算:3.5 年首笔年费**免附加费窗口 2026-05-30 → 2026-11-30**,宽限期至 2027-05-30 ⇒ **截至今日不可能因欠费失效**。USPTO Fee Portal / Patent Center 实际缴费记录 **NOT RETRIEVED**(见第 3 节"尝试记录") |
| 名义届满 | 2041-04-09(自最早非临时美国申请日起 20 年);PTA/PTE/terminal disclaimer **NOT RETRIEVED** |

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method for calibrating a visual-inertial tracking system comprising:
> detecting, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operating, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identifying, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> storing, in a storage of the head-mounted device, the first calibration parameter value;
> detecting an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, accessing, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

> **11.** A computing apparatus comprising:
> a processor; and
> a memory storing instructions that, when executed by the processor, configure the apparatus to perform operations comprising:
> detect, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operate, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identify, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> store, in a storage of the head-mounted device, the first calibration parameter value;
> detect an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, access, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> detect, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operate, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identify, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> store, in a storage of the head-mounted device, the first calibration parameter value;
> detect an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, access, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

**针对提问的三点:**
- **周期性/时间间隔限定?** 🔴 **独立权项中没有。** "periodically" 只出现在**从属**权项 2/12(*"periodically accessing the sensor data from the plurality of sensors"*)。任何具体秒数(*"every n second, m minutes"*)只在**说明书 [0035]**,不在权项中。
- **是否指明重估哪些参数?** 🔴 **没有。** 只写 "a first/second calibration parameter value of the visual-inertial tracking system",属功能性泛指。说明书举例([0020]/[0038]):*extrinsic parameters (relative orientations and positions between sensors)*、*intrinsic parameters (internal camera or lens parameters)*、*IMU biases*、*bending of the frame*、*auto exposure*。**"metric scale"、"gravity direction" 在说明书中零命中。**
- **是否有显示/AR 眼镜/硬件语境的窄化限定?** ✅ **有,且很重。** 三条独立权项**每一步**都要求 "at a head-mounted device",并且要求存在 "a virtual object display application"、"from the plurality of sensors **only at the head-mounted device**"。

---

### 2.2 US 12,210,672 B2(第一件续案)

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc. |
| 申请号 | US 18/116,511 —— **continuation of 17/301,655** |
| 申请日 | 2023-03-02 |
| 优先权日 | 2020-12-30(US 63/131,981) |
| **授权日** | **2025-01-28** |
| 公开 | US 2023/0205311 A1 (2023-06-29) |
| 现状 | **已授权在册**。另有 **Certificate of Correction,2025-03-25**(见下,纯排印更正) |
| 年费 | 3.5 年首笔年费到期日 **2028-07-28**,免附加费窗口 2028-01-28 起 ⇒ **尚未到期** |
| 名义届满 | 2041-04-09(与母案同日;terminal disclaimer 情况 **NOT RETRIEVED**) |

**Certificate of Correction 内容(已取到 USPTO 原件 PDF 第 25 页并逐字核对):**
> In the Claims — In Column 18, Line 10, in Claim 11, delete "processor," and insert --processor;-- therefor

⇒ 仅把 claim 11 中一个逗号改成分号,**未改动任何实质权项范围**。下方权项文本(授权公告原文)据此有效。

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method comprising:
> periodically updating, at a head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

> **11.** A head-mounted device comprising:
> a processor, and
> a memory storing instructions that, when executed by the processor, configure the head-mounted device to perform operations comprising:
> periodically updating, at the head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> periodically updating, at a head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

**针对提问的三点:**
- **周期性限定?** ✅ **有** —— *"periodically updating"*。**但它被死死绑在 "during an offline calibration parameter estimation" 上**,且该 offline 估计还必须 "performed after an online calibration parameter estimation"。**仍然没有任何数值间隔**(无 "N seconds")。
- **指明参数?** 🔴 没有(同 `'805`,泛指 "calibration parameter value")。
- **硬件/显示限定?** ✅ 有 —— 每条独立权项都要求 "head-mounted device";claim 11 的前序直接就是 "A head-mounted device comprising"。注意此件把 `'805` 的 "virtual object display application" **放宽为 "an application"**(AR 应用退到从属权项 10)。

---

### 2.3 US 12,704,900 B2(第二件续案 —— **本族目前最宽的一件**)

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc. |
| 申请号 | US 18/970,124 —— **continuation of 18/116,511**,后者 continuation of 17/301,655 |
| 申请日 | 2024-12-05 |
| 优先权日 | 2020-12-30 |
| **授权日** | **2026-08-11**(INPADOC `US STCF — PATENT GRANT` 事件日 2026-07-29) |
| 公开 | US 2025/0093948 A1 (2025-03-20) |
| 现状 | **已授权在册**(授权仅一个多月) |
| 年费 | 3.5 年首笔年费到期日 **2030-02-11** ⇒ 尚未到期 |
| 名义届满 | 2041-04-09 |

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

> **11.** A wearable device comprising:
> a processor; and
> a memory storing instructions that, when executed by the processor, configure the wearable device to perform operations comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

**族内演化方向(重要):** 从 `'805` → `'672` → `'900`,Snap 三次递进地**拆掉窄化语**:
- "head-mounted device" → **"wearable device"**
- "virtual object display application" → "an application"
- "detecting that the application is **not** requesting tracking" / "offline estimation" → **"detecting a calibration trigger event"**(offline/online 退到从属 2/3)
- "sensors **only at** the head-mounted device" → "a sensor of the wearable device"

**针对提问的三点:** 周期性限定 🔴 **已从独立权项移除**(退到从属 7/17);参数类型 🔴 仍未指明,且措辞更泛("a first calibration parameter value",连 "of the visual-inertial tracking system" 都挪到了最后一步);硬件限定 ✅ 仍在 —— **"wearable device"**,且仍需 "a tracking request from an application"。

---

## 3. US12210672 "notice of allowance" 核实结果

**判定:证实,且已被事实超越 —— 它不是"已允许待授",而是【已授权】。**

| 证据 | 来源 |
|---|---|
| `"U.S. Appl. No. 18/116,511, Notice of Allowance mailed Sep. 25, 2024", 7 pgs.` —— 逐字出现在 **US 12,704,900 B2 的 "Other References" 审查记录栏**(即 USPTO 在后续续案中正式引用的母案档案) | FreePatentsOnline US12704900 记录 |
| US 12,210,672 B2 **Publication Date: 01/28/2025**,Application Number 18/116,511 | FreePatentsOnline US12210672 记录 |
| `US12210672B2 · US202318116511A · 2025-01-28` 列于 INPADOC 族表;并有 `US CC — CERTIFICATE OF CORRECTION, 2025-03-25` 法律事件 | Espacenet(EPO)INPADOC 族/法律事件 |
| 授权原件 PDF(25 页,含第 25 页 Certificate of Correction)可从 USPTO `image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12210672` 直接下载 | USPTO 一手件 |
| 独立第三源逐字复现同一套权项文本 | PatentGuru US12210672B2 |

**⇒ 结论:先前调研报告的 "notice of allowance" 属实(2024-09-25 发出),但该申请已于 2025-01-28 以 US 12,210,672 B2 授权,并于 2025-03-25 作出一份纯排印更正。以"待授权"看待此件已过时。**

同时顺带核到母案的对应事件:`"U.S. Appl. No. 17/301,655, Notice of Allowance mailed Jan. 20, 2023"`;以及 18/116,511 的两次驳回(Non-Final 2024-02-27、Final 2024-06-20)——即**这一族的续案是经过实质审查、两次驳回后才允许的**,不是一路放行。

---

## 4. 族谱与仍在申请中的续案

**Espacenet/INPADOC 同族规模:9 件申请 / 15 件公开(family id 082118660)。**

### 4.1 美国链(全部已授权,无已公开的在审续案)

| 编号 | 申请号 / 日期 | 状态 | 独立权项一句话要旨 |
|---|---|---|---|
| US 63/131,981 | 2020-12-30 | 临时申请(已失效,仅作优先权) | — |
| **US 11,662,805 B2** | 17/301,655 / 2021-04-09 | **授权 2023-05-30,在册** | 检测到 AR 应用**未**请求跟踪 → 在 HMD 上离线跑 VIO 求第一标定参数并存储 → 收到跟踪请求时取出并据以求第二标定参数 |
| ├ US 2022/0206565 A1 | 同上 | 授权前公开 (2022-06-30) | 同上申请态 |
| **US 12,210,672 B2** | 18/116,511 / 2023-03-02(续案) | **授权 2025-01-28,在册**(COC 2025-03-25) | 在 HMD 的 **offline** 估计中**周期性**更新第一标定参数 → 收到跟踪请求 → **切换 offline→online** 并以该值为 **starting point** 求第二参数 |
| ├ US 2023/0205311 A1 | 同上 | 授权前公开 (2023-06-29) | 同上申请态 |
| **US 12,704,900 B2** | 18/970,124 / 2024-12-05(续案的续案) | **授权 2026-08-11,在册** | 在 **wearable device** 检测到 **calibration trigger event** → 求存第一参数 → 收到跟踪请求 → 以该值为 starting point 求第二参数(去掉了 offline/periodic) |
| ├ US 2025/0093948 A1 | 同上 | 授权前公开 (2025-03-20) | 同上申请态 |

**是否还有在审的美国续案?**
- **已公开范围内:没有。** 两次独立检索——FPO 标题检索 `TTL/"periodic parameter estimation"`(命中 6 件,全部为上表 3 专利 + 3 公开)、FPO 摘要+申请人检索 `ABST/"visual-inertial tracking system" AND AN/"Snap"`(命中 12 件,按时间倒序最新为 US12704900,本族之外命中的是另两族 *Direct scale level selection…* 与 *Long term in-field IMU temperature calibration*)——均无第 4 件本族公开。Espacenet INPADOC 族表同样只列出上述三个美国申请号。
- **未公开范围:🔴 无法排除,且这是本次检索最大的盲区。** US 12,704,900 于 2026-08-11 授权;按 Snap 在本族的既有做法(每件授权前都递交一件续案:2023-03-02 在 `'805` 授权前、2024-12-05 在 `'672` 授权后不久),**极可能存在一件 2026 年年中递交、尚未公开的第四件续案**。该类申请通常在递交后 3–4 个月才公开(优先权已过 18 个月),即最早约 2026-10~12 才可见。**⇒ "本族在美国是否还有活链" 的答案是:证据上不确定,倾向于有。**

### 4.2 国际链(**有两条确实在审的分案**)

| 编号 | 申请号 | 状态(INPADOC 事件) |
|---|---|---|
| **WO 2022/146786 A1** | PCT/US2021/064608,2021-12-21 申请,2022-07-07 公开 | PCT 已进入国家阶段;`WO WWG — GRANT IN NATIONAL OFFICE (EP), 2025-09-24` |
| **EP 4,272,053 B1** | EP 21844571 | **已授权 2025-09-24**;`EP 26N — NO OPPOSITION FILED, 2026-09-02` ⇒ 异议期已过,在册 |
| ├ EP 4,272,053 A1 | 同上 | 申请公开 2023-11-08 |
| **EP 4,645,041 A2 / A3** | **EP 25203697(分案)** | 🔴 **在审**:A2 公开 2025-11-05,A3(检索报告版)2026-01-28,`EP 17P — REQUEST FOR EXAMINATION FILED, 2026-08-19` |
| **KR 10-2932214 B1** | KR 10-2023-7025816 | 已授权,`KR Q13 — IP RIGHT DOCUMENT PUBLISHED, 2026-03-03`(审查经过:2025-03-20 驳回通知,2025-05-19 答复) |
| ├ KR 10-2023-0122157 A | 同上 | 申请公开 2023-08-22 |
| **KR 10-2026-0036392 A** | **KR 10-2026-7005604(分案)** | 🔴 **在审**,`KR Q12 — APPLICATION PUBLISHED, 2026-03-16` |
| **CN 116830067 A** | CN 国家阶段 | 公开 2023-09-29;`CN SE01 — ENTRY INTO FORCE OF REQUEST FOR SUBSTANTIVE EXAMINATION, 2023-10-20`。**当前是否已授权 NOT RETRIEVED** |

**⇒ 活链结论:即便美国侧暂无可见的在审续案,EP 分案(EP25203697)与 KR 分案(KR10-2026-7005604)两条都还活着,权项仍可针对新产品改写。** 对只在中国大陆/美国出货的产品,EP/KR 分案不直接构成风险;但它们证明这一族**在被主动维护和扩张**。

---

## 5. 对照表:特征 (A) 的要素 vs 权项限定语

我方特征 (A) 的要素拆解:
- **E1** 单目 VIO(RD-VIO/XRSLAM 谱系),**手机**为主要载体
- **E2** 在**正常跟踪运行中**(online,应用正在请求位姿)
- **E3** **每固定 N 秒**(5/10/15s)触发
- **E4** 重解**一个小状态子集**:metric scale factor **s** + 2DoF 重力方向
- **E5** 其余地图固定不动
- **E6** 初始化时解出的 s 作为本次优化的初值(工程上自然如此)

| 权项限定语 | 出处 | E1 | E2 | E3 | E4 | E5 | E6 | 判定 |
|---|---|---|---|---|---|---|---|---|
| "at a **head-mounted device**"(每一步) | '805 cl.1/11/20;'672 cl.1/11/20 | ❌ 手机不是 HMD | | | | | | **落外**(若出货形态为手机) |
| "a **wearable device**" | '900 cl.1/11/20 | ❌ 手机通常不属 "wearable" | | | | | | **落外**(同上;**若将来做眼镜则此项失效**) |
| "detecting … that a virtual object display application … **is not requesting tracking operations**" | '805 cl.1/11/20 | | ❌ 我们正在跟踪 | | | | | **落外(最硬的一条)** |
| "**during an offline** calibration parameter estimation …, performed **after an online** calibration parameter estimation" | '672 cl.1/11/20 | | ❌ 我们全程 online | | | | | **落外(最硬的一条)** |
| "**periodically** updating … a first calibration parameter value" | '672 cl.1/11/20 | | | ✅ 字面吻合 | | | | **落内,但被上一行的 offline 限定救回** |
| "detecting a **calibration trigger event**" | '900 cl.1/11/20 | | | ⚠️ 定时器是否算 "trigger event"? | | | | **不确定**,见下 |
| "**in response to detecting the tracking request**, using … as a **starting point** for estimating a second …" | '672、'900 全部独立权项 | | | | | | ⚠️ | **落外** —— 我们不是"在收到跟踪请求那一刻"才把存值当起点 |
| "a first/second **calibration parameter value**"(泛指,未限定种类) | 三件全部独立权项 | | | | ⚠️ 可能被解释为涵盖 s 与 g | | | **最不安全的一条,见下** |
| "storing … in a **storage/memory of the** [HMD/wearable] **device**" | 三件全部独立权项 | | | | | | ⚠️ | 我们也会存,**落内**(非区别点) |
| 数值间隔(N 秒) | **任何权项中都没有** | | | ✅ 无对应限定 | | | | 不构成限制 |
| "scale factor" / "gravity direction" | **权项与说明书中都没有** | | | | ✅ | | | 不构成限制,但也不排除泛指解释 |
| 保持地图其余部分固定(E5) | **任何权项中都没有** | | | | | ✅ | | 不构成限制 |

### 最可能的设计回避点(按强度排序)

1. **🥇 "online vs offline" 这一刀。** `'805` 的 *"is not requesting tracking operations"* 与 `'672` 的 *"during an offline calibration parameter estimation … performed after an online calibration parameter estimation"* 都要求参数估计发生在**应用不在用跟踪的时候**。我们的 (A) 定义上就在 online 主回路里跑。**只要 (A) 不额外增加一条"应用空闲时再跑一遍"的支路,这两件就打不到。**
2. **🥈 载体限定。** 三件全部要求 head-mounted / wearable。**手机形态直接落外。** 🔴 **但这是形态依赖的**:一旦产品线延伸到 AR 眼镜,这条保护立刻消失,回退到第 1 条独撑。说明书 [0032] 确实把 "mobile computing device … smart phone" 列为设备举例,所以**不能指望说明书帮我们缩小"wearable"**——反过来讲,权项写的是 wearable 而说明书举了手机,这更像是审查中被迫加的窄化语,字面仍限 wearable。
3. **🥉 "as a starting point … in response to detecting the tracking request"。** `'672`/`'900` 都要求"跨越一次应用启动边界"把旧值传递过去。我们的 (A) 是同一 session 内的连续重优化,不跨这个边界。

### 需要律师重点看的两处不确定

- **⚠️ "calibration parameter value" 的解释范围。** 权项完全未限定参数种类。若被功能性地解释为"VIO 系统里任何需要标定/估计的量",metric scale 与重力方向**可能**被纳入。**反证材料(已固定):** 说明书全文 `gravity` **0 命中**、`scale`(尺度义)**0 命中**;说明书对该术语的全部举例是 extrinsics / intrinsics / IMU biases / frame bending / auto exposure —— 即**都是"传感器标定量",而 metric scale 与重力方向是"状态量/世界参考系量",不是传感器标定量**。这条区分是我们最好的说明书支撑,但**术语解释必须由律师做**。
- **⚠️ `'900` 的 "calibration trigger event" 是否涵盖"每 N 秒的定时器"。** `'900` claim 1 没有说 trigger 是什么;从属 4/5/6 才举例(sensor threshold、温度/加速度/电量、检测到被佩戴)——按 claim differentiation,独立权项的 "trigger event" **比这些例子宽**。一个周期性定时器**有可能**被读成 trigger event。**但 `'900` claim 1 仍另需"wearable device"+"in response to detecting the tracking request, using … as a starting point",我们两条都不满足。**

### 关于特征 (B)(ICE-BA 相对边缘化先验,g_k0 = R_k0 · g)

**本族三件专利的权项与说明书均未涉及边缘化先验、bundle adjustment、相对参考系存储等机制**(说明书 `bundle adjust` 0 命中)。⇒ **这一族对 (B) 无对应权项。** 🔴 但请注意:**本次检索范围仅限任务指定的 Snap 这一族,未对 (B) 做独立的专利检索**,因此"(B) 无专利风险"这个结论**本报告不提供**,需另做一次针对性检索(MagicLeap US11328475 "Gravity estimation and bundle adjustment for visual-inertial odometry" 一族此次亦不在检索范围内)。

---

## 6. 检索方法、取到与没取到的

**一手/准一手来源(claim 文本经两个独立来源逐字比对一致):**
- USPTO 官方授权件 PDF:`image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/{11662805|12210672}`(影像版,无文字层;COC 页经渲染后肉眼核读)
- FreePatentsOnline(`freepatentsonline.com/{11662805|12210672|12704900}.html`)—— 权项与著录项目
- PatentGuru(`patentguru.com/US{11662805|12210672|12704900}B2`)—— **独立第二源,权项逐字一致**(包括 `'805` claim 1 末尾原文中的排印错误 *"the **virtual**-inertial tracking system"* 两源同样出现,可作保真度校验)
- Espacenet / EPO INPADOC(浏览器渲染)—— 同族 9 申请 15 公开、逐件法律事件、各国状态

**NOT RETRIEVED(及尝试记录):**
| 缺口 | 尝试过 | 结果 |
|---|---|---|
| USPTO **continuity data**(有无第 4 件在审续案) | `patentcenter.uspto.gov/retrieval/public/v{1,2,3}/application/data?applicationNumberText=18970124`;真实浏览器打开 Patent Center 应用页 | **接口对任何方法返回 405**,连 Patent Center 自己的前端都拿不到数据(已在浏览器 network 面板确认三个 v3 请求全部 405)⇒ 上游接口故障/封锁,非本地问题 |
| **实际年费缴纳记录** | `fees.uspto.gov/MaintenanceFees/fees/details`(Akamai 挑战,HTTP 202 空体)、`bulkdata.uspto.gov` MaintFeeEvents(DNS 不可解析)、`api.uspto.gov` ODP(401,需 API key)、PatentsView(已迁移至需 key 的 ODP) | 全部失败。**替代证据**:INPADOC 事件表中 `'805` 授权后无 MAFP 事件 + 按授权日推算首笔年费窗口至 2026-11-30 才截止 ⇒ 可确定"尚未失效",但"是否已缴"未取到 |
| **PTA / terminal disclaimer** | 仅可从授权件首页取,而 USPTO PDF 无文字层 | 未 OCR;**名义届满日 2041-04-09 为按 20 年推算,未计 PTA** |
| Google Patents 的 Events / Also-published-as | `patents.google.com` 直连与浏览器两路 | **持续 503 "Sorry" 反爬** + 浏览器端 `/patent/US12704900B2/en` 返回 404(Google 尚未收录该 2026-08 授权件)⇒ 改由 Espacenet 取得同等信息 |
| CN 116830067 A 当前法律状态 | INPADOC 仅到 2023-10-20 实审生效 | 未进一步查 CNIPA |

---

## 7. 免责声明

**本文件是事实搜集(fact-gathering),不是法律意见,也不构成 freedom-to-operate 结论或侵权/不侵权判断。** 上文所有"落内/落外/设计回避点"的标注,只是把我方拟建特征的要素与权项的字面限定语做**逐词对照的事实陈列**,**不代表任何权项解释结论**。权项解释(claim construction)、等同原则(doctrine of equivalents)、审查历史禁反言(prosecution history estoppel)、间接侵权、以及未公开在审续案的潜在权项范围,**必须由持证专利律师基于完整的审查档案(file wrapper)判断**。特别提示三点:(1) 美国侧很可能存在一件尚未公开、因而本次检索不可见的第四件续案;(2) 产品形态若从手机延伸到头戴/可穿戴设备,本报告中最强的一条区别点立即失效;(3) "calibration parameter value" 一词未经任何权项内定义,其解释范围是本族对我方的主要不确定性来源。

**Sources:** [FreePatentsOnline US11662805](https://www.freepatentsonline.com/11662805.html) · [FreePatentsOnline US12210672](https://www.freepatentsonline.com/12210672.html) · [FreePatentsOnline US12704900](https://www.freepatentsonline.com/12704900.html) · [PatentGuru US11662805B2](https://www.patentguru.com/US11662805B2) · [USPTO PDF US11662805](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11662805) · [USPTO PDF US12210672](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12210672) · [Espacenet US11662805B2 (INPADOC family / legal events)](https://worldwide.espacenet.com/patent/search?q=pn%3DUS11662805) · [USPTO Patent Center](https://patentcenter.uspto.gov/) · [USPTO Maintain your patent](https://www.uspto.gov/patents/maintain)

---

# 附录 B:百度 ICE-BA 中国专利 + Snap 中国同族事实搜集报告(检索 agent 原文,原样附上)

> 来源文件:`docs/research/patent_fto_baidu_iceba_cn_20260923.md`(commit `7d9e49c`)。同样,其中的「风险高/中/低」只是分诊标签。

<!-- 来源:专利事实搜集 agent 最终报告,原样落盘(2026-09-23)。本文件是事实搜集,不是法律意见。
     主会话复核(Google Patents 浏览器渲染):CN108592919B 权 1 与权 5 逐字一致;Status Active,
     Anticipated expiration 2038-04-27;Worldwide applications 仅 2018 CN 一件;GR01 2019-09-17。
     主会话对照我们自己的代码:/Users/kaidongwang/Developer/xrslam/xrslam/src 下
     grep global_BA|loop_closure|pose_graph|global_optim 零命中,localizer/ 是 httplib+json 远程定位客户端,
     ⇒ 我们没有全局集束调整;权 1 要求的「相对约束…用于在全局集束调整中优化」在我们系统里无对应物。
     这只是逐要素的事实对照,是否构成不落入由律师判断。 -->

# 专利 FTO 事实搜集报告（非法律意见）

## 0. 检索说明与失败项

| 源 | 结果 |
|---|---|
| Google Patents（浏览器真实渲染） | ✅ 取得全文/权项/法律事件 |
| CNIPA 中国专利公布公告 `epub.cnipa.gov.cn`（高级查询 + 事务查询） | ✅ 取得著录项与官方事务数据 |
| Espacenet | ❌ **未取得** — Cloudflare「Performing security verification」人机验证墙，我不绕过 |
| patenthub.cn / baiten.cn / patentguru | ❌ **未取得** — 登录墙 / HTTP 468 / 404 |
| Google Patents（curl + WebFetch 直连） | ❌ 503 / "Sorry..." 机器人拦截；改用浏览器渲染绕过 |

法律状态均取得**两个独立源**（Google Patents 法律事件 + CNIPA 官方事务数据）。

> ⚠️ **Google Patents 的 "Current Assignee" 字段不可信**：它把三件都归一成 "Beijing Baidu Netcom Science and Technology Co Ltd"（北京百度网讯），而 **CNIPA 官方著录项为「百度在线网络技术（北京）有限公司」**。以 CNIPA 为准。

> ⚠️ **公式类权项无法逐字复现**：Google Patents 把数学公式渲染成图片，CN108572939B 的权 4/6/7/11/13/14 含公式，文本层有缺口。**但四项独立权项（1/8/15/16）均不含公式，可逐字复现。** CN108592919B 全部权项无公式。

---

## 1. 一句话结论

**上一轮调研认错了号：CN108572939 不是相对边缘化那件**——它是「增量式 BA 求解器」（重新线性化 → 法向方程增量更新 → 舒尔补增量更新 → PCG 求解），权项里没有一个字涉及参考坐标系或重力相对化；**真正逐字对口「相对边缘化」的是同日同发明人的姊妹件 CN108592919B（申请公布时标题就叫《相对边缘化的制图与定位方法》），已授权、在有效期内、CN 独苗无海外同族**，其授权权 1 正面覆盖「边缘化时把参考坐标系调整为移出的首帧」，从权 5/13 进一步覆盖「以首帧为参考系调整重力方向并施加重力约束」= 我们想抄的 `g_k0 = R_k0·g`。就事实而言**风险等级：高（仅限中国大陆）**——理由是权项文义与我们拟实现的机制高度重合、专利有效、且我们在中国出货；此处「高/中/低」是事实分诊信号，不是侵权判断（侵权判断需逐特征比对我们的实际实现并由律师做）。

---

## 2. CN108572939（原目标件）完整著录项 + 法律状态 + 独立权项全文

### 2.1 号码归属辨析

| 项目 | 值 |
|---|---|
| 申请号 | **CN201810391851.1 → 不是本件**；本件申请号 **201810390462.7**（CNIPA 无点写法 `2018103904627`） |
| 申请公布号 | **CN108572939A**，申请公布日 **2018.09.25** |
| 授权公告号 | **CN108572939B**，授权公告日 **2020.05.08** |

→ `CN108572939` 既有 A（申请公布）也有 B（授权公告），属同一申请的两个公布文献号。

### 2.2 著录项（源：CNIPA 高级查询 + Google Patents）

| 项目 | 值 |
|---|---|
| 中文标题 | **VI-SLAM的优化方法、装置、设备及计算机可读介质** |
| 英文标题（Google 机译） | VI-SLAM optimization method, device, equipment and computer readable medium |
| 申请人／专利权人 | **百度在线网络技术（北京）有限公司** |
| 地址 | 100085 北京市海淀区上地十街10号百度大厦三层 |
| 发明人 | **刘浩敏；陈明裕；包英泽；王志昊** |
| 申请日 | 2018-04-27 |
| 优先权日 | 2018-04-27（本国首次申请，无在先优先权） |
| 分类号 | G06F17/11(2006.01)I |
| 预计届满 | 2038-04-27 |

### 2.3 法律状态：**已授权、未见终止**

**源 ①　CNIPA 官方事务数据**（申请号 2018103904627，数据截止 1985.09.10–2026.09.22）：

| 序号 | 事务数据公告日 | 事务数据 |
|---|---|---|
| 1 | 2020.05.08 | **授权** |
| 2 | 2018.10.26 | 实质审查的生效 |
| 3 | 2018.09.25 | 公布 |

**源 ②　Google Patents Legal Events**：PB01 2018-09-25 公布 / SE01 2018-10-26 实审生效 / **GR01 2020-05-08 专利权授予**；Status: **Active**。

→ 两源一致：**无「未缴年费专利权终止」「视为撤回」「驳回」「放弃」任何一条**。
→ ⚠️ 口径限制：CNIPA 事务数据只反映**已在公报公布**的事务；「是否此刻实际在册有效」的权威凭据是**专利登记簿副本**，非公开可检，**未取得**。

### 2.4 独立权项全文（**授权公告文本 CN108572939B**，逐字）

> 以下为**授权文本**，非申请公布文本。授权时权 1 已被**修改收窄**（把申请文本原权 4 的「构造优化方程」步骤和原权 5 的「重新线性化触发条件」并入了权 1）。全案 16 项，独立权项为 **1、8、15、16**。

**权利要求 1（方法）**
> 1.一种VI-SLAM的优化方法，其特征在于，包括：
> 如果发生变化的观测量满足更新条件，则根据发生变化的观测量对集束调整的优化方程中的观测方程进行重新线性化；
> 根据重新线性化后的观测方程，对法向方程进行增量式更新；
> 根据更新后的法向方程，对舒尔补方程进行增量式更新；
> 采用预条件共轭梯度法对更新后的舒尔补方程进行增量式求解，获得观测量的最优解；
> 一组观测量包括一组相机参数和一个三维点坐标，所述方法还包括：
> 根据多组观测量构造集束调整的优化方程，所述优化方程中的每个观测方程关联一组相机参数和一个三维点坐标；
> 所述如果发生变化的观测量满足更新条件，则根据发生变化的观测量对集束调整的优化方程中的观测方程进行重新线性化的步骤，包括：
> 当相机参数差异|C<sub>i</sub>|大于设定阈值、三维点坐标差异|X<sub>j</sub>|大于设定阈值或接收到最新一帧的观测量作为增量时，重新线性化观测方程。

**权利要求 8（装置）**
> 8.一种VI-SLAM的优化装置，其特征在于，包括：
> 重新线性化模块，用于如果发生变化的观测量满足更新条件，则根据发生变化的观测量对集束调整的优化方程中的观测方程进行重新线性化；
> 法向方程更新模块，用于根据重新线性化后的观测方程，对法向方程进行增量式更新；
> 舒尔补方程更新模块，用于根据更新后的法向方程，对舒尔补方程进行增量式更新；
> 求解模块，用于采用预条件共轭梯度法对更新后的舒尔补方程进行增量式求解，获得观测量的最优解；
> 一组观测量包括一组相机参数和一个三维点坐标，所述装置还包括：
> 优化方程构造模块，用于根据多组观测量构造集束调整的优化方程，所述优化方程中的每个观测方程关联一组相机参数和一个三维点坐标；
> 所述重新线性化模块具体用于当相机参数差异|C<sub>i</sub>|大于设定阈值、三维点坐标差异|X<sub>j</sub>|大于设定阈值或接收到最新一帧的观测量作为增量时，重新线性化观测方程。

**权利要求 15（设备）**
> 15.一种用于VI-SLAM的优化设备，其特征在于，所述设备包括：
> 一个或多个处理器；
> 存储装置，用于存储一个或多个程序；
> 当所述一个或多个程序被所述一个或多个处理器执行时，使得所述一个或多个处理器实现如权利要求1-7中任一所述的VI-SLAM的优化方法。

**权利要求 16（介质）**
> 16.一种计算机可读介质，其存储有计算机程序，其特征在于，该程序被处理器执行时实现如权利要求1-7中任一所述的VI-SLAM的优化方法。

### 2.5 它到底覆盖什么 —— **不是相对边缘化**

权项覆盖的是 **ICE-BA 论文的第一项贡献（增量式 BA 求解器）**：
- 观测量变化超阈值 → **局部重新线性化**
- 法向方程 `U/V/W/u/v` 的**增量式加减更新**（不重建）
- 舒尔补 `S/s` 的**增量式更新**
- **PCG** 求解（从权 2：预条件子为**对角带状子矩阵 B**；从权 3：上次迭代结果做本次初值）

**权项全文零命中**：`边缘化`、`参考坐标系`、`重力`、`先验约束`、`关键帧`、`滑动窗口`。
它与「相对边缘化」是 ICE-BA 论文里**两项分开的贡献**，百度也把它们拆成了**两件分开的专利申请**。所以上一轮标记本件为 "major hit" 是**关键词误命中**（命中的是 "VI-SLAM" + "bundle adjustment"，不是机制）。

### 2.6 同族：**CN 独苗**

Google Patents `Worldwide applications: 2018 CN`，family country_status = `CN:ACTIVE` 仅此一条。
**无 US / EP / WO / JP / KR 同族。** 优先权项只有 CN201810390462.7 自身，未做 PCT，未进任何外国国家阶段。
→ 域外零效力；**但我们在中国大陆出货，CN 本身就足够构成约束。**

---

## 3. 🔴 真正对口的那件：**CN108592919B《制图与定位方法、装置、存储介质和终端设备》**

### 3.1 为什么之前没被抓到

申请公布时标题为 **《相对边缘化的制图与定位方法、装置、存储介质和终端设备》**，**授权时标题里的「相对边缘化的」被删掉了**（授权公告标题为《制图与定位方法…》）。按授权标题做关键词检索会漏掉它。

我用 **权项字段限定检索** `CL=("边缘化") & assignee=百度` 把它逼了出来（全库仅 4 命中，见 §5）。

### 3.2 著录项（源：CNIPA 高级查询，逐字）

| 项目 | 值 |
|---|---|
| 授权公告号 | **CN108592919B**，授权公告日 **2019.09.17** |
| 申请公布号 | **CN108592919A**，申请公布日 **2018.09.28** |
| 申请号 | **2018103918511**（即 201810391851.1） |
| 申请日／优先权日 | **2018.04.27**（与 CN108572939 同日申请） |
| 专利权人 | **百度在线网络技术（北京）有限公司** |
| 地址 | 100085 北京市海淀区上地十街10号百度大厦三层 |
| 发明人 | **刘浩敏；陈明裕；包英泽；范一舟** |
| 分类号 | G01C21/20(2006.01)I |
| 预计届满 | 2038-04-27 |

### 3.3 法律状态：**已授权、未见终止**

**源 ①　CNIPA 官方事务数据**（2018103918511）：

| 序号 | 事务数据公告日 | 事务数据 |
|---|---|---|
| 1 | 2019.09.17 | **授权** |
| 2 | 2018.10.26 | 实质审查的生效 |
| 3 | 2018.09.28 | 公布 |

**源 ②　Google Patents**：PB01 2018-09-28 / SE01 2018-10-26 / **GR01 2019-09-17**；`Legal status: Active`；`Granted patent for invention`。

→ 两源一致，**无终止/撤回/驳回事务**。登记簿副本同样**未取得**（不公开）。

### 3.4 同族：**CN 独苗**

`Worldwide applications: 2018 CN`，family = `CN:ACTIVE` 一条。**无 US / EP / WO / JP 同族。**

### 3.5 独立权项全文（**授权公告文本 CN108592919B**，逐字）

> 全案 15 项，独立权项为 **1、9、14、15**。以下为授权文本，非申请公布文本。

**权利要求 1（方法）— 这条就是「相对边缘化」**
> 1.一种制图与定位方法，其特征在于，包括：
> 接收采集到的图像帧，并将所述图像帧加入图像帧序列的尾端；
> 控制本地集束调整的滑动窗口沿所述图像帧序列向后移动一帧以移出首帧以及移入尾帧；其中，所述首帧用于表示在移出所述首帧前所述滑动窗口中的最早帧；所述尾帧用于表示所述图像帧序列中未曾移入所述滑动窗口的最早帧；
> 判断所述首帧是否为关键帧；
> 当所述首帧为关键帧时，根据所述首帧的运动状态和约束因子进行边缘化处理，生成相对约束和下一首帧的先验约束，**并在生成所述下一首帧的先验约束的过程中调整所述边缘化处理的参考坐标系为所述首帧**；其中，所述运动状态用于描述拍摄到所述首帧时摄像机的运行；所述约束因子包括所述首帧的先验约束；所述相对约束用于在全局集束调整中优化从所述滑动窗口中移出的所有关键帧观察到场景三维结构；以及所述先验约束用于在所述本地集束调整中优化所述滑动窗口中的图像帧观察到场景三维结构。

*（粗体为我所加，用于定位，原文无强调）*

**权利要求 9（装置）**
> 9.一种制图与定位装置，其特征在于，包括：
> 图像帧采集模块，用于接收采集到的图像帧，并将所述图像帧加入图像帧序列的尾端；
> 滑动窗口移动模块，用于控制本地集束调整的滑动窗口沿所述图像帧序列向后移动一帧以移出首帧以及移入尾帧；其中，所述首帧用于表示在移出所述首帧前所述滑动窗口中的最早帧；所述尾帧用于表示所述图像帧序列中未曾移入所述滑动窗口的最早帧；
> 关键帧判断模块，用于判断所述首帧是否为关键帧；
> 第一约束生成模块，用于当所述首帧为关键帧时，根据所述首帧的运动状态和约束因子进行边缘化处理，生成相对约束和下一首帧的先验约束，并在生成所述下一首帧的先验约束的过程中调整所述边缘化处理的参考坐标系为所述首帧；其中，所述运动状态用于描述拍摄到所述首帧时摄像机的运动；所述约束因子包括所述首帧的先验约束；所述相对约束用于在全局集束调整中优化从所述滑动窗口中移出的所有关键帧观察到场景三维结构；以及所述先验约束用于在本地集束调整中优化所述滑动窗口中的图像帧观察到场景三维结构。

**权利要求 14（终端设备）**
> 14.一种制图与定位的终端设备，其特征在于，所述终端设备包括：
> 一个或多个处理器；
> 存储装置，用于存储一个或多个程序；
> 当所述一个或多个程序被所述一个或多个处理器执行时，使得所述一个或多个处理器实现如权利要求1-8中任一所述的制图与定位方法。

**权利要求 15（介质）**
> 15.一种计算机可读存储介质，其存储有计算机程序，其特征在于，该程序被处理器执行时实现如权利要求1-8中任一所述的制图与定位方法。

### 3.6 重力相对化在哪一条 —— **从权 5（及对应装置从权 13）**

这条是**从属权利要求**，不是独立权项，但它逐字覆盖了我们想抄的 `g_k0 = R_k0·g`：

> 5.如权利要求4所述的制图与定位方法，其特征在于，**所述运动状态还包括重力方向**；以及当所述首帧为关键帧时生成所述下一首帧的先验约束的过程包括：
> 对所述首帧的相机方位、重力方向和先验约束以及用于约束所述首帧的相机方向的视觉约束进行边缘化处理，生成用于约束所述首帧的惯量测量参数的间接约束；
> **以所述首帧为所述参考坐标系调整所述滑动窗口内的图像帧的相机方位和重力方向，并对所述重力方向设置重力约束**；以及
> 对生成的间接约束、设置的重力约束、所述首帧的惯量测量参数以及用于约束所述首帧与所述下一首帧两者的运动状态的惯量约束进行边缘化处理，生成所述下一首帧的先验约束。

摘要（**法律上无约束力，仅作定位**）自述目的：「采用本发明，能够避免边缘化处理产生的先验约束的误差不断累积。」

### 3.7 与 ICE-BA 论文的对应关系（事实陈述）

ICE-BA 仓库 README 原话把论文贡献列为两条，第二条是：a new relative marginalization algorithm that resolves the conflicts between sliding window marginalization bias and global loop closure constraints。
→ CN108592919 = 这一条；CN108572939 = 前一条（10× 效率的增量求解器）。两件**同日申请、同一批发明人**。

---

## 4. 【追加】Snap **CN116830067A**《周期性参数估计视觉惯性跟踪系统》

### 4.1 著录项（源：CNIPA 高级查询 + Google Patents）

| 项目 | 值 |
|---|---|
| 申请公布号 | **CN116830067A**，申请公布日 **2023.09.29** |
| **授权公告号** | **不存在** |
| 申请号 | **2021800882768**（即 CN202180088276.8） |
| 申请日 | 2021.12.21（PCT/US2021/064608 进入中国国家阶段） |
| 申请人 | **斯纳普公司**（Snap Inc.），地址：美国加利福尼亚州 |
| 发明人 | 耶奥里·哈尔梅特施拉格-富涅克；马蒂亚斯·卡尔格鲁伯；丹尼尔·沃尔夫；雅各布·齐尔纳 |
| 优先权链 | US 63/131,981（2020-12-30 临时）→ US 17/301,655（2021-04-09）→ PCT/US2021/064608（2021-12-21） |
| 分类号 | G06F3/0346(2006.01)I |

### 4.2 当前法律状态：**仍在实审，未授权**

**源 ①　CNIPA 官方事务数据**（2021800882768）：

| 序号 | 事务数据公告日 | 事务数据 |
|---|---|---|
| 1 | 2023.10.20 | 实质审查的生效 |
| 2 | 2023.09.29 | 公布 |

**源 ②　Google Patents**：PB01 2023-09-29 / SE01 2023-10-20；`Legal status: **Pending**`。

**源 ③（交叉验证）**　CNIPA 高级查询四类型（发明公布/发明授权/实用新型/外观设计）全勾选检索申请号 2021800882768 → **只返回 [发明公布] 一条记录，无 [发明授权] 记录** ⇒ 独立确认 B 公布文本不存在。

→ **结论：既非授权、亦非驳回、亦非视为撤回 —— 截至 CNIPA 数据日 2026.09.22 仍卡在实审阶段**（SE01 后已近 3 年无新事务公告）。
→ ⚠️ CNIPA 事务数据只反映**已公布**的事务；审查过程中的 OA、答复、主动修改**不在此系统**（需 CPQuery「中国及多国专利审查信息查询」，需实名登录，**未取得**）。

### 4.3 独立权项全文（**申请公布文本 CN116830067A**，逐字）

> ⚠️ **必须标明：这是申请公布文本（进入国家阶段时的权项），不是授权文本 —— 因为本件尚无授权文本。** 权项可能在后续实审中被修改。全案 20 项，独立权项为 **1、11、20**。

**权利要求 1（方法）**
> 1.一种用于校准视觉惯性跟踪系统的方法，所述方法包括：
> 在设备处操作所述视觉惯性跟踪系统，而不接收来自虚拟对象显示应用的跟踪请求；
> 响应于操作所述视觉惯性跟踪系统，访问来自所述设备的多个传感器的传感器数据；
> 基于所述传感器数据来识别所述视觉惯性跟踪系统的第一校准参数值；
> 存储所述第一校准参数值；
> 检测从所述虚拟对象显示应用到所述视觉惯性跟踪系统的跟踪请求；以及
> 响应于检测到所述跟踪请求，访问所述第一校准参数值并且根据所述第一校准参数值确定第二校准参数值。

**权利要求 11（计算装置）**
> 11.一种计算装置，包括：
> 处理器；以及
> 存储指令的存储器，所述指令在由所述处理器执行时将所述装置配置成执行操作，所述操作包括：
> 在设备处操作视觉惯性跟踪系统，而不接收来自虚拟对象显示应用的跟踪请求；
> 响应于操作所述视觉惯性跟踪系统，访问来自所述设备的多个传感器的传感器数据；
> 基于所述传感器数据来识别所述视觉惯性跟踪系统的第一校准参数值；
> 存储所述第一校准参数值；
> 检测从所述虚拟对象显示应用到所述视觉惯性跟踪系统的跟踪请求；以及
> 响应于检测到所述跟踪请求，访问所述第一校准参数值并且根据所述第一校准参数值确定第二校准参数值。

**权利要求 20（介质）**
> 20.一种非暂态计算机可读存储介质，所述计算机可读存储介质包括指令，所述指令在由计算机执行时使所述计算机执行操作，所述操作包括：
> 在设备处操作视觉惯性跟踪系统，而不接收来自虚拟对象显示应用的跟踪请求；
> 响应于操作所述视觉惯性跟踪系统，访问来自所述设备的多个传感器的传感器数据；
> 基于所述传感器数据来识别所述视觉惯性跟踪系统的第一校准参数值；
> 存储所述第一校准参数值；
> 检测从所述虚拟对象显示应用到所述视觉惯性跟踪系统的跟踪请求；以及
> 响应于检测到所述跟踪请求，访问所述第一校准参数值并且根据所述第一校准参数值确定第二校准参数值。

### 4.4 🎯 **最有用的那个对比：CN 公布权项 vs US 授权权项**

为使对比有据，我同时取回了美国母案 **US11662805B2** 的**授权**权 1（Google Patents，英文原文）：

> 1. A method for calibrating a visual-inertial tracking system comprising:
> detecting, at a **head-mounted device**, that a virtual object display application that is configured to operate at the head-mounted device is **not requesting tracking operations** from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operating, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors **only at** the head-mounted device;
> identifying, at the head-mounted device, a first calibration parameter value … based on the sensor data from the plurality of sensors **only at** the head-mounted device;
> storing, **in a storage of the head-mounted device**, the first calibration parameter value;
> detecting an operation of the virtual object display application at the head-mounted device by detecting a tracking request …; and
> in response to detecting the tracking request, accessing, **at the storage of the head-mounted device**, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value …

**逐项比对表：**

| 限定 | US11662805B2（**授权**权1） | CN116830067A（**公布**权1/11/20） |
|---|---|---|
| **载体限定「头戴式/可穿戴」** | ✅ **有**，`head-mounted device` 在权 1 中出现 **8 次**，几乎每个步骤都绑死 | ❌ **无** —— 只有中性的「**在设备处**」。全部三条独立权项中 **「头戴式设备」「可穿戴设备」零命中** |
| **离线／「未请求跟踪」限定** | ✅ 有，`is **not requesting** tracking operations` | ✅ **有**，「**而不接收来自虚拟对象显示应用的跟踪请求**」，**三条独立权项全部携带** |
| **传感器「仅在本机」限定** | ✅ 有，`only at the head-mounted device`（2 处） | ❌ **无**，仅「来自所述设备的多个传感器」 |
| **存储位置限定** | ✅ 有，`in a storage of the head-mounted device` | ❌ **无**，仅「存储所述第一校准参数值」（从权 10 才把存储位置列为「设备的存储设备中**或服务器处**」） |

**事实要点：**
1. **中国这一支目前的权项文本比美国授权权项宽**——载体、"仅本机传感器"、"本机存储" 三道收窄在 CN 公布文本里**全都不存在**，只有「离线/未请求跟踪」这一道留着。
2. 但这是**进入国家阶段的原始权项**，SE01 至今近 3 年未出授权公告，**实审可能已经或将要收窄**，公开渠道看不到 OA。所以「CN 会不会最终拿到和公布文本一样宽的权项」**未知**。
3. 「佩戴」一词在 CN 文本中**只出现在从权 4 / 14**，作为触发事件的**可选项之一**（「…或者检测到所述设备被用户佩戴」），**不构成载体限定**。
4. 同族另有美国延续案 **US12210672B2**（2025-01-28 授权）和 **US20250093948A1**（在审），说明 Snap 在美国这条线仍在扩权；但这些**对中国无效力**。

---

## 5. 百度在「增量 BA / 边缘化 / 相对位姿先验」上的更广专利暴露面

方法：在 Google Patents 上做**权项字段限定**检索（`CL=` 只搜权利要求书，避开说明书噪声），assignee 限定百度全系（百度在线 / 北京百度网讯 / 百度时代 / 百度（美国））。

### 5.1 `CL=("边缘化") & assignee=百度` — **全库仅 4 命中**

| 号 | 标题 | 状态 | 同族 | 权项主旨（一句话） | 是否读到相对边缘化 |
|---|---|---|---|---|---|
| **CN108592919B** | 制图与定位方法…（公布时名：**相对边缘化的**制图与定位方法） | **有效**（授权 2019-09-17） | **CN only** | 滑窗移出首帧→若为关键帧则边缘化生成相对约束+先验约束，**并把边缘化参考系调整为首帧** | 🔴 **正面命中** |
| **CN108564625B** | 图优化方法、装置、电子设备及存储介质 | **有效**（授权 2019-08-23） | **CN only** | 把 SLAM 待优化图中的**三维点节点复制成多个第三节点**、设边权使能量等价、再**边缘化第三节点**以降低待解线性方程系数矩阵的稠密度 | ❌ **不命中**（是稀疏化技巧，与参考系/重力无关；发明人刘浩敏，与上两件同日 2018-04-27 申请） |
| CN114492831B | 联邦学习模型的生成方法 | 有效 | EP:失效, US:失效, CN:有效 | 联邦学习，与 SLAM 无关 | ❌ |
| CN112907518B | 检测方法、装置、设备… | 有效 | CN only | 与 SLAM 无关 | ❌ |

### 5.2 `CL=("集束调整") & assignee=百度` — **全库仅 3 命中**

| 号 | 标题 | 状态 | 同族 | 主旨 |
|---|---|---|---|---|
| CN108592919B | 制图与定位方法… | 有效 | CN only | 同上（🔴） |
| CN108572939B | VI-SLAM的优化方法… | 有效 | CN only | 增量式 BA 求解器 |
| CN112055805B | 用于自动驾驶车辆的点云登记系统 | 有效 | **WO/EP/US/CN/JP/KR** | 激光点云配准，非 VIO 边缘化 |

### 5.3 `CL=("增量式") & assignee=百度` — 4 命中，SLAM 相关仅 **CN108572939B**（其余为对话系统、OCR、项目开发）

### 5.4 刘浩敏在百度名下全部专利（`inventor=刘浩敏 & assignee=百度`，共 6 件）

| 号 | 标题 | 授权日 | 同族 | 与本议题关系 |
|---|---|---|---|---|
| **CN108592919B** | 制图与定位方法（相对边缘化） | 2019-09-17 | CN | 🔴 核心 |
| **CN108564625B** | 图优化方法 | 2019-08-23 | CN | 🟡 同批，节点复制+边缘化稀疏化 |
| **CN108572939B** | VI-SLAM的优化方法 | 2020-05-08 | CN | 🟡 同批，增量 BA |
| CN111094895B | 预构建视觉地图中稳健自重定位的系统和方法（百度时代/Baidu USA，发明人陈明裕） | 2023-08-22 | **US:ACTIVE, CN:ACTIVE, WO:失效** | ⚪ 重定位，非边缘化；**唯一有美国同族的一件** |
| CN108961423B | 虚拟信息处理方法（第一发明人黄晓鹏） | 2023-04-18 | CN | ⚪ 无关 |
| CN109035303B | SLAM系统的相机跟踪方法（第一发明人李晨） | 2021-06-08 | CN | ⚪ 前端跟踪 |

**结论性事实**：百度在「边缘化 / 集束调整」上的**权项级**暴露面极窄——就是 **2018-04-27 同日申报的那三件（'919 / '625 / '939）**，三件**全部 CN 独苗、全部有效**。域外零暴露。

### 5.5 第三方「相对边缘化」检索（全库 `"相对边缘化"` 精确短语）

仅 2 条真实相关：
- **CN108592919A**（百度，本报告主角）
- **CN114387342A**《一种基于相对边缘化的orbslam3的优化算法》—— 上海师范大学，公布 2022-04-22，CN only。第三方学术申请，**未核其权项与法律状态**（超出本次范围）。

---

## 6. Apache-2.0 §3 的事实基础（只报事实）

Apache-2.0 §3 的专利许可从 **"Each Contributor"** 流出，且限于 "their Contribution(s) alone or by combination of their Contribution(s) with the Work"。因此关键事实是：**专利权人（百度）与仓库贡献者是不是同一主体。** 以下是取得的事实。

### 6.1 仓库事实（github.com/baidu/ICE-BA，GitHub API 实取）

| 项目 | 事实 |
|---|---|
| 仓库归属 | GitHub **Organization `baidu`**（org id 13245940），`fork: false` |
| 创建 / 最后推送 | 2018-03-19 / 2018-09-12 |
| 许可证 | **Apache-2.0**（SPDX 确认） |
| `LICENSE` 版权行（逐字） | **`Copyright 2017-2018 Baidu Robotic Vision Authors. All Rights Reserved.`**（出现在文件首行及 Appendix 样板处） |
| 源文件头（如 `Backend/BundleAdjustment/GlobalBundleAdjustor.cpp`） | `Copyright 2017-2018 Baidu Robotic Vision Authors. All Rights Reserved.` + 标准 Apache-2.0 样板 |
| `NOTICE` | **不存在（HTTP 404）** |
| `AUTHORS` / `CONTRIBUTORS` / `CONTRIBUTING.md` | **全部不存在（404）** |
| **`PATENTS` 文件** | **不存在（404）** —— 即**没有**类似 Facebook/Google 风格的额外专利授予或撤销条款文件 |
| README 署名 | **Authors: Haomin Liu, Mingyu Chen, Yingze Bao, Zhihao Wang** |

### 6.2 提交者身份与单位邮箱（git 历史，共 13 次提交）

| 登录名 | git author | 邮箱 | 提交数 |
|---|---|---|---|
| `liuhaomin` | liuhaomin | **liuhaomin@baidu.com** | 1 |
| `mingyux` | **Mingyu Chen** | **chenmingyu01@baidu.com** | 1 |
| `wangjio` | wangzhihao05 / wangjio | **wangzhihao05@baidu.com**（另有 wzh758@126.com） | 6 |
| `kiyology` | kiyology | 43614037@qq.com | 4 |
| `zhoukaidev` | Kai Zhou | zhoukaisspu@163.com | 1 |

### 6.3 专利权人事实（CNIPA 官方著录项）

| 件 | 专利权人 | 发明人 |
|---|---|---|
| CN108572939B | **百度在线网络技术（北京）有限公司** | 刘浩敏；陈明裕；**包英泽；王志昊** |
| CN108592919B | **百度在线网络技术（北京）有限公司** | 刘浩敏；陈明裕；包英泽；范一舟 |
| CN108564625B | **百度在线网络技术（北京）有限公司** | 刘浩敏（第一发明人） |

### 6.4 两者的重合关系（事实并列，不作结论）

- **CN108572939 的四名发明人 = README 署名的四位作者**，一一对应：刘浩敏=Haomin Liu、陈明裕=Mingyu Chen、包英泽=Yingze Bao、王志昊=Zhihao Wang。
- 其中 **刘浩敏、陈明裕、王志昊 三人以 `@baidu.com` 邮箱直接向该仓库提交过代码**；包英泽在 git 历史中**未见**提交记录。
- 仓库托管在 **`baidu` GitHub 组织**下，版权归属声明为 "Baidu Robotic Vision Authors"。
- 专利权人是 **百度在线网络技术（北京）有限公司**。
- ⚠️ **未取得的事实**：「百度在线网络技术（北京）有限公司」这一**法人实体**与 GitHub `baidu` 组织、与 LICENSE 中 "Baidu Robotic Vision Authors" 这一措辞之间的**法律对应关系**，公开渠道无从核实。百度集团在专利上至少使用四个不同法人（百度在线、北京百度网讯、百度时代、百度（美国）），本仓库的代码著作权究竟落在哪一个，**仓库里没有任何文件写明**（无 NOTICE、无 CLA、无 CONTRIBUTING）。
- ⚠️ 另需注意：**CN108592919 的第四发明人范一舟不在 README 署名之列**，而 README 署名的王志昊不在 '919 发明人之列——即「相对边缘化」这件的发明人集合与开源仓库的署名集合**并不完全重合**。

**以上为事实罗列。§3 的许可是否及于我们的具体使用方式，不在本报告的判断范围。**

---

## 7. 免责声明

- 本报告是**事实搜集（fact-gathering）**，**不是法律意见、不是侵权分析、不是 FTO 清关结论**。任何「能不能抄」「会不会侵权」「§3 是否覆盖我们」的判断，**必须由具备中国专利执业资格的律师／专利代理师**在看过我们**实际代码实现**后逐技术特征比对给出。
- §1 中的「风险高/中/低」是**基于权项文义重合度与法律状态的事实分诊标签**，用于排优先级，**不构成侵权可能性的法律评估**。
- 权项文本一律以**中文原文**引用，未作翻译（翻译会改变保护范围）。已逐处标明所引为**申请公布文本**还是**授权公告文本**。
- **摘要（摘要/Abstract）在中国专利法下不界定保护范围**（《专利法》第64条：以权利要求的内容为准）。本报告中引用摘要之处已明确标注为定位用途。
- **法律状态的权威凭据是 CNIPA 专利登记簿副本**，该文件不公开可检，本次**未取得**。本报告的「有效」判断建立在「官方事务数据中未出现终止类事务」这一**消极证据**之上，存在数据滞后与覆盖口径的固有局限（CNIPA 数据截止 2026.09.22）。
- Espacenet 因人机验证墙**未取得**，故欧洲专利局侧的同族/状态为**单源（Google Patents）**，未获第三方交叉验证；但 CN 侧已有 CNIPA 官方源，同族「CN 独苗」这一结论同时被 Google Patents 的 `Worldwide applications` 与 CNIPA 的申请号体系（无 PCT 进入国家阶段记录）支持。

---

# 附录 C:Magic Leap US11328475B2 及「重力作为估计变量」的更广检索

**[待补]** 这一件的检索 agent 在起草本任务书时还在运行,结果回来后会追加到这里。在此之前,请把 US11328475B2 当作**未检索**,由你自行按 §7 第 3 项补查:取独立权项原文、法律状态、转让记录(Magic Leap 做过专利融资,需查 USPTO Assignment),以及 F-A / F-C 的对照。

---

# 附录 D:我们自己代码的逐字摘录

> XRSLAM 摘录取自 `github.com/Kyle-Wang0211/xrslam` 分支 `pw/vio`(本地 `/Users/kaidongwang/Developer/xrslam`);SfM 摘录取自出货冻结版 `aether_sfm_c.cc@ea77244a`。行号以这两个版本为准。

### D.1 误差状态布局 — `xrslam/src/xrslam/estimation/state.h:12-19`
```cpp
enum ErrorStateLocation {
    ES_Q = 0,
    ES_P = 3,
    ES_V = 6,
    ES_BG = 9,
    ES_BA = 12,
    ES_SIZE = 15
};
```

### D.2 全部参数块声明 — `xrslam/src/xrslam/estimation/solver.cpp:88-116`
```cpp
}

void Solver::add_frame_states(Frame *frame, bool with_motion) {
    details->problem->AddParameterBlock(
        frame->pose.q.coeffs().data(), 4,
        details->quaternion_parameterization.get());
    details->problem->AddParameterBlock(frame->pose.p.data(), 3);
    if (frame->tag(FT_FIX_POSE)) {
        details->problem->SetParameterBlockConstant(
            frame->pose.q.coeffs().data());
        details->problem->SetParameterBlockConstant(frame->pose.p.data());
    }
    if (with_motion) {
        details->problem->AddParameterBlock(frame->motion.v.data(), 3);
        details->problem->AddParameterBlock(frame->motion.bg.data(), 3);
        details->problem->AddParameterBlock(frame->motion.ba.data(), 3);
        if (frame->tag(FT_FIX_MOTION)) {
            details->problem->SetParameterBlockConstant(frame->motion.v.data());
            details->problem->SetParameterBlockConstant(
                frame->motion.bg.data());
            details->problem->SetParameterBlockConstant(
                frame->motion.ba.data());
        }
    }
}

void Solver::add_track_states(Track *track) {
    details->problem->AddParameterBlock(&(track->landmark.inv_depth), 1);
}
```

### D.3 重力常量 — `xrslam/src/xrslam/estimation/preintegrator.cpp:125-132`
```cpp
        Eigen::LLT<matrix<15, 15>>(delta.cov.inverse()).matrixL().transpose();
}

void PreIntegrator::predict(const Frame *old_frame, Frame *new_frame) {
    static const vector<3> gravity = {0, 0, -XRSLAM_GRAVITY_NOMINAL};
    new_frame->motion.bg = old_frame->motion.bg;
    new_frame->motion.ba = old_frame->motion.ba;
    new_frame->motion.v =
```

### D.4 初始化器里唯一一次解尺度 — `xrslam/src/xrslam/core/initializer.cpp`(函数签名处)
```cpp
xrslam/src/xrslam/core/initializer.h:27:    void solve_gravity_scale_velocity();
xrslam/src/xrslam/core/initializer.h:28:    void refine_scale_velocity_via_gravity();
xrslam/src/xrslam/core/initializer.cpp:388:    solve_gravity_scale_velocity();
xrslam/src/xrslam/core/initializer.cpp:394:    refine_scale_velocity_via_gravity();
xrslam/src/xrslam/core/initializer.cpp:426:void Initializer::solve_gravity_scale_velocity() {
xrslam/src/xrslam/core/initializer.cpp:467:void Initializer::refine_scale_velocity_via_gravity() {
```

### D.5 边缘化先验基类(首帧 1e15 规范固定) — `xrslam/src/xrslam/estimation/marginalization_factor.h:17-33`
```cpp
  protected:
    MarginalizationFactor(Map *map) : base_map(map) {
        frames.resize(map->frame_num() - 1);
        pose_linearization_point.resize(map->frame_num() - 1);
        motion_linearization_point.resize(map->frame_num() - 1);
        for (size_t i = 0; i + 1 < map->frame_num(); ++i) {
            Frame *frame = map->get_frame(i);
            frames[i] = frame;
            pose_linearization_point[i] = frame->pose;
            motion_linearization_point[i] = frame->motion;
        }
        infovec.setZero(ES_SIZE * (map->frame_num() - 1));
        sqrt_inv_cov.setZero(ES_SIZE * (map->frame_num() - 1),
                             ES_SIZE * (map->frame_num() - 1));
        sqrt_inv_cov.block<3, 3>(ES_P, ES_P) = 1.0e15 * matrix<3>::Identity();
        sqrt_inv_cov.block<3, 3>(ES_Q, ES_Q) = 1.0e15 * matrix<3>::Identity();
    }
```

### D.6 边缘化先验残差(绝对量表达) — `xrslam/src/xrslam/estimation/ceres/marginalization_factor.h:29-45`
```cpp
        for (size_t i = 0; i < frames.size(); ++i) {
            const_map<quaternion> q(parameters[5 * i + 0]);
            const_map<vector<3>> p(parameters[5 * i + 1]);
            const_map<vector<3>> v(parameters[5 * i + 2]);
            const_map<vector<3>> bg(parameters[5 * i + 3]);
            const_map<vector<3>> ba(parameters[5 * i + 4]);
            map<vector<3>> rq(&residuals[ES_SIZE * i + ES_Q]);
            map<vector<3>> rp(&residuals[ES_SIZE * i + ES_P]);
            map<vector<3>> rv(&residuals[ES_SIZE * i + ES_V]);
            map<vector<3>> rbg(&residuals[ES_SIZE * i + ES_BG]);
            map<vector<3>> rba(&residuals[ES_SIZE * i + ES_BA]);
            rq = logmap(pose_linearization_point[i].q.conjugate() * q);
            rp = p - pose_linearization_point[i].p;
            rv = v - motion_linearization_point[i].v;
            rbg = bg - motion_linearization_point[i].bg;
            rba = ba - motion_linearization_point[i].ba;
        }
```

### D.7 边缘化后重设线性化点(=帧的绝对位姿;参考系不调整) — 同文件 `:456-473`
```cpp
            frames.resize(base_map->frame_num() - 1);
            pose_linearization_point.resize(base_map->frame_num() - 1);
            motion_linearization_point.resize(base_map->frame_num() - 1);
            set_num_residuals((int)frames.size() * ES_SIZE);
            mutable_parameter_block_sizes()->clear();
            for (size_t i = 0; i < base_map->frame_num(); ++i) {
                if (i == index)
                    continue;
                size_t j = i > index ? i - 1 : i;
                frames[j] = base_map->get_frame(i);
                pose_linearization_point[j] = frames[j]->pose;
                motion_linearization_point[j] = frames[j]->motion;
                mutable_parameter_block_sizes()->push_back(4); // q
                mutable_parameter_block_sizes()->push_back(3); // p
                mutable_parameter_block_sizes()->push_back(3); // v
                mutable_parameter_block_sizes()->push_back(3); // bg
                mutable_parameter_block_sizes()->push_back(3); // ba
            }
```

### D.8 特征分解与零空间截断 — 同文件 `:440-455`
```cpp
        /* scope: create marginalization factor */ {
            Eigen::SelfAdjointEigenSolver<matrix<>> saesolver(
                pose_motion_infomat);

            vector<> lambdas = (saesolver.eigenvalues().array() > 1.0e-8)
                                   .select(saesolver.eigenvalues(), 0);
            vector<> lambdas_inv =
                (saesolver.eigenvalues().array() > 1.0e-8)
                    .select(saesolver.eigenvalues().cwiseInverse(), 0);

            sqrt_inv_cov = lambdas.cwiseSqrt().asDiagonal() *
                           saesolver.eigenvectors().transpose();
            infovec = lambdas_inv.cwiseSqrt().asDiagonal() *
                      saesolver.eigenvectors().transpose() *
                      pose_motion_infovec;

```

### D.9 手机端 SfM:finalize 全局 BA 的规范固定与参数(出货冻结版 `aether_sfm_c.cc@ea77244a:5868-5885`)
```cpp

    colmap::BundleAdjustmentConfig cfg1;
    cfg1.FixGauge(colmap::BundleAdjustmentGauge::THREE_POINTS);
    for (const colmap::image_t img_id : s->reg_order) cfg1.AddImage(img_id);
    size_t obs_budget = 0;
    for (const auto& [len, pid] : ranked) {
      if (obs_budget >= kMaxObs) break;
      cfg1.AddVariablePoint(pid);
      obs_budget += static_cast<size_t>(len);
    }

    colmap::BundleAdjustmentOptions opt1;
    opt1.refine_rig_from_world = true;   // poses FREE → drift redistributes
    opt1.refine_points3D = true;
    opt1.refine_focal_length = false;    // trust the ARKit focal (one shared cam)
    opt1.refine_principal_point = false;
    opt1.print_summary = false;
    opt1.ceres->loss_function_type =
```
