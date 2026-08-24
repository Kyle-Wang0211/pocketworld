---
artifact_contract: "ce-handoff/v1"
created_at: "2026-08-22T03:46:47Z"
title: "PocketWorld A_refined 最终质量基线与流式稠密生产交接"
summary: "2026-08-20 至 2026-08-22 的位姿质量、rolling-C、C_journal、全分辨率查看器、A_refined 基线锁定及手机生产待办全档。"
keywords: ["PocketWorld", "A_refined", "C_batch", "C_journal", "dense point cloud", "streaming", "global BA", "handoff"]
cwd: "/Users/kaidongwang/Documents/progecttwo"
resume_focus: "在不重做已完成 A/C 实验的前提下，继续设计并接入手机端流式稠密预览，保持交互状态，最终无感替换为 A_refined。"
---

# 给下一个 agent 的交接提示词

你接手的是 PocketWorld 最近两天的“位姿质量 → rolling-global C → journal 稠密复用 → A_refined 最终质量基线 → 流式稠密生产形态”工作。

这份交接是状态和证据，不自动授权你修改生产代码、启动手机、重跑大实验或改基线。先读完，核验关键文件仍存在，然后向用户确认当前要继续哪一步。

## 0. 一句话结论

当前严格质量排序已经实测并由用户确认：

`A_refined > C_batch > C_journal`

用户随后明确决定：

> `A_refined` 固定为最终交付质量基线。

产品最合理的形态不是 A/C 二选一，而是：

`拍摄/等待期间展示持续生长的 C_journal → refined 位姿和最终稠密完成后，在同一交互状态下无感替换成 A_refined`

但必须诚实区分：**host 质量实验和静态查看器已经完成；手机生产端的流式稠密接线尚未完成。**

---

# 一、用户已经明确拍板的事项

以下是用户明确说过或明确确认过的决定，不是 agent 自行推断：

1. 不可能把同一真实场景完全复拍三遍；所有 A/B/C 对比必须用**同一份冻结素材**走不同处理臂。
2. 查看器必须展示真实完整稠密 PLY，**禁止等比例抽样或显示降采样**。
3. 页面交互与展示直接复用既有 `compare_lever1.html` / 已有点云页面，不重新发明交互。
4. 当前阶段先保质量，再讨论提速、手机热量和调度。
5. 用户希望在等待期间看到稠密点云持续变完整。
6. 用户希望后续更新点云时保留当前旋转、缩放、平移和选区，不刷新页面、不重置视角。
7. 用户肉眼判断并最终写明：`A_refined > C_batch > C_journal`。
8. 用户最终明确指令：先把 `A_refined` 固定为最终质量基线。

措辞注意：用户口中的“每训练好一帧”在实现上应称为**每完成一帧深度推理**；不是在手机上逐帧重新训练网络。

---

# 二、A/B/C 术语必须按时代区分

这是最容易造成误判的地方。08-20 的旧 A/B/C 与 08-21 最终页面的三臂名称不完全相同。

## 2.1 08-20 旧口径

- `A`：停拍后使用 refined 位姿和最终三输入，对全部帧重新做稠密推理与融合。质量最好，但尾延迟长。
- `B`：拍摄期 live 位姿下算出的稠密结果直接当成品。原始实测判负。
- `C`：每帧只在拍摄期冻结时刻推理一次，缓存深度；停拍后换成终态位姿重新融合。它的质量上限受 B/live 位姿质量约束。

权威旧交接：

- `/Users/kaidongwang/Documents/progecttwo/HANDOFF_20260820_pose_quality_research.md`
- 重点读 9–21 行、29–44 行、47–75 行、95–123 行。

## 2.2 08-21 最终三臂

- `A_refined`：finish-time refined 位姿；最终三输入；98 帧全量重推；最终融合。
- `C_batch`：开启 rolling-global BA 后的 `live_end` 终态位姿；最终三输入；98 帧全量重推；最终融合。
- `C_journal`：每帧只在其冻结 epoch 的位姿/深度范围/source list 下推理一次；缓存深度；最后使用与 `C_batch` 相同的终态 cams/pair 重融。

