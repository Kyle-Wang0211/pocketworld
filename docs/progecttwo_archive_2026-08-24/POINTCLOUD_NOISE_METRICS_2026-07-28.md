# 点云噪声判决指标调研 — 无基准面 / 双边 / 全场景

**日期**:2026-07-28
**目的**:替换现有"RANSAC 拟合地板 → 数面下点"的鬼层守门指标
**范围**:稀疏摄影测量点云(SfM tie points),端上跨平台、商用干净
**方法**:所有数值均来自实际抓取的一手源码 / 论文 PDF / 官方文档,逐条附 URL。凡未能从一手来源核实的一律标 **NOT VERIFIED**,不填记忆值。引用一律 ≤15 词并注明出处。

---

## 0. 为什么必须换掉现有指标(问题陈述)

### 0.1 现有实现(已逐行核实)

**规范实现**:`/Users/kaidongwang/Documents/progecttwo/_host_fixtures/planesweep_cap7/ps_prep.py`(地板拟合块 ≈ L195–260)

**现存四份拷贝,RANSAC 参数逐字节相同**:

| 文件 | 函数 | 角色 |
|---|---|---|
| `_host_fixtures/spatial_cand_exp/tools/floor_ghost.py` | `main()` | 逐臂重拟合,写 `floor_<fix>_<arm>.json` |
| `_host_fixtures/spatial_cand_exp/tools/floor_fixed.py` | 顶层 | 只在 A 臂拟合一次,所有臂共用该面 |
| `_host_fixtures/spatial_cand_exp/tools/floor_modal.py` | 顶层 | MODAL 频带变体(为修 cap3_eve 误锁) |
| `_host_fixtures/loop_cap37/tools/analyze_ab.py` | `fit_floor_plane()` L222–286 / `eval_floor()` L289–312 | **A/B 硬门** |
| `_host_fixtures/m2_cap7/m2_stats.py` | L106–142 | 2-view 视差禁令的面下点核算 |

**字面常数**:
- 重力 `R_w` = `qArkConj ⊗ qC ⊗ q_colmap` 均值归一化,`qC = [0,1,0,0]`,`C_FLIP = diag(1,-1,-1)`
- 候选集:**track length ≥ 3** + 重力 Y 的 **p5..p20** 百分位带
- RANSAC:`default_rng(0)`(**种子 0**)、**4000 次迭代**、3 点最小样本、**`INL_T = 0.010`(1cm 内点阈)**、法向 vs UP **倾角门 > 5.0° 拒绝**
- 精化:内点集上做 **2 次** SVD 最小二乘重拟合
- 判据:`dist = xyz @ n_model - floor_val`,**`subfloor_gt15mm: dist < -0.015`** ← 头条鬼层计数
- 门:`_host_fixtures/loop_cap37/REPORT.md:6` —— 「双层地板指标是**硬回归门**(变差=自动 DO-NOT-SHIP,位姿收益再大也不放行)」

### 0.2 三条致命缺陷,全部有本地实测坐实

**(a) 循环论证(circular)**:被测的病理(双层地板)本身就是两片壳,拟合面可落在任一片上。

**实测铁证** —— `_host_fixtures/spatial_cand_exp/floor_cap3_eve_*.json`:

| 臂 | n_points | subfloor<−1.5cm | share | 平面内点 | 倾角 |
|---|---|---|---|---|---|
| A / A2 | 96,220 | 34,582 | **35.94%** | 1,781 / 5,073 | **5.364°** |
| B_temporal_k30 | 101,488 | 32,129 | **31.66%** | 1,988 | 4.519° |
| B_spatial | 101,500 | 16,413 | 16.17% | 1,930 | 1.031° |
| B_k30 | 103,798 | 17,400 | 16.76% | 2,007 | 0.989° |

对照健康 fixture:cap7_day 臂 A **3.16%**(4,480 / 141,758,内点 7,024 / 7,986、RMS 2.911 mm、倾角 0.1226°、`floor_val −0.93812`),见 `floor_cap7_day_A.json` / `tables_cap7.md` §3 / `loop_cap37/analysis.json`。

**我们自己的代码已经承认这个缺陷** —— `floor_modal.py` docstring L4–13 原文:「"a mis-latched fit, not 36% ghosts"」(floor_modal.py 注释)。即:36% 是拟合误锁的产物,不是 36% 的鬼点。同一份点云换个拟合带就从 36% 掉到 16%,**指标的方差比被测效应还大**。

**(b) 单边(one-sided)**:判据只有 `dist < -0.015`。表面**上方**的飞点永远不计数。

**(c) 只看地板(floor-only)**:墙面、家具、天花板的鬼层对该指标完全隐形。而 `floor_fixed.py`(A 臂拟合一次共用)只修好了 (a) 在 B 臂上的表现,**A 臂自身仍是循环的**,且 (b)(c) 分毫未动。

**结论**:今日基于该指标下的所有判决全部悬置,待本文档的替代套件上线后重跑。

---

## ① 指标全表

> **口径警告(贯穿全表)**:特征值符号约定在文献里有**三套互不兼容**的体系,阈值跨体系搬运会差一个平方。见 §1.3.0。

### 1.1 统计离群剔除(Statistical Outlier Removal, SOR)

#### PCL `pcl::StatisticalOutlierRemoval`

