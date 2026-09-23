<!-- 来源:专利事实搜集 agent 最终报告,原样落盘(2026-09-23)。本文件是事实搜集,不是法律意见。
     主会话复核(Google Patents 浏览器渲染,2026-09-23):
     · US9159133B2 claim 1 与本报告逐字一致;Status Active;Adjusted expiration 2033-12-07;
       MAFP 4th year + 8th year(LARGE ENTITY)已缴 ⇒ 本报告 §3.1「法律状态/年费 NOT RETRIEVED」已补上。
     · 同族 Worldwide = US EP JP KR WO CN;中国同族 CN201380055388.9 → CN104737205B(授权 2017-08-25),
       **CF01 因未缴年费终止,终止日 2020-10-08(公告 2021-09-17)** —— 单一来源,待 CNIPA 复核。
       欧洲 EP2915139B1(授权 2020-04-22)、JP2015540680、KR1020157014270 状态未核。 -->

# 单目 VIO 专利 FTO 事实搜集报告

> **这是事实搜集,不是法律意见。** 下文只陈述检索到的记录事实与权项原文,不作侵权/有效性判断。权项解释(claim construction)必须由律师做。

---

## 1. 一句话结论

| 特性 | 风险 | 依据(哪条权项的哪个限定语) |
|---|---|---|
| **(A) 每 N 秒重优化 {metric scale s, 2-DoF gravity},其余地图固定** | **中** | 唯一实质对口的是 **Qualcomm US 9,159,133**(`ADAPTIVE SCALE AND/OR GRAVITY ESTIMATION`,优先权 2012-11-05)。独立权项 1/18/34/40 的核心要素就是 `"computing a difference between the image-based pose and the inertia-based pose; and forming at least one of a second estimation of the gravity vector or a second estimation of the scaling factor based on the difference"`。**致命点:它没有任何形态限定——前序是 `"A method for estimating in a mobile device"`,手持手机正落在里面。**最可能的设计回避点是 `"between a target and a first position of a camera … wherein the first image contains the target"`(每条独立权项都要求两帧都含同一个 **target**)以及"两种位姿求差"这一构造。 |
| **(B) 重力方向作为滑窗内的活估计变量** | **低** | 在已检索范围内,**没有找到任何在效美国专利、其独立权项以「在视觉惯性状态估计中估计/细化重力方向」为要素**。最接近的 STMicro US 12,164,705 独立权项确实 `"estimates a gravity vector"`,但**整条权项没有相机、没有图像**(纯陀螺+加计),且被锁死在特定 versor/correction-factor 公式上。 |
| **US 11,328,475 B2(Magic Leap)本身** | **对 (A)(B) 都是低/不相关** | **三条独立权项(1、10、19)里 `gravity` 一次都没出现。**标题写重力,权项写的是 `"reducing a weight associated with the reprojection error"`。而且三条**全部**锁死在 `"a wearable head device"` + `"a display of the wearable head device"` + `"presenting … a view reflecting the determined state"`。对手持手机产品,这是决定性的形态限定。 |

**一个独立的事实:US 11,328,475 B2 的全部 17 页说明书正文 OCR 后,`scale` 一词出现 0 次**(`gravity` 出现 42 次作为语料健康度对照;命中的 5 处 `scaling` 全是"权重缩放")。该专利不含任何米制尺度的公开,这对"后续 continuation 能否转向 scale"是相关事实。

---

## 2. US 11,328,475 B2 完整著录项

### 2.1 著录项(来源:USPTO 官方授权 PDF 首页,本地 OCR)

| 项 | 值 |
|---|---|
| 标题 | **GRAVITY ESTIMATION AND BUNDLE ADJUSTMENT FOR VISUAL-INERTIAL ODOMETRY** |
| 申请号 | **17/072,825**(注意:**不是** 17/070,904) |
| 申请日 | **Oct. 16, 2020** |
| 最早优先权 | **临时申请 62/923,317,2019-10-18** |
| 第二临时申请 | 63/076,251,2020-09-09 |
| 预授权公开 | US 2021/0118218 A1,2021-04-22 |
| 授权日 | **May 10, 2022** |
| 申请人/受让人(专利面) | **Magic Leap, Inc., Plantation, FL (US)**((71) 与 (73) 同) |
| PTA | **0 days**(154(b)) |
| 主审查员 | **Chong Wu** |
| 代理所 | Morrison & Foerster LLP |
| 规模 | **20 项权利要求(独立权项 3 条:1、10、19),17 幅图** |
| 发明人(13 人) | Yu-Hsiang Huang; Evan Gregory Levine; Igor Napolskikh; Dominik Michael Kasper; Manel Quim Sanchez Nicuesa; Sergiu Sima; Benjamin Langmann; Ashwin Swaminathan; Martin Georg Zahnert; Blazej Marek Czuprynski; Joao Antonio Pereira Faro; Christoph Tobler; Omid Ghasemalizadeh |
| PCT | **WO 2021/077024 A1**(PCT/US20/56163,2020-10-16) |

### 2.2 转让记录(USPTO Assignment,经 Google Patents Legal Events 转录)

| # | 记录日 | 转让类型 | 转让人 | 受让人 | Reel/Frame |
|---|---|---|---|---|---|
| 1 | 2022-04-22 | ASSIGNMENT OF ASSIGNORS INTEREST(签署 2020-01-27 → 2022-04-05) | 13 位发明人 | **MAGIC LEAP, INC.** | **059686/0472** |
| 2 | 2022-05-24(生效 2022-05-04) | **SECURITY INTEREST** | MOLECULAR IMPRINTS, INC.; MENTOR ACQUISITION ONE, LLC; MAGIC LEAP, INC. | **CITIBANK, N.A., AS COLLATERAL AGENT** | **060338/0665** |

