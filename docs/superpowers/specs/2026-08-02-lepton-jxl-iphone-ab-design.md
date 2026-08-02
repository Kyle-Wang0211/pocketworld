# Lepton 与 JPEG XL 独立真机 A/B 设计

## 目标

在不访问、不安装、不更新生产 bundle `com.kyle.PocketWorld` 的前提下，
把微软官方 Rust Lepton 0.5.8 编译为 iOS ARM64 静态库，并通过独立 bundle
`com.kyle.PocketWorld.LeptonBench` 与当前生产 JPEG XL effort 10 对同一张
JPEG 做一次干净 A/B。

只有真机结果同时满足以下条件，才允许把未来项目的生产照片编码器改为
Lepton：

1. 输入正是 2,725,495 B、SHA-256
   `a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`
   的冻结 JPEG；
2. JXL 和 Lepton 都用各自官方解码路径恢复；
3. 两份恢复 JPEG 都与输入逐字节相同，且 SHA-256 完全相同；
4. 真机生成的 Lepton 完整归档严格小于 JXL 完整归档。

任一条件失败，生产继续使用 JXL，不修改生产照片格式。

## 官方实现边界

- Lepton 固定为官方 `lepton_jpeg` 0.5.8，对应源码提交
  `90fdc27828676892fbb41777cfcc6bad1e470516`。
- 使用 Cargo.lock 固定完整依赖；构建前核验包内 `.cargo_vcs_info.json`、
  包校验和、LICENSE 与 NOTICE。
- 编码使用官方 `EnabledFeatures::compat_lepton_vector_write()`；解码使用
  `EnabledFeatures::compat_lepton_vector_read()`；线程池使用官方
  `DEFAULT_THREAD_POOL`。这些设置与官方 0.5.8 utility/DLL 的默认路径一致。
- 自有 Rust 代码只提供文件型 C ABI、错误码、版本查询和耗时，不修改
  Lepton 熵模型、JPEG 解析、分区或输出格式。
- Rust 使用任务专属临时 toolchain 和 Cargo 缓存构建
  `aarch64-apple-ios`，不修改电脑全局 Rust。

## 独立 bundle

现有 Flutter Runner 仅作为构建外壳。构建命令行覆盖：

- `PRODUCT_BUNDLE_IDENTIFIER=com.kyle.PocketWorld.LeptonBench`；
- `FLUTTER_TARGET=lib/lepton_jxl_benchmark_main.dart`；
- 通过链接参数加入独立的 Lepton ARM64 静态库；
- `CODE_SIGNING_ALLOWED=NO` 先构建，再使用已验证的 wildcard profile 单独签名。

安装前必须读取成品 `Info.plist`，确认 bundle ID 不是生产 ID；检查深层签名
和 Lepton/JXL 必需 ABI 符号。安装命令只能是
`devicectl device install app`，不得出现 uninstall。测试输入只复制到独立
bundle 的 Documents，结果也只从该容器取回。

## Dart benchmark 流程

1. 等待 `Documents/benchmark_input.jpg`。
2. 校验冻结长度与 SHA-256，不匹配即失败，不运行编码器。
3. 清除该独立容器内上一轮临时输出。
4. 使用生产 `JxlFfiPhotoArchiveCodec(effort: 10)` 生成 JXL，再用生产
   JXL bridge 恢复 JPEG。
5. 使用 Lepton FFI 生成 `.lep`，再用同一官方 Lepton 0.5.8 静态库恢复
   JPEG。
6. 对两条恢复结果分别计算长度、SHA-256 和流式逐字节比较。
7. 原子写入 `Documents/lepton_jxl_benchmark_result.json`，包含版本、输入身份、
   每条归档长度/SHA、编码/解码耗时、恢复 SHA、逐字节结果和最终 verdict。

`passed` 只表示两条都严格恢复且 Lepton 更小；相同大小也判为未通过生产
替换门槛。

## 条件式生产替换

真机 A/B 通过之前，生产文件不得改变。通过之后：

- 只让以后新建的项目写 Lepton policy/manifest 和 `.lep`；
- 旧 JXL policy、manifest、`.jxl` 及解析路径继续可读，不迁移、不重压；
- 继续执行“临时归档 -> 官方解码 -> SHA/逐字节验证 -> 原子清单 -> 最后
  删除源 JPEG”的事务顺序；
- 继续在生产管线活跃时暂停归档，并在发布归档或删除源文件前重新检查门禁；
- 将 Lepton LICENSE、NOTICE 和锁定依赖许可随 App 分发；
- native `.a` 变化必须显式记录为需要重编并 vendor 新产物。

如果 Lepton 无法保持现有事务、恢复兼容性、后台门禁或许可证义务，真机体积
胜出也只保留 benchmark 结论，不进入生产。

## 验证与证据

仓库保存冻结实验合同、输入身份、Rust/Cargo/Xcode/SDK 身份、构建命令、
静态库及 App 二进制哈希、真机 UDID、结果 JSON 和判定。主机测试只验证
桥接和失败路径；生产赢家只能由物理 iPhone 结果决定。
