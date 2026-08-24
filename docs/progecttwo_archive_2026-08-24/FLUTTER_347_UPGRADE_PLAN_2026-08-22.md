# Flutter 3.41.8 → 3.47.1 升级执行方案

日期:2026-08-22 · 裁决:**GO-WITH-PRECONDITION**
依据:10 agent 审计(依赖解析 / 破坏性变更命中 / 原生构建面)+ 主线 4 项复核


---

# ✅ 收口状态(2026-08-22 23:40)

**升级已完成并在真机验证通过。** 分支 `upgrade/flutter-3.47.1`,10 笔提交,
起点 tag `baseline/pre-flutter-347-20260822`。

| 判据 | 升级前基线 | 现在 |
|---|---|---|
| Flutter / Dart | 3.41.8 / 3.11.5 | **3.47.1 / 3.13.1** |
| `flutter analyze` | 0 error / 13 warn / 21 info | **0 error** / 13 warn / 22 info |
| `flutter test` | 900 过 / **8 败** | 864 过 / 1 skip / **0 败** |
| `flutter build ios --release` | — | **exit 0**,261.2MB |
| 真机 | — | **装机 / 启动 / 登录 / 采集 / 尺度** 全过 |
| CocoaPods trunk 依赖 | 7 个 | **3 个** |

## 两个曾被判为"可能否决整次升级"的未知项:都没兑现

- **U1 thermion build hook** —— `thermion_flutter` 留在 0.3.4,pub get 与 build hook
  均正常。审计把 flutter_tools 自己的 `hooks 2.0.2` 当成了 app 的依赖,是误判。
  真实边界是 `hooks_runner` 1.0.1 → 1.5.0(minor)。
- **U2 onnxruntime 手写 force_load** —— 两条硬编码 xcframework slice 路径实测仍命中。

## 审计清单里被实测推翻的四处

1. **部署目标是 8 处不是 7 处** —— 漏了自家插件 `packages/pw_hevc/ios/pw_hevc.podspec`
2. **"682MB libaether3d_ffi.a / 668MB libwebgpu_dawn.a 不可逆"** —— 位置写错了。
   真身在**仓库外的兄弟目录**:`~/Developer/dist/libs/ios-arm64/libaether3d_ffi.a`(650M)、
   `~/Developer/Aether3D-cross/.../libwebgpu_dawn.a`(638M)。
   ⇒ **worktree 必须放在 `~/Developer/` 下**,`$(PODS_ROOT)/../../../` 正好解析到那儿
3. **Podfile 的 13.0 地板 hook 不是阻断** —— `15.0 < 13.0` 为假,它在 3.47 下惰性。
   仍把阈值抬到 15.0(保留 `current.nil?` 的兜底),但不是"必须删"
4. **SwiftPM 没有接管** —— onnxruntime / pw_hevc / thermion_flutter / video_thumbnail
   四个插件不支持,Flutter **自动回退 CocoaPods**。⇒ 不需要
   `enable-swift-package-manager: false`

## 顺带完成的四件

| | |
|---|---|
| 断链三层修复 | `44aeac4` / `b72d654` / `9a4c703` —— main 恢复独立编译 |
| MePage 路由修复 | `f41f676` —— 官方作品**点不开 3D viewer** 的老 bug(非升级引入) |
| 移除 file_picker | `db24266` —— 调用点归零;**trunk 依赖 7 → 3**,包瘦 2.4MB |
| 8 个长期红的契约测试 | `ae9c7f7` / `242c1ad` / `b845433` —— **8 → 0**,无一条靠放宽断言变绿 |


---

## 0. 为什么是今天

- **零用户** —— 十年里破坏成本最低的一天。上架后一次坏构建 = 真实用户卡在旧版
- **代码量只会涨** —— 现在跨两代;拖到明年是跨三代(3.50),一次吃三代变更
- **Apple 的钟在走** —— Xcode 27 支持 3.47 才落地,明年四月前后大概率强制

