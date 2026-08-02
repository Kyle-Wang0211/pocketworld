# WorldPack 官方能力补全实验设计

## 目标

补齐此前只测试子集或只停留在研究文档中的四条严格无损路线：

1. OpenZL 0.2.0 的结构解析、单结构 ACE、多结构 clustering + ACE；
2. ALP 官方 reference 对真实 keypoints/poses 浮点列的完整位模式编码；
3. WebGraph Rust 官方 BVGraph 路线与洁净 Elias–Fano 基线对真实匹配/父图 ID 流的编码；
4. 将照片、SQLite 语义流、图索引、点云和元数据装入一个完整、可随机读、可中断提交的 WorldPack 归档。

实验只读冻结输入，不修改生产代码，不访问手机，不安装 App。主机结果只能建立研究基线；生产采用仍需另立物理 iPhone 完整管线准入实验。

## “测试完整”的可执行定义

“完整”不表示穷举任意库的无限参数空间，而表示同时满足：

- 使用固定官方 revision；
- 使用官方文档推荐的结构解析与训练/编码入口，而不是通用 fallback；
- 覆盖预登记的官方关键模式和有限参数网格；
- 训练运行到官方 completion，不用时间上限提前截断；
- 统计解码所需的模型、表、sidecar、索引和容器字节；
- 用官方解码路径恢复，再执行长度、逐字节、SHA-256 和损坏拒绝验证；
- 只把结论限定在实际输入和实际模式，不把一个失败配置推广为整个算法失败。

## 冻结身份

- PocketWorld 起始 HEAD：`eb269acdd8f8a941a10b55ce2d97f8b77ccc8f0e`；共享脏工作树保持原样。
- 捕获：`cap_1785512421333592`。
- SQLite：198,983,680 B，SHA-256 `0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`。
- SQLite 当前同输入研究基线：`similarity_forest_v1 + ZPAQ 7.15 method 5`，116,739,319 B。
- SQLite 当前生产作用域基线：`track_delta_v1 + ZPAQ 7.15 method 5`，124,401,918 B。
- 稀疏 PLY：1,162,370 B，SHA-256 `ba941c8b1fff4e6bbeb270aed8f4e328a14e570c46647dbd91b48e74c713dd3a`；直接 ZPAQ 基线 857,476 B。
- 照片：`photos_highres` 的有序项目清单；原始 JPEG 或已验证 JXL 必须恢复为每张原 JPEG 后再建立逻辑输入身份。
- OpenZL：`v0.2.0` / `3dceb64867840201fb8f57a29d179995f700c9b8`。
- ALP：`31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce`。
- WebGraph Rust：`f8698a7bdda2c4e171017548307179cd5c7a3166`，crate `webgraph 0.6.1`，选择 Apache-2.0 许可分支。
- ZPAQ：7.15，method 5，源码 SHA-256 `e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`。

输入 manifest 必须记录所有文件的规范化相对路径、长度和 SHA-256。实验输出记录实际 HEAD、脏 diff 哈希、工具链、命令、参数、随机种子、硬件、完整持久化字节和峰值资源。

## 单元一：OpenZL 完整官方流程

最小输入使用真实 `similarity_forest_v1` 的一个 16,384×128 descriptor chunk，并把它显式解析为 roots、residuals、parent distances 和必要的边界/类型元数据，而不是把整个缓冲区当 serial bytes。

预登记模式：

1. 相同结构的多份代表 chunk：专用 parser + ACE；
2. roots、residuals、parent metadata 多结构流：专用 parser + clustering + ACE；
3. 相同 parser 的未训练官方图作为消融；
4. 相同完整输入的 ZPAQ method 5 基线。

训练集和测试集按 chunk ID 固定分离，禁止在测试块上 inline overfit 后把模型成本忽略。训练必须完成；序列化 compressor 若解码需要，就计入归档总字节。每个模式至少执行一次压缩、官方解压和确定性损坏拒绝。

最小单元中严格小于 ZPAQ 的 OpenZL 模式才扩大到全部 descriptor 流。完整 descriptor 结果再与完整 `similarity_forest_v1 + ZPAQ` 同作用域比较。

## 单元二：ALP 官方浮点列

