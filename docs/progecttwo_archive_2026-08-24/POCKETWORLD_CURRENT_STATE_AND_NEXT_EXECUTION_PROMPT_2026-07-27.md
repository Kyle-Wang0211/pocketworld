# PocketWorld 当前状态与下一步执行提示词(权威快照 2026-07-27 上午)

> 本文档是继 `POCKETWORLD_CURRENT_STATE_AND_NEXT_EXECUTION_PROMPT_2026-07-25.md` 之后的最新权威交接快照。
> 覆盖 07-26 全天至 07-27 上午的"GPU 匹配去饱和 → K6 退役 → 全流程无损提速 → BA 战场 → 备刀(极线先验)签决材料"整条战役。
> 阅读顺序:先看【铁律与流程】和【当前在飞】,再按需查细节。

---

## 0. 项目消歧(不变铁律)

- `~/Documents/progecttwo/` 是**工作区不是项目**;权威交接文档、备份、host fixture 都在这里。
- **产品 App(Flutter/iOS)**:`~/Developer/pocketworld/`(repo `Kyle-Wang0211/pocketworld`,当前工作分支 **main**,远端已同步)。
- **原生算法(C++)**:`~/Developer/Aether3D-cross/`(`aether_cpp/official_pipeline/` + vendored COLMAP;**全部改动未提交**,用户协调后再处理;⚠️ 此仓 `git status` 会超时,别跑)。
- 设备:iPhone 14 Pro,UDID `1B290474-D354-5B4C-AAB0-0805AC5DC832`,bundle `com.kyle.PocketWorld`,同 Wi-Fi 无线 devicectl(**绝不卸载重装**,只原地 install;签名 team 看 OU=26AH7V448L)。
- 真机包 `flutter build ios --release`;release 日志只走 jsonl sidecar(glog/stderr 全部不可见)。

---

## 1. 本轮战役成果总览(全部已装机+已 push 到 pocketworld main)

**手机上现在的完整形态**(算法形态 = `e65bb64`;⚠️ 07-27 10:27 之后手机上多了一层**未提交的采集页 UI 改动**,见 §1.6 —— 算法/native 二进制完全没动):

官方三角化+2view(已签)→ **K12 全程(K6 已退役)** → v2 融合匹配 kernel(3.1×)+ 分块调度 + 冲刺模式 → 全量 quadratic(预算关死)+ quadratic 保序流水线 → stage-1 BA 全速(轮分配冻结 2/3)→ 全套观测遥测 → EPI 极线先验实验臂(**默认关死**)。

### 1.1 三刀匹配器(逐位无损,全部 host bit-diff 验收)

| commit | 内容 | 验收 |
|---|---|---|
| `cb78757` | **刀C 分块调度**:kernel 加 rowBase;自适应 chunk(冷 16ms/热 6ms)+ 热占空间隙(serious 100%→现 25%/critical 300%,封顶 250ms);杀开关 `OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS=0` | 402 对/256,418 匹配逐位同集 |
| `ebb209c` | **刀A+B 融合 kernel v2**:单遍双向互检(省整个第二遍 GEMM)+ 列 tile 16→32 + 无守卫热循环 + **packed-4×u8 ABI**(对齐未来 WGSL dot4U8Packed);`OFFICIAL_AETHER_MATCH_V2=0` 回 v1;**guided 默认走 v1 双遍**(融合 guided 位级一致构造性不可达,有 1575 编译假设枚举零命中的法医证据;`_V2_GUIDED_FUSED=1` opt-in 待容差签决) | 15/15 parity 矩阵(plain/edge/guided × 4 配置)逐字节;bench 16.1→5.2ms/对 |
| `b6cbbe2` | **冲刺模式**:`aether_gpu_match_set_capture_active`(Swift @_silgen_name 在 AR session run/stop 拨)——相机停后占空归零+大块;真机热态匹配 1954→~900ms/帧 | 逐位同集复核 |

### 1.2 K12 全程 + enrich 修复(0323de0 → 9e4cc16)

- `0323de0`:K12 实验(K_HOT=12)+ enrich 预算关死(全量 quadratic)+ **enrich 调度修复**(armed 顺序 rematch→quadratic→spatial;quadratic 纳预算门+gap 升序)+ quadratic_summary/finalize_rematch_summary jsonl。
- `9e4cc16`:**K6 正式退役**(验证采集 cap_1785070530166049 全判据过:155帧/112serious/cand=12×143/0 rc=7/相机不冻/等待持平)。插件不再 setenv K_HOT;极端机型设 `OFFICIAL_AETHER_LIVE_CAND_K_HOT=6` 即恢复(补账链路仍在)。

### 1.3 数据驱动的两次回退(999b007)——重要方法论案例

