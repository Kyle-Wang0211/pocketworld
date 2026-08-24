# PocketWorld 架构·耦合·整洁度全面审计（2026-08-17）

四个并行审计 agent 实地扫描的汇总：Flutter 端（~/Developer/pocketworld/lib，235 文件 80,758 行）、
FFI/native 边界、C++ 算法核心（~/Developer/Aether3D-cross/aether_cpp，自研约 133K 行）、
Supabase 后端（18 个 migration，28 张表）。

## 结论速览

| 维度 | 评分 | 一句话 |
|---|---|---|
| FFI 三语言边界 | ★★★★☆ | 符号表冻结+PROVENANCE+契约测试，远超行业平均；唯一窟窿是旧栈没拆干净 |
| 后端数据模型 | ★★★★☆ | RLS 100% 覆盖、触发器计数、README 教科书级；但内容治理为零 |
| Flutter 分层 | ★★☆☆☆ | 没有真正分层：功能分包 + ui/ 杂物间，一个 4827 行引力中心 |
| C++ 核心 | ★★★☆☆ | 数值正确性纪律世界级（parity gate/字节冻结），可传承性为零（干净 checkout 编译不过） |
| 物理卫生（整洁度） | ★★☆☆☆ | 26.5% lib 死代码、构建产物进 git、尸体文档 174KB |
| **社区功能本身** | 🔴 **坏的** | 三个正在生效的 bug，与架构无关，一天能修完 |

---

## 一、🔴 现在就在生效的三个功能 bug（比一切架构问题优先）

1. **feed 硬顶 20 条，没有翻页**。`lib/ui/vault_page.dart:164` 只传 `limit: 20`，无 offset、无
   loadMore（`community_service.dart:73` 的 range 分页根本没被用上）。第 21 个作品发出来永远没人看见。
2. **缩略图上传 100% 失败**。客户端发 PNG（`publish_service.dart:319-324`），Edge Function
   `storage-sign-upload/index.ts` 的 `validateThumbnailUpload()` 只收 `image/jpeg` + `.jpg` 路径
   → 415/403 → 被 `community_service.dart:303` 静默吞掉 → 每个作品 `thumbnail_storage_path=NULL`，
   feed 全是渐变色块。测试没抓到是因为 `publish_service_test.dart` 的 fake seam 正好切在 bug 前面。
   修法：Edge Function 放宽到 PNG（一行）或客户端转 JPEG。
3. **浏览数永远是 0**。`community_service.dart:174-180` 的 `onConflict` 传了表达式
   （`coalesce(viewer_id::text,'anon')`），PostgREST 只接受列名列表 → 请求被拒 → `catch(_)` 吞掉。
   修法：改成 security definer RPC 做 `insert ... on conflict do nothing`。

## 二、UGC 长远视角的真架构缺口（按优先级）

### 1. 内容治理能力为零（App Store 合规风险）
- `reports` 表存在，但没有任何机制能下架一条内容：无 `moderation_status`、无软删除
  （`deleted_at`），`works` UPDATE 策略 owner-only，管理员只能开 SQL Editor 手改。
- 且 `works` 桶是 public（`20260429040000_works_bucket_public.sql` 自己注释承认了）：
  改私密后 URL 泄露过的文件照样能下载，"撤回发布"在存储层是假的。
- iOS Guideline 1.2 对 UGC 明确要求过滤+举报+24h 移除能力。
- 最小修法（约半天）：`works` 加 `moderation_status` + `deleted_at` 两列，
  `works_select_visible` 加过滤，加一条 service_role 下架 RPC。硬化方向：签名 URL。

### 2. 构建可复现性/可传承性（"第二个人加入当天就卡住"类问题）
- **aether_cpp 干净 checkout 编译不过**：出货必需的源码仍未跟踪
  （`src/sfm/canonical_feature_selector_v1.cc` 在 CMakeLists:167 被引用、
  `include/aether/sfm/tail_cache_epoch_v1.h` 被出货入口 include，都是 `??` 状态）。
- **`aether3d_ffi.podspec` 硬编码仓外路径**：`$(PODS_ROOT)/../../../dist/...` 和另一个仓的
  **Debug** 构建目录里的 `libwebgpu_dawn.a`（无 SHA pin、无 provenance）进了 Release 链接线。
- **COLMAP 无上游基线**：平铺拷贝+树内改 72 处（`[AETHER]` 标记质量很高），但没有上游
  commit SHA/patch 文件；`colmap-src/CMakeLists.txt` 还自称 3.14 而实际是 4.1.0；两个关键文件
  分叉到了 third_party 之外（`official_bundle_adjustment_ceres.cc` diff 384 行）。
  上游升级能力目前是零。30 分钟写一份 PROVENANCE.md + 改版本号就能止血。
- **出货构建闭包跨两个仓**：`official_gpu_match.mm` 等 3 文件只被产品仓的
  `build_xcframework.sh` 编译，aether_cpp 自己无法复现出货物。

### 3. 双栈未收干净，且隔离墙漏了（这是 podspec 问题拆不掉的原因）
- 官方 UI 有一条传递依赖穿回自研 ABI：
  `ui/official_capture/auto_rotating_cloud_view.dart → ui/community/card_live_governor.dart
  → capture/pw_telemetry.dart → aether_ffi.dart`。副作用：社区遥测写进已废弃自研树的文件。
