# 社区功能重开评估(2026-08-16)

**结论先行**:社区读侧完整存活、零编译错误;发布侧不是"重写"而是"移植"——旧树
`claude/publish-to-community` 分支上躺着 389 行成品服务 + 412 行测试 + 35KB 设计规格;
而我先前判为硬阻断的"格式代差"**证伪了**——原生 PLY 加载器本来就为点云导出器留了回退路径。

真正剩下的是三个小口子和三个待你签决的边界,没有一个是架构级重做。

---

## 0. 勘误(相对本次会话早前口径)

早前我说"格式代差是 🔴 硬阻断,原生 loadPly 是 splat 路径不是点云路径"。**这条不成立**,证据:

- `aether_cpp/include/aether/splat/ply_loader.h:215-218` 有显式注释与实现:
  *"Fallback: some PLY exporters (Polycam, Luma, etc.) use red/green/blue"*,
  并在 `:363-366` / `:471-472` 走 uchar→[0,1] 的直读 RGB 通道。
- `aether_cpp/tests/splat/ply_loader_test.cpp:272-297` 有一个**纯 `x,y,z` 无任何高斯属性**的
  PLY 用例,断言 `status == kOk`,缺失属性回落到 color=0.5 / opacity=1.0 / scale=0.01 / 单位四元数。
- 位置是唯一必需属性(`:284` "Position is required")。

所以 `official_sfm_sparse.ply`(带 RGB 的稀疏点云)**能被原生渲染器直接吃下并且带正确颜色**。
剩下的是观感调参(默认 splat scale=0.01 对我们的米制稀疏云合不合适),而 ABI 上
`set_splat_scale_multiplier` / `set_max_3d_scale` / `set_lod_extent_min` 三个旋钮都已存在。

---

## 1. 家底清单(全部经实测,非推断)

### 1.1 仓库坐标

| 项 | 值 |
|---|---|
| 远端 | `https://github.com/Kyle-Wang0211/pocketworld.git` |
| 本地 | `~/Developer/pocketworld` |
| 分支 / HEAD | `main` @ `c9c0cab` |
| 与 origin | **0 ahead / 0 behind**(远端即本地所见) |
| 工作树 | 17 个改动(colorize / aux_archive 线,与社区无关) |
| `flutter analyze` | **零 error**,33 issue 全是既有 warning/info,无一条落在社区代码 |

### 1.2 产品仓现存社区代码

**算法/数据层 `lib/community/`(856 行)**

| 文件 | 行 | 职责 |
|---|---|---|
| `community_service.dart` | 297 | Supabase 读写:`fetchPublicFeed`(works ⋈ profiles ⋈ work_likes 三次批量查,非 N+1)、`toggleLike`、`recordView`(小时桶去重)、路径→URL、`uploadAndSetThumbnail`(经 SignedUploadBroker) |
| `glb_cache.dart` | 171 | URL→bytes 两级缓存:内存 map + `tmp/glb_cache/<sha1>.glb` |
| `thumb_baker.dart` | 156 | first-viewer-wins 缩略图烘焙 |
| `glb_asset_cache.dart` | 100 | 已加载 asset LRU + 同 URL 在途合流 |
| `feed_models.dart` | 74 | `FeedWork`(format 声明 `glb\|spz\|gsplat\|ply`) |
| `anchor_viewer.dart` | 58 | 单例常驻 viewer,绕开 Thermion 0.3.4 `dispose()` 连带杀 asset |

**UI 层 `lib/ui/community/`(2893 行)+ `lib/ui/vault_page.dart`**

`post_card.dart` 731(1:1 方卡 / live 3D 背景 / liquid_glass 真折射信息板 / 可见度 0.3 挂载)、
`aether_cpp_card_demo.dart` 654(走 aether_cpp 渲染器,`kPostCardUseAetherCppViewer = true` 已切)、
`live_model_view.dart` 773(thermion 版,现为遗产)、`viewer_impl.dart` 477(两渲染器抽象)、
`work_detail_page.dart` 258。`vault_page.dart` 是 feed 页,三 tab 热门/附近/发现。

