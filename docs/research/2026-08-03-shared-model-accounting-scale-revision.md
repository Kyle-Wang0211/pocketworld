# 共享模型体积会计与项目规模修正

> 日期：2026-08-03
>
> 作用域：PLR-derived + Brunsli 相邻双照片 Mac 严格无损实验
>
> 结论：删除 15–20 MB 模型硬上限，改用完整字节准入与项目规模盈亏平衡分析

## 一、这次改了什么

原设计审核提出：PLR 类模型可能有几十 MB，如果在 141 张照片中分摊，模型成本可能吃掉 learned entropy model 相对 JXL 获得的全部空间，因此建议在 Phase 0 预登记“模型存储态压缩后不超过 15–20 MB”。

这个担忧指出了真实成本，却给出了不够普适的解决办法。**模型必须计费是正确的；把 15–20 MB 变成硬性淘汰线是不正确的。**

正式设计现改为：

1. 删除 `15,000,000 B` 目标上限和 `20,000,000 B` 硬停止线。
2. 不再使用 `model_budget_rejected` 作为终局状态。
3. 继续把模型的全部真实解码依赖计入候选，但通过 `2 / 项目照片数` 分配给双图实验。
4. 141 张仍是本轮正式准入规模，JXL 之和的严格门槛不变。
5. 新增模型规模敏感性报告和严格的 `N_break_even` 盈亏平衡照片数。
6. 141 张失败但更大项目可能获胜时，不把算法误判为普遍失败；报告为“当前规模失败、规模拐点明确”。
7. 模型运行内存、App 包体、启动时间和 iPhone ARM64 可执行性继续保留，但作为未来生产门槛单独判断，不与压缩率硬混在一起。

## 二、为什么绝对上限在数学上有问题

模型是固定成本，照片数据是随项目规模增长的可变成本。假设同一个模型可以处理整个项目：

- 项目有 141 张照片，模型只保存一次；
- 项目有 1,000 张照片，模型仍只保存一次；
- 项目有 10,000 张照片，模型还是只保存一次。

因此模型越大不一定越差。真正的问题是：模型带来的总码流节省是否大于它自身占用，而不是模型是否超过一个人为数字。

例如 60 MB 模型：

| 共用模型的照片数 | 每张分摊 | 双图分摊 |
|---:|---:|---:|
| 141 | 约 425.5 KB | 约 851.1 KB |
| 1,000 | 60 KB | 120 KB |
| 10,000 | 6 KB | 12 KB |

如果它在两张照片上只能比 JXL 节省 500 KB，那么 141 张规模不合格，但 1,000 张规模可能合格。如果它能比 JXL 节省 1.5 MB，那么即使在 141 张规模也可能获胜。硬设 20 MB 上限会把后一种真正有价值的模型提前杀死。

项目照片更大时也是同一逻辑：模型字节不变，照片码流和潜在节省通常随照片内容增加。不能用“模型 MB 数”独立决定胜负，必须用冻结真实输入的完整输出计算。

## 三、正式会计对象是什么

计费对象不是训练时随手保存的 `.ckpt` 文件，而是干净机器完成解码实际需要的“规范化解码模型工件集合”，包括：

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

## 四、三种部署作用域必须分开

### 1. 全局模型，跨所有项目只存一份

模型作为 App/云端解码仓库的版本化对象保存，项目归档只记录 model ID 和 hash。模型成本在所有能稳定使用它的项目照片之间分摊。

优点是长期总成本最低；缺点是归档不再完全自包含，必须保证离线解码、旧版本模型永久保留、云端复制和 hash 校验。没有这些保证时，不允许使用全局分摊把实验数字做小。

### 2. 每个项目保存一个模型

每个项目归档自包含一份模型。一个项目无论有多少张照片，完整项目只加一次模型大小。

本轮正式实验采用这一保守作用域。141 张照片共用一个模型，双图承担 `2/141` 的模型成本。这样不会假设未来所有项目都能依赖 App 内某个永久存在的全局模型。

### 3. 每张照片各自保存模型

每张照片都要承担一个完整模型。这通常非常不经济，也不是本轮设计。若未来做 per-image adaptation，所有特有参数都必须计入该照片，不能假装它们属于共享模型。

## 五、正式公式

定义：

```text
J = 两张同输入 JXL exact-JPEG 归档字节之和
B = 候选双图在计入共享模型分摊前的全部字节
M = 规范化解码模型工件总字节
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

## 七、报告必须怎样改

每次正式结果新增以下字段：

```yaml
model_accounting:
  canonical_model_bytes: <integer>
  storage_scope: per_project
  formal_project_photo_count: 141
  formal_pair_model_charge_bytes: <ceil(2*M/141)>
  stream_headroom_before_model_bytes: <J-B>
  break_even_photo_count: <integer-or-null>
  sensitivity:
    - photo_count: 2
      pair_model_charge_bytes: <integer>
      effective_pair_bytes: <integer>
      beats_jxl: <true-or-false>
    - photo_count: 44
      ...
    - photo_count: 141
      ...
    - photo_count: 1000
      ...
    - photo_count: 10000
      ...
```

正式终局状态调整为：

- `winner_beats_jxl_and_lepton`
- `winner_beats_jxl_but_loses_lepton`
- `loser_complete_but_not_smaller_than_jxl`
- `loser_at_141_but_scale_break_even_defined`
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
2. 生成规范化模型工件并记录真实大小和 SHA。
3. 检查 ARM64 operator 路线、CUDA-only 依赖和跨平台 CDF 决定性。
4. 计算 2/44/141/1,000/10,000 张下的模型分摊，但不按绝对模型大小停止。
5. 只有缺少未计费依赖、无法序列化、解码依赖 CUDA-only，才在 Phase 0 阻塞。

### Phase 1–3

exact container、完整 Y/Cb/Cr intra entropy stream 和唯一 A→B conditional arm 的顺序不变。H2 仍不允许无限调参。

### Phase 4

除了正式 JXL 门槛和诊断 Lepton 门槛，还必须：

1. 分别报告 `B`、`M`、`H`；
2. 报告 141 张的正式模型分摊；
3. 计算并验证 `N_break_even`；
4. 生成规模敏感性表；
5. 若141张失败但存在更大规模拐点，保留候选作为规模研究证据，不进入当前项目生产；
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
3. 当前规模若失败，计算模型从多少张照片开始摊得过来；
4. 只有真实完整项目编码才能确认大规模收益，不能靠双图比例直接外推；
5. 生产阶段再独立评估模型 RAM、App 包体、启动成本和 iPhone ARM64 可执行性。

这样既不会把模型成本藏起来，也不会因为项目暂时较小而误杀一个在大型作品或跨项目全局模型场景中真正有效的方案。