- **未见 JP Morgan Chase 对本专利的记录**(2019 年那笔融资早于本案 2020-10 申请日)。
- **未见 Citibank 担保权益的 RELEASE 记录**;该担保权益看起来仍在册。
- 同一份发明人转让在子案 18/439,653 上于 2024-03-05 重新记录(reel/frame 066654/0297)。

> ⚠️ **USPTO 直连查询 NOT RETRIEVED。**`assignment-api.uspto.gov` / `assignment.uspto.gov` / `ped.uspto.gov` **均已无 A 记录(DNS 层面下线)**,USPTO 于 2025-10-20 退役;替代的 Assignment Center 搜索模块返回 HTTP 403;ODP(`api.uspto.gov`)返回 401 需 API key。上表数据是**单一来源转录**。

### 2.3 法律状态与年费

- **状态:Active(在效)。**
- **预计到期:2040-10-16**(自 2020-10-16 申请日起 20 年,PTA=0)。
- **3.5 年年费:已缴,2025-10-23**,事件码 **MAFP** / 原始码 M1551,LARGE ENTITY。下一次(7.5 年)缴费窗口 2029-05-10 开。
- 实体状态:LARGE / UNDISCOUNTED。

> ⚠️ **年费只有单一来源**(Google Patents Legal Events,镜像 USPTO 事件码)。第二来源 **NOT RETRIEVED**:`fees.uspto.gov/MaintenanceFees/` 现要求 uspto.gov 账号登录,无匿名查询;`data.uspto.gov` 明示 **2026-06-18 起需登录**;`patentcenter.uspto.gov` 自身检索 API 返回 405;Espacenet INPADOC legal-status 页跳转/404。本次未使用任何 USPTO 账号。

### 2.4 家族与 continuation(最关键的一项)

| 成员 | 公开/授权 | 状态 |
|---|---|---|
| **US(本案)** | US2021/0118218 A1 → **US 11,328,475 B2**(2022-05-10) | 授权、在效 |
| **US 续案 #1** | US2022/0230382 A1 → **US 11,935,180 B2**(2024-03-19),**"Dual IMU SLAM"**,17/715,880,2022-04-07 申 | **已授权** |
| **US 续案 #2** | US2024/0185510 A1 → **US 12,249,024 B2**(2025-03-11),**"Dual IMU SLAM"**,18/439,653,2024-02-12 申 | **已授权** |
| EP | EP 4046138 A1/A4 → **EP 4046138 B1**(2024-11-27) | 已授权 |
| CN | CN 114830182 A → **CN 114830182 B**(2026-03-27) | 已授权 |
| JP | JP 2022-553202 A → **JP 7565349 B2**(2024-10-10) | 已授权 |
| WO | WO 2021/077024 A1 | 已进国家阶段 |

**主张 62/923,317 优先权的美国非临时申请共 3 件,全部已授权;未发现在审(pending)美国续案。**

> ⚠️ **但未能积极排除**:若 18/439,653 在 2025-03-11 授权前又提了一件 continuation,它目前尚未公开(最早约 2026 年中后期才会公开),Google Patents / INPADOC 都看不到。权威查法是 USPTO Patent Center 的 continuity data,**本次不可达(405 / 登录墙)**。

**两件已授权续案的权项我已独立取回并核对——它们对手持手机是双重不适用:**
- **US 11,935,180 B2** 独立权项 1/14/19:要求 `"a sensor of a wearable head device"` + `"a first inertial measurement unit (IMU)"` **和** `"a second IMU of wearable head device"` + `"a display of the wearable head device"` + `"presenting … virtual content"`。**权项中 gravity 零次。**
- **US 12,249,024 B2** 独立权项 1/14/20:同样要求 **两个 IMU** + wearable head device + display。claim 14 前序即 `"A system comprising: a first inertial measurement unit (IMU) of a wearable head device; a second IMU of the wearable head device; a display of the wearable head device; …"`。**权项中 gravity 零次。**

### 2.5 审查经过

- 2021-08-20 立案 → **2021-11-22 非最终 OA** → 2022-03-02 答复录入 → 2022-03-18 前后发出 Notice of Allowance → 2022-04-20 patented case。**一次 OA,无最终驳回,无 RCE,无上诉。**
- **独立权项在审查中未被缩小**:US 2021/0118218 A1 公开时的 claim 1 与授权 claim 1 **逐字相同**,两份文件都是 20 项权利要求。
- **引证的现有技术里没有 VIO/SLAM 文献。**78 篇专利引证 + 12 篇非专利引证;全文检索 `ORB-SLAM` / `VINS` / `VI-DSO` / `DSO` / `Mur-Artal` / `Qin` / `Leutenegger` / `OKVIS` / `Forster` **全部 0 命中**。12 篇 NPL 是 Magic Leap 的 AR 套话(Azuma 1995/1997、Bimber 2005)加本家族的审查文件。
- 艺术单元(art unit)/ 卷宗原件 **NOT RETRIEVED**(Patent Center 405)。

### 2.6 独立权项全文(英文逐字)

> **来源与可靠性说明**:Google Patents 对 WebFetch 与 curl 全程返回 HTTP 503,patents.justia.com 403,FreePatentsOnline 连接重置。因此权项文本取自 **USPTO 官方授权 PDF(image-ppubs.uspto.gov)**——即授权文件本身——用 macOS Vision 引擎本地 OCR。**每条独立权项都做了两次独立 OCR(450 dpi 与 300 dpi、不同分栏裁切),结果一致**;claim 19 结尾与 claim 10 结尾另做了 600 dpi 定点裁切复核。

**Claim 1(方法):**

