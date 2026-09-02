# 特征预算漏斗复测(2026-09-02,build 89,配对候选修复后)

复测 2026-07-19 原审计(记忆 `project_pocketworld_feature_budget_funnel_audit.md`)钉死的漏斗:
"提取的特征 80% 被浪费,病根=配对图稀疏(每图 verified 伙伴 5.3–10.3)"。
09-02 修复:删掉自设 45° 朝向锥门,对齐 COLMAP `SpatialPairGenerator`
(`~/Developer/aether_cpp/official_pipeline/src/pair_selection_v2.cc:149-166`,
[COLMAP-SPATIAL-PARITY 2026-09-02] 注释;诊断链见同目录
`2026-09-02-pair-candidate-halving-diagnosis.md`)。build 89 build stamp:
`Sep 2 2026 14:10:19`(会话 `sfm_match_fail.jsonl` 首行 build_stamp)。

**三句判决(细节见 §3):**
1. **每图 verified 伙伴:12.5(51帧场)/ 14.0(20帧场)**,对 07-19 的 5.3–10.3 与同分辨率旧门
   (07-23 三场:7.5/8.6/10.8)都是明确上涨;伙伴数下限从 0–1 抬到 4–7,逐帧候选饥饿清零。
2. **浪费率没有大降:83.0% / 83.3%**(进三角化 17.0%/16.8%,口径见 §2.4)。对 07-19@4K 的
   63.8–80.1% 看起来更差,但那是 4K→12MP 分辨率换代的锅(同 12MP 旧门三场浪费 86.8–90.2%);
   **在可比的 12MP 口径内,配对修复挣回 3.6–7.2 个百分点**。
3. **下一个瓶颈=每对匹配深度,不再是配对图**。铁证是本次两场互为对照:20帧场配对密度 73.7%
   (51帧场只有 25.0%,差 3 倍),覆盖率却一模一样(verified 18.3% vs 19.7%)。每对 verified
   inlier 中位只有 136–146 条(≈8192 预算的 1.7%),每 keypoint 换到的 verified 对应 0.17–0.18,
   只有 07-19@4K(0.44–1.24)的 1/2.4–1/7。

---

## 1. 数据来源(全部电脑侧读文件,未启动 app)

| | 51帧场 | 20帧场 |
|---|---|---|
| 会话目录 | `cap_1788330425726298`(2026-09-02 14:27:05) | `cap_1788331731870643`(14:48:51) |
| 帧数 / 注册 | 51 / 51(100%) | 20 / 20(100%) |
| 点云(delivered) | 22894(任务给定值吻合 meta `delivered_points`) | 9090(吻合) |
| 本地落盘 | `~/Developer/pw_funnel_20260902/cap_1788330425726298/` | `~/Developer/pw_funnel_20260902/cap_1788331731870643/` |

拉取命令(逐文件,避开目录 copy 断连坑):

```bash
xcrun devicectl device copy from --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 \
  --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld \
  --source "Documents/captures_official/<cap>/official_sfm_live.db" \
  --destination "$HOME/Developer/pw_funnel_20260902/<cap>/official_sfm_live.db"
# 同法拉 official_sfm_sparse_meta.json / official_finalize_segments.json / sfm_match_fail.jsonl
```

**旧对照臂(同分辨率、旧选择器)**:电脑上现存的 07-23 设备备份
`~/Developer/device-backups/PocketWorld/com.kyle.PocketWorld_20260723T2148_ratio08_preupdate/Documents/captures_official/`
三场(25/28/38 帧,均 4032×3024),用**同一脚本**重测。07-19 原审计的四场(cap40/41/50/51,
@3840×2160)DB 已不在电脑上,其数字取自记忆勘定段,未重导——只当"4K 时代锚点"用,不进同口径对比。

**分辨率口径(任务问的"09-02 是 12MP 还是 4K")**:两场 cameras 表全部 4032×3024(12.2MP),
且 keypoints blob 实测坐标满幅(image_id=5:x∈[4,4028], y∈[4,3022])⇒ **12MP 全幅提取,不是 4K**。
07-23 三场同为 4032×3024。07-19 四场是 3840×2160 —— **新旧审计跨分辨率,不可直接同口径比**(§5)。

## 2. 方法(逐环节定义 + 可复算)

脚本:`~/Developer/pw_funnel_20260902/funnel2.py`(复用 08-03
`progecttwo/_host_experiments.nosync/probe-gate-recon-20260803/funnel.py` 的定义,加配对图统计)。
核心逻辑:

```python
# pair_id 解码(COLMAP 口径)
i1, i2 = pair_id // 2147483647, pair_id % 2147483647
# 1) 提取量
SELECT image_id, rows FROM keypoints          # 打满率 = rows==8192 占比;利用率 = sum(rows)/(n*8192)
# 2) raw match 覆盖:matches 表(几何验证前)出现过的 keypoint 序号去重
SELECT pair_id, rows, data FROM matches WHERE rows>0   # data = uint32 × rows × 2
# 3) verified 覆盖:two_view_geometries 表 inlier 出现过的 keypoint 序号去重
SELECT pair_id, rows, data FROM two_view_geometries WHERE rows>0
# 5) 配对图:tvg_pairs / C(n,2);每图伙伴数 = 该图出现在几个 rows>0 的 TVG pair 里
```

**4) 进三角化量(口径与 07-19 不同,必须声明)**:build 89 设备端**不落**
`images.bin`/`points3D.bin`(导出函数是 debug-only,"Never called by the app",
`pw-head-0827/vendor/official_sfm/include/official_sfm_c.h:339-344`;已翻遍会话目录 / Library / tmp 确认无模型文件)。
本次用 finalize 摘要复算:

```
进三角化观测数 = n_points3d × track_len     # sum of track lengths = 三角化 point2D 数(每个 point2D 至多属一个 point3D)
进三角化率   = 上式 / total_keypoints
```

`track_len` = `work->ComputeMeanTrackLength()`,与 `n_points3d` 同出一个 recon 对象
(`official_aether_sfm_c.cc:11052-11058`),时点是 **finalize 进场的 live recon(refine 前)**。
07-19 用的是最终 images.bin 的 point2D 隶属。两口径的差 = refine/delivery 掉点
(51帧场 26084→22894)。若按 delivered 点数等 track 长度折算,51帧场 17.0%→14.9%、
20帧场 16.8%→15.9%——**结论对这 2 个百分点的口径差不敏感**(浪费都在 83–85%)。

**6) track 统计**:只有均值(meta `track_len`);**2-view 占比无法复算**(需 points3D.bin,见 §6)。

**阳性对照(尺子先验一遍)**:本脚本在两场复现出 07-19 的三条已知不变量——
几何验证只砍 2.3/4.0 个百分点(07-19 带:1.4–4.9)、verified→三角化产出率 86.2%/91.7%
(07-19 带:81–86%,20帧场略高出)、TVG 对应/帧 = 1468(51帧场),落在 09-02 诊断书
案情表 1186–2379 带内。尺子没坏。

## 3. 结果

### 3.1 新旧对照总表(逐环节;51帧/20帧分列,绝不合并)

| 环节 | 07-19@4K 四场(记忆锚点) | 07-23@12MP 旧门 25帧 | 28帧 | 38帧 | **build89 51帧(疯狂拐弯)** | **build89 20帧** |
|---|---|---|---|---|---|---|
| 图像尺寸 | 3840×2160 | 4032×3024 | 同 | 同 | **4032×3024** | **4032×3024** |
| 总 keypoints | — | 154,821 | 188,845 | 226,252 | **405,277** | **163,840** |
| 打满 8192 占比 | 81.4–99.0% | 28.0% | 21.4% | 21.1% | **88.2%** | **100%** |
| 预算利用率 | 95.0–99.9% | 75.6% | 82.3% | 72.7% | **97.0%** | **100%** |
| raw match 覆盖 | 24.9–49.7%(=100−掉幅) | 18.0% | 21.2% | 28.6% | **23.7%** | **20.6%** |
| verified 覆盖 | — | 14.9% | 17.6% | 20.6% | **19.7%** | **18.3%** |
| 进三角化 | 19.9–36.2% | 9.8% | 13.2% | 12.4% | **17.0%** | **16.8%** |
| **浪费率** | **63.8–80.1%** | 90.2% | 86.8% | 87.6% | **83.0%** | **83.3%** |
| verified pair / C(n,2) | 7.7–23.5% | 31.3%(94/300) | 31.7%(120/378) | 29.3%(206/703) | **25.0%(319/1275)** | **73.7%(140/190)** |
| 每图 verified 伙伴 min/中位/max | 均值带 5.3–10.3 | 1/8/12(均7.5) | 0/9/15(均8.6) | 0/12/16(均10.8) | **4/12/23(均12.5)** | **7/14/19(均14.0)** |
| 每 kp verified 对应 | 0.44–1.24 | 0.12 | 0.16 | 0.19 | **0.18** | **0.17** |
| track 均值 | 2.52–4.11 | 2.178 | 2.487 | 2.522 | **2.643** | **2.871** |
| 2-view 占比 | 47–70% | 无法复算 | 同 | 同 | **无法复算(§6)** | **无法复算** |