- 反向也漏：`capture/sfm_live_recon.dart:43-44` import official 树的归档运行时。
- copy contract test 只扫直接 import 字符串，测不出传递闭包——需要升级为依赖闭包检查。
- 收干净的最小路径：把 `card_live_governor` / `me_page` 的旧栈引用切到 official_*，
  删 `lib/capture`/`lib/dome`/`lib/quality`/`lib/util`/`lib/ui/capture`/
  `packages/aether_capture_services`/`lib/aether_*_ffi.dart`，Podfile 移除 `pod 'aether3d_ffi'`。
  ⚠️ 前提：确认旧草稿 resume 路径（me_page 那条）可以退役或迁移。

### 4. `ar_capture_page.dart`（4827 行）是多人协作的物理瓶颈
单个 State 类 3588 行/139 字段，同时是 UI+相机+ARKit 通道（自开 MethodChannel 绕过
`platform_pose_provider`）+SfM 编排+373 行取色算法+文件 IO+导航，零测试覆盖。
三刀能砍 40%：`_colorizeSnapshot`、SfM 事件处理、draft 持久化先移出 State。
也是跨平台（Android）的最大障碍：`lib/ui/` 里 61 处直接 File IO。

### 5. 查询性能三连（量大才爆，最易修）
热门排序无 `likes_count` 索引；搜索 `ilike '%q%'` 无 trgm；86 条 RLS 的 `auth.uid()`
未包 `(select ...)`（逐行求值）。两条 create index + 一次 sed 的事，可以攒着一起做。

## 三、耦合评估：有，但"可数"，不是弥漫性的

- **跨语言边界（Dart↔C++↔Swift）不耦合，反而是亮点**：35 个导出函数的冻结符号表、
  fail-closed resolver（绝不静默回落）、"算法归 Dart、平台归 Swift"的显式契约
  （`OfficialAetherARKitPlugin.swift` 里连反向迁移的理由都写了）。
- **Flutter 内部的耦合集中在 5 条具体的边**（不是到处都是）：
  1. 数据层 import UI 页面：`me/scan_record_store.dart:36 → ui/me_page.dart`（为一个文件名函数）
  2. 领域模型错放 UI：`ScanRecord`/`CapturePipelineKind` 住在 `ui/scan_record.dart`，
     被 me/、community/ 反向依赖
  3. 社区复用采集页内部：`live_card_cloud.dart:45-46`、`work_detail_page.dart:43-44`
     直接 import `ui/official_capture/*`（`loadSparsePly` 住在 703 行采集查看页里）
  4. 双树互相串味（见上文第 3 条）
  5. `me_page.dart` 同时驱动两棵树的同名 API + 两份模块级可变状态
- 最小止血两步（低风险高收益）：`ScanRecord` 移到 `lib/domain/`；`loadSparsePly` 和点云视图
  提到 `lib/point_cloud_display/`。一次斩断最脏的 4 条边。
- 后端客户端数据层基本干净：全仓只有 6 个文件碰 Supabase client，UI 无裸查询
  （唯一破例 `me_stats_view_model.dart:13`）。

## 四、代码整洁度：两极分化

**"决策留痕"是世界级的**：注释几乎每个非常规决定都有 why+日期+证据；vendored 裁剪逐条留理由；
40+ 契约测试锁架构决策；supabase/README 387 行含迁移出 Supabase 的分步方案；
PROVENANCE.md 能字节级证明二进制身份。

**"物理卫生"较差**：
- lib/ 26.5% 死代码（21,417 行，多为整目录级：`quality/` 全死 1624 行、`capture/dome/` 全死
  2031 行、`pipeline/` 1873 行、两个各 1906 行只差 19 行且都死的 capture_page）
- 构建产物进 git：`build_codex_fix/` 991 个文件被 track；`libglomap_core.a.bak_*` 13.6MB
  （.gitignore 写了规则但没 untrack）；12 个 build-* 目录未 ignore
- aether_cpp 根目录 174KB 尸体 PLAN 文档（PHASE6 标 ACTIVE 已 3.5 个月没动）；
  根目录还有 sqlite 误操作生成的 `--help` 文件
- supabase/README 停在 4 月底：照它部署会漏 `storage-sign-upload`
- 契约测试在守死文件：`me_root_page.dart` 已死，两个 contract test 还在断言它（假安全网）
- `aether_cpp_card_demo.dart` 名字叫 demo 实为活代码（被 3 个社区文件 import）

## 五、行动清单

**本周就值得做（都是小时级）**：
1. 修三个社区 bug（分页 / 缩略图 PNG / recordView RPC）
2. `works` 加 moderation_status + deleted_at + 下架 RPC
3. aether_cpp：提交未跟踪的出货源码；写 PROVENANCE.md（COLMAP/GLOMAP/PoseLib 上游
   SHA+日期）；改掉 3.14 假版本号
4. `git rm -r --cached build_codex_fix/`、`git rm --cached *.bak_1783512996`；补 12 行 .gitignore
5. 🔑 轮换 `progecttwo/control_plane/.env.runtime:8` 的 S3 secret（明文落盘，组件已死）
6. ⚖️ 补 NOTICE：COLMAP/Ceres/glog/Eigen/PoseLib 等全部未列（BSD-3 要求二进制分发附版权
   声明），这是出货合规问题
7. 删 research/training 迁移残留（`research_data_opt_in` 四列 + 4 个 RPC + 审计触发器）——
   别让隐私政策里出现你没在做的事

**下一批（天级）**：双树收拢（先补传递闭包契约测试）、ScanRecord/loadSparsePly 归位、
ar_capture_page 三刀、性能索引三连、supabase/README 补 5 月世代

**明确不用管**：状态管理框架（224 处 setState 现阶段合理）、ffigen、平行树 22K 行重复
（有意隔离且有契约锁）、分区部署（endpoint_config 钩子已备好未通电，架构自由度够）、
conversations/collections 等占位表、13GB 仓库体积、test/ 平铺、CMakeLists 体量（别精简它）
