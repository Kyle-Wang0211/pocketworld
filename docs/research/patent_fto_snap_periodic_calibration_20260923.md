<!-- 来源:专利事实搜集 agent 最终报告,原样落盘(2026-09-23)。
     主会话复核:US12704900 / US12210672 的 claim 1 已用 FreePatentsOnline 直取逐字比对一致;
     两件说明书 grep:gravity 0、scale 仅 'grayscale' 1、bundle adjust 0、marginaliz 0、smartphone/smart phone 共 3。
     本文件是事实搜集,不是法律意见。 -->


---

# 专利事实搜集报告 — Snap「Periodic parameter estimation for visual-inertial tracking systems」族

**检索日期:2026-09-23｜性质:事实搜集(fact-gathering),非法律意见**

---

## 1. 一句话结论

**对特征 (A)「跟踪运行中每 N 秒周期性重优化 metric scale + 2DoF 重力方向」,这一族三件美国专利的风险是【低】** —— 依据是三件专利**全部独立权项**都含两条与 (A) 结构相反的限定语:(i) 载体必须是 **"head-mounted device"**(US11662805、US12210672)或 **"wearable device"**(US12704900);(ii) 参数估计发生在**应用不请求跟踪的空闲/offline 阶段**(`'805`: *"is not requesting tracking operations"*;`'672`: *"during an offline calibration parameter estimation"*;`'900`: *"detecting a calibration trigger event"* + *"as a starting point"*),再在**收到 tracking request 那一刻**把存下的值当作起点。我们的 (A) 恰恰是**在 online 跟踪进行中**周期性重解——落在这些限定语之外。

附带一条更硬的事实:**三件专利的说明书全文中 "scale" 作为"尺度"一次未出现、"gravity" 零命中**(`scale` 唯一一次命中出现在 "grayscale" 一词中)。说明书对 "calibration parameter" 的举例是 *extrinsic(传感器间相对位姿)、intrinsic(相机/镜头)、IMU biases、机架形变、auto exposure* —— 不含 metric scale 与重力方向。

---

## 2. 逐件专利

### 2.1 US 11,662,805 B2

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc.(2023-04-14 记录转让,生效日 2021-04-08,REEL/FRAME 063323/0903) |
| 发明人 | Halmetschlager-Funek, Georg; Kalkgruber, Matthias; Wolf, Daniel; Zillner, Jakob |
| 申请号 | US 17/301,655 |
| 申请日 | 2021-04-09 |
| 优先权日 | **2020-12-30**(US 63/131,981 临时申请) |
| 授权日 | 2023-05-30 |
| 公开 | US 2022/0206565 A1 (2022-06-30) |
| IPC/CPC | G06F3/01; G06F3/038; H04L67/131 / G06F3/012 |
| 现状 | 已授权在册。INPADOC 最后事件 `US STCF — INFORMATION ON STATUS: PATENT GRANT / PATENTED CASE`(2023-05-10),其后**无**失效、放弃、再审查事件 |
| 年费 | INPADOC 事件表中**未见授权后缴费(MAFP)事件**。按授权日推算:3.5 年首笔年费**免附加费窗口 2026-05-30 → 2026-11-30**,宽限期至 2027-05-30 ⇒ **截至今日不可能因欠费失效**。USPTO Fee Portal / Patent Center 实际缴费记录 **NOT RETRIEVED**(见第 3 节"尝试记录") |
| 名义届满 | 2041-04-09(自最早非临时美国申请日起 20 年);PTA/PTE/terminal disclaimer **NOT RETRIEVED** |

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method for calibrating a visual-inertial tracking system comprising:
> detecting, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operating, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identifying, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> storing, in a storage of the head-mounted device, the first calibration parameter value;
> detecting an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, accessing, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