**定义 / 算法**(逐行核实自 https://raw.githubusercontent.com/PointCloudLibrary/pcl/master/filters/include/pcl/filters/impl/statistical_outlier_removal.hpp):

1. `searcher_k = mean_k_ + 1`(多找一个,因为 kNN 结果含查询点自身)
2. 逐点:`d_i = (1/k) Σ_{j=1..k} sqrt(nn_dists[j])` —— **跳过 j=0(自身)**,且 PCL 的 kd-tree 返回**平方距离**,此处开方成欧氏距离
3. 全局:`mean = Σd/n`;`variance = (Σd² − (Σd)²/n)/(n−1)`(一遍式 + Bessel 校正);`stddev = sqrt(variance)`
4. **判据(单边)**:`剔除 iff d_i > mean + std_mul_ · stddev`;保留是 `d_i <= threshold`(含等号)

**⚠️ 真实默认值(与业界流传的完全不同)** —— https://raw.githubusercontent.com/PointCloudLibrary/pcl/master/filters/include/pcl/filters/statistical_outlier_removal.h

```cpp
int    mean_k_{1};      // 模板版 StatisticalOutlierRemoval<PointT>,L182
double std_mul_{0.0};   // L186
int    mean_k_{2};      // PCLPointCloud2 特化版,L259
double std_mul_{0.0};   // L264
```

构造函数**不覆盖**这两个成员。**`std_mul_ = 0.0` 意味着阈值 = 均值,默认配置会砍掉约一半点云** —— 这是"必须显式设置"的哨兵值,不是可用配置。

**教程值 ≠ 默认值**:https://pcl.readthedocs.io/projects/tutorials/en/master/statistical_outlier.html 用 `setMeanK(50)` + `setStddevMulThresh(1.0)`;头文件自带 usage example 用 `setMeanK(8)` + `1.0`,并注明「"assuming the average distances are normally distributed there is a 84.1% chance"」(PCL 头文件注释)—— 正态 + 单边,1σ 单边 ≈ 84.1%,自洽。**业界普遍误以为 50/1.0 是默认值,来源就是这个教程。**

**⚠️ 文档/代码矛盾(已核实)**:头文件 L184–186 成员注释写 "points outside of μ ± σ·std_mul"(暗示双边),**但实现只有上界**。类级注释(L48–55)与代码一致。引用 PCL 时以代码为准。

**出处**:头文件 L61–64 自引 —— R. B. Rusu, Z. C. Marton, N. Blodow, M. Dolha, M. Beetz, *Towards 3D Point Cloud Based Object Maps for Household Environments*, Robotics and Autonomous Systems 56(11):927–941, 2008。https://www.sciencedirect.com/science/article/abs/pii/S0921889008001140
⚠️ Rusu 博士论文(TUM 2009)PDF xref 损坏无法提取正文;网传的"论文推荐 K=50 / 阈值 2.0" **NOT VERIFIED**,不予采信。

**License**:**BSD 3-Clause**(https://raw.githubusercontent.com/PointCloudLibrary/pcl/master/LICENSE.txt,正文含三条款)。✅ 商用干净。

**成本**:建树 O(N log N) + N 次 kNN,每次 O(log N + k);内存 O(N)。⚠️ **模板版 SOR 实现是纯单线程,无 OpenMP**(同仓 `RadiusOutlierRemoval` 有 `#pragma omp parallel for` 和 `num_threads_`)。

**失效模式**:
- **非均匀密度是头号杀手**:`mean`/`stddev` 是**整片云的单一全局统计量**,阈值只有一个。天然稀疏的合法区域(远处、掠射角表面、边缘)平均 NN 距离本就大于全局均值,会被系统性误杀。**这是单全局阈值的固有缺陷,不是调参问题** —— 与我方「点云密度必须全场景均匀」铁律直接冲突。
- **正态假设**:平均距离分布若长尾/双峰(典型:主结构 + 一层稀疏噪声壳),mean 与 stddev 双双被噪声抬高,阈值随之抬高,**反而放过噪声**。
- **k 敏感**:k 太小 → 方差大易误判;k 太大 → 平滑掉真实局部结构。
- 数值:一遍式方差在大 N + 小方差时有 catastrophic cancellation 风险。

#### Open3D `remove_statistical_outlier`

**签名与默认值**(https://raw.githubusercontent.com/isl-org/Open3D/main/cpp/pybind/geometry/pointcloud.cpp L142–146):
```cpp
.def("remove_statistical_outlier", &PointCloud::RemoveStatisticalOutliers,
     "nb_neighbors"_a, "std_ratio"_a, "print_progress"_a = false)
```
→ **`nb_neighbors` 与 `std_ratio` 均无默认值,调用者必须提供**。运行期硬校验 `if (nb_neighbors < 1 || std_ratio <= 0) LogError(...)`(PointCloud.cpp L610–614)。Tensor 版同样无默认(注意 legacy 是单数 `outlier`,tensor 版是复数 `outliers`)。

教程用 `nb_neighbors=20, std_ratio=2.0`(http://www.open3d.org/docs/release/tutorial/geometry/pointcloud_outlier_removal.html)—— 同样是示例值。

**⚠️ 与 PCL 的四处实质差异(逐行核实 PointCloud.cpp L606–666)**:

1. **Open3D 不排除自身点**。它查询**恰好 `nb_neighbors` 个**(不是 k+1)且不跳过 index 0;`KDTreeFlann::SearchKNN`(KDTreeFlann.cpp L93–112)直接透传给 nanoflann,无任何自身排除逻辑。
   → **Open3D `nb_neighbors=20` 在"真实邻居数"上等价于 PCL `mean_k=19`**。均值被那个 0 稀释为 PCL 口径的 (k−1)/k 倍;当每点都拿满 k 个邻居时这是统一缩放、比较结果恰好抵消,但**在点数不足 k 的小云/小簇上抵消不成立**。
2. 标准差用**两遍式**(数值更稳),但分子跳过 `avg == 0` 的点、分母 `valid_distances` 却几乎统计了全部点 → 存在**完全重合点**时 `cloud_mean` 被系统性低估。PCL 无此问题。
3. 保留判据是**严格小于** `avg < threshold`(PCL 是 `<=`),且**额外把 `avg == 0` 的精确重复点判为剔除**。两者均为**单边**。
4. **无 NaN/Inf 检查**(PCL 有显式 `std::isfinite`)。含 NaN 的点云在 Open3D 下行为未定义。

**License**:**MIT**(https://raw.githubusercontent.com/isl-org/Open3D/main/LICENSE)。✅

### 1.2 半径离群 / 密度(Radius Outlier Removal)

#### PCL `pcl::RadiusOutlierRemoval`

**默认值**(https://raw.githubusercontent.com/PointCloudLibrary/pcl/master/filters/include/pcl/filters/radius_outlier_removal.h L196–204):
```cpp
double search_radius_{0.0};   // 哨兵:必须设置
int    min_pts_radius_{1};
int    num_threads_{1};
```
`search_radius_ == 0.0` 时 impl 直接 `PCL_ERROR("No radius defined!")` + **输出空点云**(不是不过滤)。

**判据(自身点不计入)**:两条路径语义一致 —— radius search 路径 `k`(含自身)`> min_pts` 才保留 ⟺ **`k_不含自身 >= min_pts`**;kNN 快路径 `mean_k = min_pts_radius_ + 1`,半径比较用**平方距离且是闭区间**(`d == r` 算邻居)。
⚠️ 头文件 L99–101 文档措辞暗示"含自身",与代码不符,以代码为准。

**性能**:用 `max_nn = min_pts + 1` 截断半径搜索,稠密区不会退化;有 `#pragma omp parallel for schedule(dynamic,64)`,可 `setNumberOfThreads()` 并行。

#### Open3D `remove_radius_outlier`

`nb_points` 与 `radius` **无默认值**,硬校验 `if (nb_points < 1 || search_radius <= 0) LogError(...)`。判据 `mask[i] = (nb_neighbors_含自身 > nb_points)` ⟺ **`nb_不含自身 >= nb_points`** —— **与 PCL 语义完全一致**(两库在 radius 滤波上罕见地对齐)。
⚠️ **命名坑**:legacy Python 关键字是 `radius`,C++ 形参与 tensor 版 Python 关键字都是 `search_radius`。
性能:`SearchRadius` **无 max_nn 截断**,稠密区比 PCL 慢很多,但有 OpenMP。

#### 半径如何相对平均点距选择 —— **未找到任何权威规则**

已查:PCL 头文件/doxygen、PCL remove_outliers 教程(只给示例 0.8)、Open3D 教程(只给 0.05)、CloudCompare SOR filter wiki(只描述算法,不给默认值、不给经验规则)。

**「r = 2–3× 平均最近邻间距」这类经验法则,在 PCL / Open3D / CloudCompare 的任何官方文档或可核实的一次文献中都不存在 —— NOT VERIFIED,不要引用。** 若产品端需要一条规则,只能由我方在受控数据上标定并自行背书。

#### 平均最近邻距离工具

- **Open3D 有**:`PointCloud::ComputeNearestNeighborDistance()` / Python `compute_nearest_neighbor_distance()`,**无参数**,返回**逐点向量不是均值**。实现取 `SearchKNN(p, 2)` 后用 `sqrt(dists[1])`(index 0 是自身)。⚠️ **点数<2 或找不到邻居时填 0.0,是哨兵值,直接 `np.mean()` 会被污染**。
- **PCL 没有**:`common/` 全部头文件核对完毕,`distances.h` 只有点-点/点-线/点-面几何距离。最接近的只有 `pcl::getMeanStd` / `pcl::getMeanStdDev`(common.h L149/L270),只对已给定的 `vector<float>` 求均值方差。**求平均最近邻间距需自己写。**

### 1.3 局部维度 / 特征值特征(Eigenfeatures)

#### 1.3.0 ⚠️ 三套互不兼容的口径(头号坑)

| 体系 | 特征值口径 | 归一化 |
|---|---|---|
| **Demantké 2011** | **σ_j = sqrt(λ_j)**(沿特征向量的标准差) | µ = σ1,使 a1D+a2D+a3D = 1 |
| **Weinmann 系** | **e_i = λ_i / Σλ**(和为 1) | 分母多用 e1 |
| **West / Gross / CloudCompare / PDAL** | **raw λ,不开方不归一** | 分母 λ1(或 Σλ) |

**任何从外部搬来的阈值必须先核对口径,否则差一个平方。**
**⚠️ 下标语义陷阱**:Pauly 写 λ0/Σλ 且 **λ0 最小**;Weinmann/lidar 支系写 λ3/Σλ 且 **λ3 最小**。同一个量,排序约定相反。
**⚠️ PDAL 默认 `mode="SQRT"`** 是最隐蔽的雷,要与 CloudCompare/jakteristics/pyntcloud parity 必须显式设 `mode: "Raw"`;且 `sum` 在 SQRT 变换**之前**计算且之后从未重算,默认模式下 `SurfaceVariation = sqrt(λ3)/(Σλ)_raw`,**分子分母量纲不同**(此为对 https://raw.githubusercontent.com/PDAL/PDAL/master/filters/CovarianceFeaturesFilter.cpp 的源码分析读法,PDAL 官方未标为 bug)。

#### 1.3.1 Demantké et al. 2011(维度性 + 熵尺度选择)

PDF: https://isprs-archives.copernicus.org/articles/XXXVIII-5-W12/97/2011/isprsarchives-XXXVIII-5-W12-97-2011.pdf

```
σ_j = sqrt(λ_j) ,  µ = σ1
a1D = (σ1 − σ2)/µ ,  a2D = (σ2 − σ3)/µ ,  a3D = σ3/µ        (原文无编号式)
d* = argmax_{d∈[1,3]} [a_dD]                                  (Eq.2,纯 argmax,不需阈值)
Ef(V_P^r) = −a1D·ln(a1D) − a2D·ln(a2D) − a3D·ln(a3D)          (Eq.3)
r*_Ef = argmin_{r ∈ [rmin, rmax]} Ef(V_P^r)                    (Eq.4)
```
选 µ = σ1 是为了让三者和为 1、可当作概率 —— 这正是能取 Shannon 熵的前提。论文同时实现了竞争准则 similarity index Si(Eq.5/6,argmax),但 §5.1 明确弃用(Si 会误选,且依赖邻居标注需两轮迭代)。

**半径搜索的确切数字**:`[rmin, rmax]` 采样 **16 个值**;r 按 "a square factor" 非线性递增(⚠️ **论文未给显式解析式,任何具体递推公式都是外推 — NOT VERIFIED**);PCA 最少邻居数原文 "start with 10 points"(Demantké 2011)= **10 点**。
⚠️ **重要更正:论文并未给出通用固定的 rmin/rmax 数值**,§4.2 明说 "specific to each dataset"。它给的是准则:rmin 由噪声/扫描各向异性/PCA 最少点数决定;rmax **选择不关键(not critical)**,TLS/MMS 立面**典型 3 m**,约 5 m cut-off 普遍好用,实践中 3–4 m 已足够。

#### 1.3.2 Weinmann 系(归一化 e_i,八特征表)

⚠️ **目标论文 ISPRS J. 105:286–304(2015)付费墙,未读到原文。** 以下取自同团队开放获取的前作/同期作(公式体系相同):
[W2013] https://isprs-annals.copernicus.org/articles/II-5-W2/313/2013/ · [W2014] https://isprs-annals.copernicus.org/articles/II-3/181/2014/ · [W2015w4] https://isprs-annals.copernicus.org/articles/II-3-W4/271/2015/ · [W2017] https://isprs-annals.copernicus.org/articles/IV-1-W1/157/2017/

| 特征 | 公式 |
|---|---|
| Linearity Lλ | (e1 − e2) / **e1** |
| Planarity Pλ | (e2 − e3) / **e1** |
| Scattering / Sphericity Sλ | e3 / **e1** |
| Omnivariance Oλ | ∛(e1·e2·e3) |
| Anisotropy Aλ | (e1 − e3) / **e1** |
| Eigenentropy Eλ | −Σ e_i·ln(e_i) |
| Sum Σλ | e1 + e2 + e3 |
| Change of curvature Cλ | e3 / **(e1 + e2 + e3)** |

⚠️ [W2014] Table 1 有一处**真实印刷勘误**:若 e_i 已归一化则 `Σλ ≡ 1` 是退化量;实现界一律按 [W2013] 用原始 `λ1+λ2+λ3`。2015 期刊版印的是 e 还是 λ —— **NOT VERIFIED**。
⚠️ [W2014] 脚注 2:零特征值须加无穷小 ε,否则 eigenentropy 出现 ln(0)。

**k 搜索范围**:[W2014] §3.2 与 [W2015w4] §3.1 均为 **k_min=10, k_max=100, Δk=1**,取 Shannon 熵最小者。固定对照 k=10 / 50 / 100。覆盖率 98.12% 的点 k<100。

#### 1.3.3 Pauly, Gross, Kobbelt 2002 — surface variation(确认成立)

PDF: https://www.graphics.rwth-aachen.de/media/papers/p_Pau021.pdf,第 2 节 "Surface Variation",**式 (5)**:
```
σ_n(p) = λ0 / (λ0 + λ1 + λ2)        (λ0 ≤ λ1 ≤ λ2,λ0 最小)
```
**两个解析标定点(全文唯一硬数值)**:σ=0 ⟺ 所有点共面;**σ 最大值 = 1/3**,点完全各向同性分布时取到。

⚠️ **两点勘误常见误解**:
1. 论文只说 surface variation "closely related to curvature",**没有说它近似 mean curvature,也没给任何解析等价关系**;并明确强调 σ_n **不是内蕴特征**(依赖邻域大小),还论证它**优于**曲率估计。
2. **"change of curvature" 这个名字不来自 Pauly**。Pauly 从没用过。首创宣告见 Pauly/Keiser/Gross 2003 §2.2;"change of curvature" 是 **Weinmann 支系 2013 年起的二次命名**。PCL 叫 "surface curvature change",CloudCompare 叫 "Normal change rate"。

Pauly 2003 的多尺度邻域范围:**n 从 15 到 200**(它给出的唯一具体数值建议);σ_max、hysteresis 双阈值全是用户参数,无推荐值。

#### 1.3.4 West et al. 2004 命名溯源 —— **通行说法是一次引用漂移**

- West 2004 原文 SPIE 付费墙,OpenAlex `oa_status: closed`。**其官方摘要里完全没有 eigenvalue / linearity / planarity / covariance 任何一词** —— 这是一篇 LADAR 目标检测系统论文。
- 唯一可核实的一手转述:**Gross & Thoennessen 2006**(https://www.isprs.org/proceedings/XXXVI/part3/singlepapers/O_05.pdf),原文 "West (2004) uses the following features which depends on the eigenvalues"(Gross & Thoennessen 2006),随后 Eq.(12)–(17) 给出六式,**全部用 λ 本身不开方**,且用 **Sphericity 而非 scattering**。
- Demantké 2011 只说 "Several indicators have already been proposed (West et al., 2004; Toshev et al., 2010)"(Demantké 2011),**没把三个名字归给 West**;Chehata et al. 2009 **根本没引 West**,四式归 Gross & Thoennessen 2006;3DMASC 2024(arXiv 2401.09481)完全绕开 West。

**裁决**:公式确实出自 West 2004(高置信,据 Gross 转述);**"名字来自 West 2004" 无法证实且可疑**;"scattering" 一词肯定不来自 West(首见于 Demantké 的 a3D)。更恰当的命名归属是 **Gross & Thoennessen 2006 → Chehata 2009**。

#### 1.3.5 哪个特征最能分离干净表面 vs 噪声

**Weinmann [W2013] 特征选择排名**(Oakland 数据集,21 特征、7 种相关性度量取平均秩):

| 秩 | 特征 | 秩 | 特征 |
|---|---|---|---|
| 1 | R_{λ,2D} | 12 | Aλ 各向异性 |
| 2 | V 垂直度 | 16 | **Oλ 全方差** |
| **3** | **Cλ change of curvature** | 18 | **Σλ 特征值和** |
| 4 | σ_{Z,k-NN} | **20** | **Lλ 线性度** |
| 5 | ΔZ_{k-NN} | **21** | **Eλ 特征熵(垫底)** |
| **6** | **Pλ 平面度** | | |
| **9** | **Sλ 散布/球度** | | |

**头条结论:除 change of curvature 外,所有经典 eigenfeature 排名都很差。** 分类精度:全 21 特征 SVM 89.48;**仅 {Lλ,Pλ,Sλ} 三特征只有 75.26**;前五名子集 93.32。
[W2013] 对 Lλ 垫底给出的诊断极重要:高 linearity 主要由**遮挡边缘和视场边界**产生,"mainly caused by edges due to occlusions or borders"([W2013]),而这些不该是线状物体。
⚠️ **不要当普适**:[W2017] 在不同任务上把 **Oλ、Eλ、Cλ** 列为最相关 —— 全方差和特征熵从 2013 垫底翻转为 2017 最佳,论文自归因于任务/采样/邻域类型不同。

**唯一针对"飞点抑制"的量化实证** —— Jäger, Hillemann, Jutzi (2025), *FeatureGS*, arXiv:2501.17655(https://arxiv.org/html/2501.17655)。四种 eigenfeature 损失对比(k=50,DTU + BlendedMVS),飞点抑制(全点集 Chamfer,3DGS 基线 116.587 mm):
- **Planarity (Gaussian):10.593 mm(−90.9%)** ← 最佳
- Planarity (kNN):10.793 mm(−90.7%)
- **Omnivariance (kNN):12.212 mm(−89.5%)**
表面几何精度(CD≤10mm):基线 1.609 → Planarity-Gaussian 1.313(−18.4%)。
⚠️ **重要限定**:这是**可微损失项,不是阈值判决**,且是 3DGS 场景。证明这些特征对飞点**有判别力**,但**不能反推出任何阈值数值**。

**诚实报告的空白**:文献中**不存在**针对"哪个 eigenfeature 最能分离噪声与干净表面"的受控判别力比较(ROC/AUC)。理论侧唯一硬结论:surface variation 有 **[0, 1/3] 的闭区间绝对标尺**,是所有 eigenfeature 里**唯一有噪声端理论上界**的;但**没有论文实测过 σ 在真实噪声/干净表面上的分布重叠度**。

#### 1.3.6 已发布的数值阈值 —— **几乎不存在**

**这是本次调研最重要的发现之一:遥感/摄影测量社区从 2011 年 Demantké 起就把 eigenfeature 当分类器输入,系统性地绕开了阈值,因此从未沉淀出默认阈值。**

交叉验证的"零阈值"证据:

| 来源 | 结论 |
|---|---|
| **CloudCompare Compute geometric features**(⚠️ 正确页名 `Compute_geometric_features`,`Geometric_Features` 是 **404**) | 对话框**只暴露一个参数:Local neighborhood radius**;不给公式、不给推荐阈值,定义外包给 Hackel 2016 |
| CloudCompare Curvature | "Normal change rate" = λ3/Σλ,唯一参数是 kernel,**无推荐阈值**;邻居<6 记 NaN |
| **Hackel et al. 2016**(CC 指定的定义来源) | 全文 `grep -i threshold` 命中数 = **0** |
| Demantké 2011 | 维度标注是纯 argmax,**根本不需要阈值** |
| Weinmann 2017 | 全文 "threshold" 只出现 1 次,指特征**数量**而非特征值 |
| jakteristics README / Open3D | 无任何阈值建议;Open3D 干脆没有 eigenfeature 滤波器 |

**找到的全部真实数值(仅三条)**:

1. **PCL RegionGrowing 源码默认值** —— 唯一有代码级背书的 surface-variation 阈值
   https://github.com/PointCloudLibrary/pcl/blob/master/segmentation/include/pcl/segmentation/region_growing.h
   ```cpp
   float theta_threshold_{30.0f / 180.0f * M_PI};   // 30°
   float curvature_threshold_{0.05f};               // ← λ3/Σλ 阈值
   unsigned int neighbour_number_{30};
   ```
   ⚠️ **官方教程与源码不一致**:教程用 `setSmoothnessThreshold(3.0/180*M_PI)`(3° 不是 30°)和 **`setCurvatureThreshold(1.0)`**。而 λ3/Σλ 的**数学上限是 1/3 ≈ 0.333**,所以教程的 1.0 = **把曲率判据彻底关掉**,不是"宽松阈值"。**绝不要抄这个 1.0。**
2. **PDAL `filters.approximatecoplanar`**(https://pdal.io/en/2.7.2/stages/filters.approximatecoplanar.html):判据(λ 升序)`λ2 > (s_α·λ1) && (s_β·λ2) > λ3`,`knn=8`、**`thresh1=25`、`thresh2=6`**,归属 [Limberger2015]。⚠️ **NOT VERIFIED**:未取到原论文核实 25/6 确出自那里,目前只有 PDAL 文档一个来源。
3. **Gross & Thoennessen 2006 的理想构型特征值比**(**解析推导,不是经验阈值**):半平面直边 λ2/λ1 = (9π²−64)/(9π²) = **0.28**;两正交平面交线 λ2/λ1 = **0.5**、λ3/λ1 = **0.14**。论文自承不通用。

**最有方法论价值的发现** —— Rabbani, van den Heuvel, Vosselman 2006(https://www.isprs.org/proceedings/XXXVI/part5/paper/RABB_639.pdf)**明确拒绝给固定数值**,推荐:"calculate this threshold automatically using a specified percentile of the sorted residuals"(Rabbani 2006),并说 **95+% 可作代表性数字**,承认这导致 "data dependent values"。
**分位数门比绝对阈值更抗尺度/密度变化,也更有文献支持 —— 这是本文档采纳的判据范式。**

#### 1.3.7 邻域尺寸选择(各论文确切数字)

| 来源 | 推荐 |
|---|---|
| Demantké 2011 | radius,16 个采样值,square-factor 递增;PCA 最少 **10 点**;rmax 典型 **3 m**,5 m cut-off 普遍好用;rmin/rmax **因数据集而异** |
| Weinmann 2014/2015w4 | **k_min=10, k_max=100, Δk=1**;固定对照 k=10/50/100 |
| Pauly 2003 | **n 从 15 到 200** 全扫,统计 persistence |
| PDAL covariancefeatures / eigenvalues | **knn=10**(`min_k=3`)/ **knn=8** |
| PCL RegionGrowing | **k=30** |
| Weinmann 2017 | **k=50** + 熵选 k_opt;球/圆柱 **R=1 m** |
| Atik/Duran/Şeker 2021 (IJGI 10(3):187) | 五半径 0.5/1/1.5/2/3 m;**最优半径随点密度走**(稠密 Dublin 峰值 R=3,稀疏 Vaihingen/Oakland 峰值 R=1–1.5),且**逐类不同、逐分类器不同**。Vaihingen GNB 精度纯因半径在 71.29↔75.47% 间摆动 |
| **Duran, Ozcan, Atik 2021 (Drones 5(4):104)** | ⚠️ **同一场景 LiDAR 最优 0.5 m,摄影测量最优 0.05 m —— 差 10×**。任何在 lidar 上调好的半径搬到摄影测量数据上会差一个数量级 |

#### 1.3.8 实现与许可证

| 实现 | 有全套 eigenfeature? | 许可证(已 fetch 原文) |
|---|---|---|
| **PDAL** `filters.covariancefeatures` | ✅ 11 个 | **BSD 3-Clause** 🏆 商用友好 |
| **pyntcloud** | ✅ 8 个,纯 numpy | **MIT** 🏆 |
| **PCL** | ❌ **只有 curvature** | **BSD 3-Clause** |
| **CCCoreLib**(CC 算法实际所在地) | ✅ 14 个 | **LGPL-2.0-or-later**(源文件头 SPDX 确认) |
| CloudCompare 应用 | UI 层 | **GPL v2 or later**(⚠️ 根目录是小写 `license.txt`) |
| **jakteristics**(https://github.com/jakarto3d/jakteristics) | ✅ 27 项 | ⚠️ **仓库根目录无 LICENSE,GitHub API `license` = null**,只有 setup.py 里 `license="BSD"`,未指明 2/3-clause、无授权全文 → **法务上不完整声明** |
| Open3D | ❌ **没有 eigenfeature** | MIT |
| CGAL | ⚠️ 命名特征已从 master **移除** | **GPL-3.0-or-later OR Commercial** → **出货 DO-NOT-USE** |
| LAStools | ❌ | 半闭源 → 排除 |

**PCL `curvature` ≡ surface variation(已核实)**:https://raw.githubusercontent.com/PointCloudLibrary/pcl/master/features/include/pcl/features/impl/feature.hpp `solvePlaneParameters`:
```cpp
float eig_sum = covariance_matrix.coeff(0) + covariance_matrix.coeff(4) + covariance_matrix.coeff(8);
if (eig_sum != 0) curvature = std::abs (eigen_value / eig_sum);
```
= λ_min/(λ1+λ2+λ3),分母用协方差矩阵的**迹**而非显式求和(数学等价,省掉另外两个特征值)。
→ **PCL `curvature` ≡ CloudCompare `SurfaceVariation` ≡ jakteristics `surface_variation` ≡ pyntcloud `Curvature` ≡ Pauly σ_n。确认。**
`PrincipalCurvaturesEstimation` 是完全不同的量(对**邻域法线**投影到切平面做特征分解,Weingarten map 近似)。
**PCL 没有 linearity/planarity/omnivariance**(GitHub code search 在 repo 内 `omnivariance` 命中 0)。

**成本**:O(N log N + N·k) 时间,O(N) 额外内存。协方差累加 O(k)(≈9k flops);**3×3 对称特征分解 O(1)**。实践上 **k 主导**,且 **kNN 查询的 cache miss 通常比 flops 更贵**。
**求解器**:唯一用 closed-form 的是 **PCL `pcl::eigen33`**(特征多项式三角法,`computeRoots`,无迭代循环);CCCoreLib 用 `Jacobi<double>`(maxIter 50)、PDAL 用 `SelfAdjointEigenSolver`、jakteristics 用 LAPACK `dsyev`,均为迭代。
⚠️ **closed-form 典型快 3–10×(无分支、可 SIMD/GPU 向量化),但数值稳定性差**:接近简并(λ1≈λ2 或三重简并)时三次方程三角解法损失精度。Open3D `fast_normal_computation` 注释也承认 "This is faster, but is not as numerical stable"(Open3D)。**稠密点云的平面区域恰恰经常出现 λ2≈λ3 —— 端上 GPU 化必须实测的风险点。**

#### 1.3.9 失效模式

**尺度依赖** —— Brodu & Lague 2012(ISPRS J. 68:121–134,https://arxiv.org/pdf/1107.0550)最强独立陈述:22 个尺度(2 cm–1 m),§5.2 结论对植被/基岩/砾石/水 "there is not a single scale at which the classes could be distinguished"(Brodu & Lague 2012);砾石 vs 水在所有测试尺度上都不可分。多尺度 vs 最佳单尺度(Table 3 平衡精度)83.2% vs 70.9%,Fisher 判别比提升 "two to three times"。
⚠️ 直接相关的一条:地面 lidar 中可能**缺失最小尺度**(密度不足/阴影/场景边界),他们的对策是把次大尺度的几何**填进缺失槽位** —— 即该尺度的特征是**编造的,不是测量的**。
Weinmann 2017:"structures related with different classes may favor a different neighborhood size"(Weinmann 2017)—— 单一全局尺度不只对数据集错,是**逐类就错**。

**边缘/边界**:见 §1.3.5 [W2013] 原话。Demantké 2011 独立佐证:局部描述在包含多个不同结构时 "may be biased ... provides erroneous feature descriptors"(Demantké 2011),定位在物体边界与尺寸接近邻域大小的物体上。

**最优半径的闭式解** —— Mitra, Nguyen & Guibas 2004(http://graphics.stanford.edu/courses/cs348n-22-winter/PapersReferenced/normal_estimation_ijcga_04.pdf)Eq.(5):
```
r = [ (d1·σ_n/√(ερ) + d2·σ_n²) / κ ]^(1/3)
```
κ=曲率上界,σ_n=噪声标准差,ρ=采样密度,ε=失败概率。权衡明确:大 r 时曲率项 κr 主导,小 r 时噪声项 n/r 主导 —— **没有任何半径能同时消掉两者**。
**工程读法:最优半径 ∝ 噪声^(2/3)/曲率^(1/3),且误差下限随噪声升、随密度降 —— 噪声大的稀疏云既需要更大半径,又有更差的误差地板。** 另有简并守卫:限制 β = m12/m11 < 1/2。
⚠️ **别把 Mitra & Nguyen 当噪声估计器**:它**假设 σ_n 是输入**,用来求最优邻域半径,不是 σ 的估计子。

**密度/各向异性采样** —— Hackel et al. 2016(CloudCompare 指定的定义来源):小半径在低密度区邻居太少、大半径在高密度区邻居太多;因而选 k-NN,称其为 "an approximation to a density-adaptive search radius"(Hackel 2016),同时承认 radius search 才是正确做法 —— **"至少对密度合理均匀的点云而言"**。这是"密度均匀是这些特征几何意义的前提"的干净陈述。

**⚠️ 稀疏 SfM 点云 —— 关键项**

**存在且只有一篇直接命中**:Farella, Torresani, Remondino 2019, *Sparse Point Cloud Filtering Based on Covariance Features*, ISPRS Archives XLII-2/W15:465–472(CC-BY)。https://isprs-archives.copernicus.org/articles/XLII-2-W15/465/2019/isprs-archives-XLII-2-W15-465-2019.pdf

这是**唯一**把全套 eigenfeature 用在**光束法平差内部产生的真·稀疏 SfM 连接点云**上的论文(不是 MVS)—— 正是我们的场景。特征分配:1D 簇用 Linearity;2D 簇用 Anisotropy+Planarity;3D 簇用 Omnivariance+Eigenentropy;用 Demantké 式维度尺度选择,每点测 60 个半径取最好的 20。

**它自己发布的 caveat 正是我们要找的东西**:结论章说必须探索新的半径选择法,因为 "the low-density of the sparse point cloud could negatively condition the estimation"(Farella 2019),并补充在自己的结果中确实观察到了。§3.2 另说无论 radius 还是 k,"an empiric knowledge of the scene is always required"(Farella 2019)。
**硬数值只有**:簇少于 **10 个点**自动删除;micro-cluster 搜索半径 = **10× 簇内平均点间距**;半径扫描 0.1–6 m 步长 0.1 m。**效果:8 个平面拟合 RMSE 从 1.39 cm 降到 1.03 cm(≈26%)。**
**⚠️ 全文从头到尾没印出任何一个具体阈值数字**,只说 "filtering thresholds were empirically tested",并把"自动定义 eigen-filtering 阈值"列为未来工作。

Becker et al. 2017(https://isprs-annals.copernicus.org/articles/IV-1-W1/3/2017/):Pix4D 摄影测量云 + eigenfeature(k=10,Hackel 式多尺度),其**核心贡献是"加颜色特征"** —— "color features bring a significant improvement"(Becker 2017)。反读:在摄影测量数据上,纯 eigenfeature 基线弱到"加颜色"能成为论文贡献。

**最少邻居数 / 退化** —— Özdemir, Remondino & Golkar 2019 给出两种实测失效模式,第二种最危险:
- radius 搜索点不够 → **点被静默丢弃**
- k-NN 点不够 → **特征照算但无意义**,最近邻 "are far away and this ends up with noise in the features"(Özdemir 2019),归结为 "features can be extracted, but not useful" —— **不报错,数字看着正常,实则是垃圾**

实际守卫值:CloudCompare 邻居<6 记 NaN;Demantké 要求最少 10 点;Farella 要求簇≥10 点。

### 1.4 局部粗糙度 / 壳厚

#### 1.4.1 CloudCompare "Roughness"

**wiki 定义**(https://www.cloudcompare.org/doc/wiki/index.php/Roughness):"the 'roughness' value is equal to the distance between this point and the best fitting plane"(CloudCompare wiki)。邻居 = 以每点为心、半径 = kernel size 的球。<3 邻居 → NaN。**wiki 不说是否含查询点、不说符号、不给默认半径、不给选取指南。**

**⚠️ 关键:查询点被排除在平面拟合之外(已逐行核实)** —— `CCCoreLib/src/GeometricalAnalysisTools.cpp` `case Roughness:`:
```cpp
//find the query point in the nearest neighbors set and place it at the end
std::swap(nNSS.pointsInNeighbourhood[localIndex], nNSS.pointsInNeighbourhood[neighborCount - 1]);
DgmOctreeReferenceCloud neighboursCloud(&nNSS.pointsInNeighbourhood, neighborCount - 1); //we don't take the query point into account!
```
`Neighbourhood.h` 头文件契约同样写 `\warning The point P shouldn't be in the set of points`。
**这是不对称的**:`case Feature:` 与 `case Curvature:` 都传**完整** `neighborCount`,**只有 Roughness 做 `-1`**。含查询点会把 roughness 偏向零。这是上游明确的修正,`CHANGELOG.md` v2.5.4(2014-04-19):"the best fit plane is computed on all the neighbors except the point itself"(CloudCompare CHANGELOG)。

**符号:默认无符号;只有给了 up-direction 才有符号**(`Neighbourhood.cpp::computeRoughness`):
```cpp
ScalarType distToPlane = DistanceComputationTools::computePoint2PlaneDistance(&P, lsPlane);
if (roughnessUpDir) { if (CCVector3::vdot(lsPlane, roughnessUpDir->u) < 0) distToPlane = -distToPlane; }
else               { distToPlane = std::abs(distToPlane); }
```
注意语义:up-direction **不重投影残差**,只在拟合平面法向与 up 反向时翻符号(补偿 LS 特征向量的任意朝向)。出处 `CHANGELOG.md` v2.12.0(2022-03-30):"new option to set a 'up direction' to compute signed roughness values"(CloudCompare CHANGELOG),CLI 子选项 `-UP_DIR X Y Z`。
**守卫**:`neighborCount > 3`(即含查询点 ≥4、去掉后 ≥3);`getLSPlane()` 在共线或 <3 点时返回 null → NaN。

**默认/推荐 kernel 半径:未发布。NOT VERIFIED。** Roughness wiki 与 Compute-geometric-features wiki 都不给默认值或选取规则。

#### 1.4.2 Surface variation / Normal change rate

**"Surface variation"** 是 *Feature*(`Neighbourhood::computeFeature`,特征值**降序**排列故 `l3` 最小):`case SurfaceVariation: { double sum = l1+l2+l3; ... value = l3 / sum; }` → **λ3/(λ1+λ2+λ3)** ✅
**"Normal change rate"** 是 *CurvatureType*(`computeCurvature`):`return eMin / sum;` → **同一个量**,只是用 `std::min` 而非排序。wiki 一致:"it's equal to the smallest eigenvalue divided by the sum of the 3 eigenvalues"(CloudCompare wiki)。
数学相同但实践差异:NORMAL_CHANGE_RATE 需 ≥4 点(恰好 3 点返回 0),octree 门是 `neighborCount > 5` 而 Feature 是 `> 3`。
**Gaussian/Mean curvature 是另一套机制** —— 2.5D 二次曲面拟合(`z = a+bx+cy+dx²+exy+fy²`),不是特征值,且头文件说其值 "is always unsigned"。

#### 1.4.3 License 矩阵(CloudCompare 系,已逐文件核实)

| 组件 | 许可证 | 核实自 |
|---|---|---|
| **CloudCompare**(应用) | **GPL v2 or later** | `license.txt` |
| **CCCoreLib**(roughness/curvature 实际所在地) | **LGPL-2.0-or-later** | `LICENSE.txt` + 每个源文件首行 SPDX |
| **qM3C2 插件** | **GPL v2 or later** | 文件头,`COPYRIGHT: UNIVERSITE EUROPEENNE DE BRETAGNE` |
| **CloudComPy** | **GPL v3 or later** | `License.txt` |

→ 「CloudCompare 是 GPL v2、只可参考不可抄」这个前提**对应用和 qM3C2 插件成立,但 roughness/surface-variation 算法在 LGPL-2.0-or-later 层**。那是实质弱得多的 copyleft —— 但 LGPL §2/§6 的 relinking 义务对静态链接的移动端二进制仍然棘手,所以按"不是 GPL"处理,**不按"自由无碍"处理**。
⚠️ GitHub 侧边栏自动检测对这三个仓都返回 NOASSERTION,**别信**。

#### 1.4.4 摄影测量噪声的标准量法:Range noise(有标准背书)

**权威定义** —— Muralikrishnan, *Performance Evaluation of Terrestrial Laser Scanners – A Review*, NIST(https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=930840):
> "range noise (standard deviation of the residuals from a best-fit to a measured plane)"(NIST)

量级:range errors 是 "sub-millimeter to several millimeters",而 range noise "is on the order of a few hundred micrometers"(NIST)。
**关键**:§3.3 —— "Range noise is a quantity that is required to be reported as part of both the ASTM E2938-15 and ASTM E3125-17 standards."(NIST)
→ **"到最佳拟合平面残差的标准差"是有 ASTM 标准背书的量,不是我们发明的。**

**摄影测量侧具体数字**(球面参考体) —— *Sensors* 20(24):7095(2020),https://pmc.ncbi.nlm.nih.gov/articles/PMC7763574/:拟合球面的平均偏差 TLS 外 **4.7 mm** / 内 4.3 mm;SfM(Agisoft)外 **43.9 mm**(30.3% 的点 >25 mm)、ContextCapture 外 34.6 mm;**SfM(Agisoft)内 3.9 mm**(0.0002% >25 mm)。10× 差距是**光泽 vs 哑光表面**所致 —— 哑光内表面达到了与 TLS 可比的精度。

**入射角模型** —— Soudarissanane et al., ISPRS Laser Scanning 2009:标准差 σ = sqrt(êᵀê/n),ê 为到 LS 拟合平面的残差;1×1 m 白色涂层胶合板,20 m,测角仪 0°→70°。⚠️ 逐角 σ 值只在图里 —— **数值 NOT VERIFIED**。唯一可提取的阈值:标准差 >5 mm 的情形被排除。

#### 1.4.5 Roughness 作为 SfM 噪声代理 —— 一个强先例

**Nocerino, Stathopoulou, Rigon, Remondino, *Surface Reconstruction Assessment in Photogrammetric Applications*, Sensors 20(20):5863 (2020)**,doi 10.3390/s20205863,https://pmc.ncbi.nlm.nih.gov/articles/PMC7594060/

他们**明确区分两个概念**:
- **Roughness** = 顶点到 kernel 半径内邻居最佳拟合平面的绝对距离,**用的就是 CloudCompare 的实现**
- **Noise** = **在选定平面区域上的平面拟合 RMS**

报告的统计量:mean、STDV、median、**NMAD = 1.4826 × MAD**、RMS、outlier %。
具体 roughness 值(mean / RMS):Fountain 1.0 / 1.3 mm;Modena 1.0 / 1.4 mm;Ignatius 0.4 / 0.5 mm;Wooden Ornament 0.02 / 0.03 mm。
**要把 CloudCompare roughness 当 SfM 噪声数字报出来,引这篇。**

**反面参考**:Nikolov & Madsen, *Rough or Noisy? Metrics for Noise Estimation in SfM Reconstructions*, Sensors 20(19):5725 (2020) —— 标题很像,但实际是 **9 特征 + AdaBoost 二分类噪声区域**(准确率 0.851→0.889,F1 0.742→0.756),**不报任何毫米级噪声值**。不是定量基线。

#### 1.4.6 "壳厚" —— 无标准指标,但 MPV 是最接近的已发表构造

⚠️ **明确的负面结论:SfM/MVS 文献中没有标准化的"重建壳厚"指标。** 多种查询表述均无收获。别再找了。

**最接近的已发表、已实现、经同行评议的构造是 Mean Plane Variance (MPV)** —— Razlaw, Droeschel, Holz, Behnke, *Evaluation of Registration Methods for Sparse 3D Laser Scans*, ECMR 2015,https://www.ais.uni-bonn.de/papers/ECMR_2015_Razlaw.pdf

§IV 原文机制:假设环境大部分是平面,在给定半径内从 3D 点近似出一个平面,计算每点到该平面的距离;
> "where **v is the upper quartile of the distances in the radius**"(Razlaw 2015)

MPV = 所有地图点的 v(q_k) 的均值。伴生指标 **MME**:h(q_k) = ½ ln|2πe·Σ(q_k)|,Σ 为半径内样本协方差;"**We select r = 0.3 m** in our evaluation."(Razlaw 2015)

**关键:论文的明示用途正是我们的场景** —— 用于 "assessing pose accuracy without pose ground truth"(Razlaw 2015),度量地图的**锐度(sharpness)**。MPV 是稳健的局部壳厚估计器(上四分位数而非最大值 → 抗离群)。

参考实现(两个指标都有):https://github.com/AIS-Bonn/pointcloud_evaluation_tool

**理论联系** —— Kornilova & Ferrer, *Be your own Benchmark: No-Reference Trajectory Metric on Registered Point Clouds*, arXiv:2106.11351:在局部平面假设下 MPV 与 MME 都归结为 **λ_min**(沿法向的展布)的函数,并在 200 条扰动轨迹上验证了与轨迹误差的相关性。**已记录的失效模式**:当平面点数不均衡或平面非正交时相关性严重退化。另见 CorAl(arXiv:2109.09820)论证 MME 混淆了噪声、采样密度与几何,且不跨结构化/非结构化场景泛化。

#### 1.4.7 "双层墙 / 表面分裂" —— 文献里不是一个被正式测量的病理

⚠️ **NOT VERIFIED**:**没有找到任何同行评议论文定义并测量 SfM/MVS 摄影测量点云中双层壳的层间距。** 两条独立检索路线均空手而归。行业 scan-to-BIM QC 博客用 "ghosting (double images)" 仅作目视检查用词,不可引。

最接近的:
- Qin & Qiu, *Diffusion-Driven Inter-Outer Surface Separation for Point Clouds with Open Boundaries*, arXiv:2602.00739 —— 把该 artifact 命名为 "double surface artifact",归因于 **TSDF 截断(不对称阈值)** 产生的虚假内外壳。⚠️ **未提供任何层间距的定量测量**,只报运行时间。
- 通用 TSDF 文献指出融合"无法表示比体素尺寸更薄的东西",且位姿噪声导致表面增厚 —— 但 DFusion(*Sensors* 22(4):1631)403 无法抓取,**具体增厚数值 NOT VERIFIED**。

**一条必须带走的方法论硬约束** —— DVW Guideline 18-2022, *TLS Point Cloud Registration*(德国测量协会,2023-04-24):**在完全相同的配准参数下**,同一数据集在 point-to-point 对应下得 **7.8 mm**、在 point-to-triangle 下得 **3.4 mm**(Figs. 26–28);再加一个 3.0 mm 对应阈值,能把 12.0/2.6/2.9/12.7 mm 的残差报成 2.75 mm 的"质量",把 3.4 mm 那例变成 2.55 mm。指南自己称之为 irritating。
https://dvw.de/api/assets/downloads/ev/publikationen/merkblatter/18_23_dvwguideline18tlspointcloudregistration20230424.pdf

→ **我们发布的任何壳厚或噪声数字,必须同时声明使用的距离算子(point-to-point / point-to-plane / point-to-triangle)以及是否施加了截断阈值**,否则与任何人的数字都不可比。

### 1.5 基准级评估(ETH3D / T&T / DTU / Middlebury / C2C / C2M / M3C2)

#### 1.5.1 ETH3D(Schöps et al., CVPR 2017)

论文 PDF: https://www.eth3d.net/data/schoeps2017cvpr.pdf · 榜单 https://www.eth3d.net/high_res_multi_view · 代码 https://github.com/ETH3D/multi-view-evaluation

**方向(§4 逐字核实)**:
- **Completeness**:先测每个 GT 点到最近重建点的距离,然后是 "the amount of ground truth points for which this distance is below the evaluation threshold"(Schöps 2017 §4)。→ **GT→重建**
- **Accuracy**:"Accuracy is defined as the fraction of reconstruction points which are within a distance threshold"(Schöps 2017 §4)。→ **重建→GT**

**容差值 —— 六档,不是四档**:high-res multi-view(DSLR)与 low-res many-view **完全相同**:**1cm / 2cm / 5cm / 10cm / 20cm / 50cm**。论文 §4:"Both measures are evaluated over a range of distance thresholds from 1cm to 50cm."(Schöps 2017)。评测程序默认 `--tolerances 0.01,0.02,0.05,0.1,0.2,0.5`。榜单默认排序键 = **F1 @ 2cm**。
⚠️ low-res **two-view** 场景完全不是 3D 协议 —— 论文明说它 "is evaluated in 2D with a separate protocol",照搬 Middlebury 2014 视差指标(bad 0.5/1.0/2.0/4.0、avgerr、rms、A50/A90/A95/A99),**没有 cm 容差**。

**遮挡 / GT 不完整的处理(ETH3D 最独特的机制)**,三步:
1. **两图可见性门**:"Only laser scan points visible in at least two images are used for evaluation."(Schöps 2017)
2. **激光束自由空间建模**:每个 GT 点的激光束建模为**截头圆锥**,假设从扫描仪原点到扫描点的束体积内**只有自由空间**;把束体积向 GT 点之外延伸,延伸部分 = 扩展圆锥 ∩ 以观测点为心、**半径 = 当前容差 t** 的球。
3. **三分空间**:重建点落在所有 extended beam volume **之外 → 判为 unobserved,直接丢弃不计**;其余点落在束内且距某 GT 点 < t → accurate。
代码参数:`--beam_start_radius_meters` 默认 `0.5 × 0.00225`(1.125 mm)、`--beam_divergence_halfangle_deg` 默认 **0.011°**。

**⚠️ 防作弊的体密度归一化(常被忽略,对我们很关键)**:论文明说 accuracy/completeness 都易受两侧点云密度影响 —— "an adversary could uniformly fill the 3D space with points"(Schöps 2017);对策是把空间离散成小边长体素,**先逐体素算 accuracy/completeness,再对所有体素取平均**。代码参数 `--voxel_size` 默认 **0.01 m**。

**有没有独立 noise/outlier 指标?**:**没有**。只有 accuracy / completeness / F1。离群点被吸收进两处:accuracy 的分母,以及 unobserved 判定 —— **离群点若落在自由空间外反而被丢弃、不受惩罚**。**ETH3D 对"飞到无观测区的鬼点"是宽容的。**

**F1** = 调和平均 2·p·r/(p+r)。
**License**:**BSD**(实为 BSD 3-Clause),Copyright 2017 Thomas Schöps, Johannes L. Schönberger。https://raw.githubusercontent.com/ETH3D/multi-view-evaluation/master/LICENSE.txt ⚠️ GitHub API 报 `NOASSERTION`(LICENSE.txt 是 BSD 正文 + 依赖清单的混合文件),已读原文确认。

#### 1.5.2 Tanks and Temples(Knapitsch et al., TOG 36(4):78, 2017)

论文 PDF: https://storage.googleapis.com/t2-downloads/paper/tanks-and-temples.pdf · 教程 https://www.tanksandtemples.org/tutorial/ · 代码 https://github.com/isl-org/TanksAndTemples

**定义(§6 "Measures")**:
```
e_{r→𝒢} = min_{g∈𝒢} ‖r − g‖                                  (3)
P(d) = (100/|ℛ|) Σ_{r∈ℛ} [ e_{r→𝒢} < d ]                      (4)   ← Iverson 括号,严格小于
e_{g→ℛ} = min_{r∈ℛ} ‖g − r‖                                   (5)
R(d) = (100/|𝒢|) Σ_{g∈𝒢} [ e_{g→ℛ} < d ]                      (6)
F(d) = 2·P(d)·R(d) / (P(d) + R(d))                            (7)
```
榜单主指标 F(τ)。

**逐场景 τ(论文 Table 1,单位 mm)**

Intermediate(8 景):Family **3**、Francis **5**、Horse **5**、Lighthouse **10**、M60 **10**、Panther **10**、Playground **10**、Train **10**
Advanced(6 景):Auditorium **10**、Ballroom **10**、Courtroom **10**、Museum **10**、Palace **30**、Temple **15**
Training(7 景,论文 Table 1 未列,来自评测代码 `python_toolbox/evaluation/config.py`,该 dict 标注 "global parameters - do not modify"):Barn 0.01 m、Caterpillar 0.005、Church 0.025、Courthouse 0.025、Ignatius 0.003、Meetingroom 0.01、Truck 0.005

**τ 怎么定的(对我们最重要的一条)**:论文 §5 —— 逐场景检查数据并计算 **GT 点云中最近邻距离的统计量**来设定 τ。即 **τ ≈ GT 自身采样间距量级,不是感知阈值,是采样密度的函数**。

**裁剪 / 重采样 / 对齐**:
1. **Cropping**:每个 GT 模型配一个**多边形棱柱(polygonal prism)**包围体,底面多边形任意复杂,**人工在交互界面里画**;重建点云裁到该体积内。
2. **Resampling**:GT 与对齐后的重建**用同一体素栅格重采样,体素边长 = τ/2**,同体素多点取均值。
3. **Alignment**:重建相机位姿配准到 GT 相机位姿得粗 Sim(3);再最小化 E(T)=Σ‖p−Tq‖²,用 **Umeyama** 求解,并用**扩展到相似变换(含尺度)的 ICP** 精化。

⚠️ **T&T 没有 ETH3D 那种自由空间/观测掩膜机制。** GT 不完整只靠人工包围体裁剪处理 → **T&T 的 precision 会惩罚包围体内的鬼点(ETH3D 可能直接丢弃它们)。两个 benchmark 对离群点的严厉程度不同,别混用直觉。**

**独立 noise/outlier 指标:没有。** 论文明确 precision 就是准确性代理,并指出 "Precision alone can be maximized by producing a very sparse set of precisely localized landmarks"(Knapitsch 2017)。

**License**:评测代码 **MIT**("The Python scripts in this repository are under the MIT license" — T&T README);**数据集 CC BY 4.0**(https://www.tanksandtemples.org/license/)—— **对我们可商用,比多数 benchmark 干净**。

#### 1.5.3 DTU(Jensen et al., CVPR 2014)

论文 PDF: https://www.cv-foundation.org/openaccess/content_cvpr_2014/papers/Jensen_Large_Scale_Multi-view_2014_CVPR_paper.pdf · 官方 MATLAB 镜像 https://github.com/cdcseacave/DTUeval

**定义(§4.2)**:"Accuracy is measured as the distance from the MVS reconstruction to the structured light reference"(Jensen 2014),completeness 从参考量到 MVS。方向与 ETH3D/T&T 一致,但 —— **关键区别 —— DTU 报的是距离本身的 mean 与 median,单位 mm,不是百分比**。论文 Fig.4 四根柱子就是 Mean Accuracy / Med. Accuracy / Mean Complete / Med. Complete,纵轴 mm。

**离群裁剪阈值:20 mm(已核实)**。论文 §4.2 末:"removing all distances over 20 mm. We remove points to avoid biasing by outliers."(Jensen 2014)。代码 `ComputeStat_web.m`:`MaxDist=20;` 然后 `Dstl=Dstl(Dstl<MaxDist);`。
⚠️ **"60mm" 在原论文中不存在** —— 官方口径就是 20 mm。

**⚠️ 降采样是 0.2 mm,不是 20 mm**:论文 §4.2 "we decimate the MVS point clouds so that no two points are closer than 0.2 mm"(Jensen 2014);理由是 depthmap-fusion 类方法在强纹理区产点更多,不降采样会让误差度量偏向稠密区;0.2 mm 匹配参考重建的估计分辨率。**副作用是保留了低密度区的离群点。** 代码 `BaseEvalMain_web.m`:`dst=0.2;`

**ObsMask(§4.1)**:= 49 或 64 次结构光扫描各自可见性掩膜的**并集**;**体素边长 1 mm**;从相机向重建点投射射线,**射线再延长 10 mm**,沿途体素标为 observed。那 10 mm 是"把结构光点正后方的立体点包含进来"所需的深度假设,是在误纳与误排之间的折中。

**独立 outlier 指标:没有。** 离群处理是**双重隐式**的:(a) 20 mm 硬截断把极端离群直接删掉 —— **DTU 的 accuracy 构造性地看不见 >20 mm 的飞点**;(b) 另做 meshing 去除。
⚠️ **对我们的直接含义:DTU 的 mean accuracy 对鬼层/飞点几乎无感(20 mm 截断 + 0.2 mm 降采样双双削弱离群惩罚)。想用 DTU 口径衡量鬼层问题会失灵。**

**License**:官方 MATLAB 常见镜像 `cdcseacave/DTUeval` **无 LICENSE 文件**(GitHub API `null`)→ 按铁律 = 保留所有权利,不可商用照抄。纯 Python 重实现 https://github.com/jzhangbs/DTUeval-python **MIT**(自称与官方平均偏差 0.0153%)—— **唯一干净可用的 DTU 口径实现**。

#### 1.5.4 Middlebury MVS(Seitz et al., CVPR 2006)

PDF: https://vision.middlebury.edu/mview/seitz_mview_cvpr06.pdf(⚠️ 站点 eval 表自 2023-06 起已失效)

**两个数字全部核实通过**:
- §5:"We used an accuracy threshold of 90%"(Seitz 2006)→ accuracy 报的是**第 90 百分位距离**(accuracy = 1.0 mm 意味着 90% 的重建点在 GT 网格 1 mm 内)
- §5:"For completeness, we used an inlier threshold of 1.25mm"(Seitz 2006)

**注意两者不对称**:**accuracy 是"给定百分位、报距离(mm)";completeness 是"给定距离 1.25 mm、报百分比(%)"**。§4 给出一般化定义:算出距离 d 使 R 上 X% 的点在 G 的 d 之内;X=50 即中位距离。

**GT 不完整处理**:构造 **hole-filled 版本 G′**(space carving 生成补洞面),重建点若最近点落在补洞区就从 accuracy 里剔除;G 有逐顶点置信度,低置信区忽略。completeness 侧无法同样处理,改为报"G 中距 R 在允许距离内的点的比例",论文承认副作用:noisy 重建会拿到更低的 completeness。评测前先用 ICP 对齐。
**独立 outlier 指标:无。**

#### 1.5.5 交叉问题:有没有 benchmark 在无 GT 下衡量噪声?

**没有。四个 benchmark 全部需要 GT,零例外。**

**哪些机件是 datum-free 的(可搬到 A-vs-B)**:

| 机件 | datum-free | 说明 |
|---|---|---|
| **T&T 的 P(d)/R(d)/F(d)** | ✅ **完全可以** | 式 3–7 只是两点集之间的双向最近邻统计,把 A 当 pseudo-GT 即可直接跑。**四家里最容易移植的一套。** |
| T&T 的 τ/2 体素重采样 | ✅ | 纯预处理约定 |
| T&T 的 Umeyama + Sim3 ICP | ✅ | 但我方有 SCALE-ANCHOR,同 gauge 直出时应**禁用**(与既有铁律一致) |
| **ETH3D 的逐体素密度归一化** | ✅ | 反作弊层与 GT 无关,可直接套在 A-vs-B 上,**建议采纳** —— 否则谁点多谁占便宜 |
| ETH3D 的激光束自由空间 / unobserved 判定 | ❌ | 构造性依赖扫描仪射线原点,无法复刻 |
| ETH3D 的"至少两图可见"门 | ⚠️ 半可以 | 我方有位姿可近似,但那是自指的(点本来就从这些观测生的) |
| **DTU 的 0.2mm 抽稀 + 20mm 截断** | ✅ | 纯约定可借,但截断会**掩盖**离群 |
| DTU 的 ObsMask | ❌ | 需要参考扫描的可见性 |
| **Middlebury 的"第 X 百分位距离"读法** | ✅ | **对我们最有价值**:比"< τ 的百分比"能直接量出鬼层厚度,与 σ_depth / 双层地板口径同构 |
| Middlebury 的 hole-filled G′ + 置信度 | ❌ | 需要 GT 网格 |

**把 A 当 pseudo-GT 意味着什么(诚实版)**:
- 得到的是 **agreement(一致性)不是 correctness(正确性)**。
- **共享的系统误差完全隐形**:若 A 和 B 都长了同一层鬼壳、同样的尺度偏差、同样的双层地板,F 会给满分。**这正是我们最想抓的那类病理 —— 所以 M2 必须与 M1/M4 配套,不能单用。**
- 但对**回归检测**有效且成本极低,与我方「逐位一致 → 噪声带内 → 肉眼并排」文化是同一层工具的不同刻度。
- **不对称性有信息量**:P 掉而 R 不掉 = B 多了新点(可能是新增噪声);R 掉而 P 不掉 = B 丢了点。
- **τ 该取多少没有可移植答案** —— T&T 是按 GT 最近邻距离统计定的,我们要定就得按**自己点云的最近邻间距分布**定,**不能抄 T&T 的 mm 数**。

#### 1.5.6 C2C(cloud-to-cloud)与 C2M(cloud-to-mesh)

**C2C**(https://www.cloudcompare.org/doc/wiki/index.php/Cloud-to-Cloud_Distance):"the cloud to cloud distance is simply the nearest neighbor distance"(CloudCompare wiki),并坦承 "the nearest neighbor is not necessarily ... the actual nearest point on the surface"(CloudCompare wiki)。
局部模型按"对局部几何的保真度递增(计算时间也递增)"排序:① Least Squares Plane ② 2D½ Delaunay triangulation ③ **Quadric(height function)**`Z = a·X² + b·X + c·XY + d·Y + e·Y² + f`(wiki 推荐为默认:"it's the more versatile")。
Distances Computation 页警告:局部建模 "can locally produce *strange* results ... but it gives much better results on a global scale"(CloudCompare wiki)。

**C2M**:云顶点到参考网格三角形的垂距。**符号可选**:"signed distances: whether computed distances should be signed with the triangle normal or not"(CloudCompare wiki),另有 flip normals 选项。先显示的 "approximate distances" 明确"不应视为正式测量值"。

**⚠️ 为什么 plain C2C 有偏 —— 引 Lague et al. 2013 §2.2/§3.4(全部一手核实)**:
- **无符号且恒 ≥0**。§2.2 指出带符号版本只存在于商业软件(Polyworks),且没有空间可变的置信区间。
- **零真变化下的假阳性**:合成平坦云,点距 dx = 1 mm、高斯噪声 σz = 1 mm,C2C 与 C2C_HF **"detect an average change of 0.5 and 0.9 mm"**(Lague 2013)—— 而真实变化为零。
- **点距规则(你要的那条)**:论文原话是 —— 若点坐标不对齐(不同时期的测量典型如此),**"a change up to half the point spacing can be predicted when no change occurs"**(Lague 2013)。
  ⚠️ **"1/4 点距"这个数字:NOT VERIFIED** —— 没找到任何已发布来源。**已发布的数字是"一半"点距**,且是伪变化的上界。
- **参考云噪声造成的系统偏移**:dx = 1 mm 时 C2C **"systematically offset by 1.95 mm"**(Lague 2013)。
- **偏差量级**:真实垂直位移 4 mm 时,"LC2C = 2.56 mm for dx=1mm and 6.16 mm for dx = 10 mm"(Lague 2013)—— **细间距下低报、粗间距下高报,误差方向不可预测**。
- **局部模型不可靠地修复它**:height function "sometimes offers a significant improvement ... but can be less precise than a simple closest point comparison if the roughness is of the same order as the point spacing"(Lague 2013)。
- **§3.4 裁决**:现有最近点算法 "are prone to unpredictable bias for small surface change detection"(Lague 2013),只适合快速检测"显著大于点距和粗糙度"的变化。
- 同一测试中 **M3C2 恢复位移误差在 0.003 mm 内**,逐点标准差 0.15 mm vs C2M 的 1.00 mm。

次级佐证:Diaz et al., *Comparison of Cloud-to-Cloud Distance Calculation Methods*, 3D GeoInfo 2023 —— 比较 8 种方法,结论 "a more complex method is not necessarily the most suitable"。⚠️ 其精度总结句自相矛盾,只作方向性参考、不可引作阈值。https://www.gdmc.nl/publications/2023/3DGeoInfo_ComparePC.pdf

#### 1.5.7 M3C2 — Lague, Brodu, Leroux 2013 ⭐

**引文核实**(Crossref):ISPRS J. Photogramm. Remote Sens. **82:10–26**, 2013-08, DOI **10.1016/j.isprsjprs.2013.04.009**。预印本 arXiv:1302.1183(已提取全文读 §3)。

**精确算法**:
- **Core points**(§3.1.1):抽稀后的参考云;所有计算仍用原始数据。
- **Step 1 — 法向(§3.1.2)**:对 core point i,"a normal vector is defined for each cloud by fitting a plane to the neighbours"(Lague 2013)—— 邻域是**半径 D/2** 内的点,即 **D 是直径不是半径**。法向按用户给的 orientation point 定向。邻居到该平面距离的标准差记为 σi(D),即尺度 D 上的 **detrended roughness**。可选用云1、云2 或两者平均的法向(平均"makes the measurement reversible")。
- **Step 2 — 距离(§3.1.3)**:"defining a cylinder of **radius d/2** whose axis goes through i and which is oriented along the normal"(Lague 2013)。与两片云的交集给出大小 n1、n2 的子集;投影到轴上得两个一维分布,**均值**给 i1、i2,**标准差**给沿法向的 σ1(d)、σ2(d)。
  "The local distance between the two clouds LM3C2(i) is then given by the distance between i1 and i2."(Lague 2013)
  稳健变体:位置用**中位数**,粗糙度用**四分位距**。**最大圆柱长度 L** 用于加速。**若圆柱在对比云中找不到交集则不计算数值**(不是 0、不是插值)。
- **符号(从参考实现核实)** —— py4dgeo `lib/distances.cpp` `mean_stddev_distance`:
  ```cpp
  std::get<0>(ret) = params.normal.row(0).dot(mean2 - mean1);
  ```
  → 字面上是 **n · (i2 − i1)**:**有符号,沿法向为正**。论文结果报负值(岸线侵蚀 "by up to − 2.7 m"),印证该约定。

**Level of Detection —— Eq.(1),§3.3**:
```
LOD95%(d) = ±1.96 · ( sqrt( σ1(d)²/n1 + σ2(d)²/n2 ) + reg )
```
⚠️ **网上大量二手来源写错了** —— 有把 `reg` 写进根号内的(`1.96·√(σ1²/n1+σ2²/n2+reg²)`)。**那不是论文写的,也不是参考实现做的。** py4dgeo `lib/distances.cpp`:
```cpp
double lodetection = 1.96 * (std::sqrt(variance1/n1 + variance2/n2) + params.registration_error);
```
**`reg` 加在根号之外、括号之内。**

**`reg` 的含义**(§3.3):两片云之间的配准误差,"hereby assumed isotropic and spatially uniform"(Lague 2013)。**它是唯一承载共配准/基准不确定度的项**,在 CloudCompare 与 py4dgeo 中**默认为 0**。他们的实测中是 5 次测量/3 年上均值 2.34 mm(基于标靶)。

**常数 1.96**:n1、n2 > 30 时成立;否则理论上应用双尾 t 统计量配 Welch–Satterthwaite 自由度。但他们的实证结论是:**只要 n1、n2 > 4,Eq.(1) 就足够好**;低于 4 点则不估计置信区间(距离仍照算)。

**σ 的含义**:σ1(d)、σ2(d) 是投影圆柱内**沿法向测得的局部粗糙度** —— 它把真实表面粗糙度、法向失准、仪器噪声一并吸收。

**论文给出的算例**:完全平坦表面、法向入射,Leica ScanStation 2 @ 50 m → σ1 = 1.41 mm(与 d 无关)。d 内每云 100 点、reg = 0 → **LOD95% = ±0.33 mm**。

**参数选择(论文确切数字)**:
- **法向尺度 D**:ξ(i) = D / σi(D);法向定向误差幂律 `Enorm(%) ≈ 1.3×10⁵ · ξ^−3.5`,"choosing Enorm < 2 % corresponds to ξ ~ 20-25"(Lague 2013)。§3.2:**"D should be at least 20 to 25 times larger than the roughness σ(D)"**(Lague 2013)。§7 补充:**"there is no way to predict a priori the exact scale D"**(Lague 2013)。
  自动模式:在用户给的尺度区间(如 0.5–15 m 步长 0.5 m)上做 PCA,取**第三主成分最小**(最平面)的尺度,并强制**至少 10 点**。他们的数据中最优 D 跨约两个数量级;97% 满足 ξ(D)>25。
- **投影尺度 d**:**"d should be chosen to be large enough to average a minimum of 20 pts"**(Lague 2013)(例:点密度 1 pt/cm² 时 d ~ 15 cm),但要小到不因空间平均而降低测量分辨率。他们场景的经验区间是 **0.3 m < d < 2 m**。
  ⚠️ 对粗糙表面(落石碎屑)当 d > 1–2 m 时,预测的 LOD95% **过小**、会误报显著变化;归因于高斯统计不适用于自仿射表面(bootstrapping 也没救回来)。LOD95% ≈ (d/l0)^0.95(l0 = 0.5 m)。
- **Core point 间距**:投影尺度 50 cm 时,"little interest in using a core point spacing smaller than 10 cm"(Lague 2013)—— 约 d 的 1/5。
- **最大深度 L**:论文只说用于加速,无数值规则。CloudCompare 插件的 guess-params 硬编码 `projDepth = 5 * projScale`。

**⭐ 对我们最关键的两条:datum-free 吗?双边吗?—— 都是 YES**
- **datum-free**:只需要已配准的云 A 与云 B。不需要网格、DEM、外部真值。§6.1.1:"The M3C2 method do not require gridding or meshing of the point cloud."(Lague 2013)。唯一的外部量是标量 `reg`,那是**你提供的一个数字,不是一个参考数据集**,且两个实现都默认 0。
- **有符号/双边**:是,`n · (i2 − i1)`。

**假设与失效模式(全部来自论文)**:
- 两片云必须是**同一场景**且**已配准**。配准质量只通过 `reg` 进入。附录 A 结论:ICP "will not yield high-precision registation (i.e., < 1 cm) in natural environment"(Lague 2013),并指出 ICP "is based on a closest point measurement"(Lague 2013),因此可能有与 C2C 相同的缺陷。
- **尺度 D 上必须局部平面** —— 这是法向估计的全部前提。Fig.3b:若 D ≤ 粗糙度尺度,法向朝向剧烈变化,"This will tend to overestimate the distance between the two clouds."(Lague 2013)
- 若尺度 d 上的表面与 D 上估的法向不正交,σ1(d) 是"表观"粗糙度、大于真实 detrended 粗糙度 → LoD 膨胀(**自我保护但保守**)。
- **缺数据 → 不出结果**,这是设计。
- 大 d + 自仿射粗糙表面时高斯 LoD 失效(过检测)。
- 需要选用哪片云的法向;在表面朝向变化处答案会变。

**实现与许可证(逐 LICENSE 核实)**:

| 实现 | 许可证 |
|---|---|
| CloudCompare **qM3C2** 插件 | **GPL v2 or later** |
| **py4dgeo**(https://github.com/3dgeo-heidelberg/py4dgeo) | **MIT** ✅(`LICENSE.md` 逐字 MIT;`pyproject.toml` `license = "MIT"`;GitHub API `spdx_id: MIT`) |
| CloudComPy | GPL v3 or later |

**py4dgeo 是干净的那个** —— MIT,且上面引的 LoD 代码就是它。

**⚠️ CloudCompare 插件参数坑**:wiki 说 normal scale = "the diameter of the spherical neighborhood",max depth = "the cylinder height (*in both directions*)"。`CHANGELOG.md` **v2.13.0(2024-02-14)修了一个真 bug**:"the 'Guess parameters' option of the M3C2 plugin was suggesting radii while M3C2 scales are diameters"(CloudCompare CHANGELOG)—— **2.13 之前 guess 出来的参数差 2×**。
UI 默认:registration error **0.0**(复选框关)、min points for stats **5**、preferred orientation **+Z**;对话框探测阈值是 `getMinPointsForStats() * 6` = **30**,刻意对齐论文的 n>30。

**M3C2-EP**(Winiwarter, Anders, Höfle, ISPRS J. P&RS 178:240–258, 2021, doi 10.1016/j.isprsjprs.2021.06.011)把标量 `reg` 换成逐 core point 传播的完整 12×12 对齐协方差。同样在 py4dgeo(MIT)中。

#### 1.5.8 无参考点云质量评估(NR-PCQA)—— 对我们不可用

主流方法索引:https://github.com/zzc-1998/Point-cloud-quality-assessment(3D-NSS、ResSCNN、IT-PCQA、PQA-Net、GPA-Net、MM-PCQA、AFNet、LMM-PCQA)。

**三条否决理由,逐条有据**:
1. **几乎全部依赖颜色/纹理**。IT-PCQA / PQA-Net / GMS-3DQA / AFNet / MM-PCQA / LMM-PCQA 全走渲染投影图;ResSCNN 的 sparse tensor 特征维就是 RGB;3DTA 代码 `point_set[:,0:6]` 明确 xyz+rgb。**唯一的 geometry-only NR 方法只有两篇且同一个组**:PRL-GQA(arXiv:2211.01205)与 LRL-GQA(arXiv:2502.11726,代码**无 LICENSE 文件**)。LRL-GQA 论文自己指出现有 geometry-only 几何质量评估方法**都是 full-reference 手工度量**。
2. **跨库泛化崩塌**。GC-PCQA(arXiv:2411.07728)Table VII:SJTU 训练 → WPC 测试,3D-NSS SRCC **0.1352**、ResSCNN 0.2329、PQA-Net 0.1177、IT-PCQA 0.1949。同库能到 0.88–0.93 的模型,换一个**同样是压缩+高斯噪声**的库就掉到 0.12–0.40。
3. **没有任何一篇在 SfM 重建 artifact 上验证过**。训练失真清一色是 octree/G-PCC/V-PCC 压缩、高斯噪声、降采样。LS-PCQA 的 31 类失真里唯一沾边的 `PoissonReconstruction` 是"对干净点云做泊松重建当失真",不是 SfM 的离群/鬼壳/双层。最接近的公开测试点是 PointQ-Bench(arXiv:2605.28241,含 499 个从 CO3D 真实多视角视频重建的样本),⚠️ **具体数值 NOT VERIFIED**,定性结论(该 benchmark 存在的动机)成立。

**License 实查**:MIT = 3D-NSS、COPP-Net、3DTA-PCQA;Apache-2.0 = QD-PCQA;**无 LICENSE 文件** = MM-PCQA、ResSCNN、IT-PCQA、PQA-Net、GMS-3DQA、LMM-PCQA、LRL-GQA → 按铁律不可商用。GPA-Net 代码仓 404。

**唯一贴近需求的非学习无参考量**:**TVPC(Total Variation for Point Clouds)** —— Noise2Score3D(https://arxiv.org/abs/2503.09283)提出的**无参考**去噪质量度量,并用 σ* = argmin_σ TVPC 盲估未知噪声参数。⚠️ **公式细节为二手转述,NOT VERIFIED**;但"用 TV 最小化盲估 σ"的机制在摘要里明写。
⚠️ **别误用 3D-DaVa**(ACM JDIQ 2025, doi 10.1145/3711817):虽然量化 noise/outliers/missing values 三维度,但 pipeline **输入是点云 + 其参考模型**,是 reference-based。

### 1.6 SfM 论文实际报告的"噪声"

#### 1.6.0 总判决(先行)

真正 **datum-free(只需重建自身)且同时对 7-DoF 相似变换 gauge 免疫**的,只有**无量纲的比值型 / 角度型 / 计数型**量。**绝对 per-point sigma(米)是 datum-free 的,但不是 gauge-free(随尺度 s² 缩放),业界不存在已发表的绝对阈值。**

| 度量 | datum-free | gauge-free | 已发表阈值 |
|---|---|---|---|
| 三角化 / 视差角 | 是 | 是 | 有(1.5° / 16° / 23°) |
| Track length | 是 | 是 | 有(≥3;2-view 不可靠) |
| Reprojection error(px) | 是 | 是 | 有(0.3 px / RMS 0.13–0.18) |
| **误差椭球特征值比 sqrt(λmax/λmin)** | 是 | **是** | **有(10 / 15 / 3.16)** ⭐ |
| BA 点协方差绝对 sigma(米) | 是 | **否** | **无(构造性不存在)** |

#### 1.6.1 BA 协方差 / 逐点 3D 不确定度

**机制**:H ≈ JᵀJ,按 [poses/others | points] 分块,Schur 消元 S = H_aa − H_ap H_pp⁻¹ H_pa,回代恢复结构块。出处 Triggs et al., *Bundle Adjustment — A Modern Synthesis*, 1999/2000 §6.1 + §B(https://www.cs.jhu.edu/~misha/ReadingSeminar/Papers/Triggs00.pdf)。

**Gauge 问题(关键)**:Triggs §9 定论 —— 协方差依赖所选 gauge;§9.3 指出**只有 gauge 不变量才有坐标系无关的协方差**,inner constraints 对应加权 Moore–Penrose 伪逆(自由网平差)。Ceres 文档也有专门的 "Gauge Invariance" 小节,承认 SfM 重建只确定到相似变换。

**COLMAP 确实暴露逐点协方差**(逐行核实):
- 头文件 https://raw.githubusercontent.com/colmap/colmap/main/src/colmap/estimators/covariance.h
- API:`BACovariance::GetPointCov(point3D_t)`;入口 `EstimateBACovariance(...)`;`Params` 枚举 POSES / POINTS / POSES_AND_POINTS / ALL
- **字面默认值:`double damping = 1e-8;`**(covariance.h L106)
- **实际算法**(covariance.cc L103–122):`H_pp = J_pᵀJ_p`,逐点取 3×3 对角块 `+ damping·I`,**直接求逆**
- **⚠️ 语义关键**:源码注释原文 "Point covariance conditioned on fixed pose/other parameters"(COLMAP covariance.cc)—— 这是**条件协方差(位姿视为固定)**,不是 marginal。因此 (a) 绕开了位姿 gauge,(b) **系统性低估**真实点不确定度。
- 版本:`covariance.h` 在 tag **3.10 存在、3.9.1 不存在**;3.10 只给 pose 协方差;`GetPointCov` 自 **3.11.1** 起可用。pycolmap 已绑定 `estimate_ba_covariance` / `get_point_cov`。
- **✅ 我方 vendored 副本已包含 covariance.cc/h,`GetPointCov` 与 `damping=1e-8` 均在位**(`~/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/colmap-src/colmap/estimators/covariance.h`)

**Ceres `Covariance` 类默认值**(https://raw.githubusercontent.com/ceres-solver/ceres-solver/master/include/ceres/covariance.h,逐行核实):
`algorithm_type = SPARSE_QR`(L247)、`column_pivot_threshold = -1`(L261)、`min_reciprocal_condition_number = 1e-14`(L294)、`null_space_rank = 0`(L329)、`num_threads = 1`(L331)、`apply_loss_function = true`(L339)。
文档要点:J 秩亏时退化为 Moore–Penrose 伪逆;**SPARSE_QR 在秩亏时无法计算协方差**,DENSE_SVD 可以。**协方差计算假定残差协方差为单位阵** —— 观测噪声不是 1 px 时必须自己按 S^(-1/2) 缩放 cost,否则 sigma 单位是错的。

**Bundler**:README grep `covarian|uncertain|sigma` 无命中,`bundle.out` 格式不含协方差(负面结果,已核实)。

**已发表的「可接受 per-point sigma」阈值:不存在。** 这是构造性的 —— 绝对 sigma 依赖 gauge/尺度,跨项目不可比。**(这是核实过的负面结论,不是"没查"。)**

#### 1.6.2 Track length

**COLMAP 源码里的硬证据**:
- `IncrementalTriangulator::Options::ignore_two_view_tracks = true`(**默认开**)。实现(incremental_triangulator.cc L205–208、L495–501)调用 `correspondence_graph_->IsTwoViewObservation()`,若该特征在整个 correspondence graph 中只被两张图观测到则**直接跳过不三角化**。
- **最小 track 长度 = 2**:`FilterPoints3DWithLargeReprojectionError` 中 `if (point3D.track.Length() < 2) DeletePoint3D(...)`;`DeleteObservation` 中 `if (point3D.track.Length() <= 2) { DeletePoint3D(...); return; }`
- **`colmap point_filtering` CLI 字面默认三元组**(`src/colmap/exe/sfm.cc` L542–544):
  ```
  int    min_track_len     = 2;
  double max_reproj_error  = 4.0;
  double min_tri_angle     = 1.5;
  ```
  对应 API `FilterPoints3DWithShortTracks(min_track_length)` —— **该 API 只被这个 CLI 调用,增量管线里不调用**。
- **⭐ COLMAP 自己按 track 长度加权点的影响力**:`DelaunayMeshingOptions::visibility_sigma = 3.0`,权重 `alpha_vis = 1 − exp(−n²/(2σ²))`,n = `track.Length()`:

  | track n | 2 | 3 | ≥4 |
  |---|---|---|---|
  | alpha_vis | **0.199** | 0.394 | **1.000** |

  即 COLMAP 的 Delaunay 重建里,**2-view 点的投票权只有 4-view 以上点的 1/5**。这是上游对"短 track 不可靠"的量化表态。
  (源码里 `visibility_threshold_ = 5*visibility_sigma = 15` 被拿来与 **n²** 比较,量纲不一致导致饱和极早 —— 此为读源码的观察,非上游文档表述。)

**厂商官方表述**:
- Agisoft Metashape 手册 "Image count":只在两张照片上可见的点很可能定位精度很差。https://www.agisoft.com/pdf/metashape-pro_2_2_en.pdf
- Pix4D 官方支持页原文:**"3D points generated from 2-3 images are less precise"**(Pix4D)。https://support.pix4d.com/hc/en-us/articles/202558689

⚠️ **"track≥3 误差低 X%" 这类量化数字:未找到。** COLMAP 论文(Schönberger & Frahm CVPR 2016)逐页检索确认没有。一篇 ISARC 2017 疑似有但未逐页核实 → **NOT VERIFIED,勿引用**。

#### 1.6.3 为什么 reprojection error 是弱指标

**两条独立理由**:

1. **它是被优化的拟合残差,不是独立质检。** 重投影残差就是目标函数值(内符合精度)。Triggs et al. 专列 §10「Quality Control」另立诊断检验,正是因为代价函数值不能当质量证明。USGS OFR 2021-1039 的工作流构造性地印证:每次删点后都要重新 Optimize Cameras,报告自己反复告诫这会 "overfit the camera model"(USGS 2021)。

2. **小视差下点可沿视线大幅滑动而几乎不改变重投影误差。** 三条可引来源:
   - **⭐ Beder & Steffen, DAGM 2006** —— 最贴题。置信椭球的 roundness 直接关联该点 3D 重建的 **condition number**。定义 **R = sqrt(λ₃/λ₁) ∈ [0,1]**;两相机中心重合时 R=0。**阈值 T = sqrt(1/10)**,理由是把 condition number 控制在约 10。绕物旋转时最优射线夹角 90°,直线平移时约 35°。https://www.ipb.uni-bonn.de/pdfs/Beder2006Determining.pdf
   - **Gallup et al., CVPR 2008** 式 (2) 闭式:`ε_z = z²ε_d/(bf + zε_d) ≈ (z²/(bf))·ε_d`,即 **σ_Z ≈ Z²σ_d/(fB)**,并把误差拆成 correspondence error 与 geometric resolution 两因子。https://people.inf.ethz.ch/pomarc/pubs/GallupCVPR08.pdf
   - **Matthies & Shafer, IEEE J. Robotics & Automation 1987** —— 三角化不确定度是**有方向、偏斜的椭球**而非球,用 3D 高斯误差模型优于标量模型。https://www.ri.cmu.edu/pub_files/pub3/matthies_l_1987_1/matthies_l_1987_1.pdf

**⚠️ 一条必须纠正的既有说法**:**bas-relief ambiguity(Belhumeur/Kriegman/Yuille IJCV 1999)是 shape-from-shading 的光照歧义,不是小视差三角化歧义。** 我方 memory `project_pocketworld_sparse_scatter_floor_and_peak_quality.md` 把球壳散点归因为 bas-relief 歧义 —— 作为类比可以,**写进文档/对外表述请改引 Beder & Steffen 的 condition number 或 Gallup 的 z²/(bf)**。

#### 1.6.4 COLMAP 全部相关字面默认值(main / 4.1.1 / 我方 vendored 三处一致)

`src/colmap/sfm/incremental_mapper.h`:
```
init_min_tri_angle        = 16.0   // 初始像对最小三角化角(度)
ba_local_min_tri_angle    = 6
filter_max_reproj_error   = 4.0
filter_min_tri_angle      = 1.5
abs_pose_max_error        = 12.0
```
`src/colmap/sfm/incremental_triangulator.h`:
```
min_angle = 1.5 ; create_max_angle_error = 2.0 ; continue_max_angle_error = 2.0
merge_max_reproj_error = 4.0 ; complete_max_reproj_error = 4.0 ; re_max_angle_error = 5.0
ignore_two_view_tracks = true
```
**⚠️ 三角化角过滤的语义(读实现所得,很重要)**:`FilterPoints3DWithSmallTriangulationAngle` 遍历 track 内**所有像对**,**任意一对**超过阈值即 `keep_point = true` 并 break —— **用的是 pairwise 最大角,不是平均角、不是最小角**。

#### 1.6.5 ⭐ Metashape Gradual Selection(一手官方手册)

来源:Agisoft Metashape Professional 手册 *Editing → Filtering points based on specified criterion*。v1.6(USGS 引用版)https://www.agisoft.com/pdf/metashape-pro_1_6_en.pdf p.103–104;v2.2 https://www.agisoft.com/pdf/metashape-pro_2_2_en.pdf(四条定义与公式一字未改)。

| 判据 | 官方公式 | 含义 | datum-free / gauge-free |
|---|---|---|---|
| **Reprojection error** | `max_i ‖x'_i − x_i‖ / s_i` | 按 key point scale 归一化的**最大**(非均值)重投影误差 | 是 / 是 |
| **⭐ Reconstruction uncertainty** | **`sqrt(k1 / k3)`** | tie-point 协方差矩阵**最大/最小特征值之比**开方,即误差椭球最长/最短半轴比。官方注明**只含三角化本身的不确定度,不含内外方位元素的传播** | 是 / **是** |
| **Projection accuracy** | `Σ_i s_i / n` | 平均 image scale | 是 / 是 |
| **Image count** | 整数计数 | 观测该点的影像数 | 是 / 是 |

官方对 Reconstruction uncertainty 的因果说明:高值**典型来自小基线的邻近照片**,这类点明显偏离物体表面、给点云引入噪声 —— 这正是 §1.6.3 第 2 条的厂商版表述。
Pasumansky 在论坛(topic 2478)说法与手册一致:最大/最小相除,且**无量纲**。https://www.agisoft.com/forum/index.php?topic=2478.0

**⭐ 关键对齐关系**:**Metashape Reconstruction Uncertainty 与 COLMAP `GetPointCov` 是同一类简化** —— 两者都只算三角化本身、不传播位姿不确定度。因此 `sqrt(λmax/λmin)` 可以在 COLMAP 上**逐字复刻其语义**。

#### 1.6.6 ⭐ USGS 的字面推荐数值(一手 PDF 全文核实)

Over, Ritchie, Kranenburg, Brown, Buscombe, Noble, Sherwood, Warrick, Wernette, 2021, *Processing coastal imagery with Agisoft Metashape Professional Edition, version 1.6*, USGS Open-File Report 2021-1039。https://pubs.usgs.gov/of/2021/1039/ofr20211039.pdf · doi 10.3133/ofr20211039

**顺序严格为三步,每步之后都要 Optimize Cameras**(默认系数 [f, k1, k2, k3, cx, cy, p1, p2] + 勾选 "Estimate tie point covariance"):

| 步骤 | 目标值 | 规则 |
|---|---|---|
| **1. Reconstruction Uncertainty** | **10** | 若选中 >50% tie points,以 **0.1** 为步长上调直到 <50% |
| **2. Projection Accuracy** | **3** | 同上,0.1 步长 |
| **3. Reprojection Error** | **0.3**(或约选中 10% 点) | 重复直到 level 0.3 选不出点 |

**⭐ RU 与物理视差角的换算(报告原文 p.26)**:
- **RU = 10 ≈ base-to-height 1:2.3 ≈ 视差角约 23°**
- **RU = 15 ≈ base-to-height 1:5.5 ≈ 视差角约 10°(marginally acceptable)**

**这是找到的唯一一处把无量纲 RU 换算成物理视差角的权威文献,对门限设计极有用。**

**验收门**:unweighted RMS reprojection error 落在 **0.13–0.18 px**;**≤0.18 即可停止**;一般 <0.3 px 视为充分优化。结束时**原始 tie points 应仍剩 15–20% 以上**;某影像 projections **<100** 需警惕。若 SEUW 偏离 1,把 tie point accuracy 从 1 调到 **[0.3–0.1]**。

**换算推论(算术,非引文)**:Metashape RU = 1/R(Beder roundness 的倒数)。Beder 的 T = sqrt(1/10) ⇔ **RU ≈ 3.16**,即学术门槛比 USGS 的 RU=10 严约 3 倍(condition number 10 vs 100)。
**⚠️ 我方现在的 `filter_min_tri_angle = 1.5°` 对应的 RU 远大于 15,属于极宽松档。**

### 1.7 自由空间 / 可见性离群检测(see-through test)

#### 1.7.1 逐方法对照总表

| 方法 | datum-free | 双侧? | 需稠密深度图? | 100–300 相机 / 5–30 万点的成本 |
|---|---|---|---|---|
| **Wolff 2016 (3DV)** | 是 | 检测双侧,**判据刻意单侧** | **强制需要** | 200 深度图 ≈ **20 min**(12 核 3.2 GHz),O(KN²) |
| **Merrell 2007 (ICCV)** | 是 | **是(核心设计)** | **强制需要** | GPU 23–25 fps,但纯 depth-map fusion |
| **Labatut 2007/2009** | 是 | 前方严格、后方靠 σ 松弛 | 不需要 | 桌面分钟级;CGAL + BK maxflow;内存是风险 |
| **Vu 2012 (TPAMI)** | 是(初始曲面阶段) | 同 Labatut | 不需要 | 同上 + 变分精化 |
| **Jancosek 2011/2014** | 是 | **方向相反 —— 是加面不是删点** | 不需要 | Labatut 基线 +50~100% |
| **⭐ OpenMVS `PointCloudFilter`** | 是 | **明确单侧** | **不需要** | 桌面秒级~十几秒 |
| **⭐ COLMAP `SparseDelaunayMeshing`** | 是 | 前方严格、后方靠 σ | **不需要** | 同 Labatut(CGAL 依赖) |

#### 1.7.2 Wolff et al. 2016(3DV)— 最相关,但对我们构造性不可用

PDF: https://la.disneyresearch.com/wp-content/uploads/Point-Cloud-Noise-and-Outlier-Removal-for-Image-Based-3D-Reconstruction-Paper.pdf · 项目页 https://igl.ethz.ch/projects/noise-rem/

**精确测试**:深度图平凡三角化 → 反投影成 range surface;退化三角形(内角 <1°)剔除以允许深度不连续处开口。沿视线求 `d_i(p) = z_i(p) − z`(不做真正 point-to-mesh 距离,这是效率来源)。
符号:`d_i < 0` = p 在表面**后方**;`d_i > 0` 且很大 = p 本应被看到却悬浮在相机与表面之间 = **free-space 冲突**。

```
Eq.2  I^G_σ(d_i) = 1 if −σ < d_i, else 0                       // 后方超 σ 的观测整条丢弃
Eq.3  w_i(p) = n(p)ᵀ(p − v_i)/‖p − v_i‖                        // 掠射角降权;只保留 v_jᵀv_i > 0
Eq.4  d(p) = (1/w(p)) Σ_i I^G_σ(d_i)·w_i(p)·min{d_i, σ}
Eq.5  I^P_σ(d_i) = 1 if −σ < d_i < σ
Eq.6  v(p) = Σ_i I^P_σ(d_i)                                     // support 计数
Eq.7  p(p) = 交点插值颜色的标准差
Eq.8  保留 iff  −t_d < d(p) < 0   且   p(p) < t_p   且   v(p) > t_v
```

**全部论文默认值**(原文:所有结果用固定参数):

| 参数 | 值 |
|---|---|
| σ | **深度范围的 1%** |
| t_d | **0.1·σ** |
| t_v | **输入深度图数量的 7.5%**(200 图 ⇒ 至少 15 图必须在 ±σ 带内看到 p) |
| t_p | **0.2** |
| 退化三角形角阈 / 视线夹角上限 | 1° / 90° |

Eq.8 第一条**刻意单侧**(只留表面内侧),论文理由:**"most of the noise appears on the outside of the surface"**(Wolff 2016);Fig.3 做了消融证明单侧优于对称区间。
**运行时间**:20 张 1080p 深度图 ≈ 30 s;100 张 ≈ 5 min;**200 张 ≈ 20 min**(3.2 GHz 12 核 + OpenMP)。复杂度 O(MN) = O(KN²)。超过 200 张后质量不再提升。
**无公开代码。**

**⚠️ 红线:该方法已被专利保护 —— US10074160B2**,受让人 ETH Zürich + Disney Enterprises,2018-09-11 授权,**状态 Active,预计 2036-10-27 到期**。https://patents.google.com/patent/US10074160B2/en
**商业照抄 Eq.8 三条件判据有专利风险,需法务签决。**

**对我们的适用性:构造性不可用。** 强制需要稠密 per-pixel 深度图;论文 Limitations 里**明确点名**"从稀疏点云反投影出的稀疏深度图"这一场景会失败。

#### 1.7.3 Merrell et al. 2007(ICCV)— free-space violation 的原始定义

PDF: https://mordohai.github.io/public/Merrell_DepthMapFusion07.pdf
`R_i(X)` = 视角 i 光心到 X 的距离;`D_i(X)` = X 投影到视角 i 后该深度图在那像素记录的深度。
```
① Free-space violation:  R_i(A) < D_i(A)                          // 定义在"其他视角"的射线上
② Agreement:             |R_ref(B) − R_ref(B')| / R_ref(B) < ε
③ Occlusion:             D_i^ref(C') < D^ref(C)                    // 定义在"参考视角"的射线上
④ 反向关系不算冲突(论文明确)
```
**Stability**:`S(x) = 遮挡数 − free-space violation 数`;`S ≥ 0` 为 stable;最终融合深度取**满足 stability 非负的最近深度**。渲染次数 O(N²)(confidence-based 版 O(N))。
**数值参数(两数据集统一)**:`ε = 0.05`、`σ = 120`、`w = 8 px`、`w_s = 4 px`、`C_thres = 5`。(Eq.6 平面性阈值 t 的数值论文未给 → **NOT VERIFIED**。)
**这是"简化 see-through 检验"的原始出处** —— 但它是 depth-map fusion,无稀疏模式。

#### 1.7.4 Labatut / Vu / Jancosek 谱系

⚠️ **Labatut ICCV 2007 原文取不到**(DOI 10.1109/ICCV.2007.4408892,IEEE 付费墙,CERTIS 主页 DNS 已失效)→ **NOT VERIFIED**。改用同作者 **2009 CGF** 论文(§2.2 开头即转述 LPK07 构造):https://www.cs.jhu.edu/~misha/ReadingSeminar/Papers/Labatut09.pdf · HAL https://hal.science/hal-00712261/

**s-t 图构造**:节点 = Delaunay 四面体(**含无穷四面体**,故可重建 open surface);source = outside,sink = inside;割的有向边 = 输出表面三角形。每条视线三步投票:含相机的四面体得 α_vis 的 source link;视线穿过的朝向顶点的有向 facet 得 α_vis 边;顶点正后方四面体得 α_vis 的 sink link。

**σ 是 2009 才引入的松弛参数**(LPK07 里不存在):sink 端四面体沿视线**再后移 3σ**;facet 权重按距离衰减 **α_vis · (1 − e^(−d²/(2σ²)))**。论文原话:"note that σ = 0 is equivalent to the first (flawed) visibility weight construction"(Labatut 2009)。

**全部实验统一的数值**:**α_vis = 32**(刻意固定为常数,不用置信度加权)、**λ_qual = 5**、**σ = 中位 range-grid 对角线的 1/2**。σ 敏感性实测(UU sheep):σ=0.0625 → 131K 顶点;σ=2 → 11K 顶点。论文警告 σ 设太高会在模型内部凿出不该有的洞。

**Vu 2012 (TPAMI)**(https://enpc.hal.science/hal-00712178):论文明确把 min s-t cut 那一步**当作离群点过滤器**用 —— "robustly and efficiently filters a quasidense point cloud from outliers"(Vu 2012)。能量 Eq.5–7:`V_align(l_Ti, l_Tj) = α_vis·1[l_Ti=0 ∧ l_Tj=1]`。⚠️ **α_vis / λ_qual 的具体数值正文未给 → NOT VERIFIED**;**是否沿用 σ 松弛也 NOT VERIFIED**。论文明确否决 guided ballooning(会导致碎片化表面)。

**Jancosek & Pajdla**(CVPR 2011 closed;用同作者开放获取扩展版 ISRN 2014,CC-BY,https://pmc.ncbi.nlm.nih.gov/articles/4897344/,doi 10.1155/2014/798595):Free-space support `f(T) = Σ α(p)`,σ = **四面体所有边长中位数的 2.0 倍**。界面分类器 `K(c,p) = INT iff ε_rel < k_rel ∧ ε_abs > k_abs ∧ γ < k_outl`。**标定值:k_abs = 1000、k_rel = 0.1、k_outl = 400、k_f = 3、k_b = 4**(OpenMVS 源码逐一吻合)。

**⚠️ 关键判断:Jancosek 不解决我们的问题。** FSS/WSS 项是把 t-edge 权重乘以 ε_abs **强行拉向 inside 来加面**(保住白墙/玻璃这类弱支撑表面),**方向与"删浮点"相反**。它的离群点过滤能力仍完全继承自 Labatut 的 visibility 项。

#### 1.7.5 ⭐ COLMAP 的 Delaunay Meshing(我们自己就有一份 Labatut 谱系实现)

**COLMAP 自带完整的 Labatut 谱系 free-space 实现,而且有稀疏模式。**

`DelaunayMeshingOptions` 字面默认值(main / 4.1.1 / 我方 vendored 三处一致),https://raw.githubusercontent.com/colmap/colmap/main/src/colmap/mvs/delaunay_meshing.h:
```
max_proj_dist              = 20.0
max_depth_dist             = 0.05
visibility_sigma           = 3.0
distance_sigma_factor      = 1.0
quality_regularization     = 1.0
max_side_length_factor     = 25.0
max_side_length_percentile = 95.0
```
⚠️ 文件名是 **`delaunay_meshing.h`,不是 `meshing.h`**(`src/colmap/mvs/meshing.h` 返回 404)。

实现要点(`delaunay_meshing.cc`,逐行读过):
- **`SparseDelaunayMeshing()` 存在**,CLI 为 `colmap delaunay_mesher --input_type sparse`
- **稀疏路径只吃 reconstruction**:点坐标 + `track.Length()` + 相机位姿(L154–175)。**完全不需要深度图** ⭐
- `alpha = 1 − exp(−n_vis²/(2·visibility_sigma²))`,n_vis = track 长度(L664–665)
- 射线投票(L672–736):含相机的 cell `source_weight += alpha`;视线穿过的每个 facet `+= alpha · ComputeDistanceProb(...)`;点后方的 cell `sink_weight += alpha` —— **与 Labatut 2009 逐条对应**
- 距离衰减 `1 − exp(−d²/(2σ_dist²))`,**σ_dist = distance_sigma_factor × 边长的 25 百分位**(自适应,datum-free)⭐
- `quality_regularization` = Labatut 的 λ_qual(COLMAP 默认 1.0,Labatut 用 5)。源码注释直接引 Labatut, Pons, Keriven, CGF 2009, **Figure 9**

**⚠️ 一条硬阻碍**:整个 `delaunay_meshing.cc` 包在 `#if defined(COLMAP_CGAL_ENABLED)` 里;无 CGAL 时 CLI 直接 `EXIT_FAILURE`。
**CGAL `Delaunay_triangulation_3.h` 的 SPDX 头逐字为 `GPL-3.0-or-later OR LicenseRef-Commercial`**(https://raw.githubusercontent.com/CGAL/cgal/master/Triangulation_3/include/CGAL/Delaunay_triangulation_3.h);CGAL 官方许可页确认 Kernel/Support 库是 LGPL,**大部分几何算法与数据结构是 GPL**,闭源商用需向 GeometryFactory 购买(https://www.cgal.org/license.html)。
**我方 `aether_cpp` 树里没有 vendored CGAL**(全树 grep 只命中 Eigen 的 FindLAPACK.cmake 注释)⇒ **该路径当前在端上编译不出来,且启用会引入 GPL 传染。**

#### 1.7.6 ⭐ OpenMVS `PointCloudFilter` — 与需求最匹配的一条(但 AGPL + 单侧)

**唯一「稀疏点云原生 + 无需深度图 + 常数齐全 + 已有生产验证」的实现,约 130 行。**

CLI: https://raw.githubusercontent.com/cdcseacave/openMVS/master/apps/DensifyPointCloud/DensifyPointCloud.cpp
实现 `libs/MVS/SceneDensify.cpp` L2480–2613,**字面常数**:
```cpp
const Real thMaxDepth(1.02f);    // 锥高 = distance * 1.02
const Real thSimilar(0.01f);     // 深度相似 = 相对差 < 1%
Octree octree(points, [](IDX size, Type){ return size > 128; });
const float angle(image.ComputeFOV(0)/image.width);   // 锥半角 = 单像素角尺寸
```
核心投票(L2527–2536):
```cpp
if (coneIntersect.Classify(points[idx], dist) == VISIBLE && !IsDepthSimilar(distance, dist, 0.01f)) {
    if (dist > distance)  visibility[idx] += pointViews[idx].size();   // 在 X 之后 → 良性遮挡,加分
    else                  visibility[idx] -= weight;                   // 在 X 之前 → free-space 冲突,扣分
}
...
if (visibility[idxPoint] <= thRemove) pointcloud.RemovePoint(idxPoint);
```
辅助(`libs/Common/Util.inl` L886–906):`MaxDepthDifference(d,th) = d*th`;`DepthSimilarity(d0,d1) = |d0−d1|/d0`;`IsDepthSimilar(..., th=0.01)`。
verbosity>2 时会把被删的点导出成 `scene_dense_outliers.ply` —— **调试自己的过滤器时可直接照搬这个做法**。

**两条硬约束**:
1. **AGPL-3.0**(LICENSE 首两行逐字为 GNU AFFERO GENERAL PUBLIC LICENSE Version 3,661 行完整文本含第 13 条)。https://raw.githubusercontent.com/cdcseacave/openMVS/master/LICENSE
   **静态链接即传染 ⇒ 一行代码都不能抄,算法思想可自由重实现(clean-room 更稳妥)。** 是否可商谈商业双许可 → **NOT VERIFIED**。
2. **明确单侧**:只有「Q 在 X 之前」才扣分,「Q 在 X 之后」**加分**。⇒ **只抓相机与表面之间的浮点,抓不到表面背后的浮点。**

**⭐ 但对我们的双层壳病理这仍然有效**:双层壳中,**从某些相机看,近的那片壳就落在远的那片壳与相机之间**。因此单侧 free-space 检验**能抓到双层壳里靠近相机的那一片**。这一点必须在实测中验证,不能假设。

#### 1.7.7 有没有已发表的"简化 see-through 检验"?

**作为独立论文:没找到。** 用 `"free-space violation"`、`visibility consistency check`、`see-through test`、`sparse point cloud outlier removal visibility` 多组检索,**没有**一篇把该检验作为独立稀疏点云滤波器发表并给出推荐阈值的同行评议论文。它总是作为更大管线的组件出现。
最接近的是 Shan et al., *Occluding contours for multi-view stereo*, CVPR 2014(先把稀疏云稠密化成深度图,再删显著 visibility conflict 的点)—— ⚠️ **原文未取得,阈值 NOT VERIFIED**。另有 CVIU 一篇 *Surface reconstruction from a sparse point cloud by enforcing visibility consistency and topology constraints* 标题高度吻合但付费墙 → **NOT VERIFIED**。

**作为可照抄语义的实现:有,且只有两个** —— OpenMVS `PointCloudFilter`(约 130 行,AGPL,单侧)与 COLMAP `SparseDelaunayMeshing`(Labatut 谱系,CGAL/GPL)。

**σ 取值范式可直接借鉴,且与"不许有用户旋钮"铁律兼容(全部自适应、datum-free)**:
Labatut `σ = 中位边长/2`;Jancosek `σ = 2 × 四面体中位边长`;COLMAP `σ_dist = 边长 25 百分位`;Wolff `σ = 深度范围 1%`、`t_v = 视图数 7.5%`。

---

## ② 推荐判决套件

**判决问题**:给定两朵点云 A(基线)与 B(候选),判定 **B 是否引入了比 A 更多的噪声**。

**判据范式(全套统一)**:采纳 Rabbani 2006 的**分位数门**而非绝对阈值 —— "calculate this threshold automatically using a specified percentile of the sorted residuals"(Rabbani 2006)。绝对阈值只在**有已发表数值**的 M5 上使用。其余全部判据是 **"必须落在 A-vs-A2 噪声带内"**。
**噪声带的定义**:A2 = A 的同配置重跑。我方 cap7_day 的 A vs A2 是**逐字节相同的 PLY(噪声带 = 0)**;cap3 同步管线则逐跑不复现(见 memory `ba77s_battlefield_verdict`)。**故噪声带必须逐 fixture 实测,不得假定为 0。**

### M1 — 局部壳厚 / 粗糙度分布(替代 sub-floor 的核心) ⭐⭐⭐

**定义**:对每个点 p,取半径 r 内的邻居(**排除 p 自身** —— CloudCompare 语义,§1.4.1),最小二乘拟合平面,记 `rough(p) = |dist(p, plane)|`;同时保留**有符号残差** `s(p) = dist(p, plane)`(用重力 UP 定符号,仅为可视化,判据不依赖符号)。

**报告量**(全部 datum-free):
- `rough` 的 **p50 / p90 / p95**(Middlebury 的"报第 X 百分位距离"读法,§1.5.5)
- **MPV** = 每点邻域内距离的**上四分位数**再对全云取均值(Razlaw ECMR 2015 口径,§1.4.6)
- `NMAD = 1.4826 × MAD`(Nocerino 2020 口径,§1.4.5)
- **NaN 率**(邻居 < 8 的点占比)

**⭐ 双层壳专用读法:roughness-vs-r 曲线**
在 r ∈ {1, 2, 4, 8} × d_nn(d_nn = 全云中位最近邻间距)上各算一遍。
- **单片干净表面**:rough(r) 随 r 缓慢上升(曲率项),曲线平坦。
- **双层壳**:当 r 跨过层间距时,拟合平面落到两片之间,**rough 出现台阶式跳变,台阶高度 ≈ 层间距/2**。
⚠️ **这是我方自行构造的读法,文献中不存在** —— §1.4.7 已确认没有任何论文定义并测量双层壳层间距。**必须标注为我方定义,并按 DVW Guideline 18-2022 的要求声明距离算子(point-to-plane)与无截断阈值。**

**判据**:
1. `rough_p90(B) ≤ rough_p90(A) + band(A,A2)`(band = |A2−A| 的同量)
2. `MPV(B) ≤ MPV(A) + band`
3. **roughness-vs-r 曲线上 B 不得出现 A 所没有的台阶**;若 A 已有台阶,B 的台阶高度不得增加超过 band

**为什么不循环**:**每个点各自拟合自己邻域的局部平面**,不存在一个"拟合到被测病理上的全局基准面"。双层壳中平面落在两片之间是**正确行为** —— 它把层间距**测量**出来,而不是把一片判成"面下"。

**为什么双边**:`rough` 是绝对距离,**上方与下方的偏离等权计入**;有符号残差 `s(p)` 另存,可分别统计正/负尾。

**为什么全场景**:每个点都得到一个值,不依赖任何"地板"假设;墙面、家具、天花板一视同仁。

**参数选取(自适应,无用户旋钮)**:`d_nn` = 全云最近邻距离中位数;`r ∈ {1,2,4,8}×d_nn`;最少邻居 8(取 CloudCompare 的 <6→NaN 与 Demantké/Farella 的 10 点之间的保守值),报告 NaN 率。
**失效模式**:密度非均匀时固定 r 的邻居数波动(Hackel 2016 §1.3.9)—— 必须同时报告每个 r 下的邻居数分布;稀疏 SfM 云可能在大 r 下才够点(Farella 2019 的低密度 caveat)。

### M2 — 双向最近邻 P/R/F(τ) + 百分位距离(T&T 算子 + ETH3D 体素归一化 + Middlebury 读法) ⭐⭐

**定义**(T&T 式 3–7,§1.5.2,把 A 当 pseudo-GT):
```
e_{b→A} = min_{a∈A} ‖b − a‖ ;  e_{a→B} = min_{b∈B} ‖a − b‖
P(τ) = (100/|B|) Σ_b [ e_{b→A} < τ ] ;  R(τ) = (100/|A|) Σ_a [ e_{a→B} < τ ]
F(τ) = 2PR/(P+R)
```
**必须加 ETH3D 的逐体素归一化**(§1.5.1):先逐体素(边长 0.01 m 或 τ)算 P/R,再对体素取均值 —— **否则谁点多谁占便宜**,这正是我方点数经常变化的场景下的作弊风险。
**必须同时报 Middlebury 读法**:`e_{b→A}` 的 **p50 / p90 / p95 / p99**(单位 m)—— **这才能量出"B 的点跑多远了",而 P(τ) 只能告诉你"有多少跑出 τ"**。

**τ 的选取**:**按 A 自身的最近邻间距分布定**(T&T §5 的做法:"computing statistics of nearest-neighbor distances" — Knapitsch 2017)。**绝不能抄 T&T 的 mm 数**(他们的场景尺度与采样密度都不同)。建议 τ = A 的中位最近邻间距。

**判据**:
1. `F(τ)(A,B) ≥ F(τ)(A,A2)`(即 B 与 A 的一致性不低于噪声带)
2. **P 与 R 必须分开看**:P 掉而 R 不掉 = **B 多了 A 没有的点**(新增噪声或新增合法覆盖 —— 需配 M4 区分);R 掉而 P 不掉 = B 丢了点
3. `e_{b→A}` 的 p99 不得超出 A-vs-A2 的同量 + band

**⚠️ 必须写进结论的诚实 caveat(§1.5.5)**:这测的是 **agreement 不是 correctness**。**若 A 和 B 都长了同一层鬼壳,F 会给满分。** 因此 M2 **不能单独用**,必须与 M1(绝对壳厚)和 M4(绝对自由空间冲突)配套。

### M3 — M3C2 有符号距离 + LoD95%(A-vs-B 的正牌工具) ⭐⭐⭐

**定义**(Lague et al. 2013,§1.5.7):对 A 的 core points,以法向尺度 D 估法向,以投影尺度 d 建圆柱,取两云在圆柱内的均值 i1、i2,得 **`L_M3C2 = n·(i2 − i1)`(有符号)**;
```
LOD95%(d) = ±1.96 · ( sqrt( σ1(d)²/n1 + σ2(d)²/n2 ) + reg )      // reg 在根号之外
```
**`reg = 0`**(我方 A/B 同 gauge 直出、有 SCALE-ANCHOR、不做重配准 —— 与既有铁律「同 gauge 直出禁 Sim3」一致)。

**报告量**:
- **显著变化点比例** = `|L_M3C2| > LoD95` 的 core point 占比
- **拆成正/负两侧**:`L_M3C2 > +LoD95`(B 向法向外侧移动 = 表面**上方**新增)与 `L_M3C2 < −LoD95`(B 向内侧移动 = 表面**下方**新增)
- `L_M3C2` 的 p5 / p50 / p95
- **无值率**(圆柱在 B 中找不到交集,或 n < 4)

**参数(按论文规则自适应)**:
- **D ≥ 20–25 × σ(D)**(Lague §3.2)—— σ(D) 直接取自 **M1 的 roughness**,两个指标天然咬合 ⭐
- **d 取到每云圆柱内 ≥20 点**(Lague §5.2.1);n1、n2 > 30 时 1.96 严格成立,**> 4 时论文实证仍够用**
- **core point 间距 ≈ d/5**(Lague:投影尺度 50 cm 时 core spacing 不必小于 10 cm)
- 自动 D:在尺度区间上做 PCA 取第三主成分最小者,**强制至少 10 点**

**⭐ 为什么这条指标独自就修好了三个缺陷**:
- **不循环**:参考是**另一朵云 B**,不是拟合到被测云上的面。法向是**逐 core point 局部**估的,不是一个全局地板。
- **双边**:`n·(i2−i1)` 有符号,**上方与下方各自成列**。
- **全场景**:法向是局部的 —— 墙面的法向是水平的、天花板的法向朝下,**全都被覆盖**,没有任何"地板"假设。

**⚠️ 稀疏 SfM 的风险(必须实测,不得假设)**:M3C2 是为 TLS(点密度 1 pt/cm² 量级)设计的。我方 cap7_day 是 **141,758 点 / 93 帧** 的稀疏 tie-point 云 —— **圆柱内能否稳定凑到 ≥4 点(更别说 ≥20)是未知数**。**首次跑必须报告无值率;若无值率 >30%,M3C2 在稀疏侧不可用,应降级为只在稠密段使用。**
其余失效模式见 §1.5.7(需局部平面;D ≤ 粗糙度尺度时高估距离;大 d + 自仿射表面时 LoD 过小)。

### M4 — 自由空间 / see-through 冲突计数(唯一的绝对鬼点检验) ⭐⭐

**定义**(clean-room 重实现 OpenMVS `PointCloudFilter` **语义**,§1.7.6 —— **不抄代码,AGPL**):
对每个点 X 与每个观测到 X 的相机 c:沿 c→X 建一个锥(**锥半角 = 单像素角尺寸 `FOV(0)/width`**,锥高 = `dist·1.02`),对落在锥内的其他点 Q:
- 若 `depth(Q) > depth(X)` 且深度不相似(相对差 ≥ 1%)→ Q 在 X 之后 = 良性遮挡,`visibility[Q] += |views(Q)|`
- 若 `depth(Q) < depth(X)` → **Q 在相机与 X 之间 = free-space 冲突**,`visibility[Q] -= weight`
最终 `violation(X) = (visibility[X] <= thRemove)`。

**报告量**:`violation_share(A)` 与 `violation_share(B)`,以及 `visibility` 分数的 p1 / p5 / p50。

**判据**:`violation_share(B) ≤ violation_share(A) + band(A,A2)`

**为什么这条不可替代**:M1/M2/M3 都是**相对表面**的度量 —— 它们回答"这个点离它应该在的面多远"。M4 回答一个**绝对的物理问题**:"这个点占据了相机明确看穿过去的空间吗"。**它对'A 和 B 共享同一层鬼壳'这个 M2 的盲区是有效的**,因为它的参考是**相机几何**,不是另一朵云。

**⚠️ 已知单侧性(必须写进报告)**:OpenMVS 语义只对"X 之前的点"扣分,**表面背后的浮点抓不到**。
- **第一版按已发表形式出货单侧**(这是唯一经生产验证的形式),并**在报告里显式标注"背后浮点未覆盖"**。
- 若需双侧,可借鉴 **Merrell 的 stability 语义(遮挡数 − FSV 数 ≥ 0)**;但 Merrell 的 stability 依赖稠密深度图才有判别力,**稀疏云上"后方"证据极弱 —— 必须先做受控实验量化,别直接假设可移植**。
- **对双层壳病理**:近的那片壳从某些相机看就在远的那片壳之前 ⇒ **单侧检验应能抓到近侧壳**。**这一点必须实测验证,不能假设。**

**成本**:300 相机 / 30 万点 ≈ 300 万次锥查询,配 octree/voxel grid 后桌面秒级(OpenMVS 的实测量级)。

### M5 — Reconstruction Uncertainty `sqrt(λmax/λmin)`(唯一有已发表绝对阈值的指标) ⭐⭐

**定义**:对我方 `ba_cov_tool` 已经算出的逐点 3×3 协方差做 `SelfAdjointEigenSolver`,取 **`RU = sqrt(λmax/λmin)`** —— **逐字复刻 Metashape Reconstruction Uncertainty 的语义**(§1.6.5:`sqrt(k1/k3)`,且两者都是 pose-conditional、都不传播位姿不确定度)。

**⭐ 已发表阈值(全套指标里唯一有的)**:

| 阈值 | 出处 | 物理含义 |
|---|---|---|
| **RU ≤ 10** | USGS OFR 2021-1039 步骤 1 | ≈ base-to-height 1:2.3 ≈ **视差角 23°** |
| **RU ≤ 15** | USGS(marginally acceptable) | ≈ 1:5.5 ≈ **视差角 10°** |
| **RU ≤ 3.16** | Beder & Steffen 2006,T = sqrt(1/10) | condition number ≈ 10(学术门槛,严 3 倍) |

**报告量**:`RU` 的 p50 / p90 / p95、以及 **`RU > 10` 与 `RU > 15` 的点占比**,逐 track-length 分桶(沿用现有 `<=2 / 3 / 4 / 5-6 / 7+`)。

**判据**:
1. `share(RU > 10)(B) ≤ share(RU > 10)(A) + band` —— **绝对阈值,有 USGS 背书**
2. `RU_p90(B) ≤ RU_p90(A) + band`

**⚠️ 为什么必须用 RU 而不是绝对 sigma_depth**:绝对 sigma(mm)**不是 gauge-free**(随尺度 s² 缩放),**业界不存在已发表的绝对阈值**(§1.6.0,已核实的负面结论)。RU 是无量纲比值,**gauge 免疫**,且有 USGS/Beder 两处已发表数值。
**⚠️ 已知偏差**:COLMAP 的 `GetPointCov` 是 **pose-conditional 条件协方差**(源码注释自承),**系统性低估**真实不确定度。这个偏差在 A 与 B 上同向,故**用于 A/B 比较是安全的**;**但不可对外声称是绝对不确定度**。

### 套件如何覆盖三个缺陷 —— 覆盖矩阵

| | **修 (a) 循环** | **修 (b) 单边** | **修 (c) 只看地板** |
|---|---|---|---|
| **M1 局部壳厚** | ✅ 逐点局部平面,不存在全局基准面;双层壳中平面落两片之间是**正确测量**而非误判 | ✅ 绝对距离,上下等权;有符号残差另存 | ✅ 每点都有值,无地板假设 |
| **M2 P/R/F + 百分位** | ✅ 参考是另一朵云 B,非拟合到被测云 | ✅ 最近邻距离方向无关 | ✅ 全云双向 |
| **M3 M3C2** | ✅ 参考是另一朵云;法向逐点局部估 | ✅ **有符号**,正负两侧分列统计 | ✅ **法向是局部的** —— 墙/天花板/家具全覆盖 |
| **M4 free-space** | ✅ 参考是**相机几何**,与点云内容无关 | ⚠️ **已知单侧**(只抓表面之前);双层壳的近侧壳应可抓到(待实测) | ✅ 全场景,无表面假设 |
| **M5 RU** | ✅ 参考是 BA 的 Jacobian,不是拟合面 | ✅ 各向异性比值,方向无关 | ✅ 逐点 |

**互补性论证**:
- **M1 是绝对的、单云的**(不需要 B) → 抓"A 和 B 共有的壳厚",补 M2 的盲区
- **M2/M3 是相对的、双云的** → 抓"B 相对 A 的变化",且 M3 带**符号 + 逐点显著性检验**
- **M4 是绝对的、几何的**(参考相机) → 抓"物理上不可能存在的点",补 M1/M2 的共模盲区
- **M5 是绝对的、代数的**(参考 Jacobian) → 抓"这个点的三角化条件数本来就烂",且是**唯一有已发表绝对阈值**的

**最小可用子集**:若只能实现 3 个,取 **M1 + M2 + M5**(实现成本最低,全部可复用已有基础设施)。**M3 和 M4 是把套件从"够用"提升到"完整"的两条** —— M3 提供双边符号 + 显著性,M4 提供唯一的绝对鬼点检验。

---

## ③ 现有指标的留用评价

### 3.1 sub-floor 计数 —— **退役,不得再作门**

| 维度 | 裁决 |
|---|---|
| **作 ship 门** | ❌ **立即停用。** cap3_eve 实测:同一份点云,per-arm 拟合给 35.94%(倾角 5.364°、内点 1,781/5,073),换 MODAL 带就掉到 16% —— **指标方差大于被测效应**。`floor_modal.py` docstring 已自承是 "a mis-latched fit, not 36% ghosts"。 |
| **作可视化** | ✅ **可留用,但必须冻结平面。** 用 `floor_fixed.py` 路径(A 臂拟合一次,所有臂共用),且该拟合必须**人工核验过倾角与内点率**(cap7_day 的 0.1226° / 7,024 内点是可接受的;cap3_eve 的 5.364° / 1,781 不可接受)。`recolor.py ghost` 模式的红/品红上色继续可用于肉眼并排。 |
| **作趋势量** | ⚠️ **仅限同一 fixture、同一冻结平面、且已知该平面锁对了的情况下。** 且必须与 M1/M3 并列报告,不得单独引用。 |
| **改进空间** | 该指标的三个缺陷 **(b) 单边** 与 **(c) 只看地板** 是**设计层面的**,任何 RANSAC 调参都修不了。不值得继续投入。 |

**具体动作**:`_host_fixtures/loop_cap37/tools/analyze_ab.py` 中的 `eval_floor()` 作为**硬回归门**的角色由 **M1 + M3** 接管;`fit_floor_plane()` 保留但降级为可视化辅助;`REPORT.md:6` 的「变差=自动 DO-NOT-SHIP」条款需重写为指向新套件。

### 3.2 sigma_depth —— **保留为诊断,升级为 RU 取得阈值**

现状:`_host_fixtures/tools/ba_cov_tool.cc`,`sigma_depth = sqrt(dᵀ Cov d)`,d = unit(point − 平均观测相机中心),COLMAP `EstimateBACovariance` + `Params::POINTS`,CAUCHY loss、`loss_function_scale=1.0`、gauge `TWO_CAMS_FROM_WORLD`,单位 mm,分桶 `<=2 / 3 / 4 / 5-6 / 7+`,报 p50/p90/p99。cap7_day 臂 A:2-view p50 5.89 mm、7+ 1.14 mm、**ratio 1.70×**、`no_cov=0`。

| 维度 | 裁决 |
|---|---|
| **绝对 mm 值作门** | ❌ **不可以。** **不是 gauge-free**(随尺度 s² 缩放),且**业界不存在已发表的绝对阈值**(§1.6.0,核实过的负面结论)。 |
| **同 gauge 内的 A/B 比较** | ✅ **可以。** 我方有 SCALE-ANCHOR(锚回平台 VIO 米制),A 与 B 同 gauge,mm 值可比。**继续报告。** |
| **track-length 分桶** | ✅ **保留,信息量真实。** 1.70× 的 2-view/3-view 比值是干净的实证,与 §1.6.2 的上游共识一致。 |
| **升级动作** | ⭐ **在同一份 3×3 协方差上加 `SelfAdjointEigenSolver`,输出 `RU = sqrt(λmax/λmin)`** —— 约 20 行,立刻解锁 USGS(RU=10 / 15)与 Beder(RU=3.16)两组**已发表绝对阈值**。这是本次调研在既有基础设施上杠杆最高的一刀。 |
| **已知偏差(必须写进报告)** | COLMAP `GetPointCov` 是 **pose-conditional 条件协方差**(源码注释自承 "conditioned on fixed pose/other parameters"),**系统性低估**真实不确定度。A/B 同向偏差,比较安全;**不可对外声称是绝对不确定度**。 |

### 3.3 track length —— **保留为协变量/分层器,不作独立判决**

现状:`extract_metrics.py` 的 `TRACKLEN` / `TRACKHIST` / `TRACKS` 三行;生产 C++ 的 `track3plus`;floor 脚本的候选筛选 `track ≥ 3`;BA 变量点排序 `pt.track.Length()` 降序。

| 维度 | 裁决 |
|---|---|
| **作噪声指标** | ❌ **不是噪声指标,是先验。** 短 track 只表示"更可能不可靠",不表示"这个点是噪声"。 |
| **作分层器** | ✅ **强烈保留。** 所有新指标(M1/M3/M5)都应**逐 track-length 分桶报告** —— 这能立刻回答"新增噪声是不是集中在 2-view 点上"。 |
| **上游背书** | 强:COLMAP `ignore_two_view_tracks = true` 默认开;Delaunay `alpha_vis` 在 n=2 时只有 **0.199**(≥4 的 1/5);Metashape "Image count" 判据;Pix4D "3D points generated from 2-3 images are less precise"。 |
| **⚠️ 不可引用的数字** | 「track≥3 误差低 X%」**未找到任何一手来源,NOT VERIFIED**,勿写进任何文档。 |

### 3.4 reprojection error —— **重度降级为 tripwire**

现状:`filter_max_reproj_error = 4.0`、`filter_min_tri_angle = 1.5`(finalize)/ 2.0 / 3.0(创建);live 创建门 `OFFICIAL_AETHER_CREATE_REPROJ_PX = 10.0`,其中 **27.7% 随后被官方过滤丢弃**;报告 `mean_reproj_px`、逐点 `err`、guard 表的 `reproj` / `Δreproj` 列。

| 维度 | 裁决 |
|---|---|
| **作鬼点检测器** | ❌ **构造性无效。** 它是**被最小化的目标函数值**(内符合精度),不是独立质检;且**小视差下点沿视线滑动几乎不改变重投影误差**(Beder & Steffen condition number / Gallup σ_Z ≈ Z²σ_d/(fB))。**鬼点可以有完美的重投影误差。** |
| **作 tripwire** | ✅ **保留。** mean_reproj 突然跳变 = 有东西坏了,是有效的回归警报。 |
| **作验收带** | ✅ **可用 USGS 的已发表数值**:unweighted RMS reprojection error **0.13–0.18 px** 为验收带,一般 **<0.3 px** 视为充分优化。注意这是 Metashape 口径,搬到我方需先做口径对齐实验。 |
| **⚠️ 一条纠错** | 我方 memory 把稀疏球壳散点归因为 **bas-relief ambiguity** —— **那是 shape-from-shading 的光照歧义,不是三角化歧义**。对外表述改引 Beder & Steffen 或 Gallup。 |

### 3.5 现有 A-vs-B 基础设施评价

- **`compare.html` / `viewer_tail.js.txt` 系(用户已批准的渲染器)**:✅ **完全保留**,与「每次进步必开网页与原版并排肉眼对比」铁律一致。新增的 M1 roughness / M3 signed distance 应作为**新的上色通道**接进 `recolor.py`。
- **`recolor.py ghost` 模式**:⚠️ 降级 —— 其红/品红判据 `d < -0.015` / `-0.050 ≤ d < -0.030` 依赖冻结平面。**改为对 M1 roughness 或 M3 `L_M3C2` 上色**(后者带符号,可红=上方/蓝=下方,直接把双边性画出来)。
- **⚠️ 结构性缺口:整个树里没有任何 chamfer / 最近邻距离工具。** 现有 A-vs-A2-vs-B 的"噪声带"只量化为**标量差**(点数、3+view track 数、reproj、sigma 桶、sub-floor 计数)。**M2 是从零新建。**

---

## ④ 实现清单

### 4.1 现有可复用资产(已核实)

| 资产 | 路径 | 说明 |
|---|---|---|
| **Eigen 3.4.0** | `~/Developer/Aether3D-cross/aether_cpp/third_party/eigen-install/include/eigen3` | ✅ header-only,已 vendored。⚠️ **必须用这份,不能用 homebrew**(`ba_cov_tool.cc:12-14` 记录的 ABI/sret 崩溃:`Image::ProjectionCenter` 的 sret 破坏) |
| **COLMAP 静态库** | `third_party/glomap_vendor/build-host/libpwofficial_core.a` | 含 `EstimateBACovariance`、`Reconstruction`、`Track` 等 |
| **VLFeat KD-tree** | `third_party/glomap_vendor/colmap-src/thirdparty/VLFeat/kdtree.{h,c}` | **树里唯一的 KD-tree**;C、float/double 泛型、L2 KD-forest(`vl_kdforest_new` / `vl_kdforest_query`),**已编进 `libpwofficial_core.a`**。为高维 SIFT 设计,dim=3 也能用 |
| **构建配方** | `_host_fixtures/spatial_cand_exp/tools/build_driver.sh`([1/3]–[3/3] 有确切 flags/defines) | `ba_cov_tool` 就是这样建的,单 `.cc` + `clang++ -std=c++17 -O2` |
| **既有工具模板** | `_host_fixtures/tools/ba_cov_tool.cc` | M5 直接在这里加 20 行 |

**缺席**:❌ 无 nanoflann、无 PCL、无 Open3D、无独立 FLANN。`pocketworld` 树里也没有。
**现有 Python NN 是暴力法**:`_host_fixtures/rs_export_forensics/xmp_deep.py:43` 建完整 O(n²) 矩阵 —— 几百个相机可以,**14 万点不行**。

### 4.2 逐指标实现方案

| 指标 | 方案 | 行数估计 | 依赖 | 许可证 |
|---|---|---|---|---|
| **空间索引(共用)** | **自己写均匀体素格哈希**(3D 场景下比 VLFeat 的高维森林更简单更快),或直接用 VLFeat kdtree | **~80 行** | 无新增 | ✅ 自有代码 |
| **M1 roughness / MPV** | 体素格邻居查询 + 3×3 协方差 + `Eigen::SelfAdjointEigenSolver` 取最小特征向量作法向 → 点到平面距离。**公式来自 Pauly 2002 / Razlaw 2015 论文数学,不抄 CCCoreLib 代码** | **~120 行** | Eigen(已有) | ✅ 论文公式不受版权保护 |
| **M2 P/R/F(τ) + 百分位** | 两次最近邻查询(B→A、A→B)+ 直方图 + ETH3D 式体素归一化 | **~100 行** | 同上 | ✅ T&T 公式在论文中,参考实现是 MIT |
| **M3 M3C2** | core point 抽稀 + 法向尺度 PCA + 圆柱查询 + 均值/标准差 + LoD95。**参考读 py4dgeo(MIT)的 `lib/distances.cpp`**,公式来自论文 | **~250–300 行** | 同上 | ✅ py4dgeo MIT;论文公式;⚠️ **不碰 qM3C2 插件(GPL v2+)** |
| **M4 free-space** | 逐点逐观测相机建锥 + 体素格/octree 查询 + 投票。**clean-room 重实现 OpenMVS 语义** | **~200–250 行** | 同上 + reconstruction 的 track 观测 | ⚠️ **绝对不抄 OpenMVS 代码(AGPL-3.0 静态链接即传染)**;⚠️ **不走 CGAL 路径(GPL-3.0+/商业)**;⚠️ **避开 Wolff Eq.8 三条件判据(US10074160B2 Active 至 2036)** |
| **M5 RU** | 在 `ba_cov_tool.cc` 已有的 3×3 协方差上加 `SelfAdjointEigenSolver`,输出 `sqrt(λmax/λmin)` | **~20 行** ⭐ | 已全部就位 | ✅ |

**总计约 770–870 行 C++,零新增第三方依赖,全部 header-only Eigen。**

### 4.3 跨端与商用合规检查

| 要求 | 状态 |
|---|---|
| **跨端(iOS/Android/鸿蒙/Web)** | ✅ 纯 C++17 + Eigen,无平台依赖,无 GPU 依赖。可直接进 `aether_cpp` |
| **商用干净** | ✅ 全部自有代码 + Eigen(MPL2,header-only 使用不传染)。**不引入 PCL/Open3D 也可以** —— 它们只作为**语义参照**(PCL BSD-3 / Open3D MIT 本身可用,但为零依赖计不引入) |
| **不搬 Dart** | ✅ 全部 C++,Dart 只作 FFI facade |
| **无用户旋钮** | ✅ 全部参数自适应导出(d_nn、r=k×d_nn、D≥20σ、σ_dist=边长分位数),无一个暴露给用户 |

### 4.4 主机侧原型路径(可选,加速验证)

在端上实现之前,可先在 host 用**商用干净**的库快速验证套件的判别力:
- **M1 / M2**:Open3D(**MIT**)—— `compute_nearest_neighbor_distance` 已有;roughness 需自己写(Open3D 无 eigenfeature)
- **M3**:**py4dgeo(MIT)** —— 直接可用的 M3C2 参考实现,含正确的 LoD 公式
- **M5**:pycolmap 的 `estimate_ba_covariance` / `get_point_cov`(自 3.11.1 起可用)
- ⚠️ **不要用 CloudCompare 做数字生产** —— 应用是 GPL v2+;CCCoreLib 虽是 LGPL-2.0+ 但静态链进 iOS 有 relinking 义务。**只作肉眼对照参考。**
- ⚠️ **不要用 jakteristics** —— 仓库根目录无 LICENSE 文件,GitHub API `license = null`,法务上是不完整声明。

### 4.5 建议实施顺序

1. **M5(~20 行)** —— 一天内可交付,立刻解锁 USGS/Beder 已发表阈值。**杠杆最高。**
2. **体素格 + M1(~200 行)** —— 双层壳的直接量法,替代 sub-floor 的核心。同时产出 M3 需要的 σ(D)。
3. **M2(~100 行)** —— 复用同一个空间索引,几乎零边际成本。
4. **M3(~280 行)** —— 需要 M1 的 σ 来定 D。**首跑必须报无值率**,若 >30% 则稀疏侧降级。
5. **M4(~230 行)** —— 最大的一块,但也是唯一的绝对鬼点检验。**首跑必须验证"单侧检验能否抓到双层壳的近侧壳"这个假设。**

每完成一段跑一次 A-vs-A2 建立噪声带,再跑 A-vs-B,肉眼并排核验,再进下一段。

---

## ⑤ 未找到清单(NOT VERIFIED / 确认不存在)

### 5.1 确认不存在的(核实过的负面结论,不要再找)

1. **半径 vs 平均点距的选取规则**(如 "r = 2–3× 平均 NN 间距")—— PCL / Open3D / CloudCompare 的官方文档与可核实一次文献中**均不存在**。
2. **eigenfeature 的噪声判别阈值** —— 遥感社区系统性绕过阈值(Demantké 用 argmax、Hackel 全文 `threshold` 命中 0、Weinmann 2017 只出现 1 次且指特征数量)。**唯一有代码级背书的数只有 PCL RegionGrowing `curvature_threshold_ = 0.05f`**,且它是分割生长的收敛参数,**没有任何论文验证过它对"噪声 vs 干净面"的判别力**。
3. **"哪个 eigenfeature 最能分离噪声与干净表面"的受控判别力比较(ROC/AUC)** —— 不存在。最接近的 FeatureGS 是损失函数消融,不是判别力评估。
4. **CloudCompare Roughness 的默认/推荐 kernel 半径** —— 两个 wiki 页都不给。
5. **SfM/MVS 的标准化"壳厚"指标** —— 不存在。最接近的已发表构造是 MPV(Razlaw ECMR 2015)。
6. **任何量化"双层壳层间距"的同行评议论文** —— 两条独立检索路线均空手。Qin & Qiu(arXiv:2602.00739)命名了 "double surface artifact" 但**不提供任何定量测量**。
7. **「可接受的 per-point 绝对 sigma」阈值** —— 业界不存在。这是构造性的:绝对 sigma 依赖 gauge/尺度,跨项目不可比。
8. **独立发表的"简化 see-through 稀疏点云滤波器 + 推荐阈值"** —— 不存在;该检验总是作为更大管线的组件出现。
9. **四个 benchmark 中任何一个的独立 noise/outlier 指标** —— ETH3D / T&T / DTU / Middlebury **全部没有**,离群点一律吸进 accuracy/precision 的分母。
10. **NR-PCQA 中可用于我们的方法** —— 几乎全部依赖颜色;跨库 SRCC 掉到 0.12–0.40;**从未在 SfM artifact 上验证过**。
11. **"SfM 点偏向纹理/角点导致局部 PCA 采样的是检测器响应场而非曲面"这一机制** —— **文献中完全找不到**。Farella 2019 说的是**密度**(球内点太少),不是**采样偏置**。若我们要走这条线,这是我方的原创贡献而非引用。
12. **eigenentropy 的 ε 守卫** —— 论文里基本无处可引(仅 [W2014] 脚注 2 提到加无穷小 ε)。必须自己定约定并写文档。

### 5.2 付费墙 / 无法取得(NOT VERIFIED)

13. **Weinmann et al. 2015, ISPRS J. 105:286–304 期刊版原文** —— 付费墙。特征表与 k 范围取自同团队开放获取前作 [W2013]/[W2014]/[W2015w4]。2015 版印的是 e 还是 λ:NOT VERIFIED。**2015 版自己的特征排名:NOT VERIFIED。**
14. **West et al. 2004 SPIE 原文** —— 付费墙。官方摘要中无 eigenvalue/linearity/planarity/covariance 任何一词。**"命名来自 West 2004" 无法证实且可疑。**
15. **Labatut, Pons, Keriven ICCV 2007 原文** —— IEEE 付费墙,CERTIS 主页 DNS 已失效。α_vis / λ 的原始值全部转述自同作者 2009 CGF §2.2。
16. **Vu et al. 2012 TPAMI 的 α_vis 与 λ_qual 具体数值** —— 正文未给。**是否沿用 σ 松弛也 NOT VERIFIED。**
17. **Merrell 2007 Eq.6 平面性阈值 t 的数值** —— 论文未给。
18. **Shan et al., Occluding contours for MVS, CVPR 2014** 原文及其阈值 —— 未取得。
19. **CVIU, Surface reconstruction from a sparse point cloud by enforcing visibility consistency and topology constraints** —— 付费墙。
20. **Demantké 2011 的半径 square-factor 递增的显式解析式** —— 论文未给,任何具体递推公式都是外推。
21. **Soudarissanane 2009 的逐入射角 σ 数值** —— 只在图里,无法提取。
22. **DTU 论文的 mean/median 区分细节** —— CVPR PDF >10 MB 无法完整提取,该点为部分核实。
23. **ETH3D accuracy/completeness 定义的论文正文原句** —— 取自 README/榜单页与论文 §4,已交叉核实;beam-cone 细节为部分核实。
24. **T&T intermediate / advanced 集的 τ** —— ⚠️ 更正:**已找到,在论文 Table 1**(见 §1.5.2)。closed evaluation server 的说法不成立。
25. **PDAL `approximatecoplanar` 的 thresh1=25 / thresh2=6 是否确出自 [Limberger2015]** —— 未取到原论文,目前只有 PDAL 文档一个来源。
26. **TVPC(Noise2Score3D)的精确公式** —— 二手转述。
27. **PointQ-Bench 的具体表格数值** —— 抓取一次未能复现定位。
28. **Rusu 博士论文(TUM 2009)正文** —— PDF xref 损坏。网传"K=50 / 阈值 2.0"未能核实,不予采信。
29. **Ceres 引用的 Kanatani & Morris 完整书目条目** —— ceres-solver.org 当时 443 拒连。
30. **OpenMVS 是否可商谈商业双许可** —— NOT VERIFIED。
31. **DFusion(Sensors 22(4):1631)的 TSDF 增厚数值** —— 403 无法抓取。
32. **fuseCut 与 Jancosek 的代码级继承关系** —— 本次未重新核实,以 memory `reference_fusecut_realitycapture_lineage.md` 为准。

### 5.3 已证伪的流传说法(重要,勿再引用)

33. **「PCL SOR 默认 k=50, α=1.0」** —— ❌ 错。真实默认是 `mean_k_{1}` / `std_mul_{0.0}`(PCLPointCloud2 版 `mean_k_{2}`),是**哨兵值**。50/1.0 是**教程示例**。
34. **「PCL SOR 是双边 μ ± σ·std_mul」** —— ❌ 错。头文件成员注释这么写,**但实现只有上界**。
35. **「Open3D 与 PCL 的 SOR 参数可直接互换」** —— ❌ 错。Open3D **把自身点算进 k**,`nb_neighbors=20` ≈ PCL `mean_k=19`。
36. **「DTU 的离群截断是 60mm」** —— ❌ 错。原论文与官方代码都是 **20 mm**。且降采样是 **0.2 mm** 不是 20 mm。
37. **「C2C 的伪变化上界是 1/4 点距」** —— ❌ 未找到来源。**已发布的数字是"一半"点距**(Lague 2013 Fig.4b)。
38. **「M3C2 的 LoD 是 `1.96·√(σ1²/n1+σ2²/n2+reg²)`」** —— ❌ 错。**`reg` 加在根号之外、括号之内**(论文 Eq.1 与 py4dgeo `lib/distances.cpp` 双重核实)。
39. **「ETH3D 有四档容差」** —— ❌ 错。**六档**:1/2/5/10/20/50 cm。
40. **「CloudCompare 是 GPL v2,roughness 只能看不能抄」** —— ⚠️ 半错。**应用与 qM3C2 插件是 GPL v2+,但 roughness/surface-variation 算法在 CCCoreLib = LGPL-2.0-or-later**。仍不建议静态链进 iOS(relinking 义务),但性质不同。
41. **「PCL RegionGrowing 教程的 curvature 阈值 1.0 是宽松设置」** —— ❌ 错。λ3/Σλ 的**数学上限是 1/3**,所以 1.0 = **把曲率判据彻底关掉**。绝不要抄。
42. **「稀疏球壳散点 = bas-relief ambiguity」** —— ❌ 术语误用。bas-relief 是 **shape-from-shading 的光照歧义**。改引 Beder & Steffen 的 condition number 或 Gallup 的 σ_Z ≈ Z²σ_d/(fB)。
43. **「CloudCompare Roughness 的平面拟合包含查询点」** —— ❌ 错。源码 `neighborCount - 1` 显式排除,注释 "we don't take the query point into account!",且 CHANGELOG v2.5.4 是明确的上游修正。
44. **「CloudCompare wiki 页名是 `Geometric_Features`」** —— ❌ 404。正确页名是 `Compute_geometric_features`。
45. **「PDAL 的 eigenfeature 与 CloudCompare 数值可比」** —— ❌ 错。**PDAL 默认 `mode="SQRT"`**,必须显式设 `mode: "Raw"` 才可比。

### 5.4 许可 / 专利红线(建议进记忆库)

| 项 | 状态 |
|---|---|
| **Wolff/Disney/ETH 的点云去噪方法** | **US10074160B2,Active,预计 2036-10-27 到期** ⇒ 照抄 Eq.8 判据有专利风险,需法务签决 |
| **OpenMVS** | **AGPL-3.0**(逐字核实,含第 13 条)⇒ 商用不可 vendor,**一行代码都不能抄** |
| **CGAL `Delaunay_triangulation_3`** | SPDX 逐字 **`GPL-3.0-or-later OR LicenseRef-Commercial`** ⇒ COLMAP `DelaunayMeshing` 路径闭源商用需买 GeometryFactory 商业许可 |
| **CloudCompare 应用 / qM3C2 插件 / CloudComPy** | GPL v2+ / GPL v2+ / GPL v3+ ⇒ 只可参考不可抄 |
| **CCCoreLib** | LGPL-2.0-or-later ⇒ 不是 GPL,但静态链进 iOS 有 relinking 义务 ⇒ **建议只参照公式重写** |
| **jakteristics** | **仓库根目录无 LICENSE 文件,GitHub API `license = null`** ⇒ 法务上不完整声明,不可用 |
| **DTU 官方 MATLAB 镜像 `cdcseacave/DTUeval`** | **无 LICENSE 文件** ⇒ 保留所有权利。用 `jzhangbs/DTUeval-python`(MIT) |
| **多个 NR-PCQA 仓** | MM-PCQA / ResSCNN / IT-PCQA / PQA-Net / GMS-3DQA / LMM-PCQA / LRL-GQA **均无 LICENSE 文件** ⇒ 不可商用 |
| ✅ **可安全使用** | PCL **BSD-3** · Open3D **MIT** · PDAL **BSD-3** · pyntcloud **MIT** · **py4dgeo MIT** · T&T 评测码 **MIT** + 数据 **CC BY 4.0** · ETH3D 评测码 **BSD** · DTUeval-python **MIT** · Eigen **MPL2** |

---

## 附录:一句话总账

现有 sub-floor 指标的三条缺陷(循环 / 单边 / 只看地板)**全部是设计层面的,调参修不了**,cap3_eve 的 35.94% vs 16% 已构造性证明其方差大于被测效应。替代套件为 **M1 局部壳厚(替代核心)+ M2 双向 P/R/F 与百分位距离 + M3 M3C2 有符号距离与 LoD95 + M4 free-space 冲突计数 + M5 Reconstruction Uncertainty**,总计约 800 行 C++、零新增依赖、全部跨端商用干净。其中 **M5 只需 20 行且立刻解锁本次调研中唯一一组已发表的绝对阈值(USGS RU=10/15、Beder RU=3.16)**,应最先落地。其余四项一律采用 **Rabbani 2006 的分位数门 + 落在 A-vs-A2 噪声带内** 的判据范式 —— 因为本次调研最重要的负面结论是:**除 RU 外,点云噪声领域几乎不存在可移植的已发表绝对阈值**。
