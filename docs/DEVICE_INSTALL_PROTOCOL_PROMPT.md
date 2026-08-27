# 手机 App 更新流程 · 极致提示词 · 2026-08-25

> 下面整段是给未来会话/agent 的提示词,照抄即可。每一条规矩后面都站着一次真事故,
> 不许"优化"掉任何一步。

---

## 提示词(整段粘贴)

你要把 PocketWorld 更新到用户的 iPhone 上。**严格按以下流程执行,顺序就是生命线,
任何一步失败立即中止并报告,禁止跳步、禁止自作聪明简化。**

### 常量

```
PROJ=/Users/kaidongwang/Developer/pocketworld
APP=$PROJ/build/ios/iphoneos/Runner.app
UDID=1B290474-D354-5B4C-AAB0-0805AC5DC832        # Kyle's iPhone 14 Pro
BUNDLE=com.kyle.PocketWorld
DEVLOG=Documents/official_pw_device_log.txt        # App 数据容器内的管线日志
```

### 执行环境与唯一安装锁(2026-08-26 双 Build 43 覆盖事故)

- **禁止打开、激活或堆叠 macOS Terminal 窗口。** 用户已明确要求更新全程后台执行;
  若当前执行环境不能可靠使用 CoreDevice/签名,立即中止并报告,不得弹 Terminal
  兜底。历史文字中“正常 Terminal 会话”的建议不再授权 GUI 弹窗。
- 同一台生产手机同时只允许一个更新任务。构建开始前必须原子取得
  `/private/tmp/pw-production-device-install.lock`;锁已存在就中止,不得等待着偷偷
  接管。锁内记录 PID、bundle、目标 build、候选诊断身份,完成或失败后释放。
- install 前最后一刻除活动检查外,还必须确认不存在其他
  `devicectl device install app` 进程。发现一个就中止。本次事故中,正确 OFF 包
  18:14:15 装完后,另一遗留任务在 18:14:37 用同号 Build 43 覆盖,正是因为
  没有这把锁。
- **Build 号不是代码身份。** 构建后必须冻结并核验:source manifest、唯一
  `DART_DEFINES`(实验臂必须逐字等于目标值)、Dart AOT SHA-256、签名
  `PWLiveCloudDiagnosticBuildId`、Runner arm64 LC_UUID。任一不符即中止。
- 安装完成仍不由 agent launch。用户手动打开后,若任务要求核验手机实际运行
  二进制,后台 LLDB 只读 attach,读取运行中 Runner image UUID 后立即 detach;
  必须与候选 LC_UUID 相同。不能用 build 号、安装成功输出或本地产物 UUID
  冒充“手机实际运行 UUID”。

### 血债清单(为什么是这个流程)

- **08-18 事故**:`flutter install` 会**先卸载再安装**,一次删掉 8 个采集会话。
  ⇒ 安装只许 `xcrun devicectl device install app`(原地覆盖,保数据容器),
  **永远禁止** `flutter install`、禁止任何形式的 uninstall;
- **08-10 事故**:活动检查做在构建之前,检查通过→构建 40s→拉清单 1-2 分钟→install,
  用户恰好在这几分钟窗口里开拍,覆盖安装杀进程,拍到第 75 张戛然而止。
  照片与 db 可续跑,但**没拍完的覆盖补不回来**。⇒ 活动检查必须是 install 前
  **最后一步**,与 install 间隔秒级;
- **b22 未遂事故(fail-closed 的由来)**:①日志拉取失败后 zsh 把空 HITS 当 0 放行,
  检查形同虚设;②`install | tail` 管道吞掉 devicectl 退出码,设备已断连却谎报
  INSTALL_RC=0。⇒ copy 失败即中止;计数非数字即中止;install 输出重定向到文件、
  **绝不进管道**,直取 `$?`;
- **08-25 实战案例**:装前拉日志发现 App 在几秒前刚被启动(`[DeviceLog] session start`)
  ——这正是用户要开拍的高危信号。等 3.5 分钟重拉,确认零新活动才装。
  ⇒ 刚启动也算活动信号,必须等待复查;
- **交付无损铁律**:正在拍摄/重建时覆盖安装=永久缺帧,绝对禁止。

### 第 1 步:构建(先构建,后检查——顺序是命)

```bash
cd $PROJ && flutter build ios --release --build-number=<上一版+1>
```

- 机上现版本号查法:`xcrun devicectl device info apps --device $UDID | grep -i pocketworld`
  (第四列=build 号);新 build 号必须严格 +1,**不许捏造/跳号**;
- ⚠️ pubspec.yaml 的 `version:` 行长期滞后(如机上 31 时它还是 +20),
  **不作数**,以 `--build-number` 显式传参为准;
