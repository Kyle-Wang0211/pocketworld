# 配对候选数腰斩疑案 —— 诊断与修复交接(2026-09-02)

任务:诊断 `n_cand`(每帧配对候选数)在 09-01 → 09-02 之间无代码变更的"腰斩",对齐上游 COLMAP 语义,动刀修复。
结论先行:**诊断 (b)——腰斩来自自设偏离:空间候选选择器里的 45° 主光轴夹角门(view-angle cone)**。COLMAP 的任何配对源都没有这种门。已按 COLMAP `SpatialPairGenerator` 语义替换(一刀、只此一刀),diff 与测试见 §4。

- 修改文件(留在工作区,未 commit):
  - `~/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/pair_selection_v2.cc`(经 `~/Developer/aether_cpp` 符号链接)
  - 新增测试 `~/Developer/Aether3D-cross/aether_cpp/official_pipeline/tests/pair_selection_v2_colmap_parity_test.cc`
- ⚠️ App 消费的是预编译产物(`pw-head-0827/vendor/official_sfm/libs/ios-arm64`,冻结配方见 `vendor/official_sfm/PROVENANCE.md`)。此 diff 不重编 `.a` 不会上机 —— 重编/装机/真机验证归主线。

---

## 1. 决策链清单(交付物 A):从"新照片入列"到"n_cand 定值"

遥测口径先钉死:**`n_cand` = 本帧匹配循环遍历的候选帧数 = `candidates.size()`**。计数在循环头无条件自增,probe-gate 的跳过发生在计数**之后**,不影响 n_cand:

`official_aether_sfm_c.cc:9433-9436`
```cpp
    for (size_t cand_i = 0; cand_i < candidates.size(); ++cand_i) {
      const int j = candidates[cand_i];
      const FrameRecord& prev = s->frames[j];
      ++n_cand;
```

(以下 file:line 均指 `~/Developer/aether_cpp/official_pipeline/src/` 下的现役源码;Dart 指 `~/Developer/pw-head-0827/lib/`。)

### 链路总览

```
拍照(auto_capture 触发)→ Dart offerFrame→spool→_pump→worker isolate
  → addJpegFrame(FFI)→ native aether_sfm_add_jpeg_frame
    → K 解析(①②)→ SelectSpatialK20TemporalT2Candidates(③)
    → visual loop 追加(④)→ sort/unique(⑤)
    → 匹配循环 ++n_cand(⑥)→ last_n_cand → debug_last → frame_done → 遥测行(⑦)
```

### ① K 预算解析链 —— 对拍摄几何**不敏感**

`official_aether_sfm_c.cc:9157-9176`
```cpp
    static const int env_base_k = [] {
      if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_CAND_K")) { ... }
      return 0;  // 0 = use options.k_neighbors
    }();
    ...
    const int base_k = env_base_k > 0
                           ? env_base_k
                           : (s->options.k_neighbors > 0 ? s->options.k_neighbors
                                                         : 6);
    const int thermal_now = s->thermal_state.load(std::memory_order_relaxed);
    const bool throttled = thermal_now >= 2 && hot_k > 0 && hot_k < base_k;
    const int k = throttled ? hot_k : base_k;
```
生产 `k_neighbors = 12`:Dart 创建会话时传 `researchKNeighbors`(`official_aether_sfm_ffi.dart:993` `static const int researchKNeighbors = 12;`,`:1003` 默认参数,`:1021` 写入 options)。env 未设、热闸默认关(`hot_k=0`,`:9164-9168`)。四场遥测 `throttled_cum` 全程 0 → 热闸未触发,已复核。

### ② 热降档 —— 未触发(本案不敏感)

同上 `:9175-9180`;判据 `throttled_cum=0`(四场 `frame` 遥测行末帧均为 0)。

### ③ SelectSpatialK20TemporalT2Candidates —— 候选的主生成器

入口 `official_aether_sfm_c.cc:9197-9200`
```cpp
    int cand_spatial = 0, cand_temporal = 0;
    std::vector<int> candidates =
        SelectSpatialK20TemporalT2Candidates(
            *s, rec, frame_id, throttled, k, &cand_spatial, &cand_temporal);
```

