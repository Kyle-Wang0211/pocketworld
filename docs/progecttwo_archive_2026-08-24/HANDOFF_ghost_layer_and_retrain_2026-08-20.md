# 接管提示词:鬼层战役 + 零DTU重训(截至 2026-08-20)

给下一个会话。**读完这份再动手。** 所有数字实测,出处标在括号里。

---

## 0. 一句话现状

**产品的稠密重建在无纹理白墙上会长出一层"鬼墙"(第二面墙,粘在旅行箱上)。
事后清算家族六连败已全部关闭;唯一还开着的路是重训,而它正在跑,08-23 出结果。**

---

## 1. 病灶到底是什么(用户原话为准,别自己改描述)

> **"墙不是翘起一部分,而是正确的墙在正确的位置,同时出现了第二面墙跟旅行箱粘连"**
> —— 用户 2026-08-19,推翻了此前所有"墙面翘起/形变"的说法

法医归因(平行会话,`arch_decision_dense_first_2026-08-18/WALL_BATTLE.md`):

- 病灶 = **墙后致密偏移层**,中位缩进 ~4cm(沿视线 6cm),尾到 23cm,占墙面点 4–8%
- **位姿已被洗清**:三臂稠密(两个独立位姿引擎 + 噪声臂)同位置同形态,而**稀疏墙笔直**(RMS 4.6mm)
- 源像素 = **空白白墙 + 旅行箱纯黑内衬**(全无纹理)← 就是用户说的"粘连"
- **conf 0.95–1.0 与真墙无差:网络自信地错**,`geo_mask≥3` 被"多视一致但错误"骗过(镜像鬼点同机制族)

🔴 **所以:这是深度网络在无纹理区的行为问题,不是位姿问题,不是融合门参数问题。**

---

## 2. 已判死清单(勿回头,累计十条)

| 刀 | 死因 | 出处 |
|---|---|---|
| DA3 跨源门 | DA3 在弱纹理斜视白墙上交付不出 2.5cm,误差比病灶大 17 倍 | WALL_BATTLE 刀A |
| 官方 conf 三通道门 | conf0 AUC **0.21**(信号是反的,偏移层比真墙更自信) | 刀B |
| 提 photo 阈值 / 收紧 geo_mask | 截 15.5% 偏移层要陪葬 60% 真墙 + 全图 55% 点 | 刀B |
| 平面先验 + 全局残差门 | oracle(真值平面)也只有 81%/2.8%;**挖出真凶见下** | 刀C |
| 显示层过滤 τ5/τ3 | 用户肉眼"完全没有任何效果" | 第二幕 |
| **theta0 源视图角度先验** | θ₀ 15/25 严重丢场景;方向本身就错(位姿侧杠杆够不着深度网络) | `theta0_source_selection_2026-08-19/` |
| MonoMVSNet / ACMP / 等上游修 | 见 WALL_BATTLE | |
| 出生后逐点过滤 / 全局BA / 出生后合并 | 鬼层战役 E2–E13(07-19),**根治只在出生前** | `rs_replication_exec_2026-07-19/` |

> 🔑 **刀C 挖出的真凶:干净墙面的 MVS 深度自身带 +1.6~2.5cm 系统性后偏,且逐帧漂移
> (fr107/125 整帧 +5cm)。6cm 病灶切不出一条 2–5cm 漂移的基线。**

---

## 3. 正在跑的实验(唯一开着的路)

**零 DTU + BlendedMVG 从头训 32 轮。**

```
机器   ssh -p 20905 root@116.127.115.18   (1× RTX 5090, $0.685/hr)
目录   /workspace/{diffmvs, data/BlendedMVS, cache, runs}
主控   /workspace/master.sh   → /workspace/master.log
日志   /workspace/runs/mvg_p1.log(段②)/ mvg_p2.log(段③)
ckpt   /workspace/runs/mvg/model_0000NN.ckpt(每轮一份)
```

口径 **100% 复刻官方** `scripts/train/train_casdiffmvs.sh` 的第②③段,逐字:

```
段②p1  16轮  --train_epochs=16  --scale 0 0.25  0.05
段③p2  16轮  --resume           --scale 0 0.125 0.025
其余    batch4 / lr0.001 onecycle / trainviews9 / numdepth 384+48
        stage_iters 1 3 3 / cost_dim 4 4 4 / CostNum 0 4 4
        min_radius 0.125 max_radius 8 / conf_weight 0.05
        hidden 0 32 20 / context 32 32 16 / unet 0 16 8
唯一变量  --trainpath/--trainlist 指向 BlendedMVG(494 场景 / 114,210 样本 = MVS 的 6.75×)
```

**偏离(必须如实写进任何报告):**
1. 砍掉官方第①段 DTU 预训练(许可阻断)。沿用 C 的应对:blend 段 16→32 轮补足总预算
2. 1 个场景被体检剔除(`5692a4c2adafac1f14201821`,10 个参考视图全不可用)

