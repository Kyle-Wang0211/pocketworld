# 稀疏点云"看起来像实体表面"的成熟开源技术调研

**日期**: 2026-07-28
**约束**: 商用可用(GPL/AGPL/NC 判红)、跨端(禁 CUDA / 禁 Apple 专属)、端上 GPU 预算(A16 级、采集期不能掉帧)、**只改渲染不改数据**(交付点云保持全量未过滤)
**原则**: 不自创算法,只抄被证明有效的成熟方案。每条主张附出处;每个仓库的 LICENSE 都实际读过原文。

---

## TL;DR —— 推荐栈(4 条)

| 顺序 | 抄什么 | 抄谁 | 许可 | 视觉效果 |
|---|---|---|---|---|
| 1 | **透视衰减点尺寸 + min/max 钳制**(`size = k·r·projFactor`,`clamp(2.0, 50.0)`) | Potree `pointcloud.vs:666-705` | BSD-2 ✅ | 把"星空"变成"表面"。**这是 EDL 的前置条件,必须先做** |
| 2 | **圆形点**(`u²+v² > 1.0 → discard`) | Potree `pointcloud.fs:50-55` | BSD-2 ✅ | 消除大尺寸方点的"贴纸感" |
| 3 | **EDL**(8 邻居圆周,`shade = exp(-response·300·strength)`,**log2 深度存进颜色 RT 的 alpha 通道**) | **VTK `vtkEDLShadeFS.glsl`**(算法)+ Potree(alpha 通道技巧) | **BSD-3** ✅ | 🔥 决定性的那一步:散点"读起来像实体表面" |
| 4 | **最小屏幕半径下限**(~2px) | PlayCanvas `minPixelSize` / gsplat `eps2d` | MIT / Apache ✅ | 消除远处点云"沙沙作响"的逐帧闪烁 |

**三条最重要的判断**:
1. 🔴 **EDL 不是银弹,顺序被锁死**。CloudCompare 官方明说 EDL 需要 "contiguous depth map" —— 必须**先**用点尺寸把深度图填连通,EDL 才有输入。单上 EDL 收益接近零。
2. 🔴 **抄 VTK(BSD-3),别抄 Potree 的 `edl.fs`**。Potree 的 EDL 着色器在源码注释里自认是从 **CloudCompare(GPL-2+)** 改编的,而 Potree 以 BSD-2 再分发且无单独声明 —— 这是真实的上游传染性疑点。VTK 版由 Kitware 从 Boucheny 处取得并以 BSD-3 发布,血统干净,数学同源。
3. 🔴 **跨端必须用 instanced quad,不能用点图元**。WebGPU/WGSL 规范里 `point_size` 出现次数 = **0**,一个点恒等于一个像素。这是规范级的,不是实现限制。

---

## 0. 先修正任务书的前提(实测自代码库)

调研前先做了代码侦察,发现任务书的前提与实际代码不符,后面所有方案基于**实际代码**制定:

| 任务书说法 | 实际代码 | 出处 |
|---|---|---|
| AR overlay = 原生 Metal,固定 1.5px 方点 | **产品 App 的 AR overlay 是 SceneKit,不是 Metal**。`pocketworld` 整个仓库(除 `build/`)**没有任何 `.metal` 文件** | `/Users/kaidongwang/Developer/pocketworld/ios/Runner/OfficialAetherARKitPlugin.swift:3052-3105` |
| 点尺寸 ~1.5px | SceneKit 路径 `element.pointSize = 6`,`minimumPointScreenSpaceRadius = 2`,`maximumPointScreenSpaceRadius = 6` | 同上 `:3084-3086` |
| — | Metal 点精灵管线**存在但在另一个仓** `Aether3D-cross`,尺寸 `8.5f × pointSizeScale 2.0 × clamp(1.75/depth, 0.50, 3.0)` | `/Users/kaidongwang/Developer/Aether3D-cross/App/Shaders/PointCloudRender.metal:43-106`;尺寸常量 `aether_cpp/src/pipeline/local_subject_first_capture_overlay.cpp:249-252`;`PointCloudOIRPipeline.swift:522` |
| Flutter = CustomPainter 画方点 | Flutter 已经在用 `drawRawAtlas` + 16×16 抗锯齿**圆盘** sprite + `BlendMode.modulate` 逐点上色,且**已做全量 painter's algorithm 深度排序** | `/Users/kaidongwang/Developer/pocketworld/lib/ui/official_capture/sparse_cloud_view.dart:944-952, 252-267, 929-930` |

**关键结论(决定了后面所有方案的可行性)**:

1. **交付点云每点只有 xyz+rgb,15 字节,没有法线/置信度/尺度**。PLY header 逐字:`property float x/y/z` + `property uchar red/green/blue`,`end_header`。出处:`/Users/kaidongwang/Developer/pocketworld/lib/official_capture/sparse_ply.dart:32-41`。→ **任何需要 per-point 法线的技术(EWA splatting / surfel)直接出局**,除非在渲染期估算。
2. **产品 App 的 AR overlay(SceneKit)`readsFromDepthBuffer = false` 且 `writesToDepthBuffer = false`**(`:3091-3092`)。→ **没有深度缓冲 = EDL 在当前 SceneKit 路径上不可实现**。这是落地方案里最大的一个前提。
3. `Aether3D-cross` 的 Metal 路径**已经有离屏 render target 和 depth32Float**(OIT 的 `accumTexture` RGBA16Float / `revealTexture` R16Float,`usage=[.renderTarget,.shaderRead]`),已经有一个 composite pass。→ **在这条路径上加 EDL 后处理是顺理成章的**。出处:`PointCloudOIRPipeline.swift:402-424, 363-375, 379-397`。
4. Flutter 侧 **没有注册任何 `.frag` shader**(`pubspec.yaml` 无 `shaders:` 键),且 CustomPainter **根本没有深度缓冲**。
5. Flutter 侧 review 视图 **不做任何抽稀**:`drawStrideFor() => 1`,`drawCountFor() => pointCount`,即 ~170k 点每帧全量 CPU 投影 + `O(m log m)` 排序。出处:`lib/point_cloud_display/progressive_octree_order.dart:16-21`,`sparse_cloud_view.dart:818`。

---

## ⓪′ 许可证总表(每一条都是我读了 LICENSE 原文核实的)

| 仓库 | 许可证 | 核实的 URL | 商用 |
|---|---|---|---|
| **`potree/potree`** | **BSD-2-Clause**(FreeBSD 变体) | `raw.githubusercontent.com/potree/potree/develop/LICENSE` | ✅ |
| **`Kitware/VTK`** | **BSD-3-Clause**(着色器内还有 `SPDX-License-Identifier: BSD-3-Clause`) | `raw.githubusercontent.com/Kitware/VTK/master/Copyright.txt` | ✅ |
| `Kitware/ParaView` | BSD-3-Clause | GitHub API | ✅ |
| `potree/PotreeConverter` | BSD-2-Clause | GitHub API | ✅ |
| `pnext/three-loader` | MIT(+ 内含 Potree BSD-2) | `.../pnext/three-loader/master/LICENSE` | ✅ |
| `mrdoob/three.js` | MIT | `.../mrdoob/three.js/dev/LICENSE` | ✅ |
| `isl-org/Open3D` | MIT | `.../isl-org/Open3D/main/LICENSE` | ✅ |
| `nerfstudio-project/gsplat` | Apache-2.0 | `.../gsplat/main/LICENSE` | ✅ |
| `nerfstudio-project/nerfstudio` | Apache-2.0 | LICENSE | ✅ |
| `antimatter15/splat` | MIT | `.../antimatter15/splat/main/LICENSE` | ✅ |
| `mkkellogg/GaussianSplats3D` | MIT | LICENSE | ✅ |
| `playcanvas/engine` / `supersplat` / `supersplat-viewer` | MIT | `.../playcanvas/engine/main/LICENSE` | ✅ |
| `sparkjsdev/spark` | MIT(World Labs) | LICENSE | ✅ |
| `pub.dev/flutter_scene` | MIT | pub.dev | ✅ |
| `m-schuetz/compute_rasterizer` | MIT | `.../compute_rasterizer/master/LICENSE.md` | ✅(但 Windows+NVIDIA only) |
| `m-schuetz/SimLOD` | MIT | `.../SimLOD/master/LICENSE.md` | ✅(但 CUDA-only) |
| `m-schuetz/CudaLOD` | MIT | LICENSE.md | ✅(但 CUDA-only) |
| `m-schuetz/Skye` | BSD-2-Clause | LICENSE.txt | ✅ |
| `m-schuetz/Splatshop` | MIT | LICENSE.md | ✅ |
| `pygfx/pygfx` | BSD-2-Clause | LICENSE | ✅ |
| 🔴 **`CloudCompare/CloudCompare`** | **GPL-2.0-or-later**(`COPYRIGHT: EDF R&D / TELECOM ParisTech`) | `.../CloudCompare/master/license.txt`(注意是 `license.txt` 不是 `LICENSE`) | ❌ |
| 🔴 **`m-schuetz/Potree-Next`** | **AGPL-3.0** | `.../Potree-Next/master/LICENSE` | ❌ |
| 🔴 `m-schuetz/CuRast` | AGPL-3.0 | LICENSE.md | ❌ |
| 🔴 `m-schuetz/webgpu_pointcloud` | **无 LICENSE 文件** | 仓库根目录清单 | ❌ |
| 🔴 `graphdeco-inria/gaussian-splatting` | Inria/MPII 非商用研究许可 | `.../gaussian-splatting/main/LICENSE.md` | ❌ |
| 🔴 `graphdeco-inria/diff-gaussian-rasterization` | 同上 | LICENSE.md | ❌ |
| 🔴 `autonomousvision/mip-splatting` | 继承 Inria 研究许可 | LICENSE.md | ❌ |
| 🔴 `cnr-isti-vclab/meshlab` | GPL-3.0 | GitHub API | ❌ |

⚠️ **GitHub 的 License API 在三个仓上会骗你**:`potree/potree`(因文件头有 ASCII art)、`CloudCompare`(因文件名是 `license.txt` 且被改动过)、`m-schuetz/*` 多个仓,API 都返回 `NOASSERTION` / `Other`。**必须读文件正文,不能信 API 字段。**

---

## ① 技术清单

### 1. 点的大小(Point Size Modes)—— Potree 三档

**许可证**: Potree = **BSD-2-Clause(FreeBSD 变体)** ✅ 商用安全。
逐字读过 `https://raw.githubusercontent.com/potree/potree/develop/LICENSE`:头部 `Copyright (c) 2011-2020, Markus Schütz`,只有两条义务(源码分发保留版权声明/条件/免责;二进制分发在文档中复现三者),外加 FreeBSD 的 "views and conclusions" 样板。
⚠️ 澄清一个流传的说法:**没有**"免费商用但需署名"的额外条款。仓库**没有 NOTICE 文件**,README **没有 license 章节**。LICENSE 的最后一次实质变更是 2020-08-02 commit `a18d2460`("update license",1 增 12 删),只是把年份 `2011-2017`→`2011-2020` 并删掉了附加的 PLASIO/LASLAZ MIT 声明。GitHub API 把它标成 `NOASSERTION` 纯粹是因为文件头有 ASCII art,不是因为有非标准条款。`package.json` 自己声明 `"license": "BSD-2-CLAUSE"`。
**实际义务**:在 App 的"关于/开源许可"页里放版权行 + 许可证全文。

**枚举**(`src/defines.js:35-45`):`PointSizeType { FIXED:0, ATTENUATED:1, ADAPTIVE:2 }`,`PointShape { SQUARE:0, CIRCLE:1, PARABOLOID:2 }`。

