# 选区功能设计(RS Reconstruction Region 复刻)— 2026-07-27

> 状态:用户已批准(2026-07-27 会话内逐节签决)。
> 范围:采集完成后的稀疏点云选区 UI + 持久化。**不含**稠密化处理(CasDiffMVS
> 接入是未来阶段,本设计只为它预留边界输入)。

## 背景与需求(逐条签决过的语义)

复刻 RealityScan Mobile 的 Review Scan → Reconstruction Region 流程。
联网核实过的 RS 真实语义:选区框约束**下游重建**("everything outside the
reconstruction region will not be used in the reconstruction and will not be
in the final model"),但**稀疏点云本身不被删**(桌面版可"移除 region 重建
整个场景")。

用户签决的五条:

1. **等待页 refined 后**:底部"完成"换成 **保存草稿 | 下一步** 两按钮
   (RS 同款)。`error` 阶段保持只有"完成"。选区入口**只在 refined 后**
   (不做 localReady 期间的即时选区;`SfmLivePreview` 事件留作未来加速用)。
2. **下一步 → 选区页**:朝向立方体切视角、旋转滑杆、3D 包围盒手柄框选、
   **框外点实时变红**。
3. **PLY 永不裁、点云永远全量**。框是给未来稠密化划边界的元数据。
   完全不触碰"点云全量交付"铁律。
4. **框持久化**:重新打开草稿"查看点云",看到上次的框 + 框外红点
   (整体点云完整)。
5. **Ready to Process**:占位按钮,点击弹轻提示"稠密化处理即将上线"
   (不做真处理)。未来接 CasDiffMVS 时,框就是它的边界输入。

导航签决(推翻了 RS 的逐级后退):**选区页左上返回 = 兜底 flush 选区框 →
走"保存草稿"完全同一的退出链路 → 直接草稿列表**。不提供回等待页的路径
(选区页本身渲染全量点云 + 六面预设视角 + 双指缩放,"再看看点云"的需求
在选区页全覆盖,回等待页没有增量价值)。

## 架构

### 1. 共享投影核心 — `lib/ui/official_capture/cloud_camera.dart`(新)

消除 SparseCloudView 与选区渲染器之间的投影公式重复(用户点名要求):

- **`CloudCamera`**(值类):`yaw / pitch / zoom / panX / panY / pivot(x,y,z)
  / radius`,即现有 `SparseCloudPainter` 的全部相机参数。
- **`CloudProjection`** = `CloudCamera.projectionFor(Size)` 派生,持有预算
  标量 `cosY / sinY / cosP / sinP / f / camDist / ox / oy`,并提供:
  - `project(wx, wy, wz) → (sx, sy, depth)` —— **权威公式**
    (yaw 绕 Y → pitch 绕 X → 透视除法,与现有 painter 逐位同式);
  - `worldPerPixelAt(depth)` 与视平面世界基向量 —— 手柄拖拽的屏幕→世界
    逆映射。

**性能约束**:两个 painter 的逐点热循环(数万点)**不逐点调函数**,仍用
标量展开,但八个标量一律从 `CloudProjection` 取。公式唯一所有权归
`project()`;一致性由 parity 单测锁死(随机相机+随机点,循环展开结果 ==
`project()` 输出,容差 1e-9)。

### 2. 数据模型 — `lib/official_capture/selection_box.dart`(新)

```
SelectionBox { cx, cy, cz,  sx, sy, sz,  yawDeg }
```

- 语义:重力系(点云已 `_gravityAlign`,世界 Y=重力上)轴对齐盒 + 绕竖直
  轴旋转 `yawDeg`。
- 持久化:`<captureDir>/official_selection_box.json`(与 PLY 同目录)。
  改动即写(500ms debounce),掉进程不丢;离开页面兜底 flush。
- `contains(wx, wy, wz)`:点变换到盒局部系(减 center、逆转 yaw),逐轴
  比半尺寸。纯函数,单测直接锁。
- 初始值:点云 99.5 百分位包围盒(与现有 fit 同口径),`yawDeg = 0`。
- **PLY 永不改写**。

### 3. 页面与流向

**等待页 `SfmPreviewOverlay`(改)**:

- `refined`:底部 = `保存草稿`(原 `onDone` 语义)+ `下一步`
  (push `SelectionPage`,capture route 仍在栈里,worker/快照保活不变)。
- `error`:保持单个"完成"。

**选区页 `selection_page.dart` + `selection_cloud_view.dart`(新)**:

- 左上返回:flush 框 → 触发与"保存草稿"同一退出链路 → 草稿列表。
- 右上朝向立方体:Top / Front / Left / Right / Back / Bottom + 上下箭头,
  相机 lerp 到预设 `yaw/pitch`(重力对齐 ⇒ 预设确定性成立)。
- 中央:全量点云 + 盒线框 + 8 角球手柄 + 4 边条手柄;**框外点实时变红**
  (painter 逐点 `contains` 调制色;框外点不消失)。
- 手势:单指落在手柄 → 拖对应面/角改盒尺寸(屏幕 delta ×
  `worldPerPixelAt` 映射世界轴);单指落空白 → 平移盒中心;双指捏合 →
  视图缩放。无自由单指旋转(视角只走预设立方体)。
- 底部:`Rotate Point Cloud` 刻度滑杆 = 改 `yawDeg`(转盒对齐点云,视觉
  等效转点云,不动数据);`Ready to Process` 大按钮 = 轻提示占位。

**草稿查看器回显(改)**:

- `SparseCloudView` 加**只读**参数 `selectionBox`:画框线 + 框外红,不可
  编辑,渲染层行为,不影响数据/导出。
- `sparse_cloud_viewer_page` 加载 `official_selection_box.json` 传入。
- 注:等待页不需要回显 —— 选区页返回直接退草稿列表,等待页在框存在之后
  不再显示(自审时从设计里删去了不可达的"等待页回显")。

### 4. 错误处理

- JSON 损坏/缺失 → 视为无选区,全量正常显示(容错;选区文件坏不许拖垮
  查看器)。
- 盒退化 → 手柄 clamp 最小尺寸(fit 半径的 2%)。
- 写 JSON 失败 → 静默记设备日志,不打断交互(下次改动重试)。

### 5. 测试

1. `SelectionBox` JSON round-trip(含损坏输入→null)。
2. `contains` 判定矩阵(轴对齐 + 非零 yaw + 边界点)。
3. 投影 parity:painter 标量展开 == `CloudProjection.project()`。
4. 预设视角角度表(六面 yaw/pitch 值)。
5. widget:refined 双按钮 / error 无"下一步" / 下一步 push 选区页 /
   返回走保存草稿链路。
6. `SparseCloudView` 带只读框渲染不崩;框外红只影响调制色不影响点数。

## 明确不做(YAGNI)

- localReady 期间的即时选区(架构预留的 `SfmLivePreview` 不在本期接线)。
- 从草稿重进选区编辑(本期查看器只读回显;要编辑等稠密化一起设计)。
- 盒的 pitch/roll(RS 也只有绕竖直轴旋转)。
- Ready to Process 的真实处理链。
