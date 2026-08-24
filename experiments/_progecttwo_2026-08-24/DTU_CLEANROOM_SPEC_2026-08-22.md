# DTU clean-room 功能仿造 —— 冻结规格 v1(2026-08-22)

**用户拍板:两条并行 —— BlendedMVG 重训(08-23 ~15:00 出)+ 本线复刻 DTU。**
既然不知道 DTU 的哪个成分在起作用("无纹理区 GT 准"已被 gt_provenance 实验削弱,0.99×),
**策略 = 把 DTU 的全部功能成分都忠实复刻**:相机几何、尺度、7 光照、逐像素精确 GT。

## 0. 法律边界(红线)

- **不复制** DTU 的任何文件:图像、深度、掩码、**相机矩阵文件**(机位数值也视为数据集的一部分,自建)
- 资产只用**明确可商用**的:Poly Haven / ambientCG(**CC0,商用免署名** —— WebSearch 结论,
  🔴 **下载前逐字读各站 LICENSE 页**,DTU 那次的教训)
- 官方 diffmvs 代码 Apache-2.0,可用
- 不混入自己的采集素材(用户拍板)

## 1. 数据契约(逐行读 `datasets/dtu.py` 得出,生成器必须逐字满足)

```
<root>/
  Cameras/pair.txt                    # 🔴 全局一份,所有场景共用(DTU 是固定机械臂机位)
                                      # 格式:首行机位数;每 ref 两行:id / "10 src1 s1 src2 s2 ..."
  Cameras/train/{vid:08d}_cam.txt     # 🔴 全局共享;第1-4行 extrinsic 4×4,第7-9行 intrinsic 3×3
                                      # 第11行 "depth_min depth_interval"
                                      # 🔴🔴 intrinsic 写在 **1/4 分辨率(160×128)坐标系**
                                      #     (dtu.py:180 注释原话)。写成 640×512 的会静默全错
  Rectified/{scan}_train/rect_{vid+1:03d}_{light}_r5000.png
                                      # 🔴 640×512 RGB(已预降采样;loader 直读不再缩)
                                      # vid 从 1 起;light 0..6 共 7 档
  Depths_raw/{scan}/depth_map_{vid:04d}.pfm      # 1600×1200 高分深度(loader 半采+中心裁到 640×512)
  Depths_raw/{scan}/depth_visual_{vid:04d}.png   # 1600×1200 掩码,像素值 >10 = 有效
```

- 🔴🔴 **第四个坑(smoke 实测抓到的)**:640×512 **不是** 1600×1200 的等比缩放 ——
  loader 是**半采(→800×600)+ 中心裁(→640×512)**,裁剪会平移主点。
  正确内参链:物理相机 K_HR(1600×1200)→ K_crop = K_HR×0.5 且 cx−=80, cy−=44 → 写盘 = K_crop/4。
  Rectified 图必须按 K_crop 的几何渲染(或渲 1600×1200 后同样半采+裁)。
  第一版按等比缩放写,解析平面测试偏 **81mm**;修正后 0.324mm。
- 深度单位 **mm**;`depth_max ≈ 935`(dtu.py:66 注释);384 档在 **视差空间均匀采样**(1/d 线性)
- 训练取样:ref + 从 top-10 源视图**随机抽 4**(nviews=5);7 档光照全部进训练;val 固定 light 3
- interval_scale = 1.06/(ndepths/192) 由 loader 处理,生成器只写原始 depth_interval

## 2. 机位设计(自建,不抄 DTU 数值)

- 49 个机位,布在**面向桌面场景的球面扇区**上,半径与 DTU 同量级(物距 ~500–900mm,
  与 depth_max≈935mm 自洽);朝向共同注视点
- pair.txt 的源视图分数:在 GT 深度上直接算共视度(合成数据有真值,不需要稀疏点近似)
  ⚠️ 打分公式抄 `colmap_input.py` 的官方形式(theta0=5 —— **它对 DTU 型机位是对的**,
  theta0 实验已证);只是共视点换成 GT 采样点
- 机位表生成脚本要带 seed,可复现

## 3. 场景与光照

- **78 个训练场景 + 17 val**(= 官方 lists/dtu/{train,val}.txt 的数量;场景名沿用 scanNN 命名
  以免改 loader —— 内容当然是我们自己的)
- 场景 = 桌面尺度物件组合(Poly Haven 模型)+ 多样材质(ambientCG PBR)
  🔴 必须包含足量**无纹理/低纹理表面**(纯色墙板、白布、哑光箱体)—— 这是我们做这件事的原因
- 7 档光照:HDRI 强度/方向组合,模拟 DTU 的受控光照阶梯(具体 7 档参数进生成脚本冻结)
- 渲染:Blender Cycles;RGB 640×512(直接渲这个分辨率)、深度 1600×1200 PFM(Z pass)、
  掩码 = 有效深度且在视锥内

## 4. 训练配方(逐字 = 官方第①段,唯一变量是 trainpath)

```
--dataset=dtu --batch_size=4 --epochs=16 --lr=0.001 --lr_sche onecycle
--trainviews=5 --testviews=5 --numdepth=384 --numdepth_initial=48
--stage_iters 1 3 3 --cost_dim_stage 4 4 4 --CostNum 0 4 4
--min_radius 0.125 --max_radius 8 --scale 0 0.5 0.1 --conf_weight 0.05
--hidden_dim 0 32 20 --context_dim 32 32 16 --unet_dim 0 16 8
```
之后接官方第②③段(BlendedMVG 版配方已在跑,`--loadckpt` 接本段产物)。
⚠️ `--scale 0 0.5 0.1` 的 0.5 噪声档**只在本段用** —— 段① 实验证明它搬到真实房间有害,
但它正是为 DTU 型转台数据设计的,在这里是官方口径。

## 5. smoke 与停止条件

1. **格式 smoke —— ✅ 已通过(08-22)**:`tools/gen_fake_dtu.py` 生成 2 个解析平面假场景,
   `dtu.py` 全量 686 metas 可读;**真判据 = 反投影世界点落在解析平面上**(0.324mm < 2mm)。
   ⚠️ 同 K/E 来回投影的"闭环测试"数学上恒等,是假测试 —— 第一版就是被它放过了 81mm 的错。
2. **渲染 smoke**:2 个真场景 × 49 机位 × 7 光照,人眼看 RGB/深度/掩码对齐
3. **训练 smoke**:2 场景跑 1 轮,loss 下降、无 NaN
4. 全量:78 场景渲染(预算另算)→ 16 轮段① → 接段②③
- **停止条件**:任一 smoke 不过且修不动 ⇒ 停下汇报,不硬推
- **执行 gate**:08-23 主线判决若鬼墙已治好 ⇒ 本线**取消**(用户可随时叫停)

## 6. 验收门(用户原话,与主线共用)

> **"正确的墙在正确位置 + 不再多出第二面墙粘旅行箱"**

判据 = 用户肉眼 + `cloud_vs_ref.py`,在 b28 上,同一份 θ₀=5 的 pair.txt。
⚠️ 点数/覆盖/局部粗糙度对鬼层失明,不得作为判据。

## 7. 未决(冻结前需要补的)

- [ ] Poly Haven / ambientCG LICENSE 逐字核验(含"3D 扫描模型是否另有条款")
- [ ] 7 档光照的具体参数表
- [ ] 78 个场景的资产清单 + 逐资产许可记录(manifest)
- [ ] 渲染算力预算(Blender Cycles 78×49×7 ≈ 26,754 张,在哪台机器渲)