### 3.2 漏斗逐段损失(本次两场)

| 段 | 51帧场 | 20帧场 | 07-19 带 |
|---|---|---|---|
| 提取→raw match 掉幅 | −76.3 pp | −79.4 pp | −50.3~−75.1 pp |
| 占总浪费比 | 91.9% | 95.3% | 86.7–95.7% |
| 几何验证砍 | −4.0 pp | −2.3 pp | −1.4~−4.9 pp |
| verified→三角化产出率 | 86.2% | 91.7% | 81–86% |
| (同产出率,07-23 旧门) | 65.8% / 74.9% / 60.3% | | |

### 3.3 配对修复的直接证据(机制侧,非相关)

- **候选不再饥饿**:`sfm_match_fail.jsonl` 的 `tail_match_candidates_v1` 逐帧候选数,两场
  **零帧低于 min(fid, configured_k)**;51帧场 39 帧 ≥12(其余是开场爬坡),20帧场逐帧
  严格 = min(fid,12)(中位 9.5 = 诊断书预言的"完美曲线"上限)。修复前同 build 链路的
  实测是转弯期 n_cand 8→3(诊断书 §3)。
- **k 预算对账**:configured_k 基座 12(=空间10+时间2,`official_aether_sfm_c.cc:1640-1651`
  K-REWIRE 注释;回环检索抬到 14/16/20 共 6 帧,只在 51帧场)。51帧场 live 候选总数 572
  + finalize rematch 96 = 668 次尝试,写库 319 对(48%);20帧场 162+10=172 尝试,写库
  140 对(81%)——疯狂拐弯场的尝试成功率低是场景差异,不是门。
- **每对质量健康**:matches→TVG 的 inlier 率 82.6% / 88.0%,验证层没有在滥杀。

### 3.4 判决

**问1:浪费率降了多少?**
在唯一可比的口径(同 12MP、同脚本)内:旧门三场 86.8–90.2% → 本次 83.0/83.3%,
**降 3.6–7.2 pp**。对 07-19@4K 的 63.8–80.1% 反而更高——这不是修复退步,是 4K→12MP
换代本身把利用率砸掉了(12MP 时代旧门最好也只有 13.2% 进三角化)。**"80% 浪费"的病没好,
只是从 87–90% 回到 83%。**

**问2:每图 verified 伙伴涨到几?**
**均值 12.5(51帧)/ 14.0(20帧),中位 12 / 14**;对 07-19 的 5.3–10.3 与 07-23 同分辨率的
7.5–10.8 都是实涨,且分布下限从 0–1 抬到 4–7(旧门的"某图零伙伴"绝迹)。20帧场的配对图
已接近饱和(伙伴均值 14 / 上限 19,verified pair 占全配对 73.7%)。

**问3:下一个瓶颈在哪一环?**
仍在提取→raw match 段(占总浪费 92–95%),但段内的病因换了:
- **配对图不再 binding**:两场互为对照——配对密度 25.0% vs 73.7%(3 倍差),verified 覆盖
  19.7% vs 18.3%、进三角化 17.0% vs 16.8%(几乎相等)。把配对加密 3 倍买不到覆盖率。
- **现在 binding 的是每对匹配深度**:raw 中位 171/152 条、verified 中位 146/136 条 / 对,
  只占每图 8192 预算的 ~2%;每 kp verified 对应 0.17–0.18,是 4K 时代(0.44–1.24)的
  1/2.4–1/7。约 80% 的 keypoint 在任何一对里都从未被 raw match 命中,而命中的 ~20% 在
  多对之间反复命中(51帧场 verified 槽位 149,702 个 vs 去重 keypoint 79,945 个,重复度 1.87×,
  正好托出 track 均值 2.6)。
- 修复真正"挪走"的浪费在下游:verified→三角化产出率从旧门的 60–75% 抬到 86–92%
  (伙伴多了,几何一致性检验更容易凑齐),track 均值 2.18–2.52 → 2.64–2.87。这就是那
  3.6–7.2 pp 的来源。