**③a 配置默认值**(`pair_policy_v2_c.cc:23-44`)
```cpp
  out_config->spatial_k = 20;
  out_config->temporal_lookback = 2;
  out_config->spatial_recent_exclusion = 2;
```
但常态空间名额**不用** 20,用调用方 k(08-06 用户签决 K-REWIRE),`official_aether_sfm_c.cc:1650-1653`:
```cpp
  config.spatial_k =
      std::max(0, thermal_spatial_k - abi_config.temporal_lookback);
  (void)thermal_throttled;
  config.temporal_lookback = abi_config.temporal_lookback;
  config.spatial_recent_exclusion = abi_config.spatial_recent_exclusion;
```
即 **spatial_k = 12 − 2 = 10,temporal = 2,recent_exclusion = 2 → n_cand 上限 12**(+回环)。四场观测 max 恰为 12 → 现役源码树与在机二进制行为吻合(又一指纹:S2/S3 前段 n_cand 严格 = fid,与 T2+S10 的 `min(fid,12)` 理论曲线逐帧一致)。

**③b 紧急开关**(`:1600-1607`):`OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY=1` 时改走 legacy `SelectStreamCandidates`。未设,不走。

**③c history 映射**(`:1609-1637`):逐帧填 `pose_valid = previous.has_pose`、`matchable = n_keypoints > 0 && !descriptors.empty()`、中心/朝向向量。**帧内在属性,不随当前帧变**。

**③d V2 选择器本体**(`pair_selection_v2.cc:131-202`,改动前原文):

空间源(修改前 `:148-181`):
```cpp
  if (spatial_k > 0 && current.pose_valid) {
    const double min_dot = std::cos(ViewAngleMaxRad());
    std::vector<std::pair<double, int32_t>> compatible;
    compatible.reserve(history.size());
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < 0 || previous.frame_id >= current.frame_id ||
          !previous.pose_valid || !previous.matchable) {
        continue;
      }
      if (recent_exclusion > 0 &&
          previous.frame_id >= current.frame_id - recent_exclusion) {
        continue;
      }
      const double dot = std::clamp(
          Dot(current.forward_xyz, previous.forward_xyz), -1.0, 1.0);
      if (dot < min_dot) continue;                       // ★★★ 45° 视角门
      compatible.emplace_back(
          SquaredDistance(current.center_xyz, previous.center_xyz),
          previous.frame_id);
    }
    result.spatial_count = std::min<int32_t>(
        spatial_k, static_cast<int32_t>(compatible.size()));
    std::partial_sort(...);          // 按米制距离平方取最近 spatial_k 个
    ...
  }
```
45° 常量与 env 旋钮(`pair_selection_v2.cc:15-32`):
```cpp
constexpr double kViewAngleMaxDegDefault = 45.0;
...
double ViewAngleMaxRad() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_VIEW_ANGLE_MAX_DEG");
    double deg = kViewAngleMaxDegDefault;
    ...
```

时间源(`:183-198`):
```cpp
  if (temporal_lookback > 0) {
    const int32_t oldest_temporal_id =
        current.frame_id - temporal_lookback;
    for (const PairSelectionFrameV2& previous : history) {
      if (previous.frame_id < oldest_temporal_id ||
          previous.frame_id >= current.frame_id || !previous.matchable) {
        continue;
      }
      candidates.push_back({... kTemporal});
      ++result.temporal_count;
    }
  }
```
合并去重(`:105-129` `MergeCanonicalPairCandidatesV2`,canonical pair + source_mask 并集)。

**逐谓词"几何敏感性"判定**(物理间距变大/物体变大/走位更散会不会让它减产):

| 谓词 | file:line | 输入量 | 会否减产 |
|---|---|---|---|
| `spatial_k>0 && current.pose_valid` | pair_selection_v2.cc:148 | 当前帧有无 ARKit 位姿 | 会(位姿丢→空间源全灭,只剩 T2)。**已排除**:四场 tracking 全程 normal(见 §3),且 dip 期间 n_cand=3-6 > 2 ⇒ 空间源仍在产 |
| 帧 id 范围 / `pose_valid` / `matchable` | :153-155 | 帧内在属性 | 会(帧被撤回/无特征)。**已排除**:S3/S4 零撤回、零 reject、恢复段 n_cand 回 12 证明池子完好(帧内在属性不随当前帧变,若 f0-f8 在 fid12 不可用,fid17 也必不可用——但 fid17 = 12) |
| `recent_exclusion`(排除最近 2 帧) | :157-160 | 纯序号 | 不会(T2 恰好补回这 2 帧) |
| **45° 视角门** `dot < min_dot → continue` | :161-163 | **当前帧朝向 × 历史帧朝向** | **会——这是整条链里唯一"依赖当前帧几何且限制数量"的条款**。相机朝向每帧扫 ~10-15°(转角触发 10°/张)时,±45° 锥内只装得下 ~4-9 张历史帧 |
| KNN `partial_sort` 按米制距离² | :164-173 | 米制距离 | **不会**——纯 K 近邻无距离上限,距离只决定"选哪些",不决定"选多少"。案情假设的"米制距离阈值挑邻居"不成立:这里没有阈值 |
| T2 时间窗 | :183-198 | 纯序号 | 不会 |
| 合并去重 | :200 | — | 不会(S 排除近 2 帧,T 恰是近 2 帧,常态零重叠) |

