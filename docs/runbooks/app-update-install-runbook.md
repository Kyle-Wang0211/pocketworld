# PocketWorld iOS 装机全流程 Runbook（给所有 agent）

> 最后校订：2026-08-11。本流程在 08-08~08-11 的十余次真实装机中打磨而成，
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
5. **紧贴 install 前查用户是否在拍摄/重建**（08-10 真事故：先查后构建，
   构建那 10 分钟里用户开拍，install 打断了第 75 张）。顺序必须是
   构建 → 校验 → **查遥测** → 秒级内 install。
6. 🔴 **装机 ≠ 生效**（08-11 双事故）。"装机成功 + 测试全绿 + 三连核验过"
   只证明代码在机器上，**不证明功能在生产路径上真的跑了**。中间还隔着
   触发条件、守卫、阈值、iOS 挂起、别人写的前置闸。必须用**设备上的产物**
   （manifest / 审计 / 文件体积）回答"它真的跑了吗、产出物在哪、数字是多少"，
   拿不到就不许说"已上生产"。详见第 8 步。

## 固定事实

| 项 | 值 |
|---|---|
| 设备 | Kyle's iPhone（iPhone15,2 / A16），UDID `00008120-00146C4A1AEBC01E` |
| bundle ID | `com.kyle.PocketWorld` |
| 签名团队 | `26AH7V448L`（自动签名） |
| 构建产物 | `build/ios/iphoneos/Runner.app` |
| 仓库 | `/Users/kaidongwang/Developer/pocketworld` |
| 设备采集根目录 | `Documents/captures_official/<capture_id>/`（⚠️不是 `captures/`） |

## 流程

### 第 0 步：环境检查

```bash
df -h /Users/kaidongwang | tail -1          # ≥6GB 才继续
xcrun devicectl list devices | grep iPhone   # 设备在线且 paired
```

### 第 1 步：数据备份与逐目录对账（动大改动/首次装机时必做；小迭代可复用近期备份）

```bash
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
（含目的、构建 flag、设备、本次要验证的生效判据）。

### 第 3 步：构建

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --release
```

**已知坑（全部真踩过）**：

- 🔴 **pod install 撞 Homebrew Ruby 4.0.3 会静默失败**（08-10 实证，
  本机 `/opt/homebrew/bin/pod` 走的就是它；`/usr/bin/ruby` 是 2.6 但没人用它）。
  症状极隐蔽：`flutter build` 内部的 pod install 失败被吞，**用旧 Pods 工程
  构建"看起来成功"**；改已有源文件照常重编，但**新增的源文件/改过的 podspec
  永远不进工程**。修法：给 `flutter build ios` 和手动 `pod install` 都带上
  `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。
- **改了 podspec（含 `-Wl,-u` 守卫）后必须手动跑一次 pod install 再构建**，
  并用 `grep` 确认新守卫真进了
  `ios/Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig`。
- **`--dart-define` 在本工程 xcconfig 链上不生效**（2026-08-09 真机证实）。
  测量/开关类 flag 必须直接改源码硬编码，并写清注释和回退值。
- **不许并发跑两个 flutter build**——会 "Xcode build failed due to concurrent builds"。
- **不许用 `flutter build ... | tail && install` 这种链**——管道会吞掉构建的
  退出码，构建失败也会继续把**旧包**装上去（2026-08-10 真实事故）。构建和
  安装分开跑，中间必须校验。
- 磁盘满 → `Write() failed, errno=28`。回第 0 步。

### 第 4 步：构建校验（装机前必做）

```bash
ls -la build/ios/iphoneos/Runner.app/Runner   # 时间戳必须是刚才!
plutil -p build/ios/iphoneos/Runner.app/Info.plist | grep BundleIdentifier
# 本次新增 native 函数 → 每个都要在二进制里查到(应为 1):
nm build/ios/iphoneos/Runner.app/Runner | grep -c "<新增符号>"
# 本次删了代码 → 被删符号应为 0:
strings build/ios/iphoneos/Runner.app/Runner | grep -c "<被删符号>"
```

**时间戳是旧的 = 构建没成功，禁止安装。**
**新增符号查不到 = 要么 pod 没跑（见 Ruby4 坑），要么被 `-dead_strip` 剥了
（Release 会剥掉只经 `DynamicLibrary.process()`/dlsym 访问的符号，需
podspec 里加 `-Wl,-u,_符号名`）。两种都禁止安装。**
💡 把新函数追加进**已在 Runner target 里的既有 .cpp/.c**，可完全绕开
pbxproj 改动（B1 的 prune/reseal 就是这么落地的）。

### 第 5 步：安装（原地升级）

```bash
# 紧贴 install 前查用户是否在拍摄(铁律 5):看近 10 分钟遥测有无
# shutter / hires_still / frame 事件。有 → 等他拍完再装。
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
```

手机需解锁状态更顺；锁屏会导致后续 launch 失败（install 本身通常可以）。

### 第 6 步：装机后核验（四连）

```bash
# 1) app 在册
xcrun devicectl device info apps --device <UDID> | grep PocketWorld
# 2) 数据完整:归档状态可读
xcrun devicectl device copy from --device <UDID> ... \
  --source Documents/official_archive_status.json --destination /tmp/chk.json
