# RealityScan 的「即时照片卡」与 ARKit 高清拍摄拖慢的机制调研

2026-09-01。七路 agent(英文社区 / 中文社区 / 逆向拆包 / 日韩俄欧八语种 / 专利与学术 /
ARKit 机制 / SDK 数据库),各限时约 25 分钟。所有关键引文我都自己回源核过一次。

## 为什么查

我们想做到:按下快门时,在拍摄位姿上**立刻**出现一张照片卡 —— 这是用户定的产品底线
(「拍照和给反馈必须同时发生」)。08-28~09-01 的实现做到了(黑卡+震动在第 93ms),
但同期出现回归:世界锚点被修正 0.24–0.37m / 20–33°,跟踪丢失 5.3 次/分。回滚到
08-27 基线后两者归零(见 `baseline/verified-zero-drift-20260827`)。

于是问:**同行是怎么在不压 AR 会话的前提下做到即时卡片的?**

证据标准(对所有 agent 一致):拆包符号 / 工程师原话 / 专利 / 官方文档 / 点名 API 与
调用顺序的技术文章。**UI 行为描述明确判为无用。**

---

## 结论

**1. RealityScan 的实现:七路全零。** 没有任何公开的拆包、符号表、工程师技术表述、
专利或论文。这不是搜索不力,是这份材料在公开渠道不存在。

**2. 但问题本身被两条结构事实改写了 —— 同行很可能没解决这个问题,而是绕开的。**

**3. 我们自己那个回归的机制,Apple 有完整的官方因果链。** 这是本次调研唯一可直接
行动的产出。

---

## 一、RealityScan:它可能根本没面对我们这个约束

### 事实 A — 不是 Unreal 应用

Apple iTunes Lookup API(`https://itunes.apple.com/lookup?id=1584832280`)一手返回:

```
bundleId         com.epicgames.RealityScan
fileSizeBytes    66,651,136   (66.7 MB)
minimumOsVersion 16.0
sellerName       Epic Games International, S.a.r.l.
```

