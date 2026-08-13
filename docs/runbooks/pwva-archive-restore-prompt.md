# PocketWorld 归档还原说明（给另一个 agent 的提示词）

> 直接把本文件全文作为提示词交给对方。它是自包含的：路径、格式、步骤、验证、
> 以及会咬人的坑全部在内。最后校订 2026-08-13。

---

## 你的任务

把 PocketWorld 一个采集作品（capture）的归档还原成可用数据。归档分两条独立
的线：**照片**和**SfM 数据库**。两条线的"无损"含义不同，先读第 0 节。

## 0. 先搞清楚"无损"在这里指什么（否则你会得出错误结论）

| 对象 | 无损的含义 | 能否逐字节还原成"最初的样子" |
|---|---|---|
| **照片码流** `photos.hevc` | 逐字节保存**编码器写出的码流** | ❌ **不能**还原出原始 JPEG。原图在校验通过后已删除 |
| **SfM 数据库** `*.db.zpaq` | 逐字节保存**被归档的那个 db 文件** | ✅ 解压结果与归档时的 db **逐字节相同** |

⚠️ 但被归档的 db 是**裁剪过的**（见第 3 节）：`descriptors` 表已清空、
`keypoints` 只剩 x,y 两列、（若 v3）`matches` 表已清空。这些是"匹配期脚手架"，
按设计删除，**不是数据损坏**。

**不要**试图从码流重建原始 JPEG 字节，也不要以为解压 db 会得到含描述子的
原始库——那两件事都做不到，且已有实验定论（见第 6 节）。

## 1. 采集目录长什么样

设备路径：`Documents/captures_official/<capture_id>/`
（⚠️ 是 `captures_official`，不是 `captures`）

```
official_photo_bundle.json          策展清单:frames[].highresFilename = 权威帧名与顺序
photos_highres/
  <name>.json                       每帧 ARKit 侧车:t / extrinsic(16) / intrinsics_fxfycxcy / anchors
  <name>.jpg                        原图(已被主本接管的作品里**不存在**)
  <name>.jpg.lep                    Lepton 归档(旧作品才有)
photos_hevc/
  photos.hevc                       HEVC Annex-B 码流(照片主本)
  photos.pwvi                       逐帧索引(JSONL)
  manifest.json                     码流清单 + SHA-256
  master-manifest.json              **存在=照片主本已接管**(原图已删)
  archive-report.json               自检报告:status 必须是 finalized
official_sfm_live.db                原始 db(冷归档后会被删)
official_sfm_live.db.arkit_pose_v1  位姿侧车(ARKPOS1,身份链,勿动)
official_sfm_live.db.zpaq           ZPAQ 归档
official_database_archive.json      归档清单(源/归档 的 bytes+sha256, preprocess)
official_database_archive_policy.json
official_database_prune.json        **存在=db 被裁过**,记录裁掉了什么
official_sfm_sparse.ply             交付的稀疏点云(未压缩,直接可用)
official_sfm_sparse_meta.json       位姿 + 重力对齐 + 尺度
```

## 2. 还原照片

### 2.1 格式

`photos.hevc` 是**标准 HEVC Annex-B 码流**，无容器。关键参数：
- `AllowFrameReordering = false` ⇒ **解码顺序 == 显示顺序**，第 N 个访问单元
  就是第 N 张照片。不要为重排写缓冲。
- GOP = 8（每 8 帧一个关键帧），分辨率见 `manifest.json` 的 `resolution`。

`photos.pwvi` 每行一个 JSON：
```json
{"frame":0,"offset":0,"len":123456,"keyframe":true,"gop":0,
 "source":"official_tap-19.jpg","trigger":1786.5,
 "source_sha256":"<原始 JPEG 的 SHA-256>"}
```
`source` 是原始文件名，`source_sha256` 是**原图的哈希**（用于溯源对账，
**不能**用它反推原图内容）。