**进度(08-20 16:07):Epoch 13/32,第 12 轮验证误差 0.2078。**
C 训满 32 轮的终点是 **0.2069** —— 只差 0.4%,还有 20 轮。**预计 08-23 07:00 完成。**

| 轮 | MVG | C(同轮) |
|---|---|---|
| 0 | 0.3748 | 0.6602 |
| 4 | 0.2259 | 0.3038 |
| 8 | 0.2149 | 0.2564 |
| 12 | **0.2078** | 0.2349 |

⚠️ OneCycle 按轮数退火 ⇒ **同轮 = 同学习率位置**,这个对比是 LR 对齐的、有效的。

---

## 4. 08-23 要做的判决

用**同一份 b28、同一份 θ₀=5 的 pair.txt**,五个权重并排:

| 权重 | DTU | 数据 | 用户肉眼(08-19 判过) |
|---|---|---|---|
| 官方 `dtu` | ✅ | 只有 DTU | 明显鬼层 |
| 官方 `blend` | ✅ | BlendedMVS | 有一些连接 |
| 官方 `blendmvg` | ✅ | **BlendedMVG** | **完全没有** ← 最好 |
| 我们的 `C` | ❌ | BlendedMVS | 明显鬼层 ← 最差 |
| **新的** | ❌ | **BlendedMVG** | **← 这一格空着** |

**唯一问题:更多数据能不能替代 DTU,让网络在无纹理区不再"自信地错"。**

后手(WALL_BATTLE 写明):不行则启动 **"锚点先验注入 + conf 头补光度监督"** ——
**那是改损失函数,不再是复刻官方,需要用户重新拍板。**

---

## 5. 🔴 度量必须避的雷(今天连踩三个)

**① 点数 / 覆盖(体素占据)/ 局部粗糙度(k=15 PCA)对"整片位移"结构性失明。**
鬼墙点一个不少、照样占体素、局部还很平滑。我用这三把尺子把 C 排第一并写下
"放弃 DTU 没有代价" —— 用户肉眼当场推翻,C 是最差的。

**② 唯一管用的尺子:云对云偏离**(`mvs_pose_ablation_2026-08-18/tools/cloud_vs_ref.py`)。
拿一个"已知正确"的臂当基准,量其余臂每点到它的最近距离。
实测能复现用户的三档分组(blendmvg 0% / blend 0.51% / C 0.69% / dtu 1.12%,>5cm 占比)。
**限制:必须先有已知正确的基准,不能独立判谁对。**

**③ 纯过滤器只删点不移动点 ⇒ 任何精度改善都是幸存者效应。**
必须**同保留率 + 随机基线 + 已有判据**三方对比。
theta0 就是栽在这:指标全线变好(p99 −40%),实为点数掉 43% 的幸存者效应。

**④ 跨平台不能比稠密云点数。** MPS 与 CUDA 深度图相对差中位仅 **0.0012%**,
但融合后点数差 **24–32%**(几何一致性是数票的,阈值边界上被放大成整数级存活/淘汰)。

**⑤ pooled AUC 会因跨帧错位虚高,以逐帧为准;跨重建逐视图对拍按 `image.name` 配对,永远不要按索引。**

---

## 6. 🔴 我今天犯的错(全由用户当场纠正,别重蹈)

1. **拿 ALIKED+LightGlue@16384 当"生产"** —— 生产前端是 **GPU DSP-SIFT + COLMAP**
   (2026-06-25 定案,实测 0.8319px / 50-of-50);LightGlue **08-18 已判退役**
2. **凭记忆断言"COLMAP 没有 4.1"** —— 上游 **4.1.1**(2026-07-17 发布),`brew info` 一行可见。
   我装的是没升级的 3.13.0。**推断当 fact 之前先查**
3. **只搜了一棵树** —— 漏了 `~/Developer/A3X-colmap41/`。平行同名实现至少三处
4. **把鬼层误判成"翘起"** —— 方向从一开始就偏
5. **宣称"文件不存在"却只在一台机器上 find 过** —— `local_roughness.py` 本地就有
6. **`git ls-files` 只看当前分支** —— 跨分支查必须 `git log --all --name-only`;
   而且**按文件名判"进没进仓"会假阳性**(同名不同内容),要按 blob 内容哈希

---

## 7. 文件位置