> 1. A method comprising:
> receiving, via a sensor of a wearable head device, first sensor data indicative of a first feature in a first position;
> receiving, via the sensor, second sensor data indicative of the first feature in a second position;
> receiving, via an inertial measurement unit (IMU) on the wearable head device, inertial measurements;
> determining a velocity based on the inertial measurements;
> estimating a third position of the first feature based on the first position and the velocity;
> determining a reprojection error based on the third position and the second position;
> reducing a weight associated with the reprojection error;
> determining a state of the wearable head device, wherein determining the state comprises minimizing a total error, and wherein the total error is based on the reduced weight associated with the reprojection error; and
> presenting, via a display of the wearable head device, a view reflecting the determined state of the wearable head device.

**Claim 10(系统):**

> 10. A system comprising:
> a sensor of a wearable head device;
> an inertial measurement unit of the wearable head device;
> a display of the wearable head device;
> one or more processors configured to execute a method comprising:
> receiving, via the sensor of the wearable head device, first sensor data indicative of a first feature in a first position;
> receiving, via the sensor, second sensor data indicative of the first feature in a second position;
> receiving, via the inertial measurement unit on the wearable head device, inertial measurements;
> determining a velocity based on the inertial measurements;
> estimating a third position of the first feature based on the first position and the velocity;
> determining a reprojection error based on the third position and the second position;
> reducing a weight associated with the reprojection error;
> determining a state of the wearable head device, wherein determining the state comprises minimizing a total error, and wherein the total error is based on the reduced weight associated with the reprojection error; and
> presenting, via the display of the wearable head device, a view reflecting the determined state of the wearable head device.

**Claim 19(非暂态计算机可读介质):**

> 19. A non-transitory computer-readable medium storing instructions that, when executed by one or more processors, cause the one or more processors to execute a method comprising:
> receiving, via a sensor of a wearable head device, first sensor data indicative of a first feature in a first position;
> receiving, via the sensor, second sensor data indicative of the first feature in a second position;
> receiving, via an inertial measurement unit on the wearable head device, inertial measurements;
> determining a velocity based on the inertial measurements;
> estimating a third position of the first feature based on the first position and the velocity;
> determining a reprojection error based on the third position and the second position;
> reducing a weight associated with the reprojection error;
> determining a state of the wearable head device, wherein determining the state comprises minimizing a total error, and wherein the total error is based on the reduced weight associated with the reprojection error; and
> presenting, via a display of the wearable head device, a view reflecting the determined state of the wearable head device.

**形态限定的回答(你问的决定性问题):是。三条独立权项全部限定于 wearable head device,且全部要求该设备有 display 并 presenting a view。**传感器集合方面,claim 1/19 只要求「a sensor」+「an IMU」(不限相机种类、不要求双 IMU);双 IMU 出现在从属权项 7/16 及两件续案的独立权项里。

### 2.7 说明书公开了什么(**仅作背景,不定义侵权范围**)

说明书(FIG. 5 step 514、FIG. 8)公开了一个与 VIO 内重力估计分离的 **"standalone gravity estimation"**,其图优化结构与本次要做的 (A) 形状高度一致:

> `"nodes related to keyrig pose and IMU extrinsics (e.g., nodes 802b and 806) can be fixed, and nodes related to IMU state and gravity (e.g., nodes 802a and 808) can be optimized."`

> `"a standalone gravity estimation over 30 s may be more accurate than a standalone gravity estimation over 1 s"`

**这些内容公开了但未被主张(未写进任何权项)。**在本专利里它们不构成权利范围;它们对未来 continuation 的意义需律师判断。**而 scale 在全说明书中 0 次出现**,因此本家族说明书不支持任何以米制尺度为要素的新权项(书面描述/新事项问题)。

---

## 3. 更广的「重力作为估计变量」权项扫描

### 3.1 实质命中

| 专利号 | 标题 | 受让人 | 申请/优先/授权 | 独立权项 1 要旨 | 是否读到 (A)/(B) | 形态限定 |
|---|---|---|---|---|---|---|
| **US 9,159,133 B2** | ADAPTIVE SCALE AND/OR GRAVITY ESTIMATION | **QUALCOMM Incorporated** | 申 2013-08-29(14/014,174);优先 **61/722,601 @2012-11-05**、61/801,741 @2013-03-15;授 **2015-10-13**;PTA **100 days** | 用当前 scale 估计构 image-based pose、用当前 gravity 估计构 inertia-based pose、求差、由差**形成新的 gravity 和/或 scale 估计** | **(A) 是,最接近**;(B) 部分(gravity 被反复更新,但不是滑窗状态) | **无**。前序 `"in a mobile device"`,相机+加计。**手机不在保护范围之外。** |
| US 12,164,705 B2 / US 12,436,624 B2 | DYNAMIC GRAVITY VECTOR ESTIMATION FOR MEMORY CONSTRAINED DEVICES | STMicroelectronics S.r.l. | '705 申 2022-11-28(18/059,214),授 2024-12-10;'624 续案,授 2025-10-07 | 由 rotational versor / acceleration versor / correction factor 生成 dynamic gravity vector,**并限定具体传播公式** | **否**——权项内**无相机、无图像、无 BA**,纯 IMU | 无形态限定,但被公式锁死 |

**US 9,159,133 权项全文(英文逐字)。**来源:FreePatentsOnline 与 USPTO 授权 PDF 的两次独立 OCR(我本人用 Vision 引擎复核了 claim 1 与 claim 40,逐字一致)。