从 SQLite 的 `keypoints.data` 和可用 pose/camera 流按原始存储宽度提取同质列。读取采用整数位模式搬运，不执行浮点归一化、舍入或 NaN 规范化。

预登记模式：

- 官方 ALP 对每个 float32/float64 同质列；
- 官方 ALP-RD fallback 由官方实现自行选择；
- byte-stream-split + ZPAQ 作为同输入结构基线；
- 原字节直接 ZPAQ 作为保守基线。

结果必须恢复每一个原始 IEEE 位模式以及原行顺序。先测试一个完整 keypoint block；获胜后扩大到 SQLite 中全部兼容浮点成员。ALP 对 descriptor `uint8[128]` 不做错误作用域外推。

## 单元三：WebGraph 与 Elias–Fano 图流

图输入来自真实 `matches`、`two_view_geometries` 和 `similarity_forest_v1` backward-parent 关系。编码前允许定义规范化节点 ID，但必须保存足以恢复原 image ID、row ordinal、方向和边顺序的映射。

预登记模式：

- 官方 WebGraph Rust BVGraph 默认推荐压缩配置；
- 参数网格仅覆盖 window `{3, 7}`、max reference count `{3, 7}`、最小 interval length `{2, 4}` 和官方 ζ/gamma 编码选择；
- 洁净 Elias–Fano 用于单调 offset/neighbor 列表，非单调字段使用 zigzag/varint；
- 相同逻辑图字节直接 ZPAQ method 5 基线。

所有 `.graph`、`.properties`、`.offsets`、节点映射、顺序映射和校验数据都计入完整大小。随机读取固定的首、中、末节点并比较有序邻接表；完整解码必须恢复原始图流逐字节和 SHA-256。

## 单元四：完整 WorldPack

WorldPack 是 PocketWorld 自有容器，不冒充任何外部项目的官方格式。它借鉴 MCAP 的 append-only chunk/index/CRC 原则、内容寻址和参考森林，但其 correctness 由本实验合同证明。

容器包含：

- 每张原 JPEG 的当前最小、已验证逐字节恢复候选；本轮不重新选择照片算法；
- SQLite 的完整逻辑成员以及恢复旧 SQLite 所需的物理/逆变换信息；
- descriptor 结构流、ALP 浮点列、WebGraph/Elias–Fano 图流中各自同作用域获胜的候选；未获胜成员回退 ZPAQ；
- 原 PLY 的当前最小严格无损候选；
- 所有 JSON、策略、模型、配置、sidecar、索引、文件清单和 SHA-256。

容器按不可变 chunk 原子提交。每个 chunk 独立记录 codec、依赖、原长度、原 SHA、压缩长度和压缩 SHA。索引只能引用已提交的更早 chunk；损坏、缺失依赖或 hash 错误必须失败关闭。

执行顺序为：一个最小混合作品单元、约 100 MB 有序前缀、完整冻结项目。完整项目只有在前两级都逐字节通过后运行。无论中间 codec 是否胜出，WorldPack 都要使用“该作用域当前最小严格无损候选”完成端到端一次，以回答容器/索引净开销和完整作品实际比例。

## 验收与停止规则

- 严格无损是硬门槛：任何数值位、顺序、文件字节或 SHA 不一致，候选无效。
- 模型、sidecar、映射、索引和清单全部计入；payload-only 数字无效。
- 相同输入严格小于当前同作用域基线才升级该局部基线；相等也不升级。
- 最小单元失败只停止该模式的扩大，不宣称算法家族失败。
- 构建失败只记录工具链阻塞，必须先排除复刻/入口错误后才能结束。
- 许可不允许闭源商业嵌入的 encoder 不进入 WorldPack 生产候选，但可保留隔离研究结果。
- 主机结果不得直接改生产或安装手机。

## 证据产物

新实验目录保存：合同、输入 manifest、DVC 依赖图、`uv.lock`（仅 Python harness）、MLflow run identity、源码 revision/许可哈希、RED/GREEN 测试记录、每个最小单元结果、100 MB 结果、完整 WorldPack 结果和最终 evidence JSON。大临时归档放在任务专属 `/private/tmp`，完成后删除；失败结果和小型证据保留。