因此以后不能再说含糊的“A vs C”。必须明确是：

- `A_refined vs C_batch`：主要回答 refined 终态三输入相对 rolling-C 终态三输入的质量差。
- `C_batch vs C_journal`：主要回答复用拍摄期冻结深度的质量损失。

最终定义见：

- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/RESULT.md`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/PREREG.md`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare/manifest.json`

---

# 三、08-20：A/B 原始位姿质量研究

## 3.1 项目脉络

生产目标是手机扫描约 3.5–5 分钟后交付稠密点云。

位姿在生产架构中有两个阶段：

1. 拍摄期 `live_recon`：ARKit 锚定、局部/滑窗 BA，逐帧可用。
2. 停拍后 `finalize`：stage-1/stage-2 全局精化，产出 `refined`。

稠密 CasDiffMVS 的三类输入都来自稀疏重建：

- 相机位姿。
- 每帧深度范围。
- 有序 source 视图列表。

## 3.2 A/B 同素材 98 帧原始实测

旧战役记录：

- B 相对 A 点数约 `-1.95%`。
- 覆盖判负。
- B 全场局部粗糙度约 `+26.9%`。
- 该粗糙度差异约为换随机种子噪声地板的 400 倍。
- Umeyama 相对尺度约 `0.9860`。
- 相机中心对齐残差中位约 `6.4 mm`。
- 95/98 帧的 ordered top-10 不同。
- B 体素数量 `+15.4%`，其中约 71% 为贴壳毛边。
- A 地板全场 std 约 `0.6 cm`；B 局部塌陷约 `5 cm`。
- 163 个共同瓦片中，24 个错位至少 3 cm，且全部是 B 更低；B 另有 28 个双层瓦片。

当时结论：refined 全局 BA 修掉的是真实几何错误，不是形式流程。

注意：以上是 08-20 案卷中的旧结论。本轮没有再次重跑 A/B 原始实验，不要冒充“刚刚重新复算”。

## 3.3 找到的现成杠杆

拍摄期增量全局 BA 已经在生产内核中实现，但默认关闭：

- 实际生产 gate：`OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1`
- 历史 bench 还出现过无前缀名称：`AETHER_INCREMENTAL_GLOBAL_BA`

生产代码默认只做每帧局部 BA；开关开启后约每 25 个注册帧做一次滚动全局 BA，热状态严重时降频，critical 时跳过。

---

# 四、08-21：rolling-C 与 C_journal 同素材实验

## 4.1 冻结素材

所有新三臂来自同一份 cap41 素材：

- capture ID：`cap_1786414194441541`
- 原始 DB：125,227,008 bytes
- 原始 DB SHA-256：`e29fc9fbc01da00af64473eff29e5a7b3013e03254a6777ac318d4892408619d`
- fed journal：101 行
- fed journal SHA-256：`5589258362e65c0654ddfa06c9f16dd64c3a59731e4d91dc5afb5ce960158360`
- 最终稠密有序帧：98 帧
- 98 帧 index manifest SHA-256：`d5f719ba2cb9de13822183564d674f927966d9a10a0c69e9ee222e99c6e9ea2d`
- frame→photo map SHA-256：`7d3c9b03a4f4eb028ac58878099a97ff87034ae4afa7cabc9a7b3a02e17546cc`
- checkpoint SHA-256：`46a0b8941c4ca76859fce597255dc5da6f09e81f40ac34c5e165cddeba37392f`

## 4.2 rolling-C replay 结果

rolling-global BA 在注册帧数约 25/50/75/100 时触发四次：

- reg25：free 25 / frozen 0
- reg50：free 40 / frozen 10
- reg75：free 40 / frozen 35
- reg100：free 40 / frozen 60

结果：

- `SOURCE 101/101`
- `STREAMED fed=101 missing_pose=0`
- `incr=1`
- `n_reg=99`
- `n_points=55171`
- `track3plus=15490`
- `n_obs=146467`
- `mean_reproj_px=1.0251`

## 4.3 C_journal 冻结 epoch

冻结规则：

- `feed_ordinal = actual_frame_id + 1`
- snapshot = `ceil((feed_ordinal + 10)/10)*10`
- 最大到 `live_end`
- M=10

98 帧 cohort：

- reg20：dense IDs 00–09
- reg30：10–19
- reg40：20–29
- reg50：30–37
- reg60：38–46
- reg70：47–56
- reg80：57–66
- reg90：67–76
- reg100：77–86
- live_end：87–97

不在最终 98 帧中的三个 frame：

- `frame_000037.jpg`：映射照片缺失。
- `frame_000039.jpg`：refined model 中不存在。
- `frame_000041.jpg`：refined model 中不存在。

## 4.4 稠密配方

- CasDiffMVS：768×576。
- `num_view=10`。
- batch 1。
- 固定噪声：`20260818 + global_dense_id`。
- photo gates `[0.3, 0.5, 0.5]`。
- geo consistency `>=3`。
- pixel threshold `1.0`。
- relative depth threshold `0.01`。
- 最终使用冻结的 C→A Sim(3)，没有给 C_journal 重新估 alignment。

## 4.5 必须保留的失败记录

### Replay attempt 1

bench 不会创建 `out_dir`；第一次尝试在 `session.db` 父目录不存在时失败。打开 private SQLite 副本还会写 WAL/PRAGMA，导致物理 DB hash 从 `e29f…` 漂移到 `2746…`。

处理：失败日志和污染副本保留；第二次从干净 `e29f…` 私有副本开始，预建空 output dir。

不要：复用污染后的 replay input；不要把 `2746…` 误写为原始输入身份。

### Replay 低位非确定性

attempt2 与历史 frozen rolling-C 在拓扑、计数和指标上复现，但多线程 BA 导致浮点末位不同。最终使用 attempt2 的周期快照与历史 frozen `live_end` 组成 composite；二者是数值等价，不是 bitwise identical。

### frame 38 无稀疏锚点

global dense ID 38 / `frame_000040.jpg` 在冻结 epoch 有 4,716 keypoints，但 linked sparse anchor 为 0。

复用项目已有 streaming fallback：

- depth range：`[0.3049002626, 4.0653368346]`（C 单位）
- source IDs：`[37,39,36,35,40,8,46,9,0]`

第一次 adapter 错把 min/max 写成同一个数；该错误输出完整保留，但明确没有进入最终 assembly、fusion、PLY 或 viewer。修正后只重算 reg60，最终消费的是 `out_corrected`。

### 错误的 source 门

早期 validator 自创了“至少 9 个 score>0.01 source”的门，后来按官方 loader 改正：positive non-self source 非空即可，`n_views=10` 只是上限。

### `-W error` inference 尝试

PyTorch `meshgrid` deprecation warning 被 `-W error` 抬成异常，第一帧 forward 前退出；没有产出可用 depth/conf。随后按正常 warning policy 重跑，算法配方没有改变。

### 资源偏差

reg20 后 macOS swap-used 增长约 1.7 GiB，超过预注册 1 GiB；但实际新增 pageout 约 15 MiB、退出后系统仍有约 48% 空闲内存。记录为一次性 MPS 初载迁移，后续继续串行并保留资源停止门。

---

# 五、最终同素材三臂结果

| 口径 | 完整点数 | 有效像素率 | 全场粗糙度 p50 |
|---|---:|---:|---:|
| A_refined | 14,428,563 | 33.2822977% | 0.9802618623 mm |
| C_batch | 13,504,105 | 31.1498548% | 1.2257303421 mm |
| C_journal | 13,261,684 | 30.5907% | 1.2822236981 mm |

差值：

### C_journal 相对 C_batch

- 少 242,421 点。
- `-1.7952%`。
- 粗糙度 `+0.056493 mm`。
- 粗糙度 `+4.6090%`。

### C_journal 相对 A_refined

- 少 1,166,879 点。
- `-8.0873%`。
- 粗糙度 `+0.301962 mm`。
- 粗糙度 `+30.8042%`。

解释：

- 三者肉眼属于相近档次。
- C_journal 的主体结构可用。
- 但注册指标和用户终审都不支持“C_journal 等价于 A”。
- 严格排序只能写：`A_refined > C_batch > C_journal`。

粗糙度指标会从全云抽取 `floor(N/24)` 做确定性量测；这是**指标抽样**。网页展示三份完整点云，没有任何**展示抽样**。不要混淆。

权威结果：

- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/RESULT.md`
- SHA-256：`1dfd6a4e1f0ab910f9c9db1948c61a0f79543c30781e5a2af78c10ff3dd4c4ae`