- **预付关闭**(`OFFICIAL_AETHER_QUADRATIC_PREPAY=0`):cap5 的 finalize_split 证明 `enrich_gate_wait=0`——quadratic 与 stage-1 并行且 stage-1 更慢,预付偷采集空闲换 finalize 收益≈0。⚠️ 但 cap6/cap7 显示大采集形态下 enrichment 会翻成关键路径——预付复活案有数据基础,列在待决。
- **colorize par 6→3**:par=6 实测 14.4s 反慢于 par=3 的 12.6s(硬解码器吞吐/热封顶)。

### 1.4 观测体系(7a12d98 + 00c8fea)——78s 黑箱已开膛

jsonl sidecar(`Documents/captures_official/<cap>/sfm_match_fail.jsonl`,拉一个 ~30KB 文件即可验证一切)记录类型:
- `build_stamp`:二进制构建时间(根治"代码态当真机态",一天两次踩坑后加的)
- `frame_split`:每帧 match 墙五段拆分(gpu/tvg/tri/lba/tail)
- `finalize_split`:stage1 BA/merge、enrich_gate_wait、stage2 内部(pre/ba/merge/rounds)
- `ba_rounds`:每轮 ceres Summary(iters/jac_s/lin_s/res_s/term/threads)
- `quadratic_summary`(含 prepaid_*)/ `finalize_rematch_summary` / `epi_summary`(EPI 臂开时)/ `point_provenance`
- 另有 `official_finalize_segments.json`(cache_pre/enrich/stage1/stage2/temporal/total + 各 pass 计数)

### 1.5 BA 战场(00c8fea)+ quadratic 流水线(001601d)+ #4553

- **BA EXACT 包**:stage-1 线程减半删除+QoS 恢复 USER_INITIATED(cap43 保护的前提已被 cap5 反转;legacy:`OFFICIAL_AETHER_STAGE1_HALF_THREADS=1`/`_STAGE1_UTILITY_QOS=1`)+ 插件 `STAGE1_ROUNDS_CAP=2` 冻结轮分配保 EXACT。
- **QUAD-PIPELINE**(`001601d`):quadratic 匹配保序流水线——producer 线程只跑 Metal matcher(无 PRNG),TVG+写库留原线程原序;host A/B/B2 三轮 matches+two_view_geometries 两表逐字节同;`OFFICIAL_AETHER_QUAD_PIPELINE=0` 回串行;resume 会话自动串行。出处:官方 colmap `feature_matching_utils.h:103-106` 本就是 matcher→verifier 流水线。
- **#4553 cherry-pick**(在 Aether3D-cross 树内,ransac.h/loransac.h):上游 RANSAC 锁修复;**诚实结论:我们从未开 OpenMP,病灶本来就被编译掉,此补丁=上游对齐+保险**,parity 40 对逐位过。
- **EPI 实验臂**(`e65bb64`,默认关):见 §3。

### 1.6 采集页 UI 三改(07-27 上午,用户直接指定;**已装机、未提交**)

纯 Dart UI,native 二进制一行没动(没跑 rebuild_native.sh,只 `flutter build ios --release` + devicectl install)。

1. **开拍即弹的"20 张"入场提示删除** —— 同一句话搬进"不足 20 张点完成"的
   `official-minimum-photos-dialog`;四档顶部横幅(硬拒 60 / 移速 104 / starved 148 /
   未连接 192)不再有让位入场提示的偏移。
2. **右上角"官方"徽章删除**(`_CaptureRouteBadge` 类一并删掉);顶栏只剩 X。
3. **预览上移 + 两图标面板收起功能(chevron)删除** —— 面板与快门条常驻同屏。
   位置公式抽到 `lib/official_capture/capture_format.dart` 的 `pwCapturePreviewTop()`。
   ⚠️ **硬约束**:画面永远满宽 3:4,只准挪位置不准缩尺寸 —— native 卡片几何按
   `UIScreen.width × 4/3` 硬算,压窄即 WYSIWYG 失效。SE 类短屏(带高 487 < 500)
   顶到状态栏为止、底部仍被面板盖 13pt(改动前盖 76.5pt,非回归)。
   14 Pro 实测:画面 393×524,顶边 164→96.5(上移 67.5),底边距控件条 37.5pt。

### 1.7 采集页 UI-2(07-27 上午,用户指定;**已装机、未提交**)

用户第二轮两条:①相册/快门/完成整排向下平移;②画面下移到底边紧贴两图标灰底面板顶边。

- **整排下移 24pt**:快门行底部内边距 24→0(刘海机由 SafeArea 的 34pt 兜着)。
- **画面贴底**:`capturePreviewTop` 从"带内居中"改为 `max(safeTop, panelTop − 画面高)`。
  14 Pro 实数:画面 393×524,顶边 158,底边 682 == 面板顶边(缝隙 0.0)。
