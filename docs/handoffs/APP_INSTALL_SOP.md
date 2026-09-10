# PocketWorld 生产机装机标准流程(SOP / 交给 agent 的提示词)

> 适用:把改动装到**用户唯一的生产 iPhone 14 Pro** 上。
> 最后更新 2026-09-07。这份文件是命令级的,照着做,不要凭记忆改写步骤。
> **任何一步的中止条件触发,就停下报告用户,不要自己想办法绕过。**

---

## 0. 先读这一段:五条铁律

1. **绝不 `uninstall`,绝不 `flutter install`。** `flutter install` 会先卸载,
   卸载会删光 app 容器里的全部采集会话(2026-08-18 已因此丢掉 8 场)。
   唯一允许的安装命令是 `xcrun devicectl device install app`(原地覆盖)。
2. **装机需要用户当次明确同意。** "代码改完了"不等于"可以装"。上一版批准过
   不延伸到这一版。
3. **装前必须有一次通过对账的增量备份。** 残缺备份比没有备份更危险 —— 它会让
   装后的核对拿着残缺集合"通过"。
4. **装完不要启动 app。** 让用户自己开。
5. **生产机在用户当天要拍摄时不跑台架/压测。**(两次热态 serious 事故)
6. **四项自证只证「我装的是我想装的字节」,不证「这东西能用」。** 装机门槛必须
   同时有一条**功能臂**(§4.5、§7.1),否则它只是打包检查表。2026-09-07 build 113
   带着全绿的四项自证和 1539 个通过的测试上机,**第一次快门就失败**。
7. **`flutter test` 全绿不是上机判据。** 仓库里没有一个测试跨过 MethodChannel /
   FFI,对「Dart 侧与 native 侧来自不同代码状态」这一整类缺陷结构性失明。
   引用测试数时必须同时写明它覆盖不到什么。

---

## 1. 环境常量(照抄,不要猜)

```
产品仓(Flutter)      ~/Developer/pw-head-0827
算法仓(C++/WGSL)     ~/Developer/Aether3D-cross/aether_cpp
                      ⚠️ 它的 .git 已于 2026-09-07 夜搬出 iCloud:
                         ~/Developer/Aether3D.git(主工作树留 gitdir: 指针,
                         5 个 worktree 指针已改写)。搬之前近 1 GB 对象被 iCloud
                         驱逐,commit 必然超时(300 s 不落地);搬后 commit 1.19 s、
                         rev-parse 0.02 s。**不要再把它移回 ~/Documents。**
                         回滚素材 ~/Developer/aether3d_gitmove_20260907/
                      补丁另存   ~/Developer/pw_extract_knives/
成品 .app 与台账       ~/Developer/pw_builds_20260904/  (+ README.md 是台账)
备份根                 ~/Developer/pw_backups/pw102_20260906/
  历史脚本             backup.sh / install_gate.sh(可复用的模板)
  增量备份目标         backup103_20260906_2243/

设备 UDID              1B290474-D354-5B4C-AAB0-0805AC5DC832
bundle id              com.kyle.PocketWorld
签名身份               Apple Development: wkd20040211@gmail.com (8N5Z34UK5Y)
entitlements           ~/Developer/pw_backups/pw102_20260906/entitlements.plist

设备日志(电脑侧读)    Documents/pw_device_log.txt
                       Documents/official_pw_device_log.txt
采集会话               Documents/captures_official/cap_<纳秒时间戳>/
Dart VM 哈希(引擎指纹) 0451907c2eaa8467e848c0067bfe8ed4
```

---

## 2. 选装机形态 —— 先想清楚只换什么

| 形态 | 换哪个二进制 | 什么时候用 |
|---|---|---|
| **DART_ONLY** | 只换 `Frameworks/App.framework` | 只改了 Dart(`lib/**`)。**绝大多数情况** |
| **PIPELINE_ONLY** | 只换 `Frameworks/PWOfficialSfm.framework` | 只改了 aether_cpp / WGSL。**🔴 `flutter build ios` 出不了这个 framework,见 §3.1** |
| 全量 | 整包重签 | 改了原生插件、Runner、Flutter 版本 |