---

# 六、全分辨率 A | C_batch | C_journal 查看器

目录：

`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare`

页面顺序：

`A_refined | C_batch | C_journal`

交互：

- 三窗共享相机。
- 共享点大小。
- 左拖旋转。
- 右键平移。
- 滚轮缩放。

完整点数：

- A：14,428,563。
- C_batch：13,504,105。
- C_journal：13,261,684。
- 总计：41,194,352。

六个 bin 都是全量数据：

- `A.pos`：`12*N` bytes。
- `A.col`：`3*N` bytes。
- `C_batch.pos`：`12*N` bytes。
- `C_batch.col`：`3*N` bytes。
- `C_journal.pos`：`12*N` bytes。
- `C_journal.col`：`3*N` bytes。

关键身份：

- page SHA-256：`bc606ca0e55611a2f87712f963339fdd1969ed59a146d2a5228f1a6330428e5f`
- manifest SHA-256：`aa8f6612e89bfcf37ec312129a9c2011e0c09dae52ce15972864b0774ce81783`
- meta SHA-256：`0e98fd85c260b7f6ad215fd6c3988dcda1b46fedf2a33cfadbba66d634053186`
- exporter SHA-256：`9752c7bae83a57ac08bf6e536031aaeb5989b25681086a99cd623bc08921ea8d`
- builder SHA-256：`b62206c788cfaf0bc110284488f116668194a8972627fbb96dbf938bfe1422f1`

