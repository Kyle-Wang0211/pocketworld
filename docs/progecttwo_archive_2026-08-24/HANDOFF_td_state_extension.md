# Blocker 01 的另一半:把 td 加进误差状态的可行性与改造方案

日期:2026-08-23
性质:**只读扫描 + 报告**。没有改 `/Users/kaidongwang/Developer/xrslam` 的任何文件(那棵树由另一个 workflow 并发写入)。
本轮唯一执行过的代码在 scratchpad,是两个**独立的 Eigen 探针**,用来把报告里两条最吃重的断言变成实测结论。

---

## 0. 一句话结论

**td 可以进状态量,代价是「大但可控」;真正难的只有两处,而其中最难的那处(td 的雅可比)在读完代码后塌缩成了 4 行链式法则。**
**内参(Blocker 04 第二层)不是同一类改造 —— 它是把残差从 bearing 空间搬回像素空间的架构反转,量级完全不同,建议判死。**
**外参介于两者之间,但被一个 Ceres 的硬约束卡住(参数块按指针识别,而 `frame->camera` 是逐帧拷贝)。**

---

## 1. 现状:读穿之后的状态表示与优化结构

### 1.1 误差状态只有 15 维,且 `ES_*` 一枚硬币两面用

`xrslam/src/xrslam/estimation/state.h:12-19`

```
ES_Q = 0, ES_P = 3, ES_V = 6, ES_BG = 9, ES_BA = 12, ES_SIZE = 15
```

`ES_SIZE` 出现的**全部**位置(排除 build 目录):

| 文件 | 次数 | 性质 |
|---|---|---|
| `xrslam/src/xrslam/estimation/ceres/marginalization_factor.h` | **116** | 真正的战场 |
| `xrslam/src/xrslam/estimation/marginalization_factor.h` | 3 | 先验矩阵开尺寸(L28-30) |
| `xrslam/src/xrslam/estimation/state.h` | 1 | 定义 |
| `xrslam-interface/src/XRSLAMManager.cpp` | 2 | 注释/告警文案(另一 workflow 本轮加的) |
| `xrslam-interface/include/XRSLAM.h` | 1 | 注释 |

`ES_Q/ES_P/ES_V/ES_BG/ES_BA` 的分布:

| 文件 | 次数 |
|---|---|
| `ceres/marginalization_factor.h` | 65 |
| `ceres/preintegration_factor.h` | **28** |
| `preintegrator.cpp` | 12 |
| `state.h` | 5 |
| `marginalization_factor.h` | 2 |

🔴 **这里藏着本次调查最重要的一条发现。**
`ceres/preintegration_factor.h` 里那 28 处 `ES_*`,**不是**在给误差状态开索引,而是在给**它自己那条 15 维残差**开索引:

- L14 `ceres::SizedCostFunction<15, 4,3,3,3,3, 4,3,3,3,3>` —— 字面量 15
- L59 `map<vector<15>> r(residuals);` —— 字面量 15
- L60-68 `r.segment<3>(ES_Q) = ... ; r.segment<3>(ES_BA) = ...`

也就是说 **IMU 因子的残差维度**和**误差状态维度**今天恰好都等于 15,代码把这两个语义完全不同的量用了同一套常量。td 一旦让 `ES_SIZE` 变成 16,这两个语义就分家了 —— 而分家的地方一部分会**响**(编译错),一部分会**哑**(静默出垃圾)。

### 1.2 滑窗与边缘化

- 窗长由 `config->sliding_window_size()` 钉死(基类默认 10,`configs/iphone_slam.yaml` 也是 10)。
- `sliding_window_tracker.cpp:432-455 slide_window()` → `map->marginalize_frame(0)`;
  `map.cpp:51-63` 断言 `index == 0`,只支持边缘化最老帧。
- 边缘化是**手写的 Schur**,不是 Ceres 自带的。全部在
  `xrslam/src/xrslam/estimation/ceres/marginalization_factor.h:74-476 marginalize()`,四个 scope:
  1. **L107-161 边缘化因子自身**:把上一轮的先验重新线性化,累加进 `pose_motion_infomat`。
  2. **L163-231 预积分因子**:对 victim 前后两条 IMU 边求雅可比,累加。
  3. **L233-380 重投影因子**:对 victim 帧上每条 track 的每个观测求雅可比,累加;
     同时把「landmark ↔ pose」的耦合块攒进 `LandmarkInfo::h`(`matrix<1,6>`,只有 Q/P)。
  4. **L382-398 消 landmark**:`info.mat` 是标量(逆深度 1 维),直接 `h^T * (1/mat) * h` 减掉。
  5. **L400-438 消 victim 帧**:把 victim 换到 `last_index`,做 15×15 的舒尔补,
     幸存部分是**连续前缀** `[0, ES_SIZE*last_index)`。
  6. **L440-474 重建先验**:`SelfAdjointEigenSolver` 特征分解 → `sqrt_inv_cov` / `infovec`,
     阈值 `1.0e-8` 截断零特征值;重设 `set_num_residuals` 与 `mutable_parameter_block_sizes`。

先验因子本身:`CeresMarginalizationFactor`(L12-72),残差维 `frames.size() * ES_SIZE`,
**每帧 5 个参数块**(4,3,3,3,3),`Evaluate` 里用 `parameters[5*i + k]` 取。

### 1.3 Ceres 的参数块/残差块怎么组织

`xrslam/src/xrslam/estimation/solver.cpp`:

- `add_frame_states`(L90-112):`q(4, 带 manifold)`、`p(3)`、`v/bg/ba(3,3,3)`;
  `FT_FIX_POSE` / `FT_FIX_MOTION` 走 `SetParameterBlockConstant`。
