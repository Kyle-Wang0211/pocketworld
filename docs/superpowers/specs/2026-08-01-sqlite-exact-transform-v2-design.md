# SQLite Exact Transform V2 设计

## 目标

在不改变生产归档选择逻辑的前提下，为完整 COLMAP SQLite 增加第三个
实验候选 `exact_transform_v2 + ZPAQ 7.15 method 5`，并与已经冻结的
`track_delta_v1 + ZPAQ` 基线比较。

候选只有同时满足以下条件才有资格进入独立真机 bundle：

- 恢复后的完整 `.db` 与输入逐字节相同；
- 恢复后的长度和 SHA-256 与输入相同；
- `PRAGMA integrity_check` 返回 `ok`；
- 变换输出确定；
- ZPAQ 归档严格小于 `124,401,918` 字节。

主机只负责早停和开发验证。生产选择必须由独立物理 iPhone bundle 运行
同一个 native transform 和 ZPAQ 路径后决定。

## 冻结输入和基线

- 输入：`cap_1785512421333592/official_sfm_live.db`
- 长度：`198,983,680` 字节
- SHA-256：
  `0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`
- `raw_v1 + ZPAQ`：`127,533,074` 字节
- `track_delta_v1 + ZPAQ`：`124,401,918` 字节
- ZPAQ：官方 7.15、method 5、固定 revision
  `e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`

不新建作品，不读取生产 App 容器，不更换输入数据库。

## V2 可逆变换

V2 只修改复制出的临时 SQLite 中已定位 BLOB 的物理字节。页数、页偏移、
记录头、rowid、字段长度、schema、空闲字节和所有未列出的字节保持不变。

正向顺序：

1. 对 `descriptors.data` 应用现有 `track_delta_v1`；
2. 对 `keypoints.data` 的 float32 位模式按“列、字节平面、行”重排，同一
   平面内从第二项开始保存与前一项的 XOR；
3. 对 `matches.data` 的两个 little-endian uint32 列分别保存相邻行的
   模 `2^32` 差值；
4. 对 `two_view_geometries.data` 使用相同的两列 uint32 差分。

逆向顺序必须严格相反：

1. 恢复 `two_view_geometries.data`；
2. 恢复 `matches.data`；
3. 恢复 `keypoints.data`；
4. 使用已经恢复的 two-view 匹配关系逆转 `descriptors.data` 轨迹差分。

所有操作都在整数位模式上进行，不执行 float 运算、量化、舍入、排序或
SQLite 重写。变换态数据库可通过 SQLite 物理完整性检查，但不会暴露给
训练、重建或 UI。

## 失败与中断

以下任一情况只淘汰 v2 候选：schema 不兼容、BLOB 长度与 rows/cols 不符、
页映射不唯一、取消、内存分配失败、正逆统计不同、恢复字节不一致、SHA
不一致、完整性检查失败或归档不小于当前基线。

输入只读。所有输出写入独立临时目录；失败或结束后删除数据库副本、变换态、
归档和恢复副本，只保留小型结果记录。

## Benchmark

主机阶段只运行一轮，因为 ZPAQ 和变换均为确定性算法；确定性由同一输入的
双变换哈希单元测试覆盖。记录源/变换/归档/恢复 SHA、归档字节、耗时、峰值
RSS、峰值临时空间以及每类 BLOB 的记录数与字节数。

主机通过后，复用独立 bundle ID
`com.kyle.PocketWorld.ArchiveBench`，只把冻结数据库副本放入该 bundle 的
独立容器，运行一轮真实 A16 测试。不得安装、更新或访问生产 bundle
`com.kyle.PocketWorld`。

## 非目标

- 本阶段不把 v2 接入生产事务或清单；
- 不修改现有 `raw_v1`、`track_delta_v1` 或恢复兼容性；
- 不修改照片、Brunsli、PLY、拍摄或训练管线；
- 不承诺百分点或倍数收益，唯一胜负指标是严格无损后的归档字节。
