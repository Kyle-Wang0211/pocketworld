# 共享模型体积会计与项目规模修正

> 日期：2026-08-03
>
> 作用域：PLR-derived + Brunsli 相邻双照片 Mac 严格无损实验
>
> 结论：删除 15–20 MB 模型硬上限；`M` 改为预登记部署存储候选中的最小严格可逆结果；正式作用域冻结为每项目自包含归档

## 一、这次改了什么

原设计审核提出：PLR 类模型可能有几十 MB，如果在 141 张照片中分摊，模型成本可能吃掉 learned entropy model 相对 JXL 获得的全部空间，因此建议在 Phase 0 预登记“模型存储态压缩后不超过 15–20 MB”。

这个担忧指出了真实成本，却给出了不够普适的解决办法。**模型必须计费是正确的；把 15–20 MB 变成硬性淘汰线是不正确的。**

正式设计现改为：

1. 删除 `15,000,000 B` 目标上限和 `20,000,000 B` 硬停止线。
2. 不再使用 `model_budget_rejected` 作为终局状态。
3. 继续把模型的全部真实解码依赖计入候选，但通过 `2 / 项目照片数` 分配给双图实验。
4. 141 张仍是本轮正式准入规模，JXL 之和的严格门槛不变。
5. 新增模型规模敏感性报告和严格的 `N_break_even` 盈亏平衡照片数。
6. 141 张失败但 `N_break_even <= 300` 时，报告为“当前规模失败、但在批准的每项目作用域内可达”；若 `N_break_even > 300`，本轮直接判定为作用域内不可达的失败。
7. 模型运行内存、App 包体、启动时间和 iPhone ARM64 可执行性继续保留，但作为未来生产门槛单独判断，不与压缩率硬混在一起。
8. `M` 不再使用裸 `.pt` 或未压缩 fp32 文件大小，而是从 Phase 0 预登记的严格可逆部署存储候选中按完整持久字节选小。
9. 全局跨项目共享模型不再作为本轮“第二次机会”；scope 1 需要独立的长期模型保留设计，不能在看到 Phase 4 结果后改变作用域。

## 二、为什么绝对上限在数学上有问题

模型是固定成本，照片数据是随项目规模增长的可变成本。假设同一个模型可以处理一个自包含项目：

- 项目有 141 张照片，模型只保存一次；
- 项目有 300 张照片，模型仍只保存一次。

因此模型越大不一定越差。真正的问题是：模型带来的总码流节省是否大于它自身占用，而不是模型是否超过一个人为数字。

下面的 60 MB 表格只解释数学，不代表本轮模型实测值：

| 共用模型的照片数 | 每张分摊 | 双图分摊 |
|---:|---:|---:|
| 141 | 约 425.5 KB | 约 851.1 KB |
| 300 | 约 200 KB | 约 400 KB |
| 1,000 | 60 KB | 120 KB（纯信息，不属于批准作用域） |
| 10,000 | 6 KB | 12 KB（纯信息，不属于批准作用域） |

如果它在两张照片上只能比 JXL 节省 500 KB，那么 141 张规模不合格；只有盈亏平衡点不超过 300，才可称为在本轮批准的真实项目范围内可达。如果它能比 JXL 节省 1.5 MB，那么即使在 141 张规模也可能获胜。硬设 20 MB 上限会把后一种真正有价值的模型提前杀死。

项目照片更大时也是同一逻辑：模型字节不变，照片码流和潜在节省通常随照片内容增加。不能用“模型 MB 数”独立决定胜负，必须用冻结真实输入的完整输出计算。

## 三、正式会计对象是什么

计费对象不是训练时随手保存的 `.ckpt` 文件，而是干净机器完成解码实际需要的“规范化解码模型工件集合”的**部署存储形态**，包括：

- 推理权重；
- 权重量化或缩放表；
- entropy bottleneck/CDF buffer；
- scale table、概率查找表；
- 模型结构和版本信息；
- 自定义算子需要的静态数据；
- 能决定整数 CDF 或符号解码结果的所有参数。