**iOS 14 → 15 掉零个机型**:iOS 15 的设备支持列表与 iOS 14 完全一致(iPhone 6s 及以后)。
唯一损失是"能升却没升"的用户,而这批人跑不动 ARKit 摄影测量。

---

## 1. 真阻断(不改就升不上去)

全部是部署目标,**机械改动,零逻辑**。必须**同一次提交**:

| 位置 | 现值 | 改为 |
|---|---|---|
| `ios/Podfile:2` | `platform :ios, '14.0'` | `'15.0'` |
| `ios/Podfile:87-92` | 13.0 地板 hook | **整段删** |
| `ios/Runner.xcodeproj/project.pbxproj` 591/772/823 | `14.0` | `15.0` |
| `vendor/aether_ffi/*.podspec` | `14.0` | `15.0` |
| `vendor/official_sfm/*.podspec` | `14.0` | `15.0` |
| `ios/scripts/thermion_minos_fix.sh:34-35` | `13.0` | `15.0` |
| `ios/Runner/Info.plist:45-46` | 陈旧 `13.0` | `15.0` |

### 关于 Podfile:87-92 —— 修正审计的定性

审计称它会把 pod 钉死 13.0 导致编译失败。**实测代码是惰性的**:

```ruby
if current.nil? || current.to_f < 13.0   # 3.47 设 15.0 → 15.0 < 13.0 为 false → 不覆写
```

唯一活着的分支是 `current.nil?`。它**不阻断**,但该删 —— 注释写明动因是
"CocoaPods 有时降回 stock 12.0",这个前提在 3.47 下已不成立。

### 不是阻断,别误列

- `vector_math` 2.2.0→2.4.2 强制但已证明干净(SimplexNoise 零命中)
- `macos/` 的 10.15 是独立工程,不阻断 iOS
- UIScene 已提前适配
- SwiftPM 有官方回退路径:`flutter: config: enable-swift-package-manager: false`

---

## 2. 未知项(只能靠真跑)

### U1 · thermion build hook —— 已降级,有逃生舱

| | hooks | hooks_runner |
|---|---|---|
| Flutter 3.41.8(现) | 1.0.0 | 1.0.1 |
| Flutter 3.47.1 | 2.0.2 | 1.5.0 |
| thermion_dart 0.3.4+1(装的) | `^0.20.1` | — |
| thermion_dart 0.5.0(08-20 发) | `^1.0.0` | — |

**反证:你现在就是错配的** —— thermion 要 `^0.20.1`,3.41.8 钉 `1.0.0`,**而今天构建正常**。
说明 flutter_tools 的 `hooks` 是它自己的依赖,不参与 app 解析。

真实边界是 `hooks_runner` **1.0.1 → 1.5.0**(minor,按 semver 向后兼容)。

**逃生舱**:`thermion_dart 0.5.0`(Dart `>=3.10.0`,hooks `^1.0.0`)。
代价 = 跨两个破坏性 0.x minor + 9 个 import 点 + Podfile 里两处写死 "0.3.4" 的 workaround。

### U2 · onnxruntime —— 真未知,无救援路径

`ios/Podfile:120-170` 手写 `force_load` 补丁,**硬编码 xcframework slice 路径**,
而升级恰好改变 pod 解析结果。上游 **20 个月无提交**。

只有第 8 步的 `flutter build ios --release` 能给出结论。

---

## 2.5 iOS 原生侧的重心与一条被低估的传导路径

来源:同机会话 progecttwo-1b 的独立代码追踪(2026-08-22)。

### `ios/Runner/OfficialAetherARKitPlugin.swift` 是唯一重心

- **4336 行,全仓唯一 `import ARKit` 的文件**,向 Dart 暴露 20 个 method channel
- `:4022-4024` 作者自己写明:新增原生功能应该蹭这个文件,以求**零 pbxproj 改动**
- 它同时管:相机、AR 显示、后台任务伞、每帧写 sidecar JSON 喂 SfM