**单变量铁律**:一次只换一个。产品(Dart)与管线(C++)不得在同一个 build 里
一起变,否则真机上出问题无法归因。

---

## 3. 出包(Phase A:构建)

```bash
cd ~/Developer/pw-head-0827
export PW_PRODUCT_SOURCE_MANIFEST_SHA256=$(sh tool/product_source_manifest.sh)
export PW_DIAGNOSTIC_BUILD_ID=<版本号>-<一句话标签>   # 例:109-svo-mindistance
export PW_VIO_SHADOW_MODE=off
flutter build ios --release --no-codesign
```

- 三个 env 少一个就构建失败或产物打错标签。
- 产物:`build/ios/Release-iphoneos/App.framework`。
- **中止条件**:`flutter build` 非零退出。若失败在 `Ld`(链接)且原因是
  aether_cpp 的构建目录被删,先看 §9。

装机前先跑测试与分析:
```bash
flutter analyze lib <改动目录>      # error 必须为 0
flutter test                        # 与改动前的基线对比失败集合
```
> 已知长期失败(与改动无关,不要当成回归):
> `test/vio/ffi/xrslam_official_replica_contract_test.dart`(Android .so 缺失)、
> `test/widget_test.dart` 的 AuthGate 那条(30 s 定时器)。
> 另有若干在并发下偶发的用例(resume_badge / platform_pose_provider):
> **单独重跑两次全绿就算并发抖动,不是回归。**

---

### 3.1 🔴 PIPELINE_ONLY 出包:`flutter build ios` 不会重链 `PWOfficialSfm`

`vendor/official_sfm/official_sfm.podspec` 里是

```ruby
s.vendored_frameworks = 'Frameworks/PWOfficialSfm.xcframework'
```

—— pod 吃的是**预制的 xcframework**,`libs/ios-arm64/*.a` 只是 `preserve_paths` 的输入。
**把新的 `.a` 拷进 `libs/` 再 `flutter build ios`,产出的 framework 还是旧的那一份**
(2026-09-08 实测:构建成功、`PWOfficialSfm` 二进制日期仍是 9-05、新符号 0 命中)。
装上去等于什么都没改 —— 这次是 §4 的**第 3 项自证**把它拦下的。

换它只有一条路:`scripts/build_xcframework.sh`(要 10 个 env:carrier / 钉定 Dawn+Ceres+glog
归档及各自 SHA / link map / 输出路径…),而它唯一的正经调用者是 `scripts/rebuild_native.sh`。
**`rebuild_native.sh` 是带评审闸的**,开头三个必需输入都在仓外:

```
PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST     # fresh-review 已接受的产品清单(文件)
PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST_SHA256
PWOFFICIAL_IDENTITY_OBSERVER             # 可执行文件,SHA 必须 = 脚本里钉的 eb493fd4…
```

外加一道硬闸:

```sh
actual_revision=$(git -C "$AETHER_ROOT" rev-parse HEAD)
[ "$actual_revision" = "$ALGORITHM_REVISION" ] || exit 66   # FAIL: algorithm revision mismatch
```

**🔴 已知不一致(2026-09-08 查实,未修)**:脚本里钉的 `ALGORITHM_REVISION=b930ab18` 日期是
**2026-07-21**,而出货归档里的 `official_bundle_adjustment_ceres.cc.o` 其源码 **2026-08-10**
才被加进来(`4924f0ae`)。⇒ **按这个钉子跑,复现不出生产机上正在跑的二进制。**
动管线前必须先把钉子修正到与出货产物真正对应的版本 —— 这是评审动作,要用户签。

