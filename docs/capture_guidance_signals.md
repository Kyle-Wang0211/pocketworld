# 拍摄引导数据信号(信号1 低视差 + 信号2 断连帧)— UI 消费文档

2026-07-10。两个信号学 RealityScan 的采集引导,**纯 Dart、零 native/ABI 改动**;
本文档给 UI agent,信号计算与默认颜色策略已落地,UI 呈现由你实现。

## 信号1【低视差维度】— `CaptureCoverageCloud`

文件:`lib/capture/capture_coverage_cloud.dart`(计算 + 颜色策略都在这个类里)。

### 语义

- 每个覆盖体素除了原有的 `photoCoverage`(被几张照片拍到),现在还累计
  `maxParallaxDeg`:首次被照片拍到时记住视线方向(相机中心→体素的世界系
  单位向量),此后每次命中都用当前视线与首视线的夹角刷新最大值。
- 为什么要它:**"双墙"真身 = 低视差深度噪声壳,视差角是厚/薄的判别因子**。
  纯观测计数会把"原地连拍 5 张"误报成绿(达标),但低视差观测无法约束
  深度,恰恰是产出噪声壳的拍法。
- 阈值 `parallaxMinDeg = 5.0`(构造参数,默认 5°;2026-07-11 校准,原 8°
  "取中偏严"被真机遥测否决,依据见下节"阈值校准")。

### 默认颜色策略(已生效,UI 无需额外做)

`packed()` 输出的覆盖云颜色 ramp 不变(1 拍≈红、2-3 拍≈黄、≥5 拍≈绿),
新增一条:**观测次数达标但有效视差 < `parallaxMinDeg`(5°)的体素压在
纯黄,不给绿**。视差补足(用户换角度再拍到该体素)后自然转绿。

⚠️ `packed()` 的二进制布局(xyz 3×f32 + rgb 3×u8,逐点同序)**没有变**——
native 侧是哑渲染器,不需要任何配合改动。

### UI 访问方式

```dart
// 某世界坐标所在体素的累计最大视差角(度);无体素或未被照片覆盖 → null。
double? deg = coverageCloud.parallaxDegAt(worldPos);

// 观测次数已达标(≥coverageSaturation)但视差不足(<parallaxMinDeg)
// 而被压黄的体素数。
int starved = coverageCloud.parallaxStarvedVoxelCount;
```

### 建议 UX(RS 式)

- 覆盖云本身已经表达了主信号:**该绿不绿、一直黄 = 换角度**。
- `parallaxStarvedVoxelCount > 0`(建议加个小滞回,比如连续几秒 > N 个体素)
  时出黄色 toast/横幅:话术**必须教动作**(见下节"动作语言表")——原地
  加拍不会让它转绿,必须横移/走近(横移量 ≈ 0.14 × 距离才到 8°)。
- 不要按单体素闪烁提示,按"存在压黄区域"这一布尔信号提示即可,体素级
  细节交给覆盖云颜色本身。
- **不要在文案里报体素数**(2026-07-11 定案,抄 RS):"还有 1683 处区域…"
  既吓人又不可执行;定性 + 动作("仍有较多区域…横移一大步")才可执行。

### 动作语言表(8°~30° 甜区,2026-07-11)—— 引导话术必须教动作

视差甜区:**8° ~ 30°**。>30° 视角外观变化过大,SIFT 特征匹配失败率
飙升,帧反而连不上。所以引导语言是"一大步",绝不是"走到对面"。

⚠️ 甜区下沿(8°)是**动作目标**,不是判黄阈值:判黄/压黄阈值已校准为
5°(<5° = 真危险区,深度不可约束的双墙噪声壳;5°~8° = 够用但不富余,
金标 LAPa 有 43.5% 的点 <8° 仍无重影)。引导话术教用户横移到 ≥8° 的
甜区,但只对 <5° 的真危险区亮黄。