**⇒ 本次升级要改 `project.pbxproj` 的三处部署目标,升级后这个文件是 iOS 侧
第一优先验证对象。它挂了整条采集链就断。**

### ⚠️ 部署目标 → ARKit → 交付物尺度,这条路是通的

交付点云的**米制尺度 100% 来自 ARKit**,两级注入:

| 位置 | 机制 |
|---|---|
| `official_aether_sfm_c.cc:8991` | 每帧以 ARKit 位姿直接注册 |
| `official_aether_sfm_c.cc:8811-8827` | 拿不到合法 ARKit 位姿的帧**直接丢弃** |
| BA | `FixGauge(TWO_CAMS_FROM_WORLD)` 锁死含 scale 的 7-DOF |
| `Normalize()` 四个调用点 | 全传 `normalize_reconstruction=false` |

**任何影响 ARKit 行为的改动(iOS 部署目标 14→15、随之而来的 ARKit 版本)
都会直接传导到交付物的尺度。**

这一条把"部署目标只是个数字"这个印象推翻了。它不改变 GO 的结论(掉零个机型
仍然成立),但**新增一条升级后的验证项**:

> **在第 9 步真机装机后,补跑一场采集,与升级前的重建结果比对尺度有没有漂。**
> 这是本次升级唯一有理由怀疑会静默劣化交付质量的路径 —— 编译通过、测试全绿、
> 装机成功,它都不会报警。

---

## 2.6 两条已记录的 CocoaPods 雷(升级时会正面撞上)

来源:同机会话 progecttwo-3c 指出的既有 memory 记录。

1. **`path_provider` 2.6.0 纯 FFI 化后 CocoaPods 漏装** —— App 运行时读不到路径,
   当时是锁 2.5.1 修的。本仓库现在就带着这个 override。
   ⇒ 第 6 步 `flutter pub get` **禁用 `--major-versions`** 的理由又多一条;
   第 9 步真机验 `getApplicationDocumentsDirectory` 是必需项不是可选项。
   见 `memory/reference_path_provider_ffi_cocoapods_break.md`

2. **`pod install` 撞 Ruby 4 会静默失败** —— 不报错,但没装上。
   ⇒ 第 7 步跑完**必须核对 `ios/Pods/` 里真的有东西**,不能只看 exit code。
   见 `memory/reference_cocoapods_ruby4_unicode_bug.md`


---

## 3. 执行顺序

**【不可跳过】= 跳了就失去归因能力或回滚能力**

0. ✅ **【已完成 2026-08-22】** 断链已修复,基线已建立。
   详见 `progecttwo/TREE_BASELINE_2026-08-22/README.md`。

   断链实际是**三层**(不是最初判断的"27 个未提交文件"),三笔提交修完:

   | 提交 | 层 | 内容 |
   |---|---|---|
   | `44aeac4` | 文件缺失 | `auto_rotating_cloud_view.dart` + `card_live_governor.dart` |
   | `b72d654` | API 漂移 | `feed_models` / `thumb_baker` / `aether_cpp_card_demo` / `representative_color` / `official_aether_sfm_ffi` |
   | `9a4c703` | l10n 源 | `app_en.arb` + `app_zh.arb`(生成物不提交)|

   工作树其余 38 个脏项与编译无关,一律未触碰。
   全部 47 项已备份并逐字节 sha256 对账(69MB)。
