# PocketWorld “为什么是我们”过渡页 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Figma 文件中用一张可追溯、可回退的三栏竞争目标地图替换旧过渡页，逐条回答教授批注。

**Architecture:** 先只读勘察目标节点、样式和设计系统，再在空白区建立 2000 × 750 wrapper。按标题、三栏、底部指标带四个独立分区增量构建和截图验证，最终原位替换并隐藏旧内容。

**Tech Stack:** Figma Design、Figma Plugin API、Inter、`use_figma`、`get_metadata`、`get_screenshot`。

---

### Task 1: 冻结目标范围与设计系统

**Files:**
- Read: Figma file `sWpC4OJrJWT91O0YzoheOi`, page `0:1`
- Read: `557:23`, `557:42`, `620:94`, `675:7`, `695:15`, `695:18`, `695:23`

- [ ] 检查本地 Code Connect 文件；若不存在记录 N/A。
- [ ] 用只读 `use_figma` 检查目标附近节点、实例、变量、样式和可用 Inter 字重。
- [ ] 将目标背景、旧文案、截图层与批注节点分成明确白名单，禁止页面范围模糊删除。
- [ ] 验证目标旧画板坐标为 `(6591, 7781)`、尺寸为 `2000 × 750`。

### Task 2: 创建可回退 wrapper 与分区骨架

**Files:**
- Create: Figma frame `PocketWorld / Why Us / Evidence Transition v2`

- [ ] 在页面最右侧空白区创建 2000 × 750 wrapper，并返回其 ID。
- [ ] 创建标题区、三栏内容区、底部指标区四个 auto-layout 子容器，全部使用 placeholder 状态。
- [ ] 截图验证尺寸、背景和基础栅格，不移动旧画板。

### Task 3: 写入标题与重建/生成对比

**Files:**
- Modify: wrapper 标题区与左栏

- [ ] 写入标题“为什么是 PocketWorld，而不是大公司的一个 3D 功能？”与研究口径。
- [ ] 写入重建/生成的输入、目标、评价和用户价值四维对比。
- [ ] 写入“真实记录 ≠ 合理生成；两者互补”的结论与两条学术来源。
- [ ] 截图左栏，检查字体、行高、对齐和来源可读性。

### Task 4: 写入公司目标函数地图

**Files:**
- Modify: wrapper 中栏

- [ ] 写入 Alibaba / SKU 与交易、ByteDance / 视频与特效、Niantic / 地点与地图、Polycam / 捕捉工具与专业工作流。
- [ ] 对 DA3 与抖音的关系标记为“战略推断”，不写成部署事实。
- [ ] 将 Polycam 标为直接竞争者，避免“唯一平台”式表述。
- [ ] 截图中栏并检查公司行高、语义色和证据标签。

### Task 5: 写入“为什么是我们”与商业指标

**Files:**
- Modify: wrapper 右栏与底部指标区

- [ ] 写入四条理由：第一对象、不同目标、第一方执行证据、用户距离与迭代速度。
- [ ] 写入诚实边界：小团队不是护城河，数据关系和用户信任才可能形成防御性。
- [ ] 写入收藏者、二手商家、独立创作者的量化指标。
- [ ] 写入速度/精度、本地/计算、Splat/Mesh、简单/专业四组取舍。
- [ ] 截图右栏和底部，检查完整覆盖教授批注。

### Task 6: 原位替换与最终验证

**Files:**
- Modify: wrapper 坐标、旧过渡页节点可见性

- [ ] 对 wrapper 做整板截图，修复所有裁切、重叠和视觉层级问题。
- [ ] 读取全部 TEXT 节点并断言字体为 Inter；检查没有占位文字。
- [ ] 将 wrapper 移到 `(6591, 7781)` 并置顶。
- [ ] 仅隐藏白名单中的旧过渡页内容，保留教授批注和可回退节点。
- [ ] 用元数据断言 wrapper 为 `2000 × 750` 且旧内容不可见。
- [ ] 获取最终整板截图作为交付证据。