> **11.** A computing apparatus comprising:
> a processor; and
> a memory storing instructions that, when executed by the processor, configure the apparatus to perform operations comprising:
> detect, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operate, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identify, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> store, in a storage of the head-mounted device, the first calibration parameter value;
> detect an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, access, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> detect, at a head-mounted device, that a virtual object display application that is configured to operate at the head-mounted device is not requesting tracking operations from the visual-inertial tracking system of the head-mounted device;
> in response to the detection, operate, at the head-mounted device, the visual-inertial tracking system by accessing sensor data from a plurality of sensors only at the head-mounted device;
> identify, at the head-mounted device, a first calibration parameter value of the visual-inertial tracking system based on the sensor data from the plurality of sensors only at the head-mounted device;
> store, in a storage of the head-mounted device, the first calibration parameter value;
> detect an operation of the virtual object display application at the head-mounted device by detecting a tracking request from the virtual object display application to the visual-inertial tracking system; and
> in response to detecting the tracking request, access, at the storage of the head-mounted device, the first calibration parameter value and determining, at the head-mounted device, a second calibration parameter value of the virtual-inertial tracking system from the first calibration parameter value.

**针对提问的三点:**
- **周期性/时间间隔限定?** 🔴 **独立权项中没有。** "periodically" 只出现在**从属**权项 2/12(*"periodically accessing the sensor data from the plurality of sensors"*)。任何具体秒数(*"every n second, m minutes"*)只在**说明书 [0035]**,不在权项中。
- **是否指明重估哪些参数?** 🔴 **没有。** 只写 "a first/second calibration parameter value of the visual-inertial tracking system",属功能性泛指。说明书举例([0020]/[0038]):*extrinsic parameters (relative orientations and positions between sensors)*、*intrinsic parameters (internal camera or lens parameters)*、*IMU biases*、*bending of the frame*、*auto exposure*。**"metric scale"、"gravity direction" 在说明书中零命中。**
- **是否有显示/AR 眼镜/硬件语境的窄化限定?** ✅ **有,且很重。** 三条独立权项**每一步**都要求 "at a head-mounted device",并且要求存在 "a virtual object display application"、"from the plurality of sensors **only at the head-mounted device**"。

---

### 2.2 US 12,210,672 B2(第一件续案)

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc. |
| 申请号 | US 18/116,511 —— **continuation of 17/301,655** |
| 申请日 | 2023-03-02 |
| 优先权日 | 2020-12-30(US 63/131,981) |
| **授权日** | **2025-01-28** |
| 公开 | US 2023/0205311 A1 (2023-06-29) |
| 现状 | **已授权在册**。另有 **Certificate of Correction,2025-03-25**(见下,纯排印更正) |
| 年费 | 3.5 年首笔年费到期日 **2028-07-28**,免附加费窗口 2028-01-28 起 ⇒ **尚未到期** |
| 名义届满 | 2041-04-09(与母案同日;terminal disclaimer 情况 **NOT RETRIEVED**) |

**Certificate of Correction 内容(已取到 USPTO 原件 PDF 第 25 页并逐字核对):**
> In the Claims — In Column 18, Line 10, in Claim 11, delete "processor," and insert --processor;-- therefor

⇒ 仅把 claim 11 中一个逗号改成分号,**未改动任何实质权项范围**。下方权项文本(授权公告原文)据此有效。

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method comprising:
> periodically updating, at a head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

> **11.** A head-mounted device comprising:
> a processor, and
> a memory storing instructions that, when executed by the processor, configure the head-mounted device to perform operations comprising:
> periodically updating, at the head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> periodically updating, at a head-mounted device, a first calibration parameter value of a visual-inertial tracking system during an offline calibration parameter estimation of the visual-inertial tracking system, the offline calibration parameter estimation performed after an online calibration parameter estimation;
> detecting a tracking request from an application at the head-mounted device to the visual-inertial tracking system; and
> in response to detecting the tracking request, switching the offline calibration parameter estimation to an online calibration parameter estimation and using the first calibration parameter value as a starting point for estimating a second calibration parameter value of the visual-inertial tracking system.

