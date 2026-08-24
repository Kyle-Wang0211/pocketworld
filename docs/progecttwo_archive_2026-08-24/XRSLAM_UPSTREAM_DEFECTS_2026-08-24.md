# XRSLAM 上游既有缺陷台账(2026-08-24)

来源:一次全球多语言穷举调研 —— 52 个 agent / 469 万 token / 1305 次工具调用 /
297 条声明 / 118 条死胡同 / 七种语言。

**本文件只记账,不动代码。** 决策(2026-08-24):先把相机-IMU 外参修复在
640×480 上验证通过、拿到 known-good 基线,再逐条评估这些缺陷。现在动代码会让
「这次为什么不 TRACKING」变成多变量问题。

---

## 0. 调查本身的可信度边界(先看这个)

写在最前面,因为下面每一条的分量都取决于它。

| 项 | 实情 |
|---|---|
| 对抗验证覆盖率 | **270 条声明只验了 40 条**(workflow 脚本里 `.slice(0, 40)` 静默截断)。17 条存活、23 条被推翻,**其余 230 条只经过一次搜索,没有被质疑过**。 |
| Q4(量产设备跟踪相机分辨率) | **有效证据 0 条**。每条有数字的都被自己作废(Guttag 403、HoloLens 2 的表没提取、ARCore 没取到逐字引文、XR2 只有传感器型号)。 |
| 语言覆盖 | 法语、韩语实为零样本。Reddit / HN / X / 知乎 /p/ / 博客园 / Naver 全部被封或不可达 —— 报告里写「社区没有人…」的地方,实为**取不到**而非**不存在**。 |
| 未走的路 | **中文学位论文库(CNKI / 万方)完全没查**。「分辨率消融」这种没人愿意单独发论文的对比,最可能的载体恰恰是中文硕士论文。 |
| 学术检索 | openalex / semantic_scholar / arxiv 三个源全失效,只剩 crossref + WebSearch。所以「全球不存在分辨率消融」这个**全称否定没有一次系统性文献检索支撑**,应读作「七个主流检索面穷举后没有」。 |

---

## 1. 已在我们这边处理掉的

| # | 缺陷 | 我们的处置 |
|---|---|---|
| A | `XRSLAMImage` 没有 width/height,尺寸从 YAML 取 ⇒ 改采集分辨率不改 yaml 会**静默按错尺寸解释 buffer** | 已给结构体补 width/height(sizeof 40→48),ASAN 实测过越界 76800 字节 |
| B | `iPhone 16e.yaml` 与 `iPhone 14 Pro.yaml` **逐字节相同**(blob SHA `b3b2e8724c5e80a0b52e0f6d33b12e3be8a51012`,1868 字节),外部贡献者夹带进一个 iOS 漂移修复 PR,描述只有 "add sensor config for iPhone 16e",**无任何 16e 实测证据** | 已在 `kIosCameraImuPbcCopied` 里标记;`forIosMachine` 改成三态 provenance,16e 落 `placeholder` 而非 `deviceApi` |
| C | 未匹配机型时 demo app **静默 fail-open**(裸 `return;` 在 id 返回型 ObjC initializer 里,`XRSLAMCreate` 从未被调用,调用方不做 nil 检查),大部分 iPhone 15/16/17 会解析成 `?unrecognized?` | 我们不用 demo app 的机型查表路径。`XRSLAMCreate` 吃配置**字符串**,配置由 Dart 运行时生成;查不到机型走中位数回退,**旋转仍是正确的那个** |
| D | 降采样倍数两边各写一份常量的风险 | 唯一真源 = `PwVioSlamFeeder.kVioDownsampleFactor`;Dart 通过 `vioDownsampleFactor()` 取,取不到或不整除就**不启动 SLAM**(fail-closed) |
| E | 🔴 **加速度计符号与上游相反** | 上游 `Motion.swift:3` `GRAVITY_NOMINAL = **-9.80665**`,我们写的是 `+9.80665`。iOS 约定(屏幕朝上平放 gravity=(0,0,-1),指向"下")与 VIO/EuRoC 约定(静止时读**指向"上"**的比力,实测 V1_01 前 200 静止样本 \|a\|=9.778、方向 (0.926,0.012,-0.377) 即传感器系的"上")相反。已改成 -9.80665,并新增 `accMeanX/Y/Z` 诊断 —— **符号错靠模长查不出来(模长对符号不变),必须看方向**:静止竖持应 ≈(0,+9.81,0) |
| F | 陀螺符号 | 上游 `record.rotationRate` 原样传不翻符号 —— **我们本来就一致**,已核对 |
| G | 🔴 **上游 RANSAC 空 mask ⇒ 真机 SIGSEGV**(见 §1.6) | 已修 `xrslam/src/xrslam/utility/ransac.h`,配 6 项回归测试 + 负对照 |