下列训练专用品，如果解码不需要，可以不计：

- optimizer state；
- gradient；
- 训练数据；
- 数据增强缓存；
- 仅训练使用的 fp32 master weights；
- MLflow 日志和中间 checkpoint。

相反，不能因为一个模型随 App、动态库或云端服务分发，就把它当成零字节。只要它是恢复归档必需的依赖，就必须在选定的存储作用域中计费。

### `M` 的固定测量办法

Phase 0 在看到终局照片码流前，固定下面三个存储候选：

1. 未压缩的规范化部署模型；
2. Zstandard 1.5.7 level 22；
3. ZPAQ 7.15 method 5，源文件 SHA-256 为 `e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`。

三者都必须计算完整 envelope、manifest 和 codec identity，且压缩候选必须在干净环境恢复出与规范化部署模型长度、字节和 SHA-256 完全相同的文件。`M` 取三者完整持久字节的最小值。看到结果后不得再增加 codec、level、dictionary 或另一种序列化来追小。

报告必须同时保留：fp32 reference 大小/SHA、部署精度、部署模型未压缩大小/SHA、每个存储候选的参数和版本、压缩文件 SHA、恢复 SHA、逐字节结果，以及最终获胜的 `M`。

这里必须分清两种“无损”：

- Zstd/ZPAQ 对规范化部署模型的压缩必须逐字节无损；
- fp32→fp16/int8 只有在注册验证集上**不改变任何整数 CDF 符号判决**时，才能登记为 decoder-equivalent deployment serialization。

若精度变化导致任一 CDF 判决变化，它就是另一条模型臂，必须在终局前冻结，不能称为同一个 fp32 模型的无损压缩。无论使用哪条模型臂，两张原 JPEG 的恢复仍必须逐字节和 SHA-256 完全一致。

## 四、三种部署作用域必须分开

### 1. 全局模型，跨所有项目只存一份

模型作为 App/云端解码仓库的版本化对象保存，项目归档只记录 model ID 和 hash。模型成本在所有能稳定使用它的项目照片之间分摊。

优点是长期总成本最低；缺点是归档不再完全自包含，必须保证离线解码、旧版本模型永久保留、云端复制和 hash 校验。本轮已经冻结“压缩归档是唯一长期副本”和“项目必须自包含”，所以 scope 1 不参与本轮判定，也不能在 Phase 4 失败后用它救结果。若未来研究 scope 1，必须另立合同先证明永久模型保留机制。

### 2. 每个项目保存一个模型

每个项目归档自包含一份模型。一个项目无论有多少张照片，完整项目只加一次模型大小。

本轮正式实验只采用这一作用域。141 张照片共用一个模型，双图承担 `2/141` 的模型成本。依据用户登记的历史采集与产品目标，本合同批准的现实范围是 93–300 张；141 是正式判定点，300 是可达性上界。

### 3. 每张照片各自保存模型

每张照片都要承担一个完整模型。这通常非常不经济，也不是本轮设计。若未来做 per-image adaptation，所有特有参数都必须计入该照片，不能假装它们属于共享模型。

## 五、正式公式

定义：

```text
J = 两张同输入 JXL exact-JPEG 归档字节之和
B = 候选双图在计入共享模型分摊前的全部字节
M = 三个预登记严格可逆部署存储候选中的最小完整字节
N = 共用这一模型的项目照片数
H = J - B
```

其中 `B` 已经包括：

- 双图容器；
- 全部 Y/Cb/Cr 真实熵码流；
- exact-JPEG reconstruction side data；
- 跨照片 reference、selector 和几何数据；
- 索引、manifest、长度、checksum、SHA；
- 其他任何解码依赖，但不重复包含已经单列的共享模型。

在规模 `N` 下，双图有效成本为：

```text
candidate_effective_bytes(N) = B + ceil(2 * M / N)
```

严格获胜条件不变：

