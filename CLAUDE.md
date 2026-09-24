# CLAUDE.md — PocketWorld 产品仓铁律(每次会话必读)

## 语言
- **永远用中文回复**。技术名词可留英文。

## 本仓
- 产品 iOS AR 采集 App(Flutter),分支 `ar-capture-rs`。原生算法在 `~/Developer/Aether3D-cross/aether_cpp`(经 vendor/aether_ffi 进来)。
- **多 agent 共享脏工作树**:大量关键改动未 commit。不得 reset/clean/checkout/覆盖他人改动;交接以根目录 `HANDOFF_*.md` 为准,动手前先读最新一份。

## 不可变产品决定(用户已签,不得自行改回)
- **永远没有云端**:重建全在手机本地。
- 真机包必须 `flutter build ios --profile`(debug 脱调试器即崩)。
- **真机测试拔线安全**:detached 启动、日志写 App 容器、事后 `devicectl copy` 拉取;绝不要求用户连线陪盯。
- 点云**全量存盘、任一点拉近可见**(2026-09-24 用户签决,取代原「全量交付,不为展示降采样」):PLY 一个点不删、不改写;展示可以分级(LOD 八叉树),但用于显示的树必须装下 PLY 的每一个点(C1:树内点数 = PLY 点数、octree.bin = 18 B × 点数)、每个叶节点拉近都选得到(S2),自检不过就不用树,退回平铺显示。
- 拍摄期 SfM worker 与 UI 必须异步:拍照按钮永不等 SfM。
- 拍摄完成后进等待页;等待页必须有"返回草稿";同任务卡重入回原等待页,不得起第二个重建;最终点云先取色并持久化才出现"完成"。
- 灵动岛任务只能由用户点"拍摄完成"触发,启动/前后台切换不得凭空创建。
- temporal 匹配 K12、8192 features、mutual GPU matcher;GPU 失败跳过该 pair,禁止分钟级 CPU brute-force fallback;K20 已否决。
- **质量无损是北极星**;有损取舍必须用户签决。
- 参数全抄 Mac 'o' 认证配置,不自创;"该用什么配置"先查生产代码,不跑实验猜已有答案的问题。

## 已钉死的技术事实(别再猜)
- 双墙根因在 **streaming DB 匹配拓扑**(revisit 无跨趟 pair),不在 BA 配置——'o' 完整 Cauchy full re-run 都不消。spatial guided 已真机证伪,别再包装成双墙方案。
- CoreML 锁 **CPU+GPU,绝不 ANE**(苹果专属+跑坏 3D-conv)。
- 取色问题 = observation RGB 算术平均缺陷,与双墙独立,单独修。

## 上游算法复刻铁律(用户 2026-08-27 再次签决)
- 公开可复现且商业许可兼容的成熟上游算法,默认先完整复刻;难、耗时或本地直觉不构成省略理由,不得假设自研优于专业上游。
- 每个算法先冻结 revision/license,再逐项建立方法地图:`exact_upstream`/`semantic_port`/`product_adapter`/`not_implemented`;存在后两项就禁止称“完整/官方/faithful/equivalent 复刻”。
- 上游完整性只由 pinned 源码、官方 fixture/vector 与端到端对照证明;本地注释、本地 spec 和只测本地实现的测试不能给自己作证。
- 不同阶段的成熟算法默认按职责互补;同一 consensus/LO/状态所有权的方案先明确组合语义并做单变量验收,禁止盲叠、混变量或用一个算法的数值套另一个算法的统计量。
- 许可阻止直接抄码时走 clean-room 语义复刻并保留 provenance 测试;不得违法抄码,也不得借许可问题偷偷换成自创规则。
- 详细长期学习见 `docs/solutions/workflow-issues/upstream-algorithm-reproduction-before-product-adaptation.md`;涉及算法实现或审计时先查 `docs/solutions/` 与对应 OpenSpec。

## 流程
- 沾边 skill 先调 skill;大改动/有损取舍用 AskUserQuestion 签决;git 提交用 `commit -F 文件 </dev/null` + `GIT_TERMINAL_PROMPT=0`,共享分支默认不 push。