**静默出口标注(重点)**:被 45° 门丢掉的历史帧**无任何计数痕迹**——`cand_spatial/cand_temporal`(累计入 `stat_cand_spatial_first_pairs`,`official_aether_sfm_c.cc:9227-9228`)只统计**入选者**,没有"被视角门拒绝数"计数器。本案元凶恰好是全链唯一无埋点的丢弃路径(静默出口=头号复发缺陷,又+1)。次要静默出口:回环检索 `catch (...) {}`(`:9222-9224`,fail-closed 但无痕)。

### ④ 视觉回环追加 —— 只增不减,不敏感

`official_aether_sfm_c.cc:9205-9221`
```cpp
      const std::vector<aether::sfm::VisualLoopCandidateV1> loop_candidates =
          s->visual_loop_index.QueryAndAdd(
              frame_id, rec.descriptors.data(), rec.n_keypoints, candidates);
      for (const aether::sfm::VisualLoopCandidateV1& loop : loop_candidates) {
        if (loop.frame_id < 0 || loop.frame_id >= frame_id) continue;
        const FrameRecord& previous = s->frames[loop.frame_id];
        if (previous.image_id == 0 ||
            s->db->ExistsMatches(previous.image_id, image_id) ||
            s->db->ExistsTwoViewGeometry(previous.image_id, image_id)) {
          continue;
        }
        candidates.push_back(loop.frame_id);
      }
```
配置 `visual_loop_index_v1.h:17-26`:`query_period=5, topup=8, recent_exclusion=20`。四场未见 >12 尖峰(短会话里 S/T 已覆盖近邻,回环去重后无增量)。

### ⑤ sort/unique(`:9219-9221`)—— 不敏感。

### ⑥ 计数与回读

`:9436` `++n_cand`(见节首);`:10350` `s->last_n_cand = n_cand;`;失败复位 `:10682`(仅提取失败路径,四场 `extract_path` 全 `gpu`、`result=ok`,不在场)。
`aether_sfm_debug_last`(`:12134-12140`)把 `last_n_cand` 交给 Dart。

### ⑦ Dart 遥测出口(纯搬运,不敏感)

worker:`sfm_live_recon.dart:1974`(`session!.debugLast()`)→ `:2012`(`'nCand': dbg.nCand` 入 frame_done);facade:`:1318`(`if (msg['nCand'] != null) 'n_cand': msg['nCand']` 组 JSONL frame 行)。

### 不在链上的配对源(核实过,不影响 n_cand)

- `AddOfficialQuadraticPairs`(COLMAP 二次幂回环补配):只在 finalize(`:8190/:8200`)与 idle 预付 `PrepayQuadraticTick`←`aether_sfm_live_repay`(`:12467/:12901-12909`)调用,晚写 db,不进 add_frame 的 `candidates`。
- probe-gate:默认关(`ProbeGateMin` `:2315-2344`,08-08 当天回退,env 才能再武装),且即使开着也是计数后跳过。
- `SelectStreamCandidates`(legacy,`:1496-1571`,同款 45° 门在 `:1534/:1540-1543`)与 `SelectLegacySpatialCandidatesV2`(`pair_selection_v2.cc:49-103`):仅 `OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY=1` / bench 可达,生产不走。
- bench 平行树 `third_party/glomap_vendor/bench/aether_sfm_c.cc`:非 shipping 编译单元(shipping 目标 `pwofficial_core` 的编译清单只含 `official_pipeline/src/pair_selection_v2.cc`,见 `official_pipeline/build-ios-device/CMakeFiles/pwofficial_core.dir/DependInfo.cmake:53`)。

---

## 2. 上游 COLMAP 对照

上游依据两份互相印证的源:
- **vendored 树**(本管线血统):`~/Developer/aether_cpp/third_party/glomap_vendor/colmap-src`,`CMakeLists.txt:81` `set(COLMAP_VERSION "3.14.0.dev0")`,文件 `colmap/controllers/pairing.{h,cc}`;
- **GitHub main**(2026-09-02 curl 取回,HTTP 200):`src/colmap/controllers/pairing.{h,cc}`(任务提示的 `src/colmap/feature/pairing.cc` 在 3.x 树里实际位于 `controllers/`;`src/feature/matching.cc` 是更旧版路径)。两份 diff 仅哈希容器/头文件重构,语义无差。下面行号:V=vendored,U=upstream main。