**策略契约** `lib/ui/viewer_social_contract.dart`:
挂载阈值 0.3 / debounce 150ms / unmount 延迟 300000ms / 质量档 `feedThumbnail` vs `full`,
并明写边界:排序、挂载卸载、缓存回退、格式检测、乐观点赞回滚**归 Dart**,原生只做 thin renderer。

### 1.3 原生底座(活的,已链进当前出货二进制)

- `ios/Runner/AetherTexturePlugin.swift`(747)+ `MetalRenderer.swift` → aether_cpp scene renderer
- 12 个 `aether_scene_renderer_*` 符号齐全,实测在
  `~/Developer/dist/libs/ios-arm64/libaether3d_ffi.a`(08-07,682MB)内
- Podfile 已 `-force_load` 该库;Dawn 库(`build-ios-device-dawn/.../libwebgpu_dawn.a`,06-21,669MB)在位
- `AppDelegate.swift:20-21` 已注册 `AetherTexturePlugin`
- 能力:`load_glb` / `load_ply` / `load_spz` + 三个 capped 变体 + `get_bounds` + `set_lod_extent_min`
  / `set_max_3d_scale` / `set_splat_scale_multiplier` + `captureThumb`
  + 热态驱动 fps + 内存告警释放非焦点纹理

### 1.4 后端(supabase/,15 个 migration)

已建表远多于客户端所用:

| 域 | 表 | 客户端是否使用 |
|---|---|---|
| core | `profiles` `projects` `scans` `works` | ✅ profiles / works |
| engagement | `work_likes` `work_bookmarks` `comment_likes` `work_views` | ✅ likes / views;❌ bookmarks / comment_likes |
| social_graph | `follows` `blocks`(含计数触发器、拉黑级联退关) | ❌ 一行没用 |
| discovery | `tags` `work_tags` `mentions` | ❌ |
| communications | `notifications` `notification_settings` `conversations` `conversation_members` `messages` | ❌ |
| moderation | `reports` `audit_logs` `collections` `collection_works` | ❌ |

Edge functions:`storage-sign-upload`、`signup-start/verify`、`password-reset-start/verify`。
项目 ref `tzvwkqmgaourwqrmxbyb`;URL 与 anon key 硬编码在 `lib/main.dart:184-190` 作为默认值。

### 1.5 旧树可回收资产(关键)

`~/Developer/Aether3D-cross/pocketworld_flutter`,分支 **`claude/publish-to-community`**:

| 资产 | 规模 | 说明 |
|---|---|---|
| `lib/community/publish_service.dart` | 389 行 | 头注释明写"Re-introduces the 发布到社区 flow that was deleted in Plan G W2 (2026-05-16)" |
| `test/publish_service_test.dart` | 412 行 | 编排单测 |
| `docs/superpowers/specs/2026-06-23-publish-to-community-design.md` | 35KB / 11 章 | 含数据流、RLS 约束核实、UI/UX、归一化策略、错误处理、TDD 计划、开放问题、分期 |
| `lib/community/tiered_lru_residency.dart` | 68 行 | 产品仓没有 |
| `lib/me/publish_service.dart` | 276 行 | 更早的一版(建议弃,取 community/ 那版) |

**移植方向明确**:两树 `anchor_viewer` / `feed_models` / `glb_asset_cache` / `glb_cache` /
`thumb_baker` **逐字节相同**;`community_service.dart` 是**产品仓更新**(297 vs 273,多出
SignedUploadBroker 加固)。所以是把旧树的 publish 三件套**搬进来**,不是反向合并。

依赖核对:`publish_service.dart` 只 import `crypto` / `supabase_flutter` / `../glb_norm/glb_norm.dart`
/ `../ui/scan_record.dart` / `community_service.dart` —— **产品仓四项全在**。
它读的 `record.artifactPath` / `record.cloudWorkId` 两个字段产品仓 `ScanRecord` 也都还在
(`lib/ui/scan_record.dart:245` / `:268`)。

---

## 2. 关闭点(只有一处)

`lib/main.dart:676-679`:

```dart
// V1 (工具阶段): personal page + capture FAB only. The two-tab shell
// (AetherAppShell, with the community feed) is kept for V2 but not
// routed to here.
const MeRootPage(),
```