**针对提问的三点:**
- **周期性限定?** ✅ **有** —— *"periodically updating"*。**但它被死死绑在 "during an offline calibration parameter estimation" 上**,且该 offline 估计还必须 "performed after an online calibration parameter estimation"。**仍然没有任何数值间隔**(无 "N seconds")。
- **指明参数?** 🔴 没有(同 `'805`,泛指 "calibration parameter value")。
- **硬件/显示限定?** ✅ 有 —— 每条独立权项都要求 "head-mounted device";claim 11 的前序直接就是 "A head-mounted device comprising"。注意此件把 `'805` 的 "virtual object display application" **放宽为 "an application"**(AR 应用退到从属权项 10)。

---

### 2.3 US 12,704,900 B2(第二件续案 —— **本族目前最宽的一件**)

| 项目 | 内容 |
|---|---|
| 标题 | Periodic parameter estimation for visual-inertial tracking systems |
| 权利人 | Snap Inc. |
| 申请号 | US 18/970,124 —— **continuation of 18/116,511**,后者 continuation of 17/301,655 |
| 申请日 | 2024-12-05 |
| 优先权日 | 2020-12-30 |
| **授权日** | **2026-08-11**(INPADOC `US STCF — PATENT GRANT` 事件日 2026-07-29) |
| 公开 | US 2025/0093948 A1 (2025-03-20) |
| 现状 | **已授权在册**(授权仅一个多月) |
| 年费 | 3.5 年首笔年费到期日 **2030-02-11** ⇒ 尚未到期 |
| 名义届满 | 2041-04-09 |

**独立权项:claim 1、claim 11、claim 20(共 20 项)。逐字原文如下。**

> **1.** A method comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

> **11.** A wearable device comprising:
> a processor; and
> a memory storing instructions that, when executed by the processor, configure the wearable device to perform operations comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

> **20.** A non-transitory computer-readable storage medium, the computer-readable storage medium including instructions that when executed by a computer, cause the computer to perform operations comprising:
> detecting a calibration trigger event at a wearable device;
> in response to detecting the calibration trigger event, identifying, at the wearable device, a first calibration parameter value based on sensor data from a sensor of the wearable device;
> storing the first calibration parameter value in a memory of the wearable device;
> detecting a tracking request from an application at the wearable device; and
> in response to detecting the tracking request, using the first calibration parameter value as a starting point for estimating a second calibration parameter value of a visual-inertial tracking system of the wearable device.

**族内演化方向(重要):** 从 `'805` → `'672` → `'900`,Snap 三次递进地**拆掉窄化语**:
- "head-mounted device" → **"wearable device"**
- "virtual object display application" → "an application"
- "detecting that the application is **not** requesting tracking" / "offline estimation" → **"detecting a calibration trigger event"**(offline/online 退到从属 2/3)
- "sensors **only at** the head-mounted device" → "a sensor of the wearable device"

**针对提问的三点:** 周期性限定 🔴 **已从独立权项移除**(退到从属 7/17);参数类型 🔴 仍未指明,且措辞更泛("a first calibration parameter value",连 "of the visual-inertial tracking system" 都挪到了最后一步);硬件限定 ✅ 仍在 —— **"wearable device"**,且仍需 "a tracking request from an application"。

---

## 3. US12210672 "notice of allowance" 核实结果

**判定:证实,且已被事实超越 —— 它不是"已允许待授",而是【已授权】。**

| 证据 | 来源 |
|---|---|
| `"U.S. Appl. No. 18/116,511, Notice of Allowance mailed Sep. 25, 2024", 7 pgs.` —— 逐字出现在 **US 12,704,900 B2 的 "Other References" 审查记录栏**(即 USPTO 在后续续案中正式引用的母案档案) | FreePatentsOnline US12704900 记录 |
| US 12,210,672 B2 **Publication Date: 01/28/2025**,Application Number 18/116,511 | FreePatentsOnline US12210672 记录 |
| `US12210672B2 · US202318116511A · 2025-01-28` 列于 INPADOC 族表;并有 `US CC — CERTIFICATE OF CORRECTION, 2025-03-25` 法律事件 | Espacenet(EPO)INPADOC 族/法律事件 |
| 授权原件 PDF(25 页,含第 25 页 Certificate of Correction)可从 USPTO `image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12210672` 直接下载 | USPTO 一手件 |
| 独立第三源逐字复现同一套权项文本 | PatentGuru US12210672B2 |