**改单个 `.o` 的正解(本仓已有先例)**:不整树重编,而是**把重编的那一个 `.o` 用 `ar r` 换进
钉定归档**,`ranlib` 重建索引 —— `rebuild_native.sh` 里对 Dawn 归档就是这么做的
("640 个成员,其余逐字节未动,仅 `__.SYMDEF` 由 ranlib 重建")。判据:逐 `.o` 对拍后
**只有你换的那一个 + `__.SYMDEF` 不同,且没有任何一边独有的 `.o`**。
2026-09-08 局部 BA 两刀就是这样做出单变量归档的(`~/Developer/pw_backups/libpwofficial_core_ba_20260908.a`)。

---

## 4. 组装(Phase B:只换一个二进制 + 重签)

以 DART_ONLY 为例。写成脚本再跑,不要手敲。

```bash
#!/bin/bash
set -euo pipefail
B=~/Developer/pw_builds_20260904
NEWAPP=~/Developer/pw-head-0827/build/ios/Release-iphoneos/App.framework
BASE=$B/Runner-<上一版>.app            # 必须是**当前装在机上那一版**
DST=$B/Runner-<新版本>-<标签>.app
ID="Apple Development: wkd20040211@gmail.com (8N5Z34UK5Y)"
ENT=~/Developer/pw_backups/pw102_20260906/entitlements.plist

[ -d "$BASE" ] || { echo "base missing"; exit 1; }
[ "$DST" != "$BASE" ] || { echo "DST==BASE 会把基线删掉"; exit 1; }   # ← 必须有

rm -rf "$DST"; cp -R "$BASE" "$DST"
rm -rf "$DST/Frameworks/App.framework"; cp -R "$NEWAPP" "$DST/Frameworks/App.framework"

# App.framework 内的文件集合必须与基线一致(除 App 二进制本身)
diff <(cd "$BASE/Frameworks/App.framework" && find . -type f | grep -v "^./App$" | sort) \
     <(cd "$DST/Frameworks/App.framework"  && find . -type f | grep -v "^./App$" | sort)

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion <新版本>" "$DST/Info.plist"
for fw in "$DST"/Frameworks/*.framework; do
  codesign --force --sign "$ID" --timestamp=none "$fw" >/dev/null
done
codesign --force --sign "$ID" --entitlements "$ENT" --timestamp=none "$DST" >/dev/null
codesign --verify --deep --strict "$DST"
```

**组装前先确认构建真的结束**(2026-09-07 踩过:构建还在跑就去组装,拿到的是上一版
的 `App.framework`,三项自证里"新符号存在"照样通过,因为上一版也有那个符号):

```bash
# 后台构建时,必须等到日志出现完成行再组装
until grep -qE "Built build/ios|Encountered error|error:" build110.log; do sleep 10; done
```

**必须做的四项自证**(去签名后比 sha,签名本身每次都不同):

```bash
S=$(mktemp -d)
for v in <上一版> <新版本>; do
  for f in Runner Frameworks/App.framework/App Frameworks/Flutter.framework/Flutter \
           Frameworks/PWOfficialSfm.framework/PWOfficialSfm \
           Frameworks/thermion_dart.framework/thermion_dart; do
    n=$(echo $f | tr '/' '_'); cp "$B/Runner-$v.app/$f" $S/$v-$n
    codesign --remove-signature $S/$v-$n 2>/dev/null || true
  done
done
# 判据:只有你打算换的那一个 DIFF,其余必须 SAME
```

1. **只换的那个 DIFF,其余全 SAME。** 有第二个 DIFF ⇒ 停下,基线选错了。
   > ⚠️ **2026-09-08 实测更正:Dart AOT 不可复现。** 同一份源连编两次,
   > `App.framework/App` 去签名 sha 就不同(实测 `efd2c1c81e85` vs
   > `46450f0882c2`)。所以**全量构建时 `App` 必然 DIFF,哪怕一行 Dart 没改**
   > —— 这一条对全量构建只能判 `Flutter`/`PWOfficialSfm`/`thermion`,
   > `Runner` 与 `App` 的 DIFF 不构成信息。**只换 App.framework 的形态不受影响。**
