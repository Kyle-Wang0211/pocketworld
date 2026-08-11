# PocketWorld iOS 装机全流程 Runbook（给所有 agent）

> 最后校订：2026-08-10。本流程在 08-08~08-10 的七次真实装机中打磨而成，
> 每条"坑"都是真踩过的。偏离本流程出的事故自己负责。

## 铁律（先读，违反任何一条 = 停手上报）

1. **手机本地 app 及其数据是母版。只更新，不覆盖不删除。**
   - 永远用 `devicectl install`（同 bundle ID 同签名 = 原地升级，Documents 保留）
   - **绝对禁止 `devicectl uninstall`** ——那会删掉手机上所有采集数据
2. **先查 df 再干活**（备份合同）：磁盘满会让备份"rc=0 但只拉了一半"、
   让构建 `errno=28` 失败。低于 6 GB 先清理。
3. **共享脏工作树**：仓库里常年有他人未提交改动。只碰自己的文件；
   提交时 `git add -p` 只挑自己的 hunk；绝不 `git add -A`/`reset`/`checkout`。
4. **装机前留身份指纹**（装机合同）：HEAD + 未提交 diff 的 SHA + 脏文件数。

## 固定事实

| 项 | 值 |
|---|---|
| 设备 | Kyle's iPhone（iPhone15,2 / A16），UDID `00008120-00146C4A1AEBC01E` |
| bundle ID | `com.kyle.PocketWorld` |
| 签名团队 | `26AH7V448L`（自动签名） |
| 构建产物 | `build/ios/iphoneos/Runner.app` |
| 仓库 | `/Users/kaidongwang/Developer/pocketworld` |

## 流程

### 第 0 步：环境检查

```bash
df -h /Users/kaidongwang | tail -1          # ≥6GB 才继续
xcrun devicectl list devices | grep iPhone   # 设备在线且 paired
```

### 第 1 步：数据备份与逐目录对账（动大改动/首次装机时必做；小迭代可复用近期备份）

```bash
# 拉 Documents(3.6GB 级,注意磁盘)
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld \
  --source Documents --destination <备份目录>
```

**对账口径（血泪教训）**：照片在手机上是 `.jpg.lep`（Lepton 归档，原 JPEG
已删按需物化），**数 `*.jpg` 会数出 0**。正确对账：

- 每个 capture：`official_photo_bundle.json` 的 frames 数 == `photos_highres/*.lep` 数
  == `official_photo_archive.json` 的条目数，三方一致才算备份完整。

### 第 2 步：装机身份指纹

```bash
cd /Users/kaidongwang/Developer/pocketworld
git rev-parse HEAD                      # 记录
git diff | shasum -a 256                # 记录(未提交改动的指纹)
git status --porcelain | wc -l          # 记录脏文件数
```

写入 `experiments/hevc_capture_ladder/results/install-record-<日期>.json`
（含目的、构建 flag、设备）。

### 第 3 步：构建

```bash
cd /Users/kaidongwang/Developer/pocketworld
flutter build ios --release
```

**已知坑（全部真踩过）**：

- **`--dart-define` 在本工程 xcconfig 链上不生效**（2026-08-09 真机证实）。
  测量/开关类 flag 必须直接改源码硬编码（如 `CaptureArchiveService.abPeriod`），
  并写清注释和回退值。
- **不许并发跑两个 flutter build**——会 "Xcode build failed due to concurrent
  builds"（有时自动重试成功，有时直接失败）。
- **不许用 `flutter build ... | tail && install` 这种链**——管道会吞掉构建的
  退出码，构建失败也会继续把**旧包**装上去（2026-08-10 真实事故）。构建和
  安装分开跑，中间必须校验。
- 磁盘满 → `Write() failed, errno=28`。回第 0 步。
- pod install 有 Ruby4 静默失败前科（本机 ruby 2.6 安全；若换环境撞雷，
  按 CocoaPods 锁 2.5.1 的既有配方处理）。

### 第 4 步：构建校验（装机前必做）

```bash
ls -la build/ios/iphoneos/Runner.app/Runner   # 时间戳必须是刚才!
plutil -p build/ios/iphoneos/Runner.app/Info.plist | grep BundleIdentifier
# 若本次改动涉及删代码,做符号级验证,例:
strings build/ios/iphoneos/Runner.app/Runner | grep -c "<被删符号>"  # 应为 0
```

**时间戳是旧的 = 构建没成功，禁止安装。**

### 第 5 步：安装（原地升级）

```bash
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
```

手机需解锁状态更顺；锁屏会导致后续 launch 失败（install 本身通常可以）。

### 第 6 步：装机后核验（三连）

```bash
# 1) app 在册
xcrun devicectl device info apps --device <UDID> | grep PocketWorld
# 2) 数据完整:归档状态可读、历史采集在册
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.kyle.PocketWorld \
  --source Documents/official_archive_status.json --destination /tmp/chk.json
# 3) 抽查一个旧采集的文件可读取
```

三项任一失败 → 停手上报，不要重试 install，更不要 uninstall。

### 第 7 步：拉数据的通用姿势（装机后测试用）

- 单文件: `devicectl device copy from ... --source Documents/<路径>`
- 找采集: 先拉 `Documents/scan_records.json`，按 name/createdAt 映射 capture_id
- 遥测: `Documents/telemetry_official_dart.jsonl`（frame 事件含
  proc_ms/extract_ms/match_ms/queue/thermal，全局文件按时间窗过滤）
- 效率门分析: `python3 tool/ab_analyze.py <拉回目录> <capture_id...>`

## 当前构建状态备忘（2026-08-10 09:15 起）

- `CaptureArchiveService.abPeriod = 16` **硬编码测量模式**——效率门 PASS 后
  必须改回 0 再出生产构建
- 亮度调速器已删（用户签决 2026-08-10）：拍摄期屏幕恒定用户亮度
- 编码器 `MaximizePowerEfficiency = true`（热余量归因后的修复,勿删）
- iOS 内禁止一切 `Process.run/start`（无子进程,曾炸 finalize）