| 用户动作 | 视差效果 | 话术可用性 |
| --- | --- | --- |
| 横移(侧移一步) | 视差 ≈ 横移距离 / 到目标距离(弧度);0.14×距离 ≈ 8° | ✅ 首选:"横移一大步" |
| 走近一半 | 同样横移下视差角翻倍(基线角随距离反比放大) | ✅ "或走近一半再拍" |
| 蹲低 / 举高 | 垂直基线,与横移等效(对桌面/低矮物尤其顺手) | ✅ "蹲低举高" |
| 原地转身 / 原地连拍 | 纯旋转零基线 → **0 视差,完全无效** | ❌ 绝不引导"转一圈" |
| 绕到对面(>30°) | 超出匹配甜区,特征匹配失败 → 断联(红) | ❌ 不引导大跨步绕行 |

横移量速查(达到 8° 所需侧移 ≈ 2·d·tan(4°) ≈ **0.14 × 距离**):

| 到目标距离 | 达到 8° 所需横移 |
| --- | --- |
| 1 m | 14 cm |
| 2 m | 28 cm |
| 3 m | 42 cm |

### 已定案 UI 文案(2026-07-11,ar_capture_page.dart)

- 实时横幅(琥珀 icon + 黑底 pill,`_ParallaxStarvedBanner`):
  **"对黄色区域:横移一大步/蹲低举高,再拍一张"**
- 完成把关弹窗(`_onFinishTap`,占比口径触发):
  标题"拍摄角度可能不足";正文**"仍有较多区域拍摄角度不足,可能出现
  分层。对黄色区域:横移一大步,或走近一半再拍。"**;按钮
  【继续拍摄】(FilledButton,默认)/【仍要完成】(TextButton)。

### 验证

`tool/coverage_parallax_check.dart`(纯 Dart VM,`dart run tool/coverage_parallax_check.dart`):
双机位夹角 vs 几何真值(14.036°)、同机位 5 拍压黄、14° 给绿、4.5°/5.5°
阈值边界(2026-07-11 随校准由 7.5°/8.5° 更新),全部 PASS。
帧卡片滞回 + 白态粘性:`dart tool/photo_card_state_check.dart`;
route B 真值链路:`dart tool/true_parallax_check.dart`。

## 信号2【断连帧列表】— `SfmLiveSnapshot`

文件:`lib/capture/sfm_live_recon.dart`(`SfmLiveSnapshot` 上的纯新增 getter)。

### 语义

- 数据源:快照里已有的 `posesPacked`(9 doubles/帧,第 2 个 double 是
  per-frame registered bit,`registeredCount` 一直就是从它数的)——零 ABI 改动。
- `registered == 0` 的帧 = SfM 没能把这张照片连进重建(特征不足/与邻帧
  匹配失败等),对应 RS 的"断连"状态:这一段的表面在最终云里会缺失或
  只有弱约束。

### UI 访问方式

```dart
// 未注册帧 id,按 frameId 升序。
List<int> ids = snapshot.unregisteredFrameIds;

// 连续未注册区段(按 frameId 序归并),直接对应一句补拍提示。
for (final seg in snapshot.disconnectedSegments) {
  // seg.firstId..seg.lastId:断连区段;seg.count:帧数
  // seg.prevRegisteredId / seg.nextRegisteredId:两侧最近的已注册帧
  // (null = 区段贴拍摄开头/结尾,那一侧没有已注册邻帧)
}
```

`SfmDisconnectedSegment` 是 record typedef:
`({int firstId, int lastId, int count, int? prevRegisteredId, int? nextRegisteredId})`。

### 可用时机(重要)

- 只在 **LOCAL_READY / REFINED** 快照上有意义:流式 preview 快照的
  `posesPacked` 为空(worker 对 preview 发空 poses),两个 getter 返回空列表。
- 即:这是**拍摄完成后**(等待页/结果页)的补拍引导信号,不是拍摄中实时信号。
- frameId → 照片的映射:`SfmLiveRecon.fedFrameMeta[frameId].jpegPath`
  (已有字段),UI 可以据此显示断连区段对应的缩略图。

### 建议 UX(RS 式)

- 断连 = 红色提示。对每个区段,文案模板:
  **"有 {count} 张照片没连上,请在第 {prevRegisteredId} 和第 {nextRegisteredId}
  张的拍摄位置之间补拍"**(RS 的"在红绿之间补拍")。
- `prevRegisteredId == null` → "从头开始的一段没连上,回到起拍位置附近补拍";
  `nextRegisteredId == null` → "结尾一段没连上,回到最后成功位置继续拍"。
