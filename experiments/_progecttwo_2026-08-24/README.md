# progecttwo/experiments 抢救存档(2026-08-24)

来源:`~/Documents/progecttwo/experiments`。该目录在研究仓中**零重合**——
20 个顶层条目没有一个已被跟踪。

## 收录规则

白名单扩展名(md/yaml/json/jsonl/csv/tsv/py/sh/txt/html/toml/cfg/log)且 <2 MB。
排除 `.db`/`.bin`(COLMAP 重建产物,可再生)与 `arkit_pose_ab_20260821` 的 1.0 GB 数据体。

收录 **78** 个文件,共 1006 KB。

## 同时确认丢失的 55 个文件

以下文件为 APFS `dataless` 占位符,内容在本地与 iCloud 均不存在。
受影响最严重的是这几个**整个目录全灭**的实验:

- `detector_free_dkm_outdoor_2026-07-14`
- `incremental_ba_ab_2026-07-14`
- `lossless_cross_project_dedup`
- `plane_sweep_a16_bench_2026-07-14`
- `pw_database_extreme_codecs`
- `pw_jpeg_repacker_screen`
- `pw_pointcloud_lossless_screen`
- `pw_whole_project_dwarfs`

```
./__init__.py
./pw_whole_project_dwarfs/run_host_screen.py
./lossless_cross_project_dedup/experiment-contract.yaml
./pw_pointcloud_lossless_screen/run_host_screen.py
./pw_database_extreme_codecs/experiment-contract.yaml
./pw_database_extreme_codecs/run_host_screen.py
./pw_jpeg_repacker_screen/run_packjpg_host_screen.py
./pw_jpeg_repacker_screen/run_microsoft_lepton_host_screen.py
./pw_official_structured_codecs/run_orc_screen.py
./pw_official_structured_codecs/run_tiledb_screen.py
./pw_official_structured_codecs/__init__.py
./pw_official_structured_codecs/run_host_screen.py
./pw_official_structured_codecs/README.md
./pw_official_structured_codecs/run_blosc2_screen.py
./pw_compact_sfm_a/input-manifest.yaml
./pw_compact_sfm_a/experiment-contract.yaml
./pw_compact_sfm_a/__init__.py
./pw_compact_sfm_a/README.md
./pw_compact_sfm_a/run_tests.sh
./pw_whole_project_dwarfs/results/host-cap_1784830836808715.json
./lossless_cross_project_dedup/tests/run_tests.sh
./lossless_cross_project_dedup/results/host-five-distinct-projects-20260731.json
./lossless_cross_project_dedup/results/cross-photo-comparison-20260731.json
./pw_pointcloud_lossless_screen/results/host-glomap-v6.json
./pw_database_extreme_codecs/results/strategy-digest.md
./pw_database_extreme_codecs/results/kanzi-tpaq.json
./pw_database_extreme_codecs/results/kanzi-tpaqx.json
./pw_database_extreme_codecs/results/libbsc.json
./pw_jpeg_repacker_screen/results/packjpg-host-100mb.json
./pw_jpeg_repacker_screen/results/host-100mb.json
./pw_jpeg_repacker_screen/results/microsoft-lepton-rust-host-100mb.json
./pw_official_structured_codecs/pwcodecs/__init__.py
./pw_official_structured_codecs/pwcodecs/parquet_codec.py
./pw_official_structured_codecs/pwcodecs/blosc2_codec.py
./pw_official_structured_codecs/pwcodecs/orc_codec.py
./pw_official_structured_codecs/tests/test_parquet_codec.py
./pw_official_structured_codecs/tests/test_blosc2_codec.py
./pw_official_structured_codecs/tests/__init__.py
./pw_official_structured_codecs/tests/test_host_screen.py
./pw_official_structured_codecs/tests/test_blosc2_host_screen.py
./pw_official_structured_codecs/results/strategy-digest.md
./pw_compact_sfm_a/tests/test_zpaq_cli.py
./pw_compact_sfm_a/tests/__init__.py
./pw_compact_sfm_a/tests/test_run_potential.py
./pw_compact_sfm_a/results/host-screen-cap_1785297411166420.json
./pw_compact_sfm_a/results/strategy-digest.md
./pw_compact_sfm_a/pwcsfma/optimistic_stream.py
./pw_compact_sfm_a/pwcsfma/__init__.py
./pw_compact_sfm_a/pwcsfma/varint.py
./pw_official_structured_codecs/results/descriptor-model/result.json
./pw_official_structured_codecs/results/tiledb/result-current-project.json
./pw_official_structured_codecs/results/blosc2/result.json
./pw_official_structured_codecs/results/blosc2/dependency-evidence.json
./pw_official_structured_codecs/results/orc/result-current-project.json
./pw_official_structured_codecs/results/parquet/result.json
```

事故详情见 `docs/progecttwo_archive_2026-08-24/README.md`。

## 关于 `*.log`

30 个 `.log` 被仓库根 `.gitignore:3` 的 `*.log` 排除,此处以 `git add -f` 强制收录。
它们是 B1 厂商中立实验(关闭 ARKit 位姿仍收敛 57/60)的原始运行日志——
重跑需要 1.0 GB 输入数据,属不可再生证据。此豁免仅限本存档目录。