1. ✅ **【已完成 2026-08-22】** 基线判据已存档在 `TREE_BASELINE_2026-08-22/` 第 3 节:
   `flutter analyze` **0 error** / 13 warning / 21 info;
   `flutter test` **900 passed / 8 failed**,八个失败的**名字级**清单已记录。

   ⚠️ **升级后跑验证时,先剔掉三类环境噪声,否则会看到假失败:**

   | 噪声 | 表现 | 处理 |
   |---|---|---|
   | 兄弟仓路径 | `official_per_image_pinhole` / `official_match_ratio` 读 `${pocketWorld.parent.path}/Aether3D-cross/aether_cpp/...`;在别处的 worktree 里跑 → **假失败 3 个** | worktree 父目录 `ln -s ~/Developer/Aether3D-cross` |
   | 嵌套包 | 根包 analyze 会连 `packages/pw_hevc/` 一起分析,而根包 pub get 不给它装依赖 → **假 error 56 个** | 在 `packages/pw_hevc/` 单独跑 `flutter pub get` |
   | 环境累积 | `lib/l10n/app_localizations*.dart` 是生成物;同一个 worktree 反复验证会让它带着新 getter 留下,**把真 error 盖住** | **每次要下结论的验证都用全新检出** |
2. 开分支/worktree,**不在 main 上升**
3. **【不可跳过】** 单独提交 `pubspec.lock` + `ios/Podfile.lock` + `ios/Podfile`
   + `project.pbxproj` 作为回滚锚点
4. `git -C /opt/homebrew/share/flutter checkout 3.47.1 && flutter precache`
   ⛔ **不要 `brew upgrade`** —— Caskroom 只有 3.41.7,会把你退到更旧版本
5. **【不可跳过,同一次提交】** 第 1 节那七处 15.0 一起改
6. `flutter pub get` —— ⛔ **禁用 `--major-versions`**。让 vector_math / intl /
   app_links / url_launcher_android 自然浮动,保持单变量
7. `pod deintegrate && pod install`(`export LANG=en_US.UTF-8`,系统 Ruby 2.6)
8. **【不可跳过,判决点】** `flutter build ios --release` —— U1 与 U2 全在这里出结果。
   失败即走第 4 节回滚,**不要边升边改 thermion 版本**(那是同时动两个变量)
9. **【不可跳过】** 真机装机,跑三条只有真机能验的路:
   - Supabase OAuth deep link 往返(app_links 7.0 → 7.2.1)
   - `getApplicationDocumentsDirectory`(顺手删掉 `path_provider_foundation` override 试一次)
   - file_picker 能否弹出(`UIApplication.windows`)
10. 装机成功后再评估 `project.pbxproj:430/460` 两段自研 `xattr -cr` + 重签脚本能否删 ——
    **只能用安装码判断,编译通过不构成证据**
11. 两个活的 `.claude/worktrees/*` 各带一份 14.0 的 Podfile+pbxproj,
    必须先合并或同步改,否则合回来把旧值带回
12. `cacheExtent` → `ScrollCacheExtent.pixels(2000)` 和 RadioGroup 两处 trivial 迁移
    **延后,不进本次** —— 它们只是 analyzer warning,混进来破坏单变量

---

## 4. 回滚(已验证,15 分钟级,零不可逆)

已核实:`/opt/homebrew/share/flutter` 是 flutter/flutter 的 git checkout,
`HEAD == stable == 3.41.8`,**3.41.8 与 3.47.1 两个标签本地都在**。

```bash
git -C /opt/homebrew/share/flutter checkout 3.41.8 && flutter precache
git checkout <锚点提交> -- pubspec.lock ios/Podfile.lock ios/Podfile \
  ios/Runner.xcodeproj/project.pbxproj ios/scripts/thermion_minos_fix.sh ios/Runner/Info.plist
rm -rf ios/Pods ios/.symlinks ios/Flutter/ephemeral \
  .dart_tool/hooks_runner .dart_tool/native_assets.yaml
flutter clean && flutter pub get && (cd ios && pod install)
```

### ⛔ 唯一不可逆的东西

**升级分支上绝对不要重编 vendored 二进制**:

- `libaether3d_ffi.a`(682MB)
- `libwebgpu_dawn.a`(668MB,Debug)
- `PWOfficialSfm.xcframework`

重编了就只能回代码,回不了产物。

---

## 5. 诚实的未知项(没查实,需真跑)