曾经的临时地址：

`http://127.0.0.1:8732/`

重要：这是临时 localhost 服务。接手时必须先检查它是否仍活着；不要因为文件存在就声称 URL 当前可访问。

若要恢复服务：

```bash
python3.11 -m http.server 8732 --bind 127.0.0.1 --directory /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare
```

当前页面是**静态三云对比页**，不是动态生长 demo。它启动时加载六个固定 bin；不能用它证明手机端已经逐帧更新点云。

---

# 七、A_refined 最终质量基线已正式锁定

用户明确要求后，已经创建不可原地改写的 v1 基线：

## 7.1 基线决定

- baseline ID：`A_refined_cap41_v1`
- status：`LOCKED`
- 生效时间：2026-08-22 03:23:17 Asia/Shanghai
- 最终交付质量基线：`A_refined`

## 7.2 基线文件

人读文件：

`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.md`

机器合同：

`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.json`

98 张照片逐项哈希：

`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/A_REFINED_BASELINE_ORDERED_PHOTOS_v1.json`

SHA lock：

`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.sha256`

文件身份：

- baseline JSON：`63ebefc7bca6075e16ce5c34f8ec0a56a1ed98d7e9ec9cfa180eef1a1af3d6bd`
- baseline Markdown：`fc3440c7bb9e4aa2d05005a912040bc7b36d30ba111a1a67f405b9914752d85d`
- photo manifest：`5c3db75d8ce82e5193d2a4228cba797e980fa96f23de31b11a5d31f5d9e72316`
- SHA lock 自身：`13f810bcd8e02ad9f9e076bbcba8560bbb03b73dea133222972e01b0315ca4ed`

## 7.3 A PLY

- 路径：`/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_A.ply`
- SHA-256：`9d0c1cc5cbad53805db1a9868a52785fd12d7c0b0c6fff3ae145a96bfaec7d27`
- bytes：216,428,627。
- vertices：14,428,563。
- binary little-endian。
- float32 XYZ + uint8 RGB。