`master-manifest.json`（schema `pw_pwva_master_manifest_v1`）：
```json
{"stream_sha256":"...","frame_count":100,
 "entries":{"official_tap-19.jpg":{"frame":0,"source_bytes":3239021,
                                   "source_sha256":"..."}}}
```
**它存在就说明原图已被删除**，码流是唯一主本。

### 2.2 取出全部帧（离线，任何机器）

```bash
ffmpeg -i photos.hevc -start_number 0 out_%04d.png     # 顺序==显示顺序
```

### 2.3 取出**某一张**照片（随机访问）

按文件名 → `master-manifest.json` 拿 `frame` 索引 → 在 `photos.pwvi` 里**向前
找到最近的 `keyframe:true`** → 从该关键帧的 AU 起，按 `offset`/`len` 依次喂
解码器直到目标帧。最多解 8 帧。

仓库里已有实现：`packages/pw_hevc/lib/pwva.dart` 的 `PwvaReader.readFrameNv12(i)`
（Apple 平台用 `AppleHevcDecoder`）。

🔴 **坑**：`PwvaReader` 为**每次调用新建一个解码会话**（随机访问的设计）。
顺序遍历几十帧时会把解码器压垮（真机实测 `OSStatus=-12911`）。**顺序场景请
自己开一个解码会话读到底**，别循环调用它。

### 2.4 验证

```bash
shasum -a 256 photos.hevc     # 必须等于 manifest.json 的 stream_sha256
```
帧数与 `official_photo_bundle.json` 的 frames 数、`photos.pwvi` 行数三者必须一致。

## 3. 还原 SfM 数据库

### 3.1 解压（设备内，推荐）

用仓库里的 `DatabaseArchiveResolver.resolveDatabase(captureDir)`：
它会读 policy + `official_database_archive.json`，用 **ZPAQ 7.15 method 5**
（版本与二进制 revision 都被 policy 钉死）解压，若 `preprocess == track_delta_v1`
再做一次可逆逆变换，然后**校验长度 + SHA-256 与清单一致**，通过才把结果落成
`official_sfm_live.db`。任何一步不过 → 返回 null 并清理临时文件（fail closed）。

### 3.2 离线解压（Mac/其他）

ZPAQ 格式自描述，标准 `zpaq` CLI 可以解开：
```bash
zpaq x official_sfm_live.db.zpaq
shasum -a 256 official_sfm_live.db   # 必须等于清单的 source_sha256
```
⚠️ 若清单里 `preprocess` 是 `track_delta_v1`，解出来的还要做逆变换才是真 db
（该变换是本仓库私有的，见 `ios/Runner/pw_sqlite_descriptor_transform.cpp`）。
`raw_v1` 则解出来就是 db 本体。**裁剪过的作品一律是 `raw_v1`**（裁剪后
track_delta 已无标的，会被跳过）。

### 3.3 解出来的 db 里有什么、没什么

看 `official_database_prune.json`（schema `pw_database_prune_v3`）：
```json
{"original_db_bytes":128800000,"original_db_sha256":"...",
 "pruned_db_bytes":10900000,
 "preserved_table_sha256":{"cameras":"...","images":"...",
                           "two_view_geometries":"..."},
 "keypoints_xy_sha256":"...",
 "deleted":"descriptors + keypoints 仿射列 [+ matches]",
 "drop_raw_matches":false}
```

| 表 | 状态 |
|---|---|
| `cameras` / `images` / `two_view_geometries` | **逐字节保全**（清单里有 SHA 可核） |
| `keypoints` | 保留 x,y（`cols=2`），仿射列 a11/a12/a21/a22 已裁 |
| `matches` | v3 且 `drop_raw_matches=true` 时为空；否则保全 |
| `descriptors` | **空表** |

**重建照常可用**：COLMAP 的 `DatabaseCache::Load` 只读 `two_view_geometries`
和 keypoints 的 x,y，不读描述子、不读原始 matches。

### 3.4 用它重建点云