- 几何全部迁到新文件 `lib/ui/official_capture/capture_preview_rect.dart`
  (`CapturePreviewRect` + 各部件常量),`capture_format.dart` 恢复"纯视频格式常量"原职。

**四路对抗验证工作流(13 agent)坐实 8 条、判误报 1 条,已全部处理**:
1. 🔴 **`Align + AspectRatio` 会偷偷缩宽**(`RenderAspectRatio` 在 maxHeight 不足时
   `height=maxHeight; width=height*aspect`)。旧写法在 iPad 9.7 竖屏实测缩成 753(满宽 768)、
   12.9 缩成 1006.5(满宽 1024),且本次改动把触发阈值从 `H<W×4/3` 放宽到 `H−safeTop<W×4/3`
   = **净回归**。⚠️ iPad 是**声明支持**机型(`TARGETED_DEVICE_FAMILY = "1,2"`)。
   修法=`Stack(clipBehavior: hardEdge)` + `Positioned(width/height)` 给紧约束,放不下就裁不缩。
   (`SizedBox` 修不好 —— `RenderConstrainedBox` 会 `enforce(constraints)`。)
   **复核纠正了一处夸大**:等比缩小**不会**让 AR 卡片错位 —— native 喂的是
   `camera.projectionMatrix(for:viewportSize:)`,只吃宽高比不吃绝对尺寸。所以
   "3:4 画幅"才是硬约束,"满宽"是产品要求。注释已按这个口径改准。
2. 🔴 **SE 2/3(`safeBottom == 0`)快门贴死屏幕物理底边** —— SafeArea 让开的是 0 不是 34。
   修法=`captureShutterRowBottomPadding = max(0, 10 − safeBottom)`,且**必须与
   `capturePanelTop` 同源**(只在快门行单点加 padding 会让面板反过来盖住画面 12pt)。
   余量上限 11(超过 SE2 就贴不住),取 10。
3. 🔴 **原布局测试是恒真式**(`previewHeight == width*4/3`,而 previewHeight 就是这么算的),
   零守门力,正是它放过了 ①。现已全部改成 `pumpWidget` 真渲染断言实际矩形,
   机型表补进 iPad×2 / SE Display Zoom(320×568)/ 横屏四种**兜底形态**。
4. ⚪ 判误报:"画面其实相对 HEAD 上移了 6pt" —— 复核认定漏算遮挡且基线选错。
   但注释已写清两个基线:相对 UI-1(手机上那版)下移 61.5pt;相对 HEAD 矩形上移 6pt、
   **可见底边**下移 24pt(面板不再压画面)。
- 既有未修(非本次引入,已记录):全仓无 orientation lock 而 native 写死 `.portrait`,
  横屏是塌陷面;`_isAiming` 分支是死代码(`_onCenterTap` 无人调用,HEAD 亦然)。

验收:`flutter analyze` 12 条全部 HEAD 既有、零新增;`official_capture_preview_layout_test.dart`
20 pass(9 机型 × 真渲染);全量 `flutter test` **166 pass / 4 fail**,4 条失败逐字仍是
改动前既有的陈旧契约(`busy: finishing || capturing`、`FinalizeRematchStarvedFrames`、
`.liveRepay(`、`for (name, card) in photoCardNodes`)。装机后二进制核验:
`keyboard_arrow_up_rounded` 已消失、`official-minimum-photos-dialog` 仍在。

### 1.8 采集页 UI-3(07-27 上午,用户看实机截图后指定;**已装机、未提交**)

用户反馈 UI-2 的实机效果:"画面还是跟灰底上沿有少部分重合,灰底跟快门也有少量重合",
要求:灰底栏整体上移 + **不能再半透明** + 画面上移且与灰底栏**没有任何重叠**。

- **根因一半不是几何、是透明度**:灰底 `0xE61C1C20` = 90% 不透明,画面从面板顶部
  透出来,看着就是"重叠"。改 `0xFF1C1C20`。
- **另一半是"严丝合缝"本身**:UI-2 让画面底边 == 面板顶边、面板底边 == 快门圆顶边,
  三层两两相接,视觉上就是压在一起。现在引入
  `captureSeparatorGap`(10pt),画面↔灰底、灰底↔快门各一道。
- 14 Pro 实数:画面 138–662 | 缝 10 | 灰底 672–732 | 缝 10 | 快门 742–818(**快门行原地
  不动**,灰底上移 10,画面上移 20)。