- `add_track_states`(L114-116):`&track->landmark.inv_depth`,1 维。
- 六种残差块(L118-187),`SizedCostFunction` 声明全在 `estimation/ceres/*.h`:

| 因子 | 声明 | 残差维 | 参数块 |
|---|---|---|---|
| `CeresReprojectionErrorFactor` | `reprojection_factor.h:15` | 2 | 4,3,4,3,1 |
| `CeresReprojectionPriorFactor` | `reprojection_factor.h:101` | 2 | 4,3 |
| `CeresRotationPriorFactor` | `rotation_factor.h:13` | 2 | 4 |
| `CeresDepthPriorFactor` | `depth_factor.h:15` | 1 | 1 |
| `CeresPreIntegrationErrorFactor` | `preintegration_factor.h:14` | 15 | 4,3,3,3,3,4,3,3,3,3 |
| `CeresPreIntegrationPriorFactor` | `preintegration_factor.h:168` | 15 | 4,3,3,3,3 |
| `CeresMarginalizationFactor` | 动态 `CostFunction` | `n*15` | `n*(4,3,3,3,3)` |

求解器设置(L189-203):`SPARSE_SCHUR` + `DOGLEG`,`num_threads = 1`。

**全仓一共 8 处 solver 装配**,每一处都必须处理 td 的绑定/固定:

| # | 位置 | 用途 | 含重投影? |
|---|---|---|---|
| 1 | `initializer.cpp:88` | 初始化 BA | ✔ (L117) |
| 2 | `initializer.cpp:308` | 逐帧 PnP | ✔ (L318) |
| 3 | `initializer.cpp:340` | refine(`with_motion=false`) | ✔ (L369) |
| 4 | `feature_tracker.cpp:399` | 最新帧定位 | ✔ (L409) |
| 5 | `sliding_window_tracker.cpp:136` | `localize_newframe` | ✔ (L153) |
| 6 | `sliding_window_tracker.cpp:310` | **`refine_window` 主 BA** | ✔ (L366) |
| 7 | `sliding_window_tracker.cpp:479` | `refine_subwindow` A | ✔ (L503,506) |
| 8 | `sliding_window_tracker.cpp:517` | `refine_subwindow` B | ✔ (L537,541) |

### 1.4 `camera_time_offset` 到底死在哪

| 位置 | 行为 |
|---|---|
| `xrslam/include/xrslam/xrslam.h:105` | 纯虚声明 |
| `xrslam-extra/src/xrslam/extra/yaml_config.cpp:195, 452` | 解析 + 返回 |
| `xrslam/src/xrslam/config.cpp:139-140` | 打印 |
| `xrslam-pc/player/src/IO/tum_dataset_reader.cpp:16,18` | **离线**:加到 image 时间戳上 |
| `xrslam-pc/player/src/IO/euroc_dataset_reader.cpp:16,18` | 同上 |
| `xrslam/src/**` | **零消费** |

⇒ **在线路径(iOS/Android)上这个值连「常数偏移」都没被用**,只有离线 player 会加。
另一个 workflow 本轮已经把这件事变成了显式告警(`XRSLAMManager.cpp:411`)。

### 1.5 三个必须先摆上台面的结构事实

**(a) 残差在单位球上,不在像素平面上。**
`Frame` 存的是 `std::vector<vector<3>> bearings`(`frame.h:81`),`get_keypoint` 还带
`runtime_assert(|norm - 1| <= 0.001)`(`frame.h:42-43`)。
`CeresReprojectionErrorFactor` 构造时(`reprojection_factor.h:20-22`)从观测 `z` 建
`local_tangent`(`s2_tangential_basis(z)` + `z`),残差是
`r = (local_tangent^T · y_tgt).hnormalized()`。
**观测只通过 `local_tangent` 进入残差,而 `local_tangent` 是构造期缓存的。**

**(b) `Frame` 自己没有时间戳。**
唯一的时间来源是 `frame->image->t`(`Image::t`,`xrslam.h`),以及 `PreIntegrator::Delta::t`
和 `ImuData::t`(`common.h:62-66`)。而 `feature_tracker.cpp:164` 会调
`last_frame->image->release_image_buffer()` —— 释放的是像素缓冲,`Image` 对象和 `t` 仍在,
所以 `frame->image->t` 在滑窗里可用,但这是个隐式依赖,td 上线前应该把时间戳提升为 `Frame` 的一等成员。

**(c) 内参和外参今天都是「逐帧拷贝的 yaml 常数」。**
`detail.cpp:171-183 track_camera()`:
```
173: frame->K = config->camera_intrinsic();
176: frame->sqrt_inv_cov = frame->K.block<2,2>(0,0);
177-178: sqrt_inv_cov(i,i) /= sqrt(keypoint_noise_cov()(i,i));
179-180: frame->camera.q_cs / p_cs = config->camera_to_body_*();
181-182: frame->imu.q_cs / p_cs   = config->imu_to_body_*();
```
注意 **L176-178:白化矩阵 `sqrt_inv_cov` 是从 K 推出来的**。K 一旦变成状态量,白化也变成状态相关。

🔴 **并且畸变在在线路径上根本没被建模**:
`OpenCvImage::correct_distortion` 在全仓(排除 build)**零调用点**,只有声明
(`opencv_image.h:43`)和定义(`opencv_image.cpp:163`);
`config->camera_distortion()` 的消费者只有两个离线 reader
(`euroc_dataset_reader.cpp:63`、`tum_dataset_reader.cpp:65`)。
`remove_k`(`geometry/stereo.h:12-15`)是**纯针孔逆**,不含畸变。
⇒ 畸变系数和 `camera_time_offset` 一样,是第二个死旋钮。

