# progecttwo 顶层文档存档(2026-08-24)

## 为什么有这个目录

`~/Documents/progecttwo` 在 iCloud 同步域内,而它有 **128 GB**,iCloud 账户只有 **50 GB**。
同步永远完不成 + 本地磁盘 96% 满 ⇒ macOS 把文件逐出成 APFS `dataless` 占位符 ⇒
**内容在本地和云端都不存在**。2026-08-24 确认 46 个顶层文档已永久丢失。

本目录是当天从 progecttwo 抢救出的**全部仍可读**的顶层文本资产,已逐字节核对。

## 内容

| 类型 | 数量 |
|---|---|
| `.md` | 40 |
| `.tsv` | 4 |
| `.html` | 2 |
| `.sh` | 2 |

未收录:两个 >5 MB 的可再生清单元数据
(`repo_separation_workspace_inventory_2026-07-21.tsv` 116 MB、`repo_separation_tracked_inventory_2026-07-21.tsv` 9 MB)。

## 已永久丢失的 46 个文件

仅存文件名与元数据大小,内容不可恢复(APFS 本地快照为空,Time Machine 从未配置)。

```
AV_BUILD_REPORT.md
AV_BUILD_REPORT_v2.md
B0_B3_EXECUTION_REPORT.md
B0_MESHING_AB_REPORT.md
B0_TO_B3_EXECUTE_PROMPT.md
B1_B3_MIGRATION_REPORT.md
BA_ITERATION_CAP_RESEARCH_2026-07-28.md
CLEANUP_SYNC_AND_ROADMAP_PROMPT.md
CLEANUP_SYNC_AND_ROADMAP_REPORT_2026-07-21.md
CODEX_PROMPT_LOCAL_BA_STREAM_SPEEDUP_2026-08-08.md
COLMAP_QUADRATIC_OVERLAP_RESEARCH_PROMPT.md
COLMAP_QUADRATIC_OVERLAP_RESEARCH_REPORT_2026-07-20.md
EXECUTE_REPORT_2026-07-21.md
EXECUTE_REPORT_V2_2026-07-21.md
EXECUTE_SYNC_AND_AV_BUILD_PROMPT.md
EXECUTE_THREE_DECOUPLED_TASKS_PROMPT.md
FULLRES_MVS_AND_FUSECUT_RESEARCH_PROMPT.md
FULLRES_MVS_AND_FUSECUT_RESEARCH_REPORT_2026-07-21.md
HANDOFF_STAGE1_ALIAS_继承_2026-07-19.md
HANDOFF_UI与Cauchy最终重建_2026-07-10.md
ICLOUD_REPORT.md
L1L2_PRECEDENT_SEARCH_PROMPT.md
L1L2_PRECEDENT_SEARCH_REPORT_2026-07-20.md
LOCAL_BA_PROFILE_2026-07-29.md
M5_RU_VERDICT_2026-07-29.md
OFFICIAL_ALIGNMENT_AUDIT_2026-07-28.md
PLY_CLEANUP_EXECUTE_PROMPT.md
PLY_CLEANUP_REPORT_2026-07-21.md
PLY_DELETION_COMMIT_REPORT.md
POCKETWORLD_ABCDE_MASTER_HANDOFF_PROMPT_2026-07-16.md
POCKETWORLD_HANDOFF_ADDENDUM_2026-07-17.md
PUSH_REPORT.md
RC_BLACKBOX_MEASUREMENT_RUNBOOK_2026-08-04.md
REPO_SEPARATION_AUDIT_2026-07-21.md
REPO_SEPARATION_AUDIT_AND_MIGRATION_PROMPT.md
RS_PARITY_FINAL_VERDICT_2026-07-28.md
RS_POINT_RENDERING_EVIDENCE_2026-07-28.md
RS_THIRD_PARTY_ANALYSIS_DOSSIER_2026-07-28.md
STAGE1_TRACK_TOPOLOGY_RESEARCH_DOSSIER_2026-07-17.md
THREE_PROMPTS_EXECUTION_REPORT_2026-07-21.md
icloud_materialize_report.md
repo_separation_topology_2026-07-21.tsv
cleanup_plan.sh
migration_plan.sh
reclaim_plan.sh
sync_plan.sh
```

## 已采取的防复发措施

1. Astrill VPN 的全局代理曾劫持中国区 CloudKit(直连 HTTP 405/0.076s vs 经代理超时 25s,330×)。
   已在 Astrill → Site Filter → Exclude these sites 加入 `icloud.com.cn` 等域名。
2. progecttwo 内可再生大目录已用 `mv X X.nosync && ln -s X.nosync X` 移出 iCloud 同步集,
   共 119 GB(`.deps` / `_artifacts` / `_host_experiments` / `_host_fixtures` / `.device_backups` / `.fixtures_12mp`),
   原路径经符号链接保持可用。同步集 128 GB → 约 1.4 GB。
3. ⚠️ 仍缺 Time Machine —— 本机当前**没有任何备份**,需外置磁盘。