产品路径：`SfmLiveRecon.start(dbPath: <db>)` → `resumeFromDb(imageWidth:4032,
imageHeight:3024)` → 等 `SfmLiveRefined` 事件 → `persistSparseSnapshot` 落 PLY。

🔴 **身份链**：核在 resume 时会用 `FrameIdentityDigestV1(帧名, 相机, 关键点
x,y, 描述子)` 与 `official_sfm_live.db.arkit_pose_v1` 侧车里的指纹比对，不符
直接拒绝重建（`ERR_NOT_REGISTERED`, rc=5）。
- 侧车与 db **必须成对**，复制时别落下；
- **你若改动了 db（哪怕合法裁剪），必须重新盖章**：
  `pw_sqlite_reseal_arkit_pose_digests(dbPath, sidecarPath)`。

## 4. 侧车与点云

- `photos_highres/<name>.json`：每帧 ARKit 元数据（`t`、`extrinsic` 16 个
  double 的相机→世界矩阵、`intrinsics_fxfycxcy`、anchors）。**从未被压缩或
  删除**，直接可读。喂帧重建所需的全部输入都在这里。
- `official_sfm_sparse.ply`：交付的点云，binary_little_endian，每点
  `float x,y,z + uchar r,g,b`（15 字节）。未压缩，直接可用。

## 5. 会咬人的坑（都是真踩过的）

1. **SQLite WAL 冷库只读打不开**：采集后的 db 是 WAL 模式且常年没有 `-shm`
   伴生文件，只读连接无权创建它 ⇒ `prepare` 阶段失败。**用读写方式打开**，
   或先复制一份再打开。
2. **别把 `-wal`/`-shm` 留在 db 旁**：既有 ZPAQ 归档事务看到伴生文件会判
   "db 还热着"而**永久跳过**这个作品。用完清掉（`-wal` 为 0 字节时才安全删）。
3. **iOS 内禁止任何子进程**（`Process.run` 曾炸掉 finalize）。哈希、解压全部
   走进程内实现。
4. **锁屏会挂起冷任务**：审计里看到 `capture_started` 之后没有
   `capture_completed`，通常是被 iOS 挂起，不是卡死。
5. **审计文件 `official_archive_status.json` 每个 capture 只保留最后一条事件**，
   新一轮的 `capture_started` 会覆盖上一轮的完成详情——别读成回退。历史看
   追加日志 `official_archive_audit.jsonl`。
6. **不要用 `devicectl list devices` 的状态判断可达性**：它会显示
   `unavailable` 但实际能用，也会显示 `connected` 但数据服务连不上。**以真实
   拉一个文件成功为准**。

## 6. 已有定论，别重复劳动（负结果都在 `experiments/hevc_capture_ladder/results/`）

- `b1-regen-ceiling-PROVEN.json`：从压缩帧**重新提特征+重新匹配**来再生描述子/
  匹配图 —— 穷举匹配（K=96）后轨迹长度仍比原版低 24%，是 q65 量化的信息物理
  损失，任何匹配预算都补不回来。所以匹配图必须原样保留，只删描述子。
- `gop-reorder-sweep-DEAD.json`：GOP 8→32 只有 −2.2%，B 帧重排 +0.5%。
- `encode-order-sweep-DEAD.json`：按相机位姿相似度重排编码顺序只有 −0.1%
  （此前观察到的 −26% 是测试素材混分辨率造成的假象）。
- `power-efficiency-probe-DEAD.json`：A16 上 `MaximizePowerEfficiency` 开/关
  输出**逐字节相同**。

## 7. 一句话总结

**照片**：`photos.hevc` 是标准 HEVC，顺序即显示序，`ffmpeg` 直接解；随机访问
靠 `photos.pwvi` 回退到最近关键帧。**原图已删且不可字节还原**。

**数据库**：`.zpaq` 解压后**逐字节等于归档时的 db**；那个 db 是裁剪过的
（无描述子、关键点只剩 x,y），但**重建功能完整**——改动它必须重新盖章侧车。