---

## 2. 实测:两条断言,一条响一条哑

我没有构建 xrslam(见 §7 内存约束),但把两条会决定方案形状的断言写成了**独立 Eigen 探针**跑了出来。

### 探针 1 —— 静默腐蚀(这是本次调查抓到的地雷)

复刻 `ceres/marginalization_factor.h:188-212` 的确切写法:
```cpp
vector<ES_SIZE> piresidual;                        // L188
matrix<ES_SIZE, 4, true> dr_dqi, dr_dqj;           // L189
matrix<ES_SIZE, 3, true> dr_dpi, dr_dpj;           // L190
...                                                 // L191-193
picost->Evaluate(..., pijacobians.data());         // L198-199 —— 因子只写 15 行
matrix<ES_SIZE, ES_SIZE> dr_dstates_i, dr_dstates_j;  // L200
dr_dstates_i.block<ES_SIZE,3>(0, ES_Q) = dr_dqi.block<ES_SIZE,3>(0,0);  // L201-202
```
`dr_dqi` 用 **`ES_SIZE`** 开行数,但写它的 `CeresPreIntegrationErrorFactor` 残差维是**字面量 15**。

探针源码:`/private/tmp/claude-501/.../scratchpad/es_size_probe.cpp`
```
clang++ -std=c++17 -O0 -I/opt/homebrew/include/eigen3 es_size_probe.cpp -o es_size_probe
BUILD_EXIT=0

--- ARM A: today (ES_SIZE=15) ---
A  ES_SIZE=15, IMU factor writes 15 rows   ES=15 factor_writes=15  poisoned_cells=  0  infomat_sane=YES
--- ARM B: naive td bump (ES_SIZE=16), factor unchanged ---
B  ES_SIZE=16, IMU factor still writes 15  ES=16 factor_writes=15  poisoned_cells=  4  infomat_sane=NO
--- NEGATIVE CONTROL: same ES=16 but factor also widened ---
C  ES_SIZE=16, factor widened to 16 rows   ES=16 factor_writes=16  poisoned_cells=  0  infomat_sane=YES

RESULT: A_poison=0  B_poison=4  C_poison=0
CLAIM: CONFIRMED
RUN_EXIT=0
```

**结论**:把 `ES_SIZE` 从 15 改成 16、而不动 `preintegration_factor.h`,
**代码照常编过**,`dr_dqi` 最后一行(4 个 double)从未被写,
信息矩阵 `dr_dstates^T · dr_dstates` 被未初始化内存污染。
在真实栈上这不是 `1e99` 而是随机残留 —— 也就是**每次运行不一样、时好时坏**的那种 bug。

**负向对照**:C 臂(因子同步加宽到 16 行)`poisoned_cells=0`。
说明探针不是「怎么跑都红」,它确实在区分两种情况。

### 探针 2 —— 编译期绊线(这条是好消息)

`ceres/marginalization_factor.h:402` 有一处**没跟着 `ES_SIZE` 走的字面量**:
```cpp
matrix<15, 15> inv_infomat =
    pose_motion_infomat.block<ES_SIZE, ES_SIZE>(...).inverse();
```
探针 `tripwire.cpp`:
```
--- ES_SIZE=15 ---   (无输出 = 编译通过)
--- ES_SIZE=16 ---
error: static assertion failed ... YOU_MIXED_MATRICES_OF_DIFFERENT_SIZES
```
⇒ 这一处会**响**,不会哑。它其实是唯一一道免费的保险丝。

**两条合起来的定则:`ES_SIZE` 的字面量 15 分两类,必须分开处理 ——
「误差状态维」跟着 td 走,「IMU 残差维」不跟着走。今天它们共用一个名字,这就是全部风险的来源。**

---

## 3. 对照 VINS-Mono:公式可以抄,代码不能抄

⚠️ **VINS-Mono 是 GPLv3。本报告只引用其论文中的公式,不得复制其任何源码。**
下面每条公式都标注了出处,实现必须由我们自己从公式重新写起。
同理,ByteDance 那份参考实现(`github.com/bytedance/Ts_Online_Optimization`)在动它之前必须先单独做许可审计 —— **论文本身是 CC BY-NC-ND 4.0,这个许可对代码复用是不友好的**,默认按「只看论文」处理。

### 3.1 VINS-Mono 的做法(Qin & Shen, IROS 2018, arXiv:1808.00692)

- **式 (2)** 像素速度,来自光流相邻帧位移:
  `V_l^k = ([u_l^{k+1}, v_l^{k+1}]^T − [u_l^k, v_l^k]^T) / (t_{k+1} − t_k)`
- **式 (4)** 把观测按 td 平移,再写残差:
  `z_l^k(td) = [u_l^k, v_l^k]^T + td · V_l^k`
  `e_l^k = z_l^k(td) − π(R_{c_k}^{w T} (P_l − p_{c_k}^w))`
- **式 (7)** td 是**单个全局标量**,和所有位姿、所有特征一起联合优化:
  `X = [x_0, x_1, …, x_n, P_0, P_1, …, P_l, td]`
- 因为 `z(td)` 对 td 是线性的,`∂e/∂td = V_l^k`,雅可比是白送的。

### 3.2 为什么这条路接进 RD-VIO 反而别扭

