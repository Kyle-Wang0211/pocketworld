# DA3 Multiview K/Resolution Research Package

Date: 2026-05-27

This folder freezes the DA3 multiview tuning evidence used to seal the
commercial DA3-BASE mobile route at `K35@476x742`.

## Scope

- DA3-BASE K/resolution sweep data, including square and rectangular CoreML
  variants.
- Historical DA3-Large / DA3Metric-Large evidence kept for research context
  only. These routes remain non-production because Large-family DA3 is blocked
  from the commercial app path.
- iPhone real-device Stage 1 evidence for the 96-frame / 6-window capture:
  runtime logs, dense Sim3 cross-window geometry consistency, and the debug
  window-colored point cloud.
- Algorithm snapshots needed to reproduce the experiment logic without
  depending on chat history.

## Folder Layout

| Path | Contents |
|---|---|
| `algorithm/` | Flutter/Dart and benchmark-test snapshots: DA3 runner tests, dense Sim3 verifier, metric-depth alignment contract. |
| `data/quality_sweep/` | Human-readable benchmark rank and machine-readable compact CSV extracted from it. |
| `data/phone_6window/` | Real iPhone 96-frame / 6-window Stage 1 logs and reports. |
| `official_reference/` | DA3 official streaming/reference benchmark files used for comparison and citation prep. |
| `RESEARCH_MANIFEST.json` | File list with byte sizes and SHA-256 hashes for provenance. |

## Current Research Decision

`K35@476x742` is the current DA3-BASE geometry winner:

- Mac quality: RMSE `6.0733`, P90 `8.4533`.
- Phone pass: infer `112.453s`, peak RSS `1480MB`, device CPU peak `97.2%`.
- 6-window real capture: Stage 1 completed `96/96`, dense Sim3 report present,
  bridge/window alignment reported for downstream point cloud and mesh.

`K35@448x756` remains the high-quality runtime fallback. `K30@504x896` remains
the stress-proven but slow fallback. DA3-Large and DA3Metric-Large rows are kept
here only so future papers can explain the full search history; they are not
commercial app candidates.

## Reproducibility Notes

- The compact CSV is derived from `data/quality_sweep/da3_multiview_benchmark_rank_2026-05-24.md`.
- The 6-window phone data is copied from
  `device_captures/pulled_cap_1779777762841797_latest/`.
- Raw DA3 relative-depth tensors are intentionally not duplicated in this
  research package to avoid creating another large tensor archive. The indexed
  paths remain in `data/phone_6window/depth_index.json`.