## 7.4 基线质量

- valid pixel：33.28229770098143%。
- roughness sample：601,190。
- p50：0.9802618623124735 mm。
- p75：1.4108582780497276 mm。
- p90：1.8458498192330448 mm。

## 7.5 98 张照片内容身份

photo manifest 包含 98 个唯一 index、frame、photo、byte size 和 SHA-256。

可重新计算的 aggregate：

`8e83008e0287a83b7858e201864b04dec7ecb1bd81edeb2c9c7e8b936787f2eb`

文件里另有历史 `979a…` 聚合值，但它没有完整的旧聚合算法。以后验证用新的可复算 `8e830…`，不要把旧值当成当前 baseline aggregate。

## 7.6 替换规则

任何候选要替换 A：

1. 必须同一冻结素材和帧清单。
2. 必须全分辨率、零展示抽样。
3. 必须同一 gauge 真彩并排。
4. 必须另行预注册判据。
5. 必须获得用户明确批准。
6. 必须创建版本化 successor lock。
7. 禁止原地改写 v1。

验证命令：

```bash
cd /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C
shasum -a 256 -c FINAL_QUALITY_BASELINE_A_REFINED_v1.sha256
```

预期四项全部 `OK`。

---

# 八、当前手机生产端到底做到哪一步

## 8.1 已确认的稀疏链

生产 SfM 内核存在：

- 每帧局部 BA。
- 可选拍摄期 rolling-global BA。
- finish 后 stage-1/stage-2 refined 全局精化。
- 最终 pose getter 来自 refined reconstruction。

## 8.2 稠密相关代码存在，但生产 enqueue 未证实

可读内核会在特定 env gate 下生成 L1/CasDiffMVS 计划 sidecar：

- `arbitration_plan.json`
- `arbitration_plan.bin`
- `arbitration_points.bin`

它使用最终 reconstruction 的：

- `CamFromWorld`
- K
- Points3D/tracks
- source selection
- depth range

但该分支受：

`OFFICIAL_AETHER_GHOST_MASK=1`

控制，默认关闭。

此前在可读 Swift/Dart/App 配置和调用点中，没有找到真正 enqueue CasDiffMVS runner、消费 plan、逐帧产出 dense depth 并把点云推送到 UI 的完整生产调用链。

生产 App 树的一部分曾处于 iCloud `compressed,dataless`，所以不能把“未找到”升级成绝对不存在；只能说当前没有可验证的生产接线证据。

用户本人也明确说过：当前生产端应该只有稀疏点云，稠密链尚未接入。

因此交接必须写：

> host 已证明稠密算法与质量；手机生产端流式稠密尚未完成。

不能写：

- 手机已经在逐帧生成稠密点云。
- 手机已经保留交互状态更新。
- 停拍后已经会静默替换 A。
- 真机热量和速度已经验收。

---

# 九、现有流式稠密代码可以复用什么

已有 host 流式驱动：

`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/pw_diffmvs_stream.py`

它已经实现：

- 按顺序做 depth inference。
- inference 与 CPU fusion 重叠。
- reference 只有在其融合依赖的邻帧 depth 都存在时才变成 READY。
- streamed 与 monolithic 可做 bitwise parity 验证。
- 现有 depth-range fallback：少于 8 个稀疏 anchor 时使用 `0.3/s_al` 到 `4.0/s_al`。
- 无 covis source 时按相机中心距离和最小基线 fallback。

它没有实现：

- 手机生产 runner 接线。
- UI event bridge。
- GPU point buffer 增量更新。
- 交互状态持久化。
- 最终 A 原地替换。

产品语义不能承诺“每输入一张 raw frame，几何必定变化”。多视图融合需要邻帧依赖。准确承诺应是：

- 每完成一张深度推理，进度立即更新。
- 每当一个或多个 ref 达到 READY，点云几何立即增长。

---

# 十、建议的最终产品数据流

这是一条连续路径，不是三个独立产品：

