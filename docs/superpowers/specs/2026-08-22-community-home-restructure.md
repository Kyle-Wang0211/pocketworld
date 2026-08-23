# 社区首页改造 —— 可执行方案

2026-08-22。阶段:**冷启动前夕**,公开作品个位数,profile 1 条,单人开发。

> 本方案的每一条都来自 2026-08-22 的三次多 agent 调研(自家家底 / 开源生存 / 冷启动实证),
> 不是设计偏好。凡结论都注明出处;凡未定都标为**待签决**,不替用户决定。

---

## 0. ✅ 树状态已解决(2026-08-23 更新)—— 但冒出一个更前面的问题

### 原阻塞已消除

写本方案时的三条前提**现在全部不成立**:

| 当时写的 | 现在 |
|---|---|
| 「committed main 独立编译不过」 | ✅ **独立编译通过**,已推 `origin/main`(43 笔) |
| 5 个要动的文件是别人的未提交工作 | 3 个已提交:`card_live_governor.dart`(`44aeac4`)、`feed_models.dart`(`b72d654`)、`app_zh/en.arb`(`9a4c703`) |
| 项目在 Flutter 3.41.8 | ✅ **3.47.1 / Dart 3.13.1**,真机已验 |

⚠️ 但 §4 里"`shimmer` 4.0.0 要求 Flutter ≥3.44 ⇒ 会静默降级"这条**因此作废**。
**结论不变** —— 判死 shimmer 的真正理由是 issue #64「40-60% CPU / iOS 过热」
开了三年未关,那条与版本无关,且正对本项目的热软肋。

### 🔴 冒出来的更前面的问题:仓库里有两套并存的卡片实现

| | 已提交(= origin / 手机上跑的) | 工作树(未提交) |
|---|---|---|
| feed 用的卡 | `PostCard`(`post_card.dart` 731 行) | `WorkCard`(`work_card.dart` 637 行) |
| 实时点云 | 无 | `live_card_cloud.dart` 299 行 |
| `vault_page.dart` | 引用 `post_card.dart` | 重写 +226/−181,改用 `WorkCard` |
| 对 work_card 的引用 | **0 处** | 全量 |

**这套 WorkCard 迁移是完整的**(2026-08-23 实测):

```
flutter analyze   0 error
flutter test      909 过 / 1 skip / 0 败     ← 已提交基线是 864,多 45 个
feed_live_card_test.dart  438 行 / 24 用例全过
```

24 个用例覆盖:八叉树预算裁剪、降点后 xyz/rgb 逐点对应、热闸四档带滞回
(nominal/fair 不停 · serious/critical 停 · **停了必须回 nominal 才恢复**)、
24fps 封顶、滚动即停。

即 08-16 签决的「feed 焦点卡真实时自转 = 方案 B + 七道压热闸」,**做完了、验过了、
没提交**。这是本仓今天发现的**第四例**"活只存在于工作树"(前三:断链九文件、
12 份 license、MePage 路由修复)。

### 待签决 D0'(取代原 D0)

本方案 §4 直接点名 `work_card.dart:611-637` 的 `_CardPlaceholder`,
§7 的"藏 0 计数"也要看卡片实现 —— **方案是照着 WorkCard 那个世界写的**。

- **(a) 先提交 WorkCard 迁移,再在其上做改造 —— 推荐**
  它已完整、已验证、多 45 个测试;提交后 `post_card.dart`(731 行)成死代码,可另议清理
- **(b) 在已提交的 PostCard 基线上做改造**
  代价:§4 §7 要重写落点;那套做完的迁移继续躺着,且随时可能被 `git clean` 抹掉
- **(c) 先装机看 WorkCard 的实际观感,再决定**
  代价:多一轮装机;但"feed 卡真的会转"是肉眼决策,值得看一眼

## 1. 已定的决策(用户已签)

| # | 决定 | 依据 |
|---|---|---|
| D1 | 砍掉「附近」「发现」两个标签 | 作品个位数,空标签比没标签更伤 |
| D2 | 砍掉顶部搜索框(**代码保留,只是不渲染**) | 用户 2026-08-22 明确:先留着别删 |
| D3 | 改成**单信息流 + 主题卡** | 缺的是丰富度不是导航 |
| D4 | 骨架屏(灰色 + 轻微闪动)**手写,不加任何包** | 见 §4 |

## 2. ✅ 调研得出的四条修正 —— 用户 2026-08-23 全部签决

