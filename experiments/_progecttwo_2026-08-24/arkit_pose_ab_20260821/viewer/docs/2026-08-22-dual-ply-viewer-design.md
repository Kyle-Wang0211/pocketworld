# A / B1 双 PLY 肉眼对比查看器设计

## 目标

在本机网页中并排显示首轮主实验的真实 A 与 B1 稀疏点云，让使用者用同一尺度、同一视角直接肉眼比较结构质量。页面不是截图，也不使用过滤后的 delivered cloud。

## 冻结输入

- A：`work/A_current_sidecar_01/model`，20,407 个 raw COLMAP points3D。
- B1：`work/B1_contract_smoke_01/model`，20,348 个 raw COLMAP points3D。
- B1→A：从 57 个共同相机中心重新计算的 camera-center Sim(3)。只改变 B1 的坐标 gauge，不删除、补点或去噪。
- 两个重建模型的已有 RGB 字段全为 `(0,0,0)`，不能直接当真彩使用。颜色必须从该 capture 的 60 帧、4032×3024 原始照片归档流 `photos.hevc` 解码，并使用 COLMAP/pycolmap 的标准 `extract_colors_for_all_images` 按每个 3D 点的全部 track observations 求均值。真实 RGB 写入 PLY；网页不得生成或覆盖伪色。

## 方案比较

1. **自包含 Plotly/WebGL（采用）**：网页直接 fetch 两个 ASCII PLY，自行解析后在一个 Plotly figure 的两个 3D scene 中渲染。优点是无需 CDN、可同步 camera、可直接在浏览器检查；代价是 HTML 约数 MB。
2. Three.js + PLYLoader：交互更自由，但需要额外 vendoring 三个 JS 模块和许可证文件，当前只看两朵稀疏云不值得增加依赖面。
3. 预渲染双截图：最快但不能旋转、缩放，也不满足“网页打开肉眼看真实 PLY”。不采用。

## 页面设计

主题是“摄影测量检片台”：深炭黑背景，A 用仪器青标签，B1 用琥珀标签，中间是一条表示 pose-on / pose-off 的窄分界线。主体只保留双 3D 视窗；没有营销式卡片。

- 左：`A · ARKit pose baseline`。
- 右：`B1 · pose input = 0`。
- 两侧使用完全相同的 axis range、aspect ratio、点大小；各自显示从同一组 capture RGB 帧提取的真实点色。
- 默认同步 orbit / zoom；可解锁单独视角。
- 控件：同步视角、点大小、重置视角、全屏。
- 页面显示点数、注册帧数和已审计的 Sim(3) 诊断，但明确“A 不是真值”。
- 页面提供两个正在显示的 PLY 下载链接，并注明 B1 只做 Sim(3) 对齐。

## 数据流

`COLMAP bin → pycolmap → 点数/hash 断言 → B1 Sim(3) → ASCII PLY → browser fetch/parse → Plotly WebGL 双 scene`

构建脚本同时输出 `viewer-manifest.json`，记录模型 SHA、HEVC/帧映射 SHA、点数、真彩提取方法、Sim(3)、PLY SHA 和“无过滤/无伪色”声明。网页加载失败或 vertex count 不匹配时显示明确错误并不创建图形。

## 验收

- A PLY vertex count = 20,407；B1 PLY vertex count = 20,348。
- B1 输出点数与输入完全相同，坐标严格等于冻结 Sim(3) 变换结果。
- 两个 PLY 至少 99% 顶点为非黑真实 RGB，且 PLY 颜色来自同一个已冻结的 capture HEVC，不是网页伪色。
- 页面 HTTP 200，两个 PLY HTTP 200；无 CDN 请求。
- 浏览器中双 scene 均可见，标题/点数正确，camera 同步和 point-size 控件生效。
- 浏览器控制台无 error；桌面截图能清楚看到左右两朵点云。