> **1.** A method for estimating in a mobile device, the method comprising: determining a first pose, from a first image captured at a first time, between a target and a first position of a camera of the mobile device, wherein the first image contains the target; determining a second pose, from a second image captured at a second time, between the target and a second position of the camera, wherein the second image contains the target; computing an image-based pose between the first pose and the second pose using a first estimation of a scaling factor; receiving measurements from an accelerometer of the mobile device from the first time to the second time; forming an inertia-based pose based on the measurements from the accelerometer and a first estimation for a gravity vector; computing a difference between the image-based pose and the inertia-based pose; and forming at least one of a second estimation of the gravity vector or a second estimation of the scaling factor based on the difference.

> **18.** A mobile device for estimating in the mobile device, the mobile device comprising: a camera configured to: capture, at a first time and a first position of the camera, a first image containing a target; and capture, at a second time and a second position of the camera, a second image containing the target; an accelerometer configured to provide measurements from the first time to the second time; and a processor coupled to the camera and to the accelerometer and configured to: determine a first pose between the target of the mobile device from the first image; determine a second pose between the target of the mobile device from the second image; compute an image-based pose between the first pose and the second pose using a first estimation of a scaling factor; form an inertia-based pose based on the measurements and a first estimation for a gravity vector; compute a difference between the image-based pose and the inertia-based pose; and form at least one of a second estimation of the gravity vector or a second estimation of the scaling factor based on the difference.

> **34.** A mobile device for estimating in the mobile device, the mobile device comprising: means for determining a first pose, from a first image captured at a first time, between a target and a first position of a camera of the mobile device, wherein the first image contains the target; means for determining a second pose, from a second image captured at a second time, between the target and a second position of the camera, wherein the second image contains the target; means for computing an image-based pose between the first pose and the second pose using a first estimation of a scaling factor; means for receiving measurements from an accelerometer of the mobile device from the first time to the second time; means for forming an inertia-based pose based on the measurements from the accelerometer and a first estimation for a gravity vector; means for computing a difference between the image-based pose and the inertia-based pose; and means for forming at least one of a second estimation of the gravity vector or a second estimation of the scaling factor based on the difference.

> **40.** A non-transitory computer-readable storage medium including program code stored thereon for a mobile device to estimate in the mobile device, wherein the program code comprises code to: determine a first pose, from a first image captured at a first time, between a target and a first position of a camera of the mobile device, wherein the first image contains the target; determine a second pose, from a second image captured at a second time, between the target and a second position of the camera, wherein the second image contains the target; compute an image-based pose between the first pose and the second pose using a first estimation of a scaling factor; receive measurements from an accelerometer of the mobile device from the first time to the second time; form an inertia-based pose based on the measurements and a first estimation for a gravity vector; compute a difference between the image-based pose and the inertia-based pose; and form at least one of a second estimation of the gravity vector or a second estimation of the scaling factor based on the difference.

关于「周期性」:从属权项 14/15/30/31 据报增加了迭代重复(`"a third pose… a next difference… a third estimation of the gravity vector or a third estimation of the scaling factor"`)。**此段从属权项文本我未做第二次独立核对**,引用前请复核。**法律状态/年费 NOT RETRIEVED**(全部 USPTO 年费入口登录墙/反爬)。若按 20 年 + PTA 100 天推算,名义届满约 **2033-12 前后**,但是否因欠费提前失效未知——**这是下一步最该查的一条**。

### 3.2 Snap「周期性参数估计」家族(旧笔记标为"直接对口"——**需要更正**)

| 专利号 | 标题 | 受让人 | 日期 | 独立权项要旨 |
|---|---|---|---|---|
| **US 11,662,805 B2** | Periodic parameter estimation for visual-inertial tracking systems | Snap Inc. | 母案 17/301,655 申 2021-04-09;临时 63/131,981 @2020-12-30 | 在 AR 应用**不请求跟踪时**离线跑 VIO 求标定参数、存盘,应用请求跟踪时取出作起点 |
| **US 12,210,672 B2** | 同上 | Snap Inc. | 续案,授 2025-01 | 同上,增加 "periodically updating … during an offline calibration parameter estimation" |

**更正:这一族不读到 (A)。**理由有二,均为权项内限定语(我本人从 USPTO 授权 PDF OCR 取得):

- **全部独立权项限定于 head-mounted device。**US 11,662,805 claim 1 逐字:
  > 1. A method for calibrating a visual-inertial tracking system comprising: detecting, **at a head-mounted device**, that a virtual object display application that is configured to operate at the head-mounted device **is not requesting tracking operations** from the visual-inertial tracking system of the head-mounted device; in response to the detection, operating, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device; identifying, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device; storing, in a storage of the head-mounted device, the first calibration parameter value; detecting an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and in response to detecting the tracking request, accessing, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.
  
  (末句 `"virtual-inertial"` 疑为授权文本自身的笔误,照录。)

  US 12,210,672 claim 11 逐字(claim 1 与 claim 20 的主体语句相同):
  > 11. **A head-mounted device** comprising: a processor, and a memory storing instructions that, when executed by the processor, configure the head-mounted device to perform operations comprising: **periodically updating**, at the head-mounted device, a first calibration parameter value of a visual-inertial tracking system **during an offline calibration parameter estimation** of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation; detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