**⇒ 结论:先前调研报告的 "notice of allowance" 属实(2024-09-25 发出),但该申请已于 2025-01-28 以 US 12,210,672 B2 授权,并于 2025-03-25 作出一份纯排印更正。以"待授权"看待此件已过时。**

同时顺带核到母案的对应事件:`"U.S. Appl. No. 17/301,655, Notice of Allowance mailed Jan. 20, 2023"`;以及 18/116,511 的两次驳回(Non-Final 2024-02-27、Final 2024-06-20)——即**这一族的续案是经过实质审查、两次驳回后才允许的**,不是一路放行。

---

## 4. 族谱与仍在申请中的续案

**Espacenet/INPADOC 同族规模:9 件申请 / 15 件公开(family id 082118660)。**

### 4.1 美国链(全部已授权,无已公开的在审续案)

| 编号 | 申请号 / 日期 | 状态 | 独立权项一句话要旨 |
|---|---|---|---|
| US 63/131,981 | 2020-12-30 | 临时申请(已失效,仅作优先权) | — |
| **US 11,662,805 B2** | 17/301,655 / 2021-04-09 | **授权 2023-05-30,在册** | 检测到 AR 应用**未**请求跟踪 → 在 HMD 上离线跑 VIO 求第一标定参数并存储 → 收到跟踪请求时取出并据以求第二标定参数 |
| ├ US 2022/0206565 A1 | 同上 | 授权前公开 (2022-06-30) | 同上申请态 |
| **US 12,210,672 B2** | 18/116,511 / 2023-03-02(续案) | **授权 2025-01-28,在册**(COC 2025-03-25) | 在 HMD 的 **offline** 估计中**周期性**更新第一标定参数 → 收到跟踪请求 → **切换 offline→online** 并以该值为 **starting point** 求第二参数 |
| ├ US 2023/0205311 A1 | 同上 | 授权前公开 (2023-06-29) | 同上申请态 |
| **US 12,704,900 B2** | 18/970,124 / 2024-12-05(续案的续案) | **授权 2026-08-11,在册** | 在 **wearable device** 检测到 **calibration trigger event** → 求存第一参数 → 收到跟踪请求 → 以该值为 starting point 求第二参数(去掉了 offline/periodic) |
| ├ US 2025/0093948 A1 | 同上 | 授权前公开 (2025-03-20) | 同上申请态 |

**是否还有在审的美国续案?**
- **已公开范围内:没有。** 两次独立检索——FPO 标题检索 `TTL/"periodic parameter estimation"`(命中 6 件,全部为上表 3 专利 + 3 公开)、FPO 摘要+申请人检索 `ABST/"visual-inertial tracking system" AND AN/"Snap"`(命中 12 件,按时间倒序最新为 US12704900,本族之外命中的是另两族 *Direct scale level selection…* 与 *Long term in-field IMU temperature calibration*)——均无第 4 件本族公开。Espacenet INPADOC 族表同样只列出上述三个美国申请号。
- **未公开范围:🔴 无法排除,且这是本次检索最大的盲区。** US 12,704,900 于 2026-08-11 授权;按 Snap 在本族的既有做法(每件授权前都递交一件续案:2023-03-02 在 `'805` 授权前、2024-12-05 在 `'672` 授权后不久),**极可能存在一件 2026 年年中递交、尚未公开的第四件续案**。该类申请通常在递交后 3–4 个月才公开(优先权已过 18 个月),即最早约 2026-10~12 才可见。**⇒ "本族在美国是否还有活链" 的答案是:证据上不确定,倾向于有。**

### 4.2 国际链(**有两条确实在审的分案**)