- 构建完核对产物就是你要装的版本:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $APP/Info.plist
```

  输出必须等于你传的 build 号,否则中止。
- 若本次更新涉及重编 `libpwofficial_core.a`:先与「位姿+ui」会话协调
  (重编会把 Aether3D-cross 在飞改动一起卷进产物),并遵守装机合同
  (产品改动与管线改动分开装、单变量)。

### 第 2 步:装前清单/备份(如需)——放在活动检查**之前**

装前备份或数据清单(耗时 1-2 分钟的事)全部在这一步做完,**绝不允许横在
活动检查和 install 之间**。备份走 `project_pocketworld_device_backup_verified_recipe`
(逐目录对账+先查 df)。没有备份需求就跳过本步。

### 第 3 步:活动检查(install 前最后一刻,fail-closed)

```bash
S=<scratchpad>; rm -f $S/devlog.txt
xcrun devicectl device copy from --device $UDID \
  --domain-type appDataContainer --domain-identifier $BUNDLE \
  --source $DEVLOG --destination $S/devlog.txt >$S/copy_out.txt 2>&1
echo COPY_RC=$?
```

- **COPY_RC≠0 ⇒ 立即中止**(拉不到日志=盲飞,不许"当作没在拍"放行);
- 看日志尾部,最近 **10 分钟**内出现以下任一标记即为活动中:
  `worker up` / `session created` / `shutter ticket` / `add_frame` /
  `finalize` / `RefineGlobalBA`;
- **`[DeviceLog] session start`(App 刚启动)同样算高危信号**——用户可能正要开拍;
- 任何用 grep -c 之类得到的计数,**非纯数字一律视为检查失败并中止**,
  空值绝不许被 shell 当 0 放行;
- 有活动 ⇒ 等 3-5 分钟(用后台 sleep,不占前台)重拉重判,直到连续一次
  **零新增日志行**才放行;拍摄/重建中的等待没有上限,**等多久都比打断一次拍摄便宜**。

### 第 4 步:安装(不进管道,直取 RC)

```bash
xcrun devicectl device install app --device $UDID $APP >$S/install_out.txt 2>&1
RC=$?; echo INSTALL_RC=$RC; tail -6 $S/install_out.txt
```

- **禁止** `install | tail`、`install && …` 之类任何会掩盖退出码的写法;
- RC≠0 ⇒ 中止并把 install_out.txt 尾部原样报给用户,不许重试循环。

### 第 5 步:验证真的装上了(装机≠生效)

```bash
xcrun devicectl device info apps --device $UDID | grep -i pocketworld
```

- 第四列 build 号必须等于第 1 步传入的号,不符=安装未生效,如实报告;
- 有管线行为改动的,装后首场真机日志里还要验证新行为真的在跑
  (`feedback_verify_it_actually_landed_in_production`:装机≠生效)。

### 第 6 步:收尾纪律

- **装完绝不 launch**——由用户自己打开;
- 如需推 env 旋钮:设备 env 是**共享单文件**,必须先拉取→本地合并→再推回
  (读-改-写;直接覆盖=抹掉别的会话推的旋钮,08-11 真事故);
- 向用户报告:build 号、验证结果、本次改动一句话;若活动检查等过,说明等了多久、
  看到了什么信号。

### 红线总结(一屏速查)

1. 只用 `devicectl install`,永不 uninstall,永不 `flutter install`;
2. 先构建后检查,检查贴着 install,间隔秒级;
3. copy 失败=中止;计数非数字=中止;install 不进管道;
4. 拍摄/重建/刚启动=等,等多久都行;
5. 装完验 build 号,不 launch;
6. build 号只许 +1,不捏造;
7. env 文件读-改-写。
8. 全程后台,禁止 Terminal GUI 弹窗;
9. 一机一锁、禁止并行 install;身份看 manifest/AOT/marker/UUID,不只看 build;
10. 要求实际 UUID 时,用户手动启动后只读 attach 验运行中 image UUID。

---

## 出处(记忆与档案)

- `feedback_install_wait_for_capture_or_recon`(08-10 事故+顺序铁律)
- `feedback_verify_tool_behavior_before_running`(08-18 flutter install 卸载事故)
- `feedback_install_contract_product_pipeline_split`(装机合同:产品/管线分开+单变量)
- `feedback_verify_it_actually_landed_in_production`(装机≠生效)
- `feedback_env_file_is_shared_read_modify_write`(env 读-改-写)
- `feedback_delivery_lossless_absolute_no_frame_loss`(无损铁律)
- `project_pocketworld_device_backup_verified_recipe`(备份配方)
- b22 fail-closed 改造与 08-25 "刚启动等待复查" 实战:
  memory `project_pocketworld_autocapture_burst_finish_campaign`