- **方向相反**:Snap 要求的是**在应用不跟踪时**(offline)做周期性估计;我们的 (A) 是**跟踪进行中**做周期性重优化。从属权项 19('672)进一步明确 `"the offline calibration parameter estimation operates in response to the application not requesting tracking operations"`。

是否有在审续案 **NOT RETRIEVED**('672 于 2025-01 授权,其前提交的 continuation 尚未公开)。

### 3.3 查过但独立权项内无重力估计(阴性)

| 专利/申请 | 受让人 | 阴性理由 |
|---|---|---|
| **US 11,328,475 / 11,935,180 / 12,249,024** | Magic Leap | 权项内 gravity 零次;全锁 wearable head device + display |
| US 12,366,590 B2 | Google LLC | gravity 只在**从属**权项 8/17/20(且需 ML 深度 + 出厂/用户标定态双要素) |
| US 11,315,280 B1 / 11,935,264 B2 | Apple Inc. | 独立权项用上位概念 `"a directional measurement"`(从属权项 7/8 才定义为 gravity);**只要求"使用"方向量,不要求估计/细化重力**;无形态限定 |
| US 9,243,916 B2 | Univ. of Minnesota | `"a rotation about a gravity vector"` 作为**不可观方向**出现在从属权项;是 OC-EKF,不是重力估计 |
| US 12,387,502 B2 | TRIFO, INC. | claim 1 是 `"aligning coordinates … to a coordinate system having a z-axis aligned with gravity"` —— **重力对齐,不是重力估计** |
| **US 11,830,218 B2** | **SLAMcore Limited** | 我本人核对:独立权项 21 等是"在已有地图中重定位"(keyframe/landmark 匹配),**权项内无 gravity**;搜索摘要里的重力说法出自说明书 |
| US 10,267,924 / 10,371,530 / 10,324,195 / 10,514,456 | Qualcomm | GNSS/雷达辅助 VIO,权项内无 gravity |
| US 10,890,600 B2 | Google LLC | 故障检测 |
| US 10,866,427 B2 | Samsung | ego-motion filter,无 gravity |
| US 12,400,346 B2 | Intel | 单目 metric depth,无 gravity |
| US 12,260,588 B2 | Snap Inc. | 立体深度弯曲校正,yaw-bias |
| US 9,766,074 / 9,709,404 / 9,607,401 / 9,658,070 / 10,371,529 | Univ. of Minnesota | vision-aided INS 系列,权项内无重力估计 |
| US 10,838,427 B2 | Draper Laboratory | 无 |
| US 10,929,690 / 11,398,096 / 10,453,213 | Trifo(原 Perceptln) | 重力对齐类 |
| US 2014/0129176 A1 | Qualcomm | **未授权(据报 abandoned,未独立核实)**;且公开权项要求设备 `"held stationary on the target plane"`,是标定手势不是在线 VIO |
| US 2022/0414919 A1 | Samsung | depth-aided VIO,授权号 NOT RETRIEVED |

**Microsoft / Meta(Facebook Technologies)/ Niantic / Huawei / SenseTime / ByteDance:未找到独立权项含重力估计的在效美国专利。**这是**"未发现"而非"不存在"**——本次**没有任何一个可用的按受让人+权项字段检索的界面**(Google Patents 503、Justia 403、Espacenet 403、FPO expert search 不可达、USPTO PPS 被 WAF 拦),全部结论建立在关键词 WebSearch + 逐件 OCR 上。在有人把这些阴性当作 clearance 之前,必须用 `ACLM/"gravity" AND AN/"Microsoft"` 这类字段检索重跑。

### 3.4 一条重要的意外发现:VI-DSO 本身被申请过专利

| 项 | 值 |
|---|---|
| 公开号 | **US 2019/0301871 A1** |
| 标题 | DIRECT SPARSE VISUAL-INERTIAL ODOMETRY USING DYNAMIC MARGINALIZATION |
| 申请人 | **Artisense Corporation, Palo Alto, CA**(Artisense 于 2021-01 被 **Kudan Inc.** 收购) |
| 发明人 | Lukas Michael von Stumberg |
| 申请号/申请日 | 16/366,659 / **2019-03-27** |
| 优先权 | 临时 **62/648,416 @2018-03-27** |
| 公开日 | 2019-10-03 |
| PCT | WO 2019/191288 |

其公开权项直接写到我们两个特性:claim 7 前序 `"A method of estimating a scale parameter in a visual-inertial odometry system"`;claim 12 `"wherein the set of inertial data includes a transformation parameter describing a scale value and a gravity direction value."`

**授权状态:据搜索结果显示为 Abandoned(已放弃),但我未能独立核实。**已尝试:Google Patents(503)、Patentscope(403)、以及在 USPTO 授权 PDF 索引中按该标题检索——**未发现任何对应的 B1/B2 授权文件**,与"未授权"一致但不构成证明。**这一条值得律师用 Patent Center continuity/status 正式确认**:若确已放弃,则这条最贴近 (A)+(B) 的权利线在美国不存在;同时其 2019-10-03 的公开(早于 Magic Leap 2019-10-18 优先权 15 天)本身是现有技术。

---

## 4. 最早公开时间线(论文 + 代码)

### 4.1 概念一:重力方向作为 2-DoF 变量进入视觉惯性优化

| 日期 | 作者 | 标题(原文英文) | 出处 | arXiv / DOI | 事实注记 |
|---|---|---|---|---|---|
| 2012-02 | A. Martinelli | Vision and IMU Data Fusion: Closed-Form Solutions for Attitude, Speed, Absolute Scale, and Bias Determination | IEEE T-RO 28(1):44–60 | 10.1109/TRO.2011.2160468 | 摘要原文:`"the observable modes are the speed and attitude (roll and pitch angles), the absolute scale and the biases"`。闭式解,非迭代优化 |
| 2013-06-23 | Leutenegger, Furgale, Rabaud, Chli, Konolige, Siegwart | **Keyframe-Based Visual-Inertial SLAM Using Nonlinear Optimization** | RSS IX | 10.15607/RSS.2013.IX.037 | **重力不是变量**。状态 eq.(1) `x_R := [p, q, v, b_g, b_a]`,eq.(7) 把 `g_W` 当已知常量 |
| 2014-12-15(在线) | Leutenegger, Lynen, Bosse, Siegwart, Furgale | Keyframe-based visual–inertial odometry using nonlinear optimization | IJRR 34(3):314–334 | 10.1177/0278364914554813 | OKVIS 期刊版,设计同上 |
| 2015-12-08(arXiv v1) | Forster, Carlone, Dellaert, Scaramuzza | On-Manifold Preintegration for Real-Time Visual-Inertial Odometry | arXiv;T-RO 2017 | arXiv 1512.02363;10.1109/TRO.2016.2597321 | **无 2-DoF 重力参数化**。GTSAM 中重力是构造参数 `Vector3 n_gravity` |
| 2016-05 | Concha, Loianno, Kumar, Civera | Visual-inertial direct SLAM | ICRA 2016 | 10.1109/ICRA.2016.7487266 | **重力不被估计**,eq.(11) 状态 15 维不含 g |
| **2016-10-19**(arXiv v1) | **Mur-Artal, Tardós** | **Visual-Inertial Monocular SLAM with Map Reuse** | arXiv;RA-L 2(2):796–803 | **arXiv 1610.05949**;10.1109/LRA.2017.2653359 | ⭐ **核实到的最早明确 2-DoF 重力**。§IV-C 原文:`"R_WI can be parametrized with just two angles around x and y axes"`;SVD 联立解出 `scale factor s*, gravity direction correction δθ*_xy, accelerometer bias b*_a`(6 未知数 = 1 尺度 + 2 重力角 + 3 偏置) |
| **2017-08-13**(arXiv v1) | **Qin, Li, Shen** | **VINS-Mono: A Robust and Versatile Monocular Visual-Inertial State Estimator** | arXiv;T-RO 34(4) | **arXiv 1708.03852**;10.1109/TRO.2018.2853729 | ⭐ Fig.5 标题原文:`"Illustration of 2 DOF parameterization of gravity … parameterized around current estimate as g·ḡ̂ + w₁b₁ + w₂b₂, where b₁ and b₂ are two orthogonal basis spanning the tangent space."` 初始化状态 eq.(16) 含 `g^c0` 与 `s` |
| **2018-04-16**(arXiv v1) | **von Stumberg, Usenko, Cremers** | **Direct Sparse Visual-Inertial Odometry using Dynamic Marginalization**(VI-DSO) | arXiv;ICRA 2018 | **arXiv 1804.05625**;10.1109/ICRA.2018.8462905 | ⭐ 摘要原文:`"We explicitly include scale and gravity direction into our model and jointly optimize them together with other variables such as poses."` 注意:其变量是 SIM(3) 子群的 4 DoF(旋转 3 + 尺度 1),**不是 2-DoF** |
| ▬▬ | | **Magic Leap 优先权日 2019-10-18** | | | |
| 2020-03-12 | Campos, Montiel, Tardós | Inertial-Only Optimization for Visual-Inertial Initialization | arXiv 2003.05766;ICRA 2020 | | **晚于优先权日** |
| 2020-07-23 | Campos, Elvira, Gómez Rodríguez, Montiel, Tardós | ORB-SLAM3: An Accurate Open-Source Library for Visual, Visual-Inertial and Multi-Map SLAM | arXiv 2007.11898;T-RO 37(6) | | **晚于优先权日**。v1 已写:`"R_wg ∈ SO(3) is the gravity direction, represented with two angles"` |

**关于 `VertexGDir` 的精确答案:**`include/G2oTypes.h` 第 **271** 行 `class VertexGDir : public g2o::BaseVertex<2,GDirection>`,其 `GDirection`(第 254 行)更新式 `Rwg = Rwg*ExpSO3(pu[0],pu[1],0.0)`;第 293 行有配套 `VertexScale : BaseVertex<1,double>`。**首次公开提交:`df16ecc040d35ecbd9f81477e32e80b49460276c`,2020-07-22T09:45:39Z**(仓库首个 commit `bd7d14ba…` 2020-07-18 只有 README/LICENSE)。**ORB_SLAM2 及 Mur-Artal 已发布代码中均无等价物**——VI-ORB-SLAM(RA-L 2017)作者从未发布代码。

### 4.2 概念二:运行中周期性/重复重估米制尺度

| 日期 | 作者 | 标题(原文英文) | 出处 | DOI | 事实注记 |
|---|---|---|---|---|---|
| 2010-06-27 | Strasdat, Montiel, Davison | Scale Drift-Aware Large Scale Monocular SLAM | RSS VI | 10.15607/RSS.2010.VI.010 | 纯单目无 IMU |
| **2010-11-12**(在线) | **Nützi, Weiss, Scaramuzza, Siegwart** | **Fusion of IMU and Vision for Absolute Scale Estimation in Monocular SLAM** | J. Intell. Robot. Syst. 61:287–299 | 10.1007/s10846-010-9490-z | ⭐ **核实到的最早"尺度在运行中被持续重估"**。§5.1 EKF 状态 `z_k = [x_k, v_k, a_k, λ_k]`,**尺度 λ 是常驻滤波器状态**,非一次性初始化;结论段 `"a multi rate EKF running in real time with over 60 Hz"` |
| 2016-10-19 | Mur-Artal, Tardós | Visual-Inertial Monocular SLAM with Map Reuse | arXiv 1610.05949 | | **不是周期性**:`"the IMU initialization is performed after 15 seconds"`;§IV-E 重定位后只重初始化**偏置**(`"scale and gravity are already known"`) |
| 2017-08-13 | Qin, Li, Shen | VINS-Mono | arXiv 1708.03852 | | **尺度仅初始化**。初始化后滑窗状态 eq.(21) 不含 scale 与 gravity |
| **2018-04-16** | **von Stumberg, Usenko, Cremers** | **VI-DSO** | arXiv 1804.05625 | 10.1109/ICRA.2018.8462905 | ⭐ **优先权日前最强的"跟踪中反复精化尺度"公开**。§III-G 原文:`"Everytime the joint optimization is finished for a new frame, the coarse tracking is reinitialized with the new estimates for scale, gravity direction, bias, and velocity."` 讨论段:`"the concept of initialization with a very rough scale estimate and jointly estimating it during pose estimation"`;Fig.4/8 画出 0–35 s 内尺度估计的演化 |
| ▬▬ | | **Magic Leap 优先权日 2019-10-18** | | | |
| 2020-07-23 | Campos et al. | ORB-SLAM3 | arXiv 2007.11898 v1 | | **晚于优先权日**。原文:`"we propose a novel scale refinement technique … where all inserted keyframes are included but scale and gravity direction are the only parameters to be estimated … This optimization … is performed in the Local Mapping thread every ten seconds, until the map has more than 100 keyframes or more than 75 seconds have passed since initialization."` 另:`"visual-inertial BA is performed 5 and 15 seconds after initialization, converging to 1% scale error."` |

> **注意一个对本项目很要紧的日期事实**:你们 (A) 的直接配方(「只优化 scale + 2-DoF 重力、每 10 秒一次」)的权威表述出自 **ORB-SLAM3,2020-07-23**,**晚于 Magic Leap 的 2019-10-18,也晚于 Qualcomm 的 2012-11-05**。而**早于**这两个优先权日的同类公开是 **VI-DSO(2018-04-16)**、**VINS-Mono(2017-08-13)**、**Mur-Artal & Tardós(2016-10-19)**、**Nützi et al.(2010-11-12)**。

### 4.3 代码公开日期

| 软件 | 仓库 | 首个代码 commit | 首个 tag | 许可 | 相关内容是否在当时已存在 |
|---|---|---|---|---|---|
| **VINS-Mono** | HKUST-Aerial-Robotics/VINS-Mono | **`6fc41de52eecc30a1d0f34b93d22f9aad22fa9c0`,2017-05-20T08:42:27Z** | 无 tag/release | GPL-3.0 | **是**。首个 commit 即含 `initial_aligment.cpp` 的 `TangentBasis()`(L40)与 `RefineGravity()`(L55),`n_state = all_frame_count*3 + 2 + 1`(2 重力 DoF + 1 尺度) |
| **OKVIS** | ethz-asl/okvis | `f751fd789f4e`,2016-02-04T18:38:14Z | `v1.1.1`,2016-02-04T20:38:07Z | BSD-3 | **否**。`Parameters.hpp:117` 只有标量 `double g;`;`ImuError.cpp:472` 把方向硬编码 `g_W = imuParameters_.g * Vector3d(0,0,6371009).normalized()`;`ImuError.hpp:72` 的 `SizedCostFunction<15,7,9,7,9>` 无重力参数块 |
| **ORB-SLAM3** | UZ-SLAMLab/ORB_SLAM3 | `df16ecc0…`,**2020-07-22T09:45:39Z** | `v0.2-beta`,2020-07-24 | GPL-3.0 | **是,但晚于优先权日** |
| **VI-ORB-SLAM** | — | 作者从未发布 | — | — | 第三方移植 `jingpang/LearnVIORB` 2016-12-23 |
| **VI-DSO** | — | **作者从未发布**(已查 TUM CVG 项目页、`lukasvst`、`tum-vision` 全部 45 个仓库、`JakobEngel/dso`) | — | — | 第三方 `RonaldSun/VI-Stereo-DSO` 2019-03-06 |
| **GTSAM** | borglab/gtsam | 历史最早 2009-08-21 | 多 | BSD | 经典 `ImuFactor` 重力固定;**把重力当变量的 `ImuFactorWithGravity.h`(`Unit3` 参数化)是 2026-07-30/08-01 才写的,首次随 tag `4.3.0`(2026-09-18)发布** |

---

## 5. 对照表:(A)(B) 逐要素 vs 各权项限定语

### (A) 每 N 秒重优化 {scale s, 2-DoF gravity},其余固定

| 我们的要素 | vs **Qualcomm US 9,159,133** cl.1 | vs **Magic Leap US 11,328,475** cl.1 | vs **Snap US 12,210,672** cl.1/11 |
|---|---|---|---|
| 手持手机 | **落入**(`"a mobile device"`,无形态限定) | **落外**(`"a wearable head device"` + `"a display"` + `"presenting a view"`) | **落外**(`"a head-mounted device"`) |
| 单目相机 + IMU | **落入**(camera + accelerometer;陀螺在从属项) | 落入(`"a sensor"` + `"an IMU"`) | 落入 |
| 估计/更新 **gravity** | **落入**(`"a second estimation of the gravity vector"`) | **落外**(权项内 gravity 零次) | 落外(只说 "calibration parameter value") |
| 估计/更新 **scale** | **落入**(`"a second estimation of the scaling factor"`;"and/or" 结构,二者取一即可) | **落外**(全说明书 scale 零次) | 落外 |
| **跟踪进行中**周期性重跑 | 部分(从属 14/15/30/31 的迭代;独立权项本身只要求一轮) | 不适用 | **落外且方向相反**(`"the offline calibration parameter estimation operates in response to the application not requesting tracking operations"`) |
| 其余地图固定 | 未要求 | 不适用 | 不适用 |
| **画面中必须有 "target"** | ⚠️ **最可能的回避点**:cl.1/18/34/40 全要求 `"wherein the first image contains the target"` 且位姿定义为 `"between a target and a … position of a camera"`。通用无标靶特征 VIO 是否落入,取决于 "target" 的解释 | — | — |
| **构造两个位姿并求差** | ⚠️ **第二个回避点**:必须分别构出 `image-based pose` 与 `inertia-based pose` 并 `"computing a difference"`,由该差驱动更新。联合非线性最小二乘(BA/因子图)是否等同,需律师判断 | — | — |

### (B) 重力方向作为滑窗内活变量

| 我们的要素 | 已检索范围内的结论 |
|---|---|
| 手持手机 | 无任何命中权项以形态设限拦住手机 |
| 重力作为**被估计变量**(非常量) | **未发现任何在效美国专利的独立权项以此为要素**。Apple '280/'264 只要求"使用"一个 `directional measurement`;Google '590、Minnesota '916 的重力都在从属项;STMicro '705/'624 有独立权项级重力估计但**无相机/无图像/被公式锁死** |
| 2-DoF 参数化 | 未见任何美国权项以 "two degrees of freedom / two angles" 限定重力 |
| 滑窗 / BA | Qualcomm '133 不是滑窗构造;Magic Leap '475 是 BA 但权项写的是重投影误差加权 |

### 最可能的设计回避点(事实层面的观察,非法律建议)

1. **对 Qualcomm '133**:不构造"image-based pose vs inertia-based pose 之差";改为在一个联合因子图里直接对 {s, g} 做 MAP 估计(这正是 ORB-SLAM3 的做法)。另,不依赖画面中的 "target"。
2. **对整个 Magic Leap 家族**:不出货头戴设备、不在头戴设备的 display 上 presenting a view,即全部三件专利的每一条独立权项都缺要素。手持手机形态本身就在外面。
3. **对 Snap 家族**:我们的重优化发生在**跟踪进行中**,与其 `"not requesting tracking operations"` 的 offline 限定相反;且非头戴。
4. **有效性材料(仅提供日期,不作判断)**:若需评估 Qualcomm '133(优先权 **2012-11-05**),早于它的公开是 **Nützi et al. 2010-11-12**(尺度作为常驻 EKF 状态持续重估)与 **Strasdat et al. 2010-06-27**;Mur-Artal 2016 / VINS-Mono 2017 / VI-DSO 2018 都**晚于**它,对 '133 不是现有技术,但对 Magic Leap(2019-10-18)全部**早于**。

---

## 6. 检索覆盖与未取得项(据实列出)

**方法与阻碍。**`patents.google.com` 对 WebFetch 与 curl **全程 HTTP 503**(bot 拦截,非宕机);`patents.justia.com` 403;FreePatentsOnline 连接重置;Espacenet 403;Patentscope 403;USPTO 的 `assignment-api` / `ped` / `patft` 域名**已下线(DNS 无 A 记录)**;`api.uspto.gov` 401;`fees.uspto.gov` 与 `data.uspto.gov` **已改为强制登录**;Patent Center 自身检索 API 405。**本次未使用任何 USPTO 账号。**

**可用且被用作主源的路径**:`image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/<号>` 下载**官方授权文件 PDF**(图像型),本地用 `pdftoppm` + macOS Vision 引擎 OCR。所有关键权项均做**两次独立 OCR**(不同分辨率与分栏裁切)并比对;Magic Leap claim 10/19 结尾另做 600 dpi 定点裁切三次复核;Qualcomm claim 1 与 claim 40 由我用 Vision 引擎独立复核,与子代理的 tesseract+FPO 转录**逐字一致**。

**明确的 NOT RETRIEVED:**
- 除 US 11,328,475 外,**所有专利的法律状态与年费状态**(含最高风险的 Qualcomm US 9,159,133)。
- US 11,328,475 年费的**第二独立来源**(只有 Google Patents Legal Events 一个)。
- US 11,328,475 家族**是否存在未公开的在审 continuation**(只能说"未发现",不能说"不存在")。
- **US 2019/0301871 A1(Artisense/VI-DSO)的正式授权状态**——搜索摘要称 Abandoned,未独立核实。
- Qualcomm '133 的续案/家族情况;其从属权项 14/15/30/31 的第二次核对。
- STMicro '705 独立权项中的数学公式行(OCR 严重损坏,未重建;另发现该专利有 **2025-02-11 的 Certificate of Correction**,更正 Column 17 / Claim 14 / Line 41 的 `gprop`)。
- **按受让人 + 权项字段的结构化检索**(如 `ACLM/"gravity" AND AN/"Microsoft"`)——本次所有此类界面均不可达。因此 Microsoft / Meta / Niantic / Huawei / SenseTime / ByteDance 的"无命中"是**证据缺失,不是清白证明**。
- 本次派出的两个广度扫描代理中,负责 Meta/Snap/Niantic/华为/商汤/字节 + 周期性尺度那一路**未在时限内返回**;其中最要紧的 Snap「periodic parameter estimation」家族我已亲自完整取证(见 §3.2),Meta/Niantic/SLAMcore/中国受让人已做点查,但该半边的覆盖度低于另一半。

---

## 7. 免责声明

**本文件是事实搜集(fact-gathering),不是法律意见,也不构成 freedom-to-operate 结论或清白意见(clearance opinion)。** 文中的"高/中/低风险"仅是对**检索到的权项限定语与本产品特性之间字面对应程度**的事实性描述,不是侵权分析。权利要求解释(claim construction)、等同论(doctrine of equivalents)、权项有效性、以及各国对应件的范围差异,**必须由持证专利律师完成**。上文列出的"设计回避点"是对权项文字的观察,不是可依赖的规避设计建议。年费与法律状态存在单一来源或未取得项(见 §6),在据此做任何商业决定前必须由律师通过 USPTO 官方渠道复核。
