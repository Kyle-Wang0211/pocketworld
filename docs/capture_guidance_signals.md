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
- 阈值 `parallaxMinDeg = 8.0`(构造参数,默认 8°):真机实测厚区(双墙壳)
  平均视差 5.2°,薄区(干净表面)11.4°,取中偏严。

### 默认颜色策略(已生效,UI 无需额外做)

`packed()` 输出的覆盖云颜色 ramp 不变(1 拍≈红、2-3 拍≈黄、≥5 拍≈绿),
新增一条:**观测次数达标但 `maxParallaxDeg < 8°` 的体素压在纯黄,不给绿**。
视差补足(用户换角度再拍到该体素)后自然转绿。

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
  时出黄色 toast/横幅:**"换个角度再拍此区域"** ——原地加拍不会让它转绿,
  必须侧移/绕行(≥8° 视差,约等于 2 m 距离处侧移 0.3 m)。
- 不要按单体素闪烁提示,按"存在压黄区域"这一布尔信号提示即可,体素级
  细节交给覆盖云颜色本身。

### 验证

`tool/coverage_parallax_check.dart`(纯 Dart VM,`dart run tool/coverage_parallax_check.dart`):
双机位夹角 vs 几何真值(14.036°)、同机位 5 拍压黄、14° 给绿、7.5°/8.5°
阈值边界,全部 PASS。

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

## 阈值依据汇总

| 参数 | 值 | 出处 |
| --- | --- | --- |
| `parallaxMinDeg` | 8° | 真机实测:厚区(双墙噪声壳)5.2° vs 薄区(干净表面)11.4°,取中偏严,宁可多黄不误绿 |
| 覆盖 ramp | 1 红 / 2-3 黄 / ≥5 绿 | 既有 `coverageSaturation = 5`,未改 |

## 改动清单(本任务)

- `lib/capture/capture_coverage_cloud.dart` — 视差累计 + 压黄策略 +
  `parallaxDegAt` / `parallaxStarvedVoxelCount` 访问器(packed 布局不变)。
- `lib/capture/sfm_live_recon.dart` — `SfmLiveSnapshot.unregisteredFrameIds` /
  `disconnectedSegments` 纯新增 getter + `SfmDisconnectedSegment` typedef
  (未动任何既有行)。
- `tool/coverage_parallax_check.dart` — 纯 Dart 断言脚本(见上)。