**公式**(`src/materials/shaders/pointcloud.vs`,`getPointSize()` L666-705):

共同的投影因子(L670-676):
```
slope      = tan(fov / 2)                                  // fov 是弧度
projFactor = -0.5 * uScreenHeight / (slope * vViewPosition.z)
scale      = |MV·(0,0,0,1) − MV·(uOctreeSpacing,0,0,1)| / uOctreeSpacing
projFactor = projFactor * scale                            // 单位:像素 / 世界单位 @ 该点深度
r          = uOctreeSpacing * 1.7
```
`vViewPosition.z` 在相机前方为负,所以前面的 `-0.5` 让 projFactor 为正。

三档:
- **FIXED** (L680-681):`pointSize = size`。纯像素常数,不含任何深度项。
- **ATTENUATED** (L682-688):透视 `pointSize = size * spacing * projFactor`;正交 `pointSize = size`。
- **ADAPTIVE** (L689-696):
  ```
  worldSpaceSize = 1.0 * size * r / getPointSizeAttenuation()
  透视: pointSize = worldSpaceSize * projFactor
  正交: pointSize = (worldSpaceSize / uOrthoWidth) * uScreenWidth
  ```
  其中八叉树版 `getPointSizeAttenuation() = pow(2.0, getLOD())`(L301-303),即每深一层 LOD 点尺寸减半,与八叉树 spacing 的减半同步。

**钳制(三档都无条件生效)** L699-700:`pointSize = clamp(pointSize, minSize, maxSize)`。
默认值(`PointCloudMaterial.js:32-38`):`size = 1.0`,**`minSize = 2.0`**,**`maxSize = 50.0`**;构造函数默认档位是 `FIXED` + `SQUARE`。

**成本**: FIXED 和 ATTENUATED 都是几条 ALU,免费。**ADAPTIVE 很贵** —— `getLOD()`(L216-254)是一个**逐顶点的纹理游走循环,最多 31 次迭代,每次一个依赖性纹理采样**(采 `visibleNodes` 2048×1 RGBA 数据纹理,靠整数除法做位运算,因为是 WebGL1 时代的 GLSL)。

⚠️ **两个陷阱**(会让人抄错):
1. **ATTENUATED 依赖一个现代 Potree 数据根本不带的 per-vertex attribute**。`spacing`(vs L16)只有 1.x 的 `BinaryLoader.js:97-99` 在文件里存在 `"SPACING"` 属性时才填。Potree 2.0 的 `OctreeLoader.js` 从不设置它 —— 那里的 `spacing` 是 per-node 标量(`child.spacing = current.spacing / 2`),不是顶点缓冲。没绑缓冲时通用属性读到 0 → `pointSize = 0` → 被钳到 `minSize`(2.0)。**结果:在 2.0 格式数据上 ATTENUATED 退化成平的 2px 模式**。
2. **`material.spacing` 不是 shader 里的 `spacing`**。shader 里**没有** `uniform float spacing`;那个值是以 **`uOctreeSpacing`** 名字进去的(`PotreeRenderer.js:1299`)。另外 `getSpacing()`(L256-299)是**死代码**,全仓无调用者,别照着它设计。

**对我们的意义**: 我们没有八叉树 LOD,所以 ADAPTIVE 不适用也不需要。**我们要抄的是 ATTENUATED 的骨架 + min/max 钳制**,即 `size_px = k * worldRadius * projFactor`,再 `clamp(minSize, maxSize)`。这正是 `Aether3D-cross` 已经在做的事的更正确版本(它现在用的是拍脑袋的 `clamp(1.75/depth, 0.50, 3.0)`),也正是 SceneKit 的 `minimumPointScreenSpaceRadius`/`maximumPointScreenSpaceRadius` 提供的能力。

---

### 2. 点的形状(Point Shape)——圆形 discard / 抛物面

**出处**: `src/materials/shaders/pointcloud.fs`(100 行),许可证同上 BSD-2 ✅

**共享 UV**(L45-48):
```glsl
float u = 2.0 * gl_PointCoord.x - 1.0;
float v = 2.0 * gl_PointCoord.y - 1.0;
```

**圆形 discard**(L50-55)——就是全网都在用的那个技巧:
```glsl
float cc = u*u + v*v;
if (cc > 1.0) discard;
```
注意:用**平方半径**比较,没有 `length()`/`sqrt`;阈值是严格大于 `1.0`,边界像素保留。

**抛物面 + 深度修正**(L63-81)——这是让"点像小球/表面"而不是像贴纸的关键:
```glsl
float wi = 0.0 - (u*u + v*v);        // 中心 0,边缘 -1,朝下的抛物面
vec4 pos = vec4(vViewPosition, 1.0);
pos.z += wi * vRadius;                // 视空间 Z 最多后推一个半径
float linearDepth = -pos.z;
pos = projectionMatrix * pos;
pos = pos / pos.w;                    // → NDC
gl_FragDepthEXT = (pos.z + 1.0) / 2.0;
```
关键点:它把**位移后的视空间坐标重新过一遍真正的投影矩阵**,所以写出去的深度是正确的双曲深度,不是线性糊弄。`vRadius` 是 vs L702 回算的**钳制后**世界半径(`vRadius = pointSize / projFactor`),所以 min/max 钳制会连带改变抛物面的几何。
⚠️ 抛物面路径**没有 discard**:`u²+v² > 1` 的角落像素照样着色,只是被推到最多一个半径之后 —— 所以抛物面点是**完整方形足迹 + 弯曲深度剖面**。

**成本 / early-Z**(这段是端上性能的要害):
- **只有抛物面写深度**(`gl_FragDepthEXT`,L72)。方形和圆形都把深度交给固定功能插值器。
- `#extension GL_EXT_frag_depth` 的条件守卫(L2-4)就是为了让另外两种形状**保住 early-Z**。写任意 `gl_FragDepth` 强制 late-Z,硬件无法在着色前拒绝片元,每个重叠 splat 都要付全额着色成本。Potree **没有**用 `layout(depth_greater)` 这类保守深度提示(它面向 WebGL1 的 `EXT_frag_depth`,那里没有这个限定符)—— 而 `wi ≤ 0` 意味着深度只会增大,**保守深度提示在数学上是成立的,是可以加的优化**。
- 圆形路径的 `discard`(L52)**在多数 tiler 上同样会关掉 early-Z**。所以严格讲:**只有 SQUARE 完全 early-Z 友好;CIRCLE 丢 early-Z 但不付深度写带宽;PARABOLOID 两样都丢**。

**材质状态**(`PointCloudMaterial.js:208-227`):opacity=1.0 → `NoBlending` + 深度测试写入都开 + `LessEqualDepth`;opacity<1 且无 EDL → `AdditiveBlending` + **深度测试关** + `AlwaysDepth`;weighted → additive + 深度测试开 + 深度写关。

**加权 splat**(L89-96,Potree 的 HQ 模式):
```glsl
float distance = 2.0 * length(gl_PointCoord.xy - 0.5);
float weight   = pow(max(0.0, 1.0 - distance), 1.5);
gl_FragColor.a    = weight;
gl_FragColor.xyz *= weight;
```
之后由 `normalize.fs` / `normalize_and_edl.fs` 除以累积权重解析。

---

### 3. Eye-Dome Lighting(EDL)—— **本调研的头号推荐**

这是让稀疏点云"读起来像实体"引用最多的技术,Potree / CloudCompare / ParaView / VTK 全在用。

#### 3.1 出处与谱系(三份实现全部逐字读过原文)