| # | 修正 | 依据 |
|---|---|---|
| **D5** ✅ | 主题卡做成**流内第一张卡**(与作品卡同宽同层、可滑走),**不做压在流上方的横幅** | Roblox 的 Today's Picks 官方定位是 "a sort on Home";Behance 把 Best of Behance 做成与 For You 平级的 chip。**三家都没做独立横幅层** |
| **D6** ✅ | 主轨做**常青人工精选**(如「本周精选」),限时活动只作可选叠加 | Roblox 官方把策展分两轨:常青 Standout Games + 限时 Live Events;Sketchfab Masters / Staff picks 全是常青、永不过期。**Sketchfab 的 Weekly Challenge 已停办** —— 有公司背书的团队都没维持住周更 |
| **D7** ✅ | `@handle` 点击做成**流内"只看这个人的作品"过滤**,不做个人主页 | 见 §6 |
| **D8** ✅ | **卡片上不展示为 0 的计数** | 见 §7 |

---

## 3. ✅ 已落地(2026-08-23):砍标签与搜索

全部在 `lib/ui/vault_page.dart`,**后端 `CommunityService` 一行没改**。

### 删掉的(标签整套)

`_CommunityTab` 枚举 · `_CommunityTabBar` · `_CommunityTabPill` ·
`_NearbyComingSoonState` · `_tab` 字段 · `_onTabChanged` · 三处 nearby 早退分支。

**排序定死 `FeedSort.recent`** —— 原默认 tab 是 `discover`,本就映射到 recent,
所以这是**行为不变**的改法,不是换默认值。`FeedSort.hot` 全仓不再被引用。

### 保留的(搜索,D2)

`_SearchBar` 类 · `_searchController` · `_query` · `_onQuerySubmitted` ·
`_onClearQuery` · service 的 query 参数 —— **全部保留,只是不渲染**。
渲染它的那个 `Padding` 被注释掉并留了恢复说明,加了 `// ignore: unused_element`
并注明理由,免得被后人当"未使用代码"清理掉。

### 一条自己踩的坑

测试最初写成 `expect(src, isNot(contains('child: _SearchBar(')))` —— 而源码里
**故意留着**注释掉的恢复代码,里面就有这一行 ⇒ **判据命中了自己写的注释**。
改成先剥掉注释行再断言。这正是 memory 里
`feedback_verification_predicate_must_not_match_own_comment` 记的那条,又犯一次。

## 4. ✅ 已落地(2026-08-23):骨架屏,手写不加包

新建 `lib/ui/community/skeleton_shimmer.dart`,两个件:
`SkeletonBox`(会呼吸的灰骨头)+ `SkeletonWorkCard`(作品卡形状的组合)。

### 判死四个包的理由(其中一条已作废,但结论不变)

| 包 | 判决 |
|---|---|
| `shimmer` | ⛔ issue #64「Extremely high CPU usage causing phone to overheat」**开了三年未关**,40-60% CPU,多份报告特指 iOS —— 正对本项目的热软肋。<br>⚠️ 它"要求 Flutter ≥3.44 会静默降级"那条理由**已随 3.47.1 升级作废**,但上面这条与版本无关,仍然成立 |
| `skeleton_loader` / `skeletons` | ⛔ 五年无人维护 |
| `flutter_animate` | ⛔ 是动画库不是骨架屏库,骨头布局照样手写;停更 21 个月 |
| `skeletonizer` | 🟡 唯一值得考虑,但每帧 `markNeedsPaint()` ⇒ 整个 feed 全量重绘,且**热闸插不进去**(controller 在包内部) |

### 抄了 splash_overlay,连它的坑一起抄

范式来自 `lib/ui/splash_overlay.dart:39-56`:
`AnimationController(1800ms)..repeat(reverse: true)` + `AnimatedBuilder`。

**坑**(该文件 :60-70 原话):

> "Don't spin/pulse behind an invisible overlay — that continuous repaint is
> what made the sign-in page janky."

所以 `animate=false` 时**显式 `stop()` 并返回不挂 `AnimatedBuilder` 的静态容器** ——
不是"转着但看不见"。`didUpdateWidget` 让热闸翻转立刻生效。

### 两个落点 + 热闸

| 落点 | 之前 | 现在 | 热闸来源 |
|---|---|---|---|
| `vault_page` `_LoadingState` | 一个 28×28 `CircularProgressIndicator` | **2 张**与作品卡同形的骨架 | `_governor.liveAllowed` |
| `work_card` `_CardPlaceholder` | 静态暗色渐变 + `blur_on` 图标 | 会呼吸的骨架 | `widget.rotationAllowed` |