对照:Polycam 520.3 MB,Scaniverse 247.8 MB。66.7MB 排除 UE。Android 侧
([AppGoblin 二进制扫描](https://appgoblin.info/apps/com.epicgames.realityscan),
2026-08-21)检出 Kotlin / OkHttp / Glide / Lottie —— 普通原生栈,无 Unity 无 Unreal。

**推翻了此前"照片卡画在自研跨端渲染器里"的猜测。**

### 事实 B — iOS 包不要求 ARKit(带对照)

`supportedDevices`(由 Info.plist 的 `UIRequiredDeviceCapabilities` 派生)有 127 项,
**包含 iPhone 5s / 6 / 6 Plus / iPod touch 6** —— A7/A8,做不了 ARKit 世界跟踪。

| App | 大小 | 含 iPhone 6(A8,无 ARKit) |
|---|---|---|
| RealityScan | 66.7 MB | **是** |
| Polycam | 520.3 MB | 否 |
| Scaniverse | 247.8 MB | 否 |

Polycam 与 Scaniverse 都过滤掉非 ARKit 机型,RealityScan 不过滤。
[Epic 系统要求文档](https://dev.epicgames.com/documentation/en-us/realityscan-mobile/RealityScan-System-Requirements-and-Installation)
里 **Android 明写要 ARCore,iOS 只写系统版本、没有对应的 ARKit 要求**。

**边界:不要求 ARKit ≠ 不用 ARKit。** 没人拆过它的 iOS 二进制,框架链接列表仍未知。

### 事实 C — Epic 自己的文档说 AR 引导与相机控制互斥

[Camera Controls 文档](https://dev.epicgames.com/documentation/realityscan-mobile/camera-controls):
手动**对焦 / 白平衡 / 曝光 / 闪光灯**模式下,**AR 引导、实时点云、自动拍摄全部不可用**。

那四个旋钮是 `AVCaptureDevice` 属性,ARKit 没有对应物。最干净的读法(**推断,非证据**):
Epic 拆成两条互斥的栈 —— ARKit 那条有 AR 引导,AVCapture 那条有相机控制但没有 AR。
**他们没有在活着的 ARSession 里解决高清拍摄,而是用模式互斥绕开。**

---

## 二、Scaniverse:唯一被真正拆过的同行,而且答案是「整套架构不同」

`https://github.com/jampekka/descaniverse` —— 对 Scaniverse 2.1.4 的公开逆向,用
[`resymbol`](https://github.com/paradiseduo/resymbol) 从二进制提取 Swift 类型元数据。
以下符号逐条引自该仓库的 `reverse_engineering/Scaniverse.headers`(6877 行)。

```swift
class ScannerView: UIView {
    let metalView: MTKView
    let commandQueue: MTLCommandQueue
    let quad: ScreenQuad
}
class ScannerViewController: UIViewController {
    let scannerView: ScannerView
    let coachingView: ARCoachingOverlayView
    let session: ARSession
    var featurePointRenderer, raycastRenderer, debugRenderer
}
```

* **实时 AR 视图是自己写的 Metal 渲染器**:相机背景是 `ScreenQuad` 经 `MTKView` blit,
  特征点/raycast 叠加层各是独立的 Metal renderer。`ARSession` 只做**无头跟踪**。
* SceneKit 只出现在扫描**之后**的查看/编辑器(`ScaniverseSceneView: SCNView`、
  `CropBox` 的 gizmo 节点)。**实时路径上没有"每个标记一个场景节点"这回事。**
* 整个二进制里 `AV*` 只有 `AVAssetWriter` 系列(视频导出),**没有第二个
  AVCaptureSession**。图像来自 ARSession。
* 高清静照按**固定间隔**触发:`ScanConfigurationProto.largeImageInterval`,
  每帧带 `isLargeImage: Bool`,高清 JPEG 落 `imgl/`、低清落 `img/`。
  **是节奏驱动,不是启发式触发** —— 与我们的位移/角度判据方向相反。

**逆向作者的一手旁注(与我们的标定线相关):** 内参**逐帧变化**(主点 px/py 与焦距 f),
归因于自动对焦、可能还有 OIS;两轴共用同一焦距。位姿约定是 OpenCV/COLMAP
(+X 右 +Y 下 +Z 视线),camera-to-world,四元数标量在后。

**证据边界(逆向作者自己声明):** `resymbol` 恢复的是**类型**元数据不是调用点。
`captureHighResolutionFrame` 是 `ARSession` 的方法,本来就不会出现在这里,
**它的缺席不证明任何事**。`AVCapture*` 的缺席更强(受管的 capture session 通常需要
存储属性),但仍是推断。

---

## 三、我们那个回归的机制:Apple 有完整因果链

四段全部回源逐字核过。

**① WWDC22 Session 10126 "Discover ARKit 6"**
(`https://developer.apple.com/videos/play/wwdc2022/10126/`)

> "ARKit lets you request the capture of single photos on demand **in the background,
> while the video stream is running uninterrupted**."

> "**Do not hold on to an ARFrame for too long.** This might prevent the system from
> freeing up memory, which might further stop ARKit from surfacing newer frames to you.
> This will become visible through **frame drops** in your rendering. Ultimately,
> **the ARCamera's tracking state might fall back to limited.** Check for console
> warnings to make sure you do not retain too many images at any given time."

> "Also keep in mind our best practices on **image retention** that I mentioned earlier,
> **especially since these images use the full resolution of the image sensor.**"

**② Apple Frameworks/Graphics Engineer,Developer Forums thread 695404**
(`https://developer.apple.com/forums/thread/695404`),逐字:

> "The camera delivery (AVFoundation) has a pool of CVPixelBuffers that it uses.
> When a client retains that pixelBuffer for longer periods, **AVFoundation's pool of
> available buffers gets empty and CoreMedia starts dropping camera frames** and the
> screen will appear frozen. ARKit added a mechanism that keeps track of the frames
> that its delegate is consuming. **If that count > 10, we're emitting some warnings.
> Depending on the device the camera will start dropping frames at 15 to 20 retained
> frames. Usually the reason for this is that the app's main thread (or the queue that
> processes the delegate) is blocked**, so this indicates a performance problem."

**③ Apple DTS Engineer,thread 110046**
(`https://developer.apple.com/forums/thread/110046`),逐字:

> "If you drop frames, there is a good chance that your **ARSession will be interrupted,
> which generally causes objects to start drifting** until the session is able to recover."

**④ Apple TN2445**(`https://developer.apple.com/library/archive/technotes/tn2445/_index.html`),
`kCMSampleBufferDroppedFrameReason_OutOfBuffers` 的官方处方:

> "**This condition is typically caused by the client holding onto buffers for too long,
> and can be alleviated by returning buffers to the provider.** … consider **copying the
> data into a new buffer** and then calling `CFRelease` on the sample buffer."

### 连起来

```
持有 ARFrame / capturedImage,或阻塞主线程
  → AVFoundation 相机交付池耗空(>10 帧告警,15–20 帧开始丢帧)
  → CoreMedia 丢帧
  → tracking state 降到 limited
  → ARSession 被打断 → 物体开始漂移直到恢复
```

**这条链与我们观察到的每一个症状字面对应**:`limited_initializing`、丢失、
`arkit_anchor_delta_v1` 的 0.24–0.37m / 20–33° 修正。
build 74 按 ① 拿掉 ARFrame 持有后,漂移 0.004→0.000、丢失 5.3/分→0.39/分。

### 旁路方案:Apple 明说不支持

* thread 765497,DTS Engineer 对替换快门声:**"There is no supported way to achieve this"**;
  替代方案只有"从 ARSessionDelegate 的视频流里抓帧,但质量显著更低"。
* thread 769604,并行 `AVCaptureMultiCamSession` / 独立 AVCaptureSession 与 ARKit 共存:
  实测 OSStatus **-16409**、副路"一秒内停跑";Apple 回复同样是 "There is no supported
  way to do this"。
* thread 805839:ARKit 内部那个 `AVCapturePhotoOutput` **没有公开 API 可配置**。

**所以"另开一条 AVCapture 路"这个选项对我们关闭。**
(Apple 自家 Object Capture 示例走 `AVCapturePhotoOutput` + CoreMotion,但那个示例
**根本不跑 ARKit**,不构成反例。)

---

## 四、我们自己的数据:杀掉一个假设,也削弱一个自己的说法

机制 agent 提出:基线的 33ms ≈ 30Hz 一帧,若基线没设 non-binned 的
`recommendedVideoFormatForHighResolutionFrameCapturing` 格式,可能根本没走 12MP 静照路径。

**用 `highres_capture` 遥测里的 `image_w/image_h` 当场证伪 —— 所有构建交付的都是真
4032×3024。** 假设死亡。

但同一份数据也削弱了我们自己此前的说法。`request_to_capture_dt` 按构建的中位数:

```
build-68  33ms     build-72  183ms
build-69 117ms     build-73  225ms
build-70 133ms     build-74  217ms
build-71  50ms     build-75/76  33ms
```

**不是"build 68 起干净地慢了 6.6 倍"** —— 68 是 33ms、71 只有 50ms,噪声很大。
而且 build-76 会话里出现过**负值**(−0.0667s)。原因:该量算的是
`高分帧.timestamp − 请求帧.timestamp`,而高分帧的 timestamp 是**曝光时刻**不是交付时刻,
可以早于请求。**这把尺子的语义可疑,不应再当硬判据单独使用。**

要分段归因,应同时记 `t_request` / `t_frame.timestamp` / `t_completion_called` 三个点。

---

## 五、专利与学术:该交互没有被专利化

最接近的四件都只做**角度桶覆盖率**或**前瞻引导**,没有一件主张"在每张已拍照片的
6DoF 位姿上放标记":

| 专利 | 权利人 | 命中什么 |
|---|---|---|
| [US9998655B2](https://patents.google.com/patent/US9998655B2/en) | Qualcomm | 虚拟球面按"图像采集角度区间"分块着色 |
| [US11917289B2](https://patents.google.com/patent/US11917289B2/en) | Xerox | 测地多面体各面着色的覆盖热图 + "Go Here" 路点 |
| [US10488195](https://www.freepatentsonline.com/10488195.html) | Microsoft | 逐张存位姿为元数据 + 引导到**期望**位姿;claim 1 未主张渲染已拍位姿 |
| [US12477229B2](https://patents.google.com/patent/US12477229B2/en) | Hover | 明确是**前瞻**标记(reticle 对齐),随相机移动消失 |

Google Patents 按权利人检索 **Capturing Reality / Niantic / Polycam / Luma / KIRI 命中数为 0**。

论文侧([Hoppe BMVC 2012](https://www.tugraz.at/fileadmin/user_upload/Institute/ICG/Images/team_fraundorfer/personal_pages/markus_rumpler/bmvc_2012_hoppe.pdf)、
[IntelliCap arXiv:2508.13043](https://arxiv.org/abs/2508.13043)、
[Augmented Photogrammetry UIST'23](https://dl.acm.org/doi/10.1145/3586182.3616638))
全是球面代理/覆盖率引导,**无一涉及高清抓拍与追踪管线的相互干扰**。

---

## 六、明确的死路(以后不要重查)

* RealityScan iOS 二进制:无拆包、无符号、无框架列表、无 entitlements、无 trace。
  AppGoblin 的 iOS 记录明写 "App not yet scanned for SDKs"。
* Epic / Capturing Reality 工程师关于 AR 引导实现的任何技术表述:零。
  1.7/1.8/1.9 release notes 100% 是用户可见功能。
* `github.com/EpicGames/RealityScan` 是误导性命中 —— 实为 pano2views 网页工具。
* 非英语八语种(日/韩/俄/德/法/西/葡/意):**零**篇提到 `captureHighResolutionFrame`
  这个符号(除一篇 Habr 转述 WWDC22);对这批 app 的覆盖 100% 是消费级横评。
* `captureHighResolutionFrame` 的公开延迟基准:不存在。
* 「每张照片加一个 ARAnchor 的代价」:Apple 只说 anchor 会让 ARKit 在该区域**额外做
  优化工作**(非零成本的官方承认),但**无任何量级或 benchmark**,第三方也没有。
  现有证据既不支持把它列为嫌疑人,也不能排除它。

**方法论提醒(某路 agent 自己核出来的):不要把本地化 URL 当本地语言证据。**
Microsoft Learn 的 ja-jp `ARFrame` 页是机翻且关键段落根本没收录;de-de 页正文
实际是未翻译的英文(`locale: en-us`)。

---

## 七、还没拿到、但 Apple 指定了的那条判据

WWDC22 的原话是 **"Check for console warnings"**,指的就是:

```
ARSessionDelegate is retaining X ARFrames. This can lead to future camera frames being dropped
```

阈值是 Apple 给的硬数:**>10 告警,15–20 开始丢帧**。

我们至今没读到它 —— 它走 os_log,`log collect` 需要 root。取法:

```bash
sudo log collect --device-name "<设备名>" --last 30m --output ~/Desktop/dev.logarchive
```

**这是目前唯一能直接证实或证伪"持有导致丢帧"的官方观测量,而且不需要改一行代码。**

---

## 八、结论对我们意味着什么

1. **「复刻 RealityScan 的即时卡片」这条路关闭** —— 不是查不动,是大概率没有可复刻的
   东西:那家同行的 AR 引导是可选的、与相机控制互斥的附加层,他们没面对这个约束。
2. **唯一被证实存在的同类做法是 Scaniverse 的整套架构**:AR 层完全自绘(Metal)、
   ARSession 只做跟踪、实时路径上不往场景图塞节点、高清静照按固定节奏拍。
   这是一个架构选择,不是一刀。
3. **动手前的前置条件**:先拿到 `retaining N ARFrames` 的读数。没有它,任何关于
   "持有是不是元凶"的说法都还是故事。
4. **一条已确立的设计约束**(不论将来怎么做):绝不在回调之外持有 ARFrame 或它的
   `capturedImage`;要用像素就按 TN2445 的官方处方**先拷贝、立刻把缓冲还回去**。

相关记忆:`project-pocketworld-0827-rollback-baseline`、
`feedback-capture-path-ms-budget-is-the-ship-gate`、`feedback-correlation-is-not-mechanism`、
`feedback-replicate-official-before-inventing`(09-01 补充:复刻不变量必须连前提一起复刻)。