| 编号 | 申请号 | 状态(INPADOC 事件) |
|---|---|---|
| **WO 2022/146786 A1** | PCT/US2021/064608,2021-12-21 申请,2022-07-07 公开 | PCT 已进入国家阶段;`WO WWG — GRANT IN NATIONAL OFFICE (EP), 2025-09-24` |
| **EP 4,272,053 B1** | EP 21844571 | **已授权 2025-09-24**;`EP 26N — NO OPPOSITION FILED, 2026-09-02` ⇒ 异议期已过,在册 |
| ├ EP 4,272,053 A1 | 同上 | 申请公开 2023-11-08 |
| **EP 4,645,041 A2 / A3** | **EP 25203697(分案)** | 🔴 **在审**:A2 公开 2025-11-05,A3(检索报告版)2026-01-28,`EP 17P — REQUEST FOR EXAMINATION FILED, 2026-08-19` |
| **KR 10-2932214 B1** | KR 10-2023-7025816 | 已授权,`KR Q13 — IP RIGHT DOCUMENT PUBLISHED, 2026-03-03`(审查经过:2025-03-20 驳回通知,2025-05-19 答复) |
| ├ KR 10-2023-0122157 A | 同上 | 申请公开 2023-08-22 |
| **KR 10-2026-0036392 A** | **KR 10-2026-7005604(分案)** | 🔴 **在审**,`KR Q12 — APPLICATION PUBLISHED, 2026-03-16` |
| **CN 116830067 A** | CN 国家阶段 | 公开 2023-09-29;`CN SE01 — ENTRY INTO FORCE OF REQUEST FOR SUBSTANTIVE EXAMINATION, 2023-10-20`。**当前是否已授权 NOT RETRIEVED** |

**⇒ 活链结论:即便美国侧暂无可见的在审续案,EP 分案(EP25203697)与 KR 分案(KR10-2026-7005604)两条都还活着,权项仍可针对新产品改写。** 对只在中国大陆/美国出货的产品,EP/KR 分案不直接构成风险;但它们证明这一族**在被主动维护和扩张**。

---

## 5. 对照表:特征 (A) 的要素 vs 权项限定语

我方特征 (A) 的要素拆解:
- **E1** 单目 VIO(RD-VIO/XRSLAM 谱系),**手机**为主要载体
- **E2** 在**正常跟踪运行中**(online,应用正在请求位姿)
- **E3** **每固定 N 秒**(5/10/15s)触发
- **E4** 重解**一个小状态子集**:metric scale factor **s** + 2DoF 重力方向
- **E5** 其余地图固定不动
- **E6** 初始化时解出的 s 作为本次优化的初值(工程上自然如此)

| 权项限定语 | 出处 | E1 | E2 | E3 | E4 | E5 | E6 | 判定 |
|---|---|---|---|---|---|---|---|---|
| "at a **head-mounted device**"(每一步) | '805 cl.1/11/20;'672 cl.1/11/20 | ❌ 手机不是 HMD | | | | | | **落外**(若出货形态为手机) |
| "a **wearable device**" | '900 cl.1/11/20 | ❌ 手机通常不属 "wearable" | | | | | | **落外**(同上;**若将来做眼镜则此项失效**) |
| "detecting … that a virtual object display application … **is not requesting tracking operations**" | '805 cl.1/11/20 | | ❌ 我们正在跟踪 | | | | | **落外(最硬的一条)** |
| "**during an offline** calibration parameter estimation …, performed **after an online** calibration parameter estimation" | '672 cl.1/11/20 | | ❌ 我们全程 online | | | | | **落外(最硬的一条)** |
| "**periodically** updating … a first calibration parameter value" | '672 cl.1/11/20 | | | ✅ 字面吻合 | | | | **落内,但被上一行的 offline 限定救回** |
| "detecting a **calibration trigger event**" | '900 cl.1/11/20 | | | ⚠️ 定时器是否算 "trigger event"? | | | | **不确定**,见下 |
| "**in response to detecting the tracking request**, using … as a **starting point** for estimating a second …" | '672、'900 全部独立权项 | | | | | | ⚠️ | **落外** —— 我们不是"在收到跟踪请求那一刻"才把存值当起点 |
| "a first/second **calibration parameter value**"(泛指,未限定种类) | 三件全部独立权项 | | | | ⚠️ 可能被解释为涵盖 s 与 g | | | **最不安全的一条,见下** |
| "storing … in a **storage/memory of the** [HMD/wearable] **device**" | 三件全部独立权项 | | | | | | ⚠️ | 我们也会存,**落内**(非区别点) |
| 数值间隔(N 秒) | **任何权项中都没有** | | | ✅ 无对应限定 | | | | 不构成限制 |
| "scale factor" / "gravity direction" | **权项与说明书中都没有** | | | | ✅ | | | 不构成限制,但也不排除泛指解释 |
| 保持地图其余部分固定(E5) | **任何权项中都没有** | | | | | ✅ | | 不构成限制 |

