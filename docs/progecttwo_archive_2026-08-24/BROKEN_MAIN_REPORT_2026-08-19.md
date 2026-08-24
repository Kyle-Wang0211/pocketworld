# 🔴 pocketworld committed main 编译不过 — 断链报告

2026-08-19。发现于给采集页做「自动采集」功能、开隔离 worktree 时。
**本报告只做诊断,一个字节都没改 main**(用户 2026-08-19 裁定:不动手,交回作者收尾)。

---

## 一句话结论

`Kyle-Wang0211/pocketworld` 的 **main 分支 `bf159e3` 单独 checkout 出来编译不过**。
任何人 clone 下来 `flutter test` 都会撞编译错。

本地主树 `~/Developer/pocketworld` 能跑,**纯粹是因为缺的代码以未提交状态躺在磁盘上**。

---

## 证据(可复现)

```bash
git worktree add /tmp/pw-clean-check -b throwaway-check bf159e3
cd /tmp/pw-clean-check && flutter pub get && flutter test
```

最外层报错:

```
lib/ui/community/work_detail_page.dart:44:8:
lib/ui/me/my_work_detail_page.dart:36:8:
  Error: Error when reading 'lib/ui/official_capture/auto_rotating_cloud_view.dart':
  No such file or directory
```

`work_detail_page.dart` 与 `my_work_detail_page.dart` **两个都已提交、与 HEAD 逐字一致**,
而它们 import 的 `auto_rotating_cloud_view.dart` **从未被提交**。

这与 2026-08-18 那次事故是同一形态:**提交了调用方,没提交被调用方**。

---

## 逐层补是无效的 —— 实测走过两层

| 补什么 | 结果 |
|---|---|
| 补 `auto_rotating_cloud_view.dart` | 露出下一层:它 import 未提交的 `card_live_governor.dart` |
| 再补 `card_live_governor.dart` + `feed_models.dart` 的 28 行 | 又露出第三层:`my_work_detail_page.dart:187` 要 `AppL10n.publishErrRejected`(在未提交的 l10n ARB 里);`ar_capture_page.dart:1915` 要 `AetherEnvFile.intOf` |

Dart 编译器每个文件只报第一个错,所以**每修一层才看得见下一层**。

---

## 那份 WIP 本身是完整的(这是好消息)

把主树**全部**未提交改动整体搬进干净 worktree 后:

```
编译错误: 0
测试结果: 42 条失败 —— 与主树逐条一致
```

⇒ **作者的工作是自洽的,只是没提交。** 不是半成品,是"写完了忘了提交"。
所以正确的收尾动作是**一次性整体提交**,而不是让别人替他挑拣。

---

## 需要一起提交的 27 个文件

**16 个已改的已跟踪文件:**

```
lib/community/feed_models.dart
lib/community/thumb_baker.dart
lib/l10n/app_en.arb
lib/l10n/app_localizations.dart
lib/l10n/app_localizations_en.dart
lib/l10n/app_localizations_zh.dart
lib/l10n/app_zh.arb
lib/official_aether_sfm_ffi.dart
lib/official_capture/colorize_pipeline.dart
lib/official_capture/photo_archive_coordinator.dart
lib/official_capture/representative_color.dart
lib/official_capture/sfm_db_regen.dart
lib/ui/app_shell.dart
lib/ui/community/aether_cpp_card_demo.dart
lib/ui/vault_page.dart
tool/colorize_parallel_check.dart
```

**11 个未跟踪的新文件:**

```
lib/official_capture/aux_archive_container.dart
lib/official_capture/aux_archive_manifest.dart
lib/official_capture/aux_archive_resolver.dart
lib/official_capture/aux_archive_transaction.dart
lib/ui/community/card_live_governor.dart
lib/ui/community/live_card_cloud.dart
lib/ui/community/work_card.dart
lib/ui/official_capture/auto_rotating_cloud_view.dart
test/aux_archive_transaction_test.dart
test/endpoint_config_test.dart
test/feed_live_card_test.dart
```

看起来是两条线交织在一起:**社区 feed live 卡(方案 B)** 与 **aux archive 事务**。
如果要拆成两个提交,建议按这两条线分,但**必须同一次推上去** —— 单独推任一条,
main 仍然编译不过。

---

## 另有 19 条失败与本断链无关

即使把上面 27 个全部提交,仍有 19 条测试是红的 —— 它们在**干净 worktree 与主树里都红**,
属于 committed main 的既有失败,不是本次断链造成:

```
test/pose_drift_tracker_test.dart                    (5 条)
test/dome_target_points_curation_test.dart           (3 条)
test/official_capture_copy_contract_test.dart        (1 条)
test/official_highres_reconstruction_contract_test.dart
test/official_per_image_pinhole_contract_test.dart
test/official_stop_production_contract_test.dart
test/official_swift_config_parity_test.dart
test/sfm_start_fail_closed_contract_test.dart
test/wait_budget_telemetry_contract_test.dart
test/capture_quality_ramp_test.dart
test/glb_cache_size_guard_test.dart
test/platform_pose_provider_fail_closed_test.dart
test/sparse_thumbnail_test.dart
```

这些是另一件事,本报告不涉及。

---

## 顺带发现:提交进仓的 codegen 产物是陈旧的

在干净 worktree 里跑 `flutter pub get` 后,下列文件立刻变脏:

```
lib/l10n/app_localizations.dart
lib/l10n/app_localizations_en.dart
lib/l10n/app_localizations_zh.dart
macos/Flutter/GeneratedPluginRegistrant.swift
```

说明仓里提交的这几个生成物与当前 ARB / 插件集**不同步**。主树里它们也一直是脏的。
建议要么重新生成后提交,要么把它们移出版本控制。