- **为什么 12MP 的每对深度只有 4K 的几分之一——本次未定罪**。候选假设(全部未验,按记忆
  纪律列出不采信):① 固定 8192 预算按 (octave, scale) 降序裁剪,12MP 下拿到的是更粗尺度、
  更稀疏的特征集(07-19 审计的 UNRESOLVED 框架);② 像素阈值随分辨率被动收紧(4K→12MP
  ×1.21,COLMAP issue #1278);③ ratio test / 互检在 12MP 纹理上的杀伤;④ GPU 匹配路径的
  内部上限。**下一刀应该打在"每对匹配深度"上,并且上机前按毫秒对照纪律预算**(match_ms
  ≈44ms/候选,深度翻倍很可能不加 ms,但要实测)。

## 4. 相关≠机制:归因边界

- "伙伴上涨/饥饿清零"可以归因到修复:机制链(45° 门删除→候选不掉)在诊断书里用变异测试
  钉死(旧代码同场景 spatial_count=1,与实测谷底 n_cand=3 逐字吻合),本次遥测零饥饿帧是
  该预言的真机验证。
- "浪费 −3.6~−7.2 pp"**只能弱归因**:对照臂(07-23)与本次隔了 40 天、十几个 build
  (含 08-27 整体回滚)、场景不同、拍法不同(07-23 打满率仅 21–28%,说明当时素材糊/弱纹理,
  本次 88–100%);备份目录名带 `ratio08`,不能排除那三场跑的是 ratio 实验配置。
  方向一致(产出率 60–75%→86–92% 与"伙伴变多"机制吻合),但幅度不当定论。
- "浪费率对 07-19 变差"**不归因**给任何代码:跨 4K/12MP,不可比。

## 5. 局限(如实列)

1. **跨分辨率**:07-19 基线 @3840×2160,本次 @4032×3024。raw/verified/三角化各环节全部
   受分辨率影响(见 §3.4 假设①②),新旧总表里 07-19 列只当锚点。
2. **进三角化口径**:07-19=最终 images.bin 逐 point2D;本次=finalize 进场 recon 的
   `n_points3d×track_len`(refine 前)。两口径差 ≤2.1 pp(§2.4),不改判决。
3. **对照臂非同场同期**:见 §4 第二条。
4. **DB 写库策略变了**:07-23 的 DB 给验证失败对留 rows=0 的 TVG 行(190 attempted /94 过),
   build 89 失败对整对不落库(尝试数只在遥测里)。故 07-23 的 raw 覆盖含"后来验证失败的对"
   的贡献、build 89 的不含——此偏差方向使本次的 raw 覆盖被**低估**,改善判断偏保守。
5. **TVG config 换代**:本次 config=2(CALIBRATED)为主 + 26 对 config=6
   (PLANAR_OR_PANORAMIC,纯旋转/平面嫌疑,两场各 26 对,这些对的 inlier 未必可三角化);
   07-23 全 config=3(UNCALIBRATED)。verified 覆盖的语义因此略有漂移。
6. **单次采集,无重复跑**:07-19 审计已把"run-to-run 稳定"证伪过;本次每场只有一跑,
   变差带未知。

## 6. 不确定 / 缺数(宁空不编)

- **2-view track 占比**:无 points3D.bin,复算不了。07-19 的 47–70% 无新值可对。
  想要它 = 下次采集前设 `OFFICIAL_AETHER_LIVE_POSE_DUMP`(`official_aether_sfm_c.cc:11035-11047`,
  env-gated,app 默认不设)或起 host 工具从 db 重放——两者都归主线拍板,本次不动。
- **旧门三场当时的确切 build/配置**(`ratio08` 是否影响匹配深度)——查无 receipt。
- **12MP 每对深度塌陷的机制**(§3.4 四个假设)——全部未验。

## 7. 复算索引

- 脚本:`~/Developer/pw_funnel_20260902/funnel2.py`(python3 funnel2.py <db>,输出即 §3 各数)
- 每对深度/邻接分布:同目录下内联脚本(报告作者会话),核心 SQL:
  `SELECT rows FROM matches WHERE rows>0` / `SELECT pair_id,rows FROM two_view_geometries WHERE rows>0`
- 进三角化:`python3 -c "import json;m=json.load(open('official_sfm_sparse_meta.json'));s=m['summary'];print(s['n_points3d']*s['track_len'])"`
  除以 `SELECT SUM(rows) FROM keypoints`
- 候选遥测:`jq 'select(.type=="tail_match_candidates_v1") | {fid, configured_k, n: (.match_candidate_ids|length)}' sfm_match_fail.jsonl`
- 07-19 锚点:`~/.claude/projects/-Users-kaidongwang-Documents-progecttwo/memory/project_pocketworld_feature_budget_funnel_audit.md`
- 修复源码:`~/Developer/aether_cpp/official_pipeline/src/pair_selection_v2.cc:148-201`(新路径),
  `:15,:21-32`(45° 门只残存于 legacy 函数);k=12 出处 `official_aether_sfm_c.cc:1640-1651`

(本报告未 commit;所有产物在 `~/Developer/pw_funnel_20260902/`,未写 /tmp、未碰 iCloud,
全程未启动 app、未装机、未改产品代码。)
