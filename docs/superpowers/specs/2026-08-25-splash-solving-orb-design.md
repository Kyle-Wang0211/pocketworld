# 启动加载页 Solving 粒子球设计

日期：2026-08-25

## 目标

把当前品牌 Logo、标题、副标题、进度条和状态文案组成的 Flutter 启动加载页，替换为一个全屏实时粒子加载画面：纯黑背景，白色 `solving` 粒子球严格位于屏幕几何中心，速度固定为 `0.8`。

本变更只影响 Flutter 引擎启动后、应用主界面准备完成前显示的 `AetherSplashOverlay`。iOS 静态 `LaunchScreen.storyboard`、认证状态机、3D 渲染器启动过程、最短/最长展示时间和生产 iPhone 均不在变更范围内。

## 已确认的视觉与行为

- 背景：纯黑 `#000000`，覆盖安全区和系统栏所在区域。
- 前景：纯白粒子；不使用图片、视频、GIF、Lottie、模糊滤镜或预渲染帧。
- 动效：`solving` 状态，实时计算粒子三维位置、深度、尺寸和亮度，并用 Flutter `Canvas` 每帧绘制。
- 尺寸：`128 × 128` 逻辑像素。Retina 3× 屏幕由 Flutter 以约 `384 × 384` 物理像素栅格化，不存在放大位图造成的清晰度损失。
- 速度：固定为 `0.8`。
- 位置：粒子球的中心与可用屏幕矩形的几何中心重合；不因状态栏、安全区或底部 Home Indicator 上下偏移。
- 页面内容：删除视觉上的 Logo、品牌名、副标题、进度条和状态文字。`progressMessage` 参数暂时保留在 `AetherSplashOverlay` API 中，避免修改当前有未提交改动的 `lib/main.dart`，但不再渲染。
- 退出：沿用当前 `420ms` 淡出；淡出完成后返回空组件并停止所有粒子动画更新。
- 无障碍：当 `MediaQuery.disableAnimations` 为真时绘制 `solving` 的静态代表帧；为粒子球提供加载语义标签，但不重新显示可见文案。
- 系统外观：加载页可见时使用适合黑底的浅色系统图标；加载页消失后不继续覆盖底层页面的系统栏样式。

## 接入方案比较

### 方案 A：裁剪并内置纯 Flutter Canvas 渲染器（采用）

从 MIT 授权的 `flutter_thinking_orbs` `0.1.0`、仓库修订 `24115f7fe39da85a85b1eeb638dcfc7becaa7022` 中只移植 `solving` 所需的粒子数学和绘制代码，形成 PocketWorld 自有组件。

优点：无新增运行时依赖；跨 Flutter 平台；可直接接入现有淡出和停帧规则；只保留一个状态，维护面小。缺点：PocketWorld 需要自行维护这段经过裁剪的算法，并保留 MIT 版权与许可证声明。

### 方案 B：依赖 `flutter_thinking_orbs: 0.1.0`

优点：接入代码最少，并自动获得六种状态。缺点：包刚发布、使用量低；启动页只需要一个状态，却把整个公共 API 纳入产品依赖；上游升级可能引入不必要变化。因此不采用。

### 方案 C：SwiftUI / Metal 原生视图

优点：Apple 平台可使用原生 GPU 管线。缺点：需要 PlatformView 或纹理桥接、只覆盖 iOS、增加生命周期与合成成本，且这个效果用普通圆点 Canvas 已足够流畅。因此不采用。

## 组件边界

### `AetherSplashOverlay`

继续负责：`visible` 状态、`420ms` 整页淡出、隐藏后返回空组件、输入拦截和系统栏外观。它不再负责 Logo 旋转、呼吸、文案或进度条。

### `SplashSolvingOrb`

负责：单个 `solving` 粒子球的实时钟、暂停规则、减少动态效果、语义标签和 `CustomPaint`。公开参数仅保留 `size`、`speed`、`color` 和 `animate`；启动页固定传入 `128`、`0.8`、白色以及当前可见状态。

### 粒子绘制器

负责：确定性生成点集，根据时间计算 `solving` 的分段扭转/归位状态，进行正交投影、深度排序并绘制圆点。它不得拥有 Flutter 生命周期或独立 ticker，确保整颗球只有一个时钟。

## 数据流与生命周期

1. 现有认证/渲染器状态继续计算 `AetherSplashOverlay.visible`。
2. `visible == true` 时淡入/保持显示，粒子时钟运行。
3. `visible == false` 时只反向播放整页淡出；粒子可在淡出期间继续运行，保证退出连续。
4. 淡出完成后立即停止粒子时钟并将整个 overlay 替换为 `SizedBox.shrink()`。
5. 再次显示时，粒子时钟从稳定初相位重新启动，避免恢复到任意旧帧。
6. 减少动态效果开启时始终只画静态代表帧，不创建持续重绘路径。

## 第三方来源与许可证

- 来源：`https://github.com/iamEtornam/thinking-orbs`
- 修订：`24115f7fe39da85a85b1eeb638dcfc7becaa7022`
- 上游来源：`https://github.com/Jakubantalik/thinking-orbs`
- 许可证：MIT

实现时只追加必要声明到现有用户已修改的 `THIRD_PARTY_NOTICES`，不得覆盖或整理其中任何既有改动。移植文件头也保留来源、修订和 MIT 归属。

## 测试与验收

- Widget 测试确认黑色全屏背景、中心 `128 × 128` 粒子球、白色粒子配置和 `0.8` 速度。
- Widget 测试确认旧 Logo、品牌文案、进度条和进度状态文字不再出现。
- Widget 测试确认 overlay 完成淡出后不再挂载粒子 `CustomPaint`，且不存在持续 ticker。
- Widget 测试确认 `disableAnimations` 下连续 pump 不改变绘制相位。
- Painter 单元测试确认同一时间输入结果确定、不同时间输入产生不同粒子位置，并且所有绘制点保持在组件边界内。
- 运行目标测试、`flutter analyze` 的相关文件检查，并在本地 Flutter 测试环境渲染截图验证居中和系统栏对比度。
- 不运行 `flutter drive`，不安装、覆盖或启动生产包 `com.kyle.PocketWorld`。

## 非目标

- 不修改社交主页骨架屏。
- 不改变启动时长、认证分流、纹理加载或错误处理。
- 不保留六种 orb 状态选择器。
- 不引入第三方 Flutter 包、Swift Package、Metal shader、图片或视频资源。
- 不执行任何真机部署。