1. **RD-VIO 的残差不在像素平面上**(§1.5(a))。要用式 (4),得先把像素速度换成 bearing 空间的速度,
   而 bearing = `remove_k(pixel, K).normalized()` 是非线性的(带归一化)。
2. **更硬的一条**:观测 `z` 只通过 `local_tangent` 进残差,而 `local_tangent` 是
   `reprojection_factor.h:20-22` 在**构造函数里算一次就缓存**的。
   观测随 td 移动 ⇒ 切空间基也得跟着变 ⇒ 要么每次 `Evaluate` 重算 `s2_tangential_basis`
   (对每帧上万个观测,是热路径上的额外开销,和「热稳定是硬约束」直接冲突),
   要么把基固定当作一阶近似 —— 但那样 td 的雅可比就不再是干净的 `V`。
3. RD-VIO 的前端确实有 KLT 光流(`frame.cpp:76-108 track_keypoints`),像素速度**拿得到**,
   但 `feature_tracker_predict_keypoints()` 分支还会用 IMU 先预测再跟踪(`frame.cpp:84-95`),
   「相邻帧位移 / dt」这个量的含义会被预测污染。

### 3.3 更合身的第二条路(ByteDance, arXiv:2501.01788)

该文明确批评 VINS 那条路「高度依赖光流精度,换个前端就不适用」,提出改为
**把 IMU 位姿插值到图像时间戳**,而不是平移观测:

- **式 (11)**:`δR_ij = (I + [ω_j Δtd_j]_×)`,`P̌ = P + v · Δtd_j`
- **式 (13)**:`J_td = R_ic^T [P̌_fk]_× ω_j − R_ic^T Ř^T v`

### 3.4 🔑 把 3.3 接进 RD-VIO 之后,td 的雅可比塌缩成 4 行

这是本次调查最有价值的一条,推导如下:

补偿后的位姿是
`p̌(td) = p + v_world · td`,`q̌(td) = q ⊗ exp(ω_body · td)`

`quaternion_parameterization.h:14` 的 `Plus` 是
`result = q * expmap(dq)` —— **右扰动、体坐标系**。
所以 td 的一阶扰动**恰好就是一个位姿扰动** `(δp = v·td, δθ = ω·td)`。
链式法则直接给出:

```
∂r/∂td_tgt = dr_dp_tgt   · v_tgt + dr_dq_tgt.block<2,3>(0,0) · ω_tgt
∂r/∂td_ref = dr_dp_ref   · v_ref + dr_dq_ref.block<2,3>(0,0) · ω_ref
```

而 `dr_dp_tgt`、`dr_dq_tgt`、`dr_dp_ref`、`dr_dq_ref`
**是 `reprojection_factor.h:60-79` 已经在算的四块**。td 的雅可比是它们的线性组合,不需要任何新推导。

两个量的口径(不能弄错,弄错了是静默错):
- `v` = `frame->motion.v`,**世界系**。依据:`preintegration_factor.h:65`
  `r.segment<3>(ES_V) = q_i.conjugate()*(v_j − v_i − dt*gravity) − …`,v 出现在未旋转的世界系差里。
- `ω` = **体(center)系**角速度 = `frame->imu.q_cs * (w_gyro − bg)`。
  依据:位姿参数块是 center 系(`preintegration_factor.h:41-44` 用 `imu.q_cs` 从 center 转到 imu),
  而右扰动 `δθ` 就在 center 系。陀螺给的是 imu 系,所以必须过 `imu.q_cs`。

**代价**:`Frame` 需要新增一个 `vector<3> w`(帧时刻的体系角速度),
在 `detail.cpp` / `feature_tracker.cpp` 组帧时填,**并且 `frame.cpp:21-38 clone()` 必须复制它**
—— 漏了就是静默丢失(`clone()` 现在逐个字段手写复制,漏一个不会有任何提示)。

### 3.5 全局 td 还是逐帧 td?

VINS 用**全局单标量**(式 7)。但 RD-VIO 的边缘化布局是**严格逐帧**的:
`pose_motion_infomat` 是 `frame_num * ES_SIZE` 见方,
L400-438 的 victim 舒尔补依赖「幸存者是连续前缀、victim 在最后」。
一个全局量在这个布局里**没有位置** —— 要塞进去就得把布局改成
`[frames | globals]` 并给 victim 消元加置换,那是伤筋动骨。

**建议:用逐帧 td + 帧间随机游走先验。**
理由是这个模式在代码里**已经存在**:`preintegration_factor.h:67-68`
```
r.segment<3>(ES_BG) = bg_j - bg_i;
r.segment<3>(ES_BA) = ba_j - ba_i;
```
bg/ba 就是「逐帧状态 + 帧间随机游走」。td 完全照抄这个形状,
边缘化布局一行都不用改(`ES_TD = 15, ES_SIZE = 16`,追加在**末尾**)。

代价是 10 帧窗口里 td 从 1 个自由度变成 10 个 —— 但配一个足够紧的随机游走
(td 的真实漂移是 ppm 级,σ 可以设得很小),这 10 个数会被先验绑成一个数,
实际可观测性损失可以忽略。

⚠️ **必须追加在末尾,不能插在中间。** 因为:
- `ES_Q=0, ES_P=3` 的相邻性被 `marginalization_factor.h:367,369,374,376` 的
  `h.segment<3>(ES_Q - ES_Q)` / `h.segment<3>(ES_P - ES_Q)`,以及 L82 的 `matrix<1,6> h`
  和 L389-396 的 `block<6,6>` / `segment<6>(ES_SIZE*i + ES_Q)` 直接依赖;
