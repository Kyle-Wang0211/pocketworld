# PocketWorld 压缩实验官方复刻审计

审计日期：2026-08-02。代码身份：`13d2a4f05d491464c537a9135496eccaa05c2358`。范围严格限制为主机证据审计与最小单元补测；没有改生产代码、没有访问手机、没有安装 App、没有运行 100 MB 或完整项目。

## 结论

以前并非“所有方案都严格复刻过”。真实情况是四类：

1. **已经严格使用官方实现并有耐久证据**：JPEG XL exact JPEG、ZPAQ method 5、Zstd、LZMA2、libbsc、Kanzi、Brunsli、Rust Lepton、PackJPG。后三个照片方案和 libbsc/Kanzi 的耐久证据是本轮用最小单元补齐的。
2. **只严格测试了官方模式的一个子集**：OpenZL、C-Blosc2/B2ND、Pcodec。旧报告把 OpenZL/Blosc2 的一个简化配置写成整个项目失败，这是错误的；结论已收窄。
3. **不是论文的严格复刻**：跨照片集合原型。它只实现了顺序分组和弱预测，没有论文的全局参考关系、混合视差补偿、局部 DCT 搜索与自适应频域编码，所以只能否决本地原型。
4. **本地算法已按本地合同验证**：`track_delta_v1`、`exact_transform_v2`、`similarity_forest_v1`、PWA2。它们没有外部“官方实现”，所以单列为 `validated_internal`。
5. **原来仅提到、本轮已补测**：Parquet/Arrow、ORC、TileDB、DwarFS、meshoptimizer、fpzip、ZFP。现在每条都有固定官方版本、最小完整单元、完整输出字节数和精确恢复证据。

本轮没有发现已验证的生产基线因为“用错官方 API”而失效。真正需要撤回的是若干过度概括和没有耐久产物的旧聊天结论。

## 本轮最小单元补测

描述子输入是一整行 `uint8[8192,128]`，1,048,576 B，SHA-256 为 `2bb4062475c40b877deb7f735d4591df97c22a5d857deb1f6e3b45ff5809c92a`。每个方案只跑一次官方编码、官方解码、`cmp` 与 SHA-256。

| 官方模式 | 压缩后 | 缩小 | 结论 |
|---|---:|---:|---|
| ZPAQ 7.15 method 5 | **779,453 B** | **25.666%** | 本最小单元最小 |
| Kanzi 2.5.3 level 8 / TPAQ | 787,000 B | 24.946% | 比 level 9 更小，但仍输 ZPAQ |
| Kanzi level 9 / TPAQX | 795,976 B | 24.090% | 官方没有承诺等级越高一定越小 |
| libbsc 3.3.12 `-e2` | 803,530 B | 23.369% | `-r` 在该输入上完全相同 |
| XZ/LZMA2 preset 9 | 817,056 B | 22.080% | 比 `-9e` 小 84 B |
| XZ/LZMA2 preset 9 extreme | 817,140 B | 22.072% | extreme 不保证更小 |
| Zstd level 19/22/22+LDM | 835,970 B | 20.276% | 三者输出相同 |
| Zstd level 15 | 837,019 B | 20.176% | 精确恢复 |
| Zstd level 1/3/5/10 | 842,501–842,632 B | 19.640–19.653% | 精确恢复；等级与尺寸非严格单调 |

照片输入是一张真实原始 JPEG，2,794,655 B，SHA-256 为 `29aaef47f97b6b41fa3453b321dff030a0fcf3b4abac1d6aece72f11429744a4`。

| 官方方案 | 压缩后 | 缩小 | 结论 |
|---|---:|---:|---|
| Microsoft Rust Lepton 0.5.8 | **2,197,039 B** | **21.384%** | 三个新补测方案中本图最小 |
| packJPG 2.5j | 2,202,227 B | 21.199% | 精确，但核心许可是 LGPL-3.0-or-later，不是 wx 外壳的 MIT |
| Google Brunsli 0.1 | 2,212,076 B | 20.846% | 精确 |