1. 拍摄过程中稀疏 SfM 持续注册帧。
2. rolling-global BA 以受控节奏改善拍摄期位姿。
3. 每个可用 ref 冻结当时的 pose/depth range/source list。
4. 稠密模型对 ref 做深度推理并缓存 depth/confidence。
5. 当融合依赖齐备时，生成新的稠密几何块。
6. UI 始终保留同一个 renderer、相机、orbit target、缩放、平移、点大小和选区状态，只更新点云 buffer/资源。
7. 用户停拍时立即看到已经生成的 C_journal 部分，不出现空白等待页。
8. 停拍后继续完成尚未完成的推理；每有 READY 几何就继续更新。
9. 后台取得 `A_refined` 最终位姿与三输入。
10. 按 A 输入完成最终全量深度推理与融合。
11. A 完成时只替换点云数据，不销毁 renderer、不重置用户视角。
12. 最终交付 `A_refined`。

`C_batch` 不建议作为默认生产中间版：它同样需要 98 帧终态全量重推，但质量低于 A，默认同时跑 C_batch 和 A 会重复计算。它保留为实验对照或明确降级结果。

注意：上段中“A 最终基线”是用户明确批准；“C_batch 只作实验/fallback”是现阶段根据重复计算与质量排序形成的产品判断，不要冒充用户逐字签字。

---

# 十一、下一步真正该做什么

不要再重跑已完成的 A/C 同素材质量实验。下一步应当是手机生产端的最小端到端 vertical slice，但执行前先让用户确认是否现在开始改生产。

建议拆成以下顺序：

## 11.1 只读生产接线核查

1. 检查生产 App 源码是否 resident；先 `ls -lO`，遇到 `dataless` 停止，不要强读。
2. 找 capture accepted-frame 事件。
3. 找稀疏 pose/depth-range/source-list 可冻结的位置。
4. 找现有 CoreML/CasDiffMVS runner 或确认缺失。
5. 找预览 renderer 和 point-cloud data source。
6. 找 render state 是否已独立保存 camera/orbit/zoom/selection。
7. 画出最小接线图；不要先改代码。

## 11.2 最小生产实现目标

- 第一张 READY 稠密几何出现。
- 后续 READY 几何可增量更新。
- 页面/renderer 不重新创建。
- 用户交互状态完全保留。
- 停拍后继续计算，不回到空白 loading。
- A 完成后原子替换最终点云。
- 发生 dense 失败时不能破坏稀疏 capture 或丢失用户数据。

## 11.3 真机验收

必须在同一台目标 iPhone 上记录：

- first dense visible latency。
- 每次推理耗时。
- 每次几何更新间隔。
- 停拍到 A 最终替换的尾延迟。
- GPU/CPU/内存峰值。
- thermal state。
- 掉帧和 capture ingest latency。
- renderer 状态替换前后一致。
- 最终 PLY 与 A baseline 的视觉和注册指标。

质量优先阶段不要先做 aggressive 降分辨率、关键帧裁剪或自定义容差门。

---

# 十二、5090 训练状态

最后一次已验证的只读快照是 2026-08-21 18:06（Asia/Shanghai）：

- RTX 5090。
- Epoch 18/32。
- Iter 19944 → 19968，10 秒内仍推进。
- 显存约 21.7 / 32.6 GB。
- 温度约 70°C。
- fatal 0。
- NaN 0。
- 最新 checkpoint：`model_000017.ckpt`。
- 当时估算剩余约 45 小时。

这只是历史快照。接手时间晚于 08-21 时，必须重新 SSH 只读查询；禁止沿用旧 ETA 或宣称训练仍在运行。

不要在交接文件中保存 SSH 私钥、完整公钥、密码或其他凭据。

---

# 十三、USB 手机最后已知状态

此前只读查询确认：

- iPhone 14 Pro，iPhone15,2。
- iOS 26.6。
- USB 可见，`available=true`。
- `com.kyle.PocketWorld` 已安装，version 1.0.0，build 20。
- 当时 Runner 未运行。
- `com.kyle.Aether3D` 未安装。

这些同样是时间快照。接手时不能默认手机仍连接、仍解锁、App 版本不变。