```text
B + ceil(2 * M / N) < J
```

本轮正式判断使用 `N = 141`。

## 六、盈亏平衡照片数

### 情况 A：`H <= 0`

候选不计模型就已经不小于 JXL。由于模型成本不可能为负，项目再大也救不了这一组固定码流。结论是：

```text
loser_stream_before_model_accounting
```

这时不要继续讨论模型分摊，也不要把失败归咎于模型太大。

### 情况 B：`H == 1` 且 `M > 0`

严格门槛要求最终至少小 1 B，但任何有限项目的正模型分摊都至少占 1 B，因此仍无法获胜。

### 情况 C：`H >= 2`

使候选第一次严格获胜的最小照片数是：

```text
N_break_even = ceil((2 * M) / (H - 1))
```

实现必须用整数运算再次验证：

```text
B + ceil(2 * M / (N_break_even - 1)) >= J
B + ceil(2 * M / N_break_even) < J
```

若 `N_break_even = 1`，只检查第二行。

这个公式只回答“固定模型成本从多少张开始摊得过来”，不证明双图的码流比例能外推到完整项目。达到拐点后，仍然需要把预登记的完整项目真正编码一次。

新增可达性判断：

```text
break_even_reachable_under_approved_scope =
    N_break_even != null && N_break_even <= 300
```

- `142 <= N_break_even <= 300`：141 张正式失败，但批准的 scope 2 范围内可达；
- `N_break_even > 300`：本轮 scope 2 不可达，必须作为真实失败报告；
- 1,000/10,000 张只保留为数学敏感性信息，不得改变终局状态。

## 七、报告必须怎样改

每次正式结果新增以下字段：

```yaml
model_accounting:
  reference_fp32_bytes: <integer-or-null>
  reference_fp32_sha256: <hex-or-null>
  deployment_precision: <string>
  canonical_deployment_model_bytes: <integer>
  canonical_deployment_model_sha256: <hex>
  cdf_decision_parity_with_reference: <true-false-or-not-applicable>
  storage_candidates:
    - codec: raw
      complete_persisted_bytes: <integer>
      restored_byte_equal: true
    - codec: zstd-1.5.7-level-22
      complete_persisted_bytes: <integer>
      restored_byte_equal: true
    - codec: zpaq-7.15-method-5
      complete_persisted_bytes: <integer>
      restored_byte_equal: true
  model_stored_bytes_M: <minimum-complete-persisted-bytes>
  storage_scope: per_project
  approved_scope_photo_count_min: 93
  approved_scope_photo_count_max: 300
  formal_project_photo_count: 141
  formal_pair_model_charge_bytes: <ceil(2*M/141)>
  stream_headroom_before_model_bytes: <J-B>
  break_even_photo_count: <integer-or-null>
  break_even_reachable_under_approved_scope: <true-or-false>
  sensitivity:
    - photo_count: 2
      pair_model_charge_bytes: <integer>
      effective_pair_bytes: <integer>
      beats_jxl: <true-or-false>
    - photo_count: 44
      ...
    - photo_count: 141
      decision_role: formal
      ...
    - photo_count: 300
      decision_role: approved_scope_boundary
      ...
    - photo_count: 1000
      decision_role: informational_only
      ...
    - photo_count: 10000
      decision_role: informational_only
      ...
```

正式终局状态调整为：

- `winner_beats_jxl_and_lepton`
- `winner_beats_jxl_but_loses_lepton`
- `loser_at_141_but_reachable_within_scope2`
- `loser_at_141_break_even_unreachable_scope2`
- `loser_stream_before_model_accounting`
- `invalid_exactness_failure`
- `invalid_incomplete_cost_accounting`
- `blocked_portability`
- `blocked_upstream_or_license`

不再存在 `model_budget_rejected`。

## 八、实施方向怎样改变

### Phase 0

以前：估算模型超过 20 MB 就停止。

现在：