这张图不能决定生产赢家。随后补做的同一输入比较使用另一张生产 JXL 的原始 JPEG：原图 2,725,495 B，生产 JXL 2,215,345 B，官方 Lepton 2,159,731 B。两者都恢复原 JPEG 的相同 SHA-256；Lepton 在这张同图上比 JXL 再小 55,614 B（2.510399%）。这只把 Lepton 升为下一轮独立 iOS/真机候选，不直接修改生产。

## 原来未运行候选的最小完整单元结果

描述子仍使用同一个完整 `uint8[8192,128]` 块，并与 779,453 B 的 ZPAQ method 5 比较。Parquet 的最佳官方组合是 fixed 128-byte value + DELTA_BYTE_ARRAY + Zstd 22，841,333 B；ORC binary + Zstd 是 842,852 B；TileDB dense uint8 + Zstd 22 在把全部四个持久文件计入后是 841,795 B。三者均逐字节恢复逻辑描述子，但都比 ZPAQ 大，因此不扩大测试，也不能被说成旧 SQLite 整文件的精确替代。

DwarFS 0.15.6 level 9 对一个 JPEG、一个描述子块和一个真实稀疏 PLY 的 4,936,441 B 原始总量压到 4,533,799 B，三文件均精确恢复。8.16% 的缩减远输分类型归档；更关键的是上游 LICENSE 明确规定 reader 侧为 MIT、writer/rewrite 为 GPL-3.0，把创建归档所需 writer 嵌入闭源商业 iPhone App 与目标分发模式冲突。

点云输入是 77,475 点的真实 binary little-endian float32 xyz + uint8 rgb PLY，原文件 1,162,370 B。直接 ZPAQ 是 **857,476 B**，仍为最优：

| 严格无损结构流 | codec/framing | 再套相同 ZPAQ | 对直接 ZPAQ |
|---|---:|---:|---:|
| fpzip 1.3.0 full precision（SoA） | 966,140 B | 936,613 B | 大 79,137 B |
| meshoptimizer 1.2 vertex v1 level 3 | 992,302 B | 959,057 B | 大 101,581 B |
| ZFP 1.0.1 reversible | 1,425,350 B | 1,337,914 B | 大 480,438 B |

三条都把每个 float 位、RGB、header 和原 PLY 文件 SHA 完整恢复；没有使用量化、重排、过滤或精度截断。它们只是在这份真实稀疏点云上输给直接 ZPAQ，并不否定其他数据分布。

商业工程结论：Lepton 核心 Apache-2.0；锁定的 iOS 正常/构建依赖树只出现 Apache-2.0、MIT、BSD-2-Clause、Zlib、0BSD、Unlicense 与 Unicode-3.0 许可选项。它可以继续进入闭源商业候选，但必须随 App 保留 NOTICE/第三方许可，并补 iOS ARM64 构建和独立真机验证。锁定 ScanCode broker 已实际调用，但本机 Docker 服务未运行，因此自动扫描未完成，结论标为 `conditional`，不是无条件 `allow`。DwarFS writer 是 `conflict`；其余已测候选均为宽松许可证但仍需 notice 和最终二进制依赖核验。

## 逐方案审计要点