- `ES_V/ES_BG/ES_BA` 的 6/9/12 被 **IMU 因子当作它自己 15 维残差的索引**用
  (`preintegration_factor.h:60-68`)。动它们等于同时动两套语义。

### 3.6 随机游走因子:新写一个,别动预积分

有两种接法:
- **(b) 把 td 塞进 IMU 预积分残差**(`r(ES_TD) = td_j − td_i`)。要改
  `SizedCostFunction<15,…>` → 16、`preintegrator.h:17-18 matrix<15> cov` → 16、
  以及 `preintegrator.cpp` 里 15×15 的协方差传播 F/G。**在 IMU 热内循环里。**
- **(b') 新写一个独立的 `TdRandomWalkFactor`**,`SizedCostFunction<1, 1, 1>`,
  残差 `(td_j − td_i) / (σ_td · sqrt(dt))`,雅可比是 ±1/(σ√dt)。

**选 (b')。** 它让 `preintegrator.{h,cpp}` 和 `preintegration_factor.h` 的
**残差维永远停在 15**,§2 探针 1 的那颗地雷因此被绕开而不是被踩响。

---

## 4. 可执行的改造方案

### 阶段 0 —— 先修「哑」,不加功能(**这一步单独验证、单独合入**)

目的:把「误差状态维」和「IMU 残差维」两个语义拆开。**在 `ES_SIZE` 还是 15 的时候做完**,
所以它是构造性 no-op,可以用**逐位相同**当判据。

| # | 文件:行 | 改动 |
|---|---|---|
| 0.1 | `estimation/state.h:12-19` | 新增独立常量 `PI_RES_SIZE = 15`(IMU 因子残差维),`ES_*` 保持不动 |
| 0.2 | `estimation/ceres/preintegration_factor.h:14, 59, 72, 87, 93, 100, 112, 120, 131, 137, 143, 149, 168` | 13 处字面量 `15` → `PI_RES_SIZE` |
| 0.3 | `estimation/preintegrator.h:17, 18` | `matrix<15> cov / sqrt_inv_cov` → `matrix<PI_RES_SIZE>` |
| 0.4 | `estimation/preintegrator.cpp:125` | `Eigen::LLT<matrix<15,15>>` → `matrix<PI_RES_SIZE, PI_RES_SIZE>` |
| 0.5 | `estimation/ceres/marginalization_factor.h:188-193` | `vector<ES_SIZE> piresidual` 与 10 个 `matrix<ES_SIZE, N, true>` 的**行数** → `PI_RES_SIZE`。**这是探针 1 抓到的那一处** |
| 0.6 | 同上 `:200-212` | `matrix<ES_SIZE, ES_SIZE> dr_dstates_i/j` → `matrix<PI_RES_SIZE, ES_SIZE>`;10 处 `.block<ES_SIZE,3>` → `.block<PI_RES_SIZE,3>`。(L215-229 的 `dr_dstates^T · dr_dstates` 仍是 ES×ES,自动正确) |
| 0.7 | 同上 `:402` | `matrix<15,15>` → `matrix<ES_SIZE, ES_SIZE>`(探针 2 那条绊线,让它正确而不是靠它报警) |

**验证判据(不许匹配自己写的注释)**:
`PI_RES_SIZE == ES_SIZE == 15` 时,同一段离线序列跑出来的轨迹必须与改动前**逐位相同**。
拿 `xrslam-pc/player` 跑 EuRoC,`diff` 输出的位姿文件。
**负向对照**:故意把 0.5 里某一个 `PI_RES_SIZE` 写回 `ES_SIZE` 并同时把 `ES_SIZE` 临时设成 16,
探针 1 已经证明这会产生污染 —— 轨迹应当变化甚至发散。

### 阶段 1 —— 引入 td 状态量(仍然冻结,`SetParameterBlockConstant`)

| # | 文件:行 | 改动 |
|---|---|---|
| 1.1 | `state.h:18` | `ES_TD = 15, ES_SIZE = 16` |
| 1.2 | `map/frame.h:68-71` 附近 | 新增 `double td = 0.0;` 与 `vector<3> w;`(体系角速度) |
| 1.3 | `map/frame.h:17-22` | 新增 `FT_FIX_TD` tag |
| 1.4 | `map/frame.cpp:21-38 clone()` | **复制 `td` 与 `w`** —— 漏了是静默错 |
| 1.5 | `core/detail.cpp:171-183` | 组帧时填 `frame->w`(从 `frontal_imus` 取帧时刻陀螺,减 bg,过 `imu.q_cs`);`frame->td` 初值取 `config->camera_time_offset()` —— **这也顺手把那个死旋钮接活了** |
| 1.6 | `estimation/solver.cpp:90-112` | `add_frame_states` 增 `AddParameterBlock(&frame->td, 1)` + `FT_FIX_TD` → `SetParameterBlockConstant` |
| 1.7 | `estimation/ceres/marginalization_factor.h:18-24, 30-34, 46-66, 109-128, 136-148, 458-472` | 每帧参数块 5 → 6;所有 `5*i + k` → `6*i + k`;残差/雅可比增加 `ES_TD` 那一行 |
| 1.8 | `estimation/marginalization_factor.h:28-32` | 尺寸自动跟 `ES_SIZE` 走,无需改;但要确认 `sqrt_inv_cov.block<3,3>(ES_P,ES_P)` 的 1e15 强先验语义不受影响 |
| 1.9 | `estimation/solver.cpp:175-187` | `add_factor(MarginalizationFactor*)` 的 `params` 每帧 push 6 个 |

**验证判据**:td 全程 `SetParameterBlockConstant` 且初值 = 0 时,轨迹必须与阶段 0 结束时**逐位相同**。
这一步把「布局改造」和「新残差」彻底分开,任何数值变化都只可能来自布局 bug。
**负向对照**:把某一帧的 td 初值设成 0.03s 而仍然冻结 —— 轨迹**不应**变化(因为还没有任何因子消费 td);
若变了,说明 1.7 的索引改错了。

### 阶段 2 —— 让 td 真正进残差

| # | 文件:行 | 改动 |
|---|---|---|
| 2.1 | `estimation/ceres/reprojection_factor.h:15` | `SizedCostFunction<2,4,3,4,3,1>` → `<2,4,3,4,3,1,1,1>`(td_tgt, td_ref) |
| 2.2 | 同上 `:27-50` | 用补偿位姿:`p̌_tgt = p_tgt + v_tgt·td_tgt`,`q̌_tgt = q_tgt ⊗ exp(ω_tgt·td_tgt)`,ref 同理 |
| 2.3 | 同上 `:52-84` | 新增 `jacobians[5]`/`jacobians[6]`,内容即 §3.4 的两行链式组合 |
| 2.4 | `estimation/ceres/reprojection_factor.h:101` | prior 版 `<2,4,3>` → `<2,4,3,1>`,`params` 数组 5 → 7 |
| 2.5 | `estimation/ceres/rotation_factor.h:13` | 子帧旋转先验。**建议:子帧上 td 保持冻结**,这样这个文件一行不动(RD-VIO 的子帧是纯旋转帧,td 在那里本来就不可观测) |
| 2.6 | 新文件 `estimation/td_factor.h` + `estimation/ceres/td_factor.h` | `TdRandomWalkFactor`,`SizedCostFunction<1,1,1>` |
| 2.7 | `estimation/solver.{h,cpp}` | `create_td_randomwalk_factor` / `add_factor` / `manage_factor` 三件套;重投影 `AddResidualBlock` 增两个 td 指针 |
| 2.8 | **`estimation/ceres/marginalization_factor.h:233-380`** | 重投影 scope 增加 td 列的信息累加 |
| 2.9 | **同上 `:82, 365-378, 382-398`** | 🔴 **最难的一处**:`LandmarkInfo::h`(声明在 L82)从 `matrix<1,6>` 拆成 `h_pose(1×6) + h_td(1×1)`,因为 `ES_TD=15` 与 `ES_Q=0..ES_P=5` **不连续**;L389-396 的 `block<6,6>` / `segment<6>` 舒尔消元要拆成 pose-pose / pose-td / td-td 三类 |
| 2.10 | 同上,新 scope | 仿照 L163-231,为 `TdRandomWalkFactor` 加一段信息累加(~40 行) |
| 2.11 | `core/initializer.cpp:88, 308, 340` | 初始化阶段 **td 一律冻结**(尺度/重力没起来之前 td 不可观测) |
| 2.12 | `core/sliding_window_tracker.cpp:136, 310, 479, 517` | 主 BA(310)解冻 td;`localize_newframe`(136)与两处 subwindow 冻结 |
| 2.13 | `xrslam.h:95-150` + `config.cpp` + `yaml_config.{h,cpp}` | 新增 `estimate_td()` bool 与 `td_random_walk_noise()`。**这是开发期旋钮,不是用户可见档位** |

**验证判据**:
1. `estimate_td() == false` 时,轨迹与阶段 1 结束时**逐位相同**(开关的无损性)。
2. `estimate_td() == true` 且用 EuRoC(硬件同步,真值 td ≈ 0)时,td 应收敛到 |td| < 2ms。
3. **决定性实验**:给 EuRoC 的图像时间戳人为注入已知偏移(如 +25ms),
   td 必须收敛到 −25ms ± 3ms,且轨迹 ATE 恢复到无偏移时的水平。
   **这是唯一能证明 td 真的在工作而不是在吸收别的误差的判据。**
4. **负向对照**:把 2.3 的 td 雅可比乘 −1(符号写反)。实验 3 必须失败(td 发散或跑到 +25ms)。
   如果符号写反了实验 3 还能过,说明这个判据是假的。

**⚠️ 本地目前没有 EuRoC/TUM 数据**(已实测:`~/Developer`、`~/Documents/progecttwo` 下无 `mav0`/`MH_0*`)。
上面 4 条判据全部依赖离线 player + 数据集。**这是执行阶段的第一个前置任务,不是可选项** ——
没有它,td 这条线只能靠真机主观感受验收,那等于没验收。

### 改动量的诚实计量

| 阶段 | 触及文件 | 触及行(估) | 性质 |
|---|---|---|---|
| 0 | 4 | ~45 | 机械重命名,可用逐位相同验证 |
| 1 | 6 | ~90 | 索引改写,风险中等,可用逐位相同验证 |
| 2 | 10(含 2 个新文件) | ~250 | 含真正的新数学与舒尔重构 |
| **合计** | **~12** | **~385** | |

其中 `ceres/marginalization_factor.h` 一个文件就占 ~150 行改动(全文 480 行)。
**难度不在「多」,在于 2.9 那一处 30 行的舒尔重构** —— 它是全仓唯一一处依赖
「误差状态里 pose 分量连续」这个隐含前提的代码,而没有任何注释说明这件事。

---

## 5. 另外两个也想进状态量的东西

### 5.1 相机-IMU 外参(6 DoF)

**结论:比 td 难一档,但不是不可能。真正的阻断在 Ceres 的参数块语义,不在数学上。**

🔴 **硬阻断**:Ceres 用**指针**识别参数块。而 `frame->camera` 是 `ExtrinsicParams`
**值成员**(`frame.h:70`),每帧在 `detail.cpp:179-180` 从 config **拷贝一份**。
10 帧窗口里就是 10 份互不相干的内存 —— 传给 Ceres 就是 10 个独立参数块,
优化出 10 组不同的外参,而外参在物理上只有一组。
⇒ **必须**把 `Frame::camera` 改成指向单一共享 `ExtrinsicParams` 的指针/引用。
这会触及全仓每一处 `frame->camera` 读取(`reprojection_factor.h:39-40`、
`rotation_factor.h:30-31`、`frame.cpp:86-88`、`sliding_window_tracker.cpp:407` 等,~15 处)。
`frame->imu` 同理。

🔴 **第二阻断**:外参是**真全局量**,不是逐帧量。它在
`pose_motion_infomat`(`frame_num * ES_SIZE` 见方)里**没有位置**。
td 可以靠「逐帧 + 随机游走」绕过布局问题;外参不行 —— 一个物理上恒定的量做成逐帧再用
超紧先验绑住,数值上是病态的(先验越紧越接近奇异)。
所以外参必须走 `[frames | globals]` 布局,而 L400-438 的 victim 消元
**假设 victim 在最后、幸存者是连续前缀** —— globals 排在 frames 之后就破坏了这个假设,
需要引入置换。这正是 §4 里 td 特意避开的那件事。

**可观测性(RD-VIO 特有的坑)**:
外参旋转在一般运动下可观测,平移需要足够的旋转激励。
但 RD-VIO 的立身之本恰恰是处理**纯旋转**场景(`FT_NO_TRANSLATION` tag、subframe 机制)。
纯旋转段里外参平移 `p_cs` 完全不可观测,不冻结就会漂。
⇒ 还要额外接一套激励判据来决定何时解冻。

**改动量**:比 td 多一个数量级的**结构性**改动(布局置换 + 共享存储),
数学本身反而不难(外参扰动同样是位姿扰动的链式,和 §3.4 同构)。

**建议**:**不做在线估计,做离线批量标定。**
这与 MEMORY 里 08-22 那条 VIO 选型结论一致(「离线 batch 标 IMU 内参」是真空白且 RSS2020 点名该做)。
外参用同一套离线流程一起标,标完写进 yaml,在线只读。

### 5.2 相机内参(Blocker 04 第二层)

**结论:判死。这不是「加一个参数块」,是架构反转。**

理由是 §1.5 里那三条结构事实的直接推论:

1. **优化器从头到尾看不见像素。**
   `frame.cpp:72` 和 `:105` 在**入库时**就用 `remove_k` 把像素变成 bearing;
   `reprojection_factor.h:20-22` 和 `rotation_factor.h:18-20` 在**构造因子时**
   从 bearing 建 `local_tangent`。K 要进状态量,残差就必须回到像素空间 ——
   那意味着重写 `CeresReprojectionErrorFactor`、`CeresReprojectionPriorFactor`、
   `CeresRotationPriorFactor` 的全部数学(`s2_tangential_basis` / `hnormalized` 这套
   单位球 2-DoF 参数化整个作废),并改掉前端的入库契约。
2. **白化矩阵是 K 的函数。** `detail.cpp:176-178`
   `sqrt_inv_cov = K.block<2,2>(0,0)` 再除以噪声标准差。K 变量化 ⇒ 白化变量化 ⇒
   代价函数的加权本身依赖状态,这在 Ceres 里是要额外小心的(会引入伪梯度)。
3. **畸变在在线路径上根本没建模**(`correct_distortion` 零调用点)。
   所以「内参进状态」这个说法本身就不完整 —— 只估 fx/fy/cx/cy 而不估畸变,
   在手机广角镜头上是把畸变误差硬塞进 f 和 c 里,是在制造新的偏置。

**更划算的替代方案(强烈建议改做这个)**:
`detail.cpp:173 frame->K = config->camera_intrinsic()` —— **K 是 yaml 常数**。
而 Apple 的 [`ARCamera.intrinsics`](https://developer.apple.com/documentation/arkit/arcamera/intrinsics)
是 **逐帧**给的 `simd_float3x3`,且在同一个 `ARWorldTrackingConfiguration` session 内
**会随帧变化**(自动对焦 / focus breathing / 数字裁剪)。
也就是说平台已经把真值端上来了,而我们在扔掉它。
把 `frame->K` 从 config 常数改成**逐帧平台值**,是 §5.2 全部收益里最大的一块,
改动量只有 `detail.cpp` 一行 + 接口加一个字段 —— 而且**不动任何优化器代码**。

Android 侧:`CameraCharacteristics.LENS_INTRINSIC_CALIBRATION` 从 API 23 起存在,
但**是 optional、可以返回 null**,且各厂商实现质量参差(有设备返回 0 或错值)。
⇒ Android 上必须有「拿不到就退回 yaml 常数」的分支,不能假设有。

---

## 6. 如果这条路太贵:和 ARCore 位姿的对照

Android 手机端有两条路,下面是诚实对照。**注意 §5 已经把「内参在线估计」判死了,
所以自研核这条路的真实成本是 §4 的 ~385 行 + 离线标定流程,而不是三件事全上。**

| 维度 | A. 自研核(RD-VIO + td) | B. 直接用 ARCore 位姿 |
|---|---|---|
| 需要改的代码 | ~385 行 / ~12 文件(§4),外加离线标定流程 | 0 行 VIO 代码;接一层平台适配 |
| 时序对齐 | td 在线估计,自适应 | 由 ARCore 内部处理,我们看不见也不用管 |
| 内参/畸变 | 见 §5.2:必须改成逐帧平台值,否则是死旋钮 | ARCore 内部自己处理 |
| 设备覆盖 | 理论上任意有 IMU+相机的 Android 设备 | 只覆盖 ARCore 认证设备,且依赖 Google Play Services for AR(**中国大陆发行是已知风险**) |
| 与眼镜端一致性 | 眼镜端拿平台位姿,手机端跑自研核 ⇒ **两条路** | 手机端和眼镜端同一条路(MEMORY 08-22 的架构修正正是这个方向) |
| 尺度 | IMU 提供米制尺度,但受加计 scale factor 偏置与温漂制约(MEMORY:iPhoneXR 0.116%,温漂 −160ppm/°C) | ARCore 同样给米制尺度,偏置由 Google 负责 |
| 可控性 / 差异化 | 全部在自己手里,能针对扫描场景调 | 黑盒,出问题只能等 Google |
| 热 | 自己背全部功耗预算(硬约束) | 摊到系统服务里,但总功耗不见得低 |
| ⚠️ 结构性风险 | **MEMORY 08-22 已坐实:`XRSLAM_IOS` 一个宏控三件事,两端跑的是结构性不同的算法** ⇒「一套管线」这个前提今天就不成立,td 上不上都一样 | 无 |

**我的判断(可被推翻)**:

- 这条 blocker 的答案是「**改造代价不算过大**」——385 行、12 个文件、两处真难点,
  而且难点已经被 §3.4 和 §4 拆解到可执行粒度。**它不再是未知数。**
- 但**「代价不大」不等于「该做」**。真正应该先回答的是 MEMORY 08-22 那条架构修正:
  **既然眼镜端注定用平台位姿,手机端自研核到底在为哪个产品差异化服务?**
  MEMORY 08-22 同时记着「单目不提供米制尺度 ⇒ 量尺寸这条商业差异化没有腿」。
  如果自研核的价值主张是「更准的尺度」,那这个靶子已经被自己的记录打掉了。
- **如果决定做,阶段 0 无论如何都该做** —— 它是纯 bug 修复(探针 1 那颗地雷今天就在树里,
  只是还没人去踩),和 td 上不上无关,而且可以用逐位相同验证,零风险。

---

## 7. 本轮没做 / 做不到的

- **没有构建 xrslam**。开工时 `vm.swapusage: used = 4705.88M / free = 1438.12M`,
  `vm_stat` 空闲页 9290 × 16KB ≈ **145MB**。在这个内存水位上编 Ceres/Eigen 是
  MEMORY 08-14 那次事故的复现条件。且本任务明确是「只读扫描 + 写报告」。
  ⇒ **§4 的所有改动都是未验证的方案,不是已验证的补丁。**
- **没有跑任何 xrslam 的测试**。`xrslam-test` 里只有 4 个测试
  (`test_version` / `test_se3_cost_function` / `test_pnp` / `test_feature_track`),
  **没有任何一个覆盖 `estimation/`**。td 改造需要新写因子级单测(解析雅可比 vs 数值差分),
  这本身是阶段 0 应该顺带补上的空白。
- **本地没有 EuRoC / TUM 数据集**(已实测)。§4 的四条验证判据全部依赖它。
- **没有读 VINS-Mono 源码**(GPLv3),只读了论文。§3.1 的三条公式来自 arXiv:1808.00692 的
  式 (2)(4)(7),§3.3 来自 arXiv:2501.01788 的式 (11)(13)。
  **实现必须从公式自己写起。** ByteDance 那份参考实现在被动用前需要单独许可审计。
- **没有量化 td 对我们实际场景的收益**。iOS 上 ARKit 已经处理了时序,
  td 的收益主要在 Android;而 Android 应用今天在 pocketworld 里**根本不存在**
  (`/Users/kaidongwang/Developer/pocketworld` 无 `android/` 目录)。
  ⇒ 这条 blocker 的紧迫性低于它看起来的样子。

## 附:本轮执行过的东西

| 文件 | 用途 | 结果 |
|---|---|---|
| `<scratchpad>/es_size_probe.cpp` | 复刻 `marginalization_factor.h:188-212`,证明 ES_SIZE 上调会静默污染 | BUILD_EXIT=0,A=0 / B=4 / C=0,**CONFIRMED** |
| `<scratchpad>/tripwire.cpp` | 复刻 `:402` 的 `matrix<15,15>`,判断是响还是哑 | ES=15 通过;ES=16 `YOU_MIXED_MATRICES_OF_DIFFERENT_SIZES`,**是响的** |

scratchpad 绝对路径:
`/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/00b9f4a7-61ae-40fd-a452-5f357f42dad3/scratchpad/`

## 引用来源

- [Online Temporal Calibration for Monocular Visual-Inertial Systems (Qin & Shen, IROS 2018) — arXiv:1808.00692](https://arxiv.org/abs/1808.00692)
- [Universal Online Temporal Calibration for Optimization-based Visual-Inertial Navigation Systems — arXiv:2501.01788](https://arxiv.org/html/2501.01788)
- [RD-VIO: Robust Visual-Inertial Odometry for Mobile Augmented Reality in Dynamic Environments — arXiv:2310.15072](https://arxiv.org/abs/2310.15072)
- [ARCamera.intrinsics — Apple Developer Documentation](https://developer.apple.com/documentation/arkit/arcamera/intrinsics)
- [CameraCharacteristics — Android Developers](https://developer.android.com/reference/android/hardware/camera2/CameraCharacteristics)