### Sequential matching(顺序配对)

选项(V pairing.h:88-91 / U pairing.h:89-92):
```cpp
  // Number of overlapping image pairs.
  int overlap = 10;

  // Whether to match images against their quadratic neighbors.
  bool quadratic_overlap = true;
```
主循环(V pairing.cc:518-538 / U pairing.cc:~580,一致):
```cpp
  for (int i = 0; i < options_.overlap; ++i) {
    if (options_.quadratic_overlap) {
      const size_t image_idx_2_quadratic = image_idx_ + (1ull << i);
      if (image_idx_2_quadratic < image_ids_.size()) {
        const image_t image_id2 = image_ids_.at(image_idx_2_quadratic);
        image_pairs_.emplace_back(image_id1, image_id2);
        ...
    } else {
      const size_t image_idx_2 = image_idx_ + i + 1;
      ...
```
**语义:纯序号。每图与后 `overlap` 张(或 2^i 跳距)配对,与位姿/朝向/距离一概无关。**

### Spatial matching(空间配对)

选项(V pairing.h:170-178 / U pairing.h:176-184):
```cpp
  // The maximum number of nearest neighbors to match.
  int max_num_neighbors = 50;

  // The minimum number of nearest neighbors to match. Neighbors include those
  // within max_distance or to satisfy min_num_neighbors.
  int min_num_neighbors = 0;

  // The maximum distance between the query and nearest neighbor. For GPS
  // coordinates the unit is Euclidean distance in meters.
  double max_distance = 100;
```
主循环(V pairing.cc:637-667 / U pairing.cc:706-731,一致):
```cpp
  const float max_distance_squared =
      static_cast<float>(options_.max_distance * options_.max_distance);
  for (int j = 0; j < knn_; ++j) {
    // Check if query equals result.
    if (index_matrix_(current_idx_, j) == static_cast<int>(current_idx_)) {
      continue;
    }
    // Since the nearest neighbors are sorted by distance, we can break
    // once the distance is too large and enough neighbors are collected.
    if (distance_squared_matrix_(current_idx_, j) > max_distance_squared &&
        j > options_.min_num_neighbors) {
      break;
    }
    ...
    image_pairs_.emplace_back(image_id, nn_image_id);
  }
```
**语义:位置 KNN + max_distance 截断。资格判定只看位置先验存在与距离(`ReadPositionPriorData` V pairing.cc:669-;无位置先验的图不进索引)。没有任何朝向/视角条款。**

### 我们与上游的逐条偏离(修复前)

| # | 条款 | 我们(修复前) | 上游 | 减产敏感性 |
|---|---|---|---|---|
| 1 | **视角门** | `dot(forward_i, forward_j) < cos45° → 剔除`(pair_selection_v2.cc:161-163;env `OFFICIAL_AETHER_VIEW_ANGLE_MAX_DEG` 可调,:21-32) | **不存在**(Sequential 纯序号;Spatial 只看位置) | **有——本案元凶** |
| 2 | 空间预算 | spatial_k = 12−2 = 10(official_aether_sfm_c.cc:1650-1651) | spatial `max_num_neighbors = 50`(pairing.h V:170);sequential `overlap = 10`(V:88) | 名额差异,但两天同为 10,非变量 |
| 3 | 距离上限 | 无(纯 KNN) | `max_distance = 100`(V:178)+ `j > min_num_neighbors` 截断(V pairing.cc:655-656) | 少做的步骤;室内米级场景 100m 永不触发,不减产 |
| 4 | 时间窗 | T2:仅最近 2 帧(pair_selection_v2.cc:183-198) | sequential `overlap=10`:后 10 张序号邻居 | 我们的时间保底比上游薄 5 倍——dip 期间上游 sequential 仍会给满 10 对,我们只剩 2+少量空间 |
| 5 | 回环 | 自研 visual_loop_index(p5/top8,visual_loop_index_v1.h:17-26)+ finalize 处 `AddOfficialQuadraticPairs` | sequential `quadratic_overlap`(2^i,V pairing.cc:521)/ `loop_detection`(词汇树) | 只增不减,非本案变量 |
| 6 | 位置先验来源 | ARKit 相机中心(实时) | PosePrior(GPS/先验数据库) | 等价映射,不敏感 |
| 7 | recent_exclusion=2 | 空间源排除最近2帧(:157-160) | 无此概念(spatial 会把时间近邻也算 KNN) | 与 T2 互补,净效果为零 |