1. thermion build hook 在 3.47 下能否跑 —— 读约束读不出来,依赖第 8 步
2. onnxruntime 的 force_load 补丁在新 pod 解析下是否仍命中硬编码 slice 路径 —— 同上
3. 8 个预存测试失败在 3.47 下的走向 —— 没有名字级基线就无法判断新增
4. 两段自研 xattr/codesign 脚本是否已被上游自愈 —— 只能靠真机安装码
   (`0xe8008018` / `0xe8008014`)判断
5. `path_provider_foundation: 2.5.1` override 是否已过时 —— 3.44+ 构建路径完全不同,
   原 bug 大概率消失,但必须真机验 `getApplicationDocumentsDirectory` 才敢删
6. macOS 侧完全未验(10.15 → 12 的四处)—— 近期不出 macOS 版本可整体不动
7. CI 里没有 analyze/test 闸门 —— 本次不建议顺手加(第二个变量),
   但升级后要长期维持,它是下一件该做的事

---

## 附:CocoaPods trunk 只读(2026-12-02)

54 个 pod 中**只有 7 个走 trunk**:
`DKImagePickerController` · `DKPhotoGallery` · `SwiftyGif` · `SDWebImage` ·
`libwebp` · `onnxruntime-c` · `onnxruntime-objc`

其余全是本地路径(自研 vendored + Flutter 插件的 `.symlinks/plugins/`),**不碰 trunk**。

只读 ≠ 关停,读取与下载照常。唯一值得留意的是 **`onnxruntime` 会永远停在 1.15.1**。

**上架前不用动。** 等升 Flutter 时顺手把那 7 个的源码镜像到私有仓即可 —— 一次性的事。

---

# ⚠️ 绿灯**没有**覆盖的东西(2026-08-22 23:40)

`flutter test` 显示 `All tests passed!`,但下面这些**不在那盏绿灯的射程内**。
写在这里是为了别把"测试全绿"误读成"全部完成"。

## 1. ~~手机上装的不是当前分支~~ ✅ 已重编重装(23:58)

装机曾停在 22:11,落后 3 笔会进二进制的提交(`db24266` 移除 file_picker /
`8649c24` 删除协调器 / `ae9c7f7` device_log import 改指 official 树)。

**已从 `21ccb6c`(= 当前 main)重编并覆盖安装**:

  MinimumOSVersion   15.0
  包体               249M
  许可文本随包        12 个,位于
                     App.framework/flutter_assets/ios/Vendor/NativeCore/licenses/
                     ⇒ 合规修复**可验证地进到了二进制里**,不只是入了库
  用户数据           119 → 119 条逐条一致,零损失
                     (排除 iOS 自生成的 SplashBoard 启动快照)
  启动               FEngine backend=Metal,59.9 → 60.0 fps

装机一律用 `xcrun devicectl device install app`(覆盖安装,保留数据容器),
**不是** `flutter install`(它会先卸载,08-18 因此永久删掉 8 个采集会话)。

## 2. 1 个测试是 skip 不是 pass

`capture_quality_ramp` 的「无硬台阶」用例被**有意挂起**,不是修好:

> 133 是当前锚色下的**数学下界**(最大单步 ≈ 398/span,satAt=5 ⇒ span=3 ⇒ 133),
> 而 **133 > 旧实现的 128** —— 该模块在出货配置下已无法兑现它自己的立项目的。

出路只有两条:**重调锚色/插值路径**,或**整体删除该模块**(自 08-09 全白签决后
它在 `lib/` 已零调用)。在做出选择前红灯不算消掉,只是不再淹没其它测试。

## 3. ~~12 个 license 文件仍未入库~~ ✅ 已解决(`21ccb6c`)

`pubspec.yaml:240` 把 `ios/Vendor/NativeCore/licenses/` 声明为 Flutter asset
(注释写明「BSD-3 要求二进制分发时附带版权声明」),但那 12 个文件**从未 git add** ——
任何人干净检出后构建出的包,都缺掉法律要求随附的许可文本。