### 研究仓 `~/Developer/Aether3D-cross/pocketworld_research_benchmarks`
```
分支 research/casdiffmvs-official-replication-2026-08-17   (主线,已推)
分支 research/lightglue-frontend-spike-2026-08-17          (WALL_BATTLE / 架构决策书)

experiments/
  mvs_pose_ablation_2026-08-18/       @16384vs@8192 消融 + **cloud_vs_ref.py(唯一管用的尺子)**
    tools/{run_arm,fuse_arm,cloud_vs_ref,wall_flatness,export_bins,build_page_fullres}.py
  theta0_source_selection_2026-08-19/ theta0 判死 + 真值可信度 + 许可调研
    gt_provenance/  ← 本次新增
  casdiffmvs_blendmvg_scratch_2026-08-16/
    ckpts/casdiffmvs_{A,B,C,D}*.ckpt   ← **C 是我们的零 DTU 权重**
    H200_RUN_FINDINGS.md               ← 延迟受限负载的全部实测
    STAGE1_VERDICT.md                  ← 段① 定案 + 许可账
  arch_decision_dense_first_2026-08-18/  ← 在 lightglue 分支
    WALL_BATTLE.md  DECISION.md          ← **鬼层战役全档,先读这个**
  rs_replication_exec_2026-07-19/        ← 鬼层 E2–E13 十三战
tools/python/diffmvs/                    ← 官方 CasDiffMVS(含我们的 ext_noise 改动)
  checkpoints_unz/casdiffmvs_{dtu,blend,blendmvg}.ckpt   ← 官方三权重
  colmap_input.py:395                    ← theta0 就在这行
  filter.py                              ← 官方融合,必须原样 import
```

### 本地产物(⚠️ 在 iCloud 同步目录里,会被逐出)
```
~/Documents/progecttwo/_host_experiments/pose_ablation_20260818/
    dense_{dtu,blend,blendmvg,P16k}.ply   ← 四方对照的云(P16k = 我们的 C)
    mvs_P16k/                             ← b28 的 MVS 输入(cams/images/pair.txt)
    frames/ b28_named/                    ← 132 张原始帧
    🔴 work_P16k/P8k/P16kH 已被平行会话删除(唯一副本,5090 已销毁)
~/Documents/progecttwo/_artifacts/
    wall_forensics_20260818/ delaunay_prior_20260818/ da3_separation_probe_20260818/
    lightglue_spike/{coverage_metric,local_roughness,export_ply,build_local_page}.py
```

---

## 8. 其他 tips

- **磁盘**:`~/Documents` 在 iCloud 同步下,删了会被回填;**真正能留住空间的是 `~/Developer`**(用 `git clean -fdx` 只删未跟踪的)
- **`pgrep -f xxx` 会自匹配**自己的命令行,骗过判断;用 `[x]xx` 写法
- **`nohup ... &` 在本工具调用结束后会被回收**,起服务要 `{ nohup ... & }; disown`
- **vast.ai 的 PyTorch 模板占着 8080**(Jupyter),起页面服务要换端口
- **RTX 5090 是这个负载最快的卡**:实测 0.41s/步 vs H200 0.473s(延迟受限,吃时钟不吃算力)
- **`run_arm.py` 等脚本的 `REPO` 路径**已改成可用 `DIFFMVS_REPO` 环境变量覆盖
- **不要新写尺子** —— `local_roughness.py`/`coverage_metric.py`/`cloud_vs_ref.py` 都已存在且校准过
- **判据顺序永远是:用户肉眼 > 云对云偏离 > 覆盖 > 点数**


---

## 9. 08-22 增补:两条路线并行(用户已拍板,另一 agent 在做 DTU 线)

**决定:① 零DTU+BlendedMVG 重训(本文档主线,08-23 ~15:00 出)与
② DTU clean-room 功能仿造 两条并行;只复刻、不混入自己的训练素材。**

DTU 线现状(另一 agent 汇报,08-22):目标与法律边界已明确;官方 DTU 配方已提取
(79 训练场景 / 7 光照 / trainviews=5 / 16 epochs / scale 0 0.5 0.1);
**尚无冻结的实施规格、无许可逐字核验、无生成器、无 smoke、无 ckpt。启动训练前须用户确认。**

🔴 **给 DTU 线的两条硬约束:**
1. **假设要先厘清**:"DTU 价值 = 无纹理区 GT 准"已被 gt_provenance 实验削弱
   (BlendedMVS GT 低/高纹理残差比 0.99×,低纹理更差仅 7/19 帧)。
   DTU 真正的贡献未定位(候选:近距尺度分布/真实传感器噪声/7 光照/0.5 噪声课程的适配对象)。
   方案的假设一节必须写明复刻的是哪个功能、依据是什么。
2. **执行 gate 在 08-23**:主线治好鬼墙 ⇒ DTU 线取消;部分改善 ⇒ 做且知道补多少;
   无改善 ⇒ 优先级最高。写方案免费,造数据是几天+钱,判决只差一天,别提前花执行成本。

验收门(两条线共用,用户原话):**"正确的墙在正确位置 + 不再多出第二面墙粘旅行箱"**,
判据 = 用户肉眼 + cloud_vs_ref.py,在 b28 上,同一份 θ₀=5 的 pair.txt。