- **降级顺序**(空间不够时):先让间距(纯装饰)→ 再把画面钉在状态栏下沿承认底部被盖
  → **永远不压窄画面**。SE 2/3 全屏只剩 1pt 富余,间距自动缩到 0.5(仍不重叠);
  iPad 竖屏 / SE Display Zoom / 横屏间距让到 0 并走钉状态栏分支。

验收:`official_capture_preview_layout_test.dart` **26 pass**(9 机型真渲染 + 间距分组
+ 不透明契约);`flutter analyze` 12 条仍全部 HEAD 既有。

⚠️ **并发提醒(07-27 11:44–11:46)**:另一个 agent 正在同一棵脏树里修那 4 条陈旧契约测试
(`official_highres_reconstruction_contract_test.dart` 已修好、
`official_stop_production_contract_test.dart`、`photo_card_distance_scale_contract_test.dart`
在改)。全量 `flutter test` 因此从 166/4 变成 **172 pass / 3 fail**,减少的那条不是我改的。
这三个文件**不属于本次 UI 改动**,别把它们算进 UI 的 diff 里。

### 1.9 选区功能全量落地(07-27 下午/晚,Subagent 驱动 7 任务;**已装机、已提交**)

RS Reconstruction Region 复刻,brainstorming→spec→plan→subagent 执行全流程。
spec/plan:`docs/superpowers/specs/2026-07-27-selection-region-design.md` +
`docs/superpowers/plans/2026-07-27-selection-region.md`(RS Mobile 官方文档调研修订:
2D 投影矩形手柄非 3D 线框;滑杆=相机 yaw 联动,侧视角与 RS 的 roll 差异已签)。

**功能提交链**(全在 main,未 push):598723c(SelectionBox JSON 模型)→ 9afb394+4d1a467
(CloudCamera/CloudProjection 投影单一事实源,SparseCloudView 两热循环改标量来源,
parity 测试 1e-9;⚠️ brief 手推 upAxisWorld 符号错被数值微分测试抓出修正,**upAxisWorld
= 屏幕上方向**)→ f5990ca(SparseCloudView 只读回显:框线+框外红 kSelectionOutColor)→
f29cec5(2D 矩形手柄纯函数:boxScreenBasis 投影差分零映射表/applyRectHandleDrag 对面不动
/applyBoxPan 修 dy 反号)→ ac9b15b(SelectionPage:六面预设/滑杆/debounce 落盘/占位键;
**顺手修真 bug:late final AnimationController 不碰立方体直接返回会在 dispose 炸**)→
4b7806f(等待页 refined 双按钮 保存草稿|下一步 + push SelectionPage,pop 'save_draft'
走原退出链)→ e80ac6d(草稿查看器回显)→ 4c69e07(终审 5 修:**PopScope 关系统返回
绕过 flush 的洞**/fitFillK 单一事实源/contains 注释代数/onNext 守卫/最短弧;⚠️ 该 commit
被并发 agent 卷进 .command+重编 .a,内容核对完好,崩溃修复符号幸存)→ 92c808e(措辞+
返回防重入)。

**质量记录**:终审(opus)对着 Flutter SDK 源码核 PopScope 两分支后判 READY TO MERGE;
全量 flutter test 211/211;analyze 12 条基线零新增。已 flutter build ios --release +
devicectl 原地装机。
**测试坑(记住)**:testWidgets 的 FakeAsync zone 里真实 dart:io Future 完不成 →
必须 tester.runAsync 轮询推进(helper `_pumpUntilRealAsyncSettles` 在
test/selection_page_test.dart);两个 flutter test 并发会 build-lock 互等死锁。
**可发布后修清单**(ledger `.superpowers/sdd/progress.md` 有全量):m==0 框线消失/
yaw 弱断言/Top↔水平循环跳 Front/窄屏换行等,均 Minor。
**待用户真机手测**:拍 20+ → refined → 双按钮 → 下一步 → 六面切视角/拖手柄/滑杆/
框外变红 → Ready to Process 提示不退出 → 返回落草稿列表 → 草稿查看点云见框+红点、
点数全量不变。

**增补(07-27 深夜,已装机已提交 a2b0a8c)**:草稿查看器选区入口 —— 草稿点开的
稀疏点云页面底部 = 等待页同款"保存草稿|下一步"(共享 `SfmBottomActionButton`),
下一步进 SelectionPage(零改动复用),返回刷新框回显。spec 增补节 + 单任务 plan
(`docs/superpowers/plans/2026-07-27-selection-from-drafts.md`)。全量 218/218。
**widget 测试第三坑**(与前两坑并记):等"路由退场/入场"谓词时 `tester.pump()`
必须带 duration,否则动画时钟不动、pop 已发生但页面永不出树 → 谓词恒假。
⚠️ 又见并发卷/夹提交:85b23ec(gravity 对齐,他人)夹在本功能提交之间;
review 已确认本功能三文件未被污染。