切换发生在 `cf68313 feat(ui): V1 IA — sign-in lands on personal page + bottom-right capture FAB`。
`AetherAppShell`(两 tab:社区 / 我)整体完好,`lib/ui/app_shell.dart` 最近一次改动是
2026-07-24 `6d6a660` 为官方拍摄路线做的,不是社区侧退化。

**换回去是一行。** 但见下节——一行换回去只得到一个空 feed。

---

## 3. 三条路:范围、依赖、真实缺口

### 路 A — 只读接回(验证链路)

**做什么**:`main.dart` root 换回 `AetherAppShell`;真机验证 feed 能拉、卡片 3D 能渲、点赞能写。

**缺口**:零代码缺口。所有依赖(Supabase 初始化、auth、渲染器、l10n 六个 `community*` 键)都在。

**风险**:
- 打开后 feed 大概率**是空的**(见路 B)。这不是 bug,是没有内容源。
- Supabase dev 项目 `tzvwkqmgaourwqrmxbyb` 是否还活、表里有无数据 —— **未验证**(需要网络)。
- `--dart-define` 在本工程 xcconfig 链上**不生效**(2026-08-09 真机证实,见 runbook),
  所以要换 prod 项目不能靠 dart-define,得改 `main.dart` 默认值或另做 xcconfig 注入。

**价值**:这是唯一能立刻回答"后端还活着吗 / 渲染器在真机上还转吗"的动作,且可随时回滚。

---

### 路 B — 移植发布链(让 feed 有内容)

**做什么**:把旧树 `publish_service.dart` + 测试搬进产品仓,并重建 `MyWorkDetailPage`
的发布 bottom sheet(现状:`lib/ui/me/my_work_detail_page.dart:13-17` 明写 sheet 是 inert、
确认按钮弹 "no cloud" snackbar;`:116-120` 记录 `_PublishFormResult` / `_PublishForm` /
`_PublishFormState` 三个类被一并删除)。

**已有 vs 待写**:

| 部分 | 状态 |
|---|---|
| 服务层编排(读→归一化→sha1→上传→插行→烘缩略图) | ✅ 旧树 389 行成品 |
| 单元测试 | ✅ 旧树 412 行 |
| 设计规格(含 RLS 逐条核实、路径约定、错误分类) | ✅ 35KB |
| RLS / bucket 策略 | ✅ 规格第 4 章核实过"**无需服务端改动**":works 表 owner-insert 与 works bucket owner-write 都已上线 |
| UI:发布 sheet + 进度 + 成功失败态 | ❌ 已删,需按规格第 5 章重建 |
| l10n 发布相关文案 | ❌ 需补(现有六个 `community*` 键只覆盖 feed 页) |
| **PLY 分支** | ❌ **规格假设 GLB**,见下 |

**真实缺口(两个,都在 Dart 侧且小)**:

1. **`artifactPath` 官方路线不写。**
   实测产品仓 `artifactPath` 的写入点只有三类:demo 资产(`asset://models/*.glb`)、
   GLB 导入(`import_glb_coordinator.dart:248`)、store 刷新(`scan_record_store.dart:204`)。
   官方拍摄路线交付的是 `$captureDir/official_sfm_sparse.ply`,**不写 `artifactPath`**。
   → 结果:移植后的发布服务今天只能发**导入的 GLB**,发不了自己拍的东西。
   `ScanRecord.captureDir`(`:249`)在,所以补一条 PLY 解析路径即可,不需要改模型。

2. **`glb_norm` 归一化步骤对 PLY 无意义。**
   旧服务的流水是 `读 bytes → GlbNormalizer.normalize(社区调优预设) → sha1 → 上传 → 插行`。
   点云路径必须绕开归一化(或换成点云侧的等价处理),这是移植时的实质分支,不是照搬。

**风险**:重新引入一条上传路径,必须重过纯本地边界(见 §4.1)。

---

### 路 C — 格式打通(点云上 feed)

**做什么**:验证 `official_sfm_sparse.ply` 在社区卡片里的真机观感,调三个 splat 旋钮。