- 有 `fedFrameMeta` 的 jpegPath 时,提示里放 prev/next 两张已注册照片的
  缩略图,让用户直观知道"红绿之间"是哪里。
- 区段很多/很碎(如 >1/3 帧未注册)时降级为一条总提示"较多照片没连上,
  建议放慢移动、增加重叠后重拍",避免刷屏。

## 阈值校准(2026-07-11 晚,8° → 5°)

真机实测把 8° 阈值证伪为"扎在分布正中心":

- **帧真值中位分布中心 p50 = 8.75°**:阈值 8° 恰好落在已注册帧真值中位数
  分布的正中心 → **68% 已注册帧被判黄**(卡片密集处观感 80%+ 全场黄)。
  阈值扎在分布中心,"大半场黄"是数学必然,不是拍法问题 —— 引导信号
  失去区分度即失效。
- **金标 LAPa lt8 = 43.5% 且无重影**:认证金标配方的最终云里 43.5% 的点
  三角化角 <8°,肉眼无重影/分层 —— **<8° 不等于坏**,8° 作为"危险"
  阈值过严。
- **重影厚区实测特征 = 5.2°**:双墙噪声壳区域的实测视差特征值。黄框的
  使命是圈住这种真危险区 → 阈值取 5°(首判/压黄锚),滞回带整体平移
  (7/9 → 4/6)。
- 白→黄新增**连续 2 次采样粘性**:流式点云长大时,一批新低视差点可能把
  已白帧的真值中位数瞬间拉低一次(动态污染);单次跌破不改判,连续
  2 次真值采样都 <4° 才转黄。
- 完成把关弹窗占比阈(40%)**不动**:判黄阈值下调后 starved_true 自然
  大降,占比口径无需重校。

## 阈值依据汇总

| 参数 | 值 | 出处 |
| --- | --- | --- |
| `parallaxMinDeg` | 5°(原 8°) | 2026-07-11 校准:帧真值中位分布 p50=8.75°,8° 扎在分布正中心 → 68% 判黄;金标 LAPa lt8=43.5% 无重影;重影厚区特征 5.2° → 黄=真危险区 |
| 覆盖 ramp | 1 红 / 2-3 黄 / ≥5 绿 | 既有 `coverageSaturation = 5`,未改 |
| 帧卡片判黄(真值唯一) | 首判 <5°;白→黄 <4° 且连续 2 次采样;黄→白 ≥6° | `photo_card_state.dart` 滞回三常量 + `kFrameYellowEnterStreak`(2026-07-11 校准 8/7/9→5/4/6):真值未到达保持黑(处理中),视锥近似已彻底退出卡片判定(消"白→黄反序"+1↔3 抖动);白→黄粘性防动态污染 |
| 横幅显示/隐藏 | ≥20 连续 3 采样 / <10 | `parallax_banner_gate.dart`(去抖 + 滞回) |
| 完成把关弹窗 | starved_true / true_vox > 40% | `kParallaxStarvedFinishRatio`(2026-07-11):绝对数 >20 已废——大场景体素基数大必弹(真机 1683/5997≈28% 是健康场景);true_vox==0 不拦;**阈值校准后保持 40% 不动**(starved 自然大降) |
| 匹配甜区上限 | 30° | 视角差 >30° 外观变化过大,SIFT 匹配失败率飙升(动作语言表依据) |
| 甜区下沿(动作目标) | 8° | 横移话术的目标视差(0.14×距离);与判黄阈值(5°)刻意分离:目标教富余,黄框只报危险 |

## 改动清单(本任务)

- `lib/capture/capture_coverage_cloud.dart` — 视差累计 + 压黄策略 +
  `parallaxDegAt` / `parallaxStarvedVoxelCount` 访问器(packed 布局不变)。
- `lib/capture/sfm_live_recon.dart` — `SfmLiveSnapshot.unregisteredFrameIds` /
  `disconnectedSegments` 纯新增 getter + `SfmDisconnectedSegment` typedef
  (未动任何既有行)。
- `tool/coverage_parallax_check.dart` — 纯 Dart 断言脚本(见上)。