⚠️ UI-1 + UI-2 + UI-3 全部已随 95e4240/aab4bd3 落库;本节选区提交同样**未 push**
(共享脏分支,由用户协调)。UI-1..3 改动文件:
`lib/ui/official_capture/ar_capture_page.dart`、`lib/official_capture/capture_format.dart`、
`lib/ui/official_capture/capture_preview_rect.dart`(新增)、
`test/official_capture_{copy,twenty_frame_ui}_contract_test.dart`、
`test/official_capture_preview_layout_test.dart`(新增)。

---

## 2. 关键采集记录与核心定案(判断一切回归先查这里)

| 采集 | cap id | 形态 | 点/帧 | 关键结论 |
|---|---|---|---|---|
| 未命名10 | cap_1785034520629049 | 07-26 上午日光 | 934 | 自研建点时代基线 |
| 未命名11 | cap_1785055107915555 | 07-26 下午日光 | 808 | 官方三角化+2view 真机验证(已签切换) |
| 未命名3 | cap_1785066707194992 | 07-26 晚灯光 | 551 | 揪出 enrich 调度倒挂(quadratic 饿死 rematch);**傍晚每对内点 −36%** |
| 未命名4 | cap_1785070530166049 | 07-26 晚 | 604 | K12 全程判据全过 → K6 退役依据 |
| 未命名5 | cap_1785078141726265 | 07-26 晚 | 582 | 78s 黑箱开膛:BA 77s 主宰;预付定罪;enrich_gate_wait=0 |
| 未命名6 | cap_1785082211938612 | 07-27 凌晨 | 559 | EXACT 包兑现但关键路径翻面(enrich 61s>stage1);k≈1.30 坐实;**队列冤案平反(预付非元凶)** |
| 未命名7 | cap_1785113715332747 | **07-27 上午日光** | **974(历史最高)** | 白天问题规模+45%;drain 246s=63% GPU 热降频匹配;**TVG 实测 11ms/对(TVG 池撤案)**;enrich 424ms/对≈热降频 GPU 价 |

**核心定案(不要重新推导)**:
1. **点数由光照决定**:每对内点 白天 ~1450-1500 / 傍晚 ~900(−36%);跨采集比点数先比每对内点密度。
2. **债守恒**:匹配总量固定,只能选在哪、以什么热价付;拍摄期末尾/finalize 的 GPU 是 6× 热降频价。
3. **Ceres 无免费午餐**:154 相机是 DENSE_SCHUR 甜区;外部 BA 库全灭(RootBA/g2o/GTSAM/CUDA 系);LAPACK 已装机(≥180 帧生效,签决设计);mixed precision 已否决;本形状 phase-2 地板 ≈58s(轮分配放飘后,须签决)。
4. **replay 下游有固有时序非确定性**(B≠B2 而库表逐位同)——判 parity 只看 db 表,别看最终点数。
5. **500s 白天等待的构成**:drain 246.8(GPU 匹配 155.7+提取 56.8)+ phase2 232.6(enrich 147.9+stage1 110∥+stage2 84.6)+ colorize 19.7——**~300s 是热降频价 GPU 匹配 = EPI 备刀的靶子**。

---

## 3-bis. 【已定案 07-27 下午】A6 提取批处理 + A1b 异步预览 BA:**双双 DO-NOT-SHIP**

- **A6(提取描述子批处理)判死**:九段计时器(`frame_split.ex[9]`,5d272d9 装机)首采即定案——提取 904ms/帧里描述子仅 **32.8%**(朝向 19.7 / 金字塔 14.8 / 检测 11.3 / 仿射 9.5 / 打包 7.5),**分布平坦无主导段**,PopSift 的"DSP×N 描述子主导"在我们 kernel 上不成立。描述子完美 3× 也只换整体 1.28×,不值 1-2 周 WGSL 重写。长线可选:朝向+仿射+描述子三段融合(覆盖 62%,更深更差 ROI)。
- **A1b(异步预览 BA)判死**(臂已入库 `a608c62`,默认关):**速度全兑现**(喂帧内阻塞 BA 11.48s→0.038s = −99.7%,喂帧墙钟 −14~−17%),但质量三条死因:①cap3_eve 交付点 −5.65%/−6.33% vs A2 噪声带 0.059%(超 96-107 倍),3 视 −5%、7+ 视 −6.4%、少配准 1 帧;②**臂自身重复性(B↔B2 点数 0.71%/3+ 轨迹 2.9%/丢 1 帧)差于被测噪声带(A↔A2 0.059%/0.071%/0)**——自证无法用噪声带论证无损;③后台 BA 丢弃率 40%(kicks11/merges6/dropped4),每次烧 5-8s 且预览拿不到该次精化。cap7_day 点数过门但 σ_depth 5 桶×2 跑 **10/10 全朝坏**。病因定位:合并只搬双方共有 id 的位姿/xyz,**后台 FilterFrames 的删除决定被丢弃**。档案 `_host_fixtures/a1b_matrix/MATRIX.md`。
- **⇒ 300 帧门票另寻**:候选 ①发布政策按帧数降频(改预览语义=产品取舍,须签决)②合并语义修正(整模型换 or 搬删除决定,仍 NOISE-BAND,须新矩阵)。