---

# 十四、关键工具与最终代码身份

最终实际使用的关键文件：

- journal adapter：`journal_C/tools/run_colmap_input_journal.py`
  - SHA-256 `9532cf2af830a5ac21b97c1100b7d8adf67aa424657909517d265b8c992137c4`
- journal pipeline：`journal_C/tools/journal_pipeline.py`
  - SHA-256 `6aa0678bd2f9485998a8927eb783b61deab80bd39e3ce8c0fe12fe29ca48c3ae`
- viewer builder：`journal_C/tools/build_page_journal_fullres.py`
  - SHA-256 `b62206c788cfaf0bc110284488f116668194a8972627fbb96dbf938bfe1422f1`
- adapter tests：`journal_C/tests/test_colmap_input_journal.py`
  - SHA-256 `fddea4aa6b64ebdba65391dcf60cc58ffe9533d2efad8140bae7ea81fb7d9c94`
- pipeline tests：`journal_C/tests/test_journal_pipeline.py`
  - SHA-256 `34a29d82433b10b727d3e19e0219f27f1ecda2f14a763c354ecdfc43b3e04d0d`
- viewer tests：`journal_C/tests/test_journal_fullres_viewer.py`
  - SHA-256 `ba65fd2fd98838b5cc60e05253ee4795c0b2febd23b54eb6715abd553703ace8`

版本漂移注意：

- `journal_C/PREREG.md` 某处仍记录早期 assembler `ccb0…`。
- 最终 manifest、当前文件和最终产物使用的是 `6aa0678…`。
- 必须写成“诚实修订与 frame38 修复后的最终 reviewed identity”，不能宣称与最初 prereg hash 完全一致。

`journal_C/fusion_stage_verification.json` 是 0 bytes，且不在最终 manifest 中；不能当成验收证据。

---

# 十五、必须遵守的环境避雷

## 15.1 iCloud dataless

`/Users/kaidongwang/Documents/progecttwo` 位于同步目录。关键文件可能变成 `compressed,dataless`。

任何关键输入先运行：

```bash
ls -lO <path>
```

遇到 `dataless`：

- 不要读取。
- 不要让 SQLite 打开。
- 不要等待无 timeout 的下载。
- 报告具体阻塞文件。

SQLite 必须同时检查 main DB、WAL、SHM。WAL dataless 会导致开库错误。

## 15.2 禁止无界等待

本机没有可靠 `/usr/bin/timeout`。使用：

```bash
perl -e 'alarm 60; exec @ARGV' -- <command> <args...>
```

## 15.3 Python

稠密链固定使用 Python 3.11：

- `/Users/kaidongwang/.venv/pocketworld/bin/python`
- `/opt/homebrew/bin/python3.11`

不要默认使用 Python 3.14；历史上 cv2/ffmpeg 链接和行为不同。

## 15.4 Git

这批研究工作明确未使用 Git。部分 Aether3D 工作树和 `.git` 元数据曾 dataless/挂起。不要在模糊根目录运行 Git；先明确实际代码根、resident 状态和用户授权。

## 15.5 磁盘与内存

- PLY 和 bin 很大。
- 任何全量推理或导出前先检查磁盘。
- MPS 推理单帧串行，避免无意义并发。
- viewer 全量加载三臂会占用大量 CPU/GPU 内存。

## 15.6 不自创生产算法

- 机制诊断可以写分析脚本。
- 生产配方优先复用已有官方/项目实现。
- 任何自定阈值必须标注并等待用户批准。
- 不要为了速度偷偷降分辨率、减少 view 或采样显示。

---

# 十六、不要重复的错误方向