2. **Dart VM 哈希与引擎一致**:
   `strings "$DST/Frameworks/App.framework/App" | grep -o "0451907c[0-9a-f]*" | head -1`
   对不上 ⇒ App.framework 与 Flutter.framework 不同源,停下。
3. **改动真的进去了**:用一个新符号自证,例如
   `strings .../App.framework/App | grep -c stellaVslamNewKeyframeIsNeeded`
   新包应 ≥1、旧包应 0。**"编译过了"不等于"改动进了包"。**
4. **新包与上一版的同一二进制必须不同**(去签名后比):
   > ⚠️ **2026-09-08:这一条对全量构建是废的** —— AOT 不可复现,sha 必然不同,
   > 所以它证明不了"新代码真的进去了"。**全量构建唯一有判别力的是第 3 项
   > (新符号在新包里存在、在旧包里不存在)**,必须找一个真正新增的符号;
   > 纯删代码的改动要反向找(旧符号在新包里消失)。
   ```bash
   # 只改了函数体、没加新符号时,第 3 项验不出来,只有这一项能验
   for v in <上一版> <新版本>; do
     cp $B/Runner-$v.app/Frameworks/App.framework/App $T/$v
     codesign --remove-signature $T/$v; shasum -a 256 $T/$v
   done
   # 两者相同 ⇒ 组装抓到了旧产物,或者这次根本没编出新东西 ⇒ 停下


### 4.5 功能臂之一:接口穿越审计(合并 / 全量原生构建时**必做**)

四项自证按文件比字节,而缺陷发生在**接口**上 —— 接口的两端在两个目录里。
只要这次出包满足下面任意一条,就必须做这一节:

- 合并了另一条工作树(不管冲突多少个);
- 做了全量原生构建(不是只换 `App.framework`);
- 动了 `ios/Runner/**` 或 `lib/official_dome/**`、`lib/*/platform_*.dart`。

```bash
# ① 列出**出包这一刻的 HEAD 里**仍与对方分支同源的文件
#    注意比的是 HEAD,不是合并提交 —— 合并后又修过的文件不该再报红。
git diff --name-only <merge>^1 HEAD | while read f; do
  [ -f "$f" ] || continue
  m=$(git rev-parse "HEAD:$f" 2>/dev/null); b=$(git rev-parse "<merge>^2:$f" 2>/dev/null)
  [ -n "$b" ] && [ "$m" = "$b" ] && echo "$f"
done > /tmp/took_theirs.txt

# ② 其中凡是带跨语言契约的,都是红旗:它的对端可能来自另一侧
#    `grep -c` 无命中时退出码为 1,别用 `|| echo 0`(会打出两行)。
grep -E "^lib/" /tmp/took_theirs.txt | while read f; do
  k=$(grep -cE "MethodChannel|EventChannel|invokeMethod|ffi\.|Native" "$f" 2>/dev/null || true)
  [ "${k:-0}" -gt 0 ] && echo "🔴 $f 有 $k 处跨语言引用 —— 它的 native 对端取的是哪一侧?"
done

# ③ 跑通道契约测试(方法名 / 回包键 / 请求参数三样对齐)
flutter test --no-pub test/arkit_channel_key_contract_test.dart
```

**判据**:②必须为空,或者每一条都已人工确认对端同源;③必须绿。
**归属规则是关于文件的,契约是关于接口的 —— 按目录裁决冲突时,必须再按接口复核一遍。**

### 4.6 功能臂之二:装后冒烟(§7.1),不可省

---

## 5. 装前备份(Phase C:增量 + 逐目录对账)

### 5.1 先查盘
```bash
df -h ~ | tail -1
```
剩余 < 15 GB 就先清。**只能删派生构建目录**(下次重编即可),绝不删需要重新
下载的缓存(隧道 80–180 KB/s)。删任何构建目录前必须:
```bash
grep -rn "<目录名>" ~/Developer/pw-head-0827/ios ~/Developer/pw-head-0827/vendor
```
确认没有链接引用。(2026-09-06 删 `build-ios-device-dawn` 导致 Pods 找不到
`libjpeg.a` 与 `libwebgpu_dawn.a`,整条链接断掉。)

### 5.2 拉设备清单(必须 JSON,不要解析文本输出)
```bash
D=1B290474-D354-5B4C-AAB0-0805AC5DC832; BID=com.kyle.PocketWorld
for DOM in Documents Library; do
  xcrun devicectl device info files --device $D \
    --domain-type appDataContainer --domain-identifier $BID \
    --subdirectory $DOM --json-output $S/pre_list_$DOM.json