# 3) 抽查一个旧采集的 official_photo_bundle.json 可读且 frames 数对
# 4) 生效验证 —— 见第 8 步,不做这一步不许宣称"已上生产"
```

前三项任一失败 → 停手上报，不要重试 install，更不要 uninstall。

### 第 7 步：拉数据的通用姿势

- 单文件: `devicectl device copy from ... --source Documents/<路径>`
- 找采集: 先拉 `Documents/scan_records.json`，按 `name`/`createdAt` 映射
  `captureDir` 的最后一段（⚠️用户会删作品，昨天的 capture_id 今天可能不在）
- 遥测: `Documents/telemetry_official_dart.jsonl`（字段是 `t`，毫秒时间戳）
- 效率门分析: `python3 tool/ab_analyze.py <拉回目录> <capture_id...>`

### 第 8 步：生效验证（08-11 起强制）

**为什么**：08-11 一晚上抓出两件"装机后从未生效"的事——PWVA 归档被自己的
阈值判死（每个作品都 failed）、DB 裁剪被既有冷库守卫永久跳过（顺带发现既有
ZPAQ 线也一直被同一条卡着）。两件都在"装机成功、测试全绿"之后。

**怎么做**：

1. 触发一次真实生产路径（多数冷任务在**启动**跑）：
   ```bash
   # ⚠️对已在运行的 app,launch 只把它切到前台,不重跑启动钩子!
   xcrun devicectl device process launch --terminate-existing --device <UDID> com.kyle.PocketWorld
   ```
2. 🔴 **让手机保持解锁亮屏**。iOS 会在锁屏后挂起 app，冷任务停在半路：
   审计里看到 `capture_started` 之后没有 `capture_completed`，**通常是被挂起
   而不是卡死**（08-11 实证：那一轮裁剪其实已经完成，只是完成事件没写下）。
3. 读设备产物做判据，而不是读日志措辞：
   - `Documents/official_archive_status.json` = **每个 capture 只保留最后一条
     事件**。新一轮的 `capture_started` 会覆盖上一轮 `capture_completed` 的
     details——**别把它读成回退**。要看历史用追加日志
     `Documents/official_archive_audit.jsonl`。
   - 产物类判据最硬：`official_database_prune.json`（裁剪前后体积）、
     `photos_hevc/archive-report.json`（status 必须是 `finalized`）、
     `photos_hevc/master-manifest.json`（照片主本是否接管）、文件体积本身。
4. 失败路径必须留原因：新增守卫/事务要把 skip reason 写进审计
   （08-11 前 `recipe.applicable=false` 无痕，排障只能靠猜）。

**文件触发的实验/验收钩子**（零 UI，开发侧专用）：投放
`Documents/pw_b1_gate_request.json` 之类的请求文件 → `--terminate-existing`
重启 → 轮询对应 report。⚠️这类钩子挂在首帧回调上（**锁屏不跑**），且验收
重建会持有 `reconstructionLease`（**跑的时候用户开拍会失败**）——只在设备
空闲且用户在场亮屏时投放。

## 当前构建状态备忘（2026-08-11 21:40 起）

- `DatabaseRecipeTransaction.enabled = true`（B1 无损形态：**裁描述子保匹配图**，
  用户 08-11 签决；依据 `results/b1-prune-device-gate-PASS.json`）。
  回退 = 改回 `false`，即刻停止新裁剪，已裁 capture 不受影响。
- 归档自检**已废弃锐度阈值**，改为逐帧源 JPEG 哈希复验 + 解码冒烟
  （阈值与实现不同源，曾让每个作品都判失败）。
- DB 冷库判定：只拒绝**非空 `-wal`** 与 `-journal`；0 字节 `-wal` + `-shm`
  按冷库处理，事务结束时清壳（不清会让既有 ZPAQ 线永久跳过）。
- 效率门 A/B 逻辑已移除（门已 PASS 关门），生产恒为全帧编码。
- 亮度调速器已删（用户签决 2026-08-10）：拍摄期屏幕恒定用户亮度。
- 编码器 `MaximizePowerEfficiency = true`（热余量归因后的修复，勿删）。
- iOS 内禁止一切 `Process.run/start`（无子进程，曾炸 finalize）。