**权威描述**(Kitware 官方文章,作者 Christian Boucheny 与 Alejandro Ribes,**2011-04-15**,https://www.kitware.com/eye-dome-lighting-a-non-photorealistic-shading-technique/,逐字引用):
> "Eye-Dome Lighting (EDL) is a non-photorealistic, image-based shading technique"
> 输入:"Solely projected depth information is required to compute the shading function"
> "dome" 这个名字的来历:"consider a half-sphere (the dome) centered at each pixel p" —— 明暗是**该 dome 在 p 处可见比例**的函数,反过来说就是**被 p 的邻居遮住的比例**。
> 多尺度:"the same shading function being applied at lower resolutions (typically half and quarter image size)"

⚠️ 注意"Solely ... depth information" 这一句:**EDL 不需要法线,只要深度** —— 这正是它适配我们这种无法线点云的根本原因。

算法作者 **Christian Boucheny**,源自其博士论文工作。⚠️ 任务书里写的 "CEA" 不对:**产业方是 EDF(Électricité de France)**。VTK 的着色器文件头逐字写着这项工作的归属:
```
Acknowledgement:
This algorithm is the result of joint work by Electricité de France,
CNRS, Collège de France and Université J. Fourier as part of the
Ph.D. thesis of Christian BOUCHENY.
```
(`https://raw.githubusercontent.com/Kitware/VTK/master/Rendering/OpenGL2/glsl/vtkEDLShadeFS.glsl`)

Potree 的材质文件(`src/materials/EyeDomeLightingMaterial.js:5-12`)给出三个溯源链接:CloudCompare 的 qEDL 插件、Kitware Source 的文章 `http://www.kitware.com/source/home/post/9`、以及论文 `https://tel.archives-ouvertes.fr/tel-00438464/document` 第 115 页起(法文)。

三份实现的时间线(全部读过文件头):
| 实现 | 文件头日期 | 许可证 | 商用 |
|---|---|---|---|
| CloudCompare `qEDL`(**原版**) | `C.B. - 04/23/2008`,后经 D.G-M. 2010/2014 修改 | **GPL-2.0-or-later** | ❌ **红** |
| VTK `vtkEDLShading`(简化版) | `C.B. - 3 feb. 2009` | **BSD-3-Clause** | ✅ **绿** |
| Potree `edl.fs`(重写版) | — | BSD-2(但见下方 ⚠️) | ⚠️ 见下 |

#### 3.2 ⚠️ 一个必须签决的许可证风险

**Potree 的 `edl.fs` 自己在源码注释里声明它是从 GPL 代码改编来的**。`src/materials/shaders/edl.fs` 第 4-6 行逐字:
```
// adapted from the EDL shader code from Christian Boucheny in cloud compare:
// https://github.com/cloudcompare/trunk/tree/master/plugins/qEDL/shaders/EDL
```
CloudCompare 的许可证我读了原文(`license.txt`,因为仓库根目录**没有** `LICENSE` 文件,GitHub API 返回 `NOASSERTION`):
> GNU General Public License ... version 2 or later,`COPYRIGHT: EDF R&D / TELECOM ParisTech (ENST-TSI)`

Potree 以 BSD-2 再分发它,且 Potree 的 LICENSE **没有**为此附任何单独声明。这是一个真实的上游许可证传染性疑点。

**规避方式(推荐,零成本)**:**照 VTK 的 BSD-3 版本实现,不要照抄 Potree 的 `edl.fs`**。VTK 的版本是 Kitware 从 Boucheny 处获得并以 BSD-3 发布的独立实现(文件头 SPDX 明写 `BSD-3-Clause`,并带上述致谢),血统干净。算法本身是公开发表的(论文 + Kitware 文章),算法不受版权保护 —— 受保护的是代码。所以:**抄 VTK 的代码,或按论文自己写;不要 copy-paste Potree 的 `edl.fs`,更不要碰 CloudCompare 的 `edl_shade.frag`**。

#### 3.3 算法(三份实现的数学,逐字读自源码)

**核心思想**: 屏幕空间。对每个像素,在半径 r 的圆周上取 N 个邻居的深度;统计"有多少邻居比我更靠近相机、近多少";响应越大越暗。效果是给每个深度不连续处画上一圈单边的阴影轮廓,大脑立刻把散点读成有遮挡关系的表面。

**A. Potree 版**(`edl.fs` L29-58,最简洁):
```
uvRadius = radius / vec2(screenWidth, screenHeight)     // 像素半径 → UV,逐轴
sum = 0
for i in [0, NEIGHBOUR_COUNT):
    d_n = texture2D(uEDLColor, vUv + uvRadius * neighbours[i]).a
    d_n = (d_n == 1.0) ? 0.0 : d_n                       // 背景哨兵
    if d_n != 0.0:
        sum += (depth == 0.0) ? 100.0 : max(0.0, depth - d_n)
response = sum / NEIGHBOUR_COUNT
shade    = exp(-response * 300.0 * edlStrength)
gl_FragColor = vec4(cEDL.rgb * shade, opacity)
```
三个必须说清的点:
1. **比较的深度是对数的**。alpha 通道存的是 `log2(linearDepth)`,由 `pointcloud.vs:866` 的 `vLogDepth = log2(-mvPosition.z)` 写入。所以 `depth - d_n` 是一个 **log 比值 `log2(d/d_n)`,尺度不变** —— 这正是为什么一个全局 `edlStrength` 在任何缩放级别都成立。**这是整个技术的关键点。**
2. **只算远的一侧**。`max(0.0, depth - d_n)` 只累加比中心更近的邻居。深度断崖远侧的片元得到大响应 → 变暗;近侧得 0 → 不变。这就是它产生**单边类环境光遮蔽轮廓**而不是对称描边的原因。
3. `1.0` 和 `0.0` 都是"背景/空"的哨兵。中心是背景但有真邻居时每个邻居加 `+100.0`(巨大响应),配合末尾的 `discard` 让背景像素直接丢弃而不是变成黑晕。

**神奇常数 `300.0` 是硬编码的**,乘在 `edlStrength` 上。所以有效指数尺度是 `300 * edlStrength` 作用在 log2 比值上。`normalize_and_edl.fs:50` 里是同一个常数。

**邻居布局**(`EyeDomeLightingMaterial.js:67-82`)——单位圆均匀采样,默认 **8** 个:
```
neighbours[2c+0] = cos(2πc / N)
neighbours[2c+1] = sin(2πc / N)
```
`NEIGHBOUR_COUNT` 是从 JS 注入的**预处理器宏**,不是 uniform;改数量会**重新编译着色器**。

**深度回写**(L62-70)——让后续几何(测量工具、网格)能正确与 EDL 合成后的点云做深度测试:
```
dl        = pow(2.0, depth)                  // 反解 log2 → 线性视深度
dp        = uProj * vec4(0.0, 0.0, -dl, 1.0)
gl_FragDepthEXT = (dp.z/dp.w + 1.0) / 2.0
```

**B. VTK 版**(`vtkEDLShadeFS.glsl`,**这是我们要抄的那份**):
自称 "Simplified version for use in VTK — oriented light, no focus"。它比 Potree 版多一个**光照方向 L**:
```glsl
// 光平面-点
vec4 P = vec4(L.xyz, -dot(L.xyz, vec3(0.,0.,t)));
for(c=0; c<8; c++){
    V      = tcoordVC.st + di*vec2(SX,SY)*N[c].xy;
    Zn[c].x = ztransform(texture2D(s2_depth, V).r);
    Znp[c]  = dot(vec4(di*vec2(SX,SY)*N[c].xy, Zn[c].x, 1.0), P);
}
// obscurance(zi,zj,delta) = max(0., zj-zi) / (delta/S)   ← "伪角度"
F = Σ obscurance(0., Znp[c], di*SX) * weight;
F = exp(-F_scale * F);
```
其中 `ztransform()` 是**反解 OpenGL 透视投影**得到线性深度并按 `SceneSize` 归一化:
```glsl
Z = (z-0.5)*2.;
Z = -2.*Zfar*Znear/((Zfar-Znear)*(Z-(Zfar+Znear)/(Zfar-Znear)));
Z = (Z-Znear)/SceneSize;
return 1.-Z;
```
注意 VTK 用的是**线性深度 / SceneSize 归一化**,Potree 用的是 **log2 深度**。两者都能做到尺度不变,log2 版更省(不用 near/far/SceneSize 三个 uniform)。

**VTK 的实际参数(逐字读自 `vtkEDLShading.cxx`)**:
| 参数 | 值 | 行号 |
|---|---|---|
| 邻居数 | 8,单位圆 `cos/sin(2πc/8)` 再归一化 | `:68-75` |
| `EDLLowResFactor` | **2**(半分辨率第二遍) | `:77` |
| `Zn` / `Zf` | 0.1 / 1.0 | `:78-79` |
| 全分辨率遍:`d` / `F_scale` | **1.0** / **5.0** | `:333-334` |
| 半分辨率遍:`d` / `F_scale` | **2.0** / **5.0** | `:422-423` |
| 双边滤波:`N` / `sigma` | **5** / **2.5** | `:478-479` |
| 光方向 `L` | `{0., 0., -1.}`(正面) | `:337` |
| `SceneSize` | 包围盒对角线 | `:401` |

**VTK 的两尺度合成**(`vtkEDLComposeFS.glsl`,全文很短):
```glsl
float lum = mix(shade1.r, shade2.r, 0.3);   // 70% 细尺度 + 30% 粗尺度
gl_FragData[0] = vec4(color.rgb * lum, color.a);
gl_FragDepth = shade1.a;
```
**两分辨率买到了什么**:全分辨率(d=1)只能看到 1 像素邻域,只出细的接触阴影;半分辨率(d=2,再降采样 2×,等效 4 像素邻域)出大尺度的形体感。混合 0.3 让两者叠加。中间那道 5-tap σ=2.5 的**双边滤波**用来去掉半分辨率遍的噪点同时保住边缘。这是 Potree 版**没有**的品质提升,而且很便宜(第二遍只有 1/4 像素)。

**C. CloudCompare 原版**(`plugins/core/GL/qEDL/shaders/EDL/edl_shade.frag`)——GPL,**仅作参考,不可抄**:
数学与 VTK 版同构(`computeObscurance` 用同样的光平面 `P` 和 `max(0, Znp)`),额外有 `PerspectiveMode` 开关做 `1/z` 深度缓冲补偿,shade 同样是 `exp(-Exp_scale * f)`。同目录的 `EDL_INFO.txt` 记录了 Boucheny 2011-12-21 的一次修改:去掉背景像素上的假阴影。

#### 3.4 参数取值范围(实测自各家源码,可直接用)

| 参数 | Potree 默认 | VTK 默认 | 建议起点(我们) |
|---|---|---|---|
| 邻居数 N | 8 | 8 | **8**(两家一致,别改;改了要重编译 shader) |
| 半径 radius | `edlRadius = 1.4` 像素 | `d = 1.0`(全分辨率)/ `2.0`(半分辨率) | **1.0 – 2.0 px** |
| 强度 | `edlStrength = 1.0`(构造)/ `0.4`(loadSettings 默认) | `F_scale = 5.0` | **0.4 – 1.0**(配 Potree 的 ×300 常数) |
| 不透明度 | `edlOpacity = 1.0` | — | 1.0 |
| 默认开关 | `useEDL = false`(默认关) | — | 我们应该**默认开** |
出处:`src/viewer/viewer.js:135-138`(构造)与 `:298-301`(loadSettings);`vtkEDLShading.cxx:333-334, 422-423`。

#### 3.5 端上成本(这是决定能不能上采集期的关键)

**算力**: 全分辨率一遍 = 每像素 **8 次依赖性纹理采样** + ~20 条 ALU。1170×2532 ≈ 2.96M 像素 × 8 = **23.7M 次采样/帧**。这在 A16 上不是小数,但也不是不可承受 —— 关键在下面两点。

**⚠️ TBDR(Apple GPU)上的真实代价不是 ALU,是"把深度落地"**。Apple GPU 是 tile-based deferred:深度缓冲正常情况下只存在于 tile memory,渲染完就丢弃(`storeAction = .dontCare`)。**第二遍要把深度当纹理采样,就必须把深度 store 到显存**,这是一次全分辨率的写 + 一次全分辨率的读。这才是主要成本。

**Potree 的做法恰好绕过了这个问题,而且这是我们应该抄的最重要的一个实现技巧**:
Potree 的 `edl.fs` 采的是 **`texture2D(uEDLColor, ...).a`** —— 它把 `log2(深度)` 写进**颜色 render target 的 alpha 通道**,而**不是**绑定深度缓冲当纹理。`uEDLDepth` uniform 虽然声明了(L24)但在着色器主体里根本没用。
→ 在移动 TBDR 上这意味着:**不需要 store/resolve 深度缓冲**,只需要一个本来就要写的 RGBA 颜色附件。这是白捡的一大笔带宽。

⚠️ **但有一个硬要求**:`EDLRenderer.js:32-38` 的 render target 是 `THREE.FloatType` + `NearestFilter` + RGBA。**必须是 float 或 half-float 颜色附件** —— alpha 通道装的是 `log2(depth)`,无界且深度小于 1 时为负,8-bit alpha 会彻底毁掉它。着色器里是 `precision mediump float`(L9-10),这是继承下来的精度上限。
→ 端上用 **RGBA16Float** 即可(half-float 对 log2 深度足够:尾数 10 bit,在 log 域上相对精度绰绰有余)。而 `Aether3D-cross` 的 OIT 路径**已经在用 RGBA16Float 的 `accumTexture`** 了(`PointCloudOIRPipeline.swift:402-424`),现成。

**降本手段(按性价比排序)**:
1. **半分辨率跑 EDL**。EDL 是低频的形体阴影,半分辨率几乎看不出差别 —— VTK 自己就有半分辨率遍。成本立刻降到 1/4(5.9M 采样)。
2. 抄 VTK 的两尺度(全 + 半)只在**草稿视图**用,采集期只用单遍半分辨率。
3. 邻居数不要降到 8 以下,会出现明显的方向性条纹。

**有没有人在移动端/WebGL 高分辨率跑 EDL**:Potree 就在 WebGL 里跑,并且 `viewer.js:605` 有 `Features.SHADER_EDL.isSupported()` 的能力检测门。这是一个正面数据点,但 WebGL 桌面 ≠ A16 手机采集期(我们还同时在跑 4K 相机 + SfM)。**这一项必须实测,见 ⑤。**

**⚠️ 关于"Potree 不支持移动端"的正确解读**(重要,别误判):
Potree issue #244(https://github.com/potree/potree/issues/244,2016-09-15 开,至今未实现)里 Markus Schütz 本人说明,EDL 在移动端的阻碍是 `EXT_frag_depth` 扩展 "pretty much zero support on mobile devices",他给的解法是"复用几何 pass 的 depth buffer,这样一开始就不需要 `EXT_frag_depth`"。
→ **阻碍是 WebGL 扩展可用性,不是算力**。这个障碍对原生 Metal / Vulkan / Dawn **完全不存在**。不能把"Potree 移动端没 EDL"推论成"EDL 在手机上跑不动"。

#### 3.6 🔴 EDL 不是稀疏点云的银弹 —— 本调研最重要的一条

CloudCompare 官方 wiki 逐字(https://www.cloudcompare.org/doc/wiki/index.php/EDL_(shader),我亲自取回原文):
> "EDL requires a contiguous depth map. Therefore if your cloud is too sparse at the current viewing zoom, you must increase the point size (so as to fill the holes)."

这直接命中我们的课题:**EDL 不能凭空把稀疏点云变成实体面。它要求输入的深度图先是连通的。** EDL 做的是"给已经连成片的深度图加上形体阴影",不是"把散点连成片"。

→ **因此正确的技术组合顺序是:先用自适应点尺寸把深度图填连通(技术 1+2),EDL(技术 3)才有有效输入。** 单独上 EDL 而不放大点尺寸,视觉收益接近零。这条决定了后面 ② 的推荐组合顺序。

---

### 4. 3DGS viewer 的技巧:哪些能搬到不透明彩色点

**许可证总表(全部读过 LICENSE 原文)**:

| 仓库 | 许可证 | 商用 |
|---|---|---|
| `graphdeco-inria/gaussian-splatting`(原版 3DGS) | Inria/MPII 自研研究许可 | 🔴 **红** |
| `graphdeco-inria/diff-gaussian-rasterization`(CUDA 光栅器) | 同上 | 🔴 **红** |
| `autonomousvision/mip-splatting` | 继承 Inria 研究许可 | 🔴 **红** |
| `nerfstudio-project/gsplat` | **Apache-2.0** | ✅ |
| `nerfstudio-project/nerfstudio`(Splatfacto) | **Apache-2.0** | ✅ |
| `antimatter15/splat` | **MIT** | ✅ |
| `mkkellogg/GaussianSplats3D` | **MIT** | ✅ |
| `playcanvas/engine` / `supersplat` / `supersplat-viewer` | **MIT** | ✅ |
| `@sparkjsdev/spark` | **MIT**(World Labs) | ✅ |
| `mrdoob/three.js` | **MIT** | ✅ |

Inria 三仓的红灯原文逐字:
> "THE USER CANNOT USE, EXPLOIT OR DISTRIBUTE THE *SOFTWARE* FOR COMMERCIAL PURPOSES"

**污染检查**:gsplat 的 `.gitmodules` 只含 `glm` 与 `googletest`,**没有** vendored Inria 光栅器 —— 是干净的独立重写而非 fork。所以"读 Inria 论文思路 + 用 Apache 实现"这条路是通的;只有直接抄 `diff-gaussian-rasterization` 的代码才踩雷。数值常数属事实,不受版权保护。

#### ✅ 能搬(而且是本节最值钱的东西)

**(a) 最小屏幕半径下限 —— 防远处点闪烁的唯一解**

各家实现的确切数值:

| 实现 | 机制 | 数值 |
|---|---|---|
| 原版 3DGS CUDA | 2D 协方差对角线加常数 | `cov[0][0] += 0.3f; cov[1][1] += 0.3f;` |
| gsplat | `eps2d` 参数 | `eps2d = 0.3`,CUDA 内硬编码断言 |
| PlayCanvas | shader 内联 + 独立剔除阈值 | `float diagonal1 = cov[0][0] + 0.3;` / `minPixelSize = 2.0` |
| Spark | 可调 uniform | `blurAmount` 默认 `0.3`,注释:约等于 0.5 像素半径 |
| mkkellogg | 构造参数 | `kernel2DSize = 0.3` |

gsplat docstring 逐字:`eps2d=0.3 leads to minimal 3 pixel unit`。
算术核对:方差 +0.3 ⇒ 每轴最小 σ = √0.3 ≈ 0.548 px,3σ 全宽 ≈ 3.3 px,与"minimal 3 pixel unit"自洽。

**为什么必须搬**:亚像素点精灵在相机微动时随机命中/错过像素中心 → 逐帧闪烁(twinkle)。这与高斯的透明性**完全无关**,是纯采样问题。远处点云"沙沙作响"的病根就是这个。
⚠️ **别照搬 0.3 这个数** —— 它是"方差单位",依赖 3DGS 特定的投影 Jacobian 和 σ 倍数约定。对点云应直接在**像素半径**上设下限。生产锚点:PlayCanvas `2.0 px`、Spark 源码里注掉的 `1.6`。
⚠️ PlayCanvas 的 `minPixelSize=2.0` 语义是**剔除**(小于就丢),不是抬升下限;抬升那一半靠 `+0.3`。两者配套,单用剔除不能防闪烁。

**(b) 最大屏幕半径上限**(防近处点炸成巨块):antimatter15 `min(sqrt(2.0*lambda1), 1024.0)`;PlayCanvas `min(1024.0, min(viewport.x, viewport.y))`;Spark `maxPixelRadius = 512.0`。

**(c) 透视正确的尺寸**:各家 Jacobian `J1 = focal / vp.z`,对点云就是 `screen_radius = focal * world_radius / z`。这是"点云看起来像表面而不是星空"的关键 —— 与 Potree ATTENUATED 是同一个东西。

#### ❌ 不能搬(搬了是负收益)

**(a) 深度排序 —— 不需要,原因要说清**
高斯必须排序,因为它们**半透明**,`over` 算子 `C = α_f·C_f + (1-α_f)·C_b` **不满足交换律**。
不透明圆盘**不需要**,因为深度测试是一个**逐片元的极值运算**,极值运算满足交换律和结合律 —— 任意绘制顺序,深度缓冲留下的都是同一个最近片元。**Z-buffer 就是硬件免费提供的完美排序。**
**唯一例外**:一旦为了抗锯齿开 alpha blending,就把顺序依赖重新引入了。绕过办法见下面 (d)。

**(b) Tile-based binning —— 这是透明度的优化,不是通用优化**
3DGS 分 tile 的唯一理由是每个 tile 内要按排序列表**串行**遍历,把透射率 `T` 累乘留在寄存器(`test_T = T * (1-alpha)`),并在 `T < 0.0001f` 时整个 tile 早停。每个组成部分都以"半透明 + 有序"为前提。
不透明点没有 `T`、没有 per-tile 列表、没有早停可言 —— 直接把 quad/point 丢给光栅器让 **early-Z** 拒绝被遮挡片元,而 early-Z 是硬件免费的。**不要为点云自己实现 tile binning。**
⚠️ 别混淆:移动 GPU 的"tiled rendering"是 Apple/Adreno/Mali **硬件**在做,白拿;3DGS 的 tile binning 是**软件层**的。名字像,目的完全不同。

**(c) 跨精灵的高斯 alpha 衰减 `exp(-0.5·dᵀΣ⁻¹d)` —— 对不透明点是净伤害**
两重原因:
1. *顺序依赖*:软 alpha 只在开 blending 时才有视觉意义,而不排序开 blending 就是错的。具体病象:depth-write 开 + blending → 近点半透明边缘混的是"当时 framebuffer 里恰好是什么",出现随机色晕且随绘制顺序抖动;depth-write 关 + blending → 完全丧失遮挡,变成颜色浆糊。
2. *标定缺失(点云特有)*:3DGS 敢用高斯衰减,是因为每个高斯的 `opacity` 和衰减核是**联合优化**出来的。原始彩色点云没有任何这种标定 —— 凭空套衰减核,密集区因大量半透明边缘叠加而**发灰发雾**,稀疏区每个点边缘发虚。结果是点云读起来**像雾而不像表面**,恰好和目的相反。

*生产实现的佐证(两家自己把"点云=关掉衰减"写进了 API)*:
- mkkellogg 的 point cloud mode 把协方差强制成各向同性小常数 `eigenValue1 = eigenValue2 = 0.2;`,衰减不再携带任何几何信息。
- Spark 的 `falloff` 参数,doc 逐字:`0 means "no falloff, flat shading"`,shader 里 `rgba.a = mix(rgba.a, rgba.a * exp(-0.5*z2), falloff)`。

**(d) 抗锯齿的正确做法**:硬圆盘 `if (dot(uv,uv) > 1.0) discard;` + 需要软边时用 **alpha-to-coverage**,而不是 alpha blending。
- alpha-to-coverage 把 alpha 转成 MSAA 采样覆盖掩码,resolve 时按逐采样深度解析 → **顺序无关**。WebGPU 原生支持(`multisample.alphaToCoverageEnabled`)。需要 `count > 1` 的 MSAA target。
- ⚠️ **常见误解**:"MSAA 就够了"是错的。MSAA 只抗锯齿**几何边**;用 `discard` 在 quad 里抠圆,MSAA **不会**平滑那个圆边(discard 逐片元生效,会杀掉该片元的所有采样)。想让 shader 定义的圆边变平滑,必须走 alpha-to-coverage 或 sample shading。

**(e) Mip-Splatting 的 3D smoothing filter —— 不迁移**
它按训练视角能诱导的最大采样频率去约束 3D 高斯尺度,是一个**训练期正则项**,作用在可优化的 3D scale 上。纯点云没有可训练的 scale。
其 2D Mip filter 那一半的**思想**迁移(就是上面的最小尺寸下限),但**不透明度补偿因子 ρ = √(det Σ / det(Σ+εI)) 不迁移** —— 点是不透明的,α 恒为 1,没有可补偿的量。硬要补偿等于把点变半透明,又绕回排序问题。

#### 最强的第三方背书

**PlayCanvas 自己在 SuperSplat 里要画纯点时,没有复用任何 gsplat 管线** —— 它直接另写了一个 ~20 行的 `gl_POINTS` 着色器(`src/shaders/splat-overlay-shader.ts`:`gl_PointSize = splatSize;`,fragment 只有 `gl_FragColor = varying_color;`,没有衰减、没有圆形抠图、没有协方差)。
这是"大部分 splat 机制不该迁移到点云"这个结论最好的经验证据。

---

### 5. 加权 splat / 高质量表面泼溅(Potree HQ 模式 = Botsch 三遍法)

**许可证**: Potree BSD-2 ✅。这是 Botsch & Kobbelt "High-Quality Point-Based Rendering on Modern GPUs" 系列的标准三遍结构在生产代码里的样子,**全部逐字读自源码**。

**Pass 1 — 深度遍**(`HQSplatRenderer.js`,`depthMaterial.setDefine("depth_pass", "#define hq_depth_pass")`,`shape = CIRCLE`,`weighted = false`,渲染到 `rtDepth`)。
关键是 **epsilon 深度偏移**(`pointcloud.vs:893-900`):
```glsl
#if defined hq_depth_pass
    float originalDepth = gl_Position.w;
    float adjustedDepth = originalDepth + 2.0 * vRadius;
    float adjust = adjustedDepth / originalDepth;
    mvPosition.xyz = mvPosition.xyz * adjust;
    gl_Position = projectionMatrix * mvPosition;
#endif
```
即**沿视线把点往后推 2 倍世界半径**。这就是 Botsch 的 epsilon-offset:它定义了一个深度"壳层",同一表面上互相重叠的 splat 都会落在壳内,从而在 Pass 2 里被接受参与混合;而真正被遮挡的背面表面落在壳外,被正常剔除。**没有这个偏移,同一表面的相邻 splat 会互相 z-fight,混合退化成随机取一个。**

**Pass 2 — 属性遍**(`weighted = true`,`shape = CIRCLE`,渲染到 `rtAttribute`,深度测试against Pass 1 的深度缓冲):
```js
blendFunc: [gl.SRC_ALPHA, gl.ONE],   // 加性,按 src alpha 加权
depthWrite: false
```
片元里累加(`pointcloud.fs:89-96`):
```glsl
float distance = 2.0 * length(gl_PointCoord.xy - 0.5);
float weight   = pow(max(0.0, 1.0 - distance), 1.5);
gl_FragColor.a    = weight;
gl_FragColor.xyz *= weight;
```
于是 RGB 累加的是 `Σ wᵢ·cᵢ`,A 累加的是 `Σ wᵢ`。

**Pass 3 — 归一化遍**(`normalize.fs` / `normalize_and_edl.fs`):`color = color / color.w`,得到加权平均色。`normalize_and_edl.fs` 把归一化和 EDL 合成到同一遍里(`:57-59` 先除权重再乘 shade,`:63` 写 `gl_FragDepthEXT = depth`)。

**成本**: **点云要画两遍**(深度遍 + 属性遍)+ 一个全屏归一化遍,外加两张浮点 render target。对 80k-155k 点、A16、采集期同时跑 4K 相机 + SfM 的场景,**这是本清单里最贵的一项**。

**视觉收益**: 真正的表面感 —— 重叠 splat 之间平滑过渡,消除硬边和 z-fighting 的斑驳。但前提同样是**点足够密、splat 足够大以至于互相重叠**;对我们这种稀疏云,如果 splat 没重叠,加权平均等于没做。

**⚠️ 对我们的判断**:三遍法的收益建立在"splat 互相重叠"上,而我们恰恰稀疏。**成本翻倍、收益不确定 → 不进第一批。** 见 ④。

---

### 6. 移动端点图元(point primitive)的坑 —— 决定了跨端必须用 instanced quad

这一节全部是我亲自查规范/官方表格/硬件数据库得到的一手数据,**结论是硬性的架构约束**。

#### 6.1 Metal(iOS)—— 没问题

Apple 官方 *Metal Feature Set Tables* 表格逐字:
> **Maximum size of a point primitive** = **511**

而且**所有列都是 511**(Apple1 … Apple9 全系,以及 Mac 系列)。出处:https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf(我下载后用 `pdftotext -layout` 提取,第 363 行)。
MSL 支持顶点输出 `[[point_size]]` 和片元输入 `[[point_coord]]` —— 我们现有的 `PointCloudRender.metal` 已经在用这两个(`float2 pointCoord [[point_coord]]`)。
→ **iOS 原生 Metal 路径:点精灵完全可用,511px 上限远超需求。**

#### 6.2 Android Vulkan —— 有一小撮设备把点尺寸锁死在 1.0

一手数据来自 Sascha Willems 的 Vulkan Hardware Database(https://vulkan.gpuinfo.org/displaydevicelimit.php?name=pointSizeRange%5B1%5D&platform=android),`VkPhysicalDeviceLimits::pointSizeRange[1]`(最大点尺寸)在 Android 上的取值分布(共 **8,198** 份报告):

| 最大点尺寸 | 报告数 |
|---|---|
| 4092 | 2923 |
| 1024 | 2178 |
| 4095 | 1026 |
| 1023 | 826 |
| 511 | 424 |
| **1** | **194** |
| 2047.94 | 152 + 72 |
| 8191.88 | 119 + 38 |
| 64 | 88 |
| 255.875 / 255 | 70 / 38 |
| 其余(189.875 / 256 / 512 / 511.938 / 8192) | 50 |

⚠️ **这张聚合表要正确解读,别吓自己**。逐设备核对真实的 Android GPU,主流芯片的上限都很大:

| GPU | `pointSizeRange` | `largePoints` |
|---|---|---|
| Adreno 750 / 830 / 810 | **[1, 4095]** | true |
| Adreno 740 / 660 / 650 / 640 / 610 | [1, 4092] | true |
| Mali-G715 / G76 / G52 | **[1, 1024]** | true |
| PowerVR BXM-8-256 | [1, 511] | true |

→ **"移动驱动点尺寸上限很小"这个流传的说法是错的。原生 Vulkan/GLES 路径上,大点在主流 Android GPU 上完全可用。**
那 194 份 `max = 1.0` 的报告基本是转译层/模拟器一类的离群值(典型代表:Vulkan-on-D3D12 的 Dozen 层报 `[1, 1]`,因为 **D3D12 根本没有点尺寸这个概念**)。占比 ≈2.4%,是一个需要有 fallback 的长尾,**但不是主要论据**。

Vulkan 规范对这条的规定(https://registry.khronos.org/vulkan/specs/latest/man/html/VkPhysicalDeviceFeatures.html)逐字:
> "`largePoints` specifies whether points with size greater than 1.0 are supported. **If this feature is not enabled, only a point size of 1.0 written by a shader is supported.**"

另外 `pointSizeGranularity`:**0.0625(1/16 像素)占 7573 份**,0.125 占 368,`0` 占 247,`1` 占 7。
→ 点尺寸是**量化**的,典型步长 1/16 px。

**真正决定性的论据是下面的 WebGPU,不是 Android。**

#### 6.3 WebGPU / WGSL —— **根本没有点尺寸这个概念**

这是最决定性的一条。我直接对规范全文做了检索:
- **WebGPU 规范**(https://www.w3.org/TR/webgpu/):`point_size` / `pointSize` 出现次数 = **0**。`point-list` 作为图元拓扑存在,规范逐字:`"point-list"` — Each vertex defines a point primitive.
- **WGSL 规范**(https://www.w3.org/TR/WGSL/):`point_size` 内置值出现次数 = **0**(WGSL 的 builtin 列表里没有它)。

WebGPU 规范 §23.2.5.1 Point Rasterization(https://www.w3.org/TR/webgpu/#point-rasterization)逐字:
> "A single FragmentDestination is selected within the pixel containing the framebuffer coordinates"

→ **一个点 = 恰好一个像素,规范级钉死,没有任何尺寸控制。** 这不是实现限制,是规范层面就不存在这个能力。

**设计理由**(gpuweb#332):底层 API 对点的行为互不兼容 —— 尺寸上限设备相关、点心落在裁剪空间外时是否绘制各家不同,**而且 D3D12 根本没有点尺寸概念**(上面 Dozen 报 `[1,1]` 就是活证)。WebGPU 选了最可移植的做法:只支持 1×1。

#### 6.4 结论:跨端路径必须用 instanced quad,不能用点图元

三条约束叠起来:

| 后端 | 点图元可用性 |
|---|---|
| Metal (iOS) | ✅ 最大 511 |
| Vulkan (Android) | ⚠️ 96.6% 可用,**≈2.4% 锁死在 1px** |
| **WebGPU / Dawn / WGSL** | 🔴 **构造性不可用,永远 1px** |

我们的铁律是"跨端是硬约束、GPU 用 Dawn/WGSL"。**Dawn/WGSL 路径不支持可变点尺寸 ⇒ 点图元这条路在跨端上是死的。**

**正确做法(全行业标准)= instanced quad / billboard**:每个点一个 instance,顶点着色器里用 `vertex_index` 生成 2 个三角形(或一个 oversized 三角形),per-instance 属性是中心点 + 颜色,尺寸在顶点着色器里算。这正是所有 3DGS web viewer 的做法(PlayCanvas / Spark / antimatter15 全部走 instanced quad,即使在 WebGL2 上)。
代价:每点 6 个顶点(或用 triangle-strip 4 个)而不是 1 个,顶点着色开销 ×4-6。对 155k 点 = 930k 顶点/帧,在 A16 上完全可承受(现代手机 GPU 的顶点吞吐以千万计)。

⚠️ 注意我们现有代码的现状:`Aether3D-cross` 的 Metal 路径用的是 `drawPrimitives(type: .point)` + `[[point_size]]`(`PointCloudOIRPipeline.swift:618`)。这在 iOS 上没问题,但**这条代码路径不能直接搬到 Dawn/WGSL**。如果要一份 shader 打通四端,现在就该切成 instanced quad。

#### 6.5 深度排序与 MSAA

- **不透明圆盘不需要排序**(理由见 §4 不迁移 (a):深度测试是极值运算,满足交换律)。→ Metal 路径应该走**不透明 + depth test/write 开 + 不混合**,把 Flutter 那种 `O(m log m)` 每帧排序彻底省掉。
- **MSAA 在 Apple TBDR 上相对便宜**(resolve 在 tile memory 里做,不落显存),但它**只抗锯齿几何边**;`discard` 抠出来的圆边 MSAA 管不了(discard 逐片元生效,杀掉该片元全部采样)。
- 想要圆边平滑 → **alpha-to-coverage**(WebGPU 原生 `multisample.alphaToCoverageEnabled`,Metal 有 `isAlphaToCoverageEnabled`),它把 alpha 转成采样覆盖掩码,按逐采样深度解析,**顺序无关**,不重新引入排序需求。
- ⚠️ EDL 与 MSAA 叠加要小心:EDL 需要一张可采样的深度/log-depth 纹理,MSAA target 需要先 resolve。建议 **EDL pass 在 resolve 之后的单采样纹理上跑**。

---

### 7. Schütz 的 compute shader 软光栅化 —— 🔴 端上不可用,但要知道为什么

Markus Schütz(Potree 作者)是这个领域的现代权威,他 2021/2022 的工作是"点云渲染"的 SOTA。**但对我们全部不可用**,理由要说清以免以后有人再提。

**论文**:
- Schütz M., Kerbl B., Wimmer M. "Rendering Point Clouds with Compute Shaders and Vertex Order Optimization." *Computer Graphics Forum* **40**(4):115–126, 2021. DOI `10.1111/cgf.14345`
- Schütz M., Kerbl B., Wimmer M. "Software Rasterization of 2 Billion Points in Real Time." *Proc. ACM Comput. Graph. Interact. Tech.* **5**(3):1–17, 2022. DOI `10.1145/3543863`

**方法核心**:用 compute shader 做软光栅化,**64-bit `atomicMin`** 把 depth+color 打包进一个 64 位字做深度竞争,再用 `atomicAdd` 累加颜色,最后除以计数。他的 HQS 变体测得比 `GL_POINTS` **快 up to 4×**(Retz 145M 点:GL_POINTS 31.98ms → HQS 8.40ms → HQS1R 6.87ms)。

**🔴 为什么端上不可用 —— 卡在 64 位原子操作**:
- **WGSL / WebGPU 完全没有 64 位原子操作**。`atomic<T>` 只支持 32 位;有一个明确以 Nanite 式深度缓冲为动机的提案 gpuweb#5071("Add limited support for 64 bit atomics")**至今未决**。64 位在 WGSL 里只能当 `vec2u` 复合处理,**给不了原子 min**。
- **Metal**:我从 Apple 官方 *Metal Feature Set Tables* 里逐字读到,`64-bit atomics` 一行标的是 **Apple9**,脚注 7 逐字:
  > "GPU devices in the Apple8 family support 64-bit atomic minimum and maximum using ulong, on both buffers and textures, **only on macOS**. The full set of 64-bit atomic operations is supported on all platforms starting with Apple9."

  **A16 = Apple8 家族,且我们是 iOS 不是 macOS ⇒ A16 iPhone 上 64 位原子操作完全没有。** 要到 A17 Pro(Apple9)才有。
- `compute_rasterizer` 仓库自己的 README 写明 **Windows + NVIDIA only**。

**许可证审计(全部读过 LICENSE 原文,这里有两颗雷)**:

| 仓库 | 许可证 | 商用 | 备注 |
|---|---|---|---|
| `potree/potree`(1.x 主线 viewer) | **BSD-2-Clause** | ✅ | 我们要抄的那个 |
| `potree/PotreeConverter` | **BSD-2-Clause** | ✅ | |
| `m-schuetz/compute_rasterizer` | **MIT** | ✅ | 但 Windows+NVIDIA only,跑不了 |
| `m-schuetz/SimLOD` | **MIT** | ✅ | **CUDA-only**,跑不了 |
| `m-schuetz/CudaLOD` | **MIT** | ✅ | **CUDA-only** |
| `m-schuetz/Skye` | **BSD-2-Clause** | ✅ | |
| `m-schuetz/Splatshop` | **MIT** | ✅ | 3DGS 编辑器,CUDA |
| 🔴 **`m-schuetz/Potree-Next`**(WebGPU 版 Potree) | **AGPL-3.0** | ❌ **红** | **最大的雷,见下** |
| 🔴 `m-schuetz/CuRast` | **AGPL-3.0** | ❌ **红** | |
| 🔴 `m-schuetz/webgpu_pointcloud` | **无 LICENSE 文件** | ❌ **红** | 无许可 = 保留一切权利 |

🔴 **最重要的一颗雷:Potree-Next(Potree 的 WebGPU 后继)是 AGPL-3.0,不是 BSD。**
我亲自读了 `https://raw.githubusercontent.com/m-schuetz/Potree-Next/master/LICENSE`,文件开头逐字:
> `Potree, Copyright 2021 Markus Schütz`
> `LICENSE: AGPL License, see: https://www.gnu.org/licenses/agpl-3.0.en.html`
> `To inquire for a different license, send a request to mschuetz@potree.org`
> 并自我说明:AGPL "closely resembles GPL but also closes loopholes for SaaS services"。

**这正是我们最容易踩的坑**:我们要做 WebGPU/Dawn 跨端,直觉上会去看"Potree 的 WebGPU 版本" —— 而那一个是 AGPL。
**规矩:只碰 `potree/potree`(BSD-2,WebGL 1.x 主线),绝不碰 `m-schuetz/Potree-Next` / `Potree2` / `CuRast`。** 作者提供改许可的联系方式,若真需要可走商务,但默认当红灯。

**一个可能的未来出路(仅登记,不推荐现在做)**:David Bauer 的 TU Wien 本科论文 "Rendering of Point Clouds via WebGPU"(导师 Wimmer + Schütz)用**纯 32 位原子操作**在 WGSL 里实现了同一套 3-pass HQS:一个 `atomicMin` 做深度,再用 4 个独立的 32 位 `atomicAdd` 分别累加 R/G/B 和计数。epsilon 用 "at most 1-2% farther away than the closest point"。
⚠️ **但:只有桌面 RTX 的结果,没有移动端数据,而且找不到公开源码。** 登记备查,不进任何一批。

---

### 8. 法线问题:我们没有法线,能不能屏幕空间现算?

**先回答最重要的问题:需要 per-point 法线吗?—— 不需要,有强存在性证明。**

我逐行读完了 Potree 的整条 HQ splat 管线,**它全程没有消费任何法线属性**。`pointcloud.vs` 确实声明了 `attribute vec3 normal`,但它只被 `getNormal()` 用于 `color_type_normal` 这个调试配色(L647-648)和一段被注释掉的代码。HQ splat 路径**从不碰它**。
→ Potree 是世界上部署最广的点云查看器,**它的答案就是:朝向相机的圆盘 + 径向权重,不用法线,并且就这么出货**。这不是降级 fallback,是被接受的正常配置。

**Potree 对"朝向"的唯一让步 = paraboloid 形状**(§2):它让每个圆盘中心向观察者鼓起,于是**相邻 splat 沿一条曲面边界互相穿插,而不是沿平面边界** —— 这找回了一部分定向椭圆才有的深度连续性,代价是 `gl_FragDepth`(丢 early-Z)。

#### 8.1 屏幕空间法线重建(从深度图求法线)—— 🔴 对我们的稀疏云直接不可用

四个变体(全部取自 Ben Golus 的 gist,https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0,注释是他自己的评语):

**3-tap**(41 math / 3 tex)—— 等价于朴素的 `normalize(cross(dFdx(viewPos), dFdy(viewPos)))`:
```glsl
vec3 hDeriv = viewSpacePos_r - viewSpacePos_c;
vec3 vDeriv = viewSpacePos_u - viewSpacePos_c;
vec3 viewNormal = normalize(cross(hDeriv, vDeriv));
```
评语:三角形内部准确,边缘有对角偏移,**深度落差处有 artifact**。
(`dFdx/dFdy` 是逐 2×2 quad 的有限差分,所以朴素版还会多一层 quad 量化的块状感。)

**4-tap**(50 / 4):中心差分 `r−l`、`u−d`。Golus 自己的评语:**"probably little reason to use this over the 3 tap approach"**。

**improved(Turánszki,https://wickedengine.net/improved-normal-reconstruction-from-depth/)**(62 / 5)——挑 z 差最小的那一侧:
```glsl
vec3 hDeriv = abs(l.z) < abs(r.z) ? l : r;
vec3 vDeriv = abs(d.z) < abs(u.z) ? d : u;
```
评语:凸边处的 artifact 反而**比 3-tap 和 4-tap 都差**。

**accurate(Yuwen Wu,https://atyuwen.github.io/posts/normal-reconstruction/)**(66 / 9)——用 ±1 和 ±2 两圈共 9 个 tap,挑最符合线性外推的邻居。评语:深度落差和边缘都没 artifact,**但"artifacts on triangles that are <3 pixels across"**。

**🔴 判断:这套东西在原始稀疏云上不能用,而且是结构性的,不是调参能救的**:
1. **邻居 tap 落进洞里**。点之间有空隙时,±1/±2 像素的 tap 打到背景(远平面)。`viewSpacePos_r − viewSpacePos_c` 变成一个沿视线方向的巨大向量,叉积出来的法线大致垂直于视线 —— 即**每个 splat 边缘都镶一圈垃圾法线**。
2. **"improved"/"accurate" 的启发式反而更糟**。它们挑深度落差**最小**的邻居;当两侧都是洞时,它们是在两个错误答案里自信地挑一个。而 Golus 说 accurate 在"小于 3 像素的三角形"上崩 —— **我们的 splat 恰恰就是亚 3 像素的特征**,正中靶心。
3. **逐 splat 刻面**。就算在 splat 内部,如果 splat 写的是平深度(圆盘而非抛物面),重建出的法线逐 splat 恒定 → 一颗颗珠子的刻面感,不是表面。

**→ 顺序是被强制的:必须先把深度缓冲填连通,才能重建法线。屏幕空间法线是填洞之后的廉价着色步骤,永远不能替代填洞。**
而且:如果深度是用双边/曲率流平滑填出来的,缓冲天然又密又平滑,这时**朴素 3-tap 就够了** —— 那些昂贵的保边变体在已经平滑过的缓冲上买不到任何东西,别付这个钱。

#### 8.2 ⚠️ 一条没人算过账的岔路:我们其实拿得到定向法线(登记待验)

法线估计难的那一半是**定向**(PCA 只给出无符号法线,符号是歧义的)。但**在摄影测量管线里,定向是免费的** —— 每个稀疏点都带着一条观测相机的 track,把 PCA 法线翻向观测相机的均值方向即可,不需要 MST 传播(Hoppe et al. SIGGRAPH '92 的经典做法;Open3D 有现成的 `orient_normals_towards_camera_location`)。

**我们手上已经有这个数据**:`SfmLiveSnapshot.obsOffsets`(CSR 偏移,点 *i* 的 track 长度 = `off[i+1] - off[i]`)—— 侦察报告确认它已经被计算并写进 `official_sfm_sparse_meta_v2` 的 track 长度直方图,只是**没有逐点写进 PLY**。

⚠️ **未验证**:kNN-PCA 在**我们这个稀疏度**下稳不稳 —— 稀疏 SfM 云上 k 邻域可能跨越多个表面。**在断定"定向椭圆这条路不通"之前,值得做一个便宜的实验。** 但注意这会触碰"只改渲染不改数据"的边界(需要新增 per-point 属性),要签决。

---

### 9. SSAO —— 一个一手的负面结果

我对 `potree/potree` 的完整文件树做了检索:**含 `ssao` / `ambient` / `occlusion` 的文件 = 0 个。**
Potree 的全部着色器只有 13 个文件:`blur`、`edl`、`normalize`、`normalize_and_edl`、`pointcloud`、`pointcloud_dynamic`、`pointcloud_sm`(各 .vs/.fs)。

→ **世界上部署最广的点云查看器,让点云"看起来像实体"的全部工具就是:点尺寸档位 + 点形状 + EDL + 加权 splat。没有 SSAO。**
这本身就是这个领域的答案:**对点云而言 EDL 就是那个 AO —— 它更便宜(8 tap vs SSAO 的 16-32 tap + 噪声 + 去噪遍)、不需要法线(SSAO 的常见变体需要)、而且是为深度不连续设计的,正好是稀疏点云的主要视觉线索。**
⚠️ 我没有找到任何**正式发表**的 EDL vs SSAO 定量对比。上面是基于"三大点云软件(Potree/CloudCompare/ParaView)都选了 EDL 且都没做 SSAO"的强归纳,不是论文结论。

---

## ② 推荐组合(按 视觉收益 × 端上成本 × 许可安全 排序)

### 决策的两条主线

1. **顺序被物理约束锁死**:CloudCompare 官方明说 EDL 需要 "contiguous depth map"。**必须先用点尺寸把深度图填连通,EDL 才有输入。** 所以第一批必须是尺寸,不是 EDL。
2. **我们的点云只有 xyz+rgb**。所有需要法线的技术(EWA/surfel/定向椭圆)第一轮全部出局;所有需要点重叠的技术(加权 splat)在稀疏区收益不确定。

### 🏆 推荐栈(共 4 条,按落地顺序)

| # | 技术 | 视觉收益 | 端上成本 | 许可 | 参考实现 |
|---|---|---|---|---|---|
| **1** | **透视衰减点尺寸 + min/max 钳制** | 🔥🔥🔥 最高。这是把"星空"变成"表面"的那一步,也是 EDL 的前置条件 | 💚 几乎为零(顶点着色器几条 ALU) | ✅ BSD-2 | Potree `pointcloud.vs:666-705` |
| **2** | **圆形点(平方半径 discard)** | 🔥🔥 中高。方点在大尺寸下极其明显地"像贴纸" | 💚 一次 `discard`(⚠️丢 early-Z) | ✅ BSD-2 | Potree `pointcloud.fs:50-55` |
| **3** | **EDL(log2 深度存 alpha 通道)** | 🔥🔥🔥 最高。这是"读起来像实体"的那个决定性效果 | 🟡 一个全屏 pass,8 tap;半分辨率可降到 1/4 | ✅ **BSD-3(照 VTK 写)** | VTK `vtkEDLShadeFS.glsl` + Potree 的 alpha 通道技巧 |
| **4** | **最小屏幕半径下限(防闪烁)** | 🔥🔥 中高。消除远处点云"沙沙作响" | 💚 一个 `max()` | ✅ MIT/Apache | PlayCanvas `minPixelSize`、gsplat `eps2d` |

技术 1 和 4 其实是同一行代码的两半(`clamp(size, minSize, maxSize)`),Potree 就是这么写的 —— 但**必须理解它们解决的是两个不同的问题**:min 防亚像素闪烁,max 防近处点炸屏。

### 具体参数(全部来自已认证的生产配置,不自创)

```
// 点尺寸(抄 Potree ATTENUATED 的骨架)
slope       = tan(fov_y / 2)
projFactor  = 0.5 * screenHeight / (slope * (-viewPos.z))   // 像素 / 世界单位
pointSize   = k * worldRadius * projFactor
pointSize   = clamp(pointSize, minSize, maxSize)

minSize = 2.0      // Potree 默认(PointCloudMaterial.js:32-38);
                   // 与 PlayCanvas minPixelSize=2.0、gsplat eps2d=0.3(≈3px)三家一致
maxSize = 50.0     // Potree 默认。我们可以更小,建议先试 20-30
k * worldRadius:   我们没有八叉树 spacing,用"点云平均最近邻距离"代替
                   (Potree 用的是 uOctreeSpacing * 1.7,那个 1.7 是它的经验系数)
```

```
// EDL(抄 VTK 的算法 + Potree 的 log2-in-alpha 实现技巧)
NEIGHBOUR_COUNT = 8          // Potree 和 VTK 完全一致,别改
neighbours[c]   = (cos(2πc/8), sin(2πc/8))
radius          = 1.0 - 2.0 px     // Potree 1.4;VTK 全分辨率 1.0 / 半分辨率 2.0
strength        = 0.4 - 1.0        // Potree loadSettings 默认 0.4,构造默认 1.0
shade           = exp(-response * 300.0 * strength)   // 300 是 Potree 的硬编码常数
depth 通道      = log2(-viewPos.z),写进 RGBA16Float 颜色附件的 alpha
```

⚠️ **两个不可改的参数细节**:
- **邻居数 8**:Potree 和 VTK 独立地都选了 8。低于 8 会出现方向性条纹。改这个数在 Potree 里还会触发 shader 重编译(它是 `#define`)。
- **颜色附件必须是 float/half-float**:alpha 里装的是 `log2(depth)`,无界且可为负,8-bit alpha 会彻底毁掉它。**RGBA16Float**。

### 🥈 第二批(先做完第一批、实测有余量再上)

| # | 技术 | 为什么排后面 |
|---|---|---|
| 5 | **VTK 的两尺度 EDL**(全分辨率 + 半分辨率 + 5-tap σ=2.5 双边上采样,`mix(fine, coarse, 0.3)`) | 单尺度 EDL 只出 1 像素宽的轮廓;第二尺度才给出"体积感"光晕。但成本 +~60%,先确认单尺度的收益 |
| 6 | **抛物面点形状 + 保守深度提示** | 让相邻 splat 沿曲面而非平面穿插,更像表面。但写 `gl_FragDepth` 丢 early-Z。⚠️ Potree **没有**用 `layout(depth_greater)`,而 `wi ≤ 0` 意味着深度只增 —— **这个保守深度提示在数学上成立,是一个 Potree 没做而我们可以做的优化**,能把 early-Z 找回来 |
| 7 | **alpha-to-coverage 抗锯齿圆边** | 顺序无关,不重新引入排序。但要开 MSAA target |

---

## ③ 两个渲染面各自的落地方案

### 方案 A —— 原生 GPU 路径(Metal 现在 / WGSL 跨端)

**现状**(侦察实测):
- 产品 App(`pocketworld`)的 AR overlay 是 **SceneKit**,`pointSize=6`,`min/maxPointScreenSpaceRadius = 2/6`,**深度读写全关**。
- 真正的 Metal 点精灵管线在 `Aether3D-cross`,用 `.point` 图元 + `[[point_size]]`,尺寸 `8.5 × 2.0 × clamp(1.75/depth, 0.50, 3.0)`,已有 depth32Float 和 RGBA16Float 离屏 target。

**🔴 第一个必须签决的架构问题:SceneKit 路径上做不了 EDL。**
SceneKit 的 `readsFromDepthBuffer = false` / `writesToDepthBuffer = false` 意味着没有可用的深度信息,也没有离屏 target。**要在产品 App 的 AR overlay 上做 EDL,必须把这条路径从 SceneKit 换成 Metal。** 这是一笔真实的工程量,需要签决。

**分步落地**:

**Step 0(零成本、立刻可做,不需要换 SceneKit)**:
把 SceneKit 的尺寸参数改成透视正确的形式。SceneKit 的 `minimumPointScreenSpaceRadius`/`maximumPointScreenSpaceRadius` 已经提供了钳制能力,现在是 `2/6` —— 这其实已经是 Potree ADAPTIVE 的简化版。可以先只调这三个数(`pointSize`、min、max)做 A/B。
**这一步就能拿到推荐栈里技术 1 和 4 的大部分收益,且不动架构。**

**Step 1(换 Metal,拿 EDL)**:
```
Pass 1: 点云 → RGBA16Float 离屏 target
        - instanced quad(不要用 .point,见 §6.4)或先用 [[point_size]] 过渡
        - 片元:圆形 discard(cc = u²+v² > 1.0 → discard)
        - rgb = 颜色, a = log2(-viewPos.z)     ← Potree 的技巧,省掉 depth store
        - 不透明,depth test/write 开,不混合,不排序
Pass 2: 全屏 EDL(照 VTK 的 vtkEDLShadeFS.glsl 写)
        - 采 Pass 1 的 alpha 通道,8 邻居,radius 1.0-2.0 px
        - shade = exp(-response * 300 * strength)
        - 输出 rgb * shade,合成到相机画面上
```
⚠️ **TBDR 注意**:采用 Potree 的 alpha 通道方案后,**不需要 store 深度缓冲**(depth 可以保持 `storeAction = .dontCare` / memoryless),只需要那张本来就要写的 RGBA16Float。这是移动端最重要的一个省法。
⚠️ 采集期建议 EDL 跑**半分辨率**再上采样;草稿视图可以跑全分辨率或 VTK 的两尺度。

**Step 2(跨端,Dawn/WGSL)**:
必须用 **instanced quad**,因为 WGSL 根本没有点尺寸(§6.3),而且 ~2.4% 的 Android 设备把点尺寸锁死在 1px(§6.2)。
EDL 那一遍是纯全屏 fragment shader,WGSL 直译即可,没有障碍。
🔴 **绝不参考 `Potree-Next` / `CuRast`(AGPL)。** 参考 `potree/potree`(BSD-2)+ VTK(BSD-3)。

### 方案 B —— Flutter 草稿视图

**现状**(侦察实测):已经在用 `drawRawAtlas` + 16×16 抗锯齿白色圆盘 sprite + `BlendMode.modulate` 逐点上色,`_pointSize = 2.67`,`baseScale * (camDist/depth)` 透视缩放,**已有全量 `O(m log m)` 深度排序**,170k 点不抽稀,纯 Dart CPU 投影。

**好消息**:推荐栈里的技术 1、2、4 在 Flutter 里**基本已经做到了** ——
- 技术 2(圆形点):已完成(sprite 就是抗锯齿圆盘,比 discard 还好,自带 AA)。
- 技术 1(透视衰减):已完成(`baseScale * camDist/depth`)。
- 技术 4(最小尺寸下限):**缺**。现在没有 `clamp`,远处点会退化到亚像素 → 这正是"沙沙作响"的病根。

**立刻可做(一行改动,最高性价比)**:
```dart
// sparse_cloud_view.dart:913 附近
scaleA[m] = ortho ? baseScale : baseScale * (camDist / depth);
// 改成(sprite 是 16px 图块,圆盘直径占 14px):
final double minScale = 2.0 / 14.0;   // 下限 2 逻辑像素直径,对齐 Potree minSize=2.0
final double maxScale = 24.0 / 14.0;  // 上限,防近处炸屏
scaleA[m] = (ortho ? baseScale : baseScale * (camDist / depth)).clamp(minScale, maxScale);
```

**顺带一个净省**:既然点是不透明的,**那个每帧 `O(m log m)` 的深度排序在视觉上仍然需要**(Flutter canvas 没有深度缓冲,painter's algorithm 是唯一手段)—— 所以这里**不能**照搬 §4"不透明点不需要排序"的结论。⚠️ 那条结论的前提是有硬件 Z-buffer;Flutter canvas 没有。**保留排序。**

**🔴 EDL 在纯 Flutter canvas 里做不了 —— 硬约束**:
`FragmentProgram` 的官方限制我逐字核实过(https://docs.flutter.dev/ui/design/graphics/fragment-shaders):
> "UBOs and SSBOs aren't supported" / "`sampler2D` is the only supported sampler type" / "No additional varying inputs can be declared" / "Unsigned integers and booleans aren't supported"

uniform 只能是 `float/vec2/vec3/vec4` + `sampler2D`。**没有深度缓冲可采,也没有办法拿到深度缓冲。**

**⚠️ 一条理论上可行但属于"我们自己推导"的路子(不符合"只抄成熟方案",仅登记待评估)**:
Flutter 的 blend mode 里有 `BlendMode.lighten`(逐通道取 max)。若把 `log2(深度)` 编码成"越近越亮"画进一张离屏图,`lighten` 就等价于一个 max-composite 的深度缓冲;再 `Picture.toImageSync` 拿到 `ui.Image`(它是 **GPU-resident 且不回读到 host** 的,这是唯一可接受的每帧路径),连同颜色图一起作为两个 `sampler2D` 喂给一个做 EDL 的 `FragmentProgram`。
🔴 **但这不是任何成熟实现在做的事,是推出来的**,而且要多画一遍 170k 点。**按"不自创算法"的铁律不推荐**;若要做必须先性能实测并签决。

#### 🔴 一个必须知道的现存性能隐患:我们现在用的 `drawRawAtlas + colors` 恰好命中 Impeller 最慢的路径

Flutter issue **#131345**(https://github.com/flutter/flutter/issues/131345,2023-07 开,**P2,至今未修**):`drawVertices` 和 `drawAtlas` 在 Impeller 上比 Skia 后端慢得多。根因是**需要 blending 时 Impeller 走离屏纹理 subpass** —— per-vertex/per-sprite color 会触发**两次独立的 offscreen render 再合成**。
相关的还有 #120925(同一根因)、#127374(`drawAtlas` + `BlendMode.modulate` 在真机 iOS 上渲染错误,已修)。

→ 我们的 `sparse_cloud_view.dart:944-952` 正是 `drawRawAtlas(..., colors, BlendMode.modulate, ...)`。**这条路径的性能问题是已知且未修的**,值得实测确认它是不是草稿视图卡顿的来源。

#### stable channel 下的三个可选路径(实测数据来自 Impeller 引擎源码)

| 方案 | 视觉 | 代价 |
|---|---|---|
| `drawRawPoints` + `StrokeCap.round` | 圆点 | 🔴 **全批只能一个 `Paint` = 单色**,彩色点云要按颜色分桶多次 draw call。且 Impeller 下圆点是 **CPU 逐点三角化**:`engine/src/flutter/impeller/entity/geometry/point_field_geometry.cc` 里每个圆点展开 ~22 个顶点(半径 3-5px 时),170k 点 ≈ **26 MB/帧在 raster 线程单线程写入**;放大相机还会自动增加每点顶点数 |
| **`drawVertices(Vertices.raw, ..., BlendMode.dst)`** | **方块 splat + 逐点真彩色** | 🟢 `BlendMode.dst` = **完全忽略 paint,只用顶点色**,正是纯彩色点云要的。每点 2 三角形 = 6 顶点,170k 点 ≈ 7.2 MB positions + 3.6 MB colors。⚠️ `indices` 是 `Uint16List`(上限 65535),**不要用索引**,走 non-indexed |
| `drawRawAtlas` + colors(**现状**) | 抗锯齿圆盘 + 逐点色 | 🟡 视觉最好,但命中 #131345 的慢路径 |

**判断**:圆 vs 方对"实心感"的贡献,**远小于**"尺寸随深度自适应 + 正确遮挡"的贡献。如果实测确认 `drawRawAtlas` 是瓶颈,`drawVertices + BlendMode.dst` 是有据可依的降级方案,而且**几何按 quad 建模,将来能原样搬到 Dawn 的 instanced quad**(§6.4),不会白写。

#### 🏆 最值得跟进的单点:`flutter_scene`(MIT)

`https://pub.dev/packages/flutter_scene` v0.20.0(**2026-07-27 发布,即昨天**),作者 bdero(Flutter GPU 本人作者),**MIT 许可**。官方描述里有三条正中我们要害:
> "3D Gaussian splatting, loading `.ply` and `.splat` captures as scene nodes"
> "splats and normal geometry occluding each other correctly"
> **"Per-frame scene inputs for custom shaders, including scene depth and shadow data, plus a depth-aware and shadow-aware custom post-pass API"**

最后一条 = **EDL 需要的全部东西**(场景深度 + 自定义后处理 pass),而且它直接吃 `.ply`。
🔴 **唯一 blocker:需要 master channel。** `flutter_gpu` 至今未上 stable(engine 文档 `docs/engine/impeller/Flutter-GPU.md` 明确警告不保证 API 稳定、需要 Impeller、建议切 master、shader 构建依赖实验性的 Native Assets)。flutter_scene 自己的 README 也写着 "Flutter GPU, which hasn't shipped to the stable channel yet"。

→ **按记忆库铁律"选型先查成熟方案,能抄直接抄",这值得起一个 spike**;但产品 App 走 stable,**不能直接出货**。

#### flutter_gpu 本身(如果将来上 stable)

`https://api.flutter.dev/flutter/flutter_gpu/` 暴露了 `RenderPass`、`RenderTarget`、`RenderPipeline`、**`DepthStencilAttachment`**、`ColorAttachment`、`DeviceBuffer`、`CommandBuffer`、`ShaderLibrary`,**并支持自定义 vertex shader**(用 `.shaderbundle.json` manifest 声明 vert/frag,由 impellerc AOT 编译)。
文档还提到 `StorageMode.deviceTransient` 正是为"只活在 tile memory、不需要 VRAM 后备"的附件设计的,并明说 **depth/stencil 纹理通常符合这个条件**。
→ **纯 Dart 的真 3D pass + 真 EDL 在 flutter_gpu 上是可行的。**
⚠️ 但 `PrimitiveType.point` 在 Impeller 里**同样没有点尺寸**(在 flutter/flutter 仓库全文搜 `gl_PointSize` 零命中)—— flutter_gpu 上也必须走 instanced quad。(此条为**由缺失推出的推论**,非文档明述。)

#### 结论

- **stable channel 的现实上限 = 技术 1/2/4(尺寸自适应 + 圆形 + min/max 钳制)+ 保留深度排序。EDL 构造性不可达。**
- 要跨过这道坎只有两条路:**flutter_scene / flutter_gpu(master channel)**,或 **`Texture` widget + 原生渲染器**(iOS 官方支持路径:`FlutterTextureRegistry`;`Texture` widget 的重绘"generally does not involve executing Dart code",即原生渲染循环不受 Dart 帧调度拖累)。后者若底座是 Dawn/WGSL 的 C++ 渲染器、各端只写薄 shim,**是符合我们"计算不搬 Dart / Swift 只做平台 shim"铁律的**。

---

## ④ 明确不推荐的(以及为什么)

| 技术 | 为什么不推荐 |
|---|---|
| **EWA splatting / 定向椭圆 surfel** | 需要 per-point 法线,我们的 PLY 只有 xyz+rgb(15 字节)。**Potree 全程不用法线并且就这么出货**,是最强的反证 —— 先把不用法线的方案做满 |
| **屏幕空间法线重建** | 在稀疏云上结构性失效:邻居 tap 落进洞里 → 法线垃圾;"improved"/"accurate" 启发式在两侧都是洞时更糟;Golus 自己说 accurate 在"<3 像素的三角形"上崩,而我们的 splat 就是亚 3 像素(§8.1) |
| **Schütz 的 compute 软光栅化** | 依赖 64 位原子操作。**WGSL 完全没有**(gpuweb#5071 未决);**Metal 要 Apple9,A16 是 Apple8 且只有 macOS 才有** —— 构造性不可用(§7) |
| 🔴 **CloudCompare 的 EDL 代码** | GPL-2.0-or-later。算法可以学(已公开发表),**代码绝不可抄**。用 VTK 的 BSD-3 版本,连"接触过 GPL 代码"的举证风险都规避掉 |
| 🔴 **Potree-Next / Potree2 / CuRast** | **AGPL-3.0**。这是最容易踩的雷,因为我们要做 WebGPU 而它正是"Potree 的 WebGPU 版"(§7) |
| 🔴 **`m-schuetz/webgpu_pointcloud`** | 无 LICENSE 文件 = 保留一切权利 |
| 🔴 **INRIA 3DGS / diff-gaussian-rasterization / Mip-Splatting** | 非商用研究许可,原文:"THE USER CANNOT USE, EXPLOIT OR DISTRIBUTE THE *SOFTWARE* FOR COMMERCIAL PURPOSES" |
| 🔴 **CUDA 系(SimLOD / CudaLOD)、compute_rasterizer** | 许可证干净(MIT)但 CUDA-only / Windows+NVIDIA only,跨端铁律直接排除 |
| **高斯 alpha 衰减(软边 splat)** | 对不透明点是**净伤害**:①不排序开 blending 会出随机色晕;②我们没有 3DGS 那种 opacity-Σ 联合标定,凭空套衰减核会让密集区发灰发雾 —— 点云读起来**像雾不像表面**。mkkellogg 和 Spark 自己都把"点云=关掉衰减"写进了 API(§4) |
| **深度排序 / tile binning(原生路径)** | 不透明圆盘不需要:深度测试是极值运算,满足交换律,Z-buffer 就是免费的完美排序。tile binning 是为透明度累乘透射率设计的,不透明点没有 `T` 可累(§4)。⚠️ **例外:Flutter canvas 没有 Z-buffer,那里必须保留排序** |
| **SSAO** | Potree 全仓 0 个 AO 文件。对点云,EDL 更便宜(8 tap)、不需要法线、且专为深度不连续设计(§9) |
| **加权 splat 三遍法(第一批内)** | 收益建立在"splat 互相重叠"上,而我们恰恰稀疏;成本是点云画两遍 + 两张 float RT。**成本翻倍、收益不确定 → 不进第一批**(§5) |

---

## ⑤ 未找到 / 需自测项

**必须自测(没有任何文献能替我们回答)**:
1. 🔴 **EDL 在 A16 采集期的真实开销**。采集期同时在跑 4K 相机 + SfM + 渲染,热已经是硬约束(记忆库:`feedback_thermal_stability_hard_requirement`)。必须用**热受控的同进程 back-to-back 对照**测,单次墙钟 ±30% 不可信。测三档:关 EDL / 半分辨率 EDL / 全分辨率 EDL。
2. 🔴 **点尺寸要多大才能让深度图"连通"**。CloudCompare 只说"要加大到填满洞",没给公式。我们的点云密度是已知的(平均最近邻距离可算),但阈值要肉眼定。**按记忆库铁律,必须开网页与原版并排肉眼对比**(`feedback_visual_compare_every_progress`)。
3. **`minSize` 取 2.0 还是更大**。Potree 2.0 / PlayCanvas 2.0 / gsplat ≈3px 三家一致落在 2-3px,但那是桌面;Retina 手机上逻辑像素 ≠ 物理像素,需要实测。
4. **instanced quad vs `[[point_size]]` 在 A16 上的实际差距**。155k 点 × 6 顶点 = 930k 顶点/帧,理论上无压力,但要实测确认。
5. **kNN-PCA 法线在我们的稀疏度下稳不稳**(§8.2)。如果稳,定向椭圆这条路重新打开;但会触碰"只改渲染不改数据",要签决。
6. 🔴 **`drawRawAtlas + colors` 是不是草稿视图的性能瓶颈**(Flutter #131345 未修的慢路径)。若是,对照 `drawVertices + BlendMode.dst`。
7. **Dart 侧 170k 点每帧排序的真实耗时**。通用 `List.sort` 估 20-50ms(不可接受),`Float32List` 上的 counting sort 估 2-5ms —— **都是估算,未实测**。工程解:只在相机**旋转**超阈值时重排(平移和缩放不改变深度序)。
8. **`flutter_scene` spike**(MIT,已实现 `.ply` 加载 + depth-aware post-pass)。跟进它离 stable 还有多远,以及 depth-aware post-pass 能不能直接跑我们的 EDL。

**未取得原文 / 未验证(不要当既成事实)**:
- Botsch 原论文如何定义 epsilon 深度偏移。我有 **Potree 的答案(`2 × 世界半径`,一手源码)** 和 **Schütz 的答案(最近点深度的 1%,一手论文)**,但原始论文的表述未核实。
- CloudCompare / Open3D / MeshLab 在没有法线时具体怎么做 —— 只找到第三方博客/论坛,**没有一手来源**。
- EDL vs SSAO 的**正式定量对比** —— 找不到。§9 的结论是强归纳,不是论文结论。
- Pull-push 填洞(Grossman & Dally 1998 / Marroquim 2007)与屏幕空间流体渲染(van der Laan I3D 2009)的公式与可用代码 —— **本轮未验证完**。⚠️ 直觉上流体渲染假设粒子采样的是**体**,而摄影测量点云采样的是**薄表面**,激进的深度平滑可能抹掉真实几何细节 —— **这是待验证的怀疑,不是结论**。
- Surfel / EWA 的精确引文(Pfister 2000、Zwicker 2001/2002、Botsch 2003/2005)与 EWA 的 2×2 Jacobian 推导 —— 本轮未取得原文。鉴于 ④ 已判定这条路第一轮出局,优先级低。
- `pygfx`(BSD-2)的 WGSL EDL 实现逐字源码 —— 未完整取得。若要走 WGSL 可作为第二参考,但**以 VTK 为准**。

**其他未验证项(来自各路调研的诚实标注)**:
- MSL 规范里**没有**"point size 会被 clamp 到实现定义范围"这句话 —— 对 383 页全文检索 `point_size` 周边的 clamp/range/implementation 三个词零命中。511 这个上限**只出现在 Feature Set Tables**,超限行为无文档。**别引用"MSL 规范说会 clamp"。**
- `GL_ALIASED_POINT_SIZE_RANGE` 的逐设备实测值未取到(opengles.gpuinfo.org 该页 404)。Vulkan 数据是真实的,GLES 值只是推测同源。
- `gl_PointCoord` 在 Adreno/Mali 上的可靠性 —— 未找到系统性 bug 报告,也未找到反证。
- "MSAA 不抗锯齿 discard 抠出的圆边" —— 这是基于 discard 逐片元语义的**推论**,未找到直接的文档表述。
- EDL 关掉 memoryless depth 后的**具体带宽代价**未量化。
- flutter_gpu 的 `PrimitiveType.point` 只能画 1px —— **由 `gl_PointSize` 在引擎源码零命中推出**,非文档明述。

**已澄清的传言**:
- ❌ "Potree 是免费商用但需署名" —— **不成立**。就是标准 BSD-2,没有 NOTICE 文件,README 没有 license 章节(§1)。
- ❌ 任务书里的 "Boucheny / CEA" —— **产业方是 EDF(Électricité de France),不是 CEA**。VTK 着色器头注释逐字:"Electricité de France, CNRS, Collège de France and Université J. Fourier"。
- ❌ "Potree 不支持移动端 ⇒ EDL 在手机上跑不动" —— **推论错误**。Potree issue #244 里作者本人说明,阻碍是 WebGL 的 `EXT_frag_depth` 扩展可用性,不是算力;原生 Metal/Vulkan/Dawn 无此障碍(§3.5)。