我们的实现声称复刻的是"空间优先"产品策略(08-03 SPATIAL-K20 注释、08-06 K-REWIRE 用户签决),**并非**对上游任何一个 PairGenerator 的忠实复刻;其中条款 2/4/5/7 是签决过的产品预算结构,条款 1(视角门)是无上游对应物的自设启发式(源码注释里自认参考 hloc 的 pairs_from_poses 用 30°——hloc 之说未核源,仅注释转述,见 §5)。

---

## 3. 诊断:(b)自设偏离 —— 45° 视角门

### 机制(排除法闭合)

n_cand 的上游依赖里,**唯一**既"依赖当前帧几何"又"限制候选数量"的谓词是视角门(§1 表)。其余候选嫌疑逐一出局:

- **热闸**:`throttled_cum=0` 四场全程(frame 遥测行)。
- **当前帧位姿丢失**(spatial→0):若成立,dip 期间 n_cand 应恰为 2(T2);实测 3-6。且 tracking 事件四场拍摄期零 limited 转换(仅开场 initializing,首帧喂入前已 normal;S1 11:53:20 normal,首帧 11:53:22)。
- **历史帧被撤回/不可匹配**(毁片/photo gate 回删):S3/S4 `actual_photo_gate` 20/20 全 accept、native `photo_feedback_retracted` = 0;更硬的证据:`usable`/`matchable` 是帧内在属性,**不依赖当前帧**——若 f0-f8 在 fid12 时不可用,fid17 时也必不可用,但 fid17 的 n_cand=12(需要 ≥10 个空间可选帧)⇒ 池子全程完好,dip 是"当前帧视角"造成的。
- **计数/状态污染**(诊断 c):n_cand 在 S3 前 9 帧严格等于 fid(0,1,2,…,8),dip 后又精确回到上限 12——计数器坏不会与帧序锁步恢复。
- **提取失败复位**(:10682):`extract_path` 四场全 `gpu`,`result=ok`。

### 遥测验证(四场逐帧,n19_telemetry_official_dart.jsonl,按 finalize_phase1 切场)

| 场 | finalize | 帧数 | n_cand 中位 | 逐帧 fid:n_cand |
|---|---|---|---|---|
| S1 | 09-01 11:54:37 | 20 | 7.0 | 0:0 1:1 2:2 3:3 4:3 5:4 6:5 7:6 8:6 9:6 10:8 11:10 12:12 13:12 14:11 15:12 16:12 17:12 18:12 19:12 |
| S2 | 09-01 13:54:46 | 22 | 9.0 | 0:0 … 8:8 9:9 10:8 11:9 12:12 13:12 14:9 15:12 … 21:12 |
| S3 | 09-02 12:58:59 | 20 | 4.5 | 0:0 1:1 … 8:8 **9:4 10:5 11:4 12:3 13:3 14:4 15:6 16:8** 17:12 18:12 19:12 |
| S4 | 09-02 13:00:03 | 20 | 6.5 | 0:0 … 7:7 **8:6 9:6 10:6** 11:9 12:10 13:12 … 18:12 19:7 |

(与案情表对账:n_cand 中位 7/9/4.5≈4/6.5≈6 ✓;`tvg_pairs_cum` 末帧 47044/52340/23711/31354,除以帧数 = 2352/2379/1186/1568 = 案情表 TVG/帧 ✓。)

三个结构事实:
1. **理论天花板本来就低**:S10+T2 下 n_cand=min(fid,12),20 帧会话的**完美**中位数只有 9.5(22 帧 10.5)。所以"7 vs 9"的 09-01 已接近满配;"腰斩"的全部缺口来自——
2. **会话中段塌方**:S3 在 fid 9 从 8 骤跌到 4,谷底 3(= 空间 1 + 时间 2),fid 17 满血回 12。总缺口:S3 少 53 对(109 vs 162 理论),S1/S2/S4 分别少 13/9/18 对。
3. **方向性矛盾坐实"门不看图像"**:今天相邻照片 LK 重叠 ~84%(昨天 ~62%),视觉上更近,候选却更少——因为门只看**位姿朝向**,与外观零耦合。转角触发(10°/张)主导时,朝向每张扫 ~10°+,±45° 锥内只装得下 ~4-9 张历史帧;auto_capture 收盘遥测的 fire_turn_deg(环形缓存,末 3 张)S3=13.1/9.0/10.3°、S4=8.8/7.5/23.5°,与 ~10°/张的扫速一致。