1. 冻结模型结构、参数量、序列化格式和解码依赖。
2. 冻结部署精度和 CDF 判决一致性合同；若判决改变，把它登记成独立模型臂。
3. 运行 raw、Zstd 1.5.7 level 22、ZPAQ 7.15 method 5 三个固定存储候选，全部做模型工件逐字节恢复，按完整字节选出 `M`。
4. 冻结 scope 2、正式 N=141、批准范围 93–300；scope 1 不参与本轮。
5. 检查 ARM64 operator 路线、CUDA-only 依赖和跨平台 CDF 决定性。
6. 计算 2/44/141/300/1,000/10,000 张下的模型分摊；1,000/10,000 标为纯信息；不按绝对模型大小停止。
7. 预先钉死 Brunsli v0.1 与唯一 fallback master 的 commit。只有 v0.1 对冻结双图 exact round-trip 失败才允许运行 master，禁止手补丁。
8. 只有缺少未计费依赖、存在未登记序列化、无法恢复部署模型、或解码依赖 CUDA-only，才在 Phase 0 阻塞。

### Phase 1–3

exact container、完整 Y/Cb/Cr intra entropy stream 和唯一 A→B conditional arm 的顺序不变。H2 仍不允许无限调参。

Brunsli 主版本固定为 v0.1 commit `8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c`。唯一 fallback 固定为 master commit `c9128f43994c1ca830dd079777d85f16736d6ba7`。若 v0.1 失败，原样运行一次 master；v0.1 通过则不运行 master；两者都失败则阻塞。不得 cherry-pick 或本地修补 JPEG wrapper。

### Phase 4

证据审计确认：冻结双图当前没有同输入 JXL 结果，因此 `J`、`H` 和 `N_break_even` 在 Phase 4 之前全部是 unknown。审核中的估算数字仅用于解释，不能写入结果、门槛或停止规则。Phase 4 对两张图各运行一次 JXL exact-JPEG encode/decode，永久保存输入、归档和恢复 SHA；不得为了“稳定性”重跑。

除了正式 JXL 门槛和诊断 Lepton 门槛，还必须：

1. 分别报告 `B`、`M`、`H`；
2. 报告 141 张的正式模型分摊；
3. 计算并验证 `N_break_even`；
4. 生成规模敏感性表；
5. 若141张失败且拐点在142–300，保留为 scope 2 可达证据；若超过300，明确判为本作用域不可达失败；
6. 若141张获胜，再按原计划扩展到固定4/8图组和一次完整项目。

## 九、哪些东西完全没有改变

- 两张冻结 JPEG 和 SHA 不变。
- 正式准入线仍是同两张 JXL exact 归档之和，必须严格小于。
- Lepton 仍只作诊断次基线，不改变正式准入线。
- 两张 JPEG 都必须逐字节、长度和 SHA 完全一致。
- Y/Cb/Cr、sidecar、索引、校验和模型全部计费。
- 只跑一次终局候选，不重跑基线。
- 不动生产代码、不上手机、不跑 100 MB。
- H2 只有一个冻结 conditional arm 和一个 intra-only 归因臂。
- Mac 结果不能直接批准生产。

## 十、修改后的核心决策

模型大小不再被一个脱离项目规模的数字裁决。新的决策顺序是：

1. 先看不计共享模型时，完整真实双图码流是否产生正 headroom；
2. 再把规范化模型按141张正式分摊，判断当前项目是否严格胜过 JXL；
3. 当前规模若失败，计算模型从多少张照片开始摊得过来，并以300张判断本合同内是否可达；
4. 只有真实完整项目编码才能确认大规模收益，不能靠双图比例直接外推；
5. 生产阶段再独立评估模型 RAM、App 包体、启动成本和 iPhone ARM64 可执行性。

这样既不会把裸 fp32 或 App 外置模型的错误口径带进账，也不会用无现实对应的 1,000/10,000 张制造“精神胜利”。本轮只回答：在自包含、唯一长期副本、93–300 张的真实 scope 2 内，它是否严格胜过同输入 JXL。
