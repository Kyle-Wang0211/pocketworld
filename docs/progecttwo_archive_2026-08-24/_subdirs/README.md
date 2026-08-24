# progecttwo 子目录抢救(第三批,2026-08-24)

来源:`~/Documents/progecttwo` 的 15 个子目录。收录 **106** 个可读文本/代码文件(4.9 MB)。

| 子目录 | 抢救 |
|---|---|
| `CAPTURE_347_VERIFY` | 56 |
| `FAILING_TESTS` | 7 |
| `README.md` | 1 |
| `SFM_CMP_SHELL_SCRIPTS_RESCUED_2026-08-23` | 7 |
| `_install_ledger` | 2 |
| `_rc_sdk_forensics` | 18 |
| `docs` | 9 |
| `rc_sdk_evidence` | 1 |
| `xrslam_capi_tests` | 6 |

## 同批确认丢失 115 个文件

几个受损最重的目录:

| 目录 | 总文件 | 可读 | dataless |
|---|---|---|---|
| `donor_whitebox` | 816 | 0 | **312** |
| `_rc_sdk_forensics` | 79 | 18 | **31** |
| `docs` | 40 | 9 | **31** |
| `recovered_claude_history` | 34 | 0 | **30** |
| `local_viewers` | 19 | 0 | **8** |
| `.context` / `openspec` / `tools` | 13 | 0 | **13** |

⚠️ `donor_whitebox` 的 312 个 dataless 未计入上面的 115(该目录无白名单扩展名文件)。