### 可证伪预测 → 验证结果

| 预测(若诊断成立) | 遥测验证 |
|---|---|
| P1 dip 必须是**中段塌方且可恢复**(转弯扫过锥→转完回锥),而非单调衰减/永久损失 | ✓ S3:8→4→3→…→12;S4:7→6→…→12 |
| P2 dip 谷底 > 2(空间源仍有产出,当前位姿有效) | ✓ 谷底 3(=1 空间+2 时间),从未跌到 2 |
| P3 dip 期间 tracking 无 limited 转换、无帧撤回 | ✓ 四场拍摄期 tracking 全 normal;gate 全 accept;retracted=0 |
| P4 恢复段 n_cand 回到**精确** 12(池子完好,只是当前帧朝向变了) | ✓ S3 fid17-19、S4 fid13-18 均 =12 |
| P5 合成复算:朝向 15°/帧匀速扫、其余变量不动,旧代码空间源应塌到 ~1 | ✓ 变异测试(§4):旧代码 spatial_count=1(+T2=3,与 S3 谷底 3 逐字吻合);新代码 =10 |
| P6 若换上游语义(序号窗/位置KNN),同样的走位不减产 | ✓ 新代码同场景 n_cand=12(测试场景 1) |

### 为什么不是 (a)"上游忠实行为的正常响应"

两天的走位确实不同(转弯多少),但把"走位不同"放大成"候选腰斩→TVG 腰斩→点云 8718 vs 13237"的**规则**在上游不存在:同样的 09-02 走位,COLMAP sequential(overlap=10)每帧照给 10 对,COLMAP spatial(KNN+100m)照样满配。响应场景变化的是自设条款,不是上游参数。

---

## 4. 修复

### 刀法(一次一个变量)

只改诊断指认的条款:`SelectSpatialTemporalCandidatesV2` 的空间资格判定,从"45° 视角门 + 无上限 KNN"替换为 COLMAP `SpatialPairGenerator::Next()` 的"位置 KNN + max_distance 截断"。参数取上游默认:`max_distance=100`(V pairing.h:178)、`min_num_neighbors=0`(V:174);空间名额仍走既有 `config.spatial_k`(=10,08-06 签决预算,**不动**)。T2/回环/去重/排序全部不动。legacy 两处同款门(bench/env 逃生路径)按"一变量"纪律**不动**。

上游 break 谓词的逐字转写说明:上游 KNN 结果含查询自身(j=0,身份检查跳过),我们的 `compatible` 不含自身,故 0-based index 映射到上游 j−1,转写为 `index + 1 > kSpatialMinNumNeighbors`(min=0 时语义=任何越界邻居即停,与上游对真实邻居的行为逐点一致)。

许可:COLMAP BSD-3-Clause,允许照抄代码文本;所抄为谓词+默认值数行,已在代码注释里标明出处(vendored 树自带上游 LICENSE;`pw-head-0827/THIRD_PARTY_NOTICES` 已有 COLMAP 条目体系,主线若要可在其中补一行本次转写的指涉)。

### diff 全文

⚠️ 这是 `diff -u`(统一格式),**不是** `git diff` 输出:`Aether3D-cross` 是 git worktree,gitdir 指向 `~/Documents/Aether3D/.git`(iCloud File Provider 路径),`git diff`/`git log` 实测 90s+ 挂死(已知 iCloud 挂死坑),故对改动前备份做 diff。改动只有这一个文件 + 新增测试文件(全文在仓库里,略)。