---

## 1.5 ⚠️ 尚未消除的偏离(单变量纪律:先只改符号)

**数据源不同:上游用裸 `startAccelerometerUpdates` / `startGyroUpdates`
(CMAccelerometerData/CMGyroData,加速度以 G 为单位),我们用 `CMDeviceMotion`
的 `gravity + userAcceleration`。**

Apple 文档说两者相等,但 `CMDeviceMotion` 是**融合滤波的输出**,有滞后与可能的
衰减;上游是刻意用裸传感器的。两边都显式设 100 Hz(上游
`updateInterval = 0.01`,我们 `deviceMotionUpdateInterval = 1/100`),但我们实测
折算约 74 Hz。

⇒ **若符号改完仍不初始化,下一步就是换裸传感器。** 现在不一起改,是为了
保持单变量(见 [[feedback_control_variables_and_verify_existing]])。

---

## 1.6 🔴 上游 RANSAC bug ⇒ 真机 SIGSEGV(已修 + 已验)

**现场**:iPhone 14 Pro,`Runner-2026-08-24-011355.ips`,
`EXC_BAD_ACCESS / SIGSEGV`,`KERN_INVALID_ADDRESS at 0x0`,
故障线程 42 = FeatureTracker worker:

```
0 xrslam_0_5_0::Frame::track_keypoints(Frame*, Config*)  +2768
1 xrslam_0_5_0::FeatureTracker::work(unique_lock<mutex>&) +1708
2 xrslam_0_5_0::Worker::worker_loop()                     +184
```

**定位**:`atos` 拿不到行号(vendored 静态库无完整调试信息),改用反汇编。
崩溃指令是 `ldrb w11, [x11, x10]` —— **不是虚函数调用**,是对 `vector<char>`
的下标读。上下文逐条对上 `Frame::track_keypoints` 里:

```cpp
for (size_t i = 0; i < status.size(); ++i)
    if (!mask[i]) status[i] = 0;
```

```asm
c6bc:  ldp x9, x8, [sp,#0x1c8]   ← status.begin / status.end
c6e0:  ldr x11, [sp,#0x1b0]      ← mask.data()   = 0
c6e4:  ldrb w11, [x11, x10]      ← mask[i]       💥
c6ec:  strb wzr, [x9, x10]       ← status[i] = 0
```

**根因**(`xrslam/src/xrslam/utility/ransac.h`,**上游原文,我们未改过** ——
`git log` 只有 `031d812 add IMU-PARSAC` 与 `68d335c first commit`):

```cpp
inlier_count = 0;
...
if (current_inlier_count > inlier_count) {   // 严格大于
    inlier_mask.swap(current_inlier_mask);   // ← 唯一赋值点
}
```

每一次迭代都找到 **0 个内点**时,`0 > 0` 恒假 ⇒ `inlier_mask` 一次都不被赋值
⇒ 保持默认构造的空 vector(`data() == nullptr`)⇒ 调用方 swap 到空的 ⇒ 用
`status.size()` 索引即从地址 0 取字节。
同函数的 `size < ModelDoF` 早退分支**本来就正确**填了 `(size, 0)` —— 只有主路径漏了。