## 3. 【已定案 07-27 上午】EPI 极线先验剪枝:**DO-NOT-SHIP(矩阵实验判死,未上桌签决)**

**终审(8 轮全矩阵,cap3_eve/cap7_day × A/A2/B-def/B-wide,真 Metal matcher,生产 env;全档案在 `_host_fixtures/epi_dossier/DOSSIER.md`)**:
1. **fallback 率 47.8%~50.5%(四个 B 格全部)**:K12 远 gap 配对天然 <150 条(eve gap16+ 平均 99)⇒ 一半配对结构性双付(guided 白跑再全量重跑),放宽带宽无效;
2. **交付点 +12.43% 而噪声带只有 0.03%**:带宽削掉 Lowe-ratio 全局分母,放进认证匹配器刻意拒绝的歧义匹配(新增点 84% 是 2-view);reproj 四格一致变差(最大 +0.011 = A2 带 27 倍)——**这是"另一个算法",不是认证算法的加速版**;
3. **速度反向**:feed +33~47%、quadratic ×3.9~4.3——guided 路由走的是 v1 双遍 kernel(v2 融合 kernel 无 guided),连不 fallback 时都比 v2 全量慢。
诚实记录对臂有利面:σ_depth 每桶 p50 略优(−2~−8%)。臂真跑了的证据:attempted 2023~2180、missing_pose=0;A vs A2 匹配集逐字节同。
**复活条件(若将来重启)**:①fallback 门改 gap 感知;②ratio 语义要么全量分母 parity(吃掉节省)要么把 +2v 点当有损取舍签决;③guided 路径先拿到 v2 级 kernel;④设备端归因 guided 单对成本。实验臂代码保留在库里(默认关死,零出货影响)。

**实验臂实现细节(留档)**(`e65bb64`,默认关死,unset env = 出货行为逐字节同):
- 几何:`E = EssentialMatrixFromPose(ARKit 相对位姿)`(用喂入的原始先验 `FrameRecord.cam_from_world`,BA 不回写),走**现成** COLMAP-parity guided kernel(`PrepareGuidedGeometry` CALIBRATED 路)。
- 防线:带宽 gap 自适应(基 30px+5/gap,封顶 150)、匹配数塌陷(<150)/rc 失败/缺位姿 → 原样全量 GEMM。
- 旋钮:`OFFICIAL_AETHER_EPI_PRIOR_MATCH` / `_EPI_BAND_BASE_PX` / `_EPI_BAND_PER_GAP_PX` / `_EPI_BAND_MAX_PX` / `_EPI_FALLBACK_MIN`。
- 接线:live K12 循环 + quadratic 串行/流水线 producer;`epi_summary` jsonl。

**矩阵实验 agent 在跑**(host,2 fixture × 4 臂 = 8 次完整重放,风险格 cap3-傍晚优先,边跑边存 `RESULTS-PARTIAL.md`):
- 臂:A 基线 / A2 基线复跑(**定义噪声带**)/ B-def(30/5/150)/ B-wide(60/8/200)。
- 量:点数、reproj、track 分布、σ_depth 逐桶(ba_cov_tool)、逐 gap 段匹配数 B/A、attempted/fallback(防假 A/B:replay 必须喂 ARKit 位姿,否则臂静默全回退)、速度。
- 产出:`~/Documents/progecttwo/_host_fixtures/epi_dossier/DOSSIER.md`(SHIP-CANDIDATE/NEEDS-TUNING/DO-NOT-SHIP)+ PLY + compare.html 并排肉眼。
- **红线:落不进 A vs A2 噪声带就地判死,不上桌签决。**
- ⚠️ 该 agent 曾因宿主进程重启被杀一次(无残留);若再中断,fixture/工具都在耐久目录,按 §5 重启。

---

## 4. 即将面临的问题与待决清单(按优先级)