```diff
--- a/aether_cpp/official_pipeline/src/pair_selection_v2.cc
+++ b/aether_cpp/official_pipeline/src/pair_selection_v2.cc
@@ -146,7 +146,26 @@
       static_cast<size_t>(spatial_k + temporal_lookback));
 
   if (spatial_k > 0 && current.pose_valid) {
-    const double min_dot = std::cos(ViewAngleMaxRad());
+    // [COLMAP-SPATIAL-PARITY 2026-09-02] Spatial eligibility now replicates
+    // COLMAP SpatialPairGenerator::Next() (colmap/controllers/pairing.cc,
+    // vendored tree third_party/glomap_vendor/colmap-src, COLMAP 3.14.0.dev0,
+    // BSD-3-Clause): position-KNN sorted by distance, cut by max_distance —
+    // and NOTHING else. The former self-invented 45-degree forward-axis gate
+    // (view-angle cone) is REMOVED from this production path: it made the
+    // candidate COUNT collapse whenever the camera forward axis swept through
+    // a turn (n_cand 8→3 mid-session, 2026-09-02 telemetry), which no COLMAP
+    // pair source does. Upstream defaults (pairing.h): max_distance = 100,
+    // min_num_neighbors = 0. Upstream break predicate (pairing.cc, Next()):
+    //   if (distance_squared_matrix_(current_idx_, j) > max_distance_squared
+    //       && j > options_.min_num_neighbors) break;
+    // where j indexes the KNN result INCLUDING the query itself at j == 0
+    // (skipped via an identity check). Our `compatible` list never contains
+    // the query, so our 0-based index maps to upstream's j - 1; the literal
+    // transcription is therefore `index + 1 > kSpatialMinNumNeighbors`.
+    constexpr double kSpatialMaxDistance = 100.0;   // COLMAP pairing.h default
+    constexpr int32_t kSpatialMinNumNeighbors = 0;  // COLMAP pairing.h default
+    const double max_distance_squared =
+        kSpatialMaxDistance * kSpatialMaxDistance;
     std::vector<std::pair<double, int32_t>> compatible;
     compatible.reserve(history.size());
     for (const PairSelectionFrameV2& previous : history) {
@@ -158,25 +177,26 @@
           previous.frame_id >= current.frame_id - recent_exclusion) {
         continue;
       }
-      const double dot = std::clamp(
-          Dot(current.forward_xyz, previous.forward_xyz), -1.0, 1.0);
-      if (dot < min_dot) continue;
       compatible.emplace_back(
           SquaredDistance(current.center_xyz, previous.center_xyz),
           previous.frame_id);
     }
 
-    result.spatial_count = std::min<int32_t>(
+    const int32_t knn = std::min<int32_t>(
         spatial_k, static_cast<int32_t>(compatible.size()));
-    std::partial_sort(compatible.begin(),
-                      compatible.begin() + result.spatial_count,
+    std::partial_sort(compatible.begin(), compatible.begin() + knn,
                       compatible.end());
-    for (int32_t index = 0; index < result.spatial_count; ++index) {
+    for (int32_t index = 0; index < knn; ++index) {
+      if (compatible[index].first > max_distance_squared &&
+          index + 1 > kSpatialMinNumNeighbors) {
+        break;
+      }
       candidates.push_back(
           {.first_frame_id = compatible[index].second,
            .second_frame_id = current.frame_id,
            .source_mask =
               static_cast<uint32_t>(PairCandidateSourceV2::kSpatial)});
+      ++result.spatial_count;
     }
   }
```

副作用说明:env 旋钮 `OFFICIAL_AETHER_VIEW_ANGLE_MAX_DEG` 在生产路径失效(仅 legacy 仍消费);`Dot`/`ViewAngleMaxRad` 仍被 legacy 使用,无 unused 警告(`-Wall -Wextra` 干净)。

### 测试(不 commit,已在工作区)

`official_pipeline/tests/pair_selection_v2_colmap_parity_test.cc`(仿 `global_ptol_policy_test.cc` 的 plain-main 风格;pair_selection_v2.cc 零外部依赖,host 直接编译):

```
clang++ -std=c++20 -Wall -Wextra -I../src \
  ../src/pair_selection_v2.cc pair_selection_v2_colmap_parity_test.cc -o <bin>
```

5 个场景:① 15°/帧转弯扫掠不减产(spatial=10,总对数 12);② 同位对脸(180°)帧必须可选;③ max_distance=100 截断(3 近 2 远→只取 3);④ 当前帧无位姿→spatial=0/T2 不变(回归钉);⑤ source_mask 并集语义不变(回归钉)。

结果:
- **新代码:PASS**(5/5)。
- **变异验证(旧代码跑同一测试,必须红)**:FAIL 6 处——其中场景① `spatial_count got 1`:15°/帧扫掠下旧门只放行 1 个空间候选,+T2=3,**与 S3 实测谷底 n_cand=3 逐字吻合**。变异副本建在 scratchpad,工作区无残留。

Dart 侧无对应测试目标(候选选择纯 native;`pw-head-0827/test/` 里无配对候选测试),故未跑 flutter test;未启动 app、未碰真机。

### 成本预期与积压核查(规矩 3)