### 最可能的设计回避点(按强度排序)

1. **🥇 "online vs offline" 这一刀。** `'805` 的 *"is not requesting tracking operations"* 与 `'672` 的 *"during an offline calibration parameter estimation … performed after an online calibration parameter estimation"* 都要求参数估计发生在**应用不在用跟踪的时候**。我们的 (A) 定义上就在 online 主回路里跑。**只要 (A) 不额外增加一条"应用空闲时再跑一遍"的支路,这两件就打不到。**
2. **🥈 载体限定。** 三件全部要求 head-mounted / wearable。**手机形态直接落外。** 🔴 **但这是形态依赖的**:一旦产品线延伸到 AR 眼镜,这条保护立刻消失,回退到第 1 条独撑。说明书 [0032] 确实把 "mobile computing device … smart phone" 列为设备举例,所以**不能指望说明书帮我们缩小"wearable"**——反过来讲,权项写的是 wearable 而说明书举了手机,这更像是审查中被迫加的窄化语,字面仍限 wearable。
3. **🥉 "as a starting point … in response to detecting the tracking request"。** `'672`/`'900` 都要求"跨越一次应用启动边界"把旧值传递过去。我们的 (A) 是同一 session 内的连续重优化,不跨这个边界。

### 需要律师重点看的两处不确定

- **⚠️ "calibration parameter value" 的解释范围。** 权项完全未限定参数种类。若被功能性地解释为"VIO 系统里任何需要标定/估计的量",metric scale 与重力方向**可能**被纳入。**反证材料(已固定):** 说明书全文 `gravity` **0 命中**、`scale`(尺度义)**0 命中**;说明书对该术语的全部举例是 extrinsics / intrinsics / IMU biases / frame bending / auto exposure —— 即**都是"传感器标定量",而 metric scale 与重力方向是"状态量/世界参考系量",不是传感器标定量**。这条区分是我们最好的说明书支撑,但**术语解释必须由律师做**。
- **⚠️ `'900` 的 "calibration trigger event" 是否涵盖"每 N 秒的定时器"。** `'900` claim 1 没有说 trigger 是什么;从属 4/5/6 才举例(sensor threshold、温度/加速度/电量、检测到被佩戴)——按 claim differentiation,独立权项的 "trigger event" **比这些例子宽**。一个周期性定时器**有可能**被读成 trigger event。**但 `'900` claim 1 仍另需"wearable device"+"in response to detecting the tracking request, using … as a starting point",我们两条都不满足。**

### 关于特征 (B)(ICE-BA 相对边缘化先验,g_k0 = R_k0 · g)

**本族三件专利的权项与说明书均未涉及边缘化先验、bundle adjustment、相对参考系存储等机制**(说明书 `bundle adjust` 0 命中)。⇒ **这一族对 (B) 无对应权项。** 🔴 但请注意:**本次检索范围仅限任务指定的 Snap 这一族,未对 (B) 做独立的专利检索**,因此"(B) 无专利风险"这个结论**本报告不提供**,需另做一次针对性检索(MagicLeap US11328475 "Gravity estimation and bundle adjustment for visual-inertial odometry" 一族此次亦不在检索范围内)。

---

## 6. 检索方法、取到与没取到的