1. 不要要求用户重拍三遍同一场景。
2. 不要把 sparse 点云当成最终用户交付物。
3. 不要把 static viewer 冒充 dynamic streaming UI。
4. 不要把 C_journal 冒充与 A 等价。
5. 不要把 C_batch 默认加入生产中间阶段并与 A 重复全量计算。
6. 不要复用 frame38 的旧 degenerate depth 输出。
7. 不要使用污染后的 replay DB 副本作为 frozen input。
8. 不要把 host BA 耗时外推成手机耗时。
9. 不要用 Sim(3) 对齐后的好看结果证明绝对米制尺度正确。
10. 不要把粗糙度的指标抽样误写成页面点云抽样。
11. 不要把历史 `979a…` photo aggregate 当成新的可复算 aggregate。
12. 不要原地修改 `A_refined_cap41_v1`。
13. 不要用 0-byte `fusion_stage_verification.json` 作证据。
14. 不要继续长时间研究已结束的 A/C 排序；用户已拍板 A 为最终基线。

---

# 十七、交接后的第一轮只读核验建议

先做这些短检查，不启动训练或生产改动：

```bash
# 1. A baseline 完整性
cd /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C
shasum -a 256 -c FINAL_QUALITY_BASELINE_A_REFINED_v1.sha256

# 2. 关键文件 resident 状态
ls -lO \
  FINAL_QUALITY_BASELINE_A_REFINED_v1.json \
  FINAL_QUALITY_BASELINE_A_REFINED_v1.md \
  A_REFINED_BASELINE_ORDERED_PHOTOS_v1.json \
  ../dense_A.ply

# 3. 查看静态页文件是否存在
ls -lO fullres_compare/index.html fullres_compare/manifest.json fullres_compare/bin/meta.json

# 4. localhost 服务是否存活（只检查，不自动启动）
curl --max-time 3 -I http://127.0.0.1:8732/
```

如果 baseline 四项不是全部 `OK`，立即停止，不要继续把任何新结果与 A 对比。

---

# 十八、接手时应该怎样向用户汇报

用户偏好：

- 结论先行。
- 说人话。
- 明确“已经做到”和“尚未做到”。
- 长任务先说明预计耗时。
- 用户质疑时先查自己的口径和证据。
- 页面必须让用户肉眼终审。

正确开场示例：

> 我已经读完交接。当前最终质量基线是 A_refined；C_journal 负责渐进预览，手机生产端流式稠密尚未接入。已完成的 A/C 实验不再重跑。下一步如果你确认，我先只读定位生产 App 的 dense runner、renderer 和状态保存接口，再给出最小接线清单。

不要一上来就：

- 启动数小时实验。
- 改生产代码。
- 重新定义 A/B/C。
- 重新造查看器交互。
- 要求用户重拍素材。

---

# 十九、最权威的文件索引

## 总脉络

- `/Users/kaidongwang/Documents/progecttwo/HANDOFF_20260820_pose_quality_research.md`
  - 08-20 A/B 位姿质量战役、三输入演化、研究方向、工具与 14 条避雷。

## 最终 C_journal 实验

- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/PREREG.md`
  - 冻结输入、epoch、配方、诚实修订和失败记录。
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/RESULT.md`
  - 最终三臂结果与结论。
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare/manifest.json`
  - PLY、bin、工具、transform、viewer 的 SHA-256。

## A_refined 基线

- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.md`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.json`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/A_REFINED_BASELINE_ORDERED_PHOTOS_v1.json`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/FINAL_QUALITY_BASELINE_A_REFINED_v1.sha256`

## 查看器

- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare/index.html`
- `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/fullres_compare/bin/`

## 流式稠密历史实现

- `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/pw_diffmvs_stream.py`

## 生产稀疏内核与 L1 plan

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/include/aether_l1_plan.h`

---

# 二十、最终接手原则

1. `A_refined_cap41_v1` 是当前唯一最终质量基线。
2. C 的价值是连续体验，不是替代 A 的最终质量。
3. 已完成的实验不要重跑。
4. 当前真正缺的是手机端流式 dense runner + incremental fusion + persistent renderer state + final A swap。
5. 任何生产改动前先只读定位并让用户确认。
6. 所有新结果必须与冻结 A 基线在同素材、同 gauge、全分辨率下比较。
7. 永远区分 host proof、静态页面、真机生产三个成熟度层级。

读完后，先用一句话向用户确认你理解了当前状态；等待用户指示再行动。