触发条件不是理论风险:对应关系差到没有任何 5 点本质矩阵模型能解释哪怕一个点
(运动模糊、场景突变、跟踪几乎全丢)时就会发生。

**修法**:把不变式提到函数开头 —— **返回时 `inlier_mask.size()` 恒等于 `size`**,
与上游自己在早退分支的处理一致。「找不到模型」== 「零内点」,语义正确,且不改变
任何原本能正常返回的调用结果(有内点时下面的 swap 会覆盖初值)。

**验证**:`pw_tools/tests/ransac_empty_mask_test.cpp`(纯头文件,不链任何库,
秒级编译,带 ASAN)。
- 修复后 **6/6 通过**
- **负对照**:临时还原成上游原状后运行 →
  `AddressSanitizer: SEGV on unknown address 0x000000000000`,
  **`x[11] = 0x0000000000000000`** —— 与真机崩溃报告**同一个寄存器、同一个地址**。
- 变异已无条件还原(见 [[feedback_tool_blindspot_masquerades_as_finding]] 第 10 条)。

⚠️ 这条值得报给上游 —— 是可复现的空指针崩溃,且修复是 4 行。

---

## 2. 待评估(按对我们的威胁排序)

### 2.1 🔴 卷帘快门与相机-IMU 时间偏移在**任何平台**都不建模

- `xrslam-extra/src/xrslam/extra/yaml_config.cpp` 的 loader **根本不解析
  `camera_readout_time`**。
- 被解析进 `Config::camera_time_offset()` 的 `time_offset`,除 `config.cpp` 里
  一处调试打印外**没有任何消费者**。
- ⚠️ 推论:把 xrapi 的非零值(Mate30Pro 0.019337 / 0.02;P40 0.0123256105376 /
  0.00642703132168)抄进 iPhone yaml 是**字面意义上的 no-op**。这不是配置问题,
  必须改代码。

**为什么这条排第一:** 我们真机实测 `maxAbsCamImuDelta = 0.554 s`,
`domainMismatchActive = 0`(不是时钟域问题)。手机全是卷帘。这一条与我们**已经
观测到的异常直接对应**,很可能是继外参之后的第二个真阻断。

相关:`state.h` 的 `ES_SIZE == 15`,**没有 td 状态**去吸收这个差。扩展 ES_SIZE 的
scoping 报告已存在:`progecttwo/HANDOFF_td_state_extension.md`(34.9 KB)。

### 2.2 🔴 IMU 噪声参数是 EuRoC 的数字,不是任何一款 iPhone 的实测

- 18 份 iPhone yaml 与 6 份华为 Android yaml **逐字节相同**地带着
  `gyroscope_noise_density: 4.e-8`、`accelerometer_noise_density: 4.e-6`、
  `cov_g: 2.8791302399999997e-08`、`cov_a: 4.0e-6`、
  `cov_bg: 3.7608844899999997e-10`、`cov_ba: 9.0e-6`。
- 这组 cov 值正是 **EuRoC 数据集**的数字(同见 zju3dv/PVIO 的
  `config/euroc.yaml`)。