done
```
> 文本输出会被带空格的文件名(`Application Support`)和日志行污染,必须用
> `--json-output`。

### 5.3 只拉备份里没有的会话
比较设备上的 `captures_official/*` 与备份目录里已有的,只拉新增的那几场。

### 5.4 逐目录对账(核心判据)
每个一级子目录单独 `devicectl device copy from`,拉完立刻比对:
```
want = 该子目录在清单 JSON 里的条目数
got  = find <本地目录> | wc -l      # 含目录自身
want == got 才算这个目录 OK,否则 rm -rf 重拉,最多 3 次
```
> **`devicectl device copy from` 会静默截断**:返回 0、日志无报错,实际只拉一半,
> 常见根因是磁盘满。所以判据必须是"条目数相等",不能是"文件数 > 某阈值"。

> 🔴 **2026-09-08 更正:「不在备份里」不能用「目录存不存在」判。**
> 装 121 前用严格判据(逐场比条数)一跑就抓到:`cap_1788790152081296` 设备 74、
> 本地 61 —— 那一场今早被 app 的孤儿恢复又写进了 20 张照片,而按旧判据它
> "已经在备份里",会被直接放行。**每一场都要比条数,不看目录在不在。**
> 重拉前把旧的那份 `mv` 成 `<cap>.old` 保留,不覆盖、不删除。

### 5.5 终判据
- Documents / Library 各自:设备条目数 == 本地文件数 + 目录数
- `captures_official` 的会话集合:设备 ⊆ 备份
- 三者全绿才算备份完成。**任一条不绿,不许进入装机。**

---

## 6. 装机闸(Phase D:必须紧贴 install,中间不插别的事)

```bash
D=1B290474-D354-5B4C-AAB0-0805AC5DC832; BID=com.kyle.PocketWorld

# ① 阳性对照:进程列表本身要是活的
P=$(xcrun devicectl device info processes --device $D)
[ "$(echo "$P" | wc -l)" -gt 50 ] || { echo "进程列表异常 ⇒ 判据失效,拒绝装机"; exit 1; }

# ② app 不在前台跑
echo "$P" | grep -qiE 'PocketWorld|Runner' && { echo "app 在跑,拒绝装机"; exit 1; }

# ③ 设备日志近 5 分钟没有采集/重建活动
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
  --domain-identifier $BID --source Documents/official_pw_device_log.txt \
  --destination /tmp/devlog_pre.txt
tail -300 /tmp/devlog_pre.txt | grep -E "worker up|session created|shutter ticket|add_frame|finalize|RefineGlobalBA" | tail -1
# 取它的时间戳,距现在 < 300 s ⇒ 拒绝装机
```

> ①这一条不能省:进程列表拿不到时 `grep` 也查不到 app,会假装"没在跑"。
> 判据必须先过阳性对照(2026-09-02 有过两个探针同时失效被当成证据的事故)。

**中止条件**:①②③ 任一不过 → 停下告诉用户,让用户退出 app 或等重建结束。

### 6.1 🔴 闸与 install 必须在**同一条命令**里(2026-09-10 教训)

把闸和 `install` 拆成两次工具调用、中间隔一轮对话,等于给了 app 几分钟窗口:
09-10 装 132 时闸② 连拒两次,而两次之间 **PID 从 747 变成 1267** —— app 被
关掉后又被 iOS 拉起来了。等你问完用户再去装,查的那个"没在跑"早就过期。

现成脚本(闸0 → 闸③ 先做因为它慢 → 闸①② → 立刻 install,窗口只有一两秒):

```bash
~/Developer/pw_backups/pw102_20260906/gate_and_install.sh <app 路径> <期望的机上基线版本号>
```

闸③ 里两处判据自证:拉日志失败 → 拒装(不是"当作没活动");关键词一条都没
匹配到 → 拒装(阳性对照失败,不是"很安静")。

**人工装机也走它。** 09-10 的 132 是在本会话之外被装上去的,闸①②③ 在那一刻
的读数没有任何人记录 ⇒ 只能证明结果(数据零丢失),证明不了过程。

---

## 7. 安装 + 装后核对(Phase E)

```bash
xcrun devicectl device install app --device $D ~/Developer/pw_builds_20260904/Runner-<新版本>-<标签>.app
xcrun devicectl device info apps --device $D | grep PocketWorld    # 核 build 号
```

**装完不要 launch。**

装后立刻重新拉一次清单,与 §5.2 的 pre 对比:
```
Documents:  pre 条目数 == post 条目数,missing = 0
captures_official 会话集合:pre == post
Library:    允许 SplashBoard/Snapshots/*.ktx 有出入(系统启动快照会重生成),
            **除此以外任何 missing 都算事故**
```

**中止条件**:出现非 SplashBoard 的 missing → 立即告诉用户,并准备用备份恢复。

### 7.1 装后冒烟闸 —— **在这一步之前,这次装机都不算完成**

清单对齐只证明"数据没丢",不证明"app 能用"。2026-09-07 build 113 的清单
1854/1854 全对、四项自证全绿、1539 个测试通过,而用户点下第一次快门就失败:
合并时 Dart 侧读 `evidenceWorldFromCamera`、Swift 侧只发 `cameraTransform`,
位姿解成空数组,**每一张照片都废**。装机门槛里没有任何一条能碰到这个。

我不 launch app(铁律 4,以及"绝不为取数据而开 app")。所以这条闸的形态是:
**把冒烟当成交付的一部分说出来,并在用户点完之后由我读日志判决**,而不是
装完就宣布"装好了"。

1. 交付话术必须是"**装上了,还没验过**",并明确请用户做最小动作:
   进采集页 → **点一次快门** → 退出。
2. 用户点完后,我拉设备日志判决:
   ```bash
   xcrun devicectl device copy from --device $D --domain-type appDataContainer \
     --domain-identifier $BID --source Documents/official_pw_device_log.txt \
     --destination /tmp/devlog_post.txt
   # 红线(出现任意一条 ⇒ 这次装机判失败,立刻回退)
   grep -E "shutter ticket=[0-9]+ FAILED|Uncaught|sfm: start FAILED|未进入重建" /tmp/devlog_post.txt | tail
   # 绿线:该会话出现 shutter ticket=1 之后有对应的 add_frame ... rc=ok
   ```
3. **判据必须先过阳性对照**:上面那条 grep 要能在坏版本的日志里真的命中
   (113 的日志里 `shutter ticket=1 FAILED` 就在那儿摆着,是我没去看)。
4. 冒烟不绿 ⇒ 原地装回上一版,不卸载,并在台账里写明"装了又退"。

> 为什么这条以前没有:我把"绝不为取数据而开 app"读成了"装完什么都不验"。
> 那条规矩禁的是**为了刷数据而启动**,不是禁**验证这次装机是否成功**。
> 一次快门 + 一次日志读,60 秒,能挡住整整一类"两端不同源"的事故。

---

## 8. 记账(Phase F,不可省)

1. 追加一行到 `~/Developer/pw_builds_20260904/README.md`,必须写清:
   时间、版本号、基线是哪一版、只换了什么、对应的 git commit、
   装前备份了哪几场、装机闸三项的实际读数、装后核对结果、
   **§7.1 冒烟闸的判决(绿/红/未验)**、
   **怎么退回**(退回 = 装上一版的 .app,不卸载)。
   引用 `flutter test` 的通过数时,必须同时写明它覆盖不到什么(至少:
   不跨 MethodChannel / FFI / 真机)。只写"N 个测试通过"是把打包检查
   当成了功能验收。
2. 产品仓 `git commit`(提交信息里写清出处/许可/实测数字)。
3. 更新记忆:装了什么、验证凭据是什么、还有什么没验。

---

## 9. 常见故障与已知坑

| 现象 | 原因 / 处理 |
|---|---|
| `flutter build` 在 Ld 失败 | aether_cpp 的 `build-ios-device-dawn` 被清盘删了(Pods 链接它里面的 `libjpeg.a` 与 `Debug-iphoneos/libwebgpu_dawn.a`)。重建该树;Xcode generator 不打包 `libwebgpu_dawn.a`,要用 Unix Makefiles 树 |
| 组装脚本把基线包删了 | `DST` 与 `BASE` 同名。脚本里必须有 `[ "$DST" != "$BASE" ]` 断言 |
| 装后行为没变 | 没做 §4 的第 3 项自证。用新符号 `strings | grep -c` 验 |
| `devicectl copy from` 断连 / 只拉一半 | 磁盘满 或 传输中断。按 §5.4 逐目录重拉,不要整目录一把梭 |
| Wi-Fi adb / devicectl 掉线 | iPhone 走配对的 Wi-Fi(`Kyles-iPhone.coredevice.local`);Android 台架机 `adb connect 192.168.1.11:5555`,拔线后 adbd 复位需重连 |
| 台架机(Mate 10)数字忽快忽慢 | 必须 `adb shell svc power stayon true` + `input keyevent KEYCODE_WAKEUP`。锁屏态 GPU 慢 2–3 倍(4.7 s → 10 s),且 thermalservice 不报节流 |
| 换了 `.a` 却装完行为没变 | `PWOfficialSfm` 是 podspec vendor 的**预制 xcframework**,`flutter build ios` 不重链它。见 §3.1。必须用 §4 第 3 项自证(新符号 `strings | grep -c`)拦 |
| `rebuild_native.sh` 报 `exit 66 algorithm revision mismatch` | `ALGORITHM_REVISION` 钉子过期(见 §3.1 已知不一致)。**不要改钉子绕过** —— 那一行就是评审凭据,要用户签 |

---

## 10. 一页纸检查表(装机前逐条打勾)

- [ ] 用户**这一次**明确说了要装
- [ ] 只换一个二进制(产品 / 管线不混)
- [ ] `flutter analyze` error = 0;`flutter test` 失败集合 == 已知基线
      —— 并且**清楚这一条覆盖不到跨语言契约**,不能当功能验收
- [ ] **接口穿越审计(§4.5)**:合并 / 全量原生构建时必做,取了对方版本的
      文件里没有一个的 native 对端来自另一侧;通道契约测试绿
- [ ] 组装:只该换的那个 DIFF,其余 SAME
- [ ] Dart VM 哈希与引擎一致
- [ ] 构建日志出现完成行之后才组装
- [ ] 新符号在新包里存在、在旧包里不存在
- [ ] 新包与上一版的同一二进制去签名后 sha **不同**
- [ ] `df` 余量 ≥ 15 GB
- [ ] 增量备份三条终判据全绿
- [ ] 装机闸:进程表阳性对照过、app 不在跑、5 分钟内无采集/重建
- [ ] `devicectl device install app`(不是 flutter install)
- [ ] build 号已核
- [ ] 装后清单对比 missing = 0(SplashBoard 除外)
- [ ] 装完**没有**启动 app
- [ ] **交付话术是「装上了,还没验过」,并请用户点一次快门(§7.1)**
- [ ] **用户点完后我读日志判决冒烟闸;没绿之前这次装机不算完成**
- [ ] README 台账 + git commit + 记忆已更新(含冒烟闸判决)
- [ ] 已告诉用户:验证凭据是什么、怎么退回