```
docs/minimal_whitebox_pruning_inventory_2026-03-20.md
docs/da3_image_only_long_term_memory_2026-06-06.md
docs/object_mode_v2_implementation_table_2026-04-07.md
docs/mobile_background_upload_architecture_2026-03-22.md
docs/aether_closed_loop_pruning_plan_2026-03-19.md
docs/3dgs_mobile_paper_expansion_2026-04-07.md
docs/minimal_whitebox_constants_and_native_inventory_2026-03-21.md
docs/da3_k30_504_mac_agent_prompt_2026-05-24.md
docs/3dgs_mobile_paper_english_2026-04-07.md
docs/object_fast_publish_v1_worker_plan_2026-04-08.md
docs/object_fast_publish_v1_checklist_2026-04-08.md
docs/phone_to_5090_ssh_interface_spec_2026-03-20.md
docs/da3_multiview_benchmark_rank_2026-05-24.md
docs/aether3d_true_source_whitelist_2026-03-21.md
docs/claude_session_history_safety_long_term_memory_2026-06-20.md
docs/minimal_whitebox_runtime_inventory_2026-03-20.md
docs/control_plane_schema_worker_api_2026-03-22.md
docs/superpowers/plans/2026-07-13-global-agent-research-stack.md
docs/superpowers/plans/2026-07-21-repo-separation-audit-migration-plan.md
docs/superpowers/plans/2026-07-31-portable-canonical-exact8192-vertical-slice.md
docs/superpowers/plans/2026-07-21-three-prompts-execution-plan.md
docs/superpowers/plans/2026-07-18-codex-superpowers-only-skills.md
docs/superpowers/plans/2026-07-21-cleanup-sync-roadmap-research-plan.md
docs/superpowers/plans/2026-07-22-b0-b3-execution-plan.md
docs/superpowers/plans/2026-07-21-execute-sync-av-build-plan.md
docs/superpowers/specs/2026-07-13-global-agent-research-stack-design.md
docs/superpowers/specs/2026-07-22-b0-b3-execution-design.md
docs/superpowers/specs/2026-07-31-pw-official-structured-codecs-design.md
docs/superpowers/specs/2026-07-18-codex-superpowers-only-skills-design.md
docs/superpowers/specs/2026-07-21-execute-sync-av-build-design.md
docs/superpowers/specs/2026-07-31-lossless-cross-project-dedup-design.md
rc_sdk_evidence/20160801_RealityCapturePriceList.txt
rc_sdk_evidence/20160801_RealityCaptureSdkPriceList.txt
_rc_sdk_forensics/cescg2018_all_workshop_products.json
_rc_sdk_forensics/RCEngine_exports_154.txt
_rc_sdk_forensics/RCEngine_symbols_158_extended.txt
_rc_sdk_forensics/RC_public_alignment_surface_RAW.txt
_rc_sdk_forensics/20160801_RealityCaptureSdkPriceList.txt
_rc_sdk_forensics/cescg_wp_products_reality.json
_rc_sdk_forensics/rs_alignsettings.txt
_rc_sdk_forensics/msvc_demangle.py
_rc_sdk_forensics/rc_thread_disable_preselector.txt
_rc_sdk_forensics/Houdini_RC_SOP_sdk_surface_RAW.txt
_rc_sdk_forensics/rc_cli_docs/rs_modelsettings.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_fav_cameras.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_fav_components.txt
_rc_sdk_forensics/rc_cli_docs/rs_appsettings.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_5.txt
_rc_sdk_forensics/rc_cli_docs/wayback_rc_setkeyvaluetable_20231127.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_4.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_6.txt
_rc_sdk_forensics/rc_cli_docs/rs_editselectioncommand.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_3.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_functions_and_variables.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_2.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_fav_sets.txt
_rc_sdk_forensics/rc_cli_docs/epic_keys_and_values.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline_1.txt
_rc_sdk_forensics/rc_cli_docs/rs_alignsettings.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_fav_images.txt
_rc_sdk_forensics/rc_cli_docs/rs_commandline.txt
_rc_sdk_forensics/rc_cli_docs/rs_setkeyvaluetable.txt
_rc_sdk_forensics/rc_cli_docs/rs_reports_fav_points.txt
local_viewers/hislam2_realdesk_24_78db_probe_viewer/index.html
local_viewers/hislam2_realdesk_24_78db_probe_viewer/README.txt
local_viewers/hislam2_realdesk_24_78db_probe_viewer/serve_local_viewer.py
local_viewers/hislam2_realdesk_24_78db_probe_viewer/viewer_port.txt
local_viewers/hislam2_realdesk_21_92db_full_viewer/index.html
local_viewers/hislam2_realdesk_21_92db_full_viewer/README.txt
local_viewers/hislam2_realdesk_21_92db_full_viewer/serve_local_viewer.py
local_viewers/hislam2_realdesk_21_92db_full_viewer/viewer_port.txt
.context/compound-engineering/ce-optimize/pw-rust-lepton-jpeg-screen/spec.yaml
.context/compound-engineering/ce-optimize/pw-rust-lepton-jpeg-screen/experiment-log.yaml
.context/compound-engineering/ce-optimize/pw-rust-lepton-jpeg-screen/strategy-digest.md
.context/compound-engineering/ce-optimize/pw-database-extreme-codecs/spec.yaml
.context/compound-engineering/ce-optimize/pw-database-extreme-codecs/experiment-log.yaml
.context/compound-engineering/ce-optimize/pw-database-extreme-codecs/strategy-digest.md
openspec/changes/deactivate-canonical-exact8192-production/proposal.md
openspec/changes/benchmark-lossless-cross-project-dedup/proposal.md
openspec/changes/benchmark-pw-compact-sfm-a/proposal.md
openspec/changes/benchmark-lossless-cross-project-dedup/specs/lossless-cross-project-dedup/spec.md
openspec/changes/benchmark-pw-compact-sfm-a/specs/pw-compact-sfm-a/spec.md
tools/codex_leaf_worker_entry.sh
tools/codex_leaf_worker.sh
recovered_claude_history/index.html
recovered_claude_history/manifest.json
recovered_claude_history/sessions/023-Phase-6-4ef5ce3d.html
recovered_claude_history/sessions/004-0a5b0132-0024-4ede-ad40-afefaa347b7a-0a5b0132.html
recovered_claude_history/sessions/029-Hand-crank-generator-Arduino-p5js-game-8a1c220c.html
recovered_claude_history/sessions/006-DA3-MONO-Large-functionality-908a8ed5.html
recovered_claude_history/sessions/010-Plan-multi-pendulum-model-creation-approach-9e3dd052.html
recovered_claude_history/sessions/012-Research-web-animation-and-UI-effects-596070b4.html
recovered_claude_history/sessions/013---eb360d86.html
recovered_claude_history/sessions/009-Pocketworld-Stage-02-progress-review-3b320dff.html
recovered_claude_history/sessions/011-Adjust-robot-head-size-and-lighting-for-text-clarity-84ec553c.html
recovered_claude_history/sessions/001-New-mode-comparison-with-Max-2fd438e9.html
recovered_claude_history/sessions/005-VSCode-Claude-integration-setup-f2c35ffe.html
recovered_claude_history/sessions/002-File-and-URL-lookup-274ac979.html
recovered_claude_history/sessions/028-Phase-6.4f.2-depth-sort-SH-deg-0-3-8ae94ccd.html
recovered_claude_history/sessions/019---4f883228.html
recovered_claude_history/sessions/017-Set-up-PocketWorld-cross-platform-development-environment-b641b1d8.html
recovered_claude_history/sessions/015--SAP-efcc39fc.html
recovered_claude_history/sessions/022-Add-sidebar-with-chat-history-to-homepage-5a4ecae8.html
recovered_claude_history/sessions/020---5b3f2943.html
recovered_claude_history/sessions/021-Implement-PocketWorld-upload-and-scan-UI-8647a01d.html
recovered_claude_history/sessions/003-Claude-plugins-superpowers-v6.0.2-09b9d58a.html
recovered_claude_history/sessions/007-Mosaic-removal-algorithms-research-e4bb48d5.html
recovered_claude_history/sessions/031-Multiplayer-paint-floor-game-with-3D-house-3fa66b9c.html
recovered_claude_history/sessions/027-Phase-6.4f.3-SPZ-memory-optimization-a-b-c-d--103333ce.html
recovered_claude_history/sessions/025-phase3-e80a9e88.html
recovered_claude_history/sessions/026-Phase-1-11967862.html
recovered_claude_history/sessions/030-Fix-stuck-position-at-staircase-entrance-fc953035.html
recovered_claude_history/sessions/024-Phase-5-0378d811.html
recovered_claude_history/sessions/018-Drop-dead-captureUpload-i18n-keys-a889ee61.html
```

## 两处 gitleaks 处理

提交时 gitleaks 拦下 2 个 finding,均为误报,但处理方式不同:

1. `CAPTURE_347_VERIFY/.../official_database_prune.json` 的 `"keypoints_xy_sha256"`
   是 COLMAP 关键点坐标的 SHA-256 摘要。已在 `.gitleaks.toml` 的 `generic-api-key`
   白名单加一条窄规则:仅放行**字段名以 `sha256` 结尾且值恰为 64 位十六进制**的情况。
   已做负向对照——在同一文件放入真 Supabase service_role JWT 仍被抓出,规则未开漏洞。

2. `rc_sdk_evidence/support_CLI-vs-SDK-license_20190716.html` 第 329 行含第三方
   支持站点嵌入的 Rollbar 客户端 accessToken。**不属于本项目、也不该由本仓携带**,
   已就地替换为 `REDACTED-BY-ARCHIVE-2026-08-24`。页面其余内容未改动。