- 即**「逐设备 IMU 标定」根本不存在**。维护者 wangnancpp 只证实过标定频率:
  「是的,我们是在100Hz下标定的,iOS获取到的IMU最大帧率也是100Hz」(issue #18)。
- issue #50「imu calibration」2024-08-28 至今 open,两年零维护者回复,唯一回复是
  社区指向 `ori-drs/allan_variance_ros`。

**对我们的意义:** 我们本来就用 `ImuNoise.sharedMems` 共享默认值并标了
provenance —— 现在知道**上游也一样**,这条不是我们独有的缺口。但也意味着
「用上游的值」并不比「用我们自己的值」更有依据。

### 2.3 初始化后的重投影误差剔除是死代码

```cpp
map->prune_tracks([](const Track *track) {
    return !track->tag(TT_VALID) || track->landmark.reprojection_error > 3.0;
});
```
全树 grep `.reprojection_error` 只有这一处命中;该字段除了在 `state.h:43` 被
`reprojection_error = 0;` 初始化外**从未被写过** ⇒ 恒为 0 ⇒ **这道闸从不触发**。

`xrslam/src/xrslam/core/initializer.cpp#L376`

### 2.4 出货门限链(仅记录,便于日后调参时知道动的是什么)

| 门限 | 值 | 出处 |
|---|---|---|
| 关键帧数 / 步长 | 8 / 5 帧 | `config.cpp:38,40` |
| 两初始帧共同 track | ≥ **50** | `config.cpp:42`, `initializer.cpp:191` |
| 平均视差 | ≥ **10 px** | `config.cpp:44`, `initializer.cpp:~186-195` |
| 三角化点 | ≥ **20** | C++ 硬编码默认是 50,但两份出货 yaml 都写 `min_triangulation: 20` ⇒ 实跑 20 |
| 最终 landmark | ≥ **30** | `config.cpp:48`, `initializer.cpp:570` |

已按 fx 归一化、**分辨率安全**的只有两个(单源,且含一步未申报的推理跳跃 ——
除以 fx 只证明单位归一化,不证明阈值语义在新分辨率下仍正确):
- 单应 RANSAC:`find_homography_matrix(..., 0.7 / init_frame_i->K(0,0), ...)`
- 关键点量测噪声:`sqrt_inv_cov = K.block<2,2>(0,0) / sqrt(keypoint_noise_cov)`

### 2.5 无自包含的重定位 / 回环

`xrslam-localization` 是一个连到**外部 XRLocalization 服务器**、针对**预建 SfM
地图**的 HTTP 客户端,默认关闭。维护者 wangnancpp(issue #11)原话:当时版本
"has only the ability of odometry. So it can't recover tracking by relocalization"。

⚠️ 注意:同 issue 里两名独立用户报告的是**放置的 AR 模型在左右移动后逐渐缩小
消失**,维护者**从未说过缩小是由缺少重定位引起的**;线程里唯一被提出的机理是
里程计内部的零速/尺度漂移(wangni-bupt 提议 ZUPT)。

### 2.6 iOS demo 的 AR 渲染 FOV 全机型硬编码为 iPhone XS 内参

```
fov = 360.0/3.1415926535897 * atan2(314.618580309, 483.302341374)
```
这两个常量正是 `iPhone XS.yaml` 的 cu 和 fu。我们不用 demo 的渲染路径,仅记录。

### 2.7 xrapi(Android)侧的两处污染

- `slam_params.yaml` 的 `p_bo` 与 xrslam 的 `iPhone 13 Pro.yaml` 的 p_bc
  **逐字节相同** —— 一份 iPhone 外参被当成 Android 的全局输出变换在用。
- `default/default/device_params.yaml` 的 `T_BS` 有 YAML 语法缺陷(双逗号
  `0.0379110562259,,`)。
- ⚠️ **Android 目标从未存在过**:xrslam 仓库只有 xrslam-pc / xrslam-ios /
  xrslam-ros。issue #29「支持Android平台吗」2023-04-07 开了 39 分钟后零回复关闭。

---

## 3. 被这次调查推翻的说法(避免日后有人再捡回来)

| 说法 | 实情 |
|---|---|
| 🔴 「Delmerico & Scaramuzza ICRA 2018 做过 960×540 四分之一分辨率的 VIO 消融」 | **误引。** 该 PDF 全文 grep `resolution\|downsampl\|quarter\|960\|540` → **零命中**,论文根本没有分辨率实验。真链条:Joshi et al. ICRA 2022 转述 TUM-VI,而 TUM-VI 自己也没做过该对比(Table III/IV 全 512×512)。**三层转述,源头是空的。** |
| 「维护者说 main 在 iOS 上是坏的,应回退 632b72d」 | 已过期六个月。PR #70(2026-02-10 合入)同时修好 iOS 26.1/Xcode 26.1 构建与 632b72d 之后的**外参双重施加**回归。今天回退 = 白扔六个月修复。 |
| 「iOS 崩溃是 32BGRA(4通道)与 channels() 返回 3 的不匹配」 | 两半都假。`processBuffer` 做过 `COLOR_BGRA2GRAY`,是**单通道**;打印出的 3 是 `XRSLAMImage image;` **未初始化栈变量的垃圾值**。`channel = 1` 是正确值。 |
| 「OpenXRLab Android 栈用 640×480 专用 SLAM 流与 1280×960 显示流分开」 | **死代码。** `mSLAMWidth/mSLAMHeight` 全仓库从未被赋值;双流路径被不存在的 manifest 标志、不存在的 CameraFactory case、以及 `sensor_jni.cpp:659` 硬编码的 `bool isSupportDoubleStream = false;` 三重封死。 |
| 「同一实验室刻意让 Android 用更低分辨率(512×384 vs 640×480)」 | 数字真,推论假。xrapi 没有 iOS 目标、xrslam 没有 Android 目标 —— 两个各自单平台的独立产品,**从没做过跨平台的分辨率选择**。 |
| 「RD-VIO 论文假设外参是单位阵,所以逐机型 p_bc 不重要」 | 被作者自己的代码推翻。同一句话也假设了「constant camera intrinsic matrix K」—— 按同样逻辑就得出「逐机型内参不重要」。实现里 `detail.cpp:110-113` 把 `q_cs/p_cs` 灌进每一帧并进入残差与解析雅可比。**作者为此维护了 18 机型的表。** |
| 「XRSLAM 是商汤 SenseSLAM 去授权后的开源版,有法务风险」 | 反了。Apache-2.0,由商汤自家 OpenXRLab 发布。**所有权人主动授权 ≠ 泄露。** |
| 「issue #35 证明 XRSLAM 即使正确 Kalibr 标定也会严重漂移」 | 该 issue **完全不涉及 Kalibr**;报告者贴的 IMU 值是 Kalibr/VINS 占位默认值且与同文件 cov 块自相矛盾。它只能证明维护者两年零回复。 |
| 「逐机型标定其实经常只是复制粘贴」 | **18 份里只有 1 份是**(16e)。其余 17 份内参与 p_bc 都精确到 6 位以上有效数字且彼此不同(14 Pro 448.968 vs 14 Pro Max 449.702)。**结论要两头收窄。** |
| 「XRSLAM 设计上明确拒绝了 stereo」 | 被拒的只有**头显多相机**。关于通用 stereo-inertial(RealSense T265/D435i)的两次追问**从未被回复** —— 不要把「未表态」读成「已拒绝」。 |

---

## 4. 真空白(穷举后确认无人回答过)

1. **图像分辨率 vs VIO 精度的消融实验 —— 全球不存在。**(边界见 §0)
2. **算法层像素单位参数随分辨率缩放的规则 —— 全球不存在。** 最接近的只有
   VINS-Mono 作者 Tong Qin 一句 *"Some parameters should change will focal
   length"*(原文含笔误)和 OpenVINS 配置里 `min_px_dist` 的注释
   *"(dependent on resolution)"*。**缩放 vs 不缩放的对照实验也不存在。**
3. **没有任何维护者说过 XRSLAM 为什么选 640×480,或它支持哪些分辨率。**
   仓库全部 69 个 issue/PR 里**没有一条**关于改相机分辨率;Discussions 关闭。
4. **没有任何第三方在真机上跑 XRSLAM/RD-VIO 并公布数字。** 64 篇引用论文中只有
   1 篇真跑过且不在手机上;中/日/韩社区零篇独立实测;中文全部命中都是同一篇
   宣传稿的四处转载(一个来源、四个 URL)。
5. **ARKit 相机坐标系与 CoreMotion 设备坐标系之间的常量旋转 —— 没有任何来源
   发布过数值。** Apple 分别文档化了两个坐标系,**从未文档化它们的复合**。
   ⇒ 我们用的 `q_bc = [-0.7071068, 0.7071068, 0, 0]` 来自上游 18/18 一致的实证,
   这**是全网唯一的公开来源**。
6. **同机型个体间的外参差异(mm / 度)—— 没有任何公开量化。** 只有 ARCore
   工程师 'inio' 的定性说法:Google 跨多台标定后取平均。
7. **相机-IMU 外参误差 → 尺度误差百分比的换算 —— 没有论文做过。**
8. **「单目 VI 尺度差几千倍」这个量级 —— 全球零记载。** 有记载的最大量级是
   几十个百分点(OpenVINS #113 的 -40%/+60%)。⇒ 我们 EuRoC 半分辨率实测的
   s≈0.0002 **是一个全球没人记录过的现象**,不要指望能查到解释。
9. **XRSLAM 在 640×480 以外分辨率的官方配置 —— 不存在。** issue #57 直接向作者
   索要 ADVIO(1280×720)配置,维护者答「我们后续并没有维护ADVIO数据集的相关
   部分,因此现在没有可以直接用的配置文件」。**不要指望能找到。**

---

## 5. 检索受阻但可能存在答案的(换网络/换路径值得重试)

| 目标 | 阻断 | 价值 |
|---|---|---|
| 章国锋组中文综述《基于单目视觉惯性的同步定位与地图构建方法综述》(cjig.cn) | Socket closed ×2 | 🔴 最高价值一方中文源 |
| zjucvg.net eval-vislam 评测页 / cad.zju.edu.cn 的 VRIH 2019 AR VI-SLAM benchmark | curl HTTP 000 / 超时 | 🔴 最可能含该组逐算法 **E_scale** 数字 |
| Tomáš Krejčí《iPhone Calibration — Camera, IMU and Kalibr》 | medium 403 | 🔴 很可能是全网最好的一篇 iPhone Kalibr 外参实录 |
| HoloLens 2 跟踪相机分辨率(arXiv 2008.11239 Table 1) | 论文可达,**数字未提取** | 高 —— 唯一有一方数字的出货头显 |
| ARCore 640×480 运动跟踪流的一方原文(Java camera-sharing / SharedCamera 页) | 位置已定位,未取逐字引文 | 高 |
| Huang & Liu ICRA 2018《Online Initialization and Automatic Camera-IMU Extrinsic Calibration》 | 下载两次超时 | 中高 |
| CNKI / 万方 学位论文 | **未尝试** | 🔴 分辨率消融最可能的载体 |

---

## 6. 检索工具备忘(下一位调查者直接用)

- `blog.csdn.net`:WebFetch 403、curl 000。**可用办法:URL 前缀
  `https://r.jina.ai/` 再 WebFetch**(偶发 521,重试)。`cloud.tencent.com` 直连可用。
- `api.github.com` 未认证立刻限流;**本机 `gh` CLI 已认证**,用
  `gh api repos/OWNER/REPO/issues/N/comments --paginate`。
  ⚠️ **WebFetch 抓 GitHub issue 页面会静默丢掉全部评论** —— 必须走 API。
- `arxiv.org/pdf/<id>` 对 WebFetch 返回二进制不可解析,用 `arxiv.org/html/<id>v<n>`。
- ⚠️ **WebFetch 对表格的摘要不可靠且会自相矛盾**(同一篇论文两次抓取给出相反的
  行归属)。**表格数字必须 curl + 本地剥标签复核。**
- `mcp__research-scholarly__scholarly_search`:openalex 与 semantic_scholar 均
  返回 `api_key_not_configured`,arxiv `request_failed`,**只有 crossref 可用**。
  引用关系改用
  `api.semanticscholar.org/graph/v1/paper/DOI:.../citations` 直接 curl。
- `developer.apple.com/documentation/*` 是 JS 渲染,WebFetch 只拿到空壳;
  Apple 事实要从 `developer.apple.com/forums` 取。
- Homebrew python3.14 的 numpy 是坏壳(`__file__` 为 None),用 `/usr/bin/python3`。