只放 2 张不放 3 张:首屏可视区本来就放不下第三张,多画一张是白给的重绘面积。

### 一条测试写法的坑

`find.byType(AnimatedBuilder)` **不能裸用** —— `MaterialApp` 内部自己就有一个
(`listenable: ValueNotifier<String?>`),会误报。必须
`find.descendant(of: find.byType(SkeletonBox), matching: ...)`。

## 5. ✅ 已落地(2026-08-23):主题卡

### D9 = (a) 客户端硬编码

三选一里取 (a)。理由:D6 已定为**常青人工精选**(不是限时活动),换得不频繁;
冷启动期最贵的是工时不是发版。等真需要按周换,再升到独立的 `topics` 表。

**顺带解决了 D10**(判定时机):没有请求 ⇒ 不存在"跟首屏一起请求拖慢首屏"
还是"独立异步请求导致置顶卡晚于列表出现"的取舍。

### 落法(D5:流内第一张卡)

留在同一个 `ListView.separated` 里做**下标偏移**,不换 `CustomScrollView`:

```dart
itemCount: works.length + (kShowCommunityTopicCard ? 1 : 0),
itemBuilder: (ctx, rawIndex) {
  if (kShowCommunityTopicCard && rawIndex == 0) return const TopicCard();
  final i = rawIndex - (kShowCommunityTopicCard ? 1 : 0);
  final w = works[i];
```

⚠️ 方案原文点名的"三处必须跟着改"里,**预取下标那处天然被覆盖** —— 因为
`_kickPrefetch` 用的是偏移后的 `i`,不是 `rawIndex`。`separatorBuilder` 用的是
固定间距,主题卡与第一张作品卡之间自动取到同一个值,无需特判。

### 开关

`const bool kShowCommunityTopicCard = true;` —— 改成 `false` 列表自动退回纯作品流
(`itemCount` 不再 +1)。这就是"有就显示、没有就隐藏"的最低成本实现。

### 文案走 l10n