**一手/准一手来源(claim 文本经两个独立来源逐字比对一致):**
- USPTO 官方授权件 PDF:`image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/{11662805|12210672}`(影像版,无文字层;COC 页经渲染后肉眼核读)
- FreePatentsOnline(`freepatentsonline.com/{11662805|12210672|12704900}.html`)—— 权项与著录项目
- PatentGuru(`patentguru.com/US{11662805|12210672|12704900}B2`)—— **独立第二源,权项逐字一致**(包括 `'805` claim 1 末尾原文中的排印错误 *"the **virtual**-inertial tracking system"* 两源同样出现,可作保真度校验)
- Espacenet / EPO INPADOC(浏览器渲染)—— 同族 9 申请 15 公开、逐件法律事件、各国状态

**NOT RETRIEVED(及尝试记录):**
| 缺口 | 尝试过 | 结果 |
|---|---|---|
| USPTO **continuity data**(有无第 4 件在审续案) | `patentcenter.uspto.gov/retrieval/public/v{1,2,3}/application/data?applicationNumberText=18970124`;真实浏览器打开 Patent Center 应用页 | **接口对任何方法返回 405**,连 Patent Center 自己的前端都拿不到数据(已在浏览器 network 面板确认三个 v3 请求全部 405)⇒ 上游接口故障/封锁,非本地问题 |
| **实际年费缴纳记录** | `fees.uspto.gov/MaintenanceFees/fees/details`(Akamai 挑战,HTTP 202 空体)、`bulkdata.uspto.gov` MaintFeeEvents(DNS 不可解析)、`api.uspto.gov` ODP(401,需 API key)、PatentsView(已迁移至需 key 的 ODP) | 全部失败。**替代证据**:INPADOC 事件表中 `'805` 授权后无 MAFP 事件 + 按授权日推算首笔年费窗口至 2026-11-30 才截止 ⇒ 可确定"尚未失效",但"是否已缴"未取到 |
| **PTA / terminal disclaimer** | 仅可从授权件首页取,而 USPTO PDF 无文字层 | 未 OCR;**名义届满日 2041-04-09 为按 20 年推算,未计 PTA** |
| Google Patents 的 Events / Also-published-as | `patents.google.com` 直连与浏览器两路 | **持续 503 "Sorry" 反爬** + 浏览器端 `/patent/US12704900B2/en` 返回 404(Google 尚未收录该 2026-08 授权件)⇒ 改由 Espacenet 取得同等信息 |
| CN 116830067 A 当前法律状态 | INPADOC 仅到 2023-10-20 实审生效 | 未进一步查 CNIPA |

---

## 7. 免责声明

**本文件是事实搜集(fact-gathering),不是法律意见,也不构成 freedom-to-operate 结论或侵权/不侵权判断。** 上文所有"落内/落外/设计回避点"的标注,只是把我方拟建特征的要素与权项的字面限定语做**逐词对照的事实陈列**,**不代表任何权项解释结论**。权项解释(claim construction)、等同原则(doctrine of equivalents)、审查历史禁反言(prosecution history estoppel)、间接侵权、以及未公开在审续案的潜在权项范围,**必须由持证专利律师基于完整的审查档案(file wrapper)判断**。特别提示三点:(1) 美国侧很可能存在一件尚未公开、因而本次检索不可见的第四件续案;(2) 产品形态若从手机延伸到头戴/可穿戴设备,本报告中最强的一条区别点立即失效;(3) "calibration parameter value" 一词未经任何权项内定义,其解释范围是本族对我方的主要不确定性来源。

**Sources:** [FreePatentsOnline US11662805](https://www.freepatentsonline.com/11662805.html) · [FreePatentsOnline US12210672](https://www.freepatentsonline.com/12210672.html) · [FreePatentsOnline US12704900](https://www.freepatentsonline.com/12704900.html) · [PatentGuru US11662805B2](https://www.patentguru.com/US11662805B2) · [USPTO PDF US11662805](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11662805) · [USPTO PDF US12210672](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12210672) · [Espacenet US11662805B2 (INPADOC family / legal events)](https://worldwide.espacenet.com/patent/search?q=pn%3DUS11662805) · [USPTO Patent Center](https://patentcenter.uspto.gov/) · [USPTO Maintain your patent](https://www.uspto.gov/patents/maintain)
