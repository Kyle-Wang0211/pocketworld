# PLR 公版完整性、社区逆向与相似 JPEG 结构测试

> 研究时间：2026-08-03；所属领域：严格无损 JPEG 重压缩、移动端冷归档；研究对象类型：官方复刻审计与最小结构实验

## 执行结论

用户的怀疑成立：**当前公开 PLR 不是一个已经能够完整复刻论文结果的 JPEG 编解码器。** 问题不只在“没有写 JPEG 外壳”，而是公版训练默认选择的 `TransJPEGRecompression422` 连 Cb/Cr 色度码率都没有计入；四个 Transformer 模型的 `compress/decompress` 又引用了旧 MLCC 模型的成员，和当前 Transformer 的 target-aware 前向接口不匹配。直接训练这个仓库只能得到不完整的 likelihood 指标，不能得到可与 JXL 文件大小比较的真实码流。

没有找到被删除的隐藏实现，也没有社区补丁。官方仓库创建于 2026-07-15，截至 2026-08-03 仍是 0 fork、0 issue、0 release；初始提交之后只删除过 GitHub issue 模板和五个画图脚本。[PLR 官方仓库](https://github.com/zhuiguangzhe123/PLR)

社区逆向给出的关键帮助是把问题分成两层：

1. **精确 JPEG 容器层**保存或可重建 marker、量化表、Huffman 表、restart、padding、尾部数据与原始编码选择；
2. **DCT 熵模型层**只负责把量化 DCT 系数压得更小。

PackJPG 的拆解明确把 JPEG 头与 Huffman 扫描分开，再以算术模型编码 DCT；libjpeg-turbo 维护者也明确指出，不产生代际损失的路径必须熵解码后复制原始 DCT 系数，而不能从像素重编码。[PackJPG 逆向说明](https://gist.github.com/LukeNewNew/b55a3e87037b0e951095e3fed9ec4aec)、[libjpeg-turbo 讨论](https://github.com/libjpeg-turbo/libjpeg-turbo/issues/327)

单图诊断进一步证明“逐字节恢复”并不是主要空间负担：三张真实 PocketWorld JPEG 的全部非扫描数据都只有 1,501 B，占各自文件的 0.0482%–0.0539%。PLR 真正缺的是完整的 Y/Cb/Cr DCT 熵码流，不是 SHA-256 边界本身。

本轮还按 2024 年相似 JPEG 频域块匹配的公开结构做了一个相邻双图微型测试。3×3 块搜索确实比同位置预测更好，但简化的“残差＋Zstd”仍比直接编码目标 DCT 大 2.20%–14.46%。这不是论文失败，而是反向证明论文里的容忍度优化与 Brunsli 系数上下文不可省略。相关方法有待审中的中国专利，不能不做专利审查就复制进商业 App。[专利 CN117857794A](https://patents.google.com/patent/CN117857794A/en)

## 一、纵向审计：公版 PLR 到底缺了什么

### 1.1 默认训练指标漏掉色度

`train_lossless_jpeg_trans.py` 导入并训练 `TransJPEGRecompression422`。该类把 `bpp_likelihoods_cbcr` 初始化为零，随后将 Cb/Cr 熵模型与其 likelihood 累加整段注释，最终仍返回这个零值。因此论文所讨论的完整 JPEG 码率与公开训练脚本实际优化的指标并不相同。

这也解释了为什么“理论数字很漂亮，落地却无法验证”：如果只看训练日志，会把本应占空间的色度流当成不存在。任何基于该日志外推到 PocketWorld 的 30% 左右节省都不可信。

### 1.2 `compress/decompress` 是旧模型残留

当前 Transformer 构造的是 `Gaussian_Y` 与 `Gaussian_CbCr`。但四个 PLR 类的编解码函数引用 `Gaussion_Ys`、`Gaussion_Ys_234`、`Guassian_cbcr_anchor`、`entropy_aprameters_prior` 等并未初始化的对象。这些成员可以在同仓库较老的 `sensetime.py` MLCC 模型中找到，说明该块是旧实现迁移残留，不是简单改一个拼写就能修好。

更深一层，PLR Transformer 的前向熵模型需要 `(target y, context, masks)`，而遗留 `compress/decompress` 只传 context。要生成真实码流，必须实现编码端与解码端完全一致的顺序遍历，在每一步用已解码 target 上下文得到分布，再交给 rANS/算术编码器。这一整段状态机在公版中不存在。

### 1.3 训练后还缺真实熵编码准备

CompressAI 官方文档说明，训练结束后必须运行 `update_model` 或调用 `.update()`，把 learned CDF 写入实际熵编码需要的 buffer。[CompressAI 训练文档](https://interdigitalinc.github.io/CompressAI/tutorials/tutorial_train.html) PLR 训练入口没有这一步，也没有真实 encode/eval 入口、checkpoint release、JPEG writer 或逐字节验证。

所以当前状态应表述为：

- 模型思想可能有效；
- 公开训练入口的完整码率不成立；
- 公开编解码路径不可执行；
- 没有真实码流，不能和 2,215,345 B 的同图 JXL 基线比较；
- 若我们补齐，成果应叫“PLR-derived completion”，不能叫官方 PLR 复刻。

## 二、横向研究：社区和 2024–2026 新方案给了什么线索

### 2.1 社区共识：不要从像素重编码

PackJPG、JXL、Brunsli、Lepton 的共同点不是简单换成更强通用压缩器，而是保留 JPEG 的语法与可重建信息，将量化 DCT 系数交给专门的概率模型。社区关于 JXL 精确 JPEG 转码的讨论也强调：它和“像素无损 JXL”不是一回事，前者需要 JPEG reconstruction data 才能还原原文件。[JPEG XL 社区说明](https://www.reddit.com/r/jpegxl/comments/1pbahz7/when_jpeg_xl_visually_losslessly_converts_a_jpg/)

这对 PLR 的直接启示是：PLR 只能替换第二层 DCT 熵模型；第一层必须复用一个成熟、经过畸形 JPEG 测试的 exact-JPEG parser/reconstructor，而不是自行假设“header 加系数就一定能写回同一个文件”。本轮旧诊断 wrapper 在新的真实相机 JPEG 上恢复时触发了 libmalloc crash，也再次说明容器层不应草率自写。

### 2.2 2024：相似图片频域块匹配

PCS 2024 的论文提出在两张相似 JPEG 的未反量化 DCT 上做局部块搜索，配合方向向量与可变 N 系数残差。[论文 DOI](https://doi.org/10.1109/PCS60826.2024.10566381) 同作者、同结构的专利公开了更具体的实现：

- 当前块在参考图同位置与周围八块中搜索；
- 用前 N 个频域系数的绝对差和衡量候选；
- 不只求最小残差，还用容忍度平衡方向连续性；
- 前 N 个系数传 residual，后 64-N 个保留原系数；
- 方向 4-bit pack 后用 Brotli；DCT 流走 Brunsli；
- 不相似的图退回单图 Brunsli。

专利报告在其 Caltech pedestrian 数据上相对原 JPEG 减少 37%，相对单图 Brunsli再改善约 17%，但该数字不能外推到 PocketWorld；并且专利申请仍 pending。它可作为结构诊断线索，商业实施则是 `conditional/patent-review-required`，不是开源可商用模板。

### 2.3 2025–2026：更强结果有论文，但没有可运行交付物

APSEC 2025 的 PLLR 用 learned information decomposition，把可预测信号和稀疏 residual 分开，摘要报告 Kodak 文件减少 31.54%。这是对 PLR“完整码流必须把可预测内容与 residual 分流”的最新独立支持，但未找到公开仓库或 checkpoint。[APSEC 2025 论文页面](https://conf.researchr.org/details/apsec-2025/apsec-2025-papers/58/Practical-Lossless-Recompression-of-JPEG-Images-Using-Transform-Domain-Prediction)

2026 年还有 variable-rate JPEG frequency-domain modeling 与 joint spatial-transform prediction。后者报告 Kodak/DIV2K 约 22.9%，反而未超过成熟单图候选的量级；前者暂未发现公开全文代码或模型。[2026 joint-domain 论文 DOI](https://doi.org/10.1007/s11760-026-05186-9)、[2026 variable-rate 论文 DOI](https://doi.org/10.1109/TMM.2026.3695742)

因此，最新并不等于已有开源工程。当前能运行的成熟 exact-JPEG 软件仍是 JXL、Lepton、Brunsli/PackJPG 这一层；论文 SOTA 需要等作者代码，或明确投入一条“从论文实现”的研发线。

## 三、最小测试结果

### 3.1 精确容器旁路数据

| 真实 JPEG | 原文件 | 熵扫描 | 原样旁路上界 | 占比 |
|---|---:|---:|---:|---:|
| `cell_85_slot_4.jpg` | 2,995,750 B | 2,994,249 B | 1,501 B | 0.050104% |
| `cell_85_slot_5.jpg` | 3,112,949 B | 3,111,448 B | 1,501 B | 0.048218% |
| `cell_69_slot_5.jpg` | 2,784,405 B | 2,782,904 B | 1,501 B | 0.053907% |

这里把 marker、DQT、DHT、DRI、restart marker 与尾部数据全部按原字节计入，是保守上界。三张图均为单 scan、无 trailing data；这说明即使完全不压这 1,501 B，也几乎不影响总体比率。

### 3.2 相邻双图频域块匹配

输入是同一真实捕获中 `cap-9` 与 `cap-11`，触发时间只差 0.319 秒，分辨率均为 4224×2376。比较固定为同一个 Zstd 1.5.7 level 22：A 直接压目标图量化 DCT；B 用 3×3 最小 SAD 选择参考块，4-bit 保存方向，前 N 个 zigzag 系数存严格 residual，其余存目标 literal。

| N | 直接目标 DCT | 块匹配候选 | 相对变化 | 系数逆变换 |
|---:|---:|---:|---:|---|
| 4 | 4,018,843 B | 4,107,443 B | +2.2046% | 逐值一致 |
| 8 | 4,018,843 B | 4,170,033 B | +3.7620% | 逐值一致 |
| 16 | 4,018,843 B | 4,267,553 B | +6.1886% | 逐值一致 |
| 32 | 4,018,843 B | 4,431,875 B | +10.2774% | 逐值一致 |
| 64 | 4,018,843 B | 4,599,833 B | +14.4566% | 逐值一致 |

同位置 residual 的损失更大，为 +3.01% 到 +20.63%；因此局部块搜索本身确实改善了预测。但它不足以弥补方向信息与通用后端不认识 JPEG 系数统计的代价。最小 N=4 最接近，可把它作为未来**忠实复刻**的第一个固定样本；不能继续在这个简化版本上任意调参并宣称复现论文。

## 四、下一步决策

当前最优解没有改变：生产照片继续保持已验证 JXL exact-JPEG；PLR 不进入生产，也不启动大规模训练。

有价值的下一项测试只有两条，优先级如下：

1. **等或获取作者的完整 PLLR/PLR/variable-rate 实现与 checkpoint。** 必须包含全 Y/Cb/Cr、真实 entropy stream、模型 update、exact-JPEG wrapper 和许可。拿到后仍只跑冻结的一张 JPEG，完整计算模型摊销，严格小于 JXL 才扩大。
2. **若决定自行研发 PLR-derived completion，先做独立 exact-JPEG container 层，不训练模型。** 复用成熟开源 parser/reconstructor，建立 malformed/progressive/restart/metadata/trailing-byte corpus；只有容器能覆盖这些 JPEG 且逐字节恢复，才实现 target-aware Transformer entropy traversal。此工作是新编码器开发，不是“再跑一次官方命令”。

2024 块匹配路线暂不进入产品实现：其结构值得作为研究对照，但当前公开材料同时对应 pending patent。只有完成专利/许可审查，或找到明确开放实现，才应把 Brunsli tolerance/OMVC/VLRC 忠实 arm 加入同一双图测试。

## 五、证据状态表

| 判断 | 证据 | 状态 | 限制 |
|---|---|---|---|
| PLR 公版不能产出完整码流 | 固定 commit 源码、Git 历史 | confirmed | 不代表模型思想压缩率失败 |
| 默认训练漏计 Cb/Cr | 训练导入与 422 forward | confirmed | 其他类有 chroma forward，但训练不选它们 |
| 逐字节 JPEG 旁路很小 | 三张真实相机 JPEG parser | supported | 只覆盖该相机生成的 baseline JPEG |
| 3×3 搜索对预测有帮助 | 相邻双图 exact coefficient A/B | supported | 后端不是论文的 Brunsli 上下文 |
| 简化块匹配不能赢直接编码 | 同 Zstd-22 A/B | confirmed for this arm/input | 不能否决论文完整方法 |
| 2024 方法可直接商用 | pending patent、无开源代码 | unresolved / do not adopt | 需专利与许可审查 |
| 2025–2026 论文可立即测试 | 未找到公开代码/checkpoint | not runnable | 等作者发布或另立研发项目 |

机器可读证据位于：

- `experiments/plr_official_natural_jpeg/upstream-audit.json`
- `experiments/plr_official_natural_jpeg/exact-jpeg-side-diagnostic.json`
- `experiments/plr_official_natural_jpeg/similar-jpeg-blockmatch-diagnostic.json`