**已证伪的部分**:加载本身不是问题(见 §0)。带 RGB 的点云会**带正确颜色**加载。

**仍需实测的**:
- 默认 `scale=0.01`(1cm)对我们米制稀疏云的观感 —— 可能太小(看不见)或太大(糊成一片)。
  旋钮 `splatScaleMultiplier` / `max3dScale` / `lod_extent_min` 都已在 ABI 上,是调参不是开发。
- 我们的 PLY 具体声明了哪些属性(`red/green/blue` 是 uchar 还是 float)—— 两条路径 loader 都认,
  但要确认我们没写成别的属性名。
- 稀疏云点数级别下的 feed 多卡并发显存(策略契约里 ≤2 活跃 viewer 的约束是为 GLB 定的)。

**依赖**:路 C 可以**完全独立于路 A/B 先做** —— 拿一个已有的 `official_sfm_sparse.ply`
直接喂 `AetherCppCardDemo` 就能看,不需要后端、不需要发布链、不需要改路由。

---

### 依赖顺序建议

```
路 C(格式实测,独立、最便宜、结论最硬)
   │
   ├──► 路 A(接回路由,验证后端与渲染链)
   │        │
   └────────┴──► 路 B(移植发布链;需要 C 的旋钮结论 + A 的后端结论)
```

路 C 先做的理由:它是唯一一条**不改任何产品代码就能拿到硬结论**的路,
且它的结论决定路 B 里 PLY 分支怎么写。

---

## 4. 需要你签决的三件事

### 4.1 纯本地边界(必答)

2026-07-13 你签的边界是:云端训练/上传全删,但**用户主动分享的成品**保留,
`SignedUploadBroker` 就是专门为社区留下的。所以社区本身没被否。

但路 B = 重新开一条上传路径。需要你确认它仍落在边界内:
只传成品(`.ply` / `.glb`)+ 用户填的标题描述 + 烘好的缩略图 JPG,
**不传原始帧、不传 manifest、不做云重建、不做训练**。

### 4.2 Supabase 项目归属

现在用的是 dev 项目 `tzvwkqmgaourwqrmxbyb`,anon key 明文写在 `main.dart` 默认值里。
是继续用它,还是开 prod 项目?若换,注意 `--dart-define` 在本工程失效,
注入方式要另定。

### 4.3 feed 的第一批内容从哪来

即使路 B 落地,冷启动的 feed 仍是空的。是先内部自己发几个、还是先做成"只有自己的作品可见"的过渡态?
这会影响路 A 是否值得单独先上。

---

## 5. 未验证清单(诚实交代)

以下我**没有**验证,不要当成事实:

- Supabase 项目 `tzvwkqmgaourwqrmxbyb` 是否仍在线、表内是否有数据(需要网络/凭证)
- 社区页在**真机**上是否还能正常渲染(只做了静态代码与符号核对,没有跑真机)
- 旧树 `publish_service.dart` 是否能在产品仓当前 `community_service.dart`(已加 broker)
  上直接编译 —— 依赖符号我核对了,但没实际编译
- 我们的 `official_sfm_sparse.ply` 头部具体属性声明(没有打开一个真实产物核对)
- `tiered_lru_residency.dart` 的作用与是否必需(只见文件名与行数,没读)
- thermion 遗产(`live_model_view.dart` 773 行 + `cube_scene.dart`)能否安全删 —— 没做引用穷举

---

## 6. 零碎账

- `thermion_flutter ^0.3.4` 仍在 pubspec,但卡面已切 aether_cpp;
  `vault_page.dart:21` 还 import thermion 仅为 `hide VoidCallback`(它把 `VoidCallback`
  重声明成了 ffi typedef,撞名)。清理 thermion 是一笔独立的减重,不阻塞任何一条路。
- "附近" tab 是占位文案 `communityNearbyComingSoon`,**没有任何地理算法**,不要以为有。
- 后端 `follows` / `notifications` / `messages` / `tags` / `collections` / `reports`
  全套建好且带触发器,客户端一行未用 —— 这是一笔已付的沉没资产,V2 若要做关注流可直接接。