- 实测斜率:match_ms/n_cand 中位 43.8/44.6/41.6/50.3 ms(S1-S4)——与 40-60ms/候选预算一致(GPU 路径,cpu_pairs 四场全 0)。
- 候选恢复的增量(以 min(fid,12) 理论曲线为修复后预期):S3 +53 对/场(109→162),按 44ms/对 ≈ **+2.3s 全场增量**,摊在 39s 拍摄里;**单帧最坏** fid12:3→12 = +9 对 ≈ **+400ms**(proc_ms 由 ~680 升至 ~1100,与 S1/S2 已实测的满配帧 proc_ms 996-1119ms 同量级)。S1/S2/S4 增量 +13/+9/+18 对。n_cand 中位预期回到 9.5(20 帧场)/10.5(22 帧场)——**注意上限就是 9.5/10.5,不是案情表的 7-9;7-9 本身已含 09-01 的轻度视角门损耗**。
- 不积压的机制(代码钉):在途上限 `kSfmFeedMaxInFlight = 2`(`sfm_feed_queue.dart:23`),满了溢写磁盘 spool、快门不回压、finalize 等排空(`sfm_feed_queue.dart:28-48`,07-12 签决三角:不限流/不丢帧/不降质)。实测余量:四场 queue max 0-1、inflight max 1、spool_wait max 193ms;帧节奏中位 1.34-2.53s、最小间隔 0.78s > 满配帧 proc_ms ~1.1s(+0.4s 后最坏 ~1.5s,超过最小间隔的帧会短暂进 spool,由磁盘队列吸收,无丢帧路径)。

### 上机后的验证判据(留给主线)

修复成立 ⇒ 下一次 20 帧会话:n_cand 逐帧 = min(fid,12)(仅在 tracking limited 时允许跌到 2);任何转弯走位不再出现中段塌方;TVG/帧回到与 09-01 同量级(具体值取决于内容,不承诺常数)。按毫秒对照纪律逐张核 match_ms 增量 ≈ 44ms × Δn_cand。

---

## 5. 不确定的一切(如实)

1. **无法做位姿级复算**:四场的逐帧相机朝向不在遥测里(`arkit_anchor_delta_v2` 是锚点漂移量、全零;`highres_capture_pose_pair` 在这四场为 0 条),电脑侧也无这四场的会话存档(`~/Developer/device-backups` 最新是 07-23)。"S3 在 fid9-16 转弯扫过 45° 锥"是由 n_cand 曲线形态 + fire_turn_deg(~9-23°/张,仅末 3 张环形缓存)反推的一致性论证,不是逐帧朝向复算。**但机制归因不依赖轨迹重建**——排除法在决策链内闭合(§3)。
2. **在机二进制与工作区源码的逐字节同源未核**:shipping `.a` 冻结于 07-20(PROVENANCE.md,identity ea77244a+dirty ghost-mask),`git log` 因 iCloud gitdir 挂死无法核对 pair_selection_v2.cc 在该冻结点后的改动史。行为指纹(上限 12=K12−T2+T2、ramp=min(fid,12)、S 排近 2/T 补 2、无 20 上限)全部与当前源码吻合,判定当前树即现役语义;若主线重编时发现冻结源与工作区有第三方差异,以重编前 diff 复核为准。
3. **hloc 30° 之说未核源**:仅来自 pair_selection_v2.cc:18-19 的注释转述("hloc(Apache-2.0)的 pairs_from_poses 用 30°"),本次未打到 hloc 源码;报告不以它为据。
4. **上游 j=0 豁免的边角**:上游 break 对"KNN 含自身"的 j=0 有隐式豁免(自身被身份检查跳过后,若 min_num_neighbors=0,首个真实邻居 j=1 起全部受距离上限约束)。我按"真实邻居全受约束"转写(index+1>0 恒真);另一种读法(首个真实邻居豁免)仅在最近邻 >100m 时有差异——本产品米级场景永不触发。测试场景③按我的读法钉死。
5. **TVG≈n_cand×常数**:案情给定;我只复核了 tvg_pairs_cum/帧 与案情表数字一致(2352/2379/1186/1568),未逐对核每对匹配质量两天不变。
6. **S2 的 09-01 也有轻度门损耗**(fid10:8、11:9、14:9,共少 9 对):说明门在 09-01 也在咬,只是走位直、咬得浅。"两天代码一行未改,行为却不同"与本诊断自洽:变量是走位几何,放大器是自设门。
7. **修复后的点云增量无法离线预测**:候选恢复→TVG 边恢复→track 更长→点更多的链条方向明确,但 8718→13237 的差距里有多少可归还,取决于内容与走位,需上机 A/B(按交替 A/B 纪律)。