1. **EPI dossier 出结果 → 签决**(在飞)。判据模板:B-def 全metrics落 A2 带内 + fallback 率可接受 + 并排肉眼过 → 带数据 AskUserQuestion;NEEDS-TUNING → 调带宽重跑;DO-NOT-SHIP → 存档,回到"接受白天形态的物理账"。
2. **BA 第二步:轮分配放飘**(全速+CAP=4 → 4/1 分配,phase-2 ~58s,−28%):NOISE-BAND 须签决。**已有不利证据**:cap6/cap7 的 ba_rounds 显示多轮撞 giter=50 帽未收敛(term=1)——post-enrich 只剩 1 轮的质量价要用遥测数据定,别急着上桌。
3. **预付复活案**(大采集/白天形态 enrichment 是关键路径,队列冤案已平反;但 cap7 显示采集期空闲也被吃光,预期只有 ~10-17s,小牌)。
4. **k 系数复验**:stage-1 全速 vs enrich 争核(cap6 实测 k≈1.30);EPI 若上线会大幅缓解(enrich 的 GPU 时间掉一个量级)。
5. **preview 发布超线性**(495ms@20→9.5s@140→15.7s@145 poses,**300 帧外推单次 30-45s = 规模化头号定时炸弹**):增量快照/移出 worker,EXACT 类,还没动工。
6. **提取 kernel A6**(PopSift MMSys'18 指认 DSP×10 描述子为主导;保序求和可 bit-identical):长线大工程,白天形态 drain 的 23% + 采集期 122s。
7. **guided 融合转正**(`_V2_GUIDED_FUSED` opt-in):需容差验收准则 + 签决,低优先(guided 只在 finalize 低频用)。
8. **Aether3D-cross 全部改动未提交**(official_aether_sfm_c.cc 未跟踪 + colmap vendored 4 文件改动 + build 产物):等用户协调;备份齐全(§5)。
9. **杂项**:errInternal 真因(日志已埋,等复现);stage-2 skip(NOISE-BAND,低价值);LAPACK 送审前符号扫描;(9) 的 db 可续跑、(8) 建议删。

---

## 5. 本地文件位置全表

### 5.1 生产源码(改动过的关键文件)

| 文件 | 内容 |
|---|---|
| `~/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc` | **主战场**(未跟踪文件!):三角化/quadratic/rematch/prepay/EPI 臂/T1T2T3 遥测/QUAD-PIPELINE/stage-1 全速全在这 |
| `.../src/official_bundle_adjustment_ceres.cc` | LAPACK 路由 + **ba_rounds 遥测环**(aether_ba_ring_*) |
| `.../src/official_gpu_match.mm` | matcher 镜像(与 pocketworld vendored 逐字节同步) |
| `.../third_party/glomap_vendor/colmap-src/colmap/sfm/incremental_mapper.cc` | **[AETHER-T1] IterativeGlobalRefinement 计时钩子**(aether_igr_*) |
| `.../colmap-src/colmap/optim/{ransac.h,loransac.h}` | **#4553 补丁已应用** |
| `~/Developer/pocketworld/vendor/official_sfm/src/pwofficial_gpu_match.mm` | v1+v2 匹配 kernel 本体(capture_active 冲刺开关在此) |
| `~/Developer/pocketworld/vendor/aether_ffi/src/pwsfm_gpu_match.mm` | 自动生成镜像(改名归一,同步脚本见 §6) |
| `~/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift` | **出货 env 全景**(§6)+ 冲刺模式 Swift 侧 + AR 卡片 β 曲线 |
| `~/Developer/pocketworld/lib/official_capture/sfm_live_recon.dart` | worker/facade:finish_pending、capture-active FFI 门、repay 通道 |
| `~/Developer/pocketworld/lib/ui/official_capture/ar_capture_page.dart` | colorizePar=3、完成按钮、colorize 调用点 |
| `~/Developer/pocketworld/vendor/official_sfm/scripts/verify_source_parity.py` | **门禁**:sfm_c pin=`f287bc91…`、BA wrapper pin=`411d1307…`(独立 pin,BA-RING 分支)、全部 reviewed-delta 注释 |

### 5.2 耐久实验资产(⚠️ /tmp 会被系统清空——07-27 实测一夜全没,永远放这里)

| 路径 | 内容 |
|---|---|
| `~/Documents/progecttwo/_host_fixtures/cap7_day/` | 白天 fixture:official_sfm_live.db(195MB)+ fed_frames.jsonl(ARKit 位姿) |
| `~/Documents/progecttwo/_host_fixtures/cap3_eve/` | 傍晚 fixture:db(203MB)+ jsonl |
| `~/Documents/progecttwo/_host_fixtures/tools/ba_cov_tool.cc` | σ_depth 工具源码(⚠️ 必须 vendored Eigen:`third_party/eigen-install/include/eigen3`,homebrew Eigen 跨 TU 段错误) |
| `~/Documents/progecttwo/_host_fixtures/epi_dossier/` | EPI 矩阵实验产出地(DOSSIER.md/RESULTS-PARTIAL.md/PLY/compare.html) |
| `~/Documents/progecttwo/_native_backup_20260725/` | **20+ 份 native 源码演进备份**(…_with_prepay / _ba_stage1_full / _quadpipe / _epi_arm / incremental_mapper_with_t1_hooks 等) |
| `~/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-host/` 等 | host CMake 构建树(重放/对拍工具从 bench/sfm_replay_bench* 派生:去 GPU 弱 stub + use_gpu_match=1 + 链 pwofficial_gpu_match.mm) |

### 5.3 设备侧(devicectl 拉取口径)

```bash
xcrun devicectl device copy from --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 \
  --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld \
  --source Documents/captures_official/<cap_id>/sfm_match_fail.jsonl \
  --destination <本地绝对路径> --timeout 300
```
- 设备日志:`Documents/official_pw_device_log.txt`(Dart 侧;native glog 不可见)。
- 采集目录:`Documents/captures_official/cap_<epochMicros>/`(db/jsonl/segments/ply/photos)。
- 设备掉线(error 1011/12040):让用户解锁手机/确认同 Wi-Fi,顽固时重启手机。

## 6. 出货 env 全景(插件 `OfficialAetherARKitPlugin.swift` register 块,判断在产行为必查两层:native 默认 ⊕ 插件 setenv)

当前 setenv:`STREAM_TEMPORAL_ONLY=1`、`OFFICIAL_TRIANGULATE=1`、`SELFDEV_TRIANGULATE=0`、`TRI_IGNORE_2VIEW=0`、`ENRICH_TIME_BUDGET_MS=0`(全量 quadratic)、`QUADRATIC_PREPAY=0`、`MATCH_GAP_SERIOUS_PCT=25`、`STAGE1_ROUNDS_CAP=2`。
**已移除**:`LIVE_CAND_K_HOT`(K6 退役)。
**native 默认即生效**:MATCH_V2=1(v2 kernel)、QUAD_PIPELINE=1、CHUNK 6/16ms、冲刺模式、stage-1 全速。
**默认关,须显式开**:`EPI_PRIOR_MATCH`、`V2_GUIDED_FUSED`、`STAGE1_HALF_THREADS`/`STAGE1_UTILITY_QOS`(legacy 回退)、`DENSE_LAPACK`(<180 帧强开)。

镜像同步脚本(matcher 改动后必跑):
```bash
cd ~/Developer/pocketworld && python3 - <<'EOF'
from pathlib import Path
off = Path("vendor/official_sfm/src/pwofficial_gpu_match.mm").read_bytes()
d = off.replace(b"pwofficial_", b"pwsfm_").replace(b"PWOFFICIAL_EXPORT", b"PWSFM_EXPORT")
for a,b in ((b"0.8 product default", b"0.7 default"),(b"product default 0.8", b"default 0.7"),(b"maxRatio = 0.8f", b"maxRatio = 0.7f"),(b"max_ratio > 0 ? max_ratio : 0.8", b"max_ratio > 0 ? max_ratio : 0.7")):
    d = d.replace(a,b)
Path("vendor/aether_ffi/src/pwsfm_gpu_match.mm").write_bytes(d)
Path("/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/src/official_gpu_match.mm").write_bytes(off)
EOF
```
标准链:native 改 → 算 pin(exec parity 脚本头部拿 normalize_owned_names)→ 更新 pin+reviewed-delta 注释 → `bash vendor/official_sfm/scripts/rebuild_native.sh`(29 PASS)→ `flutter build ios --release` → strings/nm 内容核验 → devicectl install → commit -F 文件 </dev/null → push --no-verify(仅 pocketworld)→ 源码备份进 `_native_backup_20260725/`。

## 7. 流程铁律(本轮新增/强化的)

1. **提案必带出处标签**:[官方 file:line] / [调查报告 lever-X] / [自创,需签决]——用户已问责过一次"是不是一直自创",此规矩不可破。
2. **APPROXIMATE 类改动**(EPI、轮分配放飘、guided 融合):host 矩阵数据落 A-vs-A2 噪声带 + compare.html 并排肉眼 + AskUserQuestion 签决,三关缺一不可;数据不好看就地终止不上桌。
3. **拍完等待只能变短不能增加**(用户硬约束,同形态对比口径)。
4. **验收看 db 表逐位 diff,不看最终点数**(replay 下游固有抖动)。
5. **跨采集比点数先比每对内点密度**(光照形态差 ±36%)。
6. **jsonl sidecar 是唯一真机验收通道**;build_stamp 必查,防"代码态当真机态"。
7. 耐久产物放 `_host_fixtures/`;引用旧 /tmp 路径先 ls。
8. dossier/矩阵类长任务:边跑边存 partial、风险格优先、被杀后按本文档重启。