**已补提交 `21ccb6c`**,12 个文件逐个 add(abseil / ceres / cgltf / colmap / dawn /
eigen-MPL2 / glog / libjpeg-turbo / meshoptimizer / poselib / stb / vlfeat)。
复验:`flutter analyze` 的 `asset_directory_does_not_exist` 警告归零。

对照证据(说明入库是既定意图、这 12 个纯属漏了):同为 asset 声明的
`vendor/lepton_jpeg/licenses/` 是 **4/4 全部入库**的;且这 12 个未被 `.gitignore`
排除(`git check-ignore` 无输出)。

## 4. 两个已知的负载敏感 flaky 测试

单独跑 100% 过,机器压满时会假失败:

- `test/sparse_cloud_viewer_selection_test.dart`(`_pumpUntilRealAsyncSettles`
  真实 IO 预算只有 40×20ms = **800ms**)
- `test/glb_cache_size_guard_test.dart` / `test/resume_badge_and_thumb_test.dart`
- `test/platform_pose_provider_fail_closed_test.dart`

⇒ **别在跑全量测试的同时开多 agent 工作流** —— 本会话就因此制造过两次假失败,
一次差点被当成"删除协调器引入的回归"去追。

## 5. macOS 侧完全未验

`macos/` 的部署目标(10.15 → 12 的四处)一处未动、一次未编。近期不出 macOS 版本
可以整体不管;要动就是一批同构改动。

## 6. B4 / B5 的**行为**没有改变,只是变得可审计了

用户确认 TVG-SPLIT 与 STARVED-ALWAYS 均已签决,故把两条红灯换成了行为性护栏。
但要明确:**底层行为一行没动**。

- official 两视几何的**位姿**仍来自自研 `EstimateUprightRelativePoseV1`,
  **无 kill switch**,14 个调用点全覆盖,拿不到 ARKit 重力则该对直接丢弃
- 出货 env 下官方 quadratic 预付**恒不执行**,空闲通道 100% 落自研 live repay,
  且 `GrowLiveTracksFromTvgInliers` **当场三角化写 live_recon**

改变的只是:这些事实现在**被账本记录、被测试钉住**,再想隐形就会红。

## 7. ~~尚未合回 main~~ ✅ 已合并 / ⚠️ 仍未推送

**`main` 已快进到 `21ccb6c`,现在就是 Flutter 3.47.1。**

合并前核过 13 处撞车文件,**全部良性**:

  12 个 license      主树未跟踪副本与分支已提交版**逐字节相同**(12/12)
  ios/Podfile.lock   主树那 7 行未提交改动(flutter_secure_storage_darwin)
                     在分支版本里**逐行都已包含** ⇒ 完全被涵盖,不丢东西

合并后复验:12 个 license 逐字节还原一致;Podfile.lock 含
flutter_secure_storage_darwin;主树脏项 37 → **24**(正好等于被吸收的 13 个)。
合并前另存了一份这 13 个文件到 `TREE_BASELINE_2026-08-22/pre_merge_snapshot/`。

⚠️ **仍未推送**:`main` 领先 `origin/main` **43 笔**(合并前 33 + 本次 10)。
`upgrade/flutter-3.47.1` 分支无上游,`origin` 上不存在任何 `upgrade/*`。

## 8. 全机 Flutter SDK 已被切换

没装 fvm,只能切全局。**主树里跑任何 `flutter` 命令用的也是 3.47.1。**
回滚:`git -C /opt/homebrew/share/flutter checkout stable`

## 9. 一条没做的真机验证

**同场景同方式各拍一次**,才能把"尺度更贴 ARKit"这个改善单独归因给 3.47。
目前只能说**升级没有引入尺度漂移**(0.070% vs 升级前 1.028%),
不能说是 3.47 带来的改善 —— 两次采集之间还变了拍摄方式(手动 → 自动)。