新增 `communityTopicTitle` / `communityTopicBody`,中英各一份
(zh:「本周精选」/ en:「Editors' Picks」)。
⚠️ 方案原写"本批先不动 l10n"是因为当时树脏;现在树干净了,加 key 是安全的。

### `TopicCard` 是 public

为了 widget 测试能直接 pump 它。它本来也是个正经的可复用卡片,没有私有的理由;
本文件其余 `_LoadingState` / `_EmptyState` 仍是私有,因为没人从外面用。

## 6. ✅ 已落地(2026-08-23):`@handle` 流内过滤

### 后端只差一句

`CommunityService.fetchPublicFeed` 加 `String? authorUserId` 参数 →
`.eq('user_id', authorUserId)`。`profiles` 六字段本就齐、`FeedWork` 本就带 `userId`。

### 前端

- `work_card`:`@handle` 从纯 `Text` 改成 `Text.rich` —— **只有 handle 那一段可点**,
  点数那段不可点。用 `TextSpan` + `recognizer` 而不是套 `GestureDetector`:
  后者会把整行的命中区抢走,连带压掉卡片本身的 `onTap`。
- ⚠️ `TapGestureRecognizer` **必须 dispose**(放在 State 里建、`dispose()` 里释放)。
  每张卡漏一个,feed 一滚就是持续泄漏。
- `vault_page`:`_authorFilterId` / `_authorFilterName` 两个字段 + `_AuthorFilterBar`
  过滤条(只在过滤生效时占位,平时零高度)。
- **过滤生效时主题卡隐藏** —— 「本周精选」是策展,在"只看某个人"的视图里没有意义。

### 明确不做(测试里有反向断言钉着)

头像大图 · 简介 · 关注按钮 · **任何计数**(粉丝/关注/作品数)。
测试断言 `ProfilePage` / `FollowButton` / `followersCount` / `followingCount` /
`avatarUrl:` / `bio` 一个都不许出现在 `vault_page.dart` 里。

### 什么时候升级成真正的主页 —— 用信号不用时间

出现 **≥3 个非创始人创作者、且各自作品 ≥3 件**时再做。

实证参照:Sketchfab 个人主页 URL 约 **7 个月**后(关注 13 个月),且初期卡片
**连作者名都没有**;Polycam `poly.cam/@username` 约 **16–19 个月**后;
Scaniverse 的 release notes 里 profile/follow/feed **零次出现**。

## 7. ✅ 已落地(2026-08-23):卡片上的 0

调研挖出的可迁移原则:**低数字本身就是负向信号**。而当前卡片正在展示
**0 个赞、1 次浏览**(2026-08-22 截图实证)。

### 落法 —— 两者故意不同

| | 做法 | 为什么 |
|---|---|---|
| **赞** | 只藏数字,**心形图标保留** | 心是点赞的**可供性**。藏掉图标 = 把功能藏了,那是另一回事 |
| **浏览** | 低于下限**整块藏**(图标一并) | 它不可点、**没有可供性**,藏掉不损失任何功能 |

下限做成具名常量 `kWorkCardMinViewsToShow = 2`(`work_card.dart`),一行可改。

**为什么是 2 不是 1**:冷启动期公开作品个位数,一件作品的"1 次浏览"几乎必然是
创作者自己点进去的那次。印在卡片上等于告诉每个访客"除了作者没人看过"。
⚠️ 这是**产品判断不是技术约束** —— 想连 0 都显示就设 1,想更狠就设更大。

### 改了三处

1. `_LikeButton` —— `if (count > 0) ...[` 包住数字(图标在 if 之外)
2. `_ViewsChip.build` 首句 —— `if (count < kWorkCardMinViewsToShow) return const SizedBox.shrink();`
3. 两者之间的 `SizedBox(height: 4)` —— 浏览块被藏时这道间距也要跟着消失,
   否则心形下方留一段无来由的空白

### 测试:`test/work_card_zero_counts_test.dart`(6 用例)

⚠️ WorkCard 用 `VisibilityDetector`(闸 1/5/6 靠它算焦点),它默认 500ms 批处理,
widget 树销毁后 Timer 还在跑 ⇒ `A Timer is still pending`。
测试里必须 `VisibilityDetectorController.instance.updateInterval = Duration.zero;`

**四条变异全部咬住**(按 §9 要求):

| 变异 | 结果 |
|---|---|
| 赞的 0 也照印 | 4 过 2 败 ✅ |
| 删掉 `_ViewsChip` 守卫 | 4 过 2 败 ✅ |
| 下限 2 → 0 | 3 过 3 败 ✅ |
| **赞为 0 时连心形图标一起藏** | 4 过 2 败 ✅ ← 最要紧,它保护"功能不能被藏" |

## 8. 建议的执行顺序(风险前置)

1. **先解决 §0 的树状态** —— 不解决,后面全是在流沙上盖楼
2. **§7 藏 0 计数** —— 最小、最独立、立刻可见
3. **§3 砍标签与搜索** —— 只动 `vault_page.dart` 一个文件,可独立验证
4. **§4 骨架屏** —— 独立于以上,可并行
5. **§5 主题卡** —— 等 D9 签决
6. **§6 `@handle` 过滤** —— 最后做,因为它依赖 §3 之后的列表结构

## 9. 验证要求(沿用本项目已验证有效的做法)

- 每一项改动**做完立刻跑变异测试**:植入一个错误,确认测试变红,还原,确认变绿。
  本项目今天已经靠这个抓出至少五处「测试全绿但改坏了不变红」。
- ⚠️ **CI 里没有 `flutter analyze` / `flutter test`**(只有 `security.yml` 四个 job)——
  **回归只能靠人跑**,没有自动网。
- ⚠️ **跑验证前先剔三类环境噪声**(2026-08-22 实测,详见
  `progecttwo/TREE_BASELINE_2026-08-22/README.md`):兄弟仓 `Aether3D-cross` 的路径依赖
  (别处 worktree 假失败 3 个)、嵌套包 `packages/pw_hevc` 未跑 pub get(假 error 56 个)、
  **同一 worktree 反复验证导致生成物累积**(会盖住真 error)。
- ⚠️ **别在跑全量测试的同时开多 agent 工作流** —— 会把计时敏感的测试压成假失败,
  本仓已因此误判过两次。
- 真机验证:装机后必须确认**新代码真的在跑**(不是"装了就算")。

## 10. 明确不做

- 不引入任何新依赖(§4)
- 不做完整创作者主页(§6)
- 不做限时活动机制(D6)
- 不删搜索代码(D2)
- 不动 l10n key(§3,等树干净)
- 不把「热门/发现」当两个东西保留 —— 实测证实**它们是同一个流的两个排序键**,合并零信息损失