- **JPEG XL**：生产桥使用 libjxl 0.12.0 官方 JPEG 重构 API，而不是把 JPEG 解码成像素再重编码。现有真机逐字节证据保留。
- **OpenZL**：今天修正后的 ACE-serial 是官方路径且把 934 B 模型计入，但没有领域 parser 和 clustering；分类为“官方子集”，不是整个 OpenZL 的终局测试。
- **C-Blosc2/B2ND**：今天修复了旧实验没有 BYTEDELTA、类型宽度错误的问题；正确的 fixed `S128` + SHUFFLE + BYTEDELTA + Zstd 仍输 ZPAQ，但未测试字典和多组 chunk/block 形状。
- **Pcodec**：官方 API 与 level 12 使用正确；证据只覆盖兼容数值成员和 PWA2 局部选择，不能说成完整 SQLite 后端。
- **本地结构变换**：`track_delta_v1`、`exact_transform_v2`、`similarity_forest_v1`、PWA2 没有外部“官方版本”；审计的是本地合同是否完整。它们的 sidecar、顺序、随机读、恢复 SHA 与 SQLite integrity 证据仍有效。`similarity_forest_v1 + ZPAQ` 的 116,739,319 B 仍是同作用域主机研究基线，不是生产真机基线。
- **跨照片集合**：旧实现不是论文复刻，旧负结果不得再用于否决论文路线。由于没有找到可直接运行的官方 exact-JPEG 实现，当前状态是“本地复刻无效、官方路线阻塞”，不是算法失败。
- **Parquet/ORC/TileDB**：本轮官方最小块均已精确运行并输给 ZPAQ。它们改变存储格式，可以做到数值内容无损，不能直接恢复旧 SQLite 的页面排列与整文件 SHA。
- **meshoptimizer/fpzip/ZFP**：本轮严格模式均已在真实 PLY 上运行并输给直接 ZPAQ。meshoptimizer 没用量化或过滤器；ZFP 使用 reversible mode；fpzip 使用 full precision。

## 以后如何避免再次误判

每个新方案必须先登记：官方 revision、官方入口、精确参数、真实数据类型与形状、所有 sidecar/模型/索引的完整字节数、官方解码、逐字节与 SHA。最小单元赢了才允许扩大；输了只否决该参数和该输入；构建失败只记工具链阻塞；没有产物就写“未运行”。主机结果永远不能直接换生产，生产选择仍需真实 iPhone 完整管线。

机器可读清单位于 `experiments/compression_fidelity_audit/inventory.json`，第一轮补测结果位于 `experiments/compression_fidelity_audit/results/2026-08-02-minimum-units.json`，商业候选补测位于 `experiments/compression_fidelity_audit/results/2026-08-02-commercial-candidates-micro.json`。

## 官方资料索引

- JPEG XL：[libjxl 官方仓库](https://github.com/libjxl/libjxl)；[编码器 JPEG 重构 API](https://libjxl.readthedocs.io/en/latest/api_encoder.html)；[解码器逐字节 JPEG 重构说明](https://libjxl.readthedocs.io/en/latest/api_decoder.html)
- JPEG 重压缩候选：[Brunsli](https://github.com/google/brunsli)；[Microsoft Rust Lepton](https://github.com/microsoft/lepton_jpeg_rust)；[wxPackJPG/packJPG 源码发布页](https://sourceforge.net/projects/wxpackjpg/files/)
- 通用后端：[ZPAQ](https://www.mattmahoney.net/zpaq/)；[libbsc](https://github.com/IlyaGrebnov/libbsc)；[Kanzi C++](https://github.com/flanglet/kanzi-cpp)
- 结构化后端：[OpenZL](https://github.com/facebook/openzl)；[C-Blosc2](https://github.com/Blosc/c-blosc2)；[BYTEDELTA 官方说明](https://blosc.org/posts/bytedelta-enhance-compression-toolset/)；[Parquet 编码规范](https://parquet.apache.org/docs/file-format/data-pages/encodings/)；[ORC 规范](https://orc.apache.org/specification/ORCv2/)；[TileDB 压缩说明](https://documentation.cloud.tiledb.com/academy/structure/arrays/tutorials/performance/compression/)
- 整体归档与点云候选：[DwarFS](https://github.com/mhx/dwarfs)；[meshoptimizer](https://github.com/zeux/meshoptimizer)；[LLNL fpzip](https://computing.llnl.gov/projects/fpzip)；[ZFP reversible mode](https://zfp.readthedocs.io/en/release1.0.0/modes.html)
